import Foundation
import Observation

/// The Chat view's model of one Chat Mode Agent: the transcript the Host's
/// plugin reads from the harness's own session file, plus the live Agent
/// Status that drives when to read it again.
///
/// Reads are cheap single execs, but not free: a full read on start, then an
/// incremental read (`after` the last message id) on every status change and
/// every `workingPollInterval` while the Agent works, a turn is open, or a
/// local send still waits for its reply. An idle Agent is otherwise not
/// polled. Reads never overlap; one requested while another is in flight
/// runs once after it. While the Agent is Blocked, its visible screen is
/// read on entering Blocked, on the same poll, shortly after an answer, and
/// on `refresh()`; a repeat of the current status reads nothing.
///
/// The list starts as the copy kept on this device, so a chat opens with
/// its bubbles before the Host answers; the full read on start reconciles
/// it. Only a read that found the transcript changes the list: one that
/// failed or found none keeps what is shown and is tried again after
/// `retryDelays` while started.
@MainActor
@Observable
final class ChatTranscriptStore {
    enum Availability: Equatable {
        case loading
        case ready
        /// The reader found no transcript yet: a fresh Agent may not have
        /// written one.
        case waitingForConversation
        /// The Host has no Waycar plugin.
        case pluginMissing
        /// The Host's plugin predates the transcript reader.
        case pluginOutdated
        /// The last read failed; the messages already shown stay.
        case failed(String)
    }

    private(set) var messages: [ChatTranscriptMessage]
    private(set) var activity: String?
    private(set) var isTurnOpen = false
    private(set) var status: AgentStatus
    private(set) var availability: Availability = .loading
    /// The last `BlockedPromptAnswerer.screenLineLimit` non-empty lines of
    /// the visible screen while the Agent is Blocked; nil while the first
    /// read is in flight, after a read failed, and outside Blocked.
    var blockedScreen: String? { approval.screen }
    /// The last read of the Blocked screen failed or found it blank: there
    /// is no prompt on display to answer.
    var blockedScreenUnreadable: Bool { approval.screenUnreadable }
    /// True after Allow or Cancel until the status changes or the screen
    /// shows a different prompt, so a second tap cannot answer the next
    /// question blind. Also true while an answer checks the prompt is
    /// still on screen.
    var isAnsweringBlocked: Bool { approval.isAnswering }

    /// Structured requests replace the terminal screen only on transports
    /// that supply them. They can never become Queued Answers.
    var usesStructuredRequests: Bool { pendingRequests != nil }
    var requests: [AgentPendingRequest] { approval.requests }
    var requestsUnreadable: Bool { approval.requestsUnreadable }
    var requestAnswerFailed: Bool { approval.requestAnswerFailed }
    private(set) var liveUpdatesAvailable = false
    var canAnswerRequests: Bool {
        status == .blocked && liveUpdatesAvailable && !isAnsweringBlocked
    }

    var showsTypingIndicator: Bool {
        (isTurnOpen || status == .working) && status != .blocked
    }

    /// Allow and Cancel answer only a prompt the user can see, and only
    /// while none is already queued.
    var canAnswerBlocked: Bool {
        status == .blocked && blockedScreen != nil && !isAnsweringBlocked
            && queuedAnswer() == nil
    }

    /// "Allow" or "Cancel" while that answer waits for the Host to come
    /// back (CONTEXT.md **Queued Answer**); nil otherwise.
    var queuedAnswerLabel: String? {
        status == .blocked ? queuedAnswer()?.pending.label : nil
    }

    /// Drops the queued answer; the card's Allow and Cancel answer again.
    func withdrawQueuedAnswer() {
        withdrawQueued()
    }

