//! The plan-step tick's own `{pane_id: {done, total}}` map
//! (`activity/plan-steps.json` in the plugin state dir;
//! docs/agents/live-activity-contract.md, "Plan-step tick"; activity-plan-steps.js).
//!
//! The summary store only takes plan steps onto a Working record with
//! summary text, which the app's refresh writes. A turn that starts while the
//! app is closed has none, so the tick keeps the steps it read here and the
//! Live Activity uses them when no matching store record has an estimate. It
//! never writes summary-store records (tombstones included). Entries are
//! removed when the tick reads "no plan this turn", when the pane's turn ends
//! (an idle or done status event), and when the pane is gone.

use std::fs::{self, DirBuilder};
use std::io;
use std::path::{Path, PathBuf};

use serde_json::{Map, Value};

use crate::atomic::write_atomic;
use crate::js_compat::{cmp_utf16, read_json};
use crate::jsx;

pub const PLAN_STEPS_NAME: &str = "plan-steps.json";

fn activity_dir(state_dir: &Path) -> PathBuf {
    state_dir.join("activity")
}

fn plan_steps_path(state_dir: &Path) -> PathBuf {
    activity_dir(state_dir).join(PLAN_STEPS_NAME)
}

/// The stored map, empty when missing or unreadable. Entries are validated by
/// their consumer.
pub fn read_plan_steps(state_dir: &Path) -> Map<String, Value> {
    match read_json(&plan_steps_path(state_dir)) {
        Some(Value::Object(map)) => map,
        _ => Map::new(),
    }
}

/// Apply `mutate` (it edits the map in place) and write the result, panes in
/// ascending order, when it changed. Read, mutate and write are one step.
///
/// Returns whether the file changed.
pub fn update_plan_steps(
    state_dir: &Path,
    mutate: impl FnOnce(&mut Map<String, Value>),
) -> io::Result<bool> {
    let before = read_plan_steps(state_dir);
    let mut map = before.clone();
    mutate(&mut map);
    let mut entries: Vec<(String, Value)> = map.into_iter().collect();
    entries.sort_by(|(left, _), (right, _)| cmp_utf16(left, right));
    let sorted = Value::Object(entries.into_iter().collect());
    let text = jsx::stringify(&sorted);
    if text == jsx::stringify(&Value::Object(before)) {
        return Ok(false);
    }
    DirBuilder::new()
        .recursive(true)
        .create(activity_dir(state_dir))?;
    write_atomic(&plan_steps_path(state_dir), text.as_bytes(), 0o600)?;
    Ok(true)
}

/// Forget a pane's steps: its turn ended.
pub fn clear_plan_steps(state_dir: &Path, pane_id: &str) -> io::Result<bool> {
    update_plan_steps(state_dir, |map| {
        map.shift_remove(pane_id);
    })
}

