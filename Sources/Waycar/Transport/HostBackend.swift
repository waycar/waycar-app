import Foundation

/// The program on a Host that owns its Agents: herdr, herdr-core
/// (ADR 0031), plain tmux (ADR 0026), Ultimate's chats, Codex's shared
/// app-server (`docs/design/codex-backend.md`) or OpenCode 2's shared server
/// (`docs/design/opencode-backend.md`). A Host may run all of them;
/// each present backend gets its own Console projection over
/// the Host's one SSH connection.
///
/// `.herdr` and `.core` are the two runtimes that can fill the Host's herdr
/// lead slot (`fillsHerdrSlot`); they never share agents, so both get their
/// own projection. `allCases` is stable inventory order, not lead order.
enum HostBackend: String, Codable, Sendable, CaseIterable, Hashable {
    case herdr
    case core
    case tmux
    case zellij
    case ultimate
    case codex
    case opencode

    /// Ultimate conversations, Codex threads and OpenCode sessions have a
    /// transcript, never a terminal of their own (a linked pane belongs to
    /// its terminal backend).
    var hasTerminal: Bool {
        switch self {
        case .herdr, .core, .tmux, .zellij: true
        case .ultimate, .codex, .opencode: false
        }
    }

    /// Whether a Codex or OpenCode chat started from New Agent opens its
    /// linked desk terminal here. Zellij starts Agents, but its linked-pane
    /// path (Chat Markers, hiding the pane behind its chat) is not built, so
    /// on a Zellij-only Host those chats stay chat-only.
    var hostsLinkedServerTerminal: Bool {
        hasTerminal && capabilities.startsAgents && self != .zellij
    }

    /// What this backend can do that the others cannot; the UI gates per row.
    var capabilities: HostBackendCapabilities {
        switch self {
        case .herdr:
            HostBackendCapabilities(
                takeover: true, pluginRowLayout: true, namedSessions: true,
                worktrees: true, renaming: true, startsAgents: true)
        case .core:
            // Reads, drives and starts terminals in a folder; worktrees and
            // new Workspaces are a later slice.
            HostBackendCapabilities(
                takeover: false, pluginRowLayout: false, namedSessions: false,
                worktrees: false, renaming: false, startsAgents: true)
        case .ultimate:
            HostBackendCapabilities(
                takeover: false, pluginRowLayout: false, namedSessions: false,
                worktrees: false, renaming: false, startsAgents: false)
        case .codex:
            // New Agent › Codex (`thread/start` in a folder) arrives with
            // the launch path; no worktrees, Workspaces or renames.
            HostBackendCapabilities(
                takeover: false, pluginRowLayout: false, namedSessions: false,
                worktrees: false, renaming: false, startsAgents: true)
        case .opencode:
            // New Agent › OpenCode creates a session in a folder; no
            // worktrees, Workspaces or renames.
            HostBackendCapabilities(
                takeover: false, pluginRowLayout: false, namedSessions: false,
                worktrees: false, renaming: false, startsAgents: true)
        case .zellij:
            HostBackendCapabilities(
                takeover: false, pluginRowLayout: false, namedSessions: false,
                worktrees: false, renaming: true, startsAgents: true)
        case .tmux:
            HostBackendCapabilities(
                takeover: false, pluginRowLayout: false, namedSessions: false,
                worktrees: true, renaming: true, startsAgents: true)
        }
    }

    /// Whether this backend is a herdr runtime (TUI or core). This is a
    /// category, not a lead check: use the TUI-first internal lead for
    /// priority, and capabilities for runtime-specific features.
    var fillsHerdrSlot: Bool {
        switch self {
        case .herdr, .core: true
        case .tmux, .zellij, .ultimate, .codex, .opencode: false
        }
    }

    /// UI-facing runtime names. Existing prose saying "herdr" still means
    /// the TUI (ADR 0031); executable names remain herdr and herdr-core.
    var displayName: String {
        switch self {
        case .herdr: "Herdr TUI"
        case .core: "Herdr Core"
        case .tmux: "tmux"
        case .zellij: "Zellij"
        case .ultimate: "Ultimate"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        }
    }

    /// " Herdr Core is connected." or " Herdr Core and tmux are connected.",
    /// appended to a failed lead runtime's message so the user sees what still
    /// works; empty for none.
    static func connectedSentence(_ backends: [HostBackend]) -> String {
        guard !backends.isEmpty else { return "" }
        let names = ListFormatter.localizedString(byJoining: backends.map(\.displayName))
        return " \(names) " + (backends.count == 1 ? "is connected." : "are connected.")
    }
}

