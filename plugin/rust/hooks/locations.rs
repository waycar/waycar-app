//! Where each agent keeps its config on a Host, and how a Host is checked for
//! an agent (agent-hooks.js).

use std::ffi::CString;
use std::path::{Path, PathBuf};

use crate::env::Env;
use crate::native::Ctx;
use crate::paths::posix_join;

fn join(parts: &[&str]) -> PathBuf {
    posix_join(&parts.iter().map(Path::new).collect::<Vec<_>>())
}

fn under(base: &Path, parts: &[&str]) -> PathBuf {
    let mut all = vec![base];
    all.extend(parts.iter().map(Path::new));
    posix_join(&all)
}

fn home_dir(ctx: &Ctx, parts: &[&str]) -> PathBuf {
    under(&ctx.home, parts)
}

/// `$VAR` when set and not empty, else `~/<default>`.
fn env_dir(ctx: &Ctx, var: &str, default: &str) -> PathBuf {
    ctx.env
        .non_empty(var)
        .map_or_else(|| home_dir(ctx, &[default]), PathBuf::from)
}

fn config_home(ctx: &Ctx) -> PathBuf {
    ctx.env
        .non_empty("XDG_CONFIG_HOME")
        .map_or_else(|| home_dir(ctx, &[".config"]), PathBuf::from)
}

pub fn opencode_dir(ctx: &Ctx) -> PathBuf {
    under(&config_home(ctx), &["opencode"])
}

pub fn kilo_dir(ctx: &Ctx) -> PathBuf {
    under(&config_home(ctx), &["kilo"])
}

pub fn claude_dir(ctx: &Ctx) -> PathBuf {
    env_dir(ctx, "CLAUDE_CONFIG_DIR", ".claude")
}

pub fn codex_dir(ctx: &Ctx) -> PathBuf {
    env_dir(ctx, "CODEX_HOME", ".codex")
}

fn copilot_dir(ctx: &Ctx) -> PathBuf {
    env_dir(ctx, "COPILOT_HOME", ".copilot")
}

fn grok_dir(ctx: &Ctx) -> PathBuf {
    env_dir(ctx, "GROK_HOME", ".grok")
}

pub fn hermes_dir(ctx: &Ctx) -> PathBuf {
    env_dir(ctx, "HERMES_HOME", ".hermes")
}

/// The config file of a Claude-format kind.
pub fn settings_file(agent: &str, ctx: &Ctx) -> PathBuf {
    match agent {
        "claude" => under(&claude_dir(ctx), &["settings.json"]),
        "qwen" => home_dir(ctx, &[".qwen", "settings.json"]),
        "gemini" => home_dir(ctx, &[".gemini", "settings.json"]),
        "devin" => home_dir(ctx, &[".config", "devin", "config.json"]),
        "grok" => under(&grok_dir(ctx), &["hooks", "waycar.json"]),
        "copilot" => under(&copilot_dir(ctx), &["hooks", "waycar.json"]),
        "cursor" => home_dir(ctx, &[".cursor", "hooks.json"]),
        _ => under(&config_home(ctx), &["muse", "settings.json"]),
    }
}

/// The directory holding the files we own outright for an agent.
pub fn file_set_dir(agent: &str, ctx: &Ctx) -> PathBuf {
    match agent {
        "omp" => home_dir(ctx, &[".omp", "agent", "extensions"]),
        "pi" => home_dir(ctx, &[".pi", "agent", "extensions"]),
        "opencode" => under(&opencode_dir(ctx), &["plugins"]),
        "kilo" => under(&kilo_dir(ctx), &["plugins"]),
        "cline" => home_dir(ctx, &[".cline", "hooks"]),
        _ => home_dir(ctx, &[".kiro", "hooks"]),
    }
}

/// An agent's config root and its binary name, for detection.
fn detection(agent: &str, ctx: &Ctx) -> Option<(PathBuf, &'static str)> {
    Some(match agent {
        "claude" => (claude_dir(ctx), "claude"),
        "codex" => (codex_dir(ctx), "codex"),
        "omp" => (home_dir(ctx, &[".omp"]), "omp"),
        "pi" => (home_dir(ctx, &[".pi"]), "pi"),
        "opencode" => (opencode_dir(ctx), "opencode"),
        "copilot" => (copilot_dir(ctx), "copilot"),
        "qwen" => (home_dir(ctx, &[".qwen"]), "qwen"),
        // ~/.gemini alone also holds Antigravity's config.
        "gemini" => (home_dir(ctx, &[".gemini", "settings.json"]), "gemini"),
        "grok" => (grok_dir(ctx), "grok"),
        "agy" => (home_dir(ctx, &[".gemini", "antigravity-cli"]), "agy"),
        "hermes" => (hermes_dir(ctx), "hermes"),
        "kilo" => (kilo_dir(ctx), "kilo"),
        "cline" => (home_dir(ctx, &[".cline"]), "cline"),
        "cursor" => (home_dir(ctx, &[".cursor"]), "cursor-agent"),
        "devin" => (home_dir(ctx, &[".config", "devin"]), "devin"),
        "kiro" => (home_dir(ctx, &[".kiro"]), "kiro-cli"),
        "muse" => (under(&config_home(ctx), &["muse"]), "muse"),
        _ => return None,
    })
}

