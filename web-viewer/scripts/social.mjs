#!/usr/bin/env node
/**
 * social.mjs: write a built scene's link-preview image.
 *
 *   node scripts/social.mjs <scene folder> <slug>
 *
 * Takes <scene>/thumbnail.jpg (1920x1280, from thumbnail.mjs) and writes
 * dist/3d/<slug>/og.jpg, a 1200x800 copy kept under ~300 KB because WhatsApp drops
 * og:images much larger than that, plus social.json describing it. The Worker reads
 * social.json to write the og:/twitter: tags and versions the image URL with its hash, so a
 * re-rendered thumbnail busts the platforms' preview caches. build-viewer.mjs calls this;
 * run it on its own to refresh the preview of an already-built scene without re-encoding
 * the SOG.
 */
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const project = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const OG = { width: 1200, height: 800, maxBytes: 300 * 1024 };

// Returns the social.json record, or null (and removes stale preview files) when the scene
// has no thumbnail.
export const writeSocial = (sceneDir, output) => {
  const thumbnail = join(sceneDir, 'thumbnail.jpg');
  const og = join(output, 'og.jpg');
  const json = join(output, 'social.json');
  if (!existsSync(thumbnail)) {
    rmSync(og, { force: true }); rmSync(json, { force: true });
    console.warn(`No ${thumbnail}; the scene has no social preview image. Run: node scripts/thumbnail.mjs "${sceneDir}"`);
    return null;
  }
  for (const q of [3, 4, 5, 6, 8, 10]) {
    const ff = spawnSync('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', '-i', thumbnail, '-vf', `scale=${OG.width}:${OG.height}:flags=lanczos`, '-q:v', String(q), '-frames:v', '1', og], { stdio: ['ignore', 'inherit', 'inherit'] });
    if (ff.status !== 0) throw new Error(`ffmpeg failed to write ${og}`);
    if (statSync(og).size <= OG.maxBytes) break;
  }
  const bytes = readFileSync(og);
  const social = { image: 'og.jpg', width: OG.width, height: OG.height, type: 'image/jpeg', bytes: bytes.length, version: createHash('sha256').update(bytes).digest('hex').slice(0, 12) };
  writeFileSync(json, `${JSON.stringify(social, null, 2)}\n`);
  return social;
};

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [sceneArg, slug] = process.argv.slice(2);
  if (!sceneArg || !slug) { console.error('Usage: node scripts/social.mjs <scene folder> <slug>'); process.exit(2); }
  const output = join(project, 'dist', '3d', slug);
  if (!existsSync(join(output, 'index.html'))) { console.error(`${output} is not a built scene; run build-viewer.mjs first`); process.exit(1); }
  const social = writeSocial(resolve(sceneArg), output);
  if (social) console.log(JSON.stringify(social, null, 2));
}
