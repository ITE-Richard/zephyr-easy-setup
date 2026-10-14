# Isolated progress and owned-process cancellation checks; no shared installation is modified.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path $PSScriptRoot
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot 'scripts\zephyr-manager.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$functions = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)
. ([scriptblock]::Create(($functions | ForEach-Object { $_.Extent.Text }) -join "`n"))
$fixture = Join-Path $projectRoot ('offline_bundle\progress-test-' + [guid]::NewGuid().ToString('N'))
$source = Join-Path $fixture 'copy source'
$excluded = Join-Path $source '.venv'
$script:events = @()
$script:cancelCopy = $false
$script:ioAvailable = $true
$script:ownedPid = 0
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Write-PackProgress {
    param([string]$Activity, [string]$Status, [int]$PercentComplete = -1, [switch]$Completed)
    $script:events += [pscustomobject]@{ Activity = $Activity; Percent = $PercentComplete; Completed = [bool]$Completed }
}
function Get-CimInstance {
    param([string]$ClassName, [string]$Filter, [string]$ErrorAction)
    $script:ownedPid = [int]($Filter -replace '^ProcessId = ', '')
    if ($script:cancelCopy) { throw (New-Object OperationCanceledException('Simulated copy cancellation')) }
    if ($script:ioAvailable) { [pscustomobject]@{ WriteTransferCount = 1000 } }
}
try {
    New-Item -ItemType Directory -Path $source, $excluded, (Join-Path $source 'nested') -Force | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $source 'a file.bin'), [byte[]](1..5))
    [IO.File]::WriteAllBytes((Join-Path $source 'nested\b.bin'), [byte[]](1..13))
    [IO.File]::WriteAllBytes((Join-Path $excluded 'excluded.bin'), [byte[]](1..100))
    $size = Measure-CopySource ($source + '\') @($excluded)
    Assert ($size.Files -eq 2 -and $size.Bytes -eq 18) 'Copy totals included excluded files or lost source files.'
    $hashes = @(Get-BundleFileHashes $source)
    Assert ($hashes.Count -eq 3) 'Checksum enumeration lost files.'
    foreach ($entry in $hashes) {
        Assert ($entry.Sha256 -eq (Get-FileHash -LiteralPath (Join-Path $source $entry.Path) -Algorithm SHA256).Hash) 'Progress reporting changed a checksum or relative path.'
    }
    Write-Host '[PASS] Copy totals respect exclusions, and checksum progress preserves all hashes.'

    # A deliberately slow native process exercises the polling loop and cleanup on cancellation.
    $script:stub = Join-Path $fixture 'copy-stub.exe'
    Add-Type -TypeDefinition @'
public static class CopyProgressStub {
    public static int Main(string[] args) {
        System.Threading.Thread.Sleep(1800);
        return int.Parse(System.Environment.GetEnvironmentVariable("ZEPHYR_TEST_COPY_EXIT"));
    }
}
'@ -OutputAssembly $script:stub -OutputType ConsoleApplication
    function Get-Command {
        param([string]$Name, [string]$ErrorAction)
        if ($Name -ne 'robocopy.exe') { throw "Unexpected executable lookup: $Name" }
        [pscustomobject]@{ Source = $script:stub }
    }
    $env:ZEPHYR_TEST_COPY_EXIT = '1'
    $script:events = @()
    Copy-Tree $source (Join-Path $fixture 'copy destination') @($excluded)
    Assert (@($script:events | Where-Object { $_.Activity -eq 'Copying files' -and $_.Percent -eq 99 -and -not $_.Completed }).Count -gt 0) 'Copy percentage was not clamped before native success.'
    Assert ($script:events[-1].Completed) 'Copy progress was not cleared after success.'
    $script:ioAvailable = $false
    $script:events = @()
    Copy-Tree $source (Join-Path $fixture 'copy destination') @($excluded)
    Assert (@($script:events | Where-Object { $_.Activity -eq 'Copying files' -and $_.Percent -eq -1 -and -not $_.Completed }).Count -gt 0) 'Unavailable I/O counters did not fall back to elapsed-time progress.'
    $env:ZEPHYR_TEST_COPY_EXIT = '8'
    $failure = ''
    try { Copy-Tree $source (Join-Path $fixture 'copy destination') @($excluded) } catch { $failure = $_.Exception.Message }
    Assert ($failure -like '*robocopy exit 8*') 'Native copy errors were hidden by progress reporting.'
    Assert ($script:events[-1].Completed) 'Copy progress was not cleared after failure.'
    $env:ZEPHYR_TEST_COPY_EXIT = '-1'
    $failure = ''
    try { Copy-Tree $source (Join-Path $fixture 'copy destination') @($excluded) } catch { $failure = $_.Exception.Message }
    Assert ($failure -like '*robocopy exit -1*') 'A terminated native copy was reported as successful.'
    Write-Host '[PASS] Copy progress handles native success, native failure and unavailable I/O counters.'

    $env:ZEPHYR_TEST_COPY_EXIT = '1'
    $script:cancelCopy = $true
    $failure = ''
    try { Copy-Tree $source (Join-Path $fixture 'copy destination') @($excluded) } catch { $failure = $_.Exception.Message }
    Assert ($failure -like '*Simulated copy cancellation*') 'Copy cancellation did not propagate.'
    Assert ($script:ownedPid -gt 0 -and -not (Get-Process -Id $script:ownedPid -ErrorAction SilentlyContinue)) 'Cancelled copy left its owned native process running.'
    Assert ($script:events[-1].Completed) 'Copy progress was not cleared after cancellation.'
    Write-Host '[PASS] Cancellation terminates the owned copy process and clears progress.'
    # Exercise the real dispatcher catch and exit status without starting a full bundle build.
    $dispatch = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.TryStatementAst] })[0]
    $consoleFunction = @($functions | Where-Object { $_.Name -eq 'Set-ConsoleUtf8' })[0]
    $cancelScript = Join-Path $fixture 'cancel-dispatch.ps1'
    $cancelSource = @(
        '$Mode = ''Pack''; $InstallDir = '''''
        ('$Root = ''' + $projectRoot.Replace("'", "''") + '''')
        '$originalOutputEncoding = [Console]::OutputEncoding'
        $consoleFunction.Extent.Text
        'function Write-PackProgress { param([switch]$Completed) }'
        'function New-Bundle { throw (New-Object OperationCanceledException(''Cancellation fixture'')) }'
        $dispatch.Extent.Text
    ) -join "`n"
    [IO.File]::WriteAllText($cancelScript, $cancelSource)
    $cancelOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cancelScript)
    Assert ($LASTEXITCODE -eq 130 -and ($cancelOutput -join "`n") -like '*[[]CANCELLED]*Cancellation fixture*') 'Dispatcher did not distinguish cancellation from success or a generic failure.'
    Write-Host '[PASS] Packaging cancellation reports CANCELLED and exits with status 130.'
    Write-Host 'All isolated packaging progress checks passed.'
} finally { Remove-Local $fixture (Join-Path $projectRoot 'offline_bundle') }
