//! Test doubles for the Live Activity hook and tick tests
//! (`activity_hook.rs`, `activity_tick.rs`): a Host directory, the registration
//! file, an in-process relay, a clock that moves when it sleeps, and a fake
//! herdr and tmux behind one program runner. They are the Rust counterparts of
//! the fixtures `test/activity-hook.test.js` and `test/activity-tick.test.js`
//! build.

use std::fs;
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::Duration;

use serde_json::{Map, Value, json};

use crate::activity_envelope::decrypt_activity_envelope;
use crate::base64;
use crate::deps::{Clock, Fetch};
use crate::env::Env;
use crate::error::Result;
use crate::exec::RunResult;
use crate::http::Response;
use crate::test_support::{TempDir, write_stub};

pub(crate) const DEBOUNCE_MS: u64 = 120;
pub(crate) const RETRY_DELAY_MS: u64 = 10;
pub(crate) const START_GRACE_MS: u64 = 30;
pub(crate) const ALERT_TOKEN: &str =
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
pub(crate) const ACTIVITY_TOKEN_A: &str =
    "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
pub(crate) const ACTIVITY_TOKEN_B: &str =
    "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd";
pub(crate) const START_TOKEN: &str =
    "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
pub(crate) const BLOCKED_TOKEN: &str =
    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
pub(crate) const HOST_ID: &str = "6F9619FF-8B86-D011-B42D-00C04FC964FF";
pub(crate) const PANE_ID: &str = "w1:p2";

/// `Buffer.from(Array.from({length: 32}, (_, i) => i))`
pub(crate) fn key_a() -> Vec<u8> {
    (0..32).collect()
}

/// `Buffer.from(Array.from({length: 32}, (_, i) => 255 - i))`
pub(crate) fn key_b() -> Vec<u8> {
    (0..32).map(|i| 255 - i as u8).collect()
}

/// A Host: `home/config` and `home/state` (the test's `configDir` and
/// `stateDir`), removed on drop.
pub(crate) struct Sandbox {
    root: TempDir,
    pub config_dir: PathBuf,
    pub state_dir: PathBuf,
}

impl Sandbox {
    pub(crate) fn new(label: &str) -> Self {
        let root = TempDir::new(label);
        let config_dir = root.path().join("config");
        let state_dir = root.path().join("state");
        fs::create_dir_all(&config_dir).unwrap();
        fs::create_dir_all(&state_dir).unwrap();
        Self {
            root,
            config_dir,
            state_dir,
        }
    }

    /// The test's `home`.
    pub(crate) fn home(&self) -> &Path {
        self.root.path()
    }

    pub(crate) fn activity_dir(&self) -> PathBuf {
        self.state_dir.join("activity")
    }

    /// The environment herdr injects into a hook, plus `HOME` and a `PATH`,
    /// and a runtime directory that holds no core socket (so no test finds a
    /// core of the machine it runs on).
    pub(crate) fn herdr_env(&self) -> Env {
        Env::from_pairs([
            ("PATH", "/usr/bin:/bin"),
            ("HOME", self.home().to_str().unwrap()),
            ("XDG_RUNTIME_DIR", self.home().join("run").to_str().unwrap()),
            ("HERDR_PLUGIN_CONFIG_DIR", self.config_dir.to_str().unwrap()),
            ("HERDR_PLUGIN_STATE_DIR", self.state_dir.to_str().unwrap()),
        ])
    }

