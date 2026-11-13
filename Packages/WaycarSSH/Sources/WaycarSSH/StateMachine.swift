/// An explicit state machine: one value type that holds a lifecycle's state
/// and owns every legal transition (docs/design/state-machines.md). The
/// package cannot see the app, so it declares the app's protocol under the
/// same name.
///
/// `handle(_:)` is pure: no I/O, no clock reads, no Tasks, no native calls.
/// Anything the machine needs done comes back as an `Effect` that the owning
/// actor or driver performs. Work that crosses an `await` carries a token the
/// machine minted; its completion brings the token back and the machine drops
/// a stale one.
///
/// Every conforming type has a row in the index of
/// docs/design/state-machines.md; `scripts/check-state-machines.py` checks it.
protocol StateMachine: Sendable {
    associatedtype State: Equatable & Sendable
    associatedtype Event: Sendable
    associatedtype Effect: Equatable & Sendable

    /// Where the machine stands. Only `handle(_:)` changes it.
    var state: State { get }

    /// Applies one event and returns what the owner must do, in order.
    mutating func handle(_ event: Event) -> [Effect]
}
