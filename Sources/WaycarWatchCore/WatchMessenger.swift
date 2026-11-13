import Foundation

// MARK: - Message link

/// The part of the phone link that carries messages. The watch's
/// `WatchPhoneLink` refines it; tests script it.
@MainActor
protocol WatchMessageLink: AnyObject {
    /// Sends one request and returns the iPhone's reply. Throws when no
    /// reply arrived or the reply did not decode.
    func send(_ request: WatchRequest) async throws -> WatchReply
    /// Queues a recording for the iPhone, paired by `file.messageID` with
    /// the `.voice` request. `attempt` comes back with a failed transfer so
    /// a stale failure can be told from the current one.
    func transferVoice(fileAt url: URL, file: WatchVoiceFile, attempt: UUID) throws
    /// Cancels the recording's transfer if it is still queued.
    func cancelVoiceTransfer(_ messageID: UUID)
}

// MARK: - Messenger

/// Sends the watch's messages and follows each to an outcome (design §6.2).
/// A recording is queued as a file first, then the request asks for the
/// phase-1 acknowledgement. No acknowledgement means not acknowledged, and
/// Try again is safe (the phone dedupes by id while it stays running):
/// the link failed, or `WatchRequester.deadline` passed without one, and the
/// queued file is cancelled so it cannot arrive later. An acknowledged
/// message without a delivery outcome in time turns unknown.
///
/// A recording is kept until its message is sent, kept as a draft, or had no
/// words, or until the Agent's next message replaces it: a not-sent or
/// unknown message may still need it for Try again.
@MainActor
final class WatchMessenger {
    /// Waits for a duration; throws when the waiting task is cancelled.
    typealias Sleep = @MainActor @Sendable (Duration) async throws -> Void

    /// The reason a message without an acknowledgement shows ("Not sent —
    /// iPhone didn't answer").
    nonisolated static let notSentReason = "iPhone didn't answer"
    /// The reason a message shows when the iPhone could not be reached at
    /// all, so nothing was sent ("Not sent — iPhone not reachable").
    nonisolated static let unreachableReason = WatchLinkCopy.unreachable
    /// An acknowledged message with no delivery outcome after this long is
    /// shown as unknown, never retried.
    nonisolated static let deliveryTimeout: Duration = .seconds(45)

    /// Each Agent's latest message and its phase.
    private(set) var outbox = WatchOutbox()
    /// Called after every outbox change, with the message whose phase moved
    /// (nil when only messages were replaced or seeded).
    var onChange: (@MainActor (_ moved: WatchOutgoing?) -> Void)?
    /// The reason shown for a request or transfer that threw; defaults to
    /// `reason(for:)`.
    var failureReason: @MainActor (any Error) -> String = { WatchMessenger.reason(for: $0) }

    /// The channel to the iPhone, for recordings.
    private let link: any WatchMessageLink
    /// Sends the acknowledgement requests under their deadline.
    private let requester: WatchRequester
    /// How long an acknowledged message waits for its outcome.
    private let deliveryTimeout: Duration
    /// The delivery timers' wait.
    private let sleep: Sleep
    /// The clock that stamps `.sent`.
    private let now: @MainActor () -> Date
    /// Per-message effect ownership and retained recording paths.
    private var effects: [UUID: WatchMessengerMachine] = [:]
    /// External transfer UUIDs paired with the machine's attempt tokens.
    private var transfers: [UUID: (token: UInt64, id: UUID)] = [:]
    /// The delivery timer per acknowledged message.
    private var timers: [UUID: Task<Void, Never>] = [:]

    /// A messenger over `link`, asking for acknowledgements through
    /// `requester`. `sleep` and `now` default to the real clock.
    init(
        link: any WatchMessageLink,
        requester: WatchRequester,
        deliveryTimeout: Duration = WatchMessenger.deliveryTimeout,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.link = link
        self.requester = requester
        self.deliveryTimeout = deliveryTimeout
        self.sleep = sleep
        self.now = now
    }

