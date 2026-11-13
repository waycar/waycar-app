//! Reads one Agent's chat from its harness's transcript (chat-transcript.js).
//!
//! Turns a harness's own session transcript into the chat the app's Chat view
//! shows: real user prompts plus the final assistant reply of each completed
//! turn, and a short activity line for the open turn. Never scrapes the
//! terminal screen.
//!
//! claude, codex, omp, pi, opencode and kilo are parsed here; every other
//! harness has its own reader under `chat::readers`. Transcripts can run to
//! tens of megabytes, so every JSONL file is read line by line; malformed
//! lines and unknown record types are skipped. opencode, kilo and hermes keep
//! no transcript file at all (their sessions live in their own databases), so
//! their branches run the harness's own export command instead (see
//! `chat::session_export`).
//!
//! # Differences from the JS
//!
//! - A tool call id or tool-result call id that is not a JSON string reaches a
//!   `TurnObserver` as absent (the JS passes any value through; a numeric
//!   `tool_use_id` would still match a numeric `id` there).
//! - `fileURLToPath` is a hand-written WHATWG `file:` URL reduction (see
//!   `file_url_to_path`): a host other than empty or `localhost` (after
//!   percent-decoding and ASCII lowercasing) is refused, as Node does on
//!   posix, but IDNA mapping of exotic host spellings (full-width letters,
//!   soft hyphens) is not applied.
//! - A session path containing a NUL byte reports its error as `EIO` rather
//!   than Node's `ERR_INVALID_ARG_VALUE`.
//! - The signal passed to `parse_transcript` is an `Arc<AbortSignal>`, because
//!   the export runner shares it with its watcher thread.

use std::cell::{Cell, RefCell};
use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use crate::chat::shared::sha256_hex;
use serde_json::{Map, Value, json};

use crate::chat::readers::{LaunchQuery, ReaderContext, reader};
use crate::chat::session_export::{Candidate, ExportOptions, launch_candidates, session_export};
use crate::chat::shared::{
    AbortSignal, ChatError, ChatResult, ChatTurns, ErrorKind, FileStat, Found, LAUNCH_SLACK_MS,
    PROBE_LINES, PickArgs, Prompt, ToolCall, ToolImage, ToolResult, base64_data_url_prefix,
    expand_home, launched_ms, list_names, newest_file, parse_json_object, parse_time, path_forms,
    pick_by_launch, read_records, safe_name, stat_file, subdirectories, tool_activity, tool_image,
    walk_files,
};
use crate::env::Env;
use crate::jspath;
use crate::jsx::{self, field, get, trim, trim_start, truthy};

const DEFAULT_MAX_MESSAGES: f64 = 200.0;
/// At most this many sessions are exported to read their cwd and start, per
/// read (hermes).
const MAX_LAUNCH_EXPORTS: usize = 6;

const CLAUDE_WRAPPERS: [&str; 8] = [
    "<command-name>",
    "<command-message>",
    "<command-args>",
    "<local-command-stdout>",
    "<local-command-caveat>",
    "<bash-input>",
    "<bash-stdout>",
    "<bash-stderr>",
];
/// A slash command record: its wrappers, in whatever order Claude Code wrote
/// them.
const CLAUDE_COMMANDS: [&str; 3] = ["<command-name>", "<command-message>", "<command-args>"];
/// Claude Code's own filler (e.g. "No response requested."); API errors carry
/// `isApiErrorMessage`.
const CLAUDE_SYNTHETIC_MODEL: &str = "<synthetic>";
const CLAUDE_INTERRUPT: &str = "[Request interrupted by user";
const CLAUDE_TASK_NOTIFICATION: &str = "<task-notification>";
const CODEX_INJECTIONS: [&str; 6] = [
    "<environment_context>",
    "<user_instructions>",
    "<INSTRUCTIONS>",
    "<codex_internal",
    "<turn_aborted>",
    "# AGENTS.md instructions",
];
const CODEX_TOOL_TYPES: [&str; 5] = [
    "function_call",
    "custom_tool_call",
    "local_shell_call",
    "web_search_call",
    "tool_search_call",
];

/// Harnesses read through their export command: a session id (else the
/// launch match over the sessions the harness lists) names a chat, and the
/// header names no file.
fn is_exported(kind: &str) -> bool {
    matches!(kind, "opencode" | "kilo" | "hermes")
}

/// `Object.hasOwn(PARSERS, kind)`.
fn has_parser(kind: &str) -> bool {
    matches!(
        kind,
        "claude" | "codex" | "omp" | "pi" | "opencode" | "kilo"
    ) || reader(kind).is_some()
}

#[cfg(test)]
mod tests;

// MARK: - Public API

/// `launchRivals({kind, cwd, launched})`'s question: the other Agents an
/// exported kind's launch match must not take a session from.
pub struct RivalQuery {
    pub kind: String,
    pub cwd: String,
    /// Epoch ms.
    pub launched: f64,
}

/// Its answer (launch-rivals.js `launchRivals`).
pub struct Rivals {
    pub claimed: HashSet<String>,
    pub launches: Vec<f64>,
}

pub struct ReadChatArgs<'a> {
    pub kind: &'a str,
    /// `"id"` or `"path"`.
    pub session_kind: Option<&'a str>,
    pub session_value: Option<&'a str>,
    pub cwd: Option<&'a str>,
    /// ISO 8601 text, as the request carried it.
    pub launched_at: Option<&'a str>,
    pub launch_rivals: Option<&'a dyn Fn(&RivalQuery) -> Rivals>,
    pub status: Option<&'a str>,
    pub after: Option<&'a str>,
    /// `Number.isInteger(maxMessages) && maxMessages > 0`, else 200.
    pub max_messages: Option<f64>,
    pub env: &'a Env,
    pub home: &'a str,
}

/// `{header, messages}`: the header object and the message objects, in the
/// JS key order.
pub struct ChatRead {
    pub header: Value,
    pub messages: Vec<Value>,
}

pub struct ParseArgs<'a> {
    pub kind: &'a str,
    pub session_kind: Option<&'a str>,
    pub session_value: Option<&'a str>,
    pub cwd: Option<&'a str>,
    pub launched_at: Option<&'a str>,
    pub launch_rivals: Option<&'a dyn Fn(&RivalQuery) -> Rivals>,
    pub env: &'a Env,
    pub home: &'a str,
    pub signal: Option<&'a Arc<AbortSignal>>,
}

/// Read the chat for one Agent. Never fails for a missing or unreadable
/// transcript: the header's `status` says what happened (`ok`, `not_found`,
/// `unsupported` or `error`). `launch_rivals`, when given, names the other
/// Agents an exported kind's launch match must not take a session from
/// (launch-rivals.js).
pub fn read_chat(args: &ReadChatArgs<'_>) -> ChatRead {
    let kind = args.kind;
    if !has_parser(kind) {
        return ChatRead {
            header: make_header(kind, "unsupported", &HeaderExtras::default()),
            messages: Vec::new(),
        };
    }
    let mut transcript: Option<String> = None;
    match read_located(args, &mut transcript) {
        Ok(chat) => chat,
        Err(error) => {
            if error.is_missing() || matches!(error.kind, ErrorKind::Export { located: false, .. })
            {
                return ChatRead {
                    header: make_header(kind, "not_found", &HeaderExtras::default()),
                    messages: Vec::new(),
                };
            }
            ChatRead {
                header: make_header(
                    kind,
                    "error",
                    &HeaderExtras {
                        transcript: if is_exported(kind) { None } else { transcript },
                        error: Some(error.message),
                        ..HeaderExtras::default()
                    },
                ),
                messages: Vec::new(),
            }
        }
    }
}

/// The body of `readChat`'s `try`: `transcript` is set once located, for the
/// `error` header.
fn read_located(args: &ReadChatArgs<'_>, transcript: &mut Option<String>) -> ChatResult<ChatRead> {
    let kind = args.kind;
    let located = locate_transcript(&Locate {
        kind,
        session_kind: args.session_kind,
        session_value: args.session_value,
        cwd: args.cwd,
        launched_at: args.launched_at,
        launch_rivals: args.launch_rivals,
        env: args.env,
        home: args.home,
        signal: None,
    })?;
    let Some(located) = located else {
        return Ok(ChatRead {
            header: make_header(kind, "not_found", &HeaderExtras::default()),
            messages: Vec::new(),
        });
    };
    *transcript = Some(located.clone());

    let mut turns = ChatTurns::new();
    run_parser(
        kind,
        &located,
        &ParserContext {
            root: &kind_root(kind, args.env, args.home),
            env: args.env,
            home: args.home,
            cwd: args.cwd,
            signal: None,
            signal_arc: None,
        },
        &mut turns,
    )?;
    let chat = turns.finish(args.status)?;
    let limit = match args.max_messages {
        Some(n) if n.is_finite() && n.fract() == 0.0 && n > 0.0 => n,
        _ => DEFAULT_MAX_MESSAGES,
    };
    let (messages, truncated, after_found) = select_messages(&chat.messages, args.after, limit);
    Ok(ChatRead {
        header: make_header(
            kind,
            "ok",
            &HeaderExtras {
                // An exported kind has no transcript file; `transcript` holds
                // the session id for its parser, and the header names no path.
                transcript: if is_exported(kind) {
                    None
                } else {
                    Some(located)
                },
                activity: chat.activity,
                turn_open: chat.turn_open,
                truncated,
                after_found,
                error: None,
            },
        ),
        messages,
    })
}

