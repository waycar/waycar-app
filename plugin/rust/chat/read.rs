//! The `waycar chat-read` command (chat-read.js), run by the app over SSH:
//! `waycar chat-read --request -` with one JSON object on stdin, so no Host
//! value is ever shell-quoted. The flags remain for manual use. Prints the
//! chat as NDJSON (header first, then messages oldest to newest). Exits 0
//! whenever it can answer, including a transcript not found yet (the header
//! carries the status); exits 2 on bad arguments.
//!
//! The argument errors are Node's `util.parseArgs` (strict, no positionals)
//! messages, produced by [`parse_args`]: a port of Node 24's tokenizer and
//! strict checks for this command's string options. Source reference pinned
//! to Node v24.0.0, revision c5349f43cd66d2aa02d86414c9ed426f71d3ae48,
//! lib/internal/util/parse_args/ (parse_args.js and utils.js); Node's MIT
//! notice is in THIRD-PARTY-LICENSES.
//!
//! # Differences from the JS
//!
//! * `resolveHostConfig()` failing inside the launch-rivals callback throws
//!   in JS, and the throw reaches `readChat`; here the callback has no error
//!   channel, so a failure answers no rivals.
//! * `JSON.parse` of a number outside the f64 range or a lone surrogate
//!   escape differs (see `jsx::parse_json`).

use std::path::Path;

use serde_json::Value;

use crate::chat::launch_rivals::launch_rivals;
use crate::chat::transcript::{ReadChatArgs, RivalQuery, Rivals, format_ndjson, read_chat};
use crate::env::Env;
use crate::exec::run_program;
use crate::herdr::run_herdr;
use crate::jsx;
use crate::native::Io;
use crate::paths::resolve_host_config;

const USAGE: &str = "usage: waycar chat-read --kind <kind> [--session-kind id|path --session-value <v>] [--cwd <dir>] [--launched-at <ISO8601>] [--status <agent_status>] [--after <message id>] [--max-messages <n>]\n       waycar chat-read --request -   (stdin: {\"kind\",\"session_kind\",\"session_value\",\"cwd\",\"launched_at\",\"status\",\"after\",\"max_messages\"})\n";

/// `--request -` keys and the flag names the checks report.
const REQUEST_KEYS: [(&str, &str); 8] = [
    ("kind", "--kind"),
    ("session_kind", "--session-kind"),
    ("session_value", "--session-value"),
    ("cwd", "--cwd"),
    ("launched_at", "--launched-at"),
    ("status", "--status"),
    ("after", "--after"),
    ("max_messages", "--max-messages"),
];

/// The options `parseArgs` is configured with: all take a string.
const OPTIONS: [&str; 9] = [
    "request",
    "kind",
    "session-kind",
    "session-value",
    "cwd",
    "launched-at",
    "status",
    "after",
    "max-messages",
];

const MAX_SAFE_INTEGER: f64 = 9_007_199_254_740_991.0;

/// `max_messages` as the request or the flag carried it.
enum MaxMessages {
    Number(Value),
    Text(String),
}

struct Input {
    kind: Option<String>,
    session_kind: Option<String>,
    session_value: Option<String>,
    cwd: Option<String>,
    launched_at: Option<String>,
    status: Option<String>,
    after: Option<String>,
    max_messages: Option<MaxMessages>,
}

/// Run `waycar chat-read <args>`; returns the exit code.
pub fn run(args: &[String], env: &Env, home: &str, io: &mut Io<'_>) -> i32 {
    match execute(args, env, home, io) {
        Ok(output) => {
            let _ = io.stdout.write_all(output.as_bytes());
            let _ = io.stdout.flush();
            0
        }
        Err(message) => {
            let _ = write!(io.stderr, "chat-read: {message}\n{USAGE}");
            2
        }
    }
}

