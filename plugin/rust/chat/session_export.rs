//! `<harness> export` for the Chat Mode reader (session-export.js, ADR 0025):
//! opencode, kilo and hermes keep sessions in their own databases and write
//! no transcript file, so the reader asks the harness itself, once per read
//! or media fetch, and lists the sessions a launch could have started.
//!
//! One deliberate difference from the JS: `runExporter` puts the directory of
//! the running Node on the child's PATH (kilo is a node script). There is no
//! Node here; the caller's PATH is passed through unchanged.

use std::io::Read;
use std::os::unix::process::CommandExt;
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::thread;
use std::time::{Duration, Instant};

use regex::Regex;
use serde_json::Value;

use crate::chat::shared::{AbortSignal, ChatError, ChatResult, Found, check_abort};
use crate::env::Env;
use crate::jspath;
use crate::jsx;

/// One export can take a few seconds for a long session.
pub const EXPORT_TIMEOUT: Duration = Duration::from_secs(60);
/// An export larger than this is refused rather than read into memory.
const MAX_EXPORT_BYTES: u64 = 512 * 1024 * 1024;

/// What the exporter calls take: the environment and home of the Agent's
/// Host, the time limit and the abort signal.
#[derive(Clone)]
pub struct ExportOptions {
    pub env: Env,
    pub home: String,
    pub timeout: Duration,
    pub signal: Option<Arc<AbortSignal>>,
}

impl ExportOptions {
    pub fn new(env: Env, home: impl Into<String>) -> Self {
        Self {
            env,
            home: home.into(),
            timeout: EXPORT_TIMEOUT,
            signal: None,
        }
    }
}

struct Exporter {
    binary: &'static str,
    roots: fn(&str) -> Vec<String>,
    /// The session ids it makes.
    id: fn(&str) -> bool,
    args: fn(&str) -> Vec<String>,
    /// How to list the sessions a launch could have started.
    list_args: &'static [&'static str],
    list_in_cwd: bool,
}

/// `/^ses_[A-Za-z0-9_-]+$/`
fn is_opencode_id(id: &str) -> bool {
    id.strip_prefix("ses_").is_some_and(|rest| {
        !rest.is_empty()
            && rest
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
    })
}

