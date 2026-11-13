//! The tests of agent-summary.test.js against real child processes: a stub
//! herdr CLI answering `pane read`, a fake `tmux`, and stub harness
//! executables standing in for omp, claude, or a `summary_command`. The JS
//! stubs are Node scripts; these are `/bin/sh` scripts (the stubs call
//! absolute tool paths, so their `PATH` holds nothing else and no installed
//! harness is ever found). Table-driven JS tests iterate inside one test.

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime};

use serde_json::{Value, json};

use super::*;
use crate::summary::test_support::TempDir;

const PANE_ID: &str = "wV:p1";
const SCREEN: &str = "\u{1b}[1m● Merge PR #512 into main?\u{1b}[0m\n  1. Yes\n  2. No\n\n\n";
const FLAT_SCREEN: &str = "● Merge PR #512 into main?\n  1. Yes\n  2. No";

fn sq(text: &str) -> String {
    format!("'{}'", text.replace('\'', "'\\''"))
}

fn write_executable(path: &str, content: &str) {
    crate::test_support::write_stub(Path::new(path), content);
}

/// A probe answer: stdout, stderr, exit code.
#[derive(Clone, Default)]
struct Probe {
    stdout: &'static str,
    stderr: &'static str,
    code: i32,
}

/// What a stub harness does (see [`Lab::harness`]).
#[derive(Default)]
struct Behavior {
    stdout: &'static str,
    code: i32,
    hang: bool,
    probes: Vec<(&'static str, Probe)>,
    out_flag: Option<&'static str>,
    /// Make the session directory copilot would record under its id.
    session: bool,
}

/// One recorded harness call.
#[derive(Debug)]
struct Call {
    name: String,
    argv: Vec<String>,
    stdin: String,
    cwd: String,
    env: String,
}

impl Call {
    fn value_after(&self, flag: &str) -> &str {
        let at = self.argv.iter().position(|a| a == flag).expect(flag);
        &self.argv[at + 1]
    }

    fn has(&self, flag: &str) -> bool {
        self.argv.iter().any(|a| a == flag)
    }

    fn last(&self) -> &str {
        self.argv.last().unwrap()
    }
}

struct Lab {
    dir: TempDir,
    /// Where a stand-in core listens: a unix socket path must stay under 108
    /// bytes, which a long `TMPDIR` would break, so it is a short directory.
    run: PathBuf,
    /// Sockets a stand-in core listens on, for the probe that asks nothing.
    listeners: std::cell::RefCell<Vec<std::os::unix::net::UnixListener>>,
}

impl Drop for Lab {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.run);
    }
}

