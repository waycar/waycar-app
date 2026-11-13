import Foundation

/// The last inventory a snapshot listed, raw ids throughout.
struct TmuxRecords: Sendable, Equatable {
    var sessions: [TmuxSessionRecord] = []
    var windows: [TmuxWindowRecord] = []
    var panes: [TmuxPaneRecord] = []
    /// Git checkouts resolved per session directory, kept across snapshots
    /// while a shown session still has that directory.
    var checkouts: [String: TmuxCheckoutEntry] = [:]

    /// The pane's listing row in a shown session (a pane in a grouped
    /// session is listed once per session), else any row.
    func pane(_ rawID: String) -> TmuxPaneRecord? {
        let shown = Set(TmuxInventory.visibleSessions(sessions).map(\.id))
        return panes.first { $0.id == rawID && shown.contains($0.sessionID) }
            ?? panes.first { $0.id == rawID }
    }

    var sessionNames: Set<String> { Set(sessions.map(\.name)) }

    /// The session's directory (``TmuxInventory/directory(of:windows:panes:)``).
    func directory(of session: TmuxSessionRecord) -> String? {
        TmuxInventory.directory(of: session, windows: windows, panes: panes)
    }

    /// The git checkout the session's directory resolved to; nil when it is
    /// not in a work tree or was not resolved.
    func checkout(of session: TmuxSessionRecord) -> TmuxCheckout? {
        directory(of: session).flatMap { checkouts[$0]?.checkout }
    }
}

/// One directory's checkout resolution; `checkout` is nil outside a work tree.
struct TmuxCheckoutEntry: Sendable, Equatable {
    let checkout: TmuxCheckout?
    let resolvedAt: ContinuousClock.Instant
}

/// One `ps` resolution, valid while the pane runs the same process and
/// foreground command.
struct TmuxForegroundKind: Sendable, Equatable {
    let pid: Int?
    let currentCommand: String
    let kind: String?
    /// The foreground process group leader's `args`; may hold secrets, so
    /// it is only ever shown on the Shell's card, never logged.
    let commandLine: String?
}

extension TmuxTransport {
    func listAgents() async throws -> [Agent] {
        try await sessionSnapshot().agents.map(Agent.init)
    }

    /// The whole server in one control line (three list commands), with the
    /// foreground kinds of panes running an unrecognised command resolved in
    /// one `ps` exec. Idle: `tmux ls` again, and an empty snapshot while the
    /// server still has no sessions. A line an anchor's `%exit` lost goes
    /// out again (``runLine(_:recheckIdle:)``). Each refresh answers its
    /// caller with what it listed, but publishes it (records, launch-gate
    /// pruning, Shell Activity, the last snapshot) only when no refresh
    /// that started after it has published already
    /// (``TmuxInventoryPublicationMachine``).
    func sessionSnapshot() async throws -> SessionSnapshot {
        let gatesAtStart = launchGates.state
        var refresh: UInt64 = 0
        for case .list(let token) in inventoryPublication.handle(.refreshRequested) {
            refresh = token
        }
        guard
            let replies = try await runLine([
                TmuxInventory.listSessionsCommand, TmuxInventory.listWindowsCommand,
                TmuxInventory.listPanesCommand,
            ])
        else {
            let empty = Self.emptySnapshot(version: version)
            guard publishes(refresh) else { return empty }
            records = TmuxRecords()
            lastShellActivities = [:]
            lastSnapshot = empty
            return empty
        }
        var listed = TmuxRecords(
            sessions: TmuxInventory.parseSessions(replies[0].lines),
            windows: TmuxInventory.parseWindows(replies[1].lines),
            panes: TmuxInventory.parsePanes(replies[2].lines))
        // A shell in front ends the foreground process: its next command
        // (`apt update` then `apt upgrade`) must be resolved afresh.
        foregroundCache = foregroundCache.filter { id, _ in
            !listed.panes.contains { $0.id == id && ShellCommand.isShell($0.currentCommand) }
        }
        // Reuse the same batched ps read for Codex's and OpenCode's
        // session links.
        let foreground = await resolveForeground(listed.panes.filter {
            TmuxAgentDetection.needsForegroundResolution($0)
                || TmuxAgentDetection.needsServerSessionLinkFacts($0, resolvedKind: nil)
        })
        let kinds = foreground.compactMapValues(\.kind)
        listed.checkouts = await resolveCheckouts(for: listed)
        let paneIDs = Set(listed.panes.map(\.id))
        foregroundCache = foregroundCache.filter { paneIDs.contains($0.key) }
        // A refresh that started later and published meanwhile listed more
        // recently: this one only answers its caller.
        let publishing = publishes(refresh)
        if publishing {
            records = listed
            // Enrichment may have let a launch finish after these panes were
            // listed. Prune only the launch this snapshot began with.
            _ = launchGates.handle(.listed(panes: paneIDs, gatesAtStart: gatesAtStart))
        }
        let snapshot = TmuxInventory.snapshot(
            sessions: listed.sessions, windows: listed.windows,
            panes: screenOverlaid(listed.panes, kinds: kinds),
            kinds: kinds, version: version, server: serverIdentity,
            worktrees: TmuxInventory.workspaceWorktrees(
                sessions: listed.sessions, windows: listed.windows, panes: listed.panes,
                checkouts: listed.checkouts.compactMapValues(\.checkout)))
        guard publishing else { return snapshot }
        lastShellActivities = TmuxInventory.shellActivities(
            sessions: listed.sessions, windows: listed.windows, panes: listed.panes,
            foreground: foreground)
        lastSnapshot = snapshot
        return snapshot
    }

