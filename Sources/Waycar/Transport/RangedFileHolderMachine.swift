import Foundation

/// The one SFTP channel `HostSSHSession` keeps for ranged Host-file reads
/// (#325): empty, opening (every read that arrives meanwhile joins that one
/// open, so no second channel goes unowned), or open; the reads in flight;
/// and the idle release that returns the channel and its admission lease
/// once nobody has read for a while.
///
/// A failed read drops the channel when it is the only read on it, so the
/// next look opens a fresh one; with another read still on it, that read
/// settles it instead, since closing the channel under it would strand it
/// mid-use. The idle release is armed when the last read ends with a
/// channel open, and disarmed by the next read.
///
/// Kept race: the idle release acts on whatever channel is open when it
/// runs with no read in flight. One that had already run out when a read
/// started, used the channel and ended (arming the next) still closes the
/// channel early, which only costs the next read an open, as before.
struct RangedFileHolderMachine: StateMachine {
    enum Holder: Equatable, Sendable {
        case empty
        /// The open under `token` is in flight.
        case opening(token: UInt64)
        case open(token: UInt64)
    }

    struct State: Equatable, Sendable {
        var holder: Holder = .empty
        var reads = 0
    }

    enum Event: Equatable, Sendable {
        case readStarted
        case opened(token: UInt64)
        case openFailed(token: UInt64)
        /// The read failed; its end follows once any close it asked for ran.
        case readFailed
        case readEnded
        /// The idle release ran out, uncancelled.
        case idleElapsed
        /// The session closed and took the channel itself.
        case sessionClosed
    }

    enum Effect: Equatable, Sendable {
        case cancelIdleRelease
        /// Read through the open channel.
        case use
        /// Wait for the open in flight.
        case joinOpening
        /// Open the channel under `token`: a lease, then SFTP.
        case open(token: UInt64)
        /// Close the channel and return its lease.
        case close
        case armIdleRelease
    }

    private(set) var state = State()
    private var lastToken: UInt64 = 0

    init() {}

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state.holder, event) {
        case (.empty, .readStarted):
            state.reads += 1
            lastToken += 1
            state.holder = .opening(token: lastToken)
            return [.cancelIdleRelease, .open(token: lastToken)]
        case (.opening, .readStarted):
            state.reads += 1
            return [.cancelIdleRelease, .joinOpening]
        case (.open, .readStarted):
            state.reads += 1
            return [.cancelIdleRelease, .use]

        case (.opening(let current), .opened(let token)) where current == token:
            state.holder = .open(token: token)
            return []
        case (.opening(let current), .openFailed(let token)) where current == token:
            state.holder = .empty
            return []
        case (.empty, .opened), (.opening, .opened), (.open, .opened),
            (.empty, .openFailed), (.opening, .openFailed), (.open, .openFailed):
            return []

        case (.open, .readFailed) where state.reads == 1:
            state.holder = .empty
            return [.cancelIdleRelease, .close]
        case (.empty, .readFailed) where state.reads == 1, (.opening, .readFailed) where state.reads == 1:
            // Nothing open to close; the release only disarms the idle one.
            return [.cancelIdleRelease]
        case (.empty, .readFailed), (.opening, .readFailed), (.open, .readFailed):
            return []

        case (_, .readEnded):
            state.reads = max(0, state.reads - 1)
            guard state.reads == 0, case .open = state.holder else { return [.cancelIdleRelease] }
            return [.cancelIdleRelease, .armIdleRelease]

        case (.open, .idleElapsed) where state.reads == 0:
            state.holder = .empty
            return [.cancelIdleRelease, .close]
        case (.empty, .idleElapsed) where state.reads == 0, (.opening, .idleElapsed) where state.reads == 0:
            return [.cancelIdleRelease]
        case (.empty, .idleElapsed), (.opening, .idleElapsed), (.open, .idleElapsed):
            return []

        case (.open, .sessionClosed):
            state.holder = .empty
            return [.cancelIdleRelease, .close]
        case (.empty, .sessionClosed), (.opening, .sessionClosed):
            return [.cancelIdleRelease]
        }
    }
}
