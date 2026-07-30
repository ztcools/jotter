use serde::{Serialize, Serializer};

/// Every fallible boundary in the app funnels through this type; the `Serialize`
/// impl is what lets commands return it straight to the webview as a string.
#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("storage io failed: {0}")]
    Io(#[from] std::io::Error),

    #[error("workspace could not be (de)serialised: {0}")]
    Json(#[from] serde_json::Error),

    #[error("window operation failed: {0}")]
    Tauri(#[from] tauri::Error),

    #[error("clipboard unavailable: {0}")]
    Clipboard(String),

    #[error("no such {kind}: {id}")]
    NotFound { kind: &'static str, id: String },

    #[error("{0}")]
    Invalid(String),
}

impl Error {
    pub fn not_found(kind: &'static str, id: impl Into<String>) -> Self {
        Self::NotFound {
            kind,
            id: id.into(),
        }
    }
}

impl Serialize for Error {
    // `std::result::Result` spelled out: the alias below shadows the name inside
    // this module and only takes one parameter.
    fn serialize<S: Serializer>(&self, serializer: S) -> std::result::Result<S::Ok, S::Error> {
        serializer.serialize_str(&self.to_string())
    }
}

pub type Result<T> = std::result::Result<T, Error>;
