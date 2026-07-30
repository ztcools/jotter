<#
.SYNOPSIS
    Runs the packaged exe on Windows and inspects what it actually does.

.DESCRIPTION
    `cargo build`, clippy and svelte-check all passed on a binary that shipped
    showing the browser's ERR_CONNECTION_REFUSED page: none of them run the exe.
    This does. It drives the real process and asserts, independently —

      1. both webviews loaded the *embedded* bundle (CDP: location.href), mounted
         content, and recorded no frontend errors;
      2. both windows exist with the geometry the Rust side is supposed to give
         them — the mascot at its logical size, the notebook at one ninth of the
         work area (Win32: EnumWindows + GetWindowRect, DPI-aware);
      3. a click on the mascot opens the notebook *beside* it, and a second click
         puts it away (CDP Input, i.e. the real pointer path, not a JS shortcut);
      4. moving the mascot drags the notebook along, and the new position is
         persisted to workspace.json;
      5. a write from one window reaches the other — an item added in the
         notebook lands in the mascot's badge, which is the whole event chain
         from store hook to a second webview's DOM;
      6. the windows composite real pixels onto the desktop, proven by diffing a
         screen capture of each rect against the same rect with the window
         hidden. A transparent always-on-top window that paints nothing is
         invisible on screen while looking perfectly healthy to every API;
      7. nothing animates forever, and the process tree stays close to free
         while idle. A build that passed all of the above once spent 46% of a
         core sitting still, because on a transparent always-on-top window each
         animation frame recomposites the whole layer into the desktop.

    Anything this script adds to the user's workspace, it removes again.

    Run from Windows (or from WSL via powershell.exe). Exits non-zero on any
    failed assertion so it can gate a release.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File acceptance.ps1 -Exe C:\path\Jotter.exe
#>
[CmdletBinding()]
param(
    [string]$Exe = "$env:USERPROFILE\Desktop\Jotter.exe",
    [int]$Port = 9222,
    # Seconds to wait for the webviews to expose debugging targets.
    [int]$Timeout = 25,
    # Leave the widget running afterwards (it is the user's, after all).
    [switch]$Stop,
    # Skip the screen-capture assertions, which need a real desktop session. Every
    # other check works headless, which is what makes this script usable in CI.
    [switch]$SkipPixel
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- Win32 interop
if (-not ('W32' -as [type])) {
    Add-Type -Namespace '' -Name W32 -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern int GetWindowLongW(IntPtr h, int i);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int t, uint flags);
[DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, System.Text.StringBuilder s, int max);
public delegate bool EnumProc(IntPtr h, IntPtr p);
'@
}

# BEFORE any window or graphics call. PowerShell is DPI-unaware by default, which
# silently virtualises every coordinate it reads or captures: on a 150% display
# GetWindowRect reported a 108px window as 72px, and a capture of that rect
# clipped the mascot — a bug in the harness that looked exactly like a bug in the
# app. Per-monitor-v2 (-4) puts this process in the same physical pixel space as
# the widget and as workspace.json.
$dpiAware = [W32]::SetProcessDpiAwarenessContext([IntPtr](-4))
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

# Redirected output (a CI log, a WSL pipe) otherwise goes out in the console's
# ANSI code page and mangles every non-ASCII character this script prints.
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

$script:Failures = 0
function Ok   ($m) { Write-Host "[ok]   $m" }
function Info ($m) { Write-Host "[info] $m" }
function Bad  ($m) { $script:Failures++; Write-Host "[FAIL] $m" }
function Check($cond, $m) { if ($cond) { Ok $m } else { Bad $m } }
function Near($a, $b, $tol) { return ([math]::Abs($a - $b) -le $tol) }

$GWL_EXSTYLE = -20; $WS_EX_TOPMOST = 0x8; $WS_EX_LAYERED = 0x80000
$SW_HIDE = 0; $SW_SHOWNA = 8
# How far a corner pixel may move, per channel, and still count as showing the
# desktop through. Headroom, not a measurement: a truly clear corner reads 0 here,
# and the slack is for the panel's drop shadow, which paints into that same
# transparent margin and could tint a corner without making it opaque. Paper over
# any backdrop that is not itself paper-coloured moves a corner by far more.
$CORNER_TOLERANCE = 48
$SWP_NOSIZE = 0x1; $SWP_NOZORDER = 0x4; $SWP_NOACTIVATE = 0x10

