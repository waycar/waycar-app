//! Agent Notification notify hook (notify-hook.js; ADR 0008).
//!
//! herdr invokes the hook through the manifest `[[events]]` entry on
//! `pane.agent_status_changed`, one short-lived process per event, with the
//! event in `HERDR_PLUGIN_EVENT_JSON` (not on stdin), and the directories and
//! the CLI in `HERDR_PLUGIN_CONFIG_DIR`, `HERDR_PLUGIN_STATE_DIR` and
//! `HERDR_BIN_PATH`. The flow:
//!
//! ```text
//! event JSON ──> debounce sleep ──> re-check status via HERDR_BIN_PATH
//!   ──> dedupe per pane (HERDR_PLUGIN_STATE_DIR) ──> read registration file
//!   ──> count the Host's Blocked/Done agents (`herdr agent list`, plus the
//!       tmux panes unless notify.json sets `tmux_enabled: false`)
//!   ──> encrypt envelope per device ──> POST to the Push Relay per token
//! ```
//!
//! The flow itself is `notify_core`, shared with the tmux trigger
//! (`waycar notify`), so a Host running both backends keeps one producer;
//! this module is the herdr backend: event parsing, the `herdr agent get`
//! re-check, workspace labels, Chat Mode and Chat Marker collection.
//!
//! A Blocked or Done event also starts an Agent Summary alongside the
//! debounce sleep ([`AgentSummaries`]). A confirmed status records the
//! summary (or, without one, a tombstone) in the Host's summary store for the
//! app's agent list, and carries it in the push. A missing summary never fails
//! a notification, and the summary is kept even when no device is registered
//! for pushes.
//!
//! A Done push for a Chat Mode Agent (a pane with a Chat Marker) carries the
//! Agent's final reply instead ([`ChatMode`]): the hook skips the summary,
//! and after the re-check reads the reply from the harness's own transcript.
//! A reader that finds no reply falls back to the summary, within what is left
//! of its budget. Every hook run also garbage collects the markers of panes
//! the agent list no longer shows (a `tmux:` marker: of tmux panes that no
//! longer exist), at most hourly, and never while named herdr sessions share
//! the Host.
//!
//! Event JSON shape, captured against a live herdr 0.7.5 (the envelope
//! `event` name is snake_case on the wire even though the manifest hook
//! subscribes to the dot name):
//!
//! ```json
//! {"event":"pane_agent_status_changed",
//!  "data":{"type":"pane_agent_status_changed","pane_id":"wV:p1",
//!          "workspace_id":"wV","agent_status":"blocked","agent":"claude"}}
//! ```
//!
//! `agent` (and per herdr source: `title`, `display_agent`, `state_labels`)
//! are optional; herdr's wire shapes carry no stability guarantee, so parsing
//! is lenient: only `data.pane_id` and `data.agent_status` are required and
//! unknown fields are ignored.

use std::borrow::Cow;
use std::path::Path;

use serde_json::Value;

use crate::activity_state::attention_count;
use crate::chat::marker::{Marker, MarkerSession};
use crate::display_text::{for_display_str, optional_text};
use crate::env::Env;
use crate::error::{CliError, EXIT_FAILURE, EXIT_OK, Result};
use crate::exec::{EXIT_NOT_STARTED, RunResult};
use crate::hook_session::parse_hook_input;
use crate::jsx;
use crate::notification_config::{NotificationConfig, read_notification_config};
use crate::notify_core::{
    AgentSummaries, Backend, ChatMode, ChatRead, Current, Deps, Event, Flow, Labels, MarkerGc,
    MarkerProbe, ReplyRequest, Summary, SummaryRequest, collect_markers_logged, combine_attention,
    core_attention_share, live_core_pane_ids, log, run_notification, sum_shares,
    tidy_summary_store, tmux_attention_count,
};
use crate::paths::home_dir;
use crate::sidebar_config::refresh_sidebar_snapshot;
use crate::tmux::{Runner, to_waycar_pane_id};

/// The herdr hook's exit code and what it prints on stderr (line breaks
/// included); it prints nothing on stdout.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NotifyOutcome {
    pub code: i32,
    pub stderr: String,
}

/// The parsed `pane_agent_status_changed` event.
#[derive(Debug, Clone, PartialEq, Eq)]
struct StatusEvent {
    pane_id: String,
    /// Lower-cased.
    status: String,
    agent_kind: Option<String>,
    workspace_id: Option<String>,
    title: Option<String>,
}

fn owned(value: Option<&Value>) -> Option<String> {
    optional_text(value).map(str::to_owned)
}

/// Parse `HERDR_PLUGIN_EVENT_JSON` leniently: require pane id and status only.
fn parse_status_event(raw: &str) -> Result<StatusEvent> {
    let Some(parsed) = parse_hook_input(raw) else {
        return Err(CliError::failure("HERDR_PLUGIN_EVENT_JSON is not JSON"));
    };
    let data = parsed.get("data").and_then(Value::as_object);
    let required = |name: &str, message: &str| -> Result<String> {
        match data.and_then(|data| data.get(name)) {
            Some(Value::String(text)) if !text.is_empty() => Ok(text.clone()),
            _ => Err(CliError::failure(message)),
        }
    };
    let pane_id = required("pane_id", "event data.pane_id missing")?;
    let status = required("agent_status", "event data.agent_status missing")?;
    let field = |name: &str| data.and_then(|data| data.get(name));
    Ok(StatusEvent {
        pane_id,
        status: status.to_lowercase(),
        agent_kind: owned(field("agent")),
        workspace_id: owned(field("workspace_id")),
        title: owned(field("title")),
    })
}

/// A herdr CLI invocation (`runHerdr`): `HERDR_BIN_PATH` with the hook's own
/// environment.
#[derive(Clone, Copy)]
struct Herdr<'a> {
    bin: &'a str,
    env: &'a Env,
    run: Runner<'a>,
}

impl Herdr<'_> {
    fn run(&self, args: &[&str]) -> RunResult {
        (self.run)(self.bin, args, self.env)
    }
}

/// What the reply push needs of the re-check besides the status: each field
/// `None` when absent or malformed.
#[derive(Debug, Clone, PartialEq, Eq)]
struct HerdrDetail {
    workspace_id: Option<String>,
    title: Option<String>,
    terminal_id: Option<String>,
    cwd: Option<String>,
    agent_session: Option<MarkerSession>,
}

/// herdr's `agent_session` as a reader session, or `None` when unusable.
fn session_reference(session: Option<&Value>) -> Option<MarkerSession> {
    let session = session?.as_object()?;
    let kind = match session.get("kind") {
        Some(Value::String(kind)) if kind == "id" || kind == "path" => kind.clone(),
        _ => return None,
    };
    let value = optional_text(session.get("value"))?;
    Some(MarkerSession {
        kind,
        value: value.to_owned(),
    })
}

/// Re-check the pane's current Agent Status through the herdr CLI
/// (`herdr agent get <pane>` answers `{"result":{"agent":{"agent_status":...}}}`
/// on the same wire shape as `agent.list`; verified against herdr 0.7.5).
/// Also returns what the reply push needs: `terminal_id`, `cwd` and the
/// `agent_session` reference.
/// `None` when the agent is gone (`agent_not_found`); any other failure is an
/// `Err`, so an un-runnable re-check fails closed instead of notifying blind.
fn current_agent_status(herdr: Herdr<'_>, pane_id: &str) -> Result<Option<Current<HerdrDetail>>> {
    let result = herdr.run(&["agent", "get", pane_id]);
    // A CLI that could not be started is the spawn error itself, as in the JS.
    if result.code == EXIT_NOT_STARTED && result.stderr.starts_with("spawn ") {
        return Err(CliError::failure(result.stderr));
    }
    let parsed = parse_hook_input(&result.stdout);
    if result.code != 0 {
        let code = parsed
            .as_ref()
            .and_then(|parsed| parsed.get("error")?.get("code")?.as_str());
        if code == Some("agent_not_found") {
            return Ok(None);
        }
        let stderr = jsx::trim(&result.stderr);
        let detail = if stderr.is_empty() {
            jsx::trim(&result.stdout)
        } else {
            stderr
        };
        return Err(CliError::failure(format!(
            "status re-check failed (exit {}): {detail}",
            result.code
        )));
    }
    let agent = parsed
        .as_ref()
        .and_then(|parsed| parsed.get("result")?.get("agent")?.as_object());
    let Some((status, agent)) = agent.and_then(|agent| {
        let status = agent.get("agent_status")?.as_str()?;
        Some((status, agent))
    }) else {
        return Err(CliError::failure(
            "status re-check returned no agent_status",
        ));
    };
    Ok(Some(Current {
        status: status.to_lowercase(),
        agent_kind: owned(agent.get("agent")),
        detail: HerdrDetail {
            workspace_id: owned(agent.get("workspace_id")),
            // Prefer the stripped title: the raw one carries herdr's spinner glyphs.
            title: owned(agent.get("terminal_title_stripped"))
                .or_else(|| owned(agent.get("terminal_title"))),
            terminal_id: owned(agent.get("terminal_id")),
            cwd: owned(agent.get("cwd")),
            agent_session: session_reference(agent.get("agent_session")),
        },
    }))
}

/// Resolve a workspace's display label, the project name the app's alert leads
/// with (`herdr workspace get <id>` answers
/// `{"result":{"workspace":{"label":...}}}`; verified against herdr 0.7.5).
///
/// Purely decorative, so every failure yields `None`: a Host that cannot
/// answer still notifies, one step less specific.
fn workspace_label(herdr: Herdr<'_>, workspace_id: Option<&str>) -> Option<String> {
    let result = herdr.run(&["workspace", "get", workspace_id?]);
    if result.code != 0 {
        return None;
    }
    let parsed = parse_hook_input(&result.stdout)?;
    owned(parsed.get("result")?.get("workspace")?.get("label"))
}

/// A fresh `herdr agent list`: the Host's attention count (Blocked + Done
/// agents, its share of the app's Attention Badge), or the live panes for Chat
/// Marker garbage collection.
///
/// Best-effort like the workspace label: any failure yields `None`, the
/// payload omits the count, and the app leaves its badge alone rather than
/// trusting a guess.
fn list_agents(herdr: Herdr<'_>) -> Option<Vec<Value>> {
    let result = herdr.run(&["agent", "list"]);
    if result.code != 0 {
        return None;
    }
    let mut listing = parse_hook_input(&result.stdout)?;
    match listing.get_mut("result")?.get_mut("agents")?.take() {
        Value::Array(agents) => Some(agents),
        _ => None,
    }
}

