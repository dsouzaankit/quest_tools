# quest_tools: finding adb and the headset on it. Dot-sourced by QuestTools.ps1.
# Reads the settings Initialize-QuestTools sets: $script:QtAdbExe, $script:QtSerial, $script:QtHost,
# $script:QtPort, $script:AdbRediscoverSec. Needs $script:Adb (the adb.exe path, normally
# $script:Adb = Find-QuestAdbExe) before any Invoke-Adb call.

function Find-QuestAdbExe {
    if (-not [string]::IsNullOrWhiteSpace($script:QtAdbExe)) {
        if (Test-Path -LiteralPath $script:QtAdbExe) { return $script:QtAdbExe }
        Write-QuestLog "questAdbExe not found: $script:QtAdbExe"
    }
    $cmd = Get-Command -Name adb.exe -ErrorAction SilentlyContinue
    if ($null -ne $cmd) { return [string]$cmd.Source }
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe')
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\adb.exe')
        (Join-Path $env:ProgramFiles 'Meta Quest Developer Hub\resources\bin\adb.exe')
        'C:\platform-tools\adb.exe'
    )
    $wingetPkgs = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    if (Test-Path -LiteralPath $wingetPkgs) {
        $candidates += @(Get-ChildItem -LiteralPath $wingetPkgs -Directory -Filter 'Google.PlatformTools*' -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName 'platform-tools\adb.exe' })
    }
    foreach ($p in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($p) -and (Test-Path -LiteralPath $p)) { return $p }
    }
    return $null
}

function Invoke-Adb {
    param([string[]] $Arguments, [int] $TimeoutSec = 10)
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $script:Adb
    foreach ($a in $Arguments) { [void]$psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        try { $p.Kill($true) } catch {}
        return [pscustomobject]@{ Code = -1; Out = ''; Err = 'timeout' }
    }
    return [pscustomobject]@{ Code = $p.ExitCode; Out = $outTask.Result; Err = $errTask.Result }
}

# Last ip:port the headset was on adb at (%TEMP%\loopsegments-quest-last-adb.txt, shared by Open on
# Quest, keep-awake and the history helper). Wireless debugging keeps its port until it is switched
# off or the headset reboots, so a direct `adb connect` to it gets the headset back at once, while
# mDNS can take minutes to list it again (seen: 17 s, then nothing in 240 s, after an adb server
# restart; the direct connect took 134 ms).
$script:LastAdbPath = Join-Path $env:TEMP 'loopsegments-quest-last-adb.txt'
$script:LastAdbSaved = ''

function Get-OnlineQuestSerial {
    $s = Find-OnlineQuestSerial
    if ($s -and $s -match '^\d{1,3}(\.\d{1,3}){3}:\d+$' -and $s -ne $script:LastAdbSaved) {
        try { Set-Content -LiteralPath $script:LastAdbPath -Value $s -Encoding ascii -NoNewline; $script:LastAdbSaved = $s } catch {}
    }
    return $s
}

# Direct `adb connect` to the last known address (short timeout: on another network it just fails).
function Connect-QuestLastAddress {
    if (-not (Test-Path -LiteralPath $script:LastAdbPath)) { return $null }
    $target = ''
    try { $target = (Get-Content -LiteralPath $script:LastAdbPath -Raw).Trim() } catch {}
    if ($target -notmatch '^\d{1,3}(\.\d{1,3}){3}:\d+$') { return $null }
    $r = Invoke-Adb -Arguments @('connect', $target) -TimeoutSec 3
    if (([string]$r.Out) -notmatch '(?i)\bconnected to\b') { return $null }
    $s = Get-OnlineQuestSerial
    if ($s) { Write-QuestLog "Connected to the last known address $target" }
    return $s
}

