use std::sync::atomic::{AtomicBool, Ordering};

use parking_lot::Mutex;
use tauri::{LogicalSize, Manager, PhysicalPosition, PhysicalSize, Runtime, WebviewWindow};

use crate::error::{Error, Result};
use crate::model::Point;
use crate::store::Store;

pub const MAIN_WINDOW: &str = "main";

/// Logical size of the collapsed floating ball, including the transparent
/// margin the CSS drop shadow needs.
pub const BALL: (f64, f64) = (72.0, 72.0);

/// Logical size of the expanded notebook panel, same margin included.
pub const PANEL: (f64, f64) = (368.0, 476.0);

/// Reserved strip along the bottom of the screen so an expanded panel does not
/// end up under the taskbar. `current_monitor` reports the whole monitor rather
/// than the work area, so this is the pragmatic substitute.
const BOTTOM_INSET: f64 = 56.0;

/// Session-only window state. Deliberately not part of `Workspace`: the widget
/// always starts collapsed, so none of this is user data worth persisting.
#[derive(Default)]
pub struct Ui {
    expanded: AtomicBool,
    /// Where the panel was placed when it was opened. Comparing this against the
    /// panel's position on close tells us whether the user dragged it, which
    /// decides where the ball goes back to.
    panel_origin: Mutex<Option<PhysicalPosition<i32>>>,
    /// Set while a native dialog is up. Such a dialog steals focus, which would
    /// otherwise be read as "user clicked away" and collapse the panel out from
    /// under the very action that opened the dialog.
    suspend_collapse: AtomicBool,
}

impl Ui {
    pub fn is_expanded(&self) -> bool {
        self.expanded.load(Ordering::Relaxed)
    }

    pub fn collapse_suspended(&self) -> bool {
        self.suspend_collapse.load(Ordering::Relaxed)
    }

    pub fn suspend_collapse(&self, suspend: bool) {
        self.suspend_collapse.store(suspend, Ordering::Relaxed);
    }
}

pub fn main_window<R: Runtime>(app: &impl Manager<R>) -> Result<WebviewWindow<R>> {
    app.get_webview_window(MAIN_WINDOW)
        .ok_or_else(|| Error::not_found("window", MAIN_WINDOW))
}

/// Expands to the notebook panel or collapses back to the ball.
///
/// Resizing keeps the window's top-left fixed, so the panel grows out of the
/// ball's corner and shrinks back into it. Two details make that feel right:
/// an expanded panel is pulled back on-screen if it would overflow, and
/// collapsing restores the ball's original spot rather than the clamped one —
/// otherwise the ball would creep towards the top-left every time you opened it
/// near a screen edge.
pub fn set_expanded<R: Runtime>(
    window: &WebviewWindow<R>,
    store: &Store,
    expanded: bool,
) -> Result<()> {
    let ui = window.state::<Ui>();
    let scale = window.scale_factor()?;
    let current = window.outer_position()?;

    if expanded {
        if !ui.is_expanded() {
            // The current top-left is the ball's home; the panel grows from it.
            persist_position(store, current)?;
        }
        let size = LogicalSize::new(PANEL.0, PANEL.1);
        window.set_size(size)?;
        let placed = clamp_to_screen(window, current, size.to_physical(scale), scale)?;
        window.set_position(placed)?;
        *ui.panel_origin.lock() = Some(placed);
        ui.expanded.store(true, Ordering::Relaxed);
    } else {
        let dragged = ui.is_expanded() && *ui.panel_origin.lock() != Some(current);
        let size = LogicalSize::new(BALL.0, BALL.1);
        window.set_size(size)?;

        if dragged {
            // Follow the panel: the user put it there on purpose.
            persist_position(store, current)?;
        } else if let Some(home) = store.read(|ws| ws.ball_position) {
            let target = PhysicalPosition::new(home.x, home.y);
            window.set_position(clamp_to_screen(
                window,
                target,
                size.to_physical(scale),
                scale,
            )?)?;
        }
        *ui.panel_origin.lock() = None;
        ui.expanded.store(false, Ordering::Relaxed);
    }
    Ok(())
}

fn persist_position(store: &Store, pos: PhysicalPosition<i32>) -> Result<()> {
    store.write(|ws| {
        ws.ball_position = Some(Point { x: pos.x, y: pos.y });
        Ok(())
    })
}

