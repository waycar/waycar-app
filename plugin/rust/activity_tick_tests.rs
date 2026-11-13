//! Tests of `activity_tick.rs`: the port of test/activity-tick.test.js, in
//! process with a fake clock, a fake herdr/tmux runner and a stub plan reader,
//! plus the Rust-only seams (`rust_*`).

use std::cell::Cell;
use std::fs;
use std::sync::Mutex;

use serde_json::{Value, json};

use super::*;
use crate::activity_fakes::{
    FakeClock, FakeCore, FakeHerdr, FakeRelay, FakeRun, Sandbox, core_record, device, key_a,
    open_envelope,
};
use crate::activity_hook::run_progress_update;
use crate::chat::shared::PlanSteps;
use crate::deps::Fetch;
use crate::exec::RunResult;
use crate::summary::store::summary_path;

const PANE: &str = "w1:p1";

fn herdr_agent(status: &str) -> Value {
    json!({
        "pane_id": PANE, "agent": "omp", "agent_status": status,
        "agent_session": { "kind": "id", "value": "session-1" },
        "cwd": "/work/api", "workspace_id": "w1",
    })
}

/// `writeConfig(overrides)`: summaries on, the retry delay short.
fn write_config(sb: &Sandbox, relay_url: Option<&str>, overrides: Value) {
    let mut config = json!({ "summary_enabled": true });
    config
        .as_object_mut()
        .unwrap()
        .extend(overrides.as_object().cloned().unwrap_or_default());
    sb.write_config(relay_url, config);
}

/// `writeRecord(status, progress)`: the JS record, `hash: "abc"`.
fn write_record(sb: &Sandbox, status: &str, progress: Option<Value>) {
    let mut record = json!({
        "v": 1, "pane": PANE, "status": status,
        "summary": "Refactoring the transport queue", "ts": 1, "hash": "abc",
    });
    if let Some(progress) = progress {
        record["progress"] = progress;
    }
    let path = summary_file(sb);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, format!("{record}\n")).unwrap();
}

/// Where the pane's summary-store entry lives.
fn summary_file(sb: &Sandbox) -> PathBuf {
    PathBuf::from(summary_path(&sb.config_dir.to_string_lossy(), PANE))
}

fn read_plan_steps_file(sb: &Sandbox) -> Value {
    let path = sb.activity_dir().join("plan-steps.json");
    if path.exists() {
        crate::activity_fakes::read_json(&path)
    } else {
        json!({})
    }
}

fn lock_path(sb: &Sandbox) -> PathBuf {
    sb.activity_dir().join(TICK_LOCK_NAME)
}

fn write_lock(sb: &Sandbox, pid: u32, ts: u64) {
    fs::create_dir_all(sb.activity_dir()).unwrap();
    fs::write(
        lock_path(sb),
        format!("{}\n", json!({ "pid": pid, "ts": ts })),
    )
    .unwrap();
}

fn read_lock_json(sb: &Sandbox) -> Value {
    crate::activity_fakes::read_json(&lock_path(sb))
}

fn sandbox() -> Sandbox {
    let sb = Sandbox::new("activity-tick");
    fs::create_dir_all(sb.activity_dir()).unwrap();
    sb
}

/// A plan reader driven by a closure (`readPlan`).
struct FnPlan<F>(F);

impl<F: Fn(&PlanRequest<'_>) -> PlanProgress> PlanReader for FnPlan<F> {
    fn read_plan(&self, request: &PlanRequest<'_>) -> PlanProgress {
        (self.0)(request)
    }
}

/// A reader that never finds a transcript: every read is unreadable.
struct UnreadablePlans;

impl PlanReader for UnreadablePlans {
    fn read_plan(&self, _request: &PlanRequest<'_>) -> PlanProgress {
        PlanProgress::Unreadable
    }
}

fn plan<F: Fn(&PlanRequest<'_>) -> PlanProgress>(read: F) -> FnPlan<F> {
    FnPlan(read)
}

fn steps(done: u32, total: u32) -> PlanProgress {
    PlanProgress::Steps(PlanSteps { done, total })
}

fn no_plan() -> FnPlan<impl Fn(&PlanRequest<'_>) -> PlanProgress> {
    plan(|_| PlanProgress::None)
}

/// `(agent, session, cwd, pane id)` of one plan read.
type ReadSeen = (String, Option<SessionRef>, Option<String>, String);

type SendFn<'a> = &'a dyn Fn(&ProgressRequest<'_>, &ActivityDeps<'_>) -> Result<bool>;

fn noop_send(_: &ProgressRequest<'_>, _: &ActivityDeps<'_>) -> Result<bool> {
    Ok(true)
}

/// A runtime directory that holds no core socket, so no test finds the core
/// of the machine it runs on.
fn no_core_env() -> Env {
    Env::from_pairs([("XDG_RUNTIME_DIR", "/nonexistent/waycar-test-run")])
}

/// `tick(overrides)`: one `runActivityTick` on a fresh fake clock.
fn tick_full(
    sb: &Sandbox,
    run: &FakeRun<'_>,
    reader: &dyn PlanReader,
    send_update: SendFn<'_>,
    fetch: &dyn Fetch,
) -> TickStop {
    tick_in(sb, run, reader, send_update, fetch, &no_core_env())
}

