//! Muse Code transcript reader (chat-readers/muse.js; live-verified on 1.4.6,
//! docs/research/harnesses/muse.md): `$XDG_DATA_HOME/muse` (default
//! `~/.local/share/muse`) `/sessions/<YYYY>/<MM>/<DD>/<session id>/
//! session.jsonl`, an append-only event log; resume appends to the same file.
//!
//! Each line is a record `{schema_version, id, stream, sequence, recorded_at
//! (epoch us), payload_type, payload}`; a `retained_frame` line wraps child
//! records as JSON strings. The chat is:
//! - `runtime.user_intent.accepted` on the `main` surface: a prompt, its
//!   `model_messages` content `text` blocks and `asset` blocks (an attached
//!   image, stored under the session's `input-assets/v1/sha256/<2>/<digest>`);
//!   its `intent_id` is the run id of the turn it starts,
//! - `runtime.session` run events of those runs: `assistant_message_committed`
//!   (reply text), `assistant_tool_calls_committed`, `reasoning_committed`,
//!   and `terminal` (`terminal: "completed"`, else an interrupted or failed
//!   turn).
//!
//! `runtime.session.metadata` names the workspace root; a subagent's session
//! has another `root_session_id` in `agent_tree_initialized`.
//!
//! # Differences from the JS
//!
//! An asset `digest` that is not a string never matches (the JS regex test
//! would coerce an array to a string and then throw on `path.join`).

use std::collections::HashSet;

use serde_json::{Map, Value, json};

use crate::chat::readers::hermes::js_string;
use crate::chat::readers::{LaunchQuery, Reader, ReaderContext};
use crate::chat::shared::{
    ChatError, ChatResult, ChatTurns, Found, PROBE_LINES, PickArgs, Prompt, ToolCall, expand_home,
    newest_file, pick_by_launch, read_records, stat_file, subdirectories, tool_activity,
};
use crate::env::Env;
use crate::{jspath, jsx};

const DAY_MS: f64 = 24.0 * 60.0 * 60_000.0;

pub const READER: Reader = Reader {
    root,
    find_by_id,
    find_by_launch: Some(find_by_launch),
    resolve_path: None,
    parse,
};

fn root(env: &Env, home: &str) -> String {
    let data = match env.non_empty("XDG_DATA_HOME") {
        Some(dir) => expand_home(dir, home),
        None => jspath::join(&[home, ".local", "share"]),
    };
    jspath::join(&[&data, "muse"])
}

/// Every `sessions/<YYYY>/<MM>/<DD>` directory.
fn day_directories(base: &str) -> Vec<String> {
    let mut days = Vec::new();
    for year in subdirectories(&jspath::join(&[base, "sessions"])) {
        for month in subdirectories(&year) {
            days.extend(subdirectories(&month));
        }
    }
    days
}

fn find_by_id(id: &str, root: &str) -> ChatResult<Option<String>> {
    let candidates: Vec<String> = day_directories(root)
        .iter()
        .map(|day| jspath::join(&[day, id, "session.jsonl"]))
        .collect();
    Ok(newest_file(&candidates))
}

/// Sessions from the days around the launch (the directory date is the
/// session's creation day).
fn find_by_launch(query: &LaunchQuery<'_>) -> ChatResult<Option<String>> {
    let Some(launched) = query.launched_at.filter(|t| t.is_finite()) else {
        return Ok(None);
    };
    let mut near = HashSet::new();
    for offset in [-1.0, 0.0, 1.0] {
        let iso = jsx::to_iso_string(launched + offset * DAY_MS)
            .ok_or_else(|| ChatError::other("Invalid time value"))?;
        near.insert(iso.chars().take(10).collect::<String>().replace('-', "/"));
    }
    let sessions = jspath::join(&[query.root, "sessions"]);
    let mut files = Vec::new();
    for day in day_directories(query.root) {
        if !near.contains(&jspath::relative(&sessions, &day)) {
            continue;
        }
        for session in subdirectories(&day) {
            files.push(jspath::join(&[&session, "session.jsonl"]));
        }
    }
    pick_by_launch(&PickArgs {
        files: &files,
        probe: &|file| Ok(probe(file)),
        cwd: query.cwd,
        launched_at: query.launched_at,
        home: query.home,
        window: false,
        cwd_matches: None,
        stat: None,
    })
}

