<#
.SYNOPSIS
  Quest control page host: one small signed-in web page on this PC's LAN address for the Quest
  headset, filled with tiles by the projects that use it.

.DESCRIPTION
  Started hidden by the first Register-QuestControlTiles (lib\QuestControl.ps1); exits by itself
  once no registered owner process is alive. Every ~2 s it re-reads %TEMP%\quest-control-tiles.json:
  a new owner's tile module is dot-sourced once, a gone owner's tiles leave the page (an open page
  reloads itself when the set of owners changes).

  Tile module: a .ps1 whose last statement returns a hashtable
    Label       short name for the page header (e.g. '3d_playlist_local')
    Tiles       @( @{ Column = 0 | 1 | 'wide'; Order = 10; Html = '<section>...</section>' } )
    Script      JavaScript, run once in its own function scope; calls QC.register('<owner>', fn).
                fn(status, all) gets this owner's Status result (all = the whole status.json) and
                may return the poll delay it wants in ms (the smallest wins; default 10 s).
    Status      { ... } -> object for status.json (owners.<owner>)
    Routes      @{ '/path' = { param($Ctx) ...; @{ Code = 200; Body = <object> } } }: POST only,
                with the X-Quest-Control header. $Ctx: Remote, Query, Port.
    Login       { -> @{ User; Password } or $null }: also accept HTTP Basic with this login.
    OnSpeedTest { param($Result) ... }: after each PC -> Quest measurement.
  Functions the module defines land in this script's scope (prefix them with the owner's name).
  Write-QuestControlLog and the quest_tools helpers are available to it.

  Built in: the "LAN bandwidth: PC -> Quest" tile. On the headset the page downloads
  GET /speedtest/blob (64 MB) and posts bytes + milliseconds to POST /speedtest/result (recorded
  only from a non-loopback client). The measurement goes to %TEMP%\quest-lan-throughput.json
  { ok, path, measuredMbps, bytes, seconds, client, measuredAtUtc }; what a project does with it
  (e.g. a segment bitrate) is the project's own logic, in its tile module.

  Reachable from the LAN, so every request must pass all of:
    - client address is loopback or private (10/8, 172.16/12, 192.168/16, 169.254/16)
    - Host header is an IP literal or localhost (no DNS names: blocks DNS rebinding)
    - signed in: the qcpc cookie (from /pc?t=<token> on loopback, or /s?t=<token> from the LAN;
      token in %TEMP%\loopsegments-quest-control-pctoken.txt), or HTTP Basic with a module's Login.
      A failed sign-in waits 1 s.
    - actions: POST with header X-Quest-Control: 1 (a form or link on another site cannot send it,
      and the cross-origin preflight is refused)

  Log: %TEMP%\quest-control-host.log
#>
[CmdletBinding()]
param([int] $Port = 0)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'QuestTools.ps1')

$script:HostLog = Join-Path $env:TEMP 'quest-control-host.log'
$script:SpeedResultPath = Join-Path $env:TEMP 'quest-lan-throughput.json'
# Older callers (3d_playlist_local / Loop Segments copies from before the tile host) look for a
# running control page here and reuse it instead of starting their own.
$script:LegacyStatePath = Join-Path $env:TEMP 'loopsegments-quest-control.json'

function Write-QuestControlLog {
    param([string] $Message)
    try { Add-Content -LiteralPath $script:HostLog -Value ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) -Encoding utf8 } catch {}
}

if ($Port -le 0) { $Port = Get-QuestControlPort }

# ---- Request checks ----

function Test-HostPrivateAddress {
    param([System.Net.IPAddress] $Address)
    if ($null -eq $Address) { return $false }
    if ($Address.IsIPv4MappedToIPv6) { $Address = $Address.MapToIPv4() }
    if ([System.Net.IPAddress]::IsLoopback($Address)) { return $true }
    if ($Address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { return $false }
    $b = $Address.GetAddressBytes()
    return ($b[0] -eq 10) -or ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) -or ($b[0] -eq 192 -and $b[1] -eq 168) -or ($b[0] -eq 169 -and $b[1] -eq 254)
}

# Host header is an IP literal or localhost (optional port): DNS names are refused (DNS rebinding).
function Test-HostIpLiteralHeader {
    param([string] $HostHeader)
    if ([string]::IsNullOrWhiteSpace($HostHeader)) { return $false }
    return ($HostHeader.Trim() -match '^(\d{1,3}(\.\d{1,3}){3}|localhost|\[[0-9a-fA-F:]+\])(:\d+)?$')
}

