# quest_tools: the after-quit history helper. Dot-sourced by QuestTools.ps1; needs QuestCleanup.ps1,
# QuestHelperPage.ps1, QuestDevice.ps1, QuestAdb.ps1, Write-QuestLog.
#
# A cleanup at quit usually runs with nobody wearing the headset, and then Quest Browser often does
# not answer (README, *When Quest Browser does not answer*), or the headset is not on adb at all.
# Instead of dropping the delete, the caller hands it over:
#
#   Start-QuestHistoryRetry -Origins $o -HelperUrl $page -HelperFallbackPort 18767 -FallbackRange day -WifiOff
#
# That saves what is left in %TEMP%\loopsegments-quest-history-pending.json and starts one hidden,
# detached helper (quest_tools\Invoke-QuestHistoryRetry.ps1). Every 5 s it looks for the headset;
# once it is worn (mounted, not idle) it runs Invoke-QuestBrowserCleanup for those origins (plus the
# shared origin list), then switches Wi-Fi off (-WifiOff). It gives up after -Minutes. A second hand-off
# while one waits merges into it.
#
# Project hooks (both optional):
#   -StopIfCommandLine <regex>  stop (and drop the delete) when a process whose command line matches
#                               starts after the helper: e.g. the project starting again, whose own
#                               quit deletes the same origins.
#   -AfterScript <path.ps1>     run (pwsh -File <path> -Outcome <done|gaveup|stopped|none>) when the
#                               helper ends: e.g. a held network change that would have moved the
#                               headset off this PC's network while it waited.

$script:QuestHistoryPendingPath = Join-Path $env:TEMP 'loopsegments-quest-history-pending.json'
$script:QuestHistoryRetryScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'Invoke-QuestHistoryRetry.ps1'

function Read-QuestHistoryPending {
    if (-not (Test-Path -LiteralPath $script:QuestHistoryPendingPath)) { return $null }
    try { return (Get-Content -LiteralPath $script:QuestHistoryPendingPath -Raw | ConvertFrom-Json) } catch { return $null }
}

function Write-QuestHistoryPending {
    param($Pending)
    $tmp = "$($script:QuestHistoryPendingPath).$PID.tmp"
    Set-Content -LiteralPath $tmp -Value ($Pending | ConvertTo-Json -Depth 4) -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $script:QuestHistoryPendingPath -Force
}

# Is this command line an after-quit helper? (also the one Loop Segments' watcher ran before it moved
# here: Watch-LoopSegmentsQuestLanTab.ps1 -RetryHistory)
function Test-QuestHistoryRetryCommandLine {
    param([string] $CommandLine)
    return ($CommandLine -like '*Invoke-QuestHistoryRetry.ps1*') -or ($CommandLine -like '*Watch-LoopSegmentsQuestLanTab.ps1*' -and $CommandLine -like '*-RetryHistory*')
}

