# Isolated filesystem checks; never install/uninstall shared tools or change HKCU.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path $PSScriptRoot
$scriptPath = Join-Path $projectRoot 'scripts\zephyr-manager.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
# Load the actual functions without executing the script's dispatch/exit block.
$functions = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)
. ([scriptblock]::Create(($functions | ForEach-Object { $_.Extent.Text }) -join "`n"))
$toolsAssignment = $ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -eq '$Tools' }
. ([scriptblock]::Create($toolsAssignment.Extent.Text))
$Root = Join-Path $projectRoot ('offline_bundle\test-' + [guid]::NewGuid().ToString('N'))
$fixtureRoot = $Root
$Workspace = Join-Path $Root 'zephyrproject'
$Cache = Join-Path $Root 'installers'
$Board = $Qualifier = $Toolchain = ''
$junctionPath = Join-Path $Workspace 'linked-module'
$script:registrationCalls = 0
function Clear-Registration { $script:registrationCalls++ }
function Read-Host([string]$Prompt) { return $script:answers.Dequeue() }
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Expect-Failure([scriptblock]$Action, [string]$Pattern) {
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_.Exception.Message }
    Assert ($null -ne $caught -and $caught -like $Pattern) "Expected failure '$Pattern', got '$caught'."
}
function Set-Answers([string[]]$Values) {
    $script:answers = New-Object 'System.Collections.Generic.Queue[string]'
    foreach ($value in $Values) { $script:answers.Enqueue($value) }
}

