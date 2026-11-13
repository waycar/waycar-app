//! The herdr-core trigger (`waycar notify --pane hc:<address>`): the same flow
//! as the tmux trigger with core's record as the re-check, and core's share of
//! the Attention Badge and of the Chat Marker collection in the other triggers.

use std::rc::Rc;

use serde_json::{Value, json};

use super::*;
use crate::notify_fake::rig::*;
use crate::notify_fake::{FakeHost, TmuxPane};

/// A Host with core only: one terminal `t1` reporting `status`, configured,
/// with a device registered, `herdr-core` installed and a core listening (the
/// hook runs inside one, and nothing here may start one).
fn core_rig(status: Option<&str>) -> Rig {
    let rig = Rig::tmux();
    rig.write_config(json!({}));
    rig.write_registration(&[device()]);
    rig.install_core();
    rig.core_running();
    *rig.host.core_terminals.borrow_mut() = vec![core_record("t1", status, 0)];
    rig
}

/// Change the record of `t1` the way a running agent would.
fn update(host: &FakeHost, change: impl FnOnce(&mut Value)) {
    change(&mut host.core_terminals.borrow_mut()[0]);
}

fn report(host: &FakeHost, status: &str, turn: u64) {
    update(host, |record| {
        record["status"]["state"] = json!(status);
        record["turn"] = json!(turn);
    });
}

fn notified(rig: &Rig, status: &str) {
    let (result, stderr) = rig.notify_core("hc:t1", status);
    result.unwrap_or_else(|error| panic!("{error}: {stderr}"));
}

fn post_count(rig: &Rig) -> usize {
    rig.relay.posts().len()
}

/// The arguments after `subcommand` of each herdr-core call to it.
fn core_args(rig: &Rig, subcommand: &str) -> Vec<String> {
    rig.host
        .core_calls(Some(subcommand))
        .iter()
        .map(|call| call.args[1..].join(" "))
        .collect()
}

// ---- the flow --------------------------------------------------------------------

#[test]
fn a_status_that_holds_posts_the_core_terminal_with_its_kind_folder_and_name() {
    let rig = core_rig(Some("blocked"));
    let seen = Rc::new(std::cell::RefCell::new(Vec::new()));
    let (host, log) = (Rc::clone(&rig.host), Rc::clone(&seen));
    rig.clock
        .on_sleep(move || log.borrow_mut().push(host.core_calls(Some("get")).len()));

    notified(&rig, "blocked");

    assert_eq!(post_count(&rig), 1);
    let (_, payload) = rig.payload(0, &key_a());
    assert_eq!(payload["pane"], "hc:t1");
    assert_eq!(payload["kind"], "claude");
    assert_eq!(payload["status"], "blocked");
    assert_eq!(payload["project"], "proj");
    assert_eq!(payload["title"], "fix-auth");
    assert_eq!(payload["attention"], 1);
    // The record is read after the hold, never before.
    assert_eq!(*seen.borrow(), vec![0]);
    assert_eq!(core_args(&rig, "get"), ["t1 --json"]);
    assert_eq!(rig.clock.sleeps(), vec![Duration::from_millis(DEBOUNCE_MS)]);
}

#[test]
fn done_working_done_pushes_twice() {
    let rig = core_rig(Some("done"));
    notified(&rig, "done");
    report(&rig.host, "working", 0);
    notified(&rig, "working");
    report(&rig.host, "done", 1);
    notified(&rig, "done");

    assert_eq!(post_count(&rig), 2);
    for index in 0..2 {
        assert_eq!(rig.payload(index, &key_a()).1["status"], "done");
    }
}

#[test]
fn a_done_that_was_pushed_is_not_pushed_again() {
    let rig = core_rig(Some("done"));
    notified(&rig, "done");
    notified(&rig, "done");

    assert_eq!(post_count(&rig), 1);
}

