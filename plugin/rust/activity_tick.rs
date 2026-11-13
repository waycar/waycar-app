//! Plan-step tick for the Live Activity (docs/agents/live-activity-contract.md,
//! "Plan-step tick"; activity-tick.js).
//!
//! The activity hook runs only on status events, so between them nothing would
//! carry an Agent's plan-step progress to a pocketed phone. While an episode is
//! live, AI summaries are on and an Agent is Working, the hook keeps this
//! detached process alive ([`start_tick`]). Every [`TICK_INTERVAL_MS`] it:
//!
//! ```text
//! summaries on? episode live? ──> herdr + tmux + core Working Agents (none: exit)
//!   ──> read the plan per Agent (its own transcript; no model call)
//!       could not read: leave everything as it is
//!   ──> write_progress into the summary store (a Working record with text)
//!       and the tick's own plan-step map (activity_plan_steps)
//!   ──> a visible estimate differs from the last push: run_progress_update
//!       (same send flow, priority 5)
//! ```
//!
//! It exits when no Agent is Working, the episode ended, summaries were
//! switched off, or after [`TICK_MAX_RUN_MS`]. One instance per state dir:
//! `activity/tick.lock` names its holder and carries a heartbeat `ts`; a lock
//! whose holder is gone or whose heartbeat is older than [`TICK_LOCK_STALE_MS`]
//! is stolen, like refresh-summaries.js's.
//!
//! # The detached process
//!
//! [`start_tick`] runs the current executable as `waycar activity-tick
//! '<options>'` (no stdio, its own session through `setsid`, the environment
//! the hook gave it), where `<options>` is `JSON.stringify` of
//! `{configDir, stateDir, herdrBin, herdrRequired}` (the JS passed the same
//! object to `node activity-tick.js`). The `waycar activity-tick` subcommand is
//! hidden; it calls [`run_activity_tick_main`] with that one argument and exits
//! with the returned code.
//!
//! # The plan reader
//!
//! The tick asks a [`PlanReader`] for each Working Agent's plan steps; the
//! production one is [`TranscriptPlanReader`] (`readPlanProgress`,
//! [`crate::plan_progress`]). When it answers [`PlanProgress::Unreadable`] the
//! tick leaves the store and the plan-step map as they are and still pushes an
//! estimate the summary refresh stored.

use std::collections::HashMap;
use std::fs::{self, DirBuilder, OpenOptions};
use std::io::{ErrorKind, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, UNIX_EPOCH};

use serde_json::{Value, json};

use crate::activity_hook::{
    ActivityDeps, ActivityOutcome, ProgressRequest, TickStart, list_agents, process_alive,
    read_last_state,
};
use crate::activity_plan_steps::{read_plan_steps, remove_plan_steps, update_plan_steps};
use crate::activity_state::progress_for_status;
use crate::atomic::write_atomic;
use crate::core::{CoreCommand, CoreTerminal, is_core_pane_id, running_core};
use crate::deps::{Clock, SystemClock};
use crate::display_text::optional_text;
use crate::env::Env;
use crate::error::{CliError, EXIT_FAILURE, EXIT_OK, Result};
use crate::herdr::HerdrCommand;
use crate::js_compat::{js_get, js_get_opt, js_strict_eq, non_null};
use crate::jsx;
use crate::notification_config::{NotificationConfig, read_notification_config};
use crate::paths::home_dir;
use crate::plan_progress::{
    PLAN_READ_TIMEOUT_MS, PlanArgs, PlanProgress, SessionRef, core_session_reference,
    herdr_session_reference, read_plan_progress, tmux_session_reference,
};
use crate::summary::store::{ProgressWrite, read_summary, write_progress};
use crate::tmux::{Runner, is_tmux_pane_id, list_agents_with};

pub const TICK_INTERVAL_MS: u64 = 150_000;
pub const TICK_MAX_RUN_MS: u64 = 2 * 60 * 60 * 1000;
pub const TICK_LOCK_NAME: &str = "tick.lock";
/// A live tick rewrites its lock's `ts` before each wait, before each plan read
/// and around each push, so a heartbeat older than two intervals plus a read
/// cannot be live: it is stolen even if its pid was reused.
pub const TICK_LOCK_STALE_MS: u64 = 2 * TICK_INTERVAL_MS + PLAN_READ_TIMEOUT_MS;
/// A takeover guard left by a crashed stealer is cleared after this.
const STEAL_GUARD_STALE_MS: u64 = 10_000;
/// The hidden subcommand [`start_tick`] runs the current executable as.
pub const TICK_SUBCOMMAND: &str = "activity-tick";

