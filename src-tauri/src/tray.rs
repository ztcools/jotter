use tauri::menu::{Menu, MenuEvent, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{App, AppHandle, Manager, Runtime};

use crate::error::Result;
use crate::store::Store;
use crate::window::{self, PanelStateEmitter};

const ID_TOGGLE: &str = "toggle";
const ID_NEW_CARD: &str = "new-card";
const ID_QUIT: &str = "quit";

/// Builds the tray icon: left click toggles the widget, right click opens the
/// menu. This is the only way back once the widget has been hidden, so it is
/// created unconditionally at startup.
pub fn build<R: Runtime>(app: &App<R>) -> Result<()> {
    let handle = app.handle();

    let menu = Menu::with_items(
        handle,
        &[
            &MenuItem::with_id(handle, ID_TOGGLE, "显示 / 隐藏", true, None::<&str>)?,
            &MenuItem::with_id(handle, ID_NEW_CARD, "新建卡片", true, None::<&str>)?,
            &PredefinedMenuItem::separator(handle)?,
            &MenuItem::with_id(handle, ID_QUIT, "退出 Jotter", true, None::<&str>)?,
        ],
    )?;

    let mut builder = TrayIconBuilder::with_id("jotter")
        .tooltip("Jotter — 桌面速记")
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(on_menu_event)
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = event
            {
                if let Err(err) = window::toggle_visibility(tray.app_handle()) {
                    log::error!("tray toggle failed: {err}");
                }
            }
        });

    // A dedicated 64px asset rather than the window icon: the tray renders at
    // 16–24px, and downscaling the large app icon there loses the tick. Decoded
    // at compile time, so a missing file is a build error, not a bare tray.
    builder = builder.icon(tauri::include_image!("./icons/tray.png"));

    builder.build(handle)?;
    Ok(())
}

fn on_menu_event<R: Runtime>(app: &AppHandle<R>, event: MenuEvent) {
    let result = match event.id().as_ref() {
        ID_TOGGLE => window::toggle_visibility(app),
        ID_NEW_CARD => new_card_and_show(app),
        ID_QUIT => {
            app.exit(0);
            Ok(())
        }
        _ => Ok(()),
    };
    if let Err(err) = result {
        log::error!("tray menu action failed: {err}");
    }
}

/// Creates a card and pops the panel open on it, so the tray shortcut lands the
/// user straight in a fresh page ready to type into.
fn new_card_and_show<R: Runtime>(app: &AppHandle<R>) -> Result<()> {
    let store = app.state::<Store>();
    store.write(|ws| {
        let accent = ws.next_accent();
        let card = crate::model::Card::new(format!("卡片 {}", ws.cards.len() + 1), accent);
        ws.active_card_id = Some(card.id.clone());
        ws.cards.push(card);
        Ok(())
    })?;

    let win = window::main_window(app)?;
    win.show()?;
    win.set_focus()?;
    window::set_expanded(&win, &store, true)?;
    let _ = win.emit_workspace_changed();
    let _ = win.emit_panel_state(true);
    Ok(())
}
