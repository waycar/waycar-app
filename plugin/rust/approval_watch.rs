//! Host-side Blocked for tmux Agents whose Status Hooks report no approval
//! (approval-watch.js).
//!
//! agy and cline fire `PreToolUse` before every tool, auto-allowed or not,
//! just before their approval dialog draws, and then nothing while the dialog
//! shows (agy: nor after a denial or Esc; docs/research/harnesses/agy.md §1,
//! §10, cline.md §1, §10). The app reads such a dialog off the screen
//! (TmuxScreenDetector), but only while it is connected, and that verdict
//! never reaches the Host's notifier, which pushes only for the statuses
//! hooks write to the pane. So the kind's `PreToolUse` hook runs
//! `waycar-hook <agent> watch-approval`, and one watch per pane,
//! `waycar watch-approval --pane tmux:%N --agent <agent>` started detached,
//! reads the pane's visible screen:
//!
//!   1. every [`POLL_MS`] until [`DIALOG_WAIT_MS`] after the latest
//!      `PreToolUse`, while `@waycar_status` is `working` and `@waycar_seq`
//!      unchanged: the kind's dialog on screen -> `blocked` (raising the
//!      seq), notified as a hook's change is;
//!   2. then every [`HELD_POLL_MS`] while `@waycar_seq` is still that write:
//!      the dialog gone (approved, denied or cancelled) -> `working`,
//!      notified, and back to 1 when a `PreToolUse` came since.
//!
//! Any other write (a hook's: a new seq) ends the watch, since the hooks own
//! the status from there, and so does a pane that is gone.
//!
//! One watch per pane. Two pane options, the watch's own (not part of the
//! app's pane-option contract):
//!
//! * [`WATCH_OPTION`] `<pid>-<hex>`, the running watch's token
//! * [`POKE_OPTION`] set by every `PreToolUse` hook
//!
//! The hook sets the poke and reads the token in one tmux call, and starts a
//! watch only when no live process holds the token; a running watch takes a
//! new poke as a new `PreToolUse` (its wait restarts) and clears the token
//! only while the poke is the one it last saw. Both are compare-and-set
//! inside the tmux server (`if-shell -F`, which runs its commands before any
//! other client's), so a poke either reaches the running watch or finds no
//! token and starts one. Status writes are compare-and-set on the seq the
//! watch read, so a hook's write in between always wins.
//!
//! The JS awaited its notifier in the background and again at the end;
//! [`run_watch_approval`] does the same with a thread per notification, and
//! [`watch_approval`] takes a notifier that returns when it is done.

use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use ring::rand::{SecureRandom, SystemRandom};

use crate::approval_watch_machine::{ApprovalWatchMachine, PaneView, WatchEffect, WatchEvent};
use crate::cli::{parse_flags, parse_pane};
use crate::env::Env;
use crate::error::{CliError, Result};
use crate::exec::{RunResult, run_program};
use crate::hook_session::{next_seq, now_ns, process_args};
use crate::jsx;
use crate::state_machine::StateMachine;
use crate::tmux::to_tmux_target;

pub const POLL_MS: u64 = 250;
pub const DIALOG_WAIT_MS: u64 = 5000;
pub const HELD_POLL_MS: u64 = 1000;

const STATUS: &str = "@waycar_status";
const SEQ: &str = "@waycar_seq";
pub const WATCH_OPTION: &str = "@waycar_approval_watch";
pub const POKE_OPTION: &str = "@waycar_approval_poke";
const READ_OPTIONS: [&str; 4] = [STATUS, SEQ, WATCH_OPTION, POKE_OPTION];

/// The kinds with an approval screen, in the order the JS table lists them.
pub const APPROVAL_AGENTS: [&str; 2] = ["agy", "cline"];

/// Separates the option values on [`read_pane`]'s first line; tmux values
/// never hold it. Printable on purpose: tmux 3.4 prints every control
/// character of a `display-message -p` as an octal escape (`\037`), so
/// `\x1f` never arrives.
const UNIT: char = '\u{241f}';

/// Values that can sit inside a tmux format and command unquoted: ours always
/// do (`/^[0-9A-Za-z_-]*$/`).
pub(crate) fn is_plain(value: &str) -> bool {
    value
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

/// The bottom `count` non-empty rows (herdr's `bottom_non_empty_lines`).
fn bottom_non_empty(screen: &str, count: usize) -> Vec<&str> {
    let rows: Vec<&str> = screen
        .split('\n')
        .filter(|line| !line.chars().all(jsx::is_js_space))
        .collect();
    rows[rows.len().saturating_sub(count)..].to_vec()
}

/// agy 1.3.3: a permission or question dialog ends in a key-hint row right
/// above the `esc to cancel` footer, `↑/↓ Navigate · tab Amend · …` or
/// `… · esc Skip` (herdr's agy manifest 2026.10.05.1, rules
/// `permission_prompt` and `question_prompt`; the app's TmuxScreenDetector
/// agy rules).
pub fn agy_screen_shown(screen: &str) -> bool {
    let bottom = bottom_non_empty(screen, 2).join("\n").to_lowercase();
    bottom.contains("navigate") && (bottom.contains("tab amend") || bottom.contains("esc skip"))
}

/// cline 3.0.70: `Cline needs permission` / `Approve tool call?` / … /
/// `[y] Approve   [n] Deny` in the bottom 16 non-empty rows (cline.md §10,
/// live), or a question: `Cline is asking a question` and a `> ` option above
/// the `(Tab)`/`Shift+Tab` footer in the bottom 24 (herdr's cline manifest
/// 2026.09.11.1). The app's TmuxScreenDetector cline rules; its older
/// whole-screen wordings are left out, since an Agent's reply can quote them.
pub fn cline_screen_shown(screen: &str) -> bool {
    let permission = bottom_non_empty(screen, 16).join("\n").to_lowercase();
    if [
        "cline needs permission",
        "approve tool call?",
        "[y] approve",
        "[n] deny",
    ]
    .iter()
    .all(|needle| permission.contains(needle))
    {
        return true;
    }
    let rows = bottom_non_empty(screen, 24);
    let text = rows.join("\n").to_lowercase();
    // `/^\s*Cline is asking a question\s*$/`
    let asking = |row: &&str| row.trim_matches(jsx::is_js_space) == "Cline is asking a question";
    // `/^\s*>\s+\S/`
    let option = |row: &&str| {
        row.trim_start_matches(jsx::is_js_space)
            .strip_prefix('>')
            .is_some_and(|rest| {
                rest.chars().next().is_some_and(jsx::is_js_space)
                    && rest.chars().any(|c| !jsx::is_js_space(c))
            })
    };
    text.contains("(tab)")
        && text.contains("shift+tab")
        && rows.iter().any(asking)
        && rows.iter().any(option)
}

/// Per kind, whether a visible screen shows its approval dialog (the JS
/// `APPROVAL_SCREENS` table); `None` for a kind with no approval screen.
pub fn approval_screen(agent: &str) -> Option<fn(&str) -> bool> {
    match agent {
        "agy" => Some(agy_screen_shown),
        "cline" => Some(cline_screen_shown),
        _ => None,
    }
}

/// `#{==:#{<option>},<value>}`, true when the pane's option is `value` (unset
/// reads as empty).
fn equals(option: &str, value: &str) -> String {
    format!("#{{==:#{{{option}}},{value}}}")
}

/// Every condition at once, as one tmux format.
fn all(conditions: &[String]) -> String {
    conditions[1..]
        .iter()
        .fold(conditions[0].clone(), |format, condition| {
            format!("#{{&&:{format},{condition}}}")
        })
}

/// What the watch needs from the system; the tests give it a fake tmux and a
/// virtual clock.
pub struct WatchIo<'a> {
    /// Its `TMUX` picks the server.
    pub env: &'a Env,
    /// `run(cmd, args, env)`; [`run_program`] in the command.
    pub run: &'a dyn Fn(&str, &[&str], &Env) -> RunResult,
    /// Sleep that many milliseconds.
    pub sleep: &'a dyn Fn(u64),
    /// Epoch milliseconds.
    pub now: &'a dyn Fn() -> u64,
    /// This process, the token's prefix.
    pub pid: u32,
    /// Whether a token's pid is a running watch for the pane (`%3`).
    pub alive: &'a dyn Fn(u64, &str) -> bool,
    /// The notifier for a status this watch wrote (`waycar notify`); returns
    /// when the delivery is done.
    pub notify: &'a dyn Fn(&'static str),
}

