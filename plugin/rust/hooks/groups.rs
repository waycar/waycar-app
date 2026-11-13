//! The hook commands, the groups they form and the order-preserving merge of
//! those groups into a hooks object.
//!
//! Ours are recognized by the `/bin/waycar-hook` path or the `/bin/waycar'
//! hook-session ` command in a command, so uninstall removes only ours. The
//! Node-era session command (`'<root>/bin/node.sh' '<root>/src/hook-session.js'
//! <agent>`, plugin 1.x) is recognized by its script path too: uninstall
//! removes it and install and `hooks migrate` rewrite it.

use std::path::Path;

use crate::js_json::{Json, Obj, deep_equal, quote};
use crate::paths::posix_join;

use super::entries::*;

/// Event name to its groups, in install order (a JS `Map`).
pub type Groups = Vec<(String, Vec<Json>)>;

/// POSIX shell single-quoting.
pub fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

fn joined(root: &Path, parts: &[&str]) -> String {
    let mut all = vec![root];
    all.extend(parts.iter().map(Path::new));
    posix_join(&all).to_string_lossy().into_owned()
}

/// The command an entry runs. `waycar hook-session` gets the event name,
/// except for SessionStart, its default.
pub fn hook_command(plugin_root: &Path, agent: &str, status: &str, event: &str) -> String {
    if status == SESSION {
        let command = format!(
            "{} hook-session {agent}",
            shell_quote(&joined(plugin_root, &["bin", "waycar"])),
        );
        return if event == "SessionStart" {
            command
        } else {
            format!("{command} {event}")
        };
    }
    format!(
        "{} {agent} {status}",
        shell_quote(&joined(plugin_root, &["bin", "waycar-hook"]))
    )
}

/// The hook-session command written by plugin 1.x, which called Node.
pub fn is_legacy_command(command: &str) -> bool {
    command.contains("/src/hook-session.js")
}

pub fn is_our_command(command: &str) -> bool {
    command.contains("/bin/waycar-hook")
        || command.contains("/bin/waycar' hook-session ")
        || is_legacy_command(command)
}

fn command_is_ours(value: Option<&Json>) -> bool {
    value.and_then(Json::as_str).is_some_and(is_our_command)
}

/// Whether a hook handler is one of ours, from any plugin root (Copilot names
/// the command `bash`).
pub fn is_our_handler(handler: &Json) -> bool {
    command_is_ours(handler.get("command")) || command_is_ours(handler.get("bash"))
}

/// A JSON object from `(key, value)` pairs, in the given order.
pub fn object<const N: usize>(pairs: [(&str, Json); N]) -> Json {
    let mut out = Obj::new();
    for (key, value) in pairs {
        out.set(key, value);
    }
    Json::Obj(out)
}

pub fn number(value: u32) -> Json {
    Json::Num(f64::from(value))
}

fn push_group(groups: &mut Groups, event: &str, group: Json) {
    match groups.iter_mut().find(|(name, _)| name == event) {
        Some((_, list)) => list.push(group),
        None => groups.push((event.to_string(), vec![group])),
    }
}

/// How a Claude-format kind spells one handler.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Handler {
    /// `{type, command, timeout}`
    Standard,
    /// Gemini: millisecond timeouts, and a `name`.
    Gemini,
    /// Copilot: the command is `bash`, the timeout `timeoutSec`.
    Copilot,
    /// Cursor: `{command, timeout}`.
    Cursor,
    /// Muse: Interrupt handlers must be async (Muse 1.4.6 skips a synchronous one).
    Muse,
}

