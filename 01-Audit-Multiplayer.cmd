@echo off
cd /d "%~dp0"
echo === Core multiplayer audit ===
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0PZ-B42.21-Multiplayer-Patch.ps1" -Mode Audit -TargetVersion 42.21
set CORE_RC=%ERRORLEVEL%
echo.
echo === Overlay audit ===
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0PZ-B42.21-MP-Overlay.ps1" -Mode Audit -TargetVersion 42.21
set OVERLAY_RC=%ERRORLEVEL%
echo.
echo Core audit exit: %CORE_RC%
echo Overlay audit exit: %OVERLAY_RC%
pause
