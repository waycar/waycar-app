//! `waycar summaries refresh` and the herdr action `refresh-summaries`
//! (refresh-summaries.js; see README.md, "Agent Summary").
//!
//! The app invokes it about once a minute while it is open
//! (`herdr plugin action invoke refresh-summaries --plugin waycar`, which
//! returns as soon as this process starts, or `waycar summaries refresh` on a
//! tmux Host). One run:
//!
//! ```text
//! summary_enabled? -> single-flight lock + 10 s min interval
//!   -> `herdr agent list` + tmux Agents -> per Agent: (Working) its plan
//!      steps from its transcript (plan_progress), read screen, sha256
//!   -> same hash as its stored entry? store the steps only : summarize (3 at once)
//!   -> write the store entry {status, summary, ts, hash, progress}
//! ```
//!
//! An Agent whose screen has not changed since its last summary costs no
//! model call, so Idle, Done, and Blocked Agents sitting still are free. Plan
//! steps are compared on their own: the hash masks digits, so a step ticking
//! from 3/7 to 4/7 alone would otherwise go unseen. A plan that could not be
//! read ([`PlanProgress::Unreadable`]) changes nothing stored.
//!
//! The lock (`refresh-summaries.lock`), the last-run record
//! (`refresh-summaries-last.json`) and the store are shared with the Node
//! implementation and byte-identical in format.
//!
//! # Differences from the JS
//!
//! * The JS entry point (`node src/refresh-summaries.js` run by herdr, which
//!   needed `HERDR_PLUGIN_CONFIG_DIR`, `HERDR_PLUGIN_STATE_DIR` and
//!   `HERDR_BIN_PATH`, failed the run when `agent list` failed and printed
//!   `refresh-summaries: <message>`) is gone: the herdr action runs
//!   `waycar summaries refresh`, which is `refreshHostSummaries` (the
//!   injected directories win inside a hook; a missing or stopped herdr is
//!   no herdr Agents).
//! * `herdr agent list` and the tmux listing run with `exec::run_program`
//!   semantics (no shell, the environment's `PATH`) and no timeout beyond a
//!   year, like the JS `spawnRun`.
//! * Errors from the store and lock files carry the message of the Rust I/O
//!   error mapped to Node's `CODE: text, syscall 'path'` form where the
//!   syscall is known (`open`, `mkdir`); a store write failure names the
//!   summaries directory.

use std::fs::{self, DirBuilder, OpenOptions};
use std::io::Write;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::path::Path;
use std::sync::Mutex;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{Map, Value};

use crate::atomic::write_atomic;
use crate::chat::shared::ChatError;
use crate::core::{CoreCommand, get as core_get, list as core_list, running_core};
use crate::env::Env;
use crate::exec::run_program_with_timeout;
use crate::herdr::{herdr_command, run_herdr};
use crate::jspath;
use crate::jsx;
use crate::native::Io;
use crate::notification_config::read_notification_config;
use crate::paths::{home_dir, resolve_host_config};
use crate::plan_progress::{
    PLAN_READ_TIMEOUT_MS, PlanArgs, PlanProgress, SessionRef, herdr_session_reference,
    read_plan_progress, tmux_session_reference,
};
use crate::summary::agent::{
    Fetch, HttpFetch, SummarizeOptions, linked_signal, read_screen, screen_hash, summarize_screen,
};
use crate::summary::store::{
    ProgressWrite, SUMMARY_MAX_AGE_MS, SummaryWrite, normalize_progress, prune_summaries,
    read_summary, remove_summaries, write_progress, write_summary,
};
use crate::tmux::{self, Runner};

pub const LOCK_NAME: &str = "refresh-summaries.lock";
pub const LAST_RUN_NAME: &str = "refresh-summaries-last.json";
/// One run stops starting and aborts in-flight summaries at this deadline.
pub const RUN_DEADLINE_MS: u64 = 180_000;
/// A lock older than this cannot belong to a live run (it outlives the run
/// deadline with margin): it is stolen even if its pid was reused.
pub const LOCK_STALE_MS: f64 = (RUN_DEADLINE_MS + 60_000) as f64;
/// A takeover guard left by a crashed stealer is cleared after this.
const STEAL_GUARD_STALE_MS: f64 = 10_000.0;
/// Several devices (and each device's ticks) share one Host: runs closer
/// together than this are dropped. The lock and the per-Agent hash skip keep
/// the cost of a quick follow-up refresh low.
pub const MIN_INTERVAL_MS: i64 = 10_000;
pub const CONCURRENCY: usize = 3;

const SUMMARIZED_STATUSES: [&str; 4] = ["working", "idle", "done", "blocked"];

/// What a refresh did: `{ran: false, reason}` or
/// `{ran: true, agents, summarized, skipped}`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    NotRan(&'static str),
    Ran {
        agents: usize,
        summarized: usize,
        skipped: usize,
    },
}

impl Outcome {
    /// `JSON.stringify(outcome)`.
    pub fn to_json(&self) -> String {
        match self {
            Self::NotRan(reason) => format!("{{\"ran\":false,\"reason\":\"{reason}\"}}"),
            Self::Ran {
                agents,
                summarized,
                skipped,
            } => format!(
                "{{\"ran\":true,\"agents\":{agents},\"summarized\":{summarized},\"skipped\":{skipped}}}"
            ),
        }
    }
}

/// The current time in epoch milliseconds (`Date.now()`).
pub fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_millis()).unwrap_or(i64::MAX))
}

fn io_failure(error: &std::io::Error, syscall: &str, path: &str) -> String {
    ChatError::io(error, syscall, path).message
}

// MARK: - The single-flight lock

/// `process.kill(pid, 0)`: alive unless the pid does not exist. A pid that is
/// no int32 makes Node throw a TypeError, which reads as dead.
fn is_alive(pid: f64) -> bool {
    if pid != f64::from(pid as i32) {
        return false;
    }
    // SAFETY: signal 0 only checks that the process exists.
    let result = unsafe { libc::kill(pid as i32 as libc::pid_t, 0) };
    result == 0 || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

/// `tryCreateLock`: false when the lock exists.
fn try_create_lock(path: &str, now: i64) -> Result<bool, String> {
    let mut file = match OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
    {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => return Ok(false),
        Err(error) => return Err(io_failure(&error, "open", path)),
    };
    let body = format!("{{\"pid\":{},\"ts\":{}}}\n", std::process::id(), now);
    file.write_all(body.as_bytes())
        .map_err(|error| io_failure(&error, "write", path))?;
    Ok(true)
}

fn read_lock(path: &str) -> Value {
    fs::read(path)
        .ok()
        .and_then(|bytes| jsx::parse_json(&String::from_utf8_lossy(&bytes)))
        .unwrap_or(Value::Null)
}

/// `now - statSync(path).mtimeMs`; 0 when the file cannot be read.
fn age_of(path: &str, now: i64) -> f64 {
    match fs::metadata(path) {
        Ok(meta) => now as f64 - (meta.mtime() as f64 * 1000.0 + meta.mtime_nsec() as f64 / 1e6),
        Err(_) => 0.0,
    }
}

/// A holder is stale when its pid is dead or it outlived any real run.
fn is_stale(path: &str, now: i64) -> bool {
    let holder = read_lock(path);
    let (pid, ts) = (jsx::field(&holder, "pid"), jsx::field(&holder, "ts"));
    if !jsx::is_integer(pid) || !jsx::is_integer(ts) {
        // Possibly mid-write by its creator: only an old unreadable lock is stale.
        return age_of(path, now) >= LOCK_STALE_MS;
    }
    let number = |value: &Value| value.as_f64().unwrap_or(f64::NAN);
    now as f64 - number(ts) >= LOCK_STALE_MS || !is_alive(number(pid))
}

/// `rmSync(path, {force: true})`.
fn remove_force(path: &str) -> Result<(), String> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(io_failure(&error, "rm", path)),
    }
}

