use super::*;
use crate::hook_session::run_hook_session;
use crate::hook_status::run_hook_status_command;
use crate::notify_core::Backend;
use crate::test_support::TempDir;
use std::cell::RefCell;
use std::collections::BTreeMap;

#[test]
fn shared_state_vectors() {
    let v: Value =
        serde_json::from_str(include_str!("../../test-vectors/zellij-pane-state-v1.json")).unwrap();
    for case in v["paneIds"].as_array().unwrap() {
        let parsed = PaneId::parse(case["id"].as_str().unwrap())
            .map(|p| json!({"session":p.session,"pane":p.pane}));
        assert_eq!(parsed.unwrap_or(Value::Null), case["expected"]);
    }
    for case in v["fileNames"].as_array().unwrap() {
        assert_eq!(pane_file_name(case["id"].as_str().unwrap()), case["file"]);
    }
    for case in v["documents"].as_array().unwrap() {
        let doc = Document::parse(&case["document"].to_string());
        let actual = doc.map(|d| json!({"pane":d.pane,"kind":d.kind,"status":d.status,"seq":d.seq,"session":d.session,"transcript":d.transcript,"launch":d.launch,"updatedMs":d.updated_ms})).unwrap_or(Value::Null);
        assert_eq!(actual, case["expected"], "{}", case["name"]);
    }
}

struct Host {
    dir: TempDir,
    own: RefCell<Env>,
    tty: RefCell<String>,
    parents: RefCell<BTreeMap<u32, u32>>,
    commands: RefCell<BTreeMap<u32, Vec<String>>>,
    ttys: RefCell<BTreeMap<u32, String>>,
    environments: RefCell<BTreeMap<u32, Env>>,
    notes: RefCell<Vec<String>>,
    calls: RefCell<Vec<Vec<String>>>,
}
impl Host {
    fn new() -> Self {
        let dir = TempDir::new("zellij-hook");
        crate::test_support::write_stub(&dir.path().join("zellij"), "exit 1");
        Self {
            dir,
            own: RefCell::new(Env::from_pairs([
                ("ZELLIJ_PANE_ID", "0"),
                ("ZELLIJ_SESSION_NAME", "work"),
                ("WAYCAR_LAUNCH", "tag"),
            ])),
            tty: RefCell::new("pts/2".into()),
            parents: RefCell::new(BTreeMap::from([(42, 43), (43, 44), (44, 1)])),
            commands: RefCell::new(BTreeMap::from([
                (42, vec!["claude".into()]),
                (43, vec!["/bin/sh".into()]),
                (
                    44,
                    vec![
                        "/local/bin/zellij".into(),
                        "--server".into(),
                        "/tmp/zjht/socket".into(),
                    ],
                ),
            ])),
            ttys: RefCell::new(BTreeMap::from([(43, "pts/2".into())])),
            environments: RefCell::new(BTreeMap::new()),
            notes: RefCell::new(vec![]),
            calls: RefCell::new(vec![]),
        }
    }
    fn env(&self) -> Env {
        Env::from_pairs([
            ("HOME", self.dir.path().to_str().unwrap()),
            ("PATH", self.dir.path().to_str().unwrap()),
            ("ZELLIJ_PANE_ID", "0"),
            ("ZELLIJ_SESSION_NAME", "work"),
            ("CLAUDECODE", "1"),
            ("XDG_STATE_HOME", "/not-used"),
        ])
    }
    fn doc(&self) -> Option<Document> {
        read_document(&self.env(), "zellij:work/terminal_0")
    }
    fn status(&self, want: &str) {
        run_hook_status_command(&["claude".into(), want.into()], &self.env(), self, 42);
    }
}
impl HookHost for Host {
    fn tmux(&self, _: &[&str], _: &Env) -> Option<String> {
        None
    }
    fn tty(&self, pid: &str) -> String {
        if pid == "42" {
            return self.tty.borrow().clone();
        }
        pid.parse()
            .ok()
            .and_then(|p| self.ttys.borrow().get(&p).cloned())
            .unwrap_or_default()
    }
    fn ppid(&self, pid: &str) -> String {
        pid.parse()
            .ok()
            .and_then(|p| self.parents.borrow().get(&p).copied())
            .map(|p| p.to_string())
            .unwrap_or_default()
    }
    fn argv(&self, pid: u32) -> Option<Vec<String>> {
        self.commands.borrow().get(&pid).cloned()
    }
    fn notify(&self, _: &str, _: &str, _: &Env) {
        panic!("not tmux");
    }
    fn process_env(&self, pid: u32) -> Option<Env> {
        self.environments.borrow().get(&pid).cloned().or_else(|| {
            self.parents
                .borrow()
                .contains_key(&pid)
                .then(|| self.own.borrow().clone())
        })
    }
    fn zellij_notify(&self, id: &str, status: &str, _: &Env) {
        self.notes.borrow_mut().push(format!("{id} {status}"));
    }
    fn zellij_run(&self, _: &str, args: &[&str], _: &Env) -> RunResult {
        self.calls
            .borrow_mut()
            .push(args.iter().map(|s| s.to_string()).collect());
        RunResult {
            code: 0,
            stdout: "zellij 0.46.0".into(),
            stderr: String::new(),
        }
    }
}