/// The NDJSON to print, or the message of a `fail`.
fn execute(args: &[String], env: &Env, home: &str, io: &mut Io<'_>) -> Result<String, String> {
    let values = parse_args(args)?;
    let get = |name: &str| {
        values
            .iter()
            .find(|(key, _)| key == name)
            .map(|(_, value)| value.clone())
    };

    let input = if let Some(request) = get("request") {
        if request != "-" {
            return Err(format!("--request takes only -, got {}", quote(&request)));
        }
        if values.len() > 1 {
            return Err("--request - takes no other flags".into());
        }
        read_request(io)?
    } else {
        Input {
            kind: get("kind"),
            session_kind: get("session-kind"),
            session_value: get("session-value"),
            cwd: get("cwd"),
            launched_at: get("launched-at"),
            status: get("status"),
            after: get("after"),
            max_messages: get("max-messages").map(MaxMessages::Text),
        }
    };

    let Some(kind) = input.kind.as_deref().filter(|kind| !kind.is_empty()) else {
        return Err("--kind is required".into());
    };

    let session_kind = input.session_kind.as_deref();
    if let Some(session_kind) = session_kind
        && session_kind != "id"
        && session_kind != "path"
    {
        return Err(format!(
            "--session-kind must be id or path, got {}",
            quote(session_kind)
        ));
    }
    let session_value = input.session_value.as_deref();
    if session_kind.is_none() != session_value.is_none() || session_value == Some("") {
        return Err("--session-kind and --session-value go together".into());
    }

    let launched_at = input.launched_at.as_deref();
    if let Some(text) = launched_at
        && jsx::date_parse(text).is_none()
    {
        return Err(format!(
            "--launched-at is not an ISO 8601 time: {}",
            quote(text)
        ));
    }

    let mut max_messages = None;
    if let Some(raw) = &input.max_messages {
        let number = match raw {
            MaxMessages::Number(Value::Number(n)) => jsx::json_f64(n),
            MaxMessages::Number(_) => f64::NAN,
            // /^\d+$/
            MaxMessages::Text(text)
                if !text.is_empty() && text.bytes().all(|b| b.is_ascii_digit()) =>
            {
                text.parse::<f64>().unwrap_or(f64::NAN)
            }
            MaxMessages::Text(_) => f64::NAN,
        };
        if number.fract() != 0.0
            || !number.is_finite()
            || number.abs() > MAX_SAFE_INTEGER
            || number < 1.0
        {
            let shown = match raw {
                MaxMessages::Number(value) => jsx::stringify(value),
                MaxMessages::Text(text) => quote(text),
            };
            return Err(format!(
                "--max-messages must be a positive integer, got {shown}"
            ));
        }
        max_messages = Some(number);
    }

    // Chat Markers of the Host's other Agents: an exported kind's launch
    // match never takes their sessions.
    let rivals = |query: &RivalQuery| -> Rivals {
        let run_herdr_program =
            |herdr: &crate::herdr::HerdrCommand, args: &[&str]| run_herdr(herdr, args);
        match resolve_host_config(env, Path::new(home), &run_herdr_program) {
            Ok(config) => launch_rivals(
                &config.config_dir.to_string_lossy(),
                query,
                env,
                home,
                &run_program,
            ),
            Err(_) => Rivals {
                claimed: Default::default(),
                launches: Vec::new(),
            },
        }
    };
    let chat = read_chat(&ReadChatArgs {
        kind,
        session_kind,
        session_value,
        cwd: input.cwd.as_deref(),
        launched_at,
        launch_rivals: Some(&rivals),
        status: input.status.as_deref(),
        after: input.after.as_deref(),
        max_messages,
        env,
        home,
    });
    Ok(format_ndjson(&chat))
}

/// `JSON.stringify(text)`.
fn quote(text: &str) -> String {
    let mut out = String::new();
    jsx::write_json_string(text, &mut out);
    out
}

