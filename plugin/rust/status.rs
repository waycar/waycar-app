//! `waycar status [--json]` and the host report the app decodes
//! (waycar-cli.js `status`, `hostReport`).
//!
//! `--json` prints exactly one report object (version 1) on stdout, for the
//! app to decode over SSH; the human form shows what it can, and a broken
//! piece names its error instead of failing the command.

use std::io::Write;

use serde_json::{Map, Value, json};

use crate::VERSION;
use crate::cli::tmux_supported;
use crate::core;
use crate::error::Result;
use crate::exec::{find_on_path, run_program};
use crate::herdr::run_herdr;
use crate::hooks::{self, HooksResult};
use crate::native::Ctx;
use crate::paths::{HostConfig, resolve_host_config};
use crate::tmux;

/// herdr's path on PATH, tmux's `-V` version and herdr-core's `--version`
/// number, when each is there.
struct Backends {
    herdr: Option<String>,
    tmux: Option<String>,
    core: Option<String>,
    zellij: Option<String>,
}

fn detect_backends(ctx: &Ctx) -> Backends {
    Backends {
        herdr: find_on_path("herdr", &ctx.env).map(|path| path.to_string_lossy().into_owned()),
        tmux: tmux::version(&ctx.env).filter(|version| !version.is_empty()),
        // Only `--version` runs: any other subcommand would start a core.
        core: core::core_command(&ctx.env, &ctx.home, &run_program).map(|core| core.version),
        zellij: crate::zellij::command(&ctx.env, &crate::zellij::run_system).map(|z| z.version),
    }
}

fn host_config(ctx: &Ctx) -> Result<HostConfig> {
    resolve_host_config(&ctx.env, &ctx.home, &run_herdr)
}

/// `waycar config-dir`: the resolved plugin config directory, one line. The
/// opencode and kilo Chat Prompt extension asks for it, because it runs in its
/// own runtime and has no other way to resolve it as the app and every hook do.
pub fn print_config_dir(ctx: &Ctx, out: &mut dyn Write) -> Result<()> {
    writeln!(out, "{}", host_config(ctx)?.config_dir.display())?;
    Ok(())
}

/// Reads the agents' hook state; production is [`hooks::status`].
pub type HooksStatus<'a> = &'a dyn Fn(&Ctx) -> Result<HooksResult>;

/// The `--json` object: the Host Tools version and where they live, which
/// backends are here, the config directory and one row per agent (narrowed
/// to the fields the app decodes).
fn host_report(ctx: &Ctx, hooks: &HooksResult) -> Result<Value> {
    let backends = detect_backends(ctx);
    let config = host_config(ctx)?;
    let agents: Vec<Value> = hooks
        .agents
        .iter()
        .map(|row| {
            let mut object = Map::new();
            object.insert("agent".into(), json!(row.agent));
            object.insert("detected".into(), json!(row.detected));
            object.insert("installed".into(), json!(row.installed));
            object.insert("configPath".into(), json!(row.config_path));
            object.insert("needsCodexReview".into(), json!(row.needs_codex_review));
            if row.agent == "codex" {
                object.insert("hooksDisabled".into(), json!(row.hooks_disabled));
            }
            Value::Object(object)
        })
        .collect();
    Ok(json!({
        "version": 1,
        "hostTools": { "version": VERSION, "pluginRoot": ctx.plugin_root.to_string_lossy() },
        "backends": { "herdr": backends.herdr.is_some(), "tmux": backends.tmux, "core": backends.core, "zellij": backends.zellij },
        "configDir": config.config_dir.to_string_lossy(),
        "agents": agents,
    }))
}

/// Write the report of `hooks` as one line of JSON.
pub fn write_report(ctx: &Ctx, hooks: &HooksResult, out: &mut dyn Write) -> Result<()> {
    writeln!(out, "{}", host_report(ctx, hooks)?)?;
    Ok(())
}

pub fn run(ctx: &Ctx, json: bool, out: &mut dyn Write) -> Result<()> {
    run_with(ctx, json, out, &hooks::status)
}

