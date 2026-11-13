//! The other Agents a no-session launch match could mistake for this one
//! (launch-rivals.js; opencode, kilo and hermes: `findExportedByLaunch`).
//!
//! Those kinds create a session at the first prompt, any time after the
//! launch, so two Agents of one kind in one directory can each look like the
//! other's launch. Chat Markers record every Chat Mode launch and the panes
//! that still run say which of them are alive and which already name their
//! session (`@waycar_session` on tmux, `waycar.session` on herdr-core, herdr's
//! `agent_session`).

use std::collections::{HashMap, HashSet};
use std::path::Path;

use serde_json::Value;

use crate::chat::marker::{herdr_sessions_dir, list_markers, named_herdr_sessions_exist};
use crate::chat::shared::{expand_home, path_forms};
use crate::chat::transcript::{RivalQuery, Rivals};
use crate::core::{CoreTerminal, is_core_pane_id, running_core};
use crate::env::Env;
use crate::exec::RunResult;
use crate::herdr::herdr_command;
use crate::jsx;
use crate::notification_config::read_notification_config;
use crate::tmux::to_waycar_pane_id;

const TMUX_PREFIX: &str = "tmux:";

/// `run(cmd, args, env)`: [`crate::exec::run_program`] outside tests.
pub type Run<'a> = &'a dyn Fn(&str, &[&str], &Env) -> RunResult;

/// For a launch of `query.kind` in `query.cwd` at `query.launched` (epoch
/// ms): the session ids other Agents of the kind already name (their
/// marker's pinned id, or their live pane's session), and the launch times of
/// the other live Agents of the kind in the same directory that name none.
/// The launch's own marker, recorded at the same millisecond, is not a rival.
/// A pane whose backend cannot be listed (tmux not running, herdr
/// unreachable, named herdr sessions sharing the Host) counts as live and
/// naming none.
pub fn launch_rivals(
    config_dir: &str,
    query: &RivalQuery,
    env: &Env,
    home: &str,
    run: Run<'_>,
) -> Rivals {
    let mut claimed = HashSet::new();
    let mut open: Vec<(String, f64)> = Vec::new();
    let wanted = path_forms(&expand_home(&query.cwd, home));
    for marker in list_markers(config_dir) {
        if marker.kind != query.kind {
            continue;
        }
        if let Some(session) = &marker.session
            && session.kind == "id"
        {
            claimed.insert(session.value.clone());
            continue;
        }
        let at = marker.launched_at.as_deref().and_then(jsx::date_parse);
        let Some(at) = at else { continue };
        let Some(cwd) = &marker.cwd else { continue };
        if at == query.launched {
            continue;
        }
        let forms = path_forms(&expand_home(cwd, home));
        if forms.iter().any(|form| wanted.contains(form)) {
            open.push((marker.pane_id, at));
        }
    }
    let mut launches = Vec::new();
    if open.is_empty() {
        return Rivals { claimed, launches };
    }

    let on_tmux = |pane_id: &str| pane_id.starts_with(TMUX_PREFIX);
    let on_core = |pane_id: &str| !on_tmux(pane_id) && is_core_pane_id(pane_id);
    let on_herdr = |pane_id: &str| !on_tmux(pane_id) && !on_core(pane_id);
    let tmux = open
        .iter()
        .any(|(id, _)| on_tmux(id))
        .then(|| tmux_pane_sessions(env, run))
        .flatten();
    // A Host that switched core off never has it asked.
    let core_on = read_notification_config(config_dir).is_ok_and(|config| config.core_enabled);
    let core = open
        .iter()
        .any(|(id, _)| on_core(id) && core_on)
        .then(|| {
            let ids: Vec<&str> = open
                .iter()
                .map(|(id, _)| id.as_str())
                .filter(|id| on_core(id))
                .collect();
            core_pane_sessions(env, home, run, &ids)
        })
        .flatten();
    let herdr = open
        .iter()
        .any(|(id, _)| on_herdr(id))
        .then(|| herdr_pane_sessions(env, home, run))
        .flatten();
    for (pane_id, at) in open {
        let panes = if on_tmux(&pane_id) {
            &tmux
        } else if on_core(&pane_id) {
            &core
        } else {
            &herdr
        };
        if let Some(panes) = panes {
            let Some(session) = panes.get(&pane_id) else {
                continue;
            };
            if let Some(session) = session {
                claimed.insert(session.clone());
                continue;
            }
        }
        launches.push(at);
    }
    Rivals { claimed, launches }
}

