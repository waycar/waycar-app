//! Host-side Agent Summary store (summary-store.js, see README.md, "Agent
//! Summary").
//!
//! The notify hook and the refresh action keep each Agent's latest summary
//! under `<plugin config dir>/summaries/`, one file per pane, so the app can
//! list them all in a single SSH exec. File name: [`pane_file_name`] (the
//! unpadded base64url of the UTF-8 pane id plus `.json`). Content: one JSON
//! line
//! `{"v":1,"pane":"<id>","status":"working"|"idle"|"done"|"blocked",
//! "summary":"<text>"|null,"ts":<unix ms>,"hash":"<hex sha256>"|null,
//! "progress":{"done":3,"total":7,"phase":"verifying"},"progress_ts":<unix ms>}`.
//! `status` is the Agent's status when its screen was read. `hash` is the
//! sha256 of that normalized screen (null when it was unreadable): the
//! refresh action skips a pane whose screen still hashes the same, and the
//! app ignores it. A null `summary` is a tombstone: the turn produced no
//! summary, and the entry retires the previous one. Writes go through
//! [`write_atomic`].
//!
//! `progress` (Agent Progress; see [`normalize_progress`]) is the Agent's plan
//! steps done in its current turn and/or the model's coarse phase, and
//! `progress_ts` when it was last refreshed (`ts` stays the summary's own
//! time). Every record with a summary names `progress`, null without an
//! estimate: the key itself tells the app this plugin writes progress (older
//! plugins never do). Tombstones carry neither key. Only Working and Blocked
//! records carry an estimate: within a turn the phase never moves backwards
//! (a stored Working or Blocked record's phase is kept as the floor), a
//! Blocked record written without one keeps the stored Working or Blocked
//! record's (the frozen bar), and Done and Idle records, like
//! [`clear_progress`], end the turn with none.
//!
//! The files are shared with the Node tools: what one writes the other reads,
//! byte for byte (key order, number format through `jsx::stringify`,
//! trailing newline, mode 0600, directory 0700).

use std::fs::{self, DirBuilder};
use std::io;
use std::os::unix::fs::{DirBuilderExt, MetadataExt};

use serde_json::{Map, Number, Value};

use crate::atomic::{pane_file_name, write_atomic};
use crate::jspath;
use crate::jsx;

pub const SUMMARY_STORE_VERSION: i64 = 1;
pub const SUMMARIES_DIR: &str = "summaries";
/// Entries for panes that have long since closed are dropped opportunistically.
pub const SUMMARY_MAX_AGE_MS: i64 = 7 * 24 * 60 * 60 * 1000;
/// The phases a `progress.phase` may name, earliest first.
pub const PROGRESS_PHASES: [&str; 4] = ["exploring", "implementing", "verifying", "wrapping_up"];
/// The most plan steps a record may count.
pub const PROGRESS_TOTAL_MAX: i64 = 99;

fn num(x: f64) -> Value {
    Number::from_f64(x).map_or(Value::Null, Value::Number)
}

/// `Number.isInteger(value)` as a number.
fn integer_of(value: &Value) -> Option<f64> {
    jsx::is_integer(value).then(|| value.as_f64()).flatten()
}

/// A record's progress as the store keeps it (`normalizeProgress`): `done`
/// and `total` when both are integers with 0 ≤ done ≤ total and
/// 1 ≤ total ≤ [`PROGRESS_TOTAL_MAX`], and `phase` when it is one of
/// [`PROGRESS_PHASES`]; `None` (JS `null`) when neither holds.
pub fn normalize_progress(value: &Value) -> Option<Map<String, Value>> {
    if !matches!(value, Value::Object(_) | Value::Array(_)) {
        return None;
    }
    let done = jsx::field(value, "done");
    let total = jsx::field(value, "total");
    let phase = jsx::field(value, "phase");
    let mut progress = Map::new();
    if let (Some(d), Some(t)) = (integer_of(done), integer_of(total))
        && d >= 0.0
        && d <= t
        && t >= 1.0
        && t <= PROGRESS_TOTAL_MAX as f64
    {
        progress.insert("done".into(), done.clone());
        progress.insert("total".into(), total.clone());
    }
    if phase
        .as_str()
        .is_some_and(|phase| PROGRESS_PHASES.contains(&phase))
    {
        progress.insert("phase".into(), phase.clone());
    }
    (!progress.is_empty()).then_some(progress)
}

fn has_text(entry: Option<&Value>) -> bool {
    entry.is_some_and(|entry| jsx::field(entry, "summary").is_string())
}

fn phase_index(phase: Option<&str>) -> isize {
    phase
        .and_then(|phase| PROGRESS_PHASES.iter().position(|p| *p == phase))
        .map_or(-1, |index| index as isize)
}

