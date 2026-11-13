//! The Host's one Agent Notification producer (notify-core.js; ADR 0008,
//! ADR 0026 §4.5).
//!
//! Three triggers run this same code: herdr's `[[events]]` hook
//! (`notify_hook`, on `pane.agent_status_changed`), the tmux agent hooks
//! (`waycar notify --pane tmux:%N --status <s>`, [`run_tmux_notify`] below)
//! and the agent hooks inside herdr-core terminals
//! (`waycar notify --pane hc:<address> --status <s>`, [`run_core_notify`]).
//! Each supplies a [`Backend`], the only part that differs, and the flow is
//! shared:
//!
//! ```text
//! status ──> cheap exits ──> hold (debounce) alongside the summary
//!   ──> re-check ──> dedupe per pane in the state dir ──> store summary
//!   ──> read the registration file ──> attention count (every backend)
//!   ──> seal per device ──> POST to the Push Relay ──> prune 410 tokens
//! ```
//!
//! Only Blocked and Done notify; any other confirmed status re-arms the
//! pane's dedupe marker. Nothing is sent unless the status still holds after
//! the hold, so flapping detection never reaches the user.
//!
//! The JS holds with `Promise.all([sleep(debounce), summary])`. Blocking code
//! cannot overlap the two without threads, so the summary runs first and the
//! hold sleeps what is left of the debounce: the re-check comes at the same
//! moment, `max(debounce, summary)` after the event.
//!
//! Every outside effect is a parameter ([`Deps`]): the relay client
//! ([`Fetch`]), the clock and its sleeps ([`Clock`]), the program runner for
//! tmux and herdr, and the seams below. Diagnostics the JS prints with
//! `console.error` are appended to the `stderr` string the caller passes, for
//! the caller to print.
//!
//! # Seams to Agent Summaries and Chat Mode
//!
//! [`AgentSummaries`] (`generateAgentSummary`, agent-summary.js) and
//! [`ChatMode`] (chat-marker.js, chat-transcript.js, launch-rivals.js) are
//! traits so a test passes a fake; [`Deps::system`] uses the real
//! implementations in [`crate::notify_seams`]. [`NoSummaries`] and [`NoChat`]
//! answer what the JS answers when the capability yields nothing: no summary
//! (`{summary: null, hash: null}`), no marker, no reply.

use std::borrow::Cow;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::{Value, json};

use crate::activity_state::attention_count;
use crate::atomic::{edit_locked, pane_file_name, write_atomic};
use crate::base64;
use crate::chat::marker::{Marker, MarkerSession};
use crate::core::{self as hc, CoreCommand, CoreListing, CoreTerminal};
use crate::deps::{Clock, Fetch, HttpFetch, SystemClock};
use crate::display_text::for_display_str;
use crate::env::Env;
use crate::error::{CliError, Result};
use crate::exec::run_program;
use crate::herdr::{HerdrCommand, herdr_command};
use crate::hook_session::parse_hook_input;
use crate::jsx;
use crate::notification_config::{NotificationConfig, read_notification_config};
use crate::notification_envelope::{NotificationPayload, encrypt_notification_envelope};
use crate::notify_delivery::{DeliveryEffect, DeliveryEvent, NotificationDeliveryMachine};
use crate::notify_seams::{SystemChat, SystemSummaries};
use crate::paths::resolve_host_config;
use crate::seal::KEY_BYTES;
use crate::state_machine::StateMachine;
use crate::summary::store::{
    SUMMARY_MAX_AGE_MS, SummaryWrite, prune_summaries, remove_summaries, write_summary,
};
use crate::tmux::{Runner, TmuxAgent, is_tmux_pane_id, list_agents_with, to_waycar_pane_id};

const SEND_ATTEMPTS: u32 = 3;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(10);
const APNS_ENVIRONMENTS: [&str; 2] = ["production", "sandbox"];
const TMUX_STATUSES: [&str; 4] = ["working", "blocked", "done", "idle"];
/// The collapse id is the first 16 bytes of a digest: 22 base64url characters,
/// well under APNs' 64-byte cap.
const COLLAPSE_BYTES: usize = 16;
const COLLAPSE_LABEL: &[u8] = b"HERDR-NOTIFY-COLLAPSE:";

/// The registration file's per-device `notify` preference flag a status gates
/// on. Working and Idle transitions never notify (ADR 0008).
fn notify_flag(status: &str) -> Option<&'static str> {
    match status {
        "blocked" => Some("blocked"),
        "done" => Some("done"),
        _ => None,
    }
}

/// Append one diagnostic line, what `console.error` writes.
pub fn log(stderr: &mut String, line: impl std::fmt::Display) {
    use std::fmt::Write;
    let _ = writeln!(stderr, "{line}");
}

// ---- seams ------------------------------------------------------------------------

/// What `generateAgentSummary` answers: the summary (`None` on any failure)
/// and the screen's hash (`None` when the screen could not be read).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Summary {
    pub summary: Option<String>,
    pub hash: Option<String>,
}

/// `generateAgentSummary`'s options: summarize the Agent's screen within
/// `timeout_ms` (the screen read included).
pub struct SummaryRequest<'a> {
    /// The herdr CLI that reads a herdr pane's screen.
    pub herdr_bin: &'a str,
    /// A `tmux:` id is read with tmux through `run`.
    pub pane_id: &'a str,
    pub status: &'a str,
    /// `notify.json`'s `summary_command` (auto-detect a harness when `None`).
    pub command: Option<&'a [String]>,
    pub timeout_ms: u64,
    pub work_dir: &'a Path,
    pub cache_dir: &'a Path,
    pub env: &'a Env,
    pub run: Runner<'a>,
}

/// The Agent Summary generator (agent-summary.js).
pub trait AgentSummaries {
    fn generate(&self, request: &SummaryRequest<'_>) -> Summary;
}

/// No summary generator: every request yields nothing, as the JS does when no
/// summary can be produced.
pub struct NoSummaries;

impl AgentSummaries for NoSummaries {
    fn generate(&self, _request: &SummaryRequest<'_>) -> Summary {
        Summary::default()
    }
}

/// `markerApplies`'s probe: the Agent now on the marker's pane.
pub struct MarkerProbe<'a> {
    pub kind: Option<&'a str>,
    pub terminal_id: Option<&'a str>,
    pub agent_session: Option<&'a MarkerSession>,
}

/// `readChat`'s options for a Done turn (its `status` is always `"done"`).
pub struct ReplyRequest<'a> {
    /// The config dir `launchRivals` reads.
    pub config_dir: &'a Path,
    pub kind: Option<&'a str>,
    pub session: Option<&'a MarkerSession>,
    pub cwd: Option<&'a str>,
    pub launched_at: Option<&'a str>,
}

/// What `readChat` found, reduced to what the notify hook looks at.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ChatRead {
    /// `header.status === "ok"`.
    Ok,
    /// `header.status === "error"`, with `header.error`.
    Error(String),
    /// Any other header status (no transcript found).
    Other,
}

/// `readChat`'s verdict on one turn plus `lastReply` of it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChatTurn {
    pub read: ChatRead,
    /// `header.turn_open`: the reader still holds the turn open.
    pub turn_open: bool,
    /// `lastReply(chat)`: the newest assistant message's text, when any.
    pub last_reply: Option<String>,
}

/// `gcMarkers`'s options.
pub struct MarkerGc<'a> {
    pub config_dir: &'a Path,
    pub state_dir: &'a Path,
    /// Pane ids herdr lists now; `None` (the trigger is not a herdr hook)
    /// keeps every herdr marker.
    pub live_pane_ids: Option<Vec<String>>,
    /// `tmux:%N` ids of every tmux pane that exists now; `None` (tmux
    /// disabled or not listable) keeps every `tmux:` marker.
    pub live_tmux_pane_ids: Option<Vec<String>>,
    /// `hc:<address>` ids of the live herdr-core terminals; `None` (core
    /// disabled, absent or not listable) keeps every `hc:` marker.
    pub live_core_pane_ids: Option<Vec<String>>,
    pub now_ms: u64,
}

/// What `gcMarkers` did besides deleting: named herdr sessions blocked it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MarkerGcOutcome {
    pub skipped_for_named_sessions: bool,
}

/// Chat Mode: the pane markers and the harness transcripts (chat-marker.js,
/// chat-transcript.js, launch-rivals.js).
pub trait ChatMode {
    /// `readMarker(configDir, paneId)`.
    fn read_marker(&self, config_dir: &Path, pane_id: &str) -> Option<Marker>;
    /// `markerApplies(marker, probe)`.
    fn marker_applies(&self, marker: &Marker, probe: &MarkerProbe<'_>) -> bool;
    /// `readChat(...)` and `lastReply`; `Err` is a thrown reader error.
    fn read_chat(&self, request: &ReplyRequest<'_>) -> std::result::Result<ChatTurn, String>;
    /// `markerGcDue(stateDir, now)`.
    fn gc_due(&self, state_dir: &Path, now_ms: u64) -> bool;
    /// `listMarkers(configDir).length > 0`.
    fn has_markers(&self, config_dir: &Path) -> bool;
    /// `gcMarkers(...)`; `Err` is a thrown error.
    fn collect_markers(
        &self,
        request: &MarkerGc<'_>,
    ) -> std::result::Result<MarkerGcOutcome, String>;
}

/// No Chat Mode: no markers exist, so no push carries a reply and nothing is
/// collected.
pub struct NoChat;

impl ChatMode for NoChat {
    fn read_marker(&self, _config_dir: &Path, _pane_id: &str) -> Option<Marker> {
        None
    }

    fn marker_applies(&self, _marker: &Marker, _probe: &MarkerProbe<'_>) -> bool {
        false
    }

    fn read_chat(&self, _request: &ReplyRequest<'_>) -> std::result::Result<ChatTurn, String> {
        Ok(ChatTurn {
            read: ChatRead::Other,
            turn_open: false,
            last_reply: None,
        })
    }

    fn gc_due(&self, _state_dir: &Path, _now_ms: u64) -> bool {
        false
    }

    fn has_markers(&self, _config_dir: &Path) -> bool {
        false
    }

    fn collect_markers(
        &self,
        _request: &MarkerGc<'_>,
    ) -> std::result::Result<MarkerGcOutcome, String> {
        Ok(MarkerGcOutcome {
            skipped_for_named_sessions: false,
        })
    }
}

/// Everything a trigger reaches outside itself.
pub struct Deps<'a> {
    pub fetch: &'a dyn Fetch,
    pub clock: &'a dyn Clock,
    /// Runs tmux and herdr: `run(command, args, env)`.
    pub run: Runner<'a>,
    pub summaries: &'a dyn AgentSummaries,
    pub chat: &'a dyn ChatMode,
}

impl Deps<'static> {
    /// The production dependencies: the real network, clock, programs, Agent
    /// Summaries and Chat Mode.
    pub fn system() -> Self {
        Self {
            fetch: &HttpFetch,
            clock: &SystemClock,
            run: &run_program,
            summaries: &SystemSummaries,
            chat: &SystemChat,
        }
    }
}

