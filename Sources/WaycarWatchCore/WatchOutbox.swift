import Foundation

// MARK: - Outgoing message

/// One message the watch sent to an Agent, with where it stands (design §4
/// W4c). Its `id` is the wire `messageID` and survives a retry.
struct WatchOutgoing: Identifiable, Equatable, Sendable {
    /// What the user sent.
    enum Content: Equatable, Sendable {
        /// A recording of `duration` seconds, transcribed on the iPhone.
        case voice(duration: Double)
        /// Typed or dictated text.
        case text(String)
    }

    /// Where the message stands.
    enum Phase: Equatable, Sendable {
        /// Waiting for the phone's `.received` ("Sending…").
        case sending
        /// Voice acknowledged; waiting for the delivery
        /// ("Transcribing on iPhone…").
        case transcribing
        /// Text acknowledged; waiting for the delivery ("Sending…").
        case delivering
        /// Delivered as `text` at `at` ("Sent ✓ 10:10", "Waiting for reply").
        case sent(text: String, at: Date)
        /// Definitely not delivered ("Not sent — …", Try again).
        case notSent(reason: String)
        /// May have been delivered ("Couldn't confirm it was delivered");
        /// no retry, so it is never sent twice.
        case unknown
        /// Kept as a Composer draft, refused for `reason` ("Kept as draft
        /// on iPhone — answer the prompt first" and the like).
        case keptAsDraft(reason: WatchKeptReason)
        /// The transcript was empty ("Couldn't make out any words. Nothing
        /// sent.").
        case noWords
    }

    /// The wire `messageID`, reused by a retry.
    let id: UUID
    /// The Agent it was sent to.
    let agentID: WatchAgentID
    /// What the user sent.
    let content: Content
    /// Where the message stands.
    var phase: Phase = .sending

    /// Whether Try again is offered: only when definitely not delivered.
    var canRetry: Bool {
        if case .notSent = phase { true } else { false }
    }

    /// Whether the outcome is still pending.
    var isInFlight: Bool {
        switch phase {
        case .sending, .transcribing, .delivering: true
        case .sent, .notSent, .unknown, .keptAsDraft, .noWords: false
        }
    }

    /// Whether the phone already reported a final outcome that nothing
    /// later may overturn.
    fileprivate var isSettled: Bool {
        switch phase {
        case .sent, .keptAsDraft, .noWords: true
        case .sending, .transcribing, .delivering, .notSent, .unknown: false
        }
    }
}

// MARK: - Outbox

/// The watch-side message state machine (pure). It keeps at most one
/// message per Agent, the latest, and allows only one in flight per Agent;
/// events for messages it no longer holds are ignored.
struct WatchOutbox: Equatable, Sendable {
    /// Each Agent's latest message, keyed by `messageID`.
    private(set) var messages: [UUID: WatchOutgoing] = [:]

    /// An empty outbox.
    init() {}

    /// The Agent's latest message, if it sent one.
    func latest(for agentID: WatchAgentID) -> WatchOutgoing? {
        messages.values.first { $0.agentID == agentID }
    }

    /// Whether the Agent has a message whose outcome is still pending.
    func hasInFlight(for agentID: WatchAgentID) -> Bool {
        latest(for: agentID)?.isInFlight ?? false
    }

    /// Starts tracking a new message in `.sending`, replacing the Agent's
    /// previous settled message. Refuses (returns false, changes nothing)
    /// while the Agent has a message in flight or when the id is in use.
    @discardableResult
    mutating func begin(_ outgoing: WatchOutgoing) -> Bool {
        guard !hasInFlight(for: outgoing.agentID), messages[outgoing.id] == nil else {
            return false
        }
        if let previous = latest(for: outgoing.agentID) {
            messages[previous.id] = nil
        }
        var started = outgoing
        started.phase = .sending
        messages[started.id] = started
        return true
    }

    /// The phone answered `.received`: a recording moves to `.transcribing`,
    /// text to `.delivering`. Ignored unless the message is `.sending`.
    mutating func acknowledged(_ id: UUID) {
        guard var message = messages[id], message.phase == .sending else { return }
        switch message.content {
        case .voice: message.phase = .transcribing
        case .text: message.phase = .delivering
        }
        messages[id] = message
    }

    /// The request failed without an acknowledgement, so the phone never
    /// took the message: `.notSent`. Ignored unless the message is
    /// `.sending`.
    mutating func ackFailed(_ id: UUID, reason: String) {
        guard var message = messages[id], message.phase == .sending else { return }
        message.phase = .notSent(reason: reason)
        messages[id] = message
    }

    /// Applies the phone's delivery outcome; `.sent` is stamped `now`. The
    /// event may beat the acknowledgement, and a definite outcome replaces
    /// `.unknown` or `.notSent` because it is the phone's ground truth.
    /// Ignored for unknown ids, a mismatched Agent, or a message that
    /// already settled as sent, kept as draft, or no words.
    mutating func apply(_ event: WatchEvent, now: Date) {
        switch event {
        case .delivery(let id, let agentID, let delivery):
            guard var message = messages[id], message.agentID == agentID, !message.isSettled
            else { return }
            switch delivery {
            case .sent(let text): message.phase = .sent(text: text, at: now)
            case .notSent(let reason): message.phase = .notSent(reason: reason)
            case .unknown: message.phase = .unknown
            case .keptAsDraft(let reason): message.phase = .keptAsDraft(reason: reason)
            case .noWords: message.phase = .noWords
            }
            messages[id] = message
        }
    }

    /// No delivery outcome arrived in time: the phone may have sent it, so
    /// the message becomes `.unknown` and is never retried. Ignored unless
    /// the message is in flight.
    mutating func timedOut(_ id: UUID) {
        guard var message = messages[id], message.isInFlight else { return }
        message.phase = .unknown
        messages[id] = message
    }

    /// Try again: a `.notSent` message goes back to `.sending` with the same
    /// id. Ignored in any other phase.
    mutating func retry(_ id: UUID) {
        guard var message = messages[id], message.canRetry else { return }
        message.phase = .sending
        messages[id] = message
    }
}
