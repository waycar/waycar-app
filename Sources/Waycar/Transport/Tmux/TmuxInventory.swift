import Foundation

/// Pure: the three list commands, their output parsed into records, and the
/// records mapped onto herdr's `SessionSnapshot` (design §4.3).
///
/// Every record is `␞<id>␟<field>…` with free-text fields last: tmux passes
/// raw tabs and newlines in titles, paths and options through unescaped
/// (T9), so a record may span several reply lines and is reassembled by its
/// sentinel.
enum TmuxInventory {
    /// The separators of every tmux reply format Waycar parses: ␞ (U+241E)
    /// starts a record, ␟ (U+241F) separates fields. Printable on purpose: tmux
    /// 3.4 and 3.5 escape control bytes in command replies and printed
    /// output (0x1E arrives as the text `\036`), while valid UTF-8 arrives
    /// as is on every version. Text is cut at these scalars, never at
    /// Characters: a value starting with a combining mark would fuse with
    /// the separator before it into one grapheme.
    static let recordSeparator: Unicode.Scalar = "\u{241E}"
    static let fieldSeparator: Unicode.Scalar = "\u{241F}"

    /// `#{s/␞|␟//:name}`: the variable with both separators stripped from
    /// its value, so a directory name, title or option holding them can
    /// never split a record or start a forged one. An alternation, not a
    /// bracket expression, so it removes whole characters even where the
    /// regex matches bytes.
    static func field(_ name: String) -> String {
        "#{s/\(recordSeparator)|\(fieldSeparator)//:\(name)}"
    }

    /// `names` as ``field(_:)``s joined by the field separator.
    static func fields(_ names: [String]) -> String {
        names.map(field).joined(separator: String(fieldSeparator))
    }

    /// A pane's terminal id: `tmux:%N@<server>`. tmux hands pane ids out
    /// again after a server restart (a new server starts at `%0`), so the
    /// server's identity (``TmuxTransport/serverIdentity(startTime:pid:)``)
    /// makes the id unique per pane lifetime; the pane id stays `tmux:%N`.
    /// Bare `tmux:%N` while the server's identity is unknown.
    static func terminalID(pane rawPane: String, server: String) -> String {
        server.isEmpty ? TmuxID.app(rawPane) : TmuxID.app(rawPane) + "@" + server
    }

    /// `text` cut at each `separator` scalar, at most `maxSplits` times;
    /// empty pieces are kept.
    static func split(
        _ text: String, at separator: Unicode.Scalar, maxSplits: Int = .max
    ) -> [String] {
        text.unicodeScalars.split(
            separator: separator, maxSplits: maxSplits, omittingEmptySubsequences: false
        ).map { String(String.UnicodeScalarView($0)) }
    }

    static let sessionFields = [
        "session_id", "session_grouped", "session_attached",
        "session_name", "session_group", "session_path",
    ]
    static let windowFields = [
        "window_id", "session_id", "window_index", "window_active", "window_zoomed_flag",
        "window_name",
    ]
    static let paneFields = [
        "pane_id", "session_id", "window_id", "pane_index", "pane_active", "pane_dead",
        "alternate_on", "pane_pid", "pane_tty", "pane_width", "pane_height",
        "pane_current_command", "@waycar_status", "@waycar_agent", "@waycar_seq",
        "@pane_status", "@workmux_pane_status",
        "pane_current_path", "@waycar_session", "@waycar_transcript", "pane_title",
        "pane_start_command", "@waycar_launch",
    ]

    static var listSessionsCommand: String { "list-sessions -F " + format(sessionFields) }
    static var listWindowsCommand: String { "list-windows -a -F " + format(windowFields) }
    static var listPanesCommand: String { "list-panes -a -F " + format(paneFields) }

    /// All three, one control line; replies arrive as three blocks in order.
    static var listAllCommand: String {
        [listSessionsCommand, listWindowsCommand, listPanesCommand].joined(separator: " ; ")
    }

    /// `␞` and the ``fields(_:)``, each stripped of both separators.
    private static func format(_ fields: [String]) -> String {
        TmuxCommand.singleQuoted(String(recordSeparator) + Self.fields(fields))
    }

    // MARK: Parsing

