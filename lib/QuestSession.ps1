# quest_tools: end-of-session cleanup on the headset, for any project
# (Invoke-QuestHeadset.ps1 -Cleanup runs it). In this order: our tabs closed and their history
# (+ Recently closed) deleted within ~28 s of -StartedAt, Quest Browser closed when only empty
# pages are left, the proximity sensor back on, the Wi-Fi off last.
#
# "Our" pages = every origin in the shared origin list (lib\QuestOrigins.ps1: each project
# registers the pages it opens, the control page included) plus -ExtraOrigins. Usually nobody wears
# the headset at quit and Quest Browser does not answer: then the history delete goes to the
# after-quit helper (lib\QuestHistoryRetry.ps1), which also switches the Wi-Fi off after it.
#
# Returns 0 done, 1 headset not on adb (delete handed to the after-quit helper), 3 incomplete,
# 4 history delete postponed until the headset is worn. Logs "Cleanup: finished ..." at the end
# (other scripts wait for that line).
#
# Settings (Get-QuestToolsSettings): closeTabsOnExit, clearHistoryOnExit, clearHistoryFallback,
# historyRetryMinutes, wifiOffOnExit, controlPort (+ 1 = the PC-served helper page).

function Invoke-QuestSessionCleanup {
    param(
        [string[]] $ExtraOrigins = @(),
        # The project's helper page for the Recently closed sweep ('' = the PC-served one).
        [string] $HelperUrl = '',
        [switch] $CloseTabs,
        [switch] $SkipHistory,
        [switch] $EnableProximity,
        [switch] $WifiOff,
        # The after-quit helper stops when a process with a matching command line starts (e.g. a
        # project that does this cleanup itself at its own quit).
        [string] $StopIfCommandLine = '',
        [Nullable[DateTime]] $StartedAt = $null
    )
    if ($null -eq $StartedAt) { $StartedAt = [DateTime]::UtcNow }
    $settings = Get-QuestToolsSettings
    $fallbackPort = (Get-QuestControlPort) + 1
    $fbRange = Get-QuestHistoryFallbackRange
    $retryMinutes = [int]$settings.historyRetryMinutes
    $since = { ([DateTime]::UtcNow - $StartedAt).TotalSeconds }
    $origins = {
        param([string[]] $More = @())
        @(@(Get-QuestRegisteredOrigins) + @($ExtraOrigins) + @($More) | Where-Object { $_ } | ForEach-Object { ([string]$_).TrimEnd('/') } | Select-Object -Unique)
    }
    $retry = {
        param([string[]] $O, [bool] $CloseBrowser)
        Start-QuestHistoryRetry -Origins $O -Minutes $retryMinutes -CloseTabs:$CloseTabs -Proximity:$EnableProximity -CloseBrowser:$CloseBrowser `
            -HelperUrl $HelperUrl -HelperFallbackPort $fallbackPort -FallbackRange $fbRange -WifiOff:$WifiOff -StopIfCommandLine $StopIfCommandLine
    }

    # Headset only needs to be on adb (awake or not); never waits.
    $dev = Get-OnlineQuestSerial
    if (-not $dev) { $dev = Connect-Quest }
    if (-not $dev) {
        Write-QuestLog 'Cleanup: headset not reachable over adb - skipped.'
        # Close the tabs, delete the entries and reset the sensor once the headset is back.
        if (-not $SkipHistory) { [void](& $retry (& $origins) ([bool]$CloseTabs)) }
        return 1
    }
    Write-QuestLog ("Cleanup: headset on adb after {0:0.0} s." -f (& $since))

    $res = 'skipped'
    $browserRes = 'kept'
    if ($CloseTabs -or -not $SkipHistory) {
        $helper = ''
        $helperOrigin = $null
        if (-not $SkipHistory) {
            $h = Resolve-QuestHelperUrl -PreferredUrl $HelperUrl -FallbackPort $fallbackPort -PcAddress (Get-QuestPcAddress -DeviceSerial $dev -DefaultRoute)
            $helper = [string]$h.Url
            $helperOrigin = $h.FallbackOrigin
        }
        $closeBrowser = [bool]$CloseTabs
        $c = Invoke-QuestBrowserCleanup -DeviceSerial $dev -Origins (& $origins @($helperOrigin)) -HelperUrl $helper `
            -CloseTabs:$CloseTabs -SkipHistory:$SkipHistory -BudgetUntil $StartedAt.AddSeconds(28) `
            -FallbackRange $fbRange -CloseBrowser:$closeBrowser `
            -OnHistoryFailed { param($o) [void](& $retry $o $closeBrowser) }
        $res = if ($c.DevTools) { $c.History } else { 'failed' }
        $browserRes = $c.Browser
        if (($res -eq 'cleared' -or $res -eq 'fallback') -and (Test-Path -LiteralPath $script:QuestHistoryPendingPath)) {
            Remove-Item -LiteralPath $script:QuestHistoryPendingPath -Force -ErrorAction SilentlyContinue
            Write-QuestLog 'History: the postponed delete is done too (pending file removed).'
        }
    }

    $prox = 'skipped'
    if ($EnableProximity) {
        # Always after the history delete: once the sensor is on, an unworn headset may sleep.
        $t0 = [DateTime]::UtcNow
        $prox = if ((Invoke-QuestEnableProximity) -eq 0) { 'on' } else { 'failed' }
        Write-QuestLog ("Proximity step: {0} ({1:0.0} s)." -f $prox, ([DateTime]::UtcNow - $t0).TotalSeconds)
    }

    # Wi-Fi off last. Not while the history delete is pending: the after-quit helper needs the
    # Wi-Fi, and switches it off itself after its delete.
    $wifi = 'kept'
    if ($WifiOff) {
        if ($res -eq 'postponed' -or $res -eq 'failed') {
            Write-QuestLog 'Wi-Fi: left on - the history delete is not done (the after-quit helper switches it off after its delete).'
        } else {
            $wifi = Invoke-QuestWifiOff -DeviceSerial $dev
        }
    }
    Write-QuestLog ("Cleanup: finished {0:0.0} s after start (history {1}, browser {2}, proximity {3}, Wi-Fi {4})." -f (& $since), $res, $browserRes, $prox, $wifi)
    $historyBad = ($res -eq 'failed') -or (($res -eq 'skipped') -and (-not $SkipHistory))
    if ($historyBad -or ($prox -eq 'failed')) { return 3 }
    if ($res -eq 'postponed') { return 4 }
    return 0
}