    /// Whether refresh `token`, listed and enriched, publishes.
    private func publishes(_ token: UInt64) -> Bool {
        inventoryPublication.handle(.listed(token: token)).contains(.publish(token: token))
    }

    func serverSessionLinkFacts() async -> ServerSessionLinkFacts {
        var lines: [String: String] = [:]
        for pane in records.panes {
            guard let cached = foregroundCache[pane.id], cached.pid == pane.pid,
                cached.currentCommand == pane.currentCommand, let line = cached.commandLine
            else { continue }
            lines[TmuxID.app(pane.id)] = line
        }
        return ServerSessionLinkFacts(commandLines: lines)
    }

    /// The Shell Activities the last snapshot derived; no tmux traffic.
    func shellActivities(paneIDs: [String]) async throws -> [String: ShellActivity] {
        var activities: [String: ShellActivity] = [:]
        for id in paneIDs {
            if let activity = lastShellActivities[id] { activities[id] = activity }
        }
        return activities
    }

    static func emptySnapshot(version: String) -> SessionSnapshot {
        SessionSnapshot(
            agents: [], layouts: [], panes: [], protocolVersion: 0, tabs: [], version: version,
            workspaces: [])
    }

    // MARK: Worktree metadata

    /// How long a directory's resolution is trusted: a directory can become
    /// a checkout (`git init`, a clone) or stop being one.
    static let checkoutLifetime: Duration = .seconds(60)

    /// The checkouts of the shown sessions' directories: cached ones still
    /// fresh, the rest from one git exec over all of them. A failed exec
    /// resolves nothing (those Workspaces carry no worktree metadata until
    /// the next snapshot) and caches nothing. A directory the login shell
    /// cannot take safely (``TmuxTransport/isLoginShellSafe(_:)``) is never
    /// looked up and carries no worktree metadata.
    func resolveCheckouts(for listed: TmuxRecords) async -> [String: TmuxCheckoutEntry] {
        let directories = Set(
            TmuxInventory.visibleSessions(listed.sessions).compactMap(listed.directory(of:))
                .filter(Self.isLoginShellSafe))
        let now = ContinuousClock.now
        var entries = records.checkouts.filter {
            directories.contains($0.key)
                && $0.value.resolvedAt.duration(to: now) < Self.checkoutLifetime
        }
        let missing = directories.filter { entries[$0] == nil }.sorted()
        guard !missing.isEmpty, let resolved = try? await lookUpCheckouts(missing) else {
            return entries
        }
        for directory in missing {
            entries[directory] = TmuxCheckoutEntry(checkout: resolved[directory], resolvedAt: now)
        }
        return entries
    }

    /// ``TmuxInventory/checkoutScript`` over `directories`, keyed by
    /// directory; a directory outside a work tree is absent.
    func lookUpCheckouts(_ directories: [String]) async throws -> [String: TmuxCheckout] {
        let result = try await session.runExec(
            Self.shellCommand(TmuxInventory.checkoutScript, arguments: directories, cLocale: true),
            input: Data(), timeout: nil)
        guard result.exitStatus == 0 else {
            throw TransportError.channelFailed(
                detail: "the checkout lookup exited \(result.exitStatus): "
                    + Self.preview(Self.text(result.stderr)))
        }
        return TmuxInventory.parseCheckouts(Self.text(result.stdout))
    }

