# quest_tools: open a page in Quest Browser ("Push to Quest"). Dot-sourced by QuestTools.ps1; needs
# QuestAdb.ps1, QuestBrowser.ps1, QuestDevTools.ps1, QuestOrigins.ps1, Write-QuestLog.
#
#   $dev = (Wait-QuestHeadsetAwake -WaitMinutes 3).Serial
#   if ($dev) { Open-QuestPage -DeviceSerial $dev -Url 'http://pc:18768/xr' -Owner 'myproject' -HelperUrl 'http://pc:18768/xr-assets/lsclean' }
#
# Open-QuestPage: registers the page in the shared origin list (every cleanup closes and deletes it),
# opens it in a normal tab over DevTools (an open tab on -ReuseOrigins is reused; -LoginUrl signs in
# first and reloads plain), closes the empty new-tab pages a cold start leaves, then reads
# window.isSecureContext in the tab: when false (WebXR off), adds the page's origin to chrome://flags
# "unsafely-treat-insecure-origin-as-secure" (Quest Browser restarts, closing its tabs) and opens the
# page once more. Always a normal tab: Quest Browser disables immersive WebXR in private tabs.

# Wait for the headset to be on adb and awake (Get-QuestWakefulness 'Awake'), checking every
# -PollSeconds: up to -WaitMinutes; with -WaitMinutes 0 and -ParentPid, until that process ends; with
# neither, one check. -Ready { $true when the caller is ready too } (checked once awake; -ReadyLabel
# says what is awaited). -OnStatus { param($s) } gets 'checking' and 'queued'. -Label prefixes the log
# lines. -NoConnect: only read `adb devices` (leave finding the headset - adb connect, mDNS, adb server
# restart - to another process, e.g. a keep-awake job). Returns { Serial (when awake), State,
# Reason: awake | timeout | parent }.
function Wait-QuestHeadsetAwake {
    param(
        [double] $WaitMinutes = 0,
        [int] $ParentPid = 0,
        [int] $PollSeconds = 5,
        [string] $Label = '',
        [scriptblock] $Ready = $null,
        [string] $ReadyLabel = 'not ready',
        [scriptblock] $OnStatus = $null,
        [switch] $NoConnect
    )
    $untilParent = ($WaitMinutes -le 0 -and $ParentPid -gt 0)
    $deadline = if ($untilParent) { [DateTime]::MaxValue } elseif ($WaitMinutes -gt 0) { [DateTime]::UtcNow.AddMinutes($WaitMinutes) } else { [DateTime]::UtcNow }
    $lastNote = ''
    $state = ''
    $queued = $false
    if ($OnStatus) { & $OnStatus 'checking' }
    while ($true) {
        if ($ParentPid -gt 0 -and -not (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue)) {
            Write-QuestLog "${Label}process $ParentPid gone before the headset was awake - not opened."
            return [pscustomobject]@{ Serial = $null; State = $state; Reason = 'parent' }
        }
        try {
            $dev = Get-OnlineQuestSerial
            if (-not $dev -and -not $NoConnect) { $dev = Connect-Quest }
            $state = if ($dev) { Get-QuestWakefulness -DeviceSerial $dev } else { 'Unreachable' }
            if (-not $state) { $state = 'Unknown' }
            $ok =($state -eq 'Awake') -and (-not $Ready -or [bool](& $Ready))
            $note = "headset $state$(if ($dev) { " ($dev)" })$(if ($state -eq 'Awake' -and -not $ok) { ", $ReadyLabel" })"
            if ($note -ne $lastNote) { Write-QuestLog "$Label$note"; $lastNote = $note }
            if ($ok) {
                if ($queued) { Write-QuestLog "${Label}headset awake - opening the queued page." }
                return [pscustomobject]@{ Serial = $dev; State = $state; Reason = 'awake' }
            }
        } catch {
            Write-QuestLog "${Label}poll error: $($_.Exception.Message)"
        }
        if ([DateTime]::UtcNow -ge $deadline) {
            if ($WaitMinutes -gt 0) { Write-QuestLog "${Label}headset not awake within $WaitMinutes min ($state) - nothing opened." }
            else { Write-QuestLog "${Label}headset not awake / reachable ($state) - nothing opened." }
            return [pscustomobject]@{ Serial = $null; State = $state; Reason = 'timeout' }
        }
        if (-not $queued) {
            Write-QuestLog ("{0}queued - opening when the headset is awake ({1})." -f $Label, $(if ($untilParent) { "until process $ParentPid ends" } else { "up to $WaitMinutes min" }))
            if ($OnStatus) { & $OnStatus 'queued' }
            $queued = $true
        }
        Start-Sleep -Seconds ([Math]::Max(2, $PollSeconds))
    }
}

