//! Jotter — a floating desktop scratchpad for logging UI and web issues.
//!
//! Layering: `model` defines the persisted shape, `store` owns the only path to
//! disk, `window` owns all geometry and visibility, `commands` is the IPC
//! surface, and this module wires them together.

// A release binary built without `--features custom-protocol` gets `cfg(dev)`
// from tauri-build, and at runtime loads `build.devUrl` instead of the assets
// embedded in the exe: it ships, it launches, and it shows the browser's
// connection-error page. That is invisible to `cargo build`, to clippy, and to
// any check that does not run the packaged exe on Windows — so it is caught
// here, at compile time, instead.
#[cfg(all(not(debug_assertions), dev))]
compile_error!(
    "release build has cfg(dev): pass `--features custom-protocol` (see Cargo.toml) or the exe \
     will try to load build.devUrl at runtime instead of its embedded assets"
);

mod commands;
mod error;
mod model;
mod store;
mod tray;
mod window;

use tauri::{Emitter, Manager, RunEvent, WindowEvent};
use tauri_plugin_global_shortcut::{Code, Modifiers, Shortcut, ShortcutState};

use store::Store;
use window::Ui;

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

            let data_dir = app.path().app_data_dir()?;
            let path = data_dir.join(WORKSPACE_FILE);
            let images_dir = data_dir.join("images");
            log::info!("workspace: {}", path.display());
            // Every mutation, from any source, pushes the open-item count to the
            // mascot's badge through this hook.
            let notify = handle.clone();
            app.manage(Store::load(
                path,
                images_dir,
                Box::new(move |open| {
                    let _ = notify.emit("badge", open);
                }),
            )?);
            app.manage(Ui::default());

            let ball = window::ball_window(app)?;
            window::place_initial(&ball, &app.state::<Store>())?;
            let panel = window::create_panel(&handle)?;
            // Logged because it is the one thing about this widget that depends
            // on the machine it runs on, and the first thing worth checking when
            // the panel lands somewhere unexpected.
            log::info!(
                "geometry: ball {:?} at {:?}, panel {:?}, scale {}",
                ball.outer_size()?,
                ball.outer_position()?,
                panel.outer_size()?,
                ball.scale_factor()?,
            );
            ball.show()?;

            // Neither of these is load-bearing: the mascot is already on screen
            // and clickable, and the notebook carries its own hide/quit buttons.
            // A shell that refuses a tray icon, or a Ctrl+Alt+J another app
            // claimed first, should cost that one affordance — not the whole
            // widget. Hiding without a tray is still recoverable: launching the
            // exe again reveals the running instance.
            if let Err(err) = tray::build(app) {
                log::error!("no tray icon, starting without one: {err}");
            }
            if let Err(err) = register_shortcut(&handle) {
                log::error!("no Ctrl+Alt+J hotkey, starting without one: {err}");
            }
            Ok(())
        })
        .on_window_event(|raw, event| {
            let app = raw.app_handle();
            match (raw.label(), event) {
                // The widget has no chrome, but Alt+F4 and OS-level closes still
                // arrive here. Hide instead of exiting — the tray stays the only
                // way out, which is what users expect from a desktop widget.
                (_, WindowEvent::CloseRequested { api, .. }) => {
                    api.prevent_close();
                    if let Err(err) = window::hide_all(app) {
                        log::error!("hide on close request failed: {err}");
                    }
                }
                // The panel is tethered to the mascot: dragging the mascot drags
                // the notebook along with it, rather than leaving it stranded
                // where the mascot used to be.
                (window::BALL, WindowEvent::Moved(_)) => {
                    if !app.state::<Ui>().is_open() {
                        return;
                    }
                    if let (Ok(ball), Ok(panel)) =
                        (window::ball_window(app), window::panel_window(app))
                    {
                        if let Err(err) = window::anchor_panel(&ball, &panel) {
                            log::error!("re-anchor during drag failed: {err}");
                        }
                    }
                }
                // Clicking away puts the notebook away unless it is pinned, so the
                // widget never sits on top of the UI under review.
                //
                // Both windows, because what matters is the app losing focus, not
                // one window losing it: dragging the mascot hands focus from the
                // notebook to the mascot, and if only the notebook's blur were
                // watched, the next click into another app would arrive when the
                // notebook had already been blurred — no event, no collapse.
                //
                // And not decided here: at this instant focus has left but not yet
                // arrived, so a drag of our own is indistinguishable from a click
                // into another app. Every condition is re-read once it settles.
                (window::PANEL | window::BALL, WindowEvent::Focused(false)) => {
                    window::close_on_blur_when_settled(app);
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
            commands::add_item_image,
            commands::get_item_images,
            commands::copy_text,
            commands::write_text_file,
            commands::toggle_panel,
            commands::close_panel,
            commands::set_pinned,
            commands::suspend_auto_collapse,
            commands::hide_widget,
            commands::report_error,
            commands::quit_app,
        ])
        .build(tauri::generate_context!())
        .expect("failed to start Jotter")
        .run(|app, event| {
            // A drag that was never followed by an open/close cycle is only
            // persisted here, so the mascot still reappears where it was left.
            if matches!(event, RunEvent::Exit) {
                if let Ok(ball) = window::ball_window(app) {
                    if let Err(err) = window::persist_current_position(&ball, &app.state::<Store>())
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
