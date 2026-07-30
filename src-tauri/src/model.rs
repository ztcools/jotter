use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

/// Bumped whenever the on-disk shape changes incompatibly. `Store` uses it to
/// decide whether a file needs migrating before it is handed to the app.
pub const SCHEMA_VERSION: u32 = 1;

/// Number of accent hues the UI cycles through when new cards are created.
pub const ACCENT_COUNT: u8 = 6;

pub fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or_default()
}

fn new_id() -> String {
    uuid::Uuid::new_v4().simple().to_string()
}

/// A single jotted-down issue. Deliberately one line of text — this app is for
/// capture, not for prose.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Item {
    pub id: String,
    pub text: String,
    #[serde(default)]
    pub done: bool,
    pub created_at: i64,
}

impl Item {
    pub fn new(text: String) -> Self {
        Self {
            id: new_id(),
            text,
            done: false,
            created_at: now_ms(),
        }
    }
}

/// A page of the notebook: one titled list of issues, usually scoped to a
/// screen or a flow under review.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Card {
    pub id: String,
    pub title: String,
    #[serde(default)]
    pub items: Vec<Item>,
    #[serde(default)]
    pub accent: u8,
    pub created_at: i64,
    pub updated_at: i64,
}

impl Card {
    pub fn new(title: String, accent: u8) -> Self {
        let ts = now_ms();
        Self {
            id: new_id(),
            title,
            items: Vec::new(),
            accent: accent % ACCENT_COUNT,
            created_at: ts,
            updated_at: ts,
        }
    }

    pub fn touch(&mut self) {
        self.updated_at = now_ms();
    }

    pub fn item_mut(&mut self, item_id: &str) -> Option<&mut Item> {
        self.items.iter_mut().find(|i| i.id == item_id)
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct Point {
    pub x: i32,
    pub y: i32,
}

/// Everything the app persists, in one document. Small enough (kilobytes, even
/// after months of use) that rewriting it atomically on every mutation is
/// cheaper and far more predictable than an embedded database.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Workspace {
    pub version: u32,
    pub cards: Vec<Card>,
    pub active_card_id: Option<String>,
    /// When pinned, the panel stays open after losing focus.
    #[serde(default)]
    pub pinned: bool,
    /// Last known position of the collapsed ball, so it reappears where the
    /// user left it across restarts.
    #[serde(default)]
    pub ball_position: Option<Point>,
}

impl Default for Workspace {
    fn default() -> Self {
        let first = Card::new("待办问题".to_owned(), 0);
        Self {
            version: SCHEMA_VERSION,
            active_card_id: Some(first.id.clone()),
            cards: vec![first],
            pinned: false,
            ball_position: None,
        }
    }
}

impl Workspace {
    pub fn card_mut(&mut self, id: &str) -> Option<&mut Card> {
        self.cards.iter_mut().find(|c| c.id == id)
    }

    /// Guarantees the invariants the UI relies on: at least one card exists and
    /// `active_card_id` points at a card that is actually present.
    pub fn normalise(&mut self) {
        if self.cards.is_empty() {
            self.cards.push(Card::new("待办问题".to_owned(), 0));
        }
        let active_is_valid = self
            .active_card_id
            .as_deref()
            .is_some_and(|id| self.cards.iter().any(|c| c.id == id));
        if !active_is_valid {
            self.active_card_id = self.cards.first().map(|c| c.id.clone());
        }
    }

    /// Unfinished items across every card — what the mascot's badge reports.
    pub fn open_count(&self) -> usize {
        self.cards
            .iter()
            .map(|c| c.items.iter().filter(|i| !i.done).count())
            .sum()
    }

    /// Accent for the next card, continuing the palette rotation.
    pub fn next_accent(&self) -> u8 {
        self.cards
            .last()
            .map_or(0, |c| (c.accent + 1) % ACCENT_COUNT)
    }
}
