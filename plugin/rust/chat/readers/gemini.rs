//! Gemini CLI transcript reader (chat-readers/gemini.js; live-verified on
//! 0.63.0, docs/research/harnesses/gemini.md): `~/.gemini/tmp/<project slug>/
//! chats/session-<YYYY-MM-DDTHH-MM>-<first 8 hex of the session id>.jsonl`.
//!
//! Line 1 is a header `{sessionId, projectHash, startTime, kind}`, where
//! `projectHash` is the sha256 of the session's cwd. Then message records
//! `{id, timestamp, type: "user"|"gemini", content, …}` interleaved with
//! `{"$set": {…}}` patches; a `$set` of `messages` replaces the whole list (a
//! resume replays it). A record is upserted by `id`: the same gemini message
//! is written again once its `toolCalls` are known. User `content` is a parts
//! array (`displayContent` holds what the user typed when `@` expansion added
//! parts; a tool result is a user record of `functionResponse` parts); gemini
//! `content` is a string or parts, plus `thoughts` and `toolCalls`. There is
//! no end-of-turn record: the Agent Status closes a turn.
//!
//! A resumed session's SessionStart names a file it never writes (the
//! original keeps growing), so a path that does not exist resolves to the
//! newest `session-*-<same 8 hex>.jsonl` beside it.

use std::collections::{HashMap, HashSet};

use crate::chat::shared::sha256_hex;
use serde_json::Value;

use crate::chat::readers::gemini_parts::{gemini_parts_media, gemini_prompt_text};
use crate::chat::readers::{LaunchQuery, Reader, ReaderContext};
use crate::chat::shared::{
    ChatResult, ChatTurns, Found, PickArgs, Prompt, Record, ToolCall, list_names, newest_file,
    parse_time, pick_by_launch, read_records, stat_file, subdirectories, tool_activity,
};
use crate::env::Env;
use crate::jspath;
use crate::jsx::{field, prefix_utf16};

pub const READER: Reader = Reader {
    root,
    find_by_id,
    find_by_launch: Some(find_by_launch),
    resolve_path: Some(resolve_path),
    parse,
};

fn root(_env: &Env, home: &str) -> String {
    jspath::join(&[home, ".gemini"])
}

/// `/^session-.+-([0-9a-f]{8})\.jsonl$/.exec(name)?.[1]`: the session file
/// name's tail, the first 8 hex digits of the session id. `.` stops at a line
/// terminator.
fn session_short(name: &str) -> Option<&str> {
    let stem = name.strip_prefix("session-")?.strip_suffix(".jsonl")?;
    let cut = stem
        .len()
        .checked_sub(8)
        .filter(|cut| stem.is_char_boundary(*cut))?;
    let (head, short) = stem.split_at(cut);
    if !short
        .bytes()
        .all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
    {
        return None;
    }
    let tag = head.strip_suffix('-')?;
    if tag.is_empty() || tag.contains(['\n', '\r', '\u{2028}', '\u{2029}']) {
        return None;
    }
    Some(short)
}

fn session_files(base: &str) -> Vec<String> {
    let mut files = Vec::new();
    for dir in subdirectories(&jspath::join(&[base, "tmp"])) {
        let chats = jspath::join(&[&dir, "chats"]);
        for name in list_names(&chats) {
            if session_short(&name).is_some() {
                files.push(jspath::join(&[&chats, &name]));
            }
        }
    }
    files
}

/// The first record of `file`, or None for an unreadable or empty one.
fn header(file: &str) -> Option<Value> {
    match read_records(file, None).ok()?.next() {
        Some(Ok(entry)) => Some(entry.record),
        _ => None,
    }
}

fn find_by_id(id: &str, base: &str) -> ChatResult<Option<String>> {
    let short = prefix_utf16(id, 8).to_lowercase();
    let mut candidates = Vec::new();
    for file in session_files(base) {
        if session_short(jspath::basename(&file)) != Some(short.as_str()) {
            continue;
        }
        if header(&file).is_some_and(|record| field(&record, "sessionId").as_str() == Some(id)) {
            candidates.push(file);
        }
    }
    Ok(newest_file(&candidates))
}

fn resolve_path(file: &str) -> ChatResult<Option<String>> {
    if stat_file(file).is_some() {
        return Ok(Some(file.to_string()));
    }
    let Some(short) = session_short(jspath::basename(file)) else {
        return Ok(None);
    };
    let dir = jspath::dirname(file);
    let siblings: Vec<String> = list_names(&dir)
        .into_iter()
        .filter(|name| session_short(name) == Some(short))
        .map(|name| jspath::join(&[&dir, &name]))
        .collect();
    Ok(newest_file(&siblings))
}

