//! The hook runtime's subcommands (push, Live Activity, the agents' hook
//! payloads, the herdr entry points), run with the real network, clock,
//! processes and environment. `native::run` calls [`run`] for them.
//!
//! * `waycar notify --pane tmux:%N --status <s>` (waycar-cli.js `notify`), or
//!   `--pane hc:<address>` for a herdr-core terminal: the push flow and the
//!   Live Activity flow run side by side, and one failing never cancels the
//!   other. A shared server's session (`codex:<thread>`,
//!   `opencode:<session>`) has only the push flow.
//! * `waycar opencode-push <status>`: an OpenCode 2 server event from the
//!   opencode extension's V2 `setup`, its JSON on stdin.
//! * `waycar watch-approval --pane tmux:%N --agent <kind>`: each status the
//!   watch writes goes through the same notify.
//! * `waycar hook-session <agent> [<event>]`: an agent's hook payload on stdin.
//! * `waycar herdr-event notify|activity` and `waycar herdr-startup`: what the
//!   herdr manifest's `[[events]]` and `[[startup]]` hooks run.
//! * `waycar activity-tick '<json>'`: the detached plan-step tick the Live
//!   Activity hook starts (see [`crate::activity_tick::start_tick`]).
//!
//! Each prints exactly what its JS did.

use std::io::Write;
use std::path::Path;
use std::thread;

use crate::activity_hook::{
    ActivityDeps, run_core_activity, run_herdr_activity, run_progress_update, run_tmux_activity,
};
use crate::activity_tick::{TickDeps, TranscriptPlanReader, run_activity_tick_main, start_tick};
use crate::approval_watch::run_watch_approval;
use crate::cli::Native;
use crate::core::is_core_pane_id;
use crate::deps::{HttpFetch, SystemClock};
use crate::env::Env;
use crate::error::{EXIT_FAILURE, EXIT_OK, Result};
use crate::exec::run_program;
use crate::hook_session::{SystemHost, run_hook_session_command};
use crate::hook_status::run_hook_status_command;
use crate::native::Ctx;
use crate::notify_core::{Deps, run_core_notify, run_tmux_notify};
use crate::notify_hook::run_herdr_notify;
use crate::sidebar_config::run_sidebar_startup;

/// What a hook-runtime subcommand prints on stderr and exits with.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Outcome {
    code: i32,
    /// Exactly what goes to stderr, line breaks included.
    stderr: String,
}

impl Outcome {
    fn ok() -> Self {
        Self {
            code: EXIT_OK,
            stderr: String::new(),
        }
    }
}

/// Run one hook-runtime subcommand; `None` for any other. Output goes to
/// `err` and the exit code is returned.
pub fn run(native: &Native, ctx: &Ctx, err: &mut dyn Write) -> Option<i32> {
    let env = &ctx.env;
    let outcome = match native {
        Native::Notify(args) => notify(&args.pane_id, &args.status, ctx),
        Native::WatchApproval(rest) => {
            let notifier = |pane_id: &str, status: &str| {
                let outcome = notify(pane_id, status, ctx);
                // Not `eprint!`: that panics when stderr is closed.
                let _ = std::io::stderr().write_all(outcome.stderr.as_bytes());
            };
            match run_watch_approval(rest, env, &notifier) {
                Ok(()) => Outcome::ok(),
                Err(error) => Outcome {
                    code: error.exit_code(),
                    stderr: format!("waycar: {error}\n"),
                },
            }
        }
        Native::HookSession(args) => Outcome {
            code: run_hook_session_command(args, env),
            stderr: String::new(),
        },
        Native::HookStatus(args) => Outcome {
            code: run_hook_status_command(
                args,
                env,
                &SystemHost { env },
                std::os::unix::process::parent_id(),
            ),
            stderr: String::new(),
        },
        Native::CodexDaemonHook(args) => Outcome {
            code: crate::codex_hook::run_hook_command(args, env),
            stderr: String::new(),
        },
        Native::OpencodePush(args) => Outcome {
            code: crate::opencode_hook::run_push_command(args, env),
            stderr: String::new(),
        },
        Native::HerdrNotify => {
            let outcome = run_herdr_notify(env, &Deps::system());
            Outcome {
                code: outcome.code,
                stderr: outcome.stderr,
            }
        }
        Native::HerdrActivity => {
            let outcome = run_herdr_activity(env, &activity_deps(), &start_tick);
            Outcome {
                code: outcome.code,
                stderr: outcome.stderr,
            }
        }
        Native::HerdrStartup => {
            let outcome = run_sidebar_startup(env);
            Outcome {
                code: outcome.code,
                stderr: outcome.stderr,
            }
        }
        Native::ActivityTick(options) => {
            let deps = TickDeps {
                activity: activity_deps(),
                plan: &TranscriptPlanReader,
                send_update: &run_progress_update,
            };
            let outcome = run_activity_tick_main(options.as_deref(), env, &deps);
            Outcome {
                code: outcome.code,
                stderr: outcome.stderr,
            }
        }
        _ => return None,
    };
    let _ = err.write_all(outcome.stderr.as_bytes());
    Some(outcome.code)
}

