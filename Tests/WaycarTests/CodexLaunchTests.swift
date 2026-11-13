import Foundation
import Testing

@testable import Waycar

@MainActor
@Suite("Codex New Agent", .timeLimit(.minutes(1)))
struct CodexLaunchTests {
    private let host = Host.fixture()
    private static let thread = agent("codex:thread")

    private static func agent(_ paneID: String) -> AgentInfo {
        AgentInfo(agentStatus: .idle, focused: false, paneID: paneID, revision: 1,
            tabID: "tab", terminalID: "term_" + paneID, workspaceID: "folder",
            agent: "codex", cwd: "/work/app", name: "review")
    }

    private final class FormCalls {
        var requests: [AgentLaunchRequest] = []
        var destinations: [StartAgentStore.LaunchDestination] = []
        var messages: [String] = []
        var markers: [ChatModeMarker] = []
        var starts = 0
    }

    private func form(
        state: ServerRuntimeState = .running, calls: FormCalls,
        hosts: [Host]? = nil, recents: RecentWorkspaceStore = RecentWorkspaceStore(),
        live: Bool = true, queue: StartAgentStore.LaunchQueue? = nil
    ) -> StartAgentStore {
        StartAgentStore(
            hosts: hosts ?? [host], workspaces: { _ in [] },
            existingAgentNames: { _ in ["review", "review-2"] },
            discoverAgentKinds: { _ in [] }, remoteHome: { _ in "/home/test" },
            start: { request, destination, _, backend in
                #expect(backend == .codex)
                calls.requests.append(request)
                calls.destinations.append(destination)
                return Agent(Self.thread)
            },
            backends: { _ in [.herdr, .core, .tmux, .codex] },
            // Codex's state; the Host has no other server chat runtime.
            serverRuntimeState: { _, server in server == .codex ? state : .notInstalled },
            startServerRuntime: { _, _ in calls.starts += 1 },
            awaitAgentVisible: { _ in }, recents: recents,
            selections: RecentSelectionsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            recordChatMode: { marker, _ in calls.markers.append(marker) },
            chatOptions: { _ in .init(prompt: "Short\n replies.", model: "test-model", quickThinking: true) },
            queueLaunchMessage: { message, _, _ in calls.messages.append(message) },
            queueFirstMessage: { message, _, _, _ in calls.messages.append(message.text); return true },
            launchQueue: queue, hasLiveSnapshot: { _ in live })
    }

    @Test func pickerOffersStoppedCodexAndRemembersItPerHost() async {
        let calls = FormCalls()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let recents = RecentWorkspaceStore(defaults: defaults)
        let second = Host.fixture(id: UUID())
        let store = form(state: .stopped(), calls: calls, hosts: [host, second], recents: recents)
        store.selectedHostID = host.id
        store.selectNewWorkspace()
        #expect(store.launchableBackends == [.herdr, .core, .tmux, .codex])
        store.newWorkspaceBackend = .codex
        #expect(store.launchesServerChat && store.launchesIntoFolder)
        #expect(!store.offersShell && !store.offersWorktree)
        #expect(!store.canSubmit)
        await store.startServerRuntime()
        #expect(calls.starts == 1)
        store.selectedHostID = second.id
        store.selectNewWorkspace()
        #expect(store.newWorkspaceBackend == .herdr)
        store.selectedHostID = host.id
        store.selectNewWorkspace()
        #expect(store.newWorkspaceBackend == .codex)
    }

    @Test(arguments: [ServerRuntimeState.notInstalled, .needsUpdate(version: "0.1")])
    func unavailableCodexIsNotOffered(_ state: ServerRuntimeState) {
        let store = form(state: state, calls: FormCalls())
        #expect(!store.launchableBackends.contains(.codex))
    }

