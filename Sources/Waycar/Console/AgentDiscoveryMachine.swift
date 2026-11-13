import Foundation

/// New Agent's inventory read. Cached kinds remain usable through refresh,
/// cancellation and failure; only the current Host's current read may publish.
struct AgentDiscoveryMachine: StateMachine {
    struct Attempt: Equatable, Sendable {
        let token: UInt64
        let hostID: Host.ID
    }

    enum State: Equatable, Sendable {
        case idle
        case detecting(Attempt)
        case refreshing(Attempt, CachedAgentKinds)
        /// Switching Hosts clears the presentation, not the read. If the
        /// form switches back before it answers, the original guard accepts
        /// that Host's answer unless another discovery has superseded it.
        case detached(Attempt, hadCache: Bool)
        case live([SupportedAgentKind])
        case cached(CachedAgentKinds)
        case failed(String)
    }

    enum Event: Equatable, Sendable {
        case reset
        case begin(Host.ID?, CachedAgentKinds?)
        case loaded(Attempt, [SupportedAgentKind])
        case cancelled(Attempt)
        case failed(Attempt, String)
    }

    enum Effect: Equatable, Sendable {
        case clearSelection
        /// Selection is form state: the owner preserves an offered explicit
        /// pick, or applies Last Used/quick chat/preset defaults as before.
        case applyKinds([SupportedAgentKind], Host.ID, preservesLoadedPick: Bool)
        case detect(Attempt)
    }

    private(set) var state: State = .idle
    private var lastToken: UInt64 = 0

    var kinds: [SupportedAgentKind] {
        switch state {
        case .live(let kinds): kinds
        case .refreshing(_, let cached), .cached(let cached): cached.kinds
        case .idle, .detecting, .detached, .failed: []
        }
    }

    var cachedKinds: CachedAgentKinds? {
        switch state {
        case .refreshing(_, let cached), .cached(let cached): cached
        case .idle, .detecting, .detached, .live, .failed: nil
        }
    }

    var isLoaded: Bool {
        switch state {
        case .refreshing, .cached, .live: true
        case .idle, .detecting, .detached, .failed: false
        }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .reset:
            switch state {
            case .detecting(let attempt): state = .detached(attempt, hadCache: false)
            case .refreshing(let attempt, _): state = .detached(attempt, hadCache: true)
            case .detached: break
            case .idle, .live, .cached, .failed: state = .idle
            }
            return []
        case .begin(let hostID, let cached):
            guard let hostID else {
                state = .idle
                return [.clearSelection]
            }
            lastToken += 1
            let attempt = Attempt(token: lastToken, hostID: hostID)
            let preservesPick = isLoaded
            if let cached {
                state = .refreshing(attempt, cached)
                return [.applyKinds(cached.kinds, hostID, preservesLoadedPick: preservesPick), .detect(attempt)]
            }
            state = .detecting(attempt)
            return [.clearSelection, .detect(attempt)]
        case .loaded(let attempt, let kinds):
            switch state {
            case .detecting(let current), .refreshing(let current, _), .detached(let current, _):
                guard current == attempt else { return [] }
                let preservesPick = isLoaded
                state = .live(kinds)
                return [.applyKinds(kinds, attempt.hostID, preservesLoadedPick: preservesPick)]
            case .idle, .live, .cached, .failed:
                return []
            }
        case .cancelled(let attempt), .failed(let attempt, _):
            switch state {
            case .refreshing(let current, let cached) where current == attempt:
                state = .cached(cached)
            case .detecting(let current) where current == attempt:
                if case .failed(_, let message) = event { state = .failed(message) }
                else { state = .idle }
            case .detached(let current, let hadCache) where current == attempt:
                if !hadCache, case .failed(_, let message) = event { state = .failed(message) }
                else { state = .idle }
            case .idle, .detecting, .refreshing, .detached, .live, .cached, .failed:
                break
            }
            return []
        }
    }
}
