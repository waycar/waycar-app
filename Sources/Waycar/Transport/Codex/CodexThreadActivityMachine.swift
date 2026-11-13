/// One Codex thread's activity as the server broadcasts it (CODEX-04): a turn
/// running (`active`, Blocked while it waits on an approval or an answer),
/// `idle`, or any other status. Done is an idle thread whose turn this
/// connection saw end, until the user opens it; a status in between (a
/// `systemError`) keeps it, and an idle never seen active is not Done.
///
/// The raw status rides on each state: a change of flags alone is still a
/// change the Console hears about.
struct CodexThreadActivityMachine: StateMachine, Equatable {
    enum Phase: Equatable, Sendable {
        case active(status: JSONValue)
        case idle(status: JSONValue, done: Bool)
        case other(status: JSONValue, done: Bool)
    }

    struct State: Equatable, Sendable {
        var phase: Phase
        /// A preview, or a turn seen to start: the thread has a conversation.
        var hasTurns: Bool
    }

    enum Event: Equatable, Sendable {
        case statusChanged(JSONValue)
        case turnStarted
        /// The user opened the thread.
        case acknowledged
    }

    enum Effect: Equatable, Sendable {
        /// No turn runs: forget the known active turn.
        case forgetTurn
        /// Not Blocked: its pending requests are gone.
        case dropRequests
        case publish
        /// Blocked: subscribe to receive its requests.
        case resumeBlocked
    }

    private(set) var state: State

    init(status: JSONValue, hasTurns: Bool) {
        state = State(phase: Self.phase(status, done: false), hasTurns: hasTurns)
    }

    var status: JSONValue {
        switch state.phase {
        case .active(let status), .idle(let status, _), .other(let status, _): status
        }
    }

    var isActive: Bool {
        if case .active = state.phase { return true }
        return false
    }

    var isDone: Bool {
        switch state.phase {
        case .active: false
        case .idle(_, let done), .other(_, let done): done
        }
    }

    var agentStatus: AgentStatus {
        switch state.phase {
        case .active(let status):
            let flags = status["activeFlags"]?.codexArray ?? []
            return flags.contains(.string("waitingOnApproval")) || flags.contains(.string("waitingOnUserInput"))
                ? .blocked : .working
        case .idle(_, let done): return done ? .done : .idle
        case .other: return .unknown
        }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .statusChanged(let status):
            guard status != self.status else { return [] }
            let done: Bool
            switch state.phase {
            case .active: done = status["type"]?.stringValue == "idle"
            case .idle(_, let was), .other(_, let was): done = was
            }
            state.phase = Self.phase(status, done: done)
            if isActive { state.hasTurns = true }
            var effects: [Effect] = []
            if !isActive { effects.append(.forgetTurn) }
            if agentStatus != .blocked { effects.append(.dropRequests) }
            effects.append(.publish)
            if agentStatus == .blocked { effects.append(.resumeBlocked) }
            return effects
        case .turnStarted:
            state.hasTurns = true
            return []
        case .acknowledged:
            guard isDone else { return [] }
            switch state.phase {
            case .active: return []
            case .idle(let status, _): state.phase = .idle(status: status, done: false)
            case .other(let status, _): state.phase = .other(status: status, done: false)
            }
            return [.publish]
        }
    }

    private static func phase(_ status: JSONValue, done: Bool) -> Phase {
        switch status["type"]?.stringValue {
        case "active": .active(status: status)
        case "idle": .idle(status: status, done: done)
        default: .other(status: status, done: done)
        }
    }
}
