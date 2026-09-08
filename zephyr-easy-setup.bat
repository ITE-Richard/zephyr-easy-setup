@echo off
setlocal EnableExtensions
title Zephyr One-Click Setup (Windows)

echo ============================================================
echo   Zephyr RTOS One-Click Automated Setup
echo ============================================================
echo.

REM Set Zephyr workspace directory to zephyrproject alongside this script
set "WORKSPACE_ROOT=%~dp0zephyrproject"
echo Target Zephyr Workspace: %WORKSPACE_ROOT%
echo.

REM ------------------------------------------------------------
REM Step 1: Checking winget
REM ------------------------------------------------------------
echo ===== [Step 1/10] Checking winget =====
where winget >nul 2>nul
if errorlevel 1 (
    echo [INFO] winget not found in PATH. Checking default app paths...
    set "PATH=%PATH%;%LocalAppData%\Microsoft\WindowsApps;C:\Program Files\WindowsApps"
    where winget >nul 2>nul
    if errorlevel 1 (
        echo [ERROR] winget is required. Please install 'App Installer' from Microsoft Store:
        echo         https://aka.ms/getwinget
        pause
        exit /b 1
    )
)
echo [OK] winget is available.

REM ------------------------------------------------------------
REM Step 2: Installing Host Dependencies via winget
REM ------------------------------------------------------------
echo.
echo ===== [Step 2/10] Installing Host Dependencies via winget =====
for %%P in (
    Kitware.CMake
    Ninja-build.Ninja
    oss-winget.gperf
    Python.Python.3.12
    Git.Git
    oss-winget.dtc
    wget
    7zip.7zip
) do (
    echo Checking/Installing %%P...
    winget install --id %%P -e --source winget --accept-package-agreements --accept-source-agreements --silent >nul 2>nul
)

REM ------------------------------------------------------------
REM Step 3: Configuring Environment PATH
REM ------------------------------------------------------------
echo.
echo ===== [Step 3/10] Configuring Environment PATH =====
REM Refresh installer changes without discarding the current process PATH.
for /f "delims=" %%P in ('powershell.exe -NoProfile -Command "[Environment]::GetEnvironmentVariable('Path', 'Machine'); [Environment]::GetEnvironmentVariable('Path', 'User')"') do call :AddHostPath "%%P"

REM Only add tool directories that actually contain the expected executable.
set "ZEPHYR_HOST_PATH="
call :AddToolPath "%ProgramFiles%\CMake\bin" "cmake.exe"
call :AddToolPath "%ProgramFiles%\Git\cmd" "git.exe"
call :AddToolPath "%ProgramFiles%\7-Zip" "7z.exe"
call :AddToolPath "%LocalAppData%\Programs\Python\Python312" "python.exe"
call :AddToolPath "%LocalAppData%\Programs\Python\Python312\Scripts" "pip.exe"
call :AddToolPath "%ProgramFiles%\Python312" "python.exe"
call :AddToolPath "%ProgramFiles%\Python312\Scripts" "pip.exe"
for %%T in (ninja.exe gperf.exe dtc.exe wget.exe) do (
    call :AddToolPath "%LocalAppData%\Microsoft\WinGet\Links" "%%T"
    call :AddToolPath "%ProgramFiles%\WinGet\Links" "%%T"
)
REM The dtc winget package can expose usr\bin instead of a Links entry.
for /d %%D in ("%LocalAppData%\Microsoft\WinGet\Packages\oss-winget.dtc_*" "%ProgramFiles%\WinGet\Packages\oss-winget.dtc_*") do call :AddToolPath "%%~fD\usr\bin" "dtc.exe"

REM Do not report success when winget failed or an executable cannot start.
for %%T in (cmake ninja gperf dtc git python wget) do (
    echo Checking %%T...
    %%T.exe --version >nul 2>nul
    if errorlevel 1 (
        echo [ERROR] %%T cannot run. Check its winget installation and PATH.
        pause
        exit /b 1
    )
    where %%T.exe
)
7z.exe i >nul 2>nul
if errorlevel 1 (
    echo [ERROR] 7-Zip cannot run. Check the 7zip.7zip installation and PATH.
    pause
    exit /b 1
)
where 7z.exe

REM Persist missing host paths only; keep workspace .venv and SDK paths local.
powershell.exe -NoProfile -Command "$ErrorActionPreference = 'Stop'; try { $userPath = [Environment]::GetEnvironmentVariable('Path', 'User'); $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine'); $known = @(($machinePath + ';' + $userPath) -split ';' | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_.Trim()).TrimEnd('\') }); $updatedPath = $userPath; foreach ($dir in ($env:ZEPHYR_HOST_PATH -split ';')) { $dir = $dir.Trim().TrimEnd('\'); if ($dir -and $known -notcontains $dir) { if ([string]::IsNullOrEmpty($updatedPath)) { $updatedPath = $dir } else { $updatedPath = $updatedPath.TrimEnd(';') + ';' + $dir }; $known += $dir } }; if ($updatedPath -cne $userPath) { [Environment]::SetEnvironmentVariable('Path', $updatedPath, 'User') } } catch { Write-Error $_; exit 1 }"
if errorlevel 1 (
    echo [ERROR] Could not save host tool directories to the user PATH.
    pause
    exit /b 1
)
echo [OK] Host tools verified and missing directories saved to user PATH.
echo [INFO] Restart your terminal application before building in another shell.
echo [INFO] Then activate the workspace .venv before running west.

REM ------------------------------------------------------------
REM Step 4: Locating Python 3.12
REM ------------------------------------------------------------
echo.
echo ===== [Step 4/10] Locating Python 3.12 =====
set "PYTHON_EXE="
py -3.12 --version >nul 2>nul
if not errorlevel 1 (
    set "PYTHON_EXE=py -3.12"
) else (
    where python >nul 2>nul
    if not errorlevel 1 set "PYTHON_EXE=python"
)

