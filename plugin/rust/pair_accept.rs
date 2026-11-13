//! `waycar pair-accept`: the Enrollment accept entrypoint, the sshd forced
//! command behind a Bootstrap Key (pair-accept.js, ADR 0007).
//!
//! The app connects with the Bootstrap Key and writes its Device Key public
//! line to stdin. On success the Device Key is appended atomically and the
//! bootstrap line self-revokes (single use). Invalid submissions consume
//! nothing, so the app may retry within the TTL.
//!
//! stdout speaks a one-line protocol the app parses:
//!
//! ```text
//! HERDR-ENROLL:OK:<SHA256:fingerprint>
//! HERDR-ENROLL:ERR:<unknown_pairing|expired|invalid_key|no_input>
//! ```
//!
//! Human-readable detail goes to stderr.

use std::io::{Read, Write};
use std::path::Path;
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use serde_json::Value;

use crate::authorized_keys::{edit_authorized_keys, key_blob_of, parse_bootstrap_line};
use crate::device_key::parse_device_key_line;
use crate::error::{CliError, EXIT_FAILURE, EXIT_OK, Result};
use crate::jsx;
use crate::native::Ctx;
use crate::pairing_session::{
    Enrollment, end_pairing, now_seconds, pending_path, read_json, record_enrollment, remove_force,
};

const MAX_INPUT_BYTES: usize = 4096;
const INPUT_TIMEOUT: Duration = Duration::from_secs(30);
/// What one read of stdin takes at most, as a Node stream chunk does.
const READ_CHUNK: usize = 64 * 1024;

