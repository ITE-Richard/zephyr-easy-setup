# Progress must remain readable when native messages interleave or a terminal resizes.
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
Write-PackProgress -Activity 'Copying files' -Status 'Polling' -PercentComplete 82
Assert ($script:writes.Count -eq 1) 'Interactive progress flooded the terminal.'
Assert ($script:writes[0].Text.StartsWith('81% [') -and $script:writes[0].Text.Length -le 79) 'Progress wrapped or hid its percentage.'
$script:PackProgressState.LastLog = [datetime]::UtcNow.AddSeconds(-11)
Write-PackProgress -Activity 'Copying files' -Status 'Short' -PercentComplete 82
Assert ($script:writes.Count -eq 2 -and $script:writes[-1].Text.EndsWith('Short')) 'Progress did not resume after ten seconds or padded the row.'

# Reproduce a long pip message between updates, followed by a window shrink.
Write-Host ('Requirement already satisfied: package in D:\offline_bundle\wheel-test\Lib\site-packages ' * 3)
$nativeText = $script:writes[-1].Text
$script:terminalWidth = 24
$script:PackProgressState.LastLog = [datetime]::UtcNow.AddSeconds(-11)
Write-PackProgress -Activity 'Copying files' -Status 'After terminal resize' -PercentComplete 83
Assert ($script:writes.Count -eq 4 -and $script:writes[2].Text -eq $nativeText) 'Progress overwrote an intervening native message.'
Assert ($script:writes[-1].Text.Length -le 24 -and $script:writes[-1].Text.StartsWith('83%')) 'A resized terminal wrapped the progress line or lost its percentage.'
Write-PackProgress -Completed
Write-PackProgress -Completed
Assert ($script:writes.Count -eq 4) 'Completion emitted spaces or blank lines.'
Set-PackStage 5 'Copy installers, workspace and SDK'
Assert ($script:writes[-1].Text -eq '[PACK 5/9] 44% | Copy installers, workspace and SDK') 'Stage status was appended to progress or lost its percentage.'

$script:terminalWidth = 79
Write-PackProgress -Activity 'Create 7z archive' -Status 'Starting' -PercentComplete -1
Write-PackProgress -Activity 'Create 7z archive' -Status 'Completed' -PercentComplete 100
Assert ($script:writes[-1].Text.StartsWith('100%')) 'A quick operation suppressed its final completion percentage.'
$count = $script:writes.Count
Write-PackProgress -Activity 'Create 7z archive' -Status 'Completed' -PercentComplete 100
Assert ($script:writes.Count -eq $count) 'Duplicate completion flooded the terminal.'
Write-PackProgress -Completed

Assert ((Get-PackProgressText 'Scanning' 'No total yet' -1 79).StartsWith('--%')) 'Unknown totals displayed a fabricated percentage.'
$sanitized = Get-PackProgressText 'Copying' ("First`nsecond`t" + [char]27 + '[31m') 0 79
Assert (-not [regex]::IsMatch($sanitized, '[\x00-\x1f\x7f]')) 'Status included cursor controls or multiline text.'

foreach ($write in $script:writes) {
    Assert (-not $write.NoNewline -and -not [regex]::IsMatch($write.Text, '[\x00-\x1f\x7f]')) 'Interactive progress rewrote a row or emitted cursor controls.'
}
$script:terminalWidth = 0
$script:writes.Clear()
Write-PackProgress -Activity 'Copying files' -Status 'Starting' -PercentComplete 0
Write-PackProgress -Activity 'Copying files' -Status 'Polling' -PercentComplete 1
Assert ($script:writes.Count -eq 1) 'Redirected progress flooded the log.'
$script:PackProgressState.LastLog = [datetime]::UtcNow.AddSeconds(-11)
Write-PackProgress -Activity 'Copying files' -Status 'Later' -PercentComplete 10
Write-PackProgress -Completed
Assert ($script:writes.Count -eq 2) 'Redirected progress did not resume after its logging interval.'
foreach ($write in $script:writes) {
    Assert (-not $write.NoNewline -and -not [regex]::IsMatch($write.Text, '[\x00-\x1f\x7f]')) 'Redirected progress rewrote a row or emitted cursor controls.'
}
Microsoft.PowerShell.Utility\Write-Host 'All packaging terminal rendering checks passed.'
