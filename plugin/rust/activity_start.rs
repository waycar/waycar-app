//! Push-to-start bookkeeping for the Live Activity hook
//! (docs/agents/live-activity-contract.md; activity-start.js).
//!
//! A device's `live_activity_start` registration carries the app install's
//! push-to-start token and the Host's `hostID`. The hook starts a Live
//! Activity through it when the eligible inventory is non-empty and no
//! running activity on that device can take updates: at most once per
//! episode (an episode ends when the eligible inventory empties).
//!
//! The decisions are [`ActivityEpisodeMachine`] (HT-08); [`read_start_state`]
//! and [`save_start_state`] are the file around it
//! (`activity/start-state.json` in the state dir), and the Live Activity hook
//! feeds it each run's devices and each push's answer:
//!
//! * `ended_tokens`: update tokens whose activity this plugin ended with an
//!   `end` push; such a token can never take an update again.
//! * `started`: `{device id: sent_at_ms}` for devices that were started, or
//!   whose activity was dismissed, during the current episode.

use std::io;
use std::path::{Path, PathBuf};

use serde_json::{Map, Value, json};

use crate::atomic::write_atomic;
use crate::js_compat::{cmp_utf16, locale_compare, read_json};
use crate::jsx;
use crate::state_machine::StateMachine;

/// The Swift `ActivityAttributes` type name; APNs `attributes-type`.
pub const ACTIVITY_ATTRIBUTES_TYPE: &str = "AgentActivityAttributes";

/// APNs requires an alert on every start. It crosses the relay and APNs in
/// cleartext, so it is fixed, generic text: never a Host, agent, or task name.
pub const START_ALERT_TITLE: &str = "Agents active";
pub const START_ALERT_BODY: &str = "Agent status is live on your Lock Screen.";

/// `^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$`
fn is_uuid(text: &str) -> bool {
    let bytes = text.as_bytes();
    bytes.len() == 36
        && bytes.iter().enumerate().all(|(index, byte)| {
            if matches!(index, 8 | 13 | 18 | 23) {
                *byte == b'-'
            } else {
                byte.is_ascii_hexdigit()
            }
        })
}

/// The app writes `hostID` as a canonical UUID string; nothing else passes.
pub fn is_host_id(value: &Value) -> bool {
    value.as_str().is_some_and(is_uuid)
}

/// Relay request fields that make a `kind: liveactivity` push a start. The
/// host id is copied verbatim: ActivityKit decodes `attributes` into
/// `AgentActivityAttributes` with its default decoder.
pub fn start_fields(host_id: &str) -> Value {
    json!({
        "attributes_type": ACTIVITY_ATTRIBUTES_TYPE,
        "attributes": { "hostID": host_id },
        "alert": { "title": START_ALERT_TITLE, "body": START_ALERT_BODY },
    })
}

/// What the plugin remembers between runs. Both collections keep the order
/// the JS `Set` and `Map` do (insertion; a repeat keeps its place).
#[derive(Debug, Clone, Default, PartialEq)]
pub struct StartState {
    ended_tokens: Vec<String>,
    started: Vec<(String, f64)>,
}

impl StartState {
    /// Whether this plugin ended the activity behind `token`.
    pub fn is_ended(&self, token: &str) -> bool {
        self.ended_tokens.iter().any(|ended| ended == token)
    }

    /// `endedTokens.add(token)`.
    fn mark_ended(&mut self, token: &str) {
        if !self.is_ended(token) {
            self.ended_tokens.push(token.to_string());
        }
    }

    /// `started.delete(id)`.
    fn forget_started(&mut self, id: &str) {
        self.started.retain(|(started, _)| started != id);
    }

    /// Whether device `id` started (or had its activity dismissed) this episode.
    pub fn has_started(&self, id: &str) -> bool {
        self.started.iter().any(|(started, _)| started == id)
    }

    /// `started.set(id, sent_at_ms)`.
    fn mark_started(&mut self, id: &str, sent_at_ms: i64) {
        let at = sent_at_ms as f64;
        match self.started.iter_mut().find(|(started, _)| started == id) {
            Some(entry) => entry.1 = at,
            None => self.started.push((id.to_string(), at)),
        }
    }

