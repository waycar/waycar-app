//! Shared pieces of the Chat Mode transcript readers (chat-shared.js): turn
//! assembly, tool activity lines, media items, transcript discovery and line
//! reading. Every reader under `chat::readers` and `chat::transcript` builds
//! on this.
//!
//! Conventions every chat module follows:
//!
//! * Synchronous. The JS awaits file and process work one step at a time;
//!   Rust does the same work in order on one thread.
//! * Paths are `String`s handled with [`crate::jspath`], because they cross
//!   the JSON boundary as strings and Node's `path` is not `std::path`.
//! * Records are [`serde_json::Value`] with `preserve_order`, read with the
//!   [`crate::jsx`] accessors (`field`, `get`, `truthy`), so the dynamic
//!   typing of the JS carries over one for one.
//! * Failures are [`ChatError`], which carries what `readChat` tells apart:
//!   a missing file (`not_found`), a failed export (`located`) and
//!   everything else (`error`, with Node's message text).

use std::collections::HashSet;
use std::fs;
use std::io::{self, BufRead, BufReader};
use std::os::unix::fs::MetadataExt;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use serde_json::{Map, Value, json};

use crate::jspath;
use crate::jsx::{self, clip, field, trim, truthy};

// MARK: - Limits

pub const TEXT_CAP: usize = 20_000;
pub const ACTIVITY_CAP: usize = 100;
const COMMAND_CAP: usize = 40;
/// A transcript created this long before the recorded launch still counts.
pub const LAUNCH_SLACK_MS: f64 = 10_000.0;
/// codex `session_meta` and omp `session` timestamps record process start,
/// not the lazy file creation: one that records a start this long after the
/// launch belongs to an Agent started later in the same cwd.
pub const LAUNCH_WINDOW_MS: f64 = 2.0 * 60_000.0;
/// Header records (cwd, creation time) sit within a transcript's first lines.
pub const PROBE_LINES: usize = 200;
/// At most this many tool-result images ride on one reply.
const MEDIA_CAP: usize = 12;
/// A whole-file JSON document is refused over this.
const MAX_DOCUMENT_BYTES: u64 = 64 * 1024 * 1024;

/// Leading base64 of each image format's magic bytes, for images recorded
/// without a mime type.
const BASE64_SIGNATURES: [(&str, &str); 4] = [
    ("iVBORw0KGgo", "image/png"),
    ("/9j/", "image/jpeg"),
    ("R0lGOD", "image/gif"),
    ("UklGR", "image/webp"),
];

const RUN_TOOLS: [&str; 12] = [
    "bash",
    "shell",
    "exec",
    "exec_command",
    "shell_command",
    "local_shell",
    "local_shell_call",
    "run_command",
    "run_commands",
    "run_shell_command",
    "run_terminal_command",
    "terminal",
];
const READ_TOOLS: [&str; 2] = ["read", "read_file"];
const EDIT_TOOLS: [&str; 7] = [
    "edit",
    "write",
    "apply_patch",
    "multiedit",
    "notebookedit",
    "edit_file",
    "write_file",
];
const SEARCH_TOOLS: [&str; 5] = ["grep", "glob", "find", "search", "ls"];
const WEB_TOOLS: [&str; 2] = ["fetch", "web_search_call"];
const SUBAGENT_TOOLS: [&str; 4] = ["task", "agent", "subagent", "spawn_agent"];
const SHELLS: [&str; 6] = ["bash", "sh", "zsh", "/bin/bash", "/bin/sh", "/bin/zsh"];

// MARK: - Errors

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ErrorKind {
    /// A file system failure; the Node error code (`ENOENT`, `EACCES`, ...).
    Io(String),
    /// `SessionExportError`: `located` false reads as `not_found`; `absent`
    /// is true only when there truly is nothing to read.
    Export { located: bool, absent: bool },
    /// The read was aborted; the message is the signal's reason.
    Aborted,
    /// Any other `Error`.
    Other,
}

/// What a JS `throw` carried that the readers look at.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChatError {
    pub kind: ErrorKind,
    /// `error.message`.
    pub message: String,
}

pub type ChatResult<T> = Result<T, ChatError>;

impl ChatError {
    pub fn other(message: impl Into<String>) -> Self {
        Self {
            kind: ErrorKind::Other,
            message: message.into(),
        }
    }

    pub fn export(message: impl Into<String>, located: bool, absent: bool) -> Self {
        Self {
            kind: ErrorKind::Export { located, absent },
            message: message.into(),
        }
    }

    /// `error.code === "ENOENT" || "ENOTDIR"`.
    pub fn is_missing(&self) -> bool {
        matches!(&self.kind, ErrorKind::Io(code) if code == "ENOENT" || code == "ENOTDIR")
    }

    /// A Node fs error: `CODE: description, syscall 'path'`; `path` is
    /// empty for a call that names none (a stream `read`).
    pub fn io(error: &io::Error, syscall: &str, path: &str) -> Self {
        let (code, description) = errno_text(error);
        let message = if path.is_empty() {
            format!("{code}: {description}, {syscall}")
        } else {
            format!("{code}: {description}, {syscall} '{path}'")
        };
        Self {
            kind: ErrorKind::Io(code.clone()),
            message,
        }
    }
}

impl std::fmt::Display for ChatError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for ChatError {}

/// libuv's name and message for an errno, as Node prints them.
fn errno_text(error: &io::Error) -> (String, String) {
    let table: [(i32, &str, &str); 12] = [
        (libc::ENOENT, "ENOENT", "no such file or directory"),
        (libc::EACCES, "EACCES", "permission denied"),
        (libc::EISDIR, "EISDIR", "illegal operation on a directory"),
        (libc::ENOTDIR, "ENOTDIR", "not a directory"),
        (libc::ELOOP, "ELOOP", "too many symbolic links encountered"),
        (libc::EMFILE, "EMFILE", "too many open files"),
        (libc::ENAMETOOLONG, "ENAMETOOLONG", "name too long"),
        (libc::EIO, "EIO", "i/o error"),
        (libc::EPERM, "EPERM", "operation not permitted"),
        (libc::ENOMEM, "ENOMEM", "not enough memory"),
        (libc::ENFILE, "ENFILE", "file table overflow"),
        (libc::EBUSY, "EBUSY", "resource busy or locked"),
    ];
    if let Some(errno) = error.raw_os_error() {
        if let Some((_, code, text)) = table.iter().find(|(n, _, _)| *n == errno) {
            return ((*code).into(), (*text).into());
        }
        return (format!("E{errno}"), error.to_string().to_lowercase());
    }
    ("EIO".into(), error.to_string().to_lowercase())
}

