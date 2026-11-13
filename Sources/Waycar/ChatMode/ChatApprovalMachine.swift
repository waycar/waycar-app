import Foundation

/// The prompt the Chat card shows and the one answer it currently owns.
/// Terminal answers retain their exact screen guard; structured answers are
/// never queued. The shared read coalescer remains in ChatTranscriptStore.
struct ChatApprovalMachine: StateMachine, Equatable {
    enum Screen: Equatable, Sendable {
        case reading
        case unreadable
        case prompt(String)

        var text: String? {
            if case .prompt(let text) = self { return text }
            return nil
        }
    }

    enum ScreenAnswer: Equatable, Sendable {
        case ready
        case checking(token: UInt64, shown: String)
        case answered(token: UInt64, shown: String)
        /// Stop invalidates the attempt but keeps the answered card disabled
        /// until a restart or a different prompt, as before.
        case invalidated(shown: String)

        var shown: String? {
            switch self {
            case .ready: nil
            case .checking(_, let shown), .answered(_, let shown), .invalidated(let shown): shown
            }
        }
    }

    enum Recheck: Equatable, Sendable {
        case idle
        case waiting(UInt64)
    }

    enum Requests: Equatable, Sendable {
        case known([AgentPendingRequest])
        /// A read failure deliberately retains the last-known cards.
        case unreadable([AgentPendingRequest])

        var items: [AgentPendingRequest] {
            switch self {
            case .known(let items), .unreadable(let items): items
            }
        }
    }

    enum RequestAnswer: Equatable, Sendable {
        case ready(failed: Bool)
        case sending(token: UInt64, id: String)
        /// The single-flight claim lasts through the post-answer transcript
        /// refresh, not just through the write.
        case refreshing(token: UInt64, failed: Bool)
        case invalidated(failed: Bool)

        var failed: Bool {
            switch self {
            case .ready(let failed), .refreshing(_, let failed), .invalidated(let failed): failed
            case .sending: false
            }
        }
    }

    enum State: Equatable, Sendable {
        case terminal(Screen, ScreenAnswer, Recheck)
        case structured(Requests, RequestAnswer)
    }

    enum Reset: Equatable, Sendable {
        case start
        case statusChanged
        case clear
    }

    enum Event: Equatable, Sendable {
        case reset(Reset)
        case stop
        case retry
        case screenRead(String?)
        case requestsRead([AgentPendingRequest]?)
        case answerScreen
        case screenAnswered(UInt64, BlockedPromptAnswerer.Outcome)
        case recheckElapsed(UInt64)
        case answerRequest(String, AgentRequestAnswer)
        /// Both success and resolved-elsewhere remove the card. A failed
        /// send keeps it, with no automatic second answer.
        case requestAnswered(UInt64, resolved: Bool)
        case requestRefreshed(UInt64)
    }

    enum Effect: Equatable, Sendable {
        case checkScreen(UInt64, shown: String)
        case sendRequest(UInt64, id: String, answer: AgentRequestAnswer)
        case armRecheck(UInt64)
        case cancelRecheck
        case refreshScreen
        case refreshAfterRequest(UInt64)
    }

    private(set) var state: State
    private var lastToken: UInt64 = 0

    init(structured: Bool = false) {
        state = structured ? .structured(.known([]), .ready(failed: false)) : .terminal(.reading, .ready, .idle)
    }

    var screen: String? {
        if case .terminal(let display, _, _) = state { return display.text }
        return nil
    }

    var screenUnreadable: Bool {
        if case .terminal(.unreadable, _, _) = state { return true }
        return false
    }

    var requests: [AgentPendingRequest] {
        if case .structured(let display, _) = state { return display.items }
        return []
    }

    var requestsUnreadable: Bool {
        if case .structured(.unreadable, _) = state { return true }
        return false
    }

    var requestAnswerFailed: Bool {
        if case .structured(_, let answer) = state { return answer.failed }
        return false
    }

    var isAnswering: Bool {
        switch state {
        case .terminal(_, .ready, _), .structured(_, .ready): false
        case .terminal, .structured: true
        }
    }

