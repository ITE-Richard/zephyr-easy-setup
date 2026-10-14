# Exercise the real 7-Zip process, archive contents and failure reporting in isolation.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path $PSScriptRoot
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot 'scripts\zephyr-manager.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$functions = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)
. ([scriptblock]::Create(($functions | ForEach-Object { $_.Extent.Text }) -join "`n"))
$sevenZip = Get-Command 7z.exe -ErrorAction SilentlyContinue
$exe = if ($sevenZip) { $sevenZip.Source } else { Join-Path $env:ProgramFiles '7-Zip\7z.exe' }
if (-not (Test-Path -LiteralPath $exe)) { throw '7-Zip is required for this integration check.' }
$fixture = Join-Path $projectRoot ('offline_bundle\archive-test-' + [guid]::NewGuid().ToString('N'))
$source = Join-Path $fixture 'source with spaces'
$zip = Join-Path $fixture 'archive with spaces.zip'
$script:events = New-Object 'System.Collections.Generic.List[object]'
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Write-PackProgress {
    param([string]$Activity, [string]$Status, [int]$PercentComplete = -1, [switch]$Completed)
    $script:events.Add([pscustomobject]@{ Activity = $Activity; Status = $Status; Percent = $PercentComplete; Completed = [bool]$Completed })
}
try {
    New-Item -ItemType Directory -Path (Join-Path $source 'nested'), (Join-Path $source 'empty') -Force | Out-Null
    $payload = Join-Path $source 'nested\a file.bin'
    $data = New-Object byte[] (4MB)
    (New-Object Random(42)).NextBytes($data)
    [IO.File]::WriteAllBytes($payload, $data)
    Set-Content -LiteralPath (Join-Path $source '.metadata') -Value 'hidden metadata'
    (Get-Item -LiteralPath (Join-Path $source '.metadata')).Attributes = [IO.FileAttributes]::Hidden
    Push-Location -LiteralPath $source
    try {
        $output = @(Invoke-PackArchive $exe @('a', '-tzip', '-mx=0', $zip, '.\*') 'Compress ZIP' 6>&1)
    } finally { Pop-Location }
    Assert ($output.Count -eq 0) 'Successful compression leaked native filenames or summaries.'
    $archiveDetails = @(& $exe l -slt $zip)
    Assert ($LASTEXITCODE -eq 0) 'Could not inspect ZIP compression methods.'
    $methods = @($archiveDetails | Where-Object { $_ -match '^Method = ' })
    Assert ($methods.Count -gt 0 -and @($methods | Where-Object { $_ -ne 'Method = Store' }).Count -eq 0) 'Speed-first ZIP unexpectedly compressed file contents.'
    $output = @(Invoke-PackArchive $exe @('t', $zip) 'Test ZIP integrity' 6>&1)
    Assert ($output.Count -eq 0) 'Successful ZIP testing leaked native filenames or summaries.'
    foreach ($activity in @('Compress ZIP', 'Test ZIP integrity')) {
        $activityEvents = @($script:events | Where-Object { $_.Activity -eq $activity })
        Assert ($activityEvents.Count -ge 2 -and $activityEvents[-1].Percent -eq 100) "Archive progress never completed for ${activity}."
        Assert (@($activityEvents | Where-Object { $_.Status -match 'a file|metadata|source with spaces' }).Count -eq 0) 'File operations reached the progress UI.'
    }
    $destination = Join-Path $fixture 'extracted'
    & $exe x -y -bso0 -bsp0 ("-o$destination") $zip
    Assert ($LASTEXITCODE -eq 0) 'Archive extraction failed.'
    Assert ((Get-FileHash -LiteralPath $payload).Hash -eq (Get-FileHash -LiteralPath (Join-Path $destination 'nested\a file.bin')).Hash) 'Archive contents changed.'
    Assert (Test-Path -LiteralPath (Join-Path $destination '.metadata')) 'Hidden metadata was omitted.'
    Assert (Test-Path -LiteralPath (Join-Path $destination 'empty') -PathType Container) 'Empty directory was omitted.'
    $failure = ''
    $diagnostics = @(& {
        try { Invoke-PackArchive $exe @('t', (Join-Path $fixture 'missing.zip')) 'Test ZIP integrity' }
        catch { $script:failure = $_.Exception.Message }
    } 6>&1)
    Assert ($failure -like '*failed (exit *') 'A failed ZIP check was reported as successful.'
    Assert (($diagnostics -join "`n") -match 'ERROR') 'Native ZIP diagnostics were hidden.'
    Assert ($script:events[-1].Completed) 'Failed ZIP testing left progress active.'

    # A slow process checks timely updates, split reads, stderr draining and owned-process cleanup.
    $stubName = 'archive-stub-' + [guid]::NewGuid().ToString('N')
    $stub = Join-Path $fixture ($stubName + '.exe')
    Add-Type -TypeDefinition @'
public static class ArchiveProgressStub {
    public static int Main(string[] args) {
        System.Console.Write("\r 4");
        System.Console.Out.Flush();
        System.Threading.Thread.Sleep(200);
        System.Console.Write("2% 123 + secret-filename.c\r");
        System.Console.Out.Flush();
        System.Console.Error.WriteLine("WARNING: " + new string('x', 100000));
        System.Threading.Thread.Sleep(1400);
        return 0;
    }
}
'@ -OutputAssembly $stub -OutputType ConsoleApplication
    $output = @(Invoke-PackArchive $stub @() 'Streaming fixture' 6>&1)
    Assert (@($script:events | Where-Object { $_.Activity -eq 'Streaming fixture' -and $_.Percent -eq 42 }).Count -gt 0) 'Split progress was buffered until process exit or parsed incorrectly.'
    Assert (($output -join "`n") -like '*WARNING:*' -and ($output -join "`n") -notlike '*secret-filename*') 'Warnings were lost or native file output leaked.'
    $script:cancelledPid = 0
    function Read-CopyCancellation {
        $ownedProcess = Get-Process -Name $stubName -ErrorAction SilentlyContinue
        if ($ownedProcess) {
            $script:cancelledPid = $ownedProcess.Id
            throw (New-Object OperationCanceledException('Archive cancellation fixture'))
        }
    }
    $failure = ''
    try { Invoke-PackArchive $stub @() 'Cancellation fixture' } catch { $failure = $_.Exception.Message }
    Assert ($failure -eq 'Archive cancellation fixture') 'Archive cancellation did not propagate.'
    Assert ($script:cancelledPid -gt 0 -and -not (Get-Process -Id $script:cancelledPid -ErrorAction SilentlyContinue)) 'Archive cancellation left the owned process running.'
    Assert ($script:events[-1].Completed) 'Archive cancellation left progress active.'
    Write-Host 'All isolated archive integration checks passed.'
} finally { Remove-Local $fixture (Join-Path $projectRoot 'offline_bundle') }
