//! Codex: the `[features] hooks = true` edit of config.toml and the trust
//! review state (agent-hooks.js).
//!
//! Codex skips hooks until the user trusts them in `/hooks`. This module
//! never writes that trust; it recomputes Codex's trust hash for each of our
//! entries so the report can say when config.toml holds no matching one.

use ring::digest::{SHA256, digest};

use crate::js_json::{Json, Obj};
use crate::jsx;

use super::entries::{CODEX_SHORT_EVENTS, CODEX_SHORT_TIMEOUT_SEC};
use super::groups::is_our_handler;
use super::toml_doc::{FeatureFlag, TomlDoc};

/// What [`enable_codex_hooks_feature`] decided.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FeatureEdit {
    pub text: String,
    pub changed: bool,
    /// The user's explicit `hooks = false`, left alone.
    pub disabled: bool,
}

/// `^[ \t]*\[[ \t]*features[ \t]*\][ \t]*(#.*)?\r?$` for one line (no `\n`).
fn is_features_header(line: &str) -> bool {
    let blank = |c: char| c == ' ' || c == '\t';
    let Some(rest) = line.trim_start_matches(blank).strip_prefix('[') else {
        return false;
    };
    let Some(rest) = rest
        .trim_start_matches(blank)
        .strip_prefix("features")
        .and_then(|rest| rest.trim_start_matches(blank).strip_prefix(']'))
    else {
        return false;
    };
    let mut rest = rest.trim_start_matches(blank);
    // `.` of a JS regex stops at a line terminator.
    if let Some(comment) = rest.strip_prefix('#') {
        let end = comment
            .find(['\r', '\u{2028}', '\u{2029}'])
            .unwrap_or(comment.len());
        rest = &comment[end..];
    }
    rest.is_empty() || rest == "\r"
}

/// `^[ \t]*\[`
fn starts_table(line: &str) -> bool {
    line.trim_start_matches([' ', '\t']).starts_with('[')
}

/// `^[ \t]*hooks[ \t]*=`
fn sets_hooks(line: &str) -> bool {
    line.trim_start_matches([' ', '\t'])
        .strip_prefix("hooks")
        .is_some_and(|rest| rest.trim_start_matches([' ', '\t']).starts_with('='))
}

/// config.toml text with `[features] hooks = true`, editing only the one line
/// it needs: an existing `hooks = …` line inside `[features]` is replaced,
/// else the key is added under the header, else a `[features]` table is
/// appended. The result must parse, set `features.hooks = true` and leave
/// every other value as it was; otherwise this fails and the caller writes
/// nothing. An explicit `hooks = false` is the user's opt-out: it is left
/// alone and reported as `disabled`.
pub fn enable_codex_hooks_feature(text: Option<&str>) -> Result<FeatureEdit, String> {
    let original = text.unwrap_or("");
    let before = TomlDoc::parse(original)?;
    let unchanged = |disabled| FeatureEdit {
        text: original.to_string(),
        changed: false,
        disabled,
    };
    match before.hooks_flag() {
        FeatureFlag::On => return Ok(unchanged(false)),
        FeatureFlag::Off => return Ok(unchanged(true)),
        FeatureFlag::Unset => {}
    }

    let lines: Vec<&str> = original.split('\n').collect();
    let edited = if let Some(header) = lines.iter().position(|line| is_features_header(line)) {
        let end = lines[header + 1..]
            .iter()
            .position(|line| starts_table(line))
            .map_or(lines.len(), |at| header + 1 + at);
        let existing = lines[header + 1..end]
            .iter()
            .position(|line| sets_hooks(line));
        let mut updated = lines.clone();
        match existing {
            Some(at) => updated[header + 1 + at] = "hooks = true",
            None => updated.insert(header + 1, "hooks = true"),
        }
        updated.join("\n")
    } else if !before.has_features() {
        let base = if original.is_empty() || original.ends_with('\n') {
            original.to_string()
        } else {
            format!("{original}\n")
        };
        let gap = if base.is_empty() { "" } else { "\n" };
        format!("{base}{gap}[features]\nhooks = true\n")
    } else {
        return Err("config.toml sets features without a [features] table; add `hooks = true` under [features] by hand".into());
    };

    let after = TomlDoc::parse(&edited).map_err(|message| {
        format!("could not add [features] hooks = true to config.toml ({message}); add it by hand")
    })?;
    if !after.same_as(&before.with_hooks_enabled()) {
        return Err("could not add [features] hooks = true to config.toml without changing other settings; add it by hand".into());
    }
    Ok(FeatureEdit {
        text: edited,
        changed: true,
        disabled: false,
    })
}