#[test]
fn release_rearms_the_terminal_for_the_next_agent_in_it() {
    let rig = core_rig(Some("blocked"));
    notified(&rig, "blocked");
    assert_eq!(post_count(&rig), 1);

    notified(&rig, "release");
    notified(&rig, "blocked");

    assert_eq!(post_count(&rig), 2);
    // Release never asked core and never held.
    assert_eq!(core_args(&rig, "get").len(), 2);
}

#[test]
fn release_clears_the_marker_even_when_core_is_disabled_or_missing() {
    let rig = core_rig(Some("blocked"));
    notified(&rig, "blocked");
    assert!(state_path(&rig.state_dir, "hc:t1").exists());

    rig.write_config(json!({"core_enabled": false}));
    notified(&rig, "release");

    assert!(!state_path(&rig.state_dir, "hc:t1").exists());
}

#[test]
fn a_status_that_moved_on_during_the_hold_sends_nothing() {
    let rig = core_rig(Some("blocked"));
    let host = Rc::clone(&rig.host);
    rig.clock.on_sleep(move || report(&host, "working", 0));

    notified(&rig, "blocked");

    assert_eq!(post_count(&rig), 0);
}

#[test]
fn an_agent_gone_by_the_recheck_sends_nothing() {
    let rig = core_rig(Some("done"));
    let host = Rc::clone(&rig.host);
    rig.clock
        .on_sleep(move || host.core_terminals.borrow_mut().clear());

    notified(&rig, "done");

    assert_eq!(post_count(&rig), 0);
}

#[test]
fn a_finished_terminal_sends_nothing_and_a_change_that_finds_it_rearms_the_pane() {
    let rig = core_rig(Some("done"));
    notified(&rig, "done");
    assert_eq!(post_count(&rig), 1);

    update(&rig.host, |record| record["state"] = json!("finished"));
    notified(&rig, "idle");
    update(&rig.host, |record| record["state"] = json!("live"));
    notified(&rig, "done");

    assert_eq!(post_count(&rig), 2);
}

#[test]
fn a_core_that_cannot_answer_the_recheck_fails_the_run_closed() {
    let rig = core_rig(Some("blocked"));
    let host = Rc::clone(&rig.host);
    rig.clock.on_sleep(move || host.core_down.set(Some(1)));

    let (result, _) = rig.notify_core("hc:t1", "blocked");

    let error = result.unwrap_err();
    assert!(
        error.message().contains("herdr-core get failed (exit 1)"),
        "{error}"
    );
    assert_eq!(post_count(&rig), 0);
}

#[test]
fn core_enabled_false_sends_nothing_and_never_calls_herdr_core() {
    let rig = core_rig(Some("blocked"));
    rig.write_config(json!({"core_enabled": false}));

    notified(&rig, "blocked");

    assert_eq!(post_count(&rig), 0);
    assert!(rig.host.core_calls(None).is_empty());
    assert!(rig.clock.sleeps().is_empty());
}

#[test]
fn a_named_core_session_sends_nothing_because_its_addresses_repeat() {
    let rig = core_rig(Some("blocked"));
    let mut env = rig.core_env();
    env.set("HC_SESSION", "lab");

    let (result, _) = rig.notify_core_with(&env, "hc:t1", "blocked");

    result.unwrap();
    assert_eq!(post_count(&rig), 0);
    assert!(rig.host.core_calls(None).is_empty());
}

#[test]
fn a_host_without_herdr_core_reports_it_instead_of_staying_silent() {
    let rig = Rig::tmux();
    rig.write_config(json!({}));
    rig.write_registration(&[device()]);

    let (result, _) = rig.notify_core("hc:t1", "blocked");

    assert_eq!(
        result.unwrap_err().message(),
        "no herdr-core is running on this Host"
    );
    assert_eq!(post_count(&rig), 0);
}

// Every `hc` subcommand starts a core with the caller's environment: a core
// that is installed but not listening is never asked, not even its version.
#[test]
fn an_installed_core_that_is_not_listening_is_never_asked() {
    let rig = core_rig(Some("blocked"));
    rig.core_stopped();

    let (result, _) = rig.notify_core("hc:t1", "blocked");

    assert_eq!(
        result.unwrap_err().message(),
        "no herdr-core is running on this Host"
    );
    assert!(rig.host.core_calls(None).is_empty());
    assert_eq!(post_count(&rig), 0);
}

