import Foundation

/// One Workspace's Agents on one Host. Agents arrive already sorted by
/// ConsoleStore; the group preserves that exact relative order.
struct ConsoleWorkspaceGroup: Identifiable, Equatable {
    /// Bucket for agents whose snapshot carried no workspace label.
    static let unassignedLabel = "Unassigned"

    /// Group identity. Labels are freely collidable (herdr's rename RPC),
    /// so a known workspace is identified by its workspace id; only Agents
    /// whose workspace the Host no longer reports fall back to a label.
    enum ID: Hashable {
        case workspace(String)
        case label(String)
        case unassigned
    }

    let id: ID
    let label: String
    let agents: [ConsoleAgent]
    /// Linked-worktree workspaces of this group's repository, each carrying
    /// the Agents that live in that worktree workspace. Empty for
    /// everything but a repository's main-checkout workspace: a worktree
    /// is a child of its repo, never a sibling (herdr's sidebar tree).
    var worktrees: [ConsoleWorkspaceGroup] = []

    /// The Host workspace this group shows; nil for the label fallback and
    /// "Unassigned" buckets, which have no workspace to target.
    var workspaceID: String? {
        guard case .workspace(let workspaceID) = id else { return nil }
        return workspaceID
    }
}

/// One entry of the Console's Workspace menu. "All Workspaces" leads and is
/// the default; every other entry is one Host's workspace group, carrying
/// its linked worktrees' Agents too. Entries come from the Host scope alone,
/// never the Status filter: a Workspace stays listed whatever its Agents are
/// doing.
struct ConsoleWorkspaceOption: Identifiable, Equatable {
    enum ID: Hashable {
        case all
        case group(Host.ID, ConsoleWorkspaceGroup.ID)
    }

    static let allTitle = "All Workspaces"

    let id: ID
    let title: String
    /// The Agents this entry shows, in ConsoleStore's order.
    let agents: [ConsoleAgent]
}

/// The Console's filter pills. Chat follows All: it is a mode, not a
/// status, so it lists the Chat Mode Agents whatever their Agent Status.
/// Needs Attention (Blocked or Done) leads the status pills because those
/// are the two that wait on the user; Idle has no pill of its own and shows
/// under All, as do plain shells, which carry no Agent Status. Every pill is
/// always offered, even at zero. Closed is the trailing chip: it lists only
/// Closed Sessions, no Agent.
enum ConsoleStatusFilter: String, CaseIterable, Identifiable, Sendable {
    case all, chat, attention, blocked, done, working, closed

    var id: Self { self }

    /// The pills drawn as Status pills; Closed is drawn as its own chip.
    static let statusPills: [ConsoleStatusFilter] = allCases.filter { $0 != .closed }

    var title: String {
        switch self {
        case .all: "All"
        case .chat: "Chat"
        case .attention: "Needs Attention"
        case .blocked: "Blocked"
        case .done: "Done"
        case .working: "Working"
        case .closed: "Closed"
        }
    }

    /// The Agent Statuses this pill keeps; empty for All, Chat and Closed.
    var statuses: [AgentStatus] {
        switch self {
        case .all, .chat, .closed: []
        case .attention: [.blocked, .done]
        case .blocked: [.blocked]
        case .done: [.done]
        case .working: [.working]
        }
    }

    /// The colour of the pill's dot: its most urgent status; nil for All and Chat.
    var dotStatus: AgentStatus? { statuses.first }

    /// Empty-state copy when the pill matches nothing.
    var emptyTitle: String {
        switch self {
        case .attention: "No Agents Need Attention"
        case .chat: "No Chat Mode Agents"
        case .closed: "No Closed Sessions"
        default: "No \(title) Agents"
        }
    }

    /// Whether this pill lists `agent`. Chat goes by `chatAgentIDs`, the
    /// Chat Mode Agents' ids; every other pill ignores it.
    func matches(_ agent: ConsoleAgent, chatAgentIDs: Set<ConsoleAgent.ID> = []) -> Bool {
        switch self {
        case .all: true
        case .chat: !agent.isShell && chatAgentIDs.contains(agent.id)
        case .closed: false
        default: !agent.isShell && statuses.contains(agent.agent.status)
        }
    }
}