/// `/^\d{8}_\d{6}_[0-9a-f]{6}$/`
fn is_hermes_id(id: &str) -> bool {
    let bytes = id.as_bytes();
    bytes.len() == 8 + 1 + 6 + 1 + 6
        && bytes[..8].iter().all(u8::is_ascii_digit)
        && bytes[8] == b'_'
        && bytes[9..15].iter().all(u8::is_ascii_digit)
        && bytes[15] == b'_'
        && bytes[16..]
            .iter()
            .all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

/// The system directory every exporter's install roots end with. Unit tests
/// look in a directory that does not exist, so a harness installed on the test
/// host (opencode in `/usr/local/bin`, say) never answers a "no binary" case.
fn system_bin() -> String {
    if cfg!(test) {
        "/nonexistent/waycar-test-system-bin".into()
    } else {
        "/usr/local/bin".into()
    }
}

fn exporter(kind: &str) -> Option<Exporter> {
    Some(match kind {
        "opencode" => Exporter {
            binary: "opencode",
            roots: |home| vec![jspath::join(&[home, ".opencode", "bin"]), system_bin()],
            id: is_opencode_id,
            args: |id| vec!["export".into(), id.into()],
            list_args: &["session", "list", "--format", "json", "--pure"],
            list_in_cwd: true,
        },
        "kilo" => Exporter {
            binary: "kilo",
            roots: |home| vec![jspath::join(&[home, ".npm-global", "bin"]), system_bin()],
            id: is_opencode_id,
            args: |id| vec!["export".into(), id.into()],
            list_args: &["session", "list", "--format", "json", "--pure"],
            list_in_cwd: true,
        },
        "hermes" => Exporter {
            binary: "hermes",
            roots: |home| vec![jspath::join(&[home, ".local", "bin"]), system_bin()],
            id: is_hermes_id,
            args: |id| {
                [
                    "sessions",
                    "export",
                    "--format",
                    "jsonl",
                    "--session-id",
                    id,
                    "-",
                ]
                .iter()
                .map(|s| (*s).to_string())
                .collect()
            },
            list_args: &["sessions", "list", "--limit", "50"],
            list_in_cwd: false,
        },
        _ => return None,
    })
}

/// Whether `kind` is read through an export command.
pub fn exports_sessions(kind: &str) -> bool {
    exporter(kind).is_some()
}

/// A harness's stderr when it does not know the session (opencode, kilo):
/// `/session not found/i`.
fn session_not_found(stderr: &str) -> bool {
    stderr.to_lowercase().contains("session not found")
}

fn is_executable(path: &str) -> bool {
    let Ok(c_path) = std::ffi::CString::new(path) else {
        return false;
    };
    // SAFETY: c_path is a valid NUL-terminated string for the call.
    unsafe { libc::access(c_path.as_ptr(), libc::X_OK) == 0 }
}

/// The harness binary on PATH, else its usual install roots, else None.
pub fn resolve_export_binary(kind: &str, env: &Env, home: &str) -> Option<String> {
    let exporter = exporter(kind)?;
    let path_dirs: Vec<String> = env
        .get("PATH")
        .filter(|p| !p.is_empty())
        .map(|p| {
            p.split(':')
                .filter(|d| jspath::is_absolute(d))
                .map(String::from)
                .collect()
        })
        .unwrap_or_default();
    path_dirs
        .into_iter()
        .chain((exporter.roots)(home))
        .map(|dir| jspath::join(&[&dir, exporter.binary]))
        .find(|candidate| is_executable(candidate))
}

/// One session's export as a parsed JSON object with a `messages` array.
/// Fails with a `SessionExportError`-kind error, or the signal's reason when
/// it fires (the exporter is killed at once).
pub fn session_export(
    kind: &str,
    session_id: &Value,
    options: &ExportOptions,
) -> ChatResult<Value> {
    let Some(exporter) = exporter(kind) else {
        return Err(ChatError::export(
            format!("{kind} has no session export"),
            false,
            false,
        ));
    };
    // Marker and request values reach this argv element; anything that is not
    // an id the harness could have made is refused before spawning, so no
    // other flag or option can ride in.
    let id = session_id.as_str().filter(|id| (exporter.id)(id));
    let Some(id) = id else {
        let shown = match session_id {
            Value::Null => String::new(),
            Value::String(s) => s.clone(),
            other => jsx::stringify(other),
        };
        let head: String = shown
            .encode_utf16()
            .take(40)
            .collect::<Vec<u16>>()
            .pipe_utf16();
        let mut quoted = String::new();
        jsx::write_json_string(&head, &mut quoted);
        return Err(ChatError::export(
            format!("not a {kind} session id: {quoted}"),
            false,
            true,
        ));
    };
    let stdout = run_exporter(kind, "export", &(exporter.args)(id), None, options)?;
    let Some(data) = jsx::parse_json(&stdout) else {
        return Err(ChatError::export(
            format!("{} export did not print JSON", exporter.binary),
            true,
            false,
        ));
    };
    if !jsx::field(&data, "messages").is_array() || !data.is_object() {
        return Err(ChatError::export(
            format!(
                "{} export printed JSON without a messages array",
                exporter.binary
            ),
            true,
            false,
        ));
    }
    Ok(data)
}

/// `String(x).slice(0, 40)` helper: UTF-16 units back to a string, a cut
/// surrogate dropped (a Rust string cannot hold half a pair).
trait PipeUtf16 {
    fn pipe_utf16(self) -> String;
}

impl PipeUtf16 for Vec<u16> {
    fn pipe_utf16(self) -> String {
        String::from_utf16_lossy(&self).replace('\u{fffd}', "")
    }
}

/// A session a launch could have started (launch match, no session id).
pub struct Candidate {
    pub id: String,
    /// Epoch ms.
    pub created: f64,
    pub updated: f64,
    /// True when `probe()` runs a whole export.
    pub exports: bool,
    probe: Box<dyn Fn() -> Option<Found>>,
}

impl Candidate {
    /// The session's `{cwd, created}`, or None for one that is never an
    /// Agent's (another session spawned it, or it is an Agent Summary's
    /// `tool` session).
    pub fn probe(&self) -> Option<Found> {
        (self.probe)()
    }
}

/// The sessions an Agent launched in `cwd` could have started.
///
/// `opencode session list --format json` and `kilo session list --format
/// json` print `[{id, title, updated, created, projectId, directory}]` for
/// the project of the directory they run in. hermes has no machine-readable
/// list, so its table (`hermes sessions list`, newest activity first) gives
/// the ids; an id is `YYYYMMDD_HHMMSS_<hex>` in the local time hermes ran in,
/// read here in this process's local time (the Host's).
pub fn launch_candidates(
    kind: &str,
    cwd: &Value,
    options: &ExportOptions,
) -> ChatResult<Vec<Candidate>> {
    let Some(exporter) = exporter(kind) else {
        return Err(ChatError::export(
            format!("{kind} has no session export"),
            false,
            false,
        ));
    };
    let Some(cwd) = cwd.as_str().filter(|c| jspath::is_absolute(c)) else {
        let shown = match cwd {
            Value::Null => String::new(),
            Value::String(s) => s.clone(),
            other => jsx::stringify(other),
        };
        let head: Vec<u16> = shown.encode_utf16().take(80).collect();
        let mut quoted = String::new();
        jsx::write_json_string(&head.pipe_utf16(), &mut quoted);
        return Err(ChatError::export(
            format!("no launch directory: {quoted}"),
            false,
            false,
        ));
    };
    let args: Vec<String> = exporter
        .list_args
        .iter()
        .map(|s| (*s).to_string())
        .collect();
    let stdout = run_exporter(
        kind,
        "session list",
        &args,
        exporter.list_in_cwd.then_some(cwd),
        options,
    )?;
    let entries = match kind {
        "hermes" => parse_hermes_list(&stdout, options),
        _ => parse_opencode_list(&stdout)?,
    };
    Ok(entries
        .into_iter()
        .filter(|entry| (exporter.id)(&entry.id) && entry.created.is_finite())
        .collect())
}

fn parse_opencode_list(stdout: &str) -> ChatResult<Vec<Candidate>> {
    let Some(list) = jsx::parse_json(stdout) else {
        return Err(ChatError::export(
            "session list did not print JSON",
            true,
            false,
        ));
    };
    let Some(list) = list.as_array() else {
        return Err(ChatError::export(
            "session list printed JSON that is not a list",
            true,
            false,
        ));
    };
    let mut out = Vec::new();
    for session in list {
        let Some(id) = jsx::field(session, "id").as_str() else {
            continue;
        };
        let created = match jsx::field(session, "created") {
            Value::Number(n) => jsx::json_f64(n),
            _ => continue,
        };
        let updated = match jsx::field(session, "updated") {
            Value::Number(n) if jsx::json_f64(n).is_finite() => jsx::json_f64(n),
            _ => created,
        };
        let found = Found {
            cwd: jsx::field(session, "directory")
                .as_str()
                .map(str::to_string),
            created: Some(created),
        };
        out.push(Candidate {
            id: id.to_string(),
            created,
            updated,
            exports: false,
            probe: Box::new(move || Some(found.clone())),
        });
    }
    Ok(out)
}

fn parse_hermes_list(stdout: &str, options: &ExportOptions) -> Vec<Candidate> {
    // `\b` and `\d` are ASCII in JavaScript.
    let pattern = Regex::new(r"(?-u:\b)([0-9]{4})([0-9]{2})([0-9]{2})_([0-9]{2})([0-9]{2})([0-9]{2})_[0-9a-f]{6}(?-u:\b)")
        .expect("hermes id pattern");
    let mut seen: Vec<String> = Vec::new();
    let mut out = Vec::new();
    for line in stdout.split('\n') {
        // The id is the last column; a title could hold something id-shaped too.
        let Some(found) = pattern.captures_iter(line).last() else {
            continue;
        };
        let id = found[0].to_string();
        if seen.contains(&id) {
            continue;
        }
        seen.push(id.clone());
        let part = |n: usize| found[n].parse::<i64>().unwrap_or(0);
        let started = jsx::local_time_ms(part(1), part(2) - 1, part(3), part(4), part(5), part(6))
            .unwrap_or(f64::NAN);
        let options = options.clone();
        let probe_id = id.clone();
        out.push(Candidate {
            id,
            created: started,
            updated: started,
            exports: true,
            probe: Box::new(move || probe_hermes(&probe_id, &options)),
        });
    }
    out
}

/// A hermes session's recorded `{cwd, created}`, or None when it is never an
/// Agent's or cannot be exported.
fn probe_hermes(id: &str, options: &ExportOptions) -> Option<Found> {
    let data = session_export("hermes", &Value::String(id.to_string()), options).ok()?;
    if jsx::truthy(jsx::field(&data, "parent_session_id")) || jsx::field(&data, "source") == "tool"
    {
        return None;
    }
    // `Number(undefined)` is NaN, `Number(null)` is 0.
    let started = jsx::get(&data, "started_at").map_or(f64::NAN, jsx::to_number) * 1000.0;
    Some(Found {
        cwd: jsx::field(&data, "cwd").as_str().map(str::to_string),
        created: started.is_finite().then_some(started),
    })
}

/// Run one exporter command to completion and return its stdout. Not
/// located for a missing binary or a failed run, located for output over the
/// size cap. When the signal fires the process group is killed and the run
/// fails with the signal's reason.
fn run_exporter(
    kind: &str,
    what: &str,
    args: &[String],
    cwd: Option<&str>,
    options: &ExportOptions,
) -> ChatResult<String> {
    let exporter = exporter(kind).expect("kind has an exporter");
    let Some(bin) = resolve_export_binary(kind, &options.env, &options.home) else {
        return Err(ChatError::export(
            format!(
                "the {} binary was not found on PATH or in its install roots",
                exporter.binary
            ),
            false,
            true,
        ));
    };
    if kind == "opencode" {
        let version = run_export_command(
            &exporter,
            &bin,
            "--version",
            &["--version".into()],
            None,
            options,
        )?;
        let mut words = version.split_whitespace();
        if words.next() == Some("opencode") && words.next().is_some_and(|v| v.starts_with("v2.")) {
            let (url, password) = opencode_server(options)?;
            let mut args = args.to_vec();
            if what == "export" {
                args.insert(0, "session".into());
            } else {
                args.retain(|arg| arg != "--pure");
            }
            args.extend(["--server".into(), url]);
            let mut options = options.clone();
            // Never put this credential on argv: process listings expose it.
            options.env.set("OPENCODE_PASSWORD", password);
            return run_export_command(&exporter, &bin, what, &args, cwd, &options).map_err(
                |error| {
                    let lower = error.message.to_lowercase();
                    if lower.contains("could not reach server") || lower.contains("econnrefused") {
                        opencode_not_running()
                    } else {
                        error
                    }
                },
            );
        }
    }
    run_export_command(&exporter, &bin, what, args, cwd, options)
}

fn opencode_not_running() -> ChatError {
    ChatError::export(
        "OpenCode server not running; start OpenCode on the Host",
        true,
        false,
    )
}

/// Reading the registration and passing --server prevents OpenCode 2's CLI
/// from auto-starting its shared service, including when this file is stale.
fn opencode_server(options: &ExportOptions) -> ChatResult<(String, String)> {
    let state = options
        .env
        .absolute("XDG_STATE_HOME")
        .unwrap_or_else(|| std::path::PathBuf::from(&options.home).join(".local/state"));
    let service = std::fs::read_to_string(state.join("opencode/service.json"))
        .ok()
        .and_then(|text| jsx::parse_json(&text))
        .ok_or_else(opencode_not_running)?;
    let url = service
        .get("url")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .ok_or_else(opencode_not_running)?;
    let password = service
        .get("password")
        .and_then(Value::as_str)
        .ok_or_else(opencode_not_running)?;
    Ok((url.into(), password.into()))
}

fn run_export_command(
    exporter: &Exporter,
    bin: &str,
    what: &str,
    args: &[String],
    cwd: Option<&str>,
    options: &ExportOptions,
) -> ChatResult<String> {
    check_abort(options.signal.as_deref())?;
    // No shell: the session id is one argv element, never quoted text. The
    // exporter leads its own process group, and a timeout or the size cap
    // SIGKILLs the whole group: kilo's wrapper runs the native binary as a
    // child, which would otherwise outlive it and hold the pipes open.
    let mut command = Command::new(bin);
    command
        .args(args)
        .env_clear()
        .envs(options.env.iter())
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .process_group(0);
    if let Some(cwd) = cwd {
        command.current_dir(cwd);
    }
    let mut child = match command.spawn() {
        Ok(child) => child,
        // Node's `error` event: the exit code is null ("without starting").
        Err(_) => {
            return Err(ChatError::export(
                format!("{} {what} exited without starting", exporter.binary),
                false,
                false,
            ));
        }
    };
    let pid = child.id() as libc::pid_t;
    let kill = move || {
        // SAFETY: the child leads its own process group (process_group(0)).
        unsafe { libc::kill(-pid, libc::SIGKILL) };
    };

    let bytes = Arc::new(AtomicU64::new(0));
    let too_big = Arc::new(AtomicBool::new(false));
    let collect = |pipe: Option<Box<dyn Read + Send>>| {
        let bytes = Arc::clone(&bytes);
        let too_big = Arc::clone(&too_big);
        thread::spawn(move || {
            let mut data = Vec::new();
            let Some(mut pipe) = pipe else {
                return data;
            };
            let mut chunk = [0u8; 64 * 1024];
            while let Ok(read) = pipe.read(&mut chunk) {
                if read == 0 {
                    break;
                }
                data.extend_from_slice(&chunk[..read]);
                let total = bytes.fetch_add(read as u64, Ordering::SeqCst) + read as u64;
                if total > MAX_EXPORT_BYTES && !too_big.swap(true, Ordering::SeqCst) {
                    // SAFETY: as above.
                    unsafe { libc::kill(-pid, libc::SIGKILL) };
                }
            }
            data
        })
    };
    let out_thread = collect(
        child
            .stdout
            .take()
            .map(|p| Box::new(p) as Box<dyn Read + Send>),
    );
    let err_thread = collect(
        child
            .stderr
            .take()
            .map(|p| Box::new(p) as Box<dyn Read + Send>),
    );

    let deadline = Instant::now() + options.timeout;
    let mut killed = false;
    let mut aborted = false;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Some(status),
            Ok(None) => {}
            Err(_) => break None,
        }
        if !aborted && options.signal.as_ref().is_some_and(|s| s.is_aborted()) {
            aborted = true;
            kill();
        }
        if !killed && Instant::now() >= deadline {
            killed = true;
            kill();
        }
        thread::sleep(Duration::from_millis(5));
    };
    let stdout = out_thread.join().unwrap_or_default();
    let stderr = err_thread.join().unwrap_or_default();
    // Anything the group left behind goes with it.
    kill();
    check_abort(options.signal.as_deref())?;
    if too_big.load(Ordering::SeqCst) {
        return Err(ChatError::export(
            format!(
                "the export is over {} MiB",
                MAX_EXPORT_BYTES / (1024 * 1024)
            ),
            true,
            false,
        ));
    }
    let code = status.and_then(|s| s.code());
    if code != Some(0) {
        let stderr_text = String::from_utf8_lossy(&stderr);
        let detail = {
            let last = last_line(&stderr_text);
            if !last.is_empty() {
                last
            } else if killed {
                format!(
                    "no output within {}s",
                    (options.timeout.as_millis() as f64 / 1000.0).round()
                )
            } else {
                match code {
                    Some(code) => format!("exited {code}"),
                    None => "exited without starting".into(),
                }
            }
        };
        return Err(ChatError::export(
            format!("{} {what} {detail}", exporter.binary),
            false,
            !killed && session_not_found(&stderr_text),
        ));
    }
    Ok(String::from_utf8_lossy(&stdout).into_owned())
}

