import Foundation
import Testing

@testable import Waycar

/// The New Chat quick action's sheet: it presets itself from the New Chat
/// defaults and starts once the Host is ready, or leaves the user to pick
/// with Chat Mode on.
@MainActor
@Suite("Start agent quick chat")
struct StartAgentQuickChatTests {
    private nonisolated static let prompt = "Reply briefly."

    /// Records the starts the store dispatches and plays a started Agent in
    /// `agentWorkspaceID`.
    @MainActor
    private final class Recorder {
        var requests: [AgentLaunchRequest] = []
        var destinations: [StartAgentStore.LaunchDestination] = []
        /// The backend each start named; nil lets the Console route by the
        /// Workspace's owner.
        var backends: [HostBackend?] = []
        var homeProbes = 0
        var agentWorkspaceID = "w1"
        /// The Host the launch writes its Chat Prompt to.
        let promptHost = FakeLaunchPromptHost()

        func start(
            _ request: AgentLaunchRequest, _ destination: StartAgentStore.LaunchDestination,
            backend: HostBackend? = nil
        ) -> Agent {
            requests.append(request)
            destinations.append(destination)
            backends.append(backend)
            return Agent(
                .fixture(
                    paneID: "\(agentWorkspaceID):pnew", status: .working,
                    workspaceID: agentWorkspaceID, kind: request.kind))
        }
    }

    private func makeDefaults() -> UserDefaults {
        let name = "start-agent-quick-chat-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func makeStore(
        host: Host,
        workspaces: [ConsoleWorkspace] = [
            ConsoleWorkspace(id: "w1", label: "Proj"), ConsoleWorkspace(id: "w2", label: "Other"),
        ],
        kinds: @escaping () async throws -> [SupportedAgentKind] = { [.codex, .claude] },
        quickChat: NewChatPreferences,
        defaults: UserDefaults,
        recorder: Recorder,
        hasLiveSnapshot: @escaping (Host.ID) -> Bool = { _ in true },
        pollInterval: Duration = .milliseconds(1),
        backends: [HostBackend] = [.herdr],
        defaultBackend: HostBackend = .herdr,
        liveWorkspaces: ((Host.ID) -> [ConsoleWorkspace])? = nil
    ) -> StartAgentStore {
        let recentsName = "start-agent-quick-chat-recents-\(UUID().uuidString)"
        let recentsDefaults = UserDefaults(suiteName: recentsName)!
        recentsDefaults.removePersistentDomain(forName: recentsName)
        return StartAgentStore(
            hosts: [Host.fixture(), host],
            workspaces: liveWorkspaces ?? { hostID in hostID == host.id ? workspaces : [] },
            existingAgentNames: { _ in [] },
            discoverAgentKinds: { _ in try await kinds() },
            remoteHome: { _ in
                recorder.homeProbes += 1
                return "/home/you"
            },
            start: { request, destination, _, backend in
                recorder.start(request, destination, backend: backend)
            },
            backends: { hostID in hostID == host.id ? backends : [.herdr] },
            defaultBackend: { hostID in hostID == host.id ? defaultBackend : .herdr },
            awaitAgentVisible: { _ in },
            recents: RecentWorkspaceStore(defaults: recentsDefaults),
            selections: RecentSelectionsStore(defaults: defaults),
            chatOptions: { _ in ChatModeLaunchOptions(prompt: Self.prompt, quickThinking: false) },
            launchPromptHost: { _ in recorder.promptHost.host },
            quickChat: quickChat,
            hasLiveSnapshot: hasLiveSnapshot,
            quickChatPollInterval: pollInterval)
    }

    /// New Chat defaults naming `destination` on its Host and claude.
    private func preferences(
        _ destination: ChatDestination, kind: SupportedAgentKind = .claude
    ) -> NewChatPreferences {
        NewChatPreferences(destination: destination, kind: kind)
    }

