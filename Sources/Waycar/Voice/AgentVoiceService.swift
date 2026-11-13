import Foundation

/// Speech output for a voice turn. `CarSpeaker` speaks through the car;
/// tests use a fake.
@MainActor
protocol AgentVoiceSpeaker: AnyObject {
    /// A driver-started turn begins: its audio session may activate now.
    func beginTurn()
    /// Speaks `text` and returns once it finished or was stopped: true
    /// only when the whole line was heard.
    @discardableResult
    func speak(_ text: String) async -> Bool
    /// Stops speaking at once.
    func stop()
    /// Ends the turn and gives the audio back.
    func endTurn()
}

/// The voice loop over the Console, shared by CarPlay now and App Intents
/// later (docs/design/carplay.md §6): listening, the question to an Agent
/// and its spoken reply, and the Blocked turn with the car's approval
/// rules. No UIKit or CarPlay: it speaks and listens, and returns what to
/// say; the caller decides what the screen shows (never content).
///
/// Every line it returns is speakable and never asks the driver to handle
/// the iPhone (§5 rule 10).
@MainActor
final class AgentVoiceService {
    /// Endpointing and wait bounds; tests shorten them.
    struct Timing: Sendable {
        /// Silence after speech that ends an utterance; a conversation
        /// sends what was heard then, with no read-back.
        var endOfSpeech: Duration = .milliseconds(1500)
        /// Give up when nothing was said for this long.
        var noSpeech: Duration = .seconds(8)
        /// Hard cap on one utterance.
        var maximumListen: Duration = .seconds(20)
        /// The microphone must open within this (model prepared, session up).
        var startup: Duration = .seconds(15)
        var listenTick: Duration = .milliseconds(100)
        /// The Send/Cancel listen after a correction's read-back: silence
        /// means cancel.
        var confirmNoSpeech: Duration = .seconds(6)
        /// Quiet between a line finishing and the microphone opening, so
        /// the car's speakers have stopped ringing out the reply's tail.
        var speechSettle: Duration = .milliseconds(300)
        var replyPoll: Duration = .seconds(2)
        /// How long a question waits for its reply.
        var replyTimeout: Duration = .seconds(120)
        /// After the Agent finishes, how long to wait for its reply or a new
        /// Agent Summary before saying it finished.
        var finishGrace: Duration = .seconds(15)
        /// A conversation listens again through silences until nothing was
        /// said for this long.
        var conversationIdle: Duration = .seconds(120)
        /// Deny with a correction: the wait for the Agent to leave Blocked.
        var correctionTimeout: Duration = .seconds(8)
        var screenRecheckDelay: Duration = .seconds(1)
    }

    enum ListenResult: Equatable, Sendable {
        case heard(String)
        case silence
        /// Listening failed; the associated text is speakable.
        case failed(String)
    }

    enum Confirmation: Equatable, Sendable {
        case send
        case cancel
    }

    /// A spoken answer to a Blocked question (§5 rule 3).
    enum SpokenApproval: Equatable, Sendable {
        case allow
        case deny
        /// End the turn; send nothing.
        case stop
    }

    /// What a spoken reply to a Blocked question asks for.
    enum BlockedReply: Equatable, Sendable {
        case allow
        case deny
        /// End the turn; send nothing ("stop", "never mind", "that's all").
        case exit
        /// Deny, then send this instead (S5).
        case correction(String)
        /// Not an answer: worth one re-ask.
        case unrecognized
    }

    /// Where a question's reply will show up: what was there before it went.
    struct ReplyCursor: Equatable, Sendable {
        let agentID: ConsoleAgent.ID
        let identity: String
        let transcriptAvailable: Bool
        let lastMessageID: String?
        let knownAssistantIDs: Set<String>
        let summaryBefore: AgentSummary?
    }

    enum SendResult: Equatable, Sendable {
        case delivered(ReplyCursor)
        /// Nothing more to wait for; the associated text is speakable.
        case failed(String)
    }

    /// What `reply` heard back; both carry speakable text.
    enum Reply: Equatable, Sendable {
        /// The Agent answered, or finished: the driver may ask again.
        case answer(String)
        /// Nothing more to ask now (Blocked, gone, no reply in time).
        case final(String)

