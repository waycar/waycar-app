import Foundation

/// Queue scheduling only: the owner chooses and delivers messages. Reconnect
/// and Agent wakes are distinct and consumed once per iteration. A direct
/// send can fail while a drain is running, so that drain may also own a retry
/// timer; this is a legal overlap, not an implicit second scheduler.
struct ComposerDrainMachine: StateMachine {
    enum Wake: Equatable, Sendable { case none, agent, reconnect }
    struct Retry: Equatable, Sendable { let token: UInt64 }
    enum State: Equatable, Sendable {
        case idle(failures: Int)
        case draining(UInt64, failures: Int, wake: Wake, retry: Retry?)
        case backingOff(Retry, failures: Int)
        case waitingForLaunch(Retry, failures: Int)
        case waitingForAgent(failures: Int)
        case cancelled
    }
    enum Outcome: Equatable, Sendable {
        case settled, waitsForAgent, notSent, waitsForLaunch
    }
    enum Event: Sendable {
        case wake(resetBackoff: Bool, hasQueuedRecord: Bool)
        case iterationStarted(UInt64)
        case attemptFinished(UInt64, Outcome, launchDelay: Duration)
        case ended(UInt64, clearFailures: Bool)
        case unsent
        case timerElapsed(UInt64, mayWake: Bool, hasQueuedRecord: Bool)
        case cancel
    }
    enum Effect: Equatable, Sendable {
        case start(UInt64)
        case continueDrain(UInt64)
        case finish(UInt64)
        case cancelDrain(UInt64)
        case armRetry(UInt64, after: Duration)
        case cancelRetry(UInt64)
    }

    private(set) var state: State = .idle(failures: 0)
    private var lastToken: UInt64 = 0

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.cancelled, _): return []
        case (_, .cancel):
            let effects = running.map { [Effect.cancelDrain($0)] } ?? []
            let timer = retry.map { [Effect.cancelRetry($0.token)] } ?? []
            state = .cancelled
            return effects + timer
        case (_, .wake(let reset, let queued)):
            return wake(reset: reset, queued: queued)
        case (.draining(let token, let failures, _, let retry), .iterationStarted(let id)) where token == id:
            state = .draining(token, failures: failures, wake: .none, retry: retry)
            return []
        case (.draining(let token, let failures, let wake, let retry), .attemptFinished(let id, let outcome, let launchDelay))
            where token == id:
            switch outcome {
            case .settled:
                return [.continueDrain(token)]
            case .waitsForAgent where wake != .none:
                return [.continueDrain(token)]
            case .notSent where wake == .reconnect:
                return [.continueDrain(token)]
            case .waitsForAgent:
                state = retry.map { .backingOff($0, failures: failures) } ?? .waitingForAgent(failures: failures)
                return [.finish(token)]
            case .notSent, .waitsForLaunch:
                let delay = outcome == .notSent ? Self.retryDelay(afterFailures: failures) : launchDelay
                let nextFailures = outcome == .notSent ? failures + 1 : failures
                let next = mintRetry()
                state = outcome == .notSent ? .backingOff(next, failures: nextFailures) : .waitingForLaunch(next, failures: nextFailures)
                return [.finish(token)] + (retry.map { [.cancelRetry($0.token)] } ?? []) + [.armRetry(next.token, after: delay)]
            }
        case (.draining(let token, let failures, _, let retry), .ended(let id, let clear)) where token == id:
            let count = clear ? 0 : failures
            state = retry.map { .backingOff($0, failures: count) } ?? .idle(failures: count)
            return [.finish(token)]
        case (_, .unsent):
            let count = failures
            let old = retry.map { [Effect.cancelRetry($0.token)] } ?? []
            let timer = mintRetry()
            if case .draining(let token, _, let wake, _) = state {
                state = .draining(token, failures: count + 1, wake: wake, retry: timer)
            } else {
                state = .backingOff(timer, failures: count + 1)
            }
            return old + [.armRetry(timer.token, after: Self.retryDelay(afterFailures: count))]
        case (_, .timerElapsed(let id, let mayWake, let queued)) where retry?.token == id:
            switch state {
            case .draining(let token, let failures, let wake, _):
                state = .draining(token, failures: failures, wake: wake, retry: nil)
            case .backingOff(_, let failures), .waitingForLaunch(_, let failures):
                state = .idle(failures: failures)
            case .idle, .waitingForAgent, .cancelled: break
            }
            return [.cancelRetry(id)] + (mayWake ? wake(reset: false, queued: queued) : [])
        case (.idle, _), (.draining, _), (.backingOff, _), (.waitingForLaunch, _), (.waitingForAgent, _):
            return []
        }
    }

    var isCancelled: Bool { state == .cancelled }
    private var running: UInt64? {
        if case .draining(let token, _, _, _) = state { return token }
        return nil
    }
    private var retry: Retry? {
        switch state {
        case .draining(_, _, _, let timer): timer
        case .backingOff(let timer, _), .waitingForLaunch(let timer, _): timer
        case .idle, .waitingForAgent, .cancelled: nil
        }
    }
    private var failures: Int {
        switch state {
        case .idle(let count), .draining(_, let count, _, _), .backingOff(_, let count),
             .waitingForLaunch(_, let count), .waitingForAgent(let count): count
        case .cancelled: 0
        }
    }
    private mutating func wake(reset: Bool, queued: Bool) -> [Effect] {
        if !reset && retry != nil { return [] }
        let effects = reset ? retry.map { [Effect.cancelRetry($0.token)] } ?? [] : []
        let count = reset ? 0 : failures
        if case .draining(let token, _, let pending, let retry) = state {
            state = .draining(token, failures: count,
                wake: reset || pending == .reconnect ? .reconnect : .agent,
                retry: reset ? nil : retry)
            return effects
        }
        guard queued else {
            state = .idle(failures: count)
            return effects
        }
        lastToken &+= 1
        state = .draining(lastToken, failures: count, wake: .none, retry: nil)
        return effects + [.start(lastToken)]
    }
    private mutating func mintRetry() -> Retry {
        lastToken &+= 1
        return Retry(token: lastToken)
    }
    static func retryDelay(afterFailures failures: Int) -> Duration {
        min(.seconds(2) * (1 << min(max(failures, 0), 16)), .seconds(300))
    }
}
