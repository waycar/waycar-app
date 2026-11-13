import Foundation

// MARK: - Wire version

/// The iPhone ↔ Apple Watch wire contract (ADR 0029, issue #193). Every
/// value crosses WatchConnectivity as versioned JSON produced by
/// `WatchWireCodec`; both apps compile this file, so a phone and a watch
/// build of different ages either agree on `version` or fail loudly.
enum WatchWire {
    /// The wire version both sides stamp into every envelope as `v`.
    static let version = 1
}

// MARK: - Identity and hosts

/// One Agent as the watch addresses it: the Host it runs on plus its pane.
struct WatchAgentID: Codable, Hashable, Sendable {
    /// The phone's Host id.
    let hostID: UUID
    /// The Backend's pane id on that Host.
    let paneID: String
}

/// How the phone currently sees a Host's connection.
enum WatchHostCondition: String, Codable, Sendable {
    /// Connected and its Agent list is current.
    case confirmed
    /// The phone is still connecting; the list may be stale.
    case connecting
    /// The phone cannot reach the Host.
    case unreachable
}

/// One enabled Host as the watch shows it.
struct WatchHost: Codable, Hashable, Sendable, Identifiable {
    /// The phone's Host id.
    let id: UUID
    /// The Host's user-facing name.
    let name: String
    /// The phone's current view of the connection.
    let condition: WatchHostCondition
}

// MARK: - State

/// One Agent row on the watch list.
struct WatchAgentRow: Codable, Hashable, Sendable, Identifiable {
    /// The Agent this row stands for.
    let id: WatchAgentID
    /// "workspace · name", as `AgentGlanceList.title(for:)` renders it.
    let title: String
    /// The `AgentStatus` raw value; unknown values pass through unchanged.
    let status: String
    /// When the Agent entered `status`; nil when unknown, never guessed.
    let statusSince: Date?
    /// The Host's user-facing name.
    let hostName: String
    /// Whether the Agent runs in Chat Mode.
    let isChatMode: Bool
    /// The Agent's progress bar (#199); nil = no bar. Absent from older
    /// phones' rows, so it decodes as nil.
    let progress: WatchProgress?

    init(
        id: WatchAgentID, title: String, status: String, statusSince: Date?,
        hostName: String, isChatMode: Bool, progress: WatchProgress? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.statusSince = statusSince
        self.hostName = hostName
        self.isChatMode = isChatMode
        self.progress = progress
    }
}

/// An Agent's progress as the watch draws it (Agent Progress, #189).
/// No steps and no phase means "no estimate yet" (dotted bar).
struct WatchProgress: Codable, Hashable, Sendable {
    /// Plan steps done / total, both or neither (AgentProgress.Steps rules).
    let done: Int?
    let total: Int?
    /// `AgentProgress.Phase` raw value (exploring|implementing|verifying|wrapping_up) when there are no steps.
    let phase: String?
    /// When the estimate goes stale (the watch dims it from then on);
    /// `Date.distantPast` when it is already stale; nil when pending.
    let staleAfter: Date?

    /// The phases `AgentProgress.Phase` knows.
    static let knownPhases: Set<String> = ["exploring", "implementing", "verifying", "wrapping_up"]

    /// No estimate yet: neither valid steps nor a known phase, degrading
    /// like `AgentProgress.init?(steps:phase:)`.
    var isPending: Bool {
        let hasSteps: Bool
        if let done, let total {
            hasSteps = (1...99).contains(total) && (0...total).contains(done)
        } else {
            hasSteps = false
        }
        let hasPhase = phase.map(Self.knownPhases.contains) ?? false
        return !hasSteps && !hasPhase
    }

    /// Whether the watch dims the estimate at `now`.
    func isStale(at now: Date) -> Bool {
        staleAfter.map { now >= $0 } ?? false
    }
}

/// Agents per status bucket, for the list header and complications.
struct WatchCounts: Codable, Hashable, Sendable {
    /// Agents whose status is `blocked`.
    var blocked = 0
    /// Agents whose status is `done`.
    var done = 0
    /// Agents whose status is `working`.
    var working = 0
    /// Every other Agent, including unknown statuses.
    var idle = 0
}

