#!/usr/bin/env node
/**
 * export-bridge.mjs: publish the gsplat catalog for a host site's build (the "bridge").
 *
 *   node scripts/export-bridge.mjs <bridge folder> [--site https://example.com]
 *
 * The bridge folder is any folder the host site's build can read (a shared drive, a synced
 * folder, a checkout of the site's repository). --site is the origin that serves /3d/; it
 * defaults to SITE_URL in the vars of site/wrangler.jsonc.
 *
 * Writes, into the bridge folder:
 *   gsplats.json          the catalog: one item per registered scene (see BRIDGE.md)
 *   gsplats.schema.json   JSON Schema for gsplats.json
 *   thumbnails/<slug>/    master.jpg (1920x1280) and WebP crops for cards, heroes and grids
 *   previews/<slug>.mp4   the looping 1920x1080 30 fps wiggle clip from scripts/wiggle.mjs, when
 *                         the scene has one (<scene>/frame/wiggle.mp4); item.preview is null
 *                         otherwise, with a warning
 *   HANDOFF.md            the integration guide: site/HANDOFF.md when the site folder has one,
 *                         otherwise web-viewer/CATALOG.md
 *
 * Inputs: site/scenes.json (the registry the Worker also serves from), dist/3d/<slug>/
 * (build.json, social.json, scene.sog) and _workspace/<source>/ (thumbnail.jpg,
 * frame/frame.json). Run it after a deploy, so the catalog never lists a scene that is not
 * live. It fails, writing nothing, if a registered scene is not built, has no thumbnail, or
 * is missing a required registry field. Thumbnail files are only re-encoded when the master
 * changes, and folders of scenes that left the registry are removed.
 */
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { loadRegistry, loadWranglerConfig, project, sitePath, workspace } from './site.mjs';

const SCHEMA_VERSION = 1;

// Thumbnail variants, all cropped around the focal point from the 3:2 master. The master looks
// straight at the scene's opening target, so the focal point defaults to the image center; a
// scene whose people stand low in the frame (a tall sign behind them, say) sets
// thumbnailFocus in scenes.json so the wide crops keep them whole.
// Ratios cover common layouts: cards 3:2, heroes 16:9, landing rows 21:10, grid cells 1:1.
const CENTER = { x: 0.5, y: 0.5 };
const VARIANTS = [
  { name: '3x2-1920', aspect: [3, 2], width: 1920 },
  { name: '3x2-960', aspect: [3, 2], width: 960 },
  { name: '3x2-480', aspect: [3, 2], width: 480 },
  { name: '16x9-1920', aspect: [16, 9], width: 1920 },
  { name: '16x9-960', aspect: [16, 9], width: 960 },
  { name: '21x10-1680', aspect: [21, 10], width: 1680 },
  { name: '21x10-840', aspect: [21, 10], width: 840 },
  { name: '1x1-1024', aspect: [1, 1], width: 1024 },
  { name: '1x1-480', aspect: [1, 1], width: 480 }
];

const args = process.argv.slice(2);
const siteFlag = args.indexOf('--site');
const siteArg = siteFlag === -1 ? null : args.splice(siteFlag, 2)[1];
const outArg = args[0];
if (!outArg) { console.error('Usage: node scripts/export-bridge.mjs <bridge folder> [--site https://example.com]'); process.exit(2); }
const out = resolve(outArg);
if (!existsSync(out)) { console.error(`Bridge folder ${out} does not exist`); process.exit(1); }
const SITE = String(siteArg ?? loadWranglerConfig({ required: false })?.vars?.SITE_URL ?? '').replace(/\/+$/u, '');
if (!/^https:\/\/[^\s/]+$/u.test(SITE)) {
  console.error('Pass --site https://<host> (the origin that serves /3d/), or set SITE_URL in the vars of site/wrangler.jsonc.');
  process.exit(2);
}

const sha256 = (buf) => createHash('sha256').update(buf).digest('hex');
const fail = (msg) => { console.error(`export-bridge: ${msg}`); process.exit(1); };
const registry = loadRegistry();
const viewerVersion = JSON.parse(readFileSync(join(project, 'node_modules', '@playcanvas', 'supersplat-viewer', 'package.json'), 'utf8')).version;
const previous = (() => { try { return JSON.parse(readFileSync(join(out, 'gsplats.json'), 'utf8')); } catch { return null; } })();
const previousThumb = new Map((previous?.items ?? []).map((i) => [i.slug, i.thumbnail]));