// ---- the single-instance lock ----------------------------------------------

fn tick_lock_path(state_dir: &Path) -> PathBuf {
    state_dir.join("activity").join(TICK_LOCK_NAME)
}

fn read_lock(path: &Path) -> Option<Value> {
    let bytes = fs::read(path).ok()?;
    crate::hook_session::parse_hook_input(&String::from_utf8_lossy(&bytes))
}

/// How long ago `path` was modified, in milliseconds (0 when it cannot be
/// read).
fn age_of(path: &Path, now_ms: u64) -> f64 {
    let Ok(modified) = fs::metadata(path).and_then(|meta| meta.modified()) else {
        return 0.0;
    };
    let modified_ms = modified
        .duration_since(UNIX_EPOCH)
        .map_or(0.0, |elapsed| elapsed.as_secs_f64() * 1000.0);
    now_ms as f64 - modified_ms
}

fn lock_line(now_ms: u64) -> String {
    format!(
        "{}\n",
        jsx::stringify(&json!({ "pid": std::process::id(), "ts": now_ms }))
    )
}

fn try_create_lock(path: &Path, now_ms: u64) -> std::io::Result<bool> {
    match OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
    {
        Ok(mut file) => {
            file.write_all(lock_line(now_ms).as_bytes())?;
            Ok(true)
        }
        Err(error) if error.kind() == ErrorKind::AlreadyExists => Ok(false),
        Err(error) => Err(error),
    }
}

/// `Number.isInteger(value)` for a lock field; its value as a double.
fn integer_field(lock: Option<&Value>, name: &str) -> Option<f64> {
    crate::js_compat::js_integer(js_get_opt(lock, name))
}

/// A holder is stale when its pid is dead or its heartbeat is older than
/// [`TICK_LOCK_STALE_MS`] (a crashed tick whose pid was reused after a reboot).
fn is_stale(path: &Path, now_ms: u64) -> bool {
    let holder = read_lock(path);
    let (Some(pid), Some(ts)) = (
        integer_field(holder.as_ref(), "pid"),
        integer_field(holder.as_ref(), "ts"),
    ) else {
        // Possibly mid-write by its creator: only an old unreadable lock is
        // stale.
        return age_of(path, now_ms) >= TICK_LOCK_STALE_MS as f64;
    };
    now_ms as f64 - ts >= TICK_LOCK_STALE_MS as f64 || !process_alive(pid as i64)
}

/// Whether a live tick holds the lock for `state_dir`.
pub fn tick_running(state_dir: &Path, now_ms: u64) -> bool {
    let path = tick_lock_path(state_dir);
    fs::metadata(&path).is_ok() && !is_stale(&path, now_ms)
}

/// Take the single-instance lock, stealing a stale one. Returns false while
/// another live tick holds it. Takeovers are serialized by an `O_EXCL` guard
/// file, and staleness is re-checked under it, so two stealers cannot both win.
pub fn acquire_tick_lock(state_dir: &Path, now_ms: u64) -> Result<bool> {
    DirBuilder::new()
        .recursive(true)
        .create(state_dir.join("activity"))?;
    let path = tick_lock_path(state_dir);
    if try_create_lock(&path, now_ms)? {
        return Ok(true);
    }
    if !is_stale(&path, now_ms) {
        return Ok(false);
    }
    let mut guard_name = path.as_os_str().to_owned();
    guard_name.push(".steal");
    let guard = PathBuf::from(guard_name);
    if age_of(&guard, now_ms) >= STEAL_GUARD_STALE_MS as f64 {
        let _ = fs::remove_file(&guard);
    }
    match OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&guard)
    {
        Ok(_) => {}
        Err(error) if error.kind() == ErrorKind::AlreadyExists => return Ok(false),
        Err(error) => return Err(error.into()),
    }
    let taken = (|| -> Result<bool> {
        if !is_stale(&path, now_ms) {
            return Ok(false);
        }
        let _ = fs::remove_file(&path);
        Ok(try_create_lock(&path, now_ms)?)
    })();
    let _ = fs::remove_file(&guard);
    taken
}

