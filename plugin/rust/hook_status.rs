//! The Zellij and herdr-core sides of bin/waycar-hook: `waycar hook-status <agent> <status>`
//! (docs/design/herdr-core-backend.md, docs/design/zellij-backend.md §6).
//!
//! Zellij ownership is tried before core; its document writer lives in
//! [`crate::zellij`]. The rest of this module describes core's label writer.
//!
//! bin/waycar-hook tries tmux first; when the agent is not in a tmux pane
//! (no `TMUX_PANE`, no tmux, another pane's tty, a stale `HERDR_*`) and
//! `HC_TERMINAL_ID` is set, it runs this with the same arguments. A core
//! started inside a tmux or herdr pane hands every terminal that pane's
//! `TMUX_PANE` and `HERDR_*`, so the environment alone never says which
//! runtime is innermost; the tty does: the terminal's program owns the pty
//! the agent runs on. [`resolve_core`] therefore takes the terminal only when
//! the agent's controlling tty (`$CLAUDE_PID`'s for claude, else the hook's
//! parent's, with one hop to the grandparent when that has none, never for
//! codex or cline) is the tty of the process core records as the terminal's
//! `pid`.
//!
//! It does nothing, silently and with exit 0, unless: `WAYCAR_SUMMARY` is
//! unset, `HC_TERMINAL_ID` is a core address in the default session
//! (`HC_SESSION` unset or `default`), `core_enabled` is not false in
//! `notify.json`, `herdr-core` answers `--version`, the terminal is live
//! and the tty matches. `watch-approval` has no core form.
//!
//! What it writes is labels (`herdr-core label <address> k=v...`), the core
//! counterparts of the tmux pane options:
//!
//! * `waycar.kind`: the agent kind
//! * `waycar.session`, `waycar.transcript`: from `waycar hook-session` and the
//!   extensions (the transcript is the path itself, not percent-encoded)
//! * `waycar.turn`: core's `turn` of the terminal when a `working` status was
//!   hooked. A turn end the agent reports as core `idle` (not `done`) is
//!   recognised by `turn` having risen past it.
//! * `waycar.status`: the last status the hook wrote (`working`, `blocked`,
//!   `done`, `idle`), only for a terminal that has no core status (an agent
//!   that never reports OSC 7501). It is the `current` of the conditional
//!   statuses there, as `@waycar_status` is on tmux; while core has a status,
//!   core's is authoritative and the label is not written.
//!
//! `release` clears all five. There is no `@waycar_seq`: core keeps its own
//! `status_ms` and `turn`. The current status is core's `status.state`
//! (`error` is `blocked`); a conditional status (`working-if-active`, ...)
//! applies to it as it does to `@waycar_status`, but an unconditional one is
//! always taken: the agent's own report may precede the hook, and the push
//! hangs on the hook. Then `waycar notify --pane hc:<address> --status <s>`
//! runs detached.

use std::path::Path;
use std::process::{Command, Stdio};
use std::time::Duration;

use crate::core::{self, CoreCommand, CoreTerminal, is_named_session, terminal_address};
use crate::env::Env;
use crate::exec::{RunResult, run_program, run_program_with_timeout};
use crate::hook_session::{HookHost, agent_tty, next_status, read_tty};
use crate::hooks::HOOK_AGENTS;
use crate::notification_config::read_notification_config;
use crate::paths::resolve_host_config;

/// The statuses bin/waycar-hook takes.
const STATUSES: [&str; 10] = [
    "working",
    "blocked",
    "done",
    "idle",
    "working-if-active",
    "working-if-blocked",
    "idle-if-working",
    "done-if-active",
    "release",
    "watch-approval",
];

pub const LABEL_KIND: &str = "waycar.kind";
pub const LABEL_SESSION: &str = "waycar.session";
pub const LABEL_TRANSCRIPT: &str = "waycar.transcript";
pub const LABEL_TURN: &str = "waycar.turn";
pub const LABEL_STATUS: &str = "waycar.status";
const LABELS: [&str; 5] = [
    LABEL_KIND,
    LABEL_SESSION,
    LABEL_TRANSCRIPT,
    LABEL_TURN,
    LABEL_STATUS,
];

const CORE_TIMEOUT: Duration = Duration::from_millis(2000);

/// What a hook needs from herdr-core and Waycar's config; the tests give it a
/// fake core.
pub trait CoreHost {
    /// Whether `core_enabled` allows core (missing config means it does).
    fn enabled(&self, env: &Env) -> bool;
    /// The `herdr-core` that answers `--version`, with the env to run it in.
    fn command(&self, env: &Env) -> Option<CoreCommand>;
    /// Run `bin args` with `env`.
    fn run(&self, bin: &str, args: &[&str], env: &Env) -> RunResult;
    /// Start `waycar notify --pane hc:<address> --status <status>` detached
    /// with `env`; a start failure is ignored.
    fn notify(&self, address: &str, status: &str, env: &Env);
}

/// The real core and `waycar notify`.
pub struct SystemCore;

impl CoreHost for SystemCore {
    fn enabled(&self, env: &Env) -> bool {
        let home = Path::new(env.get("HOME").unwrap_or(""));
        let Ok(resolved) = resolve_host_config(env, home, &|herdr, args| {
            run_program(&herdr.bin, args, &herdr.env)
        }) else {
            return true;
        };
        read_notification_config(&resolved.config_dir.to_string_lossy())
            .map_or(true, |config| config.core_enabled)
    }

    fn command(&self, env: &Env) -> Option<CoreCommand> {
        let home = Path::new(env.get("HOME").unwrap_or(""));
        core::running_core(env, home, &|bin, args, env| {
            run_program_with_timeout(bin, args, env, CORE_TIMEOUT)
        })
    }

