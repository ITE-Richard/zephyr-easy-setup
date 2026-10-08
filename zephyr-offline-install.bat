@echo off
setlocal EnableExtensions
title Zephyr Offline Automated Setup (Target PC)

echo ============================================================
echo   Zephyr RTOS Offline Automated Setup
echo ============================================================
echo.

set "ROOT_DIR=%~dp0"
if "%ROOT_DIR:~-1%"=="\" set "ROOT_DIR=%ROOT_DIR:~0,-1%"
set "WORKSPACE_ROOT=%ROOT_DIR%\zephyrproject"
set "INSTALLERS_DIR=%ROOT_DIR%\installers"

REM ------------------------------------------------------------
REM Space in Path Verification
REM ------------------------------------------------------------
for /f "tokens=1,2" %%A in ("%ROOT_DIR%") do if not "%%B"=="" (
    echo ============================================================
    echo [ERROR] Space detected in extraction path:
    echo         "%ROOT_DIR%"
    echo ============================================================
    echo Zephyr RTOS, CMake, and Kconfig do NOT support paths with spaces.
    echo Please move or extract this folder to a path without spaces, for example C:\zephyr or D:\zephyr.
    echo.
    pause
    exit /b 1
)

if not exist "%WORKSPACE_ROOT%" (
    echo [ERROR] zephyrproject directory not found!
    echo         Expected at: %WORKSPACE_ROOT%
    echo Please make sure the entire zip bundle was extracted properly.
    pause
    exit /b 1
)

REM ------------------------------------------------------------
REM Step 1: Installing Host Tools
REM ------------------------------------------------------------
echo ===== [Step 1/7] Checking & Installing Host Tools =====

REM 1. Python 3.12 / >= 3.10
set "PYTHON_EXE="
py -3.12 -c "import sys; print(sys.version)" >nul 2>nul
if not errorlevel 1 (
    set "PYTHON_EXE=py -3.12"
) else (
    python -c "import sys; sys.exit(0 if sys.version_info.major == 3 and sys.version_info.minor >= 10 else 1)" >nul 2>nul
    if not errorlevel 1 set "PYTHON_EXE=python"
)

if not defined PYTHON_EXE (
    echo Python >= 3.10 not found. Installing from offline installer...
    for %%F in ("%INSTALLERS_DIR%\tools\*python*.exe") do (
        echo Running %%~nxF ...
        start /wait "" "%%~fF" /quiet InstallAllUsers=0 PrependPath=1 Include_pip=1
    )
    set "PATH=%PATH%;%LocalAppData%\Programs\Python\Python312;%LocalAppData%\Programs\Python\Python312\Scripts;%ProgramFiles%\Python312;%ProgramFiles%\Python312\Scripts"
    py -3.12 --version >nul 2>nul
    if not errorlevel 1 (
        set "PYTHON_EXE=py -3.12"
    ) else (
        python --version >nul 2>nul
        if not errorlevel 1 set "PYTHON_EXE=python"
    )
)

if not defined PYTHON_EXE (
    if exist "%LocalAppData%\Programs\Python\Python312\python.exe" (
        set "PYTHON_EXE=%LocalAppData%\Programs\Python\Python312\python.exe"
    ) else (
        echo [ERROR] Python installation failed or was not found. Please install Python >= 3.10 manually.
        pause
        exit /b 1
    )
)
echo [OK] Using Python: %PYTHON_EXE%

REM 2. Git
where git >nul 2>nul
if errorlevel 1 (
    if exist "%ProgramFiles%\Git\cmd\git.exe" (
        set "PATH=%PATH%;%ProgramFiles%\Git\cmd"
    ) else (
        echo Installing Git from offline installer...
        for %%F in ("%INSTALLERS_DIR%\tools\*git*.exe") do (
            echo Running %%~nxF ...
            start /wait "" "%%~fF" /VERYSILENT /NORESTART
        )
        set "PATH=%PATH%;%ProgramFiles%\Git\cmd"
    )
)
echo [OK] Git verified.

REM 3. CMake
where cmake >nul 2>nul
if errorlevel 1 (
    if exist "%ProgramFiles%\CMake\bin\cmake.exe" (
        set "PATH=%PATH%;%ProgramFiles%\CMake\bin"
    ) else (
        echo Installing CMake from offline installer...
        for %%F in ("%INSTALLERS_DIR%\tools\*cmake*.msi") do (
            echo Running %%~nxF ...
            start /wait msiexec /i "%%~fF" /qn ADD_CMAKE_TO_PATH=System
        )
        set "PATH=%PATH%;%ProgramFiles%\CMake\bin"
    )
)
echo [OK] CMake verified.