/// One tmux call: `commands` (each one tmux command line) run only while
/// `condition` holds, decided in the server, then `read_option`'s value as
/// read back afterwards ("" when unset); `None` when tmux refused (the pane
/// is gone).
fn run_if(
    io: &WatchIo,
    target: &str,
    condition: &str,
    commands: &[String],
    read_option: &str,
) -> Option<String> {
    let result = (io.run)(
        "tmux",
        &[
            "-u",
            "if-shell",
            "-F",
            "-t",
            target,
            condition,
            &commands.join(" ; "),
            ";",
            "show-options",
            "-p",
            "-q",
            "-v",
            "-t",
            target,
            read_option,
        ],
        io.env,
    );
    (result.code == 0).then(|| {
        result
            .stdout
            .strip_suffix('\n')
            .unwrap_or(&result.stdout)
            .to_string()
    })
}

/// The pane's watch options and screen from one [`read_pane`] call.
struct Pane {
    status: Option<String>,
    seq: Option<String>,
    watch: String,
    poke: String,
    screen: String,
}

/// One tmux call: the pane's watch options as one fixed-format line (an unset
/// option is an empty field, so a screen row can never fill its slot), then
/// its visible screen. `None` when the pane is gone.
fn read_pane(io: &WatchIo, target: &str) -> Option<Pane> {
    let format = READ_OPTIONS
        .iter()
        .map(|option| format!("#{{{option}}}"))
        .collect::<Vec<_>>()
        .join(&UNIT.to_string());
    let result = (io.run)(
        "tmux",
        &[
            "-u",
            "display-message",
            "-p",
            "-t",
            target,
            &format,
            ";",
            "capture-pane",
            "-p",
            "-J",
            "-t",
            target,
        ],
        io.env,
    );
    if result.code != 0 {
        return None;
    }
    let (first, screen) = match result.stdout.split_once('\n') {
        Some((first, screen)) => (first, screen),
        None => (result.stdout.as_str(), ""),
    };
    let fields: Vec<&str> = first.split(UNIT).collect();
    let [status, seq, watch, poke] = fields[..] else {
        return None;
    };
    let option = |value: &str| (!value.is_empty()).then(|| value.to_string());
    Some(Pane {
        status: option(status),
        seq: option(seq),
        watch: watch.to_string(),
        poke: poke.to_string(),
        screen: screen.to_string(),
    })
}

/// Write `status` with a raised seq while the pane's seq is still
/// `previous_seq` (and, with `token`, this watch still holds the pane); the
/// new seq, or `None` when the pane moved on or is gone.
fn write_status(
    io: &WatchIo,
    target: &str,
    status: &str,
    previous_seq: Option<&str>,
    token: Option<&str>,
) -> Option<String> {
    if !is_plain(previous_seq.unwrap_or("")) {
        return None;
    }
    let seq = next_seq(previous_seq, now_ns());
    let mut conditions = vec![equals(SEQ, previous_seq.unwrap_or(""))];
    if let Some(token) = token {
        conditions.push(equals(WATCH_OPTION, token));
    }
    let written = run_if(
        io,
        target,
        &all(&conditions),
        &[
            format!("set-option -p -t {target} {STATUS} {status}"),
            format!("set-option -p -t {target} {SEQ} {seq}"),
        ],
        SEQ,
    );
    (written.as_deref() == Some(seq.as_str())).then_some(seq)
}

/// Whether `watch` is the token of a running watch other than this one
/// (`pid`) for `target`.
fn holder(watch: &str, pid: u32, target: &str, alive: &dyn Fn(u64, &str) -> bool) -> bool {
    // `/^(\d+)-[0-9a-f]+$/`
    let Some((owner, hex)) = watch.split_once('-') else {
        return false;
    };
    if owner.is_empty()
        || !owner.bytes().all(|b| b.is_ascii_digit())
        || hex.is_empty()
        || !hex.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
    {
        return false;
    }
    // A number beyond u64 is no pid: nothing could be running as it.
    owner
        .parse::<u64>()
        .is_ok_and(|owner| owner != u64::from(pid) && alive(owner, target))
}

/// Whether `pid` is a running `watch-approval` for pane `target` (`%3`): its
/// argv must hold `watch-approval --pane tmux:%3 ` exactly, so a reused pid
/// now running a hook (`waycar-hook <agent> watch-approval`) or another
/// pane's watch does not count.
pub fn watch_running(pid: u64, target: &str, env: &Env) -> bool {
    process_args(pid, env).is_some_and(|args| {
        format!("{} ", args.trim_end_matches(jsx::is_js_space))
            .contains(&format!(" watch-approval --pane tmux:{target} "))
    })
}

/// A random token: `<pid>-<12 hex digits>`.
fn new_token(pid: u32) -> String {
    let mut bytes = [0u8; 6];
    // A system without randomness cannot make a token that is not guessable;
    // a zero one still tells watches apart by pid.
    let _ = SystemRandom::new().fill(&mut bytes);
    let hex: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    format!("{pid}-{hex}")
}

