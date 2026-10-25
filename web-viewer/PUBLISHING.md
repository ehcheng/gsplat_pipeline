# Publishing scenes with Cloudflare

Operational runbook for serving Gaussian splats at `https://<your domain>/3d/<slug>/` from a Cloudflare Worker: one-time setup, then adding, replacing, protecting, testing and removing scenes. Commands run in `web-viewer/` with Node on PATH. `pnpm run <script>` and `node scripts/<script>.mjs` are interchangeable.

## One-time setup

### 1. Cloudflare account and domain

You need a Cloudflare account (the free plan is enough). To serve under your own domain, the domain must be a zone in that account; scenes then live at `https://example.com/3d/<slug>/` and the rest of the domain is untouched. Without a domain, the Worker can serve from `https://<worker>.<subdomain>.workers.dev/3d/<slug>/`.

### 2. Site folder

```powershell
Copy-Item -Recurse ..\site.example ..\site
```

Edit `site/wrangler.jsonc`:

- `name`: the Worker name.
- `account_id`: your account ID.
- `routes`: replace `example.com` with your domain in both patterns, or delete `routes` and set `"workers_dev": true`.
- `vars.SITE_NAME`, `vars.SITE_URL`: the name shown on the login page and in link previews, and your site's address.
- `vars.GSPLAT_INDEX_URL`: optional page that `/3d/` redirects to, such as a gallery page on your site.

Replace the example scenes in `site/scenes.json` with your own as you publish them (step 3 below). `site/` is gitignored. To version it, make it its own private repository, or keep it elsewhere and point `GSPLAT_SITE_DIR` at it.

### 3. Log in

```powershell
pnpm run wrangler -- login --scopes account:read user:read zone:read workers:write workers_scripts:write workers_routes:write
pnpm run whoami
```

The login is stored in `web-viewer/.wrangler-config/`, not in your user profile. Wrangler may warn that optional access to unrelated Cloudflare products is missing; do not grant unrelated scopes just to remove the warning. `workers:write` is needed for secrets, `workers_routes:write` for routes on your zone.

### 4. Password-protected scenes only: Turnstile and session key

Skip this if every scene is public.

1. In the Cloudflare dashboard, create a Turnstile widget (Turnstile > Add widget) for your domain (and `workers.dev` host if you use it). Managed mode works well.
2. Put its **site key** in `vars.TURNSTILE_SITE_KEY` in `site/wrangler.jsonc`. Optionally set `vars.TURNSTILE_EXPECTED_HOSTNAME` to the host name the login page is served from; when empty, the Worker accepts the host of the login request.
3. Store the **secret key** and a generated session-signing key as Worker secrets:

   ```powershell
   pnpm run auth:init
   ```

   It prompts for the Turnstile secret key at Wrangler's masked prompt and generates `SESSION_SECRET` itself.

Turnstile's always-pass test keys (site key `1x00000000000000000000AA`, secret `1x0000000000000000000000000000000AA`) are handy for a first deploy; the Worker skips its action and host-name checks for the test site key. Replace them before sharing a protected scene.

### 5. First deploy

```powershell
pnpm run check:deploy
pnpm run deploy
```

With no scenes built yet, this deploys the Worker alone. Every `/3d/<slug>/` is a 404 until a scene is built and registered.

## Adding a scene

### 1. Choose the source and slug

Start with the framed scene: `frame.mjs` (see the root README) writes `<scene>/frame/publish.ply`, which the builder picks up automatically when you give it the trained PLY. Choose a stable URL slug of lowercase letters, digits and single hyphens (`park-bench`, `studio-scan-02`). Changing a slug later changes the URL, the password binding name and the session cookie.

### 2. Build

```powershell
node scripts/build-viewer.mjs ..\_workspace\<scene>\lfs\splat_30000.ply park-bench
```

The builder converts the PLY to PlayCanvas SOG and writes:

```text
dist/3d/park-bench/
  build.json  index.html  index.js  scene.sog  og.jpg  social.json
  vr/
    build.json  index.html  index.js  scene.sog
```

If `<scene>/frame/frame.json` exists, the builder uses `frame/publish.ply` and the chosen opening camera; set `FRAME_JSON=none` to ignore it. When the scene folder has a `thumbnail.jpg`, the builder also writes `og.jpg` (1200×800, under 300 KB for WhatsApp) and `social.json` for link previews. Public scenes serve `og.jpg` without a session; protected scenes keep it behind the login unless the registry entry sets `socialImage: true`. The image URL carries a content hash (`og.jpg?v=…`), so a re-rendered thumbnail bypasses platforms' preview caches. To refresh it without re-encoding: `node scripts/social.mjs ..\_workspace\<scene> <slug>`.

The `vr/` folder is the headset build (see the top of `scripts/build-viewer.mjs` for the pipeline and the numbers behind it). It takes about 35 s more per scene. Options:

| Option | Default | Meaning |
| --- | --- | --- |
| `--web-splats N` | 1500000 | Splat count for the main `scene.sog`; larger masters are decimated adaptively to it (0 keeps every splat) |
| `--lod` | | Also write `lod/`, a streamed SOG of the full master with levels at 100, 50, 25 and 10%, and point the page at it. Adds about 6 min for 5 M splats |
| `--no-vr` | | Skip the `vr/` build |
| `--vr-only` | | Rebuild only `vr/` under an existing main build |
| `--vr-splats N` | 350000 | Target splat count (forced even) |
| `--vr-sh 0..3` | 1 | Spherical-harmonic bands kept |
| `--vr-min-opacity a` | 0.05 | Splats below this opacity are dropped first |
| `--vr-decimate adaptive\|uniform` | uniform | `uniform` thins everywhere (best on Quest 3); `adaptive` keeps subject detail but leaves nearly as many overlapping layers over a dense subject as the full scene |
| `--vr-framebuffer-scale s` | 0.7 | XR framebuffer scale used by the viewer |
| `--vr-far-clip d` | 4000 | XR far clip; must stay beyond the frame.mjs far shell |
| `--vr-foveation f` | 0.5 | WebXR fixed foveation 0..1 (0 = off) |
| `--vr-frame-rate hz` | 72 | Session frame rate requested when the headset offers it (0 = browser default) |
| `--vr-sort-epsilon e` | 0.01 | Camera movement below which the WebGL sorter does not re-sort |
| `--vr-lod` | | Under test: also write `vr/lod/`, a streamed SOG of the culled master with the same SH cut and decimation, levels at 100, 50, 25, 10 and 5%, and point the /vr page at it |

The same keys can be set per scene in `site/scenes.json` under `"vr"`, and `"web": { "splats": N, "lod": true }` for the main build; command-line flags win. For in-headset A/B tests without a rebuild, the `/vr` page accepts `?fbscale=0.8`, `?foveation=0` and `?hz=90` on its URL. Every page takes `?budget=<millions of splats>`, which fixes the streamed splat budget on all Quality positions, in a headset session too.

