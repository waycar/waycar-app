//! Chat Markers (chat-marker.js; README "Chat Markers").
//!
//! The app writes one marker per pane it launched in Chat Mode, and one per
//! plain launch that pins a session id (`chat_mode: false`), under
//! `<plugin config dir>/chat/`, named by [`pane_file_name`] (the unpadded
//! base64url of the UTF-8 pane id plus `.json`). Content, v1, snake_case:
//! `{"v":1,"pane_id":..,"terminal_id":..|null,"kind":..,"cwd":..|null,
//! "session":{"kind":"id"|"path","value":..}|null,"launched_at":..|null,
//! "prompt":..|null,"chat_mode":bool}`. `chat_mode` absent or not a boolean
//! reads as true. Node and Rust read each other's files: [`Marker::to_json`]
//! keeps the JS key order, [`gc_markers`] writes its stamp through
//! `write_atomic` with the JS mode.
//!
//! Paths are `&str`/`String` joined with `jspath` (the JS `path.join`).

use std::collections::HashSet;
use std::fs;
use std::io;
use std::path::Path;

use serde_json::{Map, Value};

use crate::atomic::{pane_file_name, write_atomic};
use crate::env::Env;
use crate::jspath;
use crate::jsx;

pub const CHAT_MARKER_VERSION: i64 = 1;
pub const CHAT_MARKERS_DIR: &str = "chat";
/// Garbage collection runs at most this often per Host.
pub const MARKER_GC_INTERVAL_MS: f64 = 60.0 * 60.0 * 1000.0;
/// A marker launched this recently survives garbage collection even when its
/// pane is missing from the agent list: the app writes it right after
/// `agent.start`, and a list fetched moments earlier cannot show that pane.
pub const MARKER_GC_GRACE_MS: f64 = 10.0 * 60.0 * 1000.0;

const GC_STAMP: &str = "chat-marker-gc.json";
/// Pane ids of the tmux backend (`tmux:%3`).
const TMUX_PREFIX: &str = "tmux:";
/// Pane ids of the herdr-core backend (`hc:t7`).
const CORE_PREFIX: &str = "hc:";

/// A marker's recorded session (`kind` is `"id"` or `"path"`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MarkerSession {
    pub kind: String,
    pub value: String,
}

/// A parsed marker; malformed optional fields read as `None`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Marker {
    pub pane_id: String,
    pub terminal_id: Option<String>,
    pub kind: String,
    pub cwd: Option<String>,
    pub session: Option<MarkerSession>,
    pub launched_at: Option<String>,
    pub chat_mode: bool,
}

impl Marker {
    /// The JS marker object, key order `v, pane_id, terminal_id, kind, cwd,
    /// session, launched_at, chat_mode` (`prompt` is not read).
    pub fn to_json(&self) -> Value {
        let text = |value: &Option<String>| value.clone().map_or(Value::Null, Value::String);
        let mut map = Map::new();
        map.insert("v".into(), Value::from(CHAT_MARKER_VERSION));
        map.insert("pane_id".into(), Value::String(self.pane_id.clone()));
        map.insert("terminal_id".into(), text(&self.terminal_id));
        map.insert("kind".into(), Value::String(self.kind.clone()));
        map.insert("cwd".into(), text(&self.cwd));
        map.insert(
            "session".into(),
            self.session.as_ref().map_or(Value::Null, |session| {
                let mut inner = Map::new();
                inner.insert("kind".into(), Value::String(session.kind.clone()));
                inner.insert("value".into(), Value::String(session.value.clone()));
                Value::Object(inner)
            }),
        );
        map.insert("launched_at".into(), text(&self.launched_at));
        map.insert("chat_mode".into(), Value::Bool(self.chat_mode));
        Value::Object(map)
    }
}

/// The Agent's live `agent_session`; `None` fields are JS `undefined`/`null`.
#[derive(Debug, Clone, Default)]
pub struct AgentSession<'a> {
    pub kind: Option<&'a str>,
    pub value: Option<&'a str>,
}

/// `markerApplies`'s second argument.
#[derive(Debug, Clone, Default)]
pub struct AppliesQuery<'a> {
    pub kind: Option<&'a str>,
    pub terminal_id: Option<&'a str>,
    pub agent_session: Option<AgentSession<'a>>,
}

/// `gcMarkers`'s options (`sessions_dir` is `herdrSessionsDir()` when the JS
/// caller omits it: pass [`herdr_sessions_dir`]).
pub struct GcOptions<'a> {
    pub config_dir: &'a str,
    pub state_dir: &'a str,
    /// The pane ids herdr lists now; `None` (herdr not asked: the trigger is
    /// not a herdr hook) keeps every herdr marker.
    pub live_pane_ids: Option<&'a [String]>,
    /// `None`: tmux disabled or not listable; every `tmux:` marker is kept.
    pub live_tmux_pane_ids: Option<&'a [String]>,
    /// The `hc:<address>` ids of the live herdr-core terminals; `None` (core
    /// disabled, absent or not listable) keeps every `hc:` marker.
    pub live_core_pane_ids: Option<&'a [String]>,
    /// Unknown Zellij inventory preserves every Zellij marker.
    pub live_zellij_pane_ids: Option<&'a [String]>,
    /// Unix ms.
    pub now: f64,
    pub sessions_dir: &'a str,
    pub on_skip: Option<&'a mut dyn FnMut()>,
}

