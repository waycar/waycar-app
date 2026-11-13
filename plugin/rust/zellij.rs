//! Zellij 0.46 Host Tools: side-effect-free discovery, pane documents and hooks.
//! Documents deliberately live under HOME, not XDG_STATE_HOME: SSH readers
//! do not inherit a login shell's XDG settings. Never write to a pane's tty.

use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

use crate::atomic::{edit_locked, pane_file_name};
use crate::env::Env;
use crate::error::{CliError, Result};
use crate::exec::{RunResult, find_on_path, run_program_with_timeout};
use crate::hook_session::{HookHost, HookUpdate, next_status, percent_decode_path, read_tty};
use crate::tmux::Runner;

mod process;

pub const TIMEOUT: Duration = Duration::from_secs(2);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PaneId {
    pub session: String,
    pub pane: u32,
}

impl PaneId {
    pub fn parse(id: &str) -> Option<Self> {
        let (session, pane) = id.strip_prefix("zellij:")?.rsplit_once('/')?;
        let number = pane.strip_prefix("terminal_")?;
        if session.is_empty()
            || session.contains('/')
            || session.chars().any(char::is_control)
            || number.is_empty()
            || !number.bytes().all(|b| b.is_ascii_digit())
            || (number.len() > 1 && number.starts_with('0'))
        {
            return None;
        }
        Some(Self {
            session: session.into(),
            pane: number.parse().ok()?,
        })
    }

    pub fn from_env(env: &Env) -> Option<Self> {
        Self::parse(&format!(
            "zellij:{}/terminal_{}",
            env.non_empty("ZELLIJ_SESSION_NAME")?,
            env.non_empty("ZELLIJ_PANE_ID")?
        ))
    }