function Get-AppWindows([int]$ProcId) {
    # An ArrayList mutated via .Add, not `$found += ...`: a scriptblock used as a
    # delegate can read the enclosing scope but any assignment inside it creates
    # a scriptblock-local variable, so `+=` would silently collect nothing.
    $found = New-Object System.Collections.ArrayList
    $cb = [W32+EnumProc] {
        param($h, $p)
        $owner = 0; [W32]::GetWindowThreadProcessId($h, [ref]$owner) | Out-Null
        if ($owner -eq $ProcId) {
            $r = New-Object W32+RECT; [W32]::GetWindowRect($h, [ref]$r) | Out-Null
            $sb = New-Object System.Text.StringBuilder 256
            [W32]::GetClassNameW($h, $sb, 256) | Out-Null
            $ex = [W32]::GetWindowLongW($h, $GWL_EXSTYLE)
            [void]$found.Add([pscustomobject]@{
                Handle  = $h
                Class   = $sb.ToString()
                Visible = [W32]::IsWindowVisible($h)
                X = $r.L; Y = $r.T; W = ($r.R - $r.L); H = ($r.B - $r.T)
                TopMost = [bool]($ex -band $WS_EX_TOPMOST)
                Layered = [bool]($ex -band $WS_EX_LAYERED)
            })
        }
        return $true
    }
    [W32]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
    return $found.ToArray()
}

# The mascot is the square one; the notebook is the other Tauri window. Chosen by
# shape rather than by title, because both windows carry the same title.
function Get-Ball($wins) {
    return $wins | Where-Object { $_.Class -eq 'Tauri Window' -and (Near $_.W $_.H 4) } |
        Select-Object -First 1
}
function Get-Panel($wins) {
    return $wins | Where-Object { $_.Class -eq 'Tauri Window' -and -not (Near $_.W $_.H 4) } |
        Select-Object -First 1
}

function Get-RectPixels($x, $y, $w, $h) {
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size $w, $h))
    $g.Dispose()
    $px = New-Object 'int[]' ($w * $h)
    for ($j = 0; $j -lt $h; $j++) {
        for ($i = 0; $i -lt $w; $i++) { $px[$j * $w + $i] = $bmp.GetPixel($i, $j).ToArgb() }
    }
    $bmp.Dispose()
    return $px
}

