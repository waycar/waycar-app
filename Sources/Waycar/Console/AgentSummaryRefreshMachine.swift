/// One Host's Agent Summary refresh cadence: the wait before the next
/// refresh (the periodic interval, or the debounce after a status change),
/// then one refresh at a time (trigger, settle, re-read), with what this
/// connection learnt: consecutive failures and a missing refresh action.
///
/// A cancelled refresh (summaries paused, the connection reset) keeps its
/// slot until its Task ends: the owner reports it `cancelled`, which moves no
/// clock and covers no pane, and only then may the next one start.
///
/// The follow-up a status change asks for while a refresh runs is a field
/// rather than state data: it outlives the refresh by one step, until
/// `proceed`, which the owner sends after the finished refresh's rows are
/// published (publication can re-enter the owner, and a pause or reconnect
/// meanwhile still drops the follow-up, as before).
///
/// Waits carry no token: the owner cancels a replaced wait's Task, but one
/// whose sleep had already ended still lands, and starts the refresh as it
/// always did.
struct AgentSummaryRefreshMachine: StateMachine {
    enum Wait: Equatable, Sendable {
        case periodic
        case debounce
    }

    enum State: Equatable, Sendable {
        case idle
        case waiting(Wait)
        case refreshing(token: UInt64, restartsClock: Bool)
        case ended
    }

    enum Outcome: Equatable, Sendable {
        case refreshed
        /// The plugin or herdr has no refresh action.
        case unsupported
        case pluginMissing
        case failed
        /// The connection went away under it: no failure.
        case interrupted
        /// The owner called it off: summaries paused, or the connection
        /// reset.
        case cancelled

        init(_ error: any Error) {
            switch error {
            case AgentSummaryRefreshError.actionUnavailable: self = .unsupported
            case NotificationRegistrationError.pluginNotInstalled: self = .pluginMissing
            case is CancellationError, TransportError.cancelled, TransportError.sshUnreachable:
                self = .interrupted
            default: self = .failed
            }
        }

        /// Whether the store is worth reading after it.
        var readsStore: Bool { self == .refreshed || self == .unsupported }
    }

    enum Event: Equatable, Sendable {
        /// Arm the periodic refresh unless a wait or a refresh is pending.
        case schedule(canRefresh: Bool)
        /// An Agent changed status: refresh after the debounce, or once more
        /// after the refresh in flight. A Host backing off waits instead.
        case statusChanged(canRefresh: Bool)
        /// A wait's sleep ended. `periodicDue`: the periodic refresh is due
        /// now, so a status-triggered refresh also restarts its clock.
        case waitEnded(Wait, canRefresh: Bool, periodicDue: Bool)
        case finished(token: UInt64, Outcome)
        /// The finished refresh's rows are published: start its follow-up,
        /// or arm the next periodic refresh.
        case proceed(readsStore: Bool, canRefresh: Bool, periodicDue: Bool)
        /// Summaries turned off, or the app left the foreground.
        case paused
        case connectionChanged
        /// A store read found no plugin.
        case pluginMissing
        case end
    }

    enum Effect: Equatable, Sendable {
        /// Replace any wait with a new one of this kind.
        case arm(Wait)
        case cancelWait
        case startRefresh(token: UInt64, triggers: Bool)
        case cancelRefresh(token: UInt64)
        /// Tell the summary reads the plugin is missing.
        case reportPluginMissing
        /// Stamp the periodic clock's restart.
        case restartClock
        /// Mark the listed panes as covered by a finished refresh.
        case cover
        case updateRows
        /// Send `proceed` once the effects before it have run.
        case proceed(readsStore: Bool)
    }

    private(set) var state: State = .idle
    private(set) var failures = 0
    private(set) var isUnsupported = false
    private var followUpRequested = false
    private var lastToken: UInt64 = 0

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.ended, _):
            return []
        case (_, .end):
            let effects = stop()
            state = .ended
            return effects
        case (.idle, .schedule(true)):
            guard !isUnsupported else { return [] }
            state = .waiting(.periodic)
            return [.arm(.periodic)]
        case (.idle, .schedule(false)), (.waiting, .schedule), (.refreshing, .schedule):
            return []
        case (_, .statusChanged(let canRefresh)):
            guard canRefresh, failures == 0 else { return [] }
            if case .refreshing = state {
                followUpRequested = true
                return []
            }
            state = .waiting(.debounce)
            return [.arm(.debounce)]
        case (_, .waitEnded(let wait, let canRefresh, let periodicDue)):
            return start(periodic: wait == .periodic, canRefresh: canRefresh, periodicDue: periodicDue)
        case (.refreshing(let token, let restartsClock), .finished(let finished, let outcome)):
            guard finished == token else { return [] }
            return finish(outcome, restartsClock: restartsClock)
        case (.idle, .finished), (.waiting, .finished):
            return []
        case (_, .proceed(let readsStore, let canRefresh, let periodicDue)):
            let followUp = followUpRequested && readsStore
            followUpRequested = false
            if followUp {
                return start(periodic: false, canRefresh: canRefresh, periodicDue: periodicDue)
            }
            return handle(.schedule(canRefresh: canRefresh))
        case (_, .paused):
            followUpRequested = false
            return stop()
        case (_, .connectionChanged):
            failures = 0
            isUnsupported = false
            followUpRequested = false
            return stop()
        case (.waiting, .pluginMissing):
            state = .idle
            return [.cancelWait]
        case (.idle, .pluginMissing), (.refreshing, .pluginMissing):
            return []
        }
    }

    /// Ends any wait and cancels the refresh in flight, which keeps its slot
    /// until its Task reports back.
    private mutating func stop() -> [Effect] {
        switch state {
        case .waiting:
            state = .idle
            return [.cancelWait]
        case .refreshing(let token, _):
            return [.cancelRefresh(token: token)]
        case .idle, .ended:
            return []
        }
    }

    private mutating func start(periodic: Bool, canRefresh: Bool, periodicDue: Bool) -> [Effect] {
        var effects: [Effect] = []
        if case .waiting = state {
            state = .idle
            effects.append(.cancelWait)
        }
        guard canRefresh else { return effects }
        if case .refreshing = state {
            followUpRequested = true
            return effects
        }
        lastToken &+= 1
        // A status-triggered run stands in for the periodic one only once
        // that is due. Earlier, it leaves the periodic clock alone: the
        // plugin drops a run too close to its last, so restarting the clock
        // here could hold a Working Agent's next summary back a whole
        // interval.
        state = .refreshing(token: lastToken, restartsClock: periodic || periodicDue)
        effects.append(.startRefresh(token: lastToken, triggers: !isUnsupported))
        return effects
    }

    private mutating func finish(_ outcome: Outcome, restartsClock: Bool) -> [Effect] {
        state = .idle
        var effects: [Effect] = []
        switch outcome {
        case .refreshed: failures = 0
        case .unsupported: isUnsupported = true
        case .pluginMissing: effects.append(.reportPluginMissing)
        case .failed: failures += 1
        case .interrupted, .cancelled: break
        }
        switch outcome {
        case .cancelled, .refreshed where !restartsClock:
            break
        default:
            // Even an interrupted run restarts the clock: a dead link the
            // status still calls connected must not be retried at once.
            effects.append(.restartClock)
        }
        if outcome != .interrupted, outcome != .cancelled {
            effects.append(.cover)
        }
        effects.append(.updateRows)
        effects.append(.proceed(readsStore: outcome.readsStore))
        return effects
    }
}
