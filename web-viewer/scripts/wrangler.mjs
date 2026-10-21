// Runs the project's pinned Wrangler with the site's wrangler.jsonc and a project-local
// Cloudflare login (web-viewer/.wrangler-config), so a new shell never picks up some other
// Cloudflare profile.
//
//   node scripts/wrangler.mjs <wrangler arguments>     e.g. whoami, deploy --dry-run, deploy
//
// Wrangler's JS entry is run with this Node: Node 18.20.2+/20.12.2+ refuses to spawn .cmd shims
// without a shell (EINVAL).
import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { missingSiteFile, project, sitePath } from './site.mjs';

const wranglerJs = join(project, 'node_modules', 'wrangler', 'bin', 'wrangler.js');
const NO_CONFIG_NEEDED = new Set(['login', 'logout', 'whoami', '--version', '-v', '--help', '-h']);

export const runWrangler = (args, options = {}) => {
  if (!existsSync(wranglerJs)) throw new Error(`Wrangler is not installed at ${wranglerJs}. Run pnpm install in web-viewer/.`);
  const config = sitePath('wrangler.jsonc');
  const explicit = args.some((a) => a === '--config' || a === '-c' || a.startsWith('--config='));
  const extra = [];
  if (!explicit && existsSync(config)) extra.push('--config', config);
  else if (!explicit && !NO_CONFIG_NEEDED.has(args[0])) throw missingSiteFile(config);
  const result = spawnSync(process.execPath, [wranglerJs, ...args, ...extra], {
    cwd: project,
    env: { ...process.env, XDG_CONFIG_HOME: join(project, '.wrangler-config') },
    stdio: 'inherit',
    ...options
  });
  if (result.error) throw new Error(`Could not start Wrangler: ${result.error.message}`);
  return result;
};

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    // pnpm forwards a literal "--" from `pnpm run wrangler -- <args>`; drop it.
    const args = process.argv.slice(2);
    process.exitCode = runWrangler(args[0] === '--' ? args.slice(1) : args).status ?? 1;
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
