//! Live Activity content-state builder (docs/agents/live-activity-contract.md;
//! activity-state.js).
//!
//! Pure: given an agent inventory in herdr's `agent list` shape and a host
//! label, produce the plaintext counts (full eligible set, plus the full idle
//! count) and the capped, sorted agents array that goes inside the encrypted
//! envelope. Idle agents are counted for display only: they never enter the
//! agents array and never make the activity eligible. An optional
//! `pinned_pane_ids` list (most-recently-pinned first) reorders eligible
//! agents; it never changes eligibility or counts. tmux Agents join the same
//! inventory through [`tmux_activity_inventory`], under their `tmux:` ids. An
//! Agent's progress joins its entry only while it is Working or Blocked
//! ([`progress_for_status`]).
//!
//! Agents, summary-store records and herdr's tab and pane entries are
//! `serde_json::Value`s, read as loosely as the JS reads them. The maps the
//! hook compares and stores between runs (`{pane: status}`, `{pane: progress}`)
//! are JSON objects too, in JS property order, so they serialize with
//! [`js_stringify`](crate::jsx::stringify) exactly as the JS wrote
//! them.

use std::borrow::Cow;
use std::collections::{HashMap, HashSet};
use std::io;
use std::sync::LazyLock;

use serde_json::{Map, Value, json};

use crate::activity_rows::{
    RowContext, RowLayout, render_activity_rows, rows_to_json, stripped_sidebar_title,
};
use crate::chat::shared::PlanSteps;
use crate::core::{CoreListing, CoreTerminal};
use crate::display_text::{for_display, for_display_str, optional_text};
use crate::js_compat::{cmp_utf16, js_get_opt, js_object, js_strict_eq, non_null};
use crate::jsx;
use crate::summary::store::normalize_progress;

/// The statuses (lower case) that make an Agent part of a Live Activity.
pub const ELIGIBLE_STATUSES: [&str; 3] = ["working", "blocked", "done"];
const AGENT_CAP: usize = 5;
const TMUX_PREFIX: &str = "tmux:";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Status {
    Blocked,
    Done,
    Working,
    Idle,
    Other,
}

impl Status {
    /// The status as `agent_status.toLowerCase()` would name it.
    fn parse(text: &str) -> Self {
        let lowered = if text.is_ascii() {
            Cow::Borrowed(text)
        } else {
            Cow::Owned(text.to_lowercase())
        };
        [
            ("working", Self::Working),
            ("blocked", Self::Blocked),
            ("done", Self::Done),
            ("idle", Self::Idle),
        ]
        .into_iter()
        .find(|(name, _)| lowered.eq_ignore_ascii_case(name))
        .map_or(Self::Other, |(_, status)| status)
    }

    fn is_eligible(self) -> bool {
        matches!(self, Self::Blocked | Self::Done | Self::Working)
    }

    fn has_progress(self) -> bool {
        matches!(self, Self::Blocked | Self::Working)
    }

    fn rank(self) -> u8 {
        match self {
            Self::Blocked => 0,
            Self::Done => 1,
            _ => 2,
        }
    }

    fn name(self) -> &'static str {
        match self {
            Self::Blocked => "blocked",
            Self::Done => "done",
            Self::Working => "working",
            Self::Idle => "idle",
            Self::Other => "",
        }
    }
}

/// Whether a status (in any case) is one of [`ELIGIBLE_STATUSES`].
pub fn is_eligible_status(status: &str) -> bool {
    Status::parse(status).is_eligible()
}

struct Parsed<'a> {
    agent: &'a Value,
    pane: &'a str,
    status: Status,
}

/// An entry with a pane id; its status is whatever it says (or `Other`).
fn parse_status(agent: &Value) -> Option<Parsed<'_>> {
    let pane = agent.get("pane_id").and_then(Value::as_str).unwrap_or("");
    if pane.is_empty() {
        return None;
    }
    let status = agent
        .get("agent_status")
        .and_then(Value::as_str)
        .map_or(Status::Other, Status::parse);
    Some(Parsed {
        agent,
        pane,
        status,
    })
}

fn parse_eligible(agent: &Value) -> Option<Parsed<'_>> {
    parse_status(agent).filter(|parsed| parsed.status.is_eligible())
}

/// The Host's name as `os.hostname()` reports it.
pub fn os_hostname() -> io::Result<String> {
    let mut buffer = [0u8; 256];
    // SAFETY: gethostname writes at most `buffer.len()` bytes into `buffer`.
    let status = unsafe { libc::gethostname(buffer.as_mut_ptr().cast(), buffer.len()) };
    if status != 0 {
        return Err(io::Error::last_os_error());
    }
    let end = buffer
        .iter()
        .position(|byte| *byte == 0)
        .unwrap_or(buffer.len());
    Ok(String::from_utf8_lossy(&buffer[..end]).into_owned())
}

/// Short hostname: the first DNS label of `hostname`, trimmed to the display
/// limit.
pub fn short_host_name(hostname: &str) -> String {
    let label = hostname.split('.').next().unwrap_or("");
    for_display_str(label).map_or_else(String::new, Cow::into_owned)
}

/// Number of idle agents in the full inventory. Displayed as a chip only.
pub fn idle_count(agents: &[Value]) -> u32 {
    let idle = agents
        .iter()
        .filter_map(parse_status)
        .filter(|parsed| parsed.status == Status::Idle)
        .count();
    idle as u32
}

/// `{pane_id: status}` over the full eligible inventory (uncapped), statuses
/// lower-cased; a repeated pane keeps its first place and its last status.
pub fn eligible_status_map(agents: &[Value]) -> Map<String, Value> {
    js_object(
        agents
            .iter()
            .filter_map(parse_eligible)
            .map(|parsed| (parsed.pane.to_string(), Value::from(parsed.status.name()))),
    )
}

/// The Host's attention count: agents Blocked or Done in a herdr `agent list`
/// inventory, its share of the app's Attention Badge. `agent list` reports
/// Agents only, so plain shell panes never count.
pub fn attention_count(agents: &[Value]) -> u32 {
    let count = agents
        .iter()
        .filter_map(parse_eligible)
        .filter(|parsed| matches!(parsed.status, Status::Blocked | Status::Done))
        .count();
    count as u32
}

/// `Object.keys(value)` with `value[key]`, for whatever the previous run's
/// file held: an object's properties, an array's elements, a string's
/// characters (which are never a status).
fn own_entries(value: Option<&Value>) -> Vec<(Cow<'_, str>, Option<&Value>)> {
    match value {
        Some(Value::Object(map)) => jsx::ordered_entries(map)
            .into_iter()
            .map(|(key, item)| (Cow::Borrowed(key.as_str()), Some(item)))
            .collect(),
        Some(Value::Array(items)) => items
            .iter()
            .enumerate()
            .map(|(index, item)| (Cow::Owned(index.to_string()), Some(item)))
            .collect(),
        Some(Value::String(text)) => (0..text.encode_utf16().count())
            .map(|index| (Cow::Owned(index.to_string()), None))
            .collect(),
        _ => Vec::new(),
    }
}

/// Whether two `{pane: status}` maps hold the same entries. `right` is what
/// the previous run stored (`None` when it stored nothing).
pub fn same_status_map(left: &Map<String, Value>, right: Option<&Value>) -> bool {
    let mut a: Vec<(&str, Option<&Value>)> = left
        .iter()
        .map(|(key, value)| (key.as_str(), Some(value)))
        .collect();
    let right = own_entries(right);
    let mut b: Vec<(&str, Option<&Value>)> = right
        .iter()
        .map(|(key, value)| (key.as_ref(), *value))
        .collect();
    a.sort_by(|(x, _), (y, _)| cmp_utf16(x, y));
    b.sort_by(|(x, _), (y, _)| cmp_utf16(x, y));
    a.len() == b.len()
        && a.iter()
            .zip(&b)
            .all(|((ka, va), (kb, vb))| ka == kb && js_strict_eq(*va, *vb))
}

/// Priority 10 only when some pane is blocked now and was not blocked in the
/// previous map. An absent previous map counts as empty.
pub fn has_newly_blocked(current: &Map<String, Value>, previous: Option<&Value>) -> bool {
    current.iter().any(|(pane, status)| {
        status.as_str() == Some("blocked")
            && js_get_opt(previous, pane).and_then(Value::as_str) != Some("blocked")
    })
}

