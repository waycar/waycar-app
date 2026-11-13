//! Notification envelope v1 (notification-envelope.js, ADR 0008).
//!
//! The encrypted Agent Notification payload carried from the notify hook
//! through the Push Relay and APNs to the app's service extension. Wire
//! format: a compact JSON object `{"v":1,"kid":...,"n":...,"ct":...}` whose
//! `ct` is the AES-256-GCM ciphertext (plus tag) of a compact JSON plaintext
//! `{"pane":...,"kind":...,"status":...,"ts":...}` plus the optional display
//! fields `project`, `title`, `summary`, `reply` (a Chat Mode Agent's final
//! reply) and the optional badge count `attention`. The vectors in
//! `test-vectors/notification-payload-v1.json` are the cross-implementation
//! contract; they must pass unchanged. Breaking changes bump the version,
//! which both implementations must honor together.
//!
//! JS strings versus Rust `&str`:
//!
//! * Lengths the JS limits count UTF-16 code units ([`DISPLAY_FIELD_MAX`]);
//!   so does this port ([`utf16_len`]), so `"😀".repeat(200)` is 400 units in
//!   both.
//! * `normalizeReply` replaces lone UTF-16 surrogates with U+FFFD. A Rust
//!   `&str` is valid UTF-8 and cannot hold one, so that step has nothing to
//!   do here: text decoded from tmux output or JSON already carries U+FFFD
//!   (lossy UTF-8 decoding) or never reaches this code (serde_json rejects a
//!   lone `\ud800` escape, where `JSON.parse` accepts it; a caller that must
//!   keep such a payload has to repair the escape before parsing).
//! * `Intl.Segmenter` graphemes are `unicode-segmentation`'s extended
//!   grapheme clusters (UAX #29). The parity cases cover emoji, ZWJ
//!   sequences, flags, skin tones, combining marks, Hangul and Indic scripts
//!   against Node's ICU.
//! * `trim` strips the ECMAScript whitespace set, not Rust's.

use serde_json::Value;
use unicode_segmentation::UnicodeSegmentation;

use crate::base64;
use crate::js_compat::{MAX_SAFE_INTEGER, js_integer, js_to_string, json_escaped_len};
use crate::jsx;
pub use crate::seal::{ENVELOPE_VERSION, KEY_BYTES, NONCE_BYTES};
use crate::seal::{EnvelopeError, ErrorCode, TAG_BYTES, derive_key_id, seal};

pub const NOTIFICATION_ENVELOPE_VERSION: u32 = ENVELOPE_VERSION;

/// Additional authenticated data binding the ciphertext to envelope v1, so a
/// re-framed ciphertext under a different version fails authentication.
pub const NOTIFICATION_AAD: &[u8] = b"HERDR-NOTIFY:1";

/// Hard ceiling, in UTF-16 units, for the display-only strings. The notify
/// hook trims to something shorter still; this is the contract's backstop
/// keeping an APNs payload well inside its 4 KB budget.
pub const DISPLAY_FIELD_MAX: usize = 256;

/// Byte budget for a Chat Mode reply, ellipsis included, measured as the
/// reply's JSON-escaped size inside the plaintext. Unlike the display fields
/// a reply is normalized and capped here rather than rejected.
pub const REPLY_MAX_BYTES: usize = 1000;
const ELLIPSIS: &str = "…";

/// Ceiling for the sealed envelope's base64url `ct`, the same budget the
/// activity hook uses: the relay wraps the envelope in an APNs body capped at
/// 4,096 bytes, and the fallback alert, the `aps` framing and the escaped
/// envelope framing need the rest.
pub const ENVELOPE_CT_BUDGET: usize = 2800;

/// The cleartext key id for a raw 32-byte Notification Key (`notificationKeyId`).
pub fn notification_key_id(key: &[u8]) -> Result<String, EnvelopeError> {
    derive_key_id(key)
}