/// Locate one Agent's transcript and run its kind's parser into `turns` (a
/// `ChatTurns`, possibly with an observer; see `observes`). `Ok(true)` when it
/// parsed, `Ok(false)` when the kind has no reader or no transcript is found;
/// an error on an unreadable transcript (like `read_chat`'s internals).
/// `signal` aborts the read: a transcript stream closes and an export or
/// session list command is killed.
pub fn parse_transcript(args: &ParseArgs<'_>, turns: &mut ChatTurns) -> ChatResult<bool> {
    let kind = args.kind;
    if !has_parser(kind) {
        return Ok(false);
    }
    let located = locate_transcript(&Locate {
        kind,
        session_kind: args.session_kind,
        session_value: args.session_value,
        cwd: args.cwd,
        launched_at: args.launched_at,
        launch_rivals: args.launch_rivals,
        env: args.env,
        home: args.home,
        signal: args.signal,
    })?;
    let Some(located) = located else {
        return Ok(false);
    };
    run_parser(
        kind,
        &located,
        &ParserContext {
            root: &kind_root(kind, args.env, args.home),
            env: args.env,
            home: args.home,
            cwd: args.cwd,
            signal: args.signal.map(|signal| &**signal),
            signal_arc: args.signal,
        },
        turns,
    )?;
    Ok(true)
}

/// The text of the last assistant message, or None when there is none.
pub fn last_reply(chat: &ChatRead) -> Option<String> {
    chat.messages.iter().rev().find_map(|message| {
        if field(message, "role").as_str() == Some("assistant") {
            field(message, "text").as_str().map(str::to_string)
        } else {
            None
        }
    })
}

/// One JSON object per line: the header, then messages oldest to newest.
pub fn format_ndjson(chat: &ChatRead) -> String {
    let mut out = String::new();
    for object in std::iter::once(&chat.header).chain(&chat.messages) {
        out.push_str(&jsx::stringify(object));
        out.push('\n');
    }
    out
}

struct HeaderExtras {
    transcript: Option<String>,
    activity: Option<String>,
    turn_open: bool,
    truncated: bool,
    after_found: bool,
    error: Option<String>,
}

impl Default for HeaderExtras {
    fn default() -> Self {
        Self {
            transcript: None,
            activity: None,
            turn_open: false,
            truncated: false,
            after_found: true,
            error: None,
        }
    }
}

/// `after_found` is false only when a transcript was read, `--after` named an
/// id and that id is no longer in it: the messages are then the whole chat,
/// and the app replaces what it shows. Without a transcript nothing was
/// compared.
fn make_header(kind: &str, status: &str, extras: &HeaderExtras) -> Value {
    let mut header = Map::new();
    header.insert("type".into(), json!("header"));
    header.insert("v".into(), json!(1));
    header.insert("kind".into(), json!(kind));
    header.insert("status".into(), json!(status));
    header.insert("transcript".into(), json!(extras.transcript));
    header.insert("activity".into(), json!(extras.activity));
    header.insert("turn_open".into(), json!(extras.turn_open));
    header.insert("truncated".into(), json!(extras.truncated));
    header.insert("after_found".into(), json!(extras.after_found));
    header.insert("error".into(), json!(extras.error));
    Value::Object(header)
}

/// `--after`: only messages after that id, or all of them when the id is
/// unknown (`after_found` false). Then keep the newest `limit`.
fn select_messages(all: &[Value], after: Option<&str>, limit: f64) -> (Vec<Value>, bool, bool) {
    let mut messages = all;
    let mut after_found = true;
    if let Some(after) = after {
        match all
            .iter()
            .rposition(|message| field(message, "id").as_str() == Some(after))
        {
            Some(index) => messages = &all[index + 1..],
            None => after_found = false,
        }
    }
    let truncated = messages.len() as f64 > limit;
    if truncated {
        messages = &messages[messages.len() - limit as usize..];
    }
    (messages.to_vec(), truncated, after_found)
}

// MARK: - Parsers

/// What a parser gets besides the file and the turns (`{root, env, home, cwd,
/// signal}`).
struct ParserContext<'a> {
    root: &'a str,
    env: &'a Env,
    home: &'a str,
    cwd: Option<&'a str>,
    signal: Option<&'a AbortSignal>,
    /// The same signal, shared with an export runner's watcher thread.
    signal_arc: Option<&'a Arc<AbortSignal>>,
}

/// `PARSERS[kind](file, context)`.
fn run_parser(
    kind: &str,
    file: &str,
    context: &ParserContext<'_>,
    turns: &mut ChatTurns,
) -> ChatResult<()> {
    match kind {
        "claude" => parse_claude(file, context, turns),
        "codex" => parse_codex(file, context, turns),
        "omp" | "pi" => parse_omp_like(file, context, turns),
        "opencode" | "kilo" => parse_opencode(file, context, kind, turns),
        _ => match reader(kind) {
            Some(reader) => (reader.parse)(
                file,
                &ReaderContext {
                    root: context.root,
                    env: context.env,
                    home: context.home,
                    cwd: context.cwd,
                    signal: context.signal,
                },
                turns,
            ),
            None => Err(ChatError::other(format!("no parser for {kind}"))),
        },
    }
}

/// `record.timestamp ?? null`, as the time the turns store.
fn record_time(record: &Value) -> Option<f64> {
    parse_time(field(record, "timestamp"))
}

fn is_type(value: &Value, name: &str) -> bool {
    field(value, "type").as_str() == Some(name)
}

/// A string field, or None for any other type.
fn str_field<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    field(value, key).as_str()
}

fn parse_claude(file: &str, context: &ParserContext<'_>, turns: &mut ChatTurns) -> ChatResult<()> {
    let transcript = jspath::resolve(&[file]);
    for item in read_records(file, context.signal)? {
        let item = item?;
        let record = &item.record;
        if get(record, "isSidechain") == Some(&Value::Bool(true)) {
            continue;
        }
        let Some(id) = str_field(record, "uuid").filter(|id| !id.is_empty()) else {
            continue;
        };
        let ts = record_time(record);
        let record_type = str_field(record, "type").unwrap_or("");

        if record_type == "user" {
            let content = field(field(record, "message"), "content");
            // A tool result is never a prompt; the images in it ride on the reply.
            if let Some(blocks) = content
                .as_array()
                .filter(|blocks| blocks.iter().any(|block| is_type(block, "tool_result")))
            {
                for (index, block) in blocks.iter().enumerate() {
                    let Some(inner_blocks) = field(block, "content").as_array() else {
                        continue;
                    };
                    if !is_type(block, "tool_result") {
                        continue;
                    }
                    for (inner_index, inner) in inner_blocks.iter().enumerate() {
                        let source = if is_type(inner, "image") {
                            field(inner, "source")
                        } else {
                            &Value::Null
                        };
                        if !is_type(source, "base64") {
                            continue;
                        }
                        let pointer =
                            format!("/message/content/{index}/content/{inner_index}/source/data");
                        if let Some(media) = tool_image(
                            field(source, "data"),
                            field(source, "media_type"),
                            &transcript,
                            item.offset,
                            &pointer,
                            context.root,
                        ) {
                            turns.media(&media, None);
                        }
                    }
                }
                for block in blocks {
                    if is_type(block, "tool_result") {
                        turns.tool_result(ToolResult {
                            call_id: str_field(block, "tool_use_id"),
                            name: None,
                            content: field(block, "content"),
                            details: field(record, "toolUseResult"),
                        });
                    }
                }
                continue;
            }
            if get(record, "isMeta") == Some(&Value::Bool(true))
                || get(record, "isCompactSummary") == Some(&Value::Bool(true))
                || get(record, "toolUseResult").is_some()
            {
                continue;
            }
            let Some(raw) = claude_user_text(content) else {
                continue;
            };
            if trim_start(&raw).starts_with(CLAUDE_INTERRUPT) {
                turns.end(id, ts, false, None, None);
                continue;
            }
            let text = strip_reminders(&raw);
            if text.is_empty() {
                continue;
            }
            if let Some(command) = claude_command_prompt(&text) {
                turns.prompt(Prompt {
                    id,
                    text: &command,
                    ts,
                    command: true,
                    ..Prompt::default()
                });
                continue;
            }
            if starts_with_any(&text, &CLAUDE_WRAPPERS) {
                continue;
            }
            if text.starts_with(CLAUDE_TASK_NOTIFICATION) {
                turns.prompt(Prompt {
                    id,
                    text: &text,
                    ts,
                    hidden: true,
                    ..Prompt::default()
                });
                continue;
            }
            turns.prompt(Prompt {
                id,
                text: &text,
                ts,
                ..Prompt::default()
            });
            continue;
        }

        if record_type == "attachment" {
            let attachment = field(record, "attachment");
            if !is_type(attachment, "queued_command") {
                continue;
            }
            let Some(prompt) = str_field(attachment, "prompt") else {
                continue;
            };
            let mode = field(attachment, "commandMode");
            if mode.as_str() == Some("task-notification") {
                turns.prompt(Prompt {
                    id,
                    text: "",
                    ts,
                    hidden: true,
                    ..Prompt::default()
                });
                continue;
            }
            if !(mode.is_null() || mode.as_str() == Some("prompt")) {
                continue;
            }
            let text = strip_reminders(prompt);
            if text.is_empty() || starts_with_any(&text, &CLAUDE_WRAPPERS) {
                continue;
            }
            turns.prompt(Prompt {
                id,
                text: &text,
                ts,
                steering: true,
                ..Prompt::default()
            });
            continue;
        }

        if record_type == "assistant" {
            let message = field(record, "message");
            if !jsx::is_object_like(message) {
                continue;
            }
            if str_field(message, "model") == Some(CLAUDE_SYNTHETIC_MODEL)
                && get(record, "isApiErrorMessage") != Some(&Value::Bool(true))
            {
                continue;
            }
            let content = field(message, "content");
            let synthetic;
            let blocks: &[Value] = match content {
                Value::String(text) => {
                    synthetic = [json!({ "type": "text", "text": text })];
                    &synthetic
                }
                Value::Array(blocks) => blocks,
                _ => &[],
            };
            for block in blocks {
                match str_field(block, "type") {
                    Some("text") => turns.text(id, ts, field(block, "text"), None),
                    Some("thinking" | "redacted_thinking") => turns.thinking(id, ts, None),
                    Some("tool_use" | "server_tool_use") => turns.tool(ToolCall {
                        id,
                        ts,
                        activity: tool_activity(field(block, "name"), field(block, "input")),
                        turn_key: None,
                        name: str_field(block, "name"),
                        input: get(block, "input"),
                        call_id: str_field(block, "id"),
                    }),
                    _ => {}
                }
            }
            if matches!(
                str_field(message, "stop_reason"),
                Some("end_turn" | "stop_sequence")
            ) {
                turns.end_simple(id, ts);
            }
        }
    }
    Ok(())
}

