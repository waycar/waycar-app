import CryptoKit
import Foundation

/// An Agent that left its Pane — it exited back to the shell, or its Pane or
/// Tab closed — kept so the user can start it again where it left off
/// (CONTEXT.md **Closed Session**). herdr has no closed state: rows simply
/// vanish or turn into shells, so the Console captures the record from the
/// row it listed before. It syncs through iCloud Keychain (ADR 0019) and
/// expires `ClosedSessionsStore.retention` after `closedAt`.
///
/// Only kinds in Waycar's catalog are captured: resuming is an `agent.start`,
/// which takes a `SupportedAgentKind`. A record whose kind this build does
/// not know (a newer build's) does not decode, and is left alone.
struct ClosedSession: Codable, Identifiable, Hashable, Sendable {
    /// Where herdr said the Agent's own session lives (`agent_session`): its
    /// session id, or its session file.
    struct SessionReference: Codable, Hashable, Sendable {
        enum Kind: String, Codable, Sendable {
            case id, path
        }

        let kind: Kind
        let value: String
    }

    /// See `recordID`: equal for every device that captured the same closure.
    let id: String
    let hostID: Host.ID
    /// The Host's name when the Agent closed: shown and searched only while
    /// the Host's current name is unknown.
    let hostName: String
    let kind: SupportedAgentKind
    /// herdr's name for the Agent, when it reported one.
    let agentName: String?
    /// The terminal title the Agent last showed.
    let title: String?
    let cwd: String
    let workspaceID: String?
    let workspaceLabel: String?
    let tabLabel: String?
    /// Nil when herdr never reported a session for the Agent; resuming then
    /// opens the Agent's own resume picker.
    let session: SessionReference?
    /// When the capturing device last saw the Agent running: the live
    /// snapshot before the one it was gone from. A tombstone forgets the
    /// copies seen running no later than it (`ClosedSessionsStore`). Whole
    /// milliseconds, like `closedAtMilliseconds`.
    private(set) var lastSeenRunningAtMilliseconds: Int64
    /// When a device noticed the Agent gone. Whole milliseconds, so every
    /// device that decodes a record compares it equal to the one that
    /// encoded it.
    private(set) var closedAtMilliseconds: Int64
    /// Whether the Agent ran in Chat Mode: resuming it relaunches it in Chat
    /// Mode. Records synced by builds before Chat Mode lack the key and
    /// decode as false.
    var chatMode: Bool
    /// The backend the Agent ran on (ADR 0026): resuming launches there.
    /// Records from builds before tmux support lack the key and decode as
    /// herdr; older builds ignore it, so the field is additive.
    let backend: HostBackend

    var closedAt: Date {
        Date(timeIntervalSince1970: Double(closedAtMilliseconds) / 1000)
    }

    var lastSeenRunningAt: Date {
        Date(timeIntervalSince1970: Double(lastSeenRunningAtMilliseconds) / 1000)
    }

    init(
        id: String, hostID: Host.ID, hostName: String, kind: SupportedAgentKind,
        agentName: String?, title: String?, cwd: String, workspaceID: String?,
        workspaceLabel: String?, tabLabel: String?, session: SessionReference?,
        lastSeenRunningAt: Date, closedAt: Date, chatMode: Bool = false,
        backend: HostBackend = .herdr
    ) {
        self.id = id
        self.hostID = hostID
        self.hostName = hostName
        self.kind = kind
        self.agentName = agentName
        self.title = title
        self.cwd = cwd
        self.workspaceID = workspaceID
        self.workspaceLabel = workspaceLabel
        self.tabLabel = tabLabel
        self.session = session
        lastSeenRunningAtMilliseconds = Self.milliseconds(lastSeenRunningAt)
        closedAtMilliseconds = Self.milliseconds(closedAt)
        self.chatMode = chatMode
        self.backend = backend
    }

    /// The kind Closed Sessions keeps `row` under: nil for a shell and for a
    /// kind Waycar cannot start, which are never kept.
    static func keptKind(of row: ConsoleAgent) -> SupportedAgentKind? {
        guard !row.isShell else { return nil }
        return SupportedAgentKind(rawValue: row.agent.kind)
    }