/// The last non-empty line, clipped: a progress line comes first on stderr.
fn last_line(text: &str) -> String {
    let Some(line) = text.split('\n').rfind(|l| !jsx::trim(l).is_empty()) else {
        return String::new();
    };
    let line = jsx::trim(line);
    let head: Vec<u16> = line.encode_utf16().take(200).collect();
    head.pipe_utf16()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::fs;

    fn stage(script: &str) -> (std::path::PathBuf, ExportOptions) {
        stage_version("1.19.5", script)
    }

    fn stage_version(version: &str, script: &str) -> (std::path::PathBuf, ExportOptions) {
        let dir = std::env::temp_dir().join(format!(
            "wc-export-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(dir.join("bin")).unwrap();
        let bin = dir.join("bin/opencode");
        crate::test_support::write_stub(
            &bin,
            &format!(
                "#!/bin/sh\nif [ \"$1\" = --version ]; then printf '%s\\n' '{version}'; exit 0; fi\n{}",
                script.strip_prefix("#!/bin/sh\n").unwrap_or(script),
            ),
        );
        let env = Env::from_pairs([(
            "PATH",
            format!("{}:/usr/bin:/bin", dir.join("bin").display()),
        )]);
        let options = ExportOptions::new(env, dir.to_string_lossy());
        (dir, options)
    }

    fn stage_service(dir: &std::path::Path) {
        let state = dir.join(".local/state/opencode");
        fs::create_dir_all(&state).unwrap();
        fs::write(
            state.join("service.json"),
            r#"{"url":"http://127.0.0.1:49374","password":"fixture-password"}"#,
        )
        .unwrap();
    }

    #[test]
    fn opencode_v2_export_and_list_always_target_the_registered_server_with_env_auth() {
        let (dir, options) = stage_version(
            " \n opencode \t v2.2.7 \n",
            r#"#!/bin/sh
printf '%s\n' "$*" "$OPENCODE_PASSWORD" "$PWD" >> "$RECORD"
case "$*" in
  'session export ses_ok --server http://127.0.0.1:49374') echo '{"messages":[]}' ;;
  'session list --format json --server http://127.0.0.1:49374') cat "$LIST" ;;
  *) echo 'unsafe argv' >&2; exit 9 ;;
esac
"#,
        );
        stage_service(&dir);
        // Exercise XDG_STATE_HOME, not just the default location.
        let state = dir.join("state");
        fs::rename(dir.join(".local/state"), &state).unwrap();
        let mut options = options;
        options.env.set("XDG_STATE_HOME", state.to_string_lossy());
        options
            .env
            .set("RECORD", dir.join("calls").to_string_lossy());
        options.env.set(
            "LIST",
            format!(
                "{}/test/fixtures/opencode2-session-list.json",
                env!("CARGO_MANIFEST_DIR")
            ),
        );
        session_export("opencode", &Value::String("ses_ok".into()), &options).unwrap();
        let candidates = launch_candidates(
            "opencode",
            &Value::String(dir.to_string_lossy().into()),
            &options,
        )
        .unwrap();
        assert_eq!(candidates.len(), 1);
        assert_eq!(candidates[0].id, "ses_waycarFixture0001");
        assert_eq!(
            candidates[0].probe().unwrap().cwd.as_deref(),
            Some("/home/waycar/proj")
        );
        let calls = fs::read_to_string(dir.join("calls")).unwrap();
        let lines: Vec<_> = calls.lines().collect();
        assert_eq!(
            lines[0],
            "session export ses_ok --server http://127.0.0.1:49374"
        );
        assert_eq!(lines[1], "fixture-password");
        assert_eq!(
            lines[3],
            "session list --format json --server http://127.0.0.1:49374"
        );
        assert_eq!(lines[4], "fixture-password");
        assert_eq!(std::path::Path::new(lines[5]), dir);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn opencode_v2_missing_or_unreachable_server_never_falls_back_to_plain_commands() {
        let (dir, mut options) = stage_version(
            "opencode v2.2.7",
            r#"#!/bin/sh
printf '%s\n' "$*" >> "$RECORD"
echo 'Could not reach server at http://127.0.0.1:49374: ECONNREFUSED' >&2
exit 1
"#,
        );
        options
            .env
            .set("RECORD", dir.join("calls").to_string_lossy());
        for service_exists in [false, true] {
            if service_exists {
                stage_service(&dir);
            }
            let export_error = session_export("opencode", &json!("ses_ok"), &options).unwrap_err();
            let list_error = launch_candidates("opencode", &json!(dir.to_string_lossy()), &options)
                .err()
                .unwrap();
            for error in [export_error, list_error] {
                assert!(
                    error.message.contains("OpenCode server not running"),
                    "{}",
                    error.message
                );
                assert_eq!(
                    error.kind,
                    crate::chat::shared::ErrorKind::Export {
                        located: true,
                        absent: false
                    }
                );
            }
            if !service_exists {
                assert!(!dir.join("calls").exists());
            }
        }
        assert_eq!(
            fs::read_to_string(dir.join("calls")).unwrap(),
            "session export ses_ok --server http://127.0.0.1:49374\nsession list --format json --server http://127.0.0.1:49374\n"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn opencode_v1_keeps_the_original_export_and_list_arguments() {
        let (dir, mut options) = stage_version(
            " \n 1.19.5 \n",
            r#"#!/bin/sh
printf '%s\n' "$*" >> "$RECORD"
case "$*" in
  'export ses_ok') echo '{"messages":[]}' ;;
  'session list --format json --pure') echo '[]' ;;
  *) exit 9 ;;
esac
"#,
        );
        options
            .env
            .set("RECORD", dir.join("calls").to_string_lossy());
        session_export("opencode", &json!("ses_ok"), &options).unwrap();
        launch_candidates("opencode", &json!(dir.to_string_lossy()), &options).unwrap();
        assert_eq!(
            fs::read_to_string(dir.join("calls")).unwrap(),
            "export ses_ok\nsession list --format json --pure\n"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn ids_are_checked_before_anything_runs() {
        let options = ExportOptions::new(Env::default(), "/nonexistent");
        let error =
            session_export("opencode", &Value::String("--help".into()), &options).unwrap_err();
        assert_eq!(error.message, "not a opencode session id: \"--help\"");
        assert_eq!(
            error.kind,
            crate::chat::shared::ErrorKind::Export {
                located: false,
                absent: true
            }
        );
        // hermes: not on the empty PATH, and `system_bin` is a dead end in tests.
        let error = session_export(
            "hermes",
            &Value::String("20260930_120000_0a1b2c".into()),
            &options,
        )
        .unwrap_err();
        assert_eq!(
            error.message,
            "the hermes binary was not found on PATH or in its install roots"
        );
        assert!(
            session_export("grok", &Value::Null, &options)
                .unwrap_err()
                .message
                .contains("has no session export")
        );
    }

    #[test]
    fn an_export_is_parsed_and_a_failure_names_the_last_stderr_line() {
        let (dir, options) =
            stage("#!/bin/sh\necho 'Exporting session: x' >&2\necho '{\"messages\":[1]}'\n");
        let data = session_export("opencode", &Value::String("ses_ok".into()), &options).unwrap();
        assert_eq!(data["messages"][0], 1);
        let _ = fs::remove_dir_all(&dir);

        let (dir, options) =
            stage("#!/bin/sh\necho 'progress' >&2\necho 'Session not found: ses_x' >&2\nexit 3\n");
        let error =
            session_export("opencode", &Value::String("ses_x".into()), &options).unwrap_err();
        assert_eq!(error.message, "opencode export Session not found: ses_x");
        assert_eq!(
            error.kind,
            crate::chat::shared::ErrorKind::Export {
                located: false,
                absent: true
            }
        );
        let _ = fs::remove_dir_all(&dir);

        let (dir, options) = stage("#!/bin/sh\necho 'nope'\n");
        let error =
            session_export("opencode", &Value::String("ses_x".into()), &options).unwrap_err();
        assert_eq!(error.message, "opencode export did not print JSON");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_slow_export_is_killed_at_the_timeout() {
        let (dir, mut options) = stage("#!/bin/sh\nsleep 30\n");
        options.timeout = Duration::from_millis(200);
        let error =
            session_export("opencode", &Value::String("ses_x".into()), &options).unwrap_err();
        assert_eq!(error.message, "opencode export no output within 0s");
        assert_eq!(
            error.kind,
            crate::chat::shared::ErrorKind::Export {
                located: false,
                absent: false
            }
        );
        let _ = fs::remove_dir_all(&dir);
    }

    /// A killed child whose parent is gone stays a zombie until PID 1 reaps
    /// it, and a CI container's PID 1 may never do so: a zombie counts as dead.
    fn is_alive(pid: u32) -> bool {
        // SAFETY: signal 0 only probes.
        if unsafe { libc::kill(pid as libc::pid_t, 0) } != 0 {
            return false;
        }
        let stat = fs::read_to_string(format!("/proc/{pid}/stat")).unwrap_or_default();
        let state = stat
            .rsplit_once(')')
            .map_or("", |(_, rest)| rest.trim_start());
        !state.starts_with('Z')
    }

    #[test]
    fn a_hung_export_is_killed_with_every_child_it_started_so_the_timeout_returns() {
        // The wrapper's child inherits its stdout and stderr and never exits:
        // killing the wrapper alone would leave the pipes open.
        let dir = std::env::temp_dir().join(format!(
            "wc-export-hung-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&dir).unwrap();
        let pid_file = dir.join("child.pid");
        let bin = dir.join("kilo");
        crate::test_support::write_stub(
            &bin,
            &format!(
                "#!/bin/sh\nsleep 30 &\necho $! > '{}'\nwait\n",
                pid_file.display()
            ),
        );
        let env = Env::from_pairs([("PATH", format!("{}:/usr/bin:/bin", dir.display()))]);
        let mut options = ExportOptions::new(env, dir.to_string_lossy());
        options.timeout = Duration::from_millis(500);
        let started = Instant::now();

        let error =
            session_export("kilo", &Value::String("ses_hung".into()), &options).unwrap_err();

        assert!(matches!(
            error.kind,
            crate::chat::shared::ErrorKind::Export { .. }
        ));
        assert!(
            error.message.contains("no output within"),
            "{}",
            error.message
        );
        assert!(
            started.elapsed() < Duration::from_secs(5),
            "took {:?}",
            started.elapsed()
        );
        let child: u32 = fs::read_to_string(&pid_file)
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(1);
        while is_alive(child) && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(50));
        }
        assert!(!is_alive(child), "the native child outlived the timeout");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn hermes_sessions_come_from_its_table_newest_first_without_duplicates() {
        let options = ExportOptions::new(Env::default(), "/h");
        let table = "title 20260101_000000_abcdef  20260930_120000_0a1b2c\nother 20260930_120000_0a1b2c\nx 20260929_080000_ffffff\n";
        let found = parse_hermes_list(table, &options);
        let ids: Vec<&str> = found.iter().map(|c| c.id.as_str()).collect();
        assert_eq!(ids, ["20260930_120000_0a1b2c", "20260929_080000_ffffff"]);
        assert!(found.iter().all(|c| c.exports && c.created == c.updated));
    }
}
