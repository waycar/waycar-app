//! Hermes Agent reader (chat-readers/hermes.js; live-verified on v0.21.7,
//! docs/research/harnesses/hermes.md). Hermes writes no transcript file (its
//! sessions live in `~/.hermes/state.db`), so a chat is read by its session
//! id through `hermes sessions export` (see `chat::session_export`): one
//! object with `messages[]` of `{id, role: user|assistant|tool, content,
//! tool_calls (OpenAI shape), finish_reason, timestamp (epoch seconds),
//! display_kind, active, message_uid}`.
//!
//! An assistant message with `finish_reason` `stop` or `length` ends the
//! turn; `tool_calls` are tool activity. An interrupted turn is stored as an
//! assistant message with `display_kind: "failed_turn"` ("Your request was
//! not processed..."), which ends the turn quietly. `tool` messages and
//! inactive (`active: 0`) messages are not chat material. The export holds
//! no images: an attached image reaches the transcript only as text.
//!
//! There is no `findById`/`findByLaunch` in the JS reader: `read_chat` finds a
//! hermes session through `session_export::launch_candidates`. `find_by_id`
//! here answers None (the JS op would throw "not a function").
//!
//! # Differences from the JS
//!
//! `parse` takes the signal as a borrowed [`AbortSignal`] while the exporter
//! wants an `Arc`: a scoped thread forwards the borrowed signal to the
//! exporter's own while the export runs (polled every 5 ms).

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use serde_json::Value;

use crate::chat::readers::{Reader, ReaderContext};
use crate::chat::session_export::{ExportOptions, session_export};
use crate::chat::shared::{AbortSignal, ChatResult, ChatTurns, Prompt, ToolCall, tool_activity};
use crate::env::Env;
use crate::{jspath, jsx};

pub const READER: Reader = Reader {
    root,
    find_by_id: |_id, _root| Ok(None),
    find_by_launch: None,
    resolve_path: None,
    parse,
};

fn root(_env: &Env, home: &str) -> String {
    jspath::join(&[home, ".hermes"])
}

/// `sessionExport("hermes", session, ...)` with the reader's signal.
fn export(session: &str, ctx: &ReaderContext<'_>) -> ChatResult<Value> {
    let mut options = ExportOptions::new(ctx.env.clone(), ctx.home);
    let Some(outer) = ctx.signal else {
        return session_export("hermes", &Value::String(session.to_string()), &options);
    };
    let inner = AbortSignal::new();
    options.signal = Some(Arc::clone(&inner));
    let done = AtomicBool::new(false);
    std::thread::scope(|scope| {
        scope.spawn(|| {
            while !done.load(Ordering::SeqCst) {
                if outer.is_aborted() {
                    if let Err(error) = outer.check() {
                        inner.abort(error.message);
                    }
                    return;
                }
                std::thread::sleep(Duration::from_millis(5));
            }
        });
        let result = session_export("hermes", &Value::String(session.to_string()), &options);
        done.store(true, Ordering::SeqCst);
        result
    })
}

fn parse(session: &str, ctx: &ReaderContext<'_>, turns: &mut ChatTurns) -> ChatResult<()> {
    let data = export(session, ctx)?;
    let messages = jsx::field(&data, "messages")
        .as_array()
        .map_or(&[][..], Vec::as_slice);
    for (index, message) in messages.iter().enumerate() {
        if !jsx::is_object_like(message)
            || matches!(jsx::field(message, "active"), Value::Number(n) if jsx::json_f64(n) == 0.0)
        {
            continue;
        }
        let id = match jsx::field(message, "message_uid") {
            Value::String(uid) => uid.clone(),
            _ => {
                let own = jsx::field(message, "id");
                if own.is_null() {
                    format!("message:{index}")
                } else {
                    format!("message:{}", js_string(own))
                }
            }
        };
        let ts = match jsx::field(message, "timestamp") {
            Value::Number(n) if jsx::json_f64(n).is_finite() => Some(jsx::json_f64(n) * 1000.0),
            _ => None,
        };
        let content = jsx::field(message, "content").as_str().unwrap_or("");
        match jsx::field(message, "role").as_str() {
            Some("user") => {
                let clean = jsx::trim(content);
                if !clean.is_empty() {
                    turns.prompt(Prompt {
                        id: &id,
                        text: clean,
                        ts,
                        ..Prompt::default()
                    });
                }
                continue;
            }
            Some("assistant") => {}
            _ => continue,
        }
        if jsx::field(message, "display_kind").as_str() == Some("failed_turn") {
            turns.end(&id, ts, false, None, None);
            continue;
        }
        turns.text_str(&id, ts, content, None);
        let calls = jsx::field(message, "tool_calls")
            .as_array()
            .map_or(&[][..], Vec::as_slice);
        for call in calls {
            let function = jsx::field(call, "function");
            let input = parse_arguments(jsx::field(function, "arguments"));
            turns.tool(ToolCall {
                id: &id,
                ts,
                activity: tool_activity(jsx::field(function, "name"), &input),
                ..ToolCall::default()
            });
        }
        if matches!(
            jsx::field(message, "finish_reason").as_str(),
            Some("stop" | "length")
        ) {
            turns.end(&id, ts, false, None, None);
        }
    }
    Ok(())
}

