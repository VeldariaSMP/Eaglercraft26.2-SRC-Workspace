@echo off
setlocal
set "SCRIPT=%~dp0launch-gui-windows-x86_64.ps1"
if not exist "%SCRIPT%" (
  echo ERROR: Windows launcher script is missing: "%SCRIPT%" 1>&2
  exit /b 2
)
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
exit /b %ERRORLEVEL%
