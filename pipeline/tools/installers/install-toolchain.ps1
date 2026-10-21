#requires -Version 5.1
# Installs the machine-wide toolchain for building LichtFeld Studio from source (run elevated):
# VS 2022 Build Tools (C++ workload + Clang), CUDA 12.8 toolkit only (no display driver), CMake,
# Ninja, Git, and LongPathsEnabled. Mirrors upstream .github/workflows/windows.yml. No cuDNN.
#
#   powershell -ExecutionPolicy Bypass -File pipeline\tools\installers\install-toolchain.ps1
#
# Then run build-lichtfeld.ps1 (not elevated). Skip all of this if you install a LichtFeld
# Studio binary instead.
[CmdletBinding()]
param(
    [string] $CudaInstallerUrl = 'https://developer.download.nvidia.com/compute/cuda/12.8.0/local_installers/cuda_12.8.0_571.96_windows.exe'
)
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$log  = Join-Path $root 'install-toolchain.log'
function Log($m) { $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m; Add-Content -Path $log -Value $line; Write-Host $line }
$elevated = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')
if (-not $elevated) { throw 'Run this script from an elevated (Administrator) PowerShell.' }
Start-Transcript -Path (Join-Path $root 'install-toolchain.transcript.txt') -Append | Out-Null
Log '=== start ==='

# 1. Long paths (vcpkg buildtrees get deep)
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -Value 1 -Type DWord
Log "LongPathsEnabled = $((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem').LongPathsEnabled)"

# 2. Visual Studio 2022 Build Tools: Desktop C++ workload (recommended set incl. Windows SDK) + Clang compiler + LLVM toolset
Log "Installing VS 2022 Build Tools..."
$vsArgs = '--quiet --wait --norestart --nocache --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended --add Microsoft.VisualStudio.Component.VC.Llvm.Clang --add Microsoft.VisualStudio.Component.VC.Llvm.ClangToolset'
winget install --id Microsoft.VisualStudio.2022.BuildTools --exact --accept-source-agreements --accept-package-agreements --disable-interactivity --override $vsArgs 2>&1 | ForEach-Object { Log $_ }
Log "winget VS exit: $LASTEXITCODE"
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (Test-Path $vswhere) {
    $vsPath = & $vswhere -products '*' -latest -property installationPath
    Log "VS installationPath: $vsPath"
    if ($vsPath -and -not (Test-Path (Join-Path $vsPath 'VC\Tools\Llvm\x64\bin\clang-cl.exe'))) {
        Log "clang-cl missing; running vs_installer modify to add components..."
        $vsInstaller = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vs_installer.exe"
        Start-Process -FilePath $vsInstaller -ArgumentList "modify --installPath `"$vsPath`" $vsArgs" -Wait -NoNewWindow
        Log "vs_installer modify exit: $LASTEXITCODE"
    }
} else { Log "WARNING: vswhere not found after VS install" }

# 3. CMake, Ninja, Git (machine scope)
foreach ($id in 'Kitware.CMake', 'Ninja-build.Ninja', 'Git.Git') {
    Log "Installing $id..."
    winget install --id $id --exact --scope machine --accept-source-agreements --accept-package-agreements --disable-interactivity 2>&1 | ForEach-Object { Log $_ }
    Log "winget $id exit: $LASTEXITCODE"
}

# 4. CUDA 12.8 toolkit only. -noDisplayDriver keeps the installed NVIDIA driver, which only has
#    to be at least as new as the toolkit's (571.96 for 12.8.0).
$nvcc = 'C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v12.8\bin\nvcc.exe'
if (Test-Path $nvcc) {
    Log "CUDA 12.8 already installed"
} else {
    $cudaExe = Join-Path $root (Split-Path -Leaf $CudaInstallerUrl)
    if (-not (Test-Path $cudaExe) -or (Get-Item $cudaExe).Length -lt 2000000000) {
        Log "Downloading $CudaInstallerUrl (about 3.4 GB)..."
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $CudaInstallerUrl -OutFile $cudaExe
    }
    Log "Running CUDA installer silently (-toolkit -noDisplayDriver)..."
    $p = Start-Process -FilePath $cudaExe -ArgumentList '-y -s -accepteula -toolkit -override -noDisplayDriver' -Wait -PassThru
    Log "CUDA installer exit: $($p.ExitCode)"
}
if (Test-Path $nvcc) { Log ("nvcc: " + ((& $nvcc --version) -join ' ')) } else { Log "ERROR: nvcc not found at $nvcc" }

Log "=== done ==="
Stop-Transcript | Out-Null