/// The later of two phases (a missing one is earliest), or `None` (JS null).
fn later_phase<'a>(a: Option<&'a str>, b: Option<&'a str>) -> Option<&'a str> {
    if phase_index(a) >= phase_index(b) {
        a
    } else {
        b
    }
}

fn phase_of(progress: &Option<Map<String, Value>>) -> Option<&str> {
    progress
        .as_ref()
        .and_then(|map| map.get("phase"))
        .and_then(Value::as_str)
}

/// Whether the stored record is a Working or Blocked one with a summary: its
/// turn is still open.
fn in_turn(stored: Option<&Value>) -> bool {
    has_text(stored)
        && stored.is_some_and(|stored| {
            matches!(
                jsx::field(stored, "status").as_str(),
                Some("working" | "blocked")
            )
        })
}

/// `progress` with its phase raised to a stored Working or Blocked record's:
/// within a turn the phase only moves forward, and a Blocked record (an
/// approval asked mid-turn) does not end the turn. Only an Idle or Done
/// record (which carries no progress) or [`clear_progress`] starts it afresh.
fn forward_phase(progress: &Value, stored: Option<&Value>) -> Option<Map<String, Value>> {
    let stored_progress = if in_turn(stored) {
        stored.and_then(|stored| normalize_progress(jsx::field(stored, "progress")))
    } else {
        None
    };
    let own = normalize_progress(progress);
    let phase = later_phase(phase_of(&own), phase_of(&stored_progress));
    let mut spread = match progress {
        Value::Object(map) => map.clone(),
        _ => Map::new(),
    };
    spread.insert(
        "phase".into(),
        phase.map_or(Value::Null, |phase| Value::String(phase.into())),
    );
    normalize_progress(&Value::Object(spread))
}

/// The progress a new record for `status` carries, by the rules in the header.
fn record_progress(
    status: &str,
    summary: Option<&str>,
    progress: &Value,
    stored: Option<&Value>,
) -> Option<Map<String, Value>> {
    summary?;
    if status == "working" {
        return forward_phase(progress, stored);
    }
    if status != "blocked" {
        return None;
    }
    if !progress.is_null() {
        return normalize_progress(progress);
    }
    if in_turn(stored) {
        stored.and_then(|stored| normalize_progress(jsx::field(stored, "progress")))
    } else {
        None
    }
}

/// The fields of one store line; `None` is JS `undefined` (key omitted).
struct Line<'a> {
    pane_id: &'a str,
    status: Option<Value>,
    summary: Value,
    ts: Option<Value>,
    hash: Value,
    progress: Option<Map<String, Value>>,
    progress_ts: Option<f64>,
}

/// `recordLine`: one store line. A record with a summary always names its
/// `progress` (null without an estimate): the key tells the app this plugin
/// writes progress at all. `progress_ts` rides only with a progress; a
/// tombstone carries neither.
fn record_line(line: &Line<'_>) -> String {
    let mut record = Map::new();
    record.insert("v".into(), Value::from(SUMMARY_STORE_VERSION));
    record.insert("pane".into(), Value::String(line.pane_id.into()));
    if let Some(status) = &line.status {
        record.insert("status".into(), status.clone());
    }
    record.insert("summary".into(), line.summary.clone());
    if let Some(ts) = &line.ts {
        record.insert("ts".into(), ts.clone());
    }
    record.insert("hash".into(), line.hash.clone());
    if line.summary.is_string() {
        record.insert(
            "progress".into(),
            line.progress.clone().map_or(Value::Null, Value::Object),
        );
    }
    if line.summary.is_string()
        && line.progress.is_some()
        && let Some(progress_ts) = line.progress_ts.filter(|ts| jsx::is_integer(&num(*ts)))
    {
        record.insert("progress_ts".into(), num(progress_ts));
    }
    format!("{}\n", jsx::stringify(&Value::Object(record)))
}

fn has_steps(progress: &Option<Map<String, Value>>) -> bool {
    progress
        .as_ref()
        .is_some_and(|map| map.contains_key("done"))
}

/// `===` of two JSON values read from files (`undefined` is `None`); two
/// objects or arrays are never equal, as distinct references.
fn strict_equal(a: Option<&Value>, b: Option<&Value>) -> bool {
    match (a, b) {
        (None, None) => true,
        (Some(Value::Null), Some(Value::Null)) => true,
        (Some(Value::Bool(a)), Some(Value::Bool(b))) => a == b,
        (Some(Value::String(a)), Some(Value::String(b))) => a == b,
        (Some(Value::Number(a)), Some(Value::Number(b))) => jsx::json_f64(a) == jsx::json_f64(b),
        _ => false,
    }
}

