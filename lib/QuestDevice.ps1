# quest_tools: headset state over adb - proximity sensor, keep-awake, Wi-Fi off, /proc/net parsing.
# Dot-sourced by QuestTools.ps1 (needs QuestAdb.ps1, QuestLog.ps1).

# Proximity sensor: `prox_close` forces "worn" (virtual state CLOSE, headset never sleeps);
# `automation_disable` drops that override so the real sensor is used again (state DISABLED).
function Get-QuestVirtualProximity {
    param([string] $DeviceSerial)
    $r = Invoke-Adb -TimeoutSec 10 -Arguments @('-s', $DeviceSerial, 'shell', 'dumpsys', 'vrpowermanager')
    if ($r.Out -match 'Virtual proximity state:\s*(\w+)') { return $Matches[1] }
    return $null
}

# Hold the proximity sensor off (`prox_close`, virtual state CLOSE): the headset acts as worn and
# does not sleep when taken off. Undone by -EnableProximity or a headset reboot.
# A notification in the headset while the sensor is held off by hand (Set-QuestProximitySensor.ps1),
# so it is clear why the headset does not sleep. `cmd notification post` (as the Android shell; Quest
# shows it in the notification panel, not as a popup); there is no remove command, so turning the
# sensor on snoozes it for a year, which takes it off the panel. A snoozed notification stays snoozed
# when posted again under the same tag, so each post gets its own tag (loopsegments_prox_<time>) and
# the hide snoozes every one of them. Keep-awake during a companion session does not post it.
$script:QuestSensorNoticeTag = 'loopsegments_prox'

