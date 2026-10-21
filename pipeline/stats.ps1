#requires -Version 7.0
<#
.SYNOPSIS
  Harvest per-run pipeline statistics for one scene, or print a table of every recorded run.

.DESCRIPTION
  Reads only artifacts the pipeline already writes (log.txt, colmap/sfm.metrics.json,
  lfs/training.metrics.json, lfs/training.stdout.log, extract.complete.json, the PLY)
  and derives timings, throughput rates and quality metrics. Nothing is re-run and no stage is
  touched, so it adds no time to a reconstruction. reconstruct.ps1 calls it after the last
  stage; it can also be run by hand on any finished scene (including old ones, to backfill).

  Outputs:
    <scene>\runs\<runId>\stats.json   full nested record
    <scene>\runs\<runId>\stats.md     human-readable summary (also printed unless -Quiet)
    pipeline\runs.jsonl               one flat JSON line per run across scenes (spreadsheet/script friendly)

  The run id is the wall-clock start of the run (yyyyMMdd-HHmmss). When a scene's log.txt
  holds several runs, the LAST run of each stage is used.

.EXAMPLE
  .\pipeline\stats.ps1 .\_workspace\20260917_park_bench_wide
  .\pipeline\stats.ps1 -Table
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)] [string] $Scene,
    [string] $RunId,
    [ValidateSet('ok', 'failed', 'unknown')] [string] $Status = 'unknown',
    [string] $RunLog,
    [switch] $Table,
    [switch] $Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$inv = [Globalization.CultureInfo]::InvariantCulture
$script:RunsIndex = Join-Path $PSScriptRoot 'runs.jsonl'

# ---------------------------------------------------------------- helpers
function D($v, [int] $digits = 3) { if ($null -eq $v) { return $null }; return [math]::Round([double]$v, $digits) }
function Ratio($a, $b, [int] $digits = 3) { if ($null -eq $a -or $null -eq $b -or [double]$b -eq 0) { return $null }; return [math]::Round([double]$a / [double]$b, $digits) }
function P($obj, [string] $name) { if ($null -eq $obj) { return $null }; $p = $obj.PSObject.Properties[$name]; if ($p) { return $p.Value }; return $null }
function Stamp([string] $line) { if ($line -match '^\[(\d{4}-\d\d-\d\dT[^\]]+)\]') { try { return [DateTimeOffset]::Parse($matches[1], $inv) } catch { } }; return $null }
function Rx([string] $text, [string] $pattern, [int] $group = 1) { $m = [regex]::Match($text, $pattern); if ($m.Success) { return $m.Groups[$group].Value }; return $null }
function RxNum([string] $text, [string] $pattern) { $v = Rx $text $pattern; if ($null -ne $v) { return [double]::Parse($v, $inv) }; return $null }
function RxAll([string] $text, [string] $pattern) { return , [regex]::Matches($text, $pattern) }
function Iso($t) { if ($null -eq $t) { return $null }; return $t.ToString('o') }
function Fmt-Span($s) { if ($null -eq $s) { return '-' }; $t = [TimeSpan]::FromSeconds([math]::Round([double]$s)); if ($t.TotalHours -ge 1) { return ('{0}:{1:mm}:{1:ss}' -f [int][math]::Floor($t.TotalHours), $t) }; return ('{0:mm}:{0:ss}' -f $t) }
function Fmt($v, [int] $digits = 2) { if ($null -eq $v) { return '-' }; if ($v -is [string]) { return $v }; return ([double]$v).ToString("N$digits", $inv) }
function Stats([double[]] $values, [int] $digits = 1) {
    if (-not $values -or $values.Count -eq 0) { return $null }
    $m = $values | Measure-Object -Average -Minimum -Maximum -Sum
    return [ordered]@{ count = $values.Count; mean = D $m.Average $digits; min = D $m.Minimum $digits; max = D $m.Maximum $digits; sum = D $m.Sum $digits }
}
function Read-JsonFile([string] $path) { if (Test-Path -LiteralPath $path) { try { return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } catch { return $null } }; return $null }

