import Foundation
import Testing

@testable import Waycar

@MainActor
@Suite("Codex session links")
struct CodexSessionLinksTests {
    static let host = Host.fixture()

    static func pane(_ id: String = "tmux:%1", cwd: String = "/work/app", line: String? = nil,
                     backend: HostBackend = .tmux) -> ConsoleAgent {
        var row = ConsoleAgent(hostID: host.id, hostName: host.displayName,
            agent: Agent(terminalID: "term-\(id)", kind: "codex", title: "Codex", status: .idle,
                workspaceID: "app", tabID: "tab-\(id)", paneID: id, cwd: cwd, revision: 1),
            workspaceLabel: "app", repositoryCheckout: nil, backend: backend)
        row.paneCommandLine = line
        return row
    }

    static func thread(_ id: String = "t", cwd: String = "/work/app", threadSource: String? = "user") -> ConsoleAgent {
        var row = ConsoleAgent(hostID: host.id, hostName: host.displayName,
            agent: Agent(CodexConsoleChatTests.thread(id, status: .working)),
            workspaceLabel: "app", repositoryCheckout: nil, backend: .codex)
        row.agent = Agent(terminalID: "codex:\(id)", kind: "codex", title: "Codex", status: .working,
            workspaceID: "codex:cwd", tabID: "codex:\(id)", paneID: "codex:\(id)", cwd: cwd, revision: 1)
        row.serverSessionOrigin = threadSource
        return row
    }

    @Test(arguments: ["codex resume other", nil] as [String?])
    func markerWinsOverCommandAndFolder(line: String?) throws {
        let pane = Self.pane(line: line)
        let marker = ChatModeMarker(paneID: pane.agent.paneID, terminalID: pane.agent.terminalID,
            kind: "codex", cwd: pane.agent.cwd, session: .init(kind: "id", value: "t"),
            chatMode: false, launchedAt: .now)
        let merged = ServerSessionLinks.merge([pane, Self.thread(), Self.thread("other")]) { _ in marker }
        #expect(merged.count == 2)
        #expect(merged.first { $0.agent.paneID == "codex:t" }?.linkedTerminal?.id == pane.id)
        #expect(merged.first { $0.agent.paneID == "codex:other" }?.linkedTerminal == nil)
    }

    @Test func resumeCommandLinksWithoutFolderGuessing() {
        let pane = Self.pane(cwd: "/elsewhere", line: "/opt/bin/codex -c model=fast resume t")
        let merged = ServerSessionLinks.merge([pane, Self.thread(threadSource: "waycar")]) { _ in nil }
        #expect(merged.count == 1 && merged.first?.linkedTerminal?.backend == .tmux)
        #expect(merged.first?.linkedTerminal?.id == pane.id)
    }

    @Test(arguments: ["/private/tmp/app/", "/private/var/app/", "/work/app/"])
    func uniqueFolderLinksCanonicalPaths(cwd: String) {
        let normalized = cwd.replacingOccurrences(of: "/private", with: "").dropLast()
        let pane = Self.pane(cwd: cwd, line: "codex")
        let merged = ServerSessionLinks.merge([pane, Self.thread(cwd: String(normalized))]) { _ in nil }
        #expect(merged.count == 1 && merged.first?.linkedTerminal?.id == pane.id)
    }

    @Test(arguments: ["waycar", nil, "unknown"] as [String?])
    func folderFallbackNeverLinksWaycarOrUnknownThreads(threadSource: String?) {
        let merged = ServerSessionLinks.merge([
            Self.pane(line: "codex"), Self.thread(threadSource: threadSource)
        ]) { _ in nil }
        #expect(merged.count == 2 && merged.allSatisfy { $0.linkedTerminal == nil })
    }

    @Test func realShapedDeskThreadLinksByThreadSourceDespiteVSCodeSource() throws {
        let record: JSONValue = .object([
            "id": .string("desk"), "cwd": .string("/work/app"), "ephemeral": .bool(false),
            "source": .string("vscode"), "threadSource": .string("user"),
            "status": .object(["type": .string("idle")])])
        let thread = try #require(CodexThread(record))
        var row = ConsoleAgent(hostID: Self.host.id, hostName: Self.host.displayName,
            agent: Agent(thread.info), workspaceLabel: nil, repositoryCheckout: nil, backend: .codex)
        row.serverSessionOrigin = thread.threadSource
        let pane = Self.pane(line: "codex")
        let merged = ServerSessionLinks.merge([pane, row]) { _ in nil }
        #expect(thread.source == "vscode")
        #expect(merged.count == 1 && merged.first?.linkedTerminal?.id == pane.id)
    }

    @Test(arguments: ["codex resume missing", nil, "codex --no-daemon", "sh"] as [String?])
    func folderFallbackRequiresKnownDaemonModeWithoutAnotherResume(line: String?) {
        let merged = ServerSessionLinks.merge([Self.pane(line: line), Self.thread()]) { _ in nil }
        #expect(merged.count == 2)
        #expect(merged.allSatisfy { $0.linkedTerminal == nil })
    }

