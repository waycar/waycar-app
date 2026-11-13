//! The herdr-core command runner: the `herdr-core` CLI (`hc`), the terminal
//! records it prints, and the ids Waycar gives them (docs/design/herdr-core-backend.md).
//!
//! A herdr-core terminal is named by its `address` (`t7`, `box/t3`), opaque
//! and never reused; the id the app sees is `hc:<address>`. Core's own
//! variables are `HC_*`: a program in a terminal gets `HC_TERMINAL_ID` (the
//! address), `HC_TERMINAL_SOCKET` and `HC_SESSION`, and `hc` itself reads
//! `HC_SOCKET` to pick the core to talk to.
//!
//! Every `hc` subcommand except `--version` starts a core when none listens,
//! with the caller's environment frozen into it. Nothing here runs a command
//! that is not needed, and [`core_command`] asks only for `--version`.
//!
//! Status is the agent's own OSC 7501 report as core stores it: `status` is
//! null and `reported` false until the first report; `idle`, `working`,
//! `done`, `blocked` and `error` are the words Waycar knows (open vocabulary).

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde_json::Value;

use crate::env::Env;
use crate::error::{CliError, Result};
use crate::exec::{RunResult, find_on_path};
use crate::paths::posix_join;
use crate::tmux::Runner;

const PREFIX: &str = "hc:";
/// The names core's installer and package managers give the binary.
const BINARY_NAMES: [&str; 2] = ["herdr-core", "hc"];
/// `hc <digits>` is what `--version` prints; another program called `hc`
/// (herbstclient) prints something else and must not pass.
const VERSION_WORD: &str = "hc";

/// Whether `id` is an app-side core terminal id (`hc:t7`, `hc:box/t3`): the
/// address is what `herdr-core` accepts as a terminal, never an option.
pub fn is_core_pane_id(id: &str) -> bool {
    id.strip_prefix(PREFIX).is_some_and(is_address)
}

fn is_address(address: &str) -> bool {
    !address.is_empty()
        && !address.starts_with(['-', '/'])
        && !address.ends_with('/')
        && !address.contains("//")
        && address
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'/'))
        && address.split('/').all(|part| part != "." && part != "..")
}

/// The raw core address for an `hc:`-prefixed id; raw addresses pass through.
pub fn to_core_address(id: &str) -> &str {
    id.strip_prefix(PREFIX).unwrap_or(id)
}

/// The app-side id for a raw core address (`t7` becomes `hc:t7`); prefixed ids
/// pass through.
pub fn to_waycar_pane_id(raw: &str) -> String {
    if raw.starts_with(PREFIX) {
        raw.to_string()
    } else {
        format!("{PREFIX}{raw}")
    }
}

/// The address a program in a core terminal runs in, from `HC_TERMINAL_ID`,
/// when it is a plausible address.
pub fn terminal_address(env: &Env) -> Option<&str> {
    env.non_empty("HC_TERMINAL_ID").filter(|id| is_address(id))
}

/// Whether `env` names a core session other than the default one. Waycar
/// handles the default session only: addresses repeat across sessions, so
/// `hc:t1` would name two terminals.
pub fn is_named_session(env: &Env) -> bool {
    env.non_empty("HC_SESSION")
        .is_some_and(|session| session != "default")
}

/// `hc 0.1.14` gives `0.1.14`; anything else is not herdr-core.
pub fn parse_version(stdout: &str) -> Option<String> {
    let line = stdout.lines().next()?.trim();
    let rest = line.strip_prefix(VERSION_WORD)?;
    let version = rest.trim_start();
    // Whitespace is required between the words.
    if version.len() == rest.len() || !version.starts_with(|c: char| c.is_ascii_digit()) {
        return None;
    }
    Some(version.split_whitespace().next()?.to_string())
}

/// The herdr-core CLI and the environment to run it with.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CoreCommand {
    /// Absolute path of the binary that answered `--version`.
    pub bin: String,
    pub version: String,
    pub env: Env,
}

