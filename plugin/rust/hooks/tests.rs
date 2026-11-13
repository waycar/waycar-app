//! test/agent-hooks.test.js and test/agent-kinds.test.js: the hooks against a
//! fake HOME.

use std::fs;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt, symlink};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};

use serde_json::json;

use crate::env::Env;
use crate::js_json::{Json, Obj, deep_equal, parse};
use crate::native::Ctx;

use super::*;

/// The plugin directory: where the templates under `hooks/` live.
const PLUGIN_ROOT: &str = env!("CARGO_MANIFEST_DIR");

fn hook() -> String {
    format!("'{PLUGIN_ROOT}/bin/waycar-hook'")
}

fn session() -> String {
    format!("'{PLUGIN_ROOT}/bin/waycar' hook-session")
}

fn j(value: serde_json::Value) -> Json {
    parse(&value.to_string()).unwrap()
}

/// `value.a.0.b` as `value.a[0].b`.
fn at<'a>(value: &'a Json, path: &str) -> Option<&'a Json> {
    path.split('.')
        .try_fold(value, |current, key| match current {
            Json::Arr(items) => key.parse::<usize>().ok().and_then(|i| items.get(i)),
            other => other.get(key),
        })
}

fn text<'a>(value: &'a Json, path: &str) -> &'a str {
    at(value, path)
        .and_then(Json::as_str)
        .unwrap_or_else(|| panic!("no string at {path}"))
}

fn keys(value: &Json) -> Vec<&str> {
    value
        .as_object()
        .map_or_else(Vec::new, |object| object.keys().collect())
}

fn same(a: &Json, b: &Json) -> bool {
    deep_equal(a, b)
}

fn claude_fixture() -> Json {
    j(json!({
        "env": {"FOO": "1"},
        "permissions": {"allow": ["Bash(ls)"]},
        "hooks": {
            "PermissionRequest": [{"hooks": [moshi_value()]}],
            "PreToolUse": [
                {"matcher": "Grep|Glob|Bash", "hooks": [user_value()]},
                {"matcher": "AskUserQuestion", "hooks": [moshi_value()]},
            ],
            "SessionStart": [{"hooks": [herdr_value()]}],
        },
        "statusLine": {"type": "command", "command": "x"},
        "effortLevel": "high",
    }))
}

fn moshi_value() -> serde_json::Value {
    json!({"type": "command", "command": "'/opt/homebrew/bin/moshi-hook' claude-hook", "async": true})
}

fn herdr_value() -> serde_json::Value {
    json!({"type": "command", "command": "sh '/home/u/.claude/hooks/herdr-agent-state.sh' session", "timeout": 10})
}

fn user_value() -> serde_json::Value {
    json!({"type": "command", "command": "node \"/home/u/.claude/hooks/gitnexus-hook.cjs\"", "timeout": 10})
}