#[test]
fn ownership_match_mismatch_no_tty_and_codex_no_hop() {
    let h = Host::new();
    let e = h.env();
    assert!(resolve("claude", &e, 42, &h).is_some());
    h.own.borrow_mut().set("ZELLIJ_SESSION_NAME", "other");
    assert!(resolve("claude", &e, 42, &h).is_none());
    h.own.borrow_mut().set("ZELLIJ_SESSION_NAME", "work");
    *h.tty.borrow_mut() = "?".into();
    assert_eq!(resolve("grok", &e, 42, &h).unwrap().pid, 43);
    assert!(resolve("codex", &e, 42, &h).is_none());
    assert!(resolve("cline", &e, 42, &h).is_none());
    let mut e = e.clone();
    e.set("CLAUDE_PID", "44");
    assert!(resolve("claude", &e, 42, &h).is_none());
    e.set("CLAUDE_PID", "1");
    assert!(resolve("claude", &e, 42, &h).is_none());
}

#[test]
fn ownership_walk_requires_the_first_zellij_pane_root_with_matching_tty_and_env() {
    let h = Host::new();
    let e = h.env();
    assert!(resolve("claude", &e, 42, &h).is_some());

    // Same pair in the agent's own environment, but outside Zellij.
    h.commands.borrow_mut().insert(44, vec!["/bin/sh".into()]);
    assert!(resolve("claude", &e, 42, &h).is_none());
    h.commands.borrow_mut().insert(
        44,
        vec![
            "/home/user name/bin/zellij".into(),
            "--server".into(),
            "/tmp/zjht/socket".into(),
        ],
    );

    // A nested pty keeps the pair but not the pane root's tty.
    h.ttys.borrow_mut().insert(43, "pts/9".into());
    assert!(resolve("claude", &e, 42, &h).is_none());
    h.ttys.borrow_mut().insert(43, "pts/2".into());
    let mut wrong = h.own.borrow().clone();
    wrong.set("ZELLIJ_PANE_ID", "1");
    h.environments.borrow_mut().insert(43, wrong);
    assert!(resolve("claude", &e, 42, &h).is_none());
    h.environments.borrow_mut().clear();

    // The walk is bounded even if a process table never reaches a server.
    for pid in 43..=59 {
        h.parents.borrow_mut().insert(pid, pid + 1);
        h.commands.borrow_mut().insert(pid, vec!["/bin/sh".into()]);
    }
    h.commands.borrow_mut().insert(
        60,
        vec![
            "zellij".into(),
            "--server".into(),
            "/tmp/zjht/socket".into(),
        ],
    );
    assert!(resolve("claude", &e, 42, &h).is_none());
}

#[test]
fn ownership_query_does_not_suppress_nested_herdr_or_core_and_never_writes() {
    let h = Host::new();
    let query = ["opencode".into(), "owns-zellij".into()];
    assert_eq!(run_hook_status_command(&query, &h.env(), &h, 42), 0);
    *h.tty.borrow_mut() = "pts/9".into();
    for (key, value) in [("HERDR_PANE_ID", "w1:p1"), ("HC_TERMINAL_ID", "t1")] {
        let mut env = h.env();
        env.set(key, value);
        assert_eq!(run_hook_status_command(&query, &env, &h, 42), 125);
    }
    assert!(h.doc().is_none());
    assert!(h.notes.borrow().is_empty());
    assert!(h.calls.borrow().is_empty());
}

