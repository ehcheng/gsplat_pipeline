#requires -Version 7.0
<#
.SYNOPSIS
  Keep the sharpest frame of every N frames of a video, as full-resolution JPEGs.

.DESCRIPTION
  For handheld video (a phone, or any camera without GoPro-style interval stills). Sampling at a
  fixed rate picks whatever frame lands on the tick, including ones softened by motion blur or a
  focus hunt; this picks the best frame in each window instead, so the output keeps an even
  spacing along the path with the soft frames left out.

  Pass 1 decodes the video at 960 px on the long side, in grey, and scores every frame: the
  variance of the Laplacian in each tile of a 16x9 grid, averaged over the 6 sharpest tiles.
  Using only the sharpest tiles keeps sky, walls and other flat areas from dragging the score
  down. Pass 2 decodes at full resolution and writes the best frame of each window of -Window
  frames as <Prefix>_<frame>.jpg, where <frame> is the zero-based index in the video.

  Both passes read every frame in decode order (-fps_mode passthrough), so frame indices are
  exact for variable-frame-rate phone video. Needs ffmpeg 5.1 or later and ffprobe.
  run.ps1 calls this for -SharpestOf; it can also be run on its own.

.EXAMPLE
  .\pipeline\select-frames.ps1 -Video .\_workspace\20261015_plaza\raw\cam1.mp4 -OutDir .\staged\cam1 -Window 5
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Video,
    [Parameter(Mandatory)] [string] $OutDir,
    [ValidateRange(1, 600)] [int] $Window = 5,
    [string] $Prefix,
    [ValidateRange(1, 31)] [int] $Quality = 2,
    [string] $ReportPath,
    [string] $FfmpegPath = 'ffmpeg',
    [string] $FfprobePath = 'ffprobe'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not ('GsplatFrameSelect' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;

public static class GsplatFrameSelect
{
    static string Quote(string s) { return "\"" + s + "\""; }

    static Process Start(string exe, string args, bool stdin, bool stdout)
    {
        var psi = new ProcessStartInfo(exe, args) { UseShellExecute = false, RedirectStandardInput = stdin, RedirectStandardOutput = stdout };
        return Process.Start(psi);
    }

    static bool ReadFull(Stream s, byte[] buf)
    {
        int got = 0;
        while (got < buf.Length) { int n = s.Read(buf, got, buf.Length - got); if (n <= 0) return false; got += n; }
        return true;
    }

    static void Finish(Process p, string what)
    {
        p.WaitForExit();
        if (p.ExitCode != 0) throw new Exception(what + " exited with code " + p.ExitCode);
    }

    // Mean of the `top` largest per-tile Laplacian variances of each grey w x h frame.
    public static double[] Score(string ffmpeg, string video, int w, int h, int gx, int gy, int top)
    {
        string args = "-v error -nostdin -i " + Quote(video) + " -an -sn -dn -vf scale=" + w + ":" + h + ":flags=area -fps_mode passthrough -f rawvideo -pix_fmt gray -";
        var p = Start(ffmpeg, args, false, true);
        var frame = new byte[w * h];
        int lw = w - 2, lh = h - 2, tw = lw / gx, th = lh / gy;
        var sum = new double[gx * gy]; var sq = new double[gx * gy]; var tiles = new double[gx * gy];
        var scores = new List<double>();
        var stream = p.StandardOutput.BaseStream;
        while (ReadFull(stream, frame))
        {
            Array.Clear(sum, 0, sum.Length); Array.Clear(sq, 0, sq.Length);
            for (int y = 0; y < th * gy; y++)
            {
                int row = (y + 1) * w, ty = (y / th) * gx;
                for (int x = 0; x < tw * gx; x++)
                {
                    int i = row + x + 1;
                    double v = frame[i - w] + frame[i + w] + frame[i - 1] + frame[i + 1] - 4.0 * frame[i];
                    int t = ty + x / tw;
                    sum[t] += v; sq[t] += v * v;
                }
            }
            double n = (double)tw * th;
            for (int t = 0; t < tiles.Length; t++) { double m = sum[t] / n; tiles[t] = sq[t] / n - m * m; }
            Array.Sort(tiles);
            double s = 0; for (int k = 0; k < top; k++) s += tiles[tiles.Length - 1 - k];
            scores.Add(s / top);
        }
        Finish(p, "ffmpeg (scoring)");
        return scores.ToArray();
    }

    // Decodes w x h RGB frames and pipes the picked ones to a JPEG encoder writing outPattern. RGB,
    // not YUV, so the decoder converts with the source's range and matrix tags (a raw pipe drops them).
    // Returns the number of frames decoded.
    public static int Extract(string ffmpeg, string video, int w, int h, int[] picks, string outPattern, int quality)
    {
        var want = new HashSet<int>(picks);
        var dec = Start(ffmpeg, "-v error -nostdin -i " + Quote(video) + " -an -sn -dn -fps_mode passthrough -f rawvideo -pix_fmt rgb24 -", false, true);
        var enc = Start(ffmpeg, "-v error -y -f rawvideo -pix_fmt rgb24 -s " + w + "x" + h + " -i - -pix_fmt yuvj420p -q:v " + quality + " -start_number 0 " + Quote(outPattern), true, false);
        var frame = new byte[w * h * 3];
        var input = dec.StandardOutput.BaseStream; var output = enc.StandardInput.BaseStream;
        int index = 0;
        while (ReadFull(input, frame))
        {
            if (want.Contains(index)) output.Write(frame, 0, frame.Length);
            index++;
        }
        output.Close();
        Finish(dec, "ffmpeg (decoding)");
        Finish(enc, "ffmpeg (JPEG encoding)");
        return index;
    }
}
'@
}