fn holds_lock(path: &Path) -> bool {
    let holder = read_lock(path);
    js_strict_eq(
        js_get_opt(holder.as_ref(), "pid"),
        Some(&json!(std::process::id())),
    )
}

/// Remove the lock only while it is still ours.
pub fn release_tick_lock(state_dir: &Path) {
    let path = tick_lock_path(state_dir);
    if holds_lock(&path) {
        let _ = fs::remove_file(&path);
    }
}

/// Rewrite our lock's `ts` (the liveness heartbeat). Returns false when the
/// lock is no longer ours: another tick judged it stale and took it.
pub fn heartbeat_tick_lock(state_dir: &Path, now_ms: u64) -> Result<bool> {
    let path = tick_lock_path(state_dir);
    if !holds_lock(&path) {
        return Ok(false);
    }
    write_atomic(&path, lock_line(now_ms).as_bytes(), 0o600)?;
    Ok(true)
}

// ---- starting the detached tick --------------------------------------------

/// What spawns the detached tick: its argv after the program, and the
/// environment it runs with.
#[derive(Debug, Clone, Copy)]
pub struct TickLaunch<'a> {
    pub argv: &'a [String],
    pub env: &'a Env,
}

/// Spawn the detached tick unless a live one holds the lock, through `spawn`
/// (see [`spawn_detached`]). Two racing callers may both spawn; the loser
/// fails the lock and exits at once. Returns whether a tick was spawned.
pub fn ensure_activity_tick(
    start: &TickStart<'_>,
    now_ms: u64,
    spawn: &dyn Fn(&TickLaunch<'_>),
) -> bool {
    if tick_running(start.state_dir, now_ms) {
        return false;
    }
    let options = json!({
        "configDir": start.config_dir.to_string_lossy(),
        "stateDir": start.state_dir.to_string_lossy(),
        "herdrBin": start.herdr_bin,
        "herdrRequired": start.herdr_required,
    });
    let argv = [TICK_SUBCOMMAND.to_string(), jsx::stringify(&options)];
    spawn(&TickLaunch {
        argv: &argv,
        env: start.env,
    });
    true
}

/// Run the current executable detached: no stdio, a session of its own. A
/// failed spawn only means no progress until the next status event.
pub fn spawn_detached(launch: &TickLaunch<'_>) {
    let Ok(program) = std::env::current_exe() else {
        return;
    };
    let mut command = Command::new(program);
    command
        .args(launch.argv)
        .env_clear()
        .envs(launch.env.iter())
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    // SAFETY: setsid is async-signal-safe, the only call between fork and exec.
    unsafe {
        command.pre_exec(|| {
            if libc::setsid() == -1 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let _ = command.spawn();
}

/// The production `start_tick` of the hook's entry points.
pub fn start_tick(start: &TickStart<'_>) {
    ensure_activity_tick(start, SystemClock.now_ms(), &spawn_detached);
}

// ---- the plan seam ---------------------------------------------------------

/// What one Agent's plan read is asked (`readPlanProgress`'s options).
#[derive(Debug, Clone, Copy)]
pub struct PlanRequest<'a> {
    /// The Agent's kind (claude, codex, omp, …).
    pub agent: &'a str,
    pub session: Option<&'a SessionRef>,
    pub cwd: Option<&'a str>,
    pub pane_id: &'a str,
    pub config_dir: &'a Path,
    /// herdr's terminal id.
    pub terminal_id: Option<&'a str>,
    pub env: &'a Env,
    /// The tick run's own end (epoch milliseconds): a read stops there, on top
    /// of its own `timeout`.
    pub deadline_ms: u64,
    pub timeout: Duration,
}

/// Where a Working Agent's plan is read (`readPlanProgress`); a test passes
/// a scripted one.
pub trait PlanReader {
    fn read_plan(&self, request: &PlanRequest<'_>) -> PlanProgress;
}

/// The production reader: `readPlanProgress` (plan-progress.js) on this Host's
/// transcripts.
pub struct TranscriptPlanReader;

impl PlanReader for TranscriptPlanReader {
    fn read_plan(&self, request: &PlanRequest<'_>) -> PlanProgress {
        let Some(home) = home_dir(request.env) else {
            return PlanProgress::Unreadable;
        };
        // The read stops at the run's own end as well as at its own timeout.
        let left_ms = request.deadline_ms.saturating_sub(SystemClock.now_ms());
        let timeout_ms = u64::try_from(request.timeout.as_millis())
            .unwrap_or(u64::MAX)
            .min(left_ms);
        let config_dir = request.config_dir.to_string_lossy();
        read_plan_progress(&PlanArgs {
            agent: request.agent,
            session: request.session,
            cwd: request.cwd,
            pane_id: Some(request.pane_id),
            config_dir: Some(&config_dir),
            terminal_id: request.terminal_id,
            env: request.env,
            home: &home.to_string_lossy(),
            signal: None,
            timeout_ms,
        })
    }
}

// ---- the tick --------------------------------------------------------------

/// Why a tick loop stopped.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TickStop {
    /// Another tick runs or took over.
    Locked,
    Disabled,
    Ended,
    Idle,
    Expired,
}

impl TickStop {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Locked => "locked",
            Self::Disabled => "disabled",
            Self::Ended => "ended",
            Self::Idle => "idle",
            Self::Expired => "expired",
        }
    }
}

/// What the tick loop reads and writes, and the seams around it.
#[derive(Clone, Copy)]
pub struct TickDeps<'a> {
    pub activity: ActivityDeps<'a>,
    pub plan: &'a dyn PlanReader,
    /// [`run_progress_update`](crate::activity_hook::run_progress_update) in
    /// production.
    pub send_update: &'a dyn Fn(&ProgressRequest<'_>, &ActivityDeps<'_>) -> Result<bool>,
}