/// Whether config.toml explicitly turns Codex hooks off (`[features] hooks = false`).
pub fn is_codex_feature_off(text: Option<&str>) -> bool {
    TomlDoc::parse(text.unwrap_or("")).is_ok_and(|doc| doc.hooks_flag() == FeatureFlag::Off)
}

/// Whether `[features] hooks` is not off; a config.toml that does not parse
/// counts as off here (the status report's `featureOn`).
pub fn is_codex_feature_on(text: Option<&str>) -> bool {
    TomlDoc::parse(text.unwrap_or("")).is_ok_and(|doc| doc.hooks_flag() != FeatureFlag::Off)
}

/// `event.replace(/([a-z])([A-Z])/g, "$1_$2").toLowerCase()`
pub fn snake_case(event: &str) -> String {
    let chars: Vec<char> = event.chars().collect();
    let mut out = String::with_capacity(event.len() + 4);
    let mut i = 0;
    while i < chars.len() {
        match chars.get(i + 1) {
            Some(next) if chars[i].is_ascii_lowercase() && next.is_ascii_uppercase() => {
                out.push(chars[i]);
                out.push('_');
                out.push(*next);
                i += 2;
            }
            _ => {
                out.push(chars[i]);
                i += 1;
            }
        }
    }
    out.to_lowercase()
}

/// Keys sorted by UTF-16 code units, at every depth (`sortKeysDeep`).
fn sort_keys_deep(value: &Json) -> Json {
    match value {
        Json::Arr(items) => Json::Arr(items.iter().map(sort_keys_deep).collect()),
        Json::Obj(object) => {
            let mut keys: Vec<&str> = object.keys().collect();
            keys.sort_by(|a, b| a.encode_utf16().cmp(b.encode_utf16()));
            let mut sorted = Obj::new();
            for key in keys {
                if let Some(item) = object.get(key) {
                    sorted.set(key, sort_keys_deep(item));
                }
            }
            Json::Obj(sorted)
        }
        other => other.clone(),
    }
}

// MARK: - JavaScript number coercion, for `Math.max(handler.timeout ?? 600, 1)`

fn join_for_string(items: &[Json]) -> String {
    items
        .iter()
        .map(|item| match item {
            Json::Null => String::new(),
            Json::Bool(flag) => flag.to_string(),
            Json::Num(x) => jsx::number_to_string(*x),
            Json::Str(text) => text.clone(),
            Json::Arr(inner) => join_for_string(inner),
            Json::Obj(_) => "[object Object]".into(),
        })
        .collect::<Vec<_>>()
        .join(",")
}

/// `StringToNumber`: trimmed, empty is 0, `Infinity`, `0x`/`0o`/`0b`
/// integers and decimal literals; anything else is NaN.
fn string_to_number(text: &str) -> f64 {
    let text = jsx::trim(text);
    if text.is_empty() {
        return 0.0;
    }
    let radix_digits = |prefixes: [char; 2], radix: u32| {
        let rest = text.strip_prefix('0')?.strip_prefix(prefixes)?;
        if rest.is_empty() || !rest.chars().all(|c| c.is_digit(radix)) {
            return None;
        }
        Some(rest.chars().fold(0.0, |acc, c| {
            acc * f64::from(radix) + f64::from(c.to_digit(radix).unwrap_or(0))
        }))
    };
    if let Some(value) = radix_digits(['x', 'X'], 16)
        .or_else(|| radix_digits(['o', 'O'], 8))
        .or_else(|| radix_digits(['b', 'B'], 2))
    {
        return value;
    }
    let (sign, unsigned) = match text.as_bytes()[0] {
        b'-' => (-1.0, &text[1..]),
        b'+' => (1.0, &text[1..]),
        _ => (1.0, text),
    };
    if unsigned == "Infinity" {
        return sign * f64::INFINITY;
    }
    // StrDecimalLiteral: digits [. digits?] | . digits, then an optional exponent.
    let bytes = unsigned.as_bytes();
    let digits = |from: usize| {
        bytes[from..]
            .iter()
            .take_while(|b| b.is_ascii_digit())
            .count()
    };
    let int = digits(0);
    let mut at = int;
    let mut frac = 0;
    if bytes.get(at) == Some(&b'.') {
        frac = digits(at + 1);
        at += 1 + frac;
    }
    if int == 0 && frac == 0 {
        return f64::NAN;
    }
    if matches!(bytes.get(at), Some(b'e' | b'E')) {
        let mut exp = at + 1;
        if matches!(bytes.get(exp), Some(b'+' | b'-')) {
            exp += 1;
        }
        let exp_digits = digits(exp);
        if exp_digits == 0 {
            return f64::NAN;
        }
        at = exp + exp_digits;
    }
    if at != bytes.len() {
        return f64::NAN;
    }
    unsigned
        .parse::<f64>()
        .map_or(f64::NAN, |value| sign * value)
}