/// The workspace root and the first record's time; None for a subagent's session.
fn probe(file: &str) -> Option<Found> {
    let mut cwd: Option<String> = None;
    let mut created: Option<f64> = None;
    let id = jspath::basename(&jspath::dirname(file)).to_string();
    for item in read_records(file, None).ok()? {
        let item = item.ok()?;
        if item.line > PROBE_LINES {
            break;
        }
        for entry in unwrap(&item.record) {
            if created.is_none() {
                created = record_time(&entry);
            }
            let payload = jsx::field(&entry, "payload");
            if jsx::field(&entry, "payload_type").as_str() == Some("runtime.session.metadata")
                && let Some(root) =
                    jsx::field(jsx::field(payload, "record"), "workspace_root").as_str()
            {
                cwd = Some(root.to_string());
            }
            if jsx::field(payload, "kind").as_str() == Some("agent_tree_initialized") {
                let root_id = jsx::field(jsx::field(payload, "record"), "root_session_id");
                if jsx::truthy(root_id) && root_id.as_str() != Some(id.as_str()) {
                    return None;
                }
            }
        }
        if cwd.is_some() {
            return Some(Found { cwd, created });
        }
    }
    None
}

/// A record, or a `retained_frame`'s child records.
fn unwrap(record: &Value) -> Vec<Value> {
    let Some(children) = jsx::field(record, "children").as_array() else {
        return vec![record.clone()];
    };
    let mut out = Vec::new();
    for child in children {
        let source = jsx::field(child, "record_json");
        // `JSON.parse(undefined)` throws, like any malformed child.
        if source.is_null() && jsx::get(child, "record_json").is_none() {
            continue;
        }
        if let Some(parsed) = jsx::parse_json(&js_string(source))
            && (parsed.is_object() || parsed.is_array())
        {
            out.push(parsed);
        }
    }
    out
}

/// Epoch milliseconds from `recorded_at` (us).
fn record_time(record: &Value) -> Option<f64> {
    match jsx::field(record, "recorded_at") {
        Value::Number(n) if jsx::json_f64(n).is_finite() => {
            Some((jsx::json_f64(n) / 1000.0).floor())
        }
        _ => None,
    }
}