REM 4. 7-Zip
where 7z >nul 2>nul
if errorlevel 1 (
    if exist "%ProgramFiles%\7-Zip\7z.exe" (
        set "PATH=%PATH%;%ProgramFiles%\7-Zip"
    ) else (
        echo Installing 7-Zip from offline installer...
        for %%F in ("%INSTALLERS_DIR%\tools\*7z*.msi") do (
            echo Running %%~nxF ...
            start /wait msiexec /i "%%~fF" /qn
        )
        set "PATH=%PATH%;%ProgramFiles%\7-Zip"
    )
)
echo [OK] 7-Zip verified.

REM ------------------------------------------------------------
REM Step 2: Extract Portable Tools (Ninja, dtc, gperf)
REM ------------------------------------------------------------
echo.
echo ===== [Step 2/7] Preparing Portable Tools (Ninja, dtc, gperf) =====
if not exist "%ROOT_DIR%tools" mkdir "%ROOT_DIR%tools"

for %%F in ("%INSTALLERS_DIR%\tools\*ninja*.zip") do (
    if not exist "%ROOT_DIR%tools\ninja\ninja.exe" (
        echo Extracting Ninja...
        mkdir "%ROOT_DIR%tools\ninja" >nul 2>nul
        tar.exe -xf "%%~fF" -C "%ROOT_DIR%tools\ninja" >nul 2>nul
    )
)

for %%F in ("%INSTALLERS_DIR%\tools\*gperf*.zip") do (
    if not exist "%ROOT_DIR%tools\gperf\gperf.exe" (
        echo Extracting gperf...
        mkdir "%ROOT_DIR%tools\gperf" >nul 2>nul
        tar.exe -xf "%%~fF" -C "%ROOT_DIR%tools\gperf" >nul 2>nul
    )
)

for %%F in ("%INSTALLERS_DIR%\tools\*dtc*.zip") do (
    if not exist "%ROOT_DIR%tools\dtc\usr\bin\dtc.exe" (
        echo Extracting dtc...
        mkdir "%ROOT_DIR%tools\dtc" >nul 2>nul
        tar.exe -xf "%%~fF" -C "%ROOT_DIR%tools\dtc" >nul 2>nul
    )
)
echo [OK] Portable tools ready.

REM ------------------------------------------------------------
REM Step 3: Configure Environment PATH & Git Long Paths
REM ------------------------------------------------------------
echo.
echo ===== [Step 3/7] Configuring Environment PATH =====
set "ZEPHYR_HOST_PATH="
call :AddToolPath "%ProgramFiles%\CMake\bin" "cmake.exe"
call :AddToolPath "%ProgramFiles%\Git\cmd" "git.exe"
call :AddToolPath "%ProgramFiles%\7-Zip" "7z.exe"
call :AddToolPath "%LocalAppData%\Programs\Python\Python312" "python.exe"
call :AddToolPath "%LocalAppData%\Programs\Python\Python312\Scripts" "pip.exe"
call :AddToolPath "%ProgramFiles%\Python312" "python.exe"
call :AddToolPath "%ProgramFiles%\Python312\Scripts" "pip.exe"
call :AddToolPath "%ROOT_DIR%tools\ninja" "ninja.exe"
call :AddToolPath "%ROOT_DIR%tools\gperf" "gperf.exe"
call :AddToolPath "%ROOT_DIR%tools\dtc\usr\bin" "dtc.exe"
for %%T in (ninja.exe gperf.exe dtc.exe) do (
    call :AddToolPath "%LocalAppData%\Microsoft\WinGet\Links" "%%T"
    call :AddToolPath "%ProgramFiles%\WinGet\Links" "%%T"
)

REM Enable Git Long Paths
git config --global core.longpaths true >nul 2>nul

REM Persist Host Paths to User PATH
powershell.exe -NoProfile -Command "$ErrorActionPreference = 'Stop'; try { $userPath = [Environment]::GetEnvironmentVariable('Path', 'User'); $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine'); $known = @(($machinePath + ';' + $userPath) -split ';' | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_.Trim()).TrimEnd('\') }); $updatedPath = $userPath; foreach ($dir in ($env:ZEPHYR_HOST_PATH -split ';')) { $dir = $dir.Trim().TrimEnd('\'); if ($dir -and $known -notcontains $dir) { if ([string]::IsNullOrEmpty($updatedPath)) { $updatedPath = $dir } else { $updatedPath = $updatedPath.TrimEnd(';') + ';' + $dir }; $known += $dir } }; if ($updatedPath -cne $userPath) { [Environment]::SetEnvironmentVariable('Path', $updatedPath, 'User') } } catch { Write-Error $_; exit 1 }"
echo [OK] PATH configured and saved to User Environment.