    @Test func terminalOwnershipUsesThePaneButNavigationKeepsTheThread() throws {
        let pane = Self.pane("w1:p1", line: "codex resume t", backend: .herdr)
        let thread = try #require(ServerSessionLinks.merge([pane, Self.thread()]) { _ in nil }.first)
        let router = AgentNotificationRouter()
        router.agentsDidChange([thread])
        router.open(.init(hostID: thread.hostID, paneID: thread.agent.paneID))
        #expect(router.path == [thread.id])
        #expect(router.backend(of: thread.id) == .herdr)
        #expect(HostTerminalClaim(sceneID: UUID(), hostID: thread.hostID,
            backend: router.backend(of: thread.id)).contendsForChannel)
        #expect(!Self.thread().canShowTerminal)
    }

    @Test func ambiguousFoldersAndStandalonePanesStayVisible() {
        let cases: [[ConsoleAgent]] = [
            [Self.pane(line: "codex"), Self.pane("tmux:%2", line: "codex"), Self.thread()],
            [Self.pane(line: "codex"), Self.thread(), Self.thread("t2")],
            [Self.pane(line: "codex --no-daemon resume t"), Self.thread()],
            [Self.pane(line: "codex"), Self.thread(threadSource: "waycar")],
        ]
        for rows in cases {
            let merged = ServerSessionLinks.merge(rows) { _ in nil }
            #expect(merged.count == rows.count && merged.allSatisfy { $0.linkedTerminal == nil })
        }
    }

    @Test func linkedTerminalStageLeavesOnChatLinkChangeAndThreadDeparture() {
        let pane = Self.pane()
        var visible = true
        var presented = true
        var current: ConsoleAgent? = pane
        let stage = AgentDetailStage(isVisible: { visible }, terminalAccess: { .holds })
            .linkedTerminal(pane, isPresented: { presented }, current: { current })
        #expect(stage.isVisible() && stage.isOnStage())
        presented = false // Show Chat, while the thread stays visible.
        #expect(!stage.isVisible() && !stage.isOnStage())
        presented = true
        current = Self.pane("tmux:%2") // The link now points elsewhere.
        #expect(!stage.isVisible() && !stage.isOnStage())
        current = nil // The link was lost.
        #expect(!stage.isVisible() && !stage.isOnStage())
        current = pane
        visible = false // Leaving the thread.
        #expect(!stage.isVisible() && !stage.isOnStage())
    }

    enum ResumeInput: CaseIterable, Sendable {
        case none, chat, terminal
    }

    @Test(arguments: ResumeInput.allCases)
    func resumedThreadCountsChatAndLinkedTerminalInputBeforeBackOut(_ input: ResumeInput) async throws {
        let host = Self.host
        let pane = AgentInfo.fixture(paneID: "tmux:%1", kind: "codex")
        let terminal = ScriptedTransport(snapshot: .fixture(agents: [pane]))
        let codex = ScriptedTransport(snapshot: .fixture(agents: [CodexConsoleChatTests.thread("t", status: .idle)]))
        await terminal.setServerSessionLinkFacts(ServerSessionLinkFacts(commandLines: [pane.paneID: "codex resume t"]))
        let defaults = UserDefaults(suiteName: "codex-resume-input-\(UUID())") ?? .standard
        let closed = ClosedSessionsStore()
        let store = ConsoleStore(
            pins: PinnedAgentsStore(defaults: defaults), unread: UnreadAgentsStore(defaults: defaults),
            closedSessions: closed, chatMode: ChatModeStore(defaults: defaults),
            rowLayouts: AgentRowLayoutStore(defaults: defaults),
            backendPreferences: HostBackendPreferences(defaults: defaults),
            makeSession: { _, backend, subscriptions in
                let transport = backend == .codex ? codex : backend == .tmux ? terminal : ScriptedTransport()
                return EventsSession(subscriptions: subscriptions, connect: { transport }, keepalive: nil)
            },
            detectBackends: { _ in .init(herdr: false, tmuxVersion: "3.4", ultimate: [],
                codex: .init(version: "0.167.1", path: "/bin/codex", socketPath: "/tmp/codex.sock")) })
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil { store.agents.first?.linkedTerminal != nil }
        let thread = try #require(store.agents.first)
        let linkedPane = try #require(store.linkedTerminalAgent(for: thread))
        closed.record([ClosedAgentCapture(row: thread,
            session: .init(agent: "codex", kind: .id, source: "codex", value: "t"),
            lastSeenRunningAt: Date())])
        let record = try #require(closed.sessions.first)
        closed.beginPendingResume(record.id, agent: thread.id, terminal: thread.agent.terminalID)
        switch input {
        case .none: break
        case .chat: store.noteUserInput(to: thread.id)
        case .terminal: store.noteUserInput(to: linkedPane.id)
        }
        #expect((closed.pendingResumes[thread.id] != nil) == (input == .none))
        var closedRows: [ConsoleAgent.ID] = []
        await closed.backedOut(of: thread.id,
            verifiedRow: { try await store.verifiedAgent($0) },
            closePane: { closedRows.append($0.id) })
        #expect(closedRows == (input == .none ? [thread.id] : []))
        #expect((closed.backedOutResumes[thread.id] != nil) == (input == .none))
        // Neither input path may silently retire a used thread or its pane.
        #expect(store.linkedTerminalAgent(for: thread)?.id == linkedPane.id)
    }

    /// A real Console merge, not a filtered fake list: capture callbacks run
    /// before publish, exactly when the link must still suppress the pane.
    enum Change: CaseIterable, Sendable, Equatable {
        case paneCloses, paneBecomesShell, threadUnloads
    }

    @Test(arguments: Change.allCases)
    func mergedPaneNeverDuplicatesGlancesOrClosedSessions(change: Change) async throws {
        let host = Self.host
        let pane = AgentInfo.fixture(paneID: "tmux:%1", kind: "codex")
        let terminal = ScriptedTransport(snapshot: .fixture(agents: [pane]))
        let codex = ScriptedTransport(snapshot: .fixture(agents: [CodexConsoleChatTests.thread("t", status: .working)]))
        await terminal.setServerSessionLinkFacts(ServerSessionLinkFacts(commandLines: [pane.paneID: "codex resume t"]))
        await codex.setServerSessionLinkFacts(ServerSessionLinkFacts(sessionOrigins: ["t": "user"]))
        let defaults = UserDefaults(suiteName: "codex-links-\(UUID())") ?? .standard
        let store = ConsoleStore(
            pins: PinnedAgentsStore(defaults: defaults), unread: UnreadAgentsStore(defaults: defaults),
            closedSessions: ClosedSessionsStore(), chatMode: ChatModeStore(defaults: defaults),
            rowLayouts: AgentRowLayoutStore(defaults: defaults),
            backendPreferences: HostBackendPreferences(defaults: defaults),
            makeSession: { _, backend, subscriptions in
                let transport = backend == .codex ? codex : backend == .tmux ? terminal : ScriptedTransport()
                return EventsSession(subscriptions: subscriptions, connect: { transport }, keepalive: nil)
            },
            detectBackends: { _ in .init(herdr: false, tmuxVersion: "3.4", ultimate: [],
                codex: .init(version: "0.167.1", path: "/bin/codex", socketPath: "/tmp/codex.sock")) })
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil {
            store.verifiedAgents.count == 1 && store.agents.first?.linkedTerminal != nil
        }
        let thread = try #require(store.agents.first)
        #expect(thread.canShowTerminal)
        let resolved = try #require(store.linkedTerminalAgent(for: thread))
        #expect(resolved.backend == .tmux && resolved.agent.paneID == pane.paneID)
        #expect(store.agents.allSatisfy { $0.agent.paneID != pane.paneID })
        #expect(store.verifiedAgents.count == 1)
        let live = try #require(AgentActivityContentBuilder.desire(from: store.verifiedAgents, hostName: host.displayName))
        #expect(live.agents.map(\.paneID) == ["codex:t"] && live.counts.working == 1)
        if change == .threadUnloads {
            await codex.setSnapshot(.fixture())
            #expect(await codex.emit(HerdrEvent(kind: GlobalEventKind.paneExited.kind, data: .object([:]))))
            try await waitUntil {
                store.agents.count == 1 && store.agents.first?.id == resolved.id
                    && store.closedSessions.sessions.count == 1
            }
            #expect(store.closedSessions.sessions.first?.backend == .codex)
            #expect(store.closedSessions.sessions.first?.session?.value == "t")
            return
        }
        let exitsToShell = change == .paneBecomesShell
        if exitsToShell {
            let shell = PaneInfo(agentStatus: .unknown, focused: false, paneID: pane.paneID,
                revision: 2, tabID: pane.tabID, terminalID: pane.terminalID, workspaceID: pane.workspaceID)
            await terminal.setSnapshot(SessionSnapshot(agents: [], layouts: [], panes: [shell],
                protocolVersion: 17, tabs: [], version: "fake", workspaces: []))
        } else {
            await terminal.setSnapshot(.fixture())
        }
        #expect(await terminal.emit(HerdrEvent(kind: GlobalEventKind.paneExited.kind, data: .object([:]))))
        try await waitUntil {
            store.agents.first(where: { $0.backend == .codex })?.linkedTerminal == nil
        }
        #expect(store.closedSessions.sessions.isEmpty)
        #expect(store.linkedTerminalAgent(for: thread) == nil)
        #expect(store.agents.contains(where: \.isShell) == exitsToShell)
        await codex.setSnapshot(.fixture())
        #expect(await codex.emit(HerdrEvent(kind: GlobalEventKind.paneExited.kind, data: .object([:]))))
        try await waitUntil { store.closedSessions.sessions.count == 1 }
        #expect(store.closedSessions.sessions.first?.backend == .codex)
        #expect(store.closedSessions.sessions.first?.session?.value == "t")
    }
}
