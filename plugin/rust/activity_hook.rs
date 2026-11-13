//! Live Activity hook (docs/agents/live-activity-contract.md;
//! activity-hook.js).
//!
//! herdr invokes the hook through a second `[[events]]` entry on
//! `pane.agent_status_changed`, independent of the alert notify hook
//! ([`run_herdr_activity`]). On tmux, `waycar notify` calls
//! [`run_tmux_activity`] from the agent hooks instead, and in a herdr-core
//! terminal [`run_core_activity`]. All triggers run the same flow against the
//! same state, so a Host with several backends keeps one producer (ADR 0014,
//! design §4.5):
//!
//! ```text
//! status ──> cheap exits (no activity registration / already ended)
//!   ──> latest-wins debounce via activity/claim.json
//!   ──> activity/send.lock (one run decides and sends at a time)
//!   ──> herdr agent list + tmux Agents (unless tmux_enabled is false)
//!       + core terminals (a running core, unless core_enabled is false)
//!   ──> suppress unchanged {pane: status} + progress + idle count vs last-state
//!   ──> seal one envelope per device ──> POST kind=liveactivity update/end
//!   ──> start grace ──> POST kind=liveactivity start (push-to-start)
//! ```
//!
//! A device with a live `live_activity` token gets updates and end. A device
//! whose `live_activity_start` registration has no running activity to update
//! gets one start per episode instead. Devices with neither send nothing;
//! `notify` flags do not gate this path. APNs 410 clears only the field whose
//! token it rejected. An `fcm` entry (Android) whose `live_activity.enabled`
//! is `true` takes updates and end at its own alert token: no activity token,
//! no push-to-start, only event and priority in plaintext (counts and the
//! timestamp stay inside the envelope). A 410 for it removes the whole entry.
//! While an episode is live, summaries are on and an Agent
//! is Working, a run keeps the detached plan-step tick
//! ([`crate::activity_tick`]) alive; it pushes progress-only changes between
//! status events through [`run_progress_update`].
//!
//! The JS is async; this port is blocking, and every outside effect goes
//! through a seam: the relay through [`Fetch`], time and sleeping through
//! [`Clock`], herdr and tmux through a [`Runner`], the detached tick through
//! the `start_tick` function. A hook never fails the agent: the entry points
//! return what the JS prints (and its exit code) instead of printing or
//! exiting.
//!
//! Differences from the JS, all on paths the JS leaves undefined:
//!
//! * Registration, state and herdr JSON is parsed as `JSON.parse` does, with
//!   one exception: a lone-surrogate escape (`\ud800`) becomes U+FFFD (as in
//!   [`parse_hook_input`]) instead of surviving as a lone surrogate, which a
//!   Rust string cannot hold. The JS would write that surrogate back out as an
//!   escape when it prunes the registration file.
//! * herdr runs under [`run_program`](crate::exec::run_program)'s 10 s limit;
//!   the JS had none for the herdr hook's `agent list`.

use std::collections::HashSet;
use std::fs::{self, DirBuilder, OpenOptions};
use std::io::{ErrorKind, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, UNIX_EPOCH};

use ring::digest::{SHA256, digest};
use ring::rand::{SecureRandom, SystemRandom};
use serde_json::{Map, Value, json};

use crate::activity_envelope::{canonical_activity_plaintext, encrypt_activity_envelope};
use crate::activity_plan_steps::{clear_plan_steps, read_plan_steps};
use crate::activity_rows::{RowLayout, parse_activity_row_layout};
use crate::activity_start::{
    ActivityDevice, EpisodeEvent, StoredStartState, is_host_id, plan_devices, read_start_state,
    save_start_state, start_fields,
};
use crate::activity_state::{
    BuildInput, CoreRow, Counts, TmuxInventory, build_activity_state, core_activity_inventory,
    eligible_progress_map, eligible_status_map, has_newly_blocked, idle_count, is_eligible_status,
    os_hostname, progress_for_panes, same_progress_map, same_status_map, short_host_name,
    tmux_activity_inventory, visible_pane_ids,
};
use crate::atomic::write_atomic;
use crate::base64;
use crate::core::{CoreCommand, CoreListing, CoreTerminal, is_core_pane_id, running_core};
use crate::deps::{Clock, Fetch};
use crate::display_text::optional_text;
use crate::env::Env;
use crate::error::{CliError, EXIT_FAILURE, EXIT_OK, Result};
use crate::exec::RunResult;
use crate::herdr::{HerdrCommand, herdr_command};
use crate::hook_session::parse_hook_input;
use crate::js_compat::{cmp_utf16, js_get, js_get_opt, js_strict_eq, locale_compare, non_null};
use crate::jsx;
use crate::notification_config::{NotificationConfig, read_notification_config};
use crate::notify_core::Provider;
use crate::paths::{home_dir, resolve_host_config};
use crate::sidebar_config::refresh_sidebar_snapshot_for_event;
use crate::state_machine::StateMachine;
use crate::summary::store::{clear_progress, read_summary};
use crate::tmux::{Runner, TmuxAgent, is_tmux_pane_id, list_agents_with};

const SEND_ATTEMPTS: u32 = 3;
const REQUEST_TIMEOUT: Duration = Duration::from_millis(10_000);
const KEY_BYTES: usize = 32;
const CT_BUDGET: usize = 2800;
const APNS_PAYLOAD_BUDGET: usize = 4096;
const RELAY_REQUEST_BUDGET: usize = 8192;
const STALE_AFTER_SECONDS: u64 = 900;
const SEND_LOCK_POLL: Duration = Duration::from_millis(25);
/// The longest a run holds the send lock: herdr's and tmux's probes, then per
/// device up to [`SEND_ATTEMPTS`] relay requests of [`REQUEST_TIMEOUT`] each.
/// A lock this old is left over (its holder was killed and its PID reused, or
/// it hung), not contention, whoever holds that PID now.
pub const SEND_LOCK_STALE_MS: u64 = 120_000;
/// A waiter fails its run rather than wait past the point where even a
/// left-over lock would have been broken.
pub const SEND_LOCK_TIMEOUT_MS: u64 = SEND_LOCK_STALE_MS + 30_000;
/// Payload degrade steps: 0 full, 1 no titles, 2 no rows, 3 no progress, 4 no
/// agents.
const LAST_DEGRADE_STEP: u32 = 4;

/// What a run needs from outside: the relay, the clock and a program runner
/// (herdr and tmux). Tests and the parity harness give each a fake.
#[derive(Clone, Copy)]
pub struct ActivityDeps<'a> {
    pub fetch: &'a dyn Fetch,
    pub clock: &'a dyn Clock,
    pub run: Runner<'a>,
}

/// What `startTick` receives (`ensureActivityTick`'s options): the detached
/// plan-step tick is started for this Host unless one already runs.
/// [`crate::activity_tick::start_tick`] is the production implementation.
#[derive(Debug, Clone, Copy)]
pub struct TickStart<'a> {
    pub config_dir: &'a Path,
    pub state_dir: &'a Path,
    pub herdr_bin: &'a str,
    pub herdr_required: bool,
    /// The environment the tick runs with (herdr's, with its PATH).
    pub env: &'a Env,
}

/// What an entry point that is a process's `main` prints and exits with.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ActivityOutcome {
    pub code: i32,
    /// Exactly what goes to stderr, line breaks included; empty on success.
    pub stderr: String,
}

// ---- the herdr event -------------------------------------------------------

struct StatusEvent {
    pane_id: String,
    status: String,
}

/// Parse `HERDR_PLUGIN_EVENT_JSON` leniently: require pane id and status only.
fn parse_status_event(raw: &str) -> Result<StatusEvent> {
    let parsed = parse_hook_input(raw)
        .ok_or_else(|| CliError::failure("HERDR_PLUGIN_EVENT_JSON is not JSON"))?;
    let data = js_get(&parsed, "data");
    let field = |name: &str| {
        data.and_then(|data| js_get(data, name))
            .and_then(Value::as_str)
    };
    let pane_id = field("pane_id")
        .filter(|id| !id.is_empty())
        .ok_or_else(|| CliError::failure("event data.pane_id missing"))?;
    let status = field("agent_status")
        .filter(|status| !status.is_empty())
        .ok_or_else(|| CliError::failure("event data.agent_status missing"))?;
    Ok(StatusEvent {
        pane_id: pane_id.to_string(),
        status: status.to_lowercase(),
    })
}

// ---- the registered devices ------------------------------------------------

/// The token to address: a device's update token for update/end, its
/// push-to-start token (plus host id) for start.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Target {
    provider: Provider,
    token: String,
    env: String,
    host_id: Option<String>,
}

/// A device whose registration entry can take a Live Activity push.
struct Device {
    /// The alert token, the device's stable identity across activity tokens.
    id: Option<String>,
    key: Vec<u8>,
    update: Option<Target>,
    start: Option<Target>,
    pinned_pane_ids: Option<Value>,
    row_layout: Option<RowLayout>,
    row_host_name: Option<String>,
}

