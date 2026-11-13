//! `JSON.parse`, `JSON.stringify` and the JS object model they work on, as
//! V8 does them.
//!
//! The hook files are read and written as JSON by JS code whose output must
//! come back byte for byte, so the value type follows JS rather than serde:
//!
//! * an object keeps the JS own-key order: array-index keys (`"0"`, `"17"`)
//!   first and ascending, every other key in insertion order; assigning to a
//!   key that exists keeps its place, and a duplicate key in the text keeps
//!   the first position and the last value;
//! * a number is an `f64` and prints as `Number.prototype.toString` does
//!   (`1.0` is `1`, `1e21` is `1e+21`, `-0` is `0`, `NaN` and `Infinity` are
//!   `null`);
//! * a parse error carries V8's own message (Node 22 and later, with the
//!   `(line L column C)` suffix) and UTF-16 positions.
//!
//! Not mirrored: a string holding a lone surrogate (`"\ud800"`) cannot live
//! in a Rust string, so [`parse`] reports it as an error, and nesting deeper
//! than [`MAX_DEPTH`] fails where V8 would parse it.

use std::collections::HashMap;

use crate::jsx;

/// V8's parser is iterative; this one recurses, so it stops here instead of
/// overflowing the stack. No real config file nests anywhere near this deep.
pub const MAX_DEPTH: usize = 2000;
const STACK_OVERFLOW: &str = "Maximum call stack size exceeded";

#[derive(Debug, Clone)]
pub enum Json {
    Null,
    Bool(bool),
    Num(f64),
    Str(String),
    Arr(Vec<Json>),
    Obj(Obj),
}

/// A JS plain object whose keys are strings (see the module doc for order).
#[derive(Debug, Clone, Default)]
pub struct Obj(Vec<(String, Json)>);

impl Obj {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn get(&self, key: &str) -> Option<&Json> {
        self.0.iter().find(|(k, _)| k == key).map(|(_, v)| v)
    }

    pub fn contains_key(&self, key: &str) -> bool {
        self.get(key).is_some()
    }

    /// `obj[key] = value`: replace in place, else add where JS would list it.
    pub fn set(&mut self, key: impl Into<String>, value: Json) {
        let key = key.into();
        if let Some(slot) = self.0.iter_mut().find(|(k, _)| *k == key) {
            slot.1 = value;
            return;
        }
        match jsx::array_index(&key) {
            None => self.0.push((key, value)),
            Some(index) => {
                let at = self
                    .0
                    .iter()
                    .position(|(k, _)| jsx::array_index(k).is_none_or(|other| other > index))
                    .unwrap_or(self.0.len());
                self.0.insert(at, (key, value));
            }
        }
    }

    /// `delete obj[key]`.
    pub fn remove(&mut self, key: &str) {
        self.0.retain(|(k, _)| k != key);
    }

    pub fn iter(&self) -> impl Iterator<Item = (&str, &Json)> {
        self.0.iter().map(|(k, v)| (k.as_str(), v))
    }

    pub fn keys(&self) -> impl Iterator<Item = &str> {
        self.0.iter().map(|(k, _)| k.as_str())
    }

    pub fn len(&self) -> usize {
        self.0.len()
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    /// `util.isDeepStrictEqual` of two objects: key order does not matter.
    pub fn deep_equals(&self, other: &Obj) -> bool {
        self.len() == other.len()
            && self
                .iter()
                .all(|(key, value)| other.get(key).is_some_and(|found| deep_equal(value, found)))
    }

    /// Entries from a parse: duplicates already folded, keys in JS order.
    fn from_parsed(mut entries: Vec<(String, Json)>) -> Self {
        // Stable, so the non-index keys keep their order.
        entries.sort_by_key(|(key, _)| jsx::array_index(key).map_or((1, 0), |index| (0, index)));
        Self(entries)
    }
}

impl Json {
    pub fn str(text: impl Into<String>) -> Self {
        Self::Str(text.into())
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            Self::Str(text) => Some(text),
            _ => None,
        }
    }