#[test]
fn bad_arguments_are_rejected_before_anything_runs() {
    let rig = core_rig(Some("blocked"));
    for (pane, status, message) in [
        (
            "tmux:%3",
            "blocked",
            "not a herdr-core terminal id: tmux:%3",
        ),
        ("t1", "blocked", "not a herdr-core terminal id: t1"),
        ("hc:", "blocked", "not a herdr-core terminal id: hc:"),
        ("hc:t1", "sleeping", "unknown status: sleeping"),
    ] {
        let (result, _) = rig.notify_core(pane, status);
        assert_eq!(result.unwrap_err().message(), message);
    }
    assert!(rig.host.core_calls(None).is_empty());
}

#[test]
fn the_status_is_case_insensitive() {
    let rig = core_rig(Some("done"));
    let (result, stderr) = rig.notify_core("hc:t1", "DONE");
    result.unwrap_or_else(|error| panic!("{error}: {stderr}"));

    assert_eq!(post_count(&rig), 1);
}

#[test]
fn the_hooks_environment_picks_the_core_that_runs_the_terminal() {
    let rig = core_rig(Some("blocked"));
    // The terminal's own core listens elsewhere than the default socket.
    let own = rig
        .path("own/herdr-core/default.sock")
        .to_string_lossy()
        .into_owned();
    std::fs::create_dir_all(std::path::Path::new(&own).parent().unwrap()).unwrap();
    let _listener = std::os::unix::net::UnixListener::bind(&own).unwrap();
    let mut env = rig.core_env();
    env.set("HC_TERMINAL_SOCKET", own.as_str());

    let (result, _) = rig.notify_core_with(&env, "hc:t1", "blocked");

    result.unwrap();
    let calls = rig.host.core_calls(None);
    assert!(!calls.is_empty());
    assert!(
        calls
            .iter()
            .all(|call| call.env.get("HC_SOCKET") == Some(own.as_str()))
    );
}

// ---- what core reports -------------------------------------------------------------

#[test]
fn idle_after_a_turn_the_hook_saw_start_counts_as_done() {
    let rig = core_rig(Some("working"));
    // The hook wrote `working` while the terminal had finished one turn.
    update(&rig.host, |record| {
        record["labels"]["waycar.turn"] = json!("1");
    });
    report(&rig.host, "idle", 2);

    notified(&rig, "done");

    assert_eq!(post_count(&rig), 1);
    assert_eq!(rig.payload(0, &key_a()).1["status"], "done");
}

#[test]
fn idle_that_is_not_past_the_recorded_turn_is_not_done() {
    let rig = core_rig(Some("idle"));
    update(&rig.host, |record| {
        record["labels"]["waycar.turn"] = json!("2");
        record["turn"] = json!(2);
    });

    notified(&rig, "done");

    assert_eq!(post_count(&rig), 0);
}

#[test]
fn without_a_turn_label_idle_after_any_turn_is_done() {
    let rig = core_rig(Some("idle"));
    update(&rig.host, |record| record["turn"] = json!(1));
    notified(&rig, "done");
    assert_eq!(post_count(&rig), 1);

    let never_worked = core_rig(Some("idle"));
    notified(&never_worked, "done");
    assert_eq!(post_count(&never_worked), 0);
}

#[test]
fn a_turn_label_that_is_not_a_number_counts_as_none() {
    let rig = core_rig(Some("idle"));
    update(&rig.host, |record| {
        record["labels"]["waycar.turn"] = json!("soon");
        record["turn"] = json!(1);
    });

    notified(&rig, "done");

    assert_eq!(post_count(&rig), 1);
}