impl ActivityDevice for Device {
    fn id(&self) -> Option<&str> {
        self.id.as_deref()
    }

    fn update_token(&self) -> Option<&str> {
        self.update.as_ref().map(|target| target.token.as_str())
    }

    fn has_start(&self) -> bool {
        self.start.is_some()
    }
}

/// `/^[0-9a-f]{16,200}$/`
fn is_activity_token(token: &str) -> bool {
    (16..=200).contains(&token.len())
        && token
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

/// `/^[A-Za-z0-9_:.\-]{50,512}$/`: an FCM registration token. The entry's own
/// alert token doubles as its Live Update target.
fn is_fcm_token(token: &str) -> bool {
    (50..=512).contains(&token.len())
        && token
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b':' | b'.' | b'-'))
}

fn apns_environment(value: Option<&Value>) -> Option<&str> {
    value
        .and_then(Value::as_str)
        .filter(|env| matches!(*env, "production" | "sandbox"))
}

fn plain_object(value: Option<&Value>) -> Option<&Map<String, Value>> {
    match value {
        Some(Value::Object(map)) => Some(map),
        _ => None,
    }
}

/// A file's JSON the way the hooks read their files: missing, unreadable or
/// not JSON is `None`.
fn read_json_file(path: &Path) -> Option<Value> {
    let bytes = fs::read(path).ok()?;
    parse_hook_input(&String::from_utf8_lossy(&bytes))
}

/// The registration file's parsed content when it is a version 1 file with a
/// `devices` array.
fn read_registration(config_dir: &Path) -> Option<Value> {
    let file = read_json_file(&config_dir.join("notifications.json"))?;
    let version = js_get(&file, "v").and_then(Value::as_f64);
    let devices = js_get(&file, "devices");
    (version == Some(1.0) && devices.is_some_and(Value::is_array)).then_some(file)
}

/// Devices whose registration entry can take a Live Activity push: `update`
/// when `live_activity` carries a plausible token, `start` when
/// `live_activity_start` carries a push-to-start token and host id. `notify`
/// flags do not apply; an entry with neither is skipped.
fn read_activity_devices(config_dir: &Path) -> Vec<Device> {
    let Some(file) = read_registration(config_dir) else {
        return Vec::new();
    };
    let Some(Value::Array(entries)) = js_get(&file, "devices") else {
        return Vec::new();
    };
    let mut devices = Vec::new();
    for entry in entries {
        let Some(key) = js_get(entry, "key").and_then(Value::as_str) else {
            continue;
        };
        let key = base64::decode(key);
        if key.len() != KEY_BYTES {
            continue;
        }
        let live = plain_object(js_get(entry, "live_activity"));
        let live_field = |name: &str| live.and_then(|live| live.get(name));
        match js_get(entry, "provider") {
            Some(Value::String(provider)) if provider == "fcm" => {
                // Android: eligible only when the app switched Live Updates
                // on. Unknown providers fall through and are skipped.
                if live_field("enabled") != Some(&Value::Bool(true)) {
                    continue;
                }
                let Some(token) = js_get(entry, "token")
                    .and_then(Value::as_str)
                    .filter(|token| is_fcm_token(token))
                else {
                    continue;
                };
                devices.push(Device {
                    id: Some(token.to_string()),
                    key,
                    update: Some(Target {
                        provider: Provider::Fcm,
                        token: token.to_string(),
                        env: apns_environment(js_get(entry, "env"))
                            .unwrap_or("production")
                            .to_string(),
                        host_id: None,
                    }),
                    start: None,
                    pinned_pane_ids: live_field("pinned_pane_ids").cloned(),
                    row_layout: parse_activity_row_layout(live_field("row_layout")),
                    row_host_name: optional_text(live_field("host_name")).map(str::to_string),
                });
                continue;
            }
            None => {}
            Some(Value::String(provider)) if provider == "apns" => {}
            Some(_) => continue,
        }
        let update = live_field("token")
            .and_then(Value::as_str)
            .filter(|token| is_activity_token(token))
            .and_then(|token| {
                let env = apns_environment(live_field("env"))
                    .or_else(|| apns_environment(js_get(entry, "env")))?;
                Some(Target {
                    provider: Provider::Apns,
                    token: token.to_string(),
                    env: env.to_string(),
                    host_id: None,
                })
            });
        let id = js_get(entry, "token")
            .and_then(Value::as_str)
            .filter(|token| !token.is_empty());
        let start_entry = plain_object(js_get(entry, "live_activity_start"));
        let start = (|| {
            id?;
            let start_entry = start_entry?;
            let token = start_entry
                .get("token")
                .and_then(Value::as_str)
                .filter(|token| is_activity_token(token))?;
            let host_id = start_entry.get("host_id").filter(|id| is_host_id(id))?;
            let env = apns_environment(js_get(entry, "env"))?;
            Some(Target {
                provider: Provider::Apns,
                token: token.to_string(),
                env: env.to_string(),
                host_id: host_id.as_str().map(str::to_string),
            })
        })();
        if update.is_none() && start.is_none() {
            continue;
        }
        devices.push(Device {
            id: id.map(str::to_string),
            key,
            update,
            start,
            pinned_pane_ids: live_field("pinned_pane_ids").cloned(),
            row_layout: parse_activity_row_layout(live_field("row_layout")),
            row_host_name: optional_text(live_field("host_name")).map(str::to_string),
        });
    }
    devices
}

/// Drop whole registration entries whose own alert `token` the relay reported
/// dead (FCM has no per-activity token to drop), preserving every other entry.
fn prune_entries(config_dir: &Path, tokens: &[String]) -> Result<()> {
    let path = config_dir.join("notifications.json");
    let Some(mut file) = read_json_file(&path) else {
        return Ok(());
    };
    if js_get(&file, "v").and_then(Value::as_f64) != Some(1.0) {
        return Ok(());
    }
    let Some(Value::Array(entries)) = file.get_mut("devices") else {
        return Ok(());
    };
    entries.retain(|entry| {
        !js_get(entry, "token")
            .and_then(Value::as_str)
            .is_some_and(|token| tokens.iter().any(|dead| dead == token))
    });
    write_atomic(&path, jsx::stringify(&file).as_bytes(), 0o600)?;
    Ok(())
}

/// Drop `field` (`live_activity` or `live_activity_start`) from entries whose
/// `field.token` APNs rejected, preserving the alert token, key, notify flags,
/// the other activity field, and anything this plugin does not understand.
fn prune_registrations(config_dir: &Path, field: &str, tokens: &[String]) -> Result<()> {
    let path = config_dir.join("notifications.json");
    let Some(mut file) = read_json_file(&path) else {
        return Ok(());
    };
    if js_get(&file, "v").and_then(Value::as_f64) != Some(1.0) {
        return Ok(());
    }
    let Some(Value::Array(entries)) = file.get_mut("devices") else {
        return Ok(());
    };
    for entry in entries {
        let rejected = js_get(entry, field)
            .and_then(|live| js_get(live, "token"))
            .and_then(Value::as_str)
            .is_some_and(|token| tokens.iter().any(|rejected| rejected == token));
        if rejected && let Value::Object(map) = entry {
            map.shift_remove(field);
        }
    }
    write_atomic(&path, jsx::stringify(&file).as_bytes(), 0o600)?;
    Ok(())
}

// ---- state files -----------------------------------------------------------

fn activity_dir(state_dir: &Path) -> PathBuf {
    state_dir.join("activity")
}

fn last_state_path(state_dir: &Path) -> PathBuf {
    activity_dir(state_dir).join("last-state.json")
}

fn claim_path(state_dir: &Path) -> PathBuf {
    activity_dir(state_dir).join("claim.json")
}

fn send_lock_path(state_dir: &Path) -> PathBuf {
    activity_dir(state_dir).join("send.lock")
}

/// `mkdirSync(activityDir, {recursive: true})`.
fn create_activity_dir(state_dir: &Path) -> std::io::Result<()> {
    DirBuilder::new()
        .recursive(true)
        .create(activity_dir(state_dir))
}

/// The last pushed state (`activity/last-state.json`), or `None` when none or
/// unreadable.
pub fn read_last_state(state_dir: &Path) -> Option<Value> {
    read_json_file(&last_state_path(state_dir))
        .filter(|state| state.is_object() || state.is_array())
}

fn write_last_state(state_dir: &Path, state: &Value) -> Result<()> {
    create_activity_dir(state_dir)?;
    write_atomic(
        &last_state_path(state_dir),
        jsx::stringify(state).as_bytes(),
        0o600,
    )?;
    Ok(())
}

/// This run's place in the debounce: the newest claim wins.
#[derive(Debug, Clone, Copy)]
struct Claim {
    pid: u32,
    claimed_at_ms: u64,
}