/// Whether `entry` is still the record `seen` was (same summary, status, and time).
fn unchanged_since(seen: &Value, entry: Option<&Value>) -> bool {
    let of = |value: &'_ Value, key: &str| jsx::get(value, key).cloned();
    ["ts", "summary", "status"].iter().all(|key| {
        let theirs = entry.and_then(|entry| of(entry, key));
        strict_equal(theirs.as_ref(), of(seen, key).as_ref())
    })
}

/// Rewrite `seen`'s file with new progress, keeping everything else, unless
/// another writer replaced the record since it was read: a Done or Blocked
/// summary written meanwhile must not be lost.
fn rewrite_progress(
    config_dir: &str,
    pane_id: &str,
    seen: &Value,
    progress: Option<Map<String, Value>>,
    progress_ts: Option<f64>,
) -> io::Result<bool> {
    if !unchanged_since(seen, read_summary(config_dir, pane_id).as_ref()) {
        return Ok(false);
    }
    let hash = jsx::field(seen, "hash");
    let line = record_line(&Line {
        pane_id,
        status: jsx::get(seen, "status").cloned(),
        summary: jsx::field(seen, "summary").clone(),
        ts: jsx::get(seen, "ts").cloned(),
        hash: if hash.is_string() {
            hash.clone()
        } else {
            Value::Null
        },
        progress,
        progress_ts,
    });
    write_atomic(
        std::path::Path::new(&summary_path(config_dir, pane_id)),
        line.as_bytes(),
        0o600,
    )?;
    Ok(true)
}

/// `summaryPath(configDir, paneId)`.
pub fn summary_path(config_dir: &str, pane_id: &str) -> String {
    jspath::join(&[config_dir, SUMMARIES_DIR, &pane_file_name(pane_id)])
}

/// `readSummary(configDir, paneId)`: a pane's stored entry (a JSON object or
/// array), `None` when it is missing or unreadable.
pub fn read_summary(config_dir: &str, pane_id: &str) -> Option<Value> {
    let bytes = fs::read(summary_path(config_dir, pane_id)).ok()?;
    let entry = jsx::parse_json(&String::from_utf8_lossy(&bytes))?;
    matches!(entry, Value::Object(_) | Value::Array(_)).then_some(entry)
}

/// `writeSummary`'s options. `summary: None` is a tombstone. `progress` is
/// `Value::Null` for none, else `{done?, total?, phase?}`.
pub struct SummaryWrite<'a> {
    pub pane_id: &'a str,
    pub status: &'a str,
    pub summary: Option<&'a str>,
    pub ts: i64,
    pub hash: Option<&'a str>,
    pub progress: &'a Value,
}

fn make_dir(path: &str) -> io::Result<()> {
    DirBuilder::new().recursive(true).mode(0o700).create(path)
}

/// `writeSummary`: record a pane's latest summary, or a tombstone when
/// `summary` is `None`. A stored entry with a newer `ts` wins: two hook
/// processes for the same pane can finish out of order, and the older
/// transition must not overwrite the newer one's entry. `progress` follows
/// the header's rules; when the record carries one, its `progress_ts` is
/// `ts`. Returns whether the entry was written.
pub fn write_summary(config_dir: &str, write: &SummaryWrite<'_>) -> io::Result<bool> {
    make_dir(&jspath::join(&[config_dir, SUMMARIES_DIR]))?;
    let path = summary_path(config_dir, write.pane_id);
    let stored = read_summary(config_dir, write.pane_id);
    let ts = write.ts as f64;
    if let Some(stored_ts) = stored
        .as_ref()
        .and_then(|stored| integer_of(jsx::field(stored, "ts")))
        && stored_ts > ts
    {
        return Ok(false);
    }
    let kept = record_progress(write.status, write.summary, write.progress, stored.as_ref());
    let line = record_line(&Line {
        pane_id: write.pane_id,
        status: Some(Value::String(write.status.into())),
        summary: write
            .summary
            .map_or(Value::Null, |summary| Value::String(summary.into())),
        ts: Some(num(ts)),
        hash: write
            .hash
            .map_or(Value::Null, |hash| Value::String(hash.into())),
        progress: kept,
        progress_ts: Some(ts),
    });
    write_atomic(std::path::Path::new(&path), line.as_bytes(), 0o600)?;
    Ok(true)
}

/// `writeProgress`'s options (`progress`: `Value::Null` or `{done?, total?, phase?}`).
pub struct ProgressWrite<'a> {
    pub pane_id: &'a str,
    pub status: &'a str,
    pub progress: &'a Value,
    pub ts: i64,
}