/// The directories to look in besides `PATH`: where core's installer and the
/// Herdr app put it (`~/.local/bin` is usually missing from the PATH of a
/// hook or an SSH exec). The machine-wide ones (Homebrew, `/usr/local/bin`,
/// NixOS) are left out of unit tests, which must never find or run a real core.
fn search_dirs(env: &Env, home: &Path) -> Vec<PathBuf> {
    let data_home = env
        .absolute("XDG_DATA_HOME")
        .unwrap_or_else(|| posix_join(&[home, Path::new(".local/share")]));
    let mise_data = env
        .absolute("MISE_DATA_DIR")
        .unwrap_or_else(|| posix_join(&[&data_home, Path::new("mise")]));
    let mut dirs: Vec<PathBuf> = env
        .non_empty("PATH")
        .map(|path| {
            path.split(':')
                .filter(|dir| !dir.is_empty())
                .map(PathBuf::from)
                .collect()
        })
        .unwrap_or_default();
    let system = |dir: &str| (!cfg!(test)).then(|| PathBuf::from(dir));
    dirs.push(posix_join(&[home, Path::new(".local/bin")]));
    dirs.extend(system("/opt/homebrew/bin"));
    dirs.extend(system("/usr/local/bin"));
    dirs.push(posix_join(&[&mise_data, Path::new("shims")]));
    dirs.push(posix_join(&[home, Path::new(".nix-profile/bin")]));
    dirs.extend(system("/run/current-system/sw/bin"));
    dirs.push(posix_join(&[home, Path::new(".cargo/bin")]));
    dirs
}

/// Finds herdr-core: `herdr-core`, then `hc`, in `PATH` and the usual install
/// directories, accepting only a binary whose `--version` prints `hc <digits>`.
/// `None` when there is none. `HC_SOCKET` is taken from `HC_TERMINAL_SOCKET`
/// when the caller is a core terminal, so a hook talks to the core that runs
/// it and never starts another.
pub fn core_command(env: &Env, home: &Path, run: Runner<'_>) -> Option<CoreCommand> {
    let mut child_env = env.clone();
    if env.non_empty("HC_SOCKET").is_none()
        && let Some(socket) = env.non_empty("HC_TERMINAL_SOCKET")
    {
        child_env.set("HC_SOCKET", socket);
    }
    let dirs = search_dirs(env, home);
    for name in BINARY_NAMES {
        for dir in &dirs {
            let Some(bin) = find_on_path(&dir.join(name).to_string_lossy(), env) else {
                continue;
            };
            let bin = bin.to_string_lossy().into_owned();
            let result = run(&bin, &["--version"], &child_env);
            if result.code != 0 {
                continue;
            }
            if let Some(version) = parse_version(&result.stdout) {
                return Some(CoreCommand {
                    bin,
                    version,
                    env: child_env,
                });
            }
        }
    }
    None
}

/// Where the core of this environment's session listens, as core itself works
/// it out (docs/research/herdr-core/attach-facts.md): `HC_SOCKET`, else the
/// socket of the terminal the caller runs in, else
/// `$XDG_RUNTIME_DIR/herdr-core/<session>.sock`, else the same under
/// `/run/user/<uid>` when that directory exists, else the state directory's
/// `herdr-core/<session>/<session>.sock`. A `socket =` setting in core's own
/// config is not read: such a core is simply not found.
pub fn socket_path(env: &Env, home: &Path) -> PathBuf {
    // SAFETY: getuid has no preconditions and cannot fail.
    let uid = unsafe { libc::getuid() };
    let logind = PathBuf::from(format!("/run/user/{uid}/herdr-core"));
    socket_path_with(env, home, logind.is_dir().then_some(logind))
}

/// [`socket_path`] given the logind directory when it exists.
fn socket_path_with(env: &Env, home: &Path, logind: Option<PathBuf>) -> PathBuf {
    if let Some(socket) = env
        .non_empty("HC_SOCKET")
        .or_else(|| env.non_empty("HC_TERMINAL_SOCKET"))
    {
        return PathBuf::from(socket);
    }
    let session = env.non_empty("HC_SESSION").unwrap_or("default").trim();
    let session = if session.is_empty() {
        "default"
    } else {
        session
    };
    let file = format!("{session}.sock");
    if let Some(runtime) = env.absolute("XDG_RUNTIME_DIR") {
        return posix_join(&[&runtime, Path::new("herdr-core"), Path::new(&file)]);
    }
    if let Some(logind) = logind {
        return logind.join(&file);
    }
    let state = env
        .absolute("XDG_STATE_HOME")
        .unwrap_or_else(|| posix_join(&[home, Path::new(".local/state")]));
    posix_join(&[
        &state,
        Path::new("herdr-core"),
        Path::new(session),
        Path::new(&file),
    ])
}

