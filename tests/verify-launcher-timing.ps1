# Check all four real launchers with a delayed helper; never install or uninstall tools.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path $PSScriptRoot
$fixture = Join-Path $projectRoot ('offline_bundle\timing-test-' + [guid]::NewGuid().ToString('N'))
$launchers = @('zephyr-easy-setup.bat', 'zephyr-pack-offline.bat', 'zephyr-offline-install.bat', 'zephyr-uninstall.bat')
$originalNoPause = [Environment]::GetEnvironmentVariable('ZEPHYR_NO_PAUSE')
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Timing([string[]]$Output, [double]$MinimumSeconds) {
    $lines = @($Output | Where-Object { $_ -match '^\[TIME\] Total elapsed: ' })
    Assert ($lines.Count -eq 1) 'Launcher did not report elapsed time exactly once.'
    $match = [regex]::Match($lines[0], '^\[TIME\] Total elapsed: (\d{2,}):(\d{2}):(\d{2}) \((\d+[.,]\d{2}) seconds\)$')
    Assert ($match.Success) 'Elapsed-time output has an invalid format.'
    $seconds = [double]::Parse($match.Groups[4].Value.Replace(',', '.'), [Globalization.CultureInfo]::InvariantCulture)
    Assert ($seconds -ge $MinimumSeconds) 'Elapsed time did not include the helper execution.'
}
try {
    New-Item -ItemType Directory -Path (Join-Path $fixture 'scripts') -Force | Out-Null
    foreach ($launcher in $launchers) {
        Copy-Item -LiteralPath (Join-Path $projectRoot $launcher) -Destination $fixture
    }
    $helper = Join-Path $fixture 'scripts\zephyr-manager.ps1'
    $helperSource = @'
[CmdletBinding()]
param([string]$Mode, [string]$InstallDir, [int]$FixtureExit, [int]$DelayMilliseconds = 300)
Start-Sleep -Milliseconds $DelayMilliseconds
Write-Host "Timing fixture completed: $Mode"
exit $FixtureExit
'@
    Set-Content -LiteralPath $helper -Value $helperSource -Encoding UTF8
    $env:ZEPHYR_NO_PAUSE = '1'
    foreach ($launcher in $launchers) {
        foreach ($expectedExit in @(0, 1, 130)) {
            $output = @(& cmd.exe /c (Join-Path $fixture $launcher) -InstallDir $fixture -FixtureExit $expectedExit)
            $actualExit = $LASTEXITCODE
            Assert ($actualExit -eq $expectedExit) "$launcher timing changed exit $expectedExit to $actualExit."
            Assert-Timing $output 0.3
            Assert (($output -join "`n") -like '*Timing fixture completed:*') 'Helper was not invoked.'
        }
        Write-Host "[PASS] $launcher reports elapsed time and preserves success, failure and cancellation exit codes."
    }
    # CMD must not resume at an obsolete byte offset if the launcher changes mid-run.
    $mutationHelper = @'
[CmdletBinding()]
param([string]$Mode, [string]$InstallDir, [string]$LauncherToRewrite)
$target = [IO.Path]::GetFullPath($LauncherToRewrite)
if ([IO.Path]::GetDirectoryName($target) -ne [IO.Path]::GetFullPath($InstallDir).TrimEnd('\')) { throw 'Mutation escaped its fixture.' }
$content = [IO.File]::ReadAllText($target)
[IO.File]::WriteAllText($target, ('REM Updated while helper was running ' + ('x' * 113) + "`r`n" + $content), [Text.Encoding]::ASCII)
Write-Host "Mutation fixture completed: $Mode"
exit 9
'@
    Set-Content -LiteralPath $helper -Value $mutationHelper -Encoding UTF8
    foreach ($launcher in $launchers) {
        $launcherPath = Join-Path $fixture $launcher
        $output = @(& cmd.exe /c $launcherPath -InstallDir $fixture -LauncherToRewrite $launcherPath 2>&1)
        Assert ($LASTEXITCODE -eq 9) "$launcher lost the helper exit code after an in-flight update."
        Assert-Timing $output 0
        Assert ($output.Count -eq 2 -and ($output -join "`n").Contains('Mutation fixture completed:')) 'An in-flight update executed a partial launcher line.'
    }
    Write-Host '[PASS] Updating a launcher while its helper runs preserves exit codes and does not execute partial lines.'
    Remove-Item -LiteralPath $helper -Force
    foreach ($launcher in $launchers) {
        $output = @(& cmd.exe /c (Join-Path $fixture $launcher))
        Assert ($LASTEXITCODE -eq 1) 'Missing helper timing changed exit code 1.'
        Assert-Timing $output 0
        Assert (($output -join "`n") -like '*Required helper script is missing*') 'Missing-helper guidance was lost.'
    }
    Write-Host '[PASS] All launchers also report elapsed time when the helper is missing.'
    Write-Host 'All launcher timing checks passed.'
} finally {
    [Environment]::SetEnvironmentVariable('ZEPHYR_NO_PAUSE', $originalNoPause)
    $workspacePath = [IO.Path]::GetFullPath($projectRoot).TrimEnd('\')
    $cleanupPath = [IO.Path]::GetFullPath($fixture)
    if (-not $cleanupPath.StartsWith($workspacePath + '\offline_bundle\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Timing cleanup escaped its fixture directory.' }
    if (Test-Path -LiteralPath $cleanupPath) { Remove-Item -LiteralPath $cleanupPath -Recurse -Force }
}