/// The request object from stdin. Each known key is a string or null/absent,
/// except `max_messages`, a number; unknown keys are ignored. A terminal on
/// stdin is refused instead of waiting for Ctrl-D.
fn read_request(io: &mut Io<'_>) -> Result<Input, String> {
    if io.stdin_is_tty {
        return Err("--request -: pipe the request JSON on stdin".into());
    }
    let mut bytes = Vec::new();
    let _ = io.stdin.read_to_end(&mut bytes);
    let text = String::from_utf8_lossy(&bytes);
    let Some(request) = jsx::parse_json(&text) else {
        let message =
            jsx::json_syntax_error(&text).unwrap_or_else(|| "Unexpected token in JSON".into());
        return Err(format!("--request: stdin is not JSON ({message})"));
    };
    if !request.is_object() {
        return Err("--request: stdin must be one JSON object".into());
    }
    let field = |key: &str| -> Result<Option<&Value>, String> {
        let value = jsx::field(&request, key);
        if value.is_null() {
            return Ok(None);
        }
        let right_type = if key == "max_messages" {
            value.is_number()
        } else {
            value.is_string()
        };
        if !right_type {
            let flag = REQUEST_KEYS
                .iter()
                .find(|(name, _)| *name == key)
                .map_or("", |(_, flag)| *flag);
            return Err(format!(
                "--request: {key} ({flag}) has the wrong type: {}",
                jsx::stringify(value)
            ));
        }
        Ok(Some(value))
    };
    let text_field = |key: &str| -> Result<Option<String>, String> {
        Ok(field(key)?.and_then(Value::as_str).map(str::to_owned))
    };
    Ok(Input {
        kind: text_field("kind")?,
        session_kind: text_field("session_kind")?,
        session_value: text_field("session_value")?,
        cwd: text_field("cwd")?,
        launched_at: text_field("launched_at")?,
        status: text_field("status")?,
        after: text_field("after")?,
        max_messages: field("max_messages")?.map(|value| MaxMessages::Number(value.clone())),
    })
}

/// A token of Node's `argsToTokens`, for this command's options (none has a
/// short form, so every short option is unknown).
enum Token {
    Option {
        name: String,
        raw_name: String,
        value: Option<String>,
        /// The value came with the option (`--kind=x`), not from the next arg.
        inline_value: bool,
    },
    Positional(String),
}

fn units(text: &str) -> Vec<u16> {
    text.encode_utf16().collect()
}

fn from_units(units: &[u16]) -> String {
    String::from_utf16_lossy(units)
}

fn tokenize(args: &[String]) -> Vec<Token> {
    let mut tokens = Vec::new();
    let mut index = 0;
    while index < args.len() {
        let arg = &args[index];
        index += 1;
        if arg == "--" {
            tokens.extend(args[index..].iter().cloned().map(Token::Positional));
            break;
        }
        let u = units(arg);
        let dash = u16::from(b'-');
        if u.len() >= 2 && u[0] == dash && u[1] != dash {
            // `-f`, or a group `-fXzy` expanded to `-f -X -z -y`: no short
            // option exists, so the first one is the unknown option raised.
            let short = from_units(&u[1..2]);
            tokens.push(Token::Option {
                name: short.clone(),
                raw_name: format!("-{short}"),
                value: None,
                inline_value: false,
            });
            continue;
        }
        if u.len() > 2 && u[0] == dash && u[1] == dash {
            // `includes('=', 3)`
            if u[3..].contains(&u16::from(b'=')) {
                let equal = u.iter().position(|&c| c == u16::from(b'=')).unwrap_or(2);
                let name = from_units(&u[2..equal]);
                tokens.push(Token::Option {
                    raw_name: format!("--{name}"),
                    name,
                    value: Some(from_units(&u[equal + 1..])),
                    inline_value: true,
                });
            } else {
                let name = from_units(&u[2..]);
                let mut value = None;
                if OPTIONS.contains(&name.as_str()) && index < args.len() {
                    value = Some(args[index].clone());
                    index += 1;
                }
                tokens.push(Token::Option {
                    name,
                    raw_name: arg.clone(),
                    inline_value: false,
                    value,
                });
            }
            continue;
        }
        tokens.push(Token::Positional(arg.clone()));
    }
    tokens
}

