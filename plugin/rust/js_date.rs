//! `Date.parse` for the ECMAScript date-time string format, as V8 reads it.
//!
//! `YYYY`, `YYYY-MM`, `YYYY-MM-DD` (UTC) and those followed by `THH:mm`,
//! `THH:mm:ss` or `THH:mm:ss.s…` with an optional `Z` or `±HH:mm` offset
//! (local time without one), expanded years `±YYYYYY`, and V8's leniency for
//! a lower-case `t`/`z` and `±HHmm`. V8's legacy parser also takes formats such
//! as `Oct 12 2026`, `2026/10/12` or `2026-10-12 10:00:00`; those read as `None`
//! here, where JS has a date.

/// Milliseconds since the epoch, or `None` where JS answers `NaN`.
pub fn parse(text: &str) -> Option<i64> {
    let bytes = text.as_bytes();
    let mut at = 0;
    let digits = |at: &mut usize, count: usize| -> Option<i64> {
        let slice = bytes.get(*at..*at + count)?;
        if !slice.iter().all(u8::is_ascii_digit) {
            return None;
        }
        *at += count;
        Some(
            slice
                .iter()
                .fold(0, |acc, b| acc * 10 + i64::from(b - b'0')),
        )
    };

    let year = match bytes.first()? {
        sign @ (b'+' | b'-') => {
            at = 1;
            let magnitude = digits(&mut at, 6)?;
            if *sign == b'-' {
                // "-000000" is not a year.
                if magnitude == 0 {
                    return None;
                }
                -magnitude
            } else {
                magnitude
            }
        }
        _ => digits(&mut at, 4)?,
    };
    let (mut month, mut day) = (1, 1);
    if bytes.get(at) == Some(&b'-') {
        at += 1;
        month = digits(&mut at, 2)?;
        if bytes.get(at) == Some(&b'-') {
            at += 1;
            day = digits(&mut at, 2)?;
        }
    }
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return None;
    }
    let days = days_from_civil(year, month, day);

    if at == bytes.len() {
        return clip(days * 86_400_000);
    }
    if !matches!(bytes[at], b'T' | b't') {
        return None;
    }
    at += 1;
    let hour = digits(&mut at, 2)?;
    if bytes.get(at) != Some(&b':') {
        return None;
    }
    at += 1;
    let minute = digits(&mut at, 2)?;
    let (mut second, mut millis) = (0, 0);
    if bytes.get(at) == Some(&b':') {
        at += 1;
        second = digits(&mut at, 2)?;
        if bytes.get(at) == Some(&b'.') {
            at += 1;
            let start = at;
            while bytes.get(at).is_some_and(u8::is_ascii_digit) {
                at += 1;
            }
            if at == start {
                return None;
            }
            // Only the first three digits count.
            millis = bytes[start..at.min(start + 3)]
                .iter()
                .enumerate()
                .map(|(i, b)| i64::from(b - b'0') * 10_i64.pow(2 - i as u32))
                .sum();
        }
    }
    if hour > 24
        || minute > 59
        || second > 59
        || (hour == 24 && (minute, second, millis) != (0, 0, 0))
    {
        return None;
    }
    let of_day = ((hour * 60 + minute) * 60 + second) * 1000 + millis;
    let utc_ms = days * 86_400_000 + of_day;

    let offset_minutes = match bytes.get(at) {
        None => return clip(local_to_utc(utc_ms)?),
        Some(b'Z' | b'z') => {
            at += 1;
            0
        }
        Some(sign @ (b'+' | b'-')) => {
            at += 1;
            let hours = digits(&mut at, 2)?;
            if bytes.get(at) == Some(&b':') {
                at += 1;
            }
            let minutes = digits(&mut at, 2)?;
            if hours > 23 || minutes > 59 {
                return None;
            }
            let total = hours * 60 + minutes;
            if *sign == b'-' { -total } else { total }
        }
        Some(_) => return None,
    };
    if at != bytes.len() {
        return None;
    }
    clip(utc_ms - offset_minutes * 60_000)
}

/// `TimeClip`: a time beyond ±8.64e15 ms is not a date.
fn clip(ms: i64) -> Option<i64> {
    (ms.unsigned_abs() <= 8_640_000_000_000_000).then_some(ms)
}

/// Days since 1970-01-01 of a proleptic Gregorian date.
fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let year = year - i64::from(month <= 2);
    let era = year.div_euclid(400);
    let year_of_era = year.rem_euclid(400);
    let shifted_month = (month + 9) % 12;
    let day_of_year = (153 * shifted_month + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    era * 146_097 + day_of_era - 719_468
}

/// Days since 1970-01-01 to a proleptic Gregorian (year, month, day).
fn civil_from_days(days: i64) -> (i64, i64, i64) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let day_of_era = z.rem_euclid(146_097);
    let year_of_era =
        (day_of_era - day_of_era / 1460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let shifted_month = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * shifted_month + 2) / 5 + 1;
    let month = if shifted_month < 10 {
        shifted_month + 3
    } else {
        shifted_month - 9
    };
    let year = year_of_era + era * 400 + i64::from(month <= 2);
    (year, month, day)
}

