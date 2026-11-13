//! Clipboard helper for the pairing popup's QR screen (copy-pairing-code.js,
//! #204).
//!
//! macOS: write the exact Pairing Code string to the pasteboard via `pbcopy`.
//! Anywhere else, or if `pbcopy` is missing or fails: the caller prints the
//! code so it can be selected by hand. No format change: the v1 envelope is
//! copied as is.

use std::io::{self, Write};
use std::process::{Command, Stdio};

use crate::keypress::{Key, Name};
use crate::pairing_qr::Layout;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyAction {
    Copy,
    Close,
    Ignore,
}

/// What a keypress on the QR screen should do. `c` copies and stays. On the
/// full-size (half-block) QR any other key closes; on the compact (sextant)
/// QR and on screens without a QR only the popup's global q / Esc / Ctrl-C
/// close, because those screens advise zooming out and a zoom shortcut the
/// terminal passes through (Ctrl - sends `\x1f`) must not end pairing. No
/// `layout` (no QR screen drawn yet) behaves like the full-size QR.
pub fn qr_key_action(key: Key, layout: Option<Layout>) -> KeyAction {
    if key.name == Name::Char('c') && !key.ctrl {
        return KeyAction::Copy;
    }
    match layout {
        None | Some(Layout::HalfBlock) => KeyAction::Close,
        Some(_) => KeyAction::Ignore,
    }
}

/// Run `program` with `input` on its stdin and its output discarded; whether
/// it exited 0. An error means it could not be started.
pub fn run_with_input(program: &str, input: &[u8]) -> io::Result<bool> {
    let mut child = Command::new(program)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()?;
    // A write that fails (the program closed its stdin) is a failed copy,
    // but the child still has to be reaped.
    let written = match child.stdin.take() {
        Some(mut stdin) => stdin.write_all(input).is_ok(),
        None => false,
    };
    let status = child.wait()?;
    Ok(written && status.success())
}

/// Copy `code` to the macOS pasteboard with `spawn` (`run_with_input` in
/// production; tests pass a fake). Anything else is a failed copy, not an
/// error.
pub fn copy_pairing_code(
    code: &str,
    macos: bool,
    spawn: impl FnOnce(&str, &[u8]) -> io::Result<bool>,
) -> bool {
    if code.is_empty() || !macos {
        return false;
    }
    spawn("pbcopy", code.as_bytes()).unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::{Cell, RefCell};

    fn key(name: Name) -> Key {
        Key::plain(name)
    }

    const ALL_LAYOUTS: [Layout; 4] = [
        Layout::HalfBlock,
        Layout::Sextant,
        Layout::TooSmall,
        Layout::CodeOnly,
    ];

    #[test]
    fn plain_c_copies_and_stays_on_the_qr_screen() {
        assert_eq!(qr_key_action(key(Name::Char('c')), None), KeyAction::Copy);
    }

    #[test]
    fn any_other_key_closes_including_ctrl_c_and_unnamed_presses() {
        assert_eq!(qr_key_action(Key::ctrl('c'), None), KeyAction::Close);
        for name in [Name::Char('q'), Name::Escape, Name::Return, Name::Other] {
            assert_eq!(qr_key_action(key(name), None), KeyAction::Close);
        }
    }

    #[test]
    fn c_copies_on_every_layout() {
        for layout in ALL_LAYOUTS {
            assert_eq!(
                qr_key_action(key(Name::Char('c')), Some(layout)),
                KeyAction::Copy
            );
        }
    }

    #[test]
    fn a_passed_through_ctrl_minus_closes_only_the_full_size_qr() {
        // Ctrl - arrives as \x1f, which readline names nothing.
        let ctrl_minus = key(Name::Other);
        assert_eq!(
            qr_key_action(ctrl_minus, Some(Layout::HalfBlock)),
            KeyAction::Close
        );
        for layout in [Layout::Sextant, Layout::TooSmall, Layout::CodeOnly] {
            assert_eq!(qr_key_action(ctrl_minus, Some(layout)), KeyAction::Ignore);
        }
    }

    const CODE: &str = "HERDR-PAIR:1:exact-bytes-no-newline";

    #[test]
    fn on_macos_pbcopy_receives_the_exact_string_and_no_trailing_newline() {
        let seen = RefCell::new((String::new(), Vec::new()));
        let copied = copy_pairing_code(CODE, true, |program, input| {
            *seen.borrow_mut() = (program.to_string(), input.to_vec());
            Ok(true)
        });
        assert!(copied);
        assert_eq!(
            *seen.borrow(),
            ("pbcopy".to_string(), CODE.as_bytes().to_vec())
        );
    }

    #[test]
    fn a_missing_pbcopy_is_a_failed_copy_not_an_error() {
        let copied = copy_pairing_code(CODE, true, |_, _| {
            Err(io::Error::from(io::ErrorKind::NotFound))
        });
        assert!(!copied);
    }

    #[test]
    fn a_non_zero_pbcopy_exit_is_a_failed_copy() {
        assert!(!copy_pairing_code(CODE, true, |_, _| Ok(false)));
    }

    #[test]
    fn other_platforms_do_not_spawn_pbcopy() {
        let spawned = Cell::new(false);
        let copied = copy_pairing_code(CODE, false, |_, _| {
            spawned.set(true);
            Ok(true)
        });
        assert!(!copied);
        assert!(!spawned.get());
    }

    #[test]
    fn an_empty_code_is_not_copied() {
        let spawned = Cell::new(false);
        let copied = copy_pairing_code("", true, |_, _| {
            spawned.set(true);
            Ok(true)
        });
        assert!(!copied);
        assert!(!spawned.get());
    }

    #[test]
    fn a_real_child_gets_the_bytes_and_its_exit_status_decides() {
        assert!(run_with_input("cat", CODE.as_bytes()).unwrap());
        assert!(!run_with_input("false", CODE.as_bytes()).unwrap());
        assert!(run_with_input("waycar-no-such-program", b"x").is_err());
    }
}