/// Watch one pane for `agent`'s approval dialog, as described above. Returns
/// at once when another live watch holds the pane. `pane_id` is `tmux:%3` (a
/// raw `%3` is accepted); fails only for an agent with no approval screen.
pub fn watch_approval(pane_id: &str, agent: &str, io: &WatchIo) -> Result<()> {
    let Some(shown) = approval_screen(agent) else {
        return Err(CliError::failure(format!("no approval screen for {agent}")));
    };
    let target = to_tmux_target(pane_id);
    let mut watch = ApprovalWatchMachine::new(new_token(io.pid));
    let view = |pane: Option<Pane>| {
        pane.map(|pane| PaneView {
            shown: shown(&pane.screen),
            status: pane.status,
            seq: pane.seq,
            watch: pane.watch,
            poke: pane.poke,
        })
    };
    let first = read_pane(io, target);
    let other_holder = first
        .as_ref()
        .is_some_and(|pane| holder(&pane.watch, io.pid, target, io.alive));
    let mut events = vec![WatchEvent::Started {
        pane: view(first),
        other_holder,
    }];
    while let Some(event) = events.pop() {
        for effect in watch.handle(event) {
            let token = watch.token().to_string();
            events.push(match effect {
                WatchEffect::Claim { only_if } => {
                    let claim = only_if
                        .map_or_else(|| "1".to_string(), |watch| equals(WATCH_OPTION, &watch));
                    let watch = run_if(
                        io,
                        target,
                        &claim,
                        &[format!("set-option -p -t {target} {WATCH_OPTION} {token}")],
                        WATCH_OPTION,
                    );
                    WatchEvent::Claimed {
                        watch,
                        now: (io.now)(),
                    }
                }
                WatchEffect::Read { after_ms } => {
                    if let Some(ms) = after_ms {
                        (io.sleep)(ms);
                    }
                    let pane = view(read_pane(io, target));
                    WatchEvent::Read {
                        pane,
                        now: (io.now)(),
                    }
                }
                WatchEffect::WriteStatus {
                    status,
                    previous_seq,
                    token: with_token,
                } => {
                    let token = with_token.then_some(token.as_str());
                    let written = write_status(io, target, status, previous_seq.as_deref(), token);
                    if status == "blocked" {
                        WatchEvent::BlockedWritten(written)
                    } else {
                        WatchEvent::WorkingWritten(written.is_some())
                    }
                }
                WatchEffect::Notify(status) => {
                    (io.notify)(status);
                    continue;
                }
                WatchEffect::Leave { poke } => WatchEvent::Left(run_if(
                    io,
                    target,
                    &all(&[equals(WATCH_OPTION, &token), equals(POKE_OPTION, &poke)]),
                    &[format!("set-option -p -u -t {target} {WATCH_OPTION}")],
                    WATCH_OPTION,
                )),
            });
        }
    }
    Ok(())
}

/// The arguments of `waycar watch-approval --pane tmux:%N --agent agy|cline`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WatchArgs {
    /// Prefixed: `tmux:%3`.
    pub pane_id: String,
    pub agent: String,
}

/// Parse `--pane <id>` and `--agent <kind>`, a kind with an approval screen
/// (also `--flag=value`).
pub fn parse_watch_args(rest: &[String]) -> Result<WatchArgs> {
    let values = parse_flags(rest, &["pane", "agent"])?;
    let pane_id = parse_pane(values.get("pane").copied(), "watch-approval")?;
    let agent = values
        .get("agent")
        .copied()
        .filter(|agent| APPROVAL_AGENTS.contains(agent))
        .ok_or_else(|| {
            CliError::usage(format!(
                "watch-approval needs --agent {}",
                APPROVAL_AGENTS.join("|")
            ))
        })?;
    Ok(WatchArgs {
        pane_id,
        agent: agent.to_string(),
    })
}

/// `waycar watch-approval --pane tmux:%N --agent agy|cline`: the watch an
/// approval-less kind's tool hook starts, with the real tmux, clock and
/// processes. `rest` is everything after the subcommand. `notify(pane_id,
/// status)` is `waycar notify` for a status the watch wrote (the Live
/// Activity and the push): each runs on its own thread, so a slow delivery
/// never delays the watch, and all are done before this returns. The notifier
/// reports its own failure; none reaches the watch, as with
/// `Promise.allSettled`.
///
/// `Ok` is exit 0; an `Err` is a usage error (exit 2) or a failure (exit 1)
/// for the caller to print as every command's are (see [`CliError`]).
pub fn run_watch_approval(
    rest: &[String],
    env: &Env,
    notify: &(dyn Fn(&str, &str) + Sync),
) -> Result<()> {
    let args = parse_watch_args(rest)?;
    thread::scope(|scope| {
        let deliver = |status: &'static str| {
            let pane_id = args.pane_id.as_str();
            scope.spawn(move || notify(pane_id, status));
        };
        let io = WatchIo {
            env,
            run: &|cmd, args, env| run_program(cmd, args, env),
            sleep: &|ms| thread::sleep(Duration::from_millis(ms)),
            now: &epoch_millis,
            pid: std::process::id(),
            alive: &|pid, target| watch_running(pid, target, env),
            notify: &deliver,
        };
        watch_approval(&args.pane_id, &args.agent, &io)
    })
}

fn epoch_millis() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_millis() as u64)
}

/// An in-process tmux, with a virtual clock to run the watch on, for the
/// tests and the parity harness.
#[cfg(test)]
pub mod fake {
    use std::cell::{Cell, RefCell};
    use std::collections::BTreeMap;

    use super::{Env, Result, RunResult, WatchIo, watch_approval};

    // The tmux format expansion of the fake.

    /// The end of the `#{…}` opened just before `from`.
    fn closing(text: &str, from: usize) -> usize {
        let bytes = text.as_bytes();
        let mut depth = 1;
        let mut at = from;
        while at < bytes.len() {
            if text[at..].starts_with("#{") {
                depth += 1;
                at += 1;
            } else if bytes[at] == b'}' {
                depth -= 1;
                if depth == 0 {
                    return at;
                }
            }
            at += 1;
        }
        panic!("unclosed format: {text}");
    }

    /// `body` split at its top-level commas.
    fn format_args(body: &str) -> Vec<&str> {
        let bytes = body.as_bytes();
        let mut args = Vec::new();
        let mut start = 0;
        let mut at = 0;
        while at < bytes.len() {
            if body[at..].starts_with("#{") {
                at = closing(body, at + 2);
            } else if bytes[at] == b',' {
                args.push(&body[start..at]);
                start = at + 1;
            }
            at += 1;
        }
        args.push(&body[start..]);
        args
    }

