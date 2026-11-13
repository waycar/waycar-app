//! Agent Progress from an Agent's own plan (plan-progress.js; see README.md,
//! "Agent Progress").
//!
//! Coding agents keep a step list while they work: omp's `todo` tool, codex's
//! `update_plan`, opencode's `todowrite`, Claude Code's `TaskCreate` /
//! `TaskUpdate` (older builds: `TodoWrite`), and pi's task extension
//! (`TaskCreate` / `TaskUpdate`). [`read_plan_progress`] reads that list from
//! the Agent's transcript on this Host, through `chat::transcript`'s
//! locators and parsers so turns split exactly as Chat Mode splits them, and
//! counts the steps of the plan written in the Agent's current turn. Nothing
//! is sent to a model. Every other kind (gemini, kilo, hermes, ...) has no
//! plan read here, so it has no steps.

use std::collections::{BTreeMap, HashSet};
use std::sync::Arc;
use std::time::Duration;

use serde_json::Value;

use crate::chat::launch_rivals::launch_rivals;
use crate::chat::marker::{AppliesQuery, marker_applies, read_marker};
use crate::chat::shared::{
    AbortSignal, ChatError, ChatTurns, ErrorKind, PlanSteps, ToolCall, ToolResult, Turn,
    TurnObserver,
};
use crate::chat::transcript::{ParseArgs, RivalQuery, Rivals, parse_transcript};
use crate::env::Env;
use crate::exec::run_program;
use crate::jsx;
use crate::summary::agent::linked_signal;
use crate::summary::store::PROGRESS_TOTAL_MAX;

/// A plan read's own budget, apart from any summary model call's.
pub const PLAN_READ_TIMEOUT_MS: u64 = 10_000;

/// What [`read_plan_progress`] answers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PlanProgress {
    /// `null`: no plan this turn.
    None,
    /// `PLAN_UNREADABLE`: the plan could not be read (a timeout, an abort, an
    /// unreadable transcript). Unlike `None` it says nothing about the plan,
    /// so callers write nothing on it.
    Unreadable,
    Steps(PlanSteps),
}

/// A transcript session: `kind` is `"id"` or `"path"`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionRef {
    pub kind: String,
    pub value: String,
}

/// Each kind's plan tools: `snapshot` tools carry the whole list in their
/// call input, `result` tools in their result's `details`, and
/// `create`/`update` tools change one task at a time (the list is replayed).
#[derive(Clone, Copy, Default)]
struct PlanTools {
    snapshot: &'static [&'static str],
    result: &'static [&'static str],
    create: Option<&'static str>,
    update: Option<&'static str>,
}

fn plan_tools(kind: &str) -> Option<PlanTools> {
    Some(match kind {
        "omp" => PlanTools {
            result: &["todo"],
            ..PlanTools::default()
        },
        "codex" => PlanTools {
            snapshot: &["update_plan"],
            ..PlanTools::default()
        },
        "opencode" => PlanTools {
            snapshot: &["todowrite"],
            ..PlanTools::default()
        },
        "claude" => PlanTools {
            snapshot: &["TodoWrite"],
            create: Some("TaskCreate"),
            update: Some("TaskUpdate"),
            ..PlanTools::default()
        },
        "pi" => PlanTools {
            create: Some("TaskCreate"),
            update: Some("TaskUpdate"),
            ..PlanTools::default()
        },
        _ => return None,
    })
}

const DONE_STATUSES: [&str; 3] = ["completed", "complete", "done"];
/// Steps the Agent dropped: they are no part of the work left.
const DROPPED_STATUSES: [&str; 4] = ["cancelled", "canceled", "deleted", "abandoned"];

/// `herdrSessionReference`: herdr's `agent_session` (`agent list`) as a
/// transcript session, or `None`.
pub fn herdr_session_reference(session: &Value) -> Option<SessionRef> {
    let kind = jsx::field(session, "kind").as_str()?;
    let value = jsx::field(session, "value").as_str()?;
    if (kind != "id" && kind != "path") || value.is_empty() {
        return None;
    }
    Some(SessionRef {
        kind: kind.to_string(),
        value: value.to_string(),
    })
}

/// `tmuxSessionReference`: a tmux Agent's transcript session from
/// tmux-adapter's row: an absolute `@waycar_session` is a path and any other
/// one an id, else the `@waycar_transcript` path (as the app's
/// `TmuxInventory.agentSession`).
pub fn tmux_session_reference(
    session: Option<&str>,
    transcript: Option<&str>,
) -> Option<SessionRef> {
    if let Some(session) = session.filter(|s| !s.is_empty()) {
        return Some(SessionRef {
            kind: if session.starts_with('/') {
                "path"
            } else {
                "id"
            }
            .to_string(),
            value: session.to_string(),
        });
    }
    transcript
        .filter(|t| !t.is_empty())
        .map(|transcript| SessionRef {
            kind: "path".to_string(),
            value: transcript.to_string(),
        })
}

/// A herdr-core terminal's transcript session from its record's labels, which
/// the agent hooks write (`waycar.session`, `waycar.transcript`): read as a
/// tmux Agent's `@waycar_session` and `@waycar_transcript` are, by
/// [`tmux_session_reference`].
pub fn core_session_reference(labels: &BTreeMap<String, String>) -> Option<SessionRef> {
    let label = |key: &str| labels.get(key).map(String::as_str);
    tmux_session_reference(label("waycar.session"), label("waycar.transcript"))
}

/// `readPlanProgress`'s options.
pub struct PlanArgs<'a> {
    /// The Agent's kind (claude, codex, omp, ...).
    pub agent: &'a str,
    /// Its transcript session ([`herdr_session_reference`] / [`tmux_session_reference`]).
    pub session: Option<&'a SessionRef>,
    /// The Agent's working directory.
    pub cwd: Option<&'a str>,
    /// Its pane, for the Chat Marker fallback.
    pub pane_id: Option<&'a str>,
    /// The plugin config dir holding markers.
    pub config_dir: Option<&'a str>,
    /// herdr's terminal id (`markerApplies`).
    pub terminal_id: Option<&'a str>,
    /// Environment for the locators and `opencode export`.
    pub env: &'a Env,
    /// Home directory the transcripts live under.
    pub home: &'a str,
    /// The caller's own deadline.
    pub signal: Option<&'a Arc<AbortSignal>>,
    /// This read's budget.
    pub timeout_ms: u64,
}

