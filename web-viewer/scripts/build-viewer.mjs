// Builds dist/3d/<slug>/ (the full scene, no AR/VR) and dist/3d/<slug>/vr/ (a reduced scene for
// headsets and phone AR, with the viewer's AR/VR buttons) from one PLY.
//
//   node scripts/build-viewer.mjs <input.ply> [slug] [--no-vr | --vr-only]
//                                 [--vr-splats N] [--vr-sh 0|1|2|3] [--vr-min-opacity a]
//                                 [--vr-framebuffer-scale s]
//
// The /vr build is served at the scene URL plus /vr, behind the same password gate. Why a second
// build instead of one scene for everything: the full 1.5 M splat scenes render fine on a
// desktop GPU but not in a Quest 3 browser or a phone's AR session, where every frame is
// rendered twice (one per eye) at headset resolution and the splats are sorted on the CPU. Published guidance puts the comfortable range for standalone
// Quest 3 at a few hundred thousand splats (PlayCanvas budgets 1 M for mobile with LOD
// streaming; GSVision recommends 700 k and lags at 1.2 M; Meta's native Spatial SDK says 150 k),
// so the first cut was 500 k adaptive. Quest 3 testing (2026-09-25) settled on 350 k uniform at
// framebuffer scale 0.7: 500 k adaptive stuttered on every scene, 400 k uniform still slightly.
// Per scene overrides live in the site registry (site/scenes.json) under "vr".
//
// The VR pipeline (splat-transform):
//   1. drop splats below --vr-min-opacity (default 0.05: ~28% of a typical scene's count and
//      ~1% of its alpha-weighted screen coverage, i.e. sort cost for nothing visible)
//   2. --decimate (uniform, the default) or --decimate-adaptive to --vr-splats. Adaptive merges
//      by local error, so the subject and near ground keep nearly all their detail while far
//      hills and sky give up theirs; but that leaves nearly as many overlapping layers over a
//      dense subject as the full scene, which is what stutters in a headset. Uniform thins
//      everywhere at the same rate.
//   3. SOG with spherical harmonics cut to --vr-sh bands (default 1: band 0 alone shifts the
//      sky and ground tones visibly, bands 2-3 cost shader time for little in a headset)
// The viewer patch then starts the XR session at --vr-framebuffer-scale (default 0.7, i.e. 51%
// fewer pixels per eye), which is the fill-rate lever: decimation barely changes screen coverage
// because the sky and far shell have to cover the view whatever the count.

import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { renderViewerHtml } from '@playcanvas/supersplat-viewer';
import { defaultSettings } from '@playcanvas/supersplat-viewer/settings';
import { loadRegistry } from './site.mjs';
import { writeSocial } from './social.mjs';
import { patchViewerBundle, XR_DEFAULTS } from './viewer-patch.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const project = resolve(here, '..');

// ------------------------------------------------------------------ arguments
const positional = [];
const flags = {};
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === '--no-vr' || a === '--vr-only') flags[a.slice(2)] = true;
  else if (a.startsWith('--')) flags[a.slice(2)] = argv[++i];
  else positional.push(a);
}
const [inputArg, slug = 'scene'] = positional;

if (!inputArg) {
  console.error('Usage: node scripts/build-viewer.mjs <input.ply> [slug] [--no-vr | --vr-only] [--vr-splats N] [--vr-sh n] [--vr-min-opacity a] [--vr-framebuffer-scale s]');
  process.exit(2);
}
if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/u.test(slug)) {
  console.error('Slug must contain only lowercase letters, digits, and single hyphens.');
  process.exit(2);
}
if (flags['no-vr'] && flags['vr-only']) {
  console.error('--no-vr and --vr-only exclude each other.');
  process.exit(2);
}