/// The Host the tick watches.
#[derive(Debug, Clone, Copy)]
pub struct TickHost<'a> {
    pub config_dir: &'a Path,
    pub state_dir: &'a Path,
    pub herdr: &'a HerdrCommand,
    pub herdr_required: bool,
    /// The environment for tmux.
    pub env: &'a Env,
}

struct WorkingAgent {
    pane_id: String,
    kind: String,
    session: Option<SessionRef>,
    cwd: Option<String>,
    terminal_id: Option<String>,
}

/// The tick's view of the Host: `working` lists Working Agents in the plan
/// reader's terms; `statuses` maps every listed pane to its status;
/// `herdr_listed`/`tmux_listed`/`core_listed` say which backends answered, so
/// only their panes' absence means anything.
struct HostView {
    working: Vec<WorkingAgent>,
    statuses: HashMap<String, Option<String>>,
    herdr_listed: bool,
    tmux_listed: bool,
    core_listed: bool,
}

/// tmux's answers when no server is running (no socket, or a dead one).
fn is_tmux_no_server(message: &str) -> bool {
    let lowered = message.to_lowercase();
    lowered.contains("no server running") || lowered.contains("error connecting to")
}

/// herdr's Agents (when herdr answers; under the herdr trigger a failed list
/// is an error), tmux's unless tmux is off, and a running core's unless core
/// is off.
fn list_host(
    host: &TickHost<'_>,
    config: &NotificationConfig,
    deps: &TickDeps<'_>,
) -> Result<HostView> {
    let run = deps.activity.run;
    let mut view = HostView {
        working: Vec::new(),
        statuses: HashMap::new(),
        herdr_listed: false,
        tmux_listed: false,
        core_listed: false,
    };
    let herdr_rows = match list_agents(&|args| run(&host.herdr.bin, args, &host.herdr.env)) {
        Ok(rows) => Some(rows),
        Err(error) if host.herdr_required => return Err(error),
        Err(_) => None,
    };
    view.herdr_listed = herdr_rows.is_some();
    for row in herdr_rows.iter().flatten() {
        let Some(pane_id) = js_get(row, "pane_id").and_then(Value::as_str) else {
            continue;
        };
        let status = js_get(row, "agent_status")
            .and_then(Value::as_str)
            .map(str::to_lowercase);
        let kind = optional_text(js_get(row, "agent"));
        let working = status.as_deref() == Some("working");
        view.statuses.insert(pane_id.to_string(), status);
        let Some(kind) = kind.filter(|_| working) else {
            continue;
        };
        view.working.push(WorkingAgent {
            pane_id: pane_id.to_string(),
            kind: kind.to_string(),
            session: js_get(row, "agent_session").and_then(herdr_session_reference),
            cwd: optional_text(js_get(row, "cwd")).map(str::to_string),
            terminal_id: optional_text(js_get(row, "terminal_id")).map(str::to_string),
        });
    }
    if config.tmux_enabled {
        list_tmux(&mut view, host, run);
    }
    if let Some(core) = running_core_of(host, config, run) {
        list_core(&mut view, &core, run);
    }
    Ok(view)
}