# A normal tab, signed in when -LoginUrl differs (Open-QuestSignedInTab), reusing an open tab on
# -ReuseOrigins. -BeforeOpen { param($DeviceSerial) } runs first in the same DevTools session (e.g. a
# companion page in its own tab, so this page ends up in front). Without DevTools: a plain VIEW intent.
function Open-QuestNormalTab {
    param([string] $DeviceSerial, [string] $Url, [string] $LoginUrl = '', [string[]] $ReuseOrigins = @(), [scriptblock] $BeforeOpen = $null)
    if (-not $LoginUrl) { $LoginUrl = $Url }
    if (-not (Open-QuestDevTools -DeviceSerial $DeviceSerial)) {
        $r = Invoke-Adb -TimeoutSec 15 -Arguments @('-s', $DeviceSerial, 'shell', 'am', 'start',
            '-a', 'android.intent.action.VIEW', '-d', ("'" + ($Url -replace "'", '') + "'"), '-p', $script:QtBrowserPackage)
        if (Test-AdbStartOk $r) { Write-QuestLog "Opened $Url in Quest browser, normal tab, not signed in ($DeviceSerial)"; return $true }
        Write-QuestLog "am start failed (code $($r.Code)): $(Get-AdbMessage $r)"
        return $false
    }
    try {
        if ($BeforeOpen) { & $BeforeOpen $DeviceSerial }
        $reuse = @(@($ReuseOrigins) + @(ConvertTo-QuestOrigin -Url $Url) | Where-Object { $_ } | Select-Object -Unique)
        if (-not (Open-QuestSignedInTab -DeviceSerial $DeviceSerial -PlainUrl $Url -LoginUrl $LoginUrl -Origins $reuse)) { return $false }
        $how = if ($LoginUrl -ne $Url) { 'signed in' } else { 'not signed in' }
        $which = if ($script:QuestReusedTab) { 'reused open tab' } else { 'new tab' }
        Write-QuestLog "Opened $Url in Quest browser, normal tab, $how, $which ($DeviceSerial)"
        # A cold start can bring back extra browser windows (Android keeps their records across a
        # force-stop), each on an empty new-tab page. Close empty new-tab pages: a window left with
        # none closes with it. Your own tabs are not touched; the cleanup sweeps the 'New tab' items
        # this leaves in Recently closed.
        $empty = @(Get-QuestTabs | Where-Object { ([string]$_.url) -like 'chrome://panel-app-nav/ntp*' -or ([string]$_.url) -eq 'about:blank' })
        foreach ($t in $empty) { Close-QuestTab -Id $t.id }
        if ($empty.Count) { Write-QuestLog "Closed $($empty.Count) empty new-tab page(s) (extra browser windows from the cold start)." }
        return $true
    } catch {
        Write-QuestLog "Normal tab: $($_.Exception.Message)"
        return $false
    } finally { Close-QuestDevTools }
}

