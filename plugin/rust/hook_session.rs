//! Payload-aware hook for Waycar's tmux backend (hook-session.js):
//! `waycar hook-session <agent> [<event>]` with the event JSON on stdin.
//! `<event>` defaults to `SessionStart`.
//!
//! bin/waycar-hook handles events whose status the event name alone decides;
//! this one handles the ones whose payload matters. It records the session on
//! the agent's tmux pane as pane options the app reads:
//!
//! * `@waycar_agent`: the agent kind
//! * `@waycar_session`: the session id
//! * `@waycar_transcript`: the transcript path, percent-encoded
//!
//! and applies a status the payload decides (`@waycar_status`, raising
//! `@waycar_seq`), with waycar-hook's conditional statuses, or releases the
//! pane (unsets every `@waycar_*` option). Per agent and event, see
//! [`hook_update`]; the facts behind each are in docs/research/harnesses/.
//!
//! Like bin/waycar-hook it does nothing when `HERDR_PANE_ID` or `HERDR_ENV`
//! is set (herdr owns that pane's status) or `WAYCAR_SUMMARY` is set (an
//! Agent Summary's one-shot harness), and nothing unless `$TMUX_PANE` is set
//! and the agent's controlling tty is that pane's tty: `$CLAUDE_PID`'s for
//! claude, else the hook's parent's, else (never for codex or cline, whose
//! shared daemons have none) its grandparent's when the parent has none. Muse
//! clears the environment its hooks run in, so for muse the tmux and herdr
//! variables come from the agent's own environment ([`muse_environment`]). It
//! always exits 0 and never writes to stdout.
//!
//! The JS asked `ps` for a process's tty, parent and command line. On Linux
//! this reads `/proc` instead (`ps` is missing on Debian slim and Alpine) and
//! answers what procps' `ps -o tty=|ppid=|args=` prints; macOS keeps `ps`.
//!
//! Known differences from the JS, none reachable from a real agent payload:
//! the payload parser is serde_json, so a number outside the double range
//! (`1e999`, Infinity in JS) or nesting deeper than 128 levels is an
//! unparseable payload (the hook does nothing); lone-surrogate escapes in a
//! string parse, as in JS, and become U+FFFD, which is what Node writes out
//! for them.

use std::borrow::Cow;
use std::io::Read;
use std::path::Path;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{Map, Value};

use crate::env::Env;
use crate::exec::run_program_with_timeout;

pub const AGENTS: [&str; 13] = [
    "claude", "codex", "copilot", "qwen", "gemini", "grok", "agy", "hermes", "cline", "cursor",
    "devin", "kiro", "muse",
];
const OPTIONS: [&str; 5] = [
    "@waycar_status",
    "@waycar_seq",
    "@waycar_agent",
    "@waycar_session",
    "@waycar_transcript",
];
const TMUX_TIMEOUT: Duration = Duration::from_millis(2000);

/// Env set by the agents that also run `~/.claude/settings.json` hooks
/// (grok.md, copilot.md, cursor.md, devin.md).
const CLAUDE_FOREIGN_ENV: [&str; 5] = [
    "GROK_HOOK_EVENT",
    "GROK_SESSION_ID",
    "CURSOR_VERSION",
    "DEVIN_PROJECT_DIR",
    "COPILOT_CLI",
];

/// What one hook event does to the pane.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HookUpdate {
    /// Pane options to set, in order.
    pub options: Vec<(&'static str, String)>,
    /// A status or conditional status (see bin/waycar-hook); see [`next_status`].
    pub status: Option<&'static str>,
    /// Unset every `@waycar_*` option, but only when `session_id` is the
    /// pane's session or the pane records none (Copilot fires a stray
    /// SessionEnd for another session on resume).
    pub release: bool,
    pub session_id: Option<String>,
}

/// SessionStart `source` values that (re)open the pane's session at the prompt.
fn idle_sources(agent: &str) -> &'static [&'static str] {
    match agent {
        "claude" => &["startup", "resume", "clear", "fork"],
        "qwen" | "gemini" => &["startup", "resume"],
        "grok" => &["new", "load"],
        _ => &[],
    }
}

/// Percent-encode a path for `@waycar_transcript`: every UTF-8 byte outside
/// `A-Z a-z 0-9 - . _ ~ /` becomes `%XX` (uppercase hex), so tabs, newlines
/// and the app's field separators never reach a tmux format.
pub fn percent_encode_path(path: &str) -> String {
    const HEX: &[u8; 16] = b"0123456789ABCDEF";
    let mut out = String::with_capacity(path.len());
    for &byte in path.as_bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~' | b'/') {
            out.push(char::from(byte));
        } else {
            out.push('%');
            out.push(char::from(HEX[usize::from(byte >> 4)]));
            out.push(char::from(HEX[usize::from(byte & 15)]));
        }
    }
    out
}

/// The inverse of [`percent_encode_path`]; core labels hold the path itself,
/// as nothing there splits on tabs or newlines. `None` for text that is not
/// what the encoder prints.
pub(crate) fn percent_decode_path(encoded: &str) -> Option<String> {
    let bytes = encoded.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut at = 0;
    while at < bytes.len() {
        if bytes[at] == b'%' {
            let digits = encoded.get(at + 1..at + 3)?;
            out.push(u8::from_str_radix(digits, 16).ok()?);
            at += 3;
        } else {
            out.push(bytes[at]);
            at += 1;
        }
    }
    String::from_utf8(out).ok()
}

/// A string that is not empty (`typeof value === "string" && value`).
fn text(value: Option<&Value>) -> Option<String> {
    value
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

/// JavaScript truthiness of an absent or parsed JSON value.
fn truthy(value: Option<&Value>) -> bool {
    match value {
        None | Some(Value::Null) | Some(Value::Bool(false)) => false,
        Some(Value::String(s)) => !s.is_empty(),
        Some(Value::Number(n)) => n.as_f64().is_some_and(|f| f != 0.0 && !f.is_nan()),
        Some(_) => true,
    }
}

/// An environment variable that is set and not empty (`env.NAME` truthy).
fn env_text(env: &Env, name: &str) -> Option<String> {
    env.non_empty(name).map(str::to_string)
}

/// Pane options recording a session: the agent, and the id and transcript
/// when known.
fn session(
    agent: &'static str,
    id: Option<String>,
    transcript: Option<String>,
) -> Vec<(&'static str, String)> {
    let mut options = vec![("@waycar_agent", agent.to_string())];
    if let Some(id) = id {
        options.push(("@waycar_session", id));
    }
    if let Some(transcript) = transcript {
        options.push(("@waycar_transcript", percent_encode_path(&transcript)));
    }
    options
}

/// Whether a claude hook is really another agent running Claude's settings,
/// or not claude at all.
fn is_foreign_claude_hook(input: &Map<String, Value>, env: &Env) -> bool {
    if CLAUDE_FOREIGN_ENV
        .iter()
        .any(|name| env.non_empty(name).is_some())
    {
        return true;
    }
    if env.get("CLAUDECODE") != Some("1") {
        return true;
    }
    input.contains_key("hookEventName") || input.contains_key("cursor_version")
}

/// `path.dirname` (posix), exactly as Node cuts it.
fn posix_dirname(path: &str) -> String {
    let bytes = path.as_bytes();
    if bytes.is_empty() {
        return ".".to_string();
    }
    let has_root = bytes[0] == b'/';
    let mut end = None;
    let mut matched_slash = true;
    for at in (1..bytes.len()).rev() {
        if bytes[at] == b'/' {
            if !matched_slash {
                end = Some(at);
                break;
            }
        } else {
            matched_slash = false;
        }
    }
    match end {
        None if has_root => "/".to_string(),
        None => ".".to_string(),
        Some(1) if has_root => "//".to_string(),
        Some(end) => path[..end].to_string(),
    }
}

/// `path.posix.join`: the non-empty parts joined by `/`, then normalized (a
/// later absolute part does not restart the path).
fn join(parts: &[&str]) -> String {
    let joined = parts
        .iter()
        .copied()
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>()
        .join("/");
    if joined.is_empty() {
        return ".".to_string();
    }
    let absolute = joined.starts_with('/');
    let trailing = joined.ends_with('/');
    let mut stack: Vec<&str> = Vec::new();
    for segment in joined.split('/') {
        match segment {
            "" | "." => {}
            ".." => {
                if stack.last().is_some_and(|last| *last != "..") {
                    stack.pop();
                } else if !absolute {
                    stack.push("..");
                }
            }
            other => stack.push(other),
        }
    }
    let mut path = stack.join("/");
    if path.is_empty() {
        return match (absolute, trailing) {
            (true, _) => "/",
            (false, true) => "./",
            (false, false) => ".",
        }
        .to_string();
    }
    if trailing {
        path.push('/');
    }
    if absolute { format!("/{path}") } else { path }
}

/// `string.slice(0, 8)` counted in UTF-16 units; `None` when the cut would
/// split a surrogate pair (the JS then holds a lone surrogate no file name
/// can end with).
fn utf16_prefix(value: &str, units: usize) -> Option<&str> {
    let mut count = 0;
    for (at, ch) in value.char_indices() {
        if count + ch.len_utf16() > units {
            return if count == units {
                Some(&value[..at])
            } else {
                None
            };
        }
        count += ch.len_utf16();
    }
    Some(value)
}

/// Gemini's transcript: a resumed session's SessionStart names a file that
/// Gemini never creates and keeps writing `session-<time>-<first 8 of id>.jsonl`
/// (gemini.md), so an absent path falls back to the existing file of this
/// session in the same directory, else none (BeforeAgent records it later).
fn gemini_transcript(path: Option<String>, session_id: Option<&str>) -> Option<String> {
    let path = path?;
    if Path::new(&path).exists() {
        return Some(path);
    }
    let prefix = utf16_prefix(session_id?, 8);
    let suffix = format!("-{}.jsonl", prefix?);
    let dir = posix_dirname(&path);
    let mut found: Vec<String> = std::fs::read_dir(&dir)
        .ok()?
        .filter_map(|entry| entry.ok())
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .filter(|name| name.starts_with("session-") && name.ends_with(&suffix))
        .collect();
    // Array#sort compares UTF-16 code units.
    found.sort_by(|a, b| a.encode_utf16().cmp(b.encode_utf16()));
    found.first().map(|name| join(&[&dir, name]))
}

/// What one hook event does to the pane, or `None` when it does nothing.
/// `home` is the account's home (`env.HOME ?? ""` in the hook).
pub fn hook_update(
    agent: &str,
    event: &str,
    input: &Value,
    env: &Env,
    home: &str,
) -> Option<HookUpdate> {
    let input = input.as_object()?;
    let agent_kind: &'static str = AGENTS.iter().copied().find(|known| *known == agent)?;
    let update = |options, status| {
        Some(HookUpdate {
            options,
            status,
            release: false,
            session_id: None,
        })
    };
    let release = |session_id| {
        Some(HookUpdate {
            options: Vec::new(),
            status: None,
            release: true,
            session_id,
        })
    };
    let start_status = |source: Option<&Value>| {
        source
            .and_then(Value::as_str)
            .filter(|source| idle_sources(agent).contains(source))
            .map(|_| "idle")
    };
    let get = |key: &str| input.get(key);

    match (agent, event) {
        ("claude", "SessionStart") => {
            if truthy(get("agent_id")) || is_foreign_claude_hook(input, env) {
                return None;
            }
            update(
                session(
                    agent_kind,
                    text(get("session_id")),
                    text(get("transcript_path")),
                ),
                start_status(get("source")),
            )
        }
        ("codex", "SessionStart") => {
            let id = text(get("session_id"));
            // A Codex started from another Codex's shell inherits its thread id.
            if let Some(thread) = env.non_empty("CODEX_THREAD_ID")
                && id.as_deref() != Some(thread)
            {
                return None;
            }
            update(session(agent_kind, id, text(get("transcript_path"))), None)
        }
        ("qwen", "SessionStart") => {
            if truthy(get("agent_id")) {
                return None;
            }
            update(
                session(
                    agent_kind,
                    text(get("session_id")),
                    text(get("transcript_path")),
                ),
                start_status(get("source")),
            )
        }
        ("devin" | "kiro", "SessionStart") => update(
            session(
                agent_kind,
                text(get("session_id")),
                text(get("transcript_path")),
            ),
            None,
        ),
        ("cursor", "sessionStart") => {
            if env.non_empty("GROK_HOOK_EVENT").is_some()
                || env.non_empty("GROK_SESSION_ID").is_some()
                || input.contains_key("hookEventName")
            {
                return None;
            }
            if env.non_empty("CURSOR_VERSION").is_none() && !truthy(get("cursor_version")) {
                return None;
            }
            let id = text(get("session_id")).or_else(|| text(get("conversation_id")));
            update(session(agent_kind, id, text(get("transcript_path"))), None)
        }
        ("copilot", "SessionStart") => {
            // Copilot's SessionStart comes after the first prompt's
            // UserPromptSubmit, without a transcript path; the transcript is
            // the session's events.jsonl. Some PascalCase events still get
            // camelCase bodies (copilot.md).
            let id = text(get("session_id")).or_else(|| text(get("sessionId")))?;
            let transcript = text(get("transcript_path")).unwrap_or_else(|| {
                let base = env
                    .non_empty("COPILOT_HOME")
                    .map_or_else(|| join(&[home, ".copilot"]), str::to_string);
                join(&[&base, "session-state", &id, "events.jsonl"])
            });
            update(session(agent_kind, Some(id), Some(transcript)), None)
        }
        ("copilot", "Notification") => {
            let prompt = |key: &str| get(key).and_then(Value::as_str) == Some("permission_prompt");
            if prompt("notification_type") || prompt("notificationType") {
                update(Vec::new(), Some("blocked"))
            } else {
                None
            }
        }
        ("copilot", "SessionEnd") => {
            release(text(get("session_id")).or_else(|| text(get("sessionId"))))
        }
        ("gemini", "SessionStart") => {
            let id = text(get("session_id"));
            let transcript = gemini_transcript(text(get("transcript_path")), id.as_deref());
            update(
                session(agent_kind, id, transcript),
                start_status(get("source")),
            )
        }
        ("gemini", "BeforeAgent") => update(
            session(
                agent_kind,
                text(get("session_id")),
                text(get("transcript_path")),
            ),
            Some("working"),
        ),
        ("gemini", "Notification") => {
            if get("notification_type").and_then(Value::as_str) == Some("ToolPermission") {
                update(Vec::new(), Some("blocked"))
            } else {
                None
            }
        }
        ("grok", "SessionStart" | "UserPromptSubmit" | "Notification" | "SessionEnd") => {
            // `notificationType ?? notification_type`
            let kind = match get("notificationType") {
                Some(value) if !value.is_null() => Some(value),
                _ => get("notification_type"),
            };
            let kind = kind.and_then(Value::as_str);
            // A subagent's own events would replace or release the root
            // session, or idle it mid-turn; its approval still blocks the pane.
            if (truthy(get("subagentType")) || truthy(get("subagent_type")))
                && !(event == "Notification" && kind == Some("permission_prompt"))
            {
                return None;
            }
            let id = text(get("sessionId"))
                .or_else(|| text(get("session_id")))
                .or_else(|| env_text(env, "GROK_SESSION_ID"));
            let transcript = text(get("transcriptPath")).or_else(|| text(get("transcript_path")));
            if event == "SessionEnd" {
                return release(id);
            }
            if event == "Notification" {
                return match kind {
                    Some("permission_prompt") => update(Vec::new(), Some("blocked")),
                    Some("idle_prompt") => update(Vec::new(), Some("idle-if-working")),
                    _ => None,
                };
            }
            // SessionStart `source: "new"` carries no transcript path; the
            // first prompt does.
            let status = if event == "SessionStart" {
                start_status(get("source"))
            } else {
                Some("working")
            };
            update(session(agent_kind, id, transcript), status)
        }
        ("agy", "PreInvocation") => {
            let id = text(get("conversationId"))
                .or_else(|| env_text(env, "ANTIGRAVITY_CONVERSATION_ID"));
            update(
                session(agent_kind, id, text(get("transcriptPath"))),
                Some("working"),
            )
        }
        // fullyIdle false: the conversation keeps going (background work).
        ("agy", "Stop") => {
            if get("fullyIdle") == Some(&Value::Bool(true)) {
                update(Vec::new(), Some("done"))
            } else {
                None
            }
        }
        ("hermes", "pre_llm_call") => {
            let id = text(get("session_id")).or_else(|| env_text(env, "HERMES_SESSION_ID"));
            update(session(agent_kind, id, None), Some("working"))
        }
        // Fires at every turn end, Ctrl+C included.
        ("hermes", "on_session_end") => {
            let interrupted = get("extra")
                .and_then(|extra| extra.get("interrupted"))
                .is_some_and(|value| value == &Value::Bool(true));
            update(Vec::new(), Some(if interrupted { "idle" } else { "done" }))
        }
        ("cline", "TaskStart" | "TaskResume") => {
            if truthy(get("parent_agent_id")) {
                return None;
            }
            let id = text(get("sessionContext").and_then(|context| context.get("rootSessionId")));
            let sessions = env.non_empty("CLINE_SESSION_DATA_DIR").map_or_else(
                || join(&[home, ".cline", "data", "sessions"]),
                str::to_string,
            );
            let transcript = id
                .as_deref()
                .map(|id| join(&[&sessions, id, &format!("{id}.messages.json")]));
            update(session(agent_kind, id, transcript), Some("working"))
        }
        // Muse fires no SessionStart on resume, so every prompt records the
        // session; its payloads carry `transcript_path: null` (muse.md).
        ("muse", "UserPromptSubmit") => {
            if truthy(get("agent_id")) {
                return None;
            }
            update(
                session(
                    agent_kind,
                    text(get("session_id")),
                    text(get("transcript_path")),
                ),
                Some("working"),
            )
        }
        _ => None,
    }
}

/// The status a (conditional) status sets from `current`, or `None` for none.
pub fn next_status<'a>(want: &'a str, current: Option<&str>) -> Option<&'a str> {
    let active = matches!(current, Some("working" | "blocked"));
    match want {
        "working-if-active" => active.then_some("working"),
        "working-if-blocked" => (current == Some("blocked")).then_some("working"),
        "idle-if-working" => (current == Some("working")).then_some("idle"),
        "done-if-active" => active.then_some("done"),
        _ => Some(want),
    }
}

