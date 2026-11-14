import Foundation
import Synchronization
import Testing

@testable import Waycar

/// OpenCode 2's user flows (`docs/design/opencode-backend.md`): New Agent's
/// minted session id through retries and the offline queue, Chat Mode's
/// model and Chat Prompt, one card per session, terminal launches on an
/// OpenCode 2 Host, Archive, and Closed Sessions from archived sessions.
@MainActor
@Suite("OpenCode flows", .timeLimit(.minutes(1)))
struct OpenCodeFlowsTests {
    private let host = Host.fixture()
    private typealias Wire = OpenCodeTransportTests

    private static let session = AgentInfo(
        agentStatus: .idle, focused: false, paneID: "opencode:ses_new", revision: 0,
        tabID: "opencode:ses_new", terminalID: "opencode:ses_new", workspaceID: "opencode:cwd:/work/app",
        agent: "opencode", cwd: "/work/app", name: "review")

    private final class Calls {
        var requests: [AgentLaunchRequest] = []
        var backends: [HostBackend?] = []
        var created: [AgentLaunchRequest] = []
        var messages: [String] = []
        var markers: [ChatModeMarker] = []
        var failNext: TransportError?
        /// The phone lost its connection: the next Start queues.
        var offline = false
    }

    private static let v2 = HostBackendPresence(
        herdr: true, tmuxVersion: "3.4", ultimate: [], opencode: OpenCodeConsoleChatTests.running)
    private static let v1 = HostBackendPresence(herdr: true, tmuxVersion: "3.4", ultimate: [])

