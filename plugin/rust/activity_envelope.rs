//! Live Activity content envelope v1 (activity-envelope.js,
//! docs/agents/live-activity-contract.md).
//!
//! Same AES-256-GCM framing as the notification envelope (see `seal`), sealed
//! under AAD `HERDR-ACTIVITY:1` so the two ciphertexts cannot be opened as
//! each other. The canonical plaintext is compact JSON with object keys in
//! ascending alphabetical order at every level. `test-vectors/
//! live-activity-content-v1.json` proves both directions: this side seals
//! every non-`decodeOnly` vector byte for byte and opens all of them, and the
//! Swift side does the same.
//!
//! The plaintext is a `serde_json::Value` because the JS function is
//! dynamically typed: it copies `kind`, `pane`, `status`, `host`, `v` and a
//! span's `text` as they are, drops absent ones (a JS `undefined`), and
//! filters the optional fields by `typeof`. A value the JS would throw on
//! (`null` where an object is read, a row that is not an array) is an
//! [`ErrorCode::Type`] error here. Integers follow `Number.isInteger`, so
//! `3.0` is the integer 3 and prints as `3`.

use serde_json::Value;

use crate::js_compat::js_integer;
use crate::jsx;
pub use crate::seal::{ENVELOPE_VERSION, KEY_BYTES, NONCE_BYTES};
use crate::seal::{EnvelopeError, ErrorCode, derive_key_id, open, seal};

pub const ACTIVITY_ENVELOPE_VERSION: u32 = ENVELOPE_VERSION;
pub const ACTIVITY_AAD: &[u8] = b"HERDR-ACTIVITY:1";

/// `value[name]` as JS reads it: `null` throws, an object has the property or
/// not (`undefined`), any other value has none.
fn prop<'a>(value: &'a Value, name: &str) -> Result<Option<&'a Value>, EnvelopeError> {
    match value {
        Value::Null => Err(EnvelopeError::type_error(format!(
            "Cannot read properties of null (reading '{name}')"
        ))),
        Value::Object(map) => Ok(map.get(name)),
        _ => Ok(None),
    }
}

/// A non-empty string, the `typeof x === "string" && x.length > 0` test.
fn non_empty_str(value: Option<&Value>) -> Option<&str> {
    value
        .and_then(Value::as_str)
        .filter(|text| !text.is_empty())
}

/// Appends `{`, then fields in the order written, comma-separated.
struct Object<'a> {
    out: &'a mut String,
    first: bool,
}

impl<'a> Object<'a> {
    fn open(out: &'a mut String) -> Self {
        out.push('{');
        Self { out, first: true }
    }

    fn key(&mut self, name: &str) -> &mut String {
        if !self.first {
            self.out.push(',');
        }
        self.first = false;
        jsx::write_json_string(name, self.out);
        self.out.push(':');
        self.out
    }

    fn value(&mut self, name: &str, value: Option<&Value>) {
        if let Some(value) = value {
            jsx::write_json(value, self.key(name));
        }
    }

    fn text(&mut self, name: &str, value: &str) {
        jsx::write_json_string(value, self.key(name));
    }

    fn close(self) {
        self.out.push('}');
    }
}

fn push_progress(out: &mut String, progress: &Value) -> Result<(), EnvelopeError> {
    let mut object = Object::open(out);
    let done = prop(progress, "done")?;
    if let Some(done) = done.filter(|v| js_integer(Some(v)).is_some()) {
        object.value("done", Some(done));
    }
    if let Some(phase) = prop(progress, "phase")?.and_then(Value::as_str) {
        object.text("phase", phase);
    }
    if let Some(total) = prop(progress, "total")?.filter(|v| js_integer(Some(v)).is_some()) {
        object.value("total", Some(total));
    }
    object.close();
    Ok(())
}

fn push_rows(out: &mut String, rows: &[Value]) -> Result<(), EnvelopeError> {
    out.push('[');
    for (i, row) in rows.iter().enumerate() {
        let Value::Array(spans) = row else {
            return Err(EnvelopeError::type_error(if row.is_null() {
                "Cannot read properties of null (reading 'map')"
            } else {
                "row.map is not a function"
            }));
        };
        if i > 0 {
            out.push(',');
        }
        out.push('[');
        for (j, span) in spans.iter().enumerate() {
            if j > 0 {
                out.push(',');
            }
            let mut field = Object::open(out);
            if let Some(Value::Bool(bold)) = prop(span, "bold")? {
                field.value("bold", Some(&Value::Bool(*bold)));
            }
            if let Some(Value::Bool(dim)) = prop(span, "dim")? {
                field.value("dim", Some(&Value::Bool(*dim)));
            }
            if let Some(fg) = prop(span, "fg")?.and_then(Value::as_str) {
                field.text("fg", fg);
            }
            field.value("text", prop(span, "text")?);
            field.close();
        }
        out.push(']');
    }
    out.push(']');
    Ok(())
}

