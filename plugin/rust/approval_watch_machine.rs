//! One approval watch's lifecycle on its pane (docs/design/state-machines.md,
//! HT-05). The owner, [`crate::approval_watch::watch_approval`], reads the
//! pane, sleeps, makes the compare-and-set tmux writes and notifies; this
//! machine decides, from each answer, what comes next. The steps are the
//! ones its module documentation describes: claim the pane, wait for the
//! dialog while the pane works with an unchanged seq, hold Blocked while the
//! dialog shows, write Working when it goes, and let go unless a
//! `PreToolUse` poked the pane since.

use crate::approval_watch::{DIALOG_WAIT_MS, HELD_POLL_MS, POLL_MS, is_plain};
use crate::state_machine::StateMachine;

/// What one read of the pane says, the screen already judged by the kind's
/// rule.
#[derive(Debug, Clone, PartialEq)]
pub struct PaneView {
    pub status: Option<String>,
    pub seq: Option<String>,
    pub watch: String,
    pub poke: String,
    pub shown: bool,
}

#[derive(Debug)]
pub struct ApprovalWatchMachine {
    state: WatchState,
    token: String,
}

#[derive(Debug, Clone, PartialEq)]
pub enum WatchState {
    /// Waiting for the first read.
    Starting,
    /// The claim was sent; `pane` is the first read.
    Claiming {
        pane: PaneView,
    },
    /// Waiting for the dialog.
    Waiting(Wait),
    /// The dialog showed; Blocked is being written.
    WritingBlocked(Wait),
    /// Blocked is this watch's write `blocked_seq`; waiting for the dialog to go.
    Held {
        wait: Wait,
        blocked_seq: String,
    },
    /// The dialog went; Working is being written.
    WritingWorking {
        wait: Wait,
        blocked_seq: String,
    },
    /// Letting go of the pane, unless it was poked since the wait's poke.
    Leaving(Wait),
    Finished,
}

/// The current wait: for the dialog after the `PreToolUse` that made
/// `poke`, from the status written at `seq`, until `deadline` (epoch ms).
/// It outlives a hold: letting go after one still compares this poke.
#[derive(Debug, Clone, PartialEq)]
pub struct Wait {
    pub poke: String,
    pub seq: Option<String>,
    pub deadline: u64,
}

#[derive(Debug, Clone, PartialEq)]
pub enum WatchEvent {
    /// The first read (`None`: the pane is gone) and whether another live
    /// watch holds its token.
    Started {
        pane: Option<PaneView>,
        other_holder: bool,
    },
    /// The watch option read back after the claim, and the time.
    Claimed { watch: Option<String>, now: u64 },
    /// A read (`None`: the pane is gone) and the time.
    Read { pane: Option<PaneView>, now: u64 },
    /// Blocked's new seq, or `None` when the pane moved on.
    BlockedWritten(Option<String>),
    /// Whether Working landed.
    WorkingWritten(bool),
    /// The watch option read back after letting go (`None`: tmux refused).
    Left(Option<String>),
}

#[derive(Debug, Clone, PartialEq)]
pub enum WatchEffect {
    /// Set the watch option to the token, only while it is `only_if` (`None`:
    /// whatever it is), then read it back.
    Claim {
        only_if: Option<String>,
    },
    /// Read the pane, after sleeping `after_ms` when there is one.
    Read {
        after_ms: Option<u64>,
    },
    /// Write `status` while the seq is still `previous_seq` (and, with
    /// `token`, this watch still holds the pane).
    WriteStatus {
        status: &'static str,
        previous_seq: Option<String>,
        token: bool,
    },
    Notify(&'static str),
    /// Unset the watch option while it is this watch's token and the poke is
    /// still `poke`, then read it back.
    Leave {
        poke: String,
    },
}

impl ApprovalWatchMachine {
    pub fn new(token: impl Into<String>) -> Self {
        Self {
            state: WatchState::Starting,
            token: token.into(),
        }
    }

    pub fn token(&self) -> &str {
        &self.token
    }

    /// One pass of the dialog wait over a read.
    fn wait(&mut self, pane: Option<PaneView>, now: u64, mut wait: Wait) -> Vec<WatchEffect> {
        let Some(pane) = pane.filter(|pane| pane.watch == self.token) else {
            self.state = WatchState::Finished;
            return Vec::new();
        };
        if pane.poke != wait.poke {
            // Another PreToolUse: a new tool, from the status it saw.
            wait = Wait {
                poke: pane.poke.clone(),
                seq: pane.seq.clone(),
                deadline: now + DIALOG_WAIT_MS,
            };
        }
        if pane.status.as_deref() != Some("working") || pane.seq != wait.seq || now >= wait.deadline
        {
            return self.leave(wait);
        }
        if pane.shown {
            let previous_seq = wait.seq.clone();
            self.state = WatchState::WritingBlocked(wait);
            return vec![WatchEffect::WriteStatus {
                status: "blocked",
                previous_seq,
                token: true,
            }];
        }
        self.state = WatchState::Waiting(wait);
        vec![WatchEffect::Read {
            after_ms: Some(POLL_MS),
        }]
    }