/// The phone's snapshot of everything the watch list shows, published as
/// application context.
struct WatchState: Codable, Hashable, Sendable {
    /// When the phone built this snapshot.
    let generatedAt: Date
    /// Enabled Hosts.
    let hosts: [WatchHost]
    /// Agents in CarPlay order; Shells, Closed Sessions, and Disabled Hosts
    /// are excluded.
    let rows: [WatchAgentRow]
    /// Whether the iPhone can transcribe recorded audio (iOS 26+).
    let voiceTranscription: Bool

    /// Agents per status bucket, computed from `rows`; any status other
    /// than blocked, done, or working counts as idle.
    var counts: WatchCounts {
        var counts = WatchCounts()
        for row in rows {
            switch row.status {
            case "blocked": counts.blocked += 1
            case "done": counts.done += 1
            case "working": counts.working += 1
            default: counts.idle += 1
            }
        }
        return counts
    }

    /// Whether rows name their Host: only when more than one Host is shown.
    var showsHostNames: Bool { hosts.count > 1 }

    /// No Hosts and no Agents.
    static let empty = WatchState(
        generatedAt: Date(timeIntervalSince1970: 0), hosts: [], rows: [],
        voiceTranscription: false)

    /// This state, with `previous` rows kept for every Host this state
    /// does not confirm and lists no row for: a phone that has not
    /// reconnected (or was relaunched cold) never empties the watch's list.
    /// Kept rows follow this state's own.
    func keepingRows(from previous: WatchState?) -> WatchState {
        guard let previous else { return self }
        let unconfirmed = Set(hosts.filter { $0.condition != .confirmed }.map(\.id))
        let listedHosts = Set(rows.map(\.id.hostID))
        let kept = previous.rows.filter {
            unconfirmed.contains($0.id.hostID) && !listedHosts.contains($0.id.hostID)
        }
        guard !kept.isEmpty else { return self }
        return WatchState(
            generatedAt: generatedAt, hosts: hosts, rows: rows + kept,
            voiceTranscription: voiceTranscription)
    }
}

// MARK: - Requests

/// The watch's answer to a Blocked prompt.
enum WatchAnswer: String, Codable, Sendable {
    /// Approve the prompt.
    case allow
    /// Refuse the prompt.
    case deny
}

/// A watch → phone request sent with `sendMessageData`; each case names
/// the `WatchReply` it expects.
enum WatchRequest: Codable, Sendable, Equatable {
    /// Rebuild the state; replies `.state`.
    case refresh
    /// The Agent's latest summary or chat reply; replies `.latest`.
    case latest(WatchAgentID)
    /// The Agent's Blocked prompt; replies `.blockedPrompt`.
    case blockedPrompt(WatchAgentID)
    /// Answer the prompt the watch showed as `promptID`; replies
    /// `.answerResult`.
    case answer(WatchAgentID, promptID: UUID, WatchAnswer)
    /// Send typed text; replies `.received`, with the outcome arriving
    /// later as `WatchEvent.delivery`.
    case send(messageID: UUID, WatchAgentID, text: String)
    /// Wakes the phone and pairs the `transferFile` carrying the recording;
    /// replies `.received`.
    case voice(messageID: UUID, WatchAgentID)

    /// The JSON keys of the explicit encoding.
    private enum CodingKeys: String, CodingKey {
        case type, agent, promptID, answer, messageID, text
    }

    /// The `type` discriminator values; renaming one breaks the wire.
    private enum Kind: String, Codable {
        case refresh, latest, blockedPrompt, answer, send, voice
    }