fn parse(file: &str, ctx: &ReaderContext<'_>, turns: &mut ChatTurns) -> ChatResult<()> {
    let session_dir = jspath::dirname(&jspath::resolve(&[file]));
    // Run ids of main-surface intents; another run (a side chat) is not this chat.
    let mut runs: HashSet<String> = HashSet::new();
    let mut running: Option<String> = None;
    for item in read_records(file, ctx.signal)? {
        let item = item?;
        for entry in unwrap(&item.record) {
            let id = match jsx::field(&entry, "id") {
                Value::String(id) if !id.is_empty() => id.as_str(),
                _ => continue,
            };
            let payload = jsx::field(&entry, "payload");
            let ts = record_time(&entry);
            if !(payload.is_object() || payload.is_array()) {
                continue;
            }
            if jsx::field(&entry, "payload_type").as_str() == Some("runtime.user_intent.accepted") {
                let Some(intent) = jsx::field(payload, "intent_id").as_str() else {
                    continue;
                };
                if jsx::field(payload, "surface").as_str() != Some("main") {
                    continue;
                }
                runs.insert(intent.to_string());
                let messages = jsx::field(payload, "model_messages")
                    .as_array()
                    .map_or(&[][..], Vec::as_slice);
                let content: Vec<&Value> = messages
                    .iter()
                    .flat_map(|message| {
                        jsx::field(message, "content")
                            .as_array()
                            .map_or(&[][..], Vec::as_slice)
                    })
                    .collect();
                let joined = content
                    .iter()
                    .filter(|block| jsx::field(block, "kind").as_str() == Some("text"))
                    .filter_map(|block| jsx::field(block, "text").as_str())
                    .collect::<Vec<_>>()
                    .join("\n");
                let text = jsx::trim(&joined);
                let chat = jsx::field(jsx::field(payload, "semantic_kind"), "kind").as_str()
                    == Some("chat");
                turns.prompt(Prompt {
                    id,
                    text,
                    ts,
                    hidden: !chat || text.is_empty(),
                    steering: running.is_some(),
                    ..Prompt::default()
                });
                for block in content {
                    if let Some((item, key)) = asset_media(block, &session_dir) {
                        turns.media_item(item, Some(&key), None);
                    }
                }
                continue;
            }
            let run_id = jsx::field(payload, "run_id");
            let run = run_id.as_str();
            if jsx::field(payload, "kind").as_str() != Some("run")
                || !run.is_some_and(|r| runs.contains(r))
            {
                continue;
            }
            let event = jsx::field(payload, "event");
            match jsx::field(event, "kind").as_str() {
                Some("started") => running = run.map(str::to_string),
                Some("assistant_message_committed") => {
                    let message_id = jsx::field(event, "message_id").as_str().unwrap_or(id);
                    turns.text(message_id, ts, jsx::field(event, "text"), None);
                }
                Some("assistant_tool_calls_committed") => {
                    let calls = jsx::field(event, "tool_calls")
                        .as_array()
                        .map_or(&[][..], Vec::as_slice);
                    for call in calls {
                        let input = parse_args(jsx::field(call, "args"));
                        turns.tool(ToolCall {
                            id,
                            ts,
                            activity: tool_activity(jsx::field(call, "name"), &input),
                            ..ToolCall::default()
                        });
                    }
                }
                Some("reasoning_committed") => turns.thinking(id, ts, None),
                Some("terminal") => {
                    if running.as_deref() == run {
                        running = None;
                    }
                    let error_text = (jsx::field(event, "terminal").as_str() == Some("failed"))
                        .then(|| {
                            let reason = jsx::field(event, "reason");
                            let shown = if reason.is_null() {
                                "the turn failed".to_string()
                            } else {
                                js_string(reason)
                            };
                            format!("Muse Code stopped: {shown}")
                        });
                    turns.end(id, ts, false, None, error_text.as_deref());
                }
                _ => {}
            }
        }
    }
    Ok(())
}

fn parse_args(args: &Value) -> Value {
    match args {
        Value::String(text) => jsx::parse_json(text).unwrap_or(Value::Null),
        other => other.clone(),
    }
}