    fn run(&self, bin: &str, args: &[&str], env: &Env) -> RunResult {
        run_program_with_timeout(bin, args, env, CORE_TIMEOUT)
    }

    fn notify(&self, address: &str, status: &str, env: &Env) {
        spawn_notify(&core::to_waycar_pane_id(address), status, env);
    }
}

/// Start `waycar notify --pane <pane_id> --status <status>` detached, with
/// no stdin or output and `env` alone, and leave it. A missing CLI must not
/// fail the agent's hook.
pub fn spawn_notify(pane_id: &str, status: &str, env: &Env) {
    use std::os::unix::process::CommandExt;

    let Ok(waycar) = std::env::current_exe() else {
        return;
    };
    let mut command = Command::new(waycar);
    command
        .args(["notify", "--pane", pane_id, "--status", status])
        .env_clear()
        .envs(env.iter())
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    // SAFETY: setsid is async-signal-safe; nothing else runs in the child
    // between fork and exec.
    unsafe {
        command.pre_exec(|| {
            libc::setsid();
            Ok(())
        });
    }
    let _ = command.spawn();
}

/// The core terminal a hook runs in.
pub struct CoreTarget<'a> {
    host: &'a dyn CoreHost,
    core: CoreCommand,
    pub address: String,
    pub record: CoreTerminal,
}

/// The terminal `agent`'s hook runs in, or `None` (see the module docs).
/// `ppid` is the hook's parent.
pub fn resolve_core<'a>(
    agent: &str,
    env: &Env,
    ppid: u32,
    host: &'a dyn HookHost,
) -> Option<CoreTarget<'a>> {
    let core_host = host.core()?;
    let address = terminal_address(env)?;
    if is_named_session(env) {
        return None;
    }
    let tty = agent_tty(agent, env, ppid, host)?;
    if !core_host.enabled(env) {
        return None;
    }
    let command = core_host.command(env)?;
    let run = |bin: &str, args: &[&str], env: &Env| core_host.run(bin, args, env);
    let record = core::get(&command, &run, address).ok()??;
    if !record.is_live() {
        return None;
    }
    let pid = record.pid?.to_string();
    if read_tty(host, &pid)? != tty {
        return None;
    }
    Some(CoreTarget {
        host: core_host,
        core: command,
        address: address.to_string(),
        record,
    })
}

impl CoreTarget<'_> {
    fn set_labels(&self, pairs: &[(&str, &str)]) -> bool {
        let run = |bin: &str, args: &[&str], env: &Env| self.host.run(bin, args, env);
        core::label(&self.core, &run, &self.address, pairs).is_ok()
    }

    fn notify(&self, status: &str) {
        self.host.notify(&self.address, status, &self.core.env);
    }

    /// Apply one hook to the terminal, as the tmux path applies it to its pane.
    ///
    /// * `labels`: labels to set (`waycar.session`, `waycar.transcript`).
    /// * `status`: a status or conditional status.
    /// * `release`: clear every `waycar.*` label instead, but only when
    ///   `session_id` is the terminal's session or it records none.
    pub fn apply(
        &self,
        agent: &str,
        labels: &[(&str, String)],
        status: Option<&str>,
        release: bool,
        session_id: Option<&str>,
    ) {
        let held = |name: &str| {
            self.record
                .labels
                .get(name)
                .map(String::as_str)
                .filter(|value| !value.is_empty())
        };
        if release {
            if let (Some(wanted), Some(held)) = (session_id, held(LABEL_SESSION))
                && wanted != held
            {
                return;
            }
            let clear: Vec<(&str, &str)> = LABELS.iter().map(|name| (*name, "")).collect();
            if !self.set_labels(&clear) {
                return;
            }
            if self.record.waycar_status().is_some()
                || held(LABEL_KIND).is_some()
                || held(LABEL_STATUS).is_some()
            {
                self.notify("release");
            }
            return;
        }
        let core_status = self.record.waycar_status();
        let current = core_status.or_else(|| held(LABEL_STATUS));
        let next = status
            .and_then(|want| next_status(want, current).map(|next| (want, next)))
            .filter(|(want, next)| next == want || Some(*next) != current)
            .map(|(_, next)| next);
        let turn = self.record.turn.to_string();
        let mut pairs: Vec<(&str, &str)> = labels
            .iter()
            .map(|(name, value)| (*name, value.as_str()))
            .collect();
        if next.is_some() {
            if HOOK_AGENTS.contains(&agent) && !pairs.iter().any(|(name, _)| *name == LABEL_KIND) {
                pairs.push((LABEL_KIND, agent));
            }
            if next == Some("working") {
                pairs.push((LABEL_TURN, &turn));
            }
            if let (None, Some(next)) = (core_status, next) {
                pairs.push((LABEL_STATUS, next));
            }
        }
        if !pairs.is_empty() && !self.set_labels(&pairs) {
            return;
        }
        if let Some(next) = next {
            self.notify(next);
        }
    }
}

