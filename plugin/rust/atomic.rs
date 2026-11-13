//! Atomic file writes for the hooks' on-disk state and for authorized_keys
//! (files.js and authorized-keys.js).
//!
//! * [`write_atomic`]: replace one file by writing a sibling temp file and
//!   renaming it over the target.
//! * [`edit_locked`]: a read-modify-write under an exclusive lock file, with
//!   the file's mode preserved (0600 for a fresh file) so sshd's StrictModes
//!   keeps accepting `authorized_keys`.
//!
//! One file has one writer at a time, even while the Node and the Rust code
//! both write it: the lock and temp-file names here are the JS ones, so the
//! two sides exclude each other.

use std::fs::{self, DirBuilder, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, PoisonError};
use std::thread;
use std::time::{Duration, SystemTime};

use crate::error::{CliError, Result};

const LOCK_RETRY: Duration = Duration::from_millis(25);
const LOCK_TIMEOUT: Duration = Duration::from_secs(5);
/// A crashed editor leaves its lock behind; edits are millisecond-scale, so a
/// lock this old is garbage, not contention.
const LOCK_STALE: Duration = Duration::from_secs(10);
const BASE64URL: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

/// The file name for a per-pane record: the unpadded base64url of the UTF-8
/// pane id plus `.json`. Pane ids are opaque and need not be filesystem-safe;
/// the app derives the same name to match summary-store entries to panes.
pub fn pane_file_name(pane_id: &str) -> String {
    let bytes = pane_id.as_bytes();
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4 + 5);
    for chunk in bytes.chunks(3) {
        let n = chunk
            .iter()
            .enumerate()
            .fold(0u32, |acc, (i, b)| acc | (u32::from(*b) << (16 - 8 * i)));
        let symbols = chunk.len() + 1;
        for i in 0..symbols {
            out.push(char::from(BASE64URL[((n >> (18 - 6 * i)) & 63) as usize]));
        }
    }
    out.push_str(".json");
    out
}

fn with_suffix(path: &Path, suffix: &str) -> PathBuf {
    let mut name = path.as_os_str().to_owned();
    name.push(suffix);
    PathBuf::from(name)
}

/// The step of an atomic write that failed, for callers that word the error
/// the way Node does (`open 'x'`, `rename 'x' -> 'y'`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WriteStep {
    Open,
    Write,
    Rename,
}

#[derive(Debug)]
pub struct WriteError {
    pub step: WriteStep,
    /// The temp file the step touched.
    pub temp: PathBuf,
    pub source: io::Error,
}

/// Replace `path` atomically: write a sibling `<path>.tmp-<pid>` file, then
/// rename it over the target. The temp name never ends in `.json`, so a reader
/// globbing `*.json` cannot see a half-written file. The temp file is created
/// exclusively, so a stale one with a wider mode is never reused, and it is
/// removed when the write or the rename fails. The name is the JS one (the
/// hooks installer's error messages show it), so it is per process; the
/// threads of this process (the `notify` flows) take turns instead.
pub fn write_atomic(path: &Path, data: &[u8], mode: u32) -> io::Result<()> {
    write_atomic_traced(path, data, mode).map_err(|error| error.source)
}

/// [`write_atomic`] that says which step failed.
pub fn write_atomic_traced(
    path: &Path,
    data: &[u8],
    mode: u32,
) -> std::result::Result<(), WriteError> {
    static IN_PROCESS: Mutex<()> = Mutex::new(());
    let _turn = IN_PROCESS.lock().unwrap_or_else(PoisonError::into_inner);
    let temp = with_suffix(path, &format!(".tmp-{}", std::process::id()));
    let failed = |step, source| WriteError {
        step,
        temp: temp.clone(),
        source,
    };
    let result = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(mode)
        .open(&temp)
        .map_err(|e| failed(WriteStep::Open, e))
        .and_then(|mut file| {
            file.write_all(data)
                .map_err(|e| failed(WriteStep::Write, e))
        })
        .and_then(|()| fs::rename(&temp, path).map_err(|e| failed(WriteStep::Rename, e)));
    if result.is_err() {
        let _ = fs::remove_file(&temp);
    }
    result
}