#[test]
fn codex_resurrection_preserves_only_the_running_agents_no_daemon_flag() {
    for no_daemon in [false, true] {
        let h = Host::new();
        let mut argv = vec!["codex".into(), "--config=--no-daemon".into()];
        if no_daemon {
            argv.push("--no-daemon".into());
        }
        h.commands.borrow_mut().insert(42, argv);
        run_hook_status_command(
            &["codex".into(), "session".into(), "sid".into()],
            &h.env(),
            &h,
            42,
        );
        let calls = h.calls.borrow();
        let resurrect = calls
            .iter()
            .find(|args| args.iter().any(|s| s == "set-resurrect-command"))
            .unwrap();
        let mut expected = vec![
            "-s",
            "work",
            "action",
            "set-resurrect-command",
            "--pane-id",
            "terminal_0",
            "--",
            "codex",
        ];
        if no_daemon {
            expected.push("--no-daemon");
        }
        expected.extend(["resume", "sid"]);
        assert_eq!(resurrect, &expected);
        assert_eq!(
            calls.len(),
            2,
            "only Zellij version and resurrection; no Codex probe"
        );
    }
}

#[test]
fn writers_seq_conditional_session_transcript_and_release() {
    let h = Host::new();
    h.status("working-if-active");
    assert!(h.doc().is_none());
    h.status("working");
    let d = h.doc().unwrap();
    assert_eq!(d.status.as_deref(), Some("working"));
    assert_eq!(d.pid, Some(42));
    assert_eq!(d.launch.as_deref(), Some("tag"));
    assert!(d.updated_ms.is_some());
    h.status("working");
    assert_eq!(h.doc().unwrap().seq, d.seq);
    h.status("blocked");
    assert!(h.doc().unwrap().seq > d.seq);
    h.status("done-if-active");
    h.status("working-if-active");
    assert_eq!(h.doc().unwrap().status.as_deref(), Some("done"));
    run_hook_session(
        "claude",
        "SessionStart",
        r#"{"session_id":"abc","transcript_path":"/a b/t.jsonl","source":"startup"}"#,
        &h.env(),
        42,
        &h,
    );
    let d = h.doc().unwrap();
    assert_eq!(d.session.as_deref(), Some("abc"));
    assert_eq!(d.transcript.as_deref(), Some("/a b/t.jsonl"));
    assert!(h.calls.borrow().iter().any(|args| args
        == &[
            "-s",
            "work",
            "action",
            "set-resurrect-command",
            "--pane-id",
            "terminal_0",
            "--",
            "claude",
            "--resume",
            "abc"
        ]));
    run_hook_session(
        "claude",
        "SessionEnd",
        r#"{"session_id":"other"}"#,
        &h.env(),
        42,
        &h,
    );
    assert!(h.doc().is_some());
    h.status("release");
    assert!(h.doc().is_none());
    assert_eq!(
        h.notes.borrow().last().unwrap(),
        "zellij:work/terminal_0 release"
    );
}

#[test]
fn resume_argv_consumes_shared_launch_contract() {
    let v: Value =
        serde_json::from_str(include_str!("../../test-vectors/harness-launch-v1.json")).unwrap();
    for case in v["cases"].as_array().unwrap() {
        let Some(value) = case["input"]["resume"]["value"].as_str() else {
            continue;
        };
        let kind = case["kind"].as_str().unwrap();
        let ours = resume_argv(kind, value).unwrap();
        let expected: Vec<&str> = case["expected"]["argv"]
            .as_array()
            .unwrap()
            .iter()
            .map(|s| s.as_str().unwrap())
            .collect();
        assert_eq!(ours[0], expected[0], "{kind}");
        let suffix = if matches!(kind, "cline" | "hermes" | "kiro") {
            &ours[2..]
        } else {
            &ours[1..]
        };
        assert!(
            expected.ends_with(&suffix.iter().map(String::as_str).collect::<Vec<_>>()),
            "{kind}: {ours:?}"
        );
    }
}

