@echo off
chcp 65001 >nul
title PalRelay setup
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1"
echo.
pause
