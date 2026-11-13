import Foundation
import UIKit

/// The iPhone end of the Apple Watch app (ADR 0029, docs/design/
/// apple-watch-v0.md §6.2, §7.1). It publishes the Watch State as
/// application context, latest wins, titles and statuses only, never Agent
/// text; and answers the watch's requests: Latest text and Blocked prompts
/// read on demand, Allow/Deny under the shown-prompt guard, and messages
/// typed or spoken on the watch, acknowledged at once and reported later.
/// Only Agents the watch lists are read, answered or sent to: never a Shell
/// or a pane the request merely names.
///
/// A request may arrive with the app in the background and no window: the
/// bridge holds the app awake for the request (headless start), starting
/// the app model and holding the `.watch` activity source, and keeps that
/// hold while the watch app stays reachable. Every request gets exactly one
/// reply: when the background time runs out first, each request still
/// waiting is answered "ran out of time" before the app is let go.
@MainActor
final class WatchBridge {
    // MARK: Configuration

    /// How long the bridge waits on each thing.
    struct Timing {
        /// How long a request waits for its Host to be confirmed.
        var hostDeadline: Duration = .seconds(6)
        /// How often the Host wait looks again.
        var hostPoll: Duration = .milliseconds(250)
        /// How long a screen or transcript read, or a message's send, may
        /// take once connected; a send past it reads as `.unknown`.
        var readDeadline: Duration = .seconds(8)
        /// How long an Allow or Deny may take once connected; past it the
        /// answer reads as failed, and a retry has to read the prompt anew.
        var answerDeadline: Duration = .seconds(8)
        /// How long transcribing one recording may take.
        var transcriptionDeadline: Duration = .seconds(20)
        /// How long a voice message waits for its recording.
        var recordingWait: Duration = .seconds(20)
        /// How long a recording waits for its voice message. Long enough for
        /// a wrist kept down while the watch holds the voice message back.
        var unclaimedRecordingLifetime: Duration = .seconds(300)
        /// Changes within this window publish once.
        var publishCoalescing: Duration = .seconds(1)
    }

    /// What the bridge reads and does, as closures so tests run it against
    /// fakes (as `AgentActionService.Dependencies` does).
    struct Dependencies {
        /// The Console facts the Watch State is built from, now.
        var source: @MainActor () -> WatchStateSource
        /// Whether the Host credentials can be read (false before the first
        /// unlock after a restart).
        var keychainReadable: @MainActor () -> Bool
        /// The Agent's last reply from its transcript, cleaned
        /// (`WatchStateBuilder.lastReply(from:)`); nil when unreadable or
        /// empty. Asked only when `WatchStateBuilder.readsTranscript` says so.
        var lastReply: @MainActor (ConsoleAgent) async -> String?
        /// `AgentActionService.blockedPrompt(for:)`.
        var blockedPrompt: @MainActor (ConsoleAgent.ID) async throws -> BlockedPromptSnapshot?
        /// `AgentActionService.answer(allow:agentID:shown:)`.
        var answer:
            @MainActor (Bool, ConsoleAgent.ID, BlockedPromptSnapshot) async ->
                AgentActionService.AnswerOutcome
        /// `AgentActionService.send(_:to:suffix:)` with no suffix.
        var send: @MainActor (String, ConsoleAgent.ID) async -> AgentActionService.SendOutcome
        /// Transcribes recordings; nil below iOS 26.
        var transcriber: (any AudioFileTranscribing)?
        /// The app is needed awake: start it, hold `.watch`, and take
        /// background time. The closure runs when that time runs out.
        var hold: @MainActor (_ onExpiration: @escaping @MainActor @Sendable () -> Void) -> Void
        /// The app is no longer needed awake for the watch.
        var release: @MainActor () -> Void
        /// The wall clock, for status stamps and the Watch State's age.
        var now: @MainActor () -> Date
    }

    /// The user-facing copy the bridge replies with.
    enum Copy {
        /// The watch spoke a wire version this build does not.
        static let updatePhone = "Update Waycar on your iPhone"
        /// The Host credentials are unreadable until the phone is unlocked.
        static let unlockPhone = "Unlock your iPhone"
        /// A voice message whose recording never arrived.
        static let recordingMissing = "Recording didn't reach iPhone"
        /// The Agent is no longer listed.
        static let agentGone = "This Agent is gone"
        /// The Blocked screen read blank.
        static let promptUnreadable = "Couldn't read the prompt"
        /// Transcription failed.
        static let transcriptionFailed = "Couldn't transcribe the recording"
        /// This iPhone has no file transcriber.
        static let transcriptionUnavailable = "This iPhone can't transcribe voice"
        /// The Host is not in this iPhone's catalog, or disabled.
        static let hostMissing = "This Host isn't on your iPhone"
        /// Background time ran out before the request finished.
        static let ranOutOfTime = "Waycar on iPhone ran out of time — open it"
        /// A reply that could not be encoded.
        static let replyFailed = "Waycar on iPhone couldn't reply"