fn starts_with_any(text: &str, prefixes: &[&str]) -> bool {
    prefixes.iter().any(|prefix| text.starts_with(prefix))
}

/// `claudeUserText`: a string as is, the text blocks of an array joined by
/// newlines, else None.
fn claude_user_text(content: &Value) -> Option<String> {
    match content {
        Value::String(text) => Some(text.clone()),
        Value::Array(_) => Some(joined_text_blocks(content, "\n")),
        _ => None,
    }
}

/// The `text` strings of an array's `{type: "text"}` blocks, joined by `sep`.
fn joined_text_blocks(content: &Value, sep: &str) -> String {
    let Some(blocks) = content.as_array() else {
        return String::new();
    };
    blocks
        .iter()
        .filter(|block| is_type(block, "text"))
        .filter_map(|block| str_field(block, "text"))
        .collect::<Vec<_>>()
        .join(sep)
}

/// `/<open>([\s\S]*?)<close>/`'s first group: the leftmost match is the first
/// opening tag, ended by the first closing tag after it.
fn between<'a>(text: &'a str, open: &str, close: &str) -> Option<&'a str> {
    let start = text.find(open)? + open.len();
    let end = text[start..].find(close)? + start;
    Some(&text[start..end])
}

/// A slash command record (`<command-name>/name</command-name>` plus its
/// message and args) as the prompt the user typed, `/name args`, or None.
fn claude_command_prompt(text: &str) -> Option<String> {
    if !starts_with_any(text, &CLAUDE_COMMANDS) {
        return None;
    }
    let name = trim(between(text, "<command-name>", "</command-name>")?);
    if name.is_empty() {
        return None;
    }
    let args = between(text, "<command-args>", "</command-args>").map_or("", trim);
    let name = if name.starts_with('/') {
        name.to_string()
    } else {
        format!("/{name}")
    };
    Some(trim(&format!("{name} {args}")).to_string())
}

/// `text.replace(/<system-reminder>[\s\S]*?<\/system-reminder>/g, "").trim()`.
fn strip_reminders(text: &str) -> String {
    const OPEN: &str = "<system-reminder>";
    const CLOSE: &str = "</system-reminder>";
    let mut out = String::new();
    let mut rest = text;
    while let Some(start) = rest.find(OPEN) {
        let after = start + OPEN.len();
        let Some(end) = rest[after..].find(CLOSE) else {
            break;
        };
        out.push_str(&rest[..start]);
        rest = &rest[after + end + CLOSE.len()..];
    }
    out.push_str(rest);
    trim(&out).to_string()
}

/// Codex ids: a truthy `turn_id` (an empty string is falsy in the JS).
fn truthy_key(key: &Option<String>) -> Option<&str> {
    key.as_deref().filter(|key| !key.is_empty())
}

fn parse_codex(file: &str, context: &ParserContext<'_>, turns: &mut ChatTurns) -> ChatResult<()> {
    let transcript = jspath::resolve(&[file]);
    let mut turn_id: Option<String> = None;
    let mut used_ids: HashSet<String> = HashSet::new();
    // Some codex versions record a prompt twice (the legacy `user_message`
    // event and the `UserMessage` item); the copy follows before any reply.
    let mut last_prompt: Option<(String, Option<String>)> = None;
    // Commentary texts since the last end: `last_agent_message` may repeat
    // one, and commentary is never the reply.
    let mut commentary: HashSet<String> = HashSet::new();

    for item in read_records(file, context.signal)? {
        let item = item?;
        let (record, line, offset) = (&item.record, item.line, item.offset);
        let payload = field(record, "payload");
        if !jsx::is_object_like(payload) {
            continue;
        }
        let ts = record_time(record);
        let record_type = str_field(record, "type");

        if record_type == Some("turn_context") {
            if let Some(id) = str_field(payload, "turn_id") {
                turn_id = Some(id.to_string());
            }
            continue;
        }

        if record_type == Some("event_msg") {
            let payload_type = str_field(payload, "type");
            if payload_type == Some("task_started") {
                if let Some(id) = str_field(payload, "turn_id") {
                    turn_id = Some(id.to_string());
                }
                continue;
            }
            if matches!(payload_type, Some("task_complete" | "turn_aborted")) {
                let key = str_field(payload, "turn_id")
                    .map(str::to_string)
                    .or_else(|| turn_id.clone());
                let mut fallback: Option<String> = None;
                if payload_type == Some("task_complete") {
                    // A failed turn records its error here only; the error
                    // event is never persisted.
                    let error = str_field(field(payload, "error"), "message").map_or("", trim);
                    let last = str_field(payload, "last_agent_message").map_or("", trim);
                    fallback = if !error.is_empty() {
                        Some(error.to_string())
                    } else if commentary.contains(last) {
                        None
                    } else {
                        Some(last.to_string())
                    };
                }
                let id = match truthy_key(&key) {
                    Some(key) => format!("a:{key}"),
                    None => format!("a:{line}"),
                };
                turns.end(&id, ts, true, fallback.as_deref(), None);
                last_prompt = None;
                commentary = HashSet::new();
                continue;
            }

            let mut text: Option<String> = None;
            let mut key = turn_id.clone();
            if payload_type == Some("user_message") && field(payload, "message").is_string() {
                text = str_field(payload, "message").map(str::to_string);
            } else if payload_type == Some("item_completed")
                && is_type(field(payload, "item"), "UserMessage")
            {
                text = Some(joined_text_blocks(
                    field(field(payload, "item"), "content"),
                    "\n",
                ));
                if let Some(id) = str_field(payload, "turn_id") {
                    key = Some(id.to_string());
                }
            }
            let Some(text) = text else {
                continue;
            };
            let clean = trim(&text);
            if clean.is_empty() || starts_with_any(clean, &CODEX_INJECTIONS) {
                continue;
            }
            if let Some((previous, previous_key)) = &last_prompt
                && previous == clean
                && *previous_key == key
            {
                continue;
            }
            last_prompt = Some((clean.to_string(), key.clone()));

            let mut id = match truthy_key(&key) {
                Some(key) => format!("u:{key}"),
                None => format!("u:{line}"),
            };
            if used_ids.contains(&id) {
                id = format!("u:{line}");
            }
            used_ids.insert(id.clone());
            let reply_id = match truthy_key(&key) {
                Some(key) => format!("a:{key}"),
                None => format!("a:{line}"),
            };
            turns.prompt(Prompt {
                id: &id,
                text: clean,
                ts,
                turn_key: key.as_deref(),
                reply_id: Some(&reply_id),
                ..Prompt::default()
            });
            continue;
        }

        if record_type != Some("response_item") {
            continue;
        }
        let id = match truthy_key(&turn_id) {
            Some(turn) => format!("a:{turn}"),
            None => format!("a:{line}"),
        };
        let key = turn_id.as_deref();
        let payload_type = str_field(payload, "type");
        let role = str_field(payload, "role");
        if payload_type == Some("message") && role == Some("assistant") {
            let blocks: &[Value] = field(payload, "content")
                .as_array()
                .map_or(&[], Vec::as_slice);
            let text = blocks
                .iter()
                .filter(|block| matches!(str_field(block, "type"), Some("output_text" | "text")))
                .filter_map(|block| str_field(block, "text"))
                .map(trim)
                .filter(|text| !text.is_empty())
                .collect::<Vec<_>>()
                .join("\n\n");
            if text.is_empty() {
                continue;
            }
            // `commentary` is an interim update; `final_answer` (or no phase)
            // is the reply.
            if str_field(payload, "phase") == Some("commentary") {
                commentary.insert(text.clone());
                turns.note(&id, ts, &Value::String(text), key);
            } else {
                turns.text(&id, ts, &Value::String(text), key);
            }
            last_prompt = None;
        } else if payload_type == Some("reasoning") {
            turns.thinking(&id, ts, key);
            last_prompt = None;
        } else if payload_type.is_some_and(|t| CODEX_TOOL_TYPES.contains(&t)) {
            let arguments = field(payload, "arguments");
            turns.tool(ToolCall {
                id: &id,
                ts,
                activity: codex_tool_activity(payload),
                turn_key: key,
                name: str_field(payload, "name"),
                input: if arguments.is_null() {
                    get(payload, "input")
                } else {
                    Some(arguments)
                },
                call_id: str_field(payload, "call_id"),
            });
            last_prompt = None;
        } else if payload_type == Some("message") && role == Some("user") {
            // view_image's synthesized message (older codex): images only,
            // never a prompt. A message the user wrote also carries text and
            // is skipped.
            let blocks: &[Value] = field(payload, "content")
                .as_array()
                .map_or(&[], Vec::as_slice);
            if !blocks.is_empty() && blocks.iter().all(|block| is_type(block, "input_image")) {
                codex_media(
                    blocks,
                    "/payload/content",
                    &transcript,
                    offset,
                    context.root,
                    key,
                    turns,
                );
            }
        } else if matches!(
            payload_type,
            Some("function_call_output" | "custom_tool_call_output")
        ) && let Some(output) = field(payload, "output").as_array()
        {
            codex_media(
                output,
                "/payload/output",
                &transcript,
                offset,
                context.root,
                key,
                turns,
            );
        }
    }
    Ok(())
}

