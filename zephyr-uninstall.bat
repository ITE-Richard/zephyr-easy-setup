@echo off
setlocal EnableExtensions
set "ZEPHYR_START_TICKS="
for /f %%T in ('powershell.exe -NoProfile -Command "[Diagnostics.Stopwatch]::GetTimestamp()"') do set "ZEPHYR_START_TICKS=%%T"
if not exist "%~dp0scripts\zephyr-manager.ps1" (
    echo [ERROR] Required helper script is missing:
    echo         "%~dp0scripts\zephyr-manager.ps1"
    echo Extract or copy the entire project folder, including scripts.
    echo Run the launcher from that complete folder.
    set "RESULT=1"
    goto ReportElapsed
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\zephyr-manager.ps1" -Mode Uninstall %*
set "RESULT=%ERRORLEVEL%"
:ReportElapsed
if defined ZEPHYR_START_TICKS powershell.exe -NoProfile -Command "$elapsed = [TimeSpan]::FromSeconds(([Diagnostics.Stopwatch]::GetTimestamp() - [long]$env:ZEPHYR_START_TICKS) / [Diagnostics.Stopwatch]::Frequency); Write-Host ('[TIME] Total elapsed: {0:00}:{1:00}:{2:00} ({3:F2} seconds)' -f [math]::Floor($elapsed.TotalHours), $elapsed.Minutes, $elapsed.Seconds, $elapsed.TotalSeconds)"
if not defined ZEPHYR_NO_PAUSE pause
exit /b %RESULT%
