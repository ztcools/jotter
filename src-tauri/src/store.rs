use std::fs::{self, File};
use std::io::Write;
use std::path::{Path, PathBuf};

use base64::Engine;
use parking_lot::RwLock;

use crate::error::{Error, Result};
use crate::model::{now_ms, Workspace, SCHEMA_VERSION};

/// Single-document, crash-safe persistence for the workspace.
///
/// Writes go to a sibling temp file that is flushed and then renamed over the
/// real one, so a power loss mid-save leaves the previous good document intact
/// rather than a half-written one. `Store` is the only place that touches disk;
/// swapping in a different backend means reimplementing `load`/`persist` alone.
/// Called after every successful mutation with the number of unfinished items.
///
/// A hook on the store rather than a call at the end of each command: there are
/// eight mutating commands plus the tray, and "remember to notify" is exactly the
/// kind of step that gets forgotten when a ninth is added.
pub type ChangeHook = Box<dyn Fn(usize) + Send + Sync>;

pub struct Store {
    path: PathBuf,
    images_dir: PathBuf,
    inner: RwLock<Workspace>,
    on_change: ChangeHook,
}

impl Store {
    /// Loads the workspace at `path`, falling back to a fresh one. A file that
    /// exists but cannot be parsed is preserved under a `.corrupt-<ts>` name so
    /// the user's notes are never silently discarded.
    pub fn load(path: PathBuf, images_dir: PathBuf, on_change: ChangeHook) -> Result<Self> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::create_dir_all(&images_dir)?;

        let mut workspace = match fs::read_to_string(&path) {
            Ok(raw) => match serde_json::from_str::<Workspace>(&raw) {
                Ok(ws) => ws,
                Err(err) => {
                    let quarantine = path.with_extension(format!("corrupt-{}", now_ms()));
                    log::error!(
                        "workspace at {} is unreadable ({err}); moved to {}",
                        path.display(),
                        quarantine.display()
                    );
                    let _ = fs::rename(&path, &quarantine);
                    Workspace::default()
                }
            },
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => Workspace::default(),
            Err(err) => return Err(err.into()),
        };

        workspace.version = SCHEMA_VERSION;
        workspace.normalise();

        let store = Self {
            path,
            images_dir,
            inner: RwLock::new(workspace),
            on_change,
        };
        store.flush()?;
        Ok(store)
    }

    /// Reads a projection of the workspace without cloning the whole document.
    pub fn read<R>(&self, f: impl FnOnce(&Workspace) -> R) -> R {
        f(&self.inner.read())
    }

    pub fn snapshot(&self) -> Workspace {
        self.inner.read().clone()
    }

    /// Mutates the workspace and persists the result before returning. The
    /// invariant check runs on every mutation so no command can leave the UI
    /// pointing at a card that no longer exists.
    pub fn write<R>(&self, f: impl FnOnce(&mut Workspace) -> Result<R>) -> Result<R> {
        let (out, open) = {
            let mut guard = self.inner.write();
            let out = f(&mut guard)?;
            guard.normalise();
            persist(&self.path, &guard)?;
            (out, guard.open_count())
        };
        // Deliberately outside the lock: the hook reaches into Tauri, and a
        // listener that reads the store back would deadlock against our own
        // write guard.
        (self.on_change)(open);
        Ok(out)
    }

    fn flush(&self) -> Result<()> {
        persist(&self.path, &self.inner.read())
    }

    // ------------------------------------------------------------------ images
    //
    // Images are stored as individual PNG files next to the workspace document
    // rather than inlined as base64 in the JSON.  The workspace is rewritten
    // atomically on every mutation, and a single pasted screenshot would turn
    // every checkbox toggle into a multi-megabyte fsync.

    /// Decodes a base64 data URL (with or without the `data:image/…;base64,`
    /// prefix) and writes the decoded bytes into the images directory.  Returns
    /// a relative path suitable for storing in `Item.images`.
    pub fn save_image(&self, data_url: &str) -> Result<String> {
        let encoded = data_url
            .trim_start_matches("data:image/png;base64,")
            .trim_start_matches("data:image/jpeg;base64,")
            .trim_start_matches("data:image/webp;base64,")
            .trim_start_matches("data:image/gif;base64,")
            .trim_start_matches("data:image/bmp;base64,");
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(encoded.as_bytes())
            .map_err(|e| Error::Invalid(format!("invalid base64 image: {e}")))?;
        let filename = format!("{}.png", uuid::Uuid::new_v4().simple());
        let dest = self.images_dir.join(&filename);
        fs::write(&dest, &bytes)?;
        Ok(format!("images/{}", filename))
    }

    /// Reads image files from the images directory and returns them as base64
    /// data URLs so the frontend can render them without a custom protocol.
    pub fn read_images_batch(&self, paths: &[String]) -> Result<Vec<String>> {
        paths
            .iter()
            .map(|p| {
                let filename = p.strip_prefix("images/").unwrap_or(p);
                let bytes = fs::read(self.images_dir.join(filename))?;
                Ok(format!(
                    "data:image/png;base64,{}",
                    base64::engine::general_purpose::STANDARD.encode(&bytes)
                ))
            })
            .collect()
    }
}

fn persist(path: &Path, workspace: &Workspace) -> Result<()> {
    let tmp = path.with_extension("json.tmp");
    let bytes = serde_json::to_vec_pretty(workspace)?;

    {
        let mut file = File::create(&tmp)?;
        file.write_all(&bytes)?;
        file.sync_all()?;
    }

    // Atomic replace on both platforms: POSIX rename(2) semantics, and
    // MoveFileExW with MOVEFILE_REPLACE_EXISTING on Windows.
    fs::rename(&tmp, path)?;
    Ok(())
}
