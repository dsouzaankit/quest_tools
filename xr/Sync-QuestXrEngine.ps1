<#
.SYNOPSIS
  Copy the shared Quest XR engine (this folder) into a page that bundles its own copy, or check it.

.DESCRIPTION
  quest_tools\xr is the one editable copy of the XR player engine: xr-components.js, aframe.min.js
  (A-Frame 1.6.0, vendored) and aframe-LICENSE.txt. 3d_playlist_local serves this folder directly.
  ios_3d_loop_segments cannot: its IPA is built on GitHub Actions from that repo alone, so it keeps a
  generated copy in ios\LoopSegments\Resources. Run this after editing the engine, then commit the
  copy there (its deploy.ps1 runs -Check and stops on a stale copy, since the cloud build uses the
  pushed repo).

  Default -Target: ios_3d_loop_segments\ios\LoopSegments\Resources found next to this repo
  (<this repo's parent>\iOS apps\ios_3d_loop_segments, or $env:LOOPSEGMENTS_IOS_REPO).

  Compares text with line endings normalized (git may check files out CRLF or LF).
  Exit codes: 0 in sync (or copied), 1 -Check found differences, 2 target not found.

.EXAMPLE
  .\Sync-QuestXrEngine.ps1            # copy into the iOS Resources folder
.EXAMPLE
  .\Sync-QuestXrEngine.ps1 -Check     # report only
#>
[CmdletBinding()]
param(
    [string] $Target = '',
    [switch] $Check,
    [switch] $Quiet
)

$ErrorActionPreference = 'Stop'
$files = @('xr-components.js', 'aframe.min.js', 'aframe-LICENSE.txt')

if (-not $Target) {
    $repos = @($env:LOOPSEGMENTS_IOS_REPO, (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'iOS apps\ios_3d_loop_segments'))
    foreach ($r in $repos) {
        if ($r -and (Test-Path -LiteralPath (Join-Path $r 'ios\LoopSegments\Resources') -PathType Container)) {
            $Target = Join-Path $r 'ios\LoopSegments\Resources'
            break
        }
    }
}
if (-not $Target -or -not (Test-Path -LiteralPath $Target -PathType Container)) {
    Write-Host "XR engine: target folder not found ($Target) - pass -Target." -ForegroundColor Yellow
    exit 2
}

function Get-NormalizedText {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return ([System.IO.File]::ReadAllText($Path) -replace "`r`n", "`n")
}

$stale = @()
foreach ($f in $files) {
    $src = Join-Path $PSScriptRoot $f
    $dst = Join-Path $Target $f
    if ((Get-NormalizedText $src) -ne (Get-NormalizedText $dst)) { $stale += $f }
}

if (-not $stale.Count) {
    if (-not $Quiet) { Write-Host "XR engine: $Target is in sync with $PSScriptRoot." -ForegroundColor Green }
    exit 0
}
if ($Check) {
    Write-Host ("XR engine: {0} differs from quest_tools\xr in {1}. Run {2}, then commit the copy." -f ($stale -join ', '), $Target, $PSCommandPath) -ForegroundColor Yellow
    exit 1
}
foreach ($f in $stale) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $f) -Destination (Join-Path $Target $f) -Force
    Write-Host "XR engine: copied $f -> $Target"
}
exit 0
