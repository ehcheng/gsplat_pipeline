#requires -Version 5.1
# Compares the installed pipeline tools against their latest upstream versions. Read-only: it
# runs each tool's version command and queries GitHub, nodejs.org, npm and PyPI; nothing is
# downloaded or changed. Run it about once a month and follow "Keeping tools current" in
# pipeline/tools/INSTALLS.md for anything marked UPDATE.
#
#   powershell -ExecutionPolicy Bypass -File pipeline\tools\installers\check-updates.ps1
#
# Set GITHUB_TOKEN to avoid GitHub's anonymous rate limit (60 requests an hour).
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$tools = Split-Path -Parent $PSScriptRoot
$repo  = Split-Path -Parent (Split-Path -Parent $tools)

function Find-Exe([string] $EnvName, [string] $Command, [string[]] $Candidates) {
    if ($EnvName) { $v = [Environment]::GetEnvironmentVariable($EnvName); if ($v -and (Test-Path $v)) { return $v } }
    $cmd = if ($Command) { Get-Command $Command -ErrorAction SilentlyContinue }
    if ($cmd) { return $cmd.Source }
    foreach ($c in $Candidates) { $hit = Get-Item -Path (Join-Path $tools $c) -ErrorAction SilentlyContinue | Select-Object -Last 1; if ($hit) { return $hit.FullName } }
    return $null
}
function Get-Output([string] $Exe, [string[]] $Arguments) {
    if (-not $Exe) { return $null }
    $ErrorActionPreference = 'Continue'   # native stderr must not throw under 5.1
    try { return ((& $Exe @Arguments 2>&1) | ForEach-Object { "$_" }) -join "`n" } catch { return $null }
}
function Match([string] $Text, [string] $Pattern) { if ($Text -and $Text -match $Pattern) { return $Matches[1] } }
# Numeric part of a version string ('v0.5.4.1', '8.1-essentials', '2.11.0+cu128'), or $null.
function ConvertTo-Version([string] $s) {
    $m = Match $s '(\d+(?:\.\d+){1,3})'
    if ($m) { if ($m -notmatch '\.') { $m += '.0' }; return [version] $m }
}
function Invoke-Json([string] $Uri) {
    $headers = @{ 'User-Agent' = 'gsplats-check-updates' }
    if ($Uri -like 'https://api.github.com/*' -and $env:GITHUB_TOKEN) { $headers.Authorization = "Bearer $env:GITHUB_TOKEN" }
    try { return Invoke-RestMethod -Uri $Uri -Headers $headers -TimeoutSec 30 } catch { Write-Warning "$Uri : $($_.Exception.Message)"; return $null }
}
# Highest plain release tag (vX.Y.Z[.W], no -rc/-preview suffix) of a GitHub repository.
function Get-GitHubTag([string] $Repo) {
    $tags = Invoke-Json "https://api.github.com/repos/$Repo/tags?per_page=100"
    $tags | Where-Object { $_.name -match '^v?\d+(\.\d+){1,3}$' } | Sort-Object { ConvertTo-Version $_.name } | Select-Object -Last 1 -ExpandProperty name
}
function Get-GitHubRelease([string] $Repo) { (Invoke-Json "https://api.github.com/repos/$Repo/releases/latest").tag_name }
function Get-NpmLatest([string] $Package) { (Invoke-Json "https://registry.npmjs.org/$Package/latest").version }
function Get-PyPiLatest([string] $Package) { (Invoke-Json "https://pypi.org/pypi/$Package/json").info.version }

$rows = New-Object System.Collections.Generic.List[object]
function Add-Row([string] $Tool, [string] $Installed, [string] $Latest, [string] $Note = '') {
    $status = if (-not $Installed) { 'not found' }
              elseif (-not $Latest) { '?' }
              elseif ((ConvertTo-Version $Latest) -gt (ConvertTo-Version $Installed)) { 'UPDATE' }
              else { 'ok' }
    $rows.Add([pscustomobject]@{ Tool = $Tool; Installed = $Installed; Latest = $Latest; Status = $status; Note = $Note })
}

# LichtFeld ships v0.5+ Windows binaries only through its portal, so the latest is the newest tag.
$lfs = Find-Exe 'LICHTFELD_PATH' 'LichtFeld-Studio' @('lichtfeld\bin\LichtFeld-Studio.exe')
Add-Row 'LichtFeld Studio' (Match (Get-Output $lfs @('--version')) '(v\d[\d.]*)') (Get-GitHubTag 'MrNeRF/LichtFeld-Studio') 'rebuild: installers\build-lichtfeld.ps1 -Tag <tag>'

