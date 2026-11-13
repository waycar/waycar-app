//! Base64 the way Node's `Buffer` does it, for the key blobs, Pairing Code
//! bodies and notification envelopes the JS encodes and decodes: standard
//! alphabet with padding or url alphabet without, a lenient decoder that is
//! `Buffer.from(text, "base64")` and one that first checks the text as the
//! envelope code does.

const STANDARD: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const URL: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

/// `/^[A-Za-z0-9+/]+={0,2}$/`: standard base64 with at most two `=` at the end.
pub fn is_standard_text(text: &str) -> bool {
    let body = text.trim_end_matches('=');
    text.len() - body.len() <= 2
        && !body.is_empty()
        && body
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'+' || b == b'/')
}

/// `/^[A-Za-z0-9_-]+$/`: url-safe base64 characters, no padding.
pub fn is_url_text(text: &str) -> bool {
    !text.is_empty()
        && text
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

/// `buffer.toString("base64")`.
pub fn encode_standard(bytes: &[u8]) -> String {
    encode(bytes, STANDARD, true)
}

/// `buffer.toString("base64url")`: no padding.
pub fn encode_url(bytes: &[u8]) -> String {
    encode(bytes, URL, false)
}

/// The length of `bytes` bytes as unpadded base64url.
pub fn url_len(bytes: usize) -> usize {
    bytes / 3 * 4
        + match bytes % 3 {
            0 => 0,
            1 => 2,
            _ => 3,
        }
}

fn encode(bytes: &[u8], alphabet: &[u8; 64], pad: bool) -> String {
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let n = chunk
            .iter()
            .enumerate()
            .fold(0u32, |acc, (i, b)| acc | (u32::from(*b) << (16 - 8 * i)));
        for i in 0..=chunk.len() {
            out.push(char::from(alphabet[((n >> (18 - 6 * i)) & 63) as usize]));
        }
        if pad {
            for _ in chunk.len()..3 {
                out.push('=');
            }
        }
    }
    out
}

fn sextet(byte: u8) -> Option<u32> {
    match byte {
        b'A'..=b'Z' => Some(u32::from(byte - b'A')),
        b'a'..=b'z' => Some(u32::from(byte - b'a') + 26),
        b'0'..=b'9' => Some(u32::from(byte - b'0') + 52),
        b'+' | b'-' => Some(62),
        b'/' | b'_' => Some(63),
        _ => None,
    }
}

/// `Buffer.from(text, "base64")` and `"base64url"`: Node reads both
/// alphabets, skips characters outside them (a UTF-16 unit counts by its low
/// byte, as Node reads it) and stops at the first `=`. A trailing partial
/// group yields the bytes it fully covers, so a single leftover character
/// yields none.
pub fn decode(text: &str) -> Vec<u8> {
    let mut out = Vec::with_capacity(text.len() * 3 / 4);
    let (mut bits, mut have) = (0u32, 0u32);
    for unit in text.encode_utf16() {
        let byte = unit as u8;
        if byte == b'=' {
            break;
        }
        let Some(digit) = sextet(byte) else {
            continue;
        };
        bits = (bits << 6) | digit;
        have += 6;
        if have >= 8 {
            have -= 8;
            out.push((bits >> have) as u8);
            bits &= (1 << have) - 1;
        }
    }
    out
}

/// `Buffer.from(text, "base64url")` for text made only of base64url
/// characters: unpadded, and the unused bits of a last partial group are
/// dropped without being checked (Node accepts non-canonical tails). `None`
/// for any other character or for a length no byte string encodes (`n % 4 == 1`).
pub fn decode_url_strict(text: &str) -> Option<Vec<u8>> {
    ((text.is_empty() || is_url_text(text)) && text.len() % 4 != 1).then(|| decode(text))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encodes_like_node() {
        assert_eq!(encode_standard(&[0xfb, 0xff, 0xbf]), "+/+/");
        assert_eq!(encode_url(&[0xfb, 0xff, 0xbf]), "-_-_");
        assert_eq!(encode_standard(b"ab"), "YWI=");
        assert_eq!(encode_standard(b"a"), "YQ==");
        assert_eq!(encode_url(b"a"), "YQ");
        assert_eq!(encode_standard(b""), "");
    }

    #[test]
    fn text_patterns_follow_the_js_regexes() {
        for yes in ["AAAA", "a+/b", "AA=", "AA==", "A"] {
            assert!(is_standard_text(yes), "{yes}");
        }
        for no in ["", "=", "AAA===", "A=A", "AA-_", "AA\n", "A A", "é"] {
            assert!(!is_standard_text(no), "{no:?}");
        }
        for yes in ["AAAA", "a-_b", "A"] {
            assert!(is_url_text(yes), "{yes}");
        }
        for no in ["", "AA=", "a+b", "A\n", "é"] {
            assert!(!is_url_text(no), "{no:?}");
        }
    }

    #[test]
    fn decodes_like_node_buffer() {
        // Expected values printed by `Buffer.from(text, "base64")` in Node 24.
        for (text, hex) in [
            ("A", ""),
            ("AB", "00"),
            ("ABC", "0010"),
            ("ABCD", "001083"),
            ("ABCDE", "001083"),
            ("AA=", "00"),
            ("AA==", "00"),
            ("AAAA=", "000000"),
            ("AAB=", "0000"),
            ("A=", ""),
            ("ABCDEF==", "00108310"),
            ("+/+/", "fbffbf"),
            ("-_-_", "fbffbf"),
            ("AB-_", "001fbf"),
        ] {
            let bytes = decode(text);
            let got: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
            assert_eq!(got, hex, "{text}");
        }
    }
    #[test]
    fn url_round_trips_every_length() {
        for len in 0..40usize {
            let bytes: Vec<u8> = (0..len).map(|i| (i * 37 + 11) as u8).collect();
            let text = encode_url(&bytes);
            assert_eq!(text.len(), url_len(len));
            assert_eq!(decode_url_strict(&text), Some(bytes));
        }
        assert_eq!(encode_url(&[0xfb, 0xff, 0xfe]), "-__-");
    }

    #[test]
    fn url_decode_strict_matches_node_leniency() {
        // Node ignores the unused bits of the last group ("AB" is 0x00, not an error).
        assert_eq!(decode_url_strict("AB"), Some(vec![0]));
        assert_eq!(decode_url_strict("A"), None);
        assert_eq!(decode_url_strict("AAAAA"), None);
        assert_eq!(decode_url_strict("AA=="), None);
        assert_eq!(decode_url_strict("a+/b"), None);
        assert_eq!(decode_url_strict(""), Some(vec![]));
    }

    #[test]
    fn decode_skips_stray_characters_and_stops_at_equals_like_node() {
        // Expected values printed by `Buffer.from(text, "base64url")` in Node:
        // a UTF-16 unit counts by its low byte (U+0141 is `A`, U+D83D is `=`).
        for (text, hex) in [
            ("A\u{141}", "00"),
            ("AA\u{141}AA", "000000"),
            ("A A\nA", "0000"),
            ("AA A", "0000"),
            ("AB-_=AAAA", "001fbf"),
            ("\u{1F600}", ""),
            ("A\u{1F600}A", ""),
        ] {
            let got: String = decode(text).iter().map(|b| format!("{b:02x}")).collect();
            assert_eq!(got, hex, "{text:?}");
        }
    }
}
