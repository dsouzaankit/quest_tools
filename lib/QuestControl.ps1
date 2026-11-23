# Quest control page: one page on this PC (QuestControlHost.ps1, port controlPort, default 18766)
# that any project fills with its own tiles. A project registers a tile module for as long as one of
# its processes runs; the host is started by the first registration and exits when no registered
# process is alive any more. See README "Quest control page".
#
#   Register-QuestControlTiles -Owner playlist -OwnerPid $workflowPid -Module <path to tiles .ps1>
#   Open-QuestControlPage -DeviceSerial $dev       # signed-in tab on the headset (needs DevTools closed)
#   Get-QuestControlPcLink                         # http://127.0.0.1:<port>/pc?t=<token> for a PC browser
#
# State (shared by every caller and the host):
#   %TEMP%\quest-control-tiles.json            { owners: [ { owner, pid, started, module, registeredUtc } ] }
#   %TEMP%\quest-control-host.json             { port, pid } while the host runs
#   %TEMP%\loopsegments-quest-control-pctoken.txt  sign-in token (kept across sessions: open tabs stay signed in)
#   %TEMP%\quest-control-origins.json          control page origins opened on the headset (last 8)

$script:QuestControlRegistryPath = Join-Path $env:TEMP 'quest-control-tiles.json'
$script:QuestControlStatePath = Join-Path $env:TEMP 'quest-control-host.json'
$script:QuestControlTokenPath = Join-Path $env:TEMP 'loopsegments-quest-control-pctoken.txt'
$script:QuestControlOriginsPath = Join-Path $env:TEMP 'quest-control-origins.json'
$script:QuestControlHostScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'QuestControlHost.ps1'
$script:QuestControlOwner = 'quest-control'

function Get-QuestControlPort {
    $p = 18766
    try { $v = [int](Get-QuestToolsSettings).controlPort; if ($v -gt 0) { $p = $v } } catch {}
    return $p
}

# The sign-in token (created once, kept): /pc?t= on loopback, /s?t= from the headset.
function Get-QuestControlToken {
    try { $t = (Get-Content -LiteralPath $script:QuestControlTokenPath -Raw -ErrorAction Stop).Trim(); if ($t -match '^[A-Za-z0-9]{32,}$') { return $t } } catch {}
    $bytes = [byte[]]::new(24)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $t = -join ($bytes | ForEach-Object { $_.ToString('x2') })
    Set-Content -LiteralPath $script:QuestControlTokenPath -Value $t -Encoding ascii -NoNewline
    return $t
}

function Get-QuestControlPcLink {
    return ('http://127.0.0.1:{0}/pc?t={1}' -f (Get-QuestControlPort), (Get-QuestControlToken))
}

# Start time of a process as 't<ticks>' (a PID can be reused; ConvertFrom-Json would turn an ISO
# string into a DateTime, hence the prefix).
function Get-QuestProcessStartStamp {
    param([int] $ProcessId)
    try { return 't' + (Get-Process -Id $ProcessId -ErrorAction Stop).StartTime.ToUniversalTime().Ticks } catch { return '' }
}

# The running host: @{ Port; Pid } or $null.
function Get-QuestControlHost {
    if (-not (Test-Path -LiteralPath $script:QuestControlStatePath)) { return $null }
    try {
        $s = Get-Content -LiteralPath $script:QuestControlStatePath -Raw -ErrorAction Stop | ConvertFrom-Json
        if (Get-Process -Id ([int]$s.pid) -ErrorAction SilentlyContinue) { return [pscustomobject]@{ Port = [int]$s.port; Pid = [int]$s.pid } }
    } catch {}
    return $null
}

# Registered owners whose process still runs (same PID and start time).
function Get-QuestControlOwners {
    $list = @()
    try { $list = @((Get-Content -LiteralPath $script:QuestControlRegistryPath -Raw -ErrorAction Stop | ConvertFrom-Json).owners) } catch { return @() }
    return @($list | Where-Object { $_ -and [int]$_.pid -gt 0 -and (Get-QuestProcessStartStamp -ProcessId ([int]$_.pid)) -eq [string]$_.started })
}

function Save-QuestControlOwners {
    param([object[]] $Owners)
    $tmp = "$($script:QuestControlRegistryPath).$PID.tmp"
    @{ owners = @($Owners) } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $tmp -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $script:QuestControlRegistryPath -Force
}

