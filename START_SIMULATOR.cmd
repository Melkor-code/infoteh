@echo off
setlocal
set "GODOT_EXE=%USERPROFILE%\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64.exe"
if not exist "%GODOT_EXE%" (
  echo Godot not found at the default location.
  echo Open project.godot with Godot 4.7, or drag Godot.exe onto this file.
  if "%~1"=="" (
    pause
    exit /b 1
  )
  set "GODOT_EXE=%~1"
)
"%GODOT_EXE%" --headless --path "%~dp0." --editor --import
if errorlevel 1 (
  echo Import failed. Please open project.godot in Godot to inspect errors.
  pause
  exit /b 1
)
start "" "%GODOT_EXE%" --path "%~dp0."
