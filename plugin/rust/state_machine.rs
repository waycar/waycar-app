//! An explicit state machine: one value that holds a lifecycle's state and
//! owns every legal transition (docs/design/state-machines.md), the Host
//! Tools' counterpart of the app's `StateMachine` protocol.
//!
//! `handle` is pure: no I/O, no clock reads, no threads, no logging. Time
//! arrives in events, and anything the machine needs done (kill a process
//! group, write a pane option, post a push) comes back as an `Effect` that
//! the owning function performs, in order. Work that finishes later carries
//! a token the machine minted, and the machine drops a stale one.
//!
//! Every implementing type has an entry in the Index of
//! docs/design/state-machines.md; `scripts/check-state-machines.py` checks
//! it by `impl StateMachine for`.

pub trait StateMachine {
    type State: Clone + PartialEq + std::fmt::Debug;
    type Event;
    type Effect: PartialEq + std::fmt::Debug;

    /// Where the machine stands. Only `handle` changes it.
    fn state(&self) -> &Self::State;

    /// Applies one event and returns what the owner must do, in order.
    #[must_use = "the owner performs every effect"]
    fn handle(&mut self, event: Self::Event) -> Vec<Self::Effect>;
}

#[cfg(test)]
pub mod testing {
    use super::StateMachine;

    /// The effects of `events`, in order, from `machine`.
    pub fn handle_all<M: StateMachine>(
        machine: &mut M,
        events: impl IntoIterator<Item = M::Event>,
    ) -> Vec<M::Effect> {
        events
            .into_iter()
            .flat_map(|event| machine.handle(event))
            .collect()
    }
}
