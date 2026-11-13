//! Hermes: the marked `hooks:` block of config.yaml and what the allowlist
//! needs to know about each command (agent-hooks.js).

use std::os::unix::fs::MetadataExt;
use std::path::Path;

use crate::js_date::iso_string;
use crate::js_json::quote;
use crate::jsx;

use super::entries::{HERMES_ENTRIES, HOOK_TIMEOUT_SEC};
use super::groups::hook_command;

pub const HERMES_BLOCK_BEGIN: &str = "# >>> waycar hooks: managed by `waycar hooks install`; `waycar hooks uninstall` removes this block";
pub const HERMES_BLOCK_END: &str = "# <<< waycar hooks";

/// Our marked `hooks:` block for config.yaml, ending in a newline.
pub fn hermes_block(plugin_root: &Path) -> String {
    let mut lines = vec![HERMES_BLOCK_BEGIN.to_string(), "hooks:".to_string()];
    for (event, _, status) in HERMES_ENTRIES {
        // A JSON string is a valid YAML double-quoted scalar.
        let command = quote(&hook_command(plugin_root, "hermes", status, event));
        lines.push(format!("  {event}:"));
        lines.push(format!("    - command: {command}"));
        lines.push(format!("      timeout: {HOOK_TIMEOUT_SEC}"));
    }
    lines.push(HERMES_BLOCK_END.to_string());
    lines.push(String::new());
    lines.join("\n")
}

/// config.yaml split into our block (or none) and the rest. Install puts one
/// blank line before the block; the split takes it out again, so uninstall
/// restores the file as it was.
pub fn split_hermes_config(text: Option<&str>) -> (Option<String>, String) {
    let source = text.unwrap_or("");
    let lines: Vec<&str> = source.split('\n').collect();
    let Some(begin) = lines.iter().position(|line| *line == HERMES_BLOCK_BEGIN) else {
        return (None, source.to_string());
    };
    let Some(end) = lines[begin..]
        .iter()
        .position(|line| *line == HERMES_BLOCK_END)
        .map(|at| begin + at)
    else {
        return (None, source.to_string());
    };
    let mut before = lines[..begin].to_vec();
    if before.len() >= 2 && before.last() == Some(&"") {
        before.pop();
    }
    let block = format!("{}\n", lines[begin..=end].join("\n"));
    before.extend_from_slice(&lines[end + 1..]);
    (Some(block), before.join("\n"))
}

/// `/^hooks[ \t]*:/m`: a top-level `hooks:` key. `^` of a multiline JS regex
/// also matches after U+2028 and U+2029, and after a lone `\r`.
pub fn has_top_level_hooks(text: &str) -> bool {
    let mut starts = vec![0];
    for (at, c) in text.char_indices() {
        if matches!(c, '\n' | '\r' | '\u{2028}' | '\u{2029}') {
            starts.push(at + c.len_utf8());
        }
    }
    starts.into_iter().any(|start| {
        text[start..]
            .strip_prefix("hooks")
            .is_some_and(|rest| rest.trim_start_matches([' ', '\t']).starts_with(':'))
    })
}

/// The words of a shell command as Hermes reads them: `'quoted'` runs (with
/// `'\''` inside) and bare runs of non-white-space, `/'((?:[^']|'\\'')*)'|(\S+)/g`.
fn shell_words(command: &str) -> Vec<String> {
    let chars: Vec<char> = command.chars().collect();
    let mut words = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        if chars[i] == '\''
            && let Some(close) = quoted_end(&chars, i + 1)
        {
            words.push(chars[i + 1..close].iter().collect::<String>());
            i = close + 1;
        } else if !jsx::is_js_space(chars[i]) {
            let end = chars[i..]
                .iter()
                .position(|c| jsx::is_js_space(*c))
                .map_or(chars.len(), |at| i + at);
            words.push(chars[i..end].iter().collect());
            i = end;
        } else {
            i += 1;
        }
    }
    words
        .into_iter()
        .map(|word| word.replace("'\\''", "'"))
        .collect()
}

/// Where the closing quote of a quoted run starting at `start` is, as the
/// backtracking `(?:[^']|'\\'')*'` finds it: `'\''` is taken as content while
/// it can be, and given back (ending the run at its first quote) when the
/// input ends without a closing quote.
fn quoted_end(chars: &[char], start: usize) -> Option<usize> {
    let mut at = start;
    let mut last_escape = None;
    while at < chars.len() {
        if chars[at] != '\'' {
            at += 1;
        } else if chars[at + 1..].starts_with(&['\\', '\'', '\'']) {
            last_escape = Some(at);
            at += 4;
        } else {
            return Some(at);
        }
    }
    last_escape
}

