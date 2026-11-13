//! The parts of a parsed Codex `config.toml` the hooks read. The JS uses
//! smol-toml; this wraps the `toml` crate and answers the same questions
//! (`parse(text).features?.hooks`, `.hooks?.state[key]`, deep equality of two
//! documents). The file is only ever read here; edits are text edits.
//!
//! smol-toml and the `toml` crate disagree on a few inputs. Two are made to
//! agree here (a leading BOM, and an integer smol-toml cannot hold exactly);
//! the others stay: smol-toml accepts dates such as `1979-02-30`, a time with
//! an offset and no date (`07:32:00+01:00`) and the malformed header `[[a]`,
//! and refuses the leap second `07:32:60`. An error carries the first line of
//! smol-toml's message only (the code block under it is not reproduced).

use toml::{Table, Value};

/// `features.hooks` as JavaScript sees it: only a real boolean counts.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FeatureFlag {
    /// No `features` table, no `hooks` key, or a `hooks` that is not a boolean.
    Unset,
    On,
    Off,
}

#[derive(Debug, Clone)]
pub struct TomlDoc(Table);

impl TomlDoc {
    pub fn parse(text: &str) -> Result<Self, String> {
        if text.starts_with('\u{feff}') {
            return Err("Invalid TOML document: only letter, numbers, dashes and underscores are allowed in keys".into());
        }
        let table = text.parse::<Table>().map_err(|e| e.to_string())?;
        if !table.values().all(is_lossless) {
            return Err(
                "Invalid TOML document: integer value cannot be represented losslessly".into(),
            );
        }
        Ok(Self(table))
    }

    /// Whether the document has a `features` key of any type.
    pub fn has_features(&self) -> bool {
        self.0.contains_key("features")
    }

    pub fn hooks_flag(&self) -> FeatureFlag {
        match self
            .0
            .get("features")
            .and_then(Value::as_table)
            .and_then(|features| features.get("hooks"))
        {
            Some(Value::Boolean(true)) => FeatureFlag::On,
            Some(Value::Boolean(false)) => FeatureFlag::Off,
            _ => FeatureFlag::Unset,
        }
    }

    /// Whether `[hooks.state."<key>"]` holds `trusted_hash = "<hash>"` and
    /// is not disabled with `enabled = false`.
    pub fn trusts(&self, key: &str, hash: &str) -> bool {
        let entry = self
            .0
            .get("hooks")
            .and_then(Value::as_table)
            .and_then(|hooks| hooks.get("state"))
            .and_then(Value::as_table)
            .and_then(|state| state.get(key))
            .and_then(Value::as_table);
        entry.is_some_and(|entry| {
            entry.get("trusted_hash").and_then(Value::as_str) == Some(hash)
                && entry.get("enabled") != Some(&Value::Boolean(false))
        })
    }

    /// This document with `[features] hooks = true`: what an edit must parse to.
    pub fn with_hooks_enabled(&self) -> Self {
        let mut features = match self.0.get("features") {
            Some(Value::Table(features)) => features.clone(),
            _ => Table::new(),
        };
        features.insert("hooks".into(), Value::Boolean(true));
        let mut doc = self.0.clone();
        doc.insert("features".into(), Value::Table(features));
        Self(doc)
    }

    /// `util.isDeepStrictEqual` of two documents.
    pub fn same_as(&self, other: &Self) -> bool {
        tables_equal(&self.0, &other.0)
    }
}

/// JavaScript numbers hold integers exactly up to 2^53 - 1; smol-toml refuses
/// any other.
fn is_lossless(value: &Value) -> bool {
    match value {
        Value::Integer(n) => n.unsigned_abs() < 1 << 53,
        Value::Array(items) => items.iter().all(is_lossless),
        Value::Table(table) => table.values().all(is_lossless),
        _ => true,
    }
}

fn tables_equal(a: &Table, b: &Table) -> bool {
    a.len() == b.len()
        && a.iter()
            .all(|(key, value)| b.get(key).is_some_and(|other| values_equal(value, other)))
}

