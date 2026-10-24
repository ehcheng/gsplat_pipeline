#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Scene,
    [ValidateRange(0.1, 120)] [double] $Fps = 3,
    [ValidateRange(0, 600)] [int] $SharpestOf = 0,
    [ValidateSet('OPENCV', 'OPENCV_FISHEYE')] [string] $CameraModel,
    [ValidateSet('linear', 'linear-hl', 'narrow', 'pinhole', 'wide', 'fisheye', 'superview', 'hyperview')] [string] $Lens,
    [ValidateSet('extract', 'sfm', 'train', 'export', 'orbit', 'all')] [string] $Stage = 'all',
    [switch] $Force,
    [string] $Root = (Join-Path (Split-Path -Parent $PSScriptRoot) '_workspace'),
    [string] $InputPath,
    [string] $FfmpegPath = 'ffmpeg',
    [string] $FfprobePath = 'ffprobe',
    [string] $ColmapPath = 'colmap',
    [string] $LichtFeldPath = 'LichtFeld-Studio',
    [uri] $McpEndpoint = 'http://127.0.0.1:45677/mcp',
    [ValidateRange(1, 1000000)] [int] $Iterations = 30000,
    [ValidateRange(10000, 10000000)] [int] $MaxCap = 5000000,
    [ValidateSet('mcmc', 'mrnf', 'igs+')] [string] $Strategy = 'mcmc',
    [ValidateSet('none', 'ignore', 'segment', 'segment_and_ignore')] [string] $MaskMode = 'none',
    [ValidateRange(0, 32768)] [int] $MaxImageSize = 3840,
    [string[]] $TrainArgs = @(),
    [ValidateRange(4, 120)] [int] $OrbitKeyframes = 24,
    [ValidateRange(1, 120)] [double] $OrbitDuration = 10,
    [ValidateRange(1, 240)] [int] $OrbitFps = 30,
    [ValidateRange(64, 8192)] [int] $OrbitWidth = 3840,
    [ValidateRange(64, 8192)] [int] $OrbitHeight = 2160,
    [string] $OrbitCenter,
    [Nullable[double]] $OrbitRadius,
    [string] $SceneNode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# A rooted path is used as given. A bare default name ('colmap', 'LichtFeld-Studio') is looked up
# in this order: the tool's environment variable (COLMAP_PATH, LICHTFELD_PATH), PATH, then a copy
# under pipeline\tools (tools\colmap*\bin\colmap.exe, tools\lichtfeld\bin\LichtFeld-Studio.exe).
# See tools\INSTALLS.md.
function Resolve-Executable([string] $Value, [string] $Label) {
    $envName = @{ 'COLMAP' = 'COLMAP_PATH'; 'LichtFeld Studio' = 'LICHTFELD_PATH'; 'ffmpeg' = 'FFMPEG_PATH'; 'ffprobe' = 'FFPROBE_PATH' }[$Label]
    $isDefault = $Value -in @('colmap', 'LichtFeld-Studio', 'ffmpeg', 'ffprobe')
    if ($isDefault -and $envName -and [Environment]::GetEnvironmentVariable($envName)) { $Value = [Environment]::GetEnvironmentVariable($envName) }
    if ([IO.Path]::IsPathRooted($Value)) {
        if (-not (Test-Path -LiteralPath $Value -PathType Leaf)) { throw "$Label was not found: $Value" }
        return (Resolve-Path -LiteralPath $Value).Path
    }
    $command = Get-Command $Value -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    $bundled = switch ($Label) {
        'COLMAP' { Get-ChildItem -Path (Join-Path $PSScriptRoot 'tools\colmap*\bin\colmap.exe') -File -ErrorAction SilentlyContinue | Sort-Object FullName | Select-Object -Last 1 }
        'LichtFeld Studio' { Get-Item -LiteralPath (Join-Path $PSScriptRoot 'tools\lichtfeld\bin\LichtFeld-Studio.exe') -ErrorAction SilentlyContinue }
    }
    if ($bundled) { return $bundled.FullName }
    throw "$Label was not found. Pass its full path, set $(if ($envName) { $envName } else { 'its path' }), put it on PATH, or install it under pipeline\tools (see pipeline\tools\INSTALLS.md)."
}

function Quote-Command([string] $Exe, [string[]] $Arguments) {
    $parts = @($Exe) + $Arguments
    return ($parts | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }) -join ' '
}

function Write-Log([string] $Message) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss.fffK'), $Message
    Add-Content -LiteralPath $script:LogPath -Value $line -Encoding utf8
    Write-Host $line
}

function Invoke-Logged([string] $Exe, [string[]] $Arguments, [switch] $Capture) {
    $line = Quote-Command $Exe $Arguments
    Write-Log "COMMAND $line"
    $output = & $Exe @Arguments 2>&1 | ForEach-Object { $_.ToString() }
    $exitCode = $LASTEXITCODE
    if ($output) { Add-Content -LiteralPath $script:LogPath -Value $output -Encoding utf8 }
    if ($exitCode -ne 0) { throw "Command failed with exit code $exitCode`: $line" }
    if ($Capture) { return ($output -join [Environment]::NewLine) }
}

function Assert-SafeChild([string] $Path, [string] $Parent) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $base = [IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
    if (-not $full.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to modify path outside the scene: $full"
    }
}

function Reset-Directory([string] $Path) {
    Assert-SafeChild $Path $script:ScenePath
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

function Write-Json([string] $Path, [object] $Value, [int] $Depth = 20) {
    $Value | ConvertTo-Json -Depth $Depth | Set-Content -LiteralPath $Path -Encoding utf8
}

# Lens mode -> COLMAP camera model. GoPro stills and video do not record the lens mode in
# EXIF or GPMF, so the operator must signal it (see docs/LENS_MODES.md). SuperView and
# HyperView are non-physical horizontal stretches of the Wide sensor readout; no COLMAP
# camera model fits them, so they are rejected rather than silently mis-modelled.
$script:LensTable = [ordered]@{
    'linear'    = @{ Model = 'OPENCV';         Label = 'GoPro Linear (in-camera rectilinear dewarp)' }
    'linear-hl' = @{ Model = 'OPENCV';         Label = 'GoPro Linear + Horizon Lock/Leveling' }
    'narrow'    = @{ Model = 'OPENCV';         Label = 'GoPro Narrow (cropped rectilinear)' }
    'pinhole'   = @{ Model = 'OPENCV';         Label = 'Generic rectilinear lens' }
    'wide'      = @{ Model = 'OPENCV_FISHEYE'; Label = 'GoPro Wide (native fisheye)' }
    'fisheye'   = @{ Model = 'OPENCV_FISHEYE'; Label = 'Generic fisheye lens (<= ~180 deg)' }
    'superview' = @{ Model = $null;            Label = 'GoPro SuperView (non-physical stretch; unsupported)' }
    'hyperview' = @{ Model = $null;            Label = 'GoPro HyperView (non-physical stretch; unsupported)' }
}

function Get-CaptureManifestPath { return (Join-Path $script:ScenePath 'capture.json') }

function Read-CaptureManifest {
    $path = Get-CaptureManifestPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json) }
    catch { throw "capture.json is not valid JSON: $path. $($_.Exception.Message)" }
}

