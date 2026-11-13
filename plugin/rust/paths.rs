//! Where the Host Tools find themselves, their config and their state
//! (host-config.js, and the plugin root `waycar-cli.js` derives from its own
//! location).
//!
//! One registration/config directory per Host (design §4.5). The config
//! files (`notifications.json`, `notify.json`, the summary store) live in the
//! `waycar` herdr plugin's config directory when that plugin is installed,
//! else in `${XDG_CONFIG_HOME:-~/.config}/waycar`. The state directory
//! follows the config directory's owner: herdr's per-plugin state directory
//! (`${XDG_STATE_HOME:-~/.local/state}/herdr/plugins/<id>`) or
//! `${XDG_STATE_HOME:-~/.local/state}/waycar`. Inside a herdr hook the
//! injected `HERDR_PLUGIN_CONFIG_DIR` and `HERDR_PLUGIN_STATE_DIR` win.

use std::fs::DirBuilder;
use std::os::unix::fs::DirBuilderExt;
use std::path::{Component, Path, PathBuf};

use serde_json::Value;

use crate::env::Env;
use crate::error::{CliError, Result};
use crate::exec::RunResult;
use crate::herdr::{HerdrCommand, herdr_command};

/// The current plugin id first, then the ids it shipped under before.
const PLUGIN_IDS: [&str; 2] = ["waycar", "herdr-mobile.pairing"];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConfigSource {
    HerdrPlugin,
    Waycar,
}

impl ConfigSource {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::HerdrPlugin => "herdr-plugin",
            Self::Waycar => "waycar",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostConfig {
    pub config_dir: PathBuf,
    pub state_dir: PathBuf,
    pub source: ConfigSource,
}

/// `path.posix.join`: join with `/`, then normalize (`//`, `.` and `..`
/// collapse; a trailing `/` stays).
pub fn posix_join(parts: &[&Path]) -> PathBuf {
    let mut text = std::ffi::OsString::new();
    for part in parts.iter().filter(|p| !p.as_os_str().is_empty()) {
        if !text.is_empty() {
            text.push("/");
        }
        text.push(part.as_os_str());
    }
    let trailing = text.as_encoded_bytes().ends_with(b"/");
    let joined = PathBuf::from(text);
    let absolute = joined.has_root();
    let mut stack: Vec<Component> = Vec::new();
    for component in joined.components() {
        match component {
            Component::RootDir | Component::CurDir | Component::Prefix(_) => {}
            Component::ParentDir => match stack.last() {
                Some(Component::Normal(_)) => {
                    stack.pop();
                }
                _ if absolute => {}
                _ => stack.push(component),
            },
            Component::Normal(_) => stack.push(component),
        }
    }
    let mut out = PathBuf::new();
    if absolute {
        out.push("/");
    }
    out.extend(stack.iter().map(|c| c.as_os_str()));
    if out.as_os_str().is_empty() {
        out.push(".");
    }
    if trailing && !out.as_os_str().as_encoded_bytes().ends_with(b"/") {
        out.push("");
    }
    out
}

/// The account's home directory: `$HOME`, else the passwd entry.
pub fn home_dir(env: &Env) -> Option<PathBuf> {
    env.non_empty("HOME")
        .map(PathBuf::from)
        .or_else(std::env::home_dir)
}

/// The plugin directory the running binary belongs to: `bin/waycar`'s
/// grandparent, symlinks (`~/.local/bin/waycar`) resolved.
pub fn plugin_root_of(exe: &Path) -> Result<PathBuf> {
    let real = std::fs::canonicalize(exe)
        .map_err(|e| CliError::failure(format!("cannot resolve {}: {e}", exe.display())))?;
    real.parent()
        .and_then(Path::parent)
        .map(Path::to_path_buf)
        .ok_or_else(|| {
            CliError::failure(format!(
                "{} is not inside a plugin directory",
                real.display()
            ))
        })
}

/// The id the `waycar` herdr plugin is enabled under, or `None` when herdr is
/// missing, cannot answer, or has no such plugin enabled.
fn installed_plugin_id(
    herdr: &HerdrCommand,
    run: &dyn Fn(&HerdrCommand, &[&str]) -> RunResult,
) -> Option<&'static str> {
    let result = run(herdr, &["plugin", "list", "--json"]);
    if result.code != 0 {
        return None;
    }
    let parsed: Value = serde_json::from_str(&result.stdout).ok()?;
    let plugins = parsed.get("result")?.get("plugins")?.as_array()?;
    let enabled = |id: &str| {
        plugins.iter().any(|plugin| {
            plugin.get("enabled") != Some(&Value::Bool(false))
                && plugin.get("plugin_id").and_then(Value::as_str) == Some(id)
        })
    };
    PLUGIN_IDS.into_iter().find(|id| enabled(id))
}