        /// A Host still connecting.
        static func connecting(_ host: String) -> String { "\(host) is still connecting" }
        /// A Host the phone cannot reach.
        static func unreachable(_ host: String) -> String { "Can't reach \(host)" }
    }

    /// How many finished messages and kept prompts are remembered.
    static let memoryLimit = 64

    // MARK: State

    /// The WatchConnectivity session.
    private let channel: any WatchSessionChannel
    /// The Console, actions and app the bridge drives.
    private let dependencies: Dependencies
    /// The bridge's waits.
    private let timing: Timing

    /// Whether `activate()` ran; nothing publishes before.
    private var isActivated = false
    /// Follows the Console once publishing starts.
    private var sourceObserver: StoreChangeObserver<WatchStateSource>?
    /// When each listed Agent's current status began, as far as seen.
    private var stamps = WatchStatusStamps()
    /// The last state the watch was given; an equal one is not resent.
    private var lastPublished: WatchState?
    /// The last state built, published or replied; its rows stand in for a
    /// Host's while that Host is not confirmed.
    private var lastBuilt: WatchState?
    /// The pending coalesced publish.
    private var publishTask: Task<Void, Never>?

    /// The shared activity lease; reply handlers remain resources in this owner.
    private var activityLease = WatchActivityLeaseMachine()

    /// Every request still owed a reply, by request number: background
    /// time running out answers them all, so the watch is never left
    /// waiting on a frozen app.
    private var openReplies: [Int: WatchReplySlot] = [:]
    /// Numbers the requests in the log.
    private var requestCount = 0

    /// Dedupe, retry transcripts and token-guarded outcomes for recent messages.
    private var messageLedger = WatchMessageLedgerMachine()
    /// File/envelope pairing, independent of their arrival order.
    private var recordingRendezvous = WatchRecordingRendezvousMachine()
    /// Timer and activity resources keyed by the rendezvous's minted token.
    private var recordingTimers: [UInt64: Task<Void, Never>] = [:]
    private var recordingHolds: [UInt64: UUID] = [:]

    /// Shown-prompt ownership and first-answer deduplication.
    private var approvalLedger = WatchApprovalLedgerMachine()
    /// Work remains in the owner, keyed by the ledger's operation token.
    private var answerTasks: [UInt64: Task<WatchReply, Never>] = [:]

    /// A bridge over `channel`; `activate()` starts it.
    init(
        channel: any WatchSessionChannel, dependencies: Dependencies, timing: Timing = Timing()
    ) {
        self.channel = channel
        self.dependencies = dependencies
        self.timing = timing
    }

    // MARK: Lifecycle

    /// Starts the WatchConnectivity session. Called once, from
    /// `application(_:willFinishLaunchingWithOptions:)`, so transfers queued
    /// while the app was not running are delivered.
    func activate() {
        guard !isActivated else { return }
        isActivated = true
        channel.activate()
    }

    /// Starts following the Console and publishing the Watch State.
    /// Idempotent; called once the app model exists (a window, CarPlay, or
    /// a watch request built it).
    func startPublishing() {
        guard isActivated, sourceObserver == nil else { return }
        sourceObserver = StoreChangeObserver(
            read: { [weak self] in self?.dependencies.source() ?? .empty },
            onChange: { [weak self] source in self?.sourceDidChange(source) })
        sourceDidChange(dependencies.source())
    }

    /// The session finished activating. A cold-launched app takes the last
    /// published Watch State as its last built one, so a Host not yet
    /// confirmed keeps its rows instead of the watch losing them.
    func sessionDidActivate(isReachable: Bool) {
        lastPublished = nil
        if lastBuilt == nil, let data = channel.lastApplicationContext {
            lastBuilt = try? WatchWireCodec.decode(WatchState.self, from: data)
        }
        if sourceObserver != nil { schedulePublish() }
        reachabilityDidChange(isReachable)
    }

    /// The watch app came to the foreground or left it. While it is
    /// reachable the app is held awake, so its requests find the Hosts
    /// connected.
    func reachabilityDidChange(_ isReachable: Bool) {
        updateActivityLease(.reachability(isReachable))
    }

    /// Pairing or the watch app's installation changed: publish afresh.
    func watchStateDidChange() {
        lastPublished = nil
        if sourceObserver != nil { schedulePublish() }
    }

    // MARK: Publishing

    private func sourceDidChange(_ source: WatchStateSource) {
        stamps.observe(source.agents, at: dependencies.now())
        schedulePublish()
    }