impl Handler {
    fn build(self, command: String, event: &str) -> Json {
        let command_type = || Json::str("command");
        match self {
            Self::Standard => object([
                ("type", command_type()),
                ("command", Json::Str(command)),
                ("timeout", number(HOOK_TIMEOUT_SEC)),
            ]),
            Self::Gemini => object([
                ("type", command_type()),
                ("name", Json::Str(format!("waycar-{event}"))),
                ("command", Json::Str(command)),
                ("timeout", number(HOOK_TIMEOUT_SEC * 1000)),
            ]),
            Self::Copilot => object([
                ("type", command_type()),
                ("bash", Json::Str(command)),
                ("timeoutSec", number(HOOK_TIMEOUT_SEC)),
            ]),
            Self::Cursor => object([
                ("command", Json::Str(command)),
                ("timeout", number(HOOK_TIMEOUT_SEC)),
            ]),
            Self::Muse => {
                let mut handler = object([
                    ("type", command_type()),
                    ("command", Json::Str(command)),
                    ("timeout", number(HOOK_TIMEOUT_SEC)),
                ]);
                if event == "Interrupt"
                    && let Json::Obj(fields) = &mut handler
                {
                    fields.set("async", Json::Bool(true));
                }
                handler
            }
        }
    }
}

/// The Claude-format JSON hook files: `file` is the config file; `flat` lists
/// handlers directly under each event instead of `{matcher?, hooks}` groups;
/// `base` keys go first in a new file; `owned` files are ours alone and are
/// deleted once empty.
pub struct SettingsSpec {
    pub entries: &'static [Entry],
    pub handler: Handler,
    pub flat: bool,
    pub owned: bool,
    pub base: &'static [(&'static str, u32)],
}

/// The spec of a Claude-format kind (claude, qwen, gemini, devin, grok,
/// copilot, cursor, muse), `None` for any other agent.
pub fn settings_spec(agent: &str) -> Option<SettingsSpec> {
    let spec = |entries, handler, flat, owned, base| SettingsSpec {
        entries,
        handler,
        flat,
        owned,
        base,
    };
    Some(match agent {
        "claude" => spec(CLAUDE_ENTRIES, Handler::Standard, false, false, &[]),
        "qwen" => spec(QWEN_ENTRIES, Handler::Standard, false, false, &[]),
        "gemini" => spec(GEMINI_ENTRIES, Handler::Gemini, false, false, &[]),
        "devin" => spec(DEVIN_ENTRIES, Handler::Standard, false, false, &[]),
        "grok" => spec(GROK_ENTRIES, Handler::Standard, false, true, &[]),
        "copilot" => spec(
            COPILOT_ENTRIES,
            Handler::Copilot,
            true,
            true,
            &[("version", 1)],
        ),
        "cursor" => spec(
            CURSOR_ENTRIES,
            Handler::Cursor,
            true,
            false,
            &[("version", 1)],
        ),
        // `schema_version` is required in Muse's settings.
        "muse" => spec(
            MUSE_ENTRIES,
            Handler::Muse,
            false,
            false,
            &[("schema_version", 1)],
        ),
        _ => return None,
    })
}

/// Desired groups per event for a Claude-format kind, in install order;
/// `None` when `agent` is not one.
pub fn settings_groups(agent: &str, plugin_root: &Path) -> Option<Groups> {
    let spec = settings_spec(agent)?;
    let mut groups = Groups::new();
    for (event, matcher, status) in spec.entries {
        let inner = spec
            .handler
            .build(hook_command(plugin_root, agent, status, event), event);
        let mut group = Obj::new();
        if let Some(matcher) = matcher {
            group.set("matcher", Json::str(*matcher));
        }
        if spec.flat {
            if let Json::Obj(fields) = inner {
                for (key, value) in fields.iter() {
                    group.set(key, value.clone());
                }
            }
        } else {
            group.set("hooks", Json::Arr(vec![inner]));
        }
        push_group(&mut groups, event, Json::Obj(group));
    }
    Some(groups)
}

/// Desired Claude groups per event, in install order.
pub fn claude_groups(plugin_root: &Path) -> Groups {
    settings_groups("claude", plugin_root).unwrap_or_default()
}

