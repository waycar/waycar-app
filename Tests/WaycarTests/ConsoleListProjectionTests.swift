import Foundation
import Testing

@testable import Waycar

@MainActor
@Suite("Console list projection")
struct ConsoleListProjectionTests {
    /// An Agent whose workspace the Host no longer reports (or never did):
    /// only its label, if any, is left to group it by.
    private func consoleAgent(
        host: Host,
        paneID: String,
        status: AgentStatus,
        workspaceID: String = "w-unreported",
        workspaceLabel: String? = nil
    ) -> ConsoleAgent {
        ConsoleAgent(
            hostID: host.id,
            hostName: host.displayName,
            agent: Agent(.fixture(paneID: paneID, status: status, workspaceID: workspaceID)),
            workspaceLabel: workspaceLabel,
            repositoryCheckout: nil)
    }

    /// An Agent living in one of the Host's known workspaces, carrying that
    /// workspace's id and label exactly as the snapshot projection does.
    private func consoleAgent(
        host: Host,
        paneID: String,
        status: AgentStatus,
        in workspace: ConsoleWorkspace
    ) -> ConsoleAgent {
        consoleAgent(
            host: host, paneID: paneID, status: status,
            workspaceID: workspace.id, workspaceLabel: workspace.label)
    }

    private func checkout(
        repo: String, path: String? = nil, isLinkedWorktree: Bool = false
    ) -> RepositoryCheckout {
        RepositoryCheckout(
            repoKey: "/src/\(repo)/.git", repoName: repo, repoRoot: "/src/\(repo)",
            checkoutPath: path ?? "/src/\(repo)", isLinkedWorktree: isLinkedWorktree)
    }

    // MARK: Held open Agent

