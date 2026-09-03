@echo off
title AI Limit Monitor - uninstall
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0AI-Limit-Monitor.ps1" -UninstallStartup
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0AI-Limit-Monitor.ps1" -UninstallStatusline
echo.
pause