        var spoken: String {
            switch self {
            case .answer(let text), .final(let text): text
            }
        }
    }

    /// The buttons a Blocked turn offers (§5 per-kind map, rules 1 and 6).
    enum BlockedButtons: Equatable, Sendable {
        /// Deny, Allow.
        case denyAndAllow
        /// Deny, Hold: no voice Allow.
        case denyAndHold
        /// Spoken only.
        case readOnly
    }

    struct BlockedTurn: Equatable, Sendable {
        let agentID: ConsoleAgent.ID
        let identity: String
        let question: String
        let buttons: BlockedButtons
        /// The prompt as read aloud; nil when there is none to answer.
        let snapshot: BlockedPromptSnapshot?
    }

    struct BlockedAnswer: Equatable, Sendable {
        enum Outcome: Equatable, Sendable {
            case sent, queued, notSent
        }

        let spoken: String
        /// The prompt changed under the answer: announce this one instead.
        let next: BlockedTurn?
        let outcome: Outcome

        init(spoken: String, next: BlockedTurn?, outcome: Outcome = .notSent) {
            self.spoken = spoken
            self.next = next
            self.outcome = outcome
        }
    }

    /// The Console calls the service makes, as closures so tests run it
    /// against fakes (as `ConsoleStore.makeChatTranscriptStore` does).
    struct Dependencies {
        var agent: @MainActor (ConsoleAgent.ID) -> ConsoleAgent?
        var readScreen: @MainActor (ConsoleAgent) async throws -> String
        var sendKeys: @MainActor ([String], ConsoleAgent) async throws -> Void
        var promptAgent: @MainActor (AgentPromptParams, Host.ID) async throws -> Void
        var readTranscript: @MainActor (ConsoleAgent, _ after: String?) async throws -> ChatTranscriptSnapshot
        var statusUpdates: @MainActor (ConsoleAgent.ID) -> AsyncStream<ConsoleStore.AgentStatusUpdate>
        var insertDraft: @MainActor (ConsoleAgent, String) -> Void
    }

    private let dependencies: Dependencies
    /// The send and Blocked-answer core shared with the other surfaces:
    /// its in-flight rules and answerers span CarPlay and the watch.
    private let actions: AgentActionService
    private let dictation: (any DictationEngine)?
    let speaker: any AgentVoiceSpeaker
    private let timing: Timing
    private let locale: @MainActor () -> Locale
    /// Agents with a question on its way, from the reply cursor's read to
    /// the prompt's end.
    private var sending: Set<ConsoleAgent.ID> = []
    /// The Blocked question each Agent's driver last heard in full; Allow
    /// acts only on that one: never before the read-back.
    private var heardApprovals: [ConsoleAgent.ID: HeardApprovalMachine] = [:]

    /// The service over the app's Console, acting through `actions`, the
    /// instance the app's other surfaces share.
    convenience init(
        console: ConsoleStore, actions: AgentActionService, dictation: (any DictationEngine)?,
        speaker: any AgentVoiceSpeaker
    ) {
        let shared = AgentActionService.Dependencies.live(console: console)
        self.init(
            dependencies: Dependencies(
                agent: shared.agent,
                readScreen: shared.readScreen,
                sendKeys: shared.sendKeys,
                promptAgent: shared.promptAgent,
                readTranscript: { [weak console] agent, after in
                    guard let console else { throw CancellationError() }
                    return try await console.readChatTranscript(for: agent, after: after)
                },
                statusUpdates: { [weak console] id in
                    console?.agentStatusUpdates(for: id) ?? AsyncStream { $0.finish() }
                },
                insertDraft: shared.insertDraft),
            actions: actions,
            dictation: dictation,
            speaker: speaker)
    }

