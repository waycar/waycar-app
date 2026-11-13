//! The tests of summary-store.test.js, one for one (the vector cases and
//! the table-driven ones iterate inside one test).

use std::fs;
use std::time::{Duration, SystemTime};

use serde_json::{Value, json};

use super::*;
use crate::summary::test_support::TempDir;

const VECTOR: &str = include_str!("../../test-vectors/agent-summary-store-v1.json");

fn vector_cases() -> Vec<Value> {
    let vector: Value = serde_json::from_str(VECTOR).expect("vector json");
    vector["cases"].as_array().expect("cases").clone()
}

/// What the app keeps of one store line (AgentSummary.latestByPane), with the
/// Rust normalizer.
fn read_line(line: &str) -> Option<Value> {
    let entry: Value = serde_json::from_str(line).ok()?;
    if !entry.is_object() {
        return None;
    }
    if let Some(v) = entry.get("v")
        && v.as_f64() != Some(1.0)
    {
        return None;
    }
    let status = entry
        .get("status")
        .and_then(Value::as_str)
        .map(|s| jsx::trim(s).to_lowercase());
    let status = status.filter(|s| ["working", "idle", "done", "blocked"].contains(&s.as_str()))?;
    let pane = entry
        .get("pane")
        .and_then(Value::as_str)
        .filter(|p| !p.is_empty())?;
    let summary = entry
        .get("summary")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())?;
    let progress = normalize_progress(jsx::field(&entry, "progress"));
    let mut kept = json!({
        "pane": pane,
        "status": status,
        "summary": summary,
        "ts": jsx::field(&entry, "ts"),
        "progress": progress.clone().map_or(Value::Null, Value::Object),
        // The key at all, whatever its value: a plugin that writes progress.
        "declares_progress": entry.get("progress").is_some(),
    });
    if progress.is_some()
        && let Some(ts) = jsx::field(&entry, "progress_ts").as_f64()
    {
        kept["progress_ts"] = json!((ts + 0.5).floor() as i64);
    }
    Some(kept)
}

fn path_of(dir: &TempDir, pane: &str) -> String {
    summary_path(dir.str(), pane)
}

fn raw_of(dir: &TempDir, pane: &str) -> String {
    fs::read_to_string(path_of(dir, pane)).expect("stored file")
}

fn simple(
    dir: &TempDir,
    pane: &str,
    status: &str,
    summary: Option<&str>,
    ts: i64,
    hash: Option<&str>,
) -> bool {
    write_summary(
        dir.str(),
        &SummaryWrite {
            pane_id: pane,
            status,
            summary,
            ts,
            hash,
            progress: &Value::Null,
        },
    )
    .expect("write")
}