/// Where to look for the transcript.
struct Located {
    session_kind: Option<String>,
    session_value: Option<String>,
    cwd: Option<String>,
    launched_at: Option<String>,
}

/// The live session, else what the pane's Chat Marker recorded (its session,
/// or its cwd and launch time); `None` when there is nothing to look with.
fn locate(args: &PlanArgs<'_>) -> Option<Located> {
    if let Some(session) = args.session {
        return Some(Located {
            session_kind: Some(session.kind.clone()),
            session_value: Some(session.value.clone()),
            cwd: args.cwd.map(str::to_string),
            launched_at: None,
        });
    }
    let (config_dir, pane_id) = (args.config_dir?, args.pane_id?);
    let marker = read_marker(config_dir, pane_id);
    let applies = AppliesQuery {
        kind: Some(args.agent),
        terminal_id: args.terminal_id,
        agent_session: None,
    };
    if !marker_applies(marker.as_ref(), &applies) {
        return None;
    }
    let marker = marker?;
    let launched_at = match marker.session {
        None => Some(marker.launched_at.clone()?),
        Some(_) => None,
    };
    Some(Located {
        session_kind: marker.session.as_ref().map(|s| s.kind.clone()),
        session_value: marker.session.as_ref().map(|s| s.value.clone()),
        cwd: args.cwd.map(str::to_string).or(marker.cwd.clone()),
        launched_at,
    })
}

/// The steps done and in all of the plan the Agent wrote in its current turn;
/// `None` when there is none to show (the kind has no plan tool or reader, no
/// transcript is found, the current turn has ended or wrote no plan, its plan
/// is empty or longer than `PROGRESS_TOTAL_MAX` steps); `Unreadable` when the
/// read timed out, was aborted, or failed. Never fails.
///
/// Without a live session the pane's Chat Marker (when it applies to this
/// Agent) supplies one, or its cwd and launch time, as for Chat Mode.
pub fn read_plan_progress(args: &PlanArgs<'_>) -> PlanProgress {
    let Some(tools) = plan_tools(args.agent) else {
        return PlanProgress::None;
    };
    let parents: Vec<Arc<AbortSignal>> = args.signal.into_iter().cloned().collect();
    let budget = linked_signal(&parents, Some(Duration::from_millis(args.timeout_ms)));
    let signal = &budget.signal;
    let outcome: Result<Option<PlanSteps>, Option<ChatError>> = (|| {
        let located = locate(args).ok_or(None)?;
        signal.check().map_err(Some)?;
        let config_dir = args.config_dir.unwrap_or("");
        // A launch match with no session (opencode) leaves out sessions other
        // Agents of the kind could have started, as Chat Mode does.
        let rivals = |query: &RivalQuery| -> Rivals {
            launch_rivals(config_dir, query, args.env, args.home, &run_program)
        };
        let mut turns = ChatTurns::with_observer(Box::new(PlanTurns::new(tools)));
        let found = parse_transcript(
            &ParseArgs {
                kind: args.agent,
                session_kind: located.session_kind.as_deref(),
                session_value: located.session_value.as_deref(),
                cwd: located.cwd.as_deref(),
                launched_at: located.launched_at.as_deref(),
                launch_rivals: Some(&rivals),
                env: args.env,
                home: args.home,
                signal: Some(signal),
            },
            &mut turns,
        )
        .map_err(Some)?;
        signal.check().map_err(Some)?;
        Ok(if found { progress(&turns) } else { None })
    })();
    match outcome {
        Ok(steps) => steps.map_or(PlanProgress::None, PlanProgress::Steps),
        // `locate` found nothing to look with.
        Err(None) => PlanProgress::None,
        Err(Some(error)) => {
            if signal.is_aborted() {
                return PlanProgress::Unreadable;
            }
            // Only a transcript or session that is truly not there is "no
            // plan"; a failed `opencode export` (its database busy, say)
            // says nothing.
            let missing =
                error.is_missing() || matches!(error.kind, ErrorKind::Export { absent: true, .. });
            if missing {
                PlanProgress::None
            } else {
                PlanProgress::Unreadable
            }
        }
    }
}

/// The current turn's plan steps, when the turn is still open (`progress()`).
fn progress(turns: &ChatTurns) -> Option<PlanSteps> {
    let turn = turns.current()?;
    if turn.ended {
        return None;
    }
    let plan = turn.plan?;
    (plan.total >= 1 && i64::from(plan.total) <= PROGRESS_TOTAL_MAX).then_some(plan)
}

/// One step of a list: the key names an omp task by its phase and text; the
/// status is `statusOf(item)`, lower-cased.
struct Item {
    key: String,
    status: String,
}

/// ChatTurns' observer that also follows the plan: each turn keeps the steps
/// of the last plan written in it (`turn.plan`), so a plan from an earlier
/// turn never counts for a later one. Lists that outlive a turn (omp's
/// `todo` list and the replayed tasks) leave out the steps earlier turns
/// finished.
struct PlanTurns {
    tools: PlanTools,
    /// Replayed tasks (create/update tools), task id to status, session-wide.
    /// Insertion order is the JS `Map`'s (an update keeps a task's place).
    tasks: Vec<(String, String)>,
    /// The turn (its `seq`) the replayed tasks were last changed in.
    tasks_turn: Option<usize>,
    /// TaskCreate calls waiting for their result (the new task's id), by call id.
    creates: HashSet<String>,
    /// omp: the last `todo` list seen, and the steps it had finished before
    /// the current turn first touched the list (with that turn's `seq`).
    todo_latest: Option<Vec<Item>>,
    todo_baseline: Option<(usize, HashSet<String>)>,
}

impl PlanTurns {
    fn new(tools: PlanTools) -> Self {
        Self {
            tools,
            tasks: Vec::new(),
            tasks_turn: None,
            creates: HashSet::new(),
            todo_latest: None,
            todo_baseline: None,
        }
    }

