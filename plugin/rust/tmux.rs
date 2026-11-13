//! The tmux command runner (the top of tmux-adapter.js).
//!
//! The host tools talk to the user's default tmux server: a process running
//! inside tmux inherits `TMUX`, which names that server's socket, so `tmux`
//! with the caller's environment lands on the right server; without it plain
//! `tmux` uses the default socket. Nothing here passes `-L`/`-S`.
//!
//! Ids exchanged with the app carry the `tmux:` prefix (`tmux:%3`); tmux
//! commands take the raw id (`%3`). Every invocation passes `-u`: without a
//! UTF-8 locale and outside tmux, tmux prints the separators in `-F` output
//! as `_`.
//!
//! Agent Status lives in pane user options the agent hooks write from inside
//! the pane (`@waycar_status`, `@waycar_agent`, `@waycar_session`,
//! `@waycar_transcript`, `@waycar_seq`). A listing is `␞<field>␟<field>...`
//! per pane (U+241E, U+241F): tmux passes raw tabs and newlines in titles,
//! paths and options through unescaped, so records are split on the sentinel,
//! never on lines. The separators are printable on purpose: tmux 3.4 and 3.5
//! escape control bytes in printed output, while valid UTF-8 arrives as is on
//! every version. Every field strips both from its value
//! (`#{s/␞|␟//:field}`); should a free-text value still carry one, it would
//! shift the fields after it or forge a record, so such records are dropped
//! whole (see [`records`]).

use std::collections::HashMap;

use crate::env::Env;
use crate::error::{CliError, Result};
use crate::exec::{RunResult, run_program};

/// Runs a program: `run(cmd, args, env)`. Production is [`run_program`]; a
/// test passes a fake tmux.
pub type Runner<'a> = &'a dyn Fn(&str, &[&str], &Env) -> RunResult;

const PREFIX: &str = "tmux:";
const RECORD_SEPARATOR: char = '\u{241e}';
const FIELD_SEPARATOR: char = '\u{241f}';
/// Waycar's own grouped attach sessions share the desk session's panes.
const ATTACH_SESSION_PREFIX: &str = "waycar-";
const STATUSES: [&str; 4] = ["working", "blocked", "done", "idle"];
/// A pane whose foreground command is one of these runs no agent: an agent
/// killed without SessionEnd leaves stale options behind, which never count.
const SHELLS: [&str; 12] = [
    "sh", "bash", "zsh", "fish", "dash", "ksh", "mksh", "tcsh", "csh", "nu", "elvish", "xonsh",
];
const PANE_FIELDS: [&str; 16] = [
    "pane_id",
    "session_id",
    "window_id",
    "session_grouped",
    "session_group",
    "pane_dead",
    "@waycar_status",
    "@waycar_agent",
    "@waycar_seq",
    "pane_current_command",
    // Free text from here on.
    "session_name",
    "window_name",
    "pane_current_path",
    "@waycar_session",
    "@waycar_transcript",
    "pane_title",
];

/// Whether `id` is an app-side tmux pane id (`tmux:%3`).
pub fn is_tmux_pane_id(id: &str) -> bool {
    id.strip_prefix(PREFIX)
        .and_then(|rest| rest.strip_prefix('%'))
        .is_some_and(|digits| !digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit()))
}

/// The raw tmux id for a `tmux:`-prefixed one; raw ids pass through.
pub fn to_tmux_target(id: &str) -> &str {
    id.strip_prefix(PREFIX).unwrap_or(id)
}

/// The app-side id for a raw tmux pane id (`%3` becomes `tmux:%3`);
/// prefixed ids pass through.
pub fn to_waycar_pane_id(raw: &str) -> String {
    if raw.starts_with(PREFIX) {
        raw.to_string()
    } else {
        format!("{PREFIX}{raw}")
    }
}

/// Run `tmux -u <args>` and return its stdout; a failure names the tmux
/// subcommand, the exit code and tmux's own words.
pub fn run(args: &[&str], env: &Env) -> Result<String> {
    run_with(&run_program, args, env)
}

fn run_with(run: Runner, args: &[&str], env: &Env) -> Result<String> {
    let mut full = vec!["-u"];
    full.extend_from_slice(args);
    let result = run("tmux", &full, env);
    if result.code != 0 {
        let detail = if result.stderr.is_empty() {
            &result.stdout
        } else {
            &result.stderr
        };
        let detail = detail.trim();
        let sub = args.first().copied().unwrap_or("");
        let suffix = if detail.is_empty() {
            String::new()
        } else {
            format!(": {detail}")
        };
        return Err(CliError::failure(format!(
            "tmux {sub} failed (exit {}){suffix}",
            result.code
        )));
    }
    Ok(result.stdout)
}

/// The tmux version (`tmux -V`: `tmux 3.7c` gives `3.7c`), or `None` when
/// tmux cannot run.
pub fn version(env: &Env) -> Option<String> {
    version_with(&run_program, env)
}

