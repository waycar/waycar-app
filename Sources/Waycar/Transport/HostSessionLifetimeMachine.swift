import Foundation

/// How long one `HostSSHSession` lives (ADR 0026): open with its holds, found
/// invalidated while still held, or closed by its last release.
///
/// Every holder owns one hold; a closed session refuses a new one, so the
/// caller dials afresh. The last release of an open session tears it down
/// (the session's own channels, then the connection); the last release of
/// a session already found invalidated only closes it, leaving the
/// connection as the SSH layer left it, as the herdr Transport always did.
/// Nothing new is started on a session that is not open.
struct HostSessionLifetimeMachine: StateMachine {
    enum State: Equatable, Sendable {
        case open(holds: Int)
        /// The SSH layer reported the connection gone; holders still hold it.
        case invalidated(holds: Int)
        case closed
    }

    enum Event: Equatable, Sendable {
        case retain
        case release
        /// An operation found the connection invalidated.
        case connectionInvalidated
    }

    enum Effect: Equatable, Sendable {
        /// The new hold is taken.
        case retained
        /// Closed: no new hold.
        case refused
        /// The last hold went: end the session's channels and close the
        /// connection.
        case tearDown
    }

    /// A new session is held once, by its creator.
    private(set) var state: State = .open(holds: 1)

    init() {}

    /// Open as far as the app knows: not closed, not found invalidated.
    var isOpen: Bool {
        if case .open = state { return true }
        return false
    }

    var isClosed: Bool { state == .closed }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.open(let holds), .retain):
            state = .open(holds: holds + 1)
            return [.retained]
        case (.invalidated(let holds), .retain):
            state = .invalidated(holds: holds + 1)
            return [.retained]
        case (.closed, .retain):
            return [.refused]

        case (.open(let holds), .release) where holds > 1:
            state = .open(holds: holds - 1)
            return []
        case (.open, .release):
            state = .closed
            return [.tearDown]
        case (.invalidated(let holds), .release) where holds > 1:
            state = .invalidated(holds: holds - 1)
            return []
        case (.invalidated, .release):
            state = .closed
            return []
        case (.closed, .release):
            return []

        case (.open(let holds), .connectionInvalidated):
            state = .invalidated(holds: holds)
            return []
        case (.invalidated, .connectionInvalidated), (.closed, .connectionInvalidated):
            return []
        }
    }
}
