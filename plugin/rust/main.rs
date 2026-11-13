use std::ffi::OsString;
use std::io::{IsTerminal, Write};
use std::process::ExitCode;

use waycar::cli::{Native, Plan, plan};
use waycar::env::Env;
use waycar::error::EXIT_FAILURE;
use waycar::native::{self, Ctx, Io};
use waycar::paths::{home_dir, plugin_root_of};

fn main() -> ExitCode {
    let args: Vec<OsString> = std::env::args_os().skip(1).collect();
    let text: Vec<String> = args
        .iter()
        .map(|a| a.to_string_lossy().into_owned())
        .collect();
    match plan(&text) {
        Plan::Done {
            code,
            stdout,
            stderr,
        } => {
            // A closed pipe is the reader's choice, not a failure.
            let _ = std::io::stdout().write_all(stdout.as_bytes());
            let _ = std::io::stderr().write_all(stderr.as_bytes());
            ExitCode::from(u8::try_from(code).unwrap_or(1))
        }
        Plan::Native(command) => run_native(&command, command.is_detached_hook()),
    }
}

/// Run a subcommand in Rust with the process's own environment.
///
/// `detached`: an agent's hook started it and discards the output, so a setup
/// failure (no home directory, the binary replaced mid-run) exits 0 without
/// output. The agent never sees a failed hook.
fn run_native(command: &Native, detached: bool) -> ExitCode {
    let env = Env::from_process();
    let ctx = match (
        home_dir(&env),
        std::env::current_exe()
            .map_err(Into::into)
            .and_then(|exe| plugin_root_of(&exe)),
    ) {
        (Some(home), Ok(plugin_root)) => Ctx {
            env,
            home,
            plugin_root,
        },
        _ if detached => return ExitCode::SUCCESS,
        (None, _) => {
            eprintln!("waycar: cannot find the home directory");
            return ExitCode::from(EXIT_FAILURE as u8);
        }
        (_, Err(error)) => {
            eprintln!("waycar: {error}");
            return ExitCode::from(EXIT_FAILURE as u8);
        }
    };
    // Unlocked on purpose: `Stderr` and `Stdout` lock per write. Holding the
    // lock here would block the watch's notifier threads, which write to
    // stderr while this thread waits for them.
    let (mut stdin, mut stdout, mut stderr) =
        (std::io::stdin(), std::io::stdout(), std::io::stderr());
    let mut io = Io {
        stdin_is_tty: stdin.is_terminal(),
        stdin: &mut stdin,
        stdout: &mut stdout,
        stderr: &mut stderr,
    };
    let code = native::run(command, &ctx, &mut io);
    ExitCode::from(u8::try_from(code).unwrap_or(1))
}
