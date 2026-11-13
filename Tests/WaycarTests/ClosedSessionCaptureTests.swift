import Foundation
import Testing

@testable import Waycar

/// How the Console notices a Closed Session: by diffing the rows a live
/// snapshot replaces, never on a disconnect or a removed Host.
@MainActor
@Suite("Closed session capture")
struct ClosedSessionCaptureTests {
    private func pane(_ id: String, terminal: String? = nil) -> PaneInfo {
        PaneInfo(
            agentStatus: .idle, focused: false, paneID: id, revision: 1, tabID: "w1:t1",
            terminalID: terminal ?? "terminal_\(id)", workspaceID: "w1",
            cwd: "/home/user/project", terminalTitleStripped: "zsh")
    }

    /// `kind: nil` is an Agent herdr lists before it has told which one it is
    /// (a launch still pending).
    private func agent(
        _ paneID: String, kind: String? = "claude", terminal: String? = nil,
        session: String? = nil
    ) -> AgentInfo {
        AgentInfo(
            agentStatus: .idle, focused: false, paneID: paneID, revision: 1, tabID: "w1:t1",
            terminalID: terminal ?? "terminal_\(paneID)", workspaceID: "w1", agent: kind,
            agentSession: session.map {
                AgentSessionInfo(
                    agent: kind ?? "claude", kind: .id, source: "herdr:\(kind ?? "claude")",
                    value: $0)
            },
            cwd: "/home/user/project", terminalTitleStripped: "Task")
    }

    private func snapshot(panes: [PaneInfo], agents: [AgentInfo] = []) -> SessionSnapshot {
        SessionSnapshot(
            agents: agents, layouts: [], panes: panes, protocolVersion: 22,
            tabs: [
                TabInfo(
                    agentStatus: .idle, focused: false, label: "Main", number: 1, paneCount: 1,
                    tabID: "w1:t1", workspaceID: "w1")
            ], version: "0.9.0",
            workspaces: [.fixture(workspaceID: "w1", label: "Project")])
    }

    private func makeStore(
        _ transport: ScriptedTransport, closed: ClosedSessionsStore,
        cache: ConsoleInventoryCache? = nil
    ) -> ConsoleStore {
        ConsoleStore(
            snapshotRetryDelay: .milliseconds(10), closedSessions: closed, inventoryCache: cache
        ) { _, _, subscriptions in
            EventsSession(
                subscriptions: subscriptions, connect: { transport }, keepalive: nil)
        }
    }

    /// Starts `store` on `host` and waits for `snapshot`'s rows.
    private func connect(
        _ store: ConsoleStore, host: Host, until paneID: String
    ) async throws {
        store.setHosts([host])
        await store.resume()
        try await waitUntil {
            store.agents.contains { $0.id == ConsoleAgent.ID(hostID: host.id, paneID: paneID) }
                && !store.hostsAwaitingSnapshot.contains(host.id)
        }
    }

    /// Serves `snapshot` on the next resync and triggers one.
    private func resync(
        _ transport: ScriptedTransport, to snapshot: SessionSnapshot,
        with kind: GlobalEventKind = .paneExited
    ) async {
        await transport.setSnapshot(snapshot)
        #expect(await transport.emit(HerdrEvent(kind: kind.kind, data: .object([:]))))
    }

    /// Suspends `store`, lets `absence` pass, and has the Host list
    /// `snapshot` when it answers again.
    private func reconnect(
        _ store: ConsoleStore, host: Host, transport: ScriptedTransport, clock: ManualClock,
        after absence: TimeInterval, to snapshot: SessionSnapshot
    ) async throws {
        await store.suspend()
        try await waitUntil { store.hostsAwaitingSnapshot.contains(host.id) }
        clock.advance(by: absence)
        await transport.setSnapshot(snapshot)
        await store.resume()
    }