    pub fn truthy(value: &str) -> bool {
        !value.is_empty() && value != "0"
    }

    /// tmux's format expansion, for the forms the watch and the hooks use:
    /// `#{@option}`, `#{==:a,b}`, `#{&&:a,b}`, `#{||:a,b}`.
    pub fn expand(text: &str, options: &BTreeMap<String, String>) -> String {
        let mut out = String::new();
        let mut at = 0;
        while at < text.len() {
            if !text[at..].starts_with("#{") {
                let ch = text[at..].chars().next().unwrap();
                out.push(ch);
                at += ch.len_utf8();
                continue;
            }
            let end = closing(text, at + 2);
            let body = &text[at + 2..end];
            if body.starts_with('@') {
                out.push_str(options.get(body).map_or("", String::as_str));
            } else {
                let (op, rest) = body.split_once(':').unwrap();
                let args: Vec<String> = format_args(rest)
                    .iter()
                    .map(|a| expand(a, options))
                    .collect();
                let result = match op {
                    "==" => args[0] == args[1],
                    "&&" => truthy(&args[0]) && truthy(&args[1]),
                    "||" => truthy(&args[0]) || truthy(&args[1]),
                    _ => panic!("unexpected format {op}"),
                };
                out.push_str(if result { "1" } else { "0" });
            }
            at = end + 1;
        }
        out
    }

    pub struct Host {
        pub options: BTreeMap<String, String>,
        pub gone: bool,
        pub captures: usize,
        pub writes: Vec<String>,
        pub calls: usize,
    }

    pub type CallHook = Box<dyn Fn(&[&str], &mut Host)>;
    pub type CaptureHook = Box<dyn Fn(usize, &mut Host)>;

    /// An in-process tmux for `run`: `options` are the pane's options,
    /// `screens` the captures in order (the last one repeats); `gone` makes
    /// every call fail. `on_capture(n)` runs before the call holding the
    /// n-th capture, and `on_call(argv)` before every call, to script hooks
    /// and a closed pane. `if-shell -F` runs its commands in the same call,
    /// as tmux does.
    pub struct FakeTmux {
        pub host: RefCell<Host>,
        screens: Vec<String>,
        on_capture: Option<CaptureHook>,
        on_call: Option<CallHook>,
    }

    fn apply(host: &mut Host, screens: &[String], command: &[&str]) -> String {
        let (name, rest) = command.split_first().unwrap();
        let target_at = rest.iter().position(|a| *a == "-t").unwrap();
        assert_eq!(rest[target_at + 1], "%3");
        match *name {
            "display-message" => {
                assert!(rest.contains(&"-p"));
                format!("{}\n", expand(rest.last().unwrap(), &host.options))
            }
            "show-options" => {
                let option = rest.last().unwrap();
                match host.options.get(*option) {
                    Some(value) if rest.contains(&"-v") => format!("{value}\n"),
                    Some(value) => format!("{option} {value}\n"),
                    None => String::new(),
                }
            }
            "capture-pane" => {
                host.captures += 1;
                format!("{}\n", screens[(host.captures - 1).min(screens.len() - 1)])
            }
            "set-option" => {
                if rest.contains(&"-u") {
                    host.options.remove(*rest.last().unwrap());
                } else {
                    let (option, value) = (rest[rest.len() - 2], rest[rest.len() - 1]);
                    host.options.insert(option.to_string(), value.to_string());
                    if option == "@waycar_status" {
                        host.writes.push(value.to_string());
                    }
                }
                String::new()
            }
            "if-shell" => {
                assert!(rest.contains(&"-F"));
                let (condition, commands) = (rest[rest.len() - 2], rest[rest.len() - 1]);
                if truthy(&expand(condition, &host.options)) {
                    for command in commands.split(" ; ") {
                        let argv: Vec<&str> = command.split(' ').collect();
                        apply(host, screens, &argv);
                    }
                }
                String::new()
            }
            other => panic!("unexpected tmux command {other}"),
        }
    }

    impl FakeTmux {
        pub fn new(options: &[(&str, &str)], screens: &[String]) -> Self {
            Self {
                host: RefCell::new(Host {
                    options: options
                        .iter()
                        .map(|(k, v)| (k.to_string(), v.to_string()))
                        .collect(),
                    gone: false,
                    captures: 0,
                    writes: Vec::new(),
                    calls: 0,
                }),
                screens: screens.to_vec(),
                on_capture: None,
                on_call: None,
            }
        }

        pub fn on_capture(mut self, hook: impl Fn(usize, &mut Host) + 'static) -> Self {
            self.on_capture = Some(Box::new(hook));
            self
        }

        pub fn on_call(mut self, hook: impl Fn(&[&str], &mut Host) + 'static) -> Self {
            self.on_call = Some(Box::new(hook));
            self
        }

        pub fn run(&self, cmd: &str, args: &[&str], _env: &Env) -> RunResult {
            assert_eq!(cmd, "tmux");
            assert_eq!(args[0], "-u");
            let mut host = self.host.borrow_mut();
            host.calls += 1;
            if let Some(hook) = &self.on_call {
                hook(args, &mut host);
            }
            if args.contains(&"capture-pane")
                && let Some(hook) = &self.on_capture
            {
                let captures = host.captures;
                hook(captures, &mut host);
            }
            if host.gone {
                return RunResult {
                    code: 1,
                    stdout: String::new(),
                    stderr: "can't find pane: %3".into(),
                };
            }
            let mut stdout = String::new();
            for command in args[1..].split(|arg| *arg == ";") {
                stdout += &apply(&mut host, &self.screens, command);
            }
            RunResult {
                code: 0,
                stdout,
                stderr: String::new(),
            }
        }

        pub fn option(&self, name: &str) -> Option<String> {
            self.host.borrow().options.get(name).cloned()
        }

        pub fn writes(&self) -> Vec<String> {
            self.host.borrow().writes.clone()
        }
    }

    pub struct Watched {
        pub notified: Vec<&'static str>,
        pub sleeps: Vec<u64>,
        pub elapsed: u64,
    }

    /// Runs the watch with a virtual clock; returns the notified statuses.
    pub fn watch_with(
        host: &FakeTmux,
        agent: &str,
        pid: u32,
        alive: &dyn Fn(u64, &str) -> bool,
    ) -> (Result<()>, Watched) {
        let clock = Cell::new(1_000_000u64);
        let notified = RefCell::new(Vec::new());
        let sleeps = RefCell::new(Vec::new());
        let env = Env::default();
        let result = {
            let io = WatchIo {
                env: &env,
                run: &|cmd, args, env| host.run(cmd, args, env),
                sleep: &|ms| {
                    sleeps.borrow_mut().push(ms);
                    clock.set(clock.get() + ms);
                },
                now: &|| clock.get(),
                pid,
                alive,
                notify: &|status| notified.borrow_mut().push(status),
            };
            watch_approval("tmux:%3", agent, &io)
        };
        let watched = Watched {
            notified: notified.into_inner(),
            sleeps: sleeps.into_inner(),
            elapsed: clock.get() - 1_000_000,
        };
        (result, watched)
    }
}