// The registry is optional here: it only adds per-scene /vr overrides.
const registry = loadRegistry({ required: false });
const registered = Object.hasOwn(registry, slug) ? registry[slug] : null;
// decimate: 'adaptive' merges by local error and keeps subject detail; 'uniform' thins
// everywhere at the same rate. Adaptive leaves nearly as many overlapping layers over a dense
// subject as the full scene (measured: 159 vs 223 layers per pixel 2 m from a group of people,
// against 115 for uniform at the same count), so a scene that stutters only while looking at
// the subject wants 'uniform'.
const VR_DEFAULTS = Object.freeze({ splats: 350000, sh: 1, minOpacity: 0.05, decimate: 'uniform', xrFramebufferScale: XR_DEFAULTS.xrFramebufferScale, xrFarClip: XR_DEFAULTS.xrFarClip, xrFixedFoveation: XR_DEFAULTS.xrFixedFoveation, xrFrameRate: XR_DEFAULTS.xrFrameRate, xrSortEpsilon: XR_DEFAULTS.xrSortEpsilon });
const vrOptions = {
  ...VR_DEFAULTS,
  ...(registered?.vr ?? {}),
  ...(flags['vr-splats'] !== undefined ? { splats: Number(flags['vr-splats']) } : {}),
  ...(flags['vr-sh'] !== undefined ? { sh: Number(flags['vr-sh']) } : {}),
  ...(flags['vr-min-opacity'] !== undefined ? { minOpacity: Number(flags['vr-min-opacity']) } : {}),
  ...(flags['vr-decimate'] !== undefined ? { decimate: flags['vr-decimate'] } : {}),
  ...(flags['vr-framebuffer-scale'] !== undefined ? { xrFramebufferScale: Number(flags['vr-framebuffer-scale']) } : {}),
  ...(flags['vr-far-clip'] !== undefined ? { xrFarClip: Number(flags['vr-far-clip']) } : {}),
  ...(flags['vr-foveation'] !== undefined ? { xrFixedFoveation: Number(flags['vr-foveation']) } : {}),
  ...(flags['vr-frame-rate'] !== undefined ? { xrFrameRate: Number(flags['vr-frame-rate']) } : {}),
  ...(flags['vr-sort-epsilon'] !== undefined ? { xrSortEpsilon: Number(flags['vr-sort-epsilon']) } : {})
};
if (!(Number.isInteger(vrOptions.splats) && vrOptions.splats >= 10000)) throw new Error(`vr.splats must be an integer >= 10000, got ${vrOptions.splats}`);
if (!['adaptive', 'uniform'].includes(vrOptions.decimate)) throw new Error(`vr.decimate must be 'adaptive' or 'uniform', got ${vrOptions.decimate}`);
if (!(vrOptions.xrFarClip >= 1000)) throw new Error(`vr.xrFarClip must be >= 1000, got ${vrOptions.xrFarClip}`);
if (![0, 1, 2, 3].includes(vrOptions.sh)) throw new Error(`vr.sh must be 0..3, got ${vrOptions.sh}`);
if (!(vrOptions.minOpacity >= 0 && vrOptions.minOpacity < 1)) throw new Error(`vr.minOpacity must be in [0, 1), got ${vrOptions.minOpacity}`);
if (!(vrOptions.xrFramebufferScale > 0 && vrOptions.xrFramebufferScale <= 1)) throw new Error(`vr.xrFramebufferScale must be in (0, 1], got ${vrOptions.xrFramebufferScale}`);

const input = resolve(project, inputArg);
const outputRoot = join(project, 'dist');
const output = join(outputRoot, '3d', slug);
const vrOutput = join(output, 'vr');
const cli = join(project, 'node_modules', '@playcanvas', 'splat-transform', 'bin', 'cli.mjs');
const viewerBundle = join(project, 'node_modules', '@playcanvas', 'supersplat-viewer', 'public', 'index.js');
const pristineBundle = readFileSync(viewerBundle, 'utf8');
const gpu = process.env.SPLAT_GPU ?? '0';

