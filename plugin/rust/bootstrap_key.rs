//! Bootstrap Key material (bootstrap-key.js, ADR 0007).
//!
//! A Bootstrap Key is an ephemeral Ed25519 keypair: its raw 32-byte seed rides
//! inside the Pairing Code, its public half becomes a restricted
//! authorized_keys line. Only the seed and the public line ever leave this
//! module.

use ring::rand::{SecureRandom, SystemRandom};
use ring::signature::{Ed25519KeyPair, KeyPair};

use crate::base64;
use crate::error::{CliError, Result};

pub const SEED_BYTES: usize = 32;
const KEY_TYPE: &str = "ssh-ed25519";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BootstrapKey {
    pub seed: [u8; SEED_BYTES],
    pub public_line: String,
}

/// The OpenSSH public line (`ssh-ed25519 <blob>`) of a raw Ed25519 seed;
/// what `ssh-keygen -y` prints for the same key.
pub fn public_line_from_seed(seed: &[u8]) -> Result<String> {
    if seed.len() != SEED_BYTES {
        return Err(CliError::failure(format!(
            "Bootstrap Key seed must be {SEED_BYTES} bytes"
        )));
    }
    let pair = Ed25519KeyPair::from_seed_unchecked(seed)
        .map_err(|_| CliError::failure("Bootstrap Key seed was rejected"))?;
    Ok(public_line(pair.public_key().as_ref()))
}

fn public_line(raw_public_key: &[u8]) -> String {
    let mut blob = Vec::with_capacity(4 + KEY_TYPE.len() + 4 + raw_public_key.len());
    for part in [KEY_TYPE.as_bytes(), raw_public_key] {
        blob.extend_from_slice(&(part.len() as u32).to_be_bytes());
        blob.extend_from_slice(part);
    }
    format!("{KEY_TYPE} {}", base64::encode_standard(&blob))
}

/// A fresh Bootstrap Key from the system random source.
pub fn generate_bootstrap_key() -> Result<BootstrapKey> {
    let mut seed = [0u8; SEED_BYTES];
    SystemRandom::new()
        .fill(&mut seed)
        .map_err(|_| CliError::failure("cannot read system randomness"))?;
    let public_line = public_line_from_seed(&seed)?;
    Ok(BootstrapKey { seed, public_line })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::host_key::fingerprint_public_key_line;

    // Key generated with `ssh-keygen -t ed25519`; the seed was extracted from
    // the openssh-key-v1 private file, so the expected line is independent of
    // the implementation under test.
    const VECTOR_SEED: &str = "1n6mUQHut1FJ4pJcfRp09db_30WxtZPx7lGUIYAl0Hk";
    const VECTOR_PUBLIC_LINE: &str =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMYSCTemrZWEXptQyehHLI9kbqjHxNUGtQN2lF1ucCce";
    const VECTOR_FINGERPRINT: &str = "SHA256:ef+f9Jda6ZPkcW5GiL7pQZXJ57mCFnFAGkir3AcfTIM";

    #[test]
    fn matches_what_ssh_keygen_derives_from_the_same_seed() {
        let seed = base64::decode(VECTOR_SEED);
        assert_eq!(public_line_from_seed(&seed).unwrap(), VECTOR_PUBLIC_LINE);
    }

    #[test]
    fn fingerprints_like_ssh_keygen_lf() {
        let line = public_line_from_seed(&base64::decode(VECTOR_SEED)).unwrap();
        assert_eq!(
            fingerprint_public_key_line(&line).unwrap().fingerprint,
            VECTOR_FINGERPRINT
        );
    }

    #[test]
    fn rejects_a_seed_that_is_not_32_bytes() {
        for length in [31, 33] {
            assert_eq!(
                public_line_from_seed(&vec![0; length])
                    .unwrap_err()
                    .message(),
                "Bootstrap Key seed must be 32 bytes"
            );
        }
    }

    #[test]
    fn generates_a_seed_that_re_derives_the_same_public_line() {
        let key = generate_bootstrap_key().unwrap();
        assert_eq!(key.seed.len(), 32);
        assert_eq!(public_line_from_seed(&key.seed).unwrap(), key.public_line);
    }

    #[test]
    fn generates_a_distinct_key_each_time() {
        assert_ne!(
            generate_bootstrap_key().unwrap().public_line,
            generate_bootstrap_key().unwrap().public_line
        );
    }
}