pub fn version_with(run: Runner, env: &Env) -> Option<String> {
    let result = run("tmux", &["-u", "-V"], env);
    if result.code != 0 {
        return None;
    }
    let out = result.stdout.trim();
    let rest = out.strip_prefix("tmux")?;
    // `^tmux\s+(\S+)`: whitespace is required between the words.
    let trimmed = rest.trim_start();
    if trimmed.len() == rest.len() {
        return None;
    }
    trimmed.split_whitespace().next().map(str::to_string)
}

/// The pane's text, joined at soft wraps, from `lines` lines of history down
/// to the bottom of the visible screen (`capture-pane -p -J -S -<lines>`).
pub fn read_pane(pane_id: &str, lines: i64, env: &Env) -> Result<String> {
    read_pane_with(&run_program, pane_id, lines, env)
}

pub fn read_pane_with(run: Runner, pane_id: &str, lines: i64, env: &Env) -> Result<String> {
    let count = lines.max(0);
    run_with(
        run,
        &[
            "capture-pane",
            "-p",
            "-J",
            "-S",
            &format!("-{count}"),
            "-t",
            to_tmux_target(pane_id),
        ],
        env,
    )
}

/// Set (or with `None`, unset) a pane user option such as `@waycar_status`.
/// Fails on a name that is not a user option, or when tmux refuses.
pub fn set_pane_option(pane_id: &str, name: &str, value: Option<&str>, env: &Env) -> Result<()> {
    set_pane_option_with(&run_program, pane_id, name, value, env)
}

pub fn set_pane_option_with(
    run: Runner,
    pane_id: &str,
    name: &str,
    value: Option<&str>,
    env: &Env,
) -> Result<()> {
    if !name.starts_with('@') || name.len() < 2 {
        return Err(CliError::failure(format!(
            "pane option name must be a user option (@name): {name}"
        )));
    }
    let target = to_tmux_target(pane_id);
    match value {
        None => run_with(
            run,
            &["set-option", "-p", "-u", "-t", target, "--", name],
            env,
        )?,
        Some(value) => run_with(
            run,
            &["set-option", "-p", "-t", target, "--", name, value],
            env,
        )?,
    };
    Ok(())
}

/// One pane carrying Waycar's agent options. `seq` stays a string
/// (nanoseconds exceed a double's integers); `transcript` is the decoded path.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TmuxAgent {
    pub pane_id: String,
    pub session_id: String,
    pub session_name: Option<String>,
    pub window_id: String,
    pub window_name: Option<String>,
    pub cwd: Option<String>,
    pub agent: Option<String>,
    /// `working|blocked|done|idle`, or `None` when unset, unknown, or stale
    /// (the pane is dead or back at a shell).
    pub status: Option<&'static str>,
    pub session: Option<String>,
    pub transcript: Option<String>,
    pub seq: Option<String>,
    pub title: Option<String>,
    pub command: Option<String>,
}

/// `#{s/␞|␟//:field}`. An alternation, not a bracket expression, so the
/// regex removes whole characters even where tmux matches bytes.
fn stripped(field: &str) -> String {
    format!("#{{s/{RECORD_SEPARATOR}|{FIELD_SEPARATOR}//:{field}}}")
}

fn pane_format() -> String {
    let fields: Vec<String> = PANE_FIELDS.iter().map(|f| stripped(f)).collect();
    format!(
        "{RECORD_SEPARATOR}{}",
        fields.join(&FIELD_SEPARATOR.to_string())
    )
}

/// Split a listing into records of exactly `count` fields. A chunk with too
/// few or too many fields had a separator inside a value, so its fields
/// cannot be trusted and it is dropped; a short chunk was cut by a record
/// separator inside a value, so the chunk after it (that value's tail, which
/// may imitate a whole record) is dropped too.
fn records(stdout: &str, count: usize) -> Vec<Vec<&str>> {
    let mut rows = Vec::new();
    let mut tainted = false;
    // The text before the first sentinel is not a record.
    for chunk in stdout.split(RECORD_SEPARATOR).skip(1) {
        // The line break that ended this record belongs to the listing.
        let cut = !chunk.ends_with('\n');
        let body = chunk.strip_suffix('\n').unwrap_or(chunk);
        let parts: Vec<&str> = body.split(FIELD_SEPARATOR).collect();
        let trusted = !tainted && !cut && parts.len() == count;
        tainted = cut || parts.len() < count;
        if trusted {
            rows.push(parts);
        }
    }
    rows
}

fn non_empty(value: &str) -> Option<String> {
    (!value.is_empty()).then(|| value.to_string())
}

fn digits(value: &str) -> bool {
    !value.is_empty() && value.bytes().all(|b| b.is_ascii_digit())
}

/// `%<digits>`, `$<digits>` or `@<digits>`: a tmux id of the given sigil.
fn is_id(value: &str, sigil: char) -> bool {
    value.strip_prefix(sigil).is_some_and(digits)
}