/// Take the single-flight lock, stealing one whose holder pid is dead or that
/// is older than [`LOCK_STALE_MS`]. Returns false while another live run
/// holds it. Takeovers are serialized by an O_EXCL guard file, and staleness
/// is re-checked under it, so two stealers cannot both win.
pub fn acquire_lock(config_dir: &str, now: i64) -> Result<bool, String> {
    let path = jspath::join(&[config_dir, LOCK_NAME]);
    if try_create_lock(&path, now)? {
        return Ok(true);
    }
    if !is_stale(&path, now) {
        return Ok(false);
    }
    let guard = format!("{path}.steal");
    if age_of(&guard, now) >= STEAL_GUARD_STALE_MS {
        remove_force(&guard)?;
    }
    let guard_file = match OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&guard)
    {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => return Ok(false),
        Err(error) => return Err(io_failure(&error, "open", &guard)),
    };
    let stolen = (|| {
        if !is_stale(&path, now) {
            return Ok(false);
        }
        remove_force(&path)?;
        try_create_lock(&path, now)
    })();
    drop(guard_file);
    let removed = remove_force(&guard);
    let stolen = stolen?;
    removed?;
    Ok(stolen)
}

/// Remove the lock only while it is still ours.
pub fn release_lock(config_dir: &str) -> Result<(), String> {
    let path = jspath::join(&[config_dir, LOCK_NAME]);
    let holder = read_lock(&path);
    if jsx::field(&holder, "pid").as_f64() == Some(f64::from(std::process::id())) {
        remove_force(&path)?;
    }
    Ok(())
}

/// `lastRunAt`: when the previous run finished, or `None`.
fn last_run_at(config_dir: &str) -> Option<f64> {
    let parsed = read_lock(&jspath::join(&[config_dir, LAST_RUN_NAME]));
    let finished = jsx::field(&parsed, "finishedAt");
    jsx::is_integer(finished)
        .then(|| finished.as_f64())
        .flatten()
}

// MARK: - Listing the Agents

/// One Agent to summarize (`session` and `cwd` locate its transcript).
struct SummaryAgent {
    pane_id: String,
    status: String,
    kind: String,
    session: Option<SessionRef>,
    cwd: Option<String>,
    terminal_id: Option<String>,
}

/// `spawnRun`: no timeout (a year is none), stdin closed, no shell.
fn spawn_run(command: &str, args: &[&str], env: &Env) -> crate::exec::RunResult {
    run_program_with_timeout(command, args, env, Duration::from_secs(365 * 24 * 3600))
}

fn non_empty_string(value: &Value) -> Option<String> {
    value.as_str().filter(|s| !s.is_empty()).map(str::to_string)
}

/// The herdr Agents to summarize: each listed Agent with a summarized status
/// and an agent kind. `Err` when `agent list` fails or answers nonsense.
fn list_herdr_agents(bin_path: &str, env: &Env) -> Result<Vec<SummaryAgent>, String> {
    let result = spawn_run(bin_path, &["agent", "list"], env);
    if result.code != 0 {
        return Err(format!(
            "agent list failed (exit {}): {}",
            result.code,
            jsx::trim(&result.stderr)
        ));
    }
    let parsed = jsx::parse_json(&result.stdout).ok_or("invalid JSON")?;
    let agents = jsx::field(jsx::field(&parsed, "result"), "agents")
        .as_array()
        .ok_or("agent list returned no agents")?;
    let mut out = Vec::new();
    for agent in agents {
        // `agent list` holds Agents only; one without a detected agent kind
        // is a plain shell and gets no summary.
        let (Some(pane_id), Some(kind)) = (
            jsx::field(agent, "pane_id").as_str(),
            non_empty_string(jsx::field(agent, "agent")),
        ) else {
            continue;
        };
        let status = jsx::field(agent, "agent_status")
            .as_str()
            .map(str::to_lowercase);
        let Some(status) = status.filter(|s| SUMMARIZED_STATUSES.contains(&s.as_str())) else {
            continue;
        };
        out.push(SummaryAgent {
            pane_id: pane_id.to_string(),
            status,
            kind,
            session: herdr_session_reference(jsx::field(agent, "agent_session")),
            cwd: non_empty_string(jsx::field(agent, "cwd")),
            terminal_id: non_empty_string(jsx::field(agent, "terminal_id")),
        });
    }
    Ok(out)
}

/// The tmux Agents to summarize, by the same rule: an agent kind and a
/// summarized status. A tmux that is absent or has no server has none.
fn list_tmux_summary_agents(env: &Env) -> Vec<SummaryAgent> {
    let Ok(agents) = tmux::list_agents_with(&spawn_run, env) else {
        return Vec::new();
    };
    agents
        .into_iter()
        .filter_map(|agent| {
            let kind = agent.agent.clone().filter(|k| !k.is_empty())?;
            let status = agent.status.filter(|s| SUMMARIZED_STATUSES.contains(s))?;
            Some(SummaryAgent {
                session: tmux_session_reference(
                    agent.session.as_deref(),
                    agent.transcript.as_deref(),
                ),
                pane_id: agent.pane_id,
                status: status.to_string(),
                kind,
                cwd: agent.cwd,
                terminal_id: None,
            })
        })
        .collect()
}

/// The herdr-core terminals to summarize, by the same rule: an agent kind and
/// a summarized status (a plain shell has no status). The record gives what
/// the listing leaves out: the kind and transcript session the hooks label,
/// and the working folder. A core that cannot list has none.
fn list_core_summary_agents(core: &CoreCommand, run: Runner<'_>) -> Vec<SummaryAgent> {
    let Ok(terminals) = core_list(core, run) else {
        return Vec::new();
    };
    terminals
        .into_iter()
        .filter_map(|terminal| {
            let status = terminal
                .waycar_status()
                .filter(|s| SUMMARIZED_STATUSES.contains(s))?;
            let record = core_get(core, run, &terminal.address).ok().flatten();
            let kind = record
                .as_ref()
                .and_then(|record| record.kind())
                .or(terminal.agent.as_deref())
                .filter(|kind| !kind.is_empty())?
                .to_string();
            let label = |name: &str| record.as_ref()?.labels.get(name).map(String::as_str);
            Some(SummaryAgent {
                pane_id: terminal.pane_id(),
                status: status.to_string(),
                kind,
                session: tmux_session_reference(
                    label("waycar.session"),
                    label("waycar.transcript"),
                ),
                cwd: record
                    .as_ref()
                    .and_then(|record| record.folder())
                    .map(str::to_string)
                    .or(terminal.cwd.filter(|cwd| !cwd.is_empty())),
                terminal_id: None,
            })
        })
        .collect()
}

/// Every Agent on the Host. A missing or stopped herdr just contributes none.
fn list_agents(
    bin_path: &str,
    tmux_enabled: bool,
    core: Option<&CoreCommand>,
    env: &Env,
) -> Vec<SummaryAgent> {
    let mut agents = list_herdr_agents(bin_path, env).unwrap_or_default();
    if tmux_enabled {
        agents.extend(list_tmux_summary_agents(env));
    }
    if let Some(core) = core {
        agents.extend(list_core_summary_agents(core, &spawn_run));
    }
    agents
}

// MARK: - One refresh

/// Run `worker` over `items`, at most `limit` at a time. A lane that fails
/// stops; the others finish the queue, and the first error is returned.
fn for_each_bounded<T: Sync>(
    items: &[T],
    limit: usize,
    worker: &(dyn Fn(&T) -> Result<(), String> + Sync),
) -> Result<(), String> {
    let next = AtomicUsize::new(0);
    let failure: Mutex<Option<String>> = Mutex::new(None);
    std::thread::scope(|scope| {
        for _ in 0..limit.min(items.len()) {
            scope.spawn(|| {
                loop {
                    let index = next.fetch_add(1, Ordering::SeqCst);
                    let Some(item) = items.get(index) else {
                        break;
                    };
                    if let Err(error) = worker(item) {
                        if let Ok(mut slot) = failure.lock() {
                            slot.get_or_insert(error);
                        }
                        break;
                    }
                }
            });
        }
    });
    match failure.into_inner() {
        Ok(Some(error)) => Err(error),
        _ => Ok(()),
    }
}