/// Projects the Console list: Host scope, then Workspace, then Status (or a
/// search in place of Status), then the visible Agent cards, and the Closed
/// Sessions after them. It never reorders Agents — ConsoleStore owns sort
/// and Pin priority — it only filters that sequence.
enum ConsoleListProjection {
    /// The Host the list is scoped to: the chosen one while it is still in
    /// the catalog, otherwise every Host (nil), so a choice whose Host was
    /// removed never hides every Agent.
    static func effectiveHostID(_ selected: Host.ID?, hosts: [Host]) -> Host.ID? {
        guard let selected, hosts.contains(where: { $0.id == selected }) else { return nil }
        return selected
    }

    static func scopedAgents(_ agents: [ConsoleAgent], hostID: Host.ID?) -> [ConsoleAgent] {
        guard let hostID else { return agents }
        return agents.filter { $0.hostID == hostID }
    }

    /// "All Workspaces" first, then each in-scope Host's workspace groups in
    /// catalog order. A title shared by workspaces on different Hosts gains
    /// the Host name, so two "app" entries stay tellable apart.
    static func workspaceOptions(
        hosts: [Host],
        agents: [ConsoleAgent],
        workspacesByHost: [Host.ID: [ConsoleWorkspace]],
        hostID: Host.ID?
    ) -> [ConsoleWorkspaceOption] {
        let scoped = scopedAgents(agents, hostID: hostID)
        let agentsByHost = Dictionary(grouping: scoped, by: \.hostID)
        var entries: [(host: Host, group: ConsoleWorkspaceGroup)] = []
        var seenHosts: Set<Host.ID> = []
        for host in hosts where hostID == nil || host.id == hostID {
            guard seenHosts.insert(host.id).inserted, let hostAgents = agentsByHost[host.id]
            else { continue }
            for group in workspaceGroups(
                for: hostAgents, workspaces: workspacesByHost[host.id] ?? [])
            {
                entries.append((host, group))
            }
        }

        var hostsByTitle: [String: Set<Host.ID>] = [:]
        for entry in entries {
            hostsByTitle[entry.group.label, default: []].insert(entry.host.id)
        }
        let groups = entries.map { entry in
            let members = Set(
                (entry.group.agents + entry.group.worktrees.flatMap(\.agents)).map(\.id))
            let isShared = (hostsByTitle[entry.group.label]?.count ?? 0) > 1
            return ConsoleWorkspaceOption(
                id: .group(entry.host.id, entry.group.id),
                title: isShared
                    ? "\(entry.group.label) · \(entry.host.displayName)" : entry.group.label,
                agents: scoped.filter { members.contains($0.id) })
        }
        let all = ConsoleWorkspaceOption(
            id: .all, title: ConsoleWorkspaceOption.allTitle, agents: scoped)
        return [all] + groups
    }

    /// The Workspace the list shows: the chosen one while it still exists,
    /// otherwise All — a closed workspace must not strand an empty list.
    static func effectiveWorkspaceID(
        _ selected: ConsoleWorkspaceOption.ID, in options: [ConsoleWorkspaceOption]
    ) -> ConsoleWorkspaceOption.ID {
        options.contains(where: { $0.id == selected }) ? selected : .all
    }

    /// The Agents of the effective Workspace, before Status or search.
    static func workspaceAgents(
        options: [ConsoleWorkspaceOption], selected: ConsoleWorkspaceOption.ID
    ) -> [ConsoleAgent] {
        let id = effectiveWorkspaceID(selected, in: options)
        return options.first(where: { $0.id == id })?.agents ?? []
    }

    /// How many of `agents` each Status pill would show. `held` counts under
    /// the status it was opened with, matching where it is listed;
    /// `chatAgentIDs` feeds the Chat pill.
    static func statusCounts(
        _ agents: [ConsoleAgent], held: ConsoleAgent? = nil,
        chatAgentIDs: Set<ConsoleAgent.ID> = []
    ) -> [ConsoleStatusFilter: Int] {
        Dictionary(uniqueKeysWithValues: ConsoleStatusFilter.statusPills.map { filter in
            (filter, agents.count {
                filter.matches(filterAs($0, held: held), chatAgentIDs: chatAgentIDs)
            })
        })
    }