    /// Whether a close of `row` leaves a Closed Session that brings its
    /// conversation back (the exact session or the Agent's own picker), so
    /// Close Agent needs no confirmation (#185). A continue-the-latest
    /// fallback does not count: it reopens the folder's newest session,
    /// which may be another Agent's. Judged on the session the row reports
    /// now: the record may remember one the row has since dropped, which
    /// only errs toward asking.
    static func resumesConversation(of row: ConsoleAgent) -> Bool {
        guard let kind = keptKind(of: row) else { return false }
        let session = row.agent.agentSession.flatMap(SessionReference.init)
        let fallback = resumeArguments(kind: kind, session: nil)
        if resumeArguments(kind: kind, session: session) != fallback { return true }
        return pickerKinds.contains(kind)
    }

    /// Kinds whose session-less resume form is the Agent's own picker,
    /// rather than its latest session or a fresh start.
    private static let pickerKinds: Set<SupportedAgentKind> = [.claude, .codex, .omp, .pi, .devin]

    /// The record for `row`, an Agent a live snapshot no longer runs.
    /// `session` is the last `agent_session` herdr reported for it: herdr
    /// clears it as the Agent leaves, so the row itself often has none. Nil
    /// when `keptKind(of:)` is.
    init?(
        closing row: ConsoleAgent, session: AgentSessionInfo?, lastSeenRunningAt: Date,
        closedAt: Date, chatMode: Bool = false
    ) {
        guard let kind = Self.keptKind(of: row) else { return nil }
        let reference = (session ?? row.agent.agentSession).flatMap(SessionReference.init)
        // A server chat session resumes only by its reference, which Codex
        // omits for unnamed, turn-less launches. A server that archives its
        // sessions keeps their record itself (`init(archived:)`).
        guard !row.backend.isServerChat || row.agent.agentSession != nil,
            !row.backend.archivesOnClose
        else { return nil }
        self.init(
            id: Self.recordID(
                hostID: row.hostID, kind: kind, session: reference,
                terminalID: row.agent.terminalID),
            hostID: row.hostID,
            hostName: row.hostName,
            kind: kind,
            agentName: row.agent.name.flatMap(Self.nonEmpty),
            title: Self.nonEmpty(row.agent.title),
            cwd: row.agent.cwd,
            workspaceID: Self.nonEmpty(row.agent.workspaceID),
            workspaceLabel: row.workspaceLabel.flatMap(Self.nonEmpty),
            tabLabel: row.tabLabel.flatMap(Self.nonEmpty),
            session: reference,
            lastSeenRunningAt: lastSeenRunningAt,
            closedAt: closedAt,
            chatMode: chatMode,
            backend: row.backend)
    }

    /// The record of a session `server` keeps archived: listed while the
    /// server lists it, never persisted or synced here (the server is its
    /// record), and resumed by unarchiving it. Same id as a capture of that
    /// session would have.
    init(
        archived: ArchivedServerSession, on server: ServerChatBackend, hostID: Host.ID,
        hostName: String
    ) {
        let reference = SessionReference(kind: .id, value: archived.sessionID)
        let title = archived.title.flatMap(Self.nonEmpty)
        self.init(
            id: Self.recordID(
                hostID: hostID, kind: server.agentKind, session: reference, terminalID: ""),
            hostID: hostID, hostName: hostName, kind: server.agentKind, agentName: title,
            title: title, cwd: archived.directory, workspaceID: archived.workspaceID,
            workspaceLabel: nil, tabLabel: nil, session: reference,
            lastSeenRunningAt: archived.archivedAt, closedAt: archived.archivedAt,
            backend: server.backend)
    }

