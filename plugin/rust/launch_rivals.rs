//! The other Agents a no-session launch match could mistake for this one
//! (opencode, kilo and hermes: chat-transcript.js `findExportedByLaunch`)
//! (launch-rivals.js).
//!
//! Those kinds create a session at the first prompt, any time after the
//! launch, so two Agents of one kind in one directory can each look like the
//! other's launch. Chat Markers record every Chat Mode launch (kind, cwd,
//! launch time, a pinned session) and the panes that still run say which of
//! them are alive and which already name their session (`@waycar_session` on
//! tmux, herdr's `agent_session`).

use std::collections::HashMap;
use std::path::Path;

use crate::chat_marker::{herdr_sessions_dir, list_markers, named_herdr_sessions_exist};
use crate::chat_shared::{expand_home, path_forms};
use crate::env::Env;
use crate::exec::RunResult;
use crate::herdr::herdr_command;
use crate::js_date;
use crate::js_json::{Json, parse};
use crate::tmux::to_waycar_pane_id;

const TMUX_PREFIX: &str = "tmux:";

/// What a launch of `kind` in `cwd` at `launched` has to reckon with.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Rivals {
    /// The session ids other Agents of the kind already name (their marker's
    /// pinned id, or their live pane's session).
    pub claimed: Vec<String>,
    /// The launch times (epoch ms) of the other live Agents of the kind in
    /// the same directory that name none.
    pub launches: Vec<i64>,
}

pub struct Options<'a> {
    /// The plugin config dir holding `chat/`.
    pub config_dir: &'a Path,
    pub kind: &'a str,
    pub cwd: &'a str,
    /// Epoch ms of the launch.
    pub launched: i64,
    pub env: &'a Env,
    pub home: &'a Path,
}

/// Runs a program: `run(cmd, args, env)`, like the JS `run` option.
pub type Run<'a> = &'a dyn Fn(&str, &[&str], &Env) -> RunResult;

struct Rival {
    pane_id: String,
    at: i64,
}

/// Panes by id, each with the session its Agent names (`None` for none).
type PaneSessions = HashMap<String, Option<String>>;

/// `{claimed, launches}` for a launch. The launch's own marker, recorded at
/// the same millisecond, is not a rival. A pane whose backend cannot be
/// listed (tmux not running, herdr unreachable, named herdr sessions sharing
/// the Host and its pane ids) counts as live and naming none.
pub fn launch_rivals(options: &Options, run: Run) -> Rivals {
    let mut rivals = Rivals::default();
    let mut open: Vec<Rival> = Vec::new();
    let wanted = path_forms(&expand_home(options.cwd, options.home));
    for marker in list_markers(options.config_dir) {
        if marker.kind != options.kind {
            continue;
        }
        if let Some(session) = marker
            .session
            .as_ref()
            .filter(|session| session.kind == "id")
        {
            claim(&mut rivals.claimed, &session.value);
            continue;
        }
        let at = marker.launched_at.as_deref().and_then(js_date::parse);
        let (Some(at), Some(cwd)) = (at, marker.cwd.as_deref()) else {
            continue;
        };
        if at == options.launched {
            continue;
        }
        let forms = path_forms(&expand_home(cwd, options.home));
        if forms.iter().any(|form| wanted.contains(form)) {
            open.push(Rival {
                pane_id: marker.pane_id,
                at,
            });
        }
    }
    if open.is_empty() {
        return rivals;
    }

    let on_tmux = |rival: &Rival| rival.pane_id.starts_with(TMUX_PREFIX);
    let tmux = open
        .iter()
        .any(on_tmux)
        .then(|| tmux_pane_sessions(options.env, run))
        .flatten();
    let herdr = open
        .iter()
        .any(|rival| !on_tmux(rival))
        .then(|| herdr_pane_sessions(options.env, options.home, run))
        .flatten();
    for rival in &open {
        let panes = if on_tmux(rival) { &tmux } else { &herdr };
        if let Some(panes) = panes {
            let Some(session) = panes.get(&rival.pane_id) else {
                continue;
            };
            if let Some(session) = session {
                claim(&mut rivals.claimed, session);
                continue;
            }
        }
        rivals.launches.push(rival.at);
    }
    rivals
}

fn claim(claimed: &mut Vec<String>, session: &str) {
    if !claimed.iter().any(|known| known == session) {
        claimed.push(session.to_string());
    }
}

