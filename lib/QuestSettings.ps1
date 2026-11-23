# quest_tools settings: quest_tools\quest-tools.json (per PC, git-ignored; quest-tools.example.json
# lists every key). A key missing there falls back to the matching quest* key of the older shared
# file, ios_3d_loop_segments\windows\loop-segments-windows.json (read as plain JSON), then to the
# default below. Re-read on every call (cheap; a running helper picks up an edit).
#
#   adbExe / adbSerial / adbHost / adbPort / adbRediscoverSec   adb and finding the headset
#   controlPort           Quest control page host (QuestControlHost.ps1); the after-quit helper page
#                         falls back to controlPort + 1
#   closeTabsOnExit       session cleanup closes the registered pages' tabs
#   clearHistoryOnExit    ... and deletes their history
#   clearHistoryFallback  history range deleted when the per-entry delete fails: '' | hour | day | week | fourweeks | all
#   historyRetryMinutes   how long the after-quit helper waits for the headset to be worn
#   wifiOffOnExit         switch the headset's Wi-Fi off at the end of the cleanup
#   ensureInsecureOriginFlag  fix Quest Browser's insecure-origin flag when a page opened is not a secure context

$script:QuestSettingsPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'quest-tools.json'

$script:QuestSettingsDefaults = [ordered]@{
    adbExe                   = ''
    adbSerial                = ''
    adbHost                  = ''
    adbPort                  = 5555
    adbRediscoverSec         = 60
    controlPort              = 18766
    closeTabsOnExit          = $true
    clearHistoryOnExit       = $true
    clearHistoryFallback     = 'day'
    historyRetryMinutes      = 120
    wifiOffOnExit            = $true
    ensureInsecureOriginFlag = $true
}

# quest_tools key -> the older loop-segments-windows.json key.
$script:QuestSettingsLegacyKeys = [ordered]@{
    adbExe                   = 'questAdbExe'
    adbSerial                = 'questAdbSerial'
    adbHost                  = 'questAdbHost'
    adbPort                  = 'questAdbPort'
    adbRediscoverSec         = 'questAdbRediscoverSec'
    controlPort              = 'questControlPort'
    closeTabsOnExit          = 'questCloseLanTabsOnExit'
    clearHistoryOnExit       = 'questClearHistoryOnExit'
    clearHistoryFallback     = 'questClearHistoryFallback'
    historyRetryMinutes      = 'questHistoryRetryMinutes'
    wifiOffOnExit            = 'questWifiOffOnExit'
    ensureInsecureOriginFlag = 'questEnsureInsecureOriginFlag'
}

# The older shared settings file, if a Loop Segments checkout is around: $env:LOOPSEGMENTS_IOS_REPO,
# <ALL_SCRIPTS_ROOT>\iOS apps\ios_3d_loop_segments, next to this repo, then P:\all_scripts.
function Get-QuestLegacySettingsPath {
    $roots = @($env:LOOPSEGMENTS_IOS_REPO)
    if ($env:ALL_SCRIPTS_ROOT) { $roots += (Join-Path $env:ALL_SCRIPTS_ROOT 'iOS apps\ios_3d_loop_segments') }
    $roots += (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'iOS apps\ios_3d_loop_segments')
    $roots += 'P:\all_scripts\iOS apps\ios_3d_loop_segments'
    foreach ($r in $roots) {
        if ([string]::IsNullOrWhiteSpace($r)) { continue }
        $p = Join-Path $r 'windows\loop-segments-windows.json'
        if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
    }
    return $null
}

function Read-QuestJsonFile {
    param([string] $Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json) } catch {
        Write-QuestLog "Settings: could not read $Path ($($_.Exception.Message))."
        return $null
    }
}

# Merged settings as an ordered hashtable (every key present).
function Get-QuestToolsSettings {
    $own = Read-QuestJsonFile -Path $script:QuestSettingsPath
    $legacy = Read-QuestJsonFile -Path (Get-QuestLegacySettingsPath)
    $out = [ordered]@{}
    foreach ($k in $script:QuestSettingsDefaults.Keys) {
        $v = $script:QuestSettingsDefaults[$k]
        $old = $script:QuestSettingsLegacyKeys[$k]
        if ($legacy -and $old -and $legacy.PSObject.Properties[$old] -and $null -ne $legacy.$old) { $v = $legacy.$old }
        if ($own -and $own.PSObject.Properties[$k] -and $null -ne $own.$k) { $v = $own.$k }
        $out[$k] = $v
    }
    return $out
}

# Initialize-QuestTools from the settings; non-empty arguments win.
function Initialize-QuestToolsFromSettings {
    param([string] $AdbExe = '', [string] $Serial = '', [string] $QuestHost = '', [int] $Port = 0)
    $s = Get-QuestToolsSettings
    if (-not $AdbExe) { $AdbExe = [string]$s.adbExe }
    if (-not $Serial) { $Serial = [string]$s.adbSerial }
    if (-not $QuestHost) { $QuestHost = [string]$s.adbHost }
    if ($Port -le 0) { $Port = [int]$s.adbPort }
    Initialize-QuestTools -AdbExe $AdbExe -Serial $Serial -QuestHost $QuestHost -Port $Port -RediscoverSec ([int]$s.adbRediscoverSec)
}

# History fallback range for Invoke-QuestBrowserCleanup / the after-quit helper ('' = none).
function Get-QuestHistoryFallbackRange {
    $raw = ([string](Get-QuestToolsSettings).clearHistoryFallback).Trim().ToLowerInvariant()
    if (@('', 'none', 'off', 'false') -contains $raw) { return '' }
    if (@('hour', 'day', 'week', 'fourweeks', 'all') -contains $raw) { return $raw }
    Write-QuestLog "History: clearHistoryFallback '$raw' unknown - using 'day'."
    return 'day'
}
