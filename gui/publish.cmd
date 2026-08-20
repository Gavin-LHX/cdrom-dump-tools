@echo off
setlocal EnableExtensions

set "GUI_ROOT=%~dp0"
set "GUI_PROJECT=%GUI_ROOT%CdromDumpToolsGui\CdromDumpToolsGui.csproj"
set "PUBLISH_DIR=%GUI_ROOT%publish\win-x64"

where dotnet.exe >nul 2>nul
if errorlevel 1 (
  echo [ERROR] .NET 8 SDK was not found on PATH.
  echo Download it from https://dotnet.microsoft.com/download/dotnet/8.0
  exit /b 1
)

dotnet.exe --list-sdks | findstr.exe /r /b /c:"8\.0\." >nul
if errorlevel 1 (
  echo [ERROR] .NET 8 SDK is required. Installed SDKs:
  dotnet.exe --list-sdks
  exit /b 1
)

if not exist "%GUI_PROJECT%" (
  echo [ERROR] Project not found: "%GUI_PROJECT%"
  exit /b 1
)

pushd "%GUI_ROOT%" || exit /b 1
if exist "%PUBLISH_DIR%" rmdir /s /q "%PUBLISH_DIR%"
if exist "%PUBLISH_DIR%" (
  echo [ERROR] Could not clean publish directory: "%PUBLISH_DIR%"
  popd
  exit /b 1
)

dotnet.exe publish "%GUI_PROJECT%" ^
  --configuration Release ^
  --runtime win-x64 ^
  --self-contained false ^
  --output "%PUBLISH_DIR%" ^
  -p:DebugSymbols=false ^
  -p:DebugType=None
if errorlevel 1 goto :failed

echo.
echo Publish completed successfully.
echo Output: "%PUBLISH_DIR%"
echo This framework-dependent build requires the .NET 8 Desktop Runtime x64.
popd
exit /b 0

:failed
set "EXIT_CODE=%ERRORLEVEL%"
popd
exit /b %EXIT_CODE%
