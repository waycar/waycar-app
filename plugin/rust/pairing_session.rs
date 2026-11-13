//! One pairing ceremony on the server side (pairing-session.js, ADR 0007).
//!
//! [`begin_pairing`] mints a Bootstrap Key, writes its restricted
//! authorized_keys line (restrict + forced command at `waycar pair-accept`),
//! and records pending state under the plugin state directory.
//! [`end_pairing`] undoes both; it runs on popup exit, on TTL expiry, and is
//! idempotent so crashed ceremonies can be cleaned up twice.
//!
//! The forced command embeds absolute paths because sshd runs it with a bare
//! login-shell environment: no herdr plugin env, no PATH to rely on.

use std::fs::{self, DirBuilder, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use ring::rand::{SecureRandom, SystemRandom};
use serde_json::{Value, json};

use crate::authorized_keys::{bootstrap_line, edit_authorized_keys, parse_bootstrap_line};
use crate::bootstrap_key::generate_bootstrap_key;
use crate::error::{CliError, Result};
use crate::jsx;
use crate::paths::posix_join;

pub const PAIRING_TTL_SECONDS: i64 = 120;

/// How far past its ceremony's expiry an enrolled record must be before the
/// sweep may call it orphaned. A live popup reads the record within a poll
/// interval of the accept writing it, so anything a full TTL late is garbage.
const STATE_SWEEP_GRACE_SECONDS: i64 = PAIRING_TTL_SECONDS;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairingSession {
    pub pairing_id: String,
    /// The Bootstrap Key's raw Ed25519 seed (rides in the Pairing Code).
    pub seed: [u8; 32],
    pub expires_at: i64,
    pub public_line: String,
}

/// A completed Enrollment, as pair-accept records it so the popup can show the
/// enrolled fingerprint and offer a one-key revoke.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Enrollment {
    pub pairing_id: String,
    /// The ceremony's expiry (unix seconds); lets the startup sweep age out
    /// records a killed popup never cleaned up.
    pub expires_at: Option<i64>,
    pub fingerprint: String,
    /// The enrolled authorized_keys line (the revoke target).
    pub line: String,
}

/// Unix seconds now.
pub fn now_seconds() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_secs() as i64)
}

fn state_file(state_dir: &Path, kind: &str, pairing_id: &str) -> PathBuf {
    posix_join(&[
        state_dir,
        Path::new(kind),
        Path::new(&format!("{pairing_id}.json")),
    ])
}

pub fn pending_path(state_dir: &Path, pairing_id: &str) -> PathBuf {
    state_file(state_dir, "pending", pairing_id)
}

pub fn enrolled_path(state_dir: &Path, pairing_id: &str) -> PathBuf {
    state_file(state_dir, "enrolled", pairing_id)
}

/// `JSON.parse(readFileSync(path, "utf8"))`: invalid UTF-8 reads as U+FFFD;
/// none when the file is missing or is not JSON.
pub(crate) fn read_json(path: &Path) -> Option<Value> {
    let bytes = fs::read(path).ok()?;
    serde_json::from_str(&String::from_utf8_lossy(&bytes)).ok()
}

/// `rmSync(path, { force: true })`: a missing file is fine, any other failure
/// is not.
pub(crate) fn remove_force(path: &Path) -> Result<()> {
    match fs::remove_file(path) {
        Err(error) if error.kind() != io::ErrorKind::NotFound => Err(error.into()),
        _ => Ok(()),
    }
}

/// `mkdirSync(dir, { recursive: true, mode: 0o700 })`.
fn create_private_dir(dir: &Path) -> Result<()> {
    DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)
        .map_err(|e| CliError::failure(format!("cannot create {}: {e}", dir.display())))
}

/// `writeFileSync(path, text, { mode: 0o600 })`: the mode applies to a new
/// file only, and an existing one is overwritten in place.
fn write_private(path: &Path, text: &str) -> Result<()> {
    let mut file = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(path)?;
    Ok(file.write_all(text.as_bytes())?)
}

