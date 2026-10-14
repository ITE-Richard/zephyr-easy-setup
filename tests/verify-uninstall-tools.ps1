# Check native WinGet exit handling using a stub; never uninstall real shared tools.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path $PSScriptRoot
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot 'scripts\zephyr-manager.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$functions = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)
. ([scriptblock]::Create(($functions | ForEach-Object { $_.Extent.Text }) -join "`n"))
$Root = Join-Path $projectRoot ('offline_bundle\uninstall-test-' + [guid]::NewGuid().ToString('N'))
$Workspace = Join-Path $Root 'zephyrproject'
$Tools = @(@{ Id = 'Fixture.Tool' })
$stub = Join-Path $Root 'winget-stub.exe'
function Refresh-Path { }
function Clear-Registration { }
function Get-Command([string]$Name, [string]$ErrorAction) {
    if ($Name -ne 'winget.exe') { throw "Unexpected lookup: $Name" }
    [pscustomobject]@{ Source = $stub }
}
function Read-Host([string]$Prompt) { return 'y' }
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$originalExit = [Environment]::GetEnvironmentVariable('ZEPHYR_TEST_UNINSTALL_EXIT')
try {
    New-Item -ItemType Directory -Path (Join-Path $Workspace 'app') -Force | Out-Null
    $appFile = Join-Path $Workspace 'app\user.c'
    Set-Content -LiteralPath $appFile -Value 'keep app'
    $appHash = (Get-FileHash -LiteralPath $appFile).Hash
    Add-Type -TypeDefinition @'
public static class UninstallToolStub {
    public static int Main(string[] args) {
        return int.Parse(System.Environment.GetEnvironmentVariable("ZEPHYR_TEST_UNINSTALL_EXIT"));
    }
}
'@ -OutputAssembly $stub -OutputType ConsoleApplication
    foreach ($code in @(0, -1978335212, -1978335184, 7)) {
        $env:ZEPHYR_TEST_UNINSTALL_EXIT = [string]$code
        Set-Content -LiteralPath (Join-Path $Workspace 'remove-me.txt') -Value 'workspace data'
        $script:failure = ''
        $output = @(& {
            try { Uninstall-Zephyr } catch { $script:failure = $_.Exception.Message }
        } 6>&1) -join "`n"
        if ($code -in @(0, -1978335212)) {
            Assert (-not $failure -and $output -like '*[[]SUCCESS]*') "Acceptable WinGet exit $code was treated as failure."
            if ($code -eq -1978335212) { Assert ($output -like '*[[]SKIP]*Fixture.Tool*') 'Missing package was not reported as skipped.' }
        } else {
            Assert ($failure -like '*shared tool removal failed: Fixture.Tool*') "Real WinGet failure $code was ignored."
            Assert ($output -notlike '*[[]SUCCESS]*') 'Tool removal failure reported complete success.'
        }
        Assert ((Get-FileHash -LiteralPath $appFile).Hash -eq $appHash) 'Uninstall modified the application.'
        Assert (-not (Test-Path -LiteralPath (Join-Path $Workspace 'remove-me.txt'))) 'Workspace content was not removed.'
    }
    Write-Host 'All isolated shared-tool uninstall checks passed.'
} finally {
    [Environment]::SetEnvironmentVariable('ZEPHYR_TEST_UNINSTALL_EXIT', $originalExit, 'Process')
    Remove-Local $Root (Join-Path $projectRoot 'offline_bundle')
}
