@echo off
setlocal EnableExtensions
if not exist "%~dp0scripts\zephyr-manager.ps1" (
    echo [ERROR] Required helper script is missing:
    echo         "%~dp0scripts\zephyr-manager.ps1"
    echo Extract or copy the entire project folder, including scripts.
    echo Run the launcher from that complete folder.
    if not defined ZEPHYR_NO_PAUSE pause
    exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\zephyr-manager.ps1" -Mode Offline %*
set "RESULT=%ERRORLEVEL%"
if not defined ZEPHYR_NO_PAUSE pause
exit /b %RESULT%
