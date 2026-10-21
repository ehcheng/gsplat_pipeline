# Reconstruction pipeline

`run.ps1` stages images from one folder per physical camera, reconstructs one COLMAP model, trains a Gaussian splat in LichtFeld Studio, and optionally exports PLY/SPZ and renders a verified 4K orbit through LichtFeld's MCP server. `reconstruct.cmd` wraps the first three stages in one command with live progress.

Windows only (PowerShell 7, NTFS hard links and junctions). See the root `README.md` for the full capture-to-URL walkthrough and `tools/INSTALLS.md` for installing the tools.

## Prerequisites

- PowerShell 7 (on PATH, or portable at `pipeline/tools/pwsh/pwsh.exe`)
- An NVIDIA GPU supported by LichtFeld Studio, with a current driver
- **LichtFeld Studio**, installed or built from source (`tools/installers/build-lichtfeld.ps1`). v0.4 or later trains; the optional `export` and `orbit` stages need v0.5 or later with MCP enabled at `http://127.0.0.1:45677/mcp`
- A CUDA-enabled COLMAP build (the official Windows CUDA release works)
- ffmpeg and ffprobe on PATH (or `-FfmpegPath` / `-FfprobePath`)

Tools are found without configuration when they are on PATH or under `pipeline/tools` (`colmap*/bin/colmap.exe`, `lichtfeld/bin/LichtFeld-Studio.exe`). Elsewhere, set `LICHTFELD_PATH` / `COLMAP_PATH` or pass `-LichtFeldPath` / `-ColmapPath`.

Launch a new LichtFeld build once by hand and confirm it lists your GPU before the first run.

## One-shot reconstruction

```powershell
.\pipeline\reconstruct.cmd .\_workspace\20260920_lobby_wide
.\pipeline\reconstruct.cmd .\_workspace\20260920_lobby -Lens linear -Iterations 20000 -DryRun
```

`reconstruct.cmd <scene folder>` runs extract, sfm and train through `run.ps1` and prints a status line every 15 s: sub-stage, elapsed, estimated time left, estimated completion. The lens comes from `-Lens`, else a `_wide`/`-wide`/`_linear`/`-linear` (and so on) token in the folder name, else `capture.json`, else a provisional GoPro MakerNote fingerprint (with a warning). `-DryRun` prints the plan without running. Estimates start from rates measured on an RTX 6000 Ada and are re-learned into `timings.json` after every run, so they adapt to your machine.

A full run takes one to two hours for 400 to 550 images; launch it from its own window or as a detached process (`Start-Process`) rather than from a shell with a command timeout.

## Run statistics

Every `reconstruct` run gets its own folder, `<scene>/runs/<yyyyMMdd-HHmmss>/`, holding `reconstruct.log` (every status line with a full timestamp) and, once the last stage finishes or fails, `stats.json` and `stats.md`. The stats are harvested by `stats.ps1` from what the stages already wrote (`log.txt`, the COLMAP and LichtFeld metrics files, the training log, the PLY header), so collecting them adds nothing to the run. They cover input size, per-stage and per-sub-step wall time, SfM quality (features per image, verified pairs, registration, 3D points, track length, reprojection error), training throughput and convergence (iterations per second, loss at milestones, when the splat cap was hit, image-loader hit rate, VRAM), output size and the machine.

`pipeline/runs.jsonl` accumulates one flat JSON line per run across all scenes. To compare runs, or to backfill an older scene:

```powershell
pwsh -File .\pipeline\stats.ps1 -Table
pwsh -File .\pipeline\stats.ps1 .\_workspace\20260920_lobby_wide
```

## Documentation

- `docs/PIPELINE.md`: stage-by-stage reference (layout, COLMAP and LichtFeld command shapes, MCP export and orbit contract, acceptance checks, open items).
- `docs/LENS_MODES.md`: GoPro lens mode to camera model, fisheye support in LichtFeld, and how to signal the lens.
- `tools/INSTALLS.md`: installing COLMAP, LichtFeld Studio (binary or source build), PowerShell, Node.js and ffmpeg.
- `tests/smoke.ps1`: contract, tool-discovery and lens-resolution tests without a GPU; run with `pwsh -File .\pipeline\tests\smoke.ps1`.

## Lens mode

The lens mode decides the COLMAP camera model and the LichtFeld training path. It cannot be read from GoPro metadata, so the operator signals it, in this order of precedence:

1. `-CameraModel OPENCV|OPENCV_FISHEYE` (explicit COLMAP model)
2. `-Lens linear|linear-hl|narrow|pinhole|wide|fisheye`
3. `<scene>/capture.json` containing `{ "lens": "wide" }`

The winner is written back to `capture.json`, so stage-only reruns need no flag. Mapping:

- Linear, Linear + Horizon Lock, Narrow, or any rectilinear lens (`pinhole`): `OPENCV`, then COLMAP undistortion and pinhole training
- Wide (or any true fisheye lens): `OPENCV_FISHEYE`, then 3DGUT training with `--gut`
- SuperView and HyperView: rejected. They are non-physical stretches of the Wide readout and no COLMAP model fits them. Re-shoot in Wide or Linear.

Non-GoPro cameras work the same way: one folder per body, `-Lens pinhole` for ordinary lenses, `-Lens fisheye` for fisheyes. See `docs/LENS_MODES.md` for the evidence and trade-offs.

## Running stages directly

```powershell
pwsh -File .\pipeline\run.ps1 -Scene <name> -Lens wide -Stage sfm
pwsh -File .\pipeline\run.ps1 -Scene <name> -Stage train      # lens read back from capture.json
pwsh -File .\pipeline\run.ps1 -Scene <name> -Stage export     # LichtFeld v0.5+ running with MCP
pwsh -File .\pipeline\run.ps1 -Scene <name> -Stage orbit
```

`-Scene` is a folder name under `-Root` (default `<repo>\_workspace`) or an absolute path. The scene may contain camera folders directly, camera folders under `raw`, or camera-named video files under `raw`. The generated layout is:

```text
<scene>/
  capture.json
  images/<camera>/...
  colmap/database.db
  colmap/sparse/0/{cameras,images,points3D}.bin
  lfs/flags.txt
  lfs/training.metrics.json
  lfs/splat_30000.ply
  lfs/<scene>.ply  lfs/<scene>.spz            (export)
  renders/<scene>_orbit_4k.mp4 ...            (orbit)
  log.txt
```

Every stage is idempotent and skips completed output unless `-Force` is passed. Failures stop the pipeline with a non-zero exit. COLMAP starts with sequential matching and automatically rebuilds with exhaustive matching if the first pass does not produce exactly one model. Before training, the script decodes `sparse/0/cameras.bin` and refuses to continue if the camera model on disk disagrees with the declared lens.

The script checks the installed COLMAP and LichtFeld help text before using version-sensitive flags. It saves the LichtFeld CLI help to `lfs/flags.txt` and, for the MCP stages, the live tool and resource discovery to `lfs/mcp-catalog.json`. If the LichtFeld scene-state resource does not expose bounds, provide `-OrbitCenter 'x,y,z' -OrbitRadius r`; use `-SceneNode` if the Gaussian node cannot be picked unambiguously.