/// The header records the start (at launch: SessionStart fires before any
/// prompt) and the cwd only as its sha256; a subagent's session is not the
/// Agent's. The probe's `cwd` holds the header's `projectHash`.
fn find_by_launch(query: &LaunchQuery<'_>) -> ChatResult<Option<String>> {
    let files = session_files(query.root);
    let probe = |file: &str| -> ChatResult<Option<Found>> {
        let Some(record) = header(file) else {
            return Ok(None);
        };
        let Some(hash) = field(&record, "projectHash").as_str() else {
            return Ok(None);
        };
        if crate::jsx::get(&record, "kind").is_some_and(|kind| kind.as_str() != Some("main")) {
            return Ok(None);
        }
        Ok(Some(Found {
            cwd: Some(hash.to_string()),
            created: parse_time(field(&record, "startTime")),
        }))
    };
    let matches = |found: &Found, wanted: &HashSet<String>| {
        wanted
            .iter()
            .any(|form| found.cwd.as_deref() == Some(&sha256_hex(form.as_bytes())))
    };
    pick_by_launch(&PickArgs {
        files: &files,
        probe: &probe,
        cwd: query.cwd,
        launched_at: query.launched_at,
        home: query.home,
        window: true,
        cwd_matches: Some(&matches),
        stat: None,
    })
}

/// A record, its line's offset and the pointer to it.
struct Entry {
    record: Value,
    offset: u64,
    pointer: String,
}

/// id → the newest record for it, in the order the ids first appeared (a JS
/// `Map`: setting an existing key keeps its place).
#[derive(Default)]
struct Entries {
    order: Vec<Entry>,
    index: HashMap<String, usize>,
}

impl Entries {
    fn clear(&mut self) {
        self.order.clear();
        self.index.clear();
    }

    fn upsert(&mut self, record: Value, offset: u64, pointer: String) {
        let Some(id) = field(&record, "id").as_str().map(str::to_string) else {
            return;
        };
        if !record.is_object() {
            return;
        }
        if !matches!(field(&record, "type").as_str(), Some("user" | "gemini")) {
            return;
        }
        let entry = Entry {
            record,
            offset,
            pointer,
        };
        match self.index.get(&id) {
            Some(&slot) => self.order[slot] = entry,
            None => {
                self.index.insert(id, self.order.len());
                self.order.push(entry);
            }
        }
    }
}

fn parse(file: &str, ctx: &ReaderContext<'_>, turns: &mut ChatTurns) -> ChatResult<()> {
    let transcript = jspath::resolve(&[file]);
    let mut entries = Entries::default();
    for entry in read_records(file, ctx.signal)? {
        let Record {
            mut record, offset, ..
        } = entry?;
        let replaces = field(field(&record, "$set"), "messages").is_array();
        if replaces {
            let messages = record
                .get_mut("$set")
                .and_then(|patch| patch.get_mut("messages"))
                .and_then(Value::as_array_mut)
                .map(std::mem::take)
                .unwrap_or_default();
            entries.clear();
            for (index, message) in messages.into_iter().enumerate() {
                entries.upsert(message, offset, format!("/$set/messages/{index}"));
            }
            continue;
        }
        entries.upsert(record, offset, String::new());
    }

    let empty = Value::Array(Vec::new());
    for Entry {
        record,
        offset,
        pointer,
    } in &entries.order
    {
        let id = field(record, "id").as_str().unwrap_or_default();
        let ts = parse_time(field(record, "timestamp"));
        match field(record, "type").as_str() {
            Some("user") => {
                let content = field(record, "content");
                let parts = if content.is_array() { content } else { &empty };
                let display = field(record, "displayContent");
                let typed = if display.is_array() {
                    gemini_prompt_text(display)
                } else {
                    gemini_prompt_text(parts)
                };
                if typed.is_empty() || typed.starts_with("<session_context>") {
                    continue;
                }
                turns.prompt(Prompt {
                    id,
                    text: &typed,
                    ts,
                    ..Prompt::default()
                });
                for media in gemini_parts_media(
                    parts,
                    &transcript,
                    *offset,
                    &format!("{pointer}/content"),
                    ctx.root,
                ) {
                    turns.media(&media, None);
                }
            }
            Some("gemini") => {
                if field(record, "thoughts")
                    .as_array()
                    .is_some_and(|thoughts| !thoughts.is_empty())
                {
                    turns.thinking(id, ts, None);
                }
                turns.text_str(id, ts, &gemini_text(field(record, "content")), None);
                if let Some(calls) = field(record, "toolCalls").as_array() {
                    for call in calls {
                        let activity = tool_activity(field(call, "name"), field(call, "args"));
                        turns.tool(ToolCall {
                            id,
                            ts,
                            activity,
                            ..ToolCall::default()
                        });
                    }
                }
            }
            _ => {}
        }
    }
    Ok(())
}