const CODEX_TOML: &str = "# my codex config
model = \"gpt-5\"
notify = [\"/opt/homebrew/bin/moshi-hook\", \"codex-notify\"]

[features]
# keep these
rmcp_client = true
unified_exec = true

[projects.\"/home/u/src\"]
trust_level = \"trusted\"
";

fn codex_hooks() -> Json {
    j(json!({
        "hooks": {
            "SessionStart": [{"hooks": [{"command": "'/opt/homebrew/bin/moshi-hook' codex-hook", "type": "command"}]}],
            "Stop": [{"hooks": [{"command": "'/opt/homebrew/bin/moshi-hook' codex-hook", "type": "command"}]}],
        }
    }))
}

static NEXT: AtomicUsize = AtomicUsize::new(0);

/// A fake HOME, removed on drop.
struct Host {
    home: PathBuf,
    env: Env,
}

impl Host {
    fn new() -> Self {
        let home = std::env::temp_dir().join(format!(
            "agent-hooks-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&home).unwrap();
        let env = Env::from_pairs([
            ("PATH".to_string(), String::new()),
            (
                "XDG_CONFIG_HOME".to_string(),
                home.join("xdg").to_string_lossy().into_owned(),
            ),
        ]);
        Self { home, env }
    }

    fn ctx(&self) -> Ctx {
        Ctx {
            env: self.env.clone(),
            home: self.home.clone(),
            plugin_root: PathBuf::from(PLUGIN_ROOT),
        }
    }

    fn path(&self, relative: &str) -> PathBuf {
        self.home.join(relative)
    }

    fn install(&self, agents: &[&str]) -> HooksResult {
        install_agents(&self.ctx(), Some(agents)).unwrap()
    }

    fn uninstall(&self) -> HooksResult {
        uninstall(&self.ctx()).unwrap()
    }

    fn status(&self) -> HooksResult {
        status(&self.ctx()).unwrap()
    }

    fn row(&self, agent: &str) -> AgentRow {
        self.status()
            .agents
            .into_iter()
            .find(|row| row.agent == agent)
            .unwrap()
    }

    fn claude_path(&self) -> PathBuf {
        self.path(".claude/settings.json")
    }

    fn codex_hooks_path(&self) -> PathBuf {
        self.path(".codex/hooks.json")
    }

    fn codex_toml_path(&self) -> PathBuf {
        self.path(".codex/config.toml")
    }
}

impl Drop for Host {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.home);
    }
}

fn write_text(path: &Path, content: &str, mode: u32) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let _ = fs::remove_file(path);
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(mode)
        .open(path)
        .unwrap();
    std::io::Write::write_all(&mut file, content.as_bytes()).unwrap();
}

fn write_json_file(path: &Path, value: &Json, mode: u32) {
    write_text(path, &format!("{}\n", value.to_pretty()), mode);
}

fn read_json(path: &Path) -> Json {
    parse(&fs::read_to_string(path).unwrap()).unwrap()
}

fn read(path: &Path) -> String {
    fs::read_to_string(path).unwrap()
}

fn mode_of(path: &Path) -> u32 {
    fs::metadata(path).unwrap().permissions().mode() & 0o777
}

fn paths(rows: &[AgentRow]) -> Vec<String> {
    rows.iter().flat_map(|row| row.changed.clone()).collect()
}

fn s(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

// MARK: - Claude

#[test]
fn claude_adds_the_entries_after_every_existing_hook_keeping_key_order() {
    let host = Host::new();
    write_json_file(&host.claude_path(), &claude_fixture(), 0o644);
    let result = host.install(&["claude"]);
    assert!(result.agents[0].installed);
    assert_eq!(result.agents[0].changed, [s(&host.claude_path())]);

    let settings = read_json(&host.claude_path());
    assert_eq!(
        keys(&settings),
        ["env", "permissions", "hooks", "statusLine", "effortLevel"]
    );
    assert_eq!(
        keys(at(&settings, "hooks").unwrap()),
        [
            "PermissionRequest",
            "PreToolUse",
            "SessionStart",
            "UserPromptSubmit",
            "Notification",
            "PostToolUse",
            "PostToolUseFailure",
            "ElicitationResult",
            "Stop",
            "StopFailure",
            "SessionEnd",
        ]
    );
    let fixture = claude_fixture();
    assert!(same(
        at(&settings, "hooks.PermissionRequest.0").unwrap(),
        at(&fixture, "hooks.PermissionRequest.0").unwrap()
    ));
    assert!(same(
        &Json::Arr(
            at(&settings, "hooks.PreToolUse")
                .unwrap()
                .as_array()
                .unwrap()[..2]
                .to_vec()
        ),
        at(&fixture, "hooks.PreToolUse").unwrap()
    ));
    assert!(same(
        at(&settings, "hooks.SessionStart.0").unwrap(),
        at(&fixture, "hooks.SessionStart.0").unwrap()
    ));

    // The groups of ours in an event: [matcher, command].
    let ours = |event: &str| -> Vec<(Option<String>, String)> {
        at(&settings, &format!("hooks.{event}"))
            .unwrap()
            .as_array()
            .unwrap()
            .iter()
            .filter(|group| text(group, "hooks.0.command").contains(PLUGIN_ROOT))
            .map(|group| {
                (
                    group
                        .get("matcher")
                        .and_then(Json::as_str)
                        .map(str::to_string),
                    text(group, "hooks.0.command").to_string(),
                )
            })
            .collect()
    };
    let (hook, session) = (hook(), session());
    assert_eq!(ours("SessionStart"), [(None, format!("{session} claude"))]);
    assert_eq!(
        ours("UserPromptSubmit"),
        [(None, format!("{hook} claude working"))]
    );
    assert_eq!(
        ours("PreToolUse"),
        [(
            Some("^(?!(AskUserQuestion|ExitPlanMode)$)".to_string()),
            format!("{hook} claude working-if-active")
        )]
    );
    assert_eq!(
        ours("PermissionRequest"),
        [(None, format!("{hook} claude blocked"))]
    );
    assert_eq!(
        ours("Notification"),
        [
            (
                Some(
                    "permission_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input"
                        .to_string()
                ),
                format!("{hook} claude blocked")
            ),
            (
                Some("idle_prompt".to_string()),
                format!("{hook} claude idle-if-working")
            ),
        ]
    );
    for event in ["PostToolUse", "PostToolUseFailure", "ElicitationResult"] {
        assert_eq!(
            ours(event),
            [(None, format!("{hook} claude working-if-blocked"))],
            "{event}"
        );
    }
    assert_eq!(ours("Stop"), [(None, format!("{hook} claude done"))]);
    assert_eq!(ours("StopFailure"), [(None, format!("{hook} claude done"))]);
    assert_eq!(
        ours("SessionEnd"),
        [(None, format!("{hook} claude release"))]
    );
    assert!(at(&settings, "hooks.SubagentStop").is_none());
    assert!(at(&settings, "hooks.PostToolBatch").is_none());
}

#[test]
fn claude_pre_tool_use_skips_ask_user_question_and_exit_plan_mode_only() {
    let host = Host::new();
    host.install(&["claude"]);
    let group = read_json(&host.claude_path());
    // Claude Code treats a matcher with regex characters as an unanchored JavaScript RegExp.
    let matcher = fancy_regex::Regex::new(text(&group, "hooks.PreToolUse.0.matcher")).unwrap();
    let matches = |tool: &str| matcher.is_match(tool).unwrap();
    assert!(matches("Bash"));
    assert!(matches("mcp__memory__read"));
    assert!(matches("AskUserQuestionTool"));
    assert!(!matches("AskUserQuestion"));
    assert!(!matches("ExitPlanMode"));
}

#[test]
fn claude_second_install_changes_nothing() {
    let host = Host::new();
    write_json_file(&host.claude_path(), &claude_fixture(), 0o644);
    host.install(&["claude"]);
    let before = read(&host.claude_path());
    let again = host.install(&["claude"]);
    assert!(again.agents[0].changed.is_empty());
    assert_eq!(read(&host.claude_path()), before);
    assert!(again.lines.join("\n").contains("claude: hooks up to date"));
}

#[test]
fn claude_uninstall_restores_the_settings_exactly() {
    let host = Host::new();
    write_json_file(&host.claude_path(), &claude_fixture(), 0o644);
    host.install(&["claude"]);
    let result = host.uninstall();
    let claude = result.agents.iter().find(|a| a.agent == "claude").unwrap();
    assert_eq!(claude.changed, [s(&host.claude_path())]);
    assert!(same(&read_json(&host.claude_path()), &claude_fixture()));
}

#[test]
fn claude_an_install_from_another_plugin_root_is_replaced_in_place() {
    let host = Host::new();
    let mut fixture = claude_fixture();
    let old = json!({"type": "command", "command": "'/old/root/bin/waycar-hook' claude done", "timeout": 10});
    if let Json::Obj(root) = &mut fixture {
        let Some(Json::Obj(mut hooks)) = root.get("hooks").cloned() else {
            panic!()
        };
        hooks.set(
            "Stop",
            j(json!([{"hooks": [old]}, {"hooks": [user_value()]}])),
        );
        root.set("hooks", Json::Obj(hooks));
    }
    write_json_file(&host.claude_path(), &fixture, 0o644);
    assert!(host.status().agents[0].outdated);
    host.install(&["claude"]);
    let stop = read_json(&host.claude_path());
    let stop = at(&stop, "hooks.Stop").unwrap();
    assert_eq!(stop.as_array().unwrap().len(), 2);
    assert_eq!(
        text(stop, "0.hooks.0.command"),
        format!("{} claude done", hook())
    );
    assert!(same(
        at(stop, "1").unwrap(),
        &j(json!({"hooks": [user_value()]}))
    ));
}

#[test]
fn claude_our_handler_inside_someone_elses_group_is_removed_theirs_kept() {
    let host = Host::new();
    let mut fixture = claude_fixture();
    if let Json::Obj(root) = &mut fixture {
        let Some(Json::Obj(mut hooks)) = root.get("hooks").cloned() else {
            panic!()
        };
        hooks.set(
            "Stop",
            j(json!([{"hooks": [user_value(), {"type": "command", "command": "'/old/bin/waycar-hook' claude done"}]}])),
        );
        root.set("hooks", Json::Obj(hooks));
    }
    write_json_file(&host.claude_path(), &fixture, 0o644);
    host.uninstall();
    let settings = read_json(&host.claude_path());
    assert!(same(
        at(&settings, "hooks.Stop").unwrap(),
        &j(json!([{"hooks": [user_value()]}]))
    ));
}

// MARK: - Groups shared with another tool's handlers (agent-deck)

const AGENT_DECK: &str = "/home/u/.local/bin/agent-deck hook-handler";

/// agent-deck 1.16.38's Claude hooks (`hookEventConfigs`): event, matcher,
/// async, env prefix.
const AGENT_DECK_CLAUDE: &[(&str, Option<&str>, bool, &str)] = &[
    ("SessionStart", None, true, ""),
    ("UserPromptSubmit", None, false, ""),
    ("PreToolUse", None, false, "AGENTDECK_PRETOOL_SYNC=1 "),
    ("Stop", None, false, "AGENTDECK_STOP_SYNC=1 "),
    ("PermissionRequest", None, false, ""),
    (
        "Notification",
        Some("permission_prompt|elicitation_dialog"),
        true,
        "",
    ),
    ("SessionEnd", None, true, ""),
    ("PreCompact", None, false, ""),
];

/// `agent-deck hooks install` on a Claude settings object, as its
/// `mergeHookEvent` does it: its handler goes into the event's first group
/// with the same matcher (none counting as ""), whoever's that group is,
/// and into a new group only when there is none.
fn agent_deck_merge(settings: &Json) -> Json {
    let mut root = settings.as_object().unwrap().clone();
    let mut hooks = root
        .get("hooks")
        .and_then(Json::as_object)
        .cloned()
        .unwrap_or_default();
    for (event, matcher, run_async, env) in AGENT_DECK_CLAUDE {
        let mut handler = Obj::new();
        handler.set("type", Json::str("command"));
        handler.set("command", Json::Str(format!("{env}{AGENT_DECK}")));
        if *run_async {
            handler.set("async", Json::Bool(true));
        }
        let mut groups = hooks
            .get(event)
            .and_then(Json::as_array)
            .cloned()
            .unwrap_or_default();
        let wanted = matcher.unwrap_or("");
        match groups
            .iter_mut()
            .find(|group| group.get("matcher").and_then(Json::as_str).unwrap_or("") == wanted)
        {
            Some(Json::Obj(group)) => {
                let mut list = group
                    .get("hooks")
                    .and_then(Json::as_array)
                    .cloned()
                    .unwrap_or_default();
                list.push(Json::Obj(handler));
                group.set("hooks", Json::Arr(list));
            }
            _ => {
                let mut group = Obj::new();
                if let Some(matcher) = matcher {
                    group.set("matcher", Json::str(*matcher));
                }
                group.set("hooks", Json::Arr(vec![Json::Obj(handler)]));
                groups.push(Json::Obj(group));
            }
        }
        hooks.set(*event, Json::Arr(groups));
    }
    root.set("hooks", Json::Obj(hooks));
    Json::Obj(root)
}

/// Every command in `value` that is not ours, in file order.
fn foreign_commands(value: &Json) -> Vec<String> {
    let mut all = Vec::new();
    commands_in(value, &mut all);
    all.into_iter()
        .filter(|command| !is_our_command(command))
        .map(str::to_string)
        .collect()
}

/// The claude fixture with the current hooks installed, then agent-deck's merged in.
fn claude_shared_with_agent_deck(host: &Host, ctx: &Ctx) -> Json {
    write_json_file(&host.claude_path(), &claude_fixture(), 0o644);
    install_agents(ctx, Some(&["claude"])).unwrap();
    let merged = agent_deck_merge(&read_json(&host.claude_path()));
    write_json_file(&host.claude_path(), &merged, 0o644);
    merged
}

#[test]
fn claude_groups_another_tool_merged_its_handlers_into_stay_installed_and_untouched() {
    let host = Host::new();
    let merged = claude_shared_with_agent_deck(&host, &host.ctx());
    // agent-deck shares the groups of ours that come first in their event.
    for event in ["UserPromptSubmit", "Stop", "SessionEnd"] {
        let group = at(&merged, &format!("hooks.{event}.0.hooks")).unwrap();
        assert!(is_our_handler(at(group, "0").unwrap()), "{event}");
        assert!(text(group, "1.command").ends_with(AGENT_DECK), "{event}");
    }

    let row = host.row("claude");
    assert!(row.installed && !row.outdated);
    let before = read(&host.claude_path());
    let again = host.install(&["claude"]);
    assert!(again.agents[0].changed.is_empty());
    assert_eq!(read(&host.claude_path()), before);
}

#[test]
fn claude_an_update_rewrites_only_our_handlers_inside_shared_groups() {
    let host = Host::new();
    let old_root = Ctx {
        plugin_root: PathBuf::from("/old/plugin"),
        ..host.ctx()
    };
    claude_shared_with_agent_deck(&host, &old_root);
    assert!(host.row("claude").outdated);
    host.install(&["claude"]);
    assert!(host.row("claude").installed);

    // The file a current install and then agent-deck would have written.
    let fresh = Host::new();
    let expected = claude_shared_with_agent_deck(&fresh, &fresh.ctx());
    assert_eq!(
        read_json(&host.claude_path()).to_pretty(),
        expected.to_pretty()
    );
}

#[test]
fn claude_uninstall_keeps_every_handler_another_tool_merged_into_our_groups() {
    let host = Host::new();
    let merged = claude_shared_with_agent_deck(&host, &host.ctx());
    host.uninstall();
    let settings = read_json(&host.claude_path());
    assert!(!host.row("claude").outdated);
    assert_eq!(foreign_commands(&settings), foreign_commands(&merged));
    assert!(same(
        at(&settings, "hooks.Stop").unwrap(),
        &j(
            json!([{"hooks": [{"type": "command", "command": format!("AGENTDECK_STOP_SYNC=1 {AGENT_DECK}")}]}])
        )
    ));
}

#[test]
fn claude_writes_through_a_symlinked_settings_json_and_keeps_its_mode() {
    let host = Host::new();
    let real = host.path("dotfiles/claude-settings.json");
    write_json_file(&real, &claude_fixture(), 0o600);
    fs::create_dir(host.path(".claude")).unwrap();
    symlink(&real, host.claude_path()).unwrap();
    host.install(&["claude"]);
    assert!(
        fs::symlink_metadata(host.claude_path())
            .unwrap()
            .file_type()
            .is_symlink()
    );
    assert_eq!(mode_of(&real), 0o600);
    assert!(at(&read_json(&real), "hooks.Stop").is_some());
}

#[test]
fn claude_invalid_json_is_reported_and_left_untouched() {
    let host = Host::new();
    fs::create_dir(host.path(".claude")).unwrap();
    fs::write(host.claude_path(), "{ not json").unwrap();
    let result = host.install(&["claude"]);
    assert!(
        result.agents[0]
            .error
            .as_deref()
            .unwrap()
            .contains("not valid JSON")
    );
    assert!(result.lines[0].starts_with("claude: error:"));
    assert_eq!(read(&host.claude_path()), "{ not json");
}

// MARK: - Codex

fn seed_codex(host: &Host, toml: &str) {
    write_json_file(&host.codex_hooks_path(), &codex_hooks(), 0o644);
    write_text(&host.codex_toml_path(), toml, 0o600);
}

#[test]
fn codex_adds_the_entries_after_moshis_and_turns_the_hooks_feature_on() {
    let host = Host::new();
    seed_codex(&host, CODEX_TOML);
    let result = host.install(&["codex"]);
    let codex = &result.agents[0];
    assert!(codex.installed);
    assert_eq!(
        codex.changed,
        [s(&host.codex_hooks_path()), s(&host.codex_toml_path())]
    );

    let file = read_json(&host.codex_hooks_path());
    let hooks = at(&file, "hooks").unwrap();
    assert!(same(
        at(hooks, "SessionStart.0").unwrap(),
        at(&codex_hooks(), "hooks.SessionStart.0").unwrap()
    ));
    assert!(same(
        at(hooks, "Stop.0").unwrap(),
        at(&codex_hooks(), "hooks.Stop.0").unwrap()
    ));
    // event -> [matcher, command, timeout] of the groups of ours.
    let (hook, session) = (hook(), session());
    let mut seen = Vec::new();
    for (event, groups) in hooks.as_object().unwrap().iter() {
        let ours: Vec<(Option<String>, String, f64)> = groups
            .as_array()
            .unwrap()
            .iter()
            .filter(|g| text(g, "hooks.0.command").contains(PLUGIN_ROOT))
            .map(|g| {
                let Some(Json::Num(timeout)) = at(g, "hooks.0.timeout") else {
                    panic!()
                };
                (
                    g.get("matcher").and_then(Json::as_str).map(str::to_string),
                    text(g, "hooks.0.command").to_string(),
                    *timeout,
                )
            })
            .collect();
        seen.push((event.to_string(), ours));
    }
    let expected: Vec<(&str, String, f64)> = vec![
        ("SessionStart", format!("{session} codex"), 10.0),
        ("Stop", format!("{hook} codex done"), 10.0),
        ("UserPromptSubmit", format!("{hook} codex working"), 10.0),
        (
            "PreToolUse",
            format!("{hook} codex working-if-active"),
            10.0,
        ),
        ("PermissionRequest", format!("{hook} codex blocked"), 10.0),
        (
            "PostToolUse",
            format!("{hook} codex working-if-blocked"),
            10.0,
        ),
        ("Interrupt", format!("{hook} codex idle"), 3.0),
        ("SessionEnd", format!("{hook} codex release"), 3.0),
    ];
    assert_eq!(seen.len(), expected.len());
    for (event, command, timeout) in expected {
        let (_, ours) = seen.iter().find(|(name, _)| name == event).unwrap();
        assert_eq!(ours, &[(None, command, timeout)], "{event}");
    }

    let toml = read(&host.codex_toml_path());
    let parsed = TomlDoc::parse(&toml).unwrap();
    assert_eq!(parsed.hooks_flag(), FeatureFlag::On);
    let table: toml::Table = toml.parse().unwrap();
    assert_eq!(
        table["notify"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_str().unwrap())
            .collect::<Vec<_>>(),
        ["/opt/homebrew/bin/moshi-hook", "codex-notify"]
    );
    assert_eq!(table["features"]["rmcp_client"].as_bool(), Some(true));
    assert_eq!(
        table["projects"]["/home/u/src"]["trust_level"].as_str(),
        Some("trusted")
    );
    assert!(toml.contains("# my codex config"));
    assert!(toml.contains("# keep these"));
    assert_eq!(mode_of(&host.codex_toml_path()), 0o600);

    assert!(codex.needs_codex_review);
    assert!(result.lines.join("\n").contains("/hooks"));
}

#[test]
fn codex_second_install_changes_nothing() {
    let host = Host::new();
    seed_codex(&host, CODEX_TOML);
    host.install(&["codex"]);
    let hooks_before = read(&host.codex_hooks_path());
    let toml_before = read(&host.codex_toml_path());
    assert!(host.install(&["codex"]).agents[0].changed.is_empty());
    assert_eq!(read(&host.codex_hooks_path()), hooks_before);
    assert_eq!(read(&host.codex_toml_path()), toml_before);
}

#[test]
fn codex_uninstall_removes_only_ours_and_leaves_config_toml_alone() {
    let host = Host::new();
    seed_codex(&host, CODEX_TOML);
    host.install(&["codex"]);
    let toml_after_install = read(&host.codex_toml_path());
    host.uninstall();
    assert!(same(&read_json(&host.codex_hooks_path()), &codex_hooks()));
    assert_eq!(read(&host.codex_toml_path()), toml_after_install);
}

#[test]
fn codex_an_update_keeps_another_tools_handlers_in_our_groups_at_their_trust_keys() {
    let host = Host::new();
    seed_codex(&host, CODEX_TOML);
    let old_root = Ctx {
        plugin_root: PathBuf::from("/old/plugin"),
        ..host.ctx()
    };
    install_agents(&old_root, Some(&["codex"])).unwrap();
    // Another tool appends its handler to every group of ours.
    let mut file = read_json(&host.codex_hooks_path());
    let Some(Json::Obj(hooks)) = file.as_object().and_then(|f| f.get("hooks")).cloned() else {
        panic!()
    };
    let mut shared = Obj::new();
    for (event, groups) in hooks.iter() {
        let groups = groups
            .as_array()
            .unwrap()
            .iter()
            .map(|group| match group {
                Json::Obj(fields) if is_our_handler(at(group, "hooks.0").unwrap()) => {
                    let mut fields = fields.clone();
                    let mut list = group.get("hooks").unwrap().as_array().unwrap().clone();
                    list.push(j(
                        json!({"type": "command", "command": "/usr/local/bin/other-hook"}),
                    ));
                    fields.set("hooks", Json::Arr(list));
                    Json::Obj(fields)
                }
                other => other.clone(),
            })
            .collect();
        shared.set(event, Json::Arr(groups));
    }
    if let Json::Obj(root) = &mut file {
        root.set("hooks", Json::Obj(shared));
    }
    write_json_file(&host.codex_hooks_path(), &file, 0o644);
    let other_keys = |file: &Json| -> Vec<String> {
        let mut keys = Vec::new();
        for (event, groups) in at(file, "hooks").unwrap().as_object().unwrap().iter() {
            for (i, group) in groups.as_array().unwrap().iter().enumerate() {
                for (k, handler) in group
                    .get("hooks")
                    .unwrap()
                    .as_array()
                    .unwrap()
                    .iter()
                    .enumerate()
                {
                    if text(handler, "command") == "/usr/local/bin/other-hook" {
                        keys.push(format!("{event}:{i}:{k}"));
                    }
                }
            }
        }
        keys
    };
    assert_eq!(other_keys(&file).len(), 8);
    assert!(host.row("codex").outdated);

    host.install(&["codex"]);
    let updated = read_json(&host.codex_hooks_path());
    assert_eq!(other_keys(&updated), other_keys(&file));
    let ours: Vec<String> = codex_trust_entries(at(&updated, "hooks"), "p")
        .into_iter()
        .map(|entry| entry.key)
        .collect();
    let before: Vec<String> = codex_trust_entries(at(&file, "hooks"), "p")
        .into_iter()
        .map(|entry| entry.key)
        .collect();
    assert_eq!(ours, before);
    assert!(host.row("codex").installed);
    assert!(host.install(&["codex"]).agents[0].changed.is_empty());
}

#[test]
fn codex_trust_hashes_match_the_ones_codex_recorded() {
    // Hashes Codex 0.159 wrote to a config.toml after a /hooks review.
    assert_eq!(
        codex_trust_hash(
            "SessionStart",
            &j(json!({"type": "command", "command": "'/opt/homebrew/bin/moshi-hook' codex-hook"}))
        ),
        "sha256:32c80cd33fbfcfc4ae4f2feca77149fe3334b1113c6598676f753fd942500de2"
    );
    assert_eq!(
        codex_trust_hash(
            "SessionStart",
            &j(
                json!({"type": "command", "command": "bash '/Users/mjaverto/.codex/herdr-agent-state.sh' session", "timeout": 10})
            )
        ),
        "sha256:5d230c9fafd15ab97779c06989382330df1130a72eaf92d5748de8b1ed29242a"
    );
    assert_eq!(
        codex_trust_hash(
            "Stop",
            &j(json!({"type": "command", "command": "'/opt/homebrew/bin/moshi-hook' codex-hook"}))
        ),
        "sha256:a0550731637177c048527d803117304a1b3d0f9e4f2580a9fba31d53bfe4cb8f"
    );
}

#[test]
fn codex_review_is_needed_until_every_one_of_our_hooks_is_trusted_with_its_current_hash() {
    let host = Host::new();
    seed_codex(&host, CODEX_TOML);
    host.install(&["codex"]);
    let file = read_json(&host.codex_hooks_path());
    let hooks_path = s(&host.codex_hooks_path());
    let entries = codex_trust_entries(at(&file, "hooks"), &hooks_path);
    assert_eq!(entries.len(), 8);
    assert!(
        entries
            .iter()
            .any(|e| e.key == format!("{hooks_path}:session_start:1:0"))
    );
    assert!(
        entries
            .iter()
            .any(|e| e.key == format!("{hooks_path}:user_prompt_submit:0:0"))
    );
    let base = read(&host.codex_toml_path());
    let trust = |list: &[TrustEntry]| -> String {
        list.iter()
            .map(|e| {
                format!(
                    "\n[hooks.state.\"{}\"]\ntrusted_hash = \"{}\"\n",
                    e.key, e.hash
                )
            })
            .collect()
    };

    fs::write(host.codex_toml_path(), format!("{base}{}", trust(&entries))).unwrap();
    assert!(!host.row("codex").needs_codex_review);
    assert!(host.row("codex").installed);

    fs::write(
        host.codex_toml_path(),
        format!("{base}{}", trust(&entries[1..])),
    )
    .unwrap();
    assert!(host.row("codex").needs_codex_review);

    let mut stale = entries.clone();
    stale[0].hash = "sha256:0000".into();
    fs::write(host.codex_toml_path(), format!("{base}{}", trust(&stale))).unwrap();
    assert!(host.row("codex").needs_codex_review);

    let disabled = format!(
        "{base}{}\n[hooks.state.\"{}\"]\ntrusted_hash = \"{}\"\nenabled = false\n",
        trust(&entries[1..]),
        entries[0].key,
        entries[0].hash
    );
    fs::write(host.codex_toml_path(), disabled).unwrap();
    assert!(host.row("codex").needs_codex_review);
}

// MARK: - Codex feature flag

fn parsed(text: &str) -> toml::Table {
    text.parse().unwrap()
}

#[test]
fn feature_flag_adds_hooks_true_under_an_existing_features_table() {
    let edit = enable_codex_hooks_feature(Some("[features]\nfoo = 1\n\n[other]\nhooks = false\n"))
        .unwrap();
    assert!(edit.changed);
    assert_eq!(
        parsed(&edit.text),
        parsed("[features]\nfoo = 1\nhooks = true\n[other]\nhooks = false\n")
    );
}

#[test]
fn feature_flag_leaves_an_explicit_hooks_false_alone_and_reports_it() {
    let text = "a = 1\n[features]\nhooks = false # off\nx = 2\n";
    assert_eq!(
        enable_codex_hooks_feature(Some(text)).unwrap(),
        FeatureEdit {
            text: text.into(),
            changed: false,
            disabled: true
        }
    );
}

#[test]
fn feature_flag_install_keeps_the_users_hooks_false_still_installs_hooks_json_and_reports_it() {
    let host = Host::new();
    fs::create_dir(host.path(".codex")).unwrap();
    let toml = "[features]\nhooks = false # off\n";
    write_text(&host.codex_toml_path(), toml, 0o600);
    let first = host.install(&["codex"]);
    let codex = &first.agents[0];
    assert_eq!(read(&host.codex_toml_path()), toml);
    assert_eq!(codex.changed, [s(&host.codex_hooks_path())]);
    assert!(codex.hooks_disabled);
    assert!(!codex.installed);
    let file = read_json(&host.codex_hooks_path());
    assert!(
        at(&file, "hooks")
            .unwrap()
            .as_object()
            .unwrap()
            .iter()
            .any(|(_, groups)| {
                groups
                    .as_array()
                    .unwrap()
                    .iter()
                    .any(|g| text(g, "hooks.0.command").contains(PLUGIN_ROOT))
            })
    );
    assert!(
        first
            .lines
            .iter()
            .any(|line| line.starts_with("codex:") && line.contains("hooks = false"))
    );

    let status = host.status();
    let row = status.agents.iter().find(|a| a.agent == "codex").unwrap();
    assert!(row.hooks_disabled);
    assert!(!row.installed);
    assert!(
        status
            .lines
            .iter()
            .any(|line| line.contains("hooks = false"))
    );

    let hooks_before = read(&host.codex_hooks_path());
    let again = host.install(&["codex"]).agents.remove(0);
    assert!(again.changed.is_empty());
    assert!(again.hooks_disabled);
    assert_eq!(read(&host.codex_toml_path()), toml);
    assert_eq!(read(&host.codex_hooks_path()), hooks_before);
}

#[test]
fn feature_flag_install_adds_hooks_true_when_the_key_is_absent_once() {
    let host = Host::new();
    fs::create_dir(host.path(".codex")).unwrap();
    write_text(&host.codex_toml_path(), "[features]\nfoo = 1\n", 0o600);
    let codex = host.install(&["codex"]).agents.remove(0);
    assert!(!codex.hooks_disabled);
    assert!(codex.installed);
    assert_eq!(
        parsed(&read(&host.codex_toml_path()))["features"],
        parsed("[features]\nfoo = 1\nhooks = true\n")["features"]
    );
    let toml_before = read(&host.codex_toml_path());
    assert!(host.install(&["codex"]).agents[0].changed.is_empty());
    assert_eq!(read(&host.codex_toml_path()), toml_before);
    assert!(!host.row("codex").hooks_disabled);
}

#[test]
fn feature_flag_appends_a_features_table_when_there_is_none() {
    let text = |input| enable_codex_hooks_feature(input).unwrap().text;
    assert_eq!(
        text(Some("model = \"m\"")),
        "model = \"m\"\n\n[features]\nhooks = true\n"
    );
    assert_eq!(text(Some("")), "[features]\nhooks = true\n");
    assert_eq!(text(None), "[features]\nhooks = true\n");
}

#[test]
fn feature_flag_leaves_a_file_that_already_has_it_alone() {
    let text = "[features]\nhooks = true\n";
    assert_eq!(
        enable_codex_hooks_feature(Some(text)).unwrap(),
        FeatureEdit {
            text: text.into(),
            changed: false,
            disabled: false
        }
    );
}

#[test]
fn feature_flag_refuses_an_edit_it_cannot_make_safely() {
    for text in ["features = { foo = true }\n", "features.foo = true\n"] {
        let error = enable_codex_hooks_feature(Some(text)).unwrap_err();
        assert!(error.contains("by hand"), "{text}: {error}");
    }
}

#[test]
fn feature_flag_an_unwritable_config_toml_leaves_hooks_json_untouched() {
    let host = Host::new();
    fs::create_dir(host.path(".codex")).unwrap();
    fs::write(host.codex_toml_path(), "features.foo = true\n").unwrap();
    let result = host.install(&["codex"]);
    assert!(
        result.agents[0]
            .error
            .as_deref()
            .unwrap()
            .contains("by hand")
    );
    assert!(!host.codex_hooks_path().exists());
}

// MARK: - Extensions

struct ExtensionPaths {
    omp: PathBuf,
    pi: PathBuf,
    opencode: PathBuf,
    opencode_chat_prompt: PathBuf,
}

fn extension_paths(host: &Host) -> ExtensionPaths {
    ExtensionPaths {
        omp: host.path(".omp/agent/extensions/waycar-agent-state.ts"),
        pi: host.path(".pi/agent/extensions/waycar-agent-state.ts"),
        opencode: host.path("xdg/opencode/plugins/waycar-agent-state.js"),
        opencode_chat_prompt: host.path("xdg/opencode/plugins/waycar-chat-prompt.js"),
    }
}

#[test]
fn extensions_copy_each_one_with_the_plugin_root_filled_in() {
    let host = Host::new();
    let paths = extension_paths(&host);
    let result = host.install(&["omp", "pi", "opencode"]);
    let root_json = crate::js_json::quote(PLUGIN_ROOT);
    for (agent, path) in [
        ("omp", &paths.omp),
        ("pi", &paths.pi),
        ("opencode", &paths.opencode),
    ] {
        let entry = result.agents.iter().find(|a| a.agent == agent).unwrap();
        assert_eq!(entry.config_path.as_deref(), Some(s(path).as_str()));
        assert!(entry.installed);
        let content = read(path);
        assert!(content.contains("installed by waycar"));
        assert!(content.contains(&root_json), "{agent}");
        assert!(!content.contains("__WAYCAR_PLUGIN_ROOT__"), "{agent}");
    }
    // opencode's second file, the Chat Prompt injection extension (ADR 0025).
    let entry = result
        .agents
        .iter()
        .find(|a| a.agent == "opencode")
        .unwrap();
    assert!(entry.changed.contains(&s(&paths.opencode_chat_prompt)));
    let chat = read(&paths.opencode_chat_prompt);
    assert!(chat.contains("installed by waycar"));
    assert!(chat.contains("experimental.chat.system.transform"));
    assert!(chat.contains(&root_json), "chat prompt");
    assert!(!chat.contains("__WAYCAR_PLUGIN_ROOT__"), "chat prompt");
    assert!(paths_changed(&host.install(&["omp", "pi", "opencode"])).is_empty());
}

fn paths_changed(result: &HooksResult) -> Vec<String> {
    paths(&result.agents)
}

#[test]
fn extensions_never_overwrite_a_file_waycar_did_not_install() {
    let host = Host::new();
    let path = extension_paths(&host).omp;
    write_text(&path, "// mine\n", 0o644);
    let result = host.install(&["omp"]);
    assert!(
        result.agents[0]
            .error
            .as_deref()
            .unwrap()
            .contains("not installed by Waycar")
    );
    host.uninstall();
    assert_eq!(read(&path), "// mine\n");
}

#[test]
fn extensions_never_overwrite_a_chat_prompt_file_waycar_did_not_install_and_change_nothing_else() {
    let host = Host::new();
    let paths = extension_paths(&host);
    write_text(&paths.opencode_chat_prompt, "// mine\n", 0o644);
    let result = host.install(&["opencode"]);
    assert!(
        result.agents[0]
            .error
            .as_deref()
            .unwrap()
            .contains("not installed by Waycar")
    );
    assert!(!paths.opencode.exists());
    host.uninstall();
    assert_eq!(read(&paths.opencode_chat_prompt), "// mine\n");
}

#[test]
fn extensions_uninstall_removes_ours() {
    let host = Host::new();
    host.install(&["omp", "pi", "opencode"]);
    host.uninstall();
    let paths = extension_paths(&host);
    for path in [
        &paths.omp,
        &paths.pi,
        &paths.opencode,
        &paths.opencode_chat_prompt,
    ] {
        assert!(!path.exists(), "{}", path.display());
    }
}

#[test]
fn extensions_kilo_gets_opencodes_two_plugins_in_its_own_config_dir_labelled_kilo() {
    let host = Host::new();
    let dir = host.path("xdg/kilo/plugins");
    let result = host.install(&["kilo"]);
    assert_eq!(
        result.agents[0].changed,
        [
            s(&dir.join("waycar-agent-state.js")),
            s(&dir.join("waycar-chat-prompt.js"))
        ]
    );
    let state = read(&dir.join("waycar-agent-state.js"));
    assert!(state.contains("const AGENT = \"kilo\";"));
    assert!(!state.contains("__WAYCAR_"));
    assert!(
        read(&dir.join("waycar-chat-prompt.js")).contains("experimental.chat.system.transform")
    );
    assert!(
        !extension_paths(&host).opencode.exists(),
        "opencode's own dir is untouched"
    );
}

// MARK: - Claude-format JSON hooks of the other kinds

fn shared_path(host: &Host, agent: &str) -> PathBuf {
    host.path(match agent {
        "qwen" => ".qwen/settings.json",
        "gemini" => ".gemini/settings.json",
        "devin" => ".config/devin/config.json",
        _ => "xdg/muse/settings.json",
    })
}

#[test]
fn shared_settings_merge_idempotently_and_uninstall_restores_the_file() {
    for agent in ["qwen", "gemini", "devin", "muse"] {
        let host = Host::new();
        let path = shared_path(&host, agent);
        // Muse refuses a settings file without its schema_version.
        let mut original = Obj::new();
        if agent == "muse" {
            original.set("schema_version", Json::Num(1.0));
        }
        original.set("model", j(json!({"name": "m"})));
        original.set("hooks", j(json!({"Stop": [{"hooks": [user_value()]}]})));
        original.set("ui", j(json!({"theme": "x"})));
        let original = Json::Obj(original);
        write_json_file(&path, &original, 0o644);
        let before = read(&path);
        assert!(host.install(&[agent]).agents[0].installed, "{agent}");
        let settings = read_json(&path);
        assert_eq!(keys(&settings), keys(&original), "{agent}");
        assert!(
            same(
                at(&settings, "hooks.Stop.0").unwrap(),
                &j(json!({"hooks": [user_value()]}))
            ),
            "{agent}"
        );
        assert!(host.row(agent).installed, "{agent}");
        assert!(
            host.install(&[agent]).agents[0].changed.is_empty(),
            "{agent}"
        );
        host.uninstall();
        assert_eq!(read(&path), before, "{agent}");
    }
}

fn commands_of(value: &Json, path: &str) -> Vec<String> {
    at(value, path)
        .unwrap()
        .as_array()
        .unwrap()
        .iter()
        .map(|group| text(group, "hooks.0.command").to_string())
        .collect()
}

#[test]
fn qwen_leaves_notification_alone_and_maps_permission_request_to_blocked() {
    let host = Host::new();
    host.install(&["qwen"]);
    let settings = read_json(&shared_path(&host, "qwen"));
    assert!(at(&settings, "hooks.Notification").is_none());
    assert_eq!(
        commands_of(&settings, "hooks.PermissionRequest"),
        [format!("{} qwen blocked", hook())]
    );
    assert_eq!(
        commands_of(&settings, "hooks.SessionStart"),
        [format!("{} qwen", session())]
    );
}

#[test]
fn gemini_handlers_carry_a_name_and_a_millisecond_timeout_payload_events_go_to_hook_session() {
    let host = Host::new();
    host.install(&["gemini"]);
    let settings = read_json(&shared_path(&host, "gemini"));
    let expected = j(json!([{
        "matcher": "*",
        "hooks": [{
            "type": "command",
            "name": "waycar-BeforeAgent",
            "command": format!("{} gemini BeforeAgent", session()),
            "timeout": 10000,
        }],
    }]));
    assert!(same(at(&settings, "hooks.BeforeAgent").unwrap(), &expected));
    assert!(at(&settings, "hooks.PreCompress").is_none());
    assert_eq!(
        text(&settings, "hooks.AfterAgent.0.hooks.0.command"),
        format!("{} gemini done", hook())
    );
}

#[test]
fn muse_schema_version_first_in_a_new_file_prompts_record_the_session_interrupt_is_async() {
    let host = Host::new();
    host.install(&["muse"]);
    let path = shared_path(&host, "muse");
    let settings = read_json(&path);
    assert_eq!(keys(&settings), ["schema_version", "hooks"]);
    assert!(same(
        at(&settings, "schema_version").unwrap(),
        &Json::Num(1.0)
    ));
    assert!(
        at(&settings, "hooks.SessionStart").is_none(),
        "SessionStart never fires on resume"
    );
    assert!(
        at(&settings, "hooks.Notification").is_none(),
        "permission_prompt comes ~6 s after the dialog"
    );
    assert!(same(
        at(&settings, "hooks.UserPromptSubmit").unwrap(),
        &j(
            json!([{"hooks": [{"type": "command", "command": format!("{} muse UserPromptSubmit", session()), "timeout": 10}]}])
        )
    ));
    assert_eq!(
        text(&settings, "hooks.PermissionRequest.0.hooks.0.command"),
        format!("{} muse blocked", hook())
    );
    assert!(same(
        at(&settings, "hooks.Interrupt").unwrap(),
        &j(
            json!([{"hooks": [{"type": "command", "command": format!("{} muse idle", hook()), "timeout": 10, "async": true}]}])
        )
    ));
    assert_eq!(
        text(&settings, "hooks.Stop.0.hooks.0.command"),
        format!("{} muse done", hook())
    );
    assert_eq!(
        text(&settings, "hooks.SessionEnd.0.hooks.0.command"),
        format!("{} muse release", hook())
    );
    host.uninstall();
    assert!(same(
        &read_json(&path),
        &j(json!({"schema_version": 1, "hooks": {}}))
    ));
}

#[test]
fn grok_has_its_own_file_no_look_ahead_matcher_stop_only_ends_an_active_turn() {
    let host = Host::new();
    let path = host.path(".grok/hooks/waycar.json");
    host.install(&["grok"]);
    let file = read_json(&path);
    let hooks = at(&file, "hooks").unwrap();
    assert!(hooks.as_object().unwrap().iter().all(|(_, groups)| {
        groups
            .as_array()
            .unwrap()
            .iter()
            .all(|g| g.get("matcher").is_none())
    }));
    assert_eq!(
        text(hooks, "Stop.0.hooks.0.command"),
        format!("{} grok done-if-active", hook())
    );
    assert_eq!(
        text(hooks, "SessionEnd.0.hooks.0.command"),
        format!("{} grok SessionEnd", session())
    );
    assert!(
        !hooks.to_compact().contains('$'),
        "grok expands $VAR in commands"
    );
    host.uninstall();
    assert!(!path.exists(), "an emptied file of ours is removed");
}

#[test]
fn copilot_flat_bash_handlers_in_its_own_versioned_file_no_permission_request() {
    let host = Host::new();
    let path = host.path(".copilot/hooks/waycar.json");
    host.install(&["copilot"]);
    let file = read_json(&path);
    assert_eq!(keys(&file), ["version", "hooks"]);
    assert!(same(at(&file, "version").unwrap(), &Json::Num(1.0)));
    assert!(same(
        at(&file, "hooks.UserPromptSubmit").unwrap(),
        &j(
            json!([{"type": "command", "bash": format!("{} copilot working", hook()), "timeoutSec": 10}])
        )
    ));
    assert!(at(&file, "hooks.PermissionRequest").is_none());
    assert!(host.install(&["copilot"]).agents[0].changed.is_empty());
    host.uninstall();
    assert!(!path.exists());
}

#[test]
fn cursor_flat_handlers_merged_beside_herdrs_in_cursor_hooks_json() {
    let host = Host::new();
    let path = host.path(".cursor/hooks.json");
    let herdr = json!({"command": "'/home/u/.cursor/herdr-agent-state.sh' session"});
    write_json_file(
        &path,
        &j(json!({"hooks": {"sessionStart": [herdr]}})),
        0o644,
    );
    host.install(&["cursor"]);
    let file = read_json(&path);
    assert!(same(at(&file, "version").unwrap(), &Json::Num(1.0)));
    assert!(same(
        at(&file, "hooks.sessionStart").unwrap(),
        &j(
            json!([herdr, {"command": format!("{} cursor sessionStart", session()), "timeout": 10}])
        )
    ));
    assert!(same(
        at(&file, "hooks.stop").unwrap(),
        &j(json!([{"command": format!("{} cursor done-if-active", hook()), "timeout": 10}]))
    ));
    host.uninstall();
    assert!(same(
        &read_json(&path),
        &j(json!({"version": 1, "hooks": {"sessionStart": [herdr]}}))
    ));
}

// MARK: - agy, hermes, cline and kiro

#[test]
fn agy_a_waycar_group_beside_herdrs_in_gemini_config_hooks_json() {
    let host = Host::new();
    let path = host.path(".gemini/config/hooks.json");
    let herdr = json!({"PreInvocation": [{"type": "command", "command": "bash ~/.gemini/config/hooks/herdr-agent-state.sh session"}]});
    write_json_file(&path, &j(json!({"herdr": herdr})), 0o644);
    host.install(&["agy"]);
    let file = read_json(&path);
    assert_eq!(keys(&file), ["herdr", "waycar"]);
    assert!(same(
        at(&file, "waycar").unwrap(),
        &j(json!({
            "PreInvocation": [{"type": "command", "command": format!("{} agy PreInvocation", session()), "timeout": 10}],
            "PreToolUse": [{"matcher": "*", "hooks": [{"type": "command", "command": format!("{} agy watch-approval", hook()), "timeout": 10}]}],
            "Stop": [{"type": "command", "command": format!("{} agy Stop", session()), "timeout": 10}],
        }))
    ));
    assert!(host.row("agy").installed);
    host.uninstall();
    assert!(same(&read_json(&path), &j(json!({"herdr": herdr}))));
}

#[test]
fn agy_a_waycar_group_holding_someone_elses_command_is_left_alone() {
    let host = Host::new();
    let path = host.path(".gemini/config/hooks.json");
    write_json_file(
        &path,
        &j(json!({"waycar": {"Stop": [{"type": "command", "command": "/usr/bin/true"}]}})),
        0o644,
    );
    assert!(
        host.install(&["agy"]).agents[0]
            .error
            .as_deref()
            .unwrap()
            .contains("not installed by Waycar")
    );
    assert_eq!(
        text(&read_json(&path), "waycar.Stop.0.command"),
        "/usr/bin/true"
    );
}

const HERMES_CONFIG: &str =
    "# Hermes\nmodel:\n  default: \"mock-model\"\n# hooks:\n#   pre_tool_call: []\n";

fn hermes_theirs() -> serde_json::Value {
    json!({"event": "pre_tool_call", "command": "~/.hermes/agent-hooks/block.sh", "approved_at": "2026-10-01T00:00:00Z"})
}

#[test]
fn hermes_appends_a_marked_block_approves_exactly_its_commands_uninstall_restores_both_files() {
    let host = Host::new();
    let config = host.path(".hermes/config.yaml");
    let allowlist = host.path(".hermes/shell-hooks-allowlist.json");
    write_text(&config, HERMES_CONFIG, 0o644);
    write_json_file(
        &allowlist,
        &j(json!({"approvals": [hermes_theirs()]})),
        0o644,
    );
    assert!(host.install(&["hermes"]).agents[0].installed);
    let yaml = read(&config);
    assert!(yaml.starts_with(&format!("{HERMES_CONFIG}\n# >>> waycar hooks")));
    let (hook, session) = (hook(), session());
    assert!(yaml.contains(&format!(
        "\nhooks:\n  pre_llm_call:\n    - command: \"{session} hermes pre_llm_call\"\n      timeout: 10\n"
    )));
    assert!(yaml.contains(&format!(
        "\n  on_session_finalize:\n    - command: \"{hook} hermes release\"\n"
    )));
    let file = read_json(&allowlist);
    let approvals = at(&file, "approvals").unwrap().as_array().unwrap();
    assert!(same(&approvals[0], &j(hermes_theirs())));
    let pairs: Vec<(String, String)> = approvals[1..]
        .iter()
        .map(|a| (text(a, "event").to_string(), text(a, "command").to_string()))
        .collect();
    assert_eq!(
        pairs,
        [
            ("pre_llm_call", format!("{session} hermes pre_llm_call")),
            ("on_human_input_request", format!("{hook} hermes blocked")),
            (
                "on_human_input_resolved",
                format!("{hook} hermes working-if-blocked")
            ),
            ("on_session_end", format!("{session} hermes on_session_end")),
            ("on_session_finalize", format!("{hook} hermes release")),
        ]
        .map(|(event, command)| (event.to_string(), command))
    );
    // `^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d{6})?Z$`. The session command's
    // path is bin/waycar, which a source checkout does not have, so the
    // approval of the `waycar-hook` command shows the format.
    let mtime = fancy_regex::Regex::new(
        r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{6})?Z$",
    )
    .unwrap();
    assert!(
        mtime
            .is_match(text(&approvals[2], "script_mtime_at_approval"))
            .unwrap()
    );
    assert!(host.row("hermes").installed);
    assert!(host.install(&["hermes"]).agents[0].changed.is_empty());

    host.uninstall();
    assert_eq!(read(&config), HERMES_CONFIG);
    assert!(same(
        at(&read_json(&allowlist), "approvals").unwrap(),
        &j(json!([hermes_theirs()]))
    ));
}

#[test]
fn hermes_a_revoked_approval_makes_the_hooks_not_installed_until_the_next_install() {
    let host = Host::new();
    write_text(&host.path(".hermes/config.yaml"), HERMES_CONFIG, 0o644);
    host.install(&["hermes"]);
    let allowlist = host.path(".hermes/shell-hooks-allowlist.json");
    write_json_file(&allowlist, &j(json!({"approvals": []})), 0o644);
    let row = host.row("hermes");
    assert_eq!((row.installed, row.outdated), (false, true));
    host.install(&["hermes"]);
    assert_eq!(
        at(&read_json(&allowlist), "approvals")
            .unwrap()
            .as_array()
            .unwrap()
            .len(),
        5
    );
}

#[test]
fn hermes_a_config_yaml_with_its_own_top_level_hooks_is_left_unchanged() {
    let host = Host::new();
    let config = host.path(".hermes/config.yaml");
    let own = format!("{HERMES_CONFIG}hooks:\n  pre_tool_call:\n    - command: \"x\"\n");
    write_text(&config, &own, 0o644);
    assert!(
        host.install(&["hermes"]).agents[0]
            .error
            .as_deref()
            .unwrap()
            .contains("own top-level hooks")
    );
    assert_eq!(read(&config), own);
    assert!(!host.path(".hermes/shell-hooks-allowlist.json").exists());
}

#[test]
fn cline_one_bash_file_per_event_that_execs_our_command() {
    let host = Host::new();
    let dir = host.path(".cline/hooks");
    host.install(&["cline"]);
    let (hook, session) = (hook(), session());
    let task_start = read(&dir.join("TaskStart"));
    assert!(
        task_start
            .lines()
            .any(|line| line == format!("exec {session} cline TaskStart"))
    );
    let complete = read(&dir.join("TaskComplete"));
    assert!(complete.starts_with("# installed by waycar"));
    assert!(complete.ends_with(&format!("\nexec {hook} cline done\n")));
    assert!(read(&dir.join("SessionShutdown")).ends_with(&format!("exec {hook} cline idle\n")));
    assert!(
        read(&dir.join("PreToolUse")).ends_with(&format!("exec {hook} cline watch-approval\n"))
    );
    host.uninstall();
    assert!(!dir.join("TaskStart").exists());
}

#[test]
fn cline_a_hook_file_of_the_users_blocks_the_install_and_survives_uninstall() {
    let host = Host::new();
    let dir = host.path(".cline/hooks");
    write_text(&dir.join("TaskComplete"), "echo mine\n", 0o644);
    let error = host.install(&["cline"]).agents[0].error.clone().unwrap();
    assert!(
        error.contains("TaskComplete exists and was not installed by Waycar"),
        "{error}"
    );
    assert!(!dir.join("TaskStart").exists());
    host.uninstall();
    assert_eq!(read(&dir.join("TaskComplete")), "echo mine\n");
}

#[test]
fn kiro_a_v3_hook_file_of_ours_and_never_a_file_of_the_users() {
    let host = Host::new();
    let path = host.path(".kiro/hooks/waycar.json");
    host.install(&["kiro"]);
    let file = read_json(&path);
    assert_eq!(text(&file, "version"), "v1");
    let (hook, session) = (hook(), session());
    let pairs: Vec<(String, String)> = at(&file, "hooks")
        .unwrap()
        .as_array()
        .unwrap()
        .iter()
        .map(|h| {
            (
                text(h, "trigger").to_string(),
                text(h, "action.command").to_string(),
            )
        })
        .collect();
    assert_eq!(
        pairs,
        [
            ("SessionStart", format!("{session} kiro")),
            ("UserPromptSubmit", format!("{hook} kiro working")),
            ("PreToolUse", format!("{hook} kiro working-if-active")),
            ("Stop", format!("{hook} kiro done")),
            ("SessionEnd", format!("{hook} kiro release")),
        ]
        .map(|(event, command)| (event.to_string(), command))
    );
    assert!(host.row("kiro").installed);
    fs::write(
        &path,
        r#"{"version":"v1","hooks":[{"trigger":"Stop","action":{"type":"command","command":"say done"}}]}"#,
    )
    .unwrap();
    assert!(
        host.install(&["kiro"]).agents[0]
            .error
            .as_deref()
            .unwrap()
            .contains("not installed by Waycar")
    );
}

// MARK: - Detection and status

fn fake_binary(dir: &Path, name: &str) {
    write_text(&dir.join(name), "#!/bin/sh\n", 0o755);
}

#[test]
fn without_an_agent_list_installs_only_for_agents_found_on_the_host() {
    let mut host = Host::new();
    fs::create_dir(host.path(".claude")).unwrap();
    let bin = host.path("bin");
    fs::create_dir(&bin).unwrap();
    fake_binary(&bin, "codex");
    host.env.set("PATH", s(&bin));
    let result = install(&host.ctx()).unwrap();
    let installed: Vec<&str> = result
        .agents
        .iter()
        .filter(|a| a.installed)
        .map(|a| a.agent.as_str())
        .collect();
    assert_eq!(installed, ["claude", "codex"]);
    assert!(
        result
            .lines
            .contains(&"omp: not found, skipped".to_string())
    );
    assert!(!host.path(".omp").exists());
}

#[test]
fn each_kind_is_found_by_its_own_config_root_or_binary_not_a_siblings() {
    let mut host = Host::new();
    // Antigravity keeps its config under ~/.gemini too.
    fs::create_dir_all(host.path(".gemini/antigravity-cli")).unwrap();
    let bin = host.path("bin");
    fs::create_dir(&bin).unwrap();
    fake_binary(&bin, "cursor-agent");
    fake_binary(&bin, "kiro-cli");
    host.env.set("PATH", s(&bin));
    let detected: Vec<String> = host
        .status()
        .agents
        .into_iter()
        .filter(|a| a.detected)
        .map(|a| a.agent)
        .collect();
    assert_eq!(detected, ["agy", "cursor", "kiro"]);
}

#[test]
fn status_reports_installed_agents_and_writes_nothing() {
    let host = Host::new();
    host.install(&["claude"]);
    let before = read(&host.claude_path());
    let status = host.status();
    assert!(
        status
            .agents
            .iter()
            .find(|a| a.agent == "claude")
            .unwrap()
            .installed
    );
    assert!(
        !status
            .agents
            .iter()
            .find(|a| a.agent == "codex")
            .unwrap()
            .installed
    );
    assert_eq!(
        status.lines[0],
        format!("claude: installed ({})", host.claude_path().display())
    );
    assert_eq!(read(&host.claude_path()), before);
    assert!(!host.codex_hooks_path().exists());
}

// MARK: - agent-kinds (test/agent-kinds.test.js)

const KINDS: &str = include_str!("../../test-vectors/agent-kinds-v1.json");

fn catalog() -> Vec<String> {
    let vector = parse(KINDS).unwrap();
    at(&vector, "kinds")
        .unwrap()
        .as_array()
        .unwrap()
        .iter()
        .map(|kind| kind.as_str().unwrap().to_string())
        .collect()
}

#[test]
fn the_vector_lists_each_kind_once() {
    let kinds = catalog();
    let unique: std::collections::BTreeSet<&String> = kinds.iter().collect();
    assert_eq!(unique.len(), kinds.len());
}

#[test]
fn every_status_hook_kind_is_a_catalog_kind() {
    let kinds = catalog();
    for agent in HOOK_AGENTS {
        assert!(kinds.iter().any(|kind| kind == agent), "{agent}");
    }
}

// MARK: - hooks migrate (plugin 1.x entries that call Node)

const LEGACY_SESSION: &str = "'/old/plugin/bin/node.sh' '/old/plugin/src/hook-session.js' claude";

fn legacy_claude_settings() -> Json {
    j(json!({
        "theme": "dark",
        "hooks": {
            "SessionStart": [
                {"hooks": [{"type": "command", "command": LEGACY_SESSION, "timeout": 10}]},
                {"hooks": [{"type": "command", "command": "echo mine"}]}
            ]
        }
    }))
}

#[test]
fn migrate_rewrites_node_era_entries_and_keeps_everything_else() {
    let host = Host::new();
    write_json_file(&host.claude_path(), &legacy_claude_settings(), 0o644);
    let result = migrate_legacy(&host.ctx()).unwrap();
    assert_eq!(
        result
            .agents
            .iter()
            .map(|r| r.agent.as_str())
            .collect::<Vec<_>>(),
        ["claude"]
    );
    assert_eq!(result.lines.last().map(String::as_str), Some(MIGRATED_LINE));
    let settings = read_json(&host.claude_path());
    assert_eq!(text(&settings, "theme"), "dark");
    let written = read(&host.claude_path());
    assert!(!written.contains("node.sh") && !written.contains("hook-session.js"));
    assert!(written.contains("echo mine"));
    assert!(written.contains(&format!("{} claude", session())));
    assert!(host.row("claude").installed);
}

#[test]
fn migrate_twice_changes_nothing_the_second_time() {
    let host = Host::new();
    write_json_file(&host.claude_path(), &legacy_claude_settings(), 0o644);
    migrate_legacy(&host.ctx()).unwrap();
    let once = read(&host.claude_path());
    let again = migrate_legacy(&host.ctx()).unwrap();
    assert!(again.agents.is_empty() && again.lines.is_empty());
    assert_eq!(read(&host.claude_path()), once);
}

#[test]
fn migrate_leaves_alone_an_agent_that_is_only_out_of_date() {
    let host = Host::new();
    // Installed from another plugin root: out of date, but not Node-era.
    let old_root = Ctx {
        plugin_root: PathBuf::from("/elsewhere/plugin"),
        ..host.ctx()
    };
    install_agents(&old_root, Some(&["gemini"])).unwrap();
    let before = read(&host.path(".gemini/settings.json"));
    assert!(host.row("gemini").outdated);
    let result = migrate_legacy(&host.ctx()).unwrap();
    assert!(result.agents.is_empty() && result.lines.is_empty());
    assert_eq!(read(&host.path(".gemini/settings.json")), before);
}

#[test]
fn migrate_with_no_hook_files_does_nothing() {
    let host = Host::new();
    let result = migrate_legacy(&host.ctx()).unwrap();
    assert!(result.agents.is_empty() && result.lines.is_empty());
    assert!(!host.claude_path().exists());
}

#[test]
fn migrate_asks_codex_for_its_one_hooks_review() {
    let host = Host::new();
    let legacy = j(json!({"hooks": {"SessionStart": [
        {"hooks": [{"type": "command", "command": "'/old/plugin/bin/node.sh' '/old/plugin/src/hook-session.js' codex"}]}
    ]}}));
    write_json_file(&host.codex_hooks_path(), &legacy, 0o644);
    let result = migrate_legacy(&host.ctx()).unwrap();
    assert!(result.lines.iter().any(|line| line == CODEX_REVIEW_LINE));
    assert!(!read(&host.codex_hooks_path()).contains("node.sh"));
}

#[test]
fn migrate_rewrites_a_node_era_handler_inside_a_shared_group_in_place() {
    let host = Host::new();
    let shared = agent_deck_merge(&j(json!({"hooks": {"SessionStart": [
        {"hooks": [{"type": "command", "command": LEGACY_SESSION, "timeout": 10}]}
    ]}})));
    write_json_file(&host.claude_path(), &shared, 0o644);
    assert_eq!(migrate_legacy(&host.ctx()).unwrap().agents.len(), 1);
    let settings = read_json(&host.claude_path());
    let group = at(&settings, "hooks.SessionStart").unwrap();
    assert_eq!(group.as_array().unwrap().len(), 1);
    assert_eq!(
        text(group, "0.hooks.0.command"),
        format!("{} claude", session())
    );
    assert!(same(
        at(group, "0.hooks.1").unwrap(),
        at(&shared, "hooks.SessionStart.0.hooks.1").unwrap()
    ));
    assert_eq!(foreign_commands(&settings), foreign_commands(&shared));
    assert!(host.row("claude").installed);
}