/// [`tick_full`] in the environment `env`.
fn tick_in(
    sb: &Sandbox,
    run: &FakeRun<'_>,
    reader: &dyn PlanReader,
    send_update: SendFn<'_>,
    fetch: &dyn Fetch,
    env: &Env,
) -> TickStop {
    let clock = FakeClock::new();
    let runner = |cmd: &str, args: &[&str], env: &Env| run.run(cmd, args, env);
    let herdr = HerdrCommand {
        bin: "herdr".into(),
        env: Env::default(),
    };
    let host = TickHost {
        config_dir: &sb.config_dir,
        state_dir: &sb.state_dir,
        herdr: &herdr,
        herdr_required: false,
        env,
    };
    let deps = TickDeps {
        activity: ActivityDeps {
            fetch,
            clock: &clock,
            run: &runner,
        },
        plan: reader,
        send_update,
    };
    run_activity_tick(&host, &deps).unwrap()
}

fn tick(
    sb: &Sandbox,
    run: &FakeRun<'_>,
    reader: &dyn PlanReader,
    send_update: SendFn<'_>,
) -> TickStop {
    tick_full(sb, run, reader, send_update, &FakeRelay::ok())
}

// ---- suite: activity-tick: loop ---------------------------------------------

// JS: "writes a changed plan into the store and pushes once; an unchanged plan pushes nothing; exits when no Agent is Working"
#[test]
fn writes_a_changed_plan_into_the_store_and_pushes_once_an_unchanged_plan_pushes_nothing_exits_when_no_agent_is_working()
 {
    let sb = sandbox();
    write_config(&sb, None, json!({}));
    sb.write_last_state(&json!({ "statuses": { PANE: "working" }, "ended": false }));
    write_record(&sb, "working", Some(json!({ "phase": "implementing" })));
    let herdr = FakeHerdr::new(vec![herdr_agent("working")]);
    let run = FakeRun::new(None, Some(&herdr));
    let reads: Mutex<Vec<ReadSeen>> = Mutex::default();
    let sends = Cell::new(0);

    let reason = tick(
        &sb,
        &run,
        &plan(|request| {
            let mut reads = reads.lock().unwrap();
            reads.push((
                request.agent.to_string(),
                request.session.cloned(),
                request.cwd.map(str::to_string),
                request.pane_id.to_string(),
            ));
            if reads.len() == 2 {
                herdr.set_agents(vec![herdr_agent("done")]);
            }
            steps(1, 3)
        }),
        // Stands in for the send flow recording what it pushed (canonical order).
        &|_: &ProgressRequest<'_>, _: &ActivityDeps<'_>| {
            sends.set(sends.get() + 1);
            sb.write_last_state(&json!({
                "statuses": { PANE: "working" }, "ended": false,
                "progress": { PANE: { "done": 1, "phase": "implementing", "total": 3 } },
            }));
            Ok(true)
        },
    );

    assert_eq!(reason, TickStop::Idle);
    let reads = reads.lock().unwrap();
    assert_eq!(reads.len(), 2);
    assert_eq!(reads[0].0, "omp");
    assert_eq!(
        reads[0].1,
        Some(SessionRef {
            kind: "id".into(),
            value: "session-1".into()
        })
    );
    assert_eq!(reads[0].2.as_deref(), Some("/work/api"));
    assert_eq!(reads[0].3, PANE);
    assert_eq!(sends.get(), 1, "only the first tick changed the steps");
    let stored = read_summary(&sb.config_dir.to_string_lossy(), PANE).unwrap();
    assert_eq!(
        stored["progress"],
        json!({ "done": 1, "total": 3, "phase": "implementing" })
    );
    assert_eq!(stored["summary"], "Refactoring the transport queue");
    assert_eq!(stored["hash"], "abc");
    assert!(!lock_path(&sb).exists(), "the lock is released");
}

// JS: "a plan that could not be read writes nothing; an estimate the refresh stored still pushes"
#[test]
fn a_plan_that_could_not_be_read_writes_nothing_an_estimate_the_refresh_stored_still_pushes() {
    let sb = sandbox();
    write_config(&sb, None, json!({}));
    sb.write_last_state(&json!({
        "statuses": { PANE: "working" }, "ended": false,
        "progress": { PANE: { "done": 1, "total": 5 } },
    }));
    write_record(&sb, "working", Some(json!({ "done": 2, "total": 5 })));
    sb.write_plan_steps(&json!({ PANE: { "done": 1, "total": 5 } }));
    let before = fs::read_to_string(summary_file(&sb)).unwrap();
    let herdr = FakeHerdr::new(vec![herdr_agent("working")]);
    let run = FakeRun::new(None, Some(&herdr));
    let sends = Cell::new(0);
    let reason = tick(
        &sb,
        &run,
        &plan(|_| {
            herdr.set_agents(vec![herdr_agent("done")]);
            PlanProgress::Unreadable
        }),
        &|_: &ProgressRequest<'_>, _: &ActivityDeps<'_>| {
            sends.set(sends.get() + 1);
            assert_eq!(
                read_plan_steps_file(&sb),
                json!({ PANE: { "done": 1, "total": 5 } }),
                "map untouched"
            );
            Ok(true)
        },
    );
    assert_eq!(reason, TickStop::Idle);
    assert_eq!(sends.get(), 1);
    assert_eq!(
        fs::read_to_string(summary_file(&sb)).unwrap(),
        before,
        "store untouched"
    );
}