fn list_tmux(view: &mut HostView, host: &TickHost<'_>, run: Runner<'_>) {
    // No server means no tmux panes at all; any other failure says nothing
    // about them, so their steps must not be pruned.
    let rows = match list_agents_with(run, host.env) {
        Ok(rows) => {
            view.tmux_listed = true;
            rows
        }
        Err(error) => {
            view.tmux_listed = is_tmux_no_server(error.message());
            Vec::new()
        }
    };
    for row in rows {
        let working = row.status == Some("working");
        let session = tmux_session_reference(row.session.as_deref(), row.transcript.as_deref());
        let kind = row.agent.clone().filter(|agent| !agent.is_empty());
        view.statuses
            .insert(row.pane_id.clone(), row.status.map(String::from));
        let Some(kind) = kind.filter(|_| working) else {
            continue;
        };
        view.working.push(WorkingAgent {
            pane_id: row.pane_id,
            kind,
            session,
            cwd: row.cwd.filter(|cwd| !cwd.is_empty()),
            terminal_id: None,
        });
    }
}

/// herdr-core, when the Host has core on and a core already runs (this never
/// starts one).
fn running_core_of(
    host: &TickHost<'_>,
    config: &NotificationConfig,
    run: Runner<'_>,
) -> Option<CoreCommand> {
    if !config.core_enabled {
        return None;
    }
    running_core(host.env, &home_dir(host.env)?, run)
}

/// core's live terminals, by `hc:<address>`. A core that cannot list says
/// nothing about its panes (`core_listed` stays false). A Working terminal's
/// kind, folder and transcript session come from its full record (`ls` has
/// none of its labels); the record's own status is the fresher one, and a
/// terminal that vanished or is no longer live is not Working.
fn list_core(view: &mut HostView, core: &CoreCommand, run: Runner<'_>) {
    let Ok(listings) = crate::core::list(core, run) else {
        return;
    };
    view.core_listed = true;
    for listing in listings.iter().filter(|listing| listing.state == "live") {
        let pane_id = listing.pane_id();
        let mut status = listing.waycar_status();
        if status != Some("working") {
            view.statuses.insert(pane_id, status.map(String::from));
            continue;
        }
        let record = match crate::core::get(core, run, &listing.address) {
            Ok(Some(record)) if record.is_live() => Some(record),
            Ok(_) => continue,
            Err(_) => None,
        };
        if let Some(record) = &record {
            status = record.waycar_status();
        }
        view.statuses
            .insert(pane_id.clone(), status.map(String::from));
        let kind = record
            .as_ref()
            .and_then(CoreTerminal::kind)
            .or(listing.agent.as_deref());
        let Some(kind) = kind.filter(|_| status == Some("working")) else {
            continue;
        };
        view.working.push(WorkingAgent {
            pane_id,
            kind: kind.to_string(),
            session: record
                .as_ref()
                .and_then(|record| core_session_reference(&record.labels)),
            cwd: record
                .as_ref()
                .and_then(CoreTerminal::folder)
                .or(listing.cwd.as_deref())
                .map(str::to_string),
            terminal_id: None,
        });
    }
}

/// `Object.keys(value).length` of a stored map.
fn key_count(value: Option<&Value>) -> usize {
    match value {
        Some(Value::Object(map)) => map.len(),
        Some(Value::Array(items)) => items.len(),
        Some(Value::String(text)) => jsx::utf16_len(text),
        _ => 0,
    }
}

fn progress_request<'a>(host: &'a TickHost<'a>) -> ProgressRequest<'a> {
    ProgressRequest {
        config_dir: host.config_dir,
        state_dir: host.state_dir,
        herdr: host.herdr,
        herdr_required: host.herdr_required,
        env: host.env,
    }
}