pub fn run_with(
    ctx: &Ctx,
    json: bool,
    out: &mut dyn Write,
    hooks_status: HooksStatus,
) -> Result<()> {
    if json {
        return write_report(ctx, &hooks_status(ctx)?, out);
    }
    writeln!(out, "waycar {VERSION} ({})", ctx.plugin_root.display())?;

    let backends = detect_backends(ctx);
    let tmux_usable = backends.tmux.as_deref().is_some_and(tmux_supported);
    let found: Vec<&str> = [
        backends.herdr.as_ref().map(|_| "herdr"),
        tmux_usable.then_some("tmux"),
        backends.core.as_ref().map(|_| "herdr-core"),
        backends.zellij.as_ref().map(|_| "Zellij"),
    ]
    .into_iter()
    .flatten()
    .collect();
    writeln!(
        out,
        "backends: {}",
        if found.is_empty() {
            "none".to_string()
        } else {
            found.join(", ")
        }
    )?;
    writeln!(
        out,
        "herdr: {}",
        backends.herdr.as_deref().unwrap_or("not found")
    )?;
    let tmux_line = match backends.tmux.as_deref() {
        None => "not found".to_string(),
        Some(version) if tmux_usable => version.to_string(),
        Some(version) => format!("{version} (too old: 3.2 or later required)"),
    };
    writeln!(out, "tmux: {tmux_line}")?;
    writeln!(
        out,
        "herdr-core: {}",
        backends.core.as_deref().unwrap_or("not found")
    )?;

    writeln!(
        out,
        "Zellij: {}",
        backends.zellij.as_deref().unwrap_or("not found")
    )?;

    match host_config(ctx) {
        Ok(config) => {
            writeln!(
                out,
                "config dir: {} ({})",
                config.config_dir.display(),
                config.source.as_str()
            )?;
            writeln!(out, "state dir: {}", config.state_dir.display())?;
        }
        Err(error) => writeln!(out, "config dir: unknown ({error})")?,
    }

    match hooks_status(ctx) {
        Ok(result) => {
            writeln!(out, "hooks:")?;
            for line in &result.lines {
                writeln!(out, "  {line}")?;
            }
        }
        Err(error) => writeln!(out, "hooks: unknown ({error})")?,
    }

    Ok(())
}

#[cfg(test)]
pub(crate) mod tests {

    use super::*;
    use crate::env::Env;
    use crate::error::CliError;
    use crate::hooks::AgentRow;

    /// A scratch home with a `bin` directory of fake commands and a Ctx whose
    /// PATH is that directory alone: no herdr and no tmux unless a test adds
    /// them, whatever this machine has.
    pub(crate) struct Scratch {
        pub ctx: Ctx,
    }

    impl Scratch {
        pub(crate) fn new(name: &str) -> Self {
            let home =
                std::env::temp_dir().join(format!("wc-status-{name}-{}", std::process::id()));
            let _ = std::fs::remove_dir_all(&home);
            std::fs::create_dir_all(home.join("bin")).unwrap();
            let path = home.join("bin").to_string_lossy().into_owned();
            Self {
                ctx: Ctx {
                    env: Env::from_pairs([("PATH", path)]),
                    plugin_root: home.join("plugin"),
                    home,
                },
            }
        }

        pub(crate) fn command(&self, name: &str, body: &str) {
            let path = self.ctx.home.join("bin").join(name);
            crate::test_support::write_script(&path, body, 0o755);
        }

        pub(crate) fn tmux(&self, version: &str) {
            self.command("tmux", &format!("[ \"$2\" = -V ] && echo 'tmux {version}'"));
        }

        /// herdr on PATH that has no plugins, so the config falls back to XDG.
        pub(crate) fn herdr(&self) {
            self.command("herdr", "exit 1");
        }

        /// A `herdr-core` that answers `--version` like the real one and
        /// fails any other subcommand (a real one would start a core).
        pub(crate) fn core(&self, version: &str) {
            self.command(
                "herdr-core",
                &format!("[ \"$1\" = --version ] && echo 'hc {version}' && exit 0\nexit 1"),
            );
        }