    @Test func anAgentExitingBackToItsShellIsRecordedOnce() async throws {
        let host = Host.fixture()
        let clock = ManualClock()
        let closed = ClosedSessionsStore(now: { clock.now })
        let transport = ScriptedTransport(
            snapshot: snapshot(panes: [pane("p1")], agents: [agent("p1", session: "s-1")]))
        let store = makeStore(transport, closed: closed)
        defer { store.setHosts([]) }
        try await connect(store, host: host, until: "p1")

        await resync(transport, to: snapshot(panes: [pane("p1")]))
        try await waitUntil { closed.sessions.count == 1 }
        let recorded = try #require(closed.sessions.first)
        // Later snapshots of the same shell add nothing, and move nothing.
        clock.advance(by: 60)
        await resync(transport, to: snapshot(panes: [pane("p1")]), with: .paneCreated)
        try await Task.sleep(for: .milliseconds(50))

        #expect(closed.sessions == [recorded])
        #expect(recorded.hostID == host.id)
        #expect(recorded.kind == .claude)
        #expect(recorded.session?.value == "s-1")
        #expect(recorded.closedAt == clock.now.addingTimeInterval(-60))
    }

    @Test func anAgentWhosePaneClosesIsRecorded() async throws {
        let host = Host.fixture()
        let closed = ClosedSessionsStore()
        let transport = ScriptedTransport(
            snapshot: snapshot(
                panes: [pane("p1"), pane("p2")], agents: [agent("p1", kind: "codex")]))
        let store = makeStore(transport, closed: closed)
        defer { store.setHosts([]) }
        try await connect(store, host: host, until: "p1")

        await resync(transport, to: snapshot(panes: [pane("p2")]), with: .paneClosed)

        try await waitUntil { closed.sessions.count == 1 }
        #expect(closed.sessions.first?.kind == .codex)
        #expect(closed.sessions.first?.session == nil)
    }

    /// herdr clears `agent_session` as the Agent leaves, sometimes a
    /// snapshot before the row itself goes.
    @Test func theSessionHerdrClearedBeforeTheAgentLeftIsStillRecorded() async throws {
        let host = Host.fixture()
        let closed = ClosedSessionsStore()
        let transport = ScriptedTransport(
            snapshot: snapshot(panes: [pane("p1")], agents: [agent("p1", session: "s-1")]))
        let store = makeStore(transport, closed: closed)
        defer { store.setHosts([]) }
        try await connect(store, host: host, until: "p1")
        let initialFetches = await transport.snapshotFetchCount

        await resync(transport, to: snapshot(panes: [pane("p1")], agents: [agent("p1")]))
        try await waitUntil { await transport.snapshotFetchCount > initialFetches }
        try await Task.sleep(for: .milliseconds(30))
        #expect(closed.sessions.isEmpty)
        await resync(transport, to: snapshot(panes: [pane("p1")]))

        try await waitUntil { closed.sessions.count == 1 }
        #expect(closed.sessions.first?.session?.value == "s-1")
    }

    @Test func shellsClosingAndAgentsMovingPanesAreNoClosure() async throws {
        let host = Host.fixture()
        let closed = ClosedSessionsStore()
        let transport = ScriptedTransport(
            snapshot: snapshot(
                panes: [pane("p1", terminal: "T1"), pane("shell")],
                agents: [agent("p1", terminal: "T1")]))
        let store = makeStore(transport, closed: closed)
        defer { store.setHosts([]) }
        try await connect(store, host: host, until: "p1")

        // The shell's pane closes, and `pane.move` re-keys the Agent's pane:
        // the same terminal keeps running it under a new pane id.
        await resync(
            transport,
            to: snapshot(panes: [pane("p9", terminal: "T1")], agents: [agent("p9", terminal: "T1")]),
            with: .paneClosed)
        try await waitUntil {
            store.agents.contains { $0.id == ConsoleAgent.ID(hostID: host.id, paneID: "p9") }
        }
        try await Task.sleep(for: .milliseconds(30))

        #expect(closed.sessions.isEmpty)
    }

