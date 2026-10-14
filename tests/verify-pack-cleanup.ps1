# Real 7z publishing with simulated Python checks; no system installations or HKCU writes.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path $PSScriptRoot
$tokens = $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot 'scripts\zephyr-manager.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$functions = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)
. ([scriptblock]::Create(($functions | ForEach-Object { $_.Extent.Text }) -join "`n"))
$assignment = $ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -eq '$Tools' }
. ([scriptblock]::Create($assignment.Extent.Text))
$command = Get-Command 7z.exe -ErrorAction SilentlyContinue
if (-not $command) { throw '7-Zip is required for this integration check.' }
$script:sevenZipExe = $command.Source
$script:installer = Join-Path $projectRoot '7zip-x64.exe'
if (-not (Test-Path -LiteralPath $script:installer)) { throw 'The matching 7zip-x64.exe is required for this integration check.' }
$fixture = Join-Path $projectRoot ('offline_bundle\cleanup-test-' + [guid]::NewGuid().ToString('N'))
$Root = Join-Path $fixture 'output'
$PackageRoot = Join-Path $fixture 'launcher'
$SourceWorkspace = Join-Path $fixture 'source'
$Workspace = Join-Path $Root 'zephyrproject'
$Cache = Join-Path $Root 'zephyr_installers'
$SdkPath = Join-Path $SourceWorkspace 'zephyr-sdk-0.17.0'
$Board = $Qualifier = $Toolchain = ''
$CacheOnly = $false
$script:failure = ''
$script:checked = ${function:Invoke-Checked}
$script:archive = ${function:Invoke-PackArchive}
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Refresh-Path { }
function Use-Workspace { param([string]$Source) }
function Find-Sdk { param([string]$Source, [string]$Explicit, [string]$TargetToolchain); return $Explicit }
function Invoke-Checked {
    param([string]$Exe, [string[]]$Arguments)
    if ($Exe -ne (Join-Path $SourceWorkspace '.venv\Scripts\python.exe') -and $Exe -notlike '*wheel-test\Scripts\python.exe') {
        & $script:checked $Exe $Arguments
    }
}
function Save-PythonWheelCache {
    param([string]$Python, [string]$Directory, [switch]$CacheOnly)
    New-Item -ItemType Directory -Path (Join-Path $Directory 'wheels') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $Directory 'wheels\west.whl') -Value 'wheel fixture'
    foreach ($name in @('requirements-source.txt', 'requirements-frozen.txt')) {
        Set-Content -LiteralPath (Join-Path $Directory $name) -Value 'west==1.5.0'
    }
    return Join-Path $Directory 'requirements-frozen.txt'
}
function Get-HostInstaller {
    param($Tool, [string]$Directory, [switch]$CacheOnly)
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    $path = Join-Path $Directory ('installer' + $Tool.Extension)
    if ($Tool.Id -eq '7zip.7zip') { Copy-Item -LiteralPath $script:installer -Destination $path -Force }
    else { Set-Content -LiteralPath $path -Value 'installer fixture' }
    return Get-Item -LiteralPath $path
}
function Invoke-PackArchive {
    param([string]$Exe, [string[]]$Arguments, [string]$Activity)
    if ($script:failure -and $Arguments[0] -eq 'a') {
        Set-Content -LiteralPath $Arguments[3] -Value 'partial archive'
        if ($script:failure -eq 'cancel') { throw [OperationCanceledException]::new('Simulated cancellation.') }
        throw 'Simulated archive failure.'
    }
    & $script:archive $Exe $Arguments $Activity
}
try {
    foreach ($relative in @('.venv\Scripts', '.west', 'zephyr\scripts', 'app', 'zephyr-sdk-0.17.0')) {
        New-Item -ItemType Directory -Path (Join-Path $SourceWorkspace $relative) -Force | Out-Null
    }
    New-Item -ItemType Directory -Path $Root, $PackageRoot -Force | Out-Null
    Add-Type -TypeDefinition 'public static class PackPythonStub { public static int Main(string[] args) { return 0; } }' -OutputAssembly (Join-Path $SourceWorkspace '.venv\Scripts\python.exe') -OutputType ConsoleApplication
    Set-Content -LiteralPath (Join-Path $SourceWorkspace '.west\config') -Value 'west fixture'
    Set-Content -LiteralPath (Join-Path $SourceWorkspace 'zephyr\scripts\requirements.txt') -Value 'west==1.5.0'
    Set-Content -LiteralPath (Join-Path $SdkPath 'sdk_version') -Value '0.17.0'
    Set-Content -LiteralPath (Join-Path $SourceWorkspace 'app\user.c') -Value 'keep the source app'
    Save-OfflineBootstrap $script:installer (Join-Path $Root 'zephyr-offline-bootstrap')
    New-Bundle
    $archivePath = Join-Path $Root 'zephyr-offline-bundle.7z'
    Assert (Test-Path -LiteralPath $archivePath) '7z archive was not published.'
    Assert (-not (Test-Path -LiteralPath (Join-Path $Root 'offline_bundle'))) 'Successful pack left its new temporary parent directory.'
    Assert (-not (Test-Path -LiteralPath $Cache)) 'Successful pack left installer/wheel cache outside the archive.'
    Assert (-not (Test-Path -LiteralPath (Join-Path $Root 'zephyr-offline-bootstrap'))) 'Successful pack left the redundant bootstrap directory.'
    Assert ((Get-FileHash -LiteralPath (Join-Path $PackageRoot '7zip-x64.exe')).Hash -eq (Get-FileHash -LiteralPath $script:installer).Hash) 'Published installer differs from the bundled version.'
    Assert-ArchiveInstaller $archivePath $script:sevenZipExe (Join-Path $PackageRoot '7zip-x64.exe')
    $publishedHash = (Get-FileHash -LiteralPath $archivePath).Hash
    $parent = Join-Path $Root 'offline_bundle'
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $parent 'existing.txt') -Value 'keep unrelated files'
    foreach ($failure in @('error', 'cancel')) {
        $script:failure = $failure
        $caught = ''
        try { New-Bundle } catch { $caught = $_.Exception.Message }
        Assert ($caught -like 'Simulated *') 'Failure or cancellation did not propagate.'
        Assert ((Get-FileHash -LiteralPath $archivePath).Hash -eq $publishedHash) 'Failure replaced the previous published archive.'
        Assert (@(Get-ChildItem -LiteralPath $parent -Force).Count -eq 1) 'Failure/cancellation left temporary files or removed unrelated files.'
        Assert ((Get-Content -LiteralPath (Join-Path $parent 'existing.txt')) -eq 'keep unrelated files') 'Cleanup changed unrelated files.'
        Assert (Test-Path -LiteralPath $Cache) 'Failed packaging removed inputs needed for a retry.'
    }
    # Cleanup must reject cache changes and unrelated bootstrap files before deleting anything.
    $script:failure = ''
    $files = @(Get-ChildItem -LiteralPath $Cache -File -Recurse | ForEach-Object { [pscustomobject]@{ Path = Get-RelativeBundlePath $_.FullName $Root; Sha256 = (Get-FileHash -LiteralPath $_.FullName).Hash } })
    Set-Content -LiteralPath (Join-Path $Cache 'new-file.txt') -Value 'not in the published archive'
    $caught = ''
    try { Remove-PackInputs $files (Get-FileHash -LiteralPath $script:installer).Hash } catch { $caught = $_.Exception.Message }
    Assert ($caught -like '*Cache changed after packaging*' -and (Test-Path -LiteralPath $Cache)) 'Cleanup removed unpublished cache changes.'
    Remove-Item -LiteralPath (Join-Path $Cache 'new-file.txt') -Force
    Save-OfflineBootstrap $script:installer (Join-Path $Root 'zephyr-offline-bootstrap')
    Set-Content -LiteralPath (Join-Path $Root 'zephyr-offline-bootstrap\user.txt') -Value 'keep unrelated bootstrap file'
    $caught = ''
    try { Remove-PackInputs $files (Get-FileHash -LiteralPath $script:installer).Hash } catch { $caught = $_.Exception.Message }
    Assert ($caught -like '*Bootstrap contains unrelated files*' -and (Test-Path -LiteralPath $Cache)) 'Cleanup removed inputs before detecting unrelated bootstrap files.'
    Write-Host '[PASS] Real 7z publishing uses the bundled installer; success, failure and cancellation clean staging while preserving outputs and unrelated files.'
} finally { Remove-Local $fixture (Join-Path $projectRoot 'offline_bundle') }
