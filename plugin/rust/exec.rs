//! Running programs the way the JS host tools do (`runProgram` in
//! tmux-adapter.js, `findOnPath` in waycar-cli.js): no shell, lookup through
//! the environment's own `PATH`, 10 s limit, never an error.

use std::io::Read;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use crate::env::Env;

pub const RUN_TIMEOUT: Duration = Duration::from_secs(10);
const DEFAULT_PATH: &str = "/usr/bin:/bin";
/// What a program that could not be started answers, like a shell's.
pub const EXIT_NOT_STARTED: i32 = 127;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RunResult {
    pub stdout: String,
    pub stderr: String,
    pub code: i32,
}

impl RunResult {
    fn not_started(message: String) -> Self {
        Self {
            stdout: String::new(),
            stderr: message,
            code: EXIT_NOT_STARTED,
        }
    }
}

/// Absolute path of an executable regular file `name` on `env`'s `PATH`
/// (findOnPath); none when `PATH` is unset. A name with a slash is taken as is.
pub fn find_on_path(name: &str, env: &Env) -> Option<PathBuf> {
    lookup(name, env.get("PATH").unwrap_or(""))
}

/// Looks `name` up in the `:`-separated `path`. An empty entry is skipped, as
/// `find_on_path` does in JS. Node's `spawn` would take it as the working
/// directory (execvp's rule), so `PATH=":/usr/bin"` runs `./foo` there and
/// this answers 127; running a program from the working directory because of
/// a stray colon is a hazard, and no caller relies on it.
fn lookup(name: &str, path: &str) -> Option<PathBuf> {
    if name.contains('/') {
        return is_executable_file(Path::new(name)).then(|| PathBuf::from(name));
    }
    path.split(':')
        .filter(|dir| !dir.is_empty())
        .map(|dir| Path::new(dir).join(name))
        .find(|candidate| is_executable_file(candidate))
}

fn is_executable_file(path: &Path) -> bool {
    match std::fs::metadata(path) {
        // Any execute bit is a hint; access(2) answers for this process.
        Ok(meta) if meta.is_file() && meta.permissions().mode() & 0o111 != 0 => {
            let Ok(c_path) = std::ffi::CString::new(path.as_os_str().as_encoded_bytes()) else {
                return false;
            };
            // SAFETY: c_path is a valid NUL-terminated string for the call.
            unsafe { libc::access(c_path.as_ptr(), libc::X_OK) == 0 }
        }
        _ => false,
    }
}

/// Run `cmd` with `args` and exactly `env` (looked up through `env`'s
/// `PATH`), stdin closed, killed with SIGTERM after [`RUN_TIMEOUT`]. Never
/// fails: a program that cannot be started answers exit 127 with the reason
/// in `stderr`, a program killed by a signal exit 1.
pub fn run_program(cmd: &str, args: &[&str], env: &Env) -> RunResult {
    run_program_with_timeout(cmd, args, env, RUN_TIMEOUT)
}

pub fn run_program_with_timeout(
    cmd: &str,
    args: &[&str],
    env: &Env,
    timeout: Duration,
) -> RunResult {
    // Spawn looks the program up in the child's own PATH; with none set, in
    // the C library's default, as Node's spawn does.
    let Some(program) = lookup(cmd, env.get("PATH").unwrap_or(DEFAULT_PATH)) else {
        return RunResult::not_started(format!("spawn {cmd} ENOENT"));
    };
    let mut command = Command::new(&program);
    command
        .args(args)
        .env_clear()
        .envs(env.iter())
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(error) => return RunResult::not_started(format!("spawn {cmd} failed: {error}")),
    };

    let drain = |pipe: Option<Box<dyn Read + Send>>| {
        thread::spawn(move || {
            let mut bytes = Vec::new();
            if let Some(mut pipe) = pipe {
                let _ = pipe.read_to_end(&mut bytes);
            }
            String::from_utf8_lossy(&bytes).into_owned()
        })
    };
    let stdout = drain(
        child
            .stdout
            .take()
            .map(|p| Box::new(p) as Box<dyn Read + Send>),
    );
    let stderr = drain(
        child
            .stderr
            .take()
            .map(|p| Box::new(p) as Box<dyn Read + Send>),
    );

    let deadline = Instant::now() + timeout;
    let mut terminated = false;
    let mut pause = Duration::from_millis(1);
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Some(status),
            Ok(None) => {}
            Err(_) => break None,
        }
        if !terminated && Instant::now() >= deadline {
            // SAFETY: the pid belongs to our un-reaped child.
            unsafe { libc::kill(child.id() as libc::pid_t, libc::SIGTERM) };
            terminated = true;
        }
        thread::sleep(pause);
        pause = (pause * 2).min(Duration::from_millis(20));
    };

    RunResult {
        stdout: stdout.join().unwrap_or_default(),
        stderr: stderr.join().unwrap_or_default(),
        code: status.and_then(|s| s.code()).unwrap_or(1),
    }
}