// ---- the backend contract -----------------------------------------------------------

/// The change a trigger reports: the pane, the new status (lower-cased) and
/// the kind when the trigger knows it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Event {
    pub pane_id: String,
    pub status: String,
    pub agent_kind: Option<String>,
}

/// A pane's state after the hold. `detail` is what the backend keeps for
/// `describe` and `chat_reply`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Current<D> {
    pub status: String,
    pub agent_kind: Option<String>,
    pub detail: D,
}

/// The push's project and title, both already trimmed for display.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Labels {
    pub project: Option<String>,
    pub title: Option<String>,
}

/// What differs between the triggers.
pub trait Backend {
    /// What a re-check keeps besides the status and kind.
    type Detail;

    /// The pane's current status after the hold, or `None` when the agent is
    /// gone; `Err` when it cannot tell (the flow fails closed).
    fn recheck(&self) -> Result<Option<Current<Self::Detail>>>;
    /// The Agent Summary within a budget.
    fn summarize(&self, budget_ms: u64) -> Summary;
    /// The push's project and title.
    fn describe(&self, current: &Current<Self::Detail>) -> Labels;
    /// The Host's Attention Badge count, or `None`.
    fn attention(&self) -> Option<u64>;
    /// A final reply carried directly by an authoritative hook payload.
    fn reply(&self) -> Option<String> {
        None
    }
    /// Herdr only: the pane's Chat Marker.
    fn read_chat_marker(&self) -> Option<Marker> {
        None
    }
    /// Herdr only: the Chat Mode final reply; what it could not read it
    /// reports on `stderr`.
    fn chat_reply(
        &self,
        _marker: &Marker,
        _current: &Current<Self::Detail>,
        _stderr: &mut String,
    ) -> Option<String> {
        None
    }
}

// ---- the registration file ------------------------------------------------------------

/// `try { JSON.parse(readFileSync(path, "utf8")) } catch`: lone surrogate
/// escapes read as U+FFFD instead of failing the whole file.
fn read_json_lenient(path: &Path) -> Option<Value> {
    let bytes = fs::read(path).ok()?;
    parse_hook_input(&String::from_utf8_lossy(&bytes))
}

/// Which push service a registration entry's token belongs to (README
/// `provider`): absent or `apns` is APNs, `fcm` is Android. Any other value
/// skips the entry.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Provider {
    Apns,
    Fcm,
}

/// A device the registration file lists for pushes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Device {
    pub provider: Provider,
    pub token: String,
    pub env: String,
    pub key: Vec<u8>,
}

/// The `devices` array of a parsed registration file; `None` for a foreign
/// version or a file without one.
fn registered_devices(file: &Value) -> Option<&Vec<Value>> {
    let file = file.as_object()?;
    (file.get("v").and_then(Value::as_f64) == Some(1.0))
        .then(|| file.get("devices")?.as_array())
        .flatten()
}

/// Read the Notification Registration file (`notifications.json`, contract in
/// README.md). Absent, corrupt, or foreign-version files mean "send nothing";
/// a malformed device entry is skipped, never fatal for its neighbors.
pub fn read_eligible_devices(config_dir: &Path, status: &str) -> Vec<Device> {
    let Some(flag) = notify_flag(status) else {
        return Vec::new();
    };
    let Some(file) = read_json_lenient(&config_dir.join("notifications.json")) else {
        return Vec::new();
    };
    let Some(entries) = registered_devices(&file) else {
        return Vec::new();
    };
    let mut devices = Vec::new();
    for entry in entries {
        let Some(entry) = entry.as_object() else {
            continue;
        };
        let Some(token) = entry
            .get("token")
            .and_then(Value::as_str)
            .filter(|token| !token.is_empty())
        else {
            continue;
        };
        let provider = match entry.get("provider") {
            None => Provider::Apns,
            Some(Value::String(name)) if name == "apns" => Provider::Apns,
            Some(Value::String(name)) if name == "fcm" => Provider::Fcm,
            Some(_) => continue,
        };
        let valid_env = entry
            .get("env")
            .and_then(Value::as_str)
            .filter(|env| APNS_ENVIRONMENTS.contains(env));
        // `env` is APNs-only: an FCM entry keeps it (older plugins still read
        // the file) and the relay ignores it, so a missing one defaults.
        let env = match (provider, valid_env) {
            (_, Some(env)) => env,
            (Provider::Fcm, None) => "production",
            (Provider::Apns, None) => continue,
        };
        // Per the v1 contract a missing notify flag means do not send (fail closed).
        let flagged = entry
            .get("notify")
            .and_then(Value::as_object)
            .and_then(|notify| notify.get(flag))
            == Some(&Value::Bool(true));
        if !flagged {
            continue;
        }
        let Some(key) = entry.get("key").and_then(Value::as_str) else {
            continue;
        };
        let key = base64::decode(key);
        if key.len() != KEY_BYTES {
            continue;
        }
        devices.push(Device {
            provider,
            token: token.to_owned(),
            env: env.to_owned(),
            key,
        });
    }
    devices
}

/// Drop pruned tokens from the registration file, preserving every field this
/// plugin does not understand (additive v1 metadata must survive the rewrite).
/// Atomic temp-file + rename, like every writer of this file; a concurrent
/// app-side rewrite is last-writer-wins, and the next 410 re-prunes.
fn prune_tokens(config_dir: &Path, tokens: &[&str]) -> Result<()> {
    let path = config_dir.join("notifications.json");
    let Some(mut file) = read_json_lenient(&path) else {
        return Ok(());
    };
    if registered_devices(&file).is_none() {
        return Ok(());
    }
    if let Some(Value::Array(devices)) = file.get_mut("devices") {
        devices.retain(|entry| {
            !entry
                .get("token")
                .and_then(Value::as_str)
                .is_some_and(|token| tokens.contains(&token))
        });
    }
    write_atomic(&path, jsx::stringify(&file).as_bytes(), 0o600)?;
    Ok(())
}

// ---- per-pane dedupe state ----------------------------------------------------------------

// Per-pane dedupe state under the state dir: the status claimed before a
// delivery starts, cleared once a different status is confirmed to hold.
// All mutations share a short lock; never hold it over a POST or debounce.
fn state_path(state_dir: &Path, pane_id: &str) -> PathBuf {
    state_dir.join("notify").join(pane_file_name(pane_id))
}

fn read_last_notified(state_dir: &Path, pane_id: &str) -> Option<String> {
    let state = read_json_lenient(&state_path(state_dir, pane_id))?;
    match state.get("last_notified_status") {
        Some(Value::String(status)) => Some(status.clone()),
        _ => None,
    }
}

fn claim_notification(state_dir: &Path, pane_id: &str, status: &str) -> Result<Option<String>> {
    let random = ring::rand::generate::<[u8; 16]>(&ring::rand::SystemRandom::new())
        .map_err(|_| CliError::failure("cannot generate notification claim"))?;
    let claim = base64::encode_url(&random.expose());
    let claimed = edit_locked(&state_path(state_dir, pane_id), "notify", |_| {
        if read_last_notified(state_dir, pane_id).as_deref() == Some(status) {
            return None;
        }
        Some(vec![jsx::stringify(&json!({
            "pane": pane_id,
            "last_notified_status": status,
            "claim": claim,
        }))])
    })?;
    Ok(claimed.then_some(claim))
}

/// A failed POST may release only its own claim: a confirmed departure or
/// another turn may already have removed or replaced it while it was in flight.
fn clear_notification_claim(state_dir: &Path, pane_id: &str, claim: Option<&str>) -> Result<()> {
    let path = state_path(state_dir, pane_id);
    let mut removed = Ok(());
    edit_locked(&path, "notify", |_| {
        let state = read_json_lenient(&path);
        if claim.is_none_or(|claim| {
            state
                .as_ref()
                .and_then(|s| s.get("claim"))
                .and_then(Value::as_str)
                == Some(claim)
        }) {
            removed = match fs::remove_file(&path) {
                Err(error) if error.kind() != std::io::ErrorKind::NotFound => Err(error),
                _ => Ok(()),
            };
        }
        None
    })?;
    removed?;
    Ok(())
}

pub(crate) fn clear_last_notified(state_dir: &Path, pane_id: &str) {
    let _ = clear_notification_claim(state_dir, pane_id, None);
}

// ---- the relay ---------------------------------------------------------------------------

/// The `apns-collapse-id` passed through the relay so a newer status replaces
/// an older notification for the same pane. Keyed by the device's Notification
/// Key so it stays opaque: the relay can neither read nor dictionary-guess the
/// pane id behind it.
fn collapse_key_for(key: &[u8], pane_id: &str) -> String {
    let mut context = ring::digest::Context::new(&ring::digest::SHA256);
    context.update(key);
    context.update(COLLAPSE_LABEL);
    context.update(pane_id.as_bytes());
    let digest = context.finish();
    base64::encode_url(&digest.as_ref()[..COLLAPSE_BYTES])
}

