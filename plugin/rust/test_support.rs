//! Helpers the unit tests share.

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};

/// A fresh directory under the system temp dir, removed on drop.
pub struct TempDir(PathBuf);

impl TempDir {
    pub fn new(label: &str) -> Self {
        static COUNTER: AtomicUsize = AtomicUsize::new(0);
        let dir = std::env::temp_dir().join(format!(
            "waycar-test-{label}-{}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).expect("create the test directory");
        Self(dir)
    }

    pub fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// Write a shell script with the given mode. Starting a script another test
/// thread was writing can fail with ETXTBSY: a child forked meanwhile holds the
/// file open for writing until its exec. An executable script therefore starts
/// with a probe guard, and this waits until it has started once, so a later run
/// of it by the code under test cannot hit that window.
pub fn write_script(path: &Path, body: &str, mode: u32) {
    use std::os::unix::fs::PermissionsExt;
    use std::process::{Command, Stdio};

    fs::write(
        path,
        format!("#!/bin/sh\n[ \"${{WAYCAR_TEST_PROBE:-}}\" = 1 ] && exit 0\n{body}\n"),
    )
    .expect("write the script");
    fs::set_permissions(path, fs::Permissions::from_mode(mode)).expect("chmod the script");
    if mode & 0o111 == 0 {
        return;
    }
    loop {
        let probe = Command::new(path)
            .env_clear()
            .env("WAYCAR_TEST_PROBE", "1")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
        match probe {
            Err(error) if error.raw_os_error() == Some(libc::ETXTBSY) => {
                std::thread::sleep(std::time::Duration::from_millis(1));
            }
            _ => return,
        }
    }
}

/// An executable stub (mode 0755) from `content`, which may begin with its own
/// `#!/bin/sh` line. See [`write_script`] for why a stub is never written any
/// other way.
pub fn write_stub(path: &Path, content: &str) {
    let body = content.strip_prefix("#!/bin/sh\n").unwrap_or(content);
    write_script(path, body.trim_end_matches('\n'), 0o755);
}