    /// Decodes the `type`-discriminated form; an unknown `type` throws.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .refresh:
            self = .refresh
        case .latest:
            self = .latest(try container.decode(WatchAgentID.self, forKey: .agent))
        case .blockedPrompt:
            self = .blockedPrompt(try container.decode(WatchAgentID.self, forKey: .agent))
        case .answer:
            self = .answer(
                try container.decode(WatchAgentID.self, forKey: .agent),
                promptID: try container.decode(UUID.self, forKey: .promptID),
                try container.decode(WatchAnswer.self, forKey: .answer))
        case .send:
            self = .send(
                messageID: try container.decode(UUID.self, forKey: .messageID),
                try container.decode(WatchAgentID.self, forKey: .agent),
                text: try container.decode(String.self, forKey: .text))
        case .voice:
            self = .voice(
                messageID: try container.decode(UUID.self, forKey: .messageID),
                try container.decode(WatchAgentID.self, forKey: .agent))
        }
    }

    /// Encodes the `type`-discriminated form.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .refresh:
            try container.encode(Kind.refresh, forKey: .type)
        case .latest(let agent):
            try container.encode(Kind.latest, forKey: .type)
            try container.encode(agent, forKey: .agent)
        case .blockedPrompt(let agent):
            try container.encode(Kind.blockedPrompt, forKey: .type)
            try container.encode(agent, forKey: .agent)
        case .answer(let agent, let promptID, let answer):
            try container.encode(Kind.answer, forKey: .type)
            try container.encode(agent, forKey: .agent)
            try container.encode(promptID, forKey: .promptID)
            try container.encode(answer, forKey: .answer)
        case .send(let messageID, let agent, let text):
            try container.encode(Kind.send, forKey: .type)
            try container.encode(messageID, forKey: .messageID)
            try container.encode(agent, forKey: .agent)
            try container.encode(text, forKey: .text)
        case .voice(let messageID, let agent):
            try container.encode(Kind.voice, forKey: .type)
            try container.encode(messageID, forKey: .messageID)
            try container.encode(agent, forKey: .agent)
        }
    }
}

// MARK: - Replies

/// What the watch shows on an Agent's detail screen, always in full: the
/// watch never truncates text, it wraps and the Digital Crown scrolls.
struct WatchLatest: Codable, Hashable, Sendable {
    /// Where `text` came from.
    enum Source: String, Codable, Sendable {
        /// The Agent Summary.
        case summary
        /// The Agent's last reply, read from its transcript.
        case reply
    }

    /// Where `text` came from.
    let source: Source
    /// The summary or the last reply, in full. A reply over the phone's
    /// byte budget keeps its end, after the line "Earlier text is on your
    /// iPhone."
    let text: String
    /// The last reply, under a "LAST REPLY" kicker, when `text` is a
    /// Working Agent's fresh summary; nil otherwise.
    let lastReply: String?
    /// The phone could not refresh it: shown dimmed with "Checking…".
    let isStale: Bool
}

extension WatchLatest {
    /// The most UTF-8 bytes one shown paragraph holds before it breaks at
    /// a line, so no single `Text` lays out a whole long reply.
    static let paragraphByteLimit = 2 * 1024

    /// `text` as the paragraphs the watch lays out one per row: split on
    /// blank lines, and a paragraph over `paragraphByteLimit` further split
    /// between its lines. A single longer line stays whole.
    static func paragraphs(_ text: String) -> [String] {
        var result: [String] = []
        for block in text.components(separatedBy: "\n\n") {
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard trimmed.utf8.count > paragraphByteLimit else {
                result.append(trimmed)
                continue
            }
            var chunk = ""
            for line in trimmed.split(separator: "\n", omittingEmptySubsequences: false) {
                if !chunk.isEmpty, chunk.utf8.count + 1 + line.utf8.count > paragraphByteLimit {
                    result.append(chunk)
                    chunk = ""
                }
                chunk += chunk.isEmpty ? String(line) : "\n" + line
            }
            if !chunk.isEmpty { result.append(chunk) }
        }
        return result
    }
}

/// A Blocked prompt as the watch may act on it.
struct WatchBlockedPrompt: Codable, Hashable, Sendable {
    /// Which answers the watch offers, matching CarPlay.
    enum Approval: String, Codable, Sendable {
        /// Allow and Deny.
        case allow
        /// Deny only.
        case hold
        /// Nothing: answer on iPhone.
        case readOnly
    }

    /// The id the phone keeps the full prompt snapshot under.
    let promptID: UUID
    /// Which answers the watch offers.
    let approval: Approval
    /// The lossless command text for allow and hold; nil for readOnly.
    let command: String?
    /// The user-facing reason a prompt is held (risky or not fully readable).
    let holdReason: String?
}

/// How the phone handled an answer.
enum WatchAnswerOutcome: String, Codable, Sendable {
    /// The answer reached the Agent.
    case sent
    /// The prompt on screen no longer matches the one the watch showed.
    case promptChanged
    /// The phone's approval rules refused the answer.
    case refused
    /// The answer could not be delivered.
    case failed
}

