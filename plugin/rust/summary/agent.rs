//! Agent Summary generation (agent-summary.js, see README.md, "Agent
//! Summary").
//!
//! An Agent Summary is one plain sentence, at most [`SUMMARY_CHAR_MAX`]
//! graphemes, on what an Agent is doing (Working) or where it ended up (Idle,
//! Done, Blocked). The refresh action asks for one about every Agent whose
//! screen changed since its last summary ([`summarize_screen`]); the notify
//! hook asks for one on a Blocked or Done transition
//! ([`generate_agent_summary`]). For a Working Agent the same call also asks
//! for a second line naming its coarse phase (`Phase: implementing`, see
//! [`parse_phase`]), the plan-less Agent Progress.
//!
//! The model is reached through the user's `summary_command` override, or
//! else through the first available provider in [`PROVIDER_ORDER`]: an
//! Anthropic harness (claude, omp), then an OpenAI one (omp's Codex login,
//! codex, the OpenAI API), then OpenRouter, then any other installed harness
//! that can run one tool-free prompt on the user's own login (pi, qwen,
//! gemini, copilot, opencode, kilo, hermes, muse; their default model). Which
//! providers this Host has is detected once and cached in the plugin config
//! dir for an hour. Everything here is best-effort: any failure, timeout, or
//! empty answer yields a null summary.
//!
//! The screen is read with `herdr pane read` (plain text; an alternate-screen
//! TUI yields just its visible screen, which is what the user would see), or
//! for a tmux pane (`tmux:%N`) with `capture-pane` through [`crate::tmux`].
//! The Agent's own pane is only ever read, never typed into or prompted.
//!
//! # Differences from the JS
//!
//! * `readScreen`/`generateAgentSummary` take no injected `run` for the tmux
//!   read (tests only in JS): the Rust tests put a fake `tmux` on `PATH`.
//! * A summary cut at [`SCREEN_CHAR_MAX`] UTF-16 units that lands inside a
//!   surrogate pair keeps a U+FFFD where JS keeps the lone surrogate; Node
//!   encodes that lone surrogate as U+FFFD as soon as it hashes or writes it,
//!   so the bytes hashed and sent are the same.
//! * `fetchImpl` is the [`Fetch`] trait ([`HttpFetch`] is the real one).
//! * The grapheme segmentation is `unicode-segmentation`'s (extended grapheme
//!   clusters) where JS uses ICU's `Intl.Segmenter`; the two can differ for
//!   text newer than one Unicode version.

use std::fs::{self, DirBuilder};
use std::io::{self, Read, Write};
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::os::unix::process::CommandExt;
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use serde_json::{Map, Value, json};
use unicode_segmentation::UnicodeSegmentation;

use crate::atomic::write_atomic;
use crate::chat::shared::{AbortSignal, sha256_hex};
use crate::core as herdr_core;
use crate::env::Env;
use crate::exec::{find_on_path, run_program};
use crate::http;
use crate::jspath;
use crate::jsx;
use crate::tmux;

/// How much of the pane to read, and how much of it to hand the model.
pub const SCREEN_LINES: usize = 60;
const SCREEN_CHAR_MAX: usize = 8000;
/// A summary is one short line; anything past this is a misbehaving harness.
const OUTPUT_BYTE_MAX: usize = 64 * 1024;

/// The summary's own cap; the push and Live Activity display fields keep
/// display-text.js's shorter one.
pub const SUMMARY_CHAR_MAX: usize = 100;

pub const SYSTEM_PROMPT: &str = concat!(
    "You write the status line on a coding agent's card in a phone app, from the agent's terminal screen. ",
    "Reply with exactly one plain sentence of at most 100 characters, ",
    "and nothing else unless the instruction asks for a second line. ",
    "The sentence has no preamble, label, quotes, markdown, or emoji."
);

macro_rules! reply_rule {
    () => {
        "Reply with that sentence only, at most 100 characters."
    };
}

const INSTRUCTION_WORKING: &str = concat!(
    "The coding agent whose terminal screen is on stdin is working right now. ",
    "In present tense, say what it is doing ",
    "(e.g. \"Adding backoff to webhook retries; writing 5xx tests\"), ",
    "at most 100 characters. ",
    "Then write a second line, \"Phase: \" and its stage of work, exactly one of: ",
    "exploring (reading, searching, planning), implementing (editing or writing code), ",
    "verifying (running builds or tests, reviewing diffs), ",
    "wrapping_up (writing the final report, committing or pushing). ",
    "Reply with those two lines only."
);
const INSTRUCTION_IDLE: &str = concat!(
    "The coding agent whose terminal screen is on stdin is idle, waiting for its next task. ",
    "Say its last result and that it is waiting ",
    "(e.g. \"Fixed the flaky login test; waiting for the next task\"). ",
    reply_rule!()
);
const INSTRUCTION_DONE: &str = concat!(
    "The coding agent whose terminal screen is on stdin just finished. ",
    "In past tense, say what it finished or its result ",
    "(e.g. \"Added retry to the upload client; all tests pass\"). ",
    reply_rule!()
);
const INSTRUCTION_BLOCKED: &str = concat!(
    "The coding agent whose terminal screen is on stdin is waiting for the user. ",
    "Say what the user must decide or do ",
    "(e.g. \"Needs approval to merge PR #512 into main\"). ",
    reply_rule!()
);

/// omp's discovery sources, all switched off in its config overlay.
const OMP_DISCOVERY_PROVIDERS: [&str; 17] = [
    "native",
    "omp-plugins",
    "claude",
    "agent-plugins",
    "codex",
    "agents",
    "claude-plugins",
    "gemini",
    "opencode",
    "cursor",
    "windsurf",
    "cline",
    "github",
    "vscode",
    "agents-md",
    "mcp-json",
    "ssh-json",
];
const OMP_OVERLAY_NAME: &str = "agent-summary-omp.yml";
/// gemini's policy file: every tool denied, so the request offers none.
const GEMINI_POLICY: &str = "[[rule]]\ntoolName = \"*\"\ndecision = \"deny\"\npriority = 999\n";
const GEMINI_POLICY_NAME: &str = "agent-summary-gemini-policy.toml";
const MUSE_PROMPT_NAME: &str = "agent-summary-muse-prompt.txt";
/// opencode's and kilo's every built-in tool, switched off in the agent the call runs.
const OPENCODE_TOOLS: [&str; 15] = [
    "*",
    "bash",
    "edit",
    "write",
    "read",
    "grep",
    "glob",
    "list",
    "patch",
    "todowrite",
    "todoread",
    "webfetch",
    "websearch",
    "task",
    "skill",
];
/// The harness's working directory, under the plugin state dir.
const HARNESS_CWD_NAME: &str = "summary-cwd";

/// Provider detection, cached in the plugin config dir; `provider` names the
/// first available one ("none" without any), for the app to report.
pub const PROVIDER_CACHE_NAME: &str = "summary-provider.json";
pub const PROVIDER_CACHE_TTL_MS: i64 = 60 * 60 * 1000;
const DETECT_TIMEOUT: Duration = Duration::from_millis(5000);

const OPENAI_RESPONSES_URL: &str = "https://api.openai.com/v1/responses";
const OPENROUTER_CHAT_URL: &str = "https://openrouter.ai/api/v1/chat/completions";

/// The providers, in the order they are preferred.
pub const PROVIDER_ORDER: [&str; 14] = [
    "claude",
    "omp-anthropic",
    "omp-openai-codex",
    "codex",
    "openai-api",
    "openrouter",
    "pi",
    "qwen",
    "gemini",
    "copilot",
    "opencode",
    "kilo",
    "hermes",
    "muse",
];

// MARK: - Text

/// `summaryInstruction(status)`: the instruction for a status, or `None`
/// when the status is not summarized.
pub fn summary_instruction(status: &str) -> Option<&'static str> {
    match status {
        "working" => Some(INSTRUCTION_WORKING),
        "idle" => Some(INSTRUCTION_IDLE),
        "done" => Some(INSTRUCTION_DONE),
        "blocked" => Some(INSTRUCTION_BLOCKED),
        _ => None,
    }
}

/// `stripAnsi`: CSI (incl. private modes), OSC (BEL or ST terminated), and
/// lone two-byte escapes: enough to flatten a screen or a harness's spinner
/// output. The JS regex is
/// `\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[@-Z\\-_]`.
pub fn strip_ansi(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == 0x1b
            && let Some(end) = escape_end(bytes, i)
        {
            i = end;
            continue;
        }
        out.push(bytes[i]);
        i += 1;
    }
    // Only whole ASCII escape sequences were removed, so the rest is valid UTF-8.
    String::from_utf8(out).unwrap_or_else(|e| String::from_utf8_lossy(e.as_bytes()).into_owned())
}