/// Normalize a Chat Mode reply for the plaintext: CRLF to LF, C0 controls
/// other than `\n` and `\t` stripped (a lone CR with them), trimmed, and
/// capped at `max_bytes` of JSON-escaped UTF-8 on a grapheme boundary, with
/// `…` appended when cut. Line breaks are kept. Empty after trimming is
/// `None`. Callers pass [`REPLY_MAX_BYTES`] for the default cap.
pub fn normalize_reply(reply: &str, max_bytes: usize) -> Option<String> {
    // CRLF becomes LF and every other CR is dropped as a control: all CRs go.
    let stripped: String = reply
        .chars()
        .filter(|c| *c >= ' ' || matches!(c, '\t' | '\n'))
        .collect();
    let text = jsx::trim(&stripped);
    if text.is_empty() {
        return None;
    }
    if json_escaped_len(text) <= max_bytes {
        return Some(text.to_owned());
    }
    let budget = max_bytes as i64 - json_escaped_len(ELLIPSIS) as i64;
    let mut kept_end = 0;
    let mut bytes = 0i64;
    for (start, segment) in text.grapheme_indices(true) {
        let size = json_escaped_len(segment) as i64;
        if bytes + size > budget {
            break;
        }
        kept_end = start + segment.len();
        bytes += size;
    }
    let cut = jsx::trim_end(&text[..kept_end]);
    if cut.is_empty() {
        return None;
    }
    Some(format!("{cut}{ELLIPSIS}"))
}

/// The notification payload. `project`, `title` and `summary` are the
/// optional display fields: leave them `None` (or empty) and the app renders
/// one step less specific. `attention` is the optional badge count: `None`
/// leaves the app's badge alone, `Some(0)` is a real count.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct NotificationPayload<'a> {
    /// herdr pane id the Agent lives in.
    pub pane_id: &'a str,
    /// Agent kind as herdr reports it.
    pub agent_kind: &'a str,
    /// The new Agent Status (lenient open set).
    pub status: &'a str,
    /// Unix seconds of the status transition.
    pub timestamp: i64,
    /// Workspace label the Agent runs in.
    pub project: Option<&'a str>,
    /// Agent terminal title, glyphs stripped.
    pub title: Option<&'a str>,
    /// Agent Summary: what a Done Agent finished, or what a Blocked Agent is
    /// asking the user for.
    pub summary: Option<&'a str>,
    /// This Host's Blocked + Done agent count.
    pub attention: Option<u64>,
    /// A Chat Mode Agent's final reply, normalized and capped by
    /// [`normalize_reply`]; any length accepted.
    pub reply: Option<&'a str>,
}

fn bad_payload(message: impl Into<String>) -> EnvelopeError {
    EnvelopeError::new(ErrorCode::BadPayload, message)
}

// The per-field checks, shared by `validate` (typed fields) and `from_json`
// (which first checks the JSON type), so both report the first failure in
// the JS order: paneId, agentKind, status, timestamp, project, title,
// summary, attention, reply.

fn check_non_empty(field: &str, value: &str) -> Result<(), EnvelopeError> {
    if value.is_empty() {
        return Err(bad_payload(format!("{field} must be a non-empty string")));
    }
    Ok(())
}

/// A timestamp is a positive integer a JS number holds exactly (at most
/// 2^53 - 1: no unix time comes near it, and past it the JS and Rust decimal
/// digits would differ).
fn timestamp_ok(timestamp: i64) -> bool {
    timestamp > 0 && timestamp as u64 <= MAX_SAFE_INTEGER
}

fn timestamp_error(shown: &str) -> EnvelopeError {
    bad_payload(format!(
        "timestamp must be a positive unix-seconds integer, got {shown}"
    ))
}

fn check_display(field: &str, value: &str) -> Result<(), EnvelopeError> {
    if jsx::utf16_len(value) > DISPLAY_FIELD_MAX {
        return Err(bad_payload(format!(
            "{field} must be at most {DISPLAY_FIELD_MAX} characters"
        )));
    }
    Ok(())
}

fn attention_error(shown: &str) -> EnvelopeError {
    bad_payload(format!(
        "attention must be a non-negative integer when present, got {shown}"
    ))
}