/// The phone's reply to a `WatchRequest`.
enum WatchReply: Codable, Sendable, Equatable {
    /// The request was received; its outcome comes later.
    case received
    /// The current state.
    case state(WatchState)
    /// The Agent's latest text; nil when there is nothing to show.
    case latest(WatchLatest?)
    /// The Agent's Blocked prompt; nil when it is no longer Blocked.
    case blockedPrompt(WatchBlockedPrompt?)
    /// How an answer went.
    case answerResult(WatchAnswerOutcome)
    /// User-facing failure copy, such as "Can't reach studio".
    case failure(String)

    /// The JSON keys of the explicit encoding.
    private enum CodingKeys: String, CodingKey {
        case type, state, latest, blockedPrompt, outcome, message
    }

    /// The `type` discriminator values; renaming one breaks the wire.
    private enum Kind: String, Codable {
        case received, state, latest, blockedPrompt, answerResult, failure
    }

    /// Decodes the `type`-discriminated form; an unknown `type` throws.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .received:
            self = .received
        case .state:
            self = .state(try container.decode(WatchState.self, forKey: .state))
        case .latest:
            self = .latest(try container.decodeIfPresent(WatchLatest.self, forKey: .latest))
        case .blockedPrompt:
            self = .blockedPrompt(
                try container.decodeIfPresent(WatchBlockedPrompt.self, forKey: .blockedPrompt))
        case .answerResult:
            self = .answerResult(try container.decode(WatchAnswerOutcome.self, forKey: .outcome))
        case .failure:
            self = .failure(try container.decode(String.self, forKey: .message))
        }
    }

    /// Encodes the `type`-discriminated form; a nil payload omits its key.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .received:
            try container.encode(Kind.received, forKey: .type)
        case .state(let state):
            try container.encode(Kind.state, forKey: .type)
            try container.encode(state, forKey: .state)
        case .latest(let latest):
            try container.encode(Kind.latest, forKey: .type)
            try container.encodeIfPresent(latest, forKey: .latest)
        case .blockedPrompt(let prompt):
            try container.encode(Kind.blockedPrompt, forKey: .type)
            try container.encodeIfPresent(prompt, forKey: .blockedPrompt)
        case .answerResult(let outcome):
            try container.encode(Kind.answerResult, forKey: .type)
            try container.encode(outcome, forKey: .outcome)
        case .failure(let message):
            try container.encode(Kind.failure, forKey: .type)
            try container.encode(message, forKey: .message)
        }
    }
}

// MARK: - Events

/// Why the iPhone kept a watch message as the Agent's Composer draft
/// instead of sending it. The raw values are wire values.
enum WatchKeptReason: String, Codable, Sendable, Equatable {
    /// The Agent was Blocked ("answer the prompt first").
    case blocked
    /// The Agent's harness needs a sign-in on the Host.
    case signInRequired
    /// The Agent's harness needs the folder trusted on the Host.
    case folderTrustRequired
}

/// The final outcome of a watch message, as the phone reports it.
enum WatchDelivery: Codable, Sendable, Equatable {
    /// Delivered; `text` is what was actually sent (transcript or text).
    case sent(text: String)
    /// Definitely not delivered; the watch may retry.
    case notSent(reason: String)
    /// May have been delivered; the watch must not retry.
    case unknown
    /// Refused before anything was typed, so the iPhone kept it as a
    /// Composer draft.
    case keptAsDraft(reason: WatchKeptReason)
    /// The transcript was empty; nothing was sent.
    case noWords

    /// The JSON keys of the explicit encoding.
    private enum CodingKeys: String, CodingKey {
        case type, text, reason
    }

    /// The `type` discriminator values; renaming one breaks the wire.
    private enum Kind: String, Codable {
        case sent, notSent, unknown, keptAsDraft, noWords
    }

    /// Decodes the `type`-discriminated form; an unknown `type` throws.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .sent: self = .sent(text: try container.decode(String.self, forKey: .text))
        case .notSent: self = .notSent(reason: try container.decode(String.self, forKey: .reason))
        case .unknown: self = .unknown
        case .keptAsDraft:
            self = .keptAsDraft(reason: try container.decode(WatchKeptReason.self, forKey: .reason))
        case .noWords: self = .noWords
        }
    }

    /// Encodes the `type`-discriminated form.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .sent(let text):
            try container.encode(Kind.sent, forKey: .type)
            try container.encode(text, forKey: .text)
        case .notSent(let reason):
            try container.encode(Kind.notSent, forKey: .type)
            try container.encode(reason, forKey: .reason)
        case .unknown:
            try container.encode(Kind.unknown, forKey: .type)
        case .keptAsDraft(let reason):
            try container.encode(Kind.keptAsDraft, forKey: .type)
            try container.encode(reason, forKey: .reason)
        case .noWords:
            try container.encode(Kind.noWords, forKey: .type)
        }
    }
}

