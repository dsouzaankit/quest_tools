<#
.SYNOPSIS
  quest_tools after-quit history helper: waits for the headset to be worn, then deletes the history
  a quit could not (lib\QuestHistoryRetry.ps1).

.DESCRIPTION
  Started hidden and detached by Start-QuestHistoryRetry; everything it needs is in
  %TEMP%\loopsegments-quest-history-pending.json. Not meant to be run by hand (with nothing pending it
  just exits). Log: %TEMP%\loopsegments-quest-lantab.log ("History retry:" lines).
  Exit codes: 0 done / stopped / nothing pending, 1 gave up.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'QuestTools.ps1')
exit (Invoke-QuestHistoryRetryLoop)