/// An `AbortSignal`: another thread (a deadline timer) calls [`abort`]; the
/// reader checks between lines and stops with the reason.
///
/// [`abort`]: AbortSignal::abort
#[derive(Debug, Default)]
pub struct AbortSignal {
    aborted: AtomicBool,
    reason: std::sync::Mutex<String>,
}

impl AbortSignal {
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    pub fn abort(&self, reason: impl Into<String>) {
        if let Ok(mut slot) = self.reason.lock()
            && !self.aborted.load(Ordering::SeqCst)
        {
            *slot = reason.into();
        }
        self.aborted.store(true, Ordering::SeqCst);
    }

    pub fn is_aborted(&self) -> bool {
        self.aborted.load(Ordering::SeqCst)
    }

    /// `signal.throwIfAborted()`.
    pub fn check(&self) -> ChatResult<()> {
        if !self.is_aborted() {
            return Ok(());
        }
        let reason = self.reason.lock().map(|r| r.clone()).unwrap_or_default();
        Err(ChatError {
            kind: ErrorKind::Aborted,
            message: reason,
        })
    }
}

/// `signal?.throwIfAborted()`.
pub fn check_abort(signal: Option<&AbortSignal>) -> ChatResult<()> {
    signal.map_or(Ok(()), AbortSignal::check)
}

// MARK: - Time

/// `parseTime`: a finite number as is, a string through `Date.parse`.
pub fn parse_time(value: &Value) -> Option<f64> {
    match value {
        Value::Number(n) => Some(jsx::json_f64(n)).filter(|f| f.is_finite()),
        Value::String(s) => jsx::date_parse(s),
        _ => None,
    }
}

/// `isoTimestamp(value)`: null for no time. `new Date(t).toISOString()`
/// throws a RangeError for a number outside the Date range, which the read
/// reports as an `error` header.
pub fn iso_timestamp(time: Option<f64>) -> ChatResult<Option<String>> {
    match time {
        None => Ok(None),
        Some(t) => jsx::to_iso_string(t)
            .map(Some)
            .ok_or_else(|| ChatError::other("Invalid time value")),
    }
}

// MARK: - Messages

/// `makeMessage`: `{type, id, role, text, ts, media?}` in that key order.
pub fn make_message(
    id: &str,
    role: &str,
    text: &str,
    ts: Option<f64>,
    media: &[Value],
) -> ChatResult<Value> {
    let mut message = Map::new();
    message.insert("type".into(), json!("message"));
    message.insert("id".into(), json!(id));
    message.insert("role".into(), json!(role));
    message.insert("text".into(), json!(cap_text(text)));
    message.insert("ts".into(), json!(iso_timestamp(ts)?));
    if !media.is_empty() {
        message.insert("media".into(), Value::Array(media.to_vec()));
    }
    Ok(Value::Object(message))
}

// MARK: - Media

/// A tool-result image: the `media` item, its dedupe key and, for an omp/pi
/// blob, the file the caller checks exists.
#[derive(Debug, Clone)]
pub struct ToolImage {
    pub item: Value,
    pub key: String,
    pub blob_path: Option<String>,
}

/// `toolImage`: a tool-result image as a media item, or None when there is
/// nothing to show. `data` is an omp/pi blob reference, raw base64 or a
/// base64 `data:` URL; `offset` and `pointer` name the string's place in the
/// transcript (`pointer` is whatever JS passed: a string path or number).
pub fn tool_image(
    data: &Value,
    mime: &Value,
    transcript: &str,
    offset: u64,
    pointer: &str,
    root: &str,
) -> Option<ToolImage> {
    let data = data.as_str().filter(|d| !d.is_empty())?;
    let declared = mime.as_str().filter(|m| !m.is_empty());
    if let Some(sha) = blob_ref(data) {
        let path = jspath::join(&[root, "blobs", sha]);
        let item = json!({ "id": data, "kind": "image", "mime": declared, "path": path });
        return Some(ToolImage {
            item,
            key: data.to_string(),
            blob_path: Some(path),
        });
    }
    let prefix = base64_data_url_prefix(data);
    if prefix.is_none() && data.starts_with("data:") {
        return None;
    }
    let payload = prefix.map_or(data, |(len, _)| &data[len..]);
    if payload.is_empty() {
        return None;
    }
    let mime_value = declared
        .map(str::to_string)
        .or_else(|| prefix.and_then(|(_, mime)| (!mime.is_empty()).then(|| mime.to_string())))
        .or_else(|| sniff_base64_image(payload).map(str::to_string));
    let item = json!({
        "id": format!("inline:{offset}:{pointer}"),
        "kind": "image",
        "mime": mime_value,
        "inline": { "transcript": transcript, "offset": offset, "pointer": pointer },
    });
    Some(ToolImage {
        item,
        key: format!("sha256:{}", sha256_hex(payload.as_bytes())),
        blob_path: None,
    })
}

/// The SHA-256 of `bytes` as 64 lower-case hex digits.
pub fn sha256_hex(bytes: &[u8]) -> String {
    use std::fmt::Write as _;
    ring::digest::digest(&ring::digest::SHA256, bytes)
        .as_ref()
        .iter()
        .fold(String::with_capacity(64), |mut out, byte| {
            let _ = write!(out, "{byte:02x}");
            out
        })
}

/// `/^blob:sha256:([0-9a-f]{64})$/`: the digest.
pub fn blob_ref(data: &str) -> Option<&str> {
    let sha = data.strip_prefix("blob:sha256:")?;
    (sha.len() == 64 && sha.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))).then_some(sha)
}

/// `/^data:([^;,]*)(?:;[^;,]*)*;base64,/i`: the prefix's byte length and the
/// mime type (group 1, as written).
pub fn base64_data_url_prefix(data: &str) -> Option<(usize, &str)> {
    let head = data.get(..5)?;
    if !head.eq_ignore_ascii_case("data:") {
        return None;
    }
    let rest = &data[5..];
    // Group 1 runs to the first ';' or ','; a ',' there ends the prefix
    // without ";base64,", so no match.
    let first_end = rest.find([';', ','])?;
    if rest.as_bytes()[first_end] == b',' {
        return None;
    }
    let mime = &rest[..first_end];
    // Parameters follow, each `;` plus non-`;,` text; the prefix ends at the
    // first ',' and the last parameter must be `base64` (any case).
    let comma = rest[first_end..].find(',')? + first_end;
    let params = &rest[first_end..comma];
    // A ';' list: every piece has no ',' by construction.
    let last = params.rsplit(';').next()?;
    if !last.eq_ignore_ascii_case("base64") {
        return None;
    }
    Some((5 + comma + 1, mime))
}

