@echo off
cd /d "%~dp0"
echo === Restoring compatibility overlay ===
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0PZ-B42.21-MP-Overlay.ps1" -Mode Restore -TargetVersion 42.21
set OVERLAY_RC=%ERRORLEVEL%
echo.
echo === Restoring core multiplayer patch ===
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0PZ-B42.21-Multiplayer-Patch.ps1" -Mode Restore -TargetVersion 42.21
set CORE_RC=%ERRORLEVEL%
echo.
echo Overlay restore exit: %OVERLAY_RC%
echo Core restore exit: %CORE_RC%
pause
