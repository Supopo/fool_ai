@echo off
chcp 65001 >nul
setlocal
title Package Android APK
cd /d "%~dp0.."
echo.
echo Starting Android APK package script. Do not close this window.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0package_android.ps1" %*
set ERR=%ERRORLEVEL%
echo.
if %ERR% neq 0 (
  echo Package script exited with error code %ERR%.
) else (
  echo Package script finished.
)
echo.
pause
exit /b %ERR%