    /// herdr lists a just-started Agent before it knows which one it is and
    /// names it a moment later, then reports its session: one Agent
    /// throughout. A resume pending on it stays pending — backing out of it
    /// unused still closes it — and its record stays, hidden while it runs.
    @Test func aLaunchingAgentHerdrNamesLaterIsNoClosureOfItsResume() async throws {
        let host = Host.fixture()
        let clock = ManualClock()
        let closed = ClosedSessionsStore(now: { clock.now })
        let transport = ScriptedTransport(
            snapshot: snapshot(panes: [pane("p1")], agents: [agent("p1", session: "s-1")]))
        let store = makeStore(transport, closed: closed)
        defer { store.setHosts([]) }
        try await connect(store, host: host, until: "p1")
        await resync(transport, to: snapshot(panes: [pane("p1")]))
        try await waitUntil { closed.sessions.count == 1 }
        let recorded = try #require(closed.sessions.first)
        let resumed = ConsoleAgent.ID(hostID: host.id, paneID: "p9")
        closed.beginPendingResume(recorded.id, agent: resumed, terminal: "terminal_p9")

        // Unnamed and launching, then named, then reporting the session.
        let launch: [(kind: String?, session: String?)] = [
            (nil, nil), ("claude", nil), ("claude", "s-1"),
        ]
        for (kind, session) in launch {
            clock.advance(by: 1)
            await resync(
                transport,
                to: snapshot(
                    panes: [pane("p1"), pane("p9")],
                    agents: [agent("p9", kind: kind, session: session)]),
                with: .paneAgentDetected)
            try await waitUntil {
                store.agents.contains {
                    $0.id == resumed && $0.agent.kind == (kind ?? Agent.unidentifiedKind)
                        && $0.agent.agentSession?.value == session
                }
            }
        }

        #expect(closed.pendingResumes[resumed]?.record == recorded.id)
        #expect(closed.sessions.map(\.id) == [recorded.id])
        #expect(closed.listedSessions.isEmpty)
        var closedPanes: [ConsoleAgent.ID] = []
        await closed.backedOut(
            of: resumed, verifiedRow: { try await store.verifiedAgent($0) },
            closePane: { closedPanes.append($0.id) })
        #expect(closedPanes == [resumed])
        #expect(closed.listedSessions.map(\.id) == [recorded.id])
    }

    /// A resume whose Agent dies before herdr names it — its Pane back at the
    /// shell — did close: its record is listed again as it was.
    @Test func aResumeThatDiesBeforeHerdrNamesItIsListedAgain() async throws {
        let host = Host.fixture()
        let closed = ClosedSessionsStore()
        let transport = ScriptedTransport(
            snapshot: snapshot(panes: [pane("p1")], agents: [agent("p1", session: "s-1")]))
        let store = makeStore(transport, closed: closed)
        defer { store.setHosts([]) }
        try await connect(store, host: host, until: "p1")
        await resync(transport, to: snapshot(panes: [pane("p1")]))
        try await waitUntil { closed.sessions.count == 1 }
        let recorded = try #require(closed.sessions.first)
        let resumed = ConsoleAgent.ID(hostID: host.id, paneID: "p9")
        closed.beginPendingResume(recorded.id, agent: resumed, terminal: "terminal_p9")
        await resync(
            transport,
            to: snapshot(panes: [pane("p1"), pane("p9")], agents: [agent("p9", kind: nil)]),
            with: .paneAgentDetected)
        try await waitUntil {
            store.agents.contains { $0.id == resumed && $0.agent.kind == Agent.unidentifiedKind }
        }

        await resync(transport, to: snapshot(panes: [pane("p1"), pane("p9")]))

        try await waitUntil { closed.pendingResumes.isEmpty }
        #expect(closed.listedSessions.map(\.id) == [recorded.id])
        #expect(closed.listedSessions.first?.closedAt == recorded.closedAt)
    }