/// Record a completed Enrollment. Written by pair-accept inside the
/// authorized_keys lock, atomically with the Device Key append; the popup
/// polls for it as its Enrollment signal and [`expire_pairing`] checks it
/// under that lock.
pub fn record_enrollment(state_dir: &Path, record: &Enrollment) -> Result<()> {
    create_private_dir(&posix_join(&[state_dir, Path::new("enrolled")]))?;
    let mut body = serde_json::Map::new();
    body.insert("pairingId".into(), json!(record.pairing_id));
    if let Some(expires_at) = record.expires_at {
        body.insert("expiresAt".into(), json!(expires_at));
    }
    body.insert("fingerprint".into(), json!(record.fingerprint));
    body.insert("line".into(), json!(record.line));
    write_private(
        &enrolled_path(state_dir, &record.pairing_id),
        &format!("{}\n", jsx::stringify(&Value::Object(body))),
    )
}

/// Read a completed Enrollment record; none when there is none yet or the
/// file is not a record.
pub fn read_enrollment(state_dir: &Path, pairing_id: &str) -> Option<Enrollment> {
    let record = read_json(&enrolled_path(state_dir, pairing_id))?;
    let text_of = |key: &str| record.get(key)?.as_str().map(str::to_string);
    Some(Enrollment {
        pairing_id: text_of("pairingId")?,
        expires_at: record.get("expiresAt").and_then(Value::as_i64),
        fingerprint: text_of("fingerprint")?,
        line: text_of("line")?,
    })
}

/// A path inside the forced command: the whole command lives inside
/// authorized_keys double quotes and is then parsed by the login shell, so
/// single-quoting keeps both layers happy as long as the path has no quote
/// characters of its own.
fn single_quoted(path: &Path, what: &str) -> Result<String> {
    let Some(text) = path.to_str() else {
        return Err(CliError::failure(format!("{what} is not valid UTF-8")));
    };
    if text.contains(['\'', '"', '\n', '\r']) {
        return Err(CliError::failure(format!(
            "{what} must not contain quotes or newlines: {text}"
        )));
    }
    Ok(format!("'{text}'"))
}

fn accept_command(waycar: &Path, state_dir: &Path, pairing_id: &str) -> Result<String> {
    Ok(format!(
        "{} pair-accept --state-dir {} --pairing-id {pairing_id}",
        single_quoted(waycar, "waycar binary path")?,
        single_quoted(state_dir, "plugin state dir")?,
    ))
}

fn random_pairing_id() -> Result<String> {
    let mut bytes = [0u8; 6];
    SystemRandom::new()
        .fill(&mut bytes)
        .map_err(|_| CliError::failure("cannot read system randomness"))?;
    Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}

/// Start a ceremony expiring [`PAIRING_TTL_SECONDS`] after `now`: Bootstrap
/// Key, restricted line, pending state. The forced command runs this waycar
/// binary, by its canonical path.
pub fn begin_pairing(home: &Path, state_dir: &Path, now: i64) -> Result<PairingSession> {
    let waycar = std::env::current_exe()
        .and_then(fs::canonicalize)
        .map_err(|e| CliError::failure(format!("cannot resolve the waycar binary: {e}")))?;
    begin_pairing_for(home, state_dir, now, &waycar)
}

/// [`begin_pairing`] for a forced command that runs `waycar` (an absolute
/// path) instead of the running binary: for a process that is not `waycar`
/// itself, such as the parity binary.
pub fn begin_pairing_for(
    home: &Path,
    state_dir: &Path,
    now: i64,
    waycar: &Path,
) -> Result<PairingSession> {
    let pairing_id = random_pairing_id()?;
    let expires_at = now + PAIRING_TTL_SECONDS;
    let key = generate_bootstrap_key()?;
    let line = bootstrap_line(
        &key.public_line,
        &pairing_id,
        expires_at,
        &accept_command(waycar, state_dir, &pairing_id)?,
    )?;

    create_private_dir(&posix_join(&[state_dir, Path::new("pending")]))?;
    let pending = pending_path(state_dir, &pairing_id);
    write_private(
        &pending,
        &format!(
            "{}\n",
            jsx::stringify(&json!({
                "pairingId": pairing_id,
                "expiresAt": expires_at,
                "publicLine": key.public_line,
            }))
        ),
    )?;
    if let Err(error) = edit_authorized_keys(home, |mut lines| {
        lines.push(line);
        Ok(Some(lines))
    }) {
        let _ = remove_force(&pending);
        return Err(error);
    }

    Ok(PairingSession {
        pairing_id,
        seed: key.seed,
        expires_at,
        public_line: key.public_line,
    })
}