    @Test func aResolvablePlanStartsOnceAfterDiscoveryLoads() async throws {
        let host = Host.fixture()
        let defaults = makeDefaults()
        let recorder = Recorder()
        recorder.agentWorkspaceID = "w2"
        let discovery = ScriptedTransportCallGate()
        let hostState = HostState()
        hostState.isLive = true
        let store = makeStore(
            host: host,
            kinds: {
                await discovery.waitUntilOpen()
                return [.codex, .claude]
            },
            quickChat: preferences(
                ChatDestination(hostID: host.id, workspaceID: "w2", workspaceLabel: "Other", cwd: "/work/w2")),
            defaults: defaults, recorder: recorder,
            hasLiveSnapshot: { _ in hostState.checkLive() })
        #expect(store.isQuickChat)
        #expect(store.chatMode)
        #expect(store.selectedHostID == host.id, "the destination's Host is preselected")

        let run = Task { await store.runQuickChat() }
        let detecting = Task { await store.discoverAgents() }
        await discovery.waitForEntry()
        try await hostState.waitForLiveChecks(hostState.liveChecks + 6)
        #expect(recorder.requests.isEmpty, "nothing starts before discovery loads")

        await discovery.open()
        await detecting.value
        await run.value
        await store.runQuickChat()

        try #require(recorder.requests.count == 1)
        let request = try #require(recorder.requests.first)
        #expect(request.kind == "claude")
        #expect(request.workspaceID == "w2")
        #expect(recorder.destinations == [.existingWorkspace])
        #expect(request.arguments.first == "--append-system-prompt-file")
        #expect(request.arguments.dropFirst(2).first == "--session-id")
        #expect(await recorder.promptHost.stagedFiles.map(\.contents) == [Self.prompt])
        #expect(store.state == .started(ConsoleAgent.ID(hostID: host.id, paneID: "w2:pnew")))
        #expect(store.launchedChat)
        let selections = RecentSelectionsStore(defaults: defaults)
        #expect(!selections.chatMode, "quick chat leaves the sheet's Chat Mode choice alone")
        #expect(selections.lastChatKind == .claude)
    }