    pub fn as_array(&self) -> Option<&Vec<Json>> {
        match self {
            Self::Arr(items) => Some(items),
            _ => None,
        }
    }

    pub fn as_object(&self) -> Option<&Obj> {
        match self {
            Self::Obj(object) => Some(object),
            _ => None,
        }
    }

    /// `value?.key`: the property of an object, `None` for anything else.
    pub fn get(&self, key: &str) -> Option<&Json> {
        self.as_object().and_then(|object| object.get(key))
    }

    /// `JSON.stringify(value)`.
    pub fn to_compact(&self) -> String {
        let mut out = String::new();
        write_value(&mut out, self, None, 0);
        out
    }

    /// `JSON.stringify(value, null, 2)`.
    pub fn to_pretty(&self) -> String {
        let mut out = String::new();
        write_value(&mut out, self, Some(2), 0);
        out
    }
}

/// `util.isDeepStrictEqual` on parsed JSON: object key order is ignored,
/// numbers compare as `Object.is` (so `-0` differs from `0`).
pub fn deep_equal(a: &Json, b: &Json) -> bool {
    match (a, b) {
        (Json::Null, Json::Null) => true,
        (Json::Bool(x), Json::Bool(y)) => x == y,
        (Json::Num(x), Json::Num(y)) => x.to_bits() == y.to_bits() || (x.is_nan() && y.is_nan()),
        (Json::Str(x), Json::Str(y)) => x == y,
        (Json::Arr(x), Json::Arr(y)) => {
            x.len() == y.len() && x.iter().zip(y).all(|(p, q)| deep_equal(p, q))
        }
        (Json::Obj(x), Json::Obj(y)) => x.deep_equals(y),
        _ => false,
    }
}

/// `JSON.stringify` of a string: quoted, with the escapes JSON requires (a
/// well-formed `JSON.stringify` leaves U+2028, U+2029 and DEL as they are).
pub fn quote(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 2);
    jsx::write_json_string(text, &mut out);
    out
}

fn write_indent(out: &mut String, indent: usize, depth: usize) {
    out.push('\n');
    out.extend(std::iter::repeat_n(' ', indent * depth));
}

fn write_value(out: &mut String, value: &Json, indent: Option<usize>, depth: usize) {
    match value {
        Json::Null => out.push_str("null"),
        Json::Bool(flag) => out.push_str(if *flag { "true" } else { "false" }),
        Json::Num(x) if x.is_finite() => out.push_str(&jsx::number_to_string(*x)),
        Json::Num(_) => out.push_str("null"),
        Json::Str(text) => jsx::write_json_string(text, out),
        Json::Arr(items) if items.is_empty() => out.push_str("[]"),
        Json::Arr(items) => {
            out.push('[');
            for (i, item) in items.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                if let Some(width) = indent {
                    write_indent(out, width, depth + 1);
                }
                write_value(out, item, indent, depth + 1);
            }
            if let Some(width) = indent {
                write_indent(out, width, depth);
            }
            out.push(']');
        }
        Json::Obj(object) if object.is_empty() => out.push_str("{}"),
        Json::Obj(object) => {
            out.push('{');
            for (i, (key, item)) in object.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                if let Some(width) = indent {
                    write_indent(out, width, depth + 1);
                }
                jsx::write_json_string(key, out);
                out.push(':');
                if indent.is_some() {
                    out.push(' ');
                }
                write_value(out, item, indent, depth + 1);
            }
            if let Some(width) = indent {
                write_indent(out, width, depth);
            }
            out.push('}');
        }
    }
}

// MARK: - Parsing

