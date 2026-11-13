//! What one `hook-session` event does to its tmux pane, as two machines
//! (docs/design/state-machines.md): [`SessionReleaseMachine`] for a release
//! (HT-03) and [`PaneStatusWriteMachine`] for options and a status (HT-04).
//! Each hook run reads the pane once, writes once and maybe notifies; the
//! owner, `hook_session::apply_to_pane`, builds the tmux argv for each
//! effect and feeds the answer back.

use crate::hook_session::{is_conditional, next_seq, next_status};
use crate::state_machine::StateMachine;

/// Whether `value` reads as itself inside a tmux format's `#{==:…,value}`:
/// no `#`, `,` or `}` (format syntax), no control character and no line
/// terminator.
pub fn format_literal(value: &str) -> bool {
    !value.contains(['#', ',', '}'])
        && !value.chars().any(char::is_control)
        && !value.contains(['\u{2028}', '\u{2029}'])
}

/// A release of the pane's session (`SessionEnd`): unset every `@waycar_*`
/// option, but only for the pane's own session or a pane that records none
/// (Copilot fires a stray SessionEnd for another session on resume), and
/// only while that still holds inside the tmux server (B-34). A pane that had
/// a status is notified once the unset happened.
#[derive(Debug, Default)]
pub struct SessionReleaseMachine {
    state: ReleaseState,
}

#[derive(Debug, Clone, PartialEq, Default)]
pub enum ReleaseState {
    /// Waiting for the hook's read of the pane.
    #[default]
    Reading,
    /// The unset was sent; `guarded`: only while the pane records the
    /// released session or none. `notify`: the pane had a status.
    Unsetting {
        guarded: bool,
        notify: bool,
    },
    Released,
    /// Another session holds the pane (at the read, or by the unset).
    Kept,
    /// tmux refused (the pane is gone).
    Failed,
}

#[derive(Debug, Clone, PartialEq)]
pub enum ReleaseEvent {
    /// The pane as read: its session and status (`None`: unset), the id
    /// the event releases (`None`: any), and whether the pane id can sit in
    /// a tmux command string.
    Read {
        held: Option<String>,
        status: Option<String>,
        wanted: Option<String>,
        pane_is_target: bool,
    },
    /// The unset's tmux output (`None`: tmux failed); a guarded one ends
    /// with the pane's `@waycar_session` read back.
    Answered(Option<String>),
}

#[derive(Debug, Clone, PartialEq)]
pub enum ReleaseEffect {
    /// Unset every option, with `only_for`: only while the pane records that
    /// session or none, then read `@waycar_session` back.
    Unset {
        only_for: Option<String>,
    },
    NotifyRelease,
}

impl StateMachine for SessionReleaseMachine {
    type State = ReleaseState;
    type Event = ReleaseEvent;
    type Effect = ReleaseEffect;

    fn state(&self) -> &ReleaseState {
        &self.state
    }

    fn handle(&mut self, event: ReleaseEvent) -> Vec<ReleaseEffect> {
        match (&self.state, event) {
            (
                ReleaseState::Reading,
                ReleaseEvent::Read {
                    held,
                    status,
                    wanted,
                    pane_is_target,
                },
            ) => {
                if let (Some(wanted), Some(held)) =
                    (&wanted, held.as_ref().filter(|held| !held.is_empty()))
                    && wanted != held
                {
                    self.state = ReleaseState::Kept;
                    return Vec::new();
                }
                let only_for = wanted.filter(|wanted| format_literal(wanted) && pane_is_target);
                self.state = ReleaseState::Unsetting {
                    guarded: only_for.is_some(),
                    notify: status.is_some_and(|status| !status.is_empty()),
                };
                vec![ReleaseEffect::Unset { only_for }]
            }
            (&ReleaseState::Unsetting { guarded, notify }, ReleaseEvent::Answered(out)) => {
                let Some(out) = out else {
                    self.state = ReleaseState::Failed;
                    return Vec::new();
                };
                if guarded && !out.trim_end_matches('\n').is_empty() {
                    self.state = ReleaseState::Kept;
                    return Vec::new();
                }
                self.state = ReleaseState::Released;
                if notify {
                    vec![ReleaseEffect::NotifyRelease]
                } else {
                    Vec::new()
                }
            }
            (ReleaseState::Reading, ReleaseEvent::Answered(_)) => Vec::new(),
            (ReleaseState::Unsetting { .. }, ReleaseEvent::Read { .. }) => Vec::new(),
            (ReleaseState::Released | ReleaseState::Kept | ReleaseState::Failed, _) => Vec::new(),
        }
    }
}

