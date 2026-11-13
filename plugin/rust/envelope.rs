//! Pairing Code v1 envelope (envelope.js, ADR 0007).
//!
//! Wire format: `HERDR-PAIR:<version>:<base64url(JSON, no padding)>`. The JSON
//! payload uses short wire keys; `test-vectors/pairing-code-v1.json` holds the
//! cross-implementation vectors. Unknown payload fields are ignored (additive
//! metadata); breaking changes bump the version, which both implementations
//! must honor.

use std::fmt;

use serde_json::{Map, Value, json};

use crate::base64;
use crate::js_compat;
use crate::jsx;

pub const PAIRING_CODE_PREFIX: &str = "HERDR-PAIR";
pub const PAIRING_CODE_VERSION: u32 = 1;

const BOOTSTRAP_SEED_BYTES: usize = 32;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PairingCodeErrorCode {
    BadPrefix,
    UnsupportedVersion,
    BadEncoding,
    BadPayload,
}

impl PairingCodeErrorCode {
    /// The step-taxonomy name the vectors use (`bad_prefix`, ...).
    pub fn as_str(self) -> &'static str {
        match self {
            Self::BadPrefix => "bad_prefix",
            Self::UnsupportedVersion => "unsupported_version",
            Self::BadEncoding => "bad_encoding",
            Self::BadPayload => "bad_payload",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairingCodeError {
    pub code: PairingCodeErrorCode,
    pub message: String,
}

impl fmt::Display for PairingCodeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for PairingCodeError {}

fn fail<T>(code: PairingCodeErrorCode, message: impl Into<String>) -> Result<T, PairingCodeError> {
    Err(PairingCodeError {
        code,
        message: message.into(),
    })
}

fn bad_payload<T>(message: impl Into<String>) -> Result<T, PairingCodeError> {
    fail(PairingCodeErrorCode::BadPayload, message)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairingPayload {
    /// Candidate addresses in try-order.
    pub addresses: Vec<String>,
    pub port: u32,
    pub username: String,
    /// OpenSSH `SHA256:` host key fingerprint.
    pub host_key_fingerprint: String,
    /// The Bootstrap Key's raw Ed25519 seed; set together with `expires_at`.
    pub bootstrap_seed: Option<Vec<u8>>,
    /// Unix-seconds expiry of the Bootstrap Key.
    pub expires_at: Option<i64>,
}

/// The payload as found, before it is known to be well formed: a field the
/// sender left out is `None` (JavaScript's `undefined`).
struct Fields<'a> {
    addresses: Option<&'a Value>,
    port: Option<&'a Value>,
    username: Option<&'a Value>,
    fingerprint: Option<&'a Value>,
    /// The Bootstrap Key seed's length, when there is one.
    seed_len: Option<usize>,
    expires_at: Option<&'a Value>,
}

fn has_space(text: &str) -> bool {
    text.chars().any(jsx::is_js_space)
}

/// `/^SHA256:[A-Za-z0-9+/]{43}$/`: an OpenSSH fingerprint, `SHA256:` and the
/// unpadded standard base64 of a 32-byte digest.
fn is_fingerprint(text: &str) -> bool {
    text.strip_prefix("SHA256:").is_some_and(|digest| {
        digest.len() == 43
            && digest
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'+' || b == b'/')
    })
}

/// Validate the payload shape shared by encode and decode, in the JS order.
fn validate(fields: &Fields) -> Result<(), PairingCodeError> {
    let Some(addresses) = fields
        .addresses
        .and_then(Value::as_array)
        .filter(|list| !list.is_empty())
    else {
        return bad_payload("addresses must be a non-empty array");
    };
    for address in addresses {
        if !address
            .as_str()
            .is_some_and(|text| !text.is_empty() && !has_space(text))
        {
            return bad_payload(format!("invalid address: {}", jsx::stringify(address)));
        }
    }
    let port_ok = fields
        .port
        .and_then(|port| js_compat::js_integer(Some(port)))
        .is_some_and(|port| (1.0..=65535.0).contains(&port));
    if !port_ok {
        return bad_payload(format!(
            "port must be an integer in 1..65535, got {}",
            js_compat::js_to_string(fields.port)
        ));
    }
    if !fields
        .username
        .and_then(Value::as_str)
        .is_some_and(|text| !text.is_empty() && !has_space(text))
    {
        return bad_payload("username must be a non-empty string without whitespace");
    }
    if !fields
        .fingerprint
        .and_then(Value::as_str)
        .is_some_and(is_fingerprint)
    {
        return bad_payload("hostKeyFingerprint must be an OpenSSH SHA256 fingerprint");
    }
    if fields.seed_len.is_some() != fields.expires_at.is_some() {
        return bad_payload("bootstrapSeed and expiresAt must be present together");
    }
    if fields
        .seed_len
        .is_some_and(|len| len != BOOTSTRAP_SEED_BYTES)
    {
        return bad_payload(format!(
            "bootstrapSeed must be {BOOTSTRAP_SEED_BYTES} bytes"
        ));
    }
    if fields
        .expires_at
        .is_some_and(|exp| js_compat::js_integer(Some(exp)).is_none_or(|exp| exp <= 0.0))
    {
        return bad_payload("expiresAt must be a positive unix-seconds integer");
    }
    Ok(())
}

fn as_number(value: &Value) -> f64 {
    value.as_f64().unwrap_or(f64::NAN)
}

/// Encode a payload into its canonical v1 string.
///
/// Key order is fixed so the same payload always yields the same code; the
/// shared vectors assert on the exact string.
pub fn encode_pairing_code(payload: &PairingPayload) -> Result<String, PairingCodeError> {
    let addresses = Value::Array(
        payload
            .addresses
            .iter()
            .cloned()
            .map(Value::String)
            .collect(),
    );
    let port = json!(payload.port);
    let username = Value::String(payload.username.clone());
    let fingerprint = Value::String(payload.host_key_fingerprint.clone());
    let expires_at = payload.expires_at.map(|exp| json!(exp));
    validate(&Fields {
        addresses: Some(&addresses),
        port: Some(&port),
        username: Some(&username),
        fingerprint: Some(&fingerprint),
        seed_len: payload.bootstrap_seed.as_ref().map(Vec::len),
        expires_at: expires_at.as_ref(),
    })?;

    let mut wire = Map::new();
    wire.insert("addrs".into(), addresses);
    wire.insert("port".into(), port);
    wire.insert("user".into(), username);
    wire.insert("fp".into(), fingerprint);
    if let Some(seed) = &payload.bootstrap_seed {
        wire.insert("seed".into(), Value::String(base64::encode_url(seed)));
    }
    if let Some(expires_at) = expires_at {
        wire.insert("exp".into(), expires_at);
    }
    let body = base64::encode_url(jsx::stringify(&Value::Object(wire)).as_bytes());
    Ok(format!(
        "{PAIRING_CODE_PREFIX}:{PAIRING_CODE_VERSION}:{body}"
    ))
}

fn decode_base64_url_strict(
    text: &str,
    what: &str,
    code: PairingCodeErrorCode,
) -> Result<Vec<u8>, PairingCodeError> {
    if !base64::is_url_text(text) || text.len() % 4 == 1 {
        return fail(code, format!("{what} is not unpadded base64url"));
    }
    Ok(base64::decode(text))
}

/// Decode and validate a scanned Pairing Code string.
///
/// The error's code says which step failed: `bad_prefix`,
/// `unsupported_version`, `bad_encoding` or `bad_payload`.
pub fn decode_pairing_code(code: &str) -> Result<PairingPayload, PairingCodeError> {
    let Some(rest) = code
        .strip_prefix(PAIRING_CODE_PREFIX)
        .and_then(|rest| rest.strip_prefix(':'))
    else {
        return fail(
            PairingCodeErrorCode::BadPrefix,
            format!("expected \"{PAIRING_CODE_PREFIX}:<version>:<payload>\""),
        );
    };
    let Some((version, body)) = rest.split_once(':') else {
        return fail(PairingCodeErrorCode::BadPrefix, "missing version separator");
    };
    if version != PAIRING_CODE_VERSION.to_string() {
        return fail(
            PairingCodeErrorCode::UnsupportedVersion,
            format!("unsupported Pairing Code version \"{version}\""),
        );
    }

    let body = decode_base64_url_strict(body, "payload", PairingCodeErrorCode::BadEncoding)?;
    let Ok(wire) = serde_json::from_str::<Value>(&String::from_utf8_lossy(&body)) else {
        return fail(
            PairingCodeErrorCode::BadEncoding,
            "payload is not valid JSON",
        );
    };
    let Value::Object(wire) = wire else {
        return bad_payload("payload must be a JSON object");
    };

    let seed = match wire.get("seed") {
        None => None,
        Some(Value::String(text)) => Some(decode_base64_url_strict(
            text,
            "seed",
            PairingCodeErrorCode::BadPayload,
        )?),
        Some(_) => return bad_payload("seed must be a base64url string"),
    };
    let fields = Fields {
        addresses: wire.get("addrs"),
        port: wire.get("port"),
        username: wire.get("user"),
        fingerprint: wire.get("fp"),
        seed_len: seed.as_ref().map(Vec::len),
        expires_at: wire.get("exp"),
    };
    validate(&fields)?;

    // Validation ran: the fields are the types and ranges taken here. A
    // timestamp past i64 is cut to its maximum; no clock reaches it.
    let text = |value: Option<&Value>| {
        value
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string()
    };
    Ok(PairingPayload {
        addresses: fields
            .addresses
            .and_then(Value::as_array)
            .map(|list| list.iter().map(|a| text(Some(a))).collect())
            .unwrap_or_default(),
        port: fields.port.map_or(0, |port| as_number(port) as u32),
        username: text(fields.username),
        host_key_fingerprint: text(fields.fingerprint),
        bootstrap_seed: seed,
        expires_at: fields.expires_at.map(|exp| as_number(exp) as i64),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    static VECTORS: &str = include_str!("../test-vectors/pairing-code-v1.json");

    fn vectors() -> Value {
        serde_json::from_str(VECTORS).unwrap()
    }

    /// A decoded payload in the vector shape (seed as base64url).
    fn to_vector_shape(payload: &PairingPayload) -> Value {
        let mut shape = json!({
            "addresses": payload.addresses,
            "port": payload.port,
            "username": payload.username,
            "hostKeyFingerprint": payload.host_key_fingerprint,
        });
        if let Some(seed) = &payload.bootstrap_seed {
            shape["bootstrapSeed"] = json!(base64::encode_url(seed));
        }
        if let Some(expires_at) = payload.expires_at {
            shape["expiresAt"] = json!(expires_at);
        }
        shape
    }

    /// A vector payload (seed as base64url) as the encode input.
    fn from_vector_shape(payload: &Value) -> PairingPayload {
        PairingPayload {
            addresses: payload["addresses"]
                .as_array()
                .unwrap()
                .iter()
                .map(|a| a.as_str().unwrap().to_string())
                .collect(),
            port: payload["port"].as_u64().unwrap() as u32,
            username: payload["username"].as_str().unwrap().to_string(),
            host_key_fingerprint: payload["hostKeyFingerprint"].as_str().unwrap().to_string(),
            bootstrap_seed: payload
                .get("bootstrapSeed")
                .map(|seed| base64::decode(seed.as_str().unwrap())),
            expires_at: payload.get("expiresAt").map(|e| e.as_i64().unwrap()),
        }
    }

    fn base() -> PairingPayload {
        PairingPayload {
            addresses: vec!["192.168.1.42".into()],
            port: 22,
            username: "ada".into(),
            host_key_fingerprint: "SHA256:6+jncNdibsG2cqvfoLApGrO8CvIwAEMzsB+IilOs8tg".into(),
            bootstrap_seed: None,
            expires_at: None,
        }
    }

    // shared vectors
    #[test]
    fn vector_file_has_cases() {
        let vectors = vectors();
        assert!(vectors["valid"].as_array().unwrap().len() >= 3);
        assert!(vectors["invalid"].as_array().unwrap().len() >= 10);
    }

    #[test]
    fn decodes_every_valid_vector() {
        for vector in vectors()["valid"].as_array().unwrap() {
            let decoded = decode_pairing_code(vector["code"].as_str().unwrap()).unwrap();
            assert_eq!(
                to_vector_shape(&decoded),
                vector["payload"],
                "{}",
                vector["name"]
            );
        }
    }

    #[test]
    fn encodes_every_valid_vector_canonically() {
        for vector in vectors()["valid"].as_array().unwrap() {
            if vector.get("decodeOnly") == Some(&json!(true)) {
                continue;
            }
            assert_eq!(
                encode_pairing_code(&from_vector_shape(&vector["payload"])).unwrap(),
                vector["code"].as_str().unwrap(),
                "{}",
                vector["name"]
            );
        }
    }

    #[test]
    fn rejects_every_invalid_vector_with_its_code() {
        for vector in vectors()["invalid"].as_array().unwrap() {
            let error = decode_pairing_code(vector["code"].as_str().unwrap()).unwrap_err();
            assert_eq!(
                error.code.as_str(),
                vector["error"].as_str().unwrap(),
                "{}",
                vector["name"]
            );
        }
    }

    // encodePairingCode
    #[test]
    fn round_trips_through_decode() {
        let decoded = decode_pairing_code(&encode_pairing_code(&base()).unwrap()).unwrap();
        assert_eq!(decoded, base());
    }

    #[test]
    fn rejects_invalid_payloads_before_encoding() {
        let bads = [
            PairingPayload {
                addresses: vec![],
                ..base()
            },
            PairingPayload { port: 0, ..base() },
            PairingPayload {
                port: 65536,
                ..base()
            },
            PairingPayload {
                username: String::new(),
                ..base()
            },
            PairingPayload {
                host_key_fingerprint: "MD5:abc".into(),
                ..base()
            },
            PairingPayload {
                bootstrap_seed: Some(vec![0; 31]),
                expires_at: Some(1753305600),
                ..base()
            },
            PairingPayload {
                bootstrap_seed: Some(vec![0; 32]),
                ..base()
            },
            PairingPayload {
                expires_at: Some(1753305600),
                ..base()
            },
            PairingPayload {
                bootstrap_seed: Some(vec![0; 32]),
                expires_at: Some(0),
                ..base()
            },
        ];
        for bad in bads {
            let error = encode_pairing_code(&bad).unwrap_err();
            assert_eq!(error.code, PairingCodeErrorCode::BadPayload, "{bad:?}");
        }
    }

    #[test]
    fn round_trips_a_bootstrap_seed_as_raw_bytes() {
        let seed: Vec<u8> = (0..32).map(|i| 255 - i as u8).collect();
        let payload = PairingPayload {
            bootstrap_seed: Some(seed.clone()),
            expires_at: Some(1753305600),
            ..base()
        };
        let decoded = decode_pairing_code(&encode_pairing_code(&payload).unwrap()).unwrap();
        assert_eq!(decoded.bootstrap_seed, Some(seed));
        assert_eq!(decoded.expires_at, Some(1753305600));
    }

    #[test]
    fn error_messages_follow_the_js_ones() {
        let message = |code: &str| decode_pairing_code(code).unwrap_err().message;
        assert_eq!(message("x"), "expected \"HERDR-PAIR:<version>:<payload>\"");
        assert_eq!(message("HERDR-PAIR:1"), "missing version separator");
        assert_eq!(
            message("HERDR-PAIR:2:e30"),
            "unsupported Pairing Code version \"2\""
        );
        assert_eq!(
            message("HERDR-PAIR:1:!"),
            "payload is not unpadded base64url"
        );
        assert_eq!(message("HERDR-PAIR:1:YQ"), "payload is not valid JSON");
        assert_eq!(message("HERDR-PAIR:1:W10"), "payload must be a JSON object");
        let with = |wire: Value| {
            let code = format!(
                "HERDR-PAIR:1:{}",
                base64::encode_url(wire.to_string().as_bytes())
            );
            decode_pairing_code(&code).unwrap_err().message
        };
        let fp = "SHA256:6+jncNdibsG2cqvfoLApGrO8CvIwAEMzsB+IilOs8tg";
        let ok = json!({"addrs": ["a"], "port": 22, "user": "u", "fp": fp});
        let patch = |key: &str, value: Value| {
            let mut wire = ok.clone();
            wire[key] = value;
            wire
        };
        assert_eq!(
            with(patch("seed", json!(5))),
            "seed must be a base64url string"
        );
        assert_eq!(
            with(patch("seed", json!("A"))),
            "seed is not unpadded base64url"
        );
        assert_eq!(
            with(patch("port", json!(22.5))),
            "port must be an integer in 1..65535, got 22.5"
        );
        assert_eq!(
            with(patch("port", json!("x"))),
            "port must be an integer in 1..65535, got x"
        );
        assert_eq!(
            with(json!({"port": 22})),
            "addresses must be a non-empty array"
        );
        assert_eq!(
            with(patch("addrs", json!(["a b"]))),
            "invalid address: \"a b\""
        );
        assert_eq!(
            with(patch("addrs", json!([null, 1.0]))),
            "invalid address: null"
        );
        assert_eq!(
            with(patch("user", json!("a b"))),
            "username must be a non-empty string without whitespace"
        );
        assert_eq!(
            with(patch("fp", json!("MD5:abc"))),
            "hostKeyFingerprint must be an OpenSSH SHA256 fingerprint"
        );
        assert_eq!(
            with(patch("exp", json!(5))),
            "bootstrapSeed and expiresAt must be present together"
        );
        assert_eq!(
            with(patch("exp", json!(null))),
            "bootstrapSeed and expiresAt must be present together"
        );
    }

    #[test]
    fn a_whole_number_written_with_a_fraction_is_an_integer() {
        let wire = json!({"addrs": ["a"], "port": 22.0, "user": "u",
            "fp": "SHA256:6+jncNdibsG2cqvfoLApGrO8CvIwAEMzsB+IilOs8tg"});
        let code = format!(
            "HERDR-PAIR:1:{}",
            base64::encode_url(wire.to_string().as_bytes())
        );
        assert_eq!(decode_pairing_code(&code).unwrap().port, 22);
    }
}