function Convert-LensToModel([string] $LensName, [string] $Origin) {
    $key = $LensName.Trim().ToLowerInvariant()
    if (-not $script:LensTable.Contains($key)) {
        throw "Unknown lens '$LensName' from $Origin. Supported: $($script:LensTable.Keys -join ', ')."
    }
    $entry = $script:LensTable[$key]
    if (-not $entry.Model) {
        throw "Lens '$key' ($($entry.Label)) from $Origin cannot be reconstructed. SuperView/HyperView stretch the Wide image non-uniformly and no COLMAP camera model fits them. Re-shoot in Wide or Linear."
    }
    return [pscustomobject]@{ Lens = $key; Model = $entry.Model; Label = $entry.Label }
}

# Resolution order: -CameraModel (explicit COLMAP model) > -Lens > capture.json 'lens'.
# The outcome is persisted to capture.json so stage-only reruns (e.g. -Stage train) do not
# need the flag again. Disagreement between a persisted value and a CLI value is an error
# unless -Force, which rewrites the manifest.
function Resolve-CaptureLens([bool] $Required) {
    $manifest = Read-CaptureManifest
    $manifestLens = $null
    if ($manifest -and ($manifest.PSObject.Properties.Name -contains 'lens') -and $manifest.lens) { $manifestLens = [string]$manifest.lens }
    if ($manifest -and ($manifest.PSObject.Properties.Name -contains 'cameras') -and $manifest.cameras) {
        foreach ($property in $manifest.cameras.PSObject.Properties) {
            $perCamera = $property.Value
            if ($perCamera -and ($perCamera.PSObject.Properties.Name -contains 'lens') -and $perCamera.lens -and $manifestLens -and ([string]$perCamera.lens).ToLowerInvariant() -ne $manifestLens.ToLowerInvariant()) {
                throw "capture.json declares lens '$($perCamera.lens)' for camera '$($property.Name)' but '$manifestLens' for the scene. Mixed lens modes are not supported: COLMAP is run with one camera model for all folders."
            }
        }
    }

    $resolved = $null
    $source = $null
    if ($Lens) {
        $resolved = Convert-LensToModel $Lens 'parameter -Lens'
        $source = 'parameter -Lens'
        if ($CameraModel -and $CameraModel -ne $resolved.Model) {
            throw "-Lens $Lens maps to $($resolved.Model) but -CameraModel $CameraModel was also given. Pass one or the other."
        }
    } elseif ($CameraModel) {
        $resolved = [pscustomobject]@{ Lens = $(if ($CameraModel -eq 'OPENCV_FISHEYE') { 'fisheye' } else { 'pinhole' }); Model = $CameraModel; Label = "Explicit COLMAP model $CameraModel" }
        $source = 'parameter -CameraModel'
    }

    if ($manifestLens) {
        $fromManifest = Convert-LensToModel $manifestLens 'capture.json'
        if ($resolved -and $fromManifest.Model -ne $resolved.Model) {
            if (-not $Force) {
                throw "capture.json records lens '$manifestLens' ($($fromManifest.Model)) but the command line resolves to $($resolved.Model). Existing colmap/lfs output was built for the manifest value. Pass -Force to rebuild with the new lens, or drop the conflicting flag."
            }
            Write-Log "WARN lens override: capture.json had '$manifestLens'; command line wins because -Force was given."
        } elseif (-not $resolved) {
            $resolved = $fromManifest
            $source = 'capture.json'
        }
    }

    if (-not $resolved) {
        if ($Required) {
            throw "Lens mode is unknown and cannot be read from GoPro image metadata. Signal it with -Lens <$($script:LensTable.Keys -join '|')>, with -CameraModel OPENCV|OPENCV_FISHEYE, or by writing $(Get-CaptureManifestPath) containing {""lens"": ""linear""}. Linear/Linear+HL -> OPENCV; Wide -> OPENCV_FISHEYE."
        }
        return $null
    }

    $script:CameraModel = $resolved.Model
    if ($source -ne 'capture.json' -or -not $manifest) {
        $updated = [ordered]@{}
        if ($manifest) { foreach ($property in $manifest.PSObject.Properties) { $updated[$property.Name] = $property.Value } }
        $updated['lens'] = $resolved.Lens
        $updated['cameraModel'] = $resolved.Model
        $updated['lensSource'] = $source
        $updated['resolvedAt'] = (Get-Date).ToString('o')
        Write-Json (Get-CaptureManifestPath) $updated
    }
    Write-Log "LENS $($resolved.Lens) ($($resolved.Label)) -> COLMAP $($resolved.Model); source=$source"
    return $resolved
}

# Reads camera model ids from a COLMAP cameras.bin so the training stage can verify that the
# sparse model on disk matches the lens the operator declared (guards against stale output).
function Get-ColmapCameraModels([string] $CamerasBin) {
    $paramCounts = @{ 0=3; 1=4; 2=4; 3=5; 4=8; 5=8; 6=12; 7=5; 8=4; 9=5; 10=12; 17=2 }
    $names = @{ 0='SIMPLE_PINHOLE'; 1='PINHOLE'; 2='SIMPLE_RADIAL'; 3='RADIAL'; 4='OPENCV'; 5='OPENCV_FISHEYE'; 6='FULL_OPENCV'; 7='FOV'; 8='SIMPLE_RADIAL_FISHEYE'; 9='RADIAL_FISHEYE'; 10='THIN_PRISM_FISHEYE'; 17='EQUIRECTANGULAR' }
    $bytes = [IO.File]::ReadAllBytes($CamerasBin)
    $reader = [IO.BinaryReader]::new([IO.MemoryStream]::new($bytes))
    $count = $reader.ReadUInt64()
    $models = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $count; $i++) {
        $null = $reader.ReadInt32()
        $modelId = $reader.ReadInt32()
        $null = $reader.ReadUInt64(); $null = $reader.ReadUInt64()
        if (-not $paramCounts.ContainsKey($modelId)) { throw "cameras.bin contains unknown COLMAP camera model id $modelId." }
        for ($p = 0; $p -lt $paramCounts[$modelId]; $p++) { $null = $reader.ReadDouble() }
        $models.Add($names[$modelId])
    }
    return @($models | Sort-Object -Unique)
}