fn sniff_base64_image(payload: &str) -> Option<&'static str> {
    BASE64_SIGNATURES
        .iter()
        .find(|(signature, _)| payload.starts_with(signature))
        .map(|(_, mime)| *mime)
}

// MARK: - Turns

#[derive(Debug, Clone)]
struct PromptItem {
    id: String,
    text: String,
    ts: Option<f64>,
}

#[derive(Debug, Clone)]
struct Anchor {
    id: String,
    ts: Option<f64>,
}

/// Steps done and in all of a turn's plan (plan-progress.js).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PlanSteps {
    pub done: u32,
    pub total: u32,
}

/// One turn: its prompts, what the assistant did and the reply to emit.
#[derive(Debug, Clone)]
pub struct Turn {
    /// Position among the turns: turn identity for observers.
    pub seq: usize,
    prompts: Vec<PromptItem>,
    turn_key: Option<String>,
    reply_id: String,
    command: bool,
    reply: Vec<String>,
    reply_start: Option<Anchor>,
    last_item: Option<Anchor>,
    activity: Option<String>,
    error_text: Option<String>,
    media: Vec<Value>,
    media_keys: HashSet<String>,
    pub ended: bool,
    /// The steps of the last plan written in this turn (set by an observer).
    pub plan: Option<PlanSteps>,
}

fn new_turn(seq: usize, turn_key: Option<&str>, reply_id: String) -> Turn {
    Turn {
        seq,
        prompts: Vec::new(),
        turn_key: turn_key.map(str::to_string),
        reply_id,
        command: false,
        reply: Vec::new(),
        reply_start: None,
        last_item: None,
        activity: None,
        error_text: None,
        media: Vec::new(),
        media_keys: HashSet::new(),
        ended: false,
        plan: None,
    }
}

/// `prompt({...})`. Defaults are the JS defaults.
#[derive(Debug, Clone, Default)]
pub struct Prompt<'a> {
    pub id: &'a str,
    pub text: &'a str,
    pub ts: Option<f64>,
    pub steering: bool,
    pub hidden: bool,
    pub command: bool,
    pub turn_key: Option<&'a str>,
    pub reply_id: Option<&'a str>,
}

/// `tool({...})`. `name`, `input` and `call_id` reach an observer only.
#[derive(Debug, Clone, Default)]
pub struct ToolCall<'a> {
    pub id: &'a str,
    pub ts: Option<f64>,
    pub activity: String,
    pub turn_key: Option<&'a str>,
    pub name: Option<&'a str>,
    pub input: Option<&'a Value>,
    pub call_id: Option<&'a str>,
}

/// `toolResult({...})`: `call_id` names its call, `name` its tool when the
/// record says, `content` the raw result content and `details` any
/// structured result the harness recorded.
#[derive(Debug, Clone, Copy)]
pub struct ToolResult<'a> {
    pub call_id: Option<&'a str>,
    pub name: Option<&'a str>,
    pub content: &'a Value,
    pub details: &'a Value,
}