/// What one refresh needs: where the store lives, which herdr to ask and how
/// to reach a model provider over HTTPS.
pub struct Refresh<'a> {
    pub config_dir: &'a str,
    pub state_dir: &'a str,
    /// The herdr CLI (`HERDR_BIN_PATH` or `herdr`).
    pub bin_path: &'a str,
    pub env: &'a Env,
    pub fetch: &'a dyn Fetch,
}

/// The steps to store with a new Working summary: the ones just read, or,
/// when the plan could not be read, the stored Working record's.
fn known_steps(steps: PlanProgress, stored: Option<&Value>) -> Map<String, Value> {
    let mut map = Map::new();
    match steps {
        PlanProgress::Steps(steps) => {
            map.insert("done".into(), Value::from(steps.done));
            map.insert("total".into(), Value::from(steps.total));
        }
        PlanProgress::None => {}
        PlanProgress::Unreadable => {
            let stored = stored.unwrap_or(&Value::Null);
            if jsx::field(stored, "status").as_str() != Some("working") {
                return map;
            }
            if let Some(known) = normalize_progress(jsx::field(stored, "progress")) {
                for key in ["done", "total"] {
                    if let Some(value) = known.get(key) {
                        map.insert(key.into(), value.clone());
                    }
                }
            }
        }
    }
    map
}

/// One agent's turn in a refresh (the body of the `forEachBounded` worker).
fn refresh_agent(
    refresh: &Refresh<'_>,
    summary_command: Option<&[String]>,
    summary_timeout: Duration,
    deadline: &std::sync::Arc<crate::chat::shared::AbortSignal>,
    agent: &SummaryAgent,
    refresh_home: &str,
    counters: (&AtomicUsize, &AtomicUsize),
) -> Result<(), String> {
    let (summarized, skipped) = counters;
    let (config_dir, env) = (refresh.config_dir, refresh.env);
    if deadline.is_aborted() {
        return Ok(());
    }
    let SummaryAgent {
        pane_id,
        status,
        kind,
        session,
        cwd,
        terminal_id,
    } = agent;
    // A Working Agent's plan steps, read before the hash skip below, on their
    // own budget (never the model's). Other statuses carry none of their own
    // (the store keeps a Blocked Agent's last ones).
    let steps = if status == "working" {
        read_plan_progress(&PlanArgs {
            agent: kind,
            session: session.as_ref(),
            cwd: cwd.as_deref(),
            pane_id: Some(pane_id),
            config_dir: Some(config_dir),
            terminal_id: terminal_id.as_deref(),
            env,
            home: refresh_home,
            signal: Some(deadline),
            timeout_ms: PLAN_READ_TIMEOUT_MS,
        })
    } else {
        PlanProgress::None
    };
    if deadline.is_aborted() {
        return Ok(());
    }
    let linked = linked_signal(std::slice::from_ref(deadline), Some(summary_timeout));
    let signal = &linked.signal;
    let Some(screen) = read_screen(refresh.bin_path, pane_id, signal, env) else {
        return Ok(());
    };
    let hash = screen_hash(&screen);
    let stored = read_summary(config_dir, pane_id);
    // Same screen, same status: the stored summary still says it. A status
    // change on an unchanged screen (Working to Done) still needs a new one.
    let stored_ref = stored.as_ref().unwrap_or(&Value::Null);
    if jsx::field(stored_ref, "hash").as_str() == Some(hash.as_str())
        && jsx::field(stored_ref, "status").as_str() == Some(status.as_str())
        && jsx::field(stored_ref, "summary").is_string()
    {
        if status == "working" && steps != PlanProgress::Unreadable {
            let progress = match steps {
                PlanProgress::Steps(steps) => {
                    let mut map = Map::new();
                    map.insert("done".into(), Value::from(steps.done));
                    map.insert("total".into(), Value::from(steps.total));
                    Value::Object(map)
                }
                _ => Value::Null,
            };
            write_progress(
                config_dir,
                &ProgressWrite {
                    pane_id,
                    status,
                    progress: &progress,
                    ts: now_ms(),
                },
            )
            .map_err(|e| io_failure(&e, "open", config_dir))?;
        }
        skipped.fetch_add(1, Ordering::SeqCst);
        return Ok(());
    }
    let read_at = now_ms();
    let summarized_screen = summarize_screen(&SummarizeOptions {
        screen: Some(&screen),
        status,
        command: summary_command,
        signal,
        work_dir: refresh.state_dir,
        cache_dir: config_dir,
        path_fallback: None,
        env,
        fetch: refresh.fetch,
    });
    summarized.fetch_add(1, Ordering::SeqCst);
    // No answer (no provider, a failure, a timeout) leaves the entry alone;
    // the next run tries again.
    let Some(summary) = summarized_screen.summary else {
        return Ok(());
    };
    let progress = if status == "working" {
        let mut map = known_steps(steps, stored.as_ref());
        map.insert(
            "phase".into(),
            summarized_screen.phase.map_or(Value::Null, Value::from),
        );
        Value::Object(map)
    } else {
        Value::Null
    };
    write_summary(
        config_dir,
        &SummaryWrite {
            pane_id,
            status,
            summary: Some(&summary),
            ts: read_at,
            hash: Some(&hash),
            progress: &progress,
        },
    )
    .map_err(|e| io_failure(&e, "open", config_dir))?;
    Ok(())
}

/// One refresh (`refreshSummaries`). `Err` carries the JS exception message.
pub fn refresh_summaries(refresh: &Refresh<'_>) -> Result<Outcome, String> {
    let config_dir = refresh.config_dir;
    let config = read_notification_config(config_dir)?;
    if !config.summary_enabled {
        remove_summaries(config_dir).map_err(|e| io_failure(&e, "rm", config_dir))?;
        return Ok(Outcome::NotRan("disabled"));
    }
    DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(config_dir)
        .map_err(|e| io_failure(&e, "mkdir", config_dir))?;
    if !acquire_lock(config_dir, now_ms())? {
        return Ok(Outcome::NotRan("locked"));
    }
    let outcome = run_locked(refresh, &config);
    let released = release_lock(config_dir);
    let outcome = outcome?;
    released?;
    Ok(outcome)
}

fn run_locked(
    refresh: &Refresh<'_>,
    config: &crate::notification_config::NotificationConfig,
) -> Result<Outcome, String> {
    let config_dir = refresh.config_dir;
    if let Some(last) = last_run_at(config_dir) {
        let since = now_ms() as f64 - last;
        if since >= 0.0 && since < MIN_INTERVAL_MS as f64 {
            return Ok(Outcome::NotRan("too-soon"));
        }
    }
    prune_summaries(config_dir, now_ms(), SUMMARY_MAX_AGE_MS);
    // `os.homedir()`: the process's own, whatever environment the children get.
    let home = home_dir(&Env::from_process())
        .map_or_else(String::new, |h| h.to_string_lossy().into_owned());
    // A core that is not running is not asked: the call would start one.
    let core = config
        .core_enabled
        .then(|| running_core(refresh.env, Path::new(&home), &spawn_run))
        .flatten();
    let agents = list_agents(
        refresh.bin_path,
        config.tmux_enabled,
        core.as_ref(),
        refresh.env,
    );
    let summarized = AtomicUsize::new(0);
    let skipped = AtomicUsize::new(0);
    // The whole run stays well inside LOCK_STALE_MS, so a live holder is never
    // mistaken for a dead one; Agents not reached wait for the next run.
    let deadline = linked_signal(&[], Some(Duration::from_millis(RUN_DEADLINE_MS)));
    let summary_timeout = Duration::from_millis(config.summary_timeout_ms);
    for_each_bounded(&agents, CONCURRENCY, &|agent| {
        refresh_agent(
            refresh,
            config.summary_command.as_deref(),
            summary_timeout,
            &deadline.signal,
            agent,
            &home,
            (&summarized, &skipped),
        )
    })?;
    drop(deadline);
    let path = jspath::join(&[config_dir, LAST_RUN_NAME]);
    let body = format!("{{\"finishedAt\":{}}}\n", now_ms());
    write_atomic(Path::new(&path), body.as_bytes(), 0o600)
        .map_err(|e| io_failure(&e, "open", &format!("{path}.tmp-{}", std::process::id())))?;
    Ok(Outcome::Ran {
        agents: agents.len(),
        summarized: summarized.load(Ordering::SeqCst),
        skipped: skipped.load(Ordering::SeqCst),
    })
}

