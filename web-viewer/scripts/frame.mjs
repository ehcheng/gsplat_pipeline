#!/usr/bin/env node
/**
 * frame.mjs: level a trained splat and choose its opening camera.
 *
 *   node scripts/frame.mjs <scene folder> [options]
 *
 * Pass 1 (no --azimuth): reads the COLMAP poses next to the PLY, estimates gravity "up",
 * derives the rotation that levels the scene, writes a decimated leveled preview PLY,
 * renders a contact sheet of candidate views around the subject, and writes
 * <scene>/frame/frame.json with everything except the final choice.
 *
 * Pass 2 (--azimuth N [--elevation E] [--distance F] [--fov V]): records the chosen camera
 * in frame.json, renders <scene>/frame/chosen.webp from it for a final check, and renders
 * the 1920x1280 share thumbnail <scene>/thumbnail.jpg (see thumbnail.mjs).
 *
 * build-viewer.mjs picks frame.json up automatically: it applies the rotation to the SOG
 * and writes the chosen pose as the viewer's initial camera.
 *
 * Coordinate frames. The PLY, SPZ and SOG formats share "PLY space"; the converter, its
 * renderer, and the PlayCanvas viewer all work in "engine space", which is PLY space
 * rotated 180 degrees about Z: (x, y, z) -> (-x, -y, z). Everything in frame.json is in
 * engine space, after the leveling rotation, so it can be used directly as viewer settings.
 *
 * Options:
 *   --ply <path>         PLY to use (default: newest lfs/splat_*.ply in the scene)
 *   --views <n>          candidate azimuths around the subject (default 8)
 *   --elevation <deg>    camera elevation above the subject center (default 18)
 *   --distance <factor>  camera distance as a multiple of the median capture radius (default 1.0)
 *   --fov <deg>          vertical field of view (default 60)
 *   --azimuth <deg>      finalize: chosen azimuth (0 = the capture-prior direction, see below)
 *   --lift <fraction>    target height as a fraction of camera height above ground (default 0.45)
 *   --far-radius <units> pass 2: pull splats beyond this radius onto a shell (default 300 x capture radius)
 *   --max-roll <deg>     frames rolled further than this from level are left out of the gravity estimate (default 20)
 *
 * Azimuth 0 points from the subject toward the mean capture position, i.e. the side the
 * photographer spent most frames on. That is usually the front. Angles increase clockwise
 * when seen from above.
 */
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, openSync, readSync, writeSync, closeSync, readdirSync, statSync, writeFileSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { renderThumbnail } from './thumbnail.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const project = resolve(here, '..');
const cli = join(project, 'node_modules', '@playcanvas', 'splat-transform', 'bin', 'cli.mjs');

// ------------------------------------------------------------------ arguments
const argv = process.argv.slice(2);
const opts = { views: 8, elevation: 18, distance: 1.0, fov: 60 };
let scene = null;
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a.startsWith('--')) { opts[a.slice(2)] = argv[++i]; } else if (!scene) { scene = a; } else { throw new Error(`Unexpected argument ${a}`); }
}
if (!scene) { console.error('Usage: node scripts/frame.mjs <scene folder> [--azimuth deg] [--elevation deg] [--distance factor] [--fov deg] [--views n] [--ply path]'); process.exit(2); }
for (const k of ['views', 'elevation', 'distance', 'fov', 'azimuth', 'lift']) if (opts[k] !== undefined) opts[k] = Number(opts[k]);
scene = resolve(scene);
const frameDir = join(scene, 'frame');
const framePath = join(frameDir, 'frame.json');
mkdirSync(frameDir, { recursive: true });

const ply = opts.ply ? resolve(opts.ply) : (() => {
  const dir = join(scene, 'lfs');
  const c = readdirSync(dir).filter((f) => /^splat_\d+\.ply$/u.test(f)).map((f) => join(dir, f)).sort((a, b) => statSync(b).mtimeMs - statSync(a).mtimeMs);
  if (!c.length) throw new Error(`No lfs/splat_*.ply in ${scene}`);
  return c[0];
})();
const imagesBin = join(scene, 'colmap', 'sparse', '0', 'images.bin');
if (!existsSync(imagesBin)) throw new Error(`Missing ${imagesBin}`);