/// `codexImages` + `toolImage` + `turns.media`: the `input_image` blocks
/// holding a base64 `data:` URL, with their JSON Pointers under `base`.
fn codex_media(
    blocks: &[Value],
    base: &str,
    transcript: &str,
    offset: u64,
    root: &str,
    turn_key: Option<&str>,
    turns: &mut ChatTurns,
) {
    for (index, block) in blocks.iter().enumerate() {
        if !is_type(block, "input_image") {
            continue;
        }
        let Some(url) = str_field(block, "image_url").filter(|url| url.starts_with("data:")) else {
            continue;
        };
        let pointer = format!("{base}/{index}/image_url");
        if let Some(media) = tool_image(
            &Value::String(url.to_string()),
            &Value::Null,
            transcript,
            offset,
            &pointer,
            root,
        ) {
            turns.media(&media, turn_key);
        }
    }
}

fn codex_tool_activity(payload: &Value) -> String {
    match str_field(payload, "type") {
        Some("local_shell_call") => tool_activity(
            &json!("local_shell_call"),
            &json!({ "command": field(field(payload, "action"), "command") }),
        ),
        Some("web_search_call") => tool_activity(&json!("web_search_call"), &Value::Null),
        Some("tool_search_call") => tool_activity(&json!("tool_search"), &Value::Null),
        Some("custom_tool_call") => {
            let input = match field(payload, "input") {
                Value::String(text) => Value::String(text.clone()),
                _ => Value::Null,
            };
            tool_activity(field(payload, "name"), &input)
        }
        _ => {
            let arguments = str_field(payload, "arguments").and_then(parse_json_object);
            tool_activity(field(payload, "name"), &arguments.unwrap_or(Value::Null))
        }
    }
}

/// One entry of omp/pi's message list, kept until the branch is known.
enum OmpMessage {
    User {
        id: String,
        ts: Option<f64>,
        text: String,
        steering: bool,
    },
    Assistant {
        id: String,
        ts: Option<f64>,
        blocks: Vec<OmpBlock>,
        stop_reason: Option<String>,
        error_text: Option<String>,
    },
    ToolResult {
        id: String,
        images: Vec<ToolImage>,
        result: Option<OmpResult>,
    },
}

enum OmpBlock {
    Text(Value),
    Thinking,
    Tool {
        activity: String,
        call: Option<OmpCall>,
    },
}

/// A tool call kept for an observer (`turns.observes(name)`).
struct OmpCall {
    name: Option<String>,
    input: Option<Value>,
    call_id: Option<String>,
}

struct OmpResult {
    call_id: Option<String>,
    name: Option<String>,
    content: Value,
    details: Value,
}

/// A message's role and stop reason, for steering and the tip.
struct OmpStep {
    role: Option<String>,
    stop_reason: Option<String>,
}

/// omp and pi share one scheme: every entry carries `id` and `parentId`, and
/// a rewind branches the tree. Only the chain from the newest message back to
/// the root is the conversation the Agent is in.
fn parse_omp_like(
    file: &str,
    context: &ParserContext<'_>,
    turns: &mut ChatTurns,
) -> ChatResult<()> {
    let transcript = jspath::resolve(&[file]);
    let mut parents: HashMap<String, Option<String>> = HashMap::new();
    // Every message entry's role and stop reason, for steering and the tip.
    let mut steps: HashMap<String, OmpStep> = HashMap::new();
    let mut messages: Vec<OmpMessage> = Vec::new();
    let mut newest: Option<String> = None;
    let mut previous: Option<String> = None;

    for item in read_records(file, context.signal)? {
        let item = item?;
        let (record, line, offset) = (&item.record, item.line, item.offset);
        if is_type(record, "session") {
            continue;
        }
        // Entries without ids (the oldest session format) form a plain list.
        let record_id = str_field(record, "id");
        let id = record_id.map_or_else(|| format!("line:{line}"), str::to_string);
        let parent_id = match str_field(record, "parentId") {
            Some(parent) => Some(parent.to_string()),
            None if record_id.is_some() => None,
            None => previous.clone(),
        };
        parents.insert(id.clone(), parent_id);
        previous = Some(id.clone());
        let message = field(record, "message");
        if !is_type(record, "message") || !jsx::is_object_like(message) {
            continue;
        }
        newest = Some(id.clone());
        let timestamp = field(record, "timestamp");
        let ts = parse_time(if timestamp.is_null() {
            field(message, "timestamp")
        } else {
            timestamp
        });
        let role = str_field(message, "role");
        let stop_reason = str_field(message, "stopReason");
        steps.insert(
            id.clone(),
            OmpStep {
                role: role.map(str::to_string),
                stop_reason: stop_reason.map(str::to_string),
            },
        );
        match role {
            Some("user") => {
                if get(message, "attribution")
                    .is_some_and(|attribution| attribution.as_str() != Some("user"))
                {
                    continue;
                }
                messages.push(OmpMessage::User {
                    id,
                    ts,
                    text: omp_text(field(message, "content")),
                    steering: get(message, "steering") == Some(&Value::Bool(true)),
                });
            }
            Some("assistant") => {
                let content: &[Value] = field(message, "content")
                    .as_array()
                    .map_or(&[], Vec::as_slice);
                let mut blocks = Vec::new();
                for block in content {
                    match str_field(block, "type") {
                        Some("text") => blocks.push(OmpBlock::Text(field(block, "text").clone())),
                        Some("thinking" | "redactedThinking") => blocks.push(OmpBlock::Thinking),
                        Some("toolCall") => {
                            let activity =
                                tool_activity(field(block, "name"), field(block, "arguments"));
                            let name = str_field(block, "name");
                            let call = turns.observes(name).then(|| OmpCall {
                                name: name.map(str::to_string),
                                input: get(block, "arguments").cloned(),
                                call_id: str_field(block, "id").map(str::to_string),
                            });
                            blocks.push(OmpBlock::Tool { activity, call });
                        }
                        _ => {}
                    }
                }
                let error_text = if stop_reason == Some("error") {
                    str_field(message, "errorMessage").map(str::to_string)
                } else {
                    None
                };
                messages.push(OmpMessage::Assistant {
                    id,
                    ts,
                    blocks,
                    stop_reason: stop_reason.map(str::to_string),
                    error_text,
                });
            }
            Some("toolResult") => {
                let content = field(message, "content");
                let blocks: &[Value] = content.as_array().map_or(&[], Vec::as_slice);
                let mut images = Vec::new();
                for (index, block) in blocks.iter().enumerate() {
                    if !is_type(block, "image") {
                        continue;
                    }
                    let pointer = format!("/message/content/{index}/data");
                    if let Some(media) = tool_image(
                        field(block, "data"),
                        field(block, "mimeType"),
                        &transcript,
                        offset,
                        &pointer,
                        context.root,
                    ) {
                        images.push(media);
                    }
                }
                let tool_name = str_field(message, "toolName");
                let result = turns.observes(tool_name).then(|| OmpResult {
                    call_id: str_field(message, "toolCallId").map(str::to_string),
                    name: tool_name.map(str::to_string),
                    content: content.clone(),
                    details: field(message, "details").clone(),
                });
                if !images.is_empty() || result.is_some() {
                    messages.push(OmpMessage::ToolResult { id, images, result });
                }
            }
            _ => {}
        }
    }

    let mut branch: HashSet<&str> = HashSet::new();
    let mut at = newest.as_deref();
    while let Some(id) = at.filter(|id| !id.is_empty() && !branch.contains(id)) {
        branch.insert(id);
        at = parents.get(id).and_then(|parent| parent.as_deref());
    }

    // The nearest user, assistant or tool result message above `id` on its
    // branch.
    let conversation_parent = |id: &str| -> Option<&OmpStep> {
        let mut seen: HashSet<&str> = HashSet::new();
        let mut at = parents.get(id).and_then(|parent| parent.as_deref());
        while let Some(parent) = at.filter(|parent| !parent.is_empty() && !seen.contains(parent)) {
            seen.insert(parent);
            if let Some(step) = steps.get(parent)
                && matches!(
                    step.role.as_deref(),
                    Some("user" | "assistant" | "toolResult")
                )
            {
                return Some(step);
            }
            at = parents.get(parent).and_then(|grand| grand.as_deref());
        }
        None
    };

    // Whether each blob file is there to read; the item is dropped otherwise.
    let mut blobs: HashMap<String, bool> = HashMap::new();
    for message in &messages {
        let message_id = match message {
            OmpMessage::User { id, .. }
            | OmpMessage::Assistant { id, .. }
            | OmpMessage::ToolResult { id, .. } => id,
        };
        if !branch.contains(message_id.as_str()) {
            continue;
        }
        match message {
            OmpMessage::ToolResult { images, result, .. } => {
                for media in images {
                    if let Some(blob) = &media.blob_path {
                        let present = *blobs
                            .entry(blob.clone())
                            .or_insert_with(|| stat_file(blob).is_some());
                        if !present {
                            continue;
                        }
                    }
                    turns.media(media, None);
                }
                if let Some(result) = result {
                    turns.tool_result(ToolResult {
                        call_id: result.call_id.as_deref(),
                        name: result.name.as_deref(),
                        content: &result.content,
                        details: &result.details,
                    });
                }
            }
            OmpMessage::User {
                id,
                ts,
                text,
                steering,
            } => {
                let text = trim(text);
                // pi records a message typed mid-run as a plain user message
                // after a tool result (or tool call); omp also flags it
                // `steering`.
                let steering = *steering || omp_run_continues(conversation_parent(id));
                if !text.is_empty() {
                    turns.prompt(Prompt {
                        id,
                        text,
                        ts: *ts,
                        steering,
                        ..Prompt::default()
                    });
                }
            }
            OmpMessage::Assistant {
                id,
                ts,
                blocks,
                stop_reason,
                error_text,
            } => {
                for block in blocks {
                    match block {
                        OmpBlock::Text(text) => turns.text(id, *ts, text, None),
                        OmpBlock::Thinking => turns.thinking(id, *ts, None),
                        OmpBlock::Tool { activity, call } => turns.tool(ToolCall {
                            id,
                            ts: *ts,
                            activity: activity.clone(),
                            turn_key: None,
                            name: call.as_ref().and_then(|call| call.name.as_deref()),
                            input: call.as_ref().and_then(|call| call.input.as_ref()),
                            call_id: call.as_ref().and_then(|call| call.call_id.as_deref()),
                        }),
                    }
                }
                if matches!(
                    stop_reason.as_deref(),
                    Some("stop" | "length" | "error" | "aborted")
                ) {
                    turns.end(id, *ts, true, None, error_text.as_deref());
                }
            }
        }
    }
    // A trailing prompt, tool result or tool call means the harness is still
    // working, whatever the Agent Status says (omp without herdr's
    // integration reports idle for its whole turn).
    let tip = newest.as_deref().and_then(|id| steps.get(id));
    turns.run_continues =
        tip.is_some_and(|tip| tip.role.as_deref() == Some("user")) || omp_run_continues(tip);
    Ok(())
}

