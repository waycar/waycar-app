import Foundation
import Observation
import WatchKit

/// Everything the watch screens show and do (design §4, §6). The iPhone
/// owns all state: the Watch State arrives as application context, and
/// Latest, Blocked prompts, answers, and messages are requests over the
/// phone link. Latest text and commands live only in memory (§7.3).
@MainActor
@Observable
final class WatchStore {
    // MARK: - Types

    typealias Load<Value: Equatable & Sendable> = WatchRead<Value>
    typealias AnswerState = WatchApprovalMachine.AnswerState

    /// A screen pushed on the root Agents list.
    enum Route: Hashable, Sendable {
        /// W2, Agent detail.
        case agent(WatchAgentID)
        /// W4, the voice recorder for the Agent.
        case recorder(WatchAgentID)
        /// W3, the Agent's Blocked prompt.
        case blocked(WatchAgentID)
    }

    // MARK: - Copy and timing

    /// The iPhone is out of range or WatchConnectivity is not active.
    static let unreachableCopy = WatchLinkCopy.unreachable
    /// The iPhone was reachable but its app did not answer (§6.3), within
    /// `WatchRequester.deadline`.
    static let noAnswerCopy = WatchLinkCopy.noAnswer
    /// The iPhone refused an answer the prompt does not allow from a watch.
    static let answerOnPhoneCopy = "Answer this one on iPhone."
    /// The iPhone runs a newer wire version than this watch build.
    static let updateWatchCopy = "Update Waycar on your Apple Watch"
    /// The iPhone runs an older wire version than this watch build.
    static let updatePhoneCopy = "Update Waycar on your iPhone"
    /// A stale Latest is asked for once more after this long, while the
    /// iPhone runs its one summaries refresh ("Checking…").
    static let staleRecheckDelay: Duration = .seconds(5)
    /// An "Allowed ✓" stamp older than this is re-checked on entering W3,
    /// in case the Agent turned Blocked again without the watch seeing it.
    static let answerStampLifetime: TimeInterval = 10

    // MARK: - State

    /// The last Watch State; nil until the iPhone sent one (W6).
    var state: WatchState? { snapshots.snapshot }
    private var snapshots = WatchSnapshotMachine()
    /// Whether the iPhone can take live messages; every action disables
    /// while it cannot.
    private(set) var isReachable: Bool
    /// "Update Waycar on your iPhone" (or Apple Watch) once the two apps
    /// were found to speak different wire versions; cleared by the next
    /// Watch State that decodes.
    var updateNotice: String? { snapshots.peerVersion.map { Self.updateCopy(peerVersion: $0) } }
    /// The NavigationStack path, set by deep links and notifications.
    var route: [Route] = []
    /// A notification action or deep link that arrived before the first
    /// Watch State; resolved once a state arrives, or falls back after
    /// `pendingRouteTimeout`.
    private var pendingRoute: PendingRoute? = nil
    /// Bumped per pending route so a stale fallback timer does nothing.
    private var pendingRouteToken = 0
    /// How long a pending route waits for the first Watch State.
    static let pendingRouteTimeout: Duration = .seconds(10)

    /// Latest per Agent.
    private var latests: [WatchAgentID: WatchLatestMachine] = [:]
    /// Approval episode per Agent; request ownership lives in the machine.
    private var approvals: [WatchAgentID: WatchApprovalMachine] = [:]
    /// Each Agent's latest message and its phase, mirrored from the
    /// messenger so views observe it.
    private var outbox = WatchOutbox()

    /// Whether a refresh is in flight.
    @ObservationIgnored private var isRefreshing = false
    /// Whether the app is frontmost; arrival haptics play only then.
    @ObservationIgnored private var isForeground = false
    /// The channel to the iPhone.
    private let link: any WatchPhoneLink
    /// Sends every request over `link` under its deadline, reads and
    /// messages alike, so none waits on another or for good.
    private let requester: WatchRequester
    /// Sends messages over `link` and follows them to an outcome.
    private let messenger: WatchMessenger