function Get-CameraSources([string] $SourceRoot) {
    $imageExtensions = @('.jpg', '.jpeg', '.png', '.tif', '.tiff', '.webp')
    $dirs = @(Get-ChildItem -LiteralPath $SourceRoot -Directory | Where-Object {
        $_.Name -notin @('images', 'colmap', 'lfs', 'renders', 'raw') -and
        (Get-ChildItem -LiteralPath $_.FullName -File | Where-Object { $imageExtensions -contains $_.Extension.ToLowerInvariant() } | Select-Object -First 1)
    } | Sort-Object Name)
    if ($dirs.Count -gt 0) { return @($dirs) }
    $raw = Join-Path $SourceRoot 'raw'
    if (Test-Path -LiteralPath $raw) {
        return @(Get-ChildItem -LiteralPath $raw -Directory | Where-Object {
            Get-ChildItem -LiteralPath $_.FullName -File | Where-Object { $imageExtensions -contains $_.Extension.ToLowerInvariant() } | Select-Object -First 1
        } | Sort-Object Name)
    }
    return @()
}

function Ensure-ColmapImagesLink {
    $link = Join-Path $script:ColmapDir 'images'
    if (Test-Path -LiteralPath $link) { return }
    try {
        New-Item -ItemType Junction -Path $link -Target $script:ImagesDir -ErrorAction Stop | Out-Null
    } catch {
        throw "Could not create the COLMAP images junction '$link'. $($_.Exception.Message)"
    }
}

function Invoke-Extract {
    $marker = $script:ExtractMarker
    $legacy = Join-Path $script:ImagesDir '.extract.complete.json'
    if ((Test-Path -LiteralPath $legacy) -and -not (Test-Path -LiteralPath $marker)) { Move-Item -LiteralPath $legacy -Destination $marker }
    if ((Test-Path -LiteralPath $marker) -and -not $Force) {
        Write-Log 'SKIP extract: completion marker exists.'
        Ensure-ColmapImagesLink
        return
    }
    if ($Force) { Reset-Directory $script:ImagesDir }
    New-Item -ItemType Directory -Path $script:ImagesDir -Force | Out-Null
    $sourceRoot = if ($InputPath) { [IO.Path]::GetFullPath($InputPath) } else { $script:ScenePath }
    if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) { throw "Input path does not exist: $sourceRoot" }
    $cameras = @(Get-CameraSources $sourceRoot)
    $counts = [ordered]@{}
    if ($cameras.Count -gt 0) {
        foreach ($camera in $cameras) {
            $destination = Join-Path $script:ImagesDir $camera.Name
            New-Item -ItemType Directory -Path $destination -Force | Out-Null
            $files = @(Get-ChildItem -LiteralPath $camera.FullName -File | Where-Object { $_.Extension.ToLowerInvariant() -in @('.jpg','.jpeg','.png','.tif','.tiff','.webp') } | Sort-Object Name)
            foreach ($file in $files) {
                $target = Join-Path $destination $file.Name
                if (-not (Test-Path -LiteralPath $target)) {
                    try { New-Item -ItemType HardLink -Path $target -Target $file.FullName -ErrorAction Stop | Out-Null }
                    catch { Copy-Item -LiteralPath $file.FullName -Destination $target }
                }
            }
            $counts[$camera.Name] = $files.Count
        }
    } else {
        $raw = if (Test-Path -LiteralPath (Join-Path $sourceRoot 'raw')) { Join-Path $sourceRoot 'raw' } else { $sourceRoot }
        $videos = @(Get-ChildItem -LiteralPath $raw -File | Where-Object { $_.Extension.ToLowerInvariant() -in @('.mp4','.mov','.mkv','.avi') } | Sort-Object Name)
        if ($videos.Count -eq 0) { throw "No camera image folders or supported videos found under $sourceRoot" }
        $ffmpeg = Resolve-Executable $FfmpegPath 'ffmpeg'
        foreach ($video in $videos) {
            $cameraName = [IO.Path]::GetFileNameWithoutExtension($video.Name)
            $destination = Join-Path $script:ImagesDir $cameraName
            New-Item -ItemType Directory -Path $destination -Force | Out-Null
            if ($SharpestOf -gt 0) {
                # Handheld video: the sharpest frame of every N instead of a fixed-rate sample.
                $report = Join-Path $script:ScenePath "extract.$cameraName.selection.json"
                $ffprobe = Resolve-Executable $FfprobePath 'ffprobe'
                Write-Log "COMMAND select-frames.ps1 -Video $($video.FullName) -OutDir $destination -Window $SharpestOf"
                & (Join-Path $PSScriptRoot 'select-frames.ps1') -Video $video.FullName -OutDir $destination -Prefix $cameraName -Window $SharpestOf -ReportPath $report -FfmpegPath $ffmpeg -FfprobePath $ffprobe | Out-Null
            } else {
                $pattern = Join-Path $destination ($cameraName + '_%05d.jpg')
                Invoke-Logged $ffmpeg @('-hide_banner','-nostdin','-i',$video.FullName,'-vf',"fps=$Fps",'-q:v','2',$pattern)
            }
            $counts[$cameraName] = @(Get-ChildItem -LiteralPath $destination -File).Count
        }
    }
    if ($counts.Count -lt 1) { throw "Expected at least one physical camera folder; found none." }
    $total = ($counts.Values | Measure-Object -Sum).Sum
    if ($total -lt 20) { throw "Only $total images were staged; reconstruction input is too small." }
    $sampling = if ($cameras.Count -gt 0) { 'stills' } elseif ($SharpestOf -gt 0) { "sharpest-of-$SharpestOf" } else { "fps=$Fps" }
    Write-Json $marker ([ordered]@{ completedAt=(Get-Date).ToString('o'); source=$sourceRoot; sampling=$sampling; cameras=$counts; total=$total })
    Ensure-ColmapImagesLink
    Write-Log "DONE extract: $total images across $($counts.Count) cameras."
}

