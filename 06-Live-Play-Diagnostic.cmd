@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Live-PZ-B42.21-Module-Diagnostic.ps1"
echo.
pause
