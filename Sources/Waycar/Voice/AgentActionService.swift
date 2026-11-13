import Foundation

/// The actions every surface away from the Console takes on an Agent:
/// send a message, read its Blocked prompt, and answer it with Allow or
/// Deny. CarPlay's voice loop and the Apple Watch share one instance
/// (`WaycarAppModel.agentActions`), so the rules hold the same everywhere:
/// one message in flight per Agent and never resent, never typed into a
/// Blocked prompt (kept as the Composer draft instead), and Allow only for a
/// lossless, risk-free plain-Yes permission through the shown-prompt guard
/// (docs/design/carplay.md §5, docs/adr/0028, docs/design/apple-watch-v0.md
/// §6). No UI, no speech: callers decide what to show or say.
@MainActor
final class AgentActionService {
    /// What became of a message `send` was given.
    enum SendOutcome: Equatable, Sendable {
        /// The Agent's Host took the prompt.
        case sent
        /// Definitely not delivered; a retry is safe. `reason` is short
        /// user-facing copy ("Host isn't connected").
        case notSent(reason: String)
        /// It may have been delivered: never retried.
        case unknown
        /// Refused before anything was typed (`reason`): the text is in
        /// the Agent's Composer draft.
        case keptAsDraft(KeptReason)
    }

    /// Why a message was kept as the Composer draft instead of sent.
    enum KeptReason: Equatable, Sendable {
        /// The Agent was Blocked on a prompt.
        case blocked
        /// The Agent's harness needs a sign-in on the Host.
        case signInRequired
        /// The Agent's harness needs the folder trusted on the Host.
        case folderTrustRequired
    }

    /// What became of an Allow or Deny `answer` was given.
    enum AnswerOutcome: Equatable, Sendable {
        /// The keys went out.
        case sent
        /// The screen no longer shows the prompt that was shown, or the
        /// Agent is no longer Blocked: nothing was sent.
        case promptChanged
        /// The approval rules forbid this answer for this prompt.
        case refused
        /// Nothing confirmed: the screen could not be re-read (a failed or
        /// blank read), the send failed, another answer was in flight, or
        /// the Agent is gone. Never retried.
        case failed
    }

    /// Why `blockedPrompt(for:)` has no prompt to return.
    enum BlockedPromptError: Error, Equatable, Sendable {
        /// The Agent is no longer listed.
        case notListed
        /// The Agent is Blocked but its screen read blank.
        case unreadable
    }

    /// The Console calls the service makes, as closures so tests run it
    /// against fakes (as `AgentVoiceService.Dependencies` does).
    struct Dependencies {
        /// The listed Agent with this id, if any.
        var agent: @MainActor (ConsoleAgent.ID) -> ConsoleAgent?
        /// The Agent's visible screen, read live.
        var readScreen: @MainActor (ConsoleAgent) async throws -> String
        /// Control keys to the Agent (`agent.send_keys`).
        var sendKeys: @MainActor ([String], ConsoleAgent) async throws -> Void
        /// One prompt to the Agent (`agent.prompt`).
        var promptAgent: @MainActor (AgentPromptParams, Host.ID) async throws -> Void
        /// Text into the Agent's Composer draft.
        var insertDraft: @MainActor (ConsoleAgent, String) -> Void
        /// Keeps an Allow or Deny the Host could not be reached for
        /// (CONTEXT.md **Queued Answer**); nil never queues.
        var queueAnswer: (@MainActor (PendingBlockedAnswer, ConsoleAgent.ID) -> Void)? = nil
        /// Counts one message the Host took for an Agent as Review Prompt
        /// use (`ReviewPromptStore.recordValueEvent`); nil counts nothing.
        var recordValueEvent: (@MainActor () -> Void)? = nil
        /// Notes that an Agent a message was sent to finished its turn
        /// (`ReviewPromptStore.noteTurnCompleted`); nil notes nothing.
        var noteTurnCompleted: (@MainActor (ConsoleAgent.ID) -> Void)? = nil
        /// The Console's status fan-out for one Agent, watched for the turn
        /// a delivered message starts; nil watches nothing.
        var statusUpdates:
            (@MainActor (ConsoleAgent.ID) -> AsyncStream<ConsoleStore.AgentStatusUpdate>)? = nil
        /// Waits out the time a turn watch is given (`turnWatchWindow`);
        /// tests replace it.
        var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

