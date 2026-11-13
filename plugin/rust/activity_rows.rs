//! Per-device Agent List Fields, resolved by the app before registration
//! (activity-rows.js).
//!
//! The layout a device registers is parsed once ([`parse_activity_row_layout`]);
//! [`render_activity_rows`] resolves it for one Agent into the spans that ride
//! in the encrypted Live Activity envelope. Agents and the herdr context
//! (tab and pane entries) stay `serde_json::Value`s: they are herdr's JSON, read
//! as loosely as the JS reads them.

use std::borrow::Cow;

use serde_json::{Map, Value, json};
use unicode_normalization::{UnicodeNormalization, is_nfc};
use unicode_segmentation::UnicodeSegmentation;

use crate::display_text::optional_text;
use crate::js_compat::{js_get_opt, js_strict_eq, js_string_unit, js_to_string, non_null};
use crate::jsx;

const BUILTINS: [&str; 11] = [
    "state_icon",
    "state_text",
    "workspace",
    "tab",
    "pane",
    "agent",
    "terminal_title",
    "terminal_title_stripped",
    "host",
    "status",
    "directory",
];
const MAX_ROWS: usize = 3;
const MAX_FIELDS: usize = 16;
/// A row value is cut to this many grapheme clusters, no ellipsis.
const ROW_TEXT_LIMIT: usize = 80;
const SEPARATOR: &str = " · ";

/// One configured field: a token and the style the span of its value gets.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Field {
    pub token: String,
    pub fg: Option<String>,
    pub bold: Option<bool>,
    pub dim: Option<bool>,
}

/// A validated layout: at most three rows of at most sixteen fields.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RowLayout {
    pub rows: Vec<Vec<Field>>,
}

impl RowLayout {
    /// The parsed form as JS holds it (`{rows: [[{token, fg?, bold?, dim?}]]}`),
    /// which the Live Activity hook hashes into the device preferences.
    pub fn to_json(&self) -> Value {
        let rows = self
            .rows
            .iter()
            .map(|row| {
                Value::Array(
                    row.iter()
                        .map(|field| {
                            let mut entry = Map::new();
                            entry.insert("token".into(), json!(field.token));
                            if let Some(fg) = &field.fg {
                                entry.insert("fg".into(), json!(fg));
                            }
                            if let Some(bold) = field.bold {
                                entry.insert("bold".into(), json!(bold));
                            }
                            if let Some(dim) = field.dim {
                                entry.insert("dim".into(), json!(dim));
                            }
                            Value::Object(entry)
                        })
                        .collect(),
                )
            })
            .collect();
        json!({ "rows": Value::Array(rows) })
    }
}

/// One run of row text with the style of the field it came from; the
/// separators between fields are unstyled.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Span {
    pub text: String,
    pub fg: Option<String>,
    pub bold: Option<bool>,
    pub dim: Option<bool>,
}

impl Span {
    /// `{text, fg?, bold?, dim?}` in that key order.
    pub fn to_json(&self) -> Value {
        let mut span = Map::new();
        span.insert("text".into(), json!(self.text));
        if let Some(fg) = &self.fg {
            span.insert("fg".into(), json!(fg));
        }
        if let Some(bold) = self.bold {
            span.insert("bold".into(), json!(bold));
        }
        if let Some(dim) = self.dim {
            span.insert("dim".into(), json!(dim));
        }
        Value::Object(span)
    }
}

/// Rendered rows as the wire array.
pub fn rows_to_json(rows: &[Vec<Span>]) -> Value {
    Value::Array(
        rows.iter()
            .map(|row| Value::Array(row.iter().map(Span::to_json).collect()))
            .collect(),
    )
}

fn is_color(text: &str) -> bool {
    text.strip_prefix('#')
        .is_some_and(|hex| matches!(hex.len(), 3 | 6) && hex.bytes().all(|b| b.is_ascii_hexdigit()))
}

/// `^\$[A-Za-z0-9_-]{1,32}$`
fn is_custom_token(token: &str) -> bool {
    token.strip_prefix('$').is_some_and(|name| {
        (1..=32).contains(&name.len())
            && name
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
    })
}

