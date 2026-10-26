@echo off
chcp 65001 >nul
title WeNet temporary route helper
setlocal

net session >nul 2>&1
if errorlevel 1 (
    echo.
    echo [ERROR] This script must be run as Administrator.
    echo Right-click the file and choose "Run as administrator".
    echo.
    pause
    exit /b 1
)

echo.
echo Adding temporary route: 10.112.0.0/16 via campus WiFi gateway 10.111.0.1 ...
route add 10.112.0.0 mask 255.255.0.0 10.111.0.1 metric 1 >nul 2>&1
if errorlevel 1 (
    echo First attempt failed, retrying with explicit interface ...
    route add 10.112.0.0 mask 255.255.0.0 10.111.0.1 if 9 metric 1 >nul 2>&1
)

echo.
echo Current 10.112.x.x routes:
route print -4 | findstr /C:"10.112"
echo.
echo --- Testing portal 10.112.0.10:80 ---
powershell -NoProfile -Command "try { $r = Invoke-WebRequest -Uri 'http://10.112.0.10/' -UseBasicParsing -TimeoutSec 5; Write-Host ('OK, HTTP ' + $r.StatusCode + ', ' + $r.Content.Length + ' bytes') } catch { Write-Host ('FAILED: ' + $_.Exception.Message) }"
echo.
echo If you see OK above, tell the assistant; you can close this window.
echo (The route disappears automatically after reboot.)
pause