Check `build.json` after every build. Cloudflare Workers Static Assets limit each file to **25 MiB**; a 1.5 M splat scene comes out at about 20 MiB, which is why `--web-splats` defaults to 1.5 M. `lod/` files are about 2 MiB each. The builder warns when any file is over the limit. See [Workers limits](https://developers.cloudflare.com/workers/platform/limits/#static-assets).

Building replaces only `dist/3d/<slug>`; other scenes stay.

### 3. Register the scene

A built scene is not reachable until it is in `site/scenes.json`:

```json
"park-bench": {
  "title": "Park Bench",
  "description": "Two friends on a park bench under an oak tree.",
  "date": "2026-09-12",
  "source": "20260912_park_bench_wide",
  "passwordBinding": null,
  "unlisted": false
}
```

| Key | Meaning |
| --- | --- |
| `title` | Page title, link-preview title, catalog title |
| `description` | One factual sentence (subject, and place when known); link-preview text for public scenes |
| `date` | Capture date, `YYYY-MM-DD` |
| `source` | Scene folder under `_workspace/` (thumbnail, framing, preview clip) |
| `passwordBinding` | `null` for a public scene, else the Worker secret holding its password |
| `unlisted` | Required. `true` marks the scene unlisted in the catalog (direct link only) |
| `socialImage` | Optional. `true` publishes a protected scene's preview image anyway |
| `thumbnailFocus` | Optional `{ "x": 0.5, "y": 0.6 }`: crop center for the catalog's wide thumbnails |
| `location` | Optional, hand-entered: `{ "name", "locality", "lat", "lng", "precision": "exact" \| "city" }`. Coordinates are never exported for protected scenes. Get `lat`/`lng` from a Google Maps place link: the numbers after `!3d` and `!4d`. |
| `vr` | Optional `/vr` build overrides (see above) |

For a **protected** scene, the binding is `SPLAT_PASSWORD_` plus the slug uppercased with hyphens as underscores (`studio-scan-02` → `SPLAT_PASSWORD_STUDIO_SCAN_02`). Add it to `secrets.required` in `site/wrangler.jsonc` and set the password:

```powershell
pnpm run password:set -- studio-scan-02
```

Enter the password only at Wrangler's native masked prompt. Never put it in a file, a script, a command line or a chat. Use at least 6 characters; the login page gives no length hints. `pnpm run wrangler -- secret list` shows binding names only.

### 4. Validate and deploy

```powershell
node --check src\index.js
pnpm run check:deploy
pnpm run deploy
```

Before deploying, confirm that the scene is registered, `dist/3d/<slug>/scene.sog` exists and is under 25 MiB, and that a protected scene's binding appears in `secret list`. The deploy uploads the Worker and every folder under `dist/3d` (unchanged files are skipped). Note the version ID Wrangler prints. The registry and per-scene gate are the production access boundary, so review protected-versus-public registration before every deploy.

### 5. Test the live scene

Open `https://<your domain>/3d/<slug>/` in a private window. A public scene loads straight into the viewer. For a protected scene, verify that:

1. the password page appears, and Turnstile completes;
2. a wrong password stays on the page with a generic error, and the right one opens the scene;
3. a refresh works for the session's lifetime (`SESSION_TTL_SECONDS`, default 24 h);
4. `/3d/<slug>/logout` (POST) ends only that scene's session;
5. in a fresh private window, `/3d/<slug>/scene.sog` does not return the model.

Check the link preview with a crawler's user agent; a public scene should list `og:image`, and that URL should return a JPEG without a cookie:

```powershell
curl.exe -s -A 'facebookexternalhit/1.1' https://example.com/3d/park-bench/ | Select-String 'og:'
```

On a VR headset, open `/3d/<slug>/vr/` and press Enter VR; the main page must show no AR or VR button.

### 6. Landing-page clip and catalog (optional)

To list scenes on another website, render each scene's looping preview clip and export the catalog after every deploy:

```powershell
node scripts/wiggle.mjs ..\_workspace\<scene folder>
node scripts/export-bridge.mjs <bridge folder> [--site https://example.com]
```

`wiggle.mjs` writes `<scene>/frame/wiggle.mp4` (1920×1080, 30 fps, 6 s, H.264) in about 6 minutes on a fast GPU. The camera circles the opening view once on a small tilted ellipse, so the clip loops without a cut. Options: `--duration`, `--fps`, `--width/--height`, `--sway`, `--bob`, `--dolly`, `--fov`, `--crf`, and `--frames n --keep` for a quick partial check. Re-run after re-framing a scene.

`export-bridge.mjs` writes `gsplats.json`, its JSON Schema, thumbnail crops, preview clips and `HANDOFF.md` to a folder your site's build reads. See [CATALOG.md](./CATALOG.md).

## Replacing a scene

Build the new PLY with the same slug, check `build.json`, deploy, and re-run the catalog export if you use it. The URL, registry entry and password are untouched; the old viewer files are not kept.

## Rotating a password

Run `pnpm run password:set -- <slug>` again. Existing sessions stay valid until they expire, because the password does not sign them. To sign everyone out of every protected scene immediately, rotate `SESSION_SECRET` (`pnpm run auth:init` regenerates it, after asking for the Turnstile secret again).

## Unpublishing a scene

Remove the entry from `site/scenes.json` and deploy (and re-run the catalog export). Unknown slugs return 404, so this is the step that takes it offline. Then clean up: delete `dist/3d/<slug>`, remove a protected scene's binding from `secrets.required`, delete its secret (`pnpm run wrangler -- secret delete <BINDING>`), and deploy again so the files leave the asset store.

## Rollback and diagnostics

```powershell
pnpm run wrangler -- versions list
pnpm run wrangler -- rollback <VERSION_ID>
pnpm run wrangler -- tail <worker name> --status error
```

The Worker logs only non-secret Turnstile rejection metadata (host name, action, error codes). Never add password values, Turnstile tokens or secrets to logs.

## Cloudflare configuration notes

- `site/wrangler.jsonc` is the source of truth for the Worker name, routes, static-assets binding, public variables and secret names.
- `TURNSTILE_SITE_KEY` is public and belongs in `vars`. `TURNSTILE_SECRET_KEY`, scene passwords and `SESSION_SECRET` are encrypted Worker secrets.
- `assets.run_worker_first` must stay `true` so the access checks run before static assets. Without it, `scene.sog` and the viewer files of protected scenes could be fetched directly.
- The Worker upgrades any `http://` request under `/3d` to `https://` (308), because not every zone forces HTTPS and the session cookie is `Secure`. It sends no HSTS header: that would apply to the whole host.
- Responses carry `X-Robots-Tag: noindex`, `X-Frame-Options: DENY` and `Referrer-Policy: no-referrer`; the login page also sends a strict CSP. Change `src/index.js` if you want scenes indexed or embedded.
- A Cloudflare Access application in front of `/3d/*` would add an email login before every scene, public ones included. The Worker's own gate does not need it.

References: [Workers Static Assets](https://developers.cloudflare.com/workers/static-assets/), [Workers limits](https://developers.cloudflare.com/workers/platform/limits/), [Workers secrets](https://developers.cloudflare.com/workers/configuration/secrets/), [Wrangler commands](https://developers.cloudflare.com/workers/wrangler/commands/), [Turnstile server-side validation](https://developers.cloudflare.com/turnstile/get-started/server-side-validation/).