fn write_claim(state_dir: &Path, claim: Claim) -> Result<()> {
    create_activity_dir(state_dir)?;
    let value = json!({ "pid": claim.pid, "claimed_at_ms": claim.claimed_at_ms });
    write_atomic(
        &claim_path(state_dir),
        jsx::stringify(&value).as_bytes(),
        0o600,
    )?;
    Ok(())
}

fn claim_superseded(ours: Claim, state_dir: &Path) -> bool {
    let Some(latest) = read_json_file(&claim_path(state_dir)) else {
        return false;
    };
    if !latest.is_object() && !latest.is_array() {
        return false;
    }
    let Some(claimed_at) = js_get(&latest, "claimed_at_ms").and_then(Value::as_f64) else {
        return false;
    };
    let ours_at = ours.claimed_at_ms as f64;
    if claimed_at > ours_at {
        return true;
    }
    claimed_at == ours_at && !js_strict_eq(js_get(&latest, "pid"), Some(&json!(ours.pid)))
}

// ---- the send lock ---------------------------------------------------------

fn lock_holder(path: &Path) -> Option<String> {
    fs::read(path)
        .ok()
        .map(|bytes| String::from_utf8_lossy(&bytes).into_owned())
}

/// `process.kill(pid, 0)`; EPERM is alive, but another user's.
pub(crate) fn process_alive(pid: i64) -> bool {
    let Ok(pid) = libc::pid_t::try_from(pid) else {
        return false;
    };
    // SAFETY: signal 0 only checks that the process exists.
    let alive = unsafe { libc::kill(pid, 0) } == 0;
    alive || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

/// `Number.parseInt(text, 10)` when it is a number.
fn parse_int(text: &str) -> Option<i64> {
    let text = jsx::trim(text);
    let (negative, digits) = match text.as_bytes().first() {
        Some(b'-') => (true, &text[1..]),
        Some(b'+') => (false, &text[1..]),
        _ => (false, text),
    };
    let end = digits
        .bytes()
        .position(|byte| !byte.is_ascii_digit())
        .unwrap_or(digits.len());
    if end == 0 {
        return None;
    }
    // A run of digits too long for an i64 is a huge number in JS, no PID.
    let value: i64 = digits[..end].parse().unwrap_or(i64::MAX);
    Some(if negative { -value } else { value })
}

/// Older than `stale_ms`, or held by a PID that is gone.
fn lock_is_stale(path: &Path, stale_ms: u64, clock: &dyn Clock) -> bool {
    let Ok(modified) = fs::metadata(path).and_then(|meta| meta.modified()) else {
        return false;
    };
    let modified_ms = modified
        .duration_since(UNIX_EPOCH)
        .map_or(0.0, |elapsed| elapsed.as_secs_f64() * 1000.0);
    if clock.now_ms() as f64 - modified_ms > stale_ms as f64 {
        return true;
    }
    lock_holder(path)
        .as_deref()
        .and_then(parse_int)
        .is_some_and(|pid| pid > 0 && !process_alive(pid))
}

/// Remove a send lock left by a run that died (crash, SIGKILL) or outlived
/// `stale_ms`, so it cannot stall the Live Activity for good. `.break` admits
/// one breaker at a time, and that breaker re-checks the lock under it: a
/// waiter that judged it stale late never removes the lock a live run has
/// taken since. A breaker that died holding `.break` is itself broken by age.
fn break_stale_lock(path: &Path, stale_ms: u64, clock: &dyn Clock) -> Result<()> {
    if !lock_is_stale(path, stale_ms, clock) {
        return Ok(());
    }
    let mut breaker_name = path.as_os_str().to_owned();
    breaker_name.push(".break");
    let breaker = PathBuf::from(breaker_name);
    match OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&breaker)
    {
        Ok(mut file) => {
            let _ = file.write_all(std::process::id().to_string().as_bytes());
        }
        Err(error) if error.kind() == ErrorKind::AlreadyExists => {
            if lock_is_stale(&breaker, stale_ms, clock) {
                let _ = fs::remove_file(&breaker);
            }
            return Ok(());
        }
        Err(error) => return Err(error.into()),
    }
    if lock_is_stale(path, stale_ms, clock) {
        let _ = fs::remove_file(path);
    }
    let _ = fs::remove_file(&breaker);
    Ok(())
}

/// A random UUID (version 4), as `randomUUID()` makes one.
fn random_uuid() -> Result<String> {
    let mut bytes = [0u8; 16];
    SystemRandom::new()
        .fill(&mut bytes)
        .map_err(|_| CliError::failure("no secure random bytes"))?;
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
    Ok(format!(
        "{}-{}-{}-{}-{}",
        &hex[..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..]
    ))
}

/// How long a lock may be held before it is stale and how long a waiter
/// waits; tests shorten them.
#[derive(Debug, Clone, Copy)]
pub struct LockLimits {
    pub stale_ms: u64,
    pub timeout_ms: u64,
}

impl Default for LockLimits {
    fn default() -> Self {
        Self {
            stale_ms: SEND_LOCK_STALE_MS,
            timeout_ms: SEND_LOCK_TIMEOUT_MS,
        }
    }
}

/// Run `locked` holding `activity/send.lock`. The debounce only coalesces
/// invocations that overlap within it; one that starts after the winner's
/// debounce ended would otherwise read last-state before the winner wrote it
/// and push the same snapshot again. Under the lock, read last-state, decide,
/// send and write last-state form one step. The lock file appears whole (a
/// hard link to a written temp file) and names its holder: its PID, for the
/// dead-holder check, and a token, so a run whose lock was broken as stale
/// never removes the next holder's. Fails after `timeout_ms` of waiting.
pub fn with_send_lock<T>(
    state_dir: &Path,
    clock: &dyn Clock,
    limits: LockLimits,
    locked: impl FnOnce() -> Result<T>,
) -> Result<T> {
    create_activity_dir(state_dir)?;
    let path = send_lock_path(state_dir);
    let pid = std::process::id();
    let token = format!("{pid} {}", random_uuid()?);
    let mut temp_name = path.as_os_str().to_owned();
    temp_name.push(format!(".tmp-{pid}-{}", random_uuid()?));
    let temp = PathBuf::from(temp_name);
    OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temp)?
        .write_all(token.as_bytes())?;
    let deadline = clock.now_ms().saturating_add(limits.timeout_ms);
    let acquired = (|| -> Result<()> {
        loop {
            match fs::hard_link(&temp, &path) {
                Ok(()) => return Ok(()),
                Err(error) if error.kind() == ErrorKind::AlreadyExists => {}
                Err(error) => return Err(error.into()),
            }
            break_stale_lock(&path, limits.stale_ms, clock)?;
            if clock.now_ms() > deadline {
                return Err(CliError::failure(format!(
                    "timed out after {} ms waiting for the Live Activity send lock {}",
                    limits.timeout_ms,
                    path.display()
                )));
            }
            clock.sleep(SEND_LOCK_POLL);
        }
    })();
    let _ = fs::remove_file(&temp);
    acquired?;
    let result = locked();
    if lock_holder(&path).as_deref() == Some(token.as_str()) {
        let _ = fs::remove_file(&path);
    }
    result
}

// ---- the Host's inventory --------------------------------------------------

/// herdr's raw `agent list` rows; `herdr(args)` runs the CLI. Fails when it
/// does.
pub fn list_agents(herdr: &dyn Fn(&[&str]) -> RunResult) -> Result<Vec<Value>> {
    let result = herdr(&["agent", "list"]);
    let parsed = parse_hook_input(&result.stdout);
    if result.code != 0 {
        let detail = match jsx::trim(&result.stderr) {
            "" => jsx::trim(&result.stdout),
            stderr => stderr,
        };
        return Err(CliError::failure(format!(
            "agent list failed (exit {}): {detail}",
            result.code
        )));
    }
    match parsed
        .as_ref()
        .and_then(|parsed| js_get(parsed, "result"))
        .and_then(|result| js_get(result, "agents"))
    {
        Some(Value::Array(agents)) => Ok(agents.clone()),
        _ => Err(CliError::failure("agent list returned no agents array")),
    }
}

/// `JSON.parse(stdout)?.result?.[name]` of a successful herdr answer.
fn herdr_list(
    herdr: &dyn Fn(&[&str]) -> RunResult,
    args: &[&str],
    name: &str,
) -> Option<Vec<Value>> {
    let result = herdr(args);
    if result.code != 0 {
        return None;
    }
    match js_get(&parse_hook_input(&result.stdout)?, "result")
        .and_then(|result| js_get(result, name))?
    {
        Value::Array(entries) => Some(entries.clone()),
        _ => None,
    }
}

/// Resolve all workspace labels once per update. Labels are presentation-only,
/// so a Host that cannot answer still sends kind-only identities.
fn list_workspace_labels(herdr: &dyn Fn(&[&str]) -> RunResult) -> Map<String, Value> {
    let mut labels = Map::new();
    for workspace in herdr_list(herdr, &["workspace", "list"], "workspaces").unwrap_or_default() {
        let id = optional_text(js_get(&workspace, "workspace_id"));
        let label = optional_text(js_get(&workspace, "label"));
        if let (Some(id), Some(label)) = (id, label) {
            labels.insert(id.to_string(), Value::from(label));
        }
    }
    labels
}