/// The two herdr runtimes; the TUI leads internally when both are installed.
enum HerdrRuntime: String, Codable, Sendable, CaseIterable, Hashable {
    case tui
    case core

    /// The backend this runtime resolves to.
    var backend: HostBackend {
        switch self {
        case .tui: .herdr
        case .core: .core
        }
    }

    /// The picker's names; copy about the pick always uses both full names.
    var displayName: String {
        switch self {
        case .tui: "Herdr TUI"
        case .core: "Herdr Core"
        }
    }
}

/// Per-backend capabilities that differ between herdr, herdr-core and tmux.
struct HostBackendCapabilities: Sendable, Equatable {
    /// One writable attach owner: Take Over, Live in Another Window and
    /// Host-keyed terminal window ownership. tmux allows several clients, so
    /// its attaches never displace each other.
    let takeover: Bool
    /// The herdr plugin's Agent Row Layout snapshot (`sidebar.json`).
    let pluginRowLayout: Bool
    /// herdr named sessions (`Host.sessionName`).
    let namedSessions: Bool
    /// Worktree launches and new Workspaces (herdr's `worktree.*` and
    /// `workspace.create`, tmux's sessions and git worktrees). herdr-core's
    /// are a later slice.
    let worktrees: Bool
    /// Rename Agent and Workspace, and Move to Workspace (herdr's Rename Tab
    /// stays herdr-only).
    let renaming: Bool
    /// Whether the app can start an agent here.
    let startsAgents: Bool
}

/// Which backends a Host has, as one detection exec reports them. A backend
/// counts as present when it is installed, not only when it is serving, so a
/// stopped herdr stays herdr's failure (design §4.1).
struct HostBackendPresence: Sendable, Equatable, Codable {
    /// `herdr` resolves on the Host PATH or its API socket exists.
    var herdr: Bool
    /// The version `tmux -V` reports ("3.4", "3.7c", "next-3.6"); nil when
    /// tmux is absent.
    var tmuxVersion: String?
    /// Zellij's side-effect-free version probe; absent in older caches.
    var zellij: ZellijPresence?
    /// The Waycar plugin the same exec found (#209); nil when it was never
    /// probed, e.g. a presence cached by a build before the probe (decoding
    /// tolerates the missing key).
    var waycarPlugin: WaycarPluginDetection?
    /// The herdr-core binary the same exec found (ADR 0031); nil when none
    /// passed `hc <digits>`, and for a presence cached by a build before
    /// core (decoding tolerates the missing key).
    var core: CorePresence?
    /// Project locks are candidates; UltimateTransport verifies each over HTTP.
    var ultimate: [UltimateInstance]?
    /// The Codex CLI the same exec found, and whether its shared app-server
    /// answered `daemon version`; nil when none was found, and for a
    /// presence cached before Codex support (decoding tolerates the key).
    var codex: CodexPresence?
    /// Nil in caches written before Codex discovery; true distinguishes a
    /// completed probe that found no Codex from one that never asked.
    var codexProbed: Bool?
    /// The OpenCode 2 CLI the same exec found, and its server's state and
    /// registration (never its password); nil when none was found (OpenCode
    /// 1 included), and for a presence cached before OpenCode support.
    var opencode: OpenCodePresence?
    /// Nil in caches written before OpenCode discovery, as `codexProbed`.
    var opencodeProbed: Bool?
    /// The Host programs that did not answer within
    /// `HostBackendDetection.probeLimitSeconds`, in the order they ran;
    /// nil when every one answered. Whatever they would have reported is
    /// missing from the rest of the presence.
    var unansweredProbes: [HostDetectionProbe]?

    init(
        herdr: Bool, tmuxVersion: String?, waycarPlugin: WaycarPluginDetection? = nil,
        core: CorePresence? = nil, zellij: ZellijPresence? = nil, ultimate: [UltimateInstance]? = nil,
        codex: CodexPresence? = nil, codexProbed: Bool? = true,
        opencode: OpenCodePresence? = nil, opencodeProbed: Bool? = true,
        unansweredProbes: [HostDetectionProbe]? = nil
    ) {
        self.herdr = herdr
        self.tmuxVersion = tmuxVersion
        self.waycarPlugin = waycarPlugin
        self.core = core
        self.zellij = zellij
        self.ultimate = ultimate
        self.codex = codex
        self.codexProbed = codexProbed
        self.opencode = opencode
        self.opencodeProbed = opencodeProbed
        self.unansweredProbes = unansweredProbes
    }