/// Delete the whole map: summaries were switched off on this Host.
pub fn remove_plan_steps(state_dir: &Path) -> io::Result<()> {
    match fs::remove_file(plan_steps_path(state_dir)) {
        Err(error) if error.kind() != io::ErrorKind::NotFound => Err(error),
        _ => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    use crate::test_support::TempDir;

    fn write_map(dir: &Path, map: &Value) {
        fs::create_dir_all(dir.join("activity")).unwrap();
        fs::write(plan_steps_path(dir), serde_json::to_string(map).unwrap()).unwrap();
    }

    fn read_file(dir: &Path) -> Value {
        serde_json::from_str(&fs::read_to_string(plan_steps_path(dir)).unwrap()).unwrap()
    }

    fn set(map: &mut Map<String, Value>, pane: &str, done: u32, total: u32) {
        map.insert(pane.into(), json!({ "done": done, "total": total }));
    }

    // activity-hook / activity-tick: a missing or unreadable map reads as {}
    #[test]
    fn a_missing_or_unreadable_map_reads_empty() {
        let dir = TempDir::new("plan-steps");
        assert!(read_plan_steps(dir.path()).is_empty());
        fs::create_dir_all(dir.path().join("activity")).unwrap();
        for text in ["{not json", "[1]", "\"s\"", "null", ""] {
            fs::write(plan_steps_path(dir.path()), text).unwrap();
            assert!(read_plan_steps(dir.path()).is_empty(), "{text}");
        }
    }

    // activity-tick: the tick stores what it read, sorted by pane, and leaves the file alone when nothing changed
    #[test]
    fn update_writes_sorted_panes_and_skips_a_no_op() {
        let dir = TempDir::new("plan-steps");
        let changed = update_plan_steps(dir.path(), |map| {
            set(map, "w1:p2", 1, 3);
            set(map, "tmux:%1", 2, 4);
            set(map, "w1:p1", 3, 5);
        })
        .unwrap();
        assert!(changed);
        assert_eq!(
            fs::read_to_string(plan_steps_path(dir.path())).unwrap(),
            r#"{"tmux:%1":{"done":2,"total":4},"w1:p1":{"done":3,"total":5},"w1:p2":{"done":1,"total":3}}"#
        );
        assert!(!update_plan_steps(dir.path(), |map| set(map, "w1:p1", 3, 5)).unwrap());
        assert!(update_plan_steps(dir.path(), |map| set(map, "w1:p1", 4, 5)).unwrap());
        assert_eq!(
            read_file(dir.path())["w1:p1"],
            json!({ "done": 4, "total": 5 })
        );
    }

    // activity-hook: a status event that ends the turn clears only that pane's steps
    #[test]
    fn clear_forgets_one_pane() {
        let dir = TempDir::new("plan-steps");
        write_map(
            dir.path(),
            &json!({ "tmux:%7": { "done": 2, "total": 4 }, "w1:p1": { "done": 1, "total": 3 } }),
        );
        assert!(clear_plan_steps(dir.path(), "tmux:%7").unwrap());
        assert_eq!(
            read_file(dir.path()),
            json!({ "w1:p1": { "done": 1, "total": 3 } })
        );
        assert!(clear_plan_steps(dir.path(), "w1:p1").unwrap());
        assert_eq!(read_file(dir.path()), json!({}));
        assert!(!clear_plan_steps(dir.path(), "w1:p1").unwrap());
    }

    // activity-tick: an unsorted file is rewritten sorted even when the edit changes nothing else
    #[test]
    fn an_unsorted_file_is_rewritten_sorted() {
        let dir = TempDir::new("plan-steps");
        fs::create_dir_all(dir.path().join("activity")).unwrap();
        fs::write(
            plan_steps_path(dir.path()),
            r#"{"b":{"done":1,"total":2},"a":{"done":1,"total":2}}"#,
        )
        .unwrap();
        assert!(update_plan_steps(dir.path(), |_| {}).unwrap());
        assert_eq!(
            fs::read_to_string(plan_steps_path(dir.path())).unwrap(),
            r#"{"a":{"done":1,"total":2},"b":{"done":1,"total":2}}"#
        );
    }

    // activity-tick: summaries switched off removes the map
    #[test]
    fn remove_deletes_the_map_and_tolerates_a_missing_one() {
        let dir = TempDir::new("plan-steps");
        write_map(dir.path(), &json!({ "w1:p1": { "done": 1, "total": 3 } }));
        remove_plan_steps(dir.path()).unwrap();
        assert!(!plan_steps_path(dir.path()).exists());
        remove_plan_steps(dir.path()).unwrap();
    }

    #[test]
    fn panes_sort_by_utf16_unit_and_index_keys_go_first_as_in_js() {
        let dir = TempDir::new("plan-steps");
        update_plan_steps(dir.path(), |map| {
            set(map, "\u{FF5E}", 1, 2);
            set(map, "\u{1F600}", 1, 2);
            set(map, "10", 1, 2);
            set(map, "9", 1, 2);
        })
        .unwrap();
        let text = fs::read_to_string(plan_steps_path(dir.path())).unwrap();
        let keys: Vec<&str> = ["\"9\"", "\"10\"", "\"\u{1F600}\"", "\"\u{FF5E}\""].to_vec();
        let positions: Vec<usize> = keys.iter().map(|key| text.find(key).unwrap()).collect();
        assert!(positions.windows(2).all(|pair| pair[0] < pair[1]), "{text}");
    }
}