/// What `class PlanTurns extends ChatTurns` overrides: `observes`, `tool`
/// (after the base's) and `toolResult`.
pub trait TurnObserver {
    /// Whether the observer wants tool `name`'s call input and results.
    fn observes(&self, name: Option<&str>) -> bool;
    /// After the base `tool`: `turn` is the turn the call landed in.
    fn tool(&mut self, turn: &mut Turn, call: &ToolCall<'_>);
    /// `turn` is the current turn, None when there is none yet.
    fn tool_result(&mut self, turn: Option<&mut Turn>, result: &ToolResult<'_>);
}

/// The result of [`ChatTurns::finish`].
#[derive(Debug, Clone)]
pub struct Chat {
    pub messages: Vec<Value>,
    pub turn_open: bool,
    pub activity: Option<String>,
}

/// Collects prompts and assistant items into turns, whatever the harness.
///
/// A turn's final reply is the assistant text written after its last tool
/// call. A turn is complete when a later real prompt starts another turn,
/// when the Agent Status says idle or done (unless the parser saw that the
/// run is still going), or when the harness wrote its own end marker and
/// nothing came after it.
#[derive(Default)]
pub struct ChatTurns {
    turns: Vec<Turn>,
    /// The transcript's last record proves the run is still going (omp/pi: a
    /// trailing prompt, tool result or tool call), so an idle or done status
    /// does not complete the last turn.
    pub run_continues: bool,
    observer: Option<Box<dyn TurnObserver>>,
}

impl ChatTurns {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_observer(observer: Box<dyn TurnObserver>) -> Self {
        Self {
            observer: Some(observer),
            ..Self::default()
        }
    }

    pub fn current(&self) -> Option<&Turn> {
        self.turns.last()
    }

    pub fn current_mut(&mut self) -> Option<&mut Turn> {
        self.turns.last_mut()
    }

    /// A prompt. A real one starts a new turn unless it steers the running
    /// one (a message typed while the Agent works). A hidden one (a
    /// harness-injected notification) is never shown; it starts a new turn
    /// only when the last one had ended. A `command` (slash command) turn
    /// that gets no assistant item shows no empty reply.
    pub fn prompt(&mut self, p: Prompt<'_>) {
        let running = self.turns.last().is_some_and(|turn| !turn.ended);
        let reply_id = p
            .reply_id
            .map_or_else(|| format!("{}:reply", p.id), str::to_string);
        if p.hidden {
            if !running {
                let seq = self.turns.len();
                self.turns.push(new_turn(seq, p.turn_key, reply_id));
            }
            return;
        }
        let joins = running
            && (p.steering
                || (p.turn_key.is_some()
                    && self.turns.last().and_then(|t| t.turn_key.as_deref()) == p.turn_key));
        if joins {
            if let Some(turn) = self.turns.last_mut() {
                turn.prompts.push(PromptItem {
                    id: p.id.to_string(),
                    text: p.text.to_string(),
                    ts: p.ts,
                });
            }
            return;
        }
        let seq = self.turns.len();
        let mut turn = new_turn(seq, p.turn_key, reply_id);
        turn.command = p.command;
        turn.prompts.push(PromptItem {
            id: p.id.to_string(),
            text: p.text.to_string(),
            ts: p.ts,
        });
        self.turns.push(turn);
    }

    /// Assistant text. `text` is whatever the record held: not a string, or
    /// blank, adds nothing.
    pub fn text(&mut self, id: &str, ts: Option<f64>, text: &Value, turn_key: Option<&str>) {
        let clean = text.as_str().map_or("", trim);
        if clean.is_empty() {
            return;
        }
        let turn = self.assistant_item(id, ts, turn_key);
        if turn.reply.is_empty() {
            turn.reply_start = Some(Anchor {
                id: id.to_string(),
                ts,
            });
        }
        turn.reply.push(clean.to_string());
        turn.activity = Some(first_line(clean));
    }

    /// Like [`text`](Self::text) for a Rust string.
    pub fn text_str(&mut self, id: &str, ts: Option<f64>, text: &str, turn_key: Option<&str>) {
        self.text(id, ts, &Value::String(text.to_string()), turn_key);
    }

    pub fn tool(&mut self, call: ToolCall<'_>) {
        let turn = self.assistant_item(call.id, call.ts, call.turn_key);
        turn.reply = Vec::new();
        turn.reply_start = None;
        turn.activity = Some(call.activity.clone());
        if let Some(observer) = self.observer.as_mut()
            && let Some(turn) = self.turns.last_mut()
        {
            observer.tool(turn, &call);
        }
    }

    /// Whether an observer wants tool `name`'s call input and results.
    pub fn observes(&self, name: Option<&str>) -> bool {
        self.observer.as_ref().is_some_and(|o| o.observes(name))
    }

    pub fn tool_result(&mut self, result: ToolResult<'_>) {
        if let Some(observer) = self.observer.as_mut() {
            observer.tool_result(self.turns.last_mut(), &result);
        }
    }

    pub fn thinking(&mut self, id: &str, ts: Option<f64>, turn_key: Option<&str>) {
        let turn = self.assistant_item(id, ts, turn_key);
        turn.activity = Some("Thinking".into());
    }

    /// Interim assistant text that is never part of the reply (codex
    /// commentary).
    pub fn note(&mut self, id: &str, ts: Option<f64>, text: &Value, turn_key: Option<&str>) {
        let clean = text.as_str().map_or("", trim);
        if clean.is_empty() {
            return;
        }
        let turn = self.assistant_item(id, ts, turn_key);
        turn.activity = Some(first_line(clean));
    }

    /// A tool-result image the Agent viewed. It rides on the running turn's
    /// final reply, never starts a turn and never joins a turn that already
    /// ended: the first 12 distinct images in transcript order. `key`
    /// defaults to the item's id.
    pub fn media(&mut self, image: &ToolImage, turn_key: Option<&str>) {
        let Some(turn) = self.turns.last_mut() else {
            return;
        };
        if turn.ended || (turn_key.is_some() && turn.turn_key.as_deref() != turn_key) {
            return;
        }
        if turn.media.len() >= MEDIA_CAP || turn.media_keys.contains(&image.key) {
            return;
        }
        turn.media_keys.insert(image.key.clone());
        turn.media.push(image.item.clone());
    }

    /// `media({item, key})` with the item's own id as the key.
    pub fn media_item(&mut self, item: Value, key: Option<&str>, turn_key: Option<&str>) {
        let key = key
            .map(str::to_string)
            .or_else(|| item.get("id").and_then(Value::as_str).map(str::to_string))
            .unwrap_or_default();
        self.media(
            &ToolImage {
                item,
                key,
                blob_path: None,
            },
            turn_key,
        );
    }

    /// The harness's end marker. `anchor` makes this record the id of an
    /// empty reply; an interrupt only anchors a turn that has no assistant
    /// item yet. `fallback_text` becomes the reply when there is none.
    /// `error_text` is shown only if the turn still has no reply when it is
    /// emitted; a later assistant item (an automatic retry) drops it.
    pub fn end(
        &mut self,
        id: &str,
        ts: Option<f64>,
        anchor: bool,
        fallback_text: Option<&str>,
        error_text: Option<&str>,
    ) {
        let Some(turn) = self.turns.last_mut() else {
            return;
        };
        turn.ended = true;
        if anchor || turn.last_item.is_none() {
            turn.last_item = Some(Anchor {
                id: id.to_string(),
                ts,
            });
        }
        let fallback = fallback_text.map_or("", trim);
        if turn.reply.is_empty() && !fallback.is_empty() {
            turn.reply.push(fallback.to_string());
            turn.reply_start = Some(Anchor {
                id: id.to_string(),
                ts,
            });
        }
        let error = error_text.map_or("", trim);
        turn.error_text = (!error.is_empty()).then(|| error.to_string());
    }

    /// `end({id, ts})` with the JS defaults (`anchor` true, no texts).
    pub fn end_simple(&mut self, id: &str, ts: Option<f64>) {
        self.end(id, ts, true, None, None);
    }

    /// Emit messages; `status` is the Agent Status, which may complete the
    /// last turn.
    pub fn finish(&self, status: Option<&str>) -> ChatResult<Chat> {
        let mut messages = Vec::new();
        let mut turn_open = false;
        let mut activity = None;
        let completing = matches!(status, Some("idle" | "done"));
        for (index, turn) in self.turns.iter().enumerate() {
            for prompt in &turn.prompts {
                messages.push(make_message(
                    &prompt.id,
                    "user",
                    &prompt.text,
                    prompt.ts,
                    &[],
                )?);
            }
            let last = index == self.turns.len() - 1;
            if last && !turn.ended && (self.run_continues || !completing) {
                turn_open = true;
                activity = Some(clip(
                    turn.activity.as_deref().unwrap_or("Thinking"),
                    ACTIVITY_CAP,
                ));
                continue;
            }
            let joined = turn.reply.join("\n\n");
            let text = if !joined.is_empty() {
                joined
            } else {
                turn.error_text.clone().unwrap_or_default()
            };
            // A turn nobody prompted (a harness notification) shows only a
            // real reply, and so does a slash command the model never
            // answered.
            if text.is_empty()
                && (turn.prompts.is_empty() || (turn.command && turn.last_item.is_none()))
            {
                continue;
            }
            let fallback;
            let anchor = match turn.reply_start.as_ref().or(turn.last_item.as_ref()) {
                Some(anchor) => anchor,
                None => {
                    fallback = Anchor {
                        id: turn.reply_id.clone(),
                        ts: turn.prompts.last().and_then(|p| p.ts),
                    };
                    &fallback
                }
            };
            messages.push(make_message(
                &anchor.id,
                "assistant",
                &text,
                anchor.ts,
                &turn.media,
            )?);
        }
        Ok(Chat {
            messages,
            turn_open,
            activity,
        })
    }

    fn assistant_item(&mut self, id: &str, ts: Option<f64>, turn_key: Option<&str>) -> &mut Turn {
        let needs_new = match self.turns.last() {
            None => true,
            Some(turn) => turn_key.is_some() && turn.turn_key.as_deref() != turn_key,
        };
        if needs_new {
            let seq = self.turns.len();
            self.turns.push(new_turn(seq, turn_key, id.to_string()));
        }
        let turn = self.turns.last_mut().expect("a turn was just ensured");
        turn.ended = false;
        turn.error_text = None;
        turn.last_item = Some(Anchor {
            id: id.to_string(),
            ts,
        });
        turn
    }
}

// MARK: - Activity

/// The status line for a tool call. `name` and `input` are the record's
/// `name` and `input`/`arguments` as found.
pub fn tool_activity(name: &Value, input: &Value) -> String {
    let tool = name.as_str().map_or("", trim);
    let lower = tool.to_lowercase();
    if lower.is_empty() {
        return "Using a tool".into();
    }
    if WEB_TOOLS.contains(&lower.as_str()) || lower.contains("web") {
        return "Searching the web".into();
    }
    if SUBAGENT_TOOLS.contains(&lower.as_str()) {
        return "Running a subagent".into();
    }
    if RUN_TOOLS.contains(&lower.as_str()) {
        return match command_of(input) {
            Some(command) => format!("Running {}", clip(&command, COMMAND_CAP)),
            None => "Running a command".into(),
        };
    }
    if READ_TOOLS.contains(&lower.as_str()) {
        return match path_of(input) {
            Some(file) => clip(
                &format!("Reading {}", jspath::basename(&file)),
                ACTIVITY_CAP,
            ),
            None => "Reading a file".into(),
        };
    }
    if EDIT_TOOLS.contains(&lower.as_str()) {
        return clip(&format!("Editing {}", edit_target(input)), ACTIVITY_CAP);
    }
    if SEARCH_TOOLS.contains(&lower.as_str()) || lower.contains("search") {
        return "Searching".into();
    }
    clip(&format!("Using {tool}"), ACTIVITY_CAP)
}

/// `/^-\w*c$/` with JS's ASCII `\w`.
fn is_shell_command_flag(flag: &str) -> bool {
    flag.len() >= 2
        && flag.starts_with('-')
        && flag.ends_with('c')
        && flag[1..]
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_')
}

fn command_of(input: &Value) -> Option<String> {
    let mut command: &Value = input;
    let joined;
    if let Value::Object(map) = input {
        // `input.command ?? input.cmd ?? input.CommandLine ?? input.commands`
        command = ["command", "cmd", "CommandLine", "commands"]
            .iter()
            .filter_map(|key| map.get(*key))
            .find(|v| !v.is_null())
            .unwrap_or(&Value::Null);
    }
    let text = match command {
        Value::Array(items) => {
            let parts: Vec<&str> = items.iter().filter_map(Value::as_str).collect();
            joined = if parts.len() >= 3
                && SHELLS.contains(&parts[0])
                && is_shell_command_flag(parts[1])
            {
                parts[parts.len() - 1].to_string()
            } else {
                parts.join(" ")
            };
            joined.as_str()
        }
        Value::String(s) => s.as_str(),
        _ => return None,
    };
    let line = first_line(text);
    if line.is_empty() {
        return None;
    }
    Some(collapse_space(&line))
}

/// `text.replace(/\s+/g, " ")`.
pub fn collapse_space(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut in_space = false;
    for c in text.chars() {
        if jsx::is_js_space(c) {
            if !in_space {
                out.push(' ');
            }
            in_space = true;
        } else {
            out.push(c);
            in_space = false;
        }
    }
    out
}

fn path_of(input: &Value) -> Option<String> {
    if !input.is_object() {
        return None;
    }
    ["path", "file_path", "filePath", "notebook_path"]
        .iter()
        .filter_map(|key| field(input, key).as_str())
        .map(trim)
        .find(|s| !s.is_empty())
        .map(str::to_string)
}

/// The one edited file's basename, or "files".
fn edit_target(input: &Value) -> String {
    if let Some(direct) = path_of(input) {
        return jspath::basename(&direct).to_string();
    }
    let patch = match input {
        Value::String(s) => s.as_str(),
        _ => ["input", "patch"]
            .iter()
            .filter_map(|key| field(input, key).as_str())
            .next()
            .unwrap_or(""),
    };
    // Distinct files in first-seen order (a Set).
    let mut files: Vec<String> = Vec::new();
    let mut add = |file: String| {
        if !files.contains(&file) {
            files.push(file);
        }
    };
    for file in patch_headers(patch) {
        add(file);
    }
    for file in hashline_headers(patch) {
        add(file);
    }
    if let Some(edits) = field(input, "edits").as_array() {
        for edit in edits {
            if let Some(file) = path_of(edit) {
                add(file);
            }
        }
    }
    if files.len() == 1 {
        jspath::basename(&files[0]).to_string()
    } else {
        "files".into()
    }
}

fn is_line_terminator(c: char) -> bool {
    matches!(c, '\n' | '\r' | '\u{2028}' | '\u{2029}')
}

/// `^\*\*\* (?:Update|Add|Delete) File: (.+)$` over every line (flag m).
fn patch_headers(patch: &str) -> Vec<String> {
    let mut found = Vec::new();
    for line in patch.split(is_line_terminator) {
        let Some(rest) = line.strip_prefix("*** ") else {
            continue;
        };
        let Some(rest) = ["Update", "Add", "Delete"]
            .iter()
            .find_map(|verb| rest.strip_prefix(verb))
        else {
            continue;
        };
        let Some(name) = rest.strip_prefix(" File: ") else {
            continue;
        };
        if !name.is_empty() {
            found.push(trim(name).to_string());
        }
    }
    found
}

/// `^\[([^\]\n#]+)#[0-9A-Fa-f]{4}\]` at every line start (flag m).
fn hashline_headers(patch: &str) -> Vec<String> {
    let mut found = Vec::new();
    let mut starts = vec![0usize];
    for (index, c) in patch.char_indices() {
        if is_line_terminator(c) {
            starts.push(index + c.len_utf8());
        }
    }
    for start in starts {
        let Some(rest) = patch[start..].strip_prefix('[') else {
            continue;
        };
        let Some(end) = rest.find([']', '\n', '#']) else {
            continue;
        };
        if end == 0 || !rest[end..].starts_with('#') {
            continue;
        }
        let after = &rest[end + 1..];
        let bytes = after.as_bytes();
        if bytes.len() >= 5 && bytes[..4].iter().all(u8::is_ascii_hexdigit) && bytes[4] == b']' {
            found.push(trim(&rest[..end]).to_string());
        }
    }
    found
}

// MARK: - Transcript location

/// A file's `{mtimeMs, birthtimeMs}`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FileStat {
    pub mtime_ms: f64,
    pub birthtime_ms: f64,
}

/// What a transcript's header records: `{cwd, created}`.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Found {
    pub cwd: Option<String>,
    /// Epoch ms; None when the file records no time (its own time counts).
    pub created: Option<f64>,
}