    /// The reason a message request or transfer that threw shows:
    /// `unreachableReason` when the iPhone could not be reached, otherwise
    /// `notSentReason`.
    nonisolated static func reason(for error: any Error) -> String {
        error as? WatchLinkError == .unreachable ? unreachableReason : notSentReason
    }

    // MARK: Sending

    /// Starts tracking a message in `.sending`, replacing the Agent's
    /// previous one and its recording. Returns the new id, or nil while the
    /// Agent has a message in flight; a refused recording is deleted at
    /// once. Call `deliver(_:)` with the id to send it.
    func begin(
        _ content: WatchOutgoing.Content, to agentID: WatchAgentID, recordingAt url: URL? = nil
    ) -> UUID? {
        let previous = outbox.latest(for: agentID)?.id
        let message = WatchOutgoing(id: UUID(), agentID: agentID, content: content)
        guard outbox.begin(message) else {
            if let url { try? FileManager.default.removeItem(at: url) }
            return nil
        }
        if let previous {
            perform(.settle, for: previous)
            effects[previous] = nil
        }
        effects[message.id] = WatchMessengerMachine(recording: url)
        onChange?(outbox.messages[message.id])
        return message.id
    }

    /// Try again: a `.notSent` message goes back to `.sending` under the
    /// same id, so the iPhone dedupes it. False in any other phase. Call
    /// `deliver(_:)` after it.
    func retry(_ messageID: UUID) -> Bool {
        guard outbox.messages[messageID]?.canRetry == true else { return false }
        update(messageID) { $0.retry(messageID) }
        return true
    }

    /// Sends a `.sending` message and waits for the acknowledgement, at most
    /// `WatchRequester.deadline`. A recording that is gone or cannot be
    /// queued is not sent; a reply other than `.received`, an error, or no
    /// reply in time cancels the queued file. Returns early when a newer
    /// attempt or an outcome overtook this one.
    func deliver(_ messageID: UUID) async {
        guard let message = outbox.messages[messageID], message.phase == .sending else { return }
        guard let pending = effects[messageID]?.handle(.deliver) else { return }
        for effect in pending {
            switch effect {
            case .deliver(let token, let recording):
                await deliver(message, token: token, recording: recording)
            default: perform(effect, for: messageID)
            }
        }
    }

    private func deliver(_ message: WatchOutgoing, token: UInt64, recording: URL?) async {
        let messageID = message.id
        let attempt = UUID()
        transfers[messageID] = (token, attempt)
        let request: WatchRequest
        switch message.content {
        case .text(let text):
            request = .send(messageID: messageID, message.agentID, text: text)
        case .voice(let duration):
            guard let url = recording else {
                perform(.ackFailed(token, reason: Self.notSentReason, cancelTransfer: false), for: messageID)
                return
            }
            do {
                let file = WatchVoiceFile(messageID: messageID, agentID: message.agentID, duration: duration)
                try link.transferVoice(fileAt: url, file: file, attempt: attempt)
                WatchLog.logger.notice(
                    "message \(messageID.uuidString, privacy: .public) recording queued, attempt \(attempt.uuidString, privacy: .public)")
            } catch {
                perform(.ackFailed(token, reason: failureReason(error), cancelTransfer: false), for: messageID)
                return
            }
            request = .voice(messageID: messageID, message.agentID)
        }
        let reason: String
        do {
            let reply = try await requester.send(request)
            switch reply {
            case .received:
                perform(.acknowledged(token), for: messageID)
                return
            case .failure(let copy):
                reason = copy
            case .state, .latest, .blockedPrompt, .answerResult:
                reason = Self.notSentReason
            }
        } catch {
            // Do not report a stale error to the UI's failure-copy hook.
            guard transfers[messageID]?.token == token else { return }
            reason = failureReason(error)
        }
        let voice: Bool
        if case .voice = message.content { voice = true } else { voice = false }
        perform(.ackFailed(token, reason: reason, cancelTransfer: voice), for: messageID)
    }

    // MARK: Inbound

