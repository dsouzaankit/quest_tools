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
# page once more. -PrivateTab: a private tab instead (no immersive WebXR there).

$script:QtIncognitoLauncher = 'com.oculus.browser/org.chromium.chrome.browser.incognito.IncognitoTabLauncher'

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

# Best effort: does a Quest Browser tab show -Url? (own DevTools forward, so it works outside a
# session). -Mode Any: login in the URL ignored; Login: loaded through user:pass@ (login cached);
# Plain: exactly -Url, no login in it. $true / $false after ~6 s / $null = could not check.
function Test-QuestBrowserHasUrl {
    param([string] $DeviceSerial, [string] $Url, [ValidateSet('Any', 'Login', 'Plain')] [string] $Mode = 'Any')
    $f = Invoke-Adb -TimeoutSec 10 -Arguments @('-s', $DeviceSerial, 'forward', 'tcp:0', 'localabstract:chrome_devtools_remote')
    $port = 0
    if (-not [int]::TryParse(([string]$f.Out).Trim(), [ref]$port) -or $port -le 0) { return $null }
    try {
        $want = $Url.TrimEnd('/')
        for ($i = 0; $i -lt 12; $i++) {
            try {
                # Invoke-RestMethod emits the JSON array as one object: enumerate it explicitly.
                $tabs = @((Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/list" -TimeoutSec 3 -NoProxy) | ForEach-Object { $_ })
                foreach ($t in $tabs) {
                    $rawUrl = ([string]$t.url).TrimEnd('/')
                    $hasLogin = $rawUrl -match '^https?://[^/@]*@'
                    $bare = $rawUrl -replace '^(https?://)[^/@]*@', '$1'
                    if ($bare -ne $want) { continue }
                    if ($Mode -eq 'Any' -or ($Mode -eq 'Login' -and $hasLogin) -or ($Mode -eq 'Plain' -and -not $hasLogin)) { return $true }
                }
            } catch {}
            Start-Sleep -Milliseconds 500
        }
        return $false
    } finally {
        [void](Invoke-Adb -TimeoutSec 5 -Arguments @('-s', $DeviceSerial, 'forward', '--remove', "tcp:$port"))
    }
}

# Ctrl+L (retried until the address bar has focus), type -TypedUrl, Enter. Never logs -TypedUrl.
function Send-QuestOmniboxUrl {
    param([string] $DeviceSerial, [string] $TypedUrl)
    $omnibox = $false
    for ($i = 0; $i -lt 8 -and -not $omnibox; $i++) {
        # A fresh private tab ignores keys for a moment after launch.
        Start-Sleep -Milliseconds 700
        $k = Invoke-Adb -TimeoutSec 10 -Arguments @('-s', $DeviceSerial, 'shell', 'input', 'keycombination', 'KEYCODE_CTRL_LEFT', 'KEYCODE_L')
        if ($k.Code -ne 0) { Write-QuestLog "Ctrl+L failed: $(Get-AdbMessage $k)"; return $false }
        Start-Sleep -Milliseconds 500
        $omnibox = Test-QuestImeShown -DeviceSerial $DeviceSerial
    }
    if (-not $omnibox) { Write-QuestLog 'Address bar never took focus - not typing the URL.'; return $false }
    foreach ($step in @(, [string[]]@('input', 'text', ("'" + $TypedUrl + "'"))) + @(, [string[]]@('input', 'keyevent', 'KEYCODE_ENTER'))) {
        $k = Invoke-Adb -TimeoutSec 10 -Arguments (@('-s', $DeviceSerial, 'shell') + $step)
        if ($k.Code -ne 0 -or (Get-AdbMessage $k) -match '(?i)Error|Exception|Unknown') {
            Write-QuestLog "'input $($step[1])' failed (code $($k.Code))."
            return $false
        }
        Start-Sleep -Milliseconds 400
    }
    return $true
}

# A private tab (Chromium IncognitoTabLauncher + the URL typed into the address bar). With a login
# URL: loaded once signed in (the private session caches the login), then again plain (a page whose
# URL has user:pass@ cannot fetch() relative URLs).
function Open-QuestIncognitoTab {
    param([string] $DeviceSerial, [string] $Url, [string] $LoginUrl = '')
    if (-not $LoginUrl) { $LoginUrl = $Url }
    $r = Invoke-Adb -TimeoutSec 20 -Arguments @('-s', $DeviceSerial, 'shell', 'am', 'start', '-W', '-n', $script:QtIncognitoLauncher)
    if (-not (Test-AdbStartOk $r)) { Write-QuestLog "Private-tab launcher failed (code $($r.Code)): $(Get-AdbMessage $r)"; return $false }
    # Let the new private tab settle before keystrokes; only type into Quest Browser.
    $resumed = $false
    for ($i = 0; $i -lt 8 -and -not $resumed; $i++) { Start-Sleep -Milliseconds 500; $resumed = Test-QuestBrowserResumed -DeviceSerial $DeviceSerial }
    if (-not $resumed) { Write-QuestLog 'Quest Browser not in front after private-tab launch - not typing the URL.'; return $false }
    if (-not (Send-QuestOmniboxUrl -DeviceSerial $DeviceSerial -TypedUrl $LoginUrl)) { return $false }
    if ($LoginUrl -ne $Url) {
        if ((Test-QuestBrowserHasUrl -DeviceSerial $DeviceSerial -Url $Url -Mode Login) -eq $false) {
            Write-QuestLog 'Signed-in load not seen in the tab list - reloading without the login anyway.'
        }
        Start-Sleep -Milliseconds 800
        if (-not (Send-QuestOmniboxUrl -DeviceSerial $DeviceSerial -TypedUrl $Url)) {
            Write-QuestLog 'Signed in, but could not reload without the login - page fetches will fail.'
            return $true
        }
        $verified = Test-QuestBrowserHasUrl -DeviceSerial $DeviceSerial -Url $Url -Mode Plain
    } else {
        $verified = Test-QuestBrowserHasUrl -DeviceSerial $DeviceSerial -Url $Url -Mode Any
    }
    if ($verified -eq $false) { Write-QuestLog "Typed the URL into the private tab, but no browser tab shows $Url - check the headset." }
    Write-QuestLog "Opened $Url in Quest browser, private tab ($DeviceSerial)"
    return $true
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
        [switch] $PrivateTab,
        [scriptblock] $BeforeOpen = $null
    )
    $Url = $Url -replace "'", ''
    $once = {
        # Before the open: a half-failed one can still leave a tab or a history entry behind.
        Register-QuestBrowserOrigin -Url $Url -Owner $Owner
        if ($PrivateTab) {
            if (Open-QuestIncognitoTab -DeviceSerial $DeviceSerial -Url $Url -LoginUrl $LoginUrl) { return $true }
            Write-QuestLog 'Falling back to a normal tab.'
        }
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