/// An Agent's progress as the Live Activity carries it: plan steps done
/// and/or the model's coarse phase, each already validated by the summary
/// store's `normalize_progress`.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Progress {
    pub steps: Option<PlanSteps>,
    pub phase: Option<String>,
}

impl Progress {
    /// The progress a store `normalize_progress` result holds, which has at
    /// least one valid part.
    fn from_normalized(normalized: &Map<String, Value>) -> Self {
        let count = |key: &str| normalized.get(key).and_then(Value::as_f64);
        Self {
            steps: count("done")
                .zip(count("total"))
                .map(|(done, total)| PlanSteps {
                    done: done as u32,
                    total: total as u32,
                }),
            phase: normalized
                .get("phase")
                .and_then(Value::as_str)
                .map(str::to_owned),
        }
    }

    /// As the Live Activity wire carries it: `done`, `phase`, `total`. An
    /// empty progress is `{}`.
    pub fn wire_json(&self) -> Value {
        let mut object = Map::new();
        if let Some(steps) = self.steps {
            object.insert("done".into(), steps.done.into());
        }
        if let Some(phase) = &self.phase {
            object.insert("phase".into(), phase.as_str().into());
        }
        if let Some(steps) = self.steps {
            object.insert("total".into(), steps.total.into());
        }
        Value::Object(object)
    }
}

/// `normalizeProgress(value)` as a [`Progress`].
fn stored_progress(value: &Value) -> Option<Progress> {
    normalize_progress(value).map(|normalized| Progress::from_normalized(&normalized))
}

/// The progress a Working or Blocked Agent shows; `None` for every other
/// status or when no estimate applies. In order:
///
/// * the summary-store record's progress when the record (with text, not a
///   tombstone) was written in the Agent's current status;
/// * for a Blocked Agent, a stored record still Working: the notify hook's
///   Blocked record lands seconds after the status event, and the bar is the
///   frozen last estimate either way;
/// * the plan-step tick's own steps for the pane (`plan_steps`), which cover a
///   turn that started while no summary refresh ran (the app closed). They
///   carry steps only: when `plan_steps` names a phase but no valid steps the
///   result is an empty progress (`{}` on the wire), as in JS.
///
/// `status` is lower case. The result serializes with [`Progress::wire_json`].
pub fn progress_for_status(
    record: Option<&Value>,
    status: &str,
    plan_steps: Option<&Value>,
) -> Option<Progress> {
    if status != "working" && status != "blocked" {
        return None;
    }
    let usable = js_get_opt(record, "v")
        .and_then(Value::as_f64)
        .is_some_and(|v| v == 1.0)
        && js_get_opt(record, "summary").is_some_and(Value::is_string);
    let stored_status = js_get_opt(record, "status").and_then(Value::as_str);
    let stored = || js_get_opt(record, "progress").and_then(stored_progress);
    if usable
        && stored_status == Some(status)
        && let Some(progress) = stored()
    {
        return Some(progress);
    }
    if usable
        && status == "blocked"
        && stored_status == Some("working")
        && let Some(progress) = stored()
    {
        return Some(progress);
    }
    plan_steps.and_then(stored_progress).map(|steps| Progress {
        steps: steps.steps,
        phase: None,
    })
}

/// `{pane_id: progress}` over the full eligible inventory (uncapped), panes in
/// ascending order so equal maps serialize equally. `read_record(pane)` returns
/// the pane's summary-store entry; `plan_steps` is the tick's
/// `{pane_id: {done, total}}` map. Entries are wire progress objects.
pub fn eligible_progress_map(
    agents: &[Value],
    mut read_record: impl FnMut(&str) -> Option<Value>,
    plan_steps: &Map<String, Value>,
) -> Map<String, Value> {
    let mut entries: Vec<(String, Value)> = Vec::new();
    for parsed in agents.iter().filter_map(parse_eligible) {
        if !parsed.status.has_progress() {
            continue;
        }
        let record = read_record(parsed.pane);
        let progress = progress_for_status(
            record.as_ref(),
            parsed.status.name(),
            plan_steps.get(parsed.pane),
        );
        if let Some(progress) = progress {
            entries.push((parsed.pane.to_string(), progress.wire_json()));
        }
    }
    entries.sort_by(|(left, _), (right, _)| cmp_utf16(left, right));
    js_object(entries)
}

/// The entries of a progress map whose pane is in `panes`, order kept.
pub fn progress_for_panes(
    progress: &Map<String, Value>,
    panes: &HashSet<String>,
) -> Map<String, Value> {
    js_object(
        jsx::ordered_entries(progress)
            .into_iter()
            .filter(|(pane, _)| panes.contains(pane.as_str()))
            .map(|(pane, value)| (pane.clone(), value.clone())),
    )
}

/// Whether two `eligible_progress_map` results hold the same estimates;
/// `right` is what the previous run stored (`None` for nothing). Equal as
/// `JSON.stringify` writes them.
pub fn same_progress_map(left: &Map<String, Value>, right: Option<&Value>) -> bool {
    match non_null(right) {
        None => jsx::stringify_object(left) == "{}",
        Some(right) => jsx::stringify_object(left) == jsx::stringify(right),
    }
}

/// The pane ids of the Agents an envelope lists for this pin order: the
/// same sort and cap as [`build_activity_state`].
pub fn visible_pane_ids(agents: &[Value], pinned_pane_ids: Option<&Value>) -> Vec<String> {
    sorted_eligible(agents, pinned_pane_ids)
        .into_iter()
        .take(AGENT_CAP)
        .map(|parsed| parsed.pane.to_string())
        .collect()
}

/// Lenient reader for `live_activity.pinned_pane_ids`. Missing, null, a
/// non-array, or any non-string entry becomes an empty list.
pub fn parse_pinned_pane_ids(value: Option<&Value>) -> Vec<String> {
    let Some(items) = value.and_then(Value::as_array) else {
        return Vec::new();
    };
    items
        .iter()
        .map(|item| item.as_str().map(str::to_string))
        .collect::<Option<Vec<_>>>()
        .unwrap_or_default()
}

fn tmux_id(value: Option<&Value>) -> Option<String> {
    let id = optional_text(value)?;
    Some(if id.starts_with(TMUX_PREFIX) {
        id.to_string()
    } else {
        format!("{TMUX_PREFIX}{id}")
    })
}

/// A tmux Agent inventory in herdr's shapes.
pub struct TmuxInventory {
    pub agents: Vec<Value>,
    pub workspace_labels: Map<String, Value>,
    pub tabs: Map<String, Value>,
}

/// Map tmux Agents (`listTmuxAgents`: `paneId`, `sessionId`, `sessionName`,
/// `windowId`, `windowName`, `agent`, `status`, `title`, `cwd`) into herdr's
/// `agent list` shape, so they count, sort, pin, and render exactly like
/// herdr's: a tmux session stands in for a Workspace (its name is the label)
/// and a window for a tab. Ids keep the `tmux:` prefix, so they never collide
/// with herdr's and match the app's pins. A pane title equal to the hostname
/// is tmux's default, not something the agent set (T11), and is dropped.
/// `hostname` is the Host's full hostname.
pub fn tmux_activity_inventory(tmux_agents: &[Value], hostname: &str) -> TmuxInventory {
    let mut inventory = TmuxInventory {
        agents: Vec::new(),
        workspace_labels: Map::new(),
        tabs: Map::new(),
    };
    for entry in tmux_agents {
        let Some(pane_id) = tmux_id(entry.get("paneId")) else {
            continue;
        };
        let workspace_id = tmux_id(entry.get("sessionId"));
        let tab_id = tmux_id(entry.get("windowId"));
        let mut agent = Map::new();
        agent.insert("pane_id".into(), pane_id.into());
        if let Some(kind) = optional_text(entry.get("agent")) {
            agent.insert("agent".into(), kind.into());
        }
        if let Some(status) = entry.get("status").and_then(Value::as_str) {
            agent.insert("agent_status".into(), status.into());
        }
        if let Some(workspace_id) = &workspace_id {
            agent.insert("workspace_id".into(), workspace_id.clone().into());
        }
        if let Some(tab_id) = &tab_id {
            agent.insert("tab_id".into(), tab_id.clone().into());
        }
        if let Some(title) = optional_text(entry.get("title")).filter(|title| *title != hostname) {
            agent.insert("terminal_title".into(), title.into());
            agent.insert(
                "terminal_title_stripped".into(),
                stripped_sidebar_title(title).into(),
            );
        }
        if let Some(cwd) = entry.get("cwd").and_then(Value::as_str) {
            agent.insert("cwd".into(), cwd.into());
        }
        inventory.agents.push(Value::Object(agent));
        let session_name = optional_text(entry.get("sessionName"));
        if let (Some(workspace_id), Some(name)) = (&workspace_id, session_name) {
            inventory
                .workspace_labels
                .insert(workspace_id.clone(), name.into());
        }
        let window_name = optional_text(entry.get("windowName"));
        if let (Some(workspace_id), Some(tab_id), Some(name)) =
            (&workspace_id, &tab_id, window_name)
        {
            // Window names are commands or user labels, never herdr's
            // positional defaults, so the row always shows them.
            inventory.tabs.insert(
                tab_id.clone(),
                json!({
                    "tab_id": tab_id,
                    "workspace_id": workspace_id,
                    "label": name,
                    "position": null,
                    "count": 1,
                }),
            );
        }
    }
    inventory
}

