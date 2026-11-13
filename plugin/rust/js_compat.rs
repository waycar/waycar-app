//! What the hook runtime's JS modules get from the language and Node that
//! [`crate::jsx`] (the shared JS-semantics helpers) does not cover: the UTF-16
//! order of `<` and `Array.prototype.sort`, `localeCompare`, `String(value)`,
//! `Object.fromEntries`, strict equality, `value?.[key]` on arrays and strings
//! and the JSON size of a string, plus reading a JSON file. The hook state
//! files are read by Node and Rust alike, so what is written must be the bytes
//! the JS would have written.

use std::cmp::Ordering;
use std::fs;
use std::path::Path;

use serde_json::{Map, Value};

use crate::jsx;

/// `Number.MAX_SAFE_INTEGER`: the largest integer a JS number holds exactly.
pub const MAX_SAFE_INTEGER: u64 = (1 << 53) - 1;

/// The order of JS `<` on strings and of `Array.prototype.sort()` without a
/// comparator: by UTF-16 code unit, which differs from Rust's byte order
/// (code point order) when an astral character meets one in U+E000..U+FFFF.
pub fn cmp_utf16(left: &str, right: &str) -> Ordering {
    left.encode_utf16().cmp(right.encode_utf16())
}

/// Printable ASCII in ICU root collation order, letters folded to lower case:
/// punctuation and symbols first, then digits, then letters.
const ICU_ASCII_ORDER: &[u8] =
    b" _-,;:!?.'\"()[]{}@*/\\&#%`^+<=>|~$0123456789abcdefghijklmnopqrstuvwxyz";

fn icu_primary(byte: u8) -> usize {
    let folded = byte.to_ascii_lowercase();
    ICU_ASCII_ORDER
        .iter()
        .position(|&b| b == folded)
        .unwrap_or(ICU_ASCII_ORDER.len())
}

fn is_printable_ascii(text: &str) -> bool {
    text.bytes().all(|b| (0x20..=0x7E).contains(&b))
}

/// `left.localeCompare(right)` with no locale (ICU root collation, what Node
/// uses when `LANG` is unset or `C`).
///
/// Exact for printable ASCII on both sides: the primary weights decide
/// (case-insensitive), then a lower-case letter sorts before its upper-case
/// form at the first position that differs. Any other string falls back to
/// [`cmp_utf16`]: ICU's full ordering (accents, ignorable controls, scripts)
/// is not implemented. The only callers sort device tokens, which the app
/// writes as lower-case hex.
pub fn locale_compare(left: &str, right: &str) -> Ordering {
    if !is_printable_ascii(left) || !is_printable_ascii(right) {
        return cmp_utf16(left, right);
    }
    let primary = left
        .bytes()
        .map(icu_primary)
        .cmp(right.bytes().map(icu_primary));
    if primary != Ordering::Equal {
        return primary;
    }
    left.bytes()
        .zip(right.bytes())
        .find(|(a, b)| a != b)
        .map_or(Ordering::Equal, |(a, _)| {
            if a.is_ascii_lowercase() {
                Ordering::Less
            } else {
                Ordering::Greater
            }
        })
}

/// `Number.isInteger(value)` for a value that was JSON.
pub fn js_integer(value: Option<&Value>) -> Option<f64> {
    let value = value.filter(|value| jsx::is_integer(value))?;
    value.as_number().map(jsx::json_f64)
}

/// `Object.fromEntries(entries)`: a repeated key keeps its first position
/// and takes the last value; array-index keys move to the front.
pub fn js_object(entries: impl IntoIterator<Item = (String, Value)>) -> Map<String, Value> {
    let mut map = Map::new();
    for (key, value) in entries {
        map.insert(key, value);
    }
    if map.keys().any(|key| jsx::array_index(key).is_some()) {
        let ordered: Vec<(String, Value)> = jsx::ordered_entries(&map)
            .into_iter()
            .map(|(key, value)| (key.clone(), value.clone()))
            .collect();
        return ordered.into_iter().collect();
    }
    map
}

/// The UTF-8 size of `JSON.stringify(text)` without its quotes.
pub fn json_escaped_len(text: &str) -> usize {
    text.chars()
        .map(|c| match c {
            '"' | '\\' | '\u{8}' | '\u{C}' | '\n' | '\r' | '\t' => 2,
            c if c < ' ' => 6,
            c => c.len_utf8(),
        })
        .sum()
}

/// `String(value)` for a value that was JSON (`None` is `undefined`).
pub fn js_to_string(value: Option<&Value>) -> String {
    match value {
        None => "undefined".to_string(),
        Some(Value::Null) => "null".to_string(),
        Some(Value::Bool(flag)) => flag.to_string(),
        Some(Value::Number(number)) => jsx::number_to_string(jsx::json_f64(number)),
        Some(Value::String(text)) => text.clone(),
        Some(Value::Array(items)) => items
            .iter()
            .map(|item| match item {
                Value::Null => String::new(),
                item => js_to_string(Some(item)),
            })
            .collect::<Vec<_>>()
            .join(","),
        Some(Value::Object(_)) => "[object Object]".to_string(),
    }
}

/// `a === b` for values that were JSON (`None` is `undefined`). Numbers
/// compare as the doubles JS holds; an object or array is only ever equal to
/// itself, and two parsed values are never the same object.
pub fn js_strict_eq(left: Option<&Value>, right: Option<&Value>) -> bool {
    match (left, right) {
        (None, None) | (Some(Value::Null), Some(Value::Null)) => true,
        (Some(Value::Bool(a)), Some(Value::Bool(b))) => a == b,
        (Some(Value::Number(a)), Some(Value::Number(b))) => jsx::json_f64(a) == jsx::json_f64(b),
        (Some(Value::String(a)), Some(Value::String(b))) => a == b,
        _ => false,
    }
}