    pub fn id(&self) -> String {
        format!("zellij:{}/terminal_{}", self.session, self.pane)
    }
    pub fn terminal(&self) -> String {
        format!("terminal_{}", self.pane)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Document {
    pub version: u32,
    pub pane: String,
    pub kind: Option<String>,
    pub status: Option<String>,
    pub seq: Option<u64>,
    pub session: Option<String>,
    pub transcript: Option<String>,
    pub launch: Option<String>,
    pub pid: Option<u32>,
    pub updated_ms: Option<u64>,
}

impl Document {
    pub fn parse(raw: &str) -> Option<Self> {
        let v: Value = serde_json::from_str(raw).ok()?;
        if v["version"].as_u64()? != 1 {
            return None;
        }
        let pane = v["pane"].as_str()?;
        PaneId::parse(pane)?;
        let text = |name: &str| v[name].as_str().map(str::to_string);
        Some(Self {
            version: 1,
            pane: pane.into(),
            kind: text("kind"),
            status: text("status")
                .filter(|s| matches!(s.as_str(), "working" | "blocked" | "done" | "idle")),
            seq: v["seq"].as_u64(),
            session: text("session"),
            transcript: text("transcript"),
            launch: text("launch"),
            pid: v["pid"].as_u64().and_then(|n| u32::try_from(n).ok()),
            updated_ms: v["updated_ms"].as_u64(),
        })
    }
    fn new(pane: &str) -> Self {
        Self {
            version: 1,
            pane: pane.into(),
            kind: None,
            status: None,
            seq: None,
            session: None,
            transcript: None,
            launch: None,
            pid: None,
            updated_ms: None,
        }
    }
}

pub fn directory(env: &Env) -> PathBuf {
    Path::new(env.get("HOME").unwrap_or("")).join(".local/state/waycar/zellij")
}
pub fn read_document(env: &Env, id: &str) -> Option<Document> {
    let doc = Document::parse(&fs::read_to_string(directory(env).join(pane_file_name(id))).ok()?)?;
    (doc.pane == id).then_some(doc)
}

#[derive(Debug, Clone)]
pub struct ZellijCommand {
    pub bin: String,
    pub version: String,
    pub env: Env,
}

pub fn parse_version(text: &str) -> Option<String> {
    let version = text.trim().strip_prefix("zellij ")?;
    let parts: Vec<u32> = version
        .split('.')
        .map(str::parse)
        .collect::<std::result::Result<_, _>>()
        .ok()?;
    (parts.len() == 3 && parts.as_slice() >= [0, 46, 0].as_slice()).then(|| version.to_string())
}

pub fn command(env: &Env, run: Runner<'_>) -> Option<ZellijCommand> {
    let home = Path::new(env.get("HOME").unwrap_or(""));
    let mut dirs: Vec<PathBuf> = env
        .get("PATH")
        .unwrap_or("")
        .split(':')
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
        .collect();
    dirs.extend([home.join(".local/bin"), home.join(".cargo/bin")]);
    if !cfg!(test) {
        dirs.extend(["/opt/homebrew/bin", "/usr/local/bin"].map(PathBuf::from));
    }
    dirs.push(home.join(".nix-profile/bin"));
    if !cfg!(test) {
        dirs.extend(
            [
                "/nix/var/nix/profiles/default/bin",
                "/run/current-system/sw/bin",
            ]
            .map(PathBuf::from),
        );
    }
    for dir in dirs {
        let Some(bin) = find_on_path(&dir.join("zellij").to_string_lossy(), env) else {
            continue;
        };
        let bin = bin.to_string_lossy().into_owned();
        let result = run(&bin, &["--version"], env);
        if result.code == 0
            && let Some(version) = parse_version(&result.stdout)
        {
            return Some(ZellijCommand {
                bin,
                version,
                env: env.clone(),
            });
        }
    }
    None
}

pub fn run_system(bin: &str, args: &[&str], env: &Env) -> RunResult {
    run_program_with_timeout(bin, args, env, TIMEOUT)
}

/// `ls -s` includes resurrectable sessions without marking them. Use `-n`
/// and remove the age instead, so GC and inventory never treat EXITED as live.
pub fn sessions(z: &ZellijCommand, run: Runner<'_>) -> Result<Vec<String>> {
    let out = run(&z.bin, &["ls", "-n"], &z.env);
    if out.code != 0 {
        if out.stdout.contains("No active zellij sessions")
            || out.stderr.contains("No active zellij sessions")
        {
            return Ok(Vec::new());
        }
        return Err(CliError::failure("Zellij cannot list sessions"));
    }
    let mut live = Vec::new();
    for line in out.stdout.lines() {
        let line = line.trim_end_matches(' ');
        let (line, exited) = match line.strip_suffix(" (EXITED - attach to resurrect)") {
            Some(line) => (line, true),
            None => (line.strip_suffix(" (current)").unwrap_or(line), false),
        };
        let parsed = line.rsplit_once(" [Created ").and_then(|(name, age)| {
            let age = age.strip_suffix(" ago]")?;
            (!name.is_empty()
                && !name.contains('/')
                && !name.chars().any(char::is_control)
                && !age.is_empty()
                && !age.contains(['[', ']'])
                && !age.chars().any(char::is_control))
            .then_some(name)
        });
        let name = parsed.ok_or_else(|| CliError::failure("invalid Zellij session list"))?;
        if !exited {
            live.push(name.to_string());
        }
    }
    Ok(live)
}

pub fn panes(z: &ZellijCommand, session: &str, run: Runner<'_>) -> Result<Vec<Value>> {
    let out = run(
        &z.bin,
        &["-s", session, "action", "list-panes", "-j"],
        &z.env,
    );
    if out.code != 0 {
        return Err(CliError::failure("Zellij cannot list panes"));
    }
    let rows: Vec<Value> = serde_json::from_str(&out.stdout)
        .map_err(|_| CliError::failure("invalid Zellij pane list"))?;
    Ok(rows
        .into_iter()
        .filter(|p| p["is_plugin"] != true && p["is_suppressed"] != true && p["exited"] != true)
        .collect())
}

pub fn root_record(pane: &Value) -> Option<&Value> {
    pane["program_status"]
        .as_array()?
        .iter()
        .find(|s| s.get("id") == Some(&Value::Null))
}
pub fn status<'a>(pane: &'a Value, doc: Option<&'a Document>) -> Option<&'a str> {
    if let Some(root) = root_record(pane) {
        return match root["state"].as_str()? {
            "Working" => Some("working"),
            "Done" => Some("done"),
            "Blocked" | "Error" => Some("blocked"),
            "Idle" => Some("idle"),
            _ => None,
        };
    }
    doc.and_then(|d| d.status.as_deref())
}
pub fn kind<'a>(pane: &'a Value, doc: Option<&'a Document>) -> Option<&'a str> {
    root_record(pane)
        .and_then(|r| r["app"].as_str())
        .map(|s| if s == "claude-code" { "claude" } else { s })
        .or_else(|| doc?.kind.as_deref())
}

pub fn inventory(z: &ZellijCommand, run: Runner<'_>) -> Result<Vec<Value>> {
    let mut rows = Vec::new();
    for session in sessions(z, run)? {
        for pane in panes(z, &session, run)? {
            let Some(n) = pane["id"].as_u64().and_then(|n| u32::try_from(n).ok()) else {
                continue;
            };
            let id = PaneId {
                session: session.clone(),
                pane: n,
            }
            .id();
            let doc = read_document(&z.env, &id);
            rows.push(json!({
                "pane_id": id,
                "agent": kind(&pane, doc.as_ref()),
                "agent_status": status(&pane, doc.as_ref()),
                "workspace_id": format!("zellij:{session}"),
                "workspace_label": session,
                "tab_id": format!("zellij:{session}/tab_{}", pane["tab_id"]),
                "tab_label": pane["tab_name"],
                "terminal_title": pane["title"],
                "terminal_title_stripped": pane["title"],
                "cwd": pane["pane_cwd"],
                "agent_session": doc.as_ref().and_then(|d| d.session.as_deref()),
            }));
        }
    }
    Ok(rows)
}

/// Unknown inventory retains all markers; callers never judge a stale doc
/// when Zellij cannot answer.
pub fn live_ids(env: &Env, run: Runner<'_>) -> Option<Vec<String>> {
    Some(
        inventory(&command(env, run)?, run)
            .ok()?
            .iter()
            .filter_map(|p| p["pane_id"].as_str().map(str::to_string))
            .collect(),
    )
}

pub fn collect_documents(z: &ZellijCommand, run: Runner<'_>) {
    let Ok(live) = sessions(z, run) else {
        return;
    };
    let Ok(files) = fs::read_dir(directory(&z.env)) else {
        return;
    };
    for file in files.flatten() {
        let path = file.path();
        if path.extension().is_none_or(|e| e != "json") {
            continue;
        }
        let _ = edit_locked(&path, "zellij", |lines| {
            if let Some(doc) = Document::parse(&lines.join("\n"))
                && let Some(id) = PaneId::parse(&doc.pane)
                && !live.contains(&id.session)
            {
                let _ = fs::remove_file(&path);
            }
            None
        });
    }
}

pub fn process_environment(pid: u32, env: &Env) -> Option<Env> {
    if pid <= 1 {
        return None;
    }
    process::read(pid, env).map(|p| p.env)
}

pub fn process_arguments(pid: u32, env: &Env) -> Option<Vec<String>> {
    if pid <= 1 {
        return None;
    }
    process::read(pid, env).map(|p| p.argv)
}

pub struct Target<'a> {
    pub id: PaneId,
    pub pid: u32,
    pub agent_env: Env,
    pub env: &'a Env,
    pub host: &'a dyn HookHost,
}

pub fn resolve<'a>(
    agent: &str,
    env: &'a Env,
    ppid: u32,
    host: &'a dyn HookHost,
) -> Option<Target<'a>> {
    let id = PaneId::from_env(env)?;
    let mut pid = if agent == "claude" {
        env.get("CLAUDE_PID")
            .and_then(|p| p.parse().ok())
            .unwrap_or(ppid)
    } else {
        ppid
    };
    if pid <= 1 {
        return None;
    }
    let tty = match read_tty(host, &pid.to_string()) {
        Some(tty) => tty,
        None => {
            if pid != ppid || matches!(agent, "codex" | "cline") {
                return None;
            }
            pid = host.ppid(&pid.to_string()).parse().ok()?;
            if pid <= 1 {
                return None;
            }
            read_tty(host, &pid.to_string())?
        }
    };
    let own = host.process_env(pid)?;
    if PaneId::from_env(&own)? != id {
        return None;
    }
    // An inherited pair plus any tty is not ownership. The first child of
    // a Zellij server is the pane root; a nested `script`/tmux pty has a
    // different tty, and a process outside Zellij has no such ancestor.
    let mut root = pid;
    for _ in 0..16 {
        let parent: u32 = host.ppid(&root.to_string()).parse().ok()?;
        if parent <= 1 {
            return None;
        }
        if is_server(&host.argv(parent)?) {
            if read_tty(host, &root.to_string()).as_deref() != Some(&tty)
                || PaneId::from_env(&host.process_env(root)?)? != id
            {
                return None;
            }
            return Some(Target {
                id,
                pid,
                agent_env: own,
                env,
                host,
            });
        }
        root = parent;
    }
    None
}

