#requires -Version 7.0
<#
.SYNOPSIS
  One command: capture folder in, trained Gaussian splat out.

.DESCRIPTION
  Wraps run.ps1 (extract -> sfm -> train) for a single scene folder, resolves the GoPro
  lens mode, and prints live stage/sub-stage progress with elapsed time, estimated time
  left, and estimated time of completion.

  Lens resolution, first match wins:
    1. -Lens argument
    2. folder name token: _wide, -wide, _linear, -linear, _linear-hl, _narrow, _fisheye, _pinhole
    3. <folder>\capture.json "lens" (written by a previous run)
    4. GoPro MakerNote fingerprint (PROVISIONAL; see Get-MakerNoteLens)
  If nothing matches the script stops and tells you how to declare the lens.

  LichtFeld Studio is taken from -LichtFeldPath, else the LICHTFELD_PATH environment variable,
  else LichtFeld-Studio on PATH, else pipeline\tools\lichtfeld\bin\LichtFeld-Studio.exe.

  Time estimates come from pipeline\timings.json, which starts seeded with rates measured
  on an RTX 6000 Ada and is updated after every completed sub-stage, so estimates adapt to
  your machine with each run. COLMAP sub-stages report no live progress (run.ps1 captures
  their output until they exit), so their "left" figure is rate-based. Training progress is
  read live from lfs\training.stdout.log.

.EXAMPLE
  .\pipeline\reconstruct.cmd .\_workspace\20260912_park_bench_wide
  .\pipeline\reconstruct.cmd .\_workspace\20260920_lobby -Lens linear -Iterations 20000
  .\pipeline\reconstruct.cmd .\_workspace\20260920_lobby_wide -DryRun
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)] [string] $Folder,
    [ValidateSet('linear', 'linear-hl', 'narrow', 'pinhole', 'wide', 'fisheye')] [string] $Lens,
    [ValidateSet('extract', 'sfm', 'train')] [string[]] $Stages = @('extract', 'sfm', 'train'),
    [switch] $Force,
    [switch] $DryRun,
    [ValidateRange(1, 1000000)] [int] $Iterations = 30000,
    [ValidateRange(10000, 10000000)] [int] $MaxCap = 1500000,
    [ValidateSet('mcmc', 'mrnf', 'igs+')] [string] $Strategy = 'mcmc',
    [ValidateRange(0.1, 120)] [double] $Fps = 3,
    [string] $LichtFeldPath,
    [ValidateRange(1, 300)] [int] $ReportSeconds = 15
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- paths and constants
$script:RunScript = Join-Path $PSScriptRoot 'run.ps1'
$script:Pwsh = Join-Path $PSScriptRoot 'tools\pwsh\pwsh.exe'
if (-not (Test-Path -LiteralPath $script:Pwsh)) { $script:Pwsh = (Get-Process -Id $PID).Path }
$script:TimingsPath = Join-Path $PSScriptRoot 'timings.json'
$script:ScenePath = [IO.Path]::GetFullPath($Folder)
if (-not (Test-Path -LiteralPath $script:ScenePath -PathType Container)) { throw "Folder does not exist: $script:ScenePath" }
$script:SceneName = Split-Path -Leaf $script:ScenePath
$script:Root = Split-Path -Parent $script:ScenePath
# Every run gets its own folder: <scene>\runs\<runId>\ holds reconstruct.log (timestamped
# status lines) and, after the last stage, stats.json/stats.md written by stats.ps1.
$script:RunId = (Get-Date).ToString('yyyyMMdd-HHmmss')
$script:RunDir = Join-Path $script:ScenePath "runs\$script:RunId"
$script:RunLogPath = $null   # set when the run starts (never for -DryRun)