// JS: "no plan this turn drops the steps (the phase stays) and the tick's own entry"
#[test]
fn no_plan_this_turn_drops_the_steps_the_phase_stays_and_the_ticks_own_entry() {
    let sb = sandbox();
    write_config(&sb, None, json!({}));
    sb.write_last_state(&json!({
        "statuses": { PANE: "working" }, "ended": false,
        "progress": { PANE: { "done": 1, "phase": "verifying", "total": 5 } },
    }));
    write_record(
        &sb,
        "working",
        Some(json!({ "done": 1, "total": 5, "phase": "verifying" })),
    );
    sb.write_plan_steps(&json!({ PANE: { "done": 1, "total": 5 } }));
    let herdr = FakeHerdr::new(vec![herdr_agent("working")]);
    let run = FakeRun::new(None, Some(&herdr));
    let sends = Cell::new(0);
    tick(
        &sb,
        &run,
        &plan(|_| {
            herdr.set_agents(vec![herdr_agent("blocked")]);
            PlanProgress::None
        }),
        &|_: &ProgressRequest<'_>, _: &ActivityDeps<'_>| {
            sends.set(sends.get() + 1);
            Ok(true)
        },
    );
    assert_eq!(
        read_summary(&sb.config_dir.to_string_lossy(), PANE).unwrap()["progress"],
        json!({ "phase": "verifying" })
    );
    assert_eq!(read_plan_steps_file(&sb), json!({}));
    assert_eq!(sends.get(), 1);
}

// JS: "pocket mode: with no Working record the tick's own map carries the steps and pushes them"
#[test]
fn pocket_mode_with_no_working_record_the_ticks_own_map_carries_the_steps_and_pushes_them() {
    let sb = sandbox();
    write_config(&sb, None, json!({}));
    sb.write_last_state(&json!({
        "statuses": { PANE: "working" }, "ended": false, "progress": {}, "visible": [PANE],
    }));
    write_record(&sb, "done", Some(json!({ "done": 9, "total": 9 })));
    let before = fs::read_to_string(summary_file(&sb)).unwrap();
    let herdr = FakeHerdr::new(vec![herdr_agent("working")]);
    let run = FakeRun::new(None, Some(&herdr));
    let sends = Cell::new(0);
    tick(
        &sb,
        &run,
        &plan(|_| {
            herdr.set_agents(vec![herdr_agent("blocked")]);
            steps(2, 6)
        }),
        &|_: &ProgressRequest<'_>, _: &ActivityDeps<'_>| {
            sends.set(sends.get() + 1);
            Ok(true)
        },
    );
    assert_eq!(sends.get(), 1);
    assert_eq!(
        read_plan_steps_file(&sb),
        json!({ PANE: { "done": 2, "total": 6 } }),
        "kept, frozen, while Blocked"
    );
    assert_eq!(
        fs::read_to_string(summary_file(&sb)).unwrap(),
        before,
        "no record or tombstone written"
    );
}

// JS: "an Agent the last push did not list never triggers a push"
#[test]
fn an_agent_the_last_push_did_not_list_never_triggers_a_push() {
    let sb = sandbox();
    write_config(&sb, None, json!({}));
    sb.write_last_state(&json!({
        "statuses": { PANE: "working" }, "ended": false, "progress": {}, "visible": ["w1:other"],
    }));
    let herdr = FakeHerdr::new(vec![herdr_agent("working")]);
    let run = FakeRun::new(None, Some(&herdr));
    let sends = Cell::new(0);
    tick(
        &sb,
        &run,
        &plan(|_| {
            herdr.set_agents(vec![herdr_agent("done")]);
            steps(2, 6)
        }),
        &|_: &ProgressRequest<'_>, _: &ActivityDeps<'_>| {
            sends.set(sends.get() + 1);
            Ok(true)
        },
    );
    assert_eq!(sends.get(), 0);
}

// JS: "steps of a pane whose turn ended or that its backend no longer lists are dropped"
#[test]
fn steps_of_a_pane_whose_turn_ended_or_that_its_backend_no_longer_lists_are_dropped() {
    let sb = sandbox();
    write_config(&sb, None, json!({ "tmux_enabled": false }));
    sb.write_last_state(&json!({ "statuses": { PANE: "working" }, "ended": false }));
    sb.write_plan_steps(&json!({
        PANE: { "done": 1, "total": 2 },
        "w1:gone": { "done": 1, "total": 2 },
        "tmux:%1": { "done": 1, "total": 2 },
    }));
    let herdr = FakeHerdr::new(vec![herdr_agent("idle")]);
    let run = FakeRun::new(None, Some(&herdr));
    tick(&sb, &run, &no_plan(), &noop_send);
    assert_eq!(
        read_plan_steps_file(&sb),
        json!({ "tmux:%1": { "done": 1, "total": 2 } }),
        "tmux was not listed"
    );
}

// JS: "exits when the episode ended, without reading plans"
#[test]
fn exits_when_the_episode_ended_without_reading_plans() {
    let sb = sandbox();
    write_config(&sb, None, json!({}));
    sb.write_last_state(&json!({ "statuses": {}, "ended": true }));
    let herdr = FakeHerdr::new(vec![herdr_agent("working")]);
    let run = FakeRun::new(None, Some(&herdr));
    let reads = Cell::new(0);
    let reason = tick(
        &sb,
        &run,
        &plan(|_| {
            reads.set(reads.get() + 1);
            PlanProgress::None
        }),
        &noop_send,
    );
    assert_eq!(reason, TickStop::Ended);
    assert_eq!(reads.get(), 0);
}

// JS: "exits when no episode was ever delivered or summaries are off"
#[test]
fn exits_when_no_episode_was_ever_delivered_or_summaries_are_off() {
    let sb = sandbox();
    write_config(&sb, None, json!({}));
    let herdr = FakeHerdr::new(vec![herdr_agent("working")]);
    let run = FakeRun::new(None, Some(&herdr));
    assert_eq!(tick(&sb, &run, &no_plan(), &noop_send), TickStop::Ended);
    sb.write_last_state(&json!({ "statuses": { PANE: "working" }, "ended": false }));
    write_config(&sb, None, json!({ "summary_enabled": false }));
    assert_eq!(tick(&sb, &run, &no_plan(), &noop_send), TickStop::Disabled);
}