/// `waycar hook-status <agent> <status>`: Zellij, then the core fallback. Always
/// 0, nothing printed. `ppid` is the hook's parent (the exec'd waycar keeps
/// the shell's pid, so it is the agent or its shell).
///
/// `waycar hook-status <agent> session <id> [<transcript path>]` is how the
/// omp, pi, opencode and kilo extensions, which have no hook payload, record
/// their session (the tmux path of those sets `@waycar_session` itself).
pub fn run_hook_status_command(args: &[String], env: &Env, host: &dyn HookHost, ppid: u32) -> i32 {
    let agent = args.first().map_or("", String::as_str);
    let restored;
    let env = if agent == "muse" {
        restored = crate::hook_session::muse_environment(env, ppid, host);
        &restored
    } else {
        env
    };
    let want = args.get(1).map_or("", String::as_str);
    // Read-only ownership query for Chat Prompt extensions. 125 means not
    // owned; never write a document, ask a runtime or start a notification.
    if want == "owns-zellij" {
        return if env.non_empty("WAYCAR_SUMMARY").is_none()
            && crate::zellij::resolve(agent, env, ppid, host).is_some()
        {
            0
        } else {
            125
        };
    }
    let session = args.get(2).filter(|id| !id.is_empty());
    let wanted = if want == "session" {
        session.is_some()
    } else {
        STATUSES.contains(&want) && want != "watch-approval"
    };
    if wanted
        && env.non_empty("WAYCAR_SUMMARY").is_none()
        && let Some(target) = crate::zellij::resolve(agent, env, ppid, host)
    {
        let mut options = Vec::new();
        if want == "session"
            && let Some(id) = session
        {
            options.push(("@waycar_agent", agent.to_string()));
            options.push(("@waycar_session", id.clone()));
            if let Some(path) = args.get(3).filter(|p| !p.is_empty()) {
                options.push((
                    "@waycar_transcript",
                    crate::hook_session::percent_encode_path(path),
                ));
            }
        }
        target.apply(
            agent,
            &crate::hook_session::HookUpdate {
                options,
                status: STATUSES
                    .iter()
                    .copied()
                    .find(|s| *s == want && *s != "release"),
                release: want == "release",
                session_id: None,
            },
        );
        return 0;
    }
    if wanted
        && env.non_empty("WAYCAR_SUMMARY").is_none()
        && let Some(target) = resolve_core(agent, env, ppid, host)
    {
        match (want, session) {
            ("session", Some(id)) => {
                let mut labels = vec![(LABEL_KIND, agent.to_string()), (LABEL_SESSION, id.clone())];
                if let Some(transcript) = args.get(3).filter(|path| !path.is_empty()) {
                    labels.push((LABEL_TRANSCRIPT, transcript.clone()));
                }
                target.apply(agent, &labels, None, false, None);
            }
            ("release", _) => target.apply(agent, &[], None, true, None),
            _ => target.apply(agent, &[], Some(want), false, None),
        }
    }
    0
}

/// A fake `herdr-core`: terminals held as `get --json` records, every
/// invocation logged, notifications recorded.
#[cfg(test)]
pub mod fake {
    use std::cell::RefCell;
    use std::collections::BTreeMap;

    use serde_json::{Value, json};

    use super::CoreHost;
    use crate::core::CoreCommand;
    use crate::env::Env;
    use crate::exec::RunResult;

    pub const ADDRESS: &str = "t7";

    #[derive(Default)]
    pub struct FakeCore {
        pub terminals: RefCell<BTreeMap<String, Value>>,
        pub log: RefCell<Vec<Vec<String>>>,
        pub notifications: RefCell<Vec<String>>,
        pub version_missing: bool,
        pub disabled: bool,
    }

    /// A live terminal whose program is process `pid`.
    pub fn record(address: &str, pid: u64, status: Option<&str>, turn: u64) -> Value {
        json!({
            "address": address,
            "state": "live",
            "pid": pid,
            "reported": status.is_some(),
            "status": status.map(|state| json!({"state": state, "app": "claude"})),
            "turn": turn,
            "labels": {},
        })
    }

    impl FakeCore {
        pub fn with(record: Value) -> Self {
            let fake = Self::default();
            fake.put(record);
            fake
        }

        pub fn put(&self, record: Value) {
            let address = record["address"].as_str().unwrap().to_string();
            self.terminals.borrow_mut().insert(address, record);
        }

        pub fn labels(&self, address: &str) -> BTreeMap<String, String> {
            self.terminals.borrow()[address]["labels"]
                .as_object()
                .unwrap()
                .iter()
                .map(|(k, v)| (k.clone(), v.as_str().unwrap().to_string()))
                .collect()
        }

        /// The `label` invocations, as `label <address> k=v ...`.
        pub fn label_calls(&self) -> Vec<String> {
            self.log
                .borrow()
                .iter()
                .filter(|argv| argv[0] == "label")
                .map(|argv| argv.join(" "))
                .collect()
        }
    }

    impl CoreHost for FakeCore {
        fn enabled(&self, _env: &Env) -> bool {
            !self.disabled
        }

        fn command(&self, env: &Env) -> Option<CoreCommand> {
            (!self.version_missing).then(|| CoreCommand {
                bin: "/fake/herdr-core".to_string(),
                version: "0.1.14".to_string(),
                env: env.clone(),
            })
        }

        fn run(&self, _bin: &str, args: &[&str], _env: &Env) -> RunResult {
            self.log
                .borrow_mut()
                .push(args.iter().map(|a| (*a).to_string()).collect());
            let ok = |stdout: String| RunResult {
                stdout,
                stderr: String::new(),
                code: 0,
            };
            match args {
                ["get", address, "--json"] => match self.terminals.borrow().get(*address) {
                    Some(record) => ok(record.to_string()),
                    None => RunResult {
                        stdout: json!({"error": {"kind": "not_found"}}).to_string(),
                        stderr: String::new(),
                        code: 3,
                    },
                },
                ["label", address, pairs @ ..] => {
                    let mut terminals = self.terminals.borrow_mut();
                    let Some(record) = terminals.get_mut(*address) else {
                        return RunResult {
                            stdout: String::new(),
                            stderr: "no such terminal".to_string(),
                            code: 3,
                        };
                    };
                    let labels = record["labels"].as_object_mut().unwrap();
                    for pair in pairs {
                        let (key, value) = pair.split_once('=').unwrap();
                        if value.is_empty() {
                            labels.remove(key);
                        } else {
                            labels.insert(key.to_string(), json!(value));
                        }
                    }
                    ok(String::new())
                }
                _ => RunResult {
                    stdout: String::new(),
                    stderr: "unexpected".to_string(),
                    code: 2,
                },
            }
        }