fn push_agent(out: &mut String, agent: &Value) -> Result<(), EnvelopeError> {
    let mut entry = Object::open(out);
    entry.value("kind", prop(agent, "kind")?);
    if let Some(name) = non_empty_str(prop(agent, "name")?) {
        entry.text("name", name);
    }
    entry.value("pane", prop(agent, "pane")?);
    if let Some(progress) =
        prop(agent, "progress")?.filter(|p| matches!(p, Value::Object(_) | Value::Array(_)))
    {
        push_progress(entry.key("progress"), progress)?;
    }
    if let Some(Value::Array(rows)) = prop(agent, "rows")? {
        push_rows(entry.key("rows"), rows)?;
    }
    entry.value("status", prop(agent, "status")?);
    if let Some(title) = non_empty_str(prop(agent, "title")?) {
        entry.text("title", title);
    }
    if let Some(workspace) = non_empty_str(prop(agent, "workspace")?) {
        entry.text("workspace", workspace);
    }
    entry.close();
    Ok(())
}

/// Canonical compact JSON for an activity plaintext object. Keys are emitted
/// in ascending alphabetical order at every level; empty titles are omitted.
pub fn canonical_activity_plaintext(plaintext: &Value) -> Result<String, EnvelopeError> {
    let agents = match plaintext {
        Value::Object(map) => match map.get("agents") {
            Some(Value::Array(agents)) => agents.as_slice(),
            _ => &[],
        },
        _ => &[],
    };
    let mut out = String::with_capacity(256 * (agents.len() + 1));
    let mut top = Object::open(&mut out);
    top.key("agents").push('[');
    for (i, agent) in agents.iter().enumerate() {
        if i > 0 {
            top.out.push(',');
        }
        push_agent(top.out, agent)?;
    }
    top.out.push(']');
    top.value("host", prop(plaintext, "host")?);
    top.value("v", prop(plaintext, "v")?);
    top.close();
    Ok(out)
}

/// Encrypt an activity plaintext object (`{agents, host, v}` already in
/// canonical form) into its canonical v1 envelope string. `nonce` is the
/// injectable 12-byte nonce (tests only): production passes `None`.
pub fn encrypt_activity_envelope(
    plaintext: &Value,
    key: &[u8],
    nonce: Option<&[u8]>,
) -> Result<String, EnvelopeError> {
    seal(
        &canonical_activity_plaintext(plaintext)?,
        key,
        ACTIVITY_AAD,
        nonce,
    )
}

pub fn activity_key_id(key: &[u8]) -> Result<String, EnvelopeError> {
    derive_key_id(key)
}

fn bad_payload(message: impl Into<String>) -> EnvelopeError {
    EnvelopeError::new(ErrorCode::BadPayload, message)
}

/// Open an activity envelope and return the plaintext object.
///
/// Errors: `Type` (key not 32 bytes), `BadEnvelope`, `UnsupportedVersion`,
/// `DecryptFailed`, `BadPayload`.
pub fn decrypt_activity_envelope(envelope: &str, key: &[u8]) -> Result<Value, EnvelopeError> {
    let raw = open(envelope, key, ACTIVITY_AAD, "activity")?;
    // `Buffer.toString("utf8")` decodes lossily, as `from_utf8_lossy` does.
    let payload: Value = serde_json::from_str(&String::from_utf8_lossy(&raw))
        .map_err(|_| bad_payload("plaintext is not JSON"))?;
    validate_activity_plaintext(&payload)?;
    Ok(payload)
}

