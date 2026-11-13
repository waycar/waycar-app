import Foundation

/// Pure: herdr-core's flat terminal list mapped onto herdr's
/// `SessionSnapshot` (design §6). The topology is synthetic (core has no
/// Workspaces or Tabs): a Workspace per `herdr.space` label or start folder,
/// a Tab per `herdr.tab` label or terminal, a Pane (and an Agent, when it is
/// one) per terminal.
///
/// Everything a Pane, Agent, Tab or Workspace id needs comes from the
/// terminal record alone, so ``paneInfo(for:core:overlay:)`` and
/// ``agentInfo(for:core:overlay:)`` give the same rows for one terminal as
/// ``snapshot(terminals:core:overlay:home:)`` does for the whole list.
enum CoreSnapshotBuilder {
    /// The Herdr app's terminal labels (C15). An empty value means parked.
    static let spaceLabelKey = "herdr.space"
    static let tabLabelKey = "herdr.tab"

    /// The labels Waycar's Host Tools write on a terminal (plugin README,
    /// "Host Tools (herdr-core)"): the agent's own session id (or session
    /// file path) and its transcript path, as the tmux options of the same
    /// names. Chat Mode and Closed Session resume read them.
    static let sessionLabelKey = "waycar.session"
    static let transcriptLabelKey = "waycar.transcript"

    /// The Workspace label when nothing about the terminal's folder is known.
    static let unknownWorkspaceLabel = "Terminals"

    /// Separates a machine name from the folder name in a Workspace label.
    static let machineSeparator = " · "

    // MARK: Snapshot

    /// The snapshot of `terminals`, finished ones left out.
    /// - Parameters:
    ///   - core: `hello`'s answer; nil before the first one. It supplies the
    ///     snapshot's `version` and `protocol` and the Terminal ids' prefix.
    ///   - overlay: the Done terminals the user has already opened.
    ///   - home: the Host's home folder, when known; a Workspace whose folder
    ///     is exactly it is labelled `~`.
    static func snapshot(
        terminals: [CoreTerminal], core: CoreHello?, overlay: CoreDoneOverlayMachine,
        home: String? = nil, appLayout: CoreAppLayout? = nil
    ) -> SessionSnapshot {
        var paneInfos: [PaneInfo] = []
        var agentInfos: [AgentInfo] = []
        var tabInfos: [TabInfo] = []
        var workspaceInfos: [WorkspaceInfo] = []

        let workspaces = grouped(ordered(terminals), by: workspaceKey(of:))
        for (workspaceOffset, workspace) in workspaces.enumerated() {
            var workspaceStatuses: [AgentStatus] = []
            var workspacePaneCount = 0
            var firstTabID = ""
            let tabs = grouped(workspace.terminals, by: tabKey(of:))
            for (tabOffset, tab) in tabs.enumerated() {
                var tabStatuses: [AgentStatus] = []
                for terminal in tab.terminals {
                    guard let pane = paneInfo(for: terminal, core: core, overlay: overlay)
                    else { continue }
                    paneInfos.append(pane)
                    if pane.agent != nil { tabStatuses.append(pane.agentStatus) }
                    if let agent = agentInfo(for: terminal, core: core, overlay: overlay) {
                        agentInfos.append(agent)
                    }
                }
                let tabID = CoreID.tab(key: tab.key)
                if tabOffset == 0 { firstTabID = tabID }
                tabInfos.append(TabInfo(
                    agentStatus: TmuxInventory.aggregate(tabStatuses), focused: false,
                    label: tabLabel(of: tab.terminals[0], appLayout: appLayout), number: tabOffset + 1,
                    paneCount: tab.terminals.count, tabID: tabID,
                    workspaceID: CoreID.workspace(key: workspace.key)))
                workspaceStatuses.append(contentsOf: tabStatuses)
                workspacePaneCount += tab.terminals.count
            }
            workspaceInfos.append(WorkspaceInfo(
                activeTabID: firstTabID, agentStatus: TmuxInventory.aggregate(workspaceStatuses),
                focused: false, label: workspaceLabel(of: workspace.terminals[0], home: home, appLayout: appLayout),
                number: workspaceOffset + 1, paneCount: workspacePaneCount,
                tabCount: tabs.count, workspaceID: CoreID.workspace(key: workspace.key)))
        }

        return SessionSnapshot(
            agents: agentInfos, layouts: [], panes: paneInfos,
            protocolVersion: core?.generation ?? 0, tabs: tabInfos,
            version: core?.version ?? "", workspaces: workspaceInfos)
    }