    @Test func anOpenedAgentKeepsItsPlaceAndPillWhenItsStatusChanges() {
        let host = Host.fixture(name: "alpha")
        let blocked = consoleAgent(host: host, paneID: "blocked", status: .blocked)
        let opened = consoleAgent(host: host, paneID: "opened", status: .done)
        let working = consoleAgent(host: host, paneID: "working", status: .working)
        let idle = consoleAgent(host: host, paneID: "idle", status: .idle)
        // Opening a Done Agent turns it Idle live.
        let nowIdle = consoleAgent(host: host, paneID: "opened", status: .idle)
        let live = [blocked, nowIdle, working, idle]

        #expect(live.consoleSorted().map(\.agent.paneID) == ["blocked", "working", "idle", "opened"])
        let heldOrder = live.consoleSorted(sortAs: { $0.id == opened.id ? opened : $0 })
        #expect(heldOrder.map(\.agent.paneID) == ["blocked", "opened", "working", "idle"])

        #expect(
            ConsoleListProjection.visibleAgents(
                workspaceAgents: heldOrder, status: .attention, searchQuery: "", held: opened
            ).map(\.agent.paneID) == ["blocked", "opened"])
        #expect(
            ConsoleListProjection.visibleAgents(
                workspaceAgents: heldOrder, status: .attention, searchQuery: ""
            ).map(\.agent.paneID) == ["blocked"])
        #expect(ConsoleListProjection.statusCounts(heldOrder, held: opened)[.done] == 1)
    }

    // MARK: Host scope

    @Test func effectiveHostIDHonorsOnlyAKnownChoice() {
        let alpha = Host.fixture(name: "alpha")
        let beta = Host.fixture(name: "beta")

        #expect(ConsoleListProjection.effectiveHostID(beta.id, hosts: [alpha, beta]) == beta.id)
        #expect(ConsoleListProjection.effectiveHostID(nil, hosts: [alpha, beta]) == nil)
        // A Host removed from the catalog no longer scopes the list.
        #expect(ConsoleListProjection.effectiveHostID(UUID(), hosts: [alpha, beta]) == nil)
        // A single Host is offered in the Host menu too, so choosing it scopes the list.
        #expect(ConsoleListProjection.effectiveHostID(alpha.id, hosts: [alpha]) == alpha.id)
    }

    @Test func hostScopePreservesTheSuppliedAgentOrder() {
        let hostA = Host.fixture(name: "alpha")
        let hostB = Host.fixture(name: "beta")
        let agents = [
            consoleAgent(host: hostA, paneID: "opaque-A", status: .idle),
            consoleAgent(host: hostB, paneID: "%opaque-B", status: .blocked),
            consoleAgent(host: hostA, paneID: "opaque-C", status: .done),
            consoleAgent(host: hostB, paneID: "opaque-D", status: .working),
        ]

        #expect(
            ConsoleListProjection.scopedAgents(agents, hostID: hostA.id).map(\.agent.paneID)
                == ["opaque-A", "opaque-C"])
        #expect(
            ConsoleListProjection.scopedAgents(agents, hostID: hostB.id).map(\.agent.paneID)
                == ["%opaque-B", "opaque-D"])
        #expect(ConsoleListProjection.scopedAgents(agents, hostID: nil) == agents)
    }

    // MARK: Workspace options

    @Test func allWorkspacesLeadsAndAVanishedWorkspaceFallsBackToAll() {
        let host = Host.fixture(name: "alpha")
        let app = ConsoleWorkspace(id: "w1", label: "App")
        let payments = ConsoleWorkspace(id: "w2", label: "Payments")
        let agents = [
            consoleAgent(host: host, paneID: "pay-1", status: .blocked, in: payments),
            consoleAgent(host: host, paneID: "app-1", status: .working, in: app),
        ]
        let options = ConsoleListProjection.workspaceOptions(
            hosts: [host], agents: agents,
            workspacesByHost: [host.id: [app, payments]], hostID: nil)

        #expect(options.map(\.id) == [
            .all, .group(host.id, .workspace("w1")), .group(host.id, .workspace("w2")),
        ])
        #expect(options.map(\.title) == [ConsoleWorkspaceOption.allTitle, "App", "Payments"])
        #expect(options[0].agents.map(\.agent.paneID) == ["pay-1", "app-1"])

        let paymentsID = ConsoleWorkspaceOption.ID.group(host.id, .workspace("w2"))
        #expect(ConsoleListProjection.effectiveWorkspaceID(paymentsID, in: options) == paymentsID)
        #expect(
            ConsoleListProjection.workspaceAgents(options: options, selected: paymentsID)
                .map(\.agent.paneID) == ["pay-1"])

        // The Payments Agent leaves: its entry goes, and the list falls back
        // to All Workspaces rather than stranding an empty selection.
        let after = ConsoleListProjection.workspaceOptions(
            hosts: [host], agents: [agents[1]],
            workspacesByHost: [host.id: [app, payments]], hostID: nil)
        #expect(after.map(\.title) == [ConsoleWorkspaceOption.allTitle, "App"])
        #expect(ConsoleListProjection.effectiveWorkspaceID(paymentsID, in: after) == .all)
        #expect(
            ConsoleListProjection.workspaceAgents(options: after, selected: paymentsID)
                .map(\.agent.paneID) == ["app-1"])
    }

    @Test func worktreeAgentsCountInTheirParentRepoWorkspace() {
        let host = Host.fixture(name: "alpha")
        let main = ConsoleWorkspace(id: "w11", label: "Waycar", checkout: checkout(repo: "Heeler"))
        let testflight = ConsoleWorkspace(
            id: "w1D", label: "testflight",
            checkout: checkout(
                repo: "Heeler", path: "/src/Heeler/testflight", isLinkedWorktree: true))
        let notes = ConsoleWorkspace(id: "w2", label: "Notes")
        let agents = [
            consoleAgent(host: host, paneID: "a-tf", status: .blocked, in: testflight),
            consoleAgent(host: host, paneID: "a-notes", status: .idle, in: notes),
            consoleAgent(host: host, paneID: "a-main", status: .idle, in: main),
        ]

        let options = ConsoleListProjection.workspaceOptions(
            hosts: [host], agents: agents,
            workspacesByHost: [host.id: [main, testflight, notes]], hostID: nil)

        // The worktree is no entry of its own; its Agents ride in the repo's
        // entry, in ConsoleStore's order.
        #expect(options.map(\.title) == [ConsoleWorkspaceOption.allTitle, "Waycar", "Notes"])
        #expect(options[1].id == .group(host.id, .workspace("w11")))
        #expect(options[1].agents.map(\.agent.paneID) == ["a-tf", "a-main"])
        #expect(options[2].agents.map(\.agent.paneID) == ["a-notes"])
    }

    @Test func sameLabelOnSeveralHostsGainsTheHostName() {
        let hostA = Host.fixture(name: "alpha")
        let hostB = Host.fixture(name: "beta")
        let appA = ConsoleWorkspace(id: "w1", label: "App")
        let notesA = ConsoleWorkspace(id: "w2", label: "Notes")
        let appB = ConsoleWorkspace(id: "w9", label: "App")
        let agents = [
            consoleAgent(host: hostB, paneID: "b-app", status: .working, in: appB),
            consoleAgent(host: hostA, paneID: "a-notes", status: .idle, in: notesA),
            consoleAgent(host: hostA, paneID: "a-app", status: .done, in: appA),
        ]
        let workspacesByHost = [hostA.id: [appA, notesA], hostB.id: [appB]]

        // Host entries follow catalog order, not the Agent order.
        let options = ConsoleListProjection.workspaceOptions(
            hosts: [hostA, hostB], agents: agents,
            workspacesByHost: workspacesByHost, hostID: nil)
        #expect(options.map(\.id) == [
            .all, .group(hostA.id, .workspace("w1")), .group(hostA.id, .workspace("w2")),
            .group(hostB.id, .workspace("w9")),
        ])
        #expect(options.map(\.title) == [
            ConsoleWorkspaceOption.allTitle, "App · alpha", "Notes", "App · beta",
        ])
        #expect(options[1].agents.map(\.agent.paneID) == ["a-app"])
        #expect(options[3].agents.map(\.agent.paneID) == ["b-app"])

        // Scoped to one Host, the label is unambiguous again.
        let scoped = ConsoleListProjection.workspaceOptions(
            hosts: [hostA, hostB], agents: agents,
            workspacesByHost: workspacesByHost, hostID: hostA.id)
        #expect(scoped.map(\.title) == [ConsoleWorkspaceOption.allTitle, "App", "Notes"])
    }

    @Test func hostScopeLimitsEveryWorkspaceOption() {
        let hostA = Host.fixture(name: "alpha")
        let hostB = Host.fixture(name: "beta")
        let app = ConsoleWorkspace(id: "w1", label: "App")
        let payments = ConsoleWorkspace(id: "w2", label: "Payments")
        let agents = [
            consoleAgent(host: hostA, paneID: "a-pay-1", status: .blocked, in: payments),
            consoleAgent(host: hostB, paneID: "b-app-1", status: .working, in: app),
            consoleAgent(host: hostA, paneID: "a-app-1", status: .done, in: app),
            consoleAgent(host: hostB, paneID: "b-pay-1", status: .idle, in: payments),
            consoleAgent(host: hostA, paneID: "a-pay-2", status: .working, in: payments),
        ]

        let options = ConsoleListProjection.workspaceOptions(
            hosts: [hostA, hostB], agents: agents,
            workspacesByHost: [hostA.id: [app, payments], hostB.id: [app, payments]],
            hostID: hostB.id)

        #expect(options.map(\.id) == [
            .all, .group(hostB.id, .workspace("w1")), .group(hostB.id, .workspace("w2")),
        ])
        #expect(options[0].agents.map(\.agent.paneID) == ["b-app-1", "b-pay-1"])
        #expect(options[1].agents.map(\.agent.paneID) == ["b-app-1"])
        #expect(options[2].agents.map(\.agent.paneID) == ["b-pay-1"])
    }

    @Test func workspaceOptionsListAWorkspaceWhateverItsAgentsAreDoing() {
        let host = Host.fixture(name: "alpha")
        let app = ConsoleWorkspace(id: "w1", label: "App")
        let calm = ConsoleWorkspace(id: "w2", label: "Calm")
        let agents = [
            consoleAgent(host: host, paneID: "app-blocked", status: .blocked, in: app),
            consoleAgent(host: host, paneID: "calm-idle", status: .idle, in: calm),
        ]

        let options = ConsoleListProjection.workspaceOptions(
            hosts: [host], agents: agents, workspacesByHost: [host.id: [app, calm]], hostID: nil)
        #expect(options.map(\.title) == [ConsoleWorkspaceOption.allTitle, "App", "Calm"])

        // Choosing Calm under the Blocked pill shows nothing — the entry
        // stays, the Status filter empties it.
        let calmAgents = ConsoleListProjection.workspaceAgents(
            options: options, selected: .group(host.id, .workspace("w2")))
        #expect(calmAgents.map(\.agent.paneID) == ["calm-idle"])
        #expect(
            ConsoleListProjection.visibleAgents(
                workspaceAgents: calmAgents, status: .blocked, searchQuery: ""
            ).isEmpty)
    }

    @Test func agentlessHostsProjectOnlyAll() {
        let empty = Host.fixture(name: "empty")

        let options = ConsoleListProjection.workspaceOptions(
            hosts: [empty], agents: [],
            workspacesByHost: [empty.id: [ConsoleWorkspace(id: "w1", label: "App")]],
            hostID: nil)
        #expect(options.map(\.id) == [.all])
        #expect(options[0].agents.isEmpty)
    }

    // MARK: Status and search

    private func shellRow(host: Host, paneID: String, workspaceID: String) -> ConsoleAgent {
        ConsoleAgent(
            hostID: host.id,
            hostName: host.displayName,
            agent: Agent(
                shellPane: PaneInfo(
                    agentStatus: .unknown, focused: false, paneID: paneID, revision: 1,
                    tabID: "\(workspaceID):t1", terminalID: "term-\(paneID)",
                    workspaceID: workspaceID, cwd: "/srv/app"),
                name: "Default Shell"),
            workspaceLabel: "Scratch",
            repositoryCheckout: nil)
    }

    @Test func statusFilterKeepsOnlyMatchingAgentsAndAllKeepsIdleAndShells() {
        let host = Host.fixture(name: "alpha")
        let agents = [
            consoleAgent(host: host, paneID: "idle", status: .idle),
            consoleAgent(host: host, paneID: "working", status: .working),
            consoleAgent(host: host, paneID: "blocked", status: .blocked),
            shellRow(host: host, paneID: "shell", workspaceID: "w1"),
            consoleAgent(host: host, paneID: "done", status: .done),
            consoleAgent(host: host, paneID: "blocked-2", status: .blocked),
        ]
        func visible(_ status: ConsoleStatusFilter) -> [String] {
            ConsoleListProjection.visibleAgents(
                workspaceAgents: agents, status: status, searchQuery: ""
            ).map(\.agent.paneID)
        }

        #expect(visible(.all) == ["idle", "working", "blocked", "shell", "done", "blocked-2"])
        #expect(visible(.attention) == ["blocked", "done", "blocked-2"])
        #expect(visible(.blocked) == ["blocked", "blocked-2"])
        #expect(visible(.done) == ["done"])
        #expect(visible(.working) == ["working"])
    }

    @Test func shellsNeverMatchAStatusPill() {
        let host = Host.fixture(name: "alpha")
        // A shell row whose Agent carries a real status still belongs only
        // under All: it is not an Agent the Status pills describe.
        let shellWorking = ConsoleAgent(
            hostID: host.id,
            hostName: host.displayName,
            agent: Agent(
                terminalID: "term-shell", kind: Agent.shellKind, title: "zsh", status: .working,
                workspaceID: "w1", tabID: "w1:t1", paneID: "shell", cwd: "/srv", revision: 1),
            workspaceLabel: nil,
            repositoryCheckout: nil)

        #expect(ConsoleStatusFilter.all.matches(shellWorking))
        for filter in ConsoleStatusFilter.allCases where filter != .all {
            #expect(!filter.matches(shellWorking), "\(filter)")
        }
    }

    // MARK: Chat pill

    @Test func chatPillListsExactlyTheChatModeAgentsInStoreOrderAndNeverAShell() {
        let host = Host.fixture(name: "alpha")
        let agents = [
            consoleAgent(host: host, paneID: "blocked-chat", status: .blocked),
            consoleAgent(host: host, paneID: "working", status: .working),
            shellRow(host: host, paneID: "shell", workspaceID: "w1"),
            consoleAgent(host: host, paneID: "idle-chat", status: .idle),
            consoleAgent(host: host, paneID: "done", status: .done),
        ]
        let outOfScope = consoleAgent(host: host, paneID: "elsewhere", status: .working)
        let chatIDs = Set(
            agents.filter { ["blocked-chat", "shell", "idle-chat"].contains($0.agent.paneID) }
                .map(\.id) + [outOfScope.id])

        #expect(
            ConsoleListProjection.visibleAgents(
                workspaceAgents: agents, status: .chat, searchQuery: "", chatAgentIDs: chatIDs
            ).map(\.agent.paneID) == ["blocked-chat", "idle-chat"])
        #expect(
            ConsoleListProjection.visibleAgents(
                workspaceAgents: agents, status: .chat, searchQuery: ""
            ).isEmpty, "no Chat Mode Agents, nothing under Chat")
    }

    @Test func chatPillCountsChatModeAgentsWhichStillCountUnderTheirStatusAndAll() {
        let host = Host.fixture(name: "alpha")
        let blockedChat = consoleAgent(host: host, paneID: "blocked-chat", status: .blocked)
        let workingChat = consoleAgent(host: host, paneID: "working-chat", status: .working)
        let agents = [
            blockedChat,
            workingChat,
            consoleAgent(host: host, paneID: "working", status: .working),
            shellRow(host: host, paneID: "shell", workspaceID: "w1"),
        ]
        let counts = ConsoleListProjection.statusCounts(
            agents, chatAgentIDs: [blockedChat.id, workingChat.id, agents[3].id])

        #expect(counts[.chat] == 2)
        #expect(counts[.all] == 4)
        #expect(counts[.blocked] == 1)
        #expect(counts[.attention] == 1)
        #expect(counts[.working] == 2)
        #expect(ConsoleListProjection.statusCounts(agents)[.chat] == 0, "always offered at zero")
    }

    @Test func statusCountsCoverTheSelectedWorkspace() {
        let host = Host.fixture(name: "alpha")
        let app = ConsoleWorkspace(id: "w1", label: "App")
        let other = ConsoleWorkspace(id: "w2", label: "Other")
        let agents = [
            consoleAgent(host: host, paneID: "app-blocked", status: .blocked, in: app),
            consoleAgent(host: host, paneID: "other-blocked", status: .blocked, in: other),
            consoleAgent(host: host, paneID: "app-done", status: .done, in: app),
            consoleAgent(host: host, paneID: "app-idle", status: .idle, in: app),
            shellRow(host: host, paneID: "app-shell", workspaceID: "w1"),
            consoleAgent(host: host, paneID: "app-done-2", status: .done, in: app),
        ]
        let options = ConsoleListProjection.workspaceOptions(
            hosts: [host], agents: agents, workspacesByHost: [host.id: [app, other]], hostID: nil)
        let appAgents = ConsoleListProjection.workspaceAgents(
            options: options, selected: .group(host.id, .workspace("w1")))

        #expect(appAgents.count == 5)
        #expect(
            ConsoleListProjection.statusCounts(appAgents)
                == [.all: 5, .chat: 0, .attention: 3, .blocked: 1, .done: 2, .working: 0])
        #expect(
            ConsoleListProjection.statusCounts(options[0].agents)
                == [.all: 6, .chat: 0, .attention: 4, .blocked: 2, .done: 2, .working: 0])
    }

    @Test func searchIgnoresStatusButRespectsTheSelectedWorkspace() {
        let hostA = Host.fixture(name: "alpha")
        let hostB = Host.fixture(name: "beta")
        let app = ConsoleWorkspace(id: "w1", label: "App")
        let payments = ConsoleWorkspace(id: "w2", label: "Payments")
        let agents = [
            consoleAgent(host: hostA, paneID: "a-pay", status: .blocked, in: payments),
            consoleAgent(host: hostB, paneID: "b-app", status: .working, in: app),
            consoleAgent(host: hostA, paneID: "a-app-idle", status: .idle, in: app),
            consoleAgent(host: hostA, paneID: "a-app-blocked", status: .blocked, in: app),
        ]
        let options = ConsoleListProjection.workspaceOptions(
            hosts: [hostA, hostB], agents: agents,
            workspacesByHost: [hostA.id: [app, payments], hostB.id: [app, payments]],
            hostID: nil)
        let appOnAlpha = ConsoleListProjection.workspaceAgents(
            options: options, selected: .group(hostA.id, .workspace("w1")))
        func visible(_ status: ConsoleStatusFilter, _ query: String) -> [String] {
            ConsoleListProjection.visibleAgents(
                workspaceAgents: appOnAlpha, status: status, searchQuery: query
            ).map(\.agent.paneID)
        }

        #expect(visible(.blocked, "") == ["a-app-blocked"])
        // Every fixture Agent is a "claude": the search matches all of them,
        // but only within the chosen Workspace and Host, and whatever the
        // Status pill says.
        #expect(visible(.blocked, " CLAUDE ") == ["a-app-idle", "a-app-blocked"])
        #expect(visible(.done, "absent").isEmpty)
        // A blank query leaves the Status filter in charge.
        #expect(visible(.done, "   ").isEmpty)
    }

    @Test func hostWithOnlyAShellPaneListsItAsACard() {
        let host = Host.fixture(name: "alpha")
        let shell = shellRow(host: host, paneID: "w1:p1", workspaceID: "w1")

        let options = ConsoleListProjection.workspaceOptions(
            hosts: [host], agents: [shell],
            workspacesByHost: [host.id: [ConsoleWorkspace(id: "w1", label: "Scratch")]],
            hostID: nil)
        #expect(options.map(\.title) == [ConsoleWorkspaceOption.allTitle, "Scratch"])
        #expect(options[1].agents.map(\.id) == [shell.id])
        // A shell has no Agent Status: it counts only under All.
        #expect(
            ConsoleListProjection.statusCounts(options[1].agents)
                == [.all: 1, .chat: 0, .attention: 0, .blocked: 0, .done: 0, .working: 0])
    }

    // MARK: Workspace grouping

    @Test func workspaceGroupsFollowKnownOrderAndPreserveAgentOrder() {
        let host = Host.fixture(name: "alpha")
        let app = ConsoleWorkspace(id: "w1", label: "App")
        let payments = ConsoleWorkspace(id: "w2", label: "Payments")
        // The incoming (already-sorted) sequence interleaves workspaces;
        // each group must preserve the exact relative Agent order without
        // re-sorting.
        let agents = [
            consoleAgent(host: host, paneID: "pay-1", status: .blocked, in: payments),
            consoleAgent(host: host, paneID: "app-1", status: .done, in: app),
            consoleAgent(host: host, paneID: "pay-2", status: .working, in: payments),
            consoleAgent(host: host, paneID: "app-2", status: .idle, in: app),
        ]

        let groups = ConsoleListProjection.workspaceGroups(
            for: agents, workspaces: [app, payments])
        #expect(groups.map(\.label) == ["App", "Payments"])
        #expect(groups.map(\.workspaceID) == ["w1", "w2"])
        #expect(groups[0].agents.map(\.agent.paneID) == ["app-1", "app-2"])
        #expect(groups[1].agents.map(\.agent.paneID) == ["pay-1", "pay-2"])
    }

    @Test func linkedWorktreeWorkspacesNestUnderTheirReposMainWorkspace() {
        let host = Host.fixture(name: "alpha")
        // Live snapshot shape: one repo (Heeler) with the main checkout's
        // workspace and two linked-worktree workspaces.
        let main = ConsoleWorkspace(id: "w11", label: "Waycar", checkout: checkout(repo: "Heeler"))
        let testflight = ConsoleWorkspace(
            id: "w1D", label: "testflight",
            checkout: checkout(
                repo: "Heeler", path: "/src/Heeler/testflight", isLinkedWorktree: true))
        let index = ConsoleWorkspace(
            id: "w1E", label: "index-worktree",
            checkout: checkout(
                repo: "Heeler", path: "/src/Heeler/index-worktree", isLinkedWorktree: true))
        let agents = [
            consoleAgent(host: host, paneID: "a-index", status: .working, in: index),
            consoleAgent(host: host, paneID: "a-main", status: .idle, in: main),
            consoleAgent(host: host, paneID: "a-tf", status: .blocked, in: testflight),
        ]

        let groups = ConsoleListProjection.workspaceGroups(
            for: agents, workspaces: [main, testflight, index])
        // Worktree workspaces are children of the main-checkout workspace,
        // not sibling top-level groups.
        #expect(groups.map(\.label) == ["Waycar"])
        #expect(groups[0].agents.map(\.agent.paneID) == ["a-main"])
        #expect(groups[0].worktrees.map(\.label) == ["testflight", "index-worktree"])
        #expect(groups[0].worktrees[0].agents.map(\.agent.paneID) == ["a-tf"])
        #expect(groups[0].worktrees[1].agents.map(\.agent.paneID) == ["a-index"])
    }

    @Test func topLevelGroupsFollowTheHostWorkspaceOrder() {
        let host = Host.fixture(name: "alpha")
        // Host order: an orphan linked worktree (its repo's main checkout is
        // not open), a child worktree listed BEFORE its parent, a
        // checkout-less workspace, then that child's main checkout.
        let orphan = ConsoleWorkspace(
            id: "w1", label: "alpha-wt",
            checkout: checkout(repo: "alpha", path: "/src/alpha/wt", isLinkedWorktree: true))
        let child = ConsoleWorkspace(
            id: "w2", label: "beta-wt",
            checkout: checkout(repo: "beta", path: "/src/beta/wt", isLinkedWorktree: true))
        let notes = ConsoleWorkspace(id: "w3", label: "Notes")
        let main = ConsoleWorkspace(id: "w4", label: "beta", checkout: checkout(repo: "beta"))

        let groups = ConsoleListProjection.workspaceGroups(
            for: [
                consoleAgent(host: host, paneID: "main", status: .working, in: main),
                consoleAgent(host: host, paneID: "child", status: .working, in: child),
                consoleAgent(host: host, paneID: "notes", status: .working, in: notes),
                consoleAgent(host: host, paneID: "orphan", status: .working, in: orphan),
            ],
            workspaces: [orphan, child, notes, main])

        #expect(groups.map(\.id) == [.workspace("w1"), .workspace("w3"), .workspace("w4")])
        #expect(groups.map { $0.agents.map(\.agent.paneID) } == [["orphan"], ["notes"], ["main"]])
        #expect(groups.map { $0.worktrees.map(\.id) } == [[], [], [.workspace("w2")]])
        #expect(groups[2].worktrees[0].agents.map(\.agent.paneID) == ["child"])
    }

    @Test func sameLabelMainWorkspaceOnAnotherRepoCannotCaptureWorktrees() {
        let host = Host.fixture(name: "alpha")
        // Two repos both have a main-checkout workspace labeled "main"; the
        // second repo's worktree must nest under ITS repo's workspace, and
        // neither same-label workspace may show the other's Agents.
        let firstMain = ConsoleWorkspace(id: "wA", label: "main", checkout: checkout(repo: "first"))
        let secondMain = ConsoleWorkspace(
            id: "wB", label: "main", checkout: checkout(repo: "second"))
        let secondWorktree = ConsoleWorkspace(
            id: "wC", label: "wt",
            checkout: checkout(repo: "second", path: "/src/second/wt", isLinkedWorktree: true))
        let workspaces = [firstMain, secondMain, secondWorktree]
        let agents = [
            consoleAgent(host: host, paneID: "a-1", status: .working, in: firstMain),
            consoleAgent(host: host, paneID: "a-2", status: .working, in: secondWorktree),
        ]

        let groups = ConsoleListProjection.workspaceGroups(for: agents, workspaces: workspaces)
        #expect(groups.map(\.id) == [.workspace("wA"), .workspace("wB")])
        #expect(groups[0].agents.map(\.agent.paneID) == ["a-1"])
        #expect(groups[0].worktrees.isEmpty)
        #expect(groups[1].agents.isEmpty)
        #expect(groups[1].worktrees.map(\.label) == ["wt"])
        #expect(groups[1].worktrees[0].agents.map(\.agent.paneID) == ["a-2"])

        // The same-label entries stay distinct and hold only their own Agents.
        let options = ConsoleListProjection.workspaceOptions(
            hosts: [host], agents: agents, workspacesByHost: [host.id: workspaces], hostID: nil)
        #expect(options.map(\.title) == [ConsoleWorkspaceOption.allTitle, "main", "main"])
        #expect(options.map { $0.agents.map(\.agent.paneID) } == [["a-1", "a-2"], ["a-1"], ["a-2"]])
    }

    @Test func sameLabelLinkedWorktreesInTwoReposHoldOnlyTheirOwnAgents() {
        let host = Host.fixture(name: "alpha")
        let mainA = ConsoleWorkspace(id: "wA", label: "A", checkout: checkout(repo: "A"))
        let featureA = ConsoleWorkspace(
            id: "wAF", label: "feature",
            checkout: checkout(repo: "A", path: "/src/A/feature", isLinkedWorktree: true))
        let mainB = ConsoleWorkspace(id: "wB", label: "B", checkout: checkout(repo: "B"))
        let featureB = ConsoleWorkspace(
            id: "wBF", label: "feature",
            checkout: checkout(repo: "B", path: "/src/B/feature", isLinkedWorktree: true))
        let agents = [
            consoleAgent(host: host, paneID: "b-1", status: .working, in: featureB),
            consoleAgent(host: host, paneID: "a-1", status: .working, in: featureA),
            consoleAgent(host: host, paneID: "b-2", status: .blocked, in: featureB),
        ]

        let groups = ConsoleListProjection.workspaceGroups(
            for: agents, workspaces: [mainA, featureA, mainB, featureB])
        #expect(groups.map(\.id) == [.workspace("wA"), .workspace("wB")])
        #expect(groups.map { $0.worktrees.map(\.id) } == [[.workspace("wAF")], [.workspace("wBF")]])
        #expect(groups[0].worktrees[0].agents.map(\.agent.paneID) == ["a-1"])
        #expect(groups[1].worktrees[0].agents.map(\.agent.paneID) == ["b-1", "b-2"])
    }

    @Test func onlyTheFirstMainWorkspaceOfARepoParentsItsWorktrees() {
        let host = Host.fixture(name: "alpha")
        // Two workspaces sit on Heeler's main checkout; only the first in
        // Host order parents the tree.
        let first = ConsoleWorkspace(id: "wM1", label: "Heeler", checkout: checkout(repo: "Heeler"))
        let second = ConsoleWorkspace(
            id: "wM2", label: "Heeler scratch", checkout: checkout(repo: "Heeler"))
        let worktree = ConsoleWorkspace(
            id: "wT", label: "testflight",
            checkout: checkout(repo: "Heeler", path: "/src/Heeler/tf", isLinkedWorktree: true))
        let workspaces = [first, second, worktree]
        #expect(
            ConsoleListProjection.parentWorkspace(
                forRepoKey: checkout(repo: "Heeler").repoKey, in: workspaces) == first)

        // Both mains agentless: one parent group, holding the worktree; the
        // second main never projects an empty group.
        var groups = ConsoleListProjection.workspaceGroups(
            for: [consoleAgent(host: host, paneID: "tf", status: .working, in: worktree)],
            workspaces: workspaces)
        #expect(groups.map(\.id) == [.workspace("wM1")])
        #expect(groups[0].agents.isEmpty)
        #expect(groups[0].worktrees.map(\.id) == [.workspace("wT")])

        // The second main with Agents is a plain group, never a parent.
        groups = ConsoleListProjection.workspaceGroups(
            for: [
                consoleAgent(host: host, paneID: "tf", status: .working, in: worktree),
                consoleAgent(host: host, paneID: "scratch", status: .idle, in: second),
            ],
            workspaces: workspaces)
        #expect(groups.map(\.id) == [.workspace("wM1"), .workspace("wM2")])
        #expect(groups[0].worktrees.map(\.id) == [.workspace("wT")])
        #expect(groups[1].agents.map(\.agent.paneID) == ["scratch"])
        #expect(groups[1].worktrees.isEmpty)
    }

    @Test func worktreeWithoutAMainCheckoutWorkspaceStaysTopLevel() {
        let host = Host.fixture(name: "alpha")
        // Only the linked worktree is known to the Host (its main checkout
        // workspace is closed): no parent to nest under.
        let worktree = ConsoleWorkspace(
            id: "w1E", label: "index-worktree",
            checkout: checkout(
                repo: "Heeler", path: "/src/Heeler/index-worktree", isLinkedWorktree: true))

        let groups = ConsoleListProjection.workspaceGroups(
            for: [consoleAgent(host: host, paneID: "a-1", status: .working, in: worktree)],
            workspaces: [worktree])
        #expect(groups.map(\.label) == ["index-worktree"])
        #expect(groups[0].worktrees.isEmpty)
        #expect(groups[0].agents.map(\.agent.paneID) == ["a-1"])
    }

    @Test func agentlessMainWorkspaceStillParentsItsWorktrees() {
        let host = Host.fixture(name: "alpha")
        let main = ConsoleWorkspace(id: "w11", label: "Waycar", checkout: checkout(repo: "Heeler"))
        let worktree = ConsoleWorkspace(
            id: "w1D", label: "testflight",
            checkout: checkout(
                repo: "Heeler", path: "/src/Heeler/testflight", isLinkedWorktree: true))

        let groups = ConsoleListProjection.workspaceGroups(
            for: [consoleAgent(host: host, paneID: "a-tf", status: .working, in: worktree)],
            workspaces: [main, worktree])
        // The main workspace has no Agents of its own but still parents its
        // worktree so the tree stays rooted at the repo.
        #expect(groups.map(\.label) == ["Waycar"])
        #expect(groups[0].agents.isEmpty)
        #expect(groups[0].worktrees.map(\.label) == ["testflight"])
    }

    @Test func unknownWorkspaceAgentsFallIntoTheFinalBucket() {
        let host = Host.fixture(name: "alpha")
        let app = ConsoleWorkspace(id: "w1", label: "App")
        let agents = [
            consoleAgent(
                host: host, paneID: "no-workspace", status: .working,
                workspaceID: "w-gone", workspaceLabel: nil),
            consoleAgent(
                host: host, paneID: "orphan", status: .done,
                workspaceID: "w-gone", workspaceLabel: "Orphaned"),
            consoleAgent(host: host, paneID: "known", status: .idle, in: app),
            consoleAgent(
                host: host, paneID: "blank", status: .blocked,
                workspaceID: "w-gone", workspaceLabel: ""),
        ]

        let groups = ConsoleListProjection.workspaceGroups(for: agents, workspaces: [app])
        #expect(groups.map(\.label) == ["App", "Orphaned", "Unassigned"])
        #expect(groups.map(\.id) == [.workspace("w1"), .label("Orphaned"), .unassigned])
        #expect(groups.map(\.workspaceID) == ["w1", nil, nil])
        #expect(groups[0].agents.map(\.agent.paneID) == ["known"])
        #expect(groups[1].agents.map(\.agent.paneID) == ["orphan"])
        #expect(groups[2].agents.map(\.agent.paneID) == ["no-workspace", "blank"])
    }

    // MARK: Closed Sessions

    @Test func theClosedPillListsOnlyClosedSessions() {
        let host = Host.fixture(name: "alpha")
        let closed = [
            ClosedSession.fixture(hostID: host.id, terminalID: "t1"),
            ClosedSession.fixture(hostID: host.id, terminalID: "t2"),
        ]
        let agents = [
            consoleAgent(host: host, paneID: "w", status: .working),
            consoleAgent(host: host, paneID: "i", status: .idle),
        ]

        #expect(
            ConsoleListProjection.visibleClosedSessions(
                closed, status: .closed, searchQuery: "", hostNames: [:]) == closed)
        #expect(
            ConsoleListProjection.visibleAgents(
                workspaceAgents: agents, status: .closed, searchQuery: ""
            ).isEmpty, "no live Agent under Closed")
        for status in ConsoleStatusFilter.allCases where status != .closed {
            #expect(
                ConsoleListProjection.visibleClosedSessions(
                    closed, status: status, searchQuery: "", hostNames: [:]
                ).isEmpty, "\(status.title) hides closed rows")
        }
    }

    @Test func aSearchFindsClosedSessionsWhateverThePill() {
        let host = Host.fixture(name: "alpha")
        let deploy = ClosedSession.fixture(hostID: host.id, title: "Deploy", terminalID: "t1")
        let other = ClosedSession.fixture(hostID: host.id, title: "Refactor", terminalID: "t2")

        for status in ConsoleStatusFilter.allCases {
            #expect(
                ConsoleListProjection.visibleClosedSessions(
                    [deploy, other], status: status, searchQuery: " deploy ",
                    hostNames: [host.id: "alpha"]
                ) == [deploy])
        }
    }

    @Test func closedSessionsFollowTheHostAndWorkspaceScope() {
        let alpha = Host.fixture(name: "alpha")
        let beta = Host.fixture(name: "beta")
        let main = ConsoleWorkspace(id: "w-main", label: "Waycar", checkout: checkout(repo: "waycar"))
        let worktree = ConsoleWorkspace(
            id: "w-tree", label: "fix-login",
            checkout: checkout(repo: "waycar", path: "/src/wt", isLinkedWorktree: true))
        let inMain = ClosedSession.fixture(
            hostID: alpha.id, workspaceID: "w-main", workspaceLabel: "Waycar", terminalID: "t1")
        let inWorktree = ClosedSession.fixture(
            hostID: alpha.id, workspaceID: "w-tree", workspaceLabel: "fix-login",
            terminalID: "t2")
        let labelOnly = ClosedSession.fixture(
            hostID: alpha.id, workspaceID: "w-gone", workspaceLabel: "Old", terminalID: "t3")
        let unassigned = ClosedSession.fixture(
            hostID: alpha.id, workspaceID: "w-gone", workspaceLabel: nil, terminalID: "t4")
        let onBeta = ClosedSession.fixture(hostID: beta.id, workspaceID: "w-main", terminalID: "t5")
        let all = [inMain, inWorktree, labelOnly, unassigned, onBeta]
        let workspaces = [alpha.id: [main, worktree], beta.id: [main]]

        func scoped(
            _ hostID: Host.ID?, _ workspace: ConsoleWorkspaceOption.ID,
            listing listed: Set<Host.ID>? = nil
        ) -> [ClosedSession] {
            ConsoleListProjection.scopedClosedSessions(
                all, listedHostIDs: listed ?? [alpha.id, beta.id], hostID: hostID,
                workspace: workspace, workspacesByHost: workspaces)
        }

        #expect(scoped(nil, .all) == all)
        #expect(scoped(beta.id, .all) == [onBeta])
        // A linked worktree's closed rows list under its repository's main
        // checkout, like its Agents.
        #expect(scoped(nil, .group(alpha.id, .workspace("w-main"))) == [inMain, inWorktree])
        #expect(scoped(nil, .group(beta.id, .workspace("w-main"))) == [onBeta])
        #expect(scoped(nil, .group(alpha.id, .label("Old"))) == [labelOnly])
        #expect(scoped(nil, .group(alpha.id, .unassigned)) == [unassigned])
        #expect(scoped(beta.id, .group(alpha.id, .workspace("w-main"))).isEmpty)
        // A Disabled Host is not listed: its closed rows hide under every
        // scope, while the listed Host's stay.
        #expect(scoped(nil, .all, listing: [alpha.id]) == [inMain, inWorktree, labelOnly, unassigned])
        #expect(scoped(nil, .group(beta.id, .workspace("w-main")), listing: [alpha.id]).isEmpty)
        #expect(scoped(nil, .all, listing: []).isEmpty)
    }
}