#[test]
fn idle_still_confirms_idle_and_a_working_hook_is_never_matched_by_idle() {
    let rig = core_rig(Some("done"));
    notified(&rig, "done");
    // The app's own `idle` event re-arms the pane when core says idle.
    report(&rig.host, "idle", 1);
    notified(&rig, "idle");
    assert!(!state_path(&rig.state_dir, "hc:t1").exists());

    // `idle` never stands in for anything but `done`.
    let blocked = core_rig(Some("idle"));
    update(&blocked.host, |record| record["turn"] = json!(3));
    notified(&blocked, "blocked");
    assert_eq!(post_count(&blocked), 0);
}

#[test]
fn error_reads_as_blocked() {
    let rig = core_rig(Some("error"));

    notified(&rig, "blocked");

    assert_eq!(post_count(&rig), 1);
    assert_eq!(rig.payload(0, &key_a()).1["status"], "blocked");
}

#[test]
fn a_status_word_waycar_does_not_know_matches_nothing() {
    let rig = core_rig(Some("thinking"));

    notified(&rig, "blocked");

    assert_eq!(post_count(&rig), 0);
}

#[test]
fn an_agent_that_never_reported_trusts_the_hook() {
    let rig = core_rig(None);

    notified(&rig, "blocked");

    assert_eq!(post_count(&rig), 1);
    let (_, payload) = rig.payload(0, &key_a());
    assert_eq!(payload["status"], "blocked");
    // No report, no app name: the kind is unknown unless a hook labelled it.
    assert_eq!(payload["kind"], "unknown");
}

// A hook that moved the status on during the hold wins for an agent that never
// reports, as the pane option does for tmux: a quick approval must not push a
// stale Blocked.
#[test]
fn a_later_hook_during_the_hold_drops_the_stale_event_of_a_non_reporting_agent() {
    let rig = core_rig(None);
    update(&rig.host, |record| {
        record["labels"]["waycar.status"] = json!("blocked");
    });
    let host = Rc::clone(&rig.host);
    rig.clock.on_sleep(move || {
        update(&host, |record| {
            record["labels"]["waycar.status"] = json!("working");
        });
    });

    notified(&rig, "blocked");

    assert_eq!(post_count(&rig), 0);

    // The label the hook wrote for this very event confirms it.
    let rig = core_rig(None);
    update(&rig.host, |record| {
        record["labels"]["waycar.status"] = json!("blocked");
    });
    notified(&rig, "blocked");
    assert_eq!(post_count(&rig), 1);
}

#[test]
fn a_terminal_with_a_report_but_no_status_trusts_the_hook() {
    let rig = core_rig(Some("working"));
    update(&rig.host, |record| record["status"] = Value::Null);

    notified(&rig, "done");

    assert_eq!(post_count(&rig), 1);
}

#[test]
fn the_kind_label_a_hook_wrote_names_the_agent() {
    let rig = core_rig(None);
    update(&rig.host, |record| {
        record["labels"]["waycar.kind"] = json!("codex");
    });

    notified(&rig, "done");

    assert_eq!(rig.payload(0, &key_a()).1["kind"], "codex");
}

// ---- project and title ---------------------------------------------------------------

fn described(rig: &Rig) -> (Value, Value) {
    notified(rig, "blocked");
    let (_, payload) = rig.payload(0, &key_a());
    (payload["project"].clone(), payload["title"].clone())
}

#[test]
fn the_title_is_the_given_name_then_the_agents_task_title_then_the_terminal_title() {
    let rig = core_rig(Some("blocked"));
    update(&rig.host, |record| {
        record["status"]["title"] = json!("Fix the auth bug");
        record["title"] = json!("✳ claude");
    });
    assert_eq!(described(&rig).1, "fix-auth");

    let rig = core_rig(Some("blocked"));
    update(&rig.host, |record| {
        record["name"] = Value::Null;
        record["status"]["title"] = json!("Fix the auth bug");
        record["title"] = json!("✳ claude");
    });
    assert_eq!(described(&rig).1, "Fix the auth bug");

    let rig = core_rig(Some("blocked"));
    update(&rig.host, |record| {
        record["name"] = Value::Null;
        record["title"] = json!("✳ claude");
    });
    assert_eq!(described(&rig).1, "✳ claude");

    let rig = core_rig(Some("blocked"));
    update(&rig.host, |record| record["name"] = Value::Null);
    assert_eq!(described(&rig).1, Value::Null);
}

