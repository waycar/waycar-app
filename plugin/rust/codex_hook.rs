//! Shared app-server hooks have no pane: the daemon's inherited runtime
//! variables belong to the shell that started it. Keep thread status locally
//! for debounce/re-check, and use the normal encrypted notification producer.

use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use crate::atomic::{edit_locked, pane_file_name};
use crate::env::Env;
use crate::error::Result;
use crate::exec::run_program;
use crate::hook_session::{HookHost, SystemHost, parse_hook_input, read_tty};
use crate::notification_config::{NotificationConfig, read_notification_config};
use crate::notify_core::{
    Backend, Current, Deps, Event, Flow, Labels, Summary, clear_last_notified, run_notification,
};
use crate::paths::resolve_host_config;

/// A tty-less hook must descend from the shared server, not merely inherit
/// CODEX_THREAD_ID or a stale TMUX_PANE. Stop at a tty so embedded TUIs keep
/// their existing pane routing. The bound also fails closed on bad ps data.
pub fn is_daemon_hook(mut pid: u32, host: &dyn HookHost) -> bool {
    for _ in 0..16 {
        if pid <= 1 || read_tty(host, &pid.to_string()).is_some() {
            return false;
        }
        if let Some(args) = host.args(pid) {
            let mut words = args.split_whitespace();
            let bin = words.next().and_then(|p| Path::new(p).file_name());
            if bin.is_some_and(|b| b == "codex") && words.next() == Some("app-server") {
                let flags: Vec<_> = words.collect();
                if flags.contains(&"--managed-daemon")
                    || flags
                        .windows(2)
                        .any(|w| w[0] == "--listen" && w[1].starts_with("unix://"))
                {
                    return true;
                }
            }
        }
        let Ok(parent) = host.ppid(&pid.to_string()).parse::<u32>() else {
            return false;
        };
        if parent == pid {
            return false;
        }
        pid = parent;
    }
    false
}

/// The shell must keep its original routing when the tty-less parent was
/// only a wrapper around an embedded TUI, rather than a shared daemon.
pub const NOT_DAEMON: i32 = 125;

pub fn run_hook_command(args: &[String], env: &Env) -> i32 {
    let mut raw = String::new();
    let _ = std::io::stdin().read_to_string(&mut raw);
    run_hook(
        args.first().map_or("", String::as_str),
        &raw,
        env,
        std::os::unix::process::parent_id(),
        &SystemHost { env },
    )
}

fn run_hook(status: &str, raw: &str, env: &Env, ppid: u32, host: &dyn HookHost) -> i32 {
    if !is_daemon_hook(ppid, host) {
        return NOT_DAEMON;
    }
    if env.non_empty("WAYCAR_SUMMARY").is_none()
        && matches!(status, "blocked" | "done")
        && let Some(input) = parse_hook_input(raw)
    {
        host.codex_hook(status, &input, env);
    }
    0
}

/// A shared server's sessions, which notify without a pane: Codex's daemon
/// threads (`codex:<thread>`) and OpenCode 2 sessions (`opencode:<session>`).
pub struct ServerAgent {
    /// The pane id prefix and the push's agent kind.
    pub kind: &'static str,
    /// The folder in the state dir that holds each session's last event.
    pub state_dir: &'static str,
    /// Whether `notify.json` lets this agent notify.
    pub enabled: fn(&NotificationConfig) -> bool,
}

const CODEX: ServerAgent = ServerAgent {
    kind: "codex",
    state_dir: "codex-hooks",
    enabled: |config| config.codex_enabled,
};

pub fn server_state_path(agent: &ServerAgent, state_dir: &Path, pane_id: &str) -> PathBuf {
    state_dir
        .join(agent.state_dir)
        .join(pane_file_name(pane_id))
}

fn state_path(state_dir: &Path, pane_id: &str) -> PathBuf {
    server_state_path(&CODEX, state_dir, pane_id)
}