/// JavaScript's `decodeURIComponent`, or `None` where it throws (a `%` not
/// followed by two hex digits, or escapes that are not UTF-8).
fn decode_uri_component(value: &str) -> Option<String> {
    let bytes = value.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hex = bytes.get(i + 1..i + 3)?;
            let pair = std::str::from_utf8(hex).ok()?;
            if !hex.iter().all(u8::is_ascii_hexdigit) {
                return None;
            }
            out.push(u8::from_str_radix(pair, 16).ok()?);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

fn decode_transcript(value: &str) -> Option<String> {
    if value.is_empty() {
        return None;
    }
    Some(decode_uri_component(value).unwrap_or_else(|| value.to_string()))
}

fn is_shell(command: &str) -> bool {
    SHELLS.contains(&command.strip_prefix('-').unwrap_or(command))
}

/// `Number.parseInt` of an id's digits; ids too long for a double compare as
/// the double they round to.
fn id_number(id: &str) -> f64 {
    id[1..].parse().unwrap_or(f64::MAX)
}

struct Candidate {
    grouped: bool,
    group: String,
    raw_session_id: String,
    session_name: String,
    agent: TmuxAgent,
}

impl Candidate {
    fn named(&self) -> bool {
        !self.grouped || self.session_name == self.group
    }

    /// Prefer one listing row per pane (`list-panes -a` lists a grouped
    /// session's panes once per session): the session named like its group,
    /// else the lowest session id.
    fn beats(&self, current: &Candidate) -> bool {
        if self.named() != current.named() {
            return self.named();
        }
        id_number(&self.raw_session_id) < id_number(&current.raw_session_id)
    }
}

/// Every pane carrying Waycar's agent options, once per pane, in listing
/// order: a pane with `@waycar_status` or `@waycar_agent` set. Fails when
/// tmux cannot list (not installed, no server running).
pub fn list_agents(env: &Env) -> Result<Vec<TmuxAgent>> {
    list_agents_with(&run_program, env)
}

pub fn list_agents_with(run: Runner, env: &Env) -> Result<Vec<TmuxAgent>> {
    let stdout = run_with(run, &["list-panes", "-a", "-F", &pane_format()], env)?;
    let mut order: Vec<String> = Vec::new();
    let mut by_pane: HashMap<String, Candidate> = HashMap::new();
    for fields in records(&stdout, PANE_FIELDS.len()) {
        let [
            pane_id,
            session_id,
            window_id,
            grouped,
            group,
            dead,
            status,
            agent,
            seq,
            command,
            session_name,
            window_name,
            cwd,
            session,
            transcript,
            title,
        ] = fields[..]
        else {
            continue;
        };
        // A record whose ids are not tmux ids is misparsed; nothing in it holds.
        if !is_id(pane_id, '%') || !is_id(session_id, '$') || !is_id(window_id, '@') {
            continue;
        }
        if session_name.starts_with(ATTACH_SESSION_PREFIX) {
            continue;
        }
        if status.is_empty() && agent.is_empty() {
            continue;
        }
        let stale = dead == "1" || is_shell(command);
        let candidate = Candidate {
            grouped: grouped == "1",
            group: group.to_string(),
            raw_session_id: session_id.to_string(),
            session_name: session_name.to_string(),
            agent: TmuxAgent {
                pane_id: to_waycar_pane_id(pane_id),
                session_id: to_waycar_pane_id(session_id),
                session_name: non_empty(session_name),
                window_id: to_waycar_pane_id(window_id),
                window_name: non_empty(window_name),
                cwd: non_empty(cwd),
                agent: non_empty(agent),
                status: STATUSES.iter().find(|s| **s == status && !stale).copied(),
                session: non_empty(session),
                transcript: decode_transcript(transcript),
                // Malformed seqs are ignored (tmux-pane-options-v1 `seq.pattern`).
                seq: valid_seq(seq).then(|| seq.to_string()),
                title: non_empty(title),
                command: non_empty(command),
            },
        };
        match by_pane.get(pane_id) {
            None => {
                order.push(pane_id.to_string());
                by_pane.insert(pane_id.to_string(), candidate);
            }
            Some(current) if candidate.beats(current) => {
                by_pane.insert(pane_id.to_string(), candidate);
            }
            Some(_) => {}
        }
    }
    Ok(order
        .iter()
        .filter_map(|id| by_pane.remove(id))
        .map(|candidate| candidate.agent)
        .collect())
}

/// `^[1-9][0-9]{0,18}$`.
fn valid_seq(seq: &str) -> bool {
    (1..=19).contains(&seq.len()) && !seq.starts_with('0') && digits(seq)
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::collections::HashMap;

    use std::path::PathBuf;

    use serde_json::Value;

    use super::*;

    fn env() -> Env {
        Env::from_pairs([
            ("TMUX", "/tmp/tmux-501/default,4242,0"),
            ("PATH", "/usr/bin"),
        ])
    }

    /// A pane as its format variables see it.
    #[derive(Clone)]
    struct Pane {
        id: &'static str,
        session: &'static str,
        window: &'static str,
        session_name: &'static str,
        window_name: &'static str,
        group: &'static str,
        status: &'static str,
        agent: &'static str,
        command: &'static str,
        extra: Vec<(&'static str, String)>,
    }

    fn pane() -> Pane {
        Pane {
            id: "%3",
            session: "$1",
            window: "@2",
            session_name: "proj",
            window_name: "fix-auth",
            group: "",
            status: "",
            agent: "claude",
            command: "2.1.286",
            extra: Vec::new(),
        }
    }

    impl Pane {
        fn with(mut self, name: &'static str, value: &str) -> Self {
            self.extra.push((name, value.to_string()));
            self
        }

        fn vars(&self) -> HashMap<&str, String> {
            let mut vars: HashMap<&str, String> = [
                ("pane_id", self.id),
                ("session_id", self.session),
                ("window_id", self.window),
                (
                    "session_grouped",
                    if self.group.is_empty() { "0" } else { "1" },
                ),
                ("session_group", self.group),
                ("pane_dead", "0"),
                ("@waycar_status", self.status),
                ("@waycar_agent", self.agent),
                ("@waycar_seq", ""),
                ("pane_current_command", self.command),
                ("session_name", self.session_name),
                ("window_name", self.window_name),
                ("pane_current_path", "/home/u/proj"),
                ("@waycar_session", ""),
                ("@waycar_transcript", ""),
                ("pane_title", "host.local"),
            ]
            .into_iter()
            .map(|(k, v)| (k, v.to_string()))
            .collect();
            for (name, value) in &self.extra {
                vars.insert(name, value.clone());
            }
            vars
        }
    }

    /// Expand a `-F` format for each pane the way tmux does: one line per
    /// pane, unset variables empty, `#{s/re/repl/:name}` substituted. With
    /// `strip: false` substitutions are skipped, as if tmux left a separator
    /// in a value.
    fn render(format: &str, panes: &[Pane], strip: bool) -> String {
        let mut out = String::new();
        for pane in panes {
            let vars = pane.vars();
            let mut rest = format;
            while let Some(start) = rest.find("#{") {
                out.push_str(&rest[..start]);
                let end = rest[start..].find('}').unwrap() + start;
                let spec = &rest[start + 2..end];
                let value = match spec.strip_prefix("s/") {
                    Some(sub) => {
                        let name = sub.split_once(":").unwrap().1;
                        let value = vars.get(name).cloned().unwrap_or_default();
                        if strip {
                            value.replace([RECORD_SEPARATOR, FIELD_SEPARATOR], "")
                        } else {
                            value
                        }
                    }
                    None => vars.get(spec).cloned().unwrap_or_default(),
                };
                out.push_str(&value);
                rest = &rest[end + 1..];
            }
            out.push_str(rest);
            out.push('\n');
        }
        out
    }

    type Calls = RefCell<Vec<(String, Vec<String>, Env)>>;

    fn answer(code: i32, stdout: &str, stderr: &str) -> RunResult {
        RunResult {
            code,
            stdout: stdout.to_string(),
            stderr: stderr.to_string(),
        }
    }

    /// A `run` answering `list-panes` from `panes` (`None`: tmux has no
    /// server), recording every call.
    fn list_with(panes: Option<&[Pane]>, strip: bool) -> (Result<Vec<TmuxAgent>>, Calls) {
        let calls: Calls = RefCell::new(Vec::new());
        let run = |cmd: &str, args: &[&str], env: &Env| {
            calls.borrow_mut().push((
                cmd.to_string(),
                args.iter().map(|a| a.to_string()).collect(),
                env.clone(),
            ));
            match panes {
                None => answer(1, "", "no server running on /tmp/tmux-501/default\n"),
                Some(panes) => {
                    let at = args.iter().position(|a| *a == "-F").unwrap();
                    answer(0, &render(args[at + 1], panes, strip), "")
                }
            }
        };
        (list_agents_with(&run, &env()), calls)
    }

    fn list(panes: &[Pane]) -> Vec<TmuxAgent> {
        list_with(Some(panes), true).0.unwrap()
    }

    fn fixed(code: i32, stdout: &str, stderr: &str) -> impl Fn(&str, &[&str], &Env) -> RunResult {
        let reply = answer(code, stdout, stderr);
        move |_, _, _| reply.clone()
    }

    #[test]
    fn only_prefixed_pane_ids_are_tmux_pane_ids() {
        assert!(is_tmux_pane_id("tmux:%3"));
        assert!(is_tmux_pane_id("tmux:%120"));
        for id in [
            "%3", "tmux:@2", "tmux:$1", "tmux:%", "tmux:%3x", "w1:p2", "",
        ] {
            assert!(!is_tmux_pane_id(id), "{id}");
        }
    }

    #[test]
    fn ids_convert_between_the_apps_prefixed_form_and_tmuxs_raw_form() {
        assert_eq!(to_tmux_target("tmux:%3"), "%3");
        assert_eq!(to_tmux_target("tmux:@2"), "@2");
        assert_eq!(to_tmux_target("%3"), "%3");
        assert_eq!(to_waycar_pane_id("%3"), "tmux:%3");
        assert_eq!(to_waycar_pane_id("tmux:%3"), "tmux:%3");
    }

    #[test]
    fn the_version_word_comes_from_tmux_v_on_the_callers_server() {
        let calls: Calls = RefCell::new(Vec::new());
        let run = |cmd: &str, args: &[&str], env: &Env| {
            calls.borrow_mut().push((
                cmd.to_string(),
                args.iter().map(|a| a.to_string()).collect(),
                env.clone(),
            ));
            answer(0, "tmux 3.7c\n", "")
        };
        assert_eq!(version_with(&run, &env()).as_deref(), Some("3.7c"));
        assert_eq!(
            *calls.borrow(),
            [(
                "tmux".to_string(),
                vec!["-u".to_string(), "-V".to_string()],
                env()
            )]
        );
        assert_eq!(
            version_with(&fixed(0, "tmux next-3.8\n", ""), &env()).as_deref(),
            Some("next-3.8")
        );
    }

    #[test]
    fn there_is_no_version_when_tmux_cannot_run_or_answers_something_else() {
        for run in [
            fixed(127, "", "tmux: not found"),
            fixed(0, "screen 4.9\n", ""),
        ] {
            assert_eq!(version_with(&run, &env()), None);
        }
    }

    #[test]
    fn the_pane_vectors_decode_as_the_swift_tests_read_them() {
        let vectors: Value =
            serde_json::from_str(include_str!("../test-vectors/tmux-pane-options-v1.json"))
                .unwrap();
        let cases = vectors["paneCases"].as_array().unwrap();
        assert!(cases.len() >= 10);
        let unknown = vectors["unknownStatus"].as_str().unwrap();
        for case in cases {
            let name = case["name"].as_str().unwrap();
            // A live pane in front of a non-shell process: only the options decide.
            let mut one = pane();
            one.command = "vector-agent";
            one.agent = "";
            for (option, value) in case["options"].as_object().unwrap() {
                let value = value.as_str().unwrap();
                match option.as_str() {
                    "@waycar_status" => one.status = Box::leak(value.to_string().into_boxed_str()),
                    "@waycar_agent" => one.agent = Box::leak(value.to_string().into_boxed_str()),
                    other => {
                        one.extra.push((
                            Box::leak(other.to_string().into_boxed_str()),
                            value.to_string(),
                        ));
                    }
                }
            }
            let agents = list(&[one]);
            let expected = &case["expected"];
            if expected["agentKind"].is_null() && expected["agentStatus"] == unknown {
                // No agent options left: the pane is not an Agent.
                assert!(agents.is_empty(), "{name}");
                continue;
            }
            assert_eq!(agents.len(), 1, "{name}");
            let agent = &agents[0];
            assert_eq!(
                agent.status.unwrap_or(unknown),
                expected["agentStatus"],
                "{name}"
            );
            assert_eq!(
                agent.agent.as_deref(),
                expected["agentKind"].as_str(),
                "{name}"
            );
            assert_eq!(
                agent.session.as_deref(),
                expected["sessionID"].as_str(),
                "{name}"
            );
            assert_eq!(
                agent.transcript.as_deref(),
                expected["transcriptPath"].as_str(),
                "{name}"
            );
            assert_eq!(
                agent.seq.as_deref(),
                expected["stateChangeSeq"].as_str(),
                "{name}"
            );
        }
    }

    #[test]
    fn lists_panes_carrying_waycars_options_with_prefixed_ids_and_every_field() {
        let mut plain = pane();
        plain.id = "%4";
        plain.agent = "";
        plain.command = "vim";
        let panes = [
            {
                let mut p = pane()
                    .with("@waycar_seq", "1727740800123456789")
                    .with("@waycar_session", "6c0e3c9a-2f1b-4a57-9d1e-0b7f5d3c2a10")
                    .with(
                        "@waycar_transcript",
                        "%2Fhome%2Fu%2F.claude%2Fprojects%2Fp%20q%2F6c0e.jsonl",
                    )
                    .with("pane_title", "\u{2733} Fix the auth bug");
                p.status = "blocked";
                p
            },
            plain,
        ];
        let (agents, calls) = list_with(Some(&panes), true);
        assert_eq!(
            agents.unwrap(),
            [TmuxAgent {
                pane_id: "tmux:%3".into(),
                session_id: "tmux:$1".into(),
                session_name: Some("proj".into()),
                window_id: "tmux:@2".into(),
                window_name: Some("fix-auth".into()),
                cwd: Some("/home/u/proj".into()),
                agent: Some("claude".into()),
                status: Some("blocked"),
                session: Some("6c0e3c9a-2f1b-4a57-9d1e-0b7f5d3c2a10".into()),
                transcript: Some("/home/u/.claude/projects/p q/6c0e.jsonl".into()),
                // Nanoseconds stay a string: they exceed a double's integers.
                seq: Some("1727740800123456789".into()),
                title: Some("\u{2733} Fix the auth bug".into()),
                command: Some("2.1.286".into()),
            }]
        );
        let calls = calls.borrow();
        assert_eq!(calls.len(), 1);
        // `-u` first: without a UTF-8 locale tmux would turn the separators into `_`.
        assert_eq!(calls[0].1[..4], ["-u", "list-panes", "-a", "-F"]);
        assert_eq!(calls[0].2, env());
    }

    #[test]
    fn titles_and_names_with_raw_tabs_and_newlines_survive_intact() {
        let mut first = pane().with("pane_title", "line one\nline\ttwo");
        first.status = "done";
        first.window_name = "a\tb";
        let mut second = pane().with("pane_title", "\n");
        second.id = "%4";
        second.status = "working";
        let agents = list(&[first, second]);
        let got: Vec<_> = agents
            .iter()
            .map(|a| {
                (
                    &a.pane_id[..],
                    a.window_name.as_deref(),
                    a.title.as_deref(),
                    a.status,
                )
            })
            .collect();
        assert_eq!(
            got,
            [
                (
                    "tmux:%3",
                    Some("a\tb"),
                    Some("line one\nline\ttwo"),
                    Some("done")
                ),
                ("tmux:%4", Some("fix-auth"), Some("\n"), Some("working")),
            ]
        );
    }

    #[test]
    fn separators_in_values_are_stripped_and_every_field_stays_in_place() {
        let mut first = pane().with(
            "pane_current_path",
            "/tmp/x\u{241f}sid\u{241f}%2Fetc%2Fsecret",
        );
        first.id = "%2";
        first.status = "blocked";
        let mut second = pane().with("pane_title", "a\u{241e}b\u{241f}c");
        second.status = "done";
        let got: Vec<_> = list(&[first, second])
            .into_iter()
            .map(|a| (a.pane_id, a.status, a.cwd, a.transcript, a.title))
            .collect();
        assert_eq!(
            got,
            [
                (
                    "tmux:%2".to_string(),
                    Some("blocked"),
                    Some("/tmp/xsid%2Fetc%2Fsecret".to_string()),
                    None,
                    Some("host.local".to_string())
                ),
                (
                    "tmux:%3".to_string(),
                    Some("done"),
                    Some("/home/u/proj".to_string()),
                    None,
                    Some("abc".to_string())
                ),
            ]
        );
    }

    fn with_status(id: &'static str, status: &'static str) -> Pane {
        let mut p = pane();
        p.id = id;
        p.status = status;
        p
    }

    fn ids_and_statuses(agents: &[TmuxAgent]) -> Vec<(&str, Option<&str>)> {
        agents.iter().map(|a| (&a.pane_id[..], a.status)).collect()
    }

    #[test]
    fn a_value_tmux_left_a_field_separator_in_drops_its_pane_and_never_shifts_fields() {
        let panes = [
            with_status("%1", "working"),
            // Would otherwise move "/etc/secret" into the transcript field.
            with_status("%2", "blocked").with(
                "pane_current_path",
                "/tmp/x\u{241f}sid\u{241f}%2Fetc%2Fsecret",
            ),
            with_status("%3", "done").with("pane_title", "a\u{241f}b"),
            with_status("%4", "idle"),
        ];
        let agents = list_with(Some(&panes), false).0.unwrap();
        assert_eq!(
            ids_and_statuses(&agents),
            [("tmux:%1", Some("working")), ("tmux:%4", Some("idle"))]
        );
        assert!(agents.iter().all(|a| a.transcript.is_none()));
    }

    #[test]
    fn a_directory_name_tmux_left_a_record_separator_in_cannot_forge_a_pane() {
        // The path's tail imitates a whole record for %9; the real pane's own
        // remaining fields complete it.
        let forged = [
            "%9", "$1", "@2", "0", "", "0", "blocked", "claude", "", "node", "evil", "win", "/p",
        ]
        .join(&FIELD_SEPARATOR.to_string());
        let panes = [
            with_status("%1", "working").with(
                "pane_current_path",
                &format!("/tmp/a{RECORD_SEPARATOR}{forged}"),
            ),
            with_status("%4", "idle"),
        ];
        let agents = list_with(Some(&panes), false).0.unwrap();
        assert_eq!(ids_and_statuses(&agents), [("tmux:%4", Some("idle"))]);
    }

    #[test]
    fn records_whose_ids_are_not_tmux_ids_are_dropped() {
        let mut bad_session = with_status("%5", "working");
        bad_session.session = "1";
        let mut bad_window = with_status("%6", "working");
        bad_window.window = "@x";
        let panes = [
            with_status("3", "working"),
            bad_session,
            bad_window,
            with_status("%7", "working"),
        ];
        let ids: Vec<_> = list(&panes).into_iter().map(|a| a.pane_id).collect();
        assert_eq!(ids, ["tmux:%7"]);
    }

    #[test]
    fn an_agent_without_a_status_still_lists_with_status_none() {
        let mut p = pane();
        p.agent = "codex";
        p.command = "codex";
        let agents = list(&[p]);
        assert_eq!(agents[0].agent.as_deref(), Some("codex"));
        assert_eq!(agents[0].status, None);
    }

    #[test]
    fn a_status_with_no_agent_kind_lists_with_agent_none() {
        let mut p = with_status("%3", "working");
        p.agent = "";
        let agents = list(&[p]);
        assert_eq!(agents[0].agent, None);
        assert_eq!(agents[0].status, Some("working"));
    }

    #[test]
    fn unknown_dead_pane_and_back_at_the_shell_statuses_read_as_none() {
        let mut shell = with_status("%3", "blocked");
        shell.command = "zsh";
        let mut login_shell = with_status("%4", "blocked");
        login_shell.command = "-bash";
        let mut node = with_status("%5", "blocked");
        node.command = "node";
        let panes = [
            with_status("%1", "thinking"),
            with_status("%2", "done").with("pane_dead", "1"),
            shell,
            login_shell,
            node,
        ];
        assert_eq!(
            ids_and_statuses(&list(&panes)),
            [
                ("tmux:%1", None),
                ("tmux:%2", None),
                ("tmux:%3", None),
                ("tmux:%4", None),
                ("tmux:%5", Some("blocked")),
            ]
        );
    }

    fn grouped(session: &'static str, name: &'static str, group: &'static str) -> Pane {
        let mut p = with_status("%3", "blocked");
        p.session = session;
        p.session_name = name;
        p.group = group;
        p
    }

    #[test]
    fn a_pane_in_grouped_sessions_lists_once_under_the_session_named_like_the_group() {
        let agents = list(&[
            grouped("$4", "proj-2", "proj"),
            grouped("$1", "proj", "proj"),
            grouped("$7", "waycar-1a2b3c4d", "proj"),
        ]);
        let got: Vec<_> = agents
            .iter()
            .map(|a| (&a.pane_id[..], &a.session_id[..], a.session_name.as_deref()))
            .collect();
        assert_eq!(got, [("tmux:%3", "tmux:$1", Some("proj"))]);
    }

    #[test]
    fn without_a_session_named_like_the_group_the_lowest_session_id_wins() {
        let agents = list(&[grouped("$12", "b", "work"), grouped("$9", "a", "work")]);
        assert_eq!(agents[0].session_id, "tmux:$9");
    }

    #[test]
    fn waycars_own_attach_sessions_are_skipped() {
        let mut p = with_status("%3", "working");
        p.session_name = "waycar-1a2b3c4d";
        assert!(list(&[p]).is_empty());
    }

    #[test]
    fn listing_fails_when_tmux_cannot_list() {
        let error = list_with(None, true).0.unwrap_err();
        assert!(error.message().contains("no server running"), "{error}");
        assert!(
            error
                .message()
                .starts_with("tmux list-panes failed (exit 1): ")
        );
    }

    #[test]
    fn captures_joined_history_and_screen_from_the_raw_pane_id() {
        let calls: Calls = RefCell::new(Vec::new());
        let run = |cmd: &str, args: &[&str], env: &Env| {
            calls.borrow_mut().push((
                cmd.to_string(),
                args.iter().map(|a| a.to_string()).collect(),
                env.clone(),
            ));
            answer(0, "$ make\nok\n", "")
        };
        assert_eq!(
            read_pane_with(&run, "tmux:%3", 60, &env()).unwrap(),
            "$ make\nok\n"
        );
        let want: Vec<String> = ["-u", "capture-pane", "-p", "-J", "-S", "-60", "-t", "%3"]
            .map(String::from)
            .to_vec();
        assert_eq!(*calls.borrow(), [("tmux".to_string(), want, env())]);
        let failing = fixed(1, "", "can't find pane: %9\n");
        let error = read_pane_with(&failing, "tmux:%9", 60, &env()).unwrap_err();
        assert!(error.message().contains("can't find pane"), "{error}");
    }

    #[test]
    fn sets_a_pane_user_option_values_starting_with_a_dash_included() {
        let calls: Calls = RefCell::new(Vec::new());
        let run = |cmd: &str, args: &[&str], env: &Env| {
            calls.borrow_mut().push((
                cmd.to_string(),
                args.iter().map(|a| a.to_string()).collect(),
                env.clone(),
            ));
            answer(0, "", "")
        };
        set_pane_option_with(&run, "tmux:%3", "@waycar_status", Some("idle"), &env()).unwrap();
        set_pane_option_with(&run, "%3", "@waycar_note", Some("-x"), &env()).unwrap();
        set_pane_option_with(&run, "tmux:%3", "@waycar_status", None, &env()).unwrap();
        let args: Vec<Vec<String>> = calls.borrow().iter().map(|c| c.1.clone()).collect();
        let strings = |list: &[&str]| list.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(
            args,
            [
                strings(&[
                    "-u",
                    "set-option",
                    "-p",
                    "-t",
                    "%3",
                    "--",
                    "@waycar_status",
                    "idle"
                ]),
                strings(&[
                    "-u",
                    "set-option",
                    "-p",
                    "-t",
                    "%3",
                    "--",
                    "@waycar_note",
                    "-x"
                ]),
                strings(&[
                    "-u",
                    "set-option",
                    "-p",
                    "-u",
                    "-t",
                    "%3",
                    "--",
                    "@waycar_status"
                ]),
            ]
        );
    }

    #[test]
    fn only_user_options_are_written_and_a_refusal_fails() {
        let calls: Calls = RefCell::new(Vec::new());
        let run = |cmd: &str, args: &[&str], env: &Env| {
            calls.borrow_mut().push((
                cmd.to_string(),
                args.iter().map(|a| a.to_string()).collect(),
                env.clone(),
            ));
            answer(1, "", "no such pane: %9\n")
        };
        let error = set_pane_option_with(&run, "tmux:%3", "status", Some("x"), &env()).unwrap_err();
        assert!(error.message().contains("user option"), "{error}");
        assert!(calls.borrow().is_empty());
        let error = set_pane_option_with(&run, "tmux:%9", "@waycar_status", Some("idle"), &env())
            .unwrap_err();
        assert!(error.message().contains("no such pane"), "{error}");
    }

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("wc-tmux-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("bin")).unwrap();
        dir
    }

    #[test]
    fn the_default_runner_finds_tmux_through_the_given_environments_path_without_a_shell() {
        let dir = scratch("path");
        let tmux = dir.join("bin/tmux");
        crate::test_support::write_script(
            &tmux,
            "[ \"$1\" = \"-u\" ] && [ \"$2\" = \"-V\" ] || exit 2\nprintf 'tmux 3.2a\\n'",
            0o755,
        );
        let path = dir.join("bin").to_string_lossy().into_owned();
        assert_eq!(
            version(&Env::from_pairs([("PATH", path.as_str())])).as_deref(),
            Some("3.2a")
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_missing_tmux_reads_as_no_version() {
        let dir = scratch("missing");
        let path = dir.join("bin").to_string_lossy().into_owned();
        assert_eq!(version(&Env::from_pairs([("PATH", path.as_str())])), None);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_program_that_cannot_start_answers_127_without_waiting_out_the_timeout() {
        let dir = scratch("nostart");
        let started = std::time::Instant::now();
        let missing = dir.join("bin/missing");
        let result = run_program(&missing.to_string_lossy(), &[], &Env::default());
        assert_eq!(result.code, 127);
        assert!(started.elapsed() < std::time::Duration::from_secs(5));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// One test drives a real tmux on a private server (its own TMUX_TMPDIR),
    /// with no locale and no TMUX, the setting where tmux sanitizes non-ASCII
    /// output. `WAYCAR_TEST_TMUX` names another tmux binary to drive.
    #[test]
    fn real_tmux_lists_agents_without_a_utf8_locale_separators_stripped_from_every_value() {
        let binary = std::env::var("WAYCAR_TEST_TMUX").unwrap_or_else(|_| "tmux".into());
        let available = std::process::Command::new(&binary)
            .arg("-V")
            .output()
            .is_ok_and(|o| o.status.success());
        if !available {
            eprintln!("skipped: tmux not installed");
            return;
        }
        let dir = std::env::temp_dir().join(format!("wc-tmux-real-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let mut path = std::env::var("PATH").unwrap_or_default();
        if binary != "tmux" {
            // list_agents runs the `tmux` on PATH.
            std::fs::create_dir_all(dir.join("bin")).unwrap();
            std::os::unix::fs::symlink(&binary, dir.join("bin/tmux")).unwrap();
            path = format!("{}:{path}", dir.join("bin").display());
        }
        let dir_text = dir.to_string_lossy().into_owned();
        let env = Env::from_pairs([("PATH", path.as_str()), ("TMUX_TMPDIR", dir_text.as_str())]);
        let tmux = |args: &[&str]| {
            std::process::Command::new(&binary)
                .args(["-f", "/dev/null"])
                .args(args)
                .env_clear()
                .envs(env.iter())
                .output()
                .unwrap()
        };
        let crafted = dir.join("a\u{241e}b\u{241f}c");
        std::fs::create_dir(&crafted).unwrap();
        assert!(
            tmux(&[
                "new-session",
                "-d",
                "-s",
                "proj",
                "-c",
                &dir_text,
                "sleep 60"
            ])
            .status
            .success()
        );
        assert!(
            tmux(&[
                "new-window",
                "-d",
                "-t",
                "proj",
                "-c",
                &crafted.to_string_lossy(),
                "sleep 60",
            ])
            .status
            .success()
        );
        let listing = tmux(&["list-panes", "-a", "-F", "#{pane_id}"]);
        let panes: Vec<String> = String::from_utf8_lossy(&listing.stdout)
            .trim()
            .split('\n')
            .map(String::from)
            .collect();
        assert_eq!(panes.len(), 2);
        for id in &panes {
            let title = "\u{2733} t\u{241e}i\u{241f}e";
            let commands: [&[&str]; 3] = [
                &["set-option", "-p", "-t", id, "@waycar_status", "blocked"],
                &["set-option", "-p", "-t", id, "@waycar_agent", "claude"],
                &["select-pane", "-t", id, "-T", title],
            ];
            for args in commands {
                assert!(tmux(args).status.success());
            }
        }

        let agents = list_agents(&env);
        tmux(&["kill-server"]);

        // The pane in the crafted directory may still report the session's
        // start directory when the platform cannot read its cwd.
        let real = std::fs::canonicalize(&dir).unwrap();
        let cwds: Vec<String> = [dir.clone(), real]
            .iter()
            .flat_map(|base| [base.clone(), base.join("abc")])
            .map(|p| p.to_string_lossy().into_owned())
            .collect();
        let agents = agents.unwrap();
        assert_eq!(agents.len(), 2);
        for agent in &agents {
            assert!(is_tmux_pane_id(&agent.pane_id), "{}", agent.pane_id);
            assert_eq!(agent.status, Some("blocked"));
            assert_eq!(agent.agent.as_deref(), Some("claude"));
            assert_eq!(agent.session_name.as_deref(), Some("proj"));
            assert_eq!(agent.title.as_deref(), Some("\u{2733} tie"));
            assert!(
                cwds.contains(agent.cwd.as_ref().unwrap()),
                "{:?}",
                agent.cwd
            );
        }
        let _ = std::fs::remove_dir_all(&dir);
    }
}
