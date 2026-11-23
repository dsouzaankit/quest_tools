# quest_tools: Quest Browser cleanup - close our tabs, delete our history (and the Recently closed
# items it leaves), close the browser when nothing else is open. Dot-sourced by QuestTools.ps1; needs
# QuestDevTools.ps1, QuestBrowser.ps1, QuestOrigins.ps1, Write-QuestLog.
#
# Callers pass the origins they know (e.g. Loop Segments: the phone LAN page, the control page);
# every origin in the shared list (QuestOrigins.ps1) is added, so one cleanup covers the pages of
# every project.
#
#   $c = Invoke-QuestBrowserCleanup -DeviceSerial $dev -Origins $mine -HelperUrl $helper -CloseTabs -CloseBrowser
#   $c.History   # 'cleared' | 'fallback' | 'failed' | 'postponed' | 'skipped'
#
# -HelperUrl: a small page that lands in history (Loop Segments: the phone's /xr-assets/lsclean, or
# the same page served from this PC). The Recently closed sweep sends our closed items there, then
# the history delete removes it; its origin is always deleted too.

# Visit -HelperUrl in an open empty tab (new-tab / blank page) and put the tab back as it was,
# without back/forward entries. DevTools must be open.
function Invoke-QuestHelperVisitInOpenTab {
    param([string] $HelperUrl)
    $tab = Get-QuestTabs | Where-Object { $u = [string]$_.url; $u -like 'chrome://panel-app-nav/ntp*' -or $u -eq 'about:blank' } | Select-Object -First 1
    if (-not $HelperUrl) { return }
    if (-not $tab) {
        $urls = @(Get-QuestTabs | ForEach-Object { (ConvertTo-QuestBareUrl ([string]$_.url)) -replace '\?.*$', '' }) -join ', '
        Write-QuestLog "Recently closed: no new-tab / blank tab open for the helper visit (tabs: $urls)."
        return
    }
    $was = [string]$tab.url
    try {
        [void](Invoke-QuestCdp -Tab $tab -Method 'Page.navigate' -Params @{ url = $HelperUrl } -TimeoutSec 8)
        $t = Wait-QuestTabUrl -Id $tab.id -TimeoutSec 6 -Match { param($u) $u -like 'http*' }
        if ($t) { $tab = $t } else { Write-QuestLog "Recently closed: the helper page did not load in the open tab (was $was)." }
        Start-Sleep -Milliseconds 1500
        $back = if ($was -like 'chrome://panel-app-nav/ntp*') { 'chrome://panel-app-nav/ntp' } else { 'about:blank' }
        [void](Invoke-QuestCdp -Tab $tab -Method 'Page.navigate' -Params @{ url = $back } -TimeoutSec 8)
        $t = Wait-QuestTabUrl -Id $tab.id -TimeoutSec 6 -Match { param($u) $u -notlike 'http*' }
        if ($t) { $tab = $t }
        [void](Invoke-QuestCdp -Tab $tab -Method 'Page.resetNavigationHistory' -TimeoutSec 5)
    } catch {
        Write-QuestLog "Recently closed: helper visit in the open tab failed - $($_.Exception.Message)"
    }
}

# The history delete, then the Recently closed sweep (Invoke-QuestRecentlyClosedSweep) and, when the
# sweep moved items onto the helper page, one more delete for those. DevTools must be open. The
# helper page's origin is added to -Origins. Returns Clear-QuestBrowserHistory's result.
function Clear-QuestHistoryAndClosed {
    param([string] $DeviceSerial, [string[]] $Origins, [double] $BudgetSec, [string] $FallbackRange, [string] $HelperUrl = '')
    $t0 = [DateTime]::UtcNow
    $ho = ConvertTo-QuestOrigin -Url $HelperUrl
    if ($ho) { $Origins = @(@($Origins) + $ho | Select-Object -Unique) }
    $res = Clear-QuestBrowserHistory -DeviceSerial $DeviceSerial -HelperUrl $HelperUrl -Origins $Origins -BudgetSec $BudgetSec -FallbackRange $FallbackRange
    if ($res -ne 'cleared' -and $res -ne 'fallback') { return $res }
    $left = $BudgetSec - ([DateTime]::UtcNow - $t0).TotalSeconds
    if ($left -lt 4 -or -not $HelperUrl) { return $res }
    $n = Invoke-QuestRecentlyClosedSweep -Origins $Origins -HelperUrl $HelperUrl -BudgetSec ($left - 3)
    if ($n -gt 0) {
        # The swept items now point at the helper page, but the visits made in those reopened tabs
        # were not recorded (seen every time an item already on the helper page was swept). The
        # history delete drops Recently closed items by URL, so one recorded visit is enough: make it
        # in a tab that stays open (the kept new-tab page), then put that tab back.
        # Checked: the visit must be in the History list before the delete (one retry), and logged
        # either way (a silent miss left the swept items in place, seen at an End session).
        $recorded = $false
        for ($try = 1; $try -le 2 -and -not $recorded; $try++) {
            Invoke-QuestHelperVisitInOpenTab -HelperUrl $HelperUrl
            $w0 = [DateTime]::UtcNow
            while (-not $recorded -and ([DateTime]::UtcNow - $w0).TotalSeconds -lt 8) {
                Start-Sleep -Milliseconds 500
                $l = Clear-QuestBrowserHistory -DeviceSerial $DeviceSerial -Origins $Origins -BudgetSec 8 -FallbackRange '' -ListOnly
                if ($l -and $l.PSObject.Properties['items']) { $recorded = @(@($l.items) | Where-Object { $_.ours -and ([string]$_.u) -eq $HelperUrl }).Count -gt 0 }
            }
            Write-QuestLog ("Recently closed: helper visit {0} in the History list (try {1})." -f $(if ($recorded) { 'is' } else { 'NOT' }), $try)
        }
        $left = $BudgetSec - ([DateTime]::UtcNow - $t0).TotalSeconds
        [void](Clear-QuestBrowserHistory -DeviceSerial $DeviceSerial -HelperUrl $HelperUrl -Origins $Origins -BudgetSec ([Math]::Max(3, $left)) -FallbackRange '')
    }
    return $res
}

