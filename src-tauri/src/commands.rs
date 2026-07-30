use tauri::{AppHandle, Runtime, State, WebviewWindow};
use tauri_plugin_clipboard_manager::ClipboardExt;

use crate::error::{Error, Result};
use crate::model::{Card, Item, Workspace};
use crate::store::Store;
use crate::window::{self, PanelStateEmitter, Ui};

/// Longest single jotted line we accept. Generous for a note, tight enough that
/// a runaway paste cannot bloat the workspace document.
const MAX_ITEM_LEN: usize = 500;
const MAX_TITLE_LEN: usize = 60;
/// Upper bound on a single export/copy payload, as a cheap abuse guard on the
/// IPC boundary.
const MAX_TEXT_LEN: usize = 1024 * 1024;

fn clean(text: &str, max: usize) -> String {
    let trimmed = text.trim();
    trimmed.chars().take(max).collect()
}

// ------------------------------------------------------------------ workspace

#[tauri::command]
pub fn load_workspace(store: State<'_, Store>) -> Workspace {
    store.snapshot()
}

#[tauri::command]
pub fn create_card(store: State<'_, Store>, title: Option<String>) -> Result<Card> {
    store.write(|ws| {
        let accent = ws.next_accent();
        let name = title
            .as_deref()
            .map(|t| clean(t, MAX_TITLE_LEN))
            .filter(|t| !t.is_empty())
            .unwrap_or_else(|| format!("卡片 {}", ws.cards.len() + 1));
        let card = Card::new(name, accent);
        ws.active_card_id = Some(card.id.clone());
        ws.cards.push(card.clone());
        Ok(card)
    })
}

#[tauri::command]
pub fn rename_card(store: State<'_, Store>, card_id: String, title: String) -> Result<()> {
    let title = clean(&title, MAX_TITLE_LEN);
    if title.is_empty() {
        return Err(Error::Invalid("card title cannot be empty".into()));
    }
    store.write(|ws| {
        let card = ws
            .card_mut(&card_id)
            .ok_or_else(|| Error::not_found("card", &card_id))?;
        card.title = title;
        card.touch();
        Ok(())
    })
}

#[tauri::command]
pub fn delete_card(store: State<'_, Store>, card_id: String) -> Result<Workspace> {
    store.write(|ws| {
        let before = ws.cards.len();
        ws.cards.retain(|c| c.id != card_id);
        if ws.cards.len() == before {
            return Err(Error::not_found("card", &card_id));
        }
        if ws.active_card_id.as_deref() == Some(card_id.as_str()) {
            ws.active_card_id = None; // `normalise` picks the first remaining card
        }
        Ok(())
    })?;
    Ok(store.snapshot())
}

#[tauri::command]
pub fn set_active_card(store: State<'_, Store>, card_id: String) -> Result<()> {
    store.write(|ws| {
        if !ws.cards.iter().any(|c| c.id == card_id) {
            return Err(Error::not_found("card", &card_id));
        }
        ws.active_card_id = Some(card_id);
        Ok(())
    })
}

// ---------------------------------------------------------------------- items

#[tauri::command]
pub fn add_item(store: State<'_, Store>, card_id: String, text: String) -> Result<Item> {
    let text = clean(&text, MAX_ITEM_LEN);
    if text.is_empty() {
        return Err(Error::Invalid("item text cannot be empty".into()));
    }
    store.write(|ws| {
        let card = ws
            .card_mut(&card_id)
            .ok_or_else(|| Error::not_found("card", &card_id))?;
        let item = Item::new(text);
        card.items.push(item.clone());
        card.touch();
        Ok(item)
    })
}

#[tauri::command]
pub fn update_item(
    store: State<'_, Store>,
    card_id: String,
    item_id: String,
    text: Option<String>,
    done: Option<bool>,
) -> Result<()> {
    let text = text.map(|t| clean(&t, MAX_ITEM_LEN));
    store.write(|ws| {
        let card = ws
            .card_mut(&card_id)
            .ok_or_else(|| Error::not_found("card", &card_id))?;
        let item = card
            .item_mut(&item_id)
            .ok_or_else(|| Error::not_found("item", &item_id))?;
        if let Some(t) = text {
            if t.is_empty() {
                return Err(Error::Invalid("item text cannot be empty".into()));
            }
            item.text = t;
        }
        if let Some(d) = done {
            item.done = d;
        }
        card.touch();
        Ok(())
    })
}

#[tauri::command]
pub fn delete_item(store: State<'_, Store>, card_id: String, item_id: String) -> Result<()> {
    store.write(|ws| {
        let card = ws
            .card_mut(&card_id)
            .ok_or_else(|| Error::not_found("card", &card_id))?;
        let before = card.items.len();
        card.items.retain(|i| i.id != item_id);
        if card.items.len() == before {
            return Err(Error::not_found("item", &item_id));
        }
        card.touch();
        Ok(())
    })
}

/// Drops every completed item from a card and reports how many went.
#[tauri::command]
pub fn clear_done(store: State<'_, Store>, card_id: String) -> Result<usize> {
    store.write(|ws| {
        let card = ws
            .card_mut(&card_id)
            .ok_or_else(|| Error::not_found("card", &card_id))?;
        let before = card.items.len();
        card.items.retain(|i| !i.done);
        let removed = before - card.items.len();
        if removed > 0 {
            card.touch();
        }
        Ok(removed)
    })
}

// ------------------------------------------------------------------- transfer

/// Markdown is rendered in the webview (it owns date/locale formatting), so the
/// Rust side only takes delivery of the finished text.
#[tauri::command]
pub fn copy_text<R: Runtime>(app: AppHandle<R>, text: String) -> Result<()> {
    if text.len() > MAX_TEXT_LEN {
        return Err(Error::Invalid("payload too large".into()));
    }
    app.clipboard()
        .write_text(text)
        .map_err(|e| Error::Clipboard(e.to_string()))
}

/// Writes an export to a path the user picked in the native save dialog.
#[tauri::command]
pub fn write_text_file(path: String, text: String) -> Result<()> {
    if text.len() > MAX_TEXT_LEN {
        return Err(Error::Invalid("payload too large".into()));
    }
    if path.trim().is_empty() {
        return Err(Error::Invalid("export path is empty".into()));
    }
    std::fs::write(path, text)?;
    Ok(())
}

// --------------------------------------------------------------------- window

#[tauri::command]
pub fn toggle_panel<R: Runtime>(
    window: WebviewWindow<R>,
    store: State<'_, Store>,
    expanded: bool,
) -> Result<()> {
    window::set_expanded(&window, &store, expanded)
}

/// Pinning suppresses the collapse-on-focus-loss behaviour, for when you need
/// to click into the browser and keep the notes visible.
#[tauri::command]
pub fn set_pinned(store: State<'_, Store>, pinned: bool) -> Result<()> {
    store.write(|ws| {
        ws.pinned = pinned;
        Ok(())
    })
}

/// Held on either side of a native dialog so the focus it steals does not
/// collapse the panel mid-action.
#[tauri::command]
pub fn suspend_auto_collapse(ui: State<'_, Ui>, suspend: bool) {
    ui.suspend_collapse(suspend);
}

#[tauri::command]
pub fn hide_widget<R: Runtime>(window: WebviewWindow<R>, store: State<'_, Store>) -> Result<()> {
    // Collapse first so the widget comes back as a ball, not a stale panel.
    window::set_expanded(&window, &store, false)?;
    window.hide()?;
    let _ = window.emit_panel_state(false);
    Ok(())
}

#[tauri::command]
pub fn quit_app<R: Runtime>(app: AppHandle<R>) {
    app.exit(0);
}
