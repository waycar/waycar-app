import Foundation
import Observation
import Synchronization
import Testing

@testable import Waycar

/// Console state store (#8) against scripted transports: snapshot-then-delta
/// sync, Blocked-first sorting, membership resyncs, and snippets — protocol
/// level, no SSH.
@MainActor
@Suite("Console store")
struct ConsoleStoreTests {
    /// Reconnect fast so resync tests never wait on real backoff.
    private static nonisolated let fastPolicy = ReconnectPolicy(
        initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50))

    /// A store whose session factory routes each Host to its scripted
    /// transport; unknown Hosts fail the connect. Pins and unread marks
    /// default to isolated suites so leftover `UserDefaults.standard` data
    /// cannot reorder the list.
    private func makeStore(
        transports: [Host.ID: ScriptedTransport],
        reconnectPolicy: ReconnectPolicy = Self.fastPolicy,
        pins: PinnedAgentsStore? = nil,
        summaryRefreshTiming: AgentSummaryRefreshTiming = AgentSummaryRefreshTiming()
    ) -> ConsoleStore {
        let resolvedPins =
            pins
            ?? PinnedAgentsStore(
                defaults: UserDefaults(suiteName: "hm-console-pins-\(UUID().uuidString)")
                    ?? .standard)
        let unread = UnreadAgentsStore(
            defaults: UserDefaults(suiteName: "hm-console-unread-\(UUID().uuidString)")
                ?? .standard)
        return ConsoleStore(
            snapshotRetryDelay: .milliseconds(10), summaryRefreshTiming: summaryRefreshTiming,
            pins: resolvedPins, unread: unread
        ) { host, _, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: {
                    guard let transport = transports[host.id] else {
                        throw TransportError.sshUnreachable(detail: "unscripted host")
                    }
                    return transport
                },
                reconnectPolicy: reconnectPolicy,
                keepalive: nil)
        }
    }

    private func consoleAgent(
        hostID: UUID,
        hostName: String,
        paneID: String,
        status: AgentStatus,
        workspaceLabel: String? = "Proj",
        workspaceTabCount: Int = 0
    ) -> ConsoleAgent {
        ConsoleAgent(
            hostID: hostID,
            hostName: hostName,
            agent: Agent(.fixture(paneID: paneID, status: status)),
            workspaceLabel: workspaceLabel,
            repositoryCheckout: nil,
            workspaceTabCount: workspaceTabCount)
    }

    @Test func theLastTabInAWorkspaceClosesItsWorkspace() {
        // (#swipe): closing a workspace's last tab takes the workspace down
        // with it, so VoiceOver announces "Closing workspace" for the
        // swiped row instead of "Closing tab".
        let host = Host.fixture()
        let store = makeStore(transports: [:])
        let last = consoleAgent(
            hostID: host.id, hostName: host.name, paneID: "w1:p1",
            status: .idle, workspaceTabCount: 1)
        let shared = consoleAgent(
            hostID: host.id, hostName: host.name, paneID: "w1:p2",
            status: .idle, workspaceTabCount: 3)

        #expect(store.closesWorkspaceWithTab(of: last))
        #expect(!store.closesWorkspaceWithTab(of: shared))
    }

    private func makePinDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "hm-console-pins-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    @Test func sortBucketsRankBlockedThenDoneThenWorkingThenIdle() {
        #expect(AgentStatus.blocked.consoleSortBucket < AgentStatus.done.consoleSortBucket)
        #expect(AgentStatus.done.consoleSortBucket < AgentStatus.working.consoleSortBucket)
        #expect(AgentStatus.working.consoleSortBucket < AgentStatus.idle.consoleSortBucket)
        #expect(AgentStatus.idle.consoleSortBucket < AgentStatus.unknown.consoleSortBucket)
        // herdr's API has no stability guarantee: a status this build does
        // not recognize must land in the bottom bucket, not on top.
        #expect(
            AgentStatus(rawValue: "haunted").consoleSortBucket
                == AgentStatus.unknown.consoleSortBucket)
    }

    @Test func consoleSortedPutsPinnedAgentsFirstByRank() {
        let hostA = UUID()
        let hostB = UUID()
        let idle = consoleAgent(
            hostID: hostA, hostName: "alpha", paneID: "w1:p1", status: .idle)
        let working = consoleAgent(
            hostID: hostA, hostName: "alpha", paneID: "w1:p2", status: .working)
        let blocked = consoleAgent(
            hostID: hostB, hostName: "beta", paneID: "w2:p1", status: .blocked)
        let done = consoleAgent(
            hostID: hostB, hostName: "beta", paneID: "w2:p2", status: .done)
        let agents = [idle, working, blocked, done]
        // Unpinned order is blocked > done > working > idle.
        #expect(agents.consoleSorted().map(\.agent.paneID) == ["w2:p1", "w2:p2", "w1:p2", "w1:p1"])

        // idle pinned first (rank 1), working pinned more recently (rank 0).
        // Unpinned blocked/done keep their relative order.
        let ranks: [ConsoleAgent.ID: Int] = [idle.id: 1, working.id: 0]
        #expect(
            agents.consoleSorted { ranks[$0.id] }.map(\.agent.paneID)
                == ["w1:p2", "w1:p1", "w2:p1", "w2:p2"])
    }

    @Test func consoleSortedLeavesUnpinnedTiebreaksUnchanged() {
        let hostA = UUID()
        let hostB = UUID()
        // Same status: Host name orders the rows; pins still lead.
        let laterName = consoleAgent(
            hostID: hostA, hostName: "zeta", paneID: "w1:p1", status: .working)
        let earlierName = consoleAgent(
            hostID: hostB, hostName: "alpha", paneID: "w2:p1", status: .working)
        let unpinned = [laterName, earlierName].consoleSorted()
        #expect(unpinned.map(\.agent.paneID) == ["w2:p1", "w1:p1"])

        let ranks: [ConsoleAgent.ID: Int] = [laterName.id: 0]
        let pinned = [laterName, earlierName].consoleSorted { ranks[$0.id] }
        #expect(pinned.map(\.agent.paneID) == ["w1:p1", "w2:p1"])
    }

    @Test func consoleSortedDefaultsToBlockedDoneWorkingWithNewestFirstInsideBuckets() {
        let host = UUID()
        func agent(_ paneID: String, _ status: AgentStatus, _ sequence: Int?) -> ConsoleAgent {
            let info = AgentInfo(
                agentStatus: status, focused: false, paneID: paneID, revision: 1,
                tabID: "w1:t1", terminalID: "term_\(paneID)", workspaceID: "w1",
                agent: "claude", stateChangeSeq: sequence)
            return ConsoleAgent(
                hostID: host, hostName: "alpha", agent: Agent(info),
                workspaceLabel: "Proj", repositoryCheckout: nil)
        }
        let staleDone = agent("p1", .done, 1)
        let freshDone = agent("p2", .done, 9)
        let waiting = agent("p3", .blocked, 2)
        let active = agent("p4", .working, 5)
        let idle = agent("p5", .idle, nil)
        // One order for every Host: the default is waiting on a reply
        // first, then a result waiting to be read, then active, then idle;
        // inside a bucket the highest `stateChangeSeq` (newest activity)
        // leads.
        #expect(
            [staleDone, freshDone, waiting, active, idle].consoleSorted().map(\.agent.paneID)
                == ["p3", "p2", "p1", "p4", "p5"])
    }

    @Test func storeOrdersOneHostByStatusThenRecency() async throws {
        let host = Host.fixture()
        func agent(_ paneID: String, _ status: AgentStatus, _ sequence: Int?) -> AgentInfo {
            AgentInfo(
                agentStatus: status, focused: false, paneID: paneID, revision: 1,
                tabID: "w1:t1", terminalID: "term_\(paneID)", workspaceID: "w1",
                agent: "claude", stateChangeSeq: sequence)
        }
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [
                agent("w1:p1", .done, 3),
                agent("w1:p2", .done, 9),
                agent("w1:p3", .working, 1),
            ]))
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("agents should arrive") { store.agents.count == 3 }

        // Done before working, newest activity first within done.
        #expect(store.agents.map(\.agent.paneID) == ["w1:p2", "w1:p1", "w1:p3"])

        store.setHosts([])
    }

    /// A store that counts every events session it builds and every backend
    /// detection it runs, each session on a fresh scripted transport, so a
    /// Host can be dropped and projected again. Its pins, unread marks and
    /// backend preferences live in a scratch defaults suite (returned, so a
    /// test can play another device writing to it) that `cleanup` removes.
    private func makeCountingStore(
        closedSessions: ClosedSessionsStore = ClosedSessionsStore(),
        inventoryCache: ConsoleInventoryCache? = nil,
        sessions: HostCalls,
        detections: HostCalls
    ) throws -> (ConsoleStore, defaults: UserDefaults, cleanup: () -> Void) {
        let (defaults, cleanup) = try makePinDefaults()
        let store = ConsoleStore(
            snapshotRetryDelay: .milliseconds(10),
            pins: PinnedAgentsStore(defaults: defaults),
            unread: UnreadAgentsStore(defaults: defaults),
            closedSessions: closedSessions,
            backendPreferences: HostBackendPreferences(defaults: defaults),
            inventoryCache: inventoryCache,
            makeSession: { host, _, subscriptions in
                sessions.record(host.id)
                return EventsSession(
                    subscriptions: subscriptions,
                    connect: {
                        ScriptedTransport(
                            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .idle)]))
                    },
                    reconnectPolicy: Self.fastPolicy,
                    keepalive: nil)
            },
            detectBackends: { host in
                detections.record(host.id)
                return .herdrOnly
            })
        return (store, defaults, cleanup)
    }

    @Test func aDisabledHostIsNeverContacted() async throws {
        var disabled = Host.fixture(name: "disabled", address: "disabled.example")
        disabled.isEnabled = false
        let enabled = Host.fixture(name: "enabled", address: "enabled.example")
        let sessions = HostCalls()
        let detections = HostCalls()
        let (store, _, cleanup) = try makeCountingStore(
            sessions: sessions, detections: detections)
        defer { cleanup() }
        defer { store.setHosts([]) }

        store.setHosts([disabled, enabled])
        await store.resume()
        await store.reactivate()
        // Positive control: by the time the enabled Host is connected and
        // detected, the same passes have had every chance to reach the
        // disabled one.
        try await waitUntil("the enabled Host should connect and be detected") {
            store.hostStatuses[enabled.id] == EventsSessionStatus.connected
                && detections.ids.contains(enabled.id)
        }

        #expect(sessions.ids.contains(enabled.id))
        #expect(!sessions.ids.contains(disabled.id))
        #expect(!detections.ids.contains(disabled.id))
        #expect(store.hostStatuses[disabled.id] == nil)
        #expect(store.agents.allSatisfy { $0.hostID == enabled.id })
    }

    @Test func disablingAHostEndsItsProjectionButKeepsItsClosedSessions() async throws {
        var host = Host.fixture()
        let closed = ClosedSessionsStore()
        let sessions = HostCalls()
        let detections = HostCalls()
        let (store, _, cleanup) = try makeCountingStore(
            closedSessions: closed, sessions: sessions, detections: detections)
        defer { cleanup() }
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil("the Host should connect") {
            store.hostStatuses[host.id] == EventsSessionStatus.connected && store.agents.count == 1
        }
        closed.record([
            ClosedAgentCapture(
                row: ConsoleAgent(
                    hostID: host.id, hostName: host.name,
                    agent: Agent(
                        terminalID: "t9", kind: "claude", title: "Gone", status: .idle,
                        workspaceID: "w9", tabID: "w9:t1", paneID: "w9:p1", cwd: "/work",
                        revision: 1,
                        agentSession: AgentSessionInfo(
                            agent: "claude", kind: .id, source: "herdr:claude", value: "s-gone")),
                    workspaceLabel: "Gone", repositoryCheckout: nil),
                session: nil, lastSeenRunningAt: closed.now())
        ])
        #expect(closed.sessions.count == 1)

        host.isEnabled = false
        store.setHosts([host])

        #expect(store.hostStatuses[host.id] == nil)
        // The Hosts sheet's sampler stops asking a Disabled Host.
        #expect(!store.connectedHostIDs.contains(host.id))
        #expect(store.agents.isEmpty)
        #expect(closed.sessions.map(\.hostID) == [host.id])

        // The store is still active (resumed above, never suspended), so
        // putting the Host back in the catalog must reconnect it on its own.
        let sessionsBeforeReenabling = sessions.ids.count
        host.isEnabled = true
        store.setHosts([host])

        try await waitUntil("re-enabling should project the Host again") {
            store.hostStatuses[host.id] == EventsSessionStatus.connected && store.agents.count == 1
        }
        #expect(sessions.ids.count > sessionsBeforeReenabling)
    }

    /// A scratch inventory cache directory, removed by the returned cleanup.
    private func makeCacheDirectory() -> (URL, cleanup: () -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "console-disabled-\(UUID().uuidString)", directoryHint: .isDirectory)
        return (directory, { try? FileManager.default.removeItem(at: directory) })
    }

    @Test func disablingAHostKeepsItsLastKnownInventoryOnDisk() async throws {
        let (directory, cleanup) = makeCacheDirectory()
        defer { cleanup() }
        var host = Host.fixture()
        let cache = ConsoleInventoryCache(directory: directory)
        cache.save(
            ConsoleInventoryCache.Entry(
                snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .idle)]),
                sidebarLayout: nil),
            for: host)
        let (store, _, storeCleanup) = try makeCountingStore(
            inventoryCache: cache, sessions: HostCalls(), detections: HostCalls())
        defer { storeCleanup() }
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil("the Host should connect") {
            store.hostStatuses[host.id] == EventsSessionStatus.connected && store.agents.count == 1
        }

        host.isEnabled = false
        store.setHosts([host])
        cache.flush()

        #expect(ConsoleInventoryCache(directory: directory).load(for: host) != nil)
    }

    /// A Disabled Host has no projection, but re-targeting it still makes
    /// what was kept for the old connection target meaningless.
    @Test func retargetingADisabledHostForgetsTheOldTargetsInventory() throws {
        let (directory, cleanup) = makeCacheDirectory()
        defer { cleanup() }
        var host = Host.fixture(address: "old.example")
        host.isEnabled = false
        let cache = ConsoleInventoryCache(directory: directory)
        cache.save(
            ConsoleInventoryCache.Entry(
                snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .idle)]),
                sidebarLayout: nil),
            for: host)
        cache.savePresence(
            .init(presence: HostBackendPresence(herdr: true, tmuxVersion: "3.4"), verifiedAt: nil),
            for: host)
        cache.flush()
        let sessions = HostCalls()
        let (store, _, storeCleanup) = try makeCountingStore(
            inventoryCache: cache, sessions: sessions, detections: HostCalls())
        defer { storeCleanup() }
        defer { store.setHosts([]) }
        store.setHosts([host])
        cache.flush()
        #expect(ConsoleInventoryCache(directory: directory).load(for: host) != nil)

        let previous = host
        host.address = "new.example"
        store.setHosts([host])
        cache.flush()

        let reader = ConsoleInventoryCache(directory: directory)
        #expect(reader.load(for: previous) == nil)
        #expect(reader.loadPresence(for: previous) == nil)
        #expect(sessions.ids.isEmpty)
    }

    /// Another device turning tmux back on arrives as a synced preference
    /// and a reload; reconciling every Host must still skip a Disabled one.
    @Test func showingTmuxOnADisabledHostStartsNoSession() async throws {
        var host = Host.fixture()
        host.isEnabled = false
        let sessions = HostCalls()
        let detections = HostCalls()
        let (store, defaults, cleanup) = try makeCountingStore(
            sessions: sessions, detections: detections)
        defer { cleanup() }
        defer { store.setHosts([]) }
        store.setHosts([host])
        store.backendPreferences.setShowsTmux(false, for: host.id)

        HostBackendPreferences(defaults: defaults).setShowsTmux(true, for: host.id)
        store.backendPreferences.reload()
        #expect(store.backendPreferences.showsTmux(for: host.id))

        #expect(sessions.ids.isEmpty)
        #expect(store.agents.isEmpty)
    }

    @Test func snapshotsAcrossHostsFlattenIntoOneStatusSortedList() async throws {
        let hostA = Host.fixture(name: "alpha", address: "a.example")
        let hostB = Host.fixture(name: "beta", address: "b.example")
        let transports = [
            hostA.id: ScriptedTransport(
                snapshot: .fixture(
                    agents: [
                        .fixture(paneID: "w1:p1", status: .idle),
                        .fixture(paneID: "w1:p2", status: .working),
                    ],
                    workspaces: [.fixture(workspaceID: "w1", label: "Proj", repoName: "proj")])),
            hostB.id: ScriptedTransport(
                snapshot: .fixture(
                    agents: [
                        .fixture(paneID: "w2:p1", status: .blocked, workspaceID: "w2"),
                        .fixture(paneID: "w2:p2", status: .done, workspaceID: "w2"),
                    ],
                    workspaces: [.fixture(workspaceID: "w2", label: "Api")])),
        ]
        let store = makeStore(transports: transports)

        store.setHosts([hostA, hostB])
        await store.resume()
        try await waitUntil("all four agents should arrive") { store.agents.count == 4 }

        // Blocked > Done > Working > Idle, flat across both Hosts.
        #expect(store.agents.map(\.agent.paneID) == ["w2:p1", "w2:p2", "w1:p2", "w1:p1"])
        #expect(store.agents.first?.hostName == "beta")
        // Workspace rides along as a context tag.
        #expect(store.agents.first?.workspaceLabel == "Api")
        #expect(store.agents[2].workspaceLabel == "Proj")
        #expect(store.agents.last?.repoName == "proj")

        store.setHosts([])
    }

    @Test func snapshotProjectionJoinsTabsAndPreservesSidebarFacts() async throws {
        func tab(_ workspace: String, label: String, number: Int, suffix: String = "t1") -> TabInfo {
            TabInfo(agentStatus: .idle, focused: false, label: label, number: number,
                    paneCount: 1, tabID: "\(workspace):\(suffix)", workspaceID: workspace)
        }
        let host = Host.fixture()
        let single = tab("single", label: "1", number: 42)
        let snapshot = SessionSnapshot(
            agents: [
                AgentInfo(agentStatus: .working, focused: false, paneID: "single:p", revision: 1,
                          tabID: "single:t1", terminalID: "terminal", workspaceID: "single", agent: "claude",
                          stateChangeSeq: 7, stateLabels: ["working": "Busy"], terminalTitle: "◑ Task",
                          terminalTitleStripped: "Task", title: "Pane title", tokens: ["pin_icon": "📌"]),
                .fixture(paneID: "multi:p", workspaceID: "multi"),
                .fixture(paneID: "named:p", workspaceID: "named"),
                .fixture(paneID: "missing:p", workspaceID: "missing"),
            ], layouts: [], panes: [
                PaneInfo(agentStatus: .idle, focused: false, paneID: "multi:p", revision: 1,
                         tabID: "multi:t1", terminalID: "term", workspaceID: "multi", label: "Manual label"),
                PaneInfo(agentStatus: .working, focused: false, paneID: "single:p", revision: 1,
                         tabID: "single:t1", terminalID: "term", workspaceID: "single", label: "Fallback"),
            ], protocolVersion: 20,
            tabs: [single, single, tab("multi", label: "1", number: 8),
                   tab("named", label: "2", number: 2),
                   tab("multi", label: "Shell", number: 9, suffix: "shell")],
            version: "0.8.2-fake", workspaces: [
                .fixture(workspaceID: "single", label: "Single"),
                .fixture(workspaceID: "multi", label: "Multi"),
                .fixture(workspaceID: "named", label: "Named"),
            ])
        let transport = ScriptedTransport(snapshot: snapshot)
        let session = EventsSession(subscriptions: [], connect: { transport }, keepalive: nil)
        let changes = AsyncStream<Void>.makeStream()
        let projection = HostConsoleProjection(
            host: host, session: session, snapshotRetryDelay: .seconds(1),
            onChange: { changes.continuation.yield(()) })
        defer {
            projection.end()
            changes.continuation.finish()
        }
        projection.start(isActive: false)
        await projection.resume()
        // Observe production publication, not a sleep or a polling barrier.
        for await _ in changes.stream {
            if !projection.isAwaitingSnapshot { break }
        }

        let row = try #require(projection.agentsByPane["single:p"])
        #expect(row.tabLabel == "1" && row.tabPosition == 1 && row.workspaceTabCount == 1)
        #expect(!row.showsTabLabel) // Stable tab number 42 is not its display position.
        #expect(row.snapshotOrder == 0 && row.agent.stateChangeSeq == 7)
        #expect(row.agent.tokens == ["pin_icon": "📌"])
        #expect(row.agent.stateLabels == ["working": "Busy"])
        #expect(row.agent.terminalTitle == "◑ Task" && row.agent.terminalTitleStripped == "Task")
        #expect(row.agent.paneTitle == "Pane title" && row.agent.title == "Task")
        let multi = try #require(projection.agentsByPane["multi:p"])
        #expect(multi.workspaceTabCount == 2 && multi.showsTabLabel) // Count the shell-only tab too.
        #expect(multi.snapshotOrder == 1)
        let paneLayout = AgentRowLayout(rows: [[.init(.pane)]])
        #expect(AgentRowRenderer.render(layout: paneLayout, agent: multi).first?.first?.text == "Manual label")
        #expect(AgentRowRenderer.render(layout: paneLayout, agent: row).first?.first?.text == "Pane title")
        #expect(projection.agentsByPane["named:p"]?.showsTabLabel == true)
        #expect(projection.agentsByPane["missing:p"]?.tabLabel == nil)
        #expect(projection.agentsByPane["missing:p"]?.showsTabLabel == false)
    }

    /// The store walks a captured array of projections across awaits, so a
    /// Host disabled mid-walk can have its just-ended projection asked to
    /// resume, revalidate or retry. None of those may dial.
    @Test func anEndedProjectionNeverDials() async throws {
        let host = Host.fixture(name: "ended", address: "ended.example")
        let control = Host.fixture(name: "control", address: "control.example")
        let socketPath = "/home/dev/.config/herdr/herdr.sock"
        let failing = ScriptedTransport(snapshot: .fixture(agents: []))
        // herdr is not running: the connect-path ping fails in a way no
        // retry clears, so the session stops on `.failed`, the one state
        // in which `revalidate()` restarts it and dials again.
        await failing.failPing(atCall: 1, with: .streamLocalOpenFailed(path: socketPath))
        let dials = HostCalls()
        func makeProjection(
            for host: Host, transport: ScriptedTransport
        ) -> HostConsoleProjection {
            let session = EventsSession(
                subscriptions: [],
                connect: {
                    dials.record(host.id)
                    return transport
                },
                reconnectPolicy: Self.fastPolicy,
                keepalive: nil)
            return HostConsoleProjection(
                host: host, session: session, snapshotRetryDelay: .seconds(1), onChange: {})
        }
        let ended = makeProjection(for: host, transport: failing)
        ended.start(isActive: false)
        await ended.resume()
        try await waitUntil("the Host should stop on a failure no retry clears") {
            ended.status == .failed(.streamLocalOpenFailed(path: socketPath))
        }
        #expect(dials.ids.filter { $0 == host.id }.count == 1)
        ended.end()

        await ended.resume()
        await ended.revalidate()
        await ended.retry()

        // Positive control: the same path on a live projection does dial,
        // and by then any dial the ended one started would have landed.
        let live = makeProjection(
            for: control, transport: ScriptedTransport(snapshot: .fixture(agents: [])))
        defer { live.end() }
        live.start(isActive: false)
        await live.resume()
        try await waitUntil("the live projection should dial") {
            dials.ids.contains(control.id)
        }
        #expect(dials.ids.filter { $0 == host.id }.count == 1)
    }

    @Test func togglePinResortsThePublishedListImmediately() async throws {
        let (defaults, cleanup) = try makePinDefaults()
        defer { cleanup() }
        let pins = PinnedAgentsStore(defaults: defaults)
        let hostA = Host.fixture(name: "alpha", address: "a.example")
        let hostB = Host.fixture(name: "beta", address: "b.example")
        let transports = [
            hostA.id: ScriptedTransport(
                snapshot: .fixture(
                    agents: [
                        .fixture(paneID: "w1:p1", status: .idle),
                        .fixture(paneID: "w1:p2", status: .working),
                    ],
                    workspaces: [.fixture(workspaceID: "w1", label: "Proj")])),
            hostB.id: ScriptedTransport(
                snapshot: .fixture(
                    agents: [
                        .fixture(paneID: "w2:p1", status: .blocked, workspaceID: "w2"),
                        .fixture(paneID: "w2:p2", status: .done, workspaceID: "w2"),
                    ],
                    workspaces: [.fixture(workspaceID: "w2", label: "Api")])),
        ]
        let store = makeStore(transports: transports, pins: pins)

        store.setHosts([hostA, hostB])
        await store.resume()
        try await waitUntil("all four agents should arrive") { store.agents.count == 4 }
        #expect(store.agents.map(\.agent.paneID) == ["w2:p1", "w2:p2", "w1:p2", "w1:p1"])

        // Pin the idle agent first, then the working one: working is rank 0.
        store.togglePin(hostID: hostA.id, paneID: "w1:p1")
        #expect(store.agents.map(\.agent.paneID) == ["w1:p1", "w2:p1", "w2:p2", "w1:p2"])

        store.togglePin(hostID: hostA.id, paneID: "w1:p2")
        #expect(store.agents.map(\.agent.paneID) == ["w1:p2", "w1:p1", "w2:p1", "w2:p2"])

        store.togglePin(hostID: hostA.id, paneID: "w1:p2")
        #expect(store.agents.map(\.agent.paneID) == ["w1:p1", "w2:p1", "w2:p2", "w1:p2"])

        store.setHosts([])
    }

    @Test func unrecognizedStatusSortsIntoTheBottomBucket() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [
                .fixture(paneID: "w1:p1", status: AgentStatus(rawValue: "haunted")),
                .fixture(paneID: "w1:p2", status: .working),
                .fixture(paneID: "w1:p3", status: .unknown),
            ]))
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("agents should arrive") { store.agents.count == 3 }

        #expect(store.agents.first?.agent.paneID == "w1:p2")
        #expect(
            store.agents.dropFirst().map(\.agent.status)
                == [AgentStatus(rawValue: "haunted"), .unknown])

        store.setHosts([])
    }

    @Test func blockedStatusChangeSurfacesToTheTopWithinOneSecond() async throws {
        // The #8 acceptance criterion: two Hosts connected, a Blocked agent
        // reaches the top of the list within 1s of its status event.
        let hostA = Host.fixture(name: "alpha", address: "a.example")
        let hostB = Host.fixture(name: "beta", address: "b.example")
        let transports = [
            hostA.id: ScriptedTransport(
                snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .working)])),
            hostB.id: ScriptedTransport(
                snapshot: .fixture(agents: [.fixture(paneID: "w2:p1", status: .idle)])),
        ]
        let store = makeStore(transports: transports)

        store.setHosts([hostA, hostB])
        await store.resume()
        try await waitUntil("both agents should arrive") { store.agents.count == 2 }
        // Wait out the pane-subscription resubscribe so the emit hits the
        // live stream that actually carries the pane subscription.
        try await waitUntil("pane subscription should be live") {
            await transports[hostB.id]?.capturedSubscriptions.last?
                .contains(.pane(.agentStatusChanged, paneID: "w2:p1")) == true
        }

        await transports[hostB.id]?.setSnapshot(
            .fixture(agents: [.fixture(paneID: "w2:p1", status: .blocked)]))
        let start = ContinuousClock.now
        let emitted = await transports[hostB.id]?.emit(
            .agentStatusChanged(paneID: "w2:p1", status: .blocked))
        #expect(emitted == true)
        try await waitUntil("the Blocked agent should surface to the top") {
            store.agents.first?.agent.paneID == "w2:p1"
                && store.agents.first?.agent.status == .blocked
        }
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .seconds(1), "took \(elapsed)")

        store.setHosts([])
    }

    @Test func statusChangeDuringSnapshotSurvivesTheStaleResponse() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .idle)]))
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the pane subscription should settle") {
            let summaryReads = await transport.agentSummaryReads
            let subscriptions = await transport.capturedSubscriptions
            return summaryReads >= 1
                && subscriptions.last?.contains(
                    .pane(.agentStatusChanged, paneID: "w1:p1")) == true
        }

        let snapshotGate = ScriptedTransportCallGate()
        await transport.gateNextSnapshot(using: snapshotGate)
        let readsBeforeRace = await transport.agentSummaryReads
        #expect(
            await transport.emit(
                HerdrEvent(kind: GlobalEventKind.paneAgentDetected.kind, data: .object([:])))
                == true)
        try await waitUntil("the stale snapshot should be in flight") {
            await snapshotGate.entryCount == 1
        }

        // The held response stays idle; the follow-up authoritative read
        // must represent the Host after it emitted the Blocked event.
        await transport.setSnapshot(
            .fixture(agents: [.fixture(paneID: "w1:p1", status: .blocked)]))
        #expect(
            await transport.emit(.agentStatusChanged(paneID: "w1:p1", status: .blocked))
                == true)
        try await waitUntil("the live status event should land first") {
            store.agents.first?.agent.status == .blocked
        }

        await snapshotGate.open()
        try await waitUntil("the stale snapshot response should finish applying") {
            await transport.agentSummaryReads > readsBeforeRace
        }
        #expect(store.agents.first?.agent.status == .blocked)

        store.setHosts([])
    }

    @Test func disconnectDuringInitialSnapshotConvergesFromAFreshSnapshot() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .idle)]))
        let snapshotGate = ScriptedTransportCallGate()
        await transport.gateNextSnapshot(using: snapshotGate)
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the initial stale snapshot should be in flight") {
            await snapshotGate.entryCount == 1
        }
        #expect(store.agents.isEmpty)

        #expect(
            await transport.emit(.agentStatusChanged(paneID: "w1:p1", status: .blocked))
                == true)
        await transport.setSnapshot(
            .fixture(agents: [.fixture(paneID: "w1:p1", status: .blocked)]))
        await transport.failEventStream(.channelFailed(detail: "test ordering barrier"))
        try await waitUntil("the Host should disconnect before the stale snapshot returns") {
            guard case .reconnecting = store.hostStatuses[host.id] else { return false }
            return true
        }
        #expect(store.agents.isEmpty)

        await snapshotGate.open()
        try await waitUntil("the reconnect should apply a fresh snapshot") {
            store.hostStatuses[host.id] == .connected
                && store.agents.first?.agent.status == .blocked
        }

        store.setHosts([])
    }

    @Test func initialAndReconnectSnapshotsFollowSubscriptionAcknowledgement() async throws {
        let host = Host.fixture()
        // Empty membership avoids a pane-subscription replacement obscuring
        // the initial and reconnect boundaries under test.
        let transport = ScriptedTransport(snapshot: .fixture(agents: []))
        let store = makeStore(transports: [host.id: transport])
        defer { store.setHosts([]) }

        let initialGate = ScriptedTransportCallGate()
        await transport.gateNextSubscription(using: initialGate)
        store.setHosts([host])
        await store.resume()
        try await waitUntil("the first subscription should await acknowledgement") {
            await initialGate.entryCount == 1
        }
        #expect(await transport.snapshotFetchCount == 0)
        await initialGate.open()
        try await waitUntil("the first acknowledged stream should bootstrap the Console") {
            await transport.snapshotFetchCount == 1
        }

        let reconnectGate = ScriptedTransportCallGate()
        await transport.gateNextSubscription(using: reconnectGate)
        await transport.failEventStream(.channelFailed(detail: "scripted reconnect"))
        try await waitUntil("the replacement subscription should await acknowledgement") {
            await reconnectGate.entryCount == 1
        }
        #expect(await transport.snapshotFetchCount == 1)
        await reconnectGate.open()
        try await waitUntil("the replacement stream should trigger a fresh snapshot") {
            await transport.snapshotFetchCount == 2
        }
        #expect(await transport.snapshotHadLiveSubscription == [true, true])
    }

    @Test func lifecycleEventDuringInitialSnapshotSchedulesAuthoritativeFollowup() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture(agents: []))
        let snapshotGate = ScriptedTransportCallGate()
        await transport.gateNextSnapshot(using: snapshotGate)
        let store = makeStore(transports: [host.id: transport])
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil("the empty initial response should be held in flight") {
            await snapshotGate.entryCount == 1
        }

        await transport.setSnapshot(.fixture(agents: [.fixture(paneID: "w1:p-new")]))
        #expect(await transport.emit(HerdrEvent(
            kind: GlobalEventKind.paneAgentDetected.kind,
            data: .object(["pane_id": .string("w1:p-new")]))) == true)
        await snapshotGate.open()
        try await waitUntil("the live-only event should converge past the stale empty snapshot") {
            store.agents.map(\.agent.paneID) == ["w1:p-new"]
        }
        #expect(await transport.snapshotFetchCount >= 2)
    }

    @Test func snapshotPushesPaneSubscriptionsIntoTheSession() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [
                .fixture(paneID: "w1:p1"), .fixture(paneID: "w1:p2"),
            ]))
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("resubscribe with pane ids should happen") {
            await transport.capturedSubscriptions.last?.contains(
                .pane(.agentStatusChanged, paneID: "w1:p1")) == true
        }

        let sets = await transport.capturedSubscriptions
        // First subscribe knows no panes; the post-snapshot one carries both.
        #expect(sets.first?.contains(.pane(.agentStatusChanged, paneID: "w1:p1")) == false)
        #expect(sets.last?.contains(.pane(.agentStatusChanged, paneID: "w1:p2")) == true)
        #expect(sets.last?.contains(.global(.paneAgentDetected)) == true)

        store.setHosts([])
    }

    @Test func droppedStreamResyncsFromAFreshSnapshot() async throws {
        // Snapshot-then-delta resync: state changed while the stream was
        // down must arrive via the re-snapshot, not be waited for as events.
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .idle)]))
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("initial agent should arrive") { store.agents.count == 1 }

        await transport.setSnapshot(
            .fixture(agents: [
                .fixture(paneID: "w1:p1", status: .blocked),
                .fixture(paneID: "w1:p9", status: .working),
            ]))
        await transport.failEventStream(.channelFailed(detail: "stream died"))

        try await waitUntil("the resync should deliver the new snapshot") {
            store.agents.map(\.agent.paneID) == ["w1:p1", "w1:p9"]
        }
        #expect(store.agents.first?.agent.status == .blocked)

        store.setHosts([])
    }

    @Test func unknownAgentStatusResnapshotsAndRemovesAReleasedAgent() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .working)]))
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the pane subscription should settle") {
            await transport.capturedSubscriptions.last?.contains(
                .pane(.agentStatusChanged, paneID: "w1:p1")) == true
        }

        await transport.setSnapshot(.fixture())
        #expect(
            await transport.emit(.agentStatusChanged(paneID: "w1:p1", status: .unknown))
                == true)

        try await waitUntil("the exited Agent should disappear through a fresh snapshot") {
            store.agents.isEmpty
        }

        store.setHosts([])
    }

    @Test func forcedEventOverflowConvergesViaTheDropMarkerResync() async throws {
        // The #22 acceptance criterion: force the bounded events buffer to
        // overflow and prove the Console converges anyway. The server state
        // changes with no membership event — only ignorable noise — so the
        // drop marker's resync is the one path to the new snapshot.
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .idle)]))
        let box = SessionBox()
        let store = ConsoleStore { _, _, subscriptions in
            let session = EventsSession(
                subscriptions: subscriptions,
                connect: { transport },
                reconnectPolicy: Self.fastPolicy,
                keepalive: nil,
                updatesBufferLimit: 2)
            Task { await box.set(session) }
            return session
        }

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the initial agent should arrive") { store.agents.count == 1 }
        // Let the connect→snapshot→resubscribe→re-snapshot cycle settle, so
        // no in-flight resync can fetch the updated snapshot by accident.
        try await waitUntil("the pane subscription should be live") {
            await transport.capturedSubscriptions.last?
                .contains(.pane(.agentStatusChanged, paneID: "w1:p1")) == true
        }
        try await waitUntil("the post-resubscribe resync should settle") {
            await transport.snapshotFetchCount >= 2
        }
        let session = try #require(await box.session)

        await transport.setSnapshot(
            .fixture(agents: [
                .fixture(paneID: "w1:p1", status: .idle),
                .fixture(paneID: "w1:p9", status: .blocked),
            ]))
        // Flood with events the Console ignores until the bounded buffer
        // demonstrably sheds updates.
        try await waitUntil("the bounded buffer should shed updates") {
            for _ in 0..<50 {
                await transport.emit(
                    HerdrEvent(kind: PaneEventKind.scrollChanged.kind, data: .object([:])))
            }
            return await session.droppedUpdateCount > 0
        }

        try await waitUntil("the marker resync should surface the pane changed during the gap") {
            store.agents.map(\.agent.paneID) == ["w1:p9", "w1:p1"]
        }
        #expect(store.agents.first?.agent.status == .blocked)

        store.setHosts([])
    }

    @Test func membershipEventTriggersAResnapshot() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")]))
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("initial agent should arrive") { store.agents.count == 1 }

        await transport.setSnapshot(
            .fixture(agents: [.fixture(paneID: "w1:p1"), .fixture(paneID: "w1:p2")]))
        await transport.emit(
            HerdrEvent(
                kind: GlobalEventKind.paneAgentDetected.kind,
                data: .object(["pane_id": .string("w1:p2")])))

        try await waitUntil("the detected agent should appear via re-snapshot") {
            store.agents.count == 2
        }

        store.setHosts([])
    }

    @Test func workspaceCreationRefreshesTheNewAgentPicker() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(workspaces: [.fixture(workspaceID: "w1", label: "Proj")]))
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the initial workspace should arrive") {
            store.workspaces(for: host.id).map(\.id) == ["w1"]
        }
        try await waitUntil("workspace creation should be subscribed") {
            await transport.capturedSubscriptions.last?.contains(.global(.workspaceCreated)) == true
        }
        let pickerRefreshObserved = Mutex(false)
        withObservationTracking {
            _ = store.workspaces(for: host.id)
        } onChange: {
            pickerRefreshObserved.withLock { $0 = true }
        }

        await transport.setSnapshot(
            .fixture(workspaces: [
                .fixture(workspaceID: "w1", label: "Proj"),
                .fixture(workspaceID: "w2", label: "Api"),
            ]))
        await transport.emit(
            HerdrEvent(kind: GlobalEventKind.workspaceCreated.kind, data: .object([:])))

        try await waitUntil("the new workspace should appear without reconnecting") {
            store.workspaces(for: host.id).map(\.id) == ["w2", "w1"]
        }
        #expect(pickerRefreshObserved.withLock { $0 })

        store.setHosts([])
    }

    @Test func snapshotFailureSurfacesAndRetriesUntilRecovery() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")]))
        await transport.setSnapshotFailure(.timedOut)
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the sync failure should be visible") {
            store.hostSyncErrors[host.id] != nil
        }

        await transport.setSnapshotFailure(nil)
        try await waitUntil("the retry should recover the snapshot") {
            store.agents.map(\.agent.paneID) == ["w1:p1"]
                && store.hostSyncErrors[host.id] == nil
        }
        #expect(await transport.snapshotFetchCount >= 2)

        store.setHosts([])
    }

    /// Host milliseconds for a summary written `seconds` ago.
    private static func writtenAgo(_ seconds: TimeInterval) -> Int64 {
        Int64(Date().addingTimeInterval(-seconds).timeIntervalSince1970 * 1000)
    }

    /// The summary line a row shows now: its text and whether it is stale.
    private static func line(_ row: ConsoleAgent?) -> (text: String, isStale: Bool)? {
        guard case .summary(let text, _, let isStale) = row?.summaryLine(at: Date()) else {
            return nil
        }
        return (text, isStale)
    }

    @Test func aSummaryGoesStaleWhenItsAgentChangesStatusInsteadOfDisappearing() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .blocked)]))
        await transport.setAgentSummaries([
            AgentSummary(
                paneID: "w1:p1", status: .blocked, text: "approve merge of PR #512",
                timestamp: Self.writtenAgo(60))
        ])
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the Blocked summary should land fresh on its row") {
            Self.line(store.agents.first).map { $0.text == "approve merge of PR #512" && !$0.isStale }
                == true
        }
        try await waitUntil("the pane subscription should be live") {
            await transport.capturedSubscriptions.last?
                .contains(.pane(.agentStatusChanged, paneID: "w1:p1")) == true
        }

        await transport.setSnapshot(
            .fixture(agents: [.fixture(paneID: "w1:p1", status: .working)]))
        #expect(
            await transport.emit(.agentStatusChanged(paneID: "w1:p1", status: .working))
                == true)
        try await waitUntil("a working Agent should keep its Blocked summary, stale") {
            store.agents.first?.agent.status == .working
                && Self.line(store.agents.first).map {
                    $0.text == "approve merge of PR #512" && $0.isStale
                } == true
        }

        store.setHosts([])
    }

    @Test func eachRefreshTriggersThePluginThenRereadsTheStore() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .working)]))
        let store = makeStore(
            transports: [host.id: transport],
            summaryRefreshTiming: AgentSummaryRefreshTiming(
                interval: .seconds(30), settle: .milliseconds(300), debounce: .milliseconds(10)))

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the first refresh should trigger the plugin at once") {
            await transport.agentSummaryRefreshes == 1
        }
        // What the plugin writes after the trigger lands on the settle read.
        await transport.setAgentSummaries([
            AgentSummary(
                paneID: "w1:p1", status: .working, text: "adding upload retries",
                timestamp: Self.writtenAgo(1))
        ])
        try await waitUntil("the re-read after the settle should pick up the summary") {
            store.agents.first?.summary?.text == "adding upload retries"
        }
        #expect(await transport.agentSummaryRefreshes == 1)

        store.setHosts([])
    }

    @Test func refreshesRepeatEveryIntervalOnlyWhileTheAppIsInTheForeground() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .working)]))
        let store = makeStore(
            transports: [host.id: transport],
            summaryRefreshTiming: AgentSummaryRefreshTiming(
                interval: .milliseconds(100), settle: .milliseconds(10),
                debounce: .milliseconds(10)))

        store.setHosts([host])
        await store.resume()
        try await waitUntil("refreshes should keep coming") {
            await transport.agentSummaryRefreshes >= 3
        }

        store.setAgentSummaryForeground(false)
        try await Task.sleep(for: .milliseconds(50))
        let inBackground = await transport.agentSummaryRefreshes
        try await Task.sleep(for: .milliseconds(400))
        #expect(await transport.agentSummaryRefreshes == inBackground)

        store.setAgentSummaryForeground(true)
        try await waitUntil("returning to the foreground should refresh again") {
            await transport.agentSummaryRefreshes > inBackground
        }

        store.setHosts([])
    }

    @Test func turningSummariesOffHidesEveryLineAndStopsAskingTheHost() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .working)]))
        await transport.setAgentSummaries([
            AgentSummary(
                paneID: "w1:p1", status: .working, text: "adding upload retries",
                timestamp: Self.writtenAgo(10))
        ])
        let store = makeStore(
            transports: [host.id: transport],
            summaryRefreshTiming: AgentSummaryRefreshTiming(
                interval: .milliseconds(50), settle: .milliseconds(10),
                debounce: .milliseconds(10)))

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the summary should show") {
            store.agents.first?.summary?.text == "adding upload retries"
        }
        try await waitUntil("the pane subscription should be live") {
            await transport.capturedSubscriptions.last?
                .contains(.pane(.agentStatusChanged, paneID: "w1:p1")) == true
        }

        store.setAgentSummariesEnabled(false)
        #expect(store.agents.first?.summaryLine(at: Date()) == nil)
        try await Task.sleep(for: .milliseconds(50))
        let refreshes = await transport.agentSummaryRefreshes
        let reads = await transport.agentSummaryReads
        await transport.setSnapshot(.fixture(agents: [.fixture(paneID: "w1:p1", status: .done)]))
        #expect(await transport.emit(.agentStatusChanged(paneID: "w1:p1", status: .done)))
        try await Task.sleep(for: .milliseconds(300))
        #expect(await transport.agentSummaryRefreshes == refreshes)
        #expect(await transport.agentSummaryReads == reads)
        #expect(store.agents.first?.summaryLine(at: Date()) == nil)

        store.setAgentSummariesEnabled(true)
        try await waitUntil("turning it back on should read and refresh again") {
            let refreshed = await transport.agentSummaryRefreshes > refreshes
            let reread = await transport.agentSummaryReads > reads
            return refreshed && reread
                && store.agents.first?.summary?.text == "adding upload retries"
        }

        store.setHosts([])
    }

    /// A tombstone retires a Working Agent's summary, but its Host still
    /// reports progress: the progress bar keeps its pending rail (#189)
    /// until summaries are turned off.
    @Test func aRetiredSummaryKeepsAWorkingAgentsProgressPending() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .working)]))
        await transport.setAgentSummaries([
            AgentSummary(
                paneID: "w1:p1", status: .working, text: "adding upload retries",
                timestamp: Self.writtenAgo(10))
        ])
        let store = makeStore(
            transports: [host.id: transport],
            summaryRefreshTiming: AgentSummaryRefreshTiming(
                interval: .milliseconds(50), settle: .milliseconds(10),
                debounce: .milliseconds(10)))

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the summary should show") {
            store.agents.first?.summary?.text == "adding upload retries"
        }
        await transport.setAgentSummaries([])
        try await waitUntil("a re-read should retire the summary") {
            store.agents.first?.summary == nil && store.agents.first?.isSummaryPending == false
        }
        #expect(store.agents.first?.progressDisplay(at: Date()) == .pending)

        store.setAgentSummariesEnabled(false)
        #expect(store.agents.first?.progressDisplay(at: Date()) == nil)

        store.setHosts([])
    }

    /// An older plugin never writes the `progress` key, so its Host never
    /// reports progress and a Working Agent shows no dotted rail. What a
    /// connection learnt is forgotten on a reconnect: a Host whose plugin
    /// was downgraded meanwhile stops showing one.
    @Test func onlyAHostWhoseStoreDeclaresProgressShowsAPendingRailUntilItReconnects() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .working)]))
        await transport.setAgentSummaries([
            AgentSummary(
                paneID: "w1:p1", status: .working, text: "adding upload retries",
                timestamp: Self.writtenAgo(10), declaresProgress: true)
        ])
        let store = makeStore(
            transports: [host.id: transport],
            summaryRefreshTiming: AgentSummaryRefreshTiming(
                interval: .seconds(30), settle: .milliseconds(10), debounce: .milliseconds(10)))

        store.setHosts([host])
        await store.resume()
        try await waitUntil("a store declaring progress should show the pending rail") {
            store.agents.first?.summary != nil && store.agents.first?.progressDisplay(at: Date()) == .pending
        }

        await transport.setAgentSummaries([
            AgentSummary(
                paneID: "w1:p1", status: .working, text: "adding upload retries",
                timestamp: Self.writtenAgo(5), declaresProgress: false)
        ])
        let readsBefore = await transport.agentSummaryReads
        await transport.failEventStream(.channelFailed(detail: "connection dropped"))
        try await waitUntil("the reconnect should re-read the older plugin's store") {
            let reread = await transport.agentSummaryReads > readsBefore
            return reread && store.hostStatuses[host.id] == .connected
                && store.agents.first?.summary?.declaresProgress == false
        }
        #expect(store.agents.first?.hostReportsProgress == false)
        #expect(store.agents.first?.progressDisplay(at: Date()) == nil)

        store.setHosts([])
    }

    @Test func onlyOneRefreshRunsAtATimeAndAStatusChangeQueuesOneMore() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .working)]))
        let store = makeStore(
            transports: [host.id: transport],
            summaryRefreshTiming: AgentSummaryRefreshTiming(
                interval: .milliseconds(10), settle: .milliseconds(800),
                debounce: .milliseconds(10)))

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the first refresh should start") {
            await transport.agentSummaryRefreshes == 1
        }
        try await waitUntil("the pane subscription should be live") {
            await transport.capturedSubscriptions.last?
                .contains(.pane(.agentStatusChanged, paneID: "w1:p1")) == true
        }
        // Status changes and an elapsed interval while that one settles.
        for status in [AgentStatus.done, .working, .blocked] {
            await transport.setSnapshot(
                .fixture(agents: [.fixture(paneID: "w1:p1", status: status)]))
            #expect(await transport.emit(.agentStatusChanged(paneID: "w1:p1", status: status)))
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(await transport.agentSummaryRefreshes == 1)

        try await waitUntil("one queued refresh should follow the first") {
            await transport.agentSummaryRefreshes == 2
        }

        store.setHosts([])
    }

    @Test func aFailingHostBacksOffInsteadOfRefreshingOnEveryStatusChange() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .working)]))
        await transport.setAgentSummaryRefreshFailure(
            TransportError.channelFailed(detail: "exit 1"))
        let store = makeStore(
            transports: [host.id: transport],
            summaryRefreshTiming: AgentSummaryRefreshTiming(
                interval: .seconds(30), settle: .milliseconds(10), debounce: .milliseconds(10)))

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the first refresh should fail") {
            await transport.agentSummaryRefreshes == 1
        }
        try await waitUntil("the pane subscription should be live") {
            await transport.capturedSubscriptions.last?
                .contains(.pane(.agentStatusChanged, paneID: "w1:p1")) == true
        }
        await transport.setSnapshot(.fixture(agents: [.fixture(paneID: "w1:p1", status: .done)]))
        #expect(await transport.emit(.agentStatusChanged(paneID: "w1:p1", status: .done)))
        try await Task.sleep(for: .milliseconds(300))
        #expect(await transport.agentSummaryRefreshes == 1)

        store.setHosts([])
    }

    /// An older plugin has no refresh action: the trigger stops for the
    /// connection, and a status change still re-reads the store after the
    /// settle, which picks up what the plugin's Done push wrote.
    @Test func aPluginWithoutTheRefreshActionStillGetsItsDoneSummaryRead() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .working)]))
        await transport.setAgentSummaryRefreshFailure(AgentSummaryRefreshError.actionUnavailable)
        let store = makeStore(
            transports: [host.id: transport],
            summaryRefreshTiming: AgentSummaryRefreshTiming(
                interval: .milliseconds(20), settle: .milliseconds(300),
                debounce: .milliseconds(10)))

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the first trigger should find no action") {
            await transport.agentSummaryRefreshes == 1
                && store.agents.first?.isSummaryPending == false
        }
        try await waitUntil("the pane subscription should be live") {
            await transport.capturedSubscriptions.last?
                .contains(.pane(.agentStatusChanged, paneID: "w1:p1")) == true
        }

        await transport.setSnapshot(.fixture(agents: [.fixture(paneID: "w1:p1", status: .done)]))
        let readsBeforeDone = await transport.agentSummaryReads
        #expect(await transport.emit(.agentStatusChanged(paneID: "w1:p1", status: .done)))
        // The resync right after Done reads before the plugin has written.
        try await waitUntil("the Done resync should read the store") {
            await transport.agentSummaryReads > readsBeforeDone
        }
        await transport.setAgentSummaries([
            AgentSummary(
                paneID: "w1:p1", status: .done, text: "added upload retries",
                timestamp: Self.writtenAgo(1))
        ])
        try await waitUntil("the settled re-read should pick up the Done summary") {
            store.agents.first?.summary?.text == "added upload retries"
        }
        #expect(await transport.agentSummaryRefreshes == 1)

        store.setHosts([])
    }

    @Test func anAgentWithoutASummaryShowsLoadingOnlyUntilTheFirstRefreshLands() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .working)]))
        let store = makeStore(
            transports: [host.id: transport],
            summaryRefreshTiming: AgentSummaryRefreshTiming(
                interval: .seconds(30), settle: .milliseconds(500), debounce: .milliseconds(10)))

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the row should wait for its first summary") {
            await transport.agentSummaryRefreshes == 1
                && store.agents.first?.summaryLine(at: Date()) == .loading
        }
        // Off: no loading placeholder either.
        store.setAgentSummariesEnabled(false)
        #expect(store.agents.first?.summaryLine(at: Date()) == nil)
        store.setAgentSummariesEnabled(true)

        // The plugin wrote nothing (no model on this Host): the placeholder
        // ends with the refresh instead of loading forever.
        try await waitUntil("a finished refresh should end the loading state") {
            store.agents.first?.isSummaryPending == false
        }
        #expect(store.agents.first?.summaryLine(at: Date()) == nil)

        store.setHosts([])
    }

    @Test func anOldMissingPluginReadCannotDisableSummariesAfterReconnect() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .working)]))
        await transport.setAgentSummaryReadFailure(NotificationRegistrationError.pluginNotInstalled)
        let readGate = ScriptedTransportCallGate()
        await transport.gateNextAgentSummaryRead(using: readGate)
        let store = makeStore(transports: [host.id: transport])
        store.setHosts([host])
        await store.resume()
        await readGate.waitForEntry()
        // The first snapshot adds the pane subscription, whose answer
        // re-snapshots on the original connection. Count that one first, so
        // it cannot stand in for the new connection's verification below.
        try await waitUntil("the post-resubscribe resync should start") {
            await transport.snapshotFetchCount >= 2
        }
        let snapshotsBefore = await transport.snapshotFetchCount
        await transport.setAgentSummaryReadFailure(nil)
        await transport.setAgentSummaries([
            AgentSummary(
                paneID: "w1:p1", status: .working, text: "current connection",
                timestamp: Self.writtenAgo(1))
        ])
        await transport.failEventStream(.channelFailed(detail: "connection dropped during summary read"))
        try await waitUntil("the new connection should verify its inventory before the old read ends") {
            await transport.snapshotFetchCount > snapshotsBefore
                && store.hostStatuses[host.id] == .connected
                && !store.hostsAwaitingSnapshot.contains(host.id)
        }
        await readGate.open()
        try await waitUntil("the new connection should still read and refresh summaries") {
            let reads = await transport.agentSummaryReads
            let refreshes = await transport.agentSummaryRefreshes
            return reads >= 2 && refreshes >= 1
                && store.agents.first?.summary?.text == "current connection"
        }
        store.setHosts([])
    }

    @Test func aHostWithoutThePluginStopsBeingAskedForSummaries() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .idle)]))
        await transport.setAgentSummaryReadFailure(
            NotificationRegistrationError.pluginNotInstalled)
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the first snapshot should ask once") {
            await transport.agentSummaryReads == 1
                && store.agents.map(\.agent.paneID) == ["w1:p1"]
        }
        let snapshotsBefore = await transport.snapshotFetchCount
        #expect(
            await transport.emit(
                HerdrEvent(kind: GlobalEventKind.paneAgentDetected.kind, data: .object([:])))
                == true)
        try await waitUntil("a later snapshot should land") {
            await transport.snapshotFetchCount > snapshotsBefore
        }
        for _ in 0..<10 { await Task.yield() }
        #expect(await transport.agentSummaryReads == 1)

        store.setHosts([])
    }

    /// A refresh the link dropped under, while the Host still reads
    /// connected, waits for its interval instead of retrying at once.
    @Test func anInterruptedRefreshWaitsForTheIntervalInsteadOfRetryingAtOnce() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .working)]))
        await transport.setAgentSummaryRefreshFailure(TransportError.cancelled)
        let store = makeStore(
            transports: [host.id: transport],
            summaryRefreshTiming: AgentSummaryRefreshTiming(
                interval: .seconds(30), settle: .milliseconds(10), debounce: .milliseconds(10)))

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the first refresh should be interrupted") {
            await transport.agentSummaryRefreshes >= 1
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await transport.agentSummaryRefreshes == 1)
        #expect(store.hostStatuses[host.id] == .connected)

        store.setHosts([])
    }

    @Test func aHostWithoutThePluginNeverShowsTheLoadingPlaceholder() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .working)]))
        await transport.setAgentSummaryReadFailure(
            NotificationRegistrationError.pluginNotInstalled)
        let readGate = ScriptedTransportCallGate()
        await transport.gateNextAgentSummaryRead(using: readGate)
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        // The snapshot has landed; the read that finds no plugin has not.
        await readGate.waitForEntry()
        #expect(store.agents.map(\.agent.paneID) == ["w1:p1"])
        #expect(store.agents.first?.summaryLine(at: Date()) == nil)

        await readGate.open()
        for _ in 0..<10 { await Task.yield() }
        #expect(store.agents.first?.summaryLine(at: Date()) == nil)

        store.setHosts([])
    }

    /// An Agent the plugin never summarizes (no model on the Host) stops
    /// loading once a refresh covers it, and a reconnect does not bring the
    /// placeholder back for it.
    @Test func anAgentLeftWithoutASummaryDoesNotShowLoadingAgainAfterAReconnect() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .working)]))
        let store = makeStore(
            transports: [host.id: transport],
            summaryRefreshTiming: AgentSummaryRefreshTiming(
                interval: .seconds(30), settle: .milliseconds(10), debounce: .milliseconds(10)))

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the first refresh should end the loading state") {
            let refreshed = await transport.agentSummaryRefreshes == 1
            return refreshed && store.agents.first?.isSummaryPending == false
        }
        let readsBefore = await transport.agentSummaryReads

        await transport.failEventStream(.channelFailed(detail: "connection dropped"))
        try await waitUntil("the reconnect should re-read the store") {
            let reread = await transport.agentSummaryReads > readsBefore
            return reread && store.hostStatuses[host.id] == .connected
        }
        for _ in 0..<10 { await Task.yield() }
        #expect(store.agents.first?.summaryLine(at: Date()) == nil)
        #expect(await transport.agentSummaryRefreshes == 1)

        store.setHosts([])
    }

    /// A status change refreshes early without restarting the periodic
    /// clock: the plugin may have dropped that run as too soon after its
    /// last, and a Working Agent's next summary must not slip a whole
    /// interval.
    @Test func aStatusChangeRefreshDoesNotPushThePeriodicRefreshBack() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [
                .fixture(paneID: "w1:p1", status: .working),
                .fixture(paneID: "w1:p2", status: .working),
            ]))
        let store = makeStore(
            transports: [host.id: transport],
            summaryRefreshTiming: AgentSummaryRefreshTiming(
                interval: .seconds(1), settle: .milliseconds(10), debounce: .milliseconds(10)))

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the first periodic refresh should run") {
            await transport.agentSummaryRefreshes == 1
        }
        let periodicStart = ContinuousClock.now
        try await waitUntil("the pane subscription should be live") {
            await transport.capturedSubscriptions.last?
                .contains(.pane(.agentStatusChanged, paneID: "w1:p2")) == true
        }

        try await Task.sleep(until: periodicStart + .milliseconds(600), clock: .continuous)
        await transport.setSnapshot(
            .fixture(agents: [
                .fixture(paneID: "w1:p1", status: .working),
                .fixture(paneID: "w1:p2", status: .done),
            ]))
        #expect(await transport.emit(.agentStatusChanged(paneID: "w1:p2", status: .done)))
        try await waitUntil("the status change should refresh early") {
            await transport.agentSummaryRefreshes == 2
        }
        try await waitUntil("the periodic refresh should follow on its own schedule") {
            await transport.agentSummaryRefreshes == 3
        }
        #expect(ContinuousClock.now - periodicStart < .milliseconds(1350))

        store.setHosts([])
    }

    @Test func removingAHostDropsItsAgentsAndEndsItsSession() async throws {
        let hostA = Host.fixture(name: "alpha", address: "a.example")
        let hostB = Host.fixture(name: "beta", address: "b.example")
        let transports = [
            hostA.id: ScriptedTransport(
                snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")])),
            hostB.id: ScriptedTransport(
                snapshot: .fixture(agents: [.fixture(paneID: "w2:p1")])),
        ]
        let store = makeStore(transports: transports)

        store.setHosts([hostA, hostB])
        await store.resume()
        try await waitUntil("both agents should arrive") { store.agents.count == 2 }
        #expect(store.hostConnectionGenerations[hostB.id] == 0)

        store.setHosts([hostA])

        #expect(store.agents.map(\.agent.paneID) == ["w1:p1"])
        #expect(store.hostStatuses[hostB.id] == nil)
        #expect(store.hostConnectionGenerations[hostB.id] == nil)
        try await waitUntil("the removed Host's transport should close") {
            await transports[hostB.id]?.isClosed == true
        }

        store.setHosts([])
    }

    @Test func terminalRunnerOpensTheHostsLiveTransport() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture())
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the Host should connect") {
            store.hostStatuses[host.id] == .connected
        }

        let runner = store.terminalRunner(for: host.id)
        let request = TerminalAttachRequest(target: "w1:p1", cols: 80, rows: 24)
        try await runner(request, TerminalSessionHandler { _ in })
        #expect(await transport.attachRequests == [request])

        let missing = store.terminalRunner(for: UUID())
        await #expect(throws: TransportError.self) {
            try await missing(request, TerminalSessionHandler { _ in })
        }

        store.setHosts([])
    }

    @Test func terminalRunnerWaitsForPreviousTerminalTeardown() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture())
        let store = makeStore(transports: [host.id: transport])
        let gate = TerminalTeardownGate()
        let result = TerminalOperationResult()
        let request = TerminalAttachRequest(target: "w1:p1", cols: 80, rows: 24)

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the Host should connect") {
            store.hostStatuses[host.id] == .connected
        }

        let runner = store.terminalRunner(for: host.id)
        let first = Task {
            try await runner(
                request,
                TerminalSessionHandler { _ in
                    await gate.waitUntilOpen()
                })
        }
        try await waitUntil("the first terminal should open") {
            await transport.attachRequests.count == 1
        }
        let second = Task {
            try await runner(
                request,
                TerminalSessionHandler { _ in
                    await result.set()
                })
        }

        try await waitUntil("the previous teardown should start") {
            await gate.enteredCount == 1
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(await !result.wasSet)
        #expect(await transport.attachRequests.count == 1)

        await gate.open()
        try await first.value
        try await second.value
        #expect(await result.wasSet)
        #expect(await transport.attachRequests.count == 2)

        store.setHosts([])
    }

    @Test func cancellingQueuedTerminalDoesNotLeakExclusiveAccess() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture())
        let store = makeStore(transports: [host.id: transport])
        let gate = TerminalTeardownGate()
        let request = TerminalAttachRequest(target: "w1:p1", cols: 80, rows: 24)

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the Host should connect") {
            store.hostStatuses[host.id] == .connected
        }

        let runner = store.terminalRunner(for: host.id)
        let first = Task {
            try await runner(
                request,
                TerminalSessionHandler { _ in
                    await gate.waitUntilOpen()
                })
        }
        try await waitUntil("the first terminal should open") {
            await transport.attachRequests.count == 1
        }

        let cancelled = Task {
            try await runner(request, TerminalSessionHandler { _ in })
        }
        try await Task.sleep(for: .milliseconds(30))
        cancelled.cancel()
        await #expect(throws: CancellationError.self) {
            try await cancelled.value
        }

        await gate.open()
        try await first.value
        try await runner(request, TerminalSessionHandler { _ in })
        #expect(await transport.attachRequests.count == 2)

        store.setHosts([])
    }

    @Test func workspacesExposeTheHostsSnapshotWorkspaces() async throws {
        // The new-agent picker (#12) offers the workspaces the store already
        // knows for a Host, including ones with no agents in them yet.
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(
                agents: [.fixture(paneID: "w1:p1", workspaceID: "w1")],
                workspaces: [
                    .fixture(workspaceID: "w2", label: "Api"),
                    .fixture(workspaceID: "w1", label: "Proj"),
                ]))
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the snapshot's workspaces should land") {
            store.workspaces(for: host.id).count == 2
        }

        // Sorted by label; a Host the store never saw offers none.
        #expect(store.workspaces(for: host.id).map(\.label) == ["Api", "Proj"])
        #expect(store.workspaces(for: host.id).map(\.id) == ["w2", "w1"])
        #expect(store.workspaces(for: UUID()).isEmpty)

        store.setHosts([])
    }

    @Test func availableAgentKindsUseTheSelectedHostsLiveTransport() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport()
        await transport.setAvailableAgentKinds([.codex, .opencode])
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the Host should connect") {
            store.hostStatuses[host.id] == .connected
        }

        let kinds = try await store.availableAgentKinds(on: host.id)
        #expect(kinds == [.codex, .opencode])
        #expect(await transport.agentDiscoveryCount == 1)

        store.setHosts([])
    }

    @Test func availableAgentKindsRejectAnUnknownHost() async {
        let store = makeStore(transports: [:])

        await #expect(throws: TransportError.self) {
            _ = try await store.availableAgentKinds(on: UUID())
        }
    }

    @Test func startAgentForwardsItsParamsAndResnapshots() async throws {
        // Agent launch (#12): the request reaches the Host's transport, and the
        // started pane surfaces via one explicit resync rather than waiting
        // on the membership event.
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .idle)]))
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the initial agent should arrive") { store.agents.count == 1 }
        let snapshotsBefore = await transport.snapshotFetchCount

        // The started pane joins the next snapshot the server would report.
        await transport.setSnapshot(
            .fixture(agents: [
                .fixture(paneID: "w1:p1", status: .idle),
                .fixture(paneID: "w1:pnew", status: .working),
            ]))
        let started = try await store.startAgent(
            AgentLaunchRequest(kind: "claude", name: "claude", workspaceID: "w1"), on: host.id)

        #expect(started.status == .working)
        let starts = await transport.agentStarts
        #expect(starts.map(\.kind) == ["claude"])
        #expect(starts.map(\.arguments) == [[]])
        #expect(starts.first?.workspaceID == "w1")
        try await waitUntil("the resync should surface the new pane") {
            store.agents.map(\.agent.paneID) == ["w1:pnew", "w1:p1"]
        }
        #expect(await transport.snapshotFetchCount > snapshotsBefore)

        store.setHosts([])
    }

    @Test func startAgentInNewWorktreeForwardsTheSpecAndResnapshots() async throws {
        // The fresh-worktree launch (#97) rides the same machinery: the
        // request/spec pair reaches the Host's transport, and the started
        // pane surfaces via one explicit resync.
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture(agents: []))
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the Host should connect") {
            store.hostStatuses[host.id] == .connected
        }
        let snapshotsBefore = await transport.snapshotFetchCount

        await transport.setSnapshot(
            .fixture(agents: [.fixture(paneID: "wt1:pnew", status: .working, workspaceID: "wt1")]))
        let started = try await store.startAgentInNewWorktree(
            AgentLaunchRequest(kind: "claude", name: "reviewer", workspaceID: "w1"),
            worktree: WorktreeSpec(branch: "task/fix-97", base: .ref("origin/main")),
            on: host.id)

        #expect(started.workspaceID == "wt1")
        let starts = await transport.worktreeStarts
        #expect(starts.map { $0.request.workspaceID } == ["w1"])
        #expect(
            starts.map { $0.worktree }
                == [WorktreeSpec(branch: "task/fix-97", base: .ref("origin/main"))])
        try await waitUntil("the resync should surface the new pane") {
            store.agents.map(\.agent.paneID) == ["wt1:pnew"]
        }
        #expect(await transport.snapshotFetchCount > snapshotsBefore)

        store.setHosts([])
    }

    @Test func aWorktreeLaunchReplayedAfterALostCreateContinuesTheSameLaunch() async throws {
        // herdr answers `worktree.create` only after `git worktree add`, so a
        // try can time out after herdr acted. The Console's replay must hand
        // the Transport the same attempt, so it continues in that worktree
        // instead of creating a second one.
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture(agents: []))
        let store = makeStore(transports: [host.id: transport])
        store.setHosts([host])
        defer { store.setHosts([]) }
        await store.resume()
        try await waitUntil("the Host should connect") {
            store.hostStatuses[host.id] == .connected
        }
        await transport.setStartedAgent(
            .fixture(paneID: "wt1:p7", status: .working, workspaceID: "wt1"))
        await transport.loseNextWorktreeCreate()

        let started = try await store.startAgentInNewWorktree(
            AgentLaunchRequest(kind: "claude", name: "reviewer", workspaceID: "w1"),
            worktree: WorktreeSpec(branch: "task/fix", base: .latestDefaultBranch),
            on: host.id)

        #expect(started.paneID == "wt1:p7")
        #expect(await transport.worktreeCreateDispatches == 1)
        let attempts = await transport.worktreeStarts.map(\.attempt)
        #expect(attempts.count == 2)
    }

    @Test func twoWorktreeLaunchesInARowEachCreateTheirOwnWorktree() async throws {
        // A finished launch must not leave its attempt behind: the next
        // launch has to send its own `worktree.create`, not continue in the
        // worktree the first one made.
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture(agents: []))
        let store = makeStore(transports: [host.id: transport])
        store.setHosts([host])
        defer { store.setHosts([]) }
        await store.resume()
        try await waitUntil("the Host should connect") {
            store.hostStatuses[host.id] == .connected
        }
        await transport.setStartedAgent(
            .fixture(paneID: "wt1:p7", status: .working, workspaceID: "wt1"))

        for branch in ["task/first", "task/second"] {
            _ = try await store.startAgentInNewWorktree(
                AgentLaunchRequest(kind: "claude", name: "reviewer", workspaceID: "w1"),
                worktree: WorktreeSpec(branch: branch, base: .latestDefaultBranch),
                on: host.id)
        }

        #expect(await transport.worktreeCreateDispatches == 2)
        #expect(await transport.worktreeStarts.count == 2)
    }

    @Test func aShellWorktreeLaunchReplayedAfterALostCreateContinuesTheSameLaunch() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture(agents: []))
        let store = makeStore(transports: [host.id: transport])
        store.setHosts([host])
        defer { store.setHosts([]) }
        await store.resume()
        try await waitUntil("the Host should connect") {
            store.hostStatuses[host.id] == .connected
        }
        let shell = ShellLaunchResult(
            paneID: "wt1:p-shell", tabID: "wt1:t-shell", terminalID: "term-wt1",
            workspaceID: "wt1")
        await transport.setShellLaunchResult(shell)
        await transport.loseNextWorktreeCreate()

        let result = try await store.startShellTerminalInNewWorktree(
            ShellLaunchRequest(name: "fix", workspaceID: "w1"),
            worktree: WorktreeSpec(branch: nil, base: .sourceHead),
            on: host.id)

        #expect(result == shell)
        #expect(await transport.worktreeCreateDispatches == 1)
        let attempts = await transport.shellWorktreeAttempts
        #expect(attempts.count == 2)
    }

    @Test func launchStepsReachTheReporterBoundAroundTheConsoleLaunch() async throws {
        // The sheet binds its reporter around the Console call; the steps
        // the Transport reports (on the first try and on the replay) must
        // cross the Console and the session actor to reach it.
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture(agents: []))
        let store = makeStore(transports: [host.id: transport])
        store.setHosts([host])
        defer { store.setHosts([]) }
        await store.resume()
        try await waitUntil("the Host should connect") {
            store.hostStatuses[host.id] == .connected
        }
        await transport.loseNextWorktreeCreate()
        let steps = Mutex<[LaunchStep]>([])

        _ = try await LaunchProgress.$reporter.withValue({ step in
            steps.withLock { $0.append(step) }
        }) {
            try await store.startAgentInNewWorktree(
                AgentLaunchRequest(kind: "claude", name: "reviewer", workspaceID: "w1"),
                worktree: WorktreeSpec(), on: host.id)
        }

        #expect(steps.withLock { $0 } == [.creatingWorktree, .checkingForCreatedWorktree])
    }

    @Test func startAgentInNewWorkspaceForwardsTheSpecAndResnapshots() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture(agents: []))
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the Host should connect") {
            store.hostStatuses[host.id] == .connected
        }
        let snapshotsBefore = await transport.snapshotFetchCount

        await transport.setSnapshot(
            .fixture(agents: [.fixture(paneID: "nw1:pnew", status: .working, workspaceID: "nw1")]))
        let started = try await store.startAgentInNewWorkspace(
            AgentLaunchRequest(kind: "claude", name: "reviewer"),
            workspace: NewWorkspaceSpec(directory: "/src/app", label: "App"),
            on: host.id)

        #expect(started.workspaceID == "nw1")
        let starts = await transport.workspaceStarts
        #expect(starts.map { $0.request.kind } == ["claude"])
        #expect(starts.map { $0.request.workspaceID } == [nil])
        #expect(
            starts.map { $0.workspace }
                == [NewWorkspaceSpec(directory: "/src/app", label: "App")])
        try await waitUntil("the resync should surface the new pane") {
            store.agents.map(\.agent.paneID) == ["nw1:pnew"]
        }
        #expect(await transport.snapshotFetchCount > snapshotsBefore)

        store.setHosts([])
    }

    @Test func waitForAgentReturnsOnceTheResyncSurfacesThePane() async throws {
        // The new-agent flow opens the started pane's terminal; the wait
        // bridges the gap between the start RPC and the resync that makes
        // the Console row exist.
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture(agents: []))
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the Host should connect") {
            store.hostStatuses[host.id] == .connected
        }

        await transport.setSnapshot(
            .fixture(agents: [.fixture(paneID: "w1:pnew", status: .working)]))
        _ = try await store.startAgent(
            AgentLaunchRequest(kind: "claude", name: "claude", workspaceID: "w1"), on: host.id)
        await store.waitForAgent(ConsoleAgent.ID(hostID: host.id, paneID: "w1:pnew"))

        #expect(store.agents.map(\.agent.paneID) == ["w1:pnew"])

        store.setHosts([])
    }

    @Test func waitForAgentGivesUpAfterItsTimeout() async {
        let store = makeStore(transports: [:])
        let ghost = ConsoleAgent.ID(hostID: Host.fixture().id, paneID: "w1:ghost")

        // Never reported; the wait must return on its own rather than hang.
        await store.waitForAgent(ghost, timeout: .milliseconds(120))

        #expect(store.agents.isEmpty)
    }

    /// The fresh-session send bug: a launch's new pane forces the next resync
    /// to reinstall the pane subscription set, and a degraded link turns that
    /// reinstall into a silent transport replacement (no `.reconnecting`, the
    /// Host still reads `.connected`). The composer's first send used to die
    /// with `sshUnreachable` inside that window; it now waits out the redial
    /// and delivers on the replacement Transport.
    @Test func promptAgentSurvivesTheSilentTransportReplacement() async throws {
        let host = Host.fixture()
        let first = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .idle)]))
        let replacement = ScriptedTransport(
            snapshot: .fixture(agents: [
                .fixture(paneID: "w1:p1", status: .idle),
                .fixture(paneID: "w1:pnew", status: .idle),
            ]))
        let queue = ConnectionAttemptQueue([.success(first), .success(replacement)])
        let connectGate = ScriptedTransportCallGate()
        let store = ConsoleStore(
            snapshotRetryDelay: .milliseconds(10),
            pins: PinnedAgentsStore(
                defaults: UserDefaults(suiteName: "hm-console-pins-\(UUID().uuidString)")
                    ?? .standard)
        ) { host, _, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: {
                    let transport = try await queue.next()
                    let dial = await queue.attemptCount
                    if dial > 1 {
                        await connectGate.waitUntilOpen()
                    }
                    return transport
                },
                reconnectPolicy: Self.fastPolicy,
                keepalive: nil)
        }

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the initial Agent should arrive") {
            store.agents.map(\.agent.paneID) == ["w1:p1"]
        }

        // The launched pane's membership change forces the reinstall, and
        // the degraded link makes it a silent redial held closed by the gate.
        await first.setSnapshot(
            .fixture(agents: [
                .fixture(paneID: "w1:p1", status: .idle),
                .fixture(paneID: "w1:pnew", status: .idle),
            ]))
        await first.setConnectionAlive(false)
        #expect(
            await first.emit(
                HerdrEvent(kind: GlobalEventKind.paneAgentDetected.kind, data: .object([:])))
            == true)
        try await waitUntil("the reinstall should hold the replacement dial closed") {
            await connectGate.entryCount == 1
        }

        let prompt = Task {
            try await store.promptAgent(
                AgentPromptParams(target: "w1:pnew", text: "hello"), on: host.id)
        }
        // The redial is still closed; the old fail-fast behavior would
        // already have surfaced `sshUnreachable` here.
        try await Task.sleep(for: .milliseconds(50))
        await connectGate.open()
        let prompted = try await prompt.value

        #expect(prompted.paneID == "w1:pnew")
        try await waitUntil("the send should have landed on the replacement") {
            let params = await replacement.agentPromptParams
            return params.map(\.target) == ["w1:pnew"] && params.map(\.text) == ["hello"]
        }

        store.setHosts([])
    }

    @Test func startAgentThrowsWhenTheHostIsUnknown() async throws {
        let host = Host.fixture()
        let store = makeStore(transports: [:])

        // No feed for this Host at all: nothing to start against.
        await #expect(throws: TransportError.self) {
            try await store.startAgent(
                AgentLaunchRequest(kind: "claude", name: "claude"), on: host.id)
        }
    }

    @Test func closePaneForwardsItsTargetAndResnapshots() async throws {
        // pane.close (#13, User Story 9): the target reaches the Host's
        // transport, and the removed pane disappears via one explicit resync
        // rather than waiting on the pane.closed membership event.
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [
                .fixture(paneID: "w1:p1", status: .idle),
                .fixture(paneID: "w1:p2", status: .idle),
            ]))
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("both agents should arrive") { store.agents.count == 2 }
        try await waitUntil("the post-resubscribe resync should start") {
            await transport.snapshotFetchCount >= 2
        }
        let snapshotsBefore = await transport.snapshotFetchCount

        // The closed pane is gone from the next snapshot the server reports.
        await transport.setSnapshot(
            .fixture(agents: [.fixture(paneID: "w1:p1", status: .idle)]))
        try await store.closePane("w1:p2", on: host.id)

        let closed = await transport.closedPanes
        #expect(closed.map(\.paneID) == ["w1:p2"])
        // The close drops the row at once; the resync it asks for follows.
        try await waitUntil("the resync should drop the closed pane") {
            store.agents.map(\.agent.paneID) == ["w1:p1"]
        }
        try await waitUntil("closing the pane should ask for a resnapshot") {
            await transport.snapshotFetchCount > snapshotsBefore
        }

        store.setHosts([])
    }

    @Test func closePaneThrowsWhenTheHostIsUnknown() async throws {
        let host = Host.fixture()
        let store = makeStore(transports: [:])

        // No feed for this Host at all: nothing to close against.
        await #expect(throws: TransportError.self) {
            try await store.closePane("w1:p1", on: host.id)
        }
    }

    @Test func closePaneFailureLeavesTheAgentsUntouched() async throws {
        // The cancel/failure path must never mutate the list: a rejected
        // close propagates and leaves every agent in place.
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .idle)]))
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the agent should arrive") { store.agents.count == 1 }

        await transport.setCloseFailure(.timedOut)
        await #expect(throws: TransportError.timedOut) {
            try await store.closePane("w1:p1", on: host.id)
        }
        #expect(store.agents.map(\.agent.paneID) == ["w1:p1"])
        #expect(await transport.closedPanes.isEmpty)

        store.setHosts([])
    }

    @Test func closeAgentTabClosesTheSharedTabAndDropsItsPins() async throws {
        // tab.close (#8 swipe action): the target reaches the Host's
        // transport, and every agent pinned on that tab is unpinned — the
        // tab close destroys them all, so a pin must not dangle onto an id
        // herdr could reuse.
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [
                .fixture(paneID: "w1:p1", status: .idle),
                .fixture(paneID: "w1:p2", status: .idle),
                .fixture(paneID: "w2:p1", status: .idle, workspaceID: "w2"),
            ]))
        let store = makeStore(transports: [host.id: transport])
        store.setHosts([host])
        defer { store.setHosts([]) }
        await store.resume()
        try await waitUntil("all agents should arrive") { store.agents.count == 3 }
        store.togglePin(hostID: host.id, paneID: "w1:p1")
        store.togglePin(hostID: host.id, paneID: "w1:p2")
        store.togglePin(hostID: host.id, paneID: "w2:p1")

        // Two agents share w1's tab; closing it targets the tab id once and
        // drops both pins while the untouched w2 pin survives.
        let victim = try #require(store.agents.first { $0.agent.paneID == "w1:p1" })
        try await store.closeAgentTab(victim)

        #expect(await transport.closedTabs == [TabTarget(tabID: "w1:t1")])
        #expect(!store.pins.isPinned(hostID: host.id, paneID: "w1:p1"))
        #expect(!store.pins.isPinned(hostID: host.id, paneID: "w1:p2"))
        #expect(store.pins.isPinned(hostID: host.id, paneID: "w2:p1"))
    }

    @Test func closeAgentTabThrowsWhenTheHostIsUnknown() async throws {
        let host = Host.fixture()
        let store = makeStore(transports: [:])
        let agent = consoleAgent(
            hostID: host.id, hostName: host.name, paneID: "w1:p1", status: .idle)

        await #expect(throws: TransportError.self) {
            try await store.closeAgentTab(agent)
        }
    }

    @Test func moveAgentForwardsToItsHostAndRekeysItsPinAndUnreadMark() async throws {
        // pane.move (drag-to-workspace): the destination reaches the Host's
        // transport, and the moved Agent's pin and unread mark re-key onto
        // the new pane id herdr reports in the reply — while pins and marks
        // on panes the move did not re-key survive untouched.
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(
                agents: [
                    .fixture(paneID: "w1:p1", status: .idle),
                    .fixture(paneID: "w1:p2", status: .idle),
                    .fixture(paneID: "w2:p1", status: .idle, workspaceID: "w2"),
                ],
                workspaces: [
                    .fixture(workspaceID: "w1", label: "Proj", repoName: "proj"),
                    .fixture(workspaceID: "w2", label: "Api"),
                ]))
        let store = makeStore(transports: [host.id: transport])
        store.setHosts([host])
        defer { store.setHosts([]) }
        await store.resume()
        try await waitUntil("all agents should arrive") { store.agents.count == 3 }
        store.togglePin(hostID: host.id, paneID: "w1:p1")
        store.togglePin(hostID: host.id, paneID: "w2:p1")
        let movedID = ConsoleAgent.ID(hostID: host.id, paneID: "w1:p1")
        let siblingID = ConsoleAgent.ID(hostID: host.id, paneID: "w1:p2")
        let newID = ConsoleAgent.ID(hostID: host.id, paneID: "w2:moved")
        store.markUnread(try #require(store.agents.first { $0.id == movedID }))
        store.markUnread(try #require(store.agents.first { $0.id == siblingID }))

        // The next snapshot already reflects the move: herdr re-keyed the
        // pane (w1:p1 → w2:moved) and the emptied tab closed.
        await transport.setSnapshot(
            .fixture(
                agents: [
                    .fixture(paneID: "w1:p2", status: .idle),
                    .fixture(paneID: "w2:p1", status: .idle, workspaceID: "w2"),
                    .fixture(paneID: "w2:moved", status: .idle, workspaceID: "w2"),
                ],
                workspaces: [
                    .fixture(workspaceID: "w1", label: "Proj", repoName: "proj"),
                    .fixture(workspaceID: "w2", label: "Api"),
                ]))

        let victim = try #require(store.agents.first { $0.agent.paneID == "w1:p1" })
        let response = try await store.moveAgent(victim, toWorkspaceID: "w2", on: host.id)

        #expect(
            await transport.paneMoves
                == [PaneMoveParams(
                    destination: .newTab(PaneMoveDestinationNewTab(workspaceID: "w2")),
                    paneID: "w1:p1")])
        // The reply carries the re-keyed pane.
        #expect(response?.moveResult.pane.paneID == "w2:moved")
        // The moved pin re-keys; the untouched w2:p1 pin survives.
        #expect(!store.pins.isPinned(hostID: host.id, paneID: "w1:p1"))
        #expect(store.pins.isPinned(hostID: host.id, paneID: "w2:moved"))
        #expect(store.pins.isPinned(hostID: host.id, paneID: "w2:p1"))
        // The mark moves too, and the rows still listing the old id until
        // the resync do not count the new pane as gone.
        #expect(!store.unread.isMarkedUnread(movedID))
        #expect(store.unread.isMarkedUnread(newID))
        #expect(store.unread.isMarkedUnread(siblingID))
        // The post-RPC resync converges the list, still listing it unread.
        try await waitUntil("the resync should show the moved agent") {
            store.agents.contains { $0.agent.paneID == "w2:moved" }
        }
        #expect(store.unread.isMarkedUnread(newID))
        #expect(store.indexAgents(holding: nil).first { $0.id == newID }?.agent.status == .done)
    }

    @Test func aSnapshotLandingMidMoveKeepsTheMovedAgentsUnreadMark() async throws {
        // herdr moves the pane before its `pane.move` reply names the new
        // id: a resync landing in between no longer lists the old pane and
        // must not settle its mark as gone before the reply re-keys it.
        let host = Host.fixture()
        let workspaces: [WorkspaceInfo] = [
            .fixture(workspaceID: "w1", label: "Proj"),
            .fixture(workspaceID: "w2", label: "Api"),
        ]
        let transport = ScriptedTransport(
            snapshot: .fixture(
                agents: [
                    .fixture(paneID: "w1:p1", status: .idle),
                    .fixture(paneID: "w2:p1", status: .idle, workspaceID: "w2"),
                ],
                workspaces: workspaces))
        let store = makeStore(transports: [host.id: transport])
        store.setHosts([host])
        defer { store.setHosts([]) }
        await store.resume()
        try await waitUntil("the pane subscriptions should settle") {
            await transport.capturedSubscriptions.last?.contains(
                .pane(.agentStatusChanged, paneID: "w1:p1")) == true
                && store.agents.count == 2
        }
        let movedID = ConsoleAgent.ID(hostID: host.id, paneID: "w1:p1")
        let newID = ConsoleAgent.ID(hostID: host.id, paneID: "w2:moved")
        let victim = try #require(store.agents.first { $0.id == movedID })
        store.markUnread(victim)

        let moveGate = ScriptedTransportCallGate()
        await transport.gateNextPaneMove(using: moveGate)
        let move = Task { try await store.moveAgent(victim, toWorkspaceID: "w2", on: host.id) }
        await moveGate.waitForEntry()

        // herdr has applied the move; its `pane.moved` event resyncs while
        // the reply is still in flight.
        await transport.setSnapshot(
            .fixture(
                agents: [
                    .fixture(paneID: "w2:p1", status: .idle, workspaceID: "w2"),
                    .fixture(paneID: "w2:moved", status: .idle, workspaceID: "w2"),
                ],
                workspaces: workspaces))
        #expect(
            await transport.emit(HerdrEvent(kind: GlobalEventKind.paneMoved.kind, data: .object([:])))
                == true)
        try await waitUntil("the mid-move snapshot should drop the old pane") {
            !store.agents.contains { $0.id == movedID }
        }
        #expect(store.unread.isMarkedUnread(movedID))

        await moveGate.open()
        let response = try await move.value
        #expect(response?.moveResult.pane.paneID == "w2:moved")
        #expect(!store.unread.isMarkedUnread(movedID))
        #expect(store.unread.isMarkedUnread(newID))
        #expect(store.indexAgents(holding: nil).first { $0.id == newID }?.agent.status == .done)
    }

    @Test func aMarkTakenAfterAStatusDeltaSurvivesTheResyncThatReportsItsSequence() async throws {
        // A `pane.agent_status_changed` delta turns the row Idle in place but
        // carries no `stateChangeSeq`: the row still holds the Working
        // snapshot's. A mark taken before the resync must not record that
        // stale sequence, or the resync's newer one reads as fresh activity.
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(
                agents: [.fixture(paneID: "w1:p1", status: .working, stateChangeSeq: 4)]))
        let store = makeStore(transports: [host.id: transport])
        store.setHosts([host])
        defer { store.setHosts([]) }
        await store.resume()
        try await waitUntil("the pane subscription should settle") {
            await transport.capturedSubscriptions.last?.contains(
                .pane(.agentStatusChanged, paneID: "w1:p1")) == true
                && store.agents.first?.agent.stateChangeSeq == 4
        }

        let snapshotGate = ScriptedTransportCallGate()
        await transport.gateNextSnapshot(using: snapshotGate)
        await transport.setSnapshot(
            .fixture(agents: [.fixture(paneID: "w1:p1", status: .idle, stateChangeSeq: 5)]))
        #expect(await transport.emit(.agentStatusChanged(paneID: "w1:p1", status: .idle)) == true)
        try await waitUntil("the delta should land while its resync is held") {
            await snapshotGate.entryCount == 1 && store.agents.first?.agent.status == .idle
        }
        let id = ConsoleAgent.ID(hostID: host.id, paneID: "w1:p1")
        store.markUnread(try #require(store.agents.first))
        #expect(store.unread.isMarkedUnread(id))

        await snapshotGate.open()
        try await waitUntil("the resync should report the Idle row's sequence") {
            store.agents.first?.agent.stateChangeSeq == 5
        }
        #expect(store.unread.isMarkedUnread(id))
        #expect(store.indexAgents(holding: nil).first?.agent.status == .done)
    }

    @Test func aMarkOnTheHeldAgentReTakesItsHeldRowAndAnyOtherMarkLeavesIt() async throws {
        // A window (an iPad split view's open Agent) holds the row it opened
        // so the Agent's own changes do not move it. Marking that Agent must
        // re-take the hold, or it keeps its Idle place under a Done badge;
        // marking another Agent must leave it where it was.
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [
                .fixture(paneID: "w1:p1", status: .idle, stateChangeSeq: 1),
                .fixture(paneID: "w1:p2", status: .idle, stateChangeSeq: 2),
            ]))
        let store = makeStore(transports: [host.id: transport])
        store.setHosts([host])
        defer { store.setHosts([]) }
        await store.resume()
        try await waitUntil("the pane subscriptions should settle") {
            await transport.capturedSubscriptions.last?.contains(
                .pane(.agentStatusChanged, paneID: "w1:p1")) == true
                && store.agents.count == 2
        }
        let open = ConsoleAgent.ID(hostID: host.id, paneID: "w1:p1")
        let other = ConsoleAgent.ID(hostID: host.id, paneID: "w1:p2")
        var held = try #require(store.listedAgent(open))
        #expect(store.indexAgents(holding: held).map(\.id) == [other, open])

        store.markUnread(held)
        #expect(store.indexAgents(holding: held).map(\.id) == [other, open], "a stale hold keeps the Idle place")
        held = try #require(store.held(held, afterMarkChangeOn: open))
        #expect(held.agent.status == .done)
        #expect(store.indexAgents(holding: held).map(\.id) == [open, other])

        store.markRead(open)
        held = try #require(store.held(held, afterMarkChangeOn: open))
        #expect(held.agent.status == .idle)
        #expect(store.indexAgents(holding: held).map(\.id) == [other, open])

        // The open Agent blocks: the hold keeps its Idle place below `other`.
        await transport.setSnapshot(
            .fixture(agents: [
                .fixture(paneID: "w1:p1", status: .blocked, stateChangeSeq: 3),
                .fixture(paneID: "w1:p2", status: .idle, stateChangeSeq: 2),
            ]))
        #expect(await transport.emit(.agentStatusChanged(paneID: "w1:p1", status: .blocked)) == true)
        try await waitUntil("the open Agent should be Blocked") {
            store.agents.first { $0.id == open }?.agent.stateChangeSeq == 3
        }
        #expect(store.indexAgents(holding: held).map(\.id) == [other, open])

        // Marking the other Agent leaves the hold: its Done leads the held
        // Idle row, where a hold re-taken from the live Blocked row would.
        store.markUnread(try #require(store.agents.first { $0.id == other }))
        held = try #require(store.held(held, afterMarkChangeOn: other))
        #expect(store.indexAgents(holding: held).map(\.id) == [other, open])
    }

    @Test func markUnreadReportsWhetherTheAgentIsNowMarked() async throws {
        // The Agent screen's Mark as Unread goes back to the index only when
        // the mark took: an Agent that started working since the menu opened,
        // or one already marked, keeps the person where they are.
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [
                .fixture(paneID: "w1:p1", status: .idle, stateChangeSeq: 1),
                .fixture(paneID: "w1:p2", status: .working, stateChangeSeq: 2),
            ]))
        let store = makeStore(transports: [host.id: transport])
        store.setHosts([host])
        defer { store.setHosts([]) }
        await store.resume()
        try await waitUntil("both agents should arrive") { store.agents.count == 2 }
        let idle = try #require(
            store.agents.first { $0.id == ConsoleAgent.ID(hostID: host.id, paneID: "w1:p1") })
        let working = try #require(
            store.agents.first { $0.id == ConsoleAgent.ID(hostID: host.id, paneID: "w1:p2") })

        #expect(!store.markUnread(working))
        #expect(!store.unread.isMarkedUnread(working.id))
        #expect(store.markUnread(idle))
        #expect(store.unread.isMarkedUnread(idle.id))
        #expect(!store.markUnread(idle))
    }

    @Test func moveAgentToItsOwnWorkspaceIsASilentNoOp() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(
                agents: [.fixture(paneID: "w1:p1", status: .idle)],
                workspaces: [.fixture(workspaceID: "w1", label: "Proj")]))
        let store = makeStore(transports: [host.id: transport])
        store.setHosts([host])
        defer { store.setHosts([]) }
        await store.resume()
        try await waitUntil("the agent should arrive") { store.agents.count == 1 }

        let agent = try #require(store.agents.first)
        let response = try await store.moveAgent(agent, toWorkspaceID: "w1", on: host.id)

        #expect(response == nil)
        #expect(await transport.paneMoves.isEmpty)
    }

    @Test func moveAgentThrowsWhenTheHostIsUnknown() async throws {
        let host = Host.fixture()
        let store = makeStore(transports: [:])
        let agent = consoleAgent(
            hostID: host.id, hostName: host.name, paneID: "w1:p1", status: .idle)

        await #expect(throws: TransportError.self) {
            try await store.moveAgent(agent, toWorkspaceID: "w2", on: host.id)
        }
    }

    @Test func focusAgentForwardsOpaqueTargetToItsHostAndResnapshotsAllRows() async throws {
        let host = Host.fixture()
        let otherHost = Host.fixture(name: "Other")
        let paneID = "opaque:Pane/A"
        let done: [AgentInfo] = [
            .fixture(paneID: paneID, status: .done),
            .fixture(paneID: "sibling", status: .done),
        ]
        let transport = ScriptedTransport(snapshot: .fixture(agents: done))
        let otherTransport = ScriptedTransport(snapshot: .fixture(agents: done))
        let store = makeStore(transports: [host.id: transport, otherHost.id: otherTransport])
        store.setHosts([host, otherHost])
        defer { store.setHosts([]) }
        await store.resume()
        try await waitUntil("both Hosts should be ready") { store.agents.count == 4 }
        // Drain subscription-triggered startup snapshots before counting calls.
        await store.refreshSidebarLayouts()
        let before = await transport.snapshotFetchCount
        await transport.setSnapshot(.fixture(agents: [
            .fixture(paneID: paneID, status: .idle),
            .fixture(paneID: "sibling", status: .idle),
        ]))
        try await store.focusAgent(paneID, on: host.id)
        #expect(await transport.agentFocuses == [AgentTarget(target: paneID)])
        #expect(await otherTransport.agentFocuses.isEmpty)
        try await waitUntil("the full Host snapshot should mark both rows Idle") {
            store.agents.filter { $0.hostID == host.id }.map(\.agent.status) == [.idle, .idle]
        }
        #expect(await transport.snapshotFetchCount > before)
        #expect(
            store.agents.filter { $0.hostID == otherHost.id }
                .allSatisfy { $0.agent.status == .done })
    }

    @Test func focusFailurePreservesDoneAndDoesNotRequestASuccessResnapshot() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "pane", status: .done)]))
        let store = makeStore(transports: [host.id: transport])
        store.setHosts([host])
        defer { store.setHosts([]) }
        await store.resume()
        try await waitUntil("the Done Agent should arrive") { store.agents.count == 1 }
        await store.refreshSidebarLayouts()
        let before = await transport.snapshotFetchCount
        await transport.setFocusFailure(.timedOut)
        await #expect(throws: TransportError.timedOut) {
            try await store.focusAgent("pane", on: host.id)
        }
        // The single retry rides the replacement, so the focus reaches the
        // transport once per attempt.
        #expect(await transport.agentFocuses == [
            AgentTarget(target: "pane"), AgentTarget(target: "pane"),
        ])
        // The redial ends the stale events channel, and the fresh
        // `.connected` that follows is the consumer's usual re-snapshot
        // signal: exactly one resync beyond the pre-focus count. A FAILED
        // focus must not add a success resync on top of it.
        try await waitUntil("the reconnect resync should land") {
            await transport.snapshotFetchCount == before + 1
        }
        // Give an incorrectly scheduled success refresh time to reach the transport.
        try await Task.sleep(for: .milliseconds(25))
        #expect(await transport.snapshotFetchCount == before + 1)
        #expect(store.agents.map(\.agent.status) == [.done])
    }

    @Test func focusDoesNotSendWhenTheAgentHasAlreadyLeftDone() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture(agents: [
            .fixture(paneID: "working", status: .working),
            .fixture(paneID: "idle", status: .idle),
        ]))
        let store = makeStore(transports: [host.id: transport])
        store.setHosts([host])
        defer { store.setHosts([]) }
        await store.resume()
        try await waitUntil("the Agents should arrive") { store.agents.count == 2 }
        for paneID in ["working", "idle"] {
            await #expect(throws: CancellationError.self) {
                try await store.focusAgent(paneID, on: host.id)
            }
        }
        #expect(await transport.agentFocuses.isEmpty)
    }

    @Test func focusRejectsUnavailableHostAndMissingAgent() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture())
        let store = makeStore(transports: [host.id: transport])
        await #expect(throws: TransportError.self) {
            try await store.focusAgent("missing", on: host.id)
        }
        store.setHosts([host])
        defer { store.setHosts([]) }
        await store.resume()
        try await waitUntil("the empty inventory should be known") {
            store.hostStatuses[host.id] == .connected
                && !store.hostsAwaitingSnapshot.contains(host.id)
        }
        await #expect(throws: TransportError.apiRejected(
            code: "agent_not_found", message: "The Agent is no longer listed.")) {
            try await store.focusAgent("missing", on: host.id)
        }
        await store.suspend()
        await #expect(throws: TransportError.self) {
            try await store.focusAgent("missing", on: host.id)
        }
        #expect(await transport.agentFocuses.isEmpty)
    }

    @Test func renameAgentForwardsItsParamsAndResnapshots() async throws {
        // agent.rename (#98): the params reach the Host's transport, the new
        // name shows as soon as herdr confirms (#105), and one explicit
        // resync follows — pane.updated is not a resync trigger (it fires on
        // every terminal-title change). The resync is told apart by content,
        // a status only the Host's snapshot carries: how many snapshots ran
        // is not this test's to pin, since the scheduled resync races the
        // confirmed edit.
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .idle)]))
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the agent should arrive") { store.agents.count == 1 }

        await transport.setSnapshot(
            .fixture(agents: [.fixture(paneID: "w1:p1", status: .working, name: "reviewer")]))
        try await store.renameAgent("w1:p1", name: "reviewer", on: host.id)

        let renames = await transport.agentRenames
        #expect(renames == [AgentRenameParams(target: "w1:p1", name: "reviewer")])
        #expect(store.agents.map(\.agent.displayName) == ["reviewer"])
        try await waitUntil("the resync should land the Host's row") {
            store.agents.map(\.agent.status) == [.working]
        }
        #expect(store.agents.map(\.agent.displayName) == ["reviewer"])

        store.setHosts([])
    }

    @Test func renameAgentForwardsANilNameAsTheClear() async throws {
        // A nil name clears the custom name back to the detected kind
        // (verified live against herdr 0.7.5); the transport must see the
        // nil, not an empty string.
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [
                .fixture(paneID: "w1:p1", status: .idle, name: "reviewer")
            ]))
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the agent should arrive") {
            store.agents.map(\.agent.displayName) == ["reviewer"]
        }

        await transport.setSnapshot(
            .fixture(agents: [.fixture(paneID: "w1:p1", status: .idle)]))
        try await store.renameAgent("w1:p1", name: nil, on: host.id)

        let renames = await transport.agentRenames
        #expect(renames == [AgentRenameParams(target: "w1:p1", name: nil)])
        try await waitUntil("the resync should fall back to the detected kind") {
            store.agents.map(\.agent.displayName) == ["claude"]
        }

        store.setHosts([])
    }

    @Test func renameWorkspaceForwardsItsParamsAndResnapshots() async throws {
        // workspace.rename (#98): the params reach the Host's transport and
        // the relabeled workspace lands via one explicit resync rather than
        // waiting on the workspace.renamed membership event.
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(workspaces: [.fixture(workspaceID: "w1", label: "Old")]))
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the workspace should arrive") {
            store.workspaces(for: host.id).map(\.label) == ["Old"]
        }

        await transport.setSnapshot(
            .fixture(workspaces: [.fixture(workspaceID: "w1", label: "New")]))
        try await store.renameWorkspace("w1", label: "New", on: host.id)

        let renames = await transport.workspaceRenames
        #expect(renames == [WorkspaceRenameParams(label: "New", workspaceID: "w1")])
        try await waitUntil("the resync should surface the new label") {
            store.workspaces(for: host.id).map(\.label) == ["New"]
        }

        store.setHosts([])
    }

    @Test func renamesThrowWhenTheHostIsUnknown() async throws {
        let host = Host.fixture()
        let store = makeStore(transports: [:])

        await #expect(throws: TransportError.self) {
            try await store.renameAgent("w1:p1", name: "x", on: host.id)
        }
        await #expect(throws: TransportError.self) {
            try await store.renameWorkspace("w1", label: "x", on: host.id)
        }
    }

    @Test func renameFailurePropagatesAndLeavesTheAgentsUntouched() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .idle)]))
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the agent should arrive") { store.agents.count == 1 }

        await transport.setRenameFailure(.timedOut)
        await #expect(throws: TransportError.timedOut) {
            try await store.renameAgent("w1:p1", name: "x", on: host.id)
        }
        #expect(store.agents.map(\.agent.displayName) == ["claude"])
        #expect(await transport.agentRenames.isEmpty)

        store.setHosts([])
    }

    @Test func liveTelemetrySourceSamplesOnlyConnectedHosts() async throws {
        let connected = Host.fixture()
        let connecting = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture())
        let usage = HostResourceUsage(cpu: 0.25, memory: 0.5, swap: 0.125)
        await transport.scriptHostResourceUsage([.success(usage)])
        let held = ScriptedTransport(snapshot: .fixture())
        let connectPing = ScriptedTransportCallGate()
        await held.gateNextPing(using: connectPing)
        let store = makeStore(transports: [connected.id: transport, connecting.id: held])

        store.setHosts([connected, connecting])
        await store.resume()
        try await waitUntil("one Host connects while the other's connect ping is held") {
            let heldPing = await connectPing.entryCount == 1
            return store.hostStatuses[connected.id] == .connected
                && !store.hostsAwaitingSnapshot.contains(connected.id) && heldPing
        }
        #expect(store.hostStatuses[connecting.id] == .connecting)
        #expect(store.connectedHostIDs == [connected.id])

        let pingsBefore = await transport.pingCount
        #expect(await store.sampleLatency(on: connected.id))
        #expect(await transport.pingCount == pingsBefore + 1)
        #expect(await transport.revalidateCount == 0)

        #expect(await store.sampleLatency(on: connecting.id) == false)
        #expect(await held.pingCount == 1)
        #expect(await store.sampleLatency(on: UUID()) == false)

        #expect(try await store.hostResourceUsage(on: connected.id) == usage)
        #expect(await transport.hostResourceUsageCount == 1)

        await connectPing.open()
        store.setHosts([])
    }

    /// The Hosts sheet's samples are non-critical connect work (#105): a
    /// Host whose connection is up but whose first snapshot has not landed is
    /// not sampled yet, so the resource exec never races that snapshot or an
    /// attach on the fresh connection. It is sampled once the snapshot lands.
    @Test func liveTelemetryWaitsForTheFirstSnapshot() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture())
        let snapshot = ScriptedTransportCallGate()
        await transport.gateNextSnapshot(using: snapshot)
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the Host connects with its first snapshot held") {
            let held = await snapshot.entryCount == 1
            return store.hostStatuses[host.id] == .connected && held
        }
        #expect(store.hostsAwaitingSnapshot.contains(host.id))
        #expect(store.connectedHostIDs.isEmpty)

        await snapshot.open()
        try await waitUntil("the snapshot lands and the Host becomes sampleable") {
            store.connectedHostIDs == [host.id]
        }
        store.setHosts([])
    }

    @Test func hostStatusesExposeStalenessPerHost() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture())
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the Host should report connected") {
            store.hostStatuses[host.id] == .connected
        }
        try await waitUntil("the Host should publish its ping latency") {
            store.hostLatencies[host.id] != nil
        }

        await store.suspend()
        try await waitUntil("the Host should report suspended") {
            store.hostStatuses[host.id] == .suspended
        }

        store.setHosts([])
        #expect(store.hostLatencies.isEmpty)
    }

    /// A latency belongs to the connection that measured it (#236), and the
    /// projection folds both from one ordered source — so every assertion here
    /// is made the instant the status is observable, with nothing waited for
    /// in between. Neither the Hosts sheet nor Agent detail can present a
    /// number the current connection never proved, and neither is left blank
    /// while it has one.
    @Test func hostLatencyIsPairedWithTheConnectionThatMeasuredIt() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture())
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the Host should report connected") {
            store.hostStatuses[host.id] == .connected
        }
        // Not waited for: the connect ping answered before `.connected` was
        // published, so the number is already here.
        #expect(store.hostLatencies[host.id] != nil)

        await store.suspend()
        try await waitUntil("the Host should report suspended") {
            store.hostStatuses[host.id] == .suspended
        }
        // Absent, not zero and not the previous measurement: the Host is
        // still in the catalog, only its proof is gone.
        #expect(store.hostLatencies[host.id] == nil)

        // Hold the replacement connection's ping open. Any latency published
        // in this window could only be the suspended connection's.
        let gate = ScriptedTransportCallGate()
        await transport.gateNextPing(using: gate)
        await store.resume()
        try await waitUntil("the replacement connection should be pinging") {
            await gate.entryCount == 1
        }
        #expect(store.hostLatencies[host.id] == nil)

        await gate.open()
        try await waitUntil("the reconnected Host should report connected") {
            store.hostStatuses[host.id] == .connected
        }
        #expect(store.hostLatencies[host.id] != nil)

        store.setHosts([])
    }

    @Test func resumedHostStaysUnverifiedUntilItsReplacementSnapshotLands() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .working)]))
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the initial Agent should arrive") {
            store.agents.map(\.agent.paneID) == ["w1:p1"]
        }
        #expect(!store.hostsAwaitingSnapshot.contains(host.id))

        await store.suspend()
        try await waitUntil("suspension should end the snapshot's authority") {
            store.hostStatuses[host.id] == .suspended
        }
        #expect(store.hostsAwaitingSnapshot.contains(host.id))
        #expect(store.agents.map(\.agent.paneID) == ["w1:p1"])

        let snapshotGate = ScriptedTransportCallGate()
        await transport.gateNextSnapshot(using: snapshotGate)
        await store.resume()
        try await waitUntil("the replacement snapshot should be in flight") {
            let snapshotEntered = await snapshotGate.entryCount == 1
            return store.hostStatuses[host.id] == .connected && snapshotEntered
        }

        #expect(store.agents.map(\.agent.paneID) == ["w1:p1"])
        #expect(store.hostsAwaitingSnapshot.contains(host.id))

        await snapshotGate.open()
        try await waitUntil("the replacement snapshot should verify the Agent") {
            store.agents.map(\.agent.paneID) == ["w1:p1"]
                && !store.hostsAwaitingSnapshot.contains(host.id)
        }

        store.setHosts([])
    }

    @Test func retryHostReconnectsOnlyTheRequestedFailedHost() async throws {
        let hostA = Host.fixture(name: "alpha", address: "a.example")
        let hostB = Host.fixture(name: "beta", address: "b.example")
        let transportA = ScriptedTransport(snapshot: .fixture())
        let transportB = ScriptedTransport(snapshot: .fixture())
        let queues = [
            hostA.id: ConnectionAttemptQueue([
                .failure(.authenticationFailed),
                .success(transportA),
            ]),
            hostB.id: ConnectionAttemptQueue([
                .failure(.authenticationFailed),
                .success(transportB),
            ]),
        ]
        let store = ConsoleStore(snapshotRetryDelay: .milliseconds(10)) {
            host, _, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: {
                    guard let queue = queues[host.id] else {
                        throw TransportError.sshUnreachable(detail: "unscripted host")
                    }
                    return try await queue.next()
                },
                reconnectPolicy: Self.fastPolicy,
                keepalive: nil)
        }

        store.setHosts([hostA, hostB])
        await store.resume()
        try await waitUntil("both Hosts should stop on authentication failure") {
            store.hostStatuses[hostA.id] == .failed(.authenticationFailed)
                && store.hostStatuses[hostB.id] == .failed(.authenticationFailed)
        }

        await store.retryHost(hostA.id)
        try await waitUntil("only the requested Host should reconnect") {
            store.hostStatuses[hostA.id] == .connected
        }

        #expect(store.hostStatuses[hostB.id] == .failed(.authenticationFailed))
        #expect(await queues[hostA.id]?.attemptCount == 2)
        #expect(await queues[hostB.id]?.attemptCount == 1)
        #expect(await transportB.capturedSubscriptions.isEmpty)

        store.setHosts([])
    }

    @Test func retryHostRestartsOnlyTheRequestedConnectedHost() async throws {
        let hostA = Host.fixture(name: "alpha", address: "a.example")
        let hostB = Host.fixture(name: "beta", address: "b.example")
        let queues = [
            hostA.id: ConnectionAttemptQueue([
                .success(ScriptedTransport(snapshot: .fixture())),
                .success(ScriptedTransport(snapshot: .fixture())),
            ]),
            hostB.id: ConnectionAttemptQueue([
                .success(ScriptedTransport(snapshot: .fixture())),
            ]),
        ]
        let store = ConsoleStore(snapshotRetryDelay: .milliseconds(10)) {
            host, _, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: {
                    guard let queue = queues[host.id] else {
                        throw TransportError.sshUnreachable(detail: "unscripted host")
                    }
                    return try await queue.next()
                },
                reconnectPolicy: Self.fastPolicy,
                keepalive: nil)
        }

        store.setHosts([hostA, hostB])
        await store.resume()
        try await waitUntil("both Hosts should connect") {
            store.hostStatuses[hostA.id] == .connected
                && store.hostStatuses[hostB.id] == .connected
        }

        await store.retryHost(hostA.id)
        try await waitUntil("the requested Host should start a new connection") {
            await queues[hostA.id]?.attemptCount == 2
        }

        #expect(await queues[hostB.id]?.attemptCount == 1)

        store.setHosts([])
    }

    @Test func eventChannelReconnectReusesHostConnectionGeneration() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")]))
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the initial subscribe cycle should settle") {
            let subscriptions = await transport.capturedSubscriptions
            return subscriptions.count >= 2
                && store.hostStatuses[host.id] == .connected
        }
        #expect(store.hostConnectionGenerations[host.id] == 0)

        await transport.failEventStream(.channelFailed(detail: "connection dropped"))
        try await waitUntil("the event channel should reconnect on the same transport") {
            let subscriptions = await transport.capturedSubscriptions
            return subscriptions.count >= 3
                && store.hostStatuses[host.id] == .connected
        }
        #expect(store.hostConnectionGenerations[host.id] == 0)

        store.setHosts([])
    }

    @Test func subscriptionResubscribeDoesNotAdvanceConnectionGeneration() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")]))
        let store = makeStore(transports: [host.id: transport])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the initial subscribe cycle should settle") {
            let snapshotCount = await transport.snapshotFetchCount
            let subscriptions = await transport.capturedSubscriptions
            return snapshotCount >= 2 && subscriptions.count >= 2
        }
        let snapshotsBeforeMembershipChange = await transport.snapshotFetchCount

        await transport.setSnapshot(
            .fixture(agents: [
                .fixture(paneID: "w1:p1"),
                .fixture(paneID: "w1:p2"),
            ]))
        #expect(
            await transport.emit(
                HerdrEvent(kind: GlobalEventKind.paneAgentDetected.kind, data: .object([:])))
                == true)
        try await waitUntil("the changed pane subscription should reconnect its event stream") {
            let subscriptions = await transport.capturedSubscriptions
            let snapshotCount = await transport.snapshotFetchCount
            return snapshotCount >= snapshotsBeforeMembershipChange + 2
                && subscriptions.last?.contains(
                    .pane(.agentStatusChanged, paneID: "w1:p2")) == true
                && store.hostStatuses[host.id] == .connected
        }
        #expect(store.hostConnectionGenerations[host.id] == 0)

        store.setHosts([])
    }

    @Test func linkedWorktreeRemovalRecordsOnlyItsAffectedAgents() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: linkedWorktreeSnapshot(
                workspaces: [
                    ("w1", "one", "/work/one-wt"),
                    ("w2", "two", "/work/two-wt"),
                ]))
        let store = makeStore(transports: [host.id: transport])
        store.setHosts([host])
        await store.resume()
        try await waitUntil("both linked-worktree Agents should arrive") {
            store.agents.count == 2
        }
        let first = try #require(store.agents.first { $0.agent.workspaceID == "w1" })
        let checkout = try #require(first.repositoryCheckout)
        let request = WorktreeRemovalRequest(
            identity: WorktreeIdentity(
                hostID: host.id, workspaceID: "w1", checkout: checkout))
        let unaffected = try #require(store.agents.first { $0.agent.workspaceID == "w2" })
        await transport.setSnapshot(
            linkedWorktreeSnapshot(workspaces: [("w2", "two", "/work/two-wt")]))

        let receipt = try await store.removeWorktree(request, on: host.id)

        #expect(await transport.removedWorktreeRequests == [request])
        #expect(receipt.affectedAgentIDs == [first.id])
        try await waitUntil("the post-removal snapshot should retain only the unaffected Agent") {
            store.agents.map(\.id) == [unaffected.id]
                && store.removedWorktreesByAgent[first.id] == receipt
                && store.removedWorktreesByAgent[unaffected.id] == nil
        }
        store.setHosts([])
    }

    @Test func staleIdentityAtTheWriteBoundarySendsNoRemoval() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: linkedWorktreeSnapshot(workspaces: [("w1", "one", "/work/one-wt")]))
        let gate = ScriptedTransportCallGate()
        await transport.gateNextWorktreeAuthorization(using: gate)
        let store = makeStore(transports: [host.id: transport])
        store.setHosts([host])
        await store.resume()
        try await waitUntil("the linked-worktree Agent should arrive") {
            store.agents.first?.isLinkedWorktree == true
        }
        let agent = try #require(store.agents.first)
        let checkout = try #require(agent.repositoryCheckout)
        let request = WorktreeRemovalRequest(
            identity: WorktreeIdentity(
                hostID: host.id, workspaceID: "w1", checkout: checkout))
        let removal = Task { try await store.removeWorktree(request, on: host.id) }

        try await waitUntil("remove should be waiting immediately before authorization") {
            await gate.entryCount == 1
        }
        await transport.setSnapshot(
            linkedWorktreeSnapshot(workspaces: [("w1", "replacement", "/work/reused-wt")]))
        #expect(
            await transport.emit(
                HerdrEvent(
                    kind: GlobalEventKind.workspaceMetadataUpdated.kind,
                    data: .object([:]))) == true)
        try await waitUntil("the replacement identity should become the latest snapshot") {
            store.agents.first?.checkoutPath == "/work/reused-wt"
        }
        await gate.open()

        await #expect(throws: WorktreeRemovalError.staleIdentity) {
            try await removal.value
        }
        #expect(await transport.removedWorktreeRequests.isEmpty)
        #expect(store.removedWorktreesByAgent.isEmpty)
        store.setHosts([])
    }

    @Test func canonicalizedRemovalPathDoesNotOverrideWorkspaceIdentity() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: linkedWorktreeSnapshot(workspaces: [("w1", "one", "/var/work/one-wt")]))
        await transport.setWorktreeRemoveResponsePath("/private/var/work/one-wt")
        let store = makeStore(transports: [host.id: transport])
        store.setHosts([host])
        await store.resume()
        try await waitUntil("the linked-worktree Agent should arrive") {
            store.agents.first?.isLinkedWorktree == true
        }
        let agent = try #require(store.agents.first)
        let request = WorktreeRemovalRequest(
            identity: WorktreeIdentity(
                hostID: host.id,
                workspaceID: "w1",
                checkout: try #require(agent.repositoryCheckout)))

        let receipt = try await store.removeWorktree(request, on: host.id)

        #expect(receipt.request == request)
        #expect(await transport.removedWorktreeRequests == [request])
        store.setHosts([])
    }

    @Test func laterSnapshotPrunesReceiptForRecreatedExactIdentity() async throws {
        let host = Host.fixture()
        let linked = linkedWorktreeSnapshot(
            workspaces: [("w1", "one", "/work/one-wt")])
        let transport = ScriptedTransport(snapshot: linked)
        let store = makeStore(transports: [host.id: transport])
        store.setHosts([host])
        await store.resume()
        try await waitUntil("the original linked-worktree Agent should arrive") {
            store.agents.first?.isLinkedWorktree == true
        }
        let agent = try #require(store.agents.first)
        let request = WorktreeRemovalRequest(
            identity: WorktreeIdentity(
                hostID: host.id,
                workspaceID: "w1",
                checkout: try #require(agent.repositoryCheckout)))
        await transport.setSnapshot(.fixture())

        _ = try await store.removeWorktree(request, on: host.id)
        try await waitUntil("the absent snapshot should retain the removal receipt") {
            store.agents.isEmpty && store.removedWorktreesByAgent[agent.id]?.request == request
        }

        await transport.setSnapshot(linked)
        #expect(
            await transport.emit(
                HerdrEvent(
                    kind: GlobalEventKind.workspaceMetadataUpdated.kind,
                    data: .object([:]))) == true)
        try await waitUntil("the recreated exact identity should clear the old receipt") {
            store.agents.first?.repositoryCheckout == agent.repositoryCheckout
                && store.removedWorktreesByAgent[agent.id] == nil
        }
        store.setHosts([])
    }

    @Test func staleInflightSnapshotCannotPruneNewRemovalReceipt() async throws {
        let host = Host.fixture()
        let linked = linkedWorktreeSnapshot(
            workspaces: [("w1", "one", "/work/one-wt")])
        let transport = ScriptedTransport(snapshot: linked)
        let store = makeStore(transports: [host.id: transport])
        store.setHosts([host])
        await store.resume()
        try await waitUntil("the pane subscription should settle") {
            await transport.capturedSubscriptions.last?.contains(
                .pane(.agentStatusChanged, paneID: "w1:p1")) == true
        }
        let agent = try #require(store.agents.first)
        let request = WorktreeRemovalRequest(
            identity: WorktreeIdentity(
                hostID: host.id,
                workspaceID: "w1",
                checkout: try #require(agent.repositoryCheckout)))

        let staleSnapshotGate = ScriptedTransportCallGate()
        await transport.gateNextSnapshot(using: staleSnapshotGate)
        #expect(
            await transport.emit(
                HerdrEvent(
                    kind: GlobalEventKind.workspaceMetadataUpdated.kind,
                    data: .object([:]))) == true)
        try await waitUntil("the pre-removal snapshot should be in flight") {
            await staleSnapshotGate.entryCount == 1
        }

        let convergenceSnapshotGate = ScriptedTransportCallGate()
        await transport.setSnapshot(.fixture())
        await transport.gateNextSnapshot(using: convergenceSnapshotGate)
        let receipt = try await store.removeWorktree(request, on: host.id)
        #expect(store.removedWorktreesByAgent[agent.id] == receipt)

        await staleSnapshotGate.open()
        try await waitUntil("the post-removal convergence snapshot should start") {
            await convergenceSnapshotGate.entryCount == 1
        }
        #expect(store.agents.first?.repositoryCheckout == agent.repositoryCheckout)
        #expect(store.removedWorktreesByAgent[agent.id] == receipt)
        #expect(
            RemovedWorktreeSelection.receipt(
                for: agent.id,
                agents: store.agents,
                receipts: store.removedWorktreesByAgent) == receipt)

        await convergenceSnapshotGate.open()
        try await waitUntil("the post-removal snapshot should converge") {
            store.agents.isEmpty && store.removedWorktreesByAgent[agent.id] == receipt
        }
        #expect(
            RemovedWorktreeSelection.receipt(
                for: agent.id,
                agents: store.agents,
                receipts: store.removedWorktreesByAgent) == receipt)
        store.setHosts([])
    }

    @Test func repeatedAndConcurrentRemovalRequestsStayDistinct() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: linkedWorktreeSnapshot(
                workspaces: [
                    ("w1", "one", "/work/one-wt"),
                    ("w2", "two", "/work/two-wt"),
                ]))
        let gate = ScriptedTransportCallGate()
        await transport.gateNextWorktreeAuthorization(using: gate)
        let store = makeStore(transports: [host.id: transport])
        store.setHosts([host])
        await store.resume()
        try await waitUntil("both Agents should arrive") { store.agents.count == 2 }
        let one = try #require(store.agents.first { $0.agent.workspaceID == "w1" })
        let two = try #require(store.agents.first { $0.agent.workspaceID == "w2" })
        let requestOne = WorktreeRemovalRequest(
            identity: WorktreeIdentity(
                hostID: host.id,
                workspaceID: "w1",
                checkout: try #require(one.repositoryCheckout)))
        let requestTwo = WorktreeRemovalRequest(
            identity: WorktreeIdentity(
                hostID: host.id,
                workspaceID: "w2",
                checkout: try #require(two.repositoryCheckout)))
        let first = Task { try await store.removeWorktree(requestOne, on: host.id) }
        try await waitUntil("the first request should wait at authorization") {
            await gate.entryCount == 1
        }

        await #expect(throws: WorktreeRemovalError.alreadyInProgress) {
            try await store.removeWorktree(requestOne, on: host.id)
        }
        let second = Task { try await store.removeWorktree(requestTwo, on: host.id) }
        await gate.open()
        _ = try await first.value
        _ = try await second.value

        let requests = await transport.removedWorktreeRequests
        #expect(requests.count == 2)
        #expect(Set(requests) == [requestOne, requestTwo])
        store.setHosts([])
    }

    @Test func serverAndTransportFailuresHaveDeterministicOutcomes() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: linkedWorktreeSnapshot(workspaces: [("w1", "one", "/work/one-wt")]))
        let store = makeStore(transports: [host.id: transport])
        store.setHosts([host])
        await store.resume()
        try await waitUntil("the Agent should arrive") { store.agents.count == 1 }
        let agent = try #require(store.agents.first)
        let checkout = try #require(agent.repositoryCheckout)

        await transport.setWorktreeRemoveFailure(
            HerdrAPIError(code: "dirty_worktree_requires_force", message: "dirty"))
        let rejected = WorktreeRemovalRequest(
            identity: WorktreeIdentity(
                hostID: host.id, workspaceID: "w1", checkout: checkout))
        await #expect(throws: HerdrAPIError.self) {
            try await store.removeWorktree(rejected, on: host.id)
        }
        #expect(store.removedWorktreesByAgent.isEmpty)

        await transport.setWorktreeRemoveFailure(TransportError.timedOut)
        await transport.setSnapshot(.fixture())
        let uncertain = WorktreeRemovalRequest(
            identity: WorktreeIdentity(
                hostID: host.id, workspaceID: "w1", checkout: checkout))
        await #expect(throws: WorktreeRemovalError.outcomeUnconfirmed) {
            try await store.removeWorktree(uncertain, on: host.id)
        }
        try await waitUntil("a newer absent snapshot should resolve the exact removal") {
            store.removedWorktreesByAgent[agent.id]?.request == uncertain
        }
        store.setHosts([])
    }

    private func linkedWorktreeSnapshot(
        workspaces: [(id: String, name: String, path: String)]
    ) -> SessionSnapshot {
        .fixture(
            agents: workspaces.map {
                .fixture(paneID: "\($0.id):p1", workspaceID: $0.id)
            },
            workspaces: workspaces.map {
                .fixture(
                    workspaceID: $0.id,
                    label: $0.name,
                    repoName: $0.name,
                    checkoutPath: $0.path,
                    isLinkedWorktree: true)
            })
    }

    /// A store whose session factory hands each Host the next transport in
    /// its scripted sequence, so tests can drive SSH-level replacement.
    private func makeStore(transportQueues: [Host.ID: TransportQueue]) -> ConsoleStore {
        ConsoleStore(snapshotRetryDelay: .milliseconds(10)) { host, _, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: {
                    guard let queue = transportQueues[host.id] else {
                        throw TransportError.sshUnreachable(detail: "unscripted host")
                    }
                    return try await queue.next()
                },
                reconnectPolicy: Self.fastPolicy,
                keepalive: nil)
        }
    }

    @Test func transportReplacementAdvancesHostConnectionGeneration() async throws {
        // The one path that must advance the projected generation: the SSH
        // connection dies and the session installs a replacement Transport.
        // This is the detail screen's only automatic-reattach trigger.
        let host = Host.fixture()
        let first = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")]))
        let second = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")]))
        let store = makeStore(
            transportQueues: [host.id: TransportQueue([first, second])])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the first transport should connect") {
            store.hostStatuses[host.id] == .connected
        }
        #expect(store.hostConnectionGenerations[host.id] == 0)

        // Kill the SSH connection outright: the stream ends and
        // `isConnected` flips false, so the reconnect must replace the
        // Transport instead of resubscribing on it.
        try await first.close()
        try await waitUntil("the replacement transport should connect") {
            let resubscribed = await second.capturedSubscriptions.isEmpty == false
            return resubscribed && store.hostStatuses[host.id] == .connected
        }
        try await waitUntil("the projected generation should advance") {
            store.hostConnectionGenerations[host.id] == 1
        }

        store.setHosts([])
    }

    @Test func terminalRunnerAndImageStagerSurviveAHostEdit() async throws {
        // The Attach screen holds its runner and stager for its whole
        // lifetime. Editing the Host replaces the projection and ends its
        // session; a call through the old handles must resolve the live
        // projection instead of staying bound to the ended session.
        let host = Host.fixture(name: "alpha")
        let first = ScriptedTransport(snapshot: .fixture())
        let second = ScriptedTransport(snapshot: .fixture())
        let store = makeStore(
            transportQueues: [host.id: TransportQueue([first, second])])

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the first transport should connect") {
            store.hostStatuses[host.id] == .connected
        }
        let runner = store.terminalRunner(for: host.id)
        let stager = store.imageStager(for: host.id)

        var edited = host
        edited.name = "alpha (renamed)"
        store.setHosts([edited])
        try await waitUntil("the replacement projection should connect") {
            let resubscribed = await second.capturedSubscriptions.isEmpty == false
            return resubscribed && store.hostStatuses[host.id] == .connected
        }

        let request = TerminalAttachRequest(target: "w1:p1", cols: 80, rows: 24)
        try await runner(request, TerminalSessionHandler { _ in })
        #expect(await second.attachRequests == [request])
        #expect(await first.attachRequests.isEmpty)

        let prepared = PreparedImage(
            fileURL: URL(fileURLWithPath: "/tmp/attach-test.jpg"),
            format: .jpeg, pixelWidth: 16, pixelHeight: 16, byteCount: 128)
        await second.configureImageStaging(
            outcomes: [.success(try StagedImage(path: "/tmp/staged/attach-test.jpg"))])
        let staged = try await stager(prepared, AttachmentStageProgressReporter { _ in })
        #expect(staged.path == "/tmp/staged/attach-test.jpg")
        #expect(await second.stageRequests.count == 1)
        #expect(await first.stageRequests.isEmpty)

        store.setHosts([])
    }

    // MARK: Host key trust (NET-04)

    private static nonisolated let healthyPing = Result<ServerInfo, TransportError>.success(
        ServerInfo(version: "0.7.5", protocolVersion: 17))

    /// The production session factory against the fake connector, which
    /// replays TOFU and records every dial. Trust is re-checked every 10 ms.
    private func makeTrustStore(
        connector: FakeTransportConnector, knownHosts: InMemoryKnownHostsStore,
        trustHolds: HostKeyTrustHoldReporter = HostKeyTrustHoldReporter()
    ) -> ConsoleStore {
        ConsoleStore(
            snapshotRetryDelay: .milliseconds(10),
            makeSession: ConsoleStore.sshSessionFactory(
                connector: connector,
                knownHosts: knownHosts,
                credentials: Self.emptyCredentials(),
                trustPollInterval: .milliseconds(10),
                trustHolds: trustHolds,
                reconnectPolicy: Self.fastPolicy),
            trustHolds: trustHolds)
    }

    private static func emptyCredentials() -> HostCredentialsProvider {
        HostCredentialsProvider(
            deviceKeys: DeviceKeyStore(secrets: InMemorySecretStore()),
            rsaKeys: RSAKeyStore(secrets: InMemorySecretStore()),
            secrets: InMemorySecretStore())
    }

    private func row(_ store: ConsoleStore, _ host: Host) -> ConsoleHostStatusPresentation? {
        ConsoleHostStatusPresentation(
            host: host,
            status: store.hostStatuses[host.id],
            trustHold: store.hostKeyTrustHolds[host.id],
            syncError: nil)
    }

    private func holdRow(_ host: Host, _ hold: HostKeyTrustHold) -> ConsoleHostStatusPresentation? {
        ConsoleHostStatusPresentation(host: host, status: .connecting, trustHold: hold, syncError: nil)
    }

    @Test func anUnreachableHostWithNoTrustedKeyShowsTheFailureNotATrustWait() async throws {
        // A Host that never answered presented no key, so there is nothing
        // to trust. The real connector fails an unresolvable name as a
        // timeout.
        let host = Host.fixture(address: "unresolvable.invalid")
        let connector = FakeTransportConnector(
            outcome: .unreachable(.timedOut), presentedKeyBlob: Data("never-seen".utf8))
        let trustHolds = HostKeyTrustHoldReporter()
        let history = TrustHoldHistory()
        await history.start(trustHolds)
        let store = makeTrustStore(
            connector: connector, knownHosts: InMemoryKnownHostsStore(), trustHolds: trustHolds)
        defer { store.setHosts([]) }

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the Console should dial and fail on the network error") {
            if case .reconnecting(_, _, .timedOut) = store.hostStatuses[host.id] { true } else { false }
        }
        #expect(try await history.flushed(trustHolds).holds(for: host.id).isEmpty)
        #expect(
            row(store, host)
                == ConsoleHostStatusPresentation(
                    host: host, status: store.hostStatuses[host.id], syncError: nil))
    }

    @Test func aNewHostWaitsForTrustInsteadOfFailingThenConnectsOnItsOwn() async throws {
        // Add Manually → Save starts the Console while the Host page asks
        // "Trust this Host?". The Host answers with a key nobody trusted
        // yet, so the Console holds instead of failing, does not redial
        // while held, and dials again without a Reconnect once the page
        // stores the key.
        let host = Host.fixture(address: "new.example")
        let keyBlob = Data("new-host-key".utf8)
        let knownHosts = InMemoryKnownHostsStore()
        let connector = FakeTransportConnector(
            outcome: .connects(pingResult: Self.healthyPing), presentedKeyBlob: keyBlob)
        let trustHolds = HostKeyTrustHoldReporter()
        let history = TrustHoldHistory()
        await history.start(trustHolds)
        let store = makeTrustStore(connector: connector, knownHosts: knownHosts, trustHolds: trustHolds)
        defer { store.setHosts([]) }

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the hold should be re-reported while held") {
            await history.holds(for: host.id).count(where: { $0 == .host }) >= 3
        }
        #expect(await connector.capturedSettings.count == 1)
        #expect(store.hostStatuses[host.id] == .connecting)
        #expect(row(store, host) == holdRow(host, .host))

        await knownHosts.setFingerprint(
            HostKeyFingerprint(publicKeyBlob: keyBlob), host: host.address, port: host.port)
        try await waitUntil("the Console should connect once the key is trusted") {
            await connector.transports.isEmpty == false && store.hostKeyTrustHolds[host.id] == nil
        }
        #expect(await connector.capturedSettings.count == 2)
    }

    @Test func anUntrustedJumpHostHoldsTheConsoleEvenWhenTheHostIsTrusted() async throws {
        var host = Host.fixture(address: "inner.example")
        host.jumpAddress = "jump.example"
        host.jumpPort = 2222
        let keyBlob = Data("inner-host-key".utf8)
        let jumpBlob = Data("jump-host-key".utf8)
        let knownHosts = InMemoryKnownHostsStore()
        await knownHosts.setFingerprint(
            HostKeyFingerprint(publicKeyBlob: keyBlob), host: host.address, port: host.port)
        let connector = FakeTransportConnector(
            outcome: .connects(pingResult: Self.healthyPing), presentedKeyBlob: keyBlob,
            presentedJumpKeyBlob: jumpBlob)
        let store = makeTrustStore(connector: connector, knownHosts: knownHosts)
        defer { store.setHosts([]) }

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the hold should name the Jump Host") {
            store.hostKeyTrustHolds[host.id] == .jumpHost
        }
        #expect(await connector.transports.isEmpty)

        await knownHosts.setFingerprint(
            HostKeyFingerprint(publicKeyBlob: jumpBlob),
            host: host.jumpAddress, port: host.jumpPort)
        try await waitUntil("the Console should connect once the Jump Host is trusted") {
            await connector.transports.isEmpty == false && store.hostKeyTrustHolds[host.id] == nil
        }
    }

    @Test func anUnreachableJumpHostShowsTheFailureNotATrustWait() async throws {
        var host = Host.fixture(address: "inner.example")
        host.jumpAddress = "jump.example"
        host.jumpPort = 2222
        let failure = TransportError.jumpHostFailed(.timedOut)
        let connector = FakeTransportConnector(
            outcome: .unreachable(failure), presentedKeyBlob: Data("inner".utf8),
            presentedJumpKeyBlob: Data("jump".utf8))
        let trustHolds = HostKeyTrustHoldReporter()
        let history = TrustHoldHistory()
        await history.start(trustHolds)
        let store = makeTrustStore(
            connector: connector, knownHosts: InMemoryKnownHostsStore(), trustHolds: trustHolds)
        defer { store.setHosts([]) }

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the Console should show the Jump Host's failure") {
            if case .reconnecting(_, _, failure) = store.hostStatuses[host.id] { true } else { false }
        }
        #expect(try await history.flushed(trustHolds).holds(for: host.id).isEmpty)
    }

    @Test func aChangedJumpHostKeyStillStopsTheConsole() async throws {
        var host = Host.fixture(address: "inner.example")
        host.jumpAddress = "jump.example"
        host.jumpPort = 2222
        let keyBlob = Data("inner-host-key".utf8)
        let trustedJump = HostKeyFingerprint(publicKeyBlob: Data("trusted-jump".utf8))
        let presentedJump = Data("replaced-jump".utf8)
        let knownHosts = InMemoryKnownHostsStore()
        await knownHosts.setFingerprint(
            HostKeyFingerprint(publicKeyBlob: keyBlob), host: host.address, port: host.port)
        await knownHosts.setFingerprint(trustedJump, host: host.jumpAddress, port: host.jumpPort)
        let connector = FakeTransportConnector(
            outcome: .connects(pingResult: Self.healthyPing), presentedKeyBlob: keyBlob,
            presentedJumpKeyBlob: presentedJump)
        let trustHolds = HostKeyTrustHoldReporter()
        let history = TrustHoldHistory()
        await history.start(trustHolds)
        let store = makeTrustStore(connector: connector, knownHosts: knownHosts, trustHolds: trustHolds)
        defer { store.setHosts([]) }

        store.setHosts([host])
        await store.resume()
        let mismatch = TransportError.jumpHostFailed(
            .hostKeyMismatch(
                known: trustedJump, presented: HostKeyFingerprint(publicKeyBlob: presentedJump)))
        try await waitUntil("a changed Jump Host key should stop the Console") {
            store.hostStatuses[host.id] == .failed(mismatch)
        }
        #expect(try await history.flushed(trustHolds).holds(for: host.id).isEmpty)
    }

    @Test func aTrustedJumpHostIsFollowedByTheHostsOwnHold() async throws {
        var host = Host.fixture(address: "inner.example")
        host.jumpAddress = "jump.example"
        host.jumpPort = 2222
        let keyBlob = Data("inner-host-key".utf8)
        let jumpBlob = Data("jump-host-key".utf8)
        let knownHosts = InMemoryKnownHostsStore()
        let connector = FakeTransportConnector(
            outcome: .connects(pingResult: Self.healthyPing), presentedKeyBlob: keyBlob,
            presentedJumpKeyBlob: jumpBlob)
        let store = makeTrustStore(connector: connector, knownHosts: knownHosts)
        defer { store.setHosts([]) }

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the Jump Host holds first") {
            store.hostKeyTrustHolds[host.id] == .jumpHost
        }
        await knownHosts.setFingerprint(
            HostKeyFingerprint(publicKeyBlob: jumpBlob),
            host: host.jumpAddress, port: host.jumpPort)
        var statuses: [EventsSessionStatus?] = []
        try await waitUntil("then the Host holds") {
            statuses.append(store.hostStatuses[host.id])
            return store.hostKeyTrustHolds[host.id] == .host
        }
        #expect(statuses.allSatisfy { $0 == .connecting })

        await knownHosts.setFingerprint(
            HostKeyFingerprint(publicKeyBlob: keyBlob), host: host.address, port: host.port)
        try await waitUntil("the Console should connect once both keys are trusted") {
            await connector.transports.isEmpty == false && store.hostKeyTrustHolds[host.id] == nil
        }
    }

    @Test func endingTheSessionClearsItsHold() async throws {
        let host = Host.fixture(address: "new.example")
        let connector = FakeTransportConnector(
            outcome: .connects(pingResult: Self.healthyPing), presentedKeyBlob: Data("k".utf8))
        let store = makeTrustStore(connector: connector, knownHosts: InMemoryKnownHostsStore())
        defer { store.setHosts([]) }

        store.setHosts([host])
        await store.resume()
        try await waitUntil("held") { store.hostKeyTrustHolds[host.id] == .host }
        await store.suspend()
        try await waitUntil("suspend clears the hold") { store.hostKeyTrustHolds[host.id] == nil }

        await store.resume()
        try await waitUntil("held again") { store.hostKeyTrustHolds[host.id] == .host }
        store.setHosts([])
        try await waitUntil("removing the Host clears the hold") {
            store.hostKeyTrustHolds[host.id] == nil
        }
    }

    @Test func theBackendDetectorWaitsForTrustWithoutReportingAHold() async throws {
        // Nothing cancels a detection on suspend or Reconnect, so a hold it
        // reported could outlive the session's and cover a later failure.
        // A detector reporting to its default reporter lands on `.shared`.
        let host = Host.fixture(address: "new.example")
        let keyBlob = Data("k".utf8)
        let knownHosts = PollCountingKnownHostsStore()
        let connector = FakeTransportConnector(
            outcome: .connects(pingResult: Self.healthyPing), presentedKeyBlob: keyBlob,
            detectionDials: true)
        let shared = TrustHoldHistory()
        await shared.start(.shared)
        let detect = ConsoleStore.sshBackendDetector(
            connector: connector, knownHosts: knownHosts, credentials: Self.emptyCredentials(),
            trustPollInterval: .milliseconds(10))
        let detection = Task { try await detect(host) }
        defer { detection.cancel() }

        // Read 1 is the dial's key lookup; reads 2 and 3 bracket one wait
        // turn, whose report, if any, precedes read 3.
        try await waitUntil("the detection waits for trust") { await knownHosts.reads >= 3 }
        #expect(try await shared.flushed(.shared).holds(for: host.id).isEmpty)

        await knownHosts.setFingerprint(
            HostKeyFingerprint(publicKeyBlob: keyBlob), host: host.address, port: host.port)
        #expect(try await detection.value == .herdrOnly)
        #expect(await connector.detectionCount == 2)
        #expect(try await shared.flushed(.shared).holds(for: host.id).isEmpty)
    }

    @Test func aHoldDuringReconnectingOutranksTheEarlierFailure() async throws {
        let host = Host.fixture(address: "flaky.example")
        let keyBlob = Data("flaky-host-key".utf8)
        let knownHosts = InMemoryKnownHostsStore()
        let connector = FakeTransportConnector(
            outcome: .connects(pingResult: Self.healthyPing), presentedKeyBlob: keyBlob)
        await connector.script([.unreachable(.timedOut), .connects(pingResult: Self.healthyPing)])
        let store = makeTrustStore(connector: connector, knownHosts: knownHosts)
        defer { store.setHosts([]) }

        store.setHosts([host])
        await store.resume()
        try await waitUntil("the reconnect dial holds for trust") {
            guard case .reconnecting(_, _, .timedOut) = store.hostStatuses[host.id] else { return false }
            return store.hostKeyTrustHolds[host.id] == .host
        }
        #expect(row(store, host) == holdRow(host, .host))

        await knownHosts.setFingerprint(
            HostKeyFingerprint(publicKeyBlob: keyBlob), host: host.address, port: host.port)
        try await waitUntil("the Console should connect without a Retry") {
            await connector.transports.isEmpty == false && store.hostKeyTrustHolds[host.id] == nil
        }
    }

    @Test func aChangedHostKeyStillStopsTheConsole() async throws {
        // Holding is for keys never trusted. A trusted Host presenting
        // another key is dialed and stops on the mismatch, as before.
        let host = Host.fixture(address: "known.example")
        let trusted = HostKeyFingerprint(publicKeyBlob: Data("trusted-host-key".utf8))
        let presentedBlob = Data("replaced-host-key".utf8)
        let knownHosts = InMemoryKnownHostsStore()
        await knownHosts.setFingerprint(trusted, host: host.address, port: host.port)
        let connector = FakeTransportConnector(
            outcome: .connects(pingResult: Self.healthyPing), presentedKeyBlob: presentedBlob)
        let store = makeTrustStore(connector: connector, knownHosts: knownHosts)
        defer { store.setHosts([]) }

        store.setHosts([host])
        await store.resume()

        let mismatch = TransportError.hostKeyMismatch(
            known: trusted, presented: HostKeyFingerprint(publicKeyBlob: presentedBlob))
        try await waitUntil("a changed key should stop the Console") {
            store.hostStatuses[host.id] == .failed(mismatch)
        }
        #expect(await connector.transports.isEmpty)
        #expect(store.hostKeyTrustHolds[host.id] == nil)
    }
}

