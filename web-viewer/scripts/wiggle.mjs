#!/usr/bin/env node
/**
 * wiggle.mjs: render a short, seamlessly looping "wiggle" video of a scene for a landing page
 * (the catalog export hands it to the host site), so the still thumbnail is replaced by motion parallax before anyone clicks
 * through to the interactive viewer.
 *
 *   node scripts/wiggle.mjs <scene folder> [options]
 *
 * The camera starts at the opening view chosen by frame.mjs (frame/frame.json) and travels once
 * around a small tilted ellipse while looking at the same target: sideways (cos), up and down
 * (sin) and toward/away (sin, phase-shifted), so every axis moves and the parallax reads
 * clearly. One full ellipse per clip means the last frame leads straight back into the first,
 * so the video loops without a cut.
 *
 * Frames are rasterised with splat-transform's headless GPU renderer, loading the publish PLY
 * once and rendering every frame in the same process (the CLI would reload 355 MiB per frame).
 * ffmpeg (on PATH) then encodes H.264 at the requested frame rate.
 *
 * Options:
 *   --ply <path>          PLY to render (default: frame/wiggle_source.ply, an adaptive
 *                         --source-splats decimation of publish.ply, built once and cached;
 *                         the renderer re-uploads and re-sorts every splat per frame, so 1.5 M
 *                         costs 2.5 s a frame against 1.8 s for 500 k, which looks the same
 *                         from the opening view)
 *   --source-splats <n>   decimation target for that source (default 500000; 0 = publish.ply)
 *   --out <path>          output MP4 (default: <scene>/frame/wiggle.mp4)
 *   --duration <s>        seconds per loop (default 6)
 *   --fps <n>             frames per second (default 30; 60 doubles the render time for little on a slow loop)
 *   --width/--height      resolution (default 1920x1080)
 *   --sway <fraction>     sideways half-amplitude as a fraction of camera distance (default 0.07)
 *   --bob <fraction>      vertical half-amplitude (default 0.035)
 *   --dolly <fraction>    toward/away half-amplitude (default 0.03)
 *   --fov <deg>           override the vertical field of view
 *   --crf <n>             x264 quality (default 18)
 *   --frames <n>          render only the first n frames (for a quick check)
 *   --keep                keep the frame PNG/WebP folder after encoding
 */
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { realpathSync } from 'node:fs';

const here = dirname(fileURLToPath(import.meta.url));
const project = resolve(here, '..');