/// The lines without the Bootstrap Key line of `pairing_id`; none when it was
/// not there.
fn without_bootstrap_line(lines: Vec<String>, pairing_id: &str) -> Option<Vec<String>> {
    let before = lines.len();
    let kept: Vec<String> = lines
        .into_iter()
        .filter(|line| parse_bootstrap_line(line).is_none_or(|m| m.pairing_id != pairing_id))
        .collect();
    (kept.len() != before).then_some(kept)
}

/// Expire a ceremony from the popup's TTL timer. Like [`end_pairing`], but the
/// enrolled-record check runs inside the authorized_keys lock: the same lock
/// under which pair-accept commits an Enrollment. Exactly one outcome is
/// possible: either the record is visible here (it is returned, nothing is
/// touched, the popup shows the revoke screen), or this cleanup consumes the
/// pending state first and the accept rejects. No interleaving can enroll a
/// device silently (ADR 0007's compensating control depends on that).
pub fn expire_pairing(
    home: &Path,
    state_dir: &Path,
    pairing_id: &str,
) -> Result<Option<Enrollment>> {
    let mut record = None;
    edit_authorized_keys(home, |lines| {
        record = read_enrollment(state_dir, pairing_id);
        if record.is_some() {
            return Ok(None);
        }
        remove_force(&pending_path(state_dir, pairing_id))?;
        Ok(without_bootstrap_line(lines, pairing_id))
    })?;
    Ok(record)
}

/// End a ceremony: drop the bootstrap line, pending state, and any Enrollment
/// record. Same critical-section rule as [`expire_pairing`]: everything runs
/// inside the authorized_keys lock, so an accept that wins the lock after this
/// edit finds the pending state gone and rejects: no silent enrollment of a
/// device the user closed the popup on. Idempotent, so crashed ceremonies can
/// be cleaned up twice.
pub fn end_pairing(home: &Path, state_dir: &Path, pairing_id: &str) -> Result<()> {
    end_pairing_with(home, state_dir, pairing_id, |home, teardown| {
        edit_authorized_keys(home, teardown)
    })
}

/// The teardown [`end_pairing`] hands to the authorized_keys editor.
type Teardown<'a> = &'a mut dyn FnMut(Vec<String>) -> Result<Option<Vec<String>>>;

/// [`end_pairing`] through `edit` instead of the real editor, so a test can
/// pin that the teardown runs inside the editor's critical section.
pub(crate) fn end_pairing_with(
    home: &Path,
    state_dir: &Path,
    pairing_id: &str,
    edit: impl FnOnce(&Path, Teardown<'_>) -> Result<bool>,
) -> Result<()> {
    edit(home, &mut |lines| {
        remove_force(&pending_path(state_dir, pairing_id))?;
        remove_force(&enrolled_path(state_dir, pairing_id))?;
        Ok(without_bootstrap_line(lines, pairing_id))
    })?;
    Ok(())
}

/// Startup sweep for the plugin state dir, the file-side twin of
/// `sweep_expired_bootstrap_lines`: a SIGKILLed popup never runs
/// [`end_pairing`], so its pending/enrolled records would otherwise live
/// forever. Only provably stale files go (pending records past their embedded
/// expiry, enrolled records a grace period past theirs), so a concurrent
/// popup's live ceremony is never clobbered. Returns how many files went.
pub fn sweep_expired_state_files(state_dir: &Path, now: i64) -> Result<usize> {
    let grace = STATE_SWEEP_GRACE_SECONDS as f64;
    Ok(sweep_dir(&state_dir.join("pending"), now, 0.0)?
        + sweep_dir(&state_dir.join("enrolled"), now, grace)?)
}

fn sweep_dir(dir: &Path, now: i64, grace: f64) -> Result<usize> {
    let entries = match fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(0),
        Err(error) => return Err(error.into()),
    };
    let mut removed = 0;
    for entry in entries {
        let path = entry?.path();
        if keep_until(&path, grace) <= now as f64 {
            remove_force(&path)?;
            removed += 1;
        }
    }
    Ok(removed)
}