impl Lab {
    fn new() -> Self {
        static COUNTER: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let run = PathBuf::from("/tmp").join(format!(
            "wl-{}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        ));
        let _ = fs::remove_dir_all(&run);
        fs::create_dir_all(&run).unwrap();
        Self {
            dir: TempDir::new("agent-summary"),
            run,
            listeners: std::cell::RefCell::default(),
        }
    }

    /// Something listens on `socket`, as a running core does: `running_core`
    /// connects to it before it runs anything.
    fn listen(&self, socket: &Path) {
        fs::create_dir_all(socket.parent().unwrap()).unwrap();
        let listener = std::os::unix::net::UnixListener::bind(socket).unwrap();
        self.listeners.borrow_mut().push(listener);
    }

    /// The default socket of the core `XDG_RUNTIME_DIR` names.
    fn default_socket(&self) -> PathBuf {
        self.run.join("herdr-core/default.sock")
    }

    fn path(&self, name: &str) -> String {
        self.dir.join(name)
    }

    /// Stub harness `name`. A detection probe (`claude auth status`, `omp
    /// token <provider> --list`, `codex login status`, `pi auth check ...`)
    /// is logged under probes/ and answered from `probes` (default:
    /// `{"loggedIn":true}`, exit 0). Any other call logs its argv, stdin, cwd
    /// and the interesting environment under calls/<n>/, records its pid,
    /// then prints `stdout` and exits `code`, or never exits when `hang` is
    /// set. With `out_flag`, the answer goes to the file after that flag
    /// instead (codex's `-o`).
    fn harness(&self, name: &str, behavior: Behavior) -> String {
        let mut script = vec![
            "#!/bin/sh".to_string(),
            "D=${0%/*}".to_string(),
            "case \"$1\" in auth|token|login)".to_string(),
            "  key=\"$*\"".to_string(),
            "  /bin/mkdir -p \"$D/probes\"".to_string(),
            format!(
                "  f=$(printf '%s' {}\" $key\" | /usr/bin/tr ' /' '__')",
                sq(name)
            ),
            format!(
                "  printf '%s %s\\n' {} \"$key\" > \"$D/probes/$f\"",
                sq(name)
            ),
        ];
        for (key, probe) in &behavior.probes {
            script.push(format!(
                "  if [ \"$key\" = {} ]; then printf '%s' {}; printf '%s' {} >&2; exit {}; fi",
                sq(key),
                sq(probe.stdout),
                sq(probe.stderr),
                probe.code
            ));
        }
        script.push("  printf '%s' '{\"loggedIn\":true}'; exit 0 ;;".to_string());
        script.push("esac".to_string());
        script.push(format!("printf '%s' $$ > \"$D/{name}.pid\""));
        script.push("n=0; while [ -e \"$D/calls/$n\" ]; do n=$((n+1)); done".to_string());
        script.push("d=\"$D/calls/$n\"; /bin/mkdir -p \"$d\"".to_string());
        script.push(format!("printf '%s' {} > \"$d/name\"", sq(name)));
        script.push("for a in \"$@\"; do printf '%s\\0' \"$a\"; done > \"$d/argv\"".to_string());
        script.push("/bin/cat > \"$d/stdin\"".to_string());
        script.push("pwd -P > \"$d/cwd\"".to_string());
        script.push(
            "/usr/bin/env | /usr/bin/grep -E '^(WAYCAR_SUMMARY|HERDR_[A-Z_]*|OPENCODE_CONFIG_CONTENT|KILO_CONFIG_CONTENT)=' | /usr/bin/sort > \"$d/env\""
                .to_string(),
        );
        if behavior.session {
            script.push(
                "for a in \"$@\"; do case \"$a\" in --session-id=*) id=${a#--session-id=}; /bin/mkdir -p \"$HOME/.copilot/session-state/$id\"; printf '{}\\n' > \"$HOME/.copilot/session-state/$id/events.jsonl\" ;; esac; done"
                    .to_string(),
            );
        }
        if behavior.hang {
            script.push("exec /bin/sleep 30".to_string());
        }
        match behavior.out_flag {
            Some(flag) => {
                script.push("prev=".to_string());
                script.push("for a in \"$@\"; do".to_string());
                script.push(format!(
                    "  if [ \"$prev\" = {} ]; then /bin/cat \"$D/{name}.answer\" > \"$a\"; fi",
                    sq(flag)
                ));
                script.push("  prev=$a".to_string());
                script.push("done".to_string());
            }
            None => script.push(format!("/bin/cat \"$D/{name}.answer\"")),
        }
        script.push(format!("exit {}", behavior.code));
        fs::write(self.path(&format!("{name}.answer")), behavior.stdout).unwrap();
        let path = self.path(name);
        write_executable(&path, &format!("{}\n", script.join("\n")));
        path
    }

    fn plain(&self, name: &str, stdout: &'static str) -> String {
        self.harness(
            name,
            Behavior {
                stdout,
                ..Behavior::default()
            },
        )
    }

    /// Stub herdr CLI: `pane read` prints `screen`, or fails when it is `None`.
    fn herdr(&self, screen: Option<&str>) -> String {
        fs::write(self.path("screen.txt"), screen.unwrap_or("")).unwrap();
        let body = if screen.is_some() {
            "/bin/cat \"$D/screen.txt\""
        } else {
            "printf '%s' '{\"error\":{\"code\":\"pane_not_found\"}}'; exit 1"
        };
        let path = self.path("herdr");
        write_executable(
            &path,
            &format!("#!/bin/sh\nD=${{0%/*}}\necho \"$*\" >> \"$D/herdr.log\"\n{body}\n"),
        );
        path
    }

    /// A fake tmux that answers `capture-pane` with `screen` (`None`: fails),
    /// and logs every call; without `-u` first it fails like the real
    /// contract demands.
    fn tmux(&self, screen: Option<&str>) {
        fs::write(self.path("tmux.screen"), screen.unwrap_or("")).unwrap();
        let body = if screen.is_some() {
            "/bin/cat \"$D/tmux.screen\""
        } else {
            "echo \"can't find pane: %3\" >&2; exit 1"
        };
        write_executable(
            &self.path("tmux"),
            &format!(
                "#!/bin/sh\nD=${{0%/*}}\nif [ \"$1\" != \"-u\" ]; then echo 'tmux without -u' >&2; exit 64; fi\nshift\necho \"$*\" >> \"$D/tmux.log\"\nif [ \"$1\" != capture-pane ]; then exit 64; fi\n{body}\n"
            ),
        );
    }

    /// A fake herdr-core: `--version` answers `hc 0.1.14`, `read` prints
    /// `screen` (`None`: fails like a missing terminal); every call is logged
    /// with the `HC_SOCKET` it ran with.
    fn core(&self, screen: Option<&str>) {
        self.listen(&self.default_socket());
        fs::write(self.path("core.screen"), screen.unwrap_or("")).unwrap();
        let body = if screen.is_some() {
            "/bin/cat \"$D/core.screen\""
        } else {
            "echo 'no such terminal' >&2; exit 3"
        };
        write_executable(
            &self.path("herdr-core"),
            &format!(
                "#!/bin/sh\nD=${{0%/*}}\necho \"$*\" >> \"$D/core.log\"\necho \"$HC_SOCKET\" >> \"$D/core.sockets\"\nif [ \"$1\" = --version ]; then echo 'hc 0.1.14'; exit 0; fi\nif [ \"$1\" != read ]; then exit 64; fi\n{body}\n"
            ),
        );
    }

    fn lines(&self, name: &str) -> Vec<String> {
        fs::read_to_string(self.path(name))
            .map(|text| text.lines().map(str::to_string).collect())
            .unwrap_or_default()
    }

    fn probes(&self) -> Vec<String> {
        let mut probes: Vec<String> = fs::read_dir(self.path("probes"))
            .map(|entries| {
                entries
                    .flatten()
                    .map(|e| fs::read_to_string(e.path()).unwrap().trim_end().to_string())
                    .collect()
            })
            .unwrap_or_default();
        probes.sort();
        probes
    }

    fn probed(&self, name: &str) -> Vec<String> {
        self.probes()
            .into_iter()
            .filter(|p| p.split(' ').next() == Some(name))
            .collect()
    }

    fn calls(&self) -> Vec<Call> {
        let mut calls = Vec::new();
        for n in 0.. {
            let dir = self.path(&format!("calls/{n}"));
            if !Path::new(&dir).exists() {
                break;
            }
            let read = |file: &str| fs::read_to_string(format!("{dir}/{file}")).unwrap_or_default();
            calls.push(Call {
                name: read("name"),
                argv: read("argv")
                    .split('\0')
                    .map(str::to_string)
                    .collect::<Vec<_>>()
                    .split_last()
                    .map(|(_, rest)| rest.to_vec())
                    .unwrap_or_default(),
                stdin: read("stdin"),
                cwd: read("cwd").trim_end().to_string(),
                env: read("env"),
            });
        }
        calls
    }

    fn call_names(&self) -> Vec<String> {
        self.calls().into_iter().map(|c| c.name).collect()
    }

    /// The environment for auto-detection: only the stubs on `PATH`, no
    /// provider keys unless `extra` adds them.
    fn env(&self, extra: &[(&str, &str)]) -> Env {
        let mut env = Env::from_pairs([
            ("PATH", self.path("")),
            ("HOME", self.dir.str().to_string()),
            ("HERDR_PLUGIN_CONFIG_DIR", "/should/not/leak".to_string()),
            ("XDG_RUNTIME_DIR", self.run.to_string_lossy().into_owned()),
        ]);
        for (name, value) in extra {
            env.set(*name, *value);
        }
        env
    }

    fn write_home_file(&self, file: &str, content: &str) {
        let path = self.path(file);
        fs::create_dir_all(Path::new(&path).parent().unwrap()).unwrap();
        fs::write(path, content).unwrap();
    }
}

/// A fetch stand-in recording each request and answering from `respond(url)`.
type Respond = Box<dyn Fn(&str) -> (u16, Value) + Sync>;

struct FakeFetch {
    respond: Respond,
    requests: Mutex<Vec<(String, String, Value)>>,
}

impl FakeFetch {
    fn new(respond: impl Fn(&str) -> (u16, Value) + Sync + 'static) -> Self {
        Self {
            respond: Box::new(respond),
            requests: Mutex::new(Vec::new()),
        }
    }

    /// The default of `autoOptions`: any network call is a failure.
    fn unexpected() -> Self {
        Self::new(|_| (599, Value::Null))
    }

    fn urls(&self) -> Vec<String> {
        self.requests
            .lock()
            .unwrap()
            .iter()
            .map(|r| r.0.clone())
            .collect()
    }
}

impl Fetch for FakeFetch {
    fn post_json(
        &self,
        url: &str,
        api_key: &str,
        body: &Value,
        _signal: &AbortSignal,
    ) -> Option<Value> {
        self.requests.lock().unwrap().push((
            url.to_string(),
            format!("Bearer {api_key}"),
            body.clone(),
        ));
        let (status, body) = (self.respond)(url);
        (200..300).contains(&status).then_some(body)
    }
}

/// The options of the JS `autoOptions`: stub env, no fallback `PATH`, a
/// private cache dir.
struct Auto<'a> {
    lab: &'a Lab,
    bin_path: String,
    status: &'static str,
    env: Env,
    fetch: FakeFetch,
    command: Option<Vec<String>>,
    timeout: Duration,
    pane_id: &'static str,
}

impl<'a> Auto<'a> {
    fn new(lab: &'a Lab) -> Self {
        Self {
            lab,
            bin_path: lab.herdr(Some(SCREEN)),
            status: "blocked",
            env: lab.env(&[]),
            fetch: FakeFetch::unexpected(),
            command: None,
            timeout: Duration::from_secs(5),
            pane_id: PANE_ID,
        }
    }