    /// The device ids that started this episode, in state order.
    pub fn started_ids(&self) -> impl Iterator<Item = &str> {
        self.started.iter().map(|(id, _)| id.as_str())
    }

    /// The tokens whose activity this plugin ended, in state order.
    pub fn ended_tokens(&self) -> impl Iterator<Item = &str> {
        self.ended_tokens.iter().map(String::as_str)
    }
}

/// Lenient reader: anything malformed reads as an empty state.
pub fn parse_start_state(raw: Option<&Value>) -> StartState {
    let mut state = StartState::default();
    let Some(raw) = raw.and_then(Value::as_object) else {
        return state;
    };
    if let Some(tokens) = raw.get("ended_tokens").and_then(Value::as_array) {
        for token in tokens.iter().filter_map(Value::as_str) {
            state.mark_ended(token);
        }
    }
    if let Some(started) = raw.get("started").and_then(Value::as_object) {
        for (id, sent_at) in jsx::ordered_entries(started) {
            if let Some(at) = sent_at
                .as_number()
                .map(jsx::json_f64)
                .filter(|at| at.is_finite())
            {
                match state.started.iter_mut().find(|(known, _)| known == id) {
                    Some(entry) => entry.1 = at,
                    None => state.started.push((id.clone(), at)),
                }
            }
        }
    }
    state
}

/// The state as persisted: tokens sorted (UTF-16 order, like `.sort()`),
/// started devices sorted by [`locale_compare`] of their ids.
///
/// The ids are the devices' APNs tokens, which the app writes as lower-case
/// hex; for those `localeCompare` and byte order agree. A token the app
/// would never write (outside printable ASCII) may order differently from
/// Node: only the key order of the file differs, never what it says.
pub fn serialize_start_state(state: &StartState) -> Value {
    let mut tokens: Vec<&String> = state.ended_tokens.iter().collect();
    tokens.sort_by(|left, right| cmp_utf16(left, right));
    let mut started: Vec<&(String, f64)> = state.started.iter().collect();
    started.sort_by(|(left, _), (right, _)| locale_compare(left, right));
    let started: Map<String, Value> = started
        .into_iter()
        .map(|(id, at)| (id.clone(), number_value(*at)))
        .collect();
    json!({ "ended_tokens": tokens, "started": started })
}

/// A number that [`js_stringify`] writes as JS would: integral values as
/// integers.
fn number_value(at: f64) -> Value {
    if at.fract() == 0.0 && at.abs() < 9.0e15 {
        Value::from(at as i64)
    } else {
        serde_json::Number::from_f64(at).map_or(Value::Null, Value::Number)
    }
}

/// The per-device episode bookkeeping (HT-08): which devices take updates,
/// which may be started, and what each push's answer means for the next run.
/// Its state is the persisted [`StartState`].
///
/// * An update token is live unless this plugin ended its activity. A device
///   with a live update token receives updates, and its start guard resets.
/// * A device without a start registration keeps the pre-push-to-start
///   behavior: its update token keeps receiving pushes, ended or not.
/// * A device with a start registration and no live update token is a start
///   candidate while the inventory is non-empty and it has not started this
///   episode.
/// * An empty inventory ends the episode: every start guard resets.
/// * Ended tokens no device still registers are forgotten.
/// * A delivered `end` (APNs) ends its token; an update APNs no longer takes
///   (the user dismissed the activity) mid-episode counts as started, so no
///   push-to-start brings it back before the episode ends; a delivered start
///   marks its device started.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct ActivityEpisodeMachine {
    state: StartState,
}