/// Unix-seconds instant until which a state file must be kept: its embedded
/// expiry plus `grace`.
fn keep_until(path: &Path, grace: f64) -> f64 {
    let embedded =
        read_json(path).and_then(|record| record.get("expiresAt").and_then(Value::as_f64));
    if let Some(expires_at) = embedded {
        return expires_at + grace;
    }
    // Unreadable or malformed: garbage still ages out, but by mtime and with
    // full TTL + grace slack so a concurrent writer's file mid-write is never
    // misjudged as stale.
    match fs::metadata(path)
        .and_then(|meta| meta.modified())
        .map(|time| time.duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs()))
    {
        Ok(seconds) => (seconds as i64 + PAIRING_TTL_SECONDS + STATE_SWEEP_GRACE_SECONDS) as f64,
        // Vanished mid-sweep: someone else already cleaned it up.
        Err(_) => f64::INFINITY,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::authorized_keys::{self, parse_bootstrap_line};
    use crate::bootstrap_key::public_line_from_seed;
    use crate::pair_accept::accept_with_input;
    use crate::test_support::TempDir;
    use std::fs::File;
    use std::os::unix::fs::PermissionsExt;
    use std::time::Duration;

    const USER_LINE: &str =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBPd+KiPbQwFzIFqVCaK0me6kR0BrPZ9HFcsl7WKcFXC laptop";
    const DEVICE_LINE: &str =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMYSCTemrZWEXptQyehHLI9kbqjHxNUGtQN2lF1ucCce waycar";
    const DEVICE_FINGERPRINT: &str = "SHA256:ef+f9Jda6ZPkcW5GiL7pQZXJ57mCFnFAGkir3AcfTIM";
    const NOW: i64 = 1753305600;

    struct Fixture {
        dir: TempDir,
    }

    impl Fixture {
        fn new() -> Self {
            Self {
                dir: TempDir::new("session"),
            }
        }

        fn home(&self) -> &Path {
            self.dir.path()
        }

        fn state(&self) -> PathBuf {
            self.dir.path().join("plugin-state")
        }

        fn keys(&self) -> String {
            fs::read_to_string(authorized_keys::path(self.home())).unwrap()
        }

        fn set_keys(&self, lines: &[&str]) {
            let lines: Vec<String> = lines.iter().map(|l| l.to_string()).collect();
            edit_authorized_keys(self.home(), |_| Ok(Some(lines))).unwrap();
        }

        fn begin(&self, now: i64) -> PairingSession {
            begin_pairing(self.home(), &self.state(), now).unwrap()
        }

        fn enroll_record(&self, id: &str, expires_at: Option<i64>) {
            record_enrollment(
                &self.state(),
                &Enrollment {
                    pairing_id: id.into(),
                    expires_at,
                    fingerprint: DEVICE_FINGERPRINT.into(),
                    line: DEVICE_LINE.into(),
                },
            )
            .unwrap();
        }
    }

    fn mode(path: &Path) -> u32 {
        fs::metadata(path).unwrap().permissions().mode() & 0o777
    }

    // beginPairing
    #[test]
    fn writes_a_restricted_bootstrap_line_and_matching_pending_state() {
        let f = Fixture::new();
        let session = f.begin(NOW);

        assert_eq!(session.seed.len(), 32);
        assert_eq!(session.expires_at, NOW + PAIRING_TTL_SECONDS);
        assert_eq!(
            session.public_line,
            public_line_from_seed(&session.seed).unwrap()
        );
        assert_eq!(session.pairing_id.len(), 12);
        assert!(session.pairing_id.bytes().all(|b| b.is_ascii_hexdigit()));

        let keys = f.keys();
        let lines: Vec<&str> = keys.trim_end().split('\n').collect();
        assert_eq!(lines.len(), 1);
        let line = lines[0];
        assert!(line.starts_with("restrict,command=\""), "{line}");
        let waycar = std::fs::canonicalize(std::env::current_exe().unwrap()).unwrap();
        assert!(
            line.contains(&format!("'{}' pair-accept ", waycar.display())),
            "command must pin the waycar binary: {line}"
        );
        assert!(
            line.contains(&format!("--state-dir '{}'", f.state().display())),
            "command must carry the state dir"
        );
        assert!(line.contains(&format!("--pairing-id {}", session.pairing_id)));
        assert!(line.contains(&session.public_line));
        let marker = parse_bootstrap_line(line).unwrap();
        assert_eq!(marker.pairing_id, session.pairing_id);
        assert_eq!(marker.expires_at, session.expires_at as u64);

        let pending_file = pending_path(&f.state(), &session.pairing_id);
        let pending: Value = serde_json::from_slice(&fs::read(&pending_file).unwrap()).unwrap();
        assert_eq!(pending["pairingId"], session.pairing_id);
        assert_eq!(pending["expiresAt"], session.expires_at);
        assert_eq!(pending["publicLine"], session.public_line);
        assert_eq!(mode(&pending_file), 0o600);
    }

    #[test]
    fn the_pending_file_is_one_json_line_in_the_js_key_order() {
        let f = Fixture::new();
        let session = f.begin(NOW);
        assert_eq!(
            fs::read_to_string(pending_path(&f.state(), &session.pairing_id)).unwrap(),
            format!(
                "{{\"pairingId\":\"{}\",\"expiresAt\":{},\"publicLine\":\"{}\"}}\n",
                session.pairing_id, session.expires_at, session.public_line
            )
        );
    }

    #[test]
    fn keeps_existing_authorized_keys_entries() {
        let f = Fixture::new();
        f.set_keys(&[USER_LINE]);
        f.begin(NOW);
        assert!(f.keys().starts_with(&format!("{USER_LINE}\n")));
    }

    #[test]
    fn rejects_a_state_dir_the_forced_command_cannot_quote() {
        let f = Fixture::new();
        let state = f.home().join("state'dir");
        let error = begin_pairing(f.home(), &state, NOW).unwrap_err();
        assert!(
            error
                .message()
                .starts_with("plugin state dir must not contain quotes or newlines: "),
            "{error}"
        );
        // Nothing was written.
        assert!(!state.exists());
        assert!(!authorized_keys::path(f.home()).exists());
    }

    // enrollment record
    #[test]
    fn the_enrollment_record_round_trips_fingerprint_line_and_expiry_written_0600() {
        let f = Fixture::new();
        f.enroll_record("abc123", Some(NOW));
        assert_eq!(
            read_enrollment(&f.state(), "abc123"),
            Some(Enrollment {
                pairing_id: "abc123".into(),
                expires_at: Some(NOW),
                fingerprint: DEVICE_FINGERPRINT.into(),
                line: DEVICE_LINE.into(),
            })
        );
        assert_eq!(mode(&enrolled_path(&f.state(), "abc123")), 0o600);
        assert_eq!(
            fs::read_to_string(enrolled_path(&f.state(), "abc123")).unwrap(),
            format!(
                "{{\"pairingId\":\"abc123\",\"expiresAt\":{NOW},\"fingerprint\":\"{DEVICE_FINGERPRINT}\",\"line\":\"{DEVICE_LINE}\"}}\n"
            )
        );
    }

    #[test]
    fn a_record_without_an_expiry_omits_the_field() {
        let f = Fixture::new();
        f.enroll_record("abc123", None);
        let text = fs::read_to_string(enrolled_path(&f.state(), "abc123")).unwrap();
        assert!(!text.contains("expiresAt"), "{text}");
        assert_eq!(
            read_enrollment(&f.state(), "abc123").unwrap().expires_at,
            None
        );
    }

    #[test]
    fn read_enrollment_is_none_when_there_is_no_record() {
        let f = Fixture::new();
        assert_eq!(read_enrollment(&f.state(), "missing"), None);
    }

    // sweepExpiredStateFiles
    #[test]
    fn sweep_removes_expired_pending_and_stale_enrolled_records_keeps_live_ones() {
        // Real clock: the sweep's fallback for unreadable files compares mtime.
        let now = now_seconds();
        let f = Fixture::new();
        let dead = f.begin(now - 10 * PAIRING_TTL_SECONDS);
        let live = f.begin(now);
        f.enroll_record("stale", Some(now - 10 * PAIRING_TTL_SECONDS));
        f.enroll_record("fresh", Some(now + PAIRING_TTL_SECONDS));

        assert_eq!(sweep_expired_state_files(&f.state(), now).unwrap(), 2);

        assert!(!pending_path(&f.state(), &dead.pairing_id).exists());
        assert!(pending_path(&f.state(), &live.pairing_id).exists());
        assert_eq!(read_enrollment(&f.state(), "stale"), None);
        assert!(read_enrollment(&f.state(), "fresh").is_some());
    }

    #[test]
    fn sweep_keeps_an_enrolled_record_inside_its_grace_window() {
        // Just past its ceremony's expiry: a live popup may not have read it yet.
        let now = now_seconds();
        let f = Fixture::new();
        f.enroll_record("graceful", Some(now - 1));
        assert_eq!(sweep_expired_state_files(&f.state(), now).unwrap(), 0);
        assert!(read_enrollment(&f.state(), "graceful").is_some());
    }

    #[test]
    fn sweep_ages_out_unreadable_state_files_by_mtime() {
        let now = now_seconds();
        let f = Fixture::new();
        let pending_dir = f.state().join("pending");
        fs::create_dir_all(&pending_dir).unwrap();
        let stale = pending_dir.join("garbage-old.json");
        fs::write(&stale, "not json").unwrap();
        File::options()
            .write(true)
            .open(&stale)
            .unwrap()
            .set_modified(SystemTime::now() - Duration::from_secs(3600))
            .unwrap();
        let fresh = pending_dir.join("garbage-new.json");
        fs::write(&fresh, "not json").unwrap();

        assert_eq!(sweep_expired_state_files(&f.state(), now).unwrap(), 1);
        assert!(!stale.exists());
        assert!(fresh.exists());
    }

    #[test]
    fn sweep_is_a_no_op_when_the_state_dir_does_not_exist_yet() {
        let f = Fixture::new();
        assert_eq!(
            sweep_expired_state_files(&f.home().join("no-such-state"), now_seconds()).unwrap(),
            0
        );
    }

    // expirePairing
    #[test]
    fn expiring_removes_the_bootstrap_line_and_pending_state_when_nothing_enrolled() {
        let f = Fixture::new();
        f.set_keys(&[USER_LINE]);
        let session = f.begin(NOW);

        let record = expire_pairing(f.home(), &f.state(), &session.pairing_id).unwrap();

        assert_eq!(record, None);
        assert_eq!(f.keys(), format!("{USER_LINE}\n"));
        assert!(!pending_path(&f.state(), &session.pairing_id).exists());
    }

    #[test]
    fn expiring_returns_the_enrollment_record_and_touches_nothing_when_a_device_enrolled() {
        let f = Fixture::new();
        f.set_keys(&[USER_LINE]);
        let session = f.begin(NOW);
        f.enroll_record(&session.pairing_id, Some(session.expires_at));
        let keys_before = f.keys();

        let record = expire_pairing(f.home(), &f.state(), &session.pairing_id).unwrap();

        let record = record.unwrap();
        assert_eq!(record.fingerprint, DEVICE_FINGERPRINT);
        assert_eq!(record.line, DEVICE_LINE);
        assert_eq!(f.keys(), keys_before);
        assert!(pending_path(&f.state(), &session.pairing_id).exists());
        assert!(enrolled_path(&f.state(), &session.pairing_id).exists());
    }

    // endPairing
    #[test]
    fn ending_removes_the_bootstrap_line_the_pending_state_and_the_enrollment_record() {
        let f = Fixture::new();
        f.set_keys(&[USER_LINE]);
        let session = f.begin(NOW);
        f.enroll_record(&session.pairing_id, None);
        end_pairing(f.home(), &f.state(), &session.pairing_id).unwrap();
        assert_eq!(f.keys(), format!("{USER_LINE}\n"));
        assert!(!pending_path(&f.state(), &session.pairing_id).exists());
        assert!(!enrolled_path(&f.state(), &session.pairing_id).exists());
    }

    #[test]
    fn ending_is_idempotent() {
        let f = Fixture::new();
        let session = f.begin(NOW);
        end_pairing(f.home(), &f.state(), &session.pairing_id).unwrap();
        end_pairing(f.home(), &f.state(), &session.pairing_id).unwrap();
        assert_eq!(f.keys(), "");
    }

    // The lock end_pairing's edit runs under is the one pair-accept commits
    // under, so an accept that already committed keeps its Device Key line and
    // an accept that has not committed yet finds no pending state and rejects.
    #[test]
    fn an_enrollment_committed_before_the_close_keeps_its_device_key_line() {
        let f = Fixture::new();
        f.set_keys(&[USER_LINE]);
        let session = f.begin(now_seconds());

        let accept = accept_with_input(
            f.home(),
            &f.state(),
            &session.pairing_id,
            &format!("{DEVICE_LINE}\n"),
        );
        assert_eq!(accept.0, 0, "{}", accept.2);

        end_pairing(f.home(), &f.state(), &session.pairing_id).unwrap();
        assert_eq!(f.keys(), format!("{USER_LINE}\n{DEVICE_LINE}\n"));
        assert!(!pending_path(&f.state(), &session.pairing_id).exists());
        assert!(!enrolled_path(&f.state(), &session.pairing_id).exists());
    }

    #[test]
    fn an_accept_after_the_close_finds_no_pending_state_and_rejects() {
        let f = Fixture::new();
        f.set_keys(&[USER_LINE]);
        let session = f.begin(now_seconds());

        end_pairing(f.home(), &f.state(), &session.pairing_id).unwrap();

        let late = accept_with_input(
            f.home(),
            &f.state(),
            &session.pairing_id,
            &format!("{DEVICE_LINE}\n"),
        );
        assert_eq!(late.0, 1);
        assert_eq!(late.1.trim(), "HERDR-ENROLL:ERR:unknown_pairing");
        assert_eq!(f.keys(), format!("{USER_LINE}\n"));
    }

    // Pins the lock discipline: the pending and enrolled files must be gone
    // while the authorized_keys edit still holds the lock, before an accept
    // that just got the lock can commit.
    #[test]
    fn ending_clears_the_pending_and_enrolled_state_while_the_lock_is_held() {
        let f = Fixture::new();
        f.set_keys(&[USER_LINE]);
        let session = f.begin(NOW);
        f.enroll_record(&session.pairing_id, None);
        let id = session.pairing_id.clone();

        let mut edit_ran = false;
        end_pairing_with(f.home(), &f.state(), &id, |home, teardown| {
            edit_authorized_keys(home, |lines| {
                edit_ran = true;
                let kept = teardown(lines)?;
                assert!(
                    !pending_path(&f.state(), &id).exists(),
                    "pending removed while the lock is held"
                );
                assert!(
                    !enrolled_path(&f.state(), &id).exists(),
                    "enrolled removed while the lock is held"
                );
                Ok(kept)
            })
        })
        .unwrap();
        assert!(edit_ran, "the teardown must run inside the injected edit");

        assert_eq!(f.keys(), format!("{USER_LINE}\n"));
    }
}
