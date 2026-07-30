//! Window geometry and visibility — the whole widget's physical behaviour.
//!
//! Two windows, not one that resizes. The mascot lives in a small always-on-top
//! window sized exactly to itself; the notebook is a second window placed beside
//! it. The earlier single-window design had to grow from 96px to panel size on
//! every open, which on Windows meant the mascot's window covering a large
//! transparent rectangle (it swallowed clicks meant for whatever was underneath)
//! and a resize that `tao` may clamp on a non-resizable window. Separate windows
//! remove both problems and make "card appears next to the ball" literal.
//!
//! All arithmetic here is in physical pixels, because that is what monitors,
//! `work_area` and the persisted position are in; logical sizes are converted
//! once, at the edges.

use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use parking_lot::Mutex;
use tauri::{
    AppHandle, Emitter, LogicalSize, Manager, Monitor, PhysicalPosition, PhysicalSize, Runtime,
    WebviewUrl, WebviewWindow, WebviewWindowBuilder,
};

use crate::error::{Error, Result};
use crate::model::Point;
use crate::store::Store;

pub const BALL: &str = "ball";
pub const PANEL: &str = "panel";

/// Logical edge of the mascot window. The cat is drawn at 76px inside it; the
/// rest is the margin its shadow, badge and squash-stretch animation need — a
/// transform that overflowed the window would be clipped by the OS, not by CSS.
pub const BALL_SIZE: f64 = 104.0;

/// The panel takes one cell of a 3×3 grid laid over the work area, i.e. exactly
/// one ninth of the usable screen area, which is what was asked for.
const PANEL_GRID: u32 = 3;

/// …but a ninth of a 1024×768 laptop is unusably small and a ninth of a 4K panel
/// is a window, not a sticky note, so the cell is clamped to a sane range.
const PANEL_MIN: (f64, f64) = (460.0, 300.0);
const PANEL_MAX: (f64, f64) = (760.0, 520.0);

/// Logical gap between mascot and panel, and the margin both keep from the edges
/// of the work area.
const GAP: f64 = 12.0;
const EDGE: f64 = 10.0;

/// How long after a focus-loss close a request to open is treated as the tail of
/// that same interaction. See [`Ui::swallow_reopen`].
const REOPEN_GUARD: Duration = Duration::from_millis(320);

/// Session-only window state. Deliberately not part of `Workspace`: the widget
/// always starts with the panel closed, so none of this is user data.
#[derive(Default)]
pub struct Ui {
    panel_open: AtomicBool,
    /// Set while a native dialog is up. Such a dialog steals focus, which would
    /// otherwise read as "user clicked away" and close the panel out from under
    /// the very action that opened the dialog.
    suspend_collapse: AtomicBool,
    /// When the panel was last closed because it lost focus.
    blur_closed_at: Mutex<Option<Instant>>,
}

impl Ui {
    pub fn is_open(&self) -> bool {
        self.panel_open.load(Ordering::Relaxed)
    }

    fn set_open(&self, open: bool) {
        self.panel_open.store(open, Ordering::Relaxed);
    }

    pub fn collapse_suspended(&self) -> bool {
        self.suspend_collapse.load(Ordering::Relaxed)
    }

    pub fn suspend_collapse(&self, suspend: bool) {
        self.suspend_collapse.store(suspend, Ordering::Relaxed);
    }

    pub fn note_blur_close(&self) {
        *self.blur_closed_at.lock() = Some(Instant::now());
    }

    /// True if an open request arrived so soon after a focus-loss close that it
    /// must be the same click.
    ///
    /// Clicking the mascot to dismiss an open panel fires two things: the panel
    /// loses focus (and closes itself), and then the mascot's click handler asks
    /// to toggle. By then the panel is already closed, so a naive toggle would
    /// reopen it and the click would appear to do nothing. Consuming the timestamp
    /// here is what makes one click mean one thing.
    fn swallow_reopen(&self) -> bool {
        let mut at = self.blur_closed_at.lock();
        match *at {
            Some(t) if t.elapsed() < REOPEN_GUARD => {
                *at = None;
                true
            }
            _ => false,
        }
    }
}

pub fn ball_window<R: Runtime>(app: &impl Manager<R>) -> Result<WebviewWindow<R>> {
    app.get_webview_window(BALL)
        .ok_or_else(|| Error::not_found("window", BALL))
}

pub fn panel_window<R: Runtime>(app: &impl Manager<R>) -> Result<WebviewWindow<R>> {
    app.get_webview_window(PANEL)
        .ok_or_else(|| Error::not_found("window", PANEL))
}

/// The monitor the mascot is on, falling back to the primary one — a window that
/// has never been shown reports no current monitor.
fn monitor_of<R: Runtime>(window: &WebviewWindow<R>) -> Result<Option<Monitor>> {
    Ok(match window.current_monitor()? {
        Some(m) => Some(m),
        None => window.primary_monitor()?,
    })
}