# Same lookup order as run.ps1, resolved here so the plan shows the binary that will train.
if (-not $LichtFeldPath) {
    $onPath = Get-Command 'LichtFeld-Studio' -ErrorAction SilentlyContinue | Select-Object -First 1
    $LichtFeldPath = if ($env:LICHTFELD_PATH) { $env:LICHTFELD_PATH } elseif ($onPath) { $onPath.Source } else { Join-Path $PSScriptRoot 'tools\lichtfeld\bin\LichtFeld-Studio.exe' }
}
if (($Stages -contains 'train') -and -not (Test-Path -LiteralPath $LichtFeldPath -PathType Leaf)) {
    $message = "LichtFeld Studio was not found at $LichtFeldPath. Install or build it (README.md, pipeline\tools\INSTALLS.md), then pass -LichtFeldPath or set LICHTFELD_PATH."
    if ($DryRun) { Write-Warning $message } else { throw $message }
}

$script:LensModel = @{
    'linear' = 'OPENCV'; 'linear-hl' = 'OPENCV'; 'narrow' = 'OPENCV'; 'pinhole' = 'OPENCV'
    'wide' = 'OPENCV_FISHEYE'; 'fisheye' = 'OPENCV_FISHEYE'
}

# Seconds per unit, measured on an RTX 6000 Ada (48 GB) with 27 MP GoPro stills (2026-09-08/12).
# Only the starting point: timings.json re-learns them on your machine after every run.
# Unit is images unless noted. exhaustive_matcher scales with image pairs (N^2).
# Training is seconds per iteration; 3DGUT was unmeasured when seeded and is learned on
# the first fisheye run.
$script:DefaultRates = [ordered]@{
    OPENCV = [ordered]@{
        feature_extractor = 0.13; sequential_matcher = 0.75; exhaustive_matcher = 0.0014
        mapper = 3.5; model_analyzer = 0.15; image_undistorter = 0.02; train = 0.046; train_startup = 25
    }
    OPENCV_FISHEYE = [ordered]@{
        feature_extractor = 0.12; sequential_matcher = 0.75; exhaustive_matcher = 0.0014
        mapper = 3.5; model_analyzer = 0.15; image_undistorter = 0.02; train = 0.08; train_startup = 25
    }
}

# ---------------------------------------------------------------- helpers
function Format-Span([double] $Seconds) {
    if ($Seconds -lt 0 -or [double]::IsNaN($Seconds)) { $Seconds = 0 }
    $t = [TimeSpan]::FromSeconds([math]::Round($Seconds))
    if ($t.TotalHours -ge 1) { return ('{0}:{1:mm}:{1:ss}' -f [int][math]::Floor($t.TotalHours), $t) }
    return ('{0:mm}:{0:ss}' -f $t)
}

function Write-Status([string] $Message, [string] $Color = 'Gray') {
    $now = Get-Date
    Write-Host ('[{0:HH:mm:ss}] {1}' -f $now, $Message) -ForegroundColor $Color
    if ($script:RunLogPath) { try { Add-Content -LiteralPath $script:RunLogPath -Value ('[{0}] {1}' -f $now.ToString('yyyy-MM-ddTHH:mm:ss.fffK'), $Message) -Encoding utf8 } catch { } }
}

function Read-Timings {
    if (Test-Path -LiteralPath $script:TimingsPath) {
        try {
            $json = Get-Content -LiteralPath $script:TimingsPath -Raw | ConvertFrom-Json -AsHashtable
            foreach ($model in $script:DefaultRates.Keys) {
                if (-not $json.ContainsKey($model)) { $json[$model] = @{} }
                foreach ($k in $script:DefaultRates[$model].Keys) { if (-not $json[$model].ContainsKey($k)) { $json[$model][$k] = $script:DefaultRates[$model][$k] } }
            }
            return $json
        } catch { Write-Warning "timings.json is unreadable; using seeded rates. $($_.Exception.Message)" }
    }
    $seed = @{}
    foreach ($model in $script:DefaultRates.Keys) { $seed[$model] = @{}; foreach ($k in $script:DefaultRates[$model].Keys) { $seed[$model][$k] = $script:DefaultRates[$model][$k] } }
    return $seed
}

