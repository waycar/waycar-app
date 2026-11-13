//! Gemini `parts` message bodies, shared by the gemini and qwen readers
//! (chat-readers/gemini-parts.js; qwen is a Gemini CLI fork that kept the
//! shape; both live-verified, docs/research/harnesses/gemini.md and qwen.md).
//! An `@file` attachment appends `{text: "\n--- Content from referenced files
//! ---"}`, the file's parts (`inlineData` for an image) and
//! `{text: "\n--- End of content ---"}` to the prompt's own text parts.
//!
//! # Differences from the JS
//!
//! `gemini_parts_media` on a value that is not an array yields no items; the
//! JS would throw a `TypeError` (`parts.forEach`). Both callers pass an array.

use serde_json::Value;

use crate::chat::shared::{ToolImage, tool_image};
use crate::jsx::{field, trim, truthy};

const REFERENCED_FILES: &str = "--- Content from referenced files ---";

/// `geminiPromptText`: the text the user typed: the text parts before any
/// attached content; "" for a tool result.
pub fn gemini_prompt_text(parts: &Value) -> String {
    let Some(parts) = parts.as_array() else {
        return String::new();
    };
    if parts
        .iter()
        .any(|part| truthy(field(part, "functionResponse")))
    {
        return String::new();
    }
    let mut typed = String::new();
    for part in parts {
        let Some(text) = field(part, "text").as_str() else {
            continue;
        };
        if field(part, "thought") == &Value::Bool(true) {
            continue;
        }
        if trim(text).starts_with(REFERENCED_FILES) {
            break;
        }
        typed.push_str(text);
    }
    trim(&typed).to_string()
}

/// `geminiPartsMedia`: the attached images (`inlineData` parts) as media
/// items; `pointer` names the parts array.
pub fn gemini_parts_media(
    parts: &Value,
    transcript: &str,
    offset: u64,
    pointer: &str,
    root: &str,
) -> Vec<ToolImage> {
    let mut items = Vec::new();
    let Some(parts) = parts.as_array() else {
        return items;
    };
    for (index, part) in parts.iter().enumerate() {
        let inline = field(part, "inlineData");
        let mime = field(inline, "mimeType");
        if !mime.as_str().is_some_and(|m| m.starts_with("image/")) {
            continue;
        }
        let place = format!("{pointer}/{index}/inlineData/data");
        if let Some(media) = tool_image(
            field(inline, "data"),
            mime,
            transcript,
            offset,
            &place,
            root,
        ) {
            items.push(media);
        }
    }
    items
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn prompt_text_is_the_typed_text_before_attachments() {
        let parts = json!([
            {"text": "look at "},
            {"text": "this"},
            {"text": "  \n--- Content from referenced files ---"},
            {"text": "ignored"},
        ]);
        assert_eq!(gemini_prompt_text(&parts), "look at this");
    }

    #[test]
    fn prompt_text_skips_thoughts_and_tool_results() {
        let parts = json!([{"text": "hidden", "thought": true}, {"text": " hi "}]);
        assert_eq!(gemini_prompt_text(&parts), "hi");
        let result = json!([{"text": "hi"}, {"functionResponse": {"name": "x"}}]);
        assert_eq!(gemini_prompt_text(&result), "");
        assert_eq!(gemini_prompt_text(&json!("text")), "");
        assert_eq!(gemini_prompt_text(&json!([null, 3, "x"])), "");
    }

    #[test]
    fn media_names_each_image_part_by_pointer() {
        let parts = json!([
            {"text": "x"},
            {"inlineData": {"mimeType": "image/png", "data": "aGVsbG8="}},
            {"inlineData": {"mimeType": "application/pdf", "data": "aGVsbG8="}},
            {"inlineData": {"mimeType": "image/jpeg", "data": ""}},
        ]);
        let items = gemini_parts_media(&parts, "/t.jsonl", 7, "/content", "/root");
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].item["id"], "inline:7:/content/1/inlineData/data");
        assert_eq!(items[0].item["mime"], "image/png");
        assert_eq!(
            gemini_parts_media(&json!("x"), "/t", 0, "/p", "/r").len(),
            0
        );
    }
}

/// Fixtures shared by the tests of the agy, cline, copilot and gemini readers.
#[cfg(test)]
pub(crate) mod test_support {
    use std::fs;
    use std::sync::atomic::{AtomicUsize, Ordering};

    use serde_json::Value;

