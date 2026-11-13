//! JavaScript semantics the Node code relied on, for the modules that port
//! JS text and JSON handling one for one (chat readers, summaries).
//!
//! Where Rust's standard library differs from JavaScript in a way the output
//! can show, the JS behavior wins and lives here, so a port never reinvents
//! it: `trim` (JS strips U+FEFF, Rust strips U+0085), string length in UTF-16
//! units, `Number#toString`, `JSON.stringify` (number format, integer-like
//! keys first), `JSON.parse`, `Date.parse` and `Date#toISOString`.

use serde_json::{Map, Number, Value};

// MARK: - Strings

/// ECMAScript WhiteSpace and LineTerminator: what `trim()` and `\s` match.
pub fn is_js_space(c: char) -> bool {
    matches!(
        c,
        '\u{9}'..='\u{d}'
            | ' '
            | '\u{a0}'
            | '\u{1680}'
            | '\u{2000}'..='\u{200a}'
            | '\u{2028}'
            | '\u{2029}'
            | '\u{202f}'
            | '\u{205f}'
            | '\u{3000}'
            | '\u{feff}'
    )
}

/// `String.prototype.trim`.
pub fn trim(text: &str) -> &str {
    text.trim_matches(is_js_space)
}

/// `String.prototype.trimStart`.
pub fn trim_start(text: &str) -> &str {
    text.trim_start_matches(is_js_space)
}

/// `String.prototype.trimEnd`.
pub fn trim_end(text: &str) -> &str {
    text.trim_end_matches(is_js_space)
}

/// `text.length`: UTF-16 code units.
pub fn utf16_len(text: &str) -> usize {
    text.chars().map(char::len_utf16).sum()
}

/// `text.slice(0, units)` for a boundary that falls between characters;
/// a cut inside a surrogate pair keeps the pair's first half in JS, which a
/// Rust string cannot hold, so the whole character is dropped instead (the
/// callers that cut mid-pair drop that half anyway).
pub fn prefix_utf16(text: &str, units: usize) -> &str {
    let mut used = 0;
    for (index, c) in text.char_indices() {
        let next = used + c.len_utf16();
        if next > units {
            return &text[..index];
        }
        used = next;
    }
    text
}

/// At most `limit` UTF-16 units, ending in `…` when cut, never splitting a
/// surrogate pair (chat-shared.js `clip`).
pub fn clip(text: &str, limit: usize) -> String {
    if utf16_len(text) <= limit {
        return text.to_string();
    }
    let mut cut = prefix_utf16(text, limit.saturating_sub(1)).to_string();
    cut.push('…');
    cut
}

// MARK: - Numbers

/// `String(number)` / `Number.prototype.toString()` in radix 10.
pub fn number_to_string(x: f64) -> String {
    if x.is_nan() {
        return "NaN".into();
    }
    if x == 0.0 {
        return "0".into();
    }
    if x.is_infinite() {
        return if x < 0.0 { "-Infinity" } else { "Infinity" }.into();
    }
    let sign = if x < 0.0 { "-" } else { "" };
    // Shortest round-trip digits, as d.ddde<exp>.
    let scientific = format!("{:e}", x.abs());
    let (mantissa, exponent) = scientific.split_once('e').unwrap_or((&scientific, "0"));
    let digits: String = mantissa.chars().filter(|c| *c != '.').collect();
    let k = digits.len() as i32;
    let n = exponent.parse::<i32>().unwrap_or(0) + 1;
    let body = if k <= n && n <= 21 {
        format!("{digits}{}", "0".repeat((n - k) as usize))
    } else if 0 < n && n <= 21 {
        format!("{}.{}", &digits[..n as usize], &digits[n as usize..])
    } else if -6 < n && n <= 0 {
        format!("0.{}{digits}", "0".repeat((-n) as usize))
    } else {
        let e = n - 1;
        let sign_e = if e < 0 { '-' } else { '+' };
        if k == 1 {
            format!("{digits}e{sign_e}{}", e.abs())
        } else {
            format!("{}.{}e{sign_e}{}", &digits[..1], &digits[1..], e.abs())
        }
    };
    format!("{sign}{body}")
}

/// A JSON number as the JavaScript number `JSON.parse` would have made of it.
pub fn json_f64(number: &Number) -> f64 {
    number.as_f64().unwrap_or(f64::NAN)
}

/// `Number.isInteger(value)` on a parsed JSON value.
pub fn is_integer(value: &Value) -> bool {
    match value {
        Value::Number(n) => {
            let f = json_f64(n);
            f.is_finite() && f.fract() == 0.0
        }
        _ => false,
    }
}

// MARK: - JSON values

/// Own property `key` of an object value (null counts as present).
pub fn get<'a>(value: &'a Value, key: &str) -> Option<&'a Value> {
    value.as_object().and_then(|map| map.get(key))
}

/// `value?.[key]` with undefined read as null.
pub fn field<'a>(value: &'a Value, key: &str) -> &'a Value {
    static NULL: Value = Value::Null;
    get(value, key).unwrap_or(&NULL)
}