/// A live core terminal as the Live Activity sees it: its line of `ls --json`,
/// and its full record (`get --json`) when one was asked for.
pub struct CoreRow<'a> {
    pub listing: &'a CoreListing,
    pub record: Option<&'a CoreTerminal>,
}

/// Map core terminals that reported a status into herdr's `agent list` shape,
/// so they count, sort, pin and render like herdr's and tmux's. Ids are the
/// app's `hc:<address>`, which never collide with the other two. Core has no
/// workspace or tab, so a row has neither. A terminal that has not reported,
/// or reports a word Waycar does not know, is no Agent here; `error` counts as
/// Blocked ([`crate::core::map_status`]). The kind is the hook's own label,
/// else the program's own report (the full record, when there is one).
pub fn core_activity_inventory(rows: &[CoreRow<'_>]) -> Vec<Value> {
    let mut agents = Vec::new();
    for row in rows {
        let status = match row.record {
            Some(record) => record.waycar_status(),
            None => row.listing.waycar_status(),
        };
        let Some(status) = status else { continue };
        let mut agent = Map::new();
        agent.insert("pane_id".into(), row.listing.pane_id().into());
        let kind = row
            .record
            .and_then(CoreTerminal::kind)
            .or(row.listing.agent.as_deref());
        if let Some(kind) = kind {
            agent.insert("agent".into(), kind.into());
        }
        agent.insert("agent_status".into(), status.into());
        let name = row
            .record
            .and_then(|record| record.name.as_deref())
            .or(row.listing.name.as_deref());
        if let Some(name) = name {
            agent.insert("name".into(), name.into());
        }
        let title = row
            .record
            .and_then(|record| {
                record
                    .status
                    .as_ref()
                    .and_then(|status| status.title.as_deref())
                    .filter(|title| !title.is_empty())
                    .or(record.title.as_deref())
            })
            .filter(|title| !title.is_empty());
        if let Some(title) = title {
            agent.insert("terminal_title".into(), title.into());
            agent.insert(
                "terminal_title_stripped".into(),
                stripped_sidebar_title(title).into(),
            );
        }
        let cwd = row
            .record
            .and_then(CoreTerminal::folder)
            .or(row.listing.cwd.as_deref());
        if let Some(cwd) = cwd {
            agent.insert("cwd".into(), cwd.into());
        }
        agents.push(Value::Object(agent));
    }
    agents
}

static EMPTY_MAP: LazyLock<Map<String, Value>> = LazyLock::new(Map::new);

/// What [`build_activity_state`] builds from. `progress` is an
/// [`eligible_progress_map`] result: an entry joins its Agent's wire object
/// after `pane`, in the canonical key order. `row_host_name` is the name the
/// `host` row field shows (default: the display host name).
pub struct BuildInput<'a> {
    pub agents: &'a [Value],
    pub host_name: &'a str,
    pub pinned_pane_ids: Option<&'a Value>,
    pub workspace_labels: &'a Map<String, Value>,
    pub row_layout: Option<&'a RowLayout>,
    pub row_host_name: Option<&'a str>,
    pub tabs: &'a Map<String, Value>,
    pub panes: &'a Map<String, Value>,
    pub progress: &'a Map<String, Value>,
}

impl<'a> BuildInput<'a> {
    /// An inventory and host name with every option at its default.
    pub fn new(agents: &'a [Value], host_name: &'a str) -> Self {
        Self {
            agents,
            host_name,
            pinned_pane_ids: None,
            workspace_labels: &EMPTY_MAP,
            row_layout: None,
            row_host_name: None,
            tabs: &EMPTY_MAP,
            panes: &EMPTY_MAP,
            progress: &EMPTY_MAP,
        }
    }
}

/// The plaintext counts of the full inventory.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Counts {
    pub working: u32,
    pub blocked: u32,
    pub done: u32,
    pub idle: u32,
}

impl Counts {
    /// `{working, blocked, done, idle}` in that key order.
    pub fn to_json(self) -> Value {
        json!({
            "working": self.working,
            "blocked": self.blocked,
            "done": self.done,
            "idle": self.idle,
        })
    }
}

pub struct ActivityState {
    pub counts: Counts,
    /// `{agents, host, v}`: what goes inside the encrypted envelope.
    pub plaintext_object: Value,
}

/// Counts over the full inventory and the capped, sorted agents array.
pub fn build_activity_state(input: &BuildInput<'_>) -> ActivityState {
    let mut counts = Counts {
        idle: idle_count(input.agents),
        ..Counts::default()
    };
    let eligible = sorted_eligible(input.agents, input.pinned_pane_ids);
    for entry in &eligible {
        match entry.status {
            Status::Working => counts.working += 1,
            Status::Blocked => counts.blocked += 1,
            _ => counts.done += 1,
        }
    }
    let host = for_display_str(input.host_name).map_or_else(String::new, Cow::into_owned);
    let context = RowContext {
        host_name: input.row_host_name.unwrap_or(&host),
        workspace_labels: input.workspace_labels,
        tabs: input.tabs,
        panes: input.panes,
    };
    let selected: Vec<Value> = eligible
        .iter()
        .take(AGENT_CAP)
        .map(|entry| {
            let agent = entry.agent;
            let title = optional_text(agent.get("terminal_title_stripped"))
                .or_else(|| optional_text(agent.get("terminal_title")))
                .and_then(for_display_str);
            let name = optional_text(agent.get("display_agent"))
                .or_else(|| optional_text(agent.get("name")))
                .and_then(for_display_str);
            let mut wire = Map::new();
            wire.insert(
                "kind".into(),
                optional_text(agent.get("agent"))
                    .unwrap_or("unknown")
                    .into(),
            );
            if let Some(name) = name {
                wire.insert("name".into(), name.into_owned().into());
            }
            wire.insert("pane".into(), entry.pane.into());
            if let Some(progress) = input.progress.get(entry.pane) {
                wire.insert("progress".into(), progress.clone());
            }
            if let Some(rows) = render_activity_rows(input.row_layout, agent, &context) {
                wire.insert("rows".into(), rows_to_json(&rows));
            }
            wire.insert("status".into(), entry.status.name().into());
            if let Some(title) = title {
                wire.insert("title".into(), title.into_owned().into());
            }
            let workspace = optional_text(agent.get("workspace_id"))
                .and_then(|id| input.workspace_labels.get(id))
                .and_then(|label| for_display(Some(label)));
            if let Some(workspace) = workspace {
                wire.insert("workspace".into(), workspace.into_owned().into());
            }
            Value::Object(wire)
        })
        .collect();
    ActivityState {
        counts,
        plaintext_object: json!({ "agents": selected, "host": host, "v": 1 }),
    }
}