#[test]
fn the_project_is_the_working_folders_name() {
    let rig = core_rig(Some("blocked"));
    assert_eq!(described(&rig).0, "proj");

    // Without a foreground folder the start folder stands in.
    let rig = core_rig(Some("blocked"));
    update(&rig.host, |record| {
        record["foreground"] = Value::Null;
        record["cwd"] = json!("/home/u/start/");
    });
    assert_eq!(described(&rig).0, "start");

    let rig = core_rig(Some("blocked"));
    update(&rig.host, |record| {
        record["foreground"] = Value::Null;
        record["cwd"] = json!("/");
    });
    assert_eq!(described(&rig).0, Value::Null);
}

#[test]
fn display_trimming_applies_to_core_names_too() {
    let rig = core_rig(Some("blocked"));
    update(&rig.host, |record| record["name"] = json!("x".repeat(100)));

    let title = described(&rig).1;
    let title = title.as_str().unwrap();
    assert_eq!(title.chars().count(), 80);
    assert!(title.ends_with('…'), "{title}");
}

// ---- the summary ------------------------------------------------------------------------

#[test]
fn the_summary_reads_the_core_terminal_and_is_stored_under_its_id() {
    let rig = core_rig(Some("blocked"));
    rig.write_config(json!({"summary_enabled": true}));
    rig.summaries.says("Approve the deploy.");

    notified(&rig, "blocked");

    let requests = rig.summaries.requests.borrow().clone();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].pane_id, "hc:t1");
    assert_eq!(requests[0].status, "blocked");
    assert_eq!(rig.payload(0, &key_a()).1["summary"], "Approve the deploy.");
    assert_eq!(
        rig.stored_summary("hc:t1").unwrap()["summary"],
        "Approve the deploy."
    );
}

// ---- the Attention Badge -------------------------------------------------------------------

fn terminals_for_the_badge(rig: &Rig) {
    let mut terminals = vec![
        core_record("t1", Some("blocked"), 0),
        core_record("t2", Some("done"), 1),
        core_record("t3", Some("error"), 0),
        core_record("t4", Some("working"), 0),
        core_record("t5", Some("idle"), 0),
        core_record("t6", None, 0),
        core_record("t7", Some("done"), 1),
    ];
    // A finished terminal is no row of `ls`, whatever it last reported.
    terminals[6]["state"] = json!("finished");
    *rig.host.core_terminals.borrow_mut() = terminals;
}

#[test]
fn the_count_is_blocked_and_done_terminals_with_error_as_blocked() {
    let rig = core_rig(Some("blocked"));
    terminals_for_the_badge(&rig);

    notified(&rig, "blocked");

    assert_eq!(rig.payload(0, &key_a()).1["attention"], 3);
}

#[test]
fn tmux_panes_add_their_share_to_the_core_count_unless_tmux_is_disabled() {
    let rig = core_rig(Some("blocked"));
    terminals_for_the_badge(&rig);
    *rig.host.panes.borrow_mut() = Some(vec![TmuxPane::with_status("blocked")]);
    notified(&rig, "blocked");
    assert_eq!(rig.payload(0, &key_a()).1["attention"], 4);

    let rig = core_rig(Some("blocked"));
    terminals_for_the_badge(&rig);
    rig.write_config(json!({"tmux_enabled": false}));
    *rig.host.panes.borrow_mut() = Some(vec![TmuxPane::with_status("blocked")]);
    notified(&rig, "blocked");
    assert_eq!(rig.payload(0, &key_a()).1["attention"], 3);
    assert!(rig.host.calls_of("tmux", None).is_empty());
}

