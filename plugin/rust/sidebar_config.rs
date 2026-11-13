//! The sidebar layout snapshot (sidebar-config.js and the startup hook
//! sidebar-hook.js).
//!
//! herdr's `config.toml` sets how its sidebar lays out Agent rows. The hooks
//! normalize the sidebar agent layout and sort into `sidebar.json` in the
//! plugin's config directory, where the app reads it; the file is rewritten
//! only when the source's path, existence or mtime changed.
//!
//! The JS parsed with smol-toml and `integersAsBigInt: true`, and which
//! documents that parser accepts is what the app's snapshots depend on: an
//! integer of any size parses (`row_gap = 99999999999999999999` is a bad gap,
//! not a bad file), a date is whatever V8's `Date` takes (`1979-02-30` parses,
//! a leap second does not), a byte-order mark is an error. The `toml` crate
//! differs from it on all of those (and on more, found by diffing the two on
//! mutations of real configs), so the parser here is a port of smol-toml's
//! (`mod smol_toml` below). The snapshot is written with the byte layout of
//! `JSON.stringify` (see [`write_js_json`]).

use std::fmt::Write as _;
use std::fs::DirBuilder;
use std::io;
use std::os::unix::fs::{DirBuilderExt, MetadataExt};
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{Map, Value, json};

use crate::atomic::write_atomic;
use crate::env::Env;
use crate::jsx;
use crate::paths::posix_join;

const BUILTIN_TOKENS: [&str; 8] = [
    "state_icon",
    "state_text",
    "workspace",
    "tab",
    "pane",
    "agent",
    "terminal_title",
    "terminal_title_stripped",
];
/// Canonical labels from herdr v0.9.0 src/detect/mod.rs; aliases are
/// invalid. test-vectors/agent-kinds-v1.json pins these against the app's
/// SupportedAgentKind raw values.
pub const AGENT_IDS: [&str; 23] = [
    "pi",
    "claude",
    "codex",
    "gemini",
    "cursor",
    "devin",
    "agy",
    "cline",
    "omp",
    "mastracode",
    "opencode",
    "copilot",
    "kimi",
    "kiro",
    "droid",
    "amp",
    "grok",
    "hermes",
    "kilo",
    "qodercli",
    "qwen",
    "maki",
    "muse",
];
const STYLE_KEYS: [&str; 4] = ["token", "fg", "bold", "dim"];

/// Where herdr's config file is: `HERDR_CONFIG_PATH` (even empty), else
/// `$XDG_CONFIG_HOME/herdr/config.toml`, else under `$HOME/.config`, else
/// under the temporary directory (herdr's own fallback; Node's `os.tmpdir()`
/// reads `TMPDIR`, `TMP`, `TEMP`).
pub fn resolve_config_path(env: &Env) -> String {
    if let Some(path) = env.get("HERDR_CONFIG_PATH") {
        return path.to_string();
    }
    let join = |parts: &[&str]| {
        let parts: Vec<&Path> = parts.iter().map(Path::new).collect();
        posix_join(&parts).to_string_lossy().into_owned()
    };
    if let Some(xdg) = env.get("XDG_CONFIG_HOME") {
        return join(&[xdg, "herdr", "config.toml"]);
    }
    let base = match env.get("HOME") {
        Some(home) => join(&[home, ".config"]),
        None => tmpdir(env),
    };
    join(&[&base, "herdr", "config.toml"])
}

/// Node's `os.tmpdir()` on POSIX.
fn tmpdir(env: &Env) -> String {
    let dir = ["TMPDIR", "TMP", "TEMP"]
        .into_iter()
        .find_map(|name| env.non_empty(name))
        .unwrap_or("/tmp");
    if dir.len() > 1 {
        dir.strip_suffix('/').unwrap_or(dir).to_string()
    } else {
        dir.to_string()
    }
}

fn defaults(diagnostics: &[&str]) -> Value {
    json!({
        "agent_panel_sort": "spaces",
        "sidebar": { "agents": {
            "row_gap": 0,
            "rows": [
                [{ "token": "state_icon" }, { "token": "workspace" }, { "token": "tab" }],
                [{ "token": "agent" }],
            ],
            "rows_by_agent": {},
        } },
        "diagnostics": diagnostics,
    })
}

/// Why a document's layout is refused (the diagnostics the app shows).
#[derive(Clone, Copy)]
enum Invalid {
    Schema,
    Token,
}

use smol_toml::{Doc, Table, Val};

/// `table(value)`: only a table is one (not an array, a date or a scalar).
fn table(doc: &Doc, value: Val) -> Result<&Table, Invalid> {
    match value {
        Val::Table(id) => Ok(&doc.tables[id]),
        _ => Err(Invalid::Schema),
    }
}

/// `table(parent.key ?? {})`: an absent key is an empty table.
fn child<'a>(
    doc: &'a Doc,
    parent: Option<&Table>,
    key: &str,
) -> Result<Option<&'a Table>, Invalid> {
    match parent.and_then(|parent| parent.get(key)) {
        None => Ok(None),
        Some(value) => table(doc, value).map(Some),
    }
}

/// `/^#(?:[\da-fA-F]{3}|[\da-fA-F]{6})$/`
fn is_hex_color(value: &str) -> bool {
    value
        .strip_prefix('#')
        .is_some_and(|hex| matches!(hex.len(), 3 | 6) && hex.bytes().all(|b| b.is_ascii_hexdigit()))
}

/// `/^\$[A-Za-z0-9_-]{1,32}$/`
fn is_custom_token(value: &str) -> bool {
    value.strip_prefix('$').is_some_and(|name| {
        (1..=32).contains(&name.len())
            && name
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
    })
}

fn token(doc: &Doc, value: Val) -> Result<Value, Invalid> {
    // A string is `{ token: <string> }`; anything else must be a table of
    // style keys.
    let (name, fg, bold, dim) = match value {
        Val::Str(_) => (Some(value), None, None, None),
        _ => {
            let input = table(doc, value)?;
            if input
                .entries
                .iter()
                .any(|(key, _)| !STYLE_KEYS.contains(&key.as_str()))
            {
                return Err(Invalid::Schema);
            }
            (
                input.get("token"),
                input.get("fg"),
                input.get("bold"),
                input.get("dim"),
            )
        }
    };
    let Some(Val::Str(name)) = name else {
        return Err(Invalid::Token);
    };
    let name = doc.strings[name].as_str();
    if name.trim_matches(jsx::is_js_space) != name
        || (!BUILTIN_TOKENS.contains(&name) && !is_custom_token(name))
    {
        return Err(Invalid::Token);
    }
    let mut result = Map::new();
    result.insert("token".into(), json!(name));
    if let Some(fg) = fg {
        match fg {
            Val::Str(fg) => {
                let fg = doc.strings[fg].as_str();
                if fg.trim_matches(jsx::is_js_space) != fg || !is_hex_color(fg) {
                    return Err(Invalid::Schema);
                }
                result.insert("fg".into(), json!(fg));
            }
            _ => return Err(Invalid::Schema),
        }
    }
    for (key, flag) in [("bold", bold), ("dim", dim)] {
        match flag {
            None => {}
            Some(Val::Bool(flag)) => {
                result.insert(key.into(), json!(flag));
            }
            Some(_) => return Err(Invalid::Schema),
        }
    }
    Ok(Value::Object(result))
}

fn rows(doc: &Doc, value: Val) -> Result<Value, Invalid> {
    let Val::Array(rows) = value else {
        return Err(Invalid::Schema);
    };
    let rows = &doc.arrays[rows];
    if rows.len() > 16 {
        return Err(Invalid::Schema);
    }
    let mut out = Vec::with_capacity(rows.len());
    for &row in rows {
        let Val::Array(row) = row else {
            return Err(Invalid::Schema);
        };
        let row = &doc.arrays[row];
        if row.len() > 16 {
            return Err(Invalid::Schema);
        }
        out.push(Value::Array(
            row.iter()
                .map(|&value| token(doc, value))
                .collect::<Result<_, _>>()?,
        ));
    }
    Ok(Value::Array(out))
}

/// The entries of a table in `Object.entries` order: array indexes
/// ascending, then the other keys in the order they were first defined.
fn js_entries(table: &Table) -> Vec<(&str, Val)> {
    let mut entries: Vec<(usize, &str, Val)> = table
        .entries
        .iter()
        .enumerate()
        .map(|(at, (key, value))| (at, key.as_str(), *value))
        .collect();
    entries.sort_by_key(|(at, key, _)| match jsx::array_index(key) {
        Some(index) => (0, u64::from(index)),
        None => (1, *at as u64),
    });
    entries
        .into_iter()
        .map(|(_, key, value)| (key, value))
        .collect()
}

fn layout(doc: &Doc, root: &Table) -> Result<Value, Invalid> {
    let ui = child(doc, Some(root), "ui")?;
    let agents = child(doc, child(doc, ui, "sidebar")?, "agents")?;
    let mut result = defaults(&[]);
    let sort = match ui.and_then(|ui| ui.get("agent_panel_sort")) {
        None => "spaces",
        Some(Val::Str(sort)) => match doc.strings[sort].as_str() {
            sort @ ("spaces" | "workspaces" | "priority") => sort,
            _ => return Err(Invalid::Schema),
        },
        Some(_) => return Err(Invalid::Schema),
    };
    result["agent_panel_sort"] = json!(if sort == "workspaces" { "spaces" } else { sort });
    let target = &mut result["sidebar"]["agents"];
    // Only 0..=65535 is a row gap, whatever size the integer is.
    match agents.and_then(|agents| agents.get("row_gap")) {
        None => {}
        Some(Val::Int(Some(gap))) => target["row_gap"] = json!(gap),
        Some(_) => return Err(Invalid::Schema),
    }
    if let Some(value) = agents.and_then(|agents| agents.get("rows")) {
        target["rows"] = rows(doc, value)?;
    }
    if let Some(overrides) = child(doc, agents, "rows_by_agent")? {
        let by_agent = target["rows_by_agent"].as_object_mut().unwrap();
        for (id, value) in js_entries(overrides) {
            if !AGENT_IDS.contains(&id) {
                return Err(Invalid::Schema);
            }
            by_agent.insert(id.to_string(), rows(doc, value)?);
        }
    }
    Ok(result)
}

