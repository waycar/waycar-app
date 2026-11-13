//! A private tmux server for tests that drive a real tmux (its own
//! `TMUX_TMPDIR`, no `TMUX`, no locale). `WAYCAR_TEST_TMUX` names a tmux
//! binary to use instead of the one on `PATH`; `start` is `None` when no
//! tmux runs, and the test skips.

use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::{Command, Output};
use std::sync::atomic::{AtomicUsize, Ordering};

use crate::env::Env;

static SERVERS: AtomicUsize = AtomicUsize::new(0);

/// Where each server's private `TMUX_TMPDIR` (and `bin`) lives.
const PRIVATE_PREFIX: &str = "/tmp/wc-real-tmux-";

pub struct RealTmux {
    binary: PathBuf,
    dir: PathBuf,
    /// What a hook or watch started outside tmux runs with: `tmux` on
    /// `PATH` is this binary, and its server is this one's.
    pub env: Env,
}

/// The first executable `tmux` on `PATH`, as an absolute path: the private
/// `bin` links to it, so a bare name there would be a link to itself. A
/// private `bin` of another server is never the answer.
fn tmux_on_path() -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .filter(|dir| dir.is_absolute() && !dir.to_string_lossy().starts_with(PRIVATE_PREFIX))
        .map(|dir| dir.join("tmux"))
        .find(|candidate| {
            std::fs::metadata(candidate)
                .is_ok_and(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
        })
        .and_then(|candidate| std::fs::canonicalize(candidate).ok())
}

impl RealTmux {
    pub fn start() -> Option<Self> {
        let binary = match std::env::var_os("WAYCAR_TEST_TMUX") {
            Some(binary) => std::fs::canonicalize(binary).expect("WAYCAR_TEST_TMUX"),
            None => {
                let Some(binary) = tmux_on_path() else {
                    eprintln!("skipped: tmux not installed");
                    return None;
                };
                binary
            }
        };
        let runs = Command::new(&binary)
            .arg("-V")
            .output()
            .is_ok_and(|out| out.status.success());
        if !runs {
            eprintln!("skipped: tmux not installed");
            return None;
        }
        let dir = PathBuf::from(format!(
            "{PRIVATE_PREFIX}{}-{}",
            std::process::id(),
            SERVERS.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(dir.join("bin")).expect("tmux dir");
        std::os::unix::fs::symlink(&binary, dir.join("bin/tmux")).expect("tmux link");
        let path = format!(
            "{}:{}",
            dir.join("bin").display(),
            std::env::var("PATH").unwrap_or_default()
        );
        let env = Env::from_pairs([
            ("PATH", path.as_str()),
            ("TMUX_TMPDIR", dir.to_str().expect("utf-8 dir")),
        ]);
        Some(Self { binary, dir, env })
    }

    pub fn cli(&self, args: &[&str]) -> Output {
        Command::new(&self.binary)
            .args(["-f", "/dev/null"])
            .args(args)
            .env_clear()
            .envs(self.env.iter())
            .output()
            .expect("run tmux")
    }

    /// The trimmed stdout of a tmux command that must succeed.
    pub fn ok(&self, args: &[&str]) -> String {
        let out = self.cli(args);
        assert!(
            out.status.success(),
            "tmux {args:?}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        String::from_utf8_lossy(&out.stdout).trim().to_string()
    }
}

impl Drop for RealTmux {
    fn drop(&mut self) {
        self.cli(&["kill-server"]);
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}