/// Desired Codex groups per event, in install order.
pub fn codex_groups(plugin_root: &Path) -> Groups {
    let mut groups = Groups::new();
    for (event, status) in CODEX_ENTRIES {
        let timeout = if CODEX_SHORT_EVENTS.contains(event) {
            CODEX_SHORT_TIMEOUT_SEC
        } else {
            HOOK_TIMEOUT_SEC
        };
        let handler = object([
            ("type", Json::str("command")),
            (
                "command",
                Json::Str(hook_command(plugin_root, "codex", status, event)),
            ),
            ("timeout", number(timeout)),
        ]);
        let group = object([("hooks", Json::Arr(vec![handler]))]);
        push_group(&mut groups, event, group);
    }
    groups
}

/// Antigravity's `"waycar"` group: tool events nest `matcher`/`hooks`, the
/// others list their handlers directly.
pub fn agy_group(plugin_root: &Path) -> Json {
    let mut group = Obj::new();
    for (event, matcher, status) in AGY_ENTRIES {
        let handler = object([
            ("type", Json::str("command")),
            (
                "command",
                Json::Str(hook_command(plugin_root, "agy", status, event)),
            ),
            ("timeout", number(HOOK_TIMEOUT_SEC)),
        ]);
        let entry = match matcher {
            None => handler,
            Some(matcher) => object([
                ("matcher", Json::str(*matcher)),
                ("hooks", Json::Arr(vec![handler])),
            ]),
        };
        let mut list = match group.get(event) {
            Some(Json::Arr(items)) => items.clone(),
            _ => Vec::new(),
        };
        list.push(entry);
        group.set(*event, Json::Arr(list));
    }
    Json::Obj(group)
}

/// Every command string anywhere in `value`.
pub fn commands_in<'a>(value: &'a Json, out: &mut Vec<&'a str>) {
    match value {
        Json::Arr(items) => items.iter().for_each(|item| commands_in(item, out)),
        Json::Obj(fields) => {
            for (key, item) in fields.iter() {
                match item {
                    Json::Str(text) if key == "command" || key == "bash" => out.push(text),
                    _ => commands_in(item, out),
                }
            }
        }
        _ => {}
    }
}

/// The handlers in one entry of an event's list: a group's `hooks`, or the
/// entry itself when flat.
fn handlers_of(group: &Json, flat: bool) -> Option<&[Json]> {
    if flat {
        return matches!(group, Json::Obj(_) | Json::Arr(_)).then(|| std::slice::from_ref(group));
    }
    match group.get("hooks") {
        Some(Json::Arr(handlers)) => Some(handlers),
        _ => None,
    }
}

/// A group with `hooks` cut down to our handlers: all of it that is ours
/// when someone else's handlers share it (agent-deck adds its own to the
/// first group with its matcher, ours included). A flat entry is one handler.
fn our_part(group: &Json, flat: bool) -> Json {
    match (group, handlers_of(group, flat)) {
        (Json::Obj(fields), Some(handlers)) if !flat => {
            let mut part = fields.clone();
            let ours = handlers.iter().filter(|h| is_our_handler(h)).cloned();
            part.set("hooks", Json::Arr(ours.collect()));
            Json::Obj(part)
        }
        _ => group.clone(),
    }
}

/// Whether two groups agree on everything but their handlers (the matcher).
fn same_but_hooks(group: &Obj, other: &Json) -> bool {
    let Json::Obj(other) = other else {
        return false;
    };
    let (mut a, mut b) = (group.clone(), other.clone());
    a.remove("hooks");
    b.remove("hooks");
    a.deep_equals(&b)
}

/// `out[event] = value`. A JS object assigned the key `__proto__` takes the
/// value as its prototype instead of a property, so the key never reaches
/// the file; the merge drops it the same way.
fn assign(out: &mut Obj, event: &str, value: Json) {
    if event != "__proto__" {
        out.set(event, value);
    }
}