/// Normalize only the sidebar agent layout and sort; never expose raw TOML in
/// diagnostics. The result is `{agent_panel_sort, sidebar, diagnostics}`.
pub fn parse_sidebar_config(toml: &str) -> Value {
    let Ok((doc, root)) = smol_toml::parse(toml) else {
        return defaults(&["parse_error"]);
    };
    match layout(&doc, &doc.tables[root]) {
        Ok(config) => config,
        Err(Invalid::Token) => defaults(&["invalid_token"]),
        Err(Invalid::Schema) => defaults(&["invalid_schema"]),
    }
}

/// A snapshot could not be written: the Node-style error code of the failed
/// call (`EISDIR`, `EACCES`, ...).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RefreshError {
    pub code: String,
}

impl RefreshError {
    fn from_io(error: &io::Error) -> Self {
        Self {
            code: errno_code(error),
        }
    }
}

/// Node's `error.code` for a failed system call.
fn errno_code(error: &io::Error) -> String {
    macro_rules! names {
        ($errno:expr, $($name:ident),* $(,)?) => {
            match $errno {
                $(code if code == libc::$name => stringify!($name).to_string(),)*
                other => format!("Unknown system error -{other}"),
            }
        };
    }
    match error.raw_os_error() {
        None => "UNKNOWN".to_string(),
        Some(errno) => names!(
            errno,
            EPERM,
            ENOENT,
            EIO,
            EBADF,
            EACCES,
            EBUSY,
            EEXIST,
            EXDEV,
            ENODEV,
            ENOTDIR,
            EISDIR,
            EINVAL,
            ENFILE,
            EMFILE,
            ETXTBSY,
            EFBIG,
            ENOSPC,
            EROFS,
            EMLINK,
            ENAMETOOLONG,
            ENOTEMPTY,
            ELOOP,
            EDQUOT,
            ESTALE,
            EAGAIN,
            ENOMEM,
            EINTR,
            EFAULT,
            EOVERFLOW,
        ),
    }
}

/// `JSON.stringify(value)`: no spaces, keys in order, doubles as ECMAScript
/// prints them.
pub fn write_js_json(value: &Value, out: &mut String) {
    match value {
        Value::Null => out.push_str("null"),
        Value::Bool(flag) => out.push_str(if *flag { "true" } else { "false" }),
        Value::Number(number) => match (number.as_i64(), number.as_u64()) {
            (Some(integer), _) => {
                let _ = write!(out, "{integer}");
            }
            (None, Some(integer)) => {
                let _ = write!(out, "{integer}");
            }
            _ => out.push_str(&jsx::number_to_string(number.as_f64().unwrap_or(0.0))),
        },
        Value::String(text) => {
            out.push_str(&serde_json::to_string(text).unwrap_or_default());
        }
        Value::Array(items) => {
            out.push('[');
            for (index, item) in items.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                write_js_json(item, out);
            }
            out.push(']');
        }
        Value::Object(map) => {
            out.push('{');
            for (index, (key, item)) in map.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                out.push_str(&serde_json::to_string(key).unwrap_or_default());
                out.push(':');
                write_js_json(item, out);
            }
            out.push('}');
        }
    }
}

/// `mtimeMs` as Node computes it: whole seconds times 1000 plus the
/// nanoseconds over a million, in doubles.
fn mtime_ms(meta: &std::fs::Metadata) -> f64 {
    meta.mtime() as f64 * 1000.0 + meta.mtime_nsec() as f64 / 1_000_000.0
}

/// A double as parsing its JSON text gives it back: a whole number is an
/// integer, so a snapshot just built equals one read from disk.
fn json_number(value: f64) -> Value {
    if value.fract() == 0.0 && value.abs() < 9_007_199_254_740_992.0 {
        json!(value as i64)
    } else {
        json!(value)
    }
}

fn is_enoent(error: &io::Error) -> bool {
    error.raw_os_error() == Some(libc::ENOENT)
}

/// Whether the snapshot on disk still describes this source (`found` and
/// `mtime_ms`): version 1, the same path, a rows array and no read error.
fn is_current(previous: &Value, path: &str, found: bool, mtime: Option<f64>) -> bool {
    let source = previous.get("source");
    let same_mtime = match (source.and_then(|s| s.get("mtime_ms")), mtime) {
        (Some(Value::Null), None) => true,
        (Some(Value::Number(previous)), Some(current)) => previous.as_f64() == Some(current),
        _ => false,
    };
    previous.get("v").and_then(Value::as_f64) == Some(1.0)
        && source.and_then(|s| s.get("path")).and_then(Value::as_str) == Some(path)
        && source.and_then(|s| s.get("found")) == Some(&Value::Bool(found))
        && same_mtime
        && previous
            .get("sidebar")
            .and_then(|s| s.get("agents"))
            .and_then(|a| a.get("rows"))
            .is_some_and(Value::is_array)
        && previous
            .get("diagnostics")
            .and_then(Value::as_array)
            .is_some_and(|list| !list.iter().any(|d| d == "read_error"))
}

/// Refresh on source path/existence/mtime changes; the current snapshot.
/// `now` is the clock in epoch milliseconds, read once when a snapshot is
/// built.
pub fn refresh_sidebar_snapshot(
    config_dir: &Path,
    env: &Env,
    now: &dyn Fn() -> u64,
) -> Result<Value, RefreshError> {
    let path = resolve_config_path(env);
    let destination = config_dir.join("sidebar.json");
    let mut found = false;
    let mut mtime = None;
    let mut read_error = false;
    match std::fs::metadata(&path) {
        Ok(meta) => {
            mtime = Some(mtime_ms(&meta));
            found = true;
        }
        Err(error) => read_error = !is_enoent(&error),
    }
    if !read_error {
        // Missing or corrupt snapshots are replaced.
        let previous = std::fs::read(&destination)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok());
        if let Some(previous) = previous
            && is_current(&previous, &path, found, mtime)
        {
            return Ok(previous);
        }
    }
    let mut config = defaults(if read_error { &["read_error"] } else { &[] });
    if found {
        match std::fs::read(&path) {
            Ok(bytes) => config = parse_sidebar_config(&String::from_utf8_lossy(&bytes)),
            Err(error) if is_enoent(&error) => {
                found = false;
                mtime = None;
                config = defaults(&[]);
            }
            Err(_) => config = defaults(&["read_error"]),
        }
    }
    let mut snapshot = Map::new();
    snapshot.insert("v".into(), json!(1));
    snapshot.insert("generated_at".into(), json!(now() / 1000));
    snapshot.insert(
        "source".into(),
        json!({
            "path": path,
            "found": found,
            "mtime_ms": mtime.map(json_number),
        }),
    );
    if let Value::Object(config) = config {
        snapshot.extend(config);
    }
    let snapshot = Value::Object(snapshot);
    DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(config_dir)
        .map_err(|error| RefreshError::from_io(&error))?;
    let mut text = String::new();
    write_js_json(&snapshot, &mut text);
    text.push('\n');
    write_atomic(&destination, text.as_bytes(), 0o600)
        .map_err(|error| RefreshError::from_io(&error))?;
    Ok(snapshot)
}

/// The system clock in epoch milliseconds (`Date.now()`).
pub fn system_now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_millis() as u64)
}

/// Refresh for an event hook: a snapshot write failure must not prevent
/// notification delivery. `Some(line)` is what the hook prints on stderr when
/// the refresh failed.
pub fn refresh_sidebar_snapshot_for_event(config_dir: &Path, env: &Env) -> Option<String> {
    refresh_sidebar_snapshot(config_dir, env, &system_now_ms)
        .err()
        .map(|error| format!("sidebar-hook: snapshot refresh failed ({})", error.code))
}

/// What the startup hook prints and exits with.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StartupOutcome {
    pub code: i32,
    /// Exactly what goes to stderr, line break included; empty on success.
    pub stderr: String,
}

/// The herdr startup hook (sidebar-hook.js): refresh the snapshot in
/// `HERDR_PLUGIN_CONFIG_DIR`. It needs no event, state directory or CLI.
pub fn run_sidebar_startup(env: &Env) -> StartupOutcome {
    let Some(config_dir) = env.non_empty("HERDR_PLUGIN_CONFIG_DIR") else {
        return StartupOutcome {
            code: 1,
            stderr: "sidebar-hook: HERDR_PLUGIN_CONFIG_DIR is not set\n".to_string(),
        };
    };
    match refresh_sidebar_snapshot(Path::new(config_dir), env, &system_now_ms) {
        Ok(_) => StartupOutcome {
            code: 0,
            stderr: String::new(),
        },
        Err(error) => StartupOutcome {
            code: 1,
            stderr: format!("sidebar-hook: {}\n", error.code),
        },
    }
}

/// A port of smol-toml 1.8.0's `parse` with `integersAsBigInt: true`: the
/// parser the JS used, quirks included, since which documents it accepts is
/// the contract (the `toml` crate refuses some it accepts, among them dates
/// like `1979-02-30` and a bare `\r` in an array, and accepts some it
/// refuses, among them a byte-order mark). Only what the sidebar layout reads
/// is kept of the values: types, strings, tables with their key order, and
/// whether an integer is a `u16`.
///
/// smol-toml is licensed as follows; this port keeps its notice.
///
/// ```text
/// Copyright (c) Squirrel Chat et al., All rights reserved.
/// SPDX-License-Identifier: BSD-3-Clause
///
/// Redistribution and use in source and binary forms, with or without
/// modification, are permitted provided that the following conditions are met:
///
/// 1. Redistributions of source code must retain the above copyright notice, this
///    list of conditions and the following disclaimer.
/// 2. Redistributions in binary form must reproduce the above copyright notice,
///    this list of conditions and the following disclaimer in the
///    documentation and/or other materials provided with the distribution.
/// 3. Neither the name of the copyright holder nor the names of its contributors
///    may be used to endorse or promote products derived from this software without
///    specific prior written permission.
///
/// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
/// ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
/// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
/// DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
/// FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
/// DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
/// SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
/// CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
/// OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
/// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
/// ```
///
/// The text is handled as UTF-16 code units, as `charCodeAt` sees it, and an
/// error is any exception of the JS (a `TomlError`, or the `TypeError` of
/// assigning into a primitive).
mod smol_toml {
    use std::collections::{HashMap, HashSet};

