import Foundation

/// Pure projection of a watch frame to Console wire rows; no transport or backend registration.
enum ZellijSnapshotBuilder {
    static func snapshot(
        frame: ZellijFrame, generations: [String: UInt64] = [:],
        overlays: ZellijDoneOverlay = .init(), screenVerdicts: [String: AgentStatus] = [:],
        firstSeenMs: [String: Int64] = [:], version: String = ""
    ) -> SessionSnapshot {
        var panes: [PaneInfo] = []
        var agents: [AgentInfo] = []
        var tabs: [TabInfo] = []
        var workspaces: [WorkspaceInfo] = []
        for session in frame.sessions where !session.closed {
            let workspaceID = ZellijPaneID.workspace(session: session.name)
            let records = visiblePanes(frame, session: session.name)
            // Failed list-panes (including an LF-name fragment) never makes an empty Workspace.
            guard !records.isEmpty else { continue }
            let grouped = Dictionary(grouping: records, by: \.tabID)
            let tabIDs = grouped.keys.sorted {
                let lhs = grouped[$0]?.first?.tabPosition ?? $0
                let rhs = grouped[$1]?.first?.tabPosition ?? $1
                return lhs == rhs ? $0 < $1 : lhs < rhs
            }
            var workspaceStatuses: [AgentStatus] = []
            var activeTab = ""
            for tab in tabIDs {
                let tabID = ZellijPaneID.tab(session: session.name, id: tab)
                let rows = grouped[tab] ?? []
                var statuses: [AgentStatus] = []
                for row in rows {
                    guard let id = ZellijPaneID(session: session.name, pane: row.id) else { continue }
                    let terminalID = id.terminalID(generation: generations[session.name] ?? 0)
                    let document = document(for: id, frame: frame, firstSeenMs: firstSeenMs)
                    let kind = kind(row, document: document)
                    let resolved = status(row, document: document, screen: screenVerdicts[id.description])
                    let status =
                        kind == nil
                        ? AgentStatus.unknown
                        : overlays.presented(resolved, terminalID: terminalID)
                    let agentSession = kind.flatMap { agentSession(document, kind: $0) }
                    panes.append(
                        PaneInfo(
                            agentStatus: status, focused: false, paneID: id.description,
                            revision: 0, tabID: tabID, terminalID: terminalID, workspaceID: workspaceID,
                            agent: kind, agentSession: agentSession, cwd: row.paneCwd,
                            foregroundCwd: row.paneCwd, terminalTitle: row.title))
                    if let kind {
                        statuses.append(status)
                        agents.append(
                            AgentInfo(
                                agentStatus: status, focused: false, paneID: id.description,
                                revision: 0, tabID: tabID, terminalID: terminalID, workspaceID: workspaceID,
                                agent: kind, agentSession: agentSession, cwd: row.paneCwd,
                                foregroundCwd: row.paneCwd, name: rows.count == 1 ? row.tabName : row.title,
                                stateChangeSeq: resolved.sequence
                                    ?? resolved.updatedMs.flatMap(Int.init(exactly:)),
                                terminalTitle: row.title))
                    }
                }
                // Pane focus is retained per tab and per client; no active-tab claim comes from it.
                if activeTab.isEmpty { activeTab = tabID }
                tabs.append(
                    TabInfo(
                        agentStatus: TmuxInventory.aggregate(statuses), focused: false,
                        label: rows.first?.tabName ?? "Terminal", number: rows.first?.tabPosition ?? tab,
                        paneCount: rows.count, tabID: tabID, workspaceID: workspaceID))
                workspaceStatuses += statuses
            }
            workspaces.append(
                WorkspaceInfo(
                    activeTabID: activeTab, agentStatus: TmuxInventory.aggregate(workspaceStatuses),
                    focused: false, label: session.name, number: workspaces.count + 1,
                    paneCount: records.count, tabCount: tabIDs.count, workspaceID: workspaceID))
        }
        return SessionSnapshot(
            agents: agents, layouts: [], panes: panes, protocolVersion: 0, tabs: tabs,
            version: version, workspaces: workspaces)
    }