fn gemini_text(content: &Value) -> String {
    match content {
        Value::String(text) => text.clone(),
        Value::Array(parts) => parts
            .iter()
            .filter(|part| field(part, "thought") != &Value::Bool(true))
            .filter_map(|part| field(part, "text").as_str())
            .collect(),
        _ => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    use crate::chat::readers::gemini_parts::test_support::*;

    #[test]
    fn gemini_completed_turns_records_upserted_by_id_the_session_context_preamble_hidden_tool_results_never_prompts()
     {
        run_vector("gemini", 0);
    }

    #[test]
    fn gemini_open_turn_the_upserted_tool_calls_are_the_activity() {
        run_vector("gemini", 1);
    }

    #[test]
    fn gemini_resumed_session_a_set_of_messages_replaces_the_list_new_records_follow_it_display_content_is_the_prompt_and_the_image_rides_the_reply()
     {
        run_vector("gemini", 2);
    }

    #[test]
    fn gemini_finds_a_session_id_by_its_file_name_and_header_and_a_resumed_sessions_unwritten_path_reads_the_original_file()
     {
        let dir = TempDir::new();
        let launched = now_ms() - 10.0 * 60_000.0;
        let base = (READER.root)(&Env::default(), &dir.0);
        let chats = jspath::join(&[&base, "tmp", "demo", "chats"]);
        let id = "01ccc475-d9df-4b1a-8b1e-ebddc21cd237";
        let header = |session_id: &str| {
            json!({ "sessionId": session_id, "projectHash": "x", "startTime": iso(launched), "lastUpdated": iso(launched), "kind": "main" })
                .to_string()
        };
        let turn = json!({ "id": "u1", "timestamp": iso(launched), "type": "user", "content": [{ "text": "Hi?" }] }).to_string();
        let own = write_lines(
            &jspath::join(&[&chats, "session-2026-10-12T16-35-01ccc475.jsonl"]),
            &[header(id), turn.clone()],
        );
        // Same first 8 hex digits, another session.
        write_lines(
            &jspath::join(&[&chats, "session-2026-10-12T16-30-01ccc475.jsonl"]),
            &[header("01ccc475-0000-4000-8000-000000000000"), turn],
        );

        let by_id = (READER.find_by_id)(id, &base).unwrap();
        let missing = jspath::join(&[&chats, "session-2026-10-12T16-37-01ccc475.jsonl"]);
        let resolved = (READER.resolve_path.unwrap())(&missing).unwrap().unwrap();

        assert_eq!(by_id, Some(own.clone()));
        let chat = parse_chat("gemini", &resolved, &base, &dir.0, None).unwrap();
        assert_eq!(texts(&chat), vec!["Hi?"]);
    }

    #[test]
    fn gemini_with_no_session_matches_the_cwd_by_its_sha256_and_never_a_session_started_minutes_after_the_launch()
     {
        let dir = TempDir::new();
        let launched = now_ms() - 10.0 * 60_000.0;
        let base = (READER.root)(&Env::default(), &dir.0);
        let chats = jspath::join(&[&base, "tmp", "demo", "chats"]);
        let hash = sha256_hex(b"/work/demo");
        let session = |start: String, text: &str| {
            vec![
                json!({ "sessionId": text, "projectHash": hash, "startTime": start, "lastUpdated": start, "kind": "main" }).to_string(),
                json!({ "id": text, "timestamp": start, "type": "user", "content": [{ "text": text }] }).to_string(),
            ]
        };
        let own = write_lines(
            &jspath::join(&[&chats, "session-a-aaaaaaaa.jsonl"]),
            &session(iso(launched + 1_000.0), "own"),
        );
        write_lines(
            &jspath::join(&[&chats, "session-b-bbbbbbbb.jsonl"]),
            &session(iso(launched + 5.0 * 60_000.0), "later"),
        );
        let find = || {
            (READER.find_by_launch.unwrap())(&LaunchQuery {
                cwd: Some("/work/demo"),
                launched_at: Some(launched),
                root: &base,
                home: &dir.0,
            })
            .unwrap()
        };

        assert_eq!(find(), Some(own.clone()));
        // With its own session gone, the one started 5 min after the launch is still not the Agent's.
        std::fs::remove_file(&own).unwrap();
        assert_eq!(find(), None);
    }

    #[test]
    fn session_file_names_match_like_the_regex() {
        assert_eq!(
            session_short("session-2026-10-12T16-35-01ccc475.jsonl"),
            Some("01ccc475")
        );
        assert_eq!(session_short("session-a-aaaaaaaa.jsonl"), Some("aaaaaaaa"));
        assert_eq!(session_short("session--aaaaaaaa.jsonl"), None);
        assert_eq!(session_short("session-a-AAAAAAAA.jsonl"), None);
        assert_eq!(session_short("session-a-aaaaaaa.jsonl"), None);
        assert_eq!(session_short("session-a-aaaaaaaaa.jsonl"), None);
        assert_eq!(session_short("session-a\n-aaaaaaaa.jsonl"), None);
        assert_eq!(session_short("session-é-aaaaaaaa.jsonl"), Some("aaaaaaaa"));
        assert_eq!(session_short("xsession-a-aaaaaaaa.jsonl"), None);
        assert_eq!(session_short("session-a-aaaaaaaa.jsonl.bak"), None);
    }

    #[test]
    fn a_header_with_another_kind_is_never_the_agents() {
        let dir = TempDir::new();
        let launched = now_ms() - 10.0 * 60_000.0;
        let base = (READER.root)(&Env::default(), &dir.0);
        let chats = jspath::join(&[&base, "tmp", "demo", "chats"]);
        let hash = sha256_hex(b"/work/demo");
        let start = iso(launched + 1_000.0);
        for (name, kind) in [
            ("session-a-aaaaaaaa.jsonl", json!("subagent")),
            ("session-b-bbbbbbbb.jsonl", Value::Null),
        ] {
            let header =
                json!({ "sessionId": name, "projectHash": hash, "startTime": start, "kind": kind });
            write_lines(&jspath::join(&[&chats, name]), &[header.to_string()]);
        }
        let found = (READER.find_by_launch.unwrap())(&LaunchQuery {
            cwd: Some("/work/demo"),
            launched_at: Some(launched),
            root: &base,
            home: &dir.0,
        })
        .unwrap();
        assert_eq!(found, None);
    }
}

#[cfg(test)]
mod edge_tests {
    use serde_json::json;

    use super::*;
    use crate::chat::readers::gemini_parts::test_support::*;
    use crate::chat::shared::AbortSignal;

    fn session_lines(session_id: &str, hash: &str, start: &str) -> Vec<String> {
        vec![
            json!({ "sessionId": session_id, "projectHash": hash, "startTime": start, "kind": "main" }).to_string(),
            json!({ "id": "u", "timestamp": start, "type": "user", "content": [{ "text": session_id }] }).to_string(),
        ]
    }

    #[test]
    fn a_symlinked_cwd_hashes_through_its_real_path_too() {
        let dir = TempDir::new();
        let real = dir.join(&["proj"]);
        std::fs::create_dir_all(&real).unwrap();
        let link = dir.join(&["proj-link"]);
        std::os::unix::fs::symlink(&real, &link).unwrap();
        let hash = sha256_hex(real.as_bytes());
        let file = write_lines(
            &dir.join(&["tmp", "p", "chats", "session-a-aaaaaaaa.jsonl"]),
            &session_lines("s", &hash, &iso(1_000.0)),
        );
        let find = |cwd: &str| {
            find_by_launch(&LaunchQuery {
                cwd: Some(cwd),
                launched_at: Some(1_000.0),
                root: &dir.0,
                home: &dir.0,
            })
            .unwrap()
        };
        assert_eq!(find(&link), Some(file.clone()));
        assert_eq!(find(&real), Some(file));
        assert_eq!(find(&dir.join(&["other"])), None);
    }

    #[test]
    fn the_launch_window_slack_and_ties() {
        let dir = TempDir::new();
        let launched = 1_000_000.0;
        let hash = sha256_hex(b"/work/demo");
        let write = |name: &str, start: f64| {
            write_lines(
                &dir.join(&["tmp", "p", "chats", name]),
                &session_lines(name, &hash, &iso(start)),
            )
        };
        let find = || {
            find_by_launch(&LaunchQuery {
                cwd: Some("/work/demo"),
                launched_at: Some(launched),
                root: &dir.0,
                home: &dir.0,
            })
            .unwrap()
        };
        write("session-a-aaaaaaaa.jsonl", launched + 120_001.0);
        write("session-b-bbbbbbbb.jsonl", launched - 10_001.0);
        assert_eq!(find(), None);
        let edge = write("session-c-cccccccc.jsonl", launched + 120_000.0);
        assert_eq!(find(), Some(edge));
        let tie_after = write("session-d-dddddddd.jsonl", launched + 4_000.0);
        assert_eq!(find(), Some(tie_after));
        let tie_before = write("session-e-eeeeeeee.jsonl", launched - 4_000.0);
        assert_eq!(find(), Some(tie_before));
    }

    #[test]
    fn the_id_match_lowercases_the_short_id_and_compares_the_whole_session_id() {
        let dir = TempDir::new();
        let id = "ABCDEF12-0000-4000-8000-000000000000";
        let file = write_lines(
            &dir.join(&["tmp", "p", "chats", "session-x-abcdef12.jsonl"]),
            &session_lines(id, "h", &iso(1_000.0)),
        );
        assert_eq!(find_by_id(id, &dir.0).unwrap(), Some(file));
        assert_eq!(find_by_id(&id.to_lowercase(), &dir.0).unwrap(), None);
        assert_eq!(find_by_id("abcdef12", &dir.0).unwrap(), None);
        assert_eq!(find_by_id("", &dir.0).unwrap(), None);
    }

    #[test]
    fn a_path_that_exists_resolves_to_itself_and_a_missing_one_to_the_newest_sibling() {
        let dir = TempDir::new();
        let chats = dir.join(&["tmp", "p", "chats"]);
        let old = write_lines(
            &jspath::join(&[&chats, "session-a-01ccc475.jsonl"]),
            &["{}".to_string()],
        );
        let new = write_lines(
            &jspath::join(&[&chats, "session-b-01ccc475.jsonl"]),
            &["{}".to_string()],
        );
        let past = std::time::SystemTime::now() - std::time::Duration::from_secs(1000);
        std::fs::File::options()
            .write(true)
            .open(&old)
            .unwrap()
            .set_modified(past)
            .unwrap();
        assert_eq!(resolve_path(&old).unwrap(), Some(old.clone()));
        let gone = jspath::join(&[&chats, "session-z-01ccc475.jsonl"]);
        assert_eq!(resolve_path(&gone).unwrap(), Some(new));
        assert_eq!(
            resolve_path(&jspath::join(&[&chats, "notes.txt"])).unwrap(),
            None
        );
        assert_eq!(
            resolve_path(&jspath::join(&[&chats, "session-z-deadbeef.jsonl"])).unwrap(),
            None
        );
    }

    #[test]
    fn records_replaced_by_id_keep_their_first_position() {
        let dir = TempDir::new();
        let lines = [
            json!({ "id": "a", "type": "user", "content": [{ "text": "first" }] }),
            json!({ "id": "b", "type": "user", "content": [{ "text": "second" }] }),
            json!({ "id": "a", "type": "user", "content": [{ "text": "first, edited" }] }),
        ]
        .map(|record| record.to_string());
        let file = write_lines(&dir.join(&["t.jsonl"]), &lines);
        let chat = parse_chat("gemini", &file, &dir.0, &dir.0, Some("idle")).unwrap();
        let users: Vec<&str> = chat
            .messages
            .iter()
            .filter(|m| m["role"] == "user")
            .map(|m| m["text"].as_str().unwrap())
            .collect();
        assert_eq!(users, ["first, edited", "second"]);
    }

    #[test]
    fn an_aborted_read_stops_with_the_reason() {
        let dir = TempDir::new();
        let file = write_lines(&dir.join(&["t.jsonl"]), &["{}".to_string()]);
        let signal = AbortSignal::new();
        signal.abort("deadline");
        let env = Env::default();
        let ctx = ReaderContext {
            root: &dir.0,
            env: &env,
            home: &dir.0,
            cwd: None,
            signal: Some(&signal),
        };
        assert_eq!(
            (READER.parse)(&file, &ctx, &mut ChatTurns::new())
                .unwrap_err()
                .message,
            "deadline"
        );
    }
}
