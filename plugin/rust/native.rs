//! Runs the subcommands Rust owns ([`crate::cli::Native`]).
//!
//! Each command module has one entry point taking the [`Ctx`] and the two
//! output streams, and returning the exit code. Output goes through the
//! writers so a test can capture it; the interactive pairing popup also uses
//! the real terminal.

use std::io::{Read, Write};
use std::path::PathBuf;

use crate::cli::{HooksAction, Native};
use crate::env::Env;
use crate::error::{CliError, EXIT_FAILURE, EXIT_OK};
use crate::hooks::{self, HooksResult};
use crate::status;

/// What every command runs with: the environment it was given, the account
/// home, and the installed plugin directory (the parent of the `bin`
/// directory holding this binary).
#[derive(Debug, Clone)]
pub struct Ctx {
    pub env: Env,
    pub home: PathBuf,
    pub plugin_root: PathBuf,
}

/// The process's streams, passed in so each command is testable.
pub struct Io<'a> {
    pub stdin: &'a mut dyn Read,
    /// Whether stdin is a terminal (`process.stdin.isTTY`).
    pub stdin_is_tty: bool,
    pub stdout: &'a mut dyn Write,
    pub stderr: &'a mut dyn Write,
}

/// Run `native` with the streams in `io`; returns the exit code.
pub fn run(native: &Native, ctx: &Ctx, io: &mut Io<'_>) -> i32 {
    match native {
        Native::ChatRead(args) => {
            crate::chat::read::run(args, &ctx.env, &ctx.home.to_string_lossy(), io)
        }
        Native::ChatMedia(args) => {
            crate::chat::media::run(args, &ctx.env, &ctx.home.to_string_lossy(), io)
        }
        Native::SummariesRefresh => {
            crate::summary::refresh::run(&ctx.env, &ctx.home.to_string_lossy(), io)
        }
        Native::Pair => crate::pair::run(ctx, io.stdout, io.stderr),
        Native::PairAction(args) => crate::pair_action::run(ctx, args, io.stdout, io.stderr),
        Native::PairAccept(args) => crate::pair_accept::run(ctx, args, io.stdout, io.stderr),
        Native::ReachStatus(args) => crate::reach_status::run(ctx, args, io.stdout, io.stderr),
        Native::ConfigDir => finish(status::print_config_dir(ctx, io.stdout), io.stderr),
        Native::Status { json } => finish(status::run(ctx, *json, io.stdout), io.stderr),
        Native::Hooks { action, json } => {
            finish(run_hooks(ctx, *action, *json, io.stdout), io.stderr)
        }
        // The hook runtime: push, Live Activity and the hook entry points.
        Native::Notify(_)
        | Native::WatchApproval(_)
        | Native::HookSession(_)
        | Native::HookStatus(_)
        | Native::CodexDaemonHook(_)
        | Native::OpencodePush(_)
        | Native::HerdrNotify
        | Native::HerdrActivity
        | Native::HerdrStartup
        | Native::ActivityTick(_) => {
            crate::hook_runtime::run(native, ctx, io.stderr).unwrap_or(EXIT_FAILURE)
        }
    }
}

/// The hook operations; production is [`hooks`], a test passes fakes.
pub struct HooksApi {
    pub install: fn(&Ctx) -> Result<HooksResult, CliError>,
    pub uninstall: fn(&Ctx) -> Result<HooksResult, CliError>,
    pub status: fn(&Ctx) -> Result<HooksResult, CliError>,
    pub migrate: fn(&Ctx) -> Result<HooksResult, CliError>,
}

const HOOKS: HooksApi = HooksApi {
    install: hooks::install,
    uninstall: hooks::uninstall,
    status: hooks::status,
    migrate: hooks::migrate_legacy,
};

fn run_hooks(
    ctx: &Ctx,
    action: HooksAction,
    json: bool,
    out: &mut dyn Write,
) -> Result<(), CliError> {
    run_hooks_with(ctx, action, json, out, &HOOKS)
}

/// `waycar hooks <action> [--json]`: print the lines the action returns, or
/// with `--json` the host report of the state after it (what `status --json`
/// prints).
fn run_hooks_with(
    ctx: &Ctx,
    action: HooksAction,
    json: bool,
    out: &mut dyn Write,
    api: &HooksApi,
) -> Result<(), CliError> {
    let result = match action {
        HooksAction::Install => (api.install)(ctx)?,
        HooksAction::Uninstall => (api.uninstall)(ctx)?,
        HooksAction::Status => (api.status)(ctx)?,
        HooksAction::Migrate => (api.migrate)(ctx)?,
    };
    if json {
        let after = match action {
            HooksAction::Status => result,
            _ => (api.status)(ctx)?,
        };
        status::write_report(ctx, &after, out)?;
    } else {
        for line in &result.lines {
            writeln!(out, "{line}")?;
        }
    }
    Ok(())
}

