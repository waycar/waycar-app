//! Atomic authorized_keys editing for the Bootstrap Key lifecycle
//! (authorized-keys.js, ADR 0007).
//!
//! Every mutation goes through [`edit_authorized_keys`]: an exclusive lock,
//! then a rewrite through a temp file in the same directory, then a rename.
//! The file mode is kept (0600 for a fresh file) so sshd's StrictModes keeps
//! accepting it. Bootstrap lines carry a marker comment
//! `herdr-pairing:<id>:exp:<unix-seconds>` so cleanup and the startup sweep
//! find them with no state beyond the file itself.

use std::path::{Path, PathBuf};

use crate::atomic::edit_locked;
use crate::error::{CliError, Result};
use crate::host_key::split_words;
use crate::jsx;

/// Names the lock and temp files next to authorized_keys.
const LOCK_TAG: &str = "herdr-pairing";
const MARKER: &str = "herdr-pairing:";

/// `<home>/.ssh/authorized_keys`: where sshd reads it under StrictModes.
pub fn path(home: &Path) -> PathBuf {
    home.join(".ssh").join("authorized_keys")
}

/// The restricted Bootstrap Key line:
/// `restrict,command="<command>" <public line> herdr-pairing:<id>:exp:<unix>`.
///
/// `public_line` is the bare `ssh-ed25519 <blob>`, `pairing_id` alphanumeric
/// or hyphen, `expires_at` unix seconds, `command` the forced command.
pub fn bootstrap_line(
    public_line: &str,
    pairing_id: &str,
    expires_at: i64,
    command: &str,
) -> Result<String> {
    if command.contains(['"', '\n', '\r']) {
        return Err(CliError::failure(
            "forced command must not contain double quotes or newlines",
        ));
    }
    if pairing_id.is_empty()
        || !pairing_id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-')
    {
        return Err(CliError::failure("pairing id must be alphanumeric/hyphen"));
    }
    if expires_at <= 0 {
        return Err(CliError::failure(
            "expiresAt must be a positive unix-seconds integer",
        ));
    }
    Ok(format!(
        "restrict,command=\"{command}\" {public_line} {MARKER}{pairing_id}:exp:{expires_at}"
    ))
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BootstrapMarker<'a> {
    pub pairing_id: &'a str,
    pub expires_at: u64,
}

/// The marker comment of a Bootstrap Key line; none for any other line.
///
/// `/(?:^|\s)herdr-pairing:([A-Za-z0-9-]+):exp:(\d+)$/` read from the end:
/// the digits, `:exp:`, the id run, the marker word, and a space or the start.
pub fn parse_bootstrap_line(line: &str) -> Option<BootstrapMarker<'_>> {
    let without_digits = line.trim_end_matches(|c: char| c.is_ascii_digit());
    let digits = &line[without_digits.len()..];
    if digits.is_empty() {
        return None;
    }
    let before_exp = without_digits.strip_suffix(":exp:")?;
    let before_id = before_exp.trim_end_matches(|c: char| c.is_ascii_alphanumeric() || c == '-');
    let pairing_id = &before_exp[before_id.len()..];
    if pairing_id.is_empty() {
        return None;
    }
    let before_marker = before_id.strip_suffix(MARKER)?;
    if !(before_marker.is_empty() || before_marker.ends_with(jsx::is_js_space)) {
        return None;
    }
    Some(BootstrapMarker {
        pairing_id,
        // A number too large for u64 is far past any clock, as in JavaScript.
        expires_at: digits.parse().unwrap_or(u64::MAX),
    })
}

/// Edit `~/.ssh/authorized_keys` under the pairing lock.
///
/// `edit` gets the current lines (no trailing empty line) and returns the new
/// ones, or `None` to leave the file alone; an error from it leaves the file
/// alone too and is returned. Returns whether the file was rewritten.
pub fn edit_authorized_keys(
    home: &Path,
    edit: impl FnOnce(Vec<String>) -> Result<Option<Vec<String>>>,
) -> Result<bool> {
    let mut failure = None;
    let rewritten = edit_locked(&path(home), LOCK_TAG, |lines| match edit(lines) {
        Ok(edited) => edited,
        Err(error) => {
            failure = Some(error);
            None
        }
    })?;
    match failure {
        Some(error) => Err(error),
        None => Ok(rewritten),
    }
}

