/// A server session owns a New Agent launch. Its optional terminal is a
/// separately reconciled half: definitive terminal failure leaves Chat usable,
/// but a lost answer or cancellation propagates for Launch Tag reconciliation.
struct ServerChatLaunchMachine: StateMachine {
    enum Terminal: Equatable, Sendable {
        case existing
        case unavailable
        case linked
        case failed
    }

    enum State: Equatable, Sendable {
        case idle
        case starting(UInt64)
        case choosingTerminal(UInt64, Agent)
        case openingTerminal(UInt64, Agent, HostBackend)
        case recordingMarker(UInt64, Agent, Agent, HostBackend)
        case ready(Agent, Terminal)
        case failed
        case uncertain(Agent?)
        case cancelled(Agent?)
    }

    enum Choice: Equatable, Sendable {
        case existing
        case unavailable
        case open(HostBackend)
    }

    enum Failure: Equatable, Sendable {
        case definitive
        case uncertain
        case cancelled
    }

    enum Event: Equatable, Sendable {
        case begin
        case sessionStarted(UInt64, Agent)
        case terminalChosen(UInt64, Choice)
        case terminalOpened(UInt64, Agent)
        case markerRecorded(UInt64)
        case failed(UInt64, Failure)
    }

    enum Effect: Equatable, Sendable {
        case startSession(UInt64)
        case chooseTerminal(UInt64, Agent)
        case openTerminal(UInt64, Agent, HostBackend)
        case recordMarker(UInt64, Agent, Agent, HostBackend)
        case showTerminalFailure(Agent)

        var token: UInt64? {
            switch self {
            case .startSession(let token), .chooseTerminal(let token, _),
                .openTerminal(let token, _, _), .recordMarker(let token, _, _, _): token
            case .showTerminalFailure: nil
            }
        }
    }

    private(set) var state: State = .idle
    private var lastToken: UInt64 = 0

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.idle, .begin):
            state = .starting(nextToken())
            return [.startSession(lastToken)]
        case (.starting(let current), .sessionStarted(let token, let session)) where current == token:
            let next = nextToken()
            state = .choosingTerminal(next, session)
            return [.chooseTerminal(next, session)]
        case (.choosingTerminal(let current, let session), .terminalChosen(let token, let choice))
            where current == token:
            switch choice {
            case .existing: state = .ready(session, .existing)
            case .unavailable: state = .ready(session, .unavailable)
            case .open(let backend):
                let next = nextToken()
                state = .openingTerminal(next, session, backend)
                return [.openTerminal(next, session, backend)]
            }
            return []
        case (.openingTerminal(let current, let session, let backend), .terminalOpened(let token, let pane))
            where current == token:
            let next = nextToken()
            state = .recordingMarker(next, session, pane, backend)
            return [.recordMarker(next, session, pane, backend)]
        case (.recordingMarker(let current, let session, _, _), .markerRecorded(let token)) where current == token:
            state = .ready(session, .linked)
            return []
        case (.starting(let current), .failed(let token, let failure)) where current == token:
            switch failure {
            case .definitive: state = .failed
            case .uncertain: state = .uncertain(nil)
            case .cancelled: state = .cancelled(nil)
            }
            return []
        case (.choosingTerminal(let current, let session), .failed(let token, let failure)),
            (.openingTerminal(let current, let session, _), .failed(let token, let failure)),
            (.recordingMarker(let current, let session, _, _), .failed(let token, let failure)):
            guard current == token else { return [] }
            switch failure {
            case .definitive:
                state = .ready(session, .failed)
                return [.showTerminalFailure(session)]
            case .uncertain: state = .uncertain(session)
            case .cancelled: state = .cancelled(session)
            }
            return []
        case (.idle, _), (.starting, _), (.choosingTerminal, _), (.openingTerminal, _),
            (.recordingMarker, _), (.ready, _), (.failed, _), (.uncertain, _), (.cancelled, _):
            return []
        }
    }

    private mutating func nextToken() -> UInt64 {
        lastToken += 1
        return lastToken
    }
}
