//! Chat Mode inline media reader (chat-media.js), run by the app over SSH:
//! `waycar chat-media --request -` with one JSON object on stdin:
//!
//! * `{"transcript":"/abs/path.jsonl","offset":N,"pointer":"/…","max_bytes":N}`
//! * `{"session":"ses_…","kind":"kilo","id":"inline:…#prt_…","pointer":"/…","max_bytes":N}`
//!
//! `offset` is the byte offset of a transcript line's start and `pointer` an
//! RFC 6901 JSON Pointer into that line's JSON, to a string of raw base64 or
//! a base64 `data:` URL. A transcript that is one pretty-printed JSON
//! document (cline) is named with offset 0, and the pointer then resolves
//! into the whole file. The `session` form re-runs `<kind> export <session>`
//! for a harness that keeps no transcript file.
//!
//! Writes the decoded bytes to stdout and exits 0. Exits 65 when the file is
//! missing or not a regular file, the transcript path is relative, the
//! offset or pointer is bad, the string is not base64, or the export could
//! not be produced; 66 when the decoded bytes exceed `max_bytes`; 2 on bad
//! arguments or a malformed request. Errors and usage go to stderr.
//!
//! # Differences from the JS
//!
//! * A JS exception that is not a media error (an uncaught `TypeError`) ends
//!   Node with exit 1 and a stack trace; here it is exit 1 and one
//!   `chat-media: <message>` line. The one reachable case is a `session`
//!   request without `id`: `verifyPart` reads `id.lastIndexOf` and throws.
//! * `JSON.parse` of a number outside the f64 range or a lone surrogate
//!   escape differs (see `jsx::parse_json`).

use std::fs::{self, File};
use std::os::unix::fs::FileExt;

use serde_json::Value;

use crate::chat::session_export::{ExportOptions, session_export};
use crate::chat::shared::{ChatError, ErrorKind, sha256_hex};
use crate::env::Env;
use crate::native::Io;
use crate::{jspath, jsx};

const USAGE: &str = "usage: waycar chat-media --request -   (stdin: {\"transcript\":\"/abs/path.jsonl\",\"offset\":<byte offset>,\"pointer\":\"<JSON Pointer>\",\"max_bytes\":<n>} or {\"session\":\"<ses_…>\",\"kind\":\"opencode|kilo\",\"id\":\"<media item id>\",\"pointer\":\"<JSON Pointer>\",\"max_bytes\":<n>})\n";
/// The harnesses whose export-form media items the session form reads.
const EXPORT_MEDIA_KINDS: [&str; 2] = ["opencode", "kilo"];
/// A transcript line longer than this is refused rather than read into memory.
const MAX_LINE_BYTES: u64 = 64 * 1024 * 1024;
const READ_CHUNK_BYTES: usize = 1024 * 1024;

const EXIT_USAGE: i32 = 2;
const EXIT_UNAVAILABLE: i32 = 65;
const EXIT_TOO_LARGE: i32 = 66;
/// An uncaught JS exception.
const EXIT_CRASH: i32 = 1;
const MAX_SAFE_INTEGER: f64 = 9_007_199_254_740_991.0;

/// `MediaError`: an exit code and the message.
#[derive(Debug)]
struct MediaError {
    code: i32,
    message: String,
}

type Media<T> = Result<T, MediaError>;

fn usage<T>(message: impl Into<String>) -> Media<T> {
    Err(MediaError {
        code: EXIT_USAGE,
        message: message.into(),
    })
}

fn unavailable<T>(message: impl Into<String>) -> Media<T> {
    Err(MediaError {
        code: EXIT_UNAVAILABLE,
        message: message.into(),
    })
}

/// `JSON.stringify(text)`.
fn quote(text: &str) -> String {
    let mut out = String::new();
    jsx::write_json_string(text, &mut out);
    out
}

struct Request {
    /// `Some` for the session form.
    session: Option<String>,
    transcript: String,
    offset: f64,
    kind: String,
    id: Option<String>,
    pointer: String,
    max_bytes: f64,
}

/// Run `waycar chat-media <args>`; returns the exit code.
pub fn run(args: &[String], env: &Env, home: &str, io: &mut Io<'_>) -> i32 {
    let outcome = read_request(args, io).and_then(|request| read_media(&request, env, home));
    match outcome {
        Ok(bytes) => {
            let _ = io.stdout.write_all(&bytes);
            let _ = io.stdout.flush();
            0
        }
        Err(error) => {
            let tail = if error.code == EXIT_USAGE { USAGE } else { "" };
            let _ = write!(io.stderr, "chat-media: {}\n{tail}", error.message);
            error.code
        }
    }
}