    /// The cards on screen. A search replaces the Status filter — the pills
    /// give way to the search field while it is open — so a match is never
    /// hidden behind an unselected Status; the Host and Workspace still
    /// apply. The open Agent (`held`) is filtered by the status it had when
    /// opened, so opening a Done card under Needs Attention does not make it
    /// vanish as it turns Idle.
    static func visibleAgents(
        workspaceAgents: [ConsoleAgent],
        status: ConsoleStatusFilter,
        searchQuery: String,
        held: ConsoleAgent? = nil,
        chatAgentIDs: Set<ConsoleAgent.ID> = []
    ) -> [ConsoleAgent] {
        let needle = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !needle.isEmpty {
            return workspaceAgents.filter { $0.matchesAgentSearch(needle) }
        }
        return workspaceAgents.filter {
            status.matches(filterAs($0, held: held), chatAgentIDs: chatAgentIDs)
        }
    }

    private static func filterAs(_ agent: ConsoleAgent, held: ConsoleAgent?) -> ConsoleAgent {
        guard let held, held.id == agent.id else { return agent }
        return held
    }

    /// The Closed Sessions in the Host and Workspace scope, newest first. A
    /// Workspace entry lists a closed row the way it lists an Agent: by the
    /// group its Workspace lists under (`closedSessionGroupID`). Only Hosts
    /// the Console lists (`listedHostIDs`) count: a Disabled Host's Closed
    /// Sessions stay in the store, hidden, and return when it is turned on.
    static func scopedClosedSessions(
        _ sessions: [ClosedSession],
        listedHostIDs: Set<Host.ID>,
        hostID: Host.ID?,
        workspace: ConsoleWorkspaceOption.ID,
        workspacesByHost: [Host.ID: [ConsoleWorkspace]]
    ) -> [ClosedSession] {
        sessions.filter { session in
            guard listedHostIDs.contains(session.hostID) else { return false }
            if let hostID, session.hostID != hostID { return false }
            guard case .group(let groupHostID, let groupID) = workspace else { return true }
            return session.hostID == groupHostID
                && closedSessionGroupID(
                    session, workspaces: workspacesByHost[session.hostID] ?? []) == groupID
        }
    }

    /// The closed rows on screen, listed after every Agent row. A search
    /// matches them whatever the Status pill says, like it matches Agents,
    /// by the Host names the cards show (`hostNames`, the catalog's current
    /// ones); otherwise they show only under the Closed pill, which lists
    /// them alone.
    static func visibleClosedSessions(
        _ scoped: [ClosedSession],
        status: ConsoleStatusFilter,
        searchQuery: String,
        hostNames: [Host.ID: String]
    ) -> [ClosedSession] {
        let needle = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !needle.isEmpty {
            return scoped.filter {
                $0.matchesSearch(needle, currentHostName: hostNames[$0.hostID])
            }
        }
        return status == .closed ? scoped : []
    }

    /// The Queued Launches on screen (CONTEXT.md **Queued Launch**), in the
    /// store's order, oldest first: on listed Hosts within the Host scope,
    /// and under a Workspace entry only when they start in that Workspace or
    /// a worktree of it. They have no Agent Status yet, so only All lists
    /// them; a search matches them, whatever the pill, by name, kind and
    /// the Host name the card shows (`hostNames`).
    static func visibleQueuedLaunches(
        _ launches: [QueuedLaunch],
        listedHostIDs: Set<Host.ID>,
        hostID: Host.ID?,
        workspace: ConsoleWorkspaceOption.ID,
        workspacesByHost: [Host.ID: [ConsoleWorkspace]],
        status: ConsoleStatusFilter,
        searchQuery: String,
        hostNames: [Host.ID: String]
    ) -> [QueuedLaunch] {
        let needle = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty || status == .all else { return [] }
        return launches.filter { launch in
            guard listedHostIDs.contains(launch.hostID) else { return false }
            if let hostID, launch.hostID != hostID { return false }
            if case .group(let groupHostID, let groupID) = workspace {
                guard launch.hostID == groupHostID,
                    let workspaceID = launch.draft.workspaceID,
                    workspaceGroupID(
                        workspaceID, in: workspacesByHost[launch.hostID] ?? []) == groupID
                else { return false }
            }
            guard !needle.isEmpty else { return true }
            let draft = launch.draft
            let kind: [String?] =
                switch draft.dispatch.launch {
                case .agent(let kind): [kind.rawValue, kind.displayName]
                case .shell: [Agent.shellKind]
                }
            return ConsoleSearch.matches(
                needle, in: [draft.name, draft.suggestedName, hostNames[launch.hostID]] + kind)
        }
    }

