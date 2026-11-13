//! `waycar hooks install|uninstall|status|migrate`: the agent hooks that
//! drive Agent Status on Waycar's tmux backend (design §4.5, §4.6).
//!
//! Every kind's hooks run one of two commands: `bin/waycar-hook <agent>
//! <status>` for a status the event alone decides, or `bin/waycar
//! hook-session <agent> [<event>]` for events whose payload matters (sessions,
//! transcript paths, notification types, stray session ids). Ours are
//! recognized by the `/bin/waycar-hook` path or the `/bin/waycar' hook-session
//! ` command, and plugin 1.x's `/src/hook-session.js` path (Node-era), so
//! uninstall removes only ours. The mechanisms:
//!
//! * Claude-format JSON hooks (`{"hooks": {Event: [group]}}`): claude, qwen,
//!   gemini, devin, grok and muse as nested `{matcher?, hooks: [handler]}`
//!   groups, copilot and cursor as flat handler lists under `{"version": 1,
//!   "hooks"}`. The merge keeps every other hook (herdr's, Moshi's, the
//!   user's, and agent-deck's inside our own groups), the key order and the
//!   other entries' positions, and is idempotent; status compares only our
//!   handlers.
//! * Codex: the same merge into hooks.json, plus `[features] hooks = true` in
//!   config.toml. Codex skips hooks until the user trusts them in `/hooks`.
//!   This module never writes that trust; it recomputes Codex's trust hash
//!   for each of our entries and reports `needs_codex_review` when config.toml
//!   holds no matching `trusted_hash`. Codex's `notify` setting is never
//!   touched.
//! * Antigravity (`agy`): a `"waycar"` group in ~/.gemini/config/hooks.json,
//!   beside herdr's `"herdr"` group.
//! * Hermes: a marked `hooks:` block at the end of ~/.hermes/config.yaml plus
//!   the matching entries in ~/.hermes/shell-hooks-allowlist.json (Hermes
//!   otherwise stops every launch on a consent prompt for each hook).
//! * Files we own outright, recognized by their `installed by waycar` marker
//!   (or, for JSON, by holding only our commands): the omp/pi/opencode/kilo
//!   extensions copied from `<plugin root>/hooks/<template>/`, cline's
//!   per-event hook files and kiro's `~/.kiro/hooks/waycar.json`.

mod codex;
mod entries;
mod files;
mod groups;
mod hermes;
mod locations;
mod ops;
mod toml_doc;

use crate::error::{CliError, Result};
use crate::native::Ctx;

pub use codex::*;
pub use entries::*;
pub use groups::*;
pub use hermes::hermes_block;
pub use locations::agent_detected;
pub use ops::{extension_content, holds_only_our_commands};
pub use toml_doc::{FeatureFlag, TomlDoc};

use ops::{Mode, run_op};

/// One agent's row of an install, uninstall or status result.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct AgentRow {
    pub agent: String,
    pub detected: bool,
    pub installed: bool,
    pub config_path: Option<String>,
    pub changed: Vec<String>,
    pub needs_codex_review: bool,
    pub hooks_disabled: bool,
    pub outdated: bool,
    pub error: Option<String>,
}

/// `{agents, lines}`: the rows, and what the CLI prints.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct HooksResult {
    pub agents: Vec<AgentRow>,
    pub lines: Vec<String>,
}

pub const CODEX_REVIEW_LINE: &str = "codex: open Codex and run /hooks to review and trust the Waycar hooks; Codex skips them until then";

pub const CODEX_DISABLED_LINE: &str = "codex: hooks stay off because ~/.codex/config.toml sets `[features] hooks = false`; change it to `hooks = true` to turn them on";

fn check(ctx: &Ctx) -> Result<()> {
    if ctx.home.as_os_str().is_empty() {
        return Err(CliError::failure("home is required"));
    }
    if ctx.plugin_root.as_os_str().is_empty() {
        return Err(CliError::failure("pluginRoot is required"));
    }
    Ok(())
}

/// An operation's row, or the error row when it failed.
fn safe_op(agent: &str, ctx: &Ctx, mode: Mode) -> AgentRow {
    run_op(agent, ctx, mode).unwrap_or_else(|error| AgentRow {
        agent: agent.to_string(),
        error: Some(error),
        ..AgentRow::default()
    })
}

fn note_codex(lines: &mut Vec<String>, row: &AgentRow) {
    if row.hooks_disabled {
        lines.push(CODEX_DISABLED_LINE.into());
    } else if row.needs_codex_review {
        lines.push(CODEX_REVIEW_LINE.into());
    }
}

/// Install or update the hooks for the agents found on the Host.
pub fn install(ctx: &Ctx) -> Result<HooksResult> {
    install_agents(ctx, None)
}