    /// The service over `dependencies`. Without `actions` it acts through
    /// its own `AgentActionService` over the same dependencies (tests).
    init(
        dependencies: Dependencies,
        actions: AgentActionService? = nil,
        dictation: (any DictationEngine)?,
        speaker: any AgentVoiceSpeaker,
        timing: Timing = Timing(),
        // The app bundle ships only English, so `Locale.current` reports
        // English for every user; the preferred language is what they speak.
        locale: @escaping @MainActor () -> Locale = {
            Locale.preferredLanguages.first.map(Locale.init(identifier:)) ?? .current
        }
    ) {
        self.dependencies = dependencies
        self.actions =
            actions
            ?? AgentActionService(
                dependencies: AgentActionService.Dependencies(
                    agent: dependencies.agent,
                    readScreen: dependencies.readScreen,
                    sendKeys: dependencies.sendKeys,
                    promptAgent: dependencies.promptAgent,
                    insertDraft: dependencies.insertDraft))
        self.dictation = dictation
        self.speaker = speaker
        self.timing = timing
        self.locale = locale
    }

    // MARK: Speech

    @discardableResult
    func speak(_ text: String) async -> Bool {
        await speaker.speak(text)
    }

    /// Speaks `line`, the announcement of `turn`'s question, and records
    /// the question as heard only when the whole line was spoken: Allow
    /// refuses a question the driver did not hear.
    @discardableResult
    func speakQuestion(_ turn: BlockedTurn, saying line: String) async -> Bool {
        let effects = approvalEvent(.announce(turn), for: turn.agentID)
        guard let effect = effects.first, case .speak(let token) = effect else {
            assertionFailure("Question announcement did not request speech")
            return false
        }
        let spoken = await speaker.speak(line)
        _ = approvalEvent(.completed(token, spoken: spoken), for: turn.agentID)
        return spoken
    }

    /// Ends the turn: stops speaking and gives the audio back.
    func endTurn() {
        speaker.endTurn()
    }

    /// How an Agent is named aloud: its push identity, `·` dropped.
    static func spokenIdentity(of agent: ConsoleAgent) -> String {
        CarVoiceScript.spokenIdentity(AgentGlanceList.title(for: agent))
    }

    /// What a row tap says before listening: status, and a fresh summary.
    func introduction(for agentID: ConsoleAgent.ID, now: Date = Date()) -> String? {
        guard let agent = dependencies.agent(agentID) else { return nil }
        let word = AgentActivityStatusVocabulary.word(for: agent.agent.status.rawValue)
        var summary: String?
        if case .summary(let text, _, let isStale) = agent.summaryLine(at: now), !isStale {
            summary = text
        }
        return CarVoiceScript.introduction(
            identity: Self.spokenIdentity(of: agent), statusWord: word, summary: summary)
    }

    // MARK: Listening

    /// One utterance through the car profile, half-duplex: speech stops
    /// first, and the microphone opens `speechSettle` later. Ends
    /// `endOfSpeech` after the last new words, after `noSpeech` with
    /// nothing said, or at `maximumListen`. A listen cancelled before the
    /// microphone opened is `.silence`.
    func listen() async -> ListenResult {
        await listen(noSpeech: timing.noSpeech)
    }

    /// A short listen after a correction's read-back. Silence and anything
    /// unrecognized mean Cancel (§5 rule 4): nothing is sent unless "send"
    /// was heard.
    func listenForConfirmation() async -> Confirmation {
        guard case .heard(let text) = await listen(noSpeech: timing.confirmNoSpeech) else {
            return .cancel
        }
        return Self.confirmation(in: text) ?? .cancel
    }

