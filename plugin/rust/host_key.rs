//! Host key fingerprint for the Pairing Code (host-key.js, ADR 0007).
//!
//! The app pins the Host's SSH fingerprint from the Pairing Code instead of
//! showing a TOFU prompt, so this must be exactly what OpenSSH prints: SHA256
//! of the public key blob, base64 without padding.

use std::fs;
use std::path::{Path, PathBuf};

use ring::digest::{SHA256, digest};

use crate::base64;
use crate::error::{CliError, Result};
use crate::jsx;

/// Where sshd keeps the host keys.
pub const DEFAULT_SSH_DIR: &str = "/etc/ssh";

/// Preference order mirrors what modern clients negotiate first.
const HOST_KEY_FILES: [&str; 3] = [
    "ssh_host_ed25519_key.pub",
    "ssh_host_ecdsa_key.pub",
    "ssh_host_rsa_key.pub",
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PublicKeyFingerprint {
    pub key_type: String,
    pub fingerprint: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostKeyFingerprint {
    pub key_type: String,
    pub fingerprint: String,
    pub path: PathBuf,
}

/// `text.trim().split(/\s+/)`: the words of already trimmed text; an empty
/// text is one empty word, as in JavaScript.
pub(crate) fn split_words(trimmed: &str) -> Vec<&str> {
    if trimmed.is_empty() {
        return vec![""];
    }
    trimmed
        .split(jsx::is_js_space)
        .filter(|word| !word.is_empty())
        .collect()
}

/// `SHA256:<unpadded base64>` of a public key blob, as `ssh-keygen -lf` prints.
pub fn fingerprint_of_blob(blob: &[u8]) -> String {
    let digest = digest(&SHA256, blob);
    let encoded = base64::encode_standard(digest.as_ref());
    format!("SHA256:{}", encoded.trim_end_matches('='))
}

/// The OpenSSH SHA256 fingerprint of a `<type> <base64 blob> [comment]` line.
pub fn fingerprint_public_key_line(line: &str) -> Result<PublicKeyFingerprint> {
    let words = split_words(jsx::trim(line));
    let key_type = words[0];
    if !key_type.starts_with("ssh-") && !key_type.starts_with("ecdsa-") {
        let mut quoted = String::new();
        jsx::write_json_string(line, &mut quoted);
        return Err(CliError::failure(format!(
            "not an SSH public key line: {quoted}"
        )));
    }
    let Some(blob) = words.get(1).filter(|blob| base64::is_standard_text(blob)) else {
        return Err(CliError::failure(
            "SSH public key line has no base64 key blob",
        ));
    };
    Ok(PublicKeyFingerprint {
        key_type: key_type.to_string(),
        fingerprint: fingerprint_of_blob(&base64::decode(blob)),
    })
}

/// The preferred host key's fingerprint in `ssh_dir` (public halves are
/// world-readable, so no privileges are needed); none when no key can be read.
pub fn read_host_key_fingerprint(ssh_dir: &Path) -> Result<Option<HostKeyFingerprint>> {
    for file in HOST_KEY_FILES {
        let path = ssh_dir.join(file);
        let Ok(bytes) = fs::read(&path) else {
            continue;
        };
        let PublicKeyFingerprint {
            key_type,
            fingerprint,
        } = fingerprint_public_key_line(&String::from_utf8_lossy(&bytes))?;
        return Ok(Some(HostKeyFingerprint {
            key_type,
            fingerprint,
            path,
        }));
    }
    Ok(None)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::TempDir;

    // Generated with ssh-keygen; fingerprint confirmed via `ssh-keygen -lf`.
    const ED25519_PUB: &str =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBPd+KiPbQwFzIFqVCaK0me6kR0BrPZ9HFcsl7WKcFXC vector";
    const ED25519_FP: &str = "SHA256:6+jncNdibsG2cqvfoLApGrO8CvIwAEMzsB+IilOs8tg";

    // fingerprintPublicKeyLine
    #[test]
    fn matches_ssh_keygen_lf_output() {
        assert_eq!(
            fingerprint_public_key_line(ED25519_PUB).unwrap(),
            PublicKeyFingerprint {
                key_type: "ssh-ed25519".into(),
                fingerprint: ED25519_FP.into()
            }
        );
    }

    #[test]
    fn accepts_a_line_without_a_comment() {
        let bare = ED25519_PUB.rsplit_once(' ').unwrap().0;
        assert_eq!(
            fingerprint_public_key_line(bare).unwrap().fingerprint,
            ED25519_FP
        );
    }

    #[test]
    fn rejects_garbage() {
        for line in ["", "ssh-ed25519", "ssh-ed25519 !!!", "just words here"] {
            assert!(fingerprint_public_key_line(line).is_err(), "{line:?}");
        }
    }

    #[test]
    fn errors_read_like_the_js_ones() {
        assert_eq!(
            fingerprint_public_key_line("just words\n")
                .unwrap_err()
                .message(),
            "not an SSH public key line: \"just words\\n\""
        );
        assert_eq!(
            fingerprint_public_key_line("ssh-ed25519 !!!")
                .unwrap_err()
                .message(),
            "SSH public key line has no base64 key blob"
        );
    }

    // readHostKeyFingerprint
    #[test]
    fn prefers_ed25519_over_other_host_keys() {
        let temp = TempDir::new("hostkey");
        let dir = temp.path();
        fs::write(dir.join("ssh_host_rsa_key.pub"), format!("{ED25519_PUB}\n")).unwrap();
        fs::write(
            dir.join("ssh_host_ed25519_key.pub"),
            format!("{ED25519_PUB}\n"),
        )
        .unwrap();
        let found = read_host_key_fingerprint(dir).unwrap().unwrap();
        assert_eq!(found.fingerprint, ED25519_FP);
        assert_eq!(found.path, dir.join("ssh_host_ed25519_key.pub"));
    }

    #[test]
    fn falls_back_to_the_next_key_type_when_ed25519_is_missing() {
        let temp = TempDir::new("hostkey");
        let dir = temp.path();
        fs::write(dir.join("ssh_host_rsa_key.pub"), format!("{ED25519_PUB}\n")).unwrap();
        let found = read_host_key_fingerprint(dir).unwrap().unwrap();
        assert_eq!(found.fingerprint, ED25519_FP);
        assert_eq!(found.path, dir.join("ssh_host_rsa_key.pub"));
    }

    #[test]
    fn is_none_when_no_host_key_exists() {
        let temp = TempDir::new("hostkey");
        let dir = temp.path();
        assert_eq!(read_host_key_fingerprint(dir).unwrap(), None);
    }
}
