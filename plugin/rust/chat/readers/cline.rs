//! Cline CLI transcript reader (chat-readers/cline.js; live-verified on
//! 3.0.70, docs/research/harnesses/cline.md): `~/.cline/data/sessions/
//! <sessionId>/<sessionId>.messages.json` — the default `--data-dir`, which
//! Waycar passes explicitly — one pretty-printed JSON document `{version,
//! sessionId, messages: […]}` rewritten in place, with a manifest
//! `<sessionId>.json` (`cwd`, `started_at`) beside it. Resume (`--id`)
//! appends to the same file.
//!
//! Messages are Anthropic-shaped: user `text` blocks wrapped in
//! `<user_input mode="…">…</user_input>` plus `image` blocks (`data` base64,
//! `mediaType`); assistant `text`, `thinking` and `tool_use` blocks; a user
//! message of `tool_result` blocks is a tool result. There is no end-of-turn
//! record: the Agent Status closes a turn. An image's media item names the
//! file with offset 0 and a pointer into the whole document.

use std::fs;

use serde_json::Value;

use crate::chat::readers::{LaunchQuery, Reader, ReaderContext};
use crate::chat::shared::{
    ChatResult, ChatTurns, Found, PickArgs, Prompt, ToolCall, check_abort, parse_json_object,
    parse_time, pick_by_launch, read_json_document, stat_file, subdirectories, tool_activity,
    tool_image,
};
use crate::env::Env;
use crate::jspath;
use crate::jsx::{field, trim};

const CLOSE_TAG: &str = "</user_input>";

pub const READER: Reader = Reader {
    root,
    find_by_id,
    find_by_launch: Some(find_by_launch),
    resolve_path: None,
    parse,
};

fn root(_env: &Env, home: &str) -> String {
    jspath::join(&[home, ".cline", "data"])
}

fn messages_of(dir: &str) -> String {
    jspath::join(&[dir, &format!("{}.messages.json", jspath::basename(dir))])
}

fn find_by_id(id: &str, base: &str) -> ChatResult<Option<String>> {
    let file = messages_of(&jspath::join(&[base, "sessions", id]));
    Ok(stat_file(&file).map(|_| file))
}

/// The manifest records the cwd and the process start (`started_at`).
fn find_by_launch(query: &LaunchQuery<'_>) -> ChatResult<Option<String>> {
    let files: Vec<String> = subdirectories(&jspath::join(&[query.root, "sessions"]))
        .iter()
        .map(|dir| messages_of(dir))
        .collect();
    pick_by_launch(&PickArgs {
        files: &files,
        probe: &probe,
        cwd: query.cwd,
        launched_at: query.launched_at,
        home: query.home,
        window: true,
        cwd_matches: None,
        stat: None,
    })
}

fn probe(file: &str) -> ChatResult<Option<Found>> {
    let manifest = file
        .strip_suffix(".messages.json")
        .map_or_else(|| file.to_string(), |stem| format!("{stem}.json"));
    let Ok(bytes) = fs::read(manifest) else {
        return Ok(None);
    };
    let manifest = parse_json_object(&String::from_utf8_lossy(&bytes));
    let Some(manifest) = manifest else {
        return Ok(None);
    };
    let Some(cwd) = field(&manifest, "cwd").as_str() else {
        return Ok(None);
    };
    Ok(Some(Found {
        cwd: Some(cwd.to_string()),
        created: parse_time(field(&manifest, "started_at")),
    }))
}

/// `text.replace(/^<user_input\b[^>]*>([\s\S]*)<\/user_input>$/, "$1")`.
fn unwrap_user_input(text: &str) -> &str {
    let Some(rest) = text.strip_prefix("<user_input") else {
        return text;
    };
    // `\b` after the tag name: the next character may not be a word character.
    if rest.starts_with(|c: char| c.is_ascii_alphanumeric() || c == '_') {
        return text;
    }
    let Some(gt) = rest.find('>') else {
        return text;
    };
    match rest[gt + 1..].strip_suffix(CLOSE_TAG) {
        Some(body) => body,
        None => text,
    }
}