// JS: "exits after the maximum run while Agents keep working"
#[test]
fn exits_after_the_maximum_run_while_agents_keep_working() {
    let sb = sandbox();
    write_config(&sb, None, json!({}));
    sb.write_last_state(&json!({ "statuses": { PANE: "working" }, "ended": false }));
    write_record(&sb, "working", None);
    let herdr = FakeHerdr::new(vec![herdr_agent("working")]);
    let run = FakeRun::new(None, Some(&herdr));
    let reads = Cell::new(0u64);
    let reason = tick(
        &sb,
        &run,
        &plan(|_| {
            reads.set(reads.get() + 1);
            PlanProgress::None
        }),
        &noop_send,
    );
    assert_eq!(reason, TickStop::Expired);
    assert_eq!(reads.get(), TICK_MAX_RUN_MS.div_ceil(TICK_INTERVAL_MS) - 1);
}

// JS: "a tmux list that failed (not 'no server') keeps tmux panes' frozen steps; no server prunes them"
#[test]
fn a_tmux_list_that_failed_not_no_server_keeps_tmux_panes_frozen_steps_no_server_prunes_them() {
    let sb = sandbox();
    write_config(&sb, None, json!({}));
    sb.write_last_state(&json!({ "statuses": { PANE: "working" }, "ended": false }));
    sb.write_plan_steps(&json!({ "tmux:%1": { "done": 1, "total": 2 } }));
    let herdr = FakeHerdr::new(vec![]);
    let failing_run = FakeRun::new(None, Some(&herdr));
    // tmux answers a failure that is not "no server running".
    let clock = FakeClock::new();
    let runner = |cmd: &str, args: &[&str], env: &Env| {
        if cmd == "tmux" {
            RunResult {
                stdout: String::new(),
                stderr: "lost server".into(),
                code: 1,
            }
        } else {
            failing_run.run(cmd, args, env)
        }
    };
    let herdr_cmd = HerdrCommand {
        bin: "herdr".into(),
        env: Env::default(),
    };
    let env = Env::default();
    let host = TickHost {
        config_dir: &sb.config_dir,
        state_dir: &sb.state_dir,
        herdr: &herdr_cmd,
        herdr_required: false,
        env: &env,
    };
    let fetch = FakeRelay::ok();
    let reader = no_plan();
    let deps = TickDeps {
        activity: ActivityDeps {
            fetch: &fetch,
            clock: &clock,
            run: &runner,
        },
        plan: &reader,
        send_update: &noop_send,
    };
    assert_eq!(run_activity_tick(&host, &deps).unwrap(), TickStop::Idle);
    assert_eq!(
        read_plan_steps_file(&sb),
        json!({ "tmux:%1": { "done": 1, "total": 2 } })
    );

    let no_server = FakeRun::new(None, Some(&herdr));
    assert_eq!(
        tick(&sb, &no_server, &no_plan(), &noop_send),
        TickStop::Idle
    );
    assert_eq!(read_plan_steps_file(&sb), json!({}));
}

// JS: "switching summaries off clears shown progress with one push, drops the tick's steps and exits"
#[test]
fn switching_summaries_off_clears_shown_progress_with_one_push_drops_the_ticks_steps_and_exits() {
    let sb = sandbox();
    write_config(&sb, None, json!({ "summary_enabled": false }));
    sb.write_last_state(&json!({
        "statuses": { PANE: "working" }, "ended": false,
        "progress": { PANE: { "done": 1, "total": 3 } },
    }));
    sb.write_plan_steps(&json!({ PANE: { "done": 1, "total": 3 } }));
    let herdr = FakeHerdr::new(vec![herdr_agent("working")]);
    let run = FakeRun::new(None, Some(&herdr));
    let sends = Cell::new(0);
    let reads = Cell::new(0);
    let count_send = |_: &ProgressRequest<'_>, _: &ActivityDeps<'_>| {
        sends.set(sends.get() + 1);
        Ok(true)
    };
    let reason = tick(
        &sb,
        &run,
        &plan(|_| {
            reads.set(reads.get() + 1);
            PlanProgress::None
        }),
        &count_send,
    );
    assert_eq!(reason, TickStop::Disabled);
    assert_eq!(sends.get(), 1);
    assert_eq!(reads.get(), 0);
    assert!(!sb.activity_dir().join("plan-steps.json").exists());

    sb.write_last_state(
        &json!({ "statuses": { PANE: "working" }, "ended": false, "progress": {} }),
    );
    assert_eq!(
        tick(&sb, &run, &UnreadablePlans, &count_send),
        TickStop::Disabled
    );
    assert_eq!(sends.get(), 1, "nothing shown, nothing to clear");
}

// JS: "the clearing push goes through the real flow at priority 5 without progress"
#[test]
fn the_clearing_push_goes_through_the_real_flow_at_priority_5_without_progress() {
    let sb = sandbox();
    write_config(
        &sb,
        Some("https://relay.invalid"),
        json!({ "summary_enabled": false }),
    );
    sb.write_registration(&[device()], json!({}));
    sb.write_last_state(&json!({
        "statuses": { PANE: "working" }, "idle": 0, "ended": false,
        "progress": { PANE: { "done": 1, "total": 3 } },
    }));
    write_record(&sb, "working", Some(json!({ "done": 1, "total": 3 })));
    let herdr = FakeHerdr::new(vec![herdr_agent("working")]);
    let run = FakeRun::new(None, Some(&herdr));
    let relay = FakeRelay::ok();
    assert_eq!(
        tick_full(&sb, &run, &UnreadablePlans, &run_progress_update, &relay),
        TickStop::Disabled
    );
    let pushes = relay.bodies();
    assert_eq!(pushes.len(), 1);
    assert_eq!(pushes[0]["priority"], 5);
    let payload = open_envelope(&pushes[0], &key_a());
    assert!(payload["agents"][0].get("progress").is_none());
}