#[test]
fn a_core_that_cannot_list_has_no_share() {
    let core = CoreCommand {
        bin: "/x/herdr-core".into(),
        version: "0.1.14".into(),
        env: Env::default(),
    };
    let failing = |_: &str, _: &[&str], _: &Env| crate::exec::RunResult {
        code: 1,
        stdout: String::new(),
        stderr: "no".into(),
    };
    assert_eq!(core_attention_count(&core, &failing), None);
}

#[test]
fn badge_shares_add_up_only_when_they_answered() {
    assert_eq!(sum_shares(None, None), None);
    assert_eq!(sum_shares(Some(2), None), Some(2));
    assert_eq!(sum_shares(None, Some(3)), Some(3));
    assert_eq!(sum_shares(Some(2), Some(3)), Some(5));
    // The old two-backend sum is unchanged when core is absent.
    assert_eq!(
        combine_attention(Some(1), sum_shares(Some(2), None)),
        combine_attention(Some(1), Some(2))
    );
    assert_eq!(
        combine_attention(Some(1), sum_shares(None, None)),
        combine_attention(Some(1), None)
    );
}

#[test]
fn core_attention_counts_listings_that_need_the_user() {
    let listing = |status: Option<&str>| CoreListing {
        address: "t1".into(),
        agent: None,
        cwd: None,
        name: None,
        state: "live".into(),
        status: status.map(str::to_owned),
        turn: 0,
    };
    let terminals = [
        listing(Some("blocked")),
        listing(Some("done")),
        listing(Some("error")),
        listing(Some("working")),
        listing(Some("idle")),
        listing(Some("novel")),
        listing(None),
    ];
    assert_eq!(core_attention(&terminals), 3);
    assert_eq!(core_attention(&[]), 0);
}

// ---- core's share in the tmux and herdr triggers ----------------------------------------------

fn tmux_rig_with_core_terminals() -> Rig {
    let rig = Rig::tmux();
    rig.write_config(json!({}));
    rig.write_registration(&[device()]);
    *rig.host.panes.borrow_mut() = Some(vec![TmuxPane::with_status("blocked")]);
    terminals_for_the_badge(&rig);
    rig
}

/// Each program run, as its name and first two arguments.
fn lines(host: &FakeHost) -> Vec<String> {
    host.calls()
        .iter()
        .map(|call| {
            let cmd = call.cmd.rsplit('/').next().unwrap_or(&call.cmd);
            let args: Vec<&str> = call.args.iter().take(2).map(String::as_str).collect();
            format!("{cmd} {}", args.join(" "))
        })
        .collect()
}

#[test]
fn a_tmux_trigger_without_core_runs_exactly_the_old_calls() {
    let rig = tmux_rig_with_core_terminals();

    let (result, stderr) = rig.notify("tmux:%3", "blocked");
    result.unwrap_or_else(|error| panic!("{error}: {stderr}"));

    assert_eq!(rig.payload(0, &key_a()).1["attention"], 1);
    assert_eq!(
        lines(&rig.host),
        [
            "herdr plugin list",
            "tmux list-panes -a",
            "tmux list-panes -a",
            "herdr agent list",
        ]
    );
}

#[test]
fn a_tmux_trigger_counts_a_running_core() {
    let rig = tmux_rig_with_core_terminals();
    rig.install_core();
    rig.core_running();

    let (result, stderr) = rig.notify("tmux:%3", "blocked");
    result.unwrap_or_else(|error| panic!("{error}: {stderr}"));

    // One blocked tmux pane plus three blocked or done core terminals.
    assert_eq!(rig.payload(0, &key_a()).1["attention"], 4);
    assert_eq!(core_args(&rig, "ls"), ["--json"]);
}

#[test]
fn a_tmux_trigger_never_asks_a_core_that_is_not_running() {
    // Installed, a socket file left behind, nothing listening: asking would
    // start a core with the hook's environment.
    let rig = tmux_rig_with_core_terminals();
    rig.install_core();
    rig.core_running();
    rig.core_stopped();

    let (result, _) = rig.notify("tmux:%3", "blocked");
    result.unwrap();

    assert_eq!(rig.payload(0, &key_a()).1["attention"], 1);
    assert!(rig.host.core_calls(None).is_empty());
}