/// JS `text.slice(0, units)` as it reaches a terminal: a surrogate pair cut in
/// half is a lone surrogate there, which prints as U+FFFD.
fn utf16_prefix(text: &str, units: usize) -> Cow<'_, str> {
    if jsx::utf16_len(text) <= units {
        return Cow::Borrowed(text);
    }
    let mut kept = String::new();
    let mut used = 0;
    for c in text.chars() {
        if used + c.len_utf16() > units {
            break;
        }
        kept.push(c);
        used += c.len_utf16();
    }
    if used < units {
        kept.push('\u{FFFD}');
    }
    Cow::Owned(kept)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PushOutcome {
    Delivered,
    /// APNs 410 Unregistered: the token is dead.
    Pruned,
}

/// POST one push, retrying transient failures (network errors, 429, 5xx) up
/// to [`SEND_ATTEMPTS`]. The relay itself never retries by design (ADR 0008).
/// `Err` is a delivery that conclusively failed.
///
/// An APNs body is `token, env, envelope, collapse`, byte-identical to
/// plugins before FCM. An FCM body adds `provider` and carries no collapse id
/// (the app replaces by its local notification tag), so `collapse` is unused
/// for it.
fn post_push(
    deps_fetch: &dyn Fetch,
    clock: &dyn Clock,
    relay_url: &str,
    device: &Device,
    envelope: &str,
    collapse: &str,
    retry_delay_ms: u64,
) -> std::result::Result<PushOutcome, String> {
    let body = match device.provider {
        Provider::Fcm => json!({
            "provider": "fcm",
            "token": device.token,
            "env": device.env,
            "envelope": envelope,
        }),
        Provider::Apns => json!({
            "token": device.token,
            "env": device.env,
            "envelope": envelope,
            "collapse": collapse,
        }),
    };
    let url = format!("{relay_url}/push");
    let mut last_failure = String::new();
    for attempt in 1..=SEND_ATTEMPTS {
        if attempt > 1 {
            clock.sleep(Duration::from_millis(retry_delay_ms));
        }
        let response = match deps_fetch.post_json(&url, &[], &body, REQUEST_TIMEOUT) {
            Ok(response) => response,
            Err(error) => {
                last_failure = format!("relay unreachable: {}", error.message());
                continue;
            }
        };
        if (200..300).contains(&response.status) {
            return Ok(PushOutcome::Delivered);
        }
        if response.status == 410 {
            return Ok(PushOutcome::Pruned);
        }
        last_failure = format!(
            "relay answered {}: {}",
            response.status,
            utf16_prefix(&response.body, 200)
        );
        if response.status != 429 && response.status < 500 {
            break;
        }
    }
    Err(format!(
        "push for token {}… failed: {last_failure}",
        utf16_prefix(&device.token, 8)
    ))
}

// ---- the summary store ----------------------------------------------------------------------

/// Summary-store retention, run by every trigger before any early return: the
/// 7-day prune must hold even for Hosts whose Agents stopped producing
/// summaries, and switching summaries off deletes what they left. Never fatal.
pub fn tidy_summary_store(
    config_dir: &Path,
    summary_enabled: bool,
    clock: &dyn Clock,
    stderr: &mut String,
) {
    if summary_enabled {
        prune_summaries(
            &config_dir.to_string_lossy(),
            clock.now_ms() as i64,
            SUMMARY_MAX_AGE_MS,
        );
    } else if let Err(error) = remove_summaries(&config_dir.to_string_lossy()) {
        log(
            stderr,
            format!("notify-hook: summary store not tidied: {error}"),
        );
    }
}

/// Record a confirmed turn's summary (`None`: a tombstone); never fatal.
fn persist_summary(
    config_dir: &Path,
    pane_id: &str,
    status: &str,
    generated: &Summary,
    event_at: u64,
    stderr: &mut String,
) {
    let write = SummaryWrite {
        pane_id,
        status,
        summary: generated.summary.as_deref(),
        ts: event_at as i64,
        hash: generated.hash.as_deref(),
        progress: &Value::Null,
    };
    if let Err(error) = write_summary(&config_dir.to_string_lossy(), &write) {
        log(stderr, format!("notify-hook: summary not stored: {error}"));
    }
}

// ---- attention ---------------------------------------------------------------------------------

/// Blocked + Done panes in a `list_tmux_agents` listing.
pub fn tmux_attention(agents: &[TmuxAgent]) -> u64 {
    agents
        .iter()
        .filter(|agent| matches!(agent.status, Some("blocked" | "done")))
        .count() as u64
}

/// The tmux share of the Attention Badge, or `None` when tmux cannot list.
pub fn tmux_attention_count(env: &Env, run: Runner<'_>) -> Option<u64> {
    list_agents_with(run, env)
        .ok()
        .map(|agents| tmux_attention(&agents))
}

/// One Host's Attention Badge count across both backends. The triggering
/// backend's count is required (`None`: the payload omits the count and the
/// app leaves its badge alone rather than trusting a guess); the other
/// backend adds its share when it answered, so a Host without it counts
/// exactly as before.
pub fn combine_attention(primary: Option<u64>, secondary: Option<u64>) -> Option<u64> {
    primary.map(|primary| primary + secondary.unwrap_or(0))
}

/// Blocked + Done terminals in a `herdr-core ls` listing (an `error` report
/// is blocked); a terminal that never reported counts for nothing.
pub fn core_attention(terminals: &[CoreListing]) -> u64 {
    terminals
        .iter()
        .filter(|terminal| matches!(terminal.waycar_status(), Some("blocked" | "done")))
        .count() as u64
}

/// The core share of the Attention Badge, or `None` when core cannot list.
fn core_attention_count(core: &CoreCommand, run: Runner<'_>) -> Option<u64> {
    hc::list(core, run)
        .ok()
        .map(|terminals| core_attention(&terminals))
}

/// The core share for a tmux or herdr trigger: `None` unless core is enabled
/// on this Host and already running. Asking a core that is not running would
/// start one with the hook's environment, so a Host that merely has
/// herdr-core installed counts exactly as before.
pub fn core_attention_share(
    config: &NotificationConfig,
    env: &Env,
    home: &Path,
    run: Runner<'_>,
) -> Option<u64> {
    if !config.core_enabled {
        return None;
    }
    let core = hc::running_core(env, home, run)?;
    core_attention_count(&core, run)
}

/// Two optional shares of a badge: both when both answered, whichever
/// answered otherwise, `None` when neither did.
pub fn sum_shares(first: Option<u64>, second: Option<u64>) -> Option<u64> {
    match (first, second) {
        (None, None) => None,
        (first, second) => Some(first.unwrap_or(0) + second.unwrap_or(0)),
    }
}

// ---- the flow ----------------------------------------------------------------------------------

/// Where one run keeps its files and which relay and clock it uses.
pub struct Flow<'a> {
    /// The Host's config dir (registration file, summary store).
    pub config_dir: &'a Path,
    /// The Host's state dir (dedupe markers).
    pub state_dir: &'a Path,
    pub config: &'a NotificationConfig,
    pub fetch: &'a dyn Fetch,
    pub clock: &'a dyn Clock,
}