fn parse_field(field: &Value) -> Option<Field> {
    let token = field.get("token")?.as_str()?;
    if !BUILTINS.contains(&token) && !is_custom_token(token) {
        return None;
    }
    let mut entry = Field {
        token: token.to_string(),
        fg: None,
        bold: None,
        dim: None,
    };
    if let Some(fg) = non_null(field.get("fg")) {
        let fg = fg.as_str().filter(|text| is_color(text))?;
        entry.fg = Some(fg.to_string());
    }
    if let Some(bold) = non_null(field.get("bold")) {
        entry.bold = Some(bold.as_bool()?);
    }
    if let Some(dim) = non_null(field.get("dim")) {
        entry.dim = Some(dim.as_bool()?);
    }
    Some(entry)
}

/// Malformed layouts leave older senders' identity rendering intact: `None`.
pub fn parse_activity_row_layout(value: Option<&Value>) -> Option<RowLayout> {
    let rows = value?.get("rows")?.as_array()?;
    if rows.len() > MAX_ROWS {
        return None;
    }
    let mut parsed = Vec::with_capacity(rows.len());
    for row in rows {
        let row = row.as_array()?;
        if row.len() > MAX_FIELDS {
            return None;
        }
        parsed.push(row.iter().map(parse_field).collect::<Option<Vec<_>>>()?);
    }
    Some(RowLayout { rows: parsed })
}

fn is_activity_glyph(first: char) -> bool {
    ('\u{2800}'..='\u{28FF}').contains(&first) || "·✢✳✶✻✽◐◓◑◒".contains(first)
}

/// Same single-glyph fallback as `Agent.strippedSidebarTitle`: one leading
/// activity glyph is dropped when whitespace (or nothing) follows it.
pub fn stripped_sidebar_title(raw: &str) -> &str {
    let trimmed = jsx::trim(raw);
    let Some(first) = trimmed.chars().next() else {
        return trimmed;
    };
    if !is_activity_glyph(first) {
        return trimmed;
    }
    let rest = &trimmed[first.len_utf8()..];
    if rest.is_empty() || rest.starts_with(jsx::is_js_space) {
        jsx::trim(rest)
    } else {
        trimmed
    }
}

/// The first 80 grapheme clusters of `text`, whole.
fn row_text(text: &str) -> &str {
    text.grapheme_indices(true)
        .nth(ROW_TEXT_LIMIT)
        .map_or(text, |(end, _)| &text[..end])
}

/// Swift's `CharacterSet.whitespacesAndNewlines`: Unicode Z* plus U+0009 to
/// U+000D and U+0085 (NEL). Unlike JS `trim` it keeps U+FEFF, which is a
/// format character, not whitespace.
fn is_edge_whitespace(c: char) -> bool {
    matches!(
        c,
        '\u{9}'..='\u{D}'
            | '\u{85}'
            // Zs, Zl, Zp
            | ' '
            | '\u{A0}'
            | '\u{1680}'
            | '\u{2000}'..='\u{200A}'
            | '\u{2028}'
            | '\u{2029}'
            | '\u{202F}'
            | '\u{205F}'
            | '\u{3000}'
    )
}

/// The row dedupe key: NFC-normalized (canonically equivalent text is equal,
/// like Swift's String ==), then trimmed of Swift's whitespacesAndNewlines;
/// case-sensitive. Empty means the field shows nothing.
pub fn row_key(text: &str) -> Cow<'_, str> {
    if is_nfc(text) {
        Cow::Borrowed(text.trim_matches(is_edge_whitespace))
    } else {
        let normalized: String = text.nfc().collect();
        Cow::Owned(normalized.trim_matches(is_edge_whitespace).to_string())
    }
}

/// The herdr context a layout resolves against. `tabs` and `panes` map an id
/// to herdr's entry (`workspace_id`, `label`, ...); a tab entry also carries
/// the `position` and numeric `count` of its workspace's tabs, which decide
/// whether the `tab` field shows. `host_name` is already the name to show.
pub struct RowContext<'a> {
    pub host_name: &'a str,
    pub workspace_labels: &'a Map<String, Value>,
    pub tabs: &'a Map<String, Value>,
    pub panes: &'a Map<String, Value>,
}

fn lookup<'a>(map: &'a Map<String, Value>, id: Option<&Value>) -> Option<&'a Value> {
    map.get(id?.as_str()?)
}

/// `status.charAt(0).toUpperCase() + status.slice(1)` of the lower-cased
/// status (`charAt` is a UTF-16 unit: an astral first character stays as is).
fn capitalized(status: &str) -> String {
    let lower = status.to_lowercase();
    let mut chars = lower.chars();
    let Some(first) = chars.next() else {
        return lower;
    };
    let mut out = String::with_capacity(lower.len());
    if first.len_utf16() == 1 {
        out.extend(first.to_uppercase());
    } else {
        out.push(first);
    }
    out.push_str(chars.as_str());
    out
}