/// Wall-clock nanoseconds since the Unix epoch. The JS took the milliseconds
/// and filled the rest with the monotonic clock's sub-millisecond part; the
/// value has the same shape.
pub fn now_ns() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_nanos())
}

/// The next `@waycar_seq`: `now_ns`, never at or below `previous`. A stored
/// seq is any digit string (BigInt in the JS, so no length limit); anything
/// else is ignored.
pub fn next_seq(previous: Option<&str>, now_ns: u128) -> String {
    if let Some(previous) =
        previous.filter(|p| !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit()))
    {
        let digits = previous.trim_start_matches('0');
        let digits = if digits.is_empty() { "0" } else { digits };
        let now = now_ns.to_string();
        let behind =
            now.len() < digits.len() || (now.len() == digits.len() && now.as_str() <= digits);
        if behind {
            return increment_decimal(digits);
        }
        return now;
    }
    now_ns.to_string()
}

/// `digits + 1` for a decimal digit string without leading zeros.
fn increment_decimal(digits: &str) -> String {
    let mut bytes = digits.as_bytes().to_vec();
    for byte in bytes.iter_mut().rev() {
        if *byte == b'9' {
            *byte = b'0';
        } else {
            *byte += 1;
            return String::from_utf8(bytes).unwrap_or_default();
        }
    }
    bytes.insert(0, b'1');
    String::from_utf8(bytes).unwrap_or_default()
}

/// Whether `value` reads as itself inside a tmux format's `#{==:…,value}`:
/// no `#`, `,` or `}` (format syntax), no control character and no line
/// terminator.
fn format_literal(value: &str) -> bool {
    !value.contains(['#', ',', '}'])
        && !value.chars().any(char::is_control)
        && no_line_terminator(value)
}

/// Whether `pane` can sit unquoted in a tmux command string: `%<digits>`.
fn command_target(pane: &str) -> bool {
    pane.strip_prefix('%')
        .is_some_and(|digits| !digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit()))
}

/// tmux splits an argument that ends in an unescaped `;`; `\;` keeps it.
fn tmux_arg(value: &str) -> Cow<'_, str> {
    match value.strip_suffix(';') {
        Some(head) => Cow::Owned(format!("{head}\\;")),
        None => Cow::Borrowed(value),
    }
}

// ---- processes -------------------------------------------------------------

/// A process's controlling tty as `ps -o tty= -p <pid>` prints it (`pts/3`,
/// `ttys021`, `?`, `??`), or "" when there is no such process.
pub fn process_tty(pid: &str, env: &Env) -> String {
    #[cfg(target_os = "linux")]
    {
        let _ = env;
        linux::tty(pid)
    }
    #[cfg(not(target_os = "linux"))]
    {
        ps_field("tty", pid, env)
    }
}

/// A process's parent as `ps -o ppid= -p <pid>` prints it, or "".
pub fn process_ppid(pid: &str, env: &Env) -> String {
    #[cfg(target_os = "linux")]
    {
        let _ = env;
        linux::ppid(pid)
    }
    #[cfg(not(target_os = "linux"))]
    {
        ps_field("ppid", pid, env)
    }
}

/// A process's command line as `ps -ww -o args= -p <pid>` prints it (the
/// arguments joined by single spaces), or `None` when there is no such
/// process.
pub fn process_args(pid: u64, env: &Env) -> Option<String> {
    #[cfg(target_os = "linux")]
    {
        let _ = env;
        linux::args(pid)
    }
    #[cfg(not(target_os = "linux"))]
    {
        let result =
            crate::exec::run_program("ps", &["-ww", "-o", "args=", "-p", &pid.to_string()], env);
        (result.code == 0).then_some(result.stdout)
    }
}

#[cfg(not(target_os = "linux"))]
fn ps_field(field: &str, pid: &str, env: &Env) -> String {
    let result = run_program_with_timeout(
        "ps",
        &["-o", &format!("{field}="), "-p", pid],
        env,
        TMUX_TIMEOUT,
    );
    if result.code == 0 {
        result.stdout.trim().to_string()
    } else {
        String::new()
    }
}

#[cfg(target_os = "linux")]
mod linux {
    use std::os::unix::fs::{FileTypeExt, MetadataExt};

    /// The pid as `ps -p` reads it: a number, leading zeros allowed.
    fn pid_number(pid: &str) -> Option<u64> {
        if pid.is_empty() || !pid.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        pid.parse().ok()
    }

    /// The fields of `/proc/<pid>/stat` after the command name: state, ppid,
    /// pgrp, session, tty_nr, ...
    fn stat_fields(pid: u64) -> Option<Vec<String>> {
        let stat = std::fs::read(format!("/proc/{pid}/stat")).ok()?;
        let stat = String::from_utf8_lossy(&stat);
        // The command name sits in parentheses and may hold anything.
        let after = &stat[stat.rfind(')')? + 1..];
        Some(after.split_whitespace().map(str::to_string).collect())
    }

    pub fn ppid(pid: &str) -> String {
        pid_number(pid)
            .and_then(stat_fields)
            .and_then(|fields| fields.get(1).cloned())
            .unwrap_or_default()
    }

    pub fn tty(pid: &str) -> String {
        let Some(fields) = pid_number(pid).and_then(stat_fields) else {
            return String::new();
        };
        let Some(tty_nr) = fields.get(4).and_then(|f| f.parse::<u64>().ok()) else {
            return String::new();
        };
        if tty_nr == 0 {
            return "?".to_string();
        }
        device_name(
            (tty_nr >> 8) & 0xfff,
            (tty_nr & 0xff) | ((tty_nr >> 12) & 0xfff00),
        )
    }

    /// The device's name the way procps prints it: `pts/N`, `ttyN`, `ttySN`,
    /// the character device found under /dev, else `major,minor`.
    fn device_name(major: u64, minor: u64) -> String {
        match major {
            136..=143 => return format!("pts/{}", (major - 136) * 256 + minor),
            4 if minor < 64 => return format!("tty{minor}"),
            4 => return format!("ttyS{}", minor - 64),
            5 => match minor {
                0 => return "tty".to_string(),
                1 => return "console".to_string(),
                2 => return "ptmx".to_string(),
                _ => {}
            },
            _ => {}
        }
        if let Ok(entries) = std::fs::read_dir("/dev") {
            for entry in entries.filter_map(Result::ok) {
                let Ok(meta) = entry.metadata() else { continue };
                if meta.file_type().is_char_device()
                    && u64::from(libc::major(meta.rdev())) == major
                    && u64::from(libc::minor(meta.rdev())) == minor
                {
                    return entry.file_name().to_string_lossy().into_owned();
                }
            }
        }
        format!("{major},{minor}")
    }

    pub fn args(pid: u64) -> Option<String> {
        let cmdline = std::fs::read(format!("/proc/{pid}/cmdline")).ok()?;
        if cmdline.is_empty() {
            // A kernel thread or a zombie: ps shows `[name]`.
            let stat = std::fs::read(format!("/proc/{pid}/stat")).ok()?;
            let stat = String::from_utf8_lossy(&stat);
            let name = &stat[stat.find('(')? + 1..stat.rfind(')')?];
            return Some(format!("[{name}]"));
        }
        let trimmed = cmdline.strip_suffix(&[0]).unwrap_or(&cmdline);
        let joined: Vec<u8> = trimmed
            .iter()
            .map(|&b| if b == 0 { b' ' } else { b })
            .collect();
        Some(String::from_utf8_lossy(&joined).into_owned())
    }
}

// ---- the hook --------------------------------------------------------------

/// What the hook needs from the system; the tests give it a fake tmux and a
/// process table.
pub trait HookHost {
    /// `tmux <args>` with `env`: its stdout, or `None` when it failed (exit
    /// code, 2 s timeout or not installed).
    fn tmux(&self, args: &[&str], env: &Env) -> Option<String>;
    /// `ps -o tty= -p <pid>`, trimmed; "" when unknown.
    fn tty(&self, pid: &str) -> String;
    /// `ps -o ppid= -p <pid>`, trimmed; "" when unknown.
    fn ppid(&self, pid: &str) -> String;
    /// A process's full command line, or `None` when it is gone.
    fn args(&self, _pid: u32) -> Option<String> {
        None
    }
    /// Record and notify a shared-daemon Codex hook, without touching a pane.
    fn codex_hook(&self, _event: &str, _input: &Value, _env: &Env) {}
    /// Start `waycar notify --pane tmux:<pane> --status <status>` detached,
    /// with `env`, and leave it; a start failure is ignored.
    fn notify(&self, pane: &str, status: &str, env: &Env);
    /// Lossless argv from /proc or macOS KERN_PROCARGS2, not split ps text.
    fn argv(&self, _pid: u32) -> Option<Vec<String>> {
        None
    }
    fn process_env(&self, _pid: u32) -> Option<Env> {
        None
    }
    fn zellij_run(&self, _bin: &str, _args: &[&str], _env: &Env) -> crate::exec::RunResult {
        crate::exec::RunResult {
            stdout: String::new(),
            stderr: String::new(),
            code: 1,
        }
    }
    fn zellij_notify(&self, _pane: &str, _status: &str, _env: &Env) {}
    /// herdr-core, for a host that has it; `None` on one that does not.
    fn core(&self) -> Option<&dyn crate::hook_status::CoreHost> {
        None
    }
}