    /// The first of `backend`'s programs that did not answer, if any.
    func unansweredProbe(of backend: HostBackend) -> HostDetectionProbe? {
        unansweredProbes?.first { $0.backend == backend }
    }

    /// Every Host before tmux support: herdr only.
    static let herdrOnly = HostBackendPresence(herdr: true, tmuxVersion: nil)

    /// The oldest tmux with format subscriptions, `attach -f` flags and
    /// `new-session -e` (tmux CHANGES, 3.1c to 3.2).
    static let minimumTmuxVersion = "3.2"

    /// tmux is present and at least `minimumTmuxVersion`.
    var tmuxUsable: Bool {
        tmuxVersion.map(Self.meetsTmuxFloor) ?? false
    }

    /// herdr-core is on the Host: a binary that printed `hc <digits>`.
    var coreFound: Bool { core != nil }

    /// Both herdr runtimes are installed; each gets its own inventory.
    var bothRuntimesFound: Bool { herdr && coreFound }

    /// Internal TUI-first lead, or nil when neither runtime is installed.
    var herdrSlot: HostBackend? {
        switch (herdr, coreFound) {
        case (true, false): .herdr
        case (false, true): .core
        case (true, true): .herdr
        case (false, false): nil
        }
    }

    /// Codex's server answered (`runningServerChats`).
    var codexRunning: Bool { runningServerChats.contains(.codex) }

    /// Installed runtimes are additive in stable TUI, core, tmux, Ultimate,
    /// then server chat (Codex, OpenCode) order. Without a herdr runtime any tmux gets
    /// its projection; with neither, herdr reports the gap.
    var backends: [HostBackend] {
        let servers = runningServerChats
        if herdr || coreFound || zellij != nil || !(ultimate ?? []).isEmpty || !servers.isEmpty {
            var present: [HostBackend] = []
            if herdr { present.append(.herdr) }
            if coreFound { present.append(.core) }
            if tmuxUsable { present.append(.tmux) }
            if zellij != nil { present.append(.zellij) }
            if !(ultimate ?? []).isEmpty { present.append(.ultimate) }
            present += servers.map(\.backend)
            return present
        }
        return tmuxVersion == nil ? [.herdr] : [.tmux]
    }

    /// Parses `major.minor` leniently from a `tmux -V` version: "3.2a",
    /// "next-3.6" and "openbsd-7.5" style strings. A version without digits
    /// ("master") is a development build, newer than any floor.
    static func meetsTmuxFloor(_ version: String) -> Bool {
        guard let parsed = majorMinor(version) else { return true }
        guard let floor = majorMinor(minimumTmuxVersion) else { return true }
        return parsed.major != floor.major ? parsed.major > floor.major : parsed.minor >= floor.minor
    }

    private static func majorMinor(_ version: String) -> (major: Int, minor: Int)? {
        guard let match = version.firstMatch(of: /([0-9]+)\.([0-9]+)/),
            let major = Int(match.1), let minor = Int(match.2)
        else { return nil }
        return (major, minor)
    }
}

/// A Host program backend detection runs, named on the `timedout=` line the
/// script prints when it did not answer in time
/// (`HostBackendDetection.probeLimitSeconds`). The raw values are that
/// line's words: never change one.
enum HostDetectionProbe: String, Codable, Sendable, CaseIterable {
    case herdrPlugins = "herdr-plugins"
    case tmux
    case zellij
    case herdrCore = "herdr-core"
    case hc
    case codexVersion = "codex-version"
    case codexDaemon = "codex-daemon"
    case opencodeVersion = "opencode-version"
    case opencodeService = "opencode-service"

    /// The runtime it asks about.
    var backend: HostBackend {
        switch self {
        case .herdrPlugins: .herdr
        case .tmux: .tmux
        case .zellij: .zellij
        case .herdrCore, .hc: .core
        case .codexVersion, .codexDaemon: .codex
        case .opencodeVersion, .opencodeService: .opencode
        }
    }