/// Eligible Agents in envelope order: pinned first by pin recency, then
/// status rank, then pane.
fn sorted_eligible<'a>(agents: &'a [Value], pinned_pane_ids: Option<&Value>) -> Vec<Parsed<'a>> {
    let mut eligible: Vec<Parsed<'a>> = agents.iter().filter_map(parse_eligible).collect();
    let pins = parse_pinned_pane_ids(pinned_pane_ids);
    let mut pin_index: HashMap<&str, usize> = HashMap::new();
    for (index, pane) in pins.iter().enumerate() {
        pin_index.entry(pane.as_str()).or_insert(index);
    }
    eligible.sort_by(
        |left, right| match (pin_index.get(left.pane), pin_index.get(right.pane)) {
            (Some(a), Some(b)) => a.cmp(b),
            (Some(_), None) => std::cmp::Ordering::Less,
            (None, Some(_)) => std::cmp::Ordering::Greater,
            (None, None) => left
                .status
                .rank()
                .cmp(&right.status.rank())
                .then_with(|| cmp_utf16(left.pane, right.pane)),
        },
    );
    eligible
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::Path;

    use super::*;
    use crate::activity_rows::parse_activity_row_layout;
    use crate::display_text::DISPLAY_LIMIT;

    fn vectors() -> Value {
        let path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("test-vectors/live-activity-content-v1.json");
        serde_json::from_slice(&fs::read(path).unwrap()).unwrap()
    }

    fn agent(pane: &str, status: &str, extra: Value) -> Value {
        let mut entry = json!({ "pane_id": pane, "agent_status": status });
        if let (Some(entry), Some(extra)) = (entry.as_object_mut(), extra.as_object()) {
            for (key, value) in extra {
                entry.insert(key.clone(), value.clone());
            }
        }
        entry
    }

    fn plain(pane: &str, status: &str) -> Value {
        agent(pane, status, json!({}))
    }

    fn build(agents: &[Value], host: &str) -> ActivityState {
        build_activity_state(&BuildInput::new(agents, host))
    }

    fn pinned(agents: &[Value], pins: &Value) -> ActivityState {
        build_activity_state(&BuildInput {
            pinned_pane_ids: Some(pins),
            ..BuildInput::new(agents, "studio")
        })
    }

    fn entries(state: &ActivityState) -> &Vec<Value> {
        state.plaintext_object["agents"].as_array().unwrap()
    }

    fn ranked(state: &ActivityState) -> Vec<String> {
        entries(state)
            .iter()
            .map(|entry| {
                format!(
                    "{}:{}",
                    entry["status"].as_str().unwrap(),
                    entry["pane"].as_str().unwrap()
                )
            })
            .collect()
    }

    fn panes(state: &ActivityState) -> Vec<&str> {
        entries(state)
            .iter()
            .map(|entry| entry["pane"].as_str().unwrap())
            .collect()
    }

    fn keys(value: &Value) -> Vec<&str> {
        value
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect()
    }

    fn by_pane<'a>(state: &'a ActivityState, pane: &str) -> &'a Value {
        entries(state)
            .iter()
            .find(|entry| entry["pane"] == pane)
            .unwrap()
    }

    fn map_of(value: Value) -> Map<String, Value> {
        value.as_object().unwrap().clone()
    }

    fn record(status: &str, progress: Value, extra: Value) -> Value {
        let mut record = json!({ "v": 1, "pane": "w1:p1", "status": status, "summary": "Refactoring", "ts": 1, "hash": null, "progress": progress });
        for (key, value) in extra.as_object().unwrap() {
            record[key] = value.clone();
        }
        record
    }

    fn wire(progress: Option<Progress>) -> Option<Value> {
        progress.as_ref().map(Progress::wire_json)
    }

    // shared inventory vectors: builds counts and payload for: <name>
    #[test]
    fn shared_inventory_vectors_build_counts_and_payload() {
        let vectors = vectors();
        let cases: Vec<&Value> = vectors["valid"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|entry| entry["inventory"].is_array())
            .collect();
        assert_eq!(cases.len(), 5);
        for vector in cases {
            let inventory = vector["inventory"].as_array().unwrap();
            let labels = map_of(vector.get("workspace_labels").cloned().unwrap_or(json!({})));
            let tabs: Map<String, Value> = vector
                .get("tabs")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .map(|tab| (tab["tab_id"].as_str().unwrap().to_string(), tab.clone()))
                .collect();
            let summaries = vector.get("summaries");
            let progress = eligible_progress_map(
                inventory,
                |pane| summaries.and_then(|s| s.get(pane)).cloned(),
                &Map::new(),
            );
            let layout = parse_activity_row_layout(vector.get("row_layout"));
            let state = build_activity_state(&BuildInput {
                pinned_pane_ids: vector.get("pinned_pane_ids"),
                workspace_labels: &labels,
                row_layout: layout.as_ref(),
                tabs: &tabs,
                progress: &progress,
                ..BuildInput::new(inventory, vector["payload"]["host"].as_str().unwrap())
            });
            assert_eq!(
                state.counts.to_json(),
                vector["counts"],
                "{}",
                vector["name"]
            );
            assert_eq!(
                state.plaintext_object, vector["payload"],
                "{}",
                vector["name"]
            );
        }
    }

    // Agent progress: applies to Working and Blocked Agents whose record was written in that status
    #[test]
    fn progress_applies_to_working_and_blocked_agents_whose_record_was_written_in_that_status() {
        let steps = json!({ "done": 3, "total": 7 });
        let progress =
            |record: Option<&Value>, status: &str| wire(progress_for_status(record, status, None));
        assert_eq!(
            progress(
                Some(&record("working", steps.clone(), json!({}))),
                "working"
            ),
            Some(steps.clone())
        );
        assert_eq!(
            progress(
                Some(&record("blocked", steps.clone(), json!({}))),
                "blocked"
            ),
            Some(steps.clone())
        );
        assert_eq!(
            progress(
                Some(&record("blocked", steps.clone(), json!({}))),
                "working"
            ),
            None
        );
        assert_eq!(
            progress(Some(&record("done", steps.clone(), json!({}))), "working"),
            None
        );
        assert_eq!(
            progress(Some(&record("done", steps.clone(), json!({}))), "done"),
            None
        );
        assert_eq!(
            progress(Some(&record("idle", steps.clone(), json!({}))), "idle"),
            None
        );
        assert_eq!(
            progress(
                Some(&record(
                    "working",
                    steps.clone(),
                    json!({ "summary": null })
                )),
                "working"
            ),
            None
        );
        assert_eq!(
            progress(
                Some(&record("working", steps, json!({ "v": 2 }))),
                "working"
            ),
            None
        );
        assert_eq!(progress(None, "working"), None);
    }

    // Agent progress: a Blocked Agent whose record is still Working keeps that estimate (frozen)
    #[test]
    fn a_blocked_agent_whose_record_is_still_working_keeps_that_estimate() {
        let working = record(
            "working",
            json!({ "done": 2, "total": 5, "phase": "verifying" }),
            json!({}),
        );
        let frozen = wire(progress_for_status(Some(&working), "blocked", None)).unwrap();
        assert_eq!(
            frozen,
            json!({ "done": 2, "phase": "verifying", "total": 5 })
        );
        assert_eq!(keys(&frozen), ["done", "phase", "total"]);
        let idle = record("idle", json!({ "done": 2, "total": 5 }), json!({}));
        assert_eq!(
            wire(progress_for_status(Some(&idle), "blocked", None)),
            None
        );
    }

    // Agent progress: the tick's plan steps cover Agents without a usable matching record; a matching record wins
    #[test]
    fn the_ticks_plan_steps_cover_agents_without_a_usable_matching_record() {
        let tick = json!({ "done": 1, "total": 4 });
        let with_tick = |record: Option<&Value>, status: &str, steps: &Value| {
            wire(progress_for_status(record, status, Some(steps)))
        };
        assert_eq!(with_tick(None, "working", &tick), Some(tick.clone()));
        let done = record("done", json!({ "done": 9, "total": 9 }), json!({}));
        assert_eq!(with_tick(Some(&done), "working", &tick), Some(tick.clone()));
        let missing = {
            let mut missing = record("working", json!(null), json!({}));
            missing.as_object_mut().unwrap().remove("progress");
            missing
        };
        assert_eq!(
            with_tick(Some(&missing), "working", &tick),
            Some(tick.clone())
        );
        let matching = record("working", json!({ "done": 3, "total": 4 }), json!({}));
        assert_eq!(
            with_tick(Some(&matching), "working", &tick),
            Some(json!({ "done": 3, "total": 4 }))
        );
        assert_eq!(
            with_tick(None, "blocked", &tick),
            Some(tick.clone()),
            "frozen while Blocked"
        );
        assert_eq!(with_tick(None, "done", &tick), None);
        assert_eq!(
            with_tick(None, "working", &json!({ "done": 5, "total": 4 })),
            None
        );
        assert_eq!(
            with_tick(
                None,
                "working",
                &json!({ "done": 1, "total": 4, "phase": "verifying" })
            ),
            Some(tick.clone()),
            "steps only"
        );
        let agents = [plain("w1:p1", "working")];
        let plan = map_of(json!({ "w1:p1": tick, "w1:p9": tick }));
        let map = eligible_progress_map(&agents, |_| None, &plan);
        assert_eq!(Value::Object(map), json!({ "w1:p1": tick }));
    }

    // Agent progress: visible panes follow the envelope's pin order and cap
    #[test]
    fn visible_panes_follow_the_envelopes_pin_order_and_cap() {
        let agents: Vec<Value> = ["w1:p1", "w1:p2", "w1:p3", "w1:p4", "w1:p5", "w1:p6"]
            .iter()
            .map(|pane| plain(pane, "working"))
            .collect();
        assert_eq!(
            visible_pane_ids(&agents, Some(&json!([]))),
            ["w1:p1", "w1:p2", "w1:p3", "w1:p4", "w1:p5"]
        );
        assert_eq!(
            visible_pane_ids(&agents, Some(&json!(["w1:p6"]))),
            ["w1:p6", "w1:p1", "w1:p2", "w1:p3", "w1:p4"]
        );
        let visible: HashSet<String> = visible_pane_ids(&agents, Some(&json!([])))
            .into_iter()
            .collect();
        let progress = map_of(
            json!({ "w1:p1": { "done": 1, "total": 2 }, "w1:p6": { "done": 1, "total": 2 } }),
        );
        assert_eq!(
            Value::Object(progress_for_panes(&progress, &visible)),
            json!({ "w1:p1": { "done": 1, "total": 2 } })
        );
    }

    // Agent progress: keeps the valid half in canonical key order and drops nothing-valid progress
    #[test]
    fn keeps_the_valid_half_in_canonical_key_order_and_drops_nothing_valid_progress() {
        let for_working = |progress: Value| {
            wire(progress_for_status(
                Some(&record("working", progress, json!({}))),
                "working",
                None,
            ))
        };
        let mixed = for_working(json!({ "total": 4, "phase": "verifying", "done": 2 })).unwrap();
        assert_eq!(keys(&mixed), ["done", "phase", "total"]);
        assert_eq!(
            for_working(json!({ "done": 9, "total": 7, "phase": "verifying" })),
            Some(json!({ "phase": "verifying" }))
        );
        assert_eq!(for_working(json!({ "phase": "dreaming" })), None);
        assert_eq!(for_working(json!("3/7")), None);
        let missing = {
            let mut missing = record("working", json!(null), json!({}));
            missing.as_object_mut().unwrap().remove("progress");
            missing
        };
        assert_eq!(
            wire(progress_for_status(Some(&missing), "working", None)),
            None
        );
        // Addendum B: non-tombstone records may carry an explicit `progress: null`.
        let null = record("working", json!(null), json!({}));
        assert_eq!(
            wire(progress_for_status(Some(&null), "working", None)),
            None
        );
        assert_eq!(
            wire(progress_for_status(Some(&null), "blocked", None)),
            None
        );
        assert_eq!(
            wire(progress_for_status(
                Some(&null),
                "working",
                Some(&json!({ "done": 1, "total": 2 }))
            )),
            Some(json!({ "done": 1, "total": 2 }))
        );
        // Plan steps with a phase and no valid steps give `{}`, not null.
        assert_eq!(
            wire(progress_for_status(
                None,
                "working",
                Some(&json!({ "phase": "verifying" }))
            )),
            Some(json!({}))
        );
    }

    // Agent progress: the map covers the uncapped eligible inventory, sorted by pane, and compares by value
    #[test]
    fn the_map_covers_the_uncapped_eligible_inventory_sorted_by_pane_and_compares_by_value() {
        let mut agents: Vec<Value> = ["w1:p6", "w1:p5", "w1:p4", "w1:p3", "w1:p2", "w1:p1"]
            .iter()
            .map(|pane| plain(pane, "working"))
            .collect();
        agents.push(plain("w1:p7", "idle"));
        let mut records: HashMap<String, Value> = agents
            .iter()
            .map(|a| {
                (
                    a["pane_id"].as_str().unwrap().to_string(),
                    record("working", json!({ "done": 1, "total": 2 }), json!({})),
                )
            })
            .collect();
        records.insert(
            "w1:p7".into(),
            record("idle", json!({ "done": 1, "total": 2 }), json!({})),
        );
        let map = eligible_progress_map(&agents, |pane| records.get(pane).cloned(), &Map::new());
        assert_eq!(
            map.keys().collect::<Vec<_>>(),
            ["w1:p1", "w1:p2", "w1:p3", "w1:p4", "w1:p5", "w1:p6"]
        );
        let round_trip: Value =
            serde_json::from_str(&serde_json::to_string(&map).unwrap()).unwrap();
        assert!(same_progress_map(&map, Some(&round_trip)));
        assert!(same_progress_map(&Map::new(), None));
        records.insert(
            "w1:p6".into(),
            record("working", json!({ "done": 2, "total": 2 }), json!({})),
        );
        let other = eligible_progress_map(&agents, |pane| records.get(pane).cloned(), &Map::new());
        assert!(!same_progress_map(&map, Some(&Value::Object(other))));
    }

    // Agent progress: an entry carries its progress after pane; other entries carry none
    #[test]
    fn an_entry_carries_its_progress_after_pane_other_entries_carry_none() {
        let agents = [
            agent("w1:p1", "working", json!({ "agent": "omp" })),
            agent("w1:p2", "done", json!({ "agent": "omp" })),
        ];
        let progress = map_of(json!({ "w1:p1": { "done": 3, "total": 7 } }));
        let state = build_activity_state(&BuildInput {
            progress: &progress,
            ..BuildInput::new(&agents, "mbp")
        });
        // Sorted: done before working.
        assert_eq!(keys(&entries(&state)[0]), ["kind", "pane", "status"]);
        assert_eq!(
            keys(&entries(&state)[1]),
            ["kind", "pane", "progress", "status"]
        );
        assert_eq!(
            entries(&state)[1]["progress"],
            json!({ "done": 3, "total": 7 })
        );
    }

    // idleCount: counts idle panes case-insensitively and skips malformed entries
    #[test]
    fn idle_count_counts_idle_panes_case_insensitively_and_skips_malformed_entries() {
        let agents = [
            plain("w1:p1", "idle"),
            plain("w1:p2", "IDLE"),
            plain("w1:p3", "working"),
            plain("", "idle"),
            Value::Null,
            json!({ "agent_status": "idle" }),
        ];
        assert_eq!(idle_count(&agents), 2);
        assert_eq!(idle_count(&[]), 0);
    }

    // buildActivityState: sorts blocked > done > working and tie-breaks by pane ascending
    #[test]
    fn sorts_blocked_done_working_and_tie_breaks_by_pane_ascending() {
        let agents = [
            agent(
                "w1:p1",
                "working",
                json!({ "agent": "claude", "terminal_title_stripped": "refactor" }),
            ),
            agent("w1:p9", "blocked", json!({ "agent": "codex" })),
            agent(
                "w1:p2",
                "blocked",
                json!({ "agent": "claude", "terminal_title_stripped": "review" }),
            ),
            agent(
                "w2:p1",
                "done",
                json!({ "agent": "droid", "terminal_title_stripped": "copy" }),
            ),
            agent(
                "w3:p4",
                "working",
                json!({ "agent": "grok", "terminal_title_stripped": "research" }),
            ),
            agent("w9:p1", "idle", json!({ "agent": "claude" })),
            agent("w9:p2", "unknown", json!({ "agent": "claude" })),
        ];
        let state = build(&agents, "studio");
        assert_eq!(
            state.counts,
            Counts {
                working: 2,
                blocked: 2,
                done: 1,
                idle: 1
            }
        );
        assert_eq!(
            ranked(&state),
            [
                "blocked:w1:p2",
                "blocked:w1:p9",
                "done:w2:p1",
                "working:w1:p1",
                "working:w3:p4"
            ]
        );
        assert_eq!(state.plaintext_object["host"], "studio");
        assert_eq!(state.plaintext_object["v"], 1);
    }

    // buildActivityState: caps the agents array at 5 while counts cover the full inventory
    #[test]
    fn caps_the_agents_array_at_5_while_counts_cover_the_full_inventory() {
        let agents = [
            agent("w1:p1", "blocked", json!({ "agent": "a" })),
            agent("w1:p2", "blocked", json!({ "agent": "b" })),
            agent("w1:p3", "done", json!({ "agent": "c" })),
            agent("w1:p4", "done", json!({ "agent": "d" })),
            agent("w1:p5", "working", json!({ "agent": "e" })),
            agent("w1:p6", "working", json!({ "agent": "f" })),
        ];
        let state = build(&agents, "mbp");
        assert_eq!(
            state.counts,
            Counts {
                working: 2,
                blocked: 2,
                done: 2,
                idle: 0
            }
        );
        assert_eq!(entries(&state).len(), 5);
        assert_eq!(panes(&state), ["w1:p1", "w1:p2", "w1:p3", "w1:p4", "w1:p5"]);
    }

    // buildActivityState: trims titles at the 80-grapheme CJK boundary and omits empty titles
    #[test]
    fn trims_titles_at_the_80_grapheme_cjk_boundary_and_omits_empty_titles() {
        let eighty = "屏".repeat(DISPLAY_LIMIT);
        let over = "屏".repeat(DISPLAY_LIMIT + 1);
        let agents = [
            agent(
                "w1:p1",
                "working",
                json!({ "agent": "claude", "terminal_title": format!("⠂ {eighty}"), "terminal_title_stripped": eighty }),
            ),
            agent(
                "w1:p2",
                "done",
                json!({ "agent": "codex", "terminal_title": over, "terminal_title_stripped": over }),
            ),
            agent("w1:p3", "blocked", json!({ "agent": "grok" })),
        ];
        let state = build(&agents, "mbp");
        assert_eq!(by_pane(&state, "w1:p1")["title"], json!(eighty));
        assert_eq!(
            by_pane(&state, "w1:p1")["title"]
                .as_str()
                .unwrap()
                .chars()
                .count(),
            DISPLAY_LIMIT
        );
        let cut = by_pane(&state, "w1:p2")["title"].as_str().unwrap();
        assert_eq!(cut.chars().count(), DISPLAY_LIMIT);
        assert!(cut.ends_with('…'));
        assert!(by_pane(&state, "w1:p3").get("title").is_none());
    }

    // buildActivityState: carries the herdr agent name, preferring display_agent, omitting it when unnamed
    #[test]
    fn carries_the_herdr_agent_name_preferring_display_agent() {
        let agents = [
            agent(
                "w1:p1",
                "working",
                json!({ "agent": "grok", "name": "la-demo" }),
            ),
            agent(
                "w1:p2",
                "blocked",
                json!({ "agent": "codex", "name": "reviewer", "display_agent": "rev" }),
            ),
            agent("w1:p3", "done", json!({ "agent": "claude", "name": "" })),
        ];
        let state = build(&agents, "mbp");
        assert_eq!(by_pane(&state, "w1:p1")["name"], "la-demo");
        assert_eq!(by_pane(&state, "w1:p2")["name"], "rev");
        assert!(by_pane(&state, "w1:p3").get("name").is_none());
        assert_eq!(
            keys(by_pane(&state, "w1:p1")),
            ["kind", "name", "pane", "status"]
        );
    }

    // buildActivityState: carries the workspace label by workspace id and omits unavailable labels
    #[test]
    fn carries_the_workspace_label_by_workspace_id_and_omits_unavailable_labels() {
        let agents = [
            agent(
                "w1:p1",
                "working",
                json!({ "agent": "codex", "workspace_id": "w1" }),
            ),
            agent(
                "w2:p1",
                "blocked",
                json!({ "agent": "claude", "workspace_id": "missing" }),
            ),
        ];
        let labels = map_of(json!({ "w1": "Waycar" }));
        let state = build_activity_state(&BuildInput {
            workspace_labels: &labels,
            ..BuildInput::new(&agents, "mbp")
        });
        assert_eq!(by_pane(&state, "w1:p1")["workspace"], "Waycar");
        assert!(by_pane(&state, "w2:p1").get("workspace").is_none());
        assert_eq!(
            keys(by_pane(&state, "w1:p1")),
            ["kind", "pane", "status", "workspace"]
        );
    }

    // buildActivityState: prefers the stripped title, falls kind back to unknown, and trims host
    #[test]
    fn prefers_the_stripped_title_falls_kind_back_to_unknown_and_trims_host() {
        let long_host = "h".repeat(DISPLAY_LIMIT + 5);
        let agents = [agent(
            "wV:p1",
            "working",
            json!({ "terminal_title": "raw with glyphs", "terminal_title_stripped": "stripped title" }),
        )];
        let state = build(&agents, &long_host);
        assert_eq!(entries(&state)[0]["kind"], "unknown");
        assert_eq!(entries(&state)[0]["title"], "stripped title");
        let host = state.plaintext_object["host"].as_str().unwrap();
        assert_eq!(host.chars().count(), DISPLAY_LIMIT);
        assert!(host.ends_with('…'));
    }

    // buildActivityState: idle-only inventory counts idle but lists no agents
    #[test]
    fn idle_only_inventory_counts_idle_but_lists_no_agents() {
        let agents = [plain("w1:p1", "idle"), plain("w1:p2", "unknown")];
        let state = build(&agents, "mbp");
        assert_eq!(
            state.counts,
            Counts {
                working: 0,
                blocked: 0,
                done: 0,
                idle: 1
            }
        );
        assert_eq!(
            state.plaintext_object,
            json!({ "agents": [], "host": "mbp", "v": 1 })
        );
    }

    fn mixed_eligible() -> Vec<Value> {
        vec![
            agent("w1:p1", "working", json!({ "agent": "claude" })),
            agent("w1:p9", "blocked", json!({ "agent": "codex" })),
            agent("w1:p2", "blocked", json!({ "agent": "claude" })),
            agent("w2:p1", "done", json!({ "agent": "droid" })),
            agent("w3:p4", "working", json!({ "agent": "grok" })),
            agent("w9:p1", "idle", json!({ "agent": "claude" })),
            agent("w9:p2", "unknown", json!({ "agent": "claude" })),
        ]
    }

    const STATUS_THEN_PANE_ORDER: [&str; 5] = [
        "blocked:w1:p2",
        "blocked:w1:p9",
        "done:w2:p1",
        "working:w1:p1",
        "working:w3:p4",
    ];

    // buildActivityState pin ordering: pins float first in recency order, then the existing status rank
    #[test]
    fn pins_float_first_in_recency_order_then_the_existing_status_rank() {
        let state = pinned(&mixed_eligible(), &json!(["w3:p4", "w1:p2"]));
        assert_eq!(
            state.counts,
            Counts {
                working: 2,
                blocked: 2,
                done: 1,
                idle: 1
            }
        );
        assert_eq!(
            ranked(&state),
            [
                "working:w3:p4",
                "blocked:w1:p2",
                "blocked:w1:p9",
                "done:w2:p1",
                "working:w1:p1"
            ]
        );
    }

    // buildActivityState pin ordering: an ineligible pinned agent is ignored
    #[test]
    fn an_ineligible_pinned_agent_is_ignored() {
        let state = pinned(&mixed_eligible(), &json!(["w9:p1", "w3:p4"]));
        assert_eq!(
            state.counts,
            Counts {
                working: 2,
                blocked: 2,
                done: 1,
                idle: 1
            }
        );
        assert_eq!(
            ranked(&state),
            [
                "working:w3:p4",
                "blocked:w1:p2",
                "blocked:w1:p9",
                "done:w2:p1",
                "working:w1:p1"
            ]
        );
    }

    // buildActivityState pin ordering: unknown pane ids in the pin set are ignored
    #[test]
    fn unknown_pane_ids_in_the_pin_set_are_ignored() {
        let state = pinned(&mixed_eligible(), &json!(["nope", "w1:p1", "also-missing"]));
        assert_eq!(
            state.counts,
            Counts {
                working: 2,
                blocked: 2,
                done: 1,
                idle: 1
            }
        );
        assert_eq!(
            ranked(&state),
            [
                "working:w1:p1",
                "blocked:w1:p2",
                "blocked:w1:p9",
                "done:w2:p1",
                "working:w3:p4"
            ]
        );
    }

    // buildActivityState pin ordering: a missing or malformed pin set keeps today's ordering
    #[test]
    fn a_missing_or_malformed_pin_set_keeps_todays_ordering() {
        let agents = mixed_eligible();
        let expected = build(&agents, "studio");
        assert_eq!(ranked(&expected), STATUS_THEN_PANE_ORDER);
        let malformed = [
            json!(null),
            json!([]),
            json!("w1:p1"),
            json!(1),
            json!({ "0": "w3:p4" }),
            json!([1, "w3:p4"]),
            json!(["w3:p4", null]),
        ];
        for pins in malformed {
            let state = pinned(&agents, &pins);
            assert_eq!(state.counts, expected.counts, "{pins}");
            assert_eq!(ranked(&state), STATUS_THEN_PANE_ORDER, "{pins}");
        }
    }

    // buildActivityState pin ordering: the agent cap still applies when more than five agents are pinned
    #[test]
    fn the_agent_cap_still_applies_when_more_than_five_agents_are_pinned() {
        let agents = [
            agent("w1:p1", "blocked", json!({ "agent": "a" })),
            agent("w1:p2", "blocked", json!({ "agent": "b" })),
            agent("w1:p3", "done", json!({ "agent": "c" })),
            agent("w1:p4", "done", json!({ "agent": "d" })),
            agent("w1:p5", "working", json!({ "agent": "e" })),
            agent("w1:p6", "working", json!({ "agent": "f" })),
        ];
        let state = pinned(
            &agents,
            &json!(["w1:p6", "w1:p5", "w1:p4", "w1:p3", "w1:p2", "w1:p1"]),
        );
        assert_eq!(
            state.counts,
            Counts {
                working: 2,
                blocked: 2,
                done: 2,
                idle: 0
            }
        );
        assert_eq!(panes(&state), ["w1:p6", "w1:p5", "w1:p4", "w1:p3", "w1:p2"]);
    }

    // parsePinnedPaneIds: returns a string array as-is
    #[test]
    fn parse_pinned_pane_ids_returns_a_string_array_as_is() {
        assert_eq!(
            parse_pinned_pane_ids(Some(&json!(["w3:p4", "w1:p2"]))),
            ["w3:p4", "w1:p2"]
        );
        assert!(parse_pinned_pane_ids(Some(&json!([]))).is_empty());
    }

    // parsePinnedPaneIds: treats missing, null, non-array, or mixed entries as empty
    #[test]
    fn parse_pinned_pane_ids_treats_missing_null_non_array_or_mixed_entries_as_empty() {
        assert!(parse_pinned_pane_ids(None).is_empty());
        for value in [
            json!(null),
            json!("w1:p1"),
            json!(1),
            json!({ "0": "w3:p4" }),
            json!([1, "w3:p4"]),
            json!(["w3:p4", null]),
        ] {
            assert!(parse_pinned_pane_ids(Some(&value)).is_empty(), "{value}");
        }
    }

    // eligible status helpers: eligibleStatusMap ignores idle panes and lowercases statuses
    #[test]
    fn eligible_status_map_ignores_idle_panes_and_lowercases_statuses() {
        let map = eligible_status_map(&[
            plain("w1:p1", "Working"),
            plain("w1:p2", "idle"),
            plain("w1:p3", "BLOCKED"),
        ]);
        assert_eq!(
            Value::Object(map),
            json!({ "w1:p1": "working", "w1:p3": "blocked" })
        );
    }

    // eligible status helpers: sameStatusMap compares pane-to-status maps
    #[test]
    fn same_status_map_compares_pane_to_status_maps() {
        let left = map_of(json!({ "a": "working" }));
        assert!(same_status_map(&left, Some(&json!({ "a": "working" }))));
        assert!(!same_status_map(&left, Some(&json!({ "a": "done" }))));
        assert!(!same_status_map(
            &left,
            Some(&json!({ "a": "working", "b": "done" }))
        ));
        assert!(same_status_map(&Map::new(), None));
        assert!(same_status_map(&Map::new(), Some(&json!(null))));
        assert!(!same_status_map(&left, None));
    }

    // eligible status helpers: hasNewlyBlocked treats a missing previous map as empty
    #[test]
    fn has_newly_blocked_treats_a_missing_previous_map_as_empty() {
        let blocked = |value: Value| map_of(value);
        assert!(has_newly_blocked(&blocked(json!({ "a": "blocked" })), None));
        assert!(has_newly_blocked(
            &blocked(json!({ "a": "blocked" })),
            Some(&Value::Null)
        ));
        assert!(!has_newly_blocked(
            &blocked(json!({ "a": "blocked" })),
            Some(&json!({ "a": "blocked" }))
        ));
        assert!(has_newly_blocked(
            &blocked(json!({ "a": "blocked", "b": "working" })),
            Some(&json!({ "a": "working" }))
        ));
        assert!(!has_newly_blocked(
            &blocked(json!({ "a": "working" })),
            Some(&json!({ "a": "blocked" }))
        ));
    }

    // eligible status helpers: attentionCount counts Blocked and Done agents only, case-insensitively
    #[test]
    fn attention_count_counts_blocked_and_done_agents_only_case_insensitively() {
        let agents = [
            plain("w1:p1", "Blocked"),
            plain("w1:p2", "done"),
            plain("w1:p3", "working"),
            plain("w1:p4", "idle"),
            plain("w1:p5", "unknown"),
            plain("", "blocked"),
            Value::Null,
        ];
        assert_eq!(attention_count(&agents), 2);
        assert_eq!(attention_count(&[]), 0);
    }

    const HOSTNAME: &str = "build-box.example.com";

    fn tmux_agent(pane_id: &str, status: Value, extra: Value) -> Value {
        let mut entry = json!({
            "paneId": pane_id, "sessionId": "tmux:$1", "sessionName": "dev", "windowId": "tmux:@2",
            "windowName": "api", "cwd": "/work/api", "agent": "claude", "status": status,
            "session": null, "transcript": null, "seq": "1790000000000000000", "title": null, "command": "2.1.286",
        });
        for (key, value) in extra.as_object().unwrap() {
            entry[key] = value.clone();
        }
        entry
    }

    // tmuxActivityInventory: tmux Agents count, sort, and pin beside herdr's under their tmux: ids
    #[test]
    fn tmux_agents_count_sort_and_pin_beside_herdrs_under_their_tmux_ids() {
        let tmux = tmux_activity_inventory(
            &[
                tmux_agent(
                    "tmux:%3",
                    json!("working"),
                    json!({ "title": "✳ Fix flaky test" }),
                ),
                tmux_agent("tmux:%4", json!("done"), json!({})),
                tmux_agent("tmux:%5", json!("idle"), json!({})),
                // Listed for its @waycar_agent alone, or stale: neither eligible nor idle.
                tmux_agent("tmux:%6", json!(null), json!({})),
            ],
            HOSTNAME,
        );
        let mut agents = vec![
            agent(
                "w1:p1",
                "blocked",
                json!({ "agent": "codex", "workspace_id": "w1" }),
            ),
            plain("w1:p2", "idle"),
        ];
        agents.extend(tmux.agents.clone());
        let mut labels = map_of(json!({ "w1": "Waycar" }));
        labels.extend(tmux.workspace_labels.clone());
        let pins = json!(["tmux:%3"]);
        let state = build_activity_state(&BuildInput {
            pinned_pane_ids: Some(&pins),
            workspace_labels: &labels,
            ..BuildInput::new(&agents, "box")
        });
        assert_eq!(
            state.counts,
            Counts {
                working: 1,
                blocked: 1,
                done: 1,
                idle: 2
            }
        );
        assert_eq!(
            Value::Array(entries(&state).clone()),
            json!([
                { "kind": "claude", "pane": "tmux:%3", "status": "working", "title": "Fix flaky test", "workspace": "dev" },
                { "kind": "codex", "pane": "w1:p1", "status": "blocked", "workspace": "Waycar" },
                { "kind": "claude", "pane": "tmux:%4", "status": "done", "workspace": "dev" },
            ])
        );
        assert_eq!(
            Value::Object(eligible_status_map(&agents)),
            json!({ "w1:p1": "blocked", "tmux:%3": "working", "tmux:%4": "done" })
        );
        assert_eq!(attention_count(&agents), 2);
    }

    // tmuxActivityInventory: raw tmux ids gain the prefix, and tmux's hostname default title is dropped
    #[test]
    fn raw_tmux_ids_gain_the_prefix_and_tmuxs_hostname_default_title_is_dropped() {
        let tmux = tmux_activity_inventory(
            &[tmux_agent(
                "%3",
                json!("blocked"),
                json!({ "sessionId": "$1", "windowId": "@2", "title": HOSTNAME, "agent": null }),
            )],
            HOSTNAME,
        );
        assert_eq!(
            tmux.agents,
            [
                json!({ "pane_id": "tmux:%3", "agent_status": "blocked", "workspace_id": "tmux:$1", "tab_id": "tmux:@2", "cwd": "/work/api" })
            ]
        );
        assert_eq!(
            tmux.workspace_labels
                .iter()
                .map(|(k, v)| (k.as_str(), v.clone()))
                .collect::<Vec<_>>(),
            [("tmux:$1", json!("dev"))]
        );
        assert_eq!(tmux.tabs["tmux:@2"]["label"], "api");
        let state = build_activity_state(&BuildInput {
            workspace_labels: &tmux.workspace_labels,
            ..BuildInput::new(&tmux.agents, "box")
        });
        assert_eq!(
            Value::Array(entries(&state).clone()),
            json!([{ "kind": "unknown", "pane": "tmux:%3", "status": "blocked", "workspace": "dev" }])
        );
    }

    // tmuxActivityInventory: a registered row layout renders the session, window, and directory of a tmux Agent
    #[test]
    fn a_registered_row_layout_renders_the_session_window_and_directory_of_a_tmux_agent() {
        let tmux = tmux_activity_inventory(
            &[tmux_agent("tmux:%3", json!("working"), json!({}))],
            HOSTNAME,
        );
        let layout = parse_activity_row_layout(Some(
            &json!({ "rows": [[{ "token": "workspace" }, { "token": "tab" }], [{ "token": "directory" }]] }),
        ));
        let state = build_activity_state(&BuildInput {
            workspace_labels: &tmux.workspace_labels,
            tabs: &tmux.tabs,
            row_layout: layout.as_ref(),
            ..BuildInput::new(&tmux.agents, "box")
        });
        assert_eq!(
            entries(&state)[0]["rows"],
            json!([[{ "text": "dev" }, { "text": " · " }, { "text": "api" }], [{ "text": "/work/api" }]])
        );
    }

    #[test]
    fn short_host_name_is_the_first_label_trimmed_to_the_display_limit() {
        assert_eq!(short_host_name("build-box.example.com"), "build-box");
        assert_eq!(short_host_name("plain"), "plain");
        assert_eq!(short_host_name(".leading"), "");
        assert_eq!(short_host_name(""), "");
        let long = "h".repeat(DISPLAY_LIMIT + 5);
        let short = short_host_name(&long);
        assert_eq!(short.chars().count(), DISPLAY_LIMIT);
        assert!(short.ends_with('…'));
    }

    #[test]
    fn os_hostname_is_the_kernels_node_name() {
        let name = os_hostname().unwrap();
        assert!(!name.is_empty());
        assert!(!name.contains('\0'));
    }

    #[test]
    fn eligible_status_names_are_case_insensitive() {
        assert!(is_eligible_status("BLOCKED"));
        // KELVIN SIGN lower-cases to an ASCII k.
        assert!(is_eligible_status("bloc\u{212A}ed"));
        assert!(!is_eligible_status("idle"));
        assert!(!is_eligible_status(""));
    }

    #[test]
    fn repeated_panes_keep_their_first_place_and_last_status() {
        let map = eligible_status_map(&[
            plain("b", "working"),
            plain("a", "done"),
            plain("b", "blocked"),
        ]);
        assert_eq!(
            map.iter()
                .map(|(k, v)| (k.as_str(), v.as_str().unwrap()))
                .collect::<Vec<_>>(),
            [("b", "blocked"), ("a", "done")]
        );
    }
}