/// JavaScript truthiness of a parsed JSON value.
pub fn truthy(value: &Value) -> bool {
    match value {
        Value::Null => false,
        Value::Bool(b) => *b,
        Value::Number(n) => {
            let f = json_f64(n);
            f != 0.0 && !f.is_nan()
        }
        Value::String(s) => !s.is_empty(),
        Value::Array(_) | Value::Object(_) => true,
    }
}

/// `typeof value === "object" && value !== null && !Array.isArray(value)`.
pub fn is_plain_object(value: &Value) -> bool {
    value.is_object()
}

/// `typeof value === "object" && value !== null`: an object or an array (JS
/// arrays are objects, and many checks in the JS do not exclude them).
pub fn is_object_like(value: &Value) -> bool {
    value.is_object() || value.is_array()
}

/// `JSON.parse(text)`; None where JavaScript would throw. Differences that
/// remain: serde_json rejects a lone surrogate escape and a number outside
/// the f64 range, which JavaScript accepts.
pub fn parse_json(text: &str) -> Option<Value> {
    serde_json::from_str(text).ok()
}

/// `JSON.stringify(value)` for a value that came from `JSON.parse` or was
/// built from such values: JS number formatting, integer-like keys first in
/// ascending order, everything else in insertion order.
pub fn stringify(value: &Value) -> String {
    let mut out = String::new();
    write_json(value, &mut out);
    out
}

pub fn write_json(value: &Value, out: &mut String) {
    match value {
        Value::Null => out.push_str("null"),
        Value::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        Value::Number(n) => {
            let f = json_f64(n);
            if f.is_finite() {
                out.push_str(&number_to_string(f));
            } else {
                out.push_str("null");
            }
        }
        Value::String(s) => write_json_string(s, out),
        Value::Array(items) => {
            out.push('[');
            for (index, item) in items.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                write_json(item, out);
            }
            out.push(']');
        }
        Value::Object(map) => write_object(map, out),
    }
}

/// `JSON.stringify(object)` appended to `out`.
fn write_object(map: &Map<String, Value>, out: &mut String) {
    out.push('{');
    let mut first = true;
    for (key, item) in ordered_entries(map) {
        if !first {
            out.push(',');
        }
        first = false;
        write_json_string(key, out);
        out.push(':');
        write_json(item, out);
    }
    out.push('}');
}

/// `JSON.stringify(object)` for an object that came from `JSON.parse` or was
/// built from such values.
pub fn stringify_object(map: &Map<String, Value>) -> String {
    let mut out = String::new();
    write_object(map, &mut out);
    out
}

/// A canonical array index: "0", or digits without a leading zero, at most
/// 2^32 - 2. JavaScript lists these keys first, ascending.
pub fn array_index(key: &str) -> Option<u32> {
    if key.is_empty() || key.len() > 10 || (key.len() > 1 && key.starts_with('0')) {
        return None;
    }
    if !key.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    key.parse::<u64>()
        .ok()
        .filter(|n| *n < u64::from(u32::MAX))
        .map(|n| n as u32)
}

/// An object's entries in JavaScript's `Object.keys` order.
pub fn ordered_entries(map: &Map<String, Value>) -> Vec<(&String, &Value)> {
    let mut indexed: Vec<(u32, &String, &Value)> = Vec::new();
    let mut named: Vec<(&String, &Value)> = Vec::new();
    for (key, item) in map {
        match array_index(key) {
            Some(index) => indexed.push((index, key, item)),
            None => named.push((key, item)),
        }
    }
    indexed.sort_by_key(|(index, _, _)| *index);
    indexed
        .into_iter()
        .map(|(_, key, item)| (key, item))
        .chain(named)
        .collect()
}

/// JSON string quoting exactly as `JSON.stringify` does (well-formed text:
/// no lone surrogates exist in a Rust string).
pub fn write_json_string(text: &str, out: &mut String) {
    out.push('"');
    for c in text.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\u{8}' => out.push_str("\\b"),
            '\u{c}' => out.push_str("\\f"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
}

// MARK: - Dates

const MS_PER_DAY: f64 = 86_400_000.0;
/// ECMAScript's time range: beyond it a Date is invalid.
const MAX_TIME: f64 = 8.64e15;

fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let year = if month <= 2 { year - 1 } else { year };
    let era = year.div_euclid(400);
    let yoe = year - era * 400;
    let mp = (month + 9) % 12;
    let doy = (153 * mp + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

fn civil_from_days(days: i64) -> (i64, i64, i64) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let year = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    (if month <= 2 { year + 1 } else { year }, month, day)
}

fn days_in_month(year: i64, month: i64) -> i64 {
    match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        _ if (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 => 29,
        _ => 28,
    }
}

/// The host zone's offset from UTC (ms, east positive) in effect at the
/// UTC instant `instant_ms`.
fn offset_at(instant_ms: f64) -> f64 {
    // `as _` takes the platform's time_t (64-bit on every release target).
    let seconds = (instant_ms / 1000.0).floor() as i64 as _;
    // SAFETY: `tm` is plain data that localtime_r fills in.
    unsafe {
        let mut local: libc::tm = std::mem::zeroed();
        if libc::localtime_r(&seconds, &mut local).is_null() {
            return 0.0;
        }
        local.tm_gmtoff as f64 * 1000.0
    }
}

/// The UTC instant of the host-zone wall time `wall_ms` (the wall clock read
/// as if it were UTC), as ECMAScript's UTC(t): an ambiguous time (clocks set
/// back) is the earlier instant, a time that never happened (clocks set
/// forward) uses the offset from before the change.
fn local_wall_to_utc(wall_ms: f64) -> f64 {
    let before = offset_at(wall_ms - MS_PER_DAY);
    let after = offset_at(wall_ms + MS_PER_DAY);
    if before == after {
        return wall_ms - before;
    }
    let first = wall_ms - before;
    let second = wall_ms - after;
    let first_ok = offset_at(first) == before;
    let second_ok = offset_at(second) == after;
    match (first_ok, second_ok) {
        (true, true) => first.min(second),
        (true, false) => first,
        (false, true) => second,
        (false, false) => first,
    }
}

fn time_clip(time: f64) -> Option<f64> {
    if time.is_finite() && time.abs() <= MAX_TIME {
        Some(time.trunc() + 0.0)
    } else {
        None
    }
}

struct Cursor<'a> {
    bytes: &'a [u8],
    at: usize,
}

