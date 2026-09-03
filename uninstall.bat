@echo off
title Limits Watcher - uninstall
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Limits-Watcher.ps1" -UninstallStartup
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Limits-Watcher.ps1" -UninstallStatusline
echo.
pause
