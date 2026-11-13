//! Tests of the transcript reader (test/chat-transcript.test.js), plus the
//! recorded vectors (test-vectors/chat-transcript-v1.json).
//!
//! Left to their own slices: the `chat-read CLI` suite (chat::read) and the
//! reader-kind cases of `harness transcript location` (copilot, qwen, gemini,
//! grok, agy, cline: the readers' own tests).

use std::cell::RefCell;
use std::collections::HashSet;
use std::fs;
use std::path::Path;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{Map, Value, json};

use super::{ChatRead, ReadChatArgs, RivalQuery, Rivals, format_ndjson, last_reply, read_chat};
use crate::env::Env;
use crate::jsx::{self, field};

// MARK: - Fixtures

static COUNTER: AtomicUsize = AtomicUsize::new(0);

/// A unique temp dir, removed on drop (`dir` of the JS tests).
struct Dir(String);

impl Dir {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "chat-transcript-{}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::SeqCst)
        ));
        fs::create_dir_all(&path).expect("create the test dir");
        Self(path.to_string_lossy().into_owned())
    }

    fn path(&self) -> &str {
        &self.0
    }

    /// `join(dir, ...parts)`.
    fn at(&self, parts: &[&str]) -> String {
        join(&self.0, parts)
    }
}

impl Drop for Dir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn join(base: &str, parts: &[&str]) -> String {
    let mut out = base.to_string();
    for part in parts {
        out.push('/');
        out.push_str(part);
    }
    out
}

fn make_parent(file: &str) {
    if let Some(parent) = Path::new(file).parent() {
        fs::create_dir_all(parent).expect("create the parent dir");
    }
}

/// `writeLines`: one record per line (a string record is written as is, any
/// other is `JSON.stringify`ed), each line ended by `\n`.
fn write_lines(file: &str, records: &[Value]) -> String {
    make_parent(file);
    let lines: Vec<String> = records
        .iter()
        .map(|record| match record {
            Value::String(text) => text.clone(),
            other => jsx::stringify(other),
        })
        .collect();
    fs::write(file, format!("{}\n", lines.join("\n"))).expect("write the transcript");
    file.to_string()
}

/// An executable stub script (mode 0755).
fn write_exec(file: &str, content: &str) {
    make_parent(file);
    crate::test_support::write_stub(Path::new(file), content);
}

fn path_env(bin: &str) -> Env {
    Env::from_pairs([("PATH", format!("{bin}:/usr/bin:/bin"))])
}

fn now_ms() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("clock after the epoch")
        .as_millis() as f64
}

/// `new Date(ms).toISOString()`.
fn iso(ms: f64) -> String {
    jsx::to_iso_string(ms).expect("a valid time")
}

// MARK: - Reading

fn base<'a>(kind: &'a str, env: &'a Env, home: &'a str) -> ReadChatArgs<'a> {
    ReadChatArgs {
        kind,
        session_kind: None,
        session_value: None,
        cwd: None,
        launched_at: None,
        launch_rivals: None,
        status: None,
        after: None,
        max_messages: None,
        env,
        home,
    }
}

fn read_id(kind: &str, id: &str, env: &Env, home: &str) -> ChatRead {
    read_chat(&ReadChatArgs {
        session_kind: Some("id"),
        session_value: Some(id),
        ..base(kind, env, home)
    })
}

fn read_path(kind: &str, file: &str, env: &Env, home: &str) -> ChatRead {
    read_chat(&ReadChatArgs {
        session_kind: Some("path"),
        session_value: Some(file),
        ..base(kind, env, home)
    })
}

fn read_launch(kind: &str, cwd: &str, launched: f64, env: &Env, home: &str) -> ChatRead {
    read_chat(&ReadChatArgs {
        cwd: Some(cwd),
        launched_at: Some(&iso(launched)),
        ..base(kind, env, home)
    })
}

/// `read` of the turn-rules suite and the like: a path session with a status
/// and an `after`.
fn read_file(
    kind: &str,
    file: &str,
    status: Option<&str>,
    after: Option<&str>,
    home: &str,
) -> ChatRead {
    let env = Env::default();
    read_chat(&ReadChatArgs {
        session_kind: Some("path"),
        session_value: Some(file),
        status,
        after,
        ..base(kind, &env, home)
    })
}

fn status(chat: &ChatRead) -> &str {
    field(&chat.header, "status").as_str().unwrap_or("")
}

fn transcript(chat: &ChatRead) -> Option<&str> {
    field(&chat.header, "transcript").as_str()
}

fn texts(chat: &ChatRead) -> Vec<String> {
    chat.messages
        .iter()
        .map(|message| field(message, "text").as_str().unwrap_or("").to_string())
        .collect()
}

fn ids(chat: &ChatRead) -> Vec<String> {
    chat.messages
        .iter()
        .map(|message| field(message, "id").as_str().unwrap_or("").to_string())
        .collect()
}

/// `[message.id, message.text]` for each message.
fn summary(chat: &ChatRead) -> Vec<(String, String)> {
    ids(chat).into_iter().zip(texts(chat)).collect()
}

fn pairs(items: &[(&str, &str)]) -> Vec<(String, String)> {
    items
        .iter()
        .map(|(a, b)| (a.to_string(), b.to_string()))
        .collect()
}

fn error_text(chat: &ChatRead) -> &str {
    field(&chat.header, "error").as_str().unwrap_or("")
}

// MARK: - Claude records

fn claude_user(uuid: &str, ts: &str, content: Value, cwd: &str) -> Value {
    json!({ "type": "user", "uuid": uuid, "isSidechain": false, "timestamp": ts, "cwd": cwd, "message": { "role": "user", "content": content } })
}

fn claude_reply(uuid: &str, ts: &str, content: Value, stop: &str, cwd: &str) -> Value {
    json!({ "type": "assistant", "uuid": uuid, "isSidechain": false, "timestamp": ts, "cwd": cwd, "message": { "role": "assistant", "content": content, "stop_reason": stop } })
}

fn claude_turn_at(n: u32, cwd: &str, ts: &str) -> Vec<Value> {
    vec![
        claude_user(&format!("u{n}"), ts, json!(format!("Question {n}?")), cwd),
        claude_reply(
            &format!("a{n}"),
            ts,
            json!([{ "type": "text", "text": format!("Answer {n}.") }]),
            "end_turn",
            cwd,
        ),
    ]
}

fn claude_turn(n: u32, cwd: &str) -> Vec<Value> {
    claude_turn_at(n, cwd, "2026-09-30T12:00:00.000Z")
}

// MARK: - Vector layout

/// Each kind's root under the test home (`env` is empty): `$ROOT` in the vectors.
fn kind_root_parts(kind: &str) -> &'static [&'static str] {
    match kind {
        "claude" => &[".claude"],
        "codex" => &[".codex"],
        "omp" => &[".omp", "agent"],
        "pi" => &[".pi", "agent"],
        "opencode" => &[".local", "share", "opencode"],
        "kilo" => &[".local", "share", "kilo"],
        "copilot" => &[".copilot"],
        "qwen" => &[".qwen"],
        "gemini" => &[".gemini"],
        "grok" => &[".grok"],
        "agy" => &[".gemini", "antigravity-cli"],
        "cline" => &[".cline", "data"],
        "hermes" => &[".hermes"],
        "muse" => &[".local", "share", "muse"],
        _ => &[],
    }
}

/// Kinds without a transcript file: the session id inside the export, and
/// the argv the export must be run with.
fn exported_id(kind: &str, doc: &Value) -> Option<(String, String)> {
    let (id, argv) = match kind {
        "opencode" | "kilo" => {
            let id = field(field(doc, "info"), "id").as_str()?.to_string();
            let argv = format!("export {id}");
            (id, argv)
        }
        "hermes" => {
            let id = field(doc, "id").as_str()?.to_string();
            let argv = format!("sessions export --format jsonl --session-id {id} -");
            (id, argv)
        }
        _ => return None,
    };
    Some((id, argv))
}

/// `$TRANSCRIPT_DIR`, `$TRANSCRIPT` and `$ROOT` in every string value.
fn substitute(value: &mut Value, dir: &str, file: &str, root: &str) {
    match value {
        Value::String(text) => {
            *text = text
                .replace("$TRANSCRIPT_DIR", dir)
                .replace("$TRANSCRIPT", file)
                .replace("$ROOT", root);
        }
        Value::Array(items) => items
            .iter_mut()
            .for_each(|item| substitute(item, dir, file, root)),
        Value::Object(map) => map
            .values_mut()
            .for_each(|item| substitute(item, dir, file, root)),
        _ => {}
    }
}