fn activity_deps() -> ActivityDeps<'static> {
    ActivityDeps {
        fetch: &HttpFetch,
        clock: &SystemClock,
        run: &run_program,
    }
}

/// `waycar notify`: the push flow and the Live Activity flow, independent
/// deliveries. A failure of either is `waycar: <flow>: <message>` and exit 1.
fn notify(pane_id: &str, status: &str, ctx: &Ctx) -> Outcome {
    notify_with(
        pane_id,
        status,
        &ctx.env,
        ctx.home.as_path(),
        &run_push,
        &run_activity,
    )
}

/// One delivery flow of `notify`: `(pane id, status, env, home)`.
type Flow<'a> = &'a (dyn Fn(&str, &str, &Env, &Path) -> FlowOutcome + Sync);

/// [`notify`] with its two flows given, which run side by side.
fn notify_with(
    pane_id: &str,
    status: &str,
    env: &Env,
    home: &Path,
    push: Flow<'_>,
    activity: Flow<'_>,
) -> Outcome {
    let (push, activity) = thread::scope(|scope| {
        let push = scope.spawn(|| push(pane_id, status, env, home));
        let activity = scope.spawn(|| activity(pane_id, status, env, home));
        // The release profile aborts on a panic, so a flow never "fails" by
        // panicking; a test build re-raises it.
        (
            push.join().unwrap_or_else(|p| std::panic::resume_unwind(p)),
            activity
                .join()
                .unwrap_or_else(|p| std::panic::resume_unwind(p)),
        )
    });
    let mut stderr = push.stderr;
    stderr.push_str(&activity.stderr);
    let mut code = EXIT_OK;
    for (flow, result) in [("notify", push.result), ("activity", activity.result)] {
        if let Err(error) = result {
            stderr.push_str(&format!("waycar: {flow}: {error}\n"));
            code = EXIT_FAILURE;
        }
    }
    Outcome { code, stderr }
}

struct FlowOutcome {
    result: Result<()>,
    stderr: String,
}

fn run_push(pane_id: &str, status: &str, env: &Env, home: &Path) -> FlowOutcome {
    let mut stderr = String::new();
    let result = push_with(pane_id, status, env, home, &Deps::system(), &mut stderr);
    FlowOutcome { result, stderr }
}

/// The push flow for `pane_id`, by its namespace.
pub(crate) fn push_with(
    pane_id: &str,
    status: &str,
    env: &Env,
    home: &Path,
    deps: &Deps<'_>,
    stderr: &mut String,
) -> Result<()> {
    if pane_id.starts_with("codex:") {
        crate::codex_hook::run_notify(pane_id, status, env, home, deps, stderr)
    } else if crate::opencode_hook::is_session_pane_id(pane_id) {
        crate::opencode_hook::run_notify(pane_id, status, env, home, deps, stderr)
    } else if crate::zellij::PaneId::parse(pane_id).is_some() {
        crate::zellij_notify::run_notify(pane_id, status, env, home, deps, stderr)
    } else if crate::core::is_core_pane_id(pane_id) {
        run_core_notify(pane_id, status, env, home, deps, stderr)
    } else {
        run_tmux_notify(pane_id, status, env, home, deps, stderr)
    }
}

