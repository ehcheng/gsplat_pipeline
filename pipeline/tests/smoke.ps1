#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'run.ps1'
$pwsh = (Get-Process -Id $PID).Path   # the PowerShell 7 running this test; pwsh need not be on PATH
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | ForEach-Object Message | Out-String) }

$help = & $pwsh -NoProfile -File $scriptPath -? 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { throw 'run.ps1 help invocation failed.' }
foreach ($name in @('Scene','Fps','CameraModel','Lens','Stage','Force')) {
    if (-not $help.Contains($name)) { throw "Help output is missing parameter $name" }
}
Write-Host 'PASS: run.ps1 parses and exposes the required contract.'

# --- Unit checks on the lens table and the cameras.bin reader, lifted out of run.ps1 by AST ---
$functions = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)
foreach ($name in @('Convert-LensToModel', 'Get-ColmapCameraModels', 'Write-Json')) {
    $definition = $functions | Where-Object Name -eq $name | Select-Object -First 1
    if (-not $definition) { throw "run.ps1 no longer defines $name" }
    . ([ScriptBlock]::Create($definition.Extent.Text))
}
$tableAssignment = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$script:LensTable' }, $true) | Select-Object -First 1
if (-not $tableAssignment) { throw 'run.ps1 no longer defines $script:LensTable' }
. ([ScriptBlock]::Create($tableAssignment.Extent.Text))

$expected = @{ linear='OPENCV'; 'linear-hl'='OPENCV'; narrow='OPENCV'; pinhole='OPENCV'; wide='OPENCV_FISHEYE'; fisheye='OPENCV_FISHEYE' }
foreach ($lens in $expected.Keys) {
    $model = (Convert-LensToModel $lens 'test').Model
    if ($model -ne $expected[$lens]) { throw "Lens $lens mapped to $model, expected $($expected[$lens])" }
}
foreach ($lens in @('superview', 'hyperview')) {
    $threw = $false
    try { Convert-LensToModel $lens 'test' | Out-Null } catch { $threw = $_.Exception.Message -match 'cannot be reconstructed' }
    if (-not $threw) { throw "Lens $lens must be rejected" }
}
$threw = $false
try { Convert-LensToModel 'gopro-magic' 'test' | Out-Null } catch { $threw = $_.Exception.Message -match 'Unknown lens' }
if (-not $threw) { throw 'Unknown lens names must be rejected' }
Write-Host 'PASS: lens table maps Linear-family to OPENCV, Wide/fisheye to OPENCV_FISHEYE, rejects SuperView/HyperView.'

# Synthesize a cameras.bin with one OPENCV camera (id 4, 8 params) and one OPENCV_FISHEYE camera (id 5).
$stream = [IO.MemoryStream]::new()
$writer = [IO.BinaryWriter]::new($stream)
$writer.Write([uint64]2)
foreach ($modelId in @(4, 5)) {
    $writer.Write([int32]$modelId); $writer.Write([int32]$modelId)
    $writer.Write([uint64]5568); $writer.Write([uint64]4176)
    for ($p = 0; $p -lt 8; $p++) { $writer.Write([double](0.5 * $p)) }
}
$writer.Flush()
$camerasBin = Join-Path ([IO.Path]::GetTempPath()) ("smoke-cameras-{0}.bin" -f [guid]::NewGuid())
[IO.File]::WriteAllBytes($camerasBin, $stream.ToArray())
try {
    $models = @(Get-ColmapCameraModels $camerasBin)
    if (($models -join ',') -ne 'OPENCV,OPENCV_FISHEYE') { throw "cameras.bin reader returned $($models -join ',')" }
} finally { Remove-Item -LiteralPath $camerasBin -Force -ErrorAction SilentlyContinue }
Write-Host 'PASS: cameras.bin reader decodes COLMAP camera model ids.'

