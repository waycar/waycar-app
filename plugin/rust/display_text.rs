//! Display-string helpers shared by the notify and Live Activity hooks
//! (display-text.js).
//!
//! Agent terminal titles and host labels are whole phrases and run long. The
//! app trims to the same length for display; trimming here keeps encrypted
//! payloads small on the wire too.

use std::borrow::Cow;

use serde_json::Value;

use crate::jsx;

/// Display strings are cut to this many code points (JS `[...text]`: not
/// UTF-16 units and not grapheme clusters), ellipsis included.
pub const DISPLAY_LIMIT: usize = 80;

/// A non-empty string or `None`; the display fields are all best-effort.
pub fn optional_text(value: Option<&Value>) -> Option<&str> {
    value
        .and_then(Value::as_str)
        .filter(|text| !text.is_empty())
}

/// [`for_display_str`] of a JSON value: `None` unless it is a non-empty string.
pub fn for_display(value: Option<&Value>) -> Option<Cow<'_, str>> {
    optional_text(value).map(trim_for_display)
}

/// Trim a display string to [`DISPLAY_LIMIT`] code points, ellipsis included;
/// `None` for an empty one.
pub fn for_display_str(text: &str) -> Option<Cow<'_, str>> {
    (!text.is_empty()).then(|| trim_for_display(text))
}

fn trim_for_display(text: &str) -> Cow<'_, str> {
    // Byte offset of the first code point that does not fit, if any.
    let Some((overflow, _)) = text.char_indices().nth(DISPLAY_LIMIT) else {
        return Cow::Borrowed(text);
    };
    let keep = text
        .char_indices()
        .nth(DISPLAY_LIMIT - 1)
        .map_or(overflow, |(at, _)| at);
    Cow::Owned(format!("{}…", jsx::trim_end(&text[..keep])))
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    fn shown(text: &str) -> String {
        for_display_str(text).unwrap().into_owned()
    }

    #[test]
    fn optional_text_wants_a_non_empty_string() {
        assert_eq!(optional_text(Some(&json!("a"))), Some("a"));
        for none in [json!(""), json!(null), json!(1), json!(["a"]), json!({})] {
            assert_eq!(optional_text(Some(&none)), None, "{none}");
        }
        assert_eq!(optional_text(None), None);
        assert_eq!(for_display(Some(&json!(7))), None);
        assert_eq!(for_display_str(""), None);
    }

    #[test]
    fn text_up_to_the_limit_is_kept_whole() {
        let eighty = "屏".repeat(DISPLAY_LIMIT);
        assert_eq!(shown(&eighty), eighty);
        assert_eq!(shown("short"), "short");
        // Trailing spaces survive when nothing is cut.
        assert_eq!(shown("a  "), "a  ");
    }

    #[test]
    fn longer_text_is_cut_to_79_code_points_and_an_ellipsis() {
        let cut = shown(&"屏".repeat(DISPLAY_LIMIT + 1));
        assert_eq!(cut.chars().count(), DISPLAY_LIMIT);
        assert_eq!(cut, format!("{}…", "屏".repeat(DISPLAY_LIMIT - 1)));
    }

    #[test]
    fn white_space_before_the_cut_is_trimmed_the_javascript_way() {
        let text = format!("{}{}tail-past-the-limit", "a".repeat(70), " ".repeat(20));
        assert_eq!(shown(&text), format!("{}…", "a".repeat(70)));
        // trimEnd takes U+FEFF and U+00A0 but not U+0085 or U+180E.
        let text = format!("{}\u{feff}\u{a0}{}", "b".repeat(77), "z".repeat(10));
        assert_eq!(shown(&text), format!("{}…", "b".repeat(77)));
        let text = format!("{}\u{85}{}", "b".repeat(78), "z".repeat(10));
        assert_eq!(shown(&text), format!("{}\u{85}…", "b".repeat(78)));
    }

    #[test]
    fn a_cut_counts_code_points_not_utf16_units_or_graphemes() {
        // 79 astral characters are 158 UTF-16 units: JS spreads by code point.
        let astral = "😀".repeat(DISPLAY_LIMIT + 1);
        assert_eq!(
            shown(&astral),
            format!("{}…", "😀".repeat(DISPLAY_LIMIT - 1))
        );
        // The 79th code point can split a ZWJ family: JS does not look for
        // grapheme boundaries either (7 code points; 75 + 4 are kept, ending on a joiner).
        let family = "👨‍👩‍👧‍👦";
        assert_eq!(family.chars().count(), 7);
        let text = format!("{}{family}{}", "x".repeat(75), "y".repeat(10));
        assert_eq!(
            shown(&text),
            format!("{}👨\u{200d}👩\u{200d}…", "x".repeat(75))
        );
        // A combining mark at the cut is separated from its base letter.
        let combining = format!("{}e\u{301}{}", "x".repeat(78), "y".repeat(5));
        assert_eq!(shown(&combining), format!("{}e…", "x".repeat(78)));
    }
}
