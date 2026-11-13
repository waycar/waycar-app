//! OpenCode 2's shared server runs Waycar's plugin once per loaded Location,
//! with the environment of whichever client started it, so its sessions have
//! no pane. The plugin's V2 `setup` hands each needs-your-OK, question and
//! finished turn to `waycar opencode-push <status>` (the event on stdin), which
//! records it here and notifies as `opencode:<sessionID>` through the normal
//! encrypted producer, as Codex's daemon threads do.

use std::io::Read;
use std::path::Path;

use serde_json::{Value, json};

use crate::atomic::edit_locked;
use crate::codex_hook::{ServerAgent, run_server_notify, server_state_path};
use crate::env::Env;
use crate::error::Result;
use crate::exec::run_program;
use crate::hook_session::parse_hook_input;
use crate::notify_core::{Deps, clear_last_notified};
use crate::paths::resolve_host_config;

pub const OPENCODE: ServerAgent = ServerAgent {
    kind: "opencode",
    state_dir: "opencode-hooks",
    enabled: |config| config.opencode_enabled,
};

/// True for `opencode:<sessionID>` with a non-empty id.
pub fn is_session_pane_id(pane_id: &str) -> bool {
    pane_id
        .strip_prefix("opencode:")
        .is_some_and(|id| !id.is_empty())
}

/// `waycar opencode-push blocked|done`, `{session_id, key, reply?}` on
/// stdin: `key` names the event (each plugin instance sends the same one).
/// Always exits 0, and prints nothing.
pub fn run_push_command(args: &[String], env: &Env) -> i32 {
    let mut raw = String::new();
    let _ = std::io::stdin().read_to_string(&mut raw);
    if env.non_empty("WAYCAR_SUMMARY").is_some() {
        return 0;
    }
    let (Some(status), Some(input)) = (args.first(), parse_hook_input(&raw)) else {
        return 0;
    };
    let home = Path::new(env.get("HOME").unwrap_or(""));
    let Ok(host) = resolve_host_config(env, home, &|cmd, args| {
        run_program(&cmd.bin, args, &cmd.env)
    }) else {
        return 0;
    };
    // Record first, then detach: the debounce and relay retries must not
    // hold up the server's plugin.
    if let Ok(Some((pane_id, status))) = record_in(status, &input, &host.state_dir) {
        crate::hook_status::spawn_notify(&pane_id, &status, env);
    }
    0
}

/// Record the session's latest event; `None` when there is nothing to send,
/// including an event another plugin instance already recorded.
///
/// One snapshot per session, on purpose (as for Codex's threads): events of
/// one session within the debounce coalesce into the latest status and
/// reply. Each event's notifier re-checks the snapshot after its hold, so a
/// blocked push is dropped when the session moved on meanwhile (the request
/// was answered and the turn finished), and only the newest event pushes.
fn record_in(status: &str, input: &Value, state_dir: &Path) -> Result<Option<(String, String)>> {
    if !matches!(status, "blocked" | "done") {
        return Ok(None);
    }
    let text = |key| {
        input
            .get(key)
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
    };
    let (Some(session), Some(key)) = (text("session_id"), text("key")) else {
        return Ok(None);
    };
    let pane_id = format!("opencode:{session}");
    let snapshot = json!({
        "status": status,
        "key": key,
        "reply": (status == "done").then(|| text("reply")).flatten(),
    });
    let recorded = edit_locked(
        &server_state_path(&OPENCODE, state_dir, &pane_id),
        "hook",
        |lines| {
            let current: Value = serde_json::from_str(&lines.join("\n")).unwrap_or(Value::Null);
            if current["status"] == snapshot["status"] && current["key"] == snapshot["key"] {
                return None; // this event is already on its way
            }
            // A new event (the next turn, another request) re-arms the
            // previous push's dedupe.
            clear_last_notified(state_dir, &pane_id);
            Some(vec![snapshot.to_string()])
        },
    )?;
    Ok(recorded.then(|| (pane_id, status.to_string())))
}

