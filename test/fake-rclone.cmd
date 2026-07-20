@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0fake-rclone.ps1" %*
exit /b %ERRORLEVEL%
