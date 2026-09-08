@echo off
setlocal EnableExtensions
title Zephyr Clean Uninstall (Preserves app folder)

echo ============================================================
echo   Zephyr RTOS Complete Uninstall Script
echo   (Safely preserves zephyrproject\app\)
echo ============================================================
echo.
echo This script will:
echo   1. Backup and PRESERVE your %~dp0zephyrproject\app directory
echo   2. Delete all other Zephyr sources, modules, SDK, and .venv
echo   3. Clear Zephyr CMake registry and environment settings
echo   4. (Optional) Uninstall dependency tools installed by winget
echo.
echo Please close VS Code, terminals, and build tools before proceeding.
echo.
pause

REM ------------------------------------------------------------
REM Step 1: Backup and preserve app directory
REM ------------------------------------------------------------
echo.
echo [1/5] Backing up zephyrproject\app if present...
set "PROJECT_DIR=%~dp0zephyrproject"
set "APP_BACKUP=%TEMP%\zephyr_app_backup_%RANDOM%"

if exist "%PROJECT_DIR%\app" (
    echo Found app directory. Backing up to %APP_BACKUP%...
    mkdir "%APP_BACKUP%"
    robocopy "%PROJECT_DIR%\app" "%APP_BACKUP%" /E /MOVE /NFL /NDL /NJH /NJS >nul
    echo App directory safely backed up.
) else (
    echo No app directory found to preserve.
)

REM ------------------------------------------------------------
REM Step 2: Remove zephyrproject workspace (SDK, venv, source)
REM ------------------------------------------------------------
echo.
echo [2/5] Removing zephyrproject workspace directories...
for %%D in (
    "%PROJECT_DIR%"
    "C:\zephyrproject"
    "D:\zephyrproject"
    "%USERPROFILE%\zephyrproject"
) do (
    if exist "%%~fD" (
        echo Deleting: %%~fD...
        rd /s /q "%%~fD" >nul 2>nul
    )
)

for /d %%S in ("%USERPROFILE%\zephyr-sdk-*") do (
    echo Deleting orphaned SDK: %%S...
    rd /s /q "%%S" >nul 2>nul
)

REM ------------------------------------------------------------
REM Step 3: Restore app directory back to zephyrproject\app
REM ------------------------------------------------------------
echo.
echo [3/5] Restoring preserved app folder...
if exist "%APP_BACKUP%" (
    mkdir "%PROJECT_DIR%\app"
    robocopy "%APP_BACKUP%" "%PROJECT_DIR%\app" /E /MOVE /NFL /NDL /NJH /NJS >nul
    rd /s /q "%APP_BACKUP%" >nul 2>nul
    echo [OK] %PROJECT_DIR%\app has been successfully restored and preserved!
)

REM ------------------------------------------------------------
REM Step 4: Clear environment variables & CMake package registries
REM ------------------------------------------------------------
echo.
echo [4/5] Clearing environment variables & CMake package registries...
reg delete "HKCU\Environment" /v ZEPHYR_BASE /f >nul 2>nul
reg delete "HKCU\Environment" /v ZEPHYR_SDK_INSTALL_DIR /f >nul 2>nul
reg delete "HKCU\Environment" /v ZEPHYR_TOOLCHAIN_VARIANT /f >nul 2>nul

reg delete "HKCU\Software\Kitware\CMake\Packages\Zephyr" /f >nul 2>nul
reg delete "HKCU\Software\Kitware\CMake\Packages\Zephyr-sdk" /f >nul 2>nul

if exist "%USERPROFILE%\.cmake\packages\Zephyr" rd /s /q "%USERPROFILE%\.cmake\packages\Zephyr" >nul 2>nul
if exist "%USERPROFILE%\.cmake\packages\Zephyr-sdk" rd /s /q "%USERPROFILE%\.cmake\packages\Zephyr-sdk" >nul 2>nul
echo Environment variables and registry entries cleared.

REM ------------------------------------------------------------
REM Step 5: (Optional) Uninstall winget tools
REM ------------------------------------------------------------
echo.
echo [5/5] Host development tools (CMake, Ninja, Python 3.12, Git, 7-Zip, etc.)
set /p UNINSTALL_TOOLS="Do you want to uninstall host tools via winget as well? (y/N): "
if /i "%UNINSTALL_TOOLS%"=="y" (
    where winget >nul 2>nul
    if not errorlevel 1 (
        for %%I in (
            Kitware.CMake
            Ninja-build.Ninja
            oss-winget.gperf
            Python.Python.3.12
            Git.Git
            oss-winget.dtc
            wget
            7zip.7zip
        ) do (
            echo Uninstalling %%I...
            winget uninstall --id %%I --silent --accept-source-agreements >nul 2>nul
        )
    )
) else (
    echo Kept host tools intact.
)

echo.
echo ============================================================
echo   Cleanup completed!
echo   Preserved files: %PROJECT_DIR%\app
echo ============================================================
pause