type PaneSessions = HashMap<String, Option<String>>;

/// `tmux:%N` to the pane's `@waycar_session` (None when unset) for every tmux
/// pane, or None when tmux cannot list them.
fn tmux_pane_sessions(env: &Env, run: Run<'_>) -> Option<PaneSessions> {
    let result = run(
        "tmux",
        &[
            "-u",
            "list-panes",
            "-a",
            "-F",
            "#{pane_id}\u{241f}#{@waycar_session}",
        ],
        env,
    );
    if result.code != 0 {
        return None;
    }
    let mut panes = HashMap::new();
    for line in result.stdout.split('\n') {
        let mut parts = line.split('\u{241f}');
        let id = parts.next().unwrap_or("");
        let session = parts.next().unwrap_or("");
        let digits = id.strip_prefix('%').unwrap_or("");
        if !digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit()) {
            panes.insert(
                to_waycar_pane_id(id),
                (!session.is_empty()).then(|| session.to_string()),
            );
        }
    }
    Some(panes)
}

/// `hc:<address>` to the terminal's `waycar.session` label (None when unset)
/// for each of the live terminals among `open`, or None when no core runs or
/// it cannot say. Asking never starts a core ([`running_core`]); the labels
/// are in the full record only, so only the panes a marker still names are
/// fetched.
fn core_pane_sessions(env: &Env, home: &str, run: Run<'_>, open: &[&str]) -> Option<PaneSessions> {
    let core = running_core(env, Path::new(home), run)?;
    let listings = crate::core::list(&core, run).ok()?;
    let mut panes = HashMap::new();
    for listing in listings.iter().filter(|listing| listing.state == "live") {
        let pane_id = listing.pane_id();
        if !open.contains(&pane_id.as_str()) {
            continue;
        }
        let Some(record) = crate::core::get(&core, run, &listing.address)
            .ok()?
            .filter(CoreTerminal::is_live)
        else {
            continue;
        };
        let session = record
            .labels
            .get("waycar.session")
            .filter(|session| !session.is_empty())
            .cloned();
        panes.insert(pane_id, session);
    }
    Some(panes)
}

