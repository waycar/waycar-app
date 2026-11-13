//! `waycar`: the Host Tools' command line (waycar-cli.js).
//!
//!   waycar pair                          Pairing Code in this terminal
//!   waycar hooks install|status [--json]
//!   waycar hooks uninstall
//!   waycar notify --pane tmux:%N --status working|idle|blocked|done|release
//!   waycar watch-approval --pane tmux:%N --agent agy|cline   (run by the agent hooks)
//!   waycar summaries refresh
//!   waycar status [--json]
//!   waycar version
//!
//! [`plan`] turns the arguments into what to do: print something and exit, or
//! run a subcommand ([`Native`], see `native.rs`). Argument errors are
//! word-for-word the retired JS CLI's, so a usage mistake reads the same as
//! it did.

use std::collections::BTreeMap;

use crate::VERSION;
use crate::approval_watch::parse_watch_args;

use crate::error::{CliError, EXIT_OK, Result};

pub const USAGE: &str = "usage: waycar <command>

commands:
  pair                                   show a Pairing Code in this terminal
  hooks install|status [--json]          install or check the agent status hooks
  hooks uninstall                        remove the agent status hooks
  notify --pane tmux:%N --status working|idle|blocked|done|release
                                         update the Live Activity; push on
                                         blocked or done
  watch-approval --pane tmux:%N --agent agy|cline
                                         run by the agent hooks: Blocked
                                         while the agent's approval shows
  summaries refresh                      refresh Agent Summaries
  status [--json]                        show backends, hooks and config dir
  version                                print the version
";

/// `notify` takes every status change the hooks make, plus `release` (the
/// agent left and its pane options were unset): the Live Activity follows all
/// of them, while only Blocked and Done send a push.
pub const PANE_STATUSES: [&str; 5] = ["working", "idle", "blocked", "done", "release"];
const HOOK_ACTIONS: [&str; 4] = ["install", "uninstall", "status", "migrate"];

/// What one `waycar` invocation does.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Plan {
    /// Write `stdout` and `stderr`, then exit with `code`.
    Done {
        code: i32,
        stdout: String,
        stderr: String,
    },
    /// Run this subcommand in Rust (`native::run`).
    Native(Native),
}

/// The subcommands Rust runs itself.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Native {
    /// `waycar pair`: the Pairing Code popup in this terminal.
    Pair,
    /// `waycar pair-action`: herdr's "Pair a mobile device" action, which
    /// opens the pairing popup pane (not in the usage).
    PairAction(Vec<String>),
    /// `waycar pair-accept --state-dir D --pairing-id I`: the sshd forced
    /// command behind a Bootstrap Key (not in the usage; the arguments are
    /// parsed by the command).
    PairAccept(Vec<String>),
    /// `waycar hooks install|uninstall|status [--json]`.
    Hooks {
        action: HooksAction,
        json: bool,
    },
    /// `waycar status [--json]`.
    Status {
        json: bool,
    },
    /// `waycar reach-status [--tailscale-cli]`: what install.sh prints about
    /// Tailscale (not in the usage; the arguments are parsed by the command).
    ReachStatus(Vec<String>),
    /// `waycar config-dir`: the plugin config directory, which the Chat
    /// Prompt extension of opencode and kilo asks for (not in the usage).
    ConfigDir,
    /// `waycar notify --pane tmux:%N --status <s>`: the push and the Live
    /// Activity flows.
    Notify(NotifyArgs),
    /// `waycar watch-approval ...`: the arguments after the subcommand,
    /// which `approval_watch` parses again.
    WatchApproval(Vec<String>),
    /// `waycar hook-session <agent> [<event>]`: agent and event as given
    /// (not in the usage; the event payload is on stdin).
    HookSession(Vec<String>),
    /// `waycar hook-status <agent> <status>`: the herdr-core half of
    /// waycar-hook, which runs it when the agent is not in a tmux pane (not
    /// in the usage).
    HookStatus(Vec<String>),
    /// `waycar codex-daemon-hook <status>`: tty-less Codex hooks only;
    /// exit 125 asks waycar-hook to continue its original pane path.
    CodexDaemonHook(Vec<String>),
    /// `waycar opencode-push <status>`: an OpenCode 2 server event from the
    /// opencode plugin's V2 `setup`, its JSON on stdin (not in the usage).
    OpencodePush(Vec<String>),
    /// `waycar herdr-event notify` and `herdr-event activity`: herdr's
    /// `pane.agent_status_changed` event hooks (not in the usage).
    HerdrNotify,
    HerdrActivity,
    /// `waycar herdr-startup`: herdr's startup hook (not in the usage).
    HerdrStartup,
    /// `waycar activity-tick '<json>'`: the detached plan-step tick the Live
    /// Activity hook starts, with the JSON options it passed (not in the
    /// usage).
    ActivityTick(Option<String>),
    /// `waycar chat-read <flags>`: the Chat Mode transcript reader the app
    /// runs over SSH (chat-read.js; not in the usage).
    ChatRead(Vec<String>),
    /// `waycar chat-media <flags>`: the inline media reader the app runs
    /// over SSH (chat-media.js; not in the usage).
    ChatMedia(Vec<String>),
    /// `waycar summaries refresh` and the herdr action `refresh-summaries`
    /// (refresh-summaries.js).
    SummariesRefresh,
}