function Find-OnlineQuestSerial {
    $r = Invoke-Adb -Arguments @('devices', '-l')
    # A healthy server answers `adb devices` in well under a second: a timeout means it is stuck.
    $script:AdbDevicesTimedOut = ($r.Code -eq -1)
    $lines = @($r.Out -split "`r?`n" | Where-Object { $_ -match '^\S+\s+device\b' })
    if (-not [string]::IsNullOrWhiteSpace($script:QtSerial)) {
        foreach ($l in $lines) { if ($l -match ('^' + [regex]::Escape($script:QtSerial) + '\s')) { return $script:QtSerial } }
        return $null
    }
    foreach ($l in $lines) {
        if ($l -match '(?i)\bmodel:Quest' -or $l -match '(?i)\bproduct:(hollywood|eureka|seacliff|panther|monterey)') {
            return ($l -split '\s+')[0]
        }
    }
    # Exactly one non-Quest-looking device that we connected to ourselves (host:port) - take it.
    if (-not [string]::IsNullOrWhiteSpace($script:QtHost)) {
        foreach ($l in $lines) {
            if ($l -match ('^' + [regex]::Escape($script:QtHost) + ':\d+\s')) { return ($l -split '\s+')[0] }
        }
    }
    return $null
}

function Connect-Quest {
    # Stuck adb server: nothing below can get through it, so reset it first.
    if ($script:AdbDevicesTimedOut -and (Repair-QuestAdbStuckServer)) {
        $s = Get-OnlineQuestSerial
        if ($s) { $script:MdnsUnseenSince = $null; return $s }
    }
    if (-not [string]::IsNullOrWhiteSpace($script:QtHost)) {
        $target = '{0}:{1}' -f $script:QtHost, $script:QtPort
        $r = Invoke-Adb -Arguments @('connect', $target) -TimeoutSec 8
        $msg = ($r.Out + $r.Err).Trim()
        if ($msg -ne $script:LastConnectMsg) {
            Write-QuestLog "adb connect $target -> $msg"
            $script:LastConnectMsg = $msg
        }
        $s = Get-OnlineQuestSerial
        if ($s) { return $s }
    }
    # Same port as last time (no reboot / wireless debugging toggle since): no mDNS needed.
    $s = Connect-QuestLastAddress
    if ($s) { $script:MdnsUnseenSince = $null; return $s }
    # Wireless debugging (TLS) advertises its random port over mDNS; works once paired.
    $s = Connect-QuestViaMdns
    if ($s) { $script:MdnsUnseenSince = $null; return $s }
    if (Invoke-QuestAdbRediscover) {
        $s = Connect-QuestViaMdns
        if ($s) { $script:MdnsUnseenSince = $null; return $s }
    }
    return $null
}

function Connect-QuestViaMdns {
    $m = Invoke-Adb -Arguments @('mdns', 'services') -TimeoutSec 8
    foreach ($l in @($m.Out -split "`r?`n")) {
        if ($l -match '_adb-tls-connect\._tcp\.?\s+(\d{1,3}(?:\.\d{1,3}){3}:\d+)') {
            $target = $Matches[1]
            [void](Invoke-Adb -Arguments @('connect', $target) -TimeoutSec 8)
            $s = Get-OnlineQuestSerial
            if ($s) { Write-QuestLog "Connected via mDNS $target"; return $s }
        }
    }
    return $null
}

# The PC's adb server can stop hearing the headset's mDNS announcements (seen after the headset
# slept and came back on a new wireless-debugging port: the headset advertised, `adb mdns services`
# stayed empty until the server was restarted). So once this process has not found the headset for
# questAdbRediscoverSec (default 60 s), restart the adb server and look again. Only when no adb
# device at all is connected (nothing to interrupt), and at most once every 5 min across all
# companion processes (shared %TEMP% stamp). Returns $true when it restarted the server.
$script:MdnsUnseenSince = $null
# Minutes between adb server restarts (the after-quit history helper waits longer: 20).
$script:AdbRediscoverEveryMin = 5
$script:AdbRestartStamp = Join-Path $env:TEMP 'loopsegments-adb-rediscover.txt'
function Invoke-QuestAdbRediscover {
    if ($script:AdbRediscoverSec -le 0) { return $false }
    $now = [DateTime]::UtcNow
    if (-not $script:MdnsUnseenSince) { $script:MdnsUnseenSince = $now; return $false }
    $unseen = ($now - $script:MdnsUnseenSince).TotalSeconds
    if ($unseen -lt $script:AdbRediscoverSec) { return $false }
    try {
        if (Test-Path -LiteralPath $script:AdbRestartStamp) {
            $last = [DateTime]::Parse((Get-Content -LiteralPath $script:AdbRestartStamp -Raw).Trim(), $null, [Globalization.DateTimeStyles]::RoundtripKind)
            if (($now - $last).TotalMinutes -lt $script:AdbRediscoverEveryMin) { return $false }
        }
    } catch {}
    $d = Invoke-Adb -Arguments @('devices')
    $attached = @($d.Out -split "`r?`n" | Where-Object { $_ -match '^\S+\s+(device|unauthorized|recovery|sideload)\b' })
    if ($attached.Count -gt 0) { return $false }
    try { Set-Content -LiteralPath $script:AdbRestartStamp -Value $now.ToString('o') -Encoding ascii } catch {}
    Write-QuestLog ("adb: headset not seen over mDNS for {0:0} s - restarting the adb server to rediscover it." -f $unseen)
    [void](Reset-QuestAdbServer -AdbExe $script:Adb -Log { param($m) Write-QuestLog "adb: $m" })
    # mDNS answers arrive over the next few seconds.
    for ($i = 0; $i -lt 8; $i++) {
        Start-Sleep -Seconds 1
        $m = Invoke-Adb -Arguments @('mdns', 'services') -TimeoutSec 8
        if ($m.Out -match '_adb-tls-connect') { break }
    }
    $script:MdnsUnseenSince = $now
    return $true
}