#[cfg(test)]
mod core_tests {
    use serde_json::json;

    use super::*;
    use crate::core::{CoreStatus, parse_record};

    fn listing(address: &str, status: Option<&str>) -> CoreListing {
        CoreListing {
            address: address.into(),
            agent: Some("claude".into()),
            cwd: Some("/start".into()),
            name: Some(format!("{address}-name")),
            state: "live".into(),
            status: status.map(String::from),
            turn: 1,
        }
    }

    fn record(value: Value) -> CoreTerminal {
        parse_record(&value).unwrap()
    }

    #[test]
    fn a_terminal_that_reported_becomes_an_agent_under_its_hc_id_with_the_listing_line_alone() {
        let l = listing("t1", Some("working"));
        let agents = core_activity_inventory(&[CoreRow {
            listing: &l,
            record: None,
        }]);
        assert_eq!(
            agents,
            [json!({
                "pane_id": "hc:t1", "agent": "claude", "agent_status": "working",
                "name": "t1-name", "cwd": "/start",
            })]
        );
        assert_eq!(
            build_activity_state(&BuildInput::new(&agents, "mac")).plaintext_object["agents"],
            json!([{ "kind": "claude", "name": "t1-name", "pane": "hc:t1", "status": "working" }])
        );
    }

    #[test]
    fn the_full_record_adds_the_hooks_kind_label_the_report_title_and_the_foreground_folder() {
        let l = listing("t2", Some("working"));
        let r = record(json!({
            "address": "t2", "state": "live", "name": "ci", "cwd": "/start", "title": "⠂ shell title",
            "foreground": { "cwd": "/work/api" },
            "labels": { "waycar.kind": "codex" },
            "status": { "state": "blocked", "app": "claude", "title": "✳ Fix flaky test" },
        }));
        let agents = core_activity_inventory(&[CoreRow {
            listing: &l,
            record: Some(&r),
        }]);
        // The record's status is the fresher one; the label beats the report's app.
        assert_eq!(
            agents,
            [json!({
                "pane_id": "hc:t2", "agent": "codex", "agent_status": "blocked", "name": "ci",
                "terminal_title": "✳ Fix flaky test", "terminal_title_stripped": "Fix flaky test",
                "cwd": "/work/api",
            })]
        );
    }