impl Cursor<'_> {
    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.at).copied()
    }

    fn eat(&mut self, byte: u8) -> bool {
        if self.peek() == Some(byte) {
            self.at += 1;
            true
        } else {
            false
        }
    }

    fn digits(&mut self, count: usize) -> Option<i64> {
        let slice = self.bytes.get(self.at..self.at + count)?;
        if !slice.iter().all(u8::is_ascii_digit) {
            return None;
        }
        self.at += count;
        Some(slice.iter().fold(0i64, |n, d| n * 10 + i64::from(d - b'0')))
    }

    fn done(&self) -> bool {
        self.at == self.bytes.len()
    }
}

/// How V8 reads a string as the ECMAScript date-time format.
enum Iso {
    Time(f64),
    /// ISO-shaped but wrong: V8 answers NaN without trying the legacy forms.
    Invalid,
    /// Not (entirely) ISO: the legacy parser reads it.
    Fallback,
}

/// The ECMAScript date-time string format: `YYYY[-MM[-DD]]` with an optional
/// `THH:mm[:ss[.sss]]` and zone (`Z`, `+hh:mm` or `+hhmm`). Date-only forms
/// are UTC; a date-time with no zone is local time. V8 commits to this
/// reading at the `T`: anything wrong after it is NaN, while a date followed
/// by anything but `T` (a space, say) goes to the legacy parser.
fn parse_iso(text: &str) -> Iso {
    let mut c = Cursor {
        bytes: text.as_bytes(),
        at: 0,
    };
    let Some(first) = c.peek() else {
        return Iso::Fallback;
    };
    let year = match first {
        b'+' | b'-' => {
            let negative = first == b'-';
            c.at += 1;
            let Some(year) = c.digits(6) else {
                return Iso::Fallback;
            };
            if negative && year == 0 {
                return Iso::Invalid;
            }
            if negative { -year } else { year }
        }
        _ => match c.digits(4) {
            Some(year) => year,
            None => return Iso::Fallback,
        },
    };
    let (mut month, mut day) = (1, 1);
    if c.eat(b'-') {
        match c.digits(2) {
            Some(m) => month = m,
            None => return Iso::Fallback,
        }
        if c.eat(b'-') {
            match c.digits(2) {
                Some(d) => day = d,
                None => return Iso::Fallback,
            }
        }
    }
    if !matches!(c.peek(), Some(b'T' | b't')) && !c.done() {
        return Iso::Fallback;
    }
    // V8 checks only 1..=31 and rolls a day past the month's end over.
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return Iso::Invalid;
    }
    iso_time(c, year, month, day).map_or(Iso::Invalid, Iso::Time)
}

fn iso_time(mut c: Cursor<'_>, year: i64, month: i64, day: i64) -> Option<f64> {
    let (mut hour, mut minute, mut second, mut milli) = (0, 0, 0, 0);
    let mut offset: Option<i64> = None;
    let mut has_time = false;
    if matches!(c.peek(), Some(b'T' | b't')) {
        c.at += 1;
        has_time = true;
        hour = c.digits(2)?;
        if !c.eat(b':') {
            return None;
        }
        minute = c.digits(2)?;
        if c.eat(b':') {
            second = c.digits(2)?;
            if c.eat(b'.') {
                let start = c.at;
                while c.peek().is_some_and(|b| b.is_ascii_digit()) {
                    c.at += 1;
                }
                if c.at == start {
                    return None;
                }
                let fraction = &c.bytes[start..c.at];
                for index in 0..3 {
                    milli = milli * 10 + fraction.get(index).map_or(0, |d| i64::from(d - b'0'));
                }
            }
        }
        if hour > 24
            || minute > 59
            || second > 59
            || (hour == 24 && (minute, second, milli) != (0, 0, 0))
        {
            return None;
        }
        match c.peek() {
            Some(b'Z' | b'z') => {
                c.at += 1;
                offset = Some(0);
            }
            Some(sign @ (b'+' | b'-')) => {
                c.at += 1;
                let oh = c.digits(2)?;
                c.eat(b':');
                let om = c.digits(2)?;
                if oh > 23 || om > 59 {
                    return None;
                }
                let total = oh * 60 + om;
                offset = Some(if sign == b'-' { -total } else { total });
            }
            _ => {}
        }
    }
    if !c.done() {
        return None;
    }
    let days = days_from_civil(year, month, day);
    let wall = days as f64 * MS_PER_DAY
        + (hour * 3_600_000 + minute * 60_000 + second * 1000 + milli) as f64;
    let time = match offset {
        Some(minutes) => wall - minutes as f64 * 60_000.0,
        None if has_time => local_wall_to_utc(wall),
        None => wall,
    };
    Some(time)
}