    private func schedulePublish() {
        guard publishTask == nil else { return }
        publishTask = Task { [weak self, timing] in
            try? await Task.sleep(for: timing.publishCoalescing)
            guard let self else { return }
            publishTask = nil
            publishNow()
        }
    }

    /// Publishes the Watch State unless it is unchanged or the Console is
    /// suspended in the background: its Hosts are not confirmed then, and
    /// a refresh request still gets the state with its rows kept.
    private func publishNow() {
        let source = dependencies.source()
        guard channel.canPublish, !source.isSuspended else { return }
        let state = currentState(source)
        if let lastPublished, Self.sameContent(lastPublished, state) { return }
        guard let data = try? WatchWireCodec.encode(state) else { return }
        do {
            try channel.updateApplicationContext(data)
            lastPublished = state
        } catch {
            // Not activated or no watch: the next change tries again.
            let nsError = error as NSError
            WatchLog.logger.error(
                "Watch State not published: \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public)")
        }
    }

    /// The Watch State now, with the status stamps brought up to date and
    /// the rows of Hosts not yet confirmed kept from the last state built.
    private func currentState(_ source: WatchStateSource? = nil) -> WatchState {
        let source = source ?? dependencies.source()
        let now = dependencies.now()
        stamps.observe(source.agents, at: now)
        let state = WatchStateBuilder.state(from: source, stamps: stamps, previous: lastBuilt, now: now)
        lastBuilt = state
        return state
    }

    /// Equal but for when it was built.
    private static func sameContent(_ lhs: WatchState, _ rhs: WatchState) -> Bool {
        lhs.hosts == rhs.hosts && lhs.rows == rhs.rows
            && lhs.voiceTranscription == rhs.voiceTranscription
    }

    // MARK: Requests

    /// One `sendMessageData` from the watch. `reply` is nil when the watch
    /// sent without a reply handler; otherwise it is called exactly once.
    func receive(messageData: Data, reply handler: (@MainActor @Sendable (Data) -> Void)?) {
        sweepUnclaimedRecordings()
        requestCount += 1
        let number = requestCount
        let request: WatchRequest
        do {
            request = try WatchWireCodec.decode(WatchRequest.self, from: messageData)
        } catch {
            // Another wire version, or a shape this build does not know.
            WatchLog.logger.error(
                "request #\(number, privacy: .public) of \(messageData.count, privacy: .public) bytes did not decode")
            respond(.failure(Copy.updatePhone), via: slot(for: handler, number: number, type: "undecodable"))
            return
        }
        WatchLog.logger.notice(
            "request #\(number, privacy: .public) \(request.logType, privacy: .public) received, message \(request.logMessageID, privacy: .public)")
        let reply = slot(for: handler, number: number, type: request.logType)
        switch request {
        case .refresh:
            let hold = acquireHold()
            startPublishing()
            respond(.state(currentState()), via: reply)
            releaseHold(hold)
        case .latest(let id):
            guard unlocked(reply) else { return }
            readLatest(id.consoleID, reply: reply)
        case .blockedPrompt(let id):
            guard unlocked(reply) else { return }
            readBlockedPrompt(id.consoleID, reply: reply)
        case .answer(let id, let promptID, let answer):
            self.answer(answer, promptID: promptID, agentID: id.consoleID, reply: reply)
        case .send(let messageID, let id, let text):
            guard !reportedAgain(messageID, reply: reply), unlocked(reply) else { return }
            respond(.received, via: reply)
            sendText(text, messageID: messageID, agentID: id.consoleID)
        case .voice(let messageID, let id):
            guard !reportedAgain(messageID, reply: reply), unlocked(reply) else { return }
            respond(.received, via: reply)
            voiceMessageArrived(messageID, agentID: id.consoleID)
        }
    }

    /// Sends a Done notification's text reply (below iOS 26 the watch has
    /// no recorder and replies with system text input, delivered here),
    /// under the same rules as a watch message: the phone unlocked, the
    /// Host confirmed, and only to a listed Agent.
    /// - Returns: what became of it; `.notSent` with the bridge's copy when
    ///   it never went out.
    func sendNotificationReply(_ text: String, to agentID: ConsoleAgent.ID) async
        -> AgentActionService.SendOutcome
    {
        guard dependencies.keychainReadable() else { return .notSent(reason: Copy.unlockPhone) }
        let hold = acquireHold()
        defer { releaseHold(hold) }
        if let failure = await waitForHost(agentID.hostID) { return .notSent(reason: failure) }
        guard listedAgent(agentID) != nil else { return .notSent(reason: Copy.agentGone) }
        return await sendWithinDeadline(text, to: agentID)
    }

    // MARK: Latest