/// The `tmux:%N` ids of every tmux pane on the Host (not only Agents with hook
/// options, so screen-detected Agents keep their markers), or `None` when tmux
/// cannot list them.
fn live_tmux_pane_ids(env: &Env, run: Runner<'_>) -> Option<Vec<String>> {
    let result = run("tmux", &["-u", "list-panes", "-a", "-F", "#{pane_id}"], env);
    if result.code != 0 {
        return None;
    }
    Some(
        result
            .stdout
            .split('\n')
            .filter(|id| {
                id.strip_prefix('%').is_some_and(|digits| {
                    !digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit())
                })
            })
            .map(to_waycar_pane_id)
            .collect(),
    )
}

/// Hourly Chat Marker garbage collection, run by every hook before any early
/// return; the agent list is fetched only when a run is due and markers exist.
/// A `tmux:` marker (written by the tmux transport into the same dir) is live
/// while its tmux pane exists, and is never deleted while tmux is disabled or
/// cannot be listed. Never fatal.
fn collect_chat_markers(
    herdr: Herdr<'_>,
    config_dir: &Path,
    state_dir: &Path,
    config: &NotificationConfig,
    home: &Path,
    deps: &Deps<'_>,
    stderr: &mut String,
) {
    let now_ms = deps.clock.now_ms();
    if !deps.chat.gc_due(state_dir, now_ms) || !deps.chat.has_markers(config_dir) {
        return;
    }
    let Some(agents) = list_agents(herdr) else {
        return;
    };
    let live_pane_ids = agents
        .iter()
        .filter_map(|agent| agent.get("pane_id")?.as_str().map(str::to_owned))
        .collect();
    let request = MarkerGc {
        config_dir,
        state_dir,
        live_pane_ids: Some(live_pane_ids),
        live_tmux_pane_ids: if config.tmux_enabled {
            live_tmux_pane_ids(herdr.env, herdr.run)
        } else {
            None
        },
        live_core_pane_ids: live_core_pane_ids(config, herdr.env, home, herdr.run),
        now_ms,
    };
    collect_markers_logged(deps.chat, &request, stderr);
}

/// The herdr backend of the shared flow.
struct HerdrBackend<'a> {
    herdr: Herdr<'a>,
    event: &'a StatusEvent,
    flow: &'a Flow<'a>,
    tmux_enabled: bool,
    home: &'a Path,
    summaries: &'a dyn AgentSummaries,
    chat: &'a dyn ChatMode,
}

impl HerdrBackend<'_> {
    /// The final reply for a Chat Mode push, or `None` to build the push as for
    /// any other Agent: the marker does not describe the Agent on the pane now,
    /// the transcript is missing or unreadable, the reader still holds the turn
    /// open (its newest assistant message answers an earlier prompt), or the
    /// turn ended without text.
    /// Session precedence: the live `agent_session` (it follows `/clear`), then
    /// the marker's.
    fn read_reply(
        &self,
        marker: &Marker,
        current: &Current<HerdrDetail>,
        stderr: &mut String,
    ) -> Option<String> {
        let kind = current
            .agent_kind
            .as_deref()
            .or(self.event.agent_kind.as_deref());
        let live = current.detail.agent_session.as_ref();
        let probe = MarkerProbe {
            kind,
            terminal_id: current.detail.terminal_id.as_deref(),
            agent_session: live,
        };
        if !self.chat.marker_applies(marker, &probe) {
            return None;
        }
        let request = ReplyRequest {
            config_dir: self.flow.config_dir,
            kind,
            session: live.or(marker.session.as_ref()),
            cwd: current.detail.cwd.as_deref().or(marker.cwd.as_deref()),
            launched_at: marker.launched_at.as_deref(),
        };
        match self.chat.read_chat(&request) {
            Ok(turn) => {
                if let ChatRead::Error(error) = &turn.read {
                    log(stderr, format!("notify-hook: chat reply not read: {error}"));
                }
                if turn.read != ChatRead::Ok || turn.turn_open {
                    return None;
                }
                turn.last_reply.filter(|reply| !jsx::trim(reply).is_empty())
            }
            Err(message) => {
                log(
                    stderr,
                    format!("notify-hook: chat reply not read: {message}"),
                );
                None
            }
        }
    }
}

impl Backend for HerdrBackend<'_> {
    type Detail = HerdrDetail;

    fn recheck(&self) -> Result<Option<Current<HerdrDetail>>> {
        current_agent_status(self.herdr, &self.event.pane_id)
    }

    fn summarize(&self, budget_ms: u64) -> Summary {
        self.summaries.generate(&SummaryRequest {
            herdr_bin: self.herdr.bin,
            pane_id: &self.event.pane_id,
            status: &self.event.status,
            command: self.flow.config.summary_command.as_deref(),
            timeout_ms: budget_ms,
            work_dir: self.flow.state_dir,
            cache_dir: self.flow.config_dir,
            env: self.herdr.env,
            run: self.herdr.run,
        })
    }

    // The re-check is the fresher read for anything that can change while the
    // debounce sleeps (the title moves with the agent's task); the event is
    // the fallback for whatever it did not carry.
    fn describe(&self, current: &Current<HerdrDetail>) -> Labels {
        let workspace = current
            .detail
            .workspace_id
            .as_deref()
            .or(self.event.workspace_id.as_deref());
        let trimmed = |text: Option<&str>| text.and_then(for_display_str).map(Cow::into_owned);
        Labels {
            project: trimmed(workspace_label(self.herdr, workspace).as_deref()),
            title: trimmed(
                current
                    .detail
                    .title
                    .as_deref()
                    .or(self.event.title.as_deref()),
            ),
        }
    }

    fn attention(&self) -> Option<u64> {
        combine_attention(
            list_agents(self.herdr).map(|agents| u64::from(attention_count(&agents))),
            sum_shares(
                if self.tmux_enabled {
                    tmux_attention_count(self.herdr.env, self.herdr.run)
                } else {
                    None
                },
                core_attention_share(self.flow.config, self.herdr.env, self.home, self.herdr.run),
            ),
        )
    }

    fn read_chat_marker(&self) -> Option<Marker> {
        self.chat
            .read_marker(self.flow.config_dir, &self.event.pane_id)
    }

    fn chat_reply(
        &self,
        marker: &Marker,
        current: &Current<HerdrDetail>,
        stderr: &mut String,
    ) -> Option<String> {
        self.read_reply(marker, current, stderr)
    }
}

fn require_env<'a>(env: &'a Env, name: &str) -> Result<&'a str> {
    env.non_empty(name).ok_or_else(|| {
        CliError::failure(format!(
            "{name} is not set; this script must run as a herdr event hook"
        ))
    })
}

fn run(env: &Env, deps: &Deps<'_>, stderr: &mut String) -> Result<()> {
    let config_dir = Path::new(require_env(env, "HERDR_PLUGIN_CONFIG_DIR")?);
    // A snapshot write failure must not prevent notification delivery
    // (`refreshSidebarSnapshotForEvent`).
    if let Err(error) = refresh_sidebar_snapshot(config_dir, env, &|| deps.clock.now_ms()) {
        log(
            stderr,
            format!("sidebar-hook: snapshot refresh failed ({})", error.code),
        );
    }
    let event_json = require_env(env, "HERDR_PLUGIN_EVENT_JSON")?;
    let state_dir = Path::new(require_env(env, "HERDR_PLUGIN_STATE_DIR")?);
    let bin = require_env(env, "HERDR_BIN_PATH")?;

    let config =
        read_notification_config(&config_dir.to_string_lossy()).map_err(CliError::failure)?;
    tidy_summary_store(config_dir, config.summary_enabled, deps.clock, stderr);
    let herdr = Herdr {
        bin,
        env,
        run: deps.run,
    };
    let home = home_dir(env).unwrap_or_default();
    collect_chat_markers(herdr, config_dir, state_dir, &config, &home, deps, stderr);

    let event = parse_status_event(event_json)?;
    let event_at = deps.clock.now_ms();
    let flow = Flow {
        config_dir,
        state_dir,
        config: &config,
        fetch: deps.fetch,
        clock: deps.clock,
    };
    let backend = HerdrBackend {
        herdr,
        event: &event,
        flow: &flow,
        tmux_enabled: config.tmux_enabled,
        home: &home,
        summaries: deps.summaries,
        chat: deps.chat,
    };
    let core_event = Event {
        pane_id: event.pane_id.clone(),
        status: event.status.clone(),
        agent_kind: event.agent_kind.clone(),
    };
    run_notification(&flow, &core_event, event_at, &backend, stderr)
}