// JS: "respects tmux_enabled: tmux Agents are read only while tmux is on"
#[test]
fn respects_tmux_enabled_tmux_agents_are_read_only_while_tmux_is_on() {
    let sb = sandbox();
    sb.write_last_state(&json!({ "statuses": { PANE: "working" }, "ended": false }));
    write_config(&sb, None, json!({ "tmux_enabled": false }));
    let herdr = FakeHerdr::new(vec![]);
    let off = FakeRun::new(None, Some(&herdr));
    assert_eq!(tick(&sb, &off, &no_plan(), &noop_send), TickStop::Idle);
    assert!(!off.called("tmux"));

    write_config(&sb, None, json!({}));
    let on = FakeRun::new(None, Some(&herdr));
    assert_eq!(tick(&sb, &on, &no_plan(), &noop_send), TickStop::Idle);
    assert!(on.called("tmux"));
}

/// A Host with core installed and listening: `(listener, env)`; the listener
/// must outlive the tick.
fn core_host(sb: &Sandbox) -> (std::os::unix::net::UnixListener, Env) {
    sb.core_env()
}

fn core_working(address: &str, labels: Value) -> Value {
    core_record(
        address,
        Some("working"),
        json!({ "labels": labels, "turn": 1 }),
    )
}

/// Plan steps of every pane the retention tests start with.
fn all_panes_have_steps(sb: &Sandbox) {
    sb.write_plan_steps(&json!({
        PANE: { "done": 1, "total": 2 },
        "w1:gone": { "done": 1, "total": 2 },
        "tmux:%1": { "done": 1, "total": 2 },
        "hc:t1": { "done": 1, "total": 2 },
        "hc:t2": { "done": 1, "total": 2 },
        "hc:t3": { "done": 1, "total": 2 },
        "hc:t9": { "done": 1, "total": 2 },
    }));
}

#[test]
fn core_panes_are_their_own_retention_bucket_while_herdr_and_tmux_keep_theirs() {
    let sb = sandbox();
    write_config(&sb, None, json!({ "tmux_enabled": false }));
    sb.write_last_state(&json!({ "statuses": { PANE: "working" }, "ended": false }));
    all_panes_have_steps(&sb);
    let herdr = FakeHerdr::new(vec![herdr_agent("idle")]);
    // t1 works, t2 is blocked (frozen), t3 finished its turn (done); t9 is gone.
    let core = FakeCore::new(vec![
        core_working("t1", json!({})),
        core_record("t2", Some("blocked"), json!({})),
        core_record("t3", Some("done"), json!({})),
    ]);
    let run = FakeRun::new(None, Some(&herdr)).with_core(&core);
    let (_listener, env) = core_host(&sb);

    let reason = tick_in(
        &sb,
        &run,
        &plan(|_| PlanProgress::Unreadable),
        &noop_send,
        &FakeRelay::ok(),
        &env,
    );

    assert_eq!(reason, TickStop::Expired);
    // herdr's idle pane, herdr's unlisted pane, core's done and unlisted
    // panes lose their steps; core's working and blocked panes keep theirs,
    // and tmux (off) was not listed, so its pane keeps its too.
    assert_eq!(
        read_plan_steps_file(&sb),
        json!({
            "tmux:%1": { "done": 1, "total": 2 },
            "hc:t1": { "done": 1, "total": 2 },
            "hc:t2": { "done": 1, "total": 2 },
        })
    );
}

#[test]
fn core_panes_keep_their_steps_when_core_is_off_stopped_cannot_list_or_is_in_a_named_session() {
    for case in ["core off", "not running", "cannot list", "named session"] {
        let sb = sandbox();
        write_config(
            &sb,
            None,
            json!({ "tmux_enabled": false, "core_enabled": case != "core off" }),
        );
        sb.write_last_state(&json!({ "statuses": { PANE: "working" }, "ended": false }));
        all_panes_have_steps(&sb);
        let herdr = FakeHerdr::new(vec![herdr_agent("idle")]);
        let core = FakeCore::new(vec![core_working("t1", json!({}))]);
        core.set_down(case == "cannot list");
        let run = FakeRun::new(None, Some(&herdr)).with_core(&core);
        let (listener, mut env) = core_host(&sb);
        match case {
            "not running" => drop(listener),
            "named session" => env.set("HC_SESSION", "lab"),
            _ => {}
        }

        let reason = tick_in(
            &sb,
            &run,
            &plan(|_| PlanProgress::Unreadable),
            &noop_send,
            &FakeRelay::ok(),
            &env,
        );

        // Only herdr answered: the herdr bucket loses its panes, nothing else.
        assert_eq!(reason, TickStop::Idle, "{case}");
        let steps = read_plan_steps_file(&sb);
        for pane in ["tmux:%1", "hc:t1", "hc:t2", "hc:t3", "hc:t9"] {
            assert!(steps.get(pane).is_some(), "{case}: {pane}");
        }
        for pane in [PANE, "w1:gone"] {
            assert!(steps.get(pane).is_none(), "{case}: {pane}");
        }
        let asked: Vec<Vec<String>> = core
            .invocation_args()
            .into_iter()
            .filter(|args| args[0] != "--version")
            .collect();
        match case {
            "cannot list" => assert_eq!(asked.len(), 1, "{case}: {asked:?}"),
            _ => assert!(asked.is_empty(), "{case}: {asked:?}"),
        }
    }
}

