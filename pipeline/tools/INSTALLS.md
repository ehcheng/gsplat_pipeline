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
- **Build from source** into `tools/lichtfeld/`, which is what the reference setup uses (v0.5.3):

  ```powershell
  # once, from an elevated PowerShell: VS 2022 Build Tools + Clang, CUDA 12.8 toolkit, CMake, Ninja, Git, long paths
  powershell -ExecutionPolicy Bypass -File .\pipeline\tools\installers\install-toolchain.ps1
  # then, not elevated: clones the tagged source and vcpkg, configures, builds, installs
  powershell -ExecutionPolicy Bypass -File .\pipeline\tools\installers\build-lichtfeld.ps1 -Tag v0.5.3
  ```

  The recipe mirrors upstream's `.github/workflows/nightly.yml` (build-windows job): `cmake -B build -S . -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_PORTABLE=ON -DBUILD_PYTHON_STUBS=OFF`, then `cmake --install build --prefix pipeline/tools/lichtfeld`. The first configure takes about 50 minutes (vcpkg builds about 90 dependency ports); the compile about 20 minutes on 64 threads. The result is a portable folder of about 550 MB; kernels ship as PTX and JIT-compile for your GPU on first launch. `-Reconfigure` wipes the build folder. No cuDNN is needed, and the CUDA installer runs with `-noDisplayDriver`, so your NVIDIA driver is left alone.

- **Linux:** LichtFeld builds on Linux too, but this pipeline's scripts are Windows-only.

Check a build with `LichtFeld-Studio.exe --version` and `--help`: training needs `--headless --train --strategy --max-cap --iter` and, for fisheye sets, `--gut`. In GUI mode v0.5+ starts its MCP server on `127.0.0.1:45677`.

## COLMAP (required)

Use a CUDA build. The reference setup uses the official 4.2.0 release:

- Asset: `colmap-x64-windows-cuda.zip` from the `colmap/colmap` GitHub release 4.2.0 (commit `be5e291`)
- SHA-256: `991E0BAE403A496FCC4DE0C1F1F428619BF12F8000978F77BC6799D9BFEAC23E`
- Extract to `pipeline/tools/colmap-4.2.0-cuda/` so that `bin/colmap.exe` exists

COLMAP 3.x also works; `run.ps1` reads `colmap <command> -h` and picks the 3.x (`SiftExtraction`) or 4.x (`FeatureExtraction`) option names.

## PowerShell 7 (required)

Install it machine-wide (`winget install Microsoft.PowerShell`) or extract the official `PowerShell-7.x-win-x64.zip` to `pipeline/tools/pwsh/`. On some machines the MSI fails under winget with `0x80070005`; the portable zip avoids it.

## ffmpeg / ffprobe (required)

Any recent build on PATH, for example `winget install Gyan.FFmpeg` or `choco install ffmpeg`. Used for video frame sampling, contact sheets, thumbnails, preview clips and video checks.

## Node.js and pnpm (web-viewer)

Node.js 24 (tested with 24.21.0, official `node-v24.21.0-win-x64.zip`, SHA-256 `158f7685b44de51f6c0df1d153526cbcd3e1bc739a8dfc607721cef75de9e541`; older versions are untested), installed or extracted to `pipeline/tools/node/` and put on PATH for the session:

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