/// The end of the escape sequence the ESC at `at` starts, in the regex's order.
fn escape_end(bytes: &[u8], at: usize) -> Option<usize> {
    let next = *bytes.get(at + 1)?;
    if next == b'['
        && let Some(end) = csi_end(bytes, at + 2)
    {
        return Some(end);
    }
    if next == b']'
        && let Some(end) = osc_end(bytes, at + 2)
    {
        return Some(end);
    }
    // `[@-Z\\-_]`: @ through Z, and \ through _ (which holds `]` but not `[`).
    matches!(next, b'@'..=b'Z' | b'\\'..=b'_').then_some(at + 2)
}

fn csi_end(bytes: &[u8], mut i: usize) -> Option<usize> {
    while bytes.get(i).is_some_and(|b| (b'0'..=b'?').contains(b)) {
        i += 1;
    }
    while bytes.get(i).is_some_and(|b| (b' '..=b'/').contains(b)) {
        i += 1;
    }
    bytes
        .get(i)
        .is_some_and(|b| (b'@'..=b'~').contains(b))
        .then_some(i + 1)
}

fn osc_end(bytes: &[u8], mut i: usize) -> Option<usize> {
    while bytes.get(i).is_some_and(|b| *b != 0x07 && *b != 0x1b) {
        i += 1;
    }
    match (bytes.get(i), bytes.get(i + 1)) {
        (Some(0x07), _) => Some(i + 1),
        (Some(0x1b), Some(b'\\')) => Some(i + 2),
        _ => None,
    }
}

/// The last `units` UTF-16 units of `text` (`text.slice(text.length - units)`).
/// A cut inside a surrogate pair leaves a lone surrogate in JS, which UTF-8
/// encoding turns into U+FFFD: that is what the result starts with.
fn tail_utf16(text: &str, units: usize) -> String {
    let skip = jsx::utf16_len(text) - units;
    let mut seen = 0;
    for (index, c) in text.char_indices() {
        let width = c.len_utf16();
        if seen + width > skip {
            let rest = &text[index + c.len_utf8()..];
            return if seen == skip {
                text[index..].to_string()
            } else {
                format!("\u{FFFD}{rest}")
            };
        }
        seen += width;
    }
    String::new()
}

/// `normalizeScreen`: flatten a pane read into bounded plain text, or `None`
/// when it is blank.
pub fn normalize_screen(raw: &str) -> Option<String> {
    let stripped = strip_ansi(raw);
    let mut lines: Vec<&str> = stripped.split('\n').map(jsx::trim_end).collect();
    // `split(/\r?\n/)` takes the `\r` of a CRLF with the break; `trimEnd`
    // would have removed it anyway.
    while lines.last() == Some(&"") {
        lines.pop();
    }
    while lines.first() == Some(&"") {
        lines.remove(0);
    }
    if lines.is_empty() {
        return None;
    }
    let text = lines.join("\n");
    Some(if jsx::utf16_len(&text) <= SCREEN_CHAR_MAX {
        text
    } else {
        tail_utf16(&text, SCREEN_CHAR_MAX)
    })
}

/// Spinner glyphs (braille and Claude/Codex-style stars and dots) that
/// animate on a still screen: `[\u2800-\u28FF✻✳✢✶✽✺·•∙⋅◐◓◑◒⠁]`.
fn is_spinner_glyph(c: char) -> bool {
    matches!(
        c,
        '\u{2800}'
            ..='\u{28FF}'
                | '✻'
                | '✳'
                | '✢'
                | '✶'
                | '✽'
                | '✺'
                | '·'
                | '•'
                | '∙'
                | '⋅'
                | '◐'
                | '◓'
                | '◑'
                | '◒'
    )
}

/// `hashableScreen`: the screen with its volatile parts (spinner frames,
/// elapsed timers, token and cost counters) collapsed, so a still Agent keeps
/// one hash.
pub fn hashable_screen(screen: &str) -> String {
    let mut out = String::with_capacity(screen.len());
    let mut in_digits = false;
    for c in screen.chars().filter(|c| !is_spinner_glyph(*c)) {
        if c.is_ascii_digit() {
            if !in_digits {
                out.push('#');
            }
            in_digits = true;
        } else {
            in_digits = false;
            out.push(c);
        }
    }
    out
}

/// `screenHash`: sha256 (hex) of a screen's volatility-normalized form: the
/// refresh skips unchanged screens by it.
pub fn screen_hash(screen: &str) -> String {
    sha256_hex(hashable_screen(screen).as_bytes())
}

fn is_quote(c: char) -> bool {
    matches!(c, '"' | '\'' | '`' | '“' | '”' | '‘' | '’' | '«' | '»')
}

fn strip_wrapping_quotes(text: &str) -> String {
    let mut s = text;
    loop {
        let mut chars = s.chars();
        let (Some(first), Some(last)) = (chars.next(), chars.next_back()) else {
            return s.to_string();
        };
        if !(is_quote(first) && is_quote(last)) {
            return s.to_string();
        }
        s = jsx::trim(&s[first.len_utf8()..s.len() - last.len_utf8()]);
    }
}

/// Extended grapheme clusters (`Intl.Segmenter` with `granularity: "grapheme"`).
pub fn graphemes(text: &str) -> Vec<&str> {
    text.graphemes(true).collect()
}

/// `capSummary`: trim to [`SUMMARY_CHAR_MAX`] graphemes, ellipsis included;
/// whole emoji stay whole.
pub fn cap_summary(text: &str) -> String {
    let parts = graphemes(text);
    if parts.len() <= SUMMARY_CHAR_MAX {
        return text.to_string();
    }
    let kept: String = parts[..SUMMARY_CHAR_MAX - 1].concat();
    format!("{}…", jsx::trim_end(&kept))
}

fn strip_prefix_ci<'a>(text: &'a str, prefix: &str) -> Option<&'a str> {
    let head = text.as_bytes().get(..prefix.len())?;
    head.eq_ignore_ascii_case(prefix.as_bytes())
        .then(|| &text[prefix.len()..])
}

fn is_word_byte(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'_'
}

/// `PROGRESS_LINE`: `^(working|thinking|loading)\b[.…\s]*$` (`i`).
fn is_progress_line(line: &str) -> bool {
    ["working", "thinking", "loading"]
        .iter()
        .filter_map(|word| strip_prefix_ci(line, word))
        .any(|rest| {
            rest.chars()
                .all(|c| c == '.' || c == '…' || jsx::is_js_space(c))
        })
}

/// `rest` without its leading whitespace, when it had some (`\s+`).
fn after_space(rest: &str) -> Option<&str> {
    let trimmed = jsx::trim_start(rest);
    (trimmed.len() < rest.len()).then_some(trimmed)
}

/// `s.replace(LEAD_MARKER, "")`: `^(?:#{1,6}\s+|[-*•>]\s+|\d+[.)]\s+)`.
fn strip_lead_marker(s: &str) -> &str {
    let hashes = s.bytes().take_while(|b| *b == b'#').count();
    if (1..=6).contains(&hashes)
        && let Some(rest) = after_space(&s[hashes..])
    {
        return rest;
    }
    let mut chars = s.chars();
    if let Some(first) = chars.next()
        && matches!(first, '-' | '*' | '•' | '>')
        && let Some(rest) = after_space(chars.as_str())
    {
        return rest;
    }
    let digits = s.bytes().take_while(u8::is_ascii_digit).count();
    if digits > 0
        && matches!(s.as_bytes().get(digits), Some(b'.' | b')'))
        && let Some(rest) = after_space(&s[digits + 1..])
    {
        return rest;
    }
    s
}

/// `.replace(/\*\*|__|`/g, "")`.
fn strip_markup(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(c) = rest.chars().next() {
        if rest.starts_with("**") || rest.starts_with("__") {
            rest = &rest[2..];
        } else if c == '`' {
            rest = &rest[1..];
        } else {
            out.push(c);
            rest = &rest[c.len_utf8()..];
        }
    }
    out
}

fn is_dash(c: char) -> bool {
    matches!(c, ':' | '-' | '–' | '—')
}

/// `s.replace(LABEL_PREFIX, "")`:
/// `^(?:summary|result|status|done|blocked|working|idle)\s*[:\-–—]\s*` (`i`).
fn strip_label_prefix(s: &str) -> &str {
    for word in [
        "summary", "result", "status", "done", "blocked", "working", "idle",
    ] {
        if let Some(rest) = strip_prefix_ci(s, word) {
            let rest = jsx::trim_start(rest);
            let mut chars = rest.chars();
            if chars.next().is_some_and(is_dash) {
                return jsx::trim_start(chars.as_str());
            }
        }
    }
    s
}

/// `PHASE_LINE.exec(line)?.[1]`:
/// `^phase\s*[:\-–—]\s*(exploring|implementing|verifying|wrapping[_ -]?up)\b` (`i`).
fn phase_match(line: &str) -> Option<&str> {
    let rest = jsx::trim_start(strip_prefix_ci(line, "phase")?);
    let mut chars = rest.chars();
    if !is_dash(chars.next()?) {
        return None;
    }
    let rest = jsx::trim_start(chars.as_str());
    let len = phase_word_len(rest)?;
    (!rest.as_bytes().get(len).is_some_and(|b| is_word_byte(*b))).then(|| &rest[..len])
}