function Test-Composites($win, $label) {
    if ($SkipPixel) { Info "$label pixel diff skipped (-SkipPixel)"; return }
    if (-not $win) { Bad "no $label window to pixel-test"; return }
    $shown = Get-RectPixels $win.X $win.Y $win.W $win.H
    [W32]::ShowWindow($win.Handle, $SW_HIDE) | Out-Null; Start-Sleep -Milliseconds 700
    $hidden = Get-RectPixels $win.X $win.Y $win.W $win.H
    [W32]::ShowWindow($win.Handle, $SW_SHOWNA) | Out-Null; Start-Sleep -Milliseconds 300
    $diff = 0
    for ($i = 0; $i -lt $shown.Length; $i++) { if ($shown[$i] -ne $hidden[$i]) { $diff++ } }
    $pct = [math]::Round(100 * $diff / $shown.Length, 1)
    # A weak-by-construction assertion: it proves the window paints, not that it
    # paints the right thing. Judging the drawing is a job for the eye — see
    # `pnpm dev` + preview.html for that.
    Check ($diff -gt 0) "$label composites real pixels ($diff/$($shown.Length) differ, $pct%)"

    # …and at the corners the desktop must still be recognisable, because a rounded
    # transparent widget shows through them. This is the only check that
    # distinguishes the intended surface from an opaque rectangle of the right size:
    # window styles do not say — WebView2 transparency is composited, so
    # WS_EX_LAYERED is not set.
    #
    # Not equality, which this asserted at first and which flaked: a pixel of
    # desktop can change on its own between the two captures — anything animating
    # behind the widget — and that read as "the corner is opaque". Those pixels are
    # now found by a second reading and dropped, since they can say nothing either
    # way. What is left is judged by distance rather than equality, for the panel's
    # drop shadow, which paints into this same transparent margin.
    #
    # Every arithmetic term is parenthesised because `,` binds tighter than `-` in
    # PowerShell: `@($win.W - 2, 1)` means `$win.W - (2, 1)`.
    $corners = @(@(1, 1), @(($win.W - 2), 1), @(1, ($win.H - 2)), @(($win.W - 2), ($win.H - 2)))
    $clear = 0
    $judged = 0
    $deltas = @()
    foreach ($c in $corners) {
        $i = $c[1] * $win.W + $c[0]
        # Re-read this one pixel while the window is still hidden: if the desktop
        # changed it by itself, it can say nothing about our window.
        $again = (Get-RectPixels ($win.X + $c[0]) ($win.Y + $c[1]) 1 1)[0]
        if ($again -ne $hidden[$i]) { $deltas += 'unstable'; continue }
        $judged++
        $a = [System.Drawing.Color]::FromArgb($shown[$i])
        $b = [System.Drawing.Color]::FromArgb($hidden[$i])
        $delta = [math]::Max([math]::Abs($a.R - $b.R),
            [math]::Max([math]::Abs($a.G - $b.G), [math]::Abs($a.B - $b.B)))
        $deltas += $delta
        if ($delta -le $CORNER_TOLERANCE) { $clear++ }
    }
    Info "$label corner deltas: $($deltas -join ', ') (tolerance $CORNER_TOLERANCE)"
    # All but one of the corners that could be read, and at least two read: one
    # corner may sit over something that moved for its own reasons, but a window
    # that is opaque is opaque at every corner.
    Check ($judged -ge 2 -and $clear -ge [math]::Max(2, ($judged - 1))) `
        "$label has transparent corners ($clear/$judged readable corners show the desktop through)"
}

# ------------------------------------------------------------------- CDP client
function Connect-Cdp([string]$Url) {
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $ws.ConnectAsync([Uri]$Url, [Threading.CancellationToken]::None).Wait(10000) | Out-Null
    return $ws
}

$script:CdpId = 0
function Invoke-Cdp($Ws, [string]$Method, $Params) {
    $script:CdpId++
    $id = $script:CdpId
    $req = @{ id = $id; method = $Method; params = $Params } | ConvertTo-Json -Depth 8 -Compress
    $seg = [ArraySegment[byte]]::new([Text.Encoding]::UTF8.GetBytes($req))
    $Ws.SendAsync($seg, 'Text', $true, [Threading.CancellationToken]::None).Wait(5000) | Out-Null

    # Read frames until the reply to this id arrives; CDP interleaves events.
    $buf = [ArraySegment[byte]]::new((New-Object byte[] 262144))
    for ($n = 0; $n -lt 80; $n++) {
        $sb = New-Object Text.StringBuilder
        do {
            $r = $Ws.ReceiveAsync($buf, [Threading.CancellationToken]::None)
            $r.Wait(15000) | Out-Null
            [void]$sb.Append([Text.Encoding]::UTF8.GetString($buf.Array, 0, $r.Result.Count))
        } until ($r.Result.EndOfMessage)
        $msg = $sb.ToString() | ConvertFrom-Json
        if ($msg.id -eq $id) { return $msg }
    }
    throw "no CDP reply for id $id ($Method)"
}

function Invoke-Js($Ws, [string]$Expression) {
    $msg = Invoke-Cdp $Ws 'Runtime.evaluate' @{
        expression = $Expression; returnByValue = $true; awaitPromise = $true
    }
    if ($msg.result.exceptionDetails) {
        throw "JS threw: $($msg.result.exceptionDetails.exception.description)"
    }
    return $msg.result.result.value
}

# A real pointer press and release inside the webview, which is what the mascot
# listens for. `Runtime.evaluate`-ing a `.click()` would bypass the pointerdown /
# threshold / pointerup logic that decides click-versus-drag — i.e. it would test
# something the user never does.
function Send-Click($Ws, [int]$X, [int]$Y) {
    foreach ($t in @('mousePressed', 'mouseReleased')) {
        Invoke-Cdp $Ws 'Input.dispatchMouseEvent' @{
            type = $t; x = $X; y = $Y; button = 'left'; clickCount = 1
            buttons = $(if ($t -eq 'mousePressed') { 1 } else { 0 })
        } | Out-Null
    }
}

# A press that travels far enough to become a window drag. The intermediate moves
# are the point: the threshold that separates a drag from a click only ever sees
# `pointermove`, so a press-then-release would test the other branch.
function Send-Drag($Ws, [int]$X, [int]$Y, [int]$By) {
    Invoke-Cdp $Ws 'Input.dispatchMouseEvent' @{
        type = 'mousePressed'; x = $X; y = $Y; button = 'left'; clickCount = 1; buttons = 1
    } | Out-Null
    foreach ($step in 3, 9, 18, $By) {
        Invoke-Cdp $Ws 'Input.dispatchMouseEvent' @{
            type = 'mouseMoved'; x = ($X + $step); y = ($Y + $step); button = 'left'; buttons = 1
        } | Out-Null
    }
    Invoke-Cdp $Ws 'Input.dispatchMouseEvent' @{
        type = 'mouseReleased'; x = ($X + $By); y = ($Y + $By); button = 'left'; clickCount = 1; buttons = 0
    } | Out-Null
}

# ------------------------------------------------------------------------- run
if (-not (Test-Path $Exe)) { Bad "exe not found: $Exe"; exit 1 }
$exeItem = Get-Item $Exe
Info "exe      $Exe  ($($exeItem.Length) bytes, $($exeItem.LastWriteTime))"
Info "dpi-aware $dpiAware"

$workspacePath = "$env:APPDATA\com.ztcools.jotter\workspace.json"
$logPath = "$env:LOCALAPPDATA\com.ztcools.jotter\logs\Jotter.log"
# Only lines this run appends are this run's problem. Counted in lines rather than
# bytes: the log is UTF-8, so a byte offset would slice a multi-byte character in
# half the first time anything Chinese is logged.
$logLinesBefore = 0
if (Test-Path $logPath) {
    $logLinesBefore = @(Get-Content $logPath -Encoding UTF8).Count
}

Get-Process Jotter -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 500

# The webview only opens a debugging port when asked; this is the sole way to see
# the pages the app is really showing.
$env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--remote-debugging-port=$Port"
$proc = Start-Process $Exe -PassThru
Info "pid      $($proc.Id)"

$targets = @()
for ($i = 0; $i -lt ($Timeout * 2); $i++) {
    Start-Sleep -Milliseconds 500
    try {
        $targets = @((Invoke-RestMethod "http://127.0.0.1:$Port/json" -TimeoutSec 2) |
            Where-Object { $_.type -eq 'page' })
        # Waiting for the count alone catches a webview that exists but has not
        # navigated yet: the notebook is listed as `about:blank` for a moment
        # before its document loads, which reads exactly like a broken window.
        if (@($targets | Where-Object { $_.url -like '*panel.html*' }).Count -ge 1 -and
            @($targets | Where-Object { $_.url -like 'http*' -and $_.url -notlike '*panel.html*' }).Count -ge 1) {
            break
        }
    } catch { }
}
Check ($targets.Count -ge 2) "both webviews exposed a CDP target ($($targets.Count) found)"
if ($targets.Count -lt 1) { exit 1 }
$targets | ForEach-Object { Info "target   $($_.url)" }

$ballTarget  = $targets |
    Where-Object { $_.url -like 'http*' -and $_.url -notlike '*panel.html*' } | Select-Object -First 1
$panelTarget = $targets | Where-Object { $_.url -like '*panel.html*' } | Select-Object -First 1
Check ($null -ne $ballTarget)  "mascot document is loaded"
Check ($null -ne $panelTarget) "notebook document is loaded"
if (-not $ballTarget -or -not $panelTarget) { exit 1 }

$ballWs  = Connect-Cdp $ballTarget.webSocketDebuggerUrl
$panelWs = Connect-Cdp $panelTarget.webSocketDebuggerUrl

# One round trip per window, so a slow first paint cannot desynchronise the
# assertions.
$probeJs = @'
JSON.stringify({
  href:   location.href,
  ready:  document.readyState,
  app:    (document.querySelector("#app") ? document.querySelector("#app").innerHTML.length : -1),
  nodes:  document.querySelectorAll("*").length,
  body:   (document.body ? document.body.innerText : "").slice(0, 120),
  ipc:    typeof window.__TAURI_INTERNALS__,
  errors: (window.__jotterErrors || []).slice(0, 5)
})
'@
foreach ($pair in @(@{ n = 'mascot'; ws = $ballWs }, @{ n = 'notebook'; ws = $panelWs })) {
    $p = (Invoke-Js $pair.ws $probeJs) | ConvertFrom-Json
    Info "$($pair.n): $($p.href) — $($p.app) bytes, $($p.nodes) nodes, ipc=$($p.ipc)"
    # tauri.localhost is the custom protocol serving the embedded bundle. A dev
    # binary reports http://localhost:1420 or, with nothing there, chrome-error://.
    Check ($p.href -notlike 'chrome-error*')  "$($pair.n) is not on a browser error page"
    Check ($p.href -like '*tauri.localhost*') "$($pair.n) loaded the embedded bundle"
    Check ($p.app -gt 0)                      "$($pair.n) mounted content ($($p.app) bytes)"
    Check ($p.ipc -eq 'object')               "$($pair.n) has the Tauri IPC bridge"
    Check ($p.errors.Count -eq 0)             "$($pair.n) recorded no frontend errors"
    if ($p.errors.Count) { $p.errors | ForEach-Object { Info "  js error: $_" } }
    if ($p.href -like 'chrome-error*') { Info "  body: $($p.body)" }
}

# ------------------------------------------------------------------- geometry
$wins = Get-AppWindows $proc.Id
foreach ($w in $wins) {
    Info ("window   {0} {1}x{2} at ({3},{4}) visible={5} topmost={6} layered={7} class={8}" -f `
        $w.Handle, $w.W, $w.H, $w.X, $w.Y, $w.Visible, $w.TopMost, $w.Layered, $w.Class)
}
$ball = Get-Ball $wins
$panel = Get-Panel $wins
Check ($null -ne $ball)  "mascot window exists"
Check ($null -ne $panel) "notebook window exists (created up front, hidden)"
if (-not $ball -or -not $panel) { exit 1 }