// splat-transform 3.4.0: the GPU SOG compressor dies with STATUS_STACK_BUFFER_OVERRUN
// (0xC0000409, no message) when the splat count is odd, and its GPU-initialised decimation
// pass dies the same way on some inputs. So decimation runs on the CPU (it is CPU work
// anyway) and every target count is forced even before the GPU SOG step.
const transform = (args, what, device = gpu) => {
  const result = spawnSync(process.execPath, [cli, '--no-tty', '--gpu', device, '--overwrite', ...args], { stdio: 'inherit' });
  if (result.status !== 0) {
    console.error(`splat-transform failed (${what})`);
    process.exit(result.status ?? 1);
  }
};

// Optional leveling rotation and opening camera from scripts/frame.mjs. Looked up next to
// the PLY (<scene>/frame/frame.json) unless FRAME_JSON points elsewhere; FRAME_JSON=none
// disables it.
const frameCandidate = process.env.FRAME_JSON ?? join(dirname(input), '..', 'frame', 'frame.json');
const frame = frameCandidate !== 'none' && existsSync(frameCandidate) ? JSON.parse(readFileSync(frameCandidate, 'utf8')) : null;
// frame.mjs pass 2 writes a publish PLY with the rotation already baked in and far splats
// pulled onto a shell; use it as-is. Without it, apply the rotation during conversion.
// frame.json records absolute paths, which go stale when a scene folder moves, so the copy
// next to frame.json wins.
const publishPly = frame && [join(dirname(frameCandidate), 'publish.ply'), frame.publishPly].find((p) => p && existsSync(p));
const usePublishPly = Boolean(publishPly);
const source = usePublishPly ? publishPly : input;
const actions = !usePublishPly && frame?.rotate ? ['-r', frame.rotate.join(',')] : [];
const sceneDir = frame ? dirname(dirname(frameCandidate)) : dirname(dirname(input));

const settings = defaultSettings('object');
if (frame?.chosen?.camera) settings.cameras = [{ initial: frame.chosen.camera }];

const viewerHtml = (baseHref, title) =>
  renderViewerHtml({
    bootstrap: {
      contentUrl: './scene.sog',
      settings
    },
    baseHref,
    backgroundColor: [0.025, 0.025, 0.03],
    headExtras: [
      '<meta name="robots" content="noindex,nofollow,noarchive,nosnippet">',
      '<meta name="color-scheme" content="dark">'
    ].join(''),
    inlineCss: true
  }).replace('<title>SuperSplat Viewer</title>', `<title>${title}</title>`);

const frameSummary = frame
  ? { file: frameCandidate, publishPly: usePublishPly ? publishPly : null, rotate: frame.rotate ?? null, farShell: frame.farShell ?? null, camera: frame.chosen?.camera ?? null }
  : null;
const sourceBytes = statSync(input).size;
const mib = (bytes) => Number((bytes / 1048576).toFixed(2));

// ------------------------------------------------------------------ main build
if (!flags['vr-only']) {
  rmSync(output, { recursive: true, force: true });
  mkdirSync(output, { recursive: true });
  const sog = join(output, 'scene.sog');
  transform([source, ...actions, sog], 'main SOG');

  writeFileSync(join(output, 'index.html'), viewerHtml(`/3d/${slug}/`, slug.replaceAll('-', ' ')));
  // Link-preview image from <scene>/thumbnail.jpg; see scripts/social.mjs.
  const social = writeSocial(sceneDir, output);
  // FPS-style gamepad look/move rates, no AR/VR; see scripts/viewer-patch.mjs.
  writeFileSync(join(output, 'index.js'), patchViewerBundle(pristineBundle, { xr: false }));

  const sogBytes = statSync(sog).size;
  const result = {
    source: basename(input),
    sourceDirectory: basename(dirname(input)),
    output: `/3d/${slug}/scene.sog`,
    sourceBytes,
    sogBytes,
    reductionPercent: Number((100 * (1 - sogBytes / sourceBytes)).toFixed(1)),
    sourceMiB: mib(sourceBytes),
    sogMiB: mib(sogBytes),
    frame: frameSummary,
    social,
    vr: flags['no-vr'] ? null : `/3d/${slug}/vr/`
  };
  writeFileSync(join(output, 'build.json'), `${JSON.stringify(result, null, 2)}\n`);
  console.log(JSON.stringify(result, null, 2));
} else if (!existsSync(join(output, 'index.html'))) {
  console.error(`--vr-only needs an existing main build at ${output}`);
  process.exit(2);
}