    private func listen(noSpeech: Duration) async -> ListenResult {
        guard let dictation else { return .failed(Self.voiceUnavailable) }
        speaker.stop()
        speaker.beginTurn()
        do { try await Task.sleep(for: timing.speechSettle) } catch { return .silence }
        let activity = ObjectIdentifier(self)
        DictationActivity.shared.begin(activity)
        defer { DictationActivity.shared.end(activity) }
        // Agent Notifications stay silent while the car listens.
        CarVoiceActivity.shared.beginListening()
        defer { CarVoiceActivity.shared.endListening() }

        let sessionID = DictationSessionID()
        let events = dictation.events(for: sessionID, locale: locale(), audioProfile: .car)
        let clock = ContinuousClock()
        let state = ListenState(machine: VoiceListenMachine(
            endpointer: Endpointer(
                startedAt: clock.now, endOfSpeech: timing.endOfSpeech, noSpeech: noSpeech,
                maximum: timing.maximumListen, startup: timing.startup),
            startupFailure: Self.voiceNotReady))
        let token = state.machine.token
        // The events are consumed in their own task so the startup bound
        // can end the listen: before `.listening`, `finish` only flags the
        // session, and the stream stays open while the engine waits on a
        // permission prompt nobody can answer (phone locked) or a model
        // download. Cancelling the consumer terminates the stream, which
        // cancels the engine's session.
        let consumer = Task { @MainActor () -> (any Error)? in
            do {
                for try await event in events {
                    _ = state.machine.handle(.engine(token, event, now: clock.now))
                }
            } catch {
                return error
            }
            return nil
        }
        let tick = timing.listenTick
        let watchdog = Task { @MainActor in
            while !Task.isCancelled {
                do { try await Task.sleep(for: tick) } catch { return }
                let effects = state.machine.handle(.tick(token, now: clock.now))
                guard !effects.isEmpty else { continue }
                for effect in effects {
                    switch effect {
                    case .cancelConsumer: consumer.cancel()
                    case .finishEngine: await dictation.finish(sessionID)
                    }
                }
                return
            }
        }
        defer { watchdog.cancel() }
        let failure = await withTaskCancellationHandler {
            await consumer.value
        } onCancel: {
            consumer.cancel()
        }
        _ = state.machine.handle(.streamEnded(token, failure: failure.map(Self.spokenError)))
        guard let result = state.machine.result else {
            assertionFailure("Listen stream ended without settling its machine")
            return .silence
        }
        return result
    }

    /// A spoken end to the conversation ("stop", "that's all", "no
    /// thanks"): the whole utterance, fillers dropped, nothing else.
    static func isConversationExit(_ transcript: String) -> Bool {
        let phrase = normalizedWords(transcript).joined(separator: " ")
        return [
            "stop", "done", "cancel", "no", "nope", "nothing", "no thanks", "no thank you",
            "thanks", "thank you", "that's all", "thats all", "that's it", "thats it",
            "i'm done", "im done", "all done", "we're done", "never mind", "nevermind",
            "bye", "goodbye", "stop listening",
        ].contains(phrase)
    }

    /// The closed Send/Cancel vocabulary; nil for anything else.
    static func confirmation(in transcript: String) -> Confirmation? {
        let words = normalizedWords(transcript)
        let phrase = words.joined(separator: " ")
        if ["send", "send it", "yes", "yeah", "yep", "go", "go ahead", "do it"].contains(phrase) {
            return .send
        }
        if ["cancel", "no", "nope", "stop", "don't send", "dont send", "do not send"]
            .contains(phrase)
        {
            return .cancel
        }
        return nil
    }

    /// The closed approval vocabulary: exactly one word once fillers and
    /// "please" are dropped; nil for anything else (§5 rule 3).
    static func spokenApproval(in transcript: String) -> SpokenApproval? {
        let words = normalizedWords(transcript)
        guard words.count == 1, let word = words.first else { return nil }
        switch word {
        case "allow", "yes", "approve": return .allow
        case "deny", "no": return .deny
        case "stop", "cancel": return .stop
        default: return nil
        }
    }

