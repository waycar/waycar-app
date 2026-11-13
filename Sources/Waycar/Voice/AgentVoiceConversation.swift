import Foundation

/// A hands-free back-and-forth with one Agent (docs/design/carplay.md §5
/// Conversation): listen, send what was heard as soon as the driver
/// pauses, speak the reply, then listen again on the same Agent, until
/// the driver closes the template, the car's screen moves on, a spoken
/// "stop" or "that's all", or nothing is said for `conversationIdle`.
/// No read-back, no Send. Half-duplex: a listen never starts before the
/// line before it finished speaking. The audio session stays up for the
/// whole conversation, the wait for each reply included. No UIKit or
/// CarPlay: `onPhase` tells the caller what to show.
@MainActor
final class AgentVoiceConversation {
    enum Phase: Equatable, Sendable {
        /// The microphone is open; `followUp` once a reply was spoken.
        case listening(followUp: Bool)
        case sending
        /// The question went out; the reply is awaited.
        case waiting
        case replying
        case ended(End)
    }

    enum End: Equatable, Sendable {
        /// A spoken "stop" or "that's all", the template closed, or the
        /// car's screen moved on.
        case driver
        /// Nothing was said for `conversationIdle`: the conversation is over.
        case silence
        /// The turn's last line was spoken (a failure, a reply that leaves
        /// nothing to ask).
        case finished
    }

    let agentID: ConsoleAgent.ID
    private let voice: AgentVoiceService
    private let onPhase: @MainActor (Phase) -> Void
    /// Says what queued up while the car spoke or listened (another Agent's
    /// Blocked push): after each reply line, before the next listen, and
    /// before a finishing conversation gives its audio back.
    private let announcePending: @MainActor () async -> Void
    private var conversation: VoiceConversationMachine
    private var tasks: [UInt64: Task<Void, Never>] = [:]

    var phase: Phase? { conversation.phase }
    var isEnded: Bool { conversation.isEnded }

    init(
        agentID: ConsoleAgent.ID, voice: AgentVoiceService,
        announcePending: @escaping @MainActor () async -> Void = {},
        onPhase: @escaping @MainActor (Phase) -> Void
    ) {
        self.agentID = agentID
        self.voice = voice
        self.announcePending = announcePending
        self.onPhase = onPhase
        conversation = VoiceConversationMachine(idle: voice.conversationIdle)
    }

    /// Status first, then the loop.
    func start() {
        let effects = conversation.handle(.start)
        guard case .introducing(let token) = conversation.state, !effects.isEmpty else { return }
        tasks[token] = Task { [weak self] in
            guard let self else { return }
            await self.perform(effects)
        }
    }

    /// The driver ended it (a spoken "stop", a close, the scene leaving
    /// the car's screen): stop at once, speak nothing. A question being
    /// sent and not out yet becomes the draft (`AgentVoiceService.send`).
    /// Reported as `.ended(.driver)`, which the caller closes at once.
    /// `releasingAudio` false leaves the session to a turn starting next.
    func end(releasingAudio: Bool = true) {
        for effect in conversation.handle(.close(releasingAudio: releasingAudio)) {
            performImmediate(effect)
        }
    }

    /// A loop, not recursive async calls: a long conversation retains no
    /// previous turns. Every await keeps the original cancellation guard.
    private func perform(_ initial: [VoiceConversationMachine.Effect]) async {
        var pending = initial
        while !pending.isEmpty {
            let effect = pending.removeFirst()
            let event: VoiceConversationMachine.Event
            switch effect {
            case .introduce(let token):
                voice.speaker.beginTurn()
                if let introduction = voice.introduction(for: agentID) {
                    await voice.speak(introduction)
                }
                guard !Task.isCancelled else { return }
                event = .introduced(token, now: .now)
            case .listen(let token):
                let result = await voice.listen()
                guard !Task.isCancelled else { return }
                let isExit: Bool
                if case .heard(let text) = result { isExit = AgentVoiceService.isConversationExit(text) }
                else { isExit = false }
                event = .listened(token, result, isExit: isExit, now: .now)
            case .send(let token, let text):
                let result = await voice.send(text, to: agentID)
                guard !Task.isCancelled else { return }
                event = .sent(token, result)
            case .reply(let token, let cursor):
                let result = await voice.reply(after: cursor)
                guard !Task.isCancelled else { return }
                event = .replied(token, result)
            case .speak(let token, let text):
                await voice.speak(text)
                guard !Task.isCancelled else { return }
                event = .spoken(token)
            case .announce(let token):
                await announcePending()
                guard !Task.isCancelled else { return }
                event = .announced(token, now: .now)
            case .phase, .endAudio, .stopAudio, .cancelTask, .clearTask:
                performImmediate(effect)
                continue
            }
            pending.append(contentsOf: conversation.handle(event))
        }
    }

    private func performImmediate(_ effect: VoiceConversationMachine.Effect) {
        switch effect {
        case .phase(let next): onPhase(next)
        case .endAudio: voice.endTurn()
        case .stopAudio: voice.speaker.stop()
        case .cancelTask:
            for task in tasks.values { task.cancel() }
            tasks.removeAll()
        case .clearTask: tasks.removeAll()
        case .introduce, .listen, .send, .reply, .speak, .announce:
            assertionFailure("Async conversation effect outside task")
        }
    }
}