/// [`core_command`] for a core that is already running, else `None`: every
/// `hc` subcommand but `--version` starts a core when none listens, with the
/// caller's environment frozen into it, so a hook or a herdr or tmux event on
/// a Host that merely has core installed must not ask. A plain connect to the
/// socket (and no named session: Waycar handles the default one) says whether
/// anything listens, and starts nothing.
pub fn running_core(env: &Env, home: &Path, run: Runner<'_>) -> Option<CoreCommand> {
    if is_named_session(env) {
        return None;
    }
    let socket = socket_path(env, home);
    std::os::unix::net::UnixStream::connect(&socket).ok()?;
    // The probe and the commands must agree on the core: pin the socket that
    // answered instead of letting `hc` derive its own from a different env.
    let mut core = core_command(env, home, run)?;
    core.env.set("HC_SOCKET", socket.to_string_lossy());
    Some(core)
}

/// What the app and the hooks call a status: `error` shows as `blocked`
/// (design section 0.6); `None` for a word Waycar does not know.
pub fn map_status(state: &str) -> Option<&'static str> {
    match state {
        "idle" => Some("idle"),
        "working" => Some("working"),
        "done" => Some("done"),
        "blocked" | "error" => Some("blocked"),
        _ => None,
    }
}

/// A terminal's OSC 7501 report (`status` in `get`).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CoreStatus {
    pub state: String,
    pub kind: Option<String>,
    pub app: Option<String>,
    pub msg: Option<String>,
    pub title: Option<String>,
}

/// The program in a terminal's foreground.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CoreForeground {
    pub pid: Option<u64>,
    pub name: Option<String>,
    pub argv: Vec<String>,
    pub cwd: Option<String>,
}

/// A terminal as `herdr-core get <t> --json` prints it, the fields Waycar
/// reads. Unknown fields are ignored: the API only grows.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CoreTerminal {
    pub address: String,
    /// `live` or `finished` (open vocabulary).
    pub state: String,
    pub pid: Option<u64>,
    pub reported: bool,
    pub status: Option<CoreStatus>,
    /// The millisecond clock of the last change of the state word.
    pub status_ms: Option<u64>,
    /// How many times the terminal left `working`.
    pub turn: u64,
    pub cwd: Option<String>,
    pub foreground: Option<CoreForeground>,
    pub labels: BTreeMap<String, String>,
    pub name: Option<String>,
    pub title: Option<String>,
}

impl CoreTerminal {
    pub fn is_live(&self) -> bool {
        self.state == "live"
    }

    /// The status word as Waycar uses it (`error` is `blocked`), `None` before
    /// the first report.
    pub fn waycar_status(&self) -> Option<&'static str> {
        map_status(&self.status.as_ref()?.state)
    }

    /// The agent's kind: a hook's own label, else the program's own report.
    pub fn kind(&self) -> Option<&str> {
        self.labels
            .get("waycar.kind")
            .map(String::as_str)
            .or_else(|| self.status.as_ref()?.app.as_deref())
            .filter(|kind| !kind.is_empty())
    }

    /// The working folder: where the foreground program is, else the start folder.
    pub fn folder(&self) -> Option<&str> {
        self.foreground
            .as_ref()
            .and_then(|fg| fg.cwd.as_deref())
            .or(self.cwd.as_deref())
            .filter(|cwd| !cwd.is_empty())
    }

    pub fn pane_id(&self) -> String {
        to_waycar_pane_id(&self.address)
    }
}

fn text(value: &Value, key: &str) -> Option<String> {
    value.get(key)?.as_str().map(str::to_string)
}

/// One record of `get --json` (or an element of `terminal.list`).
pub fn parse_record(record: &Value) -> Option<CoreTerminal> {
    let address = text(record, "address").filter(|a| is_address(a))?;
    let status = record
        .get("status")
        .filter(|status| status.is_object())
        .and_then(|status| {
            Some(CoreStatus {
                state: text(status, "state")?,
                kind: text(status, "kind"),
                app: text(status, "app"),
                msg: text(status, "msg"),
                title: text(status, "title"),
            })
        });
    let foreground = record
        .get("foreground")
        .filter(|fg| fg.is_object())
        .map(|fg| CoreForeground {
            pid: fg.get("pid").and_then(Value::as_u64),
            name: text(fg, "name"),
            argv: fg
                .get("argv")
                .and_then(Value::as_array)
                .map(|argv| {
                    argv.iter()
                        .filter_map(|arg| arg.as_str().map(str::to_string))
                        .collect()
                })
                .unwrap_or_default(),
            cwd: text(fg, "cwd"),
        });
    let labels = record
        .get("labels")
        .and_then(Value::as_object)
        .map(|labels| {
            labels
                .iter()
                .filter_map(|(k, v)| Some((k.clone(), v.as_str()?.to_string())))
                .collect()
        })
        .unwrap_or_default();
    Some(CoreTerminal {
        address,
        state: text(record, "state").unwrap_or_default(),
        pid: record.get("pid").and_then(Value::as_u64),
        reported: record
            .get("reported")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        status,
        status_ms: record.get("status_ms").and_then(Value::as_u64),
        turn: record.get("turn").and_then(Value::as_u64).unwrap_or(0),
        cwd: text(record, "cwd"),
        foreground,
        labels,
        name: text(record, "name").filter(|name| !name.is_empty()),
        title: text(record, "title").filter(|title| !title.is_empty()),
    })
}