/// Startup sweep: remove every Bootstrap Key line whose expiry has passed at
/// `now`. Lines still inside their TTL stay (another pairing may be in
/// flight). Returns how many were removed.
pub fn sweep_expired_bootstrap_lines(home: &Path, now: i64) -> Result<usize> {
    let mut removed = 0;
    edit_authorized_keys(home, |lines| {
        let before = lines.len();
        let kept: Vec<String> = lines
            .into_iter()
            .filter(|line| {
                parse_bootstrap_line(line)
                    .is_none_or(|marker| i128::from(marker.expires_at) > i128::from(now))
            })
            .collect();
        removed = before - kept.len();
        Ok((removed > 0).then_some(kept))
    })?;
    Ok(removed)
}

/// Where the `<type> <blob>` words of a public key line start and how many
/// words of the line there are: an options word may come first.
fn identity_words(line: &str) -> (Vec<&str>, usize) {
    let words = split_words(jsx::trim(line));
    let start = if words[0].starts_with("ssh-") || words[0].starts_with("ecdsa-") {
        0
    } else {
        1
    };
    (words, start)
}

/// The `<type> <blob>` identity of a public key line, ignoring the comment.
pub fn key_blob_of(line: &str) -> String {
    let (words, start) = identity_words(line);
    words
        .get(start..)
        .unwrap_or_default()
        .iter()
        .take(2)
        .copied()
        .collect::<Vec<_>>()
        .join(" ")
}

/// The comment (everything after `<type> <blob>`) of a public key line.
pub fn comment_of(line: &str) -> String {
    let (words, start) = identity_words(line);
    words.get(start + 2..).unwrap_or_default().join(" ")
}