/// One vector: `Err` names what differed.
fn run_vector(vector: &Value) -> Result<(), String> {
    let kind = field(vector, "kind").as_str().ok_or("no kind")?;
    let lines: Vec<Value> = field(vector, "transcript")
        .as_array()
        .cloned()
        .unwrap_or_default();
    let args = field(vector, "args");
    let status_arg = args.get("status").and_then(Value::as_str);
    let after_arg = args.get("after").and_then(Value::as_str);
    let dir = Dir::new();
    let file = write_lines(&dir.at(&["transcript.jsonl"]), &lines);
    let root = dir.at(kind_root_parts(kind));
    for blob in field(vector, "blobs")
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
    {
        write_lines(&join(&root, &["blobs", blob]), &[json!("synthetic blob")]);
    }
    // Files beside the transcript (muse's content-addressed input assets).
    for asset in field(vector, "assets")
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
    {
        write_lines(&dir.at(&[asset]), &[json!("synthetic asset")]);
    }
    let expected_lines: Vec<&str> = field(vector, "expected")
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .collect();
    let mut expected = Vec::new();
    for line in &expected_lines {
        expected.push(
            jsx::parse_json(line).ok_or_else(|| format!("expected line is not JSON: {line}"))?,
        );
    }

    let first_doc = lines
        .first()
        .and_then(Value::as_str)
        .and_then(jsx::parse_json)
        .unwrap_or(Value::Null);
    let chat = if let Some((session, argv)) = exported_id(kind, &first_doc) {
        // The export is printed by a stub binary that is the only place the
        // harness can come from, and the session id comes from the export
        // itself. The stub logs its argv, so every case also pins the exec
        // path: the exported session id must be exactly the reader's session
        // value.
        let bin = dir.at(&["bin"]);
        write_exec(
            &join(&bin, &[kind]),
            &format!(
                "#!/bin/sh\nif [ \"$1\" = --version ]; then echo 1.19.5; exit 0; fi\necho \"$@\" >> '{}'\ncat '{file}'\n",
                dir.at(&["argv.log"])
            ),
        );
        let env = path_env(&bin);
        let chat = read_chat(&ReadChatArgs {
            session_kind: Some("id"),
            session_value: Some(&session),
            status: status_arg,
            after: after_arg,
            ..base(kind, &env, dir.path())
        });
        let logged = fs::read_to_string(dir.at(&["argv.log"]))
            .map_err(|error| format!("argv.log: {error}"))?;
        if logged != format!("{argv}\n") {
            return Err(format!("argv.log {logged:?}, expected {argv:?}"));
        }
        if field(&chat.header, "transcript") != &Value::Null {
            return Err(format!(
                "header transcript {:?}, expected null",
                field(&chat.header, "transcript")
            ));
        }
        chat
    } else {
        let env = Env::default();
        let chat = read_chat(&ReadChatArgs {
            session_kind: Some("path"),
            session_value: Some(&file),
            status: status_arg,
            after: after_arg,
            ..base(kind, &env, dir.path())
        });
        if transcript(&chat) != Some(file.as_str()) {
            return Err(format!(
                "header transcript {:?}, expected {file:?} (status {}, error {:?})",
                field(&chat.header, "transcript"),
                status(&chat),
                error_text(&chat)
            ));
        }
        for line in &mut expected {
            substitute(line, dir.path(), &file, &root);
        }
        chat
    };

    let ndjson = format_ndjson(&chat);
    let mut actual_lines: Vec<String> = ndjson
        .split('\n')
        .filter(|line| !line.is_empty())
        .map(str::to_string)
        .collect();
    // The header's transcript is the temp file: the vectors hold null.
    let mut header = jsx::parse_json(&actual_lines[0]).ok_or("the header line is not JSON")?;
    header["transcript"] = Value::Null;
    actual_lines[0] = jsx::stringify(&header);
    let mut actual = Vec::new();
    for line in &actual_lines {
        actual
            .push(jsx::parse_json(line).ok_or_else(|| format!("output line is not JSON: {line}"))?);
    }

    if actual != expected {
        return Err(format!(
            "output differs ({} lines, expected {}); header status {}, error {:?}\nactual:   {}\nexpected: {}",
            actual.len(),
            expected.len(),
            status(&chat),
            error_text(&chat),
            actual_lines.join("\n          "),
            expected
                .iter()
                .map(jsx::stringify)
                .collect::<Vec<_>>()
                .join("\n          "),
        ));
    }
    // Key order, which the deep comparison ignores.
    for (index, (line, value)) in actual_lines.iter().zip(&expected).enumerate() {
        if *line != jsx::stringify(value) {
            return Err(format!(
                "key order of line {index}:\nactual:   {line}\nexpected: {}",
                jsx::stringify(value)
            ));
        }
    }
    Ok(())
}

#[test]
fn chat_transcript_vectors() {
    let vectors: Value = serde_json::from_str(include_str!(
        "../../../test-vectors/chat-transcript-v1.json"
    ))
    .expect("the vectors are JSON");
    let cases = field(&vectors, "cases").as_array().expect("cases");
    assert_eq!(cases.len(), 60, "the vector count changed");
    let mut failures = Vec::new();
    for vector in cases {
        let name = field(vector, "name").as_str().unwrap_or("?");
        let kind = field(vector, "kind").as_str().unwrap_or("?");
        if let Err(reason) = run_vector(vector) {
            failures.push(format!("[{kind}] {name}: {reason}"));
        }
    }
    assert!(
        failures.is_empty(),
        "{} of {} vectors failed:\n{}",
        failures.len(),
        cases.len(),
        failures.join("\n\n")
    );
}

// MARK: - transcript location

#[test]
fn claude_finds_a_session_id_under_claude_config_dir_not_the_home_default() {
    let dir = Dir::new();
    let config = dir.at(&["claude-config"]);
    let id = "0f4c7a2e-1111-4222-8333-444455556666";
    let file = write_lines(
        &join(&config, &["projects", "-work-demo", &format!("{id}.jsonl")]),
        &claude_turn(1, "/work/demo"),
    );
    write_lines(
        &dir.at(&[".claude", "projects", "-work-demo", &format!("{id}.jsonl")]),
        &claude_turn(9, "/work/demo"),
    );

    let env = Env::from_pairs([("CLAUDE_CONFIG_DIR", config.as_str())]);
    let chat = read_id("claude", id, &env, dir.path());

    assert_eq!(status(&chat), "ok");
    assert_eq!(transcript(&chat), Some(file.as_str()));
    assert_eq!(texts(&chat), ["Question 1?", "Answer 1."]);
}

#[test]
fn codex_finds_a_session_id_in_the_dated_tree_under_codex_home() {
    let dir = Dir::new();
    let codex_home = dir.at(&["codex-home"]);
    let id = "01a0e383-bbb1-7661-880e-56889a9865b3";
    write_lines(
        &join(
            &codex_home,
            &[
                "sessions",
                "2026",
                "09",
                "29",
                "rollout-2026-09-29T10-00-00-01a0e383-0000-0000-0000-000000000000.jsonl",
            ],
        ),
        &[],
    );
    let file = write_lines(
        &join(
            &codex_home,
            &[
                "sessions",
                "2026",
                "09",
                "30",
                &format!("rollout-2026-09-30T12-00-00-{id}.jsonl"),
            ],
        ),
        &[
            json!({ "timestamp": "2026-09-30T12:00:00.000Z", "type": "session_meta", "payload": { "id": id, "cwd": "/work/demo", "source": "cli" } }),
            json!({ "timestamp": "2026-09-30T12:00:01.000Z", "type": "event_msg", "payload": { "type": "task_started", "turn_id": "t1" } }),
            json!({ "timestamp": "2026-09-30T12:00:01.000Z", "type": "event_msg", "payload": { "type": "user_message", "message": "Ping?" } }),
            json!({
                "timestamp": "2026-09-30T12:00:02.000Z",
                "type": "response_item",
                "payload": { "type": "message", "role": "assistant", "content": [{ "type": "output_text", "text": "Pong." }] },
            }),
            json!({ "timestamp": "2026-09-30T12:00:03.000Z", "type": "event_msg", "payload": { "type": "task_complete", "turn_id": "t1" } }),
        ],
    );

    let env = Env::from_pairs([("CODEX_HOME", codex_home.as_str())]);
    let chat = read_id("codex", id, &env, dir.path());

    assert_eq!(status(&chat), "ok");
    assert_eq!(transcript(&chat), Some(file.as_str()));
    assert_eq!(
        summary(&chat),
        pairs(&[("u:t1", "Ping?"), ("a:t1", "Pong.")])
    );
}

#[test]
fn with_no_session_picks_the_transcript_in_the_cwd_created_closest_to_the_launch() {
    let dir = Dir::new();
    let config = dir.at(&["claude-config"]);
    let projects = join(&config, &["projects"]);
    let launched = now_ms() - 10.0 * 60_000.0;
    // Created before the launch window: an older conversation in the same cwd.
    write_lines(
        &join(&projects, &["-work-demo", "old.jsonl"]),
        &claude_turn_at(1, "/work/demo", &iso(launched - 3_600_000.0)),
    );
    // Closest of all, but another cwd.
    write_lines(
        &join(&projects, &["-work-other", "other.jsonl"]),
        &claude_turn_at(2, "/work/other", &iso(launched + 1_000.0)),
    );
    // Outside the 10 s slack before the launch.
    write_lines(
        &join(&projects, &["-work-demo", "early.jsonl"]),
        &claude_turn_at(3, "/work/demo", &iso(launched - 30_000.0)),
    );
    let mut own_records =
        vec![json!({ "type": "permission-mode", "permissionMode": "default", "sessionId": "own" })];
    own_records.extend(claude_turn_at(4, "/work/demo", &iso(launched + 5_000.0)));
    let own = write_lines(&join(&projects, &["-work-demo", "own.jsonl"]), &own_records);
    // Another Agent started later in the same cwd: newer, but not the launch's.
    write_lines(
        &join(&projects, &["-work-demo", "later.jsonl"]),
        &claude_turn_at(5, "/work/demo", &iso(launched + 60_000.0)),
    );

    let env = Env::from_pairs([("CLAUDE_CONFIG_DIR", config.as_str())]);
    let chat = read_launch("claude", "/work/demo", launched, &env, dir.path());

    assert_eq!(status(&chat), "ok");
    assert_eq!(transcript(&chat), Some(own.as_str()));
    assert_eq!(texts(&chat), ["Question 4?", "Answer 4."]);
}

