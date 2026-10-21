# Site configuration template

Everything that is specific to your deployment lives in one folder, outside the code:

| File | What it holds |
| --- | --- |
| `wrangler.jsonc` | The Cloudflare Worker configuration: account, Worker name, routes on your domain, and public settings (`SITE_NAME`, `SITE_URL`, Turnstile site key, ...). |
| `scenes.json` | The scene registry: every published slug with its title, description, date, source folder, access (`passwordBinding`) and listing (`unlisted`). The Worker serves only slugs listed here. |
| `HANDOFF.md` | Optional. Your own version of `web-viewer/CATALOG.md`, copied into the catalog export as `HANDOFF.md` instead of the generic one. |

Copy this folder to `site/` at the repository root (it is gitignored) and edit the copy:

```powershell
Copy-Item -Recurse site.example site
```

Or keep the folder anywhere else, for example as its own private repository, and point the scripts at it with the `GSPLAT_SITE_DIR` environment variable. If you move it, update the relative paths in `wrangler.jsonc` (`$schema`, `main`, `assets.directory`), which point back into `web-viewer/`.

Nothing in this folder is secret: passwords, the Turnstile secret key and the session key are Worker secrets entered at Wrangler's prompt, never written to a file. It is still personal (account ID, domain, scene names and shooting locations), which is why it stays out of the shared repository.

See `web-viewer/PUBLISHING.md` for the fields and the setup steps.
