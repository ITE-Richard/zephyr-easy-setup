@echo off
setlocal EnableExtensions
title Zephyr Offline Bundle Packager

echo ============================================================
echo   Zephyr RTOS Offline Bundle Packager
echo ============================================================
echo.

set "ROOT_DIR=%~dp0"
if "%ROOT_DIR:~-1%"=="\" set "ROOT_DIR=%ROOT_DIR:~0,-1%"
set "WORKSPACE_ROOT=%ROOT_DIR%\zephyrproject"
set "INSTALLERS_DIR=%ROOT_DIR%\installers"
set "OUTPUT_ZIP=%ROOT_DIR%\zephyr-offline-bundle.zip"


REM ------------------------------------------------------------
REM Step 1: Pre-flight Verification
REM ------------------------------------------------------------
echo ===== [Step 1/5] Verifying Zephyr Environment =====

for /f "tokens=1,2" %%A in ("%WORKSPACE_ROOT%") do if not "%%B"=="" (
    echo ============================================================
    echo [ERROR] Space detected in workspace path:
    echo         "%WORKSPACE_ROOT%"
    echo ============================================================
    echo Zephyr RTOS, CMake, and Kconfig do NOT support paths with spaces.
    echo Please move this project to a path without spaces before packaging.
    echo.
    pause
    exit /b 1
)

if not exist "%WORKSPACE_ROOT%" (
    echo [ERROR] Zephyr workspace not found at:
    echo         %WORKSPACE_ROOT%
    echo Please run 'zephyr-easy-setup.bat' first to download Zephyr and SDK.
    pause
    exit /b 1
)

if not exist "%WORKSPACE_ROOT%\.venv\Scripts\activate.bat" (
    echo [ERROR] Virtual environment not found at:
    echo         %WORKSPACE_ROOT%\.venv
    echo Please run 'zephyr-easy-setup.bat' first to complete initial setup.
    pause
    exit /b 1
)

set "SDK_FOUND=0"
for /d %%D in ("%WORKSPACE_ROOT%\zephyr-sdk-*") do set "SDK_FOUND=1"
if "%SDK_FOUND%"=="0" (
    echo [WARNING] No zephyr-sdk directory found in %WORKSPACE_ROOT%.
    echo The bundle will not include pre-installed SDK toolchains!
    set /p CONT="Do you want to continue anyway? (y/N): "
    if /i not "%CONT%"=="y" exit /b 1
)
echo [OK] Zephyr workspace and SDK verified.

REM ------------------------------------------------------------
REM Step 2: Download Python Offline Wheels
REM ------------------------------------------------------------
echo.
echo ===== [Step 2/5] Downloading Python Offline Wheels =====
if not exist "%INSTALLERS_DIR%\wheels" mkdir "%INSTALLERS_DIR%\wheels"

call "%WORKSPACE_ROOT%\.venv\Scripts\activate.bat"
echo Downloading west and dependency wheels...
python -m pip download -d "%INSTALLERS_DIR%\wheels" west >nul 2>nul
if errorlevel 1 (
    echo [WARNING] pip download west encountered issues. Retrying with output...
    python -m pip download -d "%INSTALLERS_DIR%\wheels" west
)

if exist "%WORKSPACE_ROOT%\zephyr\scripts\requirements.txt" (
    echo Downloading Zephyr base requirements wheels...
    python -m pip download -d "%INSTALLERS_DIR%\wheels" -r "%WORKSPACE_ROOT%\zephyr\scripts\requirements.txt" >nul 2>nul
)
echo [OK] Python wheels cached in %INSTALLERS_DIR%\wheels.

REM ------------------------------------------------------------
REM Step 3: Download Host Tools Installers
REM ------------------------------------------------------------
echo.
echo ===== [Step 3/5] Downloading Host Tools Installers =====
if not exist "%INSTALLERS_DIR%\tools" mkdir "%INSTALLERS_DIR%\tools"