function Show-QuestSensorOffNotice {
    param([string] $DeviceSerial)
    $text = 'The headset stays awake when you take it off. Run Set-QuestProximitySensor.ps1 on the PC to turn the sensor on again (a headset reboot or the companion quit also does).'
    Hide-QuestSensorOffNotice -DeviceSerial $DeviceSerial -Quiet
    $tag = '{0}_{1}' -f $script:QuestSensorNoticeTag, [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $r = Invoke-Adb -TimeoutSec 8 -Arguments @('-s', $DeviceSerial, 'shell', "cmd notification post -S bigtext -t 'Proximity sensor OFF' $tag '$text'")
    if ($r.Code -ne 0) { return }
    Write-QuestLog 'Proximity: posted a "Proximity sensor OFF" notification in the headset.'
    # Quest lists it only behind the bell (Meta button > bell), so open that list in front of the
    # user: the system UI's notifications panel. Only on an awake headset (an activity start may
    # wake a sleeping one). (The Navigator's NotificationsActivity sometimes brings up the Library
    # instead, and `cmd statusbar expand-notifications` opens Settings > Notifications.)
    if ((Get-QuestWakefulness -DeviceSerial $DeviceSerial) -eq 'Awake') {
        $o = Invoke-Adb -TimeoutSec 8 -Arguments @('-s', $DeviceSerial, 'shell', 'am', 'start', '-n', 'com.oculus.systemux/com.oculus.panelapp.notifications.NotificationsActivity')
        if ($o.Code -eq 0 -and ([string]$o.Out) -notmatch '(?i)error') {
            Write-QuestLog 'Proximity: opened the notifications list (bell) in the headset; closing it in 20 s.'
            # Back / Home / Escape do not close that panel; removing its window's task does (like
            # swiping it away; the notification stays behind the bell). Skipped if already closed.
            Start-Sleep -Seconds 20
            $acts = [string](Invoke-Adb -TimeoutSec 10 -Arguments @('-s', $DeviceSerial, 'shell', 'dumpsys', 'activity', 'activities')).Out
            $m = [regex]::Match($acts, 'rootTaskId=(\d+)[^\n]*\n(?:[^\n]*\n){0,3}?[^\n]*panelapp\.notifications\.NotificationsActivity')
            $root = if ($m.Success) { $m.Groups[1].Value } else { '' }
            if (-not $root) {
                $t = [regex]::Match($acts, 'panelapp\.notifications\.NotificationsActivity t(\d+)')
                if ($t.Success) { $root = $t.Groups[1].Value }
            }
            if ($root) {
                [void](Invoke-Adb -TimeoutSec 8 -Arguments @('-s', $DeviceSerial, 'shell', 'am', 'stack', 'remove', $root))
                Write-QuestLog 'Proximity: closed the notifications list.'
            }
        }
    }
}

function Hide-QuestSensorOffNotice {
    param([string] $DeviceSerial, [switch] $Quiet)
    $l = Invoke-Adb -TimeoutSec 8 -Arguments @('-s', $DeviceSerial, 'shell', 'cmd', 'notification', 'list')
    foreach ($k in @(([string]$l.Out) -split "`r?`n" | Where-Object { $_ -match "\|$([regex]::Escape($script:QuestSensorNoticeTag))(_\d+)?\|" })) {
        [void](Invoke-Adb -TimeoutSec 8 -Arguments @('-s', $DeviceSerial, 'shell', "cmd notification snooze --for 31536000000 '$($k.Trim())'"))
        if (-not $Quiet) { Write-QuestLog 'Proximity: removed the "Proximity sensor OFF" notification.' }
    }
}

function Invoke-QuestDisableProximity {
    $dev = Get-OnlineQuestSerial
    if (-not $dev) { $dev = Connect-Quest }
    if (-not $dev) { Write-QuestLog 'Proximity: headset not reachable over adb - skipped.'; return 1 }
    $before = Get-QuestVirtualProximity -DeviceSerial $dev
    $r = Invoke-Adb -TimeoutSec 10 -Arguments @('-s', $dev, 'shell', 'am', 'broadcast', '-a', 'com.oculus.vrpowermanager.prox_close')
    if ($r.Code -ne 0 -or ($r.Out -notmatch 'Broadcast completed')) {
        Write-QuestLog "Proximity: broadcast failed (code $($r.Code)): $(Get-AdbMessage $r)"
        return 3
    }
    Start-Sleep -Milliseconds 500
    $after = Get-QuestVirtualProximity -DeviceSerial $dev
    if ($after -and $after -ne 'CLOSE') {
        Write-QuestLog "Proximity: override is '$after' after switching the sensor off (was '$before')."
        return 3
    }
    Write-QuestLog ("Proximity: sensor off, headset stays awake (override was '{0}', now '{1}')." -f $(if ($before) { $before } else { '?' }), $(if ($after) { $after } else { '?' }))
    Show-QuestSensorOffNotice -DeviceSerial $dev
    return 0
}

# Flip it: CLOSE (held off) -> on, anything else -> off.
function Invoke-QuestToggleProximity {
    $dev = Get-OnlineQuestSerial
    if (-not $dev) { $dev = Connect-Quest }
    if (-not $dev) { Write-QuestLog 'Proximity: headset not reachable over adb - skipped.'; return 1 }
    if ((Get-QuestVirtualProximity -DeviceSerial $dev) -eq 'CLOSE') { return (Invoke-QuestEnableProximity) }
    return (Invoke-QuestDisableProximity)
}

function Invoke-QuestEnableProximity {
    $dev = Get-OnlineQuestSerial
    if (-not $dev) { $dev = Connect-Quest }
    if (-not $dev) { Write-QuestLog 'Proximity: headset not reachable over adb - skipped.'; return 1 }
    $before = Get-QuestVirtualProximity -DeviceSerial $dev
    $r = Invoke-Adb -TimeoutSec 10 -Arguments @('-s', $dev, 'shell', 'am', 'broadcast', '-a', 'com.oculus.vrpowermanager.automation_disable')
    if ($r.Code -ne 0 -or ($r.Out -notmatch 'Broadcast completed')) {
        Write-QuestLog "Proximity: broadcast failed (code $($r.Code)): $(Get-AdbMessage $r)"
        return 3
    }
    Start-Sleep -Milliseconds 500
    $after = Get-QuestVirtualProximity -DeviceSerial $dev
    if ($after -and $after -ne 'DISABLED') {
        Write-QuestLog "Proximity: override still '$after' after re-enabling (was '$before')."
        return 3
    }
    Write-QuestLog ("Proximity: sensor on (override was '{0}', now '{1}')." -f $(if ($before) { $before } else { '?' }), $(if ($after) { $after } else { '?' }))
    Hide-QuestSensorOffNotice -DeviceSerial $dev
    return 0
}

# Until -ParentPid exits, every ~20 s: when the headset is on adb, awake, and the proximity override
# is not CLOSE, send `prox_close` (acts as worn, does not sleep, stays on adb). A headset in standby
# is left alone (prox_close would wake it). -RestoreProximity: turn the sensor back on once -ParentPid
# exits, unless another keep-awake without -RestoreProximity (a companion session) still runs.
# -OnTick: the caller's own per-poll work (~20 s, headset on adb or not); its errors are logged once
# per distinct message and never stop the loop.
function Invoke-QuestKeepAwakeSession {
    param([int] $ParentPid, [switch] $RestoreProximity, [scriptblock] $OnTick)
    if ($ParentPid -le 0) { Write-QuestLog 'Keep-awake: -ParentPid is required.'; return 2 }
    Write-QuestLog "Keep-awake: holding the Quest proximity sensor off while PID $ParentPid runs."
    $lastNote = ''
    $lastTickError = ''
    while (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue) {
        $note = ''
        try {
            $dev = Get-OnlineQuestSerial
            if (-not $dev) { $dev = Connect-Quest }
            if (-not $dev) {
                $note = 'headset not on adb - waiting'
            } else {
                $state = Get-QuestVirtualProximity -DeviceSerial $dev
                # prox_close tells the headset it was just put on, so it would wake one lying in
                # standby (still on Wi-Fi for a while after it sleeps). Only act once it is awake,
                # i.e. someone woke it by putting it on.
                $wake = if ($state -eq 'CLOSE') { $null } else { Get-QuestWakefulness -DeviceSerial $dev }
                if ($state -eq 'CLOSE') {
                    $note = "sensor held off ($dev)"
                } elseif ($wake -ne 'Awake') {
                    $note = "headset asleep ($(if ($wake) { $wake } else { 'unknown' })) - not waking it; sensor goes off once it is put on"
                } else {
                    # Check the parent again right before acting: cleanup may have started.
                    if (-not (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue)) { break }
                    $r = Invoke-Adb -TimeoutSec 10 -Arguments @('-s', $dev, 'shell', 'am', 'broadcast', '-a', 'com.oculus.vrpowermanager.prox_close')
                    $note = if ($r.Out -match 'Broadcast completed') { "sensor switched off (was '$state', $dev)" } else { "prox_close failed: $(Get-AdbMessage $r)" }
                }
            }
        } catch {
            $note = "error: $($_.Exception.Message)"
        }
        if ($note -ne $lastNote) { Write-QuestLog "Keep-awake: $note"; $lastNote = $note }
        if ($OnTick) {
            try { & $OnTick; $lastTickError = '' } catch {
                $e = $_.Exception.Message
                if ($e -ne $lastTickError) { Write-QuestLog "Keep-awake: tick error: $e"; $lastTickError = $e }
            }
        }
        for ($i = 0; $i -lt 20 -and (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Seconds 1 }
    }
    if ($RestoreProximity) {
        # 3d_playlist_local workflow ended by itself (the Enter button stops this process first and
        # turns the sensor on in its own order). Leave it held off while a companion session runs.
        $companion = @(Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe' OR Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
                Where-Object { ([string]$_.CommandLine) -like '*-KeepAwakeSession*' -and ([string]$_.CommandLine) -notlike '*-RestoreProximity*' -and [int]$_.ProcessId -ne $PID })
        if ($companion.Count) {
            Write-QuestLog 'Keep-awake: workflow gone - sensor left off (the companion session still holds it).'
        } else {
            Write-QuestLog 'Keep-awake: workflow gone - turning the proximity sensor back on.'
            [void](Invoke-QuestEnableProximity)
        }
        return 0
    }
    Write-QuestLog 'Keep-awake: companion gone - stopping (sensor is re-enabled by the companion cleanup).'
    return 0
}

# Switch the headset's Wi-Fi off (a sleeping headset then does not drain its battery on Wi-Fi). adb
# (over that Wi-Fi) drops right after. Wireless debugging comes back on its own (new port, found over
# mDNS) once Wi-Fi is switched on again in the headset's quick settings. Returns 'off' or 'failed'.
# Whether to do it at all (a setting) is the caller's decision.
function Invoke-QuestWifiOff {
    param([string] $DeviceSerial)
    # Open Settings > Wi-Fi first (android.settings.WIFI_SETTINGS: Quest relays it to its Settings
    # app on the Wi-Fi page, toggle at the top), so switching Wi-Fi back on is one tap when the
    # headset is next put on. Only on an awake headset (an activity start may wake a sleeping one),
    # and after the browser steps (Quest Browser goes behind the panel).
    if ((Get-QuestWakefulness -DeviceSerial $DeviceSerial) -eq 'Awake') {
        $h = Invoke-Adb -TimeoutSec 8 -Arguments @('-s', $DeviceSerial, 'shell', 'am', 'start', '-a', 'android.settings.WIFI_SETTINGS')
        if ($h.Code -eq 0 -and ([string]$h.Out) -notmatch '(?i)error') { Write-QuestLog 'Wi-Fi settings: opened (Wi-Fi toggle in front).'; Start-Sleep -Milliseconds 800 }
        else { Write-QuestLog "Wi-Fi settings: could not open ($(([string]$h.Out + ' ' + [string]$h.Err).Trim()))." }
    }
    $w = Invoke-Adb -TimeoutSec 10 -Arguments @('-s', $DeviceSerial, 'shell', 'cmd', 'wifi', 'set-wifi-enabled', 'disabled')
    if ($w.Code -eq 0) {
        Write-QuestLog 'Wi-Fi: switched the headset''s Wi-Fi off (switch it on in quick settings before the next session).'
        return 'off'
    }
    # Wireless adb runs over that Wi-Fi: the command often never returns because the link dropped
    # as Wi-Fi went off (timeout, code -1 / 1). The headset gone from adb (offline / not listed) right
    # after means it took it.
    Start-Sleep -Seconds 2
    $st = Invoke-Adb -TimeoutSec 8 -Arguments @('devices')
    $line = @(([string]$st.Out) -split "`r?`n" | Where-Object { $_ -match ('^' + [regex]::Escape($DeviceSerial) + '\s') }) | Select-Object -First 1
    if ($DeviceSerial -match '^\d{1,3}(\.\d{1,3}){3}:\d+$' -and (-not $line -or $line -notmatch '\sdevice\s*$')) {
        Write-QuestLog ("Wi-Fi: switched the headset's Wi-Fi off (adb dropped during the command, code {0}; switch it on in quick settings before the next session)." -f $w.Code)
        return 'off'
    }
    Write-QuestLog "Wi-Fi: could not switch it off (code $($w.Code))."
    return 'failed'
}

# /proc/net/tcp(6) address "0100A8C0:1F90" -> 192.168.0.1, 8080 (IPv4 and IPv4-mapped IPv6 only).
function ConvertFrom-QuestProcNetAddress {
    param([string] $Hex)
    $parts = $Hex.Split(':')
    if ($parts.Count -ne 2) { return $null }
    $ipHex = $parts[0]
    $port = [Convert]::ToInt32($parts[1], 16)
    if ($ipHex.Length -eq 32) {
        if (-not $ipHex.StartsWith('0000000000000000FFFF0000', [StringComparison]::OrdinalIgnoreCase)) { return [pscustomobject]@{ Ip = ''; Port = $port } }
        $ipHex = $ipHex.Substring(24)
    }
    if ($ipHex.Length -ne 8) { return [pscustomobject]@{ Ip = ''; Port = $port } }
    $b = @(0..3 | ForEach-Object { [Convert]::ToByte($ipHex.Substring($_ * 2, 2), 16) })
    return [pscustomobject]@{ Ip = ('{0}.{1}.{2}.{3}' -f $b[3], $b[2], $b[1], $b[0]); Port = $port }
}