/// The length of the phase word `rest` starts with (the alternation inside
/// `PHASE_LINE`, before its `\b`).
fn phase_word_len(rest: &str) -> Option<usize> {
    for word in ["exploring", "implementing", "verifying"] {
        if strip_prefix_ci(rest, word).is_some() {
            return Some(word.len());
        }
    }
    let after = strip_prefix_ci(rest, "wrapping")?;
    let tail = after
        .strip_prefix(['_', ' ', '-'])
        .and_then(|r| strip_prefix_ci(r, "up"))
        .or_else(|| strip_prefix_ci(after, "up"))?;
    Some(rest.len() - tail.len())
}

/// `answerLines`: an answer's lines with markdown decoration and wrapping
/// quotes stripped.
fn answer_lines(raw: &str) -> Vec<String> {
    let stripped = strip_ansi(raw);
    let mut segments = Vec::new();
    let mut start = 0;
    let bytes = stripped.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'\r' if bytes.get(i + 1) == Some(&b'\n') => {
                segments.push(&stripped[start..i]);
                i += 2;
                start = i;
            }
            b'\r' | b'\n' => {
                segments.push(&stripped[start..i]);
                i += 1;
                start = i;
            }
            _ => i += 1,
        }
    }
    segments.push(&stripped[start..]);

    let mut lines = Vec::new();
    for segment in segments {
        let s = collapse_whitespace(segment);
        let s = jsx::trim(&s);
        if s.is_empty() || is_progress_line(s) {
            continue;
        }
        let decorated = strip_markup(strip_lead_marker(s));
        lines.push(strip_wrapping_quotes(jsx::trim(&decorated)));
    }
    lines
}

/// `.replace(/\s+/g, " ")`.
fn collapse_whitespace(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut in_space = false;
    for c in text.chars() {
        if jsx::is_js_space(c) {
            if !in_space {
                out.push(' ');
            }
            in_space = true;
        } else {
            in_space = false;
            out.push(c);
        }
    }
    out
}

/// `sanitizeSummary`: reduce a model's answer to the summary line: the first
/// line with real content, minus progress chatter ("Working..."), the phase
/// line, markdown decoration, a leading "Blocked:"-style label (the app
/// renders the status itself), wrapping quotes, and a trailing period;
/// capped at [`SUMMARY_CHAR_MAX`]. `None` when nothing usable is left.
pub fn sanitize_summary(raw: &str) -> Option<String> {
    for line in answer_lines(raw) {
        if phase_match(&line).is_some() {
            continue;
        }
        let s = strip_wrapping_quotes(strip_label_prefix(&line));
        let s = jsx::trim(s.trim_end_matches(['.', '。']));
        if !s.is_empty() {
            return Some(cap_summary(s));
        }
    }
    None
}

/// `parsePhase`: the phase a Working answer names on its `Phase: …` line,
/// or `None` when it names none (a `summary_command` that ignores the request).
pub fn parse_phase(raw: &str) -> Option<&'static str> {
    for line in answer_lines(raw) {
        if let Some(phase) = phase_match(&line) {
            let lower = phase.to_ascii_lowercase();
            return Some(match lower.as_str() {
                "exploring" => "exploring",
                "implementing" => "implementing",
                "verifying" => "verifying",
                _ => "wrapping_up",
            });
        }
    }
    None
}

// MARK: - Processes

struct ProcessResult {
    /// `None`: spawn failure, abort, or killed by a signal (JS `null`).
    code: Option<i32>,
    stdout: String,
    stderr: String,
}

struct ProcessSpec<'a> {
    argv: &'a [String],
    input: Option<&'a str>,
    signal: &'a AbortSignal,
    env: &'a Env,
    cwd: Option<&'a str>,
    capture_stderr: bool,
}

const POLL: Duration = Duration::from_millis(2);

fn aborted_result() -> ProcessResult {
    ProcessResult {
        code: None,
        stdout: String::new(),
        stderr: String::new(),
    }
}

/// libuv looks a bare name up in the child's own `PATH` (the C library's
/// default without one).
fn resolve_program(name: &str, env: &Env, cwd: Option<&str>) -> Option<String> {
    if name.contains('/') {
        return Some(match cwd {
            Some(cwd) if !name.starts_with('/') => jspath::join(&[cwd, name]),
            _ => name.to_string(),
        });
    }
    let mut lookup = env.clone();
    if lookup.get("PATH").is_none() {
        lookup.set("PATH", "/usr/bin:/bin");
    }
    find_on_path(name, &lookup).map(|path| path.to_string_lossy().into_owned())
}

/// Collect a pipe like the JS `data` handler: chunks are appended while less
/// than [`OUTPUT_BYTE_MAX`] units are held, the pipe is drained to the end.
fn collect(mut pipe: impl Read + Send + 'static) -> thread::JoinHandle<Vec<u8>> {
    thread::spawn(move || {
        let mut kept = Vec::new();
        let mut units = 0;
        let mut buf = vec![0u8; 64 * 1024];
        loop {
            match pipe.read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    if units < OUTPUT_BYTE_MAX {
                        kept.extend_from_slice(&buf[..n]);
                        units = jsx::utf16_len(&String::from_utf8_lossy(&kept));
                    }
                }
            }
        }
        kept
    })
}

fn kill_group(child: &mut std::process::Child) {
    // SAFETY: plain syscall on the child's process group.
    let killed = unsafe { libc::kill(-(child.id() as i32), libc::SIGKILL) };
    if killed != 0 {
        let _ = child.kill();
    }
}

/// `runProcess`: run one child to completion: stdin written from `input`,
/// stdout collected (bounded). Never fails: a spawn failure (missing binary)
/// or an abort gives `code: None`.
///
/// The child leads its own session and process group, and an abort SIGKILLs
/// the whole group: a harness's helpers must not outlive the budget, nor hold
/// its stdout open and keep the hook waiting.
fn run_process(spec: &ProcessSpec<'_>) -> ProcessResult {
    if spec.signal.is_aborted() {
        return aborted_result();
    }
    let Some(name) = spec.argv.first() else {
        return aborted_result();
    };
    let Some(program) = resolve_program(name, spec.env, spec.cwd) else {
        return aborted_result();
    };
    let mut command = Command::new(program);
    command
        .arg0(name)
        .args(&spec.argv[1..])
        .env_clear()
        .envs(spec.env.iter())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(if spec.capture_stderr {
            Stdio::piped()
        } else {
            Stdio::null()
        });
    if let Some(cwd) = spec.cwd {
        command.current_dir(cwd);
    }
    // SAFETY: setsid is async-signal-safe and touches no memory of ours.
    unsafe {
        command.pre_exec(|| {
            libc::setsid();
            Ok(())
        });
    }
    let Ok(mut child) = command.spawn() else {
        return aborted_result();
    };
    let stdout = child.stdout.take().map(collect);
    let stderr = child.stderr.take().map(collect);
    // A harness that exits without draining stdin must not crash the hook.
    if let Some(mut stdin) = child.stdin.take() {
        let input = spec.input.unwrap_or("").as_bytes().to_vec();
        thread::spawn(move || {
            let _ = stdin.write_all(&input);
        });
    }
    let mut exit = None;
    loop {
        if spec.signal.is_aborted() {
            kill_group(&mut child);
            let _ = child.wait();
            return aborted_result();
        }
        if exit.is_none() {
            match child.try_wait() {
                Ok(status) => exit = status,
                Err(_) => return aborted_result(),
            }
        }
        let drained = stdout.as_ref().is_none_or(|h| h.is_finished())
            && stderr.as_ref().is_none_or(|h| h.is_finished());
        if exit.is_some() && drained {
            break;
        }
        thread::sleep(POLL);
    }
    let text = |handle: Option<thread::JoinHandle<Vec<u8>>>| {
        handle
            .and_then(|h| h.join().ok())
            .map(|bytes| String::from_utf8_lossy(&bytes).into_owned())
            .unwrap_or_default()
    };
    let code = exit.and_then(|status| status.code());
    ProcessResult {
        code: if spec.signal.is_aborted() { None } else { code },
        stdout: text(stdout),
        stderr: text(stderr),
    }
}

/// A CLI harness: the instruction as an argument, the screen on stdin. Its
/// stdout on exit 0, else `None`.
fn run_harness(
    argv: &[String],
    screen: &str,
    signal: &AbortSignal,
    env: &Env,
    cwd: &str,
) -> Option<String> {
    let result = run_process(&ProcessSpec {
        argv,
        input: Some(screen),
        signal,
        env,
        cwd: Some(cwd),
        capture_stderr: false,
    });
    (result.code == Some(0)).then_some(result.stdout)
}

fn strings<const N: usize>(items: [&str; N]) -> Vec<String> {
    items.iter().map(|s| (*s).to_string()).collect()
}

// MARK: - Signals

/// A signal that aborts when any parent aborts or after `timeout`
/// (`AbortSignal.any` / `AbortSignal.timeout`); dropping it stops the
/// watcher thread.
pub struct LinkedSignal {
    pub signal: Arc<AbortSignal>,
    stop: Arc<AtomicBool>,
}

