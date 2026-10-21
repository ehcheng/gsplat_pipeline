# Installing the pipeline tools

The pipeline runs external tools; none are bundled in the repository. Each can live anywhere on PATH, or in this folder (`pipeline/tools/`, gitignored apart from this file and `installers/`), where the scripts find it without configuration:

| Tool | Found as | Override |
| --- | --- | --- |
| LichtFeld Studio | `LichtFeld-Studio` on PATH, then `tools/lichtfeld/bin/LichtFeld-Studio.exe` | `LICHTFELD_PATH`, `-LichtFeldPath` |
| COLMAP | `colmap` on PATH, then `tools/colmap*/bin/colmap.exe` | `COLMAP_PATH`, `-ColmapPath` |
| PowerShell 7 | `tools/pwsh/pwsh.exe`, then `pwsh` on PATH (`reconstruct.cmd`) | |
| ffmpeg / ffprobe | PATH | pipeline only: `FFMPEG_PATH`, `FFPROBE_PATH`, `-FfmpegPath`, `-FfprobePath` |
| Node.js | PATH (web-viewer scripts) | |

## LichtFeld Studio (required)

[LichtFeld Studio](https://github.com/MrNeRF/LichtFeld-Studio) is the Gaussian-splat trainer (GPL-3.0). The pipeline runs it as a separate program and does not bundle or link it. Any of these works:

- **Install a Windows binary** from the project's releases or download portal, then set `LICHTFELD_PATH` to `LichtFeld-Studio.exe` (or put its `bin` folder on PATH). v0.4.2 was the last free Windows zip on GitHub; it trains (MCMC, 3DGUT) but has no MCP server, so the optional `export` and `orbit` stages need v0.5 or later.
- **Build from source** into `tools/lichtfeld/`, which is what the reference setup uses (v0.5.4.1):

  ```powershell
  # once, from an elevated PowerShell: VS 2022 Build Tools + Clang, CUDA 12.8 toolkit, CMake, Ninja, Git, long paths
  powershell -ExecutionPolicy Bypass -File .\pipeline\tools\installers\install-toolchain.ps1
  # then, not elevated: clones the tagged source and vcpkg, configures, builds, installs
  powershell -ExecutionPolicy Bypass -File .\pipeline\tools\installers\build-lichtfeld.ps1 -Tag v0.5.4.1
  ```

  The recipe mirrors upstream's `.github/workflows/nightly.yml` (build-windows job): `cmake -B build -S . -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_PORTABLE=ON -DBUILD_PYTHON_STUBS=OFF`, then `cmake --install build --prefix pipeline/tools/lichtfeld`. The first configure takes about 50 minutes (vcpkg builds about 90 dependency ports); the compile about 20 minutes on 64 threads. The result is a portable folder of about 550 MB; kernels ship as PTX and JIT-compile for your GPU on first launch. `-Reconfigure` wipes the build folder. No cuDNN is needed, and the CUDA installer runs with `-noDisplayDriver`, so your NVIDIA driver is left alone.

- **Linux:** LichtFeld builds on Linux too, but this pipeline's scripts are Windows-only.

Check a build with `LichtFeld-Studio.exe --version` and `--help`: training needs `--headless --train --strategy --max-cap --iter` and, for fisheye sets, `--gut`. In GUI mode v0.5+ starts its MCP server on `127.0.0.1:45677`.

## COLMAP (required)

Use a CUDA build. The reference setup uses the official 4.2.1 release:

- Asset: `colmap-x64-windows-cuda.zip` from the `colmap/colmap` GitHub release 4.2.1 (commit `bd1fcf6`)
- SHA-256: `E9C5CBD84C2EA986D2E970A2473FC2D2E6B34A2CDCF5D3DF2765C319A63AF881`
- Extract to `pipeline/tools/colmap-4.2.1-cuda/` so that `bin/colmap.exe` exists

COLMAP 3.x also works; `run.ps1` reads `colmap <command> -h` and picks the 3.x (`SiftExtraction`) or 4.x (`FeatureExtraction`) option names.

## PowerShell 7 (required)

Install it machine-wide (`winget install Microsoft.PowerShell`) or extract the official `PowerShell-7.x-win-x64.zip` to `pipeline/tools/pwsh/`. On some machines the MSI fails under winget with `0x80070005`; the portable zip avoids it.

## ffmpeg / ffprobe (required)

Any recent build on PATH, for example `winget install Gyan.FFmpeg` or `choco install ffmpeg`. Used for video frame sampling, contact sheets, thumbnails, preview clips and video checks.

## Node.js and pnpm (web-viewer)

Node.js 24 (tested with 24.22.1, official `node-v24.22.1-win-x64.zip`, SHA-256 `d2046d28c2c3dcd211ac5145c0bf30e2047ef9dfb306693c8c6e2eccd8b95fa5`; older versions are untested), installed or extracted to `pipeline/tools/node/` and put on PATH for the session:

```powershell
$env:PATH = "$PWD\pipeline\tools\node;" + $env:PATH
```

Then `corepack enable` (or `npm install -g pnpm`) and `pnpm install` in `web-viewer/`.

## Keeping tools current

Check for new versions about once a month:

```powershell
powershell -ExecutionPolicy Bypass -File .\pipeline\tools\installers\check-updates.ps1
```

It prints installed and latest versions of LichtFeld Studio (newest tag), COLMAP, PowerShell 7, Node.js (same major line), ffmpeg, the pinned `web-viewer` packages and the optional `pyseg` venv, and marks each newer one `UPDATE`. It changes nothing.

Treat each upgrade as an evaluation, not just an install:

1. **Baseline.** Pick a finished reference scene that exercises the stage being upgraded (a large set for COLMAP, a fisheye set for LichtFeld `--gut`) and note its current numbers from `pipeline\stats.ps1 -Table`.
2. **Install next to the old version** where you can (a new `tools\colmap-<version>-cuda` folder; for LichtFeld, keep the old `tools\lichtfeld` until the new build passes) and point the pipeline at it with `COLMAP_PATH` / `LICHTFELD_PATH`.
3. **Read the upstream changelog** for new options: faster matchers or mappers, GPU paths for stages that run on the CPU today (or the reverse, where the CPU path is faster on this hardware), new training strategies, export formats or MCP operators.
4. **Re-run the reference scene** and compare per-stage wall time, GPU and CPU use, splat count, PSNR/SSIM and the viewer result with the baseline.
5. **Keep or roll back.** Record the version, recipe changes and before/after numbers in this file, then remove the old folder.

### Upgrade log

**2026-10-21** (RTX 6000 Ada, Threadripper PRO 7975WX, same reference scenes before and after):

| Tool | From → to | Result |
| --- | --- | --- |
| COLMAP | 4.2.0 → 4.2.1 | 525-frame pinhole set: SfM 44:26 → 38:18 (mapper −20%), 524/525 registered at 1.015 px (was 525/525, 1.010 px) |
| LichtFeld Studio | v0.5.3 → v0.5.4.1 | Pinhole, 525 images, masked: 27.7 → 29.9 it/s. 3DGUT (Wide), 407 images: 7.6 → 10.4 it/s, training 1:05:59 → 48:04. Renders from the published cameras look the same. Saves `project.licht` and writes `splat_<iter>.ply` only with `--export ply` (now passed by `run.ps1`); exposure correction is on by default. Same vcpkg baseline, but the dependency cache missed, so the first configure took 20 minutes |
| splat-transform | 3.4.0 → 3.10.2 | Odd-count GPU SOG crash and GPU decimation crash fixed; VR decimation back on the GPU, 1.5 M → 350 k in about 9 s (was 40 to 70 s on the CPU); `build-viewer.mjs` for one scene 87 → 24 s |
| supersplat-viewer | 1.31.1 → 1.38.1 | `viewer-patch.mjs` ported (7 anchors moved; Quality slider replaced Performance Mode; stock now tunes Quest XR sessions, which the /vr build overrides). Needs an in-browser and in-headset check before scenes are rebuilt and deployed |
| wrangler | 4.130.0 → 4.151.3 | Deploy dry run clean |
| PowerShell | 7.6.6 → 7.6.7 | Smoke tests pass |
| Node.js | 24.21.0 → 24.22.1 | Web-viewer scripts and pnpm install run |
| ffmpeg | 8.1 → 9.0.2 | `select-frames.ps1` picks the same 525 frames; Chocolatey upgrade needs an elevated shell |
| pyseg venv | torch 2.11.0+cu128 → 2.14.1+cu130, ultralytics 8.4.178 → 8.4.183 | Person masks match (mean IoU 0.9994 on 40 frames), 26% faster; torch 2.14 has no cu128 wheels |

Previous versions are kept in `pipeline/tools/_old/` until the new ones have run a real scene.
