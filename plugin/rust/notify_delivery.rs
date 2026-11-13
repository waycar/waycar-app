//! One status change through the notification flow, as a machine
//! (docs/design/state-machines.md, HT-01). The owner,
//! [`crate::notify_core::run_notification`], reads the dedupe state and the
//! registration file, holds, re-checks the pane through its backend, stores
//! the summary, seals, claims and posts; this machine decides, from each
//! answer, what comes next.
//!
//! * Only a status that still holds after the hold notifies (or, for a
//!   status that notifies nobody, re-arms the pane); an agent gone by the
//!   re-check re-arms it too.
//! * A Chat Mode Done defers the summary to the reply: the summary is made
//!   only when no reply could be read, with what is left of its budget, and
//!   the status is re-checked once more.
//! * The push is deduped by the per-pane claim, re-read after the hold, and
//!   claimed atomically before any POST. A delivery that reached no device
//!   releases only its own claim (the token the claim effect returned).

use crate::state_machine::StateMachine;

#[derive(Debug)]
pub struct NotificationDeliveryMachine {
    state: DeliveryState,
    status: String,
    agent_kind: Option<String>,
    /// The status pushes at all (Blocked, Done).
    notify_worthy: bool,
    push_worthy: bool,
    summary_worthy: bool,
    /// The pane's Chat Marker applies: the reply replaces the summary.
    chat: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DeliveryState {
    Deciding,
    ReadingMarker,
    Holding,
    /// `second`: the re-check after a deferred summary.
    Rechecking {
        second: bool,
    },
    Replying,
    Resummarizing,
    /// The dedupe state and the devices are re-read after the hold.
    CheckingDedupe,
    Sealing,
    Claiming,
    Posting {
        claim: String,
    },
    Finished(DeliveryEnd),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeliveryEnd {
    /// Nothing to push, store or re-arm.
    Skipped,
    /// The agent was gone by a re-check: the pane re-armed.
    Gone,
    /// The status moved on during the hold; a newer event owns it.
    MovedOn,
    /// A confirmed departure re-armed the pane.
    Rearmed,
    /// The summary was stored; there was nothing to push.
    Stored,
    /// Another notifier pushed this status already.
    Deduped,
    NoDevices,
    Delivered,
    /// No device took the push; its claim was released.
    Undelivered,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DeliveryEvent {
    /// The dedupe state, whether a device takes this status, and whether
    /// summaries are on.
    Begin {
        last_notified: Option<String>,
        has_devices: bool,
        summary_enabled: bool,
    },
    /// The pane's Chat Marker: whether it is a Chat Mode one, and its kind.
    MarkerRead(Option<(bool, String)>),
    Held,
    /// The pane's status after the hold, or `None` when its agent is gone.
    Rechecked(Option<String>),
    Replied {
        has_reply: bool,
    },
    Resummarized,
    DedupeChecked {
        already_notified: bool,
        devices: usize,
    },
    Sealed,
    /// The claim's token, or `None` when another notifier claimed first.
    Claimed(Option<String>),
    Posted {
        delivered: bool,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DeliveryEffect {
    ReadChatMarker,
    /// Make the summary (when asked) within the hold, then sleep what is left
    /// of the debounce.
    Hold {
        summarize: bool,
    },
    Recheck,
    ClearLastNotified,
    /// The payload's reply; with `chat`, the Chat Mode reply instead.
    Reply {
        chat: bool,
    },
    /// The deferred summary, with what is left of its budget.
    Resummarize,
    PersistSummary,
    CheckDedupe,
    Seal,
    Claim,
    Post,
    /// Release this claim, only if the pane still holds it.
    ReleaseClaim(String),
    PruneTokens,
}

impl NotificationDeliveryMachine {
    /// One change to `status` (lower-cased); `notify_worthy` when the status
    /// pushes at all.
    pub fn new(status: &str, agent_kind: Option<&str>, notify_worthy: bool) -> Self {
        Self {
            state: DeliveryState::Deciding,
            status: status.to_string(),
            agent_kind: agent_kind.map(str::to_string),
            notify_worthy,
            push_worthy: false,
            summary_worthy: false,
            chat: false,
        }
    }

    fn finish(&mut self, end: DeliveryEnd) -> Vec<DeliveryEffect> {
        self.state = DeliveryState::Finished(end);
        Vec::new()
    }

    fn hold(&mut self) -> Vec<DeliveryEffect> {
        self.state = DeliveryState::Holding;
        vec![DeliveryEffect::Hold {
            summarize: self.summary_worthy && !self.chat,
        }]
    }

    /// The status held and the reply is known: store the summary, then
    /// check the dedupe state for the push.
    fn after_reply(&mut self) -> Vec<DeliveryEffect> {
        let mut effects = Vec::new();
        if self.summary_worthy {
            effects.push(DeliveryEffect::PersistSummary);
        }
        if !self.push_worthy {
            self.state = DeliveryState::Finished(DeliveryEnd::Stored);
            return effects;
        }
        self.state = DeliveryState::CheckingDedupe;
        effects.push(DeliveryEffect::CheckDedupe);
        effects
    }
}

impl StateMachine for NotificationDeliveryMachine {
    type State = DeliveryState;
    type Event = DeliveryEvent;
    type Effect = DeliveryEffect;

    fn state(&self) -> &DeliveryState {
        &self.state
    }

    fn handle(&mut self, event: DeliveryEvent) -> Vec<DeliveryEffect> {
        match (self.state.clone(), event) {
            (
                DeliveryState::Deciding,
                DeliveryEvent::Begin {
                    last_notified,
                    has_devices,
                    summary_enabled,
                },
            ) => {
                // The push and the Agent Summary are gated separately: a
                // deduped or device-less transition still refreshes the
                // summary the app's agent list shows.
                self.push_worthy = self.notify_worthy
                    && last_notified.as_deref() != Some(self.status.as_str())
                    && has_devices;
                self.summary_worthy = self.notify_worthy && summary_enabled;
                if self.notify_worthy && !self.push_worthy && !self.summary_worthy {
                    return self.finish(DeliveryEnd::Skipped);
                }
                if !self.notify_worthy && last_notified.is_none() {
                    return self.finish(DeliveryEnd::Skipped); // nothing to send or re-arm
                }
                if self.push_worthy && self.status == "done" {
                    self.state = DeliveryState::ReadingMarker;
                    return vec![DeliveryEffect::ReadChatMarker];
                }
                self.hold()
            }
            (DeliveryState::ReadingMarker, DeliveryEvent::MarkerRead(marker)) => {
                // A marker for another kind cannot apply, and a plain
                // launch's marker (`chat_mode: false`) is no Chat Mode pane.
                self.chat = marker.is_some_and(|(chat_mode, kind)| {
                    chat_mode && self.agent_kind.as_deref().is_none_or(|own| own == kind)
                });
                self.hold()
            }
            (DeliveryState::Holding, DeliveryEvent::Held) => {
                self.state = DeliveryState::Rechecking { second: false };
                vec![DeliveryEffect::Recheck]
            }
            (DeliveryState::Rechecking { second }, DeliveryEvent::Rechecked(status)) => {
                let Some(status) = status else {
                    // Agent gone; the dedupe state is stale.
                    self.state = DeliveryState::Finished(DeliveryEnd::Gone);
                    return vec![DeliveryEffect::ClearLastNotified];
                };
                if status != self.status {
                    return self.finish(DeliveryEnd::MovedOn);
                }
                if second {
                    return self.after_reply();
                }
                if !self.notify_worthy {
                    // A confirmed departure re-arms the pane.
                    self.state = DeliveryState::Finished(DeliveryEnd::Rearmed);
                    return vec![DeliveryEffect::ClearLastNotified];
                }
                self.state = DeliveryState::Replying;
                vec![DeliveryEffect::Reply { chat: self.chat }]
            }
            (DeliveryState::Replying, DeliveryEvent::Replied { has_reply }) => {
                if self.chat && !has_reply && self.summary_worthy {
                    self.state = DeliveryState::Resummarizing;
                    return vec![DeliveryEffect::Resummarize];
                }
                self.after_reply()
            }
            (DeliveryState::Resummarizing, DeliveryEvent::Resummarized) => {
                self.state = DeliveryState::Rechecking { second: true };
                vec![DeliveryEffect::Recheck]
            }
            (
                DeliveryState::CheckingDedupe,
                DeliveryEvent::DedupeChecked {
                    already_notified,
                    devices,
                },
            ) => {
                if already_notified {
                    return self.finish(DeliveryEnd::Deduped);
                }
                if devices == 0 {
                    return self.finish(DeliveryEnd::NoDevices);
                }
                self.state = DeliveryState::Sealing;
                vec![DeliveryEffect::Seal]
            }
            (DeliveryState::Sealing, DeliveryEvent::Sealed) => {
                self.state = DeliveryState::Claiming;
                vec![DeliveryEffect::Claim]
            }
            (DeliveryState::Claiming, DeliveryEvent::Claimed(claim)) => match claim {
                None => self.finish(DeliveryEnd::Deduped),
                Some(claim) => {
                    self.state = DeliveryState::Posting { claim };
                    vec![DeliveryEffect::Post]
                }
            },
            (DeliveryState::Posting { claim }, DeliveryEvent::Posted { delivered }) => {
                // Success leaves the claim alone, even if another notifier
                // re-armed the pane during the POST.
                if delivered {
                    self.state = DeliveryState::Finished(DeliveryEnd::Delivered);
                    return vec![DeliveryEffect::PruneTokens];
                }
                self.state = DeliveryState::Finished(DeliveryEnd::Undelivered);
                vec![
                    DeliveryEffect::ReleaseClaim(claim),
                    DeliveryEffect::PruneTokens,
                ]
            }
            (
                DeliveryState::Deciding
                | DeliveryState::ReadingMarker
                | DeliveryState::Holding
                | DeliveryState::Rechecking { .. }
                | DeliveryState::Replying
                | DeliveryState::Resummarizing
                | DeliveryState::CheckingDedupe
                | DeliveryState::Sealing
                | DeliveryState::Claiming
                | DeliveryState::Posting { .. }
                | DeliveryState::Finished(_),
                _,
            ) => Vec::new(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state_machine::testing::handle_all;

    fn begin(last: Option<&str>, devices: bool, summaries: bool) -> DeliveryEvent {
        DeliveryEvent::Begin {
            last_notified: last.map(str::to_string),
            has_devices: devices,
            summary_enabled: summaries,
        }
    }

    fn done() -> NotificationDeliveryMachine {
        NotificationDeliveryMachine::new("done", Some("claude"), true)
    }

    fn blocked() -> NotificationDeliveryMachine {
        NotificationDeliveryMachine::new("blocked", None, true)
    }

    #[test]
    fn nothing_to_push_store_or_rearm_is_skipped() {
        for (mut machine, event) in [
            (blocked(), begin(Some("blocked"), true, false)),
            (blocked(), begin(None, false, false)),
            (
                NotificationDeliveryMachine::new("working", None, false),
                begin(None, true, true),
            ),
        ] {
            assert_eq!(machine.handle(event), []);
            assert_eq!(
                machine.state(),
                &DeliveryState::Finished(DeliveryEnd::Skipped)
            );
        }
    }

    #[test]
    fn a_done_push_reads_the_chat_marker_first_and_a_chat_marker_defers_the_summary() {
        let mut machine = done();
        assert_eq!(
            machine.handle(begin(None, true, true)),
            [DeliveryEffect::ReadChatMarker]
        );
        assert_eq!(
            machine.handle(DeliveryEvent::MarkerRead(Some((true, "claude".into())))),
            [DeliveryEffect::Hold { summarize: false }]
        );
        for marker in [
            None,
            Some((false, "claude".into())),
            Some((true, "codex".into())),
        ] {
            let mut machine = done();
            let _ = machine.handle(begin(None, true, true));
            assert_eq!(
                machine.handle(DeliveryEvent::MarkerRead(marker.clone())),
                [DeliveryEffect::Hold { summarize: true }],
                "{marker:?}"
            );
        }
    }

    #[test]
    fn a_summary_only_change_holds_and_stores_without_a_push() {
        let mut machine = blocked();
        let effects = handle_all(
            &mut machine,
            [
                begin(Some("blocked"), true, true),
                DeliveryEvent::Held,
                DeliveryEvent::Rechecked(Some("blocked".into())),
                DeliveryEvent::Replied { has_reply: false },
            ],
        );
        assert_eq!(
            effects,
            [
                DeliveryEffect::Hold { summarize: true },
                DeliveryEffect::Recheck,
                DeliveryEffect::Reply { chat: false },
                DeliveryEffect::PersistSummary,
            ]
        );
        assert_eq!(
            machine.state(),
            &DeliveryState::Finished(DeliveryEnd::Stored)
        );
    }

    #[test]
    fn the_recheck_ends_on_a_gone_agent_or_a_moved_status_and_rearms_a_departure() {
        let mut machine = blocked();
        let _ = handle_all(
            &mut machine,
            [begin(None, true, false), DeliveryEvent::Held],
        );
        assert_eq!(
            machine.handle(DeliveryEvent::Rechecked(None)),
            [DeliveryEffect::ClearLastNotified]
        );
        assert_eq!(machine.state(), &DeliveryState::Finished(DeliveryEnd::Gone));
        let mut machine = blocked();
        let _ = handle_all(
            &mut machine,
            [begin(None, true, false), DeliveryEvent::Held],
        );
        assert_eq!(
            machine.handle(DeliveryEvent::Rechecked(Some("working".into()))),
            []
        );
        assert_eq!(
            machine.state(),
            &DeliveryState::Finished(DeliveryEnd::MovedOn)
        );
        let mut machine = NotificationDeliveryMachine::new("working", None, false);
        let effects = handle_all(
            &mut machine,
            [
                begin(Some("done"), false, false),
                DeliveryEvent::Held,
                DeliveryEvent::Rechecked(Some("working".into())),
            ],
        );
        assert_eq!(
            effects,
            [
                DeliveryEffect::Hold { summarize: false },
                DeliveryEffect::Recheck,
                DeliveryEffect::ClearLastNotified,
            ]
        );
        assert_eq!(
            machine.state(),
            &DeliveryState::Finished(DeliveryEnd::Rearmed)
        );
    }

    #[test]
    fn a_chat_done_without_a_reply_summarizes_late_and_rechecks_once_more() {
        let mut machine = done();
        let effects = handle_all(
            &mut machine,
            [
                begin(None, true, true),
                DeliveryEvent::MarkerRead(Some((true, "claude".into()))),
                DeliveryEvent::Held,
                DeliveryEvent::Rechecked(Some("done".into())),
                DeliveryEvent::Replied { has_reply: false },
                DeliveryEvent::Resummarized,
                DeliveryEvent::Rechecked(Some("done".into())),
            ],
        );
        assert_eq!(
            effects,
            [
                DeliveryEffect::ReadChatMarker,
                DeliveryEffect::Hold { summarize: false },
                DeliveryEffect::Recheck,
                DeliveryEffect::Reply { chat: true },
                DeliveryEffect::Resummarize,
                DeliveryEffect::Recheck,
                DeliveryEffect::PersistSummary,
                DeliveryEffect::CheckDedupe,
            ]
        );
        // The second re-check found the agent gone.
        let mut machine = done();
        let _ = handle_all(
            &mut machine,
            [
                begin(None, true, true),
                DeliveryEvent::MarkerRead(Some((true, "claude".into()))),
                DeliveryEvent::Held,
                DeliveryEvent::Rechecked(Some("done".into())),
                DeliveryEvent::Replied { has_reply: false },
                DeliveryEvent::Resummarized,
            ],
        );
        assert_eq!(
            machine.handle(DeliveryEvent::Rechecked(None)),
            [DeliveryEffect::ClearLastNotified]
        );
    }

    #[test]
    fn a_chat_reply_skips_the_late_summary() {
        let mut machine = done();
        let _ = handle_all(
            &mut machine,
            [
                begin(None, true, true),
                DeliveryEvent::MarkerRead(Some((true, "claude".into()))),
                DeliveryEvent::Held,
                DeliveryEvent::Rechecked(Some("done".into())),
            ],
        );
        assert_eq!(
            machine.handle(DeliveryEvent::Replied { has_reply: true }),
            [DeliveryEffect::PersistSummary, DeliveryEffect::CheckDedupe]
        );
    }

    fn checking() -> NotificationDeliveryMachine {
        let mut machine = blocked();
        let _ = handle_all(
            &mut machine,
            [
                begin(None, true, false),
                DeliveryEvent::Held,
                DeliveryEvent::Rechecked(Some("blocked".into())),
                DeliveryEvent::Replied { has_reply: false },
            ],
        );
        assert_eq!(machine.state(), &DeliveryState::CheckingDedupe);
        machine
    }

    #[test]
    fn after_the_hold_a_notified_status_or_no_device_ends_the_push() {
        let mut machine = checking();
        let _ = machine.handle(DeliveryEvent::DedupeChecked {
            already_notified: true,
            devices: 1,
        });
        assert_eq!(
            machine.state(),
            &DeliveryState::Finished(DeliveryEnd::Deduped)
        );
        let mut machine = checking();
        let _ = machine.handle(DeliveryEvent::DedupeChecked {
            already_notified: false,
            devices: 0,
        });
        assert_eq!(
            machine.state(),
            &DeliveryState::Finished(DeliveryEnd::NoDevices)
        );
    }

    #[test]
    fn a_seal_comes_before_the_claim_and_a_lost_claim_posts_nothing() {
        let mut machine = checking();
        let effects = handle_all(
            &mut machine,
            [
                DeliveryEvent::DedupeChecked {
                    already_notified: false,
                    devices: 2,
                },
                DeliveryEvent::Sealed,
                DeliveryEvent::Claimed(None),
            ],
        );
        assert_eq!(effects, [DeliveryEffect::Seal, DeliveryEffect::Claim]);
        assert_eq!(
            machine.state(),
            &DeliveryState::Finished(DeliveryEnd::Deduped)
        );
    }

    #[test]
    fn a_delivered_post_keeps_its_claim_an_undelivered_one_releases_only_its_own() {
        for (delivered, expected) in [
            (true, vec![DeliveryEffect::PruneTokens]),
            (
                false,
                vec![
                    DeliveryEffect::ReleaseClaim("c1".into()),
                    DeliveryEffect::PruneTokens,
                ],
            ),
        ] {
            let mut machine = checking();
            let _ = handle_all(
                &mut machine,
                [
                    DeliveryEvent::DedupeChecked {
                        already_notified: false,
                        devices: 1,
                    },
                    DeliveryEvent::Sealed,
                ],
            );
            assert_eq!(
                machine.handle(DeliveryEvent::Claimed(Some("c1".into()))),
                [DeliveryEffect::Post]
            );
            assert_eq!(
                machine.handle(DeliveryEvent::Posted { delivered }),
                expected
            );
        }
    }

    #[test]
    fn events_a_state_never_asked_for_are_ignored() {
        let mut machine = blocked();
        assert_eq!(machine.handle(DeliveryEvent::Held), []);
        assert_eq!(
            machine.handle(DeliveryEvent::Posted { delivered: true }),
            []
        );
        assert_eq!(machine.state(), &DeliveryState::Deciding);
        let mut machine = checking();
        assert_eq!(machine.handle(DeliveryEvent::Claimed(Some("x".into()))), []);
        assert_eq!(machine.state(), &DeliveryState::CheckingDedupe);
    }
}