/// `refreshHostSummaries`: one refresh with the Host's config and state dirs
/// (the herdr plugin's when it is installed, so both triggers share one store
/// and lock). herdr's Agents are included when `herdr` (or `HERDR_BIN_PATH`)
/// answers.
pub fn refresh_host_summaries(env: &Env, home: &str) -> Result<Outcome, String> {
    let host = resolve_host_config(env, Path::new(home), &|herdr, args| run_herdr(herdr, args))
        .map_err(|e| e.message().to_string())?;
    // herdr's usual install prefixes join PATH; tmux and the harnesses see the same.
    let herdr = herdr_command(env, Path::new(home));
    refresh_summaries(&Refresh {
        config_dir: &host.config_dir.to_string_lossy(),
        state_dir: &host.state_dir.to_string_lossy(),
        bin_path: &herdr.bin,
        env: &herdr.env,
        fetch: &HttpFetch,
    })
}

/// `waycar summaries refresh`: one refresh, its outcome as one JSON line.
pub fn run(env: &Env, home: &str, io: &mut Io<'_>) -> i32 {
    match refresh_host_summaries(env, home) {
        Ok(outcome) => {
            let _ = writeln!(io.stdout, "{}", outcome.to_json());
            0
        }
        Err(message) => {
            let _ = writeln!(io.stderr, "waycar: {message}");
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;
    use std::sync::atomic::AtomicU32;

    use serde_json::json;

    use super::*;
    use crate::atomic::pane_file_name;

    static COUNTER: AtomicU32 = AtomicU32::new(0);

    /// The stub herdr: `agent list` from agents.json, `pane read <id>` from
    /// screens/<id>.
    const HERDR_STUB: &str = r#"#!/bin/sh
d=$(dirname "$0")
if [ "$1" = agent ] && [ "$2" = list ]; then
  printf '{"id":"cli","result":{"agents":%s}}' "$(cat "$d/agents.json")"
  exit 0
fi
if [ "$1" = pane ] && [ "$2" = read ]; then
  f="$d/screens/$(printf %s "$3" | tr ':%' '__')"
  [ -f "$f" ] || exit 1
  cat "$f"
  exit 0
fi
exit 2
"#;

    /// herdr-core: `--version`, `ls --json` (core-ls.json), `get <t> --json`
    /// (core-get-<t>.json), and `read <t> --lines N` (cscreens/<t>); every call
    /// is logged in core.log.
    const CORE_STUB: &str = r#"#!/bin/sh
d=$(dirname "$0")
echo "$*" >> "$d/core.log"
case "$1" in
  --version) echo 'hc 0.1.14';;
  ls) cat "$d/core-ls.json";;
  get)
    f="$d/core-get-$2.json"
    if [ -f "$f" ]; then cat "$f"; else echo '{"error":{"kind":"not_found"}}'; exit 3; fi;;
  read)
    f="$d/cscreens/$2"
    [ -f "$f" ] || exit 3
    cat "$f";;
  *) exit 64;;
esac
exit 0
"#;

    /// `tmux`: no server without tmux-list.out; else `list-panes` prints it
    /// and `capture-pane -t %N` prints tscreens/N.
    const TMUX_STUB: &str = r#"#!/bin/sh
d=$(dirname "$0")
if [ "$1" != "-u" ]; then echo "stub: tmux without -u" >&2; exit 64; fi
shift
if [ ! -f "$d/tmux-list.out" ]; then
  echo "no server running on /tmp/tmux-stub/default" >&2
  exit 1