/// Every trust hold a reporter delivered, in order, from `start` on.
/// Dropping it ends its stream, which unregisters it from the reporter.
private actor TrustHoldHistory {
    private var updates: [HostKeyTrustHoldReporter.Update] = []
    private var consumer: Task<Void, Never>?

    func start(_ reporter: HostKeyTrustHoldReporter) {
        let stream = reporter.updates()
        consumer = Task { [weak self] in
            for await update in stream { await self?.record(update) }
        }
    }

    private func record(_ update: HostKeyTrustHoldReporter.Update) {
        updates.append(update)
    }

    func holds(for hostID: Host.ID) -> [HostKeyTrustHold?] {
        updates.filter { $0.hostID == hostID }.map(\.hold)
    }

    /// Returns once every report whose yield happened before this call has
    /// been recorded: it reports for a sentinel Host and waits until that
    /// arrives.
    func flushed(_ reporter: HostKeyTrustHoldReporter) async throws -> TrustHoldHistory {
        let sentinel = UUID()
        reporter.report(nil, for: sentinel)
        let deadline = ContinuousClock.now + .waitCeiling
        while !updates.contains(where: { $0.hostID == sentinel }) {
            guard ContinuousClock.now < deadline else {
                Issue.record("The trust hold history never received its flush sentinel")
                return self
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        return self
    }

    deinit { consumer?.cancel() }
}

/// Counts store reads, so a test can see a trust wait poll.
private actor PollCountingKnownHostsStore: KnownHostsStore {
    private let base = InMemoryKnownHostsStore()
    private(set) var reads = 0

    func fingerprints(host: String, port: Int) async -> [HostKeyFingerprint] {
        reads += 1
        return await base.fingerprints(host: host, port: port)
    }

    func fingerprint(host: String, port: Int, algorithm: String) async -> HostKeyFingerprint? {
        await base.fingerprint(host: host, port: port, algorithm: algorithm)
    }

    func setFingerprint(_ fingerprint: HostKeyFingerprint, host: String, port: Int) async {
        await base.setFingerprint(fingerprint, host: host, port: port)
    }
}

/// Hands out scripted transports in order, one per `connect`, so tests can
/// drive SSH-level replacement deterministically.
private actor TransportQueue {
    private var remaining: [ScriptedTransport]

    init(_ transports: [ScriptedTransport]) {
        remaining = transports
    }

    func next() throws -> ScriptedTransport {
        guard !remaining.isEmpty else {
            throw TransportError.sshUnreachable(detail: "transport queue exhausted")
        }
        return remaining.removeFirst()
    }
}

/// Scripts both failed and successful connection attempts for manual retry
/// tests while recording exactly which Host was retried.
private actor ConnectionAttemptQueue {
    private var remaining: [Result<ScriptedTransport, TransportError>]
    private(set) var attemptCount = 0

    init(_ attempts: [Result<ScriptedTransport, TransportError>]) {
        remaining = attempts
    }

    func next() throws -> ScriptedTransport {
        attemptCount += 1
        guard !remaining.isEmpty else {
            throw TransportError.sshUnreachable(detail: "connection queue exhausted")
        }
        return try remaining.removeFirst().get()
    }
}

/// Captures the session a store's factory built, so overflow tests can
/// observe its drop diagnostics.
private actor SessionBox {
    private(set) var session: EventsSession?

    func set(_ session: EventsSession) {
        self.session = session
    }
}

private actor TerminalTeardownGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var enteredCount = 0

    func waitUntilOpen() async {
        enteredCount += 1
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let resuming = waiters
        waiters.removeAll()
        for waiter in resuming { waiter.resume() }
    }
}

private actor TerminalOperationResult {
    private(set) var wasSet = false

    func set() {
        wasSet = true
    }
}

/// The Hosts a store's session factory or backend detector was called for,
/// shareable with those `@Sendable` closures.
private final class HostCalls: Sendable {
    private let calls = Mutex<[Host.ID]>([])

    var ids: [Host.ID] { calls.withLock { $0 } }

    func record(_ id: Host.ID) {
        calls.withLock { $0.append(id) }
    }
}
