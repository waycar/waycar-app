//! `waycar pair-action`: herdr's "Pair a mobile device" action, which opens the
//! pairing popup pane (pair-action.js).
//!
//! Actions run headless; the interactive checklist and QR live in the popup
//! pane entrypoint. Calling back through `HERDR_BIN_PATH` keeps this portable
//! across socket transports.

use std::io::{self, Write};
use std::process::Command;

use crate::native::Ctx;

/// What `HERDR_BIN_PATH` and `HERDR_PLUGIN_ID` default to.
const DEFAULT_HERDR: &str = "herdr";
const DEFAULT_PLUGIN: &str = "waycar";

/// Node's name for an errno it reports on a failed spawn (`ENOENT`, ...).
fn errno_name(code: i32) -> Option<&'static str> {
    [
        (libc::ENOENT, "ENOENT"),
        (libc::EACCES, "EACCES"),
        (libc::EPERM, "EPERM"),
        (libc::ENOTDIR, "ENOTDIR"),
        (libc::EISDIR, "EISDIR"),
        (libc::ELOOP, "ELOOP"),
        (libc::ENAMETOOLONG, "ENAMETOOLONG"),
        (libc::ENOEXEC, "ENOEXEC"),
        (libc::E2BIG, "E2BIG"),
        (libc::ENOMEM, "ENOMEM"),
        (libc::EAGAIN, "EAGAIN"),
        (libc::EMFILE, "EMFILE"),
        (libc::ETXTBSY, "ETXTBSY"),
    ]
    .into_iter()
    .find_map(|(errno, name)| (errno == code).then_some(name))
}

/// The text of Node's `spawnSync` error for a program that cannot start.
fn spawn_error_message(herdr: &str, error: &io::Error) -> String {
    if herdr.is_empty() {
        return "The argument 'file' cannot be empty. Received ''".to_string();
    }
    match error.raw_os_error().and_then(errno_name) {
        Some(name) => format!("spawnSync {herdr} {name}"),
        None => error.to_string(),
    }
}

pub fn run(ctx: &Ctx, _args: &[String], _out: &mut dyn Write, err: &mut dyn Write) -> i32 {
    let herdr = ctx.env.get("HERDR_BIN_PATH").unwrap_or(DEFAULT_HERDR);
    let plugin = ctx.env.get("HERDR_PLUGIN_ID").unwrap_or(DEFAULT_PLUGIN);
    let status = if herdr.is_empty() {
        Err(io::Error::from(io::ErrorKind::InvalidInput))
    } else {
        Command::new(herdr)
            .args([
                "plugin",
                "pane",
                "open",
                "--plugin",
                plugin,
                "--entrypoint",
                "pair",
            ])
            .env_clear()
            .envs(ctx.env.iter())
            .status()
    };
    match status {
        Ok(status) => status.code().unwrap_or(1),
        Err(error) => {
            let _ = writeln!(
                err,
                "failed to run herdr: {}",
                spawn_error_message(herdr, &error)
            );
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::env::Env;
    use crate::test_support::TempDir;
    use std::fs;
    use std::path::Path;

    fn ctx(dir: &Path, pairs: &[(&str, &str)]) -> Ctx {
        Ctx {
            env: Env::from_pairs(
                pairs
                    .iter()
                    .map(|&(k, v)| (k, v))
                    .chain([("PATH", "/usr/bin:/bin")]),
            ),
            home: dir.to_path_buf(),
            plugin_root: dir.to_path_buf(),
        }
    }

    fn script(path: &Path, body: &str, mode: u32) {
        crate::test_support::write_script(path, body, mode);
    }

    fn run_with(ctx: &Ctx) -> (i32, String) {
        let mut err = Vec::new();
        let code = run(ctx, &[], &mut Vec::new(), &mut err);
        (code, String::from_utf8(err).unwrap())
    }

    #[test]
    fn opens_the_pair_entrypoint_and_answers_with_herdrs_exit_code() {
        let dir = TempDir::new("pair-action");
        let herdr = dir.path().join("herdr");
        let args = dir.path().join("args");
        script(
            &herdr,
            &format!("printf '%s\\n' \"$@\" > '{}'\nexit 3", args.display()),
            0o755,
        );
        let ctx = ctx(
            dir.path(),
            &[
                ("HERDR_BIN_PATH", herdr.to_str().unwrap()),
                ("HERDR_PLUGIN_ID", "waycar-dev"),
            ],
        );
        assert_eq!(run_with(&ctx), (3, String::new()));
        assert_eq!(
            fs::read_to_string(args).unwrap(),
            "plugin\npane\nopen\n--plugin\nwaycar-dev\n--entrypoint\npair\n"
        );
    }

    #[test]
    fn the_plugin_id_defaults_to_waycar() {
        let dir = TempDir::new("pair-action-default");
        let herdr = dir.path().join("herdr");
        let args = dir.path().join("args");
        script(
            &herdr,
            &format!("printf '%s\\n' \"$@\" > '{}'", args.display()),
            0o755,
        );
        let ctx = ctx(dir.path(), &[("HERDR_BIN_PATH", herdr.to_str().unwrap())]);
        assert_eq!(run_with(&ctx).0, 0);
        assert!(
            fs::read_to_string(args)
                .unwrap()
                .contains("--plugin\nwaycar\n")
        );
    }

    #[test]
    fn a_herdr_killed_by_a_signal_exits_one_without_a_message() {
        let dir = TempDir::new("pair-action-signal");
        let herdr = dir.path().join("herdr");
        script(&herdr, "kill -9 $$", 0o755);
        let ctx = ctx(dir.path(), &[("HERDR_BIN_PATH", herdr.to_str().unwrap())]);
        assert_eq!(run_with(&ctx), (1, String::new()));
    }

    #[test]
    fn a_herdr_that_cannot_start_prints_nodes_spawn_error_and_exits_one() {
        let dir = TempDir::new("pair-action-missing");
        let missing = dir.path().join("none");
        let ctx = ctx(dir.path(), &[("HERDR_BIN_PATH", missing.to_str().unwrap())]);
        assert_eq!(
            run_with(&ctx),
            (
                1,
                format!(
                    "failed to run herdr: spawnSync {} ENOENT\n",
                    missing.display()
                )
            )
        );
        let plain = dir.path().join("plain");
        script(&plain, "exit 0", 0o644);
        let ctx = self::ctx(dir.path(), &[("HERDR_BIN_PATH", plain.to_str().unwrap())]);
        assert_eq!(
            run_with(&ctx),
            (
                1,
                format!(
                    "failed to run herdr: spawnSync {} EACCES\n",
                    plain.display()
                )
            )
        );
    }

    #[test]
    fn herdr_is_looked_up_on_path_by_default() {
        let dir = TempDir::new("pair-action-path");
        script(&dir.path().join("herdr"), "exit 5", 0o755);
        let ctx = Ctx {
            env: Env::from_pairs([("PATH", dir.path().to_str().unwrap())]),
            home: dir.path().to_path_buf(),
            plugin_root: dir.path().to_path_buf(),
        };
        assert_eq!(run_with(&ctx).0, 5);
    }
}