const SCRIPT_EXTENSIONS: [&str; 13] = [
    "sh", "bash", "zsh", "fish", "py", "pyw", "rb", "pl", "lua", "js", "mjs", "cjs", "ts",
];

fn is_script(word: &str) -> bool {
    // `/\.(sh|bash|…|ts)$/i`: ASCII case folding only, as JS does without `u`.
    word.rsplit_once('.').is_some_and(|(_, ext)| {
        SCRIPT_EXTENSIONS
            .iter()
            .any(|known| ext.eq_ignore_ascii_case(known))
    })
}

/// Hermes's own ISO form of a script's mtime (`script_mtime_iso`), or `None`.
pub fn script_mtime(command: &str) -> Option<String> {
    let words = shell_words(command);
    let path = words
        .iter()
        .find(|word| is_script(word))
        .or_else(|| words.iter().find(|word| word.contains('/')))?;
    let meta = std::fs::metadata(path).ok()?;
    let nanos = i128::from(meta.mtime()) * 1_000_000_000 + i128::from(meta.mtime_nsec());
    let micros = (nanos + 500) / 1000;
    let ms = i64::try_from(micros / 1000).ok()?;
    let seconds = &iso_string(ms)?[..19];
    let fraction = micros % 1_000_000;
    Some(if fraction == 0 {
        format!("{seconds}Z")
    } else {
        format!("{seconds}.{:0>6}Z", fraction.to_string())
    })
}

#[cfg(test)]
mod tests {
    use std::ffi::CString;
    use std::fs;

    use super::*;

