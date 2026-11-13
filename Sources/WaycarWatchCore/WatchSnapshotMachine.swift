import Foundation

/// Snapshot ordering and wire compatibility are one acceptance boundary.
/// Link reachability remains orthogonal and never erases retained rows.
struct WatchSnapshotMachine: StateMachine {
    enum State: Equatable, Sendable {
        case awaitingFirstState
        case current(WatchState)
        case incompatible(peerVersion: Int, previous: WatchState?)
    }
    enum Event: Equatable, Sendable {
        case snapshot(WatchState)
        case versionMismatch(Int)
    }
    enum Effect: Equatable, Sendable {
        case accepted(previous: WatchState?, next: WatchState)
    }
    private(set) var state: State = .awaitingFirstState

    var snapshot: WatchState? {
        switch state {
        case .awaitingFirstState: nil
        case .current(let snapshot): snapshot
        case .incompatible(_, let previous): previous
        }
    }
    var peerVersion: Int? {
        if case .incompatible(let version, _) = state { return version }
        return nil
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .versionMismatch(let version):
            state = .incompatible(peerVersion: version, previous: snapshot)
            return []
        case .snapshot(let incoming):
            let previous = snapshot
            // Rejected data is not evidence that compatibility recovered.
            if let previous, incoming.generatedAt < previous.generatedAt { return [] }
            let next = incoming.keepingRows(from: previous)
            state = .current(next)
            return [.accepted(previous: previous, next: next)]
        }
    }
}
