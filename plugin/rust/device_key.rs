//! Strict validation of a submitted Device Key public line (device-key.js,
//! ADR 0007).
//!
//! The Enrollment accept entrypoint runs as an sshd forced command and appends
//! whatever passes this parser to authorized_keys, so the rules are strict:
//! exactly one bare `ssh-ed25519 <blob> [comment]` line, the wire blob must be
//! a well-formed Ed25519 public key, and the comment must be printable ASCII.
//! Anything else is rejected without consuming the Bootstrap Key.

use std::fmt;

use crate::base64;
use crate::host_key::fingerprint_of_blob;
use crate::jsx;

const KEY_TYPE: &str = "ssh-ed25519";
const ED25519_KEY_BYTES: usize = 32;
const MAX_LINE_LENGTH: usize = 1024;

/// A rejected submission; the message is the one the JS `DeviceKeyError` has.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceKeyError(pub String);

impl fmt::Display for DeviceKeyError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for DeviceKeyError {}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceKey {
    /// The canonical authorized_keys line.
    pub line: String,
    pub fingerprint: String,
}

fn fail<T>(message: impl Into<String>) -> Result<T, DeviceKeyError> {
    Err(DeviceKeyError(message.into()))
}

/// One SSH wire string at `offset`: its bytes and the offset after it.
fn read_ssh_string(buffer: &[u8], offset: usize) -> Result<(&[u8], usize), DeviceKeyError> {
    let Some(length) = buffer.get(offset..offset + 4) else {
        return fail("truncated key blob");
    };
    let length = u32::from_be_bytes([length[0], length[1], length[2], length[3]]) as usize;
    let end = offset + 4 + length;
    match buffer.get(offset + 4..end) {
        Some(value) => Ok((value, end)),
        None => fail("truncated key blob"),
    }
}