    #[test]
    fn the_block_is_marked_and_quotes_each_command_as_json() {
        let block = hermes_block(Path::new("/p"));
        assert!(block.starts_with(&format!("{HERMES_BLOCK_BEGIN}\nhooks:\n  pre_llm_call:\n")));
        assert!(block.ends_with(&format!("{HERMES_BLOCK_END}\n")));
        assert!(block.contains(
            "  pre_llm_call:\n    - command: \"'/p/bin/waycar' hook-session hermes pre_llm_call\"\n      timeout: 10\n"
        ));
        assert!(block.contains(
            "  on_human_input_request:\n    - command: \"'/p/bin/waycar-hook' hermes blocked\"\n"
        ));
        // A quote in the root is escaped for YAML (a JSON string) on top of the shell.
        let odd = hermes_block(Path::new("/it's \"q\"/x"));
        assert!(
            odd.contains(r#"command: "'/it'\\''s \"q\"/x/bin/waycar-hook' hermes blocked""#),
            "{odd}"
        );
    }

    #[test]
    fn splitting_takes_the_blank_line_install_added_back_out() {
        let block = hermes_block(Path::new("/p"));
        let (found, rest) = split_hermes_config(Some(&format!("model: x\n\n{block}")));
        assert_eq!(found.as_deref(), Some(block.as_str()));
        assert_eq!(rest, "model: x\n");
        let (found, rest) = split_hermes_config(Some(&format!("{block}tail: 1\n")));
        assert_eq!(found.as_deref(), Some(block.as_str()));
        assert_eq!(rest, "tail: 1\n");
        // A begin marker without its end, and no marker, split nothing.
        let broken = format!("a: 1\n{HERMES_BLOCK_BEGIN}\nhooks:\n");
        assert_eq!(split_hermes_config(Some(&broken)), (None, broken.clone()));
        assert_eq!(split_hermes_config(None), (None, String::new()));
        // One line before the block is not a blank separator.
        let (_, rest) = split_hermes_config(Some(&format!("\n{block}")));
        assert_eq!(rest, "\n");
        let (_, rest) = split_hermes_config(Some(&format!("\n\n{block}")));
        assert_eq!(rest, "\n");
    }

    #[test]
    fn a_top_level_hooks_key_is_found_the_way_a_multiline_js_regex_finds_it() {
        for yes in [
            "hooks:",
            "a: 1\nhooks :\n",
            "a: 1\r\nhooks:\r\n",
            "x\u{2028}hooks\t:",
            "hooks  : []",
        ] {
            assert!(has_top_level_hooks(yes), "{yes:?}");
        }
        for no in [
            "",
            "# hooks:",
            "  hooks:",
            "a:\n  hooks:\n",
            "hooksx:",
            "hooks",
            "ahooks:",
            "hooks x:",
        ] {
            assert!(!has_top_level_hooks(no), "{no:?}");
        }
    }

    #[test]
    fn shell_words_read_quoted_runs_and_bare_runs() {
        assert_eq!(
            shell_words(r"'/a b/node.sh' '/it'\''s/x.js' hermes  pre_llm_call"),
            ["/a b/node.sh", "/it's/x.js", "hermes", "pre_llm_call"]
        );
        // An unclosed quote reads as a bare run; an escape with no closing
        // quote gives its first quote back, and the rest is a bare run.
        assert_eq!(shell_words("'abc def"), ["'abc", "def"]);
        assert_eq!(shell_words(r"'a'\''b"), ["a", r"\''b"]);
        assert_eq!(shell_words("\t\n x\u{a0}y\u{3000}z "), ["x", "y", "z"]);
        assert_eq!(shell_words(""), Vec::<String>::new());
    }

    #[test]
    fn the_script_is_the_first_word_with_a_script_extension_else_the_first_path() {
        assert!(
            is_script("/x/node.sh")
                && is_script("a.PY")
                && is_script("a.b.Ts")
                && is_script("x.mjs")
        );
        assert!(
            !is_script("/x/waycar-hook")
                && !is_script("sh")
                && !is_script("a.shx")
                && !is_script("a.ſh")
        );
    }

    fn set_mtime(path: &Path, secs: i64, nanos: i64) {
        let times = [
            libc::timespec {
                tv_sec: secs,
                tv_nsec: nanos,
            },
            libc::timespec {
                tv_sec: secs,
                tv_nsec: nanos,
            },
        ];
        let c_path = CString::new(path.as_os_str().as_encoded_bytes()).unwrap();
        // SAFETY: the path and the two timespecs are valid for the call.
        assert_eq!(
            unsafe { libc::utimensat(libc::AT_FDCWD, c_path.as_ptr(), times.as_ptr(), 0) },
            0
        );
    }

    #[test]
    fn the_mtime_has_microseconds_unless_it_is_whole_seconds() {
        let dir = std::env::temp_dir().join(format!("wc-hermes-mtime-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let script = dir.join("hook-session.js");
        fs::write(&script, "").unwrap();
        let command = format!("'{}' hermes x", script.display());
        // 2026-01-02T03:04:05Z
        set_mtime(&script, 1_767_323_045, 0);
        assert_eq!(
            script_mtime(&command).as_deref(),
            Some("2026-01-02T03:04:05Z")
        );
        // Nanoseconds round to the nearest microsecond.
        set_mtime(&script, 1_767_323_045, 123_456_789);
        assert_eq!(
            script_mtime(&command).as_deref(),
            Some("2026-01-02T03:04:05.123457Z")
        );
        set_mtime(&script, 1_767_323_045, 123_456_400);
        assert_eq!(
            script_mtime(&command).as_deref(),
            Some("2026-01-02T03:04:05.123456Z")
        );
        set_mtime(&script, 1_767_323_045, 999_999_700);
        assert_eq!(
            script_mtime(&command).as_deref(),
            Some("2026-01-02T03:04:06Z")
        );
        set_mtime(&script, 1_767_323_045, 1_000);
        assert_eq!(
            script_mtime(&command).as_deref(),
            Some("2026-01-02T03:04:05.000001Z")
        );
        // The first script wins over a later path; a path stands in for none.
        let other = dir.join("waycar-hook");
        fs::write(&other, "").unwrap();
        let command = format!("'{}' '{}' hermes x", other.display(), script.display());
        assert_eq!(
            script_mtime(&command).as_deref(),
            Some("2026-01-02T03:04:05.000001Z")
        );
        set_mtime(&other, 1_767_323_045, 0);
        assert_eq!(
            script_mtime(&format!("'{}' hermes blocked", other.display())).as_deref(),
            Some("2026-01-02T03:04:05Z")
        );
        // Nothing to stat is null.
        assert_eq!(script_mtime("hermes blocked"), None);
        assert_eq!(script_mtime("'/no/such/hook-session.js' hermes"), None);
        fs::remove_dir_all(&dir).unwrap();
    }
}
