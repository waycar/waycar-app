//! Test doubles for the notify flow: a clock on fake time, a recording relay
//! client, and (in tests) a fake host answering the tmux and herdr CLIs. The
//! tests and the parity harness (`parity_notify`) drive the real flow with
//! them, as the JS tests drive it with a fake relay server and stub binaries.

use std::cell::{Cell, RefCell};
use std::time::Duration;

use serde_json::Value;

use crate::deps::{Clock, Fetch};
use crate::error::Result;
use crate::http::Response;

/// A clock whose sleeps cost no time. A ticking clock moves forward by what
/// it sleeps; a frozen one stays at its start, as a test that stubs `Date.now`.
pub struct FakeClock {
    now: Cell<u64>,
    ticking: bool,
    sleeps: RefCell<Vec<Duration>>,
    on_sleep: RefCell<Option<Box<dyn FnMut()>>>,
}

impl FakeClock {
    pub fn ticking(now_ms: u64) -> Self {
        Self {
            now: Cell::new(now_ms),
            ticking: true,
            sleeps: RefCell::new(Vec::new()),
            on_sleep: RefCell::new(None),
        }
    }

    pub fn frozen(now_ms: u64) -> Self {
        Self {
            ticking: false,
            ..Self::ticking(now_ms)
        }
    }

    /// Run `action` at every sleep, before it returns: the world moving on
    /// while the flow holds (the JS tests' `setTimeout`).
    pub fn on_sleep(&self, action: impl FnMut() + 'static) {
        *self.on_sleep.borrow_mut() = Some(Box::new(action));
    }

    /// Every sleep so far, in order.
    pub fn sleeps(&self) -> Vec<Duration> {
        self.sleeps.borrow().clone()
    }

    pub fn advance(&self, ms: u64) {
        self.now.set(self.now.get() + ms);
    }
}

impl Clock for FakeClock {
    fn now_ms(&self) -> u64 {
        self.now.get()
    }

    fn sleep(&self, duration: Duration) {
        self.sleeps.borrow_mut().push(duration);
        if self.ticking {
            self.advance(duration.as_millis() as u64);
        }
        if let Some(action) = self.on_sleep.borrow_mut().as_mut() {
            action();
        }
    }
}

/// One request the relay client was asked to make.
#[derive(Debug, Clone, PartialEq)]
pub struct Posted {
    pub url: String,
    /// The extra headers the caller gave (the client adds `content-type`).
    pub headers: Vec<(String, String)>,
    pub body: Value,
}

/// What the relay answers request number `n` (from 0, over the client's life):
/// a status and body, or `Err` for a request that got no answer.
pub type Responder = Box<dyn Fn(&Posted, usize) -> Result<Response>>;

/// A relay client that records every request and answers from a script.
pub struct RecordingFetch {
    respond: Responder,
    posts: RefCell<Vec<Posted>>,
}

impl RecordingFetch {
    pub fn new(respond: impl Fn(&Posted, usize) -> Result<Response> + 'static) -> Self {
        Self {
            respond: Box::new(respond),
            posts: RefCell::new(Vec::new()),
        }
    }