/// Parse and strictly validate a submitted Device Key public line (one line,
/// whitespace around it tolerated).
pub fn parse_device_key_line(input: &str) -> Result<DeviceKey, DeviceKeyError> {
    if jsx::utf16_len(input) > MAX_LINE_LENGTH {
        return fail(format!("submission exceeds {MAX_LINE_LENGTH} characters"));
    }
    let line = jsx::trim(input);
    if line.is_empty() {
        return fail("submission is empty");
    }
    if line.contains(['\n', '\r']) {
        return fail("submission must be a single line");
    }

    let mut fields = line.splitn(3, ' ');
    if fields.next() != Some(KEY_TYPE) {
        return fail(format!("key type must be {KEY_TYPE}"));
    }
    let Some(blob_text) = fields.next().filter(|text| base64::is_standard_text(text)) else {
        return fail("key blob is not base64");
    };
    let comment = fields.next().unwrap_or("");

    let blob = base64::decode(blob_text);
    let (kind, after_kind) = read_ssh_string(&blob, 0)?;
    if kind != KEY_TYPE.as_bytes() {
        return fail("key blob type disagrees with the line type");
    }
    let (key, end) = read_ssh_string(&blob, after_kind)?;
    if key.len() != ED25519_KEY_BYTES {
        return fail(format!(
            "Ed25519 public key must be {ED25519_KEY_BYTES} bytes"
        ));
    }
    if end != blob.len() {
        return fail("key blob has trailing bytes");
    }

    // Space through tilde: printable ASCII only, no tabs or control characters.
    if !comment.bytes().all(|b| (0x20..=0x7e).contains(&b)) {
        return fail("comment must be printable ASCII");
    }

    // Re-emit the blob from the decoded bytes so authorized_keys only ever
    // receives canonical base64, whatever padding the submission used.
    let canonical_blob = base64::encode_standard(&blob);
    let line = if comment.is_empty() {
        format!("{KEY_TYPE} {canonical_blob}")
    } else {
        format!("{KEY_TYPE} {canonical_blob} {comment}")
    };
    Ok(DeviceKey {
        line,
        fingerprint: fingerprint_of_blob(&blob),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    // Generated with ssh-keygen; fingerprint confirmed via `ssh-keygen -lf`.
    const BLOB: &str = "AAAAC3NzaC1lZDI1NTE5AAAAIMYSCTemrZWEXptQyehHLI9kbqjHxNUGtQN2lF1ucCce";
    const FINGERPRINT: &str = "SHA256:ef+f9Jda6ZPkcW5GiL7pQZXJ57mCFnFAGkir3AcfTIM";

    fn assert_rejects(input: &str) {
        assert!(
            parse_device_key_line(input).is_err(),
            "expected rejection for {input:?}"
        );
    }

    fn ssh_string(chunk: &[u8]) -> Vec<u8> {
        let mut out = (chunk.len() as u32).to_be_bytes().to_vec();
        out.extend_from_slice(chunk);
        out
    }

    fn blob_of(kind: &[u8], key: &[u8]) -> String {
        base64::encode_standard(&[ssh_string(kind), ssh_string(key)].concat())
    }

    #[test]
    fn accepts_a_bare_ed25519_line() {
        let parsed = parse_device_key_line(&format!("ssh-ed25519 {BLOB}")).unwrap();
        assert_eq!(parsed.line, format!("ssh-ed25519 {BLOB}"));
        assert_eq!(parsed.fingerprint, FINGERPRINT);
    }

    #[test]
    fn accepts_a_comment_and_keeps_it_in_the_canonical_line() {
        let parsed = parse_device_key_line(&format!("ssh-ed25519 {BLOB} waycar iPhone")).unwrap();
        assert_eq!(parsed.line, format!("ssh-ed25519 {BLOB} waycar iPhone"));
        assert_eq!(parsed.fingerprint, FINGERPRINT);
    }

    #[test]
    fn trims_surrounding_whitespace_and_a_trailing_newline() {
        let parsed = parse_device_key_line(&format!("  ssh-ed25519 {BLOB} phone\n")).unwrap();
        assert_eq!(parsed.line, format!("ssh-ed25519 {BLOB} phone"));
    }

    #[test]
    fn rejects_non_ed25519_key_types() {
        assert_rejects(&format!("ssh-rsa {BLOB}"));
        assert_rejects(&format!("ecdsa-sha2-nistp256 {BLOB}"));
    }

    #[test]
    fn rejects_authorized_keys_options_smuggled_before_the_key() {
        assert_rejects(&format!("restrict,command=\"evil\" ssh-ed25519 {BLOB}"));
        assert_rejects(&format!("command=\"evil\" ssh-ed25519 {BLOB}"));
    }

    #[test]
    fn rejects_a_blob_whose_inner_type_disagrees_with_the_outer_type() {
        let blob = blob_of(b"ssh-rsa", &[7; 32]);
        let error = parse_device_key_line(&format!("ssh-ed25519 {blob}")).unwrap_err();
        assert_eq!(error.0, "key blob type disagrees with the line type");
    }

    #[test]
    fn rejects_a_blob_with_the_wrong_key_length() {
        let blob = blob_of(b"ssh-ed25519", &[7; 31]);
        let error = parse_device_key_line(&format!("ssh-ed25519 {blob}")).unwrap_err();
        assert_eq!(error.0, "Ed25519 public key must be 32 bytes");
    }

    #[test]
    fn rejects_a_blob_with_trailing_bytes() {
        let mut raw = base64::decode(BLOB);
        raw.push(1);
        let error =
            parse_device_key_line(&format!("ssh-ed25519 {}", base64::encode_standard(&raw)))
                .unwrap_err();
        assert_eq!(error.0, "key blob has trailing bytes");
    }

    #[test]
    fn rejects_malformed_input() {
        assert_rejects("");
        assert_rejects("   \n");
        assert_rejects("ssh-ed25519");
        assert_rejects("ssh-ed25519 !!!not-base64!!!");
        assert_rejects("just some words");
    }

    #[test]
    fn rejects_embedded_newlines() {
        assert_rejects(&format!("ssh-ed25519 {BLOB} a\nssh-ed25519 {BLOB} b"));
    }

    #[test]
    fn rejects_comments_with_control_or_non_ascii_characters() {
        assert_rejects(&format!("ssh-ed25519 {BLOB} bad\tcomment"));
        assert_rejects(&format!("ssh-ed25519 {BLOB} bad\u{7}comment"));
        assert_rejects(&format!("ssh-ed25519 {BLOB} téléphone"));
    }

    #[test]
    fn rejects_an_overlong_line() {
        let error =
            parse_device_key_line(&format!("ssh-ed25519 {BLOB} {}", "x".repeat(2000))).unwrap_err();
        assert_eq!(error.0, "submission exceeds 1024 characters");
    }

    #[test]
    fn messages_follow_the_js_ones() {
        let message = |input: &str| parse_device_key_line(input).unwrap_err().0;
        assert_eq!(message(""), "submission is empty");
        assert_eq!(
            message(&format!("ssh-ed25519 {BLOB} a\nb")),
            "submission must be a single line"
        );
        assert_eq!(message("ssh-rsa x"), "key type must be ssh-ed25519");
        assert_eq!(message("ssh-ed25519"), "key blob is not base64");
        assert_eq!(message("ssh-ed25519 A"), "truncated key blob");
        assert_eq!(
            message(&format!("ssh-ed25519 {BLOB} \u{7}")),
            "comment must be printable ASCII"
        );
    }

    #[test]
    fn re_emits_the_blob_as_canonical_base64() {
        // Padding after a blob that needs none is dropped.
        let parsed = parse_device_key_line(&format!("ssh-ed25519 {BLOB}=")).unwrap();
        assert_eq!(parsed.line, format!("ssh-ed25519 {BLOB}"));
    }
}
