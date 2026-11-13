import Foundation

/// The hands-free conversation, including the previously unnamed introduction.
/// Presentation remains unchanged: introduction and finishing keep the last
/// visible phase; every completion is scoped to the step that requested it.
struct VoiceConversationMachine: StateMachine {
    typealias Phase = AgentVoiceConversation.Phase
    typealias End = AgentVoiceConversation.End
    enum State: Equatable, Sendable {
        case ready
        case introducing(UInt64)
        case listening(UInt64, followUp: Bool, quietSince: ContinuousClock.Instant)
        case sending(UInt64)
        case waiting(UInt64)
        case replying(UInt64)
        case announcing(UInt64)
        case finishing(UInt64, End, lastPhase: Phase, announcing: Bool)
        case ended(End)
    }
    enum Event: Sendable {
        case start
        case introduced(UInt64, now: ContinuousClock.Instant)
        case listened(UInt64, AgentVoiceService.ListenResult, isExit: Bool, now: ContinuousClock.Instant)
        case sent(UInt64, AgentVoiceService.SendResult)
        case replied(UInt64, AgentVoiceService.Reply)
        case spoken(UInt64)
        case announced(UInt64, now: ContinuousClock.Instant)
        case close(releasingAudio: Bool)
    }
    enum Effect: Equatable, Sendable {
        case introduce(UInt64)
        case phase(Phase)
        case listen(UInt64)
        case send(UInt64, String)
        case reply(UInt64, AgentVoiceService.ReplyCursor)
        case speak(UInt64, String)
        case announce(UInt64)
        case endAudio
        case stopAudio
        case cancelTask
        case clearTask
    }
    private(set) var state: State = .ready
    private var lastToken: UInt64 = 0
    let idle: Duration

    init(idle: Duration) { self.idle = idle }

    var phase: Phase? {
        switch state {
        case .ready, .introducing: nil
        case .listening(_, let followUp, _): .listening(followUp: followUp)
        case .sending: .sending
        case .waiting: .waiting
        case .replying, .announcing: .replying
        case .finishing(_, _, let phase, _): phase
        case .ended(let end): .ended(end)
        }
    }
    var isEnded: Bool { if case .ended = state { true } else { false } }

    mutating func handle(_ event: Event) -> [Effect] {
        // Terminal enter guard: no late async result can reopen a closed turn.
        if case .ended = state { return [] }
        switch (state, event) {
        case (_, .close(let releasing)):
            state = .ended(.driver)
            return [.cancelTask, releasing ? .endAudio : .stopAudio, .phase(.ended(.driver))]
        case (.ready, .start):
            lastToken += 1
            state = .introducing(lastToken)
            return [.introduce(lastToken)]
        case (.introducing(let token), .introduced(let current, let now)) where token == current:
            return beginListening(followUp: false, now: now)
        case (.listening(let token, let followUp, let since), .listened(let current, let result, let isExit, let now)) where token == current:
            switch result {
            case .heard(let text):
                if isExit {
                    return handle(.close(releasingAudio: true))
                }
                lastToken += 1
                state = .sending(lastToken)
                return [.phase(.sending), .send(lastToken, text)]
            case .silence:
                if since.duration(to: now) >= idle { return finish(.silence, saying: "") }
                lastToken += 1
                state = .listening(lastToken, followUp: followUp, quietSince: since)
                return [.listen(lastToken)]
            case .failed(let line): return finish(.finished, saying: line)
            }
        case (.sending(let token), .sent(let current, let result)) where token == current:
            switch result {
            case .failed(let line): return finish(.finished, saying: line)
            case .delivered(let cursor):
                lastToken += 1
                state = .waiting(lastToken)
                return [.phase(.waiting), .reply(lastToken, cursor)]
            }
        case (.waiting(let token), .replied(let current, let reply)) where token == current:
            switch reply {
            case .final(let line): return finish(.finished, saying: line)
            case .answer(let line):
                lastToken += 1
                state = .replying(lastToken)
                return [.phase(.replying), .speak(lastToken, line)]
            }
        case (.replying(let token), .spoken(let current)) where token == current:
            lastToken += 1
            state = .announcing(lastToken)
            return [.announce(lastToken)]
        case (.announcing(let token), .announced(let current, let now)) where token == current:
            return beginListening(followUp: true, now: now)
        case (.finishing(let token, let end, let phase, false), .spoken(let current)) where token == current:
            lastToken += 1
            state = .finishing(lastToken, end, lastPhase: phase, announcing: true)
            return [.announce(lastToken)]
        case (.finishing(let token, let end, _, true), .announced(let current, _)) where token == current:
            state = .ended(end)
            return [.endAudio, .clearTask, .phase(.ended(end))]
        case (.ready, _), (.introducing, _), (.listening, _), (.sending, _),
             (.waiting, _), (.replying, _), (.announcing, _), (.finishing, _), (.ended, _):
            return []
        }
    }

    private mutating func beginListening(followUp: Bool, now: ContinuousClock.Instant) -> [Effect] {
        lastToken += 1
        state = .listening(lastToken, followUp: followUp, quietSince: now)
        return [.phase(.listening(followUp: followUp)), .listen(lastToken)]
    }

    private mutating func finish(_ end: End, saying line: String) -> [Effect] {
        guard let phase else { return [] }
        lastToken += 1
        state = .finishing(lastToken, end, lastPhase: phase, announcing: line.isEmpty)
        return line.isEmpty ? [.announce(lastToken)] : [.speak(lastToken, line)]
    }
}
