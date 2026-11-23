# quest_tools: Quest Browser (com.oculus.browser) process / activity checks over adb.
# Dot-sourced by QuestTools.ps1. The DevTools-socket helpers are in QuestDevTools.ps1.

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