function Get-ColmapHelp([string] $Colmap, [string] $Command) {
    return Invoke-Logged $Colmap @($Command, '-h') -Capture
}

function Require-Option([string] $Help, [string[]] $Candidates, [string] $Context) {
    foreach ($candidate in $Candidates) { if ($Help.Contains($candidate)) { return $candidate } }
    throw "$Context does not expose any supported option: $($Candidates -join ', ')"
}

function Get-ColmapModels {
    if (-not (Test-Path -LiteralPath $script:SparseDir)) { return @() }
    return @(Get-ChildItem -LiteralPath $script:SparseDir -Directory | Where-Object {
        (Test-Path -LiteralPath (Join-Path $_.FullName 'cameras.bin')) -and
        (Test-Path -LiteralPath (Join-Path $_.FullName 'images.bin')) -and
        (Test-Path -LiteralPath (Join-Path $_.FullName 'points3D.bin'))
    } | Sort-Object Name)
}

function Invoke-Mapper([string] $Colmap) {
    Invoke-Logged $Colmap @('mapper','--database_path',$script:DatabasePath,'--image_path',$script:ImagesDir,'--output_path',$script:SparseDir)
}

function Save-SfmMetrics([string] $Colmap, [object] $Model, [string] $Matcher) {
    $analysis = Invoke-Logged $Colmap @('model_analyzer','--path',$Model.FullName) -Capture
    $registeredMatch = [regex]::Match($analysis, '(?i)Registered images:\s*(\d+)')
    $errorMatch = [regex]::Match($analysis, '(?i)Mean reprojection error:\s*([0-9.eE+-]+)\s*px?')
    if (-not $registeredMatch.Success -or -not $errorMatch.Success) { throw 'Could not parse registered image count and mean reprojection error from COLMAP model_analyzer.' }
    $total = @(Get-ChildItem -LiteralPath $script:ImagesDir -Recurse -File | Where-Object { $_.Name -ne '.extract.complete.json' }).Count
    $metrics = [ordered]@{ completedAt=(Get-Date).ToString('o'); modelCount=1; matcher=$Matcher; lens=$(if ($script:Capture) { $script:Capture.Lens } else { $null }); cameraModel=$CameraModel; registeredImages=[int]$registeredMatch.Groups[1].Value; totalImages=$total; registrationPercent=[math]::Round(100*[int]$registeredMatch.Groups[1].Value/$total,2); meanReprojectionErrorPx=[double]::Parse($errorMatch.Groups[1].Value,[Globalization.CultureInfo]::InvariantCulture); modelPath=$Model.FullName }
    Write-Json (Join-Path $script:ColmapDir 'sfm.metrics.json') $metrics
    Write-Log "DONE sfm: $($metrics.registeredImages)/$total registered, mean reprojection error $($metrics.meanReprojectionErrorPx) px ($Matcher matcher)."
}

function Invoke-Sfm {
    if (-not $CameraModel) { throw 'Lens mode was not resolved before sfm. Pass -Lens, -CameraModel, or write capture.json.' }
    $marker = Join-Path $script:ColmapDir 'sfm.metrics.json'
    $modelsAtStart = @(Get-ColmapModels)
    if ((Test-Path -LiteralPath $marker) -and $modelsAtStart.Count -eq 1 -and -not $Force) {
        Write-Log 'SKIP sfm: one model and metrics file exist.'
        return
    }
    if (-not (Test-Path -LiteralPath $script:ExtractMarker)) { Invoke-Extract }
    $colmap = Resolve-Executable $ColmapPath 'COLMAP'
    $existingModels = @(Get-ColmapModels)
    if (-not $Force -and $existingModels.Count -eq 1) {
        Write-Log 'Found one completed model without metrics; analyzing it without rerunning matching or mapping.'
        Save-SfmMetrics $colmap $existingModels[0] 'exhaustive'
        return
    }
    if ($Force) {
        if (Test-Path -LiteralPath $script:DatabasePath) { Assert-SafeChild $script:DatabasePath $script:ScenePath; Remove-Item -LiteralPath $script:DatabasePath -Force }
        Reset-Directory $script:SparseDir
    } else { New-Item -ItemType Directory -Path $script:SparseDir -Force | Out-Null }
    $featureHelp = Get-ColmapHelp $colmap 'feature_extractor'
    $singleFolder = Require-Option $featureHelp @('--ImageReader.single_camera_per_folder') 'COLMAP feature_extractor'
    $featureGpu = Require-Option $featureHelp @('--FeatureExtraction.use_gpu','--SiftExtraction.use_gpu') 'COLMAP feature_extractor'
    if (-not (Test-Path -LiteralPath $script:DatabasePath)) {
        Invoke-Logged $colmap @('feature_extractor','--database_path',$script:DatabasePath,'--image_path',$script:ImagesDir,'--ImageReader.camera_model',$CameraModel,$singleFolder,'1',$featureGpu,'1')
    }
    $sequentialHelp = Get-ColmapHelp $colmap 'sequential_matcher'
    $matchGpu = Require-Option $sequentialHelp @('--FeatureMatching.use_gpu','--SiftMatching.use_gpu') 'COLMAP sequential_matcher'
    $matcher = 'sequential'
    $sequentialFailed = $false
    try {
        Invoke-Logged $colmap @('sequential_matcher','--database_path',$script:DatabasePath,'--SequentialMatching.overlap','20','--SequentialMatching.loop_detection','1',$matchGpu,'1')
        $modelsAfterSequential = @(Get-ColmapModels)
        if ($modelsAfterSequential.Count -eq 0) { Invoke-Mapper $colmap }
    } catch {
        $sequentialFailed = $true
        Write-Log "Sequential matching failed; retrying with exhaustive matching. Cause: $($_.Exception.Message)"
    }
    $models = @(Get-ColmapModels)
    if ($sequentialFailed -or $models.Count -ne 1) {
        if (-not $sequentialFailed) { Write-Log "Sequential matching produced $($models.Count) models; retrying with exhaustive matching." }
        Reset-Directory $script:SparseDir
        $exhaustiveHelp = Get-ColmapHelp $colmap 'exhaustive_matcher'
        $exhaustiveGpu = Require-Option $exhaustiveHelp @('--FeatureMatching.use_gpu','--SiftMatching.use_gpu') 'COLMAP exhaustive_matcher'
        Invoke-Logged $colmap @('exhaustive_matcher','--database_path',$script:DatabasePath,$exhaustiveGpu,'1')
        Invoke-Mapper $colmap
        $matcher = 'exhaustive'
        $models = @(Get-ColmapModels)
    }
    if ($models.Count -ne 1) { throw "COLMAP produced $($models.Count) models after exhaustive fallback; expected exactly one." }
    Save-SfmMetrics $colmap $models[0] $matcher
}