function Resolve-Tool([string] $Value) {
    $cmd = Get-Command $Value -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) { throw "Not found: $Value" }
    return $cmd.Source
}
$ffmpeg  = Resolve-Tool $FfmpegPath
$ffprobe = Resolve-Tool $FfprobePath
$videoPath = (Resolve-Path -LiteralPath $Video).Path
if (-not $Prefix) { $Prefix = [IO.Path]::GetFileNameWithoutExtension($videoPath) }

# Decoded size: ffmpeg applies the rotation metadata phones write for portrait clips.
$probe = & $ffprobe -v error -select_streams v:0 -show_entries 'stream=width,height:stream_tags=rotate:stream_side_data=rotation' -of json $videoPath | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $probe.streams) { throw "ffprobe found no video stream in $videoPath" }
$stream = $probe.streams[0]
$rotation = 0
if ($stream.PSObject.Properties['side_data_list']) { foreach ($d in $stream.side_data_list) { if ($d.PSObject.Properties['rotation']) { $rotation = [int]$d.rotation } } }
elseif ($stream.PSObject.Properties['tags'] -and $stream.tags.PSObject.Properties['rotate']) { $rotation = [int]$stream.tags.rotate }
$width, $height = [int]$stream.width, [int]$stream.height
if ([math]::Abs($rotation) % 180 -eq 90) { $width, $height = $height, $width }
if ($width % 2 -or $height % 2) { throw "Odd frame size ${width}x${height} is not supported." }

$landscape = $width -ge $height
$long = 960
$short = 2 * [int][math]::Round($long * [math]::Min($width, $height) / [math]::Max($width, $height) / 2)
$sw, $sh, $gx, $gy = if ($landscape) { $long, $short, 16, 9 } else { $short, $long, 9, 16 }

$started = Get-Date
Write-Host "select-frames: scoring $([IO.Path]::GetFileName($videoPath)) (${width}x${height}, rotation $rotation) at ${sw}x${sh}"
$scores = [GsplatFrameSelect]::Score($ffmpeg, $videoPath, $sw, $sh, $gx, $gy, 6)
if ($scores.Length -eq 0) { throw "No frames decoded from $videoPath" }
$picks = for ($start = 0; $start -lt $scores.Length; $start += $Window) {
    $best = $start
    for ($i = $start + 1; $i -lt [math]::Min($start + $Window, $scores.Length); $i++) { if ($scores[$i] -gt $scores[$best]) { $best = $i } }
    $best
}
$picks = [int[]]@($picks)

# The encoder numbers its output 0..n-1; each file is then renamed to its source frame index.
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$temp = Join-Path $OutDir '.select-frames'
if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
New-Item -ItemType Directory -Path $temp | Out-Null
Write-Host "select-frames: writing $($picks.Length) of $($scores.Length) frames (sharpest of every $Window)"
$decoded = [GsplatFrameSelect]::Extract($ffmpeg, $videoPath, $width, $height, $picks, (Join-Path $temp '%06d.jpg'), $Quality)
if ($decoded -ne $scores.Length) { throw "Frame count changed between passes ($($scores.Length) scored, $decoded decoded)." }
for ($k = 0; $k -lt $picks.Length; $k++) {
    $target = Join-Path $OutDir ('{0}_{1:D5}.jpg' -f $Prefix, $picks[$k])
    Move-Item -LiteralPath (Join-Path $temp ('{0:D6}.jpg' -f $k)) -Destination $target -Force
}
Remove-Item -LiteralPath $temp -Recurse -Force

$sorted = [double[]]$scores.Clone(); [Array]::Sort($sorted)
$keptScores = [double[]]@($picks | ForEach-Object { $scores[$_] }); [Array]::Sort($keptScores)
$result = [ordered]@{
    source = $videoPath; width = $width; height = $height; window = $Window
    totalFrames = $scores.Length; kept = $picks.Length
    medianScore = $sorted[[int]($sorted.Length / 2)]; medianKeptScore = $keptScores[[int]($keptScores.Length / 2)]
    seconds = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
    frames = $picks; scores = @($scores | ForEach-Object { [math]::Round($_, 1) })
}
if ($ReportPath) { $result | ConvertTo-Json -Depth 3 -Compress | Set-Content -LiteralPath $ReportPath -Encoding utf8 }
Write-Host ("select-frames: kept {0} of {1} frames in {2} s (median sharpness {3:F0} overall, {4:F0} kept)" -f $result.kept, $result.totalFrames, $result.seconds, $result.medianScore, $result.medianKeptScore)
[pscustomobject]$result | Select-Object source, totalFrames, kept, window, seconds