    use crate::chat::readers::{Reader, ReaderContext, reader};
    use crate::chat::shared::{Chat, ChatResult, ChatTurns};
    use crate::env::Env;
    use crate::jsx::{parse_json, stringify, to_iso_string};

    /// A unique temp directory, removed on drop.
    pub struct TempDir(pub String);

    impl TempDir {
        pub fn new() -> Self {
            static NEXT: AtomicUsize = AtomicUsize::new(0);
            let path = std::env::temp_dir().join(format!(
                "waycar-readers-a-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir_all(&path).unwrap();
            Self(path.to_string_lossy().into_owned())
        }

        pub fn join(&self, parts: &[&str]) -> String {
            let mut all = vec![self.0.as_str()];
            all.extend_from_slice(parts);
            crate::jspath::join(&all)
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    /// `writeLines`: one line per record, a final newline; returns the file.
    pub fn write_lines(file: &str, lines: &[String]) -> String {
        fs::create_dir_all(crate::jspath::dirname(file)).unwrap();
        let mut text = lines.join("\n");
        text.push('\n');
        fs::write(file, text).unwrap();
        file.to_string()
    }

    pub fn iso(ms: f64) -> String {
        to_iso_string(ms).unwrap()
    }

    pub fn now_ms() -> f64 {
        let elapsed = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap();
        elapsed.as_millis() as f64
    }

    /// `reader.parse` then `finish`, as the chat-read layer does.
    pub fn parse_chat(
        kind: &str,
        file: &str,
        root: &str,
        home: &str,
        status: Option<&str>,
    ) -> ChatResult<Chat> {
        let reader: &Reader = reader(kind).unwrap();
        let env = Env::default();
        let ctx = ReaderContext {
            root,
            env: &env,
            home,
            cwd: None,
            signal: None,
        };
        let mut turns = ChatTurns::new();
        (reader.parse)(file, &ctx, &mut turns)?;
        turns.finish(status)
    }

    pub fn texts(chat: &Chat) -> Vec<String> {
        chat.messages
            .iter()
            .map(|m| m["text"].as_str().unwrap_or_default().to_string())
            .collect()
    }

    /// Each kind's root under the test home (`$ROOT` in the vectors).
    fn kind_root(kind: &str) -> &'static [&'static str] {
        match kind {
            "copilot" => &[".copilot"],
            "gemini" => &[".gemini"],
            "agy" => &[".gemini", "antigravity-cli"],
            "cline" => &[".cline", "data"],
            other => panic!("no root for {other}"),
        }
    }

    /// The `nth` vector of `kind` in test-vectors/chat-transcript-v1.json,
    /// through `parse` + `finish`: messages, `turn_open` and `activity` of
    /// the expected header must come out unchanged.
    pub fn run_vector(kind: &str, nth: usize) {
        let vectors = parse_json(include_str!(
            "../../../test-vectors/chat-transcript-v1.json"
        ))
        .unwrap();
        let case = vectors["cases"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|case| case["kind"] == kind)
            .nth(nth)
            .unwrap();
        let dir = TempDir::new();
        let lines: Vec<String> = case["transcript"]
            .as_array()
            .unwrap()
            .iter()
            .map(|line| line.as_str().unwrap().to_string())
            .collect();
        let file = write_lines(&dir.join(&["transcript.jsonl"]), &lines);
        let root = dir.join(kind_root(kind));
        for blob in case["blobs"].as_array().into_iter().flatten() {
            write_lines(
                &dir.join(&[&root, "blobs", blob.as_str().unwrap()]),
                &["synthetic blob".to_string()],
            );
        }
        let status = case["args"]["status"].as_str();
        let chat = parse_chat(kind, &file, &root, &dir.0, status).unwrap();

        let substitute = |line: &str| {
            line.replace("$TRANSCRIPT_DIR", &dir.0)
                .replace("$TRANSCRIPT", &file)
                .replace("$ROOT", &root)
        };
        let expected: Vec<Value> = case["expected"]
            .as_array()
            .unwrap()
            .iter()
            .map(|line| parse_json(&substitute(line.as_str().unwrap())).unwrap())
            .collect();
        let header = &expected[0];
        assert_eq!(chat.turn_open, header["turn_open"].as_bool().unwrap());
        assert_eq!(chat.activity.as_deref(), header["activity"].as_str());
        let actual: Vec<String> = chat.messages.iter().map(stringify).collect();
        let want: Vec<String> = expected[1..].iter().map(stringify).collect();
        assert_eq!(actual, want);
    }
}