    /// A store over `link`, activated at once so queued state arrives.
    init(link: any WatchPhoneLink) {
        self.link = link
        // Inactive until the scene says otherwise, and reachability unknown
        // until activation reports it, so a slow cold launch never reads
        // as "iPhone not reachable".
        let requester = WatchRequester(
            link: link, isActive: false, isReachable: nil, isReachableNow: { link.isReachable })
        self.requester = requester
        messenger = WatchMessenger(link: link, requester: requester)
        isReachable = link.isReachable
        messenger.onChange = { [weak self] moved in self?.messengerDidChange(moved) }
        messenger.failureReason = { [weak self] error in
            self?.messageFailureReason(for: error) ?? WatchMessenger.reason(for: error)
        }
        link.activate { [weak self] inbound in self?.receive(inbound) }
    }

    /// The store backed by the paired iPhone.
    static func live() -> WatchStore {
        WatchStore(link: WatchSessionClient())
    }

    // MARK: - Reading

    /// Whether the iPhone transcribes recordings (iOS 26+); otherwise the
    /// mic opens system text input.
    var phoneTranscribesVoice: Bool { state?.voiceTranscription ?? false }

    /// Whether Reply may open the recorder for an Agent right now: the
    /// iPhone transcribes and no message to it is in flight.
    func canRecord(_ id: WatchAgentID) -> Bool {
        phoneTranscribesVoice && outgoing(for: id)?.isInFlight != true
    }

    /// A route whose resolution waits for a Watch State.
    struct PendingRoute: Sendable {
        /// The Agent it targets; nil resolves at once (no state needed).
        let agentID: WatchAgentID?
        /// The routes, given whether the Agent can record; nil leaves the
        /// path alone.
        let resolve: @MainActor @Sendable (_ canRecord: Bool) -> [Route]?
    }

    /// Applies `pending` now when a Watch State is present (or it targets
    /// no Agent); otherwise holds it until the first state arrives, falling
    /// back to the Agent's detail after `pendingRouteTimeout`.
    func open(_ pending: PendingRoute) {
        pendingRouteToken += 1
        guard state == nil, let agentID = pending.agentID else {
            pendingRoute = nil
            resolve(pending)
            return
        }
        pendingRoute = pending
        let token = pendingRouteToken
        Task { [weak self] in
            try? await Task.sleep(for: Self.pendingRouteTimeout)
            guard let self, self.pendingRouteToken == token, self.pendingRoute != nil else { return }
            self.pendingRoute = nil
            self.route = [.agent(agentID)]
        }
    }

    /// Sets the route `pending` resolves to against the current state.
    private func resolve(_ pending: PendingRoute) {
        let recordable = pending.agentID.map(canRecord) ?? false
        if let routes = pending.resolve(recordable) { route = routes }
    }

    /// The Agent's row in the current Watch State.
    func row(_ id: WatchAgentID) -> WatchAgentRow? {
        state?.rows.first { $0.id == id }
    }

    /// The Agent's Latest read.
    func latest(_ id: WatchAgentID) -> Load<WatchLatest?> {
        latests[id]?.read ?? .idle
    }

    /// Whether a stale Latest is being checked.
    func isCheckingLatest(_ id: WatchAgentID) -> Bool {
        latests[id]?.isChecking ?? false
    }

    /// The Agent's Blocked prompt read.
    func blocked(_ id: WatchAgentID) -> Load<WatchBlockedPrompt?> {
        approvals[id]?.prompt ?? .idle
    }

    /// Where the answer to the Agent's Blocked prompt stands.
    func answerState(_ id: WatchAgentID) -> AnswerState {
        approvals[id]?.answer ?? .idle
    }

    /// The Agent's latest message from this watch.
    func outgoing(for id: WatchAgentID) -> WatchOutgoing? {
        outbox.latest(for: id)
    }

