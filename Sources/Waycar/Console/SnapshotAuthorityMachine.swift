/// Whether a Host projection's rows are the Host's word, and the snapshot
/// work that makes them so: one resync at a time with one coalesced
/// follow-up, the retry after a failed snapshot, and the epoch that fences
/// off answers from a connection that has since dropped.
///
/// Rows are `awaiting` (cached, kept from a dropped connection, or never
/// loaded) until a live snapshot from the current connection lands, then
/// `verified` until the connection changes. A connection change bumps the
/// epoch but leaves a resync in flight running: its answer is refused, and
/// the new connection's own request waits for it as the follow-up.
///
/// The retry's wait carries no token, as before: one whose sleep ended after
/// it was cancelled still lands, releasing whatever retry is armed and
/// asking for a resync.
struct SnapshotAuthorityMachine: StateMachine {
    enum Authority: Equatable, Sendable {
        case awaiting
        case verified
    }

    enum Resync: Equatable, Sendable {
        case idle
        case running(token: UInt64, followUp: Bool)
    }

    struct State: Equatable, Sendable {
        var authority: Authority = .awaiting
        var resync: Resync = .idle
        /// Snapshot work that crossed a connection change is refused.
        var epoch: UInt64 = 0
        var isRetryArmed = false
        /// The projection ended: its rows keep the authority they had, and
        /// nothing is asked for again.
        var isEnded = false
    }

    enum Event: Equatable, Sendable {
        /// Something asked for a fresh snapshot.
        case requested(connected: Bool)
        case resyncEnded(token: UInt64, connected: Bool)
        /// A snapshot taken in `epoch` answered.
        case landed(epoch: UInt64, connected: Bool)
        /// A snapshot taken in `epoch` failed.
        case refused(epoch: UInt64, connected: Bool)
        /// The answer's rows replaced the inventory.
        case verified
        /// The failure was published: retry after the delay.
        case retryRequested(connected: Bool)
        case retryElapsed(connected: Bool)
        case connectionChanged
        case end
    }

    enum Effect: Equatable, Sendable {
        case run(token: UInt64)
        /// The resync Task ended: drop its handle.
        case release
        case cancelRun(token: UInt64)
        case apply
        case reportFailure
        case armRetry
        case cancelRetry
        /// The retry Task ended: drop its handle.
        case releaseRetry
    }

    private(set) var state = State()
    private var lastToken: UInt64 = 0

    var epoch: UInt64 { state.epoch }
    var isAwaitingSnapshot: Bool { state.authority != .verified }

    mutating func handle(_ event: Event) -> [Effect] {
        if state.isEnded { return [] }
        switch event {
        case .requested(let connected):
            return request(connected: connected)
        case .resyncEnded(let token, let connected):
            guard case .running(token, let followUp) = state.resync else { return [] }
            state.resync = .idle
            return followUp ? [.release] + request(connected: connected) : [.release]
        case .landed(let epoch, let connected):
            guard connected, epoch == state.epoch else { return [] }
            return cancelRetry() + [.apply]
        case .refused(let epoch, let connected):
            guard connected, epoch == state.epoch else { return [] }
            return [.reportFailure]
        case .verified:
            state.authority = .verified
            return []
        case .retryRequested(let connected):
            guard !state.isRetryArmed, connected else { return [] }
            state.isRetryArmed = true
            return [.armRetry]
        case .retryElapsed(let connected):
            guard connected else { return [] }
            state.isRetryArmed = false
            return [.releaseRetry] + request(connected: connected)
        case .connectionChanged:
            state.epoch &+= 1
            state.authority = .awaiting
            if case .running(let token, _) = state.resync {
                state.resync = .running(token: token, followUp: false)
            }
            return cancelRetry()
        case .end:
            let running = state.resync
            state.isEnded = true
            state.resync = .idle
            var effects: [Effect] = []
            if case .running(let token, _) = running { effects.append(.cancelRun(token: token)) }
            return effects + cancelRetry()
        }
    }

    private mutating func request(connected: Bool) -> [Effect] {
        guard connected else { return [] }
        if case .running(let token, _) = state.resync {
            state.resync = .running(token: token, followUp: true)
            return []
        }
        lastToken &+= 1
        state.resync = .running(token: lastToken, followUp: false)
        return [.run(token: lastToken)]
    }

    private mutating func cancelRetry() -> [Effect] {
        guard state.isRetryArmed else { return [] }
        state.isRetryArmed = false
        return [.cancelRetry]
    }
}