/// How an accept ended: the protocol line for stdout, plus stderr detail on
/// failure.
enum Outcome {
    Enrolled { fingerprint: String },
    Rejected { code: &'static str, detail: String },
}

fn rejected(code: &'static str, detail: String) -> Result<Outcome> {
    Ok(Outcome::Rejected { code, detail })
}

/// `waycar pair-accept --state-dir D --pairing-id I`; the Device Key line is
/// read from stdin.
pub fn run(ctx: &Ctx, args: &[String], out: &mut dyn Write, err: &mut dyn Write) -> i32 {
    accept(
        ctx,
        args,
        Box::new(std::io::stdin()),
        INPUT_TIMEOUT,
        out,
        err,
    )
}

fn accept(
    ctx: &Ctx,
    args: &[String],
    input: Box<dyn Read + Send>,
    timeout: Duration,
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> i32 {
    // Stdout and stderr are the protocol's channels; a reader that went away
    // is not a failure of the accept.
    match try_accept(ctx, args, input, timeout) {
        Ok(Outcome::Enrolled { fingerprint }) => {
            let _ = writeln!(out, "HERDR-ENROLL:OK:{fingerprint}");
            EXIT_OK
        }
        Ok(Outcome::Rejected { code, detail }) => {
            let _ = writeln!(out, "HERDR-ENROLL:ERR:{code}");
            let _ = writeln!(err, "{detail}");
            EXIT_FAILURE
        }
        Err(error) => {
            let _ = writeln!(err, "{error}");
            EXIT_FAILURE
        }
    }
}

fn try_accept(
    ctx: &Ctx,
    args: &[String],
    input: Box<dyn Read + Send>,
    timeout: Duration,
) -> Result<Outcome> {
    let parsed = parse_args(args).map_err(|e| CliError::failure(e.to_string()))?;
    let (Some(state_dir), Some(pairing_id), Some(home)) = (
        parsed.state_dir.filter(|v| !v.is_empty()),
        parsed.pairing_id.filter(|v| !v.is_empty()),
        ctx.env.non_empty("HOME"),
    ) else {
        return rejected(
            "unknown_pairing",
            "pair-accept requires --state-dir, --pairing-id, and HOME".into(),
        );
    };
    let (state_dir, home) = (Path::new(&state_dir), Path::new(home));

    let pending = match read_json(&pending_path(state_dir, &pairing_id)) {
        // Unknown, already completed, or already cleaned up. Self-heal any
        // leftover line for this id before rejecting.
        None => {
            end_pairing(home, state_dir, &pairing_id)?;
            return rejected(
                "unknown_pairing",
                format!("no pending pairing {pairing_id}"),
            );
        }
        Some(Value::Null) => {
            return Err(CliError::failure(
                "TypeError: Cannot read properties of null (reading 'expiresAt')",
            ));
        }
        Some(pending) => pending,
    };
    // The expiry as a number; a record this program did not write, with none,
    // never expires.
    let expires_at = pending.get("expiresAt").and_then(Value::as_f64);
    let expired = |now: i64| expires_at.is_some_and(|expires_at| now as f64 > expires_at);
    let expired_detail = format!("pairing {pairing_id} expired; regenerate the Pairing Code");

    if expired(now_seconds()) {
        end_pairing(home, state_dir, &pairing_id)?;
        return rejected("expired", expired_detail);
    }

    let submission = read_submission(input, timeout);
    if jsx::trim(&submission).is_empty() {
        return rejected(
            "no_input",
            "expected a Device Key public line on stdin".into(),
        );
    }
    let device_key = match parse_device_key_line(&submission) {
        Ok(device_key) => device_key,
        Err(error) => {
            return rejected("invalid_key", format!("rejected Device Key line: {error}"));
        }
    };

    // One locked edit enrolls the Device Key and self-revokes the bootstrap
    // line. Pending state is deleted inside the critical section so a racing
    // second connection cannot enroll twice with the same Bootstrap Key, and
    // the Enrollment record is written inside it too, so the popup's locked
    // expiry check (expire_pairing) can never miss an enroll that already
    // happened: it would render "expired" over a silently enrolled device.
    let pending_file = pending_path(state_dir, &pairing_id);
    let mut verdict = Verdict::Enrolled;
    edit_authorized_keys(home, |lines| {
        if !pending_file.exists() {
            verdict = Verdict::AlreadyUsed;
            return Ok(None);
        }
        let mut kept: Vec<String> = lines
            .into_iter()
            .filter(|line| parse_bootstrap_line(line).is_none_or(|m| m.pairing_id != pairing_id))
            .collect();
        remove_force(&pending_file)?;
        // Re-validate expiry inside the lock: the stdin read can block for up
        // to the input timeout, so the TTL may have lapsed since the check
        // before it. Still revoke the bootstrap line, but do not enroll the
        // Device Key.
        if expired(now_seconds()) {
            verdict = Verdict::Expired;
            return Ok(Some(kept));
        }
        let identity = key_blob_of(&device_key.line);
        if !kept.iter().any(|line| key_blob_of(line) == identity) {
            kept.push(device_key.line.clone());
        }
        // The record the popup polls for: the enrolled fingerprint plus the
        // appended line, its one-key revoke target.
        record_enrollment(
            state_dir,
            &Enrollment {
                pairing_id: pairing_id.clone(),
                expires_at: expires_at.map(|e| e as i64),
                fingerprint: device_key.fingerprint.clone(),
                line: device_key.line.clone(),
            },
        )?;
        Ok(Some(kept))
    })?;
    match verdict {
        Verdict::AlreadyUsed => rejected(
            "unknown_pairing",
            format!("pairing {pairing_id} was already used"),
        ),
        Verdict::Expired => rejected("expired", expired_detail),
        Verdict::Enrolled => Ok(Outcome::Enrolled {
            fingerprint: device_key.fingerprint,
        }),
    }
}

/// What the locked edit found.
enum Verdict {
    Enrolled,
    AlreadyUsed,
    Expired,
}

/// Read stdin until the first newline, EOF, a size cap, or a timeout, and
/// return the first line.
fn read_submission(mut input: Box<dyn Read + Send>, timeout: Duration) -> String {
    let (chunks, received) = mpsc::channel();
    // A reader still blocked at the timeout is left behind: the process
    // exits right after the accept.
    thread::spawn(move || {
        loop {
            let mut chunk = vec![0; READ_CHUNK];
            match input.read(&mut chunk) {
                Ok(0) | Err(_) => break,
                Ok(read) => {
                    chunk.truncate(read);
                    if chunks.send(chunk).is_err() {
                        break;
                    }
                }
            }
        }
    });
    let deadline = Instant::now() + timeout;
    let mut data: Vec<u8> = Vec::new();
    while let Ok(chunk) = received.recv_timeout(deadline.saturating_duration_since(Instant::now()))
    {
        data.extend_from_slice(&chunk);
        if data.contains(&b'\n')
            || String::from_utf8_lossy(&data).encode_utf16().count() >= MAX_INPUT_BYTES
        {
            break;
        }
    }
    let first_line = data.split(|byte| *byte == b'\n').next().unwrap_or_default();
    String::from_utf8_lossy(first_line).into_owned()
}

/// A command line `node:util` `parseArgs` rejects, worded as its error.
#[derive(Debug, PartialEq, Eq)]
struct ArgsError {
    code: &'static str,
    message: String,
}

impl std::fmt::Display for ArgsError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "TypeError [{}]: {}", self.code, self.message)
    }
}