    @Test(arguments: [true, false])
    func nativeChatOptionsAndFirstMessageNeedNoHostTools(chat: Bool) async throws {
        let calls = FormCalls()
        let store = form(calls: calls)
        store.selectNewWorkspace()
        store.newWorkspaceBackend = .codex
        store.newWorkspaceDirectory = "/work/app"
        store.name = "review"
        store.chatMode = chat
        store.firstMessageText = "Hello"
        #expect(store.canSubmit && store.showsChatModeToggle)
        await store.submit()
        let request = try #require(calls.requests.first)
        #expect(request.kind == "codex" && request.name == "review-3")
        #expect(request.arguments.isEmpty && request.environment.isEmpty)
        #expect(request.codex == (chat ? .init(
            developerInstructions: "Short replies.", model: "test-model", reasoningEffort: "low") : nil))
        #expect(calls.destinations == [.newWorkspace(.init(directory: "/work/app", label: nil))])
        #expect(calls.messages == ["Hello"])
        #expect(calls.markers.isEmpty)
        #expect(store.state == .started(.init(hostID: host.id, paneID: "codex:thread")))
    }

    @Test func aCodexThreadOriginKeepsItsRuntimeAndFolder() async throws {
        let calls = FormCalls()
        let store = StartAgentStore(
            hosts: [host], workspaces: { _ in [.init(id: "native", label: "app", backend: .codex)] },
            existingAgentNames: { _ in [] }, discoverAgentKinds: { _ in [.claude] },
            remoteHome: { _ in Issue.record("Must keep the origin folder"); return "/home/test" },
            start: { request, destination, _, backend in
                #expect(backend == .codex && request.kind == "codex")
                calls.destinations.append(destination)
                return Agent(Self.thread)
            }, backends: { _ in [.herdr, .codex] }, serverRuntimeState: { _, _ in .running },
            awaitAgentVisible: { _ in },
            origin: .init(hostID: host.id, workspaceID: "native", cwd: "/work/app"))
        store.chatMode = false
        await store.discoverAgents()
        #expect(store.canSubmit && store.launchesServerChat)
        await store.submit()
        #expect(calls.destinations == [.newWorkspace(.init(directory: "/work/app", label: nil))])
    }

    @Test func anOfflineCodexLaunchReplaysTheSameDraftAndFirstMessage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let saved = QueuedLaunchStore(directory: directory)
        var queued: QueuedLaunch?
        let calls = FormCalls()
        let store = form(calls: calls, live: false, queue: .init(store: saved, enqueue: {
            queued = $0
            try saved.save($0)
        }))
        store.selectNewWorkspace()
        store.newWorkspaceBackend = .codex
        store.newWorkspaceDirectory = "/work/app"
        store.name = "review"
        store.chatMode = false
        store.firstMessageText = "First"
        await store.submit()
        let launch = try #require(queued)
        #expect(calls.requests.isEmpty)
        #expect(launch.draft.dispatch.backend == .codex)
        #expect(saved.launches(on: host.id).first?.id == launch.id)
        let replay = form(calls: calls)
        let prepared = replay.prepareLaunchDraft(launch.draft)
        _ = await replay.launch(prepared, mayHaveStarted: true)
        #expect(calls.requests.first?.launchID == launch.id)
        #expect(calls.requests.first?.mayHaveStarted == true)
        #expect(calls.requests.first?.name == "review-3")
        #expect(calls.messages == ["First"])
    }

    private struct Fixture {
        let console: ConsoleStore
        let native: ScriptedTransport
        let terminals: [HostBackend: ScriptedTransport]
    }

    private func fixture(
        terminalBackends: [HostBackend], server: ServerChatBackend = .codex
    ) async throws -> Fixture {
        let session = server == .codex ? Self.thread : OpenCodeConsoleChatTests.session("ses_a", status: .idle)
        let native = ScriptedTransport(snapshot: .fixture(agents: [session]))
        await native.setStartedAgent(session)
        var terminals: [HostBackend: ScriptedTransport] = [:]
        for backend in terminalBackends {
            let paneID: String = switch backend {
            case .herdr: "w1:p1"
            case .core: "hc:t1"
            case .zellij: "zellij:fixture/terminal_0"
            default: "tmux:%1"
            }
            let pane = Self.agent(paneID)
            let transport = ScriptedTransport(snapshot: .fixture(agents: [pane]))
            await transport.setStartedAgent(pane)
            terminals[backend] = transport
        }
        let transports = terminals.merging([server.backend: native]) { first, _ in first }
        let presence = HostBackendPresence(
            herdr: terminalBackends.contains(.herdr),
            tmuxVersion: terminalBackends.contains(.tmux) ? "3.4" : nil,
            core: terminalBackends.contains(.core) ? .init(version: "0.1.14", path: "/bin/herdr-core") : nil,
            zellij: terminalBackends.contains(.zellij) ? .init(version: "0.46.0", path: "/bin/zellij") : nil,
            codex: server == .codex ? .init(version: "0.167.1", path: "/bin/codex", socketPath: "/tmp/codex.sock", appServerVersion: "0.167.1") : nil,
            opencode: server == .opencode ? OpenCodeConsoleChatTests.running : nil)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let console = ConsoleStore(
            chatMode: ChatModeStore(defaults: defaults),
            backendPreferences: HostBackendPreferences(defaults: defaults),
            makeSession: { _, backend, subscriptions in
                EventsSession(subscriptions: subscriptions, connect: {
                    guard let transport = transports[backend] else { throw TransportError.cancelled }
                    return transport
                }, keepalive: nil)
            }, detectBackends: { _ in presence })
        console.setHosts([host])
        await console.resume()
        try await waitUntil { console.presentBackends(on: host.id).count == transports.count
            && console.hasLiveSnapshots(on: host.id) }
        return Fixture(console: console, native: native, terminals: terminals)
    }

    @Test(arguments: [[HostBackend.herdr, .core, .tmux], [.core, .tmux], [.tmux], []])
    func threadThenPaneOnTheLeadRuntime(_ backends: [HostBackend]) async throws {
        let f = try await fixture(terminalBackends: backends)
        defer { f.console.setHosts([]) }
        let launchID = UUID()
        let request = AgentLaunchRequest(kind: "codex", name: "review", launchID: launchID)
        let agent = try await f.console.startAgent(
            request, at: .newWorkspace(.init(directory: "/work/app", label: nil)),
            on: host.id, backend: .codex)
        #expect(agent.paneID == "codex:thread")
        #expect(await f.native.workspaceStarts.count == 1)
        for backend in backends {
            let transport = try #require(f.terminals[backend])
            let starts = await transport.workspaceStarts
            #expect(starts.count == (backend == backends.first ? 1 : 0))
            if let (pane, spec) = starts.first {
                #expect(pane.arguments == ["resume", "thread"])
                #expect(pane.joinsCodexServer && pane.launchID == launchID)
                #expect(spec.directory == "/work/app")
                let marker = try #require(await transport.chatModeMarkerWrites.last)
                #expect(marker.kind == "codex" && !marker.chatMode)
                #expect(marker.session == .init(kind: "id", value: "thread"))
                #expect(marker.cwd == "/work/app")
            }
        }
    }

    @Test(arguments: ServerChatBackend.allCases)
    func zellijIsNotChosenForLinkedLaunch(_ server: ServerChatBackend) async throws {
        let f = try await fixture(terminalBackends: [.zellij], server: server)
        defer { f.console.setHosts([]) }
        let session = try await f.console.startAgent(
            .init(kind: server.agentKind.rawValue, name: "review"),
            at: .newWorkspace(.init(directory: "/work/app", label: nil)),
            on: host.id, backend: server.backend)
        #expect(session.kind == server.agentKind.rawValue)
        #expect(await f.native.workspaceStarts.count == 1)
        #expect(await f.terminals[.zellij]?.workspaceStarts.isEmpty == true)
    }

    @Test func hiddenCodexIsNotOfferedInNewAgent() async throws {
        let f = try await fixture(terminalBackends: [.tmux])
        defer { f.console.setHosts([]) }
        let form = f.console.makeStartAgentStore(hosts: [host])
        #expect(form.launchableBackends.contains(.codex))
        f.console.setShowsServerChat(false, .codex, for: host.id)
        #expect(!form.launchableBackends.contains(.codex))
        #expect(!f.console.backendPreferences.showsServerChat(.codex, for: host.id))
    }

    @Test func paneFailureKeepsTheThreadAndShowsOneQuietNotice() async throws {
        let f = try await fixture(terminalBackends: [.tmux])
        defer { f.console.setHosts([]) }
        let tmux = try #require(f.terminals[.tmux])
        await tmux.setStartFailure(.apiRejected(code: "failed", message: "No terminal"))
        let agent = try await f.console.startAgent(
            .init(kind: "codex", name: "review"),
            at: .newWorkspace(.init(directory: "/work/app", label: nil)), on: host.id, backend: .codex)
        let id = ConsoleAgent.ID(hostID: host.id, paneID: agent.paneID)
        #expect(agent.paneID == "codex:thread")
        #expect(f.console.serverLaunchNotices[id] == "Couldn't open a terminal for this thread. Chat still works.")
        f.console.dismissServerLaunchNotice(for: id)
        #expect(f.console.serverLaunchNotices[id] == nil)
    }

    @Test func replayPreservesBothLaunchTagsAndNativeOptions() async throws {
        let f = try await fixture(terminalBackends: [.tmux])
        defer { f.console.setHosts([]) }
        let id = UUID()
        let native = CodexLaunchOptions(developerInstructions: "Short", model: "test")
        let request = AgentLaunchRequest(kind: "codex", name: "review", launchID: id,
            mayHaveStarted: true, codex: native)
        _ = try await f.console.startAgent(request,
            at: .newWorkspace(.init(directory: "/work/app", label: nil)), on: host.id,
            backend: .codex, retriesLinkFailure: false)
        let thread = try #require(await f.native.workspaceStarts.first?.0)
        let pane = try #require(await f.terminals[.tmux]?.workspaceStarts.first?.0)
        #expect(thread.mayHaveStarted && pane.mayHaveStarted)
        #expect(thread.launchID == id && pane.launchID == id)
        #expect(thread.codex == native && pane.joinsCodexServer)
    }

    @Test(arguments: ServerChatBackend.allCases)
    func aLostTerminalAnswerPropagatesForIndependentTagReconciliation(_ server: ServerChatBackend) async throws {
        let f = try await fixture(terminalBackends: [.tmux], server: server)
        defer { f.console.setHosts([]) }
        let terminal = try #require(f.terminals[.tmux])
        await terminal.setStartFailure(.sshUnreachable(detail: "lost terminal answer"))
        let launchID = UUID()
        do {
            _ = try await f.console.startAgent(
                .init(kind: server.agentKind.rawValue, name: "review", launchID: launchID, mayHaveStarted: true),
                at: .newWorkspace(.init(directory: "/requested/alias", label: nil)),
                on: host.id, backend: server.backend, retriesLinkFailure: false)
            Issue.record("An uncertain terminal must not become Chat-only success")
        } catch {
            #expect(EventsSession.isTransportLinkFailure(error))
        }
        let nativeRequest = try #require(await f.native.workspaceStarts.first?.request)
        let terminalStart = try #require(await terminal.workspaceStarts.first)
        #expect(nativeRequest.launchID == launchID && nativeRequest.mayHaveStarted)
        #expect(terminalStart.request.launchID == launchID && terminalStart.request.mayHaveStarted)
        // The session's canonical folder, not the requested alias, owns its terminal.
        #expect(terminalStart.workspace.directory == "/work/app")
        #expect(f.console.serverLaunchNotices.isEmpty)
    }

    @Test(arguments: ServerChatBackend.allCases)
    func definitiveTerminalFailureLeavesEitherServerChatUsable(_ server: ServerChatBackend) async throws {
        let f = try await fixture(terminalBackends: [.tmux], server: server)
        defer { f.console.setHosts([]) }
        let terminal = try #require(f.terminals[.tmux])
        await terminal.setStartFailure(.apiRejected(code: "failed", message: "No terminal"))
        let session = try await f.console.startAgent(
            .init(kind: server.agentKind.rawValue, name: "review"),
            at: .newWorkspace(.init(directory: "/work/app", label: nil)),
            on: host.id, backend: server.backend)
        #expect(session.kind == server.agentKind.rawValue)
        let id = ConsoleAgent.ID(hostID: host.id, paneID: session.paneID)
        #expect(f.console.serverLaunchNotices[id] ==
            "Couldn't open a terminal for this \(server.sessionNoun). Chat still works.")
        #expect(await terminal.chatModeMarkerWrites.isEmpty)
    }

    @Test func aLinkMarkerDoesNotMakeThePaneAChatOrChangeItsTerminalResume() async throws {
        let pane = Agent(Self.agent("tmux:%1"))
        let marker = ChatModeMarker(
            paneID: pane.paneID, terminalID: pane.terminalID, kind: "codex", cwd: pane.cwd,
            session: .init(kind: "id", value: "thread"), chatMode: false, launchedAt: Date())
        let chat = ChatModeStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        chat.record(marker, hostID: host.id)
        let row = ConsoleAgent(hostID: host.id, hostName: host.displayName, agent: pane,
            workspaceLabel: nil, repositoryCheckout: nil, backend: .tmux)
        #expect(!chat.isChatMode(row))
        let record = ClosedSession.fixture(kind: .codex, session: .init(kind: .id, value: "thread"), backend: .tmux)
        let command = try await ClosedSessionResumer.launchCommand(
            for: record, chatOptions: .init(prompt: "Must not inject"), host: nil, hostName: "Host")
        let launch = try #require(ClosedSessionResumer.launch(
            for: record, workspaces: [], takenNames: [], command: command))
        #expect(launch.request.arguments == ["resume", "thread"])
        #expect(!launch.request.joinsCodexServer)
    }

    @Test func nativeClosedSessionResumesTheThreadWithoutChatPromptFiles() async throws {
        let record = ClosedSession.fixture(
            kind: .codex, session: .init(kind: .id, value: "thread"), backend: .codex)
        let calls = FormCalls()
        let resumer = ClosedSessionResumer(
            workspaces: { _ in [] }, existingAgentNames: { _ in [] },
            start: { request, destination, _, backend in
                #expect(backend == .codex)
                calls.requests.append(request)
                calls.destinations.append(destination)
                return Agent(Self.thread)
            }, awaitAgentVisible: { _ in }, beginPendingResume: { _, _, _ in
                Issue.record("Native threads have no disposable resume pane")
            }, recordChatMode: { marker, _ in calls.markers.append(marker) })
        #expect(record.canResume)
        #expect(await resumer.resume(record) == .started(.init(hostID: record.hostID, paneID: "codex:thread")))
        let request = try #require(calls.requests.first)
        #expect(request.codex == .init(resumeThreadID: "thread"))
        #expect(request.arguments.isEmpty && calls.markers.isEmpty)
    }
}