/// A tool result or a tool call: the harness runs on after this message.
fn omp_run_continues(step: Option<&OmpStep>) -> bool {
    step.is_some_and(|step| {
        step.role.as_deref() == Some("toolResult")
            || (step.role.as_deref() == Some("assistant")
                && step.stop_reason.as_deref() == Some("toolUse"))
    })
}

fn omp_text(content: &Value) -> String {
    match content {
        Value::String(text) => text.clone(),
        Value::Array(_) => joined_text_blocks(content, "\n"),
        _ => String::new(),
    }
}

/// opencode and kilo: one `<kind> export <session id>` (see
/// `chat::session_export`; opencode verified against 1.18.33, kilo 7.8.8: kilo
/// is an opencode fork whose export has the same shape) instead of a
/// transcript file; `session` is the id herdr reported or the marker
/// recorded. The export is one JSON object: `{info, messages: [{info,
/// parts}]}` with user and assistant message infos and no child sessions:
/// subagent work surfaces only as `subtask` and tool parts inside it.
///
/// There is no end-of-turn record: a user message starts a turn, the
/// herdr-reported Agent Status closes it, and a following user message closes
/// the one before. Message info `error` (or a `finish` of `"error"`) does end
/// the turn, like omp's `stopReason` `"error"`: a user abort ends it quietly,
/// any other recorded error becomes the reply when no text follows, and a
/// later assistant item (an automatic retry) reopens the turn and drops it.
fn parse_opencode(
    session: &str,
    context: &ParserContext<'_>,
    kind: &str,
    turns: &mut ChatTurns,
) -> ChatResult<()> {
    let mut options = ExportOptions::new(context.env.clone(), context.home);
    // The export runner shares its signal with a watcher thread.
    options.signal = context.signal_arc.cloned();
    let data = session_export(kind, &Value::String(session.to_string()), &options)?;
    // The media reader re-runs the export: opencode's items name only the
    // session (the wire predates kilo), any other kind's also name the kind.
    let mut export_ref = Map::new();
    export_ref.insert("session".into(), json!(session));
    if kind != "opencode" {
        export_ref.insert("kind".into(), json!(kind));
    }
    let messages: &[Value] = field(&data, "messages")
        .as_array()
        .map_or(&[], Vec::as_slice);
    if kind == "opencode"
        && messages
            .iter()
            .any(|entry| str_field(entry, "type").is_some())
    {
        return parse_opencode_v2(messages, &export_ref, turns);
    }
    // file:// attachments may only name files in these directories.
    let roots = opencode_media_roots(
        str_field(field(&data, "info"), "directory"),
        context.cwd,
        context.home,
    );
    for (message_index, entry) in messages.iter().enumerate() {
        let info = field(entry, "info");
        let role = str_field(info, "role");
        if !jsx::is_object_like(info) || !matches!(role, Some("user" | "assistant")) {
            continue;
        }
        let parts: &[Value] = field(entry, "parts").as_array().map_or(&[], Vec::as_slice);
        // User and assistant message infos carry a `msg_...` id and
        // `time.created` in epoch milliseconds.
        let id = str_field(info, "id")
            .map_or_else(|| format!("message:{message_index}"), str::to_string);
        let ts = parse_time(field(field(info, "time"), "created"));

        if role == Some("user") {
            // Text parts join into the one prompt; `synthetic` and `ignored`
            // texts are opencode's own injections, never the user's words.
            let joined = parts
                .iter()
                .filter(|part| {
                    is_type(part, "text")
                        && get(part, "synthetic") != Some(&Value::Bool(true))
                        && get(part, "ignored") != Some(&Value::Bool(true))
                })
                .filter_map(|part| str_field(part, "text"))
                .collect::<Vec<_>>()
                .join("\n");
            let text = trim(&joined);
            if !text.is_empty() {
                turns.prompt(Prompt {
                    id: &id,
                    text,
                    ts,
                    ..Prompt::default()
                });
            }
            for (part_index, part) in parts.iter().enumerate() {
                let pointer = format!("/messages/{message_index}/parts/{part_index}/url");
                if let Some(media) = opencode_file_media(part, &export_ref, &pointer, &roots)
                    && turns.current().is_some()
                {
                    turns.media(&media, None);
                }
            }
            continue;
        }

        // Auto-compaction writes an assistant message with `agent:
        // "compaction"` and `summary: true` whose text parts hold a
        // whole-conversation summary; it is never a reply. It may be followed
        // by a new user message replaying the compacted range's original
        // prompt verbatim with no marker: a duplicate bubble we accept, since
        // a legit consecutive identical prompt must survive.
        if get(info, "summary") == Some(&Value::Bool(true))
            || str_field(info, "agent") == Some("compaction")
        {
            continue;
        }

        for (part_index, part) in parts.iter().enumerate() {
            if !jsx::is_object_like(part) {
                continue;
            }
            match str_field(part, "type") {
                Some("text") => turns.text(&id, ts, field(part, "text"), None),
                Some("reasoning") => turns.thinking(&id, ts, None),
                Some("tool") => {
                    // `state.status` is pending/running/completed/error;
                    // `input` holds the tool call's arguments in every state.
                    let state = field(part, "state");
                    turns.tool(ToolCall {
                        id: &id,
                        ts,
                        activity: tool_activity(field(part, "tool"), field(state, "input")),
                        turn_key: None,
                        name: str_field(part, "tool"),
                        input: get(state, "input"),
                        call_id: str_field(part, "callID"),
                    });
                    let attachments: &[Value] = field(state, "attachments")
                        .as_array()
                        .map_or(&[], Vec::as_slice);
                    for (attachment_index, attachment) in attachments.iter().enumerate() {
                        let pointer = format!(
                            "/messages/{message_index}/parts/{part_index}/state/attachments/{attachment_index}/url"
                        );
                        if let Some(media) =
                            opencode_file_media(attachment, &export_ref, &pointer, &roots)
                        {
                            turns.media(&media, None);
                        }
                    }
                }
                // A subagent run: the child session is not part of the export.
                Some("subtask") => turns.tool(ToolCall {
                    id: &id,
                    ts,
                    activity: tool_activity(&json!("task"), &Value::Null),
                    ..ToolCall::default()
                }),
                // step-start and step-finish bookend a model step; snapshot,
                // patch, agent, retry, compaction and unknown future types
                // are not chat material.
                _ => {}
            }
        }

        let error = field(info, "error");
        if error.is_object() || error.is_array() {
            // `{name, data}` per the AssistantError union: `MessageAbortedError`
            // is the user's interrupt; everything else records its message in
            // `data.message`.
            if str_field(error, "name") == Some("MessageAbortedError") {
                turns.end(&id, ts, false, None, None);
            } else {
                turns.end(
                    &id,
                    ts,
                    true,
                    None,
                    str_field(field(error, "data"), "message"),
                );
            }
        } else if str_field(info, "finish") == Some("error") {
            turns.end(&id, ts, false, None, None);
        }
    }

    // A trailing user prompt, or an assistant message whose last step has not
    // finished (`finish` is absent mid-run, `"tool-calls"` between steps),
    // shows the run still going: an idle or done status does not complete the
    // last turn. A finished step (`"stop"`, `"length"`, ...) does not end the
    // turn on its own: only the reported status or a later prompt does.
    let last = messages
        .last()
        .map_or(&Value::Null, |entry| field(entry, "info"));
    turns.run_continues = str_field(last, "role") == Some("user")
        || (str_field(last, "role") == Some("assistant")
            && (get(last, "finish").is_none() || str_field(last, "finish") == Some("tool-calls")));
    Ok(())
}