#[test]
fn a_working_core_terminal_is_read_by_its_label_kind_its_folder_and_its_session_labels() {
    let sb = sandbox();
    write_config(&sb, None, json!({ "tmux_enabled": false }));
    sb.write_last_state(&json!({ "statuses": { "hc:t1": "working" }, "ended": false }));
    let herdr = FakeHerdr::new(vec![]);
    let core = FakeCore::new(vec![
        core_working(
            "t1",
            json!({ "waycar.kind": "omp", "waycar.session": "/s/one.jsonl" }),
        ),
        core_working("t2", json!({ "waycar.session": "abc" })),
        // Not an Agent that reported: never read.
        core_record("t3", None, json!({})),
    ]);
    let run = FakeRun::new(None, Some(&herdr)).with_core(&core);
    let (_listener, env) = core_host(&sb);
    let reads: Mutex<Vec<ReadSeen>> = Mutex::default();

    tick_in(
        &sb,
        &run,
        &plan(|request| {
            reads.lock().unwrap().push((
                request.agent.to_string(),
                request.session.cloned(),
                request.cwd.map(str::to_string),
                request.pane_id.to_string(),
            ));
            assert_eq!(request.terminal_id, None);
            PlanProgress::Unreadable
        }),
        &noop_send,
        &FakeRelay::ok(),
        &env,
    );

    let reads = reads.lock().unwrap();
    let session = |kind: &str, value: &str| {
        Some(SessionRef {
            kind: kind.into(),
            value: value.into(),
        })
    };
    assert_eq!(
        reads[..2],
        [
            (
                "omp".to_string(),
                session("path", "/s/one.jsonl"),
                Some("/work/api".to_string()),
                "hc:t1".to_string()
            ),
            (
                "claude".to_string(),
                session("id", "abc"),
                Some("/work/api".to_string()),
                "hc:t2".to_string()
            ),
        ]
    );
    assert!(reads.iter().all(|read| read.3 != "hc:t3"));
}

#[test]
fn a_core_terminal_that_stopped_working_between_the_listing_and_its_record_is_not_read() {
    let sb = sandbox();
    write_config(&sb, None, json!({ "tmux_enabled": false }));
    sb.write_last_state(&json!({ "statuses": { "hc:t1": "working" }, "ended": false }));
    sb.write_plan_steps(&json!({ "hc:t1": { "done": 1, "total": 2 } }));
    let herdr = FakeHerdr::new(vec![]);
    let core = FakeCore::new(vec![core_record("t1", Some("done"), json!({}))]);
    core.set_listed(vec![core_working("t1", json!({}))]);
    let run = FakeRun::new(None, Some(&herdr)).with_core(&core);
    let (_listener, env) = core_host(&sb);
    let reads = Cell::new(0);

    let reason = tick_in(
        &sb,
        &run,
        &plan(|_| {
            reads.set(reads.get() + 1);
            PlanProgress::Unreadable
        }),
        &noop_send,
        &FakeRelay::ok(),
        &env,
    );

    assert_eq!(reason, TickStop::Idle);
    assert_eq!(reads.get(), 0);
    // The record's own status, done, ended its turn: the steps go.
    assert_eq!(read_plan_steps_file(&sb), json!({}));
}

// JS: "never invokes the summary model, end to end through the real send flow"
// (Rust has no model seam: the marker script is configured and must never be
// spawned.)
#[test]
fn never_invokes_the_summary_model_end_to_end_through_the_real_send_flow() {
    let sb = sandbox();
    let marker = sb.home().join("model-called");
    write_config(
        &sb,
        Some("https://relay.invalid"),
        json!({ "summary_command": ["/bin/sh", "-c", format!("touch '{}'", marker.display())] }),
    );
    sb.write_registration(&[device()], json!({}));
    sb.write_last_state(&json!({
        "statuses": { PANE: "working" }, "idle": 0, "ended": false, "progress": {},
    }));
    write_record(&sb, "working", None);
    let herdr = FakeHerdr::new(vec![herdr_agent("working")]);
    let run = FakeRun::new(None, Some(&herdr));
    let relay = FakeRelay::ok();

    let reason = tick_full(
        &sb,
        &run,
        &plan(|_| {
            herdr.set_agents(vec![herdr_agent(if relay.count() > 0 {
                "done"
            } else {
                "working"
            })]);
            steps(2, 5)
        }),
        &run_progress_update,
        &relay,
    );

    assert_eq!(reason, TickStop::Idle);
    assert!(!marker.exists(), "no summary command ran");
    let pushes = relay.bodies();
    assert_eq!(pushes.len(), 1);
    assert_eq!(pushes[0]["priority"], 5);
    assert_eq!(pushes[0]["event"], "update");
    let payload = open_envelope(&pushes[0], &key_a());
    assert_eq!(
        payload["agents"][0]["progress"],
        json!({ "done": 2, "total": 5 })
    );
    assert_eq!(
        read_summary(&sb.config_dir.to_string_lossy(), PANE).unwrap()["summary"],
        "Refactoring the transport queue"
    );
}

// ---- suite: activity-tick: heartbeat ----------------------------------------

