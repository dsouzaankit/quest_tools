<#
.SYNOPSIS
  Add (or remove) a project's tiles on the shared Quest control page, from any script.

.DESCRIPTION
  Command-line form of Register-QuestControlTiles / Unregister-QuestControlTiles (lib\QuestControl.ps1)
  for callers that do not load quest_tools themselves. The tiles show while -OwnerPid runs; the host
  (QuestControlHost.ps1) is started when none runs and exits once no registered owner is alive.
  Prints one JSON line { ok, port, pid, started, pcLink }.

.EXAMPLE
  pwsh -File Register-QuestControlTiles.ps1 -Owner loopsegments -OwnerPid 1234 -Module C:\...\LoopSegmentsControlTiles.ps1

.EXAMPLE
  pwsh -File Register-QuestControlTiles.ps1 -Owner loopsegments -Unregister
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Owner,
    [int] $OwnerPid = 0,
    [string] $Module = '',
    [switch] $Unregister
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'QuestTools.ps1')

if ($Unregister) {
    Unregister-QuestControlTiles -Owner $Owner
    Write-QuestLog "Control page: $Owner tiles removed."
    @{ ok = $true } | ConvertTo-Json -Compress
    exit 0
}
if ($OwnerPid -le 0 -or -not $Module -or -not (Test-Path -LiteralPath $Module -PathType Leaf)) {
    @{ ok = $false; error = '-OwnerPid and an existing -Module are required' } | ConvertTo-Json -Compress
    exit 2
}
$h = Register-QuestControlTiles -Owner $Owner -OwnerPid $OwnerPid -Module $Module
@{ ok = [bool]$h.Pid; port = $h.Port; pid = $h.Pid; started = $h.Started; pcLink = (Get-QuestControlPcLink) } | ConvertTo-Json -Compress
if ($h.Pid) { exit 0 } else { exit 1 }