Check ($ball.Visible)      "mascot is visible on startup"
Check (-not $panel.Visible) "notebook starts hidden"
Check ($ball.TopMost)      "mascot is always-on-top"
Check ($panel.TopMost)     "notebook is always-on-top"

$dpi = [W32]::GetDpiForWindow($ball.Handle)
$scale = $dpi / 96.0
# The monitor the mascot is on, not the primary one: `Monitor::work_area()` on the
# Rust side is per-monitor too, so on a multi-head desktop the primary screen's
# numbers would be the wrong yardstick.
$work = [System.Windows.Forms.Screen]::FromHandle($ball.Handle).WorkingArea
Info "dpi      $dpi (scale $scale), work area $($work.Width)x$($work.Height) at ($($work.X),$($work.Y))"

# Must match `window.rs`: BALL_SIZE, PANEL_GRID, PANEL_MIN, PANEL_MAX.
$ballExpect = [math]::Round(104 * $scale)
Check (Near $ball.W $ballExpect 6) "mascot is $ballExpect px physical (104 logical), got $($ball.W)"

function Get-ExpectedCell($physical, $min, $max) {
    $logical = $physical / $scale / 3.0
    return [math]::Round([math]::Min([math]::Max($logical, $min), $max) * $scale)
}
$panelExpectW = Get-ExpectedCell $work.Width  460 760
$panelExpectH = Get-ExpectedCell $work.Height 300 520
$ninth = [math]::Round(100.0 * ($panel.W * $panel.H) / ($work.Width * $work.Height), 1)
Info "notebook $($panel.W)x$($panel.H) (expected ${panelExpectW}x${panelExpectH}), $ninth% of work area"
Check (Near $panel.W $panelExpectW 8) "notebook width is the clamped 1/3 of the work area"
Check (Near $panel.H $panelExpectH 8) "notebook height is the clamped 1/3 of the work area"