function Invoke-Train {
    $metricsPath = Join-Path $script:LfsDir 'training.metrics.json'
    if ((Test-Path -LiteralPath $metricsPath) -and -not $Force) { Write-Log 'SKIP train: metrics file exists.'; return }
    $modelsForTraining = @(Get-ColmapModels)
    if ($modelsForTraining.Count -ne 1) { throw 'Training requires exactly one completed COLMAP model.' }
    if (-not $CameraModel) { throw 'Lens mode was not resolved before train. Pass -Lens, -CameraModel, or write capture.json.' }
    $sparseModels = @(Get-ColmapCameraModels (Join-Path (Get-ColmapModels)[0].FullName 'cameras.bin'))
    if ($sparseModels.Count -ne 1 -or $sparseModels[0] -ne $CameraModel) {
        throw "The COLMAP model on disk uses camera model(s) $($sparseModels -join ', ') but the declared lens resolves to $CameraModel. Rerun sfm with -Force after fixing capture.json or the -Lens flag."
    }
    $trainingDataset = $script:ColmapDir
    if ($CameraModel -eq 'OPENCV') {
        $trainingDataset = Join-Path $script:ColmapDir 'undistorted'
        $undistortMarker = Join-Path $trainingDataset '.undistort.complete.json'
        $undistortedModel = Join-Path $trainingDataset 'sparse'
        # -MaxImageSize 0 keeps full resolution (COLMAP's -1); a marker written at another size is redone.
        $undistortedSize = $null
        if (Test-Path -LiteralPath $undistortMarker) { $undistortedSize = (Get-Content -LiteralPath $undistortMarker -Raw | ConvertFrom-Json).PSObject.Properties['maxImageSize']?.Value }
        if ($undistortedSize -ne $MaxImageSize -or -not (Test-Path -LiteralPath (Join-Path $undistortedModel 'cameras.bin'))) {
            Reset-Directory $trainingDataset
            $colmap = Resolve-Executable $ColmapPath 'COLMAP'
            $colmapSize = if ($MaxImageSize -eq 0) { -1 } else { $MaxImageSize }
            Invoke-Logged $colmap @('image_undistorter','--image_path',$script:ImagesDir,'--input_path',(Get-ColmapModels)[0].FullName,'--output_path',$trainingDataset,'--output_type','COLMAP','--max_image_size',"$colmapSize")
            $undistortedImages = @(Get-ChildItem -LiteralPath (Join-Path $trainingDataset 'images') -Recurse -File -ErrorAction SilentlyContinue).Count
            $stagedImages = @(Get-ChildItem -LiteralPath $script:ImagesDir -Recurse -File | Where-Object { $_.Name -ne '.extract.complete.json' }).Count
            if ($undistortedImages -ne $stagedImages) { throw "COLMAP undistortion wrote $undistortedImages images; expected $stagedImages (the staged image count)." }
            Write-Json $undistortMarker ([ordered]@{ completedAt=(Get-Date).ToString('o'); images=$undistortedImages; maxImageSize=$MaxImageSize; sourceModel=(Get-ColmapModels)[0].FullName })
            Write-Log "DONE undistort: $undistortedImages pinhole images at maximum dimension $(if ($MaxImageSize -eq 0) { 'full resolution' } else { "$MaxImageSize px" })."
        }
    }
    $lichtfeld = Resolve-Executable $LichtFeldPath 'LichtFeld Studio'
    $help = Invoke-Logged $lichtfeld @('--help') -Capture
    Set-Content -LiteralPath (Join-Path $script:LfsDir 'flags.txt') -Value $help -Encoding utf8
    foreach ($required in @('--headless','--train','--strategy','--max-cap')) { if (-not $help.Contains($required)) { throw "Installed LichtFeld build is missing required flag $required. See lfs/flags.txt." } }
    $iterationFlag = if ($help.Contains('--iter')) { '--iter' } elseif ($help.Contains('-i')) { '-i' } else { throw 'Installed LichtFeld build has no recognized iteration flag.' }
    $arguments = @('--headless','--train','-d',$trainingDataset,'-o',$script:LfsDir,'--strategy',$Strategy,'--max-cap',"$MaxCap",$iterationFlag,"$Iterations")
    $gut = $false
    if ($CameraModel -eq 'OPENCV_FISHEYE') {
        # Fisheye images stay distorted; LichtFeld renders through the lens model with 3DGUT.
        # Without --gut or --undistort LichtFeld refuses distorted cameras outright.
        if (-not $help.Contains('--gut')) { throw 'Fisheye input requires LichtFeld 3DGUT, but this build does not expose --gut. Undistort in COLMAP or install a compatible build.' }
        $arguments += '--gut'
        $gut = $true
    }
    if ($MaskMode -ne 'none') {
        # Per-image masks in <dataset>/masks/<cam>/<stem>.png, in the training images' pixel space; white trains, black is ignored.
        if (-not $help.Contains('--mask-mode')) { throw "-MaskMode $MaskMode needs LichtFeld --mask-mode, which this build does not expose. See lfs/flags.txt." }
        $masks = @(Get-ChildItem -LiteralPath (Join-Path $trainingDataset 'masks') -Recurse -File -ErrorAction SilentlyContinue).Count
        if ($masks -eq 0) { throw "-MaskMode $MaskMode was given but $trainingDataset\masks holds no mask files." }
        $arguments += @('--mask-mode', $MaskMode)
        Write-Log "MASKS $masks files, mode $MaskMode."
    }
    # v0.5.4 saves only project.licht unless asked for a splat file; --export ply restores
    # lfs/splat_<iter>.ply, which frame.mjs and build-viewer.mjs read. v0.5.3 writes it unasked.
    if ($help.Contains('--export')) { $arguments += @('--export', 'ply') }
    # v0.5.4 scales photos wider than --max-width (default 3840) down before training; 0 trains at full width.
    if ($help.Contains('--max-width')) { $arguments += @('--max-width', "$MaxImageSize") }
    $arguments += $TrainArgs
    $stdout = Join-Path $script:LfsDir 'training.stdout.log'
    $stderr = Join-Path $script:LfsDir 'training.stderr.log'
    Write-Log "COMMAND $(Quote-Command $lichtfeld $arguments)"
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $process = Start-Process -FilePath $lichtfeld -ArgumentList $arguments -PassThru -NoNewWindow -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $peakMiB = 0
    while (-not $process.HasExited) {
        Start-Sleep -Milliseconds 1000
        $rows = & nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits 2>$null
        foreach ($row in $rows) {
            if ($row -match '^\s*(\d+)\s*,\s*(\d+)') { if ([int]$matches[1] -eq $process.Id) { $peakMiB = [math]::Max($peakMiB,[int]$matches[2]) } }
        }
        $process.Refresh()
    }
    $timer.Stop()
    $trainingLog = ((Get-Content -LiteralPath $stdout -Raw -ErrorAction SilentlyContinue) + [Environment]::NewLine + (Get-Content -LiteralPath $stderr -Raw -ErrorAction SilentlyContinue))
    Add-Content -LiteralPath $script:LogPath -Value $trainingLog -Encoding utf8
    if ($process.ExitCode -ne 0) { throw "LichtFeld training failed with exit code $($process.ExitCode). See lfs/training.*.log." }
    $checkpoints = @(Get-ChildItem -LiteralPath $script:LfsDir -Recurse -File -Include '*.resume','*.licht' | Sort-Object LastWriteTime)
    if ($checkpoints.Count -eq 0) { throw 'Training exited successfully but wrote no .resume or .licht checkpoint.' }
    if (-not (Test-Path -LiteralPath (Join-Path $script:LfsDir "splat_$Iterations.ply"))) { throw "Training exited successfully but wrote no lfs\splat_$Iterations.ply. Convert the checkpoint with: LichtFeld-Studio convert $($checkpoints[-1].FullName) $(Join-Path $script:LfsDir "splat_$Iterations.ply")" }
    $lossMatches = [regex]::Matches($trainingLog, '(?i)Loss:\s*([0-9.eE+-]+)')
    $finalLoss = if ($lossMatches.Count) { [double]::Parse($lossMatches[-1].Groups[1].Value,[Globalization.CultureInfo]::InvariantCulture) } else { $null }
    $metrics = [ordered]@{ completedAt=(Get-Date).ToString('o'); targetIteration=$Iterations; finalLoss=$finalLoss; wallTimeSeconds=[math]::Round($timer.Elapsed.TotalSeconds,2); peakVramMiB=$peakMiB; checkpoint=$checkpoints[-1].FullName; lens=$(if ($script:Capture) { $script:Capture.Lens } else { $null }); cameraModel=$CameraModel; gut=$gut; trainingDataset=$trainingDataset; strategy=$Strategy; maxCap=$MaxCap; maskMode=$MaskMode }
    Write-Json $metricsPath $metrics
    Write-Log "DONE train: iteration $Iterations, loss $finalLoss, $($metrics.wallTimeSeconds)s, peak VRAM $peakMiB MiB."
}