#[test]
fn with_no_session_a_tie_in_distance_from_the_launch_goes_to_the_earlier_transcript() {
    let dir = Dir::new();
    let config = dir.at(&["claude-config"]);
    let launched = now_ms() - 10.0 * 60_000.0;
    write_lines(
        &join(&config, &["projects", "-work-demo", "after.jsonl"]),
        &claude_turn_at(1, "/work/demo", &iso(launched + 4_000.0)),
    );
    let before = write_lines(
        &join(&config, &["projects", "-work-demo", "before.jsonl"]),
        &claude_turn_at(2, "/work/demo", &iso(launched - 4_000.0)),
    );

    let env = Env::from_pairs([("CLAUDE_CONFIG_DIR", config.as_str())]);
    let chat = read_launch("claude", "/work/demo", launched, &env, dir.path());

    assert_eq!(transcript(&chat), Some(before.as_str()));
}

#[test]
fn with_no_session_the_10_s_slack_before_the_launch_is_inclusive() {
    let dir = Dir::new();
    let config = dir.at(&["claude-config"]);
    let launched = now_ms() - 10.0 * 60_000.0;
    write_lines(
        &join(&config, &["projects", "-work-demo", "outside.jsonl"]),
        &claude_turn_at(1, "/work/demo", &iso(launched - 10_001.0)),
    );
    let edge = write_lines(
        &join(&config, &["projects", "-work-demo", "edge.jsonl"]),
        &claude_turn_at(2, "/work/demo", &iso(launched - 10_000.0)),
    );

    let env = Env::from_pairs([("CLAUDE_CONFIG_DIR", config.as_str())]);
    let found = read_launch("claude", "/work/demo", launched, &env, dir.path());

    assert_eq!(transcript(&found), Some(edge.as_str()));
}

#[test]
fn with_no_session_a_transcript_created_only_before_the_launch_window_is_not_found() {
    let dir = Dir::new();
    let config = dir.at(&["claude-config"]);
    let launched = now_ms() - 10.0 * 60_000.0;
    write_lines(
        &join(&config, &["projects", "-work-demo", "old.jsonl"]),
        &claude_turn_at(1, "/work/demo", &iso(launched - 11_000.0)),
    );

    let env = Env::from_pairs([("CLAUDE_CONFIG_DIR", config.as_str())]);
    let chat = read_launch("claude", "/work/demo", launched, &env, dir.path());

    assert_eq!(status(&chat), "not_found");
    assert_eq!(transcript(&chat), None);
    assert!(chat.messages.is_empty());
}

// codex and omp headers record process start; a start 5 min after this
// launch is a later Agent's, even while this Agent's own file is unwritten.
#[test]
fn with_no_session_a_codex_or_omp_transcript_started_5_min_after_the_launch_is_never_matched() {
    let dir = Dir::new();
    let launched = now_ms() - 10.0 * 60_000.0;
    let later = iso(launched + 5.0 * 60_000.0);
    let stamp = later.replace([':', '.'], "-");
    write_lines(
        &dir.at(&[
            ".omp",
            "agent",
            "sessions",
            "--work-demo--",
            &format!("{stamp}_later.jsonl"),
        ]),
        &[
            json!({ "type": "session", "version": 3, "id": "later", "timestamp": later, "cwd": "/work/demo" }),
            json!({ "type": "message", "id": "u1", "parentId": null, "timestamp": later, "message": { "role": "user", "content": [{ "type": "text", "text": "Hi?" }] } }),
        ],
    );
    let id = "01a0e383-bbb1-7661-880e-56889a9865b3";
    write_lines(
        &dir.at(&[
            ".codex",
            "sessions",
            "2026",
            "09",
            "30",
            &format!("rollout-2026-09-30T12-05-00-{id}.jsonl"),
        ]),
        &[
            json!({ "timestamp": later, "type": "session_meta", "payload": { "id": id, "timestamp": later, "cwd": "/work/demo", "source": "cli" } }),
            json!({ "timestamp": later, "type": "event_msg", "payload": { "type": "user_message", "message": "Hi?" } }),
        ],
    );

    let env = Env::default();
    for kind in ["omp", "codex"] {
        let chat = read_launch(kind, "/work/demo", launched, &env, dir.path());
        assert_eq!(status(&chat), "not_found", "{kind}");
        assert_eq!(transcript(&chat), None, "{kind}");
    }
}

#[test]
fn a_missing_session_id_or_path_is_not_found_not_an_error() {
    let dir = Dir::new();
    let pi_dir = dir.at(&["pi"]);
    let env = Env::from_pairs([("PI_CODING_AGENT_DIR", pi_dir.as_str())]);
    let by_id = read_id("pi", "abc", &env, dir.path());
    assert_eq!(status(&by_id), "not_found");

    let by_path = read_path(
        "omp",
        &dir.at(&["missing.jsonl"]),
        &Env::default(),
        dir.path(),
    );
    assert_eq!(status(&by_path), "not_found");
    assert_eq!(field(&by_path.header, "error"), &Value::Null);
}

#[test]
fn a_kind_without_a_transcript_reader_is_unsupported() {
    // cursor's transcript format is not sourced (docs/research/harnesses/cursor.md).
    let dir = Dir::new();
    let chat = read_path("cursor", &dir.at(&["x.jsonl"]), &Env::default(), dir.path());
    let expected = json!({
        "type": "header",
        "v": 1,
        "kind": "cursor",
        "status": "unsupported",
        "transcript": null,
        "activity": null,
        "turn_open": false,
        "truncated": false,
        "after_found": true,
        "error": null,
    });
    assert_eq!(chat.header, expected);
    assert_eq!(
        jsx::stringify(&chat.header),
        jsx::stringify(&expected),
        "key order"
    );
    assert!(chat.messages.is_empty());
}

// MARK: - harness transcript location (the kinds that are not readers)

// The hermes half passes only once the hermes reader lands: the reader (a
// placeholder in this branch) is what rejects a malformed id before any export.
#[test]
fn kilo_and_hermes_a_path_session_is_not_found_and_a_malformed_id_never_runs_the_harness() {
    let dir = Dir::new();
    let bin = dir.at(&["bin"]);
    let ran = dir.at(&["ran.log"]);
    for kind in ["kilo", "hermes"] {
        write_exec(
            &join(&bin, &[kind]),
            &format!("#!/bin/sh\necho ran >> '{ran}'\nexit 1\n"),
        );
    }
    let env = path_env(&bin);
    for kind in ["kilo", "hermes"] {
        let by_path = read_path(kind, &dir.at(&["x.json"]), &env, dir.path());
        assert_eq!(status(&by_path), "not_found", "{kind}");
        let malformed = read_id(kind, "--format=html", &env, dir.path());
        assert_eq!(status(&malformed), "not_found", "{kind}");
        let no_launch = read_chat(&base(kind, &env, dir.path()));
        assert_eq!(status(&no_launch), "not_found", "{kind} without a launch");
    }
    assert!(!Path::new(&ran).exists());
}

// MARK: - an exported kind with no session id: the launch match over the sessions the harness lists

/// `'text'` for a POSIX shell.
fn shell_quote(text: &str) -> String {
    format!("'{}'", text.replace('\'', "'\\''"))
}

/// A stub harness answering from `answers` (argv joined by spaces → stdout),
/// logging argv and cwd (`stubHarness`). Returns the `Env` whose `PATH` finds it.
fn stub_harness(dir: &Dir, kind: &str, answers: &[(String, String)]) -> Env {
    let bin = dir.at(&["bin"]);
    let answer_dir = dir.at(&[&format!("answers-{kind}")]);
    let _ = fs::remove_dir_all(&answer_dir);
    fs::create_dir_all(&answer_dir).expect("create the answers dir");
    let mut script = format!(
        "#!/bin/sh\nif [ \"$1\" = --version ]; then echo 1.19.5; exit 0; fi\nprintf '%s\\n%s\\n' \"$*\" \"$(pwd -P)\" >> {}\ncase \"$*\" in\n",
        shell_quote(&dir.at(&["calls.log"]))
    );
    for (index, (argv, answer)) in answers.iter().enumerate() {
        let file = join(&answer_dir, &[&index.to_string()]);
        fs::write(&file, answer).expect("write the answer");
        script.push_str(&format!(
            "  {}) cat {} ;;\n",
            shell_quote(argv),
            shell_quote(&file)
        ));
    }
    script.push_str("  *) echo \"unknown: $*\" >&2; exit 1 ;;\nesac\n");
    write_exec(&join(&bin, &[kind]), &script);
    path_env(&bin)
}

/// `(argv, cwd)` of every call the stub logged.
fn calls(dir: &Dir) -> Vec<(String, String)> {
    let text = fs::read_to_string(dir.at(&["calls.log"])).expect("the stub logged its calls");
    let lines: Vec<&str> = text.lines().collect();
    lines
        .chunks(2)
        .map(|pair| (pair[0].to_string(), pair[1].to_string()))
        .collect()
}

fn work(dir: &Dir) -> String {
    dir.at(&["work"])
}

fn other(dir: &Dir) -> String {
    dir.at(&["other"])
}

struct Around {
    other: String,
    early: String,
    later: String,
    own: String,
}

