# quest_tools: Meta Quest headset helpers over adb

Generic PowerShell 7 helpers for a Meta Quest (tested on Quest 3) on **wireless adb**, split out of [ios_3d_loop_segments](../iOS%20apps/ios_3d_loop_segments) (`windows\quest\`, commit e865041). Used by:

- **Loop Segments** (`ios_3d_loop_segments\windows\quest\`): the PC companion's Open on Quest, its tiles on the Quest control page, quit cleanup (`Watch-LoopSegmentsQuestLanTab.ps1` loads this repo);
- **3d_playlist_local** (`individual_transcode\quest\`): the workflow's Quest session: keep-awake, its tiles on the Quest control page, the page on the headset, End session and the cleanup (`Invoke-QuestHeadset.ps1` modes and this repo's functions directly; it does not need Loop Segments).

The **Quest control page** both use is hosted here: one page, one port, filled with each project's own tiles. See [Quest control page](#quest-control-page).

It also holds the shared **Quest XR player engine** (`xr\`, A-Frame / WebXR JavaScript) that both projects' Quest Browser pages run: Loop Segments' `/xr` and 3d_playlist_local's PC XR page. See [XR player engine](#xr-player-engine).

Log: `%TEMP%\loopsegments-quest-lantab.log` (one log for all of them).

## Layout

| File | What |
|------|------|
| [`QuestTools.ps1`](QuestTools.ps1) | Loader: dot-source it, then `Initialize-QuestTools` (optional) and $script:Adb = Find-QuestAdbExe` |
| [`Invoke-QuestHeadset.ps1`](Invoke-QuestHeadset.ps1) | Command line: `-Status` (default, read-only), `-ResetAdb`, `-EnableProximity` / `-DisableProximity` / `-ToggleProximity`, `-WifiOff`, `-KeepAwakeSession -ParentPid N [-RestoreProximity]`, `-OpenControlPage [-ParentPid N] [-WaitMinutes M] [-StatusFile F]`, `-Cleanup` (see [End-of-session cleanup](#end-of-session-cleanup)) |
| [`QuestControlHost.ps1`](QuestControlHost.ps1), [`Register-QuestControlTiles.ps1`](Register-QuestControlTiles.ps1) | The [Quest control page](#quest-control-page) host, and the command line to add / remove a project's tiles |
| [`quest-tools.example.json`](quest-tools.example.json) | [Settings](#settings) keys (copy to `quest-tools.json`, per PC, git-ignored) |
| [`Set-QuestProximitySensor.ps1`](Set-QuestProximitySensor.ps1), [`Set-QuestWifiOff.ps1`](Set-QuestWifiOff.ps1) | Double-click tools: retry until the headset is on adb, show the result, wait for Enter |
| [`Find-QuestWifiNetwork.ps1`](Find-QuestWifiNetwork.ps1) | Double-click tool: cycle this PC through its saved Wi-Fi networks (current first, then in range, then the rest) until the headset is on wireless adb (USB entries skipped; with the headset on USB, only its own Wi-Fi entry counts); stays on that network, else goes back. Exit 0 found, 1 not found, 2 no adb / no Wi-Fi |
| [`QuestWrapperCommon.ps1`](QuestWrapperCommon.ps1) | Their shared retry loop and closing message |
| [`lib\QuestLog.ps1`](lib/QuestLog.ps1) | `Write-QuestLog` |
| [`lib\QuestAdbServer.ps1`](lib/QuestAdbServer.ps1) | `Reset-QuestAdbServer` (also a stuck server), `Start-QuestAdbServerDetached` |
| [`lib\QuestAdb.ps1`](lib/QuestAdb.ps1) | `Find-QuestAdbExe`, `Invoke-Adb`, `Get-OnlineQuestSerial`, `Connect-Quest` (+ last address, mDNS, rediscover), `Repair-QuestAdbStuckServer`, `Get-QuestWakefulness`, `Test-QuestHeadsetWorn` |
| [`lib\QuestDevice.ps1`](lib/QuestDevice.ps1) | Proximity sensor (+ the "Proximity sensor OFF" notification), `Invoke-QuestKeepAwakeSession` (`-OnTick { ... }`: the caller's own work on each ~20 s check, headset on adb or not, errors logged once and never fatal; Loop Segments renews the phone's Keep Alive there while [Quest media activity](#quest-media-activity) is fresh), `Invoke-QuestWifiOff`, `ConvertFrom-QuestProcNetAddress` |
| [`lib\QuestBrowser.ps1`](lib/QuestBrowser.ps1) | Quest Browser process / activity checks, `Close-QuestBrowserIfEmpty` |
| [`lib\QuestDevTools.ps1`](lib/QuestDevTools.ps1) | Quest Browser over its DevTools socket: tabs, CDP, `chrome://flags` (insecure-origin flag, Reset all), history delete, *Recently closed* sweep |
| [`lib\QuestOpen.ps1`](lib/QuestOpen.ps1) | Push to Quest: `Wait-QuestHeadsetAwake`, `Open-QuestPage` (registered, one tab reused, signed in, empty tabs closed, `isSecureContext` + insecure-origin flag fix). See [Opening a page](#opening-a-page-push-to-quest) |
| [`lib\QuestOrigins.ps1`](lib/QuestOrigins.ps1) | Shared list of the pages any project opened in Quest Browser: `Register-QuestBrowserOrigin`, `Get-QuestRegisteredOrigins`, `Remove-QuestClosedOrigins`. See [Quest Browser cleanup](#quest-browser-cleanup) |
| [`lib\QuestPc.ps1`](lib/QuestPc.ps1) | This PC as the headset sees it: `Get-QuestPcAddress`, `Resolve-QuestPcHost` (its name when the headset resolves it). Hidden helper processes: `Start-QuestHiddenProcess`, `Get-QuestPwshExe`. See [Pages served from this PC](#pages-served-from-this-pc) |
| [`lib\QuestHelperPage.ps1`](lib/QuestHelperPage.ps1) | The *Recently closed* sweep's helper page: `Resolve-QuestHelperUrl` (a project's page, else one served from this PC) |
| [`lib\QuestHistoryRetry.ps1`](lib/QuestHistoryRetry.ps1), [`Invoke-QuestHistoryRetry.ps1`](Invoke-QuestHistoryRetry.ps1) | After-quit history helper: `Start-QuestHistoryRetry` hands a failed delete to a detached helper that does it once the headset is worn; `Stop-QuestHistoryRetry`, `Get-QuestHistoryRetryProcesses`. See [After-quit history helper](#after-quit-history-helper) |
| [`lib\QuestCleanup.ps1`](lib/QuestCleanup.ps1) | `Invoke-QuestBrowserCleanup` (close our tabs, delete our history and *Recently closed* items, close the browser when empty), `Clear-QuestHistoryAndClosed` |
| [`lib\QuestSkybox.ps1`](lib/QuestSkybox.ps1) | SKYBOX VR Player: add / update / remove a WebDAV server in its database |
| [`lib\QuestSettings.ps1`](lib/QuestSettings.ps1) | `Get-QuestToolsSettings`, `Initialize-QuestToolsFromSettings`, `Get-QuestHistoryFallbackRange`. See [Settings](#settings) |
| [`lib\QuestControl.ps1`](lib/QuestControl.ps1) | The control page from a script: `Register-QuestControlTiles`, `Unregister-QuestControlTiles`, `Open-QuestControlPage`, `Get-QuestControlPcLink`, `Get-QuestControlToken`, `Get-QuestControlHost` |
| [`lib\QuestSession.ps1`](lib/QuestSession.ps1) | `Invoke-QuestSessionCleanup`: the end-of-session cleanup |
| [`lib\QuestMediaActivity.ps1`](lib/QuestMediaActivity.ps1) | "One of our pages is playing": `Set-QuestMediaActivity`, `Get-QuestMediaActivity -FreshSec N`, `Get-QuestMediaActivityPath`. See [Quest media activity](#quest-media-activity) |
| [`xr\`](xr) | Quest XR player engine for Quest Browser pages: `xr-components.js` (A-Frame components), vendored `aframe.min.js` 1.6.0 + license, [`Sync-QuestXrEngine.ps1`](xr/Sync-QuestXrEngine.ps1). See [XR player engine](#xr-player-engine) |

## Using it from a script

```powershell
. (Join-Path $questToolsRepo 'QuestTools.ps1')          # top level of your script, not inside a function
Initialize-QuestTools -AdbExe '' -Serial '' -QuestHost '' -Port 0 -RediscoverSec 60   # all optional
$script:Adb = Find-QuestAdbExe
$dev = Get-OnlineQuestSerial; if (-not $dev) { $dev = Connect-Quest }
if ($dev) { Get-QuestWakefulness -DeviceSerial $dev }
```

Everything lands in your script scope: the helpers keep their state in $script:` variables (`Qt*`, `Adb`, `Skybox*`, `Quest*`). The SKYBOX server name ($script:SkyboxServerName`, default *Loop Segments*) and package ($script:SkyboxPackage`) can be set before or after loading.

**Finding this repo.** Callers look, in order, at `$env:QUEST_TOOLS_REPO`, `<ALL_SCRIPTS_ROOT>\quest_tools`, a `quest_tools` folder next to any parent folder of the caller (so `P:\all_scripts\quest_tools` for both `P:\all_scripts\3d_playlist_local` and `P:\all_scripts\iOS apps\ios_3d_loop_segments`), then `P:\all_scripts\quest_tools`, and set `$env:QUEST_TOOLS_REPO` for their child processes. Use **one checkout** (no submodule, no copies): the helpers share one adb server and these `%TEMP%` files, so two versions at once would disagree. (The one copy elsewhere is the XR engine bundled into the Loop Segments IPA, generated by `xr\Sync-QuestXrEngine.ps1`; see [XR player engine](#xr-player-engine).) The `%TEMP%` files:

| File | What |
|------|------|
| `loopsegments-quest-last-adb.txt` | Last `ip:port` the headset was on adb at |
| `loopsegments-adb-rediscover.txt` | Last adb server restart for mDNS rediscovery (at most every 5 min) |
| `loopsegments-adb-stuck-reset.txt` | Last stuck-server reset (at most once a minute) |
| `loopsegments-skybox-webdav.json` | SKYBOX servers this PC added |
| `loopsegments-quest-history-pending.json` | The delete the after-quit helper waits to do (origins, options, hooks, helper PID, deadline) |
| `loopsegments-quest-helper-page.ps1` | The PC-served helper page's server script (written on use) |
| `quest-browser-origins.json` | Pages opened in Quest Browser by any project (`origin`, `owner`), which every cleanup closes and deletes |
| `loopsegments-quest-lantab.log` | The log |

The names keep their `loopsegments-` prefix so a companion started before the split and a newer helper agree (`quest-browser-origins.json` is newer and has none).

## Opening a page (Push to Quest)

[`lib\QuestOpen.ps1`](lib/QuestOpen.ps1): what Loop Segments' **Open on Quest** and 3d_playlist_local's XR page use.

```powershell
$w = Wait-QuestHeadsetAwake -WaitMinutes 7 -OnStatus { param($s) <# 'checking' / 'queued' #> }
if ($w.Serial) { Open-QuestPage -DeviceSerial $w.Serial -Url $url -Owner 'myproject' -HelperUrl "$origin/xr-assets/lsclean" }
```

**Waiting for the headset.** `Wait-QuestHeadsetAwake` checks every `-PollSeconds` (5, at least 2) until the headset is on adb and `Awake`: for `-WaitMinutes`; with `-WaitMinutes 0 -ParentPid N`, until process N ends; with neither, once. While it is unreachable each check first tries to find it (`Connect-Quest`: last address, `-QuestHost`, mDNS, adb server restart); `-NoConnect` only reads `adb devices`, leaving that to another process such as a keep-awake job. `-Ready { ... }` also waits for the caller once the headset is awake (3d_playlist_local: the control page open finished). Logged `<label>headset Awake (10.0.100.238:41033)`, `<label>queued - opening when the headset is awake (...)`.

**Opening.** `Open-QuestPage -Url`, in order:

1. **registers** the page in the shared origin list under `-Owner`, before the open (a half-failed one can still leave a tab or a history entry), so every cleanup closes and deletes it ([Quest Browser cleanup](#quest-browser-cleanup));
2. **one tab:** over DevTools, an open tab on the page's origin or `-ReuseOrigins` is brought to the front and reused; extra ones are closed. A reused tab must answer DevTools within 5 s: tabs Quest Browser restored after it was stopped (force-stop, or closed from the headset) can sit unloaded, or on a login prompt (the stop also drops a cached login), and are closed and opened fresh instead (`closed 1 open tab(s) ... that did not answer`). Otherwise a **VIEW intent** opens it (retried: the browser sometimes drops the first one) in a new normal tab, or by navigating the open new-tab page a cleanup left behind (that counts as success too; looking only for a new tab id used to miss it). `-BeforeOpen { param($DeviceSerial) }` runs first in the same DevTools session (Loop Segments: its control page in its own tab, so this page ends up in front). Without DevTools: a plain VIEW intent;
3. **signed in** when `-LoginUrl` (the URL with `user:pass@`) differs: the tab is sent there (the browser caches the login), then back to the plain URL, and its back/forward list is reset so **Back** never leads to the URL with the password. A page whose URL contains `user:pass@` cannot `fetch()` (Chromium refuses URLs with credentials), hence the reload. A tab that ends on Chromium's error page (server down, firewall) counts as a failure;
4. **empty new-tab pages are closed** (`Closed N empty new-tab page(s) ...`): a cold start can bring back extra Quest Browser windows, each on an empty new tab, because Android keeps their records across a force-stop (seen: two windows after a force-stop); a window left with no tab closes with it. Your own tabs are not touched;
5. **secure context:** WebXR on an `http://` page needs `chrome://flags/#unsafely-treat-insecure-origin-as-secure` **Enabled** with the page's origin listed; only then is `window.isSecureContext` true (and `navigator.xr` there). So `isSecureContext` is read in the tab over DevTools (`Flags: <origin> isSecureContext=True in the open tab.`): **true = done**, with no `chrome://flags` visit (nothing extra in history or *Recently closed*; about 5 s instead of ~40 s). Only when it is **false** does it open `chrome://flags` on a helper tab (`-HelperUrl`: a small page with no login, closed afterwards; a scriptblock is only called then) and **add** the page's origin and `-FlagOrigins`, keeping the origins already there; then it enables the flag and **restarts Quest Browser** (flags apply only after a restart). **The restart closes the open tabs** (Quest does not restore them), so the page is opened once more and `isSecureContext` read again to confirm (tested: the whole open took 12 s with the restart). Nothing changes and nothing restarts when the flag already covers the origin. `-NoFlags` skips this step.

**Always a normal tab, so history has to be cleaned.** A private (incognito) tab would keep these pages out of Quest Browser history by itself, but it cannot be used: **Quest Browser disables immersive WebXR in private tabs** (`isSessionSupported("immersive-vr")` is false there and true in a normal tab), and WebXR is why these pages are opened at all (the XR player's Enter VR / Enter AR, Loop Segments' `/xr`). The same holds for the insecure-origin flag: it only matters to a page that runs WebXR, which is a normal tab. So the pages run in normal tabs, land in history and *Recently closed* like any other page, and every quit removes them again ([Quest Browser cleanup](#quest-browser-cleanup)); with the headset off, the [after-quit history helper](#after-quit-history-helper) finishes it. (A private-tab option, `questIncognito` / `-PrivateTab`, typed the URL into the address bar with key events; removed 2026-11-23: it gave up WebXR for history the cleanup removes anyway.)

## Pages served from this PC

[`lib\QuestPc.ps1`](lib/QuestPc.ps1), for a page the headset loads from this PC (3d_playlist_local's XR page, Loop Segments' control page, the PC-served helper page):

- **Address:** `Get-QuestPcAddress -DeviceSerial <ip:port>` is this PC's IPv4 on the route to the headset (a UDP "connect" to the headset's address, which sends nothing, and the local address Windows picks). `-Target <ip>` uses that address instead (Loop Segments: `questAdbHost` or the phone, for a USB serial); `-DefaultRoute` falls back to the default route. A new address is picked up on the next call.
- **Host name:** `Resolve-QuestPcHost -DeviceSerial -Ip -Mode` picks the host for the page's URL. `auto`: this PC's name, `<COMPUTERNAME>.local` then `<COMPUTERNAME>`, when the headset resolves it to this PC (checked over adb with `ping -c 1 <name>`: the `PING name (a.b.c.d)` line counts even with no reply, since Windows Firewall drops ICMP echo by default), else the IPv4; `ip`: always the IPv4; any other value: that host name (e.g. a router DNS name for a DHCP reservation). A name keeps the page's origin, and so its `chrome://flags` insecure-origin entry and its history entries, the same when DHCP hands this PC another address; with the IPv4, a new address means one more flag fix and browser restart. Logged `<label>the headset resolves <name> to <ip>, not this PC (...) - not used.` when it points elsewhere.
- **Windows Firewall** must let the headset in on the page's port (private network): Python for 3d_playlist_local's XR server, pwsh for Loop Segments' control page and the helper page.
- **Hidden helpers:** `Start-QuestHiddenProcess -Script <ps1> -Arguments @(...)` starts `pwsh -File` with no window (each argument passed as is, spaces included) and returns the process; `Get-QuestPwshExe` finds PowerShell 7.
## Quest control page

One small signed-in page on **this PC's LAN address** for Quest Browser, shared by every project that uses the headset: [`QuestControlHost.ps1`](QuestControlHost.ps1), port `controlPort` (default **18766**). A project adds its own **tiles** for as long as one of its processes runs; the host starts with the first registration and exits once no registered process is alive (an open page reloads itself when the set of projects changes). Today: Loop Segments (SKYBOX, PC ↔ phone LAN) while its companion runs, 3d_playlist_local (Session Control: Space, End session, segment bitrate) while a workflow runs.

```powershell
Register-QuestControlTiles -Owner playlist -OwnerPid $workflowPid -Module .\PlaylistControlTiles.ps1   # lib\QuestControl.ps1
Open-QuestControlPage -DeviceSerial $dev            # its own signed-in Quest Browser tab (opens its own DevTools session)
Get-QuestControlPcLink                              # http://127.0.0.1:<port>/pc?t=<token> for a PC browser
```

From a script that does not load quest_tools: `pwsh -File Register-QuestControlTiles.ps1 -Owner <name> -OwnerPid <pid> -Module <path>` (or `-Owner <name> -Unregister`); prints `{ ok, port, pid, started, pcLink }`. From the command line, `Invoke-QuestHeadset.ps1 -OpenControlPage -ParentPid <pid>` waits for an awake headset (until that process exits; `-WaitMinutes` caps it) and opens the page there.

**Tile module**: a `.ps1` the host dot-sources once (its functions land in the host's scope: prefix them with the project's name), whose last statement returns a hashtable:

| Key | What |
|-----|------|
| `Label` | Name in the page header |
| `Tiles` | `@( @{ Column = 0, 1 or 'wide'; Order = 10; Html = '<section>...</section>' } )`; column 1 starts with the built-in speed test tile |
| `Script` | JavaScript, run once in its own function. `QC.register('<owner>', fn)`: `fn(status, all)` gets this project's `Status` result on every poll and may return the poll delay it wants (ms; the smallest wins, default 10 s). Helpers: `QC.$`, `QC.post(path)` (sends the action header; returns `{ ok, status, json }`), `QC.schedule(ms)`, `QC.onQuest`, `QC.mbps` |
| `Status` | `{ ... }` returning an object, shown in `/status.json` under `owners.<owner>` |
| `Routes` | `@{ '/path' = { param($Ctx) ...; @{ Code = 200; Body = <object> } } }`: `POST` only, with the action header; `$Ctx.Remote`, `$Ctx.Query` |
| `Login` | `{ @{ User; Password } }`: also accept HTTP Basic with this login (Loop Segments: the phone LAN login, which its PC extension answers) |
| `OnSpeedTest` | `{ param($Result) ... }` after each PC → Quest measurement |

**Built-in tile: LAN bandwidth PC → Quest.** On the headset the page downloads **64 MB** from this PC (`GET /speedtest/blob`, random bytes, timed from the first byte) and posts bytes and milliseconds back (`POST /speedtest/result`, recorded only from a non-loopback client). It runs by itself each time the page opens on the Quest (unless a result under 2 min old exists), and with its button. The measurement goes to `%TEMP%\quest-lan-throughput.json` (`{ ok, measuredMbps, bytes, seconds, client, measuredAtUtc }`); what it means for a project (3d_playlist_local: the minute-segment bitrate) is that project's logic.

**Sign-in.** Reachable from the LAN, so every request must pass all of: client address loopback or private (`10/8`, `172.16/12`, `192.168/16`, `169.254/16`); `Host` header an IP literal or `localhost` (no DNS names: blocks DNS rebinding); signed in, with the `qcpc` cookie or HTTP Basic with a module's `Login` (a failed sign-in waits 1 s); actions `POST` with header `X-Quest-Control: 1` (a form or link on another site cannot send it, and the cross-origin preflight is refused). The cookie comes from the token in `%TEMP%\loopsegments-quest-control-pctoken.txt` (kept across sessions): `/pc?t=<token>` from loopback (the link a workflow window prints), `/s?t=<token>` from the LAN (what `Open-QuestControlPage` types on the headset). Both swap the token for an HttpOnly `SameSite=Strict` cookie and redirect to `/`, so the tab's URL and history carry no token. The control page's origin is registered in the shared origin list, so every cleanup closes its tab and deletes its history.

One request at a time, handled only once a connection has sent one (Quest Browser opens spare connections that send nothing; those are closed after 10 s). The page sends `Content-Security-Policy`, `X-Frame-Options: DENY` and `Cache-Control: no-store`. **Windows Firewall** must allow inbound TCP on the port on the Private network (the *PowerShell 7* allow rule for `pwsh.exe` does). Host log: `%TEMP%\quest-control-host.log`. State: `%TEMP%\quest-control-tiles.json` (registered projects), `%TEMP%\quest-control-host.json` (port, pid; also written as `loopsegments-quest-control.json` for older callers).

## End-of-session cleanup

`Invoke-QuestHeadset.ps1 -Cleanup` (`Invoke-QuestSessionCleanup`, [`lib\QuestSession.ps1`](lib/QuestSession.ps1)), for a project's quit: tabs on our pages closed and their history (+ *Recently closed*) deleted within ~28 s ([Quest Browser cleanup](#quest-browser-cleanup)), Quest Browser closed when only empty pages are left, the proximity sensor back on, the **Wi-Fi off** last. "Our pages" are every origin in the shared origin list (each project registers what it opens, the control page included) plus `-ExtraOrigins a,b`. The *Recently closed* helper page is `-HelperUrl`, else the one served from this PC on `controlPort + 1`. Not on adb, or Quest Browser not answering (nobody wearing it): the delete goes to the [after-quit helper](#after-quit-history-helper), which switches the Wi-Fi off after it (`-StopIfCommandLine <regex>` stops that helper when a matching process starts). Choices not given follow the [settings](#settings) (`-CloseTabs` / `-KeepTabs`, `-SkipHistory`, `-WifiOff` / `-KeepWifi`, `-KeepProximity`). Exit 0 done, 1 not on adb (handed to the helper), 3 incomplete, 4 history postponed; logs `Cleanup: finished ...`.

## Quest media activity

Which of our pages is **playing on the Quest right now**, for any project to ask ([`lib\QuestMediaActivity.ps1`](lib/QuestMediaActivity.ps1)). A project's page server records each media request its page makes (a `<video>` fetching a segment) in its own file, `%TEMP%\quest-media-activity-<owner>.json`. One file per owner, so writers never race. Only requests to our own servers write these files, so other Quest Browser playback (YouTube, any site) does not count. adb cannot tell them apart: `dumpsys audio` reports playback per app (`com.oculus.browser`), with no URL or tab.

- **Format** (UTF-8 JSON; write `<file>.tmp`, then rename over the file): `{"owner": "playlist", "lastMediaEpoch": 1764134400.5, "lastMediaUtc": "...", "media": "hybrid/3d_op_00_Full_SBS.mkv", "pid": 1234}`. Readers use `lastMediaEpoch` (Unix seconds, UTC). Write at most every ~15 s.
- **Write:** `Set-QuestMediaActivity -Owner <name> [-Media <what>]` from PowerShell; other languages write the format themselves. 3d_playlist_local's `xr\serve_xr_page.py` (owner `playlist`) does, on each `/media` GET.
- **Read:** `Get-QuestMediaActivity [-FreshSec N]` returns `{Owner, AgeSec, Media, Path}` per owner, newest first; with `-FreshSec`, only those within the last N seconds (a clock up to 60 s ahead also counts).
- **Used by:** Loop Segments' keep-awake. While anything played in the last 3 min, it renews the phone's Keep Alive every 10 min, from an `Invoke-QuestKeepAwakeSession -OnTick` step. The phone call itself stays in Loop Segments: it is that app's endpoint and login.
- Paused or closed pages stop writing, so a reader sees the activity go stale within its `-FreshSec`. The files are not cleaned up; a stale one is just old.

## Settings

`quest-tools.json` next to `QuestTools.ps1` (per PC, git-ignored; [`quest-tools.example.json`](quest-tools.example.json) lists every key). A key missing there falls back to the older `quest*` key in `ios_3d_loop_segments\windows\loop-segments-windows.json` (read as plain JSON when a Loop Segments checkout is around), then to the default. `Initialize-QuestToolsFromSettings` applies the adb ones.

| Key | Older key | Default | What |
|-----|-----------|---------|------|
| `adbExe` | `questAdbExe` | `""` | Full path to `adb.exe` (empty = auto) |
| `adbSerial` | `questAdbSerial` | `""` | Only this adb serial counts as the headset |
| `adbHost` / `adbPort` | `questAdbHost` / `questAdbPort` | `""` / `5555` | `adb connect` target before mDNS |
| `adbRediscoverSec` | `questAdbRediscoverSec` | `60` | Restart the adb server after this long without the headset (`0` = never) |
| `controlPort` | `questControlPort` | `18766` | Quest control page port (`+ 1`: the PC-served helper page) |
| `closeTabsOnExit` | `questCloseLanTabsOnExit` | `true` | `-Cleanup` closes our tabs |
| `clearHistoryOnExit` | `questClearHistoryOnExit` | `true` | `-Cleanup` deletes their history |
| `clearHistoryFallback` | `questClearHistoryFallback` | `day` | Range cleared when the per-entry delete fails (`hour`, `day`, `week`, `fourweeks`, `all`, `none`) |
| `historyRetryMinutes` | `questHistoryRetryMinutes` | `120` | How long the after-quit helper waits for the headset to be worn |
| `wifiOffOnExit` | `questWifiOffOnExit` | `true` | `-Cleanup` switches the Wi-Fi off last |
| `ensureInsecureOriginFlag` | `questEnsureInsecureOriginFlag` | `true` | Fix the insecure-origin flag when an opened page is not a secure context |

## Quest Browser cleanup

Every page a project opens on the headset is **registered when it opens**, with an owner name, in `%TEMP%\quest-browser-origins.json` ([`lib\QuestOrigins.ps1`](lib/QuestOrigins.ps1)): Loop Segments registers its phone LAN page (`loopsegments`) and the Quest control page (`loopsegments-control`), 3d_playlist_local its PC XR page (`3d_playlist_local-xr`). Origins are stored as `scheme://host:port` (no login, path or query).

Every cleanup runs [`Invoke-QuestBrowserCleanup`](lib/QuestCleanup.ps1), which adds every registered origin to the ones the caller knows. So whichever quit runs first (the Loop Segments companion's, a 3d_playlist_local workflow's, End session, or the after-quit history helper) cleans up the pages of **all** projects, not only its own. In one DevTools session it:

1. closes the tabs on those origins (`-CloseTabs`; one tab is always kept, as a new-tab page, because the History list needs an open tab);
2. deletes their history entries (unless `-SkipHistory`), then sweeps their *Recently closed* items through `-HelperUrl` (a small page that lands in history; its origin is always deleted too) and deletes once more;
3. drops the cleaned origins from the list: only those with no tab still open on them (an open tab puts its page back in history, so it stays for the next cleanup);
4. closes Quest Browser when only empty pages are left (`-CloseBrowser`).

A failed delete can be handed over (`-OnHistoryFailed`, result `postponed`): Loop Segments' after-quit helper does it once the headset is worn (why a delete fails: [When Quest Browser does not answer](#when-quest-browser-does-not-answer)). Entries not opened again for 30 days leave the list (newest 32 kept). Logged as `Tabs: closed N Quest Browser tab(s) on our pages` and `History step: cleared`.

What the caller supplies: its own origins, the helper page (`-HelperUrl`), the fallback range (`-FallbackRange`), the time limit (`-BudgetSec` / `-BudgetUntil`) and what to do with a failed delete. Loop Segments' side (its origins, the phone helper page and its PC fallback, the settings, the after-quit helper): its `windows\quest\README.md`, *Close LAN tabs on companion close* and *Delete Loop Segments history on companion close*.

### When Quest Browser does not answer

The tab closing works over DevTools on any awake headset: pages in open tabs answer, so DevTools can navigate them, run script in them and close them. The **history delete, its fallback and the *Recently closed* sweep** go through Quest Browser's own UI (its History panel and *Clear browsing data* dialog), and that UI often does not answer when nobody is wearing the headset:

- **Idle.** With the proximity override on ([Proximity sensor](#proximity-sensor)), a headset lying still stays awake but goes **idle** after about a minute (`Device idle state`, [Headset state](#headset-state)). While it is idle the browser's UI **often** does not answer: no history list (`history query never answered`), no clear dialog (`dialog time options never arrived`), no new tabs from intents. Not always, and idle time alone does not decide it: one delete failed 35 min into idle, another worked 20 min into idle (`cleared` in 1.2 s, nobody wearing the headset), and new tabs from intents also opened on an idle headset. What differs is not known yet (the browser had been started fresh 15 min before the working one, and had run all afternoon before the failing one). So a cleanup at quit, with the headset on the desk, often fails; it is then handed over (`-OnHistoryFailed`) and done once the headset is worn.
- **No open tab.** The History list and the dialog only answer while the browser has at least one tab (tested: the delete worked with one tab open and got `history query never answered` right after its last tab was closed; this made deletes fail even with the headset worn). So the tab closing always keeps one tab ([below](#closing-tabs-and-the-browser)).
- **Asleep or off adb.** An asleep headset stays on Wi-Fi and adb only for a while; even before it drops off, the browser does not answer. Keep-awake holds the sensor off for that reason.

(A `Page.navigate timeout` in the log usually means the page being opened does not answer, not that the headset is idle: navigating to a page that does not answer times out by itself.)

### Closing tabs and the browser

Every tab on our origins is closed over DevTools (`Close-QuestOurTabs`); other tabs stay. Empty tabs (`about:blank`, new-tab pages) are closed along with ours, and when no tab of yours is left **one tab is kept as a new-tab page** (back/forward list reset; `about:blank` only when the new-tab page cannot be loaded): `Tabs: kept one tab as a new-tab page`. That tab is what the History list needs. A force-stopped browser restores its open tabs, so it next starts on that New tab (a kept blank page used to come back as a blank tab), and that is also why our tabs are closed before the browser is.

With `-CloseBrowser`, Quest Browser is **force-stopped** afterwards (`am force-stop com.oculus.browser`: Android's "close this app now", the only way to close an app over adb) whenever no tab of yours is left: empty new-tab pages and the kept tab do not count, whoever started the browser. Any tab of your own keeps it running: `Browser: N other tab(s) open - Quest Browser left running`. It waits 5 s first: Chromium writes its *Recently closed* list a few seconds after a change, and a force-stop before that can bring back an older copy on the next start. With a postponed delete the browser is left for whoever took the delete over (`helper`). Tested: cold start from a stopped browser, then a cleanup → history cleared, browser closed in 2.9 s.

### History delete

Deletes **only the entries on our origins** from Quest Browser history (`Clear-QuestBrowserHistory`). **The rest of your history is kept**, and so are cookies, cache, saved passwords, form data and site settings.

How: the browser's own **History** list (the panel behind *History* in the browser menu) is opened over DevTools. Its own code asks the browser for the whole history, and each matching entry is removed the way that entry's remove button does it. Matching is by origin (scheme, host and port), so every entry on those origins goes, whatever its path. Only the origins given are matched: entries from an address no longer known (for example a PC address before DHCP gave it a new one) stay, unless the fallback runs.

Then the history is read again. A delete is a message to the browser with no reply, so this re-read is the only proof that none are left. If some are left, it deletes those and checks again. That covers a delete the browser dropped, a very large history (older matches appear only once newer ones are gone), and a page still loading that adds a visit. Normally one pass and one check is all it takes (1-2 s in tests). It stops after 20 rounds or when the time limit is nearly used up; any matching entry left then means the selective delete failed. Logged as `History: deleted 2 entries on http://10.0.100.10:8765, http://10.0.100.244:18766; kept the other 2.`

Quest Browser's 2D window is brought to the front first (the list only fills in then; launcher intent, sent again once if the first does not take), and the browser is started if it was closed. This also takes the headset out of an immersive WebXR session, which runs in a separate task and hides the 2D window. With the browser already running it takes 1-3 s; a cold start usually takes longer and may not fit a short time limit (logged).

**Fallback range.** If the selective delete fails (History list not found, query not answered, entries left), `-FallbackRange` clears **all** Quest Browser history from that range instead, through the browser's own *Clear browsing data* dialog: **History only** is ticked, the range is picked, *Clear data* is pressed, then the dialog's previous ticks and range are put back. Cookies, cache, passwords, form data and site settings are never ticked. Ranges: `hour`, `day`, `week`, `fourweeks`, `all`; `''` = no fallback (the result is then `failed`). It deletes unrelated browsing in that range and misses our entries older than it, which is why it is only the fallback (the dialog only offers those fixed ranges). Logged `History: selective delete failed - ...`, then `History: fallback cleared ALL Quest Browser history from the last 24 hours (history only).`; result `fallback`. Like the list, the dialog only answers while a tab is open. Tested with one blank tab open: the last 24 hours cleared in 2 s, and *Recently closed* was emptied with it. 10 s of the time limit is kept for it.

This relies on Quest Browser's internal UI (its History list component and the `webui_action_query_history` / `webui_action_delete_history` messages). A Quest Browser update can change those; the selective delete then fails (for example `History list not found`) and the fallback runs.

### Recently closed

The History panel also lists *Recently closed* tabs, and every tab closed over DevTools lands there: our tabs closed at cleanup, and helper tabs such as the `chrome://flags` fix's (shown as *Experiments*). These items also show as **tiles on the new-tab page**, and they are not in *See full history* or *Recently visited*. `chrome://` pages are never in history, and deleting a page from history does not reliably drop its item: an item for a test page whose history entry had been deleted, plus *Experiments* and empty *New tab* items cleaned before, were all back days later (probably a force-stop right after a change; see the 5 s wait above).

So after the history delete, **the sweep** (`Invoke-QuestRecentlyClosedSweep`): every item whose tabs are all on our origins, new-tab pages, blank pages or `chrome://flags` is reopened, sent (via `about:blank`) to the **helper page** (`-HelperUrl`) with its back/forward list reset, and closed; one more history delete then removes the helper page's entries. Items with any other page in them are left alone. Logged `Recently closed: cleaned N of M ... item(s)`. What makes it work (all seen on the headset):

1. the UI only holds the Recently closed list after asking the browser for it, and keeps the last answer, so the sweep requests it and waits 1.5 s before reading it (it used to see an empty or stale list and sweep nothing);
2. the delete removes Recently closed items **by URL**, so that URL must be in history. The helper page has to be one whose visits are recorded: a small page with no login (Loop Segments: a 404 page, `/xr-assets/lsclean`); visits to a 1.4 MB script stopped being recorded, and a visit with a query string never was. A visit made in a reopened item is not recorded either;
3. so after the sweep one visit to the helper page is made in the tab that stays open (the kept new-tab page, put back afterwards), and checked in the History list before the delete (retried once; logged `Recently closed: helper visit is / NOT in the History list`). The following delete removes that URL and every item pointing at it.

The helper page must be reachable from the headset; its origin is always deleted with ours. Cleaned by hand once this way (6 items: 4 *New tab*, a test page, *Experiments*): the list stayed empty after a browser restart 20 s later.

**When the project's helper page does not answer** (for Loop Segments: the phone app closed, or the phone off the LAN), no visit is recorded and the swept items stay. [`Resolve-QuestHelperUrl`](lib/QuestHelperPage.ps1) `-PreferredUrl <page> -FallbackPort <port> -PcAddress <ip>` picks the page once per process: the preferred one when its host answers on TCP, else the same small 404 page served from this PC at `http://<pc>:<port>/lsclean` by a hidden pwsh that exits with the caller (or after 30 min; needs pwsh allowed through Windows Firewall on private networks). Its `FallbackOrigin` is then deleted with ours. Logged `Helper page: <host> not answering - serving it from this PC at ...`. On another Wi-Fi network the items stay until the next cleanup on the right one. This PC's address there comes from `Get-QuestPcAddress` ([Pages served from this PC](#pages-served-from-this-pc)).

### After-quit history helper

A cleanup at quit usually runs with nobody wearing the headset, so the delete often fails ([When Quest Browser does not answer](#when-quest-browser-does-not-answer)), or the headset is not on adb at all. Instead of dropping the delete, the caller hands it over ([`lib\QuestHistoryRetry.ps1`](lib/QuestHistoryRetry.ps1)):

```powershell
Start-QuestHistoryRetry -Origins $o -Minutes 120 -CloseTabs -CloseBrowser -HelperUrl $page -HelperFallbackPort 18767 `
    -FallbackRange day -WifiOff -StopIfCommandLine 'MyApp\.ps1' -AfterScript 'C:\...\After.ps1'   # $true = handed over
```

(`Invoke-QuestBrowserCleanup -OnHistoryFailed { param($o) Start-QuestHistoryRetry -Origins $o ... }` does it at the right moment.)

- What is left goes to `%TEMP%\loopsegments-quest-history-pending.json`: the origins, whether to close tabs, reset the sensor (`-Proximity`: the quit could not reach the headset) and close the browser, the helper page, the fallback range, Wi-Fi off, the hooks, and how this process reached the headset (adb, serial, host, port). A second hand-off while one is waiting merges into it (origins added, the deadline moved).
- One hidden helper starts, detached from the caller's process tree so it outlives it: [`Invoke-QuestHistoryRetry.ps1`](Invoke-QuestHistoryRetry.ps1). Logged `History: postponed - deleted when the headset is next worn (helper PID 6172, until 02:22)`; the cleanup's result is `postponed`.
- Every **2 s** it looks for the headset on adb (`adb devices`, and `dumpsys vrpowermanager` once it is there). If the quit could not reach it, it turns the sensor back on as soon as it gets through. Once the headset is **worn** (`HEADSET_MOUNTED` and `Not idle`: [Headset state](#headset-state)) it **holds the proximity sensor off for the delete** (`prox_close`, only when the real sensor is on; turned back on right after, even if the delete failed), so you only need the headset on until Quest Browser comes up: taken off with the real sensor on, the headset sleeps and the browser stops answering. Logged `History retry: headset worn - deleting (sensor held off for it: the headset can come off now).` It then waits 1 s for the browser and runs `Invoke-QuestBrowserCleanup` for those origins plus the shared list (the browser comes to the front, so it pops up shortly after you put the headset on): `History retry: headset worn - deleting.` ... `History retry: done.` The fallback range is tried **once per helper run**: retried every few seconds, its *Clear browsing data* dialog kept popping up (seen stuck on *last 24 hours* while the browser did not answer); it also clears what you browsed since the quit. The browser is closed afterwards only once the delete worked.
- After the delete it switches the headset's **Wi-Fi off** (`-WifiOff`). That happens while you are wearing it, so Wi-Fi goes off under you: switch it back on if you keep using the headset.
- It gives up after `-Minutes` (Wi-Fi still switched off first if the headset is on adb): `History retry: the headset was not worn in time - gave up`.
- `-StopIfCommandLine <regex>`: it stops, dropping the delete, when a process matching it starts after the helper (the project starting again: that session's quit deletes the same origins): `History retry: the session started again - stop`. `Stop-QuestHistoryRetry` stops every helper and drops the pending delete (a new session does it first thing, before its keep-awake can switch the sensor off under the helper).
- `-AfterScript <path.ps1>`: run as `pwsh -File <path> -Outcome done|gaveup|stopped|none` when the helper ends (at most 11 min): for work that had to wait for the delete, such as a network change that would move the headset off this PC's network.
- While it waits it restarts the PC's adb server at most every 20 min (not 5) when it cannot find the headset.

Tested (with a 30 s check then): quit with the headset lying idle for 2 min → postponed; headset put on 4 min later → 3 entries deleted 6 s after the helper saw it worn. 2026-11-22 (5 s check, 3 s settle): XR page entry, Recently closed item and helper visit deleted 17 s after the helper saw the headset worn (delete 1 s, sweep 5 s, helper-visit check 6 s). Now the delete starts within ~2 s of putting the headset on, after a 1 s settle, and the helper-visit check polls every 0.5 s. If the helper is killed mid-delete (`Stop-QuestHistoryRetry` by a new session), the sensor stays held off: that session's keep-awake holds it off anyway and its quit turns it back on.

## XR player engine

`xr\` is the one editable copy of the WebXR player engine both projects' Quest pages run: 180° SBS domes
(VR180 half sphere, equidistant fisheye 180, or a flat screen: `window.__xrProjection`), chroma key over
passthrough (key colour pure black `#000000` = a brightness key instead: near-black pixels go transparent, for
black fisheye backgrounds), per-eye WebGL layers (left dome layer 1, right dome layer 2) in **Enter VR and Enter AR**
(SBS off = one picture to both eyes), the AV1 render-target path (MP4 `av01` and Matroska
`V_AV1`), and the `xr_debug.json` log ring. Each page keeps its own `xr-app.js` / `xr-player.html` (playlists,
server URLs) and sets those `window.__xr*` knobs.

**Hand tracking** (`xr-hand-gestures`, put on `<a-scene>` by the engine itself; `window.__xrHandGestures = false`
turns it off): the engine requests the optional `hand-tracking` WebXR feature, so in Enter VR / Enter AR with
no controllers:

- **pinch** (thumb + index) = play / pause. Quest sends a hand pinch as the session `select` event, which both
  pages already map to play / pause, as with the controller trigger.
- **fist held 1 s** (either hand; `window.__xrHandExitHoldMs`) = leave VR / AR back to Quest Browser's 2D
  window. A ring in front of the eyes fills while the fist is held; opening the hand cancels. Logged as
  `hand-exit`.
- **another Quest app**: a web page cannot open one, but Quest's own system gesture (look at your palm, pinch)
  opens the universal menu inside WebXR too.

- **3d_playlist_local** (`individual_transcode\xr\serve_xr_page.py`): serves `/xr-assets/xr-components.js`,
  `aframe.min.js` straight from this folder (found like the rest of this repo).
- **Loop Segments** (`ios\LoopSegments\Resources`): the IPA is built on GitHub Actions from that repo alone,
  so it bundles a **generated copy**. After editing the engine run `xr\Sync-QuestXrEngine.ps1` (default
  target: `..\iOS apps\ios_3d_loop_segments\ios\LoopSegments\Resources`, or `$env:LOOPSEGMENTS_IOS_REPO`) and commit
  that copy; its `deploy.ps1` runs `-Check` and stops on a stale copy. Never edit the copy there.

A-Frame stays at 1.6.0: the first-VR-after-AR repair (`xr-enabled-fixed`), the eye layers and the canvas
texture reset depend on how it behaves. An upgrade means replacing `aframe.min.js` + the license here and a
full headset retest (AR then VR, Chroma on and off, Fullscreen) on both pages. Debug log fields: Loop Segments'
`.cursor/skills/xr-debug/SKILL.md`.

## Headset state

**Reading the headset state.** Three `dumpsys` fields, each used for something different:

| Field | Values | Meaning | Read by |
|---|---|---|---|
| `mWakefulness` (`dumpsys power`) | `Awake` / `Asleep` / `Dozing` | Display on or off | Open on Quest (open now or queue), keep-awake (never `prox_close` a headset that is not `Awake`) |
| `Virtual proximity state` (`dumpsys vrpowermanager`) | `CLOSE` / `DISABLED` | The override: `CLOSE` = `prox_close` sent (pretend a face is there), `DISABLED` = real sensor (`automation_disable`, `-EnableProximity`) | Keep-awake (re-apply after a reboot), `-EnableProximity` (confirm) |
| `State` + `Device idle state` (`dumpsys vrpowermanager`) | `HEADSET_MOUNTED` / standby; `Idle` / `Not idle` | The power manager's result, driven by the real or virtual sensor; idle = no motion for about a minute | After-quit helper: worn = `HEADSET_MOUNTED` **and** `Not idle` |

With the override `CLOSE`, `State` is always `HEADSET_MOUNTED`, even on the desk, so during a session only `Not idle` tells worn from lying still. Headset on but not worn during a session: `Awake`, `CLOSE`, `HEADSET_MOUNTED`, `Idle`.

## Proximity sensor

`am broadcast -a com.oculus.vrpowermanager.prox_close` holds the sensor off (the headset acts as worn: it does not sleep, and stays on adb, when taken off); `...automation_disable` gives the real sensor back. A reboot clears the override. **Keep-awake** (`Invoke-QuestKeepAwakeSession`, `Invoke-QuestHeadset.ps1 -KeepAwakeSession -ParentPid N`) checks every ~20 s while process N runs and applies the override once the headset is on adb **and awake**: a headset in standby is left alone, since `prox_close` would wake it. `-RestoreProximity` turns the sensor back on when N exits, unless another keep-awake without it (a Loop Segments companion session) is still running.

**Toggle by hand:** run [`Set-QuestProximitySensor.ps1`](Set-QuestProximitySensor.ps1) (for example right-click → *Run with PowerShell*; Loop Segments' `windows\quest\Set-LoopSegmentsQuestProximitySensor.ps1` runs it after its network check). With no arguments it flips the sensor (off = the headset stays awake and on adb when you take it off; on = it sleeps again). If the first try finds no headset, it runs [`Find-QuestWifiNetwork.ps1`](Find-QuestWifiNetwork.ps1) once (the PC through its saved Wi-Fi networks; it stays on the one where the headset answers, else goes back), then tries again at once; `-NoNetworkCycle` skips that (Loop Segments' wrapper passes it, since the PC has to stay on the phone's network). The cycle runs before any retry, so its adb server restarts never overlap the retry loop's, and a headset on USB passes the first try and never cycles. If the headset is still not on adb (asleep, or its Wi-Fi just switched on after a quit switched it off), it keeps trying every 5 s for up to **2 minutes** (`-WaitSec`, `0` = once), so you can put the headset on or switch its Wi-Fi on meanwhile. Before every retry (not the first try) it restarts the PC's adb server: when the headset's Wi-Fi comes back on, wireless debugging gets a new port, and a running adb server can go on missing it over mDNS for minutes (seen: still nothing 40 s after a 2-minute run gave up; listed 4 s after a restart). Loop Segments' `Reset-QuestBrowserFlags.ps1` does the same. It then prints what it did and the final state (`Sensor is OFF ...` / `Sensor is ON ...`) or the error (headset not on adb, no adb, change not taken), and waits for Enter. `-State On` / `-State Off` force one; `-NoWait` skips the wait. While a keep-awake session runs (Loop Segments companion, 3d_playlist_local workflow), it switches the sensor off again within ~20 s of turning it on. While the sensor is off by hand, the headset shows a **"Proximity sensor OFF"** notification saying it stays awake and how to turn the sensor on again. Quest only lists notifications behind the bell (Meta button > bell), so the script then opens that list in front of you (`am start -n com.oculus.systemux/com.oculus.panelapp.notifications.NotificationsActivity`, awake headset only) and closes it again after **20 s** by removing that window's task (`am stack remove <id>`: Back, Home and Escape do not close it; the notification stays behind the bell; the script waits those 20 s; tested: closed, notification still listed). Other ways that did not work: the Navigator's own notifications activity sometimes brought up the Library instead, `cmd statusbar expand-notifications` opens Settings > Notifications, and Quest's own popups need a permission only Meta's system apps have); turning the sensor on, by hand or by the companion quit, removes it. Posted with `cmd notification post` as the Android shell; there is no remove command, so it is snoozed for a year instead. Keep-awake during a companion session does not post it.

## Wi-Fi off

**By hand:** [`Set-QuestWifiOff.ps1`](Set-QuestWifiOff.ps1) (or `Invoke-QuestHeadset.ps1 -WifiOff`) switches the headset's Wi-Fi off any time: Settings > Wi-Fi first on an awake headset (so switching it back on is one tap), then `cmd wifi set-wifi-enabled disabled`; adb drops right after, since it runs over that Wi-Fi. Like `Set-QuestProximitySensor.ps1` it waits up to 2 minutes for the headset on adb (`-WaitSec`). Exit codes 0 off, 1 headset not on adb, 2 no adb, 3 failed.

Before the next session, switch Wi-Fi on in the headset's quick settings. Wireless debugging then comes back by itself on a new port, which the PC finds over mDNS (tested: listed 2 s after Wi-Fi came back on). Until then Open on Quest queues and keep-awake waits.

## One-time setup

### 1. PC: adb

```powershell
winget install Google.PlatformTools
```

Open a new terminal afterwards so `adb` is on PATH. (`Find-QuestAdbExe` also finds the winget, Android SDK, and Meta Quest Developer Hub copies on its own; `Initialize-QuestTools -AdbExe` / Loop Segments' `questAdbExe` overrides.)

### 2. Quest: developer mode

In the **Meta Horizon** phone app: Devices → your headset → Headset settings → **Developer mode** on. Reboot the headset.

### 3. USB once: trust the PC

Plug the Quest into the PC, put it on, and accept **Allow USB debugging** (tick *Always allow from this computer*). Check:

```powershell
adb devices -l
```

### 4. Keep wireless adb on across reboots: [adb-auto-enable](https://github.com/project-SIMPLE/adb-auto-enable)

Quest switches wireless adb off on every reboot. adb-auto-enable turns it back on after boot (and auto-accepts the USB-debugging prompt). Download the APK from that repo's **Releases**, then with the Quest still on USB:

```powershell
adb install <path-to-downloaded>.apk
adb shell pm grant eu.project_simple.adbautoenable android.permission.WRITE_SECURE_SETTINGS
```

Open **ADB Auto-Enable** on the headset once (Library → Unknown sources). With the permission granted it enables its own accessibility service. If it does not, run:

```powershell
adb shell "settings put secure enabled_accessibility_services eu.project_simple.adbautoenable/eu.project_simple.adbautoenable.AdbPopupAccessibilityService && settings put secure accessibility_enabled 1"
```

Verify (expect `granted=true`, the service name, `1`, `1`):

```powershell
adb shell dumpsys package eu.project_simple.adbautoenable | findstr WRITE_SECURE_SETTINGS
adb shell settings get secure enabled_accessibility_services
adb shell settings get secure accessibility_enabled
adb shell settings get global adb_wifi_enabled
```

**After a reboot you do not need to open the app.** Android starts its accessibility service by itself at boot (on Quest 3: 13 s after boot), the service switches wireless adb back on, and the PC reconnects through mDNS before anyone opens the app. This depends on the accessibility service staying enabled: if a Horizon OS update or a settings reset turns it off, open **ADB Auto-Enable** once or rerun the `settings put secure enabled_accessibility_services ...` command above.

Wireless adb gives full shell access to the headset: keep it on your home LAN only, and never port-forward it.

### 5. How the PC finds the headset

`Connect-Quest` ([`lib\QuestAdb.ps1`](lib/QuestAdb.ps1)) tries, in order (`-Serial` / `-QuestHost` / `-Port` / `-RediscoverSec` of `Initialize-QuestTools`, which Loop Segments fills from `questAdbSerial` / `questAdbHost` / `questAdbPort` / `questAdbRediscoverSec`):

1. a Quest already listed by `adb devices -l` (or `questAdbSerial`);
2. `adb connect <questAdbHost>:<questAdbPort>` (default `5555`) when `questAdbHost` is set;
3. `adb connect` to the **last address the headset was on adb at** (`%TEMP%\loopsegments-quest-last-adb.txt`, saved whenever it is found; shared by Open on Quest, keep-awake and the history helper; 3 s timeout). Wireless debugging keeps its port until it is switched off or the headset reboots, so this gets the headset back at once, without mDNS: logged `Connected to the last known address 10.0.100.238:39923`. Measured after an adb server restart: mDNS listed the headset after 17 s once and not within 240 s another time, while the direct connect took 134 ms (and Open on Quest found it immediately). After a reboot or on another network it simply fails and the next steps run. It keeps `ip:port` as one value: the IP alone would not help, since the port is random. The IP usually stays the same per network (the router's DHCP hands the same address back to the headset's per-network MAC; seen all day: always `10.0.100.238` on ATT-WIFI-5pmY, `192.168.2.54` on ATT-WIFI-3pKe), so the port is what goes stale: a reboot, a wireless-debugging toggle, **or a Wi-Fi network switch** gives a new one (seen: `36483` → `39923` after the headset was moved back from `192.168.2.x`). The next mDNS find saves the new port;
4. `adb mdns services` → the wireless-debugging TLS port (random, e.g. `10.0.100.238:37275`);
5. if none of that has found the headset for **60 s** (`questAdbRediscoverSec`) and no adb device at all is connected: restart the PC's adb server (`adb kill-server`, `adb start-server`) and look over mDNS again. The adb server can stop hearing the headset's announcements after the headset sleeps and comes back on a new port; a restart makes it listen afresh. At most once every 5 min across all companion processes (`%TEMP%\loopsegments-adb-rediscover.txt`), logged as `adb: headset not seen over mDNS for 60 s - restarting the adb server`. `0` turns it off.

**adb server hung (every adb command blocks).** Seen 2026-11-22: the headset was on USB and advertising over mDNS, but `adb devices`, `adb connect` and even `adb kill-server` never returned, and every PowerShell window running one froze with them. Two `adb.exe` processes were running, one holding `127.0.0.1:5037`. `adb kill-server` cannot fix this (it is a request to the stuck server), so the scripts handle it themselves ([`lib\QuestAdbServer.ps1`](lib/QuestAdbServer.ps1)):

- **`Connect-Quest`** (`Repair-QuestAdbStuckServer`; used by Loop Segments' Open on Quest, keep-awake, the history helper, the 3d_playlist_local session's keep-awake, and `Invoke-QuestHeadset.ps1`): an `adb devices` that does not answer in 10 s counts as a stuck server, and the next reconnect resets it **at once** instead of waiting for step 5's 60 s. At most once a minute across all companion processes (`%TEMP%\loopsegments-adb-stuck-reset.txt`). Logged as `adb: ... the adb server looks stuck; resetting it`, then `adb: kill-server did not return in 5 s`, `adb: killing adb.exe (PID ...)`, `adb: server reset (killed)`. Step 5's restart uses the same reset.
- **Set-QuestProximitySensor.ps1, Set-QuestWifiOff.ps1** and Loop Segments' **Reset-QuestBrowserFlags.ps1** (via [`QuestWrapperCommon.ps1`](QuestWrapperCommon.ps1)): the adb server restart before each retry now has timeouts (it used to run `adb kill-server` with none, which froze the window), and prints `adb: the adb server was stuck - killed it and started a fresh one.` when it had to.
- **[`Find-QuestWifiNetwork.ps1`](Find-QuestWifiNetwork.ps1)** (its own lookup, not `Connect-Quest`, so a USB entry cannot hide the Wi-Fi one): the same immediate `Repair-QuestAdbStuckServer` when `adb devices` does not answer in 10 s, sharing the once-a-minute stamp. A pass that is still stuck skips connect / mDNS (they would only run into their timeouts), and the time a hang and its reset took is added back to that network's `-PerNetworkSec`, so a hang cannot make the cycle skip the right network. Its restart after each Wi-Fi switch is the same reset (no `adb disconnect` first: against a stuck server it would only wait out its timeout).

The reset: `adb kill-server` (5 s). Only when that does not return, or the old server is still running 1 s later, it kills the `adb.exe` listening on `127.0.0.1:5037` (whatever install it came from, e.g. Meta Quest Developer Hub's: every adb client talks to it) plus every `adb.exe` from the scripts' own adb path; other installs' `adb.exe` are left alone. Then `adb start-server`, started without handing down the caller's handles: a server inherits its client's open handles, and one started from a script whose output is piped held that pipe open, so the caller waited forever after the script had finished (seen in testing). Tested by suspending the adb server: `adb devices` timed out, the reset killed it in 10 s, and the headset reconnected.

By hand (e.g. with no companion running), kill the processes, then reconnect to the port the headset advertises now:

```powershell
taskkill /F /IM adb.exe
adb mdns services
adb connect <ip:port from the _adb-tls-connect line>
```

`adb mdns services` starts a fresh server; the headset was listed at once (`10.0.100.238:46043`), and `adb connect` worked first try. Press Ctrl+C in, or close, any window still frozen on an adb command. To confirm before killing: `tasklist | findstr adb` (more than one `adb.exe` = suspect) and `netstat -ano | findstr :5037` (the server's PID).


**Headset on another Wi-Fi network.** mDNS does not cross routers, so the PC finds the headset only while both are on the same network (subnet). Off it, the headset still answers ping at its new address, but `adb mdns services` stops listing it, `adb devices` shows the old serial as *offline*, and each switch gives wireless debugging a new port. Restarting the adb server does not help.

Don't know which network the headset joined? Run [`Find-QuestWifiNetwork.ps1`](Find-QuestWifiNetwork.ps1): it tries the current network, then switches the PC through its other saved Wi-Fi profiles (`netsh wlan connect`, adb server restart after each switch) and stops on the first one where the headset answers on adb over Wi-Fi. It asks Windows for a fresh Wi-Fi scan first (`WlanScan`, ~4 s): `netsh wlan show networks` alone is the last scan, which while connected listed only the current network (1 SSID; 13 after a fresh scan, including a saved one it had missed). Profiles whose SSID (read from the profile, not its name) is in the scan go first; the rest are still tried, since a restarting AP or a hidden SSID is missing from any scan, with an 8 s connect wait instead of 20 s. Only a Wi-Fi entry counts, and a USB entry never hides one: the lookup reads every Quest entry in `adb devices -l` (the shared `Get-OnlineQuestSerial` takes the first, which can be the USB one). With the headset on USB it reads the headset's own serial there (`getprop ro.serialno`, the same over USB and Wi-Fi) and accepts only the Wi-Fi entry with that serial, so another Quest on the same network is skipped; `-Serial` (an `ip:port` or the headset's serial) picks the headset instead. `-Profiles a,b` limits the list, `-SkipOutOfRange` skips unseen networks, `-PerNetworkSec` / `-ConnectSec` / `-UnseenConnectSec` set the waits. It finds the headset only while wireless debugging is on: after a reboot that needs [adb-auto-enable](#4-keep-wireless-adb-on-across-reboots-adb-auto-enable) (step 4) with its accessibility service still enabled. If the cycle finds the headset on no network, check that first.

**Use wireless debugging (mDNS); leave `questAdbHost` empty.** It needs no config and keeps working across reboots. It works once this PC is paired: if `adb mdns services` lists the headset but `adb connect` fails with an auth error, pair once: on the headset, Settings → System → Developer → **Wireless debugging** → *Pair device with pairing code*, then `adb pair <ip>:<pairing-port>` and type the code.

**Optional fallback, fixed port 5555.** Only needed if mDNS discovery does not reach this PC (for example a VPN or Clash/mihomo TUN swallowing the multicast announcement, or the PC and Quest on different subnets), or if another tool insists on `IP:5555`. With the Quest on USB run `adb tcpip 5555`, then pass `-QuestHost <headset Wi‑Fi IP>` (Loop Segments: `"questAdbHost"` in `windows\loop-segments-windows.json`) (a DHCP reservation on the router keeps the IP stable). Limits: **a reboot closes 5555 again** (ADB Auto-Enable restores only the wireless-debugging port, and keeping 5555 needs root: `setprop persist.adb.tcp.port 5555` is refused on a stock Quest), and 5555 traffic is not encrypted (wireless debugging is). The script still falls back to mDNS when `IP:5555` does not answer.

### 6. Test

From this folder, with the headset awake:

```powershell
pwsh -File .\Invoke-QuestHeadset.ps1                       # read-only: adb path, serial, wakefulness, proximity override, last address
pwsh -File .\Invoke-QuestHeadset.ps1 -ResetAdb             # restart the PC's adb server (every adb client here drops for a few seconds)
pwsh -File .\Set-QuestProximitySensor.ps1 -State Off       # sensor off (stays awake); no -State = toggle; waits for Enter
pwsh -File .\Set-QuestWifiOff.ps1                          # headset Wi-Fi off now
pwsh -File .\Find-QuestWifiNetwork.ps1                     # PC through its saved Wi-Fi networks until the headset is on Wi-Fi adb (switches the PC's Wi-Fi)
```

Exit codes (all scripts): 0 ok, 1 headset not reachable, 2 no adb / bad arguments, 3 step failed.

## SKYBOX database

[`lib\QuestSkybox.ps1`](lib/QuestSkybox.ps1) (`Invoke-QuestSkyboxWebDav`) adds, updates or removes a WebDAV server in SKYBOX VR Player's **Network** list. SKYBOX (`xyz.skybox.player.ovr`) keeps those servers in an SQLite file on the headset's shared storage, `/sdcard/Android/data/xyz.skybox.player.ovr/files/SkyboxDataBase` (table `DeviceDataTable`); a WebDAV server is one row: `Url` `webdav://<host>:<port>/`, `FileName` (the name shown), `Username`, and `Password` **in plain text** (SKYBOX stores it that way itself). The servers this PC added are listed (URLs only) in `%TEMP%\loopsegments-skybox-webdav.json`. Loop Segments drives it from its control page and companion quit (its README: *SKYBOX: phone as a WebDAV server*).

How a change is made: the file is copied to a new folder in `%TEMP%` (the headset has no `sqlite3`) and checked with `sqlite3.exe` (shipped with adb in platform-tools; the SQL goes in on stdin, so the password is never on a command line or in the log) while SKYBOX keeps running. If the row is already right (or already gone), nothing else happens and SKYBOX is not touched. Otherwise SKYBOX is **stopped** (`am force-stop`; it holds the file open and would keep writing the old copy), the edit is refused if a `SkyboxDataBase-wal` or `SkyboxDataBase-journal` file sits next to it (see WAL mode below), the file is copied again only if its size or modified time moved, then edited, checked (`PRAGMA integrity_check`), pushed to a temp name and moved over the original. That move runs in **one headset shell command together with a last check**: it happens only if SKYBOX is still stopped, no `-wal` / `-journal` has appeared, and the database still has the size and modified time of the copy that was edited. Copying, editing and pushing take 5-15 s, and you may open SKYBOX in that time; if any check fails the pushed copy is deleted, SKYBOX's own file is left as it is, the log says why (`not replacing the database: SKYBOX was opened / a journal file appeared / SKYBOX saved to it ...`), and the button reports *failed*: press it again. The `%TEMP%` folder is always deleted. The adb shell cannot write SKYBOX's file in place but can replace it; SKYBOX keeps using the replaced file. Each copy moves the whole file (about 60 MB, 5-10 s over Wi-Fi), so with this on the companion waits up to **60 s** for the close-time cleanup instead of 40 s.

**Reopening SKYBOX needs the headset in use.** An adb launch only asks Horizon OS to start SKYBOX; the OS first has to place its window in your space. With the headset lying still (head tracking idle, even when the proximity override keeps it awake) that placement never answers, and after 10 s the launch is dropped without an error to adb: the headset log shows `Timeout while requesting window placement`, and no SKYBOX process starts. Worn or moving, the same launch starts SKYBOX at once. So after a Push / Update with nobody in the headset, SKYBOX may stay closed; open it yourself. The database change does not depend on this: it never needs SKYBOX running.

### If SKYBOX changes how it stores servers

This relies on details of SKYBOX 2.0.2 (version code 3868, checked 2026-11-12) that SKYBOX does not document and can change in any update. The plain-text password is the one that makes the full sign-in possible, and the one most likely to change. The log (`%TEMP%\loopsegments-quest-lantab.log`, lines starting `SKYBOX:`) shows which case you are in:

| If SKYBOX... | What you see | What the companion does | Workaround |
|---|---|---|---|
| **encrypts saved passwords** | **Loop Segments** shows in Network but asks for the login, or fails to sign in. The log still says `added` | Writes the plain password anyway; SKYBOX cannot use it. No harm to other servers | Use a blank password: the server still appears and SKYBOX asks for the username and password when you open it (tested with 2.0.2). Type them once per session; the close-time removal deletes what SKYBOX saved. Today that needs a one-line change (`-Password ''` in `Invoke-QuestSkyboxWebDavPush`); there is no setting for it yet |
| **renames the table or columns** | `SKYBOX: database read failed: ...` | Reads fail before any edit, so nothing is pushed; the button reports *failed* | Pull a copy (`adb pull <path>`), look at the schema (`sqlite3 SkyboxDataBase .schema`), add one WebDAV server by hand and compare, then update [`lib\QuestSkybox.ps1`](lib/QuestSkybox.ps1) |
| **moves the database or changes its package name** | `SKYBOX: not installed on the headset` or `no database yet` | Skips | Find the new path (`adb shell pm list packages` and look for skybox, then `adb shell ls -R /sdcard/Android/data/<package>`) and update `$script:SkyboxPackage` / `$script:SkyboxDbPath` |
| **switches SQLite to WAL mode** (or was killed mid-save) | `SKYBOX: database has a journal file next to it` | Refuses to edit (the main file alone would not hold SKYBOX's latest data); SKYBOX is started again if it was open | Open and close SKYBOX once (it folds the journal back in). If it keeps happening, SKYBOX moved to WAL: the edit would have to pull and push the `-wal` file too |
| **moves its data to private storage**, or Horizon OS blocks adb from `Android/data` | `SKYBOX: could not copy the database from the headset` | Skips | No adb workaround on a stock headset (`run-as` is refused: SKYBOX is not debuggable). Add the server by hand: Network → Add → Add WebDAV server, `http://<phone>:8765/`, `admin` / the app password |

**WAL mode, and why the journal check:** SQLite saves changes one of two ways. SKYBOX 2.0.2 uses the default **rollback journal** (`PRAGMA journal_mode` reports `delete`): changes go straight into `SkyboxDataBase`, and a `SkyboxDataBase-journal` holding the old contents exists only during a save, so a crash can be undone. With SKYBOX stopped, the main file is the whole, current database, which is what makes copy, edit and push back safe. In **WAL (write-ahead log)** mode, which an app turns on with one setting (`PRAGMA journal_mode=WAL`), new changes go to `SkyboxDataBase-wal` first and reach the main file only from time to time, so the real database is the main file plus `-wal`. Editing only the main file would drop what is still in `-wal` (recent servers, playback positions, folder listings), and a leftover `-wal` that no longer matches can corrupt the database. So after stopping SKYBOX the edit checks for either file and refuses if one is there. A `-journal` usually means SKYBOX was killed mid-save; opening and closing SKYBOX once clears it. A `-wal` that keeps coming back means SKYBOX switched to WAL: the edit would then have to pull and push the `-wal` file with the database (or fold it in first with `PRAGMA wal_checkpoint(TRUNCATE)` on the copy).

None of these stops the rest of the companion: each case is logged and skipped. To turn the feature off while you sort it out, set `"questSkyboxWebDav": false`.