@Suite("Agent card presentation")
struct AgentCardPresentationTests {
    @Test func defaultsShowWorkspaceThenAgentWithoutTheOldDirectoryRow() {
        let card = AgentCardPresentation(agent: agent(workspace: "Project"))
        #expect(card.headline == "Project")
        #expect(card.additionalRows == ["reviewer"])
    }

    @Test func configuredTitlesAndPluginTextStayLiteralAndRetainStyles() throws {
        let layout = AgentRowLayout(rows: [
            [.init(.stateIcon), .init(.terminalTitleStripped, fg: HexColor("#abc"), bold: true)],
            [.init(.custom("note")), .init(.agent)],
        ])
        let card = AgentCardPresentation(agent: agent(), layout: layout)
        #expect(card.headline == "Task title")
        #expect(card.additionalRows == ["**literal** [link](url) · reviewer"])
        let first = try #require(card.rows.first?.first)
        #expect(first.fg == HexColor("#abc") && first.bold == true)
    }

    @Test func kindOverridesReplaceAllRowsAndSkipEmptyStatusRows() {
        let layout = AgentRowLayout(rows: [[.init(.workspace)]], rowsByAgent: [
            "claude": [[.init(.stateText)], [.init(.terminalTitle)], [.init(.custom("missing"))]],
        ])
        let card = AgentCardPresentation(agent: agent(), layout: layout)
        #expect(card.headline == "◑ Task title")
        #expect(card.additionalRows.isEmpty)
    }

