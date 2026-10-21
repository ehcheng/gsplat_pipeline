# gsplats

A capture-to-web workflow for 3D Gaussian splats on Windows. Photos or videos from one or more cameras go in one end; a compact, interactive scene that anyone can open at `https://<your domain>/3d/<slug>/` comes out the other, optionally behind a per-scene password, with link previews, a VR/AR build and a looping preview clip.

```text
stills / videos ─► COLMAP (structure from motion) ─► LichtFeld Studio (3DGS training) ─► frame.mjs (level, opening view, thumbnail)
                ─► build-viewer.mjs (SOG compression + SuperSplat viewer) ─► Cloudflare Worker at /3d/<slug>/
```

It was built around a rig of GoPro HERO12 cameras (Wide or Linear lens modes) and also works with any camera whose lens is rectilinear or fisheye. [PROJECT.md](./PROJECT.md) describes the whole system, its design decisions and measured performance; this README is the step-by-step guide.

**Best run with an AI coding agent** such as Claude Code or ChatGPT/Codex. The scripts automate the standard path, but most captures need some judgment along the way: picking the lens mode, reading the SfM and training metrics, retrying a stage with different settings, leveling and framing the opening view, or writing a one-off script to cull frames or mask passers-by. The pipeline was developed that way. Point the agent at this README, `PROJECT.md` and `pipeline/docs/`, and have it launch long runs as detached processes so a command timeout does not kill them.

| Folder | Role | Detailed docs |
| --- | --- | --- |
| `pipeline/` | Reconstruct (COLMAP), train (LichtFeld Studio), optionally export and render an orbit video. Output: a full-quality `.ply`. | `pipeline/README.md`, `pipeline/docs/` |
| `web-viewer/` | Level and frame the scene, compress it to SOG, wrap it in the SuperSplat browser viewer, publish it through a Cloudflare Worker, and optionally export a catalog for another website. | `web-viewer/README.md`, `web-viewer/PUBLISHING.md`, `web-viewer/CATALOG.md` |
| `site.example/` | Template for your private site configuration (Cloudflare settings, scene registry). Copy to `site/`. | `site.example/README.md` |

## Requirements