function Get-QuestHistoryRetryProcesses {
    return @(Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe' OR Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and (Test-QuestHistoryRetryCommandLine -CommandLine ([string]$_.CommandLine)) })
}

function Test-QuestHistoryHelperAlive {
    param([int] $HelperPid)
    if ($HelperPid -le 0) { return $false }
    $p = Get-CimInstance Win32_Process -Filter "ProcessId = $HelperPid" -ErrorAction SilentlyContinue
    return [bool]($p -and (Test-QuestHistoryRetryCommandLine -CommandLine ([string]$p.CommandLine)))
}

# Stop every waiting helper and drop what it was waiting to do (a new session takes over: its quit
# deletes the same origins). Returns { Stopped = helper processes stopped; Pending = a delete was
# pending }. Does not run -AfterScript: the caller decides what its held work means now.
function Stop-QuestHistoryRetry {
    $n = 0
    foreach ($p in @(Get-QuestHistoryRetryProcesses)) {
        if ([int]$p.ProcessId -eq $PID) { continue }
        try { Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction Stop; $n++ } catch {}
    }
    $had = Test-Path -LiteralPath $script:QuestHistoryPendingPath
    if ($had) { Remove-Item -LiteralPath $script:QuestHistoryPendingPath -Force -ErrorAction SilentlyContinue }
    return [pscustomobject]@{ Stopped = $n; Pending = $had }
}

# Save what is left to do and make sure one helper is running for it. -Proximity: the quit could not
# reach the headset, so the sensor override may still be on. Returns $true when handed over.
function Start-QuestHistoryRetry {
    param(
        [string[]] $Origins,
        [int] $Minutes = 120,
        [switch] $CloseTabs,
        [switch] $Proximity,
        [switch] $CloseBrowser,
        [string] $HelperUrl = '',
        [int] $HelperFallbackPort = 0,
        [string] $FallbackRange = '',
        [switch] $WifiOff,
        [string] $StopIfCommandLine = '',
        [string] $AfterScript = ''
    )
    if ($Minutes -le 0) { return $false }
    $Origins = @($Origins | Where-Object { $_ } | ForEach-Object { ([string]$_).TrimEnd('/') })
    if ($Origins.Count -eq 0) { return $false }
    if (-not (Test-Path -LiteralPath $script:QuestHistoryRetryScript)) { Write-QuestLog "History: $($script:QuestHistoryRetryScript) missing - delete not postponed."; return $false }
    $prev = Read-QuestHistoryPending
    $has = { param($n) $prev -and $prev.PSObject.Properties[$n] -and $prev.$n }
    $all = @(@($Origins) + @($(if ($prev) { @($prev.origins) } else { @() })) | Where-Object { $_ } | Select-Object -Unique)
    $helperPid = if ($prev -and (Test-QuestHistoryHelperAlive -HelperPid ([int]$prev.pid))) { [int]$prev.pid } else { 0 }
    $until = [DateTime]::UtcNow.AddMinutes($Minutes)
    $pending = [ordered]@{
        origins            = $all
        closeTabs          = [bool]($CloseTabs -or (& $has 'closeTabs'))
        proximity          = [bool]($Proximity -or (& $has 'proximity'))
        closeBrowser       = [bool]($CloseBrowser -or (& $has 'closeBrowser'))
        helperUrl          = $HelperUrl
        helperFallbackPort = $HelperFallbackPort
        fallbackRange      = $FallbackRange
        wifiOff            = [bool]$WifiOff
        stopIfCommandLine  = $StopIfCommandLine
        afterScript        = $AfterScript
        # How this process reached the headset (Initialize-QuestTools), for the helper.
        adbExe             = [string]$script:QtAdbExe
        serial             = [string]$script:QtSerial
        questHost          = [string]$script:QtHost
        port               = [int]$script:QtPort
        until              = $until.ToString('o')
        queuedAt           = [DateTime]::UtcNow.ToString('o')
        pid                = $helperPid
    }
    Write-QuestHistoryPending $pending
    if ($helperPid -eq 0) {
        # Detached (WMI-created, so not part of the caller's process tree), no window.
        $pwsh = (Get-Process -Id $PID).Path
        $cmd = ('"{0}" -NoProfile -NoLogo -NonInteractive -ExecutionPolicy Bypass -File "{1}"' -f $pwsh, $script:QuestHistoryRetryScript)
        try {
            $si = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ ShowWindow = [uint16]0 }
            $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd; ProcessStartupInformation = $si }
            if ([int]$r.ReturnValue -ne 0) { throw "Win32_Process.Create returned $($r.ReturnValue)" }
            $helperPid = [int]$r.ProcessId
            $pending.pid = $helperPid
            Write-QuestHistoryPending $pending
        } catch {
            Write-QuestLog "History: could not start the retry helper - $($_.Exception.Message)"
            Remove-Item -LiteralPath $script:QuestHistoryPendingPath -Force -ErrorAction SilentlyContinue
            return $false
        }
    }
    Write-QuestLog ("History: postponed - deleted when the headset is next worn (helper PID {0}, until {1:HH:mm})." -f $helperPid, $until.ToLocalTime())
    return $true
}