impl<'a> NotificationPayload<'a> {
    /// Check the payload shape: non-empty ids and status, a positive
    /// timestamp, display fields of at most [`DISPLAY_FIELD_MAX`] UTF-16
    /// units, an attention count a JS number holds exactly.
    pub fn validate(&self) -> Result<(), EnvelopeError> {
        check_non_empty("paneId", self.pane_id)?;
        check_non_empty("agentKind", self.agent_kind)?;
        check_non_empty("status", self.status)?;
        if !timestamp_ok(self.timestamp) {
            return Err(timestamp_error(&self.timestamp.to_string()));
        }
        for (field, value) in [
            ("project", self.project),
            ("title", self.title),
            ("summary", self.summary),
        ] {
            if let Some(value) = value {
                check_display(field, value)?;
            }
        }
        if let Some(attention) = self.attention
            && attention > MAX_SAFE_INTEGER
        {
            return Err(attention_error(&attention.to_string()));
        }
        Ok(())
    }

    /// The payload of a JSON object (the shape the JS takes): the entry for
    /// callers whose fields are dynamically typed. A field of the wrong JSON
    /// type fails `bad_payload` with the JS message; `null` counts as absent
    /// for the optional fields. A `null` payload is the TypeError the JS
    /// destructuring throws.
    pub fn from_json(payload: &'a Value) -> Result<Self, EnvelopeError> {
        if payload.is_null() {
            return Err(EnvelopeError::type_error(
                "Cannot destructure property 'paneId' of 'payload' as it is null.",
            ));
        }
        let field = |name: &str| payload.get(name);
        let required = |name: &str| -> Result<&'a str, EnvelopeError> {
            match field(name) {
                Some(Value::String(text)) => {
                    check_non_empty(name, text)?;
                    Ok(text)
                }
                _ => Err(bad_payload(format!("{name} must be a non-empty string"))),
            }
        };
        let optional_text = |name: &str| -> Result<Option<&'a str>, EnvelopeError> {
            match field(name) {
                None | Some(Value::Null) => Ok(None),
                Some(Value::String(text)) => {
                    check_display(name, text)?;
                    Ok(Some(text))
                }
                Some(_) => Err(bad_payload(format!("{name} must be a string when present"))),
            }
        };
        let pane_id = required("paneId")?;
        let agent_kind = required("agentKind")?;
        let status = required("status")?;
        let timestamp = js_integer(field("timestamp"))
            .filter(|ts| *ts > 0.0 && *ts <= MAX_SAFE_INTEGER as f64)
            .ok_or_else(|| timestamp_error(&js_to_string(field("timestamp"))))?
            as i64;
        let project = optional_text("project")?;
        let title = optional_text("title")?;
        let summary = optional_text("summary")?;
        let attention = match field("attention") {
            None | Some(Value::Null) => None,
            value => Some(
                js_integer(value)
                    .filter(|n| *n >= 0.0 && *n <= MAX_SAFE_INTEGER as f64)
                    .ok_or_else(|| attention_error(&js_to_string(value)))? as u64,
            ),
        };
        let reply = match field("reply") {
            None | Some(Value::Null) => None,
            Some(Value::String(text)) => Some(text.as_str()),
            Some(_) => return Err(bad_payload("reply must be a string when present")),
        };
        Ok(Self {
            pane_id,
            agent_kind,
            status,
            timestamp,
            project,
            title,
            summary,
            attention,
            reply,
        })
    }

    /// The compact plaintext JSON. Empty display fields are omitted rather
    /// than sent blank, so the encoding stays canonical whichever way the
    /// Host failed to resolve them; an attention count of 0 is a real count
    /// and is sent. Key order is the notification contract's table order
    /// (not alphabetical), which the vectors pin.
    fn plaintext(&self, reply: Option<&str>) -> String {
        let mut out = String::with_capacity(
            128 + self.pane_id.len()
                + self.project.map_or(0, str::len)
                + self.title.map_or(0, str::len)
                + self.summary.map_or(0, str::len)
                + reply.map_or(0, str::len),
        );
        out.push_str("{\"pane\":");
        jsx::write_json_string(self.pane_id, &mut out);
        out.push_str(",\"kind\":");
        jsx::write_json_string(self.agent_kind, &mut out);
        out.push_str(",\"status\":");
        jsx::write_json_string(self.status, &mut out);
        out.push_str(",\"ts\":");
        out.push_str(&self.timestamp.to_string());
        for (name, value) in [
            ("project", self.project),
            ("title", self.title),
            ("summary", self.summary),
            ("reply", reply),
        ] {
            if let Some(value) = value.filter(|value| !value.is_empty()) {
                out.push_str(",\"");
                out.push_str(name);
                out.push_str("\":");
                jsx::write_json_string(value, &mut out);
            }
        }
        if let Some(attention) = self.attention {
            out.push_str(",\"attention\":");
            out.push_str(&attention.to_string());
        }
        out.push('}');
        out
    }
}