/// The request from stdin, its fields type-checked. `--request -` is the
/// only accepted argument; a terminal on stdin is refused.
fn read_request(args: &[String], io: &mut Io<'_>) -> Media<Request> {
    if args.len() != 2 || args[0] != "--request" || args[1] != "-" {
        return usage("takes exactly --request -");
    }
    if io.stdin_is_tty {
        return usage("--request -: pipe the request JSON on stdin");
    }
    let mut bytes = Vec::new();
    let _ = io.stdin.read_to_end(&mut bytes);
    let text = String::from_utf8_lossy(&bytes);
    let Some(request) = jsx::parse_json(&text) else {
        let message =
            jsx::json_syntax_error(&text).unwrap_or_else(|| "Unexpected token in JSON".into());
        return usage(format!("--request: stdin is not JSON ({message})"));
    };
    if !request.is_object() {
        return usage("--request: stdin must be one JSON object");
    }
    let max_bytes = match jsx::field(&request, "max_bytes") {
        Value::Number(n) => {
            let n = jsx::json_f64(n);
            (n.fract() == 0.0 && n.abs() <= MAX_SAFE_INTEGER && n > 0.0).then_some(n)
        }
        _ => None,
    };
    let Some(max_bytes) = max_bytes else {
        return usage("--request: max_bytes must be a positive integer");
    };
    let pointer = jsx::field(&request, "pointer");
    // The transcript form reads one line of a JSONL transcript; the session
    // form re-runs the harness's export. `pointer` names the base64 string
    // either way.
    let Some(session) = jsx::get(&request, "session") else {
        let Some(transcript) = jsx::field(&request, "transcript").as_str() else {
            return usage("--request: transcript must be a string");
        };
        let Value::Number(offset) = jsx::field(&request, "offset") else {
            return usage("--request: offset must be a number");
        };
        let Some(pointer) = pointer.as_str() else {
            return usage("--request: pointer must be a string");
        };
        return Ok(Request {
            session: None,
            transcript: transcript.to_string(),
            offset: jsx::json_f64(offset),
            kind: String::new(),
            id: None,
            pointer: pointer.to_string(),
            max_bytes,
        });
    };
    let Some(session) = session.as_str() else {
        return usage("--request: session must be a string");
    };
    // An absent kind is opencode, whose items predate the field.
    let kind = match jsx::get(&request, "kind") {
        None => "opencode",
        Some(Value::String(kind)) if EXPORT_MEDIA_KINDS.contains(&kind.as_str()) => kind,
        Some(_) => {
            return usage(format!(
                "--request: kind must be one of {}",
                EXPORT_MEDIA_KINDS.join(", ")
            ));
        }
    };
    let id = match jsx::get(&request, "id") {
        None => None,
        Some(Value::String(id)) => Some(id.clone()),
        Some(_) => return usage("--request: id must be a string"),
    };
    let Some(pointer) = pointer.as_str() else {
        return usage("--request: pointer must be a string");
    };
    Ok(Request {
        session: Some(session.to_string()),
        transcript: String::new(),
        offset: 0.0,
        kind: kind.to_string(),
        id,
        pointer: pointer.to_string(),
        max_bytes,
    })
}

/// The part the pointer names must still be the one the media item was read
/// from: a `/revert` deletes later messages, so an index-based pointer can
/// come to name a different part, and wrong bytes must never decode. The
/// item's `id` carries the V1 part id or V2 `sha256:<data hash>` after `#`.
fn verify_part(document: &Value, pointer: &str, id: Option<&str>) -> Media<()> {
    // JS: `id.lastIndexOf` on an absent id throws a TypeError.
    let Some(id) = id else {
        return Err(MediaError {
            code: EXIT_CRASH,
            message: "TypeError: Cannot read properties of undefined (reading 'lastIndexOf')"
                .into(),
        });
    };
    let Some(hash) = id.rfind('#') else {
        return Ok(());
    };
    let part_id = &id[hash + 1..];
    if pointer.ends_with("/data")
        && let Some(expected) = part_id.strip_prefix("sha256:")
    {
        let value = resolve_pointer(document, pointer)?;
        if !value
            .as_str()
            .is_some_and(|data| sha256_hex(data.as_bytes()) == expected)
        {
            return unavailable(format!(
                "the data under {} no longer matches {}",
                quote(pointer),
                quote(part_id)
            ));
        }
        return Ok(());
    }
    let Some(part_pointer) = pointer.strip_suffix("/url") else {
        return Ok(());
    };
    let part = match resolve_pointer(document, part_pointer) {
        Ok(part) => part,
        Err(error) if error.code == EXIT_UNAVAILABLE => {
            return unavailable(format!(
                "pointer {} does not name the part of {}",
                quote(pointer),
                quote(id)
            ));
        }
        Err(error) => return Err(error),
    };
    if !part.is_object() || jsx::field(part, "id").as_str() != Some(part_id) {
        return unavailable(format!(
            "the part under {} is no longer {}",
            quote(pointer),
            quote(part_id)
        ));
    }
    Ok(())
}

fn read_media(request: &Request, env: &Env, home: &str) -> Media<Vec<u8>> {
    // Resolve the pointer into the session's export. A failed export (no
    // binary, no such session) is an unavailable source, like a missing file.
    if let Some(session) = &request.session {
        let options = ExportOptions::new(env.clone(), home);
        let data = match session_export(&request.kind, &Value::String(session.clone()), &options) {
            Ok(data) => data,
            Err(ChatError {
                kind: ErrorKind::Export { .. },
                message,
            }) => return unavailable(message),
            Err(error) => {
                return Err(MediaError {
                    code: EXIT_CRASH,
                    message: error.message,
                });
            }
        };
        verify_part(&data, &request.pointer, request.id.as_deref())?;
        let value = resolve_pointer(&data, &request.pointer)?;
        let Some(value) = value.as_str() else {
            return unavailable(format!(
                "pointer {} does not name a string",
                quote(&request.pointer)
            ));
        };
        return decode_base64(value, request.max_bytes);
    }
    let transcript = &request.transcript;
    if !jspath::is_absolute(transcript) {
        return unavailable(format!(
            "transcript is not an absolute path: {}",
            quote(transcript)
        ));
    }
    let offset = request.offset;
    if offset.fract() != 0.0 || offset.abs() > MAX_SAFE_INTEGER || offset < 0.0 {
        return unavailable(format!("bad offset {}", jsx::number_to_string(offset)));
    }
    let offset = offset as u64;
    let line = read_line(transcript, offset)?;
    let mut record = parse_json_bytes(&line);
    // A transcript that is one pretty-printed document (cline's
    // `<id>.messages.json`) starts with a line that is not JSON on its own.
    if record.is_none() && offset == 0 {
        record = parse_json_bytes(&read_document(transcript)?);
    }
    let Some(record) = record else {
        return unavailable(format!("the line at offset {offset} is not JSON"));
    };
    let value = resolve_pointer(&record, &request.pointer)?;
    let Some(value) = value.as_str() else {
        return unavailable(format!(
            "pointer {} does not name a string",
            quote(&request.pointer)
        ));
    };
    decode_base64(value, request.max_bytes)
}