/// Run one status change through the shared flow, as
/// [`NotificationDeliveryMachine`] decides. `event_at` is the change's time
/// in epoch milliseconds.
///
/// `Err` is what the JS promise rejects with: an unreadable re-check, a seal
/// that failed, or a delivery that conclusively failed for some device.
pub fn run_notification<B: Backend>(
    flow: &Flow<'_>,
    event: &Event,
    event_at: u64,
    backend: &B,
    stderr: &mut String,
) -> Result<()> {
    let mut machine = NotificationDeliveryMachine::new(
        &event.status,
        event.agent_kind.as_deref(),
        notify_flag(&event.status).is_some(),
    );
    // Cheap exits before burning a 5 s hold on a no-op.
    let last_notified = read_last_notified(flow.state_dir, &event.pane_id);
    let has_devices = !read_eligible_devices(flow.config_dir, &event.status).is_empty();
    let mut pending: std::collections::VecDeque<DeliveryEffect> = machine
        .handle(DeliveryEvent::Begin {
            last_notified,
            has_devices,
            summary_enabled: flow.config.summary_enabled,
        })
        .into();

    // What the effects leave for the later ones.
    let mut marker: Option<Marker> = None;
    let mut generated = Summary::default();
    let mut current: Option<Current<B::Detail>> = None;
    let mut reply: Option<String> = None;
    let mut devices: Vec<Device> = Vec::new();
    let mut envelopes: Vec<String> = Vec::new();
    let mut pruned: Vec<String> = Vec::new();
    let mut failures: Vec<String> = Vec::new();

    while let Some(effect) = pending.pop_front() {
        let answer = match effect {
            // A Done push for a Chat Mode pane carries the Agent's reply
            // instead of a summary, so the summary is deferred: it is
            // generated only if the reader comes up empty.
            DeliveryEffect::ReadChatMarker => {
                marker = backend.read_chat_marker();
                Some(DeliveryEvent::MarkerRead(
                    marker
                        .as_ref()
                        .map(|marker| (marker.chat_mode, marker.kind.clone())),
                ))
            }
            // The hold: only a status that still holds after the sleep
            // notifies (or re-arms), so detection flapping never reaches the
            // user. The summary is generated within the hold, so the re-check
            // also covers the time the model took: pushing (and marking) a
            // status that moved on meanwhile would dedupe the pane's next
            // real one.
            DeliveryEffect::Hold { summarize } => {
                let held_from = flow.clock.now_ms();
                if summarize {
                    generated = backend.summarize(flow.config.summary_timeout_ms);
                }
                let spent = i128::from(flow.clock.now_ms()) - i128::from(held_from);
                let left = i128::from(flow.config.debounce_ms) - spent.max(0);
                flow.clock.sleep(Duration::from_millis(left.max(0) as u64));
                Some(DeliveryEvent::Held)
            }
            DeliveryEffect::Recheck => {
                current = backend.recheck()?;
                Some(DeliveryEvent::Rechecked(
                    current.as_ref().map(|current| current.status.clone()),
                ))
            }
            DeliveryEffect::ClearLastNotified => {
                clear_last_notified(flow.state_dir, &event.pane_id);
                None
            }
            // Chat Mode: the reply replaces the summary for this push.
            DeliveryEffect::Reply { chat } => {
                reply = backend.reply();
                if chat && let (Some(marker), Some(current)) = (&marker, &current) {
                    reply = backend.chat_reply(marker, current, stderr);
                }
                Some(DeliveryEvent::Replied {
                    has_reply: reply.is_some(),
                })
            }
            // Without a reply the push falls back to the deferred summary,
            // bounded by what is left of its budget from the event.
            DeliveryEffect::Resummarize => {
                let elapsed = i128::from(flow.clock.now_ms()) - i128::from(event_at);
                let remaining = i128::from(flow.config.summary_timeout_ms) - elapsed;
                if remaining > 0 {
                    generated = backend.summarize(remaining as u64);
                }
                Some(DeliveryEvent::Resummarized)
            }
            // The status held, so the summary describes this turn: store it
            // before pushing, so an app opened from the push already finds
            // it. A turn with no summary (a reply push included) still
            // retires the previous turn's.
            DeliveryEffect::PersistSummary => {
                persist_summary(
                    flow.config_dir,
                    &event.pane_id,
                    &event.status,
                    &generated,
                    event_at,
                    stderr,
                );
                None
            }
            // Re-read both after the sleep: a concurrent invocation may have
            // delivered, and the app may have rewritten the registration file
            // meanwhile.
            DeliveryEffect::CheckDedupe => {
                let already_notified = read_last_notified(flow.state_dir, &event.pane_id)
                    .as_deref()
                    == Some(event.status.as_str());
                if !already_notified {
                    devices = read_eligible_devices(flow.config_dir, &event.status);
                }
                Some(DeliveryEvent::DedupeChecked {
                    already_notified,
                    devices: devices.len(),
                })
            }
            // Seal before claiming so a local error cannot leave an
            // undeliverable marker.
            DeliveryEffect::Seal => {
                let Some(current) = &current else {
                    continue;
                };
                let labels = backend.describe(current);
                let attention = backend.attention();
                let agent_kind = event
                    .agent_kind
                    .as_deref()
                    .or(current.agent_kind.as_deref())
                    .unwrap_or("unknown");
                let payload = NotificationPayload {
                    pane_id: &event.pane_id,
                    agent_kind,
                    status: &event.status,
                    timestamp: (event_at / 1000) as i64,
                    project: labels.project.as_deref(),
                    title: labels.title.as_deref(),
                    summary: generated.summary.as_deref(),
                    reply: reply.as_deref(),
                    attention,
                };
                envelopes = devices
                    .iter()
                    .map(|device| {
                        encrypt_notification_envelope(&payload, &device.key, None)
                            .map_err(|error| CliError::failure(error.message))
                    })
                    .collect::<Result<Vec<_>>>()?;
                Some(DeliveryEvent::Sealed)
            }
            // Claim atomically before any POST: a Working notifier must see
            // it even while the relay is slow, and duplicate Done notifiers
            // must lose.
            DeliveryEffect::Claim => Some(DeliveryEvent::Claimed(claim_notification(
                flow.state_dir,
                &event.pane_id,
                &event.status,
            )?)),
            DeliveryEffect::Post => {
                let mut delivered = false;
                for (device, envelope) in devices.iter().zip(std::mem::take(&mut envelopes)) {
                    let collapse = collapse_key_for(&device.key, &event.pane_id);
                    match post_push(
                        flow.fetch,
                        flow.clock,
                        &flow.config.relay_url,
                        device,
                        &envelope,
                        &collapse,
                        flow.config.retry_delay_ms,
                    ) {
                        Ok(PushOutcome::Delivered) => delivered = true,
                        Ok(PushOutcome::Pruned) => pruned.push(device.token.clone()),
                        Err(message) => failures.push(message),
                    }
                }
                Some(DeliveryEvent::Posted { delivered })
            }
            // Failure must not erase a newer turn's claim.
            DeliveryEffect::ReleaseClaim(claim) => {
                clear_notification_claim(flow.state_dir, &event.pane_id, Some(&claim))?;
                None
            }
            DeliveryEffect::PruneTokens => {
                if !pruned.is_empty() {
                    let tokens: Vec<&str> = pruned.iter().map(String::as_str).collect();
                    prune_tokens(flow.config_dir, &tokens)?;
                }
                None
            }
        };
        if let Some(answer) = answer {
            pending.extend(machine.handle(answer));
        }
    }
    if failures.is_empty() {
        Ok(())
    } else {
        Err(CliError::failure(failures.join("; ")))
    }
}

// ---- the tmux trigger ------------------------------------------------------------------------------

/// The herdr share of the Attention Badge for the tmux trigger: Blocked +
/// Done from `herdr agent list`, or `None` when herdr is missing or cannot
/// answer.
fn herdr_attention_count(herdr: &HerdrCommand, run: Runner<'_>) -> Option<u64> {
    let result = run(&herdr.bin, &["agent", "list"], &herdr.env);
    if result.code != 0 {
        return None;
    }
    let listing = parse_hook_input(&result.stdout)?;
    let agents = listing.get("result")?.get("agents")?.as_array()?;
    Some(u64::from(attention_count(agents)))
}

/// The push title for a tmux Agent: its window name, unless that is tmux's
/// automatic-rename artifact.
fn tmux_title(pane: &TmuxAgent) -> Option<&str> {
    if pane.window_name.is_some() && pane.window_name != pane.command {
        return pane.window_name.as_deref();
    }
    pane.title.as_deref().or(pane.window_name.as_deref())
}

struct TmuxBackend<'a> {
    pane_id: &'a str,
    status: &'a str,
    env: &'a Env,
    home: &'a Path,
    run: Runner<'a>,
    herdr: HerdrCommand,
    flow: &'a Flow<'a>,
    summaries: &'a dyn AgentSummaries,
}

impl Backend for TmuxBackend<'_> {
    type Detail = TmuxAgent;

    fn recheck(&self) -> Result<Option<Current<TmuxAgent>>> {
        let panes = list_agents_with(self.run, self.env)?;
        Ok(panes
            .into_iter()
            .find(|agent| agent.pane_id == self.pane_id)
            .and_then(|pane| {
                Some(Current {
                    status: pane.status?.to_string(),
                    agent_kind: pane.agent.clone(),
                    detail: pane,
                })
            }))
    }

    fn summarize(&self, budget_ms: u64) -> Summary {
        self.summaries.generate(&SummaryRequest {
            herdr_bin: &self.herdr.bin,
            pane_id: self.pane_id,
            status: self.status,
            command: self.flow.config.summary_command.as_deref(),
            timeout_ms: budget_ms,
            work_dir: self.flow.state_dir,
            cache_dir: self.flow.config_dir,
            env: self.env,
            run: self.run,
        })
    }

    fn describe(&self, current: &Current<TmuxAgent>) -> Labels {
        let trimmed = |text: Option<&str>| text.and_then(for_display_str).map(Cow::into_owned);
        Labels {
            project: trimmed(current.detail.session_name.as_deref()),
            title: trimmed(tmux_title(&current.detail)),
        }
    }

    fn attention(&self) -> Option<u64> {
        combine_attention(
            tmux_attention_count(self.env, self.run),
            sum_shares(
                herdr_attention_count(&self.herdr, self.run),
                core_attention_share(self.flow.config, self.env, self.home, self.run),
            ),
        )
    }
}

/// The tmux trigger (`waycar notify --pane tmux:%3 --status blocked`), run by
/// the agent hooks on every status change of a pane: the shared flow with the
/// pane's `@waycar_status` as the re-check, its screen for the Agent Summary,
/// and its session and window names as project and title. A Host whose
/// `notify.json` sets `tmux_enabled: false` sends nothing for tmux panes.
///
/// `pane_id` is `tmux:%3` (a raw `%3` is accepted). `status` is
/// `working|blocked|done|idle`, or `release` (the agent left the pane): it
/// clears the pane's dedupe marker so the pane's next agent notifies afresh.
/// `env` is the hook's environment (its `TMUX` picks the server) and `home`
/// the account's home directory. The change's time is `deps.clock.now_ms()`.
///
/// `Err` is the rejection the JS reports as `waycar: notify: <message>`: bad
/// arguments, an unreadable re-check, or a delivery that failed.
pub fn run_tmux_notify(
    pane_id: &str,
    status: &str,
    env: &Env,
    home: &Path,
    deps: &Deps<'_>,
    stderr: &mut String,
) -> Result<()> {
    let id = if pane_id.is_empty() {
        None
    } else {
        Some(to_waycar_pane_id(pane_id))
    };
    let Some(id) = id.filter(|id| is_tmux_pane_id(id)) else {
        return Err(CliError::failure(format!("not a tmux pane id: {pane_id}")));
    };
    let wanted = status.to_lowercase();
    if !TMUX_STATUSES.contains(&wanted.as_str()) && wanted != "release" {
        return Err(CliError::failure(format!("unknown status: {status}")));
    }
    let event_at = deps.clock.now_ms();

    let run_herdr = |herdr: &HerdrCommand, args: &[&str]| (deps.run)(&herdr.bin, args, &herdr.env);
    let host = resolve_host_config(env, home, &run_herdr)?;
    if wanted == "release" {
        clear_last_notified(&host.state_dir, &id);
        return Ok(());
    }

    let config =
        read_notification_config(&host.config_dir.to_string_lossy()).map_err(CliError::failure)?;
    if !config.tmux_enabled {
        return Ok(());
    }
    tidy_summary_store(&host.config_dir, config.summary_enabled, deps.clock, stderr);

    let flow = Flow {
        config_dir: &host.config_dir,
        state_dir: &host.state_dir,
        config: &config,
        fetch: deps.fetch,
        clock: deps.clock,
    };
    let backend = TmuxBackend {
        pane_id: &id,
        status: &wanted,
        env,
        home,
        run: deps.run,
        herdr: herdr_command(env, home),
        flow: &flow,
        summaries: deps.summaries,
    };
    let event = Event {
        pane_id: id.clone(),
        status: wanted.clone(),
        agent_kind: None,
    };
    run_notification(&flow, &event, event_at, &backend, stderr)
}

// ---- the herdr-core trigger ----------------------------------------------------------------------