    fn cache_dir(&self) -> String {
        self.lab.path("config")
    }

    fn run(&self) -> Generated {
        let work_dir = self.lab.dir.str();
        let cache_dir = self.cache_dir();
        generate_agent_summary(&GenerateOptions {
            bin_path: &self.bin_path,
            pane_id: self.pane_id,
            status: self.status,
            timeout: self.timeout,
            command: self.command.as_deref(),
            work_dir,
            cache_dir: &cache_dir,
            path_fallback: Some(&[]),
            env: &self.env,
            fetch: &self.fetch,
        })
    }
}

fn is_alive(pid: i32) -> bool {
    // SAFETY: signal 0 only probes for the process.
    unsafe { libc::kill(pid, 0) == 0 }
}

fn five_seconds() -> LinkedSignal {
    linked_signal(&[], Some(Duration::from_secs(5)))
}

// MARK: - harness environment

#[test]
fn a_launchd_minimal_path_still_reaches_homebrew_and_per_user_harnesses_after_the_existing_entries()
{
    let base = Env::from_pairs([("PATH", "/usr/bin:/bin"), ("HERDR_PLUGIN_CONFIG_DIR", "/x")]);
    let env = harness_env(&base, &default_harness_dirs("/Users/u"));
    let path = env.get("PATH").unwrap();
    let dirs: Vec<&str> = path.split(':').collect();
    assert_eq!(&dirs[..2], ["/usr/bin", "/bin"]);
    assert!(dirs.contains(&"/opt/homebrew/bin"));
    assert!(dirs.contains(&"/Users/u/.local/bin"));
    assert_eq!(env.get("HERDR_PLUGIN_CONFIG_DIR"), None);
}

#[test]
fn a_core_terminals_variables_do_not_reach_the_harness() {
    let base = Env::from_pairs([
        ("PATH", "/usr/bin"),
        ("HC_TERMINAL_ID", "t7"),
        ("HC_TERMINAL_SOCKET", "/run/hc.sock"),
        ("HC_SESSION", "default"),
        ("HC_SOCKET", "/run/hc.sock"),
        ("HC_SCOPE", "s"),
        ("HC_OTHER", "kept"),
    ]);
    let env = harness_env(&base, &[]);
    for name in [
        "HC_TERMINAL_ID",
        "HC_TERMINAL_SOCKET",
        "HC_SESSION",
        "HC_SOCKET",
        "HC_SCOPE",
    ] {
        assert_eq!(env.get(name), None, "{name}");
    }
    assert_eq!(env.get("HC_OTHER"), Some("kept"));
    assert_eq!(env.get("WAYCAR_SUMMARY"), Some("1"));
}

#[test]
fn directories_already_on_path_are_not_duplicated() {
    let base = Env::from_pairs([("PATH", "/opt/homebrew/bin:/usr/bin")]);
    let env = harness_env(&base, &default_harness_dirs("/Users/u"));
    assert_eq!(
        env.get("PATH")
            .unwrap()
            .split(':')
            .filter(|d| *d == "/opt/homebrew/bin")
            .count(),
        1
    );
}

// MARK: - sanitizeSummary

#[test]
fn sanitize_summary_reduces_each_answer() {
    let cases = [
        ("approve merge of PR #512\n", "approve merge of PR #512"),
        (
            "Working...\n\nApprove merge of PR #512.",
            "Approve merge of PR #512",
        ),
        ("Working…\rrun the migration?", "run the migration?"),
        ("\"Approve merge of PR #512\"", "Approve merge of PR #512"),
        (
            "**Blocked:** approve `rm -rf build`",
            "approve rm -rf build",
        ),
        (
            "- Done: added retries, tests pass.\n- second bullet",
            "added retries, tests pass",
        ),
        (
            "Working: adding backoff to webhook retries",
            "adding backoff to webhook retries",
        ),
        ("# Summary: “fixed login redirect”", "fixed login redirect"),
        (
            "\u{1b}[32mfixed   login\tredirect\u{1b}[0m",
            "fixed login redirect",
        ),
        ("keep snake_case_name intact", "keep snake_case_name intact"),
    ];
    for (raw, expected) in cases {
        assert_eq!(sanitize_summary(raw).as_deref(), Some(expected), "{raw:?}");
    }
}

#[test]
fn sanitize_summary_yields_null_when_nothing_usable_is_left() {
    for raw in ["", "\n\n", "Working...\n", "\"\"", "**"] {
        assert_eq!(sanitize_summary(raw), None, "{raw:?}");
    }
    // JS `sanitizeSummary(undefined)`: the Rust callers pass no answer as `None`.
    assert_eq!(None::<&str>.and_then(sanitize_summary), None);
}

/// The summary has its own 100 cap, longer than the 80 of the other display
/// fields: an 81-100 character sentence must survive whole.
#[test]
fn keeps_a_sentence_of_exactly_the_summary_cap_and_trims_a_longer_one_to_it() {
    let exact = format!("{}b", "a".repeat(SUMMARY_CHAR_MAX - 1));
    assert_eq!(SUMMARY_CHAR_MAX, 100);
    assert_eq!(sanitize_summary(&exact).as_deref(), Some(exact.as_str()));
    let summary = sanitize_summary(&"word ".repeat(100)).unwrap();
    assert_eq!(summary.chars().count(), SUMMARY_CHAR_MAX);
    assert!(summary.ends_with('…'));
}

#[test]
fn counts_graphemes_so_a_trimmed_summary_never_splits_an_emoji() {
    let family = "👨‍👩‍👧";
    let summary = sanitize_summary(&family.repeat(120)).unwrap();
    assert_eq!(graphemes(&summary).len(), SUMMARY_CHAR_MAX);
    assert_eq!(summary, format!("{}…", family.repeat(SUMMARY_CHAR_MAX - 1)));
}

// MARK: - parsePhase

#[test]
fn parse_phase_reads_each_answer() {
    let answer = |second: &str| format!("Adding backoff to webhook retries\n{second}\n");
    let cases = [
        (answer("Phase: exploring"), Some("exploring")),
        (answer("Phase: implementing"), Some("implementing")),
        (answer("phase - verifying."), Some("verifying")),
        (answer("**Phase:** wrapping_up"), Some("wrapping_up")),
        (answer("Phase: wrapping up"), Some("wrapping_up")),
        (answer("- `Phase: Verifying`"), Some("verifying")),
        (answer("Phase: deploying"), None),
        (answer("Stage: verifying"), None),
        ("Adding backoff to webhook retries".to_string(), None),
    ];
    for (raw, expected) in cases {
        assert_eq!(parse_phase(&raw), expected, "{raw:?}");
    }
    assert_eq!(None::<&str>.and_then(parse_phase), None);
}

#[test]
fn the_phase_line_never_becomes_or_changes_the_summary() {
    let answer = "Adding backoff to webhook retries\nPhase: verifying\n";
    assert_eq!(
        sanitize_summary(answer).as_deref(),
        Some("Adding backoff to webhook retries")
    );
    assert_eq!(
        sanitize_summary("Phase: verifying\nAdding backoff to webhook retries.").as_deref(),
        Some("Adding backoff to webhook retries")
    );
    assert_eq!(sanitize_summary("Phase: verifying"), None);
}

/// A `summary_command` sees the request in its last argument: only the
/// Working one asks for the phase line, naming every phase it may answer.
#[test]
fn only_the_working_instruction_asks_for_the_phase_line() {
    let working = summary_instruction("working").unwrap();
    for phase in ["exploring", "implementing", "verifying", "wrapping_up"] {
        assert!(working.contains(phase), "{phase}");
    }
    for status in ["idle", "done", "blocked"] {
        assert!(!summary_instruction(status).unwrap().contains("Phase"));
    }
}

// MARK: - screenHash

fn spinner_screen(spinner: &str, elapsed: u32, tokens: &str) -> String {
    format!(
        "Editing src/webhook.ts\n{spinner} Thinking… ({elapsed}s · ↓ {tokens} tokens · $0.{elapsed}4)"
    )
}

#[test]
fn a_still_agent_keeps_its_hash_while_its_spinner_timer_and_counters_tick() {
    assert_eq!(
        screen_hash(&spinner_screen("⠋", 12, "1.2k")),
        screen_hash(&spinner_screen("⠙", 73, "14.9k"))
    );
    assert_eq!(
        screen_hash(&spinner_screen("✻", 5, "300")),
        screen_hash(&spinner_screen("✳", 6, "301"))
    );
}

#[test]
fn a_real_content_change_hashes_differently() {
    let screen = spinner_screen("⠋", 12, "1.2k");
    assert_ne!(
        screen_hash(&screen),
        screen_hash(&screen.replace("webhook.ts", "router.ts"))
    );
}

// MARK: - generateAgentSummary

#[test]
fn pipes_the_screen_to_the_command_and_returns_its_sanitized_answer_and_the_screen_hash() {
    let lab = Lab::new();
    let harness = lab.plain("summarize", "Working...\nApprove merge of PR #512.\n");
    let mut auto = Auto::new(&lab);
    auto.command = Some(vec![harness, "--fast".into()]);

    let result = auto.run();

    assert_eq!(
        result,
        Generated {
            summary: Some("Approve merge of PR #512".into()),
            hash: Some(screen_hash(FLAT_SCREEN)),
        }
    );
    let herdr = lab.lines("herdr.log");
    assert!(
        herdr[0].starts_with(&format!("pane read {PANE_ID} --source recent")),
        "{herdr:?}"
    );
    let calls = lab.calls();
    // The override's own argv comes first; the instruction is the one extra
    // trailing argument. The screen arrives on stdin, flattened.
    assert_eq!(calls[0].argv.len(), 2);
    assert_eq!(calls[0].argv[0], "--fast");
    assert_eq!(calls[0].stdin, FLAT_SCREEN);
    // The override wins outright: no provider was probed.
    assert!(lab.probes().is_empty());
}

#[test]
fn a_working_answers_phase_line_comes_back_beside_the_unchanged_summary_other_statuses_get_none() {
    let lab = Lab::new();
    let harness = lab.plain(
        "summarize",
        "Adding backoff to webhook retries.\nPhase: verifying\n",
    );
    let signal = five_seconds();
    let command = [harness];
    let run = |status: &str| {
        summarize_screen(&SummarizeOptions {
            screen: Some(FLAT_SCREEN),
            status,
            command: Some(&command),
            signal: &signal.signal,
            work_dir: lab.dir.str(),
            cache_dir: lab.dir.str(),
            path_fallback: None,
            env: &Env::from_process(),
            fetch: &FakeFetch::unexpected(),
        })
    };

    assert_eq!(
        run("working"),
        Summarized {
            summary: Some("Adding backoff to webhook retries".into()),
            phase: Some("verifying"),
        }
    );
    assert_eq!(
        run("blocked"),
        Summarized {
            summary: Some("Adding backoff to webhook retries".into()),
            phase: None,
        }
    );
}

#[test]
fn every_agent_status_gets_its_own_instruction_other_statuses_are_not_summarized() {
    let lab = Lab::new();
    let harness = lab.plain("summarize", "a sentence");
    let mut auto = Auto::new(&lab);
    auto.command = Some(vec![harness]);
    for status in ["working", "idle", "done", "blocked"] {
        auto.status = status;
        assert_eq!(auto.run().summary.as_deref(), Some("a sentence"));
    }
    let instructions: Vec<String> = lab.calls().iter().map(|c| c.last().to_string()).collect();
    let mut unique = instructions.clone();
    unique.sort();
    unique.dedup();
    assert_eq!(unique.len(), 4);
    for instruction in &instructions {
        assert!(instruction.contains("100 characters"));
    }

    for status in ["unknown", "exited", ""] {
        auto.status = status;
        assert_eq!(
            auto.run(),
            Generated {
                summary: None,
                hash: None
            }
        );
    }
    assert_eq!(lab.calls().len(), 4);
}

#[test]
fn a_harness_that_outlives_the_timeout_is_killed_and_yields_null() {
    let lab = Lab::new();
    let harness = lab.harness(
        "summarize",
        Behavior {
            hang: true,
            ..Behavior::default()
        },
    );
    let mut auto = Auto::new(&lab);
    auto.command = Some(vec![harness]);
    auto.status = "done";
    auto.timeout = Duration::from_millis(3000);
    let started = Instant::now();

    let result = auto.run();

    assert_eq!(result.summary, None);
    assert!(
        started.elapsed() < Duration::from_secs(5),
        "took {:?}",
        started.elapsed()
    );
    let pid: i32 = fs::read_to_string(lab.path("summarize.pid"))
        .unwrap()
        .trim()
        .parse()
        .unwrap();
    assert!(!is_alive(pid));
}

#[test]
fn a_failing_or_silent_command_yields_null() {
    let lab = Lab::new();
    let mut auto = Auto::new(&lab);
    auto.status = "done";
    for (stdout, code) in [("Approve merge", 1), ("Working...\n", 0)] {
        let harness = lab.harness(
            "summarize",
            Behavior {
                stdout,
                code,
                ..Behavior::default()
            },
        );
        auto.command = Some(vec![harness]);
        assert_eq!(auto.run().summary, None);
    }
    auto.command = Some(vec![lab.path("no-such-harness")]);
    assert_eq!(auto.run().summary, None);
}

#[test]
fn an_unreadable_or_blank_screen_never_reaches_a_harness_and_has_no_hash() {
    let lab = Lab::new();
    let harness = lab.plain("summarize", "made up");
    for screen in [None, Some("\n  \n")] {
        let mut auto = Auto::new(&lab);
        auto.bin_path = lab.herdr(screen);
        auto.status = "done";
        auto.command = Some(vec![harness.clone()]);
        assert_eq!(
            auto.run(),
            Generated {
                summary: None,
                hash: None
            }
        );
    }
    assert!(lab.calls().is_empty());
}

// MARK: - tmux pane screens

#[test]
fn a_tmux_pane_is_captured_from_the_raw_pane_through_tmux_never_through_herdr() {
    let lab = Lab::new();
    let bin_path = lab.herdr(Some("herdr must not be asked"));
    lab.tmux(Some(SCREEN));
    let signal = five_seconds();

    let screen = read_screen(&bin_path, "tmux:%3", &signal.signal, &lab.env(&[]));

    assert_eq!(screen.as_deref(), Some(FLAT_SCREEN));
    let calls = lab.lines("tmux.log");
    assert_eq!(calls.len(), 1);
    let args: Vec<&str> = calls[0].split(' ').collect();
    assert_eq!(args[0], "capture-pane");
    assert_eq!(
        args[args.iter().position(|a| *a == "-t").unwrap() + 1],
        "%3"
    );
    assert!(
        args.contains(&"-60"),
        "reads SCREEN_LINES of history: {args:?}"
    );
    assert!(!Path::new(&lab.path("herdr.log")).exists());
}

#[test]
fn an_uncapturable_or_blank_tmux_pane_reads_as_null() {
    for raw in [None, Some("\n  \n")] {
        let lab = Lab::new();
        lab.tmux(raw);
        let signal = five_seconds();
        assert_eq!(
            read_screen("herdr", "tmux:%3", &signal.signal, &lab.env(&[])),
            None
        );
    }
}

// MARK: - herdr-core terminal screens

#[test]
fn a_core_terminal_is_read_through_herdr_core_never_through_herdr_or_tmux() {
    let lab = Lab::new();
    let bin_path = lab.herdr(Some("herdr must not be asked"));
    lab.core(Some(SCREEN));
    let signal = five_seconds();

    let screen = read_screen(&bin_path, "hc:t3", &signal.signal, &lab.env(&[]));

    assert_eq!(screen.as_deref(), Some(FLAT_SCREEN));
    // Only the version probe and the read: asking anything else would start a core.
    assert_eq!(lab.lines("core.log"), ["--version", "read t3 --lines 60"]);
    assert!(!Path::new(&lab.path("herdr.log")).exists());
}

#[test]
fn a_core_terminals_own_socket_picks_the_core_that_is_read() {
    let lab = Lab::new();
    lab.core(Some(SCREEN));
    let own = lab.run.join("own/herdr-core/default.sock");
    lab.listen(&own);
    let signal = five_seconds();
    let own = own.to_string_lossy().into_owned();
    let env = lab.env(&[("HC_TERMINAL_SOCKET", own.as_str())]);

    let screen = read_screen("herdr", "hc:box/t3", &signal.signal, &env);

    assert_eq!(screen.as_deref(), Some(FLAT_SCREEN));
    assert_eq!(lab.lines("core.sockets"), [own.as_str(); 2]);
    assert_eq!(
        lab.lines("core.log"),
        ["--version", "read box/t3 --lines 60"]
    );
}

#[test]
fn an_unreadable_or_blank_core_terminal_reads_as_null() {
    for raw in [None, Some("\n  \n")] {
        let lab = Lab::new();
        lab.core(raw);
        let signal = five_seconds();
        assert_eq!(
            read_screen("herdr", "hc:t3", &signal.signal, &lab.env(&[])),
            None
        );
    }
}

#[test]
fn a_host_without_herdr_core_reads_a_core_terminal_as_null() {
    let lab = Lab::new();
    let signal = five_seconds();
    assert_eq!(
        read_screen("herdr", "hc:t3", &signal.signal, &lab.env(&[])),
        None
    );
}

#[test]
fn an_aborted_signal_reads_a_core_terminal_as_null_without_asking_core() {
    let lab = Lab::new();
    lab.core(Some(SCREEN));
    let signal = linked_signal(&[], Some(Duration::from_millis(0)));
    // The abort lands from a watcher thread: wait for it, not for a fixed time.
    let deadline = Instant::now() + Duration::from_secs(10);
    while !signal.signal.is_aborted() {
        assert!(Instant::now() < deadline, "the signal never aborted");
        std::thread::sleep(Duration::from_millis(2));
    }

    assert_eq!(
        read_screen("herdr", "hc:t3", &signal.signal, &lab.env(&[])),
        None
    );
    assert!(lab.lines("core.log").is_empty());
}

#[test]
fn generate_agent_summary_summarizes_a_core_terminals_screen() {
    let lab = Lab::new();
    let harness = lab.plain("summarize", "Approve merge of PR #512.\n");
    lab.core(Some(SCREEN));
    let mut auto = Auto::new(&lab);
    auto.bin_path = lab.path("no-herdr");
    auto.pane_id = "hc:t3";
    auto.command = Some(vec![harness]);

    let result = auto.run();

    assert_eq!(
        result,
        Generated {
            summary: Some("Approve merge of PR #512".into()),
            hash: Some(screen_hash(FLAT_SCREEN)),
        }
    );
    assert_eq!(lab.calls()[0].stdin, FLAT_SCREEN);
}

#[test]
fn generate_agent_summary_summarizes_a_tmux_panes_screen() {
    let lab = Lab::new();
    let harness = lab.plain("summarize", "Approve merge of PR #512.\n");
    lab.tmux(Some(SCREEN));
    let mut auto = Auto::new(&lab);
    auto.bin_path = lab.path("no-herdr");
    auto.pane_id = "tmux:%3";
    auto.command = Some(vec![harness]);

    let result = auto.run();

    assert_eq!(
        result,
        Generated {
            summary: Some("Approve merge of PR #512".into()),
            hash: Some(screen_hash(FLAT_SCREEN)),
        }
    );
    assert_eq!(lab.calls()[0].stdin, FLAT_SCREEN);
}

/// A summary run's harness must not see the Agent's pane or session. (The JS
/// test also fires Waycar's own hooks from the harness; the Rust hooks are
/// not part of this slice, so this one checks the environment the harness
/// gets and that nothing writes a tmux option.)
#[test]
fn a_summary_runs_harness_cannot_touch_the_agents_tmux_pane() {
    let lab = Lab::new();
    lab.tmux(Some(SCREEN));
    let harness = lab.path("harness-with-env");
    write_executable(
        &harness,
        &format!(
            "#!/bin/sh\n/bin/cat >/dev/null\n/usr/bin/env > '{}'\necho 'Approve merge of PR #512'\n",
            lab.path("harness.env")
        ),
    );
    let mut auto = Auto::new(&lab);
    auto.bin_path = lab.path("no-herdr");
    auto.pane_id = "tmux:%3";
    auto.command = Some(vec![harness]);
    auto.env = lab.env(&[
        ("TMUX", "/tmp/fake-tmux-socket,1,0"),
        ("TMUX_PANE", "%3"),
        ("CLAUDECODE", "1"),
        ("CLAUDE_PID", "4242"),
        ("GEMINI_CLI_NO_RELAUNCH", "true"),
        ("GEMINI_SESSION_ID", "users-session"),
        ("HERMES_EPHEMERAL_SYSTEM_PROMPT", "the user's Chat Prompt"),
        ("HERMES_SESSION_ID", "users-session"),
        ("MUSE_SESSION_ID", "users-session"),
        ("MUSE_THREAD_ID", "users-thread"),
    ]);

    let result = auto.run();

    assert_eq!(
        result.summary.as_deref(),
        Some("Approve merge of PR #512"),
        "the harness ran"
    );
    let tmux_calls = lab.lines("tmux.log");
    assert!(
        tmux_calls.iter().all(|line| !line.contains("set-option")),
        "no @waycar_* write or release"
    );
    let seen = lab.lines("harness.env");
    assert!(
        seen.contains(&"WAYCAR_SUMMARY=1".to_string()),
        "the harness runs marked as a summary"
    );
    for name in [
        "TMUX",
        "TMUX_PANE",
        "CLAUDECODE",
        "CLAUDE_PID",
        "GEMINI_CLI_NO_RELAUNCH",
        "GEMINI_SESSION_ID",
        "HERMES_EPHEMERAL_SYSTEM_PROMPT",
        "HERMES_SESSION_ID",
        "MUSE_SESSION_ID",
        "MUSE_THREAD_ID",
    ] {
        assert!(
            !seen
                .iter()
                .any(|line| line.starts_with(&format!("{name}="))),
            "{name} reaches the harness"
        );
    }
}

// MARK: - provider chain

#[test]
fn claude_answers_first_locked_down_from_the_private_empty_cwd() {
    let lab = Lab::new();
    lab.plain("claude", "Approve merge of PR #512\n");
    lab.plain("omp", "never asked");

    let result = Auto::new(&lab).run();

    assert_eq!(result.summary.as_deref(), Some("Approve merge of PR #512"));
    let calls = lab.calls();
    assert_eq!(lab.call_names(), ["claude"]);
    let call = &calls[0];
    for flag in [
        "--strict-mcp-config",
        "--no-session-persistence",
        "--disallowedTools",
    ] {
        assert!(call.has(flag), "{flag}");
    }
    assert_eq!(call.value_after("--tools"), "");
    assert_eq!(call.value_after("--model"), "haiku");
    assert_eq!(
        call.env.lines().filter(|l| l.starts_with("HERDR_")).count(),
        0
    );
    assert_eq!(call.stdin, FLAT_SCREEN);
    // Both CLIs load project config from their cwd: never a shared one.
    let cwd = lab.path("summary-cwd");
    assert_eq!(call.cwd, fs::canonicalize(&cwd).unwrap().to_string_lossy());
    assert_eq!(fs::read_dir(&cwd).unwrap().count(), 0);
    assert_eq!(
        fs::metadata(&cwd).unwrap().permissions().mode() & 0o777,
        0o700
    );
}

#[test]
fn a_claude_that_fails_falls_through_to_omps_anthropic_login_with_its_overlay() {
    let lab = Lab::new();
    lab.harness(
        "claude",
        Behavior {
            code: 1,
            ..Behavior::default()
        },
    );
    lab.plain("omp", "merged PR #512\n");
    let mut auto = Auto::new(&lab);
    auto.status = "done";

    let result = auto.run();

    assert_eq!(result.summary.as_deref(), Some("merged PR #512"));
    let calls = lab.calls();
    assert_eq!(lab.call_names(), ["claude", "omp"]);
    let omp = &calls[1];
    assert_eq!(omp.value_after("--model"), "anthropic/claude-haiku-4-5");
    for flag in [
        "--no-tools",
        "--approval-mode=always-ask",
        "--no-session",
        "--no-extensions",
    ] {
        assert!(omp.has(flag), "{flag}");
    }
    // omp runs with memory recall and advisors switched off through a config
    // overlay; either one turns a ~1.5 s call into 12-30 s.
    let overlay = fs::read_to_string(omp.value_after("--config")).unwrap();
    assert!(overlay.contains("memory:\n  backend: off"));
    assert!(overlay.contains("advisor:\n  enabled: false"));
    // omp hangs on an inherited open stdin: it is fed the screen and closed.
    assert_eq!(omp.stdin, FLAT_SCREEN);
}

#[test]
fn without_an_anthropic_login_the_chain_moves_to_omps_codex_login() {
    let lab = Lab::new();
    lab.harness(
        "claude",
        Behavior {
            stdout: "never asked",
            probes: vec![(
                "auth status",
                Probe {
                    stdout: "{\"loggedIn\":false}",
                    code: 1,
                    ..Probe::default()
                },
            )],
            ..Behavior::default()
        },
    );
    lab.harness(
        "omp",
        Behavior {
            stdout: "Adding backoff to webhook retries\n",
            probes: vec![
                (
                    "token anthropic --list",
                    Probe {
                        code: 1,
                        ..Probe::default()
                    },
                ),
                ("token openai-codex --list", Probe::default()),
            ],
            ..Behavior::default()
        },
    );
    let mut auto = Auto::new(&lab);
    auto.status = "working";

    let result = auto.run();

    assert_eq!(
        result.summary.as_deref(),
        Some("Adding backoff to webhook retries")
    );
    let calls = lab.calls();
    assert_eq!(calls[0].name, "omp");
    assert_eq!(calls[0].value_after("--model"), "openai-codex/gpt-6-luna");
    assert!(calls[0].has("--thinking=low"));
}

#[test]
fn an_anthropic_api_key_counts_as_an_anthropic_login_without_a_probe() {
    let lab = Lab::new();
    lab.harness(
        "claude",
        Behavior {
            stdout: "done deal\n",
            probes: vec![(
                "auth status",
                Probe {
                    stdout: "{\"loggedIn\":false}",
                    code: 1,
                    ..Probe::default()
                },
            )],
            ..Behavior::default()
        },
    );
    let mut auto = Auto::new(&lab);
    auto.env = lab.env(&[("ANTHROPIC_API_KEY", "k")]);

    assert_eq!(auto.run().summary.as_deref(), Some("done deal"));
    assert!(lab.probed("claude").is_empty());
}

#[test]
fn codex_runs_ephemeral_and_read_only_prompt_on_stdin_answer_from_its_o_file() {
    let lab = Lab::new();
    lab.harness(
        "codex",
        Behavior {
            stdout: "Merged PR #512; CI green\n",
            out_flag: Some("-o"),
            probes: vec![(
                "login status",
                Probe {
                    stderr: "Logged in using ChatGPT\n",
                    ..Probe::default()
                },
            )],
            ..Behavior::default()
        },
    );
    let mut auto = Auto::new(&lab);
    auto.status = "done";

    let result = auto.run();

    assert_eq!(result.summary.as_deref(), Some("Merged PR #512; CI green"));
    let calls = lab.calls();
    let call = &calls[0];
    for flag in [
        "--ephemeral",
        "--ignore-user-config",
        "--ignore-rules",
        "--skip-git-repo-check",
    ] {
        assert!(call.has(flag), "{flag}");
    }
    assert_eq!(call.value_after("-s"), "read-only");
    assert_eq!(call.value_after("-m"), "gpt-6-luna");
    assert_eq!(call.last(), "-");
    assert!(call.stdin.ends_with(FLAT_SCREEN));
    // The answer file is gone and the cwd stayed empty.
    let leftovers = fs::read_dir(lab.dir.path())
        .unwrap()
        .flatten()
        .filter(|e| {
            e.file_name()
                .to_string_lossy()
                .starts_with("codex-summary-")
        })
        .count();
    assert_eq!(leftovers, 0);
    assert_eq!(fs::read_dir(lab.path("summary-cwd")).unwrap().count(), 0);
}

#[test]
fn codex_on_an_api_key_login_uses_the_cheapest_api_model() {
    let lab = Lab::new();
    // Like the real CLI, `codex login status` reports on stderr only.
    lab.harness(
        "codex",
        Behavior {
            stdout: "ok\n",
            out_flag: Some("-o"),
            probes: vec![(
                "login status",
                Probe {
                    stderr: "Logged in using an API key - sk-***\n",
                    ..Probe::default()
                },
            )],
            ..Behavior::default()
        },
    );

    Auto::new(&lab).run();

    assert_eq!(lab.calls()[0].value_after("-m"), "gpt-5-nano");
}

#[test]
fn with_only_openai_api_key_the_openai_responses_api_is_called_over_https() {
    let lab = Lab::new();
    let mut auto = Auto::new(&lab);
    auto.env = lab.env(&[("OPENAI_API_KEY", "sk-test")]);
    auto.fetch = FakeFetch::new(|_| {
        (
            200,
            json!({"output": [{"type": "message", "content": [{"type": "output_text", "text": "Needs approval to merge PR #512"}]}]}),
        )
    });

    let result = auto.run();

    assert_eq!(
        result.summary.as_deref(),
        Some("Needs approval to merge PR #512")
    );
    let requests = auto.fetch.requests.lock().unwrap();
    let (url, authorization, body) = &requests[0];
    assert_eq!(url, "https://api.openai.com/v1/responses");
    assert_eq!(authorization, "Bearer sk-test");
    assert_eq!(body["model"], "gpt-5-nano");
    assert_eq!(body["reasoning"], json!({"effort": "minimal"}));
    assert!(body["input"].as_str().unwrap().ends_with(FLAT_SCREEN));
}

#[test]
fn a_failing_openai_api_falls_through_to_openrouters_cheap_models() {
    let lab = Lab::new();
    let mut auto = Auto::new(&lab);
    auto.status = "idle";
    auto.env = lab.env(&[
        ("OPENAI_API_KEY", "sk-test"),
        ("OPENROUTER_API_KEY", "or-test"),
    ]);
    auto.fetch = FakeFetch::new(|url| {
        if url.contains("openrouter") {
            (
                200,
                json!({"choices": [{"message": {"content": "Fixed the flaky login test; waiting"}}]}),
            )
        } else {
            (500, Value::Null)
        }
    });

    let result = auto.run();

    assert_eq!(
        result.summary.as_deref(),
        Some("Fixed the flaky login test; waiting")
    );
    assert_eq!(
        auto.fetch.urls(),
        [
            "https://api.openai.com/v1/responses",
            "https://openrouter.ai/api/v1/chat/completions"
        ]
    );
    let requests = auto.fetch.requests.lock().unwrap();
    let openrouter = &requests[1].2;
    assert_eq!(
        openrouter["models"],
        json!(["google/gemini-2.5-flash-lite", "openai/gpt-6-luna"])
    );
    assert_eq!(openrouter["max_tokens"], 60);
    assert_eq!(requests[1].1, "Bearer or-test");
}

#[test]
fn detection_is_cached_for_an_hour_a_second_summary_probes_nothing() {
    let lab = Lab::new();
    lab.plain("claude", "one\n");
    let auto = Auto::new(&lab);

    auto.run();
    let probed = lab.probes().len();
    auto.run();

    assert!(probed > 0);
    assert_eq!(lab.probes().len(), probed);
    let cache: Value = serde_json::from_str(
        &fs::read_to_string(format!("{}/{PROVIDER_CACHE_NAME}", auto.cache_dir())).unwrap(),
    )
    .unwrap();
    assert_eq!(cache["provider"], "claude");
    assert_eq!(lab.call_names(), ["claude", "claude"]);
}

#[test]
fn an_expired_cache_is_probed_again_and_picks_up_a_newly_installed_provider() {
    let lab = Lab::new();
    let auto = Auto::new(&lab);
    fs::create_dir_all(auto.cache_dir()).unwrap();
    let now = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64;
    fs::write(
        format!("{}/{PROVIDER_CACHE_NAME}", auto.cache_dir()),
        json!({"v": 1, "ts": now - PROVIDER_CACHE_TTL_MS - 1000, "provider": "none", "providers": []}).to_string(),
    )
    .unwrap();
    lab.plain("claude", "fresh\n");

    assert_eq!(auto.run().summary.as_deref(), Some("fresh"));
}

#[test]
fn no_provider_at_all_yields_null_and_records_provider_none() {
    let lab = Lab::new();
    let auto = Auto::new(&lab);

    let result = auto.run();

    assert_eq!(result.summary, None);
    let hash = result.hash.unwrap();
    assert_eq!(hash.len(), 64);
    assert!(
        hash.bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
    );
    let cache: Value = serde_json::from_str(
        &fs::read_to_string(format!("{}/{PROVIDER_CACHE_NAME}", auto.cache_dir())).unwrap(),
    )
    .unwrap();
    assert_eq!(cache["provider"], "none");
    assert_eq!(cache["providers"], json!([]));
}

// MARK: - installed harness providers

fn pi_ready() -> Vec<(&'static str, Probe)> {
    vec![(
        "auth check --provider mock --no-refresh --json",
        Probe {
            stdout: "{\"status\":\"ready\",\"provider\":\"mock\"}",
            ..Probe::default()
        },
    )]
}

#[test]
fn an_installed_harness_answers_only_after_every_api_provider_claude_still_goes_first() {
    let lab = Lab::new();
    lab.plain("claude", "claude answered\n");
    lab.harness(
        "pi",
        Behavior {
            stdout: "pi answered\n",
            probes: pi_ready(),
            ..Behavior::default()
        },
    );
    lab.write_home_file(".pi/agent/settings.json", "{\"defaultProvider\":\"mock\"}");

    let result = Auto::new(&lab).run();

    assert_eq!(result.summary.as_deref(), Some("claude answered"));
    assert_eq!(lab.call_names(), ["claude"]);
}

#[test]
fn pi_runs_with_no_tools_session_extensions_or_context_its_own_login_checked_without_a_refresh() {
    let lab = Lab::new();
    lab.harness(
        "pi",
        Behavior {
            stdout: "Fixing the flaky test\n",
            probes: pi_ready(),
            ..Behavior::default()
        },
    );
    lab.write_home_file(".pi/agent/settings.json", "{\"defaultProvider\":\"mock\"}");
    let mut auto = Auto::new(&lab);
    auto.status = "working";

    let result = auto.run();

    assert_eq!(result.summary.as_deref(), Some("Fixing the flaky test"));
    let calls = lab.calls();
    for flag in [
        "-p",
        "--no-tools",
        "--no-session",
        "--no-extensions",
        "--no-mcp",
        "--no-context-files",
        "--no-approve",
        "--offline",
    ] {
        assert!(calls[0].has(flag), "{flag}");
    }
    // pi appends the message to stdin as is: the screen ends in a blank line.
    assert_eq!(
        calls[0].stdin,
        format!("Terminal screen:\n{FLAT_SCREEN}\n\n")
    );
}

#[test]
fn pi_without_a_ready_default_provider_is_not_a_provider() {
    let lab = Lab::new();
    lab.harness(
        "pi",
        Behavior {
            stdout: "never asked",
            probes: vec![(
                "auth check --provider mock --no-refresh --json",
                Probe {
                    stdout: "{\"status\":\"missing\"}",
                    code: 1,
                    ..Probe::default()
                },
            )],
            ..Behavior::default()
        },
    );
    lab.write_home_file(".pi/agent/settings.json", "{\"defaultProvider\":\"mock\"}");

    assert_eq!(Auto::new(&lab).run().summary, None);
    assert!(lab.calls().is_empty());
}

#[test]
fn qwen_counts_only_with_its_own_provider_configured_never_the_ended_qwen_oauth_tier_and_aborts_on_any_tool_call()
 {
    let lab = Lab::new();
    lab.plain("qwen", "Waiting for approval to run npm test\n");
    lab.write_home_file(
        ".qwen/settings.json",
        "{\"security\":{\"auth\":{\"selectedType\":\"qwen-oauth\"}}}",
    );
    assert_eq!(Auto::new(&lab).run().summary, None);

    fs::remove_dir_all(lab.path("config")).unwrap();
    lab.write_home_file(
        ".qwen/settings.json",
        "{\"security\":{\"auth\":{\"selectedType\":\"openai\"}}}",
    );
    let result = Auto::new(&lab).run();

    assert_eq!(
        result.summary.as_deref(),
        Some("Waiting for approval to run npm test")
    );
    let calls = lab.calls();
    assert_eq!(calls[0].value_after("--max-tool-calls"), "0");
    for flag in ["--safe-mode", "--chat-recording=false"] {
        assert!(calls[0].has(flag), "{flag}");
    }
    assert_eq!(calls[0].stdin, FLAT_SCREEN);
}

#[test]
fn gemini_runs_under_a_policy_that_denies_every_tool_written_outside_its_cwd() {
    let lab = Lab::new();
    lab.plain("gemini", "Needs approval to run rm\n");
    let mut auto = Auto::new(&lab);
    auto.env = lab.env(&[("GEMINI_API_KEY", "k")]);

    let result = auto.run();

    assert_eq!(result.summary.as_deref(), Some("Needs approval to run rm"));
    let calls = lab.calls();
    let policy = fs::read_to_string(calls[0].value_after("--policy")).unwrap();
    assert!(policy.contains("toolName = \"*\"\ndecision = \"deny\""));
    assert_eq!(calls[0].value_after("-e"), "none");
    assert_eq!(fs::read_dir(lab.path("summary-cwd")).unwrap().count(), 0);
}

#[test]
fn copilot_gets_the_whole_prompt_on_stdin_and_no_tools_and_the_session_it_records_is_removed() {
    let lab = Lab::new();
    // A copilot that records its session under the id it was given.
    lab.harness(
        "copilot",
        Behavior {
            stdout: "Merged PR #512\n",
            session: true,
            ..Behavior::default()
        },
    );
    let mut auto = Auto::new(&lab);
    auto.status = "done";
    auto.env = lab.env(&[("COPILOT_PROVIDER_BASE_URL", "http://mock/v1")]);

    let result = auto.run();

    assert_eq!(result.summary.as_deref(), Some("Merged PR #512"));
    let calls = lab.calls();
    assert!(calls[0].has("--available-tools=none"));
    assert!(!calls[0].has("-p"), "the screen never rides argv");
    assert!(calls[0].stdin.ends_with(FLAT_SCREEN));
    assert_eq!(
        fs::read_dir(lab.path(".copilot/session-state"))
            .unwrap()
            .count(),
        0
    );
}

#[test]
fn opencode_and_kilo_run_their_default_agent_with_every_tool_off_but_only_with_the_users_own_provider()
 {
    let lab = Lab::new();
    lab.plain("kilo", "never asked");
    lab.plain("opencode", "Running the test suite\n");
    // kilo with nothing configured would answer through its anonymous gateway.
    lab.write_home_file(
        ".config/opencode/opencode.json",
        "{\"model\":\"mock/mock-model\"}",
    );
    let mut auto = Auto::new(&lab);
    auto.status = "working";

    let result = auto.run();

    assert_eq!(result.summary.as_deref(), Some("Running the test suite"));
    let calls = lab.calls();
    assert_eq!(calls[0].name, "opencode");
    assert_eq!(calls[0].value_after("--agent"), "build");
    assert!(calls[0].has("--pure"));
    assert_eq!(calls[0].stdin, FLAT_SCREEN);
    let line = calls[0]
        .env
        .lines()
        .find_map(|l| l.strip_prefix("OPENCODE_CONFIG_CONTENT="))
        .unwrap();
    let config: Value = serde_json::from_str(line).unwrap();
    assert_eq!(config["agent"]["build"]["tools"]["*"], false);
    assert_eq!(config["agent"]["build"]["tools"]["bash"], false);
    assert_eq!(config["share"], "disabled");
}

#[test]
fn hermes_gets_the_prompt_on_stdin_with_only_the_clarify_toolset_once_a_provider_is_configured() {
    let lab = Lab::new();
    lab.plain("hermes", "Fixed the login test; waiting\n");
    lab.write_home_file(
        ".hermes/config.yaml",
        "# Hermes\nmodel:\n  # the default\n  default: \"m\"\n\n  provider: \"custom\"\nother: 1\n",
    );
    let mut auto = Auto::new(&lab);
    auto.status = "idle";

    let result = auto.run();

    assert_eq!(
        result.summary.as_deref(),
        Some("Fixed the login test; waiting")
    );
    let calls = lab.calls();
    assert_eq!(calls[0].value_after("-t"), "clarify");
    assert_eq!(calls[0].value_after("--query-file"), "-");
    assert!(calls[0].stdin.ends_with(FLAT_SCREEN));
}

// MARK: - Rust-only: the pure helpers the parity cases pin against Node

#[test]
fn the_instructions_and_system_prompt_are_the_js_strings() {
    assert_eq!(
        SYSTEM_PROMPT,
        "You write the status line on a coding agent's card in a phone app, from the agent's terminal screen. Reply with exactly one plain sentence of at most 100 characters, and nothing else unless the instruction asks for a second line. The sentence has no preamble, label, quotes, markdown, or emoji."
    );
    assert_eq!(
        summary_instruction("done").unwrap(),
        "The coding agent whose terminal screen is on stdin just finished. In past tense, say what it finished or its result (e.g. \"Added retry to the upload client; all tests pass\"). Reply with that sentence only, at most 100 characters."
    );
    assert!(summary_instruction("unknown").is_none());
}

#[test]
fn a_screen_cut_inside_a_surrogate_pair_keeps_the_replacement_character() {
    let screen = format!("{}x", "😀".repeat(4000));
    let normalized = normalize_screen(&screen).unwrap();
    assert!(normalized.starts_with('\u{FFFD}'));
    assert_eq!(jsx::utf16_len(&normalized), 8000);
}

#[test]
fn random_ids_are_version_4_uuids() {
    let id = random_uuid().unwrap();
    let parts: Vec<&str> = id.split('-').collect();
    assert_eq!(
        parts.iter().map(|p| p.len()).collect::<Vec<_>>(),
        [8, 4, 4, 4, 12]
    );
    assert!(parts[2].starts_with('4'));
    assert!(matches!(parts[3].as_bytes()[0], b'8' | b'9' | b'a' | b'b'));
}