/// A phone → watch event queued with `transferUserInfo`, so it survives
/// the watch app being suspended.
enum WatchEvent: Codable, Sendable, Equatable {
    /// The outcome of the message `messageID` sent to an Agent.
    case delivery(messageID: UUID, WatchAgentID, WatchDelivery)

    /// The JSON keys of the explicit encoding.
    private enum CodingKeys: String, CodingKey {
        case type, messageID, agent, delivery
    }

    /// The `type` discriminator values; renaming one breaks the wire.
    private enum Kind: String, Codable {
        case delivery
    }

    /// Decodes the `type`-discriminated form; an unknown `type` throws.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .delivery:
            self = .delivery(
                messageID: try container.decode(UUID.self, forKey: .messageID),
                try container.decode(WatchAgentID.self, forKey: .agent),
                try container.decode(WatchDelivery.self, forKey: .delivery))
        }
    }

    /// Encodes the `type`-discriminated form.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .delivery(let messageID, let agent, let delivery):
            try container.encode(Kind.delivery, forKey: .type)
            try container.encode(messageID, forKey: .messageID)
            try container.encode(agent, forKey: .agent)
            try container.encode(delivery, forKey: .delivery)
        }
    }
}

/// The metadata paired with a voice recording's `transferFile`.
struct WatchVoiceFile: Codable, Hashable, Sendable {
    /// The message id the matching `WatchRequest.voice` carried.
    let messageID: UUID
    /// The Agent the recording is for.
    let agentID: WatchAgentID
    /// The recording's length in seconds.
    let duration: Double
}

// MARK: - Codec

/// Why `WatchWireCodec.decode` refused data.
enum WatchWireError: Error, Equatable, Sendable {
    /// The envelope came from another wire version (the associated value).
    case versionMismatch(Int)
    /// Not a wire envelope, or a body that does not match the expected
    /// type (including an unknown `type` discriminator).
    case malformed
}

/// Encodes and decodes every wire value as versioned JSON `Data` for
/// `sendMessageData`, `transferUserInfo`, and application context: the
/// envelope is `{"v":1,"body":…}` with ISO 8601 dates.
enum WatchWireCodec {
    /// The application-context key holding the encoded `WatchState`.
    static let applicationContextKey = "waycar.watch.state"
    /// The `transferUserInfo` key holding an encoded `WatchEvent`.
    static let userInfoKey = "waycar.watch.event"
    /// The `transferFile` metadata key holding an encoded `WatchVoiceFile`.
    static let fileMetadataKey = "waycar.watch.voice"

    /// The outer envelope written on encode.
    private struct Envelope<Body: Encodable>: Encodable {
        /// The wire version.
        let v: Int
        /// The wrapped value.
        let body: Body
    }

    /// Only the version, read before the body so a mismatch is reported as
    /// such rather than as a shape error.
    private struct Header: Decodable {
        /// The wire version.
        let v: Int
    }

    /// The outer envelope read once the version matched.
    private struct Opened<Body: Decodable>: Decodable {
        /// The wrapped value.
        let body: Body
    }

    /// Wraps `value` in a version-1 envelope. Keys are sorted, so equal
    /// values encode to equal bytes.
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(Envelope(v: WatchWire.version, body: value))
    }

    /// Unwraps a `T` from an envelope. Throws `WatchWireError.versionMismatch`
    /// for any version other than `WatchWire.version`, and
    /// `WatchWireError.malformed` for anything else that does not decode.
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let version: Int
        do {
            version = try decoder.decode(Header.self, from: data).v
        } catch {
            throw WatchWireError.malformed
        }
        guard version == WatchWire.version else {
            throw WatchWireError.versionMismatch(version)
        }
        do {
            return try decoder.decode(Opened<T>.self, from: data).body
        } catch let error as WatchWireError {
            throw error
        } catch {
            throw WatchWireError.malformed
        }
    }
}