/// Records wherever the widget currently sits, so it reappears there next
/// launch. Called on shutdown, when a drag may not have been persisted yet.
pub fn persist_current_position<R: Runtime>(
    window: &WebviewWindow<R>,
    store: &Store,
) -> Result<()> {
    if window.state::<Ui>().is_expanded() {
        return Ok(()); // the panel's origin is not the ball's
    }
    persist_position(store, window.outer_position()?)
}

/// Keeps a window rectangle fully inside the monitor it currently sits on.
fn clamp_to_screen<R: Runtime>(
    window: &WebviewWindow<R>,
    pos: PhysicalPosition<i32>,
    size: PhysicalSize<u32>,
    scale: f64,
) -> Result<PhysicalPosition<i32>> {
    let Some(monitor) = window.current_monitor()? else {
        return Ok(pos);
    };
    let m_pos = *monitor.position();
    let m_size = *monitor.size();
    let inset = (BOTTOM_INSET * scale).round() as i32;

    let max_x = m_pos.x + m_size.width as i32 - size.width as i32;
    let max_y = m_pos.y + m_size.height as i32 - size.height as i32 - inset;

    Ok(PhysicalPosition::new(
        pos.x.clamp(m_pos.x, max_x.max(m_pos.x)),
        pos.y.clamp(m_pos.y, max_y.max(m_pos.y)),
    ))
}

/// Sizes and places the ball at startup — lower-right corner on first launch,
/// otherwise wherever it was last left.
pub fn place_initial<R: Runtime>(window: &WebviewWindow<R>, store: &Store) -> Result<()> {
    let scale = window.scale_factor()?;
    let size = LogicalSize::new(BALL.0, BALL.1);
    window.set_size(size)?;
    let physical = size.to_physical::<u32>(scale);

    if store.read(|ws| ws.ball_position.is_none()) {
        if let Some(monitor) = window.current_monitor()? {
            let m_pos = *monitor.position();
            let m_size = *monitor.size();
            let margin = (24.0 * scale).round() as i32;
            persist_position(
                store,
                PhysicalPosition::new(
                    m_pos.x + m_size.width as i32 - physical.width as i32 - margin,
                    m_pos.y + m_size.height as i32
                        - physical.height as i32
                        - margin
                        - (BOTTOM_INSET * scale).round() as i32,
                ),
            )?;
        }
    }

    if let Some(p) = store.read(|ws| ws.ball_position) {
        let target = PhysicalPosition::new(p.x, p.y);
        window.set_position(clamp_to_screen(window, target, physical, scale)?)?;
    }
    Ok(())
}

/// Brings the widget back into view from the tray or another launch attempt.
pub fn reveal<R: Runtime>(app: &impl Manager<R>) -> Result<()> {
    let window = main_window(app)?;
    window.show()?;
    window.set_focus()?;
    Ok(())
}

/// Tray / shortcut behaviour: hide when visible, otherwise show and open up.
pub fn toggle_visibility<R: Runtime>(app: &impl Manager<R>) -> Result<()> {
    let window = main_window(app)?;
    let store = app.state::<Store>();
    if window.is_visible()? {
        set_expanded(&window, &store, false)?;
        window.hide()?;
        let _ = window.emit_panel_state(false);
    } else {
        window.show()?;
        window.set_focus()?;
        set_expanded(&window, &store, true)?;
        let _ = window.emit_panel_state(true);
    }
    Ok(())
}

/// Lets the webview follow state changes that originate in Rust — tray clicks,
/// the global shortcut, focus loss — rather than from a click in the UI.
pub trait PanelStateEmitter {
    fn emit_panel_state(&self, expanded: bool) -> tauri::Result<()>;
    /// Signals that the workspace was mutated outside the webview, so the UI
    /// should reload it.
    fn emit_workspace_changed(&self) -> tauri::Result<()>;
}

impl<R: Runtime> PanelStateEmitter for WebviewWindow<R> {
    fn emit_panel_state(&self, expanded: bool) -> tauri::Result<()> {
        use tauri::Emitter;
        self.emit("panel-state", expanded)
    }

    fn emit_workspace_changed(&self) -> tauri::Result<()> {
        use tauri::Emitter;
        self.emit("workspace-changed", ())
    }
}