    private let read: @MainActor (_ after: String?) async throws -> ChatTranscriptSnapshot
    private let readScreen: @MainActor () async throws -> String
    private let pendingRequests: (@MainActor () async throws -> [AgentPendingRequest])?
    private let answerRequest: (@MainActor (String, AgentRequestAnswer) async throws -> Void)?
    /// Allow and Cancel's guard: answers only the prompt on display.
    private let answerer: BlockedPromptAnswerer
    /// The Agent's Queued Answer, if one waits.
    private let queuedAnswer: @MainActor () -> BlockedAnswerQueue.Entry?
    private let withdrawQueued: @MainActor () -> Void
    /// Called on every start: an `AsyncStream` iterates once, so a restart
    /// after a (possibly spurious) disappear needs a fresh subscription.
    private let makeStatusUpdates: @MainActor () -> AsyncStream<ConsoleStore.AgentStatusUpdate>?
    /// Keeps the list on this device; called on every change to it.
    private let persist: (@MainActor ([ChatTranscriptMessage]) -> Void)?
    private let workingPollInterval: Duration
    /// How long a local send keeps the transcript polled while no reply
    /// arrives and the status gives no cue.
    private let localSendPollWindow: Duration
    /// How long after Allow or Cancel the screen is looked at again.
    private let blockedRecheckDelay: Duration
    /// The clock `localSendPollWindow` is measured on.
    private let now: @MainActor () -> ContinuousClock.Instant

    /// The two read coalescers, the cursor and the retry and plugin budgets.
    /// The owner keeps only the current Tasks.
    @ObservationIgnored private var acquisition: TranscriptAcquisitionMachine
    private var isStarted: Bool { acquisition.state.isStarted }
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    private var approval: ChatApprovalMachine
    @ObservationIgnored private var polling = ChatPollingMachine()
    @ObservationIgnored private var pollTasks: [UInt64: Task<Void, Never>] = [:]
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var screenTask: Task<Void, Never>?
    @ObservationIgnored private var recheckTasks: [UInt64: Task<Void, Never>] = [:]
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    /// Which transcript messages may account for a composer message, fixed
    /// when the message is first seen and again when it is retried.
    private enum EchoBaseline {
        /// The message predates the Chat view (sent from the terminal
        /// Composer), so any transcript message may account for it.
        case predatesChat
        /// The transcript messages already present: only newer ones count.
        case present(Set<String>)

        func admits(_ id: String) -> Bool {
            guard case .present(let ids) = self else { return true }
            return !ids.contains(id)
        }
    }

    private struct PendingTrack {
        var baseline: EchoBaseline
        var wasFailed: Bool
    }

    @ObservationIgnored private var pendingTracks: [UUID: PendingTrack] = [:]
    @ObservationIgnored private var hasSeenComposer = false

    /// A one-shot `statusUpdates` stream: after `stop()` a later `start()`
    /// finds it finished and follows no further status changes. Prefer
    /// ``init(read:readScreen:sendKeys:initialStatus:statusUpdateSource:cachedMessages:persist:retryDelays:workingPollInterval:localSendPollWindow:blockedRecheckDelay:now:)``
    /// for a view that can appear more than once.
    convenience init(
        read: @escaping @MainActor (_ after: String?) async throws -> ChatTranscriptSnapshot,
        readScreen: @escaping @MainActor () async throws -> String,
        sendKeys: @escaping @MainActor ([String]) async throws -> Void,
        queueAnswer: (@MainActor (PendingBlockedAnswer) -> Void)? = nil,
        queuedAnswer: @escaping @MainActor () -> BlockedAnswerQueue.Entry? = { nil },
        withdrawQueuedAnswer: @escaping @MainActor () -> Void = {},
        initialStatus: AgentStatus,
        statusUpdates: AsyncStream<ConsoleStore.AgentStatusUpdate>?,
        cachedMessages: [ChatTranscriptMessage] = [],
        persist: (@MainActor ([ChatTranscriptMessage]) -> Void)? = nil,
        retryDelays: [Duration] = ChatTranscriptStore.defaultRetryDelays,
        workingPollInterval: Duration = .seconds(3),
        localSendPollWindow: Duration = .seconds(180),
        blockedRecheckDelay: Duration = .seconds(1),
        now: @escaping @MainActor () -> ContinuousClock.Instant = { .now }
    ) {
        self.init(
            read: read, readScreen: readScreen, sendKeys: sendKeys,
            queueAnswer: queueAnswer, queuedAnswer: queuedAnswer,
            withdrawQueuedAnswer: withdrawQueuedAnswer,
            initialStatus: initialStatus,
            statusUpdateSource: { statusUpdates },
            cachedMessages: cachedMessages,
            persist: persist,
            retryDelays: retryDelays,
            workingPollInterval: workingPollInterval,
            localSendPollWindow: localSendPollWindow,
            blockedRecheckDelay: blockedRecheckDelay,
            now: now)
    }