    /// One omp `todo` result: the whole session's list after the op. Steps
    /// the list had finished before this turn first touched it belong to
    /// earlier turns and are left out; an `init` starts a new list, and a
    /// `view` is a look, not a write.
    fn todo_result(&mut self, turn: &mut Turn, details: &Value) {
        let Some(items) = omp_todo_items(details) else {
            return;
        };
        let op = jsx::field(details, "op").as_str();
        if op == Some("init") {
            self.todo_baseline = Some((turn.seq, HashSet::new()));
        } else if self.todo_baseline.as_ref().map(|b| b.0) != Some(turn.seq) {
            let finished = finished_keys(self.todo_latest.as_deref().unwrap_or(&[]));
            self.todo_baseline = Some((turn.seq, finished));
        }
        self.todo_latest = Some(items);
        if op == Some("view") {
            return;
        }
        let finished = self.todo_baseline.as_ref().map(|b| &b.1);
        let items = self.todo_latest.as_deref().unwrap_or(&[]);
        let kept: Vec<&Item> = items
            .iter()
            .filter(|item| {
                !(is_done(&item.status) && finished.is_some_and(|f| f.contains(&item.key)))
            })
            .collect();
        turn.plan = Some(count_steps(kept.iter().map(|item| item.status.as_str())));
    }

    /// Replay one task change. The first change in a new turn first drops the
    /// tasks earlier turns finished: they are no part of this turn's plan.
    fn change_task(&mut self, turn: &mut Turn, id: &str, status: &str) {
        if self.tasks_turn != Some(turn.seq) {
            self.tasks.retain(|(_, value)| !is_done(value));
            self.tasks_turn = Some(turn.seq);
        }
        if status == "deleted" {
            self.tasks.retain(|(key, _)| key != id);
        } else if let Some(entry) = self.tasks.iter_mut().find(|(key, _)| key == id) {
            entry.1 = status.to_string();
        } else {
            self.tasks.push((id.to_string(), status.to_string()));
        }
        turn.plan = Some(count_steps(
            self.tasks.iter().map(|(_, value)| value.as_str()),
        ));
    }
}

impl TurnObserver for PlanTurns {
    fn observes(&self, name: Option<&str>) -> bool {
        let tools = &self.tools;
        name.is_some_and(|name| tools.snapshot.contains(&name) || tools.result.contains(&name))
            || name == tools.create
            || name == tools.update
    }

    fn tool(&mut self, turn: &mut Turn, call: &ToolCall<'_>) {
        let name = call.name;
        let tools = self.tools;
        if name.is_some_and(|name| tools.snapshot.contains(&name)) {
            let parsed;
            let input = match call.input {
                Some(Value::String(text)) => {
                    parsed = parse_object(text);
                    &parsed
                }
                Some(input) => input,
                None => &Value::Null,
            };
            if let Some(items) = snapshot_items(input) {
                let statuses: Vec<String> = items.iter().map(status_of_value).collect();
                turn.plan = Some(count_steps(statuses.iter().map(String::as_str)));
            }
        } else if name == tools.create {
            if let Some(call_id) = call.call_id {
                self.creates.insert(call_id.to_string());
            }
        } else if name == tools.update {
            let input = call.input.unwrap_or(&Value::Null);
            let id = task_id(jsx::field(input, "taskId"));
            let status = jsx::field(input, "status").as_str();
            if let (Some(id), Some(status)) = (id, status)
                && self.tasks.iter().any(|(key, _)| *key == id)
            {
                self.change_task(turn, &id, &status.to_lowercase());
            }
        }
    }

    fn tool_result(&mut self, turn: Option<&mut Turn>, result: &ToolResult<'_>) {
        let Some(turn) = turn else {
            return;
        };
        if let Some(name) = result.name
            && self.tools.result.contains(&name)
        {
            self.todo_result(turn, result.details);
            return;
        }
        let removed = result.call_id.is_some_and(|id| self.creates.remove(id));
        if !removed {
            return;
        }
        let id = task_id(jsx::field(jsx::field(result.details, "task"), "id"))
            .or_else(|| task_id_from_text(&result_text(result.content)));
        if let Some(id) = id {
            self.change_task(turn, &id, "pending");
        }
    }
}

/// A snapshot tool's step list (`plan` or `todos`), or `None` for another shape.
fn snapshot_items(input: &Value) -> Option<&Vec<Value>> {
    let plan = jsx::field(input, "plan");
    let items = if plan.is_null() {
        jsx::field(input, "todos")
    } else {
        plan
    };
    items.as_array()
}

/// `${value}` for the values a task's phase name or text can be.
fn js_to_string(value: &Value) -> String {
    match value {
        Value::Null => "null".to_string(),
        Value::Bool(b) => b.to_string(),
        Value::Number(n) => jsx::number_to_string(jsx::json_f64(n)),
        Value::String(s) => s.clone(),
        Value::Array(items) => items
            .iter()
            .map(|item| {
                if item.is_null() {
                    String::new()
                } else {
                    js_to_string(item)
                }
            })
            .collect::<Vec<_>>()
            .join(","),
        Value::Object(_) => "[object Object]".to_string(),
    }
}

/// `${value}` for a property that may be missing (`undefined`).
fn js_to_string_opt(value: Option<&Value>) -> String {
    value.map_or_else(|| "undefined".to_string(), js_to_string)
}

/// omp `todo` result details: `phases[].tasks[]` flattened to `{key, status}`
/// (`key` names the task by its phase and text), or `None`.
fn omp_todo_items(details: &Value) -> Option<Vec<Item>> {
    let phases = jsx::field(details, "phases").as_array()?;
    let mut items = Vec::new();
    for phase in phases {
        let tasks = jsx::field(phase, "tasks").as_array()?;
        for task in tasks {
            let name = js_to_string_opt(jsx::get(phase, "name"));
            let content = js_to_string_opt(jsx::get(task, "content"));
            items.push(Item {
                key: format!("{name}\u{0}{content}"),
                status: status_of_value(task),
            });
        }
    }
    Some(items)
}