    /// Splits one reply's lines into records of exactly `count` fields. Short
    /// records, and records whose last field holds a stray field separator
    /// (a misaligned record), are dropped.
    static func records(_ lines: [String], fieldCount count: Int) -> [[String]] {
        var chunks = split(lines.joined(separator: "\n"), at: recordSeparator)
        guard !chunks.isEmpty else { return [] }
        chunks.removeFirst()  // Text before the first sentinel.
        return chunks.enumerated().compactMap { offset, chunk in
            var body = chunk
            // The line break that ended this record belongs to the reply.
            if offset < chunks.count - 1, body.unicodeScalars.last == "\n" {
                body.unicodeScalars.removeLast()
            }
            let fields = split(body, at: fieldSeparator, maxSplits: count - 1)
            guard fields.count == count,
                fields.last?.unicodeScalars.contains(fieldSeparator) == false
            else { return nil }
            return fields
        }
    }

    /// tmux's id format: `prefix` and a decimal number (`$3`, `@12`, `%0`).
    static func isID(_ text: String, prefix: Character) -> Bool {
        guard text.first == prefix else { return false }
        let digits = text.dropFirst()
        return !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }

    static func parseSessions(_ lines: [String]) -> [TmuxSessionRecord] {
        records(lines, fieldCount: sessionFields.count).compactMap {
            guard isID($0[0], prefix: "$") else { return nil }
            return TmuxSessionRecord(
                id: $0[0], name: $0[3], group: $0[4], grouped: $0[1] == "1",
                attached: Int($0[2]) ?? 0, path: $0[5])
        }
    }

    static func parseWindows(_ lines: [String]) -> [TmuxWindowRecord] {
        records(lines, fieldCount: windowFields.count).compactMap {
            guard isID($0[0], prefix: "@"), isID($0[1], prefix: "$") else { return nil }
            return TmuxWindowRecord(
                id: $0[0], sessionID: $0[1], index: Int($0[2]) ?? 0, name: $0[5],
                active: $0[3] == "1", zoomed: $0[4] == "1")
        }
    }

    static func parsePanes(_ lines: [String]) -> [TmuxPaneRecord] {
        records(lines, fieldCount: paneFields.count).compactMap {
            guard isID($0[0], prefix: "%"), isID($0[1], prefix: "$"), isID($0[2], prefix: "@")
            else { return nil }
            return TmuxPaneRecord(
                id: $0[0], sessionID: $0[1], windowID: $0[2], index: Int($0[3]) ?? 0,
                active: $0[4] == "1", dead: $0[5] == "1", alternateOn: $0[6] == "1",
                pid: Int($0[7]), tty: $0[8], width: Int($0[9]) ?? 0, height: Int($0[10]) ?? 0,
                currentCommand: $0[11], waycarStatus: $0[12], waycarAgent: $0[13],
                waycarSeq: $0[14], sidebarStatus: $0[15], workmuxStatus: $0[16],
                currentPath: $0[17], waycarSession: $0[18], waycarTranscript: $0[19],
                title: $0[20], startCommand: $0[21], waycarLaunch: $0[22])
        }
    }

    // MARK: Visibility

    /// Waycar's own attach sessions (§4.4) never show as Workspaces.
    static let attachSessionPrefix = "waycar-"

    /// The sessions shown as Workspaces, in listing order: no `waycar-*`
    /// session, and one session per group, the one named like the group,
    /// else the lowest id.
    static func visibleSessions(_ sessions: [TmuxSessionRecord]) -> [TmuxSessionRecord] {
        let candidates = sessions.filter { !$0.name.hasPrefix(attachSessionPrefix) }
        var representative: [String: TmuxSessionRecord] = [:]
        for session in candidates where session.grouped {
            guard let current = representative[session.group] else {
                representative[session.group] = session
                continue
            }
            if preferred(session, over: current) { representative[session.group] = session }
        }
        return candidates.filter { !$0.grouped || representative[$0.group]?.id == $0.id }
    }

    private static func preferred(
        _ lhs: TmuxSessionRecord, over rhs: TmuxSessionRecord
    ) -> Bool {
        let lhsNamed = lhs.name == lhs.group
        let rhsNamed = rhs.name == rhs.group
        if lhsNamed != rhsNamed { return lhsNamed }
        return (TmuxID.number(lhs.id) ?? .max) < (TmuxID.number(rhs.id) ?? .max)
    }

    // MARK: Snapshot

