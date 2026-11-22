<#
.SYNOPSIS
  Turn the Quest headset's proximity sensor off (stays awake) or on (sleeps when taken off), over adb.

.DESCRIPTION
  Run it with no arguments to flip the sensor: it shows what it did and the sensor's final state
  (or the error) and waits for Enter (-NoWait skips that).

  Off = `am broadcast -a com.oculus.vrpowermanager.prox_close`: the headset acts as if worn, so it
  does not sleep (and stays on adb) when you take it off. On = `...automation_disable`: the real
  sensor is used again. Toggle (the default) flips whichever it is now. Checked against
  `dumpsys vrpowermanager` (Virtual proximity state CLOSE = held off, DISABLED = sensor on). A
  headset reboot also turns the sensor back on. While the sensor is off, the headset shows a
  "Proximity sensor OFF" notification and opens the notifications list (bell) to show it for 20 s
  (the script waits); turning the sensor on removes the notification.

  Runs Invoke-QuestHeadset.ps1 (-DisableProximity / -EnableProximity / -ToggleProximity). A running
  keep-awake session (-KeepAwakeSession) switches the sensor off again within ~20 s after you turn it on.

  Headset not on adb (asleep, or Wi-Fi just switched on): keeps trying every 5 s for up to
  -WaitSec (default 120 s), restarting the adb server before each retry.

  Loop Segments' windows\quest\Set-QuestProximitySensor.ps1 runs this after moving the PC onto the
  phone's network.

  Exit codes: 0 done, 1 headset not on adb, 2 no adb, 3 the headset did not take the change.
  Log: %TEMP%\loopsegments-quest-lantab.log

.EXAMPLE
  .\Set-QuestProximitySensor.ps1                 # Toggle, then wait for Enter

.EXAMPLE
  .\Set-QuestProximitySensor.ps1 -State Off -NoWait
#>
[CmdletBinding()]
param(
    [ValidateSet('On', 'Off', 'Toggle')] [string] $State = 'Toggle',
    # Exit straight away instead of waiting for Enter (for scripts).
    [switch] $NoWait,
    # Headset not on adb: keep trying for this many seconds (every 5 s). 0 = try once.
    [int] $WaitSec = 120
)

. (Join-Path $PSScriptRoot 'QuestWrapperCommon.ps1')

$switch = @{ On = '-EnableProximity'; Off = '-DisableProximity'; Toggle = '-ToggleProximity' }[$State]
Write-Host "Quest proximity sensor: $($State.ToLowerInvariant())..." -ForegroundColor Cyan

# The Quest script prints "[quest] Proximity: ... now 'CLOSE'" (or an error line).
$r = Invoke-QuestWrapperScript -Script $script:QuestHeadsetScript -Arguments @($switch) -WaitSec $WaitSec
if ($r.Code -eq 0) {
    $now = $null
    foreach ($l in $r.Out) { if ($l -match "now '(\w+)'") { $now = $Matches[1] } }
    switch ($now) {
        'CLOSE' { Write-Host 'Sensor is OFF: the headset stays awake (and on adb) when you take it off.' -ForegroundColor Green }
        'DISABLED' { Write-Host 'Sensor is ON: the headset sleeps again when you take it off.' -ForegroundColor Green }
        default { Write-Host "Done (virtual proximity state: $(if ($now) { $now } else { 'unknown' }))." -ForegroundColor Green }
    }
}
Exit-QuestWrapper -Code $r.Code -WaitSec $WaitSec -NoWait:$NoWait -FailedText 'The headset did not take the change (see the lines above).'