/// `JSON.parse(text)`; the error is V8's message.
pub fn parse(text: &str) -> Result<Json, String> {
    let units: Vec<u16> = text.encode_utf16().collect();
    let mut parser = Parser {
        src: &units,
        pos: 0,
    };
    let value = parser.value(0)?;
    if parser.peek() != Token::Eos {
        return Err(parser.error_at(Token::Eos, Some(Message::NonWhitespaceAfter)));
    }
    Ok(value)
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Token {
    Eos,
    Str,
    Num,
    LBrace,
    RBrace,
    LBrack,
    RBrack,
    Colon,
    Comma,
    True,
    False,
    Null,
    Illegal,
}

/// The messages V8 gives for a parse error at a known position.
#[derive(Clone, Copy)]
enum Message {
    PropNameOrRBrace,
    ColonAfterPropName,
    CommaOrRBrack,
    CommaOrRBrace,
    DoubleQuotedPropName,
    NonWhitespaceAfter,
    UnterminatedString,
    BadControl,
    BadEscape,
    BadUnicode,
    NoNumberAfterMinus,
    UnterminatedFraction,
    ExponentMissing,
}

impl Message {
    fn text(self) -> &'static str {
        match self {
            Self::PropNameOrRBrace => "Expected property name or '}' in JSON",
            Self::ColonAfterPropName => "Expected ':' after property name in JSON",
            Self::CommaOrRBrack => "Expected ',' or ']' after array element in JSON",
            Self::CommaOrRBrace => "Expected ',' or '}' after property value in JSON",
            Self::DoubleQuotedPropName => "Expected double-quoted property name in JSON",
            Self::NonWhitespaceAfter => "Unexpected non-whitespace character after JSON",
            Self::UnterminatedString => "Unterminated string in JSON",
            Self::BadControl => "Bad control character in string literal in JSON",
            Self::BadEscape => "Bad escaped character in JSON",
            Self::BadUnicode => "Bad Unicode escape in JSON",
            Self::NoNumberAfterMinus => "No number after minus sign in JSON",
            Self::UnterminatedFraction => "Unterminated fractional number in JSON",
            Self::ExponentMissing => "Exponent part is missing a number in JSON",
        }
    }
}

const CONTEXT_CHARS: usize = 10;
const MIN_LENGTH_FOR_CONTEXT: usize = CONTEXT_CHARS * 2 + 1;

struct Parser<'a> {
    src: &'a [u16],
    pos: usize,
}

