@echo off
cd /d "%~dp0"
echo Installing WeNet auto-login scheduled task...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_task.ps1"