try {
    New-Item -ItemType Directory -Path "$Workspace\app", "$Workspace\.venv", "$Workspace\.west", "$Workspace\zephyr\scripts", "$Workspace\zephyr-sdk-0.17.0", "$Cache\wheels", "$Root\tools", "$Root\unrelated" -Force | Out-Null
    Set-Content -LiteralPath "$Workspace\app\user.c" -Value 'keep this source'
    Set-Content -LiteralPath "$Workspace\.venv\sentinel" -Value 'venv'
    Set-Content -LiteralPath "$Workspace\.west\config" -Value 'west config'
    Set-Content -LiteralPath "$Workspace\zephyr\scripts\requirements.txt" -Value 'west==1.0'
    Set-Content -LiteralPath "$Root\unrelated\sentinel" -Value 'unrelated source'
    Set-Content -LiteralPath "$Cache\requirements-frozen.txt" -Value 'west==1.0'
    Set-Content -LiteralPath "$Cache\wheels\dummy.whl" -Value 'fixture only'
    Set-Content -LiteralPath "$Workspace\zephyr-sdk-0.17.0\sdk_version" -Value '0.17.0'
    $originalHash = (Get-FileHash -LiteralPath "$Workspace\app\user.c").Hash
    $null = Assert-Within "$Workspace\app" $Root
    Expect-Failure { Assert-Within "$Root\..\outside" $Root } '*outside the expected*'
    Expect-Failure { Assert-Within ($Root + '-other\file') $Root } '*outside the expected*'
    Expect-Failure { Invoke-Checked 'cmd.exe' @('/c', 'exit', '7') } '*exit 7*'
    Write-Host '[PASS] Native errors propagate and deletion paths stay within their parent.'

    $settings = Get-Settings $Workspace
    Assert ($settings.Board -eq 'it51xxx_evb') 'Default board lost.'
    $Board = 'stm32f4_disco'; $Toolchain = 'arm-zephyr-eabi'
    $settings = Get-Settings $Workspace
    Assert ($settings.Qualifier -eq '' -and $settings.Toolchain -eq 'arm-zephyr-eabi') 'Custom board inherited ITE qualifier.'
    Save-Json $settings "$Workspace\.zephyr-setup.json"
    $Board = $Toolchain = ''
    Assert ((Get-Settings $Workspace).Board -eq 'stm32f4_disco') 'Stored board was not reused.'
    Write-Host '[PASS] Board/toolchain settings survive save and reload.'

    $copyTarget = Join-Path $Root 'copy'
    Copy-Tree $Workspace $copyTarget @("$Workspace\.venv")
    Assert (Test-Path -LiteralPath "$Workspace\.venv\sentinel") 'Copy removed source data.'
    Assert (Test-Path -LiteralPath "$copyTarget\.west\config") 'Copy omitted hidden west metadata.'
    Assert (-not (Test-Path -LiteralPath "$copyTarget\.venv")) 'Copy included virtual environment.'
    Write-Host '[PASS] Staging preserves source and hidden west metadata, excluding .venv.'

    $entries = @()
    foreach ($tool in $Tools) {
        $directory = Join-Path $Cache ('tools\' + $tool.Id)
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $installer = Join-Path $directory ('installer' + $tool.Extension)
        Set-Content -LiteralPath $installer -Value ('dummy ' + $tool.Id)
        $entries += @{ Id = $tool.Id; Path = $installer.Substring($Root.Length + 1); Sha256 = (Get-FileHash -LiteralPath $installer).Hash }
    }
    $payloadPath = 'zephyrproject\app\user.c'
    $manifest = @{ Format = 1; Python = '3.12'; Architecture = 'x64'; Sdk = 'zephyrproject\zephyr-sdk-0.17.0'; HostTools = $entries; Files = @(@{ Path = $payloadPath; Sha256 = $originalHash }) }
    Save-Json $manifest "$Root\bundle-manifest.json"
    $null = Test-Bundle
    Set-Content -LiteralPath "$Workspace\app\user.c" -Value 'tampered'
    Expect-Failure { Test-Bundle } '*damaged or modified*'
    Set-Content -LiteralPath "$Workspace\app\user.c" -Value 'keep this source'
    $manifest.HostTools = @($entries | Select-Object -Skip 1)
    Save-Json $manifest "$Root\bundle-manifest.json"
    Expect-Failure { Test-Bundle } '*missing installer metadata*'
    $manifest.HostTools = $entries
    $manifest.Files = @(@{ Path = '..\outside'; Sha256 = 'bad' })
    Save-Json $manifest "$Root\bundle-manifest.json"
    Expect-Failure { Test-Bundle } '*outside the expected*'
    Write-Host '[PASS] Bundle validation rejects tampering, missing installers and escaping paths.'

    foreach ($answer in @('', 'n', 'yes')) {
        Set-Answers @($answer)
        Uninstall-Zephyr
        Assert (Test-Path -LiteralPath "$Workspace\.venv\sentinel") 'Cancelled uninstall deleted files.'
        Assert ($script:registrationCalls -eq 0) 'Cancelled uninstall changed registration.'
    }
    Write-Host '[PASS] Enter/N/other answers cancel before any change.'

    New-Item -ItemType Junction -Path $junctionPath -Target "$Root\unrelated" | Out-Null
    Set-Answers @('y', 'n')
    Expect-Failure { Uninstall-Zephyr } '*Linked path is not supported*'
    Assert (Test-Path -LiteralPath "$Workspace\.venv\sentinel") 'Junction rejection happened after deletion.'
    [IO.Directory]::Delete($junctionPath)
    Set-Answers @('Y', 'n')
    Uninstall-Zephyr
    Assert ((Get-FileHash -LiteralPath "$Workspace\app\user.c").Hash -eq $originalHash) 'Application changed during uninstall.'
    Assert (-not (Test-Path -LiteralPath "$Workspace\.venv")) 'venv was not removed.'
    Assert (-not (Test-Path -LiteralPath "$Root\tools")) 'Local portable tools were not removed.'
    Assert (Test-Path -LiteralPath "$Root\unrelated\sentinel") 'Unrelated workspace was removed.'
    Assert (Test-Path -LiteralPath "$Cache\requirements-frozen.txt") 'Offline cache was removed.'
    Assert ($script:registrationCalls -eq 1) 'Registration cleanup was not called once.'
    Write-Host '[PASS] Confirmed uninstall preserves app, unrelated data and offline cache.'

    # Real batch wrappers propagate errors; no system installers are invoked.
    New-Item -ItemType Directory -Path "$Root\scripts" -Force | Out-Null
    Copy-Item -LiteralPath $scriptPath -Destination "$Root\scripts"
    foreach ($wrapper in @('zephyr-pack-offline.bat', 'zephyr-offline-install.bat')) { Copy-Item -LiteralPath (Join-Path $projectRoot $wrapper) -Destination $Root }
    Remove-Local "$Root\bundle-manifest.json" $Root
    $env:ZEPHYR_NO_PAUSE = '1'
    & cmd.exe /c "$Root\zephyr-offline-install.bat" -CheckOnly | Out-Host
    Assert ($LASTEXITCODE -eq 1) 'Offline wrapper lost error exit code.'
    & cmd.exe /c "$Root\zephyr-pack-offline.bat" -CacheOnly | Out-Host
    Assert ($LASTEXITCODE -eq 1) 'Pack wrapper lost error exit code.'
    Write-Host '[PASS] Batch entry points return exit 1 for incomplete environments.'

    # Verify legacy online positional parameters without running installers.
    Copy-Item -LiteralPath (Join-Path $projectRoot 'zephyr-easy-setup.bat') -Destination $Root
    @'
param([string]$Mode, [string]$Board, [string]$Qualifier, [string]$Toolchain, [string]$Revision, [string]$InstallDir, [switch]$CheckOnly)
@{Mode=$Mode;Board=$Board;Qualifier=$Qualifier;Toolchain=$Toolchain;Revision=$Revision;InstallDir=$InstallDir;CheckOnly=[bool]$CheckOnly} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'arguments.json')
exit 9
'@ | Set-Content -LiteralPath "$Root\scripts\zephyr-manager.ps1" -Encoding ASCII
    & cmd.exe /c "$Root\zephyr-easy-setup.bat" | Out-Host
    Assert ($LASTEXITCODE -eq 9) 'Default online wrapper lost exit status or empty parameters.'
    & cmd.exe /c "$Root\zephyr-easy-setup.bat" stm32f4_disco '""' arm-zephyr-eabi v4.1.0 | Out-Host
    Assert ($LASTEXITCODE -eq 9) 'Custom online wrapper lost exit status.'
    $arguments = Get-Content -LiteralPath "$Root\scripts\arguments.json" -Raw | ConvertFrom-Json
    Assert ($arguments.Board -eq 'stm32f4_disco' -and $arguments.Qualifier -eq '' -and $arguments.Toolchain -eq 'arm-zephyr-eabi' -and $arguments.Revision -eq 'v4.1.0') 'Positional arguments changed.'
    & cmd.exe /c "$Root\zephyr-easy-setup.bat" -InstallDir "$Root\custom-install" -Board stm32f4_disco -Toolchain arm-zephyr-eabi -CheckOnly | Out-Host
    Assert ($LASTEXITCODE -eq 9) 'Named online wrapper lost exit status.'
    $arguments = Get-Content -LiteralPath "$Root\scripts\arguments.json" -Raw | ConvertFrom-Json
    Assert ($arguments.InstallDir -eq "$Root\custom-install" -and $arguments.Board -eq 'stm32f4_disco' -and $arguments.CheckOnly) 'Named directory arguments changed.'
    Write-Host '[PASS] Online batch wrapper preserves defaults and custom positional arguments.'

    # A native stub verifies build exit-code handling, not Zephyr compilation.
    New-Item -ItemType Directory -Path "$Workspace\.venv\Scripts" -Force | Out-Null
    Add-Type -TypeDefinition @'
public static class BuildExitStub {
    public static int Main(string[] args) {
        return System.Environment.GetEnvironmentVariable("ZEPHYR_TEST_BUILD_SUCCESS") == "1" ? 0 : 8;
    }
}
'@ -OutputAssembly "$Workspace\.venv\Scripts\python.exe" -OutputType ConsoleApplication
    function Invoke-Checked([string]$Exe, [string[]]$Arguments) { }
    $settings = [pscustomobject]@{ Board = 'it51xxx_evb'; Qualifier = 'it51xxx_evb/it51526aw'; Toolchain = 'riscv64-zephyr-elf' }
    New-Item -ItemType Directory -Path "$Workspace\app\blinky" -Force | Out-Null
    Expect-Failure { Complete-Setup $settings "$Workspace\zephyr-sdk-0.17.0" } '*Sample build failed*'
    $env:ZEPHYR_TEST_BUILD_SUCCESS = '1'
    Complete-Setup $settings "$Workspace\zephyr-sdk-0.17.0"
    Assert ((Get-Settings $Workspace).SdkDirectory -eq 'zephyr-sdk-0.17.0') 'Relocated SDK settings became absolute.'
    Write-Host '[PASS] Failed builds stop setup; saved SDK path remains relocatable.'

    $fixtureRoot = $Root
    $PackageRoot = $projectRoot
    $InstallDir = ''
    Set-Answers @('')
    Select-InstallDirectory
    Assert ($Root -eq $projectRoot) 'Enter did not select the installer directory.'
    Set-Answers @("$fixtureRoot\prompt-install")
    Select-InstallDirectory
    Assert ($Workspace -eq "$fixtureRoot\prompt-install\zephyrproject") 'Prompt did not select the requested workspace.'
    $InstallDir = "$fixtureRoot\chosen-install"
    $CheckOnly = $true
    Install-Online
    Assert (-not (Test-Path -LiteralPath $Root)) 'Online path check wrote files.'
    $CheckOnly = $false
    Copy-InstallerPackage
    Assert (Test-Path -LiteralPath "$Root\scripts\zephyr-manager.ps1") 'Selected installation is missing its helper.'
    Assert (Test-Path -LiteralPath "$Root\zephyr-uninstall.bat") 'Selected installation is missing its uninstaller.'
    Assert (Test-Path -LiteralPath "$Root\tests\verify-workflows.ps1") 'Selected installation is missing its test suite.'
    # Selecting a drive root is read-only here; never install or uninstall there.
    $driveRoot = [IO.Path]::GetPathRoot($fixtureRoot)
    $InstallDir = $driveRoot
    Select-InstallDirectory
    Assert ($Root -eq $driveRoot) 'Drive root lost its absolute-path separator.'
    Assert ($Workspace -eq (Join-Path $driveRoot 'zephyrproject')) 'Drive-root workspace is incorrect.'
    Assert ($Cache -eq (Join-Path $driveRoot 'installers')) 'Drive-root cache is incorrect.'
    Assert ((Get-ToolsDirectory) -eq (Join-Path $Workspace '.host-tools')) 'Drive-root tools escaped the workspace.'
    Assert ((Get-RelativeBundlePath (Join-Path $Cache 'tools\installer.zip') $Root) -eq 'installers\tools\installer.zip') 'Drive-root bundle path lost a character.'
    Expect-Failure { Remove-Local $driveRoot $driveRoot } '*outside the expected*'
    $InstallDir = ''
    Set-Answers @($driveRoot)
    Select-InstallDirectory
    Assert ($Root -eq $driveRoot) 'Prompt rejected the drive root.'
    $PackageRoot = $driveRoot
    Set-Answers @('')
    Select-InstallDirectory
    Assert ($Root -eq $driveRoot) 'Installer at drive root changed its default installation path.'
    $PackageRoot = $projectRoot
    $output = @(& cmd.exe /c (Join-Path $projectRoot 'zephyr-easy-setup.bat') -InstallDir $driveRoot -CheckOnly)
    Assert ($LASTEXITCODE -eq 0) 'Actual launcher rejected the drive-root installation path.'
    Assert (($output -join "`n").Contains("Zephyr workspace:       $Workspace")) 'Actual launcher reported a wrong drive-root workspace.'
    Write-Host '[PASS] Drive-root selection keeps absolute paths, owned tools and complete bundle paths.'
    $InstallDir = "$fixtureRoot\path with spaces"
    Expect-Failure { Select-InstallDirectory } '*must not contain spaces*'
    $InstallDir = "$fixtureRoot\unrelated\sentinel"
    Expect-Failure { Select-InstallDirectory } '*is a file*'
    $InstallDir = "$fixtureRoot\install-link\new-child"
    New-Item -ItemType Junction -Path "$fixtureRoot\install-link" -Target "$fixtureRoot\unrelated" | Out-Null
    try { Expect-Failure { Select-InstallDirectory } '*Linked installation path*' }
    finally { [IO.Directory]::Delete("$fixtureRoot\install-link") }
    $Root = $fixtureRoot
    $Workspace = Join-Path $Root 'zephyrproject'
    $Cache = Join-Path $Root 'installers'
    Write-Host '[PASS] Install-directory prompt, named selection, path validation and copied launchers work.'

    $missing = Join-Path $fixtureRoot 'missing-helper'
    New-Item -ItemType Directory -Path $missing -Force | Out-Null
    foreach ($wrapper in @('zephyr-easy-setup.bat', 'zephyr-pack-offline.bat', 'zephyr-offline-install.bat', 'zephyr-uninstall.bat', 'zephyr-env.cmd')) {
        $destination = Join-Path $missing $wrapper
        Copy-Item -LiteralPath (Join-Path $projectRoot $wrapper) -Destination $destination
        $output = @(& cmd.exe /c $destination)
        Assert ($LASTEXITCODE -eq 1) 'Missing helper did not return exit 1.'
        Assert (($output -join "`n") -like '*Required helper script is missing*') 'Missing-helper guidance was not shown.'
        Assert (($output -join "`n") -notlike '*Windows PowerShell*') 'Missing helper launched PowerShell.'
    }
    Write-Host '[PASS] All launchers stop with guidance when the shared helper is missing.'
    Write-Host 'All isolated workflow checks passed.'
} finally {
    if (Test-Path -LiteralPath $junctionPath) { [IO.Directory]::Delete($junctionPath) }
    Remove-Local $fixtureRoot (Join-Path $projectRoot 'offline_bundle')
}