const MONTHS: [&str; 12] = [
    "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec",
];
const WEEKDAYS: [&str; 7] = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];

/// The forms V8's legacy parser reads that logs and hand-written fixtures
/// use: `Wed, 30 Sep 2026 12:00:00 GMT`, `Sep 30, 2026 12:00:00 +0200`,
/// `30 Sep 2026`, `2026/09/30 12:00`. No zone means local time.
fn parse_legacy(text: &str) -> Option<f64> {
    // Commas separate nothing; `(text)` is a comment V8 skips.
    let mut cleaned = String::with_capacity(text.len());
    let mut depth = 0u32;
    for c in text.chars() {
        match c {
            '(' => depth += 1,
            ')' if depth > 0 => depth -= 1,
            _ if depth > 0 => {}
            ',' => cleaned.push(' '),
            c => cleaned.push(c),
        }
    }
    let (mut year, mut month, mut day) = (None, None, None);
    let (mut hour, mut minute, mut second, mut milli) = (0i64, 0i64, 0i64, 0i64);
    let mut offset: Option<i64> = None;
    let mut pm: Option<bool> = None;
    for token in cleaned.split_whitespace() {
        let lower = token.to_ascii_lowercase();
        if let Some(short) = lower.get(..3)
            && lower.chars().all(|c| c.is_ascii_alphabetic() || c == '.')
            && lower.len() >= 3
        {
            if let Some(index) = MONTHS.iter().position(|m| *m == short) {
                month = Some(index as i64 + 1);
                continue;
            }
            if WEEKDAYS.contains(&short) {
                continue;
            }
        }
        match lower.trim_end_matches('.') {
            "gmt" | "utc" | "ut" | "z" => {
                offset = Some(0);
                continue;
            }
            zone @ ("est" | "edt" | "cst" | "cdt" | "mst" | "mdt" | "pst" | "pdt") => {
                // The North American zone names V8 knows.
                let hours = match zone {
                    "edt" => -4,
                    "est" | "cdt" => -5,
                    "cst" | "mdt" => -6,
                    "mst" | "pdt" => -7,
                    _ => -8,
                };
                offset = Some(hours * 60);
                continue;
            }
            "am" => {
                pm = Some(false);
                continue;
            }
            "pm" => {
                pm = Some(true);
                continue;
            }
            _ => {}
        }
        let zone = lower
            .strip_prefix("gmt")
            .or_else(|| lower.strip_prefix("utc"))
            .unwrap_or(&lower);
        if let Some(sign) = zone.chars().next().filter(|c| *c == '+' || *c == '-')
            && zone.len() >= 3
            && zone[1..].bytes().all(|b| b.is_ascii_digit() || b == b':')
        {
            let digits: String = zone[1..].chars().filter(|c| *c != ':').collect();
            let (h, m) = match digits.len() {
                1 | 2 => (digits.parse::<i64>().ok()?, 0),
                3 | 4 => {
                    let split = digits.len() - 2;
                    (
                        digits[..split].parse::<i64>().ok()?,
                        digits[split..].parse::<i64>().ok()?,
                    )
                }
                _ => return None,
            };
            let total = h * 60 + m;
            offset = Some(if sign == '-' { -total } else { total });
            continue;
        }
        if token.contains(':') {
            // A zone glued to the time: `16:00:00Z`, `16:00+0200`.
            let (token, glued) = split_glued_zone(token)?;
            if let Some(minutes) = glued {
                offset = Some(minutes);
            }
            let mut parts = token.split(':');
            hour = parts.next()?.parse().ok()?;
            minute = parts.next()?.parse().ok()?;
            if let Some(rest) = parts.next() {
                let (s, f) = rest.split_once('.').unwrap_or((rest, ""));
                second = s.parse().ok()?;
                for (index, d) in f.bytes().take(3).enumerate() {
                    milli += i64::from(d - b'0') * [100, 10, 1][index];
                }
            }
            if parts.next().is_some() {
                return None;
            }
            continue;
        }
        if token.contains('-') && !token.starts_with('-') {
            // `2026-10-12` / `2026-1-2` read as a local date.
            let parts: Vec<&str> = token.split('-').collect();
            if let [y, m, d] = parts.as_slice() {
                year = Some(y.parse().ok()?);
                month = Some(m.parse().ok()?);
                day = Some(d.parse().ok()?);
                continue;
            }
            return None;
        }
        if token.contains('/') {
            let parts: Vec<&str> = token.split('/').collect();
            match parts.as_slice() {
                [y, m, d] if y.len() == 4 => {
                    year = Some(y.parse().ok()?);
                    month = Some(m.parse().ok()?);
                    day = Some(d.parse().ok()?);
                }
                [m, d, y] => {
                    month = Some(m.parse().ok()?);
                    day = Some(d.parse().ok()?);
                    let n: i64 = y.parse().ok()?;
                    year = Some(if y.len() <= 2 {
                        if n < 50 { 2000 + n } else { 1900 + n }
                    } else {
                        n
                    });
                }
                _ => return None,
            }
            continue;
        }
        let number: i64 = token.parse().ok()?;
        if day.is_none() && token.len() <= 2 && number >= 1 {
            day = Some(number);
        } else if year.is_none() {
            year = Some(if token.len() <= 2 {
                if number < 50 {
                    2000 + number
                } else {
                    1900 + number
                }
            } else {
                number
            });
        } else {
            return None;
        }
    }
    let (year, month, day) = (year?, month?, day.unwrap_or(1));
    if !(1..=12).contains(&month) || day < 1 || day > days_in_month(year, month) {
        return None;
    }
    if let Some(pm) = pm {
        if !(1..=12).contains(&hour) {
            return None;
        }
        hour = hour % 12 + if pm { 12 } else { 0 };
    }
    if hour > 24 || minute > 59 || second > 59 {
        return None;
    }
    let wall = days_from_civil(year, month, day) as f64 * MS_PER_DAY
        + (hour * 3_600_000 + minute * 60_000 + second * 1000 + milli) as f64;
    Some(match offset {
        Some(minutes) => wall - minutes as f64 * 60_000.0,
        None => local_wall_to_utc(wall),
    })
}