/// herdr pane id to its Agent's `agent_session` value (None for none) for
/// every herdr Agent, or None when herdr cannot say.
fn herdr_pane_sessions(env: &Env, home: &str, run: Run<'_>) -> Option<PaneSessions> {
    if named_herdr_sessions_exist(&herdr_sessions_dir(env, home)) {
        return None;
    }
    let herdr = herdr_command(env, Path::new(home));
    let result = run(&herdr.bin, &["agent", "list"], &herdr.env);
    if result.code != 0 {
        return None;
    }
    let document = jsx::parse_json(&result.stdout)?;
    let agents = jsx::field(jsx::field(&document, "result"), "agents").as_array()?;
    let mut panes = HashMap::new();
    for agent in agents {
        let Some(pane_id) = jsx::field(agent, "pane_id").as_str() else {
            continue;
        };
        let session = match jsx::field(jsx::field(agent, "agent_session"), "value") {
            Value::String(value) if !value.is_empty() => Some(value.clone()),
            _ => None,
        };
        panes.insert(pane_id.to_string(), session);
    }
    Some(panes)
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::fs;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU32, Ordering};

    use serde_json::json;

    use super::*;
    use crate::atomic::pane_file_name;

    const LAUNCHED: f64 = 1_791_799_200_000.0; // 2026-10-12T10:00:00.000Z

    struct Setup {
        dir: PathBuf,
        config_dir: String,
        work: String,
        env: Env,
    }

    impl Setup {
        fn new() -> Self {
            static COUNTER: AtomicU32 = AtomicU32::new(0);
            let dir = std::env::temp_dir().join(format!(
                "wc-rivals-{}-{}",
                std::process::id(),
                COUNTER.fetch_add(1, Ordering::SeqCst)
            ));
            let work = dir.join("work");
            fs::create_dir_all(&work).unwrap();
            let text = |path: PathBuf| path.to_string_lossy().into_owned();
            Self {
                config_dir: text(dir.join("config")),
                work: text(work),
                env: Env::from_pairs([
                    ("HOME", text(dir.clone())),
                    ("XDG_CONFIG_HOME", text(dir.join("xdg"))),
                ]),
                dir,
            }
        }

        fn marker(
            &self,
            pane_id: &str,
            kind: &str,
            cwd: &str,
            at: f64,
            session: Option<(&str, &str)>,
        ) {
            let file = PathBuf::from(&self.config_dir)
                .join("chat")
                .join(pane_file_name(pane_id));
            fs::create_dir_all(file.parent().unwrap()).unwrap();
            let record = json!({
                "v": 1, "pane_id": pane_id, "terminal_id": null, "kind": kind, "cwd": cwd,
                "session": session.map(|(kind, value)| json!({"kind": kind, "value": value})),
                "launched_at": jsx::to_iso_string(at).unwrap(), "prompt": null, "chat_mode": true,
            });
            fs::write(file, jsx::stringify(&record)).unwrap();
        }

        /// `rivals(run)` with `run` answering tmux's list with `tmux` (lines) and
        /// herdr's with `herdr` (agents), or failing for None. Returns the
        /// sorted claimed ids, the sorted launches and the programs run.
        fn rivals(
            &self,
            tmux: Option<&[&str]>,
            herdr: Option<Value>,
        ) -> (Vec<String>, Vec<f64>, Vec<String>) {
            let calls = RefCell::new(Vec::new());
            let run = |cmd: &str, _args: &[&str], _env: &Env| {
                calls.borrow_mut().push(cmd.to_string());
                if cmd == "tmux" {
                    match tmux {
                        None => RunResult {
                            code: 1,
                            stdout: String::new(),
                            stderr: "no server".into(),
                        },
                        Some(lines) => RunResult {
                            code: 0,
                            stdout: lines.join("\n"),
                            stderr: String::new(),
                        },
                    }
                } else {
                    match &herdr {
                        None => RunResult {
                            code: 1,
                            stdout: String::new(),
                            stderr: String::new(),
                        },
                        Some(agents) => RunResult {
                            code: 0,
                            stdout: jsx::stringify(&json!({"result": {"agents": agents}})),
                            stderr: String::new(),
                        },
                    }
                }
            };
            let query = RivalQuery {
                kind: "opencode".into(),
                cwd: self.work.clone(),
                launched: LAUNCHED,
            };
            let rivals = launch_rivals(
                &self.config_dir,
                &query,
                &self.env,
                &self.dir.to_string_lossy(),
                &run,
            );
            let mut claimed: Vec<String> = rivals.claimed.into_iter().collect();
            claimed.sort();
            let mut launches = rivals.launches;
            launches.sort_by(f64::total_cmp);
            (claimed, launches, calls.into_inner())
        }
    }

    impl Drop for Setup {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.dir);
        }
    }

    #[test]
    fn the_launchs_own_marker_other_kinds_and_other_directories_are_no_rivals_and_nothing_is_listed()
     {
        let setup = Setup::new();
        let elsewhere = setup.dir.join("elsewhere").to_string_lossy().into_owned();
        setup.marker("w1-p1", "opencode", &setup.work, LAUNCHED, None);
        setup.marker("w1-p2", "kilo", &setup.work, LAUNCHED + 1_000.0, None);
        setup.marker("w1-p3", "opencode", &elsewhere, LAUNCHED + 1_000.0, None);

        let (claimed, launches, calls) = setup.rivals(None, None);

        assert!(claimed.is_empty());
        assert!(launches.is_empty());
        assert!(calls.is_empty());
    }

    #[test]
    fn a_pinned_session_is_claimed_whatever_its_pane_live_unpinned_panes_are_rivals_gone_ones_are_not()
     {
        let setup = Setup::new();
        let work = setup.work.clone();
        setup.marker("w1-p1", "opencode", &work, LAUNCHED, None);
        setup.marker(
            "w1-p2",
            "opencode",
            &work,
            LAUNCHED - 60_000.0,
            Some(("id", "ses_pinned")),
        );
        setup.marker("w1-p3", "opencode", &work, LAUNCHED + 1_000.0, None);
        setup.marker("w1-p4", "opencode", &work, LAUNCHED + 2_000.0, None);
        setup.marker("w1-p5", "opencode", &work, LAUNCHED + 3_000.0, None);
        setup.marker("tmux:%7", "opencode", &work, LAUNCHED + 4_000.0, None);
        setup.marker("tmux:%8", "opencode", &work, LAUNCHED + 5_000.0, None);

        let (claimed, launches, _) = setup.rivals(
            Some(&["%7\u{241f}", "%8\u{241f}ses_tmux"]),
            Some(json!([
                {"pane_id": "w1-p3", "agent_session": null},
                {"pane_id": "w1-p4", "agent_session": {"kind": "id", "value": "ses_herdr"}},
            ])),
        );

        assert_eq!(claimed, ["ses_herdr", "ses_pinned", "ses_tmux"]);
        assert_eq!(launches, [LAUNCHED + 1_000.0, LAUNCHED + 4_000.0]);
    }

    #[test]
    fn a_backend_that_cannot_list_its_panes_keeps_its_markers_as_live_rivals() {
        let setup = Setup::new();
        let work = setup.work.clone();
        setup.marker("w1-p3", "opencode", &work, LAUNCHED + 1_000.0, None);
        setup.marker("tmux:%7", "opencode", &work, LAUNCHED + 4_000.0, None);

        let (_, launches, _) = setup.rivals(None, None);

        assert_eq!(launches, [LAUNCHED + 1_000.0, LAUNCHED + 4_000.0]);
    }

    /// `rivals` for a Host whose core (a listening socket and an installed
    /// binary the runner answers for) lists `terminals` (`ls`'s lines) and
    /// describes each by its record in `records`; when `listening` is false
    /// the socket is a stale file. Returns what `rivals` does and what core was
    /// asked, `--version` aside.
    fn core_rivals(
        setup: &Setup,
        listening: bool,
        terminals: Value,
        records: Value,
    ) -> (Vec<String>, Vec<f64>, Vec<String>) {
        let bin_dir = setup.dir.join(".local/bin");
        fs::create_dir_all(&bin_dir).unwrap();
        crate::test_support::write_stub(&bin_dir.join("herdr-core"), "exit 0");
        let socket = setup.dir.join("core.sock");
        let listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();
        let mut env = setup.env.clone();
        env.set("HC_SOCKET", socket.to_str().unwrap());
        if !listening {
            drop(listener);
        }
        let asked = RefCell::new(Vec::new());
        let run = |cmd: &str, args: &[&str], _env: &Env| {
            let program = Path::new(cmd).file_name().unwrap().to_string_lossy();
            let reply = |stdout: String| RunResult {
                code: 0,
                stdout,
                stderr: String::new(),
            };
            match (program.as_ref(), args) {
                ("herdr-core", ["--version"]) => reply("hc 0.1.14\n".into()),
                ("herdr-core", ["ls", "--json"]) => {
                    asked.borrow_mut().push("ls".to_string());
                    reply(jsx::stringify(&json!({ "terminals": terminals })))
                }
                ("herdr-core", ["get", address, "--json"]) => {
                    asked.borrow_mut().push(format!("get {address}"));
                    reply(jsx::stringify(&records[*address]))
                }
                _ => RunResult {
                    code: 1,
                    stdout: String::new(),
                    stderr: "unexpected".into(),
                },
            }
        };
        let query = RivalQuery {
            kind: "opencode".into(),
            cwd: setup.work.clone(),
            launched: LAUNCHED,
        };
        let rivals = launch_rivals(
            &setup.config_dir,
            &query,
            &env,
            &setup.dir.to_string_lossy(),
            &run,
        );
        let mut claimed: Vec<String> = rivals.claimed.into_iter().collect();
        claimed.sort();
        let mut launches = rivals.launches;
        launches.sort_by(f64::total_cmp);
        (claimed, launches, asked.into_inner())
    }

    fn live_line(address: &str) -> Value {
        json!({ "address": address, "state": "live", "status": "idle", "turn": 0 })
    }

    fn record(address: &str, state: &str, labels: Value) -> Value {
        json!({ "address": address, "state": state, "labels": labels })
    }

    #[test]
    fn core_panes_are_asked_of_core_not_herdr_live_unpinned_ones_are_rivals_named_ones_claim_gone_ones_are_not()
     {
        let setup = Setup::new();
        let work = setup.work.clone();
        setup.marker("hc:t1", "opencode", &work, LAUNCHED + 1_000.0, None);
        setup.marker("hc:t2", "opencode", &work, LAUNCHED + 2_000.0, None);
        setup.marker("hc:t3", "opencode", &work, LAUNCHED + 3_000.0, None);
        setup.marker("hc:t4", "opencode", &work, LAUNCHED + 4_000.0, None);
        setup.marker("hc:t5", "opencode", &work, LAUNCHED + 5_000.0, None);

        let (claimed, launches, asked) = core_rivals(
            &setup,
            true,
            // t3 is gone from the listing; t4 finished between `ls` and `get`.
            json!([
                live_line("t1"),
                live_line("t2"),
                live_line("t4"),
                live_line("t6")
            ]),
            json!({
                "t1": record("t1", "live", json!({})),
                "t2": record("t2", "live", json!({ "waycar.session": "ses_core" })),
                "t4": record("t4", "finished", json!({ "waycar.session": "ses_dead" })),
            }),
        );

        assert_eq!(claimed, ["ses_core"]);
        assert_eq!(launches, [LAUNCHED + 1_000.0]);
        // Only the terminals a marker names are described.
        assert_eq!(asked, ["ls", "get t1", "get t2", "get t4"]);
    }

    #[test]
    fn a_core_that_does_not_run_or_cannot_describe_a_pane_counts_its_markers_as_live_rivals() {
        let setup = Setup::new();
        let work = setup.work.clone();
        setup.marker("hc:t1", "opencode", &work, LAUNCHED + 1_000.0, None);
        setup.marker("hc:t2", "opencode", &work, LAUNCHED + 2_000.0, None);

        let (claimed, launches, asked) = core_rivals(&setup, false, json!([]), json!({}));
        assert!(claimed.is_empty());
        assert_eq!(launches, [LAUNCHED + 1_000.0, LAUNCHED + 2_000.0]);
        assert!(asked.is_empty(), "a stopped core is never started");
    }

    #[test]
    fn core_is_not_asked_when_no_marker_names_a_core_pane_and_herdr_ones_stay_herdrs() {
        let setup = Setup::new();
        let work = setup.work.clone();
        setup.marker("w1-p3", "opencode", &work, LAUNCHED + 1_000.0, None);
        setup.marker("tmux:%7", "opencode", &work, LAUNCHED + 2_000.0, None);

        let (_, launches, asked) = core_rivals(&setup, true, json!([]), json!({}));
        assert_eq!(launches, [LAUNCHED + 1_000.0, LAUNCHED + 2_000.0]);
        assert!(asked.is_empty());

        // A core marker next to a herdr marker: each asks its own backend.
        setup.marker("hc:t1", "opencode", &work, LAUNCHED + 3_000.0, None);
        let (_, _, calls) = setup.rivals(Some(&["%7\u{241f}"]), Some(json!([])));
        assert!(calls.iter().any(|cmd| cmd == "tmux"));
        assert!(
            calls
                .iter()
                .any(|cmd| !cmd.ends_with("herdr-core") && cmd != "tmux")
        );
    }
}