/// Whether `name` is accessible for execution in a `PATH` directory. A
/// directory of that name counts, as `access(2)` says it does.
fn on_path(env: &Env, name: &str) -> bool {
    env.get("PATH")
        .unwrap_or("")
        .split(':')
        .filter(|dir| !dir.is_empty())
        .any(|dir| {
            let candidate = join(&[dir, name]);
            CString::new(candidate.as_os_str().as_encoded_bytes())
                // SAFETY: the string is NUL-terminated and outlives the call.
                .is_ok_and(|path| unsafe { libc::access(path.as_ptr(), libc::X_OK) } == 0)
        })
}

/// Whether an agent's config directory or binary exists on this Host.
pub fn agent_detected(agent: &str, ctx: &Ctx) -> bool {
    detection(agent, ctx).is_some_and(|(root, bin)| root.exists() || on_path(&ctx.env, bin))
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::os::unix::fs::PermissionsExt;

    use super::*;

    fn ctx(home: &Path, pairs: &[(&str, &str)]) -> Ctx {
        Ctx {
            env: Env::from_pairs(pairs.iter().map(|(k, v)| (k.to_string(), v.to_string()))),
            home: home.to_path_buf(),
            plugin_root: PathBuf::from("/p"),
        }
    }

    #[test]
    fn config_dirs_follow_the_environment_when_it_is_not_empty() {
        let home = Path::new("/home/u");
        let plain = ctx(home, &[]);
        assert_eq!(claude_dir(&plain), Path::new("/home/u/.claude"));
        assert_eq!(codex_dir(&plain), Path::new("/home/u/.codex"));
        assert_eq!(hermes_dir(&plain), Path::new("/home/u/.hermes"));
        assert_eq!(opencode_dir(&plain), Path::new("/home/u/.config/opencode"));
        assert_eq!(kilo_dir(&plain), Path::new("/home/u/.config/kilo"));
        let set = ctx(
            home,
            &[
                ("CLAUDE_CONFIG_DIR", "/c//x/../cc/"),
                ("CODEX_HOME", ""),
                ("XDG_CONFIG_HOME", "rel"),
            ],
        );
        // A set directory is used as given; a join normalizes it.
        assert_eq!(claude_dir(&set), Path::new("/c//x/../cc/"));
        assert_eq!(
            settings_file("claude", &set),
            Path::new("/c/cc/settings.json")
        );
        assert_eq!(codex_dir(&set), Path::new("/home/u/.codex"));
        assert_eq!(opencode_dir(&set), Path::new("rel/opencode"));
        assert_eq!(
            settings_file("muse", &set),
            Path::new("rel/muse/settings.json")
        );
        assert_eq!(
            settings_file("copilot", &plain),
            Path::new("/home/u/.copilot/hooks/waycar.json")
        );
        assert_eq!(
            file_set_dir("kiro", &plain),
            Path::new("/home/u/.kiro/hooks")
        );
    }

    #[test]
    fn a_binary_is_found_by_access_not_by_looks() {
        let dir = std::env::temp_dir().join(format!("wc-locations-{}", std::process::id()));
        let bin = dir.join("bin");
        fs::create_dir_all(bin.join("claude")).unwrap();
        fs::write(bin.join("codex"), "").unwrap();
        fs::write(bin.join("omp"), "").unwrap();
        fs::set_permissions(bin.join("omp"), fs::Permissions::from_mode(0o755)).unwrap();
        let path = format!(":{}:", bin.display());
        let env = Env::from_pairs([("PATH".to_string(), path)]);
        assert!(on_path(&env, "omp"), "an executable file");
        assert!(
            on_path(&env, "claude"),
            "a directory is searchable, so access says yes"
        );
        if unsafe { libc::geteuid() } != 0 {
            assert!(!on_path(&env, "codex"), "no execute bit");
        }
        assert!(!on_path(&env, "pi"));
        assert!(!on_path(&Env::default(), "omp"));
        assert!(!on_path(
            &Env::from_pairs([("PATH".to_string(), String::new())]),
            "omp"
        ));
        fs::remove_dir_all(&dir).unwrap();
    }
}
