@echo off
setlocal

set "REPO_DIR=%~dp0"
pushd "%REPO_DIR%" >nul || exit /b 1

where flutter >nul 2>nul
if errorlevel 1 (
  echo flutter not found in PATH.
  popd >nul
  exit /b 1
)

for /f "delims=" %%I in ('where flutter') do (
  set "FLUTTER_BIN=%%~fI"
  goto :flutter_found
)

:flutter_found
for %%I in ("%FLUTTER_BIN%\..") do set "FLUTTER_BIN_DIR=%%~fI"
for %%I in ("%FLUTTER_BIN_DIR%\..") do set "FLUTTER_ROOT=%%~fI"

set "GIT_CONFIG_COUNT=2"
set "GIT_CONFIG_KEY_0=safe.directory"
set "GIT_CONFIG_VALUE_0=%FLUTTER_ROOT:\=/%"
set "GIT_CONFIG_KEY_1=safe.directory"
set "GIT_CONFIG_VALUE_1=%CD:\=/%"

call flutter pub get
if errorlevel 1 (
  popd >nul
  exit /b 1
)

call flutter build windows --release
if errorlevel 1 (
  popd >nul
  exit /b 1
)

echo Built build\windows\x64\runner\Release\kelivo.exe
popd >nul
exit /b 0