// ------------------------------------------------------------------ validate and gather
const problems = [];
const gathered = [];
for (const [slug, s] of Object.entries(registry)) {
  const where = `scenes.json "${slug}"`;
  if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/u.test(slug)) problems.push(`${where}: slug must be lowercase letters, digits and single hyphens`);
  for (const k of ['title', 'description', 'source']) if (typeof s[k] !== 'string' || !s[k].trim()) problems.push(`${where}: "${k}" must be a non-empty string`);
  if (typeof s.date !== 'string' || !/^\d{4}-\d{2}-\d{2}$/u.test(s.date)) problems.push(`${where}: "date" must be YYYY-MM-DD`);
  if (!(s.passwordBinding === null || typeof s.passwordBinding === 'string')) problems.push(`${where}: "passwordBinding" must be null or a string`);
  const f = s.thumbnailFocus;
  if (f !== undefined && !(f && [f.x, f.y].every((v) => typeof v === 'number' && v >= 0 && v <= 1))) problems.push(`${where}: "thumbnailFocus" must be { x, y } with values from 0 to 1`);
  if (typeof s.unlisted !== 'boolean') problems.push(`${where}: "unlisted" must be true or false (it is required, so nothing is listed by accident)`);
  const loc = s.location;
  if (loc !== undefined) {
    if (!loc || typeof loc !== 'object') problems.push(`${where}: "location" must be an object`);
    else {
      for (const k of ['name', 'locality']) if (typeof loc[k] !== 'string' || !loc[k].trim()) problems.push(`${where}: "location.${k}" must be a non-empty string`);
      if (!['exact', 'city'].includes(loc.precision)) problems.push(`${where}: "location.precision" must be "exact" or "city"`);
      const hasLat = loc.lat !== undefined, hasLng = loc.lng !== undefined;
      if (hasLat !== hasLng) problems.push(`${where}: "location" needs both lat and lng or neither`);
      if (hasLat && !(typeof loc.lat === 'number' && loc.lat >= -90 && loc.lat <= 90)) problems.push(`${where}: "location.lat" must be a number from -90 to 90`);
      if (hasLng && !(typeof loc.lng === 'number' && loc.lng >= -180 && loc.lng <= 180)) problems.push(`${where}: "location.lng" must be a number from -180 to 180`);
      if (loc.precision === 'exact' && !hasLat) problems.push(`${where}: "location.precision" is "exact" but there are no coordinates`);
    }
  }
  const dist = join(project, 'dist', '3d', slug);
  const sceneDir = join(workspace, ...String(s.source ?? '').split('/'));
  const need = { build: join(dist, 'build.json'), sog: join(dist, 'scene.sog'), thumbnail: join(sceneDir, 'thumbnail.jpg') };
  for (const [what, p] of Object.entries(need)) if (!existsSync(p)) problems.push(`${where}: missing ${what} (${p})`);
  gathered.push({ slug, s, dist, sceneDir, ...need });
}
if (problems.length) fail(`not exporting:\n  ${problems.join('\n  ')}`);

// ------------------------------------------------------------------ thumbnails
const encode = (src, dest, [aw, ah], width, focal) => {
  // Largest aw:ah crop of the 1920x1280 master centered on the focal point (clamped to the
  // frame), then scaled.
  const height = Math.round((width * ah) / aw);
  const [W, H] = [1920, 1280];
  const [cw, ch] = W * ah > H * aw ? [Math.round((H * aw) / ah), H] : [W, Math.round((W * ah) / aw)];
  const clamp = (v, max) => Math.max(0, Math.min(max, Math.round(v)));
  const crop = `crop=${cw}:${ch}:${clamp(focal.x * W - cw / 2, W - cw)}:${clamp(focal.y * H - ch / 2, H - ch)}`;
  const r = spawnSync('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', '-i', src, '-vf', `${crop},scale=${width}:${height}:flags=lanczos`,
    '-c:v', 'libwebp', '-quality', '82', '-compression_level', '6', '-frames:v', '1', dest], { stdio: ['ignore', 'inherit', 'inherit'] });
  if (r.status !== 0) fail(`ffmpeg failed on ${dest}`);
  return { width, height };
};
const fileRecord = (rel, extra) => {
  const buf = readFileSync(join(out, rel));
  return { path: rel.replaceAll('\\', '/'), ...extra, bytes: buf.length, sha256: sha256(buf) };
};