#[test]
fn a_tmux_trigger_does_not_ask_a_core_it_cannot_find() {
    let rig = tmux_rig_with_core_terminals();
    rig.core_running();

    let (result, _) = rig.notify("tmux:%3", "blocked");
    result.unwrap();

    assert_eq!(rig.payload(0, &key_a()).1["attention"], 1);
    assert!(rig.host.core_calls(None).is_empty());
}

#[test]
fn core_enabled_false_keeps_core_out_of_the_tmux_count_without_asking_it() {
    let rig = tmux_rig_with_core_terminals();
    rig.write_config(json!({"core_enabled": false}));
    rig.install_core();
    rig.core_running();

    let (result, _) = rig.notify("tmux:%3", "blocked");
    result.unwrap();

    assert_eq!(rig.payload(0, &key_a()).1["attention"], 1);
    assert!(rig.host.core_calls(None).is_empty());
}

#[test]
fn a_core_that_fails_to_list_leaves_the_tmux_count_as_it_was() {
    let rig = tmux_rig_with_core_terminals();
    rig.install_core();
    rig.core_running();
    rig.host.core_down.set(Some(1));

    let (result, _) = rig.notify("tmux:%3", "blocked");
    result.unwrap();

    assert_eq!(rig.payload(0, &key_a()).1["attention"], 1);
}

fn herdr_rig_with_core_terminals() -> Rig {
    let rig = Rig::herdr();
    rig.write_config(json!({}));
    rig.write_registration(&[device()]);
    rig.herdr_answers(herdr_stub("blocked"));
    terminals_for_the_badge(&rig);
    rig
}

fn herdr_blocked() -> Value {
    json!({"data": {"pane_id": PANE_ID, "agent_status": "blocked"}})
}

#[test]
fn the_herdr_hook_without_core_counts_as_before() {
    let rig = herdr_rig_with_core_terminals();

    let outcome = rig.hook(&herdr_blocked());

    assert_eq!(outcome.code, 0, "{}", outcome.stderr);
    assert_eq!(rig.payload(0, &key_a()).1["attention"], 1);
    assert!(rig.host.core_calls(None).is_empty());
}

#[test]
fn the_herdr_hook_counts_a_running_core() {
    let rig = herdr_rig_with_core_terminals();
    rig.install_core();
    rig.core_running();

    let outcome = rig.hook(&herdr_blocked());

    assert_eq!(outcome.code, 0, "{}", outcome.stderr);
    assert_eq!(rig.payload(0, &key_a()).1["attention"], 4);
}

#[test]
fn the_herdr_hook_leaves_core_out_when_it_is_disabled() {
    let rig = herdr_rig_with_core_terminals();
    rig.write_config(json!({"core_enabled": false}));
    rig.install_core();
    rig.core_running();

    let outcome = rig.hook(&herdr_blocked());

    assert_eq!(outcome.code, 0, "{}", outcome.stderr);
    assert_eq!(rig.payload(0, &key_a()).1["attention"], 1);
    assert!(rig.host.core_calls(None).is_empty());
}

// ---- Chat Marker collection ---------------------------------------------------------------------

fn due(rig: &Rig) {
    rig.chat.gc_due.borrow_mut().push_back(true);
    rig.chat.has_markers.set(true);
}

