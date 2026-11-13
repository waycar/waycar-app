//! The real Agent Summaries and Chat Mode behind [`crate::notify_core`]'s
//! seams: `generateAgentSummary` (agent-summary.js) and the Chat Marker and
//! transcript reads of notify-hook.js (chat-marker.js, chat-transcript.js,
//! launch-rivals.js), on the production environment.

use std::path::Path;
use std::time::Duration;

use crate::chat::launch_rivals::launch_rivals;
use crate::chat::marker::{
    AgentSession, AppliesQuery, GcOptions, Marker, gc_markers, herdr_sessions_dir, list_markers,
    marker_applies, marker_gc_due, read_marker,
};
use crate::chat::transcript::{ReadChatArgs, RivalQuery, last_reply, read_chat};
use crate::env::Env;
use crate::exec::run_program;
use crate::jsx;
use crate::notify_core::{
    AgentSummaries, ChatMode, ChatRead, ChatTurn, MarkerGc, MarkerGcOutcome, MarkerProbe,
    ReplyRequest, Summary, SummaryRequest,
};
use crate::paths::home_dir;
use crate::summary::agent::{GenerateOptions, HttpFetch, generate_agent_summary};

/// [`AgentSummaries`] through `summary::agent::generate_agent_summary`.
pub struct SystemSummaries;

impl AgentSummaries for SystemSummaries {
    fn generate(&self, request: &SummaryRequest<'_>) -> Summary {
        let generated = generate_agent_summary(&GenerateOptions {
            bin_path: request.herdr_bin,
            pane_id: request.pane_id,
            status: request.status,
            timeout: Duration::from_millis(request.timeout_ms),
            command: request.command,
            work_dir: &request.work_dir.to_string_lossy(),
            cache_dir: &request.cache_dir.to_string_lossy(),
            path_fallback: None,
            env: request.env,
            fetch: &HttpFetch,
        });
        Summary {
            summary: generated.summary,
            hash: generated.hash,
        }
    }
}

/// [`ChatMode`] through the `chat` readers, on the process's environment and
/// home directory (what the JS reads from `process.env` and `os.homedir()`).
pub struct SystemChat;

fn text(path: &Path) -> std::borrow::Cow<'_, str> {
    path.to_string_lossy()
}

impl ChatMode for SystemChat {
    fn read_marker(&self, config_dir: &Path, pane_id: &str) -> Option<Marker> {
        read_marker(&text(config_dir), pane_id)
    }

    fn marker_applies(&self, marker: &Marker, probe: &MarkerProbe<'_>) -> bool {
        marker_applies(
            Some(marker),
            &AppliesQuery {
                kind: probe.kind,
                terminal_id: probe.terminal_id,
                agent_session: probe.agent_session.map(|session| AgentSession {
                    kind: Some(&session.kind),
                    value: Some(&session.value),
                }),
            },
        )
    }

    fn read_chat(&self, request: &ReplyRequest<'_>) -> Result<ChatTurn, String> {
        let env = Env::from_process();
        let home = home_dir(&env).ok_or("cannot find the home directory")?;
        let home = text(&home);
        let config_dir = text(request.config_dir);
        let rivals =
            |query: &RivalQuery| launch_rivals(&config_dir, query, &env, &home, &run_program);
        let chat = read_chat(&ReadChatArgs {
            kind: request.kind.unwrap_or(""),
            session_kind: request.session.map(|session| session.kind.as_str()),
            session_value: request.session.map(|session| session.value.as_str()),
            cwd: request.cwd,
            launched_at: request.launched_at,
            launch_rivals: Some(&rivals),
            status: Some("done"),
            after: None,
            max_messages: None,
            env: &env,
            home: &home,
        });
        let read = match jsx::field(&chat.header, "status").as_str() {
            Some("ok") => ChatRead::Ok,
            Some("error") => ChatRead::Error(
                jsx::field(&chat.header, "error")
                    .as_str()
                    .unwrap_or("undefined")
                    .to_owned(),
            ),
            _ => ChatRead::Other,
        };
        Ok(ChatTurn {
            read,
            turn_open: jsx::truthy(jsx::field(&chat.header, "turn_open")),
            last_reply: last_reply(&chat),
        })
    }

    fn gc_due(&self, state_dir: &Path, now_ms: u64) -> bool {
        marker_gc_due(&text(state_dir), now_ms as f64)
    }

    fn has_markers(&self, config_dir: &Path) -> bool {
        !list_markers(&text(config_dir)).is_empty()
    }

    fn collect_markers(&self, request: &MarkerGc<'_>) -> Result<MarkerGcOutcome, String> {
        let env = Env::from_process();
        let home = home_dir(&env).ok_or("cannot find the home directory")?;
        let mut skipped = false;
        let zellij =
            crate::notification_config::read_notification_config(&text(request.config_dir))
                .ok()
                .filter(|c| c.zellij_enabled)
                .and_then(|_| crate::zellij::live_ids(&env, &crate::zellij::run_system));
        gc_markers(GcOptions {
            config_dir: &text(request.config_dir),
            state_dir: &text(request.state_dir),
            live_pane_ids: request.live_pane_ids.as_deref(),
            live_tmux_pane_ids: request.live_tmux_pane_ids.as_deref(),
            live_core_pane_ids: request.live_core_pane_ids.as_deref(),
            live_zellij_pane_ids: zellij.as_deref(),
            now: request.now_ms as f64,
            sessions_dir: &herdr_sessions_dir(&env, &text(&home)),
            on_skip: Some(&mut || skipped = true),
        })
        .map_err(|error| error.to_string())?;
        Ok(MarkerGcOutcome {
            skipped_for_named_sessions: skipped,
        })
    }
}
