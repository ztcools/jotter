<div align="center">

# Jotter

**A sticky-note widget that floats on your desktop** — while reviewing front-end UI or browsing pages, jot down whatever issues you find on the fly.

A little cat hugging a notebook · one-click copy · one-click export · multi-card switching · global hotkey · single-file exe

[**Download the latest release**](https://github.com/ztcools/jotter/releases/latest) · Windows 10 20H2+ · Free & open source (MIT)

</div>

---

## Installation

Grab one from [Releases](https://github.com/ztcools/jotter/releases/latest) — both files are identical in content:

| File                          | Best for                                                                 |
| ----------------------------- | ------------------------------------------------------------------------ |
| `Jotter_<version>_x64-setup.exe` | If you want a Start-menu shortcut and an uninstall entry. Installs to the current user's directory, **no administrator rights needed** |
| `Jotter-<version>-portable.exe`  | If you just want to double-click and go. Install-free single file at 3.7 MB — works from a USB stick too                       |

Once installed, the little cat appears at the bottom-right of your desktop: click it to open the notebook, type a line and press Enter to record it, and press <kbd>Ctrl</kbd>+<kbd>Alt</kbd>+<kbd>J</kbd> to summon it at any time. Drag it wherever you like — it remembers its position across restarts.

Two things worth knowing up front:

- **WebView2**: included with Windows 10 20H2 and later, no install needed. On older systems, install
  [WebView2 Runtime](https://developer.microsoft.com/microsoft-edge/webview2/) first (official from Microsoft).
- **SmartScreen will block it once**: the published files have no code-signing certificate (personal project, and certificates are paid per year),
  so Windows shows an "Unknown app" prompt — click "More info" → "Run anyway". If you'd rather not, build it yourself:
  `make windows` cross-compiles inside a container, and the output matches the portable build.

To uninstall, use the system's "Apps & Features" (for the portable version, just delete the file). Your notes are not removed — they live in
`%APPDATA%\com.ztcools.jotter\workspace.json`.

## What it solves

While looking at a page you'll spot seven or eight issues in a row. Switch windows to open Notepad, open an issue, open a Feishu doc — and your attention is gone.

Jotter is a little cat holding a notebook on your desktop: click it and a notebook unfolds beside it, type a line and press Enter to record an item; when you're done, click "Copy" and the whole card becomes a Markdown todo list in your clipboard, ready to paste straight into an issue or a chat window.

## Features

|                   |                                                                                                                                                                                      |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Cat widget**    | A hand-drawn anime-style cat, still most of the time; on appear / hover / opening & closing the notebook / a new entry landing, it flicks an ear, blinks, and swishes its tail (plus a spontaneous idle motion every 19–30 seconds); always-on-top, draggable, position remembered across restarts; a badge shows the number of unresolved items |
| **Notebook panel**| A separate window, docked next to the cat, sized to one-ninth of the workspace (1/3 on each axis); soft rounded corners + light/dark theme that follows the system automatically                                                                                            |
| **Multiple cards**| One card per page / per workflow; a tab bar switches between them with one click, double-click to rename                                                                                                                          |
| **Entries**       | Enter to add, click the circle to mark resolved, click the text to fix a typo, hover to delete                                                                                                                                   |
| **One-click copy**| Outputs a GitHub-style task list `- [ ] / - [x]` that you can paste directly into an issue                                                                                                                           |
| **One-click export**| A native save dialog writes `.md` / `.txt`; hold <kbd>Shift</kbd> to export all cards                                                                                                                  |
| **Follows movement**| Drag the cat and the notebook follows in real time; when you get near a screen edge it re-docks to the other side, and never escapes the workspace                                                                                                                 |
| **Collapse strategy**| Auto-collapses when you click outside the panel; pin it when you need to write while looking at something else                                                                                                                               |
| **Tray + hotkey** | <kbd>Ctrl</kbd>+<kbd>Alt</kbd>+<kbd>J</kbd> summons/hides it at any time; the tray can create a new card directly                                                                                                        |

### Keyboard shortcuts

| Key                                                                             | Action                                     |
| -------------------------------------------------------------------------------- | ------------------------------------------ |
| <kbd>Ctrl</kbd>+<kbd>Alt</kbd>+<kbd>J</kbd>                                      | Globally summon / hide the widget          |
| <kbd>Enter</kbd>                                                                 | Commit the current input; the input stays focused so you can keep typing |
| <kbd>Esc</kbd>                                                                   | Collapse the notebook                                 |
| <kbd>Ctrl</kbd>+<kbd>N</kbd>                                                     | New card                                 |
| <kbd>Ctrl</kbd>+<kbd>Tab</kbd> / <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>Tab</kbd> | Switch to the next / previous card                    |

## Tech stack

**Tauri 2 (Rust) + Svelte 5 + TypeScript**

| Decision                 | Rationale                                                                                                                                                                                                                                                            |
| ----------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Tauri over Electron     | Reuses the system WebView2, so the artifact is a single exe (on the order of a few MB) and memory usage is about a tenth of Electron's. The widget is a resident process, so residency cost is the only cost that matters.                                                                                                                               |
| Two windows instead of one scaling window    | The cat and the notebook each get their own window. A single window would have to grow from 104px to panel size when expanded, so the cat window would be stuck carrying a big transparent rectangle that swallows every click meant for the apps beneath it; and size changes on a non-resizable window get clamped by `tao`. Splitting into two windows solves both problems at once, and "the card appears next to the ball" becomes literally true. |
| Hand-drawn SVG instead of downloaded assets   | The cat has to react to state (squash on press, tick when opening the notebook), which bitmaps or third-party Lottie can't do — and they'd also carry license and size baggage. The whole cat is one inline SVG + CSS keyframes, in the same document as the styles that drive it — that's "the cat noticed you", not "a swapped-in sprite sheet".                                                  |
| Rust main process             | Window geometry, tray, global hotkey, and persistence all live on the native side; the UI thread only handles rendering.                                                                                                                                                                                                 |
| Svelte 5 over React/Vue | Resolves the framework at compile time, leaving almost no runtime. The two windows total 80 KB JS + 16 KB CSS, of which the cat window accounts for only 5 KB.                                                                                                                                                                |
| WebView for the UI           | Soft rounded corners, frosted-glass texture, and transition animations are cheapest to express in CSS, and that's exactly what the requirements emphasize.                                                                                                                                                                                             |
| Single JSON document + atomic writes   | The data volume is on the KB scale, so an embedded database's C dependencies, migrations, and connection management aren't worth it. Write to a temp file → `fsync` → `rename` over the target, so a power loss only drops the current change, never leaves half a file. All reads and writes funnel through [`store.rs`](src-tauri/src/store.rs); swapping the backend means changing just that one file.                              |

### Residency cost (measured, not estimated)

The widget runs from boot to shutdown, so "how much it costs when nobody touches it" is the only metric that matters. All the numbers below come from
measuring a real exe running on Windows (16 logical cores, DPI 150%, notebook collapsed, no interaction):

|                  |                                                             |
| ---------------- | ----------------------------------------------------------- |
| exe size         | 3.75 MB (install-free single file)                                     |
| Cold start to visible window | 566–797 ms                                                  |
| Idle CPU         | **3.5%** of one core (30-second window); includes the spontaneous idle motion                    |
| Process-tree memory       | Working set 432 MB / private 219 MB, after 30 seconds 441 / 205 MB (does not grow) |

Two things must be said plainly, or these numbers will be misread:

- **The bulk of the memory isn't our code.** Jotter.exe itself is 28 MB working set / 7 MB private; the rest is the
  7 msedgewebview2 processes that WebView2 spins up for the two webviews — that's the base price of the "render UI with the system browser" choice.
  What it saves over Electron is disk and distribution (Electron bundles its own entire Chromium), not resident memory.
  To get a smaller resident footprint you'd have to give up CSS-based UI and switch to GPU direct rendering.
- **Idle CPU used to be 46%, and that was a real bug, now fixed.** The cause was the cat continuously breathing / blinking / swishing its tail.
  On a **transparent, always-on-top** window, the cost of animation isn't in what you draw, but in the fact that the window's layer has to be recomposited into the desktop every frame:
  measured — whether you animate one part or eight, it's 25–47% of one core (verified by pausing each one individually; no single animation is solely responsible),
  `drop-shadow` is about 5–7 points, inner SVG vs. a compositable root node is about 13 points, and fully static is 1%.
  In other words, there's no such thing as a "cheap resident animation" here — only "short animations". Now every keyframes has a finite iteration count
  and returns to a static pose, triggered by events or a jittered idle timer; hidden windows and `prefers-reduced-motion` never play them.
  The acceptance script therefore permanently carries two assertions: no document may contain an infinitely-iterating animation, and the process-tree idle CPU must stay below 15%.

### Assets & originality

The artifact contains no third-party artwork and no embedded fonts:

- The **cat** is a hand-written inline SVG ([`Cat.svelte`](ui/src/components/Cat.svelte), about 10 KB including comments and animation),
  each path drawn by hand — not exported, not downloaded, not an AI bitmap.
- The **icon / logo** (a rounded note with a checkmark and two lines of text) was never "authored" as binary:
  [`scripts/gen-icons.mjs`](scripts/gen-icons.mjs) holds a single vector definition (a signed distance field of the rounded rectangle and capsule),
  and the bundled PNG / DIB-ICO encoders render all sizes from it. `make icons` can byte-for-byte reproduce the 6 icon files in the repo, and CI verifies that.
- **Fonts** all use the system font stack (Segoe UI / Microsoft YaHei / PingFang…), nothing is downloaded or bundled.
- One honest disclosure: geometric glyphs like plus / x / check / dots / trash in `Icon.svelte`
  are the conventional 2px-stroke drawings on a 24×24 grid, so they're bound to look similar to what Feather, lucide, and other MIT/ISC icon sets produce —
  they were each written independently, but there's only so much room to claim "originality" for such generic symbols.
- Code dependencies (Tauri, Svelte, 515 Rust crates) are each under their own open-source license (MIT / Apache-2.0, etc.),
  and this repo's MIT covers only this repo's own code and artwork.

### Architecture

```
src-tauri/src/
├── model.rs      Persistent data structures + invariants (at least one card, activeId always valid)
├── store.rs      The only entry/exit point for disk: atomic writes, isolating corrupt files rather than discarding them
├── window.rs     All geometry and visibility for the two windows: docking, following, boundary clamping, position memory
├── commands.rs   The IPC boundary: input sanitization + length limits
├── tray.rs       Tray icon and menu
└── lib.rs        Assembly: plugins, events, command registration

ui/
├── index.html + src/ball.ts    The cat window
├── panel.html + src/panel.ts   The notebook window
└── src/
    ├── BallApp.svelte      Drag/click detection, badge; doesn't import the workspace store, only holds a single number
    ├── PanelApp.svelte     The notebook shell: spiral binding + paper surface + page header
    ├── components/Cat.svelte  The cat itself (inline SVG + CSS animations)
    ├── lib/store.svelte.ts   UI state (Rust is the source of truth; this is the reactive mirror)
    ├── lib/ipc.ts            Typed command wrappers; the rest of the code never calls invoke directly
    ├── lib/errors.ts         Uncaught front-end exceptions are reported back to Rust and written to Jotter.log
    └── lib/markdown.ts       Rendering for copy/export (lives on the front end because it needs the local timezone and locale)
```

A few details that don't stand out but make the feel right:

- **Exactly one authority for window visibility** — the front end never keeps its own "is the panel open" boolean, it only calls `toggle_panel`; the open/close state lives in Rust and is broadcast via the `panel-state` event. If both windows kept their own copy, they'd drift out of sync sooner or later.
- **The cat doesn't drift** — the notebook docks to the cat, not the other way around; when the notebook gets clamped by a workspace boundary, the cat stays where it is. Otherwise, opening and closing repeatedly in a corner would make the cat "crawl" toward the center of the screen.
- **Drag and click don't conflict** — the pointer has to move more than 4px before it's handed to the system to start dragging; otherwise it counts as a click. Calling `startDragging` directly would let the system drag loop swallow every click.
- **Blur-collapse doesn't bounce back** — clicking the cat collapses the panel on blur, but the very next click asks to open it again. A 320ms guard window between the window event and the IPC call swallows that reopen.
- **The panel doesn't vanish during export** — the native save dialog steals focus, and losing focus would normally trigger auto-collapse. The export is wrapped in `suspend_auto_collapse`.
- **Typeable as soon as it opens** — the notebook window is hidden rather than destroyed, so the one-time `focus()` at mount lands on a webview that isn't focusable yet and gets rejected, and it's never mounted a second time. The cursor is instead recovered via the `panel-state` open event, with one extra attempt when the window regains focus; it doesn't steal focus while you're editing a typo.
- **Data is never silently lost** — when JSON parsing fails, the original file is renamed to `workspace.corrupt-<timestamp>` and preserved instead of being overwritten.

## Building

### Containerized cross-compilation (recommended, no Windows machine needed)

```bash
make windows          # → dist-win/Jotter.exe
```

`cargo-xwin` pulls the MSVC CRT and Windows SDK headers inside the container and drives clang-cl / lld-link to produce an MSVC-targeted exe. The output is an **install-free single file** — copy it to Windows and double-click. The WebView2 runtime ships with Windows 10 20H2 and later.

### Native build on Windows (additionally produces an NSIS installer)

You need a Rust toolchain and MSVC Build Tools:

```powershell
pnpm install
pnpm tauri build       # → src-tauri/target/release/{jotter.exe, bundle/nsis/*.exe}
```

### Development

```bash
make check            # front-end type check
make lint             # cargo fmt --check + clippy -D warnings (needs local Rust)
make lint-docker      # same, but run in the build container — no local Rust needed
make fmt-docker       # format the Rust sources inside the container
make icons            # regenerate all icons from scripts/gen-icons.mjs
make dev              # hot reload (needs a local WebView and Rust toolchain)
```

> `make dev` inside WSL requires GTK dependencies like `webkit2gtk-4.1`; you don't need to install them if you're only shipping for Windows —
> just use `make windows` + `make lint-docker`, since both share the same image.

When changing CSS you don't need to touch the Rust side: `ui/preview.html` runs the real components against a stubbed IPC layer. Open
`http://localhost:1420/preview.html?state=panel` directly in a browser (`state=ball` to see the cat); the window size matches what Rust uses,
so you can screenshot and compare directly.

### Acceptance

An artifact where `cargo build`, clippy, and svelte-check all pass can still be a window sitting open on
`ERR_CONNECTION_REFUSED` — none of them actually run the exe.
[`scripts/acceptance.ps1`](scripts/acceptance.ps1) runs it and independently verifies:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\acceptance.ps1 -Exe .\Jotter.exe
```

| Method                                | Assertion                                                                                                                                 |
| ----------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| CDP (`--remote-debugging-port`)    | Both webviews load from the embedded bundle (`tauri.localhost`), both mount content, and neither has front-end exceptions                                                        |
| Win32 `EnumWindows` + DPI awareness      | The cat window is 104 logical pixels, the notebook is 1/3 of the workspace on each axis (1/9 of the area), always-on-top, transparent, and within bounds                                                        |
| CDP `Input.dispatchMouseEvent`      | A real pointer down/up (not `.click()`, which would bypass click and drag detection) → the notebook opens beside it, the cursor lands in the input line (asserted once for first open and once for reopen), and a further click collapses it |
| `SetWindowPos` + workspace.json     | Move the cat and the notebook follows; the new position is persisted                                                                                                       |
| Cross-window events                          | Add an entry in the notebook and the cat's badge updates accordingly (store hook → event → the other webview's DOM), then it's cleaned up automatically                                          |
| Screenshot pixel diff                      | Cover and reveal the same rectangle to compare: a transparent always-on-top window still looks "healthy" to every API even when it draws nothing                                                               |
| `getAnimations()` + process-tree CPU time | Neither document has an infinitely-iterating animation, and idle CPU stays under budget — the 46% bug above passes every other assertion                                             |

Idle CPU isn't judged on its absolute value, but as a difference against the floor of "the same process with all animations stopped" — the absolute value measures how busy that machine is;
the difference is the actual cost of the cat moving itself.

**This whole table only runs fully on a desktop**, so run a complete acceptance pass on your own machine before releasing. CI runs
`-SkipPixel -SkipCpu -NoDevtools`, and it can honestly answer less than it looks like: runners have no desktop to capture; on a shared two-core box,
a "single-core percentage" measures your neighbor; and GitHub `windows-latest` jobs run as administrator, where the WebView2
loader drops `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS` entirely — the browser process starts with only the app's own
`AdditionalBrowserArguments`, so the debug port never has anyone listening (verified on a runner: no Edge
policy involved, yet the same CI artifact on a normal desktop still honors that variable). Baking the debug port into the shipped config in exchange for a green CI
is not a trade worth making. So CI only asserts what the runner can honestly answer: the exe starts, both windows exist with correct geometry,
always-on-top, the notebook is hidden by default, and there are no ERRORs in the log; when it finishes it prints out every check it **couldn't**
assert by name, so a green light can't be misread as "everything was tested".

For local runs, keep the desktop idle: it's literally driving the cat in front of you — a real click will collapse the notebook, a real drag will
move the cat away, and every open/close assertion after that will flip. And you don't even need to press down for real: CDP-synthesized presses carry
`screenX/screenY = 0`, so merely **moving** the real pointer at all makes the drag threshold see a jump of a thousand pixels.

The script therefore parks the pointer in the corner farthest from the widget and fences it in a 3×3 box with `ClipCursor` (the fence
expires the moment the foreground window changes, so it's re-fenced before every sample); it samples once before and after each synthesized action, and if the pointer was moved,
it reports it by name — "pointer at (1785,1025), not at the dock, happened: before dragging the cat while the notebook was open". So "this assertion wasn't measured properly"
has evidence, and the assertion that fails between two clean samples is the real regression. It still tallies how many times the run was touched; when it finishes
the pointer is returned to you (an abnormal exit unfences it too).

Icons aren't binary assets: `scripts/gen-icons.mjs` uses a signed distance field to render the vector definition into the full set of PNGs and DIB-format ICOs, so changing one definition regenerates every size, and CI also verifies that the icons match the generator.

### Release

A single `v*` tag is enough:

```bash
git tag v0.1.0 && git push origin v0.1.0
```

[CI](.github/workflows/ci.yml) builds the installer and the install-free exe on a Windows runner,
**first runs the part of the acceptance suite the runner can run** (`-NoDevtools`, see above), and only then uses `gh release create`
to attach both files to that tag's Release — so there's never an artifact that was "shipped but never launched";
the checks that need a real pointer and real pixels are covered by the full local acceptance run before tagging. The version number is read from `package.json` / `tauri.conf.json` /
`Cargo.toml`, and all three must agree.

## Data storage

```
%APPDATA%\com.ztcools.jotter\workspace.json
```

Plain-text JSON — you can back it up, diff it, or edit it by hand. Fields are documented in [`model.rs`](src-tauri/src/model.rs).

Logs (including uncaught exceptions reported from the front end):

```
%LOCALAPPDATA%\com.ztcools.jotter\logs\Jotter.log
```

## License

MIT