/// Every candidate a launch at `launched` in `work` must not take: one in
/// another directory created closer to the launch, one created before the
/// launch's slack, and one a later Agent started in the same directory.
/// `(id, cwd, created)`, in the JS order.
fn sessions_around(dir: &Dir, launched: f64, ids: &Around) -> Vec<(String, String, f64)> {
    vec![
        (ids.other.clone(), other(dir), launched + 1_000.0),
        (ids.early.clone(), work(dir), launched - 60_000.0),
        (ids.later.clone(), work(dir), launched + 120_000.0),
        (ids.own.clone(), work(dir), launched + 4_000.0),
    ]
}

fn opencode_export(id: &str) -> String {
    jsx::stringify(&json!({
        "info": { "id": id, "slug": "s", "title": "t", "time": { "created": 0, "updated": 0 } },
        "messages": [
            { "info": { "id": "m1", "role": "user", "time": { "created": 0 } }, "parts": [{ "type": "text", "id": "p1", "messageID": "m1", "text": format!("hello {id}") }] },
            { "info": { "id": "m2", "role": "assistant", "time": { "created": 1000 }, "finish": "stop" }, "parts": [{ "type": "text", "id": "p2", "messageID": "m2", "text": format!("reply from {id}") }] },
        ],
    }))
}

fn hermes_export(id: &str, cwd: &str, created: f64) -> Value {
    json!({
        "id": id,
        "cwd": cwd,
        "source": "cli",
        "parent_session_id": null,
        "started_at": created / 1000.0,
        "ended_at": null,
        "messages": [
            { "id": 1, "role": "user", "content": format!("hello {id}"), "timestamp": created / 1000.0 },
            { "id": 2, "role": "assistant", "content": format!("reply from {id}"), "finish_reason": "stop", "timestamp": created / 1000.0 + 1.0 },
        ],
    })
}

/// The local-time fields of an instant: `getFullYear()`, `getMonth() + 1`,
/// `getDate()`, `getHours()`, `getMinutes()`, `getSeconds()`.
fn local_fields(ms: f64) -> [i64; 6] {
    let seconds = (ms / 1000.0).floor() as libc::time_t;
    // SAFETY: `tm` is plain data; localtime_r fills it from `seconds`.
    let tm = unsafe {
        let mut tm: libc::tm = std::mem::zeroed();
        assert!(
            !libc::localtime_r(&seconds, &mut tm).is_null(),
            "localtime_r failed"
        );
        tm
    };
    [
        i64::from(tm.tm_year) + 1900,
        i64::from(tm.tm_mon) + 1,
        i64::from(tm.tm_mday),
        i64::from(tm.tm_hour),
        i64::from(tm.tm_min),
        i64::from(tm.tm_sec),
    ]
}

/// `YYYYMMDD_HHMMSS_<hex>` in local time, the second before `started_at`.
fn hermes_id(ms: f64, hex: &str) -> String {
    let [year, month, day, hour, minute, second] = local_fields(ms - 1_000.0);
    format!("{year}{month:02}{day:02}_{hour:02}{minute:02}{second:02}_{hex}")
}

fn exported_launch_reads_the_session_the_launch_started(kind: &str) {
    let dir = Dir::new();
    let launched = now_ms() - 10.0 * 60_000.0;
    fs::create_dir_all(work(&dir)).expect("create the work dir");
    let ids = Around {
        other: "ses_other".into(),
        early: "ses_early".into(),
        later: "ses_later".into(),
        own: "ses_own".into(),
    };
    let list: Vec<Value> = sessions_around(&dir, launched, &ids)
        .into_iter()
        .map(|(id, cwd, created)| json!({ "id": id, "title": "t", "updated": created + 5_000.0, "created": created, "projectId": "p", "directory": cwd }))
        .collect();
    let mut answers = vec![(
        "session list --format json --pure".to_string(),
        jsx::stringify(&Value::Array(list)),
    )];
    for id in [&ids.other, &ids.early, &ids.later, &ids.own] {
        answers.push((format!("export {id}"), opencode_export(id)));
    }
    let env = stub_harness(&dir, kind, &answers);

    let chat = read_chat(&ReadChatArgs {
        cwd: Some(&work(&dir)),
        launched_at: Some(&iso(launched)),
        status: Some("done"),
        ..base(kind, &env, dir.path())
    });

    assert_eq!(status(&chat), "ok");
    assert_eq!(transcript(&chat), None);
    assert_eq!(texts(&chat), ["hello ses_own", "reply from ses_own"]);
    let calls = calls(&dir);
    assert_eq!(
        fs::canonicalize(&calls[0].1).expect("the list's cwd exists"),
        fs::canonicalize(work(&dir)).expect("the work dir exists"),
        "the list runs in the launch's cwd: it lists that project"
    );
    assert_eq!(calls[1].0, "export ses_own");
}

#[test]
fn opencode_lists_the_projects_sessions_from_the_launchs_cwd_and_reads_the_one_the_launch_started()
{
    exported_launch_reads_the_session_the_launch_started("opencode");
}

#[test]
fn kilo_lists_the_projects_sessions_from_the_launchs_cwd_and_reads_the_one_the_launch_started() {
    exported_launch_reads_the_session_the_launch_started("kilo");
}

// Passes only once the hermes reader lands: the reader is a placeholder in this branch.
#[test]
fn hermes_lists_ids_from_its_sessions_table_local_time_ids_and_exports_each_candidate_for_its_cwd_and_start_roots_only()
 {
    let dir = Dir::new();
    let launched = now_ms() - 10.0 * 60_000.0;
    let ids = Around {
        other: hermes_id(launched + 1_000.0, "aaaaaa"),
        early: hermes_id(launched - 60_000.0, "bbbbbb"),
        later: hermes_id(launched + 120_000.0, "cccccc"),
        own: hermes_id(launched + 4_000.0, "dddddd"),
    };
    let mut all: Vec<Value> = sessions_around(&dir, launched, &ids)
        .into_iter()
        .map(|(id, cwd, created)| hermes_export(&id, &cwd, created))
        .collect();
    // A session the Agent's own session spawned, and an Agent Summary run,
    // both created closer to the launch.
    let mut child = hermes_export(
        &hermes_id(launched + 3_000.0, "eeeeee"),
        &work(&dir),
        launched + 3_000.0,
    );
    child["parent_session_id"] = json!(ids.own);
    let mut summary = hermes_export(
        &hermes_id(launched + 3_500.0, "ffffff"),
        &work(&dir),
        launched + 3_500.0,
    );
    summary["source"] = json!("tool");
    all.push(child);
    all.push(summary);
    let mut table = vec![
        "Title                        Workspace          Last Active   ID".to_string(),
        "─".repeat(60),
    ];
    for session in &all {
        table.push(format!(
            "Waycar session 20261012_000000_abcdef   demo   1m ago   {}",
            field(session, "id").as_str().unwrap_or("")
        ));
    }
    table.push("  … more not shown (use --limit 60 to see more)".to_string());
    let export_argv = |id: &str| format!("sessions export --format jsonl --session-id {id} -");
    let mut answers = vec![("sessions list --limit 50".to_string(), table.join("\n"))];
    for session in &all {
        answers.push((
            export_argv(field(session, "id").as_str().unwrap_or("")),
            jsx::stringify(session),
        ));
    }
    let env = stub_harness(&dir, "hermes", &answers);

    let chat = read_chat(&ReadChatArgs {
        cwd: Some(&work(&dir)),
        launched_at: Some(&iso(launched)),
        ..base("hermes", &env, dir.path())
    });

    assert_eq!(status(&chat), "ok", "{}", error_text(&chat));
    assert_eq!(
        texts(&chat),
        [
            format!("hello {}", ids.own),
            format!("reply from {}", ids.own)
        ]
    );
    let argvs: Vec<String> = calls(&dir).into_iter().map(|call| call.0).collect();
    assert_eq!(argvs[0], "sessions list --limit 50");
    assert!(
        !argvs.contains(&export_argv(&ids.early)),
        "an id from before the launch's slack is never exported"
    );
    assert_eq!(
        argvs.last().map(String::as_str),
        Some(export_argv(&ids.own).as_str()),
        "the chat is read from the matched session"
    );
}

#[test]
fn no_session_started_by_the_launch_or_a_harness_that_cannot_list_is_not_found() {
    let dir = Dir::new();
    let launched = now_ms() - 10.0 * 60_000.0;
    fs::create_dir_all(work(&dir)).expect("create the work dir");
    let list = json!([{ "id": "ses_early", "title": "t", "updated": launched - 50_000.0, "created": launched - 60_000.0, "projectId": "p", "directory": work(&dir) }]);
    let env = stub_harness(
        &dir,
        "opencode",
        &[(
            "session list --format json --pure".to_string(),
            jsx::stringify(&list),
        )],
    );
    let chat = read_launch("opencode", &work(&dir), launched, &env, dir.path());
    assert_eq!(status(&chat), "not_found");
    let failing = stub_harness(&dir, "opencode", &[]);
    let chat = read_launch("opencode", &work(&dir), launched, &failing, dir.path());
    assert_eq!(status(&chat), "not_found");
    let chat = read_launch(
        "opencode",
        &dir.at(&["gone"]),
        launched,
        &failing,
        dir.path(),
    );
    assert_eq!(status(&chat), "not_found");
}

// MARK: - other Agents of the kind in the same cwd (launchRivals)

