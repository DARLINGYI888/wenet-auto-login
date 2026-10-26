@echo off
cd /d "%~dp0"
echo Removing WeNet auto-login scheduled task...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall_task.ps1"