fn names(dir: &TempDir) -> Vec<String> {
    let mut names: Vec<String> = fs::read_dir(dir.join("summaries"))
        .expect("summaries dir")
        .map(|e| e.expect("entry").file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    names
}

// MARK: - summary store

#[test]
fn names_each_file_by_the_unpadded_base64url_of_the_pane_id() {
    let dir = TempDir::new("summary-store");
    let base = |pane: &str| {
        std::path::Path::new(&path_of(&dir, pane))
            .file_name()
            .unwrap()
            .to_string_lossy()
            .into_owned()
    };
    assert_eq!(base("wV:p1"), "d1Y6cDE.json");
    assert_eq!(base("w1/p%2"), "dzEvcCUy.json");
    assert!(!base("a").contains('='));
}

#[test]
fn writes_one_contract_json_line_and_leaves_no_temp_file_behind() {
    let dir = TempDir::new("summary-store");
    let written = simple(
        &dir,
        "wV:p1",
        "blocked",
        Some("approve merge of PR #512"),
        1753305600123,
        Some("ab12"),
    );
    assert!(written);
    assert_eq!(
        raw_of(&dir, "wV:p1"),
        "{\"v\":1,\"pane\":\"wV:p1\",\"status\":\"blocked\",\"summary\":\"approve merge of PR #512\",\"ts\":1753305600123,\"hash\":\"ab12\",\"progress\":null}\n"
    );
    assert_eq!(names(&dir), ["d1Y6cDE.json"]);
}

#[test]
fn every_agent_status_round_trips_with_its_summary_and_screen_hash() {
    let dir = TempDir::new("summary-store");
    let statuses = ["working", "idle", "done", "blocked"];
    for (index, status) in statuses.iter().enumerate() {
        simple(
            &dir,
            &format!("w1:p{index}"),
            status,
            Some(&format!("{status} line")),
            index as i64,
            Some(&format!("h{index}")),
        );
    }
    for (index, status) in statuses.iter().enumerate() {
        assert_eq!(
            read_summary(dir.str(), &format!("w1:p{index}")),
            Some(json!({
                "v": 1,
                "pane": format!("w1:p{index}"),
                "status": status,
                "summary": format!("{status} line"),
                "ts": index,
                "hash": format!("h{index}"),
                "progress": null,
            }))
        );
    }
    assert_eq!(read_summary(dir.str(), "w1:missing"), None);
}

#[test]
fn a_newer_transition_replaces_the_entry() {
    let dir = TempDir::new("summary-store");
    simple(&dir, "wV:p1", "blocked", Some("approve merge"), 1000, None);
    simple(&dir, "wV:p1", "done", Some("merged PR #512"), 2000, None);
    let entry: Value = serde_json::from_str(&raw_of(&dir, "wV:p1")).unwrap();
    assert_eq!(entry["status"], "done");
    assert_eq!(entry["summary"], "merged PR #512");
}

/// Two hook processes for one pane can finish out of order.
#[test]
fn an_older_transition_finishing_late_does_not_overwrite_a_newer_one() {
    let dir = TempDir::new("summary-store");
    simple(&dir, "wV:p1", "done", Some("merged PR #512"), 2000, None);
    let written = simple(&dir, "wV:p1", "blocked", Some("approve merge"), 1000, None);
    assert!(!written);
    let entry: Value = serde_json::from_str(&raw_of(&dir, "wV:p1")).unwrap();
    assert_eq!(entry["status"], "done");
}

#[test]
fn a_corrupt_existing_entry_is_replaced() {
    let dir = TempDir::new("summary-store");
    fs::create_dir(dir.join("summaries")).unwrap();
    fs::write(path_of(&dir, "wV:p1"), "{not json").unwrap();
    assert!(simple(&dir, "wV:p1", "done", Some("ok"), 1, None));
}

#[test]
fn pruning_drops_entries_older_than_the_maximum_age_and_keeps_fresh_ones() {
    let dir = TempDir::new("summary-store");
    simple(&dir, "old", "done", Some("a"), 1, None);
    simple(&dir, "new", "done", Some("b"), 2, None);
    let now = SystemTime::now();
    let now_ms = now
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64;
    let stale = now - Duration::from_millis(SUMMARY_MAX_AGE_MS as u64 + 60_000);
    fs::File::options()
        .write(true)
        .open(path_of(&dir, "old"))
        .unwrap()
        .set_modified(stale)
        .unwrap();
    prune_summaries(dir.str(), now_ms, SUMMARY_MAX_AGE_MS);
    assert_eq!(names(&dir), ["bmV3.json"]);
}

// MARK: - agent-summary-store-v1 vector

#[test]
fn the_vector_cases_read_as_expected() {
    let cases = vector_cases();
    assert_eq!(cases.len(), 33);
    for case in &cases {
        let line = case["line"].as_str().unwrap();
        let expected = &case["expected"];
        assert_eq!(
            read_line(line).unwrap_or(Value::Null),
            *expected,
            "{}",
            case["name"]
        );
    }
}

#[test]
fn the_vector_covers_every_phase_the_step_bounds_and_dropped_lines() {
    let cases = vector_cases();
    let line_progress = |case: &Value| -> Value {
        let line: Value = serde_json::from_str(case["line"].as_str().unwrap()).unwrap();
        jsx::field(&line, "progress").clone()
    };
    let line_has = |case: &Value, key: &str| -> bool {
        let line: Value = serde_json::from_str(case["line"].as_str().unwrap()).unwrap();
        jsx::truthy(jsx::field(&line, key))
    };
    let mut phases: Vec<&str> = cases
        .iter()
        .filter_map(|c| c["expected"]["progress"]["phase"].as_str())
        .collect();
    phases.sort_unstable();
    phases.dedup();
    let mut known = PROGRESS_PHASES.to_vec();
    known.sort_unstable();
    assert_eq!(phases, known);
    assert!(
        cases
            .iter()
            .any(|c| c["expected"]["progress"]["total"] == 99)
    );
    assert!(
        cases
            .iter()
            .any(|c| c["expected"].is_null() && jsx::truthy(&line_progress(c)))
    );
    assert!(cases.iter().any(|c| {
        matches!(
            (c["expected"]["progress_ts"].as_f64(), c["expected"]["ts"].as_f64()),
            (Some(progress_ts), Some(ts)) if progress_ts > ts
        )
    }));
    assert!(cases.iter().any(|c| c["expected"]["progress"].is_null()
        && !c["expected"].is_null()
        && line_has(c, "progress_ts")));
    assert!(
        cases
            .iter()
            .any(|c| { c["expected"]["declares_progress"] == true && line_progress(c).is_null() })
    );
    assert!(
        cases
            .iter()
            .any(|c| c["expected"]["declares_progress"] == false)
    );
}

/// `write_summary` stamps the progress it writes with the record's own ts.
#[test]
fn the_writer_stores_each_kept_progress_so_a_reader_gets_it_back_unchanged() {
    let dir = TempDir::new("summary-store");
    let mut checked = 0;
    for case in vector_cases() {
        let expected = &case["expected"];
        let status = expected["status"].as_str().unwrap_or("");
        if expected["progress"].is_null() || !["working", "blocked"].contains(&status) {
            continue;
        }
        remove_summaries(dir.str()).unwrap();
        let pane = expected["pane"].as_str().unwrap();
        write_summary(
            dir.str(),
            &SummaryWrite {
                pane_id: pane,
                status,
                summary: expected["summary"].as_str(),
                ts: expected["ts"].as_i64().unwrap(),
                hash: Some("ab12"),
                progress: &expected["progress"],
            },
        )
        .unwrap();
        let line = raw_of(&dir, pane);
        let mut want = expected.clone();
        want["progress_ts"] = expected["ts"].clone();
        assert_eq!(read_line(line.trim_end()), Some(want), "{}", case["name"]);
        checked += 1;
    }
    assert!(checked > 0);
}

// MARK: - summary store: Agent Progress

const PANE: &str = "w1:p1";

fn write(dir: &TempDir, status: &str, summary: Option<&str>, ts: i64, progress: Value) -> bool {
    write_summary(
        dir.str(),
        &SummaryWrite {
            pane_id: PANE,
            status,
            summary,
            ts,
            hash: Some("h"),
            progress: &progress,
        },
    )
    .unwrap()
}

fn progress_of(dir: &TempDir) -> Value {
    // JS `readSummary(...)?.progress`: undefined (a missing key) is not null.
    match read_summary(dir.str(), PANE) {
        Some(entry) => jsx::get(&entry, "progress")
            .cloned()
            .unwrap_or_else(|| json!("<undefined>")),
        None => json!("<undefined>"),
    }
}

fn update(dir: &TempDir, status: &str, progress: Value, ts: i64) -> bool {
    write_progress(
        dir.str(),
        &ProgressWrite {
            pane_id: PANE,
            status,
            progress: &progress,
            ts,
        },
    )
    .unwrap()
}

fn stored(dir: &TempDir) -> Value {
    read_summary(dir.str(), PANE).unwrap()
}

#[test]
fn a_working_record_stores_its_steps_and_phase_after_the_hash() {
    let dir = TempDir::new("summary-store");
    write(
        &dir,
        "working",
        Some("editing"),
        1,
        json!({"done": 3, "total": 7, "phase": "implementing"}),
    );
    assert_eq!(
        raw_of(&dir, PANE),
        "{\"v\":1,\"pane\":\"w1:p1\",\"status\":\"working\",\"summary\":\"editing\",\"ts\":1,\"hash\":\"h\",\"progress\":{\"done\":3,\"total\":7,\"phase\":\"implementing\"},\"progress_ts\":1}\n"
    );
}

#[test]
fn invalid_parts_are_left_out_and_nothing_valid_writes_progress_null() {
    let dir = TempDir::new("summary-store");
    write(
        &dir,
        "working",
        Some("editing"),
        1,
        json!({"done": 9, "total": 7, "phase": "implementing"}),
    );
    assert_eq!(progress_of(&dir), json!({"phase": "implementing"}));

    write(&dir, "idle", Some("waiting"), 2, Value::Null);
    write(
        &dir,
        "working",
        Some("editing"),
        3,
        json!({"done": 1, "total": 100, "phase": "deploying"}),
    );
    assert_eq!(stored(&dir)["progress"], Value::Null);
    assert!(jsx::get(&stored(&dir), "progress_ts").is_none());
}

/// Every record with a summary names `progress`, so the app can tell this
/// plugin from an older one; a tombstone names nothing.
#[test]
fn records_with_a_summary_always_carry_the_progress_key_tombstones_never() {
    let dir = TempDir::new("summary-store");
    for status in ["working", "idle", "done", "blocked"] {
        write(
            &dir,
            status,
            Some(&format!("{status} line")),
            1,
            Value::Null,
        );
        assert!(jsx::get(&stored(&dir), "progress").is_some(), "{status}");
        remove_summaries(dir.str()).unwrap();
    }
    write(&dir, "done", None, 1, json!({"done": 1, "total": 2}));
    assert!(jsx::get(&stored(&dir), "progress").is_none());
}

#[test]
fn within_a_turn_the_phase_never_moves_backwards() {
    let dir = TempDir::new("summary-store");
    write(
        &dir,
        "working",
        Some("testing"),
        1,
        json!({"phase": "verifying"}),
    );
    write(
        &dir,
        "working",
        Some("editing"),
        2,
        json!({"done": 2, "total": 5, "phase": "implementing"}),
    );
    assert_eq!(
        progress_of(&dir),
        json!({"done": 2, "total": 5, "phase": "verifying"})
    );

    // An answer without the phase line keeps the phase too.
    write(
        &dir,
        "working",
        Some("editing"),
        3,
        json!({"done": 3, "total": 5}),
    );
    assert_eq!(
        progress_of(&dir),
        json!({"done": 3, "total": 5, "phase": "verifying"})
    );

    write(
        &dir,
        "working",
        Some("committing"),
        4,
        json!({"phase": "wrapping_up"}),
    );
    assert_eq!(progress_of(&dir), json!({"phase": "wrapping_up"}));
}

#[test]
fn a_done_or_idle_record_carries_no_progress_and_the_next_turns_phase_starts_afresh() {
    for end in ["done", "idle"] {
        let dir = TempDir::new("summary-store");
        write(
            &dir,
            "working",
            Some("committing"),
            1,
            json!({"done": 4, "total": 4, "phase": "wrapping_up"}),
        );
        write(
            &dir,
            end,
            Some("finished"),
            2,
            json!({"done": 4, "total": 4, "phase": "wrapping_up"}),
        );
        assert_eq!(progress_of(&dir), Value::Null);

        write(
            &dir,
            "working",
            Some("reading"),
            3,
            json!({"phase": "exploring"}),
        );
        assert_eq!(progress_of(&dir), json!({"phase": "exploring"}));
    }
}

#[test]
fn a_blocked_record_without_progress_keeps_the_working_records_frozen_bar() {
    let dir = TempDir::new("summary-store");
    write(
        &dir,
        "working",
        Some("migrating"),
        1,
        json!({"done": 3, "total": 7, "phase": "implementing"}),
    );
    write(&dir, "blocked", Some("needs approval"), 2, Value::Null);
    assert_eq!(
        progress_of(&dir),
        json!({"done": 3, "total": 7, "phase": "implementing"})
    );

    // And a later Blocked one keeps it again.
    write(
        &dir,
        "blocked",
        Some("still needs approval"),
        3,
        Value::Null,
    );
    assert_eq!(
        progress_of(&dir),
        json!({"done": 3, "total": 7, "phase": "implementing"})
    );
}

/// A mid-turn approval: Working (verifying) → Blocked → approved → Working.
#[test]
fn a_blocked_record_in_between_does_not_let_the_phase_fall_back() {
    let dir = TempDir::new("summary-store");
    write(
        &dir,
        "working",
        Some("running tests"),
        1,
        json!({"phase": "verifying"}),
    );
    write(&dir, "blocked", Some("allow the test run?"), 2, Value::Null);
    write(
        &dir,
        "working",
        Some("reading the failure"),
        3,
        json!({"phase": "exploring"}),
    );
    assert_eq!(progress_of(&dir), json!({"phase": "verifying"}));

    // Only a turn end resets it.
    clear_progress(dir.str(), PANE).unwrap();
    write(
        &dir,
        "working",
        Some("reading the failure"),
        4,
        json!({"phase": "exploring"}),
    );
    assert_eq!(progress_of(&dir), json!({"phase": "exploring"}));
}

#[test]
fn a_blocked_record_inherits_nothing_after_a_turn_end_and_its_own_progress_wins() {
    let dir = TempDir::new("summary-store");
    write(&dir, "done", Some("finished"), 1, Value::Null);
    write(&dir, "blocked", Some("needs approval"), 2, Value::Null);
    assert_eq!(progress_of(&dir), Value::Null);

    write(
        &dir,
        "blocked",
        Some("needs approval"),
        3,
        json!({"done": 1, "total": 2}),
    );
    assert_eq!(progress_of(&dir), json!({"done": 1, "total": 2}));
}

#[test]
fn a_tombstone_never_carries_progress_and_leaves_none_to_inherit() {
    let dir = TempDir::new("summary-store");
    write(
        &dir,
        "working",
        Some("migrating"),
        1,
        json!({"done": 3, "total": 7, "phase": "implementing"}),
    );
    write(
        &dir,
        "working",
        None,
        2,
        json!({"done": 4, "total": 7, "phase": "verifying"}),
    );
    assert_eq!(progress_of(&dir), json!("<undefined>"));

    write(&dir, "blocked", None, 3, Value::Null);
    assert_eq!(progress_of(&dir), json!("<undefined>"));
    write(&dir, "blocked", Some("needs approval"), 4, Value::Null);
    assert_eq!(progress_of(&dir), Value::Null);
}

#[test]
fn write_progress_replaces_the_steps_keeping_summary_ts_hash_and_phase() {
    let dir = TempDir::new("summary-store");
    write(
        &dir,
        "working",
        Some("migrating"),
        10,
        json!({"done": 3, "total": 7, "phase": "implementing"}),
    );

    assert!(update(&dir, "working", json!({"done": 4, "total": 7}), 20));
    assert_eq!(
        stored(&dir),
        json!({
            "v": 1,
            "pane": PANE,
            "status": "working",
            "summary": "migrating",
            "ts": 10,
            "hash": "h",
            "progress": {"done": 4, "total": 7, "phase": "implementing"},
            "progress_ts": 20,
        })
    );

    // The plan went away: the steps go, the phase stays; a lower phase is ignored.
    assert!(update(&dir, "working", json!({"phase": "exploring"}), 5));
    assert_eq!(stored(&dir)["progress"], json!({"phase": "implementing"}));
    assert_eq!(stored(&dir)["progress_ts"], 20);
}

/// A summary text stays as old as its screen read: refreshing the steps must
/// neither make it look fresh nor make a hook's later summary (read before
/// the steps were refreshed) look out of date.
#[test]
fn write_progress_never_moves_ts_so_a_summary_read_before_it_still_lands() {
    let dir = TempDir::new("summary-store");
    write(
        &dir,
        "working",
        Some("migrating"),
        1000,
        json!({"done": 3, "total": 7}),
    );
    update(&dir, "working", json!({"done": 4, "total": 7}), 3000);

    assert!(write(
        &dir,
        "blocked",
        Some("needs approval"),
        2000,
        Value::Null
    ));
    assert_eq!(
        stored(&dir),
        json!({
            "v": 1,
            "pane": PANE,
            "status": "blocked",
            "summary": "needs approval",
            "ts": 2000,
            "hash": "h",
            "progress": {"done": 4, "total": 7},
            "progress_ts": 2000,
        })
    );
}

#[test]
fn write_progress_keeps_an_unchanged_progress_current_without_reporting_a_change() {
    let dir = TempDir::new("summary-store");
    write(
        &dir,
        "working",
        Some("editing"),
        5,
        json!({"done": 1, "total": 2}),
    );

    assert!(!update(&dir, "working", json!({"done": 1, "total": 2}), 6));
    assert_eq!(stored(&dir)["ts"], 5);
    assert_eq!(stored(&dir)["progress_ts"], 6);
}

#[test]
fn write_progress_writes_nothing_when_there_is_nothing_to_change() {
    let dir = TempDir::new("summary-store");
    assert!(!update(&dir, "working", json!({"done": 1, "total": 2}), 1));
    assert_eq!(read_summary(dir.str(), PANE), None);

    write(&dir, "working", None, 1, Value::Null);
    assert!(!update(&dir, "working", json!({"done": 1, "total": 2}), 2));

    write(&dir, "blocked", Some("needs approval"), 3, Value::Null);
    assert!(!update(&dir, "working", json!({"done": 1, "total": 2}), 4));
    assert_eq!(stored(&dir)["progress"], Value::Null);

    write(&dir, "working", Some("editing"), 5, Value::Null);
    assert!(!update(&dir, "working", Value::Null, 6));
    assert!(jsx::get(&stored(&dir), "progress_ts").is_none());
}

/// A gemini Agent (no plan reader) keeps only the model's phase: refreshing
/// it with no steps must not make an old phase look current.
#[test]
fn a_phase_only_progress_keeps_its_progress_ts_when_no_steps_are_involved() {
    let dir = TempDir::new("summary-store");
    write(
        &dir,
        "working",
        Some("editing"),
        10,
        json!({"phase": "implementing"}),
    );

    assert!(!update(&dir, "working", json!({}), 500));
    assert_eq!(stored(&dir)["progress_ts"], 10);

    // Steps appearing or going are news: the stamp moves.
    assert!(update(&dir, "working", json!({"done": 1, "total": 3}), 600));
    assert_eq!(stored(&dir)["progress_ts"], 600);
    assert!(update(&dir, "working", json!({}), 700));
    assert_eq!(stored(&dir)["progress"], json!({"phase": "implementing"}));
    assert_eq!(stored(&dir)["progress_ts"], 700);
}

#[test]
fn clear_progress_drops_the_progress_and_keeps_the_record() {
    let dir = TempDir::new("summary-store");
    write(
        &dir,
        "working",
        Some("verifying"),
        7,
        json!({"done": 2, "total": 4, "phase": "verifying"}),
    );

    assert!(clear_progress(dir.str(), PANE).unwrap());
    assert_eq!(
        stored(&dir),
        json!({"v": 1, "pane": PANE, "status": "working", "summary": "verifying", "ts": 7, "hash": "h", "progress": null})
    );
    assert!(!clear_progress(dir.str(), PANE).unwrap());
    assert!(!clear_progress(dir.str(), "w1:missing").unwrap());

    // The next turn's phase starts afresh instead of keeping "verifying".
    write(
        &dir,
        "working",
        Some("reading"),
        8,
        json!({"phase": "exploring"}),
    );
    assert_eq!(progress_of(&dir), json!({"phase": "exploring"}));
}

// MARK: - Node interop (no JS test: the parity cases cover Node-written files)

#[test]
fn a_file_node_wrote_reads_and_a_rewrite_keeps_its_bytes() {
    let dir = TempDir::new("summary-store");
    fs::create_dir(dir.join("summaries")).unwrap();
    let node_line = "{\"v\":1,\"pane\":\"w1:p1\",\"status\":\"working\",\"summary\":\"Adding backoff\",\"ts\":1760000000000,\"hash\":\"ab12\",\"progress\":{\"done\":3,\"total\":7,\"phase\":\"verifying\"},\"progress_ts\":1760000000000}\n";
    fs::write(path_of(&dir, PANE), node_line).unwrap();

    assert_eq!(stored(&dir)["progress"]["done"], 3);
    // Same progress at the same time: nothing to rewrite.
    assert!(!update(
        &dir,
        "working",
        json!({"done": 3, "total": 7}),
        1760000000000
    ));
    assert_eq!(raw_of(&dir, PANE), node_line);
    // A clear and a write give Node's bytes for the same record.
    let progress = json!({"done": 3, "total": 7, "phase": "verifying"});
    assert!(
        write_summary(
            dir.str(),
            &SummaryWrite {
                pane_id: PANE,
                status: "working",
                summary: Some("Adding backoff"),
                ts: 1760000000000,
                hash: Some("ab12"),
                progress: &progress,
            },
        )
        .unwrap()
    );
    assert_eq!(raw_of(&dir, PANE), node_line);
}