    private func readLatest(_ id: ConsoleAgent.ID, reply: WatchReplySlot?) {
        let hold = acquireHold()
        Task {
            defer { releaseHold(hold) }
            if let failure = await waitForHost(id.hostID) {
                respond(.failure(failure), via: reply)
                return
            }
            let source = dependencies.source()
            guard let agent = listedAgent(id, in: source) else {
                respond(.failure(Copy.agentGone), via: reply)
                return
            }
            let readsTranscript = WatchStateBuilder.readsTranscript(
                agent, isChatMode: source.chatModeAgents.contains(id))
            // Only the transcript read races the deadline: a slow one falls
            // back to the summary already on the phone.
            var lastReply: String?
            if readsTranscript {
                let started = ContinuousClock.now
                let read = await race(timing.readDeadline) { [weak self] () -> String? in
                    await self?.dependencies.lastReply(agent)
                }
                if let read {
                    lastReply = read
                } else {
                    WatchLog.logger.notice(
                        "request #\(reply?.number ?? 0, privacy: .public) latest: transcript read gave up after \(WatchLog.milliseconds(since: started), privacy: .public) ms; summary instead")
                }
            }
            let latest = WatchStateBuilder.latest(
                for: agent, reply: lastReply, now: dependencies.now())
            respond(.latest(latest), via: reply)
        }
    }

    // MARK: Blocked prompts

    private func readBlockedPrompt(_ id: ConsoleAgent.ID, reply: WatchReplySlot?) {
        let hold = acquireHold()
        Task {
            defer { releaseHold(hold) }
            if let failure = await waitForHost(id.hostID) {
                respond(.failure(failure), via: reply)
                return
            }
            guard listedAgent(id) != nil else {
                respond(.failure(Copy.agentGone), via: reply)
                return
            }
            let read = await race(timing.readDeadline) {
                [weak self] () -> Result<BlockedPromptSnapshot?, any Error> in
                guard let self else { return .failure(CancellationError()) }
                do {
                    return .success(try await dependencies.blockedPrompt(id))
                } catch {
                    return .failure(error)
                }
            }
            guard let read else {
                respond(.failure(Copy.unreachable(hostName(id.hostID))), via: reply)
                return
            }
            switch read {
            case .success(nil):
                respond(.blockedPrompt(nil), via: reply)
            case .success(let snapshot?):
                let promptID = keep(snapshot, for: id)
                respond(
                    .blockedPrompt(WatchStateBuilder.blockedPrompt(snapshot, promptID: promptID)),
                    via: reply)
            case .failure(let error):
                switch error as? AgentActionService.BlockedPromptError {
                case .notListed: respond(.failure(Copy.agentGone), via: reply)
                case .unreadable: respond(.failure(Copy.promptUnreadable), via: reply)
                case nil: respond(.failure(Copy.unreachable(hostName(id.hostID))), via: reply)
                }
            }
        }
    }

    /// Keeps `snapshot` under a new prompt id, replacing the Agent's
    /// earlier one: only the prompt the watch shows last can be answered.
    private func keep(_ snapshot: BlockedPromptSnapshot, for id: ConsoleAgent.ID) -> UUID {
        let promptID = UUID()
        performApprovalEffects(approvalLedger.handle(.read(promptID, .init(agentID: id, snapshot: snapshot))))
        return promptID
    }

    private func answer(
        _ answer: WatchAnswer, promptID: UUID, agentID: ConsoleAgent.ID, reply: WatchReplySlot?
    ) {
        performApprovalEffects(
            approvalLedger.handle(.answer(promptID, agentID, answer, unlocked: dependencies.keychainReadable())),
            promptID: promptID, reply: reply)
    }

    private func performApprovalEffects(
        _ effects: [WatchApprovalLedgerMachine.Effect], promptID: UUID? = nil,
        reply: WatchReplySlot? = nil
    ) {
        for effect in effects {
            switch effect {
            case .start(let token, let prompt, let choice):
                guard let promptID else { continue }
                let hold = acquireHold()
                let task = Task { await runAnswer(promptID, token: token, prompt: prompt, choice: choice) }
                answerTasks[token] = task
                Task {
                    defer { releaseHold(hold) }
                    respond(await task.value, via: reply)
                }
            case .join(let token, let sameChoice):
                guard let task = answerTasks[token] else { continue }
                let hold = acquireHold()
                Task {
                    defer { releaseHold(hold) }
                    let first = await task.value
                    respond(sameChoice ? first : .answerResult(.promptChanged), via: reply)
                }
            case .reply(let value): respond(value, via: reply)
            case .unlockRequired: respond(.failure(Copy.unlockPhone), via: reply)
            case .forgetTask(let token): answerTasks[token] = nil
            }
        }
    }