/// Merge `desired` (empty for uninstall) into a hooks object and return the
/// new object. Groups made only of our handlers are replaced in place, in
/// order, by the desired ones; surplus ones are dropped and missing ones
/// appended. A group our handlers share with someone else's takes the next
/// desired group's handlers in place of ours when the two agree on the
/// matcher; otherwise ours are cut out of it, and so they are while an event
/// holds more groups of ours than it wants, so that a shared group gives way
/// before a group of ours is dropped. Either way their handlers keep
/// their places, and every other group and key keeps its position, so Codex
/// trust keys (which carry indices) of other hooks stay valid. An event whose
/// groups were all ours disappears when nothing is desired for it. `flat`
/// lists hold handlers directly (Copilot, Cursor).
pub fn merge_hook_groups(hooks: Option<&Json>, desired: &Groups, flat: bool) -> Obj {
    let empty = Obj::new();
    let source = hooks.and_then(Json::as_object).unwrap_or(&empty);
    let mut events: Vec<&str> = source.keys().collect();
    events.extend(
        desired
            .iter()
            .map(|(event, _)| event.as_str())
            .filter(|event| !source.contains_key(event)),
    );
    let mut out = Obj::new();
    for event in events {
        let existing = source.get(event);
        let want: &[Json] = desired
            .iter()
            .find(|(name, _)| name == event)
            .map_or(&[], |(_, groups)| groups);
        let Some(Json::Arr(existing_groups)) = existing else {
            match existing {
                Some(value) => assign(&mut out, event, value.clone()),
                None if !want.is_empty() => assign(&mut out, event, Json::Arr(want.to_vec())),
                None => {}
            }
            continue;
        };
        let holding_ours = existing_groups
            .iter()
            .filter(|group| {
                handlers_of(group, flat).is_some_and(|list| list.iter().any(is_our_handler))
            })
            .count();
        let mut surplus = holding_ours.saturating_sub(want.len());
        let mut groups: Vec<Json> = Vec::new();
        let mut next = 0;
        for group in existing_groups {
            let handlers = handlers_of(group, flat);
            let ours = handlers.map_or(0, |list| list.iter().filter(|h| is_our_handler(h)).count());
            if ours == 0 {
                groups.push(group.clone());
            } else if handlers.is_some_and(|list| ours == list.len()) {
                if let Some(replacement) = want.get(next) {
                    groups.push(replacement.clone());
                    next += 1;
                }
            } else if let (Json::Obj(fields), Some(list)) = (group, handlers) {
                let mut replacement = None;
                if surplus > 0 {
                    surplus -= 1;
                } else {
                    replacement = want
                        .get(next)
                        .filter(|wanted| same_but_hooks(fields, wanted))
                        .and_then(|wanted| handlers_of(wanted, false));
                    if replacement.is_some() {
                        next += 1;
                    }
                }
                let mut kept = Vec::new();
                for handler in list {
                    if !is_our_handler(handler) {
                        kept.push(handler.clone());
                    } else if let Some(ours) = replacement.take() {
                        kept.extend(ours.iter().cloned());
                    }
                }
                let mut shared = fields.clone();
                shared.set("hooks", Json::Arr(kept));
                groups.push(Json::Obj(shared));
            }
        }
        groups.extend(want[next..].iter().cloned());
        if !groups.is_empty() || existing_groups.is_empty() {
            assign(&mut out, event, Json::Arr(groups));
        }
    }
    out
}

fn our_groups<'a>(
    hooks: Option<&'a Json>,
    flat: bool,
) -> impl Iterator<Item = (&'a str, &'a Json)> + 'a {
    hooks
        .and_then(Json::as_object)
        .into_iter()
        .flat_map(Obj::iter)
        .filter_map(|(event, groups)| groups.as_array().map(|list| (event, list)))
        .flat_map(|(event, list)| list.iter().map(move |group| (event, group)))
        .filter(move |(_, group)| {
            handlers_of(group, flat).is_some_and(|list| list.iter().any(is_our_handler))
        })
}