# ---------------------------------------------------------------- table of all runs
if ($Table) {
    if (-not (Test-Path -LiteralPath $script:RunsIndex)) { Write-Host "No runs recorded yet ($script:RunsIndex)."; return }
    $rows = @(Get-Content -LiteralPath $script:RunsIndex | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
    $rows | Sort-Object { P $_ 'runStarted' } | Format-Table -AutoSize @(
        @{ n = 'run'; e = { P $_ 'runId' } }, @{ n = 'scene'; e = { P $_ 'scene' } }, @{ n = 'status'; e = { P $_ 'status' } }, @{ n = 'lens'; e = { P $_ 'lens' } },
        @{ n = 'imgs'; e = { P $_ 'images' } }, @{ n = 'cams'; e = { P $_ 'cameras' } }, @{ n = 'reg%'; e = { P $_ 'registrationPercent' } },
        @{ n = 'pts3D'; e = { P $_ 'points3D' } }, @{ n = 'reproj px'; e = { P $_ 'meanReprojectionErrorPx' } }, @{ n = 'track'; e = { P $_ 'meanTrackLength' } },
        @{ n = 'sfm s/img'; e = { P $_ 'sfmSecondsPerImage' } }, @{ n = 'it/s'; e = { P $_ 'trainItersPerSecond' } }, @{ n = 'loss'; e = { P $_ 'finalLoss' } },
        @{ n = 'splats'; e = { P $_ 'finalSplats' } }, @{ n = 'PLY MiB'; e = { P $_ 'plyMiB' } }, @{ n = 'total'; e = { P $_ 'totalWall' } }
    ) | Out-String -Width 300 | Write-Host
    return
}

if (-not $Scene) { throw 'Pass a scene folder, or -Table.' }
$scenePath = [IO.Path]::GetFullPath($Scene)
$sceneName = Split-Path -Leaf $scenePath
$logPath = Join-Path $scenePath 'log.txt'
if (-not (Test-Path -LiteralPath $logPath)) { throw "No log.txt in $scenePath; nothing to harvest." }
$lines = @(Get-Content -LiteralPath $logPath)

# ---------------------------------------------------------------- stage segments (last run of each stage) and commands
$segments = [ordered]@{}
$open = $null
for ($i = 0; $i -lt $lines.Count; $i++) {
    $l = $lines[$i]
    if ($l -match '\] START scene=.* stage=(\w+)') {
        $open = [ordered]@{ stage = $matches[1]; start = $i; end = $lines.Count - 1; startTime = (Stamp $l); endTime = $null; status = 'incomplete'; error = $null }
        $segments[$matches[1]] = $open
    } elseif ($open -and $l -match '\] (SUCCESS|FAILED) stage=(\w+)(.*)$') {
        $open.end = $i; $open.endTime = Stamp $l
        $open.status = if ($matches[1] -eq 'SUCCESS') { 'ok' } else { 'failed' }
        if ($matches[3] -match 'error=(.*)$') { $open.error = $matches[1] }
        $open = $null
    }
}

$commands = [Collections.Generic.List[object]]::new()
foreach ($seg in $segments.Values) {
    for ($i = $seg.start; $i -le $seg.end; $i++) {
        $l = $lines[$i]
        if ($l -notmatch '\] COMMAND (.*)$') { continue }
        $cmd = $matches[1]
        if ($cmd -match ' (-h|--help)$') { continue }
        $name = if ($cmd -match 'colmap\.exe (\w+) ') { $matches[1] } elseif ($cmd -match ' --headless --train ') { 'train' } elseif ($cmd -match 'ffmpeg') { 'ffmpeg' } else { 'other' }
        $start = Stamp $l
        $j = $i + 1; $endTime = $null
        while ($j -le $seg.end) { $s = Stamp $lines[$j]; if ($s) { $endTime = $s; break }; $j++ }
        if (-not $endTime -and $seg.endTime) { $endTime = $seg.endTime }
        $commands.Add([ordered]@{ stage = $seg.stage; name = $name; start = $start; end = $endTime; seconds = $(if ($start -and $endTime) { D ($endTime - $start).TotalSeconds 1 } else { $null }); lineStart = $i; lineEnd = ($j - 1); text = $cmd })
    }
}
function Seg-Text($c) { if ($null -eq $c) { return '' }; return (($lines[$c.lineStart..$c.lineEnd]) -join "`n") }
function Last-Command([string] $n) { $found = @($commands | Where-Object { $_.name -eq $n }); if ($found.Count) { return $found[-1] }; return $null }
function Cmd-Seconds([string] $n) { $c = Last-Command $n; if ($c) { return $c.seconds }; return $null }

# ---------------------------------------------------------------- input images
$extract = Read-JsonFile (Join-Path $scenePath 'extract.complete.json')
if (-not $extract) { $extract = Read-JsonFile (Join-Path $scenePath 'images\.extract.complete.json') }   # scenes staged before 2026-09-19
$imagesDir = Join-Path $scenePath 'images'
$imageFiles = @(if (Test-Path -LiteralPath $imagesDir) { Get-ChildItem -LiteralPath $imagesDir -Recurse -File | Where-Object { $_.Extension -match '^\.(jpe?g|png|tiff?|webp)$' } })
$cameraCounts = [ordered]@{}
if ($extract -and (P $extract 'cameras')) { foreach ($p in (P $extract 'cameras').PSObject.Properties) { $cameraCounts[$p.Name] = [int]$p.Value } }
$imageCount = if ($extract -and (P $extract 'total')) { [int](P $extract 'total') } else { $imageFiles.Count }
$imageBytes = if ($imageFiles.Count) { ($imageFiles | Measure-Object Length -Sum).Sum } else { $null }
$capture = Read-JsonFile (Join-Path $scenePath 'capture.json')

# ---------------------------------------------------------------- SfM
$sfmMetrics = Read-JsonFile (Join-Path $scenePath 'colmap\sfm.metrics.json')
$feText = Seg-Text (Last-Command 'feature_extractor')
$featureCounts = @(foreach ($m in (RxAll $feText 'Features:\s+(\d+)')) { [double]$m.Groups[1].Value })
$width = RxNum $feText 'Dimensions:\s+(\d+) x \d+'
$height = RxNum $feText 'Dimensions:\s+\d+ x (\d+)'
$megapixels = if ($width -and $height) { D ($width * $height / 1e6) 2 } else { $null }
$unreadable = (RxAll $feText 'BITMAP_ERROR').Count
$matcherName = if (Last-Command 'exhaustive_matcher') { 'exhaustive_matcher' } else { 'sequential_matcher' }
$mapText = Seg-Text (Last-Command 'mapper')
$matchedPairs = RxNum $mapText '(?s)Loading matches\.\.\.[^\n]*\n[^\]]*\]\s+(\d+) in'
$registrations = (RxAll $mapText 'Registering image #').Count
$discards = (RxAll $mapText 'Discarding reconstruction').Count
$globalBA = (RxAll $mapText 'Global bundle adjustment').Count
$sees = @(foreach ($m in (RxAll $mapText 'Image sees (\d+) / (\d+) points')) { [double]$m.Groups[1].Value / [math]::Max(1, [double]$m.Groups[2].Value) })
$mapperMinutes = $null; foreach ($m in (RxAll $mapText 'Elapsed time: ([0-9.]+) \[minutes\]')) { $mapperMinutes = [double]::Parse($m.Groups[1].Value, $inv) }
$anText = Seg-Text (Last-Command 'model_analyzer')
$sfm = [ordered]@{
    matcher                 = $(if ($sfmMetrics) { P $sfmMetrics 'matcher' } else { $matcherName -replace '_matcher', '' })
    cameraModel             = $(if ($sfmMetrics) { P $sfmMetrics 'cameraModel' } else { Rx $feText 'Camera:\s+#\d+ - (\w+)' })
    colmapCameras           = RxNum $anText 'Cameras:\s*(\d+)'
    imagesSeen              = RxNum $anText '\] Images:\s*(\d+)'
    registeredImages        = $(if ($sfmMetrics) { P $sfmMetrics 'registeredImages' } else { RxNum $anText 'Registered images:\s*(\d+)' })
    registrationPercent     = $(if ($sfmMetrics) { P $sfmMetrics 'registrationPercent' } else { $null })
    points3D                = RxNum $anText 'Points:\s*(\d+)'
    observations            = RxNum $anText 'Observations:\s*(\d+)'
    meanTrackLength         = D (RxNum $anText 'Mean track length:\s*([0-9.]+)') 3
    meanObservationsPerImage = D (RxNum $anText 'Mean observations per image:\s*([0-9.]+)') 1
    meanReprojectionErrorPx = $(if ($sfmMetrics) { P $sfmMetrics 'meanReprojectionErrorPx' } else { RxNum $anText 'Mean reprojection error:\s*([0-9.]+)' })
    featuresPerImage        = Stats $featureCounts 0
    unreadableFiles         = $unreadable
    matchedImagePairs       = $matchedPairs
    matchedPairsPerImage    = Ratio $matchedPairs $imageCount 1
    mapperRegistrations     = $registrations
    mapperDiscardedInitialPairs = $discards
    mapperGlobalBundleAdjustments = $globalBA
    mapperMeanVisiblePointFraction = $(if ($sees.Count) { D (($sees | Measure-Object -Average).Average) 3 } else { $null })
    mapperReportedMinutes   = $mapperMinutes
}

# ---------------------------------------------------------------- training
$trainMetrics = Read-JsonFile (Join-Path $scenePath 'lfs\training.metrics.json')
$trainLogPath = Join-Path $scenePath 'lfs\training.stdout.log'
$tl = if (Test-Path -LiteralPath $trainLogPath) { Get-Content -LiteralPath $trainLogPath -Raw } else { '' }
$stderrLines = 0; $stderrPath = Join-Path $scenePath 'lfs\training.stderr.log'; if (Test-Path -LiteralPath $stderrPath) { $stderrLines = @(Get-Content -LiteralPath $stderrPath | Where-Object { $_.Trim() }).Count }
$samples = @(foreach ($m in (RxAll $tl '\[(?:(\d+)h:)?(\d+)m:(\d+)s<[^\]]*\] (\d+)/(\d+) \| Loss: ([0-9.eE+-]+) \| Splats: (\d+)')) {
    $h = if ($m.Groups[1].Success) { [int]$m.Groups[1].Value } else { 0 }
    [pscustomobject]@{ iter = [int]$m.Groups[4].Value; total = [int]$m.Groups[5].Value; elapsed = $h * 3600 + [int]$m.Groups[2].Value * 60 + [int]$m.Groups[3].Value; loss = [double]::Parse($m.Groups[6].Value, $inv); splats = [int]$m.Groups[7].Value }
})
$iterations = $(if ($trainMetrics) { [int](P $trainMetrics 'targetIteration') } elseif ($samples.Count) { $samples[-1].total } else { $null })
$maxCap = $(if ($trainMetrics) { P $trainMetrics 'maxCap' } else { $null })
$trainCompletedSeconds = RxNum $tl 'Training completed in ([0-9.]+)s'
$curve = [Collections.Generic.List[object]]::new()
if ($samples.Count) {
    $milestones = @(@(100, 500, 1000, 2000, 5000, 10000, 15000, 20000, 25000, 30000, 40000, 50000) | Where-Object { $_ -le $samples[-1].iter })
    if ($milestones -notcontains $samples[-1].iter) { $milestones += $samples[-1].iter }
    $prev = $null
    foreach ($ms in $milestones) {
        $s = @($samples | Where-Object { $_.iter -le $ms })[-1]
        $rate = if ($prev -and $s.elapsed -gt $prev.elapsed) { D (($s.iter - $prev.iter) / ($s.elapsed - $prev.elapsed)) 2 } else { $null }
        $curve.Add([ordered]@{ iteration = $s.iter; elapsedSeconds = $s.elapsed; loss = $s.loss; splats = $s.splats; itersPerSecondSincePrevious = $rate })
        $prev = $s
    }
}
$capSample = $(if ($maxCap -and $samples.Count) { @($samples | Where-Object { $_.splats -ge [int]$maxCap }) | Select-Object -First 1 } else { $null })
$lastK = @(if ($samples.Count) { $samples | Where-Object { $_.iter -gt ($samples[-1].iter - 1000) } | ForEach-Object { $_.loss } })
$firstSplats = $(if ($samples.Count) { $samples[0].splats } else { $null })
$finalSplats = $(if ($null -ne (RxNum $tl 'Final splats: (\d+)')) { RxNum $tl 'Final splats: (\d+)' } elseif ($samples.Count) { $samples[-1].splats } else { $null })
$loaderHits = RxNum $tl 'Done: \d+ loaded, (\d+) hits, \d+ misses'
$loaderMisses = RxNum $tl 'Done: \d+ loaded, \d+ hits, (\d+) misses'
$train = [ordered]@{
    lichtfeldVersion        = $(if (Rx $tl 'version (v[^ |]+) \| tag (\w+)') { '{0} ({1})' -f (Rx $tl 'version (v[^ |]+) \| tag'), (Rx $tl 'version v[^ |]+ \| tag (\w+)') } else { $null })
    cudaDriverVersion       = Rx $tl 'CUDA driver version: ([\d.]+)'
    strategy                = $(if ($trainMetrics) { P $trainMetrics 'strategy' } else { $null })
    gut                     = $(if ($trainMetrics) { P $trainMetrics 'gut' } else { $null })
    maxCap                  = $maxCap
    iterations              = $iterations
    # v0.5.3 logs "Read N cameras and M images"; v0.5.4 "Training with M images"
    datasetImages           = $(if ($tl -match 'Read \d+ cameras and (\d+) images') { RxNum $tl 'Read \d+ cameras and (\d+) images' } else { RxNum $tl 'Training with (\d+) images' })
    wallTimeSeconds         = $(if ($trainMetrics) { P $trainMetrics 'wallTimeSeconds' } else { Cmd-Seconds 'train' })
    trainingLoopSeconds     = $trainCompletedSeconds
    startupAndShutdownSeconds = $(if ($trainMetrics -and $trainCompletedSeconds) { D ([double](P $trainMetrics 'wallTimeSeconds') - $trainCompletedSeconds) 1 } else { $null })
    itersPerSecondReported  = RxNum $tl 'avg ([0-9.]+) iter/s'
    itersPerSecond          = Ratio $iterations $trainCompletedSeconds 2
    secondsPer1kIterations  = $(if ($iterations -and $trainCompletedSeconds) { D (1000 * $trainCompletedSeconds / $iterations) 1 } else { $null })
    finalLoss               = $(if ($trainMetrics) { P $trainMetrics 'finalLoss' } elseif ($samples.Count) { $samples[-1].loss } else { $null })
    minLoss                 = $(if ($samples.Count) { ($samples | Measure-Object loss -Minimum).Minimum } else { $null })
    meanLossLast1kIters     = $(if ($lastK.Count) { D (($lastK | Measure-Object -Average).Average) 4 } else { $null })
    initialSplats           = $firstSplats
    finalSplats             = $finalSplats
    capReachedAtIteration   = $(if ($capSample) { $capSample.iter } else { $null })
    capReachedAtSeconds     = $(if ($capSample) { $capSample.elapsed } else { $null })
    splatsPerImage          = Ratio $finalSplats $imageCount 0
    splatsPerPoint3D        = Ratio $finalSplats $sfm.points3D 2
    splatsPerSecond         = Ratio $finalSplats $trainCompletedSeconds 0
    imageLoaderHits         = $loaderHits
    imageLoaderMisses       = $loaderMisses
    imageLoaderHitRate      = $(if ($null -ne $loaderHits -and $null -ne $loaderMisses -and ($loaderHits + $loaderMisses) -gt 0) { D ($loaderHits / ($loaderHits + $loaderMisses)) 4 } else { $null })
    arenaPeakMB             = RxNum $tl 'Arena stats: committed=\d+ MB, peak=(\d+) MB'
    arenaReallocs           = RxNum $tl 'reallocs=(\d+)'
    peakVramMiB             = $(if ($trainMetrics) { P $trainMetrics 'peakVramMiB' } else { $null })
    warnings                = (RxAll $tl '\[warn').Count
    errors                  = (RxAll $tl '\[error').Count
    stderrLines             = $stderrLines
    progressSamples         = $samples.Count
    curve                   = $curve
}

# ---------------------------------------------------------------- output PLY
$lfsDir = Join-Path $scenePath 'lfs'
$ply = @(if (Test-Path -LiteralPath $lfsDir) { Get-ChildItem -LiteralPath $lfsDir -Filter '*.ply' -File | Sort-Object LastWriteTime }) | Select-Object -Last 1
$plyVertices = $null; $plyProperties = $null
if ($ply) {
    try {
        $fs = [IO.File]::OpenRead($ply.FullName); $buf = New-Object byte[] 8192; $n = $fs.Read($buf, 0, $buf.Length); $fs.Dispose()
        $head = [Text.Encoding]::ASCII.GetString($buf, 0, $n); $hdr = $head.Substring(0, [math]::Max(0, $head.IndexOf('end_header')))
        $plyVertices = RxNum $hdr 'element vertex (\d+)'; $plyProperties = (RxAll $hdr '(?m)^property ').Count
    } catch { }
}
$output = [ordered]@{
    ply            = $(if ($ply) { $ply.FullName } else { $null })
    plyMiB         = $(if ($ply) { D ($ply.Length / 1MB) 1 } else { $null })
    plyVertices    = $plyVertices
    plyProperties  = $plyProperties
    bytesPerSplat  = $(if ($ply -and $plyVertices) { D ($ply.Length / $plyVertices) 1 } else { $null })
    plyMiBPerImage = $(if ($ply) { Ratio ($ply.Length / 1MB) $imageCount 2 } else { $null })
    checkpoint     = $(if ($trainMetrics) { P $trainMetrics 'checkpoint' } else { $null })
}

# ---------------------------------------------------------------- timings
$stageOrder = @('extract', 'sfm', 'train', 'export', 'orbit', 'all')
$stages = [ordered]@{}
foreach ($name in $stageOrder) {
    if (-not $segments.Contains($name)) { continue }
    $seg = $segments[$name]
    $secs = if ($seg.startTime -and $seg.endTime) { D ($seg.endTime - $seg.startTime).TotalSeconds 1 } else { $null }
    $stages[$name] = [ordered]@{ status = $seg.status; started = Iso $seg.startTime; ended = Iso $seg.endTime; seconds = $secs; error = $seg.error }
}
$stageSeconds = @($stages.Values | ForEach-Object { $_.seconds } | Where-Object { $null -ne $_ })
$totalSeconds = $(if ($stageSeconds.Count) { D (($stageSeconds | Measure-Object -Sum).Sum) 1 } else { $null })
$subSteps = [ordered]@{}
foreach ($n in @('ffmpeg', 'feature_extractor', 'sequential_matcher', 'exhaustive_matcher', 'mapper', 'model_analyzer', 'image_undistorter', 'train')) {
    $s = Cmd-Seconds $n
    if ($null -ne $s) { $subSteps[$n] = [ordered]@{ seconds = $s; share = $(if ($totalSeconds) { D ($s / $totalSeconds) 3 } else { $null }); secondsPerImage = Ratio $s $imageCount 3 } }
}
$sfmSeconds = $(if ($stages.Contains('sfm')) { $stages['sfm'].seconds } else { $null })
$trainStage = $(if ($stages.Contains('train')) { $stages['train'].seconds } else { $null })
$starts = @($segments.Values | ForEach-Object { $_.startTime } | Where-Object { $_ } | Sort-Object)
$ends = @($segments.Values | ForEach-Object { $_.endTime } | Where-Object { $_ } | Sort-Object)
$runStarted = $(if ($starts.Count) { $starts[0] } else { $null })
$runEnded = $(if ($ends.Count) { $ends[-1] } else { $null })
$span = $(if ($runStarted -and $runEnded) { D ($runEnded - $runStarted).TotalSeconds 1 } else { $null })
$timing = [ordered]@{
    runStarted          = Iso $runStarted
    runEnded            = Iso $runEnded
    totalStageSeconds   = $totalSeconds
    wallClockSpanSeconds = $span
    stagesContiguous    = $(if ($null -ne $span -and $null -ne $totalSeconds) { ($span - $totalSeconds) -lt 300 } else { $null })
    stages              = $stages
    steps               = $subSteps
    totalSecondsPerImage = Ratio $totalSeconds $imageCount 2
    sfmSecondsPerImage  = Ratio $sfmSeconds $imageCount 2
    sfmSecondsPerMegapixel = $(if ($sfmSeconds -and $megapixels) { Ratio $sfmSeconds ($imageCount * $megapixels) 3 } else { $null })
    trainSecondsPerImage = Ratio $trainStage $imageCount 2
    mapperRegistrationsPerMinute = $(if ($registrations -and (Cmd-Seconds 'mapper')) { D (60 * $registrations / (Cmd-Seconds 'mapper')) 1 } else { $null })
}

# ---------------------------------------------------------------- environment
$env_ = [ordered]@{ gpu = $null; gpuDriver = $null; gpuMemoryMiB = $null; cpu = $null; cpuCores = $null; cpuThreads = $null; ramGiB = $null; colmap = $null; lichtfeld = $train.lichtfeldVersion; host = $env:COMPUTERNAME }
try { $g = (& nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader,nounits 2>$null | Select-Object -First 1); if ($g) { $parts = $g -split ',\s*'; $env_.gpu = $parts[0]; $env_.gpuDriver = $parts[1]; $env_.gpuMemoryMiB = [int]$parts[2] } } catch { }
try { $c = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1; $env_.cpu = $c.Name.Trim(); $env_.cpuCores = $c.NumberOfCores; $env_.cpuThreads = $c.NumberOfLogicalProcessors } catch { }
try { $env_.ramGiB = [math]::Round((Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory / 1GB, 0) } catch { }
$colmapCmd = @($commands | Where-Object { $_.text -match 'colmap\.exe' }) | Select-Object -Last 1
if ($colmapCmd) { try { $exe = Rx $colmapCmd.text '^"?(.*?colmap\.exe)"?\s'; $env_.colmap = Split-Path -Leaf (Split-Path -Parent (Split-Path -Parent $exe)) } catch { } }

# ---------------------------------------------------------------- assemble
if (-not $RunId) { $RunId = $(if ($runStarted) { $runStarted.LocalDateTime.ToString('yyyyMMdd-HHmmss') } else { (Get-Date).ToString('yyyyMMdd-HHmmss') }) }
$stageStatuses = @($stages.Values | ForEach-Object { $_.status })
if ($Status -eq 'unknown') { $Status = if ($stageStatuses -contains 'failed') { 'failed' } elseif ($stageStatuses.Count -and @($stageStatuses | Where-Object { $_ -ne 'ok' }).Count -eq 0) { 'ok' } else { 'incomplete' } }
$record = [ordered]@{
    schema      = 1
    runId       = $RunId
    scene       = $sceneName
    scenePath   = $scenePath
    status      = $Status
    recordedAt  = (Get-Date).ToString('o')
    lens        = $(if ($capture) { P $capture 'lens' } else { $null })
    lensSource  = $(if ($capture) { P $capture 'lensSource' } else { $null })
    input       = [ordered]@{
        images          = $imageCount
        cameras         = $cameraCounts.Count
        imagesPerCamera = $cameraCounts
        width           = $width; height = $height; megapixels = $megapixels
        totalMiB        = $(if ($imageBytes) { D ($imageBytes / 1MB) 1 } else { $null })
        meanMiBPerImage = $(if ($imageBytes) { D ($imageBytes / 1MB / [math]::Max(1, $imageFiles.Count)) 2 } else { $null })
    }
    timing      = $timing
    sfm         = $sfm
    train       = $train
    output      = $output
    environment = $env_
}

$runDir = Join-Path $scenePath "runs\$RunId"
New-Item -ItemType Directory -Path $runDir -Force | Out-Null
$record | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $runDir 'stats.json') -Encoding utf8
if ($RunLog -and (Test-Path -LiteralPath $RunLog)) { $dest = Join-Path $runDir 'reconstruct.log'; if ((Resolve-Path -LiteralPath $RunLog).Path -ne $dest) { Copy-Item -LiteralPath $RunLog -Destination $dest -Force } }

# flat row for the cross-scene index
$flat = [ordered]@{
    runId = $RunId; scene = $sceneName; status = $Status; runStarted = Iso $runStarted; runEnded = Iso $runEnded
    lens = $record.lens; cameraModel = $sfm.cameraModel; matcher = $sfm.matcher; strategy = $train.strategy; iterations = $iterations; maxCap = $maxCap
    images = $imageCount; cameras = $cameraCounts.Count; megapixels = $megapixels; inputMiB = $record.input.totalMiB
    totalSeconds = $totalSeconds; totalWall = (Fmt-Span $totalSeconds); extractSeconds = $(if ($stages.Contains('extract')) { $stages['extract'].seconds } else { $null }); sfmSeconds = $sfmSeconds; trainSeconds = $trainStage
    featureSeconds = Cmd-Seconds 'feature_extractor'; matchSeconds = $(if ($null -ne (Cmd-Seconds 'exhaustive_matcher')) { Cmd-Seconds 'exhaustive_matcher' } else { Cmd-Seconds 'sequential_matcher' }); mapperSeconds = Cmd-Seconds 'mapper'
    totalSecondsPerImage = $timing.totalSecondsPerImage; sfmSecondsPerImage = $timing.sfmSecondsPerImage; trainSecondsPerImage = $timing.trainSecondsPerImage
    featuresPerImage = $(if ($sfm.featuresPerImage) { $sfm.featuresPerImage.mean } else { $null }); matchedPairs = $matchedPairs; matchedPairsPerImage = $sfm.matchedPairsPerImage
    registeredImages = $sfm.registeredImages; registrationPercent = $sfm.registrationPercent; points3D = $sfm.points3D; observations = $sfm.observations
    meanTrackLength = $sfm.meanTrackLength; meanObservationsPerImage = $sfm.meanObservationsPerImage; meanReprojectionErrorPx = $sfm.meanReprojectionErrorPx
    trainItersPerSecond = $train.itersPerSecond; trainLoopSeconds = $trainCompletedSeconds; finalLoss = $train.finalLoss; minLoss = $train.minLoss; meanLossLast1k = $train.meanLossLast1kIters
    finalSplats = $finalSplats; capReachedAtIteration = $train.capReachedAtIteration; splatsPerImage = $train.splatsPerImage; arenaPeakMB = $train.arenaPeakMB; peakVramMiB = $train.peakVramMiB
    plyMiB = $output.plyMiB; bytesPerSplat = $output.bytesPerSplat
    gpu = $env_.gpu; lichtfeld = $env_.lichtfeld; colmap = $env_.colmap
}
$keyPattern = '"runId":\s*"' + [regex]::Escape($RunId) + '"\s*,\s*"scene":\s*"' + [regex]::Escape($sceneName) + '"'
$existing = @(if (Test-Path -LiteralPath $script:RunsIndex) { Get-Content -LiteralPath $script:RunsIndex | Where-Object { $_.Trim() -and ($_ -notmatch $keyPattern) } })
$existing += ($flat | ConvertTo-Json -Depth 3 -Compress)
Set-Content -LiteralPath $script:RunsIndex -Value $existing -Encoding utf8

# ---------------------------------------------------------------- markdown summary
$fpi = $sfm.featuresPerImage
$md = [Text.StringBuilder]::new()
$null = $md.AppendLine("# Run $RunId - $sceneName")
$null = $md.AppendLine()
$null = $md.AppendLine("- Status: **$Status**  |  started $(if ($runStarted) { $runStarted.LocalDateTime.ToString('yyyy-MM-dd HH:mm:ss') } else { '-' })  |  ended $(if ($runEnded) { $runEnded.LocalDateTime.ToString('yyyy-MM-dd HH:mm:ss') } else { '-' })")
$null = $md.AppendLine("- Total stage time: **$(Fmt-Span $totalSeconds)** ($(Fmt $totalSeconds 0) s; $(Fmt $timing.totalSecondsPerImage 1) s/image)$(if ($timing.stagesContiguous -eq $false) { '  (stages ran at different times; see stage table)' })")
$null = $md.AppendLine("- Lens $($record.lens) -> $($sfm.cameraModel), $($sfm.matcher) matcher, $($train.strategy) x $iterations iterations, cap $maxCap$(if ($train.gut) { ', 3DGUT' })")
$null = $md.AppendLine()
$null = $md.AppendLine('## Input')
$null = $md.AppendLine()
$null = $md.AppendLine("- Images: **$imageCount** across $($cameraCounts.Count) cameras ($(@($cameraCounts.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '))")
$null = $md.AppendLine("- Resolution: $(Fmt $width 0) x $(Fmt $height 0) ($(Fmt $megapixels 1) MP); on disk $(Fmt $record.input.totalMiB 0) MiB, $(Fmt $record.input.meanMiBPerImage 2) MiB/image")
$null = $md.AppendLine()
$null = $md.AppendLine('## Timings')
$null = $md.AppendLine()
$null = $md.AppendLine('| Step | Time | Seconds | Share | s/image |')
$null = $md.AppendLine('|---|---|---:|---:|---:|')
foreach ($k in $stages.Keys) { $s = $stages[$k]; $null = $md.AppendLine("| stage **$k** ($($s.status)) | $(Fmt-Span $s.seconds) | $(Fmt $s.seconds 1) | $(if ($totalSeconds -and $s.seconds) { Fmt (100 * $s.seconds / $totalSeconds) 0 } else { '-' })% | $(Fmt (Ratio $s.seconds $imageCount 2) 2) |") }
foreach ($k in $subSteps.Keys) { $s = $subSteps[$k]; $null = $md.AppendLine("| $k | $(Fmt-Span $s.seconds) | $(Fmt $s.seconds 1) | $(if ($null -ne $s.share) { Fmt (100 * $s.share) 0 } else { '-' })% | $(Fmt $s.secondsPerImage 2) |") }
$null = $md.AppendLine()
$null = $md.AppendLine('## Structure from motion')
$null = $md.AppendLine()
$null = $md.AppendLine("- SIFT features/image: mean $(Fmt $(if ($fpi) { $fpi.mean }) 0), min $(Fmt $(if ($fpi) { $fpi.min }) 0), max $(Fmt $(if ($fpi) { $fpi.max }) 0)$(if ($unreadable) { "; $unreadable unreadable file(s) skipped" })")
$null = $md.AppendLine("- Verified image pairs: $(Fmt $matchedPairs 0) ($(Fmt $sfm.matchedPairsPerImage 1) per image)")
$null = $md.AppendLine("- Registered: **$(Fmt $sfm.registeredImages 0) / $imageCount** ($(Fmt $sfm.registrationPercent 1)%); mapper did $registrations registrations, $discards discarded initial pair(s), $globalBA global bundle adjustments, mean visible-point fraction $(Fmt $sfm.mapperMeanVisiblePointFraction 3); $(Fmt $timing.mapperRegistrationsPerMinute 1) registrations/min")
$null = $md.AppendLine("- Sparse model: **$(Fmt $sfm.points3D 0) points**, $(Fmt $sfm.observations 0) observations, mean track length $(Fmt $sfm.meanTrackLength 2), $(Fmt $sfm.meanObservationsPerImage 0) observations/image, mean reprojection error **$(Fmt $sfm.meanReprojectionErrorPx 3) px**")
$null = $md.AppendLine("- Throughput: $(Fmt $timing.sfmSecondsPerImage 2) s/image, $(Fmt $timing.sfmSecondsPerMegapixel 3) s/megapixel")
$null = $md.AppendLine()
$null = $md.AppendLine('## Training')
$null = $md.AppendLine()
$null = $md.AppendLine("- LichtFeld $($train.lichtfeldVersion), CUDA driver $($train.cudaDriverVersion); $(Fmt $train.datasetImages 0) images loaded")
$null = $md.AppendLine("- Loop: $(Fmt-Span $trainCompletedSeconds) for $iterations iterations = **$(Fmt $train.itersPerSecond 2) it/s** ($(Fmt $train.secondsPer1kIterations 1) s per 1k; LichtFeld reports $(Fmt $train.itersPerSecondReported 1) it/s); startup+shutdown $(Fmt $train.startupAndShutdownSeconds 1) s; $(Fmt $timing.trainSecondsPerImage 1) s/image")
$null = $md.AppendLine("- Loss: final **$(Fmt $train.finalLoss 4)**, min $(Fmt $train.minLoss 4), mean over last 1k iterations $(Fmt $train.meanLossLast1kIters 4)")
$null = $md.AppendLine("- Splats: $(Fmt $firstSplats 0) -> **$(Fmt $finalSplats 0)**$(if ($train.capReachedAtIteration) { " (cap reached at iteration $($train.capReachedAtIteration), $(Fmt-Span $train.capReachedAtSeconds))" }); $(Fmt $train.splatsPerImage 0) per image, $(Fmt $train.splatsPerPoint3D 2) per sparse point, $(Fmt $train.splatsPerSecond 0) per second")
$null = $md.AppendLine("- Memory: arena peak $(Fmt $train.arenaPeakMB 0) MB ($(Fmt $train.arenaReallocs 0) reallocs), peak VRAM $(Fmt $train.peakVramMiB 0) MiB; image loader hit rate $(if ($null -ne $train.imageLoaderHitRate) { Fmt (100 * $train.imageLoaderHitRate) 1 } else { '-' })% ($(Fmt $loaderMisses 0) misses); $($train.warnings) warnings, $($train.errors) errors, $stderrLines stderr lines")
if ($curve.Count) {
    $null = $md.AppendLine()
    $null = $md.AppendLine('| Iteration | Elapsed | Loss | Splats | it/s (segment) |')
    $null = $md.AppendLine('|---:|---:|---:|---:|---:|')
    foreach ($c in $curve) { $null = $md.AppendLine("| $($c.iteration) | $(Fmt-Span $c.elapsedSeconds) | $(Fmt $c.loss 4) | $(Fmt $c.splats 0) | $(Fmt $c.itersPerSecondSincePrevious 2) |") }
}
$null = $md.AppendLine()
$null = $md.AppendLine('## Output')
$null = $md.AppendLine()
$null = $md.AppendLine("- PLY: $($output.ply) - **$(Fmt $output.plyMiB 1) MiB**, $(Fmt $plyVertices 0) vertices x $plyProperties properties, $(Fmt $output.bytesPerSplat 1) bytes/splat, $(Fmt $output.plyMiBPerImage 2) MiB per input image")
$null = $md.AppendLine()
$null = $md.AppendLine('## Environment')
$null = $md.AppendLine()
$null = $md.AppendLine("- GPU $($env_.gpu) (driver $($env_.gpuDriver), $($env_.gpuMemoryMiB) MiB); CPU $($env_.cpu) ($($env_.cpuCores) cores / $($env_.cpuThreads) threads); RAM $($env_.ramGiB) GiB; COLMAP $($env_.colmap); host $($env_.host)")
$mdText = $md.ToString()
Set-Content -LiteralPath (Join-Path $runDir 'stats.md') -Value $mdText -Encoding utf8
if (-not $Quiet) { Write-Host $mdText }
Write-Host "Stats written to $runDir\stats.{json,md} and appended to $script:RunsIndex" -ForegroundColor DarkGray
