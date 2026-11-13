//! The part of chat-marker.js that `launch-rivals.js` needs: reading the Chat
//! Markers under `<plugin config dir>/chat/` and the named-herdr-sessions
//! check. The Chat milestone (M3) ports the rest of that module (deletion,
//! `markerApplies`, garbage collection) and extends this file.
//!
//! The app writes one marker per pane it launched in Chat Mode, and one per
//! plain launch that pins a session id, named by `pane_file_name` (the
//! unpadded base64url of the UTF-8 pane id plus `.json`). Content, v1,
//! snake_case: `{"v":1,"pane_id","terminal_id","kind","cwd","session":
//! {"kind":"id"|"path","value"}|null,"launched_at","prompt","chat_mode"}`.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use crate::atomic::pane_file_name;
use crate::env::Env;
use crate::js_json::{Json, parse};
use crate::paths::posix_join;

pub const CHAT_MARKER_VERSION: f64 = 1.0;
pub const CHAT_MARKERS_DIR: &str = "chat";

/// A marker's session: `kind` is `"id"` or `"path"`, `value` is not empty.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MarkerSession {
    pub kind: String,
    pub value: String,
}

/// The fields of a marker that launch-rivals reads (`terminal_id` and
/// `chat_mode` are the Chat milestone's). Malformed optional fields read as
/// `None`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Marker {
    pub pane_id: String,
    pub kind: String,
    pub cwd: Option<String>,
    pub session: Option<MarkerSession>,
    pub launched_at: Option<String>,
}

fn non_empty(value: Option<&Json>) -> Option<&str> {
    value.and_then(Json::as_str).filter(|text| !text.is_empty())
}

fn parse_marker(raw: &Json) -> Option<Marker> {
    let object = raw.as_object()?;
    match object.get("v") {
        Some(Json::Num(version)) if *version == CHAT_MARKER_VERSION => {}
        _ => return None,
    }
    let pane_id = non_empty(object.get("pane_id"))?;
    let kind = non_empty(object.get("kind"))?;
    let session = object.get("session").and_then(|session| {
        let kind = session.get("kind").and_then(Json::as_str)?;
        let value = non_empty(session.get("value"))?;
        matches!(kind, "id" | "path").then(|| MarkerSession {
            kind: kind.to_string(),
            value: value.to_string(),
        })
    });
    Some(Marker {
        pane_id: pane_id.to_string(),
        kind: kind.to_string(),
        cwd: non_empty(object.get("cwd")).map(str::to_string),
        session,
        launched_at: non_empty(object.get("launched_at")).map(str::to_string),
    })
}

fn read_marker_file(path: &Path) -> Option<Marker> {
    let bytes = fs::read(path).ok()?;
    parse_marker(&parse(&String::from_utf8_lossy(&bytes)).ok()?)
}

/// Every readable marker; corrupt, foreign-version and misnamed files are skipped.
pub fn list_markers(config_dir: &Path) -> Vec<Marker> {
    let dir = posix_join(&[config_dir, Path::new(CHAT_MARKERS_DIR)]);
    let Ok(entries) = fs::read_dir(&dir) else {
        return Vec::new();
    };
    // Temp files from `write_atomic` never end in `.json`, so they are skipped.
    let mut names: Vec<String> = entries
        .filter_map(|entry| entry.ok())
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .filter(|name| name.ends_with(".json"))
        .collect();
    names.sort_by(|a, b| a.encode_utf16().cmp(b.encode_utf16()));
    names
        .into_iter()
        .filter_map(|name| {
            let marker = read_marker_file(&dir.join(&name))?;
            (pane_file_name(&marker.pane_id) == name).then_some(marker)
        })
        .collect()
}

/// The directory holding herdr's named sessions: `$XDG_CONFIG_HOME/herdr/sessions`,
/// else `~/.config/herdr/sessions`.
pub fn herdr_sessions_dir(env: &Env) -> PathBuf {
    let sessions = |base: &Path, parts: &[&str]| {
        let mut all = vec![base];
        all.extend(parts.iter().map(Path::new));
        posix_join(&all)
    };
    if let Some(config_home) = env.get("XDG_CONFIG_HOME") {
        return sessions(Path::new(config_home), &["herdr", "sessions"]);
    }
    let home = env
        .get("HOME")
        .map(PathBuf::from)
        .or_else(std::env::home_dir)
        .unwrap_or_default();
    sessions(&home, &[".config", "herdr", "sessions"])
}

