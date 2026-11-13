/// An explicit state machine: one value type that holds a lifecycle's state
/// and owns every legal transition (docs/design/state-machines.md).
///
/// `handle(_:)` is pure: no I/O, no clock reads, no Tasks. Time arrives in
/// events, and anything the machine needs done (start a request, arm a timer,
/// write a file) comes back as an `Effect` that the owning store or actor
/// performs. Work that crosses an `await` carries a token the machine minted;
/// its completion event brings the token back and the machine drops a stale
/// one, so reentrancy is checked in one place.
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