function Invoke-McpRequest([string] $Method, [object] $Params = @{}) {
    $script:McpRequestId++
    $body = @{ jsonrpc='2.0'; id=$script:McpRequestId; method=$Method; params=$Params } | ConvertTo-Json -Depth 30 -Compress
    $headers = @{ Accept='application/json, text/event-stream' }
    if ($script:McpSessionId) { $headers['Mcp-Session-Id'] = $script:McpSessionId }
    $response = Invoke-WebRequest -Uri $McpEndpoint -Method Post -ContentType 'application/json' -Headers $headers -Body $body
    if (-not $script:McpSessionId -and $response.Headers['Mcp-Session-Id']) { $script:McpSessionId = $response.Headers['Mcp-Session-Id'][0] }
    $text = $response.Content
    if ($response.Headers['Content-Type'] -like 'text/event-stream*') {
        $data = ($text -split "`n" | Where-Object { $_ -like 'data:*' } | Select-Object -Last 1) -replace '^data:\s*',''
        $result = $data | ConvertFrom-Json -Depth 50
    } else { $result = $text | ConvertFrom-Json -Depth 50 }
    if ($result.error) { throw "MCP $Method failed: $($result.error | ConvertTo-Json -Depth 10 -Compress)" }
    return $result.result
}

function Connect-Mcp {
    $script:McpRequestId = 0
    $script:McpSessionId = $null
    try {
        $initialize = Invoke-McpRequest 'initialize' @{ protocolVersion='2025-03-26'; capabilities=@{}; clientInfo=@{ name='gsplat-pipeline'; version='1.0.0' } }
    } catch {
        throw "Could not connect to LichtFeld MCP at $McpEndpoint. Launch LichtFeld Studio, enable MCP, and retry. $($_.Exception.Message)"
    }
    Invoke-McpRequest 'notifications/initialized' @{} | Out-Null
    $resources = Invoke-McpRequest 'resources/list' @{}
    $script:McpTools = Invoke-McpRequest 'tools/list' @{}
    $bootstrap = [ordered]@{ initialize=$initialize; resources=$resources; tools=$script:McpTools; states=[ordered]@{} }
    foreach ($uri in @('lichtfeld://runtime/catalog','lichtfeld://runtime/state','lichtfeld://scene/state','lichtfeld://operators/registry')) {
        try { $bootstrap.states[$uri] = Invoke-McpRequest 'resources/read' @{ uri=$uri } } catch { $bootstrap.states[$uri] = @{ error=$_.Exception.Message } }
    }
    Write-Json (Join-Path $script:LfsDir 'mcp-catalog.json') $bootstrap 50
    Write-Log "Connected to LichtFeld MCP version $($initialize.serverInfo.version); catalog saved."
    return $bootstrap
}

function Resolve-McpTool([string[]] $Names) {
    foreach ($name in $Names) {
        $tool = @($script:McpTools.tools | Where-Object { $_.name -eq $name } | Select-Object -First 1)
        if ($tool.Count) { return $tool[0] }
    }
    throw "Installed LichtFeld MCP does not expose any of: $($Names -join ', '). See lfs/mcp-catalog.json."
}