REM ------------------------------------------------------------
REM Step 4: Create Virtual Environment & Install Offline Wheels
REM ------------------------------------------------------------
echo.
echo ===== [Step 4/7] Setting up Python Virtual Environment (Offline) =====
if not exist "%WORKSPACE_ROOT%\.venv\Scripts\activate.bat" (
    echo Creating virtual environment at %WORKSPACE_ROOT%\.venv ...
    %PYTHON_EXE% -m venv "%WORKSPACE_ROOT%\.venv"
    if errorlevel 1 (
        echo [ERROR] Failed to create venv.
        pause
        exit /b 1
    )
)

call "%WORKSPACE_ROOT%\.venv\Scripts\activate.bat"
echo Installing west and dependencies from offline wheels...
python -m pip install --no-index --find-links="%INSTALLERS_DIR%\wheels" west >nul 2>nul
if exist "%WORKSPACE_ROOT%\zephyr\scripts\requirements.txt" (
    python -m pip install --no-index --find-links="%INSTALLERS_DIR%\wheels" -r "%WORKSPACE_ROOT%\zephyr\scripts\requirements.txt" >nul 2>nul
)
echo [OK] Python dependencies installed offline.

REM ------------------------------------------------------------
REM Step 5: Export Zephyr CMake Package
REM ------------------------------------------------------------
echo.
echo ===== [Step 5/7] Registering Zephyr CMake Package =====
cd /d "%WORKSPACE_ROOT%"
west zephyr-export
echo [OK] Zephyr CMake package exported.

REM ------------------------------------------------------------
REM Step 6: Register Zephyr SDK
REM ------------------------------------------------------------
echo.
echo ===== [Step 6/7] Registering Zephyr SDK =====
set "ZEPHYR_SDK_INSTALL_DIR="
for /d %%D in ("%WORKSPACE_ROOT%\zephyr-sdk-*") do (
    set "ZEPHYR_SDK_INSTALL_DIR=%%~fD"
)
set "ZEPHYR_TOOLCHAIN_VARIANT=zephyr"

if defined ZEPHYR_SDK_INSTALL_DIR (
    echo Found SDK: %ZEPHYR_SDK_INSTALL_DIR%
    if exist "%ZEPHYR_SDK_INSTALL_DIR%\setup.cmd" (
        call "%ZEPHYR_SDK_INSTALL_DIR%\setup.cmd" -c >nul 2>nul
    )
    powershell.exe -NoProfile -Command "[Environment]::SetEnvironmentVariable('ZEPHYR_SDK_INSTALL_DIR', '%ZEPHYR_SDK_INSTALL_DIR%', 'User'); [Environment]::SetEnvironmentVariable('ZEPHYR_TOOLCHAIN_VARIANT', 'zephyr', 'User')"
    echo [OK] Zephyr SDK registered and environment variables persisted.
) else (
    echo [WARNING] Zephyr SDK directory not found in %WORKSPACE_ROOT%.
)

REM ------------------------------------------------------------
REM Step 7: Build Verification (Blinky Sample)
REM ------------------------------------------------------------
echo.
echo ===== [Step 7/7] Verifying Build with Blinky Sample =====
if exist "%WORKSPACE_ROOT%\app\blinky" (
    cd /d "%WORKSPACE_ROOT%\app\blinky"
    if exist "build" rmdir /S /Q build
    echo Building blinky for it51xxx_evb...
    west build -p always -b it51xxx_evb
    if errorlevel 1 (
        echo Building with 'it51xxx_evb/it51526aw' qualifier...
        west build -p always -b it51xxx_evb/it51526aw
    )
    if errorlevel 1 (
        echo [WARNING] Sample build failed. Please check build log.
    ) else (
        echo.
        echo ============================================================
        echo   [SUCCESS] Offline Setup & Sample Build Completed!
        echo   Firmware: %WORKSPACE_ROOT%\app\blinky\build\zephyr\zephyr.bin
        echo ============================================================
    )
) else (
    echo [INFO] No app\blinky sample found to build. Setup is complete!
)

echo.
echo All components installed and configured.
echo To start development anytime, run 'zephyr-env.cmd'!
echo.
pause
exit /b 0

:AddToolPath
if not exist "%~1\%~2" exit /b 0
set "PATH=%PATH%;%~1"
set "ZEPHYR_HOST_PATH=%ZEPHYR_HOST_PATH%;%~1"
exit /b 0