    /// The record's identity. With a session it is the Host, kind and
    /// session, so every device that saw the Agent close — and the same
    /// session closing again after a resume — lands on one record. Without
    /// one it is the Host, kind and the terminal the Agent ran in, which
    /// every device also agrees on. Hashed: session paths are long, and the
    /// id names an iCloud Keychain item.
    static func recordID(
        hostID: Host.ID, kind: SupportedAgentKind, session: SessionReference?, terminalID: String
    ) -> String {
        let parts =
            if let session {
                [hostID.uuidString, kind.rawValue, "session", session.value]
            } else {
                [hostID.uuidString, kind.rawValue, "terminal", terminalID]
            }
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// `date` in the whole milliseconds a record stores.
    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// This record with no time later than `limit` (whole milliseconds): how
    /// a record another device stamped by a clock running ahead is read here.
    func clamped(notAfter limit: Int64) -> ClosedSession {
        var copy = self
        copy.lastSeenRunningAtMilliseconds = min(lastSeenRunningAtMilliseconds, limit)
        copy.closedAtMilliseconds = min(closedAtMilliseconds, limit)
        return copy
    }

    /// This record, its Agent seen running as late as `milliseconds` when
    /// that is later: a resume closed again unused keeps its closure time,
    /// but a tombstone written while it ran no longer forgets it.
    func seenRunning(until milliseconds: Int64) -> ClosedSession {
        var copy = self
        copy.lastSeenRunningAtMilliseconds = max(lastSeenRunningAtMilliseconds, milliseconds)
        return copy
    }

    /// This record, in Chat Mode when either it or `other` (another copy of
    /// the same record) is: a device that never saw the Chat Marker, or a
    /// build before Chat Mode, must not turn a chat record back into a
    /// terminal one.
    func mergingChatMode(of other: ClosedSession) -> ClosedSession {
        guard other.chatMode, !chatMode else { return self }
        var copy = self
        copy.chatMode = true
        return copy
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension ClosedSession.SessionReference {
    /// herdr's reference as a record keeps it; nil for an empty value or a
    /// kind this build does not know.
    init?(_ info: AgentSessionInfo) {
        guard !info.value.isEmpty, let kind = Kind(rawValue: info.kind.rawValue) else {
            return nil
        }
        self.init(kind: kind, value: info.value)
    }
}

extension ClosedSession {
    /// Decoded by hand only so a missing `chatMode` (a record from a build
    /// before Chat Mode) reads as false and a missing `backend` (a build
    /// before tmux support) as herdr; encoding stays synthesized.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        hostID = try container.decode(Host.ID.self, forKey: .hostID)
        hostName = try container.decode(String.self, forKey: .hostName)
        kind = try container.decode(SupportedAgentKind.self, forKey: .kind)
        agentName = try container.decodeIfPresent(String.self, forKey: .agentName)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        cwd = try container.decode(String.self, forKey: .cwd)
        workspaceID = try container.decodeIfPresent(String.self, forKey: .workspaceID)
        workspaceLabel = try container.decodeIfPresent(String.self, forKey: .workspaceLabel)
        tabLabel = try container.decodeIfPresent(String.self, forKey: .tabLabel)
        session = try container.decodeIfPresent(SessionReference.self, forKey: .session)
        lastSeenRunningAtMilliseconds = try container.decode(
            Int64.self, forKey: .lastSeenRunningAtMilliseconds)
        closedAtMilliseconds = try container.decode(Int64.self, forKey: .closedAtMilliseconds)
        chatMode = try container.decodeIfPresent(Bool.self, forKey: .chatMode) ?? false
        backend = try container.decodeIfPresent(HostBackend.self, forKey: .backend) ?? .herdr
    }
}

extension ClosedSession {
    /// A native server chat resume must name a durable session (a Codex
    /// thread), never a picker.
    var canResume: Bool {
        !backend.isServerChat || (session?.kind == .id && session?.value.isEmpty == false)
    }

    /// The `agent.start` arguments that resume this session, mirroring
    /// herdr's own restore planner (`src/agent_resume.rs` `plan`): the exact
    /// session when one is known that the Agent can take (herdr's
    /// `agent_session`, the `@waycar_session` id Waycar's Status Hooks
    /// write on tmux, else the id the launch pinned in its marker), else the
    /// Agent's own picker or continue-the-latest form, else a plain start.
    /// herdr 0.9.3 reports no session for most kinds without its own
    /// integration installed (herdr-backend.md), so there only a pinned
    /// launch (claude, pi, copilot, qwen, grok) resumes exactly.
    var resumeArguments: [String] {
        Self.resumeArguments(kind: kind, session: session)
    }

    static func resumeArguments(kind: SupportedAgentKind, session: SessionReference?) -> [String] {
        // A value that reads as a flag would be parsed as one.
        let usable = session.flatMap { $0.value.hasPrefix("-") ? nil : $0 }
        let id = usable.flatMap { $0.kind == .id ? $0.value : nil }
        let any = usable?.value
        switch kind {
        case .claude:
            return id.map { ["--resume", $0] } ?? ["--resume"]
        case .codex:
            // The picker is filtered to the working directory.
            return id.map { ["resume", $0] } ?? ["resume"]
        case .omp:
            return any.map { ["--resume=\($0)"] } ?? ["--resume"]
        case .pi:
            return any.map { ["--session", $0] } ?? ["--resume"]
        case .devin:
            // A bare `--resume` picks interactively (`devin --help`).
            return id.map { ["--resume", $0] } ?? ["--resume"]
        case .grok, .qwen:
            // `--continue` reopens the most recent session in the working
            // directory (grok.md §7, qwen.md §7).
            return id.map { ["--resume", $0] } ?? ["--continue"]
        case .hermes:
            // `--resume latest` is this workspace's most recent session.
            // Not `--continue`: it first follows a breadcrumb keyed by the
            // terminal's tty, so a new pane on a reused /dev/pts/N reopens
            // whatever session last ran there (hermes.md §7).
            return ["--resume", id ?? "latest"]
        case .cursor, .droid, .qodercli:
            return id.map { ["--resume", $0] } ?? []
        case .copilot:
            // Copilot's `--resume` takes its value only joined.
            return id.map { ["--resume=\($0)"] } ?? ["--continue"]
        case .kilo:
            return id.map { ["--session", $0] } ?? ["--continue"]
        case .opencode, .kimi:
            // opencode has no picker flag: its session list lives in the TUI.
            return id.map { ["--session", $0] } ?? []
        case .mastracode:
            return id.map { ["--thread", $0] } ?? []
        case .antigravity:
            return id.map { ["--conversation", $0] } ?? ["--continue"]
        case .gemini:
            // `latest` is the most recent session of this project.
            return ["--resume", id ?? "latest"]
        case .cline:
            // No continue form; `--id` takes the root session id.
            return id.map { ["--id", $0] } ?? []
        case .kiro:
            // A bare `--resume` reopens this directory's latest session.
            return id.map { ["--resume-id", $0] } ?? ["--resume"]
        case .muse:
            // `resume <id>`; `--last` is the most recent session in this
            // workspace (muse.md §7).
            return id.map { ["resume", $0] } ?? ["resume", "--last"]
        case .amp, .maki:
            // herdr knows no resume form for these.
            return []
        }
    }

    /// Search over a closed row (`ConsoleSearch`): the name, kind, working
    /// directory, Workspace, tab, title and Host — `currentHostName`, the
    /// name the card shows, else the one the Host had when the Agent closed.
    func matchesSearch(_ query: String, currentHostName: String?) -> Bool {
        ConsoleSearch.matches(
            query,
            in: [
                agentName, kind.rawValue, kind.displayName, cwd, workspaceLabel, tabLabel, title,
                currentHostName ?? hostName,
            ])
    }
}

/// An Agent a live snapshot no longer runs, as `HostConsoleProjection`
/// hands it to `ClosedSessionsStore`: the row it last listed, the last
/// session herdr reported for it, and when a live snapshot last showed it
/// running — the previous one the projection applied, or the cached one its
/// rows were seeded from. Nil when that time is unknown (a cache written
/// before it was kept), which the store treats as too old to record.
struct ClosedAgentCapture: Sendable, Equatable {
    let row: ConsoleAgent
    let session: AgentSessionInfo?
    let lastSeenRunningAt: Date?
}

extension ClosedAgentCapture {
    /// This capture with the session its launch pinned or bound in
    /// `marker` (`ChatModeMarker.launchSession(of:)`), when the Backend
    /// reported none: herdr reports none for most kinds without its own
    /// integration. A reported session wins.
    func withLaunchSession(from marker: ChatModeMarker?) -> ClosedAgentCapture {
        guard (session?.value ?? "").isEmpty, (row.agent.agentSession?.value ?? "").isEmpty,
            let pinned = marker?.launchSession(of: row.agent)
        else { return self }
        return ClosedAgentCapture(
            row: row,
            session: AgentSessionInfo(
                agent: row.agent.kind, kind: AgentSessionRefKind(rawValue: pinned.kind),
                source: "waycar", value: pinned.value),
            lastSeenRunningAt: lastSeenRunningAt)
    }
}

/// Stored in Closed Session records. Unknown kinds fail to decode, which is
/// how a newer build's record stays out of this one.
extension SupportedAgentKind: Codable {}