    /// A Host with herdr-core: the binary in `~/.local/bin` (never run: the
    /// tests' [`FakeRun`] answers for it) and a core listening on a socket
    /// `HC_SOCKET` names in the returned environment, which is herdr's plus that
    /// (a core terminal's hook sees it as `HC_TERMINAL_SOCKET`). The listener
    /// must outlive the run.
    pub(crate) fn core_env(&self) -> (UnixListener, Env) {
        let bin_dir = self.home().join(".local/bin");
        fs::create_dir_all(&bin_dir).unwrap();
        write_stub(&bin_dir.join("herdr-core"), "exit 0");
        let socket = self.home().join("core.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        let mut env = self.herdr_env();
        env.set("HC_SOCKET", socket.to_str().unwrap());
        (listener, env)
    }

    /// `notify.json` with the tests' short debounce and retry delay; `relay_url`
    /// is the relay's (none: the config default), `overrides` an object of more
    /// keys.
    pub(crate) fn write_config(&self, relay_url: Option<&str>, overrides: Value) {
        let mut config = Map::new();
        if let Some(url) = relay_url {
            config.insert("relay_url".into(), json!(url));
        }
        config.insert("activity_debounce_ms".into(), json!(DEBOUNCE_MS));
        config.insert("retry_delay_ms".into(), json!(RETRY_DELAY_MS));
        if let Value::Object(more) = overrides {
            config.extend(more);
        }
        fs::write(
            self.config_dir.join("notify.json"),
            Value::Object(config).to_string(),
        )
        .unwrap();
    }

    pub(crate) fn write_registration(&self, devices: &[Value], extra: Value) {
        let mut file = Map::new();
        file.insert("v".into(), json!(1));
        file.insert("devices".into(), Value::Array(devices.to_vec()));
        if let Value::Object(more) = extra {
            file.extend(more);
        }
        fs::write(
            self.config_dir.join("notifications.json"),
            Value::Object(file).to_string(),
        )
        .unwrap();
    }

    pub(crate) fn read_registration(&self) -> Value {
        read_json(&self.config_dir.join("notifications.json"))
    }

    pub(crate) fn write_state_file(&self, name: &str, value: &Value) {
        fs::create_dir_all(self.activity_dir()).unwrap();
        fs::write(self.activity_dir().join(name), value.to_string()).unwrap();
    }

    pub(crate) fn read_state_file(&self, name: &str) -> Value {
        read_json(&self.activity_dir().join(name))
    }

    pub(crate) fn write_last_state(&self, state: &Value) {
        self.write_state_file("last-state.json", state);
    }

    pub(crate) fn write_plan_steps(&self, map: &Value) {
        self.write_state_file("plan-steps.json", map);
    }

    /// A summary-store record (`writeRecord`): `v: 1`, the pane, status and
    /// summary, `progress` when given.
    pub(crate) fn write_record(&self, pane: &str, status: &str, progress: Option<Value>) {
        let mut record = json!({
            "v": 1, "pane": pane, "status": status,
            "summary": "Refactoring the transport queue", "ts": 1, "hash": null,
        });
        if let Some(progress) = progress {
            record["progress"] = progress;
        }
        let path = PathBuf::from(crate::summary::store::summary_path(
            &self.config_dir.to_string_lossy(),
            pane,
        ));
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, format!("{record}\n")).unwrap();
    }
}

pub(crate) fn read_json(path: &Path) -> Value {
    serde_json::from_slice(&fs::read(path).unwrap()).unwrap()
}

/// A registration entry (`device()`): a sandbox-env device with `notify` flags
/// and, unless `live_activity` is `Some(Value::Null)`, a live activity at
/// `activity_token` (or the given `live_activity` object). `extra` keys are
/// merged into the entry.
pub(crate) struct DeviceSpec {
    pub token: &'static str,
    pub key: Vec<u8>,
    pub env: &'static str,
    pub activity_token: &'static str,
    pub live_activity: Option<Value>,
    pub extra: Value,
}

impl Default for DeviceSpec {
    fn default() -> Self {
        Self {
            token: ALERT_TOKEN,
            key: key_a(),
            env: "sandbox",
            activity_token: ACTIVITY_TOKEN_A,
            live_activity: None,
            extra: Value::Null,
        }
    }
}

impl DeviceSpec {
    pub(crate) fn build(self) -> Value {
        let mut entry = json!({
            "token": self.token,
            "key": base64::encode_url(&self.key),
            "env": self.env,
            "notify": { "blocked": true, "done": true },
        });
        if let Value::Object(extra) = self.extra {
            entry.as_object_mut().unwrap().extend(extra);
        }
        match self.live_activity {
            Some(Value::Null) => {}
            Some(live) => entry["live_activity"] = live,
            None => {
                entry["live_activity"] =
                    json!({ "token": self.activity_token, "started_at": "2026-01-01T00:00:00Z" });
            }
        }
        entry
    }
}

/// The default device: alert token `a…`, key A, update token `c…`.
pub(crate) fn device() -> Value {
    DeviceSpec::default().build()
}

/// The device the tests register second: alert token `b…`, key B, update token
/// `d…`, `production`.
pub(crate) fn second_device() -> Value {
    DeviceSpec {
        token: BLOCKED_TOKEN,
        key: key_b(),
        env: "production",
        activity_token: ACTIVITY_TOKEN_B,
        ..DeviceSpec::default()
    }
    .build()
}