    /// `statusUpdateSource` subscribes afresh on every `start()`.
    /// `cachedMessages` is shown until the first read lands; `persist` is
    /// not called for it.
    init(
        read: @escaping @MainActor (_ after: String?) async throws -> ChatTranscriptSnapshot,
        readScreen: @escaping @MainActor () async throws -> String,
        sendKeys: @escaping @MainActor ([String]) async throws -> Void,
        queueAnswer: (@MainActor (PendingBlockedAnswer) -> Void)? = nil,
        queuedAnswer: @escaping @MainActor () -> BlockedAnswerQueue.Entry? = { nil },
        withdrawQueuedAnswer: @escaping @MainActor () -> Void = {},
        initialStatus: AgentStatus,
        pendingRequests: (@MainActor () async throws -> [AgentPendingRequest])? = nil,
        answerRequest: (@MainActor (String, AgentRequestAnswer) async throws -> Void)? = nil,
        statusUpdateSource: @escaping @MainActor () -> AsyncStream<ConsoleStore.AgentStatusUpdate>?,
        cachedMessages: [ChatTranscriptMessage] = [],
        persist: (@MainActor ([ChatTranscriptMessage]) -> Void)? = nil,
        retryDelays: [Duration] = ChatTranscriptStore.defaultRetryDelays,
        workingPollInterval: Duration = .seconds(3),
        localSendPollWindow: Duration = .seconds(180),
        blockedRecheckDelay: Duration = .seconds(1),
        now: @escaping @MainActor () -> ContinuousClock.Instant = { .now }
    ) {
        self.read = read
        self.readScreen = readScreen
        self.pendingRequests = pendingRequests
        self.answerRequest = answerRequest
        approval = ChatApprovalMachine(structured: pendingRequests != nil)
        answerer = BlockedPromptAnswerer(
            readScreen: readScreen, sendKeys: sendKeys, queueAnswer: queueAnswer)
        self.queuedAnswer = queuedAnswer
        withdrawQueued = withdrawQueuedAnswer
        status = initialStatus
        makeStatusUpdates = statusUpdateSource
        messages = cachedMessages
        self.persist = persist
        acquisition = TranscriptAcquisitionMachine(retryDelays: retryDelays)
        self.workingPollInterval = workingPollInterval
        self.localSendPollWindow = localSendPollWindow
        self.blockedRecheckDelay = blockedRecheckDelay
        self.now = now
    }

