import Foundation

/// One serial offline-copy pass, its attempt/Host cooldowns, and the next wake.
/// Cancellation retains attempt history but invalidates all late outcomes.
struct TranscriptPrefetchMachine: StateMachine {
    struct Candidate: Equatable, Sendable {
        let id: ConsoleAgent.ID
        let savedAt: Date?
    }

    enum State: Equatable, Sendable {
        case idle
        case running(token: UInt64)
        case waiting(token: UInt64, until: Date)
    }

    enum Event: Equatable, Sendable {
        case update(active: Bool, hasDue: Bool, now: Date, nextWake: Date?)
        case attempted(UInt64, ConsoleAgent.ID, now: Date)
        case unreadable(UInt64, Host.ID, now: Date)
        case ended(UInt64, active: Bool, now: Date, nextWake: Date?)
        case woke(UInt64)
        case cancel
    }

    enum Effect: Equatable, Sendable {
        case run(UInt64)
        case sleep(UInt64, Duration)
        case cancel(UInt64)
        case update
    }

    private(set) var state: State = .idle
    private var lastToken: UInt64 = 0
    private var attempts: [ConsoleAgent.ID: Date] = [:]
    private var unreadableHosts: [Host.ID: Date] = [:]
    static let cooldown: TimeInterval = 600

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    func ownsPass(_ token: UInt64) -> Bool { state == .running(token: token) }

    /// The owner keeps its lazy saved-copy lookup: no disk lookup for a
    /// cooling Agent, and no scan beyond the first due Agent.
    func canTry(_ id: ConsoleAgent.ID, now: Date) -> Bool {
        if let seen = unreadableHosts[id.hostID], now.timeIntervalSince(seen) < Self.cooldown { return false }
        if let tried = attempts[id], now.timeIntervalSince(tried) < Self.cooldown { return false }
        return true
    }

    func nextWake(for candidates: [Candidate], now: Date) -> Date? {
        candidates.map { candidate in
            let last = [candidate.savedAt, attempts[candidate.id], unreadableHosts[candidate.id.hostID]]
                .compactMap { $0 }.max() ?? now
            return last.addingTimeInterval(Self.cooldown)
        }.min()
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (_, .cancel), (_, .update(active: false, hasDue: _, now: _, nextWake: _)):
            let effects: [Effect]
            switch state {
            case .idle: effects = []
            case .running(let token), .waiting(let token, _): effects = [.cancel(token)]
            }
            state = .idle
            return effects
        case (.running, .update):
            return []
        case (.idle, .update(_, let hasDue, let now, let nextWake)):
            return advance(hasDue: hasDue, now: now, nextWake: nextWake)
        case (.waiting(let token, _), .update(_, let hasDue, let now, let nextWake)):
            return [.cancel(token)] + advance(hasDue: hasDue, now: now, nextWake: nextWake)
        case (.running(let token), .attempted(let received, let id, let now)) where token == received:
            attempts[id] = now
            return []
        case (.running(let token), .unreadable(let received, let host, let now)) where token == received:
            unreadableHosts[host] = now
            return []
        case (.running(let token), .ended(let received, let active, let now, let nextWake)) where token == received:
            state = .idle
            return active ? advance(hasDue: false, now: now, nextWake: nextWake) : []
        case (.waiting(let token, _), .woke(let received)) where token == received:
            state = .idle
            return [.update]
        case (.idle, .attempted), (.idle, .unreadable), (.idle, .ended), (.idle, .woke),
             (.running, .attempted), (.running, .unreadable), (.running, .ended), (.running, .woke),
             (.waiting, .attempted), (.waiting, .unreadable), (.waiting, .ended), (.waiting, .woke):
            return []
        }
    }

    private mutating func advance(hasDue: Bool, now: Date, nextWake: Date?) -> [Effect] {
        if hasDue {
            lastToken += 1
            state = .running(token: lastToken)
            return [.run(lastToken)]
        }
        guard let nextWake else {
            state = .idle
            return []
        }
        lastToken += 1
        state = .waiting(token: lastToken, until: nextWake)
        return [.sleep(lastToken, .seconds(max(0, nextWake.timeIntervalSince(now))))]
    }
}
