//! Qwen Code transcript reader (chat-readers/qwen.js; live-verified on 0.25.1,
//! docs/research/harnesses/qwen.md): `~/.qwen/projects/<cwd with "/" -> "-">
//! /chats/<sessionId>.jsonl`, a Claude-style envelope (`uuid`, `parentUuid`,
//! `timestamp`, `type`, `cwd`) around Gemini-style `message.parts`; resume
//! appends to the same file.
//!
//! `type: "user"` records are prompts (an `@file` attachment adds a
//! `--- Content from referenced files ---` text part and `inlineData` parts
//! after the typed text), `assistant` records hold `text` and `functionCall`
//! parts, `tool_result` and `system` records are not chat material. There is
//! no end-of-turn record: the Agent Status closes a turn.

use serde_json::Value;

use crate::chat::readers::gemini_parts::{gemini_parts_media, gemini_prompt_text};
use crate::chat::readers::{LaunchQuery, Reader, ReaderContext};
use crate::chat::shared::{
    ChatResult, ChatTurns, Found, PROBE_LINES, PickArgs, Prompt, ToolCall, list_names, newest_file,
    parse_time, pick_by_launch, read_records, subdirectories, tool_activity,
};
use crate::env::Env;
use crate::{jspath, jsx};

pub const READER: Reader = Reader {
    root,
    find_by_id,
    find_by_launch: Some(find_by_launch),
    resolve_path: None,
    parse,
};

fn root(_env: &Env, home: &str) -> String {
    jspath::join(&[home, ".qwen"])
}

fn find_by_id(id: &str, root: &str) -> ChatResult<Option<String>> {
    let candidates: Vec<String> = subdirectories(&jspath::join(&[root, "projects"]))
        .iter()
        .map(|dir| jspath::join(&[dir, "chats", &format!("{id}.jsonl")]))
        .collect();
    Ok(newest_file(&candidates))
}

/// Every record carries the cwd; the first one's time is the first prompt
/// (claude's rule).
fn find_by_launch(query: &LaunchQuery<'_>) -> ChatResult<Option<String>> {
    let mut files = Vec::new();
    for dir in subdirectories(&jspath::join(&[query.root, "projects"])) {
        let chats = jspath::join(&[&dir, "chats"]);
        for name in list_names(&chats) {
            if name.ends_with(".jsonl") {
                files.push(jspath::join(&[&chats, &name]));
            }
        }
    }
    pick_by_launch(&PickArgs {
        files: &files,
        probe: &|file| Ok(probe(file)),
        cwd: query.cwd,
        launched_at: query.launched_at,
        home: query.home,
        window: false,
        cwd_matches: None,
        stat: None,
    })
}

fn probe(file: &str) -> Option<Found> {
    for item in read_records(file, None).ok()? {
        let item = item.ok()?;
        if item.line > PROBE_LINES {
            break;
        }
        if let Some(cwd) = jsx::field(&item.record, "cwd").as_str() {
            return Some(Found {
                cwd: Some(cwd.to_string()),
                created: parse_time(jsx::field(&item.record, "timestamp")),
            });
        }
    }
    None
}