        /// The live Console's calls. Held weakly: a released store makes
        /// every call fail instead of keeping it alive.
        static func live(console: ConsoleStore) -> Dependencies {
            Dependencies(
                agent: { [weak console] id in console?.agents.first { $0.id == id } },
                readScreen: { [weak console] agent in
                    guard let console else { throw CancellationError() }
                    return try await console.readVisibleScreen(for: agent)
                },
                sendKeys: { [weak console] keys, agent in
                    guard let console else { throw CancellationError() }
                    try await console.sendKeys(keys, to: agent)
                },
                promptAgent: { [weak console] params, hostID in
                    guard let console else { throw CancellationError() }
                    _ = try await console.promptAgent(params, on: hostID)
                },
                insertDraft: { [weak console] agent, text in
                    // Placed at the caret with word spacing, as dictation is.
                    guard let composer = console?.composerStore(for: agent) else { return }
                    let composed = DictationComposition(
                        draft: composer.draft, selection: composer.draftSelection
                    ).compose(text)
                    composer.applyEditorDraft(
                        composed.text, selection: NSRange(location: composed.caret, length: 0))
                },
                queueAnswer: { [weak console] pending, agentID in
                    console?.queueBlockedAnswer(pending, for: agentID)
                },
                // Read when called: the Review Prompt store is installed
                // after the service is made, and absent from the demo and
                // the headless CarPlay Console.
                recordValueEvent: { [weak console] in console?.reviewPrompt?.recordValueEvent() },
                noteTurnCompleted: { [weak console] id in
                    console?.reviewPrompt?.noteTurnCompleted(agent: id)
                },
                statusUpdates: { [weak console] id in
                    console?.agentStatusUpdates(for: id) ?? AsyncStream { $0.finish() }
                })
        }
    }

    /// `notSent` reason while another message to the Agent is in flight.
    static let busyReason = "Still sending the last message"
    /// `notSent` reason for text with nothing left once made safe.
    static let emptyReason = "Nothing to send"
    /// `notSent` reason for an Agent no longer listed.
    static let notListedReason = "This Agent is gone"

    private let dependencies: Dependencies
    /// One Blocked answerer per Agent: one answer in flight each, across
    /// every surface.
    private var answerers: [ConsoleAgent.ID: BlockedPromptAnswerer] = [:]
    /// Agents with a message on its way.
    private var sending: Set<ConsoleAgent.ID> = []
    /// The one watcher per Agent of the turn a delivered message started.
    private var turnWatchers: [ConsoleAgent.ID: (token: UUID, task: Task<Void, Never>)] = [:]

    /// The service over the app's Console.
    convenience init(console: ConsoleStore) {
        self.init(dependencies: .live(console: console))
    }

    /// The service over `dependencies`; tests pass fakes.
    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    // MARK: Sending

    /// Whether a message to the Agent is on its way now.
    func isSending(to agentID: ConsoleAgent.ID) -> Bool {
        sending.contains(agentID)
    }

    /// Unsafe characters dropped, newlines folded to one line (§5 rule 9):
    /// what `send` types and `keepAsDraft` keeps.
    static func hygienic(_ text: String) -> String {
        var safe = String.UnicodeScalarView()
        for scalar in text.unicodeScalars
        where TerminalTextSafety.containsOnlySafeScalars(String(scalar)) {
            safe.append(scalar)
        }
        return CarVoiceScript.foldedLine(TerminalTextSafety.normalizingNewlines(String(safe)))
    }

    /// Unsent text to the Agent's Composer draft; nothing for blank text
    /// or an Agent no longer listed.
    func keepAsDraft(_ text: String, for agentID: ConsoleAgent.ID) {
        let line = Self.hygienic(text)
        guard !line.isEmpty, let agent = dependencies.agent(agentID) else { return }
        dependencies.insertDraft(agent, line)
    }