// ------------------------------------------------------------------ small vector helpers
const add = (a, b) => [a[0] + b[0], a[1] + b[1], a[2] + b[2]];
const sub = (a, b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
const mul = (a, s) => [a[0] * s, a[1] * s, a[2] * s];
const dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
const cross = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
const norm = (a) => Math.hypot(a[0], a[1], a[2]);
const unit = (a) => mul(a, 1 / norm(a));
const matVec = (M, v) => [dot(M[0], v), dot(M[1], v), dot(M[2], v)];
const transpose = (M) => [[M[0][0], M[1][0], M[2][0]], [M[0][1], M[1][1], M[2][1]], [M[0][2], M[1][2], M[2][2]]];
const round = (v, d = 4) => v.map((x) => Number(x.toFixed(d)));
const deg = (r) => (r * 180) / Math.PI;
const rad = (d) => (d * Math.PI) / 180;
const toEngine = (p) => [-p[0], -p[1], p[2]]; // PLY space -> engine space (180 deg about Z)

const quatToMat = ([w, x, y, z]) => [
  [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
  [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
  [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]
];

// Rotation matrix (row-major) that maps unit vector a onto unit vector b by the shortest arc.
const rotationBetween = (a, b) => {
  const v = cross(a, b); const c = dot(a, b); const s = norm(v);
  if (s < 1e-9) return c > 0 ? [[1, 0, 0], [0, 1, 0], [0, 0, 1]] : [[1, 0, 0], [0, -1, 0], [0, 0, -1]];
  const k = mul(v, 1 / s); const t = 1 - c;
  return [
    [c + k[0] * k[0] * t, k[0] * k[1] * t - k[2] * s, k[0] * k[2] * t + k[1] * s],
    [k[1] * k[0] * t + k[2] * s, c + k[1] * k[1] * t, k[1] * k[2] * t - k[0] * s],
    [k[2] * k[0] * t - k[1] * s, k[2] * k[1] * t + k[0] * s, c + k[2] * k[2] * t]
  ];
};

// PlayCanvas Mat4.setFromEulerAngles(ex, ey, ez), row-major 3x3, for verification.
const matFromEulers = (ex, ey, ez) => {
  const s1 = Math.sin(-rad(ex)), c1 = Math.cos(-rad(ex));
  const s2 = Math.sin(-rad(ey)), c2 = Math.cos(-rad(ey));
  const s3 = Math.sin(-rad(ez)), c3 = Math.cos(-rad(ez));
  return [
    [c2 * c3, c1 * s3 + c3 * s1 * s2, s1 * s3 - c1 * c3 * s2],
    [-c2 * s3, c1 * c3 - s1 * s2 * s3, c3 * s1 + c1 * s2 * s3],
    [s2, -c2 * s1, c1 * c2]
  ];
};
// Inverse of the above, so `-r x,y,z` reproduces M exactly in the converter's convention.
const eulersFromMat = (M) => {
  const ey = -Math.asin(Math.max(-1, Math.min(1, M[2][0])));
  const ez = -Math.atan2(-M[1][0], M[0][0]);
  const ex = -Math.atan2(-M[2][1], M[2][2]);
  const e = [deg(ex), deg(ey), deg(ez)];
  const back = matFromEulers(...e);
  let err = 0; for (let r = 0; r < 3; r++) for (let c = 0; c < 3; c++) err = Math.max(err, Math.abs(back[r][c] - M[r][c]));
  if (err > 1e-6) throw new Error(`Euler round-trip failed (max error ${err})`);
  return e;
};

// ------------------------------------------------------------------ COLMAP poses
const readImagesBin = (path) => {
  const b = readFileSync(path);
  let o = 0; const n = Number(b.readBigUInt64LE(o)); o += 8;
  const cams = [];
  for (let i = 0; i < n; i++) {
    o += 4; // image id
    const q = [0, 1, 2, 3].map((k) => b.readDoubleLE(o + 8 * k)); o += 32;
    const t = [0, 1, 2].map((k) => b.readDoubleLE(o + 8 * k)); o += 24;
    o += 4; // camera id
    let e = o; while (b[e] !== 0) e++; const name = b.toString('utf8', o, e); o = e + 1;
    const np = Number(b.readBigUInt64LE(o)); o += 8; o += np * 24;
    const R = quatToMat(q); // world -> camera
    const Rt = transpose(R);
    cams.push({
      name,
      center: matVec(Rt, mul(t, -1)),
      up: matVec(Rt, [0, -1, 0]),      // COLMAP camera y points down
      right: matVec(Rt, [1, 0, 0]),
      forward: matVec(Rt, [0, 0, 1])
    });
  }
  return cams;
};

const cams = readImagesBin(imagesBin);
// Gravity is the mean camera up, but frames where the rig was rolled (tipped sideways on
// purpose or by accident) would drag it. A camera's right vector stays horizontal at any
// pitch, so its angle to the current estimate is the roll: drop frames rolled more than
// --max-roll degrees and re-average until the set is stable. A level capture drops nothing.
const maxRollDeg = Number(opts['max-roll'] ?? 20);
const rollDeg = (c, up) => deg(Math.abs(Math.asin(Math.max(-1, Math.min(1, dot(c.right, up))))));
let upCams = cams;
let meanUp = unit(cams.reduce((s, c) => add(s, c.up), [0, 0, 0]));
for (let k = 0; k < 10; k++) {
  const kept = cams.filter((c) => rollDeg(c, meanUp) <= maxRollDeg);
  if (kept.length < 0.5 * cams.length) throw new Error(`Only ${kept.length}/${cams.length} cameras within ${maxRollDeg} deg of level; raise --max-roll`);
  const next = unit(kept.reduce((s, c) => add(s, c.up), [0, 0, 0]));
  const settled = kept.length === upCams.length && dot(next, meanUp) > 1 - 1e-12;
  upCams = kept; meanUp = next;
  if (settled) break;
}
const rolledFrames = cams.filter((c) => rollDeg(c, meanUp) > maxRollDeg).map((c) => c.name).sort();
const camCentroid = mul(cams.reduce((s, c) => add(s, c.center), [0, 0, 0]), 1 / cams.length);
// Plane through the camera centers: smallest-variance axis, as a cross-check on gravity.
const cov = [[0, 0, 0], [0, 0, 0], [0, 0, 0]];
for (const c of cams) { const d = sub(c.center, camCentroid); for (let i = 0; i < 3; i++) for (let j = 0; j < 3; j++) cov[i][j] += d[i] * d[j]; }
let planeNormal = [0, 0, 0];
{ // power iteration on the inverse is overkill; use the eigenvector of the smallest eigenvalue via repeated deflation of the largest two
  const powerIter = (M) => { let v = [0.3, 0.5, 0.8]; for (let k = 0; k < 200; k++) v = unit(matVec(M, v)); return v; };
  const e1 = powerIter(cov); const l1 = dot(matVec(cov, e1), e1);
  const M2 = cov.map((r, i) => r.map((x, j) => x - l1 * e1[i] * e1[j]));
  const e2 = powerIter(M2);
  planeNormal = unit(cross(e1, e2));
  if (dot(planeNormal, meanUp) < 0) planeNormal = mul(planeNormal, -1);
}
const upAgreementDeg = deg(Math.acos(Math.max(-1, Math.min(1, dot(meanUp, planeNormal)))));
const upSpreadDeg = deg(Math.acos(Math.max(-1, Math.min(1, upCams.reduce((s, c) => s + dot(c.up, meanUp), 0) / upCams.length))));

// ------------------------------------------------------------------ splat positions (subject center)
const readPlyPositions = (path) => {
  const fd = openSync(path, 'r');
  const head = Buffer.alloc(65536); const hn = readSync(fd, head, 0, head.length, 0);
  const text = head.toString('latin1', 0, hn);
  const end = text.indexOf('end_header\n'); if (end < 0) throw new Error('PLY header not found');
  const headerLen = end + 'end_header\n'.length;
  const lines = text.slice(0, end).split('\n');
  const count = Number(lines.find((l) => l.startsWith('element vertex')).split(' ')[2]);
  const props = lines.filter((l) => l.startsWith('property')).map((l) => l.split(' ')[2]);
  if (!lines.some((l) => l.startsWith('format binary_little_endian'))) throw new Error('Only binary little-endian PLY is supported');
  const stride = props.length * 4;
  const ix = props.indexOf('x'), iy = props.indexOf('y'), iz = props.indexOf('z'), io = props.indexOf('opacity');
  const pts = []; // opaque positions only
  const chunkRows = 65536; const buf = Buffer.alloc(chunkRows * stride);
  let row = 0; let pos = headerLen;
  while (row < count) {
    const rows = Math.min(chunkRows, count - row);
    readSync(fd, buf, 0, rows * stride, pos); pos += rows * stride;
    for (let r = 0; r < rows; r++) {
      const base = r * stride;
      const opacity = 1 / (1 + Math.exp(-buf.readFloatLE(base + io * 4)));
      if (opacity < 0.5) continue;
      pts.push([buf.readFloatLE(base + ix * 4), buf.readFloatLE(base + iy * 4), buf.readFloatLE(base + iz * 4)]);
    }
    row += rows;
  }
  closeSync(fd);
  return { count, opaque: pts };
};
const { count: splatCount, opaque } = readPlyPositions(ply);

// Frame with gravity up: basis (e1, up, e2) in PLY space.
const seed = Math.abs(meanUp[0]) < 0.9 ? [1, 0, 0] : [0, 0, 1];
const e1 = unit(cross(seed, meanUp)); const e2 = cross(meanUp, e1);
const horizontal = (p, origin) => { const d = sub(p, origin); return [dot(d, e1), dot(d, e2)]; };
const median = (arr) => { const s = [...arr].sort((a, b) => a - b); return s.length ? s[Math.floor(s.length / 2)] : 0; };
const percentile = (arr, q) => { const s = [...arr].sort((a, b) => a - b); return s.length ? s[Math.min(s.length - 1, Math.floor(q * s.length))] : 0; };

// Capture radius: median horizontal distance of cameras from their centroid.
const camRadius = median(cams.map((c) => Math.hypot(...horizontal(c.center, camCentroid))));
// Subject center: median of opaque splats inside the capture ring (horizontally), height from those too.
const inside = opaque.filter((p) => Math.hypot(...horizontal(p, camCentroid)) < 0.8 * camRadius);
const pick = inside.length > 1000 ? inside : opaque;
// The median of opaque splats sits on the ground (most opaque splats are ground), so the
// horizontal center comes from it but the height is lifted toward the cameras: an
// eye-level walk-around implies a subject whose middle is a bit under half camera height.
const groundCenter = [median(pick.map((p) => p[0])), median(pick.map((p) => p[1])), median(pick.map((p) => p[2]))];
const subjectRadius = percentile(pick.map((p) => Math.hypot(...horizontal(p, groundCenter))), 0.9);
const camHeight = median(cams.map((c) => dot(sub(c.center, groundCenter), meanUp)));
const targetLift = Number(opts.lift ?? 0.45);
const center = add(groundCenter, mul(meanUp, camHeight * targetLift));

// Prior azimuth: direction from the subject toward the mean camera position.
const priorDir2 = horizontal(camCentroid, center);
const priorAngle = Math.atan2(priorDir2[0], priorDir2[1]); // relative to e2, clockwise from above

// ------------------------------------------------------------------ engine space, leveling rotation
const upE = unit(toEngine(meanUp));
const R = rotationBetween(upE, [0, 1, 0]);
const rotate = round(eulersFromMat(R), 4);
const lv = (p) => matVec(R, toEngine(p)); // PLY space -> leveled engine space
const target = lv(center);
const e1E = matVec(R, unit(toEngine(e1))); const e2E = matVec(R, unit(toEngine(e2)));
// Azimuth a (deg, 0 = prior direction, clockwise from above) -> horizontal unit vector in leveled engine space
const azDir = (aDeg) => { const a = priorAngle + rad(aDeg); return add(mul(e1E, Math.sin(a)), mul(e2E, Math.cos(a))); };
const cameraFor = (aDeg, elevationDeg, distanceFactor) => {
  const d = camRadius * distanceFactor; const el = rad(elevationDeg);
  const position = add(add(target, mul(azDir(aDeg), d * Math.cos(el))), [0, d * Math.sin(el), 0]);
  return { position: round(position), target: round(target), fov: opts.fov };
};

const run = (args, label) => {
  const r = spawnSync(process.execPath, [cli, '--no-tty', '-q', '-w', ...args], { stdio: ['ignore', 'inherit', 'inherit'] });
  if (r.status !== 0) throw new Error(`${label} failed (exit ${r.status})`);
};
const renderView = (source, camera, out, resolution) => run([source, '--camera-pos', camera.position.join(','), '--camera-target', camera.target.join(','), '--camera-up', '0,1,0', '--camera-fov', String(camera.fov), '--resolution', resolution, out], `render ${out}`);

let frame = existsSync(framePath) ? JSON.parse(readFileSync(framePath, 'utf8')) : {};
frame = {
  ...frame,
  scene, ply, generatedAt: new Date().toISOString(),
  poses: { images: cams.length, rolledFrames: rolledFrames.length, maxRollDeg, upSpreadDeg: Number(upSpreadDeg.toFixed(2)), planeVsGravityDeg: Number(upAgreementDeg.toFixed(2)), captureRadius: Number(camRadius.toFixed(3)), cameraHeightAboveCenter: Number(camHeight.toFixed(3)) },
  splats: { total: splatCount, opaque: opaque.length, insideRing: inside.length, subjectRadius: Number(subjectRadius.toFixed(3)) },
  upPly: round(meanUp), upEngine: round(upE),
  rolledFrames,
  rotate,
  target: round(target),
  azimuthZeroIsCapturePrior: true,
  defaults: { elevation: opts.elevation, distance: opts.distance, fov: opts.fov, lift: targetLift }
};

if (opts.azimuth === undefined) {
  // Pass 1: preview PLY + contact sheet.
  const preview = join(frameDir, 'preview.ply');
  console.log(`Leveling: up (PLY) ${round(meanUp).join(', ')}; cameras agree within ${upSpreadDeg.toFixed(1)} deg; orbit plane vs gravity ${upAgreementDeg.toFixed(1)} deg`);
  if (rolledFrames.length) console.log(`Leveling ignored ${rolledFrames.length} frames rolled more than ${maxRollDeg} deg: ${rolledFrames.join(' ')}`);
  console.log(`Rotate (engine Euler deg): ${rotate.join(', ')}  |  subject center ${round(target).join(', ')}  |  capture radius ${camRadius.toFixed(2)}`);
  console.log(`Writing leveled preview (${splatCount} splats, SH bands above 1 dropped)...`);
  run([ply, '-r', rotate.join(','), '-H', '1', preview], 'preview'); // -d (decimate) crashes on 1.5M-splat inputs in v3.4.0
  const n = opts.views; const tiles = [];
  frame.candidates = [];
  for (let i = 0; i < n; i++) {
    const az = (i * 360) / n; const cam = cameraFor(az, opts.elevation, opts.distance);
    const out = join(frameDir, `view_${String(az).padStart(3, '0')}.webp`);
    renderView(preview, cam, out, '640x400'); tiles.push(out);
    frame.candidates.push({ azimuth: az, camera: cam });
  }
  const top = { position: round(add(target, [0, camRadius * 1.6, 0.001])), target: round(target), fov: opts.fov };
  const topOut = join(frameDir, 'view_top.webp'); renderView(preview, top, topOut, '640x400'); tiles.push(topOut);
  // Contact sheet with ffmpeg (on PATH): rows of 3, labels drawn as text.
  const cols = 3; const rows = Math.ceil(tiles.length / cols);
  const inputs = tiles.flatMap((t) => ['-i', t]);
  const labels = tiles.map((t, i) => (i < n ? `az ${(i * 360) / n}` : 'top'));
  let fc = tiles.map((_, i) => `[${i}]drawtext=text='${labels[i]}':x=10:y=10:fontsize=28:fontcolor=white:box=1:boxcolor=black@0.6[t${i}]`).join(';');
  const rowsSpec = [];
  for (let r = 0; r < rows; r++) {
    const ids = []; for (let c = 0; c < cols; c++) { const i = r * cols + c; ids.push(i < tiles.length ? `[t${i}]` : null); }
    const present = ids.filter(Boolean);
    if (present.length < cols) { const pad = cols - present.length; fc += `;color=c=black:s=640x400:d=1[pad${r}]`; for (let k = 0; k < pad; k++) present.push(`[pad${r}]`); }
    fc += `;${present.join('')}hstack=inputs=${cols}[r${r}]`; rowsSpec.push(`[r${r}]`);
  }
  fc += `;${rowsSpec.join('')}vstack=inputs=${rows}[out]`;
  const sheet = join(frameDir, 'contact.png');
  // ffmpeg's drawtext prints harmless fontconfig complaints on Windows; stderr is shown only on failure.
  const ffmpeg = (filter) => spawnSync('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', ...inputs, '-filter_complex', filter, '-map', '[out]', '-frames:v', '1', sheet], { stdio: ['ignore', 'inherit', 'pipe'] });
  let ff = ffmpeg(fc);
  if (ff.status !== 0) { // retry without drawtext (no font support in this ffmpeg build)
    ff = ffmpeg(fc.replace(/\[(\d+)\]drawtext=[^\[]*\[t\1\]/gu, '[$1]copy[t$1]'));
    if (ff.status !== 0) process.stderr.write(ff.stderr);
  }
  frame.contactSheet = ff.status === 0 ? sheet : null;
  frame.contactSheetOrder = labels;
  writeFileSync(framePath, `${JSON.stringify(frame, null, 2)}\n`);
  console.log(`Contact sheet: ${frame.contactSheet ?? '(ffmpeg failed; see individual view_*.webp files)'}  order: ${labels.join(' | ')}`);
  console.log(`Next: node scripts/frame.mjs "${scene}" --azimuth <deg> [--elevation ${opts.elevation}] [--distance ${opts.distance}] [--fov ${opts.fov}]`);
} else {
  // Pass 2: finalize the camera and write the publish PLY.
  const cam = cameraFor(opts.azimuth, opts.elevation, opts.distance);
  frame.chosen = { azimuth: opts.azimuth, elevation: opts.elevation, distance: opts.distance, fov: opts.fov, camera: cam };
  const preview = join(frameDir, 'preview.ply');
  if (existsSync(preview)) renderView(preview, cam, join(frameDir, 'chosen.webp'), '1280x800');

  // Publish PLY: leveled (rotation baked in) with far splats pulled onto a shell.
  // Outdoor scenes put sky and distant terrain hundreds of thousands of units out. The
  // viewer sorts splats with fixed-bit keys spread over the whole depth range, so a range
  // that large leaves the subject unsorted (translucent bodies, smeared ground). Moving
  // every splat beyond farRadius onto a thin shell at that radius, along its own ray from
  // the subject and scaled proportionally, keeps the same view from inside the scene while
  // collapsing the depth range. The shell is slightly thick (up to 1.25 x radius) so far
  // splats keep their relative ordering.
  const publish = join(frameDir, 'publish.ply');
  const farRadius = Number(opts['far-radius'] ?? Math.round(300 * camRadius));
  console.log(`Writing publish PLY (leveled, far shell at ${farRadius})...`);
  run([ply, '-r', rotate.join(','), publish], 'publish');
  const centerPly = [-target[0], -target[1], target[2]]; // engine -> PLY space of the leveled file
  const moved = pullFarSplatsToShell(publish, centerPly, farRadius);
  frame.publishPly = publish;
  frame.farShell = { radius: farRadius, movedSplats: moved.moved, maxDistanceBefore: Number(moved.maxBefore.toFixed(1)) };
  renderView(publish, cam, join(frameDir, 'publish_check.webp'), '1280x800');
  frame.thumbnail = renderThumbnail(scene, frame);

  writeFileSync(framePath, `${JSON.stringify(frame, null, 2)}\n`);
  console.log(`Chosen camera: position ${cam.position.join(', ')} target ${cam.target.join(', ')} fov ${cam.fov}`);
  console.log(`Far shell: ${moved.moved} of ${splatCount} splats moved in from up to ${moved.maxBefore.toFixed(0)} units`);
  console.log(`Written ${framePath}, ${publish}, ${join(frameDir, 'publish_check.webp')}, and ${frame.thumbnail.path}`);
}

// In-place edit of a binary little-endian PLY: every splat farther than R from `center`
// is moved to distance R * (1 + 0.25 * (1 - R / d)) along the same ray and its log-scales
// are shifted by ln(d'/d) so it covers the same solid angle. Returns counts.
function pullFarSplatsToShell(path, center, R) {
  const fd = openSync(path, 'r+');
  const head = Buffer.alloc(65536); const hn = readSync(fd, head, 0, head.length, 0);
  const text = head.toString('latin1', 0, hn);
  const end = text.indexOf('end_header\n'); const headerLen = end + 'end_header\n'.length;
  const lines = text.slice(0, end).split('\n');
  const count = Number(lines.find((l) => l.startsWith('element vertex')).split(' ')[2]);
  const props = lines.filter((l) => l.startsWith('property')).map((l) => l.split(' ')[2]);
  const stride = props.length * 4;
  const ix = props.indexOf('x'), iy = props.indexOf('y'), iz = props.indexOf('z');
  const is = [props.indexOf('scale_0'), props.indexOf('scale_1'), props.indexOf('scale_2')];
  const chunkRows = 65536; const buf = Buffer.alloc(chunkRows * stride);
  let row = 0; let pos = headerLen; let moved = 0; let maxBefore = 0;
  while (row < count) {
    const rows = Math.min(chunkRows, count - row);
    readSync(fd, buf, 0, rows * stride, pos);
    let dirty = false;
    for (let r = 0; r < rows; r++) {
      const b = r * stride;
      const x = buf.readFloatLE(b + ix * 4) - center[0], y = buf.readFloatLE(b + iy * 4) - center[1], z = buf.readFloatLE(b + iz * 4) - center[2];
      const d = Math.hypot(x, y, z);
      if (!(d > R)) continue;
      if (d > maxBefore) maxBefore = d;
      const dNew = R * (1 + 0.25 * (1 - R / d)); const f = dNew / d; const lf = Math.log(f);
      buf.writeFloatLE(center[0] + x * f, b + ix * 4); buf.writeFloatLE(center[1] + y * f, b + iy * 4); buf.writeFloatLE(center[2] + z * f, b + iz * 4);
      for (const k of is) buf.writeFloatLE(buf.readFloatLE(b + k * 4) + lf, b + k * 4);
      moved++; dirty = true;
    }
    if (dirty) writeSync(fd, buf, 0, rows * stride, pos);
    pos += rows * stride; row += rows;
  }
  closeSync(fd);
  return { moved, maxBefore };
}
