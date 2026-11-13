//! Antigravity CLI (`agy`) transcript reader (chat-readers/agy.js;
//! live-verified on 1.3.3, docs/research/harnesses/agy.md):
//! `~/.gemini/antigravity-cli/brain/<conversationId>/.system_generated/logs/
//! transcript_full.jsonl`, one step per line, `{step_index, source, type,
//! status, created_at, content, tool_calls?, error?, media?}`; resume appends
//! to the same file. The file records no cwd, so a chat is found only by its
//! conversation id or path.
//!
//! `USER_INPUT` steps are prompts, wrapped in `<USER_REQUEST>…</USER_REQUEST>`
//! plus `<ADDITIONAL_METADATA>`; an image the user uploaded is a
//! `media: [{mime_type, uri}]` entry naming a file in the conversation's
//! `.user_uploaded/` directory. `PLANNER_RESPONSE` steps hold the reply text
//! or `tool_calls`; `GENERIC` steps are tool results, and one with
//! `status: "ERROR"` (a denied tool) ends the turn with its `error`.
//! `SYSTEM_MESSAGE` steps are agy's own notices. There is no end-of-turn
//! record: the Agent Status closes a turn.

use serde_json::{Value, json};

use crate::chat::readers::{Reader, ReaderContext};
use crate::chat::shared::{
    ChatResult, ChatTurns, Prompt, Record, ToolCall, parse_time, read_records, stat_file,
    tool_activity,
};
use crate::env::Env;
use crate::jspath;
use crate::jsx::{field, is_integer, number_to_string, trim};

const OPEN: &str = "<USER_REQUEST>";
const CLOSE: &str = "</USER_REQUEST>";

pub const READER: Reader = Reader {
    root,
    find_by_id,
    find_by_launch: None,
    resolve_path: None,
    parse,
};

fn root(_env: &Env, home: &str) -> String {
    jspath::join(&[home, ".gemini", "antigravity-cli"])
}

/// The transcript of a conversation; its directory is the brain directory
/// three levels up.
fn transcript_of(base: &str, id: &str) -> String {
    jspath::join(&[
        base,
        "brain",
        id,
        ".system_generated",
        "logs",
        "transcript_full.jsonl",
    ])
}

fn find_by_id(id: &str, base: &str) -> ChatResult<Option<String>> {
    let file = transcript_of(base, id);
    Ok(stat_file(&file).map(|_| file))
}

/// `/<USER_REQUEST>\n?([\s\S]*?)\n?<\/USER_REQUEST>/.exec(content)?.[1]`:
/// after the first opener (and one newline), up to the first closer, minus
/// one newline before it.
fn user_request(content: &str) -> Option<&str> {
    let after = &content[content.find(OPEN)? + OPEN.len()..];
    let after = after.strip_prefix('\n').unwrap_or(after);
    let end = after.find(CLOSE)?;
    let body = &after[..end];
    Some(body.strip_suffix('\n').unwrap_or(body))
}

fn parse(file: &str, ctx: &ReaderContext<'_>, turns: &mut ChatTurns) -> ChatResult<()> {
    // Uploaded media may only name files inside this conversation's
    // directory: transcript content is agent-controlled.
    let brain = jspath::resolve(&[file, "..", "..", ".."]);
    for entry in read_records(file, ctx.signal)? {
        let Record { record, line, .. } = entry?;
        let step = field(&record, "step_index");
        let id = if is_integer(step) {
            format!(
                "step:{}",
                number_to_string(step.as_f64().unwrap_or(f64::NAN))
            )
        } else {
            format!("line:{line}")
        };
        let ts = parse_time(field(&record, "created_at"));
        let kind = field(&record, "type").as_str();
        if kind == Some("USER_INPUT") {
            let content = field(&record, "content").as_str().unwrap_or("");
            let text = trim(user_request(content).unwrap_or(content));
            if text.is_empty() {
                continue;
            }
            turns.prompt(Prompt {
                id: &id,
                text,
                ts,
                ..Prompt::default()
            });
            if let Some(media) = field(&record, "media").as_array() {
                for media in media {
                    if let Some((item, key)) = uploaded_media(media, &brain) {
                        turns.media_item(item, Some(&key), None);
                    }
                }
            }
        } else if kind == Some("PLANNER_RESPONSE") {
            turns.text(&id, ts, field(&record, "content"), None);
            if let Some(calls) = field(&record, "tool_calls").as_array() {
                for call in calls {
                    let activity = tool_activity(field(call, "name"), field(call, "args"));
                    turns.tool(ToolCall {
                        id: &id,
                        ts,
                        activity,
                        ..ToolCall::default()
                    });
                }
            }
            if field(&record, "status").as_str() == Some("ERROR") {
                turns.end(&id, ts, true, None, error_of(&record));
            }
        } else if kind == Some("GENERIC") && field(&record, "status").as_str() == Some("ERROR") {
            turns.end(&id, ts, true, None, error_of(&record));
        }
    }
    Ok(())
}