    /// Sends `text`, made safe, as one `agent.prompt`, with ` suffix`
    /// appended when there is one. One message in flight per Agent; never
    /// resent after a failure that may have delivered it (§5 rule 7); a
    /// Blocked Agent gets nothing typed and the text in its draft (rule 5).
    func send(_ text: String, to agentID: ConsoleAgent.ID, suffix: String?) async -> SendOutcome {
        guard let agent = dependencies.agent(agentID) else {
            return .notSent(reason: Self.notListedReason)
        }
        let line = Self.hygienic(text)
        guard !line.isEmpty else { return .notSent(reason: Self.emptyReason) }
        guard agent.agent.status != .blocked else {
            keepAsDraft(line, for: agentID)
            return .keptAsDraft(.blocked)
        }
        guard !sending.contains(agentID) else { return .notSent(reason: Self.busyReason) }
        sending.insert(agentID)
        defer { sending.remove(agentID) }
        let statusAtSend = dependencies.agent(agentID)?.agent.status ?? agent.agent.status
        let prompt = suffix.map { "\(line) \($0)" } ?? line
        do {
            try await dependencies.promptAgent(
                AgentPromptParams(target: agent.agent.paneID, text: prompt), agent.hostID)
        } catch {
            // Refused before anything was typed: kept, never "unknown".
            if let reason = Self.keptReason(for: error) {
                keepAsDraft(line, for: agentID)
                return .keptAsDraft(reason)
            }
            if error is RequestNotSentError {
                return .notSent(reason: Self.notSentReason(error))
            }
            return .unknown
        }
        // Seeded with the status read before the prompt went out (the
        // Composer's rule): the prompt itself starts the turn, so the
        // status after it is already `.working` and would hide the work.
        recordDelivery(to: agent, statusAtSend: statusAtSend)
        return .sent
    }

    // MARK: Review Prompt

    /// Counts a prompt the Host took for `agent` as one Review Prompt value
    /// event and watches the turn it starts, so the ask can follow the
    /// Agent's Done (docs/design/review-prompt.md). Callers invoke it only
    /// on success, once per delivery. A shell is not an Agent: nothing.
    func recordDelivery(to agent: ConsoleAgent, statusAtSend: AgentStatus) {
        guard !agent.isShell else { return }
        dependencies.recordValueEvent?()
        watchTurn(of: agent, statusAtSend: statusAtSend)
    }

    /// Whether the turn of a message sent to the Agent is being watched.
    func isWatchingTurn(of agentID: ConsoleAgent.ID) -> Bool {
        turnWatchers[agentID] != nil
    }

    /// Whether a status stream shows the turn of a message sent to an Agent
    /// finishing: the Composer's rule (`AgentComposerStore.agentStatusDidChange`),
    /// kept in one place. Done counts after the Agent was seen working, or
    /// when it was not working at the send; Idle only after it was seen
    /// working.
    struct TurnTracker {
        private var status: AgentStatus
        private let wasWorkingAtSend: Bool
        private var observedWorking = false

        init(statusAtSend: AgentStatus) {
            status = statusAtSend
            wasWorkingAtSend = statusAtSend == .working
        }

        /// Whether `new` finishes the turn. Repeats of the current status
        /// (the stream's first value replays it) change nothing.
        mutating func finishesTurn(on new: AgentStatus) -> Bool {
            guard new != status else { return false }
            status = new
            switch new {
            case .working:
                observedWorking = true
                return false
            case .done:
                return observedWorking || !wasWorkingAtSend
            case .idle:
                return observedWorking
            default:
                return false
            }
        }
    }

    /// The longest a turn is watched. It only bounds a stuck watcher: the
    /// window of the Review Prompt starts when a turn ENDS, and a turn started
    /// from the Watch or CarPlay can run far longer than that window.
    static let turnWatchWindow: Duration = .seconds(4 * 60 * 60)

    /// Notes the turn done once, at the first status that finishes it. One
    /// watcher per Agent: a newer message replaces it. The Console's status
    /// stream never finishes on its own, so the watch ends at the first of:
    /// the turn finishing, the Agent leaving the list (a nil status), and
    /// `turnWatchWindow` (a few hours) passing.
    private func watchTurn(of agent: ConsoleAgent, statusAtSend: AgentStatus) {
        guard let note = dependencies.noteTurnCompleted,
            let statusUpdates = dependencies.statusUpdates
        else { return }
        let id = agent.id
        turnWatchers[id]?.task.cancel()
        let token = UUID()
        let stream = statusUpdates(id)
        // `statusAtSend` is the status before the prompt, not after.
        let sleep = dependencies.sleep
        let window = Self.turnWatchWindow
        let task = Task { [weak self] in
            let watcher = Task { @MainActor in
                var tracker = TurnTracker(statusAtSend: statusAtSend)
                for await update in stream {
                    // No status: the Agent is gone.
                    guard !Task.isCancelled, let status = update.status else { return false }
                    if tracker.finishesTurn(on: status) { return true }
                }
                return false
            }
            // Expiring ends the watch unfinished; only the status stream
            // says the turn finished.
            let timer = Task {
                try? await sleep(window)
                watcher.cancel()
            }
            let finished = await withTaskCancellationHandler {
                let result = await watcher.value
                timer.cancel()
                return result
            } onCancel: {
                watcher.cancel()
                timer.cancel()
            }
            if finished, !Task.isCancelled { note(id) }
            self?.endTurnWatch(of: id, token: token)
        }
        turnWatchers[id] = (token, task)
    }