    use crate::jsx;

    /// The document is not accepted.
    #[derive(Debug)]
    pub struct Reject;

    type Parse<T> = Result<T, Reject>;

    /// What a value is.
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub enum Val {
        Str(usize),
        /// An integer: its value when it is within 0..=65535.
        Int(Option<u16>),
        Float,
        Bool(bool),
        Date,
        Array(usize),
        Table(usize),
    }

    #[derive(Default)]
    pub struct Table {
        index: HashMap<String, usize>,
        /// In insertion order.
        pub entries: Vec<(String, Val)>,
    }

    impl Table {
        pub fn get(&self, key: &str) -> Option<Val> {
            self.index.get(key).map(|&at| self.entries[at].1)
        }

        fn set(&mut self, key: &str, value: Val) {
            match self.index.get(key) {
                Some(&at) => self.entries[at].1 = value,
                None => {
                    self.index.insert(key.to_string(), self.entries.len());
                    self.entries.push((key.to_string(), value));
                }
            }
        }
    }

    /// The parsed document: arenas for what JS holds as objects.
    #[derive(Default)]
    pub struct Doc {
        pub tables: Vec<Table>,
        pub arrays: Vec<Vec<Val>>,
        pub strings: Vec<String>,
    }

    impl Doc {
        fn table(&mut self) -> usize {
            self.tables.push(Table::default());
            self.tables.len() - 1
        }

        fn array(&mut self) -> usize {
            self.arrays.push(Vec::new());
            self.arrays.len() - 1
        }

        fn string(&mut self, text: &[u16]) -> Val {
            self.strings.push(String::from_utf16_lossy(text));
            Val::Str(self.strings.len() - 1)
        }
    }

    const NAN: i32 = -1;

