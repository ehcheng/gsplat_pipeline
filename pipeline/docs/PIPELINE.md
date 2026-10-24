# Pipeline reference: multi-GoPro capture to Gaussian splat and orbit video

Stage-by-stage reference for `pipeline/run.ps1`. Everything here has been checked against
the tools listed below unless the text says otherwise. Companion documents:

- `docs/LENS_MODES.md`: lens mode to camera model, fisheye support in LichtFeld, how the
  operator signals the lens.
- `tools/INSTALLS.md`: how to install the tools, where the scripts look for them, versions.
- `../README.md`: quick start and command lines.

## 0. Environment

| Item | Requirement (reference setup in brackets) |
| --- | --- |
| OS | Windows 10 or 11, 64-bit (Windows 11 Pro) |
| GPU | NVIDIA GPU that LichtFeld Studio supports; more VRAM allows a higher splat cap (RTX 6000 Ada, 48 GB) |
| CUDA driver | Recent NVIDIA driver (CUDA driver API 13.2) |
| PowerShell | 7.x, on PATH or portable at `pipeline/tools/pwsh/pwsh.exe` |
| COLMAP | CUDA build, 3.x or 4.x, on PATH, `COLMAP_PATH`, or under `pipeline/tools/colmap*/` (4.2.1 CUDA release) |
| LichtFeld Studio | v0.4+ for training; v0.5+ for the MCP export and orbit stages. On PATH, `LICHTFELD_PATH`, or `pipeline/tools/lichtfeld/` (v0.5.4.1 built from source) |
| ffmpeg / ffprobe | on PATH or passed via `-FfmpegPath` / `-FfprobePath` |
| Scene root | `<repo>\_workspace\<scene>` (override with `-Root`) |

Before the first run of a new LichtFeld build, launch it once and confirm it lists the GPU.
`run.ps1` records the CLI help of whatever binary it trains with in `<scene>/lfs/flags.txt`
and refuses to use flags that are absent from it.

## 1. Scene layout

```text
<scene>/
  capture.json                 lens mode and capture notes (see LENS_MODES.md)
  cam1/ cam2/ cam3/            stills, one folder per physical camera   (or)
  raw/cam1.mp4 ...             one video per camera                      (or)
  raw/cam1/ ...                stills under raw
  images/<cam>/                staged frames (hard links when possible)
  extract.complete.json        extract marker (kept out of images/ so COLMAP does not try to read it)
  colmap/database.db
  colmap/images -> ../images   junction so LichtFeld sees images beside sparse/
  colmap/sparse/0/             cameras.bin images.bin points3D.bin
  colmap/sfm.metrics.json
  colmap/undistorted/          pinhole copy, OPENCV (Linear) sets only
  lfs/flags.txt                LichtFeld --help of the binary used
  lfs/checkpoints/             *.resume (v0.5.3)
  lfs/project.licht            training project (v0.5.4 and later)
  lfs/training.metrics.json
  lfs/splat_<iter>.ply         written by LichtFeld at the end of training
  lfs/<scene>.ply lfs/<scene>.spz   MCP exports
  lfs/mcp-catalog.json         live MCP tool and resource discovery
  renders/orbit_plan.json renders/orbit_keyframes.json
  renders/<scene>_orbit_4k.mp4 renders/orbit.metrics.json
  log.txt                      every command line, output, and stage result
```

One folder per camera matters. COLMAP's `--ImageReader.single_camera_per_folder 1` assigns
one intrinsics set per folder, which is right for three bodies and wrong if they are merged.

## 2. Extract stage

Stills are hard-linked into `images/<cam>/` (copied if the link fails). Videos are sampled
with ffmpeg at `-Fps` (default 3) into JPEG quality 2. With `-SharpestOf N`, `select-frames.ps1`
instead keeps the sharpest frame of every N decoded frames (tiled Laplacian variance) and
records scores and picks in `extract.<cam>.selection.json`; use it for handheld video (see
PHONE_VIDEO.md). Static subjects do not need temporal
sync between cameras. The stage fails if fewer than two camera folders or fewer than 20
images result.

Targets: 300 to 800 frames for a single-object orbit. More frames raise COLMAP time
superlinearly and add little past that range. The 545-image Linear reference set below used
three cameras (182, 182, 181 stills).

Blur rejection for stills is not implemented. If stills are soft, drop the bottom 20 percent
per camera by Laplacian variance before staging. For video, use `-SharpestOf`.