function Invoke-McpTool([object] $Tool, [hashtable] $Arguments) {
    $properties = @($Tool.inputSchema.properties.PSObject.Properties.Name)
    $filtered = @{}
    foreach ($entry in $Arguments.GetEnumerator()) { if ($entry.Key -in $properties) { $filtered[$entry.Key] = $entry.Value } }
    foreach ($required in @($Tool.inputSchema.required)) { if (-not $filtered.ContainsKey([string]$required)) { throw "Tool $($Tool.name) requires unsupported/unset argument '$required'. Inspect lfs/mcp-catalog.json." } }
    $result = Invoke-McpRequest 'tools/call' @{ name=$Tool.name; arguments=$filtered }
    if ($result.isError) { throw "MCP tool $($Tool.name) returned an error: $($result.content | ConvertTo-Json -Depth 20 -Compress)" }
    return $result
}

function Get-LatestCheckpoint {
    $metricsPath = Join-Path $script:LfsDir 'training.metrics.json'
    if (Test-Path -LiteralPath $metricsPath) {
        $metrics = Get-Content -LiteralPath $metricsPath -Raw | ConvertFrom-Json
        if (Test-Path -LiteralPath $metrics.checkpoint) { return $metrics.checkpoint }
    }
    $files = @(Get-ChildItem -LiteralPath $script:LfsDir -Recurse -File -Include '*.resume','*.licht' | Sort-Object LastWriteTime)
    if (-not $files.Count) { throw 'No LichtFeld checkpoint found. Run the train stage first.' }
    return $files[-1].FullName
}

function Get-McpPayload([object] $Result) {
    if ($Result.structuredContent) { return $Result.structuredContent }
    foreach ($item in @($Result.content)) {
        if ($item.type -eq 'text') { try { return ($item.text | ConvertFrom-Json -Depth 50) } catch {} }
    }
    return $Result
}

function Ensure-CheckpointLoaded([object] $Bootstrap) {
    $checkpoint = Get-LatestCheckpoint
    $load = Resolve-McpTool @('scene_load_checkpoint','scene.load_checkpoint')
    Invoke-McpTool $load @{ path=$checkpoint } | Out-Null
    try {
        $wait = Resolve-McpTool @('runtime_job_wait','runtime.job.wait')
        Invoke-McpTool $wait @{ job_id='import.dataset'; until='finished'; timeout_ms=60000 } | Out-Null
    } catch { Write-Log "MCP import wait was unavailable or unnecessary: $($_.Exception.Message)" }
    return $checkpoint
}

function Resolve-SceneNode {
    if ($SceneNode) { return $SceneNode }
    $list = Resolve-McpTool @('scene_list_nodes','scene.list_nodes')
    $payload = Get-McpPayload (Invoke-McpTool $list @{})
    $json = $payload | ConvertTo-Json -Depth 50 -Compress
    $match = [regex]::Match($json, '"(?:id|name)":"([^"]*(?:training|splat|gaussian)[^"]*)"', 'IgnoreCase')
    if ($match.Success) { return $match.Groups[1].Value }
    throw 'Could not identify a Gaussian scene node. Pass -SceneNode after inspecting lfs/mcp-catalog.json.'
}

function Invoke-Export {
    $ply = Join-Path $script:LfsDir ($script:SceneName + '.ply')
    $spz = Join-Path $script:LfsDir ($script:SceneName + '.spz')
    if ((Test-Path -LiteralPath $ply) -and (Test-Path -LiteralPath $spz) -and -not $Force) { Write-Log 'SKIP export: PLY and SPZ exist.'; return }
    $bootstrap = Connect-Mcp
    Ensure-CheckpointLoaded $bootstrap | Out-Null
    $node = Resolve-SceneNode
    foreach ($spec in @(@{ names=@('scene_export_ply','scene.export_ply'); path=$ply }, @{ names=@('scene_export_spz','scene.export_spz'); path=$spz })) {
        $tool = Resolve-McpTool $spec.names
        Invoke-McpTool $tool @{ path=$spec.path; node=$node; nodes=@($node); sh_degree=3 } | Out-Null
        if (-not (Test-Path -LiteralPath $spec.path -PathType Leaf)) { throw "LichtFeld reported success but did not create $($spec.path)" }
    }
    Write-Log "DONE export: $ply and $spz"
}

function Convert-Vector([string] $Text) {
    $values = @($Text -split ',' | ForEach-Object { [double]::Parse($_.Trim(),[Globalization.CultureInfo]::InvariantCulture) })
    if ($values.Count -ne 3) { throw "Expected x,y,z, got '$Text'." }
    return $values
}

function Find-Bounds([object] $Payload) {
    $json = $Payload | ConvertTo-Json -Depth 50 -Compress
    $centerMatch = [regex]::Match($json, '"center":\[\s*([-0-9.eE+]+),\s*([-0-9.eE+]+),\s*([-0-9.eE+]+)\]', 'IgnoreCase')
    $radiusMatch = [regex]::Match($json, '"(?:bounding_)?radius":\s*([-0-9.eE+]+)', 'IgnoreCase')
    if ($centerMatch.Success -and $radiusMatch.Success) {
        return @{ center=@([double]$centerMatch.Groups[1].Value,[double]$centerMatch.Groups[2].Value,[double]$centerMatch.Groups[3].Value); radius=[double]$radiusMatch.Groups[1].Value }
    }
    return $null
}

