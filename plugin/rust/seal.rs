//! Shared AES-256-GCM envelope sealer (seal-envelope.js), the framing both
//! the notification envelope (`HERDR-NOTIFY:1`) and the Live Activity
//! envelope (`HERDR-ACTIVITY:1`) use: `{"v":1,"kid":...,"n":...,"ct":...}`
//! with the same key-id derivation. Domain separation is the AAD the caller
//! passes.
//!
//! * [`seal`] and [`open`] are byte-compatible with the app's
//!   `SealedEnvelopeCodec` (Sources/WaycarNotificationCore). The shared
//!   vectors in `plugin/test-vectors` prove both directions: they were made
//!   with raw AES-GCM calls, `seal` reproduces them byte for byte and `open`
//!   opens every one of them, and the Swift suites do the same.
//! * The JavaScript semantics the envelopes depend on (`trim`, number
//!   formatting, `JSON.stringify` bytes, UTF-16 lengths) live in `js_compat`.

use std::fmt;

use ring::aead::{AES_256_GCM, Aad, LessSafeKey, Nonce, UnboundKey};
use ring::digest::{SHA256, digest};
use ring::rand::{SecureRandom, SystemRandom};
use serde_json::Value;

use crate::base64;
use crate::js_compat::{js_integer, js_to_string};

pub const ENVELOPE_VERSION: u32 = 1;
pub const KEY_BYTES: usize = 32;
pub const NONCE_BYTES: usize = 12;
pub const TAG_BYTES: usize = 16;
const KEY_ID_BYTES: usize = 8;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ErrorCode {
    /// JS `TypeError`: a key or nonce of the wrong size, or a value the JS
    /// would have thrown on while reading it.
    Type,
    BadEnvelope,
    UnsupportedVersion,
    DecryptFailed,
    BadPayload,
}

impl ErrorCode {
    /// The wire code the app and the JS errors use (`error.code`); `type_error`
    /// has no JS code (it is a `TypeError`).
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Type => "type_error",
            Self::BadEnvelope => "bad_envelope",
            Self::UnsupportedVersion => "unsupported_version",
            Self::DecryptFailed => "decrypt_failed",
            Self::BadPayload => "bad_payload",
        }
    }
}

/// What `NotificationEnvelopeError`, `ActivityEnvelopeError` and the
/// `TypeError`s of the JS envelope modules become.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EnvelopeError {
    pub code: ErrorCode,
    pub message: String,
}

impl EnvelopeError {
    pub fn new(code: ErrorCode, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }

    pub fn type_error(message: impl Into<String>) -> Self {
        Self::new(ErrorCode::Type, message)
    }
}

impl fmt::Display for EnvelopeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for EnvelopeError {}

fn sha256(data: &[u8]) -> ring::digest::Digest {
    digest(&SHA256, data)
}

/// The cleartext key id for a raw 32-byte Notification Key: the first 8
/// bytes of SHA-256 over the key, unpadded base64url. Both ends derive it,
/// so it never needs to be stored or exchanged separately.
pub fn derive_key_id(key: &[u8]) -> Result<String, EnvelopeError> {
    if key.len() != KEY_BYTES {
        return Err(EnvelopeError::type_error(format!(
            "Notification Key must be a {KEY_BYTES}-byte Buffer"
        )));
    }
    Ok(base64::encode_url(&sha256(key).as_ref()[..KEY_ID_BYTES]))
}

fn aes_key(key: &[u8]) -> LessSafeKey {
    // The caller has checked the length, the only way this can fail.
    LessSafeKey::new(UnboundKey::new(&AES_256_GCM, key).expect("32-byte AES-256 key"))
}

/// Seal a UTF-8 plaintext under AES-256-GCM and return the canonical
/// envelope JSON string `{"v":1,"kid":...,"n":...,"ct":...}`.
///
/// `nonce` is the injectable 12-byte nonce (tests only): production passes
/// `None` and gets a fresh random one, as the JS default does.
pub fn seal(
    plaintext: &str,
    key: &[u8],
    aad: &[u8],
    nonce: Option<&[u8]>,
) -> Result<String, EnvelopeError> {
    let key_id = derive_key_id(key)?;
    let mut random = [0u8; NONCE_BYTES];
    let nonce_bytes = match nonce {
        Some(nonce) if nonce.len() == NONCE_BYTES => nonce,
        Some(_) => {
            return Err(EnvelopeError::type_error(format!(
                "nonce must be a {NONCE_BYTES}-byte Buffer"
            )));
        }
        None => {
            SystemRandom::new()
                .fill(&mut random)
                .map_err(|_| EnvelopeError::type_error("no random bytes for a nonce"))?;
            &random
        }
    };
    let mut sealed = Vec::with_capacity(plaintext.len() + TAG_BYTES);
    sealed.extend_from_slice(plaintext.as_bytes());
    aes_key(key)
        .seal_in_place_append_tag(
            Nonce::try_assume_unique_for_key(nonce_bytes).expect("12-byte nonce"),
            Aad::from(aad),
            &mut sealed,
        )
        .map_err(|_| EnvelopeError::type_error("AES-GCM sealing failed"))?;
    Ok(format!(
        "{{\"v\":{ENVELOPE_VERSION},\"kid\":\"{key_id}\",\"n\":\"{}\",\"ct\":\"{}\"}}",
        base64::encode_url(nonce_bytes),
        base64::encode_url(&sealed)
    ))
}

fn decode_field(value: Option<&Value>, what: &str) -> Result<Vec<u8>, EnvelopeError> {
    value
        .and_then(Value::as_str)
        .filter(|text| !text.is_empty())
        .and_then(base64::decode_url_strict)
        .ok_or_else(|| {
            EnvelopeError::new(
                ErrorCode::BadEnvelope,
                format!("{what} is not unpadded base64url"),
            )
        })
}

