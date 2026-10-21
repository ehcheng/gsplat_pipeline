#!/usr/bin/env node
/**
 * thumbnail.mjs: render a scene's share thumbnail from its chosen opening camera.
 *
 *   node scripts/thumbnail.mjs <scene folder>
 *
 * Reads <scene>/frame/frame.json (written by frame.mjs pass 2), renders frame/publish.ply
 * from the chosen camera, and writes <scene>/thumbnail.jpg: 1920x1280 (3:2), rectilinear
 * (pinhole), with the same vertical field of view as the viewer's opening camera. The
 * render is done at twice that size and downscaled with Lanczos, which supersamples away
 * the aliasing of single-sample splat edges. frame.mjs pass 2 calls this automatically;
 * run it on its own to backfill an older scene.
 *
 * build-viewer.mjs picks thumbnail.jpg up and derives the social-preview image from it.
 */
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const cli = join(here, '..', 'node_modules', '@playcanvas', 'splat-transform', 'bin', 'cli.mjs');

export const THUMBNAIL = { width: 1920, height: 1280, supersample: 2 };
// Matches the viewer's backgroundColor in build-viewer.mjs.
const BACKGROUND = '0.025,0.025,0.03,1';

// Renders <scene>/thumbnail.jpg from frame.chosen.camera and returns the record frame.mjs
// stores as frame.thumbnail. `frame` is the parsed frame.json.
export const renderThumbnail = (scene, frame) => {
  const camera = frame?.chosen?.camera;
  if (!camera) throw new Error(`${scene} has no chosen camera; run frame.mjs pass 2 (--azimuth) first`);
  // frame.json stores absolute paths, which go stale when scene folders move; the publish
  // PLY always sits next to it.
  const local = join(scene, 'frame', 'publish.ply');
  const source = existsSync(local) ? local : frame.publishPly;
  if (!source || !existsSync(source)) throw new Error(`No publish PLY for ${scene}; run frame.mjs pass 2 first`);

  const { width, height, supersample } = THUMBNAIL;
  const raw = join(scene, 'frame', 'thumbnail_raw.webp');
  const out = join(scene, 'thumbnail.jpg');
  const render = spawnSync(process.execPath, [cli, '--no-tty', '-q', '-w', source,
    '--camera-pos', camera.position.join(','), '--camera-target', camera.target.join(','), '--camera-up', '0,1,0',
    '--camera-fov', String(camera.fov), '--projection', 'pinhole', '--background', BACKGROUND,
    '--resolution', `${width * supersample}x${height * supersample}`, raw], { stdio: ['ignore', 'inherit', 'inherit'] });
  if (render.status !== 0) throw new Error(`thumbnail render failed (exit ${render.status})`);
  const ff = spawnSync('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', '-i', raw,
    '-vf', `scale=${width}:${height}:flags=lanczos`, '-q:v', '2', '-frames:v', '1', out], { stdio: ['ignore', 'inherit', 'inherit'] });
  if (ff.status !== 0) throw new Error(`thumbnail JPEG encode failed (exit ${ff.status})`);
  rmSync(raw, { force: true });
  return { path: out, width, height, source, camera, renderedAt: new Date().toISOString() };
};

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const arg = process.argv[2];
  if (!arg) { console.error('Usage: node scripts/thumbnail.mjs <scene folder>'); process.exit(2); }
  const scene = resolve(arg);
  const framePath = join(scene, 'frame', 'frame.json');
  if (!existsSync(framePath)) { console.error(`Missing ${framePath}; run frame.mjs first`); process.exit(1); }
  const frame = JSON.parse(readFileSync(framePath, 'utf8'));
  frame.thumbnail = renderThumbnail(scene, frame);
  writeFileSync(framePath, `${JSON.stringify(frame, null, 2)}\n`);
  console.log(`Thumbnail: ${frame.thumbnail.path} (${frame.thumbnail.width}x${frame.thumbnail.height})`);
}