#[derive(Debug, Default, PartialEq, Eq)]
struct Parsed {
    state_dir: Option<String>,
    pairing_id: Option<String>,
}

fn args_error(code: &'static str, message: String) -> ArgsError {
    ArgsError { code, message }
}

/// `parseArgs({ options: { "state-dir": {type: "string"}, "pairing-id":
/// {type: "string"} } })` in its strict mode: long options only, as
/// `--name value` or `--name=value`, the last of a repeated one wins, and
/// anything else is an error naming the first offender.
fn parse_args(args: &[String]) -> std::result::Result<Parsed, ArgsError> {
    let mut parsed = Parsed::default();
    let mut index = 0;
    while index < args.len() {
        let arg = &args[index];
        index += 1;
        if arg == "--" {
            // Everything after the terminator is a positional argument.
            return match args.get(index) {
                Some(positional) => Err(unexpected_positional(positional)),
                None => Ok(parsed),
            };
        }
        if arg.len() > 2 && arg.starts_with("--") {
            // `--name=value` needs the `=` past the third character.
            let (name, inline) = match arg.as_bytes()[3..].contains(&b'=') {
                true => {
                    let eq = arg.find('=').unwrap_or(arg.len());
                    (&arg[2..eq], Some(&arg[eq + 1..]))
                }
                false => (&arg[2..], None),
            };
            let slot = match name {
                "state-dir" => &mut parsed.state_dir,
                "pairing-id" => &mut parsed.pairing_id,
                _ => {
                    return Err(args_error(
                        "ERR_PARSE_ARGS_UNKNOWN_OPTION",
                        format!("Unknown option '--{name}'"),
                    ));
                }
            };
            let value = match inline {
                Some(value) => value,
                None => {
                    let Some(next) = args.get(index) else {
                        return Err(args_error(
                            "ERR_PARSE_ARGS_INVALID_OPTION_VALUE",
                            format!("Option '--{name} <value>' argument missing"),
                        ));
                    };
                    index += 1;
                    // A lone `-` is a value; anything else starting with a
                    // dash is probably a forgotten value.
                    if next.len() > 1 && next.starts_with('-') {
                        return Err(args_error(
                            "ERR_PARSE_ARGS_INVALID_OPTION_VALUE",
                            format!(
                                "Option '--{name}' argument is ambiguous.\nDid you forget to specify the option argument for '--{name}'?\nTo specify an option argument starting with a dash use '--{name}=-XYZ'."
                            ),
                        ));
                    }
                    next
                }
            };
            *slot = Some(value.to_string());
        } else if arg.len() > 1 && arg.starts_with('-') {
            // No short options exist; a group names its first letter.
            let letter: String = arg.chars().skip(1).take(1).collect();
            return Err(args_error(
                "ERR_PARSE_ARGS_UNKNOWN_OPTION",
                format!("Unknown option '-{letter}'"),
            ));
        } else {
            return Err(unexpected_positional(arg));
        }
    }
    Ok(parsed)
}

fn unexpected_positional(arg: &str) -> ArgsError {
    args_error(
        "ERR_PARSE_ARGS_UNEXPECTED_POSITIONAL",
        format!("Unexpected argument '{arg}'. This command does not take positional arguments"),
    )
}