const items = [];
for (const g of gathered) {
  const { slug, s } = g;
  const build = JSON.parse(readFileSync(g.build, 'utf8'));
  const social = existsSync(join(g.dist, 'social.json')) ? JSON.parse(readFileSync(join(g.dist, 'social.json'), 'utf8')) : null;
  const framePath = join(g.sceneDir, 'frame', 'frame.json');
  const frame = existsSync(framePath) ? JSON.parse(readFileSync(framePath, 'utf8')) : null;

  const master = readFileSync(g.thumbnail);
  const masterSha = sha256(master);
  const dir = join('thumbnails', slug);
  mkdirSync(join(out, dir), { recursive: true });
  const prior = previousThumb.get(slug);
  const focal = s.thumbnailFocus ? { x: s.thumbnailFocus.x, y: s.thumbnailFocus.y } : CENTER;
  const reuse = prior?.sha256 === masterSha && prior.focalPoint?.x === focal.x && prior.focalPoint?.y === focal.y && Object.values(prior.variants ?? {}).every((v) => existsSync(join(out, v.path)));
  const variants = {};
  if (!reuse || !existsSync(join(out, dir, 'master.jpg'))) copyFileSync(g.thumbnail, join(out, dir, 'master.jpg'));
  variants.master = fileRecord(join(dir, 'master.jpg'), { format: 'jpeg', width: 1920, height: 1280 });
  for (const v of VARIANTS) {
    const rel = join(dir, `${v.name}.webp`);
    const dims = reuse ? { width: prior.variants[v.name].width, height: prior.variants[v.name].height } : encode(g.thumbnail, join(out, rel), v.aspect, v.width, focal);
    variants[v.name] = fileRecord(rel, { format: 'webp', ...dims });
  }
  const isProtected = s.passwordBinding !== null;
  const servedPublicly = Boolean(social) && (s.socialImage ?? !isProtected);

  // Wiggle preview video (scripts/wiggle.mjs). Copied only when its hash changed.
  let preview = null;
  const wigglePath = join(g.sceneDir, 'frame', 'wiggle.mp4');
  const wiggleMetaPath = join(g.sceneDir, 'frame', 'wiggle.json');
  if (existsSync(wigglePath) && existsSync(wiggleMetaPath)) {
    const wiggle = JSON.parse(readFileSync(wiggleMetaPath, 'utf8'));
    const rel = join('previews', `${slug}.mp4`);
    mkdirSync(join(out, 'previews'), { recursive: true });
    const srcBuf = readFileSync(wigglePath);
    const srcSha = sha256(srcBuf);
    const priorPreview = previous?.items?.find((i) => i.slug === slug)?.preview;
    if (!(priorPreview?.video?.sha256 === srcSha && existsSync(join(out, rel)))) writeFileSync(join(out, rel), srcBuf);
    preview = {
      kind: 'wiggle',
      video: fileRecord(rel, { format: 'mp4', width: wiggle.width, height: wiggle.height }),
      codec: 'h264',
      durationSeconds: wiggle.duration,
      fps: wiggle.fps,
      loop: wiggle.loop === true,
      silent: true,
      poster: 'thumbnail.variants.16x9-1920'
    };
  } else {
    console.warn(`  ${slug}: no wiggle preview (run node scripts/wiggle.mjs on ${g.sceneDir})`);
  }

  // Shooting location, hand-entered in the registry (the cameras have no GPS). Protected
  // scenes never export coordinates: a private capture gets a place label at most.
  let location = null;
  if (s.location) {
    const pin = !isProtected && s.location.precision === 'exact' && s.location.lat !== undefined;
    location = {
      name: s.location.name,
      locality: s.location.locality,
      precision: isProtected ? 'city' : s.location.precision,
      lat: pin ? s.location.lat : null,
      lng: pin ? s.location.lng : null,
      mapsUrl: pin ? `https://www.google.com/maps/search/?api=1&query=${s.location.lat},${s.location.lng}` : null
    };
  } else {
    console.warn(`  ${slug}: no location in scenes.json`);
  }

  const item = {
    slug,
    url: `${SITE}/3d/${slug}/`,
    title: s.title,
    description: s.description,
    date: s.date,
    location,
    protected: isProtected,
    unlisted: s.unlisted,
    thumbnail: {
      alt: s.description,
      width: 1920,
      height: 1280,
      aspectRatio: '3:2',
      focalPoint: focal,
      sha256: masterSha,
      servedPublicly,
      publicUrl: servedPublicly ? `${SITE}/3d/${slug}/${social.image}?v=${social.version}` : null,
      variants
    },
    preview,
    scene: {
      format: 'sog',
      bytes: build.sogBytes,
      splatCount: frame?.splats?.total ?? null,
      openingFovDeg: frame?.chosen?.camera?.fov ?? null,
      viewer: `@playcanvas/supersplat-viewer ${viewerVersion} (patched)`,
      embeddable: false
    },
    builtAt: statSync(g.sog).mtime.toISOString()
  };
  item.revision = sha256(JSON.stringify(item)).slice(0, 16);
  items.push(item);
  console.log(`${slug.padEnd(20)} ${isProtected ? 'protected' : 'public   '} ${s.unlisted ? 'unlisted' : 'listed  '} thumbnails ${reuse ? 'unchanged' : 'written'} preview ${preview ? `${(preview.video.bytes / 1048576).toFixed(1)} MiB` : 'none'}`);
}
items.sort((a, b) => b.date.localeCompare(a.date) || a.slug.localeCompare(b.slug));

