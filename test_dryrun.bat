@echo off
cd /d "%~dp0"
echo Dry run: only checks status and shows which device would be kicked (no real action)...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0wenet_auto.ps1" -DryRun
echo.
pause