/// Run an accept on `input` the way sshd would: stdin carries the line, HOME
/// is `home`. Returns the exit code, stdout and stderr.
#[cfg(test)]
pub(crate) fn accept_with_input(
    home: &Path,
    state_dir: &Path,
    pairing_id: &str,
    input: &str,
) -> (i32, String, String) {
    use crate::env::Env;

    let ctx = Ctx {
        env: Env::from_pairs([("HOME", home.to_string_lossy().into_owned())]),
        home: home.to_path_buf(),
        plugin_root: home.to_path_buf(),
    };
    let args = [
        "--state-dir".to_string(),
        state_dir.to_string_lossy().into_owned(),
        "--pairing-id".to_string(),
        pairing_id.to_string(),
    ];
    let (mut out, mut err) = (Vec::new(), Vec::new());
    let code = accept(
        &ctx,
        &args,
        Box::new(std::io::Cursor::new(input.as_bytes().to_vec())),
        INPUT_TIMEOUT,
        &mut out,
        &mut err,
    );
    (
        code,
        String::from_utf8_lossy(&out).into_owned(),
        String::from_utf8_lossy(&err).into_owned(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::authorized_keys::{self, edit_authorized_keys};
    use crate::pairing_session::{PairingSession, begin_pairing, expire_pairing, read_enrollment};
    use crate::test_support::TempDir;
    use std::fs;

    // Generated with ssh-keygen; fingerprint confirmed via `ssh-keygen -lf`.
    const DEVICE_LINE: &str =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMYSCTemrZWEXptQyehHLI9kbqjHxNUGtQN2lF1ucCce waycar";
    const DEVICE_FINGERPRINT: &str = "SHA256:ef+f9Jda6ZPkcW5GiL7pQZXJ57mCFnFAGkir3AcfTIM";
    const USER_LINE: &str =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBPd+KiPbQwFzIFqVCaK0me6kR0BrPZ9HFcsl7WKcFXC laptop";

    struct Fixture {
        home_dir: TempDir,
    }

    impl Fixture {
        fn new() -> Self {
            Self {
                home_dir: TempDir::new("accept"),
            }
        }

        fn home(&self) -> &Path {
            self.home_dir.path()
        }

        fn state(&self) -> std::path::PathBuf {
            self.home().join("plugin-state")
        }

        fn begin(&self) -> PairingSession {
            begin_pairing(
                self.home(),
                &self.state(),
                crate::pairing_session::now_seconds(),
            )
            .unwrap()
        }

        fn begin_at(&self, now: i64) -> PairingSession {
            begin_pairing(self.home(), &self.state(), now).unwrap()
        }

        fn set_keys(&self, lines: &[&str]) {
            let lines: Vec<String> = lines.iter().map(|l| l.to_string()).collect();
            edit_authorized_keys(self.home(), |_| Ok(Some(lines))).unwrap();
        }

        fn keys(&self) -> String {
            fs::read_to_string(authorized_keys::path(self.home())).unwrap()
        }

        fn accept(&self, id: &str, input: &str) -> (i32, String, String) {
            accept_with_input(self.home(), &self.state(), id, input)
        }

        fn pending_exists(&self, id: &str) -> bool {
            pending_path(&self.state(), id).exists()
        }

        fn bootstrap_lines(&self) -> usize {
            self.keys()
                .trim_end()
                .split('\n')
                .filter(|line| parse_bootstrap_line(line).is_some())
                .count()
        }
    }

    fn stdout_line(result: &(i32, String, String)) -> &str {
        result.1.trim()
    }

    #[test]
    fn enrolls_a_valid_device_key_and_self_revokes_the_bootstrap_line() {
        let f = Fixture::new();
        f.set_keys(&[USER_LINE]);
        let session = f.begin();

        let result = f.accept(&session.pairing_id, &format!("{DEVICE_LINE}\n"));

        assert_eq!(result.0, 0, "{}", result.2);
        assert_eq!(
            stdout_line(&result),
            format!("HERDR-ENROLL:OK:{DEVICE_FINGERPRINT}")
        );
        assert_eq!(f.keys(), format!("{USER_LINE}\n{DEVICE_LINE}\n"));
        assert!(!f.pending_exists(&session.pairing_id));
        // The popup reads this record to show the enrolled fingerprint and
        // revoke; the expiry lets the startup sweep age out records a killed
        // popup left.
        assert_eq!(
            read_enrollment(&f.state(), &session.pairing_id),
            Some(Enrollment {
                pairing_id: session.pairing_id.clone(),
                expires_at: Some(session.expires_at),
                fingerprint: DEVICE_FINGERPRINT.into(),
                line: DEVICE_LINE.into(),
            })
        );
    }

    #[test]
    fn a_rejected_submission_leaves_no_enrollment_record() {
        let f = Fixture::new();
        let session = f.begin();
        f.accept(&session.pairing_id, "ssh-rsa AAAAB3nope\n");
        assert_eq!(read_enrollment(&f.state(), &session.pairing_id), None);
    }

    #[test]
    fn an_invalid_submission_does_not_consume_the_bootstrap_line_and_a_retry_works() {
        let f = Fixture::new();
        let session = f.begin();

        let invalid = f.accept(&session.pairing_id, "ssh-rsa AAAAB3nope\n");
        assert_eq!(invalid.0, 1);
        assert_eq!(stdout_line(&invalid), "HERDR-ENROLL:ERR:invalid_key");
        assert_eq!(
            invalid.2,
            "rejected Device Key line: key type must be ssh-ed25519\n"
        );
        assert_eq!(f.bootstrap_lines(), 1);
        assert!(f.pending_exists(&session.pairing_id));

        let retry = f.accept(&session.pairing_id, &format!("{DEVICE_LINE}\n"));
        assert_eq!(retry.0, 0, "{}", retry.2);
        assert_eq!(f.keys(), format!("{DEVICE_LINE}\n"));
    }

    #[test]
    fn an_empty_submission_is_rejected_without_consuming_the_line() {
        let f = Fixture::new();
        let session = f.begin();
        let result = f.accept(&session.pairing_id, "");
        assert_eq!(result.0, 1);
        assert_eq!(stdout_line(&result), "HERDR-ENROLL:ERR:no_input");
        assert_eq!(result.2, "expected a Device Key public line on stdin\n");
        assert_eq!(f.bootstrap_lines(), 1);
    }

    #[test]
    fn an_expired_pairing_removes_its_line_and_rejects() {
        let f = Fixture::new();
        let session = f.begin_at(crate::pairing_session::now_seconds() - 600);

        let result = f.accept(&session.pairing_id, &format!("{DEVICE_LINE}\n"));

        assert_eq!(result.0, 1);
        assert_eq!(stdout_line(&result), "HERDR-ENROLL:ERR:expired");
        assert_eq!(
            result.2,
            format!(
                "pairing {} expired; regenerate the Pairing Code\n",
                session.pairing_id
            )
        );
        assert_eq!(f.bootstrap_lines(), 0);
        assert!(!f.keys().contains(DEVICE_LINE));
        assert!(!f.pending_exists(&session.pairing_id));
    }

    #[test]
    fn an_unknown_pairing_id_is_rejected() {
        let f = Fixture::new();
        f.begin();
        let result = f.accept("deadbeef0000", &format!("{DEVICE_LINE}\n"));
        assert_eq!(result.0, 1);
        assert_eq!(stdout_line(&result), "HERDR-ENROLL:ERR:unknown_pairing");
        assert_eq!(result.2, "no pending pairing deadbeef0000\n");
    }

    #[test]
    fn the_bootstrap_line_is_single_use() {
        let f = Fixture::new();
        let session = f.begin();

        let first = f.accept(&session.pairing_id, &format!("{DEVICE_LINE}\n"));
        assert_eq!(first.0, 0, "{}", first.2);

        let second = f.accept(&session.pairing_id, &format!("{DEVICE_LINE}\n"));
        assert_eq!(second.0, 1);
        assert_eq!(stdout_line(&second), "HERDR-ENROLL:ERR:unknown_pairing");
        assert_eq!(f.keys(), format!("{DEVICE_LINE}\n"));
    }

    #[test]
    fn re_enrolling_an_already_authorized_device_key_succeeds_without_a_duplicate() {
        let f = Fixture::new();
        let first = f.begin();
        f.accept(&first.pairing_id, &format!("{DEVICE_LINE}\n"));

        let second = f.begin();
        let result = f.accept(&second.pairing_id, &format!("{DEVICE_LINE}\n"));

        assert_eq!(result.0, 0, "{}", result.2);
        assert_eq!(
            stdout_line(&result),
            format!("HERDR-ENROLL:OK:{DEVICE_FINGERPRINT}")
        );
        assert_eq!(f.keys(), format!("{DEVICE_LINE}\n"));
    }

    #[test]
    fn expiring_after_an_enroll_returns_the_record_instead_of_expiring() {
        let f = Fixture::new();
        let session = f.begin();
        let accept = f.accept(&session.pairing_id, &format!("{DEVICE_LINE}\n"));
        assert_eq!(accept.0, 0, "{}", accept.2);

        let record = expire_pairing(f.home(), &f.state(), &session.pairing_id).unwrap();

        assert_eq!(record.unwrap().fingerprint, DEVICE_FINGERPRINT);
        assert!(f.keys().contains(DEVICE_LINE));
        // The record survives so the popup can still offer the revoke.
        assert!(read_enrollment(&f.state(), &session.pairing_id).is_some());
    }

    #[test]
    fn expiring_before_the_accept_runs_consumes_the_pairing() {
        let f = Fixture::new();
        let session = f.begin();

        let record = expire_pairing(f.home(), &f.state(), &session.pairing_id).unwrap();
        assert_eq!(record, None);

        let result = f.accept(&session.pairing_id, &format!("{DEVICE_LINE}\n"));
        assert_eq!(result.0, 1);
        assert_eq!(stdout_line(&result), "HERDR-ENROLL:ERR:unknown_pairing");
        assert!(!f.keys().contains(DEVICE_LINE));
        assert_eq!(read_enrollment(&f.state(), &session.pairing_id), None);
    }

    #[test]
    fn an_expiry_racing_an_accept_never_enrolls_a_device_silently() {
        // Many rounds: the interleaving differs each time.
        for _ in 0..20 {
            let f = Fixture::new();
            let session = f.begin();
            let (home, state, id) = (
                f.home().to_path_buf(),
                f.state(),
                session.pairing_id.clone(),
            );
            let accepting = std::thread::spawn(move || {
                accept_with_input(&home, &state, &id, &format!("{DEVICE_LINE}\n"))
            });
            let record = expire_pairing(f.home(), &f.state(), &session.pairing_id).unwrap();
            let result = accepting.join().unwrap();

            if f.keys().contains(DEVICE_LINE) {
                // The accept won: the popup's locked expiry check must have
                // seen the record, or it would render "expired" over a
                // silently enrolled device.
                assert_eq!(
                    stdout_line(&result),
                    format!("HERDR-ENROLL:OK:{DEVICE_FINGERPRINT}")
                );
                assert_eq!(record.unwrap().fingerprint, DEVICE_FINGERPRINT);
            } else {
                // The expiry won: nothing enrolled, no record, accept rejected.
                assert_eq!(record, None);
                assert_eq!(result.0, 1);
                assert_eq!(read_enrollment(&f.state(), &session.pairing_id), None);
            }
            assert_eq!(f.bootstrap_lines(), 0);
        }
    }

    #[test]
    fn two_concurrent_accepts_enroll_the_device_key_exactly_once() {
        for _ in 0..20 {
            let f = Fixture::new();
            f.set_keys(&[USER_LINE]);
            let session = f.begin();
            let accepts: Vec<_> = (0..2)
                .map(|_| {
                    let (home, state, id) = (
                        f.home().to_path_buf(),
                        f.state(),
                        session.pairing_id.clone(),
                    );
                    std::thread::spawn(move || {
                        accept_with_input(&home, &state, &id, &format!("{DEVICE_LINE}\n"))
                    })
                })
                .collect();
            let mut outcomes: Vec<String> = accepts
                .into_iter()
                .map(|handle| handle.join().unwrap().1.trim().to_string())
                .collect();
            outcomes.sort();

            // Exactly one winner enrolls; the loser sees the pairing consumed.
            assert_eq!(
                outcomes,
                [
                    "HERDR-ENROLL:ERR:unknown_pairing".to_string(),
                    format!("HERDR-ENROLL:OK:{DEVICE_FINGERPRINT}"),
                ]
            );
            // One Device Key line, no leftover bootstrap line.
            assert_eq!(f.keys(), format!("{USER_LINE}\n{DEVICE_LINE}\n"));
            assert_eq!(f.bootstrap_lines(), 0);
            assert!(!f.pending_exists(&session.pairing_id));
        }
    }

    #[test]
    fn the_first_line_only_is_the_submission() {
        let f = Fixture::new();
        let session = f.begin();
        let result = f.accept(
            &session.pairing_id,
            &format!("{DEVICE_LINE}\nssh-ed25519 ignored\n"),
        );
        assert_eq!(result.0, 0, "{}", result.2);
        assert_eq!(f.keys(), format!("{DEVICE_LINE}\n"));
    }

    #[test]
    fn a_line_longer_than_the_cap_is_rejected_as_a_key() {
        let f = Fixture::new();
        let session = f.begin();
        let result = f.accept(&session.pairing_id, &"x".repeat(10_000));
        assert_eq!(stdout_line(&result), "HERDR-ENROLL:ERR:invalid_key");
        assert_eq!(
            result.2,
            "rejected Device Key line: submission exceeds 1024 characters\n"
        );
    }

    #[test]
    fn a_stalled_stdin_ends_the_wait_at_the_timeout() {
        struct Stalled;
        impl Read for Stalled {
            fn read(&mut self, _: &mut [u8]) -> std::io::Result<usize> {
                thread::sleep(Duration::from_secs(3600));
                Ok(0)
            }
        }
        let started = Instant::now();
        let line = read_submission(Box::new(Stalled), Duration::from_millis(100));
        assert_eq!(line, "");
        assert!(started.elapsed() < Duration::from_secs(5));
    }

    #[test]
    fn a_missing_argument_or_home_is_unknown_pairing() {
        use crate::env::Env;
        let f = Fixture::new();
        let ctx = |env: Env| Ctx {
            env,
            home: f.home().to_path_buf(),
            plugin_root: f.home().to_path_buf(),
        };
        let with_home = Env::from_pairs([("HOME", f.home().to_string_lossy().into_owned())]);
        let run = |ctx: &Ctx, args: &[&str]| {
            let args: Vec<String> = args.iter().map(|a| a.to_string()).collect();
            let (mut out, mut err) = (Vec::new(), Vec::new());
            let code = accept(
                ctx,
                &args,
                Box::new(std::io::empty()),
                INPUT_TIMEOUT,
                &mut out,
                &mut err,
            );
            (
                code,
                String::from_utf8(out).unwrap(),
                String::from_utf8(err).unwrap(),
            )
        };
        let expected = (
            1,
            "HERDR-ENROLL:ERR:unknown_pairing\n".to_string(),
            "pair-accept requires --state-dir, --pairing-id, and HOME\n".to_string(),
        );
        assert_eq!(run(&ctx(with_home.clone()), &[]), expected);
        assert_eq!(
            run(&ctx(with_home.clone()), &["--state-dir=", "--pairing-id=x"]),
            expected
        );
        assert_eq!(
            run(&ctx(Env::default()), &["--state-dir=/s", "--pairing-id=x"]),
            expected
        );
    }

    fn argv(list: &[&str]) -> Vec<String> {
        list.iter().map(|a| a.to_string()).collect()
    }

    fn parsed(list: &[&str]) -> (Option<String>, Option<String>) {
        let parsed = parse_args(&argv(list)).unwrap();
        (parsed.state_dir, parsed.pairing_id)
    }

    fn failure(list: &[&str]) -> String {
        parse_args(&argv(list)).unwrap_err().to_string()
    }

    #[test]
    fn arguments_follow_node_parse_args() {
        let some = |v: &str| Some(v.to_string());
        assert_eq!(parsed(&[]), (None, None));
        assert_eq!(
            parsed(&["--state-dir", "a", "--pairing-id", "b"]),
            (some("a"), some("b"))
        );
        assert_eq!(
            parsed(&["--state-dir=a=b", "--pairing-id=c"]),
            (some("a=b"), some("c"))
        );
        // The last of a repeated option wins.
        assert_eq!(
            parsed(&["--state-dir", "a", "--state-dir", "b"]),
            (some("b"), None)
        );
        // A lone dash is a value; an empty `=` value is a value.
        assert_eq!(parsed(&["--state-dir", "-"]), (some("-"), None));
        assert_eq!(parsed(&["--pairing-id="]), (None, some("")));
        assert_eq!(parsed(&["--"]), (None, None));
    }

    #[test]
    fn argument_errors_carry_the_node_messages() {
        for (list, message) in [
            (
                &["--foo"][..],
                "TypeError [ERR_PARSE_ARGS_UNKNOWN_OPTION]: Unknown option '--foo'",
            ),
            (
                &["--foo=bar"][..],
                "TypeError [ERR_PARSE_ARGS_UNKNOWN_OPTION]: Unknown option '--foo'",
            ),
            (
                &["--=x"][..],
                "TypeError [ERR_PARSE_ARGS_UNKNOWN_OPTION]: Unknown option '--=x'",
            ),
            (
                &["--Foo"][..],
                "TypeError [ERR_PARSE_ARGS_UNKNOWN_OPTION]: Unknown option '--Foo'",
            ),
            (
                &["-abc"][..],
                "TypeError [ERR_PARSE_ARGS_UNKNOWN_OPTION]: Unknown option '-a'",
            ),
            (
                &["-s", "a"][..],
                "TypeError [ERR_PARSE_ARGS_UNKNOWN_OPTION]: Unknown option '-s'",
            ),
            (
                &["--state-dir"][..],
                "TypeError [ERR_PARSE_ARGS_INVALID_OPTION_VALUE]: Option '--state-dir <value>' argument missing",
            ),
            (
                &["--state-dir", "--pairing-id", "i"][..],
                "TypeError [ERR_PARSE_ARGS_INVALID_OPTION_VALUE]: Option '--state-dir' argument is ambiguous.\nDid you forget to specify the option argument for '--state-dir'?\nTo specify an option argument starting with a dash use '--state-dir=-XYZ'.",
            ),
            (
                &["x"][..],
                "TypeError [ERR_PARSE_ARGS_UNEXPECTED_POSITIONAL]: Unexpected argument 'x'. This command does not take positional arguments",
            ),
            (
                &["-"][..],
                "TypeError [ERR_PARSE_ARGS_UNEXPECTED_POSITIONAL]: Unexpected argument '-'. This command does not take positional arguments",
            ),
            (
                &["--state-dir", "a", "--", "b"][..],
                "TypeError [ERR_PARSE_ARGS_UNEXPECTED_POSITIONAL]: Unexpected argument 'b'. This command does not take positional arguments",
            ),
        ] {
            assert_eq!(failure(list), message, "{list:?}");
        }
    }

    #[test]
    fn a_bad_command_line_prints_no_protocol_line_and_exits_1() {
        let f = Fixture::new();
        let ctx = Ctx {
            env: crate::env::Env::from_pairs([("HOME", f.home().to_string_lossy().into_owned())]),
            home: f.home().to_path_buf(),
            plugin_root: f.home().to_path_buf(),
        };
        let (mut out, mut err) = (Vec::new(), Vec::new());
        let code = accept(
            &ctx,
            &argv(&["--bogus"]),
            Box::new(std::io::empty()),
            INPUT_TIMEOUT,
            &mut out,
            &mut err,
        );
        assert_eq!(code, 1);
        assert_eq!(out, b"");
        assert_eq!(
            String::from_utf8(err).unwrap(),
            "TypeError [ERR_PARSE_ARGS_UNKNOWN_OPTION]: Unknown option '--bogus'\n"
        );
    }
}
