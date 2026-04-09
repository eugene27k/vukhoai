@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "PS_SCRIPT=%SCRIPT_DIR%Scripts\get_or_build_windows_portable.ps1"

if not exist "%PS_SCRIPT%" (
  echo.
  echo Missing script: "%PS_SCRIPT%"
  echo.
  pause
  exit /b 1
)

echo.
echo Preparing Vukho.AI for Windows...
echo The script will try to download a ready build first and only compile locally if needed.
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" -OpenFolder
set "EXIT_CODE=%ERRORLEVEL%"

if not "%EXIT_CODE%"=="0" (
  echo.
  echo Build failed with exit code %EXIT_CODE%.
  echo.
  pause
  exit /b %EXIT_CODE%
)

exit /b 0