/// `statFile`: the stat of a regular file, else None.
pub fn stat_file(file: &str) -> Option<FileStat> {
    let meta = fs::metadata(file).ok().filter(fs::Metadata::is_file)?;
    let ms = |sec: i64, nsec: i64| sec as f64 * 1e3 + nsec as f64 / 1e6;
    let birth = meta
        .created()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map_or(0.0, |d| d.as_secs_f64() * 1e3);
    Some(FileStat {
        mtime_ms: ms(meta.mtime(), meta.mtime_nsec()),
        birthtime_ms: birth,
    })
}

/// `cwdMatches(found, wanted)`.
pub type CwdMatches<'a> = dyn Fn(&Found, &HashSet<String>) -> bool + 'a;
/// `stat(entry)`.
pub type StatFn<'a> = dyn Fn(&str) -> Option<FileStat> + 'a;

/// `pickByLaunch`'s arguments.
pub struct PickArgs<'a> {
    pub files: &'a [String],
    /// A file's `{cwd, created}`, or None for a file that is never an
    /// Agent's (a subagent's).
    pub probe: &'a dyn Fn(&str) -> ChatResult<Option<Found>>,
    pub cwd: Option<&'a str>,
    /// The launch time in epoch ms (see [`launched_ms`]).
    pub launched_at: Option<f64>,
    pub home: &'a str,
    /// A file that records a start more than 2 minutes after the launch
    /// never matches.
    pub window: bool,
    /// Replaces the cwd comparison for a harness that records the cwd only
    /// in another form: `(found, wanted path forms)`.
    pub cwd_matches: Option<&'a CwdMatches<'a>>,
    /// Replaces the file stat for entries that are no files (an exported
    /// kind's session ids).
    pub stat: Option<&'a StatFn<'a>>,
}

