import Foundation

/// The Chat Marker (`CONTEXT.md`): the JSON file on the Host that records
/// "this pane was launched in Chat Mode", so every device and the plugin
/// know. It lives at `<waycar plugin config dir>/chat/<fileName(paneID:)>`.
/// A launch outside Chat Mode that pinned its session id writes one too,
/// with `chat_mode` false, so a Closed Session on herdr knows the session
/// herdr itself does not report (`ChatModeLaunch.sessionPin`).
///
/// Wire format v1, snake_case; `terminal_id`, `cwd`, `session` and `prompt`
/// may be null, and `launched_at` is ISO 8601 UTC with or without fractional
/// seconds. `prompt` holds the normalized Chat Prompt the launch sent: the
/// plugin's `waycar-chat-prompt` extension reads it for opencode, which has
/// no launch-time system-prompt flag; the other kinds ignore it. Older
/// markers without the field still decode. `chat_mode` absent reads as
/// true, the only kind of marker before the field existed.
struct ChatModeMarker: Codable, Equatable, Sendable {
    /// Where the Agent's own session lives when the launch pinned or knew
    /// one: `kind` is `"id"` or `"path"`, as in herdr's `agent_session`.
    struct Session: Codable, Equatable, Sendable {
        let kind: String
        let value: String
    }

    let v: Int
    let paneID: String
    /// Nil matches any Agent in the pane with the same kind.
    let terminalID: String?
    let kind: String
    let cwd: String?
    let session: Session?
    /// The normalized Chat Prompt the launch sent; nil on a marker written
    /// before the field existed.
    let prompt: String?
    /// False for a plain launch whose marker only records its pinned
    /// session.
    let chatMode: Bool
    let launchedAt: Date

    init(
        v: Int = 1, paneID: String, terminalID: String?, kind: String,
        cwd: String?, session: Session?, prompt: String? = nil, chatMode: Bool = true,
        launchedAt: Date
    ) {
        self.v = v
        self.paneID = paneID
        self.terminalID = terminalID
        self.kind = kind
        self.cwd = cwd
        self.session = session
        self.prompt = prompt
        self.chatMode = chatMode
        self.launchedAt = launchedAt
    }

    private enum CodingKeys: String, CodingKey {
        case v
        case paneID = "pane_id"
        case terminalID = "terminal_id"
        case kind
        case cwd
        case session
        case prompt
        case chatMode = "chat_mode"
        case launchedAt = "launched_at"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        v = try container.decode(Int.self, forKey: .v)
        paneID = try container.decode(String.self, forKey: .paneID)
        terminalID = try container.decodeIfPresent(String.self, forKey: .terminalID)
        kind = try container.decode(String.self, forKey: .kind)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        session = try container.decodeIfPresent(Session.self, forKey: .session)
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
        chatMode = (try? container.decodeIfPresent(Bool.self, forKey: .chatMode)) ?? true
        let launched = try container.decode(String.self, forKey: .launchedAt)
        guard let date = ChatModeTimestamp.date(from: launched) else {
            throw DecodingError.dataCorruptedError(
                forKey: .launchedAt, in: container,
                debugDescription: "launched_at is not an ISO 8601 timestamp")
        }
        launchedAt = date
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(v, forKey: .v)
        try container.encode(paneID, forKey: .paneID)
        // Absent values go out as explicit nulls, matching the wire format.
        try container.encode(terminalID, forKey: .terminalID)
        try container.encode(kind, forKey: .kind)
        try container.encode(cwd, forKey: .cwd)
        try container.encode(session, forKey: .session)
        // Absent as an explicit null, like the other nullable fields.
        try container.encode(prompt, forKey: .prompt)
        try container.encode(chatMode, forKey: .chatMode)
        try container.encode(ChatModeTimestamp.string(from: launchedAt), forKey: .launchedAt)
    }

    /// The marker's file name for a pane: unpadded base64url of the UTF-8
    /// pane id plus `.json`, the plugin's `paneFileName` rule. Pane ids are
    /// opaque, so they never appear in a path verbatim.
    static func fileName(paneID: String) -> String {
        Data(paneID.utf8).base64URLEncodedString() + ".json"
    }

    /// Whether this marker describes `agent`: same pane and kind, and
    /// either the same terminal (or the marker recorded none), or the
    /// marker's session equals the Agent's live `agent_session` (same kind
    /// and non-empty value). The session match recognizes a chat herdr
    /// restored or resumed in a new terminal of the same pane; an empty
    /// value counts as no session. A pane reused by another Agent after the
    /// chat one exited no longer applies.
    func applies(to agent: Agent) -> Bool {
        guard paneID == agent.paneID, kind == agent.kind else { return false }
        if terminalID == nil || terminalID == agent.terminalID { return true }
        guard let session, !session.value.isEmpty,
            let live = agent.agentSession, !live.value.isEmpty
        else { return false }
        return session.kind == live.kind.rawValue && session.value == live.value
    }

    /// The session this marker's launch pinned or bound, when it still
    /// describes `agent` and holds a non-empty one.
    func launchSession(of agent: Agent) -> Session? {
        guard applies(to: agent), let session, !session.value.isEmpty else { return nil }
        return session
    }
}

/// ISO 8601 UTC timestamps shared by the Chat Mode wire formats (Chat
/// Marker, transcript reader output): written with milliseconds, like the
/// plugin's `Date.toISOString()`, and read with or without fractional
/// seconds.
enum ChatModeTimestamp {
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let whole = Date.ISO8601FormatStyle()

    static func date(from string: String) -> Date? {
        if let date = try? fractional.parse(string) { return date }
        return try? whole.parse(string)
    }

    /// Rounded to whole milliseconds, which are written by hand: the
    /// formatter truncates its fraction, and a date parsed from `…614Z` can
    /// sit a hair below .614, so it wrote `…613Z` and the Host's copy of a
    /// marker read as another launch than the copy recorded here
    /// (`ChatGreeting.seed`, `ConsoleStore.chatTranscriptKey`).
    static func string(from date: Date) -> String {
        let milliseconds = (date.timeIntervalSinceReferenceDate * 1000).rounded()
        let seconds = (milliseconds / 1000).rounded(.down)
        let fraction = Int(milliseconds - seconds * 1000)
        let stamp = whole.format(Date(timeIntervalSinceReferenceDate: seconds))
        return "\(stamp.dropLast()).\(String(format: "%03d", fraction))Z"
    }
}