/// A herdr `agent list` row (`listedAgent`); `title` `None` leaves the terminal
/// title out.
pub(crate) fn listed_agent(pane: &str, status: &str, title: Option<&str>) -> Value {
    let mut info = json!({
        "agent": "claude", "agent_status": status, "pane_id": pane, "workspace_id": "w1",
    });
    if let Some(title) = title {
        info["terminal_title"] = json!(format!("⠂ {title}"));
        info["terminal_title_stripped"] = json!(title);
    }
    info
}

/// The default listed agent: `w1:p2`, working, "implement live activity".
pub(crate) fn default_agent() -> Value {
    listed_agent(PANE_ID, "working", Some("implement live activity"))
}

/// `HERDR_PLUGIN_EVENT_JSON` for a status change of `pane_id`.
pub(crate) fn status_event(status: &str, pane_id: &str) -> String {
    json!({
        "event": "pane_agent_status_changed",
        "data": {
            "type": "pane_agent_status_changed", "pane_id": pane_id,
            "workspace_id": "w1", "agent_status": status, "agent": "claude",
        },
    })
    .to_string()
}

/// A pane as tmux formats see it (`tmuxPane`); options are the agent hooks'
/// `@waycar_*`.
pub(crate) fn tmux_pane(id: &str, status: &str) -> Value {
    json!({
        "pane_id": id, "session_id": "$1", "window_id": "@2", "session_grouped": "0",
        "session_group": "", "pane_dead": "0", "@waycar_status": status,
        "@waycar_agent": "claude", "@waycar_seq": "1790000000000000000",
        "pane_current_command": "2.1.286", "session_name": "dev", "window_name": "api",
        "pane_current_path": "/work/api", "pane_title": "✳ Fix flaky test",
    })
}

/// A herdr-core terminal record (`herdr-core get <t> --json`): live, with the
/// status word `status` (`None`: it never reported), app `claude`, folder
/// `/work/api`, name `<address>-name`; `extra` keys are merged over it.
pub(crate) fn core_record(address: &str, status: Option<&str>, extra: Value) -> Value {
    let mut record = json!({
        "address": address, "state": "live", "pid": 100, "name": format!("{address}-name"),
        "cwd": "/work", "reported": status.is_some(), "turn": 0, "labels": {},
        "foreground": { "pid": 100, "name": "claude", "argv": ["claude"], "cwd": "/work/api" },
        "status": status.map(|state| json!({ "state": state, "app": "claude" })),
    });
    if let Value::Object(more) = extra {
        record.as_object_mut().unwrap().extend(more);
    }
    record
}

/// herdr-core's CLI as `hc` answers it for a throwaway core: `--version`,
/// `ls --json` (the live records, in `ls`'s compact shape) and `get <t> --json`
/// (a missing terminal is `not_found`, exit 3); anything else is a usage
/// error. Every call is logged by its arguments.
pub(crate) struct FakeCore {
    records: Mutex<Vec<Value>>,
    /// What `ls` lists when it is not the records `get` answers from (a
    /// terminal that changed between the two calls).
    listed: Mutex<Option<Vec<Value>>>,
    /// Every command but `--version` fails, as when core cannot be reached.
    down: AtomicBool,
    /// Only `get` fails.
    get_down: AtomicBool,
    pub invocations: Mutex<Vec<Vec<String>>>,
}

impl FakeCore {
    pub(crate) fn new(records: Vec<Value>) -> Self {
        Self {
            records: Mutex::new(records),
            listed: Mutex::new(None),
            down: AtomicBool::new(false),
            get_down: AtomicBool::new(false),
            invocations: Mutex::default(),
        }
    }

    pub(crate) fn set_listed(&self, records: Vec<Value>) {
        *self.listed.lock().unwrap() = Some(records);
    }

    pub(crate) fn set_down(&self, down: bool) {
        self.down.store(down, Ordering::SeqCst);
    }

    pub(crate) fn set_get_down(&self, down: bool) {
        self.get_down.store(down, Ordering::SeqCst);
    }

    pub(crate) fn invocation_args(&self) -> Vec<Vec<String>> {
        self.invocations.lock().unwrap().clone()
    }

