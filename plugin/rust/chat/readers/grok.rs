//! Grok Build transcript reader (chat-readers/grok.js; live-verified on
//! 1.0.50, docs/research/harnesses/grok.md): `$GROK_HOME` (default `~/.grok`)
//! `/sessions/<percent-encoded cwd>/<session id>/updates.jsonl`, one ACP
//! notification per line: `{timestamp (epoch s), method, params: {sessionId,
//! update: {sessionUpdate, ...}, _meta: {eventId, agentTimestampMs}}}`; resume
//! appends to the same file.
//!
//! The text arrives as chunks: `user_message_chunk` (one prompt per
//! `_meta.promptIndex`), `agent_message_chunk` (consecutive chunks are one
//! message); `tool_call` is a tool call and `turn_completed` ends the turn.
//! Grok has no route for an image over SSH, so there are no media.

use serde_json::Value;

use crate::chat::readers::{LaunchQuery, Reader, ReaderContext};
use crate::chat::shared::{
    ChatResult, ChatTurns, Found, PickArgs, Prompt, ToolCall, expand_home, newest_file,
    pick_by_launch, read_records, subdirectories, tool_activity,
};
use crate::env::Env;
use crate::{jspath, jsx};

pub const READER: Reader = Reader {
    root,
    find_by_id,
    find_by_launch: Some(find_by_launch),
    resolve_path: None,
    parse,
};

fn root(env: &Env, home: &str) -> String {
    match env.non_empty("GROK_HOME") {
        Some(grok_home) => expand_home(grok_home, home),
        None => jspath::join(&[home, ".grok"]),
    }
}

fn find_by_id(id: &str, root: &str) -> ChatResult<Option<String>> {
    let candidates: Vec<String> = subdirectories(&jspath::join(&[root, "sessions"]))
        .iter()
        .map(|dir| jspath::join(&[dir, id, "updates.jsonl"]))
        .collect();
    Ok(newest_file(&candidates))
}