    @Test func aGoneWorkspaceWithADirectoryStartsInANewWorkspaceThere() async throws {
        let host = Host.fixture()
        let defaults = makeDefaults()
        let recorder = Recorder()
        recorder.agentWorkspaceID = "w9"
        let store = makeStore(
            host: host,
            quickChat: preferences(
                ChatDestination(hostID: host.id, workspaceID: "gone", workspaceLabel: "Old", cwd: "/srv/old")),
            defaults: defaults, recorder: recorder)
        await store.discoverAgents()
        await store.runQuickChat()

        let request = try #require(recorder.requests.first)
        #expect(recorder.requests.count == 1)
        #expect(request.workspaceID == nil)
        #expect(recorder.destinations == [.newWorkspace(NewWorkspaceSpec(directory: "/srv/old", label: "Old"))])
        #expect(recorder.homeProbes == 0)
        #expect(
            RecentSelectionsStore(defaults: defaults).lastChatDestination
                == ChatDestination(hostID: host.id, workspaceID: "w9", workspaceLabel: "Old", cwd: "/work/w9"))
    }

    @Test func anUnresolvablePlanNeverStartsAndLeavesChatModeOn() async {
        let host = Host.fixture()
        let recorder = Recorder()
        let store = makeStore(
            host: host,
            quickChat: preferences(
                ChatDestination(hostID: host.id, workspaceID: "gone", workspaceLabel: "Old", cwd: nil)),
            defaults: makeDefaults(), recorder: recorder)
        await store.discoverAgents()
        await store.runQuickChat()

        #expect(recorder.requests.isEmpty)
        #expect(store.state == .editing)
        #expect(store.chatMode)
        #expect(store.showsChatModeToggle)
        #expect(store.selectedAgentKind == .claude, "the New Chat kind stays preselected")
    }

    @Test func anUnknownHostNeverStarts() async {
        let recorder = Recorder()
        let store = makeStore(
            host: .fixture(),
            quickChat: preferences(
                ChatDestination(hostID: UUID(), workspaceID: "w1", workspaceLabel: "Proj", cwd: "/work/w1")),
            defaults: makeDefaults(), recorder: recorder)
        await store.discoverAgents()
        await store.runQuickChat()

        #expect(recorder.requests.isEmpty)
        #expect(store.chatMode)
    }

    @Test func anEditBeforeDiscoveryCancelsTheStart() async {
        let host = Host.fixture()
        let recorder = Recorder()
        let discovery = ScriptedTransportCallGate()
        let store = makeStore(
            host: host,
            kinds: {
                await discovery.waitUntilOpen()
                return [.claude]
            },
            quickChat: preferences(
                ChatDestination(hostID: host.id, workspaceID: "w1", workspaceLabel: "Proj", cwd: "/work/w1")),
            defaults: makeDefaults(), recorder: recorder)

        let run = Task { await store.runQuickChat() }
        let detecting = Task { await store.discoverAgents() }
        await discovery.waitForEntry()
        store.name = "mine"
        await discovery.open()
        await detecting.value
        await run.value

        #expect(recorder.requests.isEmpty)
        #expect(store.state == .editing)
        #expect(store.name == "mine")
        #expect(store.chatMode)
    }

    @Test func aKindTheHostLacksNeverStarts() async {
        let host = Host.fixture()
        let recorder = Recorder()
        let store = makeStore(
            host: host,
            kinds: { [.codex] },
            quickChat: preferences(
                ChatDestination(hostID: host.id, workspaceID: "w1", workspaceLabel: "Proj", cwd: "/work/w1")),
            defaults: makeDefaults(), recorder: recorder)
        await store.discoverAgents()
        await store.runQuickChat()

        #expect(recorder.requests.isEmpty)
        #expect(store.state == .editing)
        #expect(store.selectedAgentKind == .codex, "a Chat Mode kind the Host has is preselected")
        #expect(store.chatMode)
    }

    /// The Host's snapshot liveness and detection attempts, driven by the test.
    @MainActor
    private final class HostState {
        var isLive = false
        var discoveryAttempts = 0
        /// Quick chat asks once per poll.
        private(set) var liveChecks = 0

        func checkLive() -> Bool {
            liveChecks += 1
            return isLive
        }

        /// Counts one poll answered by `live`, the Console's own answer.
        func count(_ live: Bool) -> Bool {
            liveChecks += 1
            return live
        }

        /// Waits for quick chat to have polled; no wall-clock budget.
        func waitForLiveChecks(_ count: Int) async throws {
            while liveChecks < count { try await Task.sleep(for: .milliseconds(1)) }
        }
    }

    private struct DiscoveryFailed: Error {}

    @Test func autoStartWaitsForALiveSnapshotThenStartsOnce() async throws {
        let host = Host.fixture()
        let recorder = Recorder()
        let hostState = HostState()
        let store = makeStore(
            host: host,
            quickChat: preferences(
                ChatDestination(hostID: host.id, workspaceID: "w1", workspaceLabel: "Proj", cwd: "/work/w1")),
            defaults: makeDefaults(), recorder: recorder,
            hasLiveSnapshot: { _ in hostState.checkLive() })
        await store.discoverAgents()
        let run = Task { await store.runQuickChat() }
        try await hostState.waitForLiveChecks(6)
        #expect(recorder.requests.isEmpty, "nothing starts before the snapshot is live")

        hostState.isLive = true
        await run.value
        await store.runQuickChat()

        #expect(recorder.requests.count == 1)
        #expect(recorder.requests.first?.workspaceID == "w1")
        #expect(store.state == .started(ConsoleAgent.ID(hostID: host.id, paneID: "w1:pnew")))
    }

    /// Cancel and the sheet's teardown call `stopQuickChat()`; teardown
    /// also cancels the view's task.
    @Test(arguments: [false, true])
    func stoppingBeforeDiscoveryPreventsAnyStart(cancelsTask: Bool) async {
        let host = Host.fixture()
        let recorder = Recorder()
        let discovery = ScriptedTransportCallGate()
        let store = makeStore(
            host: host,
            kinds: {
                await discovery.waitUntilOpen()
                return [.claude]
            },
            quickChat: preferences(
                ChatDestination(hostID: host.id, workspaceID: "w1", workspaceLabel: "Proj", cwd: "/work/w1")),
            defaults: makeDefaults(), recorder: recorder)

        let run = Task { await store.runQuickChat() }
        let detecting = Task { await store.discoverAgents() }
        await discovery.waitForEntry()
        store.stopQuickChat()
        if cancelsTask { run.cancel() }
        await discovery.open()
        await detecting.value
        await run.value
        await store.runQuickChat()

        #expect(recorder.requests.isEmpty)
        #expect(store.state == .editing)
    }

    @Test func aFailedDiscoveryIsRetriedWhenTheHostBecomesLive() async throws {
        let host = Host.fixture()
        let recorder = Recorder()
        recorder.agentWorkspaceID = "w2"
        let hostState = HostState()
        let store = makeStore(
            host: host,
            kinds: {
                hostState.discoveryAttempts += 1
                guard hostState.discoveryAttempts > 1 else { throw DiscoveryFailed() }
                return [.claude]
            },
            quickChat: preferences(
                ChatDestination(hostID: host.id, workspaceID: "w2", workspaceLabel: "Other", cwd: "/work/w2")),
            defaults: makeDefaults(), recorder: recorder,
            hasLiveSnapshot: { _ in hostState.checkLive() })
        await store.discoverAgents()
        guard case .failed = store.agentDiscoveryState else {
            Issue.record("the first detection should fail")
            return
        }
        let run = Task { await store.runQuickChat() }
        try await hostState.waitForLiveChecks(6)
        #expect(hostState.discoveryAttempts == 1, "no retry while the Host is not live")

        hostState.isLive = true
        await run.value

        #expect(hostState.discoveryAttempts == 2)
        #expect(recorder.requests.count == 1)
        #expect(recorder.requests.first?.workspaceID == "w2")
    }

    @Test func discoveryPreselectsTheNewChatWorkspaceEvenWhenTheKindIsMissing() async {
        let host = Host.fixture()
        let recorder = Recorder()
        let store = makeStore(
            host: host,
            kinds: { [.codex] },
            quickChat: preferences(
                ChatDestination(hostID: host.id, workspaceID: "w2", workspaceLabel: "Other", cwd: "/work/w2")),
            defaults: makeDefaults(), recorder: recorder)
        await store.discoverAgents()
        await store.runQuickChat()

        #expect(recorder.requests.isEmpty)
        #expect(store.selectedWorkspaceID == "w2")
    }

    /// Auto-start ends before detection loads: the window passes (as
    /// `stopQuickChat()` does) or the user edits an unrelated field. A late
    /// detection still preselects New Chat's Workspace.
    @Test(arguments: [false, true])
    func lateDiscoveryPreselectsTheNewChatWorkspaceAfterAutoStartEnds(editsName: Bool) async {
        let host = Host.fixture()
        let recorder = Recorder()
        let discovery = ScriptedTransportCallGate()
        let store = makeStore(
            host: host,
            kinds: {
                await discovery.waitUntilOpen()
                return [.claude]
            },
            quickChat: preferences(
                ChatDestination(hostID: host.id, workspaceID: "w2", workspaceLabel: "Other", cwd: "/work/w2")),
            defaults: makeDefaults(), recorder: recorder)

        let run = Task { await store.runQuickChat() }
        let detecting = Task { await store.discoverAgents() }
        await discovery.waitForEntry()
        if editsName { store.name = "mine" } else { store.stopQuickChat() }
        await run.value
        await discovery.open()
        await detecting.value

        #expect(recorder.requests.isEmpty)
        #expect(store.state == .editing)
        #expect(store.selectedAgentKind == .claude)
        #expect(store.selectedWorkspaceID == "w2", "New Chat's Workspace, not the first one")
    }

    @Test func discoveryNeverOverridesAWorkspaceTheUserPicked() async {
        let host = Host.fixture()
        let recorder = Recorder()
        let discovery = ScriptedTransportCallGate()
        let store = makeStore(
            host: host,
            kinds: {
                await discovery.waitUntilOpen()
                return [.claude]
            },
            quickChat: preferences(
                ChatDestination(hostID: host.id, workspaceID: "w1", workspaceLabel: "Proj", cwd: "/work/w1")),
            defaults: makeDefaults(), recorder: recorder)

        let run = Task { await store.runQuickChat() }
        let detecting = Task { await store.discoverAgents() }
        await discovery.waitForEntry()
        store.selectExistingWorkspace("w2")
        await discovery.open()
        await detecting.value
        await run.value
        #expect(store.selectedWorkspaceID == "w2")

        // A later detection, such as Retry, leaves the pick alone too.
        await store.discoverAgents()
        #expect(recorder.requests.isEmpty)
        #expect(store.selectedWorkspaceID == "w2")
        #expect(store.launchTarget == .existingWorkspace)
    }
}

