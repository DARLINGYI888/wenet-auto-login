@echo off
chcp 65001 >nul
title WeNet Auto Login Console
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\menu.ps1"
if errorlevel 1 pause
