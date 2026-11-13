//! Tests of `activity_hook.rs`: the ports of test/activity-hook.test.js and the
//! activity parts of test/sidebar-hook.test.js, then the Rust-only tests.
//!
//! The JS runs the hook as a child process against a stub herdr and an HTTP
//! relay; here `run_herdr_activity` runs in-process against `FakeRun` (herdr
//! and tmux) and `FakeRelay`. Tests that only look at ordering run on
//! `FakeClock` (its sleeps cost nothing); tests that compare against the wall
//! clock, that run concurrent invocations, or that age real file mtimes use
//! `SystemClock`, with the JS tests' millisecond values.

use std::collections::HashMap;
use std::fs;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, mpsc};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

use super::*;
use crate::activity_fakes::*;
use crate::activity_start::{START_ALERT_BODY, START_ALERT_TITLE};
use crate::deps::{Clock, HttpFetch, SystemClock};
use crate::jsx;
use crate::sidebar_config::{refresh_sidebar_snapshot, system_now_ms};

const RELAY_URL: &str = "http://127.0.0.1:9";

// ---- the harness -------------------------------------------------------------

/// One Host's collaborators: `hook.herdr(event)` is `runHook`,
/// `hook.tmux(pane, status)` is `runTmuxActivity`.
struct Hook<'a, 'b> {
    sb: &'a Sandbox,
    run: &'a FakeRun<'b>,
    relay: &'a FakeRelay,
    clock: &'a dyn Clock,
}