fi
case "$1" in
  list-panes) cat "$d/tmux-list.out"; exit 0;;
  capture-pane)
    while [ $# -gt 0 ]; do
      if [ "$1" = "-t" ]; then t="$2"; fi
      shift
    done
    f="$d/tscreens/$(printf %s "$t" | tr '%' '_')"
    [ -f "$f" ] || exit 1
    cat "$f"
    exit 0;;
esac
exit 64
"#;

    /// The summarizer: logs each call, answers "about <first screen line>",
    /// plus any `Phase:` line on the screen as its own second line.
    const SUMMARIZER: &str = r#"#!/bin/sh
d=$(dirname "$0")
t=$(mktemp)
cat > "$t"
echo called >> "$d/calls.log"
printf 'about %s\n' "$(head -n 1 "$t")"
grep -m1 '^Phase:' "$t"
rm -f "$t"
exit 0
"#;

    /// The panes `list-panes` prints and the screens `capture-pane` answers.
    type TmuxHost<'a> = (&'a [String], &'a [(&'a str, &'a str)]);

    struct Fixture {
        root: PathBuf,
        config_dir: String,
        state_dir: String,
        stub_dir: String,
    }

    impl Fixture {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!(
                "refresh-summaries-{}-{}",
                std::process::id(),
                COUNTER.fetch_add(1, Ordering::SeqCst)
            ));
            let path = |name: &str| root.join(name).to_str().unwrap().to_string();
            let fixture = Self {
                config_dir: path("config"),
                state_dir: path("state"),
                stub_dir: path("stub"),
                root: root.clone(),
            };
            for dir in [&fixture.config_dir, &fixture.state_dir, &fixture.stub_dir] {
                fs::create_dir_all(dir).unwrap();
            }
            fixture.write_stub("herdr", HERDR_STUB);
            fixture.write_stub("summarize", SUMMARIZER);
            fixture.write_stub("tmux", TMUX_STUB);
            fixture
        }

        fn stub(&self, name: &str) -> String {
            format!("{}/{name}", self.stub_dir)
        }

        fn write_stub(&self, name: &str, script: &str) {
            let path = self.stub(name);
            crate::test_support::write_stub(Path::new(&path), script);
        }

        fn root_str(&self) -> &str {
            self.root.to_str().unwrap()
        }

        fn set_host(&self, agents: Value, screens: &[(&str, &str)]) {
            fs::write(self.stub("agents.json"), jsx::stringify(&agents)).unwrap();
            let dir = self.stub("screens");
            let _ = fs::remove_dir_all(&dir);
            fs::create_dir_all(&dir).unwrap();
            for (pane, screen) in screens {
                fs::write(format!("{dir}/{}", pane.replace([':', '%'], "_")), screen).unwrap();
            }
        }

        /// Without a host the tmux stub answers like a machine with no server.
        fn set_tmux(&self, rows: Option<TmuxHost<'_>>) {
            let list = self.stub("tmux-list.out");
            let _ = fs::remove_file(&list);
            let Some((rows, screens)) = rows else {
                return;
            };
            fs::write(list, rows.concat()).unwrap();
            let dir = self.stub("tscreens");
            fs::create_dir_all(&dir).unwrap();
            for (pane, screen) in screens {
                fs::write(format!("{dir}/{}", pane.replace('%', "_")), screen).unwrap();
            }
        }

        fn write_config(&self, overrides: Value) {
            let mut config = json!({
                "summary_enabled": true,
                "summary_command": [self.stub("summarize")],
            });
            for (key, value) in overrides.as_object().unwrap() {
                config[key] = value.clone();
            }
            fs::write(
                format!("{}/notify.json", self.config_dir),
                jsx::stringify(&config),
            )
            .unwrap();
        }

        fn model_calls(&self) -> usize {
            fs::read_to_string(self.stub("calls.log"))
                .map_or(0, |log| log.trim_end().split('\n').count())
        }

        fn stored(&self, pane_id: &str) -> Option<Value> {
            let path = format!("{}/summaries/{}", self.config_dir, pane_file_name(pane_id));
            fs::read_to_string(path)
                .ok()
                .and_then(|text| jsx::parse_json(&text))
        }

        /// Let the next run past the 10 s minimum interval.
        fn age_last_run(&self) {
            fs::write(
                format!("{}/{LAST_RUN_NAME}", self.config_dir),
                jsx::stringify(&json!({ "finishedAt": now_ms() - 11_000 })),
            )
            .unwrap();
        }

        /// The action's environment: plugin dirs and the stub herdr, and a
        /// runtime dir of its own so the probe for a running core never looks
        /// at the socket of the machine's own core.
        fn action_env(&self) -> Env {
            Env::from_pairs([
                ("PATH", format!("{}:/usr/bin:/bin", self.stub_dir)),
                ("HERDR_PLUGIN_CONFIG_DIR", self.config_dir.clone()),
                ("HERDR_PLUGIN_STATE_DIR", self.state_dir.clone()),
                ("HERDR_BIN_PATH", self.stub("herdr")),
                ("XDG_RUNTIME_DIR", format!("{}/run", self.root_str())),
            ])
        }

        fn run_refresh(&self) -> Outcome {
            refresh_host_summaries(&self.action_env(), self.root_str()).unwrap()
        }

        /// herdr-core as a stub: `ls --json` prints `listing`, `get <t> --json`
        /// the record of `t` (or `not_found`), `read <t> --lines N` the screen.
        fn set_core(&self, listing: &Value, records: &[(&str, Value)], screens: &[(&str, &str)]) {
            self.write_stub("herdr-core", CORE_STUB);
            fs::write(self.stub("core-ls.json"), jsx::stringify(listing)).unwrap();
            for (address, record) in records {
                fs::write(
                    self.stub(&format!("core-get-{address}.json")),
                    jsx::stringify(record),
                )
                .unwrap();
            }
            let dir = self.stub("cscreens");
            fs::create_dir_all(&dir).unwrap();
            for (address, screen) in screens {
                fs::write(format!("{dir}/{address}"), screen).unwrap();
            }
        }

        /// A core listening on the default socket under the action's
        /// `XDG_RUNTIME_DIR` for as long as the result lives.
        fn core_listening(&self) -> std::os::unix::net::UnixListener {
            let dir = format!("{}/run/herdr-core", self.root_str());
            fs::create_dir_all(&dir).unwrap();
            std::os::unix::net::UnixListener::bind(format!("{dir}/default.sock")).unwrap()
        }

        /// The action's environment with the runtime dir a core lives in.
        fn core_env(&self) -> Env {
            let mut env = self.action_env();
            env.set("XDG_RUNTIME_DIR", format!("{}/run", self.root_str()));
            env
        }

        fn lock_path(&self) -> String {
            format!("{}/{LOCK_NAME}", self.config_dir)
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    fn ran(agents: usize, summarized: usize, skipped: usize) -> Outcome {
        Outcome::Ran {
            agents,
            summarized,
            skipped,
        }
    }

    fn agents() -> Value {
        json!([
            { "pane_id": "w1:p1", "agent": "claude", "agent_status": "working" },
            { "pane_id": "w1:p2", "agent": "omp", "agent_status": "idle" },
            { "pane_id": "w1:p3", "agent": "codex", "agent_status": "done" },
            { "pane_id": "w1:p4", "agent": "claude", "agent_status": "blocked" },
        ])
    }

    const SCREENS: [(&str, &str); 4] = [
        ("w1:p1", "editing webhook.ts\n"),
        ("w1:p2", "tests pass\n"),
        ("w1:p3", "merged PR\n"),
        ("w1:p4", "approve deploy?\n"),
    ];

    fn screens_with(pane: &'static str, screen: &'static str) -> Vec<(&'static str, &'static str)> {
        SCREENS
            .iter()
            .map(|&(p, s)| if p == pane { (p, screen) } else { (p, s) })
            .collect()
    }

    #[test]
    fn writes_an_entry_with_status_summary_and_screen_hash_for_every_agent() {
        let f = Fixture::new();
        f.write_config(json!({}));
        f.set_host(agents(), &SCREENS);
        let before = now_ms();

        assert_eq!(f.run_refresh(), ran(4, 4, 0));

        for (pane, status) in [
            ("w1:p1", "working"),
            ("w1:p2", "idle"),
            ("w1:p3", "done"),
            ("w1:p4", "blocked"),
        ] {
            let entry = f.stored(pane).unwrap();
            let screen = SCREENS
                .iter()
                .find(|(p, _)| *p == pane)
                .unwrap()
                .1
                .trim_end();
            let ts = entry["ts"].as_i64().unwrap();
            assert!(ts >= before);
            let mut entry = entry;
            entry["ts"] = Value::Null;
            assert_eq!(
                entry,
                json!({
                    "v": 1, "pane": pane, "status": status,
                    "summary": format!("about {screen}"), "ts": null,
                    "hash": screen_hash(screen), "progress": null,
                })
            );
        }
    }

    #[test]
    fn a_second_run_within_10_s_does_nothing() {
        let f = Fixture::new();
        f.write_config(json!({}));
        f.set_host(agents(), &SCREENS);
        f.run_refresh();
        f.set_host(agents(), &screens_with("w1:p1", "something new\n"));

        assert_eq!(f.run_refresh(), Outcome::NotRan("too-soon"));
        assert_eq!(f.model_calls(), 4);
    }

    #[test]
    fn unchanged_screens_cost_no_model_call_only_the_changed_one_is_summarized_again() {
        let f = Fixture::new();
        f.write_config(json!({}));
        f.set_host(agents(), &SCREENS);
        f.run_refresh();
        f.age_last_run();
        let idle_before = f.stored("w1:p2");

        f.set_host(agents(), &screens_with("w1:p1", "now writing 5xx tests\n"));
        assert_eq!(f.run_refresh(), ran(4, 1, 3));
        assert_eq!(f.model_calls(), 5);
        assert_eq!(
            f.stored("w1:p1").unwrap()["summary"],
            "about now writing 5xx tests"
        );
        assert_eq!(f.stored("w1:p2"), idle_before);
    }

    #[test]
    fn a_status_change_on_an_unchanged_screen_is_summarized_again() {
        let f = Fixture::new();
        f.write_config(json!({}));
        f.set_host(agents(), &SCREENS);
        f.run_refresh();
        f.age_last_run();

        let mut changed = agents();
        changed[0]["agent_status"] = json!("done");
        f.set_host(changed, &SCREENS);
        assert!(matches!(
            f.run_refresh(),
            Outcome::Ran { summarized: 1, .. }
        ));
        assert_eq!(f.stored("w1:p1").unwrap()["status"], "done");
    }

    #[test]
    fn an_agent_without_a_summary_is_retried_on_the_next_run() {
        let f = Fixture::new();
        f.write_config(json!({ "summary_command": [f.stub("missing-model")] }));
        f.set_host(json!([agents()[0]]), &SCREENS);
        f.run_refresh();
        assert_eq!(f.stored("w1:p1"), None);
        f.age_last_run();

        f.write_config(json!({}));
        assert!(matches!(
            f.run_refresh(),
            Outcome::Ran { summarized: 1, .. }
        ));
        assert_eq!(
            f.stored("w1:p1").unwrap()["summary"],
            "about editing webhook.ts"
        );
    }

    #[test]
    fn entries_without_a_kind_plain_shells_and_unreadable_panes_are_skipped() {
        let f = Fixture::new();
        f.write_config(json!({}));
        f.set_host(
            json!([
                agents()[0],
                { "pane_id": "w1:p9", "agent_status": "idle" },
                { "pane_id": "w1:p8", "agent": "omp", "agent_status": "idle" },
            ]),
            &SCREENS,
        );

        assert!(matches!(
            f.run_refresh(),
            Outcome::Ran { summarized: 1, .. }
        ));
        assert_eq!(f.stored("w1:p9"), None);
        assert_eq!(f.stored("w1:p8"), None);
    }

    #[test]
    fn a_run_holding_the_lock_keeps_a_concurrent_one_out() {
        let f = Fixture::new();
        f.write_config(json!({}));
        f.set_host(agents(), &SCREENS);
        fs::write(
            f.lock_path(),
            jsx::stringify(&json!({ "pid": std::process::id(), "ts": now_ms() })),
        )
        .unwrap();

        assert_eq!(f.run_refresh(), Outcome::NotRan("locked"));
        assert_eq!(f.model_calls(), 0);
        assert!(
            Path::new(&f.lock_path()).exists(),
            "another run's lock is left alone"
        );
    }

    #[test]
    fn a_lock_whose_holder_is_gone_or_older_than_any_run_can_last_is_taken_over_and_released() {
        let f = Fixture::new();
        f.write_config(json!({}));
        f.set_host(agents(), &SCREENS);
        for holder in [
            json!({ "pid": std::process::id(), "ts": now_ms() - LOCK_STALE_MS as i64 - 1_000 }),
            json!({ "pid": (1i64 << 22) + 7, "ts": now_ms() }),
        ] {
            fs::write(f.lock_path(), jsx::stringify(&holder)).unwrap();
            let _ = fs::remove_file(format!("{}/{LAST_RUN_NAME}", f.config_dir));

            assert!(matches!(f.run_refresh(), Outcome::Ran { .. }), "{holder}");
            assert!(!Path::new(&f.lock_path()).exists());
        }
    }

    // A busy run (28 Agents, 3 at a time, 15 s each) lasts ~150 s.
    #[test]
    fn a_live_run_past_150_s_keeps_its_lock() {
        let f = Fixture::new();
        let holder = jsx::stringify(
            &json!({ "pid": std::os::unix::process::parent_id(), "ts": now_ms() - 150_000 }),
        );
        fs::write(f.lock_path(), &holder).unwrap();

        assert_eq!(acquire_lock(&f.config_dir, now_ms()), Ok(false));
        assert_eq!(fs::read_to_string(f.lock_path()).unwrap(), holder);
    }

    #[test]
    fn releasing_never_removes_another_runs_lock() {
        let f = Fixture::new();
        let holder =
            jsx::stringify(&json!({ "pid": std::os::unix::process::parent_id(), "ts": now_ms() }));
        fs::write(f.lock_path(), &holder).unwrap();

        release_lock(&f.config_dir).unwrap();

        assert_eq!(fs::read_to_string(f.lock_path()).unwrap(), holder);
        fs::remove_file(f.lock_path()).unwrap();
        assert_eq!(acquire_lock(&f.config_dir, now_ms()), Ok(true));
        release_lock(&f.config_dir).unwrap();
        assert!(!Path::new(&f.lock_path()).exists());
    }

    #[test]
    fn a_status_triggered_refresh_10_s_after_the_last_run_is_not_dropped() {
        let f = Fixture::new();
        f.write_config(json!({}));
        f.set_host(agents(), &SCREENS);
        f.run_refresh();
        f.age_last_run();
        f.set_host(agents(), &screens_with("w1:p1", "something new\n"));

        assert_eq!(f.run_refresh(), ran(4, 1, 3));
    }

    #[test]
    fn a_ticking_timer_and_spinner_on_a_still_agent_cost_no_model_call() {
        let f = Fixture::new();
        f.write_config(json!({}));
        let one = json!([agents()[0]]);
        f.set_host(
            one.clone(),
            &[(
                "w1:p1",
                "editing webhook.ts\n⠋ Thinking… (12s · 1.2k tokens)\n",
            )],
        );
        f.run_refresh();
        f.age_last_run();
        f.set_host(
            one,
            &[(
                "w1:p1",
                "editing webhook.ts\n⠙ Thinking… (74s · 3.9k tokens)\n",
            )],
        );

        assert_eq!(f.run_refresh(), ran(1, 0, 1));
    }

    #[test]
    fn with_summaries_off_nothing_is_read_and_the_store_is_deleted() {
        let f = Fixture::new();
        f.write_config(json!({ "summary_enabled": false }));
        f.set_host(agents(), &SCREENS);
        fs::create_dir_all(format!("{}/summaries", f.config_dir)).unwrap();
        fs::write(
            format!("{}/summaries/{}", f.config_dir, pane_file_name("w1:p1")),
            "{}",
        )
        .unwrap();

        assert_eq!(f.run_refresh(), Outcome::NotRan("disabled"));
        assert!(!Path::new(&format!("{}/summaries", f.config_dir)).exists());
        assert_eq!(f.model_calls(), 0);
    }

    // MARK: tmux Agents

    /// One `list-panes -F` row per pane, in the field order the listing asks for.
    fn tmux_pane(id: &str, status: &str, agent: &str, command: &str, session: &str) -> String {
        let fields = [
            id,
            "$1",
            "@2",
            "0",
            "",
            "0",
            status,
            agent,
            "1790000000000000000",
            command,
            "dev",
            "api",
            "/work/api",
            session,
            "",
            "",
        ];
        format!("\u{241e}{}\n", fields.join("\u{241f}"))
    }

    fn tmux_panes() -> Vec<String> {
        vec![
            tmux_pane("%7", "blocked", "claude", "2.1.286", ""),
            // No agent kind (status alone) and a pane back at its shell get no summary.
            tmux_pane("%8", "working", "", "2.1.286", ""),
            tmux_pane("%9", "done", "codex", "zsh", ""),
        ]
    }

    const TMUX_SCREENS: [(&str, &str); 3] = [
        ("%7", "allow rm -rf build?\n"),
        ("%8", "x\n"),
        ("%9", "y\n"),
    ];

    #[test]
    fn the_herdr_action_summarizes_herdr_and_tmux_agents_in_one_run() {
        let f = Fixture::new();
        f.write_config(json!({}));
        f.set_host(agents(), &SCREENS);
        f.set_tmux(Some((&tmux_panes(), &TMUX_SCREENS)));

        assert_eq!(f.run_refresh(), ran(5, 5, 0));
        let entry = f.stored("tmux:%7").unwrap();
        assert_eq!(entry["status"], "blocked");
        assert_eq!(entry["summary"], "about allow rm -rf build?");
        assert_eq!(entry["hash"], screen_hash("allow rm -rf build?"));
        assert_eq!(f.stored("tmux:%8"), None);
        assert_eq!(f.stored("tmux:%9"), None);
        assert_eq!(f.stored("w1:p1").unwrap()["status"], "working");
    }

    #[test]
    fn tmux_enabled_false_leaves_tmux_agents_unsummarized() {
        let f = Fixture::new();
        f.write_config(json!({ "tmux_enabled": false }));
        f.set_host(agents(), &SCREENS);
        f.set_tmux(Some((&tmux_panes(), &TMUX_SCREENS)));

        assert_eq!(f.run_refresh(), ran(4, 4, 0));
        assert_eq!(f.stored("tmux:%7"), None);
    }

    // MARK: herdr-core Agents

    /// `ls --json`, the records `get` prints for these terminals, and what
    /// `read <t> --lines N` prints.
    type CoreTerminals = (
        Value,
        Vec<(&'static str, Value)>,
        Vec<(&'static str, &'static str)>,
    );

    fn core_terminals() -> CoreTerminals {
        let record = |address: &str, status: Option<&str>, app: &str, labels: Value| {
            json!({
                "address": address, "state": "live", "reported": status.is_some(),
                "status": status.map(|state| json!({ "state": state, "app": app })),
                "turn": 1, "cwd": "/start",
                "foreground": { "cwd": "/work/api", "name": app },
                "labels": labels,
            })
        };
        let records = vec![
            ("t1", record("t1", Some("blocked"), "claude", json!({}))),
            // A plain shell never reported: no summary.
            ("t2", record("t2", None, "sh", json!({}))),
            (
                "t3",
                record(
                    "t3",
                    Some("done"),
                    "codex",
                    json!({ "waycar.kind": "omp", "waycar.session": "/tmp/s.jsonl" }),
                ),
            ),
            ("t4", record("t4", Some("error"), "claude", json!({}))),
        ];
        let listing = json!({ "hidden_finished": 0, "terminals": records.iter().map(|(address, record)| json!({
            "address": address,
            "agent": record["status"]["app"].as_str().unwrap_or("sh"),
            "cwd": record["cwd"],
            "state": "live",
            "status": record["status"]["state"],
            "turn": 1,
        })).collect::<Vec<_>>() });
        let screens = vec![
            ("t1", "allow rm -rf build?\n"),
            ("t2", "$ \n"),
            ("t3", "merged PR\n"),
            ("t4", "tests crashed\n"),
        ];
        (listing, records, screens)
    }

    #[test]
    fn a_running_core_has_its_agents_summarized() {
        let f = Fixture::new();
        f.write_config(json!({}));
        f.set_host(json!([]), &[]);
        let (listing, records, screens) = core_terminals();
        f.set_core(&listing, &records, &screens);
        let _listening = f.core_listening();

        let outcome = refresh_host_summaries(&f.core_env(), f.root_str()).unwrap();

        assert_eq!(outcome, ran(3, 3, 0));
        let entry = f.stored("hc:t1").unwrap();
        assert_eq!(entry["status"], "blocked");
        assert_eq!(entry["summary"], "about allow rm -rf build?");
        assert_eq!(entry["hash"], screen_hash("allow rm -rf build?"));
        assert_eq!(f.stored("hc:t2"), None);
        assert_eq!(f.stored("hc:t3").unwrap()["status"], "done");
        // An `error` report summarizes as blocked.
        assert_eq!(f.stored("hc:t4").unwrap()["status"], "blocked");
    }

    #[test]
    fn core_agents_join_herdr_and_tmux_agents_in_one_run() {
        let f = Fixture::new();
        f.write_config(json!({}));
        f.set_host(agents(), &SCREENS);
        f.set_tmux(Some((&tmux_panes(), &TMUX_SCREENS)));
        let (listing, records, screens) = core_terminals();
        f.set_core(&listing, &records, &screens);
        let _listening = f.core_listening();

        let outcome = refresh_host_summaries(&f.core_env(), f.root_str()).unwrap();

        assert_eq!(outcome, ran(8, 8, 0));
    }

    #[test]
    fn core_enabled_false_leaves_core_out_without_asking_it() {
        let f = Fixture::new();
        f.write_config(json!({ "core_enabled": false }));
        f.set_host(json!([]), &[]);
        let (listing, records, screens) = core_terminals();
        f.set_core(&listing, &records, &screens);
        let _listening = f.core_listening();

        let outcome = refresh_host_summaries(&f.core_env(), f.root_str()).unwrap();

        assert_eq!(outcome, ran(0, 0, 0));
        assert!(!Path::new(&f.stub("core.log")).exists());
    }

    #[test]
    fn a_core_that_is_not_running_is_never_asked() {
        // The socket file is there, nothing listens: asking would start a core.
        let f = Fixture::new();
        f.write_config(json!({}));
        f.set_host(json!([]), &[]);
        let (listing, records, screens) = core_terminals();
        f.set_core(&listing, &records, &screens);
        // A file where the socket was: a listener dropped here could still be
        // held open by a child another test thread forks meanwhile.
        let socket = format!("{}/run/herdr-core/default.sock", f.root_str());
        fs::create_dir_all(Path::new(&socket).parent().unwrap()).unwrap();
        fs::write(&socket, "").unwrap();

        let outcome = refresh_host_summaries(&f.core_env(), f.root_str()).unwrap();

        assert_eq!(outcome, ran(0, 0, 0));
        assert!(!Path::new(&f.stub("core.log")).exists());
    }

    #[test]
    fn a_core_agent_whose_record_cannot_be_read_is_still_summarized_by_its_listing() {
        let f = Fixture::new();
        f.write_config(json!({}));
        f.set_host(json!([]), &[]);
        let (listing, _, screens) = core_terminals();
        f.set_core(&listing, &[], &screens);
        let _listening = f.core_listening();

        let outcome = refresh_host_summaries(&f.core_env(), f.root_str()).unwrap();

        assert_eq!(outcome, ran(3, 3, 0));
    }

    #[test]
    fn core_agents_carry_the_kind_session_and_folder_the_hooks_labelled() {
        let (listing, records, _) = core_terminals();
        let run = |_: &str, args: &[&str], _: &Env| {
            let mut found = crate::exec::RunResult {
                code: 0,
                stdout: String::new(),
                stderr: String::new(),
            };
            match args {
                ["ls", "--json"] => found.stdout = listing.to_string(),
                ["get", address, "--json"] => {
                    let record = records.iter().find(|(a, _)| a == address).unwrap();
                    found.stdout = record.1.to_string();
                }
                _ => found.code = 64,
            }
            found
        };
        let core = CoreCommand {
            bin: "/x/herdr-core".into(),
            version: "0.1.14".into(),
            env: Env::default(),
        };

        let agents = list_core_summary_agents(&core, &run);

        let ids: Vec<&str> = agents.iter().map(|a| a.pane_id.as_str()).collect();
        assert_eq!(ids, ["hc:t1", "hc:t3", "hc:t4"]);
        let t3 = &agents[1];
        // The kind label beats the program's own app name.
        assert_eq!(t3.kind, "omp");
        assert_eq!(
            t3.session,
            Some(SessionRef {
                kind: "path".into(),
                value: "/tmp/s.jsonl".into()
            })
        );
        // The foreground folder beats the start folder.
        assert_eq!(t3.cwd.as_deref(), Some("/work/api"));
        assert_eq!(t3.terminal_id, None);
        assert_eq!(agents[0].kind, "claude");
        assert_eq!(agents[0].session, None);
        assert_eq!(agents[2].status, "blocked");
    }

    #[test]
    fn refresh_host_summaries_on_a_tmux_only_host_uses_the_hosts_own_config_and_state_dirs() {
        let mut f = Fixture::new();
        let xdg_config = format!("{}/xdg-config", f.root_str());
        let xdg_state = format!("{}/xdg-state", f.root_str());
        f.config_dir = format!("{xdg_config}/waycar");
        fs::create_dir_all(&f.config_dir).unwrap();
        f.write_config(json!({}));
        f.set_tmux(Some((&tmux_panes()[..1], &TMUX_SCREENS)));
        // A missing herdr is no herdr Agents, never a failed run.
        let env = Env::from_pairs([
            ("PATH", format!("{}:/usr/bin:/bin", f.stub_dir)),
            ("HOME", f.root_str().to_string()),
            ("XDG_CONFIG_HOME", xdg_config),
            ("XDG_STATE_HOME", xdg_state.clone()),
            ("HERDR_BIN_PATH", f.stub("no-herdr-here")),
        ]);

        let outcome = refresh_host_summaries(&env, f.root_str()).unwrap();

        assert_eq!(outcome, ran(1, 1, 0));
        assert_eq!(
            f.stored("tmux:%7").unwrap()["summary"],
            "about allow rm -rf build?"
        );
        assert!(
            Path::new(&format!("{xdg_state}/waycar/summary-cwd")).exists(),
            "the harness ran from the Host state dir"
        );
    }

    // MARK: Agent Progress

    /// A codex rollout whose open turn wrote one plan with these step statuses.
    fn write_codex_plan(f: &Fixture, statuses: &[&str]) -> String {
        let file = format!("{}/rollout.jsonl", f.root_str());
        let plan: Vec<Value> = statuses
            .iter()
            .enumerate()
            .map(|(i, status)| json!({ "step": format!("step {}", i + 1), "status": status }))
            .collect();
        let records = [
            json!({ "type": "event_msg", "payload": { "type": "task_started", "turn_id": "t1" } }),
            json!({ "type": "event_msg", "payload": { "type": "user_message", "message": "migrate the store" } }),
            json!({ "type": "response_item", "payload": {
                "type": "function_call", "name": "update_plan",
                "arguments": jsx::stringify(&json!({ "plan": plan })), "call_id": "c1",
            } }),
        ];
        let body: Vec<String> = records.iter().map(jsx::stringify).collect();
        fs::write(&file, format!("{}\n", body.join("\n"))).unwrap();
        file
    }

    fn plan(done: usize, total: usize) -> Vec<&'static str> {
        let mut steps = vec!["completed"; done];
        steps.extend(vec!["pending"; total - done]);
        steps
    }

    fn codex_agent(status: &str, transcript: &str) -> Value {
        json!([{
            "pane_id": "w1:p1", "agent": "codex", "agent_status": status, "cwd": "/work",
            "agent_session": { "kind": "path", "value": transcript },
        }])
    }

    #[test]
    fn a_step_ticking_on_a_digit_only_screen_change_is_stored_without_a_model_call() {
        let f = Fixture::new();
        f.write_config(json!({}));
        let transcript = write_codex_plan(&f, &plan(3, 7));
        f.set_host(
            codex_agent("working", &transcript),
            &[("w1:p1", "running step 4 of 7\nPhase: implementing\n")],
        );
        f.run_refresh();
        assert_eq!(
            f.stored("w1:p1").unwrap()["progress"],
            json!({ "done": 3, "total": 7, "phase": "implementing" })
        );
        f.age_last_run();

        write_codex_plan(&f, &plan(4, 7));
        f.set_host(
            codex_agent("working", &transcript),
            &[("w1:p1", "running step 5 of 7\nPhase: implementing\n")],
        );

        assert_eq!(f.run_refresh(), ran(1, 0, 1));
        assert_eq!(f.model_calls(), 1);
        let entry = f.stored("w1:p1").unwrap();
        assert_eq!(entry["summary"], "about running step 4 of 7");
        assert_eq!(
            entry["progress"],
            json!({ "done": 4, "total": 7, "phase": "implementing" })
        );
    }

    #[test]
    fn the_phase_never_moves_backwards_within_a_turn_and_starts_afresh_after_done() {
        let f = Fixture::new();
        f.write_config(json!({}));
        let phase_after = |status: &str, screen: &str| {
            f.set_host(
                json!([{ "pane_id": "w1:p1", "agent": "claude", "agent_status": status }]),
                &[("w1:p1", screen)],
            );
            f.run_refresh();
            f.age_last_run();
            f.stored("w1:p1").unwrap()["progress"].clone()
        };

        assert_eq!(
            phase_after("working", "running tests\nPhase: verifying\n"),
            json!({ "phase": "verifying" })
        );
        assert_eq!(
            phase_after("working", "reading a.ts\nPhase: exploring\n"),
            json!({ "phase": "verifying" })
        );
        assert_eq!(phase_after("done", "all green\n"), Value::Null);
        assert_eq!(
            phase_after("working", "reading b.ts\nPhase: exploring\n"),
            json!({ "phase": "exploring" })
        );
    }

    #[test]
    fn a_plan_that_cannot_be_read_never_erases_the_stored_steps() {
        let f = Fixture::new();
        f.write_config(json!({}));
        let transcript = write_codex_plan(&f, &plan(3, 7));
        f.set_host(
            codex_agent("working", &transcript),
            &[("w1:p1", "migrating\nPhase: implementing\n")],
        );
        f.run_refresh();
        f.age_last_run();

        // The session now names a directory: the read fails. Same screen
        // first, then a changed one that is summarized again.
        f.set_host(
            codex_agent("working", f.root_str()),
            &[("w1:p1", "migrating\nPhase: implementing\n")],
        );
        f.run_refresh();
        assert_eq!(
            f.stored("w1:p1").unwrap()["progress"],
            json!({ "done": 3, "total": 7, "phase": "implementing" })
        );
        f.age_last_run();

        f.set_host(
            codex_agent("working", f.root_str()),
            &[("w1:p1", "migrating the index\nPhase: verifying\n")],
        );
        assert!(matches!(
            f.run_refresh(),
            Outcome::Ran { summarized: 1, .. }
        ));
        let entry = f.stored("w1:p1").unwrap();
        assert_eq!(entry["summary"], "about migrating the index");
        assert_eq!(
            entry["progress"],
            json!({ "done": 3, "total": 7, "phase": "verifying" })
        );
    }

    #[test]
    fn a_blocked_agent_keeps_its_working_progress_frozen() {
        let f = Fixture::new();
        f.write_config(json!({}));
        let transcript = write_codex_plan(&f, &plan(2, 5));
        f.set_host(
            codex_agent("working", &transcript),
            &[("w1:p1", "migrating\nPhase: implementing\n")],
        );
        f.run_refresh();
        f.age_last_run();

        f.set_host(
            codex_agent("blocked", &transcript),
            &[("w1:p1", "allow the migration?\n")],
        );
        f.run_refresh();

        let entry = f.stored("w1:p1").unwrap();
        assert_eq!(entry["status"], "blocked");
        assert_eq!(
            entry["progress"],
            json!({ "done": 2, "total": 5, "phase": "implementing" })
        );
    }

    #[test]
    fn a_tmux_agents_plan_is_found_through_its_waycar_session() {
        let f = Fixture::new();
        f.write_config(json!({}));
        f.set_host(json!([]), &[]);
        let transcript = write_codex_plan(&f, &plan(1, 3));
        f.set_tmux(Some((
            &[tmux_pane("%7", "working", "codex", "2.1.286", &transcript)],
            &[("%7", "editing\n")],
        )));

        f.run_refresh();

        assert_eq!(
            f.stored("tmux:%7").unwrap()["progress"],
            json!({ "done": 1, "total": 3 })
        );
    }

    // MARK: the command

    #[test]
    fn a_bare_host_prints_the_disabled_outcome() {
        // No node, no tmux, no herdr: a scratch HOME and a PATH without them.
        let f = Fixture::new();
        let env = Env::from_pairs([
            ("PATH", format!("{}/nowhere", f.root_str())),
            ("HOME", f.root_str().to_string()),
        ]);
        let (mut out, mut err) = (Vec::new(), Vec::new());
        let mut stdin = std::io::empty();
        let mut io = Io {
            stdin: &mut stdin,
            stdin_is_tty: false,
            stdout: &mut out,
            stderr: &mut err,
        };

        assert_eq!(run(&env, f.root_str(), &mut io), 0);
        assert_eq!(
            String::from_utf8(out).unwrap(),
            "{\"ran\":false,\"reason\":\"disabled\"}\n"
        );
        assert_eq!(String::from_utf8(err).unwrap(), "");
    }

    #[test]
    fn outcomes_print_like_json_stringify() {
        assert_eq!(
            Outcome::NotRan("too-soon").to_json(),
            r#"{"ran":false,"reason":"too-soon"}"#
        );
        assert_eq!(
            ran(28, 6, 22).to_json(),
            r#"{"ran":true,"agents":28,"summarized":6,"skipped":22}"#
        );
    }
}
