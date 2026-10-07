@echo off
cd /d "%~dp0"
echo === Applying core multiplayer fixes ===
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0PZ-B42.21-Multiplayer-Patch.ps1" -Mode Apply -TargetVersion 42.21
if errorlevel 1 goto :fail
echo.
echo === Building local multiplayer compatibility overlay ===
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0PZ-B42.21-MP-Overlay.ps1" -Mode Apply -TargetVersion 42.21
if errorlevel 1 goto :fail
echo.
echo Apply completed successfully.
echo Run 03-Verify-Multiplayer.cmd next.
pause
exit /b 0
:fail
echo.
echo Apply stopped with an error. Review the message above.
echo No automatic checksum disabling or unsafe fallback was performed.
pause
exit /b 1