/// Ports of test/approval-watch.test.js: agy's and cline's approval screen
/// rules against live screens (agy 1.3.3 and cline 3.0.70 in the harness lab,
/// tmux 3.4), and the watch against an in-process tmux whose screen and
/// options the test scripts.
#[cfg(test)]
mod tests {
    use super::fake::{FakeTmux, Watched, watch_with};
    use super::*;
    use std::cell::{Cell, RefCell};

    fn rule() -> String {
        "─".repeat(60)
    }

    const FOOTER_MODEL: &str =
        "                                             Gemini 3.6 Flash · low";

    // The harness lab e2e run's screen while agy asked (2026-10-12).
    fn blocked() -> String {
        [
            "  waycar-mock-reply: WAYCAR_E2E_AGY_TMUX_0EC51A_P1",
            "",
            &rule(),
            "> run WAYCAR_TOOL now WAYCAR_E2E_AGY_TMUX_0EC51A_T1",
            "",
            "● Ran (echo waycar-tool-ok) (ctrl+o to expand)",
            "",
            "Command",
            &"─".repeat(80),
            "",
            "Requesting permission for:",
            "   echo waycar-tool-ok",
            "",
            "Run this command?",
            "> 1. Yes, run command",
            "  2. Yes, and always allow in this conversation for commands that start with 'echo'",
            "  3. Yes, and always allow for commands that start with 'echo' (Persist to settings.json)",
            "  4. No, cancel",
            "",
            "  ↑/↓ Navigate · tab Amend · ctrl+g edit/expand command",
            &format!("esc to cancel{FOOTER_MODEL}"),
            "",
            "",
        ]
        .join("\n")
    }

    fn working() -> String {
        [
            "> run WAYCAR_TOOL now",
            "",
            "⣽  Generating...",
            &rule(),
            ">",
            &rule(),
            &format!("esc to cancel{FOOTER_MODEL}"),
            "",
        ]
        .join("\n")
    }

    fn approved() -> String {
        [
            "> run WAYCAR_TOOL now",
            "● Ran (echo waycar-tool-ok) (ctrl+o to expand)",
            "",
            "  waycar-tool-done: saw waycar-tool-ok",
            &rule(),
            ">",
            &rule(),
            &format!("? for shortcuts{FOOTER_MODEL}"),
        ]
        .join("\n")
    }

    // After `4. No, cancel`: no hook fires (agy.md §1).
    fn denied() -> String {
        [
            "> deny WAYCAR_TOOL test",
            "● Ran (echo waycar-tool-ok) failed (ctrl+o to expand)",
            "Command",
            "  ⎿  User declined the tool call",
            "  ⎿  Interrupted · What should Antigravity CLI do instead?",
            &rule(),
            ">",
            &rule(),
            &format!("? for shortcuts{FOOTER_MODEL}"),
        ]
        .join("\n")
    }

    // The slash-command menu is idle, not a dialog (herdr's agy manifest).
    fn slash_menu() -> String {
        [
            "> /",
            "  /help",
            "  /model",
            "  ↑/↓ Navigate · enter Select · tab Complete",
            &format!("? for shortcuts{FOOTER_MODEL}"),
        ]
        .join("\n")
    }

    // suite "agy's approval screen"

    #[test]
    fn agy_the_permission_and_question_dialogs() {
        assert!(agy_screen_shown(&blocked()));
        assert!(agy_screen_shown(
            "  Which color?\n  ↑/↓ Navigate · enter Select · esc Skip\nesc to cancel"
        ));
    }

    #[test]
    fn agy_never_a_working_finished_denied_or_menu_screen() {
        for screen in [working(), approved(), denied(), slash_menu(), String::new()] {
            assert!(!agy_screen_shown(&screen), "{screen}");
        }
    }

    #[test]
    fn agy_not_the_dialogs_text_once_it_scrolled_above_the_bottom_rows() {
        let rule = rule();
        assert!(!agy_screen_shown(&format!(
            "{}\n  waycar-tool-done: saw waycar-tool-ok\n{rule}\n>\n{rule}\n? for shortcuts",
            blocked()
        )));
    }

    fn cline_rule() -> String {
        "─".repeat(100)
    }

    const CLINE_FOOTER: [&str; 3] = [
        " mock-model (5,474) $0.00                                                        ○ Plan ● Act (Tab)",
        " demo (main)",
        " Auto-approve all disabled (Shift+Tab)",
    ];

    fn with_footer(rows: &[&str]) -> String {
        rows.iter()
            .chain(CLINE_FOOTER.iter())
            .copied()
            .collect::<Vec<_>>()
            .join("\n")
    }

    // The lab's `--auto-approve false` dialog (cline.md §10, 2026-10-12).
    fn cline_blocked() -> String {
        with_footer(&[
            " ❯ hello CLPROBE_delay_P1",
            " * waycar-mock-reply: CLPROBE_delay_P1",
            " ❯ run WAYCAR_TOOL now CLPROBE_delay_T1",
            " ⠋ Thinking... (esc to cancel)",
            "",
            "",
            " Cline needs permission",
            "",
            " Approve tool call?",
            "",
            " run_commands",
            "",
            "   $ bash",
            "   $ -lc",
            "   $ echo waycar-tool-ok",
            "",
            "  [y] Approve   [n] Deny",
            "",
        ])
    }

    fn cline_working() -> String {
        let rule = cline_rule();
        with_footer(&[
            " ❯ run WAYCAR_TOOL now",
            " ⠙ Thinking... (esc to cancel)",
            &rule,
            "❯ Ask anything...",
            &rule,
        ])
    }

    // After `y`.
    fn cline_approved() -> String {
        let rule = cline_rule();
        with_footer(&[
            " ❯ run WAYCAR_TOOL now CLPROBE_delay_T1",
            " * run_commands(bash && -lc && echo waycar-tool-ok)",
            "   ⎿",
            "      ... 6 more lines",
            " * waycar-tool-done: saw waycar-tool-ok",
            &rule,
            "❯ Ask anything...",
            &rule,
        ])
    }

    // suite "cline's approval screen"

    #[test]
    fn cline_the_permission_and_question_dialogs() {
        assert!(cline_screen_shown(&cline_blocked()));
        assert!(cline_screen_shown(&with_footer(&[
            " Cline is asking a question",
            " Which color?",
            " > red",
            "   blue",
        ])));
    }