/// OpenCode 2.2.7 exports flat messages, oldest first. Its idle records end
/// turns even when the pane's status hooks are unavailable; assistant errors
/// also end them (a declined tool can have no following idle record).
fn parse_opencode_v2(
    messages: &[Value],
    export_ref: &Map<String, Value>,
    turns: &mut ChatTurns,
) -> ChatResult<()> {
    for (index, entry) in messages.iter().enumerate() {
        let id = str_field(entry, "id").map_or_else(|| format!("message:{index}"), str::to_string);
        let ts = parse_time(field(field(entry, "time"), "created"));
        match str_field(entry, "type") {
            Some("user") => {
                let text = str_field(entry, "text").map_or("", trim);
                let files = field(entry, "files")
                    .as_array()
                    .map_or(&[][..], Vec::as_slice);
                if !text.is_empty() || !files.is_empty() {
                    turns.prompt(Prompt {
                        id: &id,
                        text,
                        ts,
                        ..Prompt::default()
                    });
                }
                for (file_index, file) in files.iter().enumerate() {
                    let pointer = format!("/messages/{index}/files/{file_index}/data");
                    if let Some(media) = opencode_v2_file_media(file, export_ref, &pointer) {
                        turns.media(&media, None);
                    }
                }
                turns.run_continues = true;
            }
            Some("assistant") => {
                for part in field(entry, "content")
                    .as_array()
                    .map_or(&[][..], Vec::as_slice)
                {
                    match str_field(part, "type") {
                        Some("text") => turns.text(&id, ts, field(part, "text"), None),
                        Some("reasoning") => turns.thinking(&id, ts, None),
                        Some("tool") => {
                            let state = field(part, "state");
                            turns.tool(ToolCall {
                                id: &id,
                                ts,
                                activity: tool_activity(field(part, "name"), field(state, "input")),
                                turn_key: None,
                                name: str_field(part, "name"),
                                input: get(state, "input"),
                                call_id: str_field(part, "id"),
                            });
                        }
                        _ => {}
                    }
                }
                let error = field(entry, "error");
                if error.is_object() {
                    let failed = str_field(error, "type") != Some("aborted");
                    turns.end(
                        &id,
                        ts,
                        failed,
                        None,
                        if failed {
                            str_field(error, "message")
                        } else {
                            None
                        },
                    );
                    turns.run_continues = false;
                } else if str_field(entry, "finish") == Some("error") {
                    turns.end(&id, ts, false, None, None);
                    turns.run_continues = false;
                } else {
                    turns.run_continues = get(entry, "finish").is_none()
                        || str_field(entry, "finish") == Some("tool-calls");
                }
            }
            Some("idle") => {
                // An assistant error may already have ended the turn. Keep
                // its reason and anchor if this idle marker has no error.
                if turns.current().is_some_and(|turn| !turn.ended) {
                    let failed = str_field(entry, "outcome") == Some("failed");
                    turns.end(
                        &id,
                        ts,
                        failed,
                        None,
                        if failed {
                            str_field(field(entry, "error"), "message")
                        } else {
                            None
                        },
                    );
                }
                turns.run_continues = false;
            }
            // Synthetic prompts, system records and switches are never the
            // user's words. Unknown future records do not change turn state.
            _ => {}
        }
    }
    Ok(())
}

/// V2 files contain raw base64, not V1's data URL. Keep it out of chat-read:
/// chat-media accepts raw base64 at an export JSON Pointer and checks its
/// hash so a reverted message's replacement cannot reuse the old attachment.
fn opencode_v2_file_media(
    file: &Value,
    export_ref: &Map<String, Value>,
    pointer: &str,
) -> Option<ToolImage> {
    let mime = str_field(file, "mime")?;
    if !mime.starts_with("image/") && !mime.starts_with("video/") {
        return None;
    }
    let data = str_field(file, "data").filter(|data| !data.is_empty())?;
    let hex = sha256_hex(data.as_bytes());
    let mut inline = export_ref.clone();
    inline.insert("pointer".into(), json!(pointer));
    Some(ToolImage {
        item: json!({
            "id": format!("inline:{pointer}#sha256:{hex}"),
            "kind": if mime.starts_with("video/") { "video" } else { "image" },
            "mime": mime,
            "inline": Value::Object(inline),
        }),
        key: format!("sha256:{hex}"),
        blob_path: None,
    })
}

/// An opencode `file` part as a media item, or None. A `file://` URL (an
/// @-mention or `run --attach` of a local file) names a Host path; its item
/// rides the reply and the app reads the file over SFTP, but only when the
/// file lives inside the session's directory or the Agent's cwd: transcript
/// content is agent-controlled, so anything else is dropped rather than
/// surfaced as a tappable attachment. A base64 `data:` URL (how 1.18.33's TUI
/// attaches a file, also MCP resources and run attachments) is addressed by a
/// JSON Pointer into the export document, so the base64 never rides the chat
/// reads: `chat::media` re-runs the export for the session and reads the
/// pointer. A directory attachment shows nothing, and a data: attachment that
/// is not an image or video shows nothing.
fn opencode_file_media(
    part: &Value,
    export_ref: &Map<String, Value>,
    pointer: &str,
    roots: &HashSet<String>,
) -> Option<ToolImage> {
    if !is_type(part, "file") {
        return None;
    }
    let url = str_field(part, "url").filter(|url| !url.is_empty())?;
    let declared_mime = str_field(part, "mime");
    if declared_mime == Some("application/x-directory") {
        return None;
    }
    let mime = declared_mime.filter(|mime| !mime.is_empty());
    if url.starts_with("file://") {
        // `resolve()` normalizes `..` segments the URL may carry.
        let file = jspath::resolve(&[&file_url_to_path(url)?]);
        if !opencode_path_inside(&file, roots) {
            return None;
        }
        let id = format!("file:{file}");
        return Some(ToolImage {
            item: json!({ "id": id, "kind": "file", "mime": mime, "path": file }),
            key: id,
            blob_path: None,
        });
    }
    // A non-base64 data: URL has nothing chat::media can decode.
    let (prefix_len, prefix_mime) = base64_data_url_prefix(url)?;
    let kind_type = mime.unwrap_or(prefix_mime);
    if !kind_type.starts_with("image/") && !kind_type.starts_with("video/") {
        return None;
    }
    let payload = &url[prefix_len..];
    if payload.is_empty() {
        return None;
    }
    // The part's `prt_...` id rides in the item id: a `/revert` deletes later
    // messages, so a bare index pointer could silently resolve to a different
    // part; `chat::media` checks the part under the pointer still has this
    // id before decoding.
    let part_id = str_field(part, "id").filter(|id| !id.is_empty());
    let mut inline = export_ref.clone();
    inline.insert("pointer".into(), json!(pointer));
    let id = match part_id {
        Some(part_id) => format!("inline:{pointer}#{part_id}"),
        None => format!("inline:{pointer}"),
    };
    let hex = sha256_hex(payload.as_bytes());
    Some(ToolImage {
        item: json!({
            "id": id,
            "kind": if kind_type.starts_with("video/") { "video" } else { "image" },
            "mime": if kind_type.is_empty() { Value::Null } else { json!(kind_type) },
            "inline": Value::Object(inline),
        }),
        key: format!("sha256:{hex}"),
        blob_path: None,
    })
}

/// The directories a file:// attachment may name: the session's own
/// directory (export `info.directory`) and the Agent's cwd, each in its
/// resolved and symlink-resolved forms, the way `find_by_launch` compares
/// cwd.
fn opencode_media_roots(
    session_directory: Option<&str>,
    cwd: Option<&str>,
    home: &str,
) -> HashSet<String> {
    let mut roots = HashSet::new();
    for dir in [session_directory, cwd]
        .into_iter()
        .flatten()
        .filter(|dir| !dir.is_empty())
    {
        roots.extend(path_forms(&expand_home(dir, home)));
    }
    roots
}

/// Whether a resolved file lives under one of the allowed root forms.
fn opencode_path_inside(file: &str, roots: &HashSet<String>) -> bool {
    let mut forms = vec![file.to_string()];
    if let Ok(real) = std::fs::canonicalize(file) {
        let real = jspath::text(&real);
        if real != file {
            forms.push(real);
        }
    }
    forms.iter().any(|form| {
        roots
            .iter()
            .any(|root| form == root || form.starts_with(&format!("{root}/")))
    })
}