    /// The Pane row of one terminal (an Agent's carries its kind and
    /// status, a Shell's has no kind and an unknown status); nil for a
    /// finished terminal, which is not a row.
    static func paneInfo(
        for terminal: CoreTerminal, core: CoreHello?, overlay: CoreDoneOverlayMachine
    ) -> PaneInfo? {
        guard !terminal.isFinished else { return nil }
        let ids = identity(of: terminal, core: core)
        let cwd = currentDirectory(of: terminal)
        let title = nonEmpty(terminal.title)
        guard isAgent(terminal) else {
            return PaneInfo(
                agentStatus: .unknown, focused: false, paneID: ids.pane, revision: 0,
                tabID: ids.tab, terminalID: ids.terminal, workspaceID: ids.workspace,
                cwd: cwd, foregroundCwd: cwd, terminalTitle: title)
        }
        return PaneInfo(
            agentStatus: agentStatus(of: terminal, overlay: overlay), focused: false,
            paneID: ids.pane, revision: 0, tabID: ids.tab, terminalID: ids.terminal,
            workspaceID: ids.workspace, agent: agentKind(of: terminal), cwd: cwd,
            foregroundCwd: cwd, terminalTitle: title)
    }

    /// The Pane row `snapshot` already holds for `terminal`: nothing is
    /// recomputed, so it is the very value ``snapshot(terminals:core:overlay:home:)``
    /// built; nil when the terminal is not a row there (finished, or not in
    /// the table the snapshot came from). `overlay` is what that snapshot
    /// was built with: the Done overlay is already applied to the row, so it
    /// is not consulted again.
    static func paneInfo(
        for terminal: CoreTerminal, in snapshot: SessionSnapshot, overlay: CoreDoneOverlayMachine
    ) -> PaneInfo? {
        let id = CoreID.pane(terminal.address)
        return snapshot.panes.first { $0.paneID == id }
    }

    /// The Agent row of one terminal; nil for a Shell and for a finished
    /// terminal.
    static func agentInfo(
        for terminal: CoreTerminal, core: CoreHello?, overlay: CoreDoneOverlayMachine
    ) -> AgentInfo? {
        guard !terminal.isFinished, isAgent(terminal) else { return nil }
        let ids = identity(of: terminal, core: core)
        let cwd = currentDirectory(of: terminal)
        let seq = terminal.statusMs.flatMap { Int(exactly: $0) }
        return AgentInfo(
            agentStatus: agentStatus(of: terminal, overlay: overlay), focused: false,
            paneID: ids.pane, revision: 0, tabID: ids.tab, terminalID: ids.terminal,
            workspaceID: ids.workspace, agent: agentKind(of: terminal),
            agentSession: agentSession(of: terminal), cwd: cwd,
            foregroundCwd: cwd, interactiveReady: true, launchPending: false,
            name: displayName(of: terminal), stateChangeSeq: seq,
            terminalTitle: nonEmpty(terminal.title))
    }

    /// The Agent's own session from `waycar.session` (an absolute path is a
    /// session file), else the `waycar.transcript` path: the labels the Host
    /// Tools' hooks keep, as `TmuxInventory.agentSession` reads the tmux
    /// options. Nil until a hook wrote one.
    static func agentSession(of terminal: CoreTerminal) -> AgentSessionInfo? {
        let kind = agentKind(of: terminal)
        if let session = label(terminal, sessionLabelKey) {
            return AgentSessionInfo(
                agent: kind, kind: session.hasPrefix("/") ? .path : .id,
                source: "core", value: session)
        }
        guard let path = label(terminal, transcriptLabelKey) else { return nil }
        return AgentSessionInfo(agent: kind, kind: .path, source: "core", value: path)
    }

    // MARK: Agents, kinds, status

    /// A terminal is an Agent when its program has reported through OSC 7501
    /// or its kind is recognized; otherwise it is a Shell row.
    static func isAgent(_ terminal: CoreTerminal) -> Bool {
        terminal.reported || kind(of: terminal) != nil
    }

