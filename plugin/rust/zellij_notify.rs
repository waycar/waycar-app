//! Zellij pushes use the shared delivery, dedupe and claim flow. A failed
//! list is unknown, never permission to trust an old hook document.
use std::path::Path;

use serde_json::Value;

use crate::env::Env;
use crate::error::{CliError, Result};
use crate::notification_config::read_notification_config;
use crate::notify_core::{
    Backend, Current, Deps, Event, Flow, Labels, MarkerGc, Summary, clear_last_notified,
    collect_markers_logged, run_notification,
};
use crate::paths::resolve_host_config;
use crate::tmux::Runner;
use crate::zellij::{self, PaneId, ZellijCommand};

pub struct ZellijBackend<'a> {
    pub command: &'a ZellijCommand,
    pub id: &'a PaneId,
    pub run: Runner<'a>,
}

impl Backend for ZellijBackend<'_> {
    type Detail = Value;
    fn recheck(&self) -> Result<Option<Current<Value>>> {
        let rows = zellij::panes(self.command, &self.id.session, self.run)?;
        let Some(pane) = rows
            .into_iter()
            .find(|p| p["id"].as_u64() == Some(u64::from(self.id.pane)))
        else {
            return Ok(None);
        };
        let doc = zellij::read_document(&self.command.env, &self.id.id());
        Ok(Some(Current {
            status: zellij::status(&pane, doc.as_ref())
                .unwrap_or("unknown")
                .into(),
            agent_kind: zellij::kind(&pane, doc.as_ref()).map(str::to_string),
            detail: pane,
        }))
    }
    fn summarize(&self, _budget_ms: u64) -> Summary {
        Summary::default()
    }
    fn describe(&self, current: &Current<Value>) -> Labels {
        let pane = &current.detail;
        let clean = |s: &str| crate::display_text::for_display_str(s).map(|s| s.into_owned());
        Labels {
            project: clean(&self.id.session),
            title: pane["title"]
                .as_str()
                .filter(|s| !s.is_empty())
                .or_else(|| pane["tab_name"].as_str())
                .and_then(clean),
        }
    }
    fn attention(&self) -> Option<u64> {
        Some(
            zellij::inventory(self.command, self.run)
                .ok()?
                .iter()
                .filter(|p| matches!(p["agent_status"].as_str(), Some("blocked" | "done")))
                .count() as u64,
        )
    }
}

pub fn run_notify(
    pane_id: &str,
    status: &str,
    env: &Env,
    home: &Path,
    deps: &Deps<'_>,
    stderr: &mut String,
) -> Result<()> {
    let id = PaneId::parse(pane_id).ok_or_else(|| CliError::failure("invalid Zellij pane id"))?;
    let host = resolve_host_config(env, home, &|herdr, args| {
        (deps.run)(&herdr.bin, args, &herdr.env)
    })?;
    if status == "release" {
        clear_last_notified(&host.state_dir, pane_id);
        return Ok(());
    }
    let config =
        read_notification_config(&host.config_dir.to_string_lossy()).map_err(CliError::failure)?;
    if !config.zellij_enabled {
        return Ok(());
    }
    let z = zellij::command(env, deps.run)
        .ok_or_else(|| CliError::failure("Zellij 0.46 or later not found"))?;
    let flow = Flow {
        config_dir: &host.config_dir,
        state_dir: &host.state_dir,
        config: &config,
        fetch: deps.fetch,
        clock: deps.clock,
    };
    let gc_dir = host.state_dir.join("zellij-chat-marker-gc");
    let now_ms = deps.clock.now_ms();
    if deps.chat.gc_due(&gc_dir, now_ms) {
        zellij::collect_documents(&z, deps.run);
        collect_markers_logged(
            deps.chat,
            &MarkerGc {
                config_dir: &host.config_dir,
                state_dir: &gc_dir,
                live_pane_ids: None,
                live_tmux_pane_ids: None,
                live_core_pane_ids: None,
                now_ms,
            },
            stderr,
        );
    }
    let backend = ZellijBackend {
        command: &z,
        id: &id,
        run: deps.run,
    };
    let event = Event {
        pane_id: pane_id.into(),
        status: status.into(),
        agent_kind: None,
    };
    run_notification(&flow, &event, now_ms, &backend, stderr)
}
