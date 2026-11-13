/// One Host's checks and its coalesced rerun. Invalidated work stays running
/// until its owner unwinds, but cannot publish or take another remote step.
struct HostChecksMachine: StateMachine {
    struct Facts: Equatable, Sendable {
        var report: PreflightReport?
        var serverInfo: ServerInfo?
        var presence: HostBackendPresence?
        var statusHooks: StatusHooksState?
        var sessions: [HerdrSession] = []
        var discoveryError: String?
    }

    struct Run: Equatable, Sendable {
        let token: UInt64
        var rerun = false
        var facts: Facts
    }

    enum State: Equatable, Sendable {
        case idle(enabled: Bool, Facts)
        case detecting(Run)
        case checking(Run)
        case invalidated(Run, enabled: Bool)
        case finished(enabled: Bool, Facts)
    }

    enum Event: Equatable, Sendable {
        case request
        case detected(UInt64, HostBackendPresence)
        /// Synchronous publication; the owner checks `accepts` after awaits.
        case factsChanged(Facts)
        case ended(UInt64)
        case enabled(Bool)
    }

    enum Effect: Equatable, Sendable {
        case run(UInt64)
    }

    private(set) var state: State
    private var lastToken: UInt64 = 0

    init(enabled: Bool, presence: HostBackendPresence? = nil) {
        state = .idle(enabled: enabled, Facts(presence: presence))
    }

    var facts: Facts {
        switch state {
        case .idle(_, let facts), .finished(_, let facts): facts
        case .detecting(let run), .checking(let run), .invalidated(let run, _): run.facts
        }
    }

    var isEnabled: Bool {
        switch state {
        case .idle(let enabled, _), .finished(let enabled, _), .invalidated(_, let enabled): enabled
        case .detecting, .checking: true
        }
    }

    var isRunning: Bool {
        switch state {
        case .idle, .finished: false
        case .detecting, .checking, .invalidated: true
        }
    }

    var hasFinished: Bool {
        if case .finished = state { return true }
        return false
    }

    func accepts(_ token: UInt64) -> Bool {
        switch state {
        case .detecting(let run), .checking(let run): run.token == token
        case .idle, .finished, .invalidated: false
        }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.idle(true, _), .request), (.finished(true, _), .request):
            return begin()
        case (.detecting(var run), .request):
            run.rerun = true
            state = .detecting(run)
            return []
        case (.checking(var run), .request):
            run.rerun = true
            state = .checking(run)
            return []
        case (.invalidated(var run, true), .request):
            run.rerun = true
            state = .invalidated(run, enabled: true)
            return []
        case (.detecting(var run), .detected(let token, let presence)) where run.token == token:
            run.facts.presence = presence
            state = .checking(run)
            return []
        case (.idle(let enabled, _), .factsChanged(let facts)):
            state = .idle(enabled: enabled, facts)
            return []
        case (.finished(let enabled, _), .factsChanged(let facts)):
            state = .finished(enabled: enabled, facts)
            return []
        case (.detecting(var run), .factsChanged(let facts)):
            run.facts = facts
            state = .detecting(run)
            return []
        case (.checking(var run), .factsChanged(let facts)):
            run.facts = facts
            state = .checking(run)
            return []
        case (.invalidated(var run, let enabled), .factsChanged(let facts)):
            run.facts = facts
            state = .invalidated(run, enabled: enabled)
            return []
        case (.detecting(let run), .ended(let token)), (.checking(let run), .ended(let token)):
            guard run.token == token else { return [] }
            if run.rerun { return begin() }
            state = .finished(enabled: true, run.facts)
            return []
        case (.invalidated(let run, let enabled), .ended(let token)):
            guard run.token == token else { return [] }
            if run.rerun && enabled { return begin() }
            state = .finished(enabled: enabled, run.facts)
            return []
        case (.idle(_, let facts), .enabled(let enabled)):
            state = .idle(enabled: enabled, facts)
            return []
        case (.finished(_, let facts), .enabled(let enabled)):
            state = .finished(enabled: enabled, facts)
            return []
        case (.detecting(let run), .enabled(false)), (.checking(let run), .enabled(false)):
            state = .invalidated(run, enabled: false)
            return []
        case (.invalidated(let run, _), .enabled(let enabled)):
            state = .invalidated(run, enabled: enabled)
            return []
        case (.idle, _), (.detecting, _), (.checking, _), (.invalidated, _), (.finished, _):
            return []
        }
    }

    private mutating func begin() -> [Effect] {
        lastToken += 1
        state = .detecting(Run(token: lastToken, facts: Facts(presence: facts.presence)))
        return [.run(lastToken)]
    }
}