    // MARK: Foreground resolution

    /// Foreground resolutions for `panes`, keyed by raw pane id: cached per pane, process and
    /// foreground command, except Codex and OpenCode, whose session can
    /// change without either changing. Refresh those with the same batched `ps` exec. A
    /// failed exec resolves nothing (those panes show as Shells until the
    /// next snapshot) and caches nothing.
    func resolveForeground(_ panes: [TmuxPaneRecord]) async -> [String: TmuxForegroundKind] {
        var kinds: [String: TmuxForegroundKind] = [:]
        var unresolved: [TmuxPaneRecord] = []
        for pane in panes {
            if let cached = foregroundCache[pane.id], cached.pid == pane.pid,
                cached.currentCommand == pane.currentCommand,
                !TmuxAgentDetection.needsServerSessionLinkFacts(pane, resolvedKind: cached.kind)
            {
                kinds[pane.id] = cached
            } else {
                // A failed refresh must not leave a previous resume id live.
                foregroundCache[pane.id] = nil
                if Self.ttyName(pane.tty) != nil { unresolved.append(pane) }
            }
        }
        guard !unresolved.isEmpty else { return kinds }
        var ttys: [String] = []
        for pane in unresolved {
            if let tty = Self.ttyName(pane.tty), !ttys.contains(tty) { ttys.append(tty) }
        }
        guard
            let result = try? await session.runExec(
                Self.foregroundProcessCommand(ttys: ttys), input: Data(), timeout: nil),
            result.exitStatus == 0
        else { return kinds }
        let commandLines = Self.foregroundCommandLines(Self.text(result.stdout))
        for pane in unresolved {
            guard let tty = Self.ttyName(pane.tty), let commandLine = commandLines[tty] else {
                continue
            }
            let kind = commandLine.flatMap(AgentKindDetection.kind(commandLine:))
            let resolved = TmuxForegroundKind(
                pid: pane.pid, currentCommand: pane.currentCommand, kind: kind,
                commandLine: commandLine)
            foregroundCache[pane.id] = resolved
            kinds[pane.id] = resolved
        }
        return kinds
    }

    static let ttyMarker = "__WAYCAR_TTY__="

    /// For each tty, a marker line and its processes:
    /// `ps -t <tty> -o pid=,pgid=,tpgid=,stat=,args=`.
    static func foregroundProcessCommand(ttys: [String]) throws -> String {
        try shellCommand(
            "for t in \"$@\"; do printf \"\(ttyMarker)%s\\n\" \"$t\"; "
                + "ps -t \"$t\" -o pid=,pgid=,tpgid=,stat=,args= 2>/dev/null; done; exit 0",
            arguments: ttys, cLocale: true)
    }