    /// The terminals `ls --json` lists.
    fn listing(records: &[Value]) -> Value {
        let terminals: Vec<Value> = records
            .iter()
            .filter(|record| record["state"] == "live")
            .map(|record| {
                json!({
                    "address": record["address"],
                    "agent": record["status"]["app"].as_str().or(record["foreground"]["name"].as_str()),
                    "cwd": record["cwd"], "name": record["name"], "state": record["state"],
                    "status": record["status"]["state"], "turn": record["turn"],
                })
            })
            .collect();
        json!({ "hidden_finished": 0, "terminals": terminals })
    }

    pub(crate) fn answer(&self, args: &[&str]) -> RunResult {
        self.invocations
            .lock()
            .unwrap()
            .push(args.iter().map(|arg| arg.to_string()).collect());
        let records = self.records.lock().unwrap().clone();
        let unavailable = || RunResult {
            stdout: String::new(),
            stderr: "herdr-core: unavailable".into(),
            code: 5,
        };
        match args {
            ["--version"] => ok_run("hc 0.1.14\n".into()),
            [_, ..] if self.down.load(Ordering::SeqCst) => unavailable(),
            ["ls", "--json"] => {
                let listed = self.listed.lock().unwrap().clone();
                ok_run(Self::listing(listed.as_deref().unwrap_or(&records)).to_string())
            }
            ["get", ..] if self.get_down.load(Ordering::SeqCst) => unavailable(),
            ["get", address, "--json"] => {
                match records.iter().find(|record| record["address"] == *address) {
                    Some(record) => ok_run(record.to_string()),
                    None => RunResult {
                        stdout: json!({ "error": { "kind": "not_found", "message": "no such terminal" } })
                            .to_string(),
                        stderr: String::new(),
                        code: 3,
                    },
                }
            }
            _ => RunResult {
                stdout: String::new(),
                stderr: format!("fake herdr-core: unexpected {}", args.join(" ")),
                code: 2,
            },
        }
    }
}

/// `-F` output for `panes`: `#{name}` and `#{s/…/…/:name}` take the pane's
/// field, else empty; one row per pane.
pub(crate) fn expand_panes(format: &str, panes: &[Value]) -> String {
    let mut out = String::new();
    for pane in panes {
        let mut rest = format;
        while let Some(open) = rest.find("#{") {
            out.push_str(&rest[..open]);
            let close = rest[open..].find('}').unwrap() + open;
            let spec = &rest[open + 2..close];
            let name = spec
                .strip_prefix("s/")
                .and_then(|sub| sub.split_once("//:"))
                .map_or(spec, |(_, name)| name);
            out.push_str(pane.get(name).and_then(Value::as_str).unwrap_or(""));
            rest = &rest[close + 1..];
        }
        out.push_str(rest);
        out.push('\n');
    }
    out
}

fn ok_run(stdout: String) -> RunResult {
    RunResult {
        stdout,
        stderr: String::new(),
        code: 0,
    }
}

/// herdr's CLI as the JS tests' stub answers it: `agent list`, `workspace list`
/// and `tab|pane list` from one response, every invocation logged. A
/// registration file parked as `registration-after-list.json` next to it is
/// moved into place on the first `agent list` (the app registering a token
/// while the hook runs).
pub(crate) struct FakeHerdr {
    response: Mutex<Value>,
    pub invocations: Mutex<Vec<Vec<String>>>,
    after_list: Mutex<Option<(PathBuf, PathBuf)>>,
}

impl FakeHerdr {
    pub(crate) fn new(agents: Vec<Value>) -> Self {
        let herdr = Self {
            response: Mutex::new(Value::Null),
            invocations: Mutex::default(),
            after_list: Mutex::default(),
        };
        herdr.set(
            agents,
            vec![json!({ "workspace_id": "w1", "label": "Waycar" })],
            vec![],
            vec![],
        );
        herdr
    }

    /// `writeHerdrStub(agents, workspaces, tabs, panes)`.
    pub(crate) fn set(
        &self,
        agents: Vec<Value>,
        workspaces: Vec<Value>,
        tabs: Vec<Value>,
        panes: Vec<Value>,
    ) {
        *self.response.lock().unwrap() =
            json!({ "agents": agents, "workspaces": workspaces, "tabs": tabs, "panes": panes });
    }

    pub(crate) fn set_agents(&self, agents: Vec<Value>) {
        self.response.lock().unwrap()["agents"] = Value::Array(agents);
    }

    /// Move `from` to `to` on the next `agent list`.
    pub(crate) fn register_after_list(&self, from: PathBuf, to: PathBuf) {
        *self.after_list.lock().unwrap() = Some((from, to));
    }

