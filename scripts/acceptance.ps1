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

    Run it on a quiet desktop. It drives the very widget the person at the
    keyboard can see, so one real click on the mascot puts the notebook away
    underneath the harness and inverts every open/closed assertion that follows.
    Real presses are counted and reported, so a disturbed run says so instead of
    reading like a regression.

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
    [switch]$SkipPixel,
    # Skip the idle-CPU reading. A percentage of one core is only meaningful on a
    # machine that is otherwise quiet; on a shared two-core CI runner it says more
    # about the neighbours than about us. The invariant behind it — that nothing
    # animates forever — is asserted deterministically either way.
    [switch]$SkipCpu
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
[DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vk);
[StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
[DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
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
    # A pointer moving across the captured rect changes it between the two shots,
    # which is exactly what the corner readings then report as "unstable".
    Measure-HumanInput
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
    if ($judged -lt 2) {
        # Every corner moved on its own, so the backdrop this check compares
        # against does not exist. Something is animating behind the window — the
        # author's own desktop does this — and no reading here can say anything
        # about transparency. The pixel diff above still proves the window paints.
        Info "$label transparency not judged: the desktop behind it will not hold still"
    }
    else {
        Check ($clear -ge [math]::Max(2, ($judged - 1))) `
            "$label has transparent corners ($clear/$judged readable corners show the desktop through)"
    }
}

# ------------------------------------------------------------------- CDP client
# Both of these go out of their way to keep a proxy out of the path. .NET applies
# the system proxy to 127.0.0.1 as readily as to the internet, and where one is
# configured the request does not fail fast — it hangs until it times out, which
# reads exactly like a webview that never opened its debugging port. Two hops on
# loopback should not depend on a machine's proxy settings at all.
function Get-Local([string]$Path, [int]$TimeoutMs = 2000) {
    $req = [Net.HttpWebRequest]::Create("http://127.0.0.1:$Port$Path")
    $req.Proxy = $null
    $req.Timeout = $TimeoutMs
    $req.ReadWriteTimeout = $TimeoutMs
    $res = $req.GetResponse()
    try {
        $reader = New-Object IO.StreamReader($res.GetResponseStream(), [Text.Encoding]::UTF8)
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    }
    finally { $res.Dispose() }
}

function Connect-Cdp([string]$Url) {
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $ws.Options.Proxy = $null
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

# The app's own escape hatch for "focus is about to be stolen by something that is
# not the user walking away" — it brackets its native file dialogs with this. The
# harness needs it for the same reason (see the pixel capture below), and reaching
# for the real command keeps the widget's behaviour under test rather than
# working around it.
function Suspend-AutoCollapse($Ws, [bool]$On) {
    $arg = $On.ToString().ToLower()
    Invoke-Js $Ws `
        "window.__TAURI_INTERNALS__.invoke('suspend_auto_collapse', { suspend: $arg })" | Out-Null
}

# This harness shares the desktop with whoever is sitting at it, and the widget it
# drives is the same one they can see. One real click on the mascot toggles the
# notebook, which inverts every open/closed expectation after it; one real drag
# moves the mascot, which breaks the anchor and the persisted position. Runs have
# failed six assertions that way on a build that passes when the desk is empty.
#
# The low bit of GetAsyncKeyState is "pressed since the last call", so sampling it
# after each synthetic interaction catches presses in between without polling.
# Synthetic CDP input never touches the physical key state, so ours cannot trip it.
#
# The pointer is the louder signal, because the harness parks it (see the
# interaction section) and then nothing of ours moves it: any displacement is
# somebody else's hand. Twelve consecutive samples caught it wandering across the
# screen and the mascot following it into the corner, which is what finally
# explained a run that failed seven assertions on a binary that passes.
$script:HumanPresses = 0
$script:PointerNudges = 0
$script:ParkPoint = $null
# Re-parking keeps the rest of the run meaningful, but only for the first few
# nudges: past that the desk is plainly in use and wrestling somebody for their
# own mouse is not this script's place.
$REPARK_LIMIT = 3
function Measure-HumanInput {
    foreach ($vk in 0x01, 0x02) {
        if ([W32]::GetAsyncKeyState($vk) -band 0x1) { $script:HumanPresses++ }
    }
    if (-not $script:ParkPoint) { return }
    $now = New-Object W32+POINT
    if (-not [W32]::GetCursorPos([ref]$now)) { return }
    if ((Near $now.X $script:ParkPoint.X 4) -and (Near $now.Y $script:ParkPoint.Y 4)) { return }
    $script:PointerNudges++
    if ($script:PointerNudges -le $REPARK_LIMIT) {
        [W32]::SetCursorPos($script:ParkPoint.X, $script:ParkPoint.Y) | Out-Null
    }
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
    Measure-HumanInput
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
    Measure-HumanInput
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

# The webview only opens a debugging port when asked, through this environment
# variable, and reading the pages the app really shows depends on it arriving.
#
# Not Start-Process, which launches through ShellExecute: a process created that
# way can be handed an environment block that is not the one we just modified. On
# a desktop it happened to work; on a CI runner the same call produced a webview
# whose command line had no trace of the switch, so nothing ever listened on the
# port. CreateProcess with an explicit environment (UseShellExecute = false) is
# the only way to be sure the child sees what we set.
$exePath = (Resolve-Path $Exe).Path
$psi = New-Object Diagnostics.ProcessStartInfo
$psi.FileName = $exePath
$psi.WorkingDirectory = Split-Path -Parent $exePath
$psi.UseShellExecute = $false
$psi.EnvironmentVariables['WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS'] = "--remote-debugging-port=$Port"
$proc = [Diagnostics.Process]::Start($psi)
Info "pid      $($proc.Id)"

$targets = @()
for ($i = 0; $i -lt ($Timeout * 2); $i++) {
    Start-Sleep -Milliseconds 500
    try {
        $targets = @((Get-Local '/json' | ConvertFrom-Json) |
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
# Everything below needs a debugging target, so a failure here ends the run. It
# used to end it with nothing but the count, which on a machine that is not the
# author's desktop — a CI runner, a colleague's laptop — leaves no way to tell a
# missing WebView2 runtime from a process that died on startup. So say what is
# knowable before giving up.
function Show-LaunchDiagnostics {
    $live = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
    if ($live) {
        Info "diag: process $($proc.Id) is still running, $(@(Get-AppWindows $proc.Id).Count) window(s)"
    }
    else {
        Info "diag: process $($proc.Id) has exited (code $($proc.ExitCode))"
    }
    # The runtime is a separate Microsoft install; on a machine without it the
    # webviews never come up and the app itself looks perfectly healthy.
    $keys = @(
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
        'HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
    )
    $runtime = $null
    foreach ($k in $keys) {
        $v = (Get-ItemProperty -Path $k -Name pv -ErrorAction SilentlyContinue).pv
        if ($v) { $runtime = "$v ($k)"; break }
    }
    Info "diag: WebView2 runtime $(if ($runtime) { $runtime } else { 'NOT FOUND in the registry' })"
    Info "diag: webview host processes: $(@(Get-Process msedgewebview2 -ErrorAction SilentlyContinue).Count)"
    # Two states read identically from up here and want opposite fixes: nothing
    # ever listened on the port (the switch did not reach the webview), or
    # something is listening and the request never gets an answer out of it.
    $tcp = New-Object Net.Sockets.TcpClient
    $reachable = $false
    try { $reachable = $tcp.ConnectAsync('127.0.0.1', $Port).Wait(1000) -and $tcp.Connected }
    catch { }
    finally { $tcp.Dispose() }
    Info "diag: port $Port $(if ($reachable) { 'accepts connections' } else { 'is not listening' })"
    try { Info "diag: /json/version -> $(Get-Local '/json/version')" }
    catch { Info "diag: /json/version unreachable ($($_.Exception.Message))" }
    # What the webview hosts were actually launched with. The switch travels to
    # WebView2 through an environment variable, and a machine that drops it on
    # the way — a policy, a shim, an older loader — is indistinguishable from a
    # port that is merely slow to open, unless the command line is read.
    try {
        # Ours only: every other WebView2 app on the machine shows up in this
        # list too, and each is several processes.
        $hostArgs = @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction Stop |
            Select-Object -ExpandProperty CommandLine |
            Where-Object { $_ -like '*com.ztcools.jotter*' })
        $withSwitch = @($hostArgs | Where-Object { $_ -like '*--remote-debugging-port*' })
        Info "diag: $($withSwitch.Count) of $($hostArgs.Count) of our webview host(s) got --remote-debugging-port"
        if ($hostArgs.Count -and -not $withSwitch.Count) {
            # First few switches only: a full WebView2 command line is a paragraph.
            Info "diag: host args start: $((($hostArgs[0] -split ' --' | Select-Object -First 5) -join ' --'))"
        }
    }
    catch { Info "diag: could not read webview host command lines ($($_.Exception.Message))" }
    # Edge policy can forbid remote debugging outright, and does so silently.
    foreach ($k in 'HKLM:\SOFTWARE\Policies\Microsoft\Edge',
        'HKLM:\SOFTWARE\Policies\Microsoft\EdgeWebView',
        'HKCU:\SOFTWARE\Policies\Microsoft\Edge') {
        $p = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue
        if (-not $p) { continue }
        $set = @($p.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } |
            ForEach-Object { "$($_.Name)=$($_.Value)" })
        if ($set.Count) { Info "diag: policy $k -> $($set -join ', ')" }
    }
    if (Test-Path $logPath) {
        $fresh = @(Get-Content $logPath -Encoding UTF8 | Select-Object -Skip $logLinesBefore)
        if ($fresh.Count) { $fresh | Select-Object -Last 20 | ForEach-Object { Info "diag log: $_" } }
        else { Info 'diag: the app logged nothing this run' }
    }
    else { Info "diag: no log file at $logPath" }
}

Check ($targets.Count -ge 2) "both webviews exposed a CDP target ($($targets.Count) found)"
if ($targets.Count -lt 1) { Show-LaunchDiagnostics; exit 1 }
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
# The physical pointer is part of this test's environment whether the harness
# likes it or not, and it interferes in a way that took three runs to pin down:
# CDP's synthetic press carries screenX/screenY = 0, so if a real `pointermove`
# reaches the mascot while that press is in flight, the drag threshold sees a
# jump of a thousand pixels, hands the window to the OS move loop, and the mascot
# teleports. Downstream, "the notebook is beside the mascot" and "the position was
# persisted" then fail on a build where both work. A hovering pointer also keeps
# the mascot's hover animation running under the idle-cost reading and moves the
# corner pixels under the transparency capture.
#
# So park it in the work-area corner farthest from the widget for the duration,
# and put it back at the end. This is the harness taking the desktop it is already
# driving, not a workaround for anything the app does.
$cursorHome = New-Object W32+POINT
if ([W32]::GetCursorPos([ref]$cursorHome)) {
    $ballMidX = $ball.X + $ball.W / 2
    $ballMidY = $ball.Y + $ball.H / 2
    $park = @(
        @{ X = $work.X + 2; Y = $work.Y + 2 }
        @{ X = $work.X + $work.Width - 3; Y = $work.Y + 2 }
        @{ X = $work.X + 2; Y = $work.Y + $work.Height - 3 }
        @{ X = $work.X + $work.Width - 3; Y = $work.Y + $work.Height - 3 }
    ) | Sort-Object { -(($_.X - $ballMidX) * ($_.X - $ballMidX) + ($_.Y - $ballMidY) * ($_.Y - $ballMidY)) } |
        Select-Object -First 1
    [W32]::SetCursorPos($park.X, $park.Y) | Out-Null
    $script:ParkPoint = [pscustomobject]@{ X = $park.X; Y = $park.Y }
    Info "pointer parked at ($($park.X),$($park.Y)), was at ($($cursorHome.X),$($cursorHome.Y))"
}

$gap = [math]::Round(12 * $scale)

$edge = [math]::Round(10 * $scale)

function Test-Anchored($ballWin, $panelWin, $label) {
    $rightOf = Near $panelWin.X ($ballWin.X + $ballWin.W + $gap) 6
    $leftOf  = Near ($panelWin.X + $panelWin.W) ($ballWin.X - $gap) 6
    if (-not ($rightOf -or $leftOf)) {
        # A bare "not beside it" sends the reader back to the app to guess which
        # window is where; the two rectangles say it outright.
        Info ("$label — mascot at ({0},{1}) {2}x{3}, notebook at ({4},{5}) {6}x{7}" -f `
                $ballWin.X, $ballWin.Y, $ballWin.W, $ballWin.H,
            $panelWin.X, $panelWin.Y, $panelWin.W, $panelWin.H)
    }
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

# Focus is not granted the instant a window is shown: Windows hands it to the
# webview a beat later, and a hidden webview refuses it outright, which is why the
# app retries. So poll for the caret instead of sampling once — a single sample
# turns "landed 40 ms later than the last run" into a failed release, and reports
# nothing about where the caret actually went when it genuinely misses.
function Wait-Caret($Ws, [int]$BudgetMs = 1200) {
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        if ((Invoke-Js $Ws $caretOnCaptureLine) -eq 'true') {
            return [pscustomobject]@{ Landed = $true; Ms = [int]$watch.ElapsedMilliseconds }
        }
        if ($watch.ElapsedMilliseconds -ge $BudgetMs) { break }
        Start-Sleep -Milliseconds 60
    }
    $where = Invoke-Js $Ws @'
(() => { const el = document.activeElement;
  return (el ? el.tagName.toLowerCase() + '.' + (el.className || '') : 'nothing') +
    ', window focused=' + document.hasFocus(); })()
'@
    return [pscustomobject]@{ Landed = $false; Ms = [int]$watch.ElapsedMilliseconds; Where = $where }
}

function Test-Caret($Ws, [string]$Label) {
    $caret = Wait-Caret $Ws
    if ($caret.Landed) { Info "caret ready $($caret.Ms) ms after the window appeared" }
    else { Info "caret is on $($caret.Where) after $($caret.Ms) ms" }
    Check $caret.Landed $Label
}

Info "clicking the mascot…"
Send-Click $ballWs ([int]($ball.W / $scale / 2)) ([int]($ball.H / $scale / 2))
Start-Sleep -Milliseconds 900
$wins = Get-AppWindows $proc.Id
$panel = Get-Panel $wins
Check ($panel.Visible) "a click on the mascot opens the notebook"
if ($panel.Visible) {
    Info ("notebook at ({0},{1}) {2}x{3}" -f $panel.X, $panel.Y, $panel.W, $panel.H)
    Test-Anchored (Get-Ball $wins) $panel 'on open'
    # The capture hides the notebook for longer than the app's 180 ms focus-settle
    # window and shows it again without activating it, so whatever is in front of
    # the desktop keeps the focus — and the app, quite correctly, puts the notebook
    # away when focus has gone somewhere that is not ours. That is the harness
    # perturbing the state its next dozen assertions are about: it cost six
    # failures on a build that passes with an idle foreground. Suspend the collapse
    # for the capture, then hand the focus back, so what follows starts from the
    # state a user would be looking at.
    Suspend-AutoCollapse $panelWs $true
    Test-Composites $panel 'notebook'
    Invoke-Cdp $panelWs 'Page.bringToFront' @{} | Out-Null
    Start-Sleep -Milliseconds 250
    Suspend-AutoCollapse $panelWs $false
}

# An open notebook you have to click into before you can type is not the thing
# that was asked for, and no amount of reading the source settles which way this
# goes: the window is created hidden, a hidden webview refuses focus, and the
# document never remounts afterwards. Ask the running app.
Test-Caret $panelWs "the caret is on the capture line when the notebook opens"

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
$ballAtClose = Get-Ball $wins
Info "mascot at ($($ballAtClose.X),$($ballAtClose.Y)) when the notebook closed"

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
Test-Caret $panelWs "the caret is on the capture line again after a reopen"

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

function Measure-TreeCpu([int]$Seconds) {
    $before = Get-TreeCpu $proc.Id
    $clock = [Diagnostics.Stopwatch]::StartNew()
    Start-Sleep -Seconds $Seconds
    $clock.Stop()
    return 100 * ((Get-TreeCpu $proc.Id) - $before).TotalMilliseconds / $clock.Elapsed.TotalMilliseconds
}

# Measured against our own floor rather than against zero, because on a
# transparent always-on-top window the absolute number is not a property of this
# app: whatever else is on the desktop — a video, an IDE, a remote-desktop server
# capturing the screen — forces the compositor to run, and our layer is
# recomposited with it. The same binary read 3.5% on a quiet machine and 34% while
# the author was working on it. What *is* ours is the difference our own animation
# makes, so that is what gets a budget.
$ANIMATION_BUDGET = 12.0
# Above this the floor is dominated by the neighbours and the difference between
# two windows is mostly noise; say so instead of flipping a coin.
$QUIET_FLOOR = 12.0
$CPU_WINDOW = 10
if ($SkipCpu) { Info 'cpu readings skipped (-SkipCpu)' }
else {
    $asShipped = Measure-TreeCpu $CPU_WINDOW
    # Same conditions, minus every animation and transition: the floor this
    # window costs just by existing.
    $still = @'
(() => { const s = document.createElement('style'); s.id = 'probe-still';
  s.textContent = '*,*::before,*::after{animation:none !important;transition:none !important}';
  document.head.appendChild(s); return 1; })()
'@ -replace "`r?`n", ' '
    Invoke-Js $ballWs $still | Out-Null
    $floor = Measure-TreeCpu $CPU_WINDOW
    Invoke-Js $ballWs "document.getElementById('probe-still').remove()" | Out-Null
    $delta = $asShipped - $floor
    Info ("idle cpu {0:N1}% of one core, floor with nothing animating {1:N1}%, ours {2:N1} points" -f `
            $asShipped, $floor, $delta)
    if ($floor -gt $QUIET_FLOOR) {
        Info ("cpu budget not judged: the floor is {0:N1}% — this desktop is too busy for the reading to mean anything" -f $floor)
    }
    else {
        Check ($delta -lt $ANIMATION_BUDGET) `
            "the mascot's own movement is close to free (budget $ANIMATION_BUDGET points)"
    }
}

# ----------------------------------------------------------------------- logs
if (Test-Path $logPath) {
    $fresh = @(Get-Content $logPath -Encoding UTF8 | Select-Object -Skip $logLinesBefore)
    $errors = @($fresh | Where-Object { $_ -match 'ERROR' })
    Check ($errors.Count -eq 0) "no ERROR lines logged during this run"
    $errors | ForEach-Object { Info "  $_" }
    Info "--- tail $logPath ---"
    ($fresh | Where-Object { $_ } | Select-Object -Last 10) | ForEach-Object { Info "  $_" }
}

if ($cursorHome -and ($cursorHome.X -or $cursorHome.Y)) {
    [W32]::SetCursorPos($cursorHome.X, $cursorHome.Y) | Out-Null
}

if ($Stop) { Get-Process Jotter -ErrorAction SilentlyContinue | Stop-Process -Force }
else { Info "widget left running (pass -Stop to close it)" }

Measure-HumanInput
Write-Host ""
$disturbed = ($script:HumanPresses -gt 0) -or ($script:PointerNudges -gt 0)
if ($disturbed) {
    Info ("someone else was using this desktop during the run: $script:HumanPresses real mouse " +
        "press(es), pointer moved off its parking spot $script:PointerNudges time(s)")
    Info ('a real click toggles the notebook and a real drag moves the mascot, so treat the ' +
        'assertions above as inconclusive and re-run on an idle desktop before calling anything a regression')
}
if ($script:Failures -eq 0) { Write-Host "ACCEPTANCE PASS"; exit 0 }
if ($disturbed) { Write-Host "ACCEPTANCE FAIL ($script:Failures assertion(s)) — on a disturbed desktop"; exit 1 }
Write-Host "ACCEPTANCE FAIL ($script:Failures assertion(s))"
exit 1