    #[test]
    fn cline_never_a_working_or_finished_screen() {
        for screen in [cline_working(), cline_approved(), String::new()] {
            assert!(!cline_screen_shown(&screen), "{screen}");
        }
    }

    #[test]
    fn cline_not_the_dialogs_text_once_it_scrolled_above_the_bottom_rows() {
        let filler: Vec<String> = (0..16).map(|i| format!(" * line {i}")).collect();
        let screen = [cline_blocked(), filler.join("\n"), cline_approved()].join("\n");
        assert!(!cline_screen_shown(&screen));
    }

    #[test]
    fn question_rows_follow_the_js_regexes() {
        let question = |rows: &[&str]| cline_screen_shown(&with_footer(rows));
        // `\s` is JavaScript's set: U+FEFF counts, U+0085 does not.
        assert!(question(&[
            "\u{feff}Cline is asking a question\u{3000}",
            ">\u{a0}red"
        ]));
        assert!(!question(&["\u{85}Cline is asking a question", "> red"]));
        assert!(!question(&["Cline is asking a question", ">red"]));
        assert!(!question(&["Cline is asking a question", "> "]));
        assert!(!question(&["cline is asking a question", "> red"]));
        // A row of only JavaScript whitespace is empty for the bottom rows.
        assert_eq!(
            bottom_non_empty("a\n\u{feff}\n\u{85}\nb", 5),
            ["a", "\u{85}", "b"]
        );
    }

    fn watch(host: &FakeTmux) -> Watched {
        let (result, watched) = watch_with(host, "agy", 4242, &|_, _| false);
        result.unwrap();
        watched
    }

    const WORKING_OPTIONS: [(&str, &str); 3] = [
        ("@waycar_status", "working"),
        ("@waycar_seq", "1000"),
        ("@waycar_agent", "agy"),
    ];

    fn screens(list: &[String]) -> Vec<String> {
        list.to_vec()
    }

    // suite "watchApproval"

    #[test]
    fn the_dialog_drawn_after_the_hook_blocked_while_it_shows_then_working() {
        let host = FakeTmux::new(
            &WORKING_OPTIONS,
            &screens(&[
                working(),
                working(),
                blocked(),
                blocked(),
                blocked(),
                working(),
            ]),
        );
        let watched = watch(&host);
        assert_eq!(host.writes(), ["blocked", "working"]);
        assert_eq!(watched.notified, ["blocked", "working"]);
        assert_eq!(
            watched.sleeps,
            [POLL_MS, POLL_MS, HELD_POLL_MS, HELD_POLL_MS, HELD_POLL_MS]
        );
        assert_eq!(host.option("@waycar_status").as_deref(), Some("working"));
        assert!(host.option("@waycar_seq").unwrap().parse::<u128>().unwrap() > 1000);
        assert_eq!(
            host.option("@waycar_approval_watch"),
            None,
            "the watch let go of the pane"
        );
    }

    #[test]
    fn a_denial_ends_the_dialog_with_no_hook_back_to_working() {
        let host = FakeTmux::new(&WORKING_OPTIONS, &screens(&[blocked(), denied()]));
        assert_eq!(watch(&host).notified, ["blocked", "working"]);
        assert_eq!(host.option("@waycar_status").as_deref(), Some("working"));
    }

    #[test]
    fn no_dialog_within_the_wait_an_auto_allowed_tool_writes_nothing() {
        let host = FakeTmux::new(&WORKING_OPTIONS, &screens(&[working()]));
        let watched = watch(&host);
        assert!(host.writes().is_empty());
        assert!(watched.notified.is_empty());
        assert!(
            watched.elapsed >= DIALOG_WAIT_MS && watched.elapsed < DIALOG_WAIT_MS + POLL_MS,
            "{}",
            watched.elapsed
        );
    }

    #[test]
    fn only_from_a_working_pane() {
        for status in [None, Some("idle"), Some("done"), Some("blocked")] {
            let options: Vec<(&str, &str)> = match status {
                None => Vec::new(),
                Some(status) => vec![
                    ("@waycar_status", status),
                    ("@waycar_seq", "1000"),
                    ("@waycar_agent", "agy"),
                ],
            };
            let host = FakeTmux::new(&options, &screens(&[blocked()]));
            assert!(watch(&host).notified.is_empty(), "{status:?}");
            assert!(host.writes().is_empty());
        }
    }

    #[test]
    fn a_hooks_write_before_the_dialog_ends_the_watch() {
        let host = FakeTmux::new(&WORKING_OPTIONS, &screens(&[working(), blocked()])).on_capture(
            |n, h| {
                if n == 1 {
                    h.options.insert("@waycar_seq".into(), "2000".into());
                }
            },
        );
        assert!(watch(&host).notified.is_empty());
        assert!(host.writes().is_empty());
    }

    #[test]
    fn a_hooks_write_while_blocked_owns_the_status_from_there() {
        let host = FakeTmux::new(
            &WORKING_OPTIONS,
            &screens(&[blocked(), blocked(), working()]),
        )
        .on_capture(|n, h| {
            // The next invocation's PreInvocation after the approval.
            if n == 2 {
                h.options.insert("@waycar_status".into(), "working".into());
                h.options
                    .insert("@waycar_seq".into(), "9999999999999999999".into());
            }
        });
        assert_eq!(watch(&host).notified, ["blocked"]);
        assert_eq!(host.writes(), ["blocked"]);
    }

    #[test]
    fn a_pane_that_goes_away_ends_the_watch() {
        let host = FakeTmux::new(&WORKING_OPTIONS, &screens(&[blocked()])).on_capture(|n, h| {
            if n == 2 {
                h.gone = true;
            }
        });
        assert_eq!(watch(&host).notified, ["blocked"]);
    }

    #[test]
    fn one_watch_per_pane_a_live_watchs_token_turns_another_away() {
        let mut options = WORKING_OPTIONS.to_vec();
        options.push(("@waycar_approval_watch", "777-abcdef"));
        let host = FakeTmux::new(&options, &screens(&[blocked()]));
        let asked = RefCell::new(Vec::new());
        let alive = |pid: u64, target: &str| {
            asked.borrow_mut().push((pid, target.to_string()));
            pid == 777
        };
        let (result, watched) = watch_with(&host, "agy", 4242, &alive);
        result.unwrap();
        assert!(watched.notified.is_empty());
        assert_eq!(*asked.borrow(), [(777, "%3".to_string())]);
        assert!(host.writes().is_empty());
        assert_eq!(host.host.borrow().calls, 1);
        assert_eq!(
            host.option("@waycar_approval_watch").as_deref(),
            Some("777-abcdef")
        );
    }

