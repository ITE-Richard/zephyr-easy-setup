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
param([string]$Mode, [string]$Board, [string]$Qualifier, [string]$Toolchain, [string]$Revision)
@{Mode=$Mode;Board=$Board;Qualifier=$Qualifier;Toolchain=$Toolchain;Revision=$Revision} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'arguments.json')
exit 9
'@ | Set-Content -LiteralPath "$Root\scripts\zephyr-manager.ps1" -Encoding ASCII
    & cmd.exe /c "$Root\zephyr-easy-setup.bat" | Out-Host
    Assert ($LASTEXITCODE -eq 9) 'Default online wrapper lost exit status or empty parameters.'
    & cmd.exe /c "$Root\zephyr-easy-setup.bat" stm32f4_disco '""' arm-zephyr-eabi v4.1.0 | Out-Host
    Assert ($LASTEXITCODE -eq 9) 'Custom online wrapper lost exit status.'
    $arguments = Get-Content -LiteralPath "$Root\scripts\arguments.json" -Raw | ConvertFrom-Json
    Assert ($arguments.Board -eq 'stm32f4_disco' -and $arguments.Qualifier -eq '' -and $arguments.Toolchain -eq 'arm-zephyr-eabi' -and $arguments.Revision -eq 'v4.1.0') 'Positional arguments changed.'
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
    Write-Host 'All isolated workflow checks passed.'
} finally {
    if (Test-Path -LiteralPath $junctionPath) { [IO.Directory]::Delete($junctionPath) }
    Remove-Local $Root (Join-Path $projectRoot 'offline_bundle')
}
