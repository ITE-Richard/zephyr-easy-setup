@echo off
setlocal EnableExtensions
REM Legacy: [BOARD] [BOARD_QUALIFIER] [SDK_TOOLCHAIN] [ZEPHYR_REVISION]
REM Named: -InstallDir D:\zephyr [-Board BOARD] [-Toolchain TOOLCHAIN] [-CheckOnly]
if not exist "%~dp0scripts\zephyr-manager.ps1" (
    echo [ERROR] Required helper script is missing:
    echo         "%~dp0scripts\zephyr-manager.ps1"
    echo Extract or copy the entire project folder, including scripts.
    echo Run the launcher from that complete folder.
    if not defined ZEPHYR_NO_PAUSE pause
    exit /b 1
)
if /i "%~1"=="-InstallDir" goto NamedArguments
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\zephyr-manager.ps1" -Mode Online -Board "%~1" -Qualifier "%~2" -Toolchain "%~3" -Revision "%~4"
goto Finished

:NamedArguments
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\zephyr-manager.ps1" -Mode Online %*

:Finished
set "RESULT=%ERRORLEVEL%"
if not defined ZEPHYR_NO_PAUSE pause
exit /b %RESULT%