fn read_state(path: &Path) -> Option<Value> {
    serde_json::from_slice(&fs::read(path).ok()?).ok()
}

/// Record first, then detach: debounce and relay retries must not hold up
/// Codex's approval UI or outlive its hook timeout.
pub fn record(status: &str, input: &Value, env: &Env) {
    let home = Path::new(env.get("HOME").unwrap_or(""));
    let Ok(host) = resolve_host_config(env, home, &|cmd, args| {
        run_program(&cmd.bin, args, &cmd.env)
    }) else {
        return;
    };
    if let Ok(Some((pane_id, status))) = record_in(status, input, &host.state_dir) {
        crate::hook_status::spawn_notify(&pane_id, &status, env);
    }
}

fn record_in(status: &str, input: &Value, state_dir: &Path) -> Result<Option<(String, String)>> {
    if !matches!(status, "blocked" | "done") {
        return Ok(None);
    }
    let Some(session) = input
        .get("session_id")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
    else {
        return Ok(None);
    };
    let pane_id = format!("codex:{session}");
    let snapshot = json!({
        "status": status,
        "turn_id": input.get("turn_id"),
        "reply": (status == "done").then(|| input.get("last_assistant_message")).flatten(),
        "tool_name": (status == "blocked").then(|| input.get("tool_name")).flatten(),
        "tool_input": (status == "blocked").then(|| input.get("tool_input")).flatten(),
    });
    edit_locked(&state_path(state_dir, &pane_id), "hook", |lines| {
        let current: Value = serde_json::from_str(&lines.join("\n")).unwrap_or(Value::Null);
        // Working hooks are deliberately no-ops. A new turn (or a different
        // approval within it) must still re-arm the previous push's dedupe.
        if current != snapshot {
            clear_last_notified(state_dir, &pane_id);
        }
        Some(vec![snapshot.to_string()])
    })?;
    Ok(Some((pane_id, status.to_string())))
}

struct ServerNotification {
    kind: &'static str,
    path: PathBuf,
    snapshot: Value,
}

impl Backend for ServerNotification {
    type Detail = ();

    fn recheck(&self) -> Result<Option<Current<()>>> {
        Ok(read_state(&self.path).map(|state| Current {
            // A different turn is not a gone thread: returning None would
            // clear a newer notifier's dedupe claim in the shared producer.
            status: if state == self.snapshot {
                state["status"].as_str().unwrap_or("").to_string()
            } else {
                String::new()
            },
            agent_kind: Some(self.kind.to_string()),
            detail: (),
        }))
    }

    fn summarize(&self, _budget_ms: u64) -> Summary {
        Summary::default()
    }

    fn describe(&self, _current: &Current<()>) -> Labels {
        Labels::default()
    }

    fn attention(&self) -> Option<u64> {
        None
    }

    fn reply(&self) -> Option<String> {
        crate::display_text::optional_text(self.snapshot.get("reply")).map(str::to_string)
    }
}

/// `waycar notify --pane codex:<thread> --status <s>` reads only hook state;
/// it never resolves a pane or writes tmux options / core labels.
pub fn run_notify(
    pane_id: &str,
    status: &str,
    env: &Env,
    home: &Path,
    deps: &Deps<'_>,
    stderr: &mut String,
) -> Result<()> {
    run_server_notify(&CODEX, pane_id, status, env, home, deps, stderr)
}