fn is_server(argv: &[String]) -> bool {
    argv.first().is_some_and(|program| {
        Path::new(program)
            .file_name()
            .is_some_and(|name| name == "zellij")
    }) && argv.get(1).map(String::as_str) == Some("--server")
        && argv.get(2).is_some()
}

impl Target<'_> {
    pub fn apply(&self, agent: &str, update: &HookUpdate) {
        let id = self.id.id();
        let path = directory(self.env).join(pane_file_name(&id));
        let mut notification = None;
        let mut resume = None;
        let outcome = edit_locked(&path, "zellij", |lines| {
            let mut doc = Document::parse(&lines.join("\n"))
                .filter(|d| d.pane == id)
                .unwrap_or_else(|| Document::new(&id));
            if update.release {
                if update
                    .session_id
                    .as_ref()
                    .zip(doc.session.as_ref())
                    .is_some_and(|(a, b)| a != b)
                {
                    return None;
                }
                if fs::remove_file(&path).is_ok() {
                    notification = Some("release".to_string());
                }
                return None;
            }
            let next = update
                .status
                .and_then(|s| next_status(s, doc.status.as_deref()))
                .filter(|s| Some(*s) != doc.status.as_deref());
            if next.is_none() && update.options.is_empty() {
                return None;
            }
            for (key, value) in &update.options {
                match *key {
                    "@waycar_agent" => doc.kind = Some(value.clone()),
                    "@waycar_session" => {
                        doc.session = Some(value.clone());
                        resume = Some(value.clone());
                    }
                    "@waycar_transcript" => doc.transcript = percent_decode_path(value),
                    _ => {}
                }
            }
            if let Some(next) = next {
                doc.kind = Some(agent.into());
                doc.status = Some(next.into());
                let now = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap_or_default();
                doc.seq = Some(
                    doc.seq
                        .unwrap_or(0)
                        .saturating_add(1)
                        .max(now.as_nanos() as u64),
                );
                notification = Some(next.into());
            }
            doc.launch = self
                .agent_env
                .non_empty("WAYCAR_LAUNCH")
                .map(str::to_string)
                .or(doc.launch);
            doc.pid = Some(self.pid);
            doc.updated_ms = Some(
                SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_millis() as u64,
            );
            Some(vec![
                json!({
                    "version": doc.version, "pane": doc.pane, "kind": doc.kind,
                    "status": doc.status, "seq": doc.seq, "session": doc.session,
                    "transcript": doc.transcript, "launch": doc.launch,
                    "pid": doc.pid, "updated_ms": doc.updated_ms,
                })
                .to_string(),
            ])
        });
        if outcome.is_err() {
            return;
        }
        if let Some(status) = notification {
            self.host.zellij_notify(&id, &status, self.env);
        }
        if let Some(session) = resume
            && let Some(mut argv) = resume_argv(agent, &session)
        {
            if agent == "codex"
                && self
                    .host
                    .argv(self.pid)
                    .is_some_and(|args| args.iter().any(|arg| arg == "--no-daemon"))
            {
                argv.insert(1, "--no-daemon".into());
            }
            let run = |bin: &str, args: &[&str], env: &Env| self.host.zellij_run(bin, args, env);
            if let Some(z) = command(self.env, &run) {
                let terminal = self.id.terminal();
                let mut args = vec![
                    "-s",
                    &self.id.session,
                    "action",
                    "set-resurrect-command",
                    "--pane-id",
                    &terminal,
                    "--",
                ];
                args.extend(argv.iter().map(String::as_str));
                let _ = run(&z.bin, &args, &z.env);
            }
        }
    }
}

/// Resume-only argv, pinned against harness-launch-v1.json. No Chat Mode,
/// model overrides or launch-time first message belongs in resurrection.
pub fn resume_argv(kind: &str, session: &str) -> Option<Vec<String>> {
    let (program, prefix, flag) = match kind {
        "claude" | "qwen" | "gemini" | "grok" | "devin" => (kind, None, "--resume"),
        "codex" | "muse" => (kind, None, "resume"),
        "opencode" | "kilo" | "pi" => (kind, None, "--session"),
        "omp" | "copilot" => return Some(vec![kind.into(), format!("--resume={session}")]),
        "agy" => (kind, None, "--conversation"),
        "hermes" => (kind, Some("chat"), "--resume"),
        "cline" => (kind, Some("-i"), "--id"),
        "cursor" => ("cursor-agent", None, "--resume"),
        "kiro" => ("kiro-cli", Some("chat"), "--resume-id"),
        _ => return None,
    };
    Some(
        std::iter::once(program)
            .chain(prefix)
            .chain([flag, session])
            .map(str::to_string)
            .collect(),
    )
}

#[cfg(test)]
mod tests;