    /// The recognized ``SupportedAgentKind`` raw value of a terminal, else
    /// nil. First match wins:
    /// 1. the report's `app` (``kind(forApp:)``);
    /// 2. the foreground command line, `foreground.argv` joined by spaces
    ///    (Claude renames its process title to its version number, so the
    ///    name alone is not enough, and an interpreter's script follows it);
    /// 3. the command line the terminal started with, for a terminal whose
    ///    foreground is absent or unrecognized.
    static func kind(of terminal: CoreTerminal) -> String? {
        if let app = terminal.status?.app, let kind = kind(forApp: app) { return kind }
        if let foreground = terminal.foreground,
            let kind = AgentKindDetection.kind(
                commandLine: foreground.argv.joined(separator: " "))
        {
            return kind
        }
        return AgentKindDetection.kind(commandLine: terminal.argv.joined(separator: " "))
    }

    /// Names a program reports for itself that are not a kind's raw value or
    /// executable, normalized (lowercased, spaces and underscores as `-`).
    private static let appAliases: [String: String] = [
        "claude-code": SupportedAgentKind.claude.rawValue,
        "claudecode": SupportedAgentKind.claude.rawValue,
        "codex-cli": SupportedAgentKind.codex.rawValue,
        "gemini-cli": SupportedAgentKind.gemini.rawValue,
        "cursor-cli": SupportedAgentKind.cursor.rawValue,
        "devin-cli": SupportedAgentKind.devin.rawValue,
        "antigravity": SupportedAgentKind.antigravity.rawValue,
        "mastra-code": SupportedAgentKind.mastracode.rawValue,
        "github-copilot": SupportedAgentKind.copilot.rawValue,
        "github-copilot-cli": SupportedAgentKind.copilot.rawValue,
        "copilot-cli": SupportedAgentKind.copilot.rawValue,
        "kimi-cli": SupportedAgentKind.kimi.rawValue,
        "hermes-agent": SupportedAgentKind.hermes.rawValue,
        "kilo-code": SupportedAgentKind.kilo.rawValue,
        "kilocode": SupportedAgentKind.kilo.rawValue,
        "qoder": SupportedAgentKind.qodercli.rawValue,
        "qwen-code": SupportedAgentKind.qwen.rawValue,
    ]

    /// The kind a report's `app` names: a kind's raw value or executable
    /// (case-insensitive), else one of ``appAliases``; nil for any other
    /// string, which stays the Agent's display name (``agentKind(of:)``).
    static func kind(forApp app: String) -> String? {
        let normalized = app.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
        guard !normalized.isEmpty else { return nil }
        if let kind = SupportedAgentKind(rawValue: normalized) { return kind.rawValue }
        if let kind = AgentKindDetection.knownKind(executable: normalized) { return kind }
        return appAliases[normalized]
    }

    /// `AgentInfo.agent` / `PaneInfo.agent` of an Agent: the recognized kind,
    /// else the report's own `app` lowercased (it is the display name, and no
    /// behavior keys off it), else `unknown`.
    static func agentKind(of terminal: CoreTerminal) -> String {
        if let kind = kind(of: terminal) { return kind }
        let app = terminal.status?.app?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let app, !app.isEmpty { return app }
        return Agent.unidentifiedKind
    }

    /// The Agent Status core reports, before the Done overlay: `idle`,
    /// `working`, `done` and `blocked` as they are, `error` as blocked, and
    /// unknown for no status, a program that never reported, or any other
    /// word.
    static func rawStatus(of terminal: CoreTerminal) -> AgentStatus {
        guard terminal.reported, let state = terminal.status?.state else { return .unknown }
        switch state {
        case "idle": return .idle
        case "working": return .working
        case "done": return .done
        case "blocked", "error": return .blocked
        default: return .unknown
        }
    }

    /// The status the Console shows: ``rawStatus(of:)`` with a Done the user
    /// has opened presented as Idle.
    static func agentStatus(of terminal: CoreTerminal, overlay: CoreDoneOverlayMachine) -> AgentStatus {
        overlay.presented(rawStatus(of: terminal), for: terminal)
    }

    // MARK: Shell Activity

    /// Shell Activity of the live Shell rows, keyed by Pane id (`hc:<address>`):
    /// running a command when `foreground.pid` is not the terminal's own
    /// `pid`, idle when it is. A terminal with no foreground, no pid, or a
    /// command line that sanitizes to nothing is absent (unknown).
    static func shellActivities(terminals: [CoreTerminal]) -> [String: ShellActivity] {
        var activities: [String: ShellActivity] = [:]
        for terminal in terminals where !terminal.isFinished && !isAgent(terminal) {
            guard let foreground = terminal.foreground, let foregroundPid = foreground.pid,
                let pid = terminal.pid
            else { continue }
            if foregroundPid == pid {
                activities[CoreID.pane(terminal.address)] = ShellActivity.idle
            } else if let activity = ShellActivity.runningCommand(
                foreground.argv.joined(separator: " "))
                ?? ShellActivity.runningCommand(foreground.name ?? "")
            {
                activities[CoreID.pane(terminal.address)] = activity
            }
        }
        return activities
    }

