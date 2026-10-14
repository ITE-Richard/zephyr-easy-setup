# Verify the actual renderer with simulated terminal widths and captured host writes.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path $PSScriptRoot
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot 'scripts\zephyr-manager.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$functions = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)
. ([scriptblock]::Create(($functions | ForEach-Object { $_.Extent.Text }) -join "`n"))
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$script:terminalWidth = 79
$script:writes = New-Object 'System.Collections.Generic.List[object]'
function Get-PackConsoleWidth { return $script:terminalWidth }
function Write-Host {
    param([string]$Object, [switch]$NoNewline, $ForegroundColor, $BackgroundColor)
    Assert (-not $PSBoundParameters.ContainsKey('ForegroundColor') -and -not $PSBoundParameters.ContainsKey('BackgroundColor')) 'Progress changed terminal colors.'
    $script:writes.Add([pscustomobject]@{ Text = $Object; NoNewline = [bool]$NoNewline })
}

Write-PackProgress -Activity 'Copying files' -Status ('Long status ' * 20) -PercentComplete 81
Write-PackProgress -Activity 'Copying files' -Status 'Short' -PercentComplete 82
Assert ($script:writes.Count -eq 2) 'Interactive updates were skipped.'
foreach ($write in $script:writes) {
    Assert ($write.NoNewline -and $write.Text.StartsWith("`r") -and $write.Text.Length -eq 80) 'Progress wrapped or failed to overwrite the current row.'
    Assert (-not $write.Text.Contains("`n") -and -not $write.Text.Contains([string][char]27)) 'Progress used extra rows or terminal escape sequences.'
}
Assert ($script:writes[0].Text.StartsWith("`r81% [")) 'Numeric percentage was hidden behind a long status.'
Assert ($script:writes[1].Text.EndsWith(' ')) 'A shorter update did not erase the previous suffix.'
Write-PackProgress -Completed
Assert ($script:writes[2].Text -eq ("`r" + (' ' * 79) + "`r")) 'Completion did not clear the progress row before ordinary output.'
$count = $script:writes.Count
Write-PackProgress -Completed
Assert ($script:writes.Count -eq $count) 'Repeated cleanup wrote an extra row.'

$script:terminalWidth = 24
Write-PackProgress -Activity 'Computing SHA-256' -Status "Long`nstatus`ttext" -PercentComplete 100
Assert ($script:writes[-1].Text.Length -eq 25 -and $script:writes[-1].Text.StartsWith("`r100%")) 'A narrow terminal wrapped or lost its percentage.'
Write-PackProgress -Completed
Assert ((Get-PackProgressText 'Scanning' 'No total yet' -1 79).StartsWith('--%')) 'Unknown totals displayed a fabricated percentage.'
Assert (-not (Get-PackProgressText 'Copying' "First`nsecond" 0 79).Contains("`n")) 'Multiline status broke the single-row layout.'

$script:terminalWidth = 0
$script:writes.Clear()
Write-PackProgress -Activity 'Copying files' -Status 'Starting' -PercentComplete 0
Write-PackProgress -Activity 'Copying files' -Status 'Polling' -PercentComplete 1
Assert ($script:writes.Count -eq 1) 'Redirected progress flooded the log.'
$script:PackProgressState.LastLog = [datetime]::UtcNow.AddSeconds(-11)
Write-PackProgress -Activity 'Copying files' -Status 'Later' -PercentComplete 10
Write-PackProgress -Completed
foreach ($write in $script:writes) {
    Assert (-not $write.NoNewline -and -not $write.Text.Contains("`r") -and -not $write.Text.Contains([string][char]27)) 'Redirected output contained cursor controls.'
}
Assert ($script:writes.Count -eq 2) 'Redirected progress did not resume after its logging interval.'

$script:writes.Clear()
Set-PackStage 5 'Copy installers, workspace and SDK'
Assert ($script:writes.Count -eq 1 -and $script:writes[0].Text -eq '[PACK 5/9] 44% | Copy installers, workspace and SDK') 'Stage status created an overlay or lost its percentage.'
Microsoft.PowerShell.Utility\Write-Host 'All packaging terminal rendering checks passed.'
