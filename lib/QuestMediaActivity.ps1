# Quest media activity: "one of our pages is playing on the Quest right now", shared across projects.
#
# A project's page server records each media request it serves to its own page (a <video> fetching a
# segment) in %TEMP%\quest-media-activity-<owner>.json; anyone can ask whether any page is playing.
# One file per owner, so writers never race (each replaces only its own file). Other Quest Browser
# playback (YouTube, any site) does not count: only requests to our own servers write these files.
# (adb `dumpsys audio` cannot tell: it reports playback per app, with no URL.)
#
# File format (UTF-8 JSON; write to <file>.tmp, then rename over the file):
#   { "owner": "playlist", "lastMediaEpoch": 1764134400.5, "lastMediaUtc": "2026-11-26T05:20:00+00:00",
#     "media": "hybrid/3d_op_00_Full_SBS.mkv", "pid": 1234 }
# lastMediaEpoch (Unix seconds, UTC) is what readers use; the rest is for people reading the file.
# Write at most every ~15 s: readers only need freshness to within a minute or so.
#
# Writers: 3d_playlist_local xr\serve_xr_page.py (owner playlist, Python, writes the format itself);
# PowerShell servers can call Set-QuestMediaActivity. Reader: Loop Segments' keep-awake (renews the
# phone's Keep Alive while anything plays).

$script:QuestMediaActivityPrefix = 'quest-media-activity-'

function Get-QuestMediaActivityPath {
    param([Parameter(Mandatory)] [string] $Owner)
    $safe = ($Owner -replace '[^A-Za-z0-9_.-]', '_')
    return (Join-Path $env:TEMP ($script:QuestMediaActivityPrefix + $safe + '.json'))
}

function Set-QuestMediaActivity {
    param([Parameter(Mandatory)] [string] $Owner, [string] $Media = '')
    $path = Get-QuestMediaActivityPath -Owner $Owner
    $rec = [ordered]@{
        owner          = $Owner
        lastMediaEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0
        lastMediaUtc   = [DateTime]::UtcNow.ToString('o')
        media          = $Media
        pid            = $PID
    }
    $tmp = "$path.tmp"
    $rec | ConvertTo-Json -Compress | Set-Content -LiteralPath $tmp -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

# Every owner's last media request, newest first: [pscustomobject]{ Owner; AgeSec; Media; Path }.
# -FreshSec N: only those within the last N seconds (a clock a little ahead counts as fresh too).
function Get-QuestMediaActivity {
    param([double] $FreshSec = 0)
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0
    $out = foreach ($f in @(Get-ChildItem -LiteralPath $env:TEMP -Filter ($script:QuestMediaActivityPrefix + '*.json') -File -ErrorAction SilentlyContinue)) {
        try { $j = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction Stop | ConvertFrom-Json } catch { continue }
        if ($null -eq $j -or -not $j.PSObject.Properties['lastMediaEpoch']) { continue }
        $age = $now - [double]$j.lastMediaEpoch
        if ($FreshSec -gt 0 -and ($age -gt $FreshSec -or $age -lt -60)) { continue }
        $owner = if ($j.PSObject.Properties['owner'] -and $j.owner) { [string]$j.owner } else { $f.BaseName.Substring($script:QuestMediaActivityPrefix.Length) }
        [pscustomobject]@{
            Owner  = $owner
            AgeSec = $age
            Media  = $(if ($j.PSObject.Properties['media']) { [string]$j.media } else { '' })
            Path   = $f.FullName
        }
    }
    return @($out | Sort-Object AgeSec)
}