    private func endTurnWatch(of id: ConsoleAgent.ID, token: UUID) {
        guard turnWatchers[id]?.token == token else { return }
        turnWatchers[id] = nil
    }

    /// Short copy for a failure that left nothing on its way.
    private static func notSentReason(_ error: any Error) -> String {
        switch RequestNotSentError.unwrapped(error) as? TransportError {
        case .sshUnreachable: "Host isn't connected"
        case .timedOut: "Host didn't answer"
        default: "Couldn't reach the Host"
        }
    }

    /// The refusal that left nothing typed, if `error` is one.
    private static func keptReason(for error: any Error) -> KeptReason? {
        if isAgentBlocked(error) { return .blocked }
        if error is AgentSignInRequiredError { return .signInRequired }
        if error is AgentFolderTrustRequiredError { return .folderTrustRequired }
        return nil
    }

    /// herdr's and the tmux transport's refusal of a prompt to a Blocked
    /// Agent: nothing was typed.
    static func isAgentBlocked(_ error: any Error) -> Bool {
        if let apiError = error as? HerdrAPIError { return apiError.code == "agent_blocked" }
        if let transportError = error as? TransportError,
            case .apiRejected(let code, _) = transportError
        {
            return code == "agent_blocked"
        }
        return false
    }

    // MARK: Blocked

    /// The Agent's Blocked prompt, read live and classified; nil when the
    /// Agent is not Blocked.
    /// - Throws: `BlockedPromptError` for an Agent no longer listed or a
    ///   blank screen; the screen read's own error when it fails.
    func blockedPrompt(for agentID: ConsoleAgent.ID) async throws -> BlockedPromptSnapshot? {
        guard let agent = dependencies.agent(agentID) else { throw BlockedPromptError.notListed }
        guard agent.agent.status == .blocked else { return nil }
        let screen = try await dependencies.readScreen(agent)
        guard let snapshot = BlockedPromptSnapshot(kind: agent.agent.kind, fullScreen: screen)
        else { throw BlockedPromptError.unreadable }
        return snapshot
    }

    /// Allow (Enter) or Deny (Esc) on the prompt `shown`, only while the
    /// Agent is still Blocked and the screen still shows it. Allow only when
    /// `shown.approval == .allow`; Deny for anything but a read-only prompt
    /// (CarPlay parity, ADR 0028).
    func answer(allow: Bool, agentID: ConsoleAgent.ID, shown snapshot: BlockedPromptSnapshot)
        async -> AnswerOutcome
    {
        if allow {
            guard snapshot.approval == .allow else { return .refused }
        } else {
            guard snapshot.approval != .readOnly else { return .refused }
        }
        guard let agent = dependencies.agent(agentID), let answerer = answerer(for: agentID)
        else { return .failed }
        guard agent.agent.status == .blocked else { return .promptChanged }
        let outcome =
            allow
            ? await answerer.allow(snapshot, queuesOffline: false)
            : await answerer.deny(snapshot, queuesOffline: false)
        switch outcome {
        case .sent: return .sent
        // No screen to compare: the read failed or came back blank.
        case .promptChanged(current: nil): return .failed
        case .promptChanged: return .promptChanged
        case .refused: return .refused
        case .sendFailed, .busy, .abandoned, .cancelled, .queued, .unreachable: return .failed
        }
    }

    /// The Agent's one answerer, shared by every surface so one answer is
    /// in flight per Agent; nil for an Agent no longer listed.
    func answerer(for agentID: ConsoleAgent.ID) -> BlockedPromptAnswerer? {
        if let existing = answerers[agentID] { return existing }
        guard dependencies.agent(agentID) != nil else { return nil }
        let dependencies = dependencies
        let queue = dependencies.queueAnswer
        let queueAnswer: (@MainActor (PendingBlockedAnswer) -> Void)? =
            queue.map { queue in { @MainActor pending in queue(pending, agentID) } }
        let answerer = BlockedPromptAnswerer(
            readScreen: {
                guard let agent = dependencies.agent(agentID) else { throw CancellationError() }
                return try await dependencies.readScreen(agent)
            },
            sendKeys: { keys in
                guard let agent = dependencies.agent(agentID) else { throw CancellationError() }
                try await dependencies.sendKeys(keys, agent)
            },
            queueAnswer: queueAnswer)
        answerers[agentID] = answerer
        return answerer
    }
}
