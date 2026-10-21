import { randomBytes } from 'node:crypto';
import { runWrangler } from './wrangler.mjs';

const putGeneratedSecret = (name, value) => {
  const result = runWrangler(['secret', 'put', name], {
    input: `${value}\n`,
    stdio: ['pipe', 'inherit', 'inherit']
  });
  if (result.status !== 0) throw new Error(`Failed to store ${name}. See Wrangler's error above.`);
};

try {
  console.log('Cloudflare will securely prompt for the Turnstile Secret Key.');
  const turnstile = runWrangler(['secret', 'put', 'TURNSTILE_SECRET_KEY']);
  if (turnstile.status !== 0) throw new Error("Failed to store TURNSTILE_SECRET_KEY. See Wrangler's error above.");

  putGeneratedSecret('SESSION_SECRET', randomBytes(48).toString('base64url'));
  console.log('Turnstile and session secrets saved securely in Cloudflare.');
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
}