// JS: "each tick refreshes the lock; a tick whose lock was taken over stops"
#[test]
fn each_tick_refreshes_the_lock_a_tick_whose_lock_was_taken_over_stops() {
    let sb = sandbox();
    write_config(&sb, None, json!({}));
    sb.write_last_state(&json!({ "statuses": { PANE: "working" }, "ended": false }));
    write_record(&sb, "working", None);
    let herdr = FakeHerdr::new(vec![herdr_agent("working")]);
    let run = FakeRun::new(None, Some(&herdr));
    let ppid = std::os::unix::process::parent_id();
    let seen: Mutex<Vec<u64>> = Mutex::default();
    let reason = tick(
        &sb,
        &run,
        &plan(|_| {
            let mut seen = seen.lock().unwrap();
            seen.push(read_lock_json(&sb)["ts"].as_u64().unwrap());
            if seen.len() == 2 {
                write_lock(&sb, ppid, SystemClock.now_ms());
            }
            PlanProgress::None
        }),
        &noop_send,
    );
    assert_eq!(reason, TickStop::Locked);
    let seen = seen.lock().unwrap();
    assert_eq!(seen.len(), 2);
    assert_eq!(
        seen[1] - seen[0],
        TICK_INTERVAL_MS,
        "the heartbeat follows the clock"
    );
    assert_eq!(
        read_lock_json(&sb)["pid"],
        ppid,
        "the new holder's lock stays"
    );
}

#[test]
fn a_lock_taken_over_between_two_agents_stops_before_the_second_read() {
    let sb = sandbox();
    write_config(&sb, None, json!({}));
    sb.write_last_state(&json!({ "statuses": { PANE: "working" }, "ended": false }));
    let mut second = herdr_agent("working");
    second["pane_id"] = json!("w1:p9");
    let herdr = FakeHerdr::new(vec![herdr_agent("working"), second]);
    let run = FakeRun::new(None, Some(&herdr));
    let ppid = std::os::unix::process::parent_id();
    let reads: Mutex<Vec<String>> = Mutex::default();
    let sends = Cell::new(0);
    let reason = tick(
        &sb,
        &run,
        &plan(|request| {
            reads.lock().unwrap().push(request.pane_id.to_string());
            write_lock(&sb, ppid, SystemClock.now_ms());
            steps(1, 2)
        }),
        &|_: &ProgressRequest<'_>, _: &ActivityDeps<'_>| {
            sends.set(sends.get() + 1);
            Ok(true)
        },
    );
    assert_eq!(reason, TickStop::Locked);
    assert_eq!(*reads.lock().unwrap(), [PANE]);
    assert_eq!(sends.get(), 0);
    // The first read's steps were still written.
    assert_eq!(
        read_plan_steps_file(&sb)[PANE],
        json!({ "done": 1, "total": 2 })
    );
}

#[test]
fn a_lock_taken_over_during_the_push_stops_after_it() {
    let sb = sandbox();
    write_config(&sb, None, json!({}));
    sb.write_last_state(&json!({ "statuses": { PANE: "working" }, "ended": false }));
    write_record(&sb, "working", None);
    let herdr = FakeHerdr::new(vec![herdr_agent("working")]);
    let run = FakeRun::new(None, Some(&herdr));
    let ppid = std::os::unix::process::parent_id();
    let reads = Cell::new(0);
    let sends = Cell::new(0);
    let reason = tick(
        &sb,
        &run,
        &plan(|_| {
            reads.set(reads.get() + 1);
            steps(1, 2)
        }),
        &|_: &ProgressRequest<'_>, _: &ActivityDeps<'_>| {
            sends.set(sends.get() + 1);
            write_lock(&sb, ppid, SystemClock.now_ms());
            Ok(true)
        },
    );
    assert_eq!(reason, TickStop::Locked);
    assert_eq!((reads.get(), sends.get()), (1, 1));
    assert_eq!(read_lock_json(&sb)["pid"], ppid);
}

// JS: "a live pid with an old heartbeat (pid reused after a crash) is taken over"
#[test]
fn a_live_pid_with_an_old_heartbeat_pid_reused_after_a_crash_is_taken_over() {
    let sb = sandbox();
    let ppid = std::os::unix::process::parent_id();
    write_lock(&sb, ppid, SystemClock.now_ms());
    assert!(!acquire_tick_lock(&sb.state_dir, SystemClock.now_ms()).unwrap());
    let now = SystemClock.now_ms();
    write_lock(&sb, ppid, now - TICK_LOCK_STALE_MS - 1);
    assert!(acquire_tick_lock(&sb.state_dir, now).unwrap());
    const {
        assert!(
            TICK_LOCK_STALE_MS < 6 * 60_000,
            "a stale lock blocks ticks for minutes, not hours"
        );
    }
    release_tick_lock(&sb.state_dir);
}

// ---- suite: activity-tick: single instance ----------------------------------

// JS: "a live holder keeps a second tick from running; a dead holder's lock is taken over"
#[test]
fn a_live_holder_keeps_a_second_tick_from_running_a_dead_holders_lock_is_taken_over() {
    let sb = sandbox();
    write_config(&sb, None, json!({}));
    sb.write_last_state(&json!({ "statuses": {}, "ended": true }));
    assert!(acquire_tick_lock(&sb.state_dir, SystemClock.now_ms()).unwrap());
    let herdr = FakeHerdr::new(vec![]);
    let run = FakeRun::new(None, Some(&herdr));
    let reads = Cell::new(0);
    assert_eq!(
        tick(
            &sb,
            &run,
            &plan(|_| {
                reads.set(reads.get() + 1);
                PlanProgress::None
            }),
            &noop_send,
        ),
        TickStop::Locked
    );
    assert_eq!(reads.get(), 0);
    release_tick_lock(&sb.state_dir);

    write_lock(&sb, 1 << 30, SystemClock.now_ms());
    assert!(acquire_tick_lock(&sb.state_dir, SystemClock.now_ms()).unwrap());
    assert_eq!(read_lock_json(&sb)["pid"], std::process::id());
    release_tick_lock(&sb.state_dir);
    assert!(!lock_path(&sb).exists());
}