if not defined PYTHON_EXE (
    if exist "%LocalAppData%\Programs\Python\Python312\python.exe" (
        set "PYTHON_EXE=%LocalAppData%\Programs\Python\Python312\python.exe"
    ) else (
        echo [ERROR] Python 3.12 not found. Please restart terminal or verify installation.
        pause
        exit /b 1
    )
)
echo [OK] Using Python: %PYTHON_EXE%

REM ------------------------------------------------------------
REM Step 5: Creating Python Virtual Environment
REM ------------------------------------------------------------
echo.
echo ===== [Step 5/10] Creating Python Virtual Environment =====
if not exist "%WORKSPACE_ROOT%" mkdir "%WORKSPACE_ROOT%"

if not exist "%WORKSPACE_ROOT%\.venv\Scripts\activate.bat" (
    echo Creating .venv in %WORKSPACE_ROOT%\.venv ...
    %PYTHON_EXE% -m venv "%WORKSPACE_ROOT%\.venv"
    if errorlevel 1 (
        echo [ERROR] Failed to create venv.
        pause
        exit /b 1
    )
)
call "%WORKSPACE_ROOT%\.venv\Scripts\activate.bat"
python -m pip install --upgrade pip >nul 2>nul
python -m pip install west >nul 2>nul
echo [OK] Virtual environment activated, west installed.

REM ------------------------------------------------------------
REM Step 6: Initializing Zephyr Workspace
REM ------------------------------------------------------------
echo.
echo ===== [Step 6/10] Initializing Zephyr Workspace =====
cd /d "%WORKSPACE_ROOT%"
if not exist ".west" (
    echo Initializing west repository in %WORKSPACE_ROOT%...
    west init -l . >nul 2>nul
    if errorlevel 1 (
        west init -m https://github.com/zephyrproject-rtos/zephyr .
    )
) else (
    echo [INFO] .west already exists, skipping init.
)

echo Running west update (fetching repositories)...
west update
if errorlevel 1 (
    echo [ERROR] west update failed. Please check network/git access.
    pause
    exit /b 1
)

REM ------------------------------------------------------------
REM Step 7: Installing Zephyr Python Packages & CMake Export
REM ------------------------------------------------------------
echo.
echo ===== [Step 7/10] Installing Zephyr Python Packages & CMake Export =====
if exist "zephyr\scripts\utils\west-packages-pip-install.cmd" (
    cmd /c zephyr\scripts\utils\west-packages-pip-install.cmd
) else (
    west packages pip --install
)
west zephyr-export

REM ------------------------------------------------------------
REM Step 8: Installing Zephyr SDK into zephyrproject
REM ------------------------------------------------------------
echo.
echo ===== [Step 8/10] Installing Zephyr SDK into zephyrproject =====
echo Installing Zephyr SDK (riscv64-zephyr-elf & host tools)...
west sdk install -d . -t riscv64-zephyr-elf
if errorlevel 1 (
    echo [WARNING] Minimal toolchain install failed. Trying default SDK install...
    west sdk install -d .
)

for /d %%D in ("%WORKSPACE_ROOT%\zephyr-sdk-*") do (
    set "ZEPHYR_SDK_INSTALL_DIR=%%~fD"
)
set "ZEPHYR_TOOLCHAIN_VARIANT=zephyr"

echo [OK] ZEPHYR_SDK_INSTALL_DIR=%ZEPHYR_SDK_INSTALL_DIR%
echo [OK] ZEPHYR_TOOLCHAIN_VARIANT=%ZEPHYR_TOOLCHAIN_VARIANT%

REM ------------------------------------------------------------
REM Step 9: Preparing Blinky Sample in zephyrproject\app
REM ------------------------------------------------------------
echo.
echo ===== [Step 9/10] Preparing Blinky Sample in %WORKSPACE_ROOT%\app =====
if not exist "%WORKSPACE_ROOT%\app" mkdir "%WORKSPACE_ROOT%\app"

if not exist "%WORKSPACE_ROOT%\app\blinky" (
    echo Copying samples\basic\blinky to app\blinky...
    xcopy /E /I /Y "%WORKSPACE_ROOT%\zephyr\samples\basic\blinky" "%WORKSPACE_ROOT%\app\blinky" >nul
) else (
    echo [INFO] app\blinky already exists.
)

REM ------------------------------------------------------------
REM Step 10: Building Blinky for it51xxx_evb
REM ------------------------------------------------------------
echo.
echo ===== [Step 10/10] Building Blinky for it51xxx_evb =====
cd /d "%WORKSPACE_ROOT%\app\blinky"
if exist "build" rmdir /S /Q build

echo Starting build with west...
west build -p always -b it51xxx_evb
if errorlevel 1 (
    echo [INFO] Building with 'it51xxx_evb/it51526aw' target qualifier...
    west build -p always -b it51xxx_evb/it51526aw
)

if errorlevel 1 (
    echo.
    echo [BUILD FAILED] Build did not complete successfully.
    pause
    exit /b 1
) else (
    echo.
    echo ============================================================
    echo   [SUCCESS] Zephyr Setup & Sample Build Completed!
    echo   Firmware: %WORKSPACE_ROOT%\app\blinky\build\zephyr\zephyr.bin
    echo ============================================================
)

pause
exit /b 0

:AddHostPath
set "PATH=%PATH%;%~1"
exit /b 0

:AddToolPath
if not exist "%~1\%~2" exit /b 0
set "PATH=%PATH%;%~1"
set "ZEPHYR_HOST_PATH=%ZEPHYR_HOST_PATH%;%~1"
exit /b 0