fn error_of(record: &Value) -> Option<&str> {
    field(record, "error").as_str()
}

/// An uploaded image as a Host-path media item and its key, or None when it
/// is elsewhere or gone.
fn uploaded_media(media: &Value, brain: &str) -> Option<(Value, String)> {
    let mime = field(media, "mime_type").as_str();
    let uri = field(media, "uri").as_str()?;
    let mime = mime.filter(|mime| mime.starts_with("image/"))?;
    if !jspath::is_absolute(uri) {
        return None;
    }
    let file = jspath::resolve(&[uri]);
    if !file.starts_with(&format!("{brain}/")) || stat_file(&file).is_none() {
        return None;
    }
    let item = json!({ "id": format!("file:{file}"), "kind": "image", "mime": mime, "path": file });
    Some((item, format!("file:{file}")))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::chat::readers::gemini_parts::test_support::*;

    #[test]
    fn agy_completed_turns_the_user_request_wrapper_stripped_the_reply_after_the_tool_step() {
        run_vector("agy", 0);
    }

    #[test]
    fn agy_open_turn_a_planner_response_tool_call_is_the_activity() {
        run_vector("agy", 1);
    }

    #[test]
    fn agy_denied_tool_the_generic_error_step_ends_the_turn_as_its_reply_esc_leaves_an_empty_reply()
    {
        run_vector("agy", 2);
    }

    #[test]
    fn agy_finds_a_conversation_id_records_no_cwd_so_a_read_with_no_session_finds_nothing_and_shows_only_uploads_inside_the_conversation()
     {
        let dir = TempDir::new();
        let launched = now_ms() - 10.0 * 60_000.0;
        let base = (READER.root)(&Env::default(), &dir.0);
        let brain = jspath::join(&[&base, "brain", "conv1"]);
        let upload = jspath::join(&[&brain, ".user_uploaded", "uploaded_media_1.png"]);
        write_lines(&upload, &["png".to_string()]);
        let outside = write_lines(&dir.join(&["elsewhere.png"]), &["png".to_string()]);
        let step = json!({
            "step_index": 0,
            "source": "USER_EXPLICIT",
            "type": "USER_INPUT",
            "status": "DONE",
            "created_at": iso(launched),
            "content": "<USER_REQUEST>\nwhat color\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\n</ADDITIONAL_METADATA>",
            "media": [
                { "mime_type": "image/png", "uri": upload },
                { "mime_type": "image/png", "uri": outside },
                { "mime_type": "image/png", "uri": format!("{brain}/.user_uploaded/../../../../elsewhere.png") },
            ],
        });
        let reply = json!({
            "step_index": 1, "source": "MODEL", "type": "PLANNER_RESPONSE", "status": "DONE",
            "created_at": iso(launched), "content": "Red.",
        });
        let file = write_lines(
            &jspath::join(&[&brain, ".system_generated", "logs", "transcript_full.jsonl"]),
            &[step.to_string(), reply.to_string()],
        );

        assert_eq!(
            (READER.find_by_id)("conv1", &base).unwrap(),
            Some(file.clone())
        );
        let chat = parse_chat("agy", &file, &base, &dir.0, Some("idle")).unwrap();

        let media = chat.messages.last().unwrap()["media"].clone();
        assert_eq!(
            media,
            json!([{ "id": format!("file:{upload}"), "kind": "image", "mime": "image/png", "path": upload }])
        );
        assert!(READER.find_by_launch.is_none());
    }

    #[test]
    fn user_request_matches_like_the_regex() {
        assert_eq!(
            user_request("<USER_REQUEST>\nhi\n</USER_REQUEST>x"),
            Some("hi")
        );
        assert_eq!(user_request("a<USER_REQUEST>hi</USER_REQUEST>"), Some("hi"));
        assert_eq!(
            user_request("<USER_REQUEST>\n\nhi\n\n</USER_REQUEST>"),
            Some("\nhi\n")
        );
        assert_eq!(user_request("<USER_REQUEST></USER_REQUEST>"), Some(""));
        assert_eq!(user_request("<USER_REQUEST>\n</USER_REQUEST>"), Some(""));
        assert_eq!(
            user_request("<USER_REQUEST>a</USER_REQUEST>b</USER_REQUEST>"),
            Some("a")
        );
        assert_eq!(user_request("<USER_REQUEST>no close"), None);
        assert_eq!(user_request("</USER_REQUEST><USER_REQUEST>x"), None);
    }
}

