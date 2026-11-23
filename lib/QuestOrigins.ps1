# quest_tools: the shared list of web origins opened in Quest Browser by any project.
# Dot-sourced by QuestTools.ps1; needs Write-QuestLog (and, for Remove-QuestClosedOrigins, an open
# DevTools session: Get-QuestLanTabs).
#
# Every page a project opens on the headset (Loop Segments' phone LAN page and control page,
# 3d_playlist_local's XR page, ...) is registered here when it is opened, with an owner name.
# Every Quest Browser cleanup (tabs + history) adds these origins to its own, so whichever quit runs
# first cleans up the pages of all projects - not only the ones it knows itself.
#
#   Register-QuestBrowserOrigin -Url http://pc:18768/xr -Owner 3d_playlist_local-xr
#   Get-QuestRegisteredOrigins [-Owner a,b] [-ExcludeOwner c]
#   Remove-QuestClosedOrigins -Origins $deleted   # after a successful delete, DevTools open
#
# File: %TEMP%\quest-browser-origins.json { origins: [ { origin, owner, firstUtc, lastUtc } ] }.
# Entries leave it when a cleanup deleted their history with no tab left open on them, or after
# $script:QuestOriginsMaxDays without being opened again (newest $script:QuestOriginsMax kept).

$script:QuestOriginsPath = Join-Path $env:TEMP 'quest-browser-origins.json'
$script:QuestOriginsMaxDays = 30
$script:QuestOriginsMax = 32

# scheme://host[:port] in lower case, without login, path or trailing slash; $null when not http(s).
function ConvertTo-QuestOrigin {
    param([string] $Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return $null }
    try {
        $u = [Uri]($Url.Trim())
        if (-not $u.IsAbsoluteUri -or $u.Scheme -notin @('http', 'https')) { return $null }
        return ('{0}://{1}' -f $u.Scheme, $u.Authority).ToLowerInvariant()
    } catch { return $null }
}

# Runs $Action on the entry list under a cross-process lock and saves the list it returns as
# @{ list = ... } (an empty list included); $null = no change. Returns the list as saved / read.
function Update-QuestOriginsFile {
    param([scriptblock] $Action)
    $mutex = [System.Threading.Mutex]::new($false, 'Local\quest-browser-origins')
    $locked = $false
    try {
        try { $locked = $mutex.WaitOne(5000) } catch [System.Threading.AbandonedMutexException] { $locked = $true }
        $list = @()
        try {
            $raw = Get-Content -LiteralPath $script:QuestOriginsPath -Raw -ErrorAction Stop | ConvertFrom-Json
            $list = @(@($raw.origins) | Where-Object { $_ -and $_.origin })
        } catch {}
        $now = [DateTime]::UtcNow
        $fresh = @($list | Where-Object {
                try { ($now - [DateTime]::Parse([string]$_.lastUtc, $null, [Globalization.DateTimeStyles]::RoundtripKind)).TotalDays -le $script:QuestOriginsMaxDays } catch { $false }
            })
        $pruned = $fresh.Count -ne $list.Count
        $r = & $Action $fresh
        if ($null -eq $r -and -not $pruned) { return $fresh }
        $new = if ($null -eq $r) { $fresh } else { @($r.list) }
        $new = @(@($new) | Where-Object { $_ } | Sort-Object { [string]$_.lastUtc } -Descending | Select-Object -First $script:QuestOriginsMax)
        try {
            $tmp = "$($script:QuestOriginsPath).$PID.tmp"
            @{ origins = @($new) } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $tmp -Encoding utf8
            Move-Item -LiteralPath $tmp -Destination $script:QuestOriginsPath -Force
        } catch { Write-QuestLog "Origins: could not save $($script:QuestOriginsPath) - $($_.Exception.Message)" }
        return $new
    } finally {
        if ($locked) { try { $mutex.ReleaseMutex() } catch {} }
        $mutex.Dispose()
    }
}

# Add (or refresh) the origin of -Url / -Origin for -Owner. Call it when the page is opened, or just
# before (a half-failed open can still leave a tab or a history entry).
function Register-QuestBrowserOrigin {
    param([string] $Url, [string] $Origin, [string] $Owner = 'unknown')
    $o = ConvertTo-QuestOrigin -Url $(if ($Origin) { $Origin } else { $Url })
    if (-not $o) { return }
    $owner = if ([string]::IsNullOrWhiteSpace($Owner)) { 'unknown' } else { $Owner.Trim() }
    $stamp = [DateTime]::UtcNow.ToString('o')
    [void](Update-QuestOriginsFile -Action {
            param($list)
            $old = @($list | Where-Object { $_.origin -eq $o -and $_.owner -eq $owner } | Select-Object -First 1)
            $first = if ($old.Count) { [string]$old[0].firstUtc } else { $stamp }
            $keep = @($list | Where-Object { -not ($_.origin -eq $o -and $_.owner -eq $owner) })
            return @{ list = @($keep + [pscustomobject]@{ origin = $o; owner = $owner; firstUtc = $first; lastUtc = $stamp }) }
        })
}

# Registered origins (unique), optionally only those of -Owner / not those of -ExcludeOwner.
function Get-QuestRegisteredOrigins {
    param([string[]] $Owner = @(), [string[]] $ExcludeOwner = @())
    $own = @(@($Owner) | ForEach-Object { [string]$_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $exc = @(@($ExcludeOwner) | ForEach-Object { [string]$_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $list = @(Update-QuestOriginsFile -Action { param($l) $null })
    return @($list |
            Where-Object { (-not $own.Count -or $own -contains [string]$_.owner) -and -not ($exc -contains [string]$_.owner) } |
            ForEach-Object { [string]$_.origin } | Select-Object -Unique)
}

# Drop entries by origin (all owners).
function Unregister-QuestBrowserOrigin {
    param([string[]] $Origins)
    $os = @(@($Origins) | ForEach-Object { ConvertTo-QuestOrigin -Url $_ } | Where-Object { $_ })
    if (-not $os.Count) { return }
    [void](Update-QuestOriginsFile -Action { param($list) @{ list = @($list | Where-Object { $os -notcontains [string]$_.origin }) } })
}

# After a successful history delete of -Origins: drop the registered ones with no tab still open on
# them (an open tab puts its page back in history, so its entry stays for the next cleanup).
# DevTools must be open. Returns how many were dropped.
function Remove-QuestClosedOrigins {
    param([string[]] $Origins)
    $os = @(@($Origins) | ForEach-Object { ConvertTo-QuestOrigin -Url $_ } | Where-Object { $_ } | Select-Object -Unique)
    if (-not $os.Count) { return 0 }
    $reg = @(Get-QuestRegisteredOrigins)
    $done = @($os | Where-Object { $reg -contains $_ -and @(Get-QuestLanTabs -Origins @($_)).Count -eq 0 })
    if ($done.Count) { Unregister-QuestBrowserOrigin -Origins $done }
    return $done.Count
}