pub fn marker_path(config_dir: &str, pane_id: &str) -> String {
    jspath::join(&[config_dir, CHAT_MARKERS_DIR, &pane_file_name(pane_id)])
}

/// A pane's marker, or `None` when it is missing, unreadable, from another
/// version, or recorded for a different pane.
pub fn read_marker(config_dir: &str, pane_id: &str) -> Option<Marker> {
    read_marker_file(&marker_path(config_dir, pane_id)).filter(|marker| marker.pane_id == pane_id)
}

/// Every readable marker; corrupt, foreign-version and misnamed files are
/// skipped.
pub fn list_markers(config_dir: &str) -> Vec<Marker> {
    let dir = jspath::join(&[config_dir, CHAT_MARKERS_DIR]);
    let Ok(entries) = fs::read_dir(&dir) else {
        return Vec::new();
    };
    let mut names: Vec<String> = entries
        .filter_map(Result::ok)
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .filter(|name| name.ends_with(".json"))
        .collect();
    // Array.prototype.sort compares UTF-16 code units.
    names.sort_by(|a, b| a.encode_utf16().cmp(b.encode_utf16()));
    let mut markers = Vec::new();
    for name in names {
        let path = jspath::join(&[&dir, &name]);
        if let Some(marker) = read_marker_file(&path)
            && pane_file_name(&marker.pane_id) == name
        {
            markers.push(marker);
        }
    }
    markers
}

/// `rmSync(path, { force: true })`: a missing file is fine.
pub fn delete_marker(config_dir: &str, pane_id: &str) -> io::Result<()> {
    match fs::remove_file(marker_path(config_dir, pane_id)) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        other => other,
    }
}

/// Whether `marker` describes the Agent now on its pane: same kind, and
/// either the marker's `terminal_id` is null or the Agent's, or the marker
/// records a session with the same kind and value as the Agent's live
/// `agent_session` (a chat herdr restored or resumed in a new terminal).
pub fn marker_applies(marker: Option<&Marker>, query: &AppliesQuery<'_>) -> bool {
    let (Some(marker), Some(kind)) = (marker, query.kind) else {
        return false;
    };
    if marker.kind != kind {
        return false;
    }
    match marker.terminal_id.as_deref() {
        None => return true,
        Some(terminal) if Some(terminal) == query.terminal_id => return true,
        Some(_) => {}
    }
    let (Some(recorded), Some(session)) = (&marker.session, &query.agent_session) else {
        return false;
    };
    let Some(value) = session.value else {
        return false;
    };
    !recorded.value.is_empty()
        && !value.is_empty()
        && session.kind == Some(recorded.kind.as_str())
        && recorded.value == value
}

/// Whether garbage collection is due: it last ran at least
/// [`MARKER_GC_INTERVAL_MS`] ago, never ran, or ran in the future.
pub fn marker_gc_due(state_dir: &str, now: f64) -> bool {
    let last_run = read_last_run(&jspath::join(&[state_dir, GC_STAMP]));
    !matches!(last_run, Some(last) if last <= now && now - last < MARKER_GC_INTERVAL_MS)
}

/// `$XDG_CONFIG_HOME/herdr/sessions`, else `~/.config/herdr/sessions`
/// (`home` stands for `os.homedir()` when `HOME` is unset).
pub fn herdr_sessions_dir(env: &Env, home: &str) -> String {
    if let Some(xdg) = env.get("XDG_CONFIG_HOME") {
        return jspath::join(&[xdg, "herdr", "sessions"]);
    }
    jspath::join(&[
        env.get("HOME").unwrap_or(home),
        ".config",
        "herdr",
        "sessions",
    ])
}

/// Whether any named herdr session exists (`<sessions_dir>/<name>/herdr.sock`).
/// An unreadable sessions dir counts as none only when it is missing.
pub fn named_herdr_sessions_exist(sessions_dir: &str) -> bool {
    let entries = match fs::read_dir(sessions_dir) {
        Ok(entries) => entries,
        Err(error) => return error.kind() != io::ErrorKind::NotFound,
    };
    // `readdirSync` fails as a whole on a read error; `read_dir` iterates, so
    // an entry error counts as the JS throw would (not ENOENT: exists).
    let mut names = Vec::new();
    for entry in entries {
        match entry {
            Ok(entry) => names.push(entry.file_name()),
            Err(error) => return error.kind() != io::ErrorKind::NotFound,
        }
    }
    names.iter().any(|name| {
        Path::new(sessions_dir)
            .join(name)
            .join("herdr.sock")
            .exists()
    })
}