    static func visiblePanes(_ frame: ZellijFrame, session: String) -> [ZellijPaneRecord] {
        var seen = Set<Int>()
        return (frame.panes[session] ?? []).filter {
            $0.isVisible && ZellijPaneID(session: session, pane: $0.id) != nil
                && seen.insert($0.id).inserted
        }.sorted { $0.id < $1.id }
    }

    enum RenameTarget: Sendable, Equatable {
        case tab(Int)
        case pane
    }

    /// Rename exactly the source of AgentInfo.name: a lone terminal's tab, otherwise its pane.
    /// Counts the same visible terminal rows the snapshot shows, never plugins or suppressed panes.
    static func renameTarget(for id: ZellijPaneID, frame: ZellijFrame) -> RenameTarget? {
        guard frame.sessions.contains(where: { $0.name == id.session && !$0.closed }) else { return nil }
        let rows = visiblePanes(frame, session: id.session)
        guard let pane = rows.first(where: { $0.id == id.pane }) else { return nil }
        return rows.filter { $0.tabID == pane.tabID }.count == 1 ? .tab(pane.tabID) : .pane
    }

    /// A missing first-sighting means no restart was observed. Otherwise an undated/stale hook is unsafe.
    static func document(
        for id: ZellijPaneID, frame: ZellijFrame, firstSeenMs: [String: Int64]
    ) -> ZellijPaneState? {
        guard let document = frame.documents[id.description] else { return nil }
        if let firstSeen = firstSeenMs[id.session], (document.updatedMs ?? .min) < firstSeen { return nil }
        return document
    }

    static func kind(_ row: ZellijPaneRecord, document: ZellijPaneState?) -> String? {
        guard row.exited != true else { return nil }
        if let app = row.rootStatus?.app, let kind = CoreSnapshotBuilder.kind(forApp: app) { return kind }
        if let kind = document?.kind, !kind.isEmpty { return kind }
        return row.paneCommand.flatMap(AgentKindDetection.kind(commandLine:))
    }

    static func status(
        _ row: ZellijPaneRecord, document: ZellijPaneState?, screen: AgentStatus?
    ) -> ZellijResolvedStatus {
        if let root = row.rootStatus, let status = root.agentStatus {
            return .init(status: status, source: .program, updatedMs: root.updatedMs)
        }
        if let status = document?.status {
            return .init(
                status: status, source: .hook, sequence: document?.seq, updatedMs: document?.updatedMs)
        }
        if let screen { return .init(status: screen, source: .screen) }
        return .init(status: .unknown, source: .unknown)
    }

    static func agentSession(_ document: ZellijPaneState?, kind: String) -> AgentSessionInfo? {
        guard let value = document?.session ?? document?.transcript, !value.isEmpty else { return nil }
        return AgentSessionInfo(
            agent: kind, kind: value.hasPrefix("/") ? .path : .id, source: "zellij", value: value)
    }

    /// The hook's launch identity, otherwise the creation command's exact env token (Z13).
    static func launchTag(_ row: ZellijPaneRecord, document: ZellijPaneState?) -> String? {
        if let launch = document?.launch, !launch.isEmpty { return launch }
        return ZellijLaunchReconciliation.tag(in: row.terminalCommand ?? "")
    }

    /// ShellForeground's prompt-vs-script rules, using a synthetic single leader (Zellij has no pids).
    static func shellActivities(frame: ZellijFrame, firstSeenMs: [String: Int64] = [:]) -> [String:
        ShellActivity]
    {
        var result: [String: ShellActivity] = [:]
        for session in frame.sessions where !session.closed {
            for row in visiblePanes(frame, session: session.name) where row.exited != true {
                guard let id = ZellijPaneID(session: session.name, pane: row.id),
                    kind(row, document: document(for: id, frame: frame, firstSeenMs: firstSeenMs)) == nil,
                    let command = row.paneCommand
                else { continue }
                let argv = command.split(whereSeparator: \.isWhitespace).map(String.init)
                guard let name = argv.first else { continue }
                result[id.description] = ShellForeground.activity(
                    PaneProcessInfo(
                        paneID: id.description, foregroundProcessGroupID: 0,
                        foregroundProcesses: [.init(name: name, pid: 0, argv: argv, cmdline: command)],
                        shellPid: 0))
            }
        }
        return result
    }
}
