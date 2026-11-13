//! A private tmux server for tests that drive a real tmux (its own
//! `TMUX_TMPDIR`, no `TMUX`, no locale). `WAYCAR_TEST_TMUX` names a tmux
//! binary to use instead of the one on `PATH`; `start` is `None` when no
//! tmux runs, and the test skips.

use std::path::PathBuf;
use std::process::{Command, Output};
use std::sync::atomic::{AtomicUsize, Ordering};

use crate::env::Env;

static SERVERS: AtomicUsize = AtomicUsize::new(0);

pub struct RealTmux {
    binary: PathBuf,
    dir: PathBuf,
    /// What a hook or watch started outside tmux runs with: `tmux` on
    /// `PATH` is this binary, and its server is this one's.
    pub env: Env,
}

impl RealTmux {
    pub fn start() -> Option<Self> {
        let binary = std::env::var_os("WAYCAR_TEST_TMUX")
            .map(|binary| std::fs::canonicalize(binary).expect("WAYCAR_TEST_TMUX"))
            .unwrap_or_else(|| "tmux".into());
        let runs = Command::new(&binary)
            .arg("-V")
            .output()
            .is_ok_and(|out| out.status.success());
        if !runs {
            eprintln!("skipped: tmux not installed");
            return None;
        }
        let dir = PathBuf::from(format!(
            "/tmp/wc-real-tmux-{}-{}",
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