## 3. SfM stage (COLMAP)

Requires a resolved lens (see LENS_MODES.md, section 4). Commands, in order:

```powershell
colmap feature_extractor --database_path colmap\database.db --image_path images `
  --ImageReader.camera_model <OPENCV|OPENCV_FISHEYE> --ImageReader.single_camera_per_folder 1 `
  --FeatureExtraction.use_gpu 1
colmap sequential_matcher --database_path colmap\database.db `
  --SequentialMatching.overlap 20 --SequentialMatching.loop_detection 1 --FeatureMatching.use_gpu 1
colmap mapper --database_path colmap\database.db --image_path images --output_path colmap\sparse
```

The GPU option names differ between COLMAP releases (`SiftExtraction` in 3.x,
`FeatureExtraction` in 4.x); the script reads `-h` and picks whichever exists.

Sequential matching pairs neighbours within a folder plus loop closures. If it yields
anything other than exactly one model, the script wipes `sparse/`, runs
`exhaustive_matcher`, and maps again. Exhaustive on about 600 frames takes minutes on the
reference GPU. The Linear reference set (a car in a garage) needed the exhaustive fallback.

Past roughly 1,000 images the incremental `mapper` slows down badly. For large single-camera
sets, COLMAP's `global_mapper` registered 1,383 images in about an hour on the reference
machine; run it by hand in place of the sfm stage, then continue with `-Stage train`.

Success is exactly one model. `model_analyzer` output is parsed into `sfm.metrics.json`:
registered images, total, percent, and mean reprojection error. Reference numbers from the
545-image Linear set:

| Metric | Value |
| --- | --- |
| Registered | 545 / 545 |
| Mean reprojection error | 1.31 px |
| Matcher | exhaustive |

Under about 1 px is good; 1.3 px on undistorted GoPro Linear stills was acceptable in
practice. If COLMAP fails twice on a fisheye set, RealityScan (free under 1M USD revenue)
exported to COLMAP format is the alternative aligner. Not exercised yet.

## 4. Train stage (LichtFeld headless)

Preconditions checked by the script: one COLMAP model, a resolved lens, and the camera model
inside `sparse/0/cameras.bin` matching that lens.

Two paths, chosen by the camera model:

- `OPENCV` (Linear family): `colmap image_undistorter --output_type COLMAP --max_image_size 3840`
  writes `colmap/undistorted/` with a PINHOLE model. The image count must equal the staged
  count. LichtFeld trains on that folder with no distortion flags.
- `OPENCV_FISHEYE` (Wide): LichtFeld trains on `colmap/` directly with `--gut` (3DGUT).
  The script fails if the binary does not expose `--gut`. LichtFeld itself refuses distorted
  cameras unless `--gut` or `--undistort` is passed.

Command shape (flags verified in v0.4.2, v0.5.3 and v0.5.4.1):

```powershell
LichtFeld-Studio.exe --headless --train -d <dataset> -o <scene>\lfs `
  --strategy mcmc --max-cap 5000000 --iter 30000 [--gut] [--mask-mode ignore] [--export ply]
```

`--export ply` is added when the build lists it (v0.5.4 and later save only `project.licht`
otherwise); training fails if `lfs/splat_<iter>.ply` is missing afterwards.

The script polls `nvidia-smi` for the process's peak VRAM while training runs, appends
stdout and stderr to `log.txt`, requires a `.resume` or `.licht` checkpoint, and parses the
last `Loss:` value. Results go to `training.metrics.json` with lens, camera model, whether
3DGUT was used, dataset path, strategy, and cap.

Reference numbers from the 545-image Linear set (RTX 6000 Ada, v0.4.2, MCMC, 1.5M cap,
30k iterations, pinhole):

| Metric | Value |
| --- | --- |
| Final loss | 0.0413 |
| Wall time | 1376 s |
| Peak VRAM | not captured (nvidia-smi reported 0 for the process; open item) |

The default cap is 5M (`-MaxCap 5000000`) with photos scaled to 3840 px wide (`-MaxImageSize
3840`). Holdout scoring on two scenes (2026-10-23, one in eight photos held out, scored against
the full-resolution photo at 1920 and 3840 px) found that the splat cap is what raises
quality: 5M against 1.5M cut LPIPS by 15% on a 27 MP GoPro set and 8% on a 50 MP Sony set,
for 1.6x the training time. Full-resolution training scored no better than 3840 at either cap
and took 2 to 5 times as long, so `-MaxImageSize 0` is only worth it for scenes meant to be
inspected closer than 4K. 1.5M was the default before and still suits smaller GPUs. On the reference
machine, 410 Wide (27 MP fisheye) images trained through 3DGUT at 8.2 it/s against 22.1 it/s
for the undistorted Linear set, so a Wide set takes about an hour at 30k iterations.