    @Test func emptyLayoutsAndMissingValuesKeepAnIdentifiableAgent() {
        for layout in [AgentRowLayout(rows: []), AgentRowLayout(rows: [[], [.init(.custom("absent"))]])] {
            let card = AgentCardPresentation(agent: agent(), layout: layout)
            #expect(card.headline == "reviewer")
            #expect(card.additionalRows.isEmpty)
        }
        #expect(AgentCardPresentation(agent: agent()).headline == "reviewer")
    }

    @Test func runningShellShowsRunningAndItsCommand() throws {
        let presentation = try #require(ShellActivityPresentation(
            agent: shell(.running(command: "sudo apt update"))))
        #expect(presentation.statusText == "Running")
        #expect(presentation.commandText == "sudo apt update")
        #expect(presentation.accessibilityLabel == "Running sudo apt update")
    }

    @Test func idleUnknownShellsAndAgentRowsKeepTheirCardUnchanged() {
        #expect(ShellActivityPresentation(agent: shell(.idle)) == nil)
        #expect(ShellActivityPresentation(agent: shell(nil)) == nil)
        var agentRow = agent()
        agentRow.shellActivity = .running(command: "make")
        #expect(ShellActivityPresentation(agent: agentRow) == nil)
    }

    @Test func runningShellStillMatchesOnlyAllAndKeepsItsSortBucket() {
        let running = shell(.running(command: "sudo apt update"))
        let idle = shell(.idle)
        #expect(running.agent.status == .shellTerminal)
        #expect(running.agent.status.consoleSortBucket == idle.agent.status.consoleSortBucket)
        #expect(ConsoleStatusFilter.all.matches(running))
        for filter in ConsoleStatusFilter.allCases where filter != .all {
            #expect(!filter.matches(running), "\(filter)")
        }
    }

    private func shell(_ activity: ShellActivity?) -> ConsoleAgent {
        ConsoleAgent(
            hostID: UUID(), hostName: "devbox",
            agent: Agent(
                terminalID: "term-shell", kind: Agent.shellKind, title: "zsh", status: .shellTerminal,
                workspaceID: "w", tabID: "t", paneID: "shell", cwd: "/srv", revision: 1),
            workspaceLabel: nil, repositoryCheckout: nil, shellActivity: activity)
    }

    private func agent(workspace: String? = nil) -> ConsoleAgent {
        ConsoleAgent(
            hostID: UUID(), hostName: "devbox",
            agent: Agent(
                terminalID: "terminal", kind: "claude", title: "Old title", status: .blocked,
                workspaceID: "w", tabID: "t", paneID: "p", cwd: "/work/project", revision: 1,
                name: "reviewer", terminalTitle: "◑ Task title", terminalTitleStripped: "Task title",
                tokens: ["note": "**literal** [link](url)"]),
            workspaceLabel: workspace, repositoryCheckout: nil)
    }
}
