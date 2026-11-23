# quest_tools: this PC, as the headset sees it, and hidden helper processes on it. Dot-sourced by
# QuestTools.ps1; needs Invoke-Adb, Write-QuestLog.
#
#   $ip   = Get-QuestPcAddress -DeviceSerial $dev -DefaultRoute    # this PC's IPv4 on the route to the headset
#   $name = Resolve-QuestPcHost -DeviceSerial $dev -Ip $ip         # <COMPUTERNAME>.local when the headset resolves it
#   $p    = Start-QuestHiddenProcess -Script C:\x\Job.ps1 -Arguments @('-A', 'b')

# This PC's IPv4 address on the route to -Target, or to the headset of a wireless adb serial
# (ip:port). UDP "connect" sends nothing. -DefaultRoute: with neither (a USB serial), the address on
# the default route. $null when unknown.
function Get-QuestPcAddress {
    param([string] $DeviceSerial = '', [string] $Target = '', [switch] $DefaultRoute)
    if (-not $Target -and $DeviceSerial -match '^(\d{1,3}(?:\.\d{1,3}){3}):\d+$') { $Target = $Matches[1] }
    if (-not $Target -and $DefaultRoute) { $Target = '192.0.2.1' }
    if (-not $Target) { return $null }
    $u = [System.Net.Sockets.UdpClient]::new()
    try {
        $u.Connect($Target, 9)
        return ([System.Net.IPEndPoint]$u.Client.LocalEndPoint).Address.ToString()
    } catch { return $null } finally { $u.Dispose() }
}

# Does the headset resolve -Name to this PC (-Ip, or any of this PC's IPv4 addresses)? Over adb:
# `ping -c 1` prints "PING name (a.b.c.d)" even with no reply (Windows Firewall drops ICMP echo by
# default), so only the name lookup counts.
function Test-QuestHeadsetResolves {
    param([string] $DeviceSerial, [string] $Name, [string] $Ip, [string] $Label = '')
    $r = Invoke-Adb -Arguments @('-s', $DeviceSerial, 'shell', 'ping', '-c', '1', '-W', '2', $Name) -TimeoutSec 10
    $text = [string]$r.Out + ' ' + [string]$r.Err
    if ($text -match 'PING\s+\S+\s+\((\d{1,3}(?:\.\d{1,3}){3})\)') {
        $got = $Matches[1]
        $mine = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { $_.IPAddress })
        if ($got -eq $Ip -or $mine -contains $got) { return $true }
        Write-QuestLog "${Label}the headset resolves $Name to $got, not this PC ($Ip) - not used."
    }
    return $false
}

# The host name a page served from this PC should use on the headset. -Mode: 'auto' = this PC's name
# (<COMPUTERNAME>.local, then <COMPUTERNAME>) when the headset resolves it to this PC, else -Ip;
# 'ip' = always -Ip; anything else = that host name (e.g. a router DNS name for a DHCP reservation).
# A name keeps an origin (and its chrome://flags entry) valid when DHCP hands this PC another address.
function Resolve-QuestPcHost {
    param([string] $DeviceSerial, [string] $Ip, [string] $Mode = 'auto', [string] $Label = '')
    if ($Mode -ieq 'ip') { return $Ip }
    if ($Mode -and $Mode -ine 'auto') { return $Mode }
    $pcName = ([string]$env:COMPUTERNAME).ToLowerInvariant()
    if (-not $pcName) { return $Ip }
    foreach ($n in @("$pcName.local", $pcName)) {
        if (Test-QuestHeadsetResolves -DeviceSerial $DeviceSerial -Name $n -Ip $Ip -Label $Label) { return $n }
    }
    return $Ip
}

# PowerShell 7 for child processes: this one when it is pwsh, else pwsh.exe on PATH, else the usual
# install folders. $null when none.
function Get-QuestPwshExe {
    $self = (Get-Process -Id $PID).Path
    if ($self -and (Split-Path $self -Leaf) -ieq 'pwsh.exe') { return $self }
    $cmd = Get-Command -Name pwsh.exe -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return [string]$cmd.Source }
    foreach ($p in @((Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'), (Join-Path $env:LOCALAPPDATA 'Microsoft\PowerShell\7\pwsh.exe'))) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    return $null
}

# Start a hidden `pwsh -File <Script> <Arguments>` (no window; each argument passed as is, spaces
# included) and return the process. A child of this process: it ends with this one only if the caller
# waits for it or kills it (detached: Start-QuestHistoryRetry's WMI start).
function Start-QuestHiddenProcess {
    param([string] $Script, [string[]] $Arguments = @(), [string] $Pwsh = '')
    if (-not $Pwsh) { $Pwsh = Get-QuestPwshExe }
    if (-not $Pwsh) { throw 'PowerShell 7 (pwsh.exe) not found.' }
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $Pwsh
    foreach ($a in @('-NoProfile', '-NoLogo', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $Script) + @($Arguments)) { [void]$psi.ArgumentList.Add([string]$a) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    return [System.Diagnostics.Process]::Start($psi)
}
