/// One terminal pipeline's runs (``AttachTerminalStore``): the status the
/// screen shows, the run and the session in it, and every restart a run's
/// end, the mosh upgrade or the user's retries schedule.
///
/// Rules a reader needs:
/// - A run starts on the first known size, a retry, or a restart; one
///   session per run, and only a session that drew something (or a mosh
///   session whose blank first frame outlasted the grace) goes live.
/// - A run's failure restarts it at most once per budget: a lost mosh link
///   once per live stretch, the automatic mosh→SSH fallback once per store
///   (a user's retry or the upgrade give it back), a transient channel death
///   once per ended episode. Anything else ends with its message.
/// - A stop is terminal: no run ending after it changes the status, and a
///   restart that wakes after it does not start. As before, a restart that
///   passed that check before the mosh invalidation it awaits still starts
///   once the invalidation returns; that run sees the stop and ends its
///   session at once.
/// - An upgrade restart owns the status while it is scheduled: the dying
///   run's end changes nothing.
/// - The blank-frame grace belongs to the session that armed it.
struct TerminalRunMachine: StateMachine {
    typealias Status = AttachTerminalStore.Status

    enum Run: Equatable, Sendable {
        case idle
        case running(token: UInt64)
    }

    enum Session: Equatable, Sendable {
        case none
        case open(token: UInt64)
    }

    /// How a run's runner failed, as far as restarts care.
    enum Failure: Equatable, Sendable {
        /// A live mosh session's server stopped answering.
        case moshLinkLost
        /// The mosh attempt died after its banner.
        case moshSessionFailed
        /// The attach channel's own I/O died.
        case transient
        case other
    }

    struct State: Equatable, Sendable {
        var status = Status.waitingForSize
        var run = Run.idle
        var session = Session.none
        var runningFlavor: TerminalSessionFlavor?
        var stopRequested = false
        var upgradeRestartScheduled = false
        var hasBeenLive = false
        var endedWithMoshFailure = false
        /// Never reset by the fallback's own restart, so a failed
        /// invalidation cannot loop mosh against the same dead handshake.
        var moshAutoFallbackUsed = false
        var transientRetryUsed = false
        var linkLossReattachUsed = false
    }

    enum Event: Equatable, Sendable {
        /// A run starts: first size, retry or restart.
        case start
        case transportReady(TerminalSessionFlavor)
        case sessionOpened
        case sessionFinished
        /// The session drew something, or no content is waited for.
        case contentShown
        case graceElapsed(session: UInt64)
        /// The runner threw. Like the run's end below, it is not checked
        /// against the run's token: the old code never did, and a second
        /// run can only overlap a first through two queued restarts.
        case runFailed(Failure, message: String, canInvalidateMosh: Bool)
        case runCompleted
        /// The run Task's own end: unconditional, as before.
        case runFinished
        case retry
        case retryOverSSH
        case upgrade
        /// A scheduled restart woke after its predecessor ended.
        case restartDue
        case upgradeRestartDue
        case stop
        case stopFinished
    }

    enum Effect: Equatable, Sendable {
        case publishStatus(Status)
        case publishFlavor(TerminalSessionFlavor?)
        case publishEndedWithMoshFailure(Bool)
        case publishHasBeenLive
        case publishStopRequested
        case publishUpgradeScheduled(Bool)
        case telemetryBegan
        case telemetryWentLive
        case telemetryRunEnded(restarting: Bool)
        case telemetryStopped
        /// Forget the previous run's acquired transport generation.
        case clearAcquired
        case startRun(UInt64)
        case sessionToken(UInt64)
        /// Schedule a restart behind the running task; a mosh invalidation
        /// with `cause` runs first.
        case scheduleRestart(invalidating: MoshInvalidationCause?)
        /// End the session (cancel the run when none is open), then restart.
        case scheduleUpgradeRestart
        case restart
    }

    private(set) var state = State()
    private var lastToken: UInt64 = 0

    var status: Status { state.status }
    var isRunning: Bool { state.run != .idle }
    var hasSession: Bool { state.session != .none }

    func isSession(_ token: UInt64) -> Bool { state.session == .open(token: token) }