fn noop_tick(_: &TickStart<'_>) {}

/// The environment herdr injects into a hook for `event`.
fn event_env(sb: &Sandbox, event: &str) -> Env {
    let mut env = sb.herdr_env();
    env.set("HERDR_PLUGIN_EVENT_JSON", event);
    env.set("HERDR_BIN_PATH", "herdr");
    env
}

impl Hook<'_, '_> {
    fn with_deps<R>(&self, f: impl FnOnce(&ActivityDeps<'_>) -> R) -> R {
        let runner = |cmd: &str, args: &[&str], env: &Env| self.run.run(cmd, args, env);
        f(&ActivityDeps {
            fetch: self.relay,
            clock: self.clock,
            run: &runner,
        })
    }

    /// `runHook`: the hook exits 0.
    fn herdr(&self, event: &str) {
        let env = event_env(self.sb, event);
        let outcome = self.with_deps(|deps| run_herdr_activity(&env, deps, &noop_tick));
        assert_eq!(outcome.code, 0, "{}", outcome.stderr);
    }

    fn tmux_in(
        &self,
        env: &Env,
        pane: &str,
        status: &str,
        start_tick: &dyn Fn(&TickStart<'_>),
    ) -> Result<()> {
        self.with_deps(|deps| {
            run_tmux_activity(pane, status, env, self.sb.home(), deps, start_tick)
        })
    }

    fn tmux(&self, pane: &str, status: &str) {
        self.tmux_in(&self.sb.herdr_env(), pane, status, &noop_tick)
            .unwrap();
    }

    fn core_in(
        &self,
        env: &Env,
        pane: &str,
        status: &str,
        start_tick: &dyn Fn(&TickStart<'_>),
    ) -> Result<()> {
        self.with_deps(|deps| {
            run_core_activity(pane, status, env, self.sb.home(), deps, start_tick)
        })
    }

    /// `run_core_activity` as an agent hook in a core terminal runs it.
    fn core(&self, env: &Env, pane: &str, status: &str) {
        self.core_in(env, pane, status, &noop_tick).unwrap();
    }
}

/// `sb`, `herdr`, `relay`, `run`, `hook` for one test over `agents`; the clock
/// is the caller's.
macro_rules! rig {
    ($sb:ident, $herdr:ident, $relay:ident, $run:ident, $hook:ident, $clock:ident; $relay_expr:expr; $agents:expr) => {
        let $sb = Sandbox::new("activity-hook");
        let $herdr = FakeHerdr::new($agents);
        let $relay = $relay_expr;
        let $run = FakeRun::new(None, Some(&$herdr));
        let $hook = Hook {
            sb: &$sb,
            run: &$run,
            relay: &$relay,
            clock: &$clock,
        };
    };
}

/// The ticks `startTick` was asked for: config dir, state dir, herdr required.
#[derive(Default)]
struct Ticks(Mutex<Vec<(PathBuf, PathBuf, bool)>>);

impl Ticks {
    fn record(&self, start: &TickStart<'_>) {
        self.0.lock().unwrap().push((
            start.config_dir.to_path_buf(),
            start.state_dir.to_path_buf(),
            start.herdr_required,
        ));
    }

    fn all(&self) -> Vec<(PathBuf, PathBuf, bool)> {
        self.0.lock().unwrap().clone()
    }
}

fn event(status: &str) -> String {
    status_event(status, PANE_ID)
}

fn counts(working: u32, blocked: u32, done: u32, idle: u32) -> Value {
    json!({ "working": working, "blocked": blocked, "done": done, "idle": idle })
}

fn pair(event: &str, token: &str) -> (String, String) {
    (event.to_string(), token.to_string())
}

fn by_token(bodies: &[Value]) -> HashMap<String, Value> {
    bodies
        .iter()
        .map(|body| (body["token"].as_str().unwrap().to_string(), body.clone()))
        .collect()
}

fn agent_panes(payload: &Value) -> Vec<&str> {
    payload["agents"]
        .as_array()
        .unwrap()
        .iter()
        .map(|agent| agent["pane"].as_str().unwrap())
        .collect()
}

fn with_cwd(mut agent: Value, cwd: &str) -> Value {
    agent["cwd"] = json!(cwd);
    agent
}

fn live(value: Value) -> DeviceSpec {
    DeviceSpec {
        live_activity: Some(value),
        ..DeviceSpec::default()
    }
}

/// The second device with the default `sandbox` env: `device({token: "b"…,
/// key: KEY_B, activityToken: ACTIVITY_TOKEN_B})`.
fn sandbox_second_device() -> Value {
    DeviceSpec {
        token: BLOCKED_TOKEN,
        key: key_b(),
        activity_token: ACTIVITY_TOKEN_B,
        ..DeviceSpec::default()
    }
    .build()
}

fn without_update_token(extra: Value) -> Value {
    DeviceSpec {
        live_activity: Some(Value::Null),
        extra,
        ..DeviceSpec::default()
    }
    .build()
}

fn with_extra(extra: Value) -> Value {
    DeviceSpec {
        extra,
        ..DeviceSpec::default()
    }
    .build()
}

fn set_mtime(path: &Path, at: SystemTime) {
    fs::OpenOptions::new()
        .write(true)
        .open(path)
        .unwrap()
        .set_modified(at)
        .unwrap();
}

fn names_in(dir: &Path) -> Vec<String> {
    let mut names: Vec<String> = fs::read_dir(dir)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().into_string().unwrap())
        .collect();
    names.sort();
    names
}

fn read_last(sb: &Sandbox) -> Value {
    sb.read_state_file("last-state.json")
}

/// Poll `condition` every 5 ms for up to 10 s (`until`).
fn until(condition: impl Fn() -> bool) {
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    while !condition() {
        assert!(std::time::Instant::now() < deadline, "condition never held");
        std::thread::sleep(Duration::from_millis(5));
    }
}

fn host_short_name() -> String {
    short_host_name(&os_hostname().unwrap())
}

fn startup_registration() -> Value {
    json!({ "token": START_TOKEN, "host_id": HOST_ID })
}

fn start_grace() -> Value {
    json!({ "activity_start_grace_ms": START_GRACE_MS })
}

// ---- activity-hook: cheap exits ------------------------------------------------

// JS: "no live_activity entries send zero requests"
#[test]
fn no_live_activity_entries_send_zero_requests() {
    let clock = FakeClock::new();
    rig!(sb, herdr, relay, run, hook, clock; FakeRelay::ok(); vec![default_agent()]);
    sb.write_config(Some(RELAY_URL), json!({}));
    sb.write_registration(
        &[DeviceSpec {
            live_activity: Some(Value::Null),
            ..DeviceSpec::default()
        }
        .build()],
        Value::Null,
    );

    hook.herdr(&event("working"));

    assert_eq!(relay.count(), 0);
    assert_eq!(herdr.invocation_args().len(), 0);
}

// JS: "ended last-state short-circuits non-eligible incoming statuses"
#[test]
fn ended_last_state_short_circuits_non_eligible_incoming_statuses() {
    let clock = FakeClock::new();
    rig!(sb, herdr, relay, run, hook, clock; FakeRelay::ok();
        vec![listed_agent(PANE_ID, "idle", None)]);
    sb.write_config(Some(RELAY_URL), json!({}));
    sb.write_registration(&[device()], Value::Null);
    sb.write_last_state(&json!({ "sent_at_ms": 1, "statuses": {}, "ended": true }));

    hook.herdr(&event("idle"));

    assert_eq!(relay.count(), 0);
    assert_eq!(herdr.invocation_args().len(), 0);
}

// ---- activity-hook: update and end ---------------------------------------------

// JS: "posts an update with an envelope decryptable under HERDR-ACTIVITY:1"
#[test]
fn posts_an_update_with_an_envelope_decryptable_under_herdr_activity_1() {
    let clock = SystemClock;
    rig!(sb, herdr, relay, run, hook, clock; FakeRelay::ok();
        vec![listed_agent(PANE_ID, "working", Some("实现锁屏显示 agent 工作状态"))]);
    sb.write_config(Some(RELAY_URL), json!({}));
    sb.write_registration(&[device(), second_device()], Value::Null);
    let before = SystemClock.now_ms() / 1000;

    hook.herdr(&event("working"));

    let bodies = relay.bodies();
    assert_eq!(bodies.len(), 2);
    for body in &bodies {
        assert_eq!(body["kind"], "liveactivity");
        assert_eq!(body["event"], "update");
        assert_eq!(body["priority"], 5);
        assert_eq!(
            body["stale_date"].as_u64().unwrap(),
            body["timestamp"].as_u64().unwrap() + 900
        );
        assert!(body.get("dismissal_date").is_none());
        assert!(body.get("collapse").is_none());
        assert_eq!(body["counts"], counts(1, 0, 0, 0));
        assert!(body["timestamp"].as_u64().unwrap() >= before);
    }
    for request in relay.requests.lock().unwrap().iter() {
        assert_eq!(request.url, format!("{RELAY_URL}/push"));
        assert!(request.headers.is_empty(), "the hook adds no headers");
    }
    let tokens = by_token(&bodies);
    assert_eq!(tokens[ACTIVITY_TOKEN_A]["env"], "sandbox");
    assert_eq!(tokens[ACTIVITY_TOKEN_B]["env"], "production");
    let opened = open_envelope(&tokens[ACTIVITY_TOKEN_A], &key_a());
    assert_eq!(opened["host"], host_short_name());
    assert_eq!(opened["v"], 1);
    let agents = opened["agents"].as_array().unwrap();
    assert_eq!(agents.len(), 1);
    assert_eq!(agents[0]["kind"], "claude");
    assert_eq!(agents[0]["pane"], PANE_ID);
    assert_eq!(agents[0]["status"], "working");
    assert_eq!(agents[0]["title"], "实现锁屏显示 agent 工作状态");
    assert_eq!(agents[0]["workspace"], "Waycar");
    open_envelope(&tokens[ACTIVITY_TOKEN_B], &key_b());
    assert_eq!(
        herdr.invocation_args(),
        vec![vec!["agent", "list"], vec!["workspace", "list"]]
    );
}

// JS: "pinned_pane_ids from each device reorder that device's envelope only"
#[test]
fn pinned_pane_ids_from_each_device_reorder_that_devices_envelope_only() {
    let clock = FakeClock::new();
    rig!(sb, herdr, relay, run, hook, clock; FakeRelay::ok(); vec![
        listed_agent("w1:p1", "blocked", Some("need input")),
        listed_agent("w1:p2", "working", Some("coding")),
    ]);
    sb.write_config(Some(RELAY_URL), json!({}));
    sb.write_registration(
        &[
            live(json!({
                "token": ACTIVITY_TOKEN_A,
                "started_at": "2026-01-01T00:00:00Z",
                "pinned_pane_ids": ["w1:p2"],
            }))
            .build(),
            second_device(),
        ],
        Value::Null,
    );

    hook.herdr(&status_event("working", "w1:p2"));

    let bodies = relay.bodies();
    assert_eq!(bodies.len(), 2);
    let tokens = by_token(&bodies);
    assert_eq!(tokens[ACTIVITY_TOKEN_A]["counts"], counts(1, 1, 0, 0));
    assert_eq!(tokens[ACTIVITY_TOKEN_B]["counts"], counts(1, 1, 0, 0));
    let pinned = open_envelope(&tokens[ACTIVITY_TOKEN_A], &key_a());
    let unpinned = open_envelope(&tokens[ACTIVITY_TOKEN_B], &key_b());
    assert_eq!(agent_panes(&pinned), ["w1:p2", "w1:p1"]);
    assert_eq!(agent_panes(&unpinned), ["w1:p1", "w1:p2"]);
}

// JS: "empty inventory sends end with dismissal_date and empty agents"
#[test]
fn empty_inventory_sends_end_with_dismissal_date_and_empty_agents() {
    let clock = FakeClock::new();
    rig!(sb, herdr, relay, run, hook, clock; FakeRelay::ok();
        vec![listed_agent(PANE_ID, "idle", None)]);
    sb.write_config(Some(RELAY_URL), json!({}));
    sb.write_registration(&[device()], Value::Null);

    hook.herdr(&event("idle"));

    let bodies = relay.bodies();
    assert_eq!(bodies.len(), 1);
    let body = &bodies[0];
    assert_eq!(body["event"], "end");
    assert_eq!(body["priority"], 5);
    assert_eq!(body["dismissal_date"], body["timestamp"]);
    assert!(body.get("stale_date").is_none());
    assert_eq!(body["counts"], counts(0, 0, 0, 0));
    let payload = open_envelope(body, &key_a());
    assert_eq!(payload["agents"], json!([]));
    assert_eq!(payload["host"], host_short_name());
}

// ---- activity-hook: priority and suppression -----------------------------------

// JS: "new blocked is priority 10, a repeat state sends nothing, a change without new blocked is 5"
#[test]
fn new_blocked_is_priority_10_a_repeat_state_sends_nothing_a_change_without_new_blocked_is_5() {
    let clock = FakeClock::new();
    rig!(sb, herdr, relay, run, hook, clock; FakeRelay::ok();
        vec![listed_agent(PANE_ID, "blocked", Some("need input"))]);
    sb.write_config(Some(RELAY_URL), json!({}));
    sb.write_registration(&[device()], Value::Null);

    hook.herdr(&event("blocked"));
    assert_eq!(relay.count(), 1);
    assert_eq!(relay.bodies()[0]["priority"], 10);
    assert_eq!(relay.bodies()[0]["event"], "update");

    hook.herdr(&event("blocked"));
    assert_eq!(relay.count(), 1);

    herdr.set_agents(vec![
        listed_agent(PANE_ID, "blocked", Some("need input")),
        listed_agent("w1:p3", "done", Some("landed")),
    ]);
    hook.herdr(&status_event("done", "w1:p3"));
    assert_eq!(relay.count(), 2);
    assert_eq!(relay.bodies()[1]["priority"], 5);
    assert_eq!(relay.bodies()[1]["counts"], counts(0, 1, 1, 0));
}

// JS: "an idle-only change pushes the idle chip at priority 5; an ended activity stays ended"
#[test]
fn an_idle_only_change_pushes_the_idle_chip_at_priority_5_an_ended_activity_stays_ended() {
    let clock = FakeClock::new();
    rig!(sb, herdr, relay, run, hook, clock; FakeRelay::ok();
        vec![listed_agent(PANE_ID, "working", Some("busy"))]);
    sb.write_config(Some(RELAY_URL), json!({}));
    sb.write_registration(&[device()], Value::Null);

    hook.herdr(&event("working"));
    assert_eq!(relay.count(), 1);

    herdr.set_agents(vec![
        listed_agent(PANE_ID, "working", Some("busy")),
        listed_agent("w1:p3", "idle", None),
    ]);
    hook.herdr(&status_event("idle", "w1:p3"));
    assert_eq!(relay.count(), 2);
    assert_eq!(relay.bodies()[1]["event"], "update");
    assert_eq!(relay.bodies()[1]["priority"], 5);
    assert_eq!(relay.bodies()[1]["counts"], counts(1, 0, 0, 1));

    hook.herdr(&status_event("idle", "w1:p3"));
    assert_eq!(relay.count(), 2);

    herdr.set_agents(vec![
        listed_agent(PANE_ID, "idle", None),
        listed_agent("w1:p3", "idle", None),
    ]);
    hook.herdr(&event("idle"));
    assert_eq!(relay.count(), 3);
    assert_eq!(relay.bodies()[2]["event"], "end");
    assert_eq!(relay.bodies()[2]["counts"], counts(0, 0, 0, 0));

    herdr.set_agents(vec![listed_agent(PANE_ID, "idle", None)]);
    hook.herdr(&status_event("idle", "w1:p3"));
    assert_eq!(relay.count(), 3);
}

// ---- activity-hook: debounce ---------------------------------------------------

// JS: "overlapping invocations produce one send"
#[test]
fn overlapping_invocations_produce_one_send() {
    let sb = Sandbox::new("activity-hook");
    let herdr = FakeHerdr::new(vec![default_agent()]);
    let relay = FakeRelay::ok();
    let run = FakeRun::new(None, Some(&herdr));
    sb.write_config(Some(RELAY_URL), json!({}));
    sb.write_registration(&[device()], Value::Null);

    // Both invocations share this process's pid, so the second claims 20 ms
    // later: the claims differ in time, as two hook processes' would.
    std::thread::scope(|scope| {
        let invoke = || {
            Hook {
                sb: &sb,
                run: &run,
                relay: &relay,
                clock: &SystemClock,
            }
            .herdr(&event("working"));
        };
        let first = scope.spawn(invoke);
        std::thread::sleep(Duration::from_millis(20));
        let second = scope.spawn(invoke);
        first.join().unwrap();
        second.join().unwrap();
    });

    assert_eq!(relay.count(), 1);
}

// JS: "an invocation that starts while another is sending does not send it again"
#[test]
fn an_invocation_that_starts_while_another_is_sending_does_not_send_it_again() {
    // The first run is held inside its send, after its debounce and before it
    // records last-state; the second is released into it only once it waits
    // on the send lock (its temp file exists only while it waits), so the
    // debounce cannot coalesce them and only the lock serializes them.
    let (arrived_tx, arrived_rx) = mpsc::channel::<()>();
    let (release_tx, release_rx) = mpsc::channel::<()>();
    let arrived_tx = Mutex::new(arrived_tx);
    let release_rx = Mutex::new(release_rx);
    let relay = FakeRelay::answering(move |_, index| {
        if index == 0 {
            arrived_tx.lock().unwrap().send(()).unwrap();
            release_rx
                .lock()
                .unwrap()
                .recv_timeout(Duration::from_secs(10))
                .unwrap();
        }
        (200, json!({ "apnsId": "x" }))
    });
    let sb = Sandbox::new("activity-hook");
    let herdr = FakeHerdr::new(vec![default_agent()]);
    let run = FakeRun::new(None, Some(&herdr));
    sb.write_config(Some(RELAY_URL), json!({}));
    sb.write_registration(&[device()], Value::Null);
    let invoke = || {
        Hook {
            sb: &sb,
            run: &run,
            relay: &relay,
            clock: &SystemClock,
        }
        .herdr(&event("working"));
    };

    std::thread::scope(|scope| {
        let first = scope.spawn(invoke);
        arrived_rx.recv_timeout(Duration::from_secs(10)).unwrap();
        let second = scope.spawn(invoke);
        until(|| {
            fs::read_dir(sb.activity_dir()).is_ok_and(|entries| {
                entries.flatten().any(|entry| {
                    entry
                        .file_name()
                        .to_string_lossy()
                        .starts_with("send.lock.tmp-")
                })
            })
        });
        release_tx.send(()).unwrap();
        first.join().unwrap();
        second.join().unwrap();
    });

    assert_eq!(relay.count(), 1);
    let left: Vec<String> = names_in(&sb.activity_dir())
        .into_iter()
        .filter(|name| name.starts_with("send.lock"))
        .collect();
    assert_eq!(left, Vec::<String>::new());
}

// JS: "a send lock left by a dead process is broken"
#[test]
fn a_send_lock_left_by_a_dead_process_is_broken() {
    let clock = FakeClock::new();
    rig!(sb, herdr, relay, run, hook, clock; FakeRelay::ok(); vec![default_agent()]);
    sb.write_config(Some(RELAY_URL), json!({}));
    sb.write_registration(&[device()], Value::Null);
    let mut dead = std::process::Command::new("true").spawn().unwrap();
    let pid = dead.id();
    dead.wait().unwrap();
    fs::create_dir_all(sb.activity_dir()).unwrap();
    fs::write(sb.activity_dir().join("send.lock"), pid.to_string()).unwrap();

    hook.herdr(&event("working"));

    assert_eq!(relay.count(), 1);
    assert!(!sb.activity_dir().join("send.lock").exists());
}

// JS: "a send lock older than any run is broken even when its PID is alive"
#[test]
fn a_send_lock_older_than_any_run_is_broken_even_when_its_pid_is_alive() {
    // PID 1 is always alive and another user's (EPERM): a reused PID after a
    // reboot looks exactly like this.
    let clock = SystemClock;
    rig!(sb, herdr, relay, run, hook, clock; FakeRelay::ok(); vec![default_agent()]);
    sb.write_config(Some(RELAY_URL), json!({}));
    sb.write_registration(&[device()], Value::Null);
    let lock = sb.activity_dir().join("send.lock");
    fs::create_dir_all(sb.activity_dir()).unwrap();
    fs::write(&lock, "1").unwrap();
    set_mtime(&lock, SystemTime::now() - Duration::from_secs(3600));

    hook.herdr(&event("working"));

    assert_eq!(relay.count(), 1);
    assert!(!lock.exists());
}

// JS: "waiting on a live, fresh send lock gives up at the deadline"
#[test]
fn waiting_on_a_live_fresh_send_lock_gives_up_at_the_deadline() {
    // On FakeClock `now` is nowhere near the lock's real mtime, so only the
    // live-holder check (PID 1) is in play: the lock is never judged stale.
    let sb = Sandbox::new("activity-hook");
    let lock = sb.activity_dir().join("send.lock");
    fs::create_dir_all(sb.activity_dir()).unwrap();
    fs::write(&lock, "1").unwrap();
    let mut ran = false;

    let error = with_send_lock(
        &sb.state_dir,
        &FakeClock::new(),
        LockLimits {
            stale_ms: SEND_LOCK_STALE_MS,
            timeout_ms: 150,
        },
        || {
            ran = true;
            Ok(())
        },
    )
    .unwrap_err();

    assert!(
        error
            .message()
            .starts_with("timed out after 150 ms waiting for the Live Activity send lock"),
        "{}",
        error.message()
    );
    assert!(!ran);
    assert_eq!(
        fs::read_to_string(&lock).unwrap(),
        "1",
        "a live holder's lock is left alone"
    );
    assert_eq!(names_in(&sb.activity_dir()), ["send.lock"]);
}

// JS: "a run whose lock was broken as stale leaves the next holder's lock alone"
#[test]
fn a_run_whose_lock_was_broken_as_stale_leaves_the_next_holders_lock_alone() {
    let sb = Sandbox::new("activity-hook");
    let lock = sb.activity_dir().join("send.lock");

    with_send_lock(
        &sb.state_dir,
        &SystemClock,
        LockLimits::default(),
        || -> Result<()> {
            // A waiter judged this run stale, broke its lock and took its own.
            fs::remove_file(&lock).unwrap();
            fs::write(&lock, "1").unwrap();
            Ok(())
        },
    )
    .unwrap();

    assert_eq!(fs::read_to_string(&lock).unwrap(), "1");
}

// ---- activity-hook: relay failures ---------------------------------------------

// JS: "a 410 Unregistered prunes only live_activity, preserving the rest of the entry"
#[test]
fn a_410_unregistered_prunes_only_live_activity_preserving_the_rest_of_the_entry() {
    let clock = FakeClock::new();
    rig!(sb, herdr, relay, run, hook, clock;
        FakeRelay::answering(|_, _| (410, json!({ "reason": "Unregistered" })));
        vec![default_agent()]);
    sb.write_config(Some(RELAY_URL), json!({}));
    sb.write_registration(
        &[
            with_extra(json!({ "future_entry_field": "kept" })),
            sandbox_second_device(),
        ],
        json!({ "future_top_field": "kept" }),
    );

    hook.herdr(&event("working"));

    assert_eq!(relay.count(), 2);
    let file = sb.read_registration();
    assert_eq!(file["v"], 1);
    assert_eq!(file["future_top_field"], "kept");
    let devices = file["devices"].as_array().unwrap();
    assert_eq!(devices.len(), 2);
    assert_eq!(devices[0]["token"], ALERT_TOKEN);
    assert_eq!(devices[0]["key"], base64::encode_url(&key_a()));
    assert_eq!(
        devices[0]["notify"],
        json!({ "blocked": true, "done": true })
    );
    assert_eq!(devices[0]["future_entry_field"], "kept");
    assert!(devices[0].get("live_activity").is_none());
    assert!(devices[1].get("live_activity").is_none());
}

// JS: "a relay-origin 413 resends without titles"
#[test]
fn a_relay_origin_413_resends_without_titles() {
    let clock = FakeClock::new();
    rig!(sb, herdr, relay, run, hook, clock;
        FakeRelay::answering(|_, index| if index == 0 {
            (413, json!({ "error": "payload_too_large" }))
        } else {
            (200, json!({ "apnsId": "x" }))
        });
        vec![listed_agent(PANE_ID, "working", Some("a long enough title to drop"))]);
    sb.write_config(Some(RELAY_URL), json!({}));
    sb.write_registration(&[device()], Value::Null);

    hook.herdr(&event("working"));

    let bodies = relay.bodies();
    assert_eq!(bodies.len(), 2);
    let first = open_envelope(&bodies[0], &key_a());
    let second = open_envelope(&bodies[1], &key_a());
    assert_eq!(first["agents"][0]["title"], "a long enough title to drop");
    assert!(second["agents"][0].get("title").is_none());
    assert_eq!(second["agents"][0]["workspace"], "Waycar");
    assert_eq!(second["agents"][0]["pane"], PANE_ID);
    assert_eq!(second["agents"][0]["status"], "working");
}

// ---- activity-hook: registered Agent List Fields -------------------------------

// JS: "devices render separate layouts and a preference change bypasses unchanged status suppression"
#[test]
fn devices_render_separate_layouts_and_a_preference_change_bypasses_unchanged_status_suppression() {
    let clock = FakeClock::new();
    rig!(sb, herdr, relay, run, hook, clock; FakeRelay::ok();
        vec![with_cwd(default_agent(), "/work/Waycar")]);
    sb.write_config(Some(RELAY_URL), json!({}));
    let mut layout = json!({
        "token": ACTIVITY_TOKEN_A,
        "host_name": "My Mac",
        "row_layout": { "rows": [[{ "token": "host" }], [{ "token": "directory", "dim": true }]] },
    });
    sb.write_registration(
        &[live(layout.clone()).build(), sandbox_second_device()],
        Value::Null,
    );

    hook.herdr(&event("working"));
    let bodies = relay.bodies();
    let first = open_envelope(&bodies[0], &key_a());
    assert_eq!(
        first["agents"][0]["rows"],
        json!([[{ "text": "My Mac" }], [{ "dim": true, "text": "/work/Waycar" }]])
    );
    assert!(
        open_envelope(&bodies[1], &key_b())["agents"][0]
            .get("rows")
            .is_none()
    );

    layout["row_layout"]["rows"] = json!([[{ "token": "agent" }]]);
    sb.write_registration(&[live(layout).build()], Value::Null);
    hook.herdr(&event("working"));
    assert_eq!(relay.count(), 3);
    assert_eq!(
        open_envelope(&relay.bodies()[2], &key_a())["agents"][0]["rows"],
        json!([[{ "text": "claude" }]])
    );
}

// JS: "fetches tab and pane context once per workspace for configured fields"
#[test]
fn fetches_tab_and_pane_context_once_per_workspace_for_configured_fields() {
    let clock = FakeClock::new();
    rig!(sb, herdr, relay, run, hook, clock; FakeRelay::ok(); vec![]);
    herdr.set(
        vec![{
            let mut agent = default_agent();
            agent["tab_id"] = json!("tab");
            agent
        }],
        vec![json!({ "workspace_id": "w1", "label": "Waycar" })],
        vec![json!({ "workspace_id": "w1", "tab_id": "tab", "label": "review" })],
        vec![json!({
            "workspace_id": "w1", "tab_id": "tab", "pane_id": PANE_ID, "label": "pane label",
        })],
    );
    sb.write_config(Some(RELAY_URL), json!({}));
    sb.write_registration(
        &[live(json!({
            "token": ACTIVITY_TOKEN_A,
            "row_layout": { "rows": [[{ "token": "tab" }, { "token": "pane" }]] },
        }))
        .build()],
        Value::Null,
    );

    hook.herdr(&event("working"));

    assert_eq!(
        open_envelope(&relay.bodies()[0], &key_a())["agents"][0]["rows"],
        json!([[{ "text": "review" }, { "text": " · " }, { "text": "pane label" }]])
    );
    let context: Vec<Vec<String>> = herdr
        .invocation_args()
        .into_iter()
        .filter(|args| args[0] == "tab" || args[0] == "pane")
        .collect();
    assert_eq!(
        context,
        vec![
            vec!["tab", "list", "--workspace", "w1"],
            vec!["pane", "list", "--workspace", "w1"],
        ]
    );
}

// JS: "payload degradation removes titles, then rows, then agents"
#[test]
fn payload_degradation_removes_titles_then_rows_then_agents() {
    let clock = FakeClock::new();
    rig!(sb, herdr, relay, run, hook, clock;
        FakeRelay::answering(|_, index| if index < 3 {
            (413, json!({ "error": "payload_too_large" }))
        } else {
            (200, json!({}))
        });
        vec![with_cwd(default_agent(), "/work/Waycar")]);
    sb.write_config(Some(RELAY_URL), json!({}));
    sb.write_registration(
        &[live(json!({
            "token": ACTIVITY_TOKEN_A,
            "row_layout": { "rows": [[{ "token": "directory" }]] },
        }))
        .build()],
        Value::Null,
    );

    hook.herdr(&event("working"));

    let bodies = relay.bodies();
    assert_eq!(bodies.len(), 4);
    let contents: Vec<Value> = bodies
        .iter()
        .map(|body| open_envelope(body, &key_a()))
        .collect();
    assert!(contents[0]["agents"][0]["title"].is_string());
    assert!(contents[1]["agents"][0].get("title").is_none());
    assert!(contents[1]["agents"][0]["rows"].is_array());
    assert!(contents[2]["agents"][0].get("rows").is_none());
    assert_eq!(contents[2]["agents"][0]["workspace"], "Waycar");
    assert_eq!(contents[3]["agents"], json!([]));
}

// ---- activity-hook: push-to-start ----------------------------------------------

// JS: "starts once per episode while no update token is registered"
#[test]
fn starts_once_per_episode_while_no_update_token_is_registered() {
    let clock = SystemClock;
    rig!(sb, herdr, relay, run, hook, clock; FakeRelay::ok(); vec![
        listed_agent(PANE_ID, "working", Some("secret task")),
        listed_agent("w1:p3", "idle", None),
    ]);
    sb.write_config(Some(RELAY_URL), start_grace());
    sb.write_registration(
        &[without_update_token(
            json!({ "live_activity_start": startup_registration() }),
        )],
        Value::Null,
    );
    let before = SystemClock.now_ms() / 1000;

    hook.herdr(&event("working"));

    assert_eq!(relay.count(), 1);
    let body = relay.bodies()[0].clone();
    assert_eq!(body["kind"], "liveactivity");
    assert_eq!(body["event"], "start");
    assert_eq!(body["token"], START_TOKEN);
    assert_eq!(body["env"], "sandbox");
    assert_eq!(body["priority"], 10);
    assert!(body["timestamp"].as_u64().unwrap() >= before);
    assert_eq!(
        body["stale_date"].as_u64().unwrap(),
        body["timestamp"].as_u64().unwrap() + 900
    );
    assert!(body.get("dismissal_date").is_none());
    assert_eq!(body["attributes_type"], "AgentActivityAttributes");
    assert_eq!(body["attributes"], json!({ "hostID": HOST_ID }));
    assert_eq!(
        body["alert"],
        json!({ "title": START_ALERT_TITLE, "body": START_ALERT_BODY })
    );
    assert_eq!(body["counts"], counts(1, 0, 0, 1));
    let mut cleartext = body.clone();
    cleartext.as_object_mut().unwrap().remove("envelope");
    assert!(!cleartext.to_string().contains("secret task"));
    assert_eq!(
        open_envelope(&body, &key_a())["agents"][0]["title"],
        "secret task"
    );

    herdr.set_agents(vec![listed_agent(PANE_ID, "blocked", Some("secret task"))]);
    hook.herdr(&event("blocked"));
    assert_eq!(relay.count(), 1, "one start per episode");

    herdr.set_agents(vec![listed_agent(PANE_ID, "idle", None)]);
    hook.herdr(&event("idle"));
    assert_eq!(relay.count(), 1, "no update token, so nothing to end");

    herdr.set_agents(vec![listed_agent(PANE_ID, "working", Some("again"))]);
    hook.herdr(&event("working"));
    assert_eq!(
        relay.sent(),
        [pair("start", START_TOKEN), pair("start", START_TOKEN)]
    );
}

// JS: "a device with a live update token gets updates, never a start"
#[test]
fn a_device_with_a_live_update_token_gets_updates_never_a_start() {
    let clock = FakeClock::new();
    rig!(sb, herdr, relay, run, hook, clock; FakeRelay::ok(); vec![default_agent()]);
    sb.write_config(Some(RELAY_URL), start_grace());
    sb.write_registration(
        &[with_extra(
            json!({ "live_activity_start": startup_registration() }),
        )],
        Value::Null,
    );

    hook.herdr(&event("working"));

    assert_eq!(relay.sent(), [pair("update", ACTIVITY_TOKEN_A)]);
    assert!(relay.bodies()[0].get("alert").is_none());
    assert!(relay.bodies()[0].get("attributes").is_none());
}

// JS: "after an end, the next episode starts a new activity; devices without a start token keep updating"
#[test]
fn after_an_end_the_next_episode_starts_a_new_activity_devices_without_a_start_token_keep_updating()
{
    let clock = FakeClock::new();
    rig!(sb, herdr, relay, run, hook, clock; FakeRelay::ok(); vec![default_agent()]);
    sb.write_config(Some(RELAY_URL), start_grace());
    sb.write_registration(
        &[
            with_extra(json!({ "live_activity_start": startup_registration() })),
            sandbox_second_device(),
        ],
        Value::Null,
    );

    hook.herdr(&event("working"));
    herdr.set_agents(vec![listed_agent(PANE_ID, "idle", None)]);
    hook.herdr(&event("idle"));
    herdr.set_agents(vec![listed_agent(PANE_ID, "done", Some("landed"))]);
    hook.herdr(&event("done"));

    let sent = relay.sent();
    let mut first_four = sent[..4].to_vec();
    first_four.sort();
    assert_eq!(
        first_four,
        [
            pair("end", ACTIVITY_TOKEN_A),
            pair("end", ACTIVITY_TOKEN_B),
            pair("update", ACTIVITY_TOKEN_A),
            pair("update", ACTIVITY_TOKEN_B),
        ]
    );
    assert_eq!(
        sent[4..],
        [pair("update", ACTIVITY_TOKEN_B), pair("start", START_TOKEN)]
    );
    assert_eq!(relay.bodies()[5]["counts"], counts(0, 0, 1, 0));
}

// JS: "an update token the app registers during the start grace wins over a start"
#[test]
fn an_update_token_the_app_registers_during_the_start_grace_wins_over_a_start() {
    let clock = FakeClock::new();
    rig!(sb, herdr, relay, run, hook, clock; FakeRelay::ok(); vec![default_agent()]);
    sb.write_config(Some(RELAY_URL), start_grace());
    sb.write_registration(
        &[without_update_token(
            json!({ "live_activity_start": startup_registration() }),
        )],
        Value::Null,
    );
    let parked = sb.home().join("registration-after-list.json");
    fs::write(
        &parked,
        json!({
            "v": 1,
            "devices": [with_extra(json!({ "live_activity_start": startup_registration() }))],
        })
        .to_string(),
    )
    .unwrap();
    herdr.register_after_list(parked, sb.config_dir.join("notifications.json"));

    hook.herdr(&event("working"));
    assert_eq!(relay.count(), 0);

    hook.herdr(&event("working"));
    assert_eq!(relay.sent(), [pair("update", ACTIVITY_TOKEN_A)]);
}

// JS: "a 410 on the start token prunes only live_activity_start"
#[test]
fn a_410_on_the_start_token_prunes_only_live_activity_start() {
    let clock = FakeClock::new();
    rig!(sb, herdr, relay, run, hook, clock;
        FakeRelay::answering(|_, _| (410, json!({ "reason": "Unregistered" })));
        vec![default_agent()]);
    sb.write_config(Some(RELAY_URL), start_grace());
    sb.write_registration(
        &[with_extra(json!({
            "live_activity_start": startup_registration(),
            "future_entry_field": "kept",
        }))],
        json!({ "future_top_field": "kept" }),
    );
    // The registered update token belongs to an activity this plugin ended.
    sb.write_state_file(
        "start-state.json",
        &json!({ "ended_tokens": [ACTIVITY_TOKEN_A], "started": {} }),
    );

    hook.herdr(&event("working"));

    assert_eq!(relay.sent(), [pair("start", START_TOKEN)]);
    let file = sb.read_registration();
    assert_eq!(file["future_top_field"], "kept");
    let entry = &file["devices"][0];
    assert!(entry.get("live_activity_start").is_none());
    assert_eq!(entry["live_activity"]["token"], ACTIVITY_TOKEN_A);
    assert_eq!(entry["token"], ALERT_TOKEN);
    assert_eq!(entry["key"], base64::encode_url(&key_a()));
    assert_eq!(entry["notify"], json!({ "blocked": true, "done": true }));
    assert_eq!(entry["future_entry_field"], "kept");
}

// JS: "an activity dismissed mid-episode is not started again until the episode ends"
#[test]
fn an_activity_dismissed_mid_episode_is_not_started_again_until_the_episode_ends() {
    let clock = FakeClock::new();
    rig!(sb, herdr, relay, run, hook, clock;
        FakeRelay::answering(|body, _| if body["event"] == "update" {
            (410, json!({ "reason": "Unregistered" }))
        } else {
            (200, json!({ "apnsId": "x" }))
        });
        vec![default_agent()]);
    sb.write_config(Some(RELAY_URL), start_grace());
    sb.write_registration(
        &[with_extra(
            json!({ "live_activity_start": startup_registration() }),
        )],
        Value::Null,
    );

    hook.herdr(&event("working"));
    assert!(
        sb.read_registration()["devices"][0]
            .get("live_activity")
            .is_none()
    );
    assert_eq!(
        sb.read_registration()["devices"][0]["live_activity_start"],
        startup_registration()
    );
    herdr.set_agents(vec![listed_agent(PANE_ID, "blocked", Some("need input"))]);
    hook.herdr(&event("blocked"));
    assert_eq!(relay.sent(), [pair("update", ACTIVITY_TOKEN_A)]);

    herdr.set_agents(vec![listed_agent(PANE_ID, "idle", None)]);
    hook.herdr(&event("idle"));
    herdr.set_agents(vec![default_agent()]);
    hook.herdr(&event("working"));
    assert_eq!(
        relay.sent(),
        [pair("update", ACTIVITY_TOKEN_A), pair("start", START_TOKEN)]
    );
}

#[test]
fn the_start_state_records_a_dismissal_by_device_an_end_by_token_and_an_episode_end_resets_starts()
{
    let clock = FakeClock::new();
    rig!(sb, herdr, relay, run, hook, clock;
        FakeRelay::answering(|body, _| if body["event"] == "update" {
            (410, json!({ "reason": "Unregistered" }))
        } else {
            (200, json!({ "apnsId": "x" }))
        });
        vec![default_agent()]);
    sb.write_config(Some(RELAY_URL), start_grace());
    sb.write_registration(
        &[with_extra(
            json!({ "live_activity_start": startup_registration() }),
        )],
        Value::Null,
    );
    hook.herdr(&event("working"));
    // Dismissed mid-episode: the device is marked started, keyed by its
    // alert token, and no token is marked ended.
    let state = sb.read_state_file("start-state.json");
    assert_eq!(state["ended_tokens"], json!([]));
    assert_eq!(
        state["started"]
            .as_object()
            .unwrap()
            .keys()
            .collect::<Vec<_>>(),
        [ALERT_TOKEN]
    );
    // The inventory empties: the episode ends and its guards reset.
    herdr.set_agents(vec![]);
    hook.herdr(&event("idle"));
    assert_eq!(
        sb.read_state_file("start-state.json"),
        json!({ "ended_tokens": [], "started": {} })
    );
}

#[test]
fn a_delivered_end_marks_its_update_token_ended_so_the_next_episode_starts_instead() {
    let clock = FakeClock::new();
    rig!(sb, herdr, relay, run, hook, clock; FakeRelay::ok(); vec![default_agent()]);
    sb.write_config(Some(RELAY_URL), start_grace());
    sb.write_registration(
        &[with_extra(
            json!({ "live_activity_start": startup_registration() }),
        )],
        Value::Null,
    );
    hook.herdr(&event("working"));
    herdr.set_agents(vec![]);
    hook.herdr(&event("idle"));
    assert_eq!(
        sb.read_state_file("start-state.json")["ended_tokens"],
        json!([ACTIVITY_TOKEN_A])
    );
    herdr.set_agents(vec![default_agent()]);
    hook.herdr(&event("working"));
    assert_eq!(
        relay.sent(),
        [
            pair("update", ACTIVITY_TOKEN_A),
            pair("end", ACTIVITY_TOKEN_A),
            pair("start", START_TOKEN)
        ]
    );
    let state = sb.read_state_file("start-state.json");
    assert_eq!(
        state["started"]
            .as_object()
            .unwrap()
            .keys()
            .collect::<Vec<_>>(),
        [ALERT_TOKEN]
    );
}

// ---- activity-hook: tmux Agents ------------------------------------------------

// JS: "the herdr hook counts and lists herdr and tmux Agents together, and a pin matches a tmux id"
#[test]
fn the_herdr_hook_counts_and_lists_herdr_and_tmux_agents_together_and_a_pin_matches_a_tmux_id() {
    let clock = FakeClock::new();
    rig!(sb, herdr, relay, run, hook, clock; FakeRelay::ok();
        vec![listed_agent(PANE_ID, "blocked", Some("need input"))]);
    sb.write_config(Some(RELAY_URL), json!({}));
    sb.write_registration(
        &[live(json!({ "token": ACTIVITY_TOKEN_A, "pinned_pane_ids": ["tmux:%7"] })).build()],
        Value::Null,
    );
    let mut idle = tmux_pane("%8", "idle");
    idle["window_id"] = json!("@3");
    // Waycar's own attach session lists the same pane again; it never counts twice.
    let mut attach = tmux_pane("%7", "working");
    attach["session_id"] = json!("$9");
    attach["session_name"] = json!("waycar-1");
    run.set_panes(Some(vec![tmux_pane("%7", "working"), idle, attach]));

    hook.herdr(&event("blocked"));

    let bodies = relay.bodies();
    assert_eq!(bodies.len(), 1);
    assert_eq!(bodies[0]["priority"], 10);
    assert_eq!(bodies[0]["counts"], counts(1, 1, 0, 1));
    let payload = open_envelope(&bodies[0], &key_a());
    let rows: Vec<(&str, &str)> = payload["agents"]
        .as_array()
        .unwrap()
        .iter()
        .map(|agent| {
            (
                agent["pane"].as_str().unwrap(),
                agent["status"].as_str().unwrap(),
            )
        })
        .collect();
    assert_eq!(rows, [("tmux:%7", "working"), (PANE_ID, "blocked")]);
    assert_eq!(payload["agents"][0]["kind"], "claude");
    assert_eq!(payload["agents"][0]["workspace"], "dev");
    assert_eq!(payload["agents"][0]["title"], "Fix flaky test");
    assert_eq!(payload["agents"][1]["workspace"], "Waycar");
    // herdr is asked only about its own Agents.
    assert_eq!(
        herdr.invocation_args(),
        vec![vec!["agent", "list"], vec!["workspace", "list"]]
    );
    let last = read_last(&sb);
    assert_eq!(
        last["statuses"],
        json!({ PANE_ID: "blocked", "tmux:%7": "working" })
    );
    assert_eq!(last["idle"], 1);
}

// JS: "tmux_enabled false leaves tmux Agents out of the herdr hook's content"
#[test]
fn tmux_enabled_false_leaves_tmux_agents_out_of_the_herdr_hooks_content() {
    let clock = FakeClock::new();
    rig!(sb, herdr, relay, run, hook, clock; FakeRelay::ok();
        vec![listed_agent(PANE_ID, "blocked", Some("need input"))]);
    sb.write_config(Some(RELAY_URL), json!({ "tmux_enabled": false }));
    sb.write_registration(&[device()], Value::Null);
    run.set_panes(Some(vec![
        tmux_pane("%7", "working"),
        tmux_pane("%8", "idle"),
    ]));

    hook.herdr(&event("blocked"));

    assert_eq!(relay.bodies()[0]["counts"], counts(0, 1, 0, 0));
    let payload = open_envelope(&relay.bodies()[0], &key_a());
    assert_eq!(agent_panes(&payload), [PANE_ID]);
}

// JS: "the tmux trigger on a tmux-only Host pushes from the Host's own config and state dirs"
#[test]
fn the_tmux_trigger_on_a_tmux_only_host_pushes_from_the_hosts_own_config_and_state_dirs() {
    let clock = FakeClock::new();
    let mut sb = Sandbox::new("activity-hook");
    let xdg_config = sb.home().join("xdg-config");
    let xdg_state = sb.home().join("xdg-state");
    sb.config_dir = xdg_config.join("waycar");
    sb.state_dir = xdg_state.join("waycar");
    fs::create_dir_all(&sb.config_dir).unwrap();
    let relay = FakeRelay::ok();
    sb.write_config(Some(RELAY_URL), json!({}));
    sb.write_registration(&[device()], Value::Null);
    let mut pane = tmux_pane("%7", "blocked");
    pane["pane_title"] = json!(os_hostname().unwrap());
    let run = FakeRun::new(Some(vec![pane]), None);
    let hook = Hook {
        sb: &sb,
        run: &run,
        relay: &relay,
        clock: &clock,
    };
    let env = Env::from_pairs([
        ("PATH", "/usr/bin:/bin"),
        ("HOME", sb.home().to_str().unwrap()),
        ("XDG_CONFIG_HOME", xdg_config.to_str().unwrap()),
        ("XDG_STATE_HOME", xdg_state.to_str().unwrap()),
    ]);

    hook.tmux_in(&env, "tmux:%7", "blocked", &noop_tick)
        .unwrap();

    let bodies = relay.bodies();
    assert_eq!(bodies.len(), 1);
    assert_eq!(bodies[0]["event"], "update");
    assert_eq!(bodies[0]["priority"], 10);
    assert_eq!(bodies[0]["counts"], counts(0, 1, 0, 0));
    let payload = open_envelope(&bodies[0], &key_a());
    assert_eq!(payload["host"], host_short_name());
    assert_eq!(payload["agents"].as_array().unwrap().len(), 1);
    assert_eq!(payload["agents"][0]["pane"], "tmux:%7");
    assert_eq!(payload["agents"][0]["workspace"], "dev");
    // tmux's default pane title is the hostname, which says nothing about the work.
    assert!(payload["agents"][0].get("title").is_none());
    // A missing herdr is no herdr Agents, never a failed run or a label lookup.
    let calls = run.calls.lock().unwrap().clone();
    assert!(
        calls
            .iter()
            .any(|call| call.get(1).map(String::as_str) == Some("agent")
                && call.get(2).map(String::as_str) == Some("list"))
    );
    assert!(
        !calls
            .iter()
            .any(|call| call.get(1).map(String::as_str) == Some("workspace"))
    );
    assert_eq!(
        read_json(&xdg_state.join("waycar/activity/last-state.json"))["statuses"],
        json!({ "tmux:%7": "blocked" })
    );
}

// JS: "the tmux trigger sends nothing when the Host turned tmux off"
#[test]
fn the_tmux_trigger_sends_nothing_when_the_host_turned_tmux_off() {
    let clock = FakeClock::new();
    let sb = Sandbox::new("activity-hook");
    let relay = FakeRelay::ok();
    sb.write_config(Some(RELAY_URL), json!({ "tmux_enabled": false }));
    sb.write_registration(&[device()], Value::Null);
    let run = FakeRun::new(Some(vec![tmux_pane("%7", "blocked")]), None);
    let hook = Hook {
        sb: &sb,
        run: &run,
        relay: &relay,
        clock: &clock,
    };

    hook.tmux("tmux:%7", "blocked");

    assert_eq!(relay.count(), 0);
    assert!(!run.called("tmux"));
}

// JS: "both triggers share one episode: the tmux trigger after the herdr hook sends no duplicate"
#[test]
fn both_triggers_share_one_episode_the_tmux_trigger_after_the_herdr_hook_sends_no_duplicate() {
    let clock = FakeClock::new();
    rig!(sb, herdr, relay, run, hook, clock; FakeRelay::ok(); vec![default_agent()]);
    sb.write_config(Some(RELAY_URL), json!({}));
    sb.write_registration(&[device()], Value::Null);
    run.set_panes(Some(vec![tmux_pane("%7", "blocked")]));
    hook.herdr(&event("working"));
    assert_eq!(relay.count(), 1);
    assert_eq!(relay.bodies()[0]["counts"], counts(1, 1, 0, 0));

    hook.tmux("tmux:%7", "blocked");
    assert_eq!(
        relay.count(),
        1,
        "unchanged statuses are suppressed across triggers"
    );

    run.set_panes(Some(vec![tmux_pane("%7", "done")]));
    hook.tmux("tmux:%7", "done");
    assert_eq!(relay.count(), 2);
    assert_eq!(relay.bodies()[1]["counts"], counts(1, 0, 1, 0));
    let payload = open_envelope(&relay.bodies()[1], &key_a());
    assert_eq!(agent_panes(&payload), ["tmux:%7", PANE_ID]);
    assert_eq!(payload["agents"][1]["workspace"], "Waycar");
}

// ---- activity-hook: herdr-core Agents ------------------------------------------

/// Core's terminals for the tests: `t1` Working (title from the terminal), `t2`
/// in error with the hook's own kind label, `t3` idle, `t4` that never
/// reported, `t5` finished.
fn core_terminals() -> Vec<Value> {
    vec![
        core_record(
            "t1",
            Some("working"),
            json!({ "title": "⠂ Fix flaky test", "turn": 2 }),
        ),
        core_record(
            "t2",
            Some("error"),
            json!({ "labels": { "waycar.kind": "codex" }, "name": "ci" }),
        ),
        core_record("t3", Some("idle"), json!({})),
        core_record("t4", None, json!({})),
        core_record("t5", None, json!({ "state": "finished" })),
    ]
}

fn core_event_env(env: &Env, event: &str) -> Env {
    let mut env = env.clone();
    env.set("HERDR_PLUGIN_EVENT_JSON", event);
    env.set("HERDR_BIN_PATH", "herdr");
    env
}

fn herdr_trigger(hook: &Hook<'_, '_>, env: &Env) {
    let outcome = hook.with_deps(|deps| run_herdr_activity(env, deps, &noop_tick));
    assert_eq!(outcome.code, 0, "{}", outcome.stderr);
}

fn args_of(args: &[&str]) -> Vec<String> {
    args.iter().map(|arg| arg.to_string()).collect()
}

#[test]
fn the_core_trigger_on_a_core_only_host_pushes_status_kind_name_and_title_of_the_terminals_that_reported()
 {
    let clock = FakeClock::new();
    let sb = Sandbox::new("activity-hook");
    let relay = FakeRelay::ok();
    sb.write_config(Some(RELAY_URL), json!({}));
    sb.write_registration(&[device()], Value::Null);
    let core = FakeCore::new(core_terminals());
    let run = FakeRun::new(None, None).with_core(&core);
    let hook = Hook {
        sb: &sb,
        run: &run,
        relay: &relay,
        clock: &clock,
    };
    let (_listener, env) = sb.core_env();

    hook.core(&env, "hc:t1", "working");

    let bodies = relay.bodies();
    assert_eq!(bodies.len(), 1);
    assert_eq!(bodies[0]["event"], "update");
    // The error is Blocked, so a new blocked Agent is a priority 10 push.
    assert_eq!(bodies[0]["priority"], 10);
    assert_eq!(bodies[0]["counts"], counts(1, 1, 0, 1));
    let payload = open_envelope(&bodies[0], &key_a());
    assert_eq!(
        payload["agents"],
        json!([
            { "kind": "codex", "name": "ci", "pane": "hc:t2", "status": "blocked" },
            { "kind": "claude", "name": "t1-name", "pane": "hc:t1", "status": "working",
              "title": "Fix flaky test" },
        ])
    );
    assert_eq!(
        read_last(&sb)["statuses"],
        json!({ "hc:t1": "working", "hc:t2": "blocked" })
    );
    assert_eq!(read_last(&sb)["idle"], 1);
    // core is listed once; only the terminals an envelope can show are fetched.
    assert_eq!(
        core.invocation_args(),
        [
            args_of(&["--version"]),
            args_of(&["ls", "--json"]),
            args_of(&["get", "t1", "--json"]),
            args_of(&["get", "t2", "--json"]),
        ]
    );
    // The same Agents again change nothing, so nothing is pushed.
    hook.core(&env, "hc:t1", "working");
    assert_eq!(relay.count(), 1);
}

#[test]
fn a_core_terminal_that_is_gone_when_asked_for_is_no_row_and_one_core_cannot_describe_keeps_its_listing_line()
 {
    let clock = FakeClock::new();
    let sb = Sandbox::new("activity-hook");
    let relay = FakeRelay::ok();
    sb.write_config(Some(RELAY_URL), json!({}));
    sb.write_registration(&[device()], Value::Null);
    let working = core_record("t1", Some("working"), json!({}));
    let mut finished = working.clone();
    finished["state"] = json!("finished");
    let core = FakeCore::new(vec![finished]);
    core.set_listed(vec![working.clone()]);
    let run = FakeRun::new(None, None).with_core(&core);
    let hook = Hook {
        sb: &sb,
        run: &run,
        relay: &relay,
        clock: &clock,
    };
    let (_listener, env) = sb.core_env();

    // `ls` shows it Working, then `get` says it finished: it is no Agent, so
    // the run ends the (never started) activity with no rows.
    hook.core(&env, "hc:t1", "working");
    assert_eq!(relay.count(), 1);
    assert_eq!(relay.bodies()[0]["event"], "end");
    assert_eq!(
        open_envelope(&relay.bodies()[0], &key_a())["agents"],
        json!([])
    );

    // `get` is not answered: the listing line alone makes the row.
    core.set_get_down(true);
    hook.core(&env, "hc:t1", "working");
    assert_eq!(relay.count(), 2);
    assert_eq!(relay.bodies()[1]["event"], "update");
    let payload = open_envelope(&relay.bodies()[1], &key_a());
    assert_eq!(
        payload["agents"],
        json!([{ "kind": "claude", "name": "t1-name", "pane": "hc:t1", "status": "working" }])
    );
}

#[test]
fn the_herdr_hook_counts_and_lists_herdr_tmux_and_core_agents_together_and_a_pin_matches_a_core_id()
{
    let clock = FakeClock::new();
    let sb = Sandbox::new("activity-hook");
    let herdr = FakeHerdr::new(vec![listed_agent(PANE_ID, "blocked", Some("need input"))]);
    let relay = FakeRelay::ok();
    let core = FakeCore::new(vec![core_record("t1", Some("working"), json!({}))]);
    let run = FakeRun::new(Some(vec![tmux_pane("%7", "working")]), Some(&herdr)).with_core(&core);
    let hook = Hook {
        sb: &sb,
        run: &run,
        relay: &relay,
        clock: &clock,
    };
    sb.write_config(Some(RELAY_URL), json!({}));
    sb.write_registration(
        &[live(json!({ "token": ACTIVITY_TOKEN_A, "pinned_pane_ids": ["hc:t1"] })).build()],
        Value::Null,
    );
    let (_listener, env) = sb.core_env();

    herdr_trigger(&hook, &core_event_env(&env, &event("blocked")));

    let bodies = relay.bodies();
    assert_eq!(bodies.len(), 1);
    assert_eq!(bodies[0]["counts"], counts(2, 1, 0, 0));
    let payload = open_envelope(&bodies[0], &key_a());
    // The pinned core Agent leads; herdr's and tmux's follow as ever.
    assert_eq!(agent_panes(&payload), ["hc:t1", PANE_ID, "tmux:%7"]);
    assert_eq!(
        read_last(&sb)["statuses"],
        json!({ PANE_ID: "blocked", "hc:t1": "working", "tmux:%7": "working" })
    );
    // herdr is asked only about its own Agents.
    assert_eq!(
        herdr.invocation_args(),
        vec![vec!["agent", "list"], vec!["workspace", "list"]]
    );
}

/// What the herdr hook pushes on a herdr and tmux Host (a blocked herdr Agent,
/// a working tmux Agent) and what that Host's core was asked. `case` says what
/// the Host has of core: `None` nothing; else it is installed with a Working
/// terminal, and: `"not running"` no core listens, `"core off"` `notify.json`
/// turns it off, `"named session"` the hook runs in a named core session.
fn herdr_tmux_host_content(case: Option<&str>) -> (Value, Vec<Vec<String>>) {
    let clock = FakeClock::new();
    let sb = Sandbox::new("activity-hook");
    let herdr = FakeHerdr::new(vec![listed_agent(PANE_ID, "blocked", Some("need input"))]);
    let relay = FakeRelay::ok();
    let core = FakeCore::new(vec![core_record("t1", Some("working"), json!({}))]);
    let run = FakeRun::new(Some(vec![tmux_pane("%7", "working")]), Some(&herdr)).with_core(&core);
    let hook = Hook {
        sb: &sb,
        run: &run,
        relay: &relay,
        clock: &clock,
    };
    sb.write_config(
        Some(RELAY_URL),
        json!({ "core_enabled": case != Some("core off") }),
    );
    sb.write_registration(&[device()], Value::Null);
    let mut env = sb.herdr_env();
    let mut listener = None;
    if let Some(case) = case {
        let (core_listener, core_env) = sb.core_env();
        env = core_env;
        if case == "named session" {
            env.set("HC_SESSION", "lab");
        }
        // A socket nobody listens on is what a stopped core leaves behind.
        if case != "not running" {
            listener = Some(core_listener);
        }
    }

    herdr_trigger(&hook, &core_event_env(&env, &event("blocked")));

    drop(listener);
    let bodies = relay.bodies();
    assert_eq!(bodies.len(), 1, "{case:?}");
    (open_envelope(&bodies[0], &key_a()), core.invocation_args())
}

#[test]
fn herdr_and_tmux_hosts_build_the_same_content_with_core_absent_off_stopped_or_in_a_named_session()
{
    let (reference, asked) = herdr_tmux_host_content(None);
    assert_eq!(agent_panes(&reference), [PANE_ID, "tmux:%7"]);
    assert!(asked.is_empty());
    for case in ["core off", "not running", "named session"] {
        let (content, asked) = herdr_tmux_host_content(Some(case));
        assert_eq!(content, reference, "{case}");
        // Nothing was run, not even `--version`: a stopped core must not be
        // started by a herdr or tmux event.
        assert!(asked.is_empty(), "{case}: {asked:?}");
    }
}

#[test]
fn a_core_that_cannot_list_adds_no_agents_and_fails_nothing() {
    let clock = FakeClock::new();
    let sb = Sandbox::new("activity-hook");
    let relay = FakeRelay::ok();
    sb.write_config(Some(RELAY_URL), json!({}));
    sb.write_registration(&[device()], Value::Null);
    let core = FakeCore::new(core_terminals());
    core.set_down(true);
    let run = FakeRun::new(Some(vec![tmux_pane("%7", "blocked")]), None).with_core(&core);
    let hook = Hook {
        sb: &sb,
        run: &run,
        relay: &relay,
        clock: &clock,
    };
    let (_listener, env) = sb.core_env();

    hook.core(&env, "hc:t1", "working");

    let payload = open_envelope(&relay.bodies()[0], &key_a());
    assert_eq!(agent_panes(&payload), ["tmux:%7"]);
}

#[test]
fn the_core_trigger_sends_nothing_and_never_asks_core_when_the_host_turned_core_off() {
    let clock = FakeClock::new();
    let sb = Sandbox::new("activity-hook");
    let relay = FakeRelay::ok();
    sb.write_config(Some(RELAY_URL), json!({ "core_enabled": false }));
    sb.write_registration(&[device()], Value::Null);
    let core = FakeCore::new(core_terminals());
    let run = FakeRun::new(Some(vec![tmux_pane("%7", "blocked")]), None).with_core(&core);
    let hook = Hook {
        sb: &sb,
        run: &run,
        relay: &relay,
        clock: &clock,
    };
    let (_listener, env) = sb.core_env();

    hook.core(&env, "hc:t1", "blocked");

    assert_eq!(relay.count(), 0);
    assert!(!run.called_core());
    assert!(!run.called("tmux"));
}

#[test]
fn zellij_activity_renders_live_panes_and_honors_its_gate() {
    let clock = FakeClock::new();
    let sb = Sandbox::new("activity-zellij");
    let relay = FakeRelay::ok();
    sb.write_config(Some(RELAY_URL), json!({}));
    sb.write_registration(&[device()], Value::Null);
    let bin = sb.home().join(".local/bin/zellij");
    fs::create_dir_all(bin.parent().unwrap()).unwrap();
    crate::test_support::write_stub(&bin, "exit 0");
    let fallback = FakeRun::new(None, None);
    let run =
        |bin: &str, args: &[&str], env: &Env| {
            if bin.ends_with("/zellij") {
                RunResult { code: 0, stderr: String::new(), stdout: match args {
                ["--version"] => "zellij 0.46.0".into(),
                ["ls", "-n"] => "work [Created 1s ago]".into(),
                ["-s", "work", "action", "list-panes", "-j"] => json!([{
                    "id": 0, "tab_id": 2, "tab_name": "Tasks", "title": "Agent",
                    "program_status": [{"id": null, "state": "Blocked", "app": "claude-code"}],
                }]).to_string(),
                _ => panic!("unexpected command: {args:?}"),
            }}
            } else {
                fallback.run(bin, args, env)
            }
        };
    let deps = ActivityDeps {
        run: &run,
        fetch: &relay,
        clock: &clock,
    };
    let env = sb.herdr_env();
    run_zellij_activity(
        "zellij:work/terminal_0",
        "blocked",
        &env,
        sb.home(),
        &deps,
        &noop_tick,
    )
    .unwrap();
    let payload = open_envelope(&relay.bodies()[0], &key_a());
    assert_eq!(agent_panes(&payload), ["zellij:work/terminal_0"]);
    assert_eq!(
        read_last(&sb)["statuses"],
        json!({"zellij:work/terminal_0": "blocked"})
    );
    sb.write_config(Some(RELAY_URL), json!({"zellij_enabled": false}));
    run_zellij_activity(
        "zellij:work/terminal_0",
        "done",
        &env,
        sb.home(),
        &deps,
        &noop_tick,
    )
    .unwrap();
    assert_eq!(relay.count(), 1);
}

#[test]
fn each_trigger_takes_only_its_own_pane_ids_and_the_tmux_error_is_unchanged() {
    let clock = FakeClock::new();
    let sb = Sandbox::new("activity-hook");
    let relay = FakeRelay::ok();
    let run = FakeRun::new(None, None);
    let hook = Hook {
        sb: &sb,
        run: &run,
        relay: &relay,
        clock: &clock,
    };
    let env = sb.herdr_env();

    for pane in ["hc:t1", "w1:p1", "t1", ""] {
        let error = hook.tmux_in(&env, pane, "done", &noop_tick).unwrap_err();
        assert_eq!(error.message(), format!("not a tmux pane id: {pane}"));
    }
    for pane in ["tmux:%1", "w1:p1", "t1", "hc:", "hc:-x"] {
        let error = hook.core_in(&env, pane, "done", &noop_tick).unwrap_err();
        assert_eq!(error.message(), format!("not a herdr-core pane id: {pane}"));
    }
    let error = hook.core_in(&env, "hc:t1", "", &noop_tick).unwrap_err();
    assert_eq!(error.message(), "status missing");
    assert_eq!(relay.count(), 0);
}

#[test]
fn a_core_terminals_idle_or_done_event_drops_its_stored_steps_even_with_core_off() {
    let clock = FakeClock::new();
    let sb = Sandbox::new("activity-hook");
    let relay = FakeRelay::ok();
    sb.write_config(Some(RELAY_URL), json!({ "core_enabled": false }));
    sb.write_registration(&[device()], Value::Null);
    let run = FakeRun::new(None, None);
    let hook = Hook {
        sb: &sb,
        run: &run,
        relay: &relay,
        clock: &clock,
    };
    let env = sb.herdr_env();
    for status in ["working", "blocked", "idle", "done"] {
        sb.write_plan_steps(&json!({
            "hc:t1": { "done": 1, "total": 3 }, "hc:t2": { "done": 2, "total": 4 },
        }));

        hook.core(&env, "hc:t1", status);

        let ends = status == "idle" || status == "done";
        let steps = read_plan_steps(&sb.state_dir);
        assert_eq!(steps.contains_key("hc:t1"), !ends, "{status}");
        assert!(steps.contains_key("hc:t2"), "{status}");
    }
}

// ---- activity-hook: Agent Progress ---------------------------------------------

/// `statusRun`: one in-process tmux-trigger status run over herdr `agents`,
/// recording tick requests.
fn status_run(hook: &Hook<'_, '_>, herdr: &FakeHerdr, agents: Vec<Value>, ticks: &Ticks) {
    herdr.set_agents(agents);
    hook.tmux_in(&hook.sb.herdr_env(), "tmux:%7", "working", &|start| {
        ticks.record(start)
    })
    .unwrap();
}

// JS: "progress joins Working/Blocked entries by the record, the frozen Working record, or the tick's steps"
#[test]
fn progress_joins_working_blocked_entries_by_the_record_the_frozen_working_record_or_the_ticks_steps()
 {
    let clock = FakeClock::new();
    rig!(sb, herdr, relay, run, hook, clock; FakeRelay::ok(); vec![]);
    sb.write_config(Some(RELAY_URL), json!({ "summary_enabled": true }));
    sb.write_registration(&[device()], Value::Null);
    sb.write_record(
        PANE_ID,
        "working",
        Some(json!({ "done": 1, "total": 4, "phase": "implementing" })),
    );
    // Blocked, but the notify hook's Blocked record has not landed yet.
    sb.write_record("w1:p3", "working", Some(json!({ "done": 2, "total": 4 })));
    sb.write_record("w1:p4", "done", Some(json!({ "done": 4, "total": 4 })));
    // A turn that started while the app was closed: only the tick's steps.
    sb.write_record("w1:p5", "done", Some(json!({ "done": 5, "total": 5 })));
    sb.write_record("w1:p6", "idle", Some(json!({ "done": 1, "total": 2 })));
    sb.write_plan_steps(&json!({
        "w1:p4": { "done": 1, "total": 9 }, "w1:p5": { "done": 2, "total": 6 },
    }));
    let ticks = Ticks::default();

    status_run(
        &hook,
        &herdr,
        vec![
            default_agent(),
            listed_agent("w1:p3", "blocked", Some("needs input")),
            listed_agent("w1:p4", "done", Some("landed")),
            listed_agent("w1:p5", "working", Some("pocket")),
            listed_agent("w1:p6", "blocked", Some("stale")),
        ],
        &ticks,
    );

    assert_eq!(relay.count(), 1);
    assert_eq!(
        progress_of(&relay.bodies()[0]),
        json!({
            "w1:p3": { "done": 2, "total": 4 },
            "w1:p4": null,
            "w1:p5": { "done": 2, "total": 6 },
            "w1:p6": null,
            PANE_ID: { "done": 1, "phase": "implementing", "total": 4 },
        })
    );
    assert_eq!(
        ticks.all(),
        [(sb.config_dir.clone(), sb.state_dir.clone(), false)]
    );
}

// JS: "an idle or done event clears the pane's stored progress and tick steps on both triggers"
#[test]
fn an_idle_or_done_event_clears_the_panes_stored_progress_and_tick_steps_on_both_triggers() {
    let clock = FakeClock::new();
    let sb = Sandbox::new("activity-hook");
    let relay = FakeRelay::ok();
    sb.write_config(None, json!({ "summary_enabled": true }));
    // No Live Activity registration: clearing runs before every exit.
    sb.write_record(
        "tmux:%7",
        "working",
        Some(json!({ "done": 2, "total": 4, "phase": "verifying" })),
    );
    sb.write_plan_steps(&json!({
        "tmux:%7": { "done": 2, "total": 4 }, PANE_ID: { "done": 1, "total": 3 },
    }));
    let bare = FakeRun::new(None, None);
    Hook {
        sb: &sb,
        run: &bare,
        relay: &relay,
        clock: &clock,
    }
    .tmux("tmux:%7", "done");
    let record = read_json(Path::new(&crate::summary::store::summary_path(
        &sb.config_dir.to_string_lossy(),
        "tmux:%7",
    )));
    assert!(
        record.get("progress").is_none_or(Value::is_null),
        "cleared (absent or explicit null)"
    );
    assert!(record.get("progress_ts").is_none());
    assert_eq!(record["summary"], "Refactoring the transport queue");
    assert_eq!(
        sb.read_state_file("plan-steps.json"),
        json!({ PANE_ID: { "done": 1, "total": 3 } })
    );

    let herdr = FakeHerdr::new(vec![listed_agent(PANE_ID, "idle", None)]);
    let run = FakeRun::new(None, Some(&herdr));
    let hook = Hook {
        sb: &sb,
        run: &run,
        relay: &relay,
        clock: &clock,
    };
    sb.write_record(PANE_ID, "working", Some(json!({ "done": 1, "total": 3 })));
    hook.herdr(&event("idle"));
    let record = read_json(Path::new(&crate::summary::store::summary_path(
        &sb.config_dir.to_string_lossy(),
        PANE_ID,
    )));
    assert!(record.get("progress").is_none_or(Value::is_null));
    assert_eq!(sb.read_state_file("plan-steps.json"), json!({}));

    sb.write_record(PANE_ID, "working", Some(json!({ "done": 1, "total": 3 })));
    sb.write_plan_steps(&json!({ PANE_ID: { "done": 1, "total": 3 } }));
    hook.herdr(&event("blocked"));
    let record = read_json(Path::new(&crate::summary::store::summary_path(
        &sb.config_dir.to_string_lossy(),
        PANE_ID,
    )));
    assert_eq!(record["progress"], json!({ "done": 1, "total": 3 }));
    assert_eq!(
        sb.read_state_file("plan-steps.json"),
        json!({ PANE_ID: { "done": 1, "total": 3 } }),
        "Blocked keeps the frozen estimate"
    );
}

// JS: "only progress on Agents the envelope lists is part of the dedupe key"
#[test]
fn only_progress_on_agents_the_envelope_lists_is_part_of_the_dedupe_key() {
    let clock = FakeClock::new();
    rig!(sb, herdr, relay, run, hook, clock; FakeRelay::ok(); vec![]);
    sb.write_config(Some(RELAY_URL), json!({ "summary_enabled": true }));
    sb.write_registration(&[device()], Value::Null);
    let panes = ["w1:p1", "w1:p2", "w1:p3", "w1:p4", "w1:p5", "w1:p6"];
    let agents: Vec<Value> = panes
        .iter()
        .map(|pane| listed_agent(pane, "working", Some(pane)))
        .collect();
    for pane in panes {
        sb.write_record(pane, "working", Some(json!({ "done": 1, "total": 4 })));
    }
    let ticks = Ticks::default();

    status_run(&hook, &herdr, agents.clone(), &ticks);
    assert_eq!(relay.count(), 1);
    assert_eq!(
        progress_of(&relay.bodies()[0])["w1:p6"],
        Value::Null,
        "past the cap"
    );

    sb.write_record("w1:p6", "working", Some(json!({ "done": 2, "total": 4 })));
    status_run(&hook, &herdr, agents.clone(), &ticks);
    assert_eq!(relay.count(), 1, "an invisible change pushes nothing");

    sb.write_record("w1:p1", "working", Some(json!({ "done": 2, "total": 4 })));
    status_run(&hook, &herdr, agents, &ticks);
    assert_eq!(relay.count(), 2);
    assert_eq!(
        progress_of(&relay.bodies()[1])["w1:p1"],
        json!({ "done": 2, "total": 4 })
    );
}

// JS: "a progress-only change is not suppressed and pushes at priority 5; an unchanged estimate is"
#[test]
fn a_progress_only_change_is_not_suppressed_and_pushes_at_priority_5_an_unchanged_estimate_is() {
    let clock = FakeClock::new();
    rig!(sb, herdr, relay, run, hook, clock; FakeRelay::ok(); vec![]);
    sb.write_config(Some(RELAY_URL), json!({ "summary_enabled": true }));
    sb.write_registration(&[device()], Value::Null);
    let agents = vec![listed_agent(PANE_ID, "blocked", Some("needs input"))];
    sb.write_record(PANE_ID, "blocked", Some(json!({ "done": 1, "total": 4 })));
    let ticks = Ticks::default();

    status_run(&hook, &herdr, agents.clone(), &ticks);
    assert_eq!(relay.count(), 1);
    assert_eq!(relay.bodies()[0]["priority"], 10);

    status_run(&hook, &herdr, agents.clone(), &ticks);
    assert_eq!(
        relay.count(),
        1,
        "same statuses and same estimate stay suppressed"
    );

    sb.write_record(PANE_ID, "blocked", Some(json!({ "done": 2, "total": 4 })));
    status_run(&hook, &herdr, agents, &ticks);
    assert_eq!(relay.count(), 2);
    assert_eq!(relay.bodies()[1]["priority"], 5);
    assert_eq!(
        progress_of(&relay.bodies()[1]),
        json!({ PANE_ID: { "done": 2, "total": 4 } })
    );
}

// JS: "with summaries off a stored estimate is ignored and no tick starts"
#[test]
fn with_summaries_off_a_stored_estimate_is_ignored_and_no_tick_starts() {
    let clock = FakeClock::new();
    rig!(sb, herdr, relay, run, hook, clock; FakeRelay::ok(); vec![]);
    sb.write_config(Some(RELAY_URL), json!({}));
    sb.write_registration(&[device()], Value::Null);
    sb.write_record(PANE_ID, "working", Some(json!({ "done": 1, "total": 4 })));
    let ticks = Ticks::default();

    status_run(&hook, &herdr, vec![default_agent()], &ticks);

    assert_eq!(relay.count(), 1);
    assert_eq!(progress_of(&relay.bodies()[0]), json!({ PANE_ID: null }));
    assert_eq!(ticks.all().len(), 0);
}

// JS: "no tick starts when no Agent is Working"
#[test]
fn no_tick_starts_when_no_agent_is_working() {
    let clock = FakeClock::new();
    rig!(sb, herdr, relay, run, hook, clock; FakeRelay::ok(); vec![]);
    sb.write_config(Some(RELAY_URL), json!({ "summary_enabled": true }));
    sb.write_registration(&[device()], Value::Null);
    let ticks = Ticks::default();

    status_run(
        &hook,
        &herdr,
        vec![listed_agent(PANE_ID, "blocked", Some("needs input"))],
        &ticks,
    );

    assert_eq!(relay.count(), 1);
    assert_eq!(ticks.all().len(), 0);
}

// JS: "payload degradation removes titles, then rows, then progress, then agents"
#[test]
fn payload_degradation_removes_titles_then_rows_then_progress_then_agents() {
    let clock = FakeClock::new();
    rig!(sb, herdr, relay, run, hook, clock;
        FakeRelay::answering(|_, index| if index < 4 {
            (413, json!({ "error": "payload_too_large" }))
        } else {
            (200, json!({}))
        });
        vec![]);
    sb.write_config(Some(RELAY_URL), json!({ "summary_enabled": true }));
    sb.write_registration(
        &[live(json!({
            "token": ACTIVITY_TOKEN_A,
            "row_layout": { "rows": [[{ "token": "directory" }]] },
        }))
        .build()],
        Value::Null,
    );
    sb.write_record(PANE_ID, "working", Some(json!({ "done": 1, "total": 4 })));

    status_run(
        &hook,
        &herdr,
        vec![with_cwd(default_agent(), "/work/Waycar")],
        &Ticks::default(),
    );

    let bodies = relay.bodies();
    assert_eq!(bodies.len(), 5);
    let agents_of = |index: usize| open_envelope(&bodies[index], &key_a())["agents"].clone();
    assert!(agents_of(0)[0]["title"].is_string());
    assert!(agents_of(1)[0].get("title").is_none());
    assert!(agents_of(1)[0]["rows"].is_array());
    assert!(agents_of(2)[0].get("rows").is_none());
    assert_eq!(
        agents_of(2)[0]["progress"],
        json!({ "done": 1, "total": 4 })
    );
    assert!(agents_of(3)[0].get("progress").is_none());
    assert_eq!(agents_of(3)[0]["workspace"], "Waycar");
    assert_eq!(agents_of(4), json!([]));
}

// JS: "the shared degrade vector: titles, then rows, then progress, then agents"
#[test]
fn the_shared_degrade_vector_titles_then_rows_then_progress_then_agents() {
    let path =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("test-vectors/live-activity-content-v1.json");
    let vectors: Value = serde_json::from_slice(&fs::read(path).unwrap()).unwrap();
    let payload = &vectors["degrade"]["payload"];
    let steps = vectors["degrade"]["steps"].as_array().unwrap();
    assert!(!steps.is_empty());
    for (index, expected) in steps.iter().enumerate() {
        assert_eq!(
            &plaintext_at_step(payload, index as u32 + 1),
            expected,
            "step {}",
            index + 1
        );
    }
}

// JS: "runProgressUpdate pushes a progress-only change at 5 and leaves status changes and ended episodes to the hooks"
#[test]
fn run_progress_update_pushes_a_progress_only_change_at_5_and_leaves_status_changes_and_ended_episodes_to_the_hooks()
 {
    let clock = FakeClock::new();
    rig!(sb, herdr, relay, run, hook, clock; FakeRelay::ok(); vec![]);
    sb.write_config(Some(RELAY_URL), json!({ "summary_enabled": true }));
    sb.write_registration(&[device()], Value::Null);
    sb.write_record(PANE_ID, "working", Some(json!({ "done": 1, "total": 4 })));
    status_run(&hook, &herdr, vec![default_agent()], &Ticks::default());
    assert_eq!(relay.count(), 1);

    let env = sb.herdr_env();
    let command = HerdrCommand {
        bin: "herdr".to_string(),
        env: env.clone(),
    };
    let update = |agents: Vec<Value>| {
        herdr.set_agents(agents);
        hook.with_deps(|deps| {
            run_progress_update(
                &ProgressRequest {
                    config_dir: &sb.config_dir,
                    state_dir: &sb.state_dir,
                    herdr: &command,
                    herdr_required: false,
                    env: &env,
                },
                deps,
            )
            .unwrap()
        })
    };

    assert!(!update(vec![default_agent()]), "nothing changed");
    sb.write_record(PANE_ID, "working", Some(json!({ "done": 2, "total": 4 })));
    assert!(update(vec![default_agent()]));
    assert_eq!(relay.count(), 2);
    assert_eq!(relay.bodies()[1]["event"], "update");
    assert_eq!(relay.bodies()[1]["priority"], 5);
    assert_eq!(
        progress_of(&relay.bodies()[1]),
        json!({ PANE_ID: { "done": 2, "total": 4 } })
    );

    sb.write_record(PANE_ID, "working", Some(json!({ "done": 3, "total": 4 })));
    assert!(
        !update(vec![listed_agent(
            PANE_ID,
            "blocked",
            Some("implement live activity")
        )]),
        "a status change is the hooks' push"
    );
    sb.write_last_state(&json!({ "sent_at_ms": 1, "statuses": {}, "ended": true }));
    assert!(
        !update(vec![default_agent()]),
        "an ended episode stays ended"
    );
    assert_eq!(relay.count(), 2);
}

// ---- sidebar-hook.test.js: activity-hook.js ------------------------------------

/// The sidebar-hook suite's `run(script, event)` environment.
fn sidebar_env(sb: &Sandbox, with_event: bool) -> Env {
    let mut env = Env::from_pairs([
        ("PATH", "/usr/bin:/bin"),
        ("HOME", sb.home().to_str().unwrap()),
        (
            "HERDR_CONFIG_PATH",
            sb.home().join("config.toml").to_str().unwrap(),
        ),
        ("HERDR_PLUGIN_CONFIG_DIR", sb.config_dir.to_str().unwrap()),
    ]);
    if with_event {
        env.set(
            "HERDR_PLUGIN_EVENT_JSON",
            json!({ "data": { "pane_id": "w1:pA", "agent_status": "working" } }).to_string(),
        );
        env.set("HERDR_PLUGIN_STATE_DIR", sb.state_dir.to_str().unwrap());
        env.set(
            "HERDR_BIN_PATH",
            sb.home().join("must-not-run-herdr").to_str().unwrap(),
        );
    }
    env
}

/// `run("activity-hook.js", true)`: no notifications are registered, so the
/// runner (herdr, tmux) must never be called.
fn run_sidebar_event(sb: &Sandbox) -> ActivityOutcome {
    let relay = FakeRelay::ok();
    let runner = |cmd: &str, args: &[&str], _: &Env| -> RunResult {
        panic!("nothing may run, not even {cmd} {args:?}")
    };
    let outcome = run_herdr_activity(
        &sidebar_env(sb, true),
        &ActivityDeps {
            fetch: &relay,
            clock: &SystemClock,
            run: &runner,
        },
        &noop_tick,
    );
    assert_eq!(outcome.code, 0, "{}", outcome.stderr);
    outcome
}

// JS: "activity-hook.js refreshes before no-device and no-notification exits"
#[test]
fn activity_hook_js_refreshes_before_no_device_and_no_notification_exits() {
    let sb = Sandbox::new("sidebar-hook");
    let path = sb.home().join("config.toml");
    fs::write(&path, "").unwrap();
    set_mtime(&path, UNIX_EPOCH + Duration::from_secs(1));
    refresh_sidebar_snapshot(&sb.config_dir, &sidebar_env(&sb, false), &system_now_ms).unwrap();
    fs::write(&path, "[ui]\nagent_panel_sort = \"priority\"\n").unwrap();
    set_mtime(&path, UNIX_EPOCH + Duration::from_secs(2));

    run_sidebar_event(&sb);

    let snapshot = read_json(&sb.config_dir.join("sidebar.json"));
    assert_eq!(snapshot["agent_panel_sort"], "priority");
    assert_eq!(snapshot["source"]["mtime_ms"].as_f64(), Some(2000.0));
    let snapshot_path = sb.config_dir.join("sidebar.json");
    let before = fs::metadata(&snapshot_path).unwrap();
    run_sidebar_event(&sb);
    let after = fs::metadata(&snapshot_path).unwrap();
    assert_eq!(after.ino(), before.ino());
    assert_eq!(after.modified().unwrap(), before.modified().unwrap());
}

// JS: "activity-hook.js keeps its event path working when snapshot writes fail"
#[test]
fn activity_hook_js_keeps_its_event_path_working_when_snapshot_writes_fail() {
    let sb = Sandbox::new("sidebar-hook");
    fs::create_dir(sb.config_dir.join("sidebar.json")).unwrap();

    let outcome = run_sidebar_event(&sb);

    assert!(
        outcome
            .stderr
            .contains("sidebar-hook: snapshot refresh failed"),
        "{}",
        outcome.stderr
    );
}

// ---- Rust-only tests -----------------------------------------------------------

/// A request the stand-in relay saw: request line, lower-cased headers, body.
type Served = (String, Vec<(String, String)>, Value);

/// A stand-in relay on a local port: it answers every POST with
/// `200 {"apnsId":"x"}` and returns the requests it saw when `requests` have
/// been served.
fn serve_relay(requests: usize) -> (String, std::thread::JoinHandle<Vec<Served>>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let handle = std::thread::spawn(move || {
        let mut seen = Vec::new();
        for stream in listener.incoming().take(requests) {
            let mut stream = stream.unwrap();
            let mut raw = Vec::new();
            let (head_end, length) = loop {
                let mut chunk = [0u8; 4096];
                let read = stream.read(&mut chunk).unwrap();
                assert!(read > 0, "client hung up mid-request");
                raw.extend_from_slice(&chunk[..read]);
                let Some(end) = raw.windows(4).position(|window| window == b"\r\n\r\n") else {
                    continue;
                };
                let head = String::from_utf8_lossy(&raw[..end]).to_lowercase();
                let length = head
                    .lines()
                    .find_map(|line| line.strip_prefix("content-length:"))
                    .map_or(0, |value| value.trim().parse::<usize>().unwrap());
                if raw.len() >= end + 4 + length {
                    break (end, length);
                }
            };
            let head = String::from_utf8_lossy(&raw[..head_end]).into_owned();
            let mut lines = head.lines();
            let request_line = lines.next().unwrap().to_string();
            let headers = lines
                .map(|line| {
                    let (name, value) = line.split_once(':').unwrap();
                    (name.trim().to_lowercase(), value.trim().to_string())
                })
                .collect();
            let body = serde_json::from_slice(&raw[head_end + 4..head_end + 4 + length]).unwrap();
            seen.push((request_line, headers, body));
            let answer = r#"{"apnsId":"x"}"#;
            write!(
                stream,
                "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{answer}",
                answer.len()
            )
            .unwrap();
        }
        seen
    });
    (url, handle)
}

#[test]
fn rust_tmux_trigger_posts_the_update_through_the_real_http_fetch() {
    let (url, server) = serve_relay(1);
    let sb = Sandbox::new("activity-hook");
    sb.write_config(Some(&url), json!({ "activity_debounce_ms": 5 }));
    sb.write_registration(&[device()], Value::Null);
    let run = FakeRun::new(Some(vec![tmux_pane("%7", "blocked")]), None);
    let env = sb.herdr_env();

    let runner = |cmd: &str, args: &[&str], env: &Env| run.run(cmd, args, env);
    run_tmux_activity(
        "tmux:%7",
        "blocked",
        &env,
        sb.home(),
        &ActivityDeps {
            fetch: &HttpFetch,
            clock: &SystemClock,
            run: &runner,
        },
        &noop_tick,
    )
    .unwrap();

    let seen = server.join().unwrap();
    assert_eq!(seen.len(), 1);
    let (request_line, headers, body) = &seen[0];
    assert_eq!(request_line, "POST /push HTTP/1.1");
    let content_type = headers
        .iter()
        .find(|(name, _)| name == "content-type")
        .map(|(_, value)| value.as_str());
    assert_eq!(content_type, Some("application/json"));
    assert_eq!(body["kind"], "liveactivity");
    assert_eq!(body["event"], "update");
    assert_eq!(body["priority"], 10);
    assert_eq!(body["token"], ACTIVITY_TOKEN_A);
    assert_eq!(body["counts"], counts(0, 1, 0, 0));
    let payload = open_envelope(body, &key_a());
    assert_eq!(agent_panes(&payload), ["tmux:%7"]);
    assert_eq!(payload["agents"][0]["status"], "blocked");
}

#[test]
fn rust_node_base64_decode_matches_buffer_from_base64url() {
    let key = key_a();
    let encoded = base64::encode_url(&key);
    assert_eq!(encoded.len(), 43);
    assert_eq!(base64::decode(&encoded), key);
    // A trailing `=` is ignored.
    assert_eq!(base64::decode(&format!("{encoded}=")), key);
    // `=` in the middle stops the decode: 20 sextets are 15 bytes.
    assert_eq!(
        base64::decode(&format!("{}=AAAA", "A".repeat(20))),
        vec![0u8; 15]
    );
    // Stray characters are skipped.
    let noisy: String = encoded
        .chars()
        .enumerate()
        .flat_map(|(index, ch)| match index % 3 {
            0 => vec!['!', ch],
            1 => vec!['\n', ch],
            _ => vec![' ', ch],
        })
        .collect();
    assert_eq!(base64::decode(&noisy), key);
    // Both alphabets: 62 and 63 as `+`/`/` and as `-`/`_`.
    assert_eq!(base64::decode("+/+/"), [0xfb, 0xff, 0xbf]);
    assert_eq!(base64::decode("-_-_"), [0xfb, 0xff, 0xbf]);
    // 44 characters are 33 bytes, so such a key is not a key.
    assert_eq!(base64::decode(&"A".repeat(44)).len(), 33);
    assert_eq!(base64::decode(&"A".repeat(43)).len(), 32);
    // A trailing sextet that completes no byte adds nothing.
    assert_eq!(base64::decode("AB"), [0]);
    assert_eq!(base64::decode("A"), Vec::<u8>::new());
}

#[test]
fn rust_device_preferences_hash_matches_the_js() {
    // From node, over the same two devices, sorted by token:
    //   createHash("sha256").update(JSON.stringify([
    //     {token: "c…", env: "sandbox", pins: ["w1:p2", "tmux:%7"],
    //      layout: {rows: [[{token: "host"}], [{token: "directory", fg: "#ff0000", dim: true}]]},
    //      host: "My Mac"},
    //     {token: "d…", env: "production", pins: undefined, layout: null, host: null},
    //   ])).digest("hex")
    let device = |token: &str, env: &str| Device {
        id: None,
        key: Vec::new(),
        update: Some(Target {
            provider: Provider::Apns,
            token: token.to_string(),
            env: env.to_string(),
            host_id: None,
        }),
        start: None,
        pinned_pane_ids: None,
        row_layout: None,
        row_host_name: None,
    };
    let plain = device(ACTIVITY_TOKEN_B, "production");
    let mut rich = device(ACTIVITY_TOKEN_A, "sandbox");
    rich.pinned_pane_ids = Some(json!(["w1:p2", "tmux:%7"]));
    rich.row_layout = parse_activity_row_layout(Some(&json!({
        "rows": [[{ "token": "host" }], [{ "token": "directory", "dim": true, "fg": "#ff0000" }]],
    })));
    rich.row_host_name = Some("My Mac".to_string());

    assert_eq!(
        device_preferences(&[&plain, &rich]),
        "f121f0fd69d806aa6f15edbbce388ea81c0254deb6307dc46e3705801ed463d5"
    );
}

#[test]
fn rust_js_slice_cuts_a_surrogate_pair_and_the_413_check_reads_only_200_units() {
    // "😀" is two UTF-16 units: a cut between them leaves a lone surrogate.
    assert_eq!(js_slice("a😀", 2), "a\u{FFFD}");
    assert_eq!(js_slice("😀", 1), "\u{FFFD}");
    assert_eq!(js_slice("😀", 2), "😀");
    assert_eq!(js_slice("😀", 0), "");
    assert_eq!(js_slice("short", 200), "short");

    assert!(is_relay_origin_413(r#"{"error":"payload_too_large"}"#));
    assert!(!is_relay_origin_413(r#"{"error":1}"#));
    assert!(!is_relay_origin_413(r#"{"reason":"x"}"#));
    assert!(!is_relay_origin_413("[]"));
    assert!(!is_relay_origin_413("payload too large"));
    // The error sits past the first 200 units: the detail postPush looks at
    // is cut mid-JSON.
    let body = format!(r#"{{"pad":"{}","error":"e"}}"#, "x".repeat(200));
    assert!(is_relay_origin_413(&body));
    assert!(!is_relay_origin_413(&js_slice(&body, 200)));
    let emoji_body = format!(r#"{{"pad":"{}","error":"e"}}"#, "😀".repeat(100));
    assert!(!is_relay_origin_413(&js_slice(&emoji_body, 200)));
}

#[test]
fn rust_a_lone_surrogate_escape_still_yields_a_device_and_a_status_event() {
    let sb = Sandbox::new("activity-hook");
    let registration = r#"{"v":1,"devices":[{"token":"ALERT","key":"KEY","env":"sandbox",
        "live_activity":{"token":"UPDATE","host_name":"\ud800 Mac"}}]}"#
        .replace("ALERT", ALERT_TOKEN)
        .replace("KEY", &base64::encode_url(&key_a()))
        .replace("UPDATE", ACTIVITY_TOKEN_A);
    fs::write(sb.config_dir.join("notifications.json"), registration).unwrap();

    let devices = read_activity_devices(&sb.config_dir);

    assert_eq!(devices.len(), 1);
    assert_eq!(devices[0].row_host_name.as_deref(), Some("\u{FFFD} Mac"));
    assert_eq!(devices[0].update_token(), Some(ACTIVITY_TOKEN_A));

    let event = parse_status_event(
        r#"{"event":"pane_agent_status_changed","data":{"pane_id":"w1:p\ud800","agent_status":"Working"}}"#,
    )
    .unwrap();
    assert_eq!(event.pane_id, "w1:p\u{FFFD}");
    assert_eq!(event.status, "working");
}

/// The relay body's wire bytes are the JS `JSON.stringify` ones: key order
/// `kind, token, env, event, priority, timestamp, counts, envelope`, then the
/// dates, then a start's attribute fields.
#[test]
fn rust_relay_body_bytes_follow_the_js_key_order() {
    let counts = Counts {
        working: 1,
        blocked: 0,
        done: 0,
        idle: 2,
    };
    let update = Target {
        provider: Provider::Apns,
        token: ACTIVITY_TOKEN_A.to_string(),
        env: "sandbox".to_string(),
        host_id: None,
    };
    let request = Request {
        target: &update,
        event: "update",
        priority: 5,
        timestamp: 1_790_000_000,
        counts,
    };
    assert_eq!(
        jsx::stringify(&relay_body(&request, "{\"v\":1}")),
        format!(
            r#"{{"kind":"liveactivity","token":"{ACTIVITY_TOKEN_A}","env":"sandbox","event":"update","priority":5,"timestamp":1790000000,"counts":{{"working":1,"blocked":0,"done":0,"idle":2}},"envelope":"{{\"v\":1}}","stale_date":1790000900}}"#
        )
    );
    let end = Request {
        event: "end",
        ..request
    };
    assert!(
        jsx::stringify(&relay_body(&end, "e"))
            .ends_with(r#""envelope":"e","dismissal_date":1790000000}"#)
    );
    let start = Target {
        provider: Provider::Apns,
        token: START_TOKEN.to_string(),
        env: "production".to_string(),
        host_id: Some(HOST_ID.to_string()),
    };
    let request = Request {
        target: &start,
        event: "start",
        priority: 10,
        timestamp: 1_790_000_000,
        counts,
    };
    assert_eq!(
        jsx::stringify(&relay_body(&request, "e")),
        format!(
            r#"{{"kind":"liveactivity","token":"{START_TOKEN}","env":"production","event":"start","priority":10,"timestamp":1790000000,"counts":{{"working":1,"blocked":0,"done":0,"idle":2}},"envelope":"e","stale_date":1790000900,"attributes_type":"AgentActivityAttributes","attributes":{{"hostID":"{HOST_ID}"}},"alert":{{"title":"{START_ALERT_TITLE}","body":"{START_ALERT_BODY}"}}}}"#
        )
    );
}

// ---- activity-hook: fcm provider -------------------------------------------------

/// The shared FCM registration vector (one APNs entry, one FCM entry).
fn fcm_vector() -> Value {
    serde_json::from_str(include_str!(
        "../test-vectors/registration-file-fcm-v1.json"
    ))
    .expect("registration-file-fcm-v1.json")
}

fn fcm_entry() -> Value {
    fcm_vector()["file"]["devices"][1].clone()
}

fn fcm_key() -> Vec<u8> {
    base64::decode(fcm_entry()["key"].as_str().unwrap())
}

// JS: "an enabled fcm entry gets a Live Update to its own token with only event and priority in plaintext"
#[test]
fn an_enabled_fcm_entry_gets_a_live_update_to_its_own_token_with_only_event_and_priority_in_plaintext()
 {
    let clock = FakeClock::new();
    rig!(sb, herdr, relay, run, hook, clock; FakeRelay::ok(); vec![default_agent()]);
    sb.write_config(Some(RELAY_URL), json!({}));
    sb.write_registration(&[fcm_entry()], Value::Null);

    hook.herdr(&event("working"));

    let bodies = relay.bodies();
    assert_eq!(bodies.len(), 1);
    let body = &bodies[0];
    let mut keys: Vec<&str> = body
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect();
    assert_eq!(
        keys,
        [
            "provider", "kind", "token", "env", "event", "priority", "envelope"
        ]
    );
    keys.sort_unstable();
    assert_eq!(
        keys,
        [
            "env", "envelope", "event", "kind", "priority", "provider", "token"
        ]
    );
    assert_eq!(body["provider"], "fcm");
    assert_eq!(body["kind"], "liveactivity");
    assert_eq!(body["token"], fcm_vector()["fcmToken"]);
    assert_eq!(body["event"], "update");
    assert_eq!(body["priority"], 5);
    let opened = open_envelope(body, &fcm_key());
    assert_eq!(opened["agents"][0]["status"], "working");
}

// JS: "a blocked agent sends priority 10; an empty inventory ends with event end"
#[test]
fn a_blocked_fcm_agent_sends_priority_10_and_an_empty_inventory_ends_with_event_end() {
    let clock = FakeClock::new();
    rig!(sb, herdr, relay, run, hook, clock; FakeRelay::ok();
        vec![listed_agent(PANE_ID, "blocked", Some("need input"))]);
    sb.write_config(Some(RELAY_URL), json!({}));
    sb.write_registration(&[fcm_entry()], Value::Null);

    hook.herdr(&event("blocked"));
    assert_eq!(relay.bodies()[0]["priority"], 10);

    herdr.set_agents(vec![]);
    hook.herdr(&event("idle"));

    let bodies = relay.bodies();
    assert_eq!(bodies.len(), 2);
    let end = &bodies[1];
    assert_eq!(end["event"], "end");
    assert!(end.get("dismissal_date").is_none());
    assert!(end.get("counts").is_none());
    assert!(end.get("timestamp").is_none());
}

// JS: "an fcm entry without live_activity.enabled, and an apns-only registration, send nothing for fcm"
#[test]
fn an_fcm_entry_that_did_not_enable_live_updates_sends_nothing() {
    let clock = FakeClock::new();
    rig!(sb, herdr, relay, run, hook, clock; FakeRelay::ok(); vec![default_agent()]);
    sb.write_config(Some(RELAY_URL), json!({}));
    let mut disabled = fcm_entry();
    disabled.as_object_mut().unwrap().remove("live_activity");
    let mut off = fcm_entry();
    off["live_activity"] = json!({ "enabled": "true" });
    let mut short_token = fcm_entry();
    short_token["token"] = json!("tooShort:APA91b");
    sb.write_registration(&[disabled, off, short_token], Value::Null);

    hook.herdr(&event("working"));

    assert_eq!(relay.count(), 0);
}

// JS: "an fcm entry never gets a push-to-start or a start grace wait"
#[test]
fn an_fcm_entry_never_gets_a_push_to_start() {
    let clock = FakeClock::new();
    rig!(sb, herdr, relay, run, hook, clock; FakeRelay::ok(); vec![default_agent()]);
    sb.write_config(Some(RELAY_URL), start_grace());
    let mut entry = fcm_entry();
    entry["live_activity_start"] = startup_registration();
    sb.write_registration(&[entry], Value::Null);

    hook.herdr(&event("working"));

    let bodies = relay.bodies();
    assert_eq!(bodies.len(), 1);
    assert!(bodies.iter().all(|body| body["event"] != "start"));
    assert!(bodies.iter().all(|body| body.get("attributes").is_none()));
}

// JS: "a 410 prunes the whole fcm entry and keeps the apns entry"
#[test]
fn a_410_prunes_the_whole_fcm_entry_and_keeps_the_apns_entry() {
    let clock = FakeClock::new();
    rig!(sb, herdr, relay, run, hook, clock;
        FakeRelay::answering(|body, _| if body["provider"] == "fcm" {
            (410, json!({ "reason": "Unregistered" }))
        } else {
            (200, json!({ "apnsId": "x" }))
        });
        vec![default_agent()]);
    sb.write_config(Some(RELAY_URL), json!({}));
    let vector = fcm_vector();
    let mut apns = vector["file"]["devices"][0].clone();
    apns["live_activity"] = json!({ "token": ACTIVITY_TOKEN_A });
    sb.write_registration(&[apns, fcm_entry()], Value::Null);

    hook.herdr(&event("working"));

    let file = sb.read_registration();
    let devices = file["devices"].as_array().unwrap();
    assert_eq!(devices.len(), 1);
    assert_eq!(devices[0]["token"], vector["file"]["devices"][0]["token"]);
    assert_eq!(devices[0]["live_activity"]["token"], ACTIVITY_TOKEN_A);
}

// ---- against a real herdr-core -------------------------------------------------

/// A private herdr-core: its own runtime and state directories and the default
/// session, started by the first command run against it and stopped on drop.
/// `WAYCAR_TEST_HERDR_CORE` names the binary; without it the tests that need
/// one skip, so a machine that happens to have core installed never starts
/// one from `cargo test`.
struct RealCore {
    command: crate::core::CoreCommand,
    /// Holds the runtime directory (under `/tmp`: a socket path must fit
    /// 107 bytes, which the system temp directory may not), removed on drop.
    dir: PathBuf,
}

impl RealCore {
    fn start(sb: &Sandbox) -> Option<Self> {
        static CORES: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let Some(bin) = std::env::var_os("WAYCAR_TEST_HERDR_CORE").map(PathBuf::from) else {
            eprintln!("skipped: WAYCAR_TEST_HERDR_CORE is not set");
            return None;
        };
        let dir = PathBuf::from(format!(
            "/tmp/wc-real-core-{}-{}",
            std::process::id(),
            CORES.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        ));
        let run_dir = dir.join("run");
        fs::create_dir_all(&run_dir).unwrap();
        fs::set_permissions(
            &run_dir,
            std::os::unix::fs::PermissionsExt::from_mode(0o700),
        )
        .unwrap();
        let mut env = sb.herdr_env();
        env.set("XDG_RUNTIME_DIR", run_dir.to_str().unwrap());
        env.set("XDG_STATE_HOME", sb.home().join("state").to_str().unwrap());
        env.set("XDG_CONFIG_HOME", sb.home().join("xdg").to_str().unwrap());
        let bin = bin.to_str().unwrap().to_string();
        let version = crate::core::parse_version(
            &crate::exec::run_program(&bin, &["--version"], &env).stdout,
        );
        let Some(version) = version else {
            eprintln!("skipped: {bin} is not herdr-core");
            let _ = fs::remove_dir_all(&dir);
            return None;
        };
        Some(Self {
            command: crate::core::CoreCommand { bin, version, env },
            dir,
        })
    }

    /// `herdr-core run --bg --name <name> -- sh fake-agent.sh <name> <mode>`.
    fn run_fake_agent(&self, name: &str, mode: &str) {
        let agent = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../scripts/core-lab/agents/fake-agent.sh"
        );
        let result = crate::exec::run_program(
            &self.command.bin,
            &["run", "--bg", "--name", name, "--", "sh", agent, name, mode],
            &self.command.env,
        );
        assert_eq!(result.code, 0, "{}", result.stderr);
    }

    /// Wait for core to list `want` as `(name, status word)`.
    fn wait_for(&self, want: &[(&str, &str)]) {
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        loop {
            let listed = crate::core::list(&self.command, &crate::exec::run_program).unwrap();
            let seen: Vec<(String, String)> = listed
                .iter()
                .filter_map(|listing| Some((listing.name.clone()?, listing.status.clone()?)))
                .collect();
            if want
                .iter()
                .all(|(name, status)| seen.iter().any(|(n, s)| n == name && s == status))
            {
                return;
            }
            assert!(std::time::Instant::now() < deadline, "core lists {seen:?}");
            std::thread::sleep(Duration::from_millis(50));
        }
    }
}

impl Drop for RealCore {
    fn drop(&mut self) {
        crate::exec::run_program(&self.command.bin, &["server", "stop"], &self.command.env);
        let _ = fs::remove_dir_all(&self.dir);
    }
}

#[test]
fn rust_a_real_core_terminal_hook_builds_the_content_from_the_real_ls_and_get_replies() {
    let clock = FakeClock::new();
    let sb = Sandbox::new("activity-real-core");
    let Some(core) = RealCore::start(&sb) else {
        return;
    };
    let relay = FakeRelay::ok();
    sb.write_config(Some(RELAY_URL), json!({ "tmux_enabled": false }));
    sb.write_registration(&[device()], Value::Null);
    core.run_fake_agent("worker", "loop");
    core.run_fake_agent("asker", "blocked");
    core.run_fake_agent("idler", "idle");
    core.wait_for(&[
        ("worker", "working"),
        ("asker", "blocked"),
        ("idler", "idle"),
    ]);
    // The hook labels its terminal (the first one core made).
    crate::core::label(
        &core.command,
        &crate::exec::run_program,
        "t1",
        &[("waycar.kind", "claude")],
    )
    .unwrap();
    // Core's own program runs for core only: herdr and tmux are not installed.
    let run = |cmd: &str, args: &[&str], env: &Env| {
        if std::path::Path::new(cmd)
            .file_name()
            .is_some_and(|name| name == "herdr-core")
        {
            crate::exec::run_program(cmd, args, env)
        } else {
            RunResult {
                stdout: String::new(),
                stderr: format!("spawn {cmd} ENOENT"),
                code: 127,
            }
        }
    };
    let deps = ActivityDeps {
        fetch: &relay,
        clock: &clock,
        run: &run,
    };
    // The environment of a hook run by a program in the core's terminal t1,
    // minus the socket variable: the socket is found by core's own rule.
    let mut env = core.command.env.clone();
    env.set("HC_TERMINAL_ID", "t1");
    env.set(
        "PATH",
        format!(
            "{}:/usr/bin:/bin",
            Path::new(&core.command.bin).parent().unwrap().display()
        ),
    );

    run_core_activity("hc:t1", "working", &env, sb.home(), &deps, &noop_tick).unwrap();

    let bodies = relay.bodies();
    assert_eq!(bodies.len(), 1);
    assert_eq!(bodies[0]["counts"], counts(1, 1, 0, 1));
    let payload = open_envelope(&bodies[0], &key_a());
    let rows: Vec<(&str, &str, &str, &str)> = payload["agents"]
        .as_array()
        .unwrap()
        .iter()
        .map(|agent| {
            (
                agent["pane"].as_str().unwrap(),
                agent["status"].as_str().unwrap(),
                agent["kind"].as_str().unwrap(),
                agent["name"].as_str().unwrap(),
            )
        })
        .collect();
    // The label beats the program's own report (`worker`) for t1; t2 is
    // what its app says it is.
    assert_eq!(
        rows,
        [
            ("hc:t2", "blocked", "asker", "asker"),
            ("hc:t1", "working", "claude", "worker"),
        ]
    );
    assert_eq!(
        read_last(&sb)["statuses"],
        json!({ "hc:t1": "working", "hc:t2": "blocked" })
    );
}