    /// A spoken correction to a Blocked question ("No, use pnpm instead"):
    /// more than one word, a leading "no" dropped. Nil when it is none.
    static func correction(in transcript: String) -> String? {
        guard normalizedWords(transcript).count > 1 else { return nil }
        let text = transcript.replacingOccurrences(
            of: #"^\s*no\b[\s,.!]*"#, with: "", options: [.regularExpression, .caseInsensitive])
        let line = AgentActionService.hygienic(text)
        return line.isEmpty ? nil : line
    }

    /// A spoken reply to a Blocked question: an approval word first, then
    /// a conversation exit, then a correction.
    static func blockedReply(to transcript: String) -> BlockedReply {
        switch spokenApproval(in: transcript) {
        case .allow: return .allow
        case .deny: return .deny
        case .stop: return .exit
        case nil: break
        }
        if isConversationExit(transcript) { return .exit }
        return correction(in: transcript).map(BlockedReply.correction) ?? .unrecognized
    }

    /// Lowercased words, punctuation dropped, fillers and a trailing
    /// "please" ignored.
    private static func normalizedWords(_ text: String) -> [String] {
        let words = text.lowercased()
            .split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "’" })
            .map { $0.replacingOccurrences(of: "’", with: "'") }
            .filter { !["uh", "um", "er", "please", "okay", "ok"].contains($0) }
        return words
    }

    // MARK: Asking

    /// How long a conversation keeps listening with nothing said.
    var conversationIdle: Duration { timing.conversationIdle }

    /// Unsent text to the Agent's Composer draft.
    func keepAsDraft(_ text: String, for agentID: ConsoleAgent.ID) {
        actions.keepAsDraft(text, for: agentID)
    }

    /// Sends the question, then speaks nothing: returns where its reply
    /// will appear, or a speakable failure. One `agent.prompt` through the
    /// shared `AgentActionService`, with the spoken-reply instruction;
    /// never resent after a failure that may have delivered it (§5 rule 7).
    func send(_ transcript: String, to agentID: ConsoleAgent.ID) async -> SendResult {
        guard let agent = dependencies.agent(agentID) else {
            return .failed(CarVoiceScript.notListed)
        }
        let identity = Self.spokenIdentity(of: agent)
        let line = AgentActionService.hygienic(transcript)
        guard !line.isEmpty else { return .failed(CarVoiceScript.notHeard) }
        // §5 rule 5: never type into a Blocked prompt.
        guard agent.agent.status != .blocked else {
            keepAsDraft(line, for: agentID)
            return .failed(CarVoiceScript.blockedKeptDraft(identity: identity))
        }
        guard !sending.contains(agentID), !actions.isSending(to: agentID) else {
            return .failed(CarVoiceScript.stillAnswering)
        }
        sending.insert(agentID)
        defer { sending.remove(agentID) }

        let cursor = await replyCursor(for: agent, identity: identity)
        // The driver closed the turn while the transcript was read: send
        // nothing, and keep the question rather than lose it.
        guard !Task.isCancelled else {
            keepAsDraft(line, for: agentID)
            return .failed(CarVoiceScript.notSent)
        }
        // `suffix` makes the prompt `CarVoiceScript.outgoingPrompt(transcript:)`.
        let outcome = await actions.send(
            line, to: agentID, suffix: CarVoiceScript.spokenReplyInstruction)
        switch outcome {
        case .sent:
            return .delivered(cursor)
        case .keptAsDraft(.blocked):
            return .failed(CarVoiceScript.blockedKeptDraft(identity: identity))
        case .keptAsDraft(.signInRequired):
            return .failed(CarVoiceScript.signInKeptDraft(identity: identity))
        case .keptAsDraft(.folderTrustRequired):
            return .failed(CarVoiceScript.trustKeptDraft(identity: identity))
        case .notSent(let reason) where reason == AgentActionService.busyReason:
            return .failed(CarVoiceScript.stillAnswering)
        case .notSent(let reason) where reason == AgentActionService.notListedReason:
            return .failed(CarVoiceScript.notListed)
        case .notSent, .unknown:
            return .failed(CarVoiceScript.notConfirmed)
        }
    }

    /// Waits for the reply to a question `send` delivered: a new assistant
    /// message in the Agent's transcript, capped to two sentences; without
    /// a transcript, the Agent Summary written after it finished. A
    /// cancelled wait is a silent `.final("")`.
    func reply(after cursor: ReplyCursor) async -> Reply {
        let clock = ContinuousClock()
        let deadline = clock.now + timing.replyTimeout
        var finishedAt: ContinuousClock.Instant?
        while clock.now < deadline {
            do { try await Task.sleep(for: timing.replyPoll) } catch { return .final("") }
            guard let agent = dependencies.agent(cursor.agentID) else {
                return .final(CarVoiceScript.notListed)
            }
            if cursor.transcriptAvailable, let reply = await newReply(of: agent, after: cursor) {
                return .answer(CarVoiceScript.spokenReply(reply))
            }
            let status = agent.agent.status
            let newSummary = agent.summary.flatMap {
                $0 != cursor.summaryBefore && $0.status == status ? $0.text : nil
            }
            switch status {
            case .blocked:
                return .final(CarVoiceScript.blockedAfterQuestion(identity: cursor.identity))
            case .done, .idle:
                if !cursor.transcriptAvailable, let newSummary {
                    return .answer(
                        CarVoiceScript.finished(identity: cursor.identity, summary: newSummary))
                }
                let since = finishedAt ?? clock.now
                finishedAt = since
                if since.duration(to: clock.now) >= timing.finishGrace {
                    return .answer(
                        CarVoiceScript.finished(identity: cursor.identity, summary: newSummary))
                }
            default:
                finishedAt = nil
            }
        }
        return .final(CarVoiceScript.noReply)
    }

    /// `send`, then `reply`: the whole question as one speakable answer.
    func ask(_ transcript: String, to agentID: ConsoleAgent.ID) async -> String {
        switch await send(transcript, to: agentID) {
        case .failed(let spoken): return spoken
        case .delivered(let cursor): return await reply(after: cursor).spoken
        }
    }

    private func replyCursor(for agent: ConsoleAgent, identity: String) async -> ReplyCursor {
        var snapshot: ChatTranscriptSnapshot?
        do {
            snapshot = try await dependencies.readTranscript(agent, nil)
        } catch {
            snapshot = nil
        }
        let messages = snapshot?.header.status == .ok ? snapshot?.messages : nil
        return ReplyCursor(
            agentID: agent.id,
            identity: identity,
            transcriptAvailable: messages != nil,
            lastMessageID: messages?.last?.id,
            knownAssistantIDs: Set((messages ?? []).filter { $0.role == .assistant }.map(\.id)),
            summaryBefore: agent.summary)
    }

    private func newReply(of agent: ConsoleAgent, after cursor: ReplyCursor) async -> String? {
        guard let snapshot = try? await dependencies.readTranscript(agent, cursor.lastMessageID),
            snapshot.header.status == .ok
        else { return nil }
        return snapshot.messages.last { message in
            message.role == .assistant && !cursor.knownAssistantIDs.contains(message.id)
                && !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }?.text
    }

    // MARK: Blocked

    /// Reads and classifies the Blocked prompt and returns what to say and
    /// which buttons to offer. Allow only for a lossless, risk-free
    /// plain-Yes permission (§5 rules 1, 6).
    func blockedTurn(for agentID: ConsoleAgent.ID) async -> BlockedTurn {
        guard let agent = dependencies.agent(agentID) else {
            return BlockedTurn(
                agentID: agentID, identity: "", question: CarVoiceScript.notListed,
                buttons: .readOnly, snapshot: nil)
        }
        let identity = Self.spokenIdentity(of: agent)
        guard agent.agent.status == .blocked else {
            return BlockedTurn(
                agentID: agentID, identity: identity,
                question: CarVoiceScript.notBlocked(identity: identity),
                buttons: .readOnly, snapshot: nil)
        }
        let snapshot = try? await actions.blockedPrompt(for: agentID)
        let (question, buttons) = Self.blockedQuestion(identity: identity, snapshot: snapshot)
        return BlockedTurn(
            agentID: agentID, identity: identity, question: question, buttons: buttons,
            snapshot: snapshot)
    }

    /// The spoken question and the buttons for a classified prompt.
    static func blockedQuestion(identity: String, snapshot: BlockedPromptSnapshot?)
        -> (String, BlockedButtons)
    {
        guard let snapshot else {
            return (CarVoiceScript.unreadablePrompt(identity: identity), .readOnly)
        }
        switch snapshot.prompt {
        case .permission(let command, _):
            switch snapshot.approval {
            case .allow:
                return (
                    CarVoiceScript.blockedQuestion(identity: identity, command: command),
                    .denyAndAllow)
            case .hold(.risky(let reason)):
                // A command that cannot be read out in full is never read
                // out in part.
                guard case .permission(_, true) = snapshot.prompt else {
                    return (CarVoiceScript.tooLongHold(identity: identity), .denyAndHold)
                }
                return (
                    CarVoiceScript.riskyHold(identity: identity, command: command, reason: reason),
                    .denyAndHold)
            case .hold(.notLossless):
                return (CarVoiceScript.tooLongHold(identity: identity), .denyAndHold)
            case .readOnly:
                return (CarVoiceScript.unknownPrompt(identity: identity), .readOnly)
            }
        case .trust:
            return (CarVoiceScript.trustQuestion(identity: identity), .readOnly)
        case .yesNo:
            return (CarVoiceScript.yesNoQuestion(identity: identity), .readOnly)
        case .question:
            return (CarVoiceScript.multipleChoiceQuestion(identity: identity), .readOnly)
        case .unknown:
            return (CarVoiceScript.unknownPrompt(identity: identity), .readOnly)
        }
    }

    /// Enter, through the guard, only when the turn offered Allow and its
    /// question was heard in full.
    func allow(_ turn: BlockedTurn) async -> BlockedAnswer {
        // handle consumes the full-question authorization before the
        // answerer's first await, including when no answerer is available.
        let effects = approvalEvent(.allow(turn), for: turn.agentID)
        guard let effect = effects.first, case .authorize(let snapshot) = effect else {
            return BlockedAnswer(spoken: CarVoiceScript.notAllowedFromCar, next: nil)
        }
        guard let answerer = actions.answerer(for: turn.agentID) else {
            return BlockedAnswer(spoken: CarVoiceScript.notListed, next: nil)
        }
        let outcome = await answerer.allow(snapshot)
        return await answer(for: outcome, of: turn, success: CarVoiceScript.allowed)
    }

    private func approvalEvent(
        _ event: HeardApprovalMachine.Event, for agentID: ConsoleAgent.ID
    ) -> [HeardApprovalMachine.Effect] {
        var machine = heardApprovals[agentID] ?? HeardApprovalMachine()
        let effects = machine.handle(event)
        heardApprovals[agentID] = machine
        return effects
    }

    /// Esc, through the guard.
    func deny(_ turn: BlockedTurn) async -> BlockedAnswer {
        guard turn.buttons != .readOnly, let snapshot = turn.snapshot else {
            return BlockedAnswer(spoken: CarVoiceScript.notAnsweredFromCar, next: nil)
        }
        guard let answerer = actions.answerer(for: turn.agentID) else {
            return BlockedAnswer(spoken: CarVoiceScript.notListed, next: nil)
        }
        let outcome = await answerer.deny(snapshot)
        return await answer(for: outcome, of: turn, success: CarVoiceScript.denied)
    }

    /// Esc, then `text` as its own prompt once the Agent leaves Blocked;
    /// otherwise `text` goes to the draft (S5, §5 rule 5).
    func denyAndInstruct(_ turn: BlockedTurn, text: String) async -> BlockedAnswer {
        guard turn.buttons != .readOnly, let snapshot = turn.snapshot else {
            return BlockedAnswer(spoken: CarVoiceScript.notAnsweredFromCar, next: nil)
        }
        let line = AgentActionService.hygienic(text)
        guard let agent = dependencies.agent(turn.agentID),
            let answerer = actions.answerer(for: turn.agentID)
        else {
            return BlockedAnswer(spoken: CarVoiceScript.notListed, next: nil)
        }
        guard !line.isEmpty else { return await deny(turn) }
        let promptAgent = dependencies.promptAgent
        let insertDraft = dependencies.insertDraft
        let actions = actions
        let outcome = await answerer.denyAndInstruct(
            snapshot, text: line,
            statusUpdates: dependencies.statusUpdates(turn.agentID),
            prompt: { correction in
                // Read before the prompt: it is what starts the turn.
                let statusAtSend = dependencies.agent(agent.id)?.agent.status ?? agent.agent.status
                try await promptAgent(
                    AgentPromptParams(
                        target: agent.agent.paneID,
                        text: CarVoiceScript.outgoingPrompt(transcript: correction)),
                    agent.hostID)
                // The Host took the correction: a value event, like `send`.
                actions.recordDelivery(to: agent, statusAtSend: statusAtSend)
            },
            draft: { insertDraft(agent, $0) },
            timeout: timing.correctionTimeout,
            screenRecheckDelay: timing.screenRecheckDelay)
        switch outcome {
        case .prompted:
            return BlockedAnswer(spoken: CarVoiceScript.deniedAndSent, next: nil, outcome: .sent)
        case .drafted:
            return BlockedAnswer(spoken: CarVoiceScript.correctionDrafted, next: nil)
        case .promptFailed:
            return BlockedAnswer(spoken: CarVoiceScript.correctionNotConfirmed, next: nil)
        case .denyFailed(let denied):
            return await answer(for: denied, of: turn, success: CarVoiceScript.denied)
        }
    }

    private func answer(
        for outcome: BlockedPromptAnswerer.Outcome, of turn: BlockedTurn, success: String
    ) async -> BlockedAnswer {
        switch outcome {
        case .sent:
            return BlockedAnswer(spoken: success, next: nil, outcome: .sent)
        case .queued:
            return BlockedAnswer(
                spoken: success == CarVoiceScript.allowed
                    ? CarVoiceScript.allowQueued : CarVoiceScript.denyQueued,
                next: nil, outcome: .queued)
        case .promptChanged:
            let next = await blockedTurn(for: turn.agentID)
            return BlockedAnswer(spoken: CarVoiceScript.promptChanged(next.question), next: next)
        case .sendFailed, .unreachable:
            return BlockedAnswer(spoken: CarVoiceScript.notConfirmed, next: nil)
        case .busy:
            return BlockedAnswer(spoken: CarVoiceScript.stillAnswering, next: nil)
        case .refused:
            return BlockedAnswer(spoken: CarVoiceScript.notAllowedFromCar, next: nil)
        case .abandoned, .cancelled:
            return BlockedAnswer(spoken: "", next: nil)
        }
    }

    // MARK: Errors

    static let voiceUnavailable = "Voice input isn't available on this device."
    static let voiceNotReady = "Voice input isn't ready yet. Try again in a moment."

    static func spokenError(_ error: any Error) -> String {
        switch error as? DictationEngineError {
        case .microphonePermissionDenied:
            return "Waycar doesn't have microphone access."
        case .localeUnsupported:
            return "There's no on-device speech model for your language."
        case .modelUnavailable:
            return "The speech model isn't available right now."
        case .busy:
            return "The microphone is already in use."
        case .captureFailed, nil:
            return "Listening stopped unexpectedly."
        }
    }
}