impl Parser<'_> {
    fn unit(&self) -> Option<u16> {
        self.src.get(self.pos).copied()
    }

    fn skip_whitespace(&mut self) {
        while matches!(self.unit(), Some(0x20 | 0x09 | 0x0a | 0x0d)) {
            self.pos += 1;
        }
    }

    fn token_of(unit: Option<u16>) -> Token {
        match unit {
            None => Token::Eos,
            Some(0x22) => Token::Str,
            Some(0x2d | 0x30..=0x39) => Token::Num,
            Some(0x7b) => Token::LBrace,
            Some(0x7d) => Token::RBrace,
            Some(0x5b) => Token::LBrack,
            Some(0x5d) => Token::RBrack,
            Some(0x3a) => Token::Colon,
            Some(0x2c) => Token::Comma,
            Some(0x74) => Token::True,
            Some(0x66) => Token::False,
            Some(0x6e) => Token::Null,
            Some(_) => Token::Illegal,
        }
    }

    fn peek(&mut self) -> Token {
        self.skip_whitespace();
        Self::token_of(self.unit())
    }

    /// Consume the next token when it is `token` (V8's `Check`).
    fn check(&mut self, token: Token) -> bool {
        if self.peek() == token {
            self.pos += 1;
            true
        } else {
            false
        }
    }

    fn expect(&mut self, token: Token, message: Message) -> Result<(), String> {
        if self.peek() == token {
            self.pos += 1;
            Ok(())
        } else {
            let found = self.peek();
            Err(self.error_at(found, Some(message)))
        }
    }

    fn lossy(units: &[u16]) -> String {
        String::from_utf16_lossy(units)
    }

    /// `(line L column C)` for the current position; `\r\n` is one break.
    fn line_column(&self) -> (usize, usize) {
        let end = self.pos.min(self.src.len());
        let mut line = 1;
        let mut last_break = 0;
        let mut i = 0;
        while i < end {
            if self.src[i] == 0x0d && i + 1 < end && self.src[i + 1] == 0x0a {
                i += 1;
            }
            if self.src[i] == 0x0d || self.src[i] == 0x0a {
                line += 1;
                last_break = i + 1;
            }
            i += 1;
        }
        (line, 1 + i - last_break)
    }

    /// V8's `ReportUnexpectedToken`: the message for `token` at the current
    /// position, or the given positional one.
    fn error_at(&self, token: Token, message: Option<Message>) -> String {
        if let Some(message) = message {
            let (line, column) = self.line_column();
            return format!(
                "{} at position {} (line {line} column {column})",
                message.text(),
                self.pos
            );
        }
        match token {
            Token::Eos => "Unexpected end of JSON input".into(),
            Token::Num | Token::Str => {
                let (line, column) = self.line_column();
                let what = if token == Token::Num {
                    "number"
                } else {
                    "string"
                };
                format!(
                    "Unexpected {what} in JSON at position {} (line {line} column {column})",
                    self.pos
                )
            }
            _ => self.unexpected_token_text(),
        }
    }

    fn unexpected_token_text(&self) -> String {
        let whole = Self::lossy(self.src);
        if matches!(
            whole.as_str(),
            "NaN" | "Infinity" | "undefined" | "[object Object]"
        ) {
            return format!("\"{whole}\" is not valid JSON");
        }
        let token = Self::lossy(&self.src[self.pos..self.pos + 1]);
        let length = self.src.len();
        if length < MIN_LENGTH_FOR_CONTEXT {
            return format!("Unexpected token '{token}', \"{whole}\" is not valid JSON");
        }
        let pos = self.pos;
        if pos < CONTEXT_CHARS {
            let part = Self::lossy(&self.src[..pos + CONTEXT_CHARS]);
            format!("Unexpected token '{token}', \"{part}\"... is not valid JSON")
        } else if pos < length - CONTEXT_CHARS {
            let part = Self::lossy(&self.src[pos - CONTEXT_CHARS..pos + CONTEXT_CHARS]);
            format!("Unexpected token '{token}', ...\"{part}\"... is not valid JSON")
        } else {
            let part = Self::lossy(&self.src[pos - CONTEXT_CHARS..]);
            format!("Unexpected token '{token}', ...\"{part}\" is not valid JSON")
        }
    }

    fn fail<T>(&self, message: Message) -> Result<T, String> {
        Err(self.error_at(Token::Illegal, Some(message)))
    }

    fn value(&mut self, depth: usize) -> Result<Json, String> {
        let token = self.peek();
        match token {
            Token::Str => {
                self.pos += 1;
                Ok(Json::Str(self.string()?))
            }
            Token::Num => self.number(),
            Token::LBrace => {
                if depth >= MAX_DEPTH {
                    return Err(STACK_OVERFLOW.into());
                }
                self.pos += 1;
                self.object(depth)
            }
            Token::LBrack => {
                if depth >= MAX_DEPTH {
                    return Err(STACK_OVERFLOW.into());
                }
                self.pos += 1;
                self.array(depth)
            }
            Token::True => self.literal("true").map(|()| Json::Bool(true)),
            Token::False => self.literal("false").map(|()| Json::Bool(false)),
            Token::Null => self.literal("null").map(|()| Json::Null),
            Token::Colon
            | Token::Comma
            | Token::Illegal
            | Token::RBrace
            | Token::RBrack
            | Token::Eos => Err(self.error_at(token, None)),
        }
    }

    fn literal(&mut self, word: &str) -> Result<(), String> {
        let word = word.as_bytes();
        // The first letter chose the token; the rest must follow exactly.
        self.pos += 1;
        for expected in &word[1..] {
            match self.unit() {
                Some(unit) if unit == u16::from(*expected) => self.pos += 1,
                other => return Err(self.error_at(Self::token_of(other), None)),
            }
        }
        Ok(())
    }

    fn array(&mut self, depth: usize) -> Result<Json, String> {
        let mut items = Vec::new();
        if self.check(Token::RBrack) {
            return Ok(Json::Arr(items));
        }
        loop {
            items.push(self.value(depth + 1)?);
            if self.check(Token::Comma) {
                continue;
            }
            self.expect(Token::RBrack, Message::CommaOrRBrack)?;
            return Ok(Json::Arr(items));
        }
    }

    fn object(&mut self, depth: usize) -> Result<Json, String> {
        let mut entries: Vec<(String, Json)> = Vec::new();
        let mut index: HashMap<String, usize> = HashMap::new();
        if self.check(Token::RBrace) {
            return Ok(Json::Obj(Obj::new()));
        }
        let mut first = true;
        loop {
            self.expect(
                Token::Str,
                if first {
                    Message::PropNameOrRBrace
                } else {
                    Message::DoubleQuotedPropName
                },
            )?;
            first = false;
            let key = self.string()?;
            self.expect(Token::Colon, Message::ColonAfterPropName)?;
            let value = self.value(depth + 1)?;
            match index.get(&key) {
                Some(at) => entries[*at].1 = value,
                None => {
                    index.insert(key.clone(), entries.len());
                    entries.push((key, value));
                }
            }
            if self.check(Token::Comma) {
                continue;
            }
            self.expect(Token::RBrace, Message::CommaOrRBrace)?;
            return Ok(Json::Obj(Obj::from_parsed(entries)));
        }
    }

    fn hex_digit(unit: Option<u16>) -> Option<u32> {
        let unit = unit?;
        char::from_u32(u32::from(unit))?.to_digit(16)
    }

    /// The string body after its opening quote.
    fn string(&mut self) -> Result<String, String> {
        let mut out: Vec<u16> = Vec::new();
        loop {
            let Some(unit) = self.unit() else {
                return self.fail(Message::UnterminatedString);
            };
            match unit {
                0x22 => {
                    self.pos += 1;
                    return String::from_utf16(&out).map_err(|_| {
                        "a string holding a lone surrogate escape cannot be read".to_string()
                    });
                }
                0x5c => {
                    self.pos += 1;
                    let plain = match self.unit() {
                        Some(0x22) => 0x22,
                        Some(0x5c) => 0x5c,
                        Some(0x2f) => 0x2f,
                        Some(0x62) => 0x08,
                        Some(0x66) => 0x0c,
                        Some(0x6e) => 0x0a,
                        Some(0x72) => 0x0d,
                        Some(0x74) => 0x09,
                        Some(0x75) => {
                            let mut value: u32 = 0;
                            for _ in 0..4 {
                                self.pos += 1;
                                let Some(digit) = Self::hex_digit(self.unit()) else {
                                    return self.fail(Message::BadUnicode);
                                };
                                value = value * 16 + digit;
                            }
                            value as u16
                        }
                        // A backslash ending the input reads as plain end of input, one before a
                        // non-Latin-1 unit as an unexpected token.
                        None => return Err(self.error_at(Token::Eos, None)),
                        Some(unit) if unit > 0xff => {
                            return Err(self.error_at(Token::Illegal, None));
                        }
                        _ => return self.fail(Message::BadEscape),
                    };
                    out.push(plain);
                    self.pos += 1;
                }
                0..=0x1f => return self.fail(Message::BadControl),
                other => {
                    out.push(other);
                    self.pos += 1;
                }
            }
        }
    }

    fn digit_at(&self) -> bool {
        matches!(self.unit(), Some(0x30..=0x39))
    }

    fn skip_digits(&mut self) {
        while self.digit_at() {
            self.pos += 1;
        }
    }

    fn number(&mut self) -> Result<Json, String> {
        let start = self.pos;
        if self.unit() == Some(0x2d) {
            self.pos += 1;
        }
        if self.unit() == Some(0x30) {
            self.pos += 1;
            if self.digit_at() {
                return Err(self.error_at(Token::Num, None));
            }
        } else if self.digit_at() {
            self.skip_digits();
        } else {
            return self.fail(Message::NoNumberAfterMinus);
        }
        if self.unit() == Some(0x2e) {
            self.pos += 1;
            if !self.digit_at() {
                return self.fail(Message::UnterminatedFraction);
            }
            self.skip_digits();
        }
        if matches!(self.unit(), Some(0x65 | 0x45)) {
            self.pos += 1;
            if matches!(self.unit(), Some(0x2b | 0x2d)) {
                self.pos += 1;
            }
            if !self.digit_at() {
                return self.fail(Message::ExponentMissing);
            }
            self.skip_digits();
        }
        let text: String = self.src[start..self.pos]
            .iter()
            .map(|unit| char::from(*unit as u8))
            .collect();
        // The grammar above only lets ASCII digits, signs, `.` and `e` through.
        Ok(Json::Num(text.parse::<f64>().unwrap_or(f64::NAN)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pretty(text: &str) -> String {
        parse(text).unwrap().to_pretty()
    }

    #[test]
    fn numbers_print_as_javascript_does() {
        for (text, printed) in [
            ("1.0", "1"),
            ("-0", "0"),
            ("-0.0", "0"),
            ("1e21", "1e+21"),
            ("1e20", "100000000000000000000"),
            ("123456789012345678901234", "1.2345678901234569e+23"),
            ("12345678901234567890", "12345678901234567000"),
            ("0.000001", "0.000001"),
            ("0.0000001", "1e-7"),
            ("1.5e300", "1.5e+300"),
            ("5e-324", "5e-324"),
            ("0.1", "0.1"),
            ("100", "100"),
            ("1E2", "100"),
            ("4294967295", "4294967295"),
            ("1e400", "null"),
            ("-1e400", "null"),
        ] {
            assert_eq!(parse(text).unwrap().to_compact(), printed, "{text}");
        }
    }

    #[test]
    fn pretty_form_matches_json_stringify() {
        assert_eq!(pretty("{}"), "{}");
        assert_eq!(pretty("[]"), "[]");
        assert_eq!(
            pretty(r#"{"a":[],"b":{},"c":[1,{"d":null}]}"#),
            "{\n  \"a\": [],\n  \"b\": {},\n  \"c\": [\n    1,\n    {\n      \"d\": null\n    }\n  ]\n}"
        );
        assert_eq!(
            parse(r#"{"a": [1, true]}"#).unwrap().to_compact(),
            r#"{"a":[1,true]}"#
        );
    }

    #[test]
    fn keys_keep_javascript_order() {
        assert_eq!(
            parse(r#"{"b":1,"10":2,"a":3,"9":4,"01":5,"4294967295":6,"4294967294":7}"#)
                .unwrap()
                .to_compact(),
            r#"{"9":4,"10":2,"4294967294":7,"b":1,"a":3,"01":5,"4294967295":6}"#
        );
        // A duplicate keeps the first position and the last value.
        assert_eq!(
            parse(r#"{"a":1,"b":2,"a":3}"#).unwrap().to_compact(),
            r#"{"a":3,"b":2}"#
        );
        let mut object = Obj::new();
        object.set("x", Json::Null);
        object.set("2", Json::Null);
        object.set("1", Json::Null);
        object.set("x", Json::Bool(true));
        assert_eq!(
            Json::Obj(object).to_compact(),
            r#"{"1":null,"2":null,"x":true}"#
        );
    }

    #[test]
    fn strings_escape_as_javascript_does() {
        let text = "a\"b\\c\u{8}\t\n\u{c}\r\u{1}\u{1f}\u{7f}\u{2028}é😀";
        assert_eq!(
            quote(text),
            "\"a\\\"b\\\\c\\b\\t\\n\\f\\r\\u0001\\u001f\u{7f}\u{2028}é😀\""
        );
        assert_eq!(
            parse(r#""\ud83d\ude00 \u00e9 \/ \u0000""#)
                .unwrap()
                .as_str(),
            Some("😀 é / \u{0}")
        );
        assert!(parse(r#""\ud800""#).is_err());
    }

    #[test]
    fn deep_equal_follows_is_deep_strict_equal() {
        let a = parse(r#"{"a":1,"b":[1,2,{"c":null}]}"#).unwrap();
        let b = parse(r#"{"b":[1,2,{"c":null}],"a":1.0}"#).unwrap();
        assert!(deep_equal(&a, &b));
        assert!(!deep_equal(&parse("0").unwrap(), &parse("-0").unwrap()));
        assert!(!deep_equal(
            &parse("[1]").unwrap(),
            &parse("[1,2]").unwrap()
        ));
        assert!(!deep_equal(&parse("{}").unwrap(), &parse("[]").unwrap()));
        assert!(!deep_equal(
            &parse(r#"{"a":1}"#).unwrap(),
            &parse(r#"{"b":1}"#).unwrap()
        ));
    }

    #[test]
    fn parse_errors_carry_v8_messages() {
        for (text, message) in [
            ("", "Unexpected end of JSON input"),
            (
                "{",
                "Expected property name or '}' in JSON at position 1 (line 1 column 2)",
            ),
            (
                "{\"a\"",
                "Expected ':' after property name in JSON at position 4 (line 1 column 5)",
            ),
            (
                "{\"a\":1",
                "Expected ',' or '}' after property value in JSON at position 6 (line 1 column 7)",
            ),
            (
                "{\"a\":1,",
                "Expected double-quoted property name in JSON at position 7 (line 1 column 8)",
            ),
            ("[1,]", "Unexpected token ']', \"[1,]\" is not valid JSON"),
            (
                "[1 2]",
                "Expected ',' or ']' after array element in JSON at position 3 (line 1 column 4)",
            ),
            ("undefined", "\"undefined\" is not valid JSON"),
            (
                "{ not json",
                "Expected property name or '}' in JSON at position 2 (line 1 column 3)",
            ),
            (
                "\"abc",
                "Unterminated string in JSON at position 4 (line 1 column 5)",
            ),
            (
                "\"a\nb\"",
                "Bad control character in string literal in JSON at position 2 (line 1 column 3)",
            ),
            (
                "\"\\x\"",
                "Bad escaped character in JSON at position 2 (line 1 column 3)",
            ),
            (
                "\"\\u12\"",
                "Bad Unicode escape in JSON at position 5 (line 1 column 6)",
            ),
            (
                "-",
                "No number after minus sign in JSON at position 1 (line 1 column 2)",
            ),
            (
                "01",
                "Unexpected number in JSON at position 1 (line 1 column 2)",
            ),
            (
                "1.",
                "Unterminated fractional number in JSON at position 2 (line 1 column 3)",
            ),
            (
                "1e+",
                "Exponent part is missing a number in JSON at position 3 (line 1 column 4)",
            ),
            (
                "[1] x",
                "Unexpected non-whitespace character after JSON at position 4 (line 1 column 5)",
            ),
            (
                "{\"abcdefghijklmnopqrstuvwxyz\":}",
                "Unexpected token '}', ...\"stuvwxyz\":}\" is not valid JSON",
            ),
            (
                "{\n  \"a\": 1,\n  \"b\": ,\n}",
                "Unexpected token ',', ...\"1,\n  \"b\": ,\n}\" is not valid JSON",
            ),
            ("nulx", "Unexpected token 'x', \"nulx\" is not valid JSON"),
            ("nu", "Unexpected end of JSON input"),
            (
                "{\r\n\"a\" 1}",
                "Expected ':' after property name in JSON at position 7 (line 2 column 5)",
            ),
        ] {
            assert_eq!(parse(text).unwrap_err(), message, "{text:?}");
        }
    }

    #[test]
    fn nesting_beyond_the_limit_fails_cleanly() {
        let deep = "[".repeat(MAX_DEPTH + 1);
        assert_eq!(parse(&deep).unwrap_err(), STACK_OVERFLOW);
        let ok = format!("{}{}", "[".repeat(MAX_DEPTH), "]".repeat(MAX_DEPTH));
        assert!(parse(&ok).is_ok());
    }
}