impl Drop for LinkedSignal {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
    }
}

pub fn linked_signal(parents: &[Arc<AbortSignal>], timeout: Option<Duration>) -> LinkedSignal {
    let signal = AbortSignal::new();
    // `AbortSignal.any` is aborted at once when a parent already is; the
    // watcher thread below only catches aborts that come later.
    if parents.iter().any(|parent| parent.is_aborted()) {
        signal.abort("aborted");
    }
    let stop = Arc::new(AtomicBool::new(false));
    let parents = parents.to_vec();
    let watched = (Arc::clone(&signal), Arc::clone(&stop));
    let started = Instant::now();
    thread::spawn(move || {
        let (signal, stop) = watched;
        while !stop.load(Ordering::SeqCst) && !signal.is_aborted() {
            if parents.iter().any(|parent| parent.is_aborted()) {
                signal.abort("aborted");
                return;
            }
            if timeout.is_some_and(|limit| started.elapsed() >= limit) {
                signal.abort("The operation was aborted due to timeout");
                return;
            }
            thread::sleep(Duration::from_millis(2));
        }
    });
    LinkedSignal { signal, stop }
}

// MARK: - Screen

/// `readScreen(binPath, paneId, signal, {env})`: read the Agent's screen;
/// `None` when unreadable, blank, or aborted. herdr panes go through the
/// herdr CLI at `bin_path`; `tmux:` panes through [`tmux::read_pane`], with
/// `env` (its `TMUX` picks the server); `hc:` terminals through
/// `herdr-core read`, found from `env`.
pub fn read_screen(
    bin_path: &str,
    pane_id: &str,
    signal: &AbortSignal,
    env: &Env,
) -> Option<String> {
    if tmux::is_tmux_pane_id(pane_id) {
        return read_tmux_screen(pane_id, signal, env);
    }
    if herdr_core::is_core_pane_id(pane_id) {
        return read_core_screen(pane_id, signal, env);
    }
    let argv = [
        bin_path,
        "pane",
        "read",
        pane_id,
        "--source",
        "recent",
        "--lines",
        &SCREEN_LINES.to_string(),
    ]
    .map(String::from);
    let result = run_process(&ProcessSpec {
        argv: &argv,
        input: None,
        signal,
        env,
        cwd: None,
        capture_stderr: false,
    });
    if result.code != Some(0) {
        return None;
    }
    normalize_screen(&result.stdout)
}

/// `readTmuxScreen`: the tmux read raced against `signal`; failures and
/// aborts read as `None`.
fn read_tmux_screen(pane_id: &str, signal: &AbortSignal, env: &Env) -> Option<String> {
    if signal.is_aborted() {
        return None;
    }
    let (sender, receiver) = mpsc::channel();
    let (pane, env) = (pane_id.to_string(), env.clone());
    thread::spawn(move || {
        let _ = sender.send(tmux::read_pane(&pane, SCREEN_LINES as i64, &env).ok());
    });
    await_screen(&receiver, signal)
}

/// The herdr-core read, raced against `signal` like tmux's: the terminal's
/// screen with [`SCREEN_LINES`] of history, through the `herdr-core` the
/// environment finds (a core terminal's own `HC_TERMINAL_SOCKET` keeps it
/// from starting another core). Failures and aborts read as `None`.
fn read_core_screen(pane_id: &str, signal: &AbortSignal, env: &Env) -> Option<String> {
    if signal.is_aborted() {
        return None;
    }
    let (sender, receiver) = mpsc::channel();
    let (address, env) = (
        herdr_core::to_core_address(pane_id).to_string(),
        env.clone(),
    );
    thread::spawn(move || {
        let home = home_of(&env);
        let screen = herdr_core::running_core(&env, std::path::Path::new(&home), &run_program)
            .and_then(|core| {
                herdr_core::read_recent(&core, &run_program, &address, SCREEN_LINES).ok()
            });
        let _ = sender.send(screen);
    });
    await_screen(&receiver, signal)
}

/// A screen read in another thread, awaited until it answers or `signal`
/// aborts; blank screens read as `None`.
fn await_screen(receiver: &mpsc::Receiver<Option<String>>, signal: &AbortSignal) -> Option<String> {
    loop {
        match receiver.recv_timeout(POLL) {
            Ok(raw) => return raw.and_then(|raw| normalize_screen(&raw)),
            Err(mpsc::RecvTimeoutError::Timeout) if !signal.is_aborted() => {}
            Err(_) => return None,
        }
    }
}

// MARK: - Providers

/// `homeOf`: `env.HOME || homedir()`.
fn home_of(env: &Env) -> String {
    env.non_empty("HOME").map_or_else(
        || {
            std::env::home_dir()
                .map(|p| p.to_string_lossy().into_owned())
                .unwrap_or_default()
        },
        str::to_string,
    )
}

/// `onPath`: whether `name` is an executable in one of `env.PATH`'s directories.
fn on_path(name: &str, env: &Env) -> bool {
    env.get("PATH").unwrap_or("").split(':').any(|dir| {
        if dir.is_empty() {
            return false;
        }
        let Ok(path) = std::ffi::CString::new(jspath::join(&[dir, name])) else {
            return false;
        };
        // SAFETY: `path` is a valid NUL-terminated string for the call.
        unsafe { libc::access(path.as_ptr(), libc::X_OK) == 0 }
    })
}

/// A JSON object from a config file, or `None` when it is missing or not JSON.
fn read_json_file(path: &str) -> Option<Value> {
    let bytes = fs::read(path).ok()?;
    jsx::parse_json(&String::from_utf8_lossy(&bytes)).filter(Value::is_object)
}

fn read_text_file(path: &str) -> Option<String> {
    fs::read(path)
        .ok()
        .map(|bytes| String::from_utf8_lossy(&bytes).into_owned())
}

fn has_anthropic_key(env: &Env) -> bool {
    env.non_empty("ANTHROPIC_API_KEY").is_some() || env.non_empty("ANTHROPIC_OAUTH_TOKEN").is_some()
}

/// Run a detection probe (stdin closed); its exit code, stdout, and stderr.
fn probe(argv: &[&str], env: &Env, cwd: &str) -> ProcessResult {
    let timeout = linked_signal(&[], Some(DETECT_TIMEOUT));
    let argv: Vec<String> = argv.iter().map(|s| (*s).to_string()).collect();
    run_process(&ProcessSpec {
        argv: &argv,
        input: None,
        signal: &timeout.signal,
        env,
        cwd: Some(cwd),
        capture_stderr: true,
    })
}

/// A provider's detection: unavailable, available, or available with detail.
enum Detected {
    No,
    Yes,
    Detail(Value),
}

impl From<bool> for Detected {
    fn from(found: bool) -> Self {
        if found { Self::Yes } else { Self::No }
    }
}

fn stdout_field_is(result: &ProcessResult, key: &str, expected: Value) -> bool {
    jsx::parse_json(&result.stdout).is_some_and(|value| *jsx::field(&value, key) == expected)
}

/// opencode or kilo: a model or provider the user configured, or a stored
/// credential. kilo with neither would answer through its anonymous gateway,
/// which is not the user's own account.
fn opencode_configured(name: &str, env: &Env) -> bool {
    let home = home_of(env);
    let config_dir = match env.non_empty("XDG_CONFIG_HOME") {
        Some(base) => jspath::join(&[base, name]),
        None => jspath::join(&[&home, ".config", name]),
    };
    let data_dir = match env.non_empty("XDG_DATA_HOME") {
        Some(base) => jspath::join(&[base, name]),
        None => jspath::join(&[&home, ".local", "share", name]),
    };
    let file = if name == "kilo" {
        "kilo.json"
    } else {
        "opencode.json"
    };
    let config = read_json_file(&jspath::join(&[&config_dir, file]));
    let auth = read_json_file(&jspath::join(&[&data_dir, "auth.json"]));
    let config = config.unwrap_or(Value::Null);
    let provider = jsx::field(&config, "provider");
    jsx::field(&config, "model").is_string()
        || matches!(provider, Value::Object(_) | Value::Array(_))
        || auth
            .as_ref()
            .and_then(Value::as_object)
            .is_some_and(|auth| !auth.is_empty())
}

/// Whether hermes's config.yaml names a provider under its top-level `model:` block.
fn hermes_provider_configured(config: &str) -> bool {
    let mut in_model = false;
    for line in config.split('\n') {
        let body = jsx::trim_start(line);
        if body.is_empty() || body.starts_with('#') {
            continue;
        }
        if !line.chars().next().is_some_and(jsx::is_js_space) {
            in_model = line
                .strip_prefix("model:")
                .is_some_and(|rest| rest.chars().all(jsx::is_js_space));
            continue;
        }
        if !in_model {
            continue;
        }
        // /^\s+provider:\s*["']?([^\s"'#]+)/
        let Some(rest) = body.strip_prefix("provider:") else {
            continue;
        };
        let rest = jsx::trim_start(rest);
        let rest = rest.strip_prefix(['"', '\'']).unwrap_or(rest);
        if rest
            .chars()
            .next()
            .is_some_and(|c| !jsx::is_js_space(c) && !matches!(c, '"' | '\'' | '#'))
        {
            return true;
        }
    }
    false
}