# window.isSecureContext in the open tab on -Url's origin: true only while the insecure-origin flag
# lists that origin, so this checks the flag without opening chrome://flags (no helper tab, no
# "Experiments" in history or Recently closed). Returns 'secure', 'insecure' or 'unknown'.
function Test-QuestPageSecure {
    param([string] $DeviceSerial, [string] $Url)
    $want = ConvertTo-QuestOrigin -Url $Url
    if (-not $want) { return 'unknown' }
    if (-not (Open-QuestDevTools -DeviceSerial $DeviceSerial)) { return 'unknown' }
    try {
        for ($i = 0; $i -lt 10; $i++) {
            foreach ($t in @(Get-QuestLanTabs -Origins @($want))) {
                try {
                    $r = Invoke-QuestEval -Tab $t -TimeoutSec 5 -Expression 'JSON.stringify({ origin: location.origin, secure: window.isSecureContext })' | ConvertFrom-Json
                    if ($r.origin -and $r.origin.ToLowerInvariant() -eq $want) {
                        Write-QuestLog ("Flags: {0} isSecureContext={1} in the open tab." -f $r.origin, $r.secure)
                        return $(if ($r.secure) { 'secure' } else { 'insecure' })
                    }
                } catch {}
            }
            Start-Sleep -Milliseconds 500
        }
        Write-QuestLog 'Flags: could not read isSecureContext in the open tab - flag not checked.'
        return 'unknown'
    } finally { Close-QuestDevTools }
}

# Open -Url on the headset (see the top of this file). -HelperUrl: a small page with no login on a
# reachable host, for the chrome://flags helper tab (a string, or a scriptblock returning one, only
# called when the flag needs fixing). -FlagOrigins: what the flag must list (default the page's
# origin; the flag keeps what it already lists). -NoFlags: no isSecureContext check / flag fix.
# Returns $true when the page opened.
function Open-QuestPage {
    param(
        [string] $DeviceSerial,
        [string] $Url,
        [string] $LoginUrl = '',
        [string] $Owner = 'unknown',
        [string[]] $ReuseOrigins = @(),
        [string[]] $FlagOrigins = @(),
        [object] $HelperUrl = $null,
        [switch] $NoFlags,
        [scriptblock] $BeforeOpen = $null
    )
    $Url = $Url -replace "'", ''
    $once = {
        # Before the open: a half-failed one can still leave a tab or a history entry behind.
        Register-QuestBrowserOrigin -Url $Url -Owner $Owner
        return (Open-QuestNormalTab -DeviceSerial $DeviceSerial -Url $Url -LoginUrl $LoginUrl -ReuseOrigins $ReuseOrigins -BeforeOpen $BeforeOpen)
    }
    if (-not (& $once)) { return $false }
    if ($NoFlags) { return $true }
    if ((Test-QuestPageSecure -DeviceSerial $DeviceSerial -Url $Url) -ne 'insecure') { return $true }
    # Not a secure context: WebXR is off. Fix the flag (restarts Quest Browser, closing its tabs) and
    # open the page again.
    $helper = if ($HelperUrl -is [scriptblock]) { [string](& $HelperUrl) } else { [string]$HelperUrl }
    $origins = @(@($FlagOrigins) + @(ConvertTo-QuestOrigin -Url $Url) | Where-Object { $_ } | Select-Object -Unique)
    $res = 'failed'
    if (-not $helper) { Write-QuestLog 'Flags: no helper page given - flag not fixed.' }
    elseif (Open-QuestDevTools -DeviceSerial $DeviceSerial) {
        try { $res = Sync-QuestInsecureOriginFlag -DeviceSerial $DeviceSerial -Origins $origins -HelperUrl $helper -SkipConfirm }
        catch { Write-QuestLog "Flags: $($_.Exception.Message)" }
        finally { Close-QuestDevTools }
    }
    if ($res -ne 'changed') {
        Write-QuestLog "Flags: page is not a secure context, flag fix result '$res' - XR may not start."
        return $true
    }
    Write-QuestLog 'Flags: fixed - opening the page again after the browser restart.'
    if (-not (& $once)) { return $false }
    # The confirmation: the reopened page is a secure context now (logged by the check).
    if ((Test-QuestPageSecure -DeviceSerial $DeviceSerial -Url $Url) -eq 'insecure') {
        Write-QuestLog 'Flags: the page is still not a secure context after the restart - the flag did not stick, XR may not start.'
    }
    return $true
}