        fn herdr_path(&self) -> String {
            self.ctx
                .home
                .join("bin/herdr")
                .to_string_lossy()
                .into_owned()
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.ctx.home);
        }
    }

    pub(crate) fn row(agent: &str, installed: bool) -> AgentRow {
        AgentRow {
            agent: agent.into(),
            installed,
            detected: true,
            config_path: Some(format!("/h/{agent}.json")),
            ..AgentRow::default()
        }
    }

    /// The three rows the JS tests report.
    pub(crate) fn sample_hooks(_: &Ctx) -> Result<HooksResult> {
        Ok(HooksResult {
            agents: vec![
                AgentRow {
                    config_path: Some("/h/.claude/settings.json".into()),
                    ..row("claude", true)
                },
                AgentRow {
                    detected: false,
                    needs_codex_review: true,
                    config_path: Some("/h/.codex/hooks.json".into()),
                    ..row("codex", true)
                },
                AgentRow {
                    detected: false,
                    config_path: Some("/h/.hermes/config.yaml".into()),
                    ..row("hermes", false)
                },
            ],
            lines: vec![
                "claude: installed".into(),
                "codex: installed (review in /hooks)".into(),
            ],
        })
    }

    fn run_text(scratch: &Scratch, json: bool, hooks: HooksStatus) -> (Result<()>, String) {
        let mut out = Vec::new();
        let result = run_with(&scratch.ctx, json, &mut out, hooks);
        (result, String::from_utf8(out).unwrap())
    }

    fn expected(scratch: &Scratch, herdr: bool, tmux: Option<&str>, core: Option<&str>) -> Value {
        json!({
            "version": 1,
            "hostTools": {
                "version": VERSION,
                "pluginRoot": scratch.ctx.plugin_root.to_string_lossy(),
            },
            "backends": { "herdr": herdr, "tmux": tmux, "core": core, "zellij": null },
            "configDir": scratch.ctx.home.join(".config/waycar").to_string_lossy(),
            "agents": [
                { "agent": "claude", "detected": true, "installed": true,
                  "configPath": "/h/.claude/settings.json", "needsCodexReview": false },
                { "agent": "codex", "detected": false, "installed": true,
                  "configPath": "/h/.codex/hooks.json", "needsCodexReview": true,
                  "hooksDisabled": false },
                { "agent": "hermes", "detected": false, "installed": false,
                  "configPath": "/h/.hermes/config.yaml", "needsCodexReview": false },
            ],
        })
    }

    #[test]
    fn status_json_prints_exactly_one_object() {
        let scratch = Scratch::new("one");
        scratch.herdr();
        scratch.tmux("3.4");
        let (result, text) = run_text(&scratch, true, &sample_hooks);
        result.unwrap();
        assert!(text.ends_with("}\n") && text.find('\n') == Some(text.len() - 1));
        assert_eq!(
            serde_json::from_str::<Value>(&text).unwrap(),
            expected(&scratch, true, Some("3.4"), None)
        );
    }

    #[test]
    fn report_key_order_is_the_one_the_app_reads() {
        let scratch = Scratch::new("order");
        let (result, text) = run_text(&scratch, true, &sample_hooks);
        result.unwrap();
        let positions: Vec<usize> = ["version", "hostTools", "backends", "configDir", "agents"]
            .iter()
            .map(|key| text.find(&format!("\"{key}\":")).unwrap())
            .collect();
        assert!(positions.windows(2).all(|pair| pair[0] < pair[1]), "{text}");
        assert!(
            text.contains(
                "\"backends\":{\"herdr\":false,\"tmux\":null,\"core\":null,\"zellij\":null}"
            ),
            "{text}"
        );
        assert!(text.contains(
            "{\"agent\":\"claude\",\"detected\":true,\"installed\":true,\"configPath\":\"/h/.claude/settings.json\",\"needsCodexReview\":false}"
        ));
    }

    #[test]
    fn tmux_missing_reports_null_and_herdr_missing_reports_false() {
        let scratch = Scratch::new("none");
        let (result, text) = run_text(&scratch, true, &sample_hooks);
        result.unwrap();
        assert_eq!(
            serde_json::from_str::<Value>(&text).unwrap(),
            expected(&scratch, false, None, None)
        );
    }

    #[test]
    fn a_too_old_tmux_is_still_reported_by_version() {
        let scratch = Scratch::new("old");
        scratch.tmux("2.7");
        let (result, text) = run_text(&scratch, true, &sample_hooks);
        result.unwrap();
        let report: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(report["backends"]["tmux"], "2.7");
    }

    fn report_of(scratch: &Scratch) -> Value {
        let (result, text) = run_text(scratch, true, &sample_hooks);
        result.unwrap();
        serde_json::from_str(&text).unwrap()
    }

    #[test]
    fn core_on_path_is_reported_by_version_after_tmux() {
        let scratch = Scratch::new("core");
        scratch.core("0.1.14");
        let (result, text) = run_text(&scratch, true, &sample_hooks);
        result.unwrap();
        assert!(
            text.contains(
                "\"backends\":{\"herdr\":false,\"tmux\":null,\"core\":\"0.1.14\",\"zellij\":null}"
            ),
            "{text}"
        );
        assert_eq!(
            serde_json::from_str::<Value>(&text).unwrap(),
            expected(&scratch, false, None, Some("0.1.14"))
        );
    }

    #[test]
    fn zellij_046_is_reported_after_core_without_starting_a_server() {
        let scratch = Scratch::new("zellij");
        scratch.command(
            "zellij",
            "[ \"$1\" = --version ] || exit 99; echo 'zellij 0.46.0'",
        );
        let report = report_of(&scratch);
        assert_eq!(report["version"], 1);
        assert_eq!(report["backends"]["zellij"], "0.46.0");
        assert!(
            run_text(&scratch, false, &sample_hooks)
                .1
                .contains("Zellij: 0.46.0")
        );
    }

    #[test]
    fn a_core_below_the_apps_floor_is_still_reported() {
        let scratch = Scratch::new("coreold");
        scratch.core("0.1.2");
        assert_eq!(report_of(&scratch)["backends"]["core"], "0.1.2");
    }

    #[test]
    fn the_hc_alias_counts() {
        let scratch = Scratch::new("corealias");
        scratch.command("hc", "[ \"$1\" = --version ] && echo 'hc 0.1.14'");
        assert_eq!(report_of(&scratch)["backends"]["core"], "0.1.14");
    }

    #[test]
    fn a_foreign_hc_is_not_core() {
        let scratch = Scratch::new("coreforeign");
        scratch.command("hc", "echo 'hc: herbstclient 0.9'");
        assert_eq!(report_of(&scratch)["backends"]["core"], Value::Null);
    }

    #[test]
    fn no_core_reports_null() {
        let scratch = Scratch::new("corenone");
        assert_eq!(report_of(&scratch)["backends"]["core"], Value::Null);
    }

    #[test]
    fn core_in_local_bin_only_is_found_off_path() {
        let scratch = Scratch::new("corelocal");
        let dir = scratch.ctx.home.join(".local/bin");
        std::fs::create_dir_all(&dir).unwrap();
        crate::test_support::write_script(
            &dir.join("herdr-core"),
            "[ \"$1\" = --version ] && echo 'hc 0.1.14'",
            0o755,
        );
        assert_eq!(report_of(&scratch)["backends"]["core"], "0.1.14");
    }

    #[test]
    fn only_version_is_ever_run() {
        let scratch = Scratch::new("coreonly");
        let log = scratch.ctx.home.join("calls");
        scratch.command(
            "herdr-core",
            &format!(
                "echo \"$*\" >> '{}'\n[ \"$1\" = --version ] && echo 'hc 0.1.14'",
                log.display()
            ),
        );
        let (result, _) = run_text(&scratch, false, &sample_hooks);
        result.unwrap();
        report_of(&scratch);
        let calls = std::fs::read_to_string(&log).unwrap();
        assert!(calls.lines().all(|line| line == "--version"), "{calls}");
    }

    #[test]
    fn human_status_lists_core_as_a_backend_with_its_version() {
        let scratch = Scratch::new("humancore");
        scratch.core("0.1.14");
        let (result, text) = run_text(&scratch, false, &sample_hooks);
        result.unwrap();
        assert!(text.contains("\nbackends: herdr-core\n"), "{text}");
        assert!(text.contains("\nherdr-core: 0.1.14\n"), "{text}");
    }

    #[test]
    fn a_codex_hooks_opt_out_is_marked_on_the_codex_row_only() {
        let scratch = Scratch::new("optout");
        let hooks = |_: &Ctx| {
            Ok(HooksResult {
                agents: vec![
                    row("claude", true),
                    AgentRow {
                        needs_codex_review: true,
                        hooks_disabled: true,
                        ..row("codex", false)
                    },
                ],
                lines: Vec::new(),
            })
        };
        let (result, text) = run_text(&scratch, true, &hooks);
        result.unwrap();
        let report: Value = serde_json::from_str(&text).unwrap();
        let rows = report["agents"].as_array().unwrap();
        assert!(rows[0].get("hooksDisabled").is_none());
        assert_eq!(rows[1]["hooksDisabled"], true);
        assert_eq!(rows[1]["installed"], false);
    }

    #[test]
    fn a_config_failure_prints_nothing_on_stdout() {
        let scratch = Scratch::new("nohome");
        // A file where the config directory's parent must be.
        std::fs::write(scratch.ctx.home.join(".config"), "").unwrap();
        let (result, text) = run_text(&scratch, true, &sample_hooks);
        assert!(result.unwrap_err().message().starts_with("cannot create "));
        assert_eq!(text, "");
    }

    #[test]
    fn a_hooks_failure_in_json_mode_fails_the_command_with_the_message() {
        let scratch = Scratch::new("hookfail");
        let hooks = |_: &Ctx| Err(CliError::failure("settings.json is not JSON"));
        let (result, text) = run_text(&scratch, true, &hooks);
        assert_eq!(
            result.unwrap_err(),
            CliError::failure("settings.json is not JSON")
        );
        assert_eq!(text, "");
    }

    #[test]
    fn human_status_names_backends_tmux_version_config_dir_and_hooks() {
        let scratch = Scratch::new("human");
        scratch.herdr();
        scratch.tmux("3.4");
        let (result, text) = run_text(&scratch, false, &sample_hooks);
        result.unwrap();
        let config = scratch.ctx.home.join(".config/waycar");
        let state = scratch.ctx.home.join(".local/state/waycar");
        assert_eq!(
            text,
            format!(
                "waycar {VERSION} ({})\nbackends: herdr, tmux\nherdr: {}\ntmux: 3.4\nherdr-core: not found\nZellij: not found\n\
config dir: {} (waycar)\nstate dir: {}\nhooks:\n  claude: installed\n  codex: installed (review in /hooks)\n",
                scratch.ctx.plugin_root.display(),
                scratch.herdr_path(),
                config.display(),
                state.display()
            )
        );
    }

    #[test]
    fn an_old_tmux_is_not_a_backend_and_one_broken_piece_does_not_hide_the_rest() {
        let scratch = Scratch::new("humanold");
        scratch.tmux("2.7");
        let hooks = |_: &Ctx| Err(CliError::failure("boom"));
        let (result, text) = run_text(&scratch, false, &hooks);
        result.unwrap();
        assert!(text.contains("\nbackends: none\n"), "{text}");
        assert!(text.contains("\nherdr: not found\n"), "{text}");
        assert!(
            text.contains("\ntmux: 2.7 (too old: 3.2 or later required)\n"),
            "{text}"
        );
        assert!(text.contains("\nconfig dir: "), "{text}");
        assert!(text.ends_with("\nhooks: unknown (boom)\n"), "{text}");
    }

    #[test]
    fn no_tmux_reads_not_found_and_a_config_error_is_named_not_fatal() {
        let scratch = Scratch::new("humanbroken");
        std::fs::write(scratch.ctx.home.join(".config"), "").unwrap();
        let (result, text) = run_text(&scratch, false, &sample_hooks);
        result.unwrap();
        assert!(text.contains("\ntmux: not found\n"), "{text}");
        assert!(
            text.contains("\nconfig dir: unknown (cannot create "),
            "{text}"
        );
        assert!(text.contains("\nhooks:\n  claude: installed\n"), "{text}");
    }
}