fn parse(file: &str, ctx: &ReaderContext<'_>, turns: &mut ChatTurns) -> ChatResult<()> {
    let transcript = jspath::resolve(&[file]);
    check_abort(ctx.signal)?;
    let document = read_json_document(file)?;
    check_abort(ctx.signal)?;
    let empty = Vec::new();
    let messages = field(&document, "messages").as_array().unwrap_or(&empty);
    for (message_index, message) in messages.iter().enumerate() {
        let id = field(message, "id")
            .as_str()
            .map_or_else(|| format!("message:{message_index}"), str::to_string);
        let ts = parse_time(field(message, "ts"));
        let content = field(message, "content");
        let wrapped;
        let content = match content.as_str() {
            Some(text) => {
                wrapped = Value::Array(vec![serde_json::json!({ "type": "text", "text": text })]);
                &wrapped
            }
            None => content,
        };
        let Some(blocks) = content.as_array() else {
            continue;
        };
        match field(message, "role").as_str() {
            Some("user") => {
                if blocks
                    .iter()
                    .any(|block| field(block, "type").as_str() == Some("tool_result"))
                {
                    continue;
                }
                let text = blocks
                    .iter()
                    .filter(|block| field(block, "type").as_str() == Some("text"))
                    .filter_map(|block| field(block, "text").as_str())
                    .map(|text| unwrap_user_input(trim(text)))
                    .collect::<Vec<_>>()
                    .join("\n");
                let text = trim(&text);
                if text.is_empty() {
                    continue;
                }
                turns.prompt(Prompt {
                    id: &id,
                    text,
                    ts,
                    ..Prompt::default()
                });
                for (block_index, block) in blocks.iter().enumerate() {
                    if field(block, "type").as_str() != Some("image") {
                        continue;
                    }
                    let pointer = format!("/messages/{message_index}/content/{block_index}/data");
                    let media = tool_image(
                        field(block, "data"),
                        field(block, "mediaType"),
                        &transcript,
                        0,
                        &pointer,
                        ctx.root,
                    );
                    if let Some(media) = media {
                        turns.media(&media, None);
                    }
                }
            }
            Some("assistant") => {
                for block in blocks {
                    match field(block, "type").as_str() {
                        Some("text") => turns.text(&id, ts, field(block, "text"), None),
                        Some("thinking" | "redacted_thinking") => turns.thinking(&id, ts, None),
                        Some("tool_use") => {
                            let activity =
                                tool_activity(field(block, "name"), field(block, "input"));
                            turns.tool(ToolCall {
                                id: &id,
                                ts,
                                activity,
                                ..ToolCall::default()
                            });
                        }
                        _ => {}
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
    use serde_json::json;

    use super::*;
    use crate::chat::readers::gemini_parts::test_support::*;

    #[test]
    fn cline_completed_turns_user_input_wrapper_stripped_tool_results_never_prompts_the_pasted_image_on_the_reply()
     {
        run_vector("cline", 0);
    }

    #[test]
    fn cline_open_turn_a_tool_use_is_the_activity() {
        run_vector("cline", 1);
    }

    #[test]
    fn cline_finds_a_session_id_and_with_no_session_the_manifest_whose_cwd_and_start_match_the_launch()
     {
        let dir = TempDir::new();
        let launched = now_ms() - 10.0 * 60_000.0;
        let base = (READER.root)(&Env::default(), &dir.0);
        let session = |id: &str, cwd: &str, start: &str| {
            let manifest = json!({ "session_id": id, "cwd": cwd, "started_at": start });
            write_lines(
                &jspath::join(&[&base, "sessions", id, &format!("{id}.json")]),
                &[manifest.to_string()],
            );
            let ts = crate::jsx::date_parse(start).unwrap();
            let document = json!({
                "sessionId": id,
                "messages": [{ "id": format!("{id}-u"), "role": "user", "content": [{ "type": "text", "text": id }], "ts": ts }],
            });
            write_lines(
                &jspath::join(&[&base, "sessions", id, &format!("{id}.messages.json")]),
                &[document.to_string()],
            )
        };
        let own = session("1791823632626_own", "/work/demo", &iso(launched + 500.0));
        session(
            "1791823632626_far",
            "/work/demo",
            &iso(launched + 5.0 * 60_000.0),
        );

        assert_eq!(
            (READER.find_by_id)("1791823632626_own", &base).unwrap(),
            Some(own.clone())
        );
        let found = (READER.find_by_launch.unwrap())(&LaunchQuery {
            cwd: Some("/work/demo"),
            launched_at: Some(launched),
            root: &base,
            home: &dir.0,
        })
        .unwrap();
        assert_eq!(found, Some(own));
    }

    #[test]
    fn user_input_wrapper_matches_like_the_regex() {
        assert_eq!(
            unwrap_user_input("<user_input mode=\"act\">hi</user_input>"),
            "hi"
        );
        assert_eq!(unwrap_user_input("<user_input>a\nb</user_input>"), "a\nb");
        assert_eq!(unwrap_user_input("<user_input></user_input>"), "");
        assert_eq!(
            unwrap_user_input("<user_inputs>hi</user_inputs>"),
            "<user_inputs>hi</user_inputs>"
        );
        assert_eq!(unwrap_user_input("<user_input>hi"), "<user_input>hi");
        assert_eq!(
            unwrap_user_input("<user_input mode=\"</user_input>"),
            "<user_input mode=\"</user_input>"
        );
        assert_eq!(
            unwrap_user_input("x<user_input>hi</user_input>"),
            "x<user_input>hi</user_input>"
        );
        assert_eq!(
            unwrap_user_input("<user_input>a</user_input>b</user_input>"),
            "a</user_input>b"
        );
    }
}

#[cfg(test)]
mod edge_tests {
    use serde_json::json;

    use super::*;
    use crate::chat::readers::gemini_parts::test_support::*;
    use crate::chat::shared::AbortSignal;

    fn document(dir: &TempDir, id: &str) -> String {
        let base = jspath::join(&[&dir.0, "sessions", id]);
        let messages = json!({ "messages": [{ "id": "u", "role": "user", "content": "hi" }] });
        write_lines(
            &jspath::join(&[&base, &format!("{id}.messages.json")]),
            &[messages.to_string()],
        )
    }

    #[test]
    fn a_symlinked_session_directory_is_not_a_session() {
        let dir = TempDir::new();
        let manifest = json!({ "cwd": "/work/demo", "started_at": iso(1_000.0) }).to_string();
        document(&dir, "real");
        write_lines(&dir.join(&["sessions", "real", "real.json"]), &[manifest]);
        std::os::unix::fs::symlink(
            dir.join(&["sessions", "real"]),
            dir.join(&["sessions", "link"]),
        )
        .unwrap();
        let found = find_by_launch(&LaunchQuery {
            cwd: Some("/work/demo"),
            launched_at: Some(1_000.0),
            root: &dir.0,
            home: "/h",
        })
        .unwrap();
        assert_eq!(
            found,
            Some(dir.join(&["sessions", "real", "real.messages.json"]))
        );
        // `findById` looks for `<id>/<id>.messages.json`: the link has none.
        assert!(find_by_id("real", &dir.0).unwrap().is_some());
        assert!(find_by_id("link", &dir.0).unwrap().is_none());
    }

    #[test]
    fn a_symlinked_cwd_matches_its_real_path() {
        let dir = TempDir::new();
        let real = dir.join(&["real-cwd"]);
        std::fs::create_dir_all(&real).unwrap();
        let link = dir.join(&["link-cwd"]);
        std::os::unix::fs::symlink(&real, &link).unwrap();
        let manifest = json!({ "cwd": real, "started_at": iso(1_000.0) }).to_string();
        document(&dir, "s");
        write_lines(&dir.join(&["sessions", "s", "s.json"]), &[manifest]);
        let find = |cwd: &str| {
            find_by_launch(&LaunchQuery {
                cwd: Some(cwd),
                launched_at: Some(1_000.0),
                root: &dir.0,
                home: "/h",
            })
            .unwrap()
        };
        assert!(find(&link).is_some());
        assert!(find(&real).is_some());
        assert!(find(&dir.join(&["nowhere"])).is_none());
    }

    #[test]
    fn the_launch_window_is_two_minutes_and_the_slack_ten_seconds() {
        let dir = TempDir::new();
        let launched = 1_000_000.0;
        let session = |id: &str, start: f64| {
            document(&dir, id);
            let manifest = json!({ "cwd": "/work/demo", "started_at": iso(start) }).to_string();
            write_lines(
                &dir.join(&["sessions", id, &format!("{id}.json")]),
                &[manifest],
            );
        };
        let find = || {
            find_by_launch(&LaunchQuery {
                cwd: Some("/work/demo"),
                launched_at: Some(launched),
                root: &dir.0,
                home: "/h",
            })
            .unwrap()
        };
        // Files are written now: far after this launch, so only the manifest's start counts.
        session("late", launched + 120_001.0);
        assert_eq!(find(), None);
        session("edge", launched + 120_000.0);
        assert!(find().unwrap().contains("/edge/"));
        session("tie_after", launched + 4_000.0);
        session("tie_before", launched - 4_000.0);
        assert!(find().unwrap().contains("/tie_before/"));
    }

    #[test]
    fn an_aborted_read_stops_with_the_reason() {
        let dir = TempDir::new();
        let file = document(&dir, "s");
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
        let error = (READER.parse)(&file, &ctx, &mut ChatTurns::new()).unwrap_err();
        assert_eq!(error.message, "deadline");
    }

    #[test]
    fn a_document_that_is_not_an_object_is_an_error_naming_the_file() {
        let dir = TempDir::new();
        let file = write_lines(&dir.join(&["d.json"]), &["[1]".to_string()]);
        let error = parse_chat("cline", &file, &dir.0, &dir.0, None).unwrap_err();
        assert_eq!(error.message, format!("not a JSON object: {file}"));
    }

    #[test]
    fn only_image_blocks_with_data_become_media() {
        let dir = TempDir::new();
        let document = json!({ "messages": [
            { "id": "u", "role": "user", "content": [
                { "type": "text", "text": "look" },
                { "type": "image", "data": "iVBORw0KGgo=", "mediaType": "image/png" },
                { "type": "image", "data": 5 },
                { "type": "image" },
            ] },
            { "id": "a", "role": "assistant", "content": [{ "type": "text", "text": "ok" }] },
        ] });
        let file = write_lines(&dir.join(&["d.json"]), &[document.to_string()]);
        let chat = parse_chat("cline", &file, &dir.0, &dir.0, Some("idle")).unwrap();
        let media = &chat.messages[1]["media"];
        assert_eq!(media.as_array().unwrap().len(), 1);
        assert_eq!(media[0]["id"], "inline:0:/messages/0/content/1/data");
        assert_eq!(media[0]["inline"]["transcript"], file);
    }
}