fn parse(file: &str, ctx: &ReaderContext<'_>, turns: &mut ChatTurns) -> ChatResult<()> {
    let transcript = jspath::resolve(&[file]);
    for item in read_records(file, ctx.signal)? {
        let item = item?;
        let record = &item.record;
        let id = match jsx::field(record, "uuid") {
            Value::String(id) if !id.is_empty() => id.as_str(),
            _ => continue,
        };
        let parts = jsx::field(jsx::field(record, "message"), "parts");
        let Some(list) = parts.as_array() else {
            continue;
        };
        let ts = parse_time(jsx::field(record, "timestamp"));
        match jsx::field(record, "type").as_str() {
            Some("user") => {
                let text = gemini_prompt_text(parts);
                if text.is_empty() {
                    continue;
                }
                turns.prompt(Prompt {
                    id,
                    text: &text,
                    ts,
                    ..Prompt::default()
                });
                for media in
                    gemini_parts_media(parts, &transcript, item.offset, "/message/parts", ctx.root)
                {
                    turns.media(&media, None);
                }
            }
            Some("assistant") => {
                for part in list {
                    if jsx::field(part, "thought") == &Value::Bool(true) {
                        turns.thinking(id, ts, None);
                    } else if let Some(text) = jsx::field(part, "text").as_str() {
                        turns.text_str(id, ts, text, None);
                    } else if jsx::truthy(jsx::field(part, "functionCall")) {
                        let call = jsx::field(part, "functionCall");
                        turns.tool(ToolCall {
                            id,
                            ts,
                            activity: tool_activity(
                                jsx::field(call, "name"),
                                jsx::field(call, "args"),
                            ),
                            ..ToolCall::default()
                        });
                    }
                }
            }
            _ => {}
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use serde_json::{Value, json};

    use super::*;
    use crate::chat::readers::grok::testkit::{TempDir, run_vector, write_lines};

    #[test]
    fn qwen_completed_turns_the_reply_after_a_function_call_round_tool_results_never_prompts() {
        run_vector(
            "qwen completed turns: the reply after a functionCall round, tool results never prompts",
        );
    }

    #[test]
    fn qwen_open_turn_a_function_call_is_the_activity() {
        run_vector("qwen open turn: a functionCall is the activity");
    }

    #[test]
    fn qwen_at_attached_image_the_typed_text_is_the_prompt_and_the_inline_data_part_rides_the_reply()
     {
        run_vector(
            "qwen @-attached image: the typed text is the prompt and the inlineData part rides the reply",
        );
    }

    fn user(uuid: &str, ts: &str, cwd: &str) -> Value {
        json!({"uuid": uuid, "parentUuid": null, "timestamp": ts, "type": "user", "cwd": cwd, "message": {"role": "user", "parts": [{"text": uuid}]}})
    }

    #[test]
    fn qwen_finds_a_session_id_in_any_projects_chats_and_with_no_session_the_cwds_chat_closest_to_the_launch()
     {
        let dir = TempDir::new("qwen");
        let home = dir.path();
        let now_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0.0, |d| d.as_millis() as f64);
        let launched = now_ms - 10.0 * 60_000.0;
        let iso = |ms: f64| jsx::to_iso_string(ms).unwrap();
        let own = write_lines(
            &format!("{home}/.qwen/projects/-work-demo/chats/s1.jsonl"),
            &[user("first", &iso(launched + 3_000.0), "/work/demo")],
        );
        write_lines(
            &format!("{home}/.qwen/projects/-work-demo/chats/s0.jsonl"),
            &[user("old", &iso(launched - 60_000.0), "/work/demo")],
        );
        let base = (READER.root)(&Env::default(), &home);
        assert_eq!(base, format!("{home}/.qwen"));

        assert_eq!(find_by_id("s1", &base).unwrap(), Some(own.clone()));
        let found = find_by_launch(&LaunchQuery {
            cwd: Some("/work/demo"),
            launched_at: Some(launched),
            root: &base,
            home: &home,
        })
        .unwrap();
        assert_eq!(found, Some(own));
    }

    #[test]
    fn qwen_a_cwd_after_the_probe_lines_is_not_seen() {
        let dir = TempDir::new("qwen");
        let file = dir.join("p/chats/s1.jsonl");
        let mut lines: Vec<Value> = (0..200).map(|n| json!({ "n": n })).collect();
        lines.push(user("a", "2026-10-12T16:00:00.000Z", "/w"));
        write_lines(&file, &lines);
        assert!(probe(&file).is_none());
        lines.remove(0);
        write_lines(&file, &lines);
        assert_eq!(probe(&file).and_then(|f| f.cwd).as_deref(), Some("/w"));
    }
}
