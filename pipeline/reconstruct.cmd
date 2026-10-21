@echo off
rem Single-command reconstruction: reconstruct.cmd <scene folder> [-Lens wide|linear] [-Iterations N] [-MaxCap N] [-Force] [-DryRun]
rem Uses the portable PowerShell 7 under tools\pwsh when present, else pwsh on PATH, so it works
rem from cmd, Windows PowerShell 5.1, or Explorer.
set "PWSH=%~dp0tools\pwsh\pwsh.exe"
if not exist "%PWSH%" set "PWSH=pwsh"
"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0reconstruct.ps1" %*
exit /b %ERRORLEVEL%