/// Delete markers whose pane is not live, at most once per
/// [`MARKER_GC_INTERVAL_MS`]. Markers launched within [`MARKER_GC_GRACE_MS`]
/// of `now` are kept, and so are files this version cannot read. When named
/// herdr sessions exist nothing is deleted (the run is still stamped) and
/// `on_skip` is called once. Returns the pane ids whose markers were deleted.
pub fn gc_markers(options: GcOptions<'_>) -> io::Result<Vec<String>> {
    let GcOptions {
        config_dir,
        state_dir,
        live_pane_ids,
        live_tmux_pane_ids,
        live_core_pane_ids,
        live_zellij_pane_ids,
        now,
        sessions_dir,
        on_skip,
    } = options;
    if !marker_gc_due(state_dir, now) {
        return Ok(Vec::new());
    }
    fs::create_dir_all(state_dir)?;
    let mut stamp = Map::new();
    stamp.insert("ran_at".into(), json_number(now));
    write_atomic(
        Path::new(&jspath::join(&[state_dir, GC_STAMP])),
        jsx::stringify(&Value::Object(stamp)).as_bytes(),
        0o600,
    )?;

    if named_herdr_sessions_exist(sessions_dir) {
        if let Some(on_skip) = on_skip {
            on_skip();
        }
        return Ok(Vec::new());
    }
    fn live_set(ids: Option<&[String]>) -> Option<HashSet<&str>> {
        ids.map(|ids| ids.iter().map(String::as_str).collect())
    }
    let live_herdr = live_set(live_pane_ids);
    let live_tmux = live_set(live_tmux_pane_ids);
    let live_core = live_set(live_core_pane_ids);
    let live_zellij = live_set(live_zellij_pane_ids);
    let mut deleted = Vec::new();
    for marker in list_markers(config_dir) {
        // Each backend's markers are judged by its own list; a backend with no
        // list (disabled, absent, not answering) keeps its markers.
        let live = if marker.pane_id.starts_with(TMUX_PREFIX) {
            &live_tmux
        } else if marker.pane_id.starts_with("zellij:") {
            &live_zellij
        } else if marker.pane_id.starts_with(CORE_PREFIX) {
            &live_core
        } else {
            &live_herdr
        };
        match live {
            Some(set) if !set.contains(marker.pane_id.as_str()) => {}
            _ => continue,
        }
        let launched_at = marker.launched_at.as_deref().and_then(jsx::date_parse);
        if let Some(launched) = launched_at
            && now - launched < MARKER_GC_GRACE_MS
        {
            continue;
        }
        delete_marker(config_dir, &marker.pane_id)?;
        deleted.push(marker.pane_id);
    }
    Ok(deleted)
}

/// A JS number as JSON: integers stay integers.
fn json_number(value: f64) -> Value {
    if value.fract() == 0.0 && value.abs() < 9_007_199_254_740_992.0 {
        Value::from(value as i64)
    } else {
        serde_json::Number::from_f64(value).map_or(Value::Null, Value::Number)
    }
}

fn read_last_run(path: &str) -> Option<f64> {
    let bytes = fs::read(path).ok()?;
    let document = jsx::parse_json(&String::from_utf8_lossy(&bytes))?;
    match jsx::field(&document, "ran_at") {
        Value::Number(number) => Some(jsx::json_f64(number)).filter(|n| n.is_finite()),
        _ => None,
    }
}

fn read_marker_file(path: &str) -> Option<Marker> {
    let bytes = fs::read(path).ok()?;
    let raw = jsx::parse_json(&String::from_utf8_lossy(&bytes))?;
    parse_marker(&raw)
}

fn non_empty_string(value: &Value) -> Option<String> {
    value
        .as_str()
        .filter(|text| !text.is_empty())
        .map(str::to_owned)
}

fn parse_marker(raw: &Value) -> Option<Marker> {
    // `raw.v !== 1` also accepts `1.0`, which serde reads as a float.
    let version_ok = matches!(jsx::field(raw, "v"), Value::Number(n) if jsx::json_f64(n) == 1.0);
    if !raw.is_object() || !version_ok {
        return None;
    }
    let pane_id = non_empty_string(jsx::field(raw, "pane_id"))?;
    let kind = non_empty_string(jsx::field(raw, "kind"))?;
    let session = jsx::field(raw, "session");
    let session = match (
        session.is_object(),
        jsx::field(session, "kind").as_str(),
        non_empty_string(jsx::field(session, "value")),
    ) {
        (true, Some(kind @ ("id" | "path")), Some(value)) => Some(MarkerSession {
            kind: kind.to_owned(),
            value,
        }),
        _ => None,
    };
    Some(Marker {
        pane_id,
        terminal_id: non_empty_string(jsx::field(raw, "terminal_id")),
        kind,
        cwd: non_empty_string(jsx::field(raw, "cwd")),
        session,
        launched_at: non_empty_string(jsx::field(raw, "launched_at")),
        chat_mode: jsx::field(raw, "chat_mode") != &Value::Bool(false),
    })
}

