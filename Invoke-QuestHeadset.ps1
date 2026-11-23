<#
.SYNOPSIS
  Generic Meta Quest headset actions over adb: status, adb server reset, proximity sensor, Wi-Fi,
  keep-awake, the Quest control page, end-of-session cleanup.

.DESCRIPTION
  One mode per run:
  -Status          (default; read-only) find the headset on adb (connecting if needed: last known
                   address, -QuestHost, mDNS) and print adb path, serial, wakefulness, proximity
                   override. Exit 1 when it is not on adb.
  -ResetAdb        restart the PC's adb server (kill-server, else kill a stuck adb.exe), then look for
                   the headset again. Every adb client on this PC (a running companion, a workflow)
                   loses adb for a few seconds.
  -EnableProximity / -DisableProximity / -ToggleProximity
                   proximity sensor on (sleeps when taken off) / held off (`prox_close`: stays awake
                   and on adb) / flipped. Set-QuestProximitySensor.ps1 wraps them.
  -WifiOff         switch the headset's Wi-Fi off (Settings > Wi-Fi opened first on an awake headset);
                   adb drops right after. Set-QuestWifiOff.ps1 wraps it.
  -KeepAwakeSession -ParentPid N [-RestoreProximity]
                   until process N exits, hold the sensor off whenever the headset is awake
                   (see Invoke-QuestKeepAwakeSession in lib\QuestDevice.ps1).
  -OpenControlPage [-ParentPid N] [-WaitMinutes M] [-StatusFile F]
                   wait for an awake headset (M minutes; 0 with -ParentPid = until process N exits),
                   then open the Quest control page there, signed in (lib\QuestControl.ps1).
                   -StatusFile gets checking / queued / opening, then opened / failed / unreachable /
                   cancelled. Exit 0 opened, 1 headset not awake in time, 3 failed.
  -Cleanup [-CloseTabs|-KeepTabs] [-SkipHistory] [-KeepProximity] [-WifiOff|-KeepWifi]
           [-ExtraOrigins a,b] [-HelperUrl U] [-StopIfCommandLine regex]
                   end of a session (lib\QuestSession.ps1): our tabs closed, their history deleted,
                   sensor back on, Wi-Fi off. Unset choices follow quest-tools.json (closeTabsOnExit,
                   clearHistoryOnExit, wifiOffOnExit). Exit 0 done, 1 headset not on adb (handed to
                   the after-quit helper), 3 incomplete, 4 history delete postponed.

  adb settings not given here come from quest-tools.json (lib\QuestSettings.ps1).
  Finding the headset: quest_tools\README.md ("How the PC finds the headset").
  Log: %TEMP%\loopsegments-quest-lantab.log
  Exit codes: 0 ok, 1 headset not reachable, 2 no adb or bad arguments, 3 step failed.

.EXAMPLE
  .\Invoke-QuestHeadset.ps1

.EXAMPLE
  .\Invoke-QuestHeadset.ps1 -DisableProximity -QuestHost 10.0.100.238

.EXAMPLE
  .\Invoke-QuestHeadset.ps1 -Cleanup