/// The cwd is the session directory's parent, percent-encoded
/// (`encodeURIComponent` matched live for `/home/waycar/work/demo`); the first
/// record's time can come at the first prompt (claude's rule).
fn find_by_launch(query: &LaunchQuery<'_>) -> ChatResult<Option<String>> {
    let mut files = Vec::new();
    for project in subdirectories(&jspath::join(&[query.root, "sessions"])) {
        for session in subdirectories(&project) {
            files.push(jspath::join(&[&session, "updates.jsonl"]));
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

fn probe(file: &str) -> Option<Found> {
    let project = jspath::dirname(&jspath::dirname(file));
    let cwd = decode_uri_component(jspath::basename(&project))?;
    let mut records = read_records(file, None).ok()?;
    match records.next() {
        Some(Ok(first)) => Some(Found {
            cwd: Some(cwd),
            created: record_time(&first.record),
        }),
        _ => None,
    }
}

/// `decodeURIComponent`: None where it throws a URIError (a `%` without two
/// hex digits, or escapes that are not UTF-8).
fn decode_uri_component(text: &str) -> Option<String> {
    if !text.contains('%') {
        return Some(text.to_string());
    }
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut at = 0;
    while at < bytes.len() {
        if bytes[at] != b'%' {
            out.push(bytes[at]);
            at += 1;
            continue;
        }
        let hex = |i: usize| bytes.get(i).and_then(|b| (*b as char).to_digit(16));
        let (high, low) = (hex(at + 1)?, hex(at + 2)?);
        out.push((high * 16 + low) as u8);
        at += 3;
    }
    String::from_utf8(out).ok()
}

/// Epoch milliseconds: the agent's own millisecond time, else the line's second.
fn record_time(record: &Value) -> Option<f64> {
    let ms = jsx::field(
        jsx::field(jsx::field(record, "params"), "_meta"),
        "agentTimestampMs",
    );
    if let Some(ms) = ms.as_number().map(jsx::json_f64).filter(|f| f.is_finite()) {
        return Some(ms);
    }
    jsx::field(record, "timestamp")
        .as_number()
        .map(jsx::json_f64)
        .filter(|f| f.is_finite())
        .map(|s| s * 1000.0)
}

/// `a === b` for two JSON values read from a record: objects and arrays are
/// never identical.
fn strict_equal(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Null, Value::Null) => true,
        (Value::Bool(a), Value::Bool(b)) => a == b,
        (Value::String(a), Value::String(b)) => a == b,
        (Value::Number(a), Value::Number(b)) => jsx::json_f64(a) == jsx::json_f64(b),
        _ => false,
    }
}

/// The message whose chunks are still arriving.
struct Pending {
    user: bool,
    key: Value,
    id: String,
    ts: Option<f64>,
    text: String,
}

fn flush(pending: &mut Option<Pending>, turns: &mut ChatTurns) {
    let Some(Pending {
        user, id, ts, text, ..
    }) = pending.take()
    else {
        return;
    };
    let clean = jsx::trim(&text);
    if user {
        if !clean.is_empty() {
            turns.prompt(Prompt {
                id: &id,
                text: clean,
                ts,
                ..Prompt::default()
            });
        }
    } else {
        turns.text_str(&id, ts, clean, None);
    }
}

fn parse(file: &str, ctx: &ReaderContext<'_>, turns: &mut ChatTurns) -> ChatResult<()> {
    let mut pending: Option<Pending> = None;
    for item in read_records(file, ctx.signal)? {
        let item = item?;
        let record = &item.record;
        let params = jsx::field(record, "params");
        let update = jsx::field(params, "update");
        if !jsx::truthy(update) || !(update.is_object() || update.is_array()) {
            continue;
        }
        let meta = jsx::field(params, "_meta");
        let id = match jsx::field(meta, "eventId") {
            Value::String(event) => event.clone(),
            _ => format!("line:{}", item.line),
        };
        let ts = record_time(record);
        let content = jsx::field(update, "content");
        let text = match (jsx::field(content, "type"), jsx::field(content, "text")) {
            (Value::String(kind), Value::String(text)) if kind == "text" => text.as_str(),
            _ => "",
        };

        match jsx::field(update, "sessionUpdate").as_str().unwrap_or("") {
            "user_message_chunk" => {
                let key = jsx::field(jsx::field(update, "_meta"), "promptIndex");
                match pending.as_mut() {
                    Some(p) if p.user && strict_equal(&p.key, key) => p.text.push_str(text),
                    _ => {
                        flush(&mut pending, turns);
                        pending = Some(Pending {
                            user: true,
                            key: key.clone(),
                            id,
                            ts,
                            text: text.to_string(),
                        });
                    }
                }
            }
            "agent_message_chunk" => match pending.as_mut() {
                Some(p) if !p.user => p.text.push_str(text),
                _ => {
                    flush(&mut pending, turns);
                    pending = Some(Pending {
                        user: false,
                        key: Value::Null,
                        id,
                        ts,
                        text: text.to_string(),
                    });
                }
            },
            "agent_thought_chunk" => {
                flush(&mut pending, turns);
                turns.thinking(&id, ts, None);
            }
            "tool_call" => {
                flush(&mut pending, turns);
                let named =
                    jsx::field(jsx::field(jsx::field(update, "_meta"), "x.ai/tool"), "name");
                let name = if named.is_null() {
                    jsx::field(update, "title")
                } else {
                    named
                };
                let input = jsx::field(update, "rawInput");
                turns.tool(ToolCall {
                    id: &id,
                    ts,
                    activity: tool_activity(name, input),
                    ..ToolCall::default()
                });
            }
            "turn_completed" => {
                flush(&mut pending, turns);
                turns.end(&id, ts, false, None, None);
            }
            // Hook runs, tool output updates and background task lists are not
            // chat material, and do not split a message's chunks.
            _ => {}
        }
    }
    flush(&mut pending, turns);
    Ok(())
}

/// Fixtures shared by the tests of the grok, hermes, muse and qwen readers.
#[cfg(test)]
pub(crate) mod testkit {
    use std::fs;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicUsize, Ordering};

    use serde_json::Value;

    use crate::chat::readers::{ReaderContext, reader};
    use crate::chat::shared::ChatTurns;
    use crate::env::Env;

    /// A unique directory under the system temp dir, removed on drop.
    pub struct TempDir(pub PathBuf);

    impl TempDir {
        pub fn new(tag: &str) -> Self {
            static NEXT: AtomicUsize = AtomicUsize::new(0);
            let nanos = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0, |d| d.as_nanos());
            let dir = std::env::temp_dir().join(format!(
                "waycar-{tag}-{}-{}-{nanos}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::SeqCst)
            ));
            fs::create_dir_all(&dir).expect("temp dir");
            Self(dir)
        }

        pub fn path(&self) -> String {
            self.0.to_str().expect("utf-8 temp dir").to_string()
        }

        pub fn join(&self, relative: &str) -> String {
            format!("{}/{relative}", self.path())
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    /// `writeLines`: one JSON record per line (a string is written as is).
    pub fn write_lines(file: &str, records: &[Value]) -> String {
        let text: String = records
            .iter()
            .map(|record| match record {
                Value::String(line) => format!("{line}\n"),
                other => format!("{other}\n"),
            })
            .collect();
        write_file(file, &text);
        file.to_string()
    }

    pub fn write_file(file: &str, text: &str) {
        let path = std::path::Path::new(file);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).expect("create dir");
        }
        fs::write(path, text).expect("write file");
    }

    pub fn write_executable(file: &str, text: &str) {
        if let Some(parent) = std::path::Path::new(file).parent() {
            fs::create_dir_all(parent).expect("create dir");
        }
        crate::test_support::write_stub(std::path::Path::new(file), text);
    }

    /// Each kind's root under the test home (`env` is empty): `$ROOT`.
    fn kind_root(kind: &str) -> &'static [&'static str] {
        match kind {
            "grok" => &[".grok"],
            "hermes" => &[".hermes"],
            "muse" => &[".local", "share", "muse"],
            _ => &[".qwen"],
        }
    }

    fn substitute(value: &Value, dir: &str, file: &str, root: &str) -> Value {
        match value {
            Value::String(s) => Value::String(
                s.replace("$TRANSCRIPT_DIR", dir)
                    .replace("$TRANSCRIPT", file)
                    .replace("$ROOT", root),
            ),
            Value::Array(items) => Value::Array(
                items
                    .iter()
                    .map(|v| substitute(v, dir, file, root))
                    .collect(),
            ),
            Value::Object(map) => Value::Object(
                map.iter()
                    .map(|(k, v)| (k.clone(), substitute(v, dir, file, root)))
                    .collect(),
            ),
            other => other.clone(),
        }
    }

    /// One recorded vector (`test-vectors/chat-transcript-v1.json`): the
    /// reader parses its transcript, and the messages, activity and open flag
    /// equal the vector's expected lines.
    pub fn run_vector(name: &str) {
        let vectors: Value = serde_json::from_str(include_str!(
            "../../../test-vectors/chat-transcript-v1.json"
        ))
        .expect("vectors");
        let case = vectors["cases"]
            .as_array()
            .and_then(|cases| cases.iter().find(|c| c["name"] == name))
            .unwrap_or_else(|| panic!("no vector {name}"));
        let kind = case["kind"].as_str().expect("kind");
        let dir = TempDir::new("vector");
        let home = dir.path();
        let file = dir.join("transcript.jsonl");
        let root = {
            let mut root = PathBuf::from(&home);
            root.extend(kind_root(kind));
            root.to_str().expect("utf-8").to_string()
        };
        let transcript: Vec<Value> = case["transcript"].as_array().expect("transcript").clone();
        write_lines(&file, &transcript);
        for asset in case["assets"].as_array().into_iter().flatten() {
            write_file(
                &dir.join(asset.as_str().expect("asset")),
                "synthetic asset\n",
            );
        }
        let status = case["args"]["status"].as_str();
        assert!(
            case["args"]["after"].is_null(),
            "no vector of these kinds uses --after"
        );

        let mut env = Env::default();
        let mut session = file.clone();
        if kind == "hermes" {
            let bin = dir.join("bin");
            write_executable(
                &format!("{bin}/hermes"),
                &format!(
                    "#!/bin/sh\necho \"$@\" >> '{}'\ncat '{file}'\n",
                    dir.join("argv.log")
                ),
            );
            env.set("PATH", format!("{bin}:/usr/bin:/bin"));
            let doc: Value =
                serde_json::from_str(transcript[0].as_str().expect("export line")).expect("export");
            session = doc["id"].as_str().expect("export id").to_string();
        }
        let ctx = ReaderContext {
            root: &root,
            env: &env,
            home: &home,
            cwd: None,
            signal: None,
        };
        let mut turns = ChatTurns::new();
        (reader(kind).expect("reader").parse)(&session, &ctx, &mut turns).expect("parse");
        let chat = turns.finish(status).expect("finish");

        if kind == "hermes" {
            let argv = fs::read_to_string(dir.join("argv.log")).expect("argv log");
            assert_eq!(
                argv,
                format!("sessions export --format jsonl --session-id {session} -\n")
            );
        }
        let expected: Vec<Value> = case["expected"]
            .as_array()
            .expect("expected")
            .iter()
            .map(|line| {
                let parsed: Value =
                    serde_json::from_str(line.as_str().expect("line")).expect("expected line");
                substitute(&parsed, &home, &file, &root)
            })
            .collect();
        let header = &expected[0];
        assert_eq!(header["type"], "header");
        assert_eq!(header["activity"], serde_json::json!(chat.activity));
        assert_eq!(header["turn_open"], serde_json::json!(chat.turn_open));
        assert_eq!(chat.messages, expected[1..].to_vec());
    }
}