/// `new Date(year, month0, day, hour, minute, second).getTime()` for in-range
/// fields (a day or month past its end rolls over, as in JS): the host
/// (local) time zone.
pub fn local_time_ms(
    year: i64,
    month0: i64,
    day: i64,
    hour: i64,
    minute: i64,
    second: i64,
) -> Option<f64> {
    let year = year + month0.div_euclid(12);
    let month = month0.rem_euclid(12) + 1;
    let days = days_from_civil(year, month, 1) + (day - 1);
    let wall =
        days as f64 * MS_PER_DAY + (hour * 3_600_000 + minute * 60_000 + second * 1000) as f64;
    time_clip(local_wall_to_utc(wall))
}

/// `Number(value)` for a parsed JSON value: null is 0, a string follows
/// StringToNumber (blank is 0, `Infinity`, hex/octal/binary prefixes,
/// decimal; anything else NaN), arrays and objects are NaN here.
pub fn to_number(value: &Value) -> f64 {
    match value {
        Value::Null => 0.0,
        Value::Bool(b) => f64::from(u8::from(*b)),
        Value::Number(n) => json_f64(n),
        Value::String(s) => string_to_number(s),
        _ => f64::NAN,
    }
}

/// `Number(text)`.
pub fn string_to_number(text: &str) -> f64 {
    let t = trim(text);
    if t.is_empty() {
        return 0.0;
    }
    for (prefix, radix) in [
        ("0x", 16),
        ("0X", 16),
        ("0o", 8),
        ("0O", 8),
        ("0b", 2),
        ("0B", 2),
    ] {
        if let Some(digits) = t.strip_prefix(prefix) {
            return if digits.is_empty() {
                f64::NAN
            } else {
                u128::from_str_radix(digits, radix).map_or(f64::NAN, |n| n as f64)
            };
        }
    }
    let (sign, body) = match t.as_bytes()[0] {
        b'-' => (-1.0, &t[1..]),
        b'+' => (1.0, &t[1..]),
        _ => (1.0, t),
    };
    if body == "Infinity" {
        return sign * f64::INFINITY;
    }
    if body.starts_with(['+', '-']) {
        return f64::NAN;
    }
    // Rust also accepts "inf", "nan" and "infinity"; JavaScript does not.
    let decimal = body
        .bytes()
        .all(|b| b.is_ascii_digit() || matches!(b, b'.' | b'e' | b'E' | b'+' | b'-'))
        && body.bytes().any(|b| b.is_ascii_digit());
    if !decimal {
        return f64::NAN;
    }
    body.parse::<f64>().map_or(f64::NAN, |n| sign * n)
}

/// `16:00:00Z` / `16:00+0200` -> (`16:00:00`, zone minutes).
fn split_glued_zone(token: &str) -> Option<(&str, Option<i64>)> {
    if let Some(time) = token.strip_suffix(['Z', 'z']) {
        return Some((time, Some(0)));
    }
    let Some(at) = token.rfind(['+', '-']) else {
        return Some((token, None));
    };
    let (time, zone) = token.split_at(at);
    let digits: String = zone[1..].chars().filter(|c| *c != ':').collect();
    if digits.len() != 4 || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let total = digits[..2].parse::<i64>().ok()? * 60 + digits[2..].parse::<i64>().ok()?;
    Some((
        time,
        Some(if zone.starts_with('-') { -total } else { total }),
    ))
}