To look at a result:

```powershell
& $env:LICHTFELD_PATH --view '.\_workspace\<scene>\lfs\splat_30000.ply'
```

## 5. Export and orbit stages (LichtFeld MCP)

These stages need a running LichtFeld v0.5.x with MCP enabled at
`http://127.0.0.1:45677/mcp` (`-McpEndpoint` to override). v0.4.2 has no MCP listener and
no export or sequencer CLI, so it cannot serve these stages.

Discovery-first contract, as implemented:

1. Initialise a session and list tools and resources; the catalogue is saved to
   `lfs/mcp-catalog.json`.
2. Read `lichtfeld://runtime/catalog`, `lichtfeld://runtime/state`,
   `lichtfeld://scene/state`, `lichtfeld://operators/registry`.
3. Only call tools whose schemas are present, with arguments filtered to that schema.
   Tool names are looked up under both `scene_export_ply` and `scene.export_ply` style
   names because builds differ.
4. Long jobs are awaited with `runtime.job.wait`; the script never sleep-polls.

Export loads the latest checkpoint, identifies the Gaussian node (`-SceneNode` if the
listing is ambiguous), and writes `lfs/<scene>.ply` and `lfs/<scene>.spz`. It verifies the
files exist rather than trusting the tool's success reply.

Orbit builds the camera path itself rather than using the 360 Record plugin. Scene bounds
come from the scene-state resource; if the build does not expose them, pass
`-OrbitCenter x,y,z -OrbitRadius r`. Geometry:

- radius = 2.5 x bounding radius
- eye height = center + 0.25 x radius
- `-OrbitKeyframes` points on a circle (default 24), all looking at the center

The plan is written to `renders/orbit_plan.json` before anything is pushed to the
sequencer, so a render is reproducible. Keyframes go through `sequencer.clear` and
`sequencer.add_keyframe`; the video tool is discovered from the catalogue and must be
unique. Output is `renders/<scene>_orbit_4k.mp4` at 3840x2160, 30 fps, 10 s by default.

The video is then checked with ffprobe and ffmpeg: exact resolution, duration within 5
percent, and no black frame at the start, middle, or end. Results go to
`renders/orbit.metrics.json`.

## 6. run.ps1 contract

```text
run.ps1 -Scene <name>
        [-Lens linear|linear-hl|narrow|pinhole|wide|fisheye | -CameraModel OPENCV|OPENCV_FISHEYE]
        [-Stage extract|sfm|train|export|orbit|all] [-Force] [-Fps 3 | -SharpestOf N]
        [-Iterations 30000] [-MaxCap 5000000] [-Strategy mcmc|mrnf|igs+]
        [-MaskMode none|ignore|segment|segment_and_ignore] [-MaxImageSize 3840] [-TrainArgs <flags>]
        [-OrbitKeyframes 24] [-OrbitDuration 10] [-OrbitFps 30] [-OrbitWidth 3840] [-OrbitHeight 2160]
        [-OrbitCenter x,y,z] [-OrbitRadius r] [-SceneNode <name>]
        [-Root <dir>] [-InputPath <dir>] [-ColmapPath] [-LichtFeldPath] [-FfmpegPath] [-FfprobePath] [-McpEndpoint]
```

- Each stage checks for its output and skips unless `-Force`.
- Every stage appends timestamps, exact command lines, and tool output to `log.txt`.
- Any failure stops the run with exit code 1; later stages do not execute.
- Lens resolution runs once at startup: `-CameraModel`, then `-Lens`, then `capture.json`.
  Required for sfm, train, all. The result is persisted to `capture.json`.
- Tool discovery: an explicit `-ColmapPath` / `-LichtFeldPath` wins; otherwise the
  `COLMAP_PATH` / `LICHTFELD_PATH` environment variable, then PATH, then the copies under
  `pipeline/tools` (`colmap*/bin/colmap.exe`, `lichtfeld/bin/LichtFeld-Studio.exe`).