fn detect(id: &str, env: &Env, cwd: &str) -> Detected {
    match id {
        "claude" => {
            if !on_path("claude", env) {
                return Detected::No;
            }
            if has_anthropic_key(env) {
                return Detected::Yes;
            }
            let result = probe(&["claude", "auth", "status"], env, cwd);
            stdout_field_is(&result, "loggedIn", Value::Bool(true)).into()
        }
        "omp-anthropic" => {
            if !on_path("omp", env) {
                return Detected::No;
            }
            if has_anthropic_key(env) {
                return Detected::Yes;
            }
            (probe(&["omp", "token", "anthropic", "--list"], env, cwd).code == Some(0)).into()
        }
        "omp-openai-codex" => (on_path("omp", env)
            && probe(&["omp", "token", "openai-codex", "--list"], env, cwd).code == Some(0))
        .into(),
        "codex" => {
            if !on_path("codex", env) {
                return Detected::No;
            }
            let result = probe(&["codex", "login", "status"], env, cwd);
            if result.code != Some(0) {
                return Detected::No;
            }
            // An API-key login pays per token: use the cheapest API model.
            // The real CLI prints its status on stderr.
            let both = format!("{}\n{}", result.stdout, result.stderr).to_ascii_lowercase();
            let model = if both.contains("api key") {
                "gpt-5-nano"
            } else {
                "gpt-6-luna"
            };
            Detected::Detail(json!({ "model": model }))
        }
        "openai-api" => env.non_empty("OPENAI_API_KEY").is_some().into(),
        "openrouter" => env.non_empty("OPENROUTER_API_KEY").is_some().into(),
        "pi" => {
            if !on_path("pi", env) {
                return Detected::No;
            }
            let agent_dir = match env.non_empty("PI_CODING_AGENT_DIR") {
                Some(dir) => dir.to_string(),
                None => jspath::join(&[&home_of(env), ".pi", "agent"]),
            };
            let settings = read_json_file(&jspath::join(&[&agent_dir, "settings.json"]));
            let provider = settings
                .as_ref()
                .map(|s| jsx::field(s, "defaultProvider"))
                .and_then(Value::as_str)
                .filter(|p| !p.is_empty());
            let Some(provider) = provider else {
                return Detected::No;
            };
            // `--no-refresh`: an expired OAuth token is not refreshed over the network.
            let result = probe(
                &[
                    "pi",
                    "auth",
                    "check",
                    "--provider",
                    provider,
                    "--no-refresh",
                    "--json",
                ],
                env,
                cwd,
            );
            (result.code == Some(0) && stdout_field_is(&result, "status", json!("ready"))).into()
        }
        "qwen" => {
            // The Qwen OAuth free tier ended 2026-04-15; any other auth type is
            // the user's own provider.
            if !on_path("qwen", env) {
                return Detected::No;
            }
            let settings =
                read_json_file(&jspath::join(&[&home_of(env), ".qwen", "settings.json"]))
                    .unwrap_or(Value::Null);
            let kind = jsx::field(
                jsx::field(jsx::field(&settings, "security"), "auth"),
                "selectedType",
            );
            kind.as_str()
                .is_some_and(|kind| kind != "qwen-oauth")
                .into()
        }
        "gemini" => {
            if !on_path("gemini", env) {
                return Detected::No;
            }
            if env.non_empty("GEMINI_API_KEY").is_some() {
                return Detected::Yes;
            }
            let settings =
                read_json_file(&jspath::join(&[&home_of(env), ".gemini", "settings.json"]))
                    .unwrap_or(Value::Null);
            jsx::field(
                jsx::field(jsx::field(&settings, "security"), "auth"),
                "selectedType",
            )
            .is_string()
            .into()
        }
        "copilot" => {
            // BYOK or a token in the environment; a `copilot login` stored
            // elsewhere is not detected.
            (on_path("copilot", env)
                && [
                    "COPILOT_PROVIDER_BASE_URL",
                    "COPILOT_GITHUB_TOKEN",
                    "GH_TOKEN",
                    "GITHUB_TOKEN",
                ]
                .iter()
                .any(|name| env.non_empty(name).is_some()))
            .into()
        }
        "opencode" => (on_path("opencode", env) && opencode_configured("opencode", env)).into(),
        "kilo" => (on_path("kilo", env) && opencode_configured("kilo", env)).into(),
        "hermes" => {
            if !on_path("hermes", env) {
                return Detected::No;
            }
            let home = match env.non_empty("HERMES_HOME") {
                Some(home) => home.to_string(),
                None => jspath::join(&[&home_of(env), ".hermes"]),
            };
            read_text_file(&jspath::join(&[&home, "config.yaml"]))
                .is_some_and(|config| hermes_provider_configured(&config))
                .into()
        }
        "muse" => {
            // An API key in the environment or a stored credential (`muse
            // auth set`, `muse login`) in Muse's auth file.
            if !on_path("muse", env) {
                return Detected::No;
            }
            if env.non_empty("META_API_KEY").is_some() {
                return Detected::Yes;
            }
            let config_home = match env.non_empty("XDG_CONFIG_HOME") {
                Some(home) => home.to_string(),
                None => jspath::join(&[&home_of(env), ".config"]),
            };
            let auth = read_json_file(&jspath::join(&[&config_home, "muse", "auth.json"]))
                .unwrap_or(Value::Null);
            match jsx::field(&auth, "providers") {
                Value::Object(map) => !map.is_empty(),
                Value::Array(items) => !items.is_empty(),
                _ => false,
            }
            .into()
        }
        _ => Detected::No,
    }
}

fn random_bytes<const N: usize>() -> io::Result<[u8; N]> {
    let mut bytes = [0u8; N];
    fs::File::open("/dev/urandom")?.read_exact(&mut bytes)?;
    Ok(bytes)
}

fn hex(bytes: &[u8]) -> String {
    use std::fmt::Write as _;
    bytes.iter().fold(String::new(), |mut out, byte| {
        let _ = write!(out, "{byte:02x}");
        out
    })
}

/// `randomUUID()`: a version 4 UUID.
fn random_uuid() -> io::Result<String> {
    let mut b = random_bytes::<16>()?;
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    Ok(format!(
        "{}-{}-{}-{}-{}",
        hex(&b[0..4]),
        hex(&b[4..6]),
        hex(&b[6..8]),
        hex(&b[8..10]),
        hex(&b[10..16])
    ))
}

fn prompt_text(instruction: &str, screen: &str) -> String {
    format!("{SYSTEM_PROMPT}\n\n{instruction}\n\nTerminal screen:\n{screen}")
}

/// The omp config overlay: memory recall and WATCHDOG advisors off (a
/// one-shot call must not pay ~20 s for them), no project-level MCP servers,
/// and every discovery source switched off.
fn omp_overlay() -> String {
    let mut overlay = String::from(
        "memory:\n  backend: off\nadvisor:\n  enabled: false\nmcp:\n  enableProjectConfig: false\ndisabledProviders:\n",
    );
    for id in OMP_DISCOVERY_PROVIDERS {
        overlay.push_str(&format!("  - {id}\n"));
    }
    overlay
}

/// The harness's working directory: an empty directory only this user can
/// enter. Both CLIs treat their cwd as a project and load its config, so a
/// shared one such as /tmp would let another local account run code as the
/// Host user. Nothing ever writes into it.
fn harness_cwd(work_dir: &str) -> io::Result<String> {
    let path = jspath::join(&[work_dir, HARNESS_CWD_NAME]);
    DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&path)?;
    fs::set_permissions(&path, fs::Permissions::from_mode(0o700))?;
    Ok(path)
}

fn omp_argv(
    work_dir: &str,
    model: &str,
    thinking: &str,
    instruction: &str,
) -> io::Result<Vec<String>> {
    let overlay = jspath::join(&[work_dir, OMP_OVERLAY_NAME]);
    write_atomic(
        std::path::Path::new(&overlay),
        omp_overlay().as_bytes(),
        0o600,
    )?;
    Ok(vec![
        "omp".into(),
        "-p".into(),
        "--config".into(),
        overlay,
        "--no-tools".into(),
        "--approval-mode=always-ask".into(),
        "--no-session".into(),
        "--no-lsp".into(),
        "--no-extensions".into(),
        "--no-skills".into(),
        "--no-rules".into(),
        "--no-title".into(),
        format!("--thinking={thinking}"),
        format!("--system-prompt={SYSTEM_PROMPT}"),
        "--model".into(),
        model.into(),
        instruction.into(),
    ])
}

/// What a provider's `run` gets (JS: its destructured options).
struct RunCtx<'a> {
    instruction: &'a str,
    screen: &'a str,
    work_dir: &'a str,
    detail: Option<&'a Value>,
    signal: &'a AbortSignal,
    env: &'a Env,
    cwd: &'a str,
    fetch: &'a dyn Fetch,
}