// MARK: A Host running herdr and tmux

extension StartAgentQuickChatTests {
    /// herdr's `w1` and tmux's `tmux:$1`, as `ConsoleStore` lists them.
    private var dualWorkspaces: [ConsoleWorkspace] {
        [
            ConsoleWorkspace(id: "w1", label: "Proj"),
            ConsoleWorkspace(id: "tmux:$1", label: "work", backend: .tmux),
        ]
    }

    /// Last Used New Chat values: `destination` and claude.
    private func lastUsed(_ destination: ChatDestination) -> NewChatPreferences {
        NewChatPreferences(lastDestination: destination, lastChatKind: .claude)
    }

    @Test func aLastUsedTmuxSessionStartsInItAndLetsTheConsoleRouteIt() async throws {
        let host = Host.fixture()
        let recorder = Recorder()
        recorder.agentWorkspaceID = "tmux:$1"
        let store = makeStore(
            host: host, workspaces: dualWorkspaces,
            quickChat: lastUsed(
                ChatDestination(hostID: host.id, workspaceID: "tmux:$1", workspaceLabel: "work", cwd: "/work/t")),
            defaults: makeDefaults(), recorder: recorder,
            backends: [.herdr, .tmux], defaultBackend: .herdr)
        await store.discoverAgents()
        await store.runQuickChat()

        let request = try #require(recorder.requests.first)
        #expect(recorder.requests.count == 1)
        #expect(request.workspaceID == "tmux:$1")
        #expect(recorder.destinations == [.existingWorkspace])
        #expect(recorder.backends == [nil], "the Workspace's owner decides the backend")
    }