    // MARK: Topology

    /// The first 8 characters of the core's id, the Terminal ids' prefix;
    /// `core` while the id is empty or unknown.
    static func corePrefix(of core: CoreHello?) -> String {
        guard let id = core?.coreID, !id.isEmpty else { return "core" }
        return String(id.prefix(8))
    }

    /// The Workspace key: the `herdr.space` label when it is non-empty, else
    /// the start folder; a remote terminal's key starts with its machine
    /// (`box/`) so two machines' same-named spaces and folders stay apart.
    static func workspaceKey(of terminal: CoreTerminal) -> String {
        let base = label(terminal, spaceLabelKey) ?? normalizedPath(terminal.cwd)
        guard let owner = machine(of: terminal.address) else { return base }
        return owner + "/" + base
    }

    /// The terminal's core name, else the name Waycar launched it with
    /// (`CoreLaunch.nameLabel`); nil when it has neither.
    static func displayName(of terminal: CoreTerminal) -> String? {
        nonEmpty(terminal.name) ?? label(terminal, CoreLaunch.nameLabel)
    }

    /// The Tab key: within its Workspace, the `herdr.tab` label when it is
    /// non-empty, so the terminals sharing it are one Tab's Panes; else the
    /// terminal's own address, one Tab per terminal. A labelled key always
    /// holds `#`, which no address does.
    static func tabKey(of terminal: CoreTerminal) -> String {
        guard let tab = label(terminal, tabLabelKey) else { return terminal.address }
        return workspaceKey(of: terminal) + "#" + tab
    }

    /// The desktop app's tab name when its labels resolve, else the first
    /// terminal's name, title or program name.
    static func tabLabel(of terminal: CoreTerminal, appLayout: CoreAppLayout? = nil) -> String {
        if let space = appSpace(of: terminal, appLayout: appLayout),
            let tabID = label(terminal, tabLabelKey),
            let name = line(space.tabs.first { $0.id == tabID }?.name)
        { return name }
        if let name = line(displayName(of: terminal)) { return name }
        if let title = line(terminal.title) { return title }
        if let program = line(terminal.foreground?.name) { return program }
        if let program = terminal.argv.first.flatMap({ line(basename($0)) }) { return program }
        return "Terminal"
    }

    /// Resolves only label-driven membership, never the document's root tree.
    private static func appSpace(
        of terminal: CoreTerminal, appLayout: CoreAppLayout?
    ) -> CoreAppLayout.Space? {
        guard let id = label(terminal, spaceLabelKey) else { return nil }
        return appLayout?.spaces.first { $0.id == id }
    }

    /// The desktop app's space name, else the first terminal's folder name;
    /// remote terminals keep their `<machine> · ` prefix.
    static func workspaceLabel(
        of terminal: CoreTerminal, home: String? = nil, appLayout: CoreAppLayout? = nil
    ) -> String {
        let folder = nonEmpty(terminal.cwd) ?? nonEmpty(terminal.foreground?.cwd)
        let name = line(appSpace(of: terminal, appLayout: appLayout)?.name)
            ?? folderName(folder, home: home)
        guard let owner = machine(of: terminal.address) else { return name }
        return owner + machineSeparator + name
    }

    /// A folder's display name: its last path component, `/` for the root,
    /// `~` for `~` and for the Host's home folder, `Terminals` when nothing
    /// is known.
    static func folderName(_ folder: String?, home: String?) -> String {
        guard let folder, !folder.isEmpty else { return unknownWorkspaceLabel }
        let path = normalizedPath(folder)
        if path == "~" { return "~" }
        if let home, !home.isEmpty, path == normalizedPath(home) { return "~" }
        if path == "/" { return "/" }
        return line(basename(path)) ?? unknownWorkspaceLabel
    }

    /// The machine a remote address belongs to (`box` of `box/t3`); nil for
    /// the core's own terminals. Addresses are otherwise opaque.
    static func machine(of address: String) -> String? {
        guard let slash = address.lastIndex(of: "/") else { return nil }
        let machine = String(address[..<slash])
        return machine.isEmpty ? nil : machine
    }