/// Encrypt a notification payload into its canonical v1 envelope string.
///
/// Key order in both JSON objects is fixed so the same inputs always yield
/// the same envelope; the shared vectors assert on the exact string.
///
/// A reply whose sealed `ct` would exceed [`ENVELOPE_CT_BUDGET`] is re-sealed
/// capped at half the reply budget, and then without the reply, so the push
/// always fits APNs.
///
/// `nonce` is the injectable 12-byte nonce (tests only): production passes
/// `None` and every seal draws a fresh random one.
///
/// Errors: `BadPayload` (see [`NotificationPayload::validate`]), `Type` for a
/// key that is not 32 bytes or a nonce that is not 12.
pub fn encrypt_notification_envelope(
    payload: &NotificationPayload<'_>,
    key: &[u8],
    nonce: Option<&[u8]>,
) -> Result<String, EnvelopeError> {
    payload.validate()?;
    let sealed_ct_fits =
        |plaintext: &str| base64::url_len(plaintext.len() + TAG_BYTES) <= ENVELOPE_CT_BUDGET;
    let seal = |plaintext: &str| seal(plaintext, key, NOTIFICATION_AAD, nonce);

    let reply = payload
        .reply
        .and_then(|reply| normalize_reply(reply, REPLY_MAX_BYTES));
    let plaintext = payload.plaintext(reply.as_deref());
    let envelope = seal(&plaintext)?;
    if reply.is_none() || sealed_ct_fits(&plaintext) {
        return Ok(envelope);
    }
    let halved = payload
        .reply
        .and_then(|reply| normalize_reply(reply, REPLY_MAX_BYTES / 2));
    if halved.is_some() {
        let shorter = payload.plaintext(halved.as_deref());
        if sealed_ct_fits(&shorter) {
            return seal(&shorter);
        }
    }
    seal(&payload.plaintext(None))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::seal::open;
    use serde_json::json;
    use std::path::PathBuf;

    fn vectors() -> Value {
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("test-vectors/notification-payload-v1.json");
        serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
    }

    fn vector_key(vector: &Value) -> Vec<u8> {
        base64::decode_url_strict(vector["key"].as_str().unwrap()).unwrap()
    }

    fn vector_nonce(envelope: &str) -> Vec<u8> {
        let wire: Value = serde_json::from_str(envelope).unwrap();
        base64::decode_url_strict(wire["n"].as_str().unwrap()).unwrap()
    }

    fn counting_key() -> Vec<u8> {
        (0..32).collect()
    }

    fn payload() -> NotificationPayload<'static> {
        // Observed-family herdr pane id (opaque `w…:p…`, uppercase included).
        NotificationPayload {
            pane_id: "wV:p1",
            agent_kind: "claude",
            status: "blocked",
            timestamp: 1_753_305_600,
            ..NotificationPayload::default()
        }
    }

    fn code_of(result: Result<String, EnvelopeError>) -> ErrorCode {
        result.unwrap_err().code
    }

    // suite("shared vectors (encrypt direction)")

    #[test]
    fn vector_file_has_cases() {
        let vectors = vectors();
        assert!(vectors["valid"].as_array().unwrap().len() >= 3);
        assert!(vectors["invalid"].as_array().unwrap().len() >= 10);
        assert!(
            vectors["invalid"]
                .as_array()
                .unwrap()
                .iter()
                .any(|v| v["error"] == "decrypt_failed")
        );
    }

    #[test]
    fn derives_the_key_id_for_every_vector() {
        for vector in vectors()["valid"].as_array().unwrap() {
            assert_eq!(
                notification_key_id(&vector_key(vector)).unwrap(),
                vector["keyId"].as_str().unwrap(),
                "{}",
                vector["name"]
            );
        }
    }

    #[test]
    fn encrypts_canonically_every_vector() {
        let vectors = vectors();
        let mut sealed = 0;
        for vector in vectors["valid"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|v| v["decodeOnly"] != true)
        {
            let envelope = vector["envelope"].as_str().unwrap();
            let nonce = vector_nonce(envelope);
            let payload = NotificationPayload::from_json(&vector["payload"]).unwrap();
            let sealed_envelope =
                encrypt_notification_envelope(&payload, &vector_key(vector), Some(&nonce)).unwrap();
            assert_eq!(sealed_envelope, envelope, "{}", vector["name"]);
            sealed += 1;
        }
        assert!(sealed >= 14);
    }

    /// The decrypt direction Rust adds for the app's own seal: every valid
    /// vector opens under the notification AAD to the plaintext the payload
    /// encodes to, and every invalid one fails at the framing or the GCM tag
    /// with the vector's code (the `bad_payload` ones fail later, in the
    /// payload decoder the app owns).
    #[test]
    fn opens_every_vector_like_the_app() {
        let vectors = vectors();
        for vector in vectors["valid"].as_array().unwrap() {
            let plaintext = open(
                vector["envelope"].as_str().unwrap(),
                &vector_key(vector),
                NOTIFICATION_AAD,
                "notification",
            )
            .unwrap_or_else(|e| panic!("{}: {e}", vector["name"]));
            let opened: Value = serde_json::from_slice(&plaintext).unwrap();
            assert_eq!(
                opened["pane"], vector["payload"]["paneId"],
                "{}",
                vector["name"]
            );
            assert_eq!(opened["kind"], vector["payload"]["agentKind"]);
            assert_eq!(opened["status"], vector["payload"]["status"]);
            assert_eq!(opened["ts"], vector["payload"]["timestamp"]);
        }
        for vector in vectors["invalid"].as_array().unwrap() {
            let expected = vector["error"].as_str().unwrap();
            let result = open(
                vector["envelope"].as_str().unwrap(),
                &vector_key(vector),
                NOTIFICATION_AAD,
                "notification",
            );
            match expected {
                "bad_payload" => {
                    result.unwrap_or_else(|e| panic!("{}: {e}", vector["name"]));
                }
                code => assert_eq!(
                    result.unwrap_err().code.as_str(),
                    code,
                    "{}",
                    vector["name"]
                ),
            }
        }
    }

    // suite("encryptNotificationEnvelope")

    #[test]
    fn generates_a_fresh_random_nonce_when_none_is_injected() {
        let key = counting_key();
        let first: Value =
            serde_json::from_str(&encrypt_notification_envelope(&payload(), &key, None).unwrap())
                .unwrap();
        let second: Value =
            serde_json::from_str(&encrypt_notification_envelope(&payload(), &key, None).unwrap())
                .unwrap();
        assert_eq!(
            base64::decode_url_strict(first["n"].as_str().unwrap())
                .unwrap()
                .len(),
            12
        );
        assert_ne!(first["n"], second["n"]);
        assert_ne!(first["ct"], second["ct"]);
        assert_eq!(first["kid"], json!(notification_key_id(&key).unwrap()));
    }

    #[test]
    fn rejects_invalid_payloads_before_encrypting() {
        let key = counting_key();
        let valid = json!({
            "paneId": "wV:p1", "agentKind": "claude", "status": "blocked", "timestamp": 1753305600
        });
        let with = |field: &str, value: Value| {
            let mut copy = valid.clone();
            match value {
                // `{ ...payload, status: undefined }`: present but undefined.
                Value::Null if field == "status" => {
                    copy.as_object_mut().unwrap().remove(field);
                }
                value => copy[field] = value,
            }
            copy
        };
        let long = "x".repeat(257);
        let bads = [
            with("paneId", json!("")),
            with("paneId", json!(5)),
            with("agentKind", json!("")),
            with("status", json!("")),
            with("status", Value::Null),
            with("timestamp", json!(0)),
            with("timestamp", json!(17.5)),
            with("timestamp", json!("1753305600")),
            with("project", json!(5)),
            with("title", json!({})),
            with("title", json!(long)),
            with("summary", json!(["approve merge"])),
            with("summary", json!(long)),
            with("attention", json!(-1)),
            with("attention", json!(1.5)),
            with("attention", json!("3")),
            with("reply", json!(42)),
            with("reply", json!(["done"])),
        ];
        assert_eq!(bads.len(), 18);
        for bad in &bads {
            let error = NotificationPayload::from_json(bad)
                .and_then(|payload| {
                    encrypt_notification_envelope(&payload, &key, None).map(|_| payload)
                })
                .unwrap_err();
            assert_eq!(error.code, ErrorCode::BadPayload, "{bad}");
        }
    }

    #[test]
    fn bad_payload_messages_match_the_js() {
        let error = |value: Value| NotificationPayload::from_json(&value).unwrap_err().message;
        let base = json!({"paneId": "p", "agentKind": "k", "status": "s", "timestamp": 1});
        let with = |field: &str, value: Value| {
            let mut copy = base.clone();
            copy[field] = value;
            copy
        };
        assert_eq!(
            error(with("paneId", json!(5))),
            "paneId must be a non-empty string"
        );
        assert_eq!(
            error(with("timestamp", json!(17.5))),
            "timestamp must be a positive unix-seconds integer, got 17.5"
        );
        assert_eq!(
            error(with("timestamp", json!("1753305600"))),
            "timestamp must be a positive unix-seconds integer, got 1753305600"
        );
        assert_eq!(
            error(with("title", json!("x".repeat(257)))),
            "title must be at most 256 characters"
        );
        assert_eq!(
            error(with("summary", json!([1]))),
            "summary must be a string when present"
        );
        assert_eq!(
            error(with("attention", json!(-1))),
            "attention must be a non-negative integer when present, got -1"
        );
        assert_eq!(
            error(with("reply", json!(42))),
            "reply must be a string when present"
        );
        assert_eq!(
            error(json!({"paneId": "p"})),
            "agentKind must be a non-empty string"
        );
    }

    #[test]
    fn display_field_limit_counts_utf16_units() {
        let key = counting_key();
        // 128 emoji are 256 UTF-16 units (accepted), 129 are 258 (rejected).
        let fits = "😀".repeat(128);
        let over = "😀".repeat(129);
        let mut p = payload();
        p.title = Some(&fits);
        assert!(encrypt_notification_envelope(&p, &key, None).is_ok());
        p.title = Some(&over);
        assert_eq!(
            code_of(encrypt_notification_envelope(&p, &key, None)),
            ErrorCode::BadPayload
        );
    }

    /// Absent, null and empty must all encode the same way, so a Host that
    /// failed to resolve a display field still produces a canonical envelope.
    #[test]
    fn omits_display_fields_that_are_absent_null_or_empty() {
        let key = counting_key();
        let nonce = [0u8; 12];
        let encrypt =
            |p: &NotificationPayload| encrypt_notification_envelope(p, &key, Some(&nonce)).unwrap();
        let baseline = encrypt(&payload());
        let empty = NotificationPayload {
            project: Some(""),
            title: Some(""),
            summary: Some(""),
            ..payload()
        };
        assert_eq!(encrypt(&empty), baseline);
        let from_null = json!({
            "paneId": "wV:p1", "agentKind": "claude", "status": "blocked",
            "timestamp": 1753305600, "project": null, "title": null, "summary": null
        });
        assert_eq!(
            encrypt(&NotificationPayload::from_json(&from_null).unwrap()),
            baseline
        );
        let project = NotificationPayload {
            project: Some("Caterm"),
            ..payload()
        };
        assert_ne!(encrypt(&project), baseline);
    }

    /// Absent and null mean "no count" (the app leaves its badge alone); 0 is
    /// a real count and must reach the app.
    #[test]
    fn omits_an_absent_attention_count_but_sends_zero() {
        let key = counting_key();
        let nonce = [0u8; 12];
        let encrypt =
            |p: &NotificationPayload| encrypt_notification_envelope(p, &key, Some(&nonce)).unwrap();
        let baseline = encrypt(&payload());
        let from_null = json!({
            "paneId": "wV:p1", "agentKind": "claude", "status": "blocked",
            "timestamp": 1753305600, "attention": null
        });
        assert_eq!(
            encrypt(&NotificationPayload::from_json(&from_null).unwrap()),
            baseline
        );
        let zero = NotificationPayload {
            attention: Some(0),
            ..payload()
        };
        assert_ne!(encrypt(&zero), baseline);
    }

    #[test]
    fn omits_a_reply_that_is_absent_null_empty_or_only_whitespace() {
        let key = counting_key();
        let nonce = [0u8; 12];
        let baseline = encrypt_notification_envelope(&payload(), &key, Some(&nonce)).unwrap();
        for reply in [None, Some(""), Some(" \r\n\t ")] {
            let p = NotificationPayload { reply, ..payload() };
            assert_eq!(
                encrypt_notification_envelope(&p, &key, Some(&nonce)).unwrap(),
                baseline
            );
        }
    }

    // The relay rejects an APNs body over 4,096 bytes, so the reply gives way.
    #[test]
    fn a_reply_that_would_overflow_the_ciphertext_budget_is_halved_then_dropped() {
        let key = counting_key();
        let nonce = [0u8; 12];
        let open_payload = |envelope: &str| -> Value {
            let wire: Value = serde_json::from_str(envelope).unwrap();
            let ct = wire["ct"].as_str().unwrap();
            assert!(ct.len() <= ENVELOPE_CT_BUDGET, "ct is {} bytes", ct.len());
            serde_json::from_slice(&open(envelope, &key, NOTIFICATION_AAD, "notification").unwrap())
                .unwrap()
        };
        let reply = "答".repeat(400);

        let with_reply = NotificationPayload {
            reply: Some(&reply),
            ..payload()
        };
        let roomy =
            open_payload(&encrypt_notification_envelope(&with_reply, &key, Some(&nonce)).unwrap());
        assert_eq!(
            roomy["reply"].as_str().unwrap(),
            normalize_reply(&reply, REPLY_MAX_BYTES).unwrap()
        );

        let title = "修".repeat(200);
        let summary = "复".repeat(200);
        let crowded = NotificationPayload {
            title: Some(&title),
            summary: Some(&summary),
            reply: Some(&reply),
            ..payload()
        };
        let halved =
            open_payload(&encrypt_notification_envelope(&crowded, &key, Some(&nonce)).unwrap());
        assert_eq!(
            halved["reply"].as_str().unwrap(),
            normalize_reply(&reply, 500).unwrap()
        );
        assert_eq!(halved["summary"].as_str().unwrap(), summary);

        let project = "项".repeat(120);
        let full_title = "修".repeat(256);
        let full_summary = "复".repeat(256);
        let full = NotificationPayload {
            project: Some(&project),
            title: Some(&full_title),
            summary: Some(&full_summary),
            ..crowded
        };
        let dropped =
            open_payload(&encrypt_notification_envelope(&full, &key, Some(&nonce)).unwrap());
        assert!(dropped.get("reply").is_none());
        assert_eq!(dropped["summary"].as_str().unwrap(), full_summary);
    }

    #[test]
    fn rejects_a_key_that_is_not_32_bytes() {
        let error = encrypt_notification_envelope(&payload(), &[0u8; 16], None).unwrap_err();
        assert_eq!(error.code, ErrorCode::Type);
    }

    #[test]
    fn rejects_an_injected_nonce_that_is_not_12_bytes() {
        let error = encrypt_notification_envelope(&payload(), &counting_key(), Some(&[0u8; 8]))
            .unwrap_err();
        assert_eq!(error.code, ErrorCode::Type);
    }

    #[test]
    fn a_null_payload_is_the_destructuring_type_error() {
        let error = NotificationPayload::from_json(&Value::Null).unwrap_err();
        assert_eq!(error.code, ErrorCode::Type);
    }

    // suite("normalizeReply")

    #[test]
    fn turns_crlf_into_lf_trims_and_keeps_inner_line_breaks() {
        assert_eq!(
            normalize_reply("\r\n  one\r\ntwo\n\nthree  \r\n", REPLY_MAX_BYTES).unwrap(),
            "one\ntwo\n\nthree"
        );
    }

    #[test]
    fn keeps_a_reply_of_exactly_1000_bytes_intact() {
        let exact = "é".repeat(500);
        assert_eq!(exact.len(), 1000);
        assert_eq!(normalize_reply(&exact, REPLY_MAX_BYTES).unwrap(), exact);
    }

    #[test]
    fn caps_at_1000_bytes_including_the_ellipsis_on_a_grapheme_boundary() {
        // A family emoji is one grapheme of 25 bytes; it must never be split.
        let family = "👨‍👩‍👧‍👦";
        let capped = normalize_reply(&family.repeat(60), REPLY_MAX_BYTES).unwrap();
        assert!(capped.len() <= 1000);
        assert!(capped.ends_with('…'));
        assert_eq!(capped, format!("{}…", family.repeat(39)));
    }

    #[test]
    fn does_not_leave_trailing_whitespace_before_the_ellipsis() {
        let text = format!("{} {}", "a".repeat(996), "b".repeat(10));
        assert_eq!(
            normalize_reply(&text, REPLY_MAX_BYTES).unwrap(),
            format!("{}…", "a".repeat(996))
        );
    }

    #[test]
    fn strips_c0_controls_but_keeps_tabs_and_line_breaks() {
        assert_eq!(
            normalize_reply("a\u{0}b\u{7}c\u{1b}[0m\td\re\nf\u{1f}", REPLY_MAX_BYTES).unwrap(),
            "abc[0m\tde\nf"
        );
    }

    /// The JS test feeds lone UTF-16 surrogates, which `&str` cannot hold.
    /// What a Rust caller can hold is the U+FFFD that lossy UTF-8 decoding
    /// leaves in their place, and valid pairs: both are kept as they are.
    #[test]
    fn replaces_lone_surrogates_and_keeps_valid_pairs() {
        let decoded = String::from_utf8_lossy(b"x\xed\xa0\x80y\xed\xb0\x80z\xf0\x9f\x91\x8d");
        assert_eq!(
            normalize_reply(&decoded, REPLY_MAX_BYTES).unwrap(),
            "x\u{fffd}\u{fffd}\u{fffd}y\u{fffd}\u{fffd}\u{fffd}z👍"
        );
        assert_eq!(
            normalize_reply("end\u{fffd}", REPLY_MAX_BYTES).unwrap(),
            "end\u{fffd}"
        );
        assert_eq!(normalize_reply("z👍", REPLY_MAX_BYTES).unwrap(), "z👍");
    }

    // Quotes and backslashes cost two bytes once the plaintext is JSON.
    #[test]
    fn caps_the_json_escaped_size_not_the_raw_size() {
        let capped = normalize_reply(&"\"".repeat(800), REPLY_MAX_BYTES).unwrap();
        assert_eq!(capped, format!("{}…", "\"".repeat(498)));
        assert!(json_escaped_len(&capped) <= 1000);
        assert_eq!(
            normalize_reply(&"\\".repeat(500), REPLY_MAX_BYTES).unwrap(),
            "\\".repeat(500)
        );
    }

    #[test]
    fn takes_a_smaller_cap_for_the_halved_fallback() {
        let capped = normalize_reply(&"é".repeat(400), 500).unwrap();
        assert_eq!(capped, format!("{}…", "é".repeat(248)));
    }

    /// The doc's claim about JSON input: serde_json refuses the lone-surrogate
    /// escape `JSON.parse` accepts, so such text never reaches this module.
    #[test]
    fn serde_json_rejects_lone_surrogate_escapes() {
        assert!(serde_json::from_str::<Value>(r#""\ud800""#).is_err());
        assert!(serde_json::from_str::<Value>(r#""\udc00x""#).is_err());
        assert_eq!(
            serde_json::from_str::<Value>(r#""\ud83d\udc4d""#).unwrap(),
            json!("👍")
        );
    }

    #[test]
    fn normalize_reply_edge_cases() {
        assert_eq!(normalize_reply("", REPLY_MAX_BYTES), None);
        assert_eq!(
            normalize_reply("\u{feff}\u{a0}\u{85}", REPLY_MAX_BYTES),
            Some("\u{85}".into())
        );
        // Nothing fits before the ellipsis: dropped.
        assert_eq!(normalize_reply("😀😀😀", 4), None);
        assert_eq!(normalize_reply("😀😀😀", 7), Some("😀…".into()));
    }
}