    #[test]
    fn error_is_blocked_and_unreported_or_unknown_words_are_no_agent() {
        let error = listing("t1", Some("error"));
        let silent = listing("t2", None);
        let odd = listing("t3", Some("starting"));
        let idle = listing("t4", Some("idle"));
        let rows: Vec<CoreRow<'_>> = [&error, &silent, &odd, &idle]
            .into_iter()
            .map(|listing| CoreRow {
                listing,
                record: None,
            })
            .collect();
        let agents = core_activity_inventory(&rows);
        let seen: Vec<(&str, &str)> = agents
            .iter()
            .map(|agent| {
                (
                    agent["pane_id"].as_str().unwrap(),
                    agent["agent_status"].as_str().unwrap(),
                )
            })
            .collect();
        assert_eq!(seen, [("hc:t1", "blocked"), ("hc:t4", "idle")]);
        assert_eq!(idle_count(&agents), 1);
        // A record that has no status (a report that vanished) is no Agent either.
        let r = CoreTerminal {
            address: "t1".into(),
            state: "live".into(),
            status: None::<CoreStatus>,
            ..CoreTerminal::default()
        };
        assert!(
            core_activity_inventory(&[CoreRow {
                listing: &error,
                record: Some(&r),
            }])
            .is_empty()
        );
    }

    #[test]
    fn core_agents_sort_and_pin_beside_herdrs_and_tmuxs() {
        let working = listing("t1", Some("working"));
        let mut agents = core_activity_inventory(&[CoreRow {
            listing: &working,
            record: None,
        }]);
        agents.push(json!({ "pane_id": "w1:p1", "agent": "omp", "agent_status": "blocked" }));
        agents.push(json!({ "pane_id": "tmux:%3", "agent": "claude", "agent_status": "done" }));
        let panes = |pins: Option<&Value>| visible_pane_ids(&agents, pins);
        assert_eq!(panes(None), ["w1:p1", "tmux:%3", "hc:t1"]);
        assert_eq!(
            panes(Some(&json!(["hc:t1"]))),
            ["hc:t1", "w1:p1", "tmux:%3"]
        );
    }
}