// ------------------------------------------------------------------ arguments
const argv = process.argv.slice(2);
const opts = { duration: 6, fps: 30, width: 1920, height: 1080, sway: 0.07, bob: 0.035, dolly: 0.03, crf: 18 };
let scene = null;
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === '--keep') opts.keep = true;
  else if (a.startsWith('--')) opts[a.slice(2)] = argv[++i];
  else if (!scene) scene = a;
  else throw new Error(`Unexpected argument ${a}`);
}
if (!scene) {
  console.error('Usage: node scripts/wiggle.mjs <scene folder> [--duration s] [--fps n] [--width w] [--height h] [--sway f] [--bob f] [--dolly f] [--fov deg] [--out file]');
  process.exit(2);
}
for (const k of ['duration', 'fps', 'width', 'height', 'sway', 'bob', 'dolly', 'fov', 'crf', 'frames']) if (opts[k] !== undefined) opts[k] = Number(opts[k]);
scene = resolve(scene);
const frameDir = join(scene, 'frame');
const framePath = join(frameDir, 'frame.json');
if (!existsSync(framePath)) throw new Error(`Missing ${framePath}; run scripts/frame.mjs first (both passes).`);
const frame = JSON.parse(readFileSync(framePath, 'utf8'));
if (!frame.chosen?.camera) throw new Error('frame.json has no chosen camera; run frame.mjs pass 2 (--azimuth).');
const publishPly = join(frameDir, 'publish.ply');
if (!existsSync(publishPly)) throw new Error(`Missing ${publishPly}; run scripts/frame.mjs pass 2.`);
const sourceSplats = opts['source-splats'] !== undefined ? Number(opts['source-splats']) : 500000;
let ply;
if (opts.ply) {
  ply = resolve(opts.ply);
} else if (sourceSplats > 0) {
  // Cached decimated source. Adaptive keeps subject detail; the target is kept even (see
  // scripts/build-viewer.mjs on the splat-transform 3.4.0 GPU crashes).
  ply = join(frameDir, 'wiggle_source.ply');
  const wanted = sourceSplats - (sourceSplats % 2);
  const stamp = join(frameDir, 'wiggle_source.json');
  const fresh = existsSync(ply) && existsSync(stamp) && JSON.parse(readFileSync(stamp, 'utf8')).splats === wanted;
  if (!fresh) {
    console.log(`Decimating ${publishPly} to ${wanted} splats for the wiggle source...`);
    const cli = join(project, 'node_modules', '@playcanvas', 'splat-transform', 'bin', 'cli.mjs');
    const r = spawnSync(process.execPath, [cli, '--no-tty', '-q', '--gpu', process.env.SPLAT_GPU ?? '0', '--overwrite', publishPly, '--decimate-adaptive', String(wanted), ply], { stdio: 'inherit' });
    if (r.status !== 0) throw new Error(`splat-transform decimation failed (${r.status})`);
    writeFileSync(stamp, `${JSON.stringify({ splats: wanted, from: publishPly, generatedAt: new Date().toISOString() })}\n`);
  }
} else {
  ply = publishPly;
}
if (!existsSync(ply)) throw new Error(`Missing ${ply}`);
const out = opts.out ? resolve(opts.out) : join(frameDir, 'wiggle.mp4');
const totalFrames = Math.round(opts.duration * opts.fps);
const renderFrames = opts.frames ? Math.min(opts.frames, totalFrames) : totalFrames;

// ------------------------------------------------------------------ splat-transform + WebGPU in Node
// The library's peer packages (playcanvas, the webgpu binding) sit in pnpm's store next to it,
// not in this project's node_modules, so resolve them from the package's own location.
const stDir = realpathSync(join(project, 'node_modules', '@playcanvas', 'splat-transform'));
const stRequire = createRequire(join(stDir, 'package.json'));
const st = await import('@playcanvas/splat-transform');
const pc = await import(pathToFileURL(join(dirname(stRequire.resolve('playcanvas')), 'playcanvas.mjs')).href);
const webgpu = await import(pathToFileURL(stRequire.resolve('webgpu')).href);

// Same DOM stubs the CLI installs before creating a device.
Object.assign(globalThis, webgpu.globals);
globalThis.window = { navigator: { userAgent: 'node.js' } };
globalThis.document = {
  createElement: (type) => (type === 'canvas'
    ? { getContext: () => null, getBoundingClientRect: () => ({ left: 0, top: 0, width: 300, height: 150, right: 300, bottom: 150 }), width: 300, height: 150 }
    : undefined)
};
let device = null;
const createDevice = async () => {
  if (device) return device;
  window.navigator.gpu = webgpu.create(process.env.SPLAT_GPU_ADAPTER ? [`adapter=${process.env.SPLAT_GPU_ADAPTER}`] : []);
  const canvas = document.createElement('canvas');
  canvas.width = 1024; canvas.height = 512;
  device = new pc.WebgpuGraphicsDevice(canvas, { antialias: false, depth: false, stencil: false });
  await device.createDevice();
  device.wgpu?.addEventListener?.('uncapturederror', (ev) => { throw new Error(`WebGPU error: ${ev?.error?.message ?? ev}`); });
  return device;
};

// ------------------------------------------------------------------ load the scene once
console.log(`Loading ${ply} ...`);
const t0 = performance.now();
const readFs = new st.MemoryReadFileSystem();
readFs.set('scene.ply', new Uint8Array(readFileSync(ply)));
const sources = await st.readFile({ filename: 'scene.ply', inputFormat: 'ply', fileSystem: readFs });
const pool = st.createChunkDataPool();
const dataTable = await st.materializeToDataTable(sources[0], pool);
for (const s of sources) await s.close?.();
console.log(`Loaded ${dataTable.numRows} splats in ${((performance.now() - t0) / 1000).toFixed(1)} s`);