/// `tmux:%N` to the pane's `@waycar_session` (`None` when unset) for every
/// tmux pane, or `None` when tmux cannot list them.
fn tmux_pane_sessions(env: &Env, run: Run) -> Option<PaneSessions> {
    let list_format = "#{pane_id}\u{241f}#{@waycar_session}";
    let result = run("tmux", &["-u", "list-panes", "-a", "-F", list_format], env);
    if result.code != 0 {
        return None;
    }
    let mut panes = PaneSessions::new();
    for line in result.stdout.split('\n') {
        let mut fields = line.split('\u{241f}');
        let id = fields.next().unwrap_or_default();
        let session = fields.next().unwrap_or_default();
        // `/^%\d+$/`
        let is_pane = id
            .strip_prefix('%')
            .is_some_and(|digits| !digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit()));
        if is_pane {
            panes.insert(
                to_waycar_pane_id(id),
                (!session.is_empty()).then(|| session.to_string()),
            );
        }
    }
    Some(panes)
}

/// herdr pane id to its Agent's `agent_session` value (`None` for none) for
/// every herdr Agent, or `None` when herdr cannot say.
fn herdr_pane_sessions(env: &Env, home: &Path, run: Run) -> Option<PaneSessions> {
    if named_herdr_sessions_exist(&herdr_sessions_dir(env)) {
        return None;
    }
    let herdr = herdr_command(env, home);
    let result = run(&herdr.bin, &["agent", "list"], &herdr.env);
    if result.code != 0 {
        return None;
    }
    let parsed = parse(&result.stdout).ok()?;
    let agents = parsed.get("result")?.get("agents")?.as_array()?;
    let mut panes = PaneSessions::new();
    for agent in agents {
        let Some(pane_id) = agent.get("pane_id").and_then(Json::as_str) else {
            continue;
        };
        let value = agent
            .get("agent_session")
            .and_then(|session| session.get("value"))
            .and_then(Json::as_str)
            .filter(|value| !value.is_empty());
        panes.insert(pane_id.to_string(), value.map(str::to_string));
    }
    Some(panes)
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::fs;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicUsize, Ordering};

    use serde_json::json;

    use crate::atomic::pane_file_name;

    use super::*;

    const LAUNCHED: i64 = 1_791_799_200_000; // 2026-10-12T10:00:00.000Z

    static NEXT: AtomicUsize = AtomicUsize::new(0);

    struct Host {
        dir: PathBuf,
        config_dir: PathBuf,
        work: PathBuf,
    }

    impl Host {
        fn new() -> Self {
            let dir = std::env::temp_dir().join(format!(
                "launch-rivals-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            let work = dir.join("work");
            fs::create_dir_all(&work).unwrap();
            Self {
                config_dir: dir.join("config"),
                dir,
                work,
            }
        }

        fn marker(
            &self,
            pane_id: &str,
            kind: &str,
            cwd: &Path,
            at: i64,
            session: serde_json::Value,
        ) {
            let file = self.config_dir.join("chat").join(pane_file_name(pane_id));
            fs::create_dir_all(file.parent().unwrap()).unwrap();
            let launched_at = crate::js_date::iso_string(at).unwrap();
            let record = json!({
                "v": 1, "pane_id": pane_id, "terminal_id": null, "kind": kind,
                "cwd": cwd, "session": session, "launched_at": launched_at,
                "prompt": null, "chat_mode": true,
            });
            fs::write(file, record.to_string()).unwrap();
        }

        fn open(&self, pane_id: &str, at: i64) {
            self.marker(pane_id, "opencode", &self.work, at, json!(null));
        }

        fn rivals(&self, run: Run) -> Rivals {
            let env = Env::from_pairs([
                ("HOME".to_string(), self.dir.to_string_lossy().into_owned()),
                (
                    "XDG_CONFIG_HOME".to_string(),
                    self.dir.join("xdg").to_string_lossy().into_owned(),
                ),
            ]);
            launch_rivals(
                &Options {
                    config_dir: &self.config_dir,
                    kind: "opencode",
                    cwd: &self.work.to_string_lossy(),
                    launched: LAUNCHED,
                    env: &env,
                    home: &self.dir,
                },
                run,
            )
        }
    }

    impl Drop for Host {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.dir);
        }
    }

    /// A `run` answering tmux's list with `tmux` (lines) and herdr's with
    /// `herdr` (agents), or failing for `None`; the commands it was asked for.
    struct Panes {
        tmux: Option<Vec<&'static str>>,
        herdr: Option<serde_json::Value>,
        calls: RefCell<Vec<String>>,
    }

    impl Panes {
        fn new(tmux: Option<Vec<&'static str>>, herdr: Option<serde_json::Value>) -> Self {
            Self {
                tmux,
                herdr,
                calls: RefCell::new(Vec::new()),
            }
        }

        fn run(&self, cmd: &str, _args: &[&str], _env: &Env) -> RunResult {
            self.calls.borrow_mut().push(cmd.to_string());
            let answer = |code, stdout: String, stderr: &str| RunResult {
                code,
                stdout,
                stderr: stderr.into(),
            };
            if cmd == "tmux" {
                return match &self.tmux {
                    None => answer(1, String::new(), "no server"),
                    Some(lines) => answer(0, lines.join("\n"), ""),
                };
            }
            match &self.herdr {
                None => answer(1, String::new(), ""),
                Some(agents) => answer(0, json!({"result": {"agents": agents}}).to_string(), ""),
            }
        }
    }

    fn sorted(mut values: Vec<i64>) -> Vec<i64> {
        values.sort_unstable();
        values
    }

    #[test]
    fn the_launchs_own_marker_other_kinds_and_other_directories_are_no_rivals_and_nothing_is_listed()
     {
        let host = Host::new();
        host.open("w1-p1", LAUNCHED);
        host.marker("w1-p2", "kilo", &host.work, LAUNCHED + 1_000, json!(null));
        host.marker(
            "w1-p3",
            "opencode",
            &host.dir.join("elsewhere"),
            LAUNCHED + 1_000,
            json!(null),
        );
        let panes = Panes::new(None, None);
        let found = host.rivals(&|cmd, args, env| panes.run(cmd, args, env));
        assert_eq!(found, Rivals::default());
        assert!(panes.calls.borrow().is_empty());
    }

    #[test]
    fn a_pinned_session_is_claimed_whatever_its_pane_live_unpinned_panes_are_rivals_gone_ones_are_not()
     {
        let host = Host::new();
        host.open("w1-p1", LAUNCHED);
        host.marker(
            "w1-p2",
            "opencode",
            &host.work,
            LAUNCHED - 60_000,
            json!({"kind": "id", "value": "ses_pinned"}),
        );
        host.open("w1-p3", LAUNCHED + 1_000);
        host.open("w1-p4", LAUNCHED + 2_000);
        host.open("w1-p5", LAUNCHED + 3_000);
        host.open("tmux:%7", LAUNCHED + 4_000);
        host.open("tmux:%8", LAUNCHED + 5_000);
        let panes = Panes::new(
            Some(vec!["%7\u{241f}", "%8\u{241f}ses_tmux"]),
            Some(json!([
                {"pane_id": "w1-p3", "agent_session": null},
                {"pane_id": "w1-p4", "agent_session": {"kind": "id", "value": "ses_herdr"}},
            ])),
        );
        let found = host.rivals(&|cmd, args, env| panes.run(cmd, args, env));
        let mut claimed = found.claimed.clone();
        claimed.sort();
        assert_eq!(claimed, ["ses_herdr", "ses_pinned", "ses_tmux"]);
        assert_eq!(sorted(found.launches), [LAUNCHED + 1_000, LAUNCHED + 4_000]);
    }

    #[test]
    fn a_backend_that_cannot_list_its_panes_keeps_its_markers_as_live_rivals() {
        let host = Host::new();
        host.open("w1-p3", LAUNCHED + 1_000);
        host.open("tmux:%7", LAUNCHED + 4_000);
        let panes = Panes::new(None, None);
        let found = host.rivals(&|cmd, args, env| panes.run(cmd, args, env));
        assert_eq!(sorted(found.launches), [LAUNCHED + 1_000, LAUNCHED + 4_000]);
    }

    #[test]
    fn named_herdr_sessions_make_every_herdr_marker_a_live_rival_without_asking_herdr() {
        let host = Host::new();
        host.open("w1-p3", LAUNCHED + 1_000);
        fs::create_dir_all(host.dir.join("xdg/herdr/sessions/work")).unwrap();
        fs::write(host.dir.join("xdg/herdr/sessions/work/herdr.sock"), "").unwrap();
        let panes = Panes::new(None, Some(json!([])));
        let found = host.rivals(&|cmd, args, env| panes.run(cmd, args, env));
        assert_eq!(found.launches, [LAUNCHED + 1_000]);
        assert!(panes.calls.borrow().is_empty());
    }
}