/// An opencode stub listing `sessions` (`(id, created)` in `work`), and a read
/// for the launch at `at`. Returns the matched session id, or the header status.
fn read_at(
    dir: &Dir,
    at: f64,
    sessions: &[(&str, f64)],
    claimed: &[&str],
    launches: &[f64],
) -> String {
    fs::create_dir_all(work(dir)).expect("create the work dir");
    let list: Vec<Value> = sessions
        .iter()
        .map(|(id, created)| json!({ "id": id, "title": "t", "updated": created + 5_000.0, "created": created, "projectId": "p", "directory": work(dir) }))
        .collect();
    let mut answers = vec![(
        "session list --format json --pure".to_string(),
        jsx::stringify(&Value::Array(list)),
    )];
    for (id, _) in sessions {
        answers.push((format!("export {id}"), opencode_export(id)));
    }
    let env = stub_harness(dir, "opencode", &answers);
    let queries: RefCell<Vec<(String, f64)>> = RefCell::new(Vec::new());
    let launch_rivals = |query: &RivalQuery| -> Rivals {
        queries
            .borrow_mut()
            .push((query.kind.clone(), query.launched));
        Rivals {
            claimed: claimed
                .iter()
                .map(|id| id.to_string())
                .collect::<HashSet<_>>(),
            launches: launches.to_vec(),
        }
    };
    let chat = read_chat(&ReadChatArgs {
        cwd: Some(&work(dir)),
        launched_at: Some(&iso(at)),
        launch_rivals: Some(&launch_rivals),
        ..base("opencode", &env, dir.path())
    });
    assert_eq!(*queries.borrow(), [("opencode".to_string(), at)]);
    if status(&chat) == "ok" {
        texts(&chat)[0].replace("hello ", "")
    } else {
        status(&chat).to_string()
    }
}

#[test]
fn two_launches_either_of_which_could_have_started_a_session_neither_reads_one() {
    let dir = Dir::new();
    let launched = now_ms() - 10.0 * 60_000.0;
    // B launched a second after A and was prompted first.
    let sessions = [("ses_b", launched + 3_000.0), ("ses_a", launched + 5_000.0)];
    assert_eq!(
        read_at(&dir, launched, &sessions, &[], &[launched + 1_000.0]),
        "not_found"
    );
    assert_eq!(
        read_at(&dir, launched + 1_000.0, &sessions, &[], &[launched]),
        "not_found"
    );
}

#[test]
fn an_earlier_agent_keeps_the_session_it_started_before_this_launch_this_launch_takes_the_next() {
    let dir = Dir::new();
    let launched = now_ms() - 10.0 * 60_000.0;
    let earlier = launched - 10.0 * 60_000.0;
    let sessions = [
        ("ses_earlier", earlier + 5_000.0),
        ("ses_own", launched + 4_000.0),
    ];
    assert_eq!(
        read_at(&dir, launched, &sessions, &[], &[earlier]),
        "ses_own"
    );
    assert_eq!(
        read_at(&dir, earlier, &sessions, &[], &[launched]),
        "ses_earlier"
    );
}

#[test]
fn an_earlier_agent_with_no_session_of_its_own_yet_could_own_this_launchs_refused() {
    let dir = Dir::new();
    let launched = now_ms() - 10.0 * 60_000.0;
    let earlier = launched - 10.0 * 60_000.0;
    assert_eq!(
        read_at(
            &dir,
            launched,
            &[("ses_own", launched + 4_000.0)],
            &[],
            &[earlier]
        ),
        "not_found"
    );
}

#[test]
fn a_session_another_agent_names_is_never_taken_however_close() {
    let dir = Dir::new();
    let launched = now_ms() - 10.0 * 60_000.0;
    let sessions = [
        ("ses_theirs", launched + 1_000.0),
        ("ses_own", launched + 4_000.0),
    ];
    assert_eq!(
        read_at(&dir, launched, &sessions, &["ses_theirs"], &[]),
        "ses_own"
    );
}

// The launch match is in transcript.rs/session_export, so this passes with the placeholder hermes reader too.
#[test]
fn hermes_exports_at_most_a_few_of_the_sessions_closest_to_the_launch_per_read() {
    let dir = Dir::new();
    let launched = now_ms() - 10.0 * 60_000.0;
    // Ten sessions elsewhere, each closer to the launch than the Agent's own.
    let others: Vec<Value> = (0..10)
        .map(|i| {
            let created = launched + f64::from(i + 1) * 2_000.0;
            hermes_export(
                &hermes_id(created, &format!("a0000{i}")),
                &other(&dir),
                created,
            )
        })
        .collect();
    let own = hermes_export(
        &hermes_id(launched + 60_000.0, "dddddd"),
        &work(&dir),
        launched + 60_000.0,
    );
    let mut all = others.clone();
    all.push(own);
    let export_argv = |session: &Value| {
        format!(
            "sessions export --format jsonl --session-id {} -",
            field(session, "id").as_str().unwrap_or("")
        )
    };
    let list: Vec<String> = all
        .iter()
        .map(|session| {
            format!(
                "t  demo  1m ago  {}",
                field(session, "id").as_str().unwrap_or("")
            )
        })
        .collect();
    let mut answers = vec![("sessions list --limit 50".to_string(), list.join("\n"))];
    for session in &all {
        answers.push((export_argv(session), jsx::stringify(session)));
    }
    let env = stub_harness(&dir, "hermes", &answers);

    let chat = read_chat(&ReadChatArgs {
        cwd: Some(&work(&dir)),
        launched_at: Some(&iso(launched)),
        ..base("hermes", &env, dir.path())
    });

    assert_eq!(status(&chat), "not_found");
    let exported: Vec<String> = calls(&dir)
        .into_iter()
        .map(|call| call.0)
        .filter(|argv| argv.starts_with("sessions export"))
        .collect();
    let closest: Vec<String> = others[..6].iter().map(export_argv).collect();
    assert_eq!(exported, closest, "the six closest, nearest first");
}

// MARK: - opencode reader

// The vectors run opencode cases through a stub binary too; these cover what
// they cannot: the export failing, a missing binary, a path session.

fn read_opencode(dir: &Dir, env: &Env, status: Option<&str>) -> ChatRead {
    read_chat(&ReadChatArgs {
        session_kind: Some("id"),
        session_value: Some("ses_oc1"),
        status,
        ..base("opencode", env, dir.path())
    })
}

/// Writes an export answer and a stub `opencode` (the first `PATH` entry).
/// The stub logs its argv, so a test can pin the exec path: the session id
/// handed to `opencode export` must be the request's session value.
fn stub_exporting(dir: &Dir, export_text: &str) -> Env {
    let file = write_lines(&dir.at(&["export.json"]), &[json!(export_text)]);
    let bin = dir.at(&["bin"]);
    write_exec(
        &join(&bin, &["opencode"]),
        &format!(
            "#!/bin/sh\nif [ \"$1\" = --version ]; then echo 1.19.5; exit 0; fi\necho \"$@\" >> '{}'\ncat '{file}'\n",
            dir.at(&["argv.log"])
        ),
    );
    path_env(&bin)
}

/// Real OpenCode 2.2.7 mock-model capture, with model/token accounting and
/// extra timestamps omitted; all messages, content and tool states retained.
const OPENCODE_V2_FIXTURE: &str = include_str!("../../../test/fixtures/opencode2-export.json");

fn stub_exporting_v2(dir: &Dir, text: &str) -> Env {
    let file = write_lines(&dir.at(&["export.json"]), &[json!(text)]);
    write_lines(
        &dir.at(&[".local/state/opencode/service.json"]),
        &[json!({
            "url": "http://127.0.0.1:49374", "password": "fixture-password"
        })],
    );
    let bin = dir.at(&["bin"]);
    write_exec(
        &join(&bin, &["opencode"]),
        &format!(
            "#!/bin/sh\nif [ \"$1\" = --version ]; then echo 'opencode v2.2.7'; exit 0; fi\ncat '{file}'\n"
        ),
    );
    path_env(&bin)
}

#[test]
fn opencode_v2_fixture_preserves_turns_tools_interrupts_and_image_media() {
    let dir = Dir::new();
    let mut data = jsx::parse_json(OPENCODE_V2_FIXTURE).unwrap();
    let env = stub_exporting_v2(&dir, OPENCODE_V2_FIXTURE);
    let chat = read_opencode(&dir, &env, Some("working"));
    assert_eq!(status(&chat), "ok");
    assert_eq!(field(&chat.header, "turn_open"), &json!(false));
    assert_eq!(
        texts(&chat),
        [
            "hello fixture",
            "waycar-mock-reply: fixture",
            "run it WAYCAR_TOOL",
            "waycar-tool-done: saw waycar-tool-ok",
            "run again WAYCAR_TOOL",
            "",
            "ask WAYCAR_ASK",
            "waycar-tool-done: tool output missing waycar-tool-ok",
            "look at this image",
            "waycar-mock-reply: image",
            "slow WAYCAR_SLOW",
            "",
        ]
    );
    assert_eq!(ids(&chat)[1], "msg_1cca7e1780014OZXVGyc2jAqLp");
    assert_eq!(ids(&chat)[5], "msg_1cca810c6001EjcVtOWfQUGO9E");
    assert_eq!(ids(&chat)[11], "msg_1cca844270018robz36zLRWDzt");
    assert_eq!(
        chat.messages[9]["media"],
        json!([{
            "id": format!("inline:/messages/13/files/0/data#sha256:{}", super::sha256_hex(
                data["messages"][13]["files"][0]["data"].as_str().unwrap().as_bytes()
            )),
            "kind": "image", "mime": "image/png",
            "inline": {"session": "ses_oc1", "pointer": "/messages/13/files/0/data"}
        }])
    );
    assert!(!super::format_ndjson(&chat).contains("iVBOR"));

    // Read the same capture while its tool step was the newest message.
    data["messages"].as_array_mut().unwrap().truncate(5);
    let env = stub_exporting_v2(&dir, &jsx::stringify(&data));
    let running = read_opencode(&dir, &env, Some("idle"));
    assert_eq!(field(&running.header, "turn_open"), &json!(true));
    assert_eq!(
        field(&running.header, "activity"),
        &json!("Running echo waycar-tool-ok")
    );
    assert_eq!(
        texts(&running),
        [
            "hello fixture",
            "waycar-mock-reply: fixture",
            "run it WAYCAR_TOOL"
        ]
    );

    // The real declined-tool step has no idle marker after it.
    data = jsx::parse_json(OPENCODE_V2_FIXTURE).unwrap();
    data["messages"].as_array_mut().unwrap().truncate(9);
    let env = stub_exporting_v2(&dir, &jsx::stringify(&data));
    let declined = read_opencode(&dir, &env, Some("working"));
    assert_eq!(field(&declined.header, "turn_open"), &json!(false));
    assert_eq!(texts(&declined).last().unwrap(), "");
}