/// `value?.[key]`: a property of an object, an element of an array, a
/// character of a string; `None` for `undefined`.
pub fn js_get<'a>(value: &'a Value, key: &str) -> Option<&'a Value> {
    match value {
        Value::Object(map) => map.get(key),
        Value::Array(items) => jsx::array_index(key).and_then(|index| items.get(index as usize)),
        _ => None,
    }
}

/// `text[key]` for a string: the one UTF-16 unit at an array-index key, as a
/// string. `None` when there is no such unit or it is half a surrogate pair
/// (a lone surrogate is not a Rust string).
pub fn js_string_unit(text: &str, key: &str) -> Option<String> {
    let index = jsx::array_index(key)? as usize;
    let unit = text.encode_utf16().nth(index)?;
    char::from_u32(u32::from(unit)).map(String::from)
}

/// `value ?? undefined`-style read of `value?.[key]` where `value` may be
/// missing.
pub fn js_get_opt<'a>(value: Option<&'a Value>, key: &str) -> Option<&'a Value> {
    value.and_then(|value| js_get(value, key))
}

/// `value ?? fallback` for a read: `null` is as good as `undefined`.
pub fn non_null(value: Option<&Value>) -> Option<&Value> {
    value.filter(|v| !v.is_null())
}

/// The parsed JSON of a file, `None` when it is missing, unreadable or not
/// JSON (`try { JSON.parse(readFileSync(path, "utf8")) } catch`). Invalid
/// UTF-8 reads as U+FFFD, as Node's decoder does.
pub fn read_json(path: &Path) -> Option<Value> {
    let bytes = fs::read(path).ok()?;
    serde_json::from_str(&String::from_utf8_lossy(&bytes)).ok()
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn json_strings_escape_and_measure_like_stringify() {
        let text = "a\"b\\c\n\r\t\u{8}\u{c}\u{1}\u{1f}\u{7f}\u{2028}é\u{1F642}";
        let mut out = String::new();
        jsx::write_json_string(text, &mut out);
        assert_eq!(
            out,
            "\"a\\\"b\\\\c\\n\\r\\t\\b\\f\\u0001\\u001f\u{7f}\u{2028}é\u{1F642}\""
        );
        assert_eq!(json_escaped_len(text), out.len() - 2);
        assert_eq!(json_escaped_len("a\"\u{1}é\u{1F642}"), 1 + 2 + 6 + 2 + 4);
    }

    #[test]
    fn utf16_order_puts_astral_before_high_bmp() {
        assert_eq!(cmp_utf16("\u{1F600}", "\u{FF5E}"), Ordering::Less);
        assert_eq!("\u{1F600}".cmp("\u{FF5E}"), Ordering::Greater);
        assert_eq!(cmp_utf16("ab", "abc"), Ordering::Less);
    }

    #[test]
    fn to_string_follows_javascript() {
        assert_eq!(js_to_string(None), "undefined");
        assert_eq!(js_to_string(Some(&json!(null))), "null");
        assert_eq!(js_to_string(Some(&json!([1, [2, null], "x"]))), "1,2,,x");
        assert_eq!(js_to_string(Some(&json!({"a": 1}))), "[object Object]");
        assert_eq!(js_to_string(Some(&json!(2.0))), "2");
        // A JSON number is a double: big integers round as `JSON.parse` rounds them.
        assert_eq!(
            js_to_string(Some(&json!(9007199254740993u64))),
            "9007199254740992"
        );
    }

    #[test]
    fn object_from_entries_orders_index_keys_first() {
        let map = js_object([
            ("b".to_string(), json!(1)),
            ("9".to_string(), json!(2)),
            ("b".to_string(), json!(3)),
            ("10".to_string(), json!(4)),
        ]);
        let keys: Vec<&String> = map.keys().collect();
        assert_eq!(keys, ["9", "10", "b"]);
        assert_eq!(map["b"], json!(3));
    }

    #[test]
    fn locale_compare_is_icu_root_for_printable_ascii() {
        assert_eq!(locale_compare("a", "B"), Ordering::Less);
        assert_eq!(locale_compare("a", "A"), Ordering::Less);
        assert_eq!(locale_compare("A", "a"), Ordering::Greater);
        assert_eq!(locale_compare("ab", "Aa"), Ordering::Greater);
        assert_eq!(locale_compare("aB", "Ab"), Ordering::Less);
        assert_eq!(locale_compare("_", "-"), Ordering::Less);
        assert_eq!(locale_compare("~", "0"), Ordering::Less);
        assert_eq!(locale_compare("9", "a"), Ordering::Less);
        assert_eq!(locale_compare("same", "same"), Ordering::Equal);
    }

    #[test]
    fn strict_equality_and_property_reads() {
        assert!(js_strict_eq(Some(&json!(3)), Some(&json!(3.0))));
        assert!(js_strict_eq(None, None));
        assert!(!js_strict_eq(None, Some(&Value::Null)));
        assert!(!js_strict_eq(Some(&json!([])), Some(&json!([]))));
        assert_eq!(js_get(&json!(["x"]), "0"), Some(&json!("x")));
        assert_eq!(js_get(&json!("abc"), "0"), None);
    }
}
