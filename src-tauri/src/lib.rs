//! Jotter — a floating desktop scratchpad for logging UI and web issues.
//!
//! Layering: `model` defines the persisted shape, `store` owns the only path to
//! disk, `window` owns all geometry and visibility, `commands` is the IPC
//! surface, and this module wires them together.

mod commands;
mod error;
mod model;
mod store;
mod tray;
mod window;

use tauri::{Manager, RunEvent, WindowEvent};
use tauri_plugin_global_shortcut::{Code, Modifiers, Shortcut, ShortcutState};

use store::Store;
use window::{PanelStateEmitter, Ui};

/// Error type Tauri's `setup` hook expects; also used by the helpers it calls.
type BoxError = Box<dyn std::error::Error>;

/// Filename of the workspace document inside the OS app-data directory.
const WORKSPACE_FILE: &str = "workspace.json";

/// Summon/dismiss shortcut. Ctrl+Alt+J is unclaimed by Windows itself and by
/// the common browsers and editors this widget sits next to.
fn summon_shortcut() -> Shortcut {
    Shortcut::new(Some(Modifiers::CONTROL | Modifiers::ALT), Code::KeyJ)
}

pub fn run() {
    tauri::Builder::default()
        // Must be registered first so a second launch is folded into the
        // running instance before any other setup happens.
        .plugin(tauri_plugin_single_instance::init(|app, _argv, _cwd| {
            if let Err(err) = window::reveal(app) {
                log::error!("failed to reveal existing instance: {err}");
            }
        }))
        .plugin(
            tauri_plugin_log::Builder::new()
                .level(log::LevelFilter::Info)
                .build(),
        )
        .plugin(tauri_plugin_clipboard_manager::init())
        .plugin(tauri_plugin_dialog::init())
        .setup(|app| {
            let handle = app.handle().clone();

            let path = app.path().app_data_dir()?.join(WORKSPACE_FILE);
            log::info!("workspace: {}", path.display());
            app.manage(Store::load(path)?);
            app.manage(Ui::default());

            let win = window::main_window(app)?;
            window::place_initial(&win, &app.state::<Store>())?;
            win.show()?;

            tray::build(app)?;
            register_shortcut(&handle)?;
            Ok(())
        })
        .on_window_event(|raw, event| {
            // `on_window_event` hands over a `Window`; everything downstream is
            // expressed against the webview window, so resolve it once here.
            let Ok(win) = window::main_window(raw.app_handle()) else {
                return;
            };
            match event {
                // The widget has no chrome, but Alt+F4 and OS-level closes still
                // arrive here. Hide instead of exiting — the tray stays the only
                // way out, which is what users expect from a desktop widget.
                WindowEvent::CloseRequested { api, .. } => {
                    api.prevent_close();
                    let _ = win.hide();
                    let _ = win.emit_panel_state(false);
                }
                // Clicking away collapses the panel back to a ball unless
                // pinned, so the widget never covers the UI under review.
                WindowEvent::Focused(false) => {
                    let store = win.state::<Store>();
                    let ui = win.state::<Ui>();
                    if store.read(|ws| ws.pinned) || ui.collapse_suspended() || !ui.is_expanded() {
                        return;
                    }
                    if let Err(err) = window::set_expanded(&win, &store, false) {
                        log::error!("collapse on blur failed: {err}");
                    }
                    let _ = win.emit_panel_state(false);
                }
                _ => {}
            }
        })
        .invoke_handler(tauri::generate_handler![
            commands::load_workspace,
            commands::create_card,
            commands::rename_card,
            commands::delete_card,
            commands::set_active_card,
            commands::add_item,
            commands::update_item,
            commands::delete_item,
            commands::clear_done,
            commands::copy_text,
            commands::write_text_file,
            commands::toggle_panel,
            commands::set_pinned,
            commands::suspend_auto_collapse,
            commands::hide_widget,
            commands::quit_app,
        ])
        .build(tauri::generate_context!())
        .expect("failed to start Jotter")
        .run(|app, event| {
            // A drag that was never followed by an open/close cycle is only
            // persisted here, so the ball still reappears where it was left.
            if matches!(event, RunEvent::Exit) {
                if let Ok(win) = window::main_window(app) {
                    if let Err(err) = window::persist_current_position(&win, &app.state::<Store>())
                    {
                        log::error!("failed to persist widget position: {err}");
                    }
                }
            }
        });
}

fn register_shortcut(app: &tauri::AppHandle) -> std::result::Result<(), BoxError> {
    let shortcut = summon_shortcut();
    app.plugin(
        tauri_plugin_global_shortcut::Builder::new()
            .with_shortcut(shortcut)?
            .with_handler(move |app, triggered, event| {
                if event.state() != ShortcutState::Pressed || triggered != &shortcut {
                    return;
                }
                if let Err(err) = window::toggle_visibility(app) {
                    log::error!("shortcut toggle failed: {err}");
                }
            })
            .build(),
    )?;
    Ok(())
}