/// Node's `fileURLToPath(url)` on posix for a `file://` URL, or None where it
/// throws (an invalid URL, a host other than empty or `localhost`, an encoded
/// `/`, malformed percent-encoding). The WHATWG parser's `file:` path rules
/// apply first: tabs and newlines drop out, `\` is a separator, `.` and `..`
/// segments (also as `%2e`) collapse, `?` and `#` end the path, and a Windows
/// drive letter in the host position joins the path.
fn file_url_to_path(url: &str) -> Option<String> {
    let url: String = url
        .trim_matches(|c: char| c <= ' ')
        .chars()
        .filter(|c| !matches!(c, '\t' | '\n' | '\r'))
        .collect();
    let rest = url.strip_prefix("file://")?;
    let is_separator = |c: char| c == '/' || c == '\\';
    let host_end = rest
        .find(|c: char| is_separator(c) || c == '?' || c == '#')
        .unwrap_or(rest.len());
    let host = &rest[..host_end];
    let mut path: Vec<String> = Vec::new();
    let mut remaining;
    let is_drive = |text: &str| {
        let mut chars = text.chars();
        matches!((chars.next(), chars.next(), chars.next()), (Some(a), Some(b), None) if a.is_ascii_alphabetic() && (b == ':' || b == '|'))
    };
    let is_normalized_drive = |text: &str| is_drive(text) && text.ends_with(':');
    if is_drive(host) {
        // The drive letter is the first path segment (the buffer is kept).
        remaining = rest;
    } else {
        if !host.is_empty() && !percent_decode_bytes(host)?.eq_ignore_ascii_case(b"localhost") {
            return None;
        }
        remaining = &rest[host_end..];
        // Path start state: one leading separator is consumed.
        if let Some(stripped) = remaining.strip_prefix(is_separator) {
            remaining = stripped;
        }
    }
    // Path state.
    let mut buffer = String::new();
    let mut chars = remaining.chars().peekable();
    loop {
        let c = chars.next();
        let boundary = matches!(c, None | Some('/' | '\\' | '?' | '#'));
        if !boundary {
            buffer.push(c.unwrap_or_default());
            continue;
        }
        let lower = buffer.to_ascii_lowercase();
        let double_dot = matches!(lower.as_str(), ".." | ".%2e" | "%2e." | "%2e%2e");
        let single_dot = matches!(lower.as_str(), "." | "%2e");
        let slash = matches!(c, Some('/' | '\\'));
        if double_dot {
            if !(path.len() == 1 && is_normalized_drive(&path[0])) {
                path.pop();
            }
            if !slash {
                path.push(String::new());
            }
        } else if single_dot && !slash {
            path.push(String::new());
        } else if !single_dot {
            if path.is_empty() && is_drive(&buffer) {
                buffer = format!("{}:", buffer.chars().next().unwrap_or_default());
            }
            path.push(std::mem::take(&mut buffer));
        }
        buffer.clear();
        if !slash {
            break;
        }
    }
    let pathname = format!("/{}", path.join("/"));
    // Node refuses an encoded `/`, then decodes the rest.
    let lower = pathname.to_ascii_lowercase();
    if lower.contains("%2f") {
        return None;
    }
    String::from_utf8(percent_decode_bytes(&pathname)?).ok()
}

/// `decodeURIComponent` as bytes: every `%XX` becomes its byte; None for a
/// `%` not followed by two hex digits.
fn percent_decode_bytes(text: &str) -> Option<Vec<u8>> {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' {
            let hex = |at: usize| bytes.get(at).and_then(|b| (*b as char).to_digit(16));
            let value = hex(index + 1)? * 16 + hex(index + 2)?;
            out.push(value as u8);
            index += 3;
        } else {
            out.push(bytes[index]);
            index += 1;
        }
    }
    Some(out)
}

// MARK: - Transcript location

struct Locate<'a> {
    kind: &'a str,
    session_kind: Option<&'a str>,
    session_value: Option<&'a str>,
    cwd: Option<&'a str>,
    launched_at: Option<&'a str>,
    launch_rivals: Option<&'a dyn Fn(&RivalQuery) -> Rivals>,
    env: &'a Env,
    home: &'a str,
    signal: Option<&'a Arc<AbortSignal>>,
}

fn locate_transcript(args: &Locate<'_>) -> ChatResult<Option<String>> {
    let (kind, home) = (args.kind, args.home);
    let session_value = args.session_value.filter(|value| !value.is_empty());
    // An exported kind has no transcript files: sessions live in the
    // harness's own database and it never pins a path. A session id (herdr's
    // integration, the Status Hook's `@waycar_session`, or the marker's)
    // names a chat, and the parser runs the harness's export for it. Without
    // one, the harness lists the sessions started in the launch's cwd and the
    // launch match picks one, as for transcript files.
    if is_exported(kind) {
        if args.session_kind == Some("id")
            && let Some(value) = session_value
        {
            return Ok(Some(value.to_string()));
        }
        return if args.session_kind.is_none() {
            find_exported_by_launch(args)
        } else {
            Ok(None)
        };
    }
    let reader = reader(kind);
    let root = kind_root(kind, args.env, home);
    if args.session_kind == Some("path")
        && let Some(value) = session_value
    {
        let file = expand_home(value, home);
        // gemini can report a path it never writes; its reader finds the
        // real file.
        let resolved = match reader.and_then(|reader| reader.resolve_path) {
            Some(resolve_path) => resolve_path(&file)?,
            None => None,
        }
        .unwrap_or(file);
        let info = std::fs::metadata(&resolved)
            .map_err(|error| ChatError::io(&error, "stat", &resolved))?;
        if !info.is_file() {
            return Err(ChatError::other(format!("not a file: {resolved}")));
        }
        return Ok(Some(resolved));
    }
    if args.session_kind == Some("id")
        && let Some(value) = session_value
    {
        if !safe_name(value) {
            return Ok(None);
        }
        return match reader {
            Some(reader) => (reader.find_by_id)(value, &root),
            None => Ok(find_by_id(kind, value, &root)),
        };
    }
    if let Some(reader) = reader {
        return match reader.find_by_launch {
            Some(find) => find(&LaunchQuery {
                cwd: args.cwd,
                launched_at: args.launched_at.and_then(date_ms),
                root: &root,
                home,
            }),
            None => Ok(None),
        };
    }
    find_by_launch(kind, args.cwd, args.launched_at, &root, home)
}

/// `Date.parse(text)` for a launch time.
fn date_ms(text: &str) -> Option<f64> {
    launched_ms(&Value::String(text.to_string()))
}

/// No session id for an exported kind: the session the launch started,
/// matched like `find_by_launch` over the sessions the harness lists (closest
/// creation to the launch, never before its slack, recorded cwd equal to the
/// launch's). opencode and kilo create a session at its first prompt, which
/// can come any time after the launch, so no window applies, and another
/// Agent of the kind in the same cwd could have started any later session.
/// So with `launch_rivals` (see launch-rivals.js), the ids other Agents name
/// are left out, and the launches of the others that name none are matched
/// oldest first: each takes its session only when no later launch could have
/// started it (created before the next launch's slack), else the match is
/// ambiguous and nothing is read. Candidates are tried closest to each launch
/// first, and a hermes read exports at most `MAX_LAUNCH_EXPORTS`.
fn find_exported_by_launch(args: &Locate<'_>) -> ChatResult<Option<String>> {
    let (kind, home) = (args.kind, args.home);
    let (Some(cwd), Some(launched_at)) = (args.cwd.filter(|cwd| !cwd.is_empty()), args.launched_at)
    else {
        return Ok(None);
    };
    let Some(launched) = jsx::date_parse(launched_at) else {
        return Ok(None);
    };
    let launch_cwd = jspath::resolve(&[&expand_home(cwd, home)]);
    let mut options = ExportOptions::new(args.env.clone(), home);
    options.signal = args.signal.cloned();
    // A JS `Map` keyed by id: a repeated id replaces the entry in place.
    let mut candidates: Vec<Candidate> = Vec::new();
    for candidate in launch_candidates(kind, &Value::String(launch_cwd.clone()), &options)? {
        match candidates.iter().position(|known| known.id == candidate.id) {
            Some(index) => candidates[index] = candidate,
            None => candidates.push(candidate),
        }
    }
    let rivals = match args.launch_rivals {
        Some(rivals) => rivals(&RivalQuery {
            kind: kind.to_string(),
            cwd: launch_cwd,
            launched,
        }),
        None => Rivals {
            claimed: HashSet::new(),
            launches: Vec::new(),
        },
    };
    candidates.retain(|candidate| !rivals.claimed.contains(&candidate.id));

    let probed: RefCell<HashMap<String, Option<Found>>> = RefCell::new(HashMap::new());
    let exports_left = Cell::new(MAX_LAUNCH_EXPORTS);
    let mut order: Vec<f64> = Vec::new();
    for at in rivals
        .launches
        .iter()
        .copied()
        .chain(std::iter::once(launched))
    {
        if !order.contains(&at) {
            order.push(at);
        }
    }
    order.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    for (index, &at) in order.iter().enumerate() {
        let pick = {
            let find = |id: &str| candidates.iter().find(|candidate| candidate.id == id);
            let probe = |id: &str| -> ChatResult<Option<Found>> {
                if !probed.borrow().contains_key(id) {
                    let Some(candidate) = find(id) else {
                        return Ok(None);
                    };
                    if candidate.exports {
                        if exports_left.get() == 0 {
                            return Ok(None);
                        }
                        exports_left.set(exports_left.get() - 1);
                    }
                    let found = candidate.probe();
                    probed.borrow_mut().insert(id.to_string(), found);
                }
                Ok(probed.borrow().get(id).cloned().flatten())
            };
            let stat = |id: &str| {
                find(id).map(|candidate| FileStat {
                    mtime_ms: candidate.updated,
                    birthtime_ms: candidate.created,
                })
            };
            let created_of = |id: &str| find(id).map_or(f64::NAN, |candidate| candidate.created);
            let mut files: Vec<String> = candidates
                .iter()
                .map(|candidate| candidate.id.clone())
                .collect();
            files.sort_by(|a, b| {
                let distance = |id: &str| (created_of(id) - at).abs();
                (distance(a) - distance(b))
                    .partial_cmp(&0.0)
                    .unwrap_or(std::cmp::Ordering::Equal)
            });
            pick_by_launch(&PickArgs {
                files: &files,
                probe: &probe,
                cwd: Some(cwd),
                launched_at: Some(at),
                home,
                window: false,
                cwd_matches: None,
                stat: Some(&stat),
            })?
        };
        let Some(pick) = pick else {
            return Ok(None);
        };
        let probed_created = probed
            .borrow()
            .get(&pick)
            .cloned()
            .flatten()
            .and_then(|found| found.created);
        let created = probed_created
            .or_else(|| {
                candidates
                    .iter()
                    .find(|candidate| candidate.id == pick)
                    .map(|candidate| candidate.created)
            })
            .unwrap_or(f64::NAN);
        if let Some(next) = order.get(index + 1)
            && created >= next - LAUNCH_SLACK_MS
        {
            return Ok(None);
        }
        if at == launched {
            return Ok(Some(pick));
        }
        candidates.retain(|candidate| candidate.id != pick);
    }
    Ok(None)
}