function Save-Timings([hashtable] $Timings) {
    $Timings['_note'] = 'Seconds per unit (images; image pairs for exhaustive_matcher; iterations for train). Updated by reconstruct.ps1 after each completed sub-stage.'
    $Timings['_updated'] = (Get-Date).ToString('o')
    $Timings | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:TimingsPath -Encoding utf8
}

# Lens from folder name: a token delimited by _ or - (or the string ends), e.g.
# 20260912_tom_wide, tom-linear, tom_linear-hl_take2. Longer tokens are tried first.
function Get-FolderNameLens([string] $Name) {
    foreach ($token in @('linear-hl', 'linear', 'fisheye', 'pinhole', 'narrow', 'wide')) {
        if ($Name -match "(?i)(^|[_-])$([regex]::Escape($token))([_-]|$)") { return $token }
    }
    return $null
}

# PROVISIONAL GoPro MakerNote fingerprint. Bytes 3 and 7 of the HERO12 MakerNote were
# 0x17/0x4C ('L') on every one of 545 Linear stills (2026-09-08) and 0x16/0x4E ('N') on
# every one of 410 Wide stills (2026-09-12). Two shoots cannot rule out another setting
# that changed between them, so this is used only as a last resort and always warns.
# 0x36/0x4E appeared on one of four HERO12 bodies (cam3) on the 2026-09-19 Wide shoot, so
# byte 3 varies within a lens mode; byte 7 ('L' vs 'N') is the discriminating one so far.
# Add rows as new shoots confirm or refute them.
$script:MakerNoteFingerprints = @{ '17-4C' = 'linear'; '16-4E' = 'wide'; '36-4E' = 'wide' }

function Get-MakerNoteFingerprint([string] $JpegPath) {
    try {
        $b = [IO.File]::ReadAllBytes($JpegPath)
        $i = 2
        while ($i + 4 -lt $b.Length -and $b[$i] -eq 0xFF) {
            # Note: PowerShell keeps [byte] for -shl and silently overflows, so widen to [int] first.
            $marker = $b[$i + 1]; $len = [int]$b[$i + 2] * 256 + [int]$b[$i + 3]
            if ($marker -eq 0xE1 -and [Text.Encoding]::ASCII.GetString($b, $i + 4, 4) -eq 'Exif') {
                $t = $i + 10
                $le = ([Text.Encoding]::ASCII.GetString($b, $t, 2) -eq 'II')
                $r16 = { param($o) if ($le) { [int]$b[$t + $o] + [int]$b[$t + $o + 1] * 256 } else { [int]$b[$t + $o] * 256 + [int]$b[$t + $o + 1] } }
                $r32 = { param($o) if ($le) { [int64]$b[$t + $o] + [int64]$b[$t + $o + 1] * 256 + [int64]$b[$t + $o + 2] * 65536 + [int64]$b[$t + $o + 3] * 16777216 } else { [int64]$b[$t + $o] * 16777216 + [int64]$b[$t + $o + 1] * 65536 + [int64]$b[$t + $o + 2] * 256 + [int64]$b[$t + $o + 3] } }
                $ifd0 = & $r32 4
                $n = & $r16 $ifd0
                $exif = 0
                for ($k = 0; $k -lt $n; $k++) { $e = $ifd0 + 2 + $k * 12; if ((& $r16 $e) -eq 0x8769) { $exif = & $r32 ($e + 8) } }
                if ($exif -eq 0) { return $null }
                $n2 = & $r16 $exif
                for ($k = 0; $k -lt $n2; $k++) {
                    $e = $exif + 2 + $k * 12
                    if ((& $r16 $e) -eq 0x927C) {
                        $vo = & $r32 ($e + 8)
                        if ((& $r32 ($e + 4)) -lt 8) { return $null }
                        return ('{0:X2}-{1:X2}' -f $b[$t + $vo + 3], $b[$t + $vo + 7])
                    }
                }
                return $null
            }
            $i += 2 + $len
        }
    } catch { }
    return $null
}

