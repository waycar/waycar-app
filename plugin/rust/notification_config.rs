//! The plugin-side `notify.json` (notification-config.js): relay URL,
//! debounce and retry timings, the Agent Summary switches and the tmux
//! switch, read from the Host's config directory (see `paths`).
//!
//! Defaults and validation are the JS ones. A missing, unreadable or
//! unparsable file is `{}` (all defaults); a file that parses to JSON `null`
//! is the one input the JS throws on (reading a property of `null`), and
//! [`read_notification_config`] returns that error too.
//!
//! # Differences from the JS
//!
//! The millisecond settings are `u64`: an integer above 2^64 saturates, and
//! one above 2^53 is the `f64` JSON parsing gives. `serde_json` rejects a
//! lone `\ud800` escape that `JSON.parse` accepts (such a file reads as all
//! defaults here).

use std::fs;

use serde_json::Value;

use crate::jspath;
use crate::jsx;

pub const DEFAULT_RELAY_URL: &str = "https://waycar-apns.otreva.com";

/// Endpoints that shipped as the default before. A config still naming one is
/// treated as unset, so it migrates to [`DEFAULT_RELAY_URL`] instead of being
/// honoured as a deliberate override.
pub const LEGACY_DEFAULT_RELAY_URLS: [&str; 1] =
    ["https://herdr-push-relay.69709991236.workers.dev"];

const DEFAULT_DEBOUNCE_MS: u64 = 5000;
const DEFAULT_ACTIVITY_DEBOUNCE_MS: u64 = 1500;
/// Longer than the app's own foreground start (3 s settle plus the token write
/// over SSH), so an open app's local activity wins over a push-to-start.
const DEFAULT_ACTIVITY_START_GRACE_MS: u64 = 8000;
const DEFAULT_RETRY_DELAY_MS: u64 = 1000;
/// The Agent Summary's total budget, from the status event to a summary in
/// hand; it runs alongside the debounce, so the push waits at most this long.
const DEFAULT_SUMMARY_TIMEOUT_MS: u64 = 15_000;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NotificationConfig {
    pub relay_url: String,
    pub debounce_ms: u64,
    pub activity_debounce_ms: u64,
    pub activity_start_grace_ms: u64,
    pub retry_delay_ms: u64,
    /// Off unless the app switched it on: summarizing sends screen text to a
    /// model provider, which needs the user's consent.
    pub summary_enabled: bool,
    /// An argv with a non-empty program, or `None` (auto-detect a harness).
    pub summary_command: Option<Vec<String>>,
    pub summary_timeout_ms: u64,
    /// Whether tmux panes count and notify on this Host (Host detail can hide
    /// them); on unless the app switched it off.
    pub tmux_enabled: bool,
    /// Whether herdr-core terminals count and notify on this Host; on unless
    /// the app switched it off (a Host with the Herdr TUI and core together
    /// uses one of them, picked in the app).
    pub core_enabled: bool,
    /// Whether Zellij panes count and notify; absent means on.
    pub zellij_enabled: bool,
    /// Whether shared-daemon Codex threads notify; absent means on.
    pub codex_enabled: bool,
    /// Whether OpenCode 2 server sessions notify; absent means on.
    pub opencode_enabled: bool,
}

/// A trimmed relay URL without trailing slashes, or `None` when empty or a
/// retired default.
fn normalize_relay_url(value: &Value) -> Option<String> {
    let normalized = jsx::trim(value.as_str()?).trim_end_matches('/');
    if normalized.is_empty() || LEGACY_DEFAULT_RELAY_URLS.contains(&normalized) {
        return None;
    }
    Some(normalized.to_string())
}

/// An argv of strings with a non-empty program, or `None`.
fn normalize_summary_command(value: &Value) -> Option<Vec<String>> {
    let argv = value
        .as_array()?
        .iter()
        .map(|arg| arg.as_str().map(str::to_string))
        .collect::<Option<Vec<_>>>()?;
    if argv.first()?.is_empty() {
        return None;
    }
    Some(argv)
}