    /// `pane_tty` as `ps -t` takes it (`/dev/pts/3` -> `pts/3`); nil for
    /// anything that is not a plain device name.
    static func ttyName(_ tty: String) -> String? {
        let name = tty.hasPrefix("/dev/") ? String(tty.dropFirst("/dev/".count)) : tty
        guard !name.isEmpty, !name.hasPrefix("/"),
            name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "/._-".contains($0)) })
        else { return nil }
        return name
    }

    /// Per tty listed, its foreground process's command line: the row in the
    /// terminal's foreground process group (`stat` has `+`, or pgid ==
    /// tpgid), its group leader first. A tty with no such row maps to nil.
    static func foregroundCommandLines(_ output: String) -> [String: String?] {
        var result: [String: String?] = [:]
        var current: String?
        var leader: String?
        var member: String?
        func flush() {
            guard let tty = current else { return }
            result[tty] = .some(leader ?? member)
        }
        for line in output.split(whereSeparator: \.isNewline) {
            if line.hasPrefix(ttyMarker) {
                flush()
                current = String(line.dropFirst(ttyMarker.count))
                leader = nil
                member = nil
                continue
            }
            guard current != nil else { continue }
            let fields = line.split(
                maxSplits: 4, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            guard fields.count == 5, let pid = Int(fields[0]), let pgid = Int(fields[1]),
                let tpgid = Int(fields[2])
            else { continue }
            guard fields[3].contains("+") || (pgid == tpgid && tpgid > 0) else { continue }
            let args = String(fields[4])
            if pid == pgid, leader == nil { leader = args }
            if member == nil { member = args }
        }
        flush()
        return result
    }

    // MARK: Lookups

    /// The raw id inside an app id, checked for its sigil; herdr's not-found
    /// code otherwise.
    static func rawID(_ appID: String, sigil: Character, code: String) throws -> String {
        guard let raw = TmuxID.raw(appID), raw.first == sigil, TmuxID.number(raw) != nil,
            raw.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber })
        else { throw HerdrAPIError(code: code, message: "not a tmux id: \(appID)") }
        return raw
    }

    /// The raw pane in a pane id (`tmux:%N`) or a terminal id
    /// (`tmux:%N@<server>`, ``TmuxInventory/terminalID(pane:server:)``).
    static func rawPane(_ appID: String) throws -> String {
        let pane = appID.firstIndex(of: "@").map { String(appID[..<$0]) } ?? appID
        return try rawID(pane, sigil: "%", code: "pane_not_found")
    }

    /// The pane's terminal id on the server this transport talks to.
    func terminalID(forPane rawPane: String) -> String {
        TmuxInventory.terminalID(pane: rawPane, server: serverIdentity)
    }

    static func rawWindow(_ appID: String) throws -> String {
        try rawID(appID, sigil: "@", code: "tab_not_found")
    }

    static func rawSession(_ appID: String) throws -> String {
        try rawID(appID, sigil: "$", code: "workspace_not_found")
    }

    static var paneLocationFormat: String { TmuxInventory.fields(["session_id", "window_id"]) }

    /// The session and window a pane shows in: from the last inventory, else
    /// asked of tmux.
    func paneLocation(_ rawPane: String) async throws -> (sessionID: String, windowID: String) {
        if let pane = records.pane(rawPane) { return (pane.sessionID, pane.windowID) }
        let replies = try await run(
            [TmuxCommand.display(format: Self.paneLocationFormat, target: rawPane)])
        let fields = TmuxInventory.split(
            replies[0].lines.first ?? "", at: TmuxInventory.fieldSeparator)
        guard fields.count == 2, fields[0].first == "$", fields[1].first == "@" else {
            throw TransportError.malformedResponse("tmux located \(rawPane) as \(fields)")
        }
        return (fields[0], fields[1])
    }

    /// The pane's Agent from the last snapshot, else a minimal one.
    func agent(forPane rawPane: String, kind fallbackKind: String? = nil) -> Agent {
        let paneID = TmuxID.app(rawPane)
        if let info = lastSnapshot?.agents.first(where: { $0.paneID == paneID }) {
            return Agent(info)
        }
        let pane = records.pane(rawPane)
        return Agent(
            terminalID: terminalID(forPane: rawPane),
            kind: fallbackKind ?? launchGates[rawPane]?.kind ?? Agent.unidentifiedKind,
            title: "", status: .unknown,
            workspaceID: pane.map { TmuxID.app($0.sessionID) } ?? "",
            tabID: pane.map { TmuxID.app($0.windowID) } ?? "",
            paneID: paneID, cwd: pane?.currentPath ?? "", revision: 0)
    }
}

// MARK: - Screen detection