/// One ninth of the work area, clamped, in physical pixels.
fn panel_size(monitor: &Monitor) -> PhysicalSize<u32> {
    let scale = monitor.scale_factor();
    let area = monitor.work_area().size;
    let cell = |physical: u32, min: f64, max: f64| {
        let logical = physical as f64 / scale / PANEL_GRID as f64;
        (logical.clamp(min, max) * scale).round() as u32
    };
    PhysicalSize::new(
        cell(area.width, PANEL_MIN.0, PANEL_MAX.0),
        cell(area.height, PANEL_MIN.1, PANEL_MAX.1),
    )
}

/// The size the panel should have on this monitor, resizing it if it no longer
/// matches.
///
/// It was sized when it was created; dragging the mascot to a display with a
/// different scale factor or resolution has to re-cut the cell, or a ninth of one
/// screen ends up being shown on another. The comparison is what keeps the
/// continuous `Moved` events of a drag from issuing a resize per frame.
fn fit_panel<R: Runtime>(monitor: &Monitor, panel: &WebviewWindow<R>) -> Result<PhysicalSize<u32>> {
    let current = panel.outer_size()?;
    let want = panel_size(monitor);
    if want.width.abs_diff(current.width) <= 2 && want.height.abs_diff(current.height) <= 2 {
        return Ok(current);
    }
    panel.set_size(want)?;
    Ok(want)
}

/// Builds the notebook window, hidden, at startup.
///
/// Eagerly rather than on first click: a second webview costs ~20 MB next to a
/// WebView2 runtime already in memory, and creating it lazily would put a
/// visible stall on the first thing the user ever does with the widget.
pub fn create_panel<R: Runtime>(app: &AppHandle<R>) -> Result<WebviewWindow<R>> {
    let ball = ball_window(app)?;
    let size = match monitor_of(&ball)? {
        Some(monitor) => {
            let physical = panel_size(&monitor);
            physical.to_logical::<f64>(monitor.scale_factor())
        }
        None => LogicalSize::new(PANEL_MIN.0, PANEL_MIN.1),
    };

    // A separate document, not a route: the mascot window then never parses or
    // ships the notebook's code, and vice versa.
    let window = WebviewWindowBuilder::new(app, PANEL, WebviewUrl::App("panel.html".into()))
        .title("Jotter")
        .inner_size(size.width, size.height)
        .resizable(false)
        .maximizable(false)
        .minimizable(false)
        .decorations(false)
        .transparent(true)
        .always_on_top(true)
        .skip_taskbar(true)
        .shadow(false)
        .center()
        .visible(false)
        .build()?;
    Ok(window)
}

/// Places the panel beside the mascot: on whichever side has room, vertically
/// centred on it, never outside the work area.
pub fn anchor_panel<R: Runtime>(ball: &WebviewWindow<R>, panel: &WebviewWindow<R>) -> Result<()> {
    let Some(monitor) = monitor_of(ball)? else {
        return Ok(());
    };
    let scale = monitor.scale_factor();
    let gap = (GAP * scale).round() as i32;
    let edge = (EDGE * scale).round() as i32;

    let b_pos = ball.outer_position()?;
    let b_size = ball.outer_size()?;
    let p_size = fit_panel(&monitor, panel)?;
    let area = monitor.work_area();
    let (a_x, a_y) = (area.position.x, area.position.y);
    let (a_r, a_b) = (a_x + area.size.width as i32, a_y + area.size.height as i32);

    let right = b_pos.x + b_size.width as i32 + gap;
    let left = b_pos.x - gap - p_size.width as i32;
    let x = if right + p_size.width as i32 + edge <= a_r {
        right
    } else if left >= a_x + edge {
        left
    } else if b_pos.x - a_x > a_r - (b_pos.x + b_size.width as i32) {
        // Neither side fits — a narrow screen. Take the roomier side and let the
        // clamp below decide the rest; overlapping the mascot beats going
        // off-screen, where the panel would be unreachable.
        a_x + edge
    } else {
        a_r - p_size.width as i32 - edge
    };

    // Centre on the mascot, then pull fully inside the work area.
    let y = b_pos.y + b_size.height as i32 / 2 - p_size.height as i32 / 2;
    let y = y.clamp(
        a_y + edge,
        (a_b - p_size.height as i32 - edge).max(a_y + edge),
    );
    let x = x.clamp(
        a_x + edge,
        (a_r - p_size.width as i32 - edge).max(a_x + edge),
    );

    panel.set_position(PhysicalPosition::new(x, y))?;
    Ok(())
}

/// Opens or closes the notebook and tells both webviews about it.
pub fn set_panel_open<R: Runtime>(app: &AppHandle<R>, open: bool) -> Result<()> {
    let ball = ball_window(app)?;
    let panel = panel_window(app)?;
    let ui = app.state::<Ui>();

    if open {
        if !ball.is_visible()? {
            ball.show()?;
        }
        // Anchor before showing, so the panel never appears at a stale spot and
        // then jumps.
        anchor_panel(&ball, &panel)?;
        panel.show()?;
        panel.set_focus()?;
    } else {
        panel.hide()?;
        // A drag is only in the window's live position until something flushes
        // it; closing the panel is a natural, cheap moment to do that.
        let _ = persist_current_position(&ball, &app.state::<Store>());
    }

    ui.set_open(open);
    let _ = app.emit("panel-state", open);
    Ok(())
}

