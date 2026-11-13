import Foundation

/// A single-flight Latest read and its one delayed stale follow-up. Cached
/// text survives failures; the timer and every completion belong to a token.
/// A reload started while a follow-up is scheduled keeps that timer
/// (`pendingTimer`): it is dropped if it elapses mid-read, as the read in
/// flight already asks, and outlives a failed reload, which kept the text.
struct WatchLatestMachine: StateMachine {
    enum State: Equatable, Sendable {
        case resting(WatchRead<WatchLatest?>)
        case reading(
            token: UInt64, previous: WatchRead<WatchLatest?>, recheck: Bool, pendingTimer: UInt64?)
        case scheduled(WatchLatest, timer: UInt64)
    }
    enum Event: Equatable, Sendable {
        case load
        case finished(UInt64, WatchRead<WatchLatest?>)
        case recheckElapsed(UInt64)
    }
    enum Effect: Equatable, Sendable {
        case read(UInt64)
        case scheduleRecheck(UInt64)
    }
    private(set) var state: State = .resting(.idle)
    private var lastToken: UInt64 = 0

    var read: WatchRead<WatchLatest?> {
        switch state {
        case .resting(let read): read
        case .scheduled(let latest, _): .loaded(latest)
        case .reading(_, let previous, _, _):
            if case .loaded = previous { previous } else { .loading }
        }
    }

    var isChecking: Bool {
        switch state {
        case .scheduled: return true
        case .reading(_, let previous, _, _):
            if case .loaded(let latest?) = previous { return latest.isStale }
            return false
        case .resting: return false
        }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.resting(let read), .load):
            return start(previous: read, recheck: false, pendingTimer: nil)
        case (.scheduled(let latest, let timer), .load):
            return start(previous: .loaded(latest), recheck: false, pendingTimer: timer)
        case (.scheduled(let latest, let timer), .recheckElapsed(let token)):
            guard timer == token else { return [] }
            return start(previous: .loaded(latest), recheck: true, pendingTimer: nil)
        case (.reading(let token, let previous, let recheck, let pending), .recheckElapsed(let elapsed)):
            guard pending == elapsed else { return [] }
            state = .reading(token: token, previous: previous, recheck: recheck, pendingTimer: nil)
            return []
        case (.reading(let token, let previous, let recheck, let pending), .finished(let completed, let result)):
            guard token == completed else { return [] }
            if case .loaded(let latest?) = result, latest.isStale, !recheck {
                lastToken += 1
                state = .scheduled(latest, timer: lastToken)
                return [.scheduleRecheck(lastToken)]
            }
            if case .failed = result, case .loaded(let kept) = previous {
                if let pending, let kept {
                    state = .scheduled(kept, timer: pending)
                } else {
                    state = .resting(previous)
                }
            } else { state = .resting(result) }
            return []
        case (.resting, _), (.reading, _), (.scheduled, _): return []
        }
    }

    private mutating func start(
        previous: WatchRead<WatchLatest?>, recheck: Bool, pendingTimer: UInt64?
    ) -> [Effect] {
        lastToken += 1
        state = .reading(
            token: lastToken, previous: previous, recheck: recheck, pendingTimer: pendingTimer)
        return [.read(lastToken)]
    }
}