/// `${value}` of a JSON value for the `message:<id>` fallback.
pub(crate) fn js_string(value: &Value) -> String {
    match value {
        Value::String(s) => s.clone(),
        Value::Number(n) => jsx::number_to_string(jsx::json_f64(n)),
        Value::Bool(b) => b.to_string(),
        Value::Array(items) => items
            .iter()
            .map(|item| {
                if item.is_null() {
                    String::new()
                } else {
                    js_string(item)
                }
            })
            .collect::<Vec<_>>()
            .join(","),
        Value::Object(_) => "[object Object]".to_string(),
        Value::Null => String::new(),
    }
}

fn parse_arguments(value: &Value) -> Value {
    match value {
        Value::String(text) => jsx::parse_json(text).unwrap_or(Value::Null),
        other => other.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::chat::readers::grok::testkit::{TempDir, run_vector, write_executable};

    #[test]
    fn hermes_export_tool_calls_are_activity_finish_reason_stop_ends_the_turn_tool_messages_are_not_chat()
     {
        run_vector(
            "hermes export: tool calls are activity, finish_reason stop ends the turn, tool messages are not chat",
        );
    }

    #[test]
    fn hermes_interrupted_turn_a_failed_turn_message_ends_it_quietly() {
        run_vector("hermes interrupted turn: a failed_turn message ends it quietly");
    }

    #[test]
    fn hermes_open_turn_tool_calls_with_no_final_reply_yet() {
        run_vector("hermes open turn: tool_calls with no final reply yet");
    }

    #[test]
    fn hermes_a_malformed_id_never_runs_the_harness() {
        let dir = TempDir::new("hermes");
        let bin = dir.join("bin");
        let log = dir.join("ran.log");
        write_executable(
            &format!("{bin}/hermes"),
            &format!("#!/bin/sh\necho ran >> '{log}'\nexit 1\n"),
        );
        let env = Env::from_pairs([("PATH", format!("{bin}:/usr/bin:/bin"))]);
        let home = dir.path();
        let ctx = ReaderContext {
            root: &home,
            env: &env,
            home: &home,
            cwd: None,
            signal: None,
        };
        let error = (READER.parse)("--format=html", &ctx, &mut ChatTurns::new()).unwrap_err();
        assert_eq!(error.message, "not a hermes session id: \"--format=html\"");
        assert!(!std::path::Path::new(&log).exists());
    }

    #[test]
    fn hermes_messages_are_read_from_the_export_with_timestamps_ids_and_inactive_skipped() {
        let dir = TempDir::new("hermes");
        let bin = dir.join("bin");
        let export = serde_json::json!({
            "messages": [
                {"id": 1, "role": "user", "content": " hi ", "timestamp": 1791823283.5, "active": 1},
                {"id": 2, "role": "user", "content": "gone", "active": 0},
                {"id": 3, "role": "assistant", "content": "yo", "message_uid": "u3", "finish_reason": "stop"},
            ]
        });
        write_executable(
            &format!("{bin}/hermes"),
            &format!("#!/bin/sh\ncat <<'EOF'\n{export}\nEOF\n"),
        );
        let env = Env::from_pairs([("PATH", format!("{bin}:/usr/bin:/bin"))]);
        let home = dir.path();
        let ctx = ReaderContext {
            root: &home,
            env: &env,
            home: &home,
            cwd: None,
            signal: None,
        };
        let mut turns = ChatTurns::new();
        (READER.parse)("20261012_164012_b4df59", &ctx, &mut turns).unwrap();
        let chat = turns.finish(None).unwrap();
        let ids: Vec<&str> = chat
            .messages
            .iter()
            .filter_map(|m| m["id"].as_str())
            .collect();
        assert_eq!(ids, ["message:1", "u3"]);
        assert_eq!(chat.messages[0]["text"], "hi");
        assert_eq!(chat.messages[0]["ts"], "2026-10-12T16:41:23.500Z");
        assert!(!chat.turn_open);
    }

    #[test]
    fn hermes_root_is_the_home_dot_hermes() {
        assert_eq!((READER.root)(&Env::default(), "/home/u"), "/home/u/.hermes");
    }
}
