import Foundation

/// A Console mutation herdr has confirmed but no snapshot shows yet (#105):
/// a rename or a close whose RPC succeeded. `HostConsoleProjection` applies
/// it to its rows at once instead of waiting a resync round trip for the
/// change to appear, and lays it over any snapshot that was requested
/// before the mutation was confirmed, so a slower in-flight snapshot cannot
/// briefly put the old state back. The first snapshot requested after it is
/// authoritative and retires it.
enum ConsoleLocalEdit: Equatable, Sendable {
    /// `agent.rename`; nil clears back to the detected kind.
    case renameAgent(paneID: String, name: String?)
    case renameWorkspace(workspaceID: String, label: String)
    /// A tab's label, which is also its shell rows' name.
    case renameTab(tabID: String, label: String)
    case closePane(paneID: String)
    /// Closes every pane on the tab, and the workspace when it was the
    /// workspace's last tab.
    case closeTab(tabID: String)

    /// `snapshot` as herdr reports it once the edit has landed.
    func applied(to snapshot: SessionSnapshot) -> SessionSnapshot {
        var agents = snapshot.agents
        var panes = snapshot.panes
        var tabs = snapshot.tabs
        var workspaces = snapshot.workspaces
        switch self {
        case .renameAgent(let paneID, let name):
            agents = agents.map { $0.paneID == paneID ? $0.renamed(name) : $0 }
        case .renameWorkspace(let workspaceID, let label):
            workspaces = workspaces.map {
                $0.workspaceID == workspaceID ? $0.relabeled(label) : $0
            }
        case .renameTab(let tabID, let label):
            tabs = tabs.map { $0.tabID == tabID ? $0.relabeled(label) : $0 }
        case .closePane(let paneID):
            agents.removeAll { $0.paneID == paneID }
            panes.removeAll { $0.paneID == paneID }
        case .closeTab(let tabID):
            let workspaceIDs = Set(tabs.filter { $0.tabID == tabID }.map(\.workspaceID))
            agents.removeAll { $0.tabID == tabID }
            panes.removeAll { $0.tabID == tabID }
            tabs.removeAll { $0.tabID == tabID }
            let remaining = Set(tabs.map(\.workspaceID))
            workspaces.removeAll {
                workspaceIDs.contains($0.workspaceID) && !remaining.contains($0.workspaceID)
            }
        }
        return SessionSnapshot(
            agents: agents, layouts: snapshot.layouts, panes: panes,
            protocolVersion: snapshot.protocolVersion, tabs: tabs,
            version: snapshot.version, workspaces: workspaces,
            focusedPaneID: snapshot.focusedPaneID, focusedTabID: snapshot.focusedTabID,
            focusedWorkspaceID: snapshot.focusedWorkspaceID)
    }

    /// The Console rows, keyed by pane, with the edit applied in place:
    /// every other value a row carries (status deltas, summaries, shell
    /// titles folded since the last snapshot) stays as it is.
    func applied(to rows: [String: ConsoleAgent]) -> [String: ConsoleAgent] {
        switch self {
        case .renameAgent(let paneID, let name):
            guard let row = rows[paneID], !row.isShell else { return rows }
            var renamed = rows
            renamed[paneID] = row.replacing(agent: row.agent.renamed(name))
            return renamed
        case .renameWorkspace(let workspaceID, let label):
            return rows.mapValues { row in
                row.agent.workspaceID == workspaceID
                    ? row.replacing(workspaceLabel: label) : row
            }
        case .renameTab(let tabID, let label):
            return rows.mapValues { row in
                guard row.agent.tabID == tabID else { return row }
                let agent = row.isShell
                    ? row.agent.renamed(
                        HostConsoleProjection.shellName(
                            tabLabel: label, tabPosition: row.tabPosition))
                    : row.agent
                return row.replacing(agent: agent, tabLabel: label)
            }
        case .closePane(let paneID):
            var remaining = rows
            remaining[paneID] = nil
            return remaining
        case .closeTab(let tabID):
            return rows.filter { $0.value.agent.tabID != tabID }
        }
    }
}

private extension AgentInfo {
    /// herdr reports a renamed Agent under `name` and `display_agent` alike;
    /// a cleared name leaves both to the detected kind.
    func renamed(_ name: String?) -> AgentInfo {
        AgentInfo(
            agentStatus: agentStatus, focused: focused, paneID: paneID, revision: revision,
            tabID: tabID, terminalID: terminalID, workspaceID: workspaceID, agent: agent,
            agentSession: agentSession, cwd: cwd, displayAgent: name,
            foregroundCwd: foregroundCwd, interactiveReady: interactiveReady,
            launchPending: launchPending, name: name,
            screenDetectionSkipped: screenDetectionSkipped, stateChangeSeq: stateChangeSeq,
            stateLabels: stateLabels, terminalTitle: terminalTitle,
            terminalTitleStripped: terminalTitleStripped, title: title, tokens: tokens)
    }
}

private extension WorkspaceInfo {
    func relabeled(_ label: String) -> WorkspaceInfo {
        WorkspaceInfo(
            activeTabID: activeTabID, agentStatus: agentStatus, focused: focused, label: label,
            number: number, paneCount: paneCount, tabCount: tabCount, workspaceID: workspaceID,
            tokens: tokens, worktree: worktree)
    }
}

private extension TabInfo {
    func relabeled(_ label: String) -> TabInfo {
        TabInfo(
            agentStatus: agentStatus, focused: focused, label: label, number: number,
            paneCount: paneCount, tabID: tabID, workspaceID: workspaceID)
    }
}

private extension Agent {
    /// The same Agent under `name`, its folded status delta kept.
    func renamed(_ name: String?) -> Agent {
        var renamed = Agent(
            terminalID: terminalID, kind: kind, title: title, status: status,
            workspaceID: workspaceID, tabID: tabID, paneID: paneID, cwd: cwd,
            revision: revision, name: name, terminalTitle: terminalTitle,
            terminalTitleStripped: terminalTitleStripped, paneTitle: paneTitle,
            agentSession: agentSession, tokens: tokens, stateLabels: stateLabels,
            stateChangeSeq: stateChangeSeq)
        if statusReplacedSinceSnapshot { renamed.replaceStatus(status) }
        return renamed
    }
}

private extension ConsoleAgent {
    func replacing(
        agent: Agent? = nil, workspaceLabel: String? = nil, tabLabel: String? = nil
    ) -> ConsoleAgent {
        ConsoleAgent(
            hostID: hostID, hostName: hostName, agent: agent ?? self.agent,
            workspaceLabel: workspaceLabel ?? self.workspaceLabel,
            repositoryCheckout: repositoryCheckout, summary: summary,
            isSummaryPending: isSummaryPending, hostReportsProgress: hostReportsProgress,
            hostUsername: hostUsername,
            tabLabel: tabLabel ?? self.tabLabel, tabPosition: tabPosition,
            workspaceTabCount: workspaceTabCount, snapshotOrder: snapshotOrder,
            paneLabel: paneLabel, backend: backend, shellActivity: shellActivity)
    }
}