/// `waycar notify --pane <kind>:<session> --status <s>` for a shared server's
/// session: reads only the state its hook recorded.
pub fn run_server_notify(
    agent: &ServerAgent,
    pane_id: &str,
    status: &str,
    env: &Env,
    home: &Path,
    deps: &Deps<'_>,
    stderr: &mut String,
) -> Result<()> {
    let is_agents = pane_id
        .strip_prefix(agent.kind)
        .is_some_and(|rest| rest.starts_with(':'));
    if !is_agents || !matches!(status, "blocked" | "done") {
        return Ok(());
    }
    let host = resolve_host_config(env, home, &|cmd, args| (deps.run)(&cmd.bin, args, &cmd.env))?;
    let config = read_notification_config(&host.config_dir.to_string_lossy())
        .map_err(crate::error::CliError::failure)?;
    if !(agent.enabled)(&config) {
        return Ok(());
    }
    let path = server_state_path(agent, &host.state_dir, pane_id);
    let Some(snapshot) = read_state(&path).filter(|s| s["status"] == status) else {
        return Ok(());
    };
    let flow = Flow {
        config_dir: &host.config_dir,
        state_dir: &host.state_dir,
        config: &config,
        fetch: deps.fetch,
        clock: deps.clock,
    };
    let event = Event {
        pane_id: pane_id.to_string(),
        status: status.to_string(),
        agent_kind: Some(agent.kind.to_string()),
    };
    run_notification(
        &flow,
        &event,
        deps.clock.now_ms(),
        &ServerNotification {
            kind: agent.kind,
            path,
            snapshot,
        },
        stderr,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hook_session::{fake::Fake, run_hook_session};
    use crate::notify_fake::rig::{Rig, device, key_a};

    const THREAD: &str = "019a7239-2b04-7000-8000-000000000001";

    fn daemon(command: &str) -> Fake {
        let host = Fake::new();
        *host.ps_tty.borrow_mut() = "?".into();
        host.ps_table
            .borrow_mut()
            .insert("41".into(), (Some("?".into()), Some("42".into())));
        host.ps_args.borrow_mut().insert(42, command.into());
        host
    }

    #[test]
    fn only_a_tty_less_shared_server_ancestor_is_a_daemon_hook() {
        for command in [
            "/opt/bin/codex app-server --managed-daemon",
            "codex app-server --listen unix:///tmp/codex.sock",
        ] {
            let host = daemon(command);
            assert!(is_daemon_hook(41, &host));
            host.ps_table
                .borrow_mut()
                .insert("42".into(), (Some("pts/3".into()), Some("1".into())));
            assert!(!is_daemon_hook(41, &host));
        }
        for command in [
            "codex",
            "codex app-server",
            "codex exec app-server --managed-daemon",
            "sh -c codex app-server --managed-daemon",
        ] {
            assert!(!is_daemon_hook(41, &daemon(command)), "{command}");
        }
    }

    #[test]
    fn daemon_hooks_never_resolve_inherited_runtime_panes() {
        let host = daemon("codex app-server --managed-daemon");
        let env = Env::from_pairs([
            ("TMUX_PANE", "%7"),
            ("HERDR_ENV", "1"),
            ("HERDR_PANE_ID", "w1:p3"),
            ("HC_TERMINAL_ID", "t1"),
        ]);
        let input = json!({"session_id": THREAD});
        for status in [
            "blocked",
            "done",
            "working",
            "working-if-active",
            "working-if-blocked",
            "idle",
            "release",
        ] {
            assert_eq!(run_hook(status, &input.to_string(), &env, 41, &host), 0);
        }
        assert_eq!(
            host.codex_hooks
                .borrow()
                .iter()
                .map(|(status, _)| status.as_str())
                .collect::<Vec<_>>(),
            ["blocked", "done"]
        );
        assert!(host.log.borrow().is_empty(), "no tmux call at all");
        assert!(host.notifications.borrow().is_empty());
    }

    #[test]
    fn embedded_codex_keeps_its_original_pane_path() {
        let host = Fake::new();
        let env = Env::from_pairs([("TMUX_PANE", "%7")]);
        let input =
            json!({"session_id": THREAD, "transcript_path": "/tmp/rollout.jsonl"}).to_string();
        run_hook_session("codex", "SessionStart", &input, &env, 41, &host);
        assert_eq!(run_hook("done", &input, &env, 41, &host), NOT_DAEMON);
        let options = host.pane_options();
        assert_eq!(options["@waycar_agent"], "codex");
        assert_eq!(options["@waycar_session"], THREAD);
        assert_eq!(options["@waycar_transcript"], "/tmp/rollout.jsonl");
        assert!(!options.contains_key("@waycar_status"));
        assert!(host.codex_hooks.borrow().is_empty());
        assert!(host.notifications.borrow().is_empty());
    }

    #[test]
    fn a_superseded_done_is_not_a_gone_thread_that_clears_newer_dedupe() {
        let rig = Rig::tmux();
        let pane = format!("codex:{THREAD}");
        let input = json!({"session_id": THREAD, "turn_id": "old"});
        record_in("done", &input, &rig.state_dir).unwrap();
        let path = state_path(&rig.state_dir, &pane);
        let backend = ServerNotification {
            kind: "codex",
            snapshot: read_state(&path).unwrap(),
            path,
        };
        record_in(
            "done",
            &json!({"session_id": THREAD, "turn_id": "new"}),
            &rig.state_dir,
        )
        .unwrap();
        assert_eq!(backend.recheck().unwrap().unwrap().status, "");
    }

    #[test]
    fn thread_pushes_use_the_normal_envelope_reply_preferences_and_rearm() {
        let rig = Rig::tmux();
        rig.write_config(json!({}));
        rig.write_registration(&[device()]);
        let env = Env::from_pairs([
            ("HERDR_PLUGIN_CONFIG_DIR", rig.config_dir.to_str().unwrap()),
            ("HERDR_PLUGIN_STATE_DIR", rig.state_dir.to_str().unwrap()),
        ]);
        let run = |_: &str, _: &[&str], _: &Env| {
            panic!("a thread notification must not call a pane runtime")
        };
        let deps = Deps {
            fetch: rig.relay.as_ref(),
            clock: rig.clock.as_ref(),
            run: &run,
            summaries: rig.summaries.as_ref(),
            chat: rig.chat.as_ref(),
        };
        let input = json!({"session_id": THREAD, "turn_id": "turn1", "last_assistant_message": "The final reply"});
        let pane = format!("codex:{THREAD}");
        assert_eq!(
            crate::cli::parse_notify_args(&[
                "--pane".into(),
                pane.clone(),
                "--status".into(),
                "done".into()
            ])
            .unwrap()
            .pane_id,
            pane
        );
        let send = |status, turn| {
            let mut input = input.clone();
            input["turn_id"] = json!(turn);
            let Some((id, status)) = record_in(status, &input, &rig.state_dir).unwrap() else {
                return;
            };
            run_notify(
                &id,
                &status,
                &env,
                rig.home.path(),
                &deps,
                &mut String::new(),
            )
            .unwrap();
        };
        send("working", "turn1");
        send("blocked", "turn1");
        send("working-if-blocked", "turn1");
        send("done", "turn1");
        send("done", "turn1");
        assert_eq!(rig.relay.posts().len(), 2, "duplicate Stop is deduped");
        let blocked = rig.payload(0, &key_a()).1;
        assert_eq!(blocked["pane"], pane);
        assert_eq!(blocked["status"], "blocked");
        assert_eq!(blocked["kind"], "codex");
        assert_eq!(rig.payload(1, &key_a()).1["reply"], "The final reply");
        send("working", "turn2");
        send("done", "turn2");
        assert_eq!(
            rig.relay.posts().len(),
            3,
            "next turn re-arms Done without a Working write"
        );
        rig.write_config(json!({"codex_enabled": false}));
        send("working", "turn3");
        send("done", "turn3");
        assert_eq!(rig.relay.posts().len(), 3);
        rig.write_config(json!({}));
        let mut muted = device();
        muted.notify = json!({"done": false, "blocked": false});
        rig.write_registration(&[muted]);
        send("working", "turn4");
        send("done", "turn4");
        assert_eq!(rig.relay.posts().len(), 3);
    }
}