    private func runAnswer(
        _ promptID: UUID, token: UInt64, prompt: WatchApprovalLedgerMachine.Prompt, choice: WatchAnswer
    ) async -> WatchReply {
        let agentID = prompt.agentID
        if let failure = await waitForHost(agentID.hostID) {
            performApprovalEffects(approvalLedger.handle(.hostFailed(promptID, token: token)))
            return .failure(failure)
        }
        guard listedAgent(agentID) != nil else {
            let reply = WatchReply.failure(Copy.agentGone)
            performApprovalEffects(approvalLedger.handle(.completed(promptID, token: token, reply: reply, keep: false)))
            return reply
        }
        let outcome = await race(timing.answerDeadline) {
            [weak self] () -> AgentActionService.AnswerOutcome in
            guard let self else { return .failed }
            return await dependencies.answer(choice == .allow, agentID, prompt.snapshot)
        }
        let result = outcome.map(Self.watchOutcome) ?? .failed
        let reply = WatchReply.answerResult(result)
        performApprovalEffects(approvalLedger.handle(.completed(promptID, token: token, reply: reply, keep: result != .failed)))
        // A request still receives its own outcome even if bounded ledger memory
        // evicted it meanwhile. It cannot mutate a newer ledger operation.
        return reply
    }

    private static func watchOutcome(_ outcome: AgentActionService.AnswerOutcome)
        -> WatchAnswerOutcome
    {
        switch outcome {
        case .sent: .sent
        case .promptChanged: .promptChanged
        case .refused: .refused
        case .failed: .failed
        }
    }

    // MARK: Messages

    /// Whether `messageID` was seen before and needs nothing new: still
    /// on its way (its outcome will follow), or final (re-reported now). A
    /// definite not-sent is a retry and goes through again.
    private func reportedAgain(_ messageID: UUID, reply: WatchReplySlot?) -> Bool {
        let effects = messageLedger.handle(.receive(messageID))
        for effect in effects {
            switch effect {
            case .acknowledge: respond(.received, via: reply)
            case .deliver(let event): deliver(event)
            case .process: break
            }
        }
        return !effects.isEmpty
    }

    private func sendText(_ text: String, messageID: UUID, agentID: ConsoleAgent.ID) {
        beginMessage(messageID, agentID: agentID) { token, _ in
            let hold = acquireHold()
            Task {
                defer { releaseHold(hold) }
                let delivery = await send(text, to: agentID)
                finish(messageID, token: token, delivery: delivery, transcript: nil)
            }
        }
    }

    /// Only the ledger can start an operation and mint its completion token.
    private func beginMessage(
        _ messageID: UUID, agentID: ConsoleAgent.ID,
        perform: (UInt64, String?) -> Void
    ) {
        for effect in messageLedger.handle(.begin(messageID, agentID)) {
            switch effect {
            case .process(let token, let transcript): perform(token, transcript)
            case .acknowledge, .deliver: break
            }
        }
    }

    private func voiceMessageArrived(_ messageID: UUID, agentID: ConsoleAgent.ID) {
        beginMessage(messageID, agentID: agentID) { token, transcript in
            prepareVoiceMessage(messageID, agentID: agentID, token: token, transcript: transcript)
        }
    }

    private func prepareVoiceMessage(
        _ messageID: UUID, agentID: ConsoleAgent.ID, token: UInt64, transcript: String?
    ) {
        if let transcript {
            // Transcribed before and definitely not sent: send that again.
            let hold = acquireHold()
            Task {
                defer { releaseHold(hold) }
                let delivery = await send(transcript, to: agentID)
                finish(messageID, token: token, delivery: delivery, transcript: transcript)
            }
            return
        }
        updateRecordingRendezvous(.message(messageID, agentID, token: token))
    }

    /// One `transferFile` from the watch, already moved out of the inbox
    /// (nil when that failed). `metadata` is the encoded `WatchVoiceFile`.
    func receive(recordingAt url: URL?, metadata: Data?) {
        sweepUnclaimedRecordings()
        guard let url else {
            WatchLog.logger.error("recording could not be kept; dropped")
            return
        }
        guard let metadata,
            let file = try? WatchWireCodec.decode(WatchVoiceFile.self, from: metadata)
        else {
            WatchLog.logger.error("recording without readable metadata; deleted")
            WatchRecordingFiles.remove(url)
            return
        }
        let messageID = file.messageID
        let acceptUnclaimed: Bool
        switch messageLedger.state.records[messageID] {
        case .processing, .finished: acceptUnclaimed = false
        case .retryable, nil: acceptUnclaimed = true
        }
        updateRecordingRendezvous(.file(messageID, url, arrived: dependencies.now(), acceptUnclaimed: acceptUnclaimed))
    }

    /// Deletes every recording that has waited longer than
    /// `unclaimedRecordingLifetime` for its message. Each one's own timer
    /// does not run while the app is suspended, so every request sweeps too.
    private func sweepUnclaimedRecordings() {
        let lifetime = timing.unclaimedRecordingLifetime.components
        let cutoff = dependencies.now().addingTimeInterval(
            -(TimeInterval(lifetime.seconds) + TimeInterval(lifetime.attoseconds) * 1e-18))
        updateRecordingRendezvous(.sweep(cutoff: cutoff))
    }

