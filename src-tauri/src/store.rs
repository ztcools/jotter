use std::fs::{self, File};
use std::io::Write;
use std::path::{Path, PathBuf};

use parking_lot::RwLock;

use crate::error::Result;
use crate::model::{now_ms, Workspace, SCHEMA_VERSION};

/// Single-document, crash-safe persistence for the workspace.
///
/// Writes go to a sibling temp file that is flushed and then renamed over the
/// real one, so a power loss mid-save leaves the previous good document intact
/// rather than a half-written one. `Store` is the only place that touches disk;
/// swapping in a different backend means reimplementing `load`/`persist` alone.
pub struct Store {
    path: PathBuf,
    inner: RwLock<Workspace>,
}

impl Store {
    /// Loads the workspace at `path`, falling back to a fresh one. A file that
    /// exists but cannot be parsed is preserved under a `.corrupt-<ts>` name so
    /// the user's notes are never silently discarded.
    pub fn load(path: PathBuf) -> Result<Self> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }

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
            inner: RwLock::new(workspace),
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
        let mut guard = self.inner.write();
        let out = f(&mut guard)?;
        guard.normalise();
        persist(&self.path, &guard)?;
        Ok(out)
    }

    fn flush(&self) -> Result<()> {
        persist(&self.path, &self.inner.read())
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