#[test]
fn opencode_v2_reasoning_and_failures_follow_v1_turn_semantics() {
    let dir = Dir::new();
    let mut data = json!({"messages": [
        {"id": "u1", "type": "user", "text": "Help"},
        {"id": "a1", "type": "assistant", "content": [{"type": "reasoning", "text": "private"}]},
        {"id": "s1", "type": "synthetic", "text": "injected"}
    ]});
    let env = stub_exporting_v2(&dir, &jsx::stringify(&data));
    let thinking = read_opencode(&dir, &env, Some("idle"));
    assert_eq!(texts(&thinking), ["Help"]);
    assert_eq!(field(&thinking.header, "activity"), &json!("Thinking"));
    assert_eq!(field(&thinking.header, "turn_open"), &json!(true));

    for ending in [
        json!({"id": "e1", "type": "idle", "outcome": "failed", "error": {"message": "Model unavailable"}}),
        json!({"id": "e1", "type": "assistant", "content": [], "finish": "error", "error": {"type": "api", "message": "Model unavailable"}}),
    ] {
        data["messages"].as_array_mut().unwrap().push(ending);
        let env = stub_exporting_v2(&dir, &jsx::stringify(&data));
        let failed = read_opencode(&dir, &env, Some("working"));
        assert_eq!(
            summary(&failed),
            pairs(&[("u1", "Help"), ("e1", "Model unavailable")])
        );
        assert_eq!(field(&failed.header, "turn_open"), &json!(false));
        // The optional idle error must not erase the assistant's reason.
        data["messages"].as_array_mut().unwrap().push(json!({
            "id": "idle", "type": "idle", "outcome": "failed"
        }));
        let env = stub_exporting_v2(&dir, &jsx::stringify(&data));
        let idle = read_opencode(&dir, &env, Some("working"));
        assert_eq!(summary(&idle), summary(&failed));
        data["messages"].as_array_mut().unwrap().pop();
        data["messages"].as_array_mut().unwrap().pop();
    }
}

fn export_json(messages: Vec<Value>) -> String {
    jsx::stringify(
        &json!({ "info": { "id": "ses_oc1", "slug": "demo", "title": "Demo", "time": { "created": 0, "updated": 0 } }, "messages": messages }),
    )
}

fn user_message(id: &str, text: &str) -> Value {
    json!({ "info": { "id": id, "role": "user", "time": { "created": 0 } }, "parts": [{ "type": "text", "id": format!("{id}-p"), "messageID": id, "text": text }] })
}

/// `assistantMessage`; `finish: None` is the JS `finish: undefined`.
fn assistant_message(id: &str, parts: Vec<Value>, finish: Option<&str>) -> Value {
    let mut info = Map::new();
    info.insert("id".into(), json!(id));
    info.insert("role".into(), json!("assistant"));
    info.insert("time".into(), json!({ "created": 1000 }));
    if let Some(finish) = finish {
        info.insert("finish".into(), json!(finish));
    }
    json!({ "info": info, "parts": parts })
}

#[test]
fn a_failed_export_no_such_session_is_not_found_not_an_error() {
    let dir = Dir::new();
    let bin = dir.at(&["bin"]);
    write_exec(
        &join(&bin, &["opencode"]),
        "#!/bin/sh\nif [ \"$1\" = --version ]; then echo 1.19.5; exit 0; fi\necho \"Exporting session: ses_oc1\" >&2\necho \"Session not found: ses_oc1\" >&2\nexit 1\n",
    );

    let chat = read_opencode(&dir, &path_env(&bin), None);

    assert_eq!(status(&chat), "not_found");
    assert_eq!(transcript(&chat), None);
    assert_eq!(field(&chat.header, "error"), &Value::Null);
    assert!(chat.messages.is_empty());
}

#[test]
fn a_missing_opencode_binary_is_not_found() {
    let dir = Dir::new();
    let env = Env::from_pairs([("PATH", dir.at(&["nowhere"]))]);

    let chat = read_opencode(&dir, &env, None);

    assert_eq!(status(&chat), "not_found");
    assert!(chat.messages.is_empty());
}

#[test]
fn an_export_that_exits_0_without_json_is_an_error() {
    let dir = Dir::new();
    let bin = dir.at(&["bin"]);
    write_exec(
        &join(&bin, &["opencode"]),
        "#!/bin/sh\necho \"Exporting session: ses_oc1\" >&2\necho not json\n",
    );

    let chat = read_opencode(&dir, &path_env(&bin), None);

    assert_eq!(status(&chat), "error");
    assert_eq!(transcript(&chat), None);
    assert!(
        error_text(&chat).contains("did not print JSON"),
        "{}",
        error_text(&chat)
    );
}

#[test]
fn idle_does_not_complete_a_turn_whose_last_assistant_message_has_no_finished_step() {
    let dir = Dir::new();
    let env = stub_exporting(
        &dir,
        &export_json(vec![
            user_message("msg_oc1", "Go on."),
            assistant_message(
                "msg_oc2",
                vec![
                    json!({ "type": "tool", "tool": "read", "callID": "call_1", "state": { "status": "completed", "input": { "filePath": "src/app.ts" }, "output": "ok", "title": "app.ts", "metadata": {}, "time": { "start": 0, "end": 1 } } }),
                ],
                None,
            ),
        ]),
    );

    let chat = read_opencode(&dir, &env, Some("idle"));

    assert_eq!(status(&chat), "ok");
    assert_eq!(field(&chat.header, "turn_open"), &json!(true));
    assert_eq!(field(&chat.header, "activity"), &json!("Reading app.ts"));
    assert_eq!(ids(&chat), ["msg_oc1"]);
    // The stub received exactly the session id the reader was given: never a
    // marker path or an empty string.
    assert_eq!(
        fs::read_to_string(dir.at(&["argv.log"])).expect("argv.log"),
        "export ses_oc1\n"
    );
}

#[test]
fn a_trailing_tool_calls_finish_keeps_the_turn_open_under_an_idle_status() {
    let dir = Dir::new();
    let env = stub_exporting(
        &dir,
        &export_json(vec![
            user_message("msg_oc1", "Go on."),
            assistant_message(
                "msg_oc2",
                vec![
                    json!({ "type": "text", "id": "prt_1", "messageID": "msg_oc2", "text": "Working on it." }),
                ],
                Some("tool-calls"),
            ),
        ]),
    );

    let chat = read_opencode(&dir, &env, Some("idle"));

    assert_eq!(field(&chat.header, "turn_open"), &json!(true));
    assert_eq!(field(&chat.header, "activity"), &json!("Working on it."));
    assert_eq!(ids(&chat), ["msg_oc1"]);
}

#[test]
fn finish_error_without_a_recorded_error_ends_the_turn_quietly() {
    let dir = Dir::new();
    let env = stub_exporting(
        &dir,
        &export_json(vec![
            user_message("msg_oc1", "Go on."),
            assistant_message("msg_oc2", vec![], Some("error")),
        ]),
    );

    let chat = read_opencode(&dir, &env, Some("working"));

    assert_eq!(field(&chat.header, "turn_open"), &json!(false));
    assert_eq!(
        summary(&chat),
        pairs(&[("msg_oc1", "Go on."), ("msg_oc2", "")])
    );
}

#[test]
fn a_subtask_part_shows_running_a_subagent() {
    let dir = Dir::new();
    let env = stub_exporting(
        &dir,
        &export_json(vec![
            user_message("msg_oc1", "Check the docs."),
            assistant_message(
                "msg_oc2",
                vec![
                    json!({ "type": "subtask", "id": "prt_1", "messageID": "msg_oc2", "prompt": "Read the docs", "description": "docs", "agent": "explore" }),
                ],
                None,
            ),
        ]),
    );

    let chat = read_opencode(&dir, &env, Some("working"));

    assert_eq!(field(&chat.header, "turn_open"), &json!(true));
    assert_eq!(
        field(&chat.header, "activity"),
        &json!("Running a subagent")
    );
}

