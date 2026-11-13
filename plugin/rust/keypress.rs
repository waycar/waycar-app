//! Terminal input decoded into keys the way Node's
//! `readline.emitKeypressEvents` does (the popup's `readKeys`).
//!
//! Only what the popup reads is kept of a key: its name when that is one of
//! the names it tests for, and whether Ctrl was held. The decoder is a port
//! of Node's `emitKeys` generator, including how many characters each
//! sequence takes and the timeout that turns a lone ESC into the escape key.

use std::time::Duration;

/// How long a trailing ESC waits for the rest of a sequence (Node's
/// `ESCAPE_CODE_TIMEOUT`).
pub const ESCAPE_CODE_TIMEOUT: Duration = Duration::from_millis(500);

const ESC: char = '\u{1b}';

/// The key names the popup distinguishes; every other name is `Other`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Name {
    /// A letter or digit (lowercased), or the letter a Ctrl chord stands for.
    Char(char),
    Up,
    Down,
    Return,
    Escape,
    Space,
    Other,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Key {
    pub name: Name,
    pub ctrl: bool,
}

impl Key {
    pub fn plain(name: Name) -> Self {
        Self { name, ctrl: false }
    }

    pub fn ctrl(letter: char) -> Self {
        Self {
            name: Name::Char(letter),
            ctrl: true,
        }
    }

    pub fn is_char(self, letter: char) -> bool {
        self.name == Name::Char(letter)
    }
}

/// One character, or `None` for the empty string Node feeds its decoder when
/// the escape timeout fires.
type Ch = Option<char>;

/// The decoder ran out of characters mid-sequence.
struct NeedMore;

struct Source<'a> {
    chars: &'a [char],
    pos: usize,
    /// The escape timeout fired: the first missing character reads as empty.
    flushing: bool,
}

impl Source<'_> {
    fn next(&mut self) -> Result<Ch, NeedMore> {
        match self.chars.get(self.pos) {
            Some(&c) => {
                self.pos += 1;
                Ok(Some(c))
            }
            None if self.flushing => Ok(None),
            None => Err(NeedMore),
        }
    }
}

fn is_digit(ch: Ch) -> bool {
    ch.is_some_and(|c| c.is_ascii_digit())
}

/// What the sequence after `ESC O` or `ESC [` names, for the keys the popup
/// reads. `modifier` and the code follow Node's table; ctrl-ness of a named
/// key never matters to the popup, so only the name is kept.
fn sequence_name(code: &str) -> Name {
    match code {
        "[A" | "OA" | "[a" | "Oa" => Name::Up,
        "[B" | "OB" | "[b" | "Ob" => Name::Down,
        _ => Name::Other,
    }
}

/// Decode one key from the front of `chars`: the key and how many characters
/// it took, `None` when nothing is emitted for them (the timeout fired with
/// no key pending), or `NeedMore`.
fn parse_key(chars: &[char], flushing: bool) -> Result<Option<(Key, usize)>, NeedMore> {
    let mut src = Source {
        chars,
        pos: 0,
        flushing,
    };
    let mut ch = src.next()?;
    if ch.is_none() {
        // The timeout fired with no sequence pending: nothing was typed.
        return Ok(None);
    }
    let mut escaped = false;
    let mut ctrl = false;

    if ch == Some(ESC) {
        escaped = true;
        ch = src.next()?;
        if ch == Some(ESC) {
            ch = src.next()?;
        }
    }

    let name = if escaped && matches!(ch, Some('O' | '[')) {
        let mut code = String::new();
        let mut modifier = 0i32;
        if ch == Some('O') {
            // ESC O letter, ESC O modifier letter
            code.push('O');
            ch = src.next()?;
            if let Some(digit) = ch.and_then(|c| c.to_digit(10)) {
                modifier = digit as i32 - 1;
                ch = src.next()?;
            }
            code.extend(ch);
        } else {
            // ESC [ letter, ESC [ modifier letter, ESC [ [ ..., ESC [ digits ~
            code.push('[');
            ch = src.next()?;
            if ch == Some('[') {
                code.push('[');
                ch = src.next()?;
            }
            let mut cmd = String::new();
            cmd.extend(ch);
            if is_digit(ch) {
                ch = src.next()?;
                cmd.extend(ch);
                if is_digit(ch) {
                    ch = src.next()?;
                    cmd.extend(ch);
                    if is_digit(ch) {
                        ch = src.next()?;
                        cmd.extend(ch);
                    }
                }
            }
            if ch == Some(';') {
                ch = src.next()?;
                cmd.extend(ch);
                if is_digit(ch) {
                    cmd.extend(src.next()?);
                }
            }
            match split_command(&cmd) {
                Some((suffix, parsed)) => {
                    code.push_str(&suffix);
                    modifier = parsed;
                }
                None => code.push_str(&cmd),
            }
        }
        ctrl = modifier & 4 != 0 || matches!(code.as_str(), "Oa" | "Ob" | "Oc" | "Od" | "Oe");
        sequence_name(&code)
    } else {
        match ch {
            Some('\r') => Name::Return,
            Some('\n' | '\t' | '\u{8}' | '\u{7f}') => Name::Other,
            Some(ESC) => Name::Escape,
            Some(' ') => Name::Space,
            Some(c) if !escaped && c <= '\u{1a}' => {
                ctrl = true;
                // Ctrl-A is 1: the chord's letter is the code plus 96.
                Name::Char((c as u8 + 96) as char)
            }
            Some(c) if c.is_ascii_alphanumeric() => Name::Char(c.to_ascii_lowercase()),
            // An escape sequence timeout: ESC alone is the escape key.
            None if escaped => Name::Escape,
            _ => Name::Other,
        }
    };
    Ok(Some((Key { name, ctrl }, src.pos)))
}