    /// Builds herdr's snapshot from the three listings.
    /// - Parameters:
    ///   - kinds: Agent kinds the transport resolved from a pane's foreground
    ///     process (`AgentKindDetection.kind(commandLine:)`), keyed by raw
    ///     pane id; consulted only for panes that need it.
    ///   - version: the tmux version, reported as the snapshot's `version`.
    ///   - server: the server's identity, for terminal ids
    ///     (``terminalID(pane:server:)``).
    ///   - worktrees: each shown session's git checkout identity, keyed by raw
    ///     session id (``workspaceWorktrees(sessions:windows:panes:checkouts:)``).
    static func snapshot(
        sessions: [TmuxSessionRecord], windows: [TmuxWindowRecord], panes: [TmuxPaneRecord],
        kinds: [String: String], version: String, server: String = "",
        worktrees: [String: WorkspaceWorktreeInfo] = [:]
    ) -> SessionSnapshot {
        let shown = visibleSessions(sessions)
        let (windowByID, windowOrder) = shownWindows(windows, of: shown)
        let paneRecords = shownPanes(panes, windowByID: windowByID)

        var paneInfos: [PaneInfo] = []
        var agentInfos: [AgentInfo] = []
        var statusesByWindow: [String: [AgentStatus]] = [:]
        var paneCountByWindow: [String: Int] = [:]
        for pane in paneRecords {
            guard let window = windowByID[pane.windowID] else { continue }
            let workspaceID = TmuxID.app(window.sessionID)
            let tabID = TmuxID.app(window.id)
            let paneID = TmuxID.app(pane.id)
            let terminalID = Self.terminalID(pane: pane.id, server: server)
            let focused = pane.active && window.active
            let cwd = nonEmpty(pane.currentPath)
            let title = nonEmpty(pane.title)
            paneCountByWindow[window.id, default: 0] += 1

            guard let kind = TmuxAgentDetection.kind(for: pane, resolvedKind: kinds[pane.id])
            else {
                paneInfos.append(PaneInfo(
                    agentStatus: .unknown, focused: focused, paneID: paneID, revision: 0,
                    tabID: tabID, terminalID: terminalID, workspaceID: workspaceID,
                    cwd: cwd, foregroundCwd: cwd, terminalTitle: title))
                continue
            }
            let status = TmuxAgentDetection.status(for: pane)
            let session = agentSession(for: pane, kind: kind)
            statusesByWindow[window.id, default: []].append(status)
            paneInfos.append(PaneInfo(
                agentStatus: status, focused: focused, paneID: paneID, revision: 0,
                tabID: tabID, terminalID: terminalID, workspaceID: workspaceID,
                agent: kind, agentSession: session, cwd: cwd, foregroundCwd: cwd,
                terminalTitle: title))
            agentInfos.append(AgentInfo(
                agentStatus: status, focused: focused, paneID: paneID, revision: 0,
                tabID: tabID, terminalID: terminalID, workspaceID: workspaceID,
                agent: kind, agentSession: session, cwd: cwd, foregroundCwd: cwd,
                name: agentName(window: window, pane: pane),
                stateChangeSeq: Int(pane.waycarSeq), terminalTitle: title))
        }

        var tabInfos: [TabInfo] = []
        var tabsBySession: [String: [TmuxWindowRecord]] = [:]
        for id in windowOrder {
            guard let window = windowByID[id] else { continue }
            tabsBySession[window.sessionID, default: []].append(window)
            tabInfos.append(TabInfo(
                agentStatus: aggregate(statusesByWindow[id] ?? []), focused: window.active,
                label: window.name, number: window.index,
                paneCount: paneCountByWindow[id] ?? 0, tabID: TmuxID.app(id),
                workspaceID: TmuxID.app(window.sessionID)))
        }

        let workspaceInfos = shown.enumerated().map { offset, session in
            let tabs = tabsBySession[session.id] ?? []
            let active = tabs.first(where: \.active) ?? tabs.first
            return WorkspaceInfo(
                activeTabID: active.map { TmuxID.app($0.id) } ?? "",
                agentStatus: aggregate(tabs.flatMap { statusesByWindow[$0.id] ?? [] }),
                focused: false, label: session.name, number: offset + 1,
                paneCount: tabs.reduce(0) { $0 + (paneCountByWindow[$1.id] ?? 0) },
                tabCount: tabs.count, workspaceID: TmuxID.app(session.id),
                worktree: worktrees[session.id])
        }

        return SessionSnapshot(
            agents: agentInfos, layouts: [], panes: paneInfos, protocolVersion: 0,
            tabs: tabInfos, version: version, workspaces: workspaceInfos)
    }