// JS: "ensureActivityTick spawns a detached tick only while none is running"
#[test]
fn ensure_activity_tick_spawns_a_detached_tick_only_while_none_is_running() {
    let sb = sandbox();
    let env = Env::from_pairs([("A", "1")]);
    let spawned: Mutex<Vec<(Vec<String>, Env)>> = Mutex::default();
    let spawn = |launch: &TickLaunch<'_>| {
        spawned
            .lock()
            .unwrap()
            .push((launch.argv.to_vec(), launch.env.clone()));
    };
    let start = TickStart {
        config_dir: &sb.config_dir,
        state_dir: &sb.state_dir,
        herdr_bin: "/opt/herdr",
        herdr_required: true,
        env: &env,
    };

    assert!(ensure_activity_tick(&start, SystemClock.now_ms(), &spawn));
    {
        let spawned = spawned.lock().unwrap();
        assert_eq!(spawned.len(), 1);
        let (argv, spawn_env) = &spawned[0];
        assert_eq!(argv.len(), 2);
        assert_eq!(argv[0], TICK_SUBCOMMAND);
        assert_eq!(
            serde_json::from_str::<Value>(&argv[1]).unwrap(),
            json!({
                "configDir": sb.config_dir.to_str().unwrap(),
                "stateDir": sb.state_dir.to_str().unwrap(),
                "herdrBin": "/opt/herdr",
                "herdrRequired": true,
            })
        );
        // `JSON.stringify` of the keys in this order.
        assert_eq!(
            argv[1],
            format!(
                r#"{{"configDir":{},"stateDir":{},"herdrBin":"/opt/herdr","herdrRequired":true}}"#,
                serde_json::to_string(sb.config_dir.to_str().unwrap()).unwrap(),
                serde_json::to_string(sb.state_dir.to_str().unwrap()).unwrap(),
            )
        );
        assert_eq!(*spawn_env, env);
    }

    assert!(acquire_tick_lock(&sb.state_dir, SystemClock.now_ms()).unwrap());
    assert!(!ensure_activity_tick(&start, SystemClock.now_ms(), &spawn));
    assert_eq!(spawned.lock().unwrap().len(), 1);
    release_tick_lock(&sb.state_dir);
}

// ---- Rust-only ---------------------------------------------------------------

#[test]
fn rust_main_reports_a_missing_or_bad_options_argument_as_exit_1() {
    let clock = FakeClock::new();
    let run = FakeRun::new(None, None);
    let runner = |cmd: &str, args: &[&str], env: &Env| run.run(cmd, args, env);
    let fetch = FakeRelay::ok();
    let deps = TickDeps {
        activity: ActivityDeps {
            fetch: &fetch,
            clock: &clock,
            run: &runner,
        },
        plan: &UnreadablePlans,
        send_update: &noop_send,
    };
    let env = Env::default();
    let missing = run_activity_tick_main(None, &env, &deps);
    assert_eq!(missing.code, 1);
    assert_eq!(missing.stderr, "activity-tick: configDir missing\n");
    let empty = run_activity_tick_main(Some("{}"), &env, &deps);
    assert_eq!(empty.code, 1);
    assert_eq!(empty.stderr, "activity-tick: configDir missing\n");
    let no_state = run_activity_tick_main(Some(r#"{"configDir":"/c"}"#), &env, &deps);
    assert_eq!(no_state.stderr, "activity-tick: stateDir missing\n");
    let bad = run_activity_tick_main(Some("{"), &env, &deps);
    assert_eq!(bad.code, 1);
    assert!(bad.stderr.starts_with("activity-tick: "));
    assert!(bad.stderr.ends_with('\n'));
}

#[test]
fn rust_main_with_a_valid_argument_and_an_ended_episode_exits_0() {
    let sb = sandbox();
    write_config(&sb, None, json!({}));
    sb.write_last_state(&json!({ "statuses": {}, "ended": true }));
    let clock = FakeClock::new();
    let run = FakeRun::new(None, None);
    let runner = |cmd: &str, args: &[&str], env: &Env| run.run(cmd, args, env);
    let fetch = FakeRelay::ok();
    let deps = TickDeps {
        activity: ActivityDeps {
            fetch: &fetch,
            clock: &clock,
            run: &runner,
        },
        plan: &UnreadablePlans,
        send_update: &noop_send,
    };
    let options = json!({
        "configDir": sb.config_dir.to_str().unwrap(),
        "stateDir": sb.state_dir.to_str().unwrap(),
        "herdrBin": "herdr",
        "herdrRequired": false,
    })
    .to_string();
    let outcome = run_activity_tick_main(Some(&options), &Env::default(), &deps);
    assert_eq!(outcome.code, 0);
    assert_eq!(outcome.stderr, "");
    assert!(!lock_path(&sb).exists(), "the lock is released");
}

#[test]
fn rust_transcript_plan_reader_has_no_plan_for_a_kind_without_plan_tools() {
    let env = Env::default();
    let request = PlanRequest {
        agent: "gemini",
        session: None,
        cwd: None,
        pane_id: PANE,
        config_dir: Path::new("/c"),
        terminal_id: None,
        env: &env,
        deadline_ms: 0,
        timeout: Duration::from_millis(1),
    };
    assert_eq!(TranscriptPlanReader.read_plan(&request), PlanProgress::None);
}
