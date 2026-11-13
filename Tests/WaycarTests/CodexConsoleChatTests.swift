import Foundation
import Testing

@testable import Waycar

@MainActor
@Suite("Codex Console and Chat")
struct CodexConsoleChatTests {
    nonisolated static var header: ChatTranscriptHeader {
        .init(kind: "codex", status: .ok, transcript: nil, activity: nil,
              turnOpen: false, truncated: false, error: nil)
    }

    static func thread(_ id: String, status: AgentStatus) -> AgentInfo {
        AgentInfo(
            agentStatus: status, focused: false, paneID: "codex:\(id)", revision: 1,
            tabID: "codex:\(id)", terminalID: "codex:\(id)", workspaceID: "codex:/work/app",
            agent: "codex",
            agentSession: AgentSessionInfo(agent: "codex", kind: .id, source: "codex", value: id),
            cwd: "/work/app", name: "Review \(id)")
    }

    static func fixture(threads: [AgentInfo], host: Host = .fixture()) -> (ConsoleStore, Host, ScriptedTransport) {
        let transport = ScriptedTransport(snapshot: .fixture(
            agents: threads, workspaces: [.fixture(workspaceID: "codex:/work/app", label: "app")]))
        let defaults = UserDefaults(suiteName: "codex-console-\(UUID())") ?? .standard
        let store = ConsoleStore(
            pins: PinnedAgentsStore(defaults: defaults),
            unread: UnreadAgentsStore(defaults: defaults),
            closedSessions: ClosedSessionsStore(),
            chatMode: ChatModeStore(defaults: defaults),
            rowLayouts: AgentRowLayoutStore(defaults: defaults),
            backendPreferences: HostBackendPreferences(defaults: defaults),
            makeSession: { _, backend, subscriptions in
                // Before detection the Console starts its legacy herdr lead.
                // Never let that temporary projection own Codex's transport.
                let owner = backend == .codex ? transport : ScriptedTransport()
                return EventsSession(subscriptions: subscriptions, connect: { owner }, keepalive: nil)
            },
            detectBackends: { _ in
                HostBackendPresence(
                    herdr: false, tmuxVersion: nil, ultimate: [],
                    codex: CodexPresence(version: "0.167.1", path: "/bin/codex", socketPath: "/tmp/codex.sock"))
            })
        return (store, host, transport)
    }