$colmap = Find-Exe 'COLMAP_PATH' 'colmap' @('colmap*\bin\colmap.exe')
Add-Row 'COLMAP' (Match (Get-Output $colmap @('version')) 'COLMAP (\d[\d.]*)') (Get-GitHubRelease 'colmap/colmap') 'colmap-x64-windows-cuda.zip'

$pwsh = Find-Exe $null $null @('pwsh\pwsh.exe'); if (-not $pwsh) { $pwsh = Find-Exe $null 'pwsh' @() }
Add-Row 'PowerShell 7' (Match (Get-Output $pwsh @('--version')) '(\d+\.\d+\.\d+)') (Get-GitHubRelease 'PowerShell/PowerShell')

$node = Find-Exe $null $null @('node\node.exe'); if (-not $node) { $node = Find-Exe $null 'node' @() }
$nodeInstalled = Match (Get-Output $node @('--version')) '(v\d+\.\d+\.\d+)'
$nodeLatest = $null
if ($nodeInstalled) {
    $major = $nodeInstalled.TrimStart('v').Split('.')[0]
    $nodeLatest = (Invoke-Json 'https://nodejs.org/dist/index.json') | Where-Object { $_.version -like "v$major.*" } | Select-Object -First 1 -ExpandProperty version
}
Add-Row 'Node.js' $nodeInstalled $nodeLatest 'same major line'

$ffmpeg = Find-Exe 'FFMPEG_PATH' 'ffmpeg' @()
$ffLatest = try { $c = (Invoke-WebRequest -UseBasicParsing -Uri 'https://www.gyan.dev/ffmpeg/builds/release-version' -TimeoutSec 30).Content; if ($c -is [byte[]]) { $c = [Text.Encoding]::ASCII.GetString($c) }; $c.Trim() } catch { $null }
Add-Row 'ffmpeg' (Match (Get-Output $ffmpeg @('-version')) 'ffmpeg version (\d[\d.]*)') $ffLatest 'gyan.dev release build'

# web-viewer dependencies, pinned in package.json.
$pkgPath = Join-Path $repo 'web-viewer\package.json'
if (Test-Path $pkgPath) {
    $pkg = Get-Content -Raw $pkgPath | ConvertFrom-Json
    foreach ($section in @($pkg.dependencies, $pkg.devDependencies)) {
        if (-not $section) { continue }
        foreach ($p in $section.PSObject.Properties) { Add-Row $p.Name ($p.Value -replace '^[\^~]', '') (Get-NpmLatest $p.Name) 'web-viewer' }
    }
}

# Optional person-masking venv (pipeline/tools/pyseg).
$py = Join-Path $tools 'pyseg\Scripts\python.exe'
if (Test-Path $py) {
    foreach ($p in @('ultralytics', 'torch')) {
        Add-Row $p (Match (Get-Output $py @('-m', 'pip', 'show', $p)) 'Version: (\S+)') (Get-PyPiLatest $p) 'pyseg venv'
    }
}

# Toolchain and driver: listed for context, not compared.
$nvcc = Find-Exe $null 'nvcc' @(); if (-not $nvcc) { $nvcc = Get-Item 'C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v*\bin\nvcc.exe' -ErrorAction SilentlyContinue | Select-Object -Last 1 -ExpandProperty FullName }
$rows.Add([pscustomobject]@{ Tool = 'CUDA toolkit'; Installed = (Match (Get-Output $nvcc @('--version')) 'release (\d[\d.]*)'); Latest = ''; Status = 'info'; Note = 'LichtFeld build only' })
$smi = Find-Exe $null 'nvidia-smi' @()
$rows.Add([pscustomobject]@{ Tool = 'NVIDIA driver'; Installed = "$(Get-Output $smi @('--query-gpu=driver_version', '--format=csv,noheader'))".Trim(); Latest = ''; Status = 'info'; Note = '' })

($rows | Format-Table -AutoSize | Out-String -Width 200).Trim() | Write-Host
$n = @($rows | Where-Object Status -eq 'UPDATE').Count
Write-Host ("{0} update(s) available. Checked {1}." -f $n, (Get-Date -Format 'yyyy-MM-dd'))