#[cfg(test)]
mod tests {
    use std::cell::Cell;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU32, Ordering};

    use serde_json::json;

    use super::*;

    const NOW: f64 = 1_790_769_600_000.0; // 2026-09-30T12:00:00Z

    struct Sandbox {
        home: PathBuf,
        config_dir: String,
        state_dir: String,
        sessions_dir: String,
    }

    impl Sandbox {
        fn new() -> Self {
            static COUNTER: AtomicU32 = AtomicU32::new(0);
            let home = std::env::temp_dir().join(format!(
                "wc-marker-{}-{}",
                std::process::id(),
                COUNTER.fetch_add(1, Ordering::SeqCst)
            ));
            let text = |name: &str| home.join(name).to_string_lossy().into_owned();
            let sandbox = Self {
                config_dir: text("config"),
                state_dir: text("state"),
                sessions_dir: text("sessions"),
                home: home.clone(),
            };
            fs::create_dir_all(&sandbox.config_dir).unwrap();
            sandbox
        }

        fn write_marker(&self, pane_id: &str, fields: &[(&str, Option<Value>)]) {
            fs::create_dir_all(self.home.join("config/chat")).unwrap();
            fs::write(
                marker_path(&self.config_dir, pane_id),
                jsx::stringify(&marker_json(pane_id, fields)),
            )
            .unwrap();
        }

        fn write_raw(&self, name: &str, content: &str) {
            fs::create_dir_all(self.home.join("config/chat")).unwrap();
            fs::write(self.home.join("config/chat").join(name), content).unwrap();
        }

        fn add_named_session(&self, name: &str) {
            let dir = self.home.join("sessions").join(name);
            fs::create_dir_all(&dir).unwrap();
            fs::write(dir.join("herdr.sock"), "").unwrap();
        }

        fn panes(&self) -> Vec<String> {
            list_markers(&self.config_dir)
                .into_iter()
                .map(|marker| marker.pane_id)
                .collect()
        }

        /// `gcMarkers` against a sandboxed herdr sessions dir.
        fn gc(&self, live: &[&str], tmux: Option<&[&str]>, now: f64) -> Vec<String> {
            self.gc_counting(live, tmux, now, &Cell::new(0))
        }

        fn gc_counting(
            &self,
            live: &[&str],
            tmux: Option<&[&str]>,
            now: f64,
            skips: &Cell<u32>,
        ) -> Vec<String> {
            self.gc_lists(Some(live), tmux, None, now, skips)
        }

        /// `gc_markers` with each backend's live list given (`None`: not asked).
        fn gc_lists(
            &self,
            herdr: Option<&[&str]>,
            tmux: Option<&[&str]>,
            core: Option<&[&str]>,
            now: f64,
            skips: &Cell<u32>,
        ) -> Vec<String> {
            let owned = |ids: Option<&[&str]>| -> Option<Vec<String>> {
                ids.map(|ids| ids.iter().map(|id| id.to_string()).collect())
            };
            let (herdr, tmux, core) = (owned(herdr), owned(tmux), owned(core));
            let mut on_skip = || skips.set(skips.get() + 1);
            gc_markers(GcOptions {
                config_dir: &self.config_dir,
                state_dir: &self.state_dir,
                live_pane_ids: herdr.as_deref(),
                live_tmux_pane_ids: tmux.as_deref(),
                live_core_pane_ids: core.as_deref(),
                live_zellij_pane_ids: None,
                now,
                sessions_dir: &self.sessions_dir,
                on_skip: Some(&mut on_skip),
            })
            .unwrap()
        }
    }

    impl Drop for Sandbox {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.home);
        }
    }

    #[test]
    fn zellij_markers_follow_their_own_inventory_and_survive_unknown() {
        for live in [
            None,
            Some(vec!["zellij:work/terminal_0".to_string()]),
            Some(Vec::new()),
        ] {
            let sb = Sandbox::new();
            let id = "zellij:work/terminal_0";
            sb.write_marker(id, &[]);
            let deleted = gc_markers(GcOptions {
                config_dir: &sb.config_dir,
                state_dir: &sb.state_dir,
                live_pane_ids: Some(&[]),
                live_tmux_pane_ids: Some(&[]),
                live_core_pane_ids: Some(&[]),
                live_zellij_pane_ids: live.as_deref(),
                now: NOW,
                sessions_dir: &sb.sessions_dir,
                on_skip: None,
            })
            .unwrap();
            assert_eq!(
                deleted.is_empty(),
                live.as_ref().is_none_or(|v| !v.is_empty())
            );
        }
    }

    /// The JS test's `marker(paneId, fields)`: `None` removes the key
    /// (`undefined`).
    fn marker_json(pane_id: &str, fields: &[(&str, Option<Value>)]) -> Value {
        let mut map = Map::new();
        for (key, value) in [
            ("v", json!(1)),
            ("pane_id", json!(pane_id)),
            ("terminal_id", json!("term_1")),
            ("kind", json!("claude")),
            ("cwd", json!("/Users/me/proj")),
            (
                "session",
                json!({"kind": "id", "value": "0f4c2d1e-0000-4000-8000-000000000001"}),
            ),
            ("launched_at", json!("2026-09-30T09:00:00Z")),
            ("chat_mode", json!(true)),
        ] {
            map.insert(key.into(), value);
        }
        for (key, value) in fields {
            match value {
                Some(value) => {
                    map.insert((*key).into(), value.clone());
                }
                None => {
                    map.shift_remove(*key);
                }
            }
        }
        Value::Object(map)
    }

    fn expected(pane_id: &str) -> Marker {
        parse_marker(&marker_json(pane_id, &[])).unwrap()
    }

    fn some(value: Value) -> Option<Value> {
        Some(value)
    }

    fn query<'a>(kind: Option<&'a str>, terminal_id: Option<&'a str>) -> AppliesQuery<'a> {
        AppliesQuery {
            kind,
            terminal_id,
            agent_session: None,
        }
    }

    // MARK: reading

    #[test]
    fn a_marker_is_found_under_chat_by_the_panes_base64url_file_name() {
        let sandbox = Sandbox::new();
        sandbox.write_marker("w1:p1", &[]);

        assert_eq!(
            marker_path(&sandbox.config_dir, "w1:p1"),
            format!("{}/chat/dzE6cDE.json", sandbox.config_dir)
        );
        assert_eq!(
            read_marker(&sandbox.config_dir, "w1:p1"),
            Some(expected("w1:p1"))
        );
    }

    #[test]
    fn null_optional_fields_read_as_null_and_a_malformed_session_reads_as_none() {
        let sandbox = Sandbox::new();
        sandbox.write_marker(
            "w1:p1",
            &[
                ("terminal_id", some(Value::Null)),
                ("cwd", some(Value::Null)),
                ("session", some(json!({"kind": "uuid", "value": "x"}))),
            ],
        );

        let read = read_marker(&sandbox.config_dir, "w1:p1").unwrap();

        assert_eq!(read.terminal_id, None);
        assert_eq!(read.cwd, None);
        assert_eq!(read.session, None);
        assert_eq!(read.kind, "claude");
    }

    #[test]
    fn a_marker_carrying_the_chat_prompt_field_reads_unchanged() {
        let sandbox = Sandbox::new();
        sandbox.write_marker(
            "w1:p1",
            &[("prompt", some(json!("Be terse. One paragraph.")))],
        );

        assert_eq!(
            read_marker(&sandbox.config_dir, "w1:p1"),
            Some(expected("w1:p1"))
        );
        assert_eq!(sandbox.panes(), ["w1:p1"]);
    }

    #[test]
    fn chat_mode_reads_false_only_when_false_absent_or_malformed_is_a_chat_mode_marker() {
        let sandbox = Sandbox::new();
        sandbox.write_marker(
            "w1:p1",
            &[
                ("chat_mode", some(json!(false))),
                ("prompt", some(Value::Null)),
            ],
        );
        assert!(!read_marker(&sandbox.config_dir, "w1:p1").unwrap().chat_mode);
        assert!(
            !list_markers(&sandbox.config_dir)[0].chat_mode,
            "listed, so collected like any marker"
        );
        for value in [
            None,
            some(json!("false")),
            some(json!(0)),
            some(Value::Null),
        ] {
            sandbox.write_marker("w1:p1", &[("chat_mode", value.clone())]);
            assert!(
                read_marker(&sandbox.config_dir, "w1:p1").unwrap().chat_mode,
                "{value:?}"
            );
        }
    }

    #[test]
    fn a_missing_corrupt_foreign_version_or_misfiled_marker_reads_as_none() {
        let sandbox = Sandbox::new();
        assert_eq!(read_marker(&sandbox.config_dir, "w1:p1"), None);

        sandbox.write_raw("dzE6cDE.json", "{not json");
        assert_eq!(read_marker(&sandbox.config_dir, "w1:p1"), None);

        sandbox.write_marker("w1:p1", &[("v", some(json!(2)))]);
        assert_eq!(read_marker(&sandbox.config_dir, "w1:p1"), None);

        sandbox.write_marker("w1:p1", &[("kind", some(json!("")))]);
        assert_eq!(read_marker(&sandbox.config_dir, "w1:p1"), None);

        // The file for w1:p1 holding another pane's marker does not apply to w1:p1.
        sandbox.write_raw("dzE6cDE.json", &jsx::stringify(&marker_json("w2:p2", &[])));
        assert_eq!(read_marker(&sandbox.config_dir, "w1:p1"), None);
    }

    #[test]
    fn listing_skips_corrupt_files_temp_files_and_misfiled_markers() {
        let sandbox = Sandbox::new();
        sandbox.write_marker("w1:p1", &[]);
        sandbox.write_marker("w1:p2", &[]);
        sandbox.write_raw("broken.json", "{");
        sandbox.write_raw(
            "dzE6cDM.json.tmp-123",
            &jsx::stringify(&marker_json("w1:p3", &[])),
        );
        sandbox.write_raw("dzE6cDk.json", &jsx::stringify(&marker_json("w1:p4", &[])));

        let mut panes = sandbox.panes();
        panes.sort();

        assert_eq!(panes, ["w1:p1", "w1:p2"]);
    }

    #[test]
    fn listing_a_host_that_never_wrote_a_marker_is_empty() {
        let sandbox = Sandbox::new();
        assert!(list_markers(&sandbox.config_dir).is_empty());
    }

    #[test]
    fn deleting_removes_only_that_panes_marker() {
        let sandbox = Sandbox::new();
        sandbox.write_marker("w1:p1", &[]);
        sandbox.write_marker("w1:p2", &[]);

        delete_marker(&sandbox.config_dir, "w1:p1").unwrap();
        delete_marker(&sandbox.config_dir, "w1:p1").unwrap();

        assert_eq!(read_marker(&sandbox.config_dir, "w1:p1"), None);
        assert!(read_marker(&sandbox.config_dir, "w1:p2").is_some());
    }

    // MARK: applies

    #[test]
    fn a_marker_applies_to_the_same_kind_on_the_recorded_terminal() {
        let entry = expected("w1:p1");
        assert!(marker_applies(
            Some(&entry),
            &query(Some("claude"), Some("term_1"))
        ));
        assert!(!marker_applies(
            Some(&entry),
            &query(Some("codex"), Some("term_1"))
        ));
        assert!(!marker_applies(
            Some(&entry),
            &query(Some("claude"), Some("term_2"))
        ));
        assert!(!marker_applies(Some(&entry), &query(None, Some("term_1"))));
        assert!(!marker_applies(
            None,
            &query(Some("claude"), Some("term_1"))
        ));
    }

    #[test]
    fn a_marker_without_a_terminal_applies_to_any_terminal_of_its_kind() {
        let entry =
            parse_marker(&marker_json("w1:p1", &[("terminal_id", some(Value::Null))])).unwrap();
        assert!(marker_applies(
            Some(&entry),
            &query(Some("claude"), Some("term_9"))
        ));
        assert!(marker_applies(Some(&entry), &query(Some("claude"), None)));
    }

    #[test]
    fn a_marker_with_a_session_applies_in_a_new_terminal_running_that_session() {
        let entry = parse_marker(&marker_json(
            "w1:p1",
            &[(
                "session",
                some(json!({"kind": "path", "value": "/s/a.jsonl"})),
            )],
        ))
        .unwrap();
        let at = |session: Option<(&str, &str)>, kind: &str| {
            marker_applies(
                Some(&entry),
                &AppliesQuery {
                    kind: Some(kind),
                    terminal_id: Some("term_2"),
                    agent_session: session.map(|(kind, value)| AgentSession {
                        kind: Some(kind),
                        value: Some(value),
                    }),
                },
            )
        };
        assert!(at(Some(("path", "/s/a.jsonl")), "claude"));
        assert!(!at(Some(("path", "/s/b.jsonl")), "claude"));
        assert!(!at(Some(("id", "/s/a.jsonl")), "claude"));
        assert!(!at(Some(("path", "/s/a.jsonl")), "codex"));
        assert!(!at(Some(("path", "")), "claude"));
        assert!(!at(None, "claude"));
    }

    #[test]
    fn a_marker_without_a_session_does_not_apply_in_a_new_terminal() {
        let entry = parse_marker(&marker_json("w1:p1", &[("session", some(Value::Null))])).unwrap();
        let live = AgentSession {
            kind: Some("path"),
            value: Some("/s/a.jsonl"),
        };
        let query = AppliesQuery {
            kind: Some("claude"),
            terminal_id: Some("term_2"),
            agent_session: Some(live),
        };
        assert!(!marker_applies(Some(&entry), &query));
    }

    // MARK: garbage collection

    #[test]
    fn markers_of_panes_herdr_no_longer_lists_are_deleted_live_ones_stay() {
        let sandbox = Sandbox::new();
        for pane in ["w1:p1", "w1:p2", "w1:p3"] {
            sandbox.write_marker(pane, &[]);
        }

        let mut deleted = sandbox.gc(&["w1:p2", "w5:p5"], None, NOW);
        deleted.sort();

        assert_eq!(deleted, ["w1:p1", "w1:p3"]);
        assert_eq!(sandbox.panes(), ["w1:p2"]);
    }

    // The tmux transport writes its markers into the same dir; herdr never lists them.
    #[test]
    fn a_tmux_marker_is_kept_while_its_tmux_pane_exists_deleted_once_it_is_gone() {
        let sandbox = Sandbox::new();
        for pane in ["tmux:%3", "tmux:%9", "w1:p1"] {
            sandbox.write_marker(pane, &[]);
        }

        let deleted = sandbox.gc(&["w1:p1"], Some(&["tmux:%3"]), NOW);

        assert_eq!(deleted, ["tmux:%9"]);
        let mut panes = sandbox.panes();
        panes.sort();
        assert_eq!(panes, ["tmux:%3", "w1:p1"]);
    }

    #[test]
    fn tmux_markers_are_all_kept_when_tmux_panes_cannot_be_listed() {
        let sandbox = Sandbox::new();
        for pane in ["tmux:%3", "tmux:%9", "w1:p1"] {
            sandbox.write_marker(pane, &[]);
        }

        let deleted = sandbox.gc(&[], None, NOW);

        assert_eq!(deleted, ["w1:p1"]);
        let mut panes = sandbox.panes();
        panes.sort();
        assert_eq!(panes, ["tmux:%3", "tmux:%9"]);
    }

    // herdr lists no `hc:` pane, so a herdr hook's collection must leave a
    // core marker alone: core has its own list.
    #[test]
    fn gc_never_deletes_a_core_marker_because_herdr_does_not_list_it() {
        let sandbox = Sandbox::new();
        for pane in ["hc:t1", "hc:box/t2", "w1:p1"] {
            sandbox.write_marker(pane, &[]);
        }

        let deleted = sandbox.gc(&[], Some(&[]), NOW);

        assert_eq!(deleted, ["w1:p1"]);
        let mut panes = sandbox.panes();
        panes.sort();
        assert_eq!(panes, ["hc:box/t2", "hc:t1"]);
    }

    #[test]
    fn gc_keeps_live_core_markers_and_deletes_dead_ones() {
        let sandbox = Sandbox::new();
        for pane in ["hc:t1", "hc:t2", "tmux:%3", "w1:p1"] {
            sandbox.write_marker(pane, &[]);
        }

        let deleted = sandbox.gc_lists(None, None, Some(&["hc:t1"]), NOW, &Cell::new(0));

        // Only the core list was given: tmux and herdr markers stay.
        assert_eq!(deleted, ["hc:t2"]);
        let mut panes = sandbox.panes();
        panes.sort();
        assert_eq!(panes, ["hc:t1", "tmux:%3", "w1:p1"]);
    }

    #[test]
    fn gc_keeps_every_core_marker_when_core_cannot_list() {
        let sandbox = Sandbox::new();
        for pane in ["hc:t1", "hc:t2", "w1:p1"] {
            sandbox.write_marker(pane, &[]);
        }

        let deleted = sandbox.gc_lists(Some(&[]), None, None, NOW, &Cell::new(0));

        assert_eq!(deleted, ["w1:p1"]);
        let mut panes = sandbox.panes();
        panes.sort();
        assert_eq!(panes, ["hc:t1", "hc:t2"]);
    }

    #[test]
    fn gc_keeps_a_fresh_core_marker_the_listing_cannot_show_yet() {
        let sandbox = Sandbox::new();
        let iso = |time: f64| jsx::to_iso_string(time).unwrap();
        sandbox.write_marker(
            "hc:t9",
            &[(
                "launched_at",
                some(json!(iso(NOW - MARKER_GC_GRACE_MS + 1_000.0))),
            )],
        );
        sandbox.write_marker(
            "hc:t8",
            &[("launched_at", some(json!(iso(NOW - MARKER_GC_GRACE_MS))))],
        );

        let deleted = sandbox.gc_lists(None, None, Some(&[]), NOW, &Cell::new(0));

        assert_eq!(deleted, ["hc:t8"]);
        assert_eq!(sandbox.panes(), ["hc:t9"]);
    }

    #[test]
    fn it_runs_at_most_once_an_hour() {
        let sandbox = Sandbox::new();
        sandbox.write_marker("w1:p1", &[]);
        assert!(marker_gc_due(&sandbox.state_dir, NOW));
        assert_eq!(sandbox.gc(&[], None, NOW), ["w1:p1"]);

        sandbox.write_marker("w1:p2", &[]);
        assert!(!marker_gc_due(
            &sandbox.state_dir,
            NOW + MARKER_GC_INTERVAL_MS - 1.0
        ));
        let soon = sandbox.gc(&[], None, NOW + MARKER_GC_INTERVAL_MS - 1.0);
        assert!(soon.is_empty());
        assert!(read_marker(&sandbox.config_dir, "w1:p2").is_some());

        assert!(marker_gc_due(
            &sandbox.state_dir,
            NOW + MARKER_GC_INTERVAL_MS
        ));
        let later = sandbox.gc(&[], None, NOW + MARKER_GC_INTERVAL_MS);
        assert_eq!(later, ["w1:p2"]);
    }

    #[test]
    fn a_clock_that_moved_back_does_not_stall_collection() {
        let sandbox = Sandbox::new();
        sandbox.gc(&[], None, NOW);
        sandbox.write_marker("w1:p1", &[]);

        assert_eq!(sandbox.gc(&[], None, NOW - 5_000.0), ["w1:p1"]);
    }

    #[test]
    fn a_marker_launched_moments_ago_survives_until_its_pane_can_be_listed() {
        let sandbox = Sandbox::new();
        let iso = |time: f64| jsx::to_iso_string(time).unwrap();
        sandbox.write_marker(
            "w1:fresh",
            &[(
                "launched_at",
                some(json!(iso(NOW - MARKER_GC_GRACE_MS + 1_000.0))),
            )],
        );
        sandbox.write_marker(
            "w1:old",
            &[("launched_at", some(json!(iso(NOW - MARKER_GC_GRACE_MS))))],
        );
        sandbox.write_marker("w1:undated", &[("launched_at", some(Value::Null))]);

        let mut deleted = sandbox.gc(&[], None, NOW);
        deleted.sort();

        assert_eq!(deleted, ["w1:old", "w1:undated"]);
        assert!(read_marker(&sandbox.config_dir, "w1:fresh").is_some());
    }

    #[test]
    fn files_it_cannot_read_are_left_alone() {
        let sandbox = Sandbox::new();
        sandbox.write_raw("broken.json", "{");
        sandbox.write_marker("w1:p1", &[("v", some(json!(2)))]);

        assert!(sandbox.gc(&[], None, NOW).is_empty());
        assert!(sandbox.home.join("config/chat/broken.json").exists());
        assert!(Path::new(&marker_path(&sandbox.config_dir, "w1:p1")).exists());
    }

    // The chat dir is shared by every session, whose pane ids collide.
    #[test]
    fn named_herdr_sessions_block_deletion_and_report_it_once_per_run() {
        let sandbox = Sandbox::new();
        sandbox.write_marker("w1:p1", &[]);
        sandbox.add_named_session("work");
        let skips = Cell::new(0);

        assert!(sandbox.gc_counting(&[], None, NOW, &skips).is_empty());
        assert_eq!(skips.get(), 1);
        assert!(read_marker(&sandbox.config_dir, "w1:p1").is_some());

        // The run is stamped, so the next hour is quiet too.
        assert!(
            sandbox
                .gc_counting(&[], None, NOW + 1_000.0, &skips)
                .is_empty()
        );
        assert_eq!(skips.get(), 1);
    }

    #[test]
    fn a_sessions_dir_without_a_live_socket_does_not_block_deletion() {
        let sandbox = Sandbox::new();
        sandbox.write_marker("w1:p1", &[]);
        fs::create_dir_all(sandbox.home.join("sessions/stale")).unwrap();

        assert!(!named_herdr_sessions_exist(&sandbox.sessions_dir));
        assert!(!named_herdr_sessions_exist(
            &sandbox.home.join("absent").to_string_lossy()
        ));
        assert_eq!(sandbox.gc(&[], None, NOW), ["w1:p1"]);
    }

    #[test]
    fn the_sessions_dir_follows_xdg_config_home_else_home() {
        let both = Env::from_pairs([("XDG_CONFIG_HOME", "/x"), ("HOME", "/h")]);
        assert_eq!(herdr_sessions_dir(&both, "/fallback"), "/x/herdr/sessions");
        let home_only = Env::from_pairs([("HOME", "/h")]);
        assert_eq!(
            herdr_sessions_dir(&home_only, "/fallback"),
            "/h/.config/herdr/sessions"
        );
        assert_eq!(
            herdr_sessions_dir(&Env::default(), "/fallback"),
            "/fallback/.config/herdr/sessions"
        );
    }

    #[test]
    fn a_marker_written_by_the_app_round_trips_through_to_json_in_key_order() {
        let entry = expected("w1:p1");
        assert_eq!(
            jsx::stringify(&entry.to_json()),
            r#"{"v":1,"pane_id":"w1:p1","terminal_id":"term_1","kind":"claude","cwd":"/Users/me/proj","session":{"kind":"id","value":"0f4c2d1e-0000-4000-8000-000000000001"},"launched_at":"2026-09-30T09:00:00Z","chat_mode":true}"#
        );
    }
}