// ------------------------------------------------------------------ /vr build
if (!flags['no-vr']) {
  rmSync(vrOutput, { recursive: true, force: true });
  mkdirSync(vrOutput, { recursive: true });
  const sog = join(vrOutput, 'scene.sog');
  // The decimated PLY is kept next to publish.ply (or in the temp dir without a frame) so a
  // rebuild with the same settings can be checked with the CLI renderer.
  const vrPly = join(usePublishPly ? dirname(publishPly) : tmpdir(), `vr_${slug}.ply`);
  const cull = vrOptions.minOpacity > 0 ? ['-V', `opacity,gt,${vrOptions.minOpacity}`] : [];
  // --decimate-adaptive has to be the last action and needs a PLY output, hence two passes.
  const target = vrOptions.splats - (vrOptions.splats % 2);
  transform([source, ...actions, ...cull, vrOptions.decimate === 'uniform' ? '--decimate' : '--decimate-adaptive', String(target), vrPly], 'VR decimation', 'cpu');
  transform([vrPly, '-H', String(vrOptions.sh), sog], 'VR SOG');

  // WebXR sessions cannot run on the viewer's WebGPU device (no XRGPUBinding in Quest's
  // browser, nor in Chrome on Android), so the stock page would load on WebGPU and then ask to
  // reload on WebGL when the AR/VR button is pressed. The /vr page starts on WebGL.
  const rendererPick = "url.searchParams.has('webgl') ? 'webgl' : 'webgpu'";
  const vrHtml = viewerHtml(`/3d/${slug}/vr/`, `${slug.replaceAll('-', ' ')} VR`);
  if (vrHtml.split(rendererPick).length !== 2) throw new Error('build-viewer: the viewer HTML no longer picks its renderer with the expected expression; update scripts/build-viewer.mjs.');
  writeFileSync(join(vrOutput, 'index.html'), vrHtml.replace(rendererPick, () => "'webgl' /* XR needs WebGL; see scripts/build-viewer.mjs */"));
  writeFileSync(join(vrOutput, 'index.js'), patchViewerBundle(pristineBundle, { xr: true, xrFramebufferScale: vrOptions.xrFramebufferScale, xrFarClip: vrOptions.xrFarClip, xrFixedFoveation: vrOptions.xrFixedFoveation, xrFrameRate: vrOptions.xrFrameRate, xrSortEpsilon: vrOptions.xrSortEpsilon }));

  const sogBytes = statSync(sog).size;
  const result = {
    source: basename(input),
    sourceDirectory: basename(dirname(input)),
    output: `/3d/${slug}/vr/scene.sog`,
    sourceBytes,
    sogBytes,
    sourceMiB: mib(sourceBytes),
    sogMiB: mib(sogBytes),
    vr: { ...vrOptions, ply: vrPly },
    frame: frameSummary
  };
  writeFileSync(join(vrOutput, 'build.json'), `${JSON.stringify(result, null, 2)}\n`);
  console.log(JSON.stringify(result, null, 2));
}

// The Worker sets Cache-Control on everything it serves; these rules cover direct asset serving.
// (The asset store already types .sog as application/octet-stream; a Content-Type rule here
// would be appended to it, giving a doubled header.)
writeFileSync(join(outputRoot, '_headers'), [
  '/3d/*',
  '  X-Robots-Tag: noindex, nofollow, noarchive, nosnippet',
  '  Referrer-Policy: no-referrer',
  '  X-Content-Type-Options: nosniff',
  '',
  '/3d/*/scene.sog',
  '  Cache-Control: private, max-age=31536000, immutable',
  '',
  '/3d/*/vr/scene.sog',
  '  Cache-Control: private, max-age=31536000, immutable',
  ''
].join('\n'));