function Get-HostHeader {
    param([string] $HeaderText, [string] $Name)
    foreach ($l in ($HeaderText -split "`r`n")) {
        if ($l -match ('^(?i)' + [regex]::Escape($Name) + ':\s*(.*)$')) { return $Matches[1].Trim() }
    }
    return $null
}

function Test-HostTokenEqual {
    param([string] $A, [string] $B)
    if ([string]::IsNullOrEmpty($A) -or [string]::IsNullOrEmpty($B)) { return $false }
    return [System.Security.Cryptography.CryptographicOperations]::FixedTimeEquals([Text.Encoding]::UTF8.GetBytes($A), [Text.Encoding]::UTF8.GetBytes($B))
}

function Test-HostCookie {
    param([string] $HeaderText)
    $c = Get-HostHeader -HeaderText $HeaderText -Name 'Cookie'
    if (-not $c -or $c -notmatch '(?:^|;\s*)qcpc=([A-Za-z0-9]+)') { return $false }
    return (Test-HostTokenEqual -A $Matches[1] -B (Get-QuestControlToken))
}

# HTTP Basic against every live module's Login.
function Test-HostBasicAuth {
    param([string] $HeaderText)
    $a = Get-HostHeader -HeaderText $HeaderText -Name 'Authorization'
    if (-not $a -or $a -notmatch '^(?i)Basic\s+(\S+)$') { return $false }
    try { $given = [Text.Encoding]::UTF8.GetBytes([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Matches[1]))) } catch { return $false }
    foreach ($m in @($script:Modules.Values)) {
        if (-not $m.Def.ContainsKey('Login') -or -not $m.Def.Login) { continue }
        $login = $null
        try { $login = & $m.Def.Login } catch {}
        if (-not $login -or [string]::IsNullOrEmpty([string]$login.Password)) { continue }
        $want = [Text.Encoding]::UTF8.GetBytes(('{0}:{1}' -f $login.User, $login.Password))
        if ([System.Security.Cryptography.CryptographicOperations]::FixedTimeEquals($want, $given)) { return $true }
    }
    return $false
}

function Test-HostHasBasicLogin {
    foreach ($m in @($script:Modules.Values)) { if ($m.Def.ContainsKey('Login') -and $m.Def.Login) { return $true } }
    return $false
}

# ---- HTTP ----

function Read-HostRequest {
    param([System.Net.Sockets.TcpClient] $Client)
    $stream = $Client.GetStream()
    $stream.ReadTimeout = 5000
    $buffer = New-Object byte[] 16384
    $ms = New-Object System.IO.MemoryStream
    while ($ms.Length -lt 65536) {
        $read = $stream.Read($buffer, 0, $buffer.Length)
        if ($read -le 0) { break }
        $ms.Write($buffer, 0, $read)
        $text = [Text.Encoding]::UTF8.GetString($ms.ToArray())
        $end = $text.IndexOf("`r`n`r`n")
        if ($end -lt 0) { continue }
        $headerText = $text.Substring(0, $end)
        # Bodies are not used (actions carry everything in the path); a Content-Length body is
        # left unread on purpose.
        return [pscustomobject]@{ RequestLine = ($headerText -split "`r`n")[0]; HeaderText = $headerText; Stream = $stream }
    }
    return $null
}

function Write-HostResponse {
    param(
        [System.IO.Stream] $Stream,
        [int] $StatusCode,
        [string] $Body,
        [string] $ContentType = 'application/json; charset=utf-8',
        [string[]] $ExtraHeaders = @()
    )
    $reason = @{ 200 = 'OK'; 202 = 'Accepted'; 302 = 'Found'; 400 = 'Bad Request'; 401 = 'Unauthorized'; 403 = 'Forbidden'; 404 = 'Not Found'; 405 = 'Method Not Allowed'; 409 = 'Conflict'; 500 = 'Internal Server Error' }[$StatusCode]
    if (-not $reason) { $reason = 'Error' }
    $payload = [Text.Encoding]::UTF8.GetBytes($Body)
    $h = "HTTP/1.1 $StatusCode $reason`r`nContent-Type: $ContentType`r`nContent-Length: $($payload.Length)`r`n" +
         "Cache-Control: no-store`r`nX-Frame-Options: DENY`r`nX-Content-Type-Options: nosniff`r`nReferrer-Policy: no-referrer`r`n" +
         "Content-Security-Policy: default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'`r`n"
    foreach ($x in $ExtraHeaders) { $h += "$x`r`n" }
    $h += "Connection: close`r`n`r`n"
    $hb = [Text.Encoding]::ASCII.GetBytes($h)
    $Stream.Write($hb, 0, $hb.Length)
    $Stream.Write($payload, 0, $payload.Length)
    $Stream.Flush()
}

function ConvertTo-HostJson { param($Object) ($Object | ConvertTo-Json -Compress -Depth 6) }

