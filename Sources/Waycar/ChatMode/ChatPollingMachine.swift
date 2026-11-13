import Foundation

/// Poll ownership and the bounded follow of a send whose Agent reports no
/// status change. Stop keeps the local follow, but invalidates its poll loop.
struct ChatPollingMachine: StateMachine {
    enum Follow: Equatable, Sendable {
        case none
        case waiting(deadline: ContinuousClock.Instant, knownAssistantIDs: Set<String>)
    }

    enum State: Equatable, Sendable {
        case stopped(Follow)
        case quiescent
        case polling(token: UInt64, follow: Follow)
    }

    enum Event: Equatable, Sendable {
        case configure(started: Bool, status: AgentStatus, turnOpen: Bool)
        case follow(deadline: ContinuousClock.Instant, knownAssistantIDs: Set<String>,
                    started: Bool, status: AgentStatus, turnOpen: Bool)
        case messagesChanged([ChatTranscriptMessage])
        case tick(UInt64, now: ContinuousClock.Instant, status: AgentStatus, turnOpen: Bool)
        case stop
    }

    enum Effect: Equatable, Sendable {
        case start(UInt64)
        case cancel(UInt64)
        case poll(readTranscript: Bool)
    }

    private(set) var state: State = .stopped(.none)
    private var lastToken: UInt64 = 0

    var pollToken: UInt64? {
        if case .polling(let token, _) = state { return token }
        return nil
    }

    private var follow: Follow {
        switch state {
        case .stopped(let follow), .polling(_, let follow): follow
        case .quiescent: .none
        }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (_, .configure(let started, let status, let turnOpen)):
            return configure(started: started, status: status, turnOpen: turnOpen, follow: follow)
        case (_, .follow(let deadline, let ids, let started, let status, let turnOpen)):
            return configure(started: started, status: status, turnOpen: turnOpen,
                             follow: .waiting(deadline: deadline, knownAssistantIDs: ids))
        case (.stopped(let follow), .messagesChanged(let messages)):
            state = .stopped(remainingFollow(follow, messages: messages))
            return []
        case (.polling(let token, let follow), .messagesChanged(let messages)):
            // Read completion reconciles demand after all coalesced reads,
            // rather than cancelling a loop in the middle of its read.
            state = .polling(token: token, follow: remainingFollow(follow, messages: messages))
            return []
        case (.quiescent, .messagesChanged):
            return []
        case (.polling(let token, let follow), .tick(let received, let now, let status, let turnOpen))
            where token == received:
            let next: Follow
            switch follow {
            case .waiting(let deadline, _) where now >= deadline: next = .none
            case .none, .waiting: next = follow
            }
            let effects = configure(started: true, status: status, turnOpen: turnOpen, follow: next)
            guard pollToken == token else { return effects }
            return [.poll(readTranscript: status == .working || turnOpen || next != .none)]
        case (.polling(let token, let follow), .stop):
            state = .stopped(follow)
            return [.cancel(token)]
        case (.quiescent, .stop):
            state = .stopped(.none)
            return []
        case (.stopped, .stop), (.stopped, .tick), (.quiescent, .tick), (.polling, .tick):
            return []
        }
    }

    private func remainingFollow(_ follow: Follow, messages: [ChatTranscriptMessage]) -> Follow {
        guard case .waiting(_, let known) = follow,
            messages.contains(where: { $0.role == .assistant && !known.contains($0.id) })
        else { return follow }
        return .none
    }

    private mutating func configure(started: Bool, status: AgentStatus, turnOpen: Bool, follow: Follow) -> [Effect] {
        let oldToken = pollToken
        let demanded = status == .working || status == .blocked || turnOpen || follow != .none
        guard started && demanded else {
            state = started ? .quiescent : .stopped(follow)
            return oldToken.map { [.cancel($0)] } ?? []
        }
        if let oldToken {
            state = .polling(token: oldToken, follow: follow)
            return []
        }
        lastToken += 1
        state = .polling(token: lastToken, follow: follow)
        return [.start(lastToken)]
    }
}