    struct Ctx<'a> {
        s: &'a [u16],
        p: isize,
        d: i32,
    }

    impl Ctx<'_> {
        /// `charCodeAt`: NaN (-1 here) out of range.
        fn at(&self, index: isize) -> i32 {
            at(self.s, index)
        }
    }

    fn at(s: &[u16], index: isize) -> i32 {
        usize::try_from(index)
            .ok()
            .and_then(|index| s.get(index))
            .map_or(NAN, |&unit| i32::from(unit))
    }

    fn index_of(s: &[u16], needle: u16, from: isize) -> isize {
        let from = from.max(0) as usize;
        s.iter()
            .skip(from)
            .position(|&unit| unit == needle)
            .map_or(-1, |at| (at + from) as isize)
    }

    fn is_space(unit: u16) -> bool {
        char::from_u32(u32::from(unit)).is_some_and(jsx::is_js_space)
    }

    fn slice(s: &[u16], start: isize, end: isize) -> &[u16] {
        let end = (end.max(0) as usize).min(s.len());
        let start = (start.max(0) as usize).min(end);
        &s[start..end]
    }

    fn trim_start(s: &[u16]) -> &[u16] {
        let skip = s.iter().take_while(|&&unit| is_space(unit)).count();
        &s[skip..]
    }

    fn trim_end(s: &[u16]) -> &[u16] {
        let keep = s.len() - s.iter().rev().take_while(|&&unit| is_space(unit)).count();
        &s[..keep]
    }

    const TAB: i32 = 0x9;
    const LF: i32 = 0xa;
    const CR: i32 = 0xd;
    const SPACE: i32 = 0x20;
    const HASH: i32 = 0x23;

    fn index_of_newline(s: &[u16], start: isize) -> isize {
        let mut idx = index_of(s, 0xa, start);
        if at(s, idx - 1) == CR {
            idx -= 1;
        }
        idx
    }

    fn skip_comment(s: &[u16], p: &mut isize) -> Parse<()> {
        while (*p as usize) < s.len() {
            let c = at(s, *p);
            if c == LF {
                break;
            }
            if c == CR && at(s, *p + 1) == LF {
                *p += 1;
                break;
            }
            if (c < 0x20 && c != TAB) || c == 0x7f {
                return Err(Reject);
            }
            *p += 1;
        }
        Ok(())
    }

    fn skip_void(ctx: &mut Ctx, ban_new_lines: bool, ban_comments: bool) -> Parse<()> {
        loop {
            let mut c;
            loop {
                c = ctx.at(ctx.p);
                if c == SPACE
                    || c == TAB
                    || (!ban_new_lines && (c == LF || (c == CR && ctx.at(ctx.p + 1) == LF)))
                {
                    ctx.p += 1;
                } else {
                    break;
                }
            }
            if ban_comments || c != HASH {
                return Ok(());
            }
            skip_comment(ctx.s, &mut ctx.p)?;
        }
    }

    fn skip_until(ctx: &mut Ctx, sep: i32, end: Option<i32>) -> Parse<()> {
        let ptr = ctx.p;
        let Some(end) = end else {
            let found = index_of_newline(ctx.s, ptr);
            ctx.p = if found < 0 {
                ctx.s.len() as isize
            } else {
                found
            };
            return Ok(());
        };
        while (ctx.p as usize) < ctx.s.len() {
            let c = ctx.at(ctx.p);
            if c == HASH {
                skip_comment(ctx.s, &mut ctx.p)?;
            } else if c == end || c == sep {
                return Ok(());
            }
            ctx.p += 1;
        }
        Err(Reject)
    }

    // ---- primitives ---------------------------------------------------

    /// `parseString`: the string at `ctx.p` (a quote), as UTF-16.
    fn parse_string(ctx: &mut Ctx) -> Parse<Vec<u16>> {
        let first = ctx.at(ctx.p);
        ctx.p += 1;
        let is_literal = first == 0x27;
        let is_multiline = first == ctx.at(ctx.p) && first == ctx.at(ctx.p + 1);
        if is_multiline {
            // Trim initial newline.
            ctx.p += 2;
            let c = ctx.at(ctx.p);
            if c == LF {
                ctx.p += 1;
            } else if c == CR && ctx.at(ctx.p + 1) == LF {
                ctx.p += 2;
            }
        }
        let mut parsed: Vec<u16> = Vec::new();
        let mut slice_start = ctx.p;
        // 0 decoding; 1 decoding escape; 2 whitespace escape (no newline yet,
        // must fail on non-whitespace); 3 whitespace escape (newline seen,
        // allowed to transition back to normal decode).
        let mut state = 0;
        while (ctx.p as usize) < ctx.s.len() {
            let c = ctx.at(ctx.p);
            if is_multiline && (c == LF || (c == CR && ctx.at(ctx.p + 1) == LF)) {
                state = if state != 0 { 3 } else { 0 };
            } else if (c < 0x20 && c != TAB) || c == 0x7f {
                return Err(Reject);
            } else if (state == 0 || state == 3)
                && c == first
                && (!is_multiline || (ctx.at(ctx.p + 1) == first && ctx.at(ctx.p + 2) == first))
            {
                if is_multiline {
                    // A string that ends with 4-5 quotes keeps the first 1-2.
                    if ctx.at(ctx.p + 3) == first {
                        ctx.p += 1;
                    }
                    if ctx.at(ctx.p + 3) == first {
                        ctx.p += 1;
                    }
                }
                // Still in a newline escape: nothing to add.
                if state == 0 {
                    parsed.extend_from_slice(slice(ctx.s, slice_start, ctx.p));
                }
                ctx.p += if is_multiline { 3 } else { 1 };
                return Ok(parsed);
            } else if state == 0 {
                if !is_literal && c == 0x5c {
                    parsed.extend_from_slice(slice(ctx.s, slice_start, ctx.p));
                    slice_start = ctx.p;
                    state = 1;
                }
            } else if state == 1 {
                if c == 0x78 || c == 0x75 || c == 0x55 {
                    // x, u, U: a unicode escape.
                    let mut value: i32 = 0;
                    let len = if c == 0x78 {
                        2
                    } else if c == 0x75 {
                        4
                    } else {
                        8
                    };
                    for _ in 0..len {
                        let hex = ctx.at(ctx.p + 1);
                        let digit = match hex {
                            0x30..=0x39 => hex - 0x30,
                            0x41..=0x46 => hex - 0x41 + 10,
                            0x61..=0x66 => hex - 0x61 + 10,
                            _ => return Err(Reject),
                        };
                        // JS shifts as signed 32-bit: 0xfzzzzzzz reads negative.
                        value = (value << 4) | digit;
                        ctx.p += 1;
                    }
                    if !(0..=0x10ffff).contains(&value) || (0xd800..=0xdfff).contains(&value) {
                        return Err(Reject);
                    }
                    let ch = char::from_u32(value as u32).ok_or(Reject)?;
                    let mut buffer = [0u16; 2];
                    parsed.extend_from_slice(ch.encode_utf16(&mut buffer));
                    slice_start = ctx.p + 1;
                    state = 0;
                } else if c == SPACE || c == TAB {
                    // A newline would have been handled above.
                    state = 2;
                } else {
                    let unit: u16 = match c {
                        0x62 => 0x8,  // b
                        0x74 => 0x9,  // t
                        0x6e => 0xa,  // n
                        0x66 => 0xc,  // f
                        0x72 => 0xd,  // r
                        0x65 => 0x1b, // e
                        0x22 => 0x22, // "
                        0x5c => 0x5c, // \
                        _ => return Err(Reject),
                    };
                    parsed.push(unit);
                    slice_start = ctx.p + 1;
                    state = 0;
                }
            } else if c != SPACE && c != TAB {
                if state == 2 {
                    return Err(Reject);
                }
                // State cannot be zero, or an earlier branch would have run. A
                // backslash goes straight to the escape state.
                state = if !is_literal && c == 0x5c { 1 } else { 0 };
                slice_start = ctx.p;
            }
            ctx.p += 1;
        }
        Err(Reject)
    }

    fn is_digit(unit: u16) -> bool {
        (0x30..=0x39).contains(&unit)
    }

    fn is_hex(unit: u16) -> bool {
        is_digit(unit) || (0x41..=0x46).contains(&unit) || (0x61..=0x66).contains(&unit)
    }

    /// The end of `X(_?X)*` starting at `at`, `X` a digit of `class`, greedy
    /// as the regex is; `None` when there is no first digit.
    fn digits(s: &[u16], at: usize, class: fn(u16) -> bool) -> Option<usize> {
        if !s.get(at).is_some_and(|&unit| class(unit)) {
            return None;
        }
        let mut end = at + 1;
        loop {
            match (s.get(end), s.get(end + 1)) {
                (Some(&unit), _) if class(unit) => end += 1,
                (Some(0x5f), Some(&unit)) if class(unit) => end += 2,
                _ => return Some(end),
            }
        }
    }

    /// `INT_REGEX`: `^((0x[0-9a-fA-F](_?[0-9a-fA-F])*)|(([+-]|0[ob])?\d(_?\d)*))$`.
    fn is_int(s: &[u16]) -> bool {
        let ascii = |text: &str| text.encode_utf16().collect::<Vec<u16>>();
        if s.starts_with(&ascii("0x")) && digits(s, 2, is_hex) == Some(s.len()) {
            return true;
        }
        let prefix = if s.starts_with(&ascii("0b")) || s.starts_with(&ascii("0o")) {
            2
        } else if matches!(s.first(), Some(0x2b | 0x2d)) {
            1
        } else {
            0
        };
        // The prefix is optional: a "0b" that does not lead to digits may still
        // be the digit `0` followed by... nothing the regex accepts.
        digits(s, prefix, is_digit) == Some(s.len()) || digits(s, 0, is_digit) == Some(s.len())
    }

    /// `FLOAT_REGEX`: `^[+-]?\d(_?\d)*(\.\d(_?\d)*)?([eE][+-]?\d(_?\d)*)?$`.
    fn is_float(s: &[u16]) -> bool {
        let mut at = usize::from(matches!(s.first(), Some(0x2b | 0x2d)));
        let Some(end) = digits(s, at, is_digit) else {
            return false;
        };
        at = end;
        if s.get(at) == Some(&0x2e) {
            let Some(end) = digits(s, at + 1, is_digit) else {
                return false;
            };
            at = end;
        }
        if matches!(s.get(at), Some(0x65 | 0x45)) {
            at += 1;
            if matches!(s.get(at), Some(0x2b | 0x2d)) {
                at += 1;
            }
            let Some(end) = digits(s, at, is_digit) else {
                return false;
            };
            at = end;
        }
        at == s.len()
    }

    /// `LEADING_ZERO`: `^[+-]?0[0-9_]`.
    fn has_leading_zero(s: &[u16]) -> bool {
        let at = usize::from(matches!(s.first(), Some(0x2b | 0x2d)));
        s.get(at) == Some(&0x30)
            && s.get(at + 1)
                .is_some_and(|&unit| is_digit(unit) || unit == 0x5f)
    }

    /// Whether the integer text (underscores removed, as `INT_REGEX` shaped
    /// it) is `0..=65535` as a `BigInt` reads it, or `None` when `+value` is
    /// NaN (`0b102`, `0o8`, `0b`).
    fn int_in_u16(value: &[u16]) -> Option<Option<u16>> {
        let text: String = value
            .iter()
            .filter_map(|&u| char::from_u32(u32::from(u)))
            .collect();
        let (negative, body) = match text.as_bytes().first() {
            Some(b'-') => (true, &text[1..]),
            Some(b'+') => (false, &text[1..]),
            _ => (false, text.as_str()),
        };
        let (radix, body) = match body.get(..2) {
            Some("0x") => (16, &body[2..]),
            Some("0b") => (2, &body[2..]),
            Some("0o") => (8, &body[2..]),
            _ => (10, body),
        };
        if body.is_empty() || !body.chars().all(|c| c.is_digit(radix)) {
            return None;
        }
        // A magnitude too large for u128 is far past 65535.
        let magnitude = u128::from_str_radix(body, radix).unwrap_or(u128::MAX);
        Some(if negative && magnitude != 0 {
            None
        } else {
            u16::try_from(magnitude).ok()
        })
    }

    /// `parseValue`: numbers and dates (and `inf`, `nan`).
    fn parse_value(ctx: &mut Ctx, end: Option<i32>) -> Parse<Val> {
        let ptr = ctx.p;
        skip_until(ctx, 0x2c, end)?;
        let raw = slice(ctx.s, ptr, ctx.p);
        let comment = index_of(raw, 0x23, 0);
        let value: &[u16] = if comment > 0 {
            // `skipComment` validates the comment (no control characters).
            let mut at = comment;
            skip_comment(raw, &mut at)?;
            trim_end(&raw[..comment as usize])
        } else {
            trim_end(raw)
        };
        if value.is_empty() {
            return Err(Reject);
        }
        let text: String = String::from_utf16_lossy(value);
        match text.as_str() {
            "-inf" | "inf" | "+inf" | "nan" | "+nan" | "-nan" => return Ok(Val::Float),
            // Avoid FP representation of -0.
            "-0" => return Ok(Val::Int(Some(0))),
            _ => {}
        }
        let integer = is_int(value);
        if integer || is_float(value) {
            if has_leading_zero(value) {
                return Err(Reject);
            }
            let cleaned: Vec<u16> = value.iter().copied().filter(|&unit| unit != 0x5f).collect();
            if integer {
                return int_in_u16(&cleaned).map(Val::Int).ok_or(Reject);
            }
            return Ok(Val::Float);
        }
        if super::toml_date::is_valid(&text) {
            Ok(Val::Date)
        } else {
            Err(Reject)
        }
    }

    // ---- structures ---------------------------------------------------

    fn extract_value(doc: &mut Doc, ctx: &mut Ctx, end: Option<i32>) -> Parse<Val> {
        let c = ctx.at(ctx.p);
        if c == 0x5b || c == 0x7b {
            if ctx.d == 0 {
                return Err(Reject);
            }
            ctx.d -= 1;
            let value = if c == 0x5b {
                parse_array(doc, ctx)?
            } else {
                parse_inline_table(doc, ctx)?
            };
            ctx.d += 1;
            return Ok(value);
        }
        if c == 0x22 || c == 0x27 {
            let text = parse_string(ctx)?;
            return Ok(doc.string(&text));
        }
        // Booleans: the first character says which word it can only be, and
        // nothing is checked after it here.
        for (first, word, value) in [(0x74, "true", true), (0x66, "false", false)] {
            if c == first {
                for letter in word.bytes().skip(1) {
                    ctx.p += 1;
                    if ctx.at(ctx.p) != i32::from(letter) {
                        return Err(Reject);
                    }
                }
                ctx.p += 1;
                return Ok(Val::Bool(value));
            }
        }
        parse_value(ctx, end)
    }

    fn parse_array(doc: &mut Doc, ctx: &mut Ctx) -> Parse<Val> {
        let id = doc.array();
        ctx.p += 1;
        while (ctx.p as usize) < ctx.s.len() {
            skip_void(ctx, false, false)?;
            if ctx.at(ctx.p) == 0x5d {
                ctx.p += 1;
                return Ok(Val::Array(id));
            }
            let value = extract_value(doc, ctx, Some(0x5d))?;
            doc.arrays[id].push(value);
            skip_void(ctx, false, false)?;
            let c = ctx.at(ctx.p);
            ctx.p += 1;
            if c == 0x5d {
                return Ok(Val::Array(id));
            }
            if c != 0x2c {
                return Err(Reject);
            }
        }
        Err(Reject)
    }

    fn parse_inline_table(doc: &mut Doc, ctx: &mut Ctx) -> Parse<Val> {
        let result = doc.table();
        // The tables put in this one as values: a key holding one is closed.
        let mut seen: HashSet<usize> = HashSet::new();
        ctx.p += 1;
        while (ctx.p as usize) < ctx.s.len() {
            skip_void(ctx, false, false)?;
            if ctx.at(ctx.p) == 0x7d {
                ctx.p += 1;
                return Ok(Val::Table(result));
            }
            let mut table = result;
            let mut has_own = false;
            let key = parse_key(ctx, 0x3d)?;
            let mut name = "";
            for (index, part) in key.iter().enumerate() {
                if index > 0 {
                    // `t = hasOwn ? t[k] : (t[k] = {})`
                    let next = if has_own {
                        match doc.tables[table].get(name) {
                            Some(Val::Table(next)) => next,
                            _ => return Err(Reject),
                        }
                    } else {
                        let next = doc.table();
                        doc.tables[table].set(name, Val::Table(next));
                        next
                    };
                    table = next;
                }
                name = part;
                has_own = doc.tables[table].get(name).is_some();
                if has_own {
                    // Only a table made by a dotted key is still open.
                    match doc.tables[table].get(name) {
                        Some(Val::Table(id)) if !seen.contains(&id) => {}
                        _ => return Err(Reject),
                    }
                }
            }
            if has_own {
                return Err(Reject);
            }
            let value = extract_value(doc, ctx, Some(0x7d))?;
            doc.tables[table].set(name, value);
            if let Val::Table(id) = value {
                seen.insert(id);
            }
            skip_void(ctx, false, false)?;
            let c = ctx.at(ctx.p);
            ctx.p += 1;
            if c == 0x7d {
                return Ok(Val::Table(result));
            }
            if c != 0x2c {
                return Err(Reject);
            }
        }
        Err(Reject)
    }

    /// `parseKey`: the parts of a (dotted) key up to `end`.
    fn parse_key(ctx: &mut Ctx, end: u16) -> Parse<Vec<String>> {
        let start = ctx.p;
        let mut dot = start - 1;
        let mut parsed = Vec::new();
        let mut end_ptr = index_of(ctx.s, end, start);
        if end_ptr < 0 {
            return Err(Reject);
        }
        loop {
            dot += 1;
            ctx.p = dot;
            let c = ctx.at(ctx.p);
            // Whitespace is ignored.
            if c != SPACE && c != TAB {
                if c == 0x22 || c == 0x27 {
                    if c == ctx.at(ctx.p + 1) && c == ctx.at(ctx.p + 2) {
                        return Err(Reject);
                    }
                    let part = parse_string(ctx)?;
                    dot = index_of(ctx.s, 0x2e, ctx.p);
                    let str_end = slice(
                        ctx.s,
                        ctx.p,
                        if dot < 0 || dot > end_ptr {
                            end_ptr
                        } else {
                            dot
                        },
                    );
                    if index_of_newline(str_end, 0) > -1 {
                        return Err(Reject);
                    }
                    if !trim_start(str_end).is_empty() {
                        return Err(Reject);
                    }
                    if end_ptr < ctx.p {
                        end_ptr = index_of(ctx.s, end, ctx.p);
                        if end_ptr < 0 {
                            return Err(Reject);
                        }
                    }
                    parsed.push(String::from_utf16_lossy(&part));
                } else {
                    // Normal raw key part consumption and validation.
                    dot = index_of(ctx.s, 0x2e, ctx.p);
                    let part = slice(
                        ctx.s,
                        ctx.p,
                        if dot < 0 || dot > end_ptr {
                            end_ptr
                        } else {
                            dot
                        },
                    );
                    let name_length = part
                        .iter()
                        .take_while(|&&unit| {
                            is_digit(unit)
                                || (0x41..=0x5a).contains(&unit)
                                || (0x61..=0x7a).contains(&unit)
                                || unit == 0x2d
                                || unit == 0x5f
                        })
                        .count();
                    // `/^[a-zA-Z0-9-_]+[ \t]*$/`
                    if name_length == 0
                        || !part[name_length..]
                            .iter()
                            .all(|&unit| unit == 0x20 || unit == 0x9)
                    {
                        return Err(Reject);
                    }
                    parsed.push(String::from_utf16_lossy(&part[..name_length]));
                }
            }
            // Until there is no more dot.
            if !(dot + 1 != 0 && dot < end_ptr) {
                break;
            }
        }
        ctx.p = end_ptr + 1;
        skip_void(ctx, true, true)?;
        Ok(parsed)
    }

    // ---- document -----------------------------------------------------

    const DOTTED: u8 = 0;
    const EXPLICIT: u8 = 1;
    const ARRAY: u8 = 2;
    const ARRAY_DOTTED: u8 = 3;

    /// What `parse` remembers of how each key was defined.
    struct State {
        t: u8,
        d: bool,
        i: usize,
        /// The scope of this key's own keys.
        c: usize,
    }

    #[derive(Default)]
    struct Meta {
        scopes: Vec<HashMap<String, usize>>,
        states: Vec<State>,
    }

    impl Meta {
        fn scope(&mut self) -> usize {
            self.scopes.push(HashMap::new());
            self.scopes.len() - 1
        }

        fn state(&mut self, t: u8) -> usize {
            let c = self.scope();
            self.states.push(State {
                t,
                d: false,
                i: 0,
                c,
            });
            self.states.len() - 1
        }
    }

    /// `peekTable`: walk `key` from table `t` and scope `m` as a table of
    /// `kind`; `(last key, its table, its scope)`, or `None` for a redefinition.
    fn peek_table(
        doc: &mut Doc,
        meta: &mut Meta,
        key: &[String],
        table: usize,
        scope: usize,
        kind: u8,
    ) -> Parse<Option<(String, usize, usize)>> {
        // `t` is a table, or momentarily the array of tables it holds.
        let mut t = Val::Table(table);
        let mut m = scope;
        let mut k = "";
        let mut has_own = false;
        for (i, part) in key.iter().enumerate() {
            if i > 0 {
                let Val::Table(parent) = t else {
                    return Err(Reject);
                };
                t = if has_own {
                    doc.tables[parent].get(k).ok_or(Reject)?
                } else {
                    let next = doc.table();
                    doc.tables[parent].set(k, Val::Table(next));
                    Val::Table(next)
                };
                let state = *meta.scopes[m].get(k).ok_or(Reject)?;
                m = meta.states[state].c;
                if kind == DOTTED
                    && (meta.states[state].t == EXPLICIT || meta.states[state].t == ARRAY)
                {
                    return Ok(None);
                }
                if meta.states[state].t == ARRAY {
                    let Val::Array(array) = t else {
                        return Err(Reject);
                    };
                    let last = doc.arrays[array].len().checked_sub(1).ok_or(Reject)?;
                    t = doc.arrays[array][last];
                    m = meta.states[*meta.scopes[m].get(&last.to_string()).ok_or(Reject)?].c;
                }
            }
            k = part;
            let Val::Table(current) = t else {
                return Err(Reject);
            };
            has_own = doc.tables[current].get(k).is_some();
            if has_own
                && let Some(&existing) = meta.scopes[m].get(k)
                && meta.states[existing].t == DOTTED
                && meta.states[existing].d
            {
                return Ok(None);
            }
            if !has_own {
                let t_kind = if i < key.len() - 1 && kind == ARRAY {
                    ARRAY_DOTTED
                } else {
                    kind
                };
                let created = meta.state(t_kind);
                meta.scopes[m].insert(k.to_string(), created);
            }
        }
        let Val::Table(current) = t else {
            return Err(Reject);
        };
        let mut state = *meta.scopes[m].get(k).ok_or(Reject)?;
        let found = meta.states[state].t;
        if found != kind && !(kind == EXPLICIT && found == ARRAY_DOTTED) {
            // Bad key type.
            return Ok(None);
        }
        let mut t = current;
        if kind == ARRAY {
            if !meta.states[state].d {
                meta.states[state].d = true;
                let array = doc.array();
                doc.tables[t].set(k, Val::Array(array));
            }
            let Some(Val::Array(array)) = doc.tables[t].get(k) else {
                return Err(Reject);
            };
            let element = doc.table();
            doc.arrays[array].push(Val::Table(element));
            t = element;
            let index = meta.states[state].i;
            meta.states[state].i += 1;
            let created = meta.state(EXPLICIT);
            let holder = meta.states[state].c;
            meta.scopes[holder].insert(index.to_string(), created);
            state = created;
        }
        if meta.states[state].d {
            // Redefining a table.
            return Ok(None);
        }
        meta.states[state].d = true;
        if kind == EXPLICIT {
            t = if has_own {
                match doc.tables[t].get(k) {
                    Some(Val::Table(next)) => next,
                    _ => return Err(Reject),
                }
            } else {
                let next = doc.table();
                doc.tables[t].set(k, Val::Table(next));
                next
            };
        } else if kind == DOTTED && has_own {
            return Ok(None);
        }
        Ok(Some((k.to_string(), t, meta.states[state].c)))
    }

    /// `parse(toml, { integersAsBigInt: true })`: the document's root table.
    pub fn parse(source: &str) -> Parse<(Doc, usize)> {
        let units: Vec<u16> = source.encode_utf16().collect();
        let mut ctx = Ctx {
            s: &units,
            p: 0,
            d: 1000,
        };
        let mut doc = Doc::default();
        let mut meta = Meta::default();
        let root = doc.table();
        let root_scope = meta.scope();
        let mut tbl = root;
        let mut m = root_scope;
        skip_void(&mut ctx, false, false)?;
        while (ctx.p as usize) < units.len() {
            if ctx.at(ctx.p) == 0x5b {
                ctx.p += 1;
                let is_table_array = ctx.at(ctx.p) == 0x5b;
                ctx.p += isize::from(is_table_array);
                let key = parse_key(&mut ctx, 0x5d)?;
                if is_table_array {
                    if ctx.at(ctx.p - 1) != 0x5d {
                        return Err(Reject);
                    }
                    ctx.p += 1;
                }
                let kind = if is_table_array { ARRAY } else { EXPLICIT };
                let Some((_, table, scope)) =
                    peek_table(&mut doc, &mut meta, &key, root, root_scope, kind)?
                else {
                    return Err(Reject);
                };
                m = scope;
                tbl = table;
            } else {
                let key = parse_key(&mut ctx, 0x3d)?;
                let Some((last, table, _)) = peek_table(&mut doc, &mut meta, &key, tbl, m, DOTTED)?
                else {
                    return Err(Reject);
                };
                let value = extract_value(&mut doc, &mut ctx, None)?;
                doc.tables[table].set(&last, value);
            }
            skip_void(&mut ctx, true, false)?;
            if (ctx.p as usize) < units.len() {
                let c = ctx.at(ctx.p);
                if c != LF && c != CR {
                    return Err(Reject);
                }
            }
            skip_void(&mut ctx, false, false)?;
        }
        Ok((doc, root))
    }
}