    /// The Workspace group a Closed Session lists under, as
    /// `workspaceGroups` would place an Agent there: its Workspace while the
    /// Host still reports it — a linked worktree's under its repository's
    /// main-checkout parent — else its label, else Unassigned.
    static func closedSessionGroupID(
        _ session: ClosedSession, workspaces: [ConsoleWorkspace]
    ) -> ConsoleWorkspaceGroup.ID {
        if let workspaceID = session.workspaceID,
            let group = workspaceGroupID(workspaceID, in: workspaces)
        {
            return group
        }
        guard let label = session.workspaceLabel, !label.isEmpty else { return .unassigned }
        return .label(label)
    }

    /// The group a Workspace the Host reports lists under: its own, or a
    /// linked worktree's main-checkout parent's; nil once the Host no longer
    /// reports it.
    private static func workspaceGroupID(
        _ workspaceID: String, in workspaces: [ConsoleWorkspace]
    ) -> ConsoleWorkspaceGroup.ID? {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else {
            return nil
        }
        if let checkout = workspace.checkout, checkout.isLinkedWorktree,
            let parent = parentWorkspace(forRepoKey: checkout.repoKey, in: workspaces)
        {
            return .workspace(parent.id)
        }
        return .workspace(workspace.id)
    }

    /// The one workspace a repository's linked worktrees nest under: the
    /// FIRST main-checkout (`isLinkedWorktree == false`) workspace for
    /// `repoKey` in the Host's workspace order. herdr can hold several
    /// workspaces on the same main checkout; only this one parents the tree.
    static func parentWorkspace(
        forRepoKey repoKey: String, in workspaces: [ConsoleWorkspace]
    ) -> ConsoleWorkspace? {
        workspaces.first {
            $0.checkout?.repoKey == repoKey && $0.checkout?.isLinkedWorktree == false
        }
    }