    pub(crate) fn invocation_args(&self) -> Vec<Vec<String>> {
        self.invocations.lock().unwrap().clone()
    }

    pub(crate) fn answer(&self, args: &[&str]) -> RunResult {
        self.invocations
            .lock()
            .unwrap()
            .push(args.iter().map(|arg| arg.to_string()).collect());
        let response = self.response.lock().unwrap().clone();
        match args {
            ["agent", "list"] => {
                if let Some((from, to)) = self.after_list.lock().unwrap().take()
                    && from.exists()
                {
                    fs::rename(from, to).unwrap();
                }
                ok_run(json!({ "id": "cli:agent:list", "result": { "agents": response["agents"], "type": "agent_list" } }).to_string())
            }
            ["workspace", "list"] => ok_run(json!({ "id": "cli:workspace:list", "result": { "workspaces": response["workspaces"], "type": "workspace_list" } }).to_string()),
            [kind @ ("tab" | "pane"), "list", ..] => {
                let key = format!("{kind}s");
                ok_run(json!({ "result": { key.clone(): response[key] } }).to_string())
            }
            _ => RunResult {
                stdout: String::new(),
                stderr: format!("stub: unexpected subcommand {}", args.join(" ")),
                code: 64,
            },
        }
    }
}

/// The program runner of a test (`fakeRun`): `tmux` lists `panes` (none: no
/// server), a program named `herdr-core` is `core` (none: no such answer, as
/// for a binary that is not herdr-core), anything else is herdr, answered by
/// `herdr` (none: not installed). Every call, tmux's without its `-u`, is
/// logged as `[cmd, args...]`.
pub(crate) struct FakeRun<'a> {
    pub panes: Mutex<Option<Vec<Value>>>,
    pub herdr: Option<&'a FakeHerdr>,
    pub core: Option<&'a FakeCore>,
    pub calls: Mutex<Vec<Vec<String>>>,
}

impl<'a> FakeRun<'a> {
    pub(crate) fn new(panes: Option<Vec<Value>>, herdr: Option<&'a FakeHerdr>) -> Self {
        Self {
            panes: Mutex::new(panes),
            herdr,
            core: None,
            calls: Mutex::default(),
        }
    }

    /// The same runner with herdr-core answered by `core`.
    pub(crate) fn with_core(mut self, core: &'a FakeCore) -> Self {
        self.core = Some(core);
        self
    }

    pub(crate) fn set_panes(&self, panes: Option<Vec<Value>>) {
        *self.panes.lock().unwrap() = panes;
    }

    pub(crate) fn run(&self, cmd: &str, args: &[&str], _env: &Env) -> RunResult {
        let tmux = cmd == "tmux";
        if tmux && args.first() != Some(&"-u") {
            return RunResult {
                stdout: String::new(),
                stderr: "tmux without -u".into(),
                code: 64,
            };
        }
        let args = if tmux { &args[1..] } else { args };
        let mut call = vec![cmd.to_string()];
        call.extend(args.iter().map(|arg| arg.to_string()));
        self.calls.lock().unwrap().push(call);
        if tmux {
            let panes = self.panes.lock().unwrap();
            return match (&*panes, args.first()) {
                (None, _) => RunResult {
                    stdout: String::new(),
                    stderr: "no server running on /tmp/tmux-stub/default".into(),
                    code: 1,
                },
                (Some(panes), Some(&"list-panes")) => {
                    let at = args.iter().position(|arg| *arg == "-F").unwrap();
                    ok_run(expand_panes(args[at + 1], panes))
                }
                _ => RunResult {
                    stdout: String::new(),
                    stderr: format!("unexpected {}", args.join(" ")),
                    code: 64,
                },
            };
        }
        if Path::new(cmd)
            .file_name()
            .is_some_and(|name| name == "herdr-core")
        {
            return match self.core {
                Some(core) => core.answer(args),
                None => RunResult {
                    stdout: String::new(),
                    stderr: format!("spawn {cmd} ENOENT"),
                    code: 127,
                },
            };
        }
        match self.herdr {
            Some(herdr) => herdr.answer(args),
            None => RunResult {
                stdout: String::new(),
                stderr: format!("spawn {cmd} ENOENT"),
                code: 127,
            },
        }
    }

