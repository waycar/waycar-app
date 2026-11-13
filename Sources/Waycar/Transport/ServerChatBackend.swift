import Foundation

/// A server-hosted, chat-first Backend: an optional shared server on the
/// Host whose sessions are chat-only Agents, started only by the user's
/// Start … server (`docs/design/opencode-backend.md`, "Shared server-Backend
/// layer"): Codex's app-server (`docs/design/codex-backend.md`) and OpenCode
/// 2's shared server (`docs/design/opencode-backend.md`).
///
/// What the Console, New Agent and Host detail do for any such runtime keys
/// on this: the installed/stopped/running state and its Start, the
/// chat-only gate (structured requests, Chat Mode always on), the linked
/// pane behind Show Terminal, session-to-pane links, Closed Sessions resume
/// and the per-Host visibility. The wire protocol, auth, identity and
/// origin, approval recovery and the launch itself stay in each Backend's
/// transport.
enum ServerChatBackend: String, Sendable, CaseIterable, Hashable {
    case codex
    case opencode

    /// The Backend its sessions are listed under.
    var backend: HostBackend {
        switch self {
        case .codex: .codex
        case .opencode: .opencode
        }
    }

    /// The agent kind its sessions run as, in Closed Sessions, default names,
    /// launch errors and the linked terminal pane.
    var agentKind: SupportedAgentKind {
        switch self {
        case .codex: .codex
        case .opencode: .opencode
        }
    }

    /// What one of its sessions is called in copy.
    var sessionNoun: String {
        switch self {
        case .codex: "thread"
        case .opencode: "session"
        }
    }

    /// "Codex thread".
    var sessionDescription: String { "\(backend.displayName) \(sessionNoun)" }

    /// "Codex server": its state, its Start and its start errors.
    var serverName: String { "\(backend.displayName) server" }

    /// Its key in `HostBackendPreferences`' runtime visibility. Persisted and
    /// synced: never change one.
    var visibilityKey: String {
        switch self {
        case .codex: "codex"
        case .opencode: "opencode"
        }
    }

    /// Its sessions' pane ids are this prefix plus the session id.
    var paneIDPrefix: String {
        switch self {
        case .codex: "codex:"
        case .opencode: "opencode:"
        }
    }

    /// The session id one of its pane ids names.
    func sessionID(paneID: String) -> String {
        String(paneID.dropFirst(paneIDPrefix.count))
    }

    /// Whether closing one of its sessions archives it on the server: its
    /// sessions never unload, so the card's Close is **Archive** (card 1530
    /// 1a), and Closed Sessions lists what the server keeps archived.
    var archivesSessions: Bool {
        switch self {
        case .codex: false
        case .opencode: true
        }
    }

    /// What the Host's one detection exec found of it; nil when not installed.
    func presence(in presence: HostBackendPresence) -> (any ServerRuntimePresence)? {
        switch self {
        case .codex: presence.codex
        case .opencode: presence.opencode
        }
    }

    /// Whether that detection asked about it at all: a presence cached
    /// before its probe existed did not.
    func wasProbed(in presence: HostBackendPresence) -> Bool {
        switch self {
        case .codex: presence.codexProbed == true
        case .opencode: presence.opencodeProbed == true
        }
    }

    /// The launch that resumes session `id` on its server (a Closed Session).
    func resumeRequest(sessionID: String, name: String, cwd: String, launchID: UUID) -> AgentLaunchRequest {
        switch self {
        case .codex:
            AgentLaunchRequest(
                kind: agentKind.rawValue, name: name, cwd: cwd, launchID: launchID,
                codex: CodexLaunchOptions(resumeThreadID: sessionID))
        case .opencode:
            // Sessions never unload; a Closed Session is an archived one,
            // and Resume unarchives it (card 1530 1a).
            AgentLaunchRequest(
                kind: agentKind.rawValue, name: name, cwd: cwd, launchID: launchID,
                opencode: OpenCodeLaunchOptions(resumeSessionID: sessionID))
        }
    }

    /// The terminal launch that shows session `id` in a pane on a terminal
    /// Backend, joining the server rather than starting its own runtime.
    func linkedPaneRequest(
        sessionID: String, name: String, launchID: UUID?, mayHaveStarted: Bool
    ) -> AgentLaunchRequest {
        switch self {
        case .codex:
            AgentLaunchRequest(
                kind: agentKind.rawValue, name: name, arguments: ["resume", sessionID],
                launchID: launchID, mayHaveStarted: mayHaveStarted, joinsCodexServer: true)
        case .opencode:
            // Opens that session in the shared server, or creates it with
            // exactly that id at its first prompt (O12).
            AgentLaunchRequest(
                kind: agentKind.rawValue, name: name, arguments: ["--session", sessionID],
                launchID: launchID, mayHaveStarted: mayHaveStarted)
        }
    }
}

extension HostBackend {
    /// The server chat runtime this Backend is; nil for a terminal Backend
    /// and Ultimate.
    var serverChat: ServerChatBackend? {
        ServerChatBackend.allCases.first { $0.backend == self }
    }

    /// A server-hosted, chat-first Backend (`ServerChatBackend`).
    var isServerChat: Bool { serverChat != nil }

    /// Its rows' Close archives the session instead (`archivesSessions`).
    var archivesOnClose: Bool { serverChat?.archivesSessions == true }

    /// Whether its Console rows swipe and offer Close (or Archive): a
    /// terminal Backend's tabs, and an archiving server's sessions.
    var closesRows: Bool { hasTerminal || archivesOnClose }
}

/// A session its server keeps archived (`Transport.archivedServerSessions`),
/// listed as a Closed Session whose Resume unarchives it.
struct ArchivedServerSession: Sendable, Equatable {
    let sessionID: String
    let title: String?
    let directory: String
    /// The Workspace its unarchived session would list under.
    var workspaceID: String?
    let archivedAt: Date
}

/// What detection found of a server chat runtime's CLI and server. Detection
/// itself stays per Backend and starts nothing.
protocol ServerRuntimePresence: Sendable {
    /// The CLI's version.
    var version: String { get }
    /// The CLI's absolute path on the Host.
    var path: String { get }
    /// At or above the oldest version Waycar drives.
    var meetsFloor: Bool { get }
    /// Its server answered detection.
    var isRunning: Bool { get }
}

extension CodexPresence: ServerRuntimePresence {}
extension OpenCodePresence: ServerRuntimePresence {}

extension HostBackendPresence {
    /// Server chat runtimes whose server answered: only those get a
    /// projection. A stopped server shows only in New Agent and Host detail,
    /// never as a Console failure (Mike, card 1224 3a).
    var runningServerChats: [ServerChatBackend] {
        ServerChatBackend.allCases.filter { server in
            server.presence(in: self).map { $0.meetsFloor && $0.isRunning } ?? false
        }
    }
}