- **Windows 10 or 11** (64-bit) with **PowerShell 7**. The reconstruction scripts are Windows-only; the web-viewer scripts are plain Node.js.
- **An NVIDIA GPU** supported by LichtFeld Studio, with a current driver. The defaults (1.5 M splat cap, 30k iterations) were tuned on a 48 GB card; lower `-MaxCap` on smaller cards.
- **[LichtFeld Studio](https://github.com/MrNeRF/LichtFeld-Studio)**, the Gaussian-splat trainer. It is not bundled; install a Windows binary or build it from source with the scripts in `pipeline/tools/installers/` (see [pipeline/tools/INSTALLS.md](./pipeline/tools/INSTALLS.md)). v0.4 or later trains; the optional MCP-driven export and orbit stages need v0.5 or later.
- **COLMAP** with CUDA (the official Windows CUDA release works).
- **ffmpeg** and **ffprobe** on PATH.
- **Node.js 24** and **pnpm** for the web viewer.
- For publishing: a **Cloudflare** account (free plan is enough), ideally with your domain as a zone. Password-protected scenes also need a Cloudflare Turnstile widget.

Tools are found on PATH, through `LICHTFELD_PATH` / `COLMAP_PATH`, or under `pipeline/tools/` (gitignored). [pipeline/tools/INSTALLS.md](./pipeline/tools/INSTALLS.md) has download links, checksums and the LichtFeld build recipe.

## Layout

```text
gsplats/
  README.md  PROJECT.md
  pipeline/                 reconstruct.cmd (one-shot), run.ps1 (stages), stats.ps1, docs/, tests/
    tools/                  your tool installs (gitignored) + INSTALLS.md and installers/
  web-viewer/               viewer builder, Cloudflare Worker (src/index.js), scripts/
    dist/3d/<slug>/         built scenes that get deployed (gitignored)
  site.example/             template for site/
  site/                     YOUR site config: wrangler.jsonc, scenes.json (gitignored)
  _workspace/               YOUR scene data (gitignored), one folder per capture:
    <scene>/
      cam1/ cam2/ ...       raw stills, one folder per physical camera (or raw/cam1.mp4 ...)
      capture.json          lens mode, written by the pipeline
      images/ colmap/ lfs/  staged frames, SfM model, trained splats
      frame/                framing results, publish.ply, preview clip
      thumbnail.jpg         share thumbnail
      runs/ log.txt         per-run logs and stats
```

The repository holds code and docs only. Your captures, models and Cloudflare configuration stay out of it.

## First-time setup

```powershell
git clone <this repository> gsplats
cd gsplats
# Install the tools (pipeline/tools/INSTALLS.md); then, if LichtFeld is not on PATH or in pipeline\tools\lichtfeld:
[Environment]::SetEnvironmentVariable('LICHTFELD_PATH', 'C:\path\to\LichtFeld-Studio.exe', 'User')
pwsh -File .\pipeline\tests\smoke.ps1        # checks the pipeline scripts, no GPU needed
cd web-viewer
pnpm install
Copy-Item -Recurse ..\site.example ..\site   # then edit site\wrangler.jsonc; see web-viewer\PUBLISHING.md
```

## End-to-end: new capture to live URL

The example is a scene `20260912_park_bench_wide`, shot with GoPros in Wide mode and published publicly as `park-bench`.

### 1. Drop the captures in place

Create `_workspace\20260912_park_bench_wide\` with one folder per physical camera (`cam1`, `cam2`, ...). Stills go directly in those folders; videos go in `raw\cam1.mp4` and so on (sampled at 3 fps). One folder per camera matters: COLMAP assigns one set of intrinsics per folder, so stills from different bodies must not be mixed. A single camera works too (one `cam1` folder).

Aim for 300 to 800 frames in total, walking around the subject at a couple of heights. Drop obviously soft stills by hand; the pipeline does no blur rejection on stills. Stills re-saved by editing software lose the GoPro maker notes, so give their lens explicitly.

With a rig of several GoPros, set every camera to the same exposure settings (shutter, ISO, white balance, lens mode) and lock them. Cameras that expose differently produce frames that disagree in brightness and color, which shows up as blotches in the splat. [SplatSync](https://echeng.com/projects/splatsync/) is a phone app that sets a whole rig to identical, locked settings from one QR code (GoPro Labs firmware); it is not distributed yet.

No GoPro? A single handheld video from a phone works well. Put it in `raw\cam1.mp4` and run with `-Lens pinhole -SharpestOf 5`, which keeps the sharpest frame of every five instead of sampling at a fixed rate. See [pipeline/docs/PHONE_VIDEO.md](./pipeline/docs/PHONE_VIDEO.md) for shooting tips and for masking people who walk through the shot.

### 2. Know the lens mode

GoPro files do not record the lens mode, so you tell the pipeline. `wide` is recommended and maps to the `OPENCV_FISHEYE` camera model with 3DGUT training. `linear`, `linear-hl` and `narrow` map to `OPENCV` with COLMAP undistortion and plain pinhole training. SuperView and HyperView are rejected outright; re-shoot. Other cameras: `pinhole` for ordinary lenses, `fisheye` for fisheyes. See `pipeline/docs/LENS_MODES.md`.

The easiest way to declare it is a token in the folder name (`_wide`, `-linear`, ...). The choice is saved to `<scene>\capture.json` on the first run, so later runs need no flag.

### 3. Reconstruct and train

```powershell
.\pipeline\reconstruct.cmd .\_workspace\20260912_park_bench_wide
```

`reconstruct.cmd` resolves the lens, runs extract, sfm and train through `run.ps1`, and prints a status line every 15 s with the current sub-stage, elapsed time, estimated time left and estimated completion. Lens resolution order: `-Lens`, a token in the folder name, `capture.json`, then a provisional GoPro MakerNote fingerprint (with a warning). `-DryRun` shows the plan without running anything; `-Force` redoes completed stages; `-Iterations`, `-MaxCap`, `-Strategy`, `-Fps`, `-SharpestOf` and `-Stages extract,sfm` pass through.

On an RTX 6000 Ada, a 400-image Wide set takes about 1.5 hours (30 minutes of SfM, an hour of training). Run it from its own window, or detached with `Start-Process`, rather than from a shell with a command timeout. Afterwards check:

- `colmap\sfm.metrics.json`: registration near 100 percent and mean reprojection error around 1 px or lower;
- `lfs\training.metrics.json`: the final loss; the result is `lfs\splat_30000.ply`;
- `runs\<timestamp>\stats.md`: per-stage timings, SfM quality, training throughput.

To look at the result before publishing: `& $env:LICHTFELD_PATH --view .\_workspace\<scene>\lfs\splat_30000.ply`.

### 4. Level the horizon and pick the opening view

```powershell
cd web-viewer
node scripts\frame.mjs ..\_workspace\20260912_park_bench_wide                                  # pass 1
node scripts\frame.mjs ..\_workspace\20260912_park_bench_wide --azimuth 0 --distance 1.15      # pass 2
```

Trained splats come out of COLMAP tilted and off-center. Pass 1 reads the camera poses, takes gravity from the average camera up-vector (ignoring frames where the rig was rolled sideways), computes the rotation that levels the scene, and renders a contact sheet of eight views around the subject plus a top view to `<scene>\frame\contact.png`. Azimuth 0 is the side with the most frames, usually the front.

Look at the sheet, then run pass 2 with the azimuth you want (optionally `--elevation`, `--distance`, `--fov`, `--lift`; `--ply` when the trained PLY is not the newest `lfs\splat_*.ply`). Pass 2 writes `frame\frame.json` (rotation and opening camera), renders `frame\chosen.webp` for a final look, writes the share thumbnail `<scene>\thumbnail.jpg` (1920×1280), and writes `frame\publish.ply`: the leveled splat with far-away sky and terrain splats pulled onto a shell, which keeps the viewer's depth sort precise on outdoor scenes. In tight spaces, a distant camera can end up behind a wall; pull `--distance` in. On wooded scenes the pivot can land in tree canopy; raise `--lift`.

### 5. Build the web scene

```powershell
node scripts\build-viewer.mjs ..\_workspace\20260912_park_bench_wide\lfs\splat_30000.ply park-bench
```

Slugs are lowercase letters, digits and single hyphens. The builder uses `frame\publish.ply` and the opening camera from step 4, converts to SOG (a 355 MiB, 1.5 M splat PLY becomes about 20 MiB), writes the patched viewer page, the link-preview image and a `/vr` variant for headsets and phone AR. See `web-viewer/PUBLISHING.md` for options.

### 6. Register, deploy, verify

Add the scene to `site\scenes.json` (title, description, date, source folder, `passwordBinding: null` for public, `unlisted`), then:

```powershell
pnpm run check:deploy
pnpm run deploy
```

Open `https://<your domain>/3d/park-bench/` in a private window. For password-protected scenes, Turnstile setup, link-preview checks, replacing, unpublishing and rollback, follow [web-viewer/PUBLISHING.md](./web-viewer/PUBLISHING.md).

### 7. Optional: preview clip and catalog for another site

`node scripts\wiggle.mjs ..\_workspace\<scene>` renders a 6-second looping parallax clip. `node scripts\export-bridge.mjs <folder>` writes a JSON catalog with thumbnail crops and clips for a separate website to import at build time ([web-viewer/CATALOG.md](./web-viewer/CATALOG.md)).

## Notes

- `pipeline/tests/smoke.ps1` checks the `run.ps1` contract, tool discovery and lens resolution without a GPU.
- `@playcanvas/splat-transform` 3.4.0 crashes silently (exit code `0xC0000409`) when writing SOG on the GPU from an odd number of splats, and its decimation crashes on some inputs when a GPU adapter is initialised. `build-viewer.mjs` and `wiggle.mjs` keep counts even and decimate on the CPU.
- Large single-camera sets (more than about 1,000 images) map much faster with COLMAP's `global_mapper` than with the incremental mapper; see `pipeline/docs/PIPELINE.md`.
- Cloudflare limits each static file to 25 MiB. A larger `scene.sog` needs a lower `-MaxCap` or R2 storage.

## License

MIT; see [LICENSE](./LICENSE). The tools this project drives are separate programs under their own licenses: LichtFeld Studio (GPL-3.0), COLMAP (BSD), ffmpeg (LGPL/GPL), and the PlayCanvas packages installed by pnpm (MIT). None of them is included in this repository.