// Remove thumbnail folders and preview clips of scenes that are no longer registered.
const thumbsRoot = join(out, 'thumbnails');
for (const name of existsSync(thumbsRoot) ? readdirSync(thumbsRoot) : []) {
  if (!Object.hasOwn(registry, name) && statSync(join(thumbsRoot, name)).isDirectory()) {
    rmSync(join(thumbsRoot, name), { recursive: true, force: true });
    console.log(`removed thumbnails/${name} (no longer registered)`);
  }
}
const previewsRoot = join(out, 'previews');
for (const name of existsSync(previewsRoot) ? readdirSync(previewsRoot) : []) {
  const slug = name.replace(/\.mp4$/u, '');
  if (!Object.hasOwn(registry, slug) || !items.find((i) => i.slug === slug)?.preview) {
    rmSync(join(previewsRoot, name), { force: true });
    console.log(`removed previews/${name} (no longer registered or no longer rendered)`);
  }
}

// ------------------------------------------------------------------ write (manifest last, atomically)
const writeAtomic = (name, text) => { const tmp = join(out, `.${name}.tmp`); writeFileSync(tmp, text); renameSync(tmp, join(out, name)); };
writeAtomic('gsplats.schema.json', `${JSON.stringify(schema(), null, 2)}\n`);
// The guide's example is a real item: the newest public, listed scene (or the newest of any).
const example = items.find((i) => !i.protected && !i.unlisted) ?? items[0];
const handoff = existsSync(sitePath('HANDOFF.md')) ? sitePath('HANDOFF.md') : join(project, 'CATALOG.md');
writeAtomic('HANDOFF.md', readFileSync(handoff, 'utf8').replaceAll('{{SITE}}', SITE).replace('EXAMPLE_ITEM', () => JSON.stringify(example, null, 2)));
const manifest = {
  $schema: './gsplats.schema.json',
  schemaVersion: SCHEMA_VERSION,
  generatedAt: new Date().toISOString(),
  generator: 'gsplats repo: web-viewer/scripts/export-bridge.mjs',
  site: SITE,
  basePath: '/3d/',
  count: items.length,
  items
};
writeAtomic('gsplats.json', `${JSON.stringify(manifest, null, 2)}\n`);
console.log(`Wrote ${join(out, 'gsplats.json')} (${items.length} scenes)`);