/// `launchedAt instanceof Date ? getTime : Date.parse(launchedAt)` for a JSON
/// value: strings and numbers parse through `Date.parse(String(v))`.
pub fn launched_ms(value: &Value) -> Option<f64> {
    match value {
        Value::String(s) => jsx::date_parse(s),
        Value::Number(n) => jsx::date_parse(&jsx::number_to_string(jsx::json_f64(n))),
        _ => None,
    }
}

/// No session recorded: among `files` whose recorded cwd is `cwd` and that
/// were created no earlier than 10 s before the launch, the one created
/// closest to the launch, so a conversation another Agent starts later in
/// the same cwd does not take over. Ties go to the earlier one.
pub fn pick_by_launch(args: &PickArgs<'_>) -> ChatResult<Option<String>> {
    let (Some(cwd), Some(launched)) = (args.cwd.filter(|c| !c.is_empty()), args.launched_at) else {
        return Ok(None);
    };
    if !launched.is_finite() {
        return Ok(None);
    }
    let threshold = launched - LAUNCH_SLACK_MS;
    let wanted = path_forms(&expand_home(cwd, args.home));

    struct Candidate<'f> {
        file: &'f str,
        created: f64,
        distance: f64,
        mtime_ms: f64,
    }
    let mut best: Option<Candidate<'_>> = None;
    for file in args.files {
        let info = match args.stat {
            Some(stat) => stat(file),
            None => stat_file(file),
        };
        // A file created after the threshold was also last written after it.
        let Some(info) = info.filter(|i| i.mtime_ms >= threshold) else {
            continue;
        };
        let Some(found) = (args.probe)(file)? else {
            continue;
        };
        let created = found.created.unwrap_or(if info.birthtime_ms != 0.0 {
            info.birthtime_ms
        } else {
            info.mtime_ms
        });
        if created < threshold {
            continue;
        }
        if args.window && found.created.is_some() && created > launched + LAUNCH_WINDOW_MS {
            continue;
        }
        let matches = match args.cwd_matches {
            Some(matches) => matches(&found, &wanted),
            None => match found.cwd.as_deref() {
                Some(found_cwd) => path_forms(found_cwd)
                    .iter()
                    .any(|form| wanted.contains(form)),
                None => false,
            },
        };
        if !matches {
            continue;
        }
        let candidate = Candidate {
            file,
            created,
            distance: (created - launched).abs(),
            mtime_ms: info.mtime_ms,
        };
        let closer = match &best {
            None => true,
            Some(b) => closer_to_launch(
                (
                    candidate.distance,
                    candidate.created,
                    candidate.mtime_ms,
                    candidate.file,
                ),
                (b.distance, b.created, b.mtime_ms, b.file),
            ),
        };
        if closer {
            best = Some(candidate);
        }
    }
    Ok(best.map(|b| b.file.to_string()))
}

/// Closest creation to the launch, then the earlier creation, then the
/// earlier write, then a stable order (`a.file < b.file` on UTF-16 units).
fn closer_to_launch(a: (f64, f64, f64, &str), b: (f64, f64, f64, &str)) -> bool {
    if a.0 != b.0 {
        return a.0 < b.0;
    }
    if a.1 != b.1 {
        return a.1 < b.1;
    }
    if a.2 != b.2 {
        return a.2 < b.2;
    }
    a.3.encode_utf16().lt(b.3.encode_utf16())
}

/// The newest of `files` by modification time, or None.
pub fn newest_file(files: &[String]) -> Option<String> {
    let mut best: Option<(&String, f64)> = None;
    for file in files {
        if let Some(info) = stat_file(file)
            && best.is_none_or(|(_, mtime)| info.mtime_ms > mtime)
        {
            best = Some((file, info.mtime_ms));
        }
    }
    best.map(|(file, _)| file.clone())
}