#[derive(Default)]
struct RowContext {
    tabs: Map<String, Value>,
    panes: Map<String, Value>,
}

/// The key `new Map(entries.map(e => [e.id, e]))` dedupes by.
fn id_key(entry: &Value, name: &str) -> String {
    js_get(entry, name).map_or_else(|| "undefined".to_string(), jsx::stringify)
}

/// Read presentation context once per workspace, only for configured fields.
fn list_row_context(
    herdr: &dyn Fn(&[&str]) -> RunResult,
    herdr_agents: &[Value],
    devices: &[&Device],
) -> RowContext {
    let wants = |kind: &str| {
        devices.iter().any(|device| {
            device.row_layout.as_ref().is_some_and(|layout| {
                layout
                    .rows
                    .iter()
                    .any(|row| row.iter().any(|field| field.token == kind))
            })
        })
    };
    let mut context = RowContext::default();
    let mut workspaces: Vec<&str> = Vec::new();
    for agent in herdr_agents {
        let eligible = js_get(agent, "agent_status")
            .and_then(Value::as_str)
            .is_some_and(is_eligible_status);
        if eligible
            && let Some(workspace) = optional_text(js_get(agent, "workspace_id"))
            && !workspaces.contains(&workspace)
        {
            workspaces.push(workspace);
        }
    }
    for workspace in workspaces {
        for kind in ["tab", "pane"] {
            if !wants(kind) {
                continue;
            }
            let plural = format!("{kind}s");
            let Some(entries) =
                herdr_list(herdr, &[kind, "list", "--workspace", workspace], &plural)
            else {
                // Missing context suppresses only that field, never the activity.
                continue;
            };
            let id_name = format!("{kind}_id");
            let mut unique: Vec<(String, &Value)> = Vec::new();
            for entry in entries.iter().filter(|entry| {
                js_get(entry, "workspace_id").and_then(Value::as_str) == Some(workspace)
            }) {
                let key = id_key(entry, &id_name);
                match unique.iter_mut().find(|(seen, _)| *seen == key) {
                    Some(slot) => slot.1 = entry,
                    None => unique.push((key, entry)),
                }
            }
            let count = unique.len();
            for (index, (_, entry)) in unique.into_iter().enumerate() {
                let Some(id) = js_get(entry, &id_name).and_then(Value::as_str) else {
                    continue;
                };
                if kind == "tab" {
                    let mut tab = entry.as_object().cloned().unwrap_or_default();
                    tab.insert("position".into(), json!(index + 1));
                    tab.insert("count".into(), json!(count));
                    context.tabs.insert(id.to_string(), Value::Object(tab));
                } else {
                    context.panes.insert(id.to_string(), entry.clone());
                }
            }
        }
    }
    context
}

/// `TmuxAgent` in the shape `listTmuxAgents` rows have.
fn tmux_agent_value(agent: &TmuxAgent) -> Value {
    json!({
        "paneId": agent.pane_id,
        "sessionId": agent.session_id,
        "sessionName": agent.session_name,
        "windowId": agent.window_id,
        "windowName": agent.window_name,
        "agent": agent.agent,
        "status": agent.status,
        "title": agent.title,
        "cwd": agent.cwd,
    })
}

/// herdr-core's Agents in herdr's `agent list` shape: its live terminals that
/// reported a status. `ls --json` carries the status but neither the title,
/// the folder of the foreground program nor the labels, so each terminal an
/// envelope can list (Working, Blocked or Done) is asked for its full record;
/// one that vanished meanwhile or is no longer live is left out, and one core
/// will not describe keeps its listing line. An Err means core could not list.
fn core_agents(core: &CoreCommand, run: Runner<'_>) -> Result<Vec<Value>> {
    let mut found: Vec<(CoreListing, Option<CoreTerminal>)> = Vec::new();
    for listing in crate::core::list(core, run)? {
        if listing.state != "live" {
            continue;
        }
        let record = if listing.waycar_status().is_some_and(is_eligible_status) {
            match crate::core::get(core, run, &listing.address) {
                Ok(Some(record)) if record.is_live() => Some(record),
                Ok(_) => continue,
                Err(_) => None,
            }
        } else {
            None
        };
        found.push((listing, record));
    }
    let rows: Vec<CoreRow<'_>> = found
        .iter()
        .map(|(listing, record)| CoreRow {
            listing,
            record: record.as_ref(),
        })
        .collect();
    Ok(core_activity_inventory(&rows))
}

/// Zellij's session and tab names feed the same row renderer as tmux's.
fn zellij_agents(env: &Env, run: Runner<'_>) -> Option<TmuxInventory> {
    let zellij = crate::zellij::command(env, run)?;
    let agents = crate::zellij::inventory(&zellij, run).ok()?;
    let mut workspace_labels = Map::new();
    let mut tabs = Map::new();
    for row in &agents {
        if let (Some(id), Some(label)) = (
            row["workspace_id"].as_str(),
            row["workspace_label"].as_str(),
        ) {
            workspace_labels.insert(id.into(), label.into());
        }
        if let Some(id) = row["tab_id"].as_str() {
            tabs.insert(
                id.into(),
                json!({
                    "tab_id": id, "workspace_id": row["workspace_id"],
                    "label": row["tab_label"], "position": null, "count": 1,
                }),
            );
        }
    }
    Some(TmuxInventory {
        agents,
        workspace_labels,
        tabs,
    })
}

/// One run's Agent inventory: herdr's `agent list`, tmux's Agents, then
/// herdr-core's. The herdr hook requires herdr (a failed list fails the run,
/// as before tmux); the tmux and core triggers treat a missing or stopped
/// herdr as no herdr Agents. A tmux that is absent or has no server
/// contributes none either way, and neither does a core that is not given
/// (not installed, not running, or turned off) or cannot list.
/// Presentation lookups (workspace labels, tab and pane lists) ask herdr only
/// about its own Agents and only when herdr answered.
struct Inventory<'a> {
    herdr: &'a dyn Fn(&[&str]) -> RunResult,
    /// herdr's Agents, then tmux's, then core's.
    agents: Vec<Value>,
    herdr_count: usize,
    herdr_reachable: bool,
    tmux: Option<TmuxInventory>,
    zellij: Option<TmuxInventory>,
}

impl<'a> Inventory<'a> {
    fn read(
        herdr: &'a dyn Fn(&[&str]) -> RunResult,
        herdr_required: bool,
        tmux_enabled: bool,
        core: Option<&CoreCommand>,
        zellij_enabled: bool,
        env: &Env,
        run: Runner<'_>,
    ) -> Result<Self> {
        let (mut agents, herdr_reachable) = if herdr_required {
            (list_agents(herdr)?, true)
        } else {
            match list_agents(herdr) {
                Ok(agents) => (agents, true),
                Err(_) => (Vec::new(), false),
            }
        };
        let herdr_count = agents.len();
        let tmux = if tmux_enabled {
            list_agents_with(run, env).ok().map(|rows| {
                let rows: Vec<Value> = rows.iter().map(tmux_agent_value).collect();
                tmux_activity_inventory(&rows, &host_name())
            })
        } else {
            None
        };
        if let Some(tmux) = &tmux {
            agents.extend(tmux.agents.iter().cloned());
        }
        if let Some(core) = core {
            agents.extend(core_agents(core, run).unwrap_or_default());
        }
        let zellij = zellij_enabled.then(|| zellij_agents(env, run)).flatten();
        if let Some(zellij) = &zellij {
            agents.extend(zellij.agents.iter().cloned());
        }
        Ok(Self {
            herdr,
            agents,
            herdr_count,
            herdr_reachable,
            tmux,
            zellij,
        })
    }

    fn workspace_labels(&self) -> Map<String, Value> {
        let mut labels = if self.herdr_reachable {
            list_workspace_labels(self.herdr)
        } else {
            Map::new()
        };
        for inventory in [&self.tmux, &self.zellij].into_iter().flatten() {
            for (id, label) in &inventory.workspace_labels {
                labels.insert(id.clone(), label.clone());
            }
        }
        labels
    }

    fn row_context(&self, devices: &[&Device]) -> RowContext {
        let mut context = if self.herdr_reachable {
            list_row_context(self.herdr, &self.agents[..self.herdr_count], devices)
        } else {
            RowContext::default()
        };
        for inventory in [&self.tmux, &self.zellij].into_iter().flatten() {
            for (id, tab) in &inventory.tabs {
                context.tabs.insert(id.clone(), tab.clone());
            }
        }
        context
    }
}

/// The Host's name as `os.hostname()` reports it.
fn host_name() -> String {
    os_hostname().unwrap_or_default()
}

// ---- the payload -----------------------------------------------------------

