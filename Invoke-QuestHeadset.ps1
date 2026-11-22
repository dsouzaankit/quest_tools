<#
.SYNOPSIS
  Generic Meta Quest headset actions over adb: status, adb server reset, proximity sensor, Wi-Fi,
  keep-awake.

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

  Finding the headset: quest_tools\README.md ("How the PC finds the headset").
  Log: %TEMP%\loopsegments-quest-lantab.log
  Exit codes: 0 ok, 1 headset not reachable, 2 no adb or bad arguments, 3 step failed.

.EXAMPLE
  .\Invoke-QuestHeadset.ps1

.EXAMPLE
  .\Invoke-QuestHeadset.ps1 -DisableProximity -QuestHost 10.0.100.238
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
    [int] $ParentPid = 0,
    [switch] $RestoreProximity,
    [string] $AdbExe = '',
    [string] $Serial = '',
    [string] $QuestHost = '',
    [int] $Port = 0,
    [int] $RediscoverSec = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'QuestTools.ps1')
Initialize-QuestTools -AdbExe $AdbExe -Serial $Serial -QuestHost $QuestHost -Port $Port -RediscoverSec $RediscoverSec

$modes = @($ResetAdb, $EnableProximity, $DisableProximity, $ToggleProximity, $WifiOff, $KeepAwakeSession) | Where-Object { $_ }
if (@($modes).Count -gt 1) { Write-QuestLog 'Invoke-QuestHeadset: pick one mode.'; exit 2 }

$script:Adb = Find-QuestAdbExe
if (-not $script:Adb) {
    Write-QuestLog 'adb not found (winget install Google.PlatformTools, or pass -AdbExe).'
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