/// What a click on the mascot does.
pub fn toggle_panel<R: Runtime>(app: &AppHandle<R>) -> Result<()> {
    let ui = app.state::<Ui>();
    let open = !ui.is_open();
    if open && ui.swallow_reopen() {
        return Ok(());
    }
    set_panel_open(app, open)
}

/// Closes the panel because it lost focus, recording that it did so.
pub fn close_on_blur<R: Runtime>(app: &AppHandle<R>) -> Result<()> {
    app.state::<Ui>().note_blur_close();
    set_panel_open(app, false)
}

fn persist_position(store: &Store, pos: PhysicalPosition<i32>) -> Result<()> {
    store.write(|ws| {
        ws.ball_position = Some(Point { x: pos.x, y: pos.y });
        Ok(())
    })
}

/// Records where the mascot currently sits so it reappears there next launch.
///
/// Called when the panel closes, when the widget hides, and on shutdown — never
/// per `Moved` event: a drag emits those continuously and every one of them
/// would mean an fsync'd rewrite of the workspace file.
pub fn persist_current_position<R: Runtime>(ball: &WebviewWindow<R>, store: &Store) -> Result<()> {
    persist_position(store, ball.outer_position()?)
}

/// Keeps a window rectangle inside the work area — the screen minus the taskbar,
/// so the mascot cannot end up behind it.
fn clamp_to_work_area(
    monitor: &Monitor,
    pos: PhysicalPosition<i32>,
    size: PhysicalSize<u32>,
) -> PhysicalPosition<i32> {
    let area = monitor.work_area();
    let max_x = area.position.x + area.size.width as i32 - size.width as i32;
    let max_y = area.position.y + area.size.height as i32 - size.height as i32;
    PhysicalPosition::new(
        pos.x.clamp(area.position.x, max_x.max(area.position.x)),
        pos.y.clamp(area.position.y, max_y.max(area.position.y)),
    )
}

/// Sizes and places the mascot at startup — lower-right on first launch,
/// otherwise wherever it was last left, pulled back on-screen if that monitor is
/// gone.
pub fn place_initial<R: Runtime>(ball: &WebviewWindow<R>, store: &Store) -> Result<()> {
    let scale = ball.scale_factor()?;
    let size = LogicalSize::new(BALL_SIZE, BALL_SIZE);
    ball.set_size(size)?;
    let physical = size.to_physical::<u32>(scale);
    let monitor = monitor_of(ball)?;

    if store.read(|ws| ws.ball_position.is_none()) {
        if let Some(monitor) = &monitor {
            let area = monitor.work_area();
            let margin = (28.0 * scale).round() as i32;
            persist_position(
                store,
                PhysicalPosition::new(
                    area.position.x + area.size.width as i32 - physical.width as i32 - margin,
                    area.position.y + area.size.height as i32 - physical.height as i32 - margin,
                ),
            )?;
        }
    }

    if let (Some(p), Some(monitor)) = (store.read(|ws| ws.ball_position), monitor) {
        let target = PhysicalPosition::new(p.x, p.y);
        ball.set_position(clamp_to_work_area(&monitor, target, physical))?;
    }
    Ok(())
}

/// Brings the widget back into view from the tray or a second launch attempt.
pub fn reveal<R: Runtime>(app: &AppHandle<R>) -> Result<()> {
    let ball = ball_window(app)?;
    ball.show()?;
    Ok(())
}

/// Hides mascot and panel together.
pub fn hide_all<R: Runtime>(app: &AppHandle<R>) -> Result<()> {
    set_panel_open(app, false)?;
    ball_window(app)?.hide()?;
    Ok(())
}

/// Tray / shortcut behaviour: hide when visible, otherwise show with the
/// notebook already open, since that is what the shortcut is for.
pub fn toggle_visibility<R: Runtime>(app: &AppHandle<R>) -> Result<()> {
    if ball_window(app)?.is_visible()? {
        hide_all(app)
    } else {
        set_panel_open(app, true)
    }
}

/// Lets both webviews follow state changes that originate in Rust — tray clicks,
/// the global shortcut, focus loss — rather than from a click in the UI.
pub trait PanelStateEmitter {
    /// Signals that the workspace was mutated outside the webview, so the UI
    /// should reload it.
    fn emit_workspace_changed(&self) -> tauri::Result<()>;
}

impl<R: Runtime> PanelStateEmitter for AppHandle<R> {
    fn emit_workspace_changed(&self) -> tauri::Result<()> {
        self.emit("workspace-changed", ())
    }
}