impl RunCtx<'_> {
    fn harness(&self, argv: &[String], screen: &str) -> Option<String> {
        run_harness(argv, screen, self.signal, self.env, self.cwd)
    }
}

/// `runOpencodeLike`: `opencode run`/`kilo run` with every tool off in
/// `agent` (its config passed through `variable`), screen on stdin.
fn run_opencode_like(
    binary: &str,
    agent: &str,
    variable: &str,
    ctx: &RunCtx<'_>,
) -> Option<String> {
    let off: Map<String, Value> = OPENCODE_TOOLS
        .iter()
        .map(|tool| ((*tool).to_string(), Value::Bool(false)))
        .collect();
    let config = json!({
        "share": "disabled",
        "autoupdate": false,
        "tools": off.clone(),
        "agent": { agent: { "tools": off } },
    });
    let mut env = ctx.env.clone();
    env.set(variable, jsx::stringify(&config));
    let argv = strings([binary, "run", "--pure", "--agent", agent, ctx.instruction]);
    run_harness(&argv, ctx.screen, ctx.signal, &env, ctx.cwd)
}

/// The text of a JS value used as a process argument (`String(value)`).
fn js_string(value: &Value) -> String {
    match value {
        Value::String(s) => s.clone(),
        Value::Number(n) => jsx::number_to_string(jsx::json_f64(n)),
        Value::Bool(b) => b.to_string(),
        Value::Null => "null".into(),
        Value::Array(items) => items
            .iter()
            .map(|item| {
                if item.is_null() {
                    String::new()
                } else {
                    js_string(item)
                }
            })
            .collect::<Vec<_>>()
            .join(","),
        Value::Object(_) => "[object Object]".into(),
    }
}

/// The answer of one provider (`PROVIDERS[id].run`); `None` is a failure or a
/// provider that could not be prepared (the JS throws or yields null).
fn run_provider(id: &str, ctx: &RunCtx<'_>) -> Option<String> {
    let instruction = ctx.instruction;
    match id {
        // `--tools` and `--disallowedTools` are variadic: another option must
        // follow each, or it would swallow the next argument.
        "claude" => ctx.harness(
            &strings([
                "claude",
                "-p",
                "--tools",
                "",
                "--disallowedTools",
                "mcp__*",
                "--setting-sources",
                "user",
                "--strict-mcp-config",
                "--no-session-persistence",
                "--model",
                "haiku",
                "--system-prompt",
                SYSTEM_PROMPT,
                instruction,
            ]),
            ctx.screen,
        ),
        "omp-anthropic" => ctx.harness(
            &omp_argv(
                ctx.work_dir,
                "anthropic/claude-haiku-4-5",
                "off",
                instruction,
            )
            .ok()?,
            ctx.screen,
        ),
        "omp-openai-codex" => ctx.harness(
            &omp_argv(ctx.work_dir, "openai-codex/gpt-6-luna", "low", instruction).ok()?,
            ctx.screen,
        ),
        "codex" => run_codex(ctx),
        "openai-api" => {
            let body = json!({
                "model": "gpt-5-nano",
                "instructions": SYSTEM_PROMPT,
                "input": format!("{instruction}\n\nTerminal screen:\n{}", ctx.screen),
                "reasoning": { "effort": "minimal" },
                "max_output_tokens": 200,
                "store": false,
            });
            let key = ctx.env.get("OPENAI_API_KEY").unwrap_or("undefined");
            let body = ctx
                .fetch
                .post_json(OPENAI_RESPONSES_URL, key, &body, ctx.signal)?;
            // `output.flatMap(content arrays).find(output_text)?.text`
            let output = jsx::field(&body, "output").as_array()?;
            output
                .iter()
                .filter_map(|item| jsx::field(item, "content").as_array())
                .flatten()
                .find(|part| jsx::field(part, "type") == "output_text")
                .and_then(|part| jsx::field(part, "text").as_str())
                .map(str::to_string)
        }
        "openrouter" => {
            let body = json!({
                "models": ["google/gemini-2.5-flash-lite", "openai/gpt-6-luna"],
                "messages": [
                    { "role": "system", "content": SYSTEM_PROMPT },
                    {
                        "role": "user",
                        "content": format!("{instruction}\n\nTerminal screen:\n{}", ctx.screen),
                    },
                ],
                "max_tokens": 60,
                "temperature": 0.2,
                "reasoning": { "exclude": true },
            });
            let key = ctx.env.get("OPENROUTER_API_KEY").unwrap_or("undefined");
            let body = ctx
                .fetch
                .post_json(OPENROUTER_CHAT_URL, key, &body, ctx.signal)?;
            let choices = jsx::field(&body, "choices");
            let first = match choices {
                Value::Array(items) => items.first(),
                Value::Object(map) => map.get("0"),
                _ => None,
            }?;
            jsx::field(jsx::field(first, "message"), "content")
                .as_str()
                .map(str::to_string)
        }
        // The harnesses below answer with the user's own default model. Each
        // one is locked down so the model has no tool it can run.
        //
        // pi joins stdin and the message with no separator: the screen ends
        // in a blank line.
        "pi" => ctx.harness(
            &strings([
                "pi",
                "-p",
                "--no-tools",
                "--no-session",
                "--no-extensions",
                "--no-mcp",
                "--no-skills",
                "--no-prompt-templates",
                "--no-themes",
                "--no-context-files",
                "--no-approve",
                "--offline",
                "--system-prompt",
                SYSTEM_PROMPT,
                instruction,
            ]),
            &format!("Terminal screen:\n{}\n\n", ctx.screen),
        ),
        // qwen offers read-only tools even in plan mode, so `--max-tool-calls
        // 0` aborts the run (exit 55, nothing executed) on any tool call;
        // `--safe-mode` drops hooks, extensions, skills, MCP servers and
        // context files, and nothing is recorded.
        "qwen" => ctx.harness(
            &strings([
                "qwen",
                "--safe-mode",
                "--chat-recording=false",
                "--max-tool-calls",
                "0",
                "--approval-mode",
                "plan",
                "--system-prompt",
                SYSTEM_PROMPT,
                instruction,
            ]),
            ctx.screen,
        ),
        // A deny-everything policy leaves the request with no tools; `-e
        // none` loads no extension. The screen goes before the prompt on stdin.
        "gemini" => {
            let policy = jspath::join(&[ctx.work_dir, GEMINI_POLICY_NAME]);
            write_atomic(
                std::path::Path::new(&policy),
                GEMINI_POLICY.as_bytes(),
                0o600,
            )
            .ok()?;
            ctx.harness(
                &[
                    "gemini".to_string(),
                    "-p".to_string(),
                    format!("{SYSTEM_PROMPT}\n\n{instruction}"),
                    "-e".to_string(),
                    "none".to_string(),
                    "--approval-mode".to_string(),
                    "plan".to_string(),
                    "--policy".to_string(),
                    policy,
                ],
                ctx.screen,
            )
        }
        "copilot" => run_copilot(ctx),
        "opencode" => run_opencode_like("opencode", "build", "OPENCODE_CONFIG_CONTENT", ctx),
        "kilo" => run_opencode_like("kilo", "code", "KILO_CONFIG_CONTENT", ctx),
        // The whole prompt on stdin; `-t clarify` leaves only the clarifying
        // question tool, which a one-shot run cannot use. The session is
        // tagged `tool`, which keeps it out of the user's session lists.
        "hermes" => ctx.harness(
            &strings([
                "hermes",
                "chat",
                "--query-file",
                "-",
                "--oneshot",
                "-Q",
                "--ignore-rules",
                "--source",
                "tool",
                "-t",
                "clarify",
            ]),
            &prompt_text(instruction, ctx.screen),
        ),
        // `run.toolset=[]` sends no tool at all, `run.reminder_roster={}` runs
        // no observer agent beside it, and `--no-session-log` records nothing.
        // The prompt goes in a file.
        "muse" => {
            let prompt = jspath::join(&[ctx.work_dir, MUSE_PROMPT_NAME]);
            write_atomic(
                std::path::Path::new(&prompt),
                prompt_text(instruction, ctx.screen).as_bytes(),
                0o600,
            )
            .ok()?;
            ctx.harness(
                &strings([
                    "muse",
                    "exec",
                    "--no-session-log",
                    "-c",
                    "run.toolset=[]",
                    "-c",
                    "run.reminder_roster={}",
                    "--disable-shell",
                    "--disable-write",
                    "--disable-web-tools",
                    "--max-model-steps",
                    "1",
                    "--prompt-file",
                ])
                .into_iter()
                .chain([prompt])
                .collect::<Vec<_>>(),
                "",
            )
        }
        _ => None,
    }
}

