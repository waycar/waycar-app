import Foundation

/// Ids Waycar and its host tools exchange for tmux objects carry the `tmux:`
/// prefix (`tmux:$1` session, `tmux:@2` window, `tmux:%3` pane), so they can
/// never collide with herdr ids on a dual Host. tmux commands take the raw id.
enum TmuxID {
    static let prefix = "tmux:"

    /// The app-side id for a raw tmux id (`%3` -> `tmux:%3`).
    static func app(_ raw: String) -> String { prefix + raw }

    /// The raw tmux id inside an app-side id; nil for any other id.
    static func raw(_ appID: String) -> String? {
        guard appID.hasPrefix(prefix) else { return nil }
        let raw = String(appID.dropFirst(prefix.count))
        return raw.isEmpty ? nil : raw
    }

    /// The number in a raw id (`$12` -> 12), for lowest-id ordering.
    static func number(_ raw: String) -> Int? { Int(raw.dropFirst()) }
}

/// One `list-sessions` record.
struct TmuxSessionRecord: Sendable, Equatable {
    /// Raw id, `$N`.
    let id: String
    let name: String
    /// The group name; empty when the session is not grouped.
    let group: String
    let grouped: Bool
    /// Number of clients attached.
    let attached: Int
    let path: String
}

/// One `list-windows -a` record. A window linked into several sessions
/// (grouped sessions, T14) is listed once per session.
struct TmuxWindowRecord: Sendable, Equatable {
    /// Raw id, `@N`.
    let id: String
    /// Raw id of the session this listing row belongs to.
    let sessionID: String
    let index: Int
    let name: String
    /// Whether this is its session's current window.
    let active: Bool
    let zoomed: Bool
}

/// One `list-panes -a` record, with the pane options Waycar's host tools
/// and two third-party status plugins write.
struct TmuxPaneRecord: Sendable, Equatable {
    /// Raw id, `%N`.
    let id: String
    let sessionID: String
    let windowID: String
    let index: Int
    let active: Bool
    let dead: Bool
    let alternateOn: Bool
    let pid: Int?
    let tty: String
    let width: Int
    let height: Int
    /// `pane_current_command`: the foreground process name (claude shows its
    /// version here, T11).
    let currentCommand: String
    /// `@waycar_status`, `@waycar_agent`, `@waycar_seq`: empty when unset.
    let waycarStatus: String
    let waycarAgent: String
    let waycarSeq: String
    /// tmux-agent-sidebar's `@pane_status` (running/waiting/idle/error).
    let sidebarStatus: String
    /// workmux's `@workmux_pane_status` (an icon).
    let workmuxStatus: String
    let currentPath: String
    /// `@waycar_session`: a session id or a session file path.
    let waycarSession: String
    /// `@waycar_transcript`: a percent-encoded transcript path.
    let waycarTranscript: String
    let title: String
    let startCommand: String
    /// App-owned Launch Tag, read only by a fresh inventory, not the hooks.
    let waycarLaunch: String

    init(
        id: String, sessionID: String, windowID: String, index: Int = 0,
        active: Bool = false, dead: Bool = false, alternateOn: Bool = false,
        pid: Int? = nil, tty: String = "", width: Int = 80, height: Int = 24,
        currentCommand: String, waycarStatus: String = "", waycarAgent: String = "",
        waycarSeq: String = "", sidebarStatus: String = "", workmuxStatus: String = "",
        currentPath: String = "", waycarSession: String = "", waycarTranscript: String = "",
        title: String = "", startCommand: String = "", waycarLaunch: String = ""
    ) {
        self.id = id
        self.sessionID = sessionID
        self.windowID = windowID
        self.index = index
        self.active = active
        self.dead = dead
        self.alternateOn = alternateOn
        self.pid = pid
        self.tty = tty
        self.width = width
        self.height = height
        self.currentCommand = currentCommand
        self.waycarStatus = waycarStatus
        self.waycarAgent = waycarAgent
        self.waycarSeq = waycarSeq
        self.sidebarStatus = sidebarStatus
        self.workmuxStatus = workmuxStatus
        self.currentPath = currentPath
        self.waycarSession = waycarSession
        self.waycarTranscript = waycarTranscript
        self.title = title
        self.startCommand = startCommand
        self.waycarLaunch = waycarLaunch
    }
}