where winget >nul 2>nul
if errorlevel 1 (
    set "PATH=%PATH%;%LocalAppData%\Microsoft\WindowsApps;C:\Program Files\WindowsApps"
)

where winget >nul 2>nul
if not errorlevel 1 (
    for %%P in (
        Kitware.CMake
        Ninja-build.Ninja
        oss-winget.gperf
        Python.Python.3.12
        Git.Git
        oss-winget.dtc
        7zip.7zip
    ) do (
        echo Downloading %%P installer...
        winget download --id %%P -d "%INSTALLERS_DIR%\tools" -e --source winget --accept-package-agreements --accept-source-agreements --nowarn >nul 2>nul
    )
    echo [OK] Host tools installers downloaded to %INSTALLERS_DIR%\tools.
) else (
    echo [WARNING] winget not found in PATH.
    echo If offline installers already exist in %INSTALLERS_DIR%\tools, they will be packaged.
)

REM ------------------------------------------------------------
REM Step 4: Clean Temporary Build Directories
REM ------------------------------------------------------------
echo.
echo ===== [Step 4/5] Cleaning Build Artifacts & Temporary Files =====
for /d /r "%WORKSPACE_ROOT%" %%D in (build) do (
    if exist "%%D" (
        echo Removing build cache: %%D
        rd /s /q "%%D" >nul 2>nul
    )
)
echo [OK] Cleaned intermediate build files.

REM ------------------------------------------------------------
REM Step 5: Compress into ZIP Archive
REM ------------------------------------------------------------
echo.
echo ===== [Step 5/5] Packaging into %OUTPUT_ZIP% =====
if exist "%OUTPUT_ZIP%" del /f /q "%OUTPUT_ZIP%"

set "COMPRESSOR="
if exist "%ProgramFiles%\7-Zip\7z.exe" set "COMPRESSOR=%ProgramFiles%\7-Zip\7z.exe"
where 7z >nul 2>nul && set "COMPRESSOR=7z"

if defined COMPRESSOR (
    echo Using 7-Zip for high-speed multi-threaded compression...
    "%COMPRESSOR%" a -tzip "%OUTPUT_ZIP%" "%ROOT_DIR%zephyr-offline-install.bat" "%ROOT_DIR%zephyr-env.cmd" "%ROOT_DIR%README.md" "%ROOT_DIR%installers" "%ROOT_DIR%zephyrproject" -xr!.venv -xr!build -xr!*.log -xr!*.tmp
) else (
    where tar >nul 2>nul
    if not errorlevel 1 (
        echo Using tar for compression...
        tar.exe -a -c --exclude="*.venv*" --exclude="*build*" -f "%OUTPUT_ZIP%" zephyr-offline-install.bat zephyr-env.cmd README.md installers zephyrproject
    ) else (
        echo Using PowerShell Compress-Archive (may take a few minutes)...
        powershell.exe -NoProfile -Command "Compress-Archive -Path '%ROOT_DIR%zephyr-offline-install.bat','%ROOT_DIR%zephyr-env.cmd','%ROOT_DIR%README.md','%ROOT_DIR%installers','%ROOT_DIR%zephyrproject' -DestinationPath '%OUTPUT_ZIP%' -Force"
    )
)

if exist "%OUTPUT_ZIP%" (
    echo.
    echo ============================================================
    echo   [SUCCESS] Offline Bundle Created Successfully!
    echo   Archive: %OUTPUT_ZIP%
    echo ============================================================
    echo.
    echo Migration Instructions:
    echo   1. Copy '%OUTPUT_ZIP%' to target computer.
    echo   2. Extract the ZIP archive into a directory WITHOUT SPACES (e.g., D:\zephyr).
    echo   3. Run 'zephyr-offline-install.bat' on the target computer.
    echo.
) else (
    echo.
    echo [ERROR] Failed to create %OUTPUT_ZIP%.
    pause
    exit /b 1
)

pause
exit /b 0