/// Whether any named herdr session exists on the machine (a
/// `<sessions_dir>/<name>/herdr.sock`). Every session shares the plugin
/// config dir, so the chat dir holds markers of panes one session's agent
/// list cannot see, and pane ids collide across sessions. An unreadable
/// sessions dir counts as none only when it is missing.
pub fn named_herdr_sessions_exist(sessions_dir: &Path) -> bool {
    let entries = match fs::read_dir(sessions_dir) {
        Ok(entries) => entries,
        Err(error) => return error.kind() != io::ErrorKind::NotFound,
    };
    entries
        .filter_map(|entry| entry.ok())
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .any(|name| posix_join(&[sessions_dir, Path::new(&name), Path::new("herdr.sock")]).exists())
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicUsize, Ordering};

    use super::*;

    static NEXT: AtomicUsize = AtomicUsize::new(0);

    struct Scratch(PathBuf);

    impl Scratch {
        fn new() -> Self {
            let dir = std::env::temp_dir().join(format!(
                "chat-marker-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir_all(dir.join("config")).unwrap();
            Self(dir)
        }

        fn config(&self) -> PathBuf {
            self.0.join("config")
        }

        fn write_raw(&self, name: &str, content: &str) {
            fs::create_dir_all(self.config().join("chat")).unwrap();
            fs::write(self.config().join("chat").join(name), content).unwrap();
        }

        fn write_marker(&self, pane_id: &str, fields: &str) {
            let base = format!(
                r#"{{"v":1,"pane_id":"{pane_id}","terminal_id":"term_1","kind":"claude","cwd":"/Users/me/proj","session":{{"kind":"id","value":"0f4c2d1e-0000-4000-8000-000000000001"}},"launched_at":"2026-09-30T09:00:00Z","chat_mode":true"#
            );
            let record = parse(&format!("{base}}}")).unwrap();
            let mut merged = record.as_object().unwrap().clone();
            if !fields.is_empty() {
                let extra = parse(fields).unwrap();
                for (key, value) in extra.as_object().unwrap().iter() {
                    merged.set(key, value.clone());
                }
            }
            self.write_raw(&pane_file_name(pane_id), &Json::Obj(merged).to_compact());
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn null_optional_fields_read_as_null_and_a_malformed_session_reads_as_none() {
        let host = Scratch::new();
        host.write_marker(
            "w1:p1",
            r#"{"cwd":null,"launched_at":null,"session":null,"terminal_id":null}"#,
        );
        host.write_marker("w1:p2", r#"{"session":{"kind":"bogus","value":"x"}}"#);
        host.write_marker("w1:p3", r#"{"session":{"kind":"path","value":""}}"#);
        host.write_marker(
            "w1:p4",
            r#"{"session":{"kind":"path","value":"/t.jsonl"},"cwd":""}"#,
        );
        let markers = list_markers(&host.config());
        let by_pane = |pane: &str| markers.iter().find(|m| m.pane_id == pane).unwrap();
        let first = by_pane("w1:p1");
        assert_eq!(
            (
                first.cwd.as_deref(),
                first.launched_at.as_deref(),
                first.session.as_ref()
            ),
            (None, None, None)
        );
        assert_eq!(by_pane("w1:p2").session, None);
        assert_eq!(by_pane("w1:p3").session, None);
        assert_eq!(
            by_pane("w1:p4").session,
            Some(MarkerSession {
                kind: "path".into(),
                value: "/t.jsonl".into()
            })
        );
        assert_eq!(by_pane("w1:p4").cwd, None);
        assert_eq!(
            by_pane("w1:p2").launched_at.as_deref(),
            Some("2026-09-30T09:00:00Z")
        );
    }

    #[test]
    fn listing_skips_corrupt_files_temp_files_and_misfiled_markers() {
        let host = Scratch::new();
        host.write_marker("w1:p1", "");
        host.write_marker("w1:p2", "");
        host.write_raw("corrupt.json", "{not json");
        host.write_raw("old.json", r#"{"v":2,"pane_id":"w9:p9","kind":"claude"}"#);
        host.write_raw("array.json", "[1]");
        host.write_raw("no-kind.json", r#"{"v":1,"pane_id":"w1:p7"}"#);
        host.write_raw(
            "misfiled.json",
            &fs::read_to_string(host.config().join("chat").join(pane_file_name("w1:p2"))).unwrap(),
        );
        host.write_raw(
            "w1p3.json.tmp-123",
            r#"{"v":1,"pane_id":"w1:p3","kind":"claude"}"#,
        );
        let panes: Vec<String> = list_markers(&host.config())
            .into_iter()
            .map(|m| m.pane_id)
            .collect();
        assert_eq!(panes, ["w1:p1", "w1:p2"]);
    }

    #[test]
    fn listing_a_host_that_never_wrote_a_marker_is_empty() {
        let host = Scratch::new();
        assert!(list_markers(&host.config()).is_empty());
        assert!(list_markers(&host.0.join("absent")).is_empty());
    }

    #[test]
    fn a_sessions_dir_without_a_live_socket_does_not_block() {
        let host = Scratch::new();
        fs::create_dir_all(host.0.join("sessions/stale")).unwrap();
        assert!(!named_herdr_sessions_exist(&host.0.join("sessions")));
        assert!(!named_herdr_sessions_exist(&host.0.join("absent")));
        fs::write(host.0.join("sessions/stale/herdr.sock"), "").unwrap();
        assert!(named_herdr_sessions_exist(&host.0.join("sessions")));
        // A sessions "dir" that is a file cannot be read: it counts as sessions.
        fs::write(host.0.join("plain"), "").unwrap();
        assert!(named_herdr_sessions_exist(&host.0.join("plain")));
    }

    #[test]
    fn the_sessions_dir_follows_xdg_config_home_else_home() {
        let env = |pairs: &[(&str, &str)]| {
            Env::from_pairs(pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())))
        };
        assert_eq!(
            herdr_sessions_dir(&env(&[("XDG_CONFIG_HOME", "/x"), ("HOME", "/h")])),
            Path::new("/x/herdr/sessions")
        );
        assert_eq!(
            herdr_sessions_dir(&env(&[("HOME", "/h")])),
            Path::new("/h/.config/herdr/sessions")
        );
        // An empty XDG_CONFIG_HOME is set, so it wins (and makes a relative path).
        assert_eq!(
            herdr_sessions_dir(&env(&[("XDG_CONFIG_HOME", ""), ("HOME", "/h")])),
            Path::new("herdr/sessions")
        );
    }
}