fn values_equal(a: &Value, b: &Value) -> bool {
    match (a, b) {
        // Object.is: NaN equals NaN, 0 differs from -0.
        (Value::Float(x), Value::Float(y)) => {
            x.to_bits() == y.to_bits() || (x.is_nan() && y.is_nan())
        }
        (Value::Array(x), Value::Array(y)) => {
            x.len() == y.len() && x.iter().zip(y).all(|(p, q)| values_equal(p, q))
        }
        (Value::Table(x), Value::Table(y)) => tables_equal(x, y),
        (x, y) => x == y,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_a_boolean_hooks_flag_counts() {
        let flag = |text: &str| TomlDoc::parse(text).unwrap().hooks_flag();
        assert_eq!(flag(""), FeatureFlag::Unset);
        assert_eq!(flag("[features]\nhooks = true"), FeatureFlag::On);
        assert_eq!(flag("features.hooks = false"), FeatureFlag::Off);
        assert_eq!(flag("features = { hooks = true }"), FeatureFlag::On);
        assert_eq!(flag("[features]\nhooks = 1"), FeatureFlag::Unset);
        assert_eq!(flag("[features]\nhooks = \"true\""), FeatureFlag::Unset);
        assert_eq!(flag("features = 5"), FeatureFlag::Unset);
        assert_eq!(flag("[[features]]\nhooks = true"), FeatureFlag::Unset);
        assert!(TomlDoc::parse("features = 5").unwrap().has_features());
        assert!(!TomlDoc::parse("a = 1").unwrap().has_features());
    }

    #[test]
    fn trust_wants_the_hash_and_no_disabling() {
        let doc = |text: &str| TomlDoc::parse(text).unwrap();
        let trusted = doc("[hooks.state.\"k\"]\ntrusted_hash = \"h\"\nenabled = true\n");
        assert!(trusted.trusts("k", "h"));
        assert!(!trusted.trusts("k", "other"));
        assert!(!trusted.trusts("missing", "h"));
        assert!(
            !doc("[hooks.state.\"k\"]\ntrusted_hash = \"h\"\nenabled = false\n").trusts("k", "h")
        );
        assert!(!doc("[hooks.state.\"k\"]\ntrusted_hash = 5\n").trusts("k", "h"));
        assert!(!doc("hooks.state = \"x\"\n").trusts("k", "h"));
        assert!(!doc("[[hooks]]\nstate = 1\n").trusts("k", "h"));
        assert!(!doc("hooks.state.k = 1979-05-27\n").trusts("k", "h"));
    }

    #[test]
    fn documents_compare_as_object_is_does() {
        let doc = |text: &str| TomlDoc::parse(text).unwrap();
        assert!(
            doc("a = nan\nb = [1, { c = -0.0 }]").same_as(&doc("b = [1, { c = -0.0 }]\na = nan"))
        );
        assert!(!doc("a = 0.0").same_as(&doc("a = -0.0")));
        assert!(!doc("a = 1").same_as(&doc("a = 1.0")));
        assert!(!doc("a = 1").same_as(&doc("a = 1\nb = 2")));
        assert!(doc("a = 1979-05-27T07:32:00Z").same_as(&doc("a = 1979-05-27T07:32:00Z")));
        assert!(
            doc("[features]\nfoo = 1")
                .with_hooks_enabled()
                .same_as(&doc("[features]\nfoo = 1\nhooks = true"))
        );
        assert!(
            doc("")
                .with_hooks_enabled()
                .same_as(&doc("features.hooks = true"))
        );
    }

    #[test]
    fn what_smol_toml_refuses_is_refused_here_too() {
        assert!(TomlDoc::parse("\u{feff}a = 1").is_err());
        assert!(TomlDoc::parse("a = 9007199254740992").is_err());
        assert!(TomlDoc::parse("a = -9007199254740992").is_err());
        assert!(TomlDoc::parse("a = 9007199254740991").is_ok());
        assert!(TomlDoc::parse("[t]\nx = [9223372036854775807]").is_err());
        assert!(TomlDoc::parse("a = 0xFFFFFFFFFFFFFFF").is_err());
    }
}
