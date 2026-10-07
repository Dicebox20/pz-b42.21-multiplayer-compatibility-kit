@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0PZ-B42-Mod-Diagnostic-v4.ps1" -TargetVersion 42.21 -OpenReport
echo.
pause