    private func updateRecordingRendezvous(_ event: WatchRecordingRendezvousMachine.Event) {
        for effect in recordingRendezvous.handle(event) {
            switch effect {
            case .waitForFile(let messageID, let token):
                recordingHolds[token] = acquireHold()
                recordingTimers[token] = Task { [weak self, timing] in
                    try? await Task.sleep(for: timing.recordingWait)
                    guard !Task.isCancelled else { return }
                    self?.updateRecordingRendezvous(.waitExpired(messageID, token: token))
                }
            case .armExpiry(let messageID, let token):
                recordingTimers[token] = Task { [weak self, timing] in
                    try? await Task.sleep(for: timing.unclaimedRecordingLifetime)
                    guard !Task.isCancelled else { return }
                    self?.updateRecordingRendezvous(.fileExpired(messageID, token: token))
                }
            case .cancelTimer(let token):
                recordingTimers.removeValue(forKey: token)?.cancel()
            case .delete(let url):
                WatchRecordingFiles.remove(url)
            case .transcribe(let messageID, let url, let agentID, let messageToken, let waiting):
                let hold: UUID
                if let waiting {
                    guard let existing = recordingHolds.removeValue(forKey: waiting) else { continue }
                    hold = existing
                } else {
                    hold = acquireHold()
                }
                transcribeAndSend(url, messageID: messageID, agentID: agentID, hold: hold, token: messageToken)
            case .missing(let messageID, let messageToken, let waiting):
                finish(messageID, token: messageToken, delivery: .notSent(reason: Copy.recordingMissing), transcript: nil)
                if let waiting, let hold = recordingHolds.removeValue(forKey: waiting) { releaseHold(hold) }
            }
        }
    }

    /// The words of a recording, or the not-sent copy for why there are none.
    private enum Transcription: Sendable {
        /// The transcript, trimmed; empty when nothing was said.
        case words(String)
        /// Not transcribed: no transcriber, it failed, or it ran out of time.
        case failed(reason: String)

        /// The outcome's kind as the log names it; never the words.
        var logType: String {
            switch self {
            case .words(let transcript): transcript.isEmpty ? "empty" : "words"
            case .failed: "failed"
            }
        }
    }

    private func transcribeAndSend(
        _ url: URL, messageID: UUID, agentID: ConsoleAgent.ID, hold: UUID, token: UInt64
    ) {
        Task {
            defer { releaseHold(hold) }
            let started = ContinuousClock.now
            let transcription = await transcribe(url)
            WatchLog.logger.notice(
                "message \(messageID.uuidString, privacy: .public) transcription \(transcription.logType, privacy: .public) in \(WatchLog.milliseconds(since: started), privacy: .public) ms")
            WatchRecordingFiles.remove(url)
            switch transcription {
            case .failed(let reason):
                finish(
                    messageID, token: token, delivery: .notSent(reason: reason), transcript: nil)
            case .words(let transcript) where transcript.isEmpty:
                finish(messageID, token: token, delivery: .noWords, transcript: nil)
            case .words(let transcript):
                let delivery = await send(transcript, to: agentID)
                finish(messageID, token: token, delivery: delivery, transcript: transcript)
            }
        }
    }

