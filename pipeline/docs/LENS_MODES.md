# Lens modes, fisheye input, and how the processor learns which one it has

Reference for capture sets. Facts below were verified on 2026-09-08 against the LichtFeld
Studio source (tag v0.5.3) and the v0.4.2 binary's `--help` output (`<scene>/lfs/flags.txt`).

## 1. Does LichtFeld accept fisheye source imagery?

Yes. COLMAP output produced with `--ImageReader.camera_model OPENCV_FISHEYE` feeds
directly into training. There are two paths, and the trainer refuses to run if neither is
selected for a distorted dataset (`src/training/trainer.cpp`, "Distorted images detected.
Use --gut or --undistort").

| Path | Flag | What happens | When to use |
| --- | --- | --- | --- |
| 3DGUT (native) | `--gut` | Each Gaussian is projected through the actual fisheye model. Images are used as shot, full field of view is kept. | Default for Wide/fisheye. The pipeline adds this flag automatically for `OPENCV_FISHEYE`. |
| On-the-fly undistort | `--undistort` | LichtFeld remaps each image to a pinhole view at load time and trains with the standard rasterizer. | Fallback if 3DGUT misbehaves. Crops or stretches the outer field on wide lenses. |
| COLMAP undistort | none | `colmap image_undistorter` writes pinhole images and a PINHOLE model; LichtFeld trains as plain pinhole. | What the pipeline does for `OPENCV` (Linear) sets. |

Camera models the 3DGUT path supports per `docs/docs/features/gut.md`: SIMPLE_PINHOLE,
PINHOLE, SIMPLE_RADIAL, RADIAL, OPENCV, FULL_OPENCV, OPENCV_FISHEYE, RADIAL_FISHEYE,
SIMPLE_RADIAL_FISHEYE. THIN_PRISM_FISHEYE is also handled in the CUDA kernels. Both `--gut`
and `--undistort` are present in v0.4.2 and v0.5.3.

### 180 and 360 imagery

- Single-lens 180 degree fisheye (one hemisphere of an Insta360, Canon dual fisheye) works
  in principle through OPENCV_FISHEYE plus 3DGUT. The limit is COLMAP: the OpenCV fisheye
  polynomial is unstable near 90 degrees off-axis, so calibration and matching at the rim
  tend to fail. Expect to mask or crop the outer rim. Not exercised yet.
- 360 equirectangular is supported natively in the v0.5.3 source (COLMAP camera model id
  17, `EQUIRECTANGULAR`, legacy name `SPHERICAL` accepted). The rasterizer handles it
  without undistortion. This needs a COLMAP build that emits that model; the stock COLMAP
  4.2.0 release does not. Treat as experimental and confirm the flag set in
  the binary you train with before relying on it.

## 2. GoPro lens mode to COLMAP camera model

| GoPro mode | Pipeline `-Lens` value | COLMAP model | Training path |
| --- | --- | --- | --- |
| Linear | `linear` | `OPENCV` | COLMAP undistort, pinhole |
| Linear + Horizon Lock / Leveling | `linear-hl` | `OPENCV` | COLMAP undistort, pinhole |
| Narrow | `narrow` | `OPENCV` | COLMAP undistort, pinhole |
| Wide | `wide` | `OPENCV_FISHEYE` | 3DGUT (`--gut`) |
| SuperView | `superview` | none | **Rejected** |
| HyperView | `hyperview` | none | **Rejected** |
| Non-GoPro rectilinear lens | `pinhole` | `OPENCV` | COLMAP undistort, pinhole |
| Non-GoPro fisheye lens | `fisheye` | `OPENCV_FISHEYE` | 3DGUT (`--gut`) |

SuperView and HyperView are not lenses. They are a horizontal, non-uniform stretch of the
Wide readout applied in camera. No COLMAP camera model fits that warp, so a set shot in
either mode cannot be reconstructed accurately. Re-shoot in Wide or Linear.

## 3. Wide or Linear for future sets?

Recommendation: shoot Wide and reconstruct with `OPENCV_FISHEYE` plus 3DGUT.

Why:

- Wide keeps the full sensor field of view (about 120 degrees horizontal on HERO11/12).
  Linear is an in-camera rectilinear dewarp of that same readout, which crops to roughly
  90 degrees and stretches the corners. More field of view per frame means more overlap
  between neighbouring frames and between cameras, which is what makes COLMAP registration
  robust and lets you cover a subject with fewer frames.
- Linear applies a software resample before you ever see the pixels. Wide hands the
  reconstruction the least-processed image the camera can produce.
- 3DGUT trains on the distorted images directly, so nothing is cropped or resampled on the
  way into LichtFeld.

Costs of Wide:

- 3DGUT is slower per iteration than the plain rasterizer. The 3DGUT paper and gsplat
  report roughly 1.5 to 2 times; on an RTX 6000 Ada, full-resolution 27 MP Wide frames
  trained at 8.2 it/s against 22.1 it/s for undistorted Linear frames capped at 3840 px,
  which mixes the 3DGUT cost with the larger images.
- COLMAP fisheye calibration has more parameters to solve. On a well-covered orbit this is
  a non-issue; on sparse coverage it can drift.
- Any future viewer or tool that only understands pinhole cameras needs an undistorted
  export. The trained splat itself is camera-agnostic; only the training cameras are
  fisheye.

Linear remains a valid, simpler choice, processed as `OPENCV` with COLMAP undistortion. To
settle the question for your rig, shoot one subject in both modes and compare registration
rate, mean reprojection error, final loss, and wall time from the metrics files.

## 4. Signalling the lens mode to the processor

GoPro stills do not record the lens mode. Verified on HERO12 Black JPEGs:
EXIF carries the body name, firmware `H23.01.02.40.70`, timestamps, and a serial, and
nothing about Wide versus Linear. The 35 mm-equivalent focal length field does not
discriminate either (a Linear set reported 15 mm). GoPro video GPMF likewise has no
reliable lens-mode tag. Detection from metadata is therefore not attempted; the operator
supplies the value and the pipeline persists it.

Resolution order in `run.ps1`:

1. `-CameraModel OPENCV|OPENCV_FISHEYE` on the command line (explicit COLMAP model).
2. `-Lens <mode>` on the command line (values in the table above).
3. `capture.json` in the scene root, key `lens`.

Whatever wins is written back to `<scene>/capture.json` so stage-only reruns (for example
`-Stage train` or `-Stage export`) do not need the flag again. The resolved lens and model
are logged as a `LENS` line in `log.txt` and recorded in `colmap/sfm.metrics.json` and
`lfs/training.metrics.json`.

Minimal hand-written manifest, dropped next to the camera folders before the first run:

```json
{ "lens": "wide" }
```

Optional keys: `notes` (free text: bodies, firmware, capture settings) and `cameras`
(per-camera objects with their own `lens`). Per-camera values must all agree with the
scene value; COLMAP is run once with one camera model for every folder, so mixed lens
modes are rejected rather than silently modelled with the wrong lens.

Guard rails:

- The lens is required for `sfm`, `train`, and `all`. It is not required for `export` or
  `orbit`. A missing lens fails immediately with the three ways to set it.
- A command-line value that disagrees with an existing `capture.json` fails unless
  `-Force` is given, because the COLMAP and LichtFeld output on disk were built for the
  recorded value. `-Force` rewrites the manifest and rebuilds.
- `-Lens` and `-CameraModel` given together must agree.
- Before training, the script decodes `sparse/0/cameras.bin` and fails if the camera
  model on disk does not match the declared lens. This catches a manifest edited after
  SfM ran.

Equivalent invocations for a Wide set:

```powershell
pwsh -File .\pipeline\run.ps1 -Scene <name> -Lens wide
pwsh -File .\pipeline\run.ps1 -Scene <name> -CameraModel OPENCV_FISHEYE
# or write { "lens": "wide" } to <scene>\capture.json and run with no lens flag
```

## 5. Capture checklist to make the next set self-describing

- Set all bodies to the same lens mode. Mixed modes are rejected.
- Write `capture.json` with `lens` and a `notes` line naming the bodies and mode as soon
  as the cards are copied, while the setting is still known.
- Do not use SuperView or HyperView.
- If shooting video instead of stills, the same rules apply; frame extraction does not
  change the lens model.