function Get-MakerNoteLens {
    $sample = Get-ChildItem -LiteralPath $script:ScenePath -Directory | Where-Object Name -match '^cam' |
        ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -File -Filter '*.jp*g' | Select-Object -First 1 } | Select-Object -First 3
    $prints = @($sample | ForEach-Object { Get-MakerNoteFingerprint $_.FullName } | Where-Object { $_ } | Sort-Object -Unique)
    if ($prints.Count -ne 1) { return $null }
    if ($script:MakerNoteFingerprints.ContainsKey($prints[0])) { return [pscustomobject]@{ Lens = $script:MakerNoteFingerprints[$prints[0]]; Fingerprint = $prints[0] } }
    return [pscustomobject]@{ Lens = $null; Fingerprint = $prints[0] }
}

function Resolve-Lens {
    if ($Lens) { return [pscustomobject]@{ Lens = $Lens; Source = '-Lens argument' } }
    $fromName = Get-FolderNameLens $script:SceneName
    if ($fromName) { return [pscustomobject]@{ Lens = $fromName; Source = "folder name token '$fromName'" } }
    $manifest = Join-Path $script:ScenePath 'capture.json'
    if (Test-Path -LiteralPath $manifest) {
        try { $m = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json; if ($m.lens) { return [pscustomobject]@{ Lens = [string]$m.lens; Source = 'capture.json' } } } catch { }
    }
    $mn = Get-MakerNoteLens
    if ($mn -and $mn.Lens) {
        Write-Warning "Lens '$($mn.Lens)' was inferred from the GoPro MakerNote fingerprint $($mn.Fingerprint). This is provisional (two shoots of evidence). Confirm with -Lens or a _wide/_linear folder suffix if it is wrong."
        return [pscustomobject]@{ Lens = $mn.Lens; Source = "MakerNote fingerprint $($mn.Fingerprint) (provisional)" }
    }
    $seen = if ($mn) { " The MakerNote fingerprint $($mn.Fingerprint) is not in the known table." } else { '' }
    throw "Cannot determine the lens mode for $script:SceneName.$seen Pass -Lens wide|linear, or add _wide / _linear (or -wide / -linear) to the folder name."
}

function Count-Images {
    $images = Join-Path $script:ScenePath 'images'
    $n = 0
    if (Test-Path -LiteralPath $images) { $n = @(Get-ChildItem -LiteralPath $images -Recurse -File -Include '*.jpg', '*.jpeg', '*.png').Count }
    if ($n -eq 0) {
        foreach ($d in Get-ChildItem -LiteralPath $script:ScenePath -Directory | Where-Object Name -match '^cam') { $n += @(Get-ChildItem -LiteralPath $d.FullName -File -Include '*.jpg', '*.jpeg', '*.png').Count }
    }
    if ($n -eq 0) {
        $raw = Join-Path $script:ScenePath 'raw'
        $videos = @(Get-ChildItem -LiteralPath $(if (Test-Path $raw) { $raw } else { $script:ScenePath }) -File -Include '*.mp4', '*.mov' -ErrorAction SilentlyContinue)
        if ($videos.Count) { $n = [int]($videos.Count * 60 * $Fps) }   # rough: one minute per clip
    }
    return [math]::Max($n, 1)
}

# ---------------------------------------------------------------- estimate model
# A plan is an ordered list of sub-stages with unit counts; the estimate for one is
# rate[model][name] * units. The exhaustive fallback is appended only when observed.
function New-Plan([string] $Model, [int] $Images, [string[]] $StageList) {
    $plan = [Collections.Generic.List[object]]::new()
    $add = { param($stage, $name, $units) $plan.Add([pscustomobject]@{ Stage = $stage; Name = $name; Units = $units; Status = 'pending'; Started = $null; Ended = $null }) }
    if ($StageList -contains 'extract') { & $add 'extract' 'extract' $Images }
    if ($StageList -contains 'sfm') {
        & $add 'sfm' 'feature_extractor' $Images
        & $add 'sfm' 'sequential_matcher' $Images
        & $add 'sfm' 'mapper' $Images
        & $add 'sfm' 'model_analyzer' $Images
    }
    if ($StageList -contains 'train') {
        if ($Model -eq 'OPENCV') { & $add 'train' 'image_undistorter' $Images }
        & $add 'train' 'train' $Iterations
    }
    return , $plan   # comma keeps the List intact; a bare return would unroll it into an array
}