    /// 1, 2, 4, 8, 15, then every 30 seconds.
    nonisolated static let defaultRetryDelays: [Duration] = [
        .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15), .seconds(30),
    ]

    deinit {
        statusTask?.cancel()
        for task in pollTasks.values { task.cancel() }
        screenTask?.cancel()
        for task in recheckTasks.values { task.cancel() }
        readTask?.cancel()
        retryTask?.cancel()
    }

    /// Full read, then follows Agent Status. Idempotent while started.
    func start() {
        guard !isStarted else { return }
        performAcquisition(acquisition.handle(.start))
        // Whatever was answered before the view left, the prompt on screen
        // now is read afresh before Allow or Cancel can answer it.
        updateApproval(.reset(.start))
        scheduleRead()
        refreshBlockedScreen()
        if let updates = makeStatusUpdates() {
            statusTask = Task { [weak self] in
                for await update in updates {
                    guard !Task.isCancelled, let self else { return }
                    let reconnected = !self.liveUpdatesAvailable && update.liveUpdatesAvailable
                    self.liveUpdatesAvailable = update.liveUpdatesAvailable
                    if let status = update.status { self.statusDidChange(status) }
                    if reconnected, self.usesStructuredRequests { self.refreshBlockedScreen() }
                }
            }
        }
        updatePolling()
    }

    func stop() {
        updateApproval(.stop)
        liveUpdatesAvailable = false
        statusTask?.cancel()
        statusTask = nil
        performPollingEffects(polling.handle(.stop))
        performAcquisition(acquisition.handle(.stop))
    }

    /// Reads now: in full until one full read has landed, then after the
    /// last message. A Blocked screen is read again too.
    func refresh() async {
        refreshBlockedScreen()
        await scheduleRead().value
    }

    /// Answers the Blocked question with Enter.
    func allow() async {
        await answerBlocked(["enter"])
    }

    /// Dismisses the Blocked question with Esc.
    func cancel() async {
        await answerBlocked(["esc"])
    }

    func answer(_ request: AgentPendingRequest, with answer: AgentRequestAnswer) async {
        guard canAnswerRequests, let answerRequest,
            case .sendRequest(let attempt, let id, let answer)? = handleApproval(.answerRequest(request.id, answer)).first
        else { return }
        let resolved: Bool
        do {
            try await answerRequest(id, answer)
            resolved = true
        } catch TransportError.apiRejected(code: "agent_request_resolved", message: _) {
            // The desk answered first. Its decision wins without an alert.
            resolved = true
        } catch {
            resolved = false
        }
        guard case .refreshAfterRequest(let token)? = handleApproval(.requestAnswered(attempt, resolved: resolved)).first
        else { return }
        // Discard a read begun before the answer; it could still contain
        // the now-resolved request. The next read sees the desk's decision.
        performAcquisition(acquisition.handle(.screenDiscarded))
        refreshBlockedScreen()
        await scheduleRead().value
        _ = handleApproval(.requestRefreshed(token))
    }

    /// The Blocked card's Retry after the screen could not be read.
    func retryBlockedScreen() {
        guard status == .blocked else { return }
        updateApproval(.retry)
        refreshBlockedScreen()
    }

    /// The Host's plugin now meets this build's minimum (#209): read again
    /// even though a read found it missing or outdated, which otherwise is
    /// never retried. The update's reconnect may still be settling, so the
    /// same answer is retried through `retryDelays` once before it is
    /// believed again.
    func recheckPlugin() {
        guard isStarted else { return }
        switch availability {
        case .pluginMissing, .pluginOutdated:
            performAcquisition(acquisition.handle(.pluginUpdated))
        case .loading, .ready, .waitingForConversation, .failed:
            break
        }
    }

    /// A message just went out from this device. herdr may report no status
    /// change for it (omp without herdr's omp integration reports idle for
    /// its whole turn), so the transcript is polled until a new reply lands
    /// or `localSendPollWindow` passes.
    func followLocalSend() {
        performPollingEffects(polling.handle(.follow(
            deadline: now() + localSendPollWindow,
            knownAssistantIDs: Set(messages.lazy.filter { $0.role == .assistant }.map(\.id)),
            started: isStarted, status: status, turnOpen: isTurnOpen)))
    }

    /// The composer messages the transcript does not account for yet, in
    /// their order.
    /// - A failed message stays until it is retried or withdrawn.
    /// - A message is matched by a transcript user message with the same
    ///   trimmed text that was not there yet when the message was first seen
    ///   (or retried). The newest messages claim the newest echoes, and each
    ///   transcript message matches at most one composer message.
    /// - A delivered message also settles once the Agent went idle or done
    ///   after it, or once a newer transcript message is timestamped at or
    ///   after its send. One sent while the Agent was busy settles only on a
    ///   user message, not on the reply that ends the turn it queued behind.
    func pendingMessages(
        _ composerMessages: [AgentComposerStore.Message]
    ) -> [AgentComposerStore.Message] {
        let isFirstLook = !hasSeenComposer
        hasSeenComposer = true
        let presentIDs = Set(messages.map(\.id))
        let liveIDs = Set(composerMessages.map(\.id))
        pendingTracks = pendingTracks.filter { liveIDs.contains($0.key) }
        var claimed: Set<String> = []
        var settled: Set<UUID> = []
        for message in composerMessages.reversed() {
            // Queued and held messages stay on screen like failed ones until
            // they go out or the user withdraws them.
            let isFailed = message.isUnsent
            var track = pendingTracks[message.id]
                ?? PendingTrack(
                    baseline: isFirstLook ? .predatesChat : .present(presentIDs),
                    wasFailed: isFailed)
            if track.wasFailed, !isFailed {
                // Retried: only what lands from now on accounts for it.
                track.baseline = .present(presentIDs)
            }
            track.wasFailed = isFailed
            pendingTracks[message.id] = track
            guard !isFailed else { continue }
            if let echo = echo(of: message, baseline: track.baseline, excluding: claimed) {
                claimed.insert(echo.id)
                settled.insert(message.id)
            } else if isSettled(message, baseline: track.baseline) {
                settled.insert(message.id)
            }
        }
        return composerMessages.filter { !settled.contains($0.id) }
    }

    /// The newest unclaimed transcript user message with the same text.
    private func echo(
        of message: AgentComposerStore.Message,
        baseline: EchoBaseline,
        excluding claimed: Set<String>
    ) -> ChatTranscriptMessage? {
        let text = Self.trimmed(message.text)
        return messages.last { candidate in
            candidate.role == .user
                && !claimed.contains(candidate.id)
                && baseline.admits(candidate.id)
                && Self.trimmed(candidate.text) == text
        }
    }

    /// Sends that never echo as a prompt (slash commands, a Blocked answer,
    /// an over-long message) settle once the conversation moved past them.
    private func isSettled(
        _ message: AgentComposerStore.Message, baseline: EchoBaseline
    ) -> Bool {
        guard case .delivered(let progress) = message.state else { return false }
        if progress == .done { return true }
        let isQueued = progress == .agentBusy
        return messages.contains { candidate in
            guard let timestamp = candidate.timestamp, timestamp >= message.sentAt,
                baseline.admits(candidate.id)
            else { return false }
            return candidate.role == .user || !isQueued
        }
    }

    // MARK: - Status

    private func statusDidChange(_ newStatus: AgentStatus) {
        // The Console republishes every Agent's current status on each of
        // its rebuilds, so a repeat says nothing new. A new question under
        // the same status shows up on the poll, and an answer checks the
        // prompt before it sends.
        guard newStatus != status else { return }
        status = newStatus
        updateApproval(.reset(.statusChanged))
        if newStatus == .blocked {
            refreshBlockedScreen()
        } else {
            clearBlockedScreen()
        }
        scheduleRead()
        updatePolling()
    }

    /// Sends `keys` only to the prompt on display (`BlockedPromptAnswerer`):
    /// the screen is read first, since it can change under the same status
    /// (a second question, an answer typed on the Mac). A different prompt
    /// is shown for its own answer instead; an unreadable screen leaves
    /// nothing to answer.
    private func answerBlocked(_ keys: [String]) async {
        guard canAnswerBlocked,
            case .checkScreen(let attempt, let shown)? = handleApproval(.answerScreen).first
        else { return }
        let outcome = await answerer.answer(keys: keys, shown: shown) { [weak self] in
            // A status change or a newer screen read meanwhile already
            // settled the card.
            guard let self else { return false }
            return self.status == .blocked && self.approval.wantsScreenAnswer(attempt, shown: shown)
        }
        updateApproval(.screenAnswered(attempt, outcome))
    }

    /// Do not publish the same prompt again on every poll, or a stale
    /// answer's no-op. Previously the screen's setters checked equality.
    private func handleApproval(_ event: ChatApprovalMachine.Event) -> [ChatApprovalMachine.Effect] {
        var next = approval
        let effects = next.handle(event)
        if next != approval { approval = next }
        return effects
    }

    /// Async answer admission effects are consumed by `answer` and
    /// `answerBlocked`; all other approval events only maintain the card
    /// or its delayed screen recheck.
    private func updateApproval(_ event: ChatApprovalMachine.Event) {
        for effect in handleApproval(event) {
            switch effect {
            case .cancelRecheck:
                for task in recheckTasks.values { task.cancel() }
                recheckTasks.removeAll()
            case .armRecheck(let token):
                let delay = blockedRecheckDelay
                recheckTasks[token] = Task { [weak self] in
                    do { try await Task.sleep(for: delay) } catch { return }
                    guard let self, !Task.isCancelled else { return }
                    self.recheckTasks[token] = nil
                    self.updateApproval(.recheckElapsed(token))
                }
            case .refreshScreen:
                refreshBlockedScreen()
            case .checkScreen, .sendRequest, .refreshAfterRequest:
                // Only emitted by the public async answer entrypoints.
                assertionFailure("Answer effects require an awaiting caller")
            }
        }
    }

    /// Reads the visible screen while Blocked. Reads never overlap; one
    /// asked for meanwhile runs once after it.
    private func refreshBlockedScreen() {
        guard status == .blocked else { return }
        performAcquisition(acquisition.handle(.requested(.screen)))
    }

    private func readBlockedScreen() async {
        if let pendingRequests {
            do {
                let pending = try await pendingRequests()
                guard !Task.isCancelled, status == .blocked else { return }
                updateApproval(.requestsRead(pending))
            } catch {
                guard !Task.isCancelled, status == .blocked else { return }
                updateApproval(.requestsRead(nil))
            }
            return
        }
        let screen: String?
        do {
            let text = try await readScreen()
            screen = BlockedPromptAnswerer.screenText(from: text)
        } catch {
            screen = nil
        }
        guard !Task.isCancelled, status == .blocked else { return }
        updateApproval(.screenRead(screen))
    }

    private func clearBlockedScreen() {
        performAcquisition(acquisition.handle(.screenDiscarded))
        updateApproval(.reset(.clear))
    }

    // MARK: - Reads

    private func updatePolling() {
        performPollingEffects(polling.handle(.configure(
            started: isStarted, status: status, turnOpen: isTurnOpen)))
    }

    /// The owner holds only token-keyed Tasks; demand and local-reply
    /// baselines belong to the machine. A poll awaits its transcript read
    /// before sleeping again, as before.
    private func performPollingEffects(_ effects: [ChatPollingMachine.Effect]) {
        for effect in effects {
            switch effect {
            case .cancel(let token):
                pollTasks.removeValue(forKey: token)?.cancel()
            case .start(let token):
                let interval = workingPollInterval
                pollTasks[token] = Task { [weak self] in
                    while true {
                        do { try await Task.sleep(for: interval) } catch { return }
                        guard let self, !Task.isCancelled else { return }
                        let effects = self.polling.handle(.tick(
                            token, now: self.now(), status: self.status, turnOpen: self.isTurnOpen))
                        self.performPollingEffects(effects)
                        guard self.polling.pollToken == token else { return }
                        // Only a tick emits .poll, consumed here so the
                        // current loop awaits the read rather than spawning it.
                        for case .poll(let readTranscript) in effects {
                            self.refreshBlockedScreen()
                            if readTranscript { await self.scheduleRead().value }
                        }
                    }
                }
            case .poll:
                break // Awaited by the loop above.
            }
        }
    }

    /// Reads the transcript; one asked for meanwhile runs once after the
    /// read in flight, whose Task this returns.
    @discardableResult
    private func scheduleRead() -> Task<Void, Never> {
        performAcquisition(acquisition.handle(.requested(.transcript)))
        guard let readTask else {
            assertionFailure("A requested read always has a pass running")
            return Task {}
        }
        return readTask
    }

    /// The acquisition machine's effects. A pass's loop reads, then asks
    /// whether it goes round again; a token the machine retired (stop, a
    /// discarded screen read) finishes nothing.
    private func performAcquisition(_ effects: [TranscriptAcquisitionMachine.Effect]) {
        for effect in effects {
            switch effect {
            case .startPass(let reader, let token):
                let task = Task { [weak self] in
                    while let self, !Task.isCancelled {
                        _ = self.acquisition.handle(.passBegan(reader, token))
                        switch reader {
                        case .transcript: await self.performRead()
                        case .screen: await self.readBlockedScreen()
                        }
                        let ended = self.acquisition.handle(.passEnded(reader, token))
                        guard ended != [.runAgain] else { continue }
                        self.performAcquisition(ended)
                        return
                    }
                }
                switch reader {
                case .transcript: readTask = task
                case .screen: screenTask = task
                }
            case .cancelPass(.transcript):
                readTask?.cancel()
                readTask = nil
            case .cancelPass(.screen):
                screenTask?.cancel()
                screenTask = nil
            case .passFinished(.transcript):
                readTask = nil
                updatePolling()
            case .passFinished(.screen):
                screenTask = nil
            case .runAgain, .show, .merge:
                break // Consumed by the pass loop and `apply`.
            case .armRetry(let token, let delay):
                retryTask = Task { [weak self] in
                    do { try await Task.sleep(for: delay) } catch { return }
                    guard let self, !Task.isCancelled else { return }
                    let effects = self.acquisition.handle(.retryElapsed(token))
                    guard !effects.isEmpty else { return }
                    self.retryTask = nil
                    self.performAcquisition(effects)
                }
            case .cancelRetry:
                retryTask?.cancel()
                retryTask = nil
            case .scheduleRead:
                scheduleRead()
            }
        }
    }

    /// A read that does not find the transcript keeps the list and is tried
    /// again, unless no later read can do better (no plugin, an outdated
    /// one, a harness without a chat) — short of a plugin update
    /// (`recheckPlugin()`).
    private func performRead() async {
        let after = acquisition.state.needsFullRead ? nil : messages.last?.id
        let snapshot: ChatTranscriptSnapshot
        do {
            snapshot = try await read(after)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            let availability = Self.availability(for: error)
            self.availability = availability
            let pluginGap: Bool
            switch availability {
            case .pluginMissing, .pluginOutdated: pluginGap = true
            case .loading, .ready, .waitingForConversation, .failed: pluginGap = false
            }
            performAcquisition(acquisition.handle(.readFailed(pluginGap: pluginGap)))
            return
        }
        guard !Task.isCancelled else { return }
        apply(snapshot, after: after)
    }

    /// Only a read that found the transcript changes the list.
    private func apply(_ snapshot: ChatTranscriptSnapshot, after: String?) {
        let header = snapshot.header
        switch header.status {
        case .ok:
            availability = .ready
        case .notFound:
            availability = .waitingForConversation
            performAcquisition(acquisition.handle(.answered(.notFound)))
            applyActivity(of: header)
            return
        case .unsupported:
            availability = .failed("This Agent can't show a chat.")
            performAcquisition(acquisition.handle(.answered(.unsupported)))
            applyActivity(of: header)
            return
        case .error:
            // A reader error says nothing about the turn: activity and the
            // open turn stay as last read.
            availability = .failed(header.error ?? Self.unreadableMessage)
            performAcquisition(acquisition.handle(.answered(.readerError)))
            return
        }
        // An after-id the reader no longer knows (an omp retry re-anchors a
        // reply, a turn continued after idle) makes it answer with every
        // message: the list restarted. A moved transcript (`/clear`) is read
        // again in full instead.
        let isWholeList = after == nil || !header.afterFound
        for effect in acquisition.handle(.answered(.found(
            transcript: header.transcript, wholeList: isWholeList)))
        {
            switch effect {
            case .show: show(snapshot.messages)
            case .merge: merge(snapshot.messages)
            default: performAcquisition([effect])
            }
        }
        applyActivity(of: header)
    }

    private func applyActivity(of header: ChatTranscriptHeader) {
        activity = header.activity
        isTurnOpen = header.turnOpen
        _ = polling.handle(.messagesChanged(messages))
    }

    /// Keeps known messages in place and appends unseen ids in order.
    private func merge(_ incoming: [ChatTranscriptMessage]) {
        guard !incoming.isEmpty else { return }
        show(ChatTranscriptMerge.appending(incoming, to: messages))
    }

    /// Replaces the list and keeps it on this device; the same list again
    /// neither re-renders nor writes.
    private func show(_ newMessages: [ChatTranscriptMessage]) {
        guard newMessages != messages else { return }
        messages = newMessages
        persist?(newMessages)
    }

    static func availability(for error: any Error) -> Availability {
        switch error {
        case NotificationRegistrationError.pluginNotInstalled:
            .pluginMissing
        case ChatTranscriptError.readerUnavailable:
            .pluginOutdated
        case ChatTranscriptError.malformedOutput:
            .failed(unreadableMessage)
        case let error as TransportError:
            .failed(error.presentation.message)
        case let error as HerdrAPIError:
            .failed(error.message)
        default:
            .failed(unreadableMessage)
        }
    }

    private static let unreadableMessage = "The conversation couldn't be read."

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