/// `Date.parse(text)`: milliseconds since the epoch, or None for NaN.
pub fn date_parse(text: &str) -> Option<f64> {
    match parse_iso(text) {
        Iso::Time(time) => time_clip(time),
        Iso::Invalid => None,
        Iso::Fallback => parse_legacy(text).and_then(time_clip),
    }
}

/// `new Date(time).toISOString()`; None where JavaScript throws a RangeError
/// (a time outside the Date range, or NaN).
pub fn to_iso_string(time: f64) -> Option<String> {
    let time = time_clip(time)?;
    let days = (time / MS_PER_DAY).floor();
    let ms_of_day = time - days * MS_PER_DAY;
    let (year, month, day) = civil_from_days(days as i64);
    let ms = ms_of_day as i64;
    let year_text = if (0..=9999).contains(&year) {
        format!("{year:04}")
    } else {
        format!("{}{:06}", if year < 0 { '-' } else { '+' }, year.abs())
    };
    Some(format!(
        "{year_text}-{month:02}-{day:02}T{:02}:{:02}:{:02}.{:03}Z",
        ms / 3_600_000,
        ms / 60_000 % 60,
        ms / 1000 % 60,
        ms % 1000
    ))
}

/// The `SyntaxError` message `JSON.parse(text)` throws in Node 24 (V8's
/// `JsonParser`: positions in UTF-16 units, 1-based line and column), or
/// None when V8 accepts the text. Only used to word an error the caller
/// already knows [`parse_json`] reported.
pub fn json_syntax_error(text: &str) -> Option<String> {
    let units: Vec<u16> = text.encode_utf16().collect();
    JsonScan { s: &units, i: 0 }.run().err()
}

struct JsonScan<'a> {
    s: &'a [u16],
    i: usize,
}

/// What V8's `JsonToken` says about a character, as far as messages go.
#[derive(PartialEq, Clone, Copy)]
enum JsonTok {
    Eos,
    Number,
    String,
    Other,
}

type Scan<T> = Result<T, String>;