function Get-Estimate([hashtable] $Rates, [object] $Item) {
    switch ($Item.Name) {
        'extract' { return [math]::Max(2, 0.01 * $Item.Units) }
        'exhaustive_matcher' { return $Rates['exhaustive_matcher'] * $Item.Units * $Item.Units }
        'train' { return $Rates['train_startup'] + $Rates['train'] * $Item.Units }
        default { if ($Rates.ContainsKey($Item.Name)) { return $Rates[$Item.Name] * $Item.Units } else { return 60 } }
    }
}

# ---------------------------------------------------------------- main
$resolved = Resolve-Lens
$model = $script:LensModel[$resolved.Lens]
$images = Count-Images
$timings = Read-Timings
$rates = $timings[$model]
$plan = New-Plan $model $images $Stages

Write-Host ''
Write-Host "Scene      : $script:ScenePath" -ForegroundColor Cyan
Write-Host "Lens       : $($resolved.Lens) -> COLMAP $model $(if ($model -eq 'OPENCV_FISHEYE') { '(3DGUT training)' } else { '(undistort + pinhole training)' })" -ForegroundColor Cyan
Write-Host "Lens source: $($resolved.Source)" -ForegroundColor Cyan
Write-Host "Images     : $images$(if ($images -eq 1) { ' (unknown; estimates will be poor)' })" -ForegroundColor Cyan
Write-Host "Stages     : $($Stages -join ', ')  |  iterations $Iterations, cap $MaxCap, $Strategy" -ForegroundColor Cyan
Write-Host "LichtFeld  : $LichtFeldPath" -ForegroundColor Cyan
$initial = ($plan | ForEach-Object { Get-Estimate $rates $_ } | Measure-Object -Sum).Sum
Write-Host ("Estimate   : ~{0} total, done around {1:HH:mm} (rates from {2})" -f (Format-Span $initial), (Get-Date).AddSeconds($initial), $(if (Test-Path $script:TimingsPath) { 'timings.json' } else { 'seeded defaults' })) -ForegroundColor Cyan
Write-Host ''

if ($DryRun) {
    Write-Host 'Dry run. Commands that would be executed:' -ForegroundColor Yellow
    foreach ($stage in $Stages) {
        $line = @('-NoProfile', '-File', $script:RunScript, '-Scene', $script:SceneName, '-Root', $script:Root, '-Lens', $resolved.Lens, '-Stage', $stage, '-LichtFeldPath', $LichtFeldPath, '-Iterations', $Iterations, '-MaxCap', $MaxCap, '-Strategy', $Strategy, '-Fps', $Fps)
        if ($Force) { $line += '-Force' }
        Write-Host ("  {0} {1}" -f $script:Pwsh, ($line -join ' '))
    }
    foreach ($item in $plan) { Write-Host ("  {0,-8} {1,-20} ~{2}" -f $item.Stage, $item.Name, (Format-Span (Get-Estimate $rates $item))) }
    return
}

New-Item -ItemType Directory -Path $script:RunDir -Force | Out-Null
$script:RunLogPath = Join-Path $script:RunDir 'reconstruct.log'
Write-Status "RUN $script:RunId scene=$script:ScenePath lens=$($resolved.Lens) ($($resolved.Source)) model=$model images=$images stages=$($Stages -join ',') iterations=$Iterations maxCap=$MaxCap strategy=$Strategy estimate=$(Format-Span $initial)" 'DarkGray'

$overall = [Diagnostics.Stopwatch]::StartNew()
$child = $null
$exitCode = 0
$results = [ordered]@{}