/// One element of `ls --json`: a compact projection of a live terminal.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CoreListing {
    pub address: String,
    /// The program's own app name, else its foreground command.
    pub agent: Option<String>,
    pub cwd: Option<String>,
    pub name: Option<String>,
    pub state: String,
    /// The status word, `None` until the terminal reported.
    pub status: Option<String>,
    pub turn: u64,
}

impl CoreListing {
    pub fn pane_id(&self) -> String {
        to_waycar_pane_id(&self.address)
    }

    pub fn waycar_status(&self) -> Option<&'static str> {
        map_status(self.status.as_deref()?)
    }
}

fn run_core(core: &CoreCommand, run: Runner<'_>, args: &[&str]) -> RunResult {
    run(&core.bin, args, &core.env)
}

fn failure(args: &[&str], result: &RunResult) -> CliError {
    let detail = if result.stderr.trim().is_empty() {
        result.stdout.trim()
    } else {
        result.stderr.trim()
    };
    let sub = args.first().copied().unwrap_or("");
    let suffix = if detail.is_empty() {
        String::new()
    } else {
        format!(": {detail}")
    };
    CliError::failure(format!(
        "herdr-core {sub} failed (exit {}){suffix}",
        result.code
    ))
}

/// Whether a failed call said the terminal does not exist: core prints
/// `{"error":{"kind":"not_found",...}}` and exits 3. `hc 0.1.14` prints it on
/// stderr (stdout stays empty); stdout is read too, for a core that does not.
fn is_not_found(result: &RunResult) -> bool {
    [&result.stdout, &result.stderr].into_iter().any(|stream| {
        serde_json::from_str::<Value>(stream.trim())
            .ok()
            .and_then(|reply| {
                reply
                    .get("error")?
                    .get("kind")?
                    .as_str()
                    .map(|kind| kind == "not_found")
            })
            .unwrap_or(false)
    })
}

/// `herdr-core get <address> --json`: `Ok(None)` when core has no such
/// terminal; `Err` when it cannot tell, so callers fail closed.
pub fn get(core: &CoreCommand, run: Runner<'_>, address: &str) -> Result<Option<CoreTerminal>> {
    let args = ["get", address, "--json"];
    let result = run_core(core, run, &args);
    if result.code != 0 {
        if is_not_found(&result) {
            return Ok(None);
        }
        return Err(failure(&args, &result));
    }
    let record: Value = serde_json::from_str(result.stdout.trim())
        .map_err(|error| CliError::failure(format!("herdr-core get: unreadable reply: {error}")))?;
    parse_record(&record)
        .map(Some)
        .ok_or_else(|| CliError::failure("herdr-core get: no terminal address in the reply"))
}

/// `herdr-core ls --json`: the live terminals.
pub fn list(core: &CoreCommand, run: Runner<'_>) -> Result<Vec<CoreListing>> {
    let args = ["ls", "--json"];
    let result = run_core(core, run, &args);
    if result.code != 0 {
        return Err(failure(&args, &result));
    }
    let reply: Value = serde_json::from_str(result.stdout.trim())
        .map_err(|error| CliError::failure(format!("herdr-core ls: unreadable reply: {error}")))?;
    let terminals = reply
        .get("terminals")
        .and_then(Value::as_array)
        .ok_or_else(|| CliError::failure("herdr-core ls: no terminals in the reply"))?;
    Ok(terminals.iter().filter_map(parse_listing).collect())
}

fn parse_listing(entry: &Value) -> Option<CoreListing> {
    let address = text(entry, "address").filter(|a| is_address(a))?;
    Some(CoreListing {
        address,
        agent: text(entry, "agent").filter(|agent| !agent.is_empty()),
        cwd: text(entry, "cwd"),
        name: text(entry, "name").filter(|name| !name.is_empty()),
        state: text(entry, "state").unwrap_or_default(),
        status: text(entry, "status"),
        turn: entry.get("turn").and_then(Value::as_u64).unwrap_or(0),
    })
}