/// One registration as the plan sees it.
#[derive(Debug, Clone, PartialEq)]
pub struct DeviceView {
    pub id: Option<String>,
    pub update_token: Option<String>,
    pub has_start: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub enum EpisodeEvent {
    /// One run's devices, in registration order, and whether the eligible
    /// inventory is empty.
    Plan {
        devices: Vec<DeviceView>,
        empty: bool,
    },
    /// The relay's answer to an update or end push to `token`: `delivered`,
    /// or not taken (gone). `fcm`: an FCM entry, which has no activity token.
    UpdateAnswered {
        id: Option<String>,
        token: String,
        fcm: bool,
        ending: bool,
        delivered: bool,
        at_ms: i64,
    },
    /// A push-to-start was delivered.
    StartDelivered { id: Option<String>, at_ms: i64 },
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum EpisodeEffect {
    /// The plan's device at this index takes updates.
    Update(usize),
    /// The plan's device at this index may be started.
    StartCandidate(usize),
}

impl ActivityEpisodeMachine {
    pub fn new(state: StartState) -> Self {
        Self { state }
    }
}

impl StateMachine for ActivityEpisodeMachine {
    type State = StartState;
    type Event = EpisodeEvent;
    type Effect = EpisodeEffect;

    fn state(&self) -> &StartState {
        &self.state
    }

    fn handle(&mut self, event: EpisodeEvent) -> Vec<EpisodeEffect> {
        let state = &mut self.state;
        match event {
            EpisodeEvent::Plan { devices, empty } => {
                state.ended_tokens.retain(|token| {
                    devices.iter().any(|device| {
                        device.update_token.as_deref() == Some(token.as_str()) && !token.is_empty()
                    })
                });
                if empty {
                    state.started.clear();
                }
                let mut updates = Vec::new();
                let mut starts = Vec::new();
                for (index, device) in devices.iter().enumerate() {
                    let update_live = device
                        .update_token
                        .as_deref()
                        .is_some_and(|token| !device.has_start || !state.is_ended(token));
                    if update_live {
                        updates.push(EpisodeEffect::Update(index));
                        if let Some(id) = &device.id {
                            state.forget_started(id);
                        }
                        continue;
                    }
                    if device.has_start
                        && !empty
                        && !device.id.as_deref().is_some_and(|id| state.has_started(id))
                    {
                        starts.push(EpisodeEffect::StartCandidate(index));
                    }
                }
                updates.extend(starts);
                updates
            }
            EpisodeEvent::UpdateAnswered {
                id,
                token,
                fcm,
                ending,
                delivered,
                at_ms,
            } => {
                if fcm {
                    return Vec::new();
                }
                if delivered && ending {
                    // That activity is over: its token can never take an
                    // update again.
                    state.mark_ended(&token);
                } else if !delivered
                    && !ending
                    && let Some(id) = id
                {
                    state.mark_started(&id, at_ms);
                }
                Vec::new()
            }
            EpisodeEvent::StartDelivered { id, at_ms } => {
                if let Some(id) = id {
                    state.mark_started(&id, at_ms);
                }
                Vec::new()
            }
        }
    }
}

/// A device the push decision looks at: the hook's view of one registration.
pub trait ActivityDevice {
    /// The alert token, the device's stable identity across activity tokens.
    fn id(&self) -> Option<&str>;
    /// The running activity's update token, when it can take updates.
    fn update_token(&self) -> Option<&str>;
    /// Whether the device registered a push-to-start token.
    fn has_start(&self) -> bool;
}

/// Devices split by what a push can do for them.
#[derive(Debug)]
pub struct DevicePlan<'a, D> {
    pub update_devices: Vec<&'a D>,
    pub start_candidates: Vec<&'a D>,
}

/// Split devices into update targets and start candidates through
/// `episodes` (see [`ActivityEpisodeMachine`]), which applies the episode
/// resets.
pub fn plan_devices<'a, D: ActivityDevice>(
    devices: &'a [D],
    episodes: &mut ActivityEpisodeMachine,
    empty: bool,
) -> DevicePlan<'a, D> {
    let views = devices
        .iter()
        .map(|device| DeviceView {
            id: device.id().map(str::to_string),
            update_token: device.update_token().map(str::to_string),
            has_start: device.has_start(),
        })
        .collect();
    let mut plan = DevicePlan {
        update_devices: Vec::new(),
        start_candidates: Vec::new(),
    };
    for effect in episodes.handle(EpisodeEvent::Plan {
        devices: views,
        empty,
    }) {
        match effect {
            EpisodeEffect::Update(index) => plan.update_devices.push(&devices[index]),
            EpisodeEffect::StartCandidate(index) => plan.start_candidates.push(&devices[index]),
        }
    }
    plan
}