#[test]
fn notify_rechecks_gone_unknown_and_record_before_document() {
    let h = Host::new();
    h.status("blocked");
    let z = ZellijCommand {
        bin: "fake".into(),
        version: "0.46.0".into(),
        env: h.env(),
    };
    let id = PaneId::parse("zellij:work/terminal_0").unwrap();
    for (output, code, expected) in [
        ("[]", 0, "gone"),
        ("", 1, "unknown"),
        (
            r#"[{"id":0,"program_status":[{"id":null,"state":"Working"}]}]"#,
            0,
            "working",
        ),
        (r#"[{"id":0,"program_status":null}]"#, 0, "blocked"),
    ] {
        let run = |_: &str, _: &[&str], _: &Env| RunResult {
            code,
            stdout: output.into(),
            stderr: String::new(),
        };
        let b = crate::zellij_notify::ZellijBackend {
            command: &z,
            id: &id,
            run: &run,
        };
        let current = b.recheck();
        match expected {
            "gone" => assert!(current.unwrap().is_none()),
            "unknown" => assert!(current.is_err()),
            other => assert_eq!(current.unwrap().unwrap().status, other),
        }
    }
}

#[test]
fn notify_flow_uses_zellij_id_and_can_be_silenced() {
    use crate::notify_core::Deps;
    use crate::notify_fake::rig::{Rig, device, key_a};
    let rig = Rig::tmux();
    rig.write_config(json!({}));
    rig.write_registration(&[device()]);
    let bin = rig.path(".local/bin/zellij");
    std::fs::create_dir_all(bin.parent().unwrap()).unwrap();
    crate::test_support::write_stub(&bin, "exit 0");
    let calls = RefCell::new(Vec::new());
    let run = |bin: &str, args: &[&str], env: &Env| {
        if bin.ends_with("/zellij") {
            calls.borrow_mut().push(args.join(" "));
            RunResult { code: 0, stderr: String::new(), stdout: match args {
                ["--version"] => "zellij 0.46.0".into(),
                ["ls", "-n"] => "work [Created 1s ago]".into(),
                ["-s", "work", "action", "list-panes", "-j"] => json!([{"id":0,"title":"Agent","tab_name":"Tab","program_status":[{"id":null,"state":"Blocked","app":"claude-code"}]}]).to_string(),
                _ => panic!("unexpected command: {args:?}"),
            }}
        } else {
            rig.host.run(bin, args, env)
        }
    };
    let deps = Deps {
        run: &run,
        fetch: rig.relay.as_ref(),
        clock: rig.clock.as_ref(),
        summaries: rig.summaries.as_ref(),
        chat: rig.chat.as_ref(),
    };
    let env = rig.tmux_env();
    let id = "zellij:work/terminal_0";
    crate::hook_runtime::push_with(
        id,
        "blocked",
        &env,
        rig.home.path(),
        &deps,
        &mut String::new(),
    )
    .unwrap();
    assert_eq!(rig.relay.posts().len(), 1);
    let payload = rig.payload(0, &key_a()).1;
    assert_eq!(payload["pane"], id);
    assert_eq!(payload["kind"], "claude");
    assert_eq!(payload["attention"], 1);
    rig.write_config(json!({"zellij_enabled":false}));
    calls.borrow_mut().clear();
    crate::hook_runtime::push_with(id, "done", &env, rig.home.path(), &deps, &mut String::new())
        .unwrap();
    assert_eq!(rig.relay.posts().len(), 1);
    assert!(calls.borrow().is_empty());
}

#[test]
fn extensions_session_form_writes_decoded_paths_without_status() {
    let h = Host::new();
    run_hook_status_command(
        &[
            "omp".into(),
            "session".into(),
            "/a b/s.jsonl".into(),
            "/a b/s.jsonl".into(),
        ],
        &h.env(),
        &h,
        42,
    );
    let d = h.doc().unwrap();
    assert_eq!(d.kind.as_deref(), Some("omp"));
    assert_eq!(d.session.as_deref(), Some("/a b/s.jsonl"));
    assert_eq!(d.transcript.as_deref(), Some("/a b/s.jsonl"));
    assert_eq!(d.status, None);
}

#[test]
fn macos_procargs2_keeps_environment_values_and_argv_lossless() {
    let mut bytes = 3i32.to_ne_bytes().to_vec();
    bytes.extend_from_slice(b"/home/user name/bin/zellij\0\0\0zellij\0--server\0/tmp/a b/socket\0ZELLIJ_PANE_ID=12\0ZELLIJ_SESSION_NAME=my  project x=y\0WAYCAR_LAUNCH=tag = value\0\0");
    let p = process::parse_procargs2(&bytes).unwrap();
    assert_eq!(p.argv, ["zellij", "--server", "/tmp/a b/socket"]);
    assert_eq!(PaneId::from_env(&p.env).unwrap().session, "my  project x=y");
    assert_eq!(p.env.get("WAYCAR_LAUNCH"), Some("tag = value"));
    assert!(process::parse_procargs2(&bytes[..10]).is_none());
}

#[test]
fn activity_inventory_uses_session_tab_pane_names_and_live_root_status() {
    let h = Host::new();
    h.status("done");
    let z = ZellijCommand {
        bin: "fake".into(),
        version: "0.46.0".into(),
        env: h.env(),
    };
    let run = |_: &str, args: &[&str], _: &Env| RunResult {
        code: 0,
        stderr: String::new(),
        stdout: if args == ["ls", "-n"] {
            "work [Created 1s ago] \nclosed [Created 1m ago] (EXITED - attach to resurrect)".into()
        } else {
            json!([{"id":0,"title":"Agent","tab_id":7,"tab_name":"Tasks","pane_cwd":"/work","program_status":[{"id":null,"state":"Error","app":"claude-code"}]}, {"id":1,"is_plugin":true}, {"id":2,"is_suppressed":true}, {"id":3,"exited":true}]).to_string()
        },
    };
    let rows = inventory(&z, &run).unwrap();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0]["pane_id"], "zellij:work/terminal_0");
    assert_eq!(rows[0]["workspace_label"], "work");
    assert_eq!(rows[0]["tab_label"], "Tasks");
    assert_eq!(rows[0]["agent_status"], "blocked");
    assert_eq!(rows[0]["agent"], "claude");
}

