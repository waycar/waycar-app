//! The herdr command runner (`herdrCommand` in host-config.js).

use std::path::{Path, PathBuf};

use crate::env::Env;
use crate::exec::{RunResult, run_program};
use crate::paths::posix_join;

/// The herdr CLI and the environment to run it with: `HERDR_BIN_PATH` when
/// set (a herdr hook), else `herdr` looked up on `PATH` with the usual
/// install prefixes appended (`HerdrHostPath.extraPATH` in the app).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HerdrCommand {
    pub bin: String,
    pub env: Env,
}

pub fn herdr_command(env: &Env, home: &Path) -> HerdrCommand {
    let mut child_env = env.clone();
    child_env.set("PATH", herdr_path(env, home));
    HerdrCommand {
        bin: env
            .non_empty("HERDR_BIN_PATH")
            .unwrap_or("herdr")
            .to_string(),
        env: child_env,
    }
}

fn herdr_path(env: &Env, home: &Path) -> String {
    let data_home = env
        .absolute("XDG_DATA_HOME")
        .unwrap_or_else(|| posix_join(&[home, Path::new(".local/share")]));
    let mise_data = env
        .absolute("MISE_DATA_DIR")
        .unwrap_or_else(|| posix_join(&[&data_home, Path::new("mise")]));
    let extra: [PathBuf; 8] = [
        posix_join(&[home, Path::new(".local/bin")]),
        posix_join(&[&mise_data, Path::new("shims")]),
        posix_join(&[home, Path::new(".linuxbrew/bin")]),
        posix_join(&[home, Path::new(".cargo/bin")]),
        posix_join(&[home, Path::new(".bun/bin")]),
        PathBuf::from("/opt/homebrew/bin"),
        PathBuf::from("/usr/local/bin"),
        PathBuf::from("/home/linuxbrew/.linuxbrew/bin"),
    ];
    let mut parts: Vec<String> = Vec::with_capacity(extra.len() + 1);
    if let Some(path) = env.non_empty("PATH") {
        parts.push(path.to_string());
    }
    parts.extend(extra.iter().map(|p| p.to_string_lossy().into_owned()));
    parts.join(":")
}

/// Run herdr with `args` (never fails; see [`run_program`]).
pub fn run_herdr(herdr: &HerdrCommand, args: &[&str]) -> RunResult {
    run_program(&herdr.bin, args, &herdr.env)
}