impl Native {
    /// Started detached by an agent's hook or by herdr, which discard the
    /// output and must never see a failure: a setup error exits 0 without a
    /// word. The rest are run by a person or by the app, which want the error.
    pub fn is_detached_hook(&self) -> bool {
        matches!(
            self,
            Self::Notify(_)
                | Self::WatchApproval(_)
                | Self::HookSession(_)
                | Self::HookStatus(_)
                | Self::CodexDaemonHook(_)
                | Self::HerdrNotify
                | Self::HerdrActivity
                | Self::ActivityTick(_)
        )
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HooksAction {
    Install,
    Uninstall,
    Status,
    /// Rewrite the Node-era hook entries only (install.sh runs it, also
    /// under `--no-hooks`; not in the usage).
    Migrate,
}

impl Plan {
    fn print(stdout: impl Into<String>) -> Self {
        Self::Done {
            code: EXIT_OK,
            stdout: stdout.into(),
            stderr: String::new(),
        }
    }
}

/// Plan one invocation; `argv` is everything after the program name.
pub fn plan(argv: &[String]) -> Plan {
    match try_plan(argv) {
        Ok(plan) => plan,
        Err(error) => {
            let stderr = match &error {
                CliError::Usage(message) => format!("waycar: {message}\n{USAGE}"),
                CliError::Failure(message) => format!("waycar: {message}\n"),
            };
            Plan::Done {
                code: error.exit_code(),
                stdout: String::new(),
                stderr,
            }
        }
    }
}

fn try_plan(argv: &[String]) -> Result<Plan> {
    let Some((command, rest)) = argv.split_first() else {
        return Err(CliError::usage("missing command"));
    };
    match command.as_str() {
        "pair" => {
            expect_no_args(rest)?;
            Ok(Plan::Native(Native::Pair))
        }
        "pair-action" => Ok(Plan::Native(Native::PairAction(rest.to_vec()))),
        "pair-accept" => Ok(Plan::Native(Native::PairAccept(rest.to_vec()))),
        "reach-status" => Ok(Plan::Native(Native::ReachStatus(rest.to_vec()))),
        "config-dir" => {
            expect_no_args(rest)?;
            Ok(Plan::Native(Native::ConfigDir))
        }
        "hooks" => {
            let (action, json) = parse_hooks_args(rest)?;
            let action = match action {
                "install" => HooksAction::Install,
                "uninstall" => HooksAction::Uninstall,
                "migrate" => HooksAction::Migrate,
                _ => HooksAction::Status,
            };
            Ok(Plan::Native(Native::Hooks { action, json }))
        }
        "notify" => Ok(Plan::Native(Native::Notify(parse_notify_args(rest)?))),
        "watch-approval" => {
            parse_watch_args(rest)?;
            Ok(Plan::Native(Native::WatchApproval(rest.to_vec())))
        }
        // Internal commands: what agents' hook configs and the herdr manifest
        // run. Not in the usage text.
        "hook-session" => Ok(Plan::Native(Native::HookSession(rest.to_vec()))),
        "hook-status" => Ok(Plan::Native(Native::HookStatus(rest.to_vec()))),
        "codex-daemon-hook" => Ok(Plan::Native(Native::CodexDaemonHook(rest.to_vec()))),
        "opencode-push" => Ok(Plan::Native(Native::OpencodePush(rest.to_vec()))),
        "herdr-event" => match rest {
            [kind] if kind == "notify" => Ok(Plan::Native(Native::HerdrNotify)),
            [kind] if kind == "activity" => Ok(Plan::Native(Native::HerdrActivity)),
            _ => Err(CliError::usage("expected: herdr-event notify|activity")),
        },
        "herdr-startup" => {
            expect_no_args(rest)?;
            Ok(Plan::Native(Native::HerdrStartup))
        }
        "activity-tick" => Ok(Plan::Native(Native::ActivityTick(rest.first().cloned()))),
        "summaries" => {
            if rest != ["refresh"] {
                return Err(CliError::usage("expected: summaries refresh"));
            }
            Ok(Plan::Native(Native::SummariesRefresh))
        }
        // Not in the usage text: the app runs these over SSH (the chat reader and
        // its inline media reader).
        "chat-read" => Ok(Plan::Native(Native::ChatRead(rest.to_vec()))),
        "chat-media" => Ok(Plan::Native(Native::ChatMedia(rest.to_vec()))),
        "status" => Ok(Plan::Native(Native::Status {
            json: parse_json_flag(rest)?,
        })),
        "version" | "--version" => {
            expect_no_args(rest)?;
            Ok(Plan::print(format!("waycar {VERSION}\n")))
        }
        "help" | "--help" | "-h" => Ok(Plan::print(USAGE)),
        other => Err(CliError::usage(format!("unknown command: {other}"))),
    }
}

fn expect_no_args(rest: &[String]) -> Result<()> {
    match rest.first() {
        Some(arg) => Err(CliError::usage(format!("unexpected argument: {arg}"))),
        None => Ok(()),
    }
}

/// Accept nothing or a single `--json`; returns whether it was given.
pub fn parse_json_flag(rest: &[String]) -> Result<bool> {
    if rest == ["--json"] {
        return Ok(true);
    }
    expect_no_args(rest)?;
    Ok(false)
}

/// The action and whether `--json` was given.
pub fn parse_hooks_args(rest: &[String]) -> Result<(&str, bool)> {
    let Some((action, extra)) = rest.split_first() else {
        return Err(CliError::usage("expected: hooks install|uninstall|status"));
    };
    if !HOOK_ACTIONS.contains(&action.as_str()) {
        return Err(CliError::usage(format!("unknown hooks action: {action}")));
    }
    if action == "uninstall" || action == "migrate" {
        expect_no_args(extra)?;
        return Ok((action, false));
    }
    Ok((action, parse_json_flag(extra)?))
}

/// `^--([a-z]+)(?:=(.*))?$` the way JavaScript reads it: `.` stops at a line
/// terminator, so a value holding one is no match.
fn split_flag(arg: &str) -> Option<(&str, Option<&str>)> {
    let body = arg.strip_prefix("--")?;
    let name_len = body.bytes().take_while(u8::is_ascii_lowercase).count();
    if name_len == 0 {
        return None;
    }
    let (name, tail) = body.split_at(name_len);
    if tail.is_empty() {
        return Some((name, None));
    }
    let value = tail.strip_prefix('=')?;
    if value.contains(['\n', '\r', '\u{2028}', '\u{2029}']) {
        return None;
    }
    Some((name, Some(value)))
}

/// Parse `--<name> <value>` flags (also `--name=value`), each at most once,
/// for exactly the given names; a missing one is absent from the map.
pub fn parse_flags<'a>(rest: &'a [String], names: &[&str]) -> Result<BTreeMap<&'a str, &'a str>> {
    let mut values = BTreeMap::new();
    let mut i = 0;
    while i < rest.len() {
        let arg = &rest[i];
        let Some((name, inline)) = split_flag(arg).filter(|(name, _)| names.contains(name)) else {
            return Err(CliError::usage(format!("unexpected argument: {arg}")));
        };
        if values.contains_key(name) {
            return Err(CliError::usage(format!("--{name} given twice")));
        }
        let value = match inline {
            Some(value) => value,
            None => {
                i += 1;
                rest.get(i)
                    .map(String::as_str)
                    .ok_or_else(|| CliError::usage(format!("--{name} needs a value")))?
            }
        };
        values.insert(name, value);
        i += 1;
    }
    Ok(values)
}

/// A `--pane` value: a tmux pane id, prefixed (`tmux:%3`, as the hooks pass
/// it) or raw (`%3`). Returns the prefixed form.
pub fn parse_pane(pane: Option<&str>, command: &str) -> Result<String> {
    let Some(pane) = pane else {
        return Err(CliError::usage(format!("{command} needs --pane tmux:%N")));
    };
    let pane_id = if pane.starts_with("tmux:") {
        pane.to_string()
    } else {
        format!("tmux:{pane}")
    };
    if !crate::tmux::is_tmux_pane_id(&pane_id) {
        return Err(CliError::usage(format!(
            "bad pane id: {pane} (expected tmux:%N)"
        )));
    }
    Ok(pane_id)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NotifyArgs {
    pub pane_id: String,
    pub status: String,
}

/// Parse `--pane <id>` and `--status <s>` (also `--flag=value`).
pub fn parse_notify_args(rest: &[String]) -> Result<NotifyArgs> {
    let values = parse_flags(rest, &["pane", "status"])?;
    // Core terminals, shared Codex threads and OpenCode 2 sessions have their
    // own namespace; other ids retain tmux's validation and errors.
    let pane = values.get("pane").copied();
    let pane_id = match pane {
        Some(core_pane) if crate::core::is_core_pane_id(core_pane) => core_pane.to_string(),
        Some(pane) if crate::zellij::PaneId::parse(pane).is_some() => pane.to_string(),
        Some(session) if crate::opencode_hook::is_session_pane_id(session) => session.to_string(),
        Some(thread)
            if thread
                .strip_prefix("codex:")
                .is_some_and(|id| !id.is_empty()) =>
        {
            thread.to_string()
        }
        _ => parse_pane(pane, "notify")?,
    };
    let Some(status) = values.get("status").copied() else {
        return Err(CliError::usage(
            "notify needs --status working|idle|blocked|done|release",
        ));
    };
    if !PANE_STATUSES.contains(&status) {
        return Err(CliError::usage(format!(
            "bad status: {status} (expected working, idle, blocked, done or release)"
        )));
    }
    Ok(NotifyArgs {
        pane_id,
        status: status.to_string(),
    })
}

/// True for a `tmux -V` version this backend supports (3.2 or later).
pub fn tmux_supported(version: &str) -> bool {
    let bare = version.strip_prefix("tmux").map_or(version, |rest| {
        let trimmed = rest.trim_start();
        if trimmed.len() == rest.len() {
            version
        } else {
            trimmed
        }
    });
    let bare = bare.strip_prefix("next-").unwrap_or(bare);
    // OpenBSD's base tmux reports the OS release, and source builds "master";
    // both are newer than the floor.
    if bare.starts_with("openbsd-") || bare == "master" {
        return true;
    }
    let digits = |s: &str| s.bytes().take_while(u8::is_ascii_digit).count();
    let major_len = digits(bare);
    let Some(after_major) = bare[major_len..]
        .strip_prefix('.')
        .filter(|_| major_len > 0)
    else {
        return false;
    };
    let minor_len = digits(after_major);
    if minor_len == 0 {
        return false;
    }
    let (Ok(major), Ok(minor)) = (
        bare[..major_len].parse::<u64>(),
        after_major[..minor_len].parse::<u64>(),
    ) else {
        return false;
    };
    (major, minor) >= (3, 2)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    fn stderr_of(list: &[&str]) -> String {
        match plan(&args(list)) {
            Plan::Done {
                code: 2, stderr, ..
            } => stderr,
            other => panic!("expected a usage error, got {other:?}"),
        }
    }

    #[test]
    fn version_is_native_and_help_prints_the_usage() {
        assert_eq!(
            plan(&args(&["version"])),
            Plan::Done {
                code: 0,
                stdout: format!("waycar {VERSION}\n"),
                stderr: String::new()
            }
        );
        assert_eq!(plan(&args(&["-h", "ignored"])), Plan::print(USAGE));
    }

    #[test]
    fn usage_errors_carry_the_usage_text() {
        assert!(
            stderr_of(&["bogus"])
                .starts_with("waycar: unknown command: bogus\nusage: waycar <command>\n")
        );
        assert!(stderr_of(&[]).starts_with("waycar: missing command\n"));
        assert!(stderr_of(&["version", "x"]).starts_with("waycar: unexpected argument: x\n"));
    }

    #[test]
    fn flags_follow_the_js_grammar() {
        let ok = args(&["--pane=%7", "--status", "done"]);
        assert_eq!(
            parse_notify_args(&ok).unwrap(),
            NotifyArgs {
                pane_id: "tmux:%7".into(),
                status: "done".into()
            }
        );
        for (list, message) in [
            (&["--pane", "%7", "--pane", "%8"][..], "--pane given twice"),
            (&["--pane"][..], "--pane needs a value"),
            (&["--Pane", "%7"][..], "unexpected argument: --Pane"),
            (
                &["--pane=a\nb", "--status", "done"][..],
                "unexpected argument: --pane=a\nb",
            ),
            (&["--status", "done"][..], "notify needs --pane tmux:%N"),
            (
                &["--pane", "tmux:%x", "--status", "done"][..],
                "bad pane id: tmux:%x (expected tmux:%N)",
            ),
            (
                &["--pane", "%1"][..],
                "notify needs --status working|idle|blocked|done|release",
            ),
            (
                &["--pane", "%1", "--status", "x"][..],
                "bad status: x (expected working, idle, blocked, done or release)",
            ),
        ] {
            assert_eq!(
                parse_notify_args(&args(list)).unwrap_err(),
                CliError::usage(message),
                "{list:?}"
            );
        }
    }

    #[test]
    fn notify_accepts_a_herdr_core_terminal_and_nothing_else_changes() {
        for (pane, want) in [("hc:t1", "hc:t1"), ("hc:box/t3", "hc:box/t3")] {
            assert_eq!(
                parse_notify_args(&args(&["--pane", pane, "--status", "idle"])).unwrap(),
                NotifyArgs {
                    pane_id: want.into(),
                    status: "idle".into()
                }
            );
        }
        // A core id with a bad address is still a bad tmux pane, word for word.
        for (pane, message) in [
            ("hc:", "bad pane id: hc: (expected tmux:%N)"),
            ("hc:-x", "bad pane id: hc:-x (expected tmux:%N)"),
            ("hc:a b", "bad pane id: hc:a b (expected tmux:%N)"),
            ("t1", "bad pane id: t1 (expected tmux:%N)"),
            ("herdr:1", "bad pane id: herdr:1 (expected tmux:%N)"),
        ] {
            assert_eq!(
                parse_notify_args(&args(&["--pane", pane, "--status", "idle"])).unwrap_err(),
                CliError::usage(message),
                "{pane}"
            );
        }
        // Only notify takes a core pane: watch-approval stays a tmux watcher.
        assert_eq!(
            parse_pane(Some("hc:t1"), "watch-approval").unwrap_err(),
            CliError::usage("bad pane id: hc:t1 (expected tmux:%N)")
        );
    }

    #[test]
    fn the_hook_runtime_commands_plan_native() {
        assert_eq!(
            plan(&args(&["notify", "--pane", "%7", "--status", "done"])),
            Plan::Native(Native::Notify(NotifyArgs {
                pane_id: "tmux:%7".into(),
                status: "done".into()
            }))
        );
        assert_eq!(
            plan(&args(&["herdr-event", "activity"])),
            Plan::Native(Native::HerdrActivity)
        );
        assert_eq!(
            plan(&args(&["herdr-startup"])),
            Plan::Native(Native::HerdrStartup)
        );
        assert_eq!(
            plan(&args(&["hook-session", "claude", "Stop"])),
            Plan::Native(Native::HookSession(args(&["claude", "Stop"])))
        );
        assert_eq!(
            plan(&args(&["hook-status", "claude", "working"])),
            Plan::Native(Native::HookStatus(args(&["claude", "working"])))
        );
        assert_eq!(
            plan(&args(&["activity-tick", "{}"])),
            Plan::Native(Native::ActivityTick(Some("{}".into())))
        );
        assert_eq!(
            plan(&args(&["hooks", "migrate"])),
            Plan::Native(Native::Hooks {
                action: HooksAction::Migrate,
                json: false
            })
        );
        assert!(
            stderr_of(&["hooks", "migrate", "--json"])
                .starts_with("waycar: unexpected argument: --json\n")
        );
        assert!(
            stderr_of(&["herdr-event", "bogus"])
                .starts_with("waycar: expected: herdr-event notify|activity\n")
        );
        assert!(
            stderr_of(&["watch-approval", "--pane", "%1", "--agent", "nobody"])
                .starts_with("waycar: watch-approval needs --agent ")
        );
    }

    #[test]
    fn tmux_versions_at_or_above_3_2_are_supported() {
        for yes in [
            "3.2",
            "3.2a",
            "3.7c",
            "10.0",
            "next-3.6",
            "tmux 3.4",
            "openbsd-7.4",
            "master",
        ] {
            assert!(tmux_supported(yes), "{yes}");
        }
        for no in ["3.1c", "2.9", "", "3", "3.", "abc", "next-2.9", "tmux"] {
            assert!(!tmux_supported(no), "{no}");
        }
    }
}