/// An attached image: the session's content-addressed copy, when it exists.
/// The media item and its dedupe key.
fn asset_media(block: &Value, session_dir: &str) -> Option<(Value, String)> {
    if jsx::field(block, "kind").as_str() != Some("asset") {
        return None;
    }
    let asset = jsx::field(block, "asset");
    if !jsx::truthy(asset) || jsx::field(asset, "algorithm").as_str() != Some("sha256") {
        return None;
    }
    let digest = jsx::field(asset, "digest")
        .as_str()
        .filter(|d| d.len() == 64 && d.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f')))?;
    let mime = jsx::field(asset, "media_type").as_str();
    if mime.is_some_and(|m| !m.is_empty() && !m.starts_with("image/")) {
        return None;
    }
    let file = jspath::join(&[
        session_dir,
        "input-assets",
        "v1",
        "sha256",
        &digest[..2],
        digest,
    ]);
    stat_file(&file)?;
    let mut item = Map::new();
    item.insert("id".into(), json!(format!("sha256:{digest}")));
    item.insert("kind".into(), json!("image"));
    item.insert("mime".into(), json!(mime));
    item.insert("path".into(), json!(file));
    Some((Value::Object(item), format!("sha256:{digest}")))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::chat::readers::grok::testkit::{TempDir, run_vector, write_lines};

    #[test]
    fn muse_completed_turns_a_tool_round_an_attached_image_rides_on_the_reply_a_retained_frame_line_unwrapped()
     {
        run_vector(
            "muse completed turns: a tool round, an attached image rides on the reply, a retained_frame line unwrapped",
        );
    }

    #[test]
    fn muse_open_turn_the_tool_call_is_the_activity_until_the_runs_terminal_event() {
        run_vector("muse open turn: the tool call is the activity until the run's terminal event");
    }

    #[test]
    fn muse_synthetic_records_in_the_live_shape_a_failed_turn_shows_its_reason_a_side_chats_run_is_not_this_chat()
     {
        run_vector(
            "muse (synthetic records in the live shape): a failed turn shows its reason, a side chat's run is not this chat",
        );
    }

    fn metadata(cwd: &str, us: f64) -> Value {
        json!({"id": "meta", "recorded_at": us, "payload_type": "runtime.session.metadata", "payload": {"record": {"workspace_root": cwd}}})
    }

    #[test]
    fn muse_root_follows_xdg_data_home() {
        assert_eq!(
            (READER.root)(&Env::default(), "/home/u"),
            "/home/u/.local/share/muse"
        );
        let env = Env::from_pairs([("XDG_DATA_HOME", "~/data")]);
        assert_eq!((READER.root)(&env, "/home/u"), "/home/u/data/muse");
    }

    #[test]
    fn muse_finds_a_session_id_in_any_day_and_a_launch_only_in_the_days_around_it() {
        let dir = TempDir::new("muse");
        let base = dir.path();
        let now_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0.0, |d| d.as_millis() as f64);
        let launched = now_ms - 10.0 * 60_000.0;
        let day = |ms: f64| jsx::to_iso_string(ms).unwrap()[..10].replace('-', "/");
        let own = write_lines(
            &format!("{base}/sessions/{}/s1/session.jsonl", day(launched)),
            &[metadata("/work/demo", (launched + 3_000.0) * 1000.0)],
        );
        let far = write_lines(
            &format!(
                "{base}/sessions/{}/s2/session.jsonl",
                day(launched - 3.0 * 86_400_000.0)
            ),
            &[metadata("/work/demo", (launched + 1_000.0) * 1000.0)],
        );
        assert_eq!(find_by_id("s1", &base).unwrap(), Some(own.clone()));
        assert_eq!(find_by_id("s2", &base).unwrap(), Some(far));
        assert_eq!(find_by_id("s3", &base).unwrap(), None);
        let found = find_by_launch(&LaunchQuery {
            cwd: Some("/work/demo"),
            launched_at: Some(launched),
            root: &base,
            home: &base,
        })
        .unwrap();
        assert_eq!(found, Some(own));
        let none = find_by_launch(&LaunchQuery {
            cwd: Some("/work/demo"),
            launched_at: None,
            root: &base,
            home: &base,
        })
        .unwrap();
        assert_eq!(none, None);
    }

    #[test]
    fn muse_a_launch_at_the_end_of_the_date_range_is_a_range_error() {
        let query = LaunchQuery {
            cwd: Some("/w"),
            launched_at: Some(8.64e15),
            root: "/nonexistent",
            home: "/nonexistent",
        };
        assert_eq!(
            find_by_launch(&query).unwrap_err().message,
            "Invalid time value"
        );
    }

    #[test]
    fn muse_a_subagents_session_is_never_an_agents() {
        let dir = TempDir::new("muse");
        let file = write_lines(
            &dir.join("sessions/2026/10/12/sub/session.jsonl"),
            &[
                json!({"id": "t", "payload": {"kind": "agent_tree_initialized", "record": {"root_session_id": "parent"}}}),
                metadata("/w", 1.0),
            ],
        );
        assert!(probe(&file).is_none());
    }
}