#>
[CmdletBinding()]
param(
    [switch] $Status,
    [switch] $ResetAdb,
    [switch] $EnableProximity,
    [switch] $DisableProximity,
    [switch] $ToggleProximity,
    [switch] $WifiOff,
    [switch] $KeepAwakeSession,
    [switch] $OpenControlPage,
    [switch] $Cleanup,
    [int] $ParentPid = 0,
    [switch] $RestoreProximity,
    [double] $WaitMinutes = 0,
    [int] $PollSeconds = 5,
    [string] $StatusFile = '',
    [switch] $CloseTabs,
    [switch] $KeepTabs,
    [switch] $SkipHistory,
    [switch] $KeepProximity,
    [switch] $KeepWifi,
    [string[]] $ExtraOrigins = @(),
    [string] $HelperUrl = '',
    [string] $StopIfCommandLine = '',
    [string] $AdbExe = '',
    [string] $Serial = '',
    [string] $QuestHost = '',
    [int] $Port = 0,
    [int] $RediscoverSec = -1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$startedAt = [DateTime]::UtcNow

. (Join-Path $PSScriptRoot 'QuestTools.ps1')
Initialize-QuestToolsFromSettings -AdbExe $AdbExe -Serial $Serial -QuestHost $QuestHost -Port $Port
if ($RediscoverSec -ge 0) { $script:AdbRediscoverSec = $RediscoverSec }

function Set-HeadsetStatus {
    param([string] $Value)
    if ([string]::IsNullOrWhiteSpace($StatusFile)) { return }
    try { Set-Content -LiteralPath $StatusFile -Value $Value -Encoding ascii } catch {}
}

# -WifiOff is a mode alone, and a step of -Cleanup.
$modes = @($ResetAdb, $EnableProximity, $DisableProximity, $ToggleProximity, ($WifiOff -and -not $Cleanup), $KeepAwakeSession, $OpenControlPage, $Cleanup) | Where-Object { $_ }
if (@($modes).Count -gt 1) { Write-QuestLog 'Invoke-QuestHeadset: pick one mode.'; exit 2 }

$script:Adb = Find-QuestAdbExe
if (-not $script:Adb) {
    Write-QuestLog 'adb not found (winget install Google.PlatformTools, or set adbExe in quest-tools.json).'
    Set-HeadsetStatus 'failed'
    exit 2
}

function Get-QuestHeadsetSerial {
    $d = Get-OnlineQuestSerial
    if (-not $d) { $d = Connect-Quest }
    return $d
}

if ($EnableProximity) { exit (Invoke-QuestEnableProximity) }
if ($DisableProximity) { exit (Invoke-QuestDisableProximity) }
if ($ToggleProximity) { exit (Invoke-QuestToggleProximity) }
if ($KeepAwakeSession) { exit (Invoke-QuestKeepAwakeSession -ParentPid $ParentPid -RestoreProximity:$RestoreProximity) }
if ($OpenControlPage) {
    $w = Wait-QuestHeadsetAwake -WaitMinutes $WaitMinutes -ParentPid $ParentPid -PollSeconds $PollSeconds -Label 'Control page: ' `
        -OnStatus { param($s) Set-HeadsetStatus $s }
    if ($w.Reason -eq 'parent') { Set-HeadsetStatus 'cancelled'; exit 1 }
    if (-not $w.Serial) { Set-HeadsetStatus 'unreachable'; exit 1 }
    # The caller starts the host a moment before this.
    $t0 = [DateTime]::UtcNow
    while (-not (Get-QuestControlHost) -and ([DateTime]::UtcNow - $t0).TotalSeconds -lt 15) { Start-Sleep -Seconds 1 }
    Set-HeadsetStatus 'opening'
    if (Open-QuestControlPage -DeviceSerial $w.Serial) { Set-HeadsetStatus 'opened'; exit 0 }
    Set-HeadsetStatus 'failed'
    exit 3
}
if ($Cleanup) {
    # pwsh -File passes "-ExtraOrigins a,b" as one string.
    $ExtraOrigins = @($ExtraOrigins | ForEach-Object { ([string]$_) -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $s = Get-QuestToolsSettings
    $doTabs = if ($CloseTabs) { $true } elseif ($KeepTabs) { $false } else { [bool]$s.closeTabsOnExit }
    $skipHist = [bool]$SkipHistory -or -not [bool]$s.clearHistoryOnExit
    $doWifi = if ($WifiOff) { $true } elseif ($KeepWifi) { $false } else { [bool]$s.wifiOffOnExit }
    $code = Invoke-QuestSessionCleanup -ExtraOrigins $ExtraOrigins -HelperUrl $HelperUrl -CloseTabs:$doTabs -SkipHistory:$skipHist `
        -EnableProximity:(-not $KeepProximity) -WifiOff:$doWifi -StopIfCommandLine $StopIfCommandLine -StartedAt $startedAt
    Set-HeadsetStatus $(switch ($code) { 0 { 'done' } 1 { 'unreachable' } 4 { 'postponed' } default { 'incomplete' } })
    exit $code
}
if ($WifiOff) {
    $dev = Get-QuestHeadsetSerial
    if (-not $dev) { Write-QuestLog 'Wi-Fi: headset not reachable over adb - skipped.'; exit 1 }
    if ((Invoke-QuestWifiOff -DeviceSerial $dev) -eq 'off') { exit 0 } else { exit 3 }
}
if ($ResetAdb) {
    $how = Reset-QuestAdbServer -AdbExe $script:Adb -Log { param($m) Write-QuestLog "adb: $m" }
    Write-QuestLog "adb: server reset by hand ($how)."
    # Fresh server: the last address answers at once; mDNS needs a few seconds.
    $dev = $null
    for ($i = 0; $i -lt 8 -and -not $dev; $i++) {
        $dev = Get-QuestHeadsetSerial
        if (-not $dev) { Start-Sleep -Seconds 1 }
    }
    if ($dev) { Write-QuestLog "adb: headset back on adb ($dev)."; exit 0 }
    Write-QuestLog 'adb: server restarted, headset not on adb yet.'
    exit 1
}

# -Status (default).
$dev = Get-QuestHeadsetSerial
$out = [ordered]@{
    adb        = $script:Adb
    serial     = $dev
    wakefulness = $(if ($dev) { Get-QuestWakefulness -DeviceSerial $dev } else { $null })
    proximity  = $(if ($dev) { Get-QuestVirtualProximity -DeviceSerial $dev } else { $null })
    lastAddress = $(try { (Get-Content -LiteralPath $script:LastAdbPath -Raw -ErrorAction Stop).Trim() } catch { $null })
}
$out | ConvertTo-Json
if ($dev) { exit 0 } else { exit 1 }