/// Where a harness's data lives: `CLAUDE_CONFIG_DIR`, `CODEX_HOME`,
/// `PI_CODING_AGENT_DIR` or `XDG_DATA_HOME` when set, else the harness's
/// usual directory under `home`.
pub fn kind_root(kind: &str, env: &Env, home: &str) -> String {
    if let Some(reader) = reader(kind) {
        return (reader.root)(env, home);
    }
    let from_env = |name: &str, default: &[&str]| match env.non_empty(name) {
        Some(value) => expand_home(value, home),
        None => {
            let mut parts = vec![home];
            parts.extend_from_slice(default);
            jspath::join(&parts)
        }
    };
    match kind {
        "claude" => from_env("CLAUDE_CONFIG_DIR", &[".claude"]),
        "codex" => from_env("CODEX_HOME", &[".codex"]),
        "pi" => from_env("PI_CODING_AGENT_DIR", &[".pi", "agent"]),
        // The harness's data root (`~/.local/share/<kind>`), where its
        // session database lives; the parser needs no files from it, but the
        // kind's root stays uniform for tests and future use.
        "opencode" | "kilo" => {
            jspath::join(&[&from_env("XDG_DATA_HOME", &[".local", "share"]), kind])
        }
        _ => jspath::join(&[home, ".omp", "agent"]),
    }
}

fn find_by_id(kind: &str, id: &str, root: &str) -> Option<String> {
    let candidates: Vec<String> = if kind == "claude" {
        subdirectories(&jspath::join(&[root, "projects"]))
            .iter()
            .map(|dir| jspath::join(&[dir, &format!("{id}.jsonl")]))
            .collect()
    } else if kind == "codex" {
        let suffix = format!("-{id}.jsonl");
        walk_files(&jspath::join(&[root, "sessions"]), &|name| {
            name.starts_with("rollout-") && name.ends_with(&suffix)
        })
    } else {
        let suffix = format!("_{id}.jsonl");
        let mut found = Vec::new();
        for dir in subdirectories(&jspath::join(&[root, "sessions"])) {
            for name in list_names(&dir) {
                if name.ends_with(&suffix) {
                    found.push(jspath::join(&[&dir, &name]));
                }
            }
        }
        found
    };
    newest_file(&candidates)
}

/// No session recorded: the launch match (`pick_by_launch`) over the kind's
/// transcripts. codex and omp record process start, so a transcript that
/// records a start more than `LAUNCH_WINDOW_MS` after the launch belongs to a
/// later Agent. claude's creation time is its first message, which can come
/// any time after the launch; claude and pi launches pin a session id.
fn find_by_launch(
    kind: &str,
    cwd: Option<&str>,
    launched_at: Option<&str>,
    root: &str,
    home: &str,
) -> ChatResult<Option<String>> {
    let files: Vec<String> = if kind == "codex" {
        walk_files(&jspath::join(&[root, "sessions"]), &|name| {
            name.starts_with("rollout-") && name.ends_with(".jsonl")
        })
    } else {
        let mut files = Vec::new();
        let base = jspath::join(&[
            root,
            if kind == "claude" {
                "projects"
            } else {
                "sessions"
            },
        ]);
        for dir in subdirectories(&base) {
            for name in list_names(&dir) {
                if name.ends_with(".jsonl") {
                    files.push(jspath::join(&[&dir, &name]));
                }
            }
        }
        files
    };
    pick_by_launch(&PickArgs {
        files: &files,
        probe: &|file| Ok(probe_transcript(kind, file)),
        cwd,
        launched_at: launched_at.and_then(date_ms),
        home,
        window: kind == "codex" || kind == "omp",
        cwd_matches: None,
        stat: None,
    })
}

/// The recorded cwd and creation time from a transcript's first lines.
fn probe_transcript(kind: &str, file: &str) -> Option<Found> {
    let mut cwd: Option<String> = None;
    let mut created: Option<f64> = None;
    let records = read_records(file, None).ok()?;
    for item in records {
        let item = item.ok()?;
        if item.line > PROBE_LINES {
            break;
        }
        let record = &item.record;
        if kind == "codex" {
            if !is_type(record, "session_meta") {
                continue;
            }
            let payload = field(record, "payload");
            // Subagent threads share the parent's cwd; they are never the Agent.
            let source = field(payload, "source");
            if truthy(source) && (source.is_object() || source.is_array()) {
                return None;
            }
            let stamp = field(payload, "timestamp");
            return Some(Found {
                cwd: str_field(payload, "cwd").map(str::to_string),
                created: parse_time(if stamp.is_null() {
                    field(record, "timestamp")
                } else {
                    stamp
                }),
            });
        }
        if kind == "claude" {
            if get(record, "isSidechain") == Some(&Value::Bool(true)) {
                continue;
            }
            if cwd.is_none() {
                cwd = str_field(record, "cwd").map(str::to_string);
            }
            if created.is_none() {
                created = parse_time(field(record, "timestamp"));
            }
            if cwd.is_some() && created.is_some() {
                break;
            }
            continue;
        }
        if is_type(record, "session") {
            return Some(Found {
                cwd: str_field(record, "cwd").map(str::to_string),
                created: parse_time(field(record, "timestamp")),
            });
        }
    }
    cwd.map(|cwd| Found {
        cwd: Some(cwd),
        created,
    })
}

#[cfg(test)]
mod file_url_tests {
    use super::file_url_to_path;
    use crate::jspath;

    /// Node's `path.resolve(fileURLToPath(url))` for each URL, recorded from
    /// Node 24.
    #[test]
    fn file_urls_resolve_like_nodes_file_url_to_path() {
        let cases: &[(&str, Option<&str>)] = &[
            ("file:///tmp/a.png", Some("/tmp/a.png")),
            ("file:///tmp/a%20b.png", Some("/tmp/a b.png")),
            ("file:///tmp/../etc/passwd", Some("/etc/passwd")),
            ("file:///tmp/%2e%2e/etc", Some("/etc")),
            ("file:///tmp/%2E/x/.", Some("/tmp/x")),
            ("file:///tmp/a%2Fb", None),
            ("file:///tmp/a%2fb", None),
            ("file:///tmp/%zz", None),
            ("file:///tmp/%C3%A9.png", Some("/tmp/é.png")),
            ("file:///tmp/%C3.png", None),
            ("file:///tmp/%E9", None),
            ("file://localhost/tmp/x", Some("/tmp/x")),
            ("file://LOCALHOST/tmp/x", Some("/tmp/x")),
            ("file://%6Cocalhost/tmp/x", Some("/tmp/x")),
            ("file://host/tmp/x", None),
            ("file:///tmp/x?q=1#f", Some("/tmp/x")),
            ("file:///tmp/x#f", Some("/tmp/x")),
            ("file:///tmp\\y\\z", Some("/tmp/y/z")),
            ("file://C:/x/y", Some("/C:/x/y")),
            ("file://c|/x", Some("/c:/x")),
            ("file:///C:/x/../..", Some("/C:")),
            ("file://", Some("/")),
            ("file:///", Some("/")),
            ("file://?x", Some("/")),
            ("file:///tmp/a\tb/c\nd", Some("/tmp/ab/cd")),
            ("file:///tmp/ü/é", Some("/tmp/ü/é")),
            ("file:///tmp/a b", Some("/tmp/a b")),
            ("file://localhost", Some("/")),
            ("file://localhost?x", Some("/")),
            ("file:////tmp/x", Some("/tmp/x")),
            ("file:///tmp//x", Some("/tmp/x")),
            ("file:///.", Some("/")),
            ("file:///..", Some("/")),
            ("file:///a/b/../../..", Some("/")),
            ("file:///tmp/a.png  ", Some("/tmp/a.png")),
            ("file:///tmp/%00x", Some("/tmp/\0x")),
            ("file://[::1]/x", None),
            ("file://127.0.0.1/x", None),
            ("file:///tmp/%2541", Some("/tmp/%41")),
            ("file:///tmp/a%5Cb", Some("/tmp/a\\b")),
            ("file://C:", Some("/C:")),
            ("file://C:x", None),
            ("file:///tmp/..%2f..", None),
            ("file:///tmp/.%2e/x", Some("/x")),
            ("file:///tmp/%2e%2E", Some("/")),
            ("file:///tmp/%2e./y", Some("/y")),
        ];
        for (url, expected) in cases {
            let actual = file_url_to_path(url).map(|path| jspath::resolve(&[&path]));
            assert_eq!(actual.as_deref(), *expected, "{url:?}");
        }
    }
}