/// `new Date(ms).toISOString()`, or `None` for a time JS cannot represent
/// (it throws a RangeError there).
pub fn iso_string(ms: i64) -> Option<String> {
    if ms.unsigned_abs() > 8_640_000_000_000_000 {
        return None;
    }
    let (year, month, day) = civil_from_days(ms.div_euclid(86_400_000));
    let of_day = ms.rem_euclid(86_400_000);
    let year = if (0..=9999).contains(&year) {
        format!("{year:04}")
    } else {
        format!("{}{:06}", if year < 0 { '-' } else { '+' }, year.abs())
    };
    Some(format!(
        "{year}-{month:02}-{day:02}T{:02}:{:02}:{:02}.{:03}Z",
        of_day / 3_600_000,
        of_day / 60_000 % 60,
        of_day / 1000 % 60,
        of_day % 1000,
    ))
}

/// Now, as `new Date().toISOString()`.
pub fn iso_now() -> String {
    let ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_millis() as i64);
    iso_string(ms).unwrap_or_default()
}

/// The epoch time of a wall-clock time given as if it were UTC, read in the
/// process's local time zone. (All four release targets have a 64-bit
/// `time_t`; `libc::time_t` is deprecated on musl, so it is not named.)
fn local_to_utc(as_utc_ms: i64) -> Option<i64> {
    let seconds: i64 = as_utc_ms.div_euclid(1000);
    let millis = as_utc_ms.rem_euclid(1000);
    // SAFETY: both pointers are valid for the call; `gmtime_r` fills `parts`.
    let mut parts: libc::tm = unsafe { std::mem::zeroed() };
    if unsafe { libc::gmtime_r(&seconds, &mut parts) }.is_null() {
        return None;
    }
    parts.tm_isdst = -1;
    // SAFETY: `parts` is a fully initialized `tm`.
    let local: i64 = unsafe { libc::mktime(&mut parts) };
    (local != -1).then(|| local * 1000 + millis)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn iso_strings_match_to_iso_string() {
        for (ms, text) in [
            (0, Some("1970-01-01T00:00:00.000Z")),
            (1_791_799_200_123, Some("2026-10-12T10:00:00.123Z")),
            (-1, Some("1969-12-31T23:59:59.999Z")),
            (8_640_000_000_000_000, Some("+275760-09-13T00:00:00.000Z")),
            (-8_640_000_000_000_000, Some("-271821-04-20T00:00:00.000Z")),
            (253_402_300_800_000, Some("+010000-01-01T00:00:00.000Z")),
            (-62_198_755_200_000, Some("-000001-01-01T00:00:00.000Z")),
            (8_640_000_000_000_001, None),
            (951_782_400_000, Some("2000-02-29T00:00:00.000Z")),
            (4_107_542_400_000, Some("2100-03-01T00:00:00.000Z")),
            (-2_208_988_800_000, Some("1900-01-01T00:00:00.000Z")),
        ] {
            assert_eq!(iso_string(ms).as_deref(), text, "{ms}");
        }
        // And what it prints, it parses back.
        assert_eq!(parse("2026-10-12T10:00:00.123Z"), Some(1_791_799_200_123));
    }

    #[test]
    fn reads_the_iso_forms_with_an_offset_or_none() {
        for (text, ms) in [
            ("2026-10-12T10:00:00.000Z", Some(1_791_799_200_000)),
            ("2026-10-12T10:00:00Z", Some(1_791_799_200_000)),
            ("2026-10-12T10:00Z", Some(1_791_799_200_000)),
            ("2026-10-12", Some(1_791_763_200_000)),
            ("2026-10", Some(1_790_812_800_000)),
            ("2026", Some(1_767_225_600_000)),
            ("2026-10-12T10:00:00+02:00", Some(1_791_792_000_000)),
            ("2026-10-12T10:00:00-0530", Some(1_791_819_000_000)),
            ("2026-10-12T10:00:00.1Z", Some(1_791_799_200_100)),
            ("2026-10-12T10:00:00.123456789Z", Some(1_791_799_200_123)),
            ("2026-02-30", Some(1_772_409_600_000)),
            ("2026-10-12T24:00:00Z", Some(1_791_849_600_000)),
            ("+002026-10-12T10:00:00Z", Some(1_791_799_200_000)),
            ("-000001-01-01T00:00:00Z", Some(-62_198_755_200_000)),
            ("+275760-09-13T00:00:00.000Z", Some(8_640_000_000_000_000)),
            ("-271821-04-20T00:00:00Z", Some(-8_640_000_000_000_000)),
            ("0000-01-01T00:00:00Z", Some(-62_167_219_200_000)),
            ("2026-10-12t10:00:00z", Some(1_791_799_200_000)),
            ("1969-12-31T23:59:59.999Z", Some(-1)),
        ] {
            assert_eq!(parse(text), ms, "{text}");
        }
    }

    #[test]
    fn everything_else_is_not_a_date() {
        for text in [
            "",
            "abc",
            "2026-13-01",
            "2026-00-10",
            "2026-10-00",
            "2026-10-32",
            "2026-10-12T24:00:01Z",
            "2026-10-12T25:00:00Z",
            "2026-10-12T10:60:00Z",
            "2026-10-12T10:00:60Z",
            "-000000-01-01T00:00:00Z",
            "+275760-09-13T00:00:00.001Z",
            "2026-10-12T10:00:00+02",
            "2026-10-12T10:00:00.Z",
            "2026-10-12T10:00:00 Z",
            "2026-10-12T10",
            "2026-10-12T1:00:00Z",
            "2026-1-12T10:00:00Z",
            "26-10-12",
            " 2026-10-12T10:00:00Z",
            "2026-10-12T10:00:00Z ",
            "2026-10-12 10:00:00Z",
            "2026-10-12T10:00:00,5Z",
            "20261012T100000Z",
        ] {
            assert_eq!(parse(text), None, "{text:?}");
        }
    }
}