/// Split the tail of an `ESC [` sequence into the code it adds and its
/// modifier: `24;5~` is (`24~`, 4), `1;5H` is (`H`, 4). `None` when the tail
/// is neither shape, and is then appended to the code as is.
fn split_command(cmd: &str) -> Option<(String, i32)> {
    let bytes = cmd.as_bytes();
    // /^(?:(\d\d?)(?:;(\d))?([~^$])|(\d{3}~))$/
    let digits = bytes.iter().take_while(|b| b.is_ascii_digit()).count();
    let rest = &bytes[digits..];
    if digits == 3 && rest == b"~" {
        return Some((cmd.to_string(), 0));
    }
    if (1..=2).contains(&digits) {
        let (modifier, tail) = match rest {
            [b';', m, tail @ ..] if m.is_ascii_digit() => (i32::from(m - b'0') - 1, tail),
            tail => (0, tail),
        };
        if let [end @ (b'~' | b'^' | b'$')] = tail {
            return Some((format!("{}{}", &cmd[..digits], *end as char), modifier));
        }
    }
    // /^((\d;)?(\d))?([A-Za-z])$/
    let (modifier, tail) = match bytes {
        [d, b';', m, tail @ ..] if d.is_ascii_digit() && m.is_ascii_digit() => {
            (i32::from(m - b'0') - 1, tail)
        }
        [m, tail @ ..] if m.is_ascii_digit() => (i32::from(m - b'0') - 1, tail),
        tail => (0, tail),
    };
    match tail {
        [letter] if letter.is_ascii_alphabetic() => {
            Some((((*letter) as char).to_string(), modifier))
        }
        _ => None,
    }
}

/// Turns terminal bytes into keys, holding a half-received UTF-8 character or
/// escape sequence until the rest arrives.
#[derive(Debug, Default)]
pub struct Decoder {
    bytes: Vec<u8>,
    pending: Vec<char>,
}

impl Decoder {
    /// Decode `input`, calling `on_key` for each key. Returns whether the
    /// chunk ended in ESC, which the caller times out
    /// ([`ESCAPE_CODE_TIMEOUT`]) with [`Decoder::flush`].
    pub fn feed(&mut self, input: &[u8], on_key: &mut impl FnMut(Key)) -> bool {
        self.bytes.extend_from_slice(input);
        let mut text = String::new();
        loop {
            match std::str::from_utf8(&self.bytes) {
                Ok(valid) => {
                    text.push_str(valid);
                    self.bytes.clear();
                    break;
                }
                Err(error) => {
                    let (valid, rest) = self.bytes.split_at(error.valid_up_to());
                    text.push_str(std::str::from_utf8(valid).unwrap_or_default());
                    match error.error_len() {
                        Some(bad) => {
                            text.push(char::REPLACEMENT_CHARACTER);
                            self.bytes.drain(..error.valid_up_to() + bad);
                        }
                        // A character cut by the end of the read.
                        None => {
                            let keep = rest.len();
                            self.bytes.drain(..self.bytes.len() - keep);
                            break;
                        }
                    }
                }
            }
        }
        let ends_in_escape = text.ends_with(ESC);
        self.pending.extend(text.chars());
        self.drain(false, on_key);
        ends_in_escape
    }

    /// The escape timeout fired: a pending sequence ends where it stands.
    pub fn flush(&mut self, on_key: &mut impl FnMut(Key)) {
        self.drain(true, on_key);
    }

