import Foundation
import Testing

@testable import Waycar

@MainActor
@Suite("Console shell rows")
struct ConsoleTerminalInventoryTests {
    @Test func everyAgentlessPaneIsAShellRowPerHost() async throws {
        let first = Host.fixture(name: "alpha")
        let second = Host.fixture(name: "beta")
        let snapshot = snapshot(
            panes: [
                pane("agent", agent: "claude"),
                pane("shell"),
                pane("other-tab", tab: "w1:t2"),
                pane("other-workspace", workspace: "w2", tab: "w2:t1"),
            ], agents: [.fixture(paneID: "agent")])
        let firstTransport = ScriptedTransport(snapshot: snapshot)
        let secondTransport = ScriptedTransport(snapshot: snapshot)
        let store = makeStore([first.id: firstTransport, second.id: secondTransport])
        defer { store.setHosts([]) }
        store.setHosts([first, second])
        await store.resume()
        try await waitUntil { shells(store).count == 6 }

        #expect(Set(shells(store).map(\.id)).count == 6)
        let local = shells(store).filter { $0.hostID == first.id }
        #expect(Set(local.map(\.agent.paneID)) == ["shell", "other-tab", "other-workspace"])
        let otherTab = try #require(local.first { $0.agent.paneID == "other-tab" })
        #expect(otherTab.tabLabel == "Logs")
        #expect(otherTab.workspaceLabel == "Project")
        #expect(otherTab.agent.cwd == "/home/user/project")
        #expect(store.agents.first {
            $0.id == ConsoleAgent.ID(hostID: first.id, paneID: "agent")
        }?.isShell == false)
    }

    @Test func aPaneWithNoAgentIsAShellRowUntilAnAgentStartsInIt() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: snapshot(panes: [pane("shell")]))
        let store = makeStore([host.id: transport])
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        let id = ConsoleAgent.ID(hostID: host.id, paneID: "shell")
        try await waitUntil { store.agents.contains { $0.id == id } }

        let shell = try #require(store.agents.first { $0.id == id })
        #expect(shell.isShell)
        #expect(shell.agent.status == .shellTerminal)
        #expect(shell.agent.terminalID == "terminal_shell")
        #expect(shell.attachTarget == .terminal("terminal_shell"))
        // Its name is the tab's label, the way a Default Shell launch names it.
        #expect(shell.agent.displayName == "Main")

        // An Agent starting in the pane replaces the row under the same id.
        await transport.setSnapshot(
            snapshot(panes: [pane("shell", agent: "claude")], agents: [.fixture(paneID: "shell")]))
        #expect(
            await transport.emit(
                HerdrEvent(kind: GlobalEventKind.paneAgentDetected.kind, data: .object([:])))
                == true)
        try await waitUntil { store.agents.first { $0.id == id }?.isShell == false }
        let agent = try #require(store.agents.first { $0.id == id })
        #expect(agent.agent.kind == "claude")
        #expect(agent.attachTarget == .agentPane("shell"))
        #expect(store.agents.count { $0.id == id } == 1)

        // And the Agent exiting back to its shell makes it a shell row again.
        await transport.setSnapshot(snapshot(panes: [pane("shell")]))
        #expect(
            await transport.emit(
                HerdrEvent(kind: GlobalEventKind.paneExited.kind, data: .object([:])))
                == true)
        try await waitUntil { store.agents.first { $0.id == id }?.isShell == true }
    }

    @Test func shellPaneCreationAndClosureConvergeFromLifecycleEvents() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: snapshot(panes: [pane("shell")]))
        let store = makeStore([host.id: transport])
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil { shellPaneIDs(store) == ["shell"] }
        #expect(
            await transport.capturedSubscriptions.first?.contains(.global(.paneCreated)) == true)
        await transport.setSnapshot(snapshot(panes: [pane("shell"), pane("split")]))
        #expect(
            await transport.emit(
                HerdrEvent(kind: GlobalEventKind.paneCreated.kind, data: .object([:])))
                == true)
        try await waitUntil { shellPaneIDs(store) == ["shell", "split"] }
        await transport.setSnapshot(snapshot(panes: [pane("split")]))
        #expect(
            await transport.emit(
                HerdrEvent(kind: GlobalEventKind.paneClosed.kind, data: .object([:])))
                == true)
        try await waitUntil { shellPaneIDs(store) == ["split"] }
    }

    @Test func frequentPaneUpdatesRefreshMetadataWithoutSnapshotRequests() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: snapshot(panes: [pane("shell")]))
        let store = makeStore([host.id: transport])
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil { shells(store).count == 1 }
        let count = await transport.snapshotFetchCount
        for index in 0..<20 {
            let changed = pane("shell", title: "Build \(index)", foregroundCwd: "/work/\(index)")
            #expect(await transport.emit(try update(changed)) == true)
        }
        try await waitUntil { shells(store).first?.agent.title == "Build 19" }
        #expect(shells(store).first?.agent.cwd == "/work/19")
        #expect(await transport.snapshotFetchCount == count)
    }

    @Test func paneUpdateDuringSnapshotSurvivesItsOlderResponse() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: snapshot(panes: [pane("shell")]))
        let store = makeStore([host.id: transport])
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil { shells(store).count == 1 }
        let gate = ScriptedTransportCallGate()
        await transport.setSnapshot(snapshot(panes: [pane("shell")], workspaceLabel: "Renamed"))
        await transport.gateNextSnapshot(using: gate)
        #expect(
            await transport.emit(
                HerdrEvent(kind: GlobalEventKind.workspaceMetadataUpdated.kind, data: .object([:])))
                == true
        )
        try await waitUntil { await gate.entryCount == 1 }
        #expect(
            await transport.emit(
                try update(pane("shell", title: "New title", foregroundCwd: "/new")))
                == true)
        try await waitUntil { shells(store).first?.agent.cwd == "/new" }
        await gate.open()
        try await waitUntil { shells(store).first?.workspaceLabel == "Renamed" }
        #expect(shells(store).first?.agent.title == "New title")
        #expect(shells(store).first?.agent.cwd == "/new")
    }

    @Test func suspensionKeepsShellRowsAndRejectsAnInflightSnapshot() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: snapshot(panes: [pane("shell")]))
        let store = makeStore([host.id: transport])
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil { shells(store).count == 1 }
        let gate = ScriptedTransportCallGate()
        await transport.gateNextSnapshot(using: gate)
        await transport.setSnapshot(snapshot(panes: [pane("shell"), pane("stale")]))
        #expect(
            await transport.emit(
                HerdrEvent(kind: GlobalEventKind.paneCreated.kind, data: .object([:])))
                == true)
        try await waitUntil { await gate.entryCount == 1 }
        await store.suspend()
        try await waitUntil { store.hostsAwaitingSnapshot.contains(host.id) }
        await gate.open()
        try await Task.sleep(for: .milliseconds(30))
        #expect(shellPaneIDs(store) == ["shell"])
        #expect(store.hostsAwaitingSnapshot.contains(host.id))
    }

    // MARK: Shell Activity

    @Test func aShellRowShowsItsRunningCommandAndAnAgentRowNone() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: snapshot(
                panes: [pane("agent", agent: "claude"), pane("shell")],
                agents: [.fixture(paneID: "agent")]))
        await transport.setShellActivities([
            "shell": .running(command: "sudo apt update"),
            "agent": .running(command: "claude"),
        ])
        let store = makeStore([host.id: transport], shellActivityInterval: .milliseconds(10))
        defer { store.setHosts([]) }
        store.setShellActivityForeground(true)
        store.setHosts([host])
        await store.resume()

        try await waitUntil {
            shells(store).first?.shellActivity == .running(command: "sudo apt update")
        }
        let shell = try #require(shells(store).first)
        // Shell Activity never touches the Agent Status a shell row lists.
        #expect(shell.agent.status == .shellTerminal)
        let agent = try #require(store.agents.first { $0.agent.paneID == "agent" })
        #expect(agent.shellActivity == nil)
        // Only Shell panes are ever asked about.
        let requests = await transport.shellActivityRequests
        #expect(!requests.isEmpty)
        #expect(requests.allSatisfy { $0 == ["shell"] })
    }

    @Test func aShellMissingFromTheAnswerIsUnknown() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: snapshot(panes: [pane("shell"), pane("split")]))
        await transport.setShellActivities(["shell": .idle])
        let store = makeStore([host.id: transport], shellActivityInterval: .milliseconds(10))
        defer { store.setHosts([]) }
        store.setShellActivityForeground(true)
        store.setHosts([host])
        await store.resume()
        try await waitUntil { row("shell", in: store)?.shellActivity == .idle }
        #expect(row("split", in: store)?.shellActivity == nil)

        // A pane the next answer leaves out goes back to unknown.
        await transport.setShellActivities(["split": .running(command: "make")])
        try await waitUntil {
            row("split", in: store)?.shellActivity == .running(command: "make")
        }
        #expect(row("shell", in: store)?.shellActivity == nil)
    }

    @Test func paneUpdatesAndResyncsKeepAShellsActivity() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: snapshot(panes: [pane("shell")]))
        await transport.setShellActivities(["shell": .running(command: "top")])
        // Sweeps keep coming on the interval while the resync lands.
        let store = makeStore([host.id: transport], shellActivityInterval: .milliseconds(10))
        defer { store.setHosts([]) }
        store.setShellActivityForeground(true)
        store.setHosts([host])
        await store.resume()
        try await waitUntil { shells(store).first?.shellActivity == .running(command: "top") }
        // From here every sweep fails without a link failure, which keeps
        // what the rows show: only the projection itself can keep it.
        await transport.setShellActivityFailure(
            TransportError.channelFailed(detail: "scripted"))

        #expect(await transport.emit(try update(pane("shell", title: "top - load 0.42"))) == true)
        try await waitUntil { shells(store).first?.agent.title == "top - load 0.42" }
        #expect(shells(store).first?.shellActivity == .running(command: "top"))

        let reads = await transport.shellActivityReads
        await transport.setSnapshot(snapshot(panes: [pane("shell")], workspaceLabel: "Renamed"))
        #expect(
            await transport.emit(
                HerdrEvent(kind: GlobalEventKind.workspaceMetadataUpdated.kind, data: .object([:])))
                == true)
        try await waitUntil {
            await transport.shellActivityReads > reads
                && shells(store).first?.workspaceLabel == "Renamed"
        }
        #expect(shells(store).first?.shellActivity == .running(command: "top"))
    }

    @Test func anotherTerminalOnTheSamePaneDropsTheActivity() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: snapshot(panes: [pane("shell")]))
        await transport.setShellActivities(["shell": .running(command: "vim notes.txt")])
        let store = makeStore([host.id: transport])
        defer { store.setHosts([]) }
        store.setShellActivityForeground(true)
        store.setHosts([host])
        await store.resume()
        try await waitUntil {
            shells(store).first?.shellActivity == .running(command: "vim notes.txt")
        }
        await transport.setShellActivityFailure(
            TransportError.channelFailed(detail: "scripted"))

        await transport.setSnapshot(snapshot(panes: [pane("shell", terminal: "terminal_new")]))
        #expect(
            await transport.emit(
                HerdrEvent(kind: GlobalEventKind.paneCreated.kind, data: .object([:])))
                == true)
        try await waitUntil { shells(store).first?.agent.terminalID == "terminal_new" }
        #expect(shells(store).first?.shellActivity == nil)
    }

    @Test func disconnectingClearsShellActivityUntilTheHostAnswersAgain() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: snapshot(panes: [pane("shell")]))
        await transport.setShellActivities(["shell": .running(command: "tail -f log")])
        let store = makeStore([host.id: transport], shellActivityInterval: .milliseconds(10))
        defer { store.setHosts([]) }
        store.setShellActivityForeground(true)
        store.setHosts([host])
        await store.resume()
        try await waitUntil {
            shells(store).first?.shellActivity == .running(command: "tail -f log")
        }

        await store.suspend()
        try await waitUntil { store.hostStatuses[host.id] == .suspended }
        #expect(shells(store).first?.shellActivity == nil)
        #expect(shells(store).count == 1)
        // Lets a sweep the suspension cancelled mid-call land first.
        try await Task.sleep(for: .milliseconds(30))
        let reads = await transport.shellActivityReads
        try await Task.sleep(for: .milliseconds(80))
        #expect(await transport.shellActivityReads == reads)

        await store.resume()
        try await waitUntil {
            shells(store).first?.shellActivity == .running(command: "tail -f log")
        }
    }

    @Test func sweepsRunOnlyInTheForeground() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: snapshot(panes: [pane("shell")]))
        await transport.setShellActivities(["shell": .running(command: "htop")])
        let store = makeStore([host.id: transport], shellActivityInterval: .milliseconds(10))
        defer { store.setHosts([]) }
        // A store starts off screen: only a window's `.active` turns it on.
        store.setHosts([host])
        await store.resume()
        try await waitUntil { shells(store).count == 1 }
        try await Task.sleep(for: .milliseconds(80))
        #expect(await transport.shellActivityReads == 0)
        #expect(shells(store).first?.shellActivity == nil)

        store.setShellActivityForeground(true)
        try await waitUntil { shells(store).first?.shellActivity == .running(command: "htop") }
        // It keeps sweeping on the interval while on screen.
        let reads = await transport.shellActivityReads
        try await waitUntil { await transport.shellActivityReads > reads + 1 }

        store.setShellActivityForeground(false)
        #expect(shells(store).first?.shellActivity == nil)
        try await Task.sleep(for: .milliseconds(30))
        let backgroundReads = await transport.shellActivityReads
        try await Task.sleep(for: .milliseconds(80))
        #expect(await transport.shellActivityReads == backgroundReads)
    }

    @Test func aTmuxHostSweepsAfterEachSnapshotAndNeverOnATimer() async throws {
        let transport = ScriptedTransport(snapshot: snapshot(panes: [pane("shell")]))
        await transport.setShellActivities(["shell": .running(command: "make")])
        let projection = makeProjection(
            transport, backend: .tmux, shellActivityInterval: .milliseconds(10))
        defer { projection.end() }
        projection.setForeground(true)
        projection.start(isActive: true)
        try await waitUntil {
            projection.agentsByPane["shell"]?.shellActivity == .running(command: "make")
        }

        // Fifteen intervals, each of which a timer would have swept. tmux
        // answers from the cache a live snapshot fills, so it sweeps once
        // after each and the connect's snapshots bound its sweeps.
        try await Task.sleep(for: .milliseconds(150))
        let reads = await transport.shellActivityReads
        let snapshots = await transport.snapshotFetchCount
        #expect(reads <= snapshots)

        // The next live snapshot sweeps again.
        await transport.setShellActivities(["shell": .idle])
        #expect(
            await transport.emit(
                HerdrEvent(kind: GlobalEventKind.workspaceMetadataUpdated.kind, data: .object([:])))
                == true)
        try await waitUntil { projection.agentsByPane["shell"]?.shellActivity == .idle }
    }

    @Test func herdrResyncsNeverSweepFasterThanTheInterval() async throws {
        let interval = Duration.milliseconds(300)
        let transport = ScriptedTransport(snapshot: snapshot(panes: [pane("shell")]))
        await transport.setShellActivities(["shell": .running(command: "make")])
        let projection = makeProjection(
            transport, backend: .herdr, shellActivityInterval: interval)
        defer { projection.end() }
        projection.setForeground(true)
        projection.start(isActive: true)
        try await waitUntil {
            projection.agentsByPane["shell"]?.shellActivity == .running(command: "make")
        }

        // Every Agent Status change brings a resync: here five, back to back.
        let start = ContinuousClock.now
        let reads = await transport.shellActivityReads
        for _ in 0..<5 {
            let snapshots = await transport.snapshotFetchCount
            #expect(
                await transport.emit(
                    HerdrEvent(
                        kind: GlobalEventKind.workspaceMetadataUpdated.kind, data: .object([:])))
                    == true)
            try await waitUntil { await transport.snapshotFetchCount > snapshots }
        }
        let swept = await transport.shellActivityReads - reads
        let elapsed = ContinuousClock.now - start
        // At most the sweep the wait armed before them was due for, plus one
        // per interval since: none rides a resync.
        #expect(swept <= Int(elapsed / interval) + 1)

        // The interval keeps sweeping.
        try await waitUntil { await transport.shellActivityReads > reads + swept }
    }

    private func shells(_ store: ConsoleStore) -> [ConsoleAgent] {
        store.agents.filter(\.isShell)
    }

    private func shellPaneIDs(_ store: ConsoleStore) -> [String] {
        shells(store).map(\.agent.paneID).sorted()
    }

    private func row(_ paneID: String, in store: ConsoleStore) -> ConsoleAgent? {
        store.agents.first { $0.agent.paneID == paneID }
    }

    private func pane(
        _ id: String, workspace: String = "w1", tab: String = "w1:t1",
        agent: String? = nil, title: String = "Shell", foregroundCwd: String? = nil,
        terminal: String? = nil
    ) -> PaneInfo {
        PaneInfo(
            agentStatus: .idle, focused: false, paneID: id, revision: 1,
            tabID: tab, terminalID: terminal ?? "terminal_\(id)", workspaceID: workspace,
            agent: agent, cwd: "/home/user/project", foregroundCwd: foregroundCwd,
            terminalTitleStripped: title)
    }

    private func snapshot(
        panes: [PaneInfo], agents: [AgentInfo] = [], workspaceLabel: String = "Project"
    ) -> SessionSnapshot {
        SessionSnapshot(
            agents: agents, layouts: [], panes: panes, protocolVersion: 22,
            tabs: [
                TabInfo(
                    agentStatus: .idle, focused: false, label: "Main", number: 1, paneCount: 2,
                    tabID: "w1:t1", workspaceID: "w1"),
                TabInfo(
                    agentStatus: .idle, focused: false, label: "Logs", number: 2, paneCount: 1,
                    tabID: "w1:t2", workspaceID: "w1"),
                TabInfo(
                    agentStatus: .idle, focused: false, label: "Other", number: 1, paneCount: 1,
                    tabID: "w2:t1", workspaceID: "w2"),
            ], version: "0.9.0",
            workspaces: [
                .fixture(workspaceID: "w1", label: workspaceLabel),
                .fixture(workspaceID: "w2", label: "Other project"),
            ])
    }

    private func update(_ pane: PaneInfo) throws -> HerdrEvent {
        let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(pane))
        return HerdrEvent(kind: GlobalEventKind.paneUpdated.kind, data: .object(["pane": value]))
    }

    private func makeStore(
        _ transports: [Host.ID: ScriptedTransport], shellActivityInterval: Duration? = nil
    ) -> ConsoleStore {
        ConsoleStore(
            snapshotRetryDelay: .milliseconds(10),
            shellActivityTiming: shellActivityInterval.map { ShellActivityTiming(interval: $0) }
                ?? ShellActivityTiming()
        ) { host, _, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: {
                    guard let transport = transports[host.id] else {
                        throw TransportError.sshUnreachable(detail: "unscripted host")
                    }
                    return transport
                },
                keepalive: nil)
        }
    }

    /// One Backend's projection over `transport`, on screen once the test
    /// says so.
    private func makeProjection(
        _ transport: ScriptedTransport, backend: HostBackend, shellActivityInterval: Duration
    ) -> HostConsoleProjection {
        let session = EventsSession(
            subscriptions: HostConsoleProjection.subscriptions(paneIDs: []),
            connect: { transport },
            keepalive: nil)
        return HostConsoleProjection(
            host: .fixture(), session: session, backend: backend,
            snapshotRetryDelay: .milliseconds(10),
            shellActivityTiming: ShellActivityTiming(interval: shellActivityInterval)) {}
    }
}