/// The Live Activity flow for `pane_id`: a core terminal's (`hc:<address>`)
/// or a tmux pane's.
fn run_activity(pane_id: &str, status: &str, env: &Env, home: &Path) -> FlowOutcome {
    // Shared-server sessions (Codex daemon threads, OpenCode 2) have no
    // terminal inventory for Live Activities.
    if pane_id.starts_with("codex:") || crate::opencode_hook::is_session_pane_id(pane_id) {
        return FlowOutcome {
            result: Ok(()),
            stderr: String::new(),
        };
    }
    let deps = activity_deps();
    if crate::zellij::PaneId::parse(pane_id).is_some() {
        return FlowOutcome {
            result: crate::activity_hook::run_zellij_activity(
                pane_id,
                status,
                env,
                home,
                &deps,
                &start_tick,
            ),
            stderr: String::new(),
        };
    }
    activity_by_backend(
        pane_id,
        status,
        env,
        home,
        &|pane_id, status, env, home| {
            run_tmux_activity(pane_id, status, env, home, &deps, &start_tick)
        },
        &|pane_id, status, env, home| {
            run_core_activity(pane_id, status, env, home, &deps, &start_tick)
        },
    )
}

/// One backend's Live Activity run: `(pane id, status, env, home)`.
type ActivityRun<'a> = &'a dyn Fn(&str, &str, &Env, &Path) -> Result<()>;