/// When a listen ends (§5 Latency: ~1.5 s trailing silence). Pure; the
/// listen loop passes time in.
struct Endpointer: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        case endOfSpeech
        case noSpeech
        case maximum
        /// The microphone never opened.
        case startup
    }

    let startedAt: ContinuousClock.Instant
    let endOfSpeech: Duration
    let noSpeech: Duration
    let maximum: Duration
    let startup: Duration
    private(set) var listeningSince: ContinuousClock.Instant?
    private(set) var lastSpeechAt: ContinuousClock.Instant?

    init(
        startedAt: ContinuousClock.Instant, endOfSpeech: Duration, noSpeech: Duration,
        maximum: Duration, startup: Duration
    ) {
        self.startedAt = startedAt
        self.endOfSpeech = endOfSpeech
        self.noSpeech = noSpeech
        self.maximum = maximum
        self.startup = startup
    }

    mutating func listeningStarted(at now: ContinuousClock.Instant) {
        if listeningSince == nil { listeningSince = now }
    }

    mutating func heardSpeech(at now: ContinuousClock.Instant) {
        lastSpeechAt = now
    }

    func finishReason(now: ContinuousClock.Instant) -> Reason? {
        guard let listeningSince else {
            return startedAt.duration(to: now) >= startup ? .startup : nil
        }
        if listeningSince.duration(to: now) >= maximum { return .maximum }
        if let lastSpeechAt {
            return lastSpeechAt.duration(to: now) >= endOfSpeech ? .endOfSpeech : nil
        }
        return listeningSince.duration(to: now) >= noSpeech ? .noSpeech : nil
    }
}

/// The consumer and watchdog share one main-actor machine. Their resources
/// are scoped to `machine.token` inside `listen`, never shared across listens.
@MainActor
private final class ListenState {
    var machine: VoiceListenMachine
    init(machine: VoiceListenMachine) { self.machine = machine }
}