function Get-Remaining([object[]] $Plan, [hashtable] $Rates, [object] $Current, [double] $CurrentElapsed, [double] $LiveLeft) {
    $left = 0.0
    foreach ($item in $Plan) {
        if ($item.Status -eq 'done' -or $item.Status -eq 'skipped') { continue }
        $est = Get-Estimate $Rates $item
        if ($item -eq $Current) {
            if ($LiveLeft -ge 0) { $left += $LiveLeft }
            else { $left += [math]::Max($est - $CurrentElapsed, [math]::Min(10, $est * 0.05)) }
        } else { $left += $est }
    }
    return $left
}

# Blend a newly observed rate into timings.json (half old, half new). Small runs are
# skipped: per-image rates from a few dozen frames are dominated by start-up cost, and
# short training runs never reach the splat cap where the per-iteration cost settles.
function Learn-Rate([hashtable] $Timings, [string] $Model, [object] $Item, [double] $Seconds) {
    if ($Seconds -le 0 -or $Item.Units -le 0) { return }
    $blend = { param($key, $observed) $old = [double]$Timings[$Model][$key]; $Timings[$Model][$key] = [math]::Round(($old + $observed) / 2, 6) }
    switch ($Item.Name) {
        'extract' { return }
        'exhaustive_matcher' { if ($Item.Units -ge 100) { & $blend 'exhaustive_matcher' ($Seconds / ($Item.Units * $Item.Units)) } }
        'train' { if ($Item.Units -ge 5000) { & $blend 'train' (($Seconds - [double]$Timings[$Model]['train_startup']) / $Item.Units) } }
        default { if ($Item.Units -ge 100) { & $blend $Item.Name ($Seconds / $Item.Units) } }
    }
}