/// `Number.isInteger(value) && value >= 0 ? value : fallback`.
fn positive_int(value: &Value, fallback: u64) -> u64 {
    match value {
        Value::Number(number) if jsx::is_integer(value) => {
            let f = jsx::json_f64(number);
            if f >= 0.0 { f as u64 } else { fallback }
        }
        _ => fallback,
    }
}

/// The config a parsed `notify.json` holds. A non-object value has no
/// settings (JS reads `undefined` from it); `null` throws in JS.
pub fn notification_config_from_json(parsed: &Value) -> Result<NotificationConfig, String> {
    if parsed.is_null() {
        return Err("Cannot read properties of null (reading 'relay_url')".to_string());
    }
    let setting = |name: &str| jsx::field(parsed, name);
    Ok(NotificationConfig {
        relay_url: normalize_relay_url(setting("relay_url"))
            .unwrap_or_else(|| DEFAULT_RELAY_URL.to_string()),
        debounce_ms: positive_int(setting("debounce_ms"), DEFAULT_DEBOUNCE_MS),
        activity_debounce_ms: positive_int(
            setting("activity_debounce_ms"),
            DEFAULT_ACTIVITY_DEBOUNCE_MS,
        ),
        activity_start_grace_ms: positive_int(
            setting("activity_start_grace_ms"),
            DEFAULT_ACTIVITY_START_GRACE_MS,
        ),
        retry_delay_ms: positive_int(setting("retry_delay_ms"), DEFAULT_RETRY_DELAY_MS),
        summary_enabled: setting("summary_enabled") == &Value::Bool(true),
        summary_command: normalize_summary_command(setting("summary_command")),
        summary_timeout_ms: positive_int(setting("summary_timeout_ms"), DEFAULT_SUMMARY_TIMEOUT_MS),
        tmux_enabled: setting("tmux_enabled") != &Value::Bool(false),
        core_enabled: setting("core_enabled") != &Value::Bool(false),
        zellij_enabled: setting("zellij_enabled") != &Value::Bool(false),
        codex_enabled: setting("codex_enabled") != &Value::Bool(false),
        opencode_enabled: setting("opencode_enabled") != &Value::Bool(false),
    })
}