/// codex: ephemeral and read-only, prompt on stdin, answer from its `-o` file.
fn run_codex(ctx: &RunCtx<'_>) -> Option<String> {
    let suffix = random_bytes::<4>().ok()?;
    let out = jspath::join(&[
        ctx.work_dir,
        &format!("codex-summary-{}-{}.txt", std::process::id(), hex(&suffix)),
    ]);
    let model = ctx
        .detail
        .map(|detail| jsx::field(detail, "model"))
        .filter(|model| !model.is_null())
        .map_or_else(|| "gpt-6-luna".to_string(), js_string);
    let argv: Vec<String> = [
        "codex",
        "exec",
        "--ephemeral",
        "--skip-git-repo-check",
        "--ignore-user-config",
        "--ignore-rules",
        "-s",
        "read-only",
        "-m",
        &model,
        "-c",
        "model_reasoning_effort=\"low\"",
        "-c",
        "approval_policy=\"never\"",
        "-c",
        "history.persistence=\"none\"",
        "-c",
        "web_search=\"disabled\"",
        "--disable",
        "shell_tool",
        "--disable",
        "unified_exec",
        "-C",
        ctx.cwd,
        "--color",
        "never",
        "-o",
        &out,
        "-",
    ]
    .map(String::from)
    .to_vec();
    let result = run_process(&ProcessSpec {
        argv: &argv,
        input: Some(&prompt_text(ctx.instruction, ctx.screen)),
        signal: ctx.signal,
        env: ctx.env,
        cwd: Some(ctx.cwd),
        capture_stderr: false,
    });
    let answer = if result.code == Some(0) {
        read_text_file(&out)
    } else {
        None
    };
    let _ = fs::remove_file(&out);
    answer
}

/// copilot: the whole prompt on stdin (it reads no screen beside a `-p`
/// prompt), `--available-tools=none` leaves no tool, and the session it
/// records under a fresh id is removed afterwards.
fn run_copilot(ctx: &RunCtx<'_>) -> Option<String> {
    let session = random_uuid().ok()?;
    let argv = vec![
        "copilot".to_string(),
        "-s".to_string(),
        "--available-tools=none".to_string(),
        "--no-custom-instructions".to_string(),
        "--disable-builtin-mcps".to_string(),
        "--no-auto-update".to_string(),
        "--no-ask-user".to_string(),
        format!("--session-id={session}"),
    ];
    let result = run_process(&ProcessSpec {
        argv: &argv,
        input: Some(&prompt_text(ctx.instruction, ctx.screen)),
        signal: ctx.signal,
        env: ctx.env,
        cwd: Some(ctx.cwd),
        capture_stderr: false,
    });
    let copilot_home = match ctx.env.non_empty("COPILOT_HOME") {
        Some(home) => home.to_string(),
        None => jspath::join(&[&home_of(ctx.env), ".copilot"]),
    };
    let _ = fs::remove_dir_all(jspath::join(&[&copilot_home, "session-state", &session]));
    (result.code == Some(0)).then_some(result.stdout)
}

// MARK: - HTTPS

/// The HTTPS side of the providers (JS `fetchImpl`): POST JSON with a bearer
/// key; the parsed body on a 2xx answer, `None` on any failure.
pub trait Fetch: Sync {
    fn post_json(
        &self,
        url: &str,
        api_key: &str,
        body: &Value,
        signal: &AbortSignal,
    ) -> Option<Value>;
}

/// The real [`Fetch`]: HTTPS through [`http::post_json`], abandoned when
/// `signal` fires.
pub struct HttpFetch;

impl Fetch for HttpFetch {
    fn post_json(
        &self,
        url: &str,
        api_key: &str,
        body: &Value,
        signal: &AbortSignal,
    ) -> Option<Value> {
        if signal.is_aborted() {
            return None;
        }
        let (sender, receiver) = mpsc::channel();
        let (url, auth, body) = (url.to_string(), format!("Bearer {api_key}"), body.clone());
        thread::spawn(move || {
            let answer = http::post_json(
                &url,
                &[("authorization", &auth)],
                &body,
                Duration::from_secs(300),
            )
            .ok()
            .filter(|response| (200..300).contains(&response.status))
            .and_then(|response| jsx::parse_json(&response.body));
            let _ = sender.send(answer);
        });
        loop {
            match receiver.recv_timeout(Duration::from_millis(10)) {
                Ok(answer) => return answer,
                Err(mpsc::RecvTimeoutError::Timeout) if !signal.is_aborted() => {}
                Err(_) => return None,
            }
        }
    }
}

// MARK: - Detection

#[derive(Debug, Clone, PartialEq)]
pub struct Provider {
    pub id: &'static str,
    pub detail: Option<Value>,
}

/// `readProviderCache`: the cached providers while fresh, `None` otherwise.
fn read_provider_cache(cache_dir: &str, now: f64) -> Option<Vec<Provider>> {
    let bytes = fs::read(jspath::join(&[cache_dir, PROVIDER_CACHE_NAME])).ok()?;
    let cached = jsx::parse_json(&String::from_utf8_lossy(&bytes))?;
    let ts = jsx::field(&cached, "ts");
    let providers = jsx::field(&cached, "providers").as_array()?;
    if jsx::field(&cached, "v").as_f64() != Some(1.0) || !jsx::is_integer(ts) {
        return None;
    }
    let age = now - ts.as_f64()?;
    if !(0.0..PROVIDER_CACHE_TTL_MS as f64).contains(&age) {
        return None;
    }
    Some(
        providers
            .iter()
            .filter_map(|entry| {
                let id = jsx::field(entry, "id").as_str()?;
                let id = PROVIDER_ORDER.iter().find(|known| **known == id)?;
                Some(Provider {
                    id,
                    detail: jsx::get(entry, "detail").cloned(),
                })
            })
            .collect(),
    )
}

/// `detectProviders`: the providers this Host can use, in [`PROVIDER_ORDER`],
/// each with its detail (when it has one). Probed in parallel, then cached
/// for [`PROVIDER_CACHE_TTL_MS`] in `cache_dir` (the plugin config dir) so a
/// refresh costs no probes; the cache also names the first one (`provider`,
/// "none" when empty).
pub fn detect_providers(env: &Env, cwd: &str, cache_dir: &str, now_ms: i64) -> Vec<Provider> {
    if let Some(cached) = read_provider_cache(cache_dir, now_ms as f64) {
        return cached;
    }
    let results: Vec<Detected> = thread::scope(|scope| {
        let handles: Vec<_> = PROVIDER_ORDER
            .iter()
            .map(|id| scope.spawn(|| detect(id, env, cwd)))
            .collect();
        handles
            .into_iter()
            .map(|handle| handle.join().unwrap_or(Detected::No))
            .collect()
    });
    let providers: Vec<Provider> = PROVIDER_ORDER
        .iter()
        .zip(results)
        .filter_map(|(id, found)| match found {
            Detected::No => None,
            Detected::Yes => Some(Provider { id, detail: None }),
            Detected::Detail(detail) => Some(Provider {
                id,
                detail: Some(detail),
            }),
        })
        .collect();
    let _ = write_provider_cache(cache_dir, now_ms, &providers);
    providers
}

fn write_provider_cache(cache_dir: &str, now_ms: i64, providers: &[Provider]) -> io::Result<()> {
    DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(cache_dir)?;
    let entries: Vec<Value> = providers
        .iter()
        .map(|provider| match &provider.detail {
            Some(detail) => json!({ "id": provider.id, "detail": detail }),
            None => json!({ "id": provider.id }),
        })
        .collect();
    let first = providers.first().map_or("none", |provider| provider.id);
    let cache = json!({ "v": 1, "ts": now_ms, "provider": first, "providers": entries });
    write_atomic(
        std::path::Path::new(&jspath::join(&[cache_dir, PROVIDER_CACHE_NAME])),
        format!("{}\n", jsx::stringify(&cache)).as_bytes(),
        0o600,
    )
}

// MARK: - Environment

/// What an Agent's process and hook environment carries that names its pane
/// or session, or feeds its Chat Mode: a summary harness started from that
/// hook must not inherit it. Credentials and config homes stay.
const AGENT_SESSION_ENV: &[&str] = &[
    "TMUX",
    "TMUX_PANE",
    "CLAUDECODE",
    "CLAUDE_PID",
    "CLAUDE_CODE_SESSION_ID",
    "CLAUDE_CODE_ENTRYPOINT",
    "CLAUDE_PROJECT_DIR",
    "CLAUDE_ENV_FILE",
    "CLAUDE_PLUGIN_ROOT",
    "CODEX_THREAD_ID",
    "GEMINI_CLI",
    "GEMINI_CLI_NO_RELAUNCH",
    "GEMINI_SESSION_ID",
    "GEMINI_PROJECT_DIR",
    "GEMINI_CWD",
    "GEMINI_PLANS_DIR",
    "QWEN_CODE_SESSION_ID",
    "QWEN_PROJECT_DIR",
    "QWEN_CODE_PROJECT_DIR",
    "QWEN_CODE_MODEL",
    "QWEN_CODE_CLI",
    "COPILOT_CLI",
    "COPILOT_CLI_BINARY_VERSION",
    "COPILOT_PROJECT_DIR",
    "COPILOT_LOADER_PID",
    "COPILOT_CUSTOM_INSTRUCTIONS_DIRS",
    "GROK_HOOK_EVENT",
    "GROK_HOOK_NAME",
    "GROK_SESSION_ID",
    "GROK_WORKSPACE_ROOT",
    "CURSOR_VERSION",
    "CURSOR_PROJECT_DIR",
    "CURSOR_TRANSCRIPT_PATH",
    "DEVIN_PROJECT_DIR",
    "ANTIGRAVITY_CONVERSATION_ID",
    "HERMES_SESSION_ID",
    "HERMES_INTERACTIVE",
    "HERMES_AGENT",
    "HERMES_ACCEPT_HOOKS",
    "HERMES_EPHEMERAL_SYSTEM_PROMPT",
    "KILO_PID",
    "KILO_RUN_ID",
    "KILO_PROCESS_ROLE",
    "KILO_SERVER_PASSWORD",
    "MUSE_SESSION_ID",
    "MUSE_THREAD_ID",
];