/// Whether a core `idle` report is the end of the turn the hook calls `done`.
/// Claude Code's turn end may reach core as `idle`; core counts a turn each
/// time a terminal leaves `working`, and the hook records that count in the
/// `waycar.turn` label when it writes `working`, so `idle` after a higher
/// count is a finished turn. With no label, any finished turn counts.
fn idle_ends_a_turn(terminal: &CoreTerminal) -> bool {
    let recorded = terminal
        .labels
        .get("waycar.turn")
        .and_then(|turn| turn.parse::<u64>().ok());
    match recorded {
        Some(turn) => terminal.turn > turn,
        None => terminal.turn >= 1,
    }
}

/// The status a terminal confirms for an event reporting `wanted`. A terminal
/// that never reported (or has no status) has only what the hooks wrote: the
/// label `waycar.status` when there is one, so a later hook that moved the
/// status on during the hold drops this event as it does for tmux; with no
/// label the hook's own guards stand and the event's status is trusted. A
/// reporting one is read as core stores it, `error` as `blocked`, and `idle`
/// as `done` when it follows a finished turn and the hook said `done`.
fn confirmed_status(terminal: &CoreTerminal, wanted: &str) -> String {
    let (Some(status), true) = (&terminal.status, terminal.reported) else {
        return terminal
            .labels
            .get("waycar.status")
            .filter(|label| !label.is_empty())
            .map_or_else(|| wanted.to_owned(), |label| label.to_lowercase());
    };
    match hc::map_status(&status.state) {
        Some("idle") if wanted == "done" && idle_ends_a_turn(terminal) => "done".to_owned(),
        Some(word) => word.to_owned(),
        None => status.state.to_lowercase(),
    }
}

/// The last path segment of a folder: the project a push names.
fn folder_name(folder: &str) -> Option<&str> {
    folder
        .trim_end_matches('/')
        .rsplit('/')
        .next()
        .filter(|name| !name.is_empty())
}

struct CoreBackend<'a> {
    core: &'a CoreCommand,
    address: &'a str,
    pane_id: &'a str,
    status: &'a str,
    env: &'a Env,
    home: &'a Path,
    run: Runner<'a>,
    flow: &'a Flow<'a>,
    summaries: &'a dyn AgentSummaries,
}

impl Backend for CoreBackend<'_> {
    type Detail = CoreTerminal;

    fn recheck(&self) -> Result<Option<Current<CoreTerminal>>> {
        let Some(terminal) = hc::get(self.core, self.run, self.address)? else {
            return Ok(None);
        };
        if !terminal.is_live() {
            return Ok(None);
        }
        Ok(Some(Current {
            status: confirmed_status(&terminal, self.status),
            agent_kind: terminal.kind().map(str::to_owned),
            detail: terminal,
        }))
    }

    fn summarize(&self, budget_ms: u64) -> Summary {
        self.summaries.generate(&SummaryRequest {
            herdr_bin: &herdr_command(self.env, self.home).bin,
            pane_id: self.pane_id,
            status: self.status,
            command: self.flow.config.summary_command.as_deref(),
            timeout_ms: budget_ms,
            work_dir: self.flow.state_dir,
            cache_dir: self.flow.config_dir,
            env: self.env,
            run: self.run,
        })
    }

    // The project is the working folder's name; the title is what the terminal
    // is called: the name it was given, else the agent's own task title, else
    // the terminal's title.
    fn describe(&self, current: &Current<CoreTerminal>) -> Labels {
        let trimmed = |text: Option<&str>| text.and_then(for_display_str).map(Cow::into_owned);
        let terminal = &current.detail;
        Labels {
            project: trimmed(terminal.folder().and_then(folder_name)),
            title: trimmed(
                terminal
                    .name
                    .as_deref()
                    .or_else(|| terminal.status.as_ref()?.title.as_deref())
                    .or(terminal.title.as_deref()),
            ),
        }
    }

    // tmux panes show next to core terminals (the Herdr TUI does not: a Host
    // with both shows one of them), so tmux is the secondary share.
    fn attention(&self) -> Option<u64> {
        combine_attention(
            core_attention_count(self.core, self.run),
            if self.flow.config.tmux_enabled {
                tmux_attention_count(self.env, self.run)
            } else {
                None
            },
        )
    }
}

/// The `hc:<address>` ids of the terminals a `herdr-core ls` lists.
fn live_core_pane_ids_of(core: &CoreCommand, run: Runner<'_>) -> Option<Vec<String>> {
    hc::list(core, run)
        .ok()
        .map(|terminals| terminals.iter().map(CoreListing::pane_id).collect())
}

/// The live core terminals for a herdr hook's Chat Marker collection: `None`
/// when core is disabled on this Host, not running (asking would start one)
/// or not listable, which keeps every `hc:` marker.
pub fn live_core_pane_ids(
    config: &NotificationConfig,
    env: &Env,
    home: &Path,
    run: Runner<'_>,
) -> Option<Vec<String>> {
    if !config.core_enabled {
        return None;
    }
    live_core_pane_ids_of(&hc::running_core(env, home, run)?, run)
}

/// Run the Chat Marker collection `request` asks for and report what it could
/// not do on `stderr`. Never fatal.
pub fn collect_markers_logged(chat: &dyn ChatMode, request: &MarkerGc<'_>, stderr: &mut String) {
    match chat.collect_markers(request) {
        Ok(outcome) if outcome.skipped_for_named_sessions => log(
            stderr,
            "notify-hook: chat markers not collected: named herdr sessions share this Host",
        ),
        Ok(_) => {}
        Err(message) => log(
            stderr,
            format!("notify-hook: chat markers not collected: {message}"),
        ),
    }
}

/// The core trigger's Chat Marker collection: only `hc:` markers are judged
/// (by core's own listing); the tmux and herdr triggers judge theirs. Due at
/// most hourly and only while markers exist, like the herdr hook's, but in a
/// slot of its own (a state subdirectory): the herdr hook's hourly run judges
/// every backend, and a core run that took its slot would leave the herdr and
/// tmux markers uncollected.
fn collect_core_chat_markers(
    core: &CoreCommand,
    flow: &Flow<'_>,
    deps: &Deps<'_>,
    stderr: &mut String,
) {
    let now_ms = deps.clock.now_ms();
    let state_dir = flow.state_dir.join("core-chat-marker-gc");
    if !deps.chat.gc_due(&state_dir, now_ms) || !deps.chat.has_markers(flow.config_dir) {
        return;
    }
    let Some(live_core_pane_ids) = live_core_pane_ids_of(core, deps.run) else {
        return;
    };
    let request = MarkerGc {
        config_dir: flow.config_dir,
        state_dir: &state_dir,
        live_pane_ids: None,
        live_tmux_pane_ids: None,
        live_core_pane_ids: Some(live_core_pane_ids),
        now_ms,
    };
    collect_markers_logged(deps.chat, &request, stderr);
}