fn acquire_lock(lock: &Path) -> Result<()> {
    let started = std::time::Instant::now();
    loop {
        match OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(lock)
        {
            Ok(mut file) => {
                let _ = writeln!(file, "{}", std::process::id());
                return Ok(());
            }
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
                match fs::metadata(lock).and_then(|m| m.modified()) {
                    Ok(modified) => {
                        let age = SystemTime::now()
                            .duration_since(modified)
                            .unwrap_or_default();
                        if age > LOCK_STALE {
                            let _ = fs::remove_file(lock);
                            continue;
                        }
                    }
                    // The lock vanished between open and stat: retry now.
                    Err(_) => continue,
                }
                if started.elapsed() > LOCK_TIMEOUT {
                    return Err(CliError::failure(format!(
                        "timed out waiting for authorized_keys lock {}",
                        lock.display()
                    )));
                }
                thread::sleep(LOCK_RETRY);
            }
            Err(error) => return Err(error.into()),
        }
    }
}

/// Atomically edit `path` under an exclusive lock, creating its directory
/// mode 0700.
///
/// `tag` names the lock and temp files next to it (`<path>.<tag>.lock`,
/// `<path>.<tag>.<pid>.tmp`); authorized_keys uses `herdr-pairing`.
/// `edit` receives the current lines (no trailing empty line; none when the
/// file is missing) and returns the new lines, or `None` to leave the file
/// untouched. Returns whether the file was rewritten.
pub fn edit_locked(
    path: &Path,
    tag: &str,
    edit: impl FnOnce(Vec<String>) -> Option<Vec<String>>,
) -> Result<bool> {
    if let Some(dir) = path.parent().filter(|d| !d.as_os_str().is_empty()) {
        DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(dir)
            .map_err(|e| CliError::failure(format!("cannot create {}: {e}", dir.display())))?;
    }
    let lock = with_suffix(path, &format!(".{tag}.lock"));
    acquire_lock(&lock)?;
    let outcome = edit_under_lock(path, tag, edit);
    let _ = fs::remove_file(&lock);
    outcome
}

fn edit_under_lock(
    path: &Path,
    tag: &str,
    edit: impl FnOnce(Vec<String>) -> Option<Vec<String>>,
) -> Result<bool> {
    let content = match fs::read(path) {
        Ok(bytes) => Some(String::from_utf8_lossy(&bytes).into_owned()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => None,
        Err(error) => return Err(error.into()),
    };
    let mut lines: Vec<String> = content
        .as_deref()
        .map(|c| c.split('\n').map(str::to_string).collect())
        .unwrap_or_default();
    if lines.last().is_some_and(String::is_empty) {
        lines.pop();
    }
    let Some(edited) = edit(lines) else {
        return Ok(false);
    };
    let mode = match content {
        None => 0o600,
        Some(_) => fs::metadata(path)?.permissions().mode() & 0o777,
    };
    let temp = with_suffix(path, &format!(".{tag}.{}.tmp", std::process::id()));
    let body = if edited.is_empty() {
        String::new()
    } else {
        format!("{}\n", edited.join("\n"))
    };
    let written = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(mode)
        .open(&temp)
        .and_then(|mut file| file.write_all(body.as_bytes()))
        // The umask narrows the creation mode; the file keeps the mode it had
        // (sshd's StrictModes reads it) whatever the caller's umask is.
        .and_then(|()| fs::set_permissions(&temp, fs::Permissions::from_mode(mode)))
        .and_then(|()| fs::rename(&temp, path));
    if let Err(error) = written {
        let _ = fs::remove_file(&temp);
        return Err(error.into());
    }
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pane_file_name_is_unpadded_base64url() {
        assert_eq!(pane_file_name("tmux:%3"), "dG11eDolMw.json");
        assert_eq!(pane_file_name("a"), "YQ.json");
        assert_eq!(pane_file_name("ab"), "YWI.json");
        assert_eq!(pane_file_name("abc"), "YWJj.json");
        // Index 62 and 63 are the url-safe '-' and '_', not '+' and '/'.
        assert_eq!(pane_file_name("~~~"), "fn5-.json");
        assert_eq!(pane_file_name("???"), "Pz8_.json");
    }

    #[test]
    fn threads_writing_one_path_never_fail_or_leave_temp_files() {
        let dir = crate::test_support::TempDir::new("atomic-threads");
        let path = dir.path().join("notifications.json");
        thread::scope(|scope| {
            for id in 0..4 {
                let path = &path;
                scope.spawn(move || {
                    for round in 0..500 {
                        let data = format!("{id}:{round}");
                        write_atomic(path, data.as_bytes(), 0o600)
                            .unwrap_or_else(|error| panic!("thread {id} round {round}: {error}"));
                    }
                });
            }
        });
        let names: Vec<_> = fs::read_dir(dir.path())
            .unwrap()
            .map(|entry| entry.unwrap().file_name())
            .collect();
        assert_eq!(names, ["notifications.json"]);
    }
}