        fn notify(&self, address: &str, status: &str, _env: &Env) {
            self.notifications
                .borrow_mut()
                .push(format!("notify --pane hc:{address} --status {status}"));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::fake::{ADDRESS, FakeCore, record};
    use super::*;
    use crate::hook_session::fake::Fake;
    use crate::hook_session::run_hook_session;

    const PPID: u32 = 4242;
    /// The tmux fake's pane tty is /dev/ttys021; the core terminal's program
    /// runs on this one.
    const CORE_PID: u64 = 900;

    /// A tmux fake and a fake core in one host.
    struct Both {
        tmux: Fake,
        core: FakeCore,
    }

    impl HookHost for Both {
        fn tmux(&self, args: &[&str], env: &Env) -> Option<String> {
            self.tmux.tmux(args, env)
        }
        fn tty(&self, pid: &str) -> String {
            self.tmux.tty(pid)
        }
        fn ppid(&self, pid: &str) -> String {
            self.tmux.ppid(pid)
        }
        fn notify(&self, pane: &str, status: &str, env: &Env) {
            self.tmux.notify(pane, status, env);
        }
        fn core(&self) -> Option<&dyn CoreHost> {
            Some(&self.core)
        }
    }

    /// The agent (`PPID`) and the terminal's program share `pts/5`.
    fn host(status: Option<&str>, turn: u64) -> Both {
        let both = Both {
            tmux: Fake::new(),
            core: FakeCore::with(record(ADDRESS, CORE_PID, status, turn)),
        };
        both.tmux.ps_table.borrow_mut().insert(
            PPID.to_string(),
            (Some("pts/5".to_string()), Some("1".to_string())),
        );
        both.tmux.ps_table.borrow_mut().insert(
            CORE_PID.to_string(),
            (Some("pts/5".to_string()), Some("1".to_string())),
        );
        both
    }

    fn env(extra: &[(&str, &str)]) -> Env {
        let mut env = Env::from_pairs([("HOME", "/h"), ("HC_TERMINAL_ID", ADDRESS)]);
        for (name, value) in extra {
            env.set(*name, *value);
        }
        env
    }

    fn run(host: &Both, env: &Env, agent: &str, want: &str) {
        let args = vec![agent.to_string(), want.to_string()];
        assert_eq!(run_hook_status_command(&args, env, host, PPID), 0);
    }

    fn notes(host: &Both) -> Vec<String> {
        host.core.notifications.borrow().clone()
    }

    #[test]
    fn working_labels_the_terminal_and_notifies_with_the_core_id() {
        let host = host(Some("idle"), 3);
        run(&host, &env(&[]), "claude", "working");
        let labels = host.core.labels(ADDRESS);
        assert_eq!(labels["waycar.kind"], "claude");
        assert_eq!(labels["waycar.turn"], "3");
        assert_eq!(
            host.core.label_calls(),
            ["label t7 waycar.kind=claude waycar.turn=3"]
        );
        assert_eq!(notes(&host), ["notify --pane hc:t7 --status working"]);
        // Nothing went to tmux.
        assert!(host.tmux.log.borrow().is_empty());
    }

    #[test]
    fn done_and_blocked_set_the_kind_but_not_the_turn() {
        let host = host(Some("working"), 3);
        run(&host, &env(&[]), "codex", "done");
        run(&host, &env(&[]), "codex", "blocked");
        let labels = host.core.labels(ADDRESS);
        assert_eq!(labels["waycar.kind"], "codex");
        assert!(!labels.contains_key("waycar.turn"));
        assert_eq!(
            notes(&host),
            [
                "notify --pane hc:t7 --status done",
                "notify --pane hc:t7 --status blocked"
            ]
        );
    }

    #[test]
    fn an_unconditional_status_is_taken_even_when_core_already_shows_it() {
        // The agent's own report may land before the hook.
        let host = host(Some("working"), 1);
        run(&host, &env(&[]), "claude", "working");
        assert_eq!(notes(&host), ["notify --pane hc:t7 --status working"]);
    }

    #[test]
    fn conditional_statuses_read_core_status() {
        let cases = [
            ("working-if-active", "working", None),
            ("working-if-active", "blocked", Some("working")),
            ("working-if-active", "idle", None),
            ("working-if-active", "done", None),
            ("working-if-blocked", "blocked", Some("working")),
            ("working-if-blocked", "working", None),
            ("idle-if-working", "working", Some("idle")),
            ("idle-if-working", "blocked", None),
            ("done-if-active", "working", Some("done")),
            ("done-if-active", "blocked", Some("done")),
            ("done-if-active", "idle", None),
            // core `error` is `blocked`
            ("working-if-blocked", "error", Some("working")),
        ];
        for (want, core_status, expected) in cases {
            let host = host(Some(core_status), 1);
            run(&host, &env(&[]), "claude", want);
            let expected: Vec<String> = expected
                .map(|status| format!("notify --pane hc:t7 --status {status}"))
                .into_iter()
                .collect();
            assert_eq!(notes(&host), expected, "{want} from {core_status}");
        }
    }

    #[test]
    fn a_conditional_status_with_no_report_does_nothing() {
        let host = host(None, 0);
        run(&host, &env(&[]), "claude", "working-if-active");
        assert!(notes(&host).is_empty());
        assert!(host.core.label_calls().is_empty());
        // An unconditional one works for an agent that never reports.
        run(&host, &env(&[]), "claude", "working");
        assert_eq!(notes(&host), ["notify --pane hc:t7 --status working"]);
    }

    fn status_label(host: &Both) -> Option<String> {
        host.core.labels(ADDRESS).get("waycar.status").cloned()
    }

    #[test]
    fn a_non_reporting_terminal_tracks_its_status_in_a_label() {
        let host = host(None, 0);
        run(&host, &env(&[]), "claude", "working");
        assert_eq!(status_label(&host).as_deref(), Some("working"));
        assert_eq!(
            host.core.label_calls(),
            ["label t7 waycar.kind=claude waycar.turn=0 waycar.status=working"]
        );
        run(&host, &env(&[]), "claude", "done-if-active");
        assert_eq!(status_label(&host).as_deref(), Some("done"));
        assert_eq!(
            notes(&host),
            [
                "notify --pane hc:t7 --status working",
                "notify --pane hc:t7 --status done"
            ]
        );
        // done is not active any more.
        run(&host, &env(&[]), "claude", "done-if-active");
        run(&host, &env(&[]), "claude", "working-if-active");
        assert_eq!(notes(&host).len(), 2);
    }

    #[test]
    fn conditional_statuses_on_a_non_reporting_terminal_read_the_label() {
        let cases = [
            ("working-if-active", "working", Some("working")),
            ("working-if-active", "blocked", Some("working")),
            ("working-if-active", "idle", None),
            ("working-if-active", "done", None),
            ("done-if-active", "idle", None),
            ("done-if-active", "blocked", Some("done")),
            ("working-if-blocked", "blocked", Some("working")),
            ("working-if-blocked", "working", None),
            ("working-if-blocked", "idle", None),
            ("idle-if-working", "working", Some("idle")),
            ("idle-if-working", "blocked", None),
            ("idle-if-working", "done", None),
        ];
        for (want, label, expected) in cases {
            let host = host(None, 0);
            host.core.terminals.borrow_mut().get_mut(ADDRESS).unwrap()["labels"]["waycar.status"] =
                label.into();
            run(&host, &env(&[]), "claude", want);
            // `working-if-active` from working is already working: no push.
            let expected = expected.filter(|next| *next != label);
            let expected: Vec<String> = expected
                .map(|status| format!("notify --pane hc:t7 --status {status}"))
                .into_iter()
                .collect();
            assert_eq!(notes(&host), expected, "{want} from label {label}");
        }
    }

    #[test]
    fn release_clears_the_status_label_of_a_non_reporting_terminal() {
        let host = host(None, 0);
        run(&host, &env(&[]), "claude", "working");
        run(&host, &env(&[]), "claude", "release");
        assert!(host.core.labels(ADDRESS).is_empty());
        assert_eq!(
            notes(&host).last().unwrap(),
            "notify --pane hc:t7 --status release"
        );
    }

    #[test]
    fn a_reporting_terminal_never_gets_a_status_label() {
        let host = host(Some("idle"), 1);
        run(&host, &env(&[]), "claude", "working");
        run(&host, &env(&[]), "claude", "done");
        assert_eq!(status_label(&host), None);
        // The label is ignored while core reports.
        host.core.terminals.borrow_mut().get_mut(ADDRESS).unwrap()["labels"]["waycar.status"] =
            "working".into();
        host.core.notifications.borrow_mut().clear();
        run(&host, &env(&[]), "claude", "working-if-active");
        assert!(notes(&host).is_empty(), "core says idle");
    }

    #[test]
    fn an_unknown_agent_gets_no_kind_label() {
        let host = host(Some("idle"), 0);
        run(&host, &env(&[]), "mystery", "done");
        assert!(!host.core.labels(ADDRESS).contains_key("waycar.kind"));
        assert_eq!(notes(&host), ["notify --pane hc:t7 --status done"]);
    }

    #[test]
    fn release_clears_all_five_labels_and_notifies() {
        let host = host(Some("done"), 2);
        run(&host, &env(&[]), "claude", "working");
        host.core.terminals.borrow_mut().get_mut(ADDRESS).unwrap()["labels"]["waycar.session"] =
            "s1".into();
        host.core.put({
            let mut kept = host.core.terminals.borrow()[ADDRESS].clone();
            kept["labels"]["waycar.transcript"] = "/t".into();
            kept
        });
        host.core.notifications.borrow_mut().clear();
        run(&host, &env(&[]), "claude", "release");
        assert!(host.core.labels(ADDRESS).is_empty());
        assert_eq!(
            host.core.label_calls().last().unwrap(),
            "label t7 waycar.kind= waycar.session= waycar.transcript= waycar.turn= waycar.status="
        );
        assert_eq!(notes(&host), ["notify --pane hc:t7 --status release"]);
    }

    #[test]
    fn release_of_an_untracked_terminal_clears_without_a_notification() {
        let host = host(None, 0);
        run(&host, &env(&[]), "claude", "release");
        assert!(notes(&host).is_empty());
    }

    #[test]
    fn watch_approval_and_unknown_statuses_do_nothing_at_all() {
        let host = host(Some("working"), 1);
        run(&host, &env(&[]), "agy", "watch-approval");
        run(&host, &env(&[]), "agy", "bogus");
        run(&host, &env(&[]), "agy", "");
        assert!(host.core.log.borrow().is_empty());
        assert!(notes(&host).is_empty());
    }

    #[test]
    fn a_summary_harness_is_never_an_agent() {
        let host = host(Some("idle"), 0);
        run(&host, &env(&[("WAYCAR_SUMMARY", "1")]), "claude", "working");
        assert!(host.core.log.borrow().is_empty());
    }

    #[test]
    fn no_terminal_id_means_not_core() {
        let host = host(Some("idle"), 0);
        let mut bare = env(&[]);
        bare.set("HC_TERMINAL_ID", "");
        run(&host, &bare, "claude", "working");
        assert!(host.core.log.borrow().is_empty());
        let mut odd = env(&[]);
        odd.set("HC_TERMINAL_ID", "--bad");
        run(&host, &odd, "claude", "working");
        assert!(host.core.log.borrow().is_empty());
    }

    #[test]
    fn a_named_core_session_is_skipped_and_the_default_one_is_not() {
        let host = host(Some("idle"), 0);
        run(&host, &env(&[("HC_SESSION", "w479")]), "claude", "working");
        assert!(host.core.log.borrow().is_empty());
        run(
            &host,
            &env(&[("HC_SESSION", "default")]),
            "claude",
            "working",
        );
        assert_eq!(notes(&host).len(), 1);
    }

    #[test]
    fn core_enabled_false_skips_the_terminal() {
        let mut host = host(Some("idle"), 0);
        host.core.disabled = true;
        run(&host, &env(&[]), "claude", "working");
        assert!(host.core.log.borrow().is_empty());
        assert!(notes(&host).is_empty());
    }

    #[test]
    fn a_missing_herdr_core_is_silent() {
        let mut host = host(Some("idle"), 0);
        host.core.version_missing = true;
        run(&host, &env(&[]), "claude", "working");
        assert!(host.core.log.borrow().is_empty());
        assert!(notes(&host).is_empty());
    }

    #[test]
    fn a_gone_or_finished_terminal_is_skipped() {
        let host = host(Some("idle"), 0);
        run(
            &host,
            &env(&[("HC_TERMINAL_ID", "t99")]),
            "claude",
            "working",
        );
        assert!(notes(&host).is_empty());
        let mut finished = record(ADDRESS, CORE_PID, None, 1);
        finished["state"] = "finished".into();
        host.core.put(finished);
        run(&host, &env(&[]), "claude", "working");
        assert!(notes(&host).is_empty());
        assert!(host.core.label_calls().is_empty());
    }

    #[test]
    fn a_tty_mismatch_is_skipped() {
        let host = host(Some("idle"), 0);
        host.tmux.ps_table.borrow_mut().insert(
            CORE_PID.to_string(),
            (Some("pts/9".to_string()), Some("1".to_string())),
        );
        run(&host, &env(&[]), "claude", "working");
        assert!(notes(&host).is_empty());
        assert!(host.core.label_calls().is_empty());
    }

    #[test]
    fn a_terminal_whose_program_has_no_tty_is_skipped() {
        let host = host(Some("idle"), 0);
        host.tmux
            .ps_table
            .borrow_mut()
            .insert(CORE_PID.to_string(), (None, None));
        run(&host, &env(&[]), "claude", "working");
        assert!(notes(&host).is_empty());
    }

    #[test]
    fn claude_uses_claude_pid_and_one_hop_applies_to_other_kinds() {
        let host = host(Some("idle"), 0);
        // The hook's parent is a tty-less `sh -c`; its parent is on pts/5.
        host.tmux
            .ps_table
            .borrow_mut()
            .insert(PPID.to_string(), (None, Some("77".to_string())));
        host.tmux.ps_table.borrow_mut().insert(
            "77".to_string(),
            (Some("pts/5".to_string()), Some("1".to_string())),
        );
        run(&host, &env(&[]), "grok", "working");
        assert_eq!(notes(&host).len(), 1, "one hop for grok");
        // Claude with CLAUDE_PID reads that process instead.
        host.core.notifications.borrow_mut().clear();
        run(&host, &env(&[("CLAUDE_PID", "88")]), "claude", "working");
        assert!(notes(&host).is_empty(), "88 has the fake's default pts");
        host.tmux.ps_table.borrow_mut().insert(
            "88".to_string(),
            (Some("pts/5".to_string()), Some("1".to_string())),
        );
        run(&host, &env(&[("CLAUDE_PID", "88")]), "claude", "working");
        assert_eq!(notes(&host).len(), 1);
    }

    #[test]
    fn codex_and_cline_get_no_hop_on_core() {
        for agent in ["codex", "cline"] {
            let host = host(Some("idle"), 0);
            host.tmux
                .ps_table
                .borrow_mut()
                .insert(PPID.to_string(), (None, Some("77".to_string())));
            host.tmux.ps_table.borrow_mut().insert(
                "77".to_string(),
                (Some("pts/5".to_string()), Some("1".to_string())),
            );
            run(&host, &env(&[]), agent, "working");
            assert!(notes(&host).is_empty(), "{agent}");
            assert!(host.core.label_calls().is_empty(), "{agent}");
        }
    }

    // ---- `waycar hook-session` on core -------------------------------------

    fn claude_start() -> String {
        serde_json::json!({
            "hook_event_name": "SessionStart",
            "session_id": "s-1",
            "transcript_path": "/home/me/.claude/projects/a b/s-1.jsonl",
            "source": "startup",
        })
        .to_string()
    }

    fn session_env(extra: &[(&str, &str)]) -> Env {
        let mut base = env(&[("CLAUDECODE", "1")]);
        for (name, value) in extra {
            base.set(*name, *value);
        }
        base
    }

    fn session(host: &Both, env: &Env, agent: &str, event: &str, body: &str) {
        run_hook_session(agent, event, body, env, PPID, host);
    }

    #[test]
    fn session_start_labels_a_core_terminal_with_the_raw_transcript_path() {
        let host = host(Some("done"), 2);
        session(
            &host,
            &session_env(&[]),
            "claude",
            "SessionStart",
            &claude_start(),
        );
        let labels = host.core.labels(ADDRESS);
        assert_eq!(labels["waycar.kind"], "claude");
        assert_eq!(labels["waycar.session"], "s-1");
        assert_eq!(
            labels["waycar.transcript"],
            "/home/me/.claude/projects/a b/s-1.jsonl"
        );
        assert_eq!(notes(&host), ["notify --pane hc:t7 --status idle"]);
        assert!(host.tmux.log.borrow().is_empty());
    }

    #[test]
    fn a_stale_tmux_pane_with_another_tty_falls_through_to_core() {
        let host = host(Some("done"), 2);
        // The tmux fake has pane %7 on /dev/ttys021; the agent is on pts/5.
        let env = session_env(&[("TMUX_PANE", "%7"), ("TMUX", "/tmp/x,1,0")]);
        session(&host, &env, "claude", "SessionStart", &claude_start());
        assert_eq!(host.core.labels(ADDRESS)["waycar.session"], "s-1");
        assert_eq!(notes(&host), ["notify --pane hc:t7 --status idle"]);
        assert!(host.tmux.writes().is_empty());
        assert!(host.tmux.notifications.borrow().is_empty());
    }

    #[test]
    fn a_tmux_pane_whose_tty_matches_wins_over_core() {
        let host = host(Some("done"), 2);
        // The agent is on the tmux pane's tty; the core terminal's is another.
        host.tmux
            .ps_table
            .borrow_mut()
            .remove(PPID.to_string().as_str());
        let env = session_env(&[("TMUX_PANE", "%7"), ("TMUX", "/tmp/x,1,0")]);
        session(&host, &env, "claude", "SessionStart", &claude_start());
        assert_eq!(
            host.tmux.pane_options()["@waycar_session"],
            "s-1",
            "tmux took it"
        );
        assert_eq!(
            *host.tmux.notifications.borrow(),
            ["notify --pane tmux:%7 --status idle"]
        );
        assert!(host.core.log.borrow().is_empty());
        assert!(notes(&host).is_empty());
    }

    #[test]
    fn stale_herdr_variables_do_not_silence_a_core_terminal() {
        let host = host(Some("done"), 2);
        let env = session_env(&[("HERDR_PANE_ID", "p_1"), ("HERDR_ENV", "1")]);
        session(&host, &env, "claude", "SessionStart", &claude_start());
        assert_eq!(host.core.labels(ADDRESS)["waycar.session"], "s-1");
    }

    #[test]
    fn herdr_variables_without_a_core_terminal_still_end_the_hook() {
        let host = host(Some("done"), 2);
        let mut env = session_env(&[("HERDR_PANE_ID", "p_1"), ("TMUX_PANE", "%7")]);
        env.set("HC_TERMINAL_ID", "");
        host.tmux
            .ps_table
            .borrow_mut()
            .remove(PPID.to_string().as_str());
        session(&host, &env, "claude", "SessionStart", &claude_start());
        assert!(host.tmux.log.borrow().is_empty());
        assert!(host.core.log.borrow().is_empty());
    }

    #[test]
    fn no_pane_and_no_terminal_id_is_silent() {
        let host = host(Some("done"), 2);
        let mut env = session_env(&[]);
        env.set("HC_TERMINAL_ID", "");
        session(&host, &env, "claude", "SessionStart", &claude_start());
        assert!(host.tmux.log.borrow().is_empty());
        assert!(host.core.log.borrow().is_empty());
    }

    #[test]
    fn session_end_releases_core_labels_only_for_the_held_session() {
        let host = host(Some("working"), 2);
        run(&host, &env(&[]), "copilot", "working");
        host.core.terminals.borrow_mut().get_mut(ADDRESS).unwrap()["labels"]["waycar.session"] =
            "s-1".into();
        let other = r#"{"session_id":"s-2"}"#;
        session(&host, &env(&[]), "copilot", "SessionEnd", other);
        assert_eq!(
            host.core.labels(ADDRESS)["waycar.session"],
            "s-1",
            "stray end"
        );
        session(
            &host,
            &env(&[]),
            "copilot",
            "SessionEnd",
            r#"{"session_id":"s-1"}"#,
        );
        assert!(host.core.labels(ADDRESS).is_empty());
        assert_eq!(
            notes(&host).last().unwrap(),
            "notify --pane hc:t7 --status release"
        );
    }

    #[test]
    fn a_session_hook_on_core_obeys_the_same_guards() {
        // A summary harness, a named session, core_enabled false, a tty mismatch.
        let host = host(Some("done"), 2);
        session(
            &host,
            &session_env(&[("WAYCAR_SUMMARY", "1")]),
            "claude",
            "SessionStart",
            &claude_start(),
        );
        session(
            &host,
            &session_env(&[("HC_SESSION", "w1")]),
            "claude",
            "SessionStart",
            &claude_start(),
        );
        host.tmux
            .ps_table
            .borrow_mut()
            .insert(CORE_PID.to_string(), (Some("pts/9".to_string()), None));
        session(
            &host,
            &session_env(&[]),
            "claude",
            "SessionStart",
            &claude_start(),
        );
        assert!(host.core.label_calls().is_empty());
        let mut off = self::host(Some("done"), 2);
        off.core.disabled = true;
        session(
            &off,
            &session_env(&[]),
            "claude",
            "SessionStart",
            &claude_start(),
        );
        assert!(off.core.label_calls().is_empty());
    }

    #[test]
    fn muse_gets_its_core_variables_back_from_the_agents_environment() {
        let proc = crate::test_support::TempDir::new("muse-core");
        let dir = proc.path().join(PPID.to_string());
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("environ"),
            "HC_TERMINAL_ID=t7\0HC_TERMINAL_SOCKET=/run/hc.sock\0HC_SESSION=default\0HC_SOCKET=/run/hc.sock\0PATH=/x\0",
        )
        .unwrap();
        let cleared = Env::from_pairs([
            ("HOME", "/h"),
            ("WAYCAR_HOOK_PROC", &proc.path().to_string_lossy()),
        ]);
        let host = host(Some("idle"), 0);
        let restored = crate::hook_session::muse_environment(&cleared, PPID, &host);
        assert_eq!(restored.get("HC_TERMINAL_ID"), Some("t7"));
        assert_eq!(restored.get("HC_TERMINAL_SOCKET"), Some("/run/hc.sock"));
        assert_eq!(restored.get("HC_SESSION"), Some("default"));
        assert_eq!(restored.get("HC_SOCKET"), Some("/run/hc.sock"));
        assert_eq!(restored.get("PATH"), None);
        // End to end: a muse prompt in a core terminal labels it.
        let body = r#"{"session_id":"m-1","transcript_path":null}"#;
        session(&host, &cleared, "muse", "UserPromptSubmit", body);
        let labels = host.core.labels(ADDRESS);
        assert_eq!(labels["waycar.kind"], "muse");
        assert_eq!(labels["waycar.session"], "m-1");
        assert_eq!(notes(&host), ["notify --pane hc:t7 --status working"]);
    }

