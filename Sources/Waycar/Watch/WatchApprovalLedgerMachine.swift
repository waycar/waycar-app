import Foundation

/// Shown prompts are consumed once. Concurrent repeats join the first answer;
/// failed host admission restores only when no newer readable prompt exists.
struct WatchApprovalLedgerMachine: StateMachine {
    struct Prompt: Equatable, Sendable {
        let agentID: ConsoleAgent.ID
        let snapshot: BlockedPromptSnapshot
    }

    enum Record: Equatable, Sendable {
        case available(Prompt)
        case answering(token: UInt64, prompt: Prompt, choice: WatchAnswer)
        case answered(token: UInt64, choice: WatchAnswer, reply: WatchReply)
    }

    struct State: Equatable, Sendable {
        var records: [UUID: Record] = [:]
        var promptOrder: [UUID] = []
        var answerOrder: [UUID] = []
    }

    enum Event: Sendable {
        case read(UUID, Prompt)
        case answer(UUID, ConsoleAgent.ID, WatchAnswer, unlocked: Bool)
        case hostFailed(UUID, token: UInt64)
        case completed(UUID, token: UInt64, reply: WatchReply, keep: Bool)
    }

    enum Effect: Equatable, Sendable {
        case start(UInt64, Prompt, WatchAnswer)
        case join(UInt64, sameChoice: Bool)
        case reply(WatchReply)
        case unlockRequired
        case forgetTask(UInt64)
    }

    private(set) var state = State()
    private var lastToken: UInt64 = 0
    let memoryLimit: Int

    init(memoryLimit: Int = 64) { self.memoryLimit = memoryLimit }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .read(let id, let prompt):
            let earlier = state.records.compactMap { key, value -> UUID? in
                if case .available(let kept) = value, kept.agentID == prompt.agentID { return key }
                return nil
            }
            for key in earlier { state.records[key] = nil }
            state.promptOrder.removeAll { earlier.contains($0) }
            state.records[id] = .available(prompt)
            state.promptOrder.append(id)
            if state.promptOrder.count > memoryLimit {
                state.records[state.promptOrder.removeFirst()] = nil
            }
            return []
        case .answer(let id, let agent, let choice, let unlocked):
            switch state.records[id] {
            case .answering(let token, _, let first), .answered(let token, let first, _):
                return [.join(token, sameChoice: first == choice)]
            case .available(let prompt):
                guard prompt.agentID == agent else { return [.reply(.answerResult(.promptChanged))] }
                guard unlocked else { return [.unlockRequired] }
                lastToken += 1
                state.records[id] = .answering(token: lastToken, prompt: prompt, choice: choice)
                state.promptOrder.removeAll { $0 == id }
                state.answerOrder.append(id)
                var effects: [Effect] = [.start(lastToken, prompt, choice)]
                if state.answerOrder.count > memoryLimit {
                    let oldest = state.answerOrder.removeFirst()
                    if let token = token(for: oldest) { effects.append(.forgetTask(token)) }
                    state.records[oldest] = nil
                }
                return effects
            case nil:
                return [.reply(.answerResult(.promptChanged))]
            }
        case .hostFailed(let id, let token):
            guard case .answering(let current, let prompt, _) = state.records[id], current == token else { return [] }
            state.records[id] = nil
            state.answerOrder.removeAll { $0 == id }
            let newer = state.records.values.contains {
                if case .available(let kept) = $0 { return kept.agentID == prompt.agentID }
                return false
            }
            if !newer {
                state.records[id] = .available(prompt)
                state.promptOrder.append(id)
            }
            return [.forgetTask(token)]
        case .completed(let id, let token, let reply, let keep):
            guard case .answering(let current, _, let choice) = state.records[id], current == token else { return [] }
            if keep {
                state.records[id] = .answered(token: token, choice: choice, reply: reply)
                return []
            }
            state.records[id] = nil
            state.answerOrder.removeAll { $0 == id }
            return [.forgetTask(token)]
        }
    }

    private func token(for id: UUID) -> UInt64? {
        switch state.records[id] {
        case .answering(let token, _, _), .answered(let token, _, _): token
        case .available, nil: nil
        }
    }
}