/// The parsed JSON of UTF-8 bytes, or None when they are not JSON.
fn parse_json_bytes(bytes: &[u8]) -> Option<Value> {
    jsx::parse_json(&String::from_utf8_lossy(bytes))
}

/// The whole file, refused over [`MAX_LINE_BYTES`].
fn read_document(file: &str) -> Media<Vec<u8>> {
    let crash = |error: std::io::Error, syscall: &str| MediaError {
        code: EXIT_CRASH,
        message: ChatError::io(&error, syscall, file).message,
    };
    let info = fs::metadata(file).map_err(|e| crash(e, "stat"))?;
    if info.len() > MAX_LINE_BYTES {
        return unavailable(format!("{file} is over {MAX_LINE_BYTES} bytes"));
    }
    fs::read(file).map_err(|e| crash(e, "open"))
}

/// The bytes of the line starting at `offset`, without its line break.
fn read_line(file: &str, offset: u64) -> Media<Vec<u8>> {
    let opened = if file.contains('\0') {
        Err("ERR_INVALID_ARG_VALUE".to_string())
    } else {
        File::open(file).map_err(|error| match ChatError::io(&error, "open", file).kind {
            ErrorKind::Io(code) => code,
            _ => error.to_string(),
        })
    };
    let handle = match opened {
        Ok(handle) => handle,
        Err(code) => return unavailable(format!("cannot open {file}: {code}")),
    };
    let info = handle.metadata().map_err(|e| MediaError {
        code: EXIT_CRASH,
        message: ChatError::io(&e, "fstat", file).message,
    })?;
    if !info.is_file() {
        return unavailable(format!("not a regular file: {file}"));
    }
    if offset >= info.len() {
        return unavailable(format!(
            "offset {offset} is past the end of the file ({} bytes)",
            info.len()
        ));
    }
    if offset > 0 {
        let mut before = [0u8; 1];
        let read = handle.read_at(&mut before, offset - 1).unwrap_or(0);
        if read == 0 || before[0] != 0x0a {
            return unavailable(format!("offset {offset} is not the start of a line"));
        }
    }
    let mut line: Vec<u8> = Vec::new();
    let mut position = offset;
    let mut chunk = vec![0u8; READ_CHUNK_BYTES];
    loop {
        let read = handle
            .read_at(&mut chunk, position)
            .map_err(|e| MediaError {
                code: EXIT_CRASH,
                message: ChatError::io(&e, "read", file).message,
            })?;
        if read == 0 {
            break;
        }
        let newline = chunk[..read].iter().position(|&b| b == 0x0a);
        let end = newline.unwrap_or(read);
        line.extend_from_slice(&chunk[..end]);
        if line.len() as u64 > MAX_LINE_BYTES {
            return unavailable(format!(
                "the line at offset {offset} is over {MAX_LINE_BYTES} bytes"
            ));
        }
        if newline.is_some() {
            break;
        }
        position += read as u64;
    }
    if line.last() == Some(&0x0d) {
        line.pop();
    }
    Ok(line)
}

/// RFC 6901: `""` is the whole document, otherwise `/`-separated tokens with
/// `~1` to `/` and `~0` to `~`.
fn resolve_pointer<'a>(document: &'a Value, pointer: &str) -> Media<&'a Value> {
    if pointer.is_empty() {
        return Ok(document);
    }
    let Some(rest) = pointer.strip_prefix('/') else {
        return unavailable(format!("bad pointer {}", quote(pointer)));
    };
    let mut value = document;
    for raw in rest.split('/') {
        // /~(?![01])/
        let bytes = raw.as_bytes();
        let bad_escape = bytes
            .iter()
            .enumerate()
            .any(|(i, &b)| b == b'~' && !matches!(bytes.get(i + 1), Some(b'0' | b'1')));
        if bad_escape {
            return unavailable(format!("bad pointer {}", quote(pointer)));
        }
        let token = raw.replace("~1", "/").replace("~0", "~");
        let not_found = || unavailable(format!("pointer {} not found", quote(pointer)));
        match value {
            Value::Array(items) => {
                let canonical = token == "0"
                    || (token
                        .as_bytes()
                        .first()
                        .is_some_and(|b| (b'1'..=b'9').contains(b))
                        && token.bytes().all(|b| b.is_ascii_digit()));
                let index = if canonical {
                    token.parse::<usize>().ok()
                } else {
                    None
                };
                match index.and_then(|i| items.get(i)) {
                    Some(item) => value = item,
                    None => return not_found(),
                }
            }
            Value::Object(map) => match map.get(&token) {
                Some(item) => value = item,
                None => return not_found(),
            },
            _ => return not_found(),
        }
    }
    Ok(value)
}

/// `/^data:[^,]*;base64,/i`: the length of the match, if any.
fn base64_data_url_prefix(payload: &str) -> Option<usize> {
    let rest = payload.get(5..)?;
    if !payload[..5].eq_ignore_ascii_case("data:") {
        return None;
    }
    let comma = rest.find(',')?;
    let head = &rest[..comma];
    let suffix = ";base64";
    let cut = head.len().checked_sub(suffix.len())?;
    if head.is_char_boundary(cut) && head[cut..].eq_ignore_ascii_case(suffix) {
        Some(5 + comma + 1)
    } else {
        None
    }
}