fn start_state_path(state_dir: &Path) -> PathBuf {
    state_dir.join("activity").join("start-state.json")
}

/// The start state as read, with its serialized form: the hook writes only
/// when the serialization changed.
#[derive(Debug, Clone)]
pub struct StoredStartState {
    pub episodes: ActivityEpisodeMachine,
    pub stored: String,
}

/// Read `activity/start-state.json`; a missing or corrupt file is an empty state.
pub fn read_start_state(state_dir: &Path) -> StoredStartState {
    let state = parse_start_state(read_json(&start_state_path(state_dir)).as_ref());
    let stored = jsx::stringify(&serialize_start_state(&state));
    StoredStartState {
        episodes: ActivityEpisodeMachine::new(state),
        stored,
    }
}

/// Write the state back unless it serializes as it was read.
pub fn save_start_state(state_dir: &Path, read: &StoredStartState) -> io::Result<()> {
    let serialized = jsx::stringify(&serialize_start_state(read.episodes.state()));
    if serialized == read.stored {
        return Ok(());
    }
    std::fs::DirBuilder::new()
        .recursive(true)
        .create(state_dir.join("activity"))?;
    write_atomic(&start_state_path(state_dir), serialized.as_bytes(), 0o600)
}

#[cfg(test)]
mod tests {
    use std::fs;

    use super::*;
    use crate::test_support::TempDir;

    fn vectors() -> Value {
        let path = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("test-vectors/live-activity-content-v1.json");
        serde_json::from_slice(&fs::read(path).unwrap()).unwrap()
    }

    // push-to-start fields: match the shared vector the Swift suite decodes as AgentActivityAttributes
    #[test]
    fn start_fields_match_the_shared_vector() {
        let vectors = vectors();
        let vector = &vectors["pushToStart"];
        assert_eq!(
            start_fields(vector["hostId"].as_str().unwrap()),
            json!({
                "attributes_type": vector["attributesType"],
                "attributes": vector["attributes"],
                "alert": { "title": START_ALERT_TITLE, "body": START_ALERT_BODY },
            })
        );
        assert_eq!(
            jsx::stringify(&start_fields("X")),
            r#"{"attributes_type":"AgentActivityAttributes","attributes":{"hostID":"X"},"alert":{"title":"Agents active","body":"Agent status is live on your Lock Screen."}}"#
        );
    }

    // push-to-start fields: accept only canonical UUID host ids
    #[test]
    fn is_host_id_accepts_only_canonical_uuids() {
        let vectors = vectors();
        let host = vectors["pushToStart"]["hostId"].as_str().unwrap();
        assert!(is_host_id(&json!(host)));
        assert!(is_host_id(&json!(host.to_lowercase())));
        for bad in [
            json!(""),
            json!("mbp.local"),
            json!(format!("{host}0")),
            json!("6F9619FF8B86D011B42D00C04FC964FF"),
            json!(42),
            json!(format!("{host}\n")),
            json!(null),
        ] {
            assert!(!is_host_id(&bad), "{bad}");
        }
    }

    struct Device {
        id: Option<&'static str>,
        update: Option<&'static str>,
        start: bool,
    }

    impl ActivityDevice for Device {
        fn id(&self) -> Option<&str> {
            self.id
        }
        fn update_token(&self) -> Option<&str> {
            self.update
        }
        fn has_start(&self) -> bool {
            self.start
        }
    }

    fn state(raw: &str) -> StartState {
        parse_start_state(Some(&serde_json::from_str(raw).unwrap()))
    }

