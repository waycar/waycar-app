import Foundation

/// One request's sends and ready-link deadline budget. Success from any
/// earlier attempt still wins; errors and timers must belong to current work.
struct WatchRequestMachine: StateMachine {
    enum State: Equatable, Sendable {
        case waiting(sends: Int, budget: Duration)
        case transmitting(sends: Int, budget: Duration, sentAt: ContinuousClock.Instant, timer: UInt64)
        case paused(sends: Int, budget: Duration)
        case finished
    }
    enum Event: Equatable, Sendable {
        case transmit(now: ContinuousClock.Instant)
        case pause(now: ContinuousClock.Instant)
        case resume(now: ContinuousClock.Instant)
        case lose(now: ContinuousClock.Instant)
        case reply
        case error(attempt: Int, unreachable: Bool, now: ContinuousClock.Instant)
        case deadline(UInt64)
        case unreachable
    }
    enum Completion: Equatable, Sendable { case reply, error, noAnswer, unreachable }
    enum Effect: Equatable, Sendable {
        case send(Int)
        case arm(UInt64, Duration)
        case stopTimer
        case cancelWork
        case forgetWork
        case complete(Completion)
        case doubtLink
    }
    private(set) var state: State
    private var lastTimer: UInt64 = 0
    private let maxSends: Int

    init(budget: Duration, maxSends: Int) {
        state = .waiting(sends: 0, budget: budget)
        self.maxSends = maxSends
    }
    var isInFlight: Bool {
        switch state {
        case .transmitting, .paused: true
        case .waiting, .finished: false
        }
    }
    var isPaused: Bool { if case .paused = state { true } else { false } }
    var sends: Int {
        switch state {
        case .waiting(let sends, _), .transmitting(let sends, _, _, _), .paused(let sends, _): sends
        case .finished: 0
        }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.waiting(let sends, let budget), .transmit(let now)):
            guard budget > .zero, sends < maxSends else { return finish(.noAnswer) }
            return [.send(sends + 1)] + arm(sends: sends + 1, budget: budget, now: now)
        case (.transmitting(let sends, let budget, let sentAt, _), .pause(let now)):
            state = .paused(sends: sends, budget: budget - (now - sentAt))
            return [.stopTimer]
        case (.paused(let sends, let budget), .resume(let now)):
            return arm(sends: sends, budget: budget, now: now)
        case (.transmitting(let sends, let budget, let sentAt, _), .lose(let now)):
            state = .waiting(sends: sends, budget: budget - (now - sentAt))
            return [.stopTimer, .cancelWork, .forgetWork]
        case (.paused(let sends, let budget), .lose):
            state = .waiting(sends: sends, budget: budget)
            return [.cancelWork, .forgetWork]
        case (.transmitting(let sends, _, _, _), .error(let attempt, let unreachable, let now)):
            guard sends == attempt else { return [] }
            if unreachable { return handle(.lose(now: now)) + [.doubtLink] }
            return finish(.error)
        case (.paused(let sends, _), .error(let attempt, _, let now)):
            guard sends == attempt else { return [] }
            return handle(.lose(now: now))
        case (.transmitting(_, _, _, let timer), .deadline(let token)):
            guard timer == token else { return [] }
            return [.cancelWork] + finish(.noAnswer)
        case (.waiting, .reply), (.transmitting, .reply), (.paused, .reply): return finish(.reply)
        case (.waiting, .unreachable), (.transmitting, .unreachable), (.paused, .unreachable):
            return finish(.unreachable)
        case (.waiting, _), (.transmitting, _), (.paused, _), (.finished, _): return []
        }
    }

    private mutating func arm(sends: Int, budget: Duration, now: ContinuousClock.Instant) -> [Effect] {
        lastTimer += 1
        state = .transmitting(sends: sends, budget: budget, sentAt: now, timer: lastTimer)
        return [.arm(lastTimer, budget)]
    }
    private mutating func finish(_ completion: Completion) -> [Effect] {
        state = .finished
        return [.stopTimer, .forgetWork, .complete(completion)]
    }
}