    /// Neither a disconnect nor a projection ending is an Agent closing. The
    /// Host stays in the catalog throughout, so nothing it recorded could be
    /// dropped along with it.
    @Test func aDisconnectOrAnEndedProjectionRecordsNothing() async throws {
        let host = Host.fixture()
        let closed = ClosedSessionsStore()
        let transport = ScriptedTransport(
            snapshot: snapshot(panes: [pane("p1")], agents: [agent("p1", session: "s-1")]))
        let store = makeStore(transport, closed: closed)
        defer { store.setHosts([]) }
        try await connect(store, host: host, until: "p1")

        await store.suspend()
        try await waitUntil { store.hostsAwaitingSnapshot.contains(host.id) }
        try await Task.sleep(for: .milliseconds(30))
        #expect(closed.sessions.isEmpty)

        // A re-targeted Host ends its projection and keeps its id.
        var retargeted = host
        retargeted.address = "elsewhere.example"
        store.setHosts([retargeted])
        try await Task.sleep(for: .milliseconds(30))
        #expect(closed.sessions.isEmpty)
    }

    /// The rows kept through a reconnect are what the first snapshot after
    /// it replaces: an Agent gone by then left while the app was away, and
    /// was last seen running when the Host last answered.
    @Test func anAgentGoneWhenTheHostAnswersAgainIsRecorded() async throws {
        let host = Host.fixture()
        let clock = ManualClock()
        let closed = ClosedSessionsStore(now: { clock.now })
        let transport = ScriptedTransport(
            snapshot: snapshot(panes: [pane("p1")], agents: [agent("p1", session: "s-1")]))
        let store = makeStore(transport, closed: closed)
        defer { store.setHosts([]) }
        try await connect(store, host: host, until: "p1")
        let lastAnswered = clock.now

        try await reconnect(
            store, host: host, transport: transport, clock: clock, after: 3600,
            to: snapshot(panes: [pane("p1")]))

        try await waitUntil { closed.sessions.count == 1 }
        let recorded = try #require(closed.sessions.first)
        #expect(recorded.session?.value == "s-1")
        #expect(recorded.lastSeenRunningAt == lastAnswered)
        #expect(recorded.closedAt == clock.now)
    }

    /// Back after longer than a record lives: every closure it could notice
    /// is too old to list, and any Forget of it may have expired.
    @Test func anAgentGoneAfterAnAbsenceLongerThanRetentionIsNotRecorded() async throws {
        let host = Host.fixture()
        let clock = ManualClock()
        let closed = ClosedSessionsStore(now: { clock.now })
        let transport = ScriptedTransport(
            snapshot: snapshot(panes: [pane("p1")], agents: [agent("p1", session: "s-1")]))
        let store = makeStore(transport, closed: closed)
        defer { store.setHosts([]) }
        try await connect(store, host: host, until: "p1")

        try await reconnect(
            store, host: host, transport: transport, clock: clock,
            after: ClosedSessionsStore.retention + 1, to: snapshot(panes: [pane("p1")]))

        try await waitUntil { !store.hostsAwaitingSnapshot.contains(host.id) }
        try await Task.sleep(for: .milliseconds(30))
        #expect(closed.sessions.isEmpty)
    }

    /// Rows seeded from the on-device cache were last seen running when the
    /// cached snapshot was taken live.
    @Test func anAgentGoneFromACachedInventoryWasLastSeenWhenTheCacheWasTaken() async throws {
        let (directory, cleanup) = makeClosedSessionsDirectory()
        defer { cleanup() }
        let host = Host.fixture()
        let clock = ManualClock()
        let cachedAt = clock.now.addingTimeInterval(-600)
        let cache = ConsoleInventoryCache(directory: directory)
        cache.save(
            ConsoleInventoryCache.Entry(
                snapshot: snapshot(panes: [pane("p1")], agents: [agent("p1", session: "s-1")]),
                sidebarLayout: nil, verifiedAt: cachedAt),
            for: host)
        cache.flush()
        let closed = ClosedSessionsStore(now: { clock.now })
        let transport = ScriptedTransport(snapshot: snapshot(panes: [pane("p1")]))
        let store = makeStore(transport, closed: closed, cache: cache)
        defer { store.setHosts([]) }

        store.setHosts([host])
        await store.resume()

        try await waitUntil { closed.sessions.count == 1 }
        #expect(closed.sessions.first?.session?.value == "s-1")
        #expect(closed.sessions.first?.lastSeenRunningAt == cachedAt)
    }