    /// Whether any logged call has `cmd` as its program.
    pub(crate) fn called(&self, cmd: &str) -> bool {
        self.calls.lock().unwrap().iter().any(|call| call[0] == cmd)
    }

    /// Whether any logged call is to a program named `herdr-core`.
    pub(crate) fn called_core(&self) -> bool {
        self.calls.lock().unwrap().iter().any(|call| {
            Path::new(&call[0])
                .file_name()
                .is_some_and(|name| name == "herdr-core")
        })
    }
}

/// A request the relay saw: the URL, the headers the caller added, and the
/// body.
#[derive(Debug, Clone)]
pub(crate) struct Recorded {
    pub url: String,
    pub headers: Vec<(String, String)>,
    pub body: Value,
}

type Responder = Box<dyn Fn(&Value, usize) -> (u16, Value) + Send + Sync>;

/// The relay (`startFakeRelay`): records each request on arrival, then answers
/// `respond(body, index)` (default 200 `{apnsId: "x"}`). The responder may
/// block, to hold a response.
pub(crate) struct FakeRelay {
    pub requests: Mutex<Vec<Recorded>>,
    respond: Responder,
}

impl FakeRelay {
    pub(crate) fn ok() -> Self {
        Self::answering(|_, _| (200, json!({ "apnsId": "x" })))
    }

    pub(crate) fn answering(
        respond: impl Fn(&Value, usize) -> (u16, Value) + Send + Sync + 'static,
    ) -> Self {
        Self {
            requests: Mutex::default(),
            respond: Box::new(respond),
        }
    }

    pub(crate) fn bodies(&self) -> Vec<Value> {
        self.requests
            .lock()
            .unwrap()
            .iter()
            .map(|request| request.body.clone())
            .collect()
    }

    pub(crate) fn count(&self) -> usize {
        self.requests.lock().unwrap().len()
    }

    /// `[event, token]` of every request.
    pub(crate) fn sent(&self) -> Vec<(String, String)> {
        self.bodies()
            .iter()
            .map(|body| {
                (
                    body["event"].as_str().unwrap().to_string(),
                    body["token"].as_str().unwrap().to_string(),
                )
            })
            .collect()
    }
}

impl Fetch for FakeRelay {
    fn post_json(
        &self,
        url: &str,
        headers: &[(&str, &str)],
        body: &Value,
        _timeout: Duration,
    ) -> Result<Response> {
        let index = {
            let mut requests = self.requests.lock().unwrap();
            requests.push(Recorded {
                url: url.to_string(),
                headers: headers
                    .iter()
                    .map(|(name, value)| (name.to_string(), value.to_string()))
                    .collect(),
                body: body.clone(),
            });
            requests.len() - 1
        };
        let (status, body) = (self.respond)(body, index);
        Ok(Response {
            status,
            body: body.to_string(),
        })
    }
}

/// A clock that moves only when something sleeps (`fakeClock`), starting at
/// 1 000 000 ms; the sleeps are kept.
pub(crate) struct FakeClock {
    now: AtomicU64,
    pub sleeps: Mutex<Vec<u64>>,
}

impl FakeClock {
    pub(crate) fn new() -> Self {
        Self {
            now: AtomicU64::new(1_000_000),
            sleeps: Mutex::default(),
        }
    }
}

impl Clock for FakeClock {
    fn now_ms(&self) -> u64 {
        self.now.load(Ordering::SeqCst)
    }

    fn sleep(&self, duration: Duration) {
        let ms = u64::try_from(duration.as_millis()).unwrap();
        self.sleeps.lock().unwrap().push(ms);
        self.now.fetch_add(ms, Ordering::SeqCst);
    }
}

/// The plaintext of an update's envelope under `key` (`decryptEnvelope`).
pub(crate) fn open_envelope(body: &Value, key: &[u8]) -> Value {
    decrypt_activity_envelope(body["envelope"].as_str().unwrap(), key).unwrap()
}

/// `{pane: progress}` over an envelope's agents (`progressOf`); an agent
/// without progress maps to null.
pub(crate) fn progress_of(body: &Value) -> Value {
    let payload = open_envelope(body, &key_a());
    Value::Object(
        payload["agents"]
            .as_array()
            .unwrap()
            .iter()
            .map(|agent| {
                (
                    agent["pane"].as_str().unwrap().to_string(),
                    agent.get("progress").cloned().unwrap_or(Value::Null),
                )
            })
            .collect(),
    )
}
