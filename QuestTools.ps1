# quest_tools: generic Meta Quest headset helpers over adb (Windows, PowerShell 7).
#
# Dot-source this file at the top level of your script (not inside a function): every helper lands
# in your script scope and shares its $script: state.
#
#   . (Join-Path $questToolsRepo 'QuestTools.ps1')
#   Initialize-QuestTools -AdbExe $cfgAdbExe -QuestHost $cfgHost   # all optional
#   $script:Adb = Find-QuestAdbExe                                  # needed before Invoke-Adb
#   $dev = Get-OnlineQuestSerial; if (-not $dev) { $dev = Connect-Quest }
#
# lib\QuestLog.ps1       Write-QuestLog (%TEMP%\loopsegments-quest-lantab.log)
# lib\QuestAdbServer.ps1 Reset-QuestAdbServer (incl. a stuck server), Start-QuestAdbServerDetached
# lib\QuestAdb.ps1       Find-QuestAdbExe, Invoke-Adb, Get-/Find-OnlineQuestSerial, Connect-Quest (last
#                        address, questAdbHost, mDNS, adb server restart), Repair-QuestAdbStuckServer,
#                        Get-QuestWakefulness, Test-QuestHeadsetWorn, Get-AdbMessage
# lib\QuestDevice.ps1    proximity sensor (Invoke-Quest{Enable,Disable,Toggle}Proximity), keep-awake
#                        (Invoke-QuestKeepAwakeSession), Invoke-QuestWifiOff, ConvertFrom-QuestProcNetAddress
# lib\QuestBrowser.ps1   Quest Browser process / activity checks, Close-QuestBrowserIfEmpty, probe
# lib\QuestDevTools.ps1  Quest Browser over its DevTools socket: tabs, CDP, chrome://flags, history,
#                        Recently closed
# lib\QuestOrigins.ps1   shared list of origins opened in Quest Browser by any project
#                        (Register-QuestBrowserOrigin, Get-QuestRegisteredOrigins): every cleanup uses it
# lib\QuestCleanup.ps1   Invoke-QuestBrowserCleanup: close our tabs, delete our history and Recently
#                        closed items, close the browser when empty (Clear-QuestHistoryAndClosed)
# lib\QuestHelperPage.ps1 the sweep's helper page: Resolve-QuestHelperUrl (a project's page, else one
#                        served from this PC), Get-QuestPcAddress
# lib\QuestHistoryRetry.ps1 after-quit history helper: Start-QuestHistoryRetry hands a failed delete
#                        to Invoke-QuestHistoryRetry.ps1 (detached; deletes once the headset is worn),
#                        Stop-QuestHistoryRetry, Get-QuestHistoryRetryProcesses
# lib\QuestSkybox.ps1    SKYBOX VR Player: add / update / remove a WebDAV server in its database
#
# State shared across processes (keep these names: a running caller and a newer one must agree):
#   %TEMP%\loopsegments-quest-last-adb.txt    last ip:port the headset was on adb at
#   %TEMP%\loopsegments-adb-rediscover.txt    last adb server restart for mDNS rediscovery
#   %TEMP%\loopsegments-adb-stuck-reset.txt   last stuck-server reset
#   %TEMP%\loopsegments-skybox-webdav.json    SKYBOX servers this PC added
#   %TEMP%\quest-browser-origins.json         origins opened in Quest Browser (QuestOrigins.ps1)
#   %TEMP%\loopsegments-quest-history-pending.json  the delete the after-quit helper waits to do

$script:QuestToolsRoot = $PSScriptRoot

# Defaults (Initialize-QuestTools overrides them).
$script:QtAdbExe = ''
$script:QtSerial = ''
$script:QtHost = ''
$script:QtPort = 5555
$script:QtBrowserPackage = 'com.oculus.browser'
if (-not (Get-Variable -Name AdbRediscoverSec -Scope Script -ErrorAction SilentlyContinue)) { $script:AdbRediscoverSec = 60 }
if (-not (Get-Variable -Name Adb -Scope Script -ErrorAction SilentlyContinue)) { $script:Adb = $null }
$script:LastConnectMsg = ''

foreach ($qtLib in 'QuestLog', 'QuestAdbServer', 'QuestAdb', 'QuestDevice', 'QuestBrowser', 'QuestDevTools', 'QuestOrigins', 'QuestHelperPage', 'QuestCleanup', 'QuestHistoryRetry', 'QuestSkybox') {
    . (Join-Path $PSScriptRoot "lib\$qtLib.ps1")
}
Remove-Variable -Name qtLib -ErrorAction SilentlyContinue

# Settings for the helpers. Empty / 0 = keep the default:
#   -AdbExe        adb.exe to use (else PATH, Android SDK, WinGet, Meta Quest Developer Hub)
#   -Serial        only this adb serial counts as the headset
#   -QuestHost     `adb connect <QuestHost>:<Port>` before mDNS (default port 5555)
#   -RediscoverSec restart the adb server after this many seconds without the headset (0 = never)
#   -LogPath       log file (default %TEMP%\loopsegments-quest-lantab.log)
function Initialize-QuestTools {
    param(
        [string] $AdbExe = '',
        [string] $Serial = '',
        [string] $QuestHost = '',
        [int] $Port = 0,
        [Nullable[int]] $RediscoverSec = $null,
        [string] $LogPath = ''
    )
    $script:QtAdbExe = [string]$AdbExe
    $script:QtSerial = [string]$Serial
    $script:QtHost = [string]$QuestHost
    $script:QtPort = if ($Port -gt 0) { $Port } else { 5555 }
    if ($null -ne $RediscoverSec) { $script:AdbRediscoverSec = [int]$RediscoverSec }
    if ($LogPath) { $script:QuestLogPath = $LogPath }
}