function schema() {
  const file = {
    type: 'object',
    required: ['path', 'format', 'width', 'height', 'bytes', 'sha256'],
    additionalProperties: false,
    properties: {
      path: { type: 'string', description: 'Relative to the bridge folder, forward slashes.' },
      format: { enum: ['jpeg', 'webp', 'mp4'] },
      width: { type: 'integer' },
      height: { type: 'integer' },
      bytes: { type: 'integer' },
      sha256: { type: 'string', pattern: '^[0-9a-f]{64}$' }
    }
  };
  return {
    $schema: 'https://json-schema.org/draft/2020-12/schema',
    $id: `${SITE}/3d/gsplats.schema.json`,
    title: 'gsplat catalog',
    type: 'object',
    required: ['schemaVersion', 'generatedAt', 'site', 'basePath', 'count', 'items'],
    properties: {
      $schema: { type: 'string' },
      schemaVersion: { const: SCHEMA_VERSION },
      generatedAt: { type: 'string', format: 'date-time' },
      generator: { type: 'string' },
      site: { const: SITE },
      basePath: { const: '/3d/' },
      count: { type: 'integer' },
      items: {
        type: 'array',
        items: {
          type: 'object',
          additionalProperties: false,
          required: ['slug', 'url', 'title', 'description', 'date', 'location', 'protected', 'unlisted', 'thumbnail', 'preview', 'scene', 'builtAt', 'revision'],
          properties: {
            slug: { type: 'string', pattern: '^[a-z0-9]+(?:-[a-z0-9]+)*$' },
            url: { type: 'string', format: 'uri' },
            title: { type: 'string' },
            description: { type: 'string' },
            date: { type: 'string', format: 'date' },
            location: {
              description: 'Shooting location; null when not recorded. Coordinates are null for protected scenes and for "city" precision.',
              oneOf: [
                { type: 'null' },
                {
                  type: 'object',
                  additionalProperties: false,
                  required: ['name', 'locality', 'precision', 'lat', 'lng', 'mapsUrl'],
                  properties: {
                    name: { type: 'string', description: 'Place label for the card, e.g. "Golden Gate Park" or "Portland, OR".' },
                    locality: { type: 'string', description: 'City and region, e.g. "San Francisco, CA".' },
                    precision: { enum: ['exact', 'city'], description: '"exact": lat/lng mark the spot; "city": show the label only.' },
                    lat: { type: ['number', 'null'], minimum: -90, maximum: 90 },
                    lng: { type: ['number', 'null'], minimum: -180, maximum: 180 },
                    mapsUrl: { type: ['string', 'null'], format: 'uri' }
                  }
                }
              ]
            },
            protected: { type: 'boolean' },
            unlisted: { type: 'boolean' },
            thumbnail: {
              type: 'object',
              additionalProperties: false,
              required: ['alt', 'width', 'height', 'aspectRatio', 'focalPoint', 'sha256', 'servedPublicly', 'publicUrl', 'variants'],
              properties: {
                alt: { type: 'string' },
                width: { const: 1920 },
                height: { const: 1280 },
                aspectRatio: { const: '3:2' },
                focalPoint: { type: 'object', required: ['x', 'y'], properties: { x: { type: 'number' }, y: { type: 'number' } } },
                sha256: { type: 'string', pattern: '^[0-9a-f]{64}$' },
                servedPublicly: { type: 'boolean' },
                publicUrl: { type: ['string', 'null'], format: 'uri' },
                variants: {
                  type: 'object',
                  required: ['master', ...VARIANTS.map((v) => v.name)],
                  additionalProperties: file,
                  properties: Object.fromEntries(['master', ...VARIANTS.map((v) => v.name)].map((n) => [n, file]))
                }
              }
            },
            preview: {
              description: 'Looping silent motion-parallax clip for the landing page; null when not rendered.',
              oneOf: [
                { type: 'null' },
                {
                  type: 'object',
                  additionalProperties: false,
                  required: ['kind', 'video', 'codec', 'durationSeconds', 'fps', 'loop', 'silent', 'poster'],
                  properties: {
                    kind: { const: 'wiggle' },
                    video: file,
                    codec: { const: 'h264' },
                    durationSeconds: { type: 'number' },
                    fps: { type: 'integer' },
                    loop: { type: 'boolean', description: 'true: the last frame leads into the first; play with loop, no fade.' },
                    silent: { const: true },
                    poster: { const: 'thumbnail.variants.16x9-1920', description: 'Which thumbnail variant to show until the video plays.' }
                  }
                }
              ]
            },
            scene: {
              type: 'object',
              additionalProperties: false,
              required: ['format', 'bytes', 'splatCount', 'openingFovDeg', 'viewer', 'embeddable'],
              properties: {
                format: { const: 'sog' },
                bytes: { type: 'integer' },
                splatCount: { type: ['integer', 'null'] },
                openingFovDeg: { type: ['number', 'null'] },
                viewer: { type: 'string' },
                embeddable: { type: 'boolean' }
              }
            },
            builtAt: { type: 'string', format: 'date-time' },
            revision: { type: 'string', pattern: '^[0-9a-f]{16}$' }
          }
        }
      }
    }
  };
}