# -AfterScript of the pending hand-off, once, with -Outcome.
function Invoke-QuestHistoryRetryAfter {
    param($Pending, [string] $Outcome)
    $s = if ($Pending -and $Pending.PSObject.Properties['afterScript']) { [string]$Pending.afterScript } else { '' }
    if (-not $s) { return }
    if (-not (Test-Path -LiteralPath $s)) { Write-QuestLog "History retry: after-script $s missing - skipped."; return }
    try {
        $p = Start-Process -FilePath (Get-Process -Id $PID).Path -WindowStyle Hidden -PassThru `
            -ArgumentList @('-NoProfile', '-NoLogo', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$s`"", '-Outcome', $Outcome)
        if (-not $p.WaitForExit(660000)) { try { $p.Kill($true) } catch {}; Write-QuestLog 'History retry: after-script still running after 11 min - stopped.' }
    } catch { Write-QuestLog "History retry: after-script could not run: $($_.Exception.Message)" }
}

# The helper's loop (Invoke-QuestHistoryRetry.ps1). 0 done / stopped / nothing pending, 1 gave up.
function Invoke-QuestHistoryRetryLoop {
    $startedAt = [DateTime]::UtcNow
    # While it waits it restarts the PC's adb server at most every 20 min (not 5) when it cannot find the headset.
    $script:AdbRediscoverEveryMin = 20
    $p = Read-QuestHistoryPending
    if (-not $p) { Write-QuestLog 'History retry: nothing pending - stop.'; return 0 }
    $get = { param($n, $d) if ($p -and $p.PSObject.Properties[$n] -and $null -ne $p.$n) { $p.$n } else { $d } }
    Initialize-QuestTools -AdbExe ([string](& $get 'adbExe' '')) -Serial ([string](& $get 'serial' '')) -QuestHost ([string](& $get 'questHost' '')) -Port ([int](& $get 'port' 0))
    $script:Adb = Find-QuestAdbExe
    if (-not $script:Adb) { Write-QuestLog 'History retry: adb not found - stop.'; Remove-Item -LiteralPath $script:QuestHistoryPendingPath -Force -ErrorAction SilentlyContinue; Invoke-QuestHistoryRetryAfter -Pending $p -Outcome 'none'; return 1 }
    $until = [DateTime]::Parse([string]$p.until, $null, [Globalization.DateTimeStyles]::RoundtripKind)
    Write-QuestLog ("History retry: waiting for the headset to be worn (until {0:HH:mm}; {1})." -f $until.ToLocalTime(), (@($p.origins) -join ', '))
    $proxDone = -not [bool]$p.proximity
    $shownWorn = $false
    $fallbackTried = $false
    while ($true) {
        $last = $p
        $p = Read-QuestHistoryPending
        if (-not $p) { Write-QuestLog 'History retry: no longer pending - stop.'; Invoke-QuestHistoryRetryAfter -Pending $last -Outcome 'none'; return 0 }
        $owner = [int]$p.pid
        if ($owner -ne $PID) {
            if (Test-QuestHistoryHelperAlive -HelperPid $owner) { return 0 }
            $p.pid = $PID
            Write-QuestHistoryPending $p
        }
        $until = [DateTime]::Parse([string]$p.until, $null, [Globalization.DateTimeStyles]::RoundtripKind)
        $wifiOff = [bool](& $get 'wifiOff' $false)
        if ([DateTime]::UtcNow -gt $until) {
            Write-QuestLog 'History retry: the headset was not worn in time - gave up (the next quit deletes those entries).'
            Remove-Item -LiteralPath $script:QuestHistoryPendingPath -Force -ErrorAction SilentlyContinue
            # Not worn in time, but maybe still on adb: Wi-Fi off before the after-script anyway.
            $gone = Get-OnlineQuestSerial
            if (-not $gone) { $gone = Connect-Quest }
            if ($gone -and $wifiOff) { [void](Invoke-QuestWifiOff -DeviceSerial $gone) }
            Invoke-QuestHistoryRetryAfter -Pending $p -Outcome 'gaveup'
            return 1
        }
        $stopRx = [string](& $get 'stopIfCommandLine' '')
        if ($stopRx) {
            $again = Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe' OR Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
                Where-Object { ([string]$_.CommandLine) -match $stopRx -and $_.CreationDate -and $_.CreationDate.ToUniversalTime() -gt $startedAt } | Select-Object -First 1
            if ($again) {
                Write-QuestLog 'History retry: the session started again - stop (its quit deletes those entries).'
                Remove-Item -LiteralPath $script:QuestHistoryPendingPath -Force -ErrorAction SilentlyContinue
                Invoke-QuestHistoryRetryAfter -Pending $p -Outcome 'stopped'
                return 0
            }
        }
        $dev = Get-OnlineQuestSerial
        if (-not $dev) { $dev = Connect-Quest }
        if ($dev) {
            if (-not $proxDone) {
                # The quit could not reach the headset: put the sensor back to normal now.
                $proxDone = ((Invoke-QuestEnableProximity) -eq 0)
                if ($proxDone) { $p.proximity = $false; Write-QuestHistoryPending $p }
            }
            if (Test-QuestHeadsetWorn -DeviceSerial $dev) {
                # Hold the sensor off for the delete (~10-20 s), so the headset can come off again as
                # soon as Quest Browser comes up: with the real sensor on (the quit turned it back on),
                # taking it off sleeps it and the browser stops answering. Put back afterwards.
                $heldSensor = $false
                if ((Get-QuestVirtualProximity -DeviceSerial $dev) -eq 'DISABLED') {
                    $r = Invoke-Adb -TimeoutSec 10 -Arguments @('-s', $dev, 'shell', 'am', 'broadcast', '-a', 'com.oculus.vrpowermanager.prox_close')
                    $heldSensor = ([string]$r.Out) -match 'Broadcast completed'
                }
                if (-not $shownWorn) { Write-QuestLog ("History retry: headset worn - deleting{0}." -f $(if ($heldSensor) { ' (sensor held off for it: the headset can come off now)' } else { '' })); $shownWorn = $true }
                # Let the browser catch up after the headset is put on (Clear-QuestBrowserHistory also
                # waits for its window and UI).
                Start-Sleep -Seconds 1
                try {
                    # The range fallback at most once per helper run: retried every few seconds, its Clear
                    # browsing data dialog would keep popping up while the browser is stuck.
                    $fb = if ($fallbackTried) { '' } else { [string](& $get 'fallbackRange' '') }
                    if ($fb) { $fallbackTried = $true }
                    $page = $null
                    $pref = [string](& $get 'helperUrl' '')
                    if ($pref) { $page = Resolve-QuestHelperUrl -PreferredUrl $pref -FallbackPort ([int](& $get 'helperFallbackPort' 0)) -PcAddress (Get-QuestPcAddress -DeviceSerial $dev) }
                    # The saved origins plus the shared list; the quit left Quest Browser running for this
                    # delete: closed afterwards (closeBrowser) if only empty pages are left, once it worked.
                    $c = Invoke-QuestBrowserCleanup -DeviceSerial $dev -Origins @($p.origins) -HelperUrl $(if ($page) { $page.Url } else { '' }) `
                        -CloseTabs:([bool]$p.closeTabs) -BudgetSec 40 -FallbackRange $fb -KeepBrowserOnFailure `
                        -CloseBrowser:([bool](& $get 'closeBrowser' $false))
                    $res = $c.History
                } finally {
                    if ($heldSensor) { [void](Invoke-QuestEnableProximity) }
                }
                if ($res -eq 'cleared' -or $res -eq 'fallback') {
                    Write-QuestLog ("History retry: done{0}." -f $(if ($res -eq 'fallback') { ' (range fallback)' } else { '' }))
                    Remove-Item -LiteralPath $script:QuestHistoryPendingPath -Force -ErrorAction SilentlyContinue
                    # Wi-Fi off before the after-script (a held network change cannot move the headset then).
                    if ($wifiOff) { [void](Invoke-QuestWifiOff -DeviceSerial $dev) }
                    Invoke-QuestHistoryRetryAfter -Pending $p -Outcome 'done'
                    return 0
                }
                Write-QuestLog 'History retry: not done yet - trying again while the headset is worn.'
            } else {
                $shownWorn = $false
            }
        }
        # The delete starts within ~2 s of the headset being put on (each check: adb devices, plus one
        # dumpsys vrpowermanager once the headset is there).
        Start-Sleep -Seconds 2
    }
}