/// Hash of what update pushes depend on besides statuses: tokens and
/// preferences. SHA-256 over `JSON.stringify` of the devices' entries sorted
/// by token with `localeCompare`.
fn device_preferences(devices: &[&Device]) -> String {
    let mut entries: Vec<(&str, Value)> = devices
        .iter()
        .filter_map(|device| {
            let update = device.update.as_ref()?;
            let mut entry = Map::new();
            entry.insert("token".into(), Value::from(update.token.as_str()));
            entry.insert("env".into(), Value::from(update.env.as_str()));
            if let Some(pins) = &device.pinned_pane_ids {
                entry.insert("pins".into(), pins.clone());
            }
            entry.insert(
                "layout".into(),
                device
                    .row_layout
                    .as_ref()
                    .map_or(Value::Null, RowLayout::to_json),
            );
            entry.insert(
                "host".into(),
                device
                    .row_host_name
                    .as_deref()
                    .map_or(Value::Null, Value::from),
            );
            Some((update.token.as_str(), Value::Object(entry)))
        })
        .collect();
    entries.sort_by(|(left, _), (right, _)| locale_compare(left, right));
    let text = jsx::stringify(&Value::Array(
        entries.into_iter().map(|(_, entry)| entry).collect(),
    ));
    digest(&SHA256, text.as_bytes())
        .as_ref()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn drop_titles(plaintext: &Value) -> Map<String, Value> {
    let agents = js_get(plaintext, "agents")
        .and_then(Value::as_array)
        .map_or(&[][..], Vec::as_slice);
    let agents: Vec<Value> = agents
        .iter()
        .map(|agent| {
            let mut entry = Map::new();
            let get = |name: &str| js_get(agent, name).cloned().unwrap_or(Value::Null);
            entry.insert("kind".into(), get("kind"));
            entry.insert("pane".into(), get("pane"));
            if let Some(progress) = js_get(agent, "progress") {
                entry.insert("progress".into(), progress.clone());
            }
            if let Some(rows) = js_get(agent, "rows").filter(|rows| rows.is_array()) {
                entry.insert("rows".into(), rows.clone());
            }
            entry.insert("status".into(), get("status"));
            if let Some(workspace) = js_get(agent, "workspace")
                .filter(|workspace| workspace.as_str().is_some_and(|text| !text.is_empty()))
            {
                entry.insert("workspace".into(), workspace.clone());
            }
            Value::Object(entry)
        })
        .collect();
    let mut content = Map::new();
    content.insert("agents".into(), Value::Array(agents));
    content.insert(
        "host".into(),
        js_get(plaintext, "host").cloned().unwrap_or(Value::Null),
    );
    content.insert(
        "v".into(),
        js_get(plaintext, "v").cloned().unwrap_or(Value::Null),
    );
    content
}

/// The plaintext a producer sends at degrade `step` under the ciphertext cap:
/// 0 as built, 1 without titles and legacy names, 2 also without rows, 3 also
/// without progress, 4 ([`LAST_DEGRADE_STEP`]) with `agents: []`. Exported for
/// the shared degrade vector.
pub fn plaintext_at_step(plaintext: &Value, step: u32) -> Value {
    if step == 0 {
        return plaintext.clone();
    }
    if step >= LAST_DEGRADE_STEP {
        return json!({
            "agents": [],
            "host": js_get(plaintext, "host"),
            "v": js_get(plaintext, "v"),
        });
    }
    let mut content = drop_titles(plaintext);
    if let Some(Value::Array(agents)) = content.get_mut("agents") {
        for agent in agents {
            if let Value::Object(agent) = agent {
                if step >= 2 {
                    agent.shift_remove("rows");
                }
                if step >= 3 {
                    agent.shift_remove("progress");
                }
            }
        }
    }
    Value::Object(content)
}

/// One push to build: `target` is the token to address (see [`Target`]).
struct Request<'a> {
    target: &'a Target,
    event: &'static str,
    priority: u32,
    timestamp: u64,
    counts: Counts,
}

/// The APNs `aps` object the relay will build, mirrored for size budgeting.
fn projected_apns_bytes(envelope: &Value, request: &Request<'_>) -> usize {
    // FCM carries no `aps` object; the relay body bound covers its payload.
    if request.target.provider == Provider::Fcm {
        return 0;
    }
    let mut aps = Map::new();
    aps.insert("timestamp".into(), json!(request.timestamp));
    aps.insert("event".into(), json!(request.event));
    aps.insert(
        "content-state".into(),
        json!({ "counts": request.counts.to_json(), "envelope": envelope }),
    );
    if request.event == "end" {
        aps.insert("dismissal-date".into(), json!(request.timestamp));
    } else {
        aps.insert(
            "stale-date".into(),
            json!(request.timestamp + STALE_AFTER_SECONDS),
        );
    }
    if request.event == "start" {
        let fields = start_fields(request.target.host_id.as_deref().unwrap_or_default());
        aps.insert("attributes-type".into(), fields["attributes_type"].clone());
        aps.insert("attributes".into(), fields["attributes"].clone());
        aps.insert("alert".into(), fields["alert"].clone());
        aps.insert("input-push-token".into(), json!(1));
    }
    jsx::stringify(&json!({ "aps": aps })).len()
}

/// The relay request body; `target` is the token to address.
fn relay_body(request: &Request<'_>, envelope: &str) -> Value {
    if request.target.provider == Provider::Fcm {
        // Counts and the timestamp stay inside the envelope; only event and
        // priority are plaintext. No push-to-start exists, so a start maps to
        // an update.
        return json!({
            "provider": "fcm",
            "kind": "liveactivity",
            "token": request.target.token,
            "env": request.target.env,
            "event": if request.event == "end" { "end" } else { "update" },
            "priority": request.priority,
            "envelope": envelope,
        });
    }
    let mut body = Map::new();
    body.insert("kind".into(), json!("liveactivity"));
    body.insert("token".into(), json!(request.target.token));
    body.insert("env".into(), json!(request.target.env));
    body.insert("event".into(), json!(request.event));
    body.insert("priority".into(), json!(request.priority));
    body.insert("timestamp".into(), json!(request.timestamp));
    body.insert("counts".into(), request.counts.to_json());
    body.insert("envelope".into(), json!(envelope));
    if request.event == "end" {
        body.insert("dismissal_date".into(), json!(request.timestamp));
    } else {
        body.insert(
            "stale_date".into(),
            json!(request.timestamp + STALE_AFTER_SECONDS),
        );
    }
    if request.event == "start"
        && let Value::Object(fields) =
            start_fields(request.target.host_id.as_deref().unwrap_or_default())
    {
        body.extend(fields);
    }
    Value::Object(body)
}

fn envelope_fits(envelope: &str, request: &Request<'_>) -> bool {
    let Some(parsed) = parse_hook_input(envelope) else {
        return false;
    };
    if js_get(&parsed, "ct")
        .and_then(Value::as_str)
        .is_some_and(|ct| jsx::utf16_len(ct) > CT_BUDGET)
    {
        return false;
    }
    if projected_apns_bytes(&parsed, request) > APNS_PAYLOAD_BUDGET {
        return false;
    }
    jsx::stringify(&relay_body(request, envelope)).len() <= RELAY_REQUEST_BUDGET
}

/// The degrade steps that change the plaintext, in order: a step with nothing
/// to drop (no titles, rows, or progress) is skipped rather than resent.
fn degrade_candidates(plaintext: &Value) -> Result<Vec<Value>> {
    let mut candidates = Vec::new();
    let mut previous: Option<String> = None;
    for step in 0..=LAST_DEGRADE_STEP {
        let content = plaintext_at_step(plaintext, step);
        let canonical = canonical_activity_plaintext(&content)
            .map_err(|error| CliError::failure(error.message))?;
        if previous.as_deref() != Some(canonical.as_str()) {
            candidates.push(content);
        }
        previous = Some(canonical);
    }
    Ok(candidates)
}

fn seal_candidate(candidate: &Value, key: &[u8]) -> Result<String> {
    encrypt_activity_envelope(candidate, key, None)
        .map_err(|error| CliError::failure(error.message))
}

/// The first candidate that fits the budgets, else the last one.
fn seal_fitting(
    candidates: &[Value],
    key: &[u8],
    request: &Request<'_>,
) -> Result<(String, usize)> {
    let mut index = 0;
    let mut envelope = seal_candidate(&candidates[index], key)?;
    while index < candidates.len() - 1 && !envelope_fits(&envelope, request) {
        index += 1;
        envelope = seal_candidate(&candidates[index], key)?;
    }
    Ok((envelope, index))
}

// ---- the relay -------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Pushed {
    Ok,
    /// APNs 410: the activity token is gone.
    Pruned,
    /// Relay-origin 413.
    TooLarge,
}