/// `herdr-core read <address>`: the terminal's screen and history as text.
pub fn read(core: &CoreCommand, run: Runner<'_>, address: &str) -> Result<String> {
    let args = ["read", address];
    let result = run_core(core, run, &args);
    if result.code != 0 {
        return Err(failure(&args, &result));
    }
    Ok(result.stdout)
}

/// `herdr-core read <address> --lines N`: the screen plus up to `lines` lines
/// of history above it, as text (what an Agent Summary reads).
pub fn read_recent(
    core: &CoreCommand,
    run: Runner<'_>,
    address: &str,
    lines: usize,
) -> Result<String> {
    let lines = lines.to_string();
    let args = ["read", address, "--lines", lines.as_str()];
    let result = run_core(core, run, &args);
    if result.code != 0 {
        return Err(failure(&args, &result));
    }
    Ok(result.stdout)
}

/// `herdr-core label <address> k=v...`: sets labels; an empty value removes
/// one (core's own rule). A key with `=` in it is refused here, since core
/// would split it.
pub fn label(
    core: &CoreCommand,
    run: Runner<'_>,
    address: &str,
    pairs: &[(&str, &str)],
) -> Result<()> {
    if let Some((key, _)) = pairs
        .iter()
        .find(|(key, _)| key.is_empty() || key.contains('='))
    {
        return Err(CliError::failure(format!("bad label key: {key:?}")));
    }
    let assignments: Vec<String> = pairs.iter().map(|(k, v)| format!("{k}={v}")).collect();
    let mut args = vec!["label", address];
    args.extend(assignments.iter().map(String::as_str));
    let result = run_core(core, run, &args);
    if result.code != 0 {
        return Err(failure(&args, &result));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::cell::RefCell;

    fn ok(stdout: &str) -> RunResult {
        RunResult {
            stdout: stdout.to_string(),
            stderr: String::new(),
            code: 0,
        }
    }

    fn core() -> CoreCommand {
        CoreCommand {
            bin: "/x/herdr-core".to_string(),
            version: "0.1.14".to_string(),
            env: Env::default(),
        }
    }

    #[test]
    fn pane_ids_are_prefixed_addresses() {
        for good in ["hc:t1", "hc:t1b", "hc:box/t3", "hc:a_b-c.d"] {
            assert!(is_core_pane_id(good), "{good}");
        }
        for bad in [
            "",
            "hc:",
            "t1",
            "tmux:%3",
            "hc:-x",
            "hc:/t1",
            "hc:t1/",
            "hc:a//b",
            "hc:..",
            "hc:a/../b",
            "hc:t 1",
            "hc:t1;rm",
            "HC:t1",
        ] {
            assert!(!is_core_pane_id(bad), "{bad}");
        }
        assert_eq!(to_core_address("hc:t7"), "t7");
        assert_eq!(to_core_address("t7"), "t7");
        assert_eq!(to_waycar_pane_id("t7"), "hc:t7");
        assert_eq!(to_waycar_pane_id("hc:t7"), "hc:t7");
    }

    #[test]
    fn terminal_identity_comes_from_the_environment() {
        let env = Env::from_pairs([("HC_TERMINAL_ID", "t4"), ("HC_SESSION", "default")]);
        assert_eq!(terminal_address(&env), Some("t4"));
        assert!(!is_named_session(&env));
        assert!(!is_named_session(&Env::default()));
        let env = Env::from_pairs([("HC_TERMINAL_ID", "--help"), ("HC_SESSION", "lab")]);
        assert_eq!(terminal_address(&env), None);
        assert!(is_named_session(&env));
        assert_eq!(
            terminal_address(&Env::from_pairs([("HC_TERMINAL_ID", "")])),
            None
        );
    }

    #[test]
    fn version_accepts_only_hc_digits() {
        assert_eq!(parse_version("hc 0.1.14\n").as_deref(), Some("0.1.14"));
        assert_eq!(
            parse_version("hc 0.1.14-rc1 extra").as_deref(),
            Some("0.1.14-rc1")
        );
        for bad in [
            "",
            "hc: herbstclient 0.9",
            "hc",
            "hc x",
            "hc0.1",
            "herdr 0.9.5",
            "\nhc 1",
        ] {
            assert_eq!(parse_version(bad), None, "{bad:?}");
        }
    }

    #[test]
    fn status_words_map_error_to_blocked() {
        assert_eq!(map_status("idle"), Some("idle"));
        assert_eq!(map_status("working"), Some("working"));
        assert_eq!(map_status("done"), Some("done"));
        assert_eq!(map_status("blocked"), Some("blocked"));
        assert_eq!(map_status("error"), Some("blocked"));
        assert_eq!(map_status("starting"), None);
        assert_eq!(map_status(""), None);
    }

    fn sample() -> Value {
        json!({
            "address": "t1",
            "state": "live",
            "pid": 100,
            "reported": true,
            "status": {"state": "blocked", "kind": "permission", "app": "claude", "msg": "Allow?"},
            "status_ms": 1793317800513u64,
            "turn": 3,
            "cwd": "/start",
            "foreground": {"pid": 101, "name": "node", "argv": ["node", "x"], "cwd": "/work"},
            "labels": {"waycar.session": "abc", "n": 5},
            "name": "alpha",
            "title": "",
            "future_field": [1, 2]
        })
    }

    #[test]
    fn record_reads_what_waycar_needs() {
        let t = parse_record(&sample()).unwrap();
        assert_eq!(t.address, "t1");
        assert!(t.is_live());
        assert_eq!(t.pid, Some(100));
        assert!(t.reported);
        assert_eq!(t.status_ms, Some(1793317800513));
        assert_eq!(t.turn, 3);
        assert_eq!(t.waycar_status(), Some("blocked"));
        assert_eq!(t.kind(), Some("claude"));
        assert_eq!(t.folder(), Some("/work"));
        assert_eq!(t.name.as_deref(), Some("alpha"));
        assert_eq!(t.title, None);
        assert_eq!(
            t.labels.get("waycar.session").map(String::as_str),
            Some("abc")
        );
        // A non-string label is dropped, not an error.
        assert!(!t.labels.contains_key("n"));
        assert_eq!(t.pane_id(), "hc:t1");
        assert_eq!(t.foreground.unwrap().argv, ["node", "x"]);
    }

    #[test]
    fn unreported_and_finished_records() {
        let t = parse_record(&json!({
            "address": "t3", "state": "finished", "status": null, "reported": false,
            "status_ms": null, "turn": 0, "cwd": "/c", "labels": {}
        }))
        .unwrap();
        assert!(!t.is_live());
        assert_eq!(t.waycar_status(), None);
        assert_eq!(t.kind(), None);
        assert_eq!(t.folder(), Some("/c"));
        // Error reports show as blocked; unknown words as nothing.
        let mut v = sample();
        v["status"]["state"] = json!("error");
        assert_eq!(parse_record(&v).unwrap().waycar_status(), Some("blocked"));
        v["status"]["state"] = json!("thinking");
        assert_eq!(parse_record(&v).unwrap().waycar_status(), None);
        // The kind label wins over the program's own app name.
        let mut v = sample();
        v["labels"]["waycar.kind"] = json!("codex");
        assert_eq!(parse_record(&v).unwrap().kind(), Some("codex"));
        // A record without a usable address is no terminal.
        assert!(parse_record(&json!({"address": "", "state": "live"})).is_none());
        assert!(parse_record(&json!({"address": "-x"})).is_none());
        assert!(parse_record(&json!({"state": "live"})).is_none());
    }

    #[test]
    fn get_distinguishes_missing_from_unknown_failure() {
        let calls = RefCell::new(Vec::new());
        let answer = |reply: RunResult| {
            let calls = &calls;
            move |cmd: &str, args: &[&str], _env: &Env| {
                calls.borrow_mut().push((cmd.to_string(), args.join(" ")));
                reply.clone()
            }
        };
        let found = get(&core(), &answer(ok(&sample().to_string())), "t1")
            .unwrap()
            .unwrap();
        assert_eq!(found.address, "t1");
        assert_eq!(
            calls.borrow()[0],
            ("/x/herdr-core".to_string(), "get t1 --json".to_string())
        );

        let missing = RunResult {
            stdout: r#"{"error":{"hint":"see `hc ls --all`","kind":"not_found","message":"no terminal \"t9\""}}"#
                .to_string(),
            stderr: String::new(),
            code: 3,
        };
        assert_eq!(get(&core(), &answer(missing), "t9").unwrap(), None);
        // hc 0.1.14 prints the same error on stderr and leaves stdout empty.
        let missing_on_stderr = RunResult {
            stdout: String::new(),
            stderr: r#"{"error":{"hint":"see `hc ls --all`","kind":"not_found","message":"no terminal \"t9\""}}"#
                .to_string(),
            code: 3,
        };
        assert_eq!(
            get(&core(), &answer(missing_on_stderr), "t9").unwrap(),
            None
        );
        // Another kind of error is not a missing terminal, on either stream.
        let other = RunResult {
            stdout: String::new(),
            stderr: r#"{"error":{"kind":"usage","message":"bad"}}"#.to_string(),
            code: 2,
        };
        assert!(get(&core(), &answer(other), "t9").is_err());

        let broken = RunResult {
            stdout: String::new(),
            stderr: "hc: boom".to_string(),
            code: 1,
        };
        let err = get(&core(), &answer(broken), "t1").unwrap_err();
        assert_eq!(err.message(), "herdr-core get failed (exit 1): hc: boom");
        // A core that answers nonsense fails closed too.
        assert!(get(&core(), &answer(ok("not json")), "t1").is_err());
        assert!(get(&core(), &answer(ok("{}")), "t1").is_err());
    }

    #[test]
    fn list_reads_live_terminals() {
        let reply = json!({"hidden_finished": 2, "terminals": [
            {"address": "t1", "agent": "alpha", "cwd": "/a", "name": "alpha",
             "state": "live", "status": "idle", "turn": 1},
            {"address": "t2", "agent": "sh", "cwd": "/b", "name": "", "state": "live", "turn": 0},
            {"address": "bad addr"}
        ]});
        let run = |_: &str, args: &[&str], _: &Env| {
            assert_eq!(args, ["ls", "--json"]);
            ok(&reply.to_string())
        };
        let listing = list(&core(), &run).unwrap();
        assert_eq!(listing.len(), 2);
        assert_eq!(listing[0].pane_id(), "hc:t1");
        assert_eq!(listing[0].waycar_status(), Some("idle"));
        assert_eq!(listing[0].turn, 1);
        assert_eq!(listing[1].status, None);
        assert_eq!(listing[1].name, None);
        let failed = |_: &str, _: &[&str], _: &Env| RunResult {
            stdout: String::new(),
            stderr: String::new(),
            code: 1,
        };
        assert!(list(&core(), &failed).is_err());
    }

    #[test]
    fn label_passes_assignments_and_refuses_bad_keys() {
        let seen = RefCell::new(Vec::new());
        let run = |_: &str, args: &[&str], _: &Env| {
            *seen.borrow_mut() = args.iter().map(|a| a.to_string()).collect::<Vec<_>>();
            ok("")
        };
        label(
            &core(),
            &run,
            "t1",
            &[("waycar.session", "abc"), ("waycar.transcript", "")],
        )
        .unwrap();
        assert_eq!(
            *seen.borrow(),
            ["label", "t1", "waycar.session=abc", "waycar.transcript="]
        );
        assert!(label(&core(), &run, "t1", &[("a=b", "c")]).is_err());
        assert!(label(&core(), &run, "t1", &[("", "c")]).is_err());
    }

    #[test]
    fn read_returns_the_screen() {
        let run = |_: &str, args: &[&str], _: &Env| {
            assert_eq!(args, ["read", "t1"]);
            ok("screen\n")
        };
        assert_eq!(read(&core(), &run, "t1").unwrap(), "screen\n");
    }

    #[test]
    fn read_recent_asks_for_history() {
        let run = |_: &str, args: &[&str], _: &Env| {
            assert_eq!(args, ["read", "t1", "--lines", "60"]);
            ok("screen\n")
        };
        assert_eq!(read_recent(&core(), &run, "t1", 60).unwrap(), "screen\n");
        let failed = |_: &str, _: &[&str], _: &Env| RunResult {
            stdout: String::new(),
            stderr: "boom".to_string(),
            code: 3,
        };
        assert!(read_recent(&core(), &failed, "t1", 60).is_err());
    }
}

#[cfg(test)]
mod running_tests {
    use std::cell::RefCell;
    use std::os::unix::net::UnixListener;

    use super::*;
    use crate::test_support::{TempDir, write_stub};

    fn path(text: &str) -> PathBuf {
        PathBuf::from(text)
    }

    #[test]
    fn the_socket_is_found_the_way_core_finds_it() {
        let home = Path::new("/home/u");
        let logind = Some(path("/run/user/1000/herdr-core"));
        let at = |pairs: &[(&str, &str)], logind: Option<PathBuf>| {
            socket_path_with(&Env::from_pairs(pairs.iter().copied()), home, logind)
        };
        assert_eq!(
            at(
                &[
                    ("HC_SOCKET", "/s/a.sock"),
                    ("HC_TERMINAL_SOCKET", "/s/b.sock"),
                    ("XDG_RUNTIME_DIR", "/run/x")
                ],
                logind.clone()
            ),
            path("/s/a.sock")
        );
        assert_eq!(
            at(
                &[("HC_TERMINAL_SOCKET", "/s/b.sock"), ("HC_SESSION", "lab")],
                None
            ),
            path("/s/b.sock")
        );
        assert_eq!(
            at(&[("XDG_RUNTIME_DIR", "/run/x")], logind.clone()),
            path("/run/x/herdr-core/default.sock")
        );
        assert_eq!(
            at(
                &[("XDG_RUNTIME_DIR", "/run/x"), ("HC_SESSION", " lab ")],
                None
            ),
            path("/run/x/herdr-core/lab.sock")
        );
        // A relative runtime directory is ignored, as the XDG rule says.
        assert_eq!(
            at(&[("XDG_RUNTIME_DIR", "run/x")], logind),
            path("/run/user/1000/herdr-core/default.sock")
        );
        assert_eq!(
            at(&[], None),
            path("/home/u/.local/state/herdr-core/default/default.sock")
        );
        assert_eq!(
            at(&[("XDG_STATE_HOME", "/st"), ("HC_SESSION", "")], None),
            path("/st/herdr-core/default/default.sock")
        );
    }

    struct Host {
        dir: TempDir,
        env: Env,
    }

    /// A throwaway Host: `herdr-core` installed in `~/.local/bin`, a socket
    /// named by `HC_SOCKET`.
    fn host(installed: bool) -> Host {
        let dir = TempDir::new("core-running");
        if installed {
            let bin = dir.path().join(".local/bin");
            std::fs::create_dir_all(&bin).unwrap();
            write_stub(&bin.join("herdr-core"), "exit 0");
        }
        let env = Env::from_pairs([("HC_SOCKET", dir.path().join("core.sock").to_str().unwrap())]);
        Host { dir, env }
    }

    impl Host {
        /// A runner that answers `--version` for the Host's own binary only,
        /// and logs what it was asked (a binary of the machine the test runs on
        /// is never answered for).
        fn answering<'a>(
            &'a self,
            seen: &'a RefCell<Vec<Vec<String>>>,
        ) -> impl Fn(&str, &[&str], &Env) -> RunResult + 'a {
            move |cmd, args, _| {
                if !Path::new(cmd).starts_with(self.dir.path()) {
                    return RunResult {
                        stdout: String::new(),
                        stderr: String::new(),
                        code: 127,
                    };
                }
                seen.borrow_mut()
                    .push(args.iter().map(|arg| arg.to_string()).collect());
                RunResult {
                    stdout: "hc 0.1.14\n".into(),
                    stderr: String::new(),
                    code: 0,
                }
            }
        }
    }

    #[test]
    fn a_listening_core_gives_its_command_after_a_version_check_and_nothing_else_is_run() {
        let host = host(true);
        let _listener = UnixListener::bind(host.dir.path().join("core.sock")).unwrap();
        let seen = RefCell::new(Vec::new());

        let core = running_core(&host.env, host.dir.path(), &host.answering(&seen)).unwrap();

        assert_eq!(core.version, "0.1.14");
        assert!(core.bin.ends_with(".local/bin/herdr-core"));
        assert_eq!(*seen.borrow(), [vec!["--version".to_string()]]);
    }

    #[test]
    fn no_listener_a_stale_socket_a_named_session_or_no_binary_runs_nothing() {
        let seen = RefCell::new(Vec::new());

        // Nothing listens and no file exists.
        let host_a = host(true);
        assert!(running_core(&host_a.env, host_a.dir.path(), &host_a.answering(&seen)).is_none());

        // A socket file a dead core left behind.
        let host_b = host(true);
        drop(UnixListener::bind(host_b.dir.path().join("core.sock")).unwrap());
        assert!(running_core(&host_b.env, host_b.dir.path(), &host_b.answering(&seen)).is_none());

        // A listening core of a named session is not the default one.
        let host_c = host(true);
        let _listener_c = UnixListener::bind(host_c.dir.path().join("core.sock")).unwrap();
        let mut env = host_c.env.clone();
        env.set("HC_SESSION", "lab");
        assert!(running_core(&env, host_c.dir.path(), &host_c.answering(&seen)).is_none());

        // A listening core and no binary to ask.
        let host_d = host(false);
        let _listener_d = UnixListener::bind(host_d.dir.path().join("core.sock")).unwrap();
        assert!(running_core(&host_d.env, host_d.dir.path(), &host_d.answering(&seen)).is_none());

        assert!(seen.borrow().is_empty());
    }
}
