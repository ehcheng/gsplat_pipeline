// Locates the private site configuration that lives outside the code: the Worker's
// wrangler.jsonc (Cloudflare account, routes, public settings), the scene registry scenes.json,
// and optionally HANDOFF.md for the catalog export. It is <repo>/site/ unless GSPLAT_SITE_DIR
// points elsewhere; site.example/ is the template. Scene folders live in <repo>/_workspace/
// unless GSPLAT_WORKSPACE points elsewhere.
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const project = resolve(dirname(fileURLToPath(import.meta.url)), '..');
export const repo = resolve(project, '..');
export const siteDir = resolve(process.env.GSPLAT_SITE_DIR ?? join(repo, 'site'));
export const workspace = resolve(process.env.GSPLAT_WORKSPACE ?? join(repo, '_workspace'));
export const sitePath = (name) => join(siteDir, name);

export const missingSiteFile = (file) =>
  new Error(`${file} not found. Copy site.example/ to site/ (or set GSPLAT_SITE_DIR to your site folder) and edit it; see README.md.`);

// The registry is optional for building (it only adds per-scene /vr overrides) and required for
// serving and exporting.
export const loadRegistry = ({ required = true } = {}) => {
  const file = sitePath('scenes.json');
  if (!existsSync(file)) {
    if (required) throw missingSiteFile(file);
    return {};
  }
  return JSON.parse(readFileSync(file, 'utf8'));
};

// wrangler.jsonc allows comments and trailing commas. Strip both outside strings, then parse.
export const parseJsonc = (text) => {
  let out = '';
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (c === '"') {
      let j = i + 1;
      while (j < text.length && text[j] !== '"') j += text[j] === '\\' ? 2 : 1;
      out += text.slice(i, j + 1);
      i = j;
    } else if (c === '/' && text[i + 1] === '/') {
      while (i < text.length && text[i] !== '\n') i++;
      out += '\n';
    } else if (c === '/' && text[i + 1] === '*') {
      const end = text.indexOf('*/', i + 2);
      i = end === -1 ? text.length : end + 1;
    } else out += c;
  }
  return JSON.parse(out.replace(/,(\s*[}\]])/gu, '$1'));
};

export const loadWranglerConfig = ({ required = true } = {}) => {
  const file = sitePath('wrangler.jsonc');
  if (!existsSync(file)) {
    if (required) throw missingSiteFile(file);
    return null;
  }
  return parseJsonc(readFileSync(file, 'utf8'));
};
