import Foundation

/// The baseline each `%subscription-changed` push diffs against (T7, design
/// §4.3): the last value per subscription name since the control client
/// connected. A name with no value yet is unseeded; a first status push
/// then diffs against the last snapshot's hook values, since subscription
/// evaluation lags its acknowledgement and the first push may already
/// differ from the snapshot handed out; without a snapshot it asks for one
/// (``TmuxEvents/events(name:previous:value:)``). A new control client, or
/// a server left with no session, starts unseeded again.
struct TmuxSubscriptionBaselineMachine: StateMachine {
    enum Event: Equatable, Sendable {
        /// A new control client connected, or the server went idle.
        case reset
        /// A push of `value` for `name`. `snapshotPanes` is the last
        /// snapshot's panes, nil while there is none.
        case pushed(name: String, value: String, snapshotPanes: [TmuxPaneRecord]?)
    }

    enum Effect: Equatable, Sendable {
        /// A pane's status changed: delivered at once.
        case deliver(HerdrEvent)
        /// Something needs a re-snapshot: a debounced resync of `kind`.
        case resync(HerdrEventKind)
    }

    /// The last value per subscription name; a name without one is unseeded.
    private(set) var state: [String: String] = [:]

    init() {}

    /// The latest value pushed for `name` on this client.
    func value(of name: String) -> String? { state[name] }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .reset:
            state = [:]
            return []
        case .pushed(let name, let value, let snapshotPanes):
            let previous = state[name]
                ?? (name == TmuxEvents.statusName ? snapshotPanes.map(TmuxEvents.statusValue) : nil)
            state[name] = value
            return TmuxEvents.events(name: name, previous: previous, value: value).map { event in
                event.kind == PaneEventKind.agentStatusChanged.kind
                    ? .deliver(event) : .resync(event.kind)
            }
        }
    }
}