/// `waycar notify --pane opencode:<session> --status <s>`: reads only the
/// recorded event; never a pane, tmux options or core labels.
pub fn run_notify(
    pane_id: &str,
    status: &str,
    env: &Env,
    home: &Path,
    deps: &Deps<'_>,
    stderr: &mut String,
) -> Result<()> {
    run_server_notify(&OPENCODE, pane_id, status, env, home, deps, stderr)
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::rc::Rc;

    use super::*;
    use crate::notify_fake::rig::{Rig, device, key_a};

    const SESSION: &str = "ses_1ccbc2dde001KMV5o9WilAolV9";

    fn send(rig: &Rig, status: &str, input: Value) {
        if let Some((pane, status)) = record_in(status, &input, &rig.state_dir).unwrap() {
            notify(rig, pane, status);
        }
    }

    fn notify(rig: &Rig, pane: String, status: String) {
        let env = Env::from_pairs([
            ("HERDR_PLUGIN_CONFIG_DIR", rig.config_dir.to_str().unwrap()),
            ("HERDR_PLUGIN_STATE_DIR", rig.state_dir.to_str().unwrap()),
        ]);
        let run = |_: &str, _: &[&str], _: &Env| {
            panic!("a session notification must not call a pane runtime")
        };
        let deps = Deps {
            fetch: rig.relay.as_ref(),
            clock: rig.clock.as_ref(),
            run: &run,
            summaries: rig.summaries.as_ref(),
            chat: rig.chat.as_ref(),
        };
        let args =
            crate::cli::parse_notify_args(&["--pane".into(), pane, "--status".into(), status])
                .unwrap();
        crate::hook_runtime::push_with(
            &args.pane_id,
            &args.status,
            &env,
            rig.home.path(),
            &deps,
            &mut String::new(),
        )
        .unwrap();
    }

    fn event(key: &str) -> Value {
        json!({"session_id": SESSION, "key": key, "reply": "The final reply"})
    }

    #[test]
    fn session_pushes_are_encrypted_once_per_event_with_the_reply() {
        let rig = Rig::tmux();
        rig.write_config(json!({}));
        rig.write_registration(&[device()]);
        let pane = format!("opencode:{SESSION}");

        send(&rig, "blocked", event("evt_permission"));
        send(&rig, "blocked", event("evt_permission")); // a second Location's instance
        send(&rig, "done", event("evt_done1"));
        send(&rig, "done", event("evt_done1"));
        send(&rig, "working", event("evt_working"));
        assert_eq!(rig.relay.posts().len(), 2, "one push per event");
        let blocked = rig.payload(0, &key_a()).1;
        assert_eq!(blocked["pane"], pane);
        assert_eq!(blocked["status"], "blocked");
        assert_eq!(blocked["kind"], "opencode");
        assert!(blocked.get("reply").is_none_or(Value::is_null));
        let done = rig.payload(1, &key_a()).1;
        assert_eq!(done["kind"], "opencode");
        assert_eq!(done["reply"], "The final reply");

        send(&rig, "blocked", event("evt_question")); // the next turn re-arms
        send(&rig, "done", event("evt_done2"));
        assert_eq!(rig.relay.posts().len(), 4);

        rig.write_config(json!({"opencode_enabled": false, "codex_enabled": true}));
        send(&rig, "blocked", event("evt_permission3"));
        send(&rig, "done", event("evt_done3"));
        assert_eq!(
            rig.relay.posts().len(),
            4,
            "opencode_enabled: false sends nothing"
        );
    }

    #[test]
    fn overlapping_events_of_one_session_push_once_for_the_later_state() {
        let rig = Rig::tmux();
        rig.write_config(json!({}));
        rig.write_registration(&[device()]);
        let blocked = record_in("blocked", &event("evt_permission"), &rig.state_dir)
            .unwrap()
            .unwrap();
        // The permission is answered and the turn finishes during the
        // blocked push's hold.
        let state_dir = rig.state_dir.clone();
        let finished = Rc::new(RefCell::new(None));
        let recorded = finished.clone();
        rig.clock.on_sleep(move || {
            if recorded.borrow().is_none() {
                *recorded.borrow_mut() = record_in("done", &event("evt_done"), &state_dir).unwrap();
            }
        });
        notify(&rig, blocked.0, blocked.1);
        assert!(
            rig.relay.posts().is_empty(),
            "the superseded blocked push is dropped"
        );
        let (pane, status) = finished.borrow_mut().take().expect("done recorded");
        notify(&rig, pane, status);
        assert_eq!(rig.relay.posts().len(), 1);
        let done = rig.payload(0, &key_a()).1;
        assert_eq!(done["status"], "done");
        assert_eq!(done["reply"], "The final reply");
    }

    #[test]
    fn events_without_a_session_or_key_record_nothing() {
        let rig = Rig::tmux();
        for input in [
            json!({"key": "evt_1"}),
            json!({"session_id": "", "key": "evt_1"}),
            json!({"session_id": SESSION}),
            json!({"session_id": 7, "key": "evt_1"}),
        ] {
            assert_eq!(
                record_in("done", &input, &rig.state_dir).unwrap(),
                None,
                "{input}"
            );
        }
    }

    #[test]
    fn notify_refuses_an_empty_session_id_like_codex() {
        for pane in ["opencode:", "codex:"] {
            let error = crate::cli::parse_notify_args(&[
                "--pane".into(),
                pane.into(),
                "--status".into(),
                "done".into(),
            ])
            .unwrap_err();
            assert!(error.to_string().contains("bad pane id"), "{pane}: {error}");
        }
        assert!(is_session_pane_id("opencode:ses_1"));
        assert!(!is_session_pane_id("opencode:"));
        assert!(!is_session_pane_id("codex:ses_1"));
    }
}