/// One event's options and status onto the pane: the payload's options
/// always, a status (`working`, or a conditional `working-if-active`, see
/// [`next_status`]) only when it moves the pane, with `@waycar_agent` when
/// the options lack it and a raised `@waycar_seq`. A conditional status is
/// a compare-and-swap on the pane's seq (B-35): written only while the seq
/// is still the one read; when another write moved it first, the pane is
/// read again, the status decided again from the fresh status, and the
/// write retried, [`STATUS_WRITE_ATTEMPTS`] times in all. The new status is
/// notified once written.
#[derive(Debug, Default)]
pub struct PaneStatusWriteMachine {
    state: StatusWriteState,
    want: Option<&'static str>,
    options_have_agent: bool,
    pane_is_target: bool,
}

/// How many guarded writes one hook makes before it gives up.
pub const STATUS_WRITE_ATTEMPTS: u8 = 3;

#[derive(Debug, Clone, PartialEq, Default)]
pub enum StatusWriteState {
    /// Waiting for the hook's read of the pane.
    #[default]
    Reading,
    /// The write was sent. `status`: the status and seq it writes, if any.
    /// `attempt`: 1 for the first write.
    Writing {
        status: Option<(&'static str, String)>,
        guarded: bool,
        attempt: u8,
    },
    /// A guarded write was refused; the pane is being read again.
    Rereading { attempt: u8 },
    /// Written; `status`: the status it moved the pane to.
    Written { status: Option<&'static str> },
    /// Nothing to write.
    Unchanged,
    /// The pane's seq moved on before every guarded attempt landed.
    Superseded,
    /// tmux refused (the pane is gone).
    Failed,
}

#[derive(Debug, Clone, PartialEq)]
pub enum StatusWriteEvent {
    /// The pane as read and the event's own part: its status or conditional
    /// status, whether it has options and whether they hold
    /// `@waycar_agent`, whether the pane id can sit in a tmux command
    /// string, and the clock for the new seq.
    Read {
        want: Option<&'static str>,
        status: Option<String>,
        seq: Option<String>,
        options: bool,
        options_have_agent: bool,
        pane_is_target: bool,
        now_ns: u128,
    },
    /// The write's tmux output (`None`: tmux failed); a guarded one ends
    /// with the pane's `@waycar_seq` read back.
    Answered(Option<String>),
    /// The pane read again after a refused guarded write (`None`: gone).
    Reread(Option<PaneRead>),
}

/// A fresh read of the pane's status and seq, with the clock.
#[derive(Debug, Clone, PartialEq)]
pub struct PaneRead {
    pub status: Option<String>,
    pub seq: Option<String>,
    pub now_ns: u128,
}

/// The status part of a pane write.
#[derive(Debug, Clone, PartialEq)]
pub struct StatusWrite {
    /// Set `@waycar_agent` too (the options lack it).
    pub agent: bool,
    pub status: &'static str,
    pub seq: String,
    /// Only while `@waycar_seq` is this (`""`: unset), then read it back.
    pub only_if_seq: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum StatusWriteEffect {
    /// Write the event's options (with `options`), then `status` when there
    /// is one. A retry writes the status alone: the options landed already.
    Write {
        options: bool,
        status: Option<StatusWrite>,
    },
    /// Read the pane's status and seq again.
    Reread,
    Notify(&'static str),
}

impl PaneStatusWriteMachine {
    /// Decide the write from the pane's status and seq: attempt 1 writes the
    /// options too.
    fn decide(
        &mut self,
        status: Option<String>,
        seq: Option<String>,
        options: bool,
        now_ns: u128,
        attempt: u8,
    ) -> Vec<StatusWriteEffect> {
        let want = self.want;
        let next = want
            .and_then(|want| next_status(want, status.as_deref()))
            .filter(|next| Some(*next) != status.as_deref());
        if next.is_none() && !options {
            self.state = StatusWriteState::Unchanged;
            return Vec::new();
        }
        let read_seq = seq.as_deref().unwrap_or("");
        let guarded = want.is_some_and(is_conditional)
            && self.pane_is_target
            && read_seq.bytes().all(|b| b.is_ascii_digit());
        let write = next.map(|next| StatusWrite {
            agent: !self.options_have_agent,
            status: next,
            seq: next_seq(seq.as_deref(), now_ns),
            only_if_seq: guarded.then(|| read_seq.to_string()),
        });
        self.state = StatusWriteState::Writing {
            status: write.as_ref().map(|w| (w.status, w.seq.clone())),
            guarded: write.is_some() && guarded,
            attempt,
        };
        vec![StatusWriteEffect::Write {
            options,
            status: write,
        }]
    }
}

impl StateMachine for PaneStatusWriteMachine {
    type State = StatusWriteState;
    type Event = StatusWriteEvent;
    type Effect = StatusWriteEffect;

    fn state(&self) -> &StatusWriteState {
        &self.state
    }

    fn handle(&mut self, event: StatusWriteEvent) -> Vec<StatusWriteEffect> {
        match (self.state.clone(), event) {
            (
                StatusWriteState::Reading,
                StatusWriteEvent::Read {
                    want,
                    status,
                    seq,
                    options,
                    options_have_agent,
                    pane_is_target,
                    now_ns,
                },
            ) => {
                self.want = want;
                self.options_have_agent = options_have_agent;
                self.pane_is_target = pane_is_target;
                self.decide(status, seq, options, now_ns, 1)
            }
            (
                StatusWriteState::Writing {
                    status,
                    guarded,
                    attempt,
                },
                StatusWriteEvent::Answered(out),
            ) => {
                let Some(out) = out else {
                    self.state = StatusWriteState::Failed;
                    return Vec::new();
                };
                if guarded
                    && let Some((_, seq)) = &status
                    && out.trim_end_matches('\n') != seq
                {
                    // Another write moved the seq first: decide again from
                    // the pane as it is now, a bounded number of times.
                    if attempt < STATUS_WRITE_ATTEMPTS {
                        self.state = StatusWriteState::Rereading { attempt };
                        return vec![StatusWriteEffect::Reread];
                    }
                    self.state = StatusWriteState::Superseded;
                    return Vec::new();
                }
                let next = status.map(|(next, _)| next);
                self.state = StatusWriteState::Written { status: next };
                next.map(StatusWriteEffect::Notify).into_iter().collect()
            }
            (StatusWriteState::Rereading { attempt }, StatusWriteEvent::Reread(pane)) => {
                let Some(pane) = pane else {
                    self.state = StatusWriteState::Failed;
                    return Vec::new();
                };
                self.decide(pane.status, pane.seq, false, pane.now_ns, attempt + 1)
            }
            (
                StatusWriteState::Reading,
                StatusWriteEvent::Answered(_) | StatusWriteEvent::Reread(_),
            ) => Vec::new(),
            (
                StatusWriteState::Writing { .. },
                StatusWriteEvent::Read { .. } | StatusWriteEvent::Reread(_),
            ) => Vec::new(),
            (
                StatusWriteState::Rereading { .. },
                StatusWriteEvent::Read { .. } | StatusWriteEvent::Answered(_),
            ) => Vec::new(),
            (
                StatusWriteState::Written { .. }
                | StatusWriteState::Unchanged
                | StatusWriteState::Superseded
                | StatusWriteState::Failed,
                _,
            ) => Vec::new(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn read_release(
        held: Option<&str>,
        status: Option<&str>,
        wanted: Option<&str>,
    ) -> ReleaseEvent {
        ReleaseEvent::Read {
            held: held.map(str::to_string),
            status: status.map(str::to_string),
            wanted: wanted.map(str::to_string),
            pane_is_target: true,
        }
    }

    #[test]
    fn another_session_at_the_read_keeps_the_pane() {
        let mut release = SessionReleaseMachine::default();
        assert_eq!(
            release.handle(read_release(Some("s2"), Some("done"), Some("s1"))),
            []
        );
        assert_eq!(release.state(), &ReleaseState::Kept);
    }

    #[test]
    fn the_own_session_or_none_unsets_guarded_by_the_wanted_id() {
        for held in [Some("s1"), Some(""), None] {
            let mut release = SessionReleaseMachine::default();
            assert_eq!(
                release.handle(read_release(held, Some("done"), Some("s1"))),
                [ReleaseEffect::Unset {
                    only_for: Some("s1".into())
                }]
            );
            assert_eq!(
                release.state(),
                &ReleaseState::Unsetting {
                    guarded: true,
                    notify: true
                }
            );
        }
    }

    #[test]
    fn no_wanted_id_an_unformattable_one_or_an_odd_pane_unsets_unguarded() {
        for wanted in [None, Some("a,b"), Some("a#b"), Some("a}b"), Some("a\nb")] {
            let mut release = SessionReleaseMachine::default();
            assert_eq!(
                release.handle(read_release(wanted, None, wanted)),
                [ReleaseEffect::Unset { only_for: None }],
                "{wanted:?}"
            );
        }
        let mut release = SessionReleaseMachine::default();
        let effects = release.handle(ReleaseEvent::Read {
            held: None,
            status: None,
            wanted: Some("s1".into()),
            pane_is_target: false,
        });
        assert_eq!(effects, [ReleaseEffect::Unset { only_for: None }]);
    }

    #[test]
    fn a_guarded_unset_that_left_a_session_kept_the_pane() {
        let mut release = SessionReleaseMachine::default();
        let _ = release.handle(read_release(Some("s1"), Some("done"), Some("s1")));
        assert_eq!(
            release.handle(ReleaseEvent::Answered(Some("s2\n".into()))),
            []
        );
        assert_eq!(release.state(), &ReleaseState::Kept);
    }

    #[test]
    fn a_done_unset_notifies_only_a_pane_that_had_a_status() {
        for (status, notified) in [(Some("idle"), true), (Some(""), false), (None, false)] {
            let mut release = SessionReleaseMachine::default();
            let _ = release.handle(read_release(Some("s1"), status, Some("s1")));
            let effects = release.handle(ReleaseEvent::Answered(Some(String::new())));
            assert_eq!(effects.len(), usize::from(notified), "{status:?}");
            assert_eq!(release.state(), &ReleaseState::Released);
        }
        // Unguarded: any answer is done.
        let mut release = SessionReleaseMachine::default();
        let _ = release.handle(read_release(None, Some("idle"), None));
        assert_eq!(
            release.handle(ReleaseEvent::Answered(Some("ignored".into()))),
            [ReleaseEffect::NotifyRelease]
        );
    }

    #[test]
    fn a_failed_unset_notifies_nothing_and_late_events_are_ignored() {
        let mut release = SessionReleaseMachine::default();
        assert_eq!(release.handle(ReleaseEvent::Answered(None)), []);
        assert_eq!(release.state(), &ReleaseState::Reading);
        let _ = release.handle(read_release(None, Some("idle"), None));
        assert_eq!(release.handle(read_release(None, Some("idle"), None)), []);
        assert_eq!(release.handle(ReleaseEvent::Answered(None)), []);
        assert_eq!(release.state(), &ReleaseState::Failed);
        assert_eq!(
            release.handle(ReleaseEvent::Answered(Some(String::new()))),
            []
        );
        assert_eq!(release.state(), &ReleaseState::Failed);
    }

    fn read_status(
        want: Option<&'static str>,
        status: Option<&str>,
        seq: &str,
    ) -> StatusWriteEvent {
        StatusWriteEvent::Read {
            want,
            status: status.map(str::to_string),
            seq: (!seq.is_empty()).then(|| seq.to_string()),
            options: false,
            options_have_agent: false,
            pane_is_target: true,
            now_ns: 1_000,
        }
    }

    #[test]
    fn no_move_and_no_options_writes_nothing() {
        for (want, status) in [
            (Some("working"), Some("working")),
            (Some("idle-if-working"), Some("done")),
            (None, Some("idle")),
        ] {
            let mut write = PaneStatusWriteMachine::default();
            assert_eq!(write.handle(read_status(want, status, "5")), []);
            assert_eq!(write.state(), &StatusWriteState::Unchanged);
        }
    }

    #[test]
    fn options_alone_are_written_without_a_status() {
        let mut write = PaneStatusWriteMachine::default();
        let effects = write.handle(StatusWriteEvent::Read {
            want: Some("working"),
            status: Some("working".into()),
            seq: Some("5".into()),
            options: true,
            options_have_agent: true,
            pane_is_target: true,
            now_ns: 1_000,
        });
        assert_eq!(
            effects,
            [StatusWriteEffect::Write {
                options: true,
                status: None
            }]
        );
        assert_eq!(
            write.handle(StatusWriteEvent::Answered(Some(String::new()))),
            []
        );
        assert_eq!(write.state(), &StatusWriteState::Written { status: None });
    }

    #[test]
    fn an_unconditional_status_is_written_unguarded_with_the_agent_and_a_raised_seq() {
        let mut write = PaneStatusWriteMachine::default();
        assert_eq!(
            write.handle(read_status(Some("done"), Some("working"), "5000")),
            [StatusWriteEffect::Write {
                options: false,
                status: Some(StatusWrite {
                    agent: true,
                    status: "done",
                    seq: "5001".into(),
                    only_if_seq: None,
                })
            }]
        );
        assert_eq!(
            write.handle(StatusWriteEvent::Answered(Some(String::new()))),
            [StatusWriteEffect::Notify("done")]
        );
        assert_eq!(
            write.state(),
            &StatusWriteState::Written {
                status: Some("done")
            }
        );
    }

    #[test]
    fn a_conditional_status_is_guarded_by_the_seq_it_read() {
        for seq in ["100", ""] {
            let mut write = PaneStatusWriteMachine::default();
            let effects = write.handle(read_status(Some("idle-if-working"), Some("working"), seq));
            assert_eq!(
                effects,
                [StatusWriteEffect::Write {
                    options: false,
                    status: Some(StatusWrite {
                        agent: true,
                        status: "idle",
                        seq: next_seq((!seq.is_empty()).then_some(seq), 1_000),
                        only_if_seq: Some(seq.into()),
                    })
                }]
            );
        }
    }

    #[test]
    fn a_conditional_status_with_an_odd_seq_or_pane_is_unguarded() {
        let mut write = PaneStatusWriteMachine::default();
        let effects = write.handle(read_status(Some("idle-if-working"), Some("working"), "x1"));
        let [
            StatusWriteEffect::Write {
                status: Some(status),
                ..
            },
        ] = &effects[..]
        else {
            panic!("{effects:?}");
        };
        assert_eq!(status.only_if_seq, None);
        let mut write = PaneStatusWriteMachine::default();
        let effects = write.handle(StatusWriteEvent::Read {
            want: Some("idle-if-working"),
            status: Some("working".into()),
            seq: Some("1".into()),
            options: false,
            options_have_agent: false,
            pane_is_target: false,
            now_ns: 1_000,
        });
        let [
            StatusWriteEffect::Write {
                status: Some(status),
                ..
            },
        ] = &effects[..]
        else {
            panic!("{effects:?}");
        };
        assert_eq!(status.only_if_seq, None);
    }

    fn reread(status: &str, seq: &str) -> StatusWriteEvent {
        StatusWriteEvent::Reread(Some(PaneRead {
            status: Some(status.into()),
            seq: Some(seq.into()),
            now_ns: 1_000,
        }))
    }

    #[test]
    fn a_refused_guarded_write_rereads_decides_again_and_retries_the_status_alone() {
        let mut write = PaneStatusWriteMachine::default();
        let _ = write.handle(StatusWriteEvent::Read {
            want: Some("done-if-active"),
            status: Some("working".into()),
            seq: Some("100".into()),
            options: true,
            options_have_agent: false,
            pane_is_target: true,
            now_ns: 1_000,
        });
        assert_eq!(
            write.handle(StatusWriteEvent::Answered(Some("200\n".into()))),
            [StatusWriteEffect::Reread]
        );
        assert_eq!(write.state(), &StatusWriteState::Rereading { attempt: 1 });
        // Blocked is still active: Done again, guarded by the fresh seq, and
        // without the options, which landed with the first write.
        assert_eq!(
            write.handle(reread("blocked", "200")),
            [StatusWriteEffect::Write {
                options: false,
                status: Some(StatusWrite {
                    agent: true,
                    status: "done",
                    seq: "1000".into(),
                    only_if_seq: Some("200".into()),
                })
            }]
        );
        assert_eq!(
            write.handle(StatusWriteEvent::Answered(Some("1000\n".into()))),
            [StatusWriteEffect::Notify("done")]
        );
    }

    #[test]
    fn a_retry_whose_condition_no_longer_holds_or_whose_pane_is_gone_writes_nothing() {
        let mut write = PaneStatusWriteMachine::default();
        let _ = write.handle(read_status(Some("done-if-active"), Some("working"), "100"));
        let _ = write.handle(StatusWriteEvent::Answered(Some("200\n".into())));
        assert_eq!(write.handle(reread("idle", "200")), []);
        assert_eq!(write.state(), &StatusWriteState::Unchanged);
        let mut write = PaneStatusWriteMachine::default();
        let _ = write.handle(read_status(Some("done-if-active"), Some("working"), "100"));
        let _ = write.handle(StatusWriteEvent::Answered(Some("200\n".into())));
        assert_eq!(write.handle(StatusWriteEvent::Reread(None)), []);
        assert_eq!(write.state(), &StatusWriteState::Failed);
    }

    #[test]
    fn a_guarded_write_refused_on_every_attempt_is_superseded() {
        let mut write = PaneStatusWriteMachine::default();
        let _ = write.handle(read_status(Some("idle-if-working"), Some("working"), "100"));
        for attempt in 1..STATUS_WRITE_ATTEMPTS {
            assert_eq!(
                write.handle(StatusWriteEvent::Answered(Some("999\n".into()))),
                [StatusWriteEffect::Reread],
                "attempt {attempt}"
            );
            let _ = write.handle(reread("working", &format!("{}", 200 + u32::from(attempt))));
        }
        assert_eq!(
            write.handle(StatusWriteEvent::Answered(Some("999\n".into()))),
            []
        );
        assert_eq!(write.state(), &StatusWriteState::Superseded);
    }

    #[test]
    fn a_guarded_write_that_landed_notifies() {
        let mut write = PaneStatusWriteMachine::default();
        let effects = write.handle(read_status(Some("idle-if-working"), Some("working"), "100"));
        let [
            StatusWriteEffect::Write {
                status: Some(status),
                ..
            },
        ] = &effects[..]
        else {
            panic!("{effects:?}");
        };
        let landed = format!("{}\n", status.seq);
        assert_eq!(
            write.handle(StatusWriteEvent::Answered(Some(landed))),
            [StatusWriteEffect::Notify("idle")]
        );
    }

    #[test]
    fn a_failed_write_notifies_nothing_and_late_events_are_ignored() {
        let mut write = PaneStatusWriteMachine::default();
        assert_eq!(write.handle(StatusWriteEvent::Answered(None)), []);
        let _ = write.handle(read_status(Some("done"), Some("working"), "1"));
        assert_eq!(write.handle(read_status(Some("done"), None, "1")), []);
        assert_eq!(write.handle(reread("working", "1")), []);
        assert_eq!(write.handle(StatusWriteEvent::Answered(None)), []);
        assert_eq!(write.state(), &StatusWriteState::Failed);
        assert_eq!(
            write.handle(StatusWriteEvent::Answered(Some(String::new()))),
            []
        );
    }
}