    /// A relay that accepts everything (`200 {"apnsId":"x"}`).
    pub fn accepting() -> Self {
        Self::new(|_, _| Ok(answer(200, r#"{"apnsId":"x"}"#)))
    }

    pub fn posts(&self) -> Vec<Posted> {
        self.posts.borrow().clone()
    }
}

/// A relay answer.
pub fn answer(status: u16, body: &str) -> Response {
    Response {
        status,
        body: body.to_owned(),
    }
}

impl Fetch for RecordingFetch {
    fn post_json(
        &self,
        url: &str,
        headers: &[(&str, &str)],
        body: &Value,
        _timeout: Duration,
    ) -> Result<Response> {
        let posted = Posted {
            url: url.to_owned(),
            headers: headers
                .iter()
                .map(|(name, value)| ((*name).to_owned(), (*value).to_owned()))
                .collect(),
            body: body.clone(),
        };
        let index = self.posts.borrow().len();
        let reply = (self.respond)(&posted, index);
        self.posts.borrow_mut().push(posted);
        reply
    }
}

/// The plaintext and key id of a sealed notification envelope, as the app
/// opens it.
pub fn open_notification(envelope: &str, key: &[u8]) -> (String, String) {
    let plaintext = crate::seal::open(
        envelope,
        key,
        crate::notification_envelope::NOTIFICATION_AAD,
        "notification",
    )
    .expect("an envelope sealed for this key");
    let wire: Value = serde_json::from_str(envelope).expect("envelope JSON");
    (
        wire["kid"].as_str().unwrap_or_default().to_owned(),
        String::from_utf8(plaintext).expect("UTF-8 plaintext"),
    )
}

#[cfg(test)]
pub(crate) use host::{FakeHost, TmuxPane};

#[cfg(test)]
mod host {
    use std::cell::{Cell, RefCell};
    use std::collections::HashMap;

    use serde_json::{Value, json};

    use crate::env::Env;
    use crate::exec::{EXIT_NOT_STARTED, RunResult};

    /// A tmux pane as its format variables see it (the JS `tmuxPane`).
    #[derive(Clone)]
    pub(crate) struct TmuxPane {
        pub id: String,
        pub session: String,
        pub window: String,
        pub session_name: String,
        pub window_name: String,
        pub status: String,
        pub agent: String,
        pub command: String,
        pub title: String,
    }

    impl Default for TmuxPane {
        fn default() -> Self {
            Self {
                id: "%3".into(),
                session: "$1".into(),
                window: "@2".into(),
                session_name: "proj".into(),
                window_name: "fix-auth".into(),
                status: String::new(),
                agent: "claude".into(),
                command: "2.1.286".into(),
                title: "✳ Fix the auth bug".into(),
            }
        }
    }

    impl TmuxPane {
        pub(crate) fn with_status(status: &str) -> Self {
            Self {
                status: status.into(),
                ..Self::default()
            }
        }

        /// The pane's line of a `list-panes -F` listing, one record per pane
        /// in the field order the listing format asks for.
        fn render(&self) -> String {
            let fields = [
                self.id.as_str(),
                &self.session,
                &self.window,
                "0",
                "",
                "0",
                &self.status,
                &self.agent,
                "1727740800000000000",
                &self.command,
                &self.session_name,
                &self.window_name,
                "/home/u/proj",
                "",
                "",
                &self.title,
            ];
            format!("\u{241e}{}\n", fields.join("\u{241f}"))
        }
    }

    /// One program the flow ran.
    #[derive(Debug, Clone)]
    pub(crate) struct Call {
        pub cmd: String,
        /// The arguments (tmux's `-u` stripped).
        pub args: Vec<String>,
        pub env: Env,
    }

    /// The tmux and herdr CLIs the flow runs. herdr answers like the JS stub
    /// binary: a canned reply (stdout, exit code) per subcommand, found by the
    /// first two arguments (`agent list`), then the first (`agent`).
    pub(crate) struct FakeHost {
        /// `None`: no tmux server.
        pub panes: RefCell<Option<Vec<TmuxPane>>>,
        replies: RefCell<HashMap<String, (String, i32)>>,
        pub screen: RefCell<String>,
        /// The herdr-core terminals, each as `get --json` prints it.
        pub core_terminals: RefCell<Vec<Value>>,
        /// `Some(code)`: herdr-core answers every call but `--version` with
        /// that exit code.
        pub core_down: Cell<Option<i32>>,
        calls: RefCell<Vec<Call>>,
    }

    /// Whether `cmd` runs herdr-core, found at whatever path.
    fn is_core(cmd: &str) -> bool {
        cmd.rsplit('/').next() == Some("herdr-core")
    }

    impl FakeHost {
        pub(crate) fn new() -> Self {
            Self {
                panes: RefCell::new(None),
                replies: RefCell::new(HashMap::new()),
                screen: RefCell::new(String::new()),
                core_terminals: RefCell::new(Vec::new()),
                core_down: Cell::new(None),
                calls: RefCell::new(Vec::new()),
            }
        }

        pub(crate) fn reply(&self, subcommand: &str, stdout: impl Into<String>, code: i32) {
            self.replies
                .borrow_mut()
                .insert(subcommand.to_owned(), (stdout.into(), code));
        }

        /// The canned answer installed for `subcommand`: (stdout, exit code).
        pub(crate) fn replied(&self, subcommand: &str) -> (String, i32) {
            self.replies.borrow()[subcommand].clone()
        }

        /// `herdr agent list` answering `agents` (`None`: a failure).
        pub(crate) fn agent_list(&self, agents: Option<Value>) {
            match agents {
                Some(agents) => self.reply(
                    "agent list",
                    json!({"id": "cli:agent:list", "result": {"agents": agents, "type": "agent_list"}})
                        .to_string(),
                    0,
                ),
                None => self.reply(
                    "agent list",
                    json!({"error": {"code": "internal", "message": "list failed"}, "id": "x"})
                        .to_string(),
                    1,
                ),
            }
        }

        pub(crate) fn calls(&self) -> Vec<Call> {
            self.calls.borrow().clone()
        }

        /// Calls of `cmd` whose first argument is `subcommand` (any when `None`).
        pub(crate) fn calls_of(&self, cmd: &str, subcommand: Option<&str>) -> Vec<Call> {
            self.calls()
                .into_iter()
                .filter(|call| {
                    call.cmd == cmd
                        && subcommand
                            .is_none_or(|sub| call.args.first().map(String::as_str) == Some(sub))
                })
                .collect()
        }

        /// Calls of herdr-core (whatever path the flow found it at) whose first
        /// argument is `subcommand` (any when `None`).
        pub(crate) fn core_calls(&self, subcommand: Option<&str>) -> Vec<Call> {
            self.calls()
                .into_iter()
                .filter(|call| {
                    is_core(&call.cmd)
                        && subcommand
                            .is_none_or(|sub| call.args.first().map(String::as_str) == Some(sub))
                })
                .collect()
        }

        /// herdr-core as `hc 0.1.14` answers: `--version`, then `get <t> --json`
        /// (a missing terminal is `not_found` on stderr, exit 3), `ls --json` (the live
        /// terminals), `read <t>` (the shared screen) and `label <t> k=v...`.
        /// With `core_down` set every call but `--version` fails with its code.
        fn run_core(&self, args: &[&str]) -> RunResult {
            let reply = |code: i32, stdout: String, stderr: &str| RunResult {
                code,
                stdout,
                stderr: stderr.to_owned(),
            };
            if args == ["--version"] {
                return reply(0, "hc 0.1.14\n".to_owned(), "");
            }
            if let Some(code) = self.core_down.get() {
                return reply(code, String::new(), "hc: the core does not answer\n");
            }
            let mut terminals = self.core_terminals.borrow_mut();
            let position = |terminals: &[Value], address: &str| {
                terminals.iter().position(|t| t["address"] == address)
            };
            match args {
                ["get", address, "--json"] => match position(&terminals, address) {
                    Some(index) => reply(0, terminals[index].to_string(), ""),
                    None => reply(
                        3,
                        String::new(),
                        &json!({"error": {"kind": "not_found", "message": format!("no terminal {address:?}")}})
                            .to_string(),
                    ),
                },
                ["ls", "--json"] => {
                    let live: Vec<Value> = terminals
                        .iter()
                        .filter(|t| t["state"] == "live")
                        .map(|t| {
                            json!({
                                "address": t["address"],
                                "agent": t["status"]["app"],
                                "cwd": t["cwd"],
                                "name": t["name"],
                                "state": t["state"],
                                "status": t["status"]["state"],
                                "turn": t["turn"],
                            })
                        })
                        .collect();
                    reply(
                        0,
                        json!({"hidden_finished": 0, "terminals": live}).to_string(),
                        "",
                    )
                }
                ["read", address, ..] => match position(&terminals, address) {
                    Some(_) => reply(0, self.screen.borrow().clone(), ""),
                    None => reply(3, String::new(), "no such terminal"),
                },
                ["label", address, assignments @ ..] => match position(&terminals, address) {
                    Some(index) => {
                        let labels = &mut terminals[index]["labels"];
                        for assignment in assignments {
                            let (key, value) = assignment.split_once('=').unwrap_or((assignment, ""));
                            if value.is_empty() {
                                labels.as_object_mut().unwrap().remove(key);
                            } else {
                                labels[key] = json!(value);
                            }
                        }
                        reply(0, String::new(), "")
                    }
                    None => reply(3, String::new(), "no such terminal"),
                },
                _ => reply(64, String::new(), "stub: unexpected herdr-core command"),
            }
        }

        /// The runner the flow takes.
        pub(crate) fn run(&self, cmd: &str, raw_args: &[&str], env: &Env) -> RunResult {
            let reply = |code: i32, stdout: &str, stderr: &str| RunResult {
                code,
                stdout: stdout.to_owned(),
                stderr: stderr.to_owned(),
            };
            let args: &[&str] = if cmd == "tmux" {
                if raw_args.first() != Some(&"-u") {
                    return reply(64, "", "tmux without -u");
                }
                &raw_args[1..]
            } else {
                raw_args
            };
            self.calls.borrow_mut().push(Call {
                cmd: cmd.to_owned(),
                args: args.iter().map(|arg| (*arg).to_owned()).collect(),
                env: env.clone(),
            });
            if is_core(cmd) {
                return self.run_core(args);
            }
            if cmd == "tmux" {
                return match args.first().copied() {
                    Some("list-panes") => match self.panes.borrow().as_ref() {
                        None => reply(1, "", "no server running on /tmp/tmux-0/default\n"),
                        Some(panes) => {
                            // `-F #{pane_id}`: the ids alone; any other format is
                            // the agent listing's.
                            let ids_only = args
                                .windows(2)
                                .any(|w| w[0] == "-F" && w[1] == "#{pane_id}");
                            let listing: String = if ids_only {
                                panes.iter().map(|pane| format!("{}\n", pane.id)).collect()
                            } else {
                                panes.iter().map(TmuxPane::render).collect()
                            };
                            reply(0, &listing, "")
                        }
                    },
                    Some("capture-pane") => reply(0, &self.screen.borrow(), ""),
                    _ => reply(64, "", "stub: unexpected tmux command"),
                };
            }
            let two = args.iter().take(2).copied().collect::<Vec<_>>().join(" ");
            let replies = self.replies.borrow();
            let found = replies
                .get(&two)
                .or_else(|| args.first().and_then(|a| replies.get(*a)));
            match found {
                Some((stdout, code)) => reply(*code, stdout, ""),
                None => reply(EXIT_NOT_STARTED, "", &format!("{cmd}: command not found")),
            }
        }
    }
}

/// The rig the flow's tests share: a home with config and state directories, a
/// fake host, clock and relay, and fakes for the Agent Summaries and Chat Mode seams.
#[cfg(test)]
pub(crate) mod rig {
    use std::cell::{Cell, RefCell};
    use std::collections::VecDeque;
    use std::path::{Path, PathBuf};
    use std::rc::Rc;

    use serde_json::{Map, Value, json};

    use super::{FakeClock, FakeHost, RecordingFetch, open_notification};
    use crate::base64;
    use crate::chat::marker::{Marker, MarkerSession};
    use crate::deps::Fetch;
    use crate::env::Env;
    use crate::error::Result;
    use crate::exec::RunResult;
    use crate::http::Response;
    use crate::notify_core::{
        AgentSummaries, ChatMode, ChatRead, ChatTurn, Deps, MarkerGc, MarkerGcOutcome, MarkerProbe,
        ReplyRequest, Summary, SummaryRequest, run_core_notify, run_tmux_notify,
    };
    use crate::notify_hook::{NotifyOutcome, run_herdr_notify};
    use crate::test_support::TempDir;

    pub(crate) const DEBOUNCE_MS: u64 = 120;
    pub(crate) const RETRY_DELAY_MS: u64 = 10;
    pub(crate) const NOW_MS: u64 = 1_753_305_600_000;
    pub(crate) const TOKEN_A: &str =
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    pub(crate) const TOKEN_B: &str =
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    pub(crate) const TOKEN_C: &str =
        "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
    pub(crate) const PANE_ID: &str = "w1:p2";
    pub(crate) const TMUX_ENV: &str = "/tmp/tmux-501/default,4242,0";
    pub(crate) const RELAY_URL: &str = "http://relay.test";

    /// Two Notification Keys from the shared-vector fixtures (raw bytes 0..31
    /// and 255..224).
    pub(crate) fn key_a() -> Vec<u8> {
        (0..32).collect()
    }

    pub(crate) fn key_b() -> Vec<u8> {
        (0..32).map(|i| 255 - i).collect()
    }

    /// A registered device as the registration file lists it.
    pub(crate) struct Dev {
        pub token: &'static str,
        pub key: Vec<u8>,
        pub env: &'static str,
        pub notify: Value,
        pub extra: Vec<(&'static str, Value)>,
    }

    pub(crate) fn device() -> Dev {
        Dev {
            token: TOKEN_A,
            key: key_a(),
            env: "sandbox",
            notify: json!({"blocked": true, "done": true}),
            extra: Vec::new(),
        }
    }

    impl Dev {
        pub(crate) fn token(mut self, token: &'static str, key: Vec<u8>) -> Self {
            self.token = token;
            self.key = key;
            self
        }

        pub(crate) fn env(mut self, env: &'static str) -> Self {
            self.env = env;
            self
        }

        pub(crate) fn notify(mut self, notify: Value) -> Self {
            self.notify = notify;
            self
        }

        pub(crate) fn extra(mut self, name: &'static str, value: Value) -> Self {
            self.extra.push((name, value));
            self
        }

        pub(crate) fn json(&self) -> Value {
            let mut entry = Map::new();
            entry.insert("token".into(), json!(self.token));
            entry.insert("key".into(), json!(base64::encode_url(&self.key)));
            entry.insert("env".into(), json!(self.env));
            entry.insert("notify".into(), self.notify.clone());
            for (name, value) in &self.extra {
                entry.insert((*name).into(), value.clone());
            }
            Value::Object(entry)
        }
    }

    /// The herdr stub's canned answers (the JS `writeHerdrStub` options).
    pub(crate) struct HerdrStub {
        /// `None`: the agent is gone (`agent_not_found`).
        pub status: Option<&'static str>,
        pub agent: &'static str,
        pub title: Option<&'static str>,
        /// `None`: the workspace cannot be resolved.
        pub workspace_label: Option<&'static str>,
        pub agent_list: AgentList,
        pub screen: Option<&'static str>,
        pub agent_extra: Value,
    }

    pub(crate) enum AgentList {
        /// This pane with its status, alone.
        Auto,
        /// `herdr agent list` fails.
        Failing,
        Given(Value),
    }

    pub(crate) fn herdr_stub(status: &'static str) -> HerdrStub {
        HerdrStub {
            status: Some(status),
            agent: "claude",
            title: None,
            workspace_label: Some("Proj"),
            agent_list: AgentList::Auto,
            screen: None,
            agent_extra: json!({}),
        }
    }

    impl HerdrStub {
        pub(crate) fn agent(mut self, agent: &'static str) -> Self {
            self.agent = agent;
            self
        }

        pub(crate) fn title(mut self, title: &'static str) -> Self {
            self.title = Some(title);
            self
        }

        pub(crate) fn label(mut self, label: Option<&'static str>) -> Self {
            self.workspace_label = label;
            self
        }

        pub(crate) fn list(mut self, list: AgentList) -> Self {
            self.agent_list = list;
            self
        }

        pub(crate) fn extra(mut self, extra: Value) -> Self {
            self.agent_extra = extra;
            self
        }
    }

    /// Everything a summary request carried, as a test reads it back.
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub(crate) struct Requested {
        pub herdr_bin: String,
        pub pane_id: String,
        pub status: String,
        pub command: Option<Vec<String>>,
        pub timeout_ms: u64,
    }

    type Generate = Box<dyn FnMut(&Requested) -> Summary>;

    /// The summary generator of a test: answers from a script.
    pub(crate) struct FakeSummaries {
        generate: RefCell<Generate>,
        pub requests: RefCell<Vec<Requested>>,
    }

    impl FakeSummaries {
        fn none() -> Self {
            Self {
                generate: RefCell::new(Box::new(|_| Summary::default())),
                requests: RefCell::new(Vec::new()),
            }
        }

        pub(crate) fn answer(&self, generate: impl FnMut(&Requested) -> Summary + 'static) {
            *self.generate.borrow_mut() = Box::new(generate);
        }

        /// Always this summary text.
        pub(crate) fn says(&self, summary: &'static str) {
            self.answer(move |_| Summary {
                summary: Some(summary.to_owned()),
                hash: Some("hash".to_owned()),
            });
        }
    }

    impl AgentSummaries for FakeSummaries {
        fn generate(&self, request: &SummaryRequest<'_>) -> Summary {
            let requested = Requested {
                herdr_bin: request.herdr_bin.to_owned(),
                pane_id: request.pane_id.to_owned(),
                status: request.status.to_owned(),
                command: request.command.map(<[String]>::to_vec),
                timeout_ms: request.timeout_ms,
            };
            self.requests.borrow_mut().push(requested.clone());
            (self.generate.borrow_mut())(&requested)
        }
    }

    /// What a reply read asked for.
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub(crate) struct ReadAsked {
        pub kind: Option<String>,
        pub session: Option<MarkerSession>,
        pub cwd: Option<String>,
        pub launched_at: Option<String>,
    }

    /// What a marker collection asked for.
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub(crate) struct Collected {
        /// What herdr listed (empty when it was not asked).
        pub live_pane_ids: Vec<String>,
        /// Whether herdr's list was part of the request.
        pub herdr_asked: bool,
        pub live_tmux_pane_ids: Option<Vec<String>>,
        pub live_core_pane_ids: Option<Vec<String>>,
    }

    /// Chat Mode of a test: one marker, one turn, and a collection that
    /// records what it was asked.
    pub(crate) struct FakeChat {
        pub marker: RefCell<Option<Marker>>,
        pub turn: RefCell<std::result::Result<ChatTurn, String>>,
        pub reads: RefCell<Vec<ReadAsked>>,
        /// One answer per `gc_due` call; false once the script runs out.
        pub gc_due: RefCell<VecDeque<bool>>,
        pub has_markers: Cell<bool>,
        pub skipped: Cell<bool>,
        pub collected: RefCell<Vec<Collected>>,
    }

    impl FakeChat {
        fn none() -> Self {
            Self {
                marker: RefCell::new(None),
                turn: RefCell::new(Ok(ChatTurn {
                    read: ChatRead::Other,
                    turn_open: false,
                    last_reply: None,
                })),
                reads: RefCell::new(Vec::new()),
                gc_due: RefCell::new(VecDeque::new()),
                has_markers: Cell::new(false),
                skipped: Cell::new(false),
                collected: RefCell::new(Vec::new()),
            }
        }

        /// A finished turn whose final reply is `reply`.
        pub(crate) fn replies(&self, reply: &str) {
            *self.turn.borrow_mut() = Ok(ChatTurn {
                read: ChatRead::Ok,
                turn_open: false,
                last_reply: Some(reply.to_owned()),
            });
        }
    }

    pub(crate) fn marker() -> Marker {
        Marker {
            pane_id: PANE_ID.to_owned(),
            terminal_id: Some("term_chat1".to_owned()),
            kind: "claude".to_owned(),
            cwd: Some("/home/u/proj".to_owned()),
            session: Some(MarkerSession {
                kind: "path".to_owned(),
                value: "/home/u/chat.jsonl".to_owned(),
            }),
            launched_at: Some("2020-01-01T00:00:00Z".to_owned()),
            chat_mode: true,
        }
    }

    impl ChatMode for FakeChat {
        fn read_marker(&self, _config_dir: &Path, pane_id: &str) -> Option<Marker> {
            self.marker
                .borrow()
                .clone()
                .filter(|marker| marker.pane_id == pane_id)
        }

        // markerApplies of chat-marker.js, as the fake of a real marker store.
        fn marker_applies(&self, marker: &Marker, probe: &MarkerProbe<'_>) -> bool {
            if probe.kind != Some(marker.kind.as_str()) {
                return false;
            }
            match marker.terminal_id.as_deref() {
                None => return true,
                Some(terminal) if probe.terminal_id == Some(terminal) => return true,
                Some(_) => {}
            }
            match (marker.session.as_ref(), probe.agent_session) {
                (Some(recorded), Some(live)) => {
                    !recorded.value.is_empty()
                        && !live.value.is_empty()
                        && recorded.kind == live.kind
                        && recorded.value == live.value
                }
                _ => false,
            }
        }

        fn read_chat(&self, request: &ReplyRequest<'_>) -> std::result::Result<ChatTurn, String> {
            self.reads.borrow_mut().push(ReadAsked {
                kind: request.kind.map(str::to_owned),
                session: request.session.cloned(),
                cwd: request.cwd.map(str::to_owned),
                launched_at: request.launched_at.map(str::to_owned),
            });
            self.turn.borrow().clone()
        }

        fn gc_due(&self, _state_dir: &Path, _now_ms: u64) -> bool {
            self.gc_due.borrow_mut().pop_front().unwrap_or(false)
        }

        fn has_markers(&self, _config_dir: &Path) -> bool {
            self.has_markers.get()
        }

        fn collect_markers(
            &self,
            request: &MarkerGc<'_>,
        ) -> std::result::Result<MarkerGcOutcome, String> {
            self.collected.borrow_mut().push(Collected {
                live_pane_ids: request.live_pane_ids.clone().unwrap_or_default(),
                herdr_asked: request.live_pane_ids.is_some(),
                live_tmux_pane_ids: request.live_tmux_pane_ids.clone(),
                live_core_pane_ids: request.live_core_pane_ids.clone(),
            });
            Ok(MarkerGcOutcome {
                skipped_for_named_sessions: self.skipped.get(),
            })
        }
    }

    /// A live herdr-core terminal that reported OSC 7501 (`status`, `None`:
    /// never reported), as `get --json` prints it: a claude agent in
    /// `/home/u/proj` after `turn` turns.
    pub(crate) fn core_record(address: &str, status: Option<&str>, turn: u64) -> Value {
        json!({
            "address": address,
            "state": "live",
            "pid": 4242,
            "reported": status.is_some(),
            "status": status.map(|state| json!({"state": state, "app": "claude"})),
            "status_ms": 1_753_305_600_000u64,
            "turn": turn,
            "cwd": "/home/u/start",
            "foreground": {"pid": 4243, "name": "claude", "argv": ["claude"], "cwd": "/home/u/proj"},
            "labels": {},
            "name": "fix-auth",
            "title": "",
        })
    }

    type Runner = Box<dyn Fn(&str, &[&str], &Env) -> RunResult>;

    pub(crate) struct Rig {
        pub home: TempDir,
        pub config_dir: PathBuf,
        pub state_dir: PathBuf,
        pub host: Rc<FakeHost>,
        pub clock: Rc<FakeClock>,
        pub relay: Rc<RecordingFetch>,
        pub summaries: Rc<FakeSummaries>,
        pub chat: Rc<FakeChat>,
        run: Runner,
        herdr: bool,
        /// The listening socket of a running core (see `core_running`).
        listener: RefCell<Option<std::os::unix::net::UnixListener>>,
    }

    impl Rig {
        fn build(herdr: bool) -> Self {
            let home = TempDir::new("notify");
            let (config_dir, state_dir) = if herdr {
                (home.path().join("config"), home.path().join("state"))
            } else {
                // A tmux-only Host: no herdr plugin, so the Host's files live
                // under the XDG directories.
                (
                    home.path().join("xdg-config").join("waycar"),
                    home.path().join("xdg-state").join("waycar"),
                )
            };
            std::fs::create_dir_all(&config_dir).unwrap();
            std::fs::create_dir_all(&state_dir).unwrap();
            let host = Rc::new(FakeHost::new());
            let run: Runner = {
                let host = Rc::clone(&host);
                Box::new(move |cmd, args, env| host.run(cmd, args, env))
            };
            Self {
                home,
                config_dir,
                state_dir,
                host,
                clock: Rc::new(FakeClock::ticking(NOW_MS)),
                relay: Rc::new(RecordingFetch::accepting()),
                summaries: Rc::new(FakeSummaries::none()),
                chat: Rc::new(FakeChat::none()),
                run,
                herdr,
                listener: RefCell::new(None),
            }
        }

        /// The herdr hook's Host: the plugin's own config and state dirs.
        pub(crate) fn herdr() -> Self {
            Self::build(true)
        }

        pub(crate) fn tmux() -> Self {
            Self::build(false)
        }

        /// Answer the relay from a script.
        pub(crate) fn relay_answers(
            &mut self,
            respond: impl Fn(&super::Posted, usize) -> Result<Response> + 'static,
        ) {
            self.relay = Rc::new(RecordingFetch::new(respond));
        }

        pub(crate) fn path(&self, relative: &str) -> PathBuf {
            self.home.path().join(relative)
        }

        pub(crate) fn write_config(&self, overrides: Value) {
            let mut config = json!({
                "relay_url": RELAY_URL,
                "debounce_ms": DEBOUNCE_MS,
                "retry_delay_ms": RETRY_DELAY_MS,
                "summary_enabled": false,
            });
            for (name, value) in overrides.as_object().unwrap() {
                config[name] = value.clone();
            }
            std::fs::write(self.config_dir.join("notify.json"), config.to_string()).unwrap();
        }

        pub(crate) fn write_registration(&self, devices: &[Dev]) {
            self.write_registration_with(devices, json!({}));
        }

        pub(crate) fn write_registration_with(&self, devices: &[Dev], extra: Value) {
            let mut file =
                json!({"v": 1, "devices": devices.iter().map(Dev::json).collect::<Vec<_>>()});
            for (name, value) in extra.as_object().unwrap() {
                file[name] = value.clone();
            }
            std::fs::write(self.config_dir.join("notifications.json"), file.to_string()).unwrap();
        }

        pub(crate) fn read_registration(&self) -> Value {
            serde_json::from_slice(
                &std::fs::read(self.config_dir.join("notifications.json")).unwrap(),
            )
            .unwrap()
        }

        /// Install the herdr stub's canned answers (`writeHerdrStub`).
        pub(crate) fn herdr_answers(&self, stub: HerdrStub) {
            let host = &self.host;
            let mut info = json!({
                "agent": stub.agent,
                "agent_status": stub.status,
                "pane_id": PANE_ID,
                "workspace_id": "w1",
            });
            if let Some(title) = stub.title {
                info["terminal_title"] = json!(format!("⠂ {title}"));
                info["terminal_title_stripped"] = json!(title);
            }
            for (name, value) in stub.agent_extra.as_object().unwrap() {
                info[name] = value.clone();
            }
            match stub.status {
                None => host.reply(
                    "agent",
                    json!({"error": {"code": "agent_not_found", "message": "agent target not found"}, "id": "cli:agent:get"}).to_string(),
                    1,
                ),
                Some(_) => host.reply(
                    "agent",
                    json!({"id": "cli:agent:get", "result": {"agent": info, "type": "agent_info"}}).to_string(),
                    0,
                ),
            }
            match stub.agent_list {
                AgentList::Failing => host.agent_list(None),
                AgentList::Given(agents) => host.agent_list(Some(agents)),
                AgentList::Auto => host.agent_list(Some(match stub.status {
                    None => json!([]),
                    Some(status) => {
                        json!([{"pane_id": PANE_ID, "agent_status": status, "agent": stub.agent}])
                    }
                })),
            }
            match stub.workspace_label {
                None => host.reply(
                    "workspace",
                    json!({"error": {"code": "workspace_not_found", "message": "no such workspace"}, "id": "x"}).to_string(),
                    1,
                ),
                Some(label) => host.reply(
                    "workspace",
                    json!({"id": "cli:workspace:get", "result": {"workspace": {"workspace_id": "w1", "label": label}, "type": "workspace_info"}}).to_string(),
                    0,
                ),
            }
            if let Some(screen) = stub.screen {
                host.reply("pane read", screen, 0);
            }
        }

        fn deps(&self) -> Deps<'_> {
            Deps {
                fetch: &*self.relay as &dyn Fetch,
                clock: &*self.clock,
                run: &*self.run,
                summaries: &*self.summaries,
                chat: &*self.chat,
            }
        }

        /// The environment herdr injects into a hook.
        pub(crate) fn hook_env(&self, event: &str) -> Env {
            assert!(self.herdr);
            Env::from_pairs([
                ("PATH", "/usr/bin:/bin".to_owned()),
                // Named-session detection reads ~/.config/herdr/sessions.
                ("HOME", self.home.path().to_string_lossy().into_owned()),
                ("HERDR_PLUGIN_EVENT_JSON", event.to_owned()),
                (
                    "HERDR_PLUGIN_STATE_DIR",
                    self.state_dir.to_string_lossy().into_owned(),
                ),
                (
                    "HERDR_PLUGIN_CONFIG_DIR",
                    self.config_dir.to_string_lossy().into_owned(),
                ),
                (
                    "HERDR_BIN_PATH",
                    self.path("stub/herdr").to_string_lossy().into_owned(),
                ),
                (
                    "XDG_RUNTIME_DIR",
                    self.path("run").to_string_lossy().into_owned(),
                ),
            ])
        }

        pub(crate) fn hook_with(&self, env: &Env) -> NotifyOutcome {
            run_herdr_notify(env, &self.deps())
        }

        /// Run the herdr hook on `event`.
        pub(crate) fn hook(&self, event: &Value) -> NotifyOutcome {
            self.hook_with(&self.hook_env(&event.to_string()))
        }

        pub(crate) fn tmux_env(&self) -> Env {
            Env::from_pairs([
                ("HOME", self.home.path().to_string_lossy().into_owned()),
                ("PATH", "/usr/bin:/bin".to_owned()),
                ("TMUX", TMUX_ENV.to_owned()),
                (
                    "XDG_CONFIG_HOME",
                    self.path("xdg-config").to_string_lossy().into_owned(),
                ),
                (
                    "XDG_STATE_HOME",
                    self.path("xdg-state").to_string_lossy().into_owned(),
                ),
                (
                    "XDG_RUNTIME_DIR",
                    self.path("run").to_string_lossy().into_owned(),
                ),
            ])
        }

        /// Run the tmux trigger: the result and what it printed.
        pub(crate) fn notify(&self, pane_id: &str, status: &str) -> (Result<()>, String) {
            let mut stderr = String::new();
            let result = run_tmux_notify(
                pane_id,
                status,
                &self.tmux_env(),
                self.home.path(),
                &self.deps(),
                &mut stderr,
            );
            (result, stderr)
        }

        /// herdr-core's own CLI, installed where core's installer puts it
        /// (`~/.local/bin`, off the hook's PATH).
        pub(crate) fn install_core(&self) {
            let dir = self.path(".local/bin");
            std::fs::create_dir_all(&dir).unwrap();
            crate::test_support::write_stub(&dir.join("herdr-core"), "exit 0");
        }

        /// A core listening on the default socket under the hook's
        /// `XDG_RUNTIME_DIR`, as a tmux or herdr hook finds a running core.
        pub(crate) fn core_running(&self) {
            let dir = self.path("run/herdr-core");
            std::fs::create_dir_all(&dir).unwrap();
            let socket = dir.join("default.sock");
            let _ = std::fs::remove_file(&socket);
            let listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();
            *self.listener.borrow_mut() = Some(listener);
        }

        /// The core stopped: a file stays where its socket was, nothing
        /// listens. The socket is replaced rather than only closed: a child
        /// another test thread forks meanwhile holds a copy of the listening
        /// descriptor until it execs, and a connect in that window would
        /// still succeed.
        pub(crate) fn core_stopped(&self) {
            *self.listener.borrow_mut() = None;
            let socket = self.path("run/herdr-core/default.sock");
            let _ = std::fs::remove_file(&socket);
            std::fs::write(&socket, "").unwrap();
        }

        /// A core terminal's hook environment: the account's own, with the
        /// stale `TMUX`/`HERDR_*` a core started in a tmux pane hands down.
        pub(crate) fn core_env(&self) -> Env {
            let mut env = self.tmux_env();
            env.set("HC_TERMINAL_ID", "t1");
            env
        }

        /// Run the herdr-core trigger: the result and what it printed.
        pub(crate) fn notify_core(&self, pane_id: &str, status: &str) -> (Result<()>, String) {
            self.notify_core_with(&self.core_env(), pane_id, status)
        }

        pub(crate) fn notify_core_with(
            &self,
            env: &Env,
            pane_id: &str,
            status: &str,
        ) -> (Result<()>, String) {
            let mut stderr = String::new();
            let result = run_core_notify(
                pane_id,
                status,
                env,
                self.home.path(),
                &self.deps(),
                &mut stderr,
            );
            (result, stderr)
        }

        /// The envelope of request `index` opened with `key`: its key id and
        /// its payload.
        pub(crate) fn payload(&self, index: usize, key: &[u8]) -> (String, Value) {
            let posts = self.relay.posts();
            let envelope = posts[index].body["envelope"].as_str().expect("an envelope");
            let (kid, plaintext) = open_notification(envelope, key);
            (kid, serde_json::from_str(&plaintext).expect("payload JSON"))
        }

        /// The tokens of the posts so far, in order.
        pub(crate) fn tokens(&self) -> Vec<String> {
            self.relay
                .posts()
                .iter()
                .map(|post| post.body["token"].as_str().unwrap().to_owned())
                .collect()
        }

        pub(crate) fn stored_summary(&self, pane_id: &str) -> Option<Value> {
            let name = crate::atomic::pane_file_name(pane_id);
            let path = self.config_dir.join("summaries").join(name);
            std::fs::read(path)
                .ok()
                .map(|bytes| serde_json::from_slice(&bytes).unwrap())
        }
    }
}