/// `statusOf(item)`: a string status lower-cased, else `pending`.
fn status_of_value(item: &Value) -> String {
    match jsx::field(item, "status") {
        Value::String(status) => status.to_lowercase(),
        _ => "pending".to_string(),
    }
}

fn is_done(status: &str) -> bool {
    DONE_STATUSES.contains(&status)
}

fn finished_keys(items: &[Item]) -> HashSet<String> {
    items
        .iter()
        .filter(|item| is_done(&item.status))
        .map(|item| item.key.clone())
        .collect()
}

/// Steps done and in all; dropped steps count for neither.
fn count_steps<'a>(statuses: impl Iterator<Item = &'a str>) -> PlanSteps {
    let (mut done, mut total) = (0, 0);
    for status in statuses {
        if DROPPED_STATUSES.contains(&status) {
            continue;
        }
        total += 1;
        if is_done(status) {
            done += 1;
        }
    }
    PlanSteps { done, total }
}

fn task_id(value: &Value) -> Option<String> {
    match value {
        Value::Number(number) if jsx::is_integer(value) => {
            Some(jsx::number_to_string(jsx::json_f64(number)))
        }
        Value::String(text) if !text.is_empty() => Some(text.clone()),
        _ => None,
    }
}

/// `TASK_CREATED.exec(text)?.[1]` with `/\bTask #([^\s:]+) created\b/`.
fn task_id_from_text(text: &str) -> Option<String> {
    const HEAD: &str = "Task #";
    const TAIL: &str = " created";
    let word = |c: char| c.is_ascii_alphanumeric() || c == '_';
    let mut from = 0;
    while let Some(found) = text[from..].find(HEAD) {
        let start = from + found;
        from = start + 1;
        if text[..start].chars().next_back().is_some_and(word) {
            continue;
        }
        let rest = &text[start + HEAD.len()..];
        let end = rest
            .find(|c: char| jsx::is_js_space(c) || c == ':')
            .unwrap_or(rest.len());
        if end == 0 {
            continue;
        }
        let Some(after) = rest[end..].strip_prefix(TAIL) else {
            continue;
        };
        if after.chars().next().is_some_and(word) {
            continue;
        }
        return Some(rest[..end].to_string());
    }
    None
}

/// `resultText(content)`: a string as is, the text blocks of an array joined
/// by newlines, else empty.
fn result_text(content: &Value) -> String {
    match content {
        Value::String(text) => text.clone(),
        Value::Array(blocks) => blocks
            .iter()
            .filter_map(|block| {
                (jsx::field(block, "type").as_str() == Some("text"))
                    .then(|| jsx::field(block, "text").as_str())
                    .flatten()
            })
            .collect::<Vec<_>>()
            .join("\n"),
        _ => String::new(),
    }
}