/// `Number(value)` of a JSON value (arrays and objects through their string form).
fn to_number(value: &Json) -> f64 {
    match value {
        Json::Null => 0.0,
        Json::Bool(flag) => f64::from(u8::from(*flag)),
        Json::Num(x) => *x,
        Json::Str(text) => string_to_number(text),
        Json::Arr(items) => string_to_number(&join_for_string(items)),
        Json::Obj(_) => f64::NAN,
    }
}

fn js_max(a: f64, b: f64) -> f64 {
    if a.is_nan() || b.is_nan() {
        f64::NAN
    } else {
        a.max(b)
    }
}

fn js_min(a: f64, b: f64) -> f64 {
    if a.is_nan() || b.is_nan() {
        f64::NAN
    } else {
        a.min(b)
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// Codex's trust hash for one command handler in a matcher group without a
/// matcher: SHA-256 over the key-sorted compact JSON of the normalized hook
/// identity (codex-rs hooks `hook_hash` + config `version_for_toml`).
pub fn codex_trust_hash(event: &str, handler: &Json) -> String {
    let configured = |default: f64| match handler.get("timeout") {
        None | Some(Json::Null) => default,
        Some(value) => to_number(value),
    };
    let timeout = if CODEX_SHORT_EVENTS.contains(&event) {
        js_min(
            js_max(configured(1.0), 1.0),
            f64::from(CODEX_SHORT_TIMEOUT_SEC),
        )
    } else {
        js_max(configured(600.0), 1.0)
    };
    let mut normalized = Obj::new();
    normalized.set("type", Json::str("command"));
    if let Some(command) = handler.get("command") {
        normalized.set("command", command.clone());
    }
    normalized.set("timeout", Json::Num(timeout));
    normalized.set(
        "async",
        Json::Bool(matches!(handler.get("async"), Some(Json::Bool(true)))),
    );
    if let Some(message @ Json::Str(_)) = handler.get("statusMessage") {
        normalized.set("statusMessage", message.clone());
    }
    let mut identity = Obj::new();
    identity.set("event_name", Json::Str(snake_case(event)));
    identity.set("hooks", Json::Arr(vec![Json::Obj(normalized)]));
    let canonical = sort_keys_deep(&Json::Obj(identity)).to_compact();
    format!(
        "sha256:{}",
        hex(digest(&SHA256, canonical.as_bytes()).as_ref())
    )
}

/// A trust key and the hash Codex should have recorded for it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TrustEntry {
    pub key: String,
    pub hash: String,
}

/// Trust keys and hashes of our handlers in a Codex hooks object:
/// `<hooks.json path>:<snake_event>:<group index>:<handler index>`.
pub fn codex_trust_entries(hooks: Option<&Json>, hooks_path: &str) -> Vec<TrustEntry> {
    let mut entries = Vec::new();
    let Some(Json::Obj(events)) = hooks else {
        return entries;
    };
    for (event, groups) in events.iter() {
        let Json::Arr(groups) = groups else { continue };
        for (i, group) in groups.iter().enumerate() {
            let Some(Json::Arr(handlers)) = group.get("hooks") else {
                continue;
            };
            for (j, handler) in handlers.iter().enumerate() {
                if is_our_handler(handler) {
                    entries.push(TrustEntry {
                        key: format!("{hooks_path}:{}:{i}:{j}", snake_case(event)),
                        hash: codex_trust_hash(event, handler),
                    });
                }
            }
        }
    }
    entries
}

/// Whether every one of our Codex hooks is trusted and enabled in config.toml.
pub fn codex_hooks_trusted(hooks: Option<&Json>, hooks_path: &str, config: Option<&str>) -> bool {
    let Ok(doc) = TomlDoc::parse(config.unwrap_or("")) else {
        return false;
    };
    codex_trust_entries(hooks, hooks_path)
        .iter()
        .all(|entry| doc.trusts(&entry.key, &entry.hash))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::js_json::parse;

    fn hash(event: &str, handler: &str) -> String {
        codex_trust_hash(event, &parse(handler).unwrap())
    }

    fn edited(text: &str) -> Result<String, String> {
        enable_codex_hooks_feature(Some(text)).map(|edit| edit.text)
    }

    #[test]
    fn trust_hashes_follow_codexs_rules_for_timeouts_and_identity() {
        // Expected values are what the JS computes (SHA-256 of the sorted
        // compact JSON identity), checked there against Codex's own hashes.
        let cases = [
            (
                "Stop",
                r#"{"type":"command","command":"x"}"#,
                "6f14477468be127a92604ce05b51030268ccd6077fa7a807515589cfcfc7fd17",
            ),
            (
                "Stop",
                r#"{"type":"command","command":"x","timeout":null}"#,
                "6f14477468be127a92604ce05b51030268ccd6077fa7a807515589cfcfc7fd17",
            ),
            (
                "Stop",
                r#"{"type":"command","command":"x","timeout":"7"}"#,
                "601388fdae5e18622b496e62d218bc442f386b50ac7a375428a2a3029afa75ad",
            ),
            (
                "Stop",
                r#"{"type":"command","command":"x","timeout":"x"}"#,
                "228cf6d85dd01d037b738eba167daaf99202302330e4f2e760557d29aa4fb11a",
            ),
            (
                "Stop",
                r#"{"type":"command","command":"x","timeout":[3]}"#,
                "d01ee585acb29fd296868b24c90b448be56374b556348bcaeccb5d4e5f31df51",
            ),
            (
                "Stop",
                r#"{"type":"command","command":"x","timeout":0}"#,
                "11fd1bf6c8c77203d96105ae853dcf6a961553dd267dbbe78f72ab20a8383a10",
            ),
            (
                "Stop",
                r#"{"type":"command","command":"x","timeout":1e21}"#,
                "47688a67d5f9a33368e5d7fa5c5607d6298990d54c0e2a73418c804549e60cdd",
            ),
            (
                "SessionEnd",
                r#"{"type":"command","command":"x"}"#,
                "f3041eae9d0be5faed5367060d633bb905ed83825e2f4d9c7bc7f5ef19fe4bc7",
            ),
            (
                "SessionEnd",
                r#"{"type":"command","command":"x","timeout":99}"#,
                "b1aa6329f3a5daf36ae487200db1136f90a884bb805ddb24a6326c98dd6f29f6",
            ),
            (
                "Interrupt",
                r#"{"type":"command","command":"x","timeout":"0x2"}"#,
                "d39edf1c69b16d22d8e2a9be6ad43f29f85906b6ae3d4c437041059603780340",
            ),
            (
                "SessionStart",
                r#"{"type":"command","command":"😀 é \u2028 \"q\" \\ \n","statusMessage":"hi","async":true}"#,
                "c22eecb3e60e3898d6c6c6ed671eabffb9a8e0773f91efb3552c42e3d01fb300",
            ),
            (
                "Stop",
                r#"{"command":{"10":1,"b":[2,{"z":1,"y":2}],"9":3}}"#,
                "1a6b68a7c39c57fdc466d9516a58398ebb57891679a064da1c44bf0ad0694bbc",
            ),
            (
                "Stop",
                r#"{"bash":"x"}"#,
                "e989cc2a0b9cac1b7fc1f55feea5f90a6fe512f5614052c4f7957b99b5c809c7",
            ),
            (
                "HTTPRequest",
                r#"{"type":"command","command":"x"}"#,
                "f50c35ca712c67cf18ef5d2c518ab360bb3c84589a34afdb1df4d9ef74aed741",
            ),
            (
                "AbCdEf",
                r#"{"type":"command","command":"x"}"#,
                "8f9430880158b51510e66d96330cad557d54f67ea54d3267d2ae7b1b80b322d1",
            ),
        ];
        for (event, handler, digest) in cases {
            assert_eq!(
                hash(event, handler),
                format!("sha256:{digest}"),
                "{event} {handler}"
            );
        }
    }

    #[test]
    fn event_names_become_snake_case_pairwise() {
        for (event, snake) in [
            ("SessionStart", "session_start"),
            ("PreToolUse", "pre_tool_use"),
            ("HTTPRequest", "httprequest"),
            ("AbCdEf", "ab_cd_ef"),
            ("aBC", "a_bc"),
            ("aBcD", "a_bc_d"),
            ("already_snake", "already_snake"),
            ("Stop", "stop"),
            ("", ""),
        ] {
            assert_eq!(snake_case(event), snake, "{event}");
        }
    }

    #[test]
    fn the_trust_review_lists_only_our_handlers_with_their_indices() {
        let hooks = parse(
            r#"{"SessionStart":[{"hooks":[{"command":"mine"},{"command":"/x/bin/waycar-hook a b"}]},"no",{"hooks":"no"}],"Stop":"x","Interrupt":[{"hooks":[{"bash":"/y/src/hook-session.js"}]}]}"#,
        )
        .unwrap();
        let entries = codex_trust_entries(Some(&hooks), "/h/hooks.json");
        let keys: Vec<&str> = entries.iter().map(|entry| entry.key.as_str()).collect();
        assert_eq!(
            keys,
            [
                "/h/hooks.json:session_start:0:1",
                "/h/hooks.json:interrupt:0:0"
            ]
        );
        assert!(codex_trust_entries(None, "p").is_empty());
        assert!(codex_trust_entries(Some(&Json::Null), "p").is_empty());
        let config = format!(
            "[hooks.state.\"{}\"]\ntrusted_hash = \"{}\"\n[hooks.state.\"{}\"]\ntrusted_hash = \"{}\"\n",
            entries[0].key, entries[0].hash, entries[1].key, entries[1].hash
        );
        assert!(codex_hooks_trusted(
            Some(&hooks),
            "/h/hooks.json",
            Some(&config)
        ));
        // Nothing of ours needs no trust, but an unreadable config is never trusted.
        assert!(codex_hooks_trusted(Some(&Json::Null), "p", Some("")));
        assert!(codex_hooks_trusted(None, "p", None));
        assert!(!codex_hooks_trusted(None, "p", Some("[hooks")));
        assert!(!codex_hooks_trusted(Some(&hooks), "/h/hooks.json", None));
    }

    #[test]
    fn the_flag_edit_touches_one_line_and_keeps_line_endings() {
        // Expected texts are what the JS writes.
        for (text, expected) in [
            (
                "[features]\r\nfoo = 1\r\n",
                "[features]\r\nhooks = true\nfoo = 1\r\n",
            ),
            (
                "[features] # c\r\nfoo = 1\r\n",
                "[features] # c\r\nhooks = true\nfoo = 1\r\n",
            ),
            (
                "  [ features ]  \nfoo = 1\n",
                "  [ features ]  \nhooks = true\nfoo = 1\n",
            ),
            ("[features]\nhooks=1\n", "[features]\nhooks = true\n"),
            (
                "[features]\n  hooks   =   2\n",
                "[features]\nhooks = true\n",
            ),
            ("a = 1\n\n\n", "a = 1\n\n\n\n[features]\nhooks = true\n"),
            (
                "[x]\n[features]\nfoo = 1",
                "[x]\n[features]\nhooks = true\nfoo = 1",
            ),
            (
                "[features]\nfoo = [\n  1,\n]\n",
                "[features]\nhooks = true\nfoo = [\n  1,\n]\n",
            ),
            (
                "[features]\nnote = \"hooks = 1\"\n",
                "[features]\nhooks = true\nnote = \"hooks = 1\"\n",
            ),
            (
                "[features]\nfoo=1\n[features.sub]\nx = 1\n",
                "[features]\nhooks = true\nfoo=1\n[features.sub]\nx = 1\n",
            ),
        ] {
            assert_eq!(edited(text).unwrap(), expected, "{text:?}");
        }
    }

    #[test]
    fn a_header_the_edit_cannot_find_is_refused() {
        // `.` of the JS header regex stops at U+2028, so this is no header.
        for text in [
            "[features] # c\u{2028}x\nfoo = 1\n",
            "[\"features\"]\nfoo = 1\n",
        ] {
            let error = edited(text).unwrap_err();
            assert!(
                error.starts_with("config.toml sets features without a [features] table"),
                "{error}"
            );
        }
    }

    #[test]
    fn config_toml_is_read_the_way_smol_toml_reads_it() {
        // Two inputs the toml crate takes and smol-toml refuses.
        assert!(
            edited("\u{feff}[features]\nfoo = 1\n")
                .unwrap_err()
                .starts_with("Invalid TOML document")
        );
        assert!(
            edited("a = 9007199254740992\n")
                .unwrap_err()
                .starts_with("Invalid TOML document")
        );
        assert!(edited("a = 9007199254740991\n").is_ok());
        assert!(edited("a = [1, { b = -9007199254740992 }]\n").is_err());
        assert!(is_codex_feature_on(Some("a = 1\n")));
        assert!(is_codex_feature_on(None));
        assert!(
            !is_codex_feature_on(Some("[features\n")),
            "a file that does not parse counts as off"
        );
        assert!(!is_codex_feature_on(Some("[features]\nhooks = false\n")));
        assert!(!is_codex_feature_off(Some("[features\n")));
        assert!(is_codex_feature_off(Some("[features]\nhooks = false\n")));
        // A `hooks` that is not a boolean is neither on nor off.
        assert!(is_codex_feature_on(Some("[features]\nhooks = 0\n")));
        assert!(!is_codex_feature_off(Some("[features]\nhooks = 0\n")));
    }

    #[test]
    fn the_edit_must_keep_every_other_value() {
        // Dotted keys under features make `hooks = true` a redefinition.
        let error = edited("[features]\nhooks.x = 1\n").unwrap_err();
        assert!(
            error.starts_with("could not add [features] hooks = true to config.toml ("),
            "{error}"
        );
        assert!(error.ends_with("); add it by hand"), "{error}");
        assert_eq!(
            edited("features = 5\n").unwrap_err(),
            "config.toml sets features without a [features] table; add `hooks = true` under [features] by hand"
        );
        // NaN and signed zero compare as Object.is does, so they do not block an edit.
        assert_eq!(
            edited("a = nan\nb = -0.0\n[features]\nfoo = 1\n").unwrap(),
            "a = nan\nb = -0.0\n[features]\nhooks = true\nfoo = 1\n"
        );
    }

    #[test]
    fn javascript_number_coercion_reads_strings_the_way_the_language_does() {
        let n = |text: &str| string_to_number(text);
        assert_eq!(n(" 7 "), 7.0);
        assert_eq!(n(""), 0.0);
        assert_eq!(n("  \n"), 0.0);
        assert_eq!(n("0x10"), 16.0);
        assert_eq!(n("0b101"), 5.0);
        assert_eq!(n("0o17"), 15.0);
        assert_eq!(n("1e3"), 1000.0);
        assert_eq!(n(".5e1"), 5.0);
        assert_eq!(n("5."), 5.0);
        assert_eq!(n("-Infinity"), f64::NEG_INFINITY);
        assert_eq!(n("+Infinity"), f64::INFINITY);
        for not in [
            "x", "1_0", "0x", "0x1g", "-0x10", "1e", "1e+", ".", "+", "inf", "nan", "Infinit",
            "1 2", "--1",
        ] {
            assert!(n(not).is_nan(), "{not}");
        }
        assert_eq!(to_number(&parse("[3]").unwrap()), 3.0);
        assert_eq!(to_number(&parse("[]").unwrap()), 0.0);
        assert!(to_number(&parse("[1,2]").unwrap()).is_nan());
        assert!(to_number(&parse("{}").unwrap()).is_nan());
        assert_eq!(to_number(&parse("true").unwrap()), 1.0);
        assert_eq!(to_number(&parse("null").unwrap()), 0.0);
        assert_eq!(to_number(&parse("[[7]]").unwrap()), 7.0);
        assert_eq!(to_number(&parse("[null]").unwrap()), 0.0);
    }
}