# ---- Tile modules ----

# owner -> @{ Owner; Pid; Module; Def }
$script:Modules = [ordered]@{}

# Live registry entries whose module is not loaded (or changed path), and owners gone since.
function Get-HostOwnerChanges {
    $live = @(Get-QuestControlOwners)
    $toLoad = @($live | Where-Object {
            $o = [string]$_.owner
            -not $script:Modules.Contains($o) -or $script:Modules[$o].Module -ne [string]$_.module -or $script:Modules[$o].Pid -ne [int]$_.pid
        })
    $names = @($live | ForEach-Object { [string]$_.owner })
    $gone = @($script:Modules.Keys | Where-Object { $names -notcontains $_ })
    return [pscustomobject]@{ Live = $live; ToLoad = $toLoad; Gone = $gone }
}

# ---- Built-in: LAN bandwidth PC -> Quest ----

$script:BlobChunk = $null

# Raw octet-stream body of -Bytes bytes (random 1 MiB chunk repeated: not compressible).
function Write-HostBlob {
    param([System.IO.Stream] $Stream, [long] $Bytes)
    if (-not $script:BlobChunk) {
        $script:BlobChunk = [byte[]]::new(1MB)
        [System.Security.Cryptography.RandomNumberGenerator]::Fill($script:BlobChunk)
    }
    try { $Stream.WriteTimeout = 20000 } catch {}
    $h = "HTTP/1.1 200 OK`r`nContent-Type: application/octet-stream`r`nContent-Length: $Bytes`r`nCache-Control: no-store`r`n" +
         "X-Content-Type-Options: nosniff`r`nConnection: close`r`n`r`n"
    $hb = [Text.Encoding]::ASCII.GetBytes($h)
    $Stream.Write($hb, 0, $hb.Length)
    $left = $Bytes
    while ($left -gt 0) {
        $n = [int][Math]::Min([long]$script:BlobChunk.Length, $left)
        $Stream.Write($script:BlobChunk, 0, $n)
        $left -= $n
    }
    $Stream.Flush()
}

