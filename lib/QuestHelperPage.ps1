# quest_tools: the helper page for the Recently closed sweep (QuestCleanup.ps1 -HelperUrl).
# Dot-sourced by QuestTools.ps1; needs Write-QuestLog.
#
# The sweep sends our closed items to a small page whose visits Quest Browser records, then deletes
# that page from history (README, *Recently closed*). A project usually has such a page (Loop Segments:
# the phone's /xr-assets/lsclean, a small 404 page, no login). When it does not answer (phone app
# closed, phone off the LAN), no visit is recorded and the swept items stay. Then the same kind of page
# is served from this PC instead: Resolve-QuestHelperUrl -PreferredUrl <page> -FallbackPort <port>.
#
#   $h = Resolve-QuestHelperUrl -PreferredUrl 'http://10.0.100.10:8765/xr-assets/lsclean' -FallbackPort 18767 -PcAddress (Get-QuestPcAddress -DeviceSerial $dev)
#   $h.Url             # the page to use (decided once per process)
#   $h.FallbackOrigin  # http://<pc>:<port> when the PC serves it, else $null: delete it with ours

$script:QtHelperPage = $null
$script:QtHelperPageMarker = '<!-- loopsegments-lsclean -->'

# This PC's IPv4 address on the route to -Target (or to the headset of a wireless adb serial
# ip:port). UDP "connect" sends nothing. $null when unknown.
function Get-QuestPcAddress {
    param([string] $DeviceSerial = '', [string] $Target = '')
    if (-not $Target -and $DeviceSerial -match '^(\d{1,3}(?:\.\d{1,3}){3}):\d+$') { $Target = $Matches[1] }
    if (-not $Target) { return $null }
    $u = [System.Net.Sockets.UdpClient]::new()
    try {
        $u.Connect($Target, 9)
        return ([System.Net.IPEndPoint]$u.Client.LocalEndPoint).Address.ToString()
    } catch { return $null } finally { $u.Dispose() }
}

function Test-QuestTcpOpen {
    param([string] $HostName, [int] $Port, [int] $TimeoutMs = 2000)
    $c = [System.Net.Sockets.TcpClient]::new()
    try { return ($c.ConnectAsync($HostName, $Port).Wait($TimeoutMs) -and $c.Connected) } catch { return $false } finally { $c.Dispose() }
}

function Test-QuestHelperPageServing {
    param([string] $Origin)
    try {
        $r = Invoke-WebRequest -Uri "$Origin/lsclean" -TimeoutSec 3 -UseBasicParsing -SkipHttpErrorCheck
        return ([string]$r.Content).Contains($script:QtHelperPageMarker)
    } catch { return $false }
}

# Static 404 page on all addresses, port -Port, from a hidden pwsh that exits with this process (or
# after 30 min). A separate process: a listener in this one kept it from exiting after its work
# (callers then waited out their timeouts). A second caller reuses one already serving it. Needs
# pwsh allowed through Windows Firewall on private networks. $true when it answers.
function Start-QuestHelperPageServer {
    param([int] $Port)
    $origin = "http://127.0.0.1:$Port"
    if (Test-QuestHelperPageServing -Origin $origin) { return $true }
    $server = @'
param([int] $Port, [int] $ParentPid, [string] $Marker)
$l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $Port)
try { $l.Start() } catch { exit 1 }
$body = [System.Text.Encoding]::ASCII.GetBytes("<!doctype html><title>Loop Segments</title>$Marker")
$until = [DateTime]::UtcNow.AddMinutes(30)
try {
    while ([DateTime]::UtcNow -lt $until -and (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue)) {
        if (-not $l.Pending()) { Start-Sleep -Milliseconds 100; continue }
        $c = $l.AcceptTcpClient()
        try {
            $s = $c.GetStream()
            $s.ReadTimeout = 3000
            $buf = [byte[]]::new(8192)
            [void]$s.Read($buf, 0, $buf.Length)
            $hdr = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 404 Not Found`r`nContent-Type: text/html; charset=utf-8`r`nContent-Length: $($body.Length)`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n")
            $s.Write($hdr, 0, $hdr.Length)
            $s.Write($body, 0, $body.Length)
            $s.Flush()
        } catch {} finally { $c.Close() }
    }
} finally { $l.Stop() }
'@
    $file = Join-Path $env:TEMP 'loopsegments-quest-helper-page.ps1'
    try { Set-Content -LiteralPath $file -Value $server -Encoding utf8 } catch { return $false }
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = (Get-Process -Id $PID).Path
    foreach ($a in @('-NoProfile', '-NoLogo', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $file, '-Port', "$Port", '-ParentPid', "$PID", '-Marker', $script:QtHelperPageMarker)) { [void]$psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    try { [void][System.Diagnostics.Process]::Start($psi) } catch { return $false }
    for ($i = 0; $i -lt 25; $i++) {
        Start-Sleep -Milliseconds 200
        if (Test-QuestHelperPageServing -Origin $origin) { return $true }
    }
    return $false
}

# The helper page to use: -PreferredUrl when its host answers on TCP, else the PC-served page at
# http://<-PcAddress>:<-FallbackPort>/lsclean (started here), else -PreferredUrl anyway (the swept
# items may then stay). Decided once per process. Returns { Url, FallbackOrigin }.
function Resolve-QuestHelperUrl {
    param([string] $PreferredUrl, [int] $FallbackPort = 0, [string] $PcAddress = '')
    if ($script:QtHelperPage) { return $script:QtHelperPage }
    $u = $null
    try { $u = [Uri]$PreferredUrl } catch {}
    if (-not $u -or -not $u.IsAbsoluteUri) { return [pscustomobject]@{ Url = $PreferredUrl; FallbackOrigin = $null } }
    if (Test-QuestTcpOpen -HostName $u.Host -Port $u.Port) {
        $script:QtHelperPage = [pscustomobject]@{ Url = $PreferredUrl; FallbackOrigin = $null }
    } elseif ($FallbackPort -gt 0 -and $PcAddress -and (Start-QuestHelperPageServer -Port $FallbackPort)) {
        $origin = "http://${PcAddress}:$FallbackPort"
        $script:QtHelperPage = [pscustomobject]@{ Url = "$origin/lsclean"; FallbackOrigin = $origin }
        Write-QuestLog "Helper page: $($u.Authority) not answering - serving it from this PC at $origin/lsclean."
    } else {
        $script:QtHelperPage = [pscustomobject]@{ Url = $PreferredUrl; FallbackOrigin = $null }
        $why = if (-not $PcAddress) { 'no route to the headset' } elseif ($FallbackPort -le 0) { 'none set' } else { "port $FallbackPort not served" }
        Write-QuestLog "Helper page: $($u.Authority) not answering and no PC fallback ($why) - Recently closed items may stay."
    }
    return $script:QtHelperPage
}