/// `text.slice(0, units)`; a surrogate pair cut in half is the U+FFFD the
/// lone surrogate would print as.
fn js_slice(text: &str, units: usize) -> String {
    let mut out = String::new();
    let mut used = 0;
    for ch in text.chars() {
        let width = ch.len_utf16();
        if used + width > units {
            if used < units {
                out.push('\u{FFFD}');
            }
            break;
        }
        out.push(ch);
        used += width;
    }
    out
}

fn is_relay_origin_413(detail: &str) -> bool {
    parse_hook_input(detail)
        .as_ref()
        .and_then(|parsed| js_get(parsed, "error"))
        .is_some_and(Value::is_string)
}

/// The first eight characters of a token, for messages.
fn token_prefix(token: &str) -> String {
    js_slice(token, 8)
}

/// POST one Live Activity push. Transient failures (network, 429, 5xx) retry up
/// to [`SEND_ATTEMPTS`]. Other conclusive failures are errors.
fn post_push(
    config: &NotificationConfig,
    deps: &ActivityDeps<'_>,
    token: &str,
    body: &Value,
) -> Result<Pushed> {
    let url = format!("{}/push", config.relay_url);
    let mut last_failure = String::new();
    for attempt in 1..=SEND_ATTEMPTS {
        if attempt > 1 {
            deps.clock
                .sleep(Duration::from_millis(config.retry_delay_ms));
        }
        let response = match deps.fetch.post_json(&url, &[], body, REQUEST_TIMEOUT) {
            Ok(response) => response,
            Err(error) => {
                last_failure = format!("relay unreachable: {error}");
                continue;
            }
        };
        if (200..300).contains(&response.status) {
            return Ok(Pushed::Ok);
        }
        let detail = js_slice(&response.body, 200);
        if response.status == 410 {
            return Ok(Pushed::Pruned);
        }
        if response.status == 413 && is_relay_origin_413(&detail) {
            return Ok(Pushed::TooLarge);
        }
        last_failure = format!("relay answered {}: {detail}", response.status);
        if response.status != 429 && response.status < 500 {
            break;
        }
    }
    Err(CliError::failure(format!(
        "push for token {}… failed: {last_failure}",
        token_prefix(token)
    )))
}

/// Seal and push one device's content, degrading the payload while the relay
/// says it is too large. `Ok` or `Pruned`; anything else is an error.
fn deliver(
    config: &NotificationConfig,
    deps: &ActivityDeps<'_>,
    device: &Device,
    plaintext: &Value,
    request: &Request<'_>,
) -> Result<Pushed> {
    let candidates = degrade_candidates(plaintext)?;
    let (mut envelope, mut index) = seal_fitting(&candidates, &device.key, request)?;
    loop {
        let body = relay_body(request, &envelope);
        match post_push(config, deps, &request.target.token, &body)? {
            outcome @ (Pushed::Ok | Pushed::Pruned) => return Ok(outcome),
            Pushed::TooLarge if index < candidates.len() - 1 => {
                index += 1;
                envelope = seal_candidate(&candidates[index], &device.key)?;
            }
            Pushed::TooLarge => {
                return Err(CliError::failure(format!(
                    "push for token {}… failed: payload too large",
                    token_prefix(&request.target.token)
                )));
            }
        }
    }
}

// ---- one run ---------------------------------------------------------------

/// What every run reads and writes: the Host's directories and herdr. `home`
/// is where herdr-core's usual install directories are looked for (none: no
/// core Agents).
struct Host<'a> {
    config_dir: &'a Path,
    state_dir: &'a Path,
    herdr: &'a HerdrCommand,
    herdr_required: bool,
    env: &'a Env,
    home: Option<&'a Path>,
}

impl Host<'_> {
    fn run_herdr(&self, deps: &ActivityDeps<'_>, args: &[&str]) -> RunResult {
        (deps.run)(&self.herdr.bin, args, &self.herdr.env)
    }

    /// herdr-core, when the Host's config has core on and a core already
    /// runs: this is never what starts one.
    fn running_core(
        &self,
        config: &NotificationConfig,
        deps: &ActivityDeps<'_>,
    ) -> Option<CoreCommand> {
        if !config.core_enabled {
            return None;
        }
        running_core(self.env, self.home?, deps.run)
    }
}

fn read_config(config_dir: &Path) -> Result<NotificationConfig> {
    read_notification_config(&config_dir.to_string_lossy()).map_err(CliError::failure)
}

/// The content of one run, kept for the start half: it asks for each device's
/// own envelope, after the grace.
struct Content {
    agents: Vec<Value>,
    host_name: String,
    workspace_labels: Map<String, Value>,
    context: RowContext,
    progress: Map<String, Value>,
    empty: bool,
}

impl Content {
    fn for_device(&self, device: &Device) -> (Counts, Value) {
        let mut input = BuildInput::new(&self.agents, &self.host_name);
        input.pinned_pane_ids = device.pinned_pane_ids.as_ref();
        input.workspace_labels = &self.workspace_labels;
        input.row_layout = device.row_layout.as_ref();
        input.row_host_name = device.row_host_name.as_deref();
        input.tabs = &self.context.tabs;
        input.panes = &self.context.panes;
        input.progress = &self.progress;
        let state = build_activity_state(&input);
        if self.empty {
            (
                Counts::default(),
                json!({
                    "agents": [],
                    "host": state.plaintext_object.get("host"),
                    "v": 1,
                }),
            )
        } else {
            (state.counts, state.plaintext_object)
        }
    }
}

/// What a delivered run stores as `activity/last-state.json`.
struct LastState {
    statuses: Map<String, Value>,
    idle: u32,
    progress: Map<String, Value>,
    visible: Vec<String>,
    preferences: String,
    ended: bool,
}

impl LastState {
    fn to_value(&self, sent_at_ms: u64) -> Value {
        json!({
            "sent_at_ms": sent_at_ms,
            "statuses": self.statuses,
            "idle": self.idle,
            "progress": self.progress,
            "visible": self.visible,
            "preferences": self.preferences,
            "ended": self.ended,
        })
    }
}

/// What the update half hands the start half.
struct Sent {
    start_candidates: usize,
    content: Content,
    delivered: bool,
    last_state: LastState,
    failures: Vec<String>,
}

/// `Object.values(statuses ?? {}).includes("working")` of a stored map.
fn has_working_status(statuses: Option<&Value>) -> bool {
    match statuses {
        Some(Value::Object(map)) => map
            .values()
            .any(|status| status.as_str() == Some("working")),
        Some(Value::Array(items)) => items
            .iter()
            .any(|status| status.as_str() == Some("working")),
        _ => false,
    }
}

