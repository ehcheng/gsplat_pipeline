#requires -Version 5.1
# Builds LichtFeld Studio from source into pipeline/tools/lichtfeld (portable layout), which is
# where run.ps1 and reconstruct.ps1 look for it. Mirrors upstream .github/workflows/nightly.yml
# (build-windows job). Needs the toolchain from install-toolchain.ps1 and git on PATH.
#
#   powershell -ExecutionPolicy Bypass -File pipeline\tools\installers\build-lichtfeld.ps1 [-Tag v0.5.4.1] [-InstallDir <dir>] [-Reconfigure]
#
# First run: clones the tagged source (with submodules) to pipeline/tools/lichtfeld-src and
# vcpkg to pipeline/tools/vcpkg, then configures (about 50 min: vcpkg builds ~90 dependency
# ports) and compiles (about 20 min on 64 threads). An existing clean source clone is switched
# to -Tag; later builds reuse the build folder and vcpkg's cache, so an upgrade with an
# unchanged vcpkg baseline is mostly compile time. -InstallDir installs somewhere other than
# pipeline/tools/lichtfeld, to test a new version next to the current one (LICHTFELD_PATH).
[CmdletBinding()]
param(
    [string] $Tag = 'v0.5.4.1',
    [string] $RepoUrl = 'https://github.com/MrNeRF/LichtFeld-Studio.git',
    [string] $InstallDir,
    [switch] $Reconfigure,
    [string] $CudaPath = 'C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v12.8'
)
$ErrorActionPreference = 'Stop'
$tools   = Split-Path -Parent $PSScriptRoot
$src     = Join-Path $tools 'lichtfeld-src'
$build   = Join-Path $src 'build'
$dist    = if ($InstallDir) { [IO.Path]::GetFullPath($InstallDir) } else { Join-Path $tools 'lichtfeld' }
$vcpkg   = Join-Path $tools 'vcpkg'
$log     = Join-Path $PSScriptRoot 'build-lichtfeld.log'
# A log file another program holds open (an editor, a tail) must not stop an hour-long build.
function Log($m) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
    try { Add-Content -Path $log -Value $line -ErrorAction Stop } catch { Write-Warning "could not write $log ($($_.Exception.Message))" }
    Write-Host $line
}
function Invoke-Git([string[]] $Arguments) {
    & git @Arguments
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed (exit $LASTEXITCODE)" }
}

$vsInstallerDir = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer"
$vswhere = Join-Path $vsInstallerDir 'vswhere.exe'
if (-not (Test-Path $vswhere)) { throw 'Visual Studio Installer not found. Run install-toolchain.ps1 first.' }
$vsPath  = & $vswhere -products '*' -latest -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsPath) { throw 'No Visual Studio 2022 with C++ tools found. Run install-toolchain.ps1 first.' }
$vcvars = Join-Path $vsPath 'VC\Auxiliary\Build\vcvars64.bat'
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'git is not on PATH (winget install Git.Git).' }

# Source and vcpkg, fetched once.
if (-not (Test-Path (Join-Path $src 'CMakeLists.txt'))) {
    Log "Cloning $RepoUrl at $Tag into $src"
    Invoke-Git @('clone', '--branch', $Tag, '--recurse-submodules', $RepoUrl, $src)
} else {
    $current = (& git -C $src describe --tags 2>$null)
    if ($current -ne $Tag) {
        if (& git -C $src status --porcelain) { throw "$src is at '$current' with local changes; commit, stash or delete them before switching to $Tag." }
        Log "Switching $src from '$current' to $Tag"
        Invoke-Git @('-C', $src, 'fetch', '--tags', 'origin')
        Invoke-Git @('-C', $src, 'checkout', '--detach', $Tag)
        Invoke-Git @('-C', $src, 'submodule', 'update', '--init', '--recursive')
    }
}
if (-not (Test-Path (Join-Path $vcpkg 'vcpkg.exe'))) {
    if (-not (Test-Path (Join-Path $vcpkg '.git'))) {
        Log "Cloning vcpkg into $vcpkg"
        Invoke-Git @('clone', 'https://github.com/microsoft/vcpkg.git', $vcpkg)
    }
    Log 'Bootstrapping vcpkg'
    & (Join-Path $vcpkg 'bootstrap-vcpkg.bat') -disableMetrics
    if ($LASTEXITCODE -ne 0) { throw "vcpkg bootstrap failed (exit $LASTEXITCODE)" }
}
foreach ($p in @($vcvars, (Join-Path $CudaPath 'bin\nvcc.exe'), (Join-Path $vcpkg 'vcpkg.exe'))) { if (-not (Test-Path $p)) { throw "Missing prerequisite: $p" } }

$env:VCPKG_ROOT       = $vcpkg
$env:VCPKG_BUILD_TYPE = 'release'
$env:CUDA_PATH        = $CudaPath
$env:CUDA_PATH_V12_8  = $CudaPath
# vcvars64.bat needs the Visual Studio Installer folder on PATH to find vswhere.
$env:PATH             = "$CudaPath\bin;$CudaPath\libnvvp;C:\Program Files\CMake\bin;C:\Program Files\WinGet\Links;$vsInstallerDir;$env:PATH"
$jobs = [Environment]::ProcessorCount

# Run a command inside the MSVC x64 environment (cmd-level, so PowerShell 5.1 never sees native
# stderr and cannot promote it to a terminating error).
function Invoke-VcStep([string] $Name, [string] $Command) {
    Log "$Name`: $Command"
    $stepCmd = "call `"$vcvars`" >nul 2>&1 && $Command"
    $proc = Start-Process -FilePath $env:ComSpec -ArgumentList @('/d','/s','/c', "`"$stepCmd`"") -WorkingDirectory $src -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ne 0) { throw "$Name failed (exit $($proc.ExitCode)); see the console output above" }
    Log "$Name OK"
}

Log "=== build start: tag=$Tag vs=$vsPath cuda=$CudaPath vcpkg=$vcpkg jobs=$jobs ==="
try {
    if ($Reconfigure -and (Test-Path $build)) { Log 'Removing existing build dir'; Remove-Item -Recurse -Force $build }

    Invoke-VcStep 'Configure' 'cmake -B build -S . -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_PORTABLE=ON -DBUILD_PYTHON_STUBS=OFF'
    Invoke-VcStep 'Build' "cmake --build build -j $jobs"

    if (Test-Path $dist) { Log "Removing previous install at $dist"; Remove-Item -Recurse -Force $dist }
    Invoke-VcStep 'Install' "cmake --install build --prefix `"$dist`""

    $exe = Get-ChildItem -Path $dist -Recurse -Filter 'LichtFeld-Studio.exe' | Select-Object -First 1
    if (-not $exe) { throw "LichtFeld-Studio.exe not found under $dist" }
    Log "Installed: $($exe.FullName)"
    Log '=== build done ==='
} catch {
    Log "FAILED: $($_.Exception.Message)"
    exit 1
}