#[test]
fn the_core_trigger_collects_markers_by_the_live_core_terminals_alone() {
    let rig = core_rig(Some("blocked"));
    *rig.host.core_terminals.borrow_mut() = vec![
        core_record("t1", Some("blocked"), 0),
        core_record("box/t2", Some("idle"), 0),
        {
            let mut finished = core_record("t3", Some("done"), 1);
            finished["state"] = json!("finished");
            finished
        },
    ];
    due(&rig);

    notified(&rig, "blocked");

    let collected = rig.chat.collected.borrow().clone();
    assert_eq!(collected.len(), 1);
    // `ls` lists addresses; the ids are the app's `hc:` ids.
    assert_eq!(
        collected[0].live_core_pane_ids,
        Some(vec!["hc:t1".to_owned(), "hc:box/t2".to_owned()])
    );
    // herdr and tmux are not asked: their markers are kept.
    assert!(!collected[0].herdr_asked);
    assert_eq!(collected[0].live_tmux_pane_ids, None);
}

#[test]
fn a_core_trigger_that_is_not_due_or_has_no_markers_never_lists() {
    let rig = core_rig(Some("blocked"));
    rig.chat.has_markers.set(true);
    notified(&rig, "blocked");
    assert!(rig.chat.collected.borrow().is_empty());

    let rig = core_rig(Some("blocked"));
    rig.chat.gc_due.borrow_mut().push_back(true);
    notified(&rig, "blocked");
    assert!(rig.chat.collected.borrow().is_empty());
}

#[test]
fn the_core_trigger_collects_nothing_when_core_is_disabled() {
    let rig = core_rig(Some("blocked"));
    rig.write_config(json!({"core_enabled": false}));
    due(&rig);

    notified(&rig, "blocked");

    assert!(rig.chat.collected.borrow().is_empty());
    assert!(rig.host.core_calls(None).is_empty());
}

#[test]
fn the_core_trigger_collects_nothing_when_core_cannot_list() {
    let rig = core_rig(Some("blocked"));
    rig.host.core_down.set(Some(1));
    due(&rig);

    let (result, _) = rig.notify_core("hc:t1", "blocked");

    // The re-check fails closed too; nothing was collected on a guess.
    assert!(result.is_err());
    assert!(rig.chat.collected.borrow().is_empty());
}

#[test]
fn a_collection_that_cannot_run_is_reported_on_stderr_not_fatal() {
    let rig = core_rig(Some("blocked"));
    due(&rig);
    rig.chat.skipped.set(true);

    let (result, stderr) = rig.notify_core("hc:t1", "blocked");

    result.unwrap();
    assert!(
        stderr.contains("chat markers not collected: named herdr sessions share this Host"),
        "{stderr}"
    );
    assert_eq!(post_count(&rig), 1);
}

#[test]
fn the_herdr_hook_hands_core_markers_to_the_core_list_when_core_runs() {
    let rig = herdr_rig_with_core_terminals();
    rig.install_core();
    rig.core_running();
    due(&rig);

    let outcome = rig.hook(&herdr_blocked());

    assert_eq!(outcome.code, 0, "{}", outcome.stderr);
    let collected = rig.chat.collected.borrow().clone();
    assert_eq!(collected.len(), 1);
    assert!(collected[0].herdr_asked);
    assert_eq!(
        collected[0].live_core_pane_ids,
        Some(
            ["t1", "t2", "t3", "t4", "t5", "t6"]
                .iter()
                .map(|address| format!("hc:{address}"))
                .collect()
        )
    );
}

#[test]
fn the_herdr_hook_keeps_every_core_marker_when_core_is_not_running_or_disabled() {
    let rig = herdr_rig_with_core_terminals();
    rig.install_core();
    due(&rig);
    let outcome = rig.hook(&herdr_blocked());
    assert_eq!(outcome.code, 0, "{}", outcome.stderr);
    assert_eq!(rig.chat.collected.borrow()[0].live_core_pane_ids, None);
    assert!(rig.host.core_calls(None).is_empty());

    let rig = herdr_rig_with_core_terminals();
    rig.write_config(json!({"core_enabled": false}));
    rig.install_core();
    rig.core_running();
    due(&rig);
    let outcome = rig.hook(&herdr_blocked());
    assert_eq!(outcome.code, 0, "{}", outcome.stderr);
    assert_eq!(rig.chat.collected.borrow()[0].live_core_pane_ids, None);
    assert!(rig.host.core_calls(None).is_empty());
}