    fn drain(&mut self, flushing: bool, on_key: &mut impl FnMut(Key)) {
        let mut used = 0;
        while used < self.pending.len() {
            match parse_key(&self.pending[used..], flushing) {
                Ok(Some((key, taken))) => {
                    used += taken;
                    on_key(key);
                }
                Ok(None) | Err(NeedMore) => break,
            }
        }
        self.pending.drain(..used);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn keys(input: &[u8]) -> Vec<Key> {
        let mut decoder = Decoder::default();
        let mut out = Vec::new();
        decoder.feed(input, &mut |key| out.push(key));
        out
    }

    fn flushed(input: &[u8]) -> Vec<Key> {
        let mut decoder = Decoder::default();
        let mut out = Vec::new();
        decoder.feed(input, &mut |key| out.push(key));
        decoder.flush(&mut |key| out.push(key));
        out
    }

    #[test]
    fn plain_characters() {
        assert_eq!(
            keys(b"qQ7 \r\nx"),
            vec![
                Key::plain(Name::Char('q')),
                Key::plain(Name::Char('q')),
                Key::plain(Name::Char('7')),
                Key::plain(Name::Space),
                Key::plain(Name::Return),
                Key::plain(Name::Other),
                Key::plain(Name::Char('x')),
            ]
        );
    }

    #[test]
    fn control_chords_name_their_letter() {
        assert_eq!(keys(b"\x03"), vec![Key::ctrl('c')]);
        assert_eq!(keys(b"\x11\x01"), vec![Key::ctrl('q'), Key::ctrl('a')]);
        // Ctrl - arrives as \x1f, past the letters: readline names it nothing.
        assert_eq!(keys(b"\x1f"), vec![Key::plain(Name::Other)]);
    }

    #[test]
    fn arrows_in_both_encodings_with_and_without_modifiers() {
        for (input, name) in [
            (&b"\x1b[A"[..], Name::Up),
            (b"\x1bOA", Name::Up),
            (b"\x1b[1;5A", Name::Up),
            (b"\x1b[B", Name::Down),
            (b"\x1bOB", Name::Down),
            (b"\x1b[1;2B", Name::Down),
            (b"\x1b[C", Name::Other),
            (b"\x1b[3~", Name::Other),
            (b"\x1b[24;5~", Name::Other),
            (b"\x1b[[A", Name::Other),
            (b"\x1b[200~", Name::Other),
        ] {
            assert_eq!(keys(input).len(), 1, "{input:?}");
            assert_eq!(keys(input)[0].name, name, "{input:?}");
        }
    }

    #[test]
    fn alt_letters_keep_the_letter() {
        assert_eq!(keys(b"\x1bc"), vec![Key::plain(Name::Char('c'))]);
        assert_eq!(keys(b"\x1b\x03"), vec![Key::plain(Name::Other)]);
    }

    #[test]
    fn a_sequence_split_across_reads_waits_for_the_rest() {
        let mut decoder = Decoder::default();
        let mut out = Vec::new();
        assert!(!decoder.feed(b"\x1b[", &mut |key| out.push(key)));
        assert!(out.is_empty());
        decoder.feed(b"B", &mut |key| out.push(key));
        assert_eq!(out, vec![Key::plain(Name::Down)]);
    }

    #[test]
    fn a_lone_escape_is_the_escape_key_after_the_timeout() {
        let mut decoder = Decoder::default();
        let mut out = Vec::new();
        assert!(decoder.feed(b"\x1b", &mut |key| out.push(key)));
        assert!(out.is_empty());
        decoder.flush(&mut |key| out.push(key));
        assert_eq!(out, vec![Key::plain(Name::Escape)]);
        decoder.flush(&mut |key| out.push(key));
        assert_eq!(out.len(), 1);
    }

    #[test]
    fn a_cut_sequence_ends_at_the_timeout_as_an_unnamed_key() {
        assert_eq!(flushed(b"\x1b["), vec![Key::plain(Name::Other)]);
        assert_eq!(flushed(b"\x1b[1"), vec![Key::plain(Name::Other)]);
        assert_eq!(flushed(b"\x1b\x1b"), vec![Key::plain(Name::Escape)]);
    }

    #[test]
    fn multibyte_characters_survive_a_split_read() {
        let mut decoder = Decoder::default();
        let mut out = Vec::new();
        decoder.feed(&[0xe2, 0x82], &mut |key| out.push(key));
        assert!(out.is_empty());
        decoder.feed(&[0xac, b'a'], &mut |key| out.push(key));
        assert_eq!(
            out,
            vec![Key::plain(Name::Other), Key::plain(Name::Char('a'))]
        );
    }
}