    #[test]
    fn a_dead_watchs_token_is_taken_over() {
        let mut options = WORKING_OPTIONS.to_vec();
        options.push(("@waycar_approval_watch", "777-abcdef"));
        let host = FakeTmux::new(&options, &screens(&[blocked(), denied()]));
        assert_eq!(watch(&host).notified, ["blocked", "working"]);
        assert_eq!(host.option("@waycar_approval_watch"), None);
    }

    #[test]
    fn screen_rows_never_stand_in_for_unset_pane_options() {
        let host = FakeTmux::new(
            &WORKING_OPTIONS,
            &screens(&[
                format!(
                    "@waycar_approval_watch 777-abcdef\n@waycar_approval_poke 1-2\n{}",
                    blocked()
                ),
                denied(),
            ]),
        );
        let (result, watched) = watch_with(&host, "agy", 4242, &|pid, _| pid == 777);
        result.unwrap();
        assert_eq!(watched.notified, ["blocked", "working"]);
    }

    #[test]
    fn only_this_panes_running_watch_counts_as_live() {
        use std::process::{Command, Stdio};
        let spawn_with = |args: &[&str]| {
            Command::new("sh")
                .args(["-c", "sleep 10; :", "sh"])
                .args(args)
                .stdin(Stdio::null())
                .spawn()
                .unwrap()
        };
        let mut own = spawn_with(&["watch-approval", "--pane", "tmux:%3", "--agent", "agy"]);
        let mut hook = spawn_with(&["/p/bin/waycar-hook", "agy", "watch-approval"]);
        let mut other = spawn_with(&["watch-approval", "--pane", "tmux:%31", "--agent", "agy"]);
        let env = Env::from_process();
        assert!(watch_running(own.id().into(), "%3", &env));
        assert!(!watch_running(own.id().into(), "%4", &env));
        assert!(!watch_running(hook.id().into(), "%3", &env));
        assert!(!watch_running(other.id().into(), "%3", &env));
        assert!(!watch_running(999_999_999, "%3", &env));
        for child in [&mut own, &mut hook, &mut other] {
            child.kill().unwrap();
            child.wait().unwrap();
        }
    }

    #[test]
    fn a_pre_tool_use_during_the_wait_restarts_it() {
        let waited = (DIALOG_WAIT_MS / POLL_MS) as usize;
        let mut list = vec![working(); waited + 10];
        list.extend([blocked(), working()]);
        let host = FakeTmux::new(&WORKING_OPTIONS, &list).on_capture(move |n, h| {
            if n == waited - 5 {
                h.options
                    .insert("@waycar_approval_poke".into(), "51-1790000000".into());
            }
        });
        assert_eq!(watch(&host).notified, ["blocked", "working"]);
        assert_eq!(host.writes(), ["blocked", "working"]);
    }

    #[test]
    fn a_pre_tool_use_as_the_watch_lets_go_keeps_it_watching() {
        let waited = (DIALOG_WAIT_MS / POLL_MS) as usize;
        let mut list = vec![working(); waited + 1];
        list.extend([blocked(), working()]);
        let poked = std::rc::Rc::new(Cell::new(false));
        let seen = poked.clone();
        let host = FakeTmux::new(&WORKING_OPTIONS, &list).on_call(move |args, h| {
            // The hook's poke lands just before the watch's release.
            if !seen.get()
                && args.contains(&"if-shell")
                && args
                    .iter()
                    .any(|arg| arg.contains("-u -t %3 @waycar_approval_watch"))
            {
                seen.set(true);
                h.options
                    .insert("@waycar_approval_poke".into(), "52-1790000000".into());
            }
        });
        assert_eq!(watch(&host).notified, ["blocked", "working"]);
        assert!(poked.get());
        assert_eq!(host.option("@waycar_approval_watch"), None);
    }

    #[test]
    fn a_pre_tool_use_while_blocked_the_next_dialog_is_watched_too() {
        let host = FakeTmux::new(
            &WORKING_OPTIONS,
            &screens(&[blocked(), blocked(), working(), blocked(), working()]),
        )
        .on_capture(|n, h| {
            if n == 1 {
                h.options
                    .insert("@waycar_approval_poke".into(), "53-1790000000".into());
            }
        });
        assert_eq!(
            watch(&host).notified,
            ["blocked", "working", "blocked", "working"]
        );
    }

    #[test]
    fn a_hooks_write_between_the_read_and_the_blocked_write_wins() {
        let host = FakeTmux::new(&WORKING_OPTIONS, &screens(&[blocked()])).on_call(|args, h| {
            if args.contains(&"if-shell")
                && args
                    .iter()
                    .any(|arg| arg.contains("@waycar_status blocked"))
            {
                h.options.insert("@waycar_status".into(), "done".into());
                h.options.insert("@waycar_seq".into(), "2000".into());
            }
        });
        assert!(watch(&host).notified.is_empty());
        assert!(host.writes().is_empty());
        assert_eq!(host.option("@waycar_status").as_deref(), Some("done"));
        assert_eq!(host.option("@waycar_approval_watch"), None);
    }

    #[test]
    fn a_hooks_write_between_the_read_and_the_working_write_wins() {
        let host =
            FakeTmux::new(&WORKING_OPTIONS, &screens(&[blocked(), denied()])).on_call(|args, h| {
                if args.contains(&"if-shell")
                    && args
                        .iter()
                        .any(|arg| arg.contains("@waycar_status working"))
                {
                    h.options.insert("@waycar_status".into(), "done".into());
                    h.options
                        .insert("@waycar_seq".into(), "9999999999999999999".into());
                }
            });
        assert_eq!(watch(&host).notified, ["blocked"]);
        assert_eq!(host.writes(), ["blocked"]);
        assert_eq!(host.option("@waycar_status").as_deref(), Some("done"));
        assert_eq!(host.option("@waycar_approval_watch"), None);
    }

    #[test]
    fn another_watch_claiming_between_the_read_and_the_claim_wins() {
        let host = FakeTmux::new(&WORKING_OPTIONS, &screens(&[blocked()])).on_call(|args, h| {
            if args.contains(&"if-shell")
                && args
                    .iter()
                    .any(|arg| arg.contains("@waycar_approval_watch 4242-"))
            {
                h.options
                    .insert("@waycar_approval_watch".into(), "777-abcdef".into());
            }
        });
        let (result, watched) = watch_with(&host, "agy", 4242, &|_, _| false);
        result.unwrap();
        assert!(watched.notified.is_empty());
        assert!(host.writes().is_empty());
        assert_eq!(host.host.borrow().calls, 2, "the read and the claim");
        assert_eq!(
            host.option("@waycar_approval_watch").as_deref(),
            Some("777-abcdef")
        );
    }