    /// A cache that does not say when it was taken could be any age.
    @Test func aCachedInventoryOfUnknownAgeRecordsNothing() async throws {
        let (directory, cleanup) = makeClosedSessionsDirectory()
        defer { cleanup() }
        let host = Host.fixture()
        let cache = ConsoleInventoryCache(directory: directory)
        cache.save(
            ConsoleInventoryCache.Entry(
                snapshot: snapshot(panes: [pane("p1")], agents: [agent("p1", session: "s-1")]),
                sidebarLayout: nil),
            for: host)
        cache.flush()
        let closed = ClosedSessionsStore()
        let transport = ScriptedTransport(snapshot: snapshot(panes: [pane("p1")]))
        let store = makeStore(transport, closed: closed, cache: cache)
        defer { store.setHosts([]) }

        store.setHosts([host])
        #expect(store.agents.contains { $0.agent.paneID == "p1" && !$0.isShell })
        await store.resume()

        try await waitUntil { !store.hostsAwaitingSnapshot.contains(host.id) }
        try await Task.sleep(for: .milliseconds(30))
        #expect(closed.sessions.isEmpty)
    }

    /// The Agent exited and the same kind started again in its Pane while the
    /// app was away: the new one reports another session.
    @Test func aSameKindRelaunchReportingAnotherSessionRecordsTheOldOne() async throws {
        let host = Host.fixture()
        let clock = ManualClock()
        let closed = ClosedSessionsStore(now: { clock.now })
        let transport = ScriptedTransport(
            snapshot: snapshot(panes: [pane("p1")], agents: [agent("p1", session: "s-1")]))
        let store = makeStore(transport, closed: closed)
        defer { store.setHosts([]) }
        try await connect(store, host: host, until: "p1")

        try await reconnect(
            store, host: host, transport: transport, clock: clock, after: 60,
            to: snapshot(panes: [pane("p1")], agents: [agent("p1", session: "s-2")]))

        try await waitUntil { closed.sessions.count == 1 }
        #expect(closed.sessions.map(\.session?.value) == ["s-1"])
    }

    /// herdr lets a running claude switch sessions in place (`/clear`,
    /// `/resume`): on a live connection that is no closure. The session it
    /// switched to is the one recorded once it exits.
    @Test func aLiveSessionSwitchInPlaceRecordsNothing() async throws {
        let host = Host.fixture()
        let closed = ClosedSessionsStore()
        let transport = ScriptedTransport(
            snapshot: snapshot(panes: [pane("p1")], agents: [agent("p1", session: "s-1")]))
        let store = makeStore(transport, closed: closed)
        defer { store.setHosts([]) }
        try await connect(store, host: host, until: "p1")

        await resync(
            transport, to: snapshot(panes: [pane("p1")], agents: [agent("p1", session: "s-2")]),
            with: .paneAgentDetected)
        try await waitUntil {
            store.agents.contains { $0.agent.agentSession?.value == "s-2" }
        }
        #expect(closed.sessions.isEmpty)

        await resync(transport, to: snapshot(panes: [pane("p1")]))
        try await waitUntil { closed.sessions.count == 1 }
        #expect(closed.sessions.map(\.session?.value) == ["s-2"])
    }

