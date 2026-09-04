@echo off
setlocal

:: Check for admin rights and self-elevate if needed
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"
echo Running Game Connection Stabilizer...
powershell -ExecutionPolicy Bypass -File run_stabilizer.ps1 -Config config.json
pause
endlocal
