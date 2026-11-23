# quest_tools: shared by the double-click helpers (Set-QuestProximitySensor.ps1, Set-QuestWifiOff.ps1,
# and Loop Segments' Reset-QuestBrowserFlags.ps1): run a Quest script with retries until the headset
# is on adb, and the closing message. Dot-source it.

. (Join-Path $PSScriptRoot 'lib\QuestAdbServer.ps1')
$script:QuestHeadsetScript = Join-Path $PSScriptRoot 'Invoke-QuestHeadset.ps1'

# Run -Script with -Arguments. Exit 1 = headset not on adb: try again every ~5 s until -WaitSec runs
# out, restarting the PC's adb server before every retry (when the headset's Wi-Fi comes back,
# wireless debugging gets a new port, and a running adb server can go on missing it over mDNS: seen
# nothing for minutes, listed 4 s after a restart; each try is a new process, so the script's own
# 60 s restart never fires). Prints the script's lines; returns @{ Code; Out }.
#
# -CycleNetworks: when the first try finds no headset, run Find-QuestWifiNetwork.ps1 once (this PC
# through its saved Wi-Fi networks until the headset is on adb; it stays there, else goes back), then
# try again at once; -WaitSec counts from the end of the cycle. Runs before any retry, so its adb
# server restarts never overlap this loop's. A headset on USB passes the first try and never cycles.
function Invoke-QuestWrapperScript {
    param([string] $Script, [string[]] $Arguments, [int] $WaitSec, [switch] $CycleNetworks)
    $pwsh = (Get-Process -Id $PID).Path
    $deadline = [DateTime]::UtcNow.AddSeconds([Math]::Max(0, $WaitSec))
    $tries = 0
    $cycled = -not $CycleNetworks
    while ($true) {
        $tries++
        $out = @(& $pwsh -NoProfile -NoLogo -ExecutionPolicy Bypass -File $Script @Arguments 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
        if ($code -eq 1 -and -not $cycled) {
            $cycled = $true
            Write-Host "  Headset not on adb on this network - trying this PC's saved Wi-Fi networks (Find-QuestWifiNetwork.ps1)..." -ForegroundColor Yellow
            # Straight to this window (no capture): a cycle can take minutes, so show it as it goes.
            & $pwsh -NoProfile -NoLogo -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Find-QuestWifiNetwork.ps1') -NoWait
            $found = ($LASTEXITCODE -eq 0)
            $deadline = [DateTime]::UtcNow.AddSeconds([Math]::Max(0, $WaitSec))
            # Found: the cycle left a fresh adb server with the headset on it - try again now.
            if ($found) { continue }
        }
        if ($code -ne 1 -or [DateTime]::UtcNow -ge $deadline) { break }
        if ($tries -eq 1) {
            Write-Host ("  Headset not on adb yet - trying every 5 s for up to {0} s (put it on / switch its Wi-Fi on; Ctrl+C to stop)..." -f $WaitSec) -ForegroundColor Yellow
        }
        Start-Sleep -Seconds 2
        $adbExe = (Get-Command adb -ErrorAction SilentlyContinue).Source
        if ($adbExe) {
            if ($tries -eq 1) { Write-Host '  (restarting the adb server before each retry)' -ForegroundColor DarkGray }
            # With timeouts: a stuck server never answers kill-server, and this window would hang
            # on it (seen). Reset-QuestAdbServer then kills the adb.exe process instead.
            $how = Reset-QuestAdbServer -AdbExe $adbExe -Log { param($m) Write-Host "  adb: $m" -ForegroundColor Yellow }
            if ($how -eq 'killed') { Write-Host '  adb: the adb server was stuck - killed it and started a fresh one.' -ForegroundColor Yellow }
            Start-Sleep -Seconds 3
        }
    }
    if ($tries -gt 1) { Write-Host "  ($tries tries)" -ForegroundColor DarkGray }
    foreach ($l in $out) { Write-Host "  $l" -ForegroundColor DarkGray }
    Write-Host ''
    return @{ Code = $code; Out = $out }
}

# The error for a failed run (exit 3's wording is the caller's), the log path, the Enter prompt;
# then exit with -Code.
function Exit-QuestWrapper {
    param([int] $Code, [int] $WaitSec, [string] $FailedText, [switch] $NoWait)
    if ($Code -ne 0) {
        $why = switch ($Code) {
            1 { "Headset not reachable over adb within $WaitSec s: wake it (put it on), check its Wi-Fi and wireless debugging, then try again." }
            2 { 'adb not found: winget install Google.PlatformTools (see quest_tools\README.md).' }
            3 { $FailedText }
            default { "Failed (exit $Code)." }
        }
        Write-Host "ERROR: $why" -ForegroundColor Red
    }
    Write-Host "Log: $env:TEMP\loopsegments-quest-lantab.log" -ForegroundColor DarkGray
    if (-not $NoWait) {
        Write-Host ''
        [void](Read-Host 'Press Enter to close')
    }
    exit $Code
}
