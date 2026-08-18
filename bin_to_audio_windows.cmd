@echo off
setlocal

if "%~1"=="" (
  echo Drag a CD audio .bin file onto this .cmd file.
  echo.
  echo Command-line usage:
  echo   %~nx0 "D:\path\disc.bin" [flac^|wav]
  pause
  exit /b 1
)

set "AUDIO_FORMAT=%~2"
if "%AUDIO_FORMAT%"=="" set "AUDIO_FORMAT=flac"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0bin_to_audio_windows.ps1" -BinPath "%~1" -Format "%AUDIO_FORMAT%"
set "EXIT_CODE=%ERRORLEVEL%"

if not "%EXIT_CODE%"=="0" pause
exit /b %EXIT_CODE%