    func wantsScreenAnswer(_ token: UInt64, shown: String) -> Bool {
        switch state {
        case .terminal(_, .checking(let current, let prompt), _),
             .terminal(_, .answered(let current, let prompt), _): current == token && prompt == shown
        case .terminal, .structured: false
        }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.terminal(let display, _, let recheck), .reset(let reason)):
            state = .terminal(reason == .statusChanged ? display : .reading, .ready,
                              reason == .clear ? .idle : recheck)
            return reason == .clear ? [.cancelRecheck] : []
        case (.structured(let display, let answer), .reset(let reason)):
            state = .structured(reason == .clear ? .known([]) : display,
                                .ready(failed: reason == .clear ? false : answer.failed))
            return []
        case (.terminal(let display, let answer, _), .stop):
            let next: ScreenAnswer = answer.shown.map { .invalidated(shown: $0) } ?? .ready
            state = .terminal(display, next, .idle)
            return [.cancelRecheck]
        case (.structured(let display, let answer), .stop):
            state = .structured(display, isAnswering ? .invalidated(failed: answer.failed) : answer)
            return []
        case (.terminal(let display, let answer, let recheck), .retry):
            state = .terminal(display == .unreadable ? .reading : display, answer, recheck)
            return []
        case (.structured(let display, let answer), .retry):
            let next: RequestAnswer
            switch answer {
            case .ready: next = .ready(failed: false)
            case .refreshing(let token, _): next = .refreshing(token: token, failed: false)
            case .invalidated: next = .invalidated(failed: false)
            case .sending: next = answer
            }
            state = .structured(display, next)
            return []
        case (.terminal(_, let answer, let recheck), .screenRead(let text)):
            let next = text != nil && answer.shown != nil && text != answer.shown ? .ready : answer
            state = .terminal(text.map(Screen.prompt) ?? .unreadable, next, recheck)
            return []
        case (.structured(let display, let answer), .requestsRead(let items)):
            state = .structured(items.map(Requests.known) ?? .unreadable(display.items), answer)
            return []
        case (.terminal(.prompt(let shown), .ready, let recheck), .answerScreen):
            lastToken += 1
            state = .terminal(.prompt(shown), .checking(token: lastToken, shown: shown), recheck)
            return [.checkScreen(lastToken, shown: shown)]
        case (.terminal(let display, .checking(let token, let shown), let recheck),
              .screenAnswered(let received, let outcome)) where token == received:
            switch outcome {
            case .sent:
                lastToken += 1
                state = .terminal(display, .answered(token: token, shown: shown), .waiting(lastToken))
                return [.cancelRecheck, .armRecheck(lastToken)]
            case .promptChanged(let current):
                state = .terminal(current.map(Screen.prompt) ?? .unreadable, .ready, recheck)
            case .cancelled, .sendFailed, .queued, .unreachable:
                state = .terminal(display, .ready, recheck)
            case .abandoned, .busy, .refused:
                break
            }
            return []
        case (.terminal(let display, let answer, .waiting(let token)), .recheckElapsed(let received))
            where token == received:
            let answering = isAnswering
            state = .terminal(display, answer, .idle)
            return answering ? [.refreshScreen] : []
        case (.structured(let display, .ready), .answerRequest(let id, let answer))
            where display.items.contains(where: { $0.id == id }):
            lastToken += 1
            state = .structured(display, .sending(token: lastToken, id: id))
            return [.sendRequest(lastToken, id: id, answer: answer)]
        case (.structured(let display, .sending(let token, let id)),
              .requestAnswered(let received, let resolved)) where token == received:
            let remaining = resolved ? display.items.filter { $0.id != id } : display.items
            let next: Requests
            switch display {
            case .known: next = .known(remaining)
            case .unreadable: next = .unreadable(remaining)
            }
            state = .structured(next, .refreshing(token: token, failed: !resolved))
            return [.refreshAfterRequest(token)]
        case (.structured(let display, .refreshing(let token, let failed)), .requestRefreshed(let received))
            where token == received:
            state = .structured(display, .ready(failed: failed))
            return []
        case (.terminal, .requestsRead), (.terminal, .answerRequest),
             (.terminal, .requestAnswered), (.terminal, .requestRefreshed),
             (.terminal, .answerScreen), (.terminal, .screenAnswered), (.terminal, .recheckElapsed),
             (.structured, .screenRead), (.structured, .answerScreen),
             (.structured, .screenAnswered), (.structured, .recheckElapsed),
             (.structured, .answerRequest), (.structured, .requestAnswered), (.structured, .requestRefreshed):
            return []
        }
    }
}