// ------------------------------------------------------------------ camera path
const cam = frame.chosen.camera;
const P = cam.position, T = cam.target;
const fov = opts.fov ?? cam.fov ?? 60;
const sub = (a, b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
const norm = (a) => Math.hypot(a[0], a[1], a[2]);
const unit = (a) => { const n = norm(a); return [a[0] / n, a[1] / n, a[2] / n]; };
const cross = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
const forward = unit(sub(T, P));
const right = unit(cross(forward, [0, 1, 0]));
const up = cross(right, forward);
const distance = norm(sub(T, P));
const A = opts.sway * distance, B = opts.bob * distance, C = opts.dolly * distance;
const poseAt = (i) => {
  const th = (2 * Math.PI * i) / totalFrames;
  const sx = A * Math.cos(th), sy = B * Math.sin(th), sz = C * Math.sin(th + Math.PI / 4);
  return {
    x: P[0] + right[0] * sx + up[0] * sy + forward[0] * sz,
    y: P[1] + right[1] * sx + up[1] * sy + forward[1] * sz,
    z: P[2] + right[2] * sx + up[2] * sy + forward[2] * sz
  };
};

// ------------------------------------------------------------------ render frames
const framesDir = join(frameDir, 'wiggle_frames');
rmSync(framesDir, { recursive: true, force: true });
mkdirSync(framesDir, { recursive: true });
const memFs = new st.MemoryFileSystem();
const t1 = performance.now();
for (let i = 0; i < renderFrames; i++) {
  const name = `frame_${String(i).padStart(4, '0')}.webp`;
  await st.writeImage({
    filename: name,
    dataTable,
    cameraPosition: poseAt(i),
    lookAt: { x: T[0], y: T[1], z: T[2] },
    up: { x: 0, y: 1, z: 0 },
    fov,
    width: opts.width,
    height: opts.height,
    background: { r: 0.025, g: 0.025, b: 0.03, a: 1 },
    createDevice
  }, memFs);
  writeFileSync(join(framesDir, name), memFs.results.get(name));
  memFs.results.delete(name);
  if (i % 30 === 0 || i === renderFrames - 1) {
    const per = (performance.now() - t1) / (i + 1);
    process.stdout.write(`\r  frame ${i + 1}/${renderFrames}  ${(per / 1000).toFixed(2)} s/frame  eta ${((renderFrames - i - 1) * per / 1000).toFixed(0)} s   `);
  }
}
process.stdout.write('\n');

// ------------------------------------------------------------------ encode
// yuv420p + faststart for universal playback; the frame count is an exact loop so no fades.
const ff = spawnSync('ffmpeg', [
  '-hide_banner', '-loglevel', 'error', '-y',
  '-framerate', String(opts.fps), '-i', join(framesDir, 'frame_%04d.webp'),
  '-c:v', 'libx264', '-preset', 'slow', '-crf', String(opts.crf), '-pix_fmt', 'yuv420p',
  '-r', String(opts.fps), '-movflags', '+faststart', '-an', out
], { stdio: 'inherit' });
if (ff.status !== 0) throw new Error(`ffmpeg failed (${ff.status})`);
if (!opts.keep) rmSync(framesDir, { recursive: true, force: true });

const meta = {
  scene, ply, output: out, duration: renderFrames / opts.fps, fps: opts.fps, width: opts.width, height: opts.height,
  frames: renderFrames, loop: renderFrames === totalFrames, camera: { position: P, target: T, fov },
  path: { sway: A, bob: B, dolly: C, distance }, renderSeconds: Number(((performance.now() - t1) / 1000).toFixed(1)), generatedAt: new Date().toISOString()
};
writeFileSync(join(frameDir, 'wiggle.json'), `${JSON.stringify(meta, null, 2)}\n`);
console.log(JSON.stringify(meta, null, 2));
device?.destroy?.();
process.exit(0);
