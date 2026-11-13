import Foundation

/// One Host's Chat Marker reads (#69): which verification its rows are in,
/// whether the markers were read in it, and the one read (or the wait for
/// it) in flight.
///
/// A verification starts each time the Host's marker projection's rows
/// become verified, the markers move between projections, or a backend's
/// rows are verified again after a gap. A read confirms the markers only
/// when it lands in the verification it began in; one that spans a new
/// verification holds back a second read, and the new verification reads
/// as soon as it ends. Inside a verification reads are at least `interval`
/// apart, and a change inside the interval waits it out; a new
/// verification preempts that wait.
///
/// Tokens carry the entry they were minted for, so a Task left from a
/// Host removed and added again never ends the new entry's read. `began`
/// and `landed` carry no token, as before: a waiting Task cancelled after
/// its sleep ended still reads, and its answer confirms by verification.
struct ChatMarkerReadMachine: StateMachine {
    struct Token: Hashable, Sendable {
        let entry: UInt64
        let serial: UInt64
    }

    enum State: Equatable, Sendable {
        case idle
        /// Its Task sleeps out the refresh interval.
        case waiting(Token)
        /// Its Task is reading, repairing, or about to begin.
        case running(Token)
    }

    enum Event: Equatable, Sendable {
        /// The rows of the Host's marker projection (`fallback`: not its
        /// primary one) and which backends' rows are verified, at a rebuild.
        case observed(verified: Bool, fallback: Bool, verifiedBackends: Set<HostBackend>)
        case schedule(now: Date, interval: TimeInterval)
        /// A read's Task passed its wait; `eligible`: its projection is still
        /// the verified marker projection and the Console is active.
        case began(eligible: Bool, now: Date)
        /// A read that began in `verification` finished its repairs.
        case landed(verification: UInt64)
        case ended(Token)
    }

    enum Effect: Equatable, Sendable {
        /// The verification bookkeeping changed: keep the entry.
        case keep
        /// Cancel the waiting Task.
        case cancel(Token)
        case start(Token, wait: TimeInterval)
        /// Read the Host's markers in `verification`.
        case read(verification: UInt64)
        case confirmed
        /// Drop the ended Task's handle.
        case release
        /// The read spanned a new verification: read for it now.
        case reschedule
    }

    private(set) var state: State = .idle
    private(set) var isVerified = false
    private(set) var isFallback = false
    private(set) var verifiedBackends: Set<HostBackend> = []
    /// Counts the Host's verifications.
    private(set) var verification: UInt64 = 0
    private(set) var startedAt: Date?
    /// The verification the last read began in.
    private(set) var startedVerification: UInt64?
    /// The verification whose read landed.
    private(set) var confirmedVerification: UInt64?
    private let entry: UInt64
    private var lastSerial: UInt64 = 0

    init(entry: UInt64) {
        self.entry = entry
    }

    /// Whether the cached markers are known to be the Host's current ones.
    var isConfirmed: Bool { confirmedVerification == verification }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (_, .observed(let verified, let fallback, let backends)):
            guard verified != isVerified || fallback != isFallback || backends != verifiedBackends
            else { return [] }
            let reverified = !backends.isSubset(of: verifiedBackends)
            if verified, !isVerified || fallback != isFallback || reverified {
                verification &+= 1
            }
            isVerified = verified
            isFallback = fallback
            verifiedBackends = backends
            return [.keep]
        case (.running, .schedule):
            return []
        case (.waiting(let token), .schedule(let now, let interval)):
            // A refresh still waiting gives way to a new verification's read.
            guard startedVerification != verification else { return [] }
            return [.cancel(token)] + start(now: now, interval: interval)
        case (.idle, .schedule(let now, let interval)):
            return start(now: now, interval: interval)
        case (_, .began(false, _)):
            return []
        case (_, .began(true, let now)):
            if case .waiting(let token) = state { state = .running(token) }
            startedAt = now
            startedVerification = verification
            return [.read(verification: verification)]
        case (_, .landed(let landed)):
            guard landed == verification else { return [] }
            confirmedVerification = landed
            return [.confirmed]
        case (.waiting(let token), .ended(let ended)), (.running(let token), .ended(let ended)):
            guard ended == token else { return [] }
            state = .idle
            return startedVerification != verification ? [.release, .reschedule] : [.release]
        case (.idle, .ended):
            return []
        }
    }

    private mutating func start(now: Date, interval: TimeInterval) -> [Effect] {
        let wait = startedVerification != verification
            ? 0 : startedAt.map { interval - now.timeIntervalSince($0) } ?? 0
        lastSerial &+= 1
        let token = Token(entry: entry, serial: lastSerial)
        state = wait > 0 ? .waiting(token) : .running(token)
        return [.start(token, wait: wait)]
    }
}