$inWork = ($ball.X -ge $work.X) -and ($ball.Y -ge $work.Y) -and
          (($ball.X + $ball.W) -le ($work.X + $work.Width)) -and
          (($ball.Y + $ball.H) -le ($work.Y + $work.Height))
Check $inWork "mascot sits inside the work area (clear of the taskbar)"

# ---------------------------------------------------------------- interaction
$gap = [math]::Round(12 * $scale)

$edge = [math]::Round(10 * $scale)

function Test-Anchored($ballWin, $panelWin, $label) {
    $rightOf = Near $panelWin.X ($ballWin.X + $ballWin.W + $gap) 6
    $leftOf  = Near ($panelWin.X + $panelWin.W) ($ballWin.X - $gap) 6
    Check ($rightOf -or $leftOf) "$label — notebook is beside the mascot (gap $gap px)"

    # Centred on the mascot, *unless* that would have pushed it off screen and the
    # clamp moved it: accepting "within half a panel height" instead would accept
    # very nearly anything, and accepting only dead-centre would fail whenever the
    # mascot sits near the top or bottom of the work area.
    $centred = Near ($panelWin.Y + $panelWin.H / 2) ($ballWin.Y + $ballWin.H / 2) 6
    $clamped = (Near $panelWin.Y ($work.Y + $edge) 2) -or
               (Near ($panelWin.Y + $panelWin.H) ($work.Y + $work.Height - $edge) 2)
    Check ($centred -or $clamped) `
        "$label — notebook is centred on the mascot (or clamped to the work area)"
}

$caretOnCaptureLine =
    'JSON.stringify(document.activeElement === document.querySelector(".composer input"))'

Info "clicking the mascot…"
Send-Click $ballWs ([int]($ball.W / $scale / 2)) ([int]($ball.H / $scale / 2))
Start-Sleep -Milliseconds 900
$wins = Get-AppWindows $proc.Id
$panel = Get-Panel $wins
Check ($panel.Visible) "a click on the mascot opens the notebook"
if ($panel.Visible) {
    Info ("notebook at ({0},{1}) {2}x{3}" -f $panel.X, $panel.Y, $panel.W, $panel.H)
    Test-Anchored (Get-Ball $wins) $panel 'on open'
    Test-Composites $panel 'notebook'
}

# An open notebook you have to click into before you can type is not the thing
# that was asked for, and no amount of reading the source settles which way this
# goes: the window is created hidden, a hidden webview refuses focus, and the
# document never remounts afterwards. Ask the running app.
Check ((Invoke-Js $panelWs $caretOnCaptureLine) -eq 'true') `
    "the caret is on the capture line when the notebook opens"

# Moving the mascot must drag the notebook along. Done with SetWindowPos rather
# than synthetic mouse input: `startDragging` hands the gesture to the OS drag
# loop, which only responds to real hardware events — but what is being tested
# here is the tether (the Moved handler) and the persistence, both of which a
# programmatic move exercises exactly the same way.
$moveX = $work.X + [int]($work.Width * 0.45)
$moveY = $work.Y + [int]($work.Height * 0.35)
Info "moving the mascot to ($moveX,$moveY)…"
[W32]::SetWindowPos($ball.Handle, [IntPtr]::Zero, $moveX, $moveY, 0, 0,
    ($SWP_NOSIZE -bor $SWP_NOZORDER -bor $SWP_NOACTIVATE)) | Out-Null
Start-Sleep -Milliseconds 900
$wins = Get-AppWindows $proc.Id
$ball = Get-Ball $wins; $panel = Get-Panel $wins
Check (Near $ball.X $moveX 4) "mascot moved to the requested position"
Test-Anchored $ball $panel 'after a drag'

# --------------------------------------------------------- cross-window events
# An item added through the notebook's IPC must show up in the mascot's badge:
# store hook -> `badge` event -> the other webview's DOM. Cleaned up afterwards.
$probeText = "acceptance probe (safe to delete)"
$added = (Invoke-Js $panelWs @"
(async () => {
  const inv = window.__TAURI_INTERNALS__.invoke;
  const ws = await inv('load_workspace');
  const cardId = ws.activeCardId;
  const item = await inv('add_item', { cardId, text: '$probeText' });
  const after = await inv('load_workspace');
  const open = after.cards.reduce((n, c) => n + c.items.filter(i => !i.done).length, 0);
  return JSON.stringify({ cardId, itemId: item.id, open });
})()
"@) | ConvertFrom-Json
Start-Sleep -Milliseconds 600
$badge = Invoke-Js $ballWs 'JSON.stringify(document.querySelector(".badge") ? document.querySelector(".badge").textContent : null)'
$badgeText = $badge | ConvertFrom-Json
# The badge caps its label, so the expectation has to cap the same way.
$badgeExpect = if ($added.open -gt 99) { '99+' } else { [string]$added.open }
Info "badge    '$badgeText' for $($added.open) open item(s)"
Check ($badgeText -eq $badgeExpect) "a write in the notebook updates the mascot's badge"

Invoke-Js $panelWs @"
window.__TAURI_INTERNALS__.invoke('delete_item', { cardId: '$($added.cardId)', itemId: '$($added.itemId)' })
"@ | Out-Null
Info "probe item removed"

# ------------------------------------------------------------------- put away
Info "clicking the mascot again…"
Send-Click $ballWs ([int]($ball.W / $scale / 2)) ([int]($ball.H / $scale / 2))
Start-Sleep -Milliseconds 900
$wins = Get-AppWindows $proc.Id
Check (-not (Get-Panel $wins).Visible) "a second click puts the notebook away"
Check ((Get-Ball $wins).Visible) "the mascot stays visible"

# Closing the panel flushes the mascot's position, so the move above must now be
# on disk in physical pixels — which is only comparable because this process is
# DPI-aware.
if (Test-Path $workspacePath) {
    try {
        # `-Encoding UTF8` is not optional: Windows PowerShell reads a BOM-less file
        # in the console's ANSI code page, which turns any CJK note in the workspace
        # into invalid JSON — a harness failure that looks like corrupted user data.
        $saved = (Get-Content $workspacePath -Raw -Encoding UTF8 | ConvertFrom-Json).ballPosition
        Info "saved    ballPosition = ($($saved.x),$($saved.y))"
        Check ((Near $saved.x $moveX 4) -and (Near $saved.y $moveY 4)) `
            "the new mascot position was persisted to workspace.json"
    } catch {
        Bad "workspace.json is not readable JSON: $($_.Exception.Message)"
    }
} else {
    Bad "workspace.json not found at $workspacePath"
}

Test-Composites (Get-Ball $wins) 'mascot'

# Reopening is the case that regresses: the notebook was hidden rather than
# destroyed, so a fix that only runs when the document mounts works exactly once.
Info "reopening the notebook…"
Send-Click $ballWs ([int]($ball.W / $scale / 2)) ([int]($ball.H / $scale / 2))
Start-Sleep -Milliseconds 1300
Check ((Get-Panel (Get-AppWindows $proc.Id)).Visible) "the notebook reopens"
Check ((Invoke-Js $panelWs $caretOnCaptureLine) -eq 'true') `
    "the caret is on the capture line again after a reopen"

# ------------------------------------------------- gestures that must NOT close
# Dragging the mascot activates the mascot's window, which blurs the notebook.
# Reacting to that blur closed the notebook mid-drag: the card vanished the moment
# the cat started moving.
$centreX = [int]($ball.W / $scale / 2)
$centreY = [int]($ball.H / $scale / 2)
Info "dragging the mascot with the notebook open…"
Send-Drag $ballWs $centreX $centreY 26
Start-Sleep -Milliseconds 1100
Check ((Get-Panel (Get-AppWindows $proc.Id)).Visible) `
    "dragging the mascot leaves the notebook open"

# A press on the notebook's own drag handle must not close it either. Synthetic
# input cannot reproduce the whole failure — the OS move loop needs a physically
# held button, and it is the activation churn of entering that loop that blurred
# the window — so this asserts the half that is reachable: nothing in the document
# treats a press on the header or the spine as "close".
Send-Click $panelWs 400 12
Start-Sleep -Milliseconds 600
Check ((Get-Panel (Get-AppWindows $proc.Id)).Visible) "a press on the header leaves the notebook open"
Send-Click $panelWs 11 200
Start-Sleep -Milliseconds 600
Check ((Get-Panel (Get-AppWindows $proc.Id)).Visible) "a press on the spine leaves the notebook open"

# ------------------------------------------------------ …and one that still must
# The other half of the same change: a blur that really is the user going
# elsewhere has to keep putting the notebook away, or the widget starts sitting on
# top of the very UI being reviewed.
$away = Start-Process cmd -ArgumentList '/k', 'title jotter-focus-steal' -PassThru -ErrorAction SilentlyContinue
if ($away) {
    Start-Sleep -Milliseconds 1000
    try { (New-Object -ComObject WScript.Shell).AppActivate($away.Id) | Out-Null } catch { }
    Start-Sleep -Milliseconds 1300
    # Whether anything actually took the foreground is a fact to read, not to
    # assume: a session that grants it to nobody would otherwise fail this as if
    # the app were broken.
    $fgPid = 0
    [W32]::GetWindowThreadProcessId([W32]::GetForegroundWindow(), [ref]$fgPid) | Out-Null
    if ($fgPid -ne 0 -and $fgPid -ne $proc.Id) {
        Check (-not (Get-Panel (Get-AppWindows $proc.Id)).Visible) `
            "focusing another app still puts the notebook away"
    }
    else {
        Info "skipped click-away check: the foreground never left the widget (pid $fgPid)"
    }
    Stop-Process -Id $away.Id -Force -ErrorAction SilentlyContinue
}
else {
    Info "skipped click-away check: could not start a second app"
}

# ------------------------------------------------------------------ idle cost
# The widget is on screen from login to shutdown, so its cost while nobody is
# touching it is a feature, not a footnote. This section exists because a build
# that passed every other assertion above burned 46% of a CPU core doing nothing:
# on a transparent always-on-top window every animation frame recomposites the
# window's layer into the desktop, so a mascot that breathes continuously costs
# about as much as a video. The fix was to make every ambient movement a finite
# burst, and these two checks are what stop it coming back.

# 1. Nothing may animate forever. Cheaper and far more specific than the CPU
#    reading below: it names the offender instead of reporting a number.
$foreverJs = @'
(() => { const a = document.getAnimations ? document.getAnimations() : [];
  return JSON.stringify(a.filter(x => {
    const t = x.effect && x.effect.getComputedTiming ? x.effect.getComputedTiming() : {};
    return t.iterations === Infinity || t.iterations === null || t.activeDuration === Infinity;
  }).map(x => x.animationName || String(x))); })()
'@ -replace "`r?`n", ' '
foreach ($pair in @(@{n = 'mascot'; ws = $ballWs }, @{n = 'notebook'; ws = $panelWs })) {
    $forever = @((Invoke-Js $pair.ws $foreverJs | ConvertFrom-Json))
    Check ($forever.Count -eq 0) `
        "$($pair.n) has no animation that runs forever$(if ($forever.Count) { ": $($forever -join ', ')" })"
}

# 2. …and the resulting cost, measured. Sums the whole tree, because the work
#    lands in the WebView2 renderer and GPU processes rather than in ours.
function Get-TreeCpu([int]$RootPid) {
    $all = Get-CimInstance Win32_Process | Select-Object ProcessId, ParentProcessId
    $ids = New-Object System.Collections.Generic.HashSet[int]
    [void]$ids.Add($RootPid)
    # WebView2 nests its children a few levels deep; repeat until the set stops
    # growing rather than assuming a depth.
    for ($pass = 0; $pass -lt 6; $pass++) {
        foreach ($p in $all) { if ($ids.Contains([int]$p.ParentProcessId)) { [void]$ids.Add([int]$p.ProcessId) } }
    }
    $sum = [TimeSpan]::Zero
    foreach ($id in $ids) {
        $o = Get-Process -Id $id -ErrorAction SilentlyContinue
        if ($o) { $sum += $o.TotalProcessorTime }
    }
    return $sum
}

# Generous enough that a burst landing inside the window cannot fail it (one
# 1.5s burst is worth ~6 points here), tight enough that anything animating
# continuously — the defect this guards against — cannot pass.
$IDLE_CPU_BUDGET = 15.0
$cpuBefore = Get-TreeCpu $proc.Id
$clock = [Diagnostics.Stopwatch]::StartNew()
Start-Sleep -Seconds 12
$clock.Stop()
$cpuMs = ((Get-TreeCpu $proc.Id) - $cpuBefore).TotalMilliseconds
$idlePct = 100 * $cpuMs / $clock.Elapsed.TotalMilliseconds
Info ("idle cpu {0:N1}% of one core over {1:N0}s (budget {2:N0}%)" -f $idlePct, $clock.Elapsed.TotalSeconds, $IDLE_CPU_BUDGET)
Check ($idlePct -lt $IDLE_CPU_BUDGET) "the widget is close to free while idle"

# ----------------------------------------------------------------------- logs
if (Test-Path $logPath) {
    $fresh = @(Get-Content $logPath -Encoding UTF8 | Select-Object -Skip $logLinesBefore)
    $errors = @($fresh | Where-Object { $_ -match 'ERROR' })
    Check ($errors.Count -eq 0) "no ERROR lines logged during this run"
    $errors | ForEach-Object { Info "  $_" }
    Info "--- tail $logPath ---"
    ($fresh | Where-Object { $_ } | Select-Object -Last 10) | ForEach-Object { Info "  $_" }
}

if ($Stop) { Get-Process Jotter -ErrorAction SilentlyContinue | Stop-Process -Force }
else { Info "widget left running (pass -Stop to close it)" }

Write-Host ""
if ($script:Failures -eq 0) { Write-Host "ACCEPTANCE PASS"; exit 0 }
Write-Host "ACCEPTANCE FAIL ($script:Failures assertion(s))"
exit 1
