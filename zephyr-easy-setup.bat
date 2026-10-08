@echo off
setlocal EnableExtensions
REM Usage: zephyr-easy-setup.bat [BOARD] [BOARD_QUALIFIER] [SDK_TOOLCHAIN] [ZEPHYR_REVISION]
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\zephyr-manager.ps1" -Mode Online -Board "%~1" -Qualifier "%~2" -Toolchain "%~3" -Revision "%~4"
set "RESULT=%ERRORLEVEL%"
if not defined ZEPHYR_NO_PAUSE pause
exit /b %RESULT%
