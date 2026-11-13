/// An explicit state machine: one value type that holds a lifecycle's state
/// and owns every legal transition (the app's docs/design/state-machines.md;
/// the app declares the same protocol, which this package cannot see).
///
/// `handle(_:)` is pure: no I/O, no clock reads, no Tasks. Time arrives in
/// events, and anything the machine needs done comes back as an `Effect`
/// that the owning actor performs. Work that crosses an `await` carries a
/// token the machine minted; its completion brings the token back and the
/// machine drops a stale one. (Waycar patch.)
package protocol StateMachine: Sendable {
    associatedtype State: Equatable & Sendable
    associatedtype Event: Sendable
    associatedtype Effect: Equatable & Sendable

    /// Where the machine stands. Only `handle(_:)` changes it.
    var state: State { get }

    /// Applies one event and returns what the owner must do, in order.
    mutating func handle(_ event: Event) -> [Effect]
}