/// Parse and open an envelope under `aad` and return the plaintext bytes.
/// The checks and their order are the activity decryptor's (the only JS
/// opener); `domain` names the envelope in the unsupported-version message
/// (`"activity"`: `unsupported activity envelope version 2`).
///
/// Errors: `Type` (key not 32 bytes), `BadEnvelope`, `UnsupportedVersion`,
/// `DecryptFailed` (wrong key, AAD or nonce, tampered bytes).
pub fn open(
    envelope: &str,
    key: &[u8],
    aad: &[u8],
    domain: &str,
) -> Result<Vec<u8>, EnvelopeError> {
    derive_key_id(key)?;
    let bad = |message: &str| EnvelopeError::new(ErrorCode::BadEnvelope, message);
    let wire: Value = serde_json::from_str(envelope).map_err(|_| bad("envelope is not JSON"))?;
    let Value::Object(wire) = wire else {
        return Err(bad("envelope must be a JSON object"));
    };
    let version = wire
        .get("v")
        .filter(|v| js_integer(Some(v)).is_some())
        .ok_or_else(|| bad("envelope version must be an integer"))?;
    if version.as_f64() != Some(f64::from(ENVELOPE_VERSION)) {
        return Err(EnvelopeError::new(
            ErrorCode::UnsupportedVersion,
            format!(
                "unsupported {domain} envelope version {}",
                js_to_string(Some(version))
            ),
        ));
    }
    if wire
        .get("kid")
        .and_then(Value::as_str)
        .is_none_or(str::is_empty)
    {
        return Err(bad("kid missing"));
    }
    let nonce = decode_field(wire.get("n"), "nonce")?;
    let mut sealed = decode_field(wire.get("ct"), "ciphertext")?;
    if nonce.len() != NONCE_BYTES {
        return Err(bad(&format!("nonce must be {NONCE_BYTES} bytes")));
    }
    if sealed.len() < TAG_BYTES {
        return Err(bad("ciphertext shorter than the GCM tag"));
    }
    let failed = || {
        EnvelopeError::new(
            ErrorCode::DecryptFailed,
            format!("{domain} envelope failed authentication"),
        )
    };
    let plaintext_len = aes_key(key)
        .open_in_place(
            Nonce::try_assume_unique_for_key(&nonce).expect("12-byte nonce"),
            Aad::from(aad),
            &mut sealed,
        )
        .map_err(|_| failed())?
        .len();
    sealed.truncate(plaintext_len);
    Ok(sealed)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn counting_key() -> Vec<u8> {
        (0..32).collect()
    }

    #[test]
    fn seal_then_open_round_trips() {
        let key = counting_key();
        let nonce = [7u8; 12];
        let envelope = seal("héllo", &key, b"AAD", Some(&nonce)).unwrap();
        assert_eq!(
            open(&envelope, &key, b"AAD", "test").unwrap(),
            "héllo".as_bytes()
        );
        let error = open(&envelope, &key, b"OTHER", "test").unwrap_err();
        assert_eq!(error.code, ErrorCode::DecryptFailed);
        assert_eq!(error.message, "test envelope failed authentication");
    }

    #[test]
    fn seal_empty_plaintext_is_the_bare_tag() {
        let key = counting_key();
        let envelope = seal("", &key, b"AAD", Some(&[0u8; 12])).unwrap();
        let wire: Value = serde_json::from_str(&envelope).unwrap();
        assert_eq!(wire["ct"].as_str().unwrap().len(), base64::url_len(16));
        assert_eq!(open(&envelope, &key, b"AAD", "test").unwrap(), b"");
    }

    #[test]
    fn seal_rejects_bad_key_and_nonce_sizes() {
        let error = seal("x", &[0u8; 16], b"", None).unwrap_err();
        assert_eq!(error.code, ErrorCode::Type);
        assert_eq!(error.message, "Notification Key must be a 32-byte Buffer");
        let error = seal("x", &counting_key(), b"", Some(&[0u8; 8])).unwrap_err();
        assert_eq!(error.message, "nonce must be a 12-byte Buffer");
    }

    #[test]
    fn open_reports_each_framing_failure() {
        let key = counting_key();
        let good = seal("x", &key, b"A", Some(&[1u8; 12])).unwrap();
        let wire: Value = serde_json::from_str(&good).unwrap();
        let with = |field: &str, value: Value| {
            let mut copy = wire.clone();
            copy[field] = value;
            copy.to_string()
        };
        let code = |envelope: &str| open(envelope, &key, b"A", "test").unwrap_err();
        assert_eq!(code("nope").message, "envelope is not JSON");
        assert_eq!(code("[1]").message, "envelope must be a JSON object");
        assert_eq!(
            code(&with("v", json!("1"))).message,
            "envelope version must be an integer"
        );
        assert_eq!(
            code(&with("v", json!(2))).code,
            ErrorCode::UnsupportedVersion
        );
        assert_eq!(
            code(&with("v", json!(2))).message,
            "unsupported test envelope version 2"
        );
        assert_eq!(code(&with("kid", json!(""))).message, "kid missing");
        assert_eq!(
            code(&with("n", json!("!!"))).message,
            "nonce is not unpadded base64url"
        );
        assert_eq!(
            code(&with("n", json!("AAAA"))).message,
            "nonce must be 12 bytes"
        );
        assert_eq!(
            code(&with("ct", json!("AAAA"))).message,
            "ciphertext shorter than the GCM tag"
        );
        assert_eq!(
            open(&good, &[0u8; 5], b"A", "test").unwrap_err().code,
            ErrorCode::Type
        );
    }
}