/// Summaries were switched off: progress must leave the Live Activity, not sit
/// frozen on a pocketed phone. Drops the tick's steps and, when the last push
/// showed any progress, sends one update through the normal flow, which now
/// builds no progress (priority 5; a status change is left to the hooks).
fn clear_shown_progress(host: &TickHost<'_>, deps: &TickDeps<'_>) -> Result<()> {
    remove_plan_steps(host.state_dir)?;
    let Some(last_state) = read_last_state(host.state_dir) else {
        return Ok(());
    };
    if js_get(&last_state, "ended") == Some(&Value::Bool(true))
        || key_count(non_null(js_get(&last_state, "progress"))) == 0
    {
        return Ok(());
    }
    // The next status event pushes without progress anyway.
    let _ = (deps.send_update)(&progress_request(host), &deps.activity);
    Ok(())
}

/// One tick. Returns why the tick should stop, or `None` to keep going. Never
/// calls a summary model: progress comes from the Agents' own plans. `beat`
/// refreshes the lock and returns false once another tick took it.
fn tick_once(
    host: &TickHost<'_>,
    deps: &TickDeps<'_>,
    deadline_ms: u64,
    beat: &dyn Fn() -> Result<bool>,
) -> Result<Option<TickStop>> {
    let clock = deps.activity.clock;
    let config =
        read_notification_config(&host.config_dir.to_string_lossy()).map_err(CliError::failure)?;
    if !config.summary_enabled {
        clear_shown_progress(host, deps)?;
        return Ok(Some(TickStop::Disabled));
    }
    let last_state = match read_last_state(host.state_dir) {
        Some(state) if js_get(&state, "ended") != Some(&Value::Bool(true)) => state,
        _ => return Ok(Some(TickStop::Ended)),
    };
    let view = list_host(host, &config, deps)?;
    // Steps outlive a pane only while it is Working or Blocked (frozen); a pane
    // its backend no longer lists, or whose turn ended, loses them. A backend
    // that did not answer says nothing about its panes.
    update_plan_steps(host.state_dir, |map| {
        map.retain(|pane, _| {
            let listed = if is_tmux_pane_id(pane) {
                view.tmux_listed
            } else if is_core_pane_id(pane) {
                view.core_listed
            } else {
                view.herdr_listed
            };
            let kept = matches!(
                view.statuses.get(pane).and_then(Option::as_deref),
                Some("working" | "blocked")
            );
            !listed || kept
        });
    })?;
    if view.working.is_empty() {
        return Ok(Some(TickStop::Idle));
    }
    for agent in &view.working {
        if !beat()? {
            return Ok(Some(TickStop::Locked));
        }
        let read = deps.plan.read_plan(&PlanRequest {
            agent: &agent.kind,
            session: agent.session.as_ref(),
            cwd: agent.cwd.as_deref(),
            pane_id: &agent.pane_id,
            config_dir: host.config_dir,
            terminal_id: agent.terminal_id.as_deref(),
            env: host.env,
            deadline_ms,
            timeout: Duration::from_millis(PLAN_READ_TIMEOUT_MS),
        });
        // Could not read (timeout, error): keep what is stored and shown.
        let steps = match read {
            PlanProgress::Unreadable => continue,
            PlanProgress::Steps(steps) => Some(steps),
            PlanProgress::None => None,
        };
        // Steps only: the stored phase stays, and a record written in another
        // status (or none) is left alone; the tick's own map covers that case.
        let progress = steps.map_or_else(
            || json!({}),
            |steps| json!({ "done": steps.done, "total": steps.total }),
        );
        write_progress(
            &host.config_dir.to_string_lossy(),
            &ProgressWrite {
                pane_id: &agent.pane_id,
                status: "working",
                progress: &progress,
                ts: clock.now_ms() as i64,
            },
        )?;
        update_plan_steps(host.state_dir, |map| match steps {
            None => {
                map.shift_remove(&agent.pane_id);
            }
            Some(steps) => {
                map.insert(
                    agent.pane_id.clone(),
                    json!({ "done": steps.done, "total": steps.total }),
                );
            }
        })?;
    }
    if !beat()? {
        return Ok(Some(TickStop::Locked));
    }
    // Push when a visible Working Agent's estimate differs from the last push:
    // this tick's steps, or an estimate the summary refresh wrote.
    let visible = js_get(&last_state, "visible").and_then(Value::as_array);
    let plan_steps = read_plan_steps(host.state_dir);
    let changed = view.working.iter().any(|agent| {
        if visible.is_some_and(|visible| {
            !visible
                .iter()
                .any(|pane| pane.as_str() == Some(agent.pane_id.as_str()))
        }) {
            return false;
        }
        let shown = progress_for_status(
            read_summary(&host.config_dir.to_string_lossy(), &agent.pane_id).as_ref(),
            "working",
            plan_steps.get(&agent.pane_id),
        )
        .map_or(Value::Null, |progress| progress.wire_json());
        let pushed = non_null(js_get_opt(js_get(&last_state, "progress"), &agent.pane_id))
            .map_or(Value::Null, Value::clone);
        jsx::stringify(&shown) != jsx::stringify(&pushed)
    });
    if changed {
        // A relay failure leaves last-state behind the store, so the next tick
        // tries again.
        let _ = (deps.send_update)(&progress_request(host), &deps.activity);
        if !beat()? {
            return Ok(Some(TickStop::Locked));
        }
    }
    Ok(None)
}