/// Remove every authorized_keys line whose key blob matches `line`'s. Used to
/// revoke an enrolled Device Key; matching on the blob, not the whole line,
/// makes the revoke robust to comment differences. Returns whether a line
/// was removed.
pub fn remove_key_line(home: &Path, line: &str) -> Result<bool> {
    let target = key_blob_of(line);
    edit_authorized_keys(home, |lines| {
        let before = lines.len();
        let kept: Vec<String> = lines
            .into_iter()
            .filter(|existing| key_blob_of(existing) != target)
            .collect();
        Ok((kept.len() != before).then_some(kept))
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::TempDir;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use std::thread;

    const PUBLIC_LINE: &str =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMYSCTemrZWEXptQyehHLI9kbqjHxNUGtQN2lF1ucCce";
    const USER_LINE: &str =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBPd+KiPbQwFzIFqVCaK0me6kR0BrPZ9HFcsl7WKcFXC laptop";

    struct Home(TempDir);

    impl Home {
        fn new(label: &str) -> Self {
            Self(TempDir::new(label))
        }

        fn keys(&self) -> String {
            fs::read_to_string(path(self.0.path())).unwrap()
        }
    }

    fn mode(path: &Path) -> u32 {
        fs::metadata(path).unwrap().permissions().mode() & 0o777
    }

    fn set(home: &Path, lines: &[&str]) {
        let lines: Vec<String> = lines.iter().map(|l| l.to_string()).collect();
        edit_authorized_keys(home, |_| Ok(Some(lines))).unwrap();
    }

    // bootstrapLine
    #[test]
    fn carries_restrict_the_forced_command_and_the_marker_comment() {
        let line = bootstrap_line(
            PUBLIC_LINE,
            "abc123",
            1753305600,
            "'/usr/local/bin/waycar' pair-accept --pairing-id abc123",
        )
        .unwrap();
        assert_eq!(
            line,
            format!(
                "restrict,command=\"'/usr/local/bin/waycar' pair-accept --pairing-id abc123\" {PUBLIC_LINE} herdr-pairing:abc123:exp:1753305600"
            )
        );
    }

    #[test]
    fn rejects_a_command_containing_a_double_quote_or_newline() {
        for command in ["echo \"hi\"", "line1\nline2", "a\rb"] {
            assert_eq!(
                bootstrap_line(PUBLIC_LINE, "a", 1, command)
                    .unwrap_err()
                    .message(),
                "forced command must not contain double quotes or newlines"
            );
        }
    }

    #[test]
    fn rejects_a_bad_pairing_id_or_expiry() {
        for id in ["", "a b", "a:b", "a\n", "é"] {
            assert!(bootstrap_line(PUBLIC_LINE, id, 1, "cmd").is_err(), "{id:?}");
        }
        for expires_at in [0, -5] {
            assert!(bootstrap_line(PUBLIC_LINE, "a", expires_at, "cmd").is_err());
        }
    }

    // parseBootstrapLine
    #[test]
    fn parses_the_marker_of_a_bootstrap_line_only() {
        let line = bootstrap_line(PUBLIC_LINE, "ab-12", 1753305600, "cmd").unwrap();
        assert_eq!(
            parse_bootstrap_line(&line),
            Some(BootstrapMarker {
                pairing_id: "ab-12",
                expires_at: 1753305600
            })
        );
        assert_eq!(
            parse_bootstrap_line("herdr-pairing:x:exp:5"),
            Some(BootstrapMarker {
                pairing_id: "x",
                expires_at: 5
            })
        );
        for other in [
            USER_LINE,
            "",
            "xherdr-pairing:x:exp:5",
            "herdr-pairing:x:exp:5 ",
            "herdr-pairing:x:exp:",
            "herdr-pairing::exp:5",
            "herdr-pairing:a:b:exp:5",
            "herdr-pairing:a:exp:12:exp:34",
            "herdr-pairing:x:exp:5x",
        ] {
            assert_eq!(parse_bootstrap_line(other), None, "{other:?}");
        }
        // JavaScript whitespace, not just a space, may precede the marker.
        assert!(parse_bootstrap_line("key\u{a0}herdr-pairing:x:exp:5").is_some());
    }

    // editAuthorizedKeys
    #[test]
    fn creates_ssh_and_authorized_keys_with_strictmodes_safe_permissions() {
        let home = Home::new("create");
        set(home.0.path(), &[USER_LINE]);
        assert_eq!(home.keys(), format!("{USER_LINE}\n"));
        assert_eq!(mode(&home.0.path().join(".ssh")), 0o700);
        assert_eq!(mode(&path(home.0.path())), 0o600);
    }

    #[test]
    fn preserves_existing_content_order_and_file_mode() {
        let home = Home::new("preserve");
        fs::create_dir_all(home.0.path().join(".ssh")).unwrap();
        fs::write(path(home.0.path()), format!("# comment\n\n{USER_LINE}\n")).unwrap();
        fs::set_permissions(path(home.0.path()), fs::Permissions::from_mode(0o644)).unwrap();
        edit_authorized_keys(home.0.path(), |mut lines| {
            lines.push(PUBLIC_LINE.to_string());
            Ok(Some(lines))
        })
        .unwrap();
        assert_eq!(
            home.keys(),
            format!("# comment\n\n{USER_LINE}\n{PUBLIC_LINE}\n")
        );
        assert_eq!(mode(&path(home.0.path())), 0o644);
    }

    #[test]
    fn serializes_concurrent_edits() {
        let home = Home::new("concurrent");
        let threads: Vec<_> = (0..8)
            .map(|i| {
                let home = home.0.path().to_path_buf();
                thread::spawn(move || {
                    edit_authorized_keys(&home, |mut lines| {
                        lines.push(format!("{PUBLIC_LINE} key-{i}"));
                        Ok(Some(lines))
                    })
                    .unwrap();
                })
            })
            .collect();
        for thread in threads {
            thread.join().unwrap();
        }
        let keys = home.keys();
        let lines: Vec<&str> = keys.trim_end().split('\n').collect();
        assert_eq!(lines.len(), 8);
        for i in 0..8 {
            assert!(lines.contains(&format!("{PUBLIC_LINE} key-{i}").as_str()));
        }
    }

    #[test]
    fn an_error_from_the_edit_leaves_the_file_and_releases_the_lock() {
        let home = Home::new("edit-error");
        set(home.0.path(), &[USER_LINE]);
        let error =
            edit_authorized_keys(home.0.path(), |_| Err(CliError::failure("boom"))).unwrap_err();
        assert_eq!(error.message(), "boom");
        assert_eq!(home.keys(), format!("{USER_LINE}\n"));
        assert!(
            !path(home.0.path())
                .with_extension("herdr-pairing.lock")
                .exists()
        );
        set(home.0.path(), &[PUBLIC_LINE]);
    }

    // commentOf
    #[test]
    fn comment_of_a_bare_public_line() {
        assert_eq!(comment_of(USER_LINE), "laptop");
        assert_eq!(
            comment_of(&format!("{PUBLIC_LINE} herdr mobile phone")),
            "herdr mobile phone"
        );
    }

    #[test]
    fn comment_is_empty_when_there_is_none() {
        assert_eq!(comment_of(PUBLIC_LINE), "");
    }

    #[test]
    fn key_blob_skips_an_options_word() {
        assert_eq!(
            key_blob_of(USER_LINE),
            USER_LINE.rsplit_once(' ').unwrap().0
        );
        assert_eq!(
            key_blob_of(&format!("restrict {PUBLIC_LINE} note")),
            PUBLIC_LINE
        );
        assert_eq!(comment_of(&format!("restrict {PUBLIC_LINE} a  b")), "a b");
        assert_eq!(key_blob_of(""), "");
        assert_eq!(comment_of("  "), "");
    }

    // removeKeyLine
    #[test]
    fn removes_the_line_matching_the_key_blob_keeping_the_others() {
        let home = Home::new("remove");
        set(home.0.path(), &[USER_LINE, PUBLIC_LINE]);
        assert!(remove_key_line(home.0.path(), PUBLIC_LINE).unwrap());
        assert_eq!(home.keys(), format!("{USER_LINE}\n"));
    }

    #[test]
    fn matches_on_the_key_blob_even_when_the_comment_differs() {
        let home = Home::new("remove-comment");
        let phone = format!("{PUBLIC_LINE} phone");
        set(home.0.path(), &[USER_LINE, &phone]);
        remove_key_line(home.0.path(), &format!("{PUBLIC_LINE} a-different-label")).unwrap();
        assert_eq!(home.keys(), format!("{USER_LINE}\n"));
    }

    #[test]
    fn removing_an_absent_key_is_a_no_op() {
        let home = Home::new("remove-absent");
        set(home.0.path(), &[USER_LINE]);
        assert!(!remove_key_line(home.0.path(), PUBLIC_LINE).unwrap());
        assert_eq!(home.keys(), format!("{USER_LINE}\n"));
    }

    // sweepExpiredBootstrapLines
    #[test]
    fn sweep_removes_expired_pairing_lines_keeps_live_ones_and_user_lines() {
        let home = Home::new("sweep");
        let now = 1753305600;
        let expired = bootstrap_line(PUBLIC_LINE, "old", now - 1, "cmd").unwrap();
        let live = bootstrap_line(PUBLIC_LINE, "new", now + 60, "cmd").unwrap();
        set(home.0.path(), &[USER_LINE, &expired, &live]);
        assert_eq!(
            sweep_expired_bootstrap_lines(home.0.path(), now).unwrap(),
            1
        );
        assert_eq!(home.keys(), format!("{USER_LINE}\n{live}\n"));
    }

    #[test]
    fn sweep_is_a_no_op_when_the_file_does_not_exist() {
        let home = Home::new("sweep-none");
        assert_eq!(
            sweep_expired_bootstrap_lines(home.0.path(), 1753305600).unwrap(),
            0
        );
        assert!(!path(home.0.path()).exists());
    }
}