fn field_value<'a>(
    token: &str,
    agent: &'a Value,
    context: &'a RowContext<'_>,
) -> Option<Cow<'a, str>> {
    let tab = lookup(context.tabs, agent.get("tab_id"));
    let pane = lookup(context.panes, agent.get("pane_id"));
    let workspace = agent.get("workspace_id");
    let matching_tab = tab.filter(|tab| js_strict_eq(tab.get("workspace_id"), workspace));
    let matching_pane = pane.filter(|pane| {
        js_strict_eq(pane.get("workspace_id"), workspace)
            && js_strict_eq(pane.get("tab_id"), agent.get("tab_id"))
    });
    let borrowed = |value: Option<&'a Value>| value.and_then(Value::as_str).map(Cow::Borrowed);
    match token {
        "workspace" => borrowed(lookup(context.workspace_labels, workspace)),
        "tab" => matching_tab.and_then(|tab| {
            // The label is shown unless it is just the tab's default
            // position number and it is the only tab (as the Console does).
            let several = tab
                .get("count")
                .and_then(Value::as_f64)
                .is_some_and(|count| count > 1.0);
            let label = tab.get("label").and_then(Value::as_str)?;
            let position = match tab.get("position") {
                Some(Value::Number(number)) => jsx::number_to_string(crate::jsx::json_f64(number)),
                other => js_to_string(other),
            };
            (several || label != position).then_some(Cow::Borrowed(label))
        }),
        "pane" => match non_null(agent.get("title")) {
            Some(title) => borrowed(Some(title)),
            None => borrowed(js_get_opt(matching_pane, "label")),
        },
        "agent" => optional_text(agent.get("display_agent"))
            .or_else(|| optional_text(agent.get("name")))
            .or_else(|| match non_null(agent.get("agent")) {
                Some(kind) => kind.as_str(),
                None => Some("unknown"),
            })
            .map(Cow::Borrowed),
        "terminal_title" => borrowed(agent.get("terminal_title")),
        "terminal_title_stripped" => match non_null(agent.get("terminal_title_stripped")) {
            Some(stripped) => borrowed(Some(stripped)),
            None => agent
                .get("terminal_title")
                .and_then(Value::as_str)
                .map(|title| Cow::Borrowed(stripped_sidebar_title(title))),
        },
        "host" => Some(Cow::Borrowed(jsx::trim(context.host_name))),
        // The JS throws on a status that is not a string; only eligible
        // Agents (which have one) are ever rendered.
        "status" => agent
            .get("agent_status")
            .and_then(Value::as_str)
            .map(|status| Cow::Owned(capitalized(status))),
        "directory" => agent
            .get("cwd")
            .and_then(Value::as_str)
            .map(|cwd| Cow::Borrowed(jsx::trim(cwd))),
        _ => token
            .strip_prefix('$')
            .and_then(|name| match agent.get("tokens") {
                // `"abc"["0"]` is a one-character string in JS.
                Some(Value::String(text)) => js_string_unit(text, name).map(Cow::Owned),
                other => js_get_opt(other, name)
                    .and_then(Value::as_str)
                    .map(Cow::Borrowed),
            }),
    }
}