    private func form(
        calls: Calls, presence: HostBackendPresence = Self.v2, live: Bool = true,
        origin: StartAgentStore.LaunchOrigin? = nil, queue: StartAgentStore.LaunchQueue? = nil,
        kinds: [SupportedAgentKind] = [], opencode transport: OpenCodeTransport? = nil
    ) -> StartAgentStore {
        StartAgentStore(
            hosts: [host], workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "app")] },
            existingAgentNames: { _ in [] }, discoverAgentKinds: { _ in kinds },
            remoteHome: { _ in "/home/test" },
            start: { request, destination, _, backend in
                calls.requests.append(request)
                calls.backends.append(backend)
                if let failure = calls.failNext {
                    calls.failNext = nil
                    throw failure
                }
                // A real transport on a fake server, where a test needs one.
                if let transport, backend == .opencode, case .newWorkspace(let workspace) = destination {
                    return try await transport.startAgentInNewWorkspace(request, workspace: workspace)
                }
                return request.kind == "opencode" && backend == .opencode
                    ? Agent(Self.session) : Agent(.fixture(paneID: "w1:p9", status: .idle, kind: request.kind))
            },
            backends: { _ in [.herdr, .tmux, .opencode] },
            serverRuntimeState: { _, server in server == .opencode ? .running : .notInstalled },
            createServerSession: { request, _ in
                calls.created.append(request)
                return Agent(Self.session)
            },
            awaitAgentVisible: { _ in }, origin: origin,
            selections: RecentSelectionsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            recordChatMode: { marker, _ in calls.markers.append(marker) },
            chatOptions: { _ in .init(prompt: "Short\n replies.", model: "mock/mock-model", quickThinking: true) },
            queueFirstMessage: { message, _, _, _ in calls.messages.append(message.text); return true },
            launchQueue: queue, hasLiveSnapshot: { _ in live && !calls.offline },
            backendPresence: { _ in presence })
    }

    // MARK: New Agent › OpenCode: one id per launch

    @Test(arguments: [true, false])
    func newAgentSendsTheMintedIDModelAndChatPrompt(chat: Bool) async throws {
        let calls = Calls()
        let store = form(calls: calls)
        store.selectNewWorkspace()
        store.newWorkspaceBackend = .opencode
        store.newWorkspaceDirectory = "/work/app"
        store.name = "review"
        store.chatMode = chat
        store.firstMessageText = "Hello"
        await store.submit()
        let request = try #require(calls.requests.first)
        #expect(calls.backends == [.opencode] && request.kind == "opencode")
        let id = try #require(request.opencode?.sessionID)
        #expect(id.wholeMatch(of: /ses_[0-9a-f]{12}[0-9A-Za-z]{14}/) != nil)
        #expect(request.opencode == .init(
            sessionID: id, model: chat ? "mock/mock-model" : nil, instructions: chat ? "Short replies." : nil))
        #expect(request.arguments.isEmpty && calls.markers.isEmpty)
        // The first message reaches the session once, through its Composer.
        #expect(calls.messages == ["Hello"])
    }

    @Test func aLostAnswerQueuesTheLaunchWithItsIDAndEveryRetryReusesIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let saved = QueuedLaunchStore(directory: directory)
        var queued: QueuedLaunch?
        let calls = Calls()
        calls.failNext = .sshUnreachable(detail: "lost")
        let store = form(calls: calls, queue: .init(store: saved, enqueue: {
            queued = $0
            try saved.save($0)
        }))
        store.selectNewWorkspace()
        store.newWorkspaceBackend = .opencode
        store.newWorkspaceDirectory = "/work/app"
        store.name = "review"
        store.chatMode = false
        store.firstMessageText = "First"
        await store.submit()
        let first = try #require(calls.requests.first?.opencode?.sessionID)
        let launch = try #require(queued)
        #expect(launch.mayHaveStarted == true)
        // The id is on disk with the Queued Launch: an app kill keeps it.
        let restored = try #require(saved.launches(on: host.id).first)
        #expect(restored.draft.opencodeSessionID == first)
        #expect(calls.messages.isEmpty)
        let replay = form(calls: calls)
        let prepared = replay.prepareLaunchDraft(restored.draft)
        #expect(prepared.opencodeSessionID == first)
        _ = await replay.launch(prepared, mayHaveStarted: true)
        let retry = try #require(calls.requests.last)
        #expect(retry.opencode?.sessionID == first && retry.mayHaveStarted && retry.launchID == launch.id)
        #expect(calls.messages == ["First"])
    }

    @Test func anOfflineLaunchMintsItsIDOnceBeforeItsFirstTry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let saved = QueuedLaunchStore(directory: directory)
        var queued: QueuedLaunch?
        let calls = Calls()
        let store = form(calls: calls, live: false, queue: .init(store: saved, enqueue: {
            queued = $0
            try saved.save($0)
        }))
        store.selectNewWorkspace()
        store.newWorkspaceBackend = .opencode
        store.newWorkspaceDirectory = "/work/app"
        store.chatMode = false
        await store.submit()
        let launch = try #require(queued)
        #expect(calls.requests.isEmpty)
        let replay = form(calls: calls)
        let prepared = replay.prepareLaunchDraft(launch.draft)
        let id = try #require(prepared.opencodeSessionID)
        // Preparing again (a later replay of the saved, prepared draft) keeps it.
        #expect(replay.prepareLaunchDraft(prepared).opencodeSessionID == id)
        var starting = launch
        starting.draft = prepared
        try saved.save(starting)
        #expect(saved.launches(on: host.id).first?.draft.opencodeSessionID == id)
        _ = await replay.launch(prepared)
        _ = await replay.launch(prepared, mayHaveStarted: true)
        #expect(calls.requests.map(\.opencode?.sessionID) == [id, id])
    }

    /// B-40 (Mike's rule: never make the user think about a retry, no
    /// duplicates): the create answered, the Chat Prompt write did not. The
    /// form's Retry finishes that same session instead of minting another.
    @Test func aRetryAfterAFailedChatPromptWriteFinishesTheSameSession() async throws {
        let created = Mutex<[String: JSONValue]>([:])
        let puts = Mutex(0)
        let (transport, server, _) = try await Wire.open(Wire.handler(
            sessions: { created.withLock { Array($0.values) } }, extra: { request in
                switch (request.method, request.route) {
                case ("POST", "/api/session"):
                    let id = request.body?["id"]?.stringValue ?? ""
                    // Repeating a create returns the session it made (O11).
                    let session = created.withLock { sessions in
                        if sessions[id] == nil {
                            sessions[id] = Wire.session(id, dir: "/work/app", title: "review",
                                extra: ["metadata": request.body?["metadata"] ?? .null])
                        }
                        return sessions[id] ?? .null
                    }
                    return .json(.object(["data": session]))
                case ("PUT", _):
                    let attempt = puts.withLock { count in
                        count += 1
                        return count
                    }
                    return attempt == 1
                        ? OpenCodeFakeResponse(status: 500, body: #"{"_tag":"InternalError","message":"boom"}"#)
                        : OpenCodeFakeResponse(status: 204, body: nil)
                default: return nil
                }
            }))
        let calls = Calls()
        let store = form(calls: calls, opencode: transport)
        store.selectNewWorkspace()
        store.newWorkspaceBackend = .opencode
        store.newWorkspaceDirectory = "/work/app"
        store.name = "review"
        store.chatMode = true
        await store.submit()
        guard case .failed = store.state else {
            Issue.record("expected the failed Chat Prompt write to fail the launch, got \(store.state)")
            return
        }
        let id = try #require(calls.requests.first?.opencode?.sessionID)
        // Retry.
        await store.submit()
        #expect(calls.requests.map(\.opencode?.sessionID) == [id, id])
        #expect(Set(await server.requests("POST", "/api/session").compactMap { $0.body?["id"]?.stringValue }) == [id])
        #expect(await server.requests(
            "PUT", "/api/experimental/session/\(id)/instructions/entries/waycar-chat-prompt").count == 2)
        #expect(try await transport.sessionSnapshot().agents.map(\.paneID) == ["opencode:\(id)"])
        guard case .started = store.state else {
            Issue.record("expected the Retry to start the session, got \(store.state)")
            return
        }
        // Started: the next Start is a new launch with a new session.
        await store.submit()
        #expect(calls.requests.last?.opencode?.sessionID != id)
        try await transport.close()
    }

    /// Review 177084 round 2: the Chat Prompt write failed, then the phone
    /// went offline, so Retry queues. The Queued Launch carries the same
    /// session id and name, and its replay finishes that session.
    @Test func anOfflineRetryAfterAFailedChatPromptWriteQueuesTheSameSession() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let saved = QueuedLaunchStore(directory: directory)
        let created = Mutex<[String: JSONValue]>([:])
        let puts = Mutex(0)
        let (transport, server, _) = try await Wire.open(Wire.handler(
            sessions: { created.withLock { Array($0.values) } }, extra: { request in
                switch (request.method, request.route) {
                case ("POST", "/api/session"):
                    let id = request.body?["id"]?.stringValue ?? ""
                    let session = created.withLock { sessions in
                        if sessions[id] == nil {
                            sessions[id] = Wire.session(id, dir: "/work/app", title: "review",
                                extra: ["metadata": request.body?["metadata"] ?? .null])
                        }
                        return sessions[id] ?? .null
                    }
                    return .json(.object(["data": session]))
                case ("PUT", _):
                    let attempt = puts.withLock { count in
                        count += 1
                        return count
                    }
                    return attempt == 1
                        ? OpenCodeFakeResponse(status: 500, body: #"{"_tag":"InternalError","message":"boom"}"#)
                        : OpenCodeFakeResponse(status: 204, body: nil)
                default: return nil
                }
            }))
        let calls = Calls()
        var queued: QueuedLaunch?
        let store = form(calls: calls, queue: .init(store: saved, enqueue: {
            queued = $0
            try saved.save($0)
        }), opencode: transport)
        store.selectNewWorkspace()
        store.newWorkspaceBackend = .opencode
        store.newWorkspaceDirectory = "/work/app"
        store.name = "review"
        store.chatMode = true
        await store.submit()
        guard case .failed = store.state else {
            Issue.record("expected the failed Chat Prompt write to fail the launch, got \(store.state)")
            return
        }
        let first = try #require(calls.requests.first)
        let id = try #require(first.opencode?.sessionID)
        // Retry with no connection: kept on the device, nothing sent.
        calls.offline = true
        await store.submit()
        let launch = try #require(queued)
        #expect(store.state == .queued(launch.id))
        #expect(calls.requests.count == 1)
        let restored = try #require(saved.launches(on: host.id).first)
        #expect(restored.draft.opencodeSessionID == id)
        #expect(restored.draft.launchName == first.name)
        // Reconnected: the Console replays it.
        let replay = form(calls: calls, opencode: transport)
        let prepared = replay.prepareLaunchDraft(restored.draft)
        _ = await replay.launch(prepared, mayHaveStarted: restored.mayHaveStarted == true)
        #expect(calls.requests.map(\.opencode?.sessionID) == [id, id])
        #expect(Set(await server.requests("POST", "/api/session").compactMap { $0.body?["id"]?.stringValue }) == [id])
        #expect(await server.requests(
            "PUT", "/api/experimental/session/\(id)/instructions/entries/waycar-chat-prompt").count == 2)
        #expect(try await transport.sessionSnapshot().agents.map(\.paneID) == ["opencode:\(id)"])
        try await transport.close()
    }

    /// B-40's queued half: a Queued Launch whose replay lost its answer
    /// replays the same session on the next connection.
    @Test func aQueuedReplayWhoseAnswerIsLostKeepsItsSessionID() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let launches = QueuedLaunchStore(directory: directory.appendingPathComponent("launches"))
        let transport = ScriptedTransport(snapshot: .fixture(
            workspaces: [.fixture(workspaceID: "opencode:cwd:/work/app", label: "app")]))
        await transport.setStartedAgent(OpenCodeConsoleChatTests.session("ses_new", status: .idle))
        await transport.setStartFailure(.sshUnreachable(detail: "The link dropped."))
        let reconnect = ScriptedTransportCallGate()
        let defaults = UserDefaults(suiteName: "opencode-queued-\(UUID())") ?? .standard
        let console = ConsoleStore(
            pins: PinnedAgentsStore(defaults: defaults), unread: UnreadAgentsStore(defaults: defaults),
            closedSessions: ClosedSessionsStore(), chatMode: ChatModeStore(defaults: defaults),
            rowLayouts: AgentRowLayoutStore(defaults: defaults),
            backendPreferences: HostBackendPreferences(defaults: defaults),
            queuedMessages: QueuedMessageStore(directory: directory.appendingPathComponent("messages")),
            queuedLaunches: launches,
            makeSession: { _, backend, subscriptions in
                let owner = backend == .opencode ? transport : ScriptedTransport()
                return EventsSession(subscriptions: subscriptions, connect: {
                    if backend == .opencode, await !transport.workspaceStarts.isEmpty {
                        await reconnect.waitUntilOpen()
                    }
                    return owner
                }, keepalive: nil)
            },
            detectBackends: { _ in
                HostBackendPresence(herdr: false, tmuxVersion: nil, ultimate: [], opencode: OpenCodeConsoleChatTests.running)
            })
        defer { console.setHosts([]) }
        let draft = LaunchDraft(
            id: UUID(), hostID: host.id,
            dispatch: .init(destination: .newWorkspace(NewWorkspaceSpec(directory: "/work/app", label: nil)),
                            launch: .agent(.opencode), backend: .opencode),
            workspaceID: nil, originCwd: nil, name: "review", suggestedName: nil, userArguments: [],
            chatMode: false, presetFirstMessage: nil, firstMessage: nil, remembersLaunch: true, isQuickChat: false)
        try launches.save(QueuedLaunch(draft: draft, state: .waiting, createdAt: Date()))
        console.setHosts([host])
        await console.resume()
        await reconnect.waitForEntry()
        try await waitUntil("the lost answer returns the launch to waiting") {
            console.queuedLaunches.map(\.state) == [.waiting]
                && launches.launches(on: host.id).first?.mayHaveStarted == true
        }
        let first = try #require(await transport.workspaceStarts.first?.request.opencode?.sessionID)
        #expect(launches.launches(on: host.id).first?.draft.opencodeSessionID == first)
        await transport.setStartFailure(nil)
        await transport.setSnapshot(.fixture(
            agents: [OpenCodeConsoleChatTests.session("ses_new", status: .idle)],
            workspaces: [.fixture(workspaceID: "opencode:cwd:/work/app", label: "app")]))
        await reconnect.open()
        try await waitUntil("the next connection replays it") {
            await transport.workspaceStarts.count == 2 && console.queuedLaunches.isEmpty
        }
        let requests = await transport.workspaceStarts.map(\.request)
        #expect(requests.map(\.opencode?.sessionID) == [first, first])
        #expect(requests.map(\.mayHaveStarted) == [false, true])
        #expect(requests.map(\.launchID) == [draft.id, draft.id])
    }

    @Test func theTransportCreatesOneSessionForEveryTryAndPutsTheChatPrompt() async throws {
        let created = Mutex<JSONValue?>(nil)
        let (transport, server, _) = try await Wire.open(Wire.handler(sessions: { [] }, extra: { request in
            switch (request.method, request.route) {
            case ("POST", "/api/session"):
                let id = request.body?["id"]?.stringValue ?? ""
                let session = created.withLock { value in
                    if value == nil {
                        value = Wire.session(id, dir: "/work/app", title: "review",
                            extra: ["metadata": request.body?["metadata"] ?? .null])
                    }
                    return value ?? .null
                }
                return .json(.object(["data": session]))
            case ("PUT", _): return OpenCodeFakeResponse(status: 204, body: nil)
            default: return nil
            }
        }))
        let id = OpenCodeSessionID.mint()
        let options = OpenCodeLaunchOptions(sessionID: id, model: "mock/mock-model", instructions: "Short replies.")
        for mayHaveStarted in [false, true] {
            let agent = try await transport.startAgent(AgentLaunchRequest(
                kind: "opencode", name: "review", cwd: "/work/app", launchID: UUID(),
                mayHaveStarted: mayHaveStarted, opencode: options))
            #expect(agent.paneID == "opencode:\(id)")
        }
        let creates = await server.requests("POST", "/api/session")
        #expect(creates.count == 2 && creates.allSatisfy { $0.body?["id"]?.stringValue == id })
        #expect(creates.first?.body?["model"] == .object(["id": .string("mock-model"), "providerID": .string("mock")]))
        let puts = await server.requests(
            "PUT", "/api/experimental/session/\(id)/instructions/entries/waycar-chat-prompt")
        #expect(puts.count == 2 && puts.allSatisfy { $0.body == .object(["value": .string("Short replies.")]) })
        #expect(try await transport.sessionSnapshot().agents.map(\.paneID) == ["opencode:\(id)"])
        // A retry that lost its minted id must not create another session.
        await #expect(throws: TransportError.self) {
            try await transport.startAgent(AgentLaunchRequest(
                kind: "opencode", name: "x", cwd: "/work/app", mayHaveStarted: true))
        }
        #expect(await server.requests("POST", "/api/session").count == 2)
        // A Waycar session is never a desk session for the folder link.
        #expect(await transport.serverSessionLinkFacts().sessionOrigins == [id: "waycar"])
        try await transport.close()
    }

    // MARK: Terminal launches on an OpenCode 2 Host

    @Test func anOpenCode2TerminalLaunchJoinsItsSessionWithoutTheModelFlag() async throws {
        let calls = Calls()
        let store = form(calls: calls, origin: .init(hostID: host.id, workspaceID: "w1", cwd: "/work/app"),
                         kinds: [.opencode])
        await store.discoverAgents()
        store.chatMode = true
        await store.submit()
        let pane = try #require(calls.requests.first)
        let created = try #require(calls.created.first)
        let id = try #require(created.opencode?.sessionID)
        #expect(!pane.arguments.contains("-m") && !pane.arguments.contains("mock/mock-model"))
        #expect(pane.arguments.starts(with: ["--session", id]))
        // Created first, as New Agent › OpenCode would, in the launch's folder.
        #expect(created.cwd == "/work/app" && created.name == pane.name)
        #expect(created.opencode == .init(sessionID: id, model: "mock/mock-model", instructions: "Short replies."))
        let marker = try #require(calls.markers.first)
        #expect(marker.session == .init(kind: "id", value: id) && marker.chatMode)
    }

    @Test func anOpenCode1TerminalLaunchStaysAsToday() async throws {
        let calls = Calls()
        let store = form(calls: calls, presence: Self.v1,
                         origin: .init(hostID: host.id, workspaceID: "w1", cwd: "/work/app"), kinds: [.opencode])
        await store.discoverAgents()
        store.chatMode = true
        await store.submit()
        let pane = try #require(calls.requests.first)
        #expect(pane.arguments == ["-m", "mock/mock-model"])
        #expect(calls.created.isEmpty)
        #expect(calls.markers.first?.session == nil)
    }

    @Test func theUsersOwnSessionArgumentsAreNotPinned() {
        for arguments in [["-s", "ses_x"], ["--session=ses_x"], ["-c"], ["--standalone"], ["run", "hi"]] {
            #expect(!StartAgentStore.mintsOpenCodeSession(backend: .tmux, opencode2: true, userArguments: arguments))
        }
        #expect(StartAgentStore.mintsOpenCodeSession(backend: .tmux, opencode2: true, userArguments: ["/work"]))
        #expect(StartAgentStore.mintsOpenCodeSession(backend: .core, opencode2: true, userArguments: []))
        #expect(!StartAgentStore.mintsOpenCodeSession(backend: .herdr, opencode2: false, userArguments: []))
        #expect(StartAgentStore.mintsOpenCodeSession(backend: .opencode, opencode2: false, userArguments: []))
    }

    // MARK: One card per session

    private func pane(
        _ id: String = "tmux:%1", cwd: String = "/work/app", line: String?, backend: HostBackend = .tmux
    ) -> ConsoleAgent {
        var row = ConsoleAgent(hostID: host.id, hostName: host.displayName,
            agent: Agent(terminalID: "term-\(id)", kind: "opencode", title: "OpenCode", status: .idle,
                workspaceID: "app", tabID: "tab-\(id)", paneID: id, cwd: cwd, revision: 1),
            workspaceLabel: "app", repositoryCheckout: nil, backend: backend)
        row.paneCommandLine = line
        return row
    }

    private func sessionRow(_ id: String, cwd: String = "/work/app", origin: String? = "user") -> ConsoleAgent {
        var row = ConsoleAgent(hostID: host.id, hostName: host.displayName,
            agent: Agent(terminalID: "opencode:\(id)", kind: "opencode", title: "Task", status: .idle,
                workspaceID: "opencode:cwd:\(cwd)", tabID: "opencode:\(id)", paneID: "opencode:\(id)",
                cwd: cwd, revision: 1),
            workspaceLabel: "app", repositoryCheckout: nil, backend: .opencode)
        row.serverSessionOrigin = origin
        return row
    }

    @Test(arguments: [
        "opencode --session ses_b", "/home/me/.opencode/bin/opencode -s ses_b", "opencode --session=ses_b /work/app",
    ])
    func aCommandLineNamingTheSessionLinksIt(line: String) {
        let pane = pane(cwd: "/elsewhere", line: line)
        let merged = ServerSessionLinks.merge(
            [pane, sessionRow("ses_a"), sessionRow("ses_b", origin: "waycar")]) { _ in nil }
        #expect(merged.count == 2)
        #expect(merged.first { $0.agent.paneID == "opencode:ses_b" }?.linkedTerminal?.id == pane.id)
        #expect(merged.first { $0.agent.paneID == "opencode:ses_a" }?.linkedTerminal == nil)
    }

    @Test func aPlainTUILinksOneToOneByFolderToADeskSessionOnly() {
        let linked = ServerSessionLinks.merge([pane(line: "opencode"), sessionRow("ses_a")]) { _ in nil }
        #expect(linked.count == 1 && linked.first?.linkedTerminal != nil)
        // Only that link is the folder rule's, which Archive pins first.
        let byFolder = ServerSessionLinks.resolve([pane(line: "opencode"), sessionRow("ses_a")]) { _ in nil }
        #expect(byFolder.linkedByFolder == [sessionRow("ses_a").id])
        let named = ServerSessionLinks.resolve(
            [pane(line: "opencode --session ses_a"), sessionRow("ses_a")]) { _ in nil }
        #expect(named.terminals.count == 1 && named.linkedByFolder.isEmpty)
        // A pane its marker pins to another session, even one no longer
        // listed, is never linked by folder, so Archive never re-pins it.
        let plain = pane(line: "opencode")
        let pin = ChatModeMarker(paneID: plain.agent.paneID, terminalID: plain.agent.terminalID, kind: "opencode",
            cwd: "/work/app", session: .init(kind: "id", value: "ses_old"), chatMode: false, launchedAt: .now)
        let pinned = ServerSessionLinks.resolve([plain, sessionRow("ses_new")]) { _ in pin }
        #expect(pinned.rows.count == 2 && pinned.linkedByFolder.isEmpty)
        // Never a Waycar-tagged session, and never two candidates.
        let tagged = ServerSessionLinks.merge(
            [pane(line: "opencode"), sessionRow("ses_a", origin: "waycar")]) { _ in nil }
        #expect(tagged.count == 2)
        let ambiguous = ServerSessionLinks.merge(
            [pane(line: "opencode"), sessionRow("ses_a"), sessionRow("ses_b")]) { _ in nil }
        #expect(ambiguous.count == 3)
        #expect(ServerSessionLinks.resolve(
            [pane(line: "opencode"), sessionRow("ses_a"), sessionRow("ses_b")]) { _ in nil }.linkedByFolder.isEmpty)
        // A private server, `--continue` or a subcommand proves nothing.
        for line in ["opencode --standalone", "opencode -c", "opencode run hi"] {
            #expect(ServerSessionLinks.merge([pane(line: line), sessionRow("ses_a")]) { _ in nil }.count == 2)
        }
    }

    @Test func aJoinedLaunchsChatMarkerLinksAHerdrPane() {
        let herdr = pane("w1:p1", line: nil, backend: .herdr)
        let marker = ChatModeMarker(paneID: "w1:p1", terminalID: herdr.agent.terminalID, kind: "opencode",
            cwd: "/work/app", session: .init(kind: "id", value: "ses_a"), chatMode: true, launchedAt: .now)
        let merged = ServerSessionLinks.merge([herdr, sessionRow("ses_a", origin: "waycar")]) { _ in marker }
        #expect(merged.count == 1 && merged.first?.linkedTerminal?.id == herdr.id)
    }

    // MARK: Archive

    @Test func onlyOpenCodeArchivesInsteadOfClosing() {
        #expect(HostBackend.opencode.archivesOnClose && HostBackend.opencode.closesRows)
        for backend in [HostBackend.herdr, .core, .tmux] {
            #expect(!backend.archivesOnClose && backend.closesRows)
        }
        #expect(!HostBackend.codex.archivesOnClose && !HostBackend.codex.closesRows)
        #expect(!HostBackend.ultimate.closesRows)
        func actions(archives: Bool) -> AgentComposerActions {
            AgentComposerActions(canAdd: true, addImage: {}, addFile: {}, openTerminal: nil,
                isOpeningTerminal: false, startAgent: {}, manageSnippets: {}, showSkills: nil,
                showWorktreeDetails: nil, renameAgent: {}, renameWorkspace: {}, markUnread: nil,
                closeAgent: {}, archivesAgent: archives)
        }
        #expect(AgentActionMenuPolicy.title(.closeAgent, actions: actions(archives: true)) == "Archive")
        #expect(AgentActionMenuPolicy.systemImage(.closeAgent, actions: actions(archives: true)) == "archivebox")
        #expect(AgentActionMenuPolicy.title(.closeAgent, actions: actions(archives: false)) == "Close Agent")
        #expect(AgentActionMenuPolicy.role(.closeAgent, actions: actions(archives: false)) == .destructive)
    }

    @Test func theRowsSwipeArchivesTheSession() async throws {
        let (store, host, transport) = OpenCodeConsoleChatTests.fixture(
            sessions: [OpenCodeConsoleChatTests.session("ses_a", status: .idle)])
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil { store.verifiedAgents.count == 1 }
        let row = try #require(store.agents.first)
        try await store.closeAgentTab(row)
        #expect(await transport.closedTabs == [TabTarget(tabID: "opencode:ses_a")])
    }

    @Test func aPaneSurelyLinkedToAnArchivedSessionStaysHidden() {
        let archived = [ConsoleScope(hostID: host.id, backend: .opencode): Set(["ses_a"])]
        let named = pane(line: "opencode --session ses_a")
        let resolved = ServerSessionLinks.resolve([named], archived: archived) { _ in nil }
        #expect(resolved.rows.isEmpty)
        #expect(resolved.terminals[.init(hostID: host.id, paneID: "opencode:ses_a")]?.id == named.id)
        // A herdr pane has no command line: its launch marker links it.
        let herdr = pane("w1:p1", line: nil, backend: .herdr)
        let marker = ChatModeMarker(paneID: "w1:p1", terminalID: herdr.agent.terminalID, kind: "opencode",
            cwd: "/work/app", session: .init(kind: "id", value: "ses_a"), chatMode: false, launchedAt: .now)
        #expect(ServerSessionLinks.merge([herdr], archived: archived) { _ in marker }.isEmpty)
        // The folder rule proves no link to an archived session.
        #expect(ServerSessionLinks.merge([pane(line: "opencode")], archived: archived) { _ in nil }.count == 1)
        #expect(ServerSessionLinks.merge([pane(line: "opencode --session ses_b")], archived: archived) { _ in nil }
            .count == 1)
    }

    /// A Host with tmux and OpenCode 2, whose desk pane in `/work/app` shows
    /// `ses_a`, and a swipe that closes without waiting out the undo window.
    private func linkedPaneFixture() -> (ConsoleStore, terminal: ScriptedTransport, opencode: ScriptedTransport) {
        let pane = AgentInfo.fixture(paneID: "tmux:%1", workspaceID: "app", kind: "opencode")
        let terminal = ScriptedTransport(snapshot: .fixture(agents: [pane]))
        let opencode = ScriptedTransport(snapshot: .fixture(
            agents: [OpenCodeConsoleChatTests.session("ses_a", status: .idle)],
            workspaces: [.fixture(workspaceID: "opencode:cwd:/work/app", label: "app")]))
        let defaults = UserDefaults(suiteName: "opencode-linked-\(UUID())") ?? .standard
        let store = ConsoleStore(
            pins: PinnedAgentsStore(defaults: defaults), unread: UnreadAgentsStore(defaults: defaults),
            closedSessions: ClosedSessionsStore(), chatMode: ChatModeStore(defaults: defaults),
            rowLayouts: AgentRowLayoutStore(defaults: defaults),
            backendPreferences: HostBackendPreferences(defaults: defaults),
            tabCloseUndoWindow: .init {},
            makeSession: { _, backend, subscriptions in
                let transport = backend == .opencode ? opencode : backend == .tmux ? terminal : ScriptedTransport()
                return EventsSession(subscriptions: subscriptions, connect: { transport }, keepalive: nil)
            },
            detectBackends: { _ in
                HostBackendPresence(herdr: false, tmuxVersion: "3.4", ultimate: [],
                    opencode: OpenCodeConsoleChatTests.running)
            })
        return (store, terminal, opencode)
    }

    /// The pane names the session on its command line, or (`byFolder`) is
    /// a plain desk TUI the folder rule links to the one desk session there
    /// (card 1611 2a): either hides with the archived session.
    @Test(arguments: [true, false], [false, true])
    func archiveKeepsTheLinkedPaneHiddenAndResumeReusesIt(paneSurvives: Bool, byFolder: Bool) async throws {
        let (store, terminal, opencode) = linkedPaneFixture()
        defer { store.setHosts([]) }
        let paneID = ConsoleAgent.ID(hostID: host.id, paneID: "tmux:%1")
        await terminal.setServerSessionLinkFacts(
            .init(commandLines: ["tmux:%1": byFolder ? "opencode" : "opencode --session ses_a"]))
        if byFolder {
            await opencode.setServerSessionLinkFacts(.init(sessionOrigins: ["ses_a": "user"]))
        }
        // The Host's first marker read lists no markers and lands only after
        // the archive, inside the pin's local grace, the way a loaded test
        // host can order it: it writes the pin again.
        let markerRead = ScriptedTransportCallGate()
        await terminal.gateNextChatModeMarkerRead(using: markerRead)
        store.setHosts([host])
        await store.resume()
        try await waitUntil { store.agents.count == 1 && store.agents.first?.linkedTerminal?.id == paneID }
        let row = try #require(store.agents.first)
        store.scheduleTabClose(row)
        try await waitUntil { await opencode.closedTabs == [TabTarget(tabID: "opencode:ses_a")] }
        // Archive pins a folder-linked pane to its session, on the Host too,
        // and never closes it.
        let pin = ChatModeMarker.Session(kind: "id", value: "ses_a")
        if byFolder {
            #expect(store.chatMode.marker(for: paneID)?.session == pin)
            #expect(store.chatMode.marker(for: paneID)?.chatMode == false)
            try await waitUntil { await terminal.chatModeMarkerWrites.first?.session == pin }
        } else {
            #expect(store.chatMode.marker(for: paneID) == nil)
        }
        await markerRead.waitForEntry()
        let writesBeforeRead = await terminal.chatModeMarkerWrites.count
        await markerRead.open()
        if byFolder {
            // A repair rewrites the same pin; nothing writes another marker.
            try await waitUntil { await terminal.chatModeMarkerWrites.count > writesBeforeRead }
            #expect(await terminal.chatModeMarkerWrites.allSatisfy { $0.session == pin })
        }
        #expect(await terminal.closedPanes.isEmpty)
        #expect(await terminal.closedTabs.isEmpty)
        // The server archived it; its TUI runs on.
        await opencode.setSnapshot(.fixture(workspaces: [.fixture(workspaceID: "opencode:cwd:/work/app", label: "app")]))
        await opencode.setArchivedServerSessions([ArchivedServerSession(
            sessionID: "ses_a", title: "Task", directory: "/work/app",
            workspaceID: "opencode:cwd:/work/app", archivedAt: Date())])
        #expect(await opencode.emit(HerdrEvent(kind: GlobalEventKind.paneExited.kind, data: .object([:]))))
        try await waitUntil { !store.closedSessions.listedSessions.isEmpty }
        #expect(!store.agents.contains { $0.id == paneID })
        #expect(store.listedAgent(paneID) != nil)
        if !paneSurvives {
            await terminal.setSnapshot(.fixture())
            #expect(await terminal.emit(HerdrEvent(kind: GlobalEventKind.paneExited.kind, data: .object([:]))))
            try await waitUntil { store.listedAgent(paneID) == nil }
            #expect(store.agents.isEmpty)
        }
        let record = try #require(store.closedSessions.listedSessions.first)
        await opencode.setStartedAgent(OpenCodeConsoleChatTests.session("ses_a", status: .idle))
        await opencode.setSnapshot(.fixture(
            agents: [OpenCodeConsoleChatTests.session("ses_a", status: .idle)],
            workspaces: [.fixture(workspaceID: "opencode:cwd:/work/app", label: "app")]))
        await opencode.setArchivedServerSessions([])
        let outcome = await ClosedSessionResumer(console: store).resume(record)
        #expect(outcome == .started(.init(hostID: host.id, paneID: "opencode:ses_a")))
        #expect(await opencode.workspaceStarts.map(\.request.opencode)
            == [OpenCodeLaunchOptions(resumeSessionID: "ses_a")])
        let panes = await terminal.workspaceStarts.map(\.request.arguments)
        if paneSurvives {
            // Unarchived into the pane that still shows it: no second pane.
            #expect(panes.isEmpty)
            try await waitUntil { store.agents.first?.linkedTerminal?.id == paneID }
            #expect(store.agents.count == 1)
        } else {
            #expect(panes == [["--session", "ses_a"]])
        }
    }

    @Test func theChatsArchiveIsTheSwipesCloseAndReturnsToTheConsole() async throws {
        let (store, _, opencode) = linkedPaneFixture()
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil { store.agents.contains { $0.backend == .opencode } }
        let row = try #require(store.agents.first { $0.backend == .opencode })
        var returned = false
        let archive = try #require(AgentDetailView.chatArchiveAction(for: row, console: store) { returned = true })
        archive()
        #expect(returned)
        try await waitUntil { await opencode.closedTabs == [TabTarget(tabID: "opencode:ses_a")] }
        // Only a Backend whose rows archive offers it in the chat.
        let terminalRow = try #require(store.agents.first { $0.backend == .tmux })
        #expect(AgentDetailView.chatArchiveAction(for: terminalRow, console: store) {} == nil)
        let codex = ConsoleAgent(hostID: host.id, hostName: host.displayName, agent: row.agent,
            workspaceLabel: nil, repositoryCheckout: nil, backend: .codex)
        #expect(AgentDetailView.chatArchiveAction(for: codex, console: store) {} == nil)
    }

    // MARK: Closed Sessions

    @Test func archivedSessionsAreListedAndFollowArchiveUnarchiveAndDelete() async throws {
        let archivedAt = 1_794_434_000_000.0
        let old = Wire.session("ses_old", dir: "/work/old", title: "Old", extra: ["time": .object([
            "created": .number(1), "updated": .number(1), "archived": .number(archivedAt)])])
        let (transport, server, _) = try await Wire.open(Wire.handler(
            sessions: { [Wire.session("ses_a")] },
            extra: { request in
                switch (request.method, request.route) {
                case ("GET", "/api/session") where request.query.contains("archived=true"):
                    return Wire.list([old], next: nil)
                case ("GET", "/api/session/ses_old"):
                    return .json(.object(["data": Wire.session("ses_old", dir: "/work/old", title: "Old")]))
                case ("PATCH", _): return OpenCodeFakeResponse(status: 204, body: nil)
                default: return nil
                }
            }))
        #expect(await server.requests("GET", "/api/session").contains {
            $0.query == "parentID=null&archived=true&limit=100&order=desc"
        })
        #expect(await transport.archivedServerSessions() == [ArchivedServerSession(
            sessionID: "ses_old", title: "Old", directory: "/work/old", workspaceID: "opencode:cwd:/work/old",
            archivedAt: Date(timeIntervalSince1970: archivedAt / 1000))])
        let stream = try await transport.subscribeToEvents([])
        // The swipe archives it: it leaves the inventory for Closed Sessions.
        try await transport.closeTab(TabTarget(tabID: "opencode:ses_a"))
        #expect(await server.requests("PATCH", "/api/session/ses_a").first?.body == .object(["archived": .bool(true)]))
        #expect(await transport.archivedServerSessions().map(\.sessionID) == ["ses_a", "ses_old"])
        #expect(try await transport.sessionSnapshot().agents.isEmpty)
        // Unarchived at the desk: listed again, no longer closed.
        await server.push("session.unarchived", ["sessionID": .string("ses_old")])
        try await waitUntil("unarchived is listed") {
            try await transport.sessionSnapshot().agents.map(\.paneID) == ["opencode:ses_old"]
        }
        #expect(await transport.archivedServerSessions().map(\.sessionID) == ["ses_a"])
        await server.push("session.deleted", ["sessionID": .string("ses_a")])
        try await waitUntil("deleted leaves Closed Sessions") { await transport.archivedServerSessions().isEmpty }
        await stream.end()
        try await transport.close()
    }

    @Test func closedSessionsListTheServersArchivedSessionsAndResumeUnarchives() async throws {
        let (store, host, transport) = OpenCodeConsoleChatTests.fixture(sessions: [])
        defer { store.setHosts([]) }
        let archived = ArchivedServerSession(
            sessionID: "ses_old", title: "Old task", directory: "/work/app",
            workspaceID: "opencode:cwd:/work/app", archivedAt: Date())
        await transport.setArchivedServerSessions([archived])
        await transport.setStartedAgent(OpenCodeConsoleChatTests.session("ses_old", status: .idle))
        store.setHosts([host])
        await store.resume()
        try await waitUntil { !store.closedSessions.listedSessions.isEmpty }
        let record = try #require(store.closedSessions.listedSessions.first)
        #expect(record.kind == .opencode && record.backend == .opencode && record.canResume)
        #expect(record.session == .init(kind: .id, value: "ses_old") && record.cwd == "/work/app")
        #expect(record.agentName == "Old task")
        // Nothing of it is kept on the device: the server is its record.
        #expect(store.closedSessions.sessions.isEmpty)
        let outcome = await ClosedSessionResumer(console: store).resume(record)
        #expect(outcome == .started(.init(hostID: host.id, paneID: "opencode:ses_old")))
        let resumed = try #require(await transport.workspaceStarts.first?.request)
        #expect(resumed.opencode == .init(resumeSessionID: "ses_old"))
        // A Forget hides it until it is archived again.
        await transport.setArchivedServerSessions([archived])
        store.closedSessions.forget(record.id)
        #expect(store.closedSessions.listedSessions.isEmpty)
    }
}