/// Whether `hooks` holds exactly the desired groups of ours, and no others;
/// a group shared with someone else's handlers counts as its part that is ours.
pub fn has_exactly(hooks: Option<&Json>, desired: &Groups, flat: bool) -> bool {
    let mut ours: Groups = Groups::new();
    for (event, group) in our_groups(hooks, flat) {
        push_group(&mut ours, event, our_part(group, flat));
    }
    ours.len() == desired.len()
        && desired.iter().all(|(event, groups)| {
            ours.iter()
                .find(|(name, _)| name == event)
                .is_some_and(|(_, found)| {
                    deep_equal(&Json::Arr(found.clone()), &Json::Arr(groups.clone()))
                })
        })
}

pub fn has_any_ours(hooks: Option<&Json>, flat: bool) -> bool {
    our_groups(hooks, flat).next().is_some()
}

/// `JSON.stringify` of the plugin root, for the extension templates.
pub fn root_json(plugin_root: &Path) -> String {
    quote(&plugin_root.to_string_lossy())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::js_json::parse;

    fn j(text: &str) -> Json {
        parse(text).unwrap()
    }

    fn merged(hooks: &str, desired: &Groups, flat: bool) -> String {
        Json::Obj(merge_hook_groups(Some(&j(hooks)), desired, flat)).to_compact()
    }

    #[test]
    fn shell_quote_closes_and_reopens_around_a_single_quote() {
        assert_eq!(shell_quote("abc"), "'abc'");
        assert_eq!(shell_quote(""), "''");
        assert_eq!(shell_quote("it's"), r"'it'\''s'");
        assert_eq!(shell_quote("'"), r"''\'''");
        assert_eq!(shell_quote("$HOME `x` \"y\" \n"), "'$HOME `x` \"y\" \n'");
    }

    #[test]
    fn hook_command_names_the_event_except_for_session_start() {
        let root = Path::new("/opt/way car/it's//plugin/");
        assert_eq!(
            hook_command(root, "claude", "working", "SessionStart"),
            r"'/opt/way car/it'\''s/plugin/bin/waycar-hook' claude working"
        );
        assert_eq!(
            hook_command(root, "gemini", SESSION, "SessionStart"),
            r"'/opt/way car/it'\''s/plugin/bin/waycar' hook-session gemini"
        );
        assert_eq!(
            hook_command(Path::new("/p"), "gemini", SESSION, "BeforeAgent"),
            "'/p/bin/waycar' hook-session gemini BeforeAgent"
        );
        // A status that is not `session` ignores the event.
        assert_eq!(
            hook_command(Path::new("/p"), "cline", "done", "TaskComplete"),
            "'/p/bin/waycar-hook' cline done"
        );
    }

    #[test]
    fn our_commands_are_found_by_their_paths_from_any_root() {
        assert!(is_our_command("'/x/bin/waycar-hook' claude done"));
        assert!(is_our_command("'/x/bin/waycar' hook-session claude"));
        assert!(is_our_command("'/x/bin/waycar' hook-session claude Stop"));
        // The Node-era session command of plugin 1.x is ours too, and legacy.
        let legacy = "'/x/bin/node.sh' '/x/src/hook-session.js' claude";
        assert!(is_our_command(legacy));
        assert!(is_legacy_command(legacy));
        assert!(!is_legacy_command("'/x/bin/waycar' hook-session claude"));
        assert!(!is_legacy_command("'/x/bin/waycar-hook' claude done"));
        assert!(!is_our_command("'/x/bin/waycar' pair"));
        assert!(!is_our_command("'/x/bin/moshi-hook' claude done"));
        assert!(is_our_handler(&j(
            r#"{"bash": "'/x/bin/waycar-hook' c d"}"#
        )));
        assert!(is_our_handler(&j(
            r#"{"command": "/y/src/hook-session.js"}"#
        )));
        for other in [
            r#"{"command": 5}"#,
            r#"{"bash": null}"#,
            "null",
            "5",
            r#""'/x/bin/waycar-hook'""#,
            "[]",
        ] {
            assert!(!is_our_handler(&j(other)), "{other}");
        }
    }

    #[test]
    fn every_claude_format_kind_has_one_group_per_entry_in_install_order() {
        let root = Path::new("/p");
        for agent in [
            "claude", "qwen", "gemini", "devin", "grok", "copilot", "cursor", "muse",
        ] {
            let spec = settings_spec(agent).unwrap();
            let groups = settings_groups(agent, root).unwrap();
            let events: Vec<&str> = groups.iter().map(|(event, _)| event.as_str()).collect();
            let mut expected: Vec<&str> = Vec::new();
            for (event, _, _) in spec.entries {
                if !expected.contains(event) {
                    expected.push(event);
                }
            }
            assert_eq!(events, expected, "{agent}");
            let total: usize = groups.iter().map(|(_, list)| list.len()).sum();
            assert_eq!(total, spec.entries.len(), "{agent}");
        }
        assert!(settings_groups("codex", root).is_none());
        // Two Notification groups share one event, in table order.
        let claude = claude_groups(root);
        let notification = &claude.iter().find(|(e, _)| e == "Notification").unwrap().1;
        assert_eq!(notification.len(), 2);
        assert_eq!(
            notification[1].get("matcher").and_then(Json::as_str),
            Some("idle_prompt")
        );
    }

    #[test]
    fn handler_shapes_follow_each_kind() {
        let root = Path::new("/p");
        let first = |agent: &str, event: &str| {
            settings_groups(agent, root)
                .unwrap()
                .into_iter()
                .find(|(name, _)| name == event)
                .unwrap()
                .1[0]
                .to_compact()
        };
        assert_eq!(
            first("gemini", "AfterAgent"),
            r#"{"matcher":"*","hooks":[{"type":"command","name":"waycar-AfterAgent","command":"'/p/bin/waycar-hook' gemini done","timeout":10000}]}"#
        );
        assert_eq!(
            first("copilot", "Stop"),
            r#"{"type":"command","bash":"'/p/bin/waycar-hook' copilot done","timeoutSec":10}"#
        );
        assert_eq!(
            first("cursor", "stop"),
            r#"{"command":"'/p/bin/waycar-hook' cursor done-if-active","timeout":10}"#
        );
        assert_eq!(
            first("muse", "Interrupt"),
            r#"{"hooks":[{"type":"command","command":"'/p/bin/waycar-hook' muse idle","timeout":10,"async":true}]}"#
        );
        assert_eq!(
            first("muse", "Stop"),
            r#"{"hooks":[{"type":"command","command":"'/p/bin/waycar-hook' muse done","timeout":10}]}"#
        );
        assert_eq!(
            agy_group(root).to_compact(),
            concat!(
                r#"{"PreInvocation":[{"type":"command","command":"'/p/bin/waycar' hook-session agy PreInvocation","timeout":10}],"#,
                r#""PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"'/p/bin/waycar-hook' agy watch-approval","timeout":10}]}],"#,
                r#""Stop":[{"type":"command","command":"'/p/bin/waycar' hook-session agy Stop","timeout":10}]}"#
            )
        );
        let codex = codex_groups(root);
        let timeouts: Vec<String> = codex
            .iter()
            .map(|(event, list)| format!("{event}:{}", at_timeout(&list[0])))
            .collect();
        assert_eq!(
            timeouts,
            [
                "SessionStart:10",
                "UserPromptSubmit:10",
                "PreToolUse:10",
                "PermissionRequest:10",
                "PostToolUse:10",
                "Stop:10",
                "Interrupt:3",
                "SessionEnd:3"
            ]
        );
    }

    fn at_timeout(group: &Json) -> String {
        group
            .get("hooks")
            .and_then(Json::as_array)
            .and_then(|hooks| hooks[0].get("timeout"))
            .map_or_else(String::new, Json::to_compact)
    }

    #[test]
    fn merge_replaces_ours_in_place_and_keeps_everything_else() {
        let old = r#"{"hooks":[{"command":"'/old/bin/waycar-hook' claude done"}]}"#;
        let user = r#"{"hooks":[{"command":"mine"}]}"#;
        let desired: Groups = vec![(
            "Stop".into(),
            vec![j(
                r#"{"hooks":[{"command":"'/new/bin/waycar-hook' claude done"}]}"#,
            )],
        )];
        assert_eq!(
            merged(
                &format!(r#"{{"Stop":[{old},{user},{old}],"X":1}}"#),
                &desired,
                false
            ),
            format!(
                r#"{{"Stop":[{{"hooks":[{{"command":"'/new/bin/waycar-hook' claude done"}}]}},{user}],"X":1}}"#
            )
        );
        // Ours inside someone else's group is cut out of it; an all-ours group goes.
        assert_eq!(
            merged(
                r#"{"Stop":[{"matcher":"m","hooks":[{"command":"mine"},{"command":"/o/bin/waycar-hook"}]},{"hooks":[{"command":"/o/bin/waycar-hook"}]}]}"#,
                &Groups::new(),
                false
            ),
            r#"{"Stop":[{"matcher":"m","hooks":[{"command":"mine"}]}]}"#
        );
        // A shared group with the desired matcher gets ours in place, beside
        // theirs; one with another matcher loses ours to a group of their own.
        assert_eq!(
            merged(
                r#"{"Stop":[{"hooks":[{"command":"/o/bin/waycar-hook"},{"command":"mine"},{"command":"/o/bin/waycar-hook"}]}]}"#,
                &desired,
                false
            ),
            r#"{"Stop":[{"hooks":[{"command":"'/new/bin/waycar-hook' claude done"},{"command":"mine"}]}]}"#
        );
        assert_eq!(
            merged(
                r#"{"Stop":[{"matcher":"m","hooks":[{"command":"/o/bin/waycar-hook"},{"command":"mine"}]}]}"#,
                &desired,
                false
            ),
            r#"{"Stop":[{"matcher":"m","hooks":[{"command":"mine"}]},{"hooks":[{"command":"'/new/bin/waycar-hook' claude done"}]}]}"#
        );
        // With more groups of ours than wanted, the shared one gives way, so
        // no group of ours is dropped from before someone else's.
        assert_eq!(
            merged(
                r#"{"Stop":[{"hooks":[{"command":"/o/bin/waycar-hook"},{"command":"mine"}]},{"hooks":[{"command":"/o/bin/waycar-hook"}]},{"hooks":[{"command":"theirs"}]}]}"#,
                &desired,
                false
            ),
            r#"{"Stop":[{"hooks":[{"command":"mine"}]},{"hooks":[{"command":"'/new/bin/waycar-hook' claude done"}]},{"hooks":[{"command":"theirs"}]}]}"#
        );
        // An event of only ours disappears, an empty list stays, junk stays.
        assert_eq!(
            merged(
                r#"{"A":[{"hooks":[{"command":"/o/bin/waycar-hook"}]}],"B":[],"C":5,"D":null,"E":[1,null,"x"]}"#,
                &Groups::new(),
                false
            ),
            r#"{"B":[],"C":5,"D":null,"E":[1,null,"x"]}"#
        );
    }

    #[test]
    fn merge_follows_javascript_object_semantics() {
        let desired: Groups = vec![("Stop".into(), vec![j(r#"{"hooks":[]}"#)])];
        // Integer-like events list first, a duplicate keeps its first place,
        // and `__proto__` is lost to the prototype setter.
        assert_eq!(
            merged(
                r#"{"b":[],"10":[],"a":[],"9":[],"b":[1],"__proto__":[{"hooks":[]}]}"#,
                &desired,
                false
            ),
            r#"{"9":[],"10":[],"b":[1],"a":[],"Stop":[{"hooks":[]}]}"#
        );
        // Anything but an object is an empty one.
        for source in ["[]", "null", "5", r#""x""#] {
            assert_eq!(
                merged(source, &desired, false),
                r#"{"Stop":[{"hooks":[]}]}"#,
                "{source}"
            );
        }
        assert_eq!(
            Json::Obj(merge_hook_groups(None, &desired, false)).to_compact(),
            r#"{"Stop":[{"hooks":[]}]}"#
        );
    }

    #[test]
    fn flat_lists_hold_handlers_directly() {
        let desired: Groups = vec![(
            "stop".into(),
            vec![j(r#"{"command":"'/n/bin/waycar-hook' c d"}"#)],
        )];
        assert_eq!(
            merged(
                r#"{"stop":[{"command":"mine"},{"command":"'/o/bin/waycar-hook' c d"},"x",null,[]]}"#,
                &desired,
                true
            ),
            r#"{"stop":[{"command":"mine"},{"command":"'/n/bin/waycar-hook' c d"},"x",null,[]]}"#
        );
        assert_eq!(
            merged(
                r#"{"stop":[{"bash":"'/o/bin/waycar-hook' c d"},{"bash":"mine"}]}"#,
                &Groups::new(),
                true
            ),
            r#"{"stop":[{"bash":"mine"}]}"#
        );
    }

    #[test]
    fn exactness_ignores_key_order_but_not_extra_groups() {
        let desired = settings_groups("claude", Path::new("/p")).unwrap();
        let hooks = Json::Obj(merge_hook_groups(None, &desired, false));
        assert!(has_exactly(Some(&hooks), &desired, false));
        assert!(has_any_ours(Some(&hooks), false));
        let with_user = j(r#"{"Stop":[{"hooks":[{"command":"mine"}]}],"Z":[]}"#);
        assert!(!has_any_ours(Some(&with_user), false));
        // A user's extra group beside ours does not change exactness.
        let mut extra = merge_hook_groups(Some(&with_user), &desired, false);
        assert!(has_exactly(
            Some(&Json::Obj(extra.clone())),
            &desired,
            false
        ));
        // Nor does someone else's handler inside a group of ours.
        let Some(Json::Arr(mut stop)) = extra.get("Stop").cloned() else {
            panic!()
        };
        if let Json::Obj(group) = &mut stop[1] {
            group.set(
                "hooks",
                j(&format!(
                    r#"[{{"command":"mine"}},{}]"#,
                    group.get("hooks").unwrap().as_array().unwrap()[0].to_compact()
                )),
            );
        }
        extra.set("Stop", Json::Arr(stop));
        assert!(has_exactly(
            Some(&Json::Obj(extra.clone())),
            &desired,
            false
        ));
        // A changed field of ours does.
        extra.set(
            "SessionEnd",
            j(r#"[{"hooks":[{"command":"/x/bin/waycar-hook"}]}]"#),
        );
        assert!(!has_exactly(Some(&Json::Obj(extra)), &desired, false));
        assert!(!has_exactly(None, &desired, false));
        assert!(has_exactly(None, &Groups::new(), false));
    }

    #[test]
    fn commands_are_collected_from_command_and_bash_anywhere() {
        let value = j(
            r#"{"a":[{"command":"1","x":{"bash":"2","command":{"command":"3"}}}],"command":5,"b":"command"}"#,
        );
        let mut found = Vec::new();
        commands_in(&value, &mut found);
        assert_eq!(found, ["1", "2", "3"]);
    }
}
