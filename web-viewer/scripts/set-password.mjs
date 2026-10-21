import { runWrangler } from './wrangler.mjs';

const slug = process.argv.slice(2).find((a) => a !== '--');
if (!slug || !/^[a-z0-9]+(?:-[a-z0-9]+)*$/u.test(slug)) {
  throw new Error('Pass a lowercase scene slug, for example: set-password.mjs my-scene');
}
const passwordBinding = `SPLAT_PASSWORD_${slug.replaceAll('-', '_').toUpperCase()}`;

console.log(`Cloudflare will securely prompt for the password used by ${slug} (${passwordBinding}).`);
console.log('Use at least 6 characters. The value will not be displayed or saved locally.');

try {
  const result = runWrangler(['secret', 'put', passwordBinding]);
  if (result.status !== 0) process.exitCode = result.status ?? 1;
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
}