/// The tick loop. Returns why it stopped: [`TickStop::Locked`] (another tick
/// runs or took over), `Disabled`, `Ended`, `Idle`, or `Expired`.
pub fn run_activity_tick(host: &TickHost<'_>, deps: &TickDeps<'_>) -> Result<TickStop> {
    let clock = deps.activity.clock;
    if !acquire_tick_lock(host.state_dir, clock.now_ms())? {
        return Ok(TickStop::Locked);
    }
    let beat = || heartbeat_tick_lock(host.state_dir, clock.now_ms());
    let stop = (|| -> Result<TickStop> {
        // Plan reads stop at the run's end, on top of their own per-read
        // timeout.
        let deadline = clock.now_ms() + TICK_MAX_RUN_MS;
        loop {
            if !beat()? {
                return Ok(TickStop::Locked);
            }
            clock.sleep(Duration::from_millis(TICK_INTERVAL_MS));
            if clock.now_ms() >= deadline {
                return Ok(TickStop::Expired);
            }
            if let Some(stop) = tick_once(host, deps, deadline, &beat)? {
                return Ok(stop);
            }
        }
    })();
    release_tick_lock(host.state_dir);
    stop
}

/// The detached entry point (`waycar activity-tick '<options>'`; the JS
/// `main`): `options` is the JSON [`start_tick`] passed, `env` the process's
/// own environment (herdr's and tmux's). A failure is `activity-tick:
/// <message>` and exit 1.
pub fn run_activity_tick_main(
    options: Option<&str>,
    env: &Env,
    deps: &TickDeps<'_>,
) -> ActivityOutcome {
    let result = (|| -> Result<TickStop> {
        let parsed: Value = serde_json::from_str(options.unwrap_or("null"))
            .map_err(|error| CliError::failure(error.to_string()))?;
        let text = |key: &str| {
            js_get(&parsed, key)
                .and_then(Value::as_str)
                .filter(|text| !text.is_empty())
                .ok_or_else(|| CliError::failure(format!("{key} missing")))
        };
        let (config_dir, state_dir, herdr_bin) =
            (text("configDir")?, text("stateDir")?, text("herdrBin")?);
        let herdr = HerdrCommand {
            bin: herdr_bin.to_string(),
            env: env.clone(),
        };
        run_activity_tick(
            &TickHost {
                config_dir: Path::new(config_dir),
                state_dir: Path::new(state_dir),
                herdr: &herdr,
                herdr_required: js_get(&parsed, "herdrRequired") == Some(&Value::Bool(true)),
                env,
            },
            deps,
        )
    })();
    match result {
        Ok(_) => ActivityOutcome {
            code: EXIT_OK,
            stderr: String::new(),
        },
        Err(error) => ActivityOutcome {
            code: EXIT_FAILURE,
            stderr: format!("activity-tick: {}\n", error.message()),
        },
    }
}

#[cfg(test)]
#[path = "activity_tick_tests.rs"]
mod tests;
