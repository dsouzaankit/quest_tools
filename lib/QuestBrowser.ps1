# quest_tools: Quest Browser (com.oculus.browser) process / activity checks over adb.
# Dot-sourced by QuestTools.ps1. The DevTools-socket helpers are in QuestDevTools.ps1.

function Test-QuestBrowserResumed {
    param([string] $DeviceSerial)
    $r = Invoke-Adb -Arguments @('-s', $DeviceSerial, 'shell', 'dumpsys', 'activity', 'activities') -TimeoutSec 10
    $resumed = @($r.Out -split "`r?`n" | Where-Object { $_ -match '(?i)ResumedActivity' })
    return (@($resumed | Where-Object { $_ -match [regex]::Escape($script:QtBrowserPackage) }).Count -gt 0)
}

function Test-QuestImeShown {
    param([string] $DeviceSerial)
    $r = Invoke-Adb -Arguments @('-s', $DeviceSerial, 'shell', 'dumpsys', 'input_method') -TimeoutSec 10
    return ($r.Out -match 'mInputShown=true')
}

function Test-QuestBrowserRunning {
    param([string] $DeviceSerial)
    $r = Invoke-Adb -TimeoutSec 8 -Arguments @('-s', $DeviceSerial, 'shell', 'pidof', $script:QtBrowserPackage)
    return ([string]$r.Out).Trim() -match '^\d'
}

# DevTools must be open. Tabs that are yours: not empty (new-tab page, about:blank) and not on the
# phone LAN / control page origins.
function Get-QuestUserTabs {
    param([string[]] $Origins = @())
    $os = @($Origins | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('/').ToLowerInvariant() })
    return @(Get-QuestTabs | Where-Object {
            $u = [string]$_.url
            if ($u -eq '' -or $u -eq 'about:blank' -or $u -like 'chrome://panel-app-nav/ntp*' -or $u -like 'chrome://newtab*') { return $false }
            $b = (ConvertTo-QuestBareUrl $u).ToLowerInvariant()
            -not @($os | Where-Object { $b -eq $_ -or $b.StartsWith("${_}/") }).Count
        })
}

# DevTools must be open. Force-stops Quest Browser when only empty tabs are left (new tab pages).
function Close-QuestBrowserIfEmpty {
    param([string] $DeviceSerial)
    $left = @(Get-QuestUserTabs)
    if ($left.Count -gt 0) {
        Write-QuestLog "Browser: $($left.Count) other tab(s) open - Quest Browser left running."
        return 'left'
    }
    # Chromium writes its Recently closed list a few seconds after a change; a force-stop before that
    # can bring back an older copy on the next start. So give it time to save first.
    Start-Sleep -Seconds 5
    $r = Invoke-Adb -TimeoutSec 10 -Arguments @('-s', $DeviceSerial, 'shell', 'am', 'force-stop', $script:QtBrowserPackage)
    if ($r.Code -ne 0) { Write-QuestLog "Browser: force-stop failed (code $($r.Code))."; return 'failed' }
    Write-QuestLog 'Browser: closed Quest Browser (no tab of yours was open, only empty / blank pages).'
    return 'closed'
}

# Read-only: what Quest Browser exposes for incognito / private launches (full dumpsys saved to %TEMP%).
function Invoke-QuestIncognitoProbe {
    $dev = Get-OnlineQuestSerial
    if (-not $dev) { $dev = Connect-Quest }
    if (-not $dev) {
        Write-QuestLog 'Probe: headset not reachable over adb.'
        return 1
    }
    $dumpPath = Join-Path $env:TEMP 'loopsegments-quest-browser-dumpsys.txt'
    $d = Invoke-Adb -Arguments @('-s', $dev, 'shell', 'dumpsys', 'package', $script:QtBrowserPackage) -TimeoutSec 30
    Set-Content -LiteralPath $dumpPath -Value $d.Out -Encoding utf8
    Write-Host "== Quest Browser ($dev) =="
    $ver = [regex]::Match($d.Out, 'versionName=(\S+)')
    Write-Host ("versionName: {0}" -f $(if ($ver.Success) { $ver.Groups[1].Value } else { '?' }))
    Write-Host "== dumpsys lines matching incognito / private =="
    $hits = @($d.Out -split "`r?`n" | Where-Object { $_ -match '(?i)incognito|private.?tab|privatebrows|OPEN_PRIVATE' } |
        ForEach-Object { $_.Trim() } | Select-Object -Unique)
    if ($hits.Count -eq 0) { Write-Host '(none)' } else { $hits | ForEach-Object { Write-Host "  $_" } }
    Write-Host "== resolve Chromium OPEN_PRIVATE_TAB =="
    $res = Invoke-Adb -Arguments @('-s', $dev, 'shell', 'cmd', 'package', 'resolve-activity', '--brief',
        '-a', 'org.chromium.chrome.browser.incognito.OPEN_PRIVATE_TAB', $script:QtBrowserPackage) -TimeoutSec 15
    Write-Host ("  " + (($res.Out + ' ' + $res.Err) -replace '\s+', ' ').Trim())
    Write-Host "== resolve VIEW http (default handler) =="
    $res = Invoke-Adb -Arguments @('-s', $dev, 'shell', 'cmd', 'package', 'resolve-activity', '--brief',
        '-a', 'android.intent.action.VIEW', '-d', 'http://10.0.0.1/', $script:QtBrowserPackage) -TimeoutSec 15
    Write-Host ("  " + (($res.Out + ' ' + $res.Err) -replace '\s+', ' ').Trim())
    Write-Host "Full dump: $dumpPath"
    Write-QuestLog "Probe done ($dev, $($hits.Count) incognito/private lines) -> $dumpPath"
    return 0
}