    /// Transcribes the recording within `transcriptionDeadline`.
    private func transcribe(_ url: URL) async -> Transcription {
        guard let transcriber = dependencies.transcriber else {
            return .failed(reason: Copy.transcriptionUnavailable)
        }
        let transcription = await race(timing.transcriptionDeadline) { () -> Transcription in
            do {
                let transcript = try await transcriber.transcribe(fileAt: url, locale: .current)
                return .words(transcript.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch {
                return .failed(reason: Copy.transcriptionFailed)
            }
        }
        return transcription ?? .failed(reason: Copy.transcriptionFailed)
    }

    /// Sends once the Host is confirmed, and only to a listed Agent; a Host
    /// that never is, or an Agent that isn't, gets a definite not-sent,
    /// since nothing left the phone.
    private func send(_ text: String, to agentID: ConsoleAgent.ID) async -> WatchDelivery {
        if let failure = await waitForHost(agentID.hostID) {
            return .notSent(reason: failure)
        }
        guard listedAgent(agentID) != nil else { return .notSent(reason: Copy.agentGone) }
        switch await sendWithinDeadline(text, to: agentID) {
        case .sent: return .sent(text: AgentActionService.hygienic(text))
        case .notSent(let reason): return .notSent(reason: reason)
        case .unknown: return .unknown
        case .keptAsDraft(let reason): return .keptAsDraft(reason: WatchKeptReason(reason))
        }
    }

    /// `dependencies.send` under the read deadline. A send still running
    /// past it (a stalled Host transport) may have gone out, so it reads as
    /// `.unknown`, never sent twice, and the message stops holding the app.
    private func sendWithinDeadline(_ text: String, to agentID: ConsoleAgent.ID) async
        -> AgentActionService.SendOutcome
    {
        let outcome = await race(timing.readDeadline) {
            [weak self] () -> AgentActionService.SendOutcome in
            guard let self else { return .unknown }
            return await self.dependencies.send(text, agentID)
        }
        return outcome ?? .unknown
    }

    /// Records a message's outcome and reports it to the watch.
    private func finish(
        _ messageID: UUID, token: UInt64, delivery: WatchDelivery, transcript: String?
    ) {
        WatchLog.logger.notice(
            "message \(messageID.uuidString, privacy: .public) outcome \(delivery.logType, privacy: .public)")
        for effect in messageLedger.handle(.finished(messageID, token: token, delivery: delivery, transcript: transcript)) {
            switch effect {
            case .deliver(let event): deliver(event)
            case .acknowledge, .process: break
            }
        }
    }

    /// A live message while the watch app runs, else a queued transfer
    /// that survives it being suspended.
    private func deliver(_ event: WatchEvent) {
        guard let data = try? WatchWireCodec.encode(event) else { return }
        guard channel.isReachable else {
            WatchLog.logger.notice("outcome queued: the watch app is not reachable")
            channel.transferUserInfo(data)
            return
        }
        WatchLog.logger.notice("outcome sent live")
        channel.sendMessageData(data) { [weak self] in self?.channel.transferUserInfo(data) }
    }

    // MARK: Hosts

    /// Waits up to `hostDeadline` for the Host to be confirmed. Nil once
    /// it is; otherwise the copy for how it stood when time ran out.
    private func waitForHost(_ hostID: Host.ID) async -> String? {
        let clock = ContinuousClock()
        let deadline = clock.now + timing.hostDeadline
        while true {
            let source = dependencies.source()
            let host = source.hosts.first { $0.id == hostID && $0.isEnabled }
            let condition = host.map { WatchStateBuilder.condition(of: $0, in: source) }
            if condition == .confirmed { return nil }
            if clock.now >= deadline || Task.isCancelled {
                guard let host else { return Copy.hostMissing }
                return condition == .unreachable
                    ? Copy.unreachable(host.displayName) : Copy.connecting(host.displayName)
            }
            try? await Task.sleep(for: timing.hostPoll)
        }
    }

    private func hostName(_ hostID: Host.ID) -> String {
        dependencies.source().hosts.first { $0.id == hostID }?.displayName ?? "the Host"
    }

    /// The Agent with this id when the watch lists it: one `AgentGlanceList`
    /// lists (never a Shell) on an enabled Host. Whatever id a request
    /// names, nothing else is read, answered, or sent to. `source` is the
    /// Console as just read, when the caller has it.
    private func listedAgent(
        _ id: ConsoleAgent.ID, in source: WatchStateSource? = nil
    ) -> ConsoleAgent? {
        let source = source ?? dependencies.source()
        guard source.hosts.contains(where: { $0.id == id.hostID && $0.isEnabled }) else {
            return nil
        }
        return AgentGlanceList.listedAgent(id, in: source.agents)
    }

    /// Replies "Unlock your iPhone" while the Host credentials are unreadable.
    private func unlocked(_ reply: WatchReplySlot?) -> Bool {
        guard dependencies.keychainReadable() else {
            WatchLog.logger.notice(
                "request #\(reply?.number ?? 0, privacy: .public) refused: Host credentials unreadable until unlock")
            respond(.failure(Copy.unlockPhone), via: reply)
            return false
        }
        return true
    }

    // MARK: Holding the app awake

    private func acquireHold() -> UUID {
        let hold = UUID()
        updateActivityLease(.acquire(hold))
        return hold
    }

    private func releaseHold(_ hold: UUID) {
        updateActivityLease(.release(hold))
    }

    /// Background time ran out: every request still owed a reply is
    /// answered "ran out of time" now, while the app still runs (a reply
    /// sent after it freezes never arrives, and the watch would wait for
    /// nothing), then everything lets go, so the activity coordinator tears
    /// the connections down cleanly. A request that finishes later replies
    /// nothing more.
    private func holdExpired(_ generation: Int) {
        updateActivityLease(.expired(generation))
    }

    private func updateActivityLease(_ event: WatchActivityLeaseMachine.Event) {
        for effect in activityLease.handle(event) {
            switch effect {
            case .begin(let generation):
                WatchLog.logger.notice("hold \(generation, privacy: .public) taken: app held awake")
                dependencies.hold { [weak self] in self?.holdExpired(generation) }
            case .startPublishing:
                startPublishing()
            case .expireReplies:
                let owed = openReplies.values.sorted { $0.number < $1.number }
                WatchLog.logger.error("watch hold expired; answering \(owed.count, privacy: .public) open requests")
                for reply in owed { respond(.failure(Copy.ranOutOfTime), via: reply) }
            case .release:
                WatchLog.logger.notice("watch hold released: app let go")
                dependencies.release()
            }
        }
    }

    // MARK: Replies

    /// A once-only, logged reply for request `number`, kept among the open
    /// replies until given; nil when the watch wants none.
    private func slot(
        for handler: (@MainActor @Sendable (Data) -> Void)?, number: Int, type: String
    ) -> WatchReplySlot? {
        guard let handler else { return nil }
        let slot = WatchReplySlot(number: number, request: type, handler: handler) {
            [weak self] number in
            self?.openReplies[number] = nil
        }
        openReplies[number] = slot
        return slot
    }

    private func respond(_ reply: WatchReply, via slot: WatchReplySlot?) {
        slot?.send(reply)
    }

    /// `operation`'s result, or nil when `limit` passed first. The
    /// operation is cancelled then, and its late result dropped. The timer
    /// resumes the waiter itself, so the deadline holds even for an
    /// operation that ignores cancellation; it needs only the main actor
    /// free, which every await in the operation leaves it.
    private func race<T: Sendable>(
        _ limit: Duration, _ operation: @escaping @MainActor @Sendable () async -> T
    ) async -> T? {
        let gate = RaceGate<T>()
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            gate.continuation = continuation
            let work = Task { @MainActor in gate.finish(await operation()) }
            gate.timer = Task { @MainActor in
                try? await Task.sleep(for: limit)
                gate.finish(nil)
                work.cancel()
            }
        }
    }
}

/// The first of `WatchBridge.race`'s two finishers resumes the waiter.
@MainActor
private final class RaceGate<T: Sendable> {
    /// The waiter; nil once resumed.
    var continuation: CheckedContinuation<T?, Never>?
    /// The deadline; cancelled once the work wins.
    var timer: Task<Void, Never>?

