@echo off
setlocal EnableExtensions
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\zephyr-manager.ps1" -Mode Shell
set "RESULT=%ERRORLEVEL%"
if not "%RESULT%"=="0" if not defined ZEPHYR_NO_PAUSE pause
exit /b %RESULT%