    /// Windows: the listing row of a shown session, once per id (T14), and
    /// their order.
    static func shownWindows(
        _ windows: [TmuxWindowRecord], of shown: [TmuxSessionRecord]
    ) -> (byID: [String: TmuxWindowRecord], order: [String]) {
        let shownIDs = Set(shown.map(\.id))
        var windowByID: [String: TmuxWindowRecord] = [:]
        var windowOrder: [String] = []
        for window in windows where shownIDs.contains(window.sessionID) {
            guard windowByID[window.id] == nil else { continue }
            windowByID[window.id] = window
            windowOrder.append(window.id)
        }
        return (windowByID, windowOrder)
    }

    /// Panes: the listing row of their kept window's session, once per id.
    static func shownPanes(
        _ panes: [TmuxPaneRecord], windowByID: [String: TmuxWindowRecord]
    ) -> [TmuxPaneRecord] {
        var seenPanes = Set<String>()
        return panes.filter { pane in
            guard let window = windowByID[pane.windowID], pane.sessionID == window.sessionID
            else { return false }
            return seenPanes.insert(pane.id).inserted
        }
    }

    /// Shell Activity of the shown Shell panes ``snapshot`` lists, keyed by
    /// app pane id; a pane whose activity is unknown is absent.
    /// - Parameter foreground: `ps` resolutions per raw pane id.
    static func shellActivities(
        sessions: [TmuxSessionRecord], windows: [TmuxWindowRecord], panes: [TmuxPaneRecord],
        foreground: [String: TmuxForegroundKind]
    ) -> [String: ShellActivity] {
        let windowByID = shownWindows(windows, of: visibleSessions(sessions)).byID
        var activities: [String: ShellActivity] = [:]
        for pane in shownPanes(panes, windowByID: windowByID) {
            let resolved = foreground[pane.id]
            if let activity = TmuxAgentDetection.shellActivity(
                for: pane, resolvedKind: resolved?.kind, commandLine: resolved?.commandLine)
            {
                activities[TmuxID.app(pane.id)] = activity
            }
        }
        return activities
    }

    // MARK: Worktree metadata

    /// A session's directory, its Workspace cwd: `session_path`, else the
    /// cwd of its current window's active pane.
    static func directory(
        of session: TmuxSessionRecord, windows: [TmuxWindowRecord], panes: [TmuxPaneRecord]
    ) -> String? {
        if let path = nonEmpty(session.path) { return path }
        let window = windows.first { $0.sessionID == session.id && $0.active }
        let pane = panes.first {
            $0.sessionID == session.id && $0.windowID == window?.id && $0.active
        }
        return pane.flatMap { nonEmpty($0.currentPath) }
    }

    /// The shown sessions' worktree metadata, keyed by raw session id, for
    /// those whose directory resolved to a git checkout in `checkouts`.
    static func workspaceWorktrees(
        sessions: [TmuxSessionRecord], windows: [TmuxWindowRecord], panes: [TmuxPaneRecord],
        checkouts: [String: TmuxCheckout]
    ) -> [String: WorkspaceWorktreeInfo] {
        var worktrees: [String: WorkspaceWorktreeInfo] = [:]
        for session in visibleSessions(sessions) {
            guard let directory = directory(of: session, windows: windows, panes: panes),
                let checkout = checkouts[directory]
            else { continue }
            worktrees[session.id] = checkout.info
        }
        return worktrees
    }

    /// ``checkoutScript``'s separators: raw 0x1E/0x1F, since its output is
    /// `/bin/sh`'s, which tmux never escapes.
    static let checkoutMarker = "\u{1E}"
    static let checkoutSeparator: Character = "\u{1F}"