/// The real tmux, `/proc` (or `ps`) and `waycar notify`.
pub struct SystemHost<'a> {
    pub env: &'a Env,
}

impl HookHost for SystemHost<'_> {
    fn tmux(&self, args: &[&str], env: &Env) -> Option<String> {
        let result = run_program_with_timeout("tmux", args, env, TMUX_TIMEOUT);
        (result.code == 0).then_some(result.stdout)
    }

    fn tty(&self, pid: &str) -> String {
        process_tty(pid, self.env)
    }

    fn ppid(&self, pid: &str) -> String {
        process_ppid(pid, self.env)
    }

    fn args(&self, pid: u32) -> Option<String> {
        process_args(u64::from(pid), self.env)
    }

    fn codex_hook(&self, status: &str, input: &Value, env: &Env) {
        crate::codex_hook::record(status, input, env);
    }

    fn notify(&self, pane: &str, status: &str, env: &Env) {
        crate::hook_status::spawn_notify(&format!("tmux:{pane}"), status, env);
    }

    fn argv(&self, pid: u32) -> Option<Vec<String>> {
        crate::zellij::process_arguments(pid, self.env)
    }
    fn process_env(&self, pid: u32) -> Option<Env> {
        crate::zellij::process_environment(pid, self.env)
    }
    fn zellij_run(&self, bin: &str, args: &[&str], env: &Env) -> crate::exec::RunResult {
        crate::zellij::run_system(bin, args, env)
    }
    fn zellij_notify(&self, pane: &str, status: &str, env: &Env) {
        crate::hook_status::spawn_notify(pane, status, env);
    }
    fn core(&self) -> Option<&dyn crate::hook_status::CoreHost> {
        Some(&crate::hook_status::SystemCore)
    }
}

/// A pid's tty, or `None` for none (`readTty`).
pub(crate) fn read_tty(host: &dyn HookHost, pid: &str) -> Option<String> {
    let tty = host.tty(pid);
    match tty.as_str() {
        "" | "?" | "??" | "-" => None,
        _ => Some(tty.strip_prefix("/dev/").unwrap_or(&tty).to_string()),
    }
}

fn all_digits(value: &str) -> bool {
    !value.is_empty() && value.bytes().all(|b| b.is_ascii_digit())
}

/// The agent's controlling tty, as described at the top of this file.
pub(crate) fn agent_tty(agent: &str, env: &Env, ppid: u32, host: &dyn HookHost) -> Option<String> {
    if agent == "claude"
        && let Some(pid) = env.get("CLAUDE_PID").filter(|pid| all_digits(pid))
    {
        return read_tty(host, pid);
    }
    let ppid = ppid.to_string();
    let tty = read_tty(host, &ppid);
    if tty.is_some() || agent == "codex" || agent == "cline" {
        return tty;
    }
    let parent = host.ppid(&ppid);
    // `/^[0-9]+$/.test(parent) && Number(parent) > 1`
    let value = parent.trim_start_matches('0');
    if all_digits(&parent) && (value.len() > 1 || value.parse::<u8>().is_ok_and(|n| n > 1)) {
        read_tty(host, &parent)
    } else {
        None
    }
}

/// What the hook reads of its pane in one tmux call.
struct PaneState {
    tty: String,
    status: Option<String>,
    seq: Option<String>,
    session: Option<String>,
}

/// `.` of a JavaScript regex does not match line terminators.
fn no_line_terminator(value: &str) -> bool {
    !value.contains(['\n', '\r', '\u{2028}', '\u{2029}'])
}

/// Read the pane's tty and its `@waycar_status`/`@waycar_seq`/`@waycar_session`
/// in one tmux call. `None` when the pane does not exist on this server (tmux
/// failed) or answered no tty.
fn read_pane(pane: &str, env: &Env, host: &dyn HookHost) -> Option<PaneState> {
    let out = host.tmux(
        &[
            "display-message",
            "-p",
            "-t",
            pane,
            "#{pane_tty}",
            ";",
            "show-options",
            "-p",
            "-q",
            "-t",
            pane,
            "@waycar_status",
            ";",
            "show-options",
            "-p",
            "-q",
            "-t",
            pane,
            "@waycar_seq",
            ";",
            "show-options",
            "-p",
            "-q",
            "-t",
            pane,
            "@waycar_session",
        ],
        env,
    )?;
    let mut tty: Option<&str> = None;
    let (mut status, mut seq, mut session) = (None, None, None);
    for line in out.split('\n') {
        let option = ["@waycar_status", "@waycar_seq", "@waycar_session"]
            .into_iter()
            .find_map(|name| {
                line.strip_prefix(name)
                    .and_then(|rest| rest.strip_prefix(' '))
                    .filter(|value| no_line_terminator(value))
                    .map(|value| (name, value))
            });
        match option {
            Some((name, value)) => {
                // `.replace(/^"|"$/g, "")`
                let value = value.strip_prefix('"').unwrap_or(value);
                let value = value.strip_suffix('"').unwrap_or(value).to_string();
                match name {
                    "@waycar_status" => status = Some(value),
                    "@waycar_seq" => seq = Some(value),
                    _ => session = Some(value),
                }
            }
            None if tty.is_none() && !line.is_empty() => tty = Some(line),
            None => {}
        }
    }
    let tty = tty?;
    Some(PaneState {
        tty: tty.strip_prefix("/dev/").unwrap_or(tty).to_string(),
        status,
        seq,
        session,
    })
}

/// The variables [`run_hook_session`] reads that Muse's cleared hook
/// environment drops.
const MUSE_RESTORED: [&str; 12] = [
    "TMUX",
    "TMUX_PANE",
    "HERDR_PANE_ID",
    "HERDR_ENV",
    "WAYCAR_SUMMARY",
    "HC_TERMINAL_ID",
    "HC_TERMINAL_SOCKET",
    "HC_SESSION",
    "HC_SOCKET",
    "ZELLIJ",
    "ZELLIJ_PANE_ID",
    "ZELLIJ_SESSION_NAME",
];

/// Muse runs hooks with HOME, PATH, LANG and a few more only (muse.md): the
/// tmux and herdr variables come from the agent's own environment
/// (`/proc/<ppid>/environ`, `WAYCAR_HOOK_PROC` standing in for /proc in
/// tests), else, with no /proc, `TMUX_PANE` is the default tmux server's pane
/// whose tty is the agent's.
pub fn muse_environment(env: &Env, ppid: u32, host: &dyn HookHost) -> Env {
    if env.non_empty("TMUX_PANE").is_some() {
        return env.clone();
    }
    if let Some(own) = host.process_env(ppid) {
        let mut restored = env.clone();
        for name in MUSE_RESTORED {
            if restored.get(name).is_none()
                && let Some(value) = own.get(name)
            {
                restored.set(name, value);
            }
        }
        return restored;
    }
    let proc = env.non_empty("WAYCAR_HOOK_PROC").unwrap_or("/proc");
    let environ = std::fs::read(Path::new(proc).join(ppid.to_string()).join("environ")).ok();
    if let Some(environ) = environ {
        let environ = String::from_utf8_lossy(&environ);
        let mut restored = env.clone();
        for entry in environ.split('\0') {
            let Some(at) = entry.find('=').filter(|&at| at > 0) else {
                continue;
            };
            let name = &entry[..at];
            if MUSE_RESTORED.contains(&name) && restored.get(name).is_none() {
                restored.set(name, &entry[at + 1..]);
            }
        }
        return restored;
    }
    let Some(tty) = read_tty(host, &ppid.to_string()) else {
        return env.clone();
    };
    // No tmux server: not a tmux pane.
    let Some(panes) = host.tmux(&["list-panes", "-a", "-F", "#{pane_tty} #{pane_id}"], env) else {
        return env.clone();
    };
    for line in panes.split('\n') {
        let mut parts = line.split(' ');
        let pane_tty = parts.next().unwrap_or("");
        if let Some(id) = parts.next().filter(|id| !id.is_empty())
            && pane_tty.strip_prefix("/dev/").unwrap_or(pane_tty) == tty
        {
            let mut restored = env.clone();
            restored.set("TMUX_PANE", id);
            return restored;
        }
    }
    env.clone()
}

/// Parse a hook payload as `JSON.parse` does. serde_json refuses lone
/// surrogate escapes, which JSON.parse keeps (Node later writes them out as
/// U+FFFD, so they become that here).
pub fn parse_hook_input(raw: &str) -> Option<Value> {
    if let Ok(value) = serde_json::from_str(raw) {
        return Some(value);
    }
    let repaired = replace_lone_surrogates(raw)?;
    serde_json::from_str(&repaired).ok()
}

/// `raw` with every `\uD800`-`\uDFFF` escape inside a string that is not half
/// of a valid pair replaced by `\uFFFD`; `None` when there is none.
fn replace_lone_surrogates(raw: &str) -> Option<String> {
    let bytes = raw.as_bytes();
    let hex4 = |at: usize| -> Option<u32> {
        let digits = raw.get(at..at + 4)?;
        digits
            .bytes()
            .all(|b| b.is_ascii_hexdigit())
            .then(|| u32::from_str_radix(digits, 16).ok())
            .flatten()
    };
    let mut out = String::with_capacity(raw.len());
    let mut changed = false;
    let mut in_string = false;
    let mut at = 0;
    while at < bytes.len() {
        let byte = bytes[at];
        if !in_string {
            in_string = byte == b'"';
        } else if byte == b'"' {
            in_string = false;
        } else if byte == b'\\' {
            if bytes.get(at + 1) == Some(&b'u')
                && let Some(unit) = hex4(at + 2).filter(|u| (0xD800..=0xDFFF).contains(u))
            {
                let paired = unit < 0xDC00
                    && bytes.get(at + 6) == Some(&b'\\')
                    && bytes.get(at + 7) == Some(&b'u')
                    && hex4(at + 8).is_some_and(|low| (0xDC00..=0xDFFF).contains(&low));
                if paired {
                    out.push_str(&raw[at..at + 12]);
                    at += 12;
                } else {
                    out.push_str("\\uFFFD");
                    changed = true;
                    at += 6;
                }
                continue;
            }
            // Any other escape: keep the backslash and the character it escapes.
            let width = raw[at + 1..].chars().next().map_or(0, char::len_utf8);
            out.push_str(&raw[at..at + 1 + width]);
            at += 1 + width;
            continue;
        }
        let width = raw[at..].chars().next().map_or(1, char::len_utf8);
        out.push_str(&raw[at..at + width]);
        at += width;
    }
    changed.then_some(out)
}

/// Apply one hook event to `$TMUX_PANE`, or, when the agent is not in that
/// pane, to the herdr-core terminal `$HC_TERMINAL_ID` (the same event onto
/// labels, see [`crate::hook_status`]). Nothing is returned and nothing
/// printed: every failure just ends the hook, which must never fail the
/// agent. `process_env` is the hook's environment and `ppid` its parent.
///
/// tmux is tried first and wins when its pane exists and the agent's tty is
/// that pane's: a core started inside a tmux pane hands its terminals that
/// pane's `TMUX_PANE`, and `HERDR_*` may be as stale, so a mismatch falls
/// through to Zellij (own process environment and tty), then core, instead
/// of ending the hook.
pub fn run_hook_session(
    agent: &str,
    event: &str,
    raw_input: &str,
    process_env: &Env,
    ppid: u32,
    host: &dyn HookHost,
) {
    let env = if agent == "muse" {
        Cow::Owned(muse_environment(process_env, ppid, host))
    } else {
        Cow::Borrowed(process_env)
    };
    if env.non_empty("WAYCAR_SUMMARY").is_some() {
        return;
    }
    // A TMUX restored for muse names the pane's server for every tmux call.
    let child_env = match env.non_empty("TMUX") {
        Some(tmux) if process_env.get("TMUX") != Some(tmux) => {
            let mut child = process_env.clone();
            child.set("TMUX", tmux);
            Cow::Owned(child)
        }
        _ => Cow::Borrowed(process_env),
    };
    let tmux_pane = env.non_empty("TMUX_PANE").filter(|_| {
        ["HERDR_PANE_ID", "HERDR_ENV"]
            .iter()
            .all(|name| env.non_empty(name).is_none())
    });
    // Neither a tmux pane nor a core terminal: nothing to parse.
    if tmux_pane.is_none()
        && crate::core::terminal_address(&env).is_none()
        && crate::zellij::PaneId::from_env(&env).is_none()
    {
        return;
    }
    let Some(input) = parse_hook_input(raw_input) else {
        return;
    };
    let home = env.get("HOME").unwrap_or("");
    let Some(update) = hook_update(agent, event, &input, &env, home) else {
        return;
    };

    if let Some(pane) = tmux_pane
        && let Some(current) = read_pane(pane, &child_env, host)
        && agent_tty(agent, &env, ppid, host).as_deref() == Some(current.tty.as_str())
    {
        apply_to_pane(pane, agent, &update, &current, &child_env, host);
        return;
    }
    if let Some(target) = crate::zellij::resolve(agent, &env, ppid, host) {
        target.apply(agent, &update);
        return;
    }
    if let Some(target) = crate::hook_status::resolve_core(agent, &env, ppid, host) {
        let labels: Vec<(&str, String)> = update
            .options
            .iter()
            .filter_map(|(name, value)| {
                let value = match *name {
                    "@waycar_transcript" => percent_decode_path(value)?,
                    _ => value.clone(),
                };
                Some((core_label(name)?, value))
            })
            .collect();
        target.apply(
            agent,
            &labels,
            update.status,
            update.release,
            update.session_id.as_deref(),
        );
    }
}