/// `new TomlDate(value).isValid()` of smol-toml: whether a bare TOML value
/// is a date or time. It is the regex `DATE_TIME_RE`, then whether V8's
/// `Date` constructor accepts the string it builds.
mod toml_date {
    /// A run of exactly `count` ASCII digits at `at`, its value.
    fn number(s: &[u8], at: usize, count: usize) -> Option<u32> {
        let digits = s.get(at..at + count)?;
        digits
            .iter()
            .all(u8::is_ascii_digit)
            .then(|| digits.iter().fold(0, |n, d| n * 10 + u32::from(d - b'0')))
    }

    /// `DATE_TIME_RE`: `^(\d{4}-\d{2}-\d{2})?[T ]?(?:(\d{2}):\d{2}(?::\d{2}(?:\.\d+)?)?)?(Z|[-+]\d{2}:\d{2})?$`
    /// with the `i` flag; the parts it found.
    struct Shape {
        date: bool,
        /// The hour group.
        hour: Option<u32>,
        offset: bool,
    }

    fn shape(s: &[u8]) -> Option<Shape> {
        let mut at = 0;
        let date = number(s, 0, 4).is_some()
            && s.get(4) == Some(&b'-')
            && number(s, 5, 2).is_some()
            && s.get(7) == Some(&b'-')
            && number(s, 8, 2).is_some();
        if date {
            at = 10;
        }
        if matches!(s.get(at), Some(b'T' | b't' | b' ')) {
            at += 1;
        }
        let mut hour = None;
        if let (Some(h), Some(b':'), Some(_)) =
            (number(s, at, 2), s.get(at + 2), number(s, at + 3, 2))
        {
            hour = Some(h);
            at += 5;
            if s.get(at) == Some(&b':') && number(s, at + 1, 2).is_some() {
                at += 3;
                if s.get(at) == Some(&b'.') {
                    let fraction = s[at + 1..]
                        .iter()
                        .take_while(|b| b.is_ascii_digit())
                        .count();
                    if fraction > 0 {
                        at += 1 + fraction;
                    }
                }
            }
        }
        let mut offset = false;
        match s.get(at) {
            Some(b'Z' | b'z') => {
                offset = true;
                at += 1;
            }
            Some(b'+' | b'-')
                if number(s, at + 1, 2).is_some()
                    && s.get(at + 3) == Some(&b':')
                    && number(s, at + 4, 2).is_some() =>
            {
                offset = true;
                at += 6;
            }
            _ => {}
        }
        (at == s.len()).then_some(Shape { date, hour, offset })
    }