#[test]
fn session_list_accepts_current_from_a_panes_environment() {
    let h = Host::new();
    let z = ZellijCommand {
        bin: "fake".into(),
        version: "0.46.0".into(),
        env: h.env(),
    };
    let run = |_: &str, args: &[&str], env: &Env| {
        assert_eq!(env.get("ZELLIJ_SESSION_NAME"), Some("work"));
        RunResult { code: 0, stderr: String::new(), stdout: match args {
            ["ls", "-n"] => "work [Created 1s ago] (current)\nclosed [Created 1m ago] (EXITED - attach to resurrect)\n".into(),
            ["-s", "work", "action", "list-panes", "-j"] => json!([{"id": 0, "program_status": [{"id": null, "state": "Blocked", "app": "claude-code"}]}]).to_string(),
            _ => panic!("unexpected Zellij command: {args:?}"),
        }}
    };
    assert_eq!(sessions(&z, &run).unwrap(), ["work"]);
    assert_eq!(inventory(&z, &run).unwrap().len(), 1);
    let id = PaneId::parse("zellij:work/terminal_0").unwrap();
    let backend = crate::zellij_notify::ZellijBackend {
        command: &z,
        id: &id,
        run: &run,
    };
    assert_eq!(backend.attention(), Some(1));
}

#[test]
fn session_list_parses_suffixes_without_treating_name_text_as_metadata() {
    let h = Host::new();
    let z = ZellijCommand {
        bin: "fake".into(),
        version: "0.46.0".into(),
        env: h.env(),
    };
    let run = |_: &str, _: &[&str], _: &Env| {
        RunResult { code: 0, stderr: String::new(), stdout:
        "work (EXITED plans [Created 1s ago] \nwork [Created notes [Created 2m ago] \nclosed [Created 1m ago] (EXITED - attach to resurrect)\n".into() }
    };
    assert_eq!(
        sessions(&z, &run).unwrap(),
        ["work (EXITED plans", "work [Created notes"]
    );
    h.status("working");
    for line in [
        "work",
        "work [Created notes",
        "work [Created 1s ago] (EXITED someday)",
    ] {
        let malformed = |_: &str, _: &[&str], _: &Env| RunResult {
            code: 0,
            stderr: String::new(),
            stdout: line.into(),
        };
        assert!(sessions(&z, &malformed).is_err());
        collect_documents(&z, &malformed);
        assert!(h.doc().is_some(), "parse doubt must not collect documents");
    }
}

#[test]
fn session_list_excludes_resurrectable_and_gc_keeps_unknown() {
    let h = Host::new();
    h.status("working");
    let z = ZellijCommand {
        bin: "fake".into(),
        version: "0.46.0".into(),
        env: h.env(),
    };
    let run = |_: &str, _: &[&str], _: &Env| RunResult {
        code: 0,
        stdout: "work [Created 1s ago] \ndead [Created 1m ago] (EXITED - attach to resurrect)\n"
            .into(),
        stderr: String::new(),
    };
    assert_eq!(sessions(&z, &run).unwrap(), ["work"]);
    collect_documents(&z, &run);
    assert!(h.doc().is_some());
    let fail = |_: &str, _: &[&str], _: &Env| RunResult {
        code: 1,
        stdout: String::new(),
        stderr: "error".into(),
    };
    collect_documents(&z, &fail);
    assert!(h.doc().is_some());
    let empty = |_: &str, _: &[&str], _: &Env| RunResult {
        code: 0,
        stdout: String::new(),
        stderr: String::new(),
    };
    collect_documents(&z, &empty);
    assert!(h.doc().is_none());
}
