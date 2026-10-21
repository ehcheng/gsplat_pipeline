# Phone video to Gaussian splat

The pipeline was built around a rig of GoPros, but a single handheld video from a phone works well. The reference capture for this guide is a 44-second 4K60 clip from a phone's 0.6x ultrawide camera (HONOR Magic V6), walking one loop around a group seated at a table while other people walked past in the background. It registered every selected frame in COLMAP and trained to a clean splat with no manual frame culling.

This page covers shooting, the commands, and an optional masking step for people who walk through the shot.

## Shooting

- **Use the ultrawide.** A wider view means more overlap between frames and more of the surroundings in every frame. Phone ultrawide video comes out of the camera already corrected for lens distortion, so it is treated as an ordinary rectilinear lens (`-Lens pinhole`). COLMAP fitted almost no residual distortion on the reference clip (k1 = 0.002).
- **4K at 60 fps if the phone offers it.** At 60 fps each frame has a shorter exposure, so there is less motion blur, and frame selection has five candidates to choose from for every frame it keeps (at a window of 5).
- **Leave stabilization on.** The reference clip was stabilized, and stabilization did not hurt registration.
- **Shoot SDR.** Turn off HDR, HLG and Dolby Vision video. Frames are extracted as 8-bit JPEGs with no tone mapping, so HDR footage looks flat and washed out.
- **Lock exposure and focus** if the camera app allows it (usually a long press on the subject). Brightness that changes during the loop shows up as blotchy color in the splat.
- **Walk slowly around the subject** and keep it near the middle of the frame. One full loop at chest height is enough for a small scene. A second loop higher or lower fills in the tops and undersides.
- **Keep your fingers clear of the lens.** An ultrawide sees far into the corners. On the reference clip a fingertip was in the bottom-right corner of nearly half the frames. It can be masked out afterwards (see below), but it is easier not to capture it.
- **People who stand still are fine.** People who walk through the shot leave smeared ghosts unless they are masked.

## Frame selection

`run.ps1` normally samples videos at a fixed `-Fps` (default 3), which takes whatever frame lands on each tick. That suits a GoPro on a steady rig. With a handheld phone some of those frames are soft from motion or from focus hunting. `-SharpestOf N` scores every frame and keeps the sharpest one in each run of N frames, so the frames stay evenly spaced along your path and the soft ones are dropped.

Pick N so that the result is 300 to 800 frames: N ≈ total frames ÷ target. A 44-second clip at 60 fps has about 2,600 frames, so `-SharpestOf 5` keeps 525.

Each frame is scored on a 960-pixel-wide grey copy: the frame is split into a 16 × 9 grid of tiles, the variance of the Laplacian is measured in every tile, and the six sharpest tiles are averaged. Averaging only the sharpest tiles stops sky, walls and other plain areas from pulling the score down. A second pass decodes the video at full resolution and writes the chosen frames as `cam1_<frame>.jpg`, where `<frame>` is the frame's index in the video. Both passes read every decoded frame in order, so the indices stay exact even though phones record at a variable frame rate. Portrait clips are handled through the rotation stored in the file.

The scores and the chosen frames are saved to `<scene>\extract.cam1.selection.json`. The step needs only ffmpeg 5.1 or later and ffprobe, and takes about two minutes for a 44-second 4K clip. `pipeline\select-frames.ps1` also runs on its own:

```powershell
.\pipeline\select-frames.ps1 -Video D:\clips\plaza.mp4 -OutDir D:\staging\cam1 -Window 5
```

## Steps

1. **Put the video in place.** Create `_workspace\<date>_<name>\raw\` and copy the clip in as `cam1.mp4`. Every video becomes its own camera folder with its own lens calibration, so if you shot several clips with the same lens, either join them first or accept that each gets a separate calibration (which also works).

2. **Reconstruct and train:**

   ```powershell
   .\pipeline\reconstruct.cmd .\_workspace\20261015_plaza -Lens pinhole -SharpestOf 5
   ```

   Add `-DryRun` first to see the image count and time estimate. `-Lens pinhole` is saved to `capture.json`, so later runs do not need it.

3. **Check the result** as for any scene: `colmap\sfm.metrics.json` should show close to 100 percent registration and a reprojection error of about 1 px, and `runs\<timestamp>\stats.md` has the timings. Then level, frame and publish it as described in the main README.

On the reference clip (RTX 6000 Ada, 32-core CPU): 525 of 2,621 frames kept; COLMAP's sequential matcher and incremental mapper registered 525 of 525 at 1.01 px in 44 minutes; training for 30,000 iterations at a 1.5 M splat cap took 18 minutes. Video frames come in path order, which suits sequential matching. For clips that yield well over 1,000 frames, COLMAP's `global_mapper` is much faster than the incremental mapper (see `PIPELINE.md`).

## Optional: masking people and fingers

When people walk through the shot, or a finger covers part of the lens, you can tell LichtFeld to ignore those pixels with per-image masks. White pixels are trained and black pixels are ignored. The pipeline does not make the masks itself, because what needs masking differs from clip to clip. This is a good job for an AI coding agent: describe what is in the shot and have it write the masking scripts for that clip. The reference scene used this approach:

- **People.** A person-segmentation model (YOLO11x-seg from Ultralytics, run on the GPU) outlines every person in every selected frame. Each person is then placed in 3D using the COLMAP points that fall inside the outline. People near the center of your loop are the subject and are kept. People far from it, and people with too few matched 3D points to place (anyone moving does not get matched consistently between frames), are masked. On the reference clip the seated subjects sat within 0.6 loop radii of the center and passers-by beyond 1.0, so the cutoff was easy to pick (0.75).
- **Fingers.** A fingertip in front of an ultrawide lens is far out of focus, so it shows up as a region with almost no texture growing in from one corner. A local sharpness measure finds it reliably.
- **Dilate** each masked region by a few pixels to cover soft edges.

Masks must match the images LichtFeld trains on. For `-Lens pinhole` those are the undistorted copies in `colmap\undistorted\images\cam1\`, so make the masks on the original frames and warp them the same way:

1. Run extract and sfm (`reconstruct.cmd ... -Stages extract,sfm`).
2. Write one mask per frame on the original frames as `masks_src\cam1\<same name>.jpg`, with the same file names as the images.
3. Warp them with the scene's camera model: `colmap image_undistorter --image_path masks_src --input_path <scene>\colmap\sparse\0 --output_path masks_undist --output_type COLMAP --max_image_size 3840`.
4. Run `pwsh -File .\pipeline\run.ps1 -Scene <scene> -Stage train -MaskMode ignore` once. It creates `colmap\undistorted\` and then stops because there are no masks yet.
5. Threshold the warped masks at 128 and save them as PNG in `colmap\undistorted\masks\cam1\<stem>.png` (for `cam1_00042.jpg`, `cam1_00042.png`).
6. Run the same `run.ps1 -Stage train -MaskMode ignore` command again to train with the masks.