/// The herdr `[[events]]` hook: one `pane.agent_status_changed` event, read
/// from `env` like the JS reads `process.env`. Exit 0 when the event needed
/// nothing or was handled; 1, with `notify-hook: <message>` on stderr, when it
/// could not be (an event without a pane or status, a re-check that could not
/// run, a delivery that failed).
pub fn run_herdr_notify(env: &Env, deps: &Deps<'_>) -> NotifyOutcome {
    let mut stderr = String::new();
    match run(env, deps, &mut stderr) {
        Ok(()) => NotifyOutcome {
            code: EXIT_OK,
            stderr,
        },
        Err(error) => {
            log(&mut stderr, format!("notify-hook: {}", error.message()));
            NotifyOutcome {
                code: EXIT_FAILURE,
                stderr,
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::rc::Rc;
    use std::time::Duration;

    use serde_json::{Value, json};

    use super::*;
    use crate::exec::run_program;
    use crate::notify_core::{ChatTurn, NoChat, NoSummaries};
    use crate::notify_fake::rig::*;
    use crate::notify_fake::{TmuxPane, answer};

    // The JS tests drive a real child process with a stub HERDR_BIN_PATH, a
    // stub tmux and an in-test relay server; these drive the same flow in
    // process through the runner, clock and relay seams, with the fake host
    // answering as the stubs do.

    fn event_with(status: &str, agent: Option<&str>, pane: &str, extra: Value) -> Value {
        let mut data = json!({
            "type": "pane_agent_status_changed",
            "pane_id": pane,
            "workspace_id": "w1",
            "agent_status": status,
        });
        if let Some(agent) = agent {
            data["agent"] = json!(agent);
        }
        for (name, value) in extra.as_object().unwrap() {
            data[name] = value.clone();
        }
        json!({"event": "pane_agent_status_changed", "data": data})
    }

    fn status_event(status: &str) -> Value {
        event_with(status, Some("claude"), PANE_ID, json!({}))
    }

    /// A herdr Host with its config written and `devices` registered.
    fn setup(devices: &[Dev]) -> Rig {
        let rig = Rig::herdr();
        rig.write_config(json!({}));
        rig.write_registration(devices);
        rig
    }

    fn herdr_calls_of(rig: &Rig, subcommand: &str) -> Vec<Vec<String>> {
        let bin = rig.path("stub/herdr").to_string_lossy().into_owned();
        rig.host
            .calls_of(&bin, Some(subcommand))
            .into_iter()
            .map(|call| call.args)
            .collect()
    }

    fn payload_keys(payload: &Value) -> Vec<&str> {
        payload
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect()
    }

    fn assert_ok(outcome: &NotifyOutcome) {
        assert_eq!(outcome.code, 0, "{}", outcome.stderr);
    }

    // ---- suite("notify-hook: sending") ----------------------------------------------

    // test("a confirmed Blocked transition posts one decryptable push per device")
    #[test]
    fn a_confirmed_blocked_transition_posts_one_decryptable_push_per_device() {
        let rig = setup(&[device(), device().token(TOKEN_B, key_b()).env("production")]);
        rig.herdr_answers(herdr_stub("blocked"));

        let outcome = rig.hook(&status_event("blocked"));

        assert_ok(&outcome);
        let posts = rig.relay.posts();
        assert_eq!(posts.len(), 2);
        for post in &posts {
            assert_eq!(post.url, "http://relay.test/push");
        }
        let for_a = posts.iter().find(|p| p.body["token"] == TOKEN_A).unwrap();
        let for_b = posts.iter().find(|p| p.body["token"] == TOKEN_B).unwrap();
        assert_eq!(for_a.body["env"], "sandbox");
        assert_eq!(for_b.body["env"], "production");
        let (kid_a, a) = rig.payload(0, &key_a());
        let (kid_b, b) = rig.payload(1, &key_b());
        for payload in [&a, &b] {
            assert_eq!(payload["pane"], PANE_ID);
            assert_eq!(payload["kind"], "claude");
            assert_eq!(payload["status"], "blocked");
            assert_eq!(payload["ts"], NOW_MS / 1000);
        }
        assert_ne!(kid_a, kid_b);
    }

    // test("the collapse key is opaque, per pane, and stable across sends")
    #[test]
    fn the_collapse_key_is_opaque_per_pane_and_stable_across_sends() {
        let rig = setup(&[device()]);
        rig.herdr_answers(herdr_stub("blocked"));
        rig.hook(&status_event("blocked"));

        rig.herdr_answers(herdr_stub("done"));
        rig.hook(&status_event("done"));

        let posts = rig.relay.posts();
        assert_eq!(posts.len(), 2);
        let first = posts[0].body["collapse"].as_str().unwrap().to_owned();
        let second = posts[1].body["collapse"].as_str().unwrap();
        assert!(!first.is_empty() && first.len() <= 64);
        // Same pane -> same collapse key, so a newer status replaces the older
        // notification; and the key must not leak the pane id to the relay.
        assert_eq!(first, second);
        assert!(!first.contains(PANE_ID));
        assert_eq!(first, "VN_eCWTmYho49VTisasqZw");

        // A different pane collapses independently.
        rig.herdr_answers(herdr_stub("blocked"));
        rig.hook(&event_with("blocked", Some("claude"), "w9:p9", json!({})));
        let posts = rig.relay.posts();
        assert_eq!(posts.len(), 3);
        assert_ne!(posts[2].body["collapse"].as_str().unwrap(), first);
    }

    // test("a Done transition with a missing event agent falls back to the re-checked agent kind")
    #[test]
    fn a_done_transition_with_a_missing_event_agent_falls_back_to_the_rechecked_agent_kind() {
        let rig = setup(&[device()]);
        rig.herdr_answers(herdr_stub("done").agent("codex"));

        let outcome = rig.hook(&event_with("done", None, PANE_ID, json!({})));

        assert_ok(&outcome);
        assert_eq!(rig.relay.posts().len(), 1);
        let (_, payload) = rig.payload(0, &key_a());
        assert_eq!(payload["kind"], "codex");
        assert_eq!(payload["status"], "done");
    }

    // test("the payload carries the project name and the agent's task title")
    #[test]
    fn the_payload_carries_the_project_name_and_the_agents_task_title() {
        let rig = setup(&[device()]);
        rig.herdr_answers(
            herdr_stub("blocked")
                .title("排查修复 split 按钮 UI 结构问题")
                .label(Some("Caterm")),
        );

        let outcome = rig.hook(&status_event("blocked"));

        assert_ok(&outcome);
        let (_, payload) = rig.payload(0, &key_a());
        assert_eq!(payload["project"], "Caterm");
        assert_eq!(payload["title"], "排查修复 split 按钮 UI 结构问题");
        // The label is resolved for the workspace the re-check reports.
        assert_eq!(
            herdr_calls_of(&rig, "workspace")[0],
            ["workspace", "get", "w1"]
        );
    }

    // test("a title longer than the display limit is trimmed with an ellipsis")
    #[test]
    fn a_title_longer_than_the_display_limit_is_trimmed_with_an_ellipsis() {
        let rig = setup(&[device()]);
        let long: &'static str = Box::leak("重构传输层".repeat(40).into_boxed_str());
        rig.herdr_answers(herdr_stub("blocked").title(long));

        rig.hook(&status_event("blocked"));

        let (_, payload) = rig.payload(0, &key_a());
        let title = payload["title"].as_str().unwrap();
        assert_eq!(title.chars().count(), 80);
        assert!(title.ends_with('…'));
        let kept: String = title.chars().take(79).collect();
        assert!(long.starts_with(&kept));
    }

    // test("an unresolvable workspace label just omits the project")
    #[test]
    fn an_unresolvable_workspace_label_just_omits_the_project() {
        let rig = setup(&[device()]);
        rig.herdr_answers(
            herdr_stub("blocked")
                .title("Fix the flaky test")
                .label(None),
        );

        let outcome = rig.hook(&status_event("blocked"));

        assert_ok(&outcome);
        let (_, payload) = rig.payload(0, &key_a());
        assert!(payload.get("project").is_none());
        assert_eq!(payload["title"], "Fix the flaky test");
    }

    // test("an agent with no title at all still notifies")
    #[test]
    fn an_agent_with_no_title_at_all_still_notifies() {
        let rig = setup(&[device()]);
        rig.herdr_answers(herdr_stub("done"));

        let outcome = rig.hook(&status_event("done"));

        assert_ok(&outcome);
        let (_, payload) = rig.payload(0, &key_a());
        assert!(payload.get("title").is_none());
        assert_eq!(payload["status"], "done");
    }

    // test("the payload carries this Host's Blocked and Done agent count")
    #[test]
    fn the_payload_carries_this_hosts_blocked_and_done_agent_count() {
        let rig = setup(&[device()]);
        rig.herdr_answers(herdr_stub("blocked").list(AgentList::Given(json!([
            {"pane_id": PANE_ID, "agent_status": "blocked", "agent": "claude"},
            {"pane_id": "w1:p3", "agent_status": "done", "agent": "codex"},
            {"pane_id": "w2:p1", "agent_status": "working", "agent": "claude"},
            {"pane_id": "w2:p2", "agent_status": "idle", "agent": "claude"},
        ]))));

        let outcome = rig.hook(&status_event("blocked"));

        assert_ok(&outcome);
        assert_eq!(rig.payload(0, &key_a()).1["attention"], 2);
    }

    // test("an agent list that cannot be read omits the count but still notifies")
    #[test]
    fn an_agent_list_that_cannot_be_read_omits_the_count_but_still_notifies() {
        let rig = setup(&[device()]);
        rig.herdr_answers(herdr_stub("blocked").list(AgentList::Failing));

        let outcome = rig.hook(&status_event("blocked"));

        assert_ok(&outcome);
        assert_eq!(rig.relay.posts().len(), 1);
        let (_, payload) = rig.payload(0, &key_a());
        assert!(payload.get("attention").is_none());
        assert_eq!(payload["status"], "blocked");
    }

    // test("the count adds the Host's Blocked and Done tmux panes")
    #[test]
    fn the_count_adds_the_hosts_blocked_and_done_tmux_panes() {
        let rig = setup(&[device()]);
        rig.herdr_answers(herdr_stub("blocked")); // herdr: this pane, Blocked
        let pane = |id: &str, status: &str| TmuxPane {
            id: id.into(),
            ..TmuxPane::with_status(status)
        };
        *rig.host.panes.borrow_mut() = Some(vec![
            pane("%1", "blocked"),
            TmuxPane {
                agent: "codex".into(),
                command: "codex".into(),
                ..pane("%2", "done")
            },
            pane("%3", "working"),
            // Stale options under a shell, and a pane without any, never count.
            TmuxPane {
                command: "zsh".into(),
                ..pane("%4", "done")
            },
            TmuxPane {
                agent: String::new(),
                ..pane("%5", "")
            },
        ]);

        let outcome = rig.hook(&status_event("blocked"));

        assert_ok(&outcome);
        assert_eq!(rig.payload(0, &key_a()).1["attention"], 3);
    }

    // test("a Host without a tmux server counts herdr alone")
    #[test]
    fn a_host_without_a_tmux_server_counts_herdr_alone() {
        let rig = setup(&[device()]);
        rig.herdr_answers(herdr_stub("blocked"));

        let outcome = rig.hook(&status_event("blocked"));

        assert_ok(&outcome);
        assert_eq!(rig.payload(0, &key_a()).1["attention"], 1);
        assert_eq!(rig.host.calls_of("tmux", None)[0].args[0], "list-panes");
    }

    // test("tmux_enabled false leaves tmux out of the count without asking tmux")
    #[test]
    fn tmux_enabled_false_leaves_tmux_out_of_the_count_without_asking_tmux() {
        let rig = Rig::herdr();
        rig.write_config(json!({"tmux_enabled": false}));
        rig.write_registration(&[device()]);
        rig.herdr_answers(herdr_stub("blocked"));
        *rig.host.panes.borrow_mut() = Some(vec![TmuxPane {
            id: "%1".into(),
            ..TmuxPane::with_status("blocked")
        }]);

        let outcome = rig.hook(&status_event("blocked"));

        assert_ok(&outcome);
        assert_eq!(rig.payload(0, &key_a()).1["attention"], 1);
        assert!(rig.host.calls_of("tmux", None).is_empty());
    }

    // herdr is the triggering backend here: without its count the total is a
    // guess, however many tmux panes answered.
    // test("an unreadable herdr agent list omits the count even when tmux answers")
    #[test]
    fn an_unreadable_herdr_agent_list_omits_the_count_even_when_tmux_answers() {
        let rig = setup(&[device()]);
        rig.herdr_answers(herdr_stub("blocked").list(AgentList::Failing));
        *rig.host.panes.borrow_mut() = Some(vec![TmuxPane {
            id: "%1".into(),
            ..TmuxPane::with_status("blocked")
        }]);

        let outcome = rig.hook(&status_event("blocked"));

        assert_ok(&outcome);
        assert!(rig.payload(0, &key_a()).1.get("attention").is_none());
    }

    // test("unknown event fields are ignored (lenient parse)")
    #[test]
    fn unknown_event_fields_are_ignored_lenient_parse() {
        let rig = setup(&[device()]);
        rig.herdr_answers(herdr_stub("blocked"));

        let mut event = event_with(
            "blocked",
            Some("claude"),
            PANE_ID,
            json!({"future_field": "x", "state_labels": {"a": "b"}}),
        );
        event["top_level_future"] = json!(true);
        let outcome = rig.hook(&event);

        assert_ok(&outcome);
        assert_eq!(rig.relay.posts().len(), 1);
    }

    // ---- suite("notify-hook: debounce") ----------------------------------------------

    // test("re-checks through HERDR_BIN_PATH only after the debounce sleep")
    #[test]
    fn rechecks_through_herdr_bin_path_only_after_the_debounce_sleep() {
        let rig = setup(&[device()]);
        rig.herdr_answers(herdr_stub("blocked"));
        let host = Rc::clone(&rig.host);
        let rechecks_before_sleep = Rc::new(RefCell::new(Vec::new()));
        let seen = Rc::clone(&rechecks_before_sleep);
        let bin = rig.path("stub/herdr").to_string_lossy().into_owned();
        rig.clock.on_sleep(move || {
            seen.borrow_mut().push(host.calls_of(&bin, None).len());
        });

        rig.hook(&status_event("blocked"));

        let gets: Vec<_> = herdr_calls_of(&rig, "agent")
            .into_iter()
            .filter(|args| args[1] == "get")
            .collect();
        assert_eq!(gets.len(), 1);
        assert_eq!(gets[0], ["agent", "get", PANE_ID]);
        // Nothing ran before the one sleep, and the sleep was the debounce.
        assert_eq!(*rechecks_before_sleep.borrow(), vec![0]);
        assert_eq!(rig.clock.sleeps(), vec![Duration::from_millis(DEBOUNCE_MS)]);
    }

    // test("aborts without posting when the status moved on during the debounce")
    #[test]
    fn aborts_without_posting_when_the_status_moved_on_during_the_debounce() {
        let rig = setup(&[device()]);
        rig.herdr_answers(herdr_stub("working"));

        let outcome = rig.hook(&status_event("blocked"));

        assert_ok(&outcome);
        assert!(rig.relay.posts().is_empty());
        assert_eq!(rig.host.calls().len(), 1);
    }

    // test("aborts without posting when the agent is gone at re-check time")
    #[test]
    fn aborts_without_posting_when_the_agent_is_gone_at_recheck_time() {
        let rig = setup(&[device()]);
        rig.herdr_answers(HerdrStub {
            status: None,
            ..herdr_stub("blocked")
        });

        let outcome = rig.hook(&status_event("blocked"));

        assert_ok(&outcome);
        assert!(rig.relay.posts().is_empty());
    }

    // test("fails closed when the re-check itself cannot run")
    #[test]
    fn fails_closed_when_the_recheck_itself_cannot_run() {
        let rig = setup(&[device()]);
        let mut env = rig.hook_env(&status_event("blocked").to_string());
        env.set(
            "HERDR_BIN_PATH",
            rig.path("stub/does-not-exist").to_string_lossy(),
        );
        // The real program runner: a binary that does not exist.
        let deps = Deps {
            fetch: &*rig.relay,
            clock: &*rig.clock,
            run: &run_program,
            summaries: &NoSummaries,
            chat: &NoChat,
        };

        let outcome = run_herdr_notify(&env, &deps);

        assert_eq!(outcome.code, 1);
        assert!(rig.relay.posts().is_empty());
        assert!(
            outcome.stderr.starts_with("notify-hook: spawn "),
            "{}",
            outcome.stderr
        );
        assert!(
            outcome.stderr.ends_with("does-not-exist ENOENT\n"),
            "{}",
            outcome.stderr
        );
    }

    // ---- suite("notify-hook: triggers and preferences") ----------------------------------

    // test("working, idle, and unknown transitions never post")
    #[test]
    fn working_idle_and_unknown_transitions_never_post() {
        let rig = setup(&[device()]);
        for status in ["working", "idle", "unknown"] {
            rig.herdr_answers(herdr_stub(status));
            assert_ok(&rig.hook(&status_event(status)));
        }
        assert!(rig.relay.posts().is_empty());
    }

    // test("per-device preference flags gate each status")
    #[test]
    fn per_device_preference_flags_gate_each_status() {
        let rig = setup(&[
            device().notify(json!({"blocked": true, "done": false})),
            device()
                .token(TOKEN_B, key_b())
                .notify(json!({"blocked": false, "done": true})),
        ]);

        rig.herdr_answers(herdr_stub("blocked"));
        rig.hook(&status_event("blocked"));
        assert_eq!(rig.tokens(), [TOKEN_A]);

        rig.herdr_answers(herdr_stub("done"));
        rig.hook(&status_event("done"));
        assert_eq!(rig.tokens(), [TOKEN_A, TOKEN_B]);
    }

    // test("a missing notify flag means do not send (fail closed)")
    #[test]
    fn a_missing_notify_flag_means_do_not_send_fail_closed() {
        let rig = setup(&[
            device().notify(Value::Null),
            device()
                .token(TOKEN_B, key_b())
                .notify(json!({"blocked": true})),
        ]);
        rig.herdr_answers(herdr_stub("done"));

        let outcome = rig.hook(&status_event("done"));

        assert_ok(&outcome);
        assert!(rig.relay.posts().is_empty());
    }

    // ---- suite("notify-hook: dedupe") --------------------------------------------------------

    // test("a same-status repeat does not post again")
    #[test]
    fn a_same_status_repeat_does_not_post_again() {
        let rig = setup(&[device()]);
        rig.herdr_answers(herdr_stub("blocked"));

        rig.hook(&status_event("blocked"));
        let repeat = rig.hook(&status_event("blocked"));

        assert_ok(&repeat);
        assert_eq!(rig.relay.posts().len(), 1);
    }

    // test("a confirmed different status re-arms the pane")
    #[test]
    fn a_confirmed_different_status_rearms_the_pane() {
        let rig = setup(&[device()]);

        rig.herdr_answers(herdr_stub("blocked"));
        rig.hook(&status_event("blocked"));

        rig.herdr_answers(herdr_stub("working"));
        rig.hook(&status_event("working"));

        rig.herdr_answers(herdr_stub("blocked"));
        rig.hook(&status_event("blocked"));

        assert_eq!(rig.relay.posts().len(), 2);
    }

    // test("a flapping intermediate status does not re-arm (re-check disagrees)")
    #[test]
    fn a_flapping_intermediate_status_does_not_rearm_recheck_disagrees() {
        let rig = setup(&[device()]);
        rig.herdr_answers(herdr_stub("blocked"));

        rig.hook(&status_event("blocked"));
        // Detection flaps to working, but by re-check time it is blocked again:
        // the clear must not happen, so the following blocked repeat stays deduped.
        rig.hook(&status_event("working"));
        let repeat = rig.hook(&status_event("blocked"));

        assert_ok(&repeat);
        assert_eq!(rig.relay.posts().len(), 1);
    }

    // test("dedupe is per pane")
    #[test]
    fn dedupe_is_per_pane() {
        let rig = setup(&[device()]);
        rig.herdr_answers(herdr_stub("blocked"));

        rig.hook(&status_event("blocked"));
        rig.hook(&event_with("blocked", Some("claude"), "w9:p9", json!({})));

        assert_eq!(rig.relay.posts().len(), 2);
    }

    // ---- suite("notify-hook: provider") --------------------------------------------------

    /// The shared FCM registration vector: one APNs entry and one FCM entry.
    fn fcm_registration() -> Value {
        serde_json::from_str(include_str!(
            "../test-vectors/registration-file-fcm-v1.json"
        ))
        .expect("registration-file-fcm-v1.json")
    }

    fn write_registration_file(rig: &Rig, file: &Value) {
        std::fs::write(rig.config_dir.join("notifications.json"), file.to_string()).unwrap();
    }

    // test("an fcm entry posts provider fcm without collapse; the apns entry body is unchanged")
    #[test]
    fn an_fcm_entry_posts_provider_fcm_without_collapse_and_the_apns_entry_body_is_unchanged() {
        let vector = fcm_registration();
        let rig = Rig::herdr();
        rig.write_config(json!({}));
        write_registration_file(&rig, &vector["file"]);
        rig.herdr_answers(herdr_stub("blocked"));

        let outcome = rig.hook(&status_event("blocked"));

        assert_ok(&outcome);
        let posts = rig.relay.posts();
        assert_eq!(posts.len(), 2);
        let fcm = posts.iter().find(|p| p.body["provider"] == "fcm").unwrap();
        let apns = posts
            .iter()
            .find(|p| p.body.get("provider").is_none())
            .unwrap();
        assert_eq!(
            payload_keys(&fcm.body),
            ["provider", "token", "env", "envelope"]
        );
        assert_eq!(fcm.body["token"], vector["fcmToken"]);
        assert_eq!(
            payload_keys(&apns.body),
            ["token", "env", "envelope", "collapse"]
        );
        // The FCM entry's envelope opens with its own Notification Key.
        let key = crate::base64::decode(vector["file"]["devices"][1]["key"].as_str().unwrap());
        let index = posts
            .iter()
            .position(|p| p.body["provider"] == "fcm")
            .unwrap();
        let (_, payload) = rig.payload(index, &key);
        assert_eq!(payload["status"], "blocked");
        assert_eq!(payload["pane"], PANE_ID);
    }

    // test("an fcm entry without env still sends (env defaults for the relay); unknown providers are skipped")
    #[test]
    fn an_fcm_entry_without_env_still_sends_and_unknown_providers_are_skipped() {
        let mut file = fcm_registration()["file"].clone();
        file["devices"][1].as_object_mut().unwrap().remove("env");
        file["devices"][0]["provider"] = json!("webpush");
        let rig = Rig::herdr();
        rig.write_config(json!({}));
        write_registration_file(&rig, &file);
        rig.herdr_answers(herdr_stub("done"));

        let outcome = rig.hook(&status_event("done"));

        assert_ok(&outcome);
        let posts = rig.relay.posts();
        assert_eq!(posts.len(), 1);
        assert_eq!(posts[0].body["provider"], "fcm");
        assert_eq!(posts[0].body["env"], "production");
    }

    // test("a null or non-string provider is skipped, an explicit apns entry keeps its collapse id")
    #[test]
    fn a_null_provider_is_skipped_and_an_explicit_apns_entry_keeps_its_collapse_id() {
        let mut file = fcm_registration()["file"].clone();
        file["devices"][0]["provider"] = json!("apns");
        file["devices"][1]["provider"] = Value::Null;
        let rig = Rig::herdr();
        rig.write_config(json!({}));
        write_registration_file(&rig, &file);
        rig.herdr_answers(herdr_stub("blocked"));

        let outcome = rig.hook(&status_event("blocked"));

        assert_ok(&outcome);
        let posts = rig.relay.posts();
        assert_eq!(posts.len(), 1);
        assert_eq!(
            payload_keys(&posts[0].body),
            ["token", "env", "envelope", "collapse"]
        );
    }

    // test("a 410 for an fcm entry prunes that entry and keeps the rest")
    #[test]
    fn a_410_for_an_fcm_entry_prunes_that_entry_and_keeps_the_rest() {
        let vector = fcm_registration();
        let mut rig = Rig::herdr();
        rig.relay_answers(|post, _| {
            Ok(if post.body["provider"] == "fcm" {
                answer(410, r#"{"reason":"Unregistered"}"#)
            } else {
                answer(200, r#"{"apnsId":"x"}"#)
            })
        });
        rig.write_config(json!({}));
        write_registration_file(&rig, &vector["file"]);
        rig.herdr_answers(herdr_stub("blocked"));

        let outcome = rig.hook(&status_event("blocked"));

        assert_ok(&outcome);
        let file = rig.read_registration();
        let devices = file["devices"].as_array().unwrap();
        assert_eq!(devices.len(), 1);
        assert_eq!(devices[0]["token"], vector["file"]["devices"][0]["token"]);
    }

    // ---- suite("notify-hook: relay failures") -----------------------------------------------

    // test("a 410 Unregistered prunes the token, preserving everything else in the file")
    #[test]
    fn a_410_unregistered_prunes_the_token_preserving_everything_else_in_the_file() {
        let mut rig = Rig::herdr();
        rig.relay_answers(|post, _| {
            Ok(if post.body["token"] == TOKEN_A {
                answer(410, r#"{"reason":"Unregistered"}"#)
            } else {
                answer(200, r#"{"apnsId":"x"}"#)
            })
        });
        rig.write_config(json!({}));
        rig.write_registration_with(
            &[
                device().extra("future_entry_field", json!("kept")),
                device().token(TOKEN_B, key_b()),
            ],
            json!({"future_top_field": "kept"}),
        );
        rig.herdr_answers(herdr_stub("blocked"));

        let outcome = rig.hook(&status_event("blocked"));

        assert_ok(&outcome);
        assert_eq!(rig.relay.posts().len(), 2);
        let file = rig.read_registration();
        assert_eq!(file["v"], 1);
        assert_eq!(file["future_top_field"], "kept");
        let tokens: Vec<_> = file["devices"]
            .as_array()
            .unwrap()
            .iter()
            .map(|d| d["token"].as_str().unwrap())
            .collect();
        assert_eq!(tokens, [TOKEN_B]);
    }

    // test("a transient 5xx is retried until it succeeds")
    #[test]
    fn a_transient_5xx_is_retried_until_it_succeeds() {
        let mut rig = Rig::herdr();
        rig.relay_answers(|_, index| {
            Ok(if index == 0 {
                answer(500, r#"{"error":"boom"}"#)
            } else {
                answer(200, r#"{"apnsId":"x"}"#)
            })
        });
        rig.write_config(json!({}));
        rig.write_registration(&[device()]);
        rig.herdr_answers(herdr_stub("blocked"));

        let outcome = rig.hook(&status_event("blocked"));

        assert_ok(&outcome);
        assert_eq!(rig.relay.posts().len(), 2);
        // The retry waited the configured delay.
        assert_eq!(
            rig.clock.sleeps(),
            vec![
                Duration::from_millis(DEBOUNCE_MS),
                Duration::from_millis(RETRY_DELAY_MS)
            ]
        );
        // The send succeeded, so the repeat is deduped as usual.
        rig.hook(&status_event("blocked"));
        assert_eq!(rig.relay.posts().len(), 2);
    }

    // test("a persistent failure gives up after the attempt cap and does not record a send")
    #[test]
    fn a_persistent_failure_gives_up_after_the_attempt_cap_and_does_not_record_a_send() {
        let mut rig = Rig::herdr();
        rig.relay_answers(|_, _| Ok(answer(500, r#"{"error":"boom"}"#)));
        rig.write_config(json!({}));
        rig.write_registration(&[device()]);
        rig.herdr_answers(herdr_stub("blocked"));

        let outcome = rig.hook(&status_event("blocked"));

        assert_eq!(outcome.code, 1);
        assert_eq!(rig.relay.posts().len(), 3);
        assert!(outcome.stderr.contains("500"), "{}", outcome.stderr);
        assert_eq!(
            outcome.stderr,
            "notify-hook: push for token aaaaaaaa… failed: relay answered 500: {\"error\":\"boom\"}\n"
        );

        // Nothing was delivered, so a repeat event must try again, not dedupe.
        rig.relay_answers(|_, _| Ok(answer(200, r#"{"apnsId":"x"}"#)));
        let retry = rig.hook(&status_event("blocked"));
        assert_ok(&retry);
        assert_eq!(rig.relay.posts().len(), 1);
    }

    // test("a permanent 4xx is not retried")
    #[test]
    fn a_permanent_4xx_is_not_retried() {
        let mut rig = Rig::herdr();
        rig.relay_answers(|_, _| Ok(answer(400, r#"{"error":"bad_token"}"#)));
        rig.write_config(json!({}));
        rig.write_registration(&[device()]);
        rig.herdr_answers(herdr_stub("blocked"));

        let outcome = rig.hook(&status_event("blocked"));

        assert_eq!(outcome.code, 1);
        assert_eq!(rig.relay.posts().len(), 1);
    }

    // ---- suite("notify-hook: configuration and registration file") ----------------------------

    // test("an absent registration file sends nothing")
    #[test]
    fn an_absent_registration_file_sends_nothing() {
        let rig = Rig::herdr();
        rig.write_config(json!({}));
        rig.herdr_answers(herdr_stub("blocked"));

        let outcome = rig.hook(&status_event("blocked"));

        assert_ok(&outcome);
        assert!(rig.relay.posts().is_empty());
    }

    // test("a registration file with a foreign version is treated as absent")
    #[test]
    fn a_registration_file_with_a_foreign_version_is_treated_as_absent() {
        let rig = setup(&[device()]);
        let mut file = rig.read_registration();
        file["v"] = json!(2);
        std::fs::write(rig.config_dir.join("notifications.json"), file.to_string()).unwrap();
        rig.herdr_answers(herdr_stub("blocked"));

        let outcome = rig.hook(&status_event("blocked"));

        assert_ok(&outcome);
        assert!(rig.relay.posts().is_empty());
    }

    // test("a corrupt registration file is treated as absent")
    #[test]
    fn a_corrupt_registration_file_is_treated_as_absent() {
        let rig = Rig::herdr();
        rig.write_config(json!({}));
        std::fs::write(rig.config_dir.join("notifications.json"), "{not json").unwrap();
        rig.herdr_answers(herdr_stub("blocked"));

        let outcome = rig.hook(&status_event("blocked"));

        assert_ok(&outcome);
        assert!(rig.relay.posts().is_empty());
    }

    // test("a device entry with a malformed key or env is skipped, not fatal")
    #[test]
    fn a_device_entry_with_a_malformed_key_or_env_is_skipped_not_fatal() {
        let rig = setup(&[
            Dev {
                key: vec![0; 16],
                ..device()
            },
            device().token(TOKEN_B, key_b()).env("carrier-pigeon"),
            device().token(TOKEN_C, key_a()),
        ]);
        rig.herdr_answers(herdr_stub("blocked"));

        let outcome = rig.hook(&status_event("blocked"));

        assert_ok(&outcome);
        assert_eq!(rig.tokens(), [TOKEN_C]);
    }

    // test("an unparseable event JSON fails without contacting anything")
    #[test]
    fn an_unparseable_event_json_fails_without_contacting_anything() {
        let rig = setup(&[device()]);
        rig.herdr_answers(herdr_stub("blocked"));

        let outcome = rig.hook_with(&rig.hook_env("not json"));

        assert_eq!(outcome.code, 1);
        assert!(rig.relay.posts().is_empty());
        assert!(rig.host.calls().is_empty());
        assert_eq!(
            outcome.stderr,
            "notify-hook: HERDR_PLUGIN_EVENT_JSON is not JSON\n"
        );
    }

    // test("an event without a pane id or status fails leniently but loudly")
    #[test]
    fn an_event_without_a_pane_id_or_status_fails_leniently_but_loudly() {
        let rig = setup(&[device()]);
        rig.herdr_answers(herdr_stub("blocked"));

        let outcome =
            rig.hook(&json!({"event": "pane_agent_status_changed", "data": {"type": "x"}}));

        assert_eq!(outcome.code, 1);
        assert!(rig.relay.posts().is_empty());
        assert_eq!(outcome.stderr, "notify-hook: event data.pane_id missing\n");
    }

    // ---- suite("notify-hook: Agent Summary") ----------------------------------------------------
    //
    // The summary generator is a seam (`AgentSummaries`, tested in
    // `summary::agent`); these tests run the flow around it with a fake that answers the summaries the JS tests'
    // `summary_command` stand-in printed.

    fn summary_rig() -> Rig {
        let rig = Rig::herdr();
        rig.write_config(json!({"summary_enabled": true, "summary_command": ["/stub/summarize"]}));
        rig
    }

    // test("a confirmed Blocked transition carries its summary in the push and the Host store")
    #[test]
    fn a_confirmed_blocked_transition_carries_its_summary_in_the_push_and_the_host_store() {
        let rig = summary_rig();
        rig.write_registration(&[device()]);
        rig.herdr_answers(herdr_stub("blocked").title("Ship the release"));
        rig.summaries.says("Approve merge of PR #512");

        let outcome = rig.hook(&status_event("blocked"));

        assert_ok(&outcome);
        let (_, payload) = rig.payload(0, &key_a());
        assert_eq!(payload["summary"], "Approve merge of PR #512");
        assert_eq!(
            payload_keys(&payload),
            [
                "pane",
                "kind",
                "status",
                "ts",
                "project",
                "title",
                "summary",
                "attention"
            ]
        );
        assert_eq!(
            rig.stored_summary(PANE_ID).unwrap(),
            json!({
                "v": 1,
                "pane": PANE_ID,
                "status": "blocked",
                "summary": "Approve merge of PR #512",
                "ts": NOW_MS,
                "hash": "hash",
                // No estimate, named anyway: this plugin writes progress.
                "progress": null,
            })
        );
        // The generator is asked for the event's status within the configured
        // budget, with the herdr CLI and the configured command.
        let asked = rig.summaries.requests.borrow().clone();
        assert_eq!(asked.len(), 1);
        assert_eq!(asked[0].pane_id, PANE_ID);
        assert_eq!(asked[0].status, "blocked");
        assert_eq!(asked[0].timeout_ms, 15_000);
        assert_eq!(asked[0].herdr_bin, rig.path("stub/herdr").to_string_lossy());
        assert_eq!(asked[0].command, Some(vec!["/stub/summarize".to_owned()]));
    }

    // The summary's cap is 100, above the 80 of the push's other display fields.
    // test("a 100-character summary reaches the push and the store whole")
    #[test]
    fn a_100_character_summary_reaches_the_push_and_the_store_whole() {
        let rig = summary_rig();
        rig.write_registration(&[device()]);
        rig.herdr_answers(herdr_stub("done"));
        let sentence: &'static str = Box::leak(
            format!(
                "Merged PR #512 into main after rebasing onto the release branch; {}",
                "x".repeat(35)
            )
            .into_boxed_str(),
        );
        assert_eq!(sentence.len(), 100);
        rig.summaries.says(sentence);

        let outcome = rig.hook(&status_event("done"));

        assert_ok(&outcome);
        assert_eq!(rig.payload(0, &key_a()).1["summary"], sentence);
        assert_eq!(rig.stored_summary(PANE_ID).unwrap()["summary"], sentence);
    }

    // test("the summary is stored even when no device is registered for pushes")
    #[test]
    fn the_summary_is_stored_even_when_no_device_is_registered_for_pushes() {
        let rig = summary_rig();
        rig.herdr_answers(herdr_stub("done"));
        rig.summaries.says("merged PR #512");

        let outcome = rig.hook(&status_event("done"));

        assert_ok(&outcome);
        assert!(rig.relay.posts().is_empty());
        let stored = rig.stored_summary(PANE_ID).unwrap();
        assert_eq!(stored["summary"], "merged PR #512");
        assert_eq!(stored["status"], "done");
    }

    // The JS test runs a summarizer that never exits and checks the hook
    // killed it; killing the model process is `generateAgentSummary`'s.
    // What the notify flow owns is ported: the generator gets the configured
    // budget, the re-check waits out the time it took, and a push without a
    // summary goes out, storing a tombstone.
    // test("a summary that outlives its budget is dropped and the push goes out without it")
    #[test]
    fn a_summary_that_outlives_its_budget_is_dropped_and_the_push_goes_out_without_it() {
        let rig = Rig::herdr();
        rig.write_config(json!({
            "summary_enabled": true,
            "summary_command": ["/stub/summarize"],
            "summary_timeout_ms": 1500,
        }));
        rig.write_registration(&[device()]);
        rig.herdr_answers(herdr_stub("blocked"));
        let clock = Rc::clone(&rig.clock);
        rig.summaries.answer(move |asked| {
            // The hung model runs out its whole budget.
            clock.advance(asked.timeout_ms);
            Summary::default()
        });

        let outcome = rig.hook(&status_event("blocked"));

        assert_ok(&outcome);
        assert_eq!(rig.summaries.requests.borrow()[0].timeout_ms, 1500);
        // The budget outlasted the debounce: the re-check came right after it.
        assert_eq!(rig.clock.sleeps(), vec![Duration::from_millis(0)]);
        assert_eq!(rig.relay.posts().len(), 1);
        let (_, payload) = rig.payload(0, &key_a());
        assert!(payload.get("summary").is_none());
        assert_eq!(rig.stored_summary(PANE_ID).unwrap()["summary"], Value::Null);
    }

    // The user at the desk answers the prompt while the model is still
    // summarizing it: pushing the stale Blocked would also mark the pane, and
    // its next real Blocked would then be deduped.
    // test("a status that moves on while the summary is generated neither pushes nor dedupes the next one")
    #[test]
    fn a_status_that_moves_on_while_the_summary_is_generated_neither_pushes_nor_dedupes_the_next_one()
     {
        let rig = summary_rig();
        rig.write_registration(&[device()]);
        rig.herdr_answers(herdr_stub("working"));
        let (working, _) = rig.host.replied("agent");
        rig.herdr_answers(herdr_stub("blocked"));
        let host = Rc::clone(&rig.host);
        let clock = Rc::clone(&rig.clock);
        rig.summaries.answer(move |_| {
            clock.advance(DEBOUNCE_MS * 5);
            // The Agent moved on while the model answered.
            host.reply("agent", working.clone(), 0);
            Summary {
                summary: Some("approve merge".to_owned()),
                hash: Some("hash".to_owned()),
            }
        });

        let stale = rig.hook(&status_event("blocked"));

        assert_ok(&stale);
        assert!(rig.relay.posts().is_empty());
        assert!(rig.stored_summary(PANE_ID).is_none());

        rig.herdr_answers(herdr_stub("blocked"));
        rig.summaries.says("approve deploy to production");
        let next = rig.hook(&status_event("blocked"));

        assert_ok(&next);
        assert_eq!(rig.relay.posts().len(), 1);
        assert_eq!(
            rig.payload(0, &key_a()).1["summary"],
            "approve deploy to production"
        );
    }

    // test("a confirmed turn without a summary retires the previous turn's")
    #[test]
    fn a_confirmed_turn_without_a_summary_retires_the_previous_turns() {
        let rig = summary_rig();
        rig.herdr_answers(herdr_stub("done"));
        rig.summaries.says("merged PR #512");
        rig.hook(&status_event("done"));
        let previous = rig.stored_summary(PANE_ID).unwrap();

        rig.summaries.answer(|_| Summary::default());
        let outcome = rig.hook(&status_event("done"));

        assert_ok(&outcome);
        let tombstone = rig.stored_summary(PANE_ID).unwrap();
        assert_eq!(tombstone["summary"], Value::Null);
        assert_eq!(tombstone["status"], "done");
        assert!(tombstone["ts"].as_u64() > previous["ts"].as_u64());
    }

    fn write_stored_summary(rig: &Rig, pane_id: &str, modified_ms: u64) {
        let dir = rig.config_dir.join("summaries");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join(crate::atomic::pane_file_name(pane_id));
        std::fs::write(
            &path,
            json!({"v": 1, "pane": pane_id, "status": "done", "summary": "old news", "ts": 1})
                .to_string(),
        )
        .unwrap();
        std::fs::File::options()
            .write(true)
            .open(path)
            .unwrap()
            .set_modified(std::time::UNIX_EPOCH + Duration::from_millis(modified_ms))
            .unwrap();
    }

    // test("entries untouched for 7 days are pruned even by an event the hook otherwise ignores")
    #[test]
    fn entries_untouched_for_7_days_are_pruned_even_by_an_event_the_hook_otherwise_ignores() {
        let rig = summary_rig();
        rig.herdr_answers(herdr_stub("working"));
        write_stored_summary(&rig, "w9:stale", NOW_MS - 8 * 24 * 60 * 60 * 1000);
        write_stored_summary(&rig, "w9:fresh", NOW_MS);

        let outcome = rig.hook(&status_event("working"));

        assert_ok(&outcome);
        assert!(rig.stored_summary("w9:stale").is_none());
        assert!(rig.stored_summary("w9:fresh").is_some());
    }

    // test("switching summaries off deletes the stored ones on the next event")
    #[test]
    fn switching_summaries_off_deletes_the_stored_ones_on_the_next_event() {
        let rig = Rig::herdr();
        rig.write_config(json!({"summary_enabled": false}));
        rig.herdr_answers(herdr_stub("working"));
        write_stored_summary(&rig, PANE_ID, NOW_MS);

        let outcome = rig.hook(&status_event("working"));

        assert_ok(&outcome);
        assert!(!rig.config_dir.join("summaries").exists());
    }

    // test("a status that moved on during the debounce stores no summary")
    #[test]
    fn a_status_that_moved_on_during_the_debounce_stores_no_summary() {
        let rig = summary_rig();
        rig.write_registration(&[device()]);
        rig.herdr_answers(herdr_stub("working"));
        rig.summaries.says("approve merge");

        let outcome = rig.hook(&status_event("blocked"));

        assert_ok(&outcome);
        assert!(rig.relay.posts().is_empty());
        assert!(rig.stored_summary(PANE_ID).is_none());
    }

    // test("a deduped repeat refreshes the stored summary without pushing again")
    #[test]
    fn a_deduped_repeat_refreshes_the_stored_summary_without_pushing_again() {
        let rig = summary_rig();
        rig.write_registration(&[device()]);
        rig.herdr_answers(herdr_stub("blocked"));
        rig.summaries.says("approve merge of PR #512");
        rig.hook(&status_event("blocked"));

        rig.summaries.says("approve deploy to production");
        let repeat = rig.hook(&status_event("blocked"));

        assert_ok(&repeat);
        assert_eq!(rig.relay.posts().len(), 1);
        assert_eq!(
            rig.stored_summary(PANE_ID).unwrap()["summary"],
            "approve deploy to production"
        );
    }

    // test("with summaries disabled the screen is never read")
    #[test]
    fn with_summaries_disabled_the_screen_is_never_read() {
        let rig = Rig::herdr();
        rig.write_config(json!({"summary_enabled": false, "summary_command": ["/stub/summarize"]}));
        rig.write_registration(&[device()]);
        rig.herdr_answers(herdr_stub("blocked"));
        rig.summaries.says("approve merge");

        let outcome = rig.hook(&status_event("blocked"));

        assert_ok(&outcome);
        assert_eq!(rig.relay.posts().len(), 1);
        assert!(rig.summaries.requests.borrow().is_empty());
        assert!(herdr_calls_of(&rig, "pane").is_empty());
        assert!(rig.stored_summary(PANE_ID).is_none());
    }

    // ---- suite("notify-hook: Chat Mode reply") ----------------------------------------------------
    //
    // Markers and transcripts are a seam (`ChatMode`, tested in `chat`): the fake answers
    // what the JS tests' synthetic transcripts and marker files made the real
    // readers answer, so these exercise the flow around the seam.

    const REPLY: &str =
        "CI is red because the iPad suite times out.\n\nI raised the timeout and it passes now.";

    /// A Done chat pane: summaries on, a marker for the pane, the agent in the
    /// marker's terminal, and a reader that finds `REPLY`.
    fn chat_rig(agent: &'static str, marker_kind: &str) -> Rig {
        let rig = summary_rig();
        rig.write_registration(&[device()]);
        *rig.chat.marker.borrow_mut() = Some(Marker {
            kind: marker_kind.to_owned(),
            ..marker()
        });
        rig.herdr_answers(
            herdr_stub("done")
                .agent(agent)
                .extra(json!({"terminal_id": "term_chat1"})),
        );
        rig.summaries.says("merged PR #512");
        rig.chat.replies(REPLY);
        rig
    }

    // test("a Done push for a chat pane carries the final reply instead of a summary")
    #[test]
    fn a_done_push_for_a_chat_pane_carries_the_final_reply_instead_of_a_summary() {
        let rig = chat_rig("claude", "claude");

        let outcome = rig.hook(&status_event("done"));

        assert_ok(&outcome);
        assert_eq!(rig.relay.posts().len(), 1);
        let (_, payload) = rig.payload(0, &key_a());
        assert_eq!(payload["reply"], REPLY);
        assert_eq!(
            payload_keys(&payload),
            [
                "pane",
                "kind",
                "status",
                "ts",
                "project",
                "reply",
                "attention"
            ]
        );
        assert!(
            rig.summaries.requests.borrow().is_empty(),
            "the summary generator must not run for a reply push"
        );
    }

    // herdr's live agent_session follows /clear; the marker keeps the launch's.
    // test("the live agent session wins over the marker's session")
    #[test]
    fn the_live_agent_session_wins_over_the_markers_session() {
        let rig = chat_rig("claude", "claude");
        let live = "/home/u/live.jsonl";
        rig.herdr_answers(herdr_stub("done").extra(json!({
            "terminal_id": "term_chat1",
            "agent_session": {"agent": "claude", "kind": "path", "source": "hook", "value": live},
        })));

        let outcome = rig.hook(&status_event("done"));

        assert_ok(&outcome);
        assert_eq!(rig.payload(0, &key_a()).1["reply"], REPLY);
        let read = rig.chat.reads.borrow()[0].clone();
        assert_eq!(
            read.session,
            Some(MarkerSession {
                kind: "path".to_owned(),
                value: live.to_owned()
            })
        );
        // The marker's cwd and launch time still describe the chat.
        assert_eq!(read.cwd.as_deref(), Some("/home/u/proj"));
        assert_eq!(read.launched_at.as_deref(), Some("2020-01-01T00:00:00Z"));
        assert_eq!(read.kind.as_deref(), Some("claude"));
    }

    // test("a pane reused by another terminal gets today's push, summary included")
    #[test]
    fn a_pane_reused_by_another_terminal_gets_todays_push_summary_included() {
        let rig = chat_rig("claude", "claude");
        *rig.chat.marker.borrow_mut() = Some(Marker {
            terminal_id: Some("term_old".to_owned()),
            ..marker()
        });

        let outcome = rig.hook(&status_event("done"));

        assert_ok(&outcome);
        let (_, payload) = rig.payload(0, &key_a());
        assert_eq!(payload["summary"], "merged PR #512");
        assert_eq!(
            payload_keys(&payload),
            [
                "pane",
                "kind",
                "status",
                "ts",
                "project",
                "summary",
                "attention"
            ]
        );
        // The marker did not apply, so no transcript was read, and the
        // deferred summary got what was left of its budget after the hold.
        assert!(rig.chat.reads.borrow().is_empty());
        assert_eq!(
            rig.summaries.requests.borrow()[0].timeout_ms,
            15_000 - DEBOUNCE_MS
        );
    }

    // A herdr restart resumes the Agent in a new terminal under the same session.
    // test("a chat restored in a new terminal with the same session gets the reply")
    #[test]
    fn a_chat_restored_in_a_new_terminal_with_the_same_session_gets_the_reply() {
        let rig = chat_rig("claude", "claude");
        *rig.chat.marker.borrow_mut() = Some(Marker {
            terminal_id: Some("term_old".to_owned()),
            ..marker()
        });
        rig.herdr_answers(herdr_stub("done").extra(json!({
            "terminal_id": "term_chat1",
            "agent_session": {"agent": "claude", "kind": "path", "source": "hook", "value": "/home/u/chat.jsonl"},
        })));

        let outcome = rig.hook(&status_event("done"));

        assert_ok(&outcome);
        assert_eq!(rig.payload(0, &key_a()).1["reply"], REPLY);
        assert!(rig.summaries.requests.borrow().is_empty());
    }

    // test("a marker for another kind gets today's push, summary included")
    #[test]
    fn a_marker_for_another_kind_gets_todays_push_summary_included() {
        let rig = chat_rig("claude", "codex");

        let outcome = rig.hook(&status_event("done"));

        assert_ok(&outcome);
        let (_, payload) = rig.payload(0, &key_a());
        assert_eq!(payload["summary"], "merged PR #512");
        assert!(payload.get("reply").is_none());
        // Not a Chat Mode pane for this agent: the summary was never deferred.
        assert_eq!(rig.summaries.requests.borrow()[0].timeout_ms, 15_000);
    }

    // test("a plain launch's marker (chat_mode false) gets today's push, summary included")
    #[test]
    fn a_plain_launchs_marker_chat_mode_false_gets_todays_push_summary_included() {
        let rig = chat_rig("claude", "claude");
        *rig.chat.marker.borrow_mut() = Some(Marker {
            chat_mode: false,
            ..marker()
        });

        let outcome = rig.hook(&status_event("done"));

        assert_ok(&outcome);
        let (_, payload) = rig.payload(0, &key_a());
        assert_eq!(payload["summary"], "merged PR #512");
        assert!(payload.get("reply").is_none());
        assert!(rig.chat.reads.borrow().is_empty());
    }

    // test("a reader that finds no transcript falls back to the summary")
    #[test]
    fn a_reader_that_finds_no_transcript_falls_back_to_the_summary() {
        let rig = chat_rig("claude", "claude");
        *rig.chat.turn.borrow_mut() = Ok(ChatTurn {
            read: ChatRead::Other,
            turn_open: false,
            last_reply: None,
        });

        let outcome = rig.hook(&status_event("done"));

        assert_ok(&outcome);
        assert_eq!(rig.relay.posts().len(), 1);
        let (_, payload) = rig.payload(0, &key_a());
        assert_eq!(payload["summary"], "merged PR #512");
        assert!(payload.get("reply").is_none());
        assert_eq!(
            rig.stored_summary(PANE_ID).unwrap()["summary"],
            "merged PR #512"
        );
    }

    // test("a turn that ended without text falls back to the summary")
    #[test]
    fn a_turn_that_ended_without_text_falls_back_to_the_summary() {
        let rig = chat_rig("claude", "claude");
        rig.chat.replies("   ");

        let outcome = rig.hook(&status_event("done"));

        assert_ok(&outcome);
        let (_, payload) = rig.payload(0, &key_a());
        assert_eq!(payload["summary"], "merged PR #512");
        assert!(payload.get("reply").is_none());
    }

    // Done can land while the pi run is still mid tool call; the newest reply
    // then answers the previous prompt, not this one.
    // test("a pi turn the reader still holds open falls back to the summary")
    #[test]
    fn a_pi_turn_the_reader_still_holds_open_falls_back_to_the_summary() {
        let rig = chat_rig("pi", "pi");
        *rig.chat.turn.borrow_mut() = Ok(ChatTurn {
            read: ChatRead::Ok,
            turn_open: true,
            last_reply: Some("First answer.".to_owned()),
        });

        let outcome = rig.hook(&status_event_for("done", "pi"));

        assert_ok(&outcome);
        let (_, payload) = rig.payload(0, &key_a());
        assert_eq!(payload["summary"], "merged PR #512");
        assert!(payload.get("reply").is_none());
    }

    fn status_event_for(status: &str, agent: &str) -> Value {
        event_with(status, Some(agent), PANE_ID, json!({}))
    }

    // A reader that errors (or throws) is logged and falls back like one that
    // finds nothing: the JS `chatReply` swallows both.
    #[test]
    fn a_reader_error_is_logged_and_falls_back_to_the_summary() {
        let rig = chat_rig("claude", "claude");
        *rig.chat.turn.borrow_mut() = Ok(ChatTurn {
            read: ChatRead::Error("cannot open".to_owned()),
            turn_open: false,
            last_reply: None,
        });
        let outcome = rig.hook(&status_event("done"));
        assert_ok(&outcome);
        assert_eq!(
            outcome.stderr,
            "notify-hook: chat reply not read: cannot open\n"
        );
        assert_eq!(rig.payload(0, &key_a()).1["summary"], "merged PR #512");

        let rig = chat_rig("claude", "claude");
        *rig.chat.turn.borrow_mut() = Err("reader blew up".to_owned());
        let outcome = rig.hook(&status_event("done"));
        assert_ok(&outcome);
        assert_eq!(
            outcome.stderr,
            "notify-hook: chat reply not read: reader blew up\n"
        );
        assert_eq!(rig.payload(0, &key_a()).1["summary"], "merged PR #512");
    }

    // test("a Blocked push for a chat pane is unchanged")
    #[test]
    fn a_blocked_push_for_a_chat_pane_is_unchanged() {
        let rig = chat_rig("claude", "claude");
        rig.herdr_answers(herdr_stub("blocked").extra(json!({"terminal_id": "term_chat1"})));
        rig.summaries.says("approve merge");

        let outcome = rig.hook(&status_event("blocked"));

        assert_ok(&outcome);
        let (_, payload) = rig.payload(0, &key_a());
        assert_eq!(payload["summary"], "approve merge");
        assert!(payload.get("reply").is_none());
        assert!(rig.chat.reads.borrow().is_empty());
    }

    // The JS tests check which marker files are deleted; the collection is
    // `gcMarkers`. What the hook owns is ported: when a run is due and
    // what it tells the collection is live.
    // test("a push deletes the markers of panes herdr no longer lists")
    #[test]
    fn a_push_collects_the_markers_of_panes_herdr_no_longer_lists() {
        let rig = chat_rig("claude", "claude");
        rig.chat.gc_due.borrow_mut().push_back(true);
        rig.chat.has_markers.set(true);

        let outcome = rig.hook(&status_event("done"));

        assert_ok(&outcome);
        assert_eq!(rig.relay.posts().len(), 1);
        let collected = rig.chat.collected.borrow().clone();
        assert_eq!(collected.len(), 1);
        assert_eq!(collected[0].live_pane_ids, [PANE_ID]);
        // No tmux server: its markers are all kept.
        assert_eq!(collected[0].live_tmux_pane_ids, None);
    }

    // Most hook runs never push: a working transition, or a deduped Done.
    // test("a hook that pushes nothing still collects markers hourly")
    #[test]
    fn a_hook_that_pushes_nothing_still_collects_markers_hourly() {
        let rig = Rig::herdr();
        rig.write_config(json!({}));
        rig.chat.gc_due.borrow_mut().extend([true, false]);
        rig.chat.has_markers.set(true);
        rig.herdr_answers(herdr_stub("working").extra(json!({"terminal_id": "term_chat1"})));

        let outcome = rig.hook(&status_event("working"));

        assert_ok(&outcome);
        assert_eq!(rig.chat.collected.borrow().len(), 1);
        assert_eq!(rig.chat.collected.borrow()[0].live_pane_ids, [PANE_ID]);

        // Within the hour the agent list is not fetched again.
        let lists = |rig: &Rig| {
            herdr_calls_of(rig, "agent")
                .iter()
                .filter(|a| a[1] == "list")
                .count()
        };
        let before = lists(&rig);
        rig.hook(&status_event("working"));
        assert_eq!(lists(&rig), before);
        assert_eq!(rig.chat.collected.borrow().len(), 1);
    }

    // A run is skipped when no marker exists, without fetching the agent list.
    #[test]
    fn collection_does_not_list_agents_when_no_marker_exists() {
        let rig = Rig::herdr();
        rig.write_config(json!({}));
        rig.chat.gc_due.borrow_mut().push_back(true);
        rig.herdr_answers(herdr_stub("working"));

        assert_ok(&rig.hook(&status_event("working")));

        assert!(rig.chat.collected.borrow().is_empty());
        assert!(herdr_calls_of(&rig, "agent").iter().all(|a| a[1] != "list"));
    }

    // A Host running both backends: the tmux transport's markers share chat/.
    // test("collection keeps tmux markers whose pane exists, even without hook options")
    #[test]
    fn collection_keeps_tmux_markers_whose_pane_exists_even_without_hook_options() {
        let rig = Rig::herdr();
        rig.write_config(json!({}));
        rig.chat.gc_due.borrow_mut().push_back(true);
        rig.chat.has_markers.set(true);
        rig.herdr_answers(herdr_stub("working"));
        *rig.host.panes.borrow_mut() = Some(vec![TmuxPane {
            agent: String::new(),
            ..TmuxPane::with_status("")
        }]);

        let outcome = rig.hook(&status_event("working"));

        assert_ok(&outcome);
        assert_eq!(
            rig.chat.collected.borrow()[0].live_tmux_pane_ids,
            Some(vec!["tmux:%3".to_owned()])
        );
    }

    // test("collection keeps every tmux marker when tmux cannot list panes")
    #[test]
    fn collection_keeps_every_tmux_marker_when_tmux_cannot_list_panes() {
        let rig = Rig::herdr();
        rig.write_config(json!({}));
        rig.chat.gc_due.borrow_mut().push_back(true);
        rig.chat.has_markers.set(true);
        rig.herdr_answers(herdr_stub("working"));

        let outcome = rig.hook(&status_event("working"));

        assert_ok(&outcome);
        let collected = rig.chat.collected.borrow().clone();
        assert_eq!(collected[0].live_tmux_pane_ids, None);
        assert_eq!(collected[0].live_pane_ids, [PANE_ID]);
    }

    // With tmux disabled the tmux markers are kept without asking tmux.
    #[test]
    fn collection_does_not_ask_tmux_when_tmux_is_disabled() {
        let rig = Rig::herdr();
        rig.write_config(json!({"tmux_enabled": false}));
        rig.chat.gc_due.borrow_mut().push_back(true);
        rig.chat.has_markers.set(true);
        rig.herdr_answers(herdr_stub("working"));
        *rig.host.panes.borrow_mut() = Some(vec![TmuxPane::with_status("working")]);

        assert_ok(&rig.hook(&status_event("working")));

        assert_eq!(rig.chat.collected.borrow()[0].live_tmux_pane_ids, None);
        assert!(rig.host.calls_of("tmux", None).is_empty());
    }

    // Every named session shares this config dir, and pane ids collide across them.
    // test("named herdr sessions on the Host block collection")
    #[test]
    fn named_herdr_sessions_on_the_host_block_collection() {
        let rig = Rig::herdr();
        rig.write_config(json!({}));
        rig.chat.gc_due.borrow_mut().push_back(true);
        rig.chat.has_markers.set(true);
        rig.chat.skipped.set(true);
        rig.herdr_answers(herdr_stub("working"));

        let outcome = rig.hook(&status_event("working"));

        assert_ok(&outcome);
        assert!(
            outcome.stderr.contains("named herdr sessions"),
            "{}",
            outcome.stderr
        );
        assert_eq!(
            outcome.stderr,
            "notify-hook: chat markers not collected: named herdr sessions share this Host\n"
        );
    }

    // ---- the hook's own contract ----------------------------------------------------------------------

    #[test]
    fn a_missing_variable_names_itself_and_fails_before_anything_runs() {
        let rig = setup(&[device()]);
        rig.herdr_answers(herdr_stub("blocked"));
        for name in [
            "HERDR_PLUGIN_CONFIG_DIR",
            "HERDR_PLUGIN_EVENT_JSON",
            "HERDR_PLUGIN_STATE_DIR",
            "HERDR_BIN_PATH",
        ] {
            let mut env = rig.hook_env(&status_event("blocked").to_string());
            env.set(name, "");
            let outcome = rig.hook_with(&env);
            assert_eq!(outcome.code, 1);
            assert_eq!(
                outcome.stderr,
                format!(
                    "notify-hook: {name} is not set; this script must run as a herdr event hook\n"
                )
            );
        }
        assert!(rig.relay.posts().is_empty());
        assert!(rig.host.calls().is_empty());
    }

    #[test]
    fn the_event_status_is_lower_cased() {
        let event = parse_status_event(&status_event("BLOCKED").to_string()).unwrap();
        assert_eq!(event.status, "blocked");
        assert_eq!(event.agent_kind.as_deref(), Some("claude"));
        assert_eq!(event.workspace_id.as_deref(), Some("w1"));
        assert_eq!(event.title, None);
    }

    #[test]
    fn a_lone_surrogate_in_an_event_becomes_a_replacement_character() {
        let raw = r#"{"data":{"pane_id":"w1:p2","agent_status":"blocked","title":"a\ud800b"}}"#;
        let event = parse_status_event(raw).unwrap();
        assert_eq!(event.title.as_deref(), Some("a\u{FFFD}b"));
    }

    #[test]
    fn a_null_notify_json_fails_the_hook_as_the_js_does() {
        let rig = setup(&[device()]);
        std::fs::write(rig.config_dir.join("notify.json"), "null").unwrap();
        rig.herdr_answers(herdr_stub("blocked"));

        let outcome = rig.hook(&status_event("blocked"));

        assert_eq!(outcome.code, 1);
        assert!(
            outcome
                .stderr
                .starts_with("notify-hook: Cannot read properties of null")
        );
    }

    #[test]
    fn session_references_need_a_kind_and_a_value() {
        let good = json!({"kind": "path", "value": "/a.jsonl", "source": "hook"});
        assert_eq!(
            session_reference(Some(&good)),
            Some(MarkerSession {
                kind: "path".into(),
                value: "/a.jsonl".into()
            })
        );
        for bad in [
            json!({"kind": "other", "value": "x"}),
            json!({"kind": "id", "value": ""}),
            json!({"kind": "id"}),
            json!("id"),
            Value::Null,
        ] {
            assert_eq!(session_reference(Some(&bad)), None, "{bad}");
        }
        assert_eq!(session_reference(None), None);
    }

    #[test]
    fn the_stripped_title_wins_over_the_raw_one() {
        let rig = setup(&[device()]);
        rig.herdr_answers(herdr_stub("blocked").title("Fix it"));
        rig.host.reply(
            "agent",
            json!({"result": {"agent": {"agent_status": "blocked", "terminal_title": "⠂ Fix it", "terminal_title_stripped": "Fix it"}}}).to_string(),
            0,
        );
        let herdr = Herdr {
            bin: "herdr",
            env: &Env::default(),
            run: &|c, a, e| rig.host.run(c, a, e),
        };
        let current = current_agent_status(herdr, PANE_ID).unwrap().unwrap();
        assert_eq!(current.detail.title.as_deref(), Some("Fix it"));
    }
}