    #[test]
    fn a_poke_that_cannot_sit_in_a_format_ends_the_watch_holding_its_token() {
        let mut options = WORKING_OPTIONS.to_vec();
        options.push(("@waycar_approval_poke", "1 2"));
        let host = FakeTmux::new(&options, &screens(&[working()]));
        let watched = watch(&host);
        assert!(watched.notified.is_empty());
        let token = host.option("@waycar_approval_watch").unwrap();
        assert!(token.starts_with("4242-"), "{token}");
    }

    #[test]
    fn an_agent_with_no_approval_screen_is_refused() {
        let host = FakeTmux::new(&[], &screens(&[working()]));
        let (result, _) = watch_with(&host, "claude", 4242, &|_, _| false);
        assert_eq!(
            result.unwrap_err().message(),
            "no approval screen for claude"
        );
    }

    // The command's arguments, as waycar-cli.js's parseWatchArgs reads them.

    fn strings(args: &[&str]) -> Vec<String> {
        args.iter().map(|a| a.to_string()).collect()
    }

    #[test]
    fn watch_arguments_are_a_pane_and_a_kind_with_an_approval_screen() {
        let args = parse_watch_args(&strings(&["--pane", "%3", "--agent=cline"])).unwrap();
        assert_eq!(
            args,
            WatchArgs {
                pane_id: "tmux:%3".into(),
                agent: "cline".into()
            }
        );
        for (rest, message) in [
            (
                &["--agent", "agy"][..],
                "watch-approval needs --pane tmux:%N",
            ),
            (
                &["--pane", "tmux:%3"],
                "watch-approval needs --agent agy|cline",
            ),
            (
                &["--pane", "tmux:%3", "--agent", "claude"],
                "watch-approval needs --agent agy|cline",
            ),
            (
                &["--pane", "x", "--agent", "agy"],
                "bad pane id: x (expected tmux:%N)",
            ),
            (&["--pane", "%1", "--pane", "%2"], "--pane given twice"),
            (&["--bogus"], "unexpected argument: --bogus"),
        ] {
            let error = parse_watch_args(&strings(rest)).unwrap_err();
            assert_eq!(
                (error.exit_code(), error.message()),
                (2, message),
                "{rest:?}"
            );
        }
    }

    #[test]
    fn tokens_are_the_pid_and_twelve_hex_digits() {
        let token = new_token(77);
        let (pid, hex) = token.split_once('-').unwrap();
        assert_eq!(pid, "77");
        assert!(hex.len() == 12 && hex.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f')));
        assert_ne!(new_token(77), token);
        assert!(holder("12-ab", 1, "%3", &|pid, _| pid == 12));
        assert!(!holder("12-ab", 12, "%3", &|_, _| true), "this process");
        assert!(!holder("12-AB", 1, "%3", &|_, _| true));
        assert!(!holder("-ab", 1, "%3", &|_, _| true));
        assert!(!holder("12-", 1, "%3", &|_, _| true));
        assert!(!holder("99999999999999999999-ab", 1, "%3", &|_, _| true));
    }

    // The watch against a real tmux: the compare-and-set formats the fake
    // only emulates run in the server.
    #[test]
    fn real_tmux_watch_blocks_while_the_dialog_shows_then_works() {
        use crate::real_tmux::RealTmux;

        let Some(tmux) = RealTmux::start() else {
            return;
        };
        let screen = std::env::temp_dir().join(format!("wc-watch-screen-{}", std::process::id()));
        std::fs::write(&screen, blocked()).unwrap();
        let show = format!("cat '{}'; sleep 60", screen.display());
        tmux.ok(&[
            "new-session",
            "-d",
            "-x",
            "120",
            "-y",
            "40",
            "-s",
            "s",
            &show,
        ]);
        let pane = tmux.ok(&["list-panes", "-a", "-F", "#{pane_id}"]);
        assert_eq!(pane, "%0");
        for (name, value) in [("@waycar_status", "working"), ("@waycar_seq", "1000")] {
            tmux.ok(&["set-option", "-p", "-t", &pane, name, value]);
        }
        // Let the dialog draw.
        for _ in 0..100 {
            if agy_screen_shown(&tmux.ok(&["capture-pane", "-p", "-t", &pane])) {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(20));
        }

        let clock = Cell::new(1_000_000u64);
        let sleeps = RefCell::new(Vec::new());
        let notified = RefCell::new(Vec::new());
        let result = {
            let io = WatchIo {
                env: &tmux.env,
                run: &|cmd, args, env| run_program(cmd, args, env),
                // A held poll: the dialog is gone by the next one.
                sleep: &|ms| {
                    sleeps.borrow_mut().push(ms);
                    clock.set(clock.get() + ms);
                    if ms == HELD_POLL_MS {
                        tmux.ok(&["respawn-pane", "-k", "-t", "%0", "echo finished; sleep 60"]);
                        std::thread::sleep(std::time::Duration::from_millis(300));
                    }
                },
                now: &|| clock.get(),
                pid: 4242,
                alive: &|_, _| false,
                notify: &|status| notified.borrow_mut().push(status),
            };
            watch_approval("tmux:%0", "agy", &io)
        };
        std::fs::remove_file(&screen).unwrap();
        result.unwrap();

        assert_eq!(*notified.borrow(), ["blocked", "working"]);
        assert_eq!(*sleeps.borrow(), [HELD_POLL_MS]);
        let option = |name: &str| tmux.ok(&["show-options", "-p", "-v", "-q", "-t", "%0", name]);
        assert_eq!(option("@waycar_status"), "working");
        assert!(option("@waycar_seq").parse::<u128>().unwrap() > 1000);
        assert_eq!(
            option("@waycar_approval_watch"),
            "",
            "the watch let go of the pane"
        );
    }

    #[test]
    fn the_command_validates_its_arguments_and_ends_when_tmux_is_gone() {
        let notified = std::sync::Mutex::new(Vec::new());
        let notify = |pane: &str, status: &str| {
            notified.lock().unwrap().push(format!("{pane} {status}"));
        };
        let env = Env::from_pairs([("PATH", "/nonexistent")]);
        let error =
            run_watch_approval(&strings(&["--pane", "tmux:%3"]), &env, &notify).unwrap_err();
        assert_eq!(
            (error.exit_code(), error.message()),
            (2, "watch-approval needs --agent agy|cline")
        );
        // No tmux to read the pane from: nothing to watch, exit 0, no word.
        run_watch_approval(
            &strings(&["--pane", "tmux:%3", "--agent", "agy"]),
            &env,
            &notify,
        )
        .unwrap();
        assert!(notified.lock().unwrap().is_empty());
    }
}