/// `parseObject(text)`: a JSON object or array, else `null`.
fn parse_object(text: &str) -> Value {
    match jsx::parse_json(text) {
        Some(value @ (Value::Object(_) | Value::Array(_))) => value,
        _ => Value::Null,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::chat::marker::marker_path;
    use serde_json::json;
    use std::fs;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU32, Ordering};

    static COUNTER: AtomicU32 = AtomicU32::new(0);

    struct Dir(PathBuf);

    impl Dir {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "plan-progress-{}-{}",
                std::process::id(),
                COUNTER.fetch_add(1, Ordering::SeqCst)
            ));
            fs::create_dir_all(&path).unwrap();
            Self(path)
        }

        fn str(&self) -> &str {
            self.0.to_str().unwrap()
        }

        fn join(&self, name: &str) -> String {
            self.0.join(name).to_str().unwrap().to_string()
        }

        fn write_lines(&self, name: &str, records: &[Value]) -> String {
            let file = self.join(name);
            let body: Vec<String> = records.iter().map(jsx::stringify).collect();
            fs::write(&file, format!("{}\n", body.join("\n"))).unwrap();
            file
        }

        fn read(&self, agent: &str, session: Option<SessionRef>, env: &Env) -> PlanProgress {
            read_plan_progress(&PlanArgs {
                agent,
                session: session.as_ref(),
                cwd: None,
                pane_id: None,
                config_dir: None,
                terminal_id: None,
                env,
                home: self.str(),
                signal: None,
                timeout_ms: PLAN_READ_TIMEOUT_MS,
            })
        }

        /// Read `records` as an Agent of `agent` kind whose session is that file.
        fn progress_of(&self, agent: &str, records: &[Value]) -> PlanProgress {
            let file = self.write_lines(&format!("{agent}.jsonl"), records);
            self.read(agent, Some(path_session(&file)), &Env::default())
        }
    }

    impl Drop for Dir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn path_session(file: &str) -> SessionRef {
        SessionRef {
            kind: "path".into(),
            value: file.into(),
        }
    }

    fn id_session(id: &str) -> SessionRef {
        SessionRef {
            kind: "id".into(),
            value: id.into(),
        }
    }

    fn steps_of(done: u32, total: u32) -> PlanProgress {
        PlanProgress::Steps(PlanSteps { done, total })
    }

    fn steps(statuses: &[&str]) -> Vec<Value> {
        statuses
            .iter()
            .enumerate()
            .map(|(i, status)| json!({ "content": format!("step {}", i + 1), "status": status }))
            .collect()
    }

    // MARK: omp and pi (one tree of `message` entries)

    fn omp_like(messages: Vec<Value>) -> Vec<Value> {
        let mut parent = Value::Null;
        let mut out = vec![json!({ "type": "session", "version": 3, "id": "s1", "cwd": "/work" })];
        for (index, message) in messages.into_iter().enumerate() {
            let id = format!("m{index}");
            let stamp = jsx::to_iso_string(1_760_000_000_000.0 + index as f64).unwrap();
            out.push(json!({
                "type": "message", "id": id, "parentId": parent,
                "timestamp": stamp, "message": message,
            }));
            parent = json!(id);
        }
        out
    }

    fn omp_prompt(text: &str) -> Value {
        json!({ "role": "user", "content": [{ "type": "text", "text": text }] })
    }

    fn omp_call(id: &str, name: &str, args: Value) -> Value {
        json!({ "role": "assistant", "content": [{ "type": "toolCall", "id": id, "name": name, "arguments": args }], "stopReason": "toolUse" })
    }

    fn omp_result(id: &str, name: &str, text: &str, details: Value) -> Value {
        let mut message = json!({ "role": "toolResult", "toolCallId": id, "toolName": name, "content": [{ "type": "text", "text": text }] });
        if !details.is_null() {
            message["details"] = details;
        }
        message
    }

    fn omp_stop(text: &str) -> Value {
        json!({ "role": "assistant", "content": [{ "type": "text", "text": text }], "stopReason": "stop" })
    }

    fn todo(id: &str, op: &str, tasks: &[Value]) -> Vec<Value> {
        vec![
            omp_call(id, "todo", json!({ "op": op })),
            omp_result(
                id,
                "todo",
                "Remaining items",
                json!({
                    "op": op,
                    "phases": [
                        { "name": "Build", "tasks": &tasks[..2.min(tasks.len())] },
                        { "name": "Ship", "tasks": tasks.get(2..).unwrap_or(&[]) },
                    ],
                    "storage": "session",
                }),
            ),
        ]
    }

    fn cat(parts: Vec<Vec<Value>>) -> Vec<Value> {
        parts.into_iter().flatten().collect()
    }

    #[test]
    fn counts_the_latest_list_written_in_the_open_turn_across_its_phases() {
        let dir = Dir::new();
        let records = omp_like(cat(vec![
            vec![omp_prompt("build it")],
            todo(
                "c1",
                "init",
                &steps(&["in_progress", "pending", "pending", "pending"]),
            ),
            todo(
                "c2",
                "done",
                &steps(&["completed", "completed", "in_progress", "pending"]),
            ),
            vec![omp_call("c3", "read", json!({ "path": "a.ts" }))],
        ]));
        assert_eq!(dir.progress_of("omp", &records), steps_of(2, 4));
    }

    #[test]
    fn a_list_from_an_earlier_turn_does_not_count_even_when_viewed_in_this_one() {
        let dir = Dir::new();
        let records = omp_like(cat(vec![
            vec![omp_prompt("build it")],
            todo("c1", "init", &steps(&["completed", "pending", "pending"])),
            vec![omp_stop("Partly done."), omp_prompt("now the docs")],
            todo("c2", "view", &steps(&["completed", "pending", "pending"])),
            vec![omp_call("c3", "read", json!({ "path": "README.md" }))],
        ]));
        assert_eq!(dir.progress_of("omp", &records), PlanProgress::None);
    }

    #[test]
    fn an_ended_turn_has_no_progress() {
        let dir = Dir::new();
        let records = omp_like(cat(vec![
            vec![omp_prompt("build it")],
            todo("c1", "init", &steps(&["completed", "pending"])),
            vec![omp_stop("Done.")],
        ]));
        assert_eq!(dir.progress_of("omp", &records), PlanProgress::None);
    }

    #[test]
    fn a_steering_message_joins_the_running_turn_and_keeps_its_plan() {
        let dir = Dir::new();
        let mut steering = omp_prompt("also add tests");
        steering["steering"] = json!(true);
        let records = omp_like(cat(vec![
            vec![omp_prompt("build it")],
            todo("c1", "init", &steps(&["completed", "pending", "blocked"])),
            vec![steering, omp_call("c2", "read", json!({ "path": "a.ts" }))],
        ]));
        assert_eq!(dir.progress_of("omp", &records), steps_of(1, 3));
    }

    // omp keeps one list for the whole session: a follow-up turn's first
    // write still lists the steps earlier turns finished.
    #[test]
    fn a_follow_up_turn_leaves_out_the_steps_earlier_turns_finished() {
        let dir = Dir::new();
        let earlier = || {
            cat(vec![
                vec![omp_prompt("build it")],
                todo(
                    "c1",
                    "init",
                    &steps(&["in_progress", "pending", "pending", "pending"]),
                ),
                todo(
                    "c2",
                    "done",
                    &steps(&["completed", "completed", "pending", "pending"]),
                ),
                vec![omp_stop("Half done."), omp_prompt("carry on")],
            ])
        };
        let follow_up = omp_like(cat(vec![
            earlier(),
            todo(
                "c3",
                "done",
                &steps(&["completed", "completed", "completed", "pending"]),
            ),
        ]));
        assert_eq!(dir.progress_of("omp", &follow_up), steps_of(1, 2));

        // A new list (init) in the follow-up turn is all this turn's.
        let fresh = omp_like(cat(vec![
            earlier(),
            todo("c3", "init", &steps(&["completed", "pending"])),
        ]));
        assert_eq!(dir.progress_of("omp", &fresh), steps_of(1, 2));
    }

    fn create(id: &str, n: u32, subject: &str) -> Vec<Value> {
        vec![
            omp_call(
                id,
                "TaskCreate",
                json!({ "subject": subject, "description": subject }),
            ),
            omp_result(
                id,
                "TaskCreate",
                &format!("Task #{n} created successfully: {subject}"),
                Value::Null,
            ),
        ]
    }

    fn update(id: &str, task_id: &str, status: &str) -> Vec<Value> {
        vec![
            omp_call(
                id,
                "TaskUpdate",
                json!({ "taskId": task_id, "status": status }),
            ),
            omp_result(
                id,
                "TaskUpdate",
                &format!("Updated task #{task_id} status"),
                Value::Null,
            ),
        ]
    }

    #[test]
    fn replays_creates_and_updates_a_deleted_task_leaves_the_plan() {
        let dir = Dir::new();
        let records = omp_like(cat(vec![
            vec![omp_prompt("find activities")],
            create("c1", 1, "indoor"),
            create("c2", 2, "events"),
            create("c3", 3, "outings"),
            update("c4", "1", "completed"),
            update("c5", "3", "deleted"),
            update("c6", "9", "completed"),
        ]));
        assert_eq!(dir.progress_of("pi", &records), steps_of(1, 2));
    }

    #[test]
    fn a_new_turn_drops_the_tasks_earlier_turns_finished_and_counts_only_once_it_changes_a_task() {
        let dir = Dir::new();
        let earlier = || {
            cat(vec![
                vec![omp_prompt("find activities")],
                create("c1", 1, "indoor"),
                create("c2", 2, "events"),
                update("c3", "1", "completed"),
                vec![omp_stop("Found some."), omp_prompt("and restaurants")],
            ])
        };
        assert_eq!(
            dir.progress_of("pi", &omp_like(earlier())),
            PlanProgress::None
        );

        let records = omp_like(cat(vec![
            earlier(),
            create("c4", 3, "restaurants"),
            update("c5", "3", "in_progress"),
        ]));
        assert_eq!(dir.progress_of("pi", &records), steps_of(0, 2));
    }

    // MARK: codex

    struct CodexTurn {
        id: &'static str,
        prompt: &'static str,
        plans: Vec<Vec<Value>>,
        complete: bool,
    }

    fn codex_records(turns: Vec<CodexTurn>) -> Vec<Value> {
        let mut records =
            vec![json!({ "type": "session_meta", "payload": { "id": "019f", "cwd": "/work" } })];
        for turn in turns {
            records.push(json!({ "type": "event_msg", "payload": { "type": "task_started", "turn_id": turn.id } }));
            records.push(json!({ "type": "event_msg", "payload": { "type": "user_message", "message": turn.prompt } }));
            for (index, plan) in turn.plans.iter().enumerate() {
                let rows: Vec<Value> = plan
                    .iter()
                    .map(|s| json!({ "step": s["content"], "status": s["status"] }))
                    .collect();
                records.push(json!({
                    "type": "response_item",
                    "payload": {
                        "type": "function_call",
                        "name": "update_plan",
                        "arguments": jsx::stringify(&json!({ "explanation": "why", "plan": rows })),
                        "call_id": format!("{}-{index}", turn.id),
                    },
                }));
            }
            if turn.complete {
                records.push(json!({ "type": "event_msg", "payload": { "type": "task_complete", "turn_id": turn.id, "last_agent_message": "ok" } }));
            }
        }
        records
    }

    #[test]
    fn counts_the_open_turns_last_plan() {
        let dir = Dir::new();
        let records = codex_records(vec![
            CodexTurn {
                id: "t1",
                prompt: "first",
                plans: vec![steps(&["completed", "completed"])],
                complete: true,
            },
            CodexTurn {
                id: "t2",
                prompt: "second",
                plans: vec![
                    steps(&["in_progress", "pending", "pending"]),
                    steps(&["completed", "in_progress", "pending"]),
                ],
                complete: false,
            },
        ]);
        assert_eq!(dir.progress_of("codex", &records), steps_of(1, 3));
    }

    #[test]
    fn a_plan_from_a_completed_turn_does_not_count_for_the_next_one() {
        let dir = Dir::new();
        let records = codex_records(vec![
            CodexTurn {
                id: "t1",
                prompt: "first",
                plans: vec![steps(&["completed", "pending"])],
                complete: true,
            },
            CodexTurn {
                id: "t2",
                prompt: "second",
                plans: vec![],
                complete: false,
            },
        ]);
        assert_eq!(dir.progress_of("codex", &records), PlanProgress::None);
    }

    // MARK: claude

    fn claude_user(uuid: &str, content: Value, extra: Value) -> Value {
        let mut record = json!({ "type": "user", "uuid": uuid, "isSidechain": false, "timestamp": "2026-10-01T12:00:00.000Z", "message": { "role": "user", "content": content } });
        if let Some(extra) = extra.as_object() {
            for (k, v) in extra {
                record[k] = v.clone();
            }
        }
        record
    }

    fn claude_tool(uuid: &str, id: &str, name: &str, input: Value) -> Value {
        json!({
            "type": "assistant", "uuid": uuid, "isSidechain": false,
            "timestamp": "2026-10-01T12:00:00.000Z",
            "message": { "role": "assistant", "content": [{ "type": "tool_use", "id": id, "name": name, "input": input }], "stop_reason": "tool_use" },
        })
    }

    fn claude_result(uuid: &str, id: &str, text: &str, tool_use_result: Option<Value>) -> Value {
        let extra = tool_use_result.map_or(json!({}), |v| json!({ "toolUseResult": v }));
        claude_user(
            uuid,
            json!([{ "type": "tool_result", "tool_use_id": id, "content": text }]),
            extra,
        )
    }

    #[test]
    fn replays_task_create_id_from_its_result_and_task_update() {
        let dir = Dir::new();
        let records = vec![
            claude_user("u1", json!("ship the feature"), json!({})),
            claude_tool(
                "a1",
                "tu1",
                "TaskCreate",
                json!({ "subject": "Write code", "description": "x" }),
            ),
            claude_result(
                "r1",
                "tu1",
                "Task #1 created successfully: Write code",
                Some(json!({ "task": { "id": "1", "subject": "Write code" } })),
            ),
            claude_tool(
                "a2",
                "tu2",
                "TaskCreate",
                json!({ "subject": "Run tests", "description": "y" }),
            ),
            claude_result("r2", "tu2", "Task #2 created successfully: Run tests", None),
            claude_tool(
                "a3",
                "tu3",
                "TaskUpdate",
                json!({ "taskId": "1", "status": "completed" }),
            ),
            claude_result("r3", "tu3", "Updated task #1 status", None),
        ];
        assert_eq!(dir.progress_of("claude", &records), steps_of(1, 2));
    }

    #[test]
    fn a_todo_write_snapshot_counts_and_ending_the_turn_clears_it() {
        let dir = Dir::new();
        let todos: Vec<Value> = steps(&["completed", "in_progress", "pending"])
            .into_iter()
            .map(|mut s| {
                s["activeForm"] = s["content"].clone();
                s
            })
            .collect();
        let plan = vec![
            claude_user("u1", json!("fix it"), json!({})),
            claude_tool("a1", "tu1", "TodoWrite", json!({ "todos": todos })),
            claude_result("r1", "tu1", "Todos have been modified successfully", None),
        ];
        assert_eq!(dir.progress_of("claude", &plan), steps_of(1, 3));

        let mut end = claude_tool("a2", "x", "Read", json!({}));
        end["message"] = json!({ "role": "assistant", "content": [{ "type": "text", "text": "Done." }], "stop_reason": "end_turn" });
        let mut ended = plan.clone();
        ended.push(end);
        assert_eq!(dir.progress_of("claude", &ended), PlanProgress::None);
    }

    // MARK: opencode

    fn stub_export(dir: &Dir, messages: Value) -> Env {
        let file = dir.join("export.json");
        fs::write(
            &file,
            jsx::stringify(
                &json!({ "info": { "id": "ses_oc1", "directory": "/work" }, "messages": messages }),
            ),
        )
        .unwrap();
        stub_opencode(dir, &format!("cat '{file}'"))
    }

    fn stub_opencode(dir: &Dir, script: &str) -> Env {
        let bin = dir.join("bin");
        fs::create_dir_all(&bin).unwrap();
        let program = format!("{bin}/opencode");
        crate::test_support::write_stub(
            std::path::Path::new(&program),
            &format!(
                "#!/bin/sh\nif [ \"$1\" = --version ]; then echo 1.19.5; exit 0; fi\n{script}"
            ),
        );
        Env::from_pairs([("PATH", format!("{bin}:/usr/bin:/bin"))])
    }

    fn oc_user(id: &str, text: &str) -> Value {
        json!({ "info": { "id": id, "role": "user", "time": { "created": 1 } }, "parts": [{ "type": "text", "text": text }] })
    }

    fn todowrite(id: &str, todos: Vec<Value>) -> Value {
        json!({
            "info": { "id": id, "role": "assistant", "time": { "created": 2 } },
            "parts": [{ "type": "tool", "tool": "todowrite", "callID": format!("call_{id}"), "state": { "status": "completed", "input": { "todos": todos } } }],
        })
    }

    #[test]
    fn counts_the_open_turns_list_cancelled_steps_leave_it() {
        let dir = Dir::new();
        let env = stub_export(
            &dir,
            json!([
                oc_user("msg_1", "plan it"),
                todowrite("msg_2", steps(&["completed", "in_progress", "cancelled"]))
            ]),
        );
        assert_eq!(
            dir.read("opencode", Some(id_session("ses_oc1")), &env),
            steps_of(1, 2)
        );
    }

    #[test]
    fn a_later_prompt_starts_a_turn_without_a_plan() {
        let dir = Dir::new();
        let env = stub_export(
            &dir,
            json!([
                oc_user("msg_1", "plan it"),
                todowrite("msg_2", steps(&["completed", "pending"])),
                oc_user("msg_3", "something else"),
            ]),
        );
        assert_eq!(
            dir.read("opencode", Some(id_session("ses_oc1")), &env),
            PlanProgress::None
        );
    }

    // MARK: everything else

    #[test]
    fn gemini_an_unknown_kind_or_no_session_have_no_steps() {
        let dir = Dir::new();
        let file = dir.write_lines("x.jsonl", &[json!({ "type": "user" })]);
        let env = Env::default();
        assert_eq!(
            dir.read("gemini", Some(path_session(&file)), &env),
            PlanProgress::None
        );
        assert_eq!(
            dir.read("cursor", Some(path_session(&file)), &env),
            PlanProgress::None
        );
        let none = read_plan_progress(&PlanArgs {
            agent: "omp",
            session: None,
            cwd: Some("/work"),
            pane_id: None,
            config_dir: None,
            terminal_id: None,
            env: &env,
            home: dir.str(),
            signal: None,
            timeout_ms: PLAN_READ_TIMEOUT_MS,
        });
        assert_eq!(none, PlanProgress::None);
    }

    #[test]
    fn a_missing_transcript_is_no_plan_an_abort_or_an_unreadable_one_is_plan_unreadable() {
        let dir = Dir::new();
        let env = Env::default();
        assert_eq!(
            dir.read("omp", Some(path_session(&dir.join("gone.jsonl"))), &env),
            PlanProgress::None
        );
        let records = omp_like(cat(vec![
            vec![omp_prompt("go")],
            todo("c1", "init", &steps(&["pending"])),
        ]));
        let session = path_session(&dir.write_lines("omp.jsonl", &records));
        let aborted = AbortSignal::new();
        aborted.abort("aborted");
        let result = read_plan_progress(&PlanArgs {
            agent: "omp",
            session: Some(&session),
            cwd: None,
            pane_id: None,
            config_dir: None,
            terminal_id: None,
            env: &env,
            home: dir.str(),
            signal: Some(&aborted),
            timeout_ms: PLAN_READ_TIMEOUT_MS,
        });
        assert_eq!(result, PlanProgress::Unreadable);
        // A session path naming a directory cannot be read.
        assert_eq!(
            dir.read("omp", Some(path_session(dir.str())), &env),
            PlanProgress::Unreadable
        );
    }

    #[test]
    fn a_failed_opencode_export_is_plan_unreadable_an_unknown_session_or_no_binary_is_no_plan() {
        let dir = Dir::new();
        let read = |env: &Env| dir.read("opencode", Some(id_session("ses_oc1")), env);

        let env = stub_opencode(&dir, "echo \"Error: database is locked\" >&2\nexit 1");
        assert_eq!(read(&env), PlanProgress::Unreadable);

        let env = stub_opencode(
            &dir,
            "echo \"Exporting session: ses_oc1\" >&2\necho \"Session not found: ses_oc1\" >&2\nexit 1",
        );
        assert_eq!(read(&env), PlanProgress::None);

        let nowhere = Env::from_pairs([("PATH", dir.join("nowhere"))]);
        assert_eq!(read(&nowhere), PlanProgress::None);
    }

    #[test]
    fn a_timed_out_opencode_export_is_killed() {
        let dir = Dir::new();
        let pid_file = dir.join("pid");
        let env = stub_opencode(&dir, &format!("echo $$ > '{pid_file}'\nexec sleep 30"));
        let session = id_session("ses_oc1");
        let result = read_plan_progress(&PlanArgs {
            agent: "opencode",
            session: Some(&session),
            cwd: None,
            pane_id: None,
            config_dir: None,
            terminal_id: None,
            env: &env,
            home: dir.str(),
            signal: None,
            timeout_ms: 500,
        });
        assert_eq!(result, PlanProgress::Unreadable);
        let pid: libc::pid_t = fs::read_to_string(&pid_file)
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        std::thread::sleep(Duration::from_millis(100));
        // SAFETY: signal 0 only probes whether the process exists.
        let gone = unsafe { libc::kill(pid, 0) } == -1
            && std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH);
        assert!(gone, "the export process {pid} still runs");
    }

    #[test]
    fn without_a_live_session_the_panes_chat_marker_locates_the_transcript() {
        let dir = Dir::new();
        let records = omp_like(cat(vec![
            vec![omp_prompt("go")],
            todo("c1", "init", &steps(&["completed", "pending"])),
        ]));
        let file = dir.write_lines("marked.jsonl", &records);
        let config_dir = dir.join("config");
        let marker = marker_path(&config_dir, "w1:p1");
        fs::create_dir_all(PathBuf::from(&marker).parent().unwrap()).unwrap();
        let write = |kind: &str| {
            fs::write(
                &marker,
                jsx::stringify(&json!({
                    "v": 1, "pane_id": "w1:p1", "terminal_id": null, "kind": kind, "cwd": "/work",
                    "session": { "kind": "path", "value": file },
                    "launched_at": "2026-10-01T12:00:00.000Z", "prompt": null,
                })),
            )
            .unwrap();
        };
        let env = Env::default();
        let read = || {
            read_plan_progress(&PlanArgs {
                agent: "omp",
                session: None,
                cwd: None,
                pane_id: Some("w1:p1"),
                config_dir: Some(&config_dir),
                terminal_id: None,
                env: &env,
                home: dir.str(),
                signal: None,
                timeout_ms: PLAN_READ_TIMEOUT_MS,
            })
        };
        write("omp");
        assert_eq!(read(), steps_of(1, 2));
        // A marker for another kind of Agent does not apply.
        write("claude");
        assert_eq!(read(), PlanProgress::None);
    }

    #[test]
    fn an_empty_plan_or_one_longer_than_99_steps_has_no_steps() {
        let dir = Dir::new();
        let empty = omp_like(vec![
            omp_prompt("go"),
            omp_call("c1", "todo", json!({ "op": "init" })),
            omp_result("c1", "todo", "", json!({ "op": "init", "phases": [] })),
        ]);
        assert_eq!(dir.progress_of("omp", &empty), PlanProgress::None);

        let long = codex_records(vec![CodexTurn {
            id: "t1",
            prompt: "go",
            plans: vec![steps(&vec!["pending"; 100])],
            complete: false,
        }]);
        assert_eq!(dir.progress_of("codex", &long), PlanProgress::None);
    }

    #[test]
    fn herdrs_agent_session_is_used_only_with_a_known_kind_and_a_value() {
        let some = |kind: &str, value: &str| {
            Some(SessionRef {
                kind: kind.into(),
                value: value.into(),
            })
        };
        assert_eq!(
            herdr_session_reference(&json!({ "kind": "path", "value": "/t.jsonl" })),
            some("path", "/t.jsonl")
        );
        assert_eq!(
            herdr_session_reference(&json!({ "kind": "id", "value": "abc" })),
            some("id", "abc")
        );
        assert_eq!(
            herdr_session_reference(&json!({ "kind": "url", "value": "x" })),
            None
        );
        assert_eq!(
            herdr_session_reference(&json!({ "kind": "id", "value": "" })),
            None
        );
        assert_eq!(herdr_session_reference(&Value::Null), None);
    }

    #[test]
    fn a_tmux_panes_session_absolute_waycar_session_is_a_path_else_an_id_else_the_transcript() {
        let some = |kind: &str, value: &str| {
            Some(SessionRef {
                kind: kind.into(),
                value: value.into(),
            })
        };
        assert_eq!(
            tmux_session_reference(Some("/s.jsonl"), Some("/t.jsonl")),
            some("path", "/s.jsonl")
        );
        assert_eq!(
            tmux_session_reference(Some("abc"), Some("/t.jsonl")),
            some("id", "abc")
        );
        assert_eq!(
            tmux_session_reference(None, Some("/t.jsonl")),
            some("path", "/t.jsonl")
        );
        assert_eq!(tmux_session_reference(None, None), None);
    }

    #[test]
    fn a_core_terminals_session_comes_from_its_waycar_labels_as_a_tmux_panes_does() {
        let labels = |pairs: &[(&str, &str)]| -> BTreeMap<String, String> {
            pairs
                .iter()
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect()
        };
        let some = |kind: &str, value: &str| {
            Some(SessionRef {
                kind: kind.into(),
                value: value.into(),
            })
        };
        assert_eq!(
            core_session_reference(&labels(&[
                ("waycar.session", "/s.jsonl"),
                ("waycar.transcript", "/t.jsonl"),
            ])),
            some("path", "/s.jsonl")
        );
        assert_eq!(
            core_session_reference(&labels(&[
                ("waycar.session", "abc"),
                ("waycar.transcript", "/t.jsonl"),
            ])),
            some("id", "abc")
        );
        assert_eq!(
            core_session_reference(&labels(&[("waycar.transcript", "/t.jsonl")])),
            some("path", "/t.jsonl")
        );
        // A cleared label is absent in core's record; labels of other tools say nothing.
        assert_eq!(
            core_session_reference(&labels(&[("waycar.kind", "claude"), ("herdr.space", "w")])),
            None
        );
        assert_eq!(core_session_reference(&BTreeMap::new()), None);
    }

    #[test]
    fn task_created_text_matches_the_regex() {
        assert_eq!(
            task_id_from_text("Task #7 created successfully"),
            Some("7".into())
        );
        assert_eq!(task_id_from_text("xTask #7 created"), None);
        assert_eq!(task_id_from_text("Task #7 createdx"), None);
        assert_eq!(task_id_from_text("Task #a:b created"), None);
        assert_eq!(
            task_id_from_text("Task # created Task #3 created"),
            Some("3".into())
        );
    }
}