    /// The live terminals in address order: the core's own first, in the
    /// order core numbers them (shorter ids are older: `t9` before `t10`),
    /// then each machine's, machines in order of first appearance. Core hands
    /// out ids in increasing order and never reuses them, and each id's
    /// characters are ranked in core's own counting alphabet, so this is
    /// creation order whatever order the table lists them in. Equal addresses
    /// keep their input order.
    static func ordered(_ terminals: [CoreTerminal]) -> [CoreTerminal] {
        var machineRank: [String: Int] = [:]
        struct Entry {
            var terminal: CoreTerminal
            var machine: Int
            var local: [Int]
            var offset: Int
        }
        var entries: [Entry] = []
        for terminal in terminals where !terminal.isFinished {
            let owner = machine(of: terminal.address)
            let rank: Int
            if let owner {
                if let known = machineRank[owner] {
                    rank = known
                } else {
                    rank = machineRank.count + 1
                    machineRank[owner] = rank
                }
            } else {
                rank = 0
            }
            let local = terminal.address.split(
                separator: "/", omittingEmptySubsequences: false
            ).last.map(String.init) ?? terminal.address
            entries.append(Entry(
                terminal: terminal, machine: rank, local: local.map(symbolRank),
                offset: entries.count))
        }
        return entries.sorted { lhs, rhs in
            if lhs.machine != rhs.machine { return lhs.machine < rhs.machine }
            if lhs.local.count != rhs.local.count { return lhs.local.count < rhs.local.count }
            if lhs.local != rhs.local { return lhs.local.lexicographicallyPrecedes(rhs.local) }
            return lhs.offset < rhs.offset
        }.map(\.terminal)
    }

    /// Core's address counting alphabet in counting order (no vowels, no `l`).
    private static let addressAlphabet: [Character: Int] = {
        var ranks: [Character: Int] = [:]
        for (rank, symbol) in "0123456789bcdfghjkmnpqrstvwxyz".enumerated() {
            ranks[symbol] = rank
        }
        return ranks
    }()

    /// A character outside the alphabet (an address core did not number)
    /// sorts after every counting symbol, by its scalar.
    private static func symbolRank(_ symbol: Character) -> Int {
        addressAlphabet[symbol]
            ?? 100 + Int(symbol.unicodeScalars.first?.value ?? 0)
    }

    // MARK: Helpers

    private static func identity(
        of terminal: CoreTerminal, core: CoreHello?
    ) -> (workspace: String, tab: String, pane: String, terminal: String) {
        (
            workspace: CoreID.workspace(key: workspaceKey(of: terminal)),
            tab: CoreID.tab(key: tabKey(of: terminal)),
            pane: CoreID.pane(terminal.address),
            terminal: CoreID.terminal(corePrefix: corePrefix(of: core), address: terminal.address)
        )
    }

    /// Items in order of their first key's appearance, each key's items in
    /// input order.
    private static func grouped(
        _ terminals: [CoreTerminal], by key: (CoreTerminal) -> String
    ) -> [(key: String, terminals: [CoreTerminal])] {
        var groups: [(key: String, terminals: [CoreTerminal])] = []
        var index: [String: Int] = [:]
        for terminal in terminals {
            let id = key(terminal)
            if let position = index[id] {
                groups[position].terminals.append(terminal)
            } else {
                index[id] = groups.count
                groups.append((key: id, terminals: [terminal]))
            }
        }
        return groups
    }

    /// The terminal's current folder: the foreground's, else the start
    /// folder.
    private static func currentDirectory(of terminal: CoreTerminal) -> String? {
        nonEmpty(terminal.foreground?.cwd) ?? nonEmpty(terminal.cwd)
    }

    /// A label's value, trimmed; nil when absent or blank (parked).
    private static func label(_ terminal: CoreTerminal, _ key: String) -> String? {
        guard let value = terminal.labels[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else { return nil }
        return value
    }

    /// `path` without trailing slashes (`/` stays).
    private static func normalizedPath(_ path: String) -> String {
        var trimmed = Substring(path)
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        return String(trimmed)
    }

    private static func basename(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// Host-supplied text as one display line; nil when nothing is left.
    private static func line(_ raw: String?) -> String? {
        guard let raw else { return nil }
        return HostText.normalizedLine(raw, limit: 80)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