/// The herdr-core trigger (`waycar notify --pane hc:t7 --status blocked`),
/// run by the agent hooks inside a core terminal: the shared flow with the
/// terminal's record (`herdr-core get`) as the re-check, its screen for the
/// Agent Summary, and its folder and name as project and title. A Host whose
/// `notify.json` sets `core_enabled: false` sends nothing, and never asks
/// core.
///
/// `pane_id` is `hc:<address>`. `status` is `working|blocked|done|idle`, or
/// `release` (the agent left the terminal): it clears the terminal's dedupe
/// marker so its next agent notifies afresh. `env` is the hook's
/// environment (`HC_TERMINAL_SOCKET` names the core that runs the terminal,
/// so no other core starts) and `home` the account's home directory.
///
/// The re-check reads the record after the hold. A terminal that is gone or
/// finished sends nothing; core that cannot answer fails the run (closed).
/// A terminal that never reported OSC 7501 trusts the hook; one that did
/// must still show the status the hook reported (see [`confirmed_status`]).
///
/// `Err` is the rejection `waycar: notify: <message>` reports: bad arguments,
/// herdr-core missing, an unreadable re-check, or a delivery that failed.
pub fn run_core_notify(
    pane_id: &str,
    status: &str,
    env: &Env,
    home: &Path,
    deps: &Deps<'_>,
    stderr: &mut String,
) -> Result<()> {
    if !hc::is_core_pane_id(pane_id) {
        return Err(CliError::failure(format!(
            "not a herdr-core terminal id: {pane_id}"
        )));
    }
    let wanted = status.to_lowercase();
    if !TMUX_STATUSES.contains(&wanted.as_str()) && wanted != "release" {
        return Err(CliError::failure(format!("unknown status: {status}")));
    }
    let event_at = deps.clock.now_ms();

    let run_herdr = |herdr: &HerdrCommand, args: &[&str]| (deps.run)(&herdr.bin, args, &herdr.env);
    let host = resolve_host_config(env, home, &run_herdr)?;
    if wanted == "release" {
        clear_last_notified(&host.state_dir, pane_id);
        return Ok(());
    }

    let config =
        read_notification_config(&host.config_dir.to_string_lossy()).map_err(CliError::failure)?;
    // Addresses repeat across core sessions, so `hc:t1` would name two
    // terminals: Waycar handles the default session only.
    if !config.core_enabled || hc::is_named_session(env) {
        return Ok(());
    }
    tidy_summary_store(&host.config_dir, config.summary_enabled, deps.clock, stderr);
    let Some(core) = hc::running_core(env, home, deps.run) else {
        return Err(CliError::failure("no herdr-core is running on this Host"));
    };

    let flow = Flow {
        config_dir: &host.config_dir,
        state_dir: &host.state_dir,
        config: &config,
        fetch: deps.fetch,
        clock: deps.clock,
    };
    collect_core_chat_markers(&core, &flow, deps, stderr);

    let backend = CoreBackend {
        core: &core,
        address: hc::to_core_address(pane_id),
        pane_id,
        status: &wanted,
        env,
        home,
        run: deps.run,
        flow: &flow,
        summaries: deps.summaries,
    };
    let event = Event {
        pane_id: pane_id.to_owned(),
        status: wanted.clone(),
        agent_kind: None,
    };
    run_notification(&flow, &event, event_at, &backend, stderr)
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::rc::Rc;

    use serde_json::{Value, json};

    use super::*;
    use crate::notify_fake::rig::*;
    use crate::notify_fake::{FakeClock, TmuxPane, answer};

    // ---- suite("notify: tmux trigger") -----------------------------------------------------
    //
    // The JS tests run `runTmuxNotify` in process with an injected `run`
    // standing in for the tmux and herdr CLIs and a fake relay; the rig does
    // the same.

    /// A tmux-only Host with one pane at `status`, notified and configured.
    fn tmux_rig(status: &str) -> Rig {
        let rig = Rig::tmux();
        rig.write_config(json!({}));
        rig.write_registration(&[device()]);
        *rig.host.panes.borrow_mut() = Some(vec![TmuxPane::with_status(status)]);
        rig
    }

    fn set_status(rig: &Rig, status: &str) {
        rig.host.panes.borrow_mut().as_mut().unwrap()[0].status = status.to_owned();
    }

    fn notified(rig: &Rig, pane_id: &str, status: &str) {
        let (result, stderr) = rig.notify(pane_id, status);
        result.unwrap_or_else(|error| panic!("{error}: {stderr}"));
    }

    // test("a status that holds posts the tmux pane with its kind, session and window")
    #[test]
    fn a_status_that_holds_posts_the_tmux_pane_with_its_kind_session_and_window() {
        let rig = tmux_rig("blocked");
        let listed_before_the_hold = Rc::new(RefCell::new(Vec::new()));
        let seen = Rc::clone(&listed_before_the_hold);
        let host = Rc::clone(&rig.host);
        rig.clock.on_sleep(move || {
            seen.borrow_mut()
                .push(host.calls_of("tmux", Some("list-panes")).len())
        });

        notified(&rig, "tmux:%3", "blocked");

        assert_eq!(rig.relay.posts().len(), 1);
        let (_, payload) = rig.payload(0, &key_a());
        assert_eq!(payload["pane"], "tmux:%3");
        assert_eq!(payload["kind"], "claude");
        assert_eq!(payload["status"], "blocked");
        assert_eq!(payload["project"], "proj");
        assert_eq!(payload["title"], "fix-auth");
        assert_eq!(payload["attention"], 1);
        // The re-check reads the pane only after the hold, on the hook's server.
        assert_eq!(*listed_before_the_hold.borrow(), vec![0]);
        assert_eq!(rig.clock.sleeps(), vec![Duration::from_millis(DEBOUNCE_MS)]);
        assert!(
            rig.host
                .calls_of("tmux", None)
                .iter()
                .all(|call| call.env.get("TMUX") == Some(TMUX_ENV))
        );
    }

    // test("a window tmux named after the command gives way to the pane title")
    #[test]
    fn a_window_tmux_named_after_the_command_gives_way_to_the_pane_title() {
        let rig = tmux_rig("done");
        {
            let mut panes = rig.host.panes.borrow_mut();
            let pane = &mut panes.as_mut().unwrap()[0];
            pane.window_name = "2.1.286".into();
            pane.command = "2.1.286".into();
        }

        notified(&rig, "tmux:%3", "done");

        let (_, payload) = rig.payload(0, &key_a());
        assert_eq!(payload["title"], "✳ Fix the auth bug");
    }

    // test("a status that moved on during the hold sends nothing")
    #[test]
    fn a_status_that_moved_on_during_the_hold_sends_nothing() {
        let rig = tmux_rig("blocked");
        let host = Rc::clone(&rig.host);
        rig.clock.on_sleep(move || {
            host.panes.borrow_mut().as_mut().unwrap()[0].status = "working".into();
        });

        notified(&rig, "tmux:%3", "blocked");

        assert!(rig.relay.posts().is_empty());
    }

    // test("a same-status repeat is deduped; a confirmed departure re-arms the pane")
    #[test]
    fn a_same_status_repeat_is_deduped_a_confirmed_departure_rearms_the_pane() {
        let rig = tmux_rig("blocked");

        notified(&rig, "tmux:%3", "blocked");
        notified(&rig, "tmux:%3", "blocked");
        assert_eq!(rig.relay.posts().len(), 1);

        set_status(&rig, "working");
        notified(&rig, "tmux:%3", "working");
        set_status(&rig, "blocked");
        notified(&rig, "tmux:%3", "blocked");

        assert_eq!(rig.relay.posts().len(), 2);
    }

    // test("done, working, done pushes twice")
    #[test]
    fn done_working_done_pushes_twice() {
        let rig = tmux_rig("done");

        notified(&rig, "tmux:%3", "done");
        set_status(&rig, "working");
        notified(&rig, "tmux:%3", "working");
        set_status(&rig, "done");
        notified(&rig, "tmux:%3", "done");

        assert_eq!(rig.relay.posts().len(), 2);
        for index in 0..2 {
            assert_eq!(rig.payload(index, &key_a()).1["status"], "done");
        }
    }

    #[test]
    fn working_during_a_done_post_rearms_the_next_done() {
        let rig = Rc::new_cyclic(|weak: &std::rc::Weak<Rig>| {
            let mut rig = tmux_rig("done");
            let weak = weak.clone();
            rig.relay_answers(move |_, index| {
                if index == 0 {
                    let rig = weak.upgrade().unwrap();
                    set_status(&rig, "working");
                    notified(&rig, "tmux:%3", "working");
                }
                Ok(answer(200, r#"{"apnsId":"x"}"#))
            });
            rig
        });

        notified(&rig, "tmux:%3", "done");
        set_status(&rig, "done");
        notified(&rig, "tmux:%3", "done");

        assert_eq!(rig.relay.posts().len(), 2);
        for index in 0..2 {
            assert_eq!(rig.payload(index, &key_a()).1["status"], "done");
        }
    }

    #[test]
    fn a_failed_post_releases_its_own_claim_so_the_same_status_tries_again() {
        let mut rig = tmux_rig("done");
        rig.relay_answers(|_, index| {
            if index == 0 {
                Ok(answer(400, "bad"))
            } else {
                Ok(answer(200, r#"{"apnsId":"x"}"#))
            }
        });
        let (result, _) = rig.notify("tmux:%3", "done");
        assert!(result.is_err());
        assert_eq!(read_last_notified(&rig.state_dir, "tmux:%3"), None);
        notified(&rig, "tmux:%3", "done");
        assert_eq!(rig.relay.posts().len(), 2);
        assert_eq!(
            read_last_notified(&rig.state_dir, "tmux:%3").as_deref(),
            Some("done")
        );
    }

    #[test]
    fn a_failed_post_never_releases_the_claim_a_newer_turn_made_meanwhile() {
        let rig = Rc::new_cyclic(|weak: &std::rc::Weak<Rig>| {
            let mut rig = tmux_rig("done");
            let weak = weak.clone();
            let first = std::cell::Cell::new(true);
            rig.relay_answers(move |_, _| {
                if first.replace(false) {
                    // The pane worked and blocked again while this Done
                    // POST was in flight; that Blocked push claimed the pane.
                    let rig = weak.upgrade().unwrap();
                    set_status(&rig, "working");
                    notified(&rig, "tmux:%3", "working");
                    set_status(&rig, "blocked");
                    notified(&rig, "tmux:%3", "blocked");
                    return Ok(answer(400, "bad"));
                }
                Ok(answer(200, r#"{"apnsId":"x"}"#))
            });
            rig
        });
        let (result, _) = rig.notify("tmux:%3", "done");
        assert!(result.is_err());
        assert_eq!(
            read_last_notified(&rig.state_dir, "tmux:%3").as_deref(),
            Some("blocked")
        );
        // The Blocked push is still deduped.
        notified(&rig, "tmux:%3", "blocked");
        assert_eq!(rig.relay.posts().len(), 2);
    }

    #[test]
    fn a_deduped_change_still_refreshes_its_summary_and_a_410_prunes_the_token() {
        let rig = tmux_rig("blocked");
        rig.write_config(json!({"summary_enabled": true}));
        notified(&rig, "tmux:%3", "blocked");
        notified(&rig, "tmux:%3", "blocked");
        assert_eq!(rig.relay.posts().len(), 1);
        assert!(
            crate::summary::store::read_summary(&rig.config_dir.to_string_lossy(), "tmux:%3")
                .is_some()
        );
        let mut rig = tmux_rig("done");
        rig.relay_answers(|_, _| Ok(answer(410, r#"{"reason":"Unregistered"}"#)));
        notified(&rig, "tmux:%3", "done");
        assert_eq!(rig.relay.posts().len(), 1);
        assert!(read_eligible_devices(&rig.config_dir, "done").is_empty());
        // Nothing was delivered: the claim was released.
        assert_eq!(read_last_notified(&rig.state_dir, "tmux:%3"), None);
    }

    // test("release re-arms the pane for the next agent in it")
    #[test]
    fn release_rearms_the_pane_for_the_next_agent_in_it() {
        let rig = tmux_rig("blocked");
        notified(&rig, "tmux:%3", "blocked");
        assert_eq!(rig.relay.posts().len(), 1);

        // The agent leaves; its hook releases the pane before the options go.
        notified(&rig, "tmux:%3", "release");
        // A new agent in the same %N blocks.
        notified(&rig, "tmux:%3", "blocked");

        assert_eq!(rig.relay.posts().len(), 2);
        assert_eq!(rig.payload(1, &key_a()).1["status"], "blocked");
    }

    // test("an agent gone by the re-check sends nothing")
    #[test]
    fn an_agent_gone_by_the_recheck_sends_nothing() {
        let rig = tmux_rig("done");
        let host = Rc::clone(&rig.host);
        // SessionEnd unset every option before the hold ended.
        rig.clock.on_sleep(move || {
            *host.panes.borrow_mut() = Some(vec![TmuxPane {
                agent: String::new(),
                ..TmuxPane::default()
            }]);
        });

        notified(&rig, "tmux:%3", "done");

        assert!(rig.relay.posts().is_empty());
    }

    // test("a change whose agent is gone by the re-check re-arms the pane")
    #[test]
    fn a_change_whose_agent_is_gone_by_the_recheck_rearms_the_pane() {
        let rig = tmux_rig("done");
        notified(&rig, "tmux:%3", "done");

        // The agent exits; a new one's first change finds no options by the re-check.
        *rig.host.panes.borrow_mut() = Some(vec![TmuxPane {
            agent: String::new(),
            ..TmuxPane::default()
        }]);
        notified(&rig, "tmux:%3", "idle");
        *rig.host.panes.borrow_mut() = Some(vec![TmuxPane::with_status("done")]);
        notified(&rig, "tmux:%3", "done");

        assert_eq!(rig.relay.posts().len(), 2);
    }

    // test("the count combines Blocked and Done across tmux and a reachable herdr")
    #[test]
    fn the_count_combines_blocked_and_done_across_tmux_and_a_reachable_herdr() {
        let rig = tmux_rig("blocked");
        let pane = |id: &str, status: &str| TmuxPane {
            id: id.into(),
            ..TmuxPane::with_status(status)
        };
        *rig.host.panes.borrow_mut() = Some(vec![
            pane("%3", "blocked"),
            pane("%4", "done"),
            pane("%5", "working"),
        ]);
        rig.host.agent_list(Some(json!([
            {"pane_id": "w1:p1", "agent_status": "blocked", "agent": "claude"},
            {"pane_id": "w1:p2", "agent_status": "done", "agent": "codex"},
            {"pane_id": "w1:p3", "agent_status": "idle", "agent": "claude"},
        ])));

        notified(&rig, "tmux:%3", "blocked");

        assert_eq!(rig.payload(0, &key_a()).1["attention"], 4);
    }

    // test("tmux_enabled false sends nothing and never asks tmux")
    #[test]
    fn tmux_enabled_false_sends_nothing_and_never_asks_tmux() {
        let rig = tmux_rig("blocked");
        rig.write_config(json!({"tmux_enabled": false}));

        notified(&rig, "tmux:%3", "blocked");

        assert!(rig.relay.posts().is_empty());
        assert!(rig.host.calls_of("tmux", None).is_empty());
    }

    // test("fails closed when the re-check cannot list panes")
    #[test]
    fn fails_closed_when_the_recheck_cannot_list_panes() {
        let rig = tmux_rig("blocked");
        *rig.host.panes.borrow_mut() = None;

        let (result, _) = rig.notify("tmux:%3", "blocked");

        let error = result.unwrap_err();
        assert!(error.message().contains("no server running"), "{error}");
        assert!(rig.relay.posts().is_empty());
    }

    // The generator is a seam: the JS test also checks the `capture-pane`
    // arguments and the screen it fed the summarizer, which are
    // `generateAgentSummary`'s. The notify flow's part is ported.
    // test("a summary of the pane's screen rides the push and the Host store")
    #[test]
    fn a_summary_of_the_panes_screen_rides_the_push_and_the_host_store() {
        let rig = tmux_rig("blocked");
        rig.write_config(json!({"summary_enabled": true, "summary_command": ["/stub/summarize"]}));
        rig.summaries.says("Approve merge of PR #512");

        notified(&rig, "tmux:%3", "blocked");

        assert_eq!(
            rig.payload(0, &key_a()).1["summary"],
            "Approve merge of PR #512"
        );
        assert_eq!(
            rig.stored_summary("tmux:%3").unwrap()["summary"],
            "Approve merge of PR #512"
        );
        let asked = rig.summaries.requests.borrow().clone();
        assert_eq!(asked.len(), 1);
        assert_eq!(asked[0].pane_id, "tmux:%3");
        assert_eq!(asked[0].status, "blocked");
        assert_eq!(asked[0].herdr_bin, "herdr");
        assert_eq!(asked[0].command, Some(vec!["/stub/summarize".to_owned()]));
    }

    // test("rejects a pane id that is not tmux's and an unknown status")
    #[test]
    fn rejects_a_pane_id_that_is_not_tmuxs_and_an_unknown_status() {
        let rig = tmux_rig("blocked");

        let (result, _) = rig.notify("w1:p2", "blocked");
        assert!(
            result
                .unwrap_err()
                .message()
                .contains("not a tmux pane id: w1:p2")
        );
        let (result, _) = rig.notify("tmux:%3", "thinking");
        assert_eq!(result.unwrap_err().message(), "unknown status: thinking");
        let (result, _) = rig.notify("", "blocked");
        assert_eq!(result.unwrap_err().message(), "not a tmux pane id: ");

        assert!(rig.host.calls().is_empty());
    }

    // A raw `%3` is accepted and the status is case-insensitive.
    #[test]
    fn a_raw_pane_id_and_a_capitalized_status_are_accepted() {
        let rig = tmux_rig("blocked");

        notified(&rig, "%3", "Blocked");

        assert_eq!(rig.payload(0, &key_a()).1["pane"], "tmux:%3");
    }

    // Release clears the marker and reads nothing else of the Host.
    #[test]
    fn release_reads_no_config_and_no_pane() {
        let rig = tmux_rig("blocked");
        notified(&rig, "tmux:%3", "blocked");
        let marker = rig
            .state_dir
            .join("notify")
            .join(crate::atomic::pane_file_name("tmux:%3"));
        assert!(marker.exists());
        let tmux_calls = rig.host.calls_of("tmux", None).len();

        notified(&rig, "tmux:%3", "release");

        assert!(!marker.exists());
        assert_eq!(rig.host.calls_of("tmux", None).len(), tmux_calls);
    }

    // ---- acceptance: a bare Host, no Node, a status change sends the push request --------------

    /// A one-thread HTTP relay on a local port: it answers every request
    /// `200` and returns, when the listener is dropped by `count` requests,
    /// each request as text.
    fn serve(count: usize) -> (String, std::thread::JoinHandle<Vec<String>>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let handle = std::thread::spawn(move || {
            let mut requests = Vec::new();
            for _ in 0..count {
                let (mut stream, _) = listener.accept().unwrap();
                let mut request = Vec::new();
                let mut buf = [0u8; 4096];
                loop {
                    let n = stream.read(&mut buf).unwrap();
                    if n == 0 {
                        break;
                    }
                    request.extend_from_slice(&buf[..n]);
                    let text = String::from_utf8_lossy(&request);
                    if let Some((head, body)) = text.split_once("\r\n\r\n") {
                        let length = head
                            .lines()
                            .find_map(|line| {
                                let (name, value) = line.split_once(':')?;
                                name.eq_ignore_ascii_case("content-length")
                                    .then(|| value.trim().parse::<usize>().ok())
                                    .flatten()
                            })
                            .unwrap_or(0);
                        if body.len() >= length {
                            break;
                        }
                    }
                }
                let reply = r#"{"apnsId":"x"}"#;
                write!(
                    stream,
                    "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{reply}",
                    reply.len()
                )
                .unwrap();
                requests.push(String::from_utf8_lossy(&request).into_owned());
            }
            requests
        });
        (url, handle)
    }

    #[test]
    fn a_status_change_posts_to_a_relay_over_http_with_no_node_in_sight() {
        let rig = tmux_rig("blocked");
        let (relay_url, relay) = serve(2);
        rig.write_config(json!({"relay_url": relay_url, "debounce_ms": 0}));
        // The production network and clock; only tmux and herdr are the fake host's.
        let run = |cmd: &str, args: &[&str], env: &Env| rig.host.run(cmd, args, env);
        let deps = Deps {
            fetch: &HttpFetch,
            clock: &SystemClock,
            run: &run,
            summaries: &NoSummaries,
            chat: &NoChat,
        };
        let env = rig.tmux_env();
        let notify = |status: &str| {
            let mut stderr = String::new();
            run_tmux_notify("tmux:%3", status, &env, rig.home.path(), &deps, &mut stderr)
                .unwrap_or_else(|error| panic!("{error}"));
            assert_eq!(stderr, "");
        };

        notify("blocked");
        set_status(&rig, "done");
        notify("done");

        let requests = relay.join().unwrap();
        assert_eq!(requests.len(), 2);
        for (request, status) in requests.iter().zip(["blocked", "done"]) {
            let (head, body) = request.split_once("\r\n\r\n").unwrap();
            assert!(head.starts_with("POST /push HTTP/1.1\r\n"), "{head}");
            assert!(
                head.to_ascii_lowercase()
                    .contains("content-type: application/json"),
                "{head}"
            );
            let body: Value = serde_json::from_str(body).unwrap();
            let keys: Vec<_> = body.as_object().unwrap().keys().collect();
            assert_eq!(keys, ["token", "env", "envelope", "collapse"]);
            assert_eq!(body["token"], TOKEN_A);
            assert_eq!(body["env"], "sandbox");
            assert_eq!(body["collapse"], "YDTdflpNoB9At0EPaWEsOQ");
            let (_, plaintext) =
                crate::notify_fake::open_notification(body["envelope"].as_str().unwrap(), &key_a());
            let payload: Value = serde_json::from_str(&plaintext).unwrap();
            assert_eq!(payload["pane"], "tmux:%3");
            assert_eq!(payload["status"], status);
            assert_eq!(payload["project"], "proj");
        }
    }

    // ---- the pieces ---------------------------------------------------------------------------------

    #[test]
    fn node_base64_decoding_is_lenient_like_buffer_from() {
        let key = key_a();
        let url = base64::encode_url(&key);
        assert_eq!(base64::decode(&url), key);
        // Padding, the standard alphabet, whitespace and junk are all fine.
        assert_eq!(base64::decode(&format!("{url}=")), key);
        let standard = url.replace('-', "+").replace('_', "/");
        assert_eq!(base64::decode(&standard), key);
        assert_eq!(
            base64::decode(&format!("{} \n{}", &url[..10], &url[10..])),
            key
        );
        // `=` stops the decode; a unit above 255 counts by its low byte.
        assert_eq!(
            base64::decode(&format!("{}={}", &url[..20], &url[20..])).len(),
            15
        );
        assert_eq!(
            base64::decode(&format!("{}\u{141}{}", &url[..10], &url[10..])).len(),
            33
        );
        assert_eq!(base64::decode("A\u{141}").len(), 1);
        assert_eq!(base64::decode("\u{1F600}").len(), 0);
        assert_eq!(
            base64::decode(&format!("{}\u{1F600}{}", &url[..10], &url[10..])).len(),
            7
        );
        assert_eq!(base64::decode(""), Vec::<u8>::new());
    }

    #[test]
    fn the_collapse_key_hashes_the_key_and_the_pane() {
        assert_eq!(
            collapse_key_for(&key_a(), "w1:p2"),
            "VN_eCWTmYho49VTisasqZw"
        );
        assert_eq!(
            collapse_key_for(&key_a(), "tmux:%3"),
            "YDTdflpNoB9At0EPaWEsOQ"
        );
        assert_eq!(
            collapse_key_for(&key_b(), "w1:p2"),
            "jZIARHUzb9sRdDEnz5WzBQ"
        );
    }

    #[test]
    fn a_prefix_counts_utf16_units_and_marks_a_split_pair() {
        assert_eq!(utf16_prefix("abc", 8), "abc");
        assert_eq!(utf16_prefix("abcdefghij", 8), "abcdefgh");
        // The pair that straddles the cut is half a surrogate: U+FFFD on a terminal.
        assert_eq!(utf16_prefix("abcdefg\u{1F600}x", 8), "abcdefg\u{FFFD}");
        assert_eq!(utf16_prefix("abcdef\u{1F600}x", 8), "abcdef\u{1F600}");
    }

    #[test]
    fn attention_combines_both_backends_only_when_the_triggering_one_answers() {
        assert_eq!(combine_attention(Some(2), Some(3)), Some(5));
        assert_eq!(combine_attention(Some(2), None), Some(2));
        assert_eq!(combine_attention(None, Some(3)), None);
        assert_eq!(combine_attention(None, None), None);
    }

    #[test]
    fn eligible_devices_read_the_v1_registration_file() {
        let rig = Rig::herdr();
        let read = |status: &str| read_eligible_devices(&rig.config_dir, status);
        assert!(read("blocked").is_empty());

        rig.write_registration(&[
            device(),
            device()
                .token(TOKEN_B, key_b())
                .notify(json!({"blocked": false, "done": true})),
            // Entries that are not objects, and tokens that are not text, are skipped.
            device().token("", key_a()),
        ]);
        let mut file = rig.read_registration();
        file["devices"]
            .as_array_mut()
            .unwrap()
            .extend([json!(null), json!("x"), json!(7)]);
        std::fs::write(rig.config_dir.join("notifications.json"), file.to_string()).unwrap();

        assert_eq!(
            read("blocked"),
            vec![Device {
                provider: Provider::Apns,
                token: TOKEN_A.into(),
                env: "sandbox".into(),
                key: key_a()
            }]
        );
        assert_eq!(read("done").len(), 2);
        // Only Blocked and Done have a flag.
        assert!(read("working").is_empty());
        // A flag that is not the boolean true does not send.
        let mut file = rig.read_registration();
        file["devices"][0]["notify"]["blocked"] = json!("true");
        std::fs::write(rig.config_dir.join("notifications.json"), file.to_string()).unwrap();
        assert!(read("blocked").is_empty());
        // A registration whose devices are not an array, or a version of 1.5, holds none.
        std::fs::write(
            rig.config_dir.join("notifications.json"),
            r#"{"v":1,"devices":{}}"#,
        )
        .unwrap();
        assert!(read("done").is_empty());
        std::fs::write(
            rig.config_dir.join("notifications.json"),
            r#"{"v":1.5,"devices":[]}"#,
        )
        .unwrap();
        assert!(read("done").is_empty());
        std::fs::write(rig.config_dir.join("notifications.json"), "[]").unwrap();
        assert!(read("done").is_empty());
    }

    #[test]
    fn pruning_keeps_every_other_field_in_the_files_own_order() {
        let rig = Rig::herdr();
        let text = format!(
            r#"{{"v":1,"future":{{"b":1,"a":[1,2]}},"devices":[{{"token":"{TOKEN_A}","x":1}},{{"token":"{TOKEN_B}","y":2}},7]}}"#
        );
        std::fs::write(rig.config_dir.join("notifications.json"), text).unwrap();

        prune_tokens(&rig.config_dir, &[TOKEN_A]).unwrap();

        assert_eq!(
            std::fs::read_to_string(rig.config_dir.join("notifications.json")).unwrap(),
            format!(
                r#"{{"v":1,"future":{{"b":1,"a":[1,2]}},"devices":[{{"token":"{TOKEN_B}","y":2}},7]}}"#
            )
        );
        let mode = std::os::unix::fs::PermissionsExt::mode(
            &std::fs::metadata(rig.config_dir.join("notifications.json"))
                .unwrap()
                .permissions(),
        );
        assert_eq!(mode & 0o777, 0o600);
        // A foreign version or no file is left alone.
        std::fs::write(
            rig.config_dir.join("notifications.json"),
            r#"{"v":2,"devices":[]}"#,
        )
        .unwrap();
        prune_tokens(&rig.config_dir, &[TOKEN_A]).unwrap();
        assert_eq!(
            std::fs::read_to_string(rig.config_dir.join("notifications.json")).unwrap(),
            r#"{"v":2,"devices":[]}"#
        );
    }

    #[test]
    fn the_dedupe_marker_is_the_files_the_js_writes() {
        let rig = Rig::herdr();
        let path = state_path(&rig.state_dir, "w1:p\"2");
        std::fs::create_dir_all(rig.state_dir.join("notify")).unwrap();
        // Legacy markers have no claim token and still dedupe normally.
        std::fs::write(
            &path,
            r#"{"pane":"w1:p\"2","last_notified_status":"blocked"}"#,
        )
        .unwrap();
        assert_eq!(
            claim_notification(&rig.state_dir, "w1:p\"2", "blocked").unwrap(),
            None
        );
        assert_eq!(
            read_last_notified(&rig.state_dir, "w1:p\"2").as_deref(),
            Some("blocked")
        );
        clear_last_notified(&rig.state_dir, "w1:p\"2");
        assert_eq!(read_last_notified(&rig.state_dir, "w1:p\"2"), None);
        std::fs::create_dir_all(rig.state_dir.join("notify")).unwrap();
        std::fs::write(&path, r#"{"last_notified_status":7}"#).unwrap();
        assert_eq!(read_last_notified(&rig.state_dir, "w1:p\"2"), None);
    }

    #[test]
    fn a_failed_delivery_names_the_token_and_the_relay_answer() {
        let fetch = crate::notify_fake::RecordingFetch::new(|_, index| match index {
            0 => Ok(answer(429, "slow down")),
            1 => Err(CliError::failure("connection refused")),
            _ => Ok(answer(503, &"é".repeat(150))),
        });
        let clock = FakeClock::ticking(0);
        let device = Device {
            provider: Provider::Apns,
            token: TOKEN_A.into(),
            env: "sandbox".into(),
            key: key_a(),
        };

        let failure =
            post_push(&fetch, &clock, "http://relay.test", &device, "{}", "c", 25).unwrap_err();

        assert_eq!(fetch.posts().len(), 3);
        assert_eq!(
            clock.sleeps(),
            vec![Duration::from_millis(25), Duration::from_millis(25)]
        );
        assert_eq!(
            failure,
            format!(
                "push for token aaaaaaaa… failed: relay answered 503: {}",
                "é".repeat(150)
            )
        );
        let body = &fetch.posts()[0].body;
        assert_eq!(
            serde_json::to_string(body).unwrap(),
            format!(r#"{{"token":"{TOKEN_A}","env":"sandbox","envelope":"{{}}","collapse":"c"}}"#)
        );
        // A relay that never answers fails with the reason.
        let down =
            crate::notify_fake::RecordingFetch::new(|_, _| Err(CliError::failure("fetch failed")));
        assert_eq!(
            post_push(&down, &clock, "http://relay.test", &device, "{}", "c", 0).unwrap_err(),
            "push for token aaaaaaaa… failed: relay unreachable: fetch failed"
        );
    }

    #[test]
    fn a_seal_that_fails_aborts_the_run_before_any_post() {
        // A project name longer than the envelope's limit makes the seal throw;
        // as in the JS the throw escapes the delivery loop.
        struct Bad;
        impl Backend for Bad {
            type Detail = ();
            fn recheck(&self) -> Result<Option<Current<()>>> {
                Ok(Some(Current {
                    status: "blocked".into(),
                    agent_kind: None,
                    detail: (),
                }))
            }
            fn summarize(&self, _budget_ms: u64) -> Summary {
                Summary::default()
            }
            fn describe(&self, _current: &Current<()>) -> Labels {
                Labels {
                    project: Some("x".repeat(300)),
                    title: None,
                }
            }
            fn attention(&self) -> Option<u64> {
                None
            }
        }
        let rig = Rig::herdr();
        rig.write_config(json!({}));
        rig.write_registration(&[device(), device().token(TOKEN_B, key_b())]);
        let config = read_notification_config(&rig.config_dir.to_string_lossy()).unwrap();
        let flow = Flow {
            config_dir: &rig.config_dir,
            state_dir: &rig.state_dir,
            config: &config,
            fetch: &*rig.relay,
            clock: &*rig.clock,
        };
        let event = Event {
            pane_id: PANE_ID.into(),
            status: "blocked".into(),
            agent_kind: None,
        };
        let mut stderr = String::new();

        let error = run_notification(&flow, &event, NOW_MS, &Bad, &mut stderr).unwrap_err();

        assert_eq!(error.message(), "project must be at most 256 characters");
        assert!(rig.relay.posts().is_empty());
        assert!(!state_path(&rig.state_dir, PANE_ID).exists());
    }

    #[test]
    fn a_hold_longer_than_the_debounce_is_not_slept_twice() {
        let rig = Rig::herdr();
        rig.write_config(json!({"summary_enabled": true}));
        rig.write_registration(&[device()]);
        rig.herdr_answers(herdr_stub("done"));
        let clock = Rc::clone(&rig.clock);
        rig.summaries.answer(move |_| {
            clock.advance(DEBOUNCE_MS - 20);
            Summary::default()
        });
        let event = json!({"data": {"pane_id": PANE_ID, "agent_status": "done"}});
        let env = rig.hook_env(&event.to_string());

        let outcome = rig.hook_with(&env);

        assert_eq!(outcome.code, 0, "{}", outcome.stderr);
        assert_eq!(rig.clock.sleeps(), vec![Duration::from_millis(20)]);
    }
}

#[cfg(test)]
#[path = "notify_core_hc_tests.rs"]
mod hc_tests;
