# Real ZIP extraction with simulated system installers; no system tools or HKCU are changed.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path $PSScriptRoot
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot 'scripts\zephyr-manager.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$functions = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)
. ([scriptblock]::Create(($functions | ForEach-Object { $_.Extent.Text }) -join "`n"))
$assignment = $ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -eq '$Tools' }
. ([scriptblock]::Create($assignment.Extent.Text))
$command = Get-Command 7z.exe -ErrorAction SilentlyContinue
$script:sevenZipExe = if ($command) { $command.Source } else { Join-Path $env:ProgramFiles '7-Zip\7z.exe' }
if (-not (Test-Path -LiteralPath $script:sevenZipExe)) { throw '7-Zip is required for this integration check.' }
$fixture = Join-Path $projectRoot ('offline_bundle\bootstrap-test-' + [guid]::NewGuid().ToString('N'))
$PackageRoot = Join-Path $fixture 'media with spaces'
$Root = Join-Path $fixture 'destination'
$Workspace = Join-Path $Root 'zephyrproject'
$Cache = Join-Path $Root 'zephyr_installers'
$BundlePath = ''
$CheckOnly = $false
$Board = $Qualifier = $Toolchain = ''
$script:sevenZipInstalled = $false
$script:pythonInstalled = $false
$script:installerFailure = $false
$script:extractionFailure = $false
$script:events = New-Object 'System.Collections.Generic.List[string]'
$script:archiveFunction = ${function:Invoke-PackArchive}
$script:bundleFunction = ${function:Test-Bundle}
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Expect-Failure([scriptblock]$Action, [string]$Pattern) {
    $failure = ''
    try { & $Action } catch { $failure = $_.Exception.Message }
    Assert ($failure -like $Pattern) "Expected '$Pattern', got '$failure'."
}
function Refresh-Path { }
function Get-Command {
    param([string]$Name, [string]$ErrorAction)
    if ($Name -eq '7z.exe' -and $script:sevenZipInstalled) { [pscustomobject]@{ Source = $script:sevenZipExe } }
}
function Start-Installer {
    param([string]$Path, [string]$Arguments, [switch]$Msi)
    Assert (Test-Path -LiteralPath $Path -PathType Leaf) 'Installer was not provided locally.'
    if ($Path.EndsWith('7zip-x64.exe')) {
        Assert ($Arguments -eq '/S') 'Bootstrap did not silently install 7-Zip.'
        if ($script:installerFailure) { throw 'Simulated 7-Zip installer failure.' }
        $script:events.Add('install-7zip')
        $script:sevenZipInstalled = $true
    } else {
        $script:events.Add('install-package')
        if ($Arguments -like '*Include_pip*') { $script:pythonInstalled = $true }
    }
}
function Invoke-PackArchive {
    param([string]$Exe, [string[]]$Arguments, [string]$Activity)
    $script:events.Add('extract')
    if ($script:extractionFailure) { throw 'Simulated ZIP extraction failure.' }
    & $script:archiveFunction -Exe $Exe -Arguments $Arguments -Activity $Activity
}
function Test-Bundle {
    $script:events.Add('validate')
    & $script:bundleFunction
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
try {
    $source = Join-Path $fixture 'source'
    New-Item -ItemType Directory -Path $PackageRoot, $source -Force | Out-Null
    foreach ($relative in @('zephyrproject\.west', 'zephyrproject\zephyr\scripts', 'zephyrproject\app', 'zephyrproject\zephyr-sdk-0.17.0', 'zephyr_installers\wheels')) {
        New-Item -ItemType Directory -Path (Join-Path $source $relative) -Force | Out-Null
    }
    Set-Content -LiteralPath (Join-Path $source 'zephyrproject\.west\config') -Value 'west fixture'
    Set-Content -LiteralPath (Join-Path $source 'zephyrproject\zephyr\scripts\requirements.txt') -Value 'west==1.5.0'
    Set-Content -LiteralPath (Join-Path $source 'zephyrproject\app\user.c') -Value 'original app'
    Set-Content -LiteralPath (Join-Path $source 'zephyrproject\zephyr-sdk-0.17.0\sdk_version') -Value '0.17.0'
    Set-Content -LiteralPath (Join-Path $source 'zephyr_installers\wheels\west.whl') -Value 'wheel fixture'
    Set-Content -LiteralPath (Join-Path $source 'zephyr_installers\requirements-frozen.txt') -Value 'west==1.5.0'
    $entries = @()
    foreach ($tool in $Tools) {
        $directory = Join-Path $source ('zephyr_installers\tools\' + $tool.Id)
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $installer = Join-Path $directory ('installer' + $tool.Extension)
        Set-Content -LiteralPath $installer -Value ('installer fixture ' + $tool.Id)
        $entries += @{ Id = $tool.Id; Path = Get-RelativeBundlePath $installer $source; Sha256 = (Get-FileHash -LiteralPath $installer).Hash }
    }
    $manifest = @{ Format = 1; Python = '3.12'; Architecture = 'x64'; Sdk = 'zephyrproject\zephyr-sdk-0.17.0'; HostTools = $entries; Files = @(Get-BundleFileHashes $source) }
    Save-Json $manifest (Join-Path $source 'bundle-manifest.json')
    $archive = Join-Path $PackageRoot 'zephyr-offline-bundle.zip'
    Push-Location -LiteralPath $source
    try {
        & $script:sevenZipExe a -tzip -mx=0 -bso0 -bsp0 $archive '.\*'
        Assert ($LASTEXITCODE -eq 0) '7-Zip could not create the source bundle fixture.'
    } finally { Pop-Location }
    $bootstrap = Join-Path $PackageRoot 'zephyr-offline-bootstrap'
    $installerSource = Join-Path $source (@($entries | Where-Object Id -eq '7zip.7zip')[0].Path)
    Save-OfflineBootstrap $installerSource $bootstrap
    $script:installerFailure = $true
    Expect-Failure { Expand-OfflineBundle } '*7-Zip installer failure*'
    Assert ($script:events.Count -eq 0 -and -not (Test-Path -LiteralPath $Root)) 'Failed 7-Zip installation started extraction.'
    $script:installerFailure = $false
    $installer = Get-OfflineBootstrapInstaller $archive
    Assert ((Get-FileHash -LiteralPath $installer).Hash -eq (Get-FileHash -LiteralPath $installerSource).Hash) 'Published bootstrap changed the cached installer.'
    Set-Content -LiteralPath $installer -Value 'corrupted installer'
    Expect-Failure { Expand-OfflineBundle } '*bootstrap installer checksum failed*'
    Assert ($script:events.Count -eq 0 -and -not (Test-Path -LiteralPath $Root)) 'Corrupt bootstrap installed tools or extracted files.'
    Save-OfflineBootstrap $installerSource $bootstrap
    $CheckOnly = $true
    Expect-Failure { Expand-OfflineBundle } '*CheckOnly requires an extracted bundle*'
    Assert ($script:events.Count -eq 0 -and -not (Test-Path -LiteralPath $Root)) 'CheckOnly installed tools or extracted files.'
    $CheckOnly = $false
    Expand-OfflineBundle
    Assert ($script:events.Count -eq 2 -and $script:events[0] -eq 'install-7zip' -and $script:events[1] -eq 'extract') 'Extraction started before 7-Zip installation.'
    $null = Test-Bundle
    Assert ((Get-FileHash -LiteralPath (Join-Path $Workspace 'app\user.c')).Hash -eq (Get-FileHash -LiteralPath (Join-Path $source 'zephyrproject\app\user.c')).Hash) 'Real ZIP extraction changed the app.'
    $readyOutput = @(Use-OfflineSevenZip '' $archive 6>&1)
    Assert ($readyOutput.Count -eq 1 -and [string]$readyOutput[0] -eq $script:sevenZipExe) '7-Zip readiness check leaked format or codec lists.'

    # Run the drive-root branch, redirecting only native extraction into our owned fixture.
    & {
        $Root = [IO.Path]::GetPathRoot($fixture)
        $Workspace = Join-Path $Root 'zephyrproject'
        $Cache = Join-Path $Root 'zephyr_installers'
        $BundlePath = $archive
        $safeDestination = Join-Path $fixture 'drive-root-extracted'
        $script:driveRootExtracted = $false
        # Do not scan unrelated installations under the real drive root.
        function Assert-NoLinks { param([string]$Path) }
        function New-Item { param([string]$ItemType, [string]$Path, [switch]$Force); throw "Existing drive root must not be created: $Path" }
        function Invoke-PackArchive {
            param([string]$Exe, [string[]]$Arguments, [string]$Activity)
            $outputIndex = [Array]::IndexOf($Arguments, '-o' + $Root)
            Assert ($outputIndex -ge 0) 'Drive-root output path lost its trailing separator.'
            $safeArguments = [string[]]$Arguments.Clone()
            $safeArguments[$outputIndex] = '-o' + $safeDestination
            $null = [IO.Directory]::CreateDirectory($safeDestination)
            & $script:archiveFunction -Exe $Exe -Arguments $safeArguments -Activity $Activity
            $script:driveRootExtracted = $true
        }
        Expand-OfflineBundle
        Assert ($script:driveRootExtracted -and (Test-Path -LiteralPath (Join-Path $safeDestination 'zephyrproject\app\user.c'))) 'Drive-root branch did not reach real ZIP extraction.'
    }
    Write-Host '[PASS] Existing drive roots bypass directory creation and reach real extraction; 7-Zip readiness is quiet.'
    $script:events.Clear()
    Expand-OfflineBundle
    Assert ($script:events.Count -eq 0) 'An already extracted bundle was automatically extracted again.'
    $CheckOnly = $true
    Install-Offline
    Assert ($script:events.Count -eq 1 -and $script:events[0] -eq 'validate') 'Extracted CheckOnly installed packages or re-extracted the ZIP.'
    $CheckOnly = $false
    Write-Host '[PASS] Bootstrap checksum, read-only checks, automatic media discovery and real ZIP extraction.'

    $BundlePath = $archive
    $script:events.Clear()
    $script:extractionFailure = $true
    Expect-Failure { Install-Offline } '*ZIP extraction failure*'
    Assert ($script:events.Count -eq 1 -and $script:events[0] -eq 'extract') 'A failed extraction continued into validation or package installation.'
    $script:extractionFailure = $false

    # An explicit ZIP must preserve a modified app and fail validation before other installers.
    $BundlePath = $archive
    Set-Content -LiteralPath (Join-Path $Workspace 'app\user.c') -Value 'edited app'
    $script:events.Clear()
    Expect-Failure { Install-Offline } '*damaged or modified*'
    Assert ((Get-Content -LiteralPath (Join-Path $Workspace 'app\user.c')) -eq 'edited app') 'Re-extraction overwrote an existing app.'
    Assert (-not $script:events.Contains('install-package')) 'A checksum failure installed other packages.'
    $script:events.Clear()
    $BundlePath = Join-Path $PackageRoot 'missing.zip'
    Expect-Failure { Expand-OfflineBundle } '*Missing bundle ZIP*'
    Assert ($script:events.Count -eq 0) 'A missing ZIP started installation or extraction.'
    $badZip = Join-Path $PackageRoot 'bad.zip'
    $zip = [IO.Compression.ZipFile]::Open($badZip, [IO.Compression.ZipArchiveMode]::Create)
    try { $null = $zip.CreateEntry('bundle-manifest.json'); $null = $zip.CreateEntry('../outside.txt') } finally { $zip.Dispose() }
    $BundlePath = $badZip
    Expect-Failure { Expand-OfflineBundle } '*Unsupported bundle archive path*'
    Assert ($script:events.Count -eq 0) 'An escaping ZIP started installation or extraction.'
    $unrelatedZip = Join-Path $PackageRoot 'unrelated.zip'
    $zip = [IO.Compression.ZipFile]::Open($unrelatedZip, [IO.Compression.ZipArchiveMode]::Create)
    try { $null = $zip.CreateEntry('bundle-manifest.json'); $null = $zip.CreateEntry('tools/unrelated.txt') } finally { $zip.Dispose() }
    Expect-Failure { Assert-BundleArchive $unrelatedZip } '*Unexpected bundle archive path*'
    Write-Host '[PASS] Missing/unsafe ZIPs stop early; existing apps survive extraction and checksum failures stop package installation.'

    # Exercise the complete dispatcher ordering, replacing only system/tool installation work.
    Remove-Local $Root $fixture
    $script:sevenZipInstalled = $false
    $script:events.Clear()
    $BundlePath = $archive
    function Invoke-Checked {
        param([string]$Exe, [string[]]$Arguments)
        if ($Arguments -contains 'venv') {
            New-Item -ItemType Directory -Path (Join-Path $Workspace '.venv\Scripts') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $Workspace '.venv\Scripts\python.exe') -Value 'python fixture'
        }
    }
    function Get-Python312 {
        if (-not $script:pythonInstalled) { throw 'Python fixture is not installed yet.' }
        return 'python-fixture.exe'
    }
    function Test-HostTools { }
    function Save-HostPaths { }
    function Use-Workspace { param([string]$Source) }
    function Find-Sdk { param([string]$Source, [string]$Explicit, [string]$TargetToolchain); return $Explicit }
    function Complete-Setup { param($Settings, [string]$Sdk); $script:events.Add('complete') }
    Install-Offline
    Assert ($script:events[0] -eq 'install-7zip' -and $script:events[1] -eq 'extract' -and $script:events[2] -eq 'validate' -and $script:events[3] -eq 'install-package') 'Offline installation order is incorrect.'
    Assert (@($script:events | Where-Object { $_ -eq 'install-7zip' }).Count -eq 1) '7-Zip was installed twice.'
    Assert ($script:events[-1] -eq 'complete') 'Offline installation did not reach build verification.'

    # Already installed 7-Zip also supports legacy ZIPs without a bootstrap sidecar.
    Remove-Local $Root $fixture
    Remove-Local $bootstrap $PackageRoot
    $script:events.Clear()
    Expand-OfflineBundle
    Assert ($script:events.Count -eq 1 -and $script:events[0] -eq 'extract') 'An installed 7-Zip required a bootstrap installer.'
    Remove-Local $Root $fixture
    $script:sevenZipInstalled = $false
    $script:events.Clear()
    Expect-Failure { Expand-OfflineBundle } '*Copy zephyr-offline-bootstrap beside the ZIP*'
    Assert ($script:events.Count -eq 0 -and -not (Test-Path -LiteralPath $Root)) 'Missing bootstrap modified the destination.'
    Write-Host '[PASS] 7-Zip precedes extraction, validation and packages; installed 7-Zip is reused and missing bootstrap stops cleanly.'
    Write-Host 'All offline bootstrap integration checks passed.'
} finally { Remove-Local $fixture (Join-Path $projectRoot 'offline_bundle') }