/// Make sure the plan-step tick runs while it has work: an episode was
/// delivered and has not ended, AI summaries are on (progress lives in their
/// store), and the last pushed state has a Working Agent. The tick holds its
/// own single-instance lock, so a live one is left alone.
fn keep_tick_alive(
    config: &NotificationConfig,
    host: &Host<'_>,
    start_tick: &dyn Fn(&TickStart<'_>),
) {
    if !config.summary_enabled {
        return;
    }
    let Some(last_state) = read_last_state(host.state_dir) else {
        return;
    };
    if js_get(&last_state, "ended") == Some(&Value::Bool(true))
        || !has_working_status(js_get(&last_state, "statuses"))
    {
        return;
    }
    start_tick(&TickStart {
        config_dir: host.config_dir,
        state_dir: host.state_dir,
        herdr_bin: &host.herdr.bin,
        herdr_required: host.herdr_required,
        env: &host.herdr.env,
    });
}

/// One Live Activity run for a status change, shared by both triggers.
fn run_activity(
    host: &Host<'_>,
    status: &str,
    deps: &ActivityDeps<'_>,
    start_tick: &dyn Fn(&TickStart<'_>),
) -> Result<()> {
    let config = read_config(host.config_dir)?;

    // Cheap exits before burning a debounce process on a no-op.
    if read_activity_devices(host.config_dir).is_empty() {
        return Ok(());
    }
    if read_last_state(host.state_dir)
        .is_some_and(|state| js_get(&state, "ended") == Some(&Value::Bool(true)))
        && !is_eligible_status(status)
    {
        return Ok(());
    }

    let claim = Claim {
        pid: std::process::id(),
        claimed_at_ms: deps.clock.now_ms(),
    };
    write_claim(host.state_dir, claim)?;
    deps.clock
        .sleep(Duration::from_millis(config.activity_debounce_ms));
    let sent = with_send_lock(host.state_dir, deps.clock, LockLimits::default(), || {
        send_updates(&config, host, Some(claim), deps, false)
    })?;
    let mut failures = Vec::new();
    if let Some(sent) = sent {
        failures = sent.failures;
        if sent.start_candidates > 0 {
            start_activities(
                &config,
                host,
                claim,
                deps,
                &sent.content,
                &mut failures,
                (!sent.delivered).then_some(&sent.last_state),
            )?;
        }
    }
    keep_tick_alive(&config, host, start_tick);
    if failures.is_empty() {
        Ok(())
    } else {
        Err(CliError::failure(failures.join("; ")))
    }
}

/// The inputs of one progress-only push for the plan-step tick.
#[derive(Debug, Clone, Copy)]
pub struct ProgressRequest<'a> {
    pub config_dir: &'a Path,
    pub state_dir: &'a Path,
    pub herdr: &'a HerdrCommand,
    pub herdr_required: bool,
    /// tmux's environment.
    pub env: &'a Env,
}

/// One progress-only push for the plan-step tick: the same inventory,
/// content, dedupe and delivery as a status run, under the same send lock,
/// but with no debounce claim and no push-to-start; it sends only when the
/// live episode's statuses are the ones last pushed (see [`send_updates`]).
/// Every push it makes is priority 5. Returns whether an update was delivered.
pub fn run_progress_update(request: &ProgressRequest<'_>, deps: &ActivityDeps<'_>) -> Result<bool> {
    let config = read_config(request.config_dir)?;
    let home = home_dir(request.env);
    let host = Host {
        config_dir: request.config_dir,
        state_dir: request.state_dir,
        herdr: request.herdr,
        herdr_required: request.herdr_required,
        env: request.env,
        home: home.as_deref(),
    };
    let sent = with_send_lock(host.state_dir, deps.clock, LockLimits::default(), || {
        send_updates(&config, &host, None, deps, true)
    })?;
    let Some(sent) = sent else {
        return Ok(false);
    };
    if sent.failures.is_empty() {
        Ok(sent.delivered)
    } else {
        Err(CliError::failure(sent.failures.join("; ")))
    }
}

/// The update half of a run, under the send lock: last-state is read here, not
/// before the debounce, so a run that finished meanwhile counts. `None` when
/// superseded or when nothing is left to do, else what the start half needs.
/// `progress_only` (the plan-step tick, which holds no claim) sends only while
/// a delivered episode is live with the statuses it last sent: a status change
/// belongs to the status hooks and their priority rule. It never starts an
/// activity.
fn send_updates(
    config: &NotificationConfig,
    host: &Host<'_>,
    claim: Option<Claim>,
    deps: &ActivityDeps<'_>,
    progress_only: bool,
) -> Result<Option<Sent>> {
    if claim.is_some_and(|claim| claim_superseded(claim, host.state_dir)) {
        return Ok(None);
    }

    let devices = read_activity_devices(host.config_dir);
    if devices.is_empty() {
        return Ok(None);
    }
    let last_state = read_last_state(host.state_dir);
    let ended = |state: &Option<Value>| {
        state
            .as_ref()
            .is_some_and(|state| js_get(state, "ended") == Some(&Value::Bool(true)))
    };
    if progress_only && (last_state.is_none() || ended(&last_state)) {
        return Ok(None);
    }

    let herdr = |args: &[&str]| host.run_herdr(deps, args);
    let inventory = Inventory::read(
        &herdr,
        host.herdr_required,
        config.tmux_enabled,
        host.running_core(config, deps).as_ref(),
        config.zellij_enabled,
        host.env,
        deps.run,
    )?;
    let agents = &inventory.agents;
    let statuses = eligible_status_map(agents);
    let idle = idle_count(agents);
    let empty = statuses.is_empty();
    let previous = non_null(js_get_opt(last_state.as_ref(), "statuses"));
    if progress_only && !same_status_map(&statuses, previous) {
        return Ok(None);
    }
    // Progress comes from the summary store and the plan-step tick's map,
    // which exist only while the user has AI summaries on; anything left
    // behind after switching off is ignored.
    let progress = if config.summary_enabled {
        eligible_progress_map(
            agents,
            |pane| read_summary(&host.config_dir.to_string_lossy(), pane),
            &read_plan_steps(host.state_dir),
        )
    } else {
        Map::new()
    };
    let mut start_state: StoredStartState = read_start_state(host.state_dir);
    let planned = plan_devices(&devices, &mut start_state.episodes, empty);
    let update_devices = planned.update_devices;
    let start_candidates = if progress_only {
        Vec::new()
    } else {
        planned.start_candidates
    };
    let preferences = device_preferences(&update_devices);
    // Only progress some update device can see is part of the dedupe key: a
    // change on an Agent past the cap would push an identical envelope.
    let mut visible: Vec<String> = Vec::new();
    for device in &update_devices {
        for pane in visible_pane_ids(agents, device.pinned_pane_ids.as_ref()) {
            if !visible.contains(&pane) {
                visible.push(pane);
            }
        }
    }
    visible.sort_by(|left, right| cmp_utf16(left, right));
    let visible_set: HashSet<String> = visible.iter().cloned().collect();
    let visible_progress = progress_for_panes(&progress, &visible_set);
    // The idle chip is part of the dedupe key, so an idle-only change pushes
    // at priority 5. State written before idle existed lacks it and pushes
    // once. Progress is part of it too, so a plan-step-only change pushes at 5.
    let unchanged = previous.is_some()
        && same_status_map(&statuses, previous)
        && js_strict_eq(js_get_opt(last_state.as_ref(), "idle"), Some(&json!(idle)))
        && js_get_opt(last_state.as_ref(), "preferences").and_then(Value::as_str)
            == Some(preferences.as_str())
        && same_progress_map(
            &visible_progress,
            js_get_opt(last_state.as_ref(), "progress"),
        );
    let send_update = !update_devices.is_empty() && !unchanged && !(empty && ended(&last_state));
    if !send_update && start_candidates.is_empty() {
        save_start_state(host.state_dir, &start_state)?;
        return Ok(None);
    }

    let targets: Vec<&Device> = if send_update {
        update_devices
            .iter()
            .chain(&start_candidates)
            .copied()
            .collect()
    } else {
        start_candidates.clone()
    };
    let workspace_labels = if empty {
        Map::new()
    } else {
        inventory.workspace_labels()
    };
    let context = if empty {
        RowContext::default()
    } else {
        inventory.row_context(&targets)
    };
    let start_count = start_candidates.len();
    let last = LastState {
        statuses,
        idle,
        progress: visible_progress,
        visible,
        preferences,
        ended: empty,
    };
    let newly_blocked = has_newly_blocked(&last.statuses, previous);
    let content = Content {
        agents: inventory.agents,
        host_name: short_host_name(&host_name()),
        workspace_labels,
        context,
        progress,
        empty,
    };

    let mut failures = Vec::new();
    let mut delivered = false;
    if send_update {
        let event = if empty { "end" } else { "update" };
        let priority = if newly_blocked { 10 } else { 5 };
        let timestamp = deps.clock.now_ms() / 1000;
        let mut pruned: Vec<String> = Vec::new();
        let mut pruned_entries: Vec<String> = Vec::new();
        for device in update_devices {
            let Some(target) = &device.update else {
                continue;
            };
            let (counts, plaintext) = content.for_device(device);
            let request = Request {
                target,
                event,
                priority,
                timestamp,
                counts,
            };
            let answered = |delivered: bool| EpisodeEvent::UpdateAnswered {
                id: device.id.clone(),
                token: target.token.clone(),
                fcm: target.provider == Provider::Fcm,
                ending: empty,
                delivered,
                at_ms: deps.clock.now_ms() as i64,
            };
            match deliver(config, deps, device, &plaintext, &request) {
                Ok(Pushed::Ok) => {
                    delivered = true;
                    // An end's token can never take an update again.
                    let _ = start_state.episodes.handle(answered(true));
                }
                Ok(_) if target.provider == Provider::Fcm => {
                    if !pruned_entries.contains(&target.token) {
                        pruned_entries.push(target.token.clone());
                    }
                }
                Ok(_) => {
                    if !pruned.contains(&target.token) {
                        pruned.push(target.token.clone());
                    }
                    // The user dismissed it (or it expired): no push-to-start
                    // brings it back before the episode ends.
                    let _ = start_state.episodes.handle(answered(false));
                }
                Err(error) => failures.push(error.message().to_string()),
            }
        }
        if !pruned.is_empty() {
            prune_registrations(host.config_dir, "live_activity", &pruned)?;
        }
        if !pruned_entries.is_empty() {
            prune_entries(host.config_dir, &pruned_entries)?;
        }
        if delivered {
            write_last_state(host.state_dir, &last.to_value(deps.clock.now_ms()))?;
        }
    }
    save_start_state(host.state_dir, &start_state)?;
    Ok(Some(Sent {
        start_candidates: start_count,
        content,
        delivered,
        last_state: last,
        failures,
    }))
}

/// Push-to-start, after a grace period that lets a foregrounded app start its
/// own activity and register its token first; a device that gained a live
/// update token meanwhile is skipped. A newer invocation that claimed the
/// debounce during the grace takes over the decision. Start state is re-read
/// after the grace, under the send lock, so an overlapping invocation's start
/// is never repeated. `last_state`, when given, is written once a start is
/// delivered.
fn start_activities(
    config: &NotificationConfig,
    host: &Host<'_>,
    claim: Claim,
    deps: &ActivityDeps<'_>,
    content: &Content,
    failures: &mut Vec<String>,
    last_state: Option<&LastState>,
) -> Result<()> {
    deps.clock
        .sleep(Duration::from_millis(config.activity_start_grace_ms));
    with_send_lock(host.state_dir, deps.clock, LockLimits::default(), || {
        if claim_superseded(claim, host.state_dir) {
            return Ok(());
        }
        let mut start_state = read_start_state(host.state_dir);
        let devices = read_activity_devices(host.config_dir);
        let planned = plan_devices(&devices, &mut start_state.episodes, false);
        let mut pruned: Vec<String> = Vec::new();
        let mut started = false;
        let timestamp = deps.clock.now_ms() / 1000;
        for device in planned.start_candidates {
            let Some(target) = &device.start else {
                continue;
            };
            let (counts, plaintext) = content.for_device(device);
            // Once per episode, so the start alert's priority budget is
            // negligible.
            let request = Request {
                target,
                event: "start",
                priority: 10,
                timestamp,
                counts,
            };
            match deliver(config, deps, device, &plaintext, &request) {
                Ok(Pushed::Ok) => {
                    started = true;
                    let _ = start_state.episodes.handle(EpisodeEvent::StartDelivered {
                        id: device.id.clone(),
                        at_ms: deps.clock.now_ms() as i64,
                    });
                }
                Ok(_) => {
                    if !pruned.contains(&target.token) {
                        pruned.push(target.token.clone());
                    }
                }
                Err(error) => failures.push(error.message().to_string()),
            }
        }
        if !pruned.is_empty() {
            prune_registrations(host.config_dir, "live_activity_start", &pruned)?;
        }
        save_start_state(host.state_dir, &start_state)?;
        if started && let Some(last_state) = last_state {
            write_last_state(host.state_dir, &last_state.to_value(deps.clock.now_ms()))?;
        }
        Ok(())
    })
}

// ---- entry points ----------------------------------------------------------

/// An idle or done status ends the pane's turn: drop its stored progress
/// (summary-store `clear_progress`) and the tick's steps, so the next turn
/// never starts from the old steps or phase. Runs on every status event,
/// before any exit, whether or not a Live Activity is registered.
fn end_turn_progress(
    config_dir: &Path,
    state_dir: &Path,
    pane_id: &str,
    status: &str,
) -> Result<()> {
    if status != "idle" && status != "done" {
        return Ok(());
    }
    clear_progress(&config_dir.to_string_lossy(), pane_id)?;
    clear_plan_steps(state_dir, pane_id)?;
    Ok(())
}

fn require_env<'a>(env: &'a Env, name: &str) -> Result<&'a str> {
    env.non_empty(name).ok_or_else(|| {
        CliError::failure(format!(
            "{name} is not set; this script must run as a herdr event hook"
        ))
    })
}