    /// Let go, unless the poke cannot sit in a format (then end holding it).
    fn leave(&mut self, wait: Wait) -> Vec<WatchEffect> {
        if !is_plain(&wait.poke) {
            self.state = WatchState::Finished;
            return Vec::new();
        }
        let poke = wait.poke.clone();
        self.state = WatchState::Leaving(wait);
        vec![WatchEffect::Leave { poke }]
    }
}

impl StateMachine for ApprovalWatchMachine {
    type State = WatchState;
    type Event = WatchEvent;
    type Effect = WatchEffect;

    fn state(&self) -> &WatchState {
        &self.state
    }

    fn handle(&mut self, event: WatchEvent) -> Vec<WatchEffect> {
        let state = std::mem::replace(&mut self.state, WatchState::Finished);
        match (state, event) {
            (WatchState::Starting, WatchEvent::Started { pane, other_holder }) => {
                let Some(pane) = pane.filter(|_| !other_holder) else {
                    return Vec::new();
                };
                let only_if = is_plain(&pane.watch).then(|| pane.watch.clone());
                self.state = WatchState::Claiming { pane };
                vec![WatchEffect::Claim { only_if }]
            }
            (WatchState::Claiming { mut pane }, WatchEvent::Claimed { watch, now }) => {
                if watch.as_deref() != Some(self.token.as_str()) {
                    return Vec::new();
                }
                pane.watch = self.token.clone();
                let wait = Wait {
                    poke: pane.poke.clone(),
                    seq: pane.seq.clone(),
                    deadline: now + DIALOG_WAIT_MS,
                };
                self.wait(Some(pane), now, wait)
            }
            (WatchState::Waiting(wait), WatchEvent::Read { pane, now }) => {
                self.wait(pane, now, wait)
            }
            (WatchState::WritingBlocked(wait), WatchEvent::BlockedWritten(written)) => {
                match written {
                    Some(blocked_seq) => {
                        self.state = WatchState::Held { wait, blocked_seq };
                        vec![
                            WatchEffect::Notify("blocked"),
                            WatchEffect::Read {
                                after_ms: Some(HELD_POLL_MS),
                            },
                        ]
                    }
                    None => self.leave(wait),
                }
            }
            (WatchState::Held { wait, blocked_seq }, WatchEvent::Read { pane, now: _ }) => {
                let Some(pane) = pane.filter(|pane| pane.seq.as_deref() == Some(&blocked_seq))
                else {
                    return self.leave(wait);
                };
                if pane.shown {
                    self.state = WatchState::Held { wait, blocked_seq };
                    return vec![WatchEffect::Read {
                        after_ms: Some(HELD_POLL_MS),
                    }];
                }
                self.state = WatchState::WritingWorking {
                    wait,
                    blocked_seq: blocked_seq.clone(),
                };
                vec![WatchEffect::WriteStatus {
                    status: "working",
                    previous_seq: Some(blocked_seq),
                    token: false,
                }]
            }
            (WatchState::WritingWorking { wait, .. }, WatchEvent::WorkingWritten(written)) => {
                let mut effects = Vec::new();
                if written {
                    effects.push(WatchEffect::Notify("working"));
                }
                effects.extend(self.leave(wait));
                effects
            }
            (WatchState::Leaving(wait), WatchEvent::Left(watch)) => {
                if watch.as_deref() != Some(self.token.as_str()) {
                    return Vec::new();
                }
                // Poked as it let go: watch on, from a fresh read.
                self.state = WatchState::Waiting(wait);
                vec![WatchEffect::Read { after_ms: None }]
            }
            // Every other pairing is an event the state never asked for.
            (
                state @ (WatchState::Starting
                | WatchState::Claiming { .. }
                | WatchState::Waiting(_)
                | WatchState::WritingBlocked(_)
                | WatchState::Held { .. }
                | WatchState::WritingWorking { .. }
                | WatchState::Leaving(_)
                | WatchState::Finished),
                _,
            ) => {
                self.state = state;
                Vec::new()
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state_machine::testing::handle_all;

    const TOKEN: &str = "42-abcdef";

    fn view(status: &str, seq: &str, poke: &str, shown: bool) -> PaneView {
        PaneView {
            status: (!status.is_empty()).then(|| status.to_string()),
            seq: (!seq.is_empty()).then(|| seq.to_string()),
            watch: TOKEN.into(),
            poke: poke.into(),
            shown,
        }
    }

    fn read(pane: PaneView, now: u64) -> WatchEvent {
        WatchEvent::Read {
            pane: Some(pane),
            now,
        }
    }

    /// A machine that claimed the pane at `now = 0`, working at seq 1, poke p1.
    fn claimed(shown: bool) -> (ApprovalWatchMachine, Vec<WatchEffect>) {
        let mut watch = ApprovalWatchMachine::new(TOKEN);
        let mut first = view("working", "1", "p1", shown);
        first.watch = String::new();
        let effects = handle_all(
            &mut watch,
            [
                WatchEvent::Started {
                    pane: Some(first),
                    other_holder: false,
                },
                WatchEvent::Claimed {
                    watch: Some(TOKEN.into()),
                    now: 0,
                },
            ],
        );
        (watch, effects)
    }

    #[test]
    fn a_gone_pane_or_a_live_holder_ends_before_claiming() {
        let mut watch = ApprovalWatchMachine::new(TOKEN);
        let effects = watch.handle(WatchEvent::Started {
            pane: None,
            other_holder: false,
        });
        assert_eq!(effects, []);
        assert_eq!(watch.state(), &WatchState::Finished);
        let mut watch = ApprovalWatchMachine::new(TOKEN);
        let effects = watch.handle(WatchEvent::Started {
            pane: Some(view("working", "1", "", false)),
            other_holder: true,
        });
        assert_eq!(effects, []);
        assert_eq!(watch.state(), &WatchState::Finished);
    }

    #[test]
    fn the_claim_compares_a_plain_token_and_overwrites_an_odd_one() {
        for (old, only_if) in [("", Some("")), ("7-ab", Some("7-ab")), ("a b", None)] {
            let mut watch = ApprovalWatchMachine::new(TOKEN);
            let mut pane = view("working", "1", "", false);
            pane.watch = old.into();
            let effects = watch.handle(WatchEvent::Started {
                pane: Some(pane),
                other_holder: false,
            });
            assert_eq!(
                effects,
                [WatchEffect::Claim {
                    only_if: only_if.map(str::to_string)
                }]
            );
        }
    }

    #[test]
    fn a_lost_claim_ends_the_watch() {
        let mut watch = ApprovalWatchMachine::new(TOKEN);
        let _ = watch.handle(WatchEvent::Started {
            pane: Some(view("working", "1", "", false)),
            other_holder: false,
        });
        let effects = watch.handle(WatchEvent::Claimed {
            watch: Some("7-ab".into()),
            now: 0,
        });
        assert_eq!(effects, []);
        assert_eq!(watch.state(), &WatchState::Finished);
    }

    #[test]
    fn a_claim_judges_the_first_read_at_once() {
        let (watch, effects) = claimed(false);
        assert_eq!(
            effects,
            [
                WatchEffect::Claim {
                    only_if: Some(String::new())
                },
                WatchEffect::Read {
                    after_ms: Some(POLL_MS)
                }
            ]
        );
        assert_eq!(
            watch.state(),
            &WatchState::Waiting(Wait {
                poke: "p1".into(),
                seq: Some("1".into()),
                deadline: DIALOG_WAIT_MS
            })
        );
        let (_, effects) = claimed(true);
        assert_eq!(
            effects[1],
            WatchEffect::WriteStatus {
                status: "blocked",
                previous_seq: Some("1".into()),
                token: true
            }
        );
    }

    #[test]
    fn waiting_ends_on_another_status_another_seq_the_deadline_a_gone_pane_or_token() {
        for (event, leaves) in [
            (read(view("idle", "1", "p1", true), 10), true),
            (read(view("working", "2", "p1", true), 10), true),
            (read(view("working", "1", "p1", true), DIALOG_WAIT_MS), true),
            (
                WatchEvent::Read {
                    pane: None,
                    now: 10,
                },
                false,
            ),
            (
                read(
                    PaneView {
                        watch: "7-ab".into(),
                        ..view("working", "1", "p1", true)
                    },
                    10,
                ),
                false,
            ),
        ] {
            let (mut watch, _) = claimed(false);
            let effects = watch.handle(event.clone());
            if leaves {
                assert_eq!(
                    effects,
                    [WatchEffect::Leave { poke: "p1".into() }],
                    "{event:?}"
                );
            } else {
                assert_eq!(effects, [], "{event:?}");
                assert_eq!(watch.state(), &WatchState::Finished);
            }
        }
    }

    #[test]
    fn a_new_poke_restarts_the_wait_from_the_status_it_saw() {
        let (mut watch, _) = claimed(false);
        let effects = watch.handle(read(view("working", "5", "p2", false), 4_000));
        assert_eq!(
            effects,
            [WatchEffect::Read {
                after_ms: Some(POLL_MS)
            }]
        );
        assert_eq!(
            watch.state(),
            &WatchState::Waiting(Wait {
                poke: "p2".into(),
                seq: Some("5".into()),
                deadline: 4_000 + DIALOG_WAIT_MS
            })
        );
    }

    #[test]
    fn blocked_written_holds_and_a_lost_one_lets_go() {
        let (mut watch, _) = claimed(true);
        assert_eq!(
            watch.handle(WatchEvent::BlockedWritten(Some("9".into()))),
            [
                WatchEffect::Notify("blocked"),
                WatchEffect::Read {
                    after_ms: Some(HELD_POLL_MS)
                }
            ]
        );
        assert_eq!(
            watch.state(),
            &WatchState::Held {
                wait: Wait {
                    poke: "p1".into(),
                    seq: Some("1".into()),
                    deadline: DIALOG_WAIT_MS
                },
                blocked_seq: "9".into()
            }
        );
        let (mut watch, _) = claimed(true);
        assert_eq!(
            watch.handle(WatchEvent::BlockedWritten(None)),
            [WatchEffect::Leave { poke: "p1".into() }]
        );
    }

    #[test]
    fn held_polls_while_shown_writes_working_when_gone_and_lets_go_on_another_write() {
        let (mut watch, _) = claimed(true);
        let _ = watch.handle(WatchEvent::BlockedWritten(Some("9".into())));
        assert_eq!(
            watch.handle(read(view("blocked", "9", "p1", true), 0)),
            [WatchEffect::Read {
                after_ms: Some(HELD_POLL_MS)
            }]
        );
        assert_eq!(
            watch.handle(read(view("blocked", "9", "p1", false), 0)),
            [WatchEffect::WriteStatus {
                status: "working",
                previous_seq: Some("9".into()),
                token: false
            }]
        );
        assert_eq!(
            watch.handle(WatchEvent::WorkingWritten(true)),
            [
                WatchEffect::Notify("working"),
                WatchEffect::Leave { poke: "p1".into() }
            ]
        );
        for event in [
            read(view("done", "10", "p1", true), 0),
            WatchEvent::Read { pane: None, now: 0 },
        ] {
            let (mut watch, _) = claimed(true);
            let _ = watch.handle(WatchEvent::BlockedWritten(Some("9".into())));
            assert_eq!(
                watch.handle(event),
                [WatchEffect::Leave { poke: "p1".into() }]
            );
        }
    }

    #[test]
    fn a_lost_working_write_lets_go_without_a_notification() {
        let (mut watch, _) = claimed(true);
        let _ = handle_all(
            &mut watch,
            [
                WatchEvent::BlockedWritten(Some("9".into())),
                read(view("blocked", "9", "p1", false), 0),
            ],
        );
        assert_eq!(
            watch.handle(WatchEvent::WorkingWritten(false)),
            [WatchEffect::Leave { poke: "p1".into() }]
        );
    }

    #[test]
    fn letting_go_ends_unless_the_token_stayed_and_an_odd_poke_never_lets_go() {
        let (mut watch, _) = claimed(false);
        let _ = watch.handle(read(view("idle", "1", "p1", false), 0));
        assert_eq!(watch.handle(WatchEvent::Left(Some(String::new()))), []);
        assert_eq!(watch.state(), &WatchState::Finished);

        let (mut watch, _) = claimed(false);
        let _ = watch.handle(read(view("idle", "1", "p1", false), 0));
        assert_eq!(
            watch.handle(WatchEvent::Left(Some(TOKEN.into()))),
            [WatchEffect::Read { after_ms: None }]
        );
        assert!(matches!(watch.state(), WatchState::Waiting(_)));

        let (mut watch, _) = claimed(false);
        assert_eq!(watch.handle(read(view("idle", "1", "a b", false), 0)), []);
        assert_eq!(watch.state(), &WatchState::Finished);
    }

    #[test]
    fn events_a_state_never_asked_for_are_ignored() {
        let mut watch = ApprovalWatchMachine::new(TOKEN);
        assert_eq!(watch.handle(WatchEvent::Left(None)), []);
        assert_eq!(watch.state(), &WatchState::Starting);
        let (mut watch, _) = claimed(false);
        let waiting = watch.state().clone();
        assert_eq!(watch.handle(WatchEvent::WorkingWritten(true)), []);
        assert_eq!(watch.handle(WatchEvent::BlockedWritten(None)), []);
        assert_eq!(watch.state(), &waiting);
    }
}