#[cfg(test)]
mod tests {
    use serde_json::{Value, json};

    use super::testkit::{TempDir, run_vector, write_lines};
    use super::*;

    #[test]
    fn grok_completed_turns_chunks_joined_turn_completed_ends_the_turn_tool_calls_skipped_in_the_reply()
     {
        run_vector(
            "grok completed turns: chunks joined, turn_completed ends the turn, tool calls skipped in the reply",
        );
    }

    #[test]
    fn grok_open_turn_a_tool_call_is_the_activity() {
        run_vector("grok open turn: a tool_call is the activity");
    }

    #[test]
    fn grok_streamed_reply_consecutive_agent_chunks_are_one_message() {
        run_vector("grok streamed reply: consecutive agent chunks are one message");
    }

    /// `Date.now() - 10 * 60_000`: files written by a test are never older.
    fn launched() -> f64 {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0.0, |d| d.as_millis() as f64);
        now - 10.0 * 60_000.0
    }

    fn chunk(ms: f64, text: &str) -> Value {
        json!({
            "timestamp": (ms / 1000.0).floor(),
            "method": "session/update",
            "params": {
                "sessionId": "s",
                "update": {"sessionUpdate": "user_message_chunk", "content": {"type": "text", "text": text}, "_meta": {"promptIndex": 0}},
                "_meta": {"eventId": text, "agentTimestampMs": ms},
            },
        })
    }

    #[test]
    fn grok_finds_a_session_id_under_grok_home_and_with_no_session_the_cwd_from_its_percent_encoded_directory()
     {
        let dir = TempDir::new("grok");
        let home = dir.join("grok-home");
        let encoded = |cwd: &str| {
            let mut out = String::new();
            for byte in cwd.bytes() {
                if byte.is_ascii_alphanumeric() || b"-_.!~*'()".contains(&byte) {
                    out.push(byte as char);
                } else {
                    out.push_str(&format!("%{byte:02X}"));
                }
            }
            out
        };
        let own = write_lines(
            &format!("{home}/sessions/{}/s1/updates.jsonl", encoded("/work/demo")),
            &[chunk(launched() + 1_000.0, "own")],
        );
        write_lines(
            &format!(
                "{home}/sessions/{}/s2/updates.jsonl",
                encoded("/work/other")
            ),
            &[chunk(launched(), "other")],
        );
        let env = Env::from_pairs([("GROK_HOME", home.clone())]);
        let base = (READER.root)(&env, &dir.path());
        assert_eq!(base, home);

        assert_eq!((READER.find_by_id)("s1", &base).unwrap(), Some(own.clone()));
        let found = find_by_launch(&LaunchQuery {
            cwd: Some("/work/demo"),
            launched_at: Some(launched()),
            root: &base,
            home: &dir.path(),
        })
        .unwrap();
        assert_eq!(found, Some(own));
    }

    #[test]
    fn grok_a_percent_encoded_directory_that_fails_to_decode_is_never_matched() {
        let dir = TempDir::new("grok");
        let home = dir.path();
        write_lines(
            &format!("{home}/sessions/%E0%A4%A/s1/updates.jsonl"),
            &[chunk(launched() + 1.0, "x")],
        );
        write_lines(
            &format!("{home}/sessions/100%25/s2/updates.jsonl"),
            &[chunk(launched() + 1.0, "x")],
        );
        let query = |cwd| LaunchQuery {
            cwd: Some(cwd),
            launched_at: Some(launched()),
            root: &home,
            home: &home,
        };
        assert_eq!(find_by_launch(&query("/anything")).unwrap(), None);
        assert_eq!(
            find_by_launch(&query("100%")).unwrap(),
            Some(format!("{home}/sessions/100%25/s2/updates.jsonl"))
        );
    }

    #[test]
    fn decode_uri_component_matches_javascript() {
        assert_eq!(
            decode_uri_component("%2Fwork%2fdemo").as_deref(),
            Some("/work/demo")
        );
        assert_eq!(
            decode_uri_component("%F0%9F%99%82é").as_deref(),
            Some("🙂é")
        );
        for bad in [
            "%",
            "%2",
            "%ZZ",
            "%C3",
            "%C0%AF",
            "%ED%A0%80",
            "%F4%90%80%80",
            "%E0%A4%A",
            "100%",
        ] {
            assert_eq!(decode_uri_component(bad), None, "{bad}");
        }
    }
}