    @Test func projectsThreadsAndHonoursPersistedVisibility() async throws {
        let statuses: [AgentStatus] = [.working, .blocked, .done, .idle, .unknown]
        let (store, host, _) = Self.fixture(threads: statuses.enumerated().map {
            Self.thread("t\($0.offset)", status: $0.element)
        })
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil { store.verifiedAgents.count == statuses.count }
        for (index, status) in statuses.enumerated() {
            let row = try #require(store.agents.first { $0.agent.paneID == "codex:t\(index)" })
            #expect(row.agent.status == status)
            #expect(row.backend == .codex)
            #expect(store.isChatMode(row))
            #expect(!row.isUltimateLeader && row.ultimateChildren.isEmpty)
            #expect(!row.showsPluginProgressHint(
                summariesEnabled: true, pluginStatus: .outdated(installed: "1.0.0", required: "1.4.0")))
            #expect(AgentCardPresentation(agent: row, layout: .waycarDefault).caption == "codex · \(host.displayName)")
            #expect(AgentRowRenderer.value(for: .runtime, agent: row) == "Codex")
        }
        #expect(store.backendPreferences.showsServerChat(.codex, for: host.id))
        store.setShowsServerChat(false, .codex, for: host.id)
        try await waitUntil { store.agents.isEmpty }
        store.backendPreferences.reload()
        #expect(!store.backendPreferences.showsServerChat(.codex, for: host.id))
        store.setShowsServerChat(true, .codex, for: host.id)
        try await waitUntil { store.verifiedAgents.count == statuses.count }
    }

    @Test func stopAndStructuredAnswersReachTheOwningTransport() async throws {
        let (store, host, transport) = Self.fixture(threads: [Self.thread("t", status: .blocked)])
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil { store.verifiedAgents.count == 1 }
        let row = try #require(store.agents.first)
        let request = AgentPendingRequest(id: "approval-42", kind: .command(command: "make test", cwd: "/work/app", reason: nil))
        await transport.setPendingRequests([request])
        let transcript = store.makeChatTranscriptStore(for: row)
        transcript.start()
        defer { transcript.stop() }
        try await waitUntil { transcript.requests == [request] && transcript.canAnswerRequests }
        #expect(transcript.blockedScreen == nil)
        await transcript.answer(request, with: .allow)
        let answer = try #require(await transport.requestAnswers.first)
        #expect(answer.target == "codex:t" && answer.id == "approval-42" && answer.answer == .allow)
        #expect(transcript.requests.isEmpty)
        try await store.abortAgentRun("codex:t", on: host.id)
        #expect(await transport.abortedRuns == ["codex:t"])
    }

    @Test func requestsFollowBlockedStatusAndResolvedElsewhereDisappears() async throws {
        let (updates, continuation) = AsyncStream.makeStream(of: ConsoleStore.AgentStatusUpdate.self)
        let command = AgentPendingRequest(id: "42", kind: .command(command: "pwd", cwd: nil, reason: nil))
        var pending = [command]
        var answers: [AgentRequestAnswer] = []
        var reads = 0
        let store = ChatTranscriptStore(
            read: { _ in .init(header: Self.header, messages: []) },
            readScreen: { Issue.record("Structured requests must not read a screen"); return "" },
            sendKeys: { _ in Issue.record("Structured requests must not send keys") },
            initialStatus: .working,
            pendingRequests: { reads += 1; return pending },
            answerRequest: { id, answer in
                #expect(id == "42")
                answers.append(answer)
                pending = []
                throw TransportError.apiRejected(code: "agent_request_resolved", message: "Already answered")
            },
            statusUpdateSource: { updates })
        store.start()
        defer { store.stop() }
        #expect(reads == 0)
        continuation.yield(.init(status: .blocked, liveUpdatesAvailable: true))
        try await waitUntil { store.requests == [command] && store.canAnswerRequests }
        await store.answer(command, with: .cancel)
        try await waitUntil { store.requests.isEmpty && reads >= 2 }
        #expect(answers == [.cancel])
        #expect(!store.requestAnswerFailed)
        continuation.yield(.init(status: .working, liveUpdatesAvailable: true))
        try await waitUntil { store.status == .working }
        #expect(store.requests.isEmpty)
    }

    @Test func offlineRequestsCannotAnswerOrQueueAndQuestionsUseNativeAnswers() async throws {
        let (updates, continuation) = AsyncStream.makeStream(of: ConsoleStore.AgentStatusUpdate.self)
        let question = AgentPendingRequest(id: "q9", kind: .questions(.init(body: "", questions: [])))
        var sent: [(String, AgentRequestAnswer)] = []
        let store = ChatTranscriptStore(
            read: { _ in .init(header: Self.header, messages: []) },
            readScreen: { "" }, sendKeys: { _ in Issue.record("No keys") },
            queueAnswer: { _ in Issue.record("No Queued Answer") },
            initialStatus: .blocked,
            pendingRequests: { [question] },
            answerRequest: { sent.append(($0, $1)) },
            statusUpdateSource: { updates })
        store.start()
        defer { store.stop() }
        continuation.yield(.init(status: .blocked, liveUpdatesAvailable: true))
        try await waitUntil { store.canAnswerRequests && !store.requests.isEmpty }
        continuation.yield(.init(status: .blocked, liveUpdatesAvailable: false))
        try await waitUntil { !store.canAnswerRequests }
        await store.answer(question, with: .answers(["choice": ["Keep it"]]))
        #expect(sent.isEmpty && store.queuedAnswerLabel == nil)
        continuation.yield(.init(status: .blocked, liveUpdatesAvailable: true))
        try await waitUntil { store.canAnswerRequests }
        await store.answer(question, with: .answers(["choice": ["Keep it"]]))
        #expect(sent.count == 1 && sent.first?.0 == "q9")
        #expect(sent.first?.1 == .answers(["choice": ["Keep it"]]))
    }

    @Test func pushOpensCodexChatAndGlanceSurfacesIncludeThreads() async throws {
        let (store, host, _) = Self.fixture(threads: [Self.thread("thread-uuid", status: .working)])
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil { store.verifiedAgents.count == 1 }
        let row = try #require(store.agents.first)
        let router = AgentNotificationRouter()
        router.open(.init(hostID: host.id, paneID: "codex:thread-uuid"))
        router.agentsDidChange(store.agents)
        #expect(router.path == [row.id])
        #expect(store.isChatMode(row))
        let desire = try #require(AgentActivityContentBuilder.desire(from: store.agents, hostName: host.displayName))
        #expect(desire.counts.working == 1 && desire.agents.first?.paneID == "codex:thread-uuid")
        let watch = WatchStateBuilder.state(
            from: WatchStateSource(
                agents: store.verifiedAgents, hosts: [host], statuses: store.hostStatuses,
                awaitingSnapshot: [], chatModeAgents: [row.id], voiceTranscription: false),
            stamps: WatchStatusStamps(), now: .now)
        #expect(watch.rows.first?.id.paneID == "codex:thread-uuid")
        #expect(watch.rows.first?.isChatMode == true)
    }

    @Test func unloadOfAnUnnamedTurnlessThreadLeavesNoClosedSession() async throws {
        let empty = try #require(CodexThread(.object([
            "id": .string("empty"), "cwd": .string("/work/app"), "name": .null,
            "preview": .string(""), "ephemeral": .bool(false), "source": .string("vscode"),
            "status": .object(["type": .string("idle")])])))
        let (store, host, transport) = Self.fixture(threads: [empty.info, Self.thread("used", status: .idle)])
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil { store.verifiedAgents.count == 2 }
        await transport.setSnapshot(.fixture())
        #expect(await transport.emit(HerdrEvent(kind: GlobalEventKind.paneExited.kind, data: .object([:]))))
        try await waitUntil { store.verifiedAgents.isEmpty && store.closedSessions.sessions.count == 1 }
        #expect(store.closedSessions.sessions.map { $0.session?.value } == ["used"])
    }

    @Test func unloadCapturesCodexSessionAndResumesTheSameThread() async throws {
        let (store, host, transport) = Self.fixture(threads: [Self.thread("closed-id", status: .idle)])
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil { store.verifiedAgents.count == 1 }
        await transport.setSnapshot(.fixture())
        #expect(await transport.emit(HerdrEvent(kind: GlobalEventKind.paneExited.kind, data: .object([:]))))
        try await waitUntil { store.closedSessions.sessions.count == 1 }
        let record = try #require(store.closedSessions.sessions.first)
        #expect(record.backend == .codex && record.session?.value == "closed-id")
        #expect(record.chatMode && record.canResume)
        let resumed = Self.thread("closed-id", status: .idle)
        await transport.setStartedAgent(resumed)
        await transport.setSnapshot(.fixture(agents: [resumed]))
        let result = await ClosedSessionResumer(console: store).resume(record)
        #expect(result == .started(.init(hostID: host.id, paneID: "codex:closed-id")))
        #expect(await transport.agentStarts.isEmpty)
        let starts = await transport.workspaceStarts
        #expect(starts.count == 1 && starts.first?.0.codex?.resumeThreadID == "closed-id")
        #expect(await transport.chatModeMarkerWrites.isEmpty)
    }
}