/// A failed command prints `waycar: <message>` and exits 1, as the JS does.
fn finish(result: Result<(), CliError>, err: &mut dyn Write) -> i32 {
    match result {
        Ok(()) => EXIT_OK,
        Err(error) => {
            let _ = writeln!(err, "waycar: {error}");
            EXIT_FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::status::tests::{Scratch, row, sample_hooks};

    fn lines(list: &[&str]) -> Result<HooksResult, CliError> {
        Ok(HooksResult {
            agents: Vec::new(),
            lines: list.iter().map(|l| l.to_string()).collect(),
        })
    }

    fn fake_install(_: &Ctx) -> Result<HooksResult, CliError> {
        lines(&["changed ~/.claude/settings.json", "Codex: review in /hooks"])
    }

    fn fake_uninstall(_: &Ctx) -> Result<HooksResult, CliError> {
        lines(&["removed"])
    }

    fn fake_migrate(_: &Ctx) -> Result<HooksResult, CliError> {
        lines(&[])
    }

    fn fake_status(ctx: &Ctx) -> Result<HooksResult, CliError> {
        let mut result = sample_hooks(ctx)?;
        result.agents.truncate(1);
        result.agents[0] = row("claude", true);
        Ok(result)
    }

    const FAKES: HooksApi = HooksApi {
        install: fake_install,
        uninstall: fake_uninstall,
        status: fake_status,
        migrate: fake_migrate,
    };

    fn hooks_output(scratch: &Scratch, action: HooksAction, json: bool, api: &HooksApi) -> String {
        let mut out = Vec::new();
        run_hooks_with(&scratch.ctx, action, json, &mut out, api).unwrap();
        String::from_utf8(out).unwrap()
    }

    #[test]
    fn install_prints_its_lines() {
        let scratch = Scratch::new("hk-install");
        assert_eq!(
            hooks_output(&scratch, HooksAction::Install, false, &FAKES),
            "changed ~/.claude/settings.json\nCodex: review in /hooks\n"
        );
    }

    #[test]
    fn uninstall_and_status_print_their_lines() {
        let scratch = Scratch::new("hk-lines");
        assert_eq!(
            hooks_output(&scratch, HooksAction::Uninstall, false, &FAKES),
            "removed\n"
        );
        assert_eq!(
            hooks_output(&scratch, HooksAction::Status, false, &FAKES),
            "claude: installed\ncodex: installed (review in /hooks)\n"
        );
    }

    #[test]
    fn a_failing_operation_exits_1_with_its_message_and_prints_nothing_else() {
        fn failing(_: &Ctx) -> Result<HooksResult, CliError> {
            Err(CliError::failure("settings.json is not JSON"))
        }
        let scratch = Scratch::new("hk-fail");
        let api = HooksApi {
            install: failing,
            ..FAKES
        };
        let mut out = Vec::new();
        let mut err = Vec::new();
        let result = run_hooks_with(&scratch.ctx, HooksAction::Install, false, &mut out, &api);
        assert_eq!(finish(result, &mut err), 1);
        assert!(out.is_empty());
        assert_eq!(
            String::from_utf8(err).unwrap(),
            "waycar: settings.json is not JSON\n"
        );
    }

    #[test]
    fn install_json_reports_the_state_after_the_install() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        // The install must run before the status the report is built from.
        static STEP: AtomicUsize = AtomicUsize::new(0);
        fn install(_: &Ctx) -> Result<HooksResult, CliError> {
            assert_eq!(STEP.fetch_add(1, Ordering::SeqCst), 0);
            Ok(HooksResult::default())
        }
        fn status(ctx: &Ctx) -> Result<HooksResult, CliError> {
            assert_eq!(STEP.fetch_add(1, Ordering::SeqCst), 1);
            fake_status(ctx)
        }
        let scratch = Scratch::new("hk-json");
        let api = HooksApi {
            install,
            status,
            ..FAKES
        };
        let text = hooks_output(&scratch, HooksAction::Install, true, &api);
        assert_eq!(STEP.load(Ordering::SeqCst), 2);
        let report: serde_json::Value = serde_json::from_str(&text).unwrap();
        assert_eq!(report["agents"][0]["agent"], "claude");
        assert_eq!(report["agents"][0]["installed"], true);
    }

    #[test]
    fn hooks_status_json_matches_status_json() {
        let scratch = Scratch::new("hk-same");
        let from_hooks = hooks_output(&scratch, HooksAction::Status, true, &FAKES);
        let mut from_status = Vec::new();
        status::run_with(&scratch.ctx, true, &mut from_status, &fake_status).unwrap();
        assert_eq!(from_hooks, String::from_utf8(from_status).unwrap());
    }
}