/// [`run_activity`] with each backend's run given: a core pane id goes to
/// `core`, any other (a tmux pane id, or one that is none, which tmux's run
/// rejects as before) to `tmux`.
fn activity_by_backend(
    pane_id: &str,
    status: &str,
    env: &Env,
    home: &Path,
    tmux: ActivityRun<'_>,
    core: ActivityRun<'_>,
) -> FlowOutcome {
    let run = if is_core_pane_id(pane_id) { core } else { tmux };
    FlowOutcome {
        result: run(pane_id, status, env, home),
        stderr: String::new(),
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use crate::error::CliError;

    use super::*;

    type Calls = Mutex<Vec<(String, String, String, String, String)>>;

    /// A flow that records what it was given (flow name, pane, status, env
    /// `A`, home) and answers `result`.
    fn recording<'a>(
        name: &'a str,
        calls: &'a Calls,
        result: impl Fn() -> Result<()> + Sync + 'a,
    ) -> impl Fn(&str, &str, &Env, &Path) -> FlowOutcome + Sync + 'a {
        move |pane_id, status, env, home| {
            calls.lock().unwrap().push((
                name.to_string(),
                pane_id.to_string(),
                status.to_string(),
                env.get("A").unwrap_or("").to_string(),
                home.display().to_string(),
            ));
            FlowOutcome {
                result: result(),
                stderr: String::new(),
            }
        }
    }

    // waycar-cli.test.js: notify: "<status> runs the notify flow and updates the Live Activity"
    #[test]
    fn every_status_runs_both_flows_with_the_same_arguments() {
        for status in ["working", "idle", "blocked", "done", "release"] {
            let calls = Calls::default();
            let push = recording("notify", &calls, || Ok(()));
            let activity = recording("activity", &calls, || Ok(()));
            let outcome = notify_with(
                "tmux:%3",
                status,
                &Env::from_pairs([("A", "1")]),
                Path::new("/h"),
                &push,
                &activity,
            );
            assert_eq!(outcome, Outcome::ok());
            drop((push, activity));
            let mut calls = calls.into_inner().unwrap();
            calls.sort();
            let want = |flow: &str| {
                (
                    flow.to_string(),
                    "tmux:%3".to_string(),
                    status.to_string(),
                    "1".to_string(),
                    "/h".to_string(),
                )
            };
            assert_eq!(calls, [want("activity"), want("notify")], "{status}");
        }
    }

    // waycar-cli.test.js: notify: "one delivery failing still runs the other and exits 1"
    #[test]
    fn one_delivery_failing_still_runs_the_other_and_exits_1() {
        let calls = Calls::default();
        let push = recording("notify", &calls, || Err(CliError::failure("relay 500")));
        let activity = recording("activity", &calls, || Ok(()));
        let outcome = notify_with(
            "tmux:%3",
            "done",
            &Env::default(),
            Path::new("/h"),
            &push,
            &activity,
        );
        assert_eq!(
            outcome,
            Outcome {
                code: EXIT_FAILURE,
                stderr: "waycar: notify: relay 500\n".to_string()
            }
        );
        assert_eq!(calls.lock().unwrap().len(), 2);
    }

    #[test]
    fn both_failing_names_each_flow_in_order() {
        let calls = Calls::default();
        let push = recording("notify", &calls, || Err(CliError::failure("a")));
        let activity = recording("activity", &calls, || Err(CliError::failure("b")));
        let outcome = notify_with(
            "tmux:%3",
            "blocked",
            &Env::default(),
            Path::new("/h"),
            &push,
            &activity,
        );
        assert_eq!(outcome.stderr, "waycar: notify: a\nwaycar: activity: b\n");
        assert_eq!(outcome.code, EXIT_FAILURE);
    }

    #[test]
    fn a_core_terminal_runs_both_flows_with_its_own_id() {
        let calls = Calls::default();
        let push = recording("notify", &calls, || Ok(()));
        let activity = recording("activity", &calls, || Ok(()));
        let outcome = notify_with(
            "hc:t7",
            "done",
            &Env::default(),
            Path::new("/h"),
            &push,
            &activity,
        );
        assert_eq!(outcome, Outcome::ok());
        drop((push, activity));
        let mut panes: Vec<String> = calls
            .into_inner()
            .unwrap()
            .into_iter()
            .map(|call| call.1)
            .collect();
        panes.sort();
        assert_eq!(panes, ["hc:t7", "hc:t7"]);
    }

    // Both run the argument checks before touching anything, so their
    // messages say which trigger took the pane.
    #[test]
    fn the_push_flow_takes_a_core_id_for_core_and_anything_else_for_tmux() {
        let env = Env::default();
        let home = Path::new("/nonexistent-home");
        let core = run_push("hc:t7", "sleeping", &env, home);
        assert_eq!(
            core.result.unwrap_err().message(),
            "unknown status: sleeping"
        );
        let tmux = run_push("tmux:%3", "sleeping", &env, home);
        assert_eq!(
            tmux.result.unwrap_err().message(),
            "unknown status: sleeping"
        );
        // An id core would not take falls to tmux, which refuses it.
        let neither = run_push("hc:", "done", &env, home);
        assert_eq!(
            neither.result.unwrap_err().message(),
            "not a tmux pane id: hc:"
        );
        // A core id never reaches tmux's pane check.
        let core_bad_status = run_push("hc:box/t3", "bogus", &env, home);
        assert_eq!(
            core_bad_status.result.unwrap_err().message(),
            "unknown status: bogus"
        );
    }

    /// `activity_by_backend` over backends that record which one ran (with
    /// the pane id and status it was given) and answer `result`.
    fn dispatch(
        pane_id: &str,
        result: fn() -> Result<()>,
    ) -> (FlowOutcome, Vec<(&'static str, String, String)>) {
        let calls: Mutex<Vec<(&'static str, String, String)>> = Mutex::default();
        let backend = |name: &'static str| {
            let calls = &calls;
            move |pane_id: &str, status: &str, _: &Env, _: &Path| {
                calls
                    .lock()
                    .unwrap()
                    .push((name, pane_id.to_string(), status.to_string()));
                result()
            }
        };
        let outcome = activity_by_backend(
            pane_id,
            "done",
            &Env::default(),
            Path::new("/h"),
            &backend("tmux"),
            &backend("core"),
        );
        (outcome, calls.into_inner().unwrap())
    }

    #[test]
    fn a_core_pane_id_runs_the_core_activity_and_any_other_id_the_tmux_one() {
        for (pane, backend) in [
            ("hc:t7", "core"),
            ("hc:box/t3", "core"),
            ("tmux:%3", "tmux"),
            ("w1:p1", "tmux"),
            ("hc:", "tmux"),
            ("hc:-x", "tmux"),
        ] {
            let (outcome, calls) = dispatch(pane, || Ok(()));
            assert!(outcome.result.is_ok(), "{pane}");
            assert_eq!(
                calls,
                [(backend, pane.to_string(), "done".to_string())],
                "{pane}"
            );
        }
    }

    #[test]
    fn the_activity_flow_reports_what_the_backend_answered_and_prints_nothing() {
        let (outcome, _) = dispatch("hc:t7", || Err(CliError::failure("relay 500")));
        assert_eq!(outcome.result.unwrap_err().message(), "relay 500");
        assert_eq!(outcome.stderr, "");
    }
}