/// Resolve the Host's config and state directories, creating missing ones
/// mode 0700.
///
/// Order: `HERDR_PLUGIN_CONFIG_DIR` (inside a herdr hook), the enabled
/// `waycar` herdr plugin's `herdr plugin config-dir`, then
/// `${XDG_CONFIG_HOME:-$HOME/.config}/waycar`. An installed plugin whose
/// config dir cannot be read is an error rather than a fallback: a second
/// registration file would split the Host's devices.
///
/// `run` runs herdr; tests and the parity harness give it a fake.
pub fn resolve_host_config(
    env: &Env,
    home: &Path,
    run: &dyn Fn(&HerdrCommand, &[&str]) -> RunResult,
) -> Result<HostConfig> {
    let state_home = env
        .absolute("XDG_STATE_HOME")
        .unwrap_or_else(|| posix_join(&[home, Path::new(".local/state")]));
    let injected_state = env.non_empty("HERDR_PLUGIN_STATE_DIR").map(PathBuf::from);
    let herdr_state =
        |id: &str| posix_join(&[&state_home, Path::new("herdr/plugins"), Path::new(id)]);

    let resolved = if let Some(config_dir) = env.non_empty("HERDR_PLUGIN_CONFIG_DIR") {
        HostConfig {
            config_dir: PathBuf::from(config_dir),
            state_dir: injected_state.unwrap_or_else(|| herdr_state(PLUGIN_IDS[0])),
            source: ConfigSource::HerdrPlugin,
        }
    } else {
        let herdr = herdr_command(env, home);
        if let Some(id) = installed_plugin_id(&herdr, run) {
            let result = run(&herdr, &["plugin", "config-dir", id]);
            let config_dir = if result.code == 0 {
                result.stdout.trim().to_string()
            } else {
                String::new()
            };
            if !config_dir.starts_with('/') || config_dir.contains('\n') {
                return Err(CliError::failure(format!(
                    "herdr plugin config-dir {id} gave no usable directory (exit {})",
                    result.code
                )));
            }
            HostConfig {
                config_dir: PathBuf::from(config_dir),
                state_dir: injected_state.unwrap_or_else(|| herdr_state(id)),
                source: ConfigSource::HerdrPlugin,
            }
        } else {
            let config_home = env
                .absolute("XDG_CONFIG_HOME")
                .unwrap_or_else(|| posix_join(&[home, Path::new(".config")]));
            HostConfig {
                config_dir: posix_join(&[&config_home, Path::new("waycar")]),
                state_dir: injected_state
                    .unwrap_or_else(|| posix_join(&[&state_home, Path::new("waycar")])),
                source: ConfigSource::Waycar,
            }
        }
    };
    for dir in [&resolved.config_dir, &resolved.state_dir] {
        DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(dir)
            .map_err(|e| CliError::failure(format!("cannot create {}: {e}", dir.display())))?;
    }
    Ok(resolved)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn posix_join_is_path_posix_join() {
        let join = |parts: &[&str]| {
            let paths: Vec<&Path> = parts.iter().map(Path::new).collect();
            posix_join(&paths).to_string_lossy().into_owned()
        };
        // Expected values are `path.posix.join` of Node 24.
        for (parts, joined) in [
            (&["a", "b/"][..], "a/b/"),
            (&["/", "x"], "/x"),
            (&["a/..", ""], "."),
            (&["a/../", ""], "./"),
            (&["/a", "/b"], "/a/b"),
            (&["a", "", "b"], "a/b"),
            (&["", ""], "."),
            (&["/a/../../b"], "/b"),
            (&["a/../../b"], "../b"),
            (&["//a//b//"], "/a/b/"),
            (&["a", "/b/"], "a/b/"),
            (&["/", "/"], "/"),
            (&["."], "."),
            (&["./"], "./"),
            (&[".", "x"], "x"),
            (&["/home/u", "src//proj/"], "/home/u/src/proj/"),
            (&["/home/u", "/x"], "/home/u/x"),
            (&["~", "a"], "~/a"),
            (&["a/./b/../c/"], "a/c/"),
            (&["..", "a"], "../a"),
            (&["../", ""], "../"),
        ] {
            assert_eq!(join(parts), joined, "{parts:?}");
        }
    }
}