    /// Groups one Host's Agents by workspace, nesting the linked-worktree
    /// workspaces of a repository under that repo's main-checkout workspace
    /// (herdr's sidebar grouping: a linked worktree is a child of the repo,
    /// not a sibling workspace). Top-level groups follow the Host's known
    /// workspace order, and a parent's children follow it too. Agents are
    /// bucketed by workspace id; an Agent whose workspace the Host no longer
    /// reports falls back to a label group in first-appearance order, and
    /// Agents with no workspace label fall under "Unassigned" last. Within a
    /// bucket the incoming (already-sorted) Agent order is preserved.
    static func workspaceGroups(
        for agents: [ConsoleAgent],
        workspaces: [ConsoleWorkspace]
    ) -> [ConsoleWorkspaceGroup] {
        // Ids, not labels: herdr's rename RPC makes labels freely
        // collidable, and same-label workspaces must never share Agents.
        let knownWorkspaceIDs = Set(workspaces.map(\.id))
        var agentsByWorkspaceID: [String: [ConsoleAgent]] = [:]
        var agentsByLabel: [String: [ConsoleAgent]] = [:]
        var labelOrder: [String] = []
        var unassigned: [ConsoleAgent] = []
        for agent in agents {
            let workspaceID = agent.agent.workspaceID
            if knownWorkspaceIDs.contains(workspaceID) {
                agentsByWorkspaceID[workspaceID, default: []].append(agent)
                continue
            }
            guard let label = agent.workspaceLabel, !label.isEmpty else {
                unassigned.append(agent)
                continue
            }
            if agentsByLabel[label] == nil {
                labelOrder.append(label)
            }
            agentsByLabel[label, default: []].append(agent)
        }

        // One parent per repo: the first main-checkout workspace in Host
        // order. It shows when it has Agents or an agented linked worktree
        // of its repo nests under it; a worktree whose repo has no
        // main-checkout workspace on the Host stays a top-level group.
        var parentIDByRepo: [String: String] = [:]
        var agentedWorktreeRepos: Set<String> = []
        for workspace in workspaces {
            guard let checkout = workspace.checkout else { continue }
            if parentIDByRepo[checkout.repoKey] == nil,
                let parent = parentWorkspace(forRepoKey: checkout.repoKey, in: workspaces)
            {
                parentIDByRepo[checkout.repoKey] = parent.id
            }
            if checkout.isLinkedWorktree, agentsByWorkspaceID[workspace.id] != nil {
                agentedWorktreeRepos.insert(checkout.repoKey)
            }
        }

        // One ordered pass: parents, checkout-less, non-parent main, and
        // orphan worktree groups take their own position; nested children
        // are collected in workspace order and attached afterwards, so a
        // child listed before its parent never moves the parent.
        var groups: [ConsoleWorkspaceGroup] = []
        var parentIndexByID: [String: Int] = [:]
        var childrenByParentID: [String: [ConsoleWorkspaceGroup]] = [:]
        for workspace in workspaces {
            let workspaceAgents = agentsByWorkspaceID[workspace.id] ?? []
            let group = ConsoleWorkspaceGroup(
                id: .workspace(workspace.id),
                label: workspace.label,
                agents: workspaceAgents)
            let parentID = workspace.checkout.flatMap { parentIDByRepo[$0.repoKey] }
            if let checkout = workspace.checkout, parentID == workspace.id {
                guard !workspaceAgents.isEmpty || agentedWorktreeRepos.contains(checkout.repoKey)
                else { continue }
                parentIndexByID[workspace.id] = groups.count
                groups.append(group)
                continue
            }
            guard !workspaceAgents.isEmpty else { continue }
            if workspace.checkout?.isLinkedWorktree == true, let parentID {
                childrenByParentID[parentID, default: []].append(group)
            } else {
                groups.append(group)
            }
        }
        for (parentID, children) in childrenByParentID {
            guard let parentIndex = parentIndexByID[parentID] else { continue }
            groups[parentIndex].worktrees = children
        }

        for label in labelOrder {
            groups.append(
                ConsoleWorkspaceGroup(
                    id: .label(label), label: label, agents: agentsByLabel[label] ?? []))
        }
        if !unassigned.isEmpty {
            groups.append(
                ConsoleWorkspaceGroup(
                    id: .unassigned,
                    label: ConsoleWorkspaceGroup.unassignedLabel,
                    agents: unassigned))
        }
        return groups
    }
}

/// A row above the Console's Agent cards: a Host's status row or a Queued
/// Launch's card.
enum ConsoleLeadRow: Identifiable, Equatable {
    case issue(ConsoleHostStatusPresentation)
    case launch(QueuedLaunch)

    var id: String {
        switch self {
        case .issue(let issue): "issue:\(issue.id)"
        case .launch(let launch): "launch:\(launch.id.uuidString)"
        }
    }

    /// `issues` in order, each Host's `launches` right after its last row,
    /// then the launches of Hosts that have none, still together by Host, so
    /// a card stays beside its Host's others when that Host's row goes away.
    static func ordered(
        issues: [ConsoleHostStatusPresentation], launches: [QueuedLaunch]
    ) -> [ConsoleLeadRow] {
        var lastIssue: [Host.ID: Int] = [:]
        for (index, issue) in issues.enumerated() { lastIssue[issue.hostID] = index }
        func hostLaunches(_ hostID: Host.ID) -> [ConsoleLeadRow] {
            launches.filter { $0.hostID == hostID }.map(ConsoleLeadRow.launch)
        }
        var rows: [ConsoleLeadRow] = []
        for (index, issue) in issues.enumerated() {
            rows.append(.issue(issue))
            if lastIssue[issue.hostID] == index { rows += hostLaunches(issue.hostID) }
        }
        var listed = Set(lastIssue.keys)
        for launch in launches where listed.insert(launch.hostID).inserted {
            rows += hostLaunches(launch.hostID)
        }
        return rows
    }
}