    fn ids(devices: &[&Device]) -> Vec<Option<&'static str>> {
        devices.iter().map(|device| device.id).collect()
    }

    // activity-hook push-to-start: starts once per episode while no update token is registered
    #[test]
    fn a_start_device_without_an_update_token_is_a_candidate_once_per_episode() {
        let devices = [Device {
            id: Some("a"),
            update: None,
            start: true,
        }];
        let mut state = ActivityEpisodeMachine::default();
        let plan = plan_devices(&devices, &mut state, false);
        assert_eq!(ids(&plan.start_candidates), [Some("a")]);
        assert!(plan.update_devices.is_empty());
        state.state.mark_started("a", 1000);
        let plan = plan_devices(&devices, &mut state, false);
        assert!(plan.start_candidates.is_empty());
        // The inventory emptied: the episode is over and the guard resets.
        let plan = plan_devices(&devices, &mut state, true);
        assert!(plan.start_candidates.is_empty());
        assert!(!state.state().has_started("a"));
        let plan = plan_devices(&devices, &mut state, false);
        assert_eq!(ids(&plan.start_candidates), [Some("a")]);
    }

    // activity-hook push-to-start: a live update token takes updates and resets the start guard
    #[test]
    fn a_live_update_token_takes_updates_and_resets_the_start_guard() {
        let devices = [Device {
            id: Some("a"),
            update: Some("u1"),
            start: true,
        }];
        let mut state = ActivityEpisodeMachine::default();
        state.state.mark_started("a", 1);
        let plan = plan_devices(&devices, &mut state, false);
        assert_eq!(ids(&plan.update_devices), [Some("a")]);
        assert!(plan.start_candidates.is_empty());
        assert!(!state.state().has_started("a"));
    }

    // activity-hook push-to-start: an ended token is not live for a start device but stays live without one
    #[test]
    fn an_ended_token_is_dead_only_for_a_device_that_can_start() {
        let devices = [
            Device {
                id: Some("a"),
                update: Some("u1"),
                start: true,
            },
            Device {
                id: Some("b"),
                update: Some("u2"),
                start: false,
            },
            Device {
                id: None,
                update: None,
                start: false,
            },
        ];
        let mut state = ActivityEpisodeMachine::default();
        state.state.mark_ended("u1");
        state.state.mark_ended("u2");
        state.state.mark_ended("gone");
        let plan = plan_devices(&devices, &mut state, false);
        assert_eq!(ids(&plan.update_devices), [Some("b")]);
        assert_eq!(ids(&plan.start_candidates), [Some("a")]);
        // Ended tokens no device still registers are forgotten.
        assert_eq!(
            state.state().ended_tokens().collect::<Vec<_>>(),
            ["u1", "u2"]
        );
    }

    // activity-hook push-to-start: an empty inventory starts nobody
    #[test]
    fn an_empty_inventory_starts_nobody() {
        let devices = [Device {
            id: Some("a"),
            update: None,
            start: true,
        }];
        let mut state = ActivityEpisodeMachine::default();
        let plan = plan_devices(&devices, &mut state, true);
        assert!(plan.start_candidates.is_empty());
    }

    // activity-hook push-to-start: the persisted file is lenient on read and sorted on write
    #[test]
    fn the_state_reads_leniently_and_serializes_sorted() {
        for raw in [
            json!(null),
            json!("x"),
            json!([1]),
            json!({ "ended_tokens": "x", "started": [1] }),
        ] {
            assert_eq!(
                parse_start_state(Some(&raw)),
                StartState::default(),
                "{raw}"
            );
        }
        let state = state(
            r#"{"ended_tokens":["b",1,"a","b"],"started":{"zz":5,"aa":1.5,"bad":"x","nul":null,"B":2}}"#,
        );
        assert_eq!(
            jsx::stringify(&serialize_start_state(&state)),
            r#"{"ended_tokens":["a","b"],"started":{"aa":1.5,"B":2,"zz":5}}"#
        );
    }

    #[test]
    fn started_ids_sort_like_locale_compare_for_hex_tokens() {
        let mut state = StartState::default();
        for id in ["f00d", "0abc", "beef", "0ab", "9"] {
            state.mark_started(id, 7);
        }
        assert_eq!(
            jsx::stringify(&serialize_start_state(&state)),
            // "9" is an array index: JS lists it first whatever the sort said.
            r#"{"ended_tokens":[],"started":{"9":7,"0ab":7,"0abc":7,"beef":7,"f00d":7}}"#
        );
    }

    // activity-hook push-to-start: start-state.json round-trips and a no-op is not rewritten
    #[test]
    fn the_start_state_file_round_trips_and_a_no_op_is_not_rewritten() {
        let dir = TempDir::new("start-state");
        let mut read = read_start_state(dir.path());
        assert_eq!(read.stored, r#"{"ended_tokens":[],"started":{}}"#);
        save_start_state(dir.path(), &read).unwrap();
        assert!(!dir.path().join("activity").exists());

        read.episodes.state.mark_ended("tok");
        read.episodes.state.mark_started("dev", 1760000000000);
        save_start_state(dir.path(), &read).unwrap();
        let path = dir.path().join("activity/start-state.json");
        assert_eq!(
            fs::read_to_string(&path).unwrap(),
            r#"{"ended_tokens":["tok"],"started":{"dev":1760000000000}}"#
        );
        let again = read_start_state(dir.path());
        assert_eq!(again.episodes, read.episodes);
        assert_eq!(again.stored, fs::read_to_string(&path).unwrap());
    }

    // ActivityEpisodeMachine: what each push's answer leaves for the next run.

    fn answered(fcm: bool, ending: bool, delivered: bool) -> EpisodeEvent {
        EpisodeEvent::UpdateAnswered {
            id: Some("dev".into()),
            token: "tok".into(),
            fcm,
            ending,
            delivered,
            at_ms: 42,
        }
    }

    #[test]
    fn a_delivered_end_ends_its_token_and_a_delivered_update_changes_nothing() {
        let mut episodes = ActivityEpisodeMachine::default();
        assert_eq!(episodes.handle(answered(false, false, true)), []);
        assert_eq!(episodes.state(), &StartState::default());
        assert_eq!(episodes.handle(answered(false, true, true)), []);
        assert!(episodes.state().is_ended("tok"));
        assert!(!episodes.state().has_started("dev"));
    }

    #[test]
    fn an_update_apns_no_longer_takes_mid_episode_counts_as_started() {
        let mut episodes = ActivityEpisodeMachine::default();
        let _ = episodes.handle(answered(false, false, false));
        assert!(episodes.state().has_started("dev"));
        assert!(!episodes.state().is_ended("tok"));
        // At the episode's end it does not.
        let mut episodes = ActivityEpisodeMachine::default();
        let _ = episodes.handle(answered(false, true, false));
        assert_eq!(episodes.state(), &StartState::default());
    }

    #[test]
    fn an_fcm_answer_never_touches_the_episode() {
        for (ending, delivered) in [(true, true), (false, false)] {
            let mut episodes = ActivityEpisodeMachine::default();
            let _ = episodes.handle(answered(true, ending, delivered));
            assert_eq!(episodes.state(), &StartState::default());
        }
    }

    #[test]
    fn a_delivered_start_marks_its_device_and_one_without_an_id_nothing() {
        let mut episodes = ActivityEpisodeMachine::default();
        let _ = episodes.handle(EpisodeEvent::StartDelivered {
            id: Some("dev".into()),
            at_ms: 7,
        });
        assert!(episodes.state().has_started("dev"));
        let mut episodes = ActivityEpisodeMachine::default();
        let _ = episodes.handle(EpisodeEvent::StartDelivered { id: None, at_ms: 7 });
        assert_eq!(episodes.state(), &StartState::default());
    }

    #[test]
    fn the_plan_lists_updates_then_start_candidates_by_index() {
        let view = |id: &str, update: Option<&str>, start: bool| DeviceView {
            id: Some(id.into()),
            update_token: update.map(str::to_string),
            has_start: start,
        };
        let mut episodes = ActivityEpisodeMachine::default();
        let effects = episodes.handle(EpisodeEvent::Plan {
            devices: vec![
                view("a", None, true),
                view("b", Some("u"), false),
                view("c", None, false),
            ],
            empty: false,
        });
        assert_eq!(
            effects,
            [EpisodeEffect::Update(1), EpisodeEffect::StartCandidate(0)]
        );
    }
}
