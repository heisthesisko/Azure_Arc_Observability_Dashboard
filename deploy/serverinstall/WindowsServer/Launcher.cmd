@echo off
setlocal
where pwsh >nul 2>nul
if errorlevel 1 (
  echo PowerShell 7 is required. Install it from https://aka.ms/powershell-release?tag=stable
  pause
  exit /b 1
)
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Dashboard.ps1"