/// Resolve `layout` for `agent`: one list of spans per non-empty row; `None`
/// without a layout (the legacy identity rendering). A value equal (by
/// [`row_key`]) to one already shown earlier in the same row is dropped with
/// its separator, as `AgentRowRenderer` does: a herdr worktree Workspace and
/// its tab both carry the branch name (#190).
pub fn render_activity_rows(
    layout: Option<&RowLayout>,
    agent: &Value,
    context: &RowContext<'_>,
) -> Option<Vec<Vec<Span>>> {
    let layout = layout?;
    let rows = layout
        .rows
        .iter()
        .filter_map(|row| {
            let mut spans: Vec<Span> = Vec::new();
            let mut shown: Vec<Cow<'_, str>> = Vec::new();
            for field in row {
                let Some(raw) = field_value(&field.token, agent, context) else {
                    continue;
                };
                let key = match &raw {
                    Cow::Borrowed(text) => row_key(text),
                    Cow::Owned(text) => Cow::Owned(row_key(text).into_owned()),
                };
                if key.is_empty() || shown.contains(&key) {
                    continue;
                }
                shown.push(key);
                if !spans.is_empty() {
                    spans.push(Span {
                        text: SEPARATOR.to_string(),
                        fg: None,
                        bold: None,
                        dim: None,
                    });
                }
                spans.push(Span {
                    text: row_text(&raw).to_string(),
                    fg: field.fg.clone(),
                    bold: field.bold,
                    dim: field.dim,
                });
            }
            (!spans.is_empty()).then_some(spans)
        })
        .collect();
    Some(rows)
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    use crate::activity_state::{BuildInput, build_activity_state};

    fn agent() -> Value {
        json!({
            "pane_id": "opaque:pane", "workspace_id": "workspace", "tab_id": "tab", "agent": "claude",
            "agent_status": "working", "cwd": " /work/Waycar ", "display_agent": "reviewer",
            "terminal_title": "⠂ raw", "terminal_title_stripped": "stripped", "title": null,
            "tokens": { "task": "**plain text**", "blank": "  " },
        })
    }

    fn default_tabs() -> Map<String, Value> {
        let tabs = json!({ "tab": { "workspace_id": "workspace", "label": "1", "position": 1, "count": 1 } });
        tabs.as_object().unwrap().clone()
    }

    struct Overrides {
        agents: Option<Vec<Value>>,
        row_layout: Option<Value>,
        workspace_labels: Option<Map<String, Value>>,
        tabs: Option<Map<String, Value>>,
        panes: Option<Map<String, Value>>,
    }

    impl Overrides {
        fn none() -> Self {
            Self {
                agents: None,
                row_layout: None,
                workspace_labels: None,
                tabs: None,
                panes: None,
            }
        }
    }

    /// The JS test's `render(rows, overrides)`: the first agent's wire entry
    /// from `buildActivityState` with the fixed host, labels, tabs and panes.
    fn render_with(rows: Value, overrides: Overrides) -> Value {
        let rows: Vec<Value> = rows
            .as_array()
            .unwrap()
            .iter()
            .map(|row| {
                Value::Array(
                    row.as_array()
                        .unwrap()
                        .iter()
                        .map(|token| match token {
                            Value::String(_) => json!({ "token": token }),
                            other => other.clone(),
                        })
                        .collect(),
                )
            })
            .collect();
        let layout = overrides
            .row_layout
            .unwrap_or_else(|| json!({ "rows": rows }));
        let agents = overrides.agents.unwrap_or_else(|| vec![agent()]);
        let labels = overrides.workspace_labels.unwrap_or_else(|| {
            json!({ "workspace": "Waycar" })
                .as_object()
                .unwrap()
                .clone()
        });
        let tabs = overrides.tabs.unwrap_or_else(default_tabs);
        let panes = overrides.panes.unwrap_or_else(|| {
            json!({ "opaque:pane": { "workspace_id": "workspace", "tab_id": "tab", "label": "shell" } })
                .as_object()
                .unwrap()
                .clone()
        });
        let parsed = parse_activity_row_layout(Some(&layout));
        let state = build_activity_state(&BuildInput {
            row_layout: parsed.as_ref(),
            row_host_name: Some("My Mac"),
            workspace_labels: &labels,
            tabs: &tabs,
            panes: &panes,
            ..BuildInput::new(&agents, "studio")
        });
        state.plaintext_object["agents"][0].clone()
    }

    fn render(rows: Value) -> Value {
        render_with(rows, Overrides::none())
    }

    // renders the three configured rows with styles, unstyled separators and no empty fields
    #[test]
    fn renders_the_three_configured_rows() {
        let rendered = render(json!([
            ["state_icon", "workspace", "tab", { "token": "agent", "fg": "#AbC", "bold": true, "dim": false }],
            ["pane", "terminal_title", "terminal_title_stripped", "$task", "$blank", "$missing"],
            ["directory", "host", "status", "state_text"],
        ]));
        assert_eq!(
            rendered["rows"],
            json!([
                [{ "text": "Waycar" }, { "text": " · " }, { "text": "reviewer", "fg": "#AbC", "bold": true, "dim": false }],
                [{ "text": "shell" }, { "text": " · " }, { "text": "⠂ raw" }, { "text": " · " }, { "text": "stripped" }, { "text": " · " }, { "text": "**plain text**" }],
                [{ "text": "/work/Waycar" }, { "text": " · " }, { "text": "My Mac" }, { "text": " · " }, { "text": "Working" }],
            ])
        );
    }

    // tab visibility matches Console and unrelated pane context is ignored
    #[test]
    fn tab_visibility_matches_the_console() {
        assert_eq!(render(json!([["tab"]]))["rows"], json!([]));
        let mut tabs = default_tabs();
        tabs["tab"]["count"] = json!(2);
        let overrides = |tabs: &Map<String, Value>| Overrides {
            tabs: Some(tabs.clone()),
            ..Overrides::none()
        };
        assert_eq!(
            render_with(json!([["tab"]]), overrides(&tabs))["rows"],
            json!([[{ "text": "1" }]])
        );
        tabs["tab"]["count"] = json!(1);
        tabs["tab"]["label"] = json!("review");
        assert_eq!(
            render_with(json!([["tab"]]), overrides(&tabs))["rows"],
            json!([[{ "text": "review" }]])
        );
        tabs["tab"]["workspace_id"] = json!("other");
        let both = Overrides {
            tabs: Some(tabs),
            panes: Some(Map::new()),
            ..Overrides::none()
        };
        assert_eq!(
            render_with(json!([["tab", "pane"]]), both)["rows"],
            json!([])
        );
    }

    // pane empty title and stripped empty title do not fall back, unnamed agent uses raw kind
    #[test]
    fn empty_titles_do_not_fall_back_and_unnamed_agent_uses_raw_kind() {
        let mut changed = agent();
        changed["title"] = json!("");
        changed["terminal_title_stripped"] = json!("");
        changed["display_agent"] = json!("");
        changed["name"] = json!("");
        let rendered = render_with(
            json!([["pane", "terminal_title_stripped", "agent"]]),
            Overrides {
                agents: Some(vec![changed]),
                ..Overrides::none()
            },
        );
        assert_eq!(rendered["rows"], json!([[{ "text": "claude" }]]));
    }

    // row values cap at 80 graphemes without splitting joined emoji
    #[test]
    fn row_values_cap_at_80_graphemes_without_splitting_joined_emoji() {
        let emoji = "👨‍👩‍👧‍👦";
        let mut changed = agent();
        changed["cwd"] = json!(emoji.repeat(81));
        let rendered = render_with(
            json!([["directory"]]),
            Overrides {
                agents: Some(vec![changed]),
                ..Overrides::none()
            },
        );
        assert_eq!(rendered["rows"][0][0]["text"], json!(emoji.repeat(80)));
    }

    // missing or malformed layout preserves legacy fallback; explicit empty layout stays empty
    #[test]
    fn malformed_layouts_keep_the_legacy_fallback() {
        let too_wide = json!({ "rows": [vec![json!({ "token": "agent" }); 17]] });
        let layouts = [
            None,
            Some(Value::Null),
            Some(json!({})),
            Some(json!({ "rows": [null] })),
            Some(too_wide),
            Some(json!({ "rows": [[], [], [], []] })),
            Some(json!({ "rows": [[{ "token": "unknown" }]] })),
            Some(json!({ "rows": [[{ "token": "agent", "bold": 1 }]] })),
            Some(json!({ "rows": [[{ "token": "agent", "fg": "red" }]] })),
        ];
        for layout in layouts {
            assert_eq!(parse_activity_row_layout(layout.as_ref()), None);
            // `undefined` (None) and null both leave the rows out of the wire entry.
            let rendered = render_with(
                json!([]),
                Overrides {
                    row_layout: Some(layout.unwrap_or(Value::Null)),
                    ..Overrides::none()
                },
            );
            assert!(rendered.get("rows").is_none(), "{rendered}");
        }
        assert_eq!(render(json!([]))["rows"], json!([]));
    }

    // field truncation preserves the first 80 graphemes without ellipsis or trailing-space trimming
    #[test]
    fn field_truncation_keeps_the_first_80_graphemes_untrimmed() {
        let mut changed = agent();
        changed["tokens"] = json!({ "task": format!("{} y", "x".repeat(79)) });
        let rendered = render_with(
            json!([["$task"]]),
            Overrides {
                agents: Some(vec![changed]),
                ..Overrides::none()
            },
        );
        assert_eq!(
            rendered["rows"][0][0]["text"],
            json!(format!("{} ", "x".repeat(79)))
        );
    }

    // missing stripped title removes one activity glyph only at a whitespace boundary
    #[test]
    fn missing_stripped_title_removes_one_glyph_only_at_a_whitespace_boundary() {
        let cases = [
            ("  ⠂ building  ", Some("building")),
            ("✳\tbuilding", Some("building")),
            ("◐\nbuilding", Some("building")),
            ("⠂building", Some("⠂building")),
            ("✳building", Some("✳building")),
            ("⠂ ⠂ building", Some("⠂ building")),
            ("plain title  ", Some("plain title")),
            ("⠂", None),
            (" · ", None),
        ];
        for (raw, expected) in cases {
            let mut changed = agent();
            changed["terminal_title"] = json!(raw);
            changed["terminal_title_stripped"] = Value::Null;
            let rendered = render_with(
                json!([["terminal_title_stripped"]]),
                Overrides {
                    agents: Some(vec![changed]),
                    ..Overrides::none()
                },
            );
            let want = expected.map_or(json!([]), |text| json!([[{ "text": text }]]));
            assert_eq!(rendered["rows"], want, "{raw}");
        }
        let mut changed = agent();
        changed["terminal_title"] = json!("⠂ building");
        changed["terminal_title_stripped"] = json!("");
        let rendered = render_with(
            json!([["terminal_title_stripped"]]),
            Overrides {
                agents: Some(vec![changed]),
                ..Overrides::none()
            },
        );
        assert_eq!(rendered["rows"], json!([]));
    }

    // a value repeated within a row renders once with no stray separator (#190)
    #[test]
    fn a_value_repeated_within_a_row_renders_once() {
        let layout = json!([["workspace", "tab", "directory"], ["agent"]]);
        let cases: [(&str, &str, &str, &str, &str, Value); 3] = [
            (
                "workspace == tab",
                "more-harnesses",
                "more-harnesses",
                "/w/x",
                "builder",
                json!([[{ "text": "more-harnesses" }, { "text": " · " }, { "text": "/w/x" }], [{ "text": "builder" }]]),
            ),
            (
                "workspace == tab == directory, trimmed",
                "dead-space-meta",
                " dead-space-meta ",
                "dead-space-meta\n",
                "dead-space-meta",
                json!([[{ "text": "dead-space-meta" }], [{ "text": "dead-space-meta" }]]),
            ),
            (
                "distinct and case-sensitive values unchanged",
                "Waycar",
                "waycar",
                "/work/Waycar",
                "reviewer",
                json!([[{ "text": "Waycar" }, { "text": " · " }, { "text": "waycar" }, { "text": " · " }, { "text": "/work/Waycar" }], [{ "text": "reviewer" }]]),
            ),
        ];
        for (name, workspace, tab, cwd, display_agent, expected) in cases {
            let mut changed = agent();
            changed["cwd"] = json!(cwd);
            changed["display_agent"] = json!(display_agent);
            let tabs = json!({ "tab": { "workspace_id": "workspace", "label": tab, "position": 1, "count": 1 } });
            let labels = json!({ "workspace": workspace });
            let rendered = render_with(
                layout.clone(),
                Overrides {
                    agents: Some(vec![changed]),
                    workspace_labels: Some(labels.as_object().unwrap().clone()),
                    tabs: Some(tabs.as_object().unwrap().clone()),
                    ..Overrides::none()
                },
            );
            assert_eq!(rendered["rows"], expected, "{name}");
        }
    }

    // row dedupe keys are NFC-normalized and trimmed like Swift's whitespacesAndNewlines
    #[test]
    fn row_keys_are_nfc_and_swift_trimmed() {
        assert_eq!(row_key("Cafe\u{301}"), row_key("Caf\u{e9}"));
        assert_eq!(row_key("\u{85}\u{a0}Waycar\u{2028}\u{3000}\t"), "Waycar");
        // U+FEFF is a format character, not whitespace.
        assert_eq!(row_key("\u{feff}Waycar"), "\u{feff}Waycar");
        assert_ne!(row_key("Waycar"), row_key("waycar"));
        assert_eq!(row_key(" \n\u{85} "), "");
    }

    #[test]
    fn stripped_sidebar_title_covers_the_trim_edges() {
        assert_eq!(stripped_sidebar_title(""), "");
        assert_eq!(stripped_sidebar_title("\u{feff}✳ a\u{feff}"), "a");
        assert_eq!(stripped_sidebar_title("\u{85}✳ a"), "\u{85}✳ a");
        assert_eq!(stripped_sidebar_title("⣿\u{a0}x"), "x");
    }

    #[test]
    fn row_text_keeps_whole_grapheme_clusters() {
        let flags = "🇯🇵".repeat(81);
        assert_eq!(row_text(&flags), "🇯🇵".repeat(80));
        assert_eq!(row_text("short"), "short");
        let marks = "e\u{301}".repeat(81);
        assert_eq!(row_text(&marks), "e\u{301}".repeat(80));
    }
}