# --- Tool discovery: an environment variable overrides the default name; a missing tool says how to fix it ---
$resolver = $functions | Where-Object Name -eq 'Resolve-Executable' | Select-Object -First 1
if (-not $resolver) { throw 'run.ps1 no longer defines Resolve-Executable' }
# Lifted out of run.ps1, $PSScriptRoot would be empty, so point it at a throwaway pipeline folder.
$fakePipeline = Join-Path ([IO.Path]::GetTempPath()) ("gsplat-smoke-tools-{0}" -f [guid]::NewGuid())
. ([ScriptBlock]::Create($resolver.Extent.Text.Replace('$PSScriptRoot', "'$fakePipeline'")))
$fakeTool = Join-Path $fakePipeline 'elsewhere\LichtFeld-Studio.exe'
$fakeColmap = Join-Path $fakePipeline 'tools\colmap-9.9.9\bin\colmap.exe'
foreach ($file in @($fakeTool, $fakeColmap)) { New-Item -ItemType File -Path $file -Force | Out-Null }
$savedPath = $env:LICHTFELD_PATH
try {
    $env:LICHTFELD_PATH = $fakeTool
    if ((Resolve-Executable 'LichtFeld-Studio' 'LichtFeld Studio') -ne $fakeTool) { throw 'LICHTFELD_PATH was not honoured.' }
    $env:LICHTFELD_PATH = $null
    $threw = $false
    try { Resolve-Executable 'no-such-tool-gsplat' 'LichtFeld Studio' | Out-Null } catch { $threw = $_.Exception.Message -match 'LICHTFELD_PATH' }
    if (-not $threw) { throw 'A missing LichtFeld must fail with a hint about LICHTFELD_PATH.' }
    if (-not (Get-Command colmap -ErrorAction SilentlyContinue) -and -not $env:COLMAP_PATH) {
        if ((Resolve-Executable 'colmap' 'COLMAP') -ne $fakeColmap) { throw 'COLMAP under pipeline\tools\colmap*\bin was not found.' }
    }
} finally {
    $env:LICHTFELD_PATH = $savedPath
    Remove-Item -LiteralPath $fakePipeline -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host 'PASS: tool discovery honours LICHTFELD_PATH, finds tools under pipeline\tools and explains a missing tool.'

# --- End-to-end lens resolution against a throwaway scene (no images, no GPU, no external tools) ---
$root = Join-Path ([IO.Path]::GetTempPath()) ("gsplat-smoke-{0}" -f [guid]::NewGuid())
New-Item -ItemType Directory -Path $root -Force | Out-Null
function Invoke-Run([string[]] $Arguments) {
    $output = & $pwsh -NoProfile -File $scriptPath -Root $root @Arguments 2>&1 | ForEach-Object { $_.ToString() }
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
}
try {
    $r = Invoke-Run @('-Scene', 'nolens', '-Stage', 'sfm')
    if ($r.ExitCode -eq 0 -or $r.Output -notmatch 'Lens mode is unknown') { throw "Expected a clear 'lens unknown' failure. Got exit $($r.ExitCode):`n$($r.Output)" }

    $r = Invoke-Run @('-Scene', 'nolens', '-Stage', 'export')
    if ($r.Output -match 'Lens mode is unknown') { throw "Lens must not be required for the export stage.`n$($r.Output)" }

    $r = Invoke-Run @('-Scene', 'stretch', '-Stage', 'sfm', '-Lens', 'superview')
    if ($r.ExitCode -eq 0 -or $r.Output -notmatch 'cannot be reconstructed') { throw "SuperView must be rejected before any work starts.`n$($r.Output)" }

    $r = Invoke-Run @('-Scene', 'flagged', '-Stage', 'sfm', '-Lens', 'wide')
    if ($r.Output -notmatch 'LENS wide .*OPENCV_FISHEYE.*source=parameter -Lens') { throw "Lens resolution from -Lens was not logged.`n$($r.Output)" }
    if ($r.Output -notmatch 'No camera image folders') { throw "Empty scene should fail at extract, after lens resolution.`n$($r.Output)" }
    $manifest = Get-Content -LiteralPath (Join-Path $root 'flagged\capture.json') -Raw | ConvertFrom-Json
    if ($manifest.lens -ne 'wide' -or $manifest.cameraModel -ne 'OPENCV_FISHEYE') { throw 'capture.json was not persisted from -Lens.' }

    $r = Invoke-Run @('-Scene', 'flagged', '-Stage', 'sfm')
    if ($r.Output -notmatch 'LENS wide .*source=capture\.json') { throw "Lens was not re-read from capture.json on a stage-only rerun.`n$($r.Output)" }

    $r = Invoke-Run @('-Scene', 'flagged', '-Stage', 'sfm', '-Lens', 'linear')
    if ($r.ExitCode -eq 0 -or $r.Output -notmatch 'Pass -Force to rebuild') { throw "Conflicting -Lens vs capture.json must fail without -Force.`n$($r.Output)" }

    $r = Invoke-Run @('-Scene', 'flagged', '-Stage', 'sfm', '-Lens', 'wide', '-CameraModel', 'OPENCV')
    if ($r.ExitCode -eq 0 -or $r.Output -notmatch 'Pass one or the other') { throw "Contradictory -Lens and -CameraModel must fail.`n$($r.Output)" }

    $manifestScene = Join-Path $root 'manifested'
    New-Item -ItemType Directory -Path $manifestScene -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $manifestScene 'capture.json') -Value '{ "lens": "linear-hl", "notes": "HERO12 x3, Linear + Horizon Lock" }' -Encoding utf8
    $r = Invoke-Run @('-Scene', 'manifested', '-Stage', 'sfm')
    if ($r.Output -notmatch 'LENS linear-hl .*OPENCV.*source=capture\.json') { throw "Lens was not read from a hand-written capture.json.`n$($r.Output)" }

    Set-Content -LiteralPath (Join-Path $manifestScene 'capture.json') -Value '{ "lens": "wide", "cameras": { "cam1": { "lens": "linear" } } }' -Encoding utf8
    $r = Invoke-Run @('-Scene', 'manifested', '-Stage', 'sfm')
    if ($r.ExitCode -eq 0 -or $r.Output -notmatch 'Mixed lens modes') { throw "Mixed per-camera lens modes must be rejected.`n$($r.Output)" }
    Write-Host 'PASS: lens resolution order, persistence, conflicts, and stage gating behave as documented.'
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