try {
    foreach ($stage in $Stages) {
        $stageWatch = [Diagnostics.Stopwatch]::StartNew()
        $out = Join-Path $script:ScenePath "reconstruct.$stage.out"
        $err = Join-Path $script:ScenePath "reconstruct.$stage.err"
        Remove-Item -LiteralPath $out, $err -Force -ErrorAction SilentlyContinue
        $args = @('-NoProfile', '-File', $script:RunScript, '-Scene', $script:SceneName, '-Root', $script:Root, '-Lens', $resolved.Lens, '-Stage', $stage, '-LichtFeldPath', $LichtFeldPath, '-Iterations', "$Iterations", '-MaxCap', "$MaxCap", '-Strategy', $Strategy, '-Fps', "$Fps")
        if ($Force) { $args += '-Force' }
        Write-Status "STAGE $stage starting" 'Yellow'
        $child = Start-Process -FilePath $script:Pwsh -ArgumentList $args -WorkingDirectory $script:Root -PassThru -NoNewWindow -RedirectStandardOutput $out -RedirectStandardError $err

        $current = $null
        $currentStart = $null
        $lastLine = 0
        $lastReport = [DateTime]::MinValue
        $trainLog = Join-Path $script:ScenePath 'lfs\training.stdout.log'
        $trainLive = ''
        $liveLeft = -1.0

        while ($true) {
            $child.Refresh()
            $exited = $child.HasExited
            # Consume new run.ps1 output lines and track sub-stage transitions.
            $lines = @()
            if (Test-Path -LiteralPath $out) { $lines = @(Get-Content -LiteralPath $out -ErrorAction SilentlyContinue) }
            for ($li = $lastLine; $li -lt $lines.Count; $li++) {
                $line = $lines[$li]
                $name = $null
                if ($line -match 'COMMAND .*colmap\.exe (\w+) --') { $name = $matches[1] }
                elseif ($line -match 'COMMAND .* --headless --train ') { $name = 'train' }
                elseif ($line -match '\] DONE extract:') { $name = 'extract'; $lines += '' }
                if ($line -match 'retrying with exhaustive matching') {
                    # Sequential path failed: add the fallback sub-stages to the plan after the current one.
                    $idx = [array]::IndexOf($plan.ToArray(), $current)
                    if ($idx -lt 0) { $idx = $plan.Count - 1 }
                    foreach ($p in $plan) { if ($p.Stage -eq 'sfm' -and $p.Status -eq 'pending' -and $p.Name -in @('mapper')) { $p.Status = 'skipped' } }
                    $plan.Insert($idx + 1, [pscustomobject]@{ Stage = 'sfm'; Name = 'exhaustive_matcher'; Units = $images; Status = 'pending'; Started = $null; Ended = $null })
                    $plan.Insert($idx + 2, [pscustomobject]@{ Stage = 'sfm'; Name = 'mapper'; Units = $images; Status = 'pending'; Started = $null; Ended = $null })
                    Write-Status 'sequential matching did not yield one model; COLMAP is retrying with exhaustive matching (slower)' 'DarkYellow'
                }
                if ($line -match '\] SKIP (\w+):') { foreach ($p in $plan) { if ($p.Stage -eq $stage -and $p.Status -eq 'pending') { $p.Status = 'skipped' } }; Write-Status "SKIP $stage (already complete; use -Force to redo)" 'DarkGray' }
                if ($line -match '\] (DONE (sfm|train|undistort):.*)') { Write-Status $matches[1] 'Green'; $results[$stage] = $matches[1] }
                if ($line -match '\] FAILED .*error=(.*)') { Write-Status "FAILED: $($matches[1])" 'Red' }
                if ($name) {
                    if ($current -and $current.Status -eq 'running') {
                        $current.Status = 'done'; $current.Ended = Get-Date
                        $secs = ($current.Ended - $current.Started).TotalSeconds
                        Learn-Rate $timings $model $current $secs
                        Write-Status ("  {0}/{1} done in {2}" -f $current.Stage, $current.Name, (Format-Span $secs)) 'DarkGreen'
                    }
                    $current = $plan | Where-Object { $_.Name -eq $name -and $_.Status -eq 'pending' } | Select-Object -First 1
                    if (-not $current) { $current = [pscustomobject]@{ Stage = $stage; Name = $name; Units = $images; Status = 'pending'; Started = $null; Ended = $null }; $plan.Add($current) }
                    $current.Status = 'running'; $current.Started = Get-Date
                    $liveLeft = -1.0
                    Write-Status ("  {0}/{1} started (~{2})" -f $current.Stage, $current.Name, (Format-Span (Get-Estimate $rates $current))) 'DarkCyan'
                }
            }
            $lastLine = $lines.Count

            # Live training progress from LichtFeld's own progress bar.
            if ($current -and $current.Name -eq 'train' -and (Test-Path -LiteralPath $trainLog)) {
                $tail = ''
                try { $fs = [IO.File]::Open($trainLog, 'Open', 'Read', 'ReadWrite'); $fs.Seek(-[math]::Min(4096, $fs.Length), 'End') | Out-Null; $sr = [IO.StreamReader]::new($fs); $tail = $sr.ReadToEnd(); $sr.Dispose() } catch { }
                $m = [regex]::Matches($tail, '(\d+)/(\d+) \| Loss: ([0-9.]+)')
                $r = [regex]::Matches($tail, '<(\d+)m:(\d+)s\]')
                if ($m.Count) {
                    $last = $m[$m.Count - 1]
                    $trainLive = ('iter {0}/{1} ({2:P0}) loss {3}' -f $last.Groups[1].Value, $last.Groups[2].Value, ([double]$last.Groups[1].Value / [double]$last.Groups[2].Value), $last.Groups[3].Value)
                    if ($r.Count) { $rr = $r[$r.Count - 1]; $liveLeft = [int]$rr.Groups[1].Value * 60 + [int]$rr.Groups[2].Value }
                }
            }

            $now = Get-Date
            if (($now - $lastReport).TotalSeconds -ge $ReportSeconds -and $current) {
                $lastReport = $now
                $curElapsed = ($now - $current.Started).TotalSeconds
                $left = Get-Remaining $plan.ToArray() $rates $current $curElapsed $liveLeft
                $label = if ($trainLive -and $current.Name -eq 'train') { "train $trainLive" } else { "$($current.Stage)/$($current.Name)" }
                Write-Status ("{0,-46} sub-stage {1} | elapsed {2} | left ~{3} | ETC {4:HH:mm}" -f $label, (Format-Span $curElapsed), (Format-Span $overall.Elapsed.TotalSeconds), (Format-Span $left), $now.AddSeconds($left))
            }
            if ($exited) { break }
            Start-Sleep -Seconds 2
        }

        if ($current -and $current.Status -eq 'running') {
            $current.Status = 'done'; $current.Ended = Get-Date
            $secs = ($current.Ended - $current.Started).TotalSeconds
            if ($child.ExitCode -eq 0) { Learn-Rate $timings $model $current $secs }
            Write-Status ("  {0}/{1} done in {2}" -f $current.Stage, $current.Name, (Format-Span $secs)) 'DarkGreen'
        }
        foreach ($p in $plan) { if ($p.Stage -eq $stage -and $p.Status -eq 'pending') { $p.Status = 'skipped' } }
        Save-Timings $timings
        $stageWatch.Stop()
        if ($child.ExitCode -ne 0) {
            $exitCode = $child.ExitCode
            $tailErr = if (Test-Path -LiteralPath $err) { (Get-Content -LiteralPath $err -Tail 15) -join "`n" } else { '' }
            Write-Status ("STAGE $stage FAILED after {0} (exit {1}). See {2} and {3}." -f (Format-Span $stageWatch.Elapsed.TotalSeconds), $exitCode, (Join-Path $script:ScenePath 'log.txt'), $err) 'Red'
            if ($tailErr) { Write-Host $tailErr -ForegroundColor DarkRed }
            break
        }
        Write-Status ("STAGE $stage complete in {0} (total {1})" -f (Format-Span $stageWatch.Elapsed.TotalSeconds), (Format-Span $overall.Elapsed.TotalSeconds)) 'Green'
        $child = $null
    }
} finally {
    if ($child -and -not $child.HasExited) {
        Write-Status "stopping pipeline process tree (pid $($child.Id))" 'Red'
        & taskkill /PID $child.Id /T /F 2>$null | Out-Null
    }
}

