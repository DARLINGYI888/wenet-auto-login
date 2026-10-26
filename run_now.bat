@echo off
cd /d "%~dp0"
echo Running WeNet auto login (normal mode, will kick one device if needed)...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0wenet_auto.ps1" -Force
echo.
pause