#[test]
fn an_export_without_a_messages_array_is_an_error() {
    let dir = Dir::new();
    let bin = dir.at(&["bin"]);
    write_exec(
        &join(&bin, &["opencode"]),
        "#!/bin/sh\necho '{\"info\":{\"id\":\"ses_oc1\"}}'\n",
    );

    let chat = read_opencode(&dir, &path_env(&bin), None);

    assert_eq!(status(&chat), "error");
    assert!(
        error_text(&chat).contains("messages array"),
        "{}",
        error_text(&chat)
    );
}

#[test]
fn a_session_kind_path_is_not_found_opencode_never_pins_one() {
    let dir = Dir::new();
    let chat = read_path(
        "opencode",
        &dir.at(&["x.jsonl"]),
        &Env::default(),
        dir.path(),
    );

    assert_eq!(status(&chat), "not_found");
    assert_eq!(transcript(&chat), None);
    assert_eq!(field(&chat.header, "error"), &Value::Null);
}

#[test]
fn no_session_is_not_found_there_is_no_cwd_heuristic() {
    let dir = Dir::new();
    let env = Env::default();
    let chat = read_launch("opencode", "/work/demo", now_ms(), &env, dir.path());

    assert_eq!(status(&chat), "not_found");
    assert!(chat.messages.is_empty());
}

// MARK: - output limits

fn three_turns(dir: &Dir) -> String {
    let mut records = claude_turn(1, "/w");
    records.extend(claude_turn(2, "/w"));
    records.extend(claude_turn(3, "/w"));
    write_lines(&dir.at(&["t.jsonl"]), &records)
}

#[test]
fn max_messages_keeps_the_newest_and_marks_the_header_truncated() {
    let dir = Dir::new();
    let file = three_turns(&dir);
    let env = Env::default();

    let chat = read_chat(&ReadChatArgs {
        session_kind: Some("path"),
        session_value: Some(&file),
        max_messages: Some(4.0),
        ..base("claude", &env, dir.path())
    });
    assert_eq!(field(&chat.header, "truncated"), &json!(true));
    assert_eq!(ids(&chat), ["u2", "a2", "u3", "a3"]);

    let all = read_chat(&ReadChatArgs {
        session_kind: Some("path"),
        session_value: Some(&file),
        max_messages: Some(6.0),
        ..base("claude", &env, dir.path())
    });
    assert_eq!(field(&all.header, "truncated"), &json!(false));
    assert_eq!(all.messages.len(), 6);
}

#[test]
fn max_messages_applies_after_after() {
    let dir = Dir::new();
    let file = three_turns(&dir);
    let env = Env::default();

    let chat = read_chat(&ReadChatArgs {
        session_kind: Some("path"),
        session_value: Some(&file),
        after: Some("a1"),
        max_messages: Some(4.0),
        ..base("claude", &env, dir.path())
    });
    assert_eq!(field(&chat.header, "truncated"), &json!(false));
    assert_eq!(ids(&chat), ["u2", "a2", "u3", "a3"]);
}

#[test]
fn caps_each_text_at_20_000_characters() {
    let dir = Dir::new();
    let long = "x".repeat(25_000);
    let file = write_lines(
        &dir.at(&["t.jsonl"]),
        &[claude_user(
            "u1",
            "2026-09-30T12:00:00.000Z",
            json!(long),
            "/work/demo",
        )],
    );

    let chat = read_file("claude", &file, Some("working"), None, dir.path());
    let message = texts(&chat).remove(0);
    assert_eq!(jsx::utf16_len(&message), 20_000);
    assert!(message.starts_with(&"x".repeat(19_999)));
    assert!(message.ends_with('…'));
}

// MARK: - activity

fn activity_case(block: Value, expected: &str) {
    let dir = Dir::new();
    let file = write_lines(
        &dir.at(&["t.jsonl"]),
        &[
            claude_user("u1", "2026-09-30T12:00:00.000Z", json!("Go."), "/work/demo"),
            claude_reply(
                "a1",
                "2026-09-30T12:00:01.000Z",
                json!([block]),
                "tool_use",
                "/work/demo",
            ),
        ],
    );
    let chat = read_file("claude", &file, Some("working"), None, dir.path());
    assert_eq!(field(&chat.header, "turn_open"), &json!(true));
    assert_eq!(field(&chat.header, "activity"), &json!(expected));
}

#[test]
fn open_turn_ending_in_read_shows_reading_readme_md() {
    activity_case(
        json!({ "type": "tool_use", "name": "Read", "input": { "file_path": "/work/demo/src/README.md" } }),
        "Reading README.md",
    );
}

#[test]
fn open_turn_ending_in_write_shows_editing_notes_txt() {
    activity_case(
        json!({ "type": "tool_use", "name": "Write", "input": { "file_path": "/work/demo/notes.txt", "content": "x" } }),
        "Editing notes.txt",
    );
}

#[test]
fn open_turn_ending_in_grep_shows_searching() {
    activity_case(
        json!({ "type": "tool_use", "name": "Grep", "input": { "pattern": "TODO" } }),
        "Searching",
    );
}

#[test]
fn open_turn_ending_in_web_fetch_shows_searching_the_web() {
    activity_case(
        json!({ "type": "tool_use", "name": "WebFetch", "input": { "url": "https://example.com" } }),
        "Searching the web",
    );
}

#[test]
fn open_turn_ending_in_task_shows_running_a_subagent() {
    activity_case(
        json!({ "type": "tool_use", "name": "Task", "input": { "description": "look around" } }),
        "Running a subagent",
    );
}

#[test]
fn open_turn_ending_in_todo_write_shows_using_todo_write() {
    activity_case(
        json!({ "type": "tool_use", "name": "TodoWrite", "input": { "todos": [] } }),
        "Using TodoWrite",
    );
}

#[test]
fn open_turn_ending_in_text_shows_its_first_line() {
    activity_case(
        json!({ "type": "text", "text": "\nFirst I will look.\nThen fix it." }),
        "First I will look.",
    );
}

#[test]
fn open_turn_ending_in_thinking_shows_thinking() {
    activity_case(
        json!({ "type": "thinking", "thinking": "Hmm." }),
        "Thinking",
    );
}

#[test]
fn a_long_command_is_cut_to_40_characters() {
    let dir = Dir::new();
    let command = "npm test -- --runInBand --reporter=verbose --coverage";
    let file = write_lines(
        &dir.at(&["t.jsonl"]),
        &[
            claude_user("u1", "2026-09-30T12:00:00.000Z", json!("Go."), "/work/demo"),
            claude_reply(
                "a1",
                "2026-09-30T12:00:01.000Z",
                json!([{ "type": "tool_use", "name": "Bash", "input": { "command": command } }]),
                "tool_use",
                "/work/demo",
            ),
        ],
    );
    let chat = read_file("claude", &file, Some("working"), None, dir.path());
    assert_eq!(
        field(&chat.header, "activity"),
        &json!(format!("Running {}…", &command[..39]))
    );
}

// MARK: - turn rules

fn omp_session() -> Value {
    json!({ "type": "session", "version": 3, "id": "sess", "timestamp": "2026-09-30T12:00:00.000Z", "cwd": "/work/demo" })
}

fn omp_message(id: &str, parent_id: Option<&str>, second: u32, message: Value) -> Value {
    json!({
        "type": "message",
        "id": id,
        "parentId": parent_id,
        "timestamp": format!("2026-09-30T12:00:{second:02}.000Z"),
        "message": message,
    })
}

fn omp_user(id: &str, parent_id: Option<&str>, second: u32, text: &str) -> Value {
    omp_message(
        id,
        parent_id,
        second,
        json!({ "role": "user", "content": [{ "type": "text", "text": text }] }),
    )
}

fn omp_reply(
    id: &str,
    parent_id: Option<&str>,
    second: u32,
    content: Value,
    stop_reason: &str,
    extra: Option<Value>,
) -> Value {
    let mut message = Map::new();
    message.insert("role".into(), json!("assistant"));
    message.insert("content".into(), content);
    message.insert("stopReason".into(), json!(stop_reason));
    if let Some(Value::Object(extra)) = extra {
        message.extend(extra);
    }
    omp_message(id, parent_id, second, Value::Object(message))
}

#[test]
fn pi_idle_does_not_complete_a_turn_whose_last_record_is_a_prompt_an_end_marker_does() {
    let dir = Dir::new();
    let mut records = vec![
        omp_session(),
        omp_user("u1", None, 1, "First?"),
        omp_reply(
            "a1",
            Some("u1"),
            2,
            json!([{ "type": "text", "text": "One." }]),
            "stop",
            None,
        ),
        omp_user("u2", Some("a1"), 3, "Second?"),
    ];
    let file = write_lines(&dir.at(&["t.jsonl"]), &records);
    let open = read_file("pi", &file, Some("idle"), None, dir.path());
    assert_eq!(field(&open.header, "turn_open"), &json!(true));
    assert_eq!(field(&open.header, "activity"), &json!("Thinking"));
    assert_eq!(
        summary(&open),
        pairs(&[("u1", "First?"), ("a1", "One."), ("u2", "Second?")])
    );

    records.push(omp_reply(
        "a2",
        Some("u2"),
        4,
        json!([{ "type": "text", "text": "Two." }]),
        "stop",
        None,
    ));
    let file = write_lines(&dir.at(&["t.jsonl"]), &records);
    let done = read_file("pi", &file, Some("idle"), None, dir.path());
    assert_eq!(field(&done.header, "turn_open"), &json!(false));
    assert_eq!(
        summary(&done).last(),
        Some(&("a2".to_string(), "Two.".to_string()))
    );
}