/// Raw base64 or a base64 `data:` URL, checked strictly, size-capped before
/// decoding.
fn decode_base64(value: &str, max_bytes: f64) -> Media<Vec<u8>> {
    let mut payload = value;
    if payload.starts_with("data:") {
        let Some(prefix) = base64_data_url_prefix(payload) else {
            return unavailable("the data: URL is not base64");
        };
        payload = &payload[prefix..];
    }
    let payload: String = payload
        .chars()
        .filter(|c| !matches!(c, '\r' | '\n'))
        .collect();
    let body = payload.trim_end_matches('=');
    let padding = payload.len() - body.len();
    // /^[A-Za-z0-9+/]*={0,2}$/
    let valid = padding <= 2
        && body
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'+' || b == b'/');
    if payload.is_empty() || !valid || payload.len() % 4 == 1 {
        return unavailable("the string is not base64");
    }
    if padding > 0 && !payload.len().is_multiple_of(4) {
        return unavailable("the string is not base64");
    }
    let size = ((payload.len() - padding) * 3 / 4) as f64;
    if size > max_bytes {
        return Err(MediaError {
            code: EXIT_TOO_LARGE,
            message: format!(
                "the media is {} bytes, over max_bytes {}",
                jsx::number_to_string(size),
                jsx::number_to_string(max_bytes)
            ),
        });
    }
    Ok(decode_symbols(body))
}