    /// The command that did not answer, as the user would type it.
    var command: String {
        switch self {
        case .herdrPlugins: "herdr plugin list --json"
        case .tmux: "tmux -V"
        case .zellij: "zellij --version"
        case .herdrCore: "herdr-core --version"
        case .hc: "hc --version"
        case .codexVersion: "codex --version"
        case .codexDaemon: "codex app-server daemon version"
        case .opencodeVersion: "opencode --version"
        case .opencodeService: "opencode service status"
        }
    }

    /// What did not respond: the runtime, or its server for a server question.
    var subject: String {
        switch self {
        case .codexDaemon, .opencodeService: "\(backend.displayName) server"
        default: backend.displayName
        }
    }

    /// "Codex didn't respond (codex --version timed out)".
    var message: String { "\(subject) didn't respond (\(command) timed out)" }
}

/// The herdr-core binary detection found (ADR 0031): the first of
/// `herdr-core` and `hc`, in `PATH` then the Herdr app's directories, whose
/// `--version` printed `hc <digits>`.
struct CorePresence: Sendable, Equatable, Codable {
    /// The version after `hc ` ("0.1.14").
    var version: String
    /// The binary's absolute path on the Host; the connect and attach lines
    /// exec it, so a core in a directory the exec PATH lacks still runs.
    var path: String

    /// The oldest core Waycar drives: `file.*` and `status_ms` arrived in
    /// 0.1.10 (design C16). Calls beyond it are gated on `hello.methods`.
    static let minimumVersion = "0.1.10"

    init(version: String, path: String) {
        self.version = version
        self.path = path
    }

    /// This core is at or above `minimumVersion`. A version that does not
    /// parse as dotted numbers counts as below it: Waycar cannot vouch for
    /// what it cannot read.
    var meetsFloor: Bool {
        Self.meetsFloor(version)
    }

    static func meetsFloor(_ version: String) -> Bool {
        guard let found = components(version), let floor = components(minimumVersion) else {
            return false
        }
        for (a, b) in zip(found, floor) where a != b { return a > b }
        return true
    }

    /// `major.minor.patch` from the leading dotted digits; a pre-release
    /// suffix ("0.1.14-rc1") is ignored. Nil without three numbers.
    private static func components(_ version: String) -> [Int]? {
        guard let match = version.firstMatch(of: /^([0-9]+)\.([0-9]+)\.([0-9]+)/),
            let major = Int(match.1), let minor = Int(match.2), let patch = Int(match.3)
        else { return nil }
        return [major, minor, patch]
    }
}

/// The Codex CLI detection found, and its shared app-server if one runs
/// (`docs/design/codex-backend.md` X1, X3). Detection runs only
/// `codex --version` and `codex app-server daemon version`, which start
/// nothing; starting the server is the user's Start Codex server.
struct CodexPresence: Sendable, Equatable, Codable {
    /// The version after `codex-cli ` ("0.167.1").
    var version: String
    /// The binary's absolute path on the Host.
    var path: String
    /// The control socket `daemon version` reported for a running server;
    /// nil when it exited nonzero (no server).
    var socketPath: String?
    /// The running server's own version, which can differ from the CLI's.
    var appServerVersion: String?
    /// Expected rendezvous path even while stopped, from CODEX_HOME or HOME
    /// in the same detection exec. A plain socket open can notice an external
    /// start without spending another exec (or resolving HOME again).
    var probeSocketPath: String?

    init(
        version: String, path: String, socketPath: String? = nil,
        appServerVersion: String? = nil, probeSocketPath: String? = nil
    ) {
        self.version = version
        self.path = path
        self.socketPath = socketPath
        self.appServerVersion = appServerVersion
        self.probeSocketPath = probeSocketPath
    }

    static let minimumVersion = "0.167.0"

    /// Unreadable versions cannot vouch for the shared-daemon contract.
    var meetsFloor: Bool {
        guard let match = version.firstMatch(of: /^([0-9]+)\.([0-9]+)\.([0-9]+)(?:[-+].*)?$/),
            let major = Int(match.1), let minor = Int(match.2), let patch = Int(match.3)
        else { return false }
        let floor = Self.minimumVersion.split(separator: ".").compactMap { Int($0) }
        return floor.count == 3 && ![major, minor, patch].lexicographicallyPrecedes(floor)
    }

    /// A server answered `daemon version` with a socket.
    var isRunning: Bool { socketPath != nil }
}