/// `parseArgs({options, strict: true, allowPositionals: false}).values` as
/// (name, value) pairs in first-seen order, the last value of a repeated
/// option winning; or the error message Node throws.
fn parse_args(args: &[String]) -> Result<Vec<(String, String)>, String> {
    let mut values: Vec<(String, String)> = Vec::new();
    for token in tokenize(args) {
        match token {
            Token::Option {
                name,
                raw_name,
                value,
                inline_value,
            } => {
                if !OPTIONS.contains(&name.as_str()) {
                    return Err(format!("Unknown option '{raw_name}'"));
                }
                let Some(value) = value else {
                    return Err(format!("Option '--{name} <value>' argument missing"));
                };
                // isOptionLikeValue: longer than one unit and starts with `-`.
                if !inline_value && value.starts_with('-') && jsx::utf16_len(&value) > 1 {
                    return Err(format!(
                        "Option '{raw_name}' argument is ambiguous.\nDid you forget to specify the option argument for '{raw_name}'?\nTo specify an option argument starting with a dash use '{raw_name}=-XYZ'."
                    ));
                }
                match values.iter_mut().find(|(key, _)| *key == name) {
                    Some(slot) => slot.1 = value,
                    None => values.push((name, value)),
                }
            }
            Token::Positional(value) => {
                return Err(format!(
                    "Unexpected argument '{value}'. This command does not take positional arguments"
                ));
            }
        }
    }
    Ok(values)
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Outcome {
        code: i32,
        stdout: String,
        stderr: String,
    }

    fn run_with(args: &[&str], stdin: &str, tty: bool) -> Outcome {
        let args: Vec<String> = args.iter().map(|a| a.to_string()).collect();
        let env = Env::from_pairs([("HOME", "/nonexistent-home")]);
        let (mut out, mut err) = (Vec::new(), Vec::new());
        let mut input = stdin.as_bytes();
        let code = run(
            &args,
            &env,
            "/nonexistent-home",
            &mut Io {
                stdin: &mut input,
                stdin_is_tty: tty,
                stdout: &mut out,
                stderr: &mut err,
            },
        );
        Outcome {
            code,
            stdout: String::from_utf8_lossy(&out).into_owned(),
            stderr: String::from_utf8_lossy(&err).into_owned(),
        }
    }

    /// The run must end as `fail(message)`: exit 2, nothing on stdout, the
    /// message and the usage on stderr.
    fn assert_fails(args: &[&str], stdin: &str, message: &str) {
        let result = run_with(args, stdin, false);
        assert_eq!(result.code, 2, "{args:?} {stdin}: {}", result.stderr);
        assert_eq!(result.stdout, "", "{args:?} {stdin}");
        assert_eq!(
            result.stderr,
            format!("chat-read: {message}\n{USAGE}"),
            "{args:?} {stdin}"
        );
    }

    fn assert_fails_with(args: &[&str], message: &str) {
        assert_fails(args, "", message);
    }

    fn strings(args: &[&str]) -> Vec<String> {
        args.iter().map(|a| a.to_string()).collect()
    }

    // MARK: parseArgs

    #[test]
    fn unknown_options_name_the_option_as_written() {
        assert_fails_with(&["--bogus"], "Unknown option '--bogus'");
        assert_fails_with(&["--bogus=1"], "Unknown option '--bogus'");
        assert_fails_with(&["--bogus", "x"], "Unknown option '--bogus'");
        assert_fails_with(&["--KIND", "x"], "Unknown option '--KIND'");
        assert_fails_with(&["--ki", "x"], "Unknown option '--ki'");
        assert_fails_with(&["--__proto__", "x"], "Unknown option '--__proto__'");
        assert_fails_with(&["--constructor=x"], "Unknown option '--constructor'");
        assert_fails_with(&["--=x"], "Unknown option '--=x'");
        assert_fails_with(&["--=x=y"], "Unknown option '--'");
        assert_fails_with(&["---kind", "x"], "Unknown option '---kind'");
        assert_fails_with(&["---kind=x"], "Unknown option '---kind'");
        assert_fails_with(&["--a=b"], "Unknown option '--a'");
    }

    #[test]
    fn every_short_form_is_an_unknown_option_and_a_group_fails_at_its_first_unit() {
        assert_fails_with(&["-k"], "Unknown option '-k'");
        assert_fails_with(&["-abc"], "Unknown option '-a'");
        assert_fails_with(&["-kx"], "Unknown option '-k'");
        assert_fails_with(&["-k=x"], "Unknown option '-k'");
        assert_fails_with(&["-é"], "Unknown option '-é'");
        // `-😀` expands to its two UTF-16 units; a lone surrogate prints as U+FFFD.
        assert_fails_with(&["-😀"], "Unknown option '-\u{fffd}'");
    }

    #[test]
    fn a_positional_is_refused_wherever_it_stands() {
        let message = |value: &str| {
            format!(
                "Unexpected argument '{value}'. This command does not take positional arguments"
            )
        };
        assert_fails_with(&["foo"], &message("foo"));
        assert_fails_with(&["--kind", "nope", "foo"], &message("foo"));
        assert_fails_with(&["foo", "--kind", "nope"], &message("foo"));
        assert_fails_with(&["-", "x"], &message("-"));
        // Everything after a bare `--` is positional, the first one fails.
        assert_fails_with(&["--", "--kind", "nope"], &message("--kind"));
        // An unknown option before the positional fails first.
        assert_fails_with(&["--bogus", "--", "foo"], "Unknown option '--bogus'");
    }

    #[test]
    fn an_option_without_a_value_or_with_an_option_like_one_is_refused() {
        assert_fails_with(&["--kind"], "Option '--kind <value>' argument missing");
        assert_fails_with(
            &["--request"],
            "Option '--request <value>' argument missing",
        );
        assert_fails_with(
            &["--max-messages"],
            "Option '--max-messages <value>' argument missing",
        );
        let ambiguous = |name: &str| {
            format!(
                "Option '--{name}' argument is ambiguous.\nDid you forget to specify the option argument for '--{name}'?\nTo specify an option argument starting with a dash use '--{name}=-XYZ'."
            )
        };
        assert_fails_with(&["--kind", "--cwd"], &ambiguous("kind"));
        assert_fails_with(&["--kind", "--"], &ambiguous("kind"));
        assert_fails_with(&["--kind", "-x"], &ambiguous("kind"));
        assert_fails_with(&["--request", "-x"], &ambiguous("request"));
        assert_fails_with(&["--max-messages", "-5"], &ambiguous("max-messages"));
    }

    #[test]
    fn a_value_may_follow_in_the_next_argument_or_after_an_equals_sign() {
        let values = parse_args(&strings(&[
            "--kind",
            "a",
            "--cwd=/x",
            "--after=",
            "--status",
            "-",
            "--kind=-x=y",
        ]))
        .unwrap();
        let pairs: Vec<(&str, &str)> = values
            .iter()
            .map(|(k, v)| (k.as_str(), v.as_str()))
            .collect();
        // A repeated option keeps its first position and its last value.
        assert_eq!(
            pairs,
            [
                ("kind", "-x=y"),
                ("cwd", "/x"),
                ("after", ""),
                ("status", "-")
            ]
        );
        assert!(parse_args(&[]).unwrap().is_empty());
        // A lone `--` ends the options and is no error.
        assert!(parse_args(&strings(&["--"])).unwrap().is_empty());
        assert!(
            parse_args(&strings(&["--kind", "nope", "--"]))
                .unwrap()
                .len()
                == 1
        );
    }

    // MARK: --request -

    #[test]
    fn request_takes_only_a_dash_and_no_other_flag() {
        assert_fails_with(&["--request", "x"], "--request takes only -, got \"x\"");
        assert_fails_with(&["--request=x"], "--request takes only -, got \"x\"");
        assert_fails_with(&["--request=-x"], "--request takes only -, got \"-x\"");
        assert_fails(
            &["--request", "-", "--kind", "nope"],
            "{}",
            "--request - takes no other flags",
        );
        assert_fails(
            &["--kind", "nope", "--request", "-"],
            "{}",
            "--request - takes no other flags",
        );
        // The same flag twice is one key.
        assert_fails(
            &["--request", "-", "--request", "-"],
            "",
            "--request: stdin is not JSON (Unexpected end of JSON input)",
        );
    }

    #[test]
    fn a_terminal_on_stdin_is_refused() {
        let result = run_with(&["--request", "-"], "", true);
        assert_eq!(result.code, 2);
        assert_eq!(
            result.stderr,
            format!("chat-read: --request -: pipe the request JSON on stdin\n{USAGE}")
        );
    }

    #[test]
    fn a_request_that_is_not_json_reports_v8s_parse_error() {
        let not_json = |text: &str, detail: &str| {
            assert_fails(
                &["--request", "-"],
                text,
                &format!("--request: stdin is not JSON ({detail})"),
            )
        };
        not_json("", "Unexpected end of JSON input");
        not_json(
            "{",
            "Expected property name or '}' in JSON at position 1 (line 1 column 2)",
        );
        not_json("{\"kind\":", "Unexpected end of JSON input");
        not_json(
            "{\"a\":1,}",
            "Expected double-quoted property name in JSON at position 7 (line 1 column 8)",
        );
        not_json(
            "{\"a\":1 \"b\":2}",
            "Expected ',' or '}' after property value in JSON at position 7 (line 1 column 8)",
        );
        not_json(
            "[1 2]",
            "Expected ',' or ']' after array element in JSON at position 3 (line 1 column 4)",
        );
        not_json(
            "{\"a\" 1}",
            "Expected ':' after property name in JSON at position 5 (line 1 column 6)",
        );
        not_json(
            "{}x",
            "Unexpected non-whitespace character after JSON at position 2 (line 1 column 3)",
        );
        not_json(
            "not json",
            "Unexpected token 'o', \"not json\" is not valid JSON",
        );
        not_json("undefined", "\"undefined\" is not valid JSON");
        not_json(
            "{\"a\":\"abc",
            "Unterminated string in JSON at position 9 (line 1 column 10)",
        );
        not_json(
            "\"a\nb\"",
            "Bad control character in string literal in JSON at position 2 (line 1 column 3)",
        );
        not_json(
            "\"\\x\"",
            "Bad escaped character in JSON at position 2 (line 1 column 3)",
        );
        not_json(
            "\"\\u12G4\"",
            "Bad Unicode escape in JSON at position 5 (line 1 column 6)",
        );
        not_json(
            "01",
            "Unexpected number in JSON at position 1 (line 1 column 2)",
        );
        not_json(
            "-",
            "No number after minus sign in JSON at position 1 (line 1 column 2)",
        );
        not_json(
            "1.",
            "Unterminated fractional number in JSON at position 2 (line 1 column 3)",
        );
        not_json(
            "1e+",
            "Exponent part is missing a number in JSON at position 3 (line 1 column 4)",
        );
        not_json(
            "{\r\n\r\n\"a\":\r\n x}",
            "Unexpected token 'x', \"{\r\n\r\n\"a\":\r\n x}\" is not valid JSON",
        );
        not_json(
            "[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,x,1,2,3,4,5,6,7,8,9,10,11,12,13,14]",
            "Unexpected token 'x', ...\",13,14,15,x,1,2,3,4,\"... is not valid JSON",
        );
        not_json(
            "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
            "Unexpected token 'x', \"xxxxxxxxxx\"... is not valid JSON",
        );
        not_json(
            "[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,2,1,3,x",
            "Unexpected token 'x', ...\",19,2,1,3,x\" is not valid JSON",
        );
    }

    #[test]
    fn a_request_that_is_not_one_object_is_refused() {
        for text in ["[1]", "null", "5", "\"s\"", "true", "false", "0", "\"\""] {
            assert_fails(
                &["--request", "-"],
                text,
                "--request: stdin must be one JSON object",
            );
        }
    }

    #[test]
    fn a_known_key_of_the_wrong_type_names_its_flag_and_value() {
        let wrong = |key: &str, flag: &str, shown: &str| {
            format!("--request: {key} ({flag}) has the wrong type: {shown}")
        };
        let dash = ["--request", "-"];
        assert_fails(&dash, r#"{"kind":5}"#, &wrong("kind", "--kind", "5"));
        assert_fails(
            &dash,
            r#"{"kind":"nope","session_kind":true}"#,
            &wrong("session_kind", "--session-kind", "true"),
        );
        assert_fails(
            &dash,
            r#"{"kind":"nope","session_value":[1]}"#,
            &wrong("session_value", "--session-value", "[1]"),
        );
        assert_fails(
            &dash,
            r#"{"kind":"nope","cwd":{"a":1}}"#,
            &wrong("cwd", "--cwd", r#"{"a":1}"#),
        );
        assert_fails(
            &dash,
            r#"{"kind":"nope","launched_at":1.5}"#,
            &wrong("launched_at", "--launched-at", "1.5"),
        );
        assert_fails(
            &dash,
            r#"{"kind":"nope","status":false}"#,
            &wrong("status", "--status", "false"),
        );
        assert_fails(
            &dash,
            r#"{"kind":"nope","after":1e21}"#,
            &wrong("after", "--after", "1e+21"),
        );
        assert_fails(
            &dash,
            r#"{"kind":"nope","max_messages":"5"}"#,
            &wrong("max_messages", "--max-messages", "\"5\""),
        );
        assert_fails(
            &dash,
            r#"{"kind":"nope","max_messages":true}"#,
            &wrong("max_messages", "--max-messages", "true"),
        );
        assert_fails(
            &dash,
            r#"{"kind":"nope","max_messages":{"a":"é"}}"#,
            &wrong("max_messages", "--max-messages", r#"{"a":"é"}"#),
        );
        // The first key in the order kind, session_kind, ... wins.
        assert_fails(
            &dash,
            r#"{"cwd":2,"kind":1}"#,
            &wrong("kind", "--kind", "1"),
        );
    }

    // MARK: checks shared by flags and request

    #[test]
    fn a_kind_is_required() {
        assert_fails_with(&[], "--kind is required");
        assert_fails_with(&["--kind", ""], "--kind is required");
        assert_fails_with(&["--kind="], "--kind is required");
        assert_fails_with(&["--cwd", "/x"], "--kind is required");
        assert_fails(&["--request", "-"], "{}", "--kind is required");
        assert_fails(
            &["--request", "-"],
            r#"{"kind":null}"#,
            "--kind is required",
        );
        assert_fails(&["--request", "-"], r#"{"kind":""}"#, "--kind is required");
    }

    #[test]
    fn a_session_is_a_kind_and_a_non_empty_value_together() {
        let bad_kind = |kind: &str| format!("--session-kind must be id or path, got \"{kind}\"");
        assert_fails_with(
            &[
                "--kind",
                "nope",
                "--session-kind",
                "x",
                "--session-value",
                "v",
            ],
            &bad_kind("x"),
        );
        assert_fails(
            &["--request", "-"],
            r#"{"kind":"nope","session_kind":"uuid","session_value":"v"}"#,
            &bad_kind("uuid"),
        );
        let together = "--session-kind and --session-value go together";
        assert_fails_with(&["--kind", "nope", "--session-kind", "id"], together);
        assert_fails_with(&["--kind", "nope", "--session-value", "v"], together);
        assert_fails_with(
            &[
                "--kind",
                "nope",
                "--session-kind",
                "id",
                "--session-value",
                "",
            ],
            together,
        );
        assert_fails(
            &["--request", "-"],
            r#"{"kind":"nope","session_kind":"id"}"#,
            together,
        );
        assert_fails(
            &["--request", "-"],
            r#"{"kind":"nope","session_value":"v"}"#,
            together,
        );
        // The kind check comes first, even with the value missing.
        assert_fails(
            &["--request", "-"],
            r#"{"kind":"nope","session_kind":"x"}"#,
            &bad_kind("x"),
        );
    }

    #[test]
    fn launched_at_must_be_a_time_date_parse_reads() {
        let bad = |text: &str| format!("--launched-at is not an ISO 8601 time: \"{text}\"");
        assert_fails_with(
            &["--kind", "nope", "--launched-at", "nonsense"],
            &bad("nonsense"),
        );
        assert_fails_with(&["--kind", "nope", "--launched-at", ""], &bad(""));
        assert_fails(
            &["--request", "-"],
            r#"{"kind":"nope","launched_at":"tomorrow"}"#,
            &bad("tomorrow"),
        );
        assert_fails_with(
            &[
                "--kind",
                "nope",
                "--session-kind",
                "x",
                "--session-value",
                "v",
                "--launched-at",
                "bad",
            ],
            "--session-kind must be id or path, got \"x\"",
        );
    }

    #[test]
    fn max_messages_must_be_a_positive_safe_integer() {
        let bad = |shown: &str| format!("--max-messages must be a positive integer, got {shown}");
        for text in [
            "0",
            "abc",
            "1.5",
            "9007199254740992",
            "1e3",
            "",
            " 5",
            "5 ",
            "٣",
            "+5",
            "0x10",
            "99999999999999999999999",
        ] {
            assert_fails_with(
                &["--kind", "nope", "--max-messages", text],
                &bad(&format!("\"{text}\"")),
            );
        }
        assert_fails_with(&["--kind", "nope", "--max-messages=-5"], &bad("\"-5\""));
        let dash = ["--request", "-"];
        for (json, shown) in [
            ("0", "0"),
            ("-1", "-1"),
            ("1.5", "1.5"),
            ("1e21", "1e+21"),
            ("9007199254740993", "9007199254740992"),
            ("0.5", "0.5"),
        ] {
            assert_fails(
                &dash,
                &format!(r#"{{"kind":"nope","max_messages":{json}}}"#),
                &bad(shown),
            );
        }
        // Order of checks: session, launched_at, then max_messages.
        assert_fails(
            &dash,
            r#"{"kind":"nope","launched_at":"bad","max_messages":0}"#,
            "--launched-at is not an ISO 8601 time: \"bad\"",
        );
    }

    // MARK: reading (through chat::transcript::read_chat)

    fn header_status(stdout: &str) -> String {
        let header: Value = serde_json::from_str(stdout.lines().next().unwrap()).unwrap();
        header["status"].as_str().unwrap().to_string()
    }

    #[test]
    fn a_kind_without_a_reader_answers_an_unsupported_header_and_exits_0() {
        for args in [
            &["--kind", "nope"][..],
            &["--kind=nope"],
            &["--kind", "a", "--kind", "nope"],
            &["--kind", "nope", "--"],
            &["--kind", "nope", "--max-messages", "007"],
            &["--kind", "nope", "--max-messages", "9007199254740991"],
            &[
                "--kind",
                "nope",
                "--launched-at",
                "2026-10-12T10:00:00Z",
                "--session-kind",
                "path",
                "--session-value",
                "/x",
            ],
            &["--kind", "-"],
        ] {
            let result = run_with(args, "", false);
            assert_eq!(result.code, 0, "{args:?}: {}", result.stderr);
            assert_eq!(result.stderr, "");
            assert_eq!(header_status(&result.stdout), "unsupported", "{args:?}");
        }
        let request = r#"{"kind":"nope","session_kind":null,"cwd":null,"extra":1,"max_messages":1e3,"__proto__":5}"#;
        let result = run_with(&["--request", "-"], request, false);
        assert_eq!(result.code, 0, "{}", result.stderr);
        assert_eq!(header_status(&result.stdout), "unsupported");
    }
}
