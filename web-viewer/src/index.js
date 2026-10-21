// "gsplat-scenes" is the site's scenes.json, mapped by the "alias" entry in site/wrangler.jsonc.
import sceneRegistry from 'gsplat-scenes';

const ROOT = '/3d';
// The scene registry lives in the site folder (site/scenes.json) so the catalog export
// (scripts/export-bridge.mjs) reads the same data. Per slug:
//   title            page title, link-preview title, catalog title
//   description      one factual sentence; link-preview text for public scenes
//   date             capture date (YYYY-MM-DD)
//   source           scene folder under _workspace/ (thumbnail, frame.json)
//   passwordBinding  null = public; otherwise the Worker secret holding the password
//   unlisted         true = marked unlisted in the catalog, so a host site leaves it out of its
//                    library and search (direct link only)
//   socialImage      optional; true publishes a protected scene's og.jpg link preview
//   thumbnailFocus   optional { x, y } 0-1; crop center for the catalog's thumbnail variants
//   location         optional, hand-entered: { name, locality, lat, lng, precision: "exact" |
//                    "city" }. lat/lng optional; a city or state is often enough. Only the
//                    catalog export reads it, and it never exports coordinates for a protected
//                    scene (no map pins on private captures).
//   vr               optional build overrides for the /vr variant: { splats, sh, minOpacity,
//                    xrFramebufferScale }; see scripts/build-viewer.mjs for the defaults
// Every scene also has /3d/<slug>/vr/: the same scene decimated for headsets and phone AR,
// with the viewer's AR/VR buttons (the main page hides them). It is a subpath of the scene, so
// the same password gate and session cover it, and it is not listed anywhere.
// Public scenes expose /3d/<slug>/og.jpg (built by scripts/social.mjs) as their og:image.
// Protected scenes keep it behind the login, so their links preview with title and text only.
//
// Site settings come from "vars" in site/wrangler.jsonc:
//   SITE_NAME                    og:site_name and the brand on the login page
//   SITE_URL                     optional; where the login page's brand links to
//   GSPLAT_INDEX_URL             optional; /3d and /3d/ redirect here (404 without it)
//   TURNSTILE_SITE_KEY           public key of the Turnstile widget on the login page
//   TURNSTILE_EXPECTED_HOSTNAME  optional; defaults to the request's own host name
//   SESSION_TTL_SECONDS          optional; login lifetime, default 86400
const SCENES = Object.freeze(sceneRegistry);
const TURNSTILE_ACTION = 'gsplat_login';
const encoder = new TextEncoder();

const sceneFromPath = (pathname) => {
  const match = /^\/3d\/([a-z0-9-]+)(?:\/|$)/u.exec(pathname);
  if (!match || !Object.hasOwn(SCENES, match[1])) return null;
  const scene = SCENES[match[1]];
  return scene ? { slug: match[1], ...scene } : null;
};

const scenePaths = (slug) => {
  const root = `${ROOT}/${slug}`;
  return { root, login: `${root}/login`, logout: `${root}/logout` };
};

const cookieName = (slug) => `__Host-gsplat-${slug}`;

