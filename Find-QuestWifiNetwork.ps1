<#
.SYNOPSIS
  Cycle this PC through its saved Wi-Fi networks until the Quest headset is on wireless adb, and stay
  on that network.

.DESCRIPTION
  mDNS does not cross routers, so the PC finds the headset only on the same network (README: "How the
  PC finds the headset"). When you do not know which network the headset joined, run this:

  1. The current network first, without switching: the usual lookup (-QuestHost, last known
     address, mDNS); if that finds nothing, one adb server restart and another look.
  2. Then every other saved profile (`netsh wlan show profiles`, in Windows' priority order), the ones
     in range first, then the rest. "In range" = the profile's SSID is in a fresh scan (WlanScan,
     ~4 s: `netsh wlan show networks` alone is the last scan, which while connected often lists only
     the current network). Unseen ones are still tried (a restarting AP or a hidden SSID is missing
     from any scan), with a shorter wait. Each: `netsh wlan connect`, wait up to -ConnectSec
     (-UnseenConnectSec for unseen) for the PC's Wi-Fi to be connected with an IPv4 address, restart the adb server
     (a running server can go on missing the headset over mDNS for minutes), then look for up to
     -PerNetworkSec.
  3. Stops at the first network where the headset is on adb over Wi-Fi (an ip:port or mDNS serial)
     and answers `adb shell`. The PC stays on that network. USB entries in `adb devices` never count
     and never hide a Wi-Fi entry: with the headset on USB, the script reads its own serial
     (`getprop ro.serialno`) there and accepts only a Wi-Fi entry with the same serial (so another
     Quest on the network is skipped). -Serial picks the headset instead.
     Nothing found (or Ctrl+C): the PC goes back to the network it started on (-NoRestore keeps it
     on the last one tried).

  Switching drops this PC's Wi-Fi for a few seconds per network, and each adb server restart drops
  every adb client on this PC (a running companion, a workflow) for a few seconds.
  -Profiles limits the cycle to those profiles (in that order); -SkipOutOfRange tries only networks
  the scan sees.

  Shows what it did and waits for Enter (-NoWait skips that).
  Exit codes: 0 headset on adb (prints network and serial), 1 not found on any network, 2 no adb or
  no Wi-Fi interface.
  Log: %TEMP%\loopsegments-quest-lantab.log

.EXAMPLE
  .\Find-QuestWifiNetwork.ps1

.EXAMPLE
  .\Find-QuestWifiNetwork.ps1 -Profiles 'ATT-WIFI-5pmY', 'ATT-WIFI-3pKe' -PerNetworkSec 30 -NoWait
#>
[CmdletBinding()]
param(
    # Only these saved profiles, in this order (default: all saved profiles).
    [string[]] $Profiles = @(),
    # Skip saved profiles the Wi-Fi scan does not see.
    [switch] $SkipOutOfRange,
    # Per network: seconds to wait for the PC's Wi-Fi to connect and get an address.
    [int] $ConnectSec = 20,
    # Same, for a saved network the fresh scan did not see (usually really out of range).
    [int] $UnseenConnectSec = 8,
    # Per network: seconds to look for the headset once the PC is on it.
    [int] $PerNetworkSec = 25,
    # Nothing found: stay on the last network tried instead of going back.
    [switch] $NoRestore,
    # Exit straight away instead of waiting for Enter (for scripts).
    [switch] $NoWait,
    [string] $AdbExe = '',
    # Only this headset: its adb Wi-Fi serial (ip:port) or its own serial (ro.serialno, as shown
    # over USB). Default: the headset on USB if one is, else any Quest.
    [string] $Serial = '',
    [string] $QuestHost = '',
    [int] $Port = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'QuestTools.ps1')
# This script restarts the adb server itself after each switch; no 60 s rediscover on top.
# -Serial is matched here (Find-QuestOnWifi), not by the lib's lookup.
Initialize-QuestTools -AdbExe $AdbExe -QuestHost $QuestHost -Port $Port -RediscoverSec 0

function Write-Step { param([string] $Text, [string] $Color = 'Gray') Write-Host $Text -ForegroundColor $Color; Write-QuestLog "Wi-Fi cycle: $Text" }

function Exit-Cycle {
    param([int] $Code)
    Write-Host "Log: $env:TEMP\loopsegments-quest-lantab.log" -ForegroundColor DarkGray
    if (-not $NoWait) { Write-Host ''; [void](Read-Host 'Press Enter to close') }
    exit $Code
}

# The first Wi-Fi interface: its name, state, connected profile.
function Get-PcWifiInterface {
    $text = (& netsh wlan show interfaces) -join "`n"
    if ($text -notmatch '(?m)^\s+Name\s+:\s*(.+?)\s*$') { return $null }
    $name = $Matches[1]
    $state = if ($text -match '(?m)^\s+State\s+:\s*(.+?)\s*$') { $Matches[1] } else { '' }
    $prof = if ($text -match '(?m)^\s+Profile\s+:\s*(.+?)\s*$') { $Matches[1] } else { $null }
    $guid = if ($text -match '(?m)^\s+GUID\s+:\s*([0-9a-fA-F-]{36})\s*$') { $Matches[1] } else { $null }
    return [pscustomobject]@{ Name = $name; State = $state; Profile = $prof; Guid = $guid }
}

# `netsh wlan show networks` is the last scan, and Windows rarely rescans while connected (seen: only
# the current network listed, 6 other saved ones not). Ask for a fresh scan (WlanScan) and give the
# driver a few seconds to finish. Returns $true when the scan was requested.
function Request-PcWifiScan {
    param([string] $InterfaceGuid, [int] $WaitSec = 4)
    if (-not $InterfaceGuid) { return $false }
    if (-not ('QuestWlan' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class QuestWlan {
    [DllImport("wlanapi.dll")] static extern uint WlanOpenHandle(uint ver, IntPtr res, out uint negotiated, out IntPtr handle);
    [DllImport("wlanapi.dll")] static extern uint WlanCloseHandle(IntPtr handle, IntPtr res);
    [DllImport("wlanapi.dll")] static extern uint WlanScan(IntPtr handle, ref Guid iface, IntPtr ssid, IntPtr ie, IntPtr res);
    public static uint Scan(Guid iface) {
        uint v; IntPtr h;
        uint rc = WlanOpenHandle(2, IntPtr.Zero, out v, out h);
        if (rc != 0) return rc;
        try { return WlanScan(h, ref iface, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero); }
        finally { WlanCloseHandle(h, IntPtr.Zero); }
    }
}
'@
    }
    $rc = [QuestWlan]::Scan([guid]$InterfaceGuid)
    if ($rc -ne 0) { Write-QuestLog "Wi-Fi cycle: WlanScan failed ($rc); using the last scan."; return $false }
    Start-Sleep -Seconds $WaitSec
    return $true
}

# Saved profile name -> the SSID it connects to (a profile can be renamed; the scan lists SSIDs).
function Get-PcWifiProfileSsid {
    param([string] $ProfileName)
    foreach ($l in @(& netsh wlan show profile "name=$ProfileName")) {
        if ($l -match '^\s+SSID name\s+:\s*"?(.*?)"?\s*$') { return $Matches[1] }
    }
    return $ProfileName
}

function Get-PcWifiIpv4 {
    param([string] $InterfaceName)
    $a = Get-NetIPAddress -InterfaceAlias $InterfaceName -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notmatch '^169\.254\.' -and $_.AddressState -eq 'Preferred' } | Select-Object -First 1
    if ($a) { return [string]$a.IPAddress } else { return $null }
}

# Online Quest transports in `adb devices -l`, split into Wi-Fi (ip:port, or mDNS
# `adb-<serial>-xxxx._adb-tls-connect._tcp`) and USB. Not Get-OnlineQuestSerial: that returns the
# first Quest entry, and with the headset also on USB that can be the USB one, which hid its Wi-Fi
# entry (and stopped Connect-Quest before mDNS).
function Get-QuestAdbTransports {
    $r = Invoke-Adb -Arguments @('devices', '-l')
    $wifiList = @(); $usbList = @()
    foreach ($l in @($r.Out -split "`r?`n")) {
        if ($l -notmatch '^(\S+)\s+device\b') { continue }
        $s = $Matches[1]
        $isWifi = $s -match '^\d{1,3}(\.\d{1,3}){3}:\d+$|_adb-tls-connect'
        $isQuest = $l -match '(?i)\bmodel:Quest|\bproduct:(hollywood|eureka|seacliff|panther|monterey)' -or
            ($QuestHost -and $s -like "${QuestHost}:*")
        if (-not $isQuest) { continue }
        if ($isWifi) { $wifiList += $s } else { $usbList += $s }
    }
    return [pscustomobject]@{ Wifi = $wifiList; Usb = $usbList }
}

# The headset's own serial (ro.serialno): the same over USB and Wi-Fi, so it ties the two entries
# together. Also the liveness check: a stale transport does not answer.
function Get-QuestHardwareSerial {
    param([string] $Transport)
    $r = Invoke-Adb -Arguments @('-s', $Transport, 'shell', 'getprop', 'ro.serialno') -TimeoutSec 5
    $v = ([string]$r.Out).Trim()
    if ($r.Code -eq 0 -and $v -match '^\w+$') { return $v }
    return $null
}

# Which headset to look for: -Serial (a transport or a ro.serialno), else the one on USB (remembered,
# since an adb server restart drops USB for a moment); $null = any Quest.
$script:QuestWanted = $null
$script:SerialIsTransport = [bool]($Serial -match '^\d{1,3}(\.\d{1,3}){3}:\d+$|_adb-tls-connect')
function Update-QuestWanted {
    param($Transports)
    if ($script:QuestWanted -or $script:SerialIsTransport) { return }
    if ($Serial) { $script:QuestWanted = $Serial; return }
    foreach ($u in @($Transports.Usb)) {
        $hw = Get-QuestHardwareSerial -Transport $u
        if ($hw) {
            $script:QuestWanted = $hw
            Write-Step "  Headset $hw is on USB; looking for its Wi-Fi adb connection (USB does not count)." DarkGray
            return
        }
    }
}

# A Wi-Fi transport of the wanted headset that answers; else $null.
function Select-QuestWifiTransport {
    param($Transports)
    foreach ($w in @($Transports.Wifi)) {
        if ($script:SerialIsTransport) {
            if ($w -eq $Serial -and (Get-QuestHardwareSerial -Transport $w)) { return $w }
            continue
        }
        $hw = Get-QuestHardwareSerial -Transport $w
        if (-not $hw) { continue }
        if (-not $script:QuestWanted -or $hw -eq $script:QuestWanted) { return $w }
        Write-QuestLog "Wi-Fi cycle: $w is headset $hw, not $script:QuestWanted - skipped."
    }
    return $null
}

# The headset on adb over Wi-Fi (USB entries skipped) and answering; else $null. Connects like
# Connect-Quest (-QuestHost, last known address, mDNS), but checks the Wi-Fi entries after each step
# instead of stopping at a USB one.
function Find-QuestOnWifi {
    $t = Get-QuestAdbTransports
    Update-QuestWanted -Transports $t
    $dev = Select-QuestWifiTransport -Transports $t
    $targets = @()
    if (-not $dev -and $QuestHost) { $targets += ('{0}:{1}' -f $QuestHost, $script:QtPort) }
    if (-not $dev) {
        try { $last = (Get-Content -LiteralPath $script:LastAdbPath -Raw -ErrorAction Stop).Trim() } catch { $last = '' }
        if ($last -match '^\d{1,3}(\.\d{1,3}){3}:\d+$') { $targets += $last }
    }
    foreach ($target in $targets) {
        if ($dev) { break }
        [void](Invoke-Adb -Arguments @('connect', $target) -TimeoutSec 3)
        $dev = Select-QuestWifiTransport -Transports (Get-QuestAdbTransports)
    }
    if (-not $dev) {
        $m = Invoke-Adb -Arguments @('mdns', 'services') -TimeoutSec 8
        foreach ($l in @($m.Out -split "`r?`n")) {
            if ($dev) { break }
            if ($l -match '_adb-tls-connect\._tcp\.?\s+(\d{1,3}(?:\.\d{1,3}){3}:\d+)') {
                [void](Invoke-Adb -Arguments @('connect', $Matches[1]) -TimeoutSec 8)
                $dev = Select-QuestWifiTransport -Transports (Get-QuestAdbTransports)
            }
        }
    }
    if ($dev -and $dev -match '^\d{1,3}(\.\d{1,3}){3}:\d+$') {
        # Same file Get-OnlineQuestSerial keeps: the next lookup (any script) connects straight to it.
        try { Set-Content -LiteralPath $script:LastAdbPath -Value $dev -Encoding ascii -NoNewline } catch {}
    }
    return $dev
}

function Wait-QuestOnWifi {
    param([int] $Seconds)
    $until = [DateTime]::UtcNow.AddSeconds([Math]::Max(1, $Seconds))
    do {
        $dev = Find-QuestOnWifi
        if ($dev) { return $dev }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $until)
    return $null
}

function Reset-AdbForNewNetwork {
    # Old transports point at the previous network; a fresh server listens to mDNS afresh.
    [void](Invoke-Adb -Arguments @('disconnect') -TimeoutSec 5)
    $how = Reset-QuestAdbServer -AdbExe $script:Adb -Log { param($m) Write-QuestLog "adb: $m" }
    if ($how -eq 'killed') { Write-Step '  adb: the adb server was stuck - killed it and started a fresh one.' Yellow }
}

function Show-Found {
    param([string] $Network, [string] $Dev)
    Write-Step ("Headset on adb: {0} (PC on Wi-Fi '{1}')." -f $Dev, $Network) Green
}

$script:Adb = Find-QuestAdbExe
if (-not $script:Adb) { Write-Host 'ERROR: adb not found: winget install Google.PlatformTools (see quest_tools\README.md).' -ForegroundColor Red; Exit-Cycle 2 }

$wifi = Get-PcWifiInterface
if (-not $wifi) { Write-Host 'ERROR: no Wi-Fi interface on this PC (netsh wlan show interfaces).' -ForegroundColor Red; Exit-Cycle 2 }
$startProfile = if ($wifi.State -eq 'connected') { $wifi.Profile } else { $null }

Write-Host 'Quest: looking for the headset on this PC''s saved Wi-Fi networks...' -ForegroundColor Cyan

# 1. Current network, no switch.
if ($startProfile) {
    Write-Step "Current network '$startProfile'..."
    $dev = Find-QuestOnWifi
    if (-not $dev) {
        Reset-AdbForNewNetwork
        $dev = Wait-QuestOnWifi -Seconds $PerNetworkSec
    }
    if ($dev) { Show-Found -Network $startProfile -Dev $dev; Exit-Cycle 0 }
    Write-Step '  not there.' DarkGray
}

# 2. Other saved profiles.
$saved = @((& netsh wlan show profiles) | ForEach-Object { if ($_ -match 'All User Profile\s+:\s*(.+?)\s*$') { $Matches[1] } })
Write-Step 'Scanning for Wi-Fi networks...' DarkGray
[void](Request-PcWifiScan -InterfaceGuid $wifi.Guid)
$visibleSsids = @((& netsh wlan show networks) | ForEach-Object { if ($_ -match '^SSID \d+\s+:\s*(.+?)\s*$') { $Matches[1] } })
# Saved profiles whose SSID the scan saw (hidden networks never show by name: they count as unseen).
$visible = @($saved | Where-Object { $visibleSsids -contains (Get-PcWifiProfileSsid -ProfileName $_) })
Write-Step ("  in range: {0}" -f $(if ($visible.Count) { ($visible | ForEach-Object { "'$_'" }) -join ', ' } else { 'none of the saved networks' })) DarkGray
if ($Profiles.Count -gt 0) {
    $missing = @($Profiles | Where-Object { $saved -notcontains $_ })
    foreach ($m in $missing) { Write-Step "  '$m' is not a saved profile - skipped." Yellow }
    $candidates = @($Profiles | Where-Object { $saved -contains $_ -and $_ -ne $startProfile })
} else {
    $others = @($saved | Where-Object { $_ -ne $startProfile })
    $candidates = @($others | Where-Object { $visible -contains $_ }) + @($others | Where-Object { $visible -notcontains $_ })
}
if ($SkipOutOfRange) { $candidates = @($candidates | Where-Object { $visible -contains $_ }) }

$found = $false
$switched = $false
try {
    foreach ($p in $candidates) {
        $unseen = $visible -notcontains $p
        Write-Step ("Switching to '{0}'{1}..." -f $p, $(if ($unseen) { ' (not in the scan)' } else { '' }))
        $switched = $true
        & netsh wlan connect "name=$p" "interface=$($wifi.Name)" | Out-Null
        $ip = $null
        # In range connects in a few seconds; one the scan did not see gets a shorter wait.
        $waitSec = if ($unseen) { [Math]::Min($ConnectSec, $UnseenConnectSec) } else { $ConnectSec }
        $until = [DateTime]::UtcNow.AddSeconds([Math]::Max(1, $waitSec))
        while ([DateTime]::UtcNow -lt $until) {
            Start-Sleep -Seconds 1
            $now = Get-PcWifiInterface
            if ($now -and $now.State -eq 'connected' -and $now.Profile -eq $p) {
                $ip = Get-PcWifiIpv4 -InterfaceName $wifi.Name
                if ($ip) { break }
            }
        }
        if (-not $ip) { Write-Step "  could not connect within $waitSec s." DarkGray; continue }
        Write-Step "  PC on '$p' ($ip); looking for the headset (up to $PerNetworkSec s)..." DarkGray
        Reset-AdbForNewNetwork
        $dev = Wait-QuestOnWifi -Seconds $PerNetworkSec
        if ($dev) { $found = $true; Show-Found -Network $p -Dev $dev; break }
        Write-Step '  not there.' DarkGray
    }
} finally {
    # Nothing found, or Ctrl+C: back to where the PC was.
    if (-not $found -and $switched -and $startProfile -and -not $NoRestore) {
        Write-Step "Going back to '$startProfile'." Yellow
        & netsh wlan connect "name=$startProfile" "interface=$($wifi.Name)" | Out-Null
    }
}

if ($found) { Exit-Cycle 0 }
Write-Host ('ERROR: headset not on adb on any of {0} saved network(s): wake it (put it on), check its Wi-Fi and wireless debugging.' -f (@($candidates).Count + [int][bool]$startProfile)) -ForegroundColor Red
Exit-Cycle 1