# Stuck adb server (`adb devices` timed out; seen: every adb command, kill-server too, hung until
# adb.exe was killed): reset it (QuestAdbServer.ps1: kill-server, else kill the process), then
# reconnect as usual. Unlike the 60 s rediscover above this runs at once - nothing works until it
# is done - but at most once a minute across all companion processes (shared %TEMP% stamp), so
# several processes noticing the same hang reset it once. Returns $true when it reset the server.
$script:AdbDevicesTimedOut = $false
$script:AdbStuckStamp = Join-Path $env:TEMP 'loopsegments-adb-stuck-reset.txt'
function Repair-QuestAdbStuckServer {
    $now = [DateTime]::UtcNow
    try {
        if (Test-Path -LiteralPath $script:AdbStuckStamp) {
            $last = [DateTime]::Parse((Get-Content -LiteralPath $script:AdbStuckStamp -Raw).Trim(), $null, [Globalization.DateTimeStyles]::RoundtripKind)
            if (($now - $last).TotalSeconds -lt 60) { return $false }
        }
    } catch {}
    try { Set-Content -LiteralPath $script:AdbStuckStamp -Value $now.ToString('o') -Encoding ascii } catch {}
    Write-QuestLog 'adb: `adb devices` did not answer in 10 s - the adb server looks stuck; resetting it.'
    $how = Reset-QuestAdbServer -AdbExe $script:Adb -Log { param($m) Write-QuestLog "adb: $m" }
    Write-QuestLog "adb: server reset ($how)."
    $script:AdbDevicesTimedOut = $false
    return $true
}

function Get-QuestWakefulness {
    param([string] $DeviceSerial)
    $r = Invoke-Adb -Arguments @('-s', $DeviceSerial, 'shell', 'dumpsys', 'power') -TimeoutSec 8
    if ($r.Code -ne 0) { return $null }
    if ($r.Out -match 'mWakefulness=(\w+)') { return $Matches[1] }
    return $null
}

function Get-AdbMessage { param($R) (($R.Out + ' ' + $R.Err) -replace '\s+', ' ').Trim() }

function Test-AdbStartOk { param($R) ($R.Code -eq 0 -and (Get-AdbMessage $R) -notmatch '(?i)\bError\b|Exception') }

# Worn = mounted and not idle. Quest Browser only answers (history list, clear dialog, new tabs)
# while the headset is in use; a headset lying still is idle even when kept awake by prox_close.
function Test-QuestHeadsetWorn {
    param([string] $DeviceSerial)
    $r = Invoke-Adb -TimeoutSec 8 -Arguments @('-s', $DeviceSerial, 'shell', 'dumpsys', 'vrpowermanager')
    if ($r.Code -ne 0) { return $false }
    $o = [string]$r.Out
    return ($o -match '(?m)^\s*State:\s*HEADSET_MOUNTED\b') -and ($o -match '(?m)^\s*Device idle state:\s*Not idle\b')
}