/// The core label that takes a pane option's value (`@waycar_agent` is
/// `waycar.kind`); `None` for an option core has no label for.
fn core_label(option: &str) -> Option<&'static str> {
    match option {
        "@waycar_agent" => Some(crate::hook_status::LABEL_KIND),
        "@waycar_session" => Some(crate::hook_status::LABEL_SESSION),
        "@waycar_transcript" => Some(crate::hook_status::LABEL_TRANSCRIPT),
        _ => None,
    }
}

/// Write one event's options and status onto the pane the agent is in.
fn apply_to_pane(
    pane: &str,
    agent: &str,
    update: &HookUpdate,
    current: &PaneState,
    child_env: &Env,
    host: &dyn HookHost,
) {
    if update.release {
        if let (Some(wanted), Some(held)) = (
            &update.session_id,
            current.session.as_ref().filter(|held| !held.is_empty()),
        ) && wanted != held
        {
            return;
        }
        // Unset only while the pane still records that session (or none):
        // a session that replaced it after the read keeps the pane (B-34).
        if let Some(wanted) = update
            .session_id
            .as_deref()
            .filter(|wanted| format_literal(wanted) && command_target(pane))
        {
            let unset: Vec<String> = OPTIONS
                .iter()
                .map(|name| format!("set-option -p -u -t {pane} {name}"))
                .collect();
            let condition = format!(
                "#{{||:#{{==:#{{@waycar_session}},}},#{{==:#{{@waycar_session}},{wanted}}}}}"
            );
            let unset = unset.join(" ; ");
            let Some(after) = host.tmux(
                &[
                    "if-shell",
                    "-F",
                    "-t",
                    pane,
                    &condition,
                    &unset,
                    ";",
                    "show-options",
                    "-p",
                    "-q",
                    "-v",
                    "-t",
                    pane,
                    "@waycar_session",
                ],
                child_env,
            ) else {
                return;
            };
            if !after.trim_end_matches('\n').is_empty() {
                return;
            }
        } else {
            let mut args: Vec<&str> = Vec::new();
            for name in OPTIONS {
                if !args.is_empty() {
                    args.push(";");
                }
                args.extend(["set-option", "-p", "-u", "-t", pane, name]);
            }
            if host.tmux(&args, child_env).is_none() {
                return;
            }
        }
        if current
            .status
            .as_deref()
            .is_some_and(|status| !status.is_empty())
        {
            host.notify(pane, "release", child_env);
        }
        return;
    }

    let mut writes: Vec<(&str, String)> = update
        .options
        .iter()
        .map(|(name, value)| (*name, value.clone()))
        .collect();
    let next = update
        .status
        .and_then(|status| next_status(status, current.status.as_deref()))
        .filter(|next| Some(*next) != current.status.as_deref());
    if let Some(next) = next {
        if !writes.iter().any(|(name, _)| *name == "@waycar_agent") {
            writes.push(("@waycar_agent", agent.to_string()));
        }
        writes.push(("@waycar_status", next.to_string()));
        writes.push(("@waycar_seq", next_seq(current.seq.as_deref(), now_ns())));
    }
    if writes.is_empty() {
        return;
    }
    let values: Vec<Cow<str>> = writes.iter().map(|(_, value)| tmux_arg(value)).collect();
    let mut args: Vec<&str> = Vec::new();
    for ((name, _), value) in writes.iter().zip(&values) {
        if !args.is_empty() {
            args.push(";");
        }
        args.extend(["set-option", "-p", "-t", pane, name, value]);
    }
    if host.tmux(&args, child_env).is_none() {
        return;
    }
    if let Some(next) = next {
        host.notify(pane, next, child_env);
    }
}

/// The command's entry point: `waycar hook-session <agent> [<event>]` with
/// the event on stdin. Always 0.
pub fn run_hook_session_command(args: &[String], env: &Env) -> i32 {
    let agent = args.first().map_or("", String::as_str);
    let event = args.get(1).map_or("SessionStart", String::as_str);
    let mut raw = Vec::new();
    if std::io::stdin().read_to_end(&mut raw).is_ok() {
        let host = SystemHost { env };
        run_hook_session(
            agent,
            event,
            &String::from_utf8_lossy(&raw),
            env,
            std::os::unix::process::parent_id(),
            &host,
        );
    }
    0
}

/// A fake tmux server (pane options in a map, every invocation logged), process
/// table and notifier, behaving as the JS tests' fake `tmux`/`ps`/`waycar`
/// scripts do. The tests and the parity harness drive the hook with it.
#[cfg(test)]
pub mod fake {
    use std::cell::RefCell;
    use std::collections::{BTreeMap, HashMap};

    use super::{Env, HookHost};

    pub const PANE: &str = "%7";
    pub const PANE_TTY: &str = "/dev/ttys021";

    /// A pane: its tty and its options.
    pub type FakePane = (String, BTreeMap<String, String>);
    /// A process: its tty and its parent, as `ps` prints them (`None`: nothing).
    pub type FakeProcess = (Option<String>, Option<String>);

    /// Another tmux client's commands, run on the panes just before the
    /// hook's next tmux call (after its read, before its write).
    pub type Interleave = Box<dyn FnOnce(&mut BTreeMap<String, FakePane>)>;

    /// One tmux command on the fake's panes; `None` for a missing pane.
    /// `if-shell -F` runs its command list in the same call, as tmux does.
    fn apply(command: &[String], panes: &mut BTreeMap<String, FakePane>) -> Option<String> {
        let (name, rest) = command.split_first().unwrap();
        let (mut flags, mut target, mut positional) = (String::new(), None, Vec::new());
        let mut at = 0;
        while at < rest.len() {
            if rest[at] == "-t" {
                at += 1;
                target = rest.get(at).cloned();
            } else if positional.is_empty()
                && rest[at].len() > 1
                && rest[at].starts_with('-')
                && rest[at][1..].bytes().all(|b| b.is_ascii_alphabetic())
            {
                flags.push_str(&rest[at][1..]);
            } else {
                positional.push(rest[at].clone());
            }
            at += 1;
        }
        let (tty, options) = panes.get_mut(target.as_deref().unwrap_or(""))?;
        let mut out = String::new();
        match name.as_str() {
            "display-message" => out += &format!("{}\n", positional[0].replace("#{pane_tty}", tty)),
            "show-options" => match options.get(&positional[0]) {
                Some(value) if flags.contains('v') => out += &format!("{value}\n"),
                Some(value) => out += &format!("{} {value}\n", positional[0]),
                None => {}
            },
            "set-option" if flags.contains('u') => {
                options.remove(&positional[0]);
            }
            "set-option" => {
                options.insert(positional[0].clone(), positional[1].clone());
            }
            "if-shell" => {
                assert!(flags.contains('F'));
                let condition = crate::approval_watch::fake::expand(&positional[0], options);
                if crate::approval_watch::fake::truthy(&condition) {
                    for inner in positional[1].split(" ; ") {
                        let inner: Vec<String> = inner.split(' ').map(str::to_string).collect();
                        out += &apply(&inner, panes)?;
                    }
                }
            }
            _ => {}
        }
        Some(out)
    }

    pub struct Fake {
        pub panes: RefCell<BTreeMap<String, FakePane>>,
        pub interleave: RefCell<Option<Interleave>>,
        pub log: RefCell<Vec<Vec<String>>>,
        pub envs: RefCell<Vec<Env>>,
        pub ps_table: RefCell<HashMap<String, FakeProcess>>,
        pub ps_tty: RefCell<String>,
        pub ps_args: RefCell<HashMap<u32, String>>,
        pub codex_hooks: RefCell<Vec<(String, serde_json::Value)>>,
        pub notifications: RefCell<Vec<String>>,
    }

    impl Default for Fake {
        fn default() -> Self {
            Self::new()
        }
    }

    impl Fake {
        pub fn new() -> Self {
            let fake = Self {
                panes: RefCell::default(),
                interleave: RefCell::default(),
                log: RefCell::default(),
                envs: RefCell::default(),
                ps_table: RefCell::default(),
                ps_tty: RefCell::new("ttys021".into()),
                ps_args: RefCell::default(),
                codex_hooks: RefCell::default(),
                notifications: RefCell::default(),
            };
            fake.set_pane(&[]);
            fake
        }

        pub fn set_pane(&self, options: &[(&str, &str)]) {
            let options = options
                .iter()
                .map(|(k, v)| ((*k).to_string(), (*v).to_string()))
                .collect();
            self.panes
                .borrow_mut()
                .insert(PANE.into(), (PANE_TTY.into(), options));
        }

        pub fn pane_options(&self) -> BTreeMap<String, String> {
            self.panes.borrow()[PANE].1.clone()
        }

        pub fn writes(&self) -> Vec<Vec<String>> {
            self.log
                .borrow()
                .iter()
                .filter(|argv| argv.iter().any(|a| a == "set-option"))
                .cloned()
                .collect()
        }

        pub fn ps_entry(&self, pid: &str) -> FakeProcess {
            self.ps_table
                .borrow()
                .get(pid)
                .cloned()
                .unwrap_or_else(|| (Some(self.ps_tty.borrow().clone()), None))
        }
    }

    impl HookHost for Fake {
        fn args(&self, pid: u32) -> Option<String> {
            self.ps_args.borrow().get(&pid).cloned()
        }

        fn codex_hook(&self, event: &str, input: &serde_json::Value, _env: &Env) {
            self.codex_hooks
                .borrow_mut()
                .push((event.to_string(), input.clone()));
        }

        // The JS test's fake tmux.
        fn tmux(&self, args: &[&str], env: &Env) -> Option<String> {
            if !self.log.borrow().is_empty()
                && let Some(interleave) = self.interleave.borrow_mut().take()
            {
                interleave(&mut self.panes.borrow_mut());
            }
            self.log
                .borrow_mut()
                .push(args.iter().map(|a| (*a).to_string()).collect());
            self.envs.borrow_mut().push(env.clone());
            let mut commands: Vec<Vec<String>> = vec![Vec::new()];
            for arg in args {
                if *arg == ";" {
                    commands.push(Vec::new());
                } else {
                    let arg = arg
                        .strip_suffix("\\;")
                        .map_or_else(|| (*arg).to_string(), |head| format!("{head};"));
                    commands.last_mut().unwrap().push(arg);
                }
            }
            let mut out = String::new();
            let mut panes = self.panes.borrow_mut();
            for command in commands {
                out += &apply(&command, &mut panes)?;
            }
            Some(out)
        }

        fn tty(&self, pid: &str) -> String {
            self.ps_entry(pid).0.unwrap_or_default()
        }

        fn ppid(&self, pid: &str) -> String {
            self.ps_entry(pid).1.unwrap_or_default()
        }

        fn notify(&self, pane: &str, status: &str, _env: &Env) {
            self.notifications
                .borrow_mut()
                .push(format!("notify --pane tmux:{pane} --status {status}"));
        }
    }
}

/// Ports of test/hook-session.test.js: the pure event mapping against
/// payloads captured live (test/fixtures/hook-payloads.json) and the shared
/// pane option vector, and the hook against a fake tmux (pane options in a
/// map, every invocation logged), a fake process table and a fake notifier.
#[cfg(test)]
mod tests {
    use super::fake::{Fake, PANE};
    use super::*;
    use serde_json::json;
    use std::cell::RefCell;
    use std::collections::BTreeMap;

    /// The pid the tests run as the hook's parent.
    const PPID: u32 = 4242;

    fn read_json(relative: &str) -> Value {
        let path = Path::new(env!("CARGO_MANIFEST_DIR")).join(relative);
        serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
    }

    fn vectors() -> Value {
        read_json("test-vectors/tmux-pane-options-v1.json")
    }

    fn captured_payloads() -> Value {
        read_json("test/fixtures/hook-payloads.json")["payloads"].clone()
    }

    fn env_of(pairs: &[(&str, Option<&str>)]) -> Env {
        let mut env = Env::default();
        for (name, value) in pairs {
            if let Some(value) = value {
                env.set(*name, *value);
            }
        }
        env
    }

    /// `{...input, key: value}`.
    fn with(input: &Value, extra: &[(&str, Value)]) -> Value {
        let mut object = input.as_object().unwrap().clone();
        for (key, value) in extra {
            object.insert((*key).to_string(), value.clone());
        }
        Value::Object(object)
    }

    fn options(update: &HookUpdate) -> Vec<(&'static str, &str)> {
        update
            .options
            .iter()
            .map(|(n, v)| (*n, v.as_str()))
            .collect()
    }

    /// hookUpdate for a captured payload, with its captured env (plus `extra`).
    fn captured(
        agent: &str,
        name: &str,
        event: &str,
        extra: &[(&str, &str)],
    ) -> Option<HookUpdate> {
        let payloads = captured_payloads();
        let entry = &payloads[agent][name];
        let mut env = Env::default();
        if let Some(map) = entry["env"].as_object() {
            for (key, value) in map {
                env.set(key.as_str(), value.as_str().unwrap());
            }
        }
        for (key, value) in extra {
            env.set(*key, *value);
        }
        hook_update(agent, event, &entry["input"], &env, "/home/waycar")
    }

    fn update(
        agent: &str,
        event: &str,
        input: &Value,
        env: &[(&str, Option<&str>)],
    ) -> Option<HookUpdate> {
        hook_update(agent, event, input, &env_of(env), "")
    }

    // suite "hook-session helpers"

    #[test]
    fn percent_encodes_transcript_paths_as_the_shared_vector_pins() {
        for case in vectors()["transcriptEncoding"]["cases"].as_array().unwrap() {
            let (raw, encoded) = (
                case["raw"].as_str().unwrap(),
                case["encoded"].as_str().unwrap(),
            );
            assert_eq!(percent_encode_path(raw), encoded, "{raw:?}");
        }
    }