#[test]
fn pi_a_message_whose_nearest_message_parent_is_a_tool_call_steers_past_non_message_entries() {
    let dir = Dir::new();
    let file = write_lines(
        &dir.at(&["t.jsonl"]),
        &[
            omp_session(),
            omp_user("u1", None, 1, "Tidy the repo."),
            omp_reply(
                "a1",
                Some("u1"),
                2,
                json!([{ "type": "toolCall", "id": "tc", "name": "bash", "arguments": { "command": "git status" } }]),
                "toolUse",
                None,
            ),
            json!({ "type": "model_change", "id": "m1", "parentId": "a1", "timestamp": "2026-09-30T12:00:03.000Z", "provider": "demo", "modelId": "demo" }),
            omp_user("u2", Some("m1"), 4, "Skip the docs folder."),
            omp_reply(
                "a2",
                Some("u2"),
                5,
                json!([{ "type": "text", "text": "Tidied, docs untouched." }]),
                "stop",
                None,
            ),
        ],
    );

    let chat = read_file("pi", &file, None, None, dir.path());
    assert_eq!(
        summary(&chat),
        pairs(&[
            ("u1", "Tidy the repo."),
            ("u2", "Skip the docs folder."),
            ("a2", "Tidied, docs untouched.")
        ])
    );
}

#[test]
fn omp_an_error_shows_until_its_automatic_retry_replies_and_the_retry_drops_the_errors_id() {
    let dir = Dir::new();
    let mut records = vec![
        omp_session(),
        omp_user("u1", None, 1, "Summarize the PR."),
        omp_reply(
            "e1",
            Some("u1"),
            2,
            json!([]),
            "error",
            Some(json!({ "errorMessage": "Synthetic: rate limited" })),
        ),
    ];
    let file = write_lines(&dir.at(&["t.jsonl"]), &records);
    let failed = read_file("omp", &file, Some("working"), None, dir.path());
    assert_eq!(field(&failed.header, "turn_open"), &json!(false));
    assert_eq!(
        summary(&failed),
        pairs(&[
            ("u1", "Summarize the PR."),
            ("e1", "Synthetic: rate limited")
        ])
    );

    records.push(omp_reply(
        "a2",
        Some("e1"),
        9,
        json!([{ "type": "text", "text": "It adds a retry." }]),
        "stop",
        None,
    ));
    let file = write_lines(&dir.at(&["t.jsonl"]), &records);
    let retried = read_file("omp", &file, Some("working"), Some("e1"), dir.path());
    assert_eq!(field(&retried.header, "after_found"), &json!(false));
    assert_eq!(
        summary(&retried),
        pairs(&[("u1", "Summarize the PR."), ("a2", "It adds a retry.")])
    );
}

#[test]
fn codex_a_turn_that_ends_on_commentary_has_an_empty_reply_not_the_commentary() {
    let dir = Dir::new();
    let file = write_lines(
        &dir.at(&["t.jsonl"]),
        &[
            json!({ "timestamp": "2026-09-30T12:00:00.000Z", "type": "session_meta", "payload": { "id": "s", "cwd": "/work/demo", "source": "cli" } }),
            json!({ "timestamp": "2026-09-30T12:00:01.000Z", "type": "event_msg", "payload": { "type": "task_started", "turn_id": "t1" } }),
            json!({ "timestamp": "2026-09-30T12:00:01.000Z", "type": "event_msg", "payload": { "type": "user_message", "message": "Check CI." } }),
            json!({ "timestamp": "2026-09-30T12:00:02.000Z", "type": "response_item", "payload": { "type": "function_call", "name": "exec_command", "arguments": "{}" } }),
            json!({
                "timestamp": "2026-09-30T12:00:03.000Z",
                "type": "response_item",
                "payload": { "type": "message", "role": "assistant", "phase": "commentary", "content": [{ "type": "output_text", "text": "Still checking." }] },
            }),
            json!({ "timestamp": "2026-09-30T12:00:04.000Z", "type": "event_msg", "payload": { "type": "task_complete", "turn_id": "t1", "last_agent_message": "Still checking." } }),
        ],
    );

    let chat = read_file("codex", &file, None, None, dir.path());
    assert_eq!(
        summary(&chat),
        pairs(&[("u:t1", "Check CI."), ("a:t1", "")])
    );
}

const BASE64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn base64_encode(bytes: &[u8]) -> String {
    let mut out = String::new();
    for chunk in bytes.chunks(3) {
        let n = chunk.iter().enumerate().fold(0u32, |acc, (i, byte)| {
            acc | u32::from(*byte) << (16 - 8 * i)
        });
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(char::from(BASE64[((n >> (18 - 6 * i)) & 63) as usize]));
            } else {
                out.push('=');
            }
        }
    }
    out
}

fn base64_decode(text: &str) -> String {
    let mut out = Vec::new();
    let (mut bits, mut count) = (0u32, 0);
    for byte in text.bytes() {
        let Some(value) = BASE64.iter().position(|b| *b == byte) else {
            continue;
        };
        bits = (bits << 6) | value as u32;
        count += 6;
        if count >= 8 {
            count -= 8;
            out.push((bits >> count) as u8);
            bits &= (1 << count) - 1;
        }
    }
    String::from_utf8(out).expect("UTF-8 image text")
}

#[test]
fn pi_a_turns_reply_carries_its_first_12_distinct_tool_result_images_in_order_across_a_steering_prompt()
 {
    let dir = Dir::new();
    let image = |n: u32| json!({ "type": "image", "data": base64_encode(format!("image {n}").as_bytes()), "mimeType": "image/png" });
    let result = |id: &str, parent_id: &str, second: u32, images: Vec<Value>| {
        omp_message(
            id,
            Some(parent_id),
            second,
            json!({ "role": "toolResult", "toolCallId": "tc", "toolName": "read", "content": images }),
        )
    };
    let call = |id: &str, parent_id: &str, second: u32| {
        omp_reply(
            id,
            Some(parent_id),
            second,
            json!([{ "type": "toolCall", "id": "tc", "name": "read", "arguments": { "path": "x.png" } }]),
            "toolUse",
            None,
        )
    };
    let file = write_lines(
        &dir.at(&["t.jsonl"]),
        &[
            omp_session(),
            omp_user("u1", None, 1, "Show every frame."),
            call("a1", "u1", 2),
            result("r1", "a1", 3, [1, 2, 3, 4, 5].map(image).to_vec()),
            omp_user("u2", Some("r1"), 4, "Keep going."),
            call("a2", "u2", 5),
            result(
                "r2",
                "a2",
                6,
                [3, 6, 7, 8, 9, 10, 11, 12, 13, 14].map(image).to_vec(),
            ),
            omp_reply(
                "a3",
                Some("r2"),
                7,
                json!([{ "type": "text", "text": "All frames shown." }]),
                "stop",
                None,
            ),
        ],
    );

    let chat = read_file("pi", &file, None, None, dir.path());
    assert_eq!(
        summary(&chat),
        pairs(&[
            ("u1", "Show every frame."),
            ("u2", "Keep going."),
            ("a3", "All frames shown.")
        ])
    );
    // Each item names its string by the line's byte offset and a pointer into it.
    let bytes = fs::read(&file).expect("read the transcript");
    let media = field(&chat.messages[2], "media")
        .as_array()
        .cloned()
        .unwrap_or_default();
    let frames: Vec<String> = media
        .iter()
        .map(|item| {
            let inline = field(item, "inline");
            let offset = field(inline, "offset").as_f64().unwrap_or(0.0) as usize;
            let end = bytes[offset..]
                .iter()
                .position(|b| *b == 0x0a)
                .map_or(bytes.len(), |at| offset + at);
            let record =
                jsx::parse_json(std::str::from_utf8(&bytes[offset..end]).expect("a UTF-8 line"))
                    .expect("a JSON line");
            let pointer = field(inline, "pointer").as_str().unwrap_or("");
            let index: usize = pointer
                .split('/')
                .nth(3)
                .and_then(|part| part.parse().ok())
                .expect("an index in the pointer");
            base64_decode(
                field(&field(field(&record, "message"), "content")[index], "data")
                    .as_str()
                    .unwrap_or(""),
            )
        })
        .collect();
    let expected: Vec<String> = (1..=12).map(|n| format!("image {n}")).collect();
    assert_eq!(frames, expected);
}

// MARK: - lastReply

fn message(id: &str, role: &str, text: &str) -> Value {
    json!({ "type": "message", "id": id, "role": role, "text": text, "ts": null })
}

fn chat_of(messages: Vec<Value>) -> ChatRead {
    ChatRead {
        header: Value::Null,
        messages,
    }
}

#[test]
fn last_reply_returns_the_last_assistant_text_even_an_empty_one() {
    let messages = vec![
        message("u1", "user", "Q1"),
        message("a1", "assistant", "A1"),
        message("u2", "user", "Q2"),
        message("a2", "assistant", ""),
        message("u3", "user", "Q3"),
    ];
    assert_eq!(last_reply(&chat_of(messages.clone())), Some(String::new()));
    assert_eq!(
        last_reply(&chat_of(messages[..3].to_vec())),
        Some("A1".to_string())
    );
}

#[test]
fn last_reply_is_null_without_an_assistant_message() {
    assert_eq!(last_reply(&chat_of(Vec::new())), None);
    assert_eq!(last_reply(&chat_of(vec![message("u1", "user", "Q")])), None);
}