    /// Whether V8's `Date` takes `s` (already upper-case). Its ES5 ISO parser,
    /// and of the legacy parser it falls back to only the one case the shapes
    /// of `DATE_TIME_RE` reach: a whole date followed by the zone `Z` (`Z`
    /// or ` Z`) with no time. Any other string the ISO parser does not
    /// consume entirely is refused.
    fn iso_date_valid(s: &[u8]) -> bool {
        if number(s, 0, 4).is_none() {
            return false;
        }
        let mut at = 4;
        if s.get(at) == Some(&b'-') {
            if number(s, at + 1, 2).is_none_or(|month| !(1..=12).contains(&month)) {
                return false;
            }
            at += 3;
            if s.get(at) == Some(&b'-') {
                if number(s, at + 1, 2).is_none_or(|day| !(1..=31).contains(&day)) {
                    return false;
                }
                at += 3;
            }
        }
        if at == s.len() || matches!(&s[at..], b"Z" | b" Z") {
            return true;
        }
        if s[at] != b'T' {
            return false;
        }
        at += 1;
        let Some(hour) = number(s, at, 2).filter(|h| *h <= 24) else {
            return false;
        };
        let hour_is_24 = hour == 24;
        at += 2;
        if s.get(at) != Some(&b':') {
            return false;
        }
        if number(s, at + 1, 2).is_none_or(|minute| minute > 59 || (hour_is_24 && minute > 0)) {
            return false;
        }
        at += 3;
        if s.get(at) == Some(&b':') {
            if number(s, at + 1, 2).is_none_or(|sec| sec > 59 || (hour_is_24 && sec > 0)) {
                return false;
            }
            at += 3;
            if s.get(at) == Some(&b'.') {
                let fraction = &s[at + 1..];
                let digits = fraction.iter().take_while(|b| b.is_ascii_digit()).count();
                if digits == 0 {
                    return false;
                }
                // 24:00:00.000 only: any other fraction digit is non-zero.
                if hour_is_24 && fraction[..digits].iter().any(|d| *d != b'0') {
                    return false;
                }
                at += 1 + digits;
            }
        }
        match s.get(at) {
            Some(b'Z') => at += 1,
            Some(b'+' | b'-') => {
                if number(s, at + 1, 2).is_none_or(|hour| hour > 23) {
                    return false;
                }
                if s.get(at + 3) != Some(&b':') || number(s, at + 4, 2).is_none_or(|m| m > 59) {
                    return false;
                }
                at += 6;
            }
            _ => {}
        }
        at == s.len()
    }

    pub fn is_valid(value: &str) -> bool {
        let bytes = value.as_bytes();
        let Some(shape) = shape(bytes) else {
            return false;
        };
        let has_time = shape.hour.is_some();
        // Rollover hours are not allowed.
        if shape.hour.is_some_and(|hour| hour > 23) {
            return false;
        }
        let mut text = if shape.date {
            value.to_string()
        } else {
            format!("0000-01-01T{value}")
        };
        // Use T instead of a space: the latter breaks on extreme values.
        if has_time && text.as_bytes().get(10) == Some(&b' ') {
            text.replace_range(10..11, "T");
        }
        text.make_ascii_uppercase();
        if !shape.offset && has_time {
            text.push('Z');
        }
        iso_date_valid(text.as_bytes())
    }
}