impl JsonScan<'_> {
    fn peek_unit(&self) -> Option<u16> {
        self.s.get(self.i).copied()
    }

    fn skip_whitespace(&mut self) {
        while matches!(self.peek_unit(), Some(0x20 | 0x09 | 0x0a | 0x0d)) {
            self.i += 1;
        }
    }

    fn is(&self, c: char) -> bool {
        self.peek_unit() == Some(c as u16)
    }

    fn token(&self) -> JsonTok {
        match self.peek_unit() {
            None => JsonTok::Eos,
            Some(0x22) => JsonTok::String,
            Some(c) if (0x30..=0x39).contains(&c) => JsonTok::Number,
            Some(_) => JsonTok::Other,
        }
    }

    /// `CalculateFileLocation`: `\r\n` counts once; a `\r` right before the
    /// error position counts alone.
    fn location(&self) -> (usize, usize) {
        let end = self.i;
        let (mut line, mut last_break, mut cursor) = (1, 0, 0);
        while cursor < end {
            if self.s[cursor] == 0x0d && cursor + 1 < end && self.s[cursor + 1] == 0x0a {
                cursor += 1;
            }
            if self.s[cursor] == 0x0d || self.s[cursor] == 0x0a {
                line += 1;
                last_break = cursor + 1;
            }
            cursor += 1;
        }
        (line, 1 + cursor - last_break)
    }

    fn at(&self, message: &str) -> String {
        let (line, column) = self.location();
        format!(
            "{message} in JSON at position {} (line {line} column {column})",
            self.i
        )
    }

    fn lossy(&self, from: usize, to: usize) -> String {
        String::from_utf16_lossy(&self.s[from..to])
    }

    /// `ReportUnexpectedToken` without a specific message.
    fn unexpected(&self) -> String {
        match self.token() {
            JsonTok::Eos => "Unexpected end of JSON input".into(),
            JsonTok::Number => self.at("Unexpected number"),
            JsonTok::String => self.at("Unexpected string"),
            JsonTok::Other => {
                let source = self.lossy(0, self.s.len());
                if matches!(
                    source.as_str(),
                    "NaN" | "Infinity" | "undefined" | "[object Object]"
                ) {
                    return format!("\"{source}\" is not valid JSON");
                }
                let unit = self.lossy(self.i, self.i + 1);
                let (pos, len) = (self.i, self.s.len());
                const CONTEXT: usize = 10;
                if len < CONTEXT * 2 + 1 {
                    return format!("Unexpected token '{unit}', \"{source}\" is not valid JSON");
                }
                if pos < CONTEXT {
                    let part = self.lossy(0, pos + CONTEXT);
                    format!("Unexpected token '{unit}', \"{part}\"... is not valid JSON")
                } else if pos < len - CONTEXT {
                    let part = self.lossy(pos - CONTEXT, pos + CONTEXT);
                    format!("Unexpected token '{unit}', ...\"{part}\"... is not valid JSON")
                } else {
                    let part = self.lossy(pos - CONTEXT, len);
                    format!("Unexpected token '{unit}', ...\"{part}\" is not valid JSON")
                }
            }
        }
    }

    /// `Check(token)`: skip whitespace, consume `c` when it is next.
    fn check(&mut self, c: char) -> bool {
        self.skip_whitespace();
        let found = self.is(c);
        if found {
            self.i += 1;
        }
        found
    }

    /// `ExpectNext(token, message)` / `Expect(token, message)`.
    fn expect(&mut self, c: char, message: &str) -> Scan<()> {
        if self.is(c) {
            self.i += 1;
            Ok(())
        } else {
            Err(self.at(message))
        }
    }

    fn expect_next(&mut self, c: char, message: &str) -> Scan<()> {
        self.skip_whitespace();
        self.expect(c, message)
    }

    /// `ExpectNext(STRING, message)`: a property name starts here; the
    /// string scan consumes its quote.
    fn expect_quote(&mut self, message: &str) -> Scan<()> {
        self.skip_whitespace();
        if self.is('"') {
            Ok(())
        } else {
            Err(self.at(message))
        }
    }

    fn run(mut self) -> Scan<()> {
        // true: an object on the stack, false: an array.
        let mut stack: Vec<bool> = Vec::new();
        'value: loop {
            self.skip_whitespace();
            match self.peek_unit() {
                Some(0x22) => self.string()?,
                Some(c) if c == 0x2d || (0x30..=0x39).contains(&c) => self.number()?,
                Some(0x7b) => {
                    self.i += 1;
                    if !self.check('}') {
                        self.expect_quote("Expected property name or '}'")?;
                        self.string()?;
                        self.expect_next(':', "Expected ':' after property name")?;
                        stack.push(true);
                        continue 'value;
                    }
                }
                Some(0x5b) => {
                    self.i += 1;
                    if !self.check(']') {
                        stack.push(false);
                        continue 'value;
                    }
                }
                Some(0x74) => self.literal("true")?,
                Some(0x66) => self.literal("false")?,
                Some(0x6e) => self.literal("null")?,
                _ => return Err(self.unexpected()),
            }
            loop {
                match stack.last() {
                    None => {
                        self.skip_whitespace();
                        if self.i < self.s.len() {
                            let (line, column) = self.location();
                            return Err(format!(
                                "Unexpected non-whitespace character after JSON at position {} (line {line} column {column})",
                                self.i
                            ));
                        }
                        return Ok(());
                    }
                    Some(false) => {
                        if self.check(',') {
                            continue 'value;
                        }
                        self.expect(']', "Expected ',' or ']' after array element")?;
                    }
                    Some(true) => {
                        if self.check(',') {
                            self.expect_quote("Expected double-quoted property name")?;
                            self.string()?;
                            self.expect_next(':', "Expected ':' after property name")?;
                            continue 'value;
                        }
                        self.expect('}', "Expected ',' or '}' after property value")?;
                    }
                }
                stack.pop();
            }
        }
    }

    fn literal(&mut self, word: &str) -> Scan<()> {
        for expected in word.bytes() {
            if self.peek_unit() != Some(u16::from(expected)) {
                return Err(self.unexpected());
            }
            self.i += 1;
        }
        Ok(())
    }

    /// At the opening quote.
    fn string(&mut self) -> Scan<()> {
        self.i += 1;
        loop {
            match self.peek_unit() {
                None => return Err(self.at("Unterminated string")),
                Some(0x22) => {
                    self.i += 1;
                    return Ok(());
                }
                Some(0x5c) => {
                    self.i += 1;
                    match self.peek_unit() {
                        None => return Err("Unexpected end of JSON input".into()),
                        Some(0x22 | 0x5c | 0x2f | 0x62 | 0x66 | 0x6e | 0x72 | 0x74) => {}
                        Some(0x75) => {
                            for _ in 0..4 {
                                self.i += 1;
                                let hex = self
                                    .peek_unit()
                                    .and_then(|c| char::from_u32(u32::from(c)))
                                    .is_some_and(|c| c.is_ascii_hexdigit());
                                if !hex {
                                    return Err(self.at("Bad Unicode escape"));
                                }
                            }
                        }
                        _ => return Err(self.at("Bad escaped character")),
                    }
                    self.i += 1;
                }
                Some(c) if c < 0x20 => {
                    return Err(self.at("Bad control character in string literal"));
                }
                Some(_) => self.i += 1,
            }
        }
    }

    fn digits(&mut self) {
        while matches!(self.peek_unit(), Some(0x30..=0x39)) {
            self.i += 1;
        }
    }

    fn number(&mut self) -> Scan<()> {
        if self.is('-') {
            self.i += 1;
        }
        if self.is('0') {
            self.i += 1;
            if matches!(self.peek_unit(), Some(0x30..=0x39)) {
                return Err(self.at("Unexpected number"));
            }
        } else {
            let start = self.i;
            self.digits();
            if self.i == start {
                return Err(self.at("No number after minus sign"));
            }
        }
        if self.is('.') {
            self.i += 1;
            if !matches!(self.peek_unit(), Some(0x30..=0x39)) {
                return Err(self.at("Unterminated fractional number"));
            }
            self.digits();
        }
        if self.is('e') || self.is('E') {
            self.i += 1;
            if self.is('-') || self.is('+') {
                self.i += 1;
            }
            if !matches!(self.peek_unit(), Some(0x30..=0x39)) {
                return Err(self.at("Exponent part is missing a number"));
            }
            self.digits();
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn trim_follows_javascript_whitespace() {
        assert_eq!(trim("\u{feff} a\u{a0}"), "a");
        // U+0085 is Rust whitespace but not JavaScript's.
        assert_eq!(trim("\u{85}a"), "\u{85}a");
        assert_eq!(trim_start("\u{2028}\n x "), "x ");
        assert_eq!(trim_end(" x \u{3000}"), " x");
    }

    #[test]
    fn clip_counts_utf16_and_keeps_pairs_whole() {
        assert_eq!(clip("abc", 3), "abc");
        assert_eq!(clip("abcd", 3), "ab…");
        // "😀" is two units: a cut after its first unit drops the pair.
        assert_eq!(clip("a😀b", 3), "a…");
        assert_eq!(clip("a😀bc", 4), "a😀…");
        assert_eq!(utf16_len("a😀"), 3);
    }

    #[test]
    fn numbers_print_the_way_javascript_does() {
        for (value, text) in [
            (0.0, "0"),
            (-0.0, "0"),
            (1.0, "1"),
            (1.5, "1.5"),
            (100.0, "100"),
            (1e21, "1e+21"),
            (1e20, "100000000000000000000"),
            (1.5e-7, "1.5e-7"),
            (0.000001, "0.000001"),
            (123456789012345680000.0, "123456789012345680000"),
            (-12.25, "-12.25"),
            (0.1 + 0.2, "0.30000000000000004"),
            (f64::NAN, "NaN"),
        ] {
            assert_eq!(number_to_string(value), text);
        }
    }

    #[test]
    fn stringify_matches_json_stringify() {
        let value: Value = serde_json::from_str(
            r#"{"b":1.0,"10":2,"2":3,"a":[1e3,-0,0.5,"x\u0001\u2028\"\\"],"c":null}"#,
        )
        .unwrap();
        assert_eq!(
            stringify(&value),
            "{\"2\":3,\"10\":2,\"b\":1,\"a\":[1000,0,0.5,\"x\\u0001\u{2028}\\\"\\\\\"],\"c\":null}"
        );
        assert_eq!(stringify(&json!("é😀\u{7f}")), "\"é😀\u{7f}\"");
    }

    #[test]
    fn dates_parse_and_print() {
        assert_eq!(
            date_parse("2026-09-30T12:00:00.000Z"),
            Some(1_790_769_600_000.0)
        );
        assert_eq!(date_parse("2026-09-30"), Some(1_790_726_400_000.0));
        assert_eq!(
            date_parse("2026-09-30T12:00:00+02:00"),
            Some(1_790_762_400_000.0)
        );
        // V8 rolls a day past the month end over; only 1..=31 is checked.
        assert_eq!(date_parse("2026-02-30"), Some(1_772_409_600_000.0));
        assert_eq!(date_parse("2026-02-32"), None);
        // V8 commits to the ISO reading at the `T`: whitespace, a comma
        // fraction or a short zone make it NaN.
        for nan in [
            "  2026-10-12T16:00:00Z",
            "2026-10-12T16:00:00Z  ",
            "2026-10-12T16:00:00,5Z",
            "2026-10-12T16:00:00+02",
            "2026-10-12T16",
            "2026-10-12T16:00:60",
            "2026-10-12T16:00:00 Z",
            "20261012",
        ] {
            assert_eq!(date_parse(nan), None, "{nan}");
        }
        assert_eq!(
            date_parse("2026-10-12T16:00:00+0200"),
            Some(1_791_813_600_000.0)
        );
        assert_eq!(
            date_parse("2026-10-12T24:00:00Z"),
            Some(1_791_849_600_000.0)
        );
        assert_eq!(
            date_parse("2026-10-12T16:00:00.1234567Z"),
            Some(1_791_820_800_123.0)
        );
        // Other shapes go to the legacy reader.
        assert_eq!(
            date_parse("2026-10-12 16:00:00Z"),
            Some(1_791_820_800_000.0)
        );
        assert_eq!(
            date_parse("Mon Oct 12 2026 16:00:00 GMT+0200 (CEST)"),
            Some(1_791_813_600_000.0)
        );
        assert_eq!(date_parse("2026"), Some(1_767_225_600_000.0));
        assert_eq!(
            date_parse("Oct 12 2026 10:00 EST"),
            Some(1_791_817_200_000.0)
        );
        assert_eq!(date_parse("nope"), None);
        assert_eq!(
            date_parse("Wed, 30 Sep 2026 12:00:00 GMT"),
            Some(1_790_769_600_000.0)
        );
        assert_eq!(
            date_parse("Sep 30, 2026 12:00:00 GMT+0200"),
            Some(1_790_762_400_000.0)
        );
        assert_eq!(
            to_iso_string(1_790_769_600_123.0).as_deref(),
            Some("2026-09-30T12:00:00.123Z")
        );
        assert_eq!(
            to_iso_string(-1.0).as_deref(),
            Some("1969-12-31T23:59:59.999Z")
        );
        assert_eq!(to_iso_string(1e20), None);
        assert_eq!(
            to_iso_string(253_402_300_800_000.0).as_deref(),
            Some("+010000-01-01T00:00:00.000Z")
        );
    }
}
