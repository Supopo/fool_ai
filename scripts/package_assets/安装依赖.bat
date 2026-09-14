@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"
title 安装依赖 - 智慧饼
echo.
echo ========================================
echo   安装 WebView2 运行时
echo ========================================
echo.
if not exist "MicrosoftEdgeWebView2Setup.exe" (
  echo 错误：找不到 MicrosoftEdgeWebView2Setup.exe
  pause
  exit /b 1
)
echo 正在安装 WebView2（需要联网）...
MicrosoftEdgeWebView2Setup.exe
echo.
echo 完成。VC++ 运行库 DLL 已在本目录中。
echo 现在可以双击「智慧饼.exe」启动。
echo.
pause