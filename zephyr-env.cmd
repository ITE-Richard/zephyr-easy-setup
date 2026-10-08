@echo off
setlocal EnableExtensions
title Zephyr RTOS Development Shell

set "ROOT_DIR=%~dp0"
set "WORKSPACE_ROOT=%ROOT_DIR%zephyrproject"

for /f "tokens=1,2" %%A in ("%WORKSPACE_ROOT%") do if not "%%B"=="" (
    echo ============================================================
    echo [ERROR] Space detected in workspace path:
    echo         "%WORKSPACE_ROOT%"
    echo ============================================================
    echo Zephyr RTOS, CMake, and Kconfig do NOT support paths with spaces.
    echo Please move this project to a path without spaces.
    echo.
    pause
    exit /b 1
)

if not exist "%WORKSPACE_ROOT%\.venv\Scripts\activate.bat" (
    echo ============================================================
    echo [ERROR] Zephyr virtual environment not found!
    echo         Expected at: %WORKSPACE_ROOT%\.venv
    echo ============================================================
    echo.
    echo Please run 'zephyr-easy-setup.bat' first to initialize the environment.
    echo.
    pause
    exit /b 1
)

echo ============================================================
echo   Zephyr RTOS Development Environment
echo ============================================================
echo Workspace Directory: %WORKSPACE_ROOT%

REM Check and locate Zephyr SDK
if not defined ZEPHYR_SDK_INSTALL_DIR (
    for /d %%D in ("%WORKSPACE_ROOT%\zephyr-sdk-*") do (
        set "ZEPHYR_SDK_INSTALL_DIR=%%~fD"
    )
)
if not defined ZEPHYR_TOOLCHAIN_VARIANT (
    set "ZEPHYR_TOOLCHAIN_VARIANT=zephyr"
)

if defined ZEPHYR_SDK_INSTALL_DIR (
    echo SDK Directory:      %ZEPHYR_SDK_INSTALL_DIR%
) else (
    echo SDK Directory:      [Auto-detect via CMake / west]
)
echo Toolchain Variant:  %ZEPHYR_TOOLCHAIN_VARIANT%
echo.

REM Activate Python Virtual Environment
call "%WORKSPACE_ROOT%\.venv\Scripts\activate.bat"

echo Virtual Environment: [Activated]
echo West Version:
west --version 2>nul
echo.
echo ------------------------------------------------------------
echo Quick Command Tips:
echo   - Build sample:
echo       cd app\blinky
echo       west build -p always -b it51xxx_evb
echo.
echo   - Clean build:
echo       west build -t clean
echo.
echo   - Pristine rebuild:
echo       west build -p always -b it51xxx_evb
echo ------------------------------------------------------------
echo.

cd /d "%WORKSPACE_ROOT%"
cmd /k