/// A session id or file name that can name no path outside its directory.
pub fn safe_name(value: &str) -> bool {
    !value.is_empty() && value != "." && value != ".." && !value.contains(['/', '\\', '\0'])
}

// MARK: - Files

/// The resolved form of `dir`, plus its real path when it exists.
pub fn path_forms(dir: &str) -> HashSet<String> {
    let mut forms = HashSet::new();
    forms.insert(jspath::resolve(&[dir]));
    if let Ok(real) = fs::canonicalize(dir) {
        forms.insert(jspath::text(&real));
    }
    forms
}

/// Names in a directory in Node's order: libuv's scandir sorts bytewise. An
/// unreadable directory has none.
pub fn list_names(dir: &str) -> Vec<String> {
    let Ok(entries) = fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut names: Vec<String> = entries
        .filter_map(Result::ok)
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .collect();
    names.sort_by(|a, b| a.as_bytes().cmp(b.as_bytes()));
    names
}

/// `readdir(dir, {withFileTypes})` entries, sorted like [`list_names`]:
/// `(name, is_dir, is_file)` by the entry's own type (a symlink is neither).
fn typed_entries(dir: &str) -> Option<Vec<(String, bool, bool)>> {
    let entries = fs::read_dir(dir).ok()?;
    let mut out: Vec<(String, bool, bool)> = entries
        .filter_map(Result::ok)
        .map(|entry| {
            let kind = entry.file_type().ok();
            (
                entry.file_name().to_string_lossy().into_owned(),
                kind.is_some_and(|k| k.is_dir()),
                kind.is_some_and(|k| k.is_file()),
            )
        })
        .collect();
    out.sort_by(|a, b| a.0.as_bytes().cmp(b.0.as_bytes()));
    Some(out)
}

/// Child directories of `dir` (symlinks are not directories here).
pub fn subdirectories(dir: &str) -> Vec<String> {
    typed_entries(dir)
        .unwrap_or_default()
        .into_iter()
        .filter(|(_, is_dir, _)| *is_dir)
        .map(|(name, _, _)| jspath::join(&[dir, &name]))
        .collect()
}

/// Files under `dir`, recursively, whose name `matches`.
pub fn walk_files(dir: &str, matches: &dyn Fn(&str) -> bool) -> Vec<String> {
    let mut found = Vec::new();
    let Some(entries) = typed_entries(dir) else {
        return found;
    };
    for (name, is_dir, is_file) in entries {
        let full = jspath::join(&[dir, &name]);
        if is_dir {
            found.extend(walk_files(&full, matches));
        } else if is_file && matches(&name) {
            found.push(full);
        }
    }
    found
}

/// `~` and `~/x` against `home`.
pub fn expand_home(value: &str, home: &str) -> String {
    if value == "~" {
        return home.to_string();
    }
    match value.strip_prefix("~/") {
        Some(rest) => jspath::join(&[home, rest]),
        None => value.to_string(),
    }
}

// MARK: - Reading

/// One parseable JSON object line: its value, 1-based line number and the
/// byte offset where the line starts.
#[derive(Debug, Clone)]
pub struct Record {
    pub record: Value,
    pub line: usize,
    pub offset: u64,
}

/// Each parseable JSON object line of `file` with its line number and byte
/// offset. Lines split on the raw bytes, so offsets stay exact for any UTF-8
/// content; a trailing `\r` is dropped. Lines that are not JSON objects are
/// skipped. When `signal` fires the read stops with its reason.
pub struct Records<'a> {
    reader: BufReader<fs::File>,
    signal: Option<&'a AbortSignal>,
    line: usize,
    offset: u64,
    failed: bool,
}

pub fn read_records<'a>(file: &str, signal: Option<&'a AbortSignal>) -> ChatResult<Records<'a>> {
    check_abort(signal)?;
    let handle = fs::File::open(file).map_err(|e| ChatError::io(&e, "open", file))?;
    Ok(Records {
        reader: BufReader::with_capacity(64 * 1024, handle),
        signal,
        line: 0,
        offset: 0,
        failed: false,
    })
}

impl Iterator for Records<'_> {
    type Item = ChatResult<Record>;

    fn next(&mut self) -> Option<Self::Item> {
        if self.failed {
            return None;
        }
        let mut bytes = Vec::new();
        loop {
            if let Err(error) = check_abort(self.signal) {
                self.failed = true;
                return Some(Err(error));
            }
            bytes.clear();
            match self.reader.read_until(b'\n', &mut bytes) {
                Ok(0) => return None,
                Ok(read) => {
                    self.line += 1;
                    let start = self.offset;
                    self.offset += read as u64;
                    if bytes.last() == Some(&b'\n') {
                        bytes.pop();
                    }
                    if bytes.last() == Some(&b'\r') {
                        bytes.pop();
                    }
                    let text = String::from_utf8_lossy(&bytes);
                    if let Some(record) = parse_json_object(&text) {
                        return Some(Ok(Record {
                            record,
                            line: self.line,
                            offset: start,
                        }));
                    }
                }
                Err(error) => {
                    self.failed = true;
                    return Some(Err(ChatError::io(&error, "read", "")));
                }
            }
        }
    }
}

/// `parseJSONObject`: the object `text` holds, else None.
pub fn parse_json_object(text: &str) -> Option<Value> {
    if trim(text).is_empty() {
        return None;
    }
    jsx::parse_json(text).filter(Value::is_object)
}

/// A transcript that is one JSON document, parsed whole; an error for a file
/// that is not one.
pub fn read_json_document(file: &str) -> ChatResult<Value> {
    let meta = fs::metadata(file).map_err(|e| ChatError::io(&e, "stat", file))?;
    if !meta.is_file() {
        return Err(ChatError::other(format!("not a file: {file}")));
    }
    if meta.len() > MAX_DOCUMENT_BYTES {
        return Err(ChatError::other(format!(
            "transcript over {} MiB: {file}",
            MAX_DOCUMENT_BYTES / (1024 * 1024)
        )));
    }
    let bytes = fs::read(file).map_err(|e| ChatError::io(&e, "open", file))?;
    parse_json_object(&String::from_utf8_lossy(&bytes))
        .ok_or_else(|| ChatError::other(format!("not a JSON object: {file}")))
}

// MARK: - Text

/// The first non-blank line of `text`, trimmed and clipped to the activity
/// cap, or "". Lines split on `\n` only, as in the JS.
pub fn first_line(text: &str) -> String {
    text.split('\n')
        .find(|candidate| !trim(candidate).is_empty())
        .map_or_else(String::new, |line| clip(trim(line), ACTIVITY_CAP))
}

