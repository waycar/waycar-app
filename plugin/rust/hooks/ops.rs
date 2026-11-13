//! What install, uninstall and status do for each agent kind: one function
//! per mechanism (agent-hooks.js `settingsOp`, `codexOp`, `agyOp`,
//! `hermesOp`, `fileSetOp`). An error is the message the JS throws.

use std::path::{Path, PathBuf};

use crate::js_json::{Json, Obj, deep_equal, parse, quote};
use crate::jsx;
use crate::native::Ctx;
use crate::paths::posix_join;

use super::AgentRow;
use super::codex::{
    codex_hooks_trusted, enable_codex_hooks_feature, is_codex_feature_off, is_codex_feature_on,
};
use super::entries::*;
use super::files::{
    read_json_object, read_required, read_text, remove_file, write_json, write_preserving_mode,
};
use super::groups::*;
use super::hermes::*;
use super::locations::*;
use crate::js_date::iso_now;

pub type Op = Result<AgentRow, String>;

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Install,
    Uninstall,
    Status,
}

fn new_row(agent: &str, config_path: &Path) -> AgentRow {
    AgentRow {
        agent: agent.to_string(),
        config_path: Some(config_path.to_string_lossy().into_owned()),
        ..AgentRow::default()
    }
}

fn shown(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

fn under(base: &Path, parts: &[&str]) -> PathBuf {
    let mut all = vec![base];
    all.extend(parts.iter().map(Path::new));
    posix_join(&all)
}

pub fn run_op(agent: &str, ctx: &Ctx, mode: Mode) -> Op {
    match agent {
        "codex" => codex_op(ctx, mode),
        "agy" => agy_op(ctx, mode),
        "hermes" => hermes_op(ctx, mode),
        _ => match settings_spec(agent) {
            Some(spec) => settings_op(agent, &spec, ctx, mode),
            None => file_set_op(agent, ctx, mode),
        },
    }
}

fn empty_hooks() -> Json {
    Json::Obj(Obj::new())
}

/// Replace the `hooks` value in place, or add it; `base` keys the file lacks go first.
fn with_hooks(file: &Obj, hooks: Obj, base: &[(&str, u32)]) -> Obj {
    let mut out = Obj::new();
    for (key, value) in base {
        if !file.contains_key(key) {
            out.set(*key, number(*value));
        }
    }
    for (key, value) in file.iter() {
        out.set(key, value.clone());
    }
    out.set("hooks", Json::Obj(hooks));
    out
}

fn settings_op(agent: &str, spec: &SettingsSpec, ctx: &Ctx, mode: Mode) -> Op {
    let config_path = settings_file(agent, ctx);
    let (exists, settings) = read_json_object(&config_path)?;
    let mut row = new_row(agent, &config_path);
    let hooks = settings.get("hooks");
    let desired = || settings_groups(agent, &ctx.plugin_root).unwrap_or_default();
    if mode == Mode::Status {
        row.installed = has_exactly(hooks, &desired(), spec.flat);
        row.outdated = !row.installed && has_any_ours(hooks, spec.flat);
        return Ok(row);
    }
    if mode == Mode::Uninstall && !has_any_ours(hooks, spec.flat) {
        return Ok(row);
    }
    let wanted = if mode == Mode::Uninstall {
        Groups::new()
    } else {
        desired()
    };
    let next = with_hooks(
        &settings,
        merge_hook_groups(hooks, &wanted, spec.flat),
        spec.base,
    );
    let mut emptied = Obj::new();
    for (key, value) in spec.base {
        emptied.set(*key, number(*value));
    }
    emptied.set("hooks", empty_hooks());
    if mode == Mode::Uninstall && spec.owned && next.deep_equals(&emptied) {
        remove_file(&config_path)?;
        row.changed.push(shown(&config_path));
    } else if !exists || !next.deep_equals(&settings) {
        write_json(&config_path, &Json::Obj(next), 0o644)?;
        row.changed.push(shown(&config_path));
    }
    row.installed = mode == Mode::Install;
    Ok(row)
}

fn codex_op(ctx: &Ctx, mode: Mode) -> Op {
    let dir = codex_dir(ctx);
    let config_path = under(&dir, &["hooks.json"]);
    let toml_path = under(&dir, &["config.toml"]);
    let (exists, file) = read_json_object(&config_path)?;
    let mut row = new_row("codex", &config_path);
    let mut toml_text = read_text(&toml_path)?;
    let path_text = shown(&config_path);
    let hooks = file.get("hooks");

    match mode {
        Mode::Status => {
            row.installed = has_exactly(hooks, &codex_groups(&ctx.plugin_root), false)
                && is_codex_feature_on(toml_text.as_deref());
            row.outdated = !row.installed && has_any_ours(hooks, false);
            row.needs_codex_review = has_any_ours(hooks, false)
                && !codex_hooks_trusted(hooks, &path_text, toml_text.as_deref());
            row.hooks_disabled = is_codex_feature_off(toml_text.as_deref());
            return Ok(row);
        }
        Mode::Uninstall => {
            if has_any_ours(hooks, false) {
                let mut next = file.clone();
                next.set(
                    "hooks",
                    Json::Obj(merge_hook_groups(hooks, &Groups::new(), false)),
                );
                write_json(&config_path, &Json::Obj(next), 0o644)?;
                row.changed.push(path_text);
            }
            return Ok(row);
        }
        Mode::Install => {}
    }

    // Check the feature flag edit before touching anything.
    let feature = enable_codex_hooks_feature(toml_text.as_deref())?;
    let merged = Json::Obj(merge_hook_groups(
        hooks,
        &codex_groups(&ctx.plugin_root),
        false,
    ));
    let mut next = file.clone();
    next.set("hooks", merged.clone());
    if !exists || !next.deep_equals(&file) {
        write_json(&config_path, &Json::Obj(next), 0o644)?;
        row.changed.push(path_text.clone());
    }
    if feature.changed {
        write_preserving_mode(&toml_path, &feature.text, 0o600)?;
        row.changed.push(shown(&toml_path));
        toml_text = Some(feature.text);
    }
    row.hooks_disabled = feature.disabled;
    row.installed = !row.hooks_disabled;
    row.needs_codex_review = !codex_hooks_trusted(Some(&merged), &path_text, toml_text.as_deref());
    Ok(row)
}

fn is_our_value(value: Option<&Json>) -> bool {
    value.and_then(Json::as_str).is_some_and(is_our_command)
}

/// Antigravity: our `"waycar"` group in ~/.gemini/config/hooks.json; herdr's
/// and others stay.
fn agy_op(ctx: &Ctx, mode: Mode) -> Op {
    let config_path = under(&ctx.home, &[".gemini", "config", "hooks.json"]);
    let (exists, file) = read_json_object(&config_path)?;
    let mut row = new_row("agy", &config_path);
    let present = file.get("waycar");
    let desired = agy_group(&ctx.plugin_root);
    if mode == Mode::Status {
        row.installed = present.is_some_and(|group| deep_equal(group, &desired));
        row.outdated = present.is_some() && !row.installed;
        return Ok(row);
    }
    if let Some(group) = present {
        let mut commands = Vec::new();
        commands_in(group, &mut commands);
        if commands.iter().any(|command| !is_our_command(command)) {
            return Err(format!(
                "{} has a \"waycar\" group that was not installed by Waycar; left unchanged",
                config_path.display()
            ));
        }
    }
    if mode == Mode::Uninstall {
        if present.is_some() {
            let mut next = file.clone();
            next.remove("waycar");
            write_json(&config_path, &Json::Obj(next), 0o644)?;
            row.changed.push(shown(&config_path));
        }
        return Ok(row);
    }
    let mut next = file.clone();
    next.set("waycar", desired);
    if !exists || !next.deep_equals(&file) {
        write_json(&config_path, &Json::Obj(next), 0o644)?;
        row.changed.push(shown(&config_path));
    }
    row.installed = true;
    Ok(row)
}

fn approvals_of(allowlist: &Obj) -> &[Json] {
    match allowlist.get("approvals") {
        Some(Json::Arr(items)) => items,
        _ => &[],
    }
}

fn approves(entry: &Json, event: &str, command: &str) -> bool {
    entry.get("event").and_then(Json::as_str) == Some(event)
        && entry.get("command").and_then(Json::as_str) == Some(command)
}

fn read_allowlist(path: &Path) -> Result<Obj, String> {
    let Some(text) = read_text(path)?.filter(|text| !jsx::trim(text).is_empty()) else {
        return Ok(Obj::new());
    };
    match parse(&text) {
        Ok(Json::Obj(allowlist)) => Ok(allowlist),
        Ok(_) => Err(format!(
            "{} does not hold a JSON object; left unchanged",
            path.display()
        )),
        Err(message) => Err(format!(
            "{} is not valid JSON ({message}); left unchanged",
            path.display()
        )),
    }
}

/// Hermes: our block in config.yaml and its (event, command) pairs in
/// shell-hooks-allowlist.json, Hermes's first-use consent record. A
/// config.yaml with a top-level `hooks:` of its own is left alone: merging
/// into another YAML mapping needs a YAML editor this module does not have.
fn hermes_op(ctx: &Ctx, mode: Mode) -> Op {
    let dir = hermes_dir(ctx);
    let config_path = under(&dir, &["config.yaml"]);
    let allowlist_path = under(&dir, &["shell-hooks-allowlist.json"]);
    let text = read_text(&config_path)?;
    let (block, rest) = split_hermes_config(text.as_deref());
    let allowlist = read_allowlist(&allowlist_path)?;
    let approvals = approvals_of(&allowlist);
    let wanted: Vec<(&str, String)> = HERMES_ENTRIES
        .iter()
        .map(|(event, _, status)| {
            (
                *event,
                hook_command(&ctx.plugin_root, "hermes", status, event),
            )
        })
        .collect();
    let approved = |event: &str, command: &str| {
        approvals
            .iter()
            .any(|entry| approves(entry, event, command))
    };
    let mut row = new_row("hermes", &config_path);
    let desired_block = hermes_block(&ctx.plugin_root);

    if mode == Mode::Status {
        row.installed = block.as_deref() == Some(desired_block.as_str())
            && wanted
                .iter()
                .all(|(event, command)| approved(event, command));
        row.outdated = block.is_some() && !row.installed;
        return Ok(row);
    }
    let theirs: Vec<Json> = approvals
        .iter()
        .filter(|entry| !is_our_value(entry.get("command")))
        .cloned()
        .collect();
    if mode == Mode::Uninstall {
        if block.is_some() {
            write_preserving_mode(&config_path, &rest, 0o644)?;
            row.changed.push(shown(&config_path));
        }
        if theirs.len() != approvals.len() {
            let mut next = allowlist.clone();
            next.set("approvals", Json::Arr(theirs));
            write_json(&allowlist_path, &Json::Obj(next), 0o600)?;
            row.changed.push(shown(&allowlist_path));
        }
        return Ok(row);
    }
    if has_top_level_hooks(&rest) {
        return Err(format!(
            "{} has its own top-level hooks: section; add Waycar's hooks to it by hand or remove it",
            config_path.display()
        ));
    }
    if block.as_deref() != Some(desired_block.as_str()) {
        let base = if rest.is_empty() || rest.ends_with('\n') {
            rest.clone()
        } else {
            format!("{rest}\n")
        };
        let gap = if base.is_empty() { "" } else { "\n" };
        write_preserving_mode(&config_path, &format!("{base}{gap}{desired_block}"), 0o644)?;
        row.changed.push(shown(&config_path));
    }
    // Our entries from any other plugin root go; the current ones keep their approval time.
    let mut next_approvals: Vec<Json> = approvals
        .iter()
        .filter(|entry| {
            !is_our_value(entry.get("command"))
                || wanted
                    .iter()
                    .any(|(event, command)| approves(entry, event, command))
        })
        .cloned()
        .collect();
    let kept = next_approvals.len();
    let mut added = 0;
    for (event, command) in wanted
        .iter()
        .filter(|(event, command)| !approved(event, command))
    {
        let mtime = script_mtime(command).map_or(Json::Null, Json::Str);
        next_approvals.push(object([
            ("event", Json::str(*event)),
            ("command", Json::str(command.as_str())),
            ("approved_at", Json::Str(iso_now())),
            ("script_mtime_at_approval", mtime),
        ]));
        added += 1;
    }
    if added > 0 || kept != approvals.len() {
        let mut next = allowlist.clone();
        next.set("approvals", Json::Arr(next_approvals));
        write_json(&allowlist_path, &Json::Obj(next), 0o600)?;
        row.changed.push(shown(&allowlist_path));
    }
    row.installed = true;
    Ok(row)
}

// MARK: - Files we own outright

/// How the content of an agent's own file is made.
enum Content {
    /// Copied from `hooks/<template>/<file>` with the placeholders filled in.
    Template(&'static str),
    /// A cline hook file: bash runs it, and it execs our command.
    Cline,
    /// Kiro's V3 standalone hook file.
    Kiro,
}

fn file_set(agent: &str) -> Option<(Vec<&'static str>, Content)> {
    const STATE_TS: &[&str] = &["waycar-agent-state.ts"];
    const OPENCODE: &[&str] = &["waycar-agent-state.js", "waycar-chat-prompt.js"];
    Some(match agent {
        "omp" => (STATE_TS.to_vec(), Content::Template("omp")),
        "pi" => (STATE_TS.to_vec(), Content::Template("pi")),
        // opencode and kilo get the Agent Status extension and the Chat
        // Prompt injection extension (ADR 0025), from the same templates.
        "opencode" | "kilo" => (OPENCODE.to_vec(), Content::Template("opencode")),
        "cline" => (
            CLINE_ENTRIES.iter().map(|(event, _, _)| *event).collect(),
            Content::Cline,
        ),
        "kiro" => (vec!["waycar.json"], Content::Kiro),
        _ => return None,
    })
}

fn cline_hook_file(plugin_root: &Path, file: &str) -> String {
    let (event, _, status) = CLINE_ENTRIES
        .iter()
        .find(|(name, _, _)| *name == file)
        .copied()
        .unwrap_or((file, None, SESSION));
    [
        format!("# {EXTENSION_MARKER}"),
        "# managed by waycar: `waycar hooks install` overwrites this file and".into(),
        "# `waycar hooks uninstall` removes it. Cline runs it with bash; exec keeps".into(),
        "# the pane's cline process as the hook's parent.".into(),
        format!("exec {}", hook_command(plugin_root, "cline", status, event)),
        String::new(),
    ]
    .join("\n")
}

fn kiro_hook_file(plugin_root: &Path) -> String {
    let hooks = KIRO_ENTRIES
        .iter()
        .map(|(event, _, status)| {
            object([
                ("name", Json::Str(format!("waycar-{event}"))),
                ("trigger", Json::str(*event)),
                (
                    "action",
                    object([
                        ("type", Json::str("command")),
                        (
                            "command",
                            Json::Str(hook_command(plugin_root, "kiro", status, event)),
                        ),
                    ]),
                ),
                ("timeout", number(HOOK_TIMEOUT_SEC)),
            ])
        })
        .collect();
    let file = object([("version", Json::str("v1")), ("hooks", Json::Arr(hooks))]);
    format!("{}\n", file.to_pretty())
}

/// Whether a JSON text holds commands and all of them are ours.
pub fn holds_only_our_commands(text: &str) -> bool {
    let Ok(value) = parse(text) else {
        return false;
    };
    let mut commands = Vec::new();
    commands_in(&value, &mut commands);
    !commands.is_empty() && commands.iter().all(|command| is_our_command(command))
}

/// The installed content of one of an agent's own files (its first by default).
pub fn extension_content(
    agent: &str,
    plugin_root: &Path,
    file: Option<&str>,
) -> Result<String, String> {
    let Some((files, content)) = file_set(agent) else {
        return Err(format!("{agent} has no files of its own"));
    };
    let name = file.unwrap_or(files[0]);
    match content {
        Content::Cline => Ok(cline_hook_file(plugin_root, name)),
        Content::Kiro => Ok(kiro_hook_file(plugin_root)),
        Content::Template(template) => {
            let source = under(plugin_root, &["hooks", template, name]);
            Ok(read_required(&source)?
                .replace(PLUGIN_ROOT_PLACEHOLDER, &root_json(plugin_root))
                .replace(AGENT_PLACEHOLDER, &quote(agent)))
        }
    }
}

fn file_set_op(agent: &str, ctx: &Ctx, mode: Mode) -> Op {
    let Some((files, kind)) = file_set(agent) else {
        return Err(format!("no hooks known for {agent}"));
    };
    let dir = file_set_dir(agent, ctx);
    let paths: Vec<PathBuf> = files.iter().map(|file| under(&dir, &[file])).collect();
    let mut row = new_row(agent, &paths[0]);
    let mut current: Vec<Option<String>> = Vec::new();
    let mut ours: Vec<bool> = Vec::new();
    for path in &paths {
        let text = read_text(path)?;
        ours.push(text.as_deref().is_some_and(|text| match kind {
            Content::Kiro => holds_only_our_commands(text),
            _ => text.contains(EXTENSION_MARKER),
        }));
        current.push(text);
    }
    match mode {
        Mode::Status => {
            row.installed = ours.iter().all(|ours| *ours) && {
                let mut same = true;
                for (file, text) in files.iter().zip(&current) {
                    let wanted = extension_content(agent, &ctx.plugin_root, Some(file))?;
                    if text.as_deref() != Some(wanted.as_str()) {
                        same = false;
                        break;
                    }
                }
                same
            };
            row.outdated = ours.iter().any(|ours| *ours) && !row.installed;
            Ok(row)
        }
        Mode::Uninstall => {
            for (path, ours) in paths.iter().zip(&ours) {
                if *ours {
                    remove_file(path)?;
                    row.changed.push(shown(path));
                }
            }
            Ok(row)
        }
        Mode::Install => {
            // The foreign-file check passes for every file before anything is written.
            for ((path, text), ours) in paths.iter().zip(&current).zip(&ours) {
                if text.is_some() && !ours {
                    return Err(format!(
                        "{} exists and was not installed by Waycar; left unchanged",
                        path.display()
                    ));
                }
            }
            for ((path, file), text) in paths.iter().zip(&files).zip(&current) {
                let content = extension_content(agent, &ctx.plugin_root, Some(file))?;
                if text.as_deref() != Some(content.as_str()) {
                    write_preserving_mode(path, &content, 0o644)?;
                    row.changed.push(shown(path));
                }
            }
            row.installed = true;
            Ok(row)
        }
    }
}