    @Test func aGoneWorkspaceStartsANewOneOnTheHostsDefaultBackend() async throws {
        let host = Host.fixture()
        let recorder = Recorder()
        recorder.agentWorkspaceID = "tmux:$9"
        let store = makeStore(
            host: host, workspaces: dualWorkspaces,
            quickChat: lastUsed(
                ChatDestination(hostID: host.id, workspaceID: "tmux:$7", workspaceLabel: "Old", cwd: "/srv/old")),
            defaults: makeDefaults(), recorder: recorder,
            backends: [.herdr, .tmux], defaultBackend: .tmux)
        await store.discoverAgents()
        await store.runQuickChat()

        #expect(recorder.requests.count == 1)
        #expect(recorder.requests.first?.workspaceID == nil)
        #expect(recorder.destinations == [.newWorkspace(NewWorkspaceSpec(directory: "/srv/old", label: "Old"))])
        #expect(recorder.backends == [.tmux])
    }

    @Test func pickingTheBackendStopsTheAutoStart() async throws {
        let host = Host.fixture()
        let recorder = Recorder()
        let hostState = HostState()
        let store = makeStore(
            host: host, workspaces: dualWorkspaces,
            quickChat: lastUsed(
                ChatDestination(hostID: host.id, workspaceID: "gone", workspaceLabel: "Old", cwd: "/srv/old")),
            defaults: makeDefaults(), recorder: recorder,
            hasLiveSnapshot: { _ in hostState.checkLive() },
            backends: [.herdr, .tmux], defaultBackend: .herdr)
        await store.discoverAgents()
        let run = Task { await store.runQuickChat() }
        try await hostState.waitForLiveChecks(3)

        store.newWorkspaceBackend = .tmux
        hostState.isLive = true
        await run.value
        await store.runQuickChat()

        #expect(recorder.requests.isEmpty)
        #expect(store.state == .editing)
        #expect(store.chatMode)
    }