    #[test]
    fn the_session_form_labels_the_terminal_without_a_status() {
        let host = host(Some("working"), 4);
        let args: Vec<String> = ["omp", "session", "/s/a b.jsonl", "/s/a b.jsonl"]
            .map(String::from)
            .to_vec();
        assert_eq!(run_hook_status_command(&args, &env(&[]), &host, PPID), 0);
        let labels = host.core.labels(ADDRESS);
        assert_eq!(labels["waycar.kind"], "omp");
        assert_eq!(labels["waycar.session"], "/s/a b.jsonl");
        assert_eq!(labels["waycar.transcript"], "/s/a b.jsonl");
        assert!(!labels.contains_key("waycar.turn"));
        assert!(notes(&host).is_empty());
        // Without a transcript only the session is recorded; an empty id is nothing.
        let args: Vec<String> = ["pi", "session", "id-1"].map(String::from).to_vec();
        run_hook_status_command(&args, &env(&[]), &host, PPID);
        assert_eq!(host.core.labels(ADDRESS)["waycar.session"], "id-1");
        let empty: Vec<String> = ["pi", "session", ""].map(String::from).to_vec();
        let calls = host.core.label_calls().len();
        run_hook_status_command(&empty, &env(&[]), &host, PPID);
        assert_eq!(host.core.label_calls().len(), calls);
    }