/// Install or update the hooks. Without `agents`, only agents whose config
/// directory or binary exists are handled; with it, exactly those agents.
pub fn install_agents(ctx: &Ctx, agents: Option<&[&str]>) -> Result<HooksResult> {
    check(ctx)?;
    let mut result = HooksResult::default();
    for agent in HOOK_AGENTS
        .into_iter()
        .filter(|agent| agents.is_none_or(|wanted| wanted.contains(agent)))
    {
        let detected = agent_detected(agent, ctx);
        if agents.is_none() && !detected {
            result.agents.push(AgentRow {
                agent: agent.to_string(),
                ..AgentRow::default()
            });
            result.lines.push(format!("{agent}: not found, skipped"));
            continue;
        }
        let row = AgentRow {
            detected,
            ..safe_op(agent, ctx, Mode::Install)
        };
        if let Some(error) = &row.error {
            result.lines.push(format!("{agent}: error: {error}"));
        } else {
            let path = row.config_path.as_deref().unwrap_or_default();
            if row.changed.is_empty() {
                result
                    .lines
                    .push(format!("{agent}: hooks up to date ({path})"));
            }
            for changed in &row.changed {
                result.lines.push(format!("{agent}: updated {changed}"));
            }
            note_codex(&mut result.lines, &row);
        }
        result.agents.push(row);
    }
    Ok(result)
}

/// The line `hooks migrate` prints after it rewrote Node-era entries.
pub const MIGRATED_LINE: &str = "rewrote the Node-era agent hooks to call waycar hook-session";

/// Rewrite the Node-era hook entries (`bin/node.sh src/hook-session.js`,
/// plugin 1.x) of every agent that has any, and nothing else: an agent whose
/// config holds none is not touched, whatever else is out of date. Each agent
/// that had some gets the same rewrite as `install`. The row list holds only
/// the agents it rewrote; `lines` is empty when there was nothing to do.
pub fn migrate_legacy(ctx: &Ctx) -> Result<HooksResult> {
    check(ctx)?;
    let mut result = HooksResult::default();
    for agent in HOOK_AGENTS {
        let status = safe_op(agent, ctx, Mode::Status);
        let has_legacy = status
            .config_path
            .as_deref()
            .and_then(|path| std::fs::read_to_string(path).ok())
            .is_some_and(|text| text.contains("/src/hook-session.js"));
        if !has_legacy {
            continue;
        }
        let row = AgentRow {
            detected: agent_detected(agent, ctx),
            ..safe_op(agent, ctx, Mode::Install)
        };
        if let Some(error) = &row.error {
            result.lines.push(format!("{agent}: error: {error}"));
        } else {
            for changed in &row.changed {
                result.lines.push(format!("{agent}: updated {changed}"));
            }
            note_codex(&mut result.lines, &row);
        }
        result.agents.push(row);
    }
    if result.agents.iter().any(|row| row.error.is_none()) {
        result.lines.push(MIGRATED_LINE.into());
    }
    Ok(result)
}

/// Remove our hooks from every agent's config. Same result shape as install.
pub fn uninstall(ctx: &Ctx) -> Result<HooksResult> {
    check(ctx)?;
    let mut result = HooksResult::default();
    for agent in HOOK_AGENTS {
        let row = safe_op(agent, ctx, Mode::Uninstall);
        if let Some(error) = &row.error {
            result.lines.push(format!("{agent}: error: {error}"));
        } else if row.changed.is_empty() {
            result.lines.push(format!("{agent}: no Waycar hooks"));
        } else {
            for changed in &row.changed {
                result
                    .lines
                    .push(format!("{agent}: removed Waycar hooks from {changed}"));
            }
        }
        result.agents.push(row);
    }
    Ok(result)
}

/// Report, without writing, whether each agent has the current hooks.
/// `installed` means exactly this plugin root's entries are present (for
/// Codex also that `[features] hooks` is not off); `outdated` that ours are
/// present but differ; `needs_codex_review` that Codex has not trusted them.
pub fn status(ctx: &Ctx) -> Result<HooksResult> {
    check(ctx)?;
    let mut result = HooksResult::default();
    for agent in HOOK_AGENTS {
        let detected = agent_detected(agent, ctx);
        let row = AgentRow {
            detected,
            ..safe_op(agent, ctx, Mode::Status)
        };
        if let Some(error) = &row.error {
            result.lines.push(format!("{agent}: error: {error}"));
            result.agents.push(row);
            continue;
        }
        let state = if row.installed {
            "installed"
        } else if row.hooks_disabled {
            "off (`[features] hooks = false`)"
        } else if row.outdated {
            "out of date, run `waycar hooks install`"
        } else if detected {
            "not installed"
        } else {
            "not installed (agent not found)"
        };
        let path = row.config_path.as_deref().unwrap_or_default();
        result.lines.push(format!("{agent}: {state} ({path})"));
        note_codex(&mut result.lines, &row);
        result.agents.push(row);
    }
    Ok(result)
}

#[cfg(test)]
mod tests;