#[cfg(test)]
mod edge_tests {
    use super::*;
    use crate::chat::readers::gemini_parts::test_support::*;
    use crate::chat::shared::AbortSignal;

    fn conversation(dir: &TempDir, steps: &[Value]) -> (String, String) {
        let brain = dir.join(&["brain", "conv"]);
        let file = write_lines(
            &jspath::join(&[&brain, ".system_generated", "logs", "transcript_full.jsonl"]),
            &steps.iter().map(Value::to_string).collect::<Vec<_>>(),
        );
        (brain, file)
    }

    #[test]
    fn a_symlink_out_of_the_conversation_is_still_inside_by_name() {
        // Containment is by the resolved name, not the real path: the JS
        // never resolves symlinks.
        let dir = TempDir::new();
        let (brain, file) = conversation(&dir, &[]);
        let outside = write_lines(&dir.join(&["elsewhere.png"]), &["png".to_string()]);
        let uploads = jspath::join(&[&brain, ".user_uploaded"]);
        std::fs::create_dir_all(&uploads).unwrap();
        std::os::unix::fs::symlink(&outside, jspath::join(&[&uploads, "link.png"])).unwrap();
        let step = json!({ "step_index": 0, "type": "USER_INPUT", "content": "look",
                           "media": [{ "mime_type": "image/png", "uri": jspath::join(&[&uploads, "link.png"]) }] });
        write_lines(&file, &[step.to_string()]);
        let chat = parse_chat("agy", &file, &dir.0, &dir.0, Some("idle")).unwrap();
        assert_eq!(chat.messages.len(), 2);
        assert_eq!(
            chat.messages[1]["media"][0]["path"],
            jspath::join(&[&uploads, "link.png"])
        );
    }

    #[test]
    fn a_directory_or_missing_upload_is_dropped() {
        let dir = TempDir::new();
        let (brain, file) = conversation(&dir, &[]);
        let uploads = jspath::join(&[&brain, ".user_uploaded"]);
        std::fs::create_dir_all(jspath::join(&[&uploads, "dir.png"])).unwrap();
        let media: Vec<Value> = ["dir.png", "none.png"]
            .iter()
            .map(|name| json!({ "mime_type": "image/png", "uri": jspath::join(&[&uploads, name]) }))
            .collect();
        let step =
            json!({ "step_index": 0, "type": "USER_INPUT", "content": "look", "media": media });
        write_lines(&file, &[step.to_string()]);
        let chat = parse_chat("agy", &file, &dir.0, &dir.0, Some("idle")).unwrap();
        assert_eq!(chat.messages.len(), 2);
        assert!(chat.messages[1].get("media").is_none());
    }

    #[test]
    fn step_index_names_the_message_only_when_it_is_an_integer() {
        let dir = TempDir::new();
        let steps = [
            json!({ "step_index": 4, "type": "USER_INPUT", "content": "a" }),
            json!({ "step_index": 1.5, "type": "USER_INPUT", "content": "b" }),
            json!({ "step_index": "7", "type": "USER_INPUT", "content": "c" }),
            json!({ "step_index": 1e21, "type": "USER_INPUT", "content": "d" }),
        ];
        let (_, file) = conversation(&dir, &steps);
        let chat = parse_chat("agy", &file, &dir.0, &dir.0, Some("idle")).unwrap();
        let ids: Vec<&str> = chat
            .messages
            .iter()
            .filter(|m| m["role"] == "user")
            .map(|m| m["id"].as_str().unwrap())
            .collect();
        assert_eq!(ids, ["step:4", "line:2", "line:3", "step:1e+21"]);
    }

    #[test]
    fn an_error_step_ends_the_turn_with_its_error_text() {
        let dir = TempDir::new();
        let steps = [
            json!({ "step_index": 0, "type": "USER_INPUT", "content": "go" }),
            json!({ "step_index": 1, "type": "GENERIC", "status": "ERROR", "error": "denied" }),
        ];
        let (_, file) = conversation(&dir, &steps);
        let chat = parse_chat("agy", &file, &dir.0, &dir.0, None).unwrap();
        assert!(!chat.turn_open);
        assert_eq!(chat.messages[1]["text"], "denied");
        assert_eq!(chat.messages[1]["id"], "step:1");
    }

    #[test]
    fn an_aborted_read_stops_with_the_reason() {
        let dir = TempDir::new();
        let (_, file) = conversation(&dir, &[json!({ "type": "USER_INPUT", "content": "x" })]);
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
}
