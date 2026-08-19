@echo off
rem Builds the CD-ROM Dump Tools GUI as a framework-dependent win-x64 app.
rem Requires the .NET 8 SDK. The built exe lives in:
rem   CdromDumpToolsGui\bin\Release\net8.0-windows\win-x64\
setlocal

where dotnet >nul 2>nul
if errorlevel 1 (
  echo .NET SDK 8 was not found on PATH. Install it from https://dotnet.microsoft.com/download
  exit /b 1
)

pushd "%~dp0"
dotnet publish CdromDumpToolsGui\CdromDumpToolsGui.csproj -c Release -r win-x64 --self-contained false
set "EXIT_CODE=%ERRORLEVEL%"
popd
exit /b %EXIT_CODE%