/// Ports of test/sidebar-config.test.js and test/sidebar-hook.test.js, and
/// the smol-toml behavior the layout depends on.
#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use std::path::PathBuf;
    use std::time::Duration;

    fn vectors() -> Value {
        let path =
            Path::new(env!("CARGO_MANIFEST_DIR")).join("test-vectors/sidebar-layout-v1.json");
        serde_json::from_str(&fs::read_to_string(path).unwrap()).unwrap()
    }

    fn default_config() -> Value {
        json!({
            "agent_panel_sort": "spaces",
            "sidebar": { "agents": {
                "row_gap": 0,
                "rows": [
                    [{ "token": "state_icon" }, { "token": "workspace" }, { "token": "tab" }],
                    [{ "token": "agent" }],
                ],
                "rows_by_agent": {},
            } },
            "diagnostics": [],
        })
    }

    // suite "sidebar layout shared vectors"

    #[test]
    fn sidebar_layout_shared_vectors() {
        let vectors = vectors();
        let all: Vec<&Value> = vectors["valid"]
            .as_array()
            .unwrap()
            .iter()
            .chain(vectors["invalid"].as_array().unwrap())
            .collect();
        assert_eq!(all.len(), 49);
        for vector in all {
            let name = vector["name"].as_str().unwrap();
            let mut expected = vector["snapshot"].clone();
            let object = expected.as_object_mut().unwrap();
            let version = object.remove("v").unwrap();
            let generated_at = object.remove("generated_at").unwrap();
            let source = object.remove("source").unwrap();
            let actual = parse_sidebar_config(vector["toml"].as_str().unwrap());
            assert_eq!(actual, expected, "{name}");
            match vector.get("error") {
                Some(error) => {
                    let mut defaults = default_config();
                    defaults["diagnostics"] = json!([error]);
                    assert_eq!(actual, defaults, "{name}");
                }
                None => assert_eq!(actual["diagnostics"], json!([]), "{name}"),
            }
            assert_eq!(version, json!(1), "{name}");
            assert!(generated_at.is_number(), "{name}");
            assert!(source["mtime_ms"].is_number(), "{name}");
        }
    }

    // suite "sidebar config paths"

    fn env(pairs: &[(&str, &str)]) -> Env {
        Env::from_pairs(pairs.iter().copied())
    }

    #[test]
    fn explicit_path_takes_precedence_over_xdg_and_home() {
        let env = env(&[
            ("HERDR_CONFIG_PATH", "/custom/config.toml"),
            ("XDG_CONFIG_HOME", "/xdg"),
            ("HOME", "/home/u"),
        ]);
        assert_eq!(resolve_config_path(&env), "/custom/config.toml");
    }

    #[test]
    fn xdg_takes_precedence_over_home_and_is_shared_across_sessions() {
        let env = env(&[
            ("XDG_CONFIG_HOME", "/xdg"),
            ("HOME", "/home/u"),
            ("HERDR_SESSION", "other"),
        ]);
        assert_eq!(resolve_config_path(&env), "/xdg/herdr/config.toml");
    }

    #[test]
    fn home_supplies_the_conventional_path() {
        assert_eq!(
            resolve_config_path(&env(&[("HOME", "/home/u")])),
            "/home/u/.config/herdr/config.toml"
        );
    }

    #[test]
    fn unset_home_uses_herdrs_temporary_directory_fallback() {
        assert_eq!(
            resolve_config_path(&Env::default()),
            "/tmp/herdr/config.toml"
        );
        assert_eq!(
            resolve_config_path(&env(&[("TMPDIR", "/var/tmp/")])),
            "/var/tmp/herdr/config.toml"
        );
        assert_eq!(
            resolve_config_path(&env(&[("TMPDIR", ""), ("TMP", "/t")])),
            "/t/herdr/config.toml"
        );
    }

    #[test]
    fn an_explicitly_empty_override_stays_explicit() {
        assert_eq!(
            resolve_config_path(&env(&[("HERDR_CONFIG_PATH", ""), ("HOME", "/home/u")])),
            ""
        );
    }

    #[test]
    fn paths_join_and_normalize_like_path_join() {
        assert_eq!(
            resolve_config_path(&env(&[("XDG_CONFIG_HOME", "rel//x/../y/")])),
            "rel/y/herdr/config.toml"
        );
        assert_eq!(
            resolve_config_path(&env(&[("XDG_CONFIG_HOME", "")])),
            "herdr/config.toml"
        );
        assert_eq!(
            resolve_config_path(&env(&[("HOME", "")])),
            ".config/herdr/config.toml"
        );
    }

    // suite "sidebar snapshot files"

    struct Fixture {
        root: PathBuf,
        path: PathBuf,
        config_dir: PathBuf,
        env: Env,
    }

    impl Fixture {
        fn new(name: &str) -> Self {
            let root =
                std::env::temp_dir().join(format!("wc-sidebar-{name}-{}", std::process::id()));
            let _ = fs::remove_dir_all(&root);
            fs::create_dir_all(&root).unwrap();
            let path = root.join("config.toml");
            let env = env(&[("HERDR_CONFIG_PATH", path.to_str().unwrap())]);
            Self {
                config_dir: root.join("plugin-config"),
                root,
                path,
                env,
            }
        }

        fn refresh_at(&self, now: u64) -> Value {
            refresh_sidebar_snapshot(&self.config_dir, &self.env, &|| now).unwrap()
        }

        fn refresh(&self) -> Value {
            self.refresh_at(1_757_040_000_000)
        }

        fn snapshot_path(&self) -> PathBuf {
            self.config_dir.join("sidebar.json")
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    fn touch(path: &Path, seconds: u64) {
        fs::File::open(path)
            .unwrap()
            .set_modified(UNIX_EPOCH + Duration::from_secs(seconds))
            .unwrap();
    }

    fn mode(path: &Path) -> u32 {
        fs::metadata(path).unwrap().permissions().mode() & 0o777
    }

    const PRIORITY: &str = "[ui]\nagent_panel_sort = \"priority\"\n";

    #[test]
    fn missing_source_writes_complete_defaults_without_diagnostics() {
        let fixture = Fixture::new("missing");
        let actual = fixture.refresh();
        let mut expected = json!({
            "v": 1,
            "generated_at": 1_757_040_000,
            "source": { "path": fixture.path.to_str().unwrap(), "found": false, "mtime_ms": null },
        });
        expected
            .as_object_mut()
            .unwrap()
            .extend(default_config().as_object().unwrap().clone());
        assert_eq!(actual, expected);
        let written: Value =
            serde_json::from_str(&fs::read_to_string(fixture.snapshot_path()).unwrap()).unwrap();
        assert_eq!(written, actual);
        assert_eq!(mode(&fixture.config_dir), 0o700);
        assert_eq!(mode(&fixture.snapshot_path()), 0o600);
    }

    #[test]
    fn mtime_gates_reparsing_and_rewriting_including_cached_invalid_input() {
        let fixture = Fixture::new("gate");
        fs::write(&fixture.path, PRIORITY).unwrap();
        touch(&fixture.path, 1000);
        let first = fixture.refresh();
        let first_stat = fs::metadata(fixture.snapshot_path()).unwrap();
        fs::write(&fixture.path, "[malformed").unwrap();
        touch(&fixture.path, 1000);
        assert_eq!(fixture.refresh_at(1_757_040_100_000), first);
        let stat = fs::metadata(fixture.snapshot_path()).unwrap();
        assert_eq!(stat.modified().unwrap(), first_stat.modified().unwrap());
        assert_eq!(stat.ino(), first_stat.ino());
        touch(&fixture.path, 2000);
        let invalid = fixture.refresh_at(1_757_040_200_000);
        assert_eq!(invalid["agent_panel_sort"], "spaces");
        assert_eq!(invalid["diagnostics"], json!(["parse_error"]));
        assert_eq!(invalid["source"]["mtime_ms"].as_f64(), Some(2_000_000.0));
        assert_eq!(fixture.refresh_at(1_757_040_300_000), invalid);
    }

    #[test]
    fn source_creation_deletion_and_path_changes_invalidate_the_cache() {
        let mut fixture = Fixture::new("invalidate");
        fixture.refresh();
        fs::write(&fixture.path, PRIORITY).unwrap();
        touch(&fixture.path, 1000);
        assert_eq!(fixture.refresh()["agent_panel_sort"], "priority");
        let other = fixture.root.join("other.toml");
        fs::write(&other, "").unwrap();
        touch(&other, 1000);
        fixture
            .env
            .set("HERDR_CONFIG_PATH", other.to_str().unwrap());
        assert_eq!(fixture.refresh()["agent_panel_sort"], "spaces");
        assert_eq!(fixture.refresh()["source"]["path"], other.to_str().unwrap());
        fs::remove_file(&other).unwrap();
        assert_eq!(
            fixture.refresh()["source"],
            json!({ "path": other.to_str().unwrap(), "found": false, "mtime_ms": null })
        );
        assert_eq!(fixture.refresh()["diagnostics"], json!([]));
    }

    #[test]
    fn unreadable_source_reports_defaults_and_retries_at_the_same_mtime() {
        let fixture = Fixture::new("unreadable");
        // Reading a directory fails even when the test process runs as root.
        fs::create_dir(&fixture.path).unwrap();
        touch(&fixture.path, 1000);
        let failed = fixture.refresh();
        assert_eq!(failed["agent_panel_sort"], "spaces");
        assert_eq!(failed["diagnostics"], json!(["read_error"]));
        fs::remove_dir(&fixture.path).unwrap();
        fs::write(&fixture.path, PRIORITY).unwrap();
        touch(&fixture.path, 1000);
        assert_eq!(fixture.refresh()["agent_panel_sort"], "priority");
        assert_eq!(fixture.refresh()["diagnostics"], json!([]));
    }

    #[test]
    fn a_source_behind_a_file_reads_as_read_error() {
        let fixture = Fixture::new("enotdir");
        fs::write(fixture.root.join("file"), "").unwrap();
        let mut env = fixture.env.clone();
        env.set(
            "HERDR_CONFIG_PATH",
            fixture.root.join("file/config.toml").to_str().unwrap(),
        );
        let snapshot = refresh_sidebar_snapshot(&fixture.config_dir, &env, &|| 0).unwrap();
        assert_eq!(snapshot["diagnostics"], json!(["read_error"]));
        assert_eq!(snapshot["source"]["found"], false);
    }

    #[test]
    fn replacement_is_atomic_restores_mode_and_leaves_no_temporary_files() {
        let fixture = Fixture::new("atomic");
        fs::write(&fixture.path, "").unwrap();
        fixture.refresh();
        let first_inode = fs::metadata(fixture.snapshot_path()).unwrap().ino();
        fs::set_permissions(fixture.snapshot_path(), fs::Permissions::from_mode(0o644)).unwrap();
        fs::write(&fixture.path, PRIORITY).unwrap();
        touch(&fixture.path, 2000);
        fixture.refresh();
        assert_ne!(
            fs::metadata(fixture.snapshot_path()).unwrap().ino(),
            first_inode
        );
        assert_eq!(mode(&fixture.snapshot_path()), 0o600);
        let names: Vec<_> = fs::read_dir(&fixture.config_dir)
            .unwrap()
            .map(|e| e.unwrap().file_name())
            .collect();
        assert_eq!(names, ["sidebar.json"]);
    }

    #[test]
    fn corrupt_and_unsupported_snapshots_are_rebuilt() {
        let fixture = Fixture::new("corrupt");
        fixture.refresh();
        fs::write(fixture.snapshot_path(), "{").unwrap();
        assert_eq!(fixture.refresh()["sidebar"], default_config()["sidebar"]);
        let mut old = fixture.refresh();
        old["v"] = json!(2);
        fs::write(fixture.snapshot_path(), old.to_string()).unwrap();
        assert_eq!(fixture.refresh()["v"], 1);
        // Shapes JSON.parse accepts that are no snapshot at all.
        for text in [
            "null",
            "5",
            "\"x\"",
            "[]",
            "{\"v\":1}",
            "{\"v\":1.0,\"source\":5}",
        ] {
            fs::write(fixture.snapshot_path(), text).unwrap();
            assert_eq!(fixture.refresh()["v"], 1, "{text}");
            assert!(
                fs::read_to_string(fixture.snapshot_path())
                    .unwrap()
                    .starts_with("{\"v\":1,"),
                "{text}"
            );
        }
    }

    #[test]
    fn a_snapshot_with_a_read_error_is_never_reused() {
        let fixture = Fixture::new("read-error");
        fs::create_dir(&fixture.path).unwrap();
        touch(&fixture.path, 1000);
        fixture.refresh();
        // The same source state, but the rows are intact and found matches:
        // only the diagnostic keeps it from being reused.
        let mut cached: Value =
            serde_json::from_str(&fs::read_to_string(fixture.snapshot_path()).unwrap()).unwrap();
        cached["source"]["found"] = json!(true);
        fs::write(fixture.snapshot_path(), cached.to_string()).unwrap();
        fs::remove_dir(&fixture.path).unwrap();
        fs::write(&fixture.path, "").unwrap();
        touch(&fixture.path, 1000);
        let fresh = fixture.refresh();
        assert_eq!(fresh["diagnostics"], json!([]));
    }

    #[test]
    fn failed_rename_preserves_the_destination_and_cleans_the_temporary_file() {
        let fixture = Fixture::new("rename");
        fs::create_dir_all(fixture.snapshot_path()).unwrap();
        let error = refresh_sidebar_snapshot(&fixture.config_dir, &fixture.env, &|| 0).unwrap_err();
        assert_eq!(error.code, "EISDIR");
        let names: Vec<_> = fs::read_dir(&fixture.config_dir)
            .unwrap()
            .map(|e| e.unwrap().file_name())
            .collect();
        assert_eq!(names, ["sidebar.json"]);
        assert!(fs::metadata(fixture.snapshot_path()).unwrap().is_dir());
    }

    #[test]
    fn errors_carry_node_style_codes() {
        let code = |errno| errno_code(&io::Error::from_raw_os_error(errno));
        assert_eq!(code(libc::ENOENT), "ENOENT");
        assert_eq!(code(libc::EACCES), "EACCES");
        assert_eq!(code(libc::ENOTDIR), "ENOTDIR");
        assert_eq!(code(libc::EEXIST), "EEXIST");
        assert_eq!(code(libc::ENAMETOOLONG), "ENAMETOOLONG");
        assert_eq!(code(9999), "Unknown system error -9999");
    }

    // JSON.stringify's bytes.

    #[test]
    fn json_text_is_what_json_stringify_writes() {
        let write = |value: Value| {
            let mut out = String::new();
            write_js_json(&value, &mut out);
            out
        };
        assert_eq!(
            write(json!({"a": [1, true, null, "x"], "b": {}})),
            r#"{"a":[1,true,null,"x"],"b":{}}"#
        );
        // Only quote, backslash and C0 controls are escaped; U+2028/9 and DEL are not.
        assert_eq!(
            write(json!(
                "a\"\\\n\t\u{8}\u{c}\r\u{1}\u{1f}\u{7f}\u{2028}\u{2029}é😀"
            )),
            "\"a\\\"\\\\\\n\\t\\b\\f\\r\\u0001\\u001f\u{7f}\u{2028}\u{2029}é😀\""
        );
    }

    // The sidebar hook's startup.

    fn startup_env(fixture: &Fixture) -> Env {
        env(&[
            ("HOME", fixture.root.to_str().unwrap()),
            ("HERDR_CONFIG_PATH", fixture.path.to_str().unwrap()),
            (
                "HERDR_PLUGIN_CONFIG_DIR",
                fixture.config_dir.to_str().unwrap(),
            ),
        ])
    }

    fn read_snapshot(fixture: &Fixture) -> Value {
        serde_json::from_str(&fs::read_to_string(fixture.snapshot_path()).unwrap()).unwrap()
    }

    #[test]
    fn startup_needs_no_event_state_directory_or_herdr_binary() {
        let fixture = Fixture::new("startup");
        fs::create_dir(&fixture.config_dir).unwrap();
        let state_dir = fixture.root.join("state");
        fs::create_dir(&state_dir).unwrap();
        fs::write(
            &fixture.path,
            "[ui.sidebar.agents]\nrows = [[\"terminal_title_stripped\"]]\n",
        )
        .unwrap();
        let outcome = run_sidebar_startup(&startup_env(&fixture));
        assert_eq!(
            outcome,
            StartupOutcome {
                code: 0,
                stderr: String::new()
            }
        );
        let snapshot = read_snapshot(&fixture);
        assert_eq!(
            snapshot["sidebar"]["agents"]["rows"],
            json!([[{"token": "terminal_title_stripped"}]])
        );
        assert_eq!(snapshot["source"]["path"], fixture.path.to_str().unwrap());
        assert_eq!(
            snapshot["source"]["mtime_ms"].as_f64(),
            Some(mtime_ms(&fs::metadata(&fixture.path).unwrap()))
        );
        assert_eq!(mode(&fixture.snapshot_path()), 0o600);
        assert!(!state_dir.join("sidebar.json").exists());
    }

    #[test]
    fn startup_with_no_config_safely_writes_defaults() {
        let fixture = Fixture::new("startup-none");
        fs::create_dir(&fixture.config_dir).unwrap();
        run_sidebar_startup(&startup_env(&fixture));
        let snapshot = read_snapshot(&fixture);
        assert_eq!(
            snapshot["source"],
            json!({"path": fixture.path.to_str().unwrap(), "found": false, "mtime_ms": null})
        );
        assert_eq!(snapshot["agent_panel_sort"], "spaces");
        assert_eq!(snapshot["diagnostics"], json!([]));
    }

    #[test]
    fn startup_reports_what_the_js_printed() {
        let outcome = run_sidebar_startup(&Env::default());
        assert_eq!(outcome.code, 1);
        assert_eq!(
            outcome.stderr,
            "sidebar-hook: HERDR_PLUGIN_CONFIG_DIR is not set\n"
        );
        assert_eq!(
            run_sidebar_startup(&env(&[("HERDR_PLUGIN_CONFIG_DIR", "")])).code,
            1
        );
        let fixture = Fixture::new("startup-fail");
        fs::create_dir_all(fixture.snapshot_path()).unwrap();
        let outcome = run_sidebar_startup(&startup_env(&fixture));
        assert_eq!(
            outcome,
            StartupOutcome {
                code: 1,
                stderr: "sidebar-hook: EISDIR\n".to_string()
            }
        );
    }

    // `${script} refreshes before no-device and no-notification exits`: the
    // snapshot half of the notify-hook and activity-hook tests.
    #[test]
    fn event_hooks_refresh_the_snapshot_and_leave_an_unchanged_one_alone() {
        let fixture = Fixture::new("event");
        fs::write(&fixture.path, "").unwrap();
        touch(&fixture.path, 1000);
        run_sidebar_startup(&startup_env(&fixture));
        fs::write(&fixture.path, PRIORITY).unwrap();
        touch(&fixture.path, 2000);
        let env = startup_env(&fixture);
        assert_eq!(
            refresh_sidebar_snapshot_for_event(&fixture.config_dir, &env),
            None
        );
        let snapshot = read_snapshot(&fixture);
        assert_eq!(snapshot["agent_panel_sort"], "priority");
        assert_eq!(snapshot["source"]["mtime_ms"].as_f64(), Some(2_000_000.0));
        let before = fs::metadata(fixture.snapshot_path()).unwrap();
        assert_eq!(
            refresh_sidebar_snapshot_for_event(&fixture.config_dir, &env),
            None
        );
        let after = fs::metadata(fixture.snapshot_path()).unwrap();
        assert_eq!(
            (after.ino(), after.modified().unwrap()),
            (before.ino(), before.modified().unwrap())
        );
    }

    // `${script} keeps its event path working when snapshot writes fail`
    #[test]
    fn event_hooks_keep_going_when_snapshot_writes_fail() {
        let fixture = Fixture::new("event-fail");
        fs::create_dir_all(fixture.snapshot_path()).unwrap();
        assert_eq!(
            refresh_sidebar_snapshot_for_event(&fixture.config_dir, &startup_env(&fixture))
                .as_deref(),
            Some("sidebar-hook: snapshot refresh failed (EISDIR)")
        );
    }

    // smol-toml, not the toml crate, decides which documents parse.

    fn parses(toml: &str) -> bool {
        parse_sidebar_config(toml)["diagnostics"] != json!(["parse_error"])
    }

    #[test]
    fn documents_parse_as_smol_toml_parses_them() {
        // Integers are BigInt: any size parses and is a bad gap, not a bad file.
        assert!(parses("x = 99999999999999999999\n"));
        assert!(parses("x = 0xFFFFFFFFFFFFFFFFFFFFFFFF\n"));
        assert_eq!(
            parse_sidebar_config("[ui.sidebar.agents]\nrow_gap = 99999999999999999999\n")["diagnostics"],
            json!(["invalid_schema"])
        );
        assert_eq!(
            parse_sidebar_config("[ui.sidebar.agents]\nrow_gap = 0xFFFF\n")["sidebar"]["agents"]["row_gap"],
            65535
        );
        assert_eq!(
            parse_sidebar_config("[ui.sidebar.agents]\nrow_gap = 1_0\n")["sidebar"]["agents"]["row_gap"],
            10
        );
        // Dates are whatever V8's Date accepts.
        assert!(parses("x = 1979-02-30\n"));
        assert!(parses("x = 1979-05-27Z\n"));
        assert!(!parses("x = 1979-05-27T23:59:60\n"));
        // Leniencies the toml crate does not share, and one it does.
        assert!(parses("x = [1\r]\n"));
        assert!(parses("x = 1\u{a0}\n"));
        assert!(parses("[[a]\n"));
        assert!(!parses("\u{feff}x = 1\n"));
        assert!(!parses("x = 0x\n"));
        // A table defined twice is no document.
        assert!(!parses(
            "[ui.sidebar.agents.rows_by_agent]\npi = [[\"pane\"]]\n[ui.sidebar.agents.rows_by_agent.codex]\n[ui.sidebar.agents.rows_by_agent]\nclaude = [[\"agent\"]]\n"
        ));
        // Overrides keep the order they were first defined in.
        let layout = parse_sidebar_config(
            "[ui.sidebar.agents.rows_by_agent]\npi = [[\"pane\"]]\ncodex = [[\"tab\"]]\nclaude = [[\"agent\"]]\n",
        );
        let order: Vec<&str> = layout["sidebar"]["agents"]["rows_by_agent"]
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect();
        assert_eq!(order, ["pi", "codex", "claude"]);
    }

    #[test]
    fn the_first_bad_override_in_javascript_key_order_decides_the_diagnostic() {
        // An array-index key sorts before the others.
        let toml =
            "[ui.sidebar.agents.rows_by_agent]\nclaude = [[\"$bad.\"]]\n\"1\" = [[\"agent\"]]\n";
        assert_eq!(
            parse_sidebar_config(toml)["diagnostics"],
            json!(["invalid_schema"])
        );
        let toml =
            "[ui.sidebar.agents.rows_by_agent]\n\"01\" = [[\"agent\"]]\nclaude = [[\"$bad.\"]]\n";
        assert_eq!(
            parse_sidebar_config(toml)["diagnostics"],
            json!(["invalid_schema"])
        );
        let toml =
            "[ui.sidebar.agents.rows_by_agent]\ncodex = [[\"$bad.\"]]\nclaude = [[\"agent\", 5]]\n";
        assert_eq!(
            parse_sidebar_config(toml)["diagnostics"],
            json!(["invalid_token"])
        );
        let toml =
            "[ui.sidebar.agents.rows_by_agent]\nclaude = [[\"agent\", 5]]\ncodex = [[\"$bad.\"]]\n";
        assert_eq!(
            parse_sidebar_config(toml)["diagnostics"],
            json!(["invalid_schema"])
        );
    }

    #[test]
    fn js_whitespace_is_not_unicode_whitespace() {
        // U+FEFF is trimmed by JavaScript's trim (so the token is invalid) and
        // U+0085 is not (so it is merely an unknown token); both are invalid.
        for token in [
            "agent\\ufeff",
            "agent\\u0085",
            "\\u00a0agent",
            "agent\\u2028",
        ] {
            let toml = format!("[ui.sidebar.agents]\nrows = [[\"{token}\"]]\n");
            assert_eq!(
                parse_sidebar_config(&toml)["diagnostics"],
                json!(["invalid_token"]),
                "{token}"
            );
        }
    }
}