/// Read the plugin-side `notify.json`. A missing relay URL uses the
/// production endpoint; an explicit URL remains available to self-built app
/// deployments. The error is the JS `TypeError` for a file holding `null`.
pub fn read_notification_config(config_dir: &str) -> Result<NotificationConfig, String> {
    let parsed = fs::read(jspath::join(&[config_dir, "notify.json"]))
        .ok()
        .and_then(|bytes| jsx::parse_json(&String::from_utf8_lossy(&bytes)))
        .unwrap_or_else(|| Value::Object(serde_json::Map::new()));
    notification_config_from_json(&parsed)
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU32, Ordering};

    use serde_json::{Value, json};

    use super::*;

    static COUNTER: AtomicU32 = AtomicU32::new(0);

    struct Dir(PathBuf);

    impl Dir {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "notification-config-{}-{}",
                std::process::id(),
                COUNTER.fetch_add(1, Ordering::SeqCst)
            ));
            fs::create_dir_all(&path).unwrap();
            Self(path)
        }

        fn write(&self, config: &Value) {
            fs::write(self.0.join("notify.json"), config.to_string()).unwrap();
        }

        fn read(&self) -> NotificationConfig {
            read_notification_config(self.0.to_str().unwrap()).unwrap()
        }
    }

    impl Drop for Dir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn uses_the_production_relay_when_notify_json_is_absent() {
        let dir = Dir::new();
        assert_eq!(dir.read().relay_url, DEFAULT_RELAY_URL);
    }

    #[test]
    fn preserves_an_explicit_custom_relay_and_normalizes_trailing_slashes() {
        let dir = Dir::new();
        dir.write(&json!({ "relay_url": " https://relay.example.com/// " }));
        assert_eq!(dir.read().relay_url, "https://relay.example.com");
    }

    #[test]
    fn migrates_the_retired_endpoint_to_production() {
        for legacy in LEGACY_DEFAULT_RELAY_URLS {
            let dir = Dir::new();
            dir.write(&json!({ "relay_url": format!("{legacy}/") }));
            assert_eq!(dir.read().relay_url, DEFAULT_RELAY_URL);
        }
    }

    #[test]
    fn uses_the_documented_debounce_and_retry_defaults() {
        let dir = Dir::new();
        assert_eq!(
            dir.read(),
            NotificationConfig {
                relay_url: DEFAULT_RELAY_URL.to_string(),
                debounce_ms: 5000,
                activity_debounce_ms: 1500,
                activity_start_grace_ms: 8000,
                retry_delay_ms: 1000,
                summary_enabled: false,
                summary_command: None,
                summary_timeout_ms: 15000,
                tmux_enabled: true,
                core_enabled: true,
                zellij_enabled: true,
                codex_enabled: true,
                opencode_enabled: true,
            }
        );
    }

    #[test]
    fn keeps_tmux_on_unless_notify_json_sets_tmux_enabled_to_false() {
        for (tmux_enabled, expected) in [
            (json!(false), false),
            (json!(true), true),
            (json!("false"), true),
            (json!(0), true),
            (Value::Null, true),
        ] {
            let dir = Dir::new();
            dir.write(&json!({ "tmux_enabled": tmux_enabled }));
            assert_eq!(
                dir.read().tmux_enabled,
                expected,
                "tmux_enabled: {tmux_enabled}"
            );
        }
    }

    #[test]
    fn keeps_core_on_unless_notify_json_sets_core_enabled_to_false() {
        for (core_enabled, expected) in [
            (json!(false), false),
            (json!(true), true),
            (json!("false"), true),
            (json!(0), true),
            (Value::Null, true),
        ] {
            let dir = Dir::new();
            dir.write(&json!({ "core_enabled": core_enabled }));
            assert_eq!(
                dir.read().core_enabled,
                expected,
                "core_enabled: {core_enabled}"
            );
        }
        // The two switches are independent.
        let dir = Dir::new();
        dir.write(&json!({ "tmux_enabled": false }));
        assert!(dir.read().core_enabled);
        dir.write(&json!({ "core_enabled": false }));
        assert!(dir.read().tmux_enabled);
    }

    #[test]
    fn preserves_an_explicit_activity_debounce_override() {
        let dir = Dir::new();
        dir.write(&json!({ "activity_debounce_ms": 250 }));
        assert_eq!(dir.read().activity_debounce_ms, 250);
    }

    #[test]
    fn honours_explicit_agent_summary_settings() {
        let dir = Dir::new();
        dir.write(&json!({
            "summary_enabled": true,
            "summary_command": ["llm", "-m", "", "--quiet"],
            "summary_timeout_ms": 4000,
        }));
        let config = dir.read();
        assert!(config.summary_enabled);
        assert_eq!(
            config.summary_command,
            Some(vec!["llm".into(), "-m".into(), "".into(), "--quiet".into()])
        );
        assert_eq!(config.summary_timeout_ms, 4000);
    }

    #[test]
    fn ignores_malformed_agent_summary_settings() {
        for summary_command in [
            json!("llm -m haiku"),
            json!([]),
            json!([""]),
            json!(["llm", 5]),
            json!({ "argv": ["llm"] }),
        ] {
            let dir = Dir::new();
            dir.write(&json!({
                "summary_enabled": "yes",
                "summary_command": summary_command,
                "summary_timeout_ms": -1,
            }));
            let config = dir.read();
            assert!(!config.summary_enabled);
            assert_eq!(config.summary_command, None);
            assert_eq!(config.summary_timeout_ms, 15000);
        }
    }

    #[test]
    fn a_file_holding_null_is_the_one_error() {
        let dir = Dir::new();
        fs::write(dir.0.join("notify.json"), "null").unwrap();
        assert!(read_notification_config(dir.0.to_str().unwrap()).is_err());
    }
}