    /// What runs on the terminal after a reconnect may be a relaunch, so it
    /// does not inherit the session remembered from before: if it leaves
    /// without reporting one, its record opens the picker rather than
    /// resuming the conversation it replaced.
    @Test func anAgentFoundAfterAReconnectDoesNotInheritTheOldSession() async throws {
        let host = Host.fixture()
        let clock = ManualClock()
        let closed = ClosedSessionsStore(now: { clock.now })
        let transport = ScriptedTransport(
            snapshot: snapshot(panes: [pane("p1")], agents: [agent("p1", session: "s-1")]))
        let store = makeStore(transport, closed: closed)
        defer { store.setHosts([]) }
        try await connect(store, host: host, until: "p1")

        try await reconnect(
            store, host: host, transport: transport, clock: clock, after: 60,
            to: snapshot(panes: [pane("p1")], agents: [agent("p1")]))
        try await waitUntil { !store.hostsAwaitingSnapshot.contains(host.id) }
        await resync(transport, to: snapshot(panes: [pane("p1")]))

        try await waitUntil { closed.sessions.count == 1 }
        #expect(closed.sessions.first?.session == nil)
    }

    /// Resumed from another device: this one only stops listing the record
    /// while the session runs, and lists it again once it closes.
    @Test func aRecordWhoseSessionRunsAgainOnTheHostIsUnlistedWhileItRuns() async throws {
        let host = Host.fixture()
        let closed = ClosedSessionsStore()
        let transport = ScriptedTransport(
            snapshot: snapshot(panes: [pane("p1")], agents: [agent("p1", session: "s-1")]))
        let store = makeStore(transport, closed: closed)
        defer { store.setHosts([]) }
        try await connect(store, host: host, until: "p1")
        await resync(transport, to: snapshot(panes: [pane("p1")]))
        try await waitUntil { closed.listedSessions.count == 1 }

        await resync(
            transport,
            to: snapshot(panes: [pane("p1"), pane("p2")], agents: [agent("p2", session: "s-1")]),
            with: .paneAgentDetected)
        try await waitUntil { closed.listedSessions.isEmpty }
        #expect(closed.sessions.count == 1)

        await resync(transport, to: snapshot(panes: [pane("p1"), pane("p2")]))
        try await waitUntil { closed.listedSessions.count == 1 }
        #expect(closed.listedSessions.first?.session?.value == "s-1")
    }

    /// Backing out of an unused resume takes its row off the Console index
    /// and lists its record the moment it starts; a close that fails puts
    /// the row back and keeps the record unlisted.
    @Test func backingOutHidesTheResumedRowUntilTheCloseFails() async throws {
        let host = Host.fixture()
        let closed = ClosedSessionsStore()
        let transport = ScriptedTransport(
            snapshot: snapshot(panes: [pane("p1")], agents: [agent("p1", session: "s-1")]))
        let store = makeStore(transport, closed: closed)
        defer { store.setHosts([]) }
        try await connect(store, host: host, until: "p1")
        await resync(transport, to: snapshot(panes: [pane("p1")]))
        try await waitUntil { closed.sessions.count == 1 }
        let recorded = try #require(closed.sessions.first)
        let resumed = ConsoleAgent.ID(hostID: host.id, paneID: "p9")
        closed.beginPendingResume(recorded.id, agent: resumed, terminal: "terminal_p9")
        await resync(
            transport,
            to: snapshot(
                panes: [pane("p1"), pane("p9")], agents: [agent("p9", session: "s-1")]),
            with: .paneAgentDetected)
        try await waitUntil { store.indexAgents(holding: nil).contains { $0.id == resumed } }
        var duringClose: (index: [ConsoleAgent.ID], listed: [ClosedSession.ID])?

        await closed.backedOut(
            of: resumed, verifiedRow: { try await store.verifiedAgent($0) }
        ) { _ in
            duringClose = (
                store.indexAgents(holding: nil).map(\.id), closed.listedSessions.map(\.id))
            throw TransportError.sshUnreachable(detail: "down")
        }

        #expect(duringClose?.index.contains(resumed) == false)
        #expect(duringClose?.listed == [recorded.id])
        #expect(store.indexAgents(holding: nil).contains { $0.id == resumed })
        #expect(closed.listedSessions.isEmpty)
        #expect(closed.sessions == [recorded])
    }
}
