@echo off
title Limits Watcher - install
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%~dp0Limits-Watcher.ps1" (
  echo Limits-Watcher.ps1 not found next to this file.
  pause
  exit /b 1
)
"%PS%" -NoProfile -ExecutionPolicy Bypass -Command "Unblock-File -LiteralPath '%~dp0Limits-Watcher.ps1' -ErrorAction SilentlyContinue"
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Limits-Watcher.ps1" -Setup
echo.
pause
