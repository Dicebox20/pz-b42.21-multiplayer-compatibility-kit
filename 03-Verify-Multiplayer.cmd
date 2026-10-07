@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Verify-PZ-B42.21-Multiplayer.ps1"
echo.
pause