fn validate_activity_plaintext(payload: &Value) -> Result<(), EnvelopeError> {
    let Value::Object(payload) = payload else {
        return Err(bad_payload("plaintext must be a JSON object"));
    };
    let version = payload.get("v");
    if version.and_then(Value::as_f64) != Some(f64::from(ACTIVITY_ENVELOPE_VERSION)) {
        return Err(bad_payload(format!(
            "plaintext version must be {ACTIVITY_ENVELOPE_VERSION}"
        )));
    }
    if non_empty_str(payload.get("host")).is_none() {
        return Err(bad_payload("host must be a non-empty string"));
    }
    let Some(Value::Array(agents)) = payload.get("agents") else {
        return Err(bad_payload("agents must be an array"));
    };
    for agent in agents {
        let Value::Object(agent) = agent else {
            return Err(bad_payload("agent entry must be an object"));
        };
        if non_empty_str(agent.get("status")).is_none() {
            return Err(bad_payload("agent status must be a non-empty string"));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::base64;
    use serde_json::json;
    use std::path::PathBuf;

    fn vectors() -> Value {
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("test-vectors/live-activity-content-v1.json");
        serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
    }

    fn vector_key(vector: &Value) -> Vec<u8> {
        base64::decode_url_strict(vector["key"].as_str().unwrap()).unwrap()
    }

    fn counting_key() -> Vec<u8> {
        (0..32).collect()
    }

    /// The fields the Swift side and the JS test compare: what survives
    /// canonicalization of the vector payload.
    fn opened_fields(payload: &Value) -> Value {
        let agents: Vec<Value> = payload["agents"]
            .as_array()
            .unwrap()
            .iter()
            .map(|agent| {
                let mut entry = json!({
                    "kind": agent["kind"], "pane": agent["pane"], "status": agent["status"]
                });
                let entry_map = entry.as_object_mut().unwrap();
                if non_empty_str(agent.get("name")).is_some() {
                    entry_map.insert("name".into(), agent["name"].clone());
                }
                if agent.get("progress").is_some() {
                    entry_map.insert("progress".into(), agent["progress"].clone());
                }
                if agent["rows"].is_array() {
                    entry_map.insert("rows".into(), agent["rows"].clone());
                }
                for field in ["title", "workspace"] {
                    if non_empty_str(agent.get(field)).is_some() {
                        entry_map.insert(field.into(), agent[field].clone());
                    }
                }
                entry
            })
            .collect();
        json!({"v": payload["v"], "host": payload["host"], "agents": agents})
    }

    // suite("shared live-activity vectors (seal direction)")

    #[test]
    fn vector_file_has_cases() {
        let vectors = vectors();
        assert!(vectors["valid"].as_array().unwrap().len() >= 4);
        assert!(vectors["invalid"].as_array().unwrap().len() >= 4);
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
                activity_key_id(&vector_key(vector)).unwrap(),
                vector["keyId"].as_str().unwrap(),
                "{}",
                vector["name"]
            );
        }
    }

    #[test]
    fn seals_canonically_every_vector() {
        let vectors = vectors();
        let mut sealed = 0;
        for vector in vectors["valid"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|v| v["decodeOnly"] != true)
        {
            let envelope = vector["envelope"].as_str().unwrap();
            let wire: Value = serde_json::from_str(envelope).unwrap();
            let nonce = base64::decode_url_strict(wire["n"].as_str().unwrap()).unwrap();
            let sealed_envelope =
                encrypt_activity_envelope(&vector["payload"], &vector_key(vector), Some(&nonce))
                    .unwrap();
            assert_eq!(sealed_envelope, envelope, "{}", vector["name"]);
            sealed += 1;
        }
        assert!(sealed >= 8);
    }

    #[test]
    fn opens_every_vector() {
        for vector in vectors()["valid"].as_array().unwrap() {
            let payload = decrypt_activity_envelope(
                vector["envelope"].as_str().unwrap(),
                &vector_key(vector),
            )
            .unwrap_or_else(|e| panic!("{}: {e}", vector["name"]));
            assert_eq!(
                opened_fields(&payload),
                opened_fields(&vector["payload"]),
                "{}",
                vector["name"]
            );
        }
    }

    // suite("shared live-activity vectors (invalid)")

    #[test]
    fn fails_with_the_vectors_code_for_every_invalid_vector() {
        for vector in vectors()["invalid"].as_array().unwrap() {
            let error = decrypt_activity_envelope(
                vector["envelope"].as_str().unwrap(),
                &vector_key(vector),
            )
            .unwrap_err();
            assert_eq!(
                error.code.as_str(),
                vector["error"].as_str().unwrap(),
                "{}",
                vector["name"]
            );
        }
    }

    // suite("encryptActivityEnvelope")

    fn plaintext() -> Value {
        json!({
            "agents": [{"kind": "claude", "pane": "wV:p1", "status": "working"}],
            "host": "mbp",
            "v": 1
        })
    }

    #[test]
    fn generates_a_fresh_random_nonce_when_none_is_injected() {
        let key = counting_key();
        let first: Value =
            serde_json::from_str(&encrypt_activity_envelope(&plaintext(), &key, None).unwrap())
                .unwrap();
        let second: Value =
            serde_json::from_str(&encrypt_activity_envelope(&plaintext(), &key, None).unwrap())
                .unwrap();
        assert_eq!(
            base64::decode_url_strict(first["n"].as_str().unwrap())
                .unwrap()
                .len(),
            12
        );
        assert_ne!(first["n"], second["n"]);
        assert_ne!(first["ct"], second["ct"]);
        assert_eq!(first["kid"], json!(activity_key_id(&key).unwrap()));
        assert!(first["ct"].as_str().unwrap().len() >= base64::url_len(16));
    }

    #[test]
    fn rejects_a_key_that_is_not_32_bytes() {
        let error = encrypt_activity_envelope(&plaintext(), &[0u8; 16], None).unwrap_err();
        assert_eq!(error.code, ErrorCode::Type);
    }

    #[test]
    fn emits_progress_between_pane_and_rows_with_done_phase_total() {
        assert_eq!(
            canonical_activity_plaintext(&json!({
                "v": 1,
                "host": "mbp",
                "agents": [{
                    "status": "working",
                    "rows": [[{"text": "Waycar"}]],
                    "progress": {"total": 7, "phase": "verifying", "done": 3},
                    "pane": "wV:p1",
                    "kind": "claude"
                }]
            }))
            .unwrap(),
            concat!(
                r#"{"agents":[{"kind":"claude","pane":"wV:p1","progress":{"done":3,"phase":"verifying","total":7},"#,
                r#""rows":[[{"text":"Waycar"}]],"status":"working"}],"host":"mbp","v":1}"#
            )
        );
    }

    #[test]
    fn canonical_plaintext_filters_like_the_js() {
        let canonical = |value: Value| canonical_activity_plaintext(&value).unwrap();
        // Absent fields vanish, empty names/titles/workspaces are omitted,
        // span fields are typeof-filtered, 3.0 is the integer 3.
        assert_eq!(
            canonical(json!({
                "host": "h", "v": 1,
                "agents": [{
                    "pane": "p", "kind": "k", "status": "s",
                    "name": "", "title": "", "workspace": 5,
                    "progress": {"done": 3.0, "phase": 4, "total": 1.5},
                    "rows": [[{"text": "t", "bold": "yes", "dim": false, "fg": 3}]]
                }]
            })),
            r#"{"agents":[{"kind":"k","pane":"p","progress":{"done":3},"rows":[[{"dim":false,"text":"t"}]],"status":"s"}],"host":"h","v":1}"#
        );
        assert_eq!(
            canonical(json!({"agents": "x", "host": "h"})),
            r#"{"agents":[],"host":"h"}"#
        );
        assert_eq!(canonical(json!(5)), r#"{"agents":[]}"#);
        assert_eq!(
            canonical(json!({"host": "h", "v": 1, "agents": [{"progress": []}]})),
            r#"{"agents":[{"progress":{}}],"host":"h","v":1}"#
        );
        assert_eq!(
            canonical(json!({"host": "h\u{2028}\n", "v": 1, "agents": [{"kind": null}]})),
            "{\"agents\":[{\"kind\":null}],\"host\":\"h\u{2028}\\n\",\"v\":1}"
        );
    }

    #[test]
    fn canonical_plaintext_errors_where_the_js_throws() {
        for bad in [
            Value::Null,
            json!({"host": "h", "agents": [null]}),
            json!({"host": "h", "agents": [{"rows": ["x"]}]}),
            json!({"host": "h", "agents": [{"rows": [[null]]}]}),
        ] {
            let error = canonical_activity_plaintext(&bad).unwrap_err();
            assert_eq!(error.code, ErrorCode::Type, "{bad}");
        }
    }

    #[test]
    fn decrypt_reports_the_payload_failures_with_the_js_messages() {
        let key = counting_key();
        let open_text = |text: &str| {
            let envelope = seal(text, &key, ACTIVITY_AAD, Some(&[0u8; 12])).unwrap();
            decrypt_activity_envelope(&envelope, &key)
                .unwrap_err()
                .message
        };
        assert_eq!(open_text("nope"), "plaintext is not JSON");
        assert_eq!(open_text("[1]"), "plaintext must be a JSON object");
        assert_eq!(open_text(r#"{"v":2}"#), "plaintext version must be 1");
        assert_eq!(
            open_text(r#"{"v":1,"host":""}"#),
            "host must be a non-empty string"
        );
        assert_eq!(
            open_text(r#"{"v":1,"host":"h","agents":{}}"#),
            "agents must be an array"
        );
        assert_eq!(
            open_text(r#"{"v":1,"host":"h","agents":[[]]}"#),
            "agent entry must be an object"
        );
        assert_eq!(
            open_text(r#"{"v":1,"host":"h","agents":[{"status":""}]}"#),
            "agent status must be a non-empty string"
        );
        let envelope = encrypt_activity_envelope(&plaintext(), &key, None).unwrap();
        assert_eq!(
            decrypt_activity_envelope(&envelope, &key).unwrap()["host"],
            json!("mbp")
        );
    }

    #[test]
    fn notification_ciphertext_does_not_open_as_activity() {
        let key = counting_key();
        let envelope = seal(
            "{}",
            &key,
            crate::notification_envelope::NOTIFICATION_AAD,
            None,
        )
        .unwrap();
        assert_eq!(
            decrypt_activity_envelope(&envelope, &key).unwrap_err().code,
            ErrorCode::DecryptFailed
        );
    }
}