fn herdr_activity(
    env: &Env,
    deps: &ActivityDeps<'_>,
    start_tick: &dyn Fn(&TickStart<'_>),
    stderr: &mut String,
) -> Result<()> {
    let config_dir = require_env(env, "HERDR_PLUGIN_CONFIG_DIR")?;
    if let Some(line) = refresh_sidebar_snapshot_for_event(Path::new(config_dir), env) {
        stderr.push_str(&line);
        stderr.push('\n');
    }
    let event_json = require_env(env, "HERDR_PLUGIN_EVENT_JSON")?;
    let state_dir = require_env(env, "HERDR_PLUGIN_STATE_DIR")?;
    let bin_path = require_env(env, "HERDR_BIN_PATH")?;

    let event = parse_status_event(event_json)?;
    let (config_dir, state_dir) = (Path::new(config_dir), Path::new(state_dir));
    end_turn_progress(config_dir, state_dir, &event.pane_id, &event.status)?;
    let herdr = HerdrCommand {
        bin: bin_path.to_string(),
        env: env.clone(),
    };
    let home = home_dir(env);
    let host = Host {
        config_dir,
        state_dir,
        herdr: &herdr,
        herdr_required: true,
        env,
        home: home.as_deref(),
    };
    run_activity(&host, &event.status, deps, start_tick)
}

/// herdr `[[events]]` entry point (the JS `main`): the event comes in
/// `HERDR_PLUGIN_EVENT_JSON`, with `HERDR_PLUGIN_CONFIG_DIR`,
/// `HERDR_PLUGIN_STATE_DIR` and `HERDR_BIN_PATH` as herdr injects them; herdr
/// is required. A failure is `activity-hook: <message>` and exit 1.
pub fn run_herdr_activity(
    env: &Env,
    deps: &ActivityDeps<'_>,
    start_tick: &dyn Fn(&TickStart<'_>),
) -> ActivityOutcome {
    let mut stderr = String::new();
    match herdr_activity(env, deps, start_tick, &mut stderr) {
        Ok(()) => ActivityOutcome {
            code: EXIT_OK,
            stderr,
        },
        Err(error) => {
            stderr.push_str(&format!("activity-hook: {}\n", error.message()));
            ActivityOutcome {
                code: EXIT_FAILURE,
                stderr,
            }
        }
    }
}

/// tmux entry point, for `waycar notify` after an agent hook wrote a pane's
/// `@waycar_status`. Resolves the Host's one registration file and state dir
/// and runs the same coalescing, episode, and push logic as the herdr hook,
/// over herdr's Agents (when herdr answers) plus tmux's and core's. A Host
/// whose `notify.json` turned tmux off sends nothing from here.
///
/// `pane_id` is the pane whose status changed (`tmux:%N`); `status` is the
/// status the hook just wrote (working, blocked, done, idle, or release when
/// the agent left): it only gates the cheap exit, the content comes from the
/// listing. herdr is `HERDR_BIN_PATH` or `herdr` on `PATH` plus the usual
/// install prefixes. `home` resolves the Host's directories. The error is the
/// joined delivery failures (`waycar notify` prints it as `waycar: activity:
/// <message>` and exits 1).
pub fn run_tmux_activity(
    pane_id: &str,
    status: &str,
    env: &Env,
    home: &Path,
    deps: &ActivityDeps<'_>,
    start_tick: &dyn Fn(&TickStart<'_>),
) -> Result<()> {
    if !is_tmux_pane_id(pane_id) {
        return Err(CliError::failure(format!("not a tmux pane id: {pane_id}")));
    }
    run_agent_activity(pane_id, status, env, home, deps, start_tick, |config| {
        config.tmux_enabled
    })
}

/// herdr-core entry point, for `waycar notify` after an agent hook ran in a
/// core terminal: [`run_tmux_activity`] for a `hc:<address>` pane. The Agents
/// are the same (herdr's, tmux's and core's); only the gate differs. A Host
/// whose `notify.json` turned core off sends nothing from here and never asks
/// core.
pub fn run_core_activity(
    pane_id: &str,
    status: &str,
    env: &Env,
    home: &Path,
    deps: &ActivityDeps<'_>,
    start_tick: &dyn Fn(&TickStart<'_>),
) -> Result<()> {
    if !is_core_pane_id(pane_id) {
        return Err(CliError::failure(format!(
            "not a herdr-core pane id: {pane_id}"
        )));
    }
    run_agent_activity(pane_id, status, env, home, deps, start_tick, |config| {
        config.core_enabled
    })
}

pub fn run_zellij_activity(
    pane_id: &str,
    status: &str,
    env: &Env,
    home: &Path,
    deps: &ActivityDeps<'_>,
    start_tick: &dyn Fn(&TickStart<'_>),
) -> Result<()> {
    if crate::zellij::PaneId::parse(pane_id).is_none() {
        return Err(CliError::failure("invalid Zellij pane id"));
    }
    run_agent_activity(pane_id, status, env, home, deps, start_tick, |config| {
        config.zellij_enabled
    })
}

/// What the tmux and core triggers share: `enabled` says whether the
/// Host's config lets this backend's trigger send.
fn run_agent_activity(
    pane_id: &str,
    status: &str,
    env: &Env,
    home: &Path,
    deps: &ActivityDeps<'_>,
    start_tick: &dyn Fn(&TickStart<'_>),
    enabled: fn(&NotificationConfig) -> bool,
) -> Result<()> {
    if status.is_empty() {
        return Err(CliError::failure("status missing"));
    }
    let resolved = resolve_host_config(env, home, &|herdr, args| {
        (deps.run)(&herdr.bin, args, &herdr.env)
    })?;
    let status = status.to_lowercase();
    end_turn_progress(&resolved.config_dir, &resolved.state_dir, pane_id, &status)?;
    if !enabled(&read_config(&resolved.config_dir)?) {
        return Ok(());
    }
    let herdr = herdr_command(env, home);
    let host = Host {
        config_dir: &resolved.config_dir,
        state_dir: &resolved.state_dir,
        herdr: &herdr,
        herdr_required: false,
        env,
        home: Some(home),
    };
    run_activity(&host, &status, deps, start_tick)
}

#[cfg(test)]
#[path = "activity_hook_tests.rs"]
mod tests;