/// `capText`: at most 20,000 UTF-16 units.
pub fn cap_text(text: &str) -> String {
    clip(text, TEXT_CAP)
}

/// `truthy(field(...))` shorthand the readers use as `if (x)`.
pub fn is_set(value: &Value) -> bool {
    truthy(value)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn texts(chat: &Chat) -> Vec<(String, String)> {
        chat.messages
            .iter()
            .map(|m| {
                (
                    m["role"].as_str().unwrap().to_string(),
                    m["text"].as_str().unwrap().to_string(),
                )
            })
            .collect()
    }

    fn prompt<'a>(turns: &mut ChatTurns, id: &'a str, text: &'a str) {
        turns.prompt(Prompt {
            id,
            text,
            ts: parse_time(&json!("2026-09-30T12:00:00.000Z")),
            ..Prompt::default()
        });
    }

    #[test]
    fn the_reply_is_the_text_after_the_last_tool_call() {
        let mut turns = ChatTurns::new();
        prompt(&mut turns, "u1", "fix it");
        turns.text_str("a1", None, "Let me look.", None);
        turns.tool(ToolCall {
            id: "a2",
            activity: tool_activity(&json!("Bash"), &json!({"command": "npm test\nmore"})),
            ..ToolCall::default()
        });
        turns.text_str("a3", None, "Fixed.", None);
        turns.end_simple("a3", None);
        let chat = turns.finish(None).unwrap();
        assert_eq!(
            texts(&chat),
            vec![
                ("user".into(), "fix it".into()),
                ("assistant".into(), "Fixed.".into())
            ]
        );
        assert!(!chat.turn_open);
        assert_eq!(chat.messages[0]["ts"], json!("2026-09-30T12:00:00.000Z"));
    }

    #[test]
    fn an_open_turn_reports_its_activity_until_the_status_completes_it() {
        let mut turns = ChatTurns::new();
        prompt(&mut turns, "u1", "go");
        turns.tool(ToolCall {
            id: "a1",
            activity: "Running npm test".into(),
            ..ToolCall::default()
        });
        let open = turns.finish(Some("working")).unwrap();
        assert!(open.turn_open);
        assert_eq!(open.activity.as_deref(), Some("Running npm test"));
        assert!(!turns.finish(Some("idle")).unwrap().turn_open);
        turns.run_continues = true;
        assert!(turns.finish(Some("done")).unwrap().turn_open);
    }

    #[test]
    fn tool_activity_names_what_the_tool_does() {
        let cmd = |name: &str, input: Value| tool_activity(&json!(name), &input);
        assert_eq!(
            cmd("Bash", json!({"command": "  npm   run\tbuild "})),
            "Running npm run build"
        );
        assert_eq!(
            cmd("exec_command", json!({"cmd": ["bash", "-lc", "npm test"]})),
            "Running npm test"
        );
        assert_eq!(
            cmd("Read", json!({"file_path": "/a/b/c.rs"})),
            "Reading c.rs"
        );
        assert_eq!(cmd("Read", json!({})), "Reading a file");
        assert_eq!(cmd("Edit", json!({"file_path": "/x/y.js"})), "Editing y.js");
        assert_eq!(
            cmd(
                "apply_patch",
                json!("*** Update File: a/b.txt\n*** Add File: a/c.txt")
            ),
            "Editing files"
        );
        assert_eq!(
            cmd("apply_patch", json!({"input": "*** Update File: a/b.txt"})),
            "Editing b.txt"
        );
        assert_eq!(cmd("WebFetch", json!({})), "Searching the web");
        assert_eq!(cmd("Task", json!({})), "Running a subagent");
        assert_eq!(cmd("grep", json!({})), "Searching");
        assert_eq!(cmd("Weird", json!({})), "Using Weird");
        assert_eq!(tool_activity(&Value::Null, &Value::Null), "Using a tool");
    }

    #[test]
    fn tool_images_name_blobs_and_inline_data() {
        let sha = "a".repeat(64);
        let blob = tool_image(
            &json!(format!("blob:sha256:{sha}")),
            &Value::Null,
            "/t.jsonl",
            0,
            "p",
            "/root",
        )
        .unwrap();
        assert_eq!(
            blob.blob_path.as_deref(),
            Some(format!("/root/blobs/{sha}").as_str())
        );
        let inline = tool_image(
            &json!("data:image/png;base64,iVBORw0KGgoAAAA"),
            &Value::Null,
            "/t.jsonl",
            12,
            "/message/content/0",
            "/root",
        )
        .unwrap();
        assert_eq!(inline.item["id"], json!("inline:12:/message/content/0"));
        assert_eq!(inline.item["mime"], json!("image/png"));
        assert!(inline.key.starts_with("sha256:"));
        let sniffed = tool_image(&json!("/9j/4AAQ"), &Value::Null, "/t", 1, "p", "/r").unwrap();
        assert_eq!(sniffed.item["mime"], json!("image/jpeg"));
        assert!(
            tool_image(
                &json!("data:text/plain,hi"),
                &Value::Null,
                "/t",
                1,
                "p",
                "/r"
            )
            .is_none()
        );
        assert!(tool_image(&json!(""), &Value::Null, "/t", 1, "p", "/r").is_none());
    }

    #[test]
    fn records_carry_line_and_byte_offsets() {
        let dir = std::env::temp_dir().join(format!("wc-chat-shared-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let file = jspath::text(&dir.join("t.jsonl"));
        fs::write(&file, "{\"a\":1}\r\nnot json\n[1]\n{\"é\":2}").unwrap();
        let records: Vec<Record> = read_records(&file, None)
            .unwrap()
            .map(Result::unwrap)
            .collect();
        assert_eq!(records.len(), 2);
        assert_eq!((records[0].line, records[0].offset), (1, 0));
        assert_eq!((records[1].line, records[1].offset), (4, 22));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn io_errors_read_like_nodes() {
        let error = read_records("/nonexistent/x.jsonl", None).err().unwrap();
        assert!(error.is_missing());
        assert_eq!(
            error.message,
            "ENOENT: no such file or directory, open '/nonexistent/x.jsonl'"
        );
        let error = ChatError::io(&io::Error::from_raw_os_error(21), "read", "");
        assert_eq!(
            error.message,
            "EISDIR: illegal operation on a directory, read"
        );
    }
}