    #[test]
    fn the_session_form_obeys_the_guards() {
        let host = host(Some("idle"), 0);
        let args: Vec<String> = ["omp", "session", "id"].map(String::from).to_vec();
        run_hook_status_command(&args, &env(&[("WAYCAR_SUMMARY", "1")]), &host, PPID);
        run_hook_status_command(&args, &env(&[("HC_SESSION", "x")]), &host, PPID);
        assert!(host.core.label_calls().is_empty());
    }

    #[test]
    fn a_host_without_core_support_does_nothing() {
        let tmux = Fake::new();
        let args = vec!["claude".to_string(), "working".to_string()];
        assert_eq!(run_hook_status_command(&args, &env(&[]), &tmux, PPID), 0);
        assert!(tmux.log.borrow().is_empty());
    }

    /// Every `herdr-core` subcommand but `--version` starts a core with the
    /// caller's environment frozen into it. A process that merely inherited
    /// `HC_TERMINAL_ID` (a herdr or tmux pane started from a core terminal, once
    /// that core is gone) must never ask: the socket is probed first.
    #[test]
    fn a_stale_terminal_environment_never_asks_a_core_that_is_not_listening() {
        let dir = crate::test_support::TempDir::new("hook-status-stale");
        let bin = dir.path().join("herdr-core");
        let log = dir.path().join("calls.log");
        crate::test_support::write_stub(
            &bin,
            &format!(
                "echo \"$*\" >> '{}'\nif [ \"$1\" = --version ]; then echo 'hc 0.1.14'; exit 0; fi\nexit 1",
                log.display()
            ),
        );
        let env = Env::from_pairs([
            ("PATH", dir.path().to_string_lossy().into_owned()),
            ("HOME", dir.path().to_string_lossy().into_owned()),
            ("HC_TERMINAL_ID", "t1".to_string()),
            (
                "HC_TERMINAL_SOCKET",
                dir.path().join("gone.sock").to_string_lossy().into_owned(),
            ),
        ]);

        assert!(SystemCore.command(&env).is_none());
        assert!(!log.exists(), "herdr-core was run");

        // With something listening, the same environment finds core and runs only
        // its version probe.
        let socket = dir.path().join("gone.sock");
        let _listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();
        let core = SystemCore.command(&env).expect("a listening core is found");
        assert_eq!(core.version, "0.1.14");
        assert_eq!(std::fs::read_to_string(&log).unwrap().trim(), "--version");
    }
}
