import Foundation
import Testing

@testable import Waycar

/// The Console keeps a Host's last-known rows through reconnects and cold
/// launches, verifies them against the next live snapshot, and treats that
/// snapshot as a silent baseline.
@MainActor
@Suite("Console last-known inventory", .timeLimit(.minutes(1)))
struct ConsoleLastKnownInventoryTests {
    private static nonisolated let fastPolicy = ReconnectPolicy(
        initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50))

    private let directory = FileManager.default.temporaryDirectory
        .appending(path: "console-inventory-\(UUID().uuidString)", directoryHint: .isDirectory)

    private func makeStore(
        transports: [Host.ID: ScriptedTransport] = [:],
        failures: [Host.ID: TransportError] = [:],
        cache: ConsoleInventoryCache? = nil,
        reconnectGrace: ConsoleStore.Countdown = .after(.seconds(10)),
        verificationTimeout: ConsoleStore.Countdown = .after(.seconds(3600)),
        tabCloseUndoWindow: ConsoleStore.Countdown = .after(.seconds(3600)),
        rowDepartureWindow: ConsoleStore.Countdown = .after(.seconds(3600))
    ) -> ConsoleStore {
        ConsoleStore(
            snapshotRetryDelay: .milliseconds(10),
            pins: PinnedAgentsStore(
                defaults: UserDefaults(suiteName: "hm-inventory-pins-\(UUID().uuidString)")
                    ?? .standard),
            inventoryCache: cache,
            reconnectGrace: reconnectGrace,
            verificationTimeout: verificationTimeout,
            tabCloseUndoWindow: tabCloseUndoWindow,
            rowDepartureWindow: rowDepartureWindow
        ) { host, _, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: {
                    if let failure = failures[host.id] { throw failure }
                    guard let transport = transports[host.id] else {
                        throw TransportError.sshUnreachable(detail: "unscripted host")
                    }
                    return transport
                },
                reconnectPolicy: Self.fastPolicy,
                keepalive: nil)
        }
    }

    private func cached(_ agents: [AgentInfo], for host: Host) -> ConsoleInventoryCache {
        let cache = ConsoleInventoryCache(directory: directory)
        cache.save(
            ConsoleInventoryCache.Entry(snapshot: .fixture(agents: agents), sidebarLayout: nil),
            for: host)
        cache.flush()
        return cache
    }

    private func agent(
        _ paneID: String, terminal: String, workspace: String = "w1",
        status: AgentStatus = .idle
    ) -> AgentInfo {
        AgentInfo(
            agentStatus: status, focused: false, paneID: paneID, revision: 1,
            tabID: "\(workspace):t1", terminalID: terminal, workspaceID: workspace,
            agent: "claude", cwd: "/work", name: nil, terminalTitleStripped: "Task")
    }

    private func workspace(_ id: String, tabCount: Int) -> WorkspaceInfo {
        WorkspaceInfo(
            activeTabID: "\(id):t1", agentStatus: .unknown, focused: false, label: id,
            number: 1, paneCount: tabCount, tabCount: tabCount, workspaceID: id, worktree: nil)
    }

    private func paneIDs(_ store: ConsoleStore) -> [String] {
        store.agents.map(\.agent.paneID).sorted()
    }

    /// herdr lists `snapshot` from now on, and says so.
    private func resync(_ transport: ScriptedTransport, to snapshot: SessionSnapshot) async {
        await transport.setSnapshot(snapshot)
        #expect(
            await transport.emit(
                HerdrEvent(
                    kind: GlobalEventKind.workspaceMetadataUpdated.kind,
                    data: .object([:]))) == true)
    }

    /// Swipes `row` closed and runs out its undo window; once its
    /// `tab.close` has gone out, herdr lists `listing` without the closed
    /// tab's panes. Returns that listing.
    @discardableResult
    private func closeTab(
        of row: ConsoleAgent, listed listing: [AgentInfo], in store: ConsoleStore,
        transport: ScriptedTransport, undo: ManualGraceClock
    ) async throws -> [AgentInfo] {
        let sent = await transport.closedTabs.count
        store.scheduleTabClose(row)
        try await waitUntil("undo window running") { await undo.waiting == 1 }
        await undo.elapse()
        try await waitUntil("tab closed") { await transport.closedTabs.count == sent + 1 }
        let remaining = listing.filter { $0.tabID != row.agent.tabID }
        await resync(transport, to: .fixture(agents: remaining))
        try await waitUntil("closed row gone") { !store.agents.contains { $0.id == row.id } }
        return remaining
    }

    // MARK: Reconnect

    @Test func rowsSurviveAReconnectAndTheLiveSnapshotDropsGonePanes() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [
                .fixture(paneID: "w1:p1", status: .idle),
                .fixture(paneID: "w1:p2", status: .working),
            ]))
        let store = makeStore(transports: [host.id: transport])
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil("the first snapshot should verify both rows") {
            paneIDs(store) == ["w1:p1", "w1:p2"] && !store.hostsAwaitingSnapshot.contains(host.id)
        }
        try await transport.waitForLiveSubscription(containing: [
            .pane(.agentStatusChanged, paneID: "w1:p1"),
            .pane(.agentStatusChanged, paneID: "w1:p2"),
        ])
        // The pane subscription's `.connected` re-snapshots on this same
        // connection, and it is announced only after the subscribe this
        // returned on. Gated, that snapshot (not the reconnect's) would be
        // the one held below, and the drop could still be on its way.
        try await waitUntil("the resubscribe's snapshot should be asked for") {
            await transport.snapshotFetchCount >= 2
        }

        let snapshotGate = ScriptedTransportCallGate()
        await transport.gateNextSnapshot(using: snapshotGate)
        await transport.setSnapshot(.fixture(agents: [.fixture(paneID: "w1:p1", status: .blocked)]))
        await transport.failEventStream(.channelFailed(detail: "Host went offline"))
        await snapshotGate.waitForEntry()

        // Reconnected, snapshot in flight: the last-known rows are all there,
        // exactly as they were, but no longer verified.
        #expect(paneIDs(store) == ["w1:p1", "w1:p2"])
        #expect(store.agents.map(\.agent.status).sorted { $0.rawValue < $1.rawValue }
            == [.idle, .working])
        #expect(store.hostsAwaitingSnapshot.contains(host.id))
        #expect(store.verifiedAgents.isEmpty)

        await snapshotGate.open()
        try await waitUntil("the live snapshot should replace the rows wholesale") {
            paneIDs(store) == ["w1:p1"] && !store.hostsAwaitingSnapshot.contains(host.id)
        }
        #expect(store.agents.first?.agent.status == .blocked)
    }

    @Test func aStaleSnapshotFromTheDroppedConnectionCannotVerifyRows() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .working)]))
        let store = makeStore(transports: [host.id: transport])
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil("the initial snapshot cycle should settle") {
            await transport.snapshotFetchCount >= 2
        }

        // The stale request captures its response on entry and holds it.
        await transport.setSnapshot(.fixture(agents: [.fixture(paneID: "w1:stale")]))
        let staleGate = ScriptedTransportCallGate()
        await transport.gateNextSnapshot(using: staleGate)
        #expect(
            await transport.emit(
                HerdrEvent(
                    kind: GlobalEventKind.workspaceMetadataUpdated.kind,
                    data: .object([:]))) == true)
        await staleGate.waitForEntry()

        await transport.setSnapshot(.fixture(agents: [.fixture(paneID: "w1:fresh")]))
        let replacementGate = ScriptedTransportCallGate()
        await transport.gateNextSnapshot(using: replacementGate)
        await transport.failEventStream(.channelFailed(detail: "Host went offline"))
        try await waitUntil("the drop should end the snapshot's authority") {
            store.hostsAwaitingSnapshot.contains(host.id)
        }

        // The replacement request starts only after the stale one returned.
        await staleGate.open()
        await replacementGate.waitForEntry()
        #expect(paneIDs(store) == ["w1:p1"])
        #expect(store.hostsAwaitingSnapshot.contains(host.id))

        await replacementGate.open()
        try await waitUntil("only the new connection's snapshot verifies") {
            paneIDs(store) == ["w1:fresh"] && !store.hostsAwaitingSnapshot.contains(host.id)
        }
    }

    // MARK: Cold launch

    @Test func coldLaunchShowsCachedRowsThenPersistsTheLiveSnapshot() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = Host.fixture()
        let cache = cached(
            [.fixture(paneID: "w1:p1", status: .working), .fixture(paneID: "w1:gone")], for: host)
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .idle)]))
        let snapshotGate = ScriptedTransportCallGate()
        await transport.gateNextSnapshot(using: snapshotGate)
        let store = makeStore(transports: [host.id: transport], cache: cache)
        defer { store.setHosts([]) }

        store.setHosts([host])
        // Before any connection work: the cached rows, unverified.
        #expect(paneIDs(store) == ["w1:gone", "w1:p1"])
        #expect(store.hostsAwaitingSnapshot.contains(host.id))

        await store.resume()
        await snapshotGate.waitForEntry()
        #expect(paneIDs(store) == ["w1:gone", "w1:p1"])

        await snapshotGate.open()
        try await waitUntil("the live snapshot should drop the gone pane") {
            paneIDs(store) == ["w1:p1"] && !store.hostsAwaitingSnapshot.contains(host.id)
        }
        cache.flush()
        let persisted = ConsoleInventoryCache(directory: directory).load(for: host)
        #expect(persisted?.snapshot.agents.map(\.paneID) == ["w1:p1"])
        #expect(persisted?.snapshot.agents.first?.agentStatus == .idle)
    }

    @Test func aRenameKeepsTheRowsWhileRemovalOrRetargetingForgetsThem() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = Host.fixture()
        let cache = cached([.fixture(paneID: "w1:p1")], for: host)
        let store = makeStore(cache: cache)
        let file = cache.fileURL(for: host.id)

        store.setHosts([host])
        #expect(paneIDs(store) == ["w1:p1"])

        var renamed = host
        renamed.name = "Renamed"
        store.setHosts([renamed])
        #expect(store.agents.map(\.hostName) == ["Renamed"])
        cache.flush()
        #expect(FileManager.default.fileExists(atPath: file.path()))

        var retargeted = renamed
        retargeted.port = 2222
        store.setHosts([retargeted])
        #expect(store.agents.isEmpty)
        cache.flush()
        #expect(!FileManager.default.fileExists(atPath: file.path()))

        let other = Host.fixture()
        cache.save(
            ConsoleInventoryCache.Entry(
                snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")]), sidebarLayout: nil),
            for: other)
        store.setHosts([retargeted, other])
        #expect(store.agents.map(\.hostID) == [other.id])
        store.setHosts([retargeted])
        cache.flush()
        #expect(!FileManager.default.fileExists(atPath: cache.fileURL(for: other.id).path()))
    }

    // MARK: Verification

    @Test func aPromptOnACachedRowWaitsForTheLiveSnapshot() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = Host.fixture()
        let cache = cached([.fixture(paneID: "w1:p1")], for: host)
        let transport = ScriptedTransport(snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")]))
        let snapshotGate = ScriptedTransportCallGate()
        await transport.gateNextSnapshot(using: snapshotGate)
        let store = makeStore(transports: [host.id: transport], cache: cache)
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        await snapshotGate.waitForEntry()
        #expect(store.hostStatuses[host.id] == .connected)

        let prompt = Task {
            try await store.promptAgent(
                AgentPromptParams(target: "w1:p1", text: "hello"), on: host.id)
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(await transport.agentPromptParams.isEmpty)

        await snapshotGate.open()
        _ = try await prompt.value
        #expect(await transport.agentPromptParams.map(\.target) == ["w1:p1"])
    }

    @Test func aStoppedHostFailsAWaitingRPCInsteadOfHoldingIt() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = Host.fixture()
        let cache = cached([.fixture(paneID: "w1:p1")], for: host)
        let store = makeStore(failures: [host.id: .authenticationFailed], cache: cache)
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        await #expect(throws: TransportError.authenticationFailed) {
            try await store.renameAgent("w1:p1", name: "x", on: host.id)
        }
        #expect(paneIDs(store) == ["w1:p1"])
    }

    @Test func actionsOnCachedRowsUseTheVerifiedRowOrSendNothing() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = Host.fixture()
        let cache = cached(
            [agent("w1:p1", terminal: "term_old"), agent("w1:p2", terminal: "term_p2")],
            for: host)
        // herdr reused w1:p1 for another terminal; w1:p2 kept its terminal
        // but now lives in another Workspace's tab.
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [
                agent("w1:p1", terminal: "term_new"),
                agent("w1:p2", terminal: "term_p2", workspace: "w2"),
            ]))
        let snapshotGate = ScriptedTransportCallGate()
        await transport.gateNextSnapshot(using: snapshotGate)
        let store = makeStore(transports: [host.id: transport], cache: cache)
        defer { store.setHosts([]) }
        store.setHosts([host])
        let reused = try #require(store.agents.first { $0.agent.paneID == "w1:p1" })
        let moved = try #require(store.agents.first { $0.agent.paneID == "w1:p2" })
        await store.resume()
        await snapshotGate.waitForEntry()

        let prompt = Task {
            try await store.promptAgent(
                AgentPromptParams(target: "w1:p1", text: "hello"), on: host.id)
        }
        let close = Task { try await store.closePane("w1:p1", on: host.id) }
        let rename = Task { try await store.renameAgent("w1:p1", name: "x", on: host.id) }
        let closeTab = Task { try await store.closeAgentTab(moved) }
        await snapshotGate.open()

        let gone = TransportError.apiRejected(
            code: "agent_not_found", message: "The Agent is no longer listed.")
        await #expect(throws: gone) { try await prompt.value }
        await #expect(throws: gone) { try await close.value }
        await #expect(throws: gone) { try await rename.value }
        try await closeTab.value
        #expect(await transport.agentPromptParams.isEmpty)
        #expect(await transport.closedPanes.isEmpty)
        #expect(await transport.agentRenames.isEmpty)
        #expect(await transport.closedTabs == [TabTarget(tabID: "w2:t1")])
        await #expect(throws: gone) { try await store.closeAgentTab(reused) }
    }

    @Test func aSwipedCloseOfTheWorkspacesLastTabClosesWhenTheUndoWindowRunsOut() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = Host.fixture()
        let clock = ManualGraceClock()
        // Last known, the Workspace had a second tab; live, this is its last.
        let cache = ConsoleInventoryCache(directory: directory)
        cache.save(
            ConsoleInventoryCache.Entry(
                snapshot: .fixture(
                    agents: [.fixture(paneID: "w1:p1")],
                    workspaces: [workspace("w1", tabCount: 2)]),
                sidebarLayout: nil),
            for: host)
        cache.flush()
        let transport = ScriptedTransport(
            snapshot: .fixture(
                agents: [.fixture(paneID: "w1:p1")],
                workspaces: [workspace("w1", tabCount: 1)]))
        let store = makeStore(
            transports: [host.id: transport],
            cache: cache,
            tabCloseUndoWindow: ConsoleStore.Countdown { try await clock.sleep() })
        defer { store.setHosts([]) }
        store.setHosts([host])
        let cachedRow = try #require(store.agents.first)
        #expect(!store.closesWorkspaceWithTab(of: cachedRow))
        await store.resume()

        store.scheduleTabClose(cachedRow)
        #expect(store.pendingTabCloses[cachedRow.id]?.phase == .counting)
        try await Task.sleep(for: .milliseconds(20))
        #expect(await transport.closedTabs.isEmpty)

        await clock.elapse()
        try await waitUntil("tab closed") { await !transport.closedTabs.isEmpty }
        #expect(await transport.closedTabs == [TabTarget(tabID: "w1:t1")])
        // Still listed until the resync drops it, the row stays `.closing`.
        try await Task.sleep(for: .milliseconds(20))
        #expect(store.pendingTabCloses[cachedRow.id]?.phase == .closing)

        await transport.setSnapshot(.fixture())
        #expect(
            await transport.emit(
                HerdrEvent(
                    kind: GlobalEventKind.workspaceMetadataUpdated.kind,
                    data: .object([:]))) == true)
        try await waitUntil("pending cleared with the row") { store.pendingTabCloses.isEmpty }
        #expect(store.agents.isEmpty)
        #expect(store.tabCloseFailure == nil)
    }

    @Test func aSwipedCloseWhoseRowVanishesMidCountdownIsDropped() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = Host.fixture()
        let clock = ManualGraceClock()
        let transport = ScriptedTransport(
            snapshot: .fixture(
                agents: [.fixture(paneID: "w1:p1")],
                workspaces: [workspace("w1", tabCount: 2)]))
        let store = makeStore(
            transports: [host.id: transport],
            tabCloseUndoWindow: ConsoleStore.Countdown { try await clock.sleep() })
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil("row verified") { !store.verifiedAgents.isEmpty }
        let row = try #require(store.agents.first)

        store.scheduleTabClose(row)
        try await Task.sleep(for: .milliseconds(20))
        // Closed elsewhere while the undo countdown runs.
        await transport.setSnapshot(.fixture())
        #expect(
            await transport.emit(
                HerdrEvent(
                    kind: GlobalEventKind.workspaceMetadataUpdated.kind,
                    data: .object([:]))) == true)
        try await waitUntil("pending dropped with the row") { store.pendingTabCloses.isEmpty }
        // Nothing was sent, so nothing lifts away: the row is not held.
        #expect(store.indexAgents(holding: nil).isEmpty)
        // The same row coming back must not revive the dropped countdown.
        await transport.setSnapshot(
            .fixture(
                agents: [.fixture(paneID: "w1:p1")],
                workspaces: [workspace("w1", tabCount: 2)]))
        #expect(
            await transport.emit(
                HerdrEvent(
                    kind: GlobalEventKind.workspaceMetadataUpdated.kind,
                    data: .object([:]))) == true)
        try await waitUntil("row back") { store.agents.contains { $0.id == row.id } }
        await clock.elapse()
        try await Task.sleep(for: .milliseconds(50))

        #expect(await transport.closedTabs.isEmpty)
        #expect(store.pendingTabCloses.isEmpty)
        #expect(store.tabCloseFailure == nil)
    }

    @Test func twoSwipedClosesOnOneTabSendOneTabClose() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = Host.fixture()
        let clock = ManualGraceClock()
        let transport = ScriptedTransport(
            snapshot: .fixture(
                agents: [.fixture(paneID: "w1:p1"), .fixture(paneID: "w1:p2")],
                workspaces: [workspace("w1", tabCount: 2)]))
        let store = makeStore(
            transports: [host.id: transport],
            tabCloseUndoWindow: ConsoleStore.Countdown { try await clock.sleep() })
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil("rows verified") { store.verifiedAgents.count == 2 }
        let rows = store.agents
        #expect(Set(rows.map(\.agent.tabID)) == ["w1:t1"])

        for row in rows { store.scheduleTabClose(row) }
        try await Task.sleep(for: .milliseconds(20))
        // Both countdowns run out together; one `tab.close` covers the tab.
        await clock.elapse()
        try await waitUntil("tab closed") { await !transport.closedTabs.isEmpty }
        try await Task.sleep(for: .milliseconds(50))

        #expect(await transport.closedTabs == [TabTarget(tabID: "w1:t1")])
        #expect(store.tabCloseFailure == nil)
        #expect(rows.allSatisfy { store.pendingTabCloses[$0.id]?.phase == .closing })
    }

    @Test func aSwipedCloseThatFailsShowsTheErrorAndClearsThePendingClose() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = Host.fixture()
        let clock = ManualGraceClock()
        let transport = ScriptedTransport(
            snapshot: .fixture(
                agents: [.fixture(paneID: "w1:p1")],
                workspaces: [workspace("w1", tabCount: 1)]))
        await transport.setCloseFailure(.channelFailed(detail: "x"))
        let store = makeStore(
            transports: [host.id: transport],
            tabCloseUndoWindow: ConsoleStore.Countdown { try await clock.sleep() })
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil("row verified") { !store.verifiedAgents.isEmpty }
        let row = try #require(store.agents.first)

        store.scheduleTabClose(row)
        try await Task.sleep(for: .milliseconds(20))
        await clock.elapse()
        try await waitUntil("failure shown") { store.tabCloseFailure != nil }

        #expect(store.pendingTabCloses.isEmpty)
        #expect(store.agents.contains { $0.id == row.id })
        // The Transport Error Presentation, not Foundation's
        // "The operation couldn't be completed. (… error 12.)".
        #expect(store.tabCloseFailure == "Connection dropped: x.")
    }

    /// A bulk Close ends every countdown at the same instant. A Host that is
    /// reconnecting then (its rows unverified, quietly inside the reconnect
    /// grace) must hold the due Closes until it is back, not fail each one
    /// with the failure that started the reconnect: that dropped every
    /// Close with "error 22" and left every tab open.
    @Test func bulkClosesDueWhileTheirHostReconnectsAllCloseOnceItIsBack() async throws {
        let host = Host.fixture()
        let undo = ManualGraceClock()
        let listing: [AgentInfo] = ["w1", "w2", "w3"].map {
            .fixture(paneID: "\($0):p1", workspaceID: $0)
        }
        let transport = ScriptedTransport(snapshot: .fixture(agents: listing))
        let store = makeStore(
            transports: [host.id: transport],
            tabCloseUndoWindow: ConsoleStore.Countdown { try await undo.sleep() })
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil("rows verified") { store.verifiedAgents.count == 3 }
        let rows = store.agents

        for row in rows { store.scheduleTabClose(row) }
        try await waitUntil("three undo windows running") { await undo.waiting == 3 }
        // The link times out mid-countdown; the redial's subscribe is held.
        let resubscribe = ScriptedTransportCallGate()
        await transport.gateNextSubscription(using: resubscribe)
        await transport.failEventStream(.timedOut)
        await resubscribe.waitForEntry()
        try await waitUntil("rows unverified") { store.hostsAwaitingSnapshot.contains(host.id) }

        await undo.elapse()
        try await waitUntil("all closing") {
            rows.allSatisfy { store.pendingTabCloses[$0.id]?.phase == .closing }
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.tabCloseFailure == nil)
        #expect(await transport.closedTabs.isEmpty)

        await resubscribe.open()
        try await waitUntil("every tab closed") { await transport.closedTabs.count == 3 }
        #expect(
            Set(await transport.closedTabs.map(\.tabID)) == ["w1:t1", "w2:t1", "w3:t1"])
        await resync(transport, to: .fixture())
        try await waitUntil("rows gone") { store.agents.isEmpty && store.pendingTabCloses.isEmpty }
        #expect(store.tabCloseFailure == nil)
    }

    /// A Close that rides out a reconnect which never finishes fails, after
    /// the verification timeout, with the failure the Host is recovering
    /// from — what the user can act on — not a bare "Connection timed out."
    @Test func aCloseDueWhileItsHostNeverRecoversReportsTheReconnectFailure() async throws {
        let host = Host.fixture()
        let undo = ManualGraceClock()
        let verification = ManualGraceClock()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")]))
        let store = makeStore(
            transports: [host.id: transport],
            verificationTimeout: ConsoleStore.Countdown { try await verification.sleep() },
            tabCloseUndoWindow: ConsoleStore.Countdown { try await undo.sleep() })
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil("row verified") { store.verifiedAgents.count == 1 }
        let row = try #require(store.agents.first)

        store.scheduleTabClose(row)
        try await waitUntil("undo window running") { await undo.waiting == 1 }
        // The link drops mid-countdown; the redial's subscribe never opens.
        let failure = TransportError.sshUnreachable(detail: "link lost")
        let resubscribe = ScriptedTransportCallGate()
        await transport.gateNextSubscription(using: resubscribe)
        await transport.failEventStream(failure)
        await resubscribe.waitForEntry()
        try await waitUntil("rows unverified") { store.hostsAwaitingSnapshot.contains(host.id) }

        await undo.elapse()
        try await waitUntil("verification waiting") { await verification.waiting == 1 }
        #expect(store.tabCloseFailure == nil)

        await verification.elapse()
        try await waitUntil("failure shown") { store.tabCloseFailure != nil }
        #expect(store.tabCloseFailure == failure.presentation.message)
        #expect(store.tabCloseFailure != TransportError.timedOut.presentation.message)
        #expect(store.pendingTabCloses.isEmpty)
        #expect(await transport.closedTabs.isEmpty)
        await resubscribe.open()
    }

    /// `tab.close` ran, but the connection died before its answer: the
    /// session redials and asks again, and herdr answers `tab_not_found`.
    /// The tab the user closed is gone, so the Close succeeded.
    @Test func aSwipedCloseWhoseAnswerWasLostWithItsConnectionStillCloses() async throws {
        let host = Host.fixture()
        let undo = ManualGraceClock()
        let listing: [AgentInfo] = [.fixture(paneID: "w1:p1"), .fixture(paneID: "w2:p1", workspaceID: "w2")]
        let transport = ScriptedTransport(snapshot: .fixture(agents: listing))
        await transport.loseNextTabCloseAnswer(with: .sshUnreachable(detail: "link lost"))
        let store = makeStore(
            transports: [host.id: transport],
            tabCloseUndoWindow: ConsoleStore.Countdown { try await undo.sleep() })
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil("rows verified") { store.verifiedAgents.count == 2 }
        let row = try #require(store.agents.first { $0.agent.paneID == "w1:p1" })
        store.pins.addPin(hostID: host.id, paneID: row.agent.paneID)

        store.scheduleTabClose(row)
        try await waitUntil("undo window running") { await undo.waiting == 1 }
        await undo.elapse()
        try await waitUntil("tab closed") { await transport.closedTabs.count == 1 }
        try await waitUntil("pin dropped with the closed tab") {
            !store.pins.isPinned(hostID: host.id, paneID: row.agent.paneID)
        }
        // Still listed until the resync drops it, the row stays `.closing`.
        #expect(store.pendingTabCloses[row.id]?.phase == .closing)
        #expect(store.tabCloseFailure == nil)

        await resync(transport, to: .fixture(agents: [listing[1]]))
        try await waitUntil("closed row gone") { !store.agents.contains { $0.id == row.id } }
        #expect(store.pendingTabCloses.isEmpty)
        #expect(store.tabCloseFailure == nil)
    }

    @Test func aSwipedCloseOfAnAlreadyGoneAgentEndsQuietly() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = Host.fixture()
        let clock = ManualGraceClock()
        let transport = ScriptedTransport(
            snapshot: .fixture(
                agents: [.fixture(paneID: "w1:p1")],
                workspaces: [workspace("w1", tabCount: 1)]))
        await transport.setCloseFailure(.apiRejected(code: "agent_not_found", message: ""))
        let store = makeStore(
            transports: [host.id: transport],
            tabCloseUndoWindow: ConsoleStore.Countdown { try await clock.sleep() })
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil("row verified") { !store.verifiedAgents.isEmpty }
        let row = try #require(store.agents.first)

        store.scheduleTabClose(row)
        try await Task.sleep(for: .milliseconds(20))
        await clock.elapse()
        try await waitUntil("pending cleared") { store.pendingTabCloses.isEmpty }

        #expect(store.tabCloseFailure == nil)
    }

    @Test func aRiderIsReleasedWhenTheCloseItRodeOnFindsTheAgentGone() async throws {
        let host = Host.fixture()
        let clock = ManualGraceClock()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1"), .fixture(paneID: "w1:p2")]))
        await transport.setCloseFailure(.apiRejected(code: "agent_not_found", message: ""))
        let tabClose = ScriptedTransportCallGate()
        await transport.gateNextTabClose(using: tabClose)
        let store = makeStore(
            transports: [host.id: transport],
            tabCloseUndoWindow: ConsoleStore.Countdown { try await clock.sleep() })
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil("rows verified") { store.verifiedAgents.count == 2 }
        let rows = store.agents

        for row in rows { store.scheduleTabClose(row) }
        try await waitUntil("both undo windows running") { await clock.waiting == 2 }
        await clock.elapse()
        // One `tab.close` is in flight; the other countdown rides along on it.
        await tabClose.waitForEntry()
        try await waitUntil("both closing") {
            rows.allSatisfy { store.pendingTabCloses[$0.id]?.phase == .closing }
        }

        await tabClose.open()
        try await waitUntil("the rider goes back to a plain row with the close it rode on") {
            store.pendingTabCloses.isEmpty
        }
        #expect(store.tabCloseFailure == nil)
    }

    /// A pane closed on a tab whose swiped Close is in flight leaves with
    /// that Close (#105): the confirmed `pane.close` must not take the row
    /// off the list first, which would end the swiped row's `.closing`
    /// while its `tab.close` is still out.
    @Test func aPaneClosedUnderAnInFlightSwipedCloseLeavesWithThatClose() async throws {
        let host = Host.fixture()
        let clock = ManualGraceClock()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1"), .fixture(paneID: "w1:p2")]))
        let tabClose = ScriptedTransportCallGate()
        await transport.gateNextTabClose(using: tabClose)
        let store = makeStore(
            transports: [host.id: transport],
            tabCloseUndoWindow: ConsoleStore.Countdown { try await clock.sleep() })
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil("rows verified") { store.verifiedAgents.count == 2 }
        let swiped = try #require(store.agents.first { $0.agent.paneID == "w1:p1" })

        store.scheduleTabClose(swiped)
        try await waitUntil("undo window running") { await clock.waiting == 1 }
        await clock.elapse()
        await tabClose.waitForEntry()

        try await store.closePane("w1:p1", on: host.id)
        #expect(await transport.closedPanes.map(\.paneID) == ["w1:p1"])
        #expect(store.agents.contains { $0.id == swiped.id })
        #expect(store.pendingTabCloses[swiped.id]?.phase == .closing)
        await tabClose.open()
    }

    /// CONSOLE-16: a Close that succeeds stops a sibling still counting down
    /// on its tab. The sibling rides along, closing, with nothing left to
    /// undo, and its countdown sends nothing. A swiped Close asks for its
    /// tab's close, not a pane's (`tab.close` may still close a Workspace's
    /// worktree group; this does not test that).
    @Test func aSucceedingCloseStopsASiblingStillCountingOnItsTab() async throws {
        let host = Host.fixture()
        let clock = ManualGraceClock()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1"), .fixture(paneID: "w1:p2")]))
        let tabClose = ScriptedTransportCallGate()
        await transport.gateNextTabClose(using: tabClose)
        let store = makeStore(
            transports: [host.id: transport],
            tabCloseUndoWindow: ConsoleStore.Countdown { try await clock.sleep() })
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil("rows verified") { store.verifiedAgents.count == 2 }
        let first = try #require(store.agents.first { $0.agent.paneID == "w1:p1" })
        let second = try #require(store.agents.first { $0.agent.paneID == "w1:p2" })

        store.scheduleTabClose(first)
        try await waitUntil("undo window running") { await clock.waiting == 1 }
        await clock.elapse()
        await tabClose.waitForEntry()
        store.scheduleTabClose(second)
        try await waitUntil("the sibling counting down") { await clock.waiting == 1 }
        #expect(store.pendingTabCloses[second.id]?.phase == .counting)

        await tabClose.open()
        try await waitUntil("the sibling rides along") {
            store.pendingTabCloses[second.id]?.phase == .closing
        }
        store.undoTabClose(second.id)
        #expect(store.pendingTabCloses[second.id]?.phase == .closing)
        await clock.elapse()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await transport.closedTabs == [TabTarget(tabID: "w1:t1")])
        #expect(await transport.closedPanes.isEmpty)
        #expect(store.tabCloseFailure == nil)
        #expect(store.pendingTabCloses[first.id]?.phase == .closing)
    }

    /// CONSOLE-16: a failed Close releases by row. Two Closes in flight on
    /// different tabs, the second's row moved onto the first's tab: the
    /// first failing releases the second's row, which the user swipes again;
    /// the second failing then clears that new Close too, by row, but the
    /// new countdown still runs out and closes the tab its row is on now.
    @Test func aReswipedCloseThatOutlivesAnOlderFailureStillCloses() async throws {
        let host = Host.fixture()
        let clock = ManualGraceClock()
        let onSecondTab = AgentInfo(
            agentStatus: .idle, focused: false, paneID: "w1:p2", revision: 1,
            tabID: "w1:t2", terminalID: "term_w1:p2", workspaceID: "w1",
            agent: "claude", cwd: "/work/w1", name: nil, terminalTitleStripped: "Task")
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1"), onSecondTab]))
        let refused = TransportError.apiRejected(code: "tab_busy", message: "refused")
        await transport.setCloseFailure(refused)
        let firstClose = ScriptedTransportCallGate()
        await transport.gateNextTabClose(using: firstClose)
        let store = makeStore(
            transports: [host.id: transport],
            tabCloseUndoWindow: ConsoleStore.Countdown { try await clock.sleep() })
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil("rows verified") { store.verifiedAgents.count == 2 }
        let first = try #require(store.agents.first { $0.agent.paneID == "w1:p1" })
        let second = try #require(store.agents.first { $0.agent.paneID == "w1:p2" })

        // Each Close runs out on its own tab and sends its own `tab.close`.
        store.scheduleTabClose(first)
        try await waitUntil("the first undo window running") { await clock.waiting == 1 }
        await clock.elapse()
        await firstClose.waitForEntry()
        let secondClose = ScriptedTransportCallGate()
        await transport.gateNextTabClose(using: secondClose)
        store.scheduleTabClose(second)
        try await waitUntil("the second undo window running") { await clock.waiting == 1 }
        await clock.elapse()
        await secondClose.waitForEntry()
        #expect(store.pendingTabCloses.values.allSatisfy { $0.phase == .closing })

        // herdr moves the second row onto the first's tab; the first fails.
        await resync(
            transport, to: .fixture(agents: [.fixture(paneID: "w1:p1"), .fixture(paneID: "w1:p2")]))
        try await waitUntil("the second row on the first's tab") {
            store.agents.first { $0.id == second.id }?.agent.tabID == "w1:t1"
        }
        await firstClose.open()
        try await waitUntil("the first failure releases both rows") {
            store.pendingTabCloses.isEmpty && store.tabCloseFailure != nil
        }

        // Swiped again, then the second's own failure clears it by row.
        let reswiped = try #require(store.agents.first { $0.id == second.id })
        store.scheduleTabClose(reswiped)
        try await waitUntil("the new undo window running") { await clock.waiting == 1 }
        #expect(store.pendingTabCloses[second.id]?.phase == .counting)
        await secondClose.open()
        try await waitUntil("the older failure clears the new Close") {
            store.pendingTabCloses[second.id] == nil
        }

        // The new countdown still runs out and closes the row's tab.
        await transport.setCloseFailure(nil)
        await clock.elapse()
        try await waitUntil("the new countdown closes the tab") {
            await transport.closedTabs == [TabTarget(tabID: "w1:t1")]
        }
        #expect(store.pendingTabCloses[second.id] == nil)
    }

    /// CONSOLE-16: Closes ride along by the tab a row is on now. A sibling
    /// herdr moved to another tab mid-countdown closes that tab itself.
    @Test func aSiblingMovedToAnotherTabMidCountdownClosesItsNewTab() async throws {
        let host = Host.fixture()
        let clock = ManualGraceClock()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1"), .fixture(paneID: "w1:p2")]))
        let store = makeStore(
            transports: [host.id: transport],
            tabCloseUndoWindow: ConsoleStore.Countdown { try await clock.sleep() })
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil("rows verified") { store.verifiedAgents.count == 2 }
        for row in store.agents { store.scheduleTabClose(row) }
        try await waitUntil("both undo windows running") { await clock.waiting == 2 }

        let moved = AgentInfo(
            agentStatus: .idle, focused: false, paneID: "w1:p2", revision: 1,
            tabID: "w1:t2", terminalID: "term_w1:p2", workspaceID: "w1",
            agent: "claude", cwd: "/work/w1", name: nil, terminalTitleStripped: "Task")
        await resync(transport, to: .fixture(agents: [.fixture(paneID: "w1:p1"), moved]))
        try await waitUntil("the sibling's row on its new tab") {
            store.agents.first { $0.agent.paneID == "w1:p2" }?.agent.tabID == "w1:t2"
        }
        await clock.elapse()
        try await waitUntil("both tabs closed") { await transport.closedTabs.count == 2 }
        #expect(Set(await transport.closedTabs.map(\.tabID)) == ["w1:t1", "w1:t2"])
        #expect(store.tabCloseFailure == nil)
    }

    @Test func undoingASwipedCloseSendsNothing() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = Host.fixture()
        let clock = ManualGraceClock()
        let transport = ScriptedTransport(
            snapshot: .fixture(
                agents: [.fixture(paneID: "w1:p1")],
                workspaces: [workspace("w1", tabCount: 1)]))
        let store = makeStore(
            transports: [host.id: transport],
            tabCloseUndoWindow: ConsoleStore.Countdown { try await clock.sleep() })
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil("row verified") { !store.verifiedAgents.isEmpty }
        let row = try #require(store.agents.first)

        store.scheduleTabClose(row)
        try await Task.sleep(for: .milliseconds(20))
        store.undoTabClose(row.id)
        #expect(store.pendingTabCloses.isEmpty)
        await clock.elapse()
        try await Task.sleep(for: .milliseconds(50))

        #expect(await transport.closedTabs.isEmpty)
        #expect(store.pendingTabCloses.isEmpty)
    }

    @Test func aWaitingRPCFailsWhenItsHostCannotVerify() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = Host.fixture()

        // Connected, but every snapshot fails: the RPC gets that failure.
        let unsnapshottable = ScriptedTransport(snapshot: .fixture())
        await unsnapshottable.setSnapshotFailure(.channelFailed(detail: "snapshot refused"))
        let failing = makeStore(
            transports: [host.id: unsnapshottable],
            cache: cached([.fixture(paneID: "w1:p1")], for: host))
        failing.setHosts([host])
        await failing.resume()
        await #expect(throws: TransportError.channelFailed(detail: "snapshot refused")) {
            try await failing.renameAgent("w1:p1", name: "x", on: host.id)
        }
        failing.setHosts([])

        // Paused: nothing will verify it until the app is active again.
        let transport = ScriptedTransport(snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")]))
        let paused = makeStore(transports: [host.id: transport])
        paused.setHosts([host])
        await paused.resume()
        try await waitUntil("the Host should verify") {
            !paused.hostsAwaitingSnapshot.contains(host.id)
        }
        await paused.suspend()
        await #expect(throws: TransportError.self) {
            try await paused.renameAgent("w1:p1", name: "x", on: host.id)
        }
        paused.setHosts([])
        #expect(await transport.agentRenames.isEmpty)
    }

    @Test func aWaitingRPCTimesOut() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = Host.fixture()
        let clock = ManualGraceClock()
        let store = makeStore(
            cache: cached([.fixture(paneID: "w1:p1")], for: host),
            verificationTimeout: ConsoleStore.Countdown { try await clock.sleep() })
        defer { store.setHosts([]) }
        // Never activated: the Host makes no progress toward verification.
        store.setHosts([host])
        let rename = Task { try await store.renameAgent("w1:p1", name: "x", on: host.id) }
        try await Task.sleep(for: .milliseconds(20))
        await clock.elapse()
        await #expect(throws: TransportError.timedOut) { try await rename.value }
    }

    @Test func aDetailRebuildsWhenItsRowsTerminalChanges() {
        let host = Host.fixture()
        func row(_ terminal: String, status: AgentStatus = .idle) -> ConsoleAgent {
            ConsoleAgent(
                hostID: host.id, hostName: host.displayName,
                agent: Agent(agent("w1:p1", terminal: terminal, status: status)),
                workspaceLabel: nil, repositoryCheckout: nil)
        }
        #expect(AgentDetailIdentity(row("term_a")) != AgentDetailIdentity(row("term_b")))
        #expect(
            AgentDetailIdentity(row("term_a"))
                == AgentDetailIdentity(row("term_a", status: .working)))
    }

    // MARK: Departing rows

    @Test func aClosedTabsRowsStayListedInPlaceUntilTheirDepartureWindowEnds() async throws {
        let host = Host.fixture()
        let undo = ManualGraceClock()
        let departure = ManualGraceClock()
        let listing: [AgentInfo] = [
            .fixture(paneID: "w1:p1"), .fixture(paneID: "w1:p2"),
            .fixture(paneID: "w2:p3", workspaceID: "w2"),
        ]
        let transport = ScriptedTransport(snapshot: .fixture(agents: listing))
        let store = makeStore(
            transports: [host.id: transport],
            tabCloseUndoWindow: ConsoleStore.Countdown { try await undo.sleep() },
            rowDepartureWindow: ConsoleStore.Countdown { try await departure.sleep() })
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil("rows verified") { store.verifiedAgents.count == 3 }
        let before = store.indexAgents(holding: nil).map(\.id)
        let swiped = try #require(store.agents.first { $0.agent.paneID == "w1:p1" })
        let sibling = try #require(store.agents.first { $0.agent.paneID == "w1:p2" })

        try await closeTab(
            of: swiped, listed: listing, in: store, transport: transport, undo: undo)

        // The resync took both of the tab's rows; the index keeps them where
        // they were, the swiped one still drawn as closing.
        #expect(store.agents.map(\.agent.paneID) == ["w2:p3"])
        #expect(store.pendingTabCloses.isEmpty)
        #expect(store.indexAgents(holding: nil).map(\.id) == before)
        #expect(store.departingRow(swiped.id)?.pendingClose?.phase == .closing)
        let departingSibling = try #require(store.departingRow(sibling.id))
        #expect(departingSibling.pendingClose == nil)

        try await waitUntil("departure window running") { await departure.waiting == 1 }
        await departure.elapse()
        try await waitUntil("departed") { store.departingRows.isEmpty }
        #expect(store.indexAgents(holding: nil).map(\.agent.paneID) == ["w2:p3"])
    }

    @Test func aDepartingPaneIDListedAgainIsListedOnceAsANewRow() async throws {
        let host = Host.fixture()
        let undo = ManualGraceClock()
        let listing: [AgentInfo] = [
            .fixture(paneID: "w1:p1"), .fixture(paneID: "w2:p2", workspaceID: "w2"),
        ]
        let transport = ScriptedTransport(snapshot: .fixture(agents: listing))
        let store = makeStore(
            transports: [host.id: transport],
            tabCloseUndoWindow: ConsoleStore.Countdown { try await undo.sleep() })
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil("rows verified") { store.verifiedAgents.count == 2 }
        let swiped = try #require(store.agents.first { $0.agent.paneID == "w1:p1" })
        let remaining = try await closeTab(
            of: swiped, listed: listing, in: store, transport: transport, undo: undo)
        #expect(store.departingRow(swiped.id) != nil)

        // herdr reuses the closed pane's id while its row is still departing.
        await resync(
            transport, to: .fixture(agents: remaining + [agent("w1:p1", terminal: "term_new")]))
        try await waitUntil("pane id listed again") {
            store.agents.contains { $0.id == swiped.id }
        }
        #expect(store.indexAgents(holding: nil).filter { $0.id == swiped.id }.count == 1)
        #expect(store.departingRow(swiped.id) == nil)
    }

    @Test func tabsClosedOneAfterAnotherKeepTheirPlacesWhileDeparting() async throws {
        let host = Host.fixture()
        let undo = ManualGraceClock()
        let listing: [AgentInfo] = [
            .fixture(paneID: "w1:p1"),
            .fixture(paneID: "w2:p2", workspaceID: "w2"),
            .fixture(paneID: "w3:p3", workspaceID: "w3"),
        ]
        let transport = ScriptedTransport(snapshot: .fixture(agents: listing))
        let store = makeStore(
            transports: [host.id: transport],
            tabCloseUndoWindow: ConsoleStore.Countdown { try await undo.sleep() })
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil("rows verified") { store.verifiedAgents.count == 3 }
        let before = store.indexAgents(holding: nil)
        #expect(Set(before.map(\.agent.tabID)).count == 3)

        // The bottom row's tab closes first, anchoring its departing row on
        // the row above it, whose own tab closes next.
        let remaining = try await closeTab(
            of: before[2], listed: listing, in: store, transport: transport, undo: undo)
        try await closeTab(
            of: before[1], listed: remaining, in: store, transport: transport, undo: undo)

        #expect(store.agents.map(\.id) == [before[0].id])
        #expect(store.indexAgents(holding: nil).map(\.id) == before.map(\.id))
    }

    // MARK: Side effects

    @Test func theFirstLiveSnapshotAfterTheCacheIsASilentBannerBaseline() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = Host.fixture()
        let cache = cached([.fixture(paneID: "w1:p1", status: .working)], for: host)
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .blocked)]))
        let store = makeStore(transports: [host.id: transport], cache: cache)
        defer { store.setHosts([]) }
        let banners = AgentNotificationBannerStore(
            holdDuration: .zero, dismissDelay: .seconds(60),
            presentedAgent: { nil }, triggers: { _ in NotificationTriggerPreferences() },
            playSound: {}, carVoice: { CarVoiceActivity.State() })

        store.setHosts([host])
        banners.agentsDidChange(store.verifiedAgents.excludingShells)
        await store.resume()
        try await waitUntil("the live snapshot should verify the Blocked row") {
            store.verifiedAgents.first?.agent.status == .blocked
        }
        banners.agentsDidChange(store.verifiedAgents.excludingShells)
        try await Task.sleep(for: .milliseconds(30))
        #expect(banners.banner == nil)

        // A live transition after the baseline still announces.
        try await transport.waitForLiveSubscription(containing: [
            .pane(.agentStatusChanged, paneID: "w1:p1")
        ])
        await transport.setSnapshot(.fixture(agents: [.fixture(paneID: "w1:p1", status: .done)]))
        #expect(await transport.emit(.agentStatusChanged(paneID: "w1:p1", status: .done)) == true)
        try await waitUntil("the live Done should reach the verified rows") {
            store.verifiedAgents.first?.agent.status == .done
        }
        banners.agentsDidChange(store.verifiedAgents.excludingShells)
        try await waitUntil("a live transition should banner") { banners.banner != nil }
    }

    // MARK: Reconnect grace

    @Test func graceQuietsAHostWithRowsUntilItElapsesAndRestartsOnActivation() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let withRows = Host.fixture()
        let withoutRows = Host.fixture()
        let cache = cached([.fixture(paneID: "w1:p1")], for: withRows)
        let clock = ManualGraceClock()
        let store = makeStore(
            cache: cache, reconnectGrace: ConsoleStore.Countdown { try await clock.sleep() })
        defer { store.setHosts([]) }

        store.setHosts([withRows, withoutRows])
        await store.resume()
        #expect(store.hostsWithinReconnectGrace == [withRows.id])

        await clock.elapse()
        try await waitUntil("the elapsed grace should surface the Host's condition") {
            store.hostsWithinReconnectGrace.isEmpty
        }

        await store.suspend()
        await store.resume()
        #expect(store.hostsWithinReconnectGrace == [withRows.id])
    }

    @Test func graceSuppressesOnlyConditionsThatResolveThemselves() {
        let host = Host.fixture()
        let failure = TransportError.authenticationFailed
        let quiet: [(EventsSessionStatus, Bool)] = [
            (.connecting, false),
            (.reconnecting(attempt: 1, delay: .seconds(1), failure: .timedOut), false),
            (.connected, true),
            (.suspended, false),
        ]
        for (status, awaiting) in quiet {
            #expect(
                ConsoleHostStatusPresentation(
                    host: host, status: status, isAwaitingSnapshot: awaiting,
                    isWithinReconnectGrace: true, syncError: nil) == nil)
            #expect(
                ConsoleHostStatusPresentation(
                    host: host, status: status, isAwaitingSnapshot: awaiting,
                    isWithinReconnectGrace: false, syncError: nil) != nil)
        }
        #expect(
            ConsoleHostStatusPresentation(
                host: host, status: .failed(failure), isWithinReconnectGrace: true,
                syncError: nil) != nil)
        #expect(
            ConsoleHostStatusPresentation(
                host: host, status: .connecting, standingFailure: failure,
                isWithinReconnectGrace: true, syncError: nil) != nil)
    }

    @Test func anOpenDetailSaysWhatItsHostIsDoingOnlyPastGraceOrOnFailure() {
        let host = Host.fixture()
        let agentID = ConsoleAgent.ID(hostID: host.id, paneID: "w1:p1")
        func condition(
            _ status: EventsSessionStatus, awaiting: Bool = true, withinGrace: Bool
        ) -> MissingAgentPresentation.Cause? {
            MissingAgentPresentation.attachHostCondition(
                agentID: agentID, hostStatuses: [host.id: status], hosts: [host],
                hostsAwaitingSnapshot: awaiting ? [host.id] : [],
                hostStandingFailures: [:],
                hostsWithinReconnectGrace: withinGrace ? [host.id] : [])?.cause
        }
        let reconnecting = EventsSessionStatus.reconnecting(
            attempt: 2, delay: .seconds(1), failure: .timedOut)

        #expect(condition(reconnecting, withinGrace: true) == nil)
        #expect(condition(reconnecting, withinGrace: false) == .hostReconnecting)
        #expect(condition(.connected, withinGrace: false) == .hostLoadingAgents)
        #expect(condition(.failed(.authenticationFailed), withinGrace: true) == .hostFailed)
        #expect(condition(.connected, awaiting: false, withinGrace: false) == nil)
        // An on-stage attach meets `.suspended` only on a return's
        // activation edge, before the Console resumes the Host: connecting.
        #expect(condition(.suspended, withinGrace: false) == nil)

        let presentation = TerminalStatusPresentation(
            status: .connecting,
            hostCondition: MissingAgentPresentation.attachHostCondition(
                agentID: agentID, hostStatuses: [host.id: reconnecting], hosts: [host],
                hostsAwaitingSnapshot: [host.id], hostStandingFailures: [:],
                hostsWithinReconnectGrace: []))
        #expect(presentation?.kind == .connecting)
        #expect(presentation?.title == "Reconnecting…")
        #expect(
            TerminalStatusPresentation(
                status: .live,
                hostCondition: MissingAgentPresentation.attachHostCondition(
                    agentID: agentID, hostStatuses: [host.id: .failed(.authenticationFailed)],
                    hosts: [host], hostsAwaitingSnapshot: [host.id], hostStandingFailures: [:],
                    hostsWithinReconnectGrace: [])) == nil)
    }
}

/// A countdown's clock: every wait lasts until the test elapses it.
private actor ManualGraceClock {
    private var waiters: [CheckedContinuation<Void, any Error>] = []

    var waiting: Int { waiters.count }

    func sleep() async throws {
        try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    func elapse() {
        let elapsed = waiters
        waiters.removeAll()
        for waiter in elapsed { waiter.resume() }
    }
}
