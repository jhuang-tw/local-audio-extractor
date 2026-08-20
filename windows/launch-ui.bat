@echo off
setlocal
set "UI=%~dp0local-audio-extractor.ps1"

if not exist "%UI%" (
  echo ERROR: UI script not found: %UI%
  exit /b 1
)

if "%~1"=="" (
  powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%UI%"
) else (
  powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%UI%" -InputPath "%~f1"
)

exit /b %ERRORLEVEL%