    /// herdr's snapshot is live while tmux's is still in flight: quick chat
    /// waits for tmux's sessions instead of planning without them.
    @Test func planningWaitsForTmuxsLiveSnapshot() async throws {
        let host = Host.fixture()
        let defaults = makeDefaults()
        let herdr = ScriptedTransport(
            snapshot: .fixture(
                agents: [.fixture(paneID: "w1:p1")],
                workspaces: [.fixture(workspaceID: "w1", label: "Proj")]))
        let tmux = ScriptedTransport(
            snapshot: .fixture(
                agents: [.fixture(paneID: "tmux:%1", workspaceID: "tmux:$1")],
                workspaces: [.fixture(workspaceID: "tmux:$1", label: "work")]))
        let tmuxGate = ScriptedTransportCallGate()
        await tmux.gateNextSnapshot(using: tmuxGate)
        let console = ConsoleStore(
            snapshotRetryDelay: .milliseconds(10),
            pins: PinnedAgentsStore(defaults: defaults),
            unread: UnreadAgentsStore(defaults: defaults),
            closedSessions: ClosedSessionsStore(),
            chatMode: ChatModeStore(defaults: defaults),
            rowLayouts: AgentRowLayoutStore(defaults: defaults),
            backendPreferences: HostBackendPreferences(defaults: defaults),
            makeSession: { _, backend, subscriptions in
                EventsSession(
                    subscriptions: subscriptions,
                    connect: {
                        switch backend {
                        case .zellij, .ultimate, .codex, .opencode: throw TransportError.cancelled
                        case .herdr, .core: return herdr
                        case .tmux: return tmux
                        }
                    },
                    keepalive: nil)
            },
            detectBackends: { _ in HostBackendPresence(herdr: true, tmuxVersion: "3.4") })
        console.setHosts([host])
        await console.resume()
        defer { console.setHosts([]) }
        let herdrScope = ConsoleScope(hostID: host.id, backend: .herdr)
        let tmuxScope = ConsoleScope(hostID: host.id, backend: .tmux)
        await tmuxGate.waitForEntry()
        let deadline = ContinuousClock.now + .waitCeiling
        while !(console.scopeStatuses[herdrScope] == .connected
            && !console.scopesAwaitingSnapshot.contains(herdrScope)
            && console.scopesAwaitingSnapshot.contains(tmuxScope))
        {
            try #require(ContinuousClock.now < deadline, "herdr should verify while tmux's snapshot waits")
            try await Task.sleep(for: .milliseconds(5))
        }

        let recorder = Recorder()
        recorder.agentWorkspaceID = "tmux:$1"
        let hostState = HostState()
        let store = makeStore(
            host: host,
            quickChat: lastUsed(
                ChatDestination(hostID: host.id, workspaceID: "tmux:$1", workspaceLabel: "work", cwd: "/work/t")),
            defaults: defaults, recorder: recorder,
            hasLiveSnapshot: { hostState.count(console.hasLiveSnapshots(on: $0)) },
            backends: console.presentBackends(on: host.id),
            defaultBackend: console.defaultNewAgentBackend(on: host.id),
            liveWorkspaces: { console.workspaces(for: $0) })
        await store.discoverAgents()
        let run = Task { await store.runQuickChat() }
        try await hostState.waitForLiveChecks(6)
        #expect(recorder.requests.isEmpty, "nothing is planned before tmux's sessions are live")

        await tmuxGate.open()
        await run.value

        let request = try #require(recorder.requests.first)
        #expect(recorder.requests.count == 1)
        #expect(request.workspaceID == "tmux:$1")
        #expect(recorder.destinations == [.existingWorkspace])
        #expect(recorder.backends == [nil])
    }
}
