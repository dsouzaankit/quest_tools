# quest_tools: the shared log. Dot-sourced by QuestTools.ps1.
# One log for every Quest helper (Loop Segments companion, 3d_playlist_local, these scripts), so the
# file keeps its old name. Initialize-QuestTools -LogPath changes it for this process.

$script:QuestLogPath = Join-Path $env:TEMP 'loopsegments-quest-lantab.log'

function Write-QuestLog {
    param([string] $Message)
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try { Add-Content -LiteralPath $script:QuestLogPath -Value $line -Encoding utf8 } catch {}
    Write-Host "[quest] $Message"
}