function Save-HostSpeedResult {
    param([long] $Bytes, [double] $Ms, [string] $Client)
    $mbps = [Math]::Round(($Bytes * 8.0) / ($Ms / 1000.0) / 1e6, 1)
    $o = [ordered]@{
        ok = $true; path = 'pc->quest'; measuredMbps = $mbps
        bytes = $Bytes; seconds = [Math]::Round($Ms / 1000.0, 2); client = $Client; measuredAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    $tmp = "$($script:SpeedResultPath).tmp"
    ($o | ConvertTo-Json -Compress) | Set-Content -LiteralPath $tmp -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $script:SpeedResultPath -Force
    Write-QuestControlLog ("QUEST_LAN {0} Mbps from {1} ({2} bytes in {3} ms)" -f $mbps, $Client, $Bytes, [int]$Ms)
    foreach ($m in @($script:Modules.Values)) {
        if (-not $m.Def.ContainsKey('OnSpeedTest') -or -not $m.Def.OnSpeedTest) { continue }
        try { & $m.Def.OnSpeedTest ([pscustomobject]$o) } catch { Write-QuestControlLog "OnSpeedTest $($m.Owner): $($_.Exception.Message)" }
    }
    return $o
}

function Get-HostSpeedStatus {
    if (-not (Test-Path -LiteralPath $script:SpeedResultPath)) { return $null }
    try {
        $j = Get-Content -LiteralPath $script:SpeedResultPath -Raw | ConvertFrom-Json
        $at = [DateTime]::Parse([string]$j.measuredAtUtc, $null, [Globalization.DateTimeStyles]::RoundtripKind)
        $j | Add-Member -NotePropertyName ageSec -NotePropertyValue ([int]([DateTime]::UtcNow - $at.ToUniversalTime()).TotalSeconds) -Force
        return $j
    } catch { return $null }
}

function Get-HostStatus {
    $owners = [ordered]@{}
    foreach ($m in @($script:Modules.Values)) {
        $st = $null
        if ($m.Def.ContainsKey('Status') -and $m.Def.Status) {
            try { $st = & $m.Def.Status } catch { $st = @{ error = $_.Exception.Message }; Write-QuestControlLog "STATUS_ERROR $($m.Owner): $($_.Exception.Message)" }
        }
        $owners[$m.Owner] = $st
    }
    return [ordered]@{
        ok         = $true
        ownerNames = @($script:Modules.Keys)
        host       = [ordered]@{ questLan = (Get-HostSpeedStatus) }
        owners     = $owners
    }
}

# ---- Page ----

$script:PageHead = @'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Quest control</title>
<style>
  :root { color-scheme: dark; --bg:#111418; --panel:#1b2027; --line:#2c333d; --text:#e8ecf1; --muted:#9aa5b1; --accent:#4c9aff; --ok:#3fb950; --warn:#d29922; --bad:#f85149; }
  * { box-sizing: border-box; }
  body { margin:0; background:var(--bg); color:var(--text); font:18px/1.45 system-ui, -apple-system, "Segoe UI", sans-serif; }
  main { max-width: 1440px; margin: 0 auto; padding: 14px 16px 12px; }
  header { display:flex; flex-wrap: wrap; align-items: baseline; gap: 4px 14px; margin: 0 0 16px; }
  h1 { font-size: 26px; margin: 0; }
  .sub { color: var(--muted); margin: 0; font-size: 15px; }
  /* Two columns that each stack their own tiles (no shared row height, so no gap under a short
     tile), wrapping to one column on a phone. */
  .tiles { display:flex; flex-wrap: wrap; gap: 12px; align-items: flex-start; }
  .tiles .col { flex: 1 1 420px; min-width: 0; display:flex; flex-direction: column; gap: 12px; }
  .tiles .wide { flex-basis: 100%; }
  section { background: var(--panel); border: 1px solid var(--line); border-radius: 12px; padding: 14px 16px; min-width: 0; }
  .msg:empty { display: none; }
  h2 { font-size: 19px; margin: 0 0 10px; }
  dl { display:grid; grid-template-columns: max-content 1fr; gap: 4px 14px; margin: 0 0 12px; font-size: 16px; }
  dt { color: var(--muted); }
  dd { margin: 0; overflow-wrap: anywhere; font-family: ui-monospace, Consolas, monospace; font-size: 15px; }
  .buttons { display:flex; flex-wrap: wrap; gap: 12px; }
  button { font: inherit; font-size: 16px; font-weight: 600; min-height: 40px; min-width: 96px; padding: 0 16px; border-radius: 8px; border: 1px solid var(--line); background: #252c35; color: var(--text); cursor: pointer; }
  button.primary { background: var(--accent); border-color: var(--accent); color: #0b1320; }
  button.danger { border-color: #6e2b2b; color: #ffb4ae; }
  button:disabled { opacity: .45; cursor: default; }
  .note { color: var(--muted); font-size: 14px; margin: 10px 0 0; }
  .msg { margin-top: 10px; min-height: 1.4em; font-size: 16px; }
  .ok { color: var(--ok); } .warn { color: var(--warn); } .bad { color: var(--bad); }
  .pstate { align-self: center; font-size: 16px; font-weight: 600; padding: 6px 12px; border-radius: 999px; border: 1px solid var(--line); color: var(--muted); }
  .pstate:empty { display: none; }
  .pstate.playing { color: var(--ok); border-color: var(--ok); }
  .pstate.paused { color: var(--warn); border-color: var(--warn); }
  pre { margin: 0; white-space: pre-wrap; overflow-wrap: anywhere; font: 13px/1.5 ui-monospace, Consolas, monospace; color: var(--muted); }
  pre.scroll { max-height: 9em; overflow-y: auto; margin-top: 10px; }
</style>
</head>
<body>
<main>
'@

# Built-in speed test tile (column 1, before the modules' tiles of the same column).
$script:SpeedTileHtml = @'
    <section>
      <h2>LAN bandwidth: PC &rarr; Quest</h2>
      <dl>
        <dt>Result</dt><dd id="qlMbps">-</dd>
        <dt>Measured</dt><dd id="qlAt">-</dd>
      </dl>
      <div class="buttons">
        <button id="qlMeasure" class="primary">Measure PC &rarr; Quest</button>
      </div>
      <div id="qlMsg" class="msg" role="status" aria-live="polite"></div>
      <p class="note">The headset downloads 64 MB from this PC (the same Wi-Fi path the headset streams from). Runs by itself each time this page opens on the Quest (unless a result under 2 min old exists). Only the headset can run it.</p>
    </section>
'@

$script:ShellScript = @'
window.QC = (() => {
  const $ = (id) => document.getElementById(id);
  const renders = {};
  let timer = null;
  const onQuest = /OculusBrowser|Quest/i.test(navigator.userAgent);
  const pageOwners = JSON.parse(document.getElementById('qcOwners').dataset.owners || '[]');
  function setBanner(text, cls) { const m = $('qcMsg'); m.textContent = text; m.className = 'msg ' + (cls || ''); }
  async function post(path) {
    try {
      const r = await fetch(path, { method: 'POST', headers: { 'X-Quest-Control': '1' } });
      const j = await r.json().catch(() => ({}));
      return { ok: r.ok, status: r.status, json: j };
    } catch (e) { return { ok: false, status: 0, json: { error: 'Request failed: ' + e.message } }; }
  }
  function register(owner, fn) { renders[owner] = fn; }
  function schedule(ms) { clearTimeout(timer); timer = setTimeout(refresh, ms); }
  function mbps(v) { return (v === null || v === undefined) ? '-' : Number(v).toFixed(1) + ' Mbps'; }
  async function refresh() {
    let s;
    try {
      const r = await fetch('status.json', { cache: 'no-store' });
      if (!r.ok) throw new Error('HTTP ' + r.status);
      s = await r.json();
    } catch (e) {
      setBanner('PC not reachable (' + e.message + '). This page stops when every program using it has quit.', 'bad');
      document.querySelectorAll('button').forEach(b => b.disabled = true);
      schedule(5000);
      return;
    }
    setBanner('', '');
    // A program joined or left: its tiles come or go.
    if (JSON.stringify(s.ownerNames) !== JSON.stringify(pageOwners)) { location.reload(); return; }
    let next = 10000;
    for (const [owner, fn] of Object.entries(renders)) {
      try {
        const want = fn(owner === 'host' ? s.host : (s.owners || {})[owner], s);
        if (typeof want === 'number' && want > 0 && want < next) next = want;
      } catch (e) { console.error(owner, e); }
    }
    schedule(next);
  }
  return { $, post, register, schedule, refresh, onQuest, mbps, setBanner };
})();
'@

$script:SpeedScript = @'
(() => {
  const { $, onQuest } = QC;
  let running = false, autoDone = false;
  function render(h) {
    const q = h && h.questLan;
    if (q && q.ok) {
      $('qlMbps').textContent = Number(q.measuredMbps).toFixed(1) + ' Mbps (' + (q.bytes / 1048576).toFixed(0) + ' MB in ' + q.seconds + ' s, ' + q.client + ')';
      $('qlMbps').className = 'ok';
      $('qlAt').textContent = new Date(q.measuredAtUtc).toLocaleString();
    }
    $('qlMeasure').disabled = running || !onQuest;
    if (!onQuest && !running && !$('qlMsg').textContent) { $('qlMsg').textContent = 'Run it from the headset (this page on the Quest measures by itself when it opens).'; $('qlMsg').className = 'msg'; }
    // A fresh page on the headset measures once (unless a result under 2 min old exists).
    if (onQuest && !autoDone && !running) { autoDone = true; if (!(q && q.ok && q.ageSec < 120)) measure(); }
  }
  async function measure() {
    const m = $('qlMsg');
    running = true; $('qlMeasure').disabled = true;
    m.textContent = 'Measuring PC -> Quest (64 MB)...'; m.className = 'msg warn';
    try {
      const r = await fetch('speedtest/blob?bytes=' + (64 * 1048576) + '&n=' + Date.now(), { cache: 'no-store' });
      if (!r.ok) throw new Error('HTTP ' + r.status);
      const reader = r.body.getReader();
      let got = 0, t0 = null;
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        if (t0 === null) t0 = performance.now();   // from the first byte: leaves out the request latency
        got += value.length;
      }
      const ms = performance.now() - t0;
      const p = await QC.post('speedtest/result?bytes=' + got + '&ms=' + ms.toFixed(1));
      if (!p.ok) throw new Error(p.json.error || ('HTTP ' + p.status));
      m.textContent = 'Measured ' + Number(p.json.measuredMbps).toFixed(1) + ' Mbps at ' + new Date().toLocaleTimeString() + '.'; m.className = 'msg ok';
    } catch (e) { m.textContent = 'Measurement failed: ' + e.message; m.className = 'msg bad'; }
    running = false; $('qlMeasure').disabled = !onQuest;
    QC.schedule(500);
  }
  $('qlMeasure').addEventListener('click', () => { if (!running) measure(); });
  QC.register('host', render);
})();
'@

function ConvertTo-HostHtmlText { param([string] $Text) return [System.Net.WebUtility]::HtmlEncode($Text) }

function Get-HostPageHtml {
    $cols = @{ '0' = [System.Collections.Generic.List[object]]::new(); '1' = [System.Collections.Generic.List[object]]::new(); 'wide' = [System.Collections.Generic.List[object]]::new() }
    $cols['1'].Add([pscustomobject]@{ Order = 0; Html = $script:SpeedTileHtml })
    $labels = [System.Collections.Generic.List[string]]::new()
    $scripts = [System.Text.StringBuilder]::new()
    foreach ($m in @($script:Modules.Values)) {
        $d = $m.Def
        $labels.Add($(if ($d.ContainsKey('Label') -and $d.Label) { [string]$d.Label } else { $m.Owner }))
        foreach ($t in @($(if ($d.ContainsKey('Tiles')) { $d.Tiles } else { @() }))) {
            if (-not $t) { continue }
            $c = [string]$t.Column
            if (-not $cols.ContainsKey($c)) { $c = '0' }
            $order = 50
            if ($t.ContainsKey('Order') -and $null -ne $t.Order) { $order = [int]$t.Order }
            $cols[$c].Add([pscustomobject]@{ Order = $order; Html = [string]$t.Html })
        }
        if ($d.ContainsKey('Script') -and $d.Script) { [void]$scripts.Append("<script>`n(() => {`n").Append([string]$d.Script).Append("`n})();`n</script>`n") }
    }
    $join = { param($list) (@($list | Sort-Object Order | ForEach-Object { $_.Html }) -join "`n") }
    $sub = if ($labels.Count) { ConvertTo-HostHtmlText ($labels -join ' / ') } else { 'nothing registered' }
    # -InputObject: piping a one-element array would turn it into a bare string.
    $owners = ConvertTo-HostHtmlText (ConvertTo-Json -InputObject @($script:Modules.Keys) -Compress)
    return $script:PageHead +
        "  <header><h1>Quest control</h1><p class=`"sub`">$sub</p></header>`n" +
        "  <div id=`"qcMsg`" class=`"msg`" role=`"status`" aria-live=`"polite`"></div>`n" +
        "  <div class=`"tiles`">`n  <div class=`"col`">`n$(& $join $cols['0'])`n  </div>`n  <div class=`"col`">`n$(& $join $cols['1'])`n  </div>`n" +
        $(if ($cols['wide'].Count) { "  <div class=`"col wide`">`n$(& $join $cols['wide'])`n  </div>`n" } else { '' }) +
        "  </div>`n</main>`n" +
        "<div id=`"qcOwners`" hidden data-owners=`"$owners`"></div>`n" +
        "<script>`n$($script:ShellScript)`n</script>`n<script>`n$($script:SpeedScript)`n</script>`n" +
        $scripts.ToString() +
        "<script>QC.refresh();</script>`n</body>`n</html>`n"
}

# ---- One request ----

function Invoke-HostClient {
    param([System.Net.Sockets.TcpClient] $Client)
    $remote = ([System.Net.IPEndPoint]$Client.Client.RemoteEndPoint).Address
    if ($remote.IsIPv4MappedToIPv6) { $remote = $remote.MapToIPv4() }
    if (-not (Test-HostPrivateAddress -Address $remote)) { Write-QuestControlLog "REFUSED non-private client $remote"; return }
    $req = Read-HostRequest -Client $Client
    if (-not $req) { return }
    $s = $req.Stream
    if ($req.RequestLine -notmatch '^(\S+)\s+(\S+)') { Write-HostResponse -Stream $s -StatusCode 400 -Body '{"ok":false}'; return }
    $method = $Matches[1].ToUpperInvariant()
    $target = $Matches[2]
    $path = ($target -split '\?')[0]
    $query = if ($target.Contains('?')) { $target.Substring($target.IndexOf('?') + 1) } else { '' }
    if (-not (Test-HostIpLiteralHeader -HostHeader (Get-HostHeader -HeaderText $req.HeaderText -Name 'Host'))) {
        Write-HostResponse -Stream $s -StatusCode 400 -Body '{"ok":false,"error":"use the IP address"}'
        return
    }
    # Sign-in links: /pc?t= (loopback only, the link a workflow window prints) and /s?t= (the
    # headset: Open-QuestControlPage types it). Both swap the token for an HttpOnly cookie, so the
    # tab's URL and history carry no token after the redirect.
    if ($method -eq 'GET' -and ($path -eq '/pc' -or $path -eq '/s')) {
        $given = if ($query -match '(?:^|&)t=([A-Za-z0-9]+)') { $Matches[1] } else { '' }
        $tok = Get-QuestControlToken
        $allowed = ($path -eq '/s') -or [System.Net.IPAddress]::IsLoopback($remote)
        if ($allowed -and (Test-HostTokenEqual -A $given -B $tok)) {
            Write-HostResponse -Stream $s -StatusCode 302 -Body '' -ContentType 'text/plain' -ExtraHeaders @('Location: /', "Set-Cookie: qcpc=$tok; Path=/; HttpOnly; SameSite=Strict")
        } else {
            Write-QuestControlLog "TOKEN_REFUSED $path from $remote"
            Start-Sleep -Seconds 1
            Write-HostResponse -Stream $s -StatusCode 403 -Body '{"ok":false,"error":"bad or expired link"}'
        }
        return
    }
    if (-not (Test-HostCookie -HeaderText $req.HeaderText) -and -not (Test-HostBasicAuth -HeaderText $req.HeaderText)) {
        if (Get-HostHeader -HeaderText $req.HeaderText -Name 'Authorization') {
            Write-QuestControlLog "AUTH_FAILED from $remote"
            Start-Sleep -Seconds 1
        }
        $extra = if (Test-HostHasBasicLogin) { @('WWW-Authenticate: Basic realm="Quest control", charset="UTF-8"') } else { @() }
        Write-HostResponse -Stream $s -StatusCode 401 -Body '{"ok":false,"error":"sign in with the link this PC printed or opened"}' -ExtraHeaders $extra
        return
    }
    if ($method -eq 'GET' -and ($path -eq '/' -or $path -eq '/index.html')) {
        Write-HostResponse -Stream $s -StatusCode 200 -Body (Get-HostPageHtml) -ContentType 'text/html; charset=utf-8'
        return
    }
    if ($method -eq 'GET' -and $path -eq '/status.json') {
        Write-HostResponse -Stream $s -StatusCode 200 -Body (ConvertTo-HostJson (Get-HostStatus))
        return
    }
    if ($method -eq 'GET' -and $path -eq '/speedtest/blob') {
        $n = [long](64MB)
        if ($query -match '(?:^|&)bytes=(\d+)') { $n = [long]$Matches[1] }
        $n = [Math]::Max([long]1MB, [Math]::Min([long]128MB, $n))
        Write-QuestControlLog ("QUEST_LAN_BLOB {0} bytes to {1}" -f $n, $remote)
        Write-HostBlob -Stream $s -Bytes $n
        return
    }
    if ($method -eq 'OPTIONS') {
        # No CORS: cross-origin preflights fail, so other sites cannot send the action header.
        Write-HostResponse -Stream $s -StatusCode 405 -Body '{"ok":false}'
        return
    }
    # Actions: built-in speed test result, then the modules' routes.
    $route = $null
    $routeOwner = ''
    if ($path -ne '/speedtest/result') {
        foreach ($m in @($script:Modules.Values)) {
            if ($m.Def.ContainsKey('Routes') -and $m.Def.Routes -and $m.Def.Routes.ContainsKey($path)) { $route = $m.Def.Routes[$path]; $routeOwner = $m.Owner; break }
        }
        if (-not $route) { Write-HostResponse -Stream $s -StatusCode 404 -Body '{"ok":false,"error":"not found"}'; return }
    }
    if ($method -ne 'POST') { Write-HostResponse -Stream $s -StatusCode 405 -Body '{"ok":false,"error":"POST only"}'; return }
    if ((Get-HostHeader -HeaderText $req.HeaderText -Name 'X-Quest-Control') -ne '1') {
        Write-HostResponse -Stream $s -StatusCode 403 -Body '{"ok":false,"error":"missing X-Quest-Control header"}'
        return
    }
    if ($path -eq '/speedtest/result') {
        # PC -> PC (loopback) says nothing about the headset's link.
        if ([System.Net.IPAddress]::IsLoopback($remote)) {
            Write-HostResponse -Stream $s -StatusCode 409 -Body '{"ok":false,"error":"run the test from the headset"}'
            return
        }
        $b = 0L; $ms = 0.0
        if ($query -match '(?:^|&)bytes=(\d+)') { $b = [long]$Matches[1] }
        if ($query -match '(?:^|&)ms=(\d+(?:\.\d+)?)') { $ms = [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture) }
        if ($b -lt 1MB -or $b -gt 128MB -or $ms -lt 20 -or $ms -gt 600000) {
            Write-HostResponse -Stream $s -StatusCode 400 -Body '{"ok":false,"error":"bad measurement"}'
            return
        }
        Write-HostResponse -Stream $s -StatusCode 200 -Body (ConvertTo-HostJson (Save-HostSpeedResult -Bytes $b -Ms $ms -Client ([string]$remote)))
        return
    }
    $ctx = [pscustomobject]@{ Remote = $remote; Query = $query; Port = $Port }
    $res = $null
    try { $res = & $route $ctx } catch {
        Write-QuestControlLog "ROUTE_ERROR $routeOwner $path : $($_.Exception.Message)"
        Write-HostResponse -Stream $s -StatusCode 500 -Body (ConvertTo-HostJson @{ ok = $false; error = $_.Exception.Message })
        return
    }
    $res = @($res | Where-Object { $_ -is [hashtable] -or $_ -is [System.Collections.Specialized.OrderedDictionary] }) | Select-Object -Last 1
    $code = 200
    $body = @{ ok = $true }
    if ($res) { if ($res.Contains('Code')) { $code = [int]$res.Code }; if ($res.Contains('Body')) { $body = $res.Body } }
    Write-HostResponse -Stream $s -StatusCode $code -Body (ConvertTo-HostJson $body)
}

# ---- Main loop ----

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $Port)
try {
    $listener.Start()
} catch {
    Write-QuestControlLog "START_FAILED port $Port : $($_.Exception.Message)"
    exit 1
}
$stateJson = @{ port = $Port; pid = $PID } | ConvertTo-Json -Compress
try { Set-Content -LiteralPath $script:QuestControlStatePath -Value $stateJson -Encoding utf8 } catch {}
try { Set-Content -LiteralPath $script:LegacyStatePath -Value $stateJson -Encoding utf8 } catch {}
Write-QuestControlLog "LISTENING 0.0.0.0:$Port"

# Browsers open spare connections that may never send a request (Quest Browser does). Reading one
# would block every other request, so accepted connections wait in $pending and are handled only
# once data has arrived; ones still silent after 10 s are closed.
$pending = [System.Collections.Generic.List[object]]::new()
$startedAt = [DateTime]::UtcNow
$lastOwnerCheck = [DateTime]::MinValue
$emptyChecks = 0
try {
    while ($true) {
        if (([DateTime]::UtcNow - $lastOwnerCheck).TotalSeconds -ge 2) {
            $lastOwnerCheck = [DateTime]::UtcNow
            $chg = Get-HostOwnerChanges
            foreach ($g in $chg.Gone) { $script:Modules.Remove($g); Write-QuestControlLog "OWNER_GONE $g" }
            # Dot-sourced here, at script scope, so the module's functions stay defined for its
            # scriptblocks.
            foreach ($e in $chg.ToLoad) {
                $o = [string]$e.owner
                try {
                    $def = @(. ([string]$e.module)) | Where-Object { $_ -is [hashtable] } | Select-Object -Last 1
                    if (-not $def) { throw 'module returned no hashtable' }
                    $script:Modules[$o] = [pscustomobject]@{ Owner = $o; Pid = [int]$e.pid; Module = [string]$e.module; Def = $def }
                    Write-QuestControlLog "OWNER_LOADED $o (pid $($e.pid), $($e.module))"
                } catch {
                    Write-QuestControlLog "OWNER_LOAD_FAILED $o ($($e.module)): $($_.Exception.Message)"
                    # Not retried until it registers again with another PID or module path.
                    $script:Modules[$o] = [pscustomobject]@{ Owner = $o; Pid = [int]$e.pid; Module = [string]$e.module; Def = @{ Label = "$o (failed to load)" } }
                }
            }
            if (@($chg.Live).Count -eq 0) { $emptyChecks++ } else { $emptyChecks = 0 }
            # Nobody left (after a short grace at start, while the first owner registers).
            if ($emptyChecks -ge 2 -and ([DateTime]::UtcNow - $startedAt).TotalSeconds -ge 20) { Write-QuestControlLog 'No owner alive - stopping.'; break }
        }
        while ($listener.Pending()) {
            $c = $listener.AcceptTcpClient()
            $remote = ([System.Net.IPEndPoint]$c.Client.RemoteEndPoint).Address
            if (-not (Test-HostPrivateAddress -Address $remote)) {
                Write-QuestControlLog "REFUSED non-private client $remote"
                try { $c.Close() } catch {}
                continue
            }
            $pending.Add([pscustomobject]@{ Client = $c; Since = [DateTime]::UtcNow })
        }
        $ready = @($pending | Where-Object { try { $_.Client.Available -gt 0 } catch { $false } })
        $stale = @($pending | Where-Object { ([DateTime]::UtcNow - $_.Since).TotalSeconds -ge 10 -and $ready -notcontains $_ })
        foreach ($p in $stale) { [void]$pending.Remove($p); try { $p.Client.Close() } catch {} }
        if ($ready.Count -eq 0) { Start-Sleep -Milliseconds 50; continue }
        foreach ($p in $ready) {
            [void]$pending.Remove($p)
            try {
                Invoke-HostClient -Client $p.Client
            } catch {
                Write-QuestControlLog "REQUEST_ERROR $($_.Exception.Message)"
            } finally {
                try { $p.Client.Close() } catch {}
            }
        }
    }
} finally {
    foreach ($p in $pending) { try { $p.Client.Close() } catch {} }
    try { $listener.Stop() } catch {}
    foreach ($sp in $script:QuestControlStatePath, $script:LegacyStatePath) {
        try { if ((Get-Content -LiteralPath $sp -Raw -ErrorAction Stop | ConvertFrom-Json).pid -eq $PID) { Remove-Item -LiteralPath $sp -Force } } catch {}
    }
}