const siteName = (env) => (typeof env.SITE_NAME === 'string' && env.SITE_NAME.trim() ? env.SITE_NAME.trim() : 'Gaussian splats');
const siteUrl = (env) => (/^https:\/\/[^\s"<>]+$/u.test(env.SITE_URL ?? '') ? env.SITE_URL : null);

const securityHeaders = {
  'Referrer-Policy': 'no-referrer',
  'X-Content-Type-Options': 'nosniff',
  'X-Frame-Options': 'DENY',
  'X-Robots-Tag': 'noindex, nofollow, noarchive, nosnippet'
};

const loginCsp = [
  "default-src 'none'",
  "script-src https://challenges.cloudflare.com",
  "frame-src https://challenges.cloudflare.com",
  "connect-src https://challenges.cloudflare.com",
  "style-src 'unsafe-inline'",
  "img-src 'self' data:",
  "form-action 'self'",
  "base-uri 'none'",
  "frame-ancestors 'none'"
].join('; ');

const base64url = (bytes) => {
  let binary = '';
  const view = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  for (const byte of view) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/u, '');
};

const fromBase64url = (value) => {
  const padded = value.replaceAll('-', '+').replaceAll('_', '/') + '='.repeat((4 - (value.length % 4)) % 4);
  const binary = atob(padded);
  return Uint8Array.from(binary, (char) => char.charCodeAt(0));
};

const timingSafePasswordMatch = async (submitted, expected) => {
  const [left, right] = await Promise.all([
    crypto.subtle.digest('SHA-256', encoder.encode(submitted)),
    crypto.subtle.digest('SHA-256', encoder.encode(expected))
  ]);
  return crypto.subtle.timingSafeEqual(left, right);
};

const signingKey = (secret) =>
  crypto.subtle.importKey('raw', encoder.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, [
    'sign',
    'verify'
  ]);

const sessionTtl = (env) => {
  const configured = Number(env.SESSION_TTL_SECONDS ?? 86400);
  return Number.isSafeInteger(configured) && configured >= 300 && configured <= 2592000 ? configured : 86400;
};

const createSession = async (env, slug) => {
  const expires = Math.floor(Date.now() / 1000) + sessionTtl(env);
  const nonce = base64url(crypto.getRandomValues(new Uint8Array(16)));
  const payload = `v1.${expires}.${slug}.${nonce}`;
  const key = await signingKey(env.SESSION_SECRET);
  const signature = await crypto.subtle.sign('HMAC', key, encoder.encode(payload));
  return `${payload}.${base64url(signature)}`;
};

const parseCookies = (request) => {
  const result = new Map();
  for (const part of (request.headers.get('Cookie') ?? '').split(';')) {
    const separator = part.indexOf('=');
    if (separator === -1) continue;
    result.set(part.slice(0, separator).trim(), part.slice(separator + 1).trim());
  }
  return result;
};

const hasValidSession = async (request, env, slug) => {
  const value = parseCookies(request).get(cookieName(slug));
  if (!value || !env.SESSION_SECRET) return false;
  const pieces = value.split('.');
  if (pieces.length !== 5 || pieces[0] !== 'v1' || pieces[2] !== slug) return false;

  const expires = Number(pieces[1]);
  const now = Math.floor(Date.now() / 1000);
  if (!Number.isSafeInteger(expires) || expires <= now || expires > now + sessionTtl(env) + 60) return false;

  try {
    const payload = pieces.slice(0, 4).join('.');
    const key = await signingKey(env.SESSION_SECRET);
    return await crypto.subtle.verify('HMAC', key, fromBase64url(pieces[4]), encoder.encode(payload));
  } catch {
    return false;
  }
};

const safeNext = (value, sceneRoot) => {
  if (typeof value !== 'string') return `${sceneRoot}/`;
  try {
    const decoded = decodeURIComponent(value);
    return decoded === sceneRoot || decoded.startsWith(`${sceneRoot}/`) ? decoded : `${sceneRoot}/`;
  } catch {
    return `${sceneRoot}/`;
  }
};

const escapeHtml = (value) =>
  value.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

const socialImageIsPublic = (scene) => scene.socialImage ?? !scene.passwordBinding;

// social.json is written next to the scene by scripts/social.mjs. It is read straight from
// the asset store, so it never needs to be publicly reachable.
const loadSocial = async (env, url, slug) => {
  try {
    const response = await env.ASSETS.fetch(new Request(`${url.origin}${ROOT}/${slug}/social.json`));
    return response.ok ? await response.json() : null;
  } catch {
    return null;
  }
};

// Open Graph and Twitter card tags for the scene page and its login page. Crawlers that land
// on a protected scene follow the redirect to the login page, which carries the same tags.
const socialTags = (env, scene, url, social) => {
  // Always https: several platforms drop http og:images, and production is https-only anyway.
  const pageUrl = `https://${url.host}${ROOT}/${scene.slug}/`;
  // A protected scene's own description stays behind the login with the rest of it.
  const description = scene.passwordBinding
    ? 'Private interactive 3D capture. Password required.'
    : scene.description
      ? `${scene.description} Interactive 3D capture.`
      : 'Interactive 3D capture. Drag to look around.';
  const tags = [
    ['property', 'og:type', 'website'],
    ['property', 'og:site_name', siteName(env)],
    ['property', 'og:title', scene.title],
    ['property', 'og:description', description],
    ['property', 'og:url', pageUrl],
    ['name', 'description', description],
    ['name', 'twitter:title', scene.title],
    ['name', 'twitter:description', description]
  ];
  if (social && socialImageIsPublic(scene)) {
    const image = `${pageUrl}${social.image}?v=${social.version}`;
    tags.push(
      ['property', 'og:image', image],
      ['property', 'og:image:secure_url', image],
      ['property', 'og:image:type', social.type],
      ['property', 'og:image:width', String(social.width)],
      ['property', 'og:image:height', String(social.height)],
      ['property', 'og:image:alt', scene.title],
      ['name', 'twitter:card', 'summary_large_image'],
      ['name', 'twitter:image', image],
      ['name', 'twitter:image:alt', scene.title]
    );
  } else {
    tags.push(['name', 'twitter:card', 'summary']);
  }
  return tags.map(([attr, key, value]) => `<meta ${attr}="${key}" content="${escapeHtml(value)}">`).join('\n  ');
};

const loginHtml = (env, scene, paths, next, message = '', social = '') => {
  const siteKey = /^[A-Za-z0-9_-]+$/u.test(env.TURNSTILE_SITE_KEY ?? '') ? env.TURNSTILE_SITE_KEY : '';
  const escapedNext = escapeHtml(next);
  const error = message ? `<p class="error" role="alert">${escapeHtml(message)}</p>` : '';
  const stackClass = message ? 'form-stack has-error' : 'form-stack';
  const home = siteUrl(env);
  const brand = home
    ? `<a class="brand" href="${escapeHtml(home)}">${escapeHtml(siteName(env))}</a>`
    : `<span class="brand">${escapeHtml(siteName(env))}</span>`;
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <meta name="robots" content="noindex,nofollow,noarchive,nosnippet">
  <title>${escapeHtml(scene.title)} — Private view</title>
  ${social}
  <script src="https://challenges.cloudflare.com/turnstile/v0/api.js" async defer></script>
  <style>
    :root { color-scheme: dark; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif; }
    * { box-sizing: border-box; }
    html, body { margin: 0; min-height: 100%; background: #0a0a0a; }
    body { min-height: 100vh; color: #e0e0e0; -webkit-font-smoothing: antialiased; }
    nav { position: fixed; inset: 0 0 auto; z-index: 10; height: 56px; display: flex; align-items: center; padding: 0 24px; background: rgba(10,10,10,.92); backdrop-filter: blur(12px); }
    .brand { color: #e0e0e0; font-size: 22px; font-weight: 700; letter-spacing: .075em; text-decoration: none; text-transform: uppercase; white-space: nowrap; transition: color .2s ease; }
    .brand:hover { color: #fff; }
    main { min-height: 100vh; display: flex; align-items: center; justify-content: center; padding: 96px 24px 80px; }
    .gate { width: min(100%, 400px); padding: 36px 36px 28px; border: 1px solid rgba(255,255,255,.06); border-radius: 12px; background: #141414; box-shadow: 0 8px 32px rgba(0,0,0,.5); }
    .eyebrow { margin: 0 0 10px; color: rgba(224,224,224,.5); font-size: 11px; font-weight: 500; letter-spacing: .5px; text-transform: uppercase; }
    h1 { margin: 0 0 10px; color: #e0e0e0; font-size: 28px; font-weight: 600; line-height: 1.18; }
    .intro { margin: 0 0 28px; color: rgba(224,224,224,.5); font-size: 15px; line-height: 1.7; text-wrap: pretty; }
    .form-stack { display: flex; flex-direction: column; gap: 16px; }
    .has-error { animation: gate-shake .4s ease; }
    .field { display: flex; flex-direction: column; gap: 8px; }
    label { color: rgba(224,224,224,.5); font-size: 12px; font-weight: 500; letter-spacing: .5px; text-transform: uppercase; }
    input { width: 100%; height: 44px; padding: 0 14px; border: 1px solid rgba(255,255,255,.12); border-radius: 4px; background: #1e1e1e; color: #e0e0e0; font: inherit; font-size: 15px; outline: none; transition: border-color .2s ease, box-shadow .2s ease; }
    input:focus { border-color: rgba(212,168,83,.5); box-shadow: 0 0 0 3px rgba(212,168,83,.08); }
    .has-error input { border-color: #e08b8b; }
    .error { margin: 0; color: #e08b8b; font-size: 12.5px; line-height: 1.45; }
    .turnstile { min-height: 65px; overflow: hidden; border-radius: 4px; }
    button { width: 100%; min-height: 44px; padding: 12px 28px; border: 0; border-radius: 8px; background: #d4a853; color: #0a0a0a; font: inherit; font-size: 14px; font-weight: 500; cursor: pointer; transition: opacity .2s ease, transform .1s ease; }
    button:hover { opacity: .85; }
    button:active { transform: translateY(1px); }
    button:focus-visible { outline: 2px solid #e0c07f; outline-offset: 3px; }
    .privacy { margin: 20px 0 0; color: rgba(224,224,224,.3); font-size: 12px; line-height: 1.7; text-wrap: pretty; }
    @keyframes gate-shake { 0%,100% { transform: translateX(0); } 20% { transform: translateX(-6px); } 40% { transform: translateX(6px); } 60% { transform: translateX(-4px); } 80% { transform: translateX(4px); } }
    @media (max-width: 460px) {
      nav { padding: 0 20px; }
      main { padding: 80px 16px 40px; }
      .gate { padding: 30px 24px 24px; }
      h1 { font-size: 25px; }
    }
    @media (prefers-reduced-motion: reduce) {
      *, *::before, *::after { animation-duration: .01ms !important; transition-duration: .01ms !important; }
    }
  </style>
</head>
<body>
  <nav aria-label="Site">${brand}</nav>
  <main>
    <form class="gate" method="post" action="${paths.login}" autocomplete="off">
      <input type="hidden" name="next" value="${escapedNext}">
      <p class="eyebrow">Private 3D capture</p>
      <h1>${escapeHtml(scene.title)}</h1>
      <p class="intro">Enter the shared password to open the interactive view.</p>
      <div class="${stackClass}">
        <div class="field">
          <label for="password">Password</label>
          <input id="password" name="password" type="password" required autocomplete="current-password" autofocus>
          ${error}
        </div>
        <div class="turnstile cf-turnstile" data-sitekey="${siteKey}" data-action="${TURNSTILE_ACTION}" data-theme="dark"></div>
        <button id="submit" type="submit">Open viewer</button>
      </div>
      <p class="privacy">Turnstile checks the login attempt for abuse. The password is sent only to this Cloudflare Worker over HTTPS.</p>
    </form>
  </main>
</body>
</html>`;
};

const pageResponse = async (env, url, scene, paths, next, message = '', status = 200) =>
  new Response(loginHtml(env, scene, paths, next, message, socialTags(env, scene, url, await loadSocial(env, url, scene.slug))), {
    status,
    headers: {
      ...securityHeaders,
      'Cache-Control': 'no-store',
      'Content-Security-Policy': loginCsp,
      'Content-Type': 'text/html; charset=utf-8'
    }
  });

const verifyTurnstile = async (request, env, token) => {
  const body = new URLSearchParams({
    secret: env.TURNSTILE_SECRET_KEY,
    response: token,
    idempotency_key: crypto.randomUUID()
  });
  const remoteIp = request.headers.get('CF-Connecting-IP');
  if (remoteIp) body.set('remoteip', remoteIp);

  try {
    const response = await fetch('https://challenges.cloudflare.com/turnstile/v0/siteverify', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body,
      signal: AbortSignal.timeout(10000)
    });
    if (!response.ok) return false;
    const result = await response.json();
    const usingOfficialTestKey = env.TURNSTILE_SITE_KEY === '1x00000000000000000000AA';
    const valid =
      result.success === true &&
      (usingOfficialTestKey ||
        (result.action === TURNSTILE_ACTION &&
          result.hostname === (env.TURNSTILE_EXPECTED_HOSTNAME || new URL(request.url).hostname)));
    if (!valid) {
      console.warn(
        JSON.stringify({
          event: 'turnstile_rejected',
          success: result.success === true,
          action: result.action ?? null,
          hostname: result.hostname ?? null,
          errors: result['error-codes'] ?? []
        })
      );
    }
    return valid;
  } catch {
    return false;
  }
};

const redirect = (location, headers = {}) =>
  new Response(null, { status: 303, headers: { ...securityHeaders, Location: location, ...headers } });

const protectedSceneConfigured = (env, scene) =>
  Boolean(
    env.ASSETS &&
      scene.passwordBinding &&
      env[scene.passwordBinding] &&
      env.SESSION_SECRET &&
      env.TURNSTILE_SECRET_KEY &&
      env.TURNSTILE_SITE_KEY
  );

const assetResponse = async (request, env, scene, cacheControl = 'private, no-cache') => {
  const asset = await env.ASSETS.fetch(request);
  const headers = new Headers(asset.headers);
  for (const [name, value] of Object.entries(securityHeaders)) headers.set(name, value);
  headers.set('Cache-Control', cacheControl);
  const response = new Response(asset.body, { status: asset.status, statusText: asset.statusText, headers });
  if (!asset.ok || !asset.body || !(headers.get('Content-Type') ?? '').startsWith('text/html')) return response;

  // The viewer page: the registry's title replaces the builder's slug-derived one, and the
  // link-preview tags go into <head>.
  const url = new URL(request.url);
  const tags = socialTags(env, scene, url, await loadSocial(env, url, scene.slug));
  headers.delete('Content-Length');
  headers.delete('ETag');
  return new HTMLRewriter()
    .on('title', { element: (element) => element.setInnerContent(scene.title) })
    .on('head', { element: (element) => element.append(tags, { html: true }) })
    .transform(response);
};

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    // Not every zone upgrades http to https, so the Worker does it for /3d: the session cookie is
    // Secure (a plain-http login could never stick) and a password must not be typed into an
    // http page. 308 keeps the method. No HSTS header here: HSTS applies to the whole host,
    // which would force https on the rest of the site too.
    if (url.protocol === 'http:') {
      url.protocol = 'https:';
      return new Response(null, { status: 308, headers: { ...securityHeaders, Location: url.toString() } });
    }

    // /3d and /3d/ are the collection, which lives on the host site (GSPLAT_INDEX_URL). The
    // Worker never lists scenes itself: only the host site's catalog page applies "unlisted".
    if (url.pathname === ROOT || url.pathname === `${ROOT}/`) {
      const index = /^https:\/\/[^\s]+$/u.test(env.GSPLAT_INDEX_URL ?? '') ? env.GSPLAT_INDEX_URL : null;
      return index
        ? new Response(null, { status: 302, headers: { ...securityHeaders, Location: index, 'Cache-Control': 'no-store' } })
        : new Response('Not found', { status: 404, headers: securityHeaders });
    }

    const scene = sceneFromPath(url.pathname);
    if (!scene) return new Response('Not found', { status: 404, headers: securityHeaders });
    const paths = scenePaths(scene.slug);

    // Link-preview crawlers cannot log in, so the preview image is served without a session
    // wherever the scene allows it. The ?v= hash in og:image makes it safe to cache.
    if (url.pathname === `${paths.root}/og.jpg` && socialImageIsPublic(scene) && ['GET', 'HEAD'].includes(request.method)) {
      return assetResponse(request, env, scene, 'public, max-age=86400');
    }

    if (!scene.passwordBinding) {
      if (!['GET', 'HEAD'].includes(request.method)) {
        return new Response('Method not allowed', {
          status: 405,
          headers: { ...securityHeaders, Allow: 'GET, HEAD' }
        });
      }
      return assetResponse(request, env, scene);
    }

    if (!protectedSceneConfigured(env, scene)) {
      return new Response('Private viewer login is not configured.', {
        status: 503,
        headers: { ...securityHeaders, 'Cache-Control': 'no-store' }
      });
    }

    if (url.pathname === paths.login && request.method === 'GET') {
      const next = safeNext(url.searchParams.get('next'), paths.root);
      if (await hasValidSession(request, env, scene.slug)) return redirect(next);
      return pageResponse(env, url, scene, paths, next);
    }

    if (url.pathname === paths.login && request.method === 'POST') {
      const form = await request.formData();
      const next = safeNext(form.get('next'), paths.root);
      const password = form.get('password');
      const token = form.get('cf-turnstile-response');
      if (
        typeof password !== 'string' ||
        password.length === 0 ||
        password.length > 256 ||
        typeof token !== 'string' ||
        token.length === 0 ||
        token.length > 2048
      ) {
        return pageResponse(env, url, scene, paths, next, 'The login could not be verified. Please try again.', 400);
      }

      const human = await verifyTurnstile(request, env, token);
      if (!human)
        return pageResponse(env, url, scene, paths, next, 'The login could not be verified. Please try again.', 403);

      const passwordMatches = await timingSafePasswordMatch(password, env[scene.passwordBinding]);
      if (!passwordMatches)
        return pageResponse(env, url, scene, paths, next, 'The login could not be verified. Please try again.', 401);

      const session = await createSession(env, scene.slug);
      const cookie = `${cookieName(scene.slug)}=${session}; Path=/; Max-Age=${sessionTtl(env)}; HttpOnly; Secure; SameSite=Lax`;
      return redirect(next, { 'Set-Cookie': cookie, 'Cache-Control': 'no-store' });
    }

    if (url.pathname === paths.logout && request.method === 'POST') {
      return redirect(paths.login, {
        'Set-Cookie': `${cookieName(scene.slug)}=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Lax`,
        'Cache-Control': 'no-store'
      });
    }

    if (!['GET', 'HEAD'].includes(request.method)) {
      return new Response('Method not allowed', { status: 405, headers: { ...securityHeaders, Allow: 'GET, HEAD' } });
    }

    if (!(await hasValidSession(request, env, scene.slug))) {
      const next = `${url.pathname}${url.search}`;
      return redirect(`${paths.login}?next=${encodeURIComponent(next)}`, { 'Cache-Control': 'no-store' });
    }

    return assetResponse(request, env, scene);
  }
};