- All deletes are confined to the scene directory (`Assert-SafeChild`).
- `-MaskMode` passes LichtFeld `--mask-mode` for scenes with transient content (passers-by,
  a finger over the lens). Masks live in `<dataset>/masks/<cam>/<stem>.png` in the training
  images' pixel space (the undistorted ones for Linear/pinhole), white = train, black =
  ignored; train refuses to start if the folder is empty. The scene must supply them, for
  example from a person-segmentation model run over the staged frames.
- `-MaxImageSize` is the largest training image dimension: COLMAP undistorts pinhole sets to
  it, and LichtFeld v0.5.4+ gets it as `--max-width`. 0 trains at full resolution. Changing it
  on a pinhole scene redoes the undistort step.
- `-TrainArgs` appends raw LichtFeld flags to the training command, for experiments such as
  holdout evaluation (`--eval --test-every 8`). Pass it as an array from PowerShell; it does
  not survive `pwsh -File`.
- `tests/smoke.ps1` parses the script, checks the parameter contract, unit-tests the lens
  table and the `cameras.bin` reader, and runs the lens resolution end to end against a
  throwaway scene. No GPU, no external tools.

## 7. Acceptance checks

Report these with numbers for every set:

1. LichtFeld launches and lists the GPU.
2. COLMAP: one model; registered / total; mean reprojection error (`colmap/sfm.metrics.json`).
3. Training: final iteration reached; final loss; wall time; peak VRAM (`lfs/training.metrics.json`).
4. Exports exist and open in SuperSplat (https://superspl.at/editor) without error.
5. Orbit MP4 exists at the requested resolution and duration with no black frames (`renders/orbit.metrics.json`).

## 8. Open items

- Peak VRAM reads 0 on Windows. `nvidia-smi --query-compute-apps` does not attribute memory
  to the LichtFeld PID (possibly a driver reporting change).
- `export` and `orbit` have not yet run against a finished scene. The MCP tool names in the
  script are candidates checked against the live catalogue, not confirmed constants.
- Wide vs Linear on the same subject is unmeasured. Shoot one subject in both modes and
  compare the two metrics files.
- Blur rejection is manual.
- Whether LichtFeld's COLMAP plugin (https://github.com/shadygm/Lichtfeld-COLMAP-Plugin)
  could replace the sfm stage via `operator.*` is unexplored; the CLI path is sufficient.

## 9. Per-run statistics

`reconstruct.ps1` assigns each run an id (`yyyyMMdd-HHmmss`, the wall-clock start) and writes `<scene>/runs/<id>/reconstruct.log`, a copy of every status line it printed with full timestamps. When the last stage finishes or fails it calls `stats.ps1 -Scene <scene> -RunId <id> -Status ok|failed -Quiet`, which reads only artifacts the stages already produced and writes `stats.json` (nested record, schema 1) and `stats.md` (summary) next to the log, and appends a flat row to `pipeline/runs.jsonl` (rows are keyed by run id and scene, so re-harvesting replaces the row).

Sources and what is derived from them:

| Source | Metrics |
|---|---|
| `log.txt` START/SUCCESS/FAILED lines | last run of each stage: start, end, seconds, status, error |
| `log.txt` COMMAND lines | per sub-step wall time (feature_extractor, sequential/exhaustive_matcher, mapper, model_analyzer, image_undistorter, train), share of total, seconds per image |
| COLMAP feature_extractor output | resolution, megapixels, SIFT features per image (mean/min/max), unreadable files |
| COLMAP mapper output | verified image pairs (and per image), registrations, discarded initial pairs, global bundle adjustments, mean visible-point fraction, registrations per minute |
| COLMAP model_analyzer output and `colmap/sfm.metrics.json` | registered images, points, observations, mean track length, observations per image, mean reprojection error |
| `lfs/training.stdout.log` and `lfs/training.metrics.json` | LichtFeld version, CUDA driver, loop seconds, iterations per second (measured and reported), seconds per 1k iterations, startup+shutdown overhead, loss (final, minimum, mean of last 1k iterations), loss/splats/rate at milestones, cap-reached iteration, splats per image and per sparse point, image-loader hit rate, arena peak, VRAM peak, warnings, errors |
| PLY header | vertices, properties, MiB, bytes per splat |
| `images/` and `extract.complete.json` | image count, per-camera counts, MiB on disk |
| nvidia-smi, WMI | GPU, driver, VRAM, CPU, cores, RAM |

`stats.ps1 -Table` prints one row per recorded run. Running `stats.ps1 <scene>` by hand re-harvests a finished scene (the run id is then taken from the earliest stage start in `log.txt`), which is how older scenes are backfilled.