# Adds (or replaces) -Owner's entry: its tiles show while -OwnerPid runs. Starts the host when none
# runs. Returns @{ Port; Pid; Started } (Pid 0 = the host did not come up within -WaitSec).
function Register-QuestControlTiles {
    param(
        [Parameter(Mandatory)] [string] $Owner,
        [Parameter(Mandatory)] [int] $OwnerPid,
        [Parameter(Mandatory)] [string] $Module,
        [int] $WaitSec = 15
    )
    $stamp = Get-QuestProcessStartStamp -ProcessId $OwnerPid
    if (-not $stamp) { Write-QuestLog "Control page: owner $Owner PID $OwnerPid is not running - tiles not registered."; return [pscustomobject]@{ Port = 0; Pid = 0; Started = $false } }
    $mutex = [System.Threading.Mutex]::new($false, 'Local\quest-control-tiles')
    try {
        [void]$mutex.WaitOne(10000)
        $keep = @(Get-QuestControlOwners | Where-Object { [string]$_.owner -ne $Owner })
        $entry = [pscustomobject]@{ owner = $Owner; pid = $OwnerPid; started = $stamp; module = [System.IO.Path]::GetFullPath($Module); registeredUtc = [DateTime]::UtcNow.ToString('o') }
        Save-QuestControlOwners -Owners @($keep + $entry)
    } finally { try { $mutex.ReleaseMutex() } catch {}; $mutex.Dispose() }
    [void](Get-QuestControlToken)
    $h = Get-QuestControlHost
    if ($h) { Write-QuestLog "Control page: $Owner tiles registered (host PID $($h.Pid), port $($h.Port))."; return [pscustomobject]@{ Port = $h.Port; Pid = $h.Pid; Started = $false } }
    $port = Get-QuestControlPort
    $p = Start-QuestHiddenProcess -Pwsh (Get-QuestPwshExe) -Script $script:QuestControlHostScript -Arguments @('-Port', "$port")
    $t0 = [DateTime]::UtcNow
    while (([DateTime]::UtcNow - $t0).TotalSeconds -lt $WaitSec) {
        $h = Get-QuestControlHost
        if ($h) { Write-QuestLog "Control page: host started on port $($h.Port) (PID $($h.Pid)) with $Owner tiles."; return [pscustomobject]@{ Port = $h.Port; Pid = $h.Pid; Started = $true } }
        if ($p.HasExited) { break }
        Start-Sleep -Milliseconds 300
    }
    Write-QuestLog "Control page: host did not start on port $port (see %TEMP%\quest-control-host.log)."
    return [pscustomobject]@{ Port = $port; Pid = 0; Started = $false }
}

function Unregister-QuestControlTiles {
    param([Parameter(Mandatory)] [string] $Owner)
    $mutex = [System.Threading.Mutex]::new($false, 'Local\quest-control-tiles')
    try {
        [void]$mutex.WaitOne(10000)
        Save-QuestControlOwners -Owners @(Get-QuestControlOwners | Where-Object { [string]$_.owner -ne $Owner })
    } finally { try { $mutex.ReleaseMutex() } catch {}; $mutex.Dispose() }
}

# This PC's control page origin as the headset reaches it (route to the headset; a USB serial has no
# address, so the route to adbHost stands in, else the default route).
function Get-QuestControlOrigin {
    param([string] $DeviceSerial)
    $target = ''
    if ($DeviceSerial -notmatch '^\d{1,3}(\.\d{1,3}){3}:\d+$' -and $script:QtHost -match '^\d{1,3}(\.\d{1,3}){3}$') { $target = $script:QtHost }
    $ip = Get-QuestPcAddress -DeviceSerial $DeviceSerial -Target $target
    if (-not $ip) { $ip = Get-QuestPcAddress -DefaultRoute }
    if (-not $ip) { return $null }
    return ('http://{0}:{1}' -f $ip, (Get-QuestControlPort))
}

function Get-QuestSavedControlOrigins {
    try { return @((Get-Content -LiteralPath $script:QuestControlOriginsPath -Raw -ErrorAction Stop | ConvertFrom-Json).origins | Where-Object { $_ }) } catch { return @() }
}

function Add-QuestSavedControlOrigin {
    param([string] $Origin)
    if (-not $Origin) { return }
    $list = @(@($Origin) + @(Get-QuestSavedControlOrigins | Where-Object { $_ -ne $Origin }) | Select-Object -First 8)
    try { @{ origins = $list } | ConvertTo-Json | Set-Content -LiteralPath $script:QuestControlOriginsPath -Encoding utf8 } catch {}
}

# Opens the control page on the headset in its own normal tab, signed in with the token link (an
# open tab is reused), and registers its origin so every cleanup closes it and deletes its history.
# Returns $true when the tab opened. Opens and closes its own DevTools session.
function Open-QuestControlPage {
    param([Parameter(Mandatory)] [string] $DeviceSerial)
    if (-not (Get-QuestControlHost)) { Write-QuestLog 'Control page: host not running on this PC - not opened.'; return $false }
    $origin = Get-QuestControlOrigin -DeviceSerial $DeviceSerial
    if (-not $origin) { Write-QuestLog 'Control page: no PC address on the route to the headset - not opened.'; return $false }
    $plain = "$origin/"
    $login = '{0}/s?t={1}' -f $origin, (Get-QuestControlToken)
    # Before the open: a half-failed one can still leave a tab or a history entry behind.
    Register-QuestBrowserOrigin -Origin $origin -Owner $script:QuestControlOwner
    Add-QuestSavedControlOrigin -Origin $origin
    if (-not (Open-QuestDevTools -DeviceSerial $DeviceSerial)) { Write-QuestLog 'Control page: no DevTools connection to Quest Browser.'; return $false }
    try {
        # Keep-awake may have the notifications list open (proximity OFF toast): bring the browser
        # forward so the VIEW intent is not dropped behind that UI.
        Show-QuestBrowserTab -DeviceSerial $DeviceSerial
        if (Open-QuestSignedInTab -DeviceSerial $DeviceSerial -PlainUrl $plain -LoginUrl $login -Origins @($origin)) {
            $which = if ($script:QuestReusedTab) { 'reused open tab' } else { 'new tab' }
            Write-QuestLog "Control page: opened $plain in Quest browser ($which)."
            return $true
        }
        if (@(Get-QuestLanTabs -Origins @($origin)).Count -gt 0) {
            Write-QuestLog "Control page: $plain did not load on the Quest (Windows Firewall blocking port $(Get-QuestControlPort)?)."
        } else {
            Write-QuestLog "Control page: Quest Browser did not open a tab for $plain (VIEW intent dropped)."
        }
        return $false
    } finally { Close-QuestDevTools }
}