    /// Resumes the waiter with `value` unless the other side already did.
    func finish(_ value: T?) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.cancel()
        continuation.resume(returning: value)
    }
}

/// One watch request's reply: given at most once, then no longer open;
/// timed and logged with its size, never its contents.
@MainActor
private final class WatchReplySlot {
    /// The request's number in the log.
    let number: Int
    /// The request's kind in the log.
    private let request: String
    /// When the request reached the bridge.
    private let received = ContinuousClock.now
    /// WatchConnectivity's reply handler; nil once called.
    private var handler: (@MainActor @Sendable (Data) -> Void)?
    /// Takes the slot out of the bridge's open replies.
    private let onAnswered: @MainActor (Int) -> Void

    init(
        number: Int, request: String, handler: @escaping @MainActor @Sendable (Data) -> Void,
        onAnswered: @escaping @MainActor (Int) -> Void
    ) {
        self.number = number
        self.request = request
        self.handler = handler
        self.onAnswered = onAnswered
    }

    /// Gives `reply` unless one was given already; a later one is dropped.
    func send(_ reply: WatchReply) {
        let elapsed = WatchLog.milliseconds(since: received)
        guard let handler else {
            WatchLog.logger.notice(
                "request #\(self.number, privacy: .public) \(self.request, privacy: .public): late \(reply.logType, privacy: .public) after \(elapsed, privacy: .public) ms dropped, already answered")
            return
        }
        self.handler = nil
        onAnswered(number)
        do {
            let data = try WatchWireCodec.encode(reply)
            handler(data)
            WatchLog.logger.notice(
                "request #\(self.number, privacy: .public) \(self.request, privacy: .public) replied \(reply.logType, privacy: .public) in \(elapsed, privacy: .public) ms, \(data.count, privacy: .public) bytes")
        } catch {
            WatchLog.logger.error(
                "request #\(self.number, privacy: .public) \(self.request, privacy: .public): reply \(reply.logType, privacy: .public) did not encode after \(elapsed, privacy: .public) ms")
            // Every request still gets one reply: a plain failure instead.
            if let fallback = try? WatchWireCodec.encode(WatchReply.failure(WatchBridge.Copy.replyFailed)) {
                handler(fallback)
            }
        }
    }
}

extension WatchKeptReason {
    /// The wire reason for the action service's kept-as-draft reason.
    init(_ reason: AgentActionService.KeptReason) {
        switch reason {
        case .blocked: self = .blocked
        case .signInRequired: self = .signInRequired
        case .folderTrustRequired: self = .folderTrustRequired
        }
    }
}