# One cleanup pass, in one DevTools session: close the tabs on our origins (-CloseTabs), delete their
# history (unless -SkipHistory), drop cleaned origins from the shared list, then close Quest Browser
# when only empty pages are left (-CloseBrowser). Our origins = -Origins plus the shared list.
#   -BudgetSec / -BudgetUntil  time for the history step (-BudgetUntil: a deadline, measured when the
#                              history step starts, so the tab closing counts against it)
#   -FallbackRange             Clear browsing data range when the selective delete fails ('' = none)
#   -OnHistoryFailed           { param($Origins) ... } called when the delete failed; return $true
#                              when it was handed over (e.g. an after-quit helper): History = 'postponed'
#   -KeepBrowserOnFailure      with -CloseBrowser: leave the browser running when the delete failed
# Returns { DevTools, Origins, Closed, History, Browser } (Browser: kept | left | closed | failed |
# helper = left for the handed-over delete). DevTools not reachable: History 'failed' (or 'skipped').
function Invoke-QuestBrowserCleanup {
    param(
        [string] $DeviceSerial,
        [string[]] $Origins = @(),
        [string] $HelperUrl = '',
        [switch] $CloseTabs,
        [switch] $SkipHistory,
        [double] $BudgetSec = 25,
        [Nullable[DateTime]] $BudgetUntil = $null,
        [string] $FallbackRange = '',
        [switch] $CloseBrowser,
        [switch] $KeepBrowserOnFailure,
        [scriptblock] $OnHistoryFailed = $null
    )
    $all = @(@($Origins) + @(Get-QuestRegisteredOrigins) | Where-Object { $_ } | ForEach-Object { ([string]$_).Trim().TrimEnd('/') } | Where-Object { $_ } | Select-Object -Unique)
    $r = [ordered]@{ DevTools = $false; Origins = $all; Closed = 0; History = 'skipped'; Browser = 'kept' }
    if (-not (Open-QuestDevTools -DeviceSerial $DeviceSerial)) {
        if (-not $SkipHistory) { $r.History = 'failed' }
        return [pscustomobject]$r
    }
    $r.DevTools = $true
    try {
        if ($CloseTabs) {
            $t0 = [DateTime]::UtcNow
            $r.Closed = Close-QuestOurTabs -Origins $all
            Write-QuestLog ("Tabs: closed {0} Quest Browser tab(s) on our pages ({1:0.0} s)." -f $r.Closed, ([DateTime]::UtcNow - $t0).TotalSeconds)
        }
        if (-not $SkipHistory) {
            $t0 = [DateTime]::UtcNow
            # PowerShell hands a [Nullable[DateTime]] parameter over as the DateTime itself.
            $budget = if ($null -ne $BudgetUntil) { (([DateTime]$BudgetUntil).ToUniversalTime() - $t0).TotalSeconds } else { $BudgetSec }
            $res = Clear-QuestHistoryAndClosed -DeviceSerial $DeviceSerial -Origins $all -BudgetSec $budget -FallbackRange $FallbackRange -HelperUrl $HelperUrl
            # Usually nobody is wearing the headset at quit, and then Quest Browser does not answer.
            if ($res -eq 'failed' -and $OnHistoryFailed -and (& $OnHistoryFailed $all)) { $res = 'postponed' }
            Write-QuestLog ("History step: {0} ({1:0.0} s)." -f $res, ([DateTime]::UtcNow - $t0).TotalSeconds)
            if ($res -eq 'cleared' -or $res -eq 'fallback') { [void](Remove-QuestClosedOrigins -Origins $all) }
            $r.History = $res
        }
        if ($CloseBrowser) {
            # A postponed delete needs the browser: whoever took it over closes it afterwards.
            if ($r.History -eq 'postponed') { $r.Browser = 'helper' }
            elseif ($KeepBrowserOnFailure -and $r.History -eq 'failed') { $r.Browser = 'kept' }
            else { $r.Browser = Close-QuestBrowserIfEmpty -DeviceSerial $DeviceSerial }
        }
    } finally { Close-QuestDevTools }
    return [pscustomobject]$r
}