    #[test]
    fn seq_is_the_clock_unless_the_stored_seq_is_at_or_ahead_of_it() {
        let now = 1_790_000_000_000_000_000u128;
        assert_eq!(next_seq(None, now), "1790000000000000000");
        assert_eq!(
            next_seq(Some("1789999999999999999"), now),
            "1790000000000000000"
        );
        assert_eq!(
            next_seq(Some("1790000000000000000"), now),
            "1790000000000000001"
        );
        assert_eq!(
            next_seq(Some("9000000000000000000"), 1),
            "9000000000000000001"
        );
        assert_eq!(next_seq(Some("12ab"), 5), "5");
        let pattern = vectors()["seq"]["pattern"].as_str().unwrap().to_string();
        assert_eq!(pattern, "^[1-9][0-9]{0,18}$");
        let seq = next_seq(None, now_ns());
        assert!(
            (1..=19).contains(&seq.len())
                && !seq.starts_with('0')
                && seq.bytes().all(|b| b.is_ascii_digit())
        );
    }

    #[test]
    fn seq_beyond_a_u128_and_with_leading_zeros_follows_bigint() {
        // BigInt has no limit: 2^128 + 1 and a carry through every digit.
        assert_eq!(
            next_seq(Some("340282366920938463463374607431768211456"), 7),
            "340282366920938463463374607431768211457"
        );
        assert_eq!(
            next_seq(Some("99999999999999999999999999999999999999999"), 7),
            "100000000000000000000000000000000000000000"
        );
        assert_eq!(next_seq(Some("007"), 5), "8");
        assert_eq!(next_seq(Some("007"), 9), "9");
        assert_eq!(next_seq(Some("0"), 0), "1");
        assert_eq!(next_seq(Some("00"), 3), "3");
        assert_eq!(next_seq(Some(""), 3), "3");
    }

    #[test]
    fn conditional_statuses_follow_the_shared_vector() {
        // `next` null: nothing to write, the status stays as it is.
        for case in vectors()["hookTransitions"].as_array().unwrap() {
            let current = case["current"].as_str();
            let arg = case["arg"].as_str().unwrap();
            let status = next_status(arg, current);
            let written = if status == current { None } else { status };
            assert_eq!(written, case["next"].as_str(), "{current:?} + {arg}");
        }
    }

    #[test]
    fn claudes_startup_resume_clear_and_fork_reset_the_status_to_idle_compact_does_not() {
        let env = [("CLAUDECODE", Some("1"))];
        for source in ["startup", "resume", "clear", "fork"] {
            let input = json!({"session_id": "s", "source": source});
            assert_eq!(
                update("claude", "SessionStart", &input, &env)
                    .unwrap()
                    .status,
                Some("idle"),
                "{source}"
            );
        }
        let compact = json!({"session_id": "s", "source": "compact"});
        assert_eq!(
            update("claude", "SessionStart", &compact, &env)
                .unwrap()
                .status,
            None
        );
        assert_eq!(
            update("claude", "SessionStart", &json!({"session_id": "s"}), &env)
                .unwrap()
                .status,
            None
        );
    }

    #[test]
    fn claudes_live_session_start_records_the_session_and_transcript() {
        let update = captured("claude", "SessionStart", "SessionStart", &[]).unwrap();
        assert_eq!(
            options(&update),
            [
                ("@waycar_agent", "claude"),
                ("@waycar_session", "d609d33a-3274-4c3f-9b62-0e438e21e67f"),
                (
                    "@waycar_transcript",
                    "/home/waycar/.claude/projects/-home-waycar-work-demo/d609d33a-3274-4c3f-9b62-0e438e21e67f.jsonl"
                ),
            ]
        );
        assert_eq!(update.status, Some("idle"));
    }

    #[test]
    fn claudes_session_start_run_by_grok_cursor_devin_or_copilot_is_not_claudes() {
        let payloads = captured_payloads();
        // Grok's real SessionStart payload, fed to the claude entry it runs.
        let grok = &payloads["grok"]["SessionStart"];
        let mut grok_env = Env::default();
        for (key, value) in grok["env"].as_object().unwrap() {
            grok_env.set(key.as_str(), value.as_str().unwrap());
        }
        grok_env.set("CLAUDECODE", "1");
        let run = |input: &Value, env: &Env| hook_update("claude", "SessionStart", input, env, "");
        assert_eq!(run(&grok["input"], &grok_env), None);
        assert_eq!(
            run(&grok["input"], &env_of(&[("CLAUDECODE", Some("1"))])),
            None,
            "payload marker alone"
        );
        let claude = &payloads["claude"]["SessionStart"];
        let claude_env = || {
            let mut env = Env::default();
            for (key, value) in claude["env"].as_object().unwrap() {
                env.set(key.as_str(), value.as_str().unwrap());
            }
            env
        };
        for name in [
            "CURSOR_VERSION",
            "DEVIN_PROJECT_DIR",
            "COPILOT_CLI",
            "GROK_SESSION_ID",
        ] {
            let mut env = claude_env();
            env.set(name, "1");
            assert_eq!(run(&claude["input"], &env), None, "{name}");
        }
        let cursor = with(&claude["input"], &[("cursor_version", json!("2026.10.01"))]);
        assert_eq!(run(&cursor, &claude_env()), None);
        let mut no_claudecode = Env::default();
        for (key, value) in claude["env"].as_object().unwrap() {
            if key != "CLAUDECODE" {
                no_claudecode.set(key.as_str(), value.as_str().unwrap());
            }
        }
        assert_eq!(run(&claude["input"], &no_claudecode), None);
    }

    #[test]
    fn codex_records_the_session_only() {
        let input = json!({"session_id": "t", "transcript_path": "/r.jsonl", "source": "startup"});
        let update = update("codex", "SessionStart", &input, &[]).unwrap();
        assert_eq!(update.status, None);
        assert_eq!(
            options(&update),
            [
                ("@waycar_agent", "codex"),
                ("@waycar_session", "t"),
                ("@waycar_transcript", "/r.jsonl")
            ]
        );
    }

    #[test]
    fn subagents_and_nested_codex_threads_are_not_the_panes_session() {
        let payloads = captured_payloads();
        let payload = |agent: &str, name: &str| payloads[agent][name]["input"].clone();
        let claude_env = [("CLAUDECODE", Some("1"))];
        let sub = json!({"session_id": "s", "source": "startup", "agent_id": "a1"});
        assert_eq!(update("claude", "SessionStart", &sub, &claude_env), None);
        let thread = json!({"session_id": "t"});
        assert_eq!(
            update(
                "codex",
                "SessionStart",
                &thread,
                &[("CODEX_THREAD_ID", Some("other"))]
            ),
            None
        );
        assert_ne!(
            update(
                "codex",
                "SessionStart",
                &thread,
                &[("CODEX_THREAD_ID", Some("t"))]
            ),
            None
        );
        assert_eq!(
            update("aider", "SessionStart", &json!({"session_id": "s"}), &[]),
            None
        );
        let qwen = with(
            &payload("qwen", "SessionStart"),
            &[("agent_id", json!("sub"))],
        );
        assert_eq!(update("qwen", "SessionStart", &qwen, &[]), None);
        let end = with(
            &payload("grok", "SessionEnd"),
            &[("subagentType", json!("explore"))],
        );
        assert_eq!(update("grok", "SessionEnd", &end, &[]), None);
        for event in ["SessionStart", "UserPromptSubmit"] {
            let input = with(
                &payload("grok", event),
                &[("subagentType", json!("explore"))],
            );
            assert_eq!(update("grok", event, &input, &[]), None, "{event}");
        }
        let notification = payload("grok", "Notification");
        let idle = with(
            &notification,
            &[
                ("notificationType", json!("idle_prompt")),
                ("notification_type", json!("idle_prompt")),
                ("subagentType", json!("explore")),
            ],
        );
        assert_eq!(update("grok", "Notification", &idle, &[]), None);
        // A subagent's approval dialog still waits on the user.
        let approval = with(&notification, &[("subagentType", json!("explore"))]);
        assert_eq!(
            update("grok", "Notification", &approval, &[])
                .unwrap()
                .status,
            Some("blocked")
        );
        let task = with(
            &payload("cline", "TaskStart"),
            &[("parent_agent_id", json!("agent_parent"))],
        );
        assert_eq!(update("cline", "TaskStart", &task, &[]), None);
    }

    #[test]
    fn qwens_session_start_carries_its_transcript_and_opens_the_pane_idle() {
        let update = captured("qwen", "SessionStart", "SessionStart", &[]).unwrap();
        assert_eq!(
            options(&update),
            [
                ("@waycar_agent", "qwen"),
                ("@waycar_session", "5f3ac653-68b1-402c-a823-936a1885e013"),
                (
                    "@waycar_transcript",
                    "/home/waycar/.qwen/projects/-home-waycar-work-probe-qwen/chats/5f3ac653-68b1-402c-a823-936a1885e013.jsonl"
                ),
            ]
        );
        assert_eq!(update.status, Some("idle"));
    }

    #[test]
    fn copilot_the_session_from_session_start_blocked_only_on_a_permission_prompt_release_only_for_its_own_session()
     {
        let start = captured(
            "copilot",
            "SessionStart",
            "SessionStart",
            &[("COPILOT_HOME", "/opt/copilot")],
        )
        .unwrap();
        assert_eq!(
            options(&start),
            [
                ("@waycar_agent", "copilot"),
                ("@waycar_session", "f18f4b89-a0d3-4347-b145-43cedeede722"),
                (
                    "@waycar_transcript",
                    "/opt/copilot/session-state/f18f4b89-a0d3-4347-b145-43cedeede722/events.jsonl"
                ),
            ]
        );
        assert_eq!(
            start.status, None,
            "SessionStart comes after the prompt: never idle"
        );
        assert_eq!(
            captured("copilot", "Notification", "Notification", &[])
                .unwrap()
                .status,
            Some("blocked")
        );
        assert_eq!(
            update(
                "copilot",
                "Notification",
                &json!({"notification_type": "idle_prompt"}),
                &[]
            ),
            None
        );
        let end = captured("copilot", "SessionEnd", "SessionEnd", &[]).unwrap();
        assert_eq!(
            (end.release, end.session_id.as_deref()),
            (true, Some("f18f4b89-a0d3-4347-b145-43cedeede722"))
        );
        let phantom = captured("copilot", "SessionEndPhantom", "SessionEnd", &[]).unwrap();
        assert_eq!(
            phantom.session_id.as_deref(),
            Some("e98ed8fc-4ea3-4563-856a-6431589b2fd3")
        );
    }