$overall.Stop()
Write-Status ("RUN {0} after {1}" -f $(if ($exitCode -ne 0) { 'FAILED' } else { 'COMPLETE' }), (Format-Span $overall.Elapsed.TotalSeconds)) $(if ($exitCode -ne 0) { 'Red' } else { 'Green' })
# Harvest per-run metrics from what the stages left on disk. Nothing is re-run; this reads
# log.txt, the metrics JSON files and the training log and takes a few seconds.
$statsScript = Join-Path $PSScriptRoot 'stats.ps1'
if (Test-Path -LiteralPath $statsScript) {
    try { & $statsScript -Scene $script:ScenePath -RunId $script:RunId -Status $(if ($exitCode -ne 0) { 'failed' } else { 'ok' }) -Quiet }
    catch { Write-Warning "stats.ps1 failed: $($_.Exception.Message)" }
}
Write-Host ''
if ($exitCode -ne 0) {
    Write-Host ("Reconstruction FAILED after {0}." -f (Format-Span $overall.Elapsed.TotalSeconds)) -ForegroundColor Red
    exit $exitCode
}
Write-Host ("Reconstruction complete in {0}." -f (Format-Span $overall.Elapsed.TotalSeconds)) -ForegroundColor Green
foreach ($k in $results.Keys) { Write-Host "  $($results[$k])" }
Write-Host "  Run log and stats: $script:RunDir"
$ply = Get-ChildItem -LiteralPath (Join-Path $script:ScenePath 'lfs') -Filter 'splat_*.ply' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
if ($ply) {
    Write-Host ("  PLY: {0} ({1:N0} MiB)" -f $ply.FullName, ($ply.Length / 1MB))
    Write-Host ("  Publish: cd web-viewer; node scripts\build-viewer.mjs '{0}' <slug>   (see ..\README.md)" -f $ply.FullName) -ForegroundColor DarkGray
}