    /// Applies the phone's delivery outcome.
    func receive(_ event: WatchEvent) {
        switch event {
        case .delivery(let messageID, _, let delivery):
            WatchLog.logger.notice(
                "message \(messageID.uuidString, privacy: .public) outcome \(delivery.logType, privacy: .public)")
            let stamp = now()
            update(messageID) { $0.apply(event, now: stamp) }
        }
    }

    /// A recording's file transfer failed, so its audio never reached the
    /// iPhone: not sent. Ignored unless `attempt` is the message's current
    /// one, so a cancelled transfer cannot overturn a retry or its reason.
    func voiceTransferFailed(messageID: UUID, agentID: WatchAgentID, attempt: UUID) {
        guard transfers[messageID]?.id == attempt,
              outbox.messages[messageID]?.agentID == agentID,
              let token = transfers[messageID]?.token else { return }
        perform(.transferFailed(token), for: messageID)
    }

    /// Starts every acknowledged message's wait over, from now. Called when
    /// the app comes back to the front, so a wait that ran out while the
    /// app was suspended gives queued outcomes a chance to arrive.
    func restartDeliveryTimers() {
        for message in outbox.messages.values {
            switch message.phase {
            case .transcribing, .delivering: perform(.restartTimer, for: message.id)
            case .sending, .sent, .notSent, .unknown, .keptAsDraft, .noWords: break
            }
        }
    }

    // MARK: Helpers

    /// Mutates the outbox and reacts once to the message's new phase:
    /// timers and recording cleanup.
    private func update(_ messageID: UUID, _ change: (inout WatchOutbox) -> Void) {
        let before = outbox.messages[messageID]?.phase
        change(&outbox)
        guard let after = outbox.messages[messageID], after.phase != before else { return }
        perform(.phase(after.phase), for: messageID)
        onChange?(after)
    }

    private func perform(_ event: WatchMessengerMachine.Event, for messageID: UUID) {
        guard let pending = effects[messageID]?.handle(event) else { return }
        for effect in pending { perform(effect, for: messageID) }
    }

    private func perform(_ effect: WatchMessengerMachine.Effect, for messageID: UUID) {
        switch effect {
        case .deliver: break // Only deliver(_:) emits and awaits this effect.
        case .acknowledged: update(messageID) { $0.acknowledged(messageID) }
        case .ackFailed(let reason): update(messageID) { $0.ackFailed(messageID, reason: reason) }
        case .transferFailed:
            guard let message = outbox.messages[messageID] else { return }
            let stamp = now()
            update(messageID) {
                $0.apply(.delivery(messageID: messageID, message.agentID, .notSent(reason: Self.notSentReason)), now: stamp)
            }
        case .timedOut: update(messageID) { $0.timedOut(messageID) }
        case .armTimer(let token):
            let sleep = self.sleep
            let timeout = deliveryTimeout
            timers[messageID] = Task { [weak self] in
                try? await sleep(timeout)
                guard !Task.isCancelled else { return }
                self?.perform(.timerElapsed(token), for: messageID)
            }
        case .stopTimer: timers.removeValue(forKey: messageID)?.cancel()
        case .forgetAttempt: transfers[messageID] = nil
        case .cancelTransfer: link.cancelVoiceTransfer(messageID)
        case .deleteRecording(let url): try? FileManager.default.removeItem(at: url)
        }
    }
}

#if DEBUG
extension WatchMessenger {
    /// Demo only: tracks `message` already acknowledged, with no delivery
    /// timer, then applies `outcome` stamped `date`, if any.
    func seedAcknowledged(_ message: WatchOutgoing, outcome: WatchDelivery?, at date: Date) {
        guard outbox.begin(message) else { return }
        outbox.acknowledged(message.id)
        effects[message.id] = WatchMessengerMachine(recording: nil)
        if let outcome {
            outbox.apply(.delivery(messageID: message.id, message.agentID, outcome), now: date)
        }
        if let phase = outbox.messages[message.id]?.phase { perform(.seed(phase), for: message.id) }
        onChange?(nil)
    }
}
#endif