extension TmuxTransport {
    /// Reads the screens of Agent panes in Status Hooks' blind spots while
    /// the event stream is open (``TmuxScreenVerdictMachine``), one tick per
    /// `Configuration.screenWatch.tick`.
    func startScreenPoll() {
        guard screenPoll == nil else { return }
        let tick = configuration.screenWatch.tick
        screenPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: tick)
                guard !Task.isCancelled, let self else { return }
                guard await self.pollScreens() else { return }
            }
        }
    }

    /// Stops the reads. Their verdicts outlive a deliberate resubscribe, so
    /// the snapshot after it still shows them (a hook change drops one
    /// anyway); a closed transport forgets them, as does a lost link
    /// (`finishEvents`) or a server with no sessions left (`enterIdle`).
    func stopScreenPoll() {
        screenPoll?.cancel()
        screenPoll = nil
        if closed { _ = screenWatch.handle(.forget) }
    }

    /// One tick: the due panes' screens over the control channel, one
    /// control line each, and a `pane.agent_status_changed` for each verdict
    /// that changes what was reported. False once polling should stop.
    func pollScreens() async -> Bool {
        guard !closed, eventContinuation != nil else { return false }
        guard let channel = controlChannel, await channel.isOpen else { return true }
        let reads = screenWatch.handle(
            .tick(screenWatchPanes(), now: ContinuousClock.now, timing: configuration.screenWatch))
        for case .readScreen(let pane) in reads {
            let replies = try? await send(
                channel,
                [
                    TmuxCommand.capturePane(
                        target: pane.id, lines: TmuxScreenDetector.historyLines),
                    TmuxCommand.display(format: "#{pane_title}", target: pane.id),
                ])
            guard !Task.isCancelled, !closed, eventContinuation != nil else { return false }
            // A pane that went away or a slow read waits for its next turn.
            guard let replies else { continue }
            let status = TmuxScreenDetector.classify(
                kind: pane.kind, screen: replies[0].lines.joined(separator: "\n"),
                title: replies[1].lines.joined(separator: " "))
            // Listed again: a hook that moved during the read wins.
            guard let current = screenWatchPanes().first(where: { $0.id == pane.id }),
                current.kind == pane.kind, current.session == pane.session
            else { continue }
            for case .report(let report, let paneID) in screenWatch.handle(
                .read(status, pane: current, now: ContinuousClock.now))
            {
                deliver(TmuxEvents.statusChanged(paneID: paneID, status: report.rawValue))
            }
        }
        return true
    }

    /// The last snapshot's Agents of kinds with screen rules, with their hook
    /// options from the latest `wc-status` push (else the snapshot's).
    func screenWatchPanes() -> [TmuxScreenVerdictMachine.Pane] {
        guard let agents = lastSnapshot?.agents, !agents.isEmpty else { return [] }
        var hooks: [String: (status: String, seq: String, session: String)] = [:]
        if let value = subscriptionBaseline.value(of: TmuxEvents.statusName),
            let statusAt = TmuxEvents.statusFields.firstIndex(of: "@waycar_status"),
            let seqAt = TmuxEvents.statusFields.firstIndex(of: "@waycar_seq"),
            let sessionAt = TmuxEvents.statusFields.firstIndex(of: "@waycar_session")
        {
            for fields in TmuxEvents.rows(value, fieldCount: TmuxEvents.statusFields.count)
            where hooks[fields[0]] == nil {
                hooks[fields[0]] = (fields[statusAt], fields[seqAt], fields[sessionAt])
            }
        }
        return agents.compactMap { agent in
            guard let kind = agent.agent, TmuxScreenDetector.supports(kind: kind),
                let id = TmuxID.raw(agent.paneID)
            else { return nil }
            let record = records.pane(id)
            let hook = hooks[id]
                ?? (status: record?.waycarStatus ?? "", seq: record?.waycarSeq ?? "",
                    session: record?.waycarSession ?? "")
            let plugin = record.flatMap {
                TmuxAgentDetection.sidebarStatus($0.sidebarStatus)
                    ?? TmuxAgentDetection.workmuxStatus($0.workmuxStatus)
            }
            return TmuxScreenVerdictMachine.Pane(
                id: id, kind: kind, hookStatus: hook.status, hookSeq: hook.seq,
                baseStatus: TmuxAgentDetection.waycarStatus(hook.status) ?? plugin ?? .unknown,
                session: hook.session)
        }
    }

    /// `panes` with each screen verdict in force written over the pane's
    /// `@waycar_status`, so a snapshot shows what the event stream reported.
    func screenOverlaid(_ panes: [TmuxPaneRecord], kinds: [String: String]) -> [TmuxPaneRecord] {
        panes.map { pane in
            guard let kind = TmuxAgentDetection.kind(for: pane, resolvedKind: kinds[pane.id]),
                let status = screenWatch.screenStatus(
                    paneID: pane.id, hookStatus: pane.waycarStatus, hookSeq: pane.waycarSeq,
                    kind: kind, session: pane.waycarSession),
                status != TmuxAgentDetection.status(for: pane)
            else { return pane }
            return TmuxPaneRecord(
                id: pane.id, sessionID: pane.sessionID, windowID: pane.windowID,
                index: pane.index, active: pane.active, dead: pane.dead,
                alternateOn: pane.alternateOn, pid: pane.pid, tty: pane.tty, width: pane.width,
                height: pane.height, currentCommand: pane.currentCommand,
                waycarStatus: status.rawValue, waycarAgent: pane.waycarAgent,
                waycarSeq: pane.waycarSeq, sidebarStatus: pane.sidebarStatus,
                workmuxStatus: pane.workmuxStatus, currentPath: pane.currentPath,
                waycarSession: pane.waycarSession, waycarTranscript: pane.waycarTranscript,
                title: pane.title, startCommand: pane.startCommand)
        }
    }
}