/// `writeProgress`: refresh the progress of the pane's stored record,
/// keeping its summary, `ts`, hash, and phase (`progress.phase`, when given,
/// still never lowers the stored one). Without `done`/`total` the steps are
/// dropped. Nothing is written unless the stored record has a summary and is
/// for `status`, or when another writer replaces it first. `progress_ts`
/// moves to `ts` only when the stored or the new progress has plan steps:
/// those were just read and are current even when unchanged, while a
/// phase-only progress keeps the age of the model answer that named the
/// phase. Returns whether the stored progress changed.
pub fn write_progress(config_dir: &str, write: &ProgressWrite<'_>) -> io::Result<bool> {
    let Some(stored) = read_summary(config_dir, write.pane_id) else {
        return Ok(false);
    };
    if !has_text(Some(&stored)) || jsx::field(&stored, "status").as_str() != Some(write.status) {
        return Ok(false);
    }
    let current = normalize_progress(jsx::field(&stored, "progress"));
    let mut steps = Map::new();
    steps.insert("done".into(), jsx::field(write.progress, "done").clone());
    steps.insert("total".into(), jsx::field(write.progress, "total").clone());
    let mut only_phase = Map::new();
    only_phase.insert("phase".into(), jsx::field(write.progress, "phase").clone());
    let given = normalize_progress(&Value::Object(only_phase));
    let phase = later_phase(phase_of(&given), phase_of(&current));
    steps.insert(
        "phase".into(),
        phase.map_or(Value::Null, |phase| Value::String(phase.into())),
    );
    let next = normalize_progress(&Value::Object(steps));
    let text = |progress: &Option<Map<String, Value>>| {
        progress
            .clone()
            .map_or_else(|| "null".to_string(), |m| jsx::stringify(&Value::Object(m)))
    };
    let changed = text(&next) != text(&current);
    let stored_ts = integer_of(jsx::field(&stored, "progress_ts"));
    let ts = write.ts as f64;
    let progress_ts = if has_steps(&current) || has_steps(&next) {
        Some(stored_ts.unwrap_or(ts).max(ts))
    } else {
        stored_ts
    };
    if !changed && progress_ts == stored_ts {
        return Ok(false);
    }
    Ok(rewrite_progress(config_dir, write.pane_id, &stored, next, progress_ts)? && changed)
}

/// `clearProgress`: drop the pane's stored progress (`progress` becomes null,
/// `progress_ts` goes), keeping its summary, status, and `ts`: the Agent's
/// turn ended, and the next one must not inherit its steps or phase. Returns
/// whether the entry was rewritten.
pub fn clear_progress(config_dir: &str, pane_id: &str) -> io::Result<bool> {
    let Some(stored) = read_summary(config_dir, pane_id) else {
        return Ok(false);
    };
    if !has_text(Some(&stored))
        || (normalize_progress(jsx::field(&stored, "progress")).is_none()
            && jsx::get(&stored, "progress_ts").is_none())
    {
        return Ok(false);
    }
    rewrite_progress(config_dir, pane_id, &stored, None, None)
}

/// `removeSummaries`: delete the whole store (summaries were switched off on
/// this Host). A missing store is fine (`rmSync` with `force`).
pub fn remove_summaries(config_dir: &str) -> io::Result<()> {
    let path = jspath::join(&[config_dir, SUMMARIES_DIR]);
    let result = match fs::symlink_metadata(&path) {
        Ok(meta) if meta.is_dir() => fs::remove_dir_all(&path),
        Ok(_) => fs::remove_file(&path),
        Err(error) => Err(error),
    };
    match result {
        Err(error) if error.kind() != io::ErrorKind::NotFound => Err(error),
        _ => Ok(()),
    }
}

/// `pruneSummaries(configDir, {now, maxAgeMs})`: delete store files (entries
/// and stray temp files) last modified more than `max_age_ms` before `now_ms`.
/// Best-effort: a missing directory or a file that vanishes mid-scan is not
/// an error. (`rmSync` without `recursive` leaves a directory alone.)
pub fn prune_summaries(config_dir: &str, now_ms: i64, max_age_ms: i64) {
    let dir = jspath::join(&[config_dir, SUMMARIES_DIR]);
    let Ok(names) = fs::read_dir(&dir) else {
        return;
    };
    for name in names.flatten().map(|entry| entry.file_name()) {
        let path = std::path::Path::new(&dir).join(&name);
        let Ok(meta) = fs::metadata(&path) else {
            continue;
        };
        let mtime_ms = meta.mtime() as f64 * 1e3 + meta.mtime_nsec() as f64 / 1e6;
        let is_dir = fs::symlink_metadata(&path).is_ok_and(|link| link.is_dir());
        if now_ms as f64 - mtime_ms > max_age_ms as f64 && !is_dir {
            let _ = fs::remove_file(&path);
        }
    }
}

#[cfg(test)]
#[path = "store_tests.rs"]
mod tests;