    // MARK: - Lifecycle

    /// The app came to the front: arrival haptics resume, message waits
    /// start over (one may have run out while the app was suspended), and
    /// the iPhone is asked for a fresh Watch State.
    func sceneDidBecomeActive() {
        isForeground = true
        requester.setActive(true)
        messenger.restartDeliveryTimers()
        Task { await refresh() }
    }

    /// The app left the front (wrist down, another app).
    func sceneDidLeaveForeground() {
        isForeground = false
        requester.setActive(false)
    }

    // MARK: - Requests

    // Every request below goes through `requester`, so one the iPhone never
    // answers ends after `WatchRequester.deadline` as "Waycar on iPhone
    // didn't answer — open it" and frees its in-flight guard, instead of
    // spinning and blocking every later read of its kind. A request lost to
    // wrist-down or a reachability flap waits and is resent, and "iPhone not
    // reachable" comes only once the requester saw it unreachable for its
    // whole debounce window.

    /// Asks the iPhone to rebuild and send the Watch State. Skipped while
    /// already refreshing; a failure keeps the last state,
    /// and a wire-version mismatch raises the update notice.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            guard case .state(let next) = try await requester.send(.refresh) else { return }
            apply(next)
        } catch {
            noteVersionMismatch(error)
        }
    }

    /// Reads the Agent's Latest. A reload keeps the text on screen and
    /// keeps it on failure; a stale answer is asked for once more.
    func loadLatest(_ id: WatchAgentID) async {
        await latest(.load, for: id)
    }

    /// Reads the Agent's Blocked prompt from the live screen ("Reading
    /// prompt…"). Clears a failed or changed answer so the fresh prompt can
    /// be answered. An answered prompt keeps its stamp until the Agent turns
    /// Blocked again (`apply(_:)` then clears both); a stamp older than
    /// `answerStampLifetime` is re-checked and gives way to a prompt that is
    /// still waiting.
    func loadBlocked(_ id: WatchAgentID) async {
        let expired: Bool
        if case .done(_, let at) = answerState(id) {
            expired = Date().timeIntervalSince(at) > Self.answerStampLifetime
        } else { expired = false }
        await approval(.load(stampExpired: expired), for: id)
    }

    /// Answers the Blocked prompt the watch shows, by its prompt id. Allow
    /// only for `.allow` prompts and Deny for `.allow` or `.hold`, the same
    /// rule as CarPlay; the iPhone re-checks it and the screen.
    func answer(_ answer: WatchAnswer, agent id: WatchAgentID) async {
        await approval(.answer(answer), for: id)
    }

    // MARK: - Messages

    /// Sends typed or system-dictated text (the pre-iOS 26 fallback). No-op
    /// while the Agent has a message in flight.
    func sendText(_ text: String, to id: WatchAgentID) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let messageID = messenger.begin(.text(trimmed), to: id) else { return }
        Task { await messenger.deliver(messageID) }
    }

    /// Sends a finished recording for the iPhone to transcribe and send.
    /// The file is held until the message settles; a refused send deletes
    /// it at once.
    func sendVoice(recordingAt url: URL, duration: Double, to id: WatchAgentID) {
        guard let messageID = messenger.begin(.voice(duration: duration), to: id, recordingAt: url)
        else { return }
        Task { await messenger.deliver(messageID) }
    }

    /// Try again: resends a definitely-not-sent message under the same id,
    /// so the iPhone dedupes it.
    func retry(_ messageID: UUID) {
        guard messenger.retry(messageID) else { return }
        Task { await messenger.deliver(messageID) }
    }

    // MARK: - Inbound

    /// Routes one value from the phone link.
    private func receive(_ inbound: WatchInbound) {
        switch inbound {
        case .state(let next):
            apply(next)
        case .reachability(let reachable):
            let regained = reachable && !isReachable
            isReachable = reachable
            requester.setReachable(reachable)
            guard regained else { return }
            Task { await refresh() }
            reloadFailedReads()
        case .event(let event):
            messenger.receive(event)
        case .voiceTransferFailed(let messageID, let agentID, let attempt):
            guard let attempt else { return }
            messenger.voiceTransferFailed(messageID: messageID, agentID: agentID, attempt: attempt)
        case .versionMismatch(let version):
            _ = snapshots.handle(.versionMismatch(version))
        }
    }

    /// Takes a Watch State unless it is older than the one shown, keeping
    /// the shown rows of a Host it does not confirm and lists nothing for.
    /// A row turning Blocked drops its old prompt and answer; a row turning
    /// Blocked or Done buzzes while the app is in front.
    private func apply(_ incoming: WatchState) {
        for effect in snapshots.handle(.snapshot(incoming)) {
            switch effect {
            case .accepted(let old, let next): accepted(next, previous: old)
            }
        }
    }

    private func accepted(_ next: WatchState, previous old: WatchState?) {
        let previous = Dictionary(
            (old?.rows ?? []).map { ($0.id, $0.status) }, uniquingKeysWith: { first, _ in first })
        var needsAttention = false
        for row in next.rows where previous[row.id] != row.status {
            if row.status == "blocked" {
                // Episode invalidation has no I/O effects.
                _ = approvals[row.id, default: WatchApprovalMachine()].handle(.blockedEpisode)
            }
            if row.status == "blocked" || row.status == "done" { needsAttention = true }
        }
        let hadState = old != nil
        if let pending = pendingRoute {
            pendingRoute = nil
            pendingRouteToken += 1
            resolve(pending)
        }
        if hadState, needsAttention, isForeground { play(.notification) }
    }

    // MARK: - Message outcomes

    /// Mirrors the messenger's outbox for the views and buzzes once for the
    /// message's new phase (§6).
    private func messengerDidChange(_ moved: WatchOutgoing?) {
        outbox = messenger.outbox
        switch moved?.phase {
        case .sent?: play(.success)
        case .notSent?, .unknown?, .keptAsDraft?, .noWords?: play(.failure)
        case .sending?, .transcribing?, .delivering?, nil: break
        }
    }

    /// The reason a message request that threw shows: the update copy for a
    /// wire-version mismatch (also raised as the update notice), otherwise
    /// `WatchMessenger.reason(for:)`: "iPhone not reachable" when the iPhone
    /// could not be reached, "iPhone didn't answer" otherwise.
    private func messageFailureReason(for error: any Error) -> String {
        guard case WatchWireError.versionMismatch = error else { return WatchMessenger.reason(for: error) }
        noteVersionMismatch(error)
        return failureCopy(for: error)
    }

    // MARK: - Helpers

    /// Performs approval I/O; every completion returns through its token.
    private func approval(_ event: WatchApprovalMachine.Event, for id: WatchAgentID) async {
        let effects = approvals[id, default: WatchApprovalMachine()].handle(event)
        for effect in effects {
            switch effect {
            case .read(let token):
                let result: Load<WatchBlockedPrompt?>
                do {
                    switch try await requester.send(.blockedPrompt(id)) {
                    case .blockedPrompt(let prompt): result = .loaded(prompt)
                    case .failure(let copy): result = .failed(copy)
                    default: result = .failed(Self.noAnswerCopy)
                    }
                } catch { result = .failed(failureCopy(for: error)) }
                await approval(.readFinished(token, result), for: id)
            case .answer(let token, let promptID, let answer):
                let result: AnswerState
                let spent: Bool
                do {
                    let reply = try await requester.send(.answer(id, promptID: promptID, answer))
                    result = answerState(for: reply, answer: answer, agent: id)
                    switch reply {
                    case .answerResult(.failed), .failure: spent = true
                    default: spent = false
                    }
                } catch {
                    result = .failed(failureCopy(for: error))
                    // A timeout may still land on the phone; never reuse its id.
                    spent = true
                }
                await approval(.answerFinished(token, promptID: promptID, result, spent: spent), for: id)
            case .success: play(.success)
            case .failure: play(.failure)
            }
        }
    }

    /// The link is back: every Latest and Blocked prompt that failed is
    /// asked for again, so no stale failure stays on screen.
    private func reloadFailedReads() {
        for (id, machine) in latests {
            if case .failed = machine.read { Task { await loadLatest(id) } }
        }
        for (id, episode) in approvals {
            if case .failed = episode.prompt { Task { await loadBlocked(id) } }
        }
    }

    /// Performs Latest effects and feeds tokened completions back.
    private func latest(_ event: WatchLatestMachine.Event, for id: WatchAgentID) async {
        let effects = latests[id, default: WatchLatestMachine()].handle(event)
        for effect in effects {
            switch effect {
            case .read(let token):
                let result: Load<WatchLatest?>
                do {
                    switch try await requester.send(.latest(id)) {
                    case .latest(let value): result = .loaded(value)
                    case .failure(let copy): result = .failed(copy)
                    default: result = .failed(Self.noAnswerCopy)
                    }
                } catch { result = .failed(failureCopy(for: error)) }
                await latest(.finished(token, result), for: id)
            case .scheduleRecheck(let token):
                Task { [weak self] in
                    try? await Task.sleep(for: Self.staleRecheckDelay)
                    guard !Task.isCancelled else { return }
                    await self?.latest(.recheckElapsed(token), for: id)
                }
            }
        }
    }

    /// The answer state an answer reply means.
    private func answerState(
        for reply: WatchReply, answer: WatchAnswer, agent id: WatchAgentID
    ) -> AnswerState {
        switch reply {
        case .answerResult(.sent): .done(answer, at: Date())
        case .answerResult(.promptChanged): .promptChanged
        case .answerResult(.refused): .failed(Self.answerOnPhoneCopy)
        case .answerResult(.failed): .failed(row(id).map { "Can't reach \($0.hostName)" } ?? Self.noAnswerCopy)
        case .failure(let copy): .failed(copy)
        case .received, .state, .latest, .blockedPrompt: .failed(Self.noAnswerCopy)
        }
    }

    /// User-facing copy for a request that got no usable reply.
    private func failureCopy(for error: any Error) -> String {
        switch error {
        case WatchLinkError.unreachable:
            return Self.unreachableCopy
        case WatchLinkError.noAnswer:
            return Self.noAnswerCopy
        case WatchWireError.versionMismatch(let version):
            return Self.updateCopy(peerVersion: version)
        default:
            return isReachable ? Self.noAnswerCopy : Self.unreachableCopy
        }
    }

    /// Raises the update notice when `error` is a wire-version mismatch.
    private func noteVersionMismatch(_ error: any Error) {
        guard case WatchWireError.versionMismatch(let version) = error else { return }
        _ = snapshots.handle(.versionMismatch(version))
    }

    /// Which app needs an update when the iPhone speaks wire `version`.
    private static func updateCopy(peerVersion version: Int) -> String {
        version > WatchWire.version ? updateWatchCopy : updatePhoneCopy
    }

    /// Plays a wrist haptic.
    private func play(_ haptic: WKHapticType) {
        WKInterfaceDevice.current().play(haptic)
    }
}

#if DEBUG
extension WatchStore {
    /// Demo only: puts a voice message in the outbox already acknowledged
    /// (transcribing, no delivery timer) or, with `sentAt`, already sent.
    func seedDemoVoice(to id: WatchAgentID, text: String, sentAt: Date?) {
        let message = WatchOutgoing(id: UUID(), agentID: id, content: .voice(duration: 4))
        let outcome = sentAt.map { _ in WatchDelivery.sent(text: text) }
        messenger.seedAcknowledged(message, outcome: outcome, at: sentAt ?? Date())
    }
}
#endif