function Invoke-Orbit {
    $video = Join-Path $script:RendersDir ($script:SceneName + '_orbit_4k.mp4')
    if ((Test-Path -LiteralPath $video) -and -not $Force) { Write-Log 'SKIP orbit: video exists.'; return }
    $bootstrap = Connect-Mcp
    Ensure-CheckpointLoaded $bootstrap | Out-Null
    $sceneState = Invoke-McpRequest 'resources/read' @{ uri='lichtfeld://scene/state' }
    $bounds = Find-Bounds $sceneState
    $center = if ($OrbitCenter) { Convert-Vector $OrbitCenter } elseif ($bounds) { $bounds.center } else { throw 'Scene bounds were not exposed by this build. Pass -OrbitCenter x,y,z and -OrbitRadius.' }
    $radius = if ($OrbitRadius.HasValue) { $OrbitRadius.Value } elseif ($bounds) { 2.5 * $bounds.radius } else { throw 'Pass -OrbitRadius because scene bounds were unavailable.' }
    if ($radius -le 0) { throw 'Orbit radius must be positive.' }
    $clear = Resolve-McpTool @('sequencer_clear','sequencer.clear')
    $add = Resolve-McpTool @('sequencer_add_keyframe','sequencer.add_keyframe')
    Invoke-McpTool $clear @{} | Out-Null
    $frames = @()
    for ($index=0; $index -le $OrbitKeyframes; $index++) {
        $angle = 2.0 * [Math]::PI * $index / $OrbitKeyframes
        $eye = @($center[0] + $radius*[Math]::Cos($angle), $center[1] + 0.25*$radius, $center[2] + $radius*[Math]::Sin($angle))
        $key = [ordered]@{ index=$index; timeSeconds=$OrbitDuration*$index/$OrbitKeyframes; eye=$eye; target=$center; up=@(0,1,0); fovDegrees=60 }
        $frames += $key
        Invoke-McpTool $add @{ eye=$eye; target=$center; up=@(0,1,0); fov_degrees=60; show_sequencer=$false } | Out-Null
    }
    $plan = [ordered]@{ version=1; center=$center; radius=$radius; durationSeconds=$OrbitDuration; fps=$OrbitFps; width=$OrbitWidth; height=$OrbitHeight; keyframes=$frames }
    Write-Json (Join-Path $script:RendersDir 'orbit_plan.json') $plan 20
    try {
        $save = Resolve-McpTool @('sequencer_save_path','sequencer.save_path')
        Invoke-McpTool $save @{ path=(Join-Path $script:RendersDir 'orbit_keyframes.json'); show_sequencer=$false } | Out-Null
    } catch { Write-Log "Native sequencer path save unavailable: $($_.Exception.Message)" }
    $videoCandidates = @($script:McpTools.tools | Where-Object { $_.name -match '(?i)(export|render).*(video)|video.*(export|render)' })
    if ($videoCandidates.Count -ne 1) { throw "Could not uniquely discover the video export tool (found $($videoCandidates.Count)). See lfs/mcp-catalog.json." }
    $videoTool = $videoCandidates[0]
    Invoke-McpTool $videoTool @{ path=$video; output_path=$video; width=$OrbitWidth; height=$OrbitHeight; fps=$OrbitFps; duration=$OrbitDuration; duration_seconds=$OrbitDuration; format='mp4'; codec='h264' } | Out-Null
    try {
        $wait = Resolve-McpTool @('runtime_job_wait','runtime.job.wait')
        Invoke-McpTool $wait @{ job_id='export.video'; until='finished'; timeout_ms=60000 } | Out-Null
    } catch { Write-Log "Video wait unavailable or export completed synchronously: $($_.Exception.Message)" }
    if (-not (Test-Path -LiteralPath $video -PathType Leaf)) { throw "Orbit render did not create $video" }
    Test-OrbitVideo $video
    Write-Log "DONE orbit: $video"
}

function Test-OrbitVideo([string] $Video) {
    $probe = Resolve-Executable $FfprobePath 'ffprobe'
    $ffmpeg = Resolve-Executable $FfmpegPath 'ffmpeg'
    $probeJson = Invoke-Logged $probe @('-v','error','-select_streams','v:0','-show_entries','stream=width,height,r_frame_rate:format=duration','-of','json',$Video) -Capture | ConvertFrom-Json
    $stream = $probeJson.streams[0]
    $duration = [double]::Parse($probeJson.format.duration,[Globalization.CultureInfo]::InvariantCulture)
    if ($stream.width -ne $OrbitWidth -or $stream.height -ne $OrbitHeight) { throw "Orbit is $($stream.width)x$($stream.height), expected ${OrbitWidth}x${OrbitHeight}." }
    if ([Math]::Abs($duration-$OrbitDuration) -gt [Math]::Max(1.0,0.05*$OrbitDuration)) { throw "Orbit duration is $duration s, expected about $OrbitDuration s." }
    $samples = @(0.1, $duration/2, [Math]::Max(0.1,$duration-0.1))
    foreach ($sample in $samples) {
        $result = & $ffmpeg -hide_banner -nostdin -ss ([string]::Format([Globalization.CultureInfo]::InvariantCulture,'{0:F3}',$sample)) -i $Video -frames:v 1 -vf 'blackframe=amount=98:threshold=32' -f null - 2>&1 | ForEach-Object { $_.ToString() }
        $black = [regex]::Match(($result -join "`n"), 'pblack:(\d+)')
        if ($black.Success -and [int]$black.Groups[1].Value -ge 98) { throw "Orbit frame at $sample seconds is black ($($black.Groups[1].Value)% black)." }
    }
    Write-Json (Join-Path $script:RendersDir 'orbit.metrics.json') ([ordered]@{ checkedAt=(Get-Date).ToString('o'); path=$Video; width=$stream.width; height=$stream.height; durationSeconds=$duration; fps=$stream.r_frame_rate; blackFrameSamples=$samples })
}

$script:ScenePath = if ([IO.Path]::IsPathRooted($Scene)) { [IO.Path]::GetFullPath($Scene) } else { [IO.Path]::GetFullPath((Join-Path $Root $Scene)) }
$script:SceneName = Split-Path -Leaf $script:ScenePath
New-Item -ItemType Directory -Path $script:ScenePath -Force | Out-Null
$script:ImagesDir = Join-Path $script:ScenePath 'images'
$script:ExtractMarker = Join-Path $script:ScenePath 'extract.complete.json'   # scene root, so COLMAP never tries to read it as an image
$script:ColmapDir = Join-Path $script:ScenePath 'colmap'
$script:SparseDir = Join-Path $script:ColmapDir 'sparse'
$script:DatabasePath = Join-Path $script:ColmapDir 'database.db'
$script:LfsDir = Join-Path $script:ScenePath 'lfs'
$script:RendersDir = Join-Path $script:ScenePath 'renders'
$script:LogPath = Join-Path $script:ScenePath 'log.txt'
foreach ($directory in @($script:ImagesDir,$script:ColmapDir,$script:SparseDir,$script:LfsDir,$script:RendersDir)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
Write-Log "START scene=$($script:ScenePath) stage=$Stage force=$Force"

try {
    $stages = if ($Stage -eq 'all') { @('extract','sfm','train','export','orbit') } else { @($Stage) }
    $script:Capture = Resolve-CaptureLens -Required:(($stages -contains 'sfm') -or ($stages -contains 'train'))
    foreach ($current in $stages) {
        switch ($current) {
            'extract' { Invoke-Extract }
            'sfm' { Invoke-Sfm }
            'train' { Invoke-Train }
            'export' { Invoke-Export }
            'orbit' { Invoke-Orbit }
        }
    }
    Write-Log "SUCCESS stage=$Stage"
} catch {
    Write-Log "FAILED stage=$Stage error=$($_.Exception.Message)"
    Write-Error $_
    exit 1
}
