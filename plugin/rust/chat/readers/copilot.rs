//! GitHub Copilot CLI transcript reader (chat-readers/copilot.js;
//! live-verified on 1.0.95, docs/research/harnesses/copilot.md):
//! `$COPILOT_HOME` (default `~/.copilot`) `/session-state/<sessionId>/
//! events.jsonl`, one event per line, `{type, data, id, timestamp, parentId}`
//! in a linear chain; resume appends to the same file.
//!
//! A user turn is `user.message` (`data.content` is the prompt as typed),
//! then `assistant.turn_start`/`assistant.message`/`assistant.turn_end`
//! rounds — one per model call, so a tool round trip yields several; a
//! message's `data.toolRequests` are its tool calls. The turn is over when a
//! round ends whose message asked for no tool. An image attached with
//! `@file` is a `session.binary_asset` line (base64 `data.data`) just before
//! the `user.message` that names it by `assetId` in `data.attachments`.

use std::collections::HashMap;

use crate::chat::readers::{LaunchQuery, Reader, ReaderContext};
use crate::chat::shared::{
    ChatResult, ChatTurns, Found, PROBE_LINES, PickArgs, Prompt, Record, ToolCall, ToolImage,
    expand_home, parse_time, pick_by_launch, read_records, stat_file, subdirectories,
    tool_activity, tool_image,
};
use crate::env::Env;
use crate::jspath;
use crate::jsx::{field, trim};

pub const READER: Reader = Reader {
    root,
    find_by_id,
    find_by_launch: Some(find_by_launch),
    resolve_path: None,
    parse,
};

fn root(env: &Env, home: &str) -> String {
    match env.non_empty("COPILOT_HOME") {
        Some(copilot_home) => expand_home(copilot_home, home),
        None => jspath::join(&[home, ".copilot"]),
    }
}

fn find_by_id(id: &str, base: &str) -> ChatResult<Option<String>> {
    let file = jspath::join(&[base, "session-state", id, "events.jsonl"]);
    Ok(stat_file(&file).map(|_| file))
}

/// The first record is `session.start`, recording the cwd and the start
/// time; whether the file is written at launch or at the first prompt is not
/// verified, so a late start is not ruled out (claude's rule).
fn find_by_launch(query: &LaunchQuery<'_>) -> ChatResult<Option<String>> {
    let files: Vec<String> = subdirectories(&jspath::join(&[query.root, "session-state"]))
        .iter()
        .map(|dir| jspath::join(&[dir, "events.jsonl"]))
        .collect();
    pick_by_launch(&PickArgs {
        files: &files,
        probe: &probe,
        cwd: query.cwd,
        launched_at: query.launched_at,
        home: query.home,
        window: false,
        cwd_matches: None,
        stat: None,
    })
}

fn probe(file: &str) -> ChatResult<Option<Found>> {
    let Ok(records) = read_records(file, None) else {
        return Ok(None);
    };
    for entry in records {
        let Ok(Record { record, line, .. }) = entry else {
            return Ok(None);
        };
        if line > PROBE_LINES {
            break;
        }
        if field(&record, "type").as_str() != Some("session.start") {
            continue;
        }
        let data = field(&record, "data");
        let Some(cwd) = field(field(data, "context"), "cwd").as_str() else {
            return Ok(None);
        };
        let start = field(data, "startTime");
        let start = if start.is_null() {
            field(&record, "timestamp")
        } else {
            start
        };
        return Ok(Some(Found {
            cwd: Some(cwd.to_string()),
            created: parse_time(start),
        }));
    }
    Ok(None)
}

