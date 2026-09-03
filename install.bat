@echo off
title AI Limit Monitor - install
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%~dp0AI-Limit-Monitor.ps1" (
  echo AI-Limit-Monitor.ps1 not found next to this file.
  pause
  exit /b 1
)
"%PS%" -NoProfile -ExecutionPolicy Bypass -Command "Unblock-File -LiteralPath '%~dp0AI-Limit-Monitor.ps1' -ErrorAction SilentlyContinue"
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0AI-Limit-Monitor.ps1" -Setup
echo.
pause
