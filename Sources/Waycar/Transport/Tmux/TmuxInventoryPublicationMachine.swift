import Foundation

/// Which inventory refresh is in force (``TmuxTransport/sessionSnapshot()``):
/// refreshes may overlap (a snapshot waits on its checkout and `ps` execs
/// while another lists), and each answers its own caller with what it
/// listed, but only one that started after the inventory in force may
/// publish: the records, launch-gate pruning, Shell Activity and the last
/// snapshot. An older refresh finishing last never publishes over a newer
/// one (B-24).
struct TmuxInventoryPublicationMachine: StateMachine {
    enum State: Equatable, Sendable {
        /// No refresh has published since the transport opened.
        case empty
        /// What refresh `token` listed is the inventory in force.
        case current(token: UInt64)
    }

    enum Event: Equatable, Sendable {
        /// A refresh is about to list the server.
        case refreshRequested
        /// Refresh `token` listed (or found no session) and is enriched.
        case listed(token: UInt64)
    }

    enum Effect: Equatable, Sendable {
        /// List the server under `token`.
        case list(token: UInt64)
        /// Publish what refresh `token` listed.
        case publish(token: UInt64)
    }

    private(set) var state: State = .empty
    private var lastToken: UInt64 = 0

    init() {}

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (_, .refreshRequested):
            lastToken += 1
            return [.list(token: lastToken)]
        case (.empty, .listed(let token)):
            state = .current(token: token)
            return [.publish(token: token)]
        case (.current(let current), .listed(let token)):
            guard token > current else { return [] }
            state = .current(token: token)
            return [.publish(token: token)]
        }
    }
}