fn parse(file: &str, ctx: &ReaderContext<'_>, turns: &mut ChatTurns) -> ChatResult<()> {
    let transcript = jspath::resolve(&[file]);
    // assetId → media item, from the binary asset lines seen so far.
    let mut assets: HashMap<String, ToolImage> = HashMap::new();
    // Whether the newest assistant message asked for a tool.
    let mut tools_pending = false;
    let mut replied = false;

    for entry in read_records(file, ctx.signal)? {
        let Record { record, offset, .. } = entry?;
        let data = field(&record, "data");
        if !(data.is_object() || data.is_array()) {
            continue;
        }
        // `if (!id) continue`: a missing, non-string or empty id.
        let Some(id) = field(&record, "id").as_str().filter(|id| !id.is_empty()) else {
            continue;
        };
        let ts = parse_time(field(&record, "timestamp"));

        match field(&record, "type").as_str() {
            Some("session.binary_asset") => {
                let Some(asset_id) = field(data, "assetId").as_str() else {
                    continue;
                };
                if field(data, "type").as_str() != Some("image") {
                    continue;
                }
                let media = tool_image(
                    field(data, "data"),
                    field(data, "mimeType"),
                    &transcript,
                    offset,
                    "/data/data",
                    ctx.root,
                );
                if let Some(media) = media {
                    assets.insert(
                        asset_id.to_string(),
                        ToolImage {
                            key: asset_id.to_string(),
                            ..media
                        },
                    );
                }
            }
            Some("user.message") => {
                let text = field(data, "content").as_str().map_or("", trim);
                if text.is_empty() {
                    continue;
                }
                turns.prompt(Prompt {
                    id,
                    text,
                    ts,
                    ..Prompt::default()
                });
                tools_pending = false;
                replied = false;
                if let Some(attachments) = field(data, "attachments").as_array() {
                    for attachment in attachments {
                        let media = field(attachment, "assetId")
                            .as_str()
                            .and_then(|asset| assets.get(asset));
                        if let Some(media) = media {
                            turns.media(media, None);
                        }
                    }
                }
            }
            Some("assistant.message") => {
                let requests = field(data, "toolRequests")
                    .as_array()
                    .map_or(&[][..], Vec::as_slice);
                turns.text(id, ts, field(data, "content"), None);
                for request in requests {
                    let activity =
                        tool_activity(field(request, "name"), field(request, "arguments"));
                    turns.tool(ToolCall {
                        id,
                        ts,
                        activity,
                        ..ToolCall::default()
                    });
                }
                tools_pending = !requests.is_empty();
                replied = true;
            }
            Some("assistant.turn_end") if replied && !tools_pending => {
                turns.end(id, ts, false, None, None);
            }
            // Session, model, system, hook, permission, tool execution and
            // usage events are not chat material.
            _ => {}
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    use crate::chat::readers::gemini_parts::test_support::*;

    #[test]
    fn copilot_completed_turns_a_first_message_a_tool_round_trip_whose_reply_is_the_round_after_it_and_an_attached_image_on_the_reply()
     {
        run_vector("copilot", 0);
    }

    #[test]
    fn copilot_open_turn_a_round_that_asked_for_a_tool_shows_the_command_as_activity() {
        run_vector("copilot", 1);
    }

    fn copilot_session(cwd: &str, start: &str, text: &str) -> Vec<String> {
        vec![
            json!({ "type": "session.start", "id": format!("{text}-s"), "timestamp": start, "parentId": null,
                    "data": { "sessionId": text, "startTime": start, "context": { "cwd": cwd } } })
            .to_string(),
            json!({ "type": "user.message", "id": format!("{text}-u"), "timestamp": start, "parentId": format!("{text}-s"),
                    "data": { "content": text } })
            .to_string(),
        ]
    }

    #[test]
    fn copilot_finds_a_session_id_under_copilot_home_and_with_no_session_the_one_started_in_the_cwd_closest_to_the_launch()
     {
        let dir = TempDir::new();
        let launched = now_ms() - 10.0 * 60_000.0;
        let home = dir.join(&["copilot-home"]);
        let write = |name: &str, cwd: &str, offset: f64| {
            write_lines(
                &jspath::join(&[&home, "session-state", name, "events.jsonl"]),
                &copilot_session(cwd, &iso(launched + offset), name),
            )
        };
        let own = write("own", "/work/demo", 2_000.0);
        write("other", "/work/other", 1_000.0);
        write("later", "/work/demo", 60_000.0);
        let env = Env::from_pairs([("COPILOT_HOME", home.as_str())]);
        let base = (READER.root)(&env, &dir.0);
        assert_eq!(base, home);

        let by_id = (READER.find_by_id)("own", &base).unwrap();
        let by_launch = (READER.find_by_launch.unwrap())(&LaunchQuery {
            cwd: Some("/work/demo"),
            launched_at: Some(launched),
            root: &base,
            home: &dir.0,
        })
        .unwrap();

        assert_eq!(by_id, Some(own.clone()));
        assert_eq!(by_launch, Some(own.clone()));
        let chat = parse_chat("copilot", &own, &base, &dir.0, None).unwrap();
        assert_eq!(texts(&chat), vec!["own"]);
    }

    #[test]
    fn copilot_root_defaults_to_the_home_and_expands_a_tilde() {
        let none = Env::default();
        assert_eq!((READER.root)(&none, "/h"), "/h/.copilot");
        let empty = Env::from_pairs([("COPILOT_HOME", "")]);
        assert_eq!((READER.root)(&empty, "/h"), "/h/.copilot");
        let tilde = Env::from_pairs([("COPILOT_HOME", "~/cp")]);
        assert_eq!((READER.root)(&tilde, "/h"), "/h/cp");
    }
}

#[cfg(test)]
mod edge_tests {
    use serde_json::json;

    use super::*;
    use crate::chat::readers::gemini_parts::test_support::*;
    use crate::chat::shared::AbortSignal;

    fn session(dir: &TempDir, id: &str, cwd: &str, start: &str) -> String {
        let records = [
            json!({ "type": "session.start", "id": "s", "timestamp": start, "data": { "startTime": start, "context": { "cwd": cwd } } })
                .to_string(),
            json!({ "type": "user.message", "id": "u", "timestamp": start, "data": { "content": id } }).to_string(),
        ];
        write_lines(&dir.join(&["session-state", id, "events.jsonl"]), &records)
    }

    fn find(dir: &TempDir, cwd: &str, launched: f64) -> Option<String> {
        find_by_launch(&LaunchQuery {
            cwd: Some(cwd),
            launched_at: Some(launched),
            root: &dir.0,
            home: &dir.0,
        })
        .unwrap()
    }

    #[test]
    fn a_symlinked_session_directory_is_not_scanned_but_a_symlinked_cwd_matches() {
        let dir = TempDir::new();
        let real_cwd = dir.join(&["proj"]);
        std::fs::create_dir_all(&real_cwd).unwrap();
        let link_cwd = dir.join(&["proj-link"]);
        std::os::unix::fs::symlink(&real_cwd, &link_cwd).unwrap();
        let own = session(&dir, "own", &real_cwd, &iso(1_000.0));
        std::os::unix::fs::symlink(
            dir.join(&["session-state", "own"]),
            dir.join(&["session-state", "alias"]),
        )
        .unwrap();
        assert_eq!(find(&dir, &link_cwd, 1_000.0), Some(own));
    }

    #[test]
    fn there_is_no_launch_window_but_the_slack_is_ten_seconds_inclusive() {
        let dir = TempDir::new();
        let launched = 1_000_000.0;
        session(&dir, "late", "/work/demo", &iso(launched + 600_000.0));
        assert!(
            find(&dir, "/work/demo", launched)
                .unwrap()
                .contains("/late/")
        );
        session(&dir, "edge", "/work/demo", &iso(launched - 10_000.0));
        assert!(
            find(&dir, "/work/demo", launched)
                .unwrap()
                .contains("/edge/")
        );
        let dir = TempDir::new();
        session(&dir, "early", "/work/demo", &iso(launched - 10_001.0));
        assert_eq!(find(&dir, "/work/demo", launched), None);
    }

    #[test]
    fn a_tie_in_distance_goes_to_the_earlier_start() {
        let dir = TempDir::new();
        let launched = 1_000_000.0;
        session(&dir, "after", "/work/demo", &iso(launched + 4_000.0));
        session(&dir, "before", "/work/demo", &iso(launched - 4_000.0));
        assert!(
            find(&dir, "/work/demo", launched)
                .unwrap()
                .contains("/before/")
        );
    }

    #[test]
    fn session_start_is_read_only_within_the_probe_lines() {
        let dir = TempDir::new();
        let launched = 1_000_000.0;
        let filler = json!({ "type": "x", "id": "f", "data": {} }).to_string();
        let start = json!({ "type": "session.start", "id": "s", "data": { "startTime": iso(launched), "context": { "cwd": "/work/demo" } } }).to_string();
        let mut lines = vec![filler.clone(); 199];
        lines.push(start.clone());
        write_lines(&dir.join(&["session-state", "in", "events.jsonl"]), &lines);
        assert!(find(&dir, "/work/demo", launched).unwrap().contains("/in/"));
        let dir = TempDir::new();
        let mut lines = vec![filler; 200];
        lines.push(start);
        write_lines(&dir.join(&["session-state", "out", "events.jsonl"]), &lines);
        assert_eq!(find(&dir, "/work/demo", launched), None);
    }

    #[test]
    fn an_aborted_read_stops_with_the_reason() {
        let dir = TempDir::new();
        let file = session(&dir, "own", "/work/demo", &iso(1_000.0));
        let signal = AbortSignal::new();
        signal.abort("deadline");
        let env = Env::default();
        let ctx = ReaderContext {
            root: &dir.0,
            env: &env,
            home: &dir.0,
            cwd: None,
            signal: Some(&signal),
        };
        assert_eq!(
            (READER.parse)(&file, &ctx, &mut ChatTurns::new())
                .unwrap_err()
                .message,
            "deadline"
        );
    }

    #[test]
    fn a_missing_transcript_is_an_enoent_error() {
        let dir = TempDir::new();
        let file = dir.join(&["nope.jsonl"]);
        let error = parse_chat("copilot", &file, &dir.0, &dir.0, None).unwrap_err();
        assert!(error.is_missing());
        assert_eq!(
            error.message,
            format!("ENOENT: no such file or directory, open '{file}'")
        );
    }

    #[test]
    fn an_asset_must_precede_its_prompt_and_the_media_rides_the_reply() {
        let dir = TempDir::new();
        let asset = |id: &str, data: &str| {
            json!({ "type": "session.binary_asset", "id": format!("asset-{id}"),
                    "data": { "assetId": id, "type": "image", "mimeType": "image/png", "data": data } })
            .to_string()
        };
        let prompt = |id: &str, assets: &[&str]| {
            let attachments: Vec<_> = assets.iter().map(|a| json!({ "assetId": a })).collect();
            json!({ "type": "user.message", "id": id, "data": { "content": "look", "attachments": attachments } }).to_string()
        };
        let reply =
            json!({ "type": "assistant.message", "id": "a", "data": { "content": "seen" } })
                .to_string();
        let lines = [
            prompt("u0", &["late"]),
            asset("early", "iVBORw0KGgo="),
            asset("late", "AAAA"),
            prompt("u1", &["early", "late", "none"]),
            reply,
        ];
        let file = write_lines(&dir.join(&["e.jsonl"]), &lines);
        let chat = parse_chat("copilot", &file, &dir.0, &dir.0, Some("idle")).unwrap();
        let last = chat.messages.last().unwrap();
        let ids: Vec<&str> = last["media"]
            .as_array()
            .unwrap()
            .iter()
            .map(|m| m["id"].as_str().unwrap())
            .collect();
        assert_eq!(ids.len(), 2);
        assert!(ids[0].starts_with("inline:"), "{ids:?}");
    }
}
