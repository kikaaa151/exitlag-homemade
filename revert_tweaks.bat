@echo off
setlocal

set "STABILIZER_LAUNCHER=%~f0"
powershell.exe -NoProfile -Command "$identity = [Security.Principal.WindowsIdentity]::GetCurrent(); $principal = New-Object Security.Principal.WindowsPrincipal($identity); if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { exit 0 }; exit 1"
if %errorlevel% neq 0 (
    if /i "%~1"=="--elevated" (
        echo Administrator access was not granted. Run this file as administrator.
        pause
        exit /b 1
    )
    echo Requesting administrator privileges...
    powershell.exe -NoProfile -Command "try { Start-Process -FilePath $env:STABILIZER_LAUNCHER -ArgumentList '--elevated' -Verb RunAs -ErrorAction Stop } catch { Write-Host ('Could not start as administrator: ' + $_.Exception.Message); exit 1 }"
    if errorlevel 1 (
        echo Launch failed or the UAC prompt was cancelled.
        pause
        exit /b 1
    )
    exit /b 0
)

cd /d "%~dp0"
echo Reverting network tweaks left by older versions to Windows defaults...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_stabilizer.ps1" -Config "%~dp0config.json" -Revert
echo.
echo Done. Reboot once so the registry TCP changes take effect.
pause
endlocal