    /// Whether `upgrade` would restart: a live session, or one still
    /// connecting over SSH.
    var canUpgradeToMosh: Bool {
        guard isRunning, !state.stopRequested, !state.upgradeRestartScheduled else { return false }
        switch state.status {
        case .live: return true
        case .connecting: return state.runningFlavor == .ssh
        case .waitingForSize, .ended, .stopped: return false
        }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .start:
            state.status = .connecting
            state.endedWithMoshFailure = false
            state.runningFlavor = nil
            let token = nextToken()
            state.run = .running(token: token)
            return [
                .publishStatus(.connecting), .telemetryBegan, .publishEndedWithMoshFailure(false),
                .publishFlavor(nil), .clearAcquired, .startRun(token),
            ]
        case .transportReady(let flavor):
            state.runningFlavor = flavor
            return [.publishFlavor(flavor)]
        case .sessionOpened:
            let token = nextToken()
            state.session = .open(token: token)
            return [.sessionToken(token)]
        case .sessionFinished:
            state.session = .none
            return []
        case .contentShown:
            guard state.status == .connecting else { return [] }
            return goLive()
        case .graceElapsed(let session):
            guard state.session == .open(token: session), state.status == .connecting else { return [] }
            return goLive()
        case .runFailed(let failure, let message, let canInvalidateMosh):
            guard !state.stopRequested, !state.upgradeRestartScheduled else { return [] }
            if failure == .moshLinkLost, !state.linkLossReattachUsed {
                // The link went, not mosh: reattach once the ordinary way.
                state.linkLossReattachUsed = true
                return restarting(invalidating: nil)
            }
            var effects: [Effect] = []
            if failure == .moshSessionFailed {
                state.endedWithMoshFailure = true
                effects.append(.publishEndedWithMoshFailure(true))
                if !state.moshAutoFallbackUsed, canInvalidateMosh {
                    state.moshAutoFallbackUsed = true
                    return effects + restarting(invalidating: .automaticFallback)
                }
            }
            if failure == .transient, !state.transientRetryUsed {
                state.transientRetryUsed = true
                return effects + restarting(invalidating: nil)
            }
            state.status = .ended(message)
            return effects + [.telemetryRunEnded(restarting: false), .publishStatus(state.status)]
        case .runCompleted:
            guard !state.stopRequested, !state.upgradeRestartScheduled else { return [] }
            state.status = .ended("The session ended.")
            return [.telemetryRunEnded(restarting: false), .publishStatus(state.status)]
        case .runFinished:
            state.run = .idle
            return []
        case .retry:
            guard case .ended = state.status, !isRunning else { return [] }
            // A user-driven reattach is a fresh consent to the mosh path.
            state.moshAutoFallbackUsed = false
            return handle(.start)
        case .retryOverSSH:
            guard case .ended = state.status else { return [] }
            state.moshAutoFallbackUsed = true
            return [.scheduleRestart(invalidating: .userChoseSSH)]
        case .upgrade:
            guard canUpgradeToMosh else { return [] }
            state.upgradeRestartScheduled = true
            state.moshAutoFallbackUsed = false
            state.status = .connecting
            return [.publishUpgradeScheduled(true), .publishStatus(.connecting), .scheduleUpgradeRestart]
        case .restartDue:
            guard !state.stopRequested else { return [] }
            return [.restart]
        case .upgradeRestartDue:
            guard !state.stopRequested else { return [] }
            state.upgradeRestartScheduled = false
            return [.publishUpgradeScheduled(false), .restart]
        case .stop:
            state.stopRequested = true
            return [.publishStopRequested, .telemetryStopped]
        case .stopFinished:
            state.status = .stopped
            return [.publishStatus(.stopped)]
        }
    }

    private mutating func restarting(invalidating cause: MoshInvalidationCause?) -> [Effect] {
        state.status = .connecting
        return [
            .telemetryRunEnded(restarting: true), .publishStatus(.connecting),
            .scheduleRestart(invalidating: cause),
        ]
    }

    private mutating func goLive() -> [Effect] {
        state.status = .live
        state.hasBeenLive = true
        state.linkLossReattachUsed = false
        state.transientRetryUsed = false
        return [.publishStatus(.live), .publishHasBeenLive, .telemetryWentLive]
    }

    private mutating func nextToken() -> UInt64 {
        lastToken += 1
        return lastToken
    }
}