    /// One `/bin/sh` script resolving every directory argument at once: for
    /// each one in a git work tree, a `\u{1E}`-led line of the directory as
    /// given, its top level, the common git dir, its own git dir and the
    /// main worktree (`git worktree list`'s first entry), `\u{1F}`-separated
    /// and symlinks resolved, so they compare equal to the paths
    /// ``TmuxTransport`` lists worktrees with. Directories outside a work
    /// tree (a bare repository or `.git` included) print nothing. Every
    /// `cd` target is checked non-empty first: `cd ""` stays put.
    static let checkoutScript = "unset CDPATH; for d in \"$@\"; do "
        + "r=$(git -C \"$d\" rev-parse --show-toplevel) && [ -n \"$r\" ] "
        + "&& t=$(cd \"$r\" && pwd -P) "
        + "&& c=$(git -C \"$d\" rev-parse --git-common-dir) && [ -n \"$c\" ] "
        + "&& c=$(cd \"$d\" && cd \"$c\" && pwd -P) "
        + "&& g=$(git -C \"$d\" rev-parse --absolute-git-dir) && [ -n \"$g\" ] "
        + "&& g=$(cd \"$g\" && pwd -P) || continue; "
        + "m=$(git -C \"$d\" worktree list --porcelain | sed -n \"1s/^worktree //p\"); "
        + "[ -z \"$m\" ] || m=$(cd \"$m\" && pwd -P); "
        + "printf \"\\036%s\\037%s\\037%s\\037%s\\037%s\\n\" \"$d\" \"$t\" \"$c\" \"$g\" \"$m\"; "
        + "done 2>/dev/null; exit 0"

    /// ``checkoutScript``'s answer, keyed by the directory as given.
    static func parseCheckouts(_ output: String) -> [String: TmuxCheckout] {
        var checkouts: [String: TmuxCheckout] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix(checkoutMarker) else { continue }
            let fields = line.dropFirst().split(
                separator: checkoutSeparator, omittingEmptySubsequences: false
            ).map(String.init)
            guard fields.count == 5, fields[1].hasPrefix("/"), fields[2].hasPrefix("/"),
                fields[3].hasPrefix("/")
            else { continue }
            checkouts[fields[0]] = TmuxCheckout(
                path: fields[1], commonDir: fields[2], gitDir: fields[3],
                mainWorktree: nonEmpty(fields[4]))
        }
        return checkouts
    }

    /// The window name, unless it is tmux's automatic-rename artifact (the
    /// foreground command, e.g. claude's `2.1.286`); nil then, so the Agent
    /// shows its kind.
    static func agentName(window: TmuxWindowRecord, pane: TmuxPaneRecord) -> String? {
        let name = window.name
        guard !name.isEmpty, name != pane.currentCommand else { return nil }
        return name
    }

    /// The Agent's own session from `@waycar_session` (an absolute path is a
    /// session file), else the decoded `@waycar_transcript` path.
    static func agentSession(for pane: TmuxPaneRecord, kind: String) -> AgentSessionInfo? {
        if let session = nonEmpty(pane.waycarSession) {
            return AgentSessionInfo(
                agent: kind, kind: session.hasPrefix("/") ? .path : .id,
                source: "tmux", value: session)
        }
        let transcript = pane.waycarTranscript.removingPercentEncoding ?? pane.waycarTranscript
        guard let path = nonEmpty(transcript) else { return nil }
        return AgentSessionInfo(agent: kind, kind: .path, source: "tmux", value: path)
    }

    /// The most urgent status: blocked, working, done, idle, unknown.
    static func aggregate(_ statuses: [AgentStatus]) -> AgentStatus {
        let order: [AgentStatus] = [.blocked, .working, .done, .idle]
        return order.first(where: statuses.contains) ?? .unknown
    }

    private static func nonEmpty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }
}

/// One directory's git checkout, as ``TmuxInventory/checkoutScript`` resolved
/// it (symlinks resolved throughout).
struct TmuxCheckout: Sendable, Equatable {
    /// The checkout's top level: herdr's `checkout_path`.
    let path: String
    /// The repository's common git dir, shared by all its worktrees: herdr's
    /// `repo_key`.
    let commonDir: String
    /// This checkout's own git dir; a linked worktree's lies under
    /// `<commonDir>/worktrees/`.
    let gitDir: String
    /// The main worktree, `git worktree list`'s first entry: herdr's
    /// `repo_root`. Nil when git did not list it.
    let mainWorktree: String?

    var isLinked: Bool { gitDir != commonDir }

    /// The main worktree, else the parent of a `.git` common dir, else this
    /// checkout.
    var repoRoot: String {
        if let mainWorktree { return mainWorktree }
        if commonDir.hasSuffix("/.git") { return String(commonDir.dropLast("/.git".count)) }
        return path
    }

    var repoName: String {
        repoRoot.split(separator: "/").last.map(String.init) ?? repoRoot
    }

    var info: WorkspaceWorktreeInfo {
        WorkspaceWorktreeInfo(
            checkoutPath: path, isLinkedWorktree: isLinked, repoKey: commonDir,
            repoName: repoName, repoRoot: repoRoot)
    }
}