/// `Buffer.from(text, "base64")` of text already checked: 6 bits per symbol,
/// leftover bits dropped.
fn decode_symbols(body: &str) -> Vec<u8> {
    let mut out = Vec::with_capacity(body.len() * 3 / 4);
    let (mut acc, mut bits) = (0u32, 0u32);
    for b in body.bytes() {
        let sextet = match b {
            b'A'..=b'Z' => b - b'A',
            b'a'..=b'z' => b - b'a' + 26,
            b'0'..=b'9' => b - b'0' + 52,
            b'+' => 62,
            _ => 63,
        };
        acc = (acc << 6) | u32::from(sextet);
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
            acc &= (1 << bits) - 1;
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::PermissionsExt;
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicU32, Ordering};

    use serde_json::json;

    use super::*;
    use crate::chat::transcript::{ReadChatArgs, read_chat};

    const PNG_BASE64: &str = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";

    fn png() -> Vec<u8> {
        decode_symbols(PNG_BASE64.trim_end_matches('='))
    }

    struct Dir(PathBuf);

    impl Dir {
        fn new() -> Self {
            static COUNTER: AtomicU32 = AtomicU32::new(0);
            let dir = std::env::temp_dir().join(format!(
                "wc-media-{}-{}",
                std::process::id(),
                COUNTER.fetch_add(1, Ordering::SeqCst)
            ));
            fs::create_dir_all(&dir).unwrap();
            Self(dir)
        }

        fn path(&self, name: &str) -> String {
            self.0.join(name).to_string_lossy().into_owned()
        }
    }

    impl Drop for Dir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    struct Outcome {
        code: i32,
        stdout: Vec<u8>,
        stderr: String,
    }

    fn run_with(request: &str, args: &[&str], env: &Env, home: &str) -> Outcome {
        let args: Vec<String> = args.iter().map(|a| a.to_string()).collect();
        let (mut out, mut err) = (Vec::new(), Vec::new());
        let mut stdin = request.as_bytes();
        let code = run(
            &args,
            env,
            home,
            &mut Io {
                stdin: &mut stdin,
                stdin_is_tty: false,
                stdout: &mut out,
                stderr: &mut err,
            },
        );
        Outcome {
            code,
            stdout: out,
            stderr: String::from_utf8_lossy(&err).into_owned(),
        }
    }

    fn run_request(request: &Value) -> Outcome {
        run_with(
            &jsx::stringify(request),
            &["--request", "-"],
            &Env::default(),
            "/nonexistent",
        )
    }

    /// A transcript whose lines are joined by `eol`: the path and each line's byte offset.
    fn write_transcript(dir: &Dir, records: &[Value], eol: &str) -> (String, Vec<usize>) {
        let file = dir.path("t.jsonl");
        let lines: Vec<String> = records
            .iter()
            .map(|record| match record {
                Value::String(line) => line.clone(),
                other => jsx::stringify(other),
            })
            .collect();
        fs::write(
            &file,
            lines
                .iter()
                .map(|line| format!("{line}{eol}"))
                .collect::<String>(),
        )
        .unwrap();
        let mut offsets = Vec::new();
        let mut offset = 0;
        for line in &lines {
            offsets.push(offset);
            offset += line.len() + eol.len();
        }
        (file, offsets)
    }

    fn b64(bytes: &[u8]) -> String {
        const TABLE: &[u8; 64] =
            b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        let mut out = String::new();
        for chunk in bytes.chunks(3) {
            let n = chunk
                .iter()
                .enumerate()
                .fold(0u32, |acc, (i, b)| acc | (u32::from(*b) << (16 - 8 * i)));
            for i in 0..=chunk.len() {
                out.push(char::from(TABLE[((n >> (18 - 6 * i)) & 63) as usize]));
            }
            for _ in chunk.len()..3 {
                out.push('=');
            }
        }
        out
    }

    fn with(mut request: Value, changes: Value) -> Value {
        for (key, value) in changes.as_object().unwrap() {
            request[key] = value.clone();
        }
        request
    }

    fn claude_records(first: &str, image_content: Value) -> Vec<Value> {
        vec![
            json!({"type": "user", "uuid": "u1", "isSidechain": false, "timestamp": "2026-09-30T12:00:00.000Z", "message": {"role": "user", "content": first}}),
            json!({"type": "assistant", "uuid": "a1", "isSidechain": false, "timestamp": "2026-09-30T12:00:01.000Z", "message": {"role": "assistant", "content": [{"type": "tool_use", "id": "t1", "name": "Read", "input": {}}], "stop_reason": "tool_use"}}),
            json!({"type": "user", "uuid": "r1", "isSidechain": false, "timestamp": "2026-09-30T12:00:02.000Z", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t1", "content": image_content}]}, "toolUseResult": {}}),
            json!({"type": "assistant", "uuid": "a2", "isSidechain": false, "timestamp": "2026-09-30T12:00:03.000Z", "message": {"role": "assistant", "content": [{"type": "text", "text": "Da."}], "stop_reason": "end_turn"}}),
        ]
    }

    fn read_claude(dir: &Dir, file: &str) -> Vec<Value> {
        let env = Env::default();
        let chat = read_chat(&ReadChatArgs {
            kind: "claude",
            session_kind: Some("path"),
            session_value: Some(file),
            cwd: None,
            launched_at: None,
            launch_rivals: None,
            status: None,
            after: None,
            max_messages: None,
            env: &env,
            home: &dir.0.to_string_lossy(),
        });
        chat.messages
    }

    #[test]
    fn decodes_the_item_chat_read_names_past_multi_byte_text_and_crlf_line_ends() {
        let dir = Dir::new();
        let records = claude_records(
            "Zeig das Café-Logo ☕ — bitte",
            json!([{"type": "image", "source": {"type": "base64", "data": PNG_BASE64}}]),
        );
        let (file, offsets) = write_transcript(&dir, &records, "\r\n");

        let messages = read_claude(&dir, &file);
        let item = &messages.last().unwrap()["media"][0];
        assert_eq!(
            item["inline"],
            json!({"transcript": file, "offset": offsets[2], "pointer": "/message/content/0/content/0/source/data"})
        );
        assert_eq!(item["mime"], "image/png");

        let request = with(item["inline"].clone(), json!({"max_bytes": 1024}));
        let result = run_request(&request);
        assert_eq!(result.code, 0, "{}", result.stderr);
        assert_eq!(result.stdout, png());
    }

    #[test]
    fn decodes_inline_items_after_a_line_over_64_kib_of_multi_byte_text_from_a_line_over_128_kib_with_crlf()
     {
        // Over 64 KiB of 3-byte characters, then an image line whose base64 alone is over 128 KiB.
        let dir = Dir::new();
        let big: Vec<u8> = (0..100 * 1024usize)
            .map(|i| ((i * 31 + 7) & 0xff) as u8)
            .collect();
        let first = format!("Café {}", "☕".repeat(24 * 1024));
        let big_png = [&png()[..8], &big[..]].concat();
        let records = claude_records(
            &first,
            json!([
                {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": b64(&big_png)}},
                {"type": "image", "source": {"type": "base64", "data": PNG_BASE64}},
            ]),
        );
        let (file, offsets) = write_transcript(&dir, &records, "\r\n");
        assert!(offsets[1] > 64 * 1024);

        let messages = read_claude(&dir, &file);
        let media = messages.last().unwrap()["media"]
            .as_array()
            .unwrap()
            .clone();
        assert_eq!(media.len(), 2);
        let expected = [big_png, png()];
        for (index, item) in media.iter().enumerate() {
            assert_eq!(item["inline"]["offset"], offsets[2]);
            let result = run_request(&with(
                item["inline"].clone(),
                json!({"max_bytes": 1024 * 1024}),
            ));
            assert_eq!(result.code, 0, "{}", result.stderr);
            assert_eq!(result.stdout, expected[index]);
        }
    }

    #[test]
    fn accepts_line_wrapped_and_unpadded_base64() {
        let dir = Dir::new();
        let mut wrapped = String::new();
        for chunk in PNG_BASE64.as_bytes().chunks(20) {
            wrapped.push_str(std::str::from_utf8(chunk).unwrap());
            if chunk.len() == 20 {
                wrapped.push_str("\r\n");
            }
        }
        let unpadded = PNG_BASE64.trim_end_matches('=');
        let (file, _) = write_transcript(
            &dir,
            &[json!({"wrapped": wrapped, "unpadded": unpadded})],
            "\n",
        );
        for pointer in ["/wrapped", "/unpadded"] {
            let result = run_request(
                &json!({"transcript": file, "offset": 0, "pointer": pointer, "max_bytes": 1024}),
            );
            assert_eq!(result.code, 0, "{pointer}: {}", result.stderr);
            assert_eq!(result.stdout, png(), "{pointer}");
        }
    }

    #[test]
    fn strips_a_base64_data_url_prefix_and_follows_escaped_pointer_tokens() {
        let dir = Dir::new();
        let (file, offsets) = write_transcript(
            &dir,
            &[
                json!({"first": true}),
                json!({"payload": {"a/b": {"c~d": [format!("data:image/png;base64,{PNG_BASE64}")]}}}),
            ],
            "\n",
        );

        let result = run_request(
            &json!({"transcript": file, "offset": offsets[1], "pointer": "/payload/a~1b/c~0d/0", "max_bytes": png().len()}),
        );
        assert_eq!(result.code, 0, "{}", result.stderr);
        assert_eq!(result.stdout, png());
    }

    #[test]
    fn exits_66_when_the_decoded_bytes_exceed_max_bytes_and_writes_nothing() {
        let dir = Dir::new();
        let (file, _) = write_transcript(&dir, &[json!({"data": PNG_BASE64})], "\n");

        let result = run_request(
            &json!({"transcript": file, "offset": 0, "pointer": "/data", "max_bytes": png().len() - 1}),
        );
        assert_eq!(result.code, 66);
        assert!(result.stdout.is_empty());
        assert!(!result.stderr.is_empty());
        assert!(
            result
                .stderr
                .starts_with("chat-media: the media is 70 bytes, over max_bytes 69\n"),
            "{}",
            result.stderr
        );
    }

    #[test]
    fn exits_65_for_a_missing_or_unreadable_source_a_bad_offset_or_pointer_or_a_non_base64_string()
    {
        let dir = Dir::new();
        let (file, offsets) = write_transcript(
            &dir,
            &[
                json!({"data": PNG_BASE64, "text": "not base64!", "number": 7, "url": "data:image/png,raw", "bad": "~", "short": "QUJDR", "padded": "QUJDRA=", "padded3": "QUI==="}),
                json!("not json"),
            ],
            "\n",
        );
        fs::create_dir(dir.path("folder.jsonl")).unwrap();
        let base = json!({"transcript": file, "offset": 0, "pointer": "/data", "max_bytes": 1024});
        let cases = [
            json!({"transcript": "t.jsonl"}),
            json!({"transcript": dir.path("missing.jsonl")}),
            json!({"transcript": dir.path("folder.jsonl")}),
            json!({"offset": 1}),
            json!({"offset": -1}),
            json!({"offset": 1.5}),
            json!({"offset": offsets[1] + 100_000}),
            json!({"offset": offsets[1], "pointer": ""}),
            json!({"pointer": "data"}),
            json!({"pointer": "/missing"}),
            json!({"pointer": "/data/0"}),
            json!({"pointer": "/a~2b"}),
            json!({"pointer": "/number"}),
            json!({"pointer": "/text"}),
            json!({"pointer": "/url"}),
            json!({"pointer": "/bad"}),
            json!({"pointer": "/short"}),
            json!({"pointer": "/padded"}),
            json!({"pointer": "/padded3"}),
        ];
        for change in cases {
            let result = run_request(&with(base.clone(), change.clone()));
            assert_eq!(result.code, 65, "{change}: {}", result.stderr);
            assert!(result.stdout.is_empty(), "{change}");
        }
    }

    #[test]
    fn exits_65_for_a_file_it_cannot_read() {
        // SAFETY: geteuid has no preconditions.
        if unsafe { libc::geteuid() } == 0 {
            return; // root reads any file
        }
        let dir = Dir::new();
        let (file, _) = write_transcript(&dir, &[json!({"data": PNG_BASE64})], "\n");
        fs::set_permissions(&file, fs::Permissions::from_mode(0o000)).unwrap();
        let result = run_request(
            &json!({"transcript": file, "offset": 0, "pointer": "/data", "max_bytes": 1024}),
        );
        assert_eq!(result.code, 65);
        assert!(result.stdout.is_empty());
        assert!(result.stderr.contains("EACCES"), "{}", result.stderr);
    }

    #[test]
    fn exits_65_for_a_valid_json_line_just_over_64_mib_even_with_max_bytes_above_it() {
        let dir = Dir::new();
        let file = dir.path("huge.jsonl");
        let prefix = "{\"data\":\"";
        let suffix = "\"}";
        let fill = 64 * 1024 * 1024 + 1 - prefix.len() - suffix.len();
        let mut content = prefix.as_bytes().to_vec();
        content.resize(content.len() + fill + (4 - fill % 4) % 4, b'A');
        content.extend_from_slice(format!("{suffix}\n").as_bytes());
        fs::write(&file, content).unwrap();

        let result = run_request(
            &json!({"transcript": file, "offset": 0, "pointer": "/data", "max_bytes": 100 * 1024 * 1024}),
        );
        assert_eq!(result.code, 65);
        assert!(result.stdout.is_empty());
        assert!(
            result.stderr.contains("is over 67108864 bytes"),
            "{}",
            result.stderr
        );
    }

    fn stub(dir: &Dir, name: &str, script: &str) -> Env {
        let bin = dir.path("bin");
        fs::create_dir_all(&bin).unwrap();
        let file = Path::new(&bin).join(name);
        let script = if name == "opencode" {
            format!(
                "#!/bin/sh\nif [ \"$1\" = --version ]; then echo 1.19.5; exit 0; fi\n{}",
                script.strip_prefix("#!/bin/sh\n").unwrap_or(script)
            )
        } else {
            script.to_string()
        };
        crate::test_support::write_stub(&file, &script);
        Env::from_pairs([("PATH", format!("{bin}:/usr/bin:/bin"))])
    }

    fn export_json(part_id: &str) -> String {
        jsx::stringify(&json!({
            "info": {"id": "ses_1"},
            "messages": [{"info": {"id": "msg_1", "role": "user"}, "parts": [{"type": "file", "id": part_id, "mime": "image/png", "url": format!("data:image/png;base64,{PNG_BASE64}")}]}],
        }))
    }

    fn run_session(request: &Value, env: &Env, dir: &Dir) -> Outcome {
        run_with(
            &jsx::stringify(request),
            &["--request", "-"],
            env,
            &dir.0.to_string_lossy(),
        )
    }

    #[test]
    fn decodes_an_opencode_session_item_by_re_running_opencode_export() {
        let dir = Dir::new();
        let export_file = dir.path("export.json");
        fs::write(&export_file, export_json("prt_1")).unwrap();
        let env = stub(
            &dir,
            "opencode",
            &format!("#!/bin/sh\ncat '{export_file}'\n"),
        );

        let request = json!({"session": "ses_1", "id": "inline:/messages/0/parts/0/url#prt_1", "pointer": "/messages/0/parts/0/url", "max_bytes": png().len()});
        let result = run_session(&request, &env, &dir);

        assert_eq!(result.code, 0, "{}", result.stderr);
        assert_eq!(result.stdout, png());

        // A part id that no longer matches what the pointer names (a `/revert`
        // shifted the indexes) is refused rather than decoded into wrong bytes.
        let shifted_export = jsx::stringify(&json!({
            "info": {"id": "ses_1"},
            "messages": [
                {"info": {"id": "msg_0", "role": "user"}, "parts": [{"type": "text", "id": "prt_old", "text": "newer message in the slot"}]},
                {"info": {"id": "msg_1", "role": "user"}, "parts": [{"type": "file", "id": "prt_2", "mime": "image/png", "url": format!("data:image/png;base64,{PNG_BASE64}")}]},
            ],
        }));
        fs::write(&export_file, shifted_export).unwrap();
        let shifted = run_session(&request, &env, &dir);
        assert_eq!(shifted.code, 65);
        assert!(shifted.stderr.contains("no longer"), "{}", shifted.stderr);
        assert!(shifted.stdout.is_empty());
    }

    #[test]
    fn opencode_v2_media_refuses_an_image_replaced_at_the_same_index() {
        let dir = Dir::new();
        let export_file = dir.path("export.json");
        let mut data: Value =
            serde_json::from_str(include_str!("../../test/fixtures/opencode2-export.json"))
                .unwrap();
        fs::write(&export_file, jsx::stringify(&data)).unwrap();
        let service = dir.path(".local/state/opencode/service.json");
        fs::create_dir_all(Path::new(&service).parent().unwrap()).unwrap();
        fs::write(
            &service,
            r#"{"url":"http://127.0.0.1:49374","password":"fixture-password"}"#,
        )
        .unwrap();
        let bin = dir.path("bin");
        fs::create_dir_all(&bin).unwrap();
        crate::test_support::write_stub(
            &Path::new(&bin).join("opencode"),
            &format!(
                "#!/bin/sh\nif [ \"$1\" = --version ]; then echo 'opencode v2.2.7'; exit 0; fi\ncat '{export_file}'\n"
            ),
        );
        let env = Env::from_pairs([("PATH", format!("{bin}:/usr/bin:/bin"))]);
        let home = dir.0.to_string_lossy();
        let chat = read_chat(&ReadChatArgs {
            kind: "opencode",
            session_kind: Some("id"),
            session_value: Some("ses_waycarFixture0001"),
            cwd: None,
            launched_at: None,
            launch_rivals: None,
            status: Some("working"),
            after: None,
            max_messages: None,
            env: &env,
            home: &home,
        });
        let item = &chat.messages[9]["media"][0];
        let request = with(
            item["inline"].clone(),
            json!({
                "id": item["id"], "max_bytes": 1024
            }),
        );
        let original = run_session(&request, &env, &dir);
        assert_eq!(original.code, 0, "{}", original.stderr);
        assert_eq!(original.stdout.len(), 73);

        // A revert deletes the old message; a new image occupies its slot.
        data["messages"][13] = json!({
            "id": "msg_replacement", "type": "user", "text": "new image",
            "files": [{"mime": "image/png", "data": PNG_BASE64}]
        });
        fs::write(&export_file, jsx::stringify(&data)).unwrap();
        let replacement = run_session(&request, &env, &dir);
        assert_eq!(replacement.code, 65);
        assert!(
            replacement.stderr.contains("no longer"),
            "{}",
            replacement.stderr
        );
        assert!(replacement.stdout.is_empty());
    }

    #[test]
    fn a_failed_or_binary_less_opencode_export_exits_65_and_a_bad_pointer_with_it() {
        let dir = Dir::new();
        let env = stub(
            &dir,
            "opencode",
            "#!/bin/sh\necho \"Session not found: ses_1\" >&2\nexit 1\n",
        );

        let request = json!({"session": "ses_1", "id": "inline:/x#prt_1", "pointer": "/x", "max_bytes": 1024});
        let failed = run_session(&request, &env, &dir);
        assert_eq!(failed.code, 65);
        assert!(
            failed.stderr.contains("Session not found"),
            "{}",
            failed.stderr
        );
        assert!(failed.stdout.is_empty());

        let nowhere = Env::from_pairs([("PATH", dir.path("nowhere"))]);
        let missing = run_session(&request, &nowhere, &dir);
        // With PATH gone the CLI either finds no binary or, on a Host that keeps
        // one in an install root, that export also fails for the unknown session:
        // both are an unavailable source, not a usage error.
        assert_eq!(missing.code, 65);
        assert!(!missing.stderr.is_empty());
        assert!(missing.stdout.is_empty());
    }

    #[test]
    fn a_kilo_session_item_re_runs_kilo_export_never_opencodes() {
        let dir = Dir::new();
        let export_file = dir.path("export.json");
        fs::write(
            &export_file,
            export_json("prt_1").replace("ses_1", "ses_k1"),
        )
        .unwrap();
        let argv_log = dir.path("argv.log");
        let env = stub(
            &dir,
            "kilo",
            &format!("#!/bin/sh\necho \"$@\" > '{argv_log}'\ncat '{export_file}'\n"),
        );
        stub(&dir, "opencode", "#!/bin/sh\nexit 1\n");

        let result = run_session(
            &json!({"session": "ses_k1", "kind": "kilo", "id": "inline:/messages/0/parts/0/url#prt_1", "pointer": "/messages/0/parts/0/url", "max_bytes": png().len()}),
            &env,
            &dir,
        );

        assert_eq!(result.code, 0, "{}", result.stderr);
        assert_eq!(result.stdout, png());
        assert_eq!(fs::read_to_string(&argv_log).unwrap(), "export ses_k1\n");
    }

    #[test]
    fn decodes_an_item_of_a_transcript_that_is_one_pretty_printed_json_document_cline_named_at_offset_0()
     {
        let dir = Dir::new();
        let id = "1791823632626_6jtha";
        let file = dir.path(&format!(".cline/data/sessions/{id}/{id}.messages.json"));
        fs::create_dir_all(Path::new(&file).parent().unwrap()).unwrap();
        let document = json!({
            "sessionId": id,
            "messages": [
                {"id": "u1", "role": "user", "content": [{"type": "text", "text": "<user_input mode=\"act\">[Image 1] what is this</user_input>"}, {"type": "image", "data": PNG_BASE64, "mediaType": "image/png"}], "ts": 1},
                {"id": "a1", "role": "assistant", "content": [{"type": "text", "text": "A pixel."}], "ts": 2},
            ],
        });
        fs::write(&file, serde_json::to_string_pretty(&document).unwrap()).unwrap();

        let env = Env::default();
        let home = dir.0.to_string_lossy().into_owned();
        let chat = read_chat(&ReadChatArgs {
            kind: "cline",
            session_kind: Some("id"),
            session_value: Some(id),
            cwd: None,
            launched_at: None,
            launch_rivals: None,
            status: Some("idle"),
            after: None,
            max_messages: None,
            env: &env,
            home: &home,
        });
        let item = &chat.messages.last().unwrap()["media"][0];
        let result = run_request(&with(
            item["inline"].clone(),
            json!({"max_bytes": png().len()}),
        ));

        assert_eq!(
            item["inline"],
            json!({"transcript": file, "offset": 0, "pointer": "/messages/0/content/1/data"})
        );
        assert_eq!(result.code, 0, "{}", result.stderr);
        assert_eq!(result.stdout, png());
    }

    #[test]
    fn bad_arguments_or_a_malformed_request_exit_2() {
        let dir = Dir::new();
        let (file, _) = write_transcript(&dir, &[json!({"data": PNG_BASE64})], "\n");
        let valid = json!({"transcript": file, "offset": 0, "pointer": "/data", "max_bytes": 1024});
        let dash: &[&str] = &["--request", "-"];
        let cases: Vec<(&[&str], String)> = vec![
            (&[], jsx::stringify(&valid)),
            (&["--request", "request.json"], jsx::stringify(&valid)),
            (&["--request", "-", "--extra"], jsx::stringify(&valid)),
            (dash, "not json".into()),
            (dash, "[1]".into()),
            (
                dash,
                jsx::stringify(&with(valid.clone(), json!({"transcript": null}))),
            ),
            (
                dash,
                jsx::stringify(&with(valid.clone(), json!({"offset": "0"}))),
            ),
            (
                dash,
                jsx::stringify(&with(valid.clone(), json!({"pointer": 1}))),
            ),
            (
                dash,
                jsx::stringify(&with(valid.clone(), json!({"max_bytes": 0}))),
            ),
            // `max_bytes: undefined` drops the key.
            (
                dash,
                r#"{"transcript":"/x","offset":0,"pointer":"/data"}"#.into(),
            ),
            (
                dash,
                r#"{"session":null,"pointer":"/data","max_bytes":1024}"#.into(),
            ),
            (
                dash,
                r#"{"session":"ses_1","id":5,"pointer":"/data","max_bytes":1024}"#.into(),
            ),
            (
                dash,
                r#"{"session":"ses_1","pointer":1,"max_bytes":1024}"#.into(),
            ),
            (dash, r#"{"session":"ses_1","pointer":"/data"}"#.into()),
            (
                dash,
                r#"{"session":"ses_1","kind":"hermes","pointer":"/data","max_bytes":1024}"#.into(),
            ),
        ];
        for (args, request) in cases {
            let result = run_with(&request, args, &Env::default(), "/nonexistent");
            assert_eq!(result.code, 2, "{args:?} {request}");
            assert!(!result.stderr.is_empty());
            assert!(result.stdout.is_empty());
            assert!(result.stderr.ends_with(USAGE), "{}", result.stderr);
        }
    }

    #[test]
    fn a_terminal_on_stdin_is_refused() {
        let (mut out, mut err) = (Vec::new(), Vec::new());
        let args = vec!["--request".to_string(), "-".to_string()];
        let code = run(
            &args,
            &Env::default(),
            "/h",
            &mut Io {
                stdin: &mut std::io::empty(),
                stdin_is_tty: true,
                stdout: &mut out,
                stderr: &mut err,
            },
        );
        assert_eq!(code, 2);
        assert!(
            String::from_utf8_lossy(&err)
                .starts_with("chat-media: --request -: pipe the request JSON on stdin\n")
        );
    }

    #[test]
    fn base64_follows_buffer_from_for_checked_text() {
        assert_eq!(decode_symbols("QUJDRA"), b"ABCD");
        assert_eq!(decode_symbols("QUI"), b"AB");
        assert_eq!(decode_symbols("QQ"), b"A");
        // Leftover bits are dropped, as Buffer does.
        assert_eq!(decode_symbols("QR"), b"A");
        assert_eq!(decode_symbols("-_").len(), 1);
    }

    #[test]
    fn a_session_request_without_an_id_fails_like_the_js_type_error() {
        let dir = Dir::new();
        let export_file = dir.path("export.json");
        fs::write(&export_file, export_json("prt_1")).unwrap();
        let env = stub(
            &dir,
            "opencode",
            &format!("#!/bin/sh\ncat '{export_file}'\n"),
        );
        let result = run_session(
            &json!({"session": "ses_1", "pointer": "/messages/0/parts/0/url", "max_bytes": 1024}),
            &env,
            &dir,
        );
        assert_eq!(result.code, 1);
        assert!(result.stdout.is_empty());
    }
}