/// The variables a herdr-core terminal gives its program (`HC_SOCKET` is
/// the one `herdr-core` itself reads): without them the harness's own hooks
/// find no core terminal to report on.
const CORE_TERMINAL_ENV: &[&str] = &[
    "HC_TERMINAL_ID",
    "HC_TERMINAL_SOCKET",
    "HC_SESSION",
    "HC_SOCKET",
    "HC_SCOPE",
];

/// `harnessEnv`: the harness child's environment: the hook's own, minus
/// herdr's plugin variables, `CORE_TERMINAL_ENV` and `AGENT_SESSION_ENV`, plus
/// `WAYCAR_SUMMARY=1`.
/// A summary runs from the hook of the Agent it describes; inheriting that
/// Agent's pane would let the harness's own Status Hooks (Waycar's included)
/// report this one-shot call as the Agent: overwrite its session, release its
/// pane, fire another notify. With no pane they find nothing, and Waycar's
/// hooks also refuse to run under the marker.
///
/// `PATH` gets the usual per-user and package-manager bin directories
/// appended: a herdr server started by launchd on macOS inherits only
/// `/usr/bin:/bin:/usr/sbin:/sbin`, so `omp` (Homebrew) and `claude`
/// (~/.local/bin) would never be found and every summary would be empty.
pub fn harness_env(base: &Env, fallback_dirs: &[String]) -> Env {
    let mut env = Env::from_pairs(
        base.iter()
            .filter(|(name, _)| {
                !name.starts_with("HERDR_")
                    && !CORE_TERMINAL_ENV.contains(name)
                    && !AGENT_SESSION_ENV.contains(name)
            })
            .map(|(name, value)| (name.to_string(), value.to_string())),
    );
    env.set("WAYCAR_SUMMARY", "1");
    let mut dirs: Vec<String> = env
        .get("PATH")
        .unwrap_or("")
        .split(':')
        .filter(|dir| !dir.is_empty())
        .map(str::to_string)
        .collect();
    for dir in fallback_dirs {
        if !dirs.contains(dir) {
            dirs.push(dir.clone());
        }
    }
    env.set("PATH", dirs.join(":"));
    env
}

/// `defaultHarnessDirs(home)`: where omp and claude usually live when they
/// are not on the hook's `PATH`.
pub fn default_harness_dirs(home: &str) -> Vec<String> {
    vec![
        jspath::join(&[home, ".local", "bin"]),
        jspath::join(&[home, ".bun", "bin"]),
        jspath::join(&[home, ".npm-global", "bin"]),
        "/opt/homebrew/bin".to_string(),
        "/usr/local/bin".to_string(),
    ]
}

fn os_home() -> String {
    std::env::home_dir()
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_default()
}

// MARK: - Summaries

pub struct SummarizeOptions<'a> {
    /// The normalized screen; `None` is JS `null`: no summary.
    pub screen: Option<&'a str>,
    /// working, idle, done, or blocked; anything else yields no summary.
    pub status: &'a str,
    /// `summary_command` argv override; the instruction is appended as its
    /// last argument and the screen text is written to its stdin. When set,
    /// no provider is tried.
    pub command: Option<&'a [String]>,
    /// The budget; a running child is killed and a request abandoned when it fires.
    pub signal: &'a AbortSignal,
    /// Private directory (the plugin state dir): harnesses run in its
    /// `summary-cwd` subdirectory, and omp's config overlay is written beside that.
    pub work_dir: &'a str,
    /// Where provider detection is cached (the plugin config dir).
    pub cache_dir: &'a str,
    /// Directories appended to the harness's `PATH` (see [`harness_env`]);
    /// `None`: `default_harness_dirs(home)`.
    pub path_fallback: Option<&'a [String]>,
    /// The base environment.
    pub env: &'a Env,
    pub fetch: &'a dyn Fetch,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Summarized {
    pub summary: Option<String>,
    pub phase: Option<&'static str>,
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as i64)
}

/// `summarizeScreen`: summarize an already-read, normalized screen for an
/// Agent in `status`. The sanitized summary (`None` on any failure) and, for
/// a Working Agent whose answer named one, its phase ([`parse_phase`]); a
/// `None` summary has no phase.
pub fn summarize_screen(options: &SummarizeOptions<'_>) -> Summarized {
    summarize_screen_at(options, now_ms())
}

/// [`summarize_screen`] with the clock (`Date.now()`) given: the provider
/// cache is stamped and aged by it.
pub fn summarize_screen_at(options: &SummarizeOptions<'_>, now: i64) -> Summarized {
    let none = Summarized {
        summary: None,
        phase: None,
    };
    let Some(instruction) = summary_instruction(options.status) else {
        return none;
    };
    let Some(screen) = options.screen else {
        return none;
    };
    let read = |answer: Option<String>| {
        let summary = answer.as_deref().and_then(sanitize_summary);
        let phase = match (&summary, &answer) {
            (Some(_), Some(answer)) if options.status == "working" => parse_phase(answer),
            _ => None,
        };
        Summarized { summary, phase }
    };
    let Ok(cwd) = harness_cwd(options.work_dir) else {
        return none;
    };
    let fallback = options
        .path_fallback
        .map_or_else(|| default_harness_dirs(&os_home()), <[String]>::to_vec);
    let env = harness_env(options.env, &fallback);
    if let Some(command) = options.command {
        let mut argv = command.to_vec();
        argv.push(instruction.to_string());
        return read(run_harness(&argv, screen, options.signal, &env, &cwd));
    }
    for Provider { id, detail } in detect_providers(&env, &cwd, options.cache_dir, now) {
        if options.signal.is_aborted() {
            return none;
        }
        let answer = run_provider(
            id,
            &RunCtx {
                instruction,
                screen,
                work_dir: options.work_dir,
                detail: detail.as_ref(),
                signal: options.signal,
                env: &env,
                cwd: &cwd,
                fetch: options.fetch,
            },
        );
        let result = read(answer);
        if result.summary.is_some() {
            return result;
        }
    }
    none
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Generated {
    pub summary: Option<String>,
    pub hash: Option<String>,
}

pub struct GenerateOptions<'a> {
    /// herdr CLI used to read a herdr pane's screen.
    pub bin_path: &'a str,
    /// The Agent's pane; a `tmux:` id is read with tmux.
    pub pane_id: &'a str,
    pub status: &'a str,
    /// Total budget, screen read included.
    pub timeout: Duration,
    pub command: Option<&'a [String]>,
    pub work_dir: &'a str,
    pub cache_dir: &'a str,
    pub path_fallback: Option<&'a [String]>,
    pub env: &'a Env,
    pub fetch: &'a dyn Fetch,
}

/// `generateAgentSummary`: read an Agent's screen and summarize it within
/// `timeout`. The summary (`None` on any failure) and the screen's hash
/// (`None` when unreadable).
pub fn generate_agent_summary(options: &GenerateOptions<'_>) -> Generated {
    generate_agent_summary_at(options, now_ms())
}

/// [`generate_agent_summary`] with the clock given (see [`summarize_screen_at`]).
pub fn generate_agent_summary_at(options: &GenerateOptions<'_>, now: i64) -> Generated {
    let none = Generated {
        summary: None,
        hash: None,
    };
    if summary_instruction(options.status).is_none() {
        return none;
    }
    let budget = linked_signal(&[], Some(options.timeout));
    let Some(screen) = read_screen(
        options.bin_path,
        options.pane_id,
        &budget.signal,
        options.env,
    ) else {
        return none;
    };
    let Summarized { summary, .. } = summarize_screen_at(
        &SummarizeOptions {
            screen: Some(&screen),
            status: options.status,
            command: options.command,
            signal: &budget.signal,
            work_dir: options.work_dir,
            cache_dir: options.cache_dir,
            path_fallback: options.path_fallback,
            env: options.env,
            fetch: options.fetch,
        },
        now,
    );
    Generated {
        summary,
        hash: Some(screen_hash(&screen)),
    }
}

#[cfg(test)]
#[path = "agent_tests.rs"]
mod tests;