    fn temp_dir(name: &str) -> std::path::PathBuf {
        let dir =
            std::env::temp_dir().join(format!("wc-{name}-{}-{}", std::process::id(), now_ns()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn gemini_a_resumed_session_starts_missing_transcript_falls_back_to_the_sessions_real_file() {
        let dir = temp_dir("gemini-chats");
        let payloads = captured_payloads();
        let input = &payloads["gemini"]["SessionStartResume"]["input"];
        let named = dir.join("session-2026-10-12T16-37-01ccc475.jsonl");
        let real = dir.join("session-2026-10-12T16-35-01ccc475.jsonl");
        std::fs::write(&real, "").unwrap();
        std::fs::write(dir.join("session-2026-10-12T16-30-99999999.jsonl"), "").unwrap();
        let input = with(
            input,
            &[("transcript_path", json!(named.to_str().unwrap()))],
        );
        let found = update("gemini", "SessionStart", &input, &[]).unwrap();
        assert_eq!(
            found.options.last().unwrap(),
            &(
                "@waycar_transcript",
                percent_encode_path(real.to_str().unwrap())
            )
        );
        assert_eq!(found.status, Some("idle"));
        std::fs::remove_file(&real).unwrap();
        let none = update("gemini", "SessionStart", &input, &[]).unwrap();
        assert!(
            !none
                .options
                .iter()
                .any(|(name, _)| *name == "@waycar_transcript")
        );
        std::fs::remove_dir_all(&dir).unwrap();

        let before = captured("gemini", "BeforeAgent", "BeforeAgent", &[]).unwrap();
        assert_eq!(before.status, Some("working"));
        assert_eq!(
            before.options.last().unwrap(),
            &(
                "@waycar_transcript",
                "/home/waycar/.gemini/tmp/probe-gemini/chats/session-2026-10-12T16-35-01ccc475.jsonl".to_string()
            )
        );
        assert_eq!(
            captured("gemini", "Notification", "Notification", &[])
                .unwrap()
                .status,
            Some("blocked")
        );
    }

    #[test]
    fn grok_session_start_opens_idle_the_prompt_brings_the_transcript_notifications_by_type_session_end_releases()
     {
        let start = captured("grok", "SessionStart", "SessionStart", &[]).unwrap();
        assert_eq!(
            options(&start),
            [
                ("@waycar_agent", "grok"),
                ("@waycar_session", "01a130f5-82fd-79c3-b63d-a2aa609ea70e")
            ]
        );
        assert_eq!(start.status, Some("idle"));
        let prompt = captured("grok", "UserPromptSubmit", "UserPromptSubmit", &[]).unwrap();
        assert_eq!(prompt.status, Some("working"));
        assert_eq!(
            prompt.options.last().unwrap(),
            &(
                "@waycar_transcript",
                "/home/waycar/.grok/sessions/%252Fhome%252Fwaycar%252Fwork%252Fdemo/01a130f5-82fd-79c3-b63d-a2aa609ea70e/updates.jsonl"
                    .to_string()
            )
        );
        assert_eq!(
            captured("grok", "Notification", "Notification", &[])
                .unwrap()
                .status,
            Some("blocked")
        );
        let idle = with(
            &captured_payloads()["grok"]["Notification"]["input"],
            &[
                ("notificationType", json!("idle_prompt")),
                ("notification_type", json!("idle_prompt")),
            ],
        );
        assert_eq!(
            update("grok", "Notification", &idle, &[]).unwrap().status,
            Some("idle-if-working")
        );
        let end = captured("grok", "SessionEnd", "SessionEnd", &[]).unwrap();
        assert_eq!(
            (end.release, end.session_id.as_deref()),
            (true, Some("01a130f7-4334-7781-86bb-d1d0f32278bb"))
        );
    }

    #[test]
    fn antigravity_pre_invocation_records_the_conversation_and_works_only_a_fully_idle_stop_is_done()
     {
        let id = "8e00464e-4412-4944-91be-b38078c432d6";
        let start = captured("agy", "PreInvocation", "PreInvocation", &[]).unwrap();
        let transcript = format!(
            "/home/waycar/.gemini/antigravity-cli/brain/{id}/.system_generated/logs/transcript_full.jsonl"
        );
        assert_eq!(
            options(&start),
            [
                ("@waycar_agent", "agy"),
                ("@waycar_session", id),
                ("@waycar_transcript", transcript.as_str())
            ]
        );
        assert_eq!(start.status, Some("working"));
        assert_eq!(
            captured("agy", "Stop", "Stop", &[]).unwrap().status,
            Some("done")
        );
        let partial = with(
            &captured_payloads()["agy"]["Stop"]["input"],
            &[("fullyIdle", json!(false))],
        );
        assert_eq!(update("agy", "Stop", &partial, &[]), None);
    }

    #[test]
    fn hermes_every_llm_call_works_a_turn_end_is_done_an_interrupted_one_idle() {
        let call = captured("hermes", "pre_llm_call", "pre_llm_call", &[]).unwrap();
        assert_eq!(
            options(&call),
            [
                ("@waycar_agent", "hermes"),
                ("@waycar_session", "20261012_164012_b4df59")
            ]
        );
        assert_eq!(call.status, Some("working"));
        assert_eq!(
            captured("hermes", "on_session_end", "on_session_end", &[])
                .unwrap()
                .status,
            Some("done")
        );
        let interrupted = captured(
            "hermes",
            "on_session_end_interrupted",
            "on_session_end",
            &[],
        )
        .unwrap();
        assert_eq!(interrupted.status, Some("idle"));
    }

    #[test]
    fn cline_task_start_and_task_resume_record_the_root_session_and_its_messages_file() {
        for event in ["TaskStart", "TaskResume"] {
            let update = captured("cline", event, event, &[]).unwrap();
            let id =
                captured_payloads()["cline"][event]["input"]["sessionContext"]["rootSessionId"]
                    .as_str()
                    .unwrap()
                    .to_string();
            let transcript = format!("/home/waycar/.cline/data/sessions/{id}/{id}.messages.json");
            assert_eq!(
                options(&update),
                [
                    ("@waycar_agent", "cline"),
                    ("@waycar_session", id.as_str()),
                    ("@waycar_transcript", transcript.as_str())
                ]
            );
            assert_eq!(update.status, Some("working"));
        }
    }

    #[test]
    fn muse_every_prompt_records_the_session_no_session_start_on_resume_and_works() {
        let update_ = captured("muse", "UserPromptSubmit", "UserPromptSubmit", &[]).unwrap();
        assert_eq!(
            options(&update_),
            [
                ("@waycar_agent", "muse"),
                ("@waycar_session", "01a131b6-7791-7721-9945-869757c6177d")
            ]
        );
        assert_eq!(update_.status, Some("working"));
        let input = captured_payloads()["muse"]["UserPromptSubmit"]["input"].clone();
        let child = with(&input, &[("agent_id", json!("child"))]);
        assert_eq!(update("muse", "UserPromptSubmit", &child, &[]), None);
        assert_eq!(update("muse", "SessionStart", &input, &[]), None);
    }

    #[test]
    fn cursors_session_start_needs_cursors_marker_and_is_not_groks() {
        let input = json!({"session_id": "c1", "conversation_id": "c1", "cursor_version": "2026.10.01", "hook_event_name": "sessionStart"});
        let got = update("cursor", "sessionStart", &input, &[]).unwrap();
        assert_eq!(
            options(&got),
            [("@waycar_agent", "cursor"), ("@waycar_session", "c1")]
        );
        // `cursor_version: undefined` is an absent key.
        let no_version =
            json!({"session_id": "c1", "conversation_id": "c1", "hook_event_name": "sessionStart"});
        assert_eq!(update("cursor", "sessionStart", &no_version, &[]), None);
        assert_eq!(
            update(
                "cursor",
                "sessionStart",
                &input,
                &[("GROK_SESSION_ID", Some("g"))]
            ),
            None
        );
    }

    #[test]
    fn events_with_nothing_to_say_do_nothing() {
        assert_eq!(
            update("claude", "Stop", &json!({}), &[("CLAUDECODE", Some("1"))]),
            None
        );
        assert_eq!(
            update(
                "gemini",
                "Notification",
                &json!({"notification_type": "Other"}),
                &[]
            ),
            None
        );
        assert_eq!(update("grok", "SessionStart", &json!([]), &[]), None);
    }

    #[test]
    fn payload_values_follow_javascript_truthiness_and_types() {
        let claude = [("CLAUDECODE", Some("1"))];
        // An empty array or object is truthy: a subagent marker all the same.
        for marker in [json!([]), json!({}), json!(1), json!("x"), json!(true)] {
            let input = json!({"session_id": "s", "agent_id": marker});
            assert_eq!(
                update("claude", "SessionStart", &input, &claude),
                None,
                "{marker}"
            );
        }
        for marker in [json!(null), json!(0), json!(""), json!(false)] {
            let input = json!({"session_id": "s", "agent_id": marker});
            assert_ne!(
                update("claude", "SessionStart", &input, &claude),
                None,
                "{marker}"
            );
        }
        // A session id that is not a non-empty string is no session.
        let numeric = json!({"session_id": 5, "transcript_path": ""});
        let got = update("codex", "SessionStart", &numeric, &[]).unwrap();
        assert_eq!(options(&got), [("@waycar_agent", "codex")]);
        // `extra` that is not an object is not interrupted.
        let end = json!({"extra": "interrupted"});
        assert_eq!(
            update("hermes", "on_session_end", &end, &[])
                .unwrap()
                .status,
            Some("done")
        );
        assert_eq!(
            update(
                "hermes",
                "on_session_end",
                &json!({"extra": {"interrupted": 1}}),
                &[]
            )
            .unwrap()
            .status,
            Some("done")
        );
    }

    #[test]
    fn transcript_paths_join_like_path_join() {
        let env = env_of(&[("COPILOT_HOME", Some("/c/"))]);
        let input = json!({"session_id": "../x/./y//z"});
        let got = hook_update("copilot", "SessionStart", &input, &env, "").unwrap();
        assert_eq!(got.options[2].1, "/c/x/y/z/events.jsonl");
        // An absolute id does not restart the path.
        let absolute = json!({"session_id": "/etc"});
        let got = hook_update("copilot", "SessionStart", &absolute, &env, "").unwrap();
        assert_eq!(got.options[2].1, "/c/session-state/etc/events.jsonl");
        // No home: relative paths.
        let got = hook_update(
            "copilot",
            "SessionStart",
            &json!({"session_id": "s"}),
            &Env::default(),
            "",
        )
        .unwrap();
        assert_eq!(got.options[2].1, ".copilot/session-state/s/events.jsonl");
        assert_eq!(join(&["a", "..", "..", "b"]), "../b");
        assert_eq!(join(&["/a", "..", ".."]), "/");
        assert_eq!(join(&["", ""]), ".");
        assert_eq!(join(&["a/", "b/"]), "a/b/");
        assert_eq!(posix_dirname("/a/b/c.jsonl"), "/a/b");
        assert_eq!(posix_dirname("c.jsonl"), ".");
        assert_eq!(posix_dirname("/c"), "/");
        assert_eq!(posix_dirname("a//b"), "a/");
    }

    #[test]
    fn payloads_with_lone_surrogate_escapes_parse_as_json_parse_does() {
        let parsed =
            parse_hook_input(r#"{"session_id": "a\ud800b", "x": "\\ud800 \ud83d\ude00 \udc00"}"#)
                .unwrap();
        assert_eq!(parsed["session_id"], "a\u{fffd}b");
        assert_eq!(parsed["x"], "\\ud800 \u{1f600} \u{fffd}");
        assert_eq!(parse_hook_input("not json"), None);
        assert_eq!(parse_hook_input(""), None);
        assert_eq!(parse_hook_input(r#"{"a": "\ud800"#), None);
    }

    // The process readers answer what `ps` prints.

    #[cfg(target_os = "linux")]
    #[test]
    fn linux_process_readers_match_ps() {
        use std::process::{Command, Stdio};
        let ps = |args: &[&str]| {
            Command::new("ps")
                .args(args)
                .output()
                .ok()
                .filter(|out| out.status.success())
        };
        let env = Env::from_process();
        let me = std::process::id().to_string();
        let mut child = Command::new("sh")
            .args([
                "-c",
                "sleep 30; :",
                "sh",
                "watch-approval",
                "--pane",
                "tmux:%3",
                "--agent",
                "agy",
            ])
            .stdin(Stdio::null())
            .spawn()
            .unwrap();
        let pid = child.id().to_string();
        // The shell takes a moment to be a shell.
        std::thread::sleep(Duration::from_millis(100));
        for target in [me.as_str(), pid.as_str(), "1"] {
            if let Some(out) = ps(&["-o", "tty=", "-p", target]) {
                assert_eq!(
                    process_tty(target, &env),
                    String::from_utf8_lossy(&out.stdout).trim(),
                    "tty of {target}"
                );
            }
            if let Some(out) = ps(&["-o", "ppid=", "-p", target]) {
                assert_eq!(
                    process_ppid(target, &env),
                    String::from_utf8_lossy(&out.stdout).trim(),
                    "ppid of {target}"
                );
            }
            if let Some(out) = ps(&["-ww", "-o", "args=", "-p", target]) {
                let args = process_args(target.parse().unwrap(), &env).unwrap();
                assert_eq!(
                    args,
                    String::from_utf8_lossy(&out.stdout).trim_end(),
                    "args of {target}"
                );
            }
        }
        assert_eq!(process_ppid(&pid, &env), me);
        assert_eq!(
            process_args(child.id().into(), &env).as_deref(),
            Some("sh -c sleep 30; : sh watch-approval --pane tmux:%3 --agent agy")
        );
        child.kill().unwrap();
        child.wait().unwrap();
        assert_eq!(process_tty("999999999", &env), "");
        assert_eq!(process_ppid("abc", &env), "");
        assert_eq!(process_args(999_999_999, &env), None);
    }

    struct Run<'a> {
        env: Vec<(&'a str, Option<&'a str>)>,
        ps_tty: &'a str,
        ps_table: Vec<(&'a str, Option<&'a str>, Option<&'a str>)>,
        event: Option<&'a str>,
    }

    impl Default for Run<'_> {
        fn default() -> Self {
            Self {
                env: Vec::new(),
                ps_tty: "ttys021",
                ps_table: Vec::new(),
                event: None,
            }
        }
    }

    /// Run the hook; `psTty` is the tty of the hook's parent and of any pid
    /// the table does not list.
    fn run(fake: &Fake, agent: &str, input: &Value, options: Run) {
        run_raw(fake, agent, &input.to_string(), options);
    }

    fn run_raw(fake: &Fake, agent: &str, body: &str, options: Run) {
        let mut env = env_of(&[
            ("PATH", Some("/usr/bin:/bin")),
            ("TMUX", Some("/tmp/fake-tmux-socket,1,0")),
            ("TMUX_PANE", Some(PANE)),
            ("CLAUDECODE", Some("1")),
        ]);
        for (name, value) in &options.env {
            match value {
                Some(value) => env.set(*name, *value),
                None => {
                    env = Env::from_pairs(
                        env.iter()
                            .filter(|(k, _)| k != name)
                            .map(|(k, v)| (k.to_string(), v.to_string())),
                    );
                }
            }
        }
        *fake.ps_tty.borrow_mut() = options.ps_tty.to_string();
        *fake.ps_table.borrow_mut() = options
            .ps_table
            .iter()
            .map(|(pid, tty, ppid)| {
                (
                    (*pid).to_string(),
                    (tty.map(str::to_string), ppid.map(str::to_string)),
                )
            })
            .collect();
        run_hook_session(
            agent,
            options.event.unwrap_or("SessionStart"),
            body,
            &env,
            PPID,
            fake,
        );
    }

    fn claude_start() -> Value {
        json!({
            "hook_event_name": "SessionStart",
            "session_id": "0b6f3c1e-2a4d-4c55-9d1e-7f00a1b2c3d4",
            "transcript_path": "/Users/me/.claude/projects/-Users-me-a b/0b6f3c1e.jsonl",
            "source": "startup",
        })
    }

    fn notification(status: &str) -> String {
        format!("notify --pane tmux:{PANE} --status {status}")
    }

    fn opt(options: &BTreeMap<String, String>, name: &str) -> Option<String> {
        options.get(name).cloned()
    }

    #[test]
    fn claude_startup_records_the_session_encodes_the_transcript_and_sets_idle() {
        let fake = Fake::new();
        fake.set_pane(&[("@waycar_status", "done"), ("@waycar_seq", "100")]);
        let start = claude_start();
        run(&fake, "claude", &start, Run::default());
        let options = fake.pane_options();
        assert_eq!(opt(&options, "@waycar_agent").as_deref(), Some("claude"));
        assert_eq!(
            opt(&options, "@waycar_session"),
            start["session_id"].as_str().map(str::to_string)
        );
        assert_eq!(
            opt(&options, "@waycar_transcript").as_deref(),
            Some("/Users/me/.claude/projects/-Users-me-a%20b/0b6f3c1e.jsonl")
        );
        assert_eq!(opt(&options, "@waycar_status").as_deref(), Some("idle"));
        assert!(options["@waycar_seq"].parse::<u128>().unwrap() > 100);
        assert_eq!(fake.writes().len(), 1, "one tmux call for every option");
        assert_eq!(*fake.notifications.borrow(), [notification("idle")]);
    }

    #[test]
    fn claude_compact_keeps_the_status_and_seq() {
        let fake = Fake::new();
        fake.set_pane(&[("@waycar_status", "working"), ("@waycar_seq", "100")]);
        let input = with(
            &claude_start(),
            &[
                ("source", json!("compact")),
                ("session_id", json!("after-compact")),
            ],
        );
        run(&fake, "claude", &input, Run::default());
        let options = fake.pane_options();
        assert_eq!(
            opt(&options, "@waycar_session").as_deref(),
            Some("after-compact")
        );
        assert_eq!(opt(&options, "@waycar_status").as_deref(), Some("working"));
        assert_eq!(opt(&options, "@waycar_seq").as_deref(), Some("100"));
        assert!(fake.notifications.borrow().is_empty());
    }

    #[test]
    fn codex_session_start_records_the_session_without_touching_the_status() {
        let fake = Fake::new();
        let input = json!({"hook_event_name": "SessionStart", "session_id": "019a", "transcript_path": "/home/u/.codex/sessions/r.jsonl"});
        run(&fake, "codex", &input, Run::default());
        let expected: BTreeMap<String, String> = [
            ("@waycar_agent", "codex"),
            ("@waycar_session", "019a"),
            ("@waycar_transcript", "/home/u/.codex/sessions/r.jsonl"),
        ]
        .into_iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect();
        assert_eq!(fake.pane_options(), expected);
    }

    #[test]
    fn a_session_id_ending_in_a_semicolon_survives_tmuxs_command_separator() {
        let fake = Fake::new();
        run(
            &fake,
            "codex",
            &json!({"session_id": "odd;"}),
            Run::default(),
        );
        assert_eq!(
            opt(&fake.pane_options(), "@waycar_session").as_deref(),
            Some("odd;")
        );
        // The argument tmux saw ends in an escaped separator.
        assert!(fake.writes()[0].iter().any(|arg| arg == "odd\\;"));
    }

    #[test]
    fn requires_the_agents_tty_to_be_the_panes_tty() {
        let fake = Fake::new();
        for ps_tty in ["ttys099", "??", ""] {
            run(
                &fake,
                "claude",
                &claude_start(),
                Run {
                    ps_tty,
                    ..Run::default()
                },
            );
        }
        assert!(fake.writes().is_empty());
        run(
            &fake,
            "claude",
            &claude_start(),
            Run {
                ps_tty: "/dev/ttys021",
                ..Run::default()
            },
        );
        assert_eq!(
            opt(&fake.pane_options(), "@waycar_status").as_deref(),
            Some("idle")
        );
        assert_eq!(*fake.notifications.borrow(), [notification("idle")]);
    }

    #[test]
    fn does_nothing_in_a_herdr_pane_outside_tmux_in_an_agent_summary_run_for_subagents_or_bad_input()
     {
        let fake = Fake::new();
        let start = claude_start();
        run(
            &fake,
            "claude",
            &start,
            Run {
                env: vec![("HERDR_PANE_ID", Some("w1:p1"))],
                ..Run::default()
            },
        );
        run(
            &fake,
            "claude",
            &start,
            Run {
                env: vec![("HERDR_ENV", Some("1"))],
                ..Run::default()
            },
        );
        run(
            &fake,
            "claude",
            &start,
            Run {
                env: vec![("TMUX_PANE", None)],
                ..Run::default()
            },
        );
        run(
            &fake,
            "claude",
            &start,
            Run {
                env: vec![("WAYCAR_SUMMARY", Some("1"))],
                ..Run::default()
            },
        );
        let end = captured_payloads()["copilot"]["SessionEnd"]["input"].clone();
        run(
            &fake,
            "copilot",
            &end,
            Run {
                event: Some("SessionEnd"),
                env: vec![("WAYCAR_SUMMARY", Some("1"))],
                ..Run::default()
            },
        );
        run(
            &fake,
            "claude",
            &with(&start, &[("agent_id", json!("sub-1"))]),
            Run::default(),
        );
        run_raw(&fake, "claude", "not json", Run::default());
        run_raw(&fake, "claude", "", Run::default());
        assert!(fake.writes().is_empty());
    }

    #[test]
    fn exits_silently_when_tmux_fails() {
        let fake = Fake::new();
        run(
            &fake,
            "claude",
            &claude_start(),
            Run {
                env: vec![("TMUX_PANE", Some("%99"))],
                ..Run::default()
            },
        );
        assert!(fake.writes().is_empty());
    }

    #[test]
    fn muse_tmux_pane_and_herdr_variables_come_from_the_agents_own_environment() {
        let fake = Fake::new();
        let proc = temp_dir("hook-proc");
        let environ = proc.join(PPID.to_string()).join("environ");
        std::fs::create_dir_all(environ.parent().unwrap()).unwrap();
        let proc_text = proc.to_str().unwrap();
        let cleared = || Run {
            env: vec![
                ("TMUX", None),
                ("TMUX_PANE", None),
                ("CLAUDECODE", None),
                ("WAYCAR_HOOK_PROC", Some(proc_text)),
            ],
            event: Some("UserPromptSubmit"),
            ..Run::default()
        };
        let input = captured_payloads()["muse"]["UserPromptSubmit"]["input"].clone();
        std::fs::write(
            &environ,
            format!(
                "HOME=/home/u\0TMUX=/tmp/fake-tmux-socket,1,0\0TMUX_PANE={PANE}\0HERDR_ENV=1\0"
            ),
        )
        .unwrap();
        run(&fake, "muse", &input, cleared());
        assert!(fake.writes().is_empty(), "a herdr pane");
        std::fs::write(
            &environ,
            format!("HOME=/home/u\0TMUX=/tmp/fake-tmux-socket,1,0\0TMUX_PANE={PANE}\0"),
        )
        .unwrap();
        run(&fake, "muse", &input, cleared());
        let options = fake.pane_options();
        assert_eq!(
            opt(&options, "@waycar_session"),
            input["session_id"].as_str().map(str::to_string)
        );
        assert_eq!(opt(&options, "@waycar_status").as_deref(), Some("working"));
        // The restored TMUX names the server for every tmux call.
        assert!(
            fake.envs
                .borrow()
                .iter()
                .all(|env| env.get("TMUX") == Some("/tmp/fake-tmux-socket,1,0"))
        );
        std::fs::remove_dir_all(&proc).unwrap();
    }

    #[test]
    fn muse_without_proc_takes_the_pane_whose_tty_is_the_agents() {
        struct Panes;
        impl HookHost for Panes {
            fn tmux(&self, args: &[&str], _env: &Env) -> Option<String> {
                assert_eq!(args, ["list-panes", "-a", "-F", "#{pane_tty} #{pane_id}"]);
                Some("/dev/ttys001 %1\n/dev/ttys021 %7 extra\n\n".to_string())
            }
            fn tty(&self, pid: &str) -> String {
                assert_eq!(pid, "4242");
                "/dev/ttys021".into()
            }
            fn ppid(&self, _pid: &str) -> String {
                String::new()
            }
            fn notify(&self, _pane: &str, _status: &str, _env: &Env) {}
        }
        let env = env_of(&[
            ("HOME", Some("/h")),
            ("WAYCAR_HOOK_PROC", Some("/nonexistent-proc")),
        ]);
        let restored = muse_environment(&env, PPID, &Panes);
        assert_eq!(restored.get("TMUX_PANE"), Some("%7"));
        assert_eq!(restored.get("HOME"), Some("/h"));
        // An environment that already names the pane is left alone.
        let named = env_of(&[("TMUX_PANE", Some("%2"))]);
        assert_eq!(muse_environment(&named, PPID, &Panes), named);
    }

    #[test]
    fn claudes_tty_is_claude_pids_claude_2_1_296_runs_hooks_from_a_tty_less_sh() {
        let fake = Fake::new();
        let payloads = captured_payloads();
        let entry = &payloads["claude"]["SessionStart"];
        let pid = entry["env"]["CLAUDE_PID"].as_str().unwrap();
        let env: Vec<(&str, Option<&str>)> = entry["env"]
            .as_object()
            .unwrap()
            .iter()
            .map(|(k, v)| (k.as_str(), v.as_str()))
            .collect();
        run(
            &fake,
            "claude",
            &entry["input"],
            Run {
                env: env.clone(),
                ps_tty: "?",
                ps_table: vec![(pid, Some("ttys021"), None)],
                ..Run::default()
            },
        );
        assert_eq!(
            opt(&fake.pane_options(), "@waycar_session").as_deref(),
            Some("d609d33a-3274-4c3f-9b62-0e438e21e67f")
        );
        fake.set_pane(&[]);
        run(
            &fake,
            "claude",
            &entry["input"],
            Run {
                env,
                ps_tty: "ttys021",
                ps_table: vec![(pid, Some("ttys099"), None)],
                ..Run::default()
            },
        );
        assert!(fake.pane_options().is_empty());
    }

    #[test]
    fn a_tty_less_parent_defers_to_its_parent_except_for_codex_and_cline() {
        let fake = Fake::new();
        let parent = PPID.to_string();
        let table = || {
            vec![
                (parent.as_str(), Some("?"), Some("777")),
                ("777", Some("ttys021"), None),
            ]
        };
        run(
            &fake,
            "codex",
            &json!({"session_id": "019a"}),
            Run {
                ps_table: table(),
                ..Run::default()
            },
        );
        assert!(
            fake.writes().is_empty(),
            "codex's tty-less parent is its shared app-server"
        );
        let task = captured_payloads()["cline"]["TaskStart"]["input"].clone();
        run(
            &fake,
            "cline",
            &task,
            Run {
                event: Some("TaskStart"),
                ps_table: table(),
                ..Run::default()
            },
        );
        assert!(
            fake.writes().is_empty(),
            "cline's tty-less parent is its hub"
        );
        let payloads = captured_payloads();
        let grok = &payloads["grok"]["SessionStart"];
        let env: Vec<(&str, Option<&str>)> = grok["env"]
            .as_object()
            .unwrap()
            .iter()
            .map(|(k, v)| (k.as_str(), v.as_str()))
            .collect();
        run(
            &fake,
            "grok",
            &grok["input"],
            Run {
                env,
                ps_table: table(),
                ..Run::default()
            },
        );
        let options = fake.pane_options();
        assert_eq!(opt(&options, "@waycar_agent").as_deref(), Some("grok"));
        assert_eq!(opt(&options, "@waycar_status").as_deref(), Some("idle"));
    }

    #[test]
    fn a_grandparent_of_pid_1_or_0_is_not_asked() {
        let fake = Fake::new();
        let parent = PPID.to_string();
        for grandparent in ["1", "0", "001", "x"] {
            run(
                &fake,
                "qwen",
                &json!({"session_id": "q"}),
                Run {
                    ps_table: vec![
                        (parent.as_str(), Some("?"), Some(grandparent)),
                        (grandparent, Some("ttys021"), None),
                    ],
                    ..Run::default()
                },
            );
        }
        assert!(fake.writes().is_empty());
    }

    #[test]
    fn a_status_from_the_payload_applies_waycar_hooks_transitions_and_notifies() {
        let fake = Fake::new();
        fake.set_pane(&[("@waycar_status", "working"), ("@waycar_seq", "100")]);
        let payloads = captured_payloads();
        run(
            &fake,
            "hermes",
            &payloads["hermes"]["on_session_end"]["input"],
            Run {
                event: Some("on_session_end"),
                ..Run::default()
            },
        );
        let options = fake.pane_options();
        assert_eq!(opt(&options, "@waycar_status").as_deref(), Some("done"));
        assert_eq!(opt(&options, "@waycar_agent").as_deref(), Some("hermes"));
        assert!(options["@waycar_seq"].parse::<u128>().unwrap() > 100);
        assert_eq!(*fake.notifications.borrow(), [notification("done")]);
        fake.set_pane(&[("@waycar_status", "done")]);
        let idle = with(
            &payloads["grok"]["Notification"]["input"],
            &[("notificationType", json!("idle_prompt"))],
        );
        run(
            &fake,
            "grok",
            &idle,
            Run {
                event: Some("Notification"),
                ..Run::default()
            },
        );
        assert_eq!(
            opt(&fake.pane_options(), "@waycar_status").as_deref(),
            Some("done"),
            "idle-if-working leaves done alone"
        );
    }

    #[test]
    fn session_end_releases_only_the_panes_own_session_copilots_stray_session_end_on_resume() {
        let fake = Fake::new();
        let payloads = captured_payloads();
        let own = &payloads["copilot"]["SessionEnd"]["input"];
        let phantom = &payloads["copilot"]["SessionEndPhantom"]["input"];
        fake.set_pane(&[
            ("@waycar_status", "done"),
            ("@waycar_agent", "copilot"),
            ("@waycar_session", own["session_id"].as_str().unwrap()),
            ("@waycar_seq", "5"),
        ]);
        run(
            &fake,
            "copilot",
            phantom,
            Run {
                event: Some("SessionEnd"),
                ..Run::default()
            },
        );
        assert_eq!(
            opt(&fake.pane_options(), "@waycar_status").as_deref(),
            Some("done")
        );
        run(
            &fake,
            "copilot",
            own,
            Run {
                event: Some("SessionEnd"),
                ..Run::default()
            },
        );
        assert!(fake.pane_options().is_empty());
        assert_eq!(*fake.notifications.borrow(), [notification("release")]);
    }

    fn session_end(fake: &Fake, agent: &str, input: &Value) {
        run(
            fake,
            agent,
            input,
            Run {
                event: Some("SessionEnd"),
                ..Run::default()
            },
        );
    }

    #[test]
    fn a_release_without_a_session_id_or_of_a_pane_that_records_none_unsets_everything() {
        for held in [None, Some("")] {
            let fake = Fake::new();
            let mut options = vec![("@waycar_status", "working"), ("@waycar_seq", "9")];
            if let Some(held) = held {
                options.push(("@waycar_session", held));
            }
            fake.set_pane(&options);
            session_end(&fake, "copilot", &json!({"session_id": "any"}));
            assert!(fake.pane_options().is_empty(), "{held:?}");
            assert_eq!(*fake.notifications.borrow(), [notification("release")]);
        }
        // No id in the payload: whatever session the pane records.
        let fake = Fake::new();
        fake.set_pane(&[("@waycar_status", "done"), ("@waycar_session", "s1")]);
        session_end(&fake, "copilot", &json!({}));
        assert!(fake.pane_options().is_empty());
        assert_eq!(*fake.notifications.borrow(), [notification("release")]);
    }

    #[test]
    fn a_release_notifies_only_a_pane_that_had_a_status_and_only_after_the_unset() {
        // No status: unset, no notification.
        let fake = Fake::new();
        fake.set_pane(&[("@waycar_session", "s1"), ("@waycar_agent", "copilot")]);
        session_end(&fake, "copilot", &json!({"session_id": "s1"}));
        assert!(fake.pane_options().is_empty());
        assert!(fake.notifications.borrow().is_empty());
        // The pane went away between the read and the unset: no notification.
        let fake = Fake::new();
        fake.set_pane(&[("@waycar_status", "done"), ("@waycar_session", "s1")]);
        *fake.interleave.borrow_mut() = Some(Box::new(|panes| {
            panes.clear();
        }));
        session_end(&fake, "copilot", &json!({"session_id": "s1"}));
        assert_eq!(fake.log.borrow().len(), 2, "the read, then the unset");
        assert!(fake.notifications.borrow().is_empty());
        // grok's SessionEnd releases the same way; its id may come from the env.
        let fake = Fake::new();
        fake.set_pane(&[("@waycar_status", "idle"), ("@waycar_session", "g1")]);
        run(
            &fake,
            "grok",
            &json!({}),
            Run {
                event: Some("SessionEnd"),
                env: vec![("GROK_SESSION_ID", Some("g2"))],
                ..Run::default()
            },
        );
        assert_eq!(
            opt(&fake.pane_options(), "@waycar_session").as_deref(),
            Some("g1")
        );
    }

    /// Another hook's write, as another tmux client makes it.
    fn set(panes: &mut BTreeMap<String, super::fake::FakePane>, name: &str, value: &str) {
        panes
            .get_mut(PANE)
            .unwrap()
            .1
            .insert(name.to_string(), value.to_string());
    }

    #[test]
    fn an_old_session_end_never_releases_the_session_that_replaced_it() {
        // B-34: the old session's SessionEnd reads the pane, the new
        // session's SessionStart records itself, then the old hook writes.
        let fake = Fake::new();
        fake.set_pane(&[
            ("@waycar_status", "done"),
            ("@waycar_agent", "copilot"),
            ("@waycar_session", "s1"),
            ("@waycar_seq", "5"),
        ]);
        *fake.interleave.borrow_mut() = Some(Box::new(|panes| {
            set(panes, "@waycar_session", "s2");
            set(panes, "@waycar_transcript", "/t/s2.jsonl");
        }));
        session_end(&fake, "copilot", &json!({"session_id": "s1"}));
        let options = fake.pane_options();
        assert_eq!(opt(&options, "@waycar_session").as_deref(), Some("s2"));
        assert_eq!(
            opt(&options, "@waycar_transcript").as_deref(),
            Some("/t/s2.jsonl")
        );
        assert_eq!(opt(&options, "@waycar_status").as_deref(), Some("done"));
        assert!(fake.notifications.borrow().is_empty());

        // An id a tmux format cannot hold is released as before, in one
        // unconditional call.
        let fake = Fake::new();
        fake.set_pane(&[("@waycar_status", "done"), ("@waycar_session", "a,b")]);
        session_end(&fake, "copilot", &json!({"session_id": "a,b"}));
        assert!(fake.pane_options().is_empty());
        assert!(!fake.log.borrow()[1].iter().any(|arg| arg == "if-shell"));
        assert_eq!(*fake.notifications.borrow(), [notification("release")]);
    }

    #[test]
    fn a_payload_status_equal_to_the_panes_writes_only_the_options() {
        let fake = Fake::new();
        fake.set_pane(&[("@waycar_status", "working"), ("@waycar_seq", "100")]);
        let payloads = captured_payloads();
        run(
            &fake,
            "hermes",
            &payloads["hermes"]["pre_llm_call"]["input"],
            Run {
                event: Some("pre_llm_call"),
                ..Run::default()
            },
        );
        let options = fake.pane_options();
        assert_eq!(opt(&options, "@waycar_seq").as_deref(), Some("100"));
        assert!(opt(&options, "@waycar_session").is_some());
        assert_eq!(fake.writes().len(), 1);
        assert!(fake.notifications.borrow().is_empty());
        // Nothing to write at all: no tmux write.
        let fake = Fake::new();
        fake.set_pane(&[("@waycar_status", "blocked"), ("@waycar_seq", "7")]);
        let blocked = with(
            &payloads["grok"]["Notification"]["input"],
            &[("notificationType", json!("permission_prompt"))],
        );
        let notification_run = || Run {
            event: Some("Notification"),
            ..Run::default()
        };
        run(&fake, "grok", &blocked, notification_run());
        assert!(fake.writes().is_empty());
    }

    #[test]
    fn a_conditional_payload_status_moves_only_from_its_states_and_notifies_after_the_write() {
        let payloads = captured_payloads();
        let idle = with(
            &payloads["grok"]["Notification"]["input"],
            &[("notificationType", json!("idle_prompt"))],
        );
        let notification_run = || Run {
            event: Some("Notification"),
            ..Run::default()
        };
        for (current, expected) in [
            (Some("working"), Some("idle")),
            (Some("blocked"), Some("blocked")),
            (Some("done"), Some("done")),
            (None, None),
        ] {
            let fake = Fake::new();
            let mut options = vec![("@waycar_seq", "100")];
            if let Some(current) = current {
                options.push(("@waycar_status", current));
            }
            fake.set_pane(&options);
            run(&fake, "grok", &idle, notification_run());
            let pane = fake.pane_options();
            assert_eq!(
                opt(&pane, "@waycar_status").as_deref(),
                expected,
                "{current:?}"
            );
            let moved = expected != current;
            assert_eq!(fake.notifications.borrow().len(), usize::from(moved));
            if moved {
                assert_eq!(opt(&pane, "@waycar_agent").as_deref(), Some("grok"));
                assert!(pane["@waycar_seq"].parse::<u128>().unwrap() > 100);
            }
        }
        // The pane went away before the write: no notification.
        let fake = Fake::new();
        fake.set_pane(&[("@waycar_status", "working"), ("@waycar_seq", "100")]);
        *fake.interleave.borrow_mut() = Some(Box::new(|panes| {
            panes.clear();
        }));
        run(&fake, "grok", &idle, notification_run());
        assert!(fake.notifications.borrow().is_empty());
    }

    #[test]
    fn pane_option_lines_are_read_as_the_js_regex_reads_them() {
        let fake = Fake::new();
        // Quotes around a value are stripped once at each end.
        fake.set_pane(&[
            ("@waycar_status", "\"working\""),
            ("@waycar_seq", "\"\""),
            ("@waycar_session", "\""),
        ]);
        let state = read_pane(PANE, &Env::default(), &fake).unwrap();
        assert_eq!(state.tty, "ttys021");
        assert_eq!(state.status.as_deref(), Some("working"));
        assert_eq!(state.seq.as_deref(), Some(""));
        assert_eq!(state.session.as_deref(), Some(""));
        // A value holding a line terminator the JS `.` cannot match is not
        // an option line, whatever follows the name.
        for value in ["a\rb", "a\u{2028}b", "a\u{2029}b"] {
            fake.set_pane(&[("@waycar_status", value), ("@waycar_seq", "5")]);
            let state = read_pane(PANE, &Env::default(), &fake).unwrap();
            assert_eq!(
                (state.status, state.seq.as_deref()),
                (None, Some("5")),
                "{value:?}"
            );
        }
    }

    // The hook against a real tmux: the pane's own process has the pane's
    // tty, `/proc` says so, and the options land on the pane.
    #[test]
    fn real_tmux_hook_records_the_session_on_the_pane() {
        use crate::real_tmux::RealTmux;

        let Some(tmux) = RealTmux::start() else {
            return;
        };
        tmux.ok(&["new-session", "-d", "-s", "s", "sleep 60"]);
        let pane = tmux.ok(&["list-panes", "-a", "-F", "#{pane_id}"]);
        let pid: u32 = tmux
            .ok(&["display-message", "-p", "-t", &pane, "#{pane_pid}"])
            .parse()
            .unwrap();
        let mut env = tmux.env.clone();
        env.set("TMUX_PANE", &pane);
        let host = SystemHost { env: &env };
        let payload = r#"{"session_id": "019a;", "transcript_path": "/a b/\u00e9;.jsonl"}"#;

        // An agent on another tty (this test's own parent has none here, or
        // another one) leaves the pane alone.
        run_hook_session(
            "codex",
            "SessionStart",
            payload,
            &env,
            std::process::id(),
            &host,
        );
        assert_eq!(tmux.ok(&["show-options", "-p", "-t", &pane]), "");

        run_hook_session("codex", "SessionStart", payload, &env, pid, &host);
        let option = |name: &str| tmux.ok(&["show-options", "-p", "-v", "-t", &pane, name]);
        assert_eq!(option("@waycar_agent"), "codex");
        assert_eq!(option("@waycar_session"), "019a;");
        assert_eq!(option("@waycar_transcript"), "/a%20b/%C3%A9%3B.jsonl");

        // Only its own session releases the pane, and a release unsets every
        // option.
        run_hook_session(
            "copilot",
            "SessionEnd",
            r#"{"session_id": "other"}"#,
            &env,
            pid,
            &host,
        );
        assert_eq!(option("@waycar_session"), "019a;");
        run_hook_session(
            "copilot",
            "SessionEnd",
            r#"{"session_id": "019a;"}"#,
            &env,
            pid,
            &host,
        );
        assert_eq!(tmux.ok(&["show-options", "-p", "-t", &pane]), "");
    }

    /// The real tmux, with another client's commands run just before the
    /// hook's second tmux call (after its read, before its write).
    struct Racing<'a> {
        system: SystemHost<'a>,
        tmux: &'a crate::real_tmux::RealTmux,
        calls: std::cell::Cell<usize>,
        between: Vec<Vec<&'a str>>,
        notified: RefCell<Vec<String>>,
    }

    impl HookHost for Racing<'_> {
        fn tmux(&self, args: &[&str], env: &Env) -> Option<String> {
            self.calls.set(self.calls.get() + 1);
            if self.calls.get() == 2 {
                for command in &self.between {
                    self.tmux.ok(command);
                }
            }
            self.system.tmux(args, env)
        }
        fn tty(&self, pid: &str) -> String {
            self.system.tty(pid)
        }
        fn ppid(&self, pid: &str) -> String {
            self.system.ppid(pid)
        }
        fn notify(&self, _pane: &str, status: &str, _env: &Env) {
            self.notified.borrow_mut().push(status.to_string());
        }
    }

    #[test]
    fn real_tmux_an_old_session_end_keeps_the_replacing_session() {
        use crate::real_tmux::RealTmux;

        let Some(tmux) = RealTmux::start() else {
            return;
        };
        tmux.ok(&["new-session", "-d", "-s", "s", "sleep 60"]);
        let pane = tmux.ok(&["list-panes", "-a", "-F", "#{pane_id}"]);
        let pid: u32 = tmux
            .ok(&["display-message", "-p", "-t", &pane, "#{pane_pid}"])
            .parse()
            .unwrap();
        let mut env = tmux.env.clone();
        env.set("TMUX_PANE", &pane);
        for (name, value) in [("@waycar_status", "done"), ("@waycar_session", "s 1:old")] {
            tmux.ok(&["set-option", "-p", "-t", &pane, name, value]);
        }
        let host = Racing {
            system: SystemHost { env: &env },
            tmux: &tmux,
            calls: Default::default(),
            between: vec![vec![
                "set-option",
                "-p",
                "-t",
                &pane,
                "@waycar_session",
                "s2",
            ]],
            notified: RefCell::default(),
        };
        run_hook_session(
            "copilot",
            "SessionEnd",
            r#"{"session_id": "s 1:old"}"#,
            &env,
            pid,
            &host,
        );
        let option = |name: &str| tmux.ok(&["show-options", "-p", "-v", "-t", &pane, name]);
        assert_eq!(option("@waycar_session"), "s2");
        assert_eq!(option("@waycar_status"), "done");
        assert!(host.notified.borrow().is_empty());

        // Without a race the same release still clears the pane.
        let host = Racing {
            between: Vec::new(),
            ..host
        };
        run_hook_session(
            "copilot",
            "SessionEnd",
            r#"{"session_id": "s2"}"#,
            &env,
            pid,
            &host,
        );
        assert_eq!(tmux.ok(&["show-options", "-p", "-t", &pane]), "");
        assert_eq!(*host.notified.borrow(), ["release"]);
    }
}
