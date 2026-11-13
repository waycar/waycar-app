import Foundation
import Testing

@testable import Waycar

@Suite("Codex transport", .timeLimit(.minutes(1)))
struct CodexTransportTests {
    private static let presence = CodexPresence(version: "0.167.1", path: "/bin/codex", socketPath: "/codex.sock", appServerVersion: "server-1")

    private func thread(_ id: String = "t", cwd: String = "/home/user/project", name: String? = nil,
                        status: String = "idle", flags: [String] = [], extra: [String: JSONValue] = [:]) -> JSONValue {
        .object([
            "id": .string(id), "cwd": .string(cwd), "name": name.map(JSONValue.string) ?? .null,
            "preview": .string("  First preview line  \nsecond line"), "parentThreadId": .null,
            "ephemeral": .bool(false), "source": .string("vscode"), "threadSource": .string("waycar"),
            "status": .object(["type": .string(status), "activeFlags": .array(flags.map(JSONValue.string))])
        ].merging(extra) { _, new in new })
    }

    private func fixture(_ pages: [[JSONValue]]? = nil) async throws -> (CodexTransport, CodexTestServer, FakeHostSSHServices) {
        let server = CodexTestServer()
        let session = FakeHostSSHServices(exec: { _, _ in FakeHostSSHServices.result(stdout: "/home/user\n") })
        let opening = Task { try await CodexTransport.open(session: session, presence: Self.presence, channel: server.channel) }
        let initialize = try await server.call("initialize")
        #expect(initialize["params"]?["clientInfo"]?["name"] == .string("waycar"))
        try await server.reply(initialize, .object([:]))
        let pages = pages ?? [[thread()]]
        for (index, page) in pages.enumerated() {
            let list = try await server.call("thread/loaded/list")
            #expect(list["params"]?["cursor"] == (index == 0 ? nil : .string("page-\(index)")))
            try await server.reply(list, .object([
                "data": .array(page.compactMap { $0["id"] }),
                "nextCursor": index + 1 < pages.count ? .string("page-\(index + 1)") : .null
            ]))
            for value in page {
                let read = try await server.call("thread/read")
                #expect(read["params"]?["includeTurns"] == nil)
                try await server.reply(read, .object(["thread": value]))
            }
        }
        return (try await opening.value, server, session)
    }

    private func transcriptRequest(after: String? = nil) -> ChatTranscriptRequest {
        ChatTranscriptRequest(paneID: "codex:t", kind: "codex", sessionKind: nil, sessionValue: nil,
                              cwd: nil, launchedAt: nil, status: nil, after: after)
    }

    private func turn(_ id: String, status: String = "completed", items: [JSONValue] = [], error: String? = nil) -> JSONValue {
        .object(["id": .string(id), "status": .string(status), "items": .array(items),
                 "startedAt": .number(100), "completedAt": .number(110),
                 "error": error.map { .object(["message": .string($0)]) } ?? .null])
    }

    @Test func inventoryEligibilityAndMapping() async throws {
        let (transport, server, _) = try await fixture([
            [thread("one", name: "Named"), thread("child", extra: ["parentThreadId": .string("one")]),
             thread("ephemeral", extra: ["ephemeral": .bool(true)]),
             thread("sub", extra: ["threadSource": .null, "source": .object(["subAgent": .string("review")])]),
             thread("sub-new", extra: ["threadSource": .string("subagent")])],
            [thread("home", cwd: FakeHostSSHServices.homeDirectory, extra: ["preview": .string("")]), thread("preview"),
             thread("unloaded", status: "notLoaded"), .object(["id": .string("bad")])]
        ])
        let snapshot = try await transport.sessionSnapshot()
        #expect(snapshot.agents.map(\.paneID) == ["codex:home", "codex:one", "codex:preview"])
        #expect(snapshot.agents.map(\.name) == ["Codex", "Named", "First preview line"])
        #expect(await transport.serverSessionLinkFacts().sessionOrigins == ["home": "waycar", "one": "waycar", "preview": "waycar"])
        #expect(snapshot.workspaces.count == 2)
        #expect(Set(snapshot.workspaces.map(\.label)) == ["~", "project"])
        for agent in snapshot.agents {
            #expect(agent.agent == "codex")
            #expect(agent.interactiveReady == true)
            #expect(agent.paneID == agent.tabID && agent.paneID == agent.terminalID)
        }
        #expect(try await transport.availableAgentKinds() == [.codex])
        let ping = Task { try await transport.ping() }
        try await server.reply(try await server.call("thread/loaded/list"), .object(["data": .array([])]))
        #expect(try await ping.value == ServerInfo(version: "server-1", protocolVersion: 0, backend: .codex))
        try await transport.close()
    }

    @Test func broadcastStatusDoneFocusAndInventoryChanges() async throws {
        let (transport, server, _) = try await fixture([[thread(extra: ["preview": .string("")])]])
        #expect(try await transport.sessionSnapshot().agents.first?.agentSession == nil)
        let stream = try await transport.subscribeToEvents([])
        var events = stream.events.makeAsyncIterator()
        for (status, expected) in [("active", AgentStatus.working), ("idle", .done)] {
            try await server.status(status)
            _ = try await events.next()
            #expect(try await transport.sessionSnapshot().agents.first?.agentStatus == expected)
            #expect(try await transport.sessionSnapshot().agents.first?.agentSession?.value == "t")
        }
        try await transport.focusAgent(AgentTarget(target: "codex:t"))
        _ = try await events.next()
        #expect(try await transport.sessionSnapshot().agents.first?.agentStatus == .idle)
        try await server.status("active")
        _ = try await events.next()
        try await server.status("idle")
        _ = try await events.next()
        try await server.status("active")
        _ = try await events.next()
        #expect(try await transport.sessionSnapshot().agents.first?.agentStatus == .working)
        try await server.status("systemError")
        _ = try await events.next()
        #expect(try await transport.sessionSnapshot().agents.first?.agentStatus == .unknown)
        try await server.notify("thread/name/updated", ["threadId": .string("t"), "threadName": .string("Desk name")])
        _ = try await events.next()
        #expect(try await transport.sessionSnapshot().agents.first?.name == "Desk name")
        try await server.notify("thread/started", ["thread": thread("new")])
        _ = try await events.next()
        #expect(try await transport.listAgents().count == 2)
        try await server.notify("thread/closed", ["threadId": .string("t")])
        _ = try await events.next()
        #expect(try await transport.sessionSnapshot().agents.map(\.paneID) == ["codex:new"])
        try await transport.close()
    }

    @Test func blockedResumesMapsRequestsAndAnswers() async throws {
        let (transport, server, _) = try await fixture()
        let stream = try await transport.subscribeToEvents([])
        var events = stream.events.makeAsyncIterator()
        try await server.status("active", flags: ["waitingOnApproval"])
        _ = try await events.next()
        #expect(try await transport.sessionSnapshot().agents.first?.agentStatus == .blocked)
        let resume = try await server.call("thread/resume")
        #expect(resume["params"] == .object(["threadId": .string("t"), "excludeTurns": .bool(true)]))
        // A real resume replays pending server requests before its response.
        try await server.serverRequest(1, "item/commandExecution/requestApproval", [
            "threadId": .string("t"), "command": .string("/bin/bash -lc 'ls'"),
            "cwd": .string("/project"), "reason": .string("Inspect files")])
        _ = try await events.next()
        try await server.reply(resume, .object(["thread": thread(status: "active", flags: ["waitingOnApproval"])]))
        #expect(try await transport.pendingAgentRequests(target: "codex:t") == [AgentPendingRequest(id: "1",
            kind: .command(command: "/bin/bash -lc 'ls'", cwd: "/project", reason: "Inspect files"))])
        try await transport.answerAgentRequest(target: "codex:t", requestID: "1", answer: .allow)
        #expect(try await server.response()["result"] == .object(["decision": .string("accept")]))
        _ = try await events.next()
        try await server.serverRequest(2, "item/fileChange/requestApproval", ["threadId": .string("t"), "reason": .string("Patch")])
        _ = try await events.next()
        #expect(try await transport.pendingAgentRequests(target: "codex:t").first?.kind == .fileChange(reason: "Patch", paths: []))
        try await transport.answerAgentRequest(target: "codex:t", requestID: "2", answer: .cancel)
        #expect(try await server.response()["result"] == .object(["decision": .string("cancel")]))
        _ = try await events.next()
        try await server.serverRequest(3, "item/tool/requestUserInput", ["threadId": .string("t"), "questions": .array([
            .object(["id": .string("q"), "question": .string("Which?"), "options": .array([
                .object(["label": .string("One"), "description": .string("First")]),
                .object(["label": .string("Two"), "description": .string("Second")])])])])])
        _ = try await events.next()
        #expect(try await transport.pendingAgentRequests(target: "codex:t").first?.kind == .questions(
            ChatQuestionCard(body: "", questions: [ChatQuestion(ref: "q", text: "Which?", kind: "choice", options: [
                ChatQuestionOption(key: "a", label: "One", detail: "First", recommended: false),
                ChatQuestionOption(key: "b", label: "Two", detail: "Second", recommended: false)])])))
        try await transport.answerAgentRequest(target: "codex:t", requestID: "3", answer: .answers(["q": ["Two"]]))
        #expect(try await server.response()["result"] == .object(["answers": .object(["q": .object(["answers": .array([.string("Two")])])])]))
        _ = try await events.next()
        // File details come from the matching item, not another item in the turn.
        try await server.serverRequest(4, "item/fileChange/requestApproval", [
            "threadId": .string("t"), "turnId": .string("run"), "itemId": .string("patch")])
        let full = try await server.call("thread/turns/list")
        #expect(full["params"] == .object([
            "threadId": .string("t"), "limit": .number(1), "itemsView": .string("full")]))
        try await server.reply(full, .object(["data": .array([turn("run", items: [
            .object(["id": .string("other"), "type": .string("fileChange"), "changes": .array([
                .object(["path": .string("not-this-file")])])]),
            .object(["id": .string("patch"), "type": .string("fileChange"), "changes": .array([
                .object(["path": .string("Sources/App.swift"), "kind": .object(["type": .string("update")])]),
                .object(["path": .string("Tests/AppTests.swift"), "kind": .object(["type": .string("add")])])])])])])]))
        _ = try await events.next()
        #expect(try await transport.pendingAgentRequests(target: "codex:t").first?.kind ==
            .fileChange(reason: nil, paths: ["Sources/App.swift", "Tests/AppTests.swift"]))
        try await transport.answerAgentRequest(target: "codex:t", requestID: "4", answer: .allow)
        #expect(try await server.response()["result"] == .object(["decision": .string("accept")]))
        _ = try await events.next()
        try await server.serverRequest(5, "item/commandExecution/requestApproval", ["threadId": .string("t")])
        _ = try await events.next()
        try await transport.answerAgentRequest(target: "codex:t", requestID: "5", answer: .cancel)
        #expect(try await server.response()["result"] == .object(["decision": .string("cancel")]))
        _ = try await events.next()
        try await transport.close()
    }

    @Test func cancelledQueuedApprovalKeepsTheRequestAndTheWriteQueueAlive() async throws {
        let (transport, server, _) = try await fixture()
        let stream = try await transport.subscribeToEvents([])
        var events = stream.events.makeAsyncIterator()
        try await server.serverRequest(1, "item/commandExecution/requestApproval", [
            "threadId": .string("t"), "command": .string("echo ok")])
        _ = try await events.next()
        await server.channel.blockNextWrite()
        let blocker = Task { try await transport.ping() }
        let ping = try await server.call("thread/loaded/list")
        let answer = Task {
            try await transport.answerAgentRequest(target: "codex:t", requestID: "1", answer: .allow)
        }
        answer.cancel()
        await server.channel.releaseWrite()
        await #expect(throws: TransportError.cancelled) { try await answer.value }
        try await server.reply(ping, .object(["data": .array([.string("t")])]))
        _ = try await blocker.value
        #expect(try await transport.pendingAgentRequests(target: "codex:t").map(\.id) == ["1"])
        try await transport.answerAgentRequest(target: "codex:t", requestID: "1", answer: .cancel)
        #expect(try await server.response()["result"] == .object(["decision": .string("cancel")]))
        #expect(try await transport.pendingAgentRequests(target: "codex:t").isEmpty)
        try await transport.close()
    }

    @Test func unreadableFileChangesCannotBeAllowedButCanBeCancelled() async throws {
        let (transport, server, _) = try await fixture()
        let stream = try await transport.subscribeToEvents([])
        var events = stream.events.makeAsyncIterator()
        try await server.serverRequest(1, "item/fileChange/requestApproval", [
            "threadId": .string("t"), "turnId": .string("run"), "itemId": .string("patch")])
        try await server.reject(try await server.call("thread/turns/list"), "unavailable")
        _ = try await events.next()
        #expect(try await transport.pendingAgentRequests(target: "codex:t").first?.kind == .fileChange(reason: nil, paths: []))
        await #expect(throws: TransportError.self) {
            try await transport.answerAgentRequest(target: "codex:t", requestID: "1", answer: .allow)
        }
        try await transport.answerAgentRequest(target: "codex:t", requestID: "1", answer: .cancel)
        #expect(try await server.response()["result"] == .object(["decision": .string("cancel")]))
        try await transport.close()
    }

    @Test func resolvedElsewhereAndLeavingBlockedDropPending() async throws {
        let (transport, server, _) = try await fixture()
        let stream = try await transport.subscribeToEvents([])
        var events = stream.events.makeAsyncIterator()
        try await server.status("active", flags: ["waitingOnUserInput"])
        _ = try await events.next()
        try await server.reply(try await server.call("thread/resume"), .object(["thread": thread()]))
        for id in [1, 2] {
            try await server.serverRequest(id, "future/request", ["threadId": .string("t")])
            _ = try await events.next()
        }
        #expect(try await transport.pendingAgentRequests(target: "codex:t").first?.kind == .unsupported(method: "future/request"))
        try await server.notify("serverRequest/resolved", ["threadId": .string("t"), "requestId": .number(1)])
        _ = try await events.next()
        #expect(try await transport.pendingAgentRequests(target: "codex:t").map(\.id) == ["2"])
        await #expect(throws: TransportError.apiRejected(code: "agent_request_resolved", message: "This request was already resolved.")) {
            try await transport.answerAgentRequest(target: "codex:t", requestID: "1", answer: .cancel)
        }
        try await server.status("active")
        _ = try await events.next()
        #expect(try await transport.pendingAgentRequests(target: "codex:t").isEmpty)
        // The next outbound call is ping: neither stale nor unsupported requests were answered.
        let ping = Task { try await transport.ping() }
        try await server.reply(try await server.call("thread/loaded/list"), .object(["data": .array([])]))
        _ = try await ping.value
        try await transport.close()
    }

    @Test func transcriptOrderFailureAndAfterCursor() async throws {
        let (transport, server, _) = try await fixture()
        let old = turn("old", items: [
            .object(["id": .string("u"), "type": .string("userMessage"), "content": .array([
                .object(["type": .string("text"), "text": .string("Hello")])])]),
            .object(["id": .string("narration"), "type": .string("agentMessage"), "phase": .string("commentary"), "text": .string("Thinking")]),
            .object(["id": .string("a"), "type": .string("agentMessage"), "text": .string("World")])])
        let failed = turn("fail", status: "failed", error: "Failed first line\nprivate details")
        for after in [nil, "u", "gone"] as [String?] {
            let reading = Task { try await transport.readChatTranscript(transcriptRequest(after: after)) }
            let first = try await server.call("thread/turns/list")
            #expect(first["params"]?["itemsView"] == nil)
            try await server.reply(first, .object(["data": .array([turn("open", status: "inProgress"), failed]), "nextCursor": .string("older")]))
            let second = try await server.call("thread/turns/list")
            #expect(second["params"]?["cursor"] == .string("older"))
            try await server.reply(second, .object(["data": .array([old]), "nextCursor": .null]))
            let snapshot = try await reading.value
            #expect(snapshot.header.kind == "codex" && snapshot.header.status == .ok)
            #expect(snapshot.header.turnOpen)
            #expect(snapshot.header.afterFound == (after != "gone"))
            #expect(snapshot.messages.map(\.id) == (after == "u" ? ["a", "fail:failure"] : ["u", "a", "fail:failure"]))
            #expect(snapshot.messages.last?.card == .failure(ChatFailureCard(conversationId: nil, title: nil, error: "Failed first line", step: nil)))
            #expect(snapshot.messages.first?.timestamp == Date(timeIntervalSince1970: after == "u" ? 110 : 100))
        }
        try await transport.close()
    }

    @Test func promptStartsSteersFallsBackAndInterrupts() async throws {
        let (transport, server, _) = try await fixture()
        let stream = try await transport.subscribeToEvents([])
        var events = stream.events.makeAsyncIterator()
        let first = Task { try await transport.promptAgent(AgentPromptParams(target: "codex:t", text: "First")) }
        try await server.reply(try await server.call("thread/resume"), .object(["thread": thread()]))
        let start = try await server.call("turn/start")
        #expect(start["params"]?["input"] == .array([.object(["type": .string("text"), "text": .string("First")])]))
        try await server.reply(start, .object(["turn": turn("run", status: "inProgress")]))
        _ = try await first.value
        try await server.notify("turn/started", ["threadId": .string("t"), "turn": turn("run", status: "inProgress")])
        try await server.status("active")
        _ = try await events.next()
        let steer = Task { try await transport.promptAgent(AgentPromptParams(target: "codex:t", text: "More")) }
        let steering = try await server.call("turn/steer")
        #expect(steering["params"]?["expectedTurnId"] == .string("run"))
        try await server.reply(steering, .object(["turnId": .string("run")]))
        _ = try await steer.value
        let stopping = Task { try await transport.abortAgentRun(target: "codex:t") }
        let interrupt = try await server.call("turn/interrupt")
        #expect(interrupt["params"] == .object(["threadId": .string("t"), "turnId": .string("run")]))
        try await server.reply(interrupt, .object([:]))
        try await stopping.value
        let raced = Task { try await transport.promptAgent(AgentPromptParams(target: "codex:t", text: "Next")) }
        try await server.reject(try await server.call("turn/steer"), "no active turn to steer")
        try await server.reply(try await server.call("thread/turns/list"), .object(["data": .array([turn("run")])]))
        try await server.reply(try await server.call("turn/start"), .object(["turn": turn("next", status: "inProgress")]))
        _ = try await raced.value
        try await server.notify("turn/completed", ["threadId": .string("t"), "turn": turn("next")])
        try await server.status("idle")
        _ = try await events.next()
        try await transport.abortAgentRun(target: "codex:t")
        try await transport.close()
    }

    @Test(arguments: [false, true])
    func unavailableTurnsListFallsBackToChronologicalReadHistory(afterPartialPage: Bool) async throws {
        let (transport, server, _) = try await fixture()
        let old = turn("old", items: [
            .object(["id": .string("u-old"), "type": .string("userMessage"),
                "content": .array([.object(["type": .string("text"), "text": .string("Old prompt")])])]),
            .object(["id": .string("a-old"), "type": .string("agentMessage"), "text": .string("Old reply")])])
        let new = turn("new", status: "failed", items: [
            .object(["id": .string("u-new"), "type": .string("userMessage"),
                "content": .array([.object(["type": .string("text"), "text": .string("New prompt")])])]),
            .object(["id": .string("a-new"), "type": .string("agentMessage"), "text": .string("New reply")])],
            error: "Failed turn")
        let reading = Task { try await transport.readChatTranscript(transcriptRequest(after: "u-old")) }
        if afterPartialPage {
            try await server.reply(try await server.call("thread/turns/list"), .object([
                "data": .array([new]), "nextCursor": .string("older")]))
        }
        try await server.reject(try await server.call("thread/turns/list"), "list_turns is not supported yet", code: -32601)
        let read = try await server.call("thread/read")
        #expect(read["params"] == .object(["threadId": .string("t"), "includeTurns": .bool(true)]))
        try await server.reply(read, .object(["thread": .object(["turns": .array([old, new])])]))
        let snapshot = try await reading.value
        #expect(snapshot.header.afterFound && !snapshot.header.truncated)
        #expect(snapshot.messages.map(\.id) == ["a-old", "u-new", "a-new", "new:failure"])
        #expect(snapshot.messages.map(\.text) == ["Old reply", "New prompt", "New reply", ""])
        try await transport.close()
    }

    @Test func readFallbackKeepsOnlyTheNewest200Turns() async throws {
        let (transport, server, _) = try await fixture()
        let reading = Task { try await transport.readChatTranscript(transcriptRequest()) }
        try await server.reject(try await server.call("thread/turns/list"), "unavailable")
        let values = (0...200).map { index in turn("t\(index)", items: [
            .object(["id": .string("a\(index)"), "type": .string("agentMessage"), "text": .string("reply \(index)")])]) }
        try await server.reply(try await server.call("thread/read"), .object([
            "thread": .object(["turns": .array(values)])]))
        let snapshot = try await reading.value
        #expect(snapshot.header.truncated && snapshot.messages.count == 200)
        #expect(snapshot.messages.first?.id == "a1" && snapshot.messages.last?.id == "a200")
        try await transport.close()
    }

    @Test func emptyTurnPagesStopAtThePageBudget() async throws {
        let (transport, server, _) = try await fixture()
        let reading = Task { try await transport.readChatTranscript(transcriptRequest()) }
        for page in 0..<4 {
            try await server.reply(try await server.call("thread/turns/list"), .object([
                "data": .array([]), "nextCursor": .string("page-\(page)")]))
        }
        let snapshot = try await reading.value
        #expect(snapshot.header.truncated && snapshot.messages.isEmpty)
        try await transport.close()
    }

    @Test func unknownActiveTurnIsReadBeforeSteering() async throws {
        let (transport, server, _) = try await fixture([[thread(status: "active")]])
        let sending = Task { try await transport.promptAgent(AgentPromptParams(target: "codex:t", text: "More")) }
        try await server.reply(try await server.call("thread/resume"), .object(["thread": thread(status: "active")]))
        let latest = try await server.call("thread/turns/list")
        #expect(latest["params"]?["limit"] == .number(1))
        try await server.reply(latest, .object(["data": .array([turn("desk", status: "inProgress")])]))
        let steer = try await server.call("turn/steer")
        #expect(steer["params"]?["expectedTurnId"] == .string("desk"))
        try await server.reply(steer, .object(["turnId": .string("desk")]))
        _ = try await sending.value
        try await transport.close()
    }

    @Test(arguments: [false, true])
    func launchNamesAndReconcilesLoadedNameDespiteCanonicalCwd(_ canonicalized: Bool) async throws {
        let (transport, server, _) = try await fixture([[]])
        let cwd = "/tmp/repo"
        let storedCwd = canonicalized ? "/private/tmp/repo" : cwd
        let launch = AgentLaunchRequest(kind: "codex", name: "launch-tag",
            codex: CodexLaunchOptions(developerInstructions: "Chat prompt", model: "model", reasoningEffort: "low"))
        let starting = Task { try await transport.startAgentInNewWorkspace(
            launch, workspace: .init(directory: cwd, label: nil)) }
        let start = try await server.call("thread/start")
        #expect(start["params"] == .object(["cwd": .string(cwd), "threadSource": .string("waycar"),
            "developerInstructions": .string("Chat prompt"),
            "model": .string("model"), "config": .object(["model_reasoning_effort": .string("low")])]))
        try await server.reply(start, .object(["thread": thread("created", cwd: storedCwd)]))
        let naming = try await server.call("thread/name/set")
        #expect(naming["params"] == .object(["threadId": .string("created"), "name": .string("launch-tag")]))
        try await server.reply(naming, .object([:]))
        #expect(try await starting.value.paneID == "codex:created")
        let reconciling = Task { try await transport.startAgent(AgentLaunchRequest(
            kind: "codex", name: "launch-tag", cwd: cwd, mayHaveStarted: true)) }
        try await server.reply(try await server.call("thread/loaded/list"), .object(["data": .array([.string("other"), .string("created")])]))
        // A matching folder wins even over a newer namesake, including
        // the canonical macOS alias of the requested folder.
        try await server.reply(try await server.call("thread/read"), .object(["thread": thread(
            "other", cwd: "/other", name: "launch-tag", extra: ["createdAt": .number(300)])]))
        try await server.reply(try await server.call("thread/read"), .object(["thread": thread(
            "created", cwd: storedCwd, name: "launch-tag", extra: ["createdAt": .number(200)])]))
        #expect(try await reconciling.value.paneID == "codex:created")
        try await transport.close()
    }

    @Test(arguments: ["/tmp/repo/", "/var/repo/"])
    func lostCreateBeforeNamingAdoptsNewestEmptyAPIThread(cwd: String) async throws {
        let (first, peer, _) = try await fixture([[]])
        let starting = Task { try await first.startAgent(.init(kind: "codex", name: "tag", cwd: cwd)) }
        let empty = thread("lost", cwd: "/private" + String(cwd.dropLast()), extra: [
            "preview": .string(""), "createdAt": .number(200)])
        try await peer.reply(try await peer.call("thread/start"), .object(["thread": empty]))
        _ = try await peer.call("thread/name/set")
        await peer.channel.feed(CodexMemoryChannel.serverFrame(opcode: 8, payload: Data()))
        await #expect(throws: TransportError.self) { _ = try await starting.value }
        try await first.close()

        let candidates = [
            thread("older", cwd: cwd, extra: ["preview": .string(""), "createdAt": .number(100)]),
            empty,
            thread("desk", cwd: cwd, extra: ["preview": .string(""), "threadSource": .string("user"), "createdAt": .number(300)]),
            thread("unknown", cwd: cwd, extra: ["preview": .string(""), "threadSource": .null, "createdAt": .number(350)]),
            thread("used", cwd: cwd, extra: ["createdAt": .number(400)]),
            thread("elsewhere", cwd: "/elsewhere", extra: ["preview": .string(""), "createdAt": .number(500)])]
        let (retry, server, _) = try await fixture([candidates])
        let replay = Task { try await retry.startAgent(.init(kind: "codex", name: "tag", cwd: cwd, mayHaveStarted: true)) }
        try await server.reply(try await server.call("thread/loaded/list"), .object([
            "data": .array(candidates.compactMap { $0["id"] })]))
        for value in candidates {
            try await server.reply(try await server.call("thread/read"), .object(["thread": value]))
        }
        let resume = try await server.call("thread/resume")
        #expect(resume["params"]?["threadId"] == .string("lost"))
        try await server.reply(resume, .object(["thread": empty]))
        let naming = try await server.call("thread/name/set")
        #expect(naming["params"] == .object(["threadId": .string("lost"), "name": .string("tag")]))
        try await server.reply(naming, .object([:]))
        #expect(try await replay.value.paneID == "codex:lost")
        // Every outbound method was consumed: no second thread/start.
        try await retry.close()
    }

    @Test(arguments: ["user", nil, "another-feature"] as [String?], [false, true])
    func deskOrUnknownThreadIsNeverAdopted(threadSource: String?, named: Bool) async throws {
        let desk = thread("desk", cwd: "/work", name: named ? "tag" : nil, extra: ["preview": .string(""),
            "threadSource": threadSource.map(JSONValue.string) ?? .null])
        let (transport, server, _) = try await fixture([[desk]])
        let starting = Task { try await transport.startAgent(.init(kind: "codex", name: "tag", cwd: "/work", mayHaveStarted: true)) }
        try await server.reply(try await server.call("thread/loaded/list"), .object(["data": .array([.string("desk")])]))
        try await server.reply(try await server.call("thread/read"), .object(["thread": desk]))
        try await server.reply(try await server.call("thread/start"), .object(["thread": thread("new", cwd: "/work")]))
        try await server.reply(try await server.call("thread/name/set"), .object([:]))
        #expect(try await starting.value.paneID == "codex:new")
        try await transport.close()
    }

    @Test func aTUIResumeIsDiscoveredFromItsFirstStatusWithoutThreadStarted() async throws {
        let (transport, server, _) = try await fixture([[]])
        let stream = try await transport.subscribeToEvents([])
        var events = stream.events.makeAsyncIterator()
        try await server.notify("thread/status/changed", ["threadId": .string("restored"),
            "status": .object(["type": .string("active"), "activeFlags": .array([])])])
        let read = try await server.call("thread/read")
        #expect(read["params"] == .object(["threadId": .string("restored")]))
        try await server.reply(read, .object(["thread": thread("restored", name: "Desk", status: "active")]))
        _ = try await events.next()
        #expect(try await transport.sessionSnapshot().agents.map(\.paneID) == ["codex:restored"])
        try await server.notify("thread/status/changed", ["threadId": .string("restored"),
            "status": .object(["type": .string("idle"), "activeFlags": .array([])])])
        _ = try await events.next() // No second thread/read or thread/resume.
        #expect(try await transport.sessionSnapshot().agents.first?.agentStatus == .done)
        try await transport.close()
    }

    @Test func closedThreadResumeListsItWithoutStartingOrRenamingAnother() async throws {
        let (transport, server, _) = try await fixture([[]])
        let resuming = Task { try await transport.startAgent(AgentLaunchRequest(
            kind: "codex", name: "unused", codex: .init(resumeThreadID: "closed"))) }
        let resume = try await server.call("thread/resume")
        #expect(resume["params"] == .object([
            "threadId": .string("closed"), "excludeTurns": .bool(true)]))
        try await server.reply(resume, .object(["thread": thread("closed", name: "Kept")]))
        #expect(try await resuming.value.paneID == "codex:closed")
        #expect(try await transport.sessionSnapshot().agents.first?.name == "Kept")
        try await transport.close()
    }

    @Test func connectionEndFailsEventsAndReleasesOnlyOnClose() async throws {
        let (transport, server, session) = try await fixture()
        let stream = try await transport.subscribeToEvents([])
        var events = stream.events.makeAsyncIterator()
        await server.channel.feed(CodexMemoryChannel.serverFrame(opcode: 8, payload: Data()))
        await #expect(throws: TransportError.self) { _ = try await events.next() }
        #expect(await transport.isConnected == false)
        #expect(await session.releaseCount == 0)
        try await transport.close()
        try await transport.close()
        #expect(await session.releaseCount == 1)
    }

    // MARK: Pins: transport lifetime (CODEX-01)

    @Test func distrustRefusesRequestsAndEndsEventsWithoutReleasing() async throws {
        let (transport, server, session) = try await fixture()
        let stream = try await transport.subscribeToEvents([])
        var events = stream.events.makeAsyncIterator()
        await transport.transportDistrusted()
        #expect(try await events.next() == nil)
        #expect(await transport.isConnected == false)
        #expect(await server.channel.closed)
        await #expect(throws: TransportError.cancelled) { _ = try await transport.sessionSnapshot() }
        await #expect(throws: TransportError.cancelled) { _ = try await transport.subscribeToEvents([]) }
        #expect(await session.releaseCount == 0)
        try await transport.close()
        try await transport.close()
        await transport.transportDistrusted()
        #expect(await session.releaseCount == 1)
    }

    @Test func aLostConnectionRefusesRequestsUntilDistrustOrClose() async throws {
        let (transport, server, session) = try await fixture()
        let stream = try await transport.subscribeToEvents([])
        var events = stream.events.makeAsyncIterator()
        let ended = TransportError.channelFailed(detail: "Codex ended its connection.")
        await server.channel.feed(CodexMemoryChannel.serverFrame(opcode: 8, payload: Data()))
        await #expect(throws: ended) { _ = try await events.next() }
        await #expect(throws: ended) { _ = try await transport.sessionSnapshot() }
        await #expect(throws: ended) { _ = try await transport.subscribeToEvents([]) }
        await transport.transportDistrusted()
        await #expect(throws: TransportError.cancelled) { _ = try await transport.sessionSnapshot() }
        #expect(await session.releaseCount == 0)
        try await transport.close()
        #expect(await session.releaseCount == 1)
    }

    @Test func aRefusedInitializeClosesTheChannelAndLeavesTheHoldWithTheCaller() async throws {
        let server = CodexTestServer()
        let session = FakeHostSSHServices(exec: { _, _ in FakeHostSSHServices.result(stdout: "/home/user\n") })
        let opening = Task { try await CodexTransport.open(session: session, presence: Self.presence, channel: server.channel) }
        try await server.reject(try await server.call("initialize"), "not now")
        await #expect(throws: TransportError.apiRejected(code: "-32600", message: "not now")) { _ = try await opening.value }
        #expect(await server.channel.closed)
        #expect(await session.releaseCount == 0)
    }

    // MARK: Pins: thread subscription (CODEX-03)

    @Test func aFailedResumeIsRetriedByTheNextNeed() async throws {
        let (transport, server, _) = try await fixture()
        let first = Task { try await transport.promptAgent(AgentPromptParams(target: "codex:t", text: "One")) }
        try await server.reject(try await server.call("thread/resume"), "busy")
        await #expect(throws: TransportError.apiRejected(code: "-32600", message: "busy")) { _ = try await first.value }
        let second = Task { try await transport.promptAgent(AgentPromptParams(target: "codex:t", text: "Two")) }
        try await server.reply(try await server.call("thread/resume"), .object(["thread": thread()]))
        try await server.reply(try await server.call("turn/start"), .object(["turn": turn("run", status: "inProgress")]))
        _ = try await second.value
        // Subscribed now: the next prompt resumes nothing.
        let third = Task { try await transport.promptAgent(AgentPromptParams(target: "codex:t", text: "Three")) }
        try await server.reply(try await server.call("turn/start"), .object(["turn": turn("next", status: "inProgress")]))
        _ = try await third.value
        try await transport.close()
    }

    @Test func concurrentNeedsShareOneResume() async throws {
        let (transport, server, _) = try await fixture()
        let first = Task { try await transport.promptAgent(AgentPromptParams(target: "codex:t", text: "One")) }
        let resume = try await server.call("thread/resume")
        let second = Task { try await transport.promptAgent(AgentPromptParams(target: "codex:t", text: "Two")) }
        try await server.reply(resume, .object(["thread": thread()]))
        for _ in 0..<2 {
            try await server.reply(try await server.call("turn/start"), .object(["turn": turn("run", status: "inProgress")]))
        }
        _ = try await first.value
        _ = try await second.value
        try await transport.close()
    }

    @Test func aTurnStartedWhileResumingIsTheOneSteered() async throws {
        let (transport, server, _) = try await fixture([[thread(status: "active")]])
        let stream = try await transport.subscribeToEvents([])
        var events = stream.events.makeAsyncIterator()
        let sending = Task { try await transport.promptAgent(AgentPromptParams(target: "codex:t", text: "More")) }
        let resume = try await server.call("thread/resume")
        try await server.notify("turn/started", ["threadId": .string("t"), "turn": turn("desk", status: "inProgress")])
        try await server.notify("thread/started", ["thread": thread("other")])
        _ = try await events.next()
        try await server.reply(resume, .object(["thread": thread(status: "active")]))
        // No newest-turn read: the turn the subscription saw start is steered.
        let steer = try await server.call("turn/steer")
        #expect(steer["params"]?["expectedTurnId"] == .string("desk"))
        try await server.reply(steer, .object(["turnId": .string("desk")]))
        _ = try await sending.value
        try await transport.close()
    }

    @Test func aResumeAnswerNeverOverwritesTheThreadAlreadyListed() async throws {
        let (transport, server, _) = try await fixture([[thread(name: "Listed")]])
        let sending = Task { try await transport.promptAgent(AgentPromptParams(target: "codex:t", text: "One")) }
        try await server.reply(try await server.call("thread/resume"), .object([
            "thread": thread(name: "Stale", status: "active")]))
        try await server.reply(try await server.call("turn/start"), .object(["turn": turn("run", status: "inProgress")]))
        _ = try await sending.value
        let agent = try await transport.sessionSnapshot().agents.first
        #expect(agent?.name == "Listed" && agent?.agentStatus == .idle)
        try await transport.close()
    }

    @Test func aThreadBlockedAtOpenIsResumedForItsRequests() async throws {
        let (transport, server, _) = try await fixture([[thread(status: "active", flags: ["waitingOnApproval"])]])
        let resume = try await server.call("thread/resume")
        #expect(resume["params"] == .object(["threadId": .string("t"), "excludeTurns": .bool(true)]))
        try await server.reply(resume, .object(["thread": thread(status: "active", flags: ["waitingOnApproval"])]))
        // Subscribed: Stop resumes nothing and reads the newest turn.
        let stopping = Task { try await transport.abortAgentRun(target: "codex:t") }
        try await server.reply(try await server.call("thread/turns/list"), .object([
            "data": .array([turn("run", status: "inProgress")])]))
        try await server.reply(try await server.call("turn/interrupt"), .object([:]))
        try await stopping.value
        try await transport.close()
    }

    @Test func aFailedResumeForABlockedThreadEndsTheConnection() async throws {
        let (transport, server, _) = try await fixture()
        let stream = try await transport.subscribeToEvents([])
        var events = stream.events.makeAsyncIterator()
        try await server.status("active", flags: ["waitingOnApproval"])
        _ = try await events.next()
        try await server.reject(try await server.call("thread/resume"), "gone")
        await #expect(throws: TransportError.channelFailed(detail: "Codex ended its connection.")) {
            _ = try await events.next()
        }
        #expect(await transport.isConnected == false)
        try await transport.close()
    }

    @Test func aClosedThreadIsResumedAgainWhenItComesBack() async throws {
        let (transport, server, _) = try await fixture()
        let stream = try await transport.subscribeToEvents([])
        var events = stream.events.makeAsyncIterator()
        let first = Task { try await transport.promptAgent(AgentPromptParams(target: "codex:t", text: "One")) }
        try await server.reply(try await server.call("thread/resume"), .object(["thread": thread()]))
        try await server.reply(try await server.call("turn/start"), .object(["turn": turn("run", status: "inProgress")]))
        _ = try await first.value
        try await server.notify("thread/closed", ["threadId": .string("t")])
        _ = try await events.next()
        try await server.notify("thread/started", ["thread": thread()])
        _ = try await events.next()
        let second = Task { try await transport.promptAgent(AgentPromptParams(target: "codex:t", text: "Two")) }
        try await server.reply(try await server.call("thread/resume"), .object(["thread": thread()]))
        try await server.reply(try await server.call("turn/start"), .object(["turn": turn("again", status: "inProgress")]))
        _ = try await second.value
        try await transport.close()
    }

    // MARK: Pins: thread activity and Done (CODEX-04)

    @Test func doneNeedsAnObservedTurnEndAndOutlastsOtherStatuses() async throws {
        let (transport, server, _) = try await fixture()
        let stream = try await transport.subscribeToEvents([])
        var events = stream.events.makeAsyncIterator()
        func status() async throws -> AgentStatus? { try await transport.sessionSnapshot().agents.first?.agentStatus }
        for (type, expected) in [("active", AgentStatus.working), ("systemError", .unknown), ("idle", .idle),
                                 ("active", .working), ("idle", .done), ("systemError", .unknown), ("idle", .done)] {
            try await server.status(type)
            _ = try await events.next()
            #expect(try await status() == expected, "after \(type)")
        }
        try await transport.focusAgent(AgentTarget(target: "codex:t"))
        _ = try await events.next()
        #expect(try await status() == .idle)
        try await transport.close()
    }

    @Test func aTurnStartGivesAnEmptyThreadItsSession() async throws {
        let (transport, server, _) = try await fixture([[thread(extra: ["preview": .string("")])]])
        let stream = try await transport.subscribeToEvents([])
        var events = stream.events.makeAsyncIterator()
        #expect(try await transport.sessionSnapshot().agents.first?.agentSession == nil)
        try await server.notify("turn/started", ["threadId": .string("t"), "turn": turn("run", status: "inProgress")])
        try await server.notify("thread/started", ["thread": thread("other")])
        _ = try await events.next()
        let agent = try await transport.sessionSnapshot().agents.first { $0.paneID == "codex:t" }
        #expect(agent?.agentSession?.value == "t" && agent?.agentStatus == .idle)
        try await transport.close()
    }

    // MARK: Pins: active turn and send routing (CODEX-05)

    @Test func stopReadsTheNewestTurnOnlyWhileActive() async throws {
        let (transport, server, _) = try await fixture([[thread(status: "active")]])
        let stream = try await transport.subscribeToEvents([])
        var events = stream.events.makeAsyncIterator()
        let stopping = Task { try await transport.abortAgentRun(target: "codex:t") }
        try await server.reply(try await server.call("thread/turns/list"), .object(["data": .array([turn("old")])]))
        try await stopping.value
        try await server.status("idle")
        _ = try await events.next()
        try await transport.abortAgentRun(target: "codex:t")
        // Neither Stop interrupted anything: the next outbound call is ping.
        let ping = Task { try await transport.ping() }
        try await server.reply(try await server.call("thread/loaded/list"), .object(["data": .array([])]))
        _ = try await ping.value
        try await transport.close()
    }

    @Test func aSteerRefusedWhileTheTurnStillRunsIsNotRetriedAsANewTurn() async throws {
        let (transport, server, _) = try await fixture([[thread(status: "active")]])
        let sending = Task { try await transport.promptAgent(AgentPromptParams(target: "codex:t", text: "More")) }
        try await server.reply(try await server.call("thread/resume"), .object(["thread": thread(status: "active")]))
        try await server.reply(try await server.call("thread/turns/list"), .object([
            "data": .array([turn("desk", status: "inProgress")])]))
        try await server.reject(try await server.call("turn/steer"), "policy")
        try await server.reply(try await server.call("thread/turns/list"), .object([
            "data": .array([turn("desk", status: "inProgress")])]))
        await #expect(throws: TransportError.apiRejected(code: "-32600", message: "policy")) { _ = try await sending.value }
        // The turn stays known: Stop interrupts it without another read.
        let stopping = Task { try await transport.abortAgentRun(target: "codex:t") }
        let interrupt = try await server.call("turn/interrupt")
        #expect(interrupt["params"] == .object(["threadId": .string("t"), "turnId": .string("desk")]))
        try await server.reply(interrupt, .object([:]))
        try await stopping.value
        try await transport.close()
    }

    @Test func anotherTurnsCompletionKeepsTheKnownTurnAndIdleForgetsIt() async throws {
        let (transport, server, _) = try await fixture([[thread(status: "active")]])
        let stream = try await transport.subscribeToEvents([])
        var events = stream.events.makeAsyncIterator()
        let sending = Task { try await transport.promptAgent(AgentPromptParams(target: "codex:t", text: "More")) }
        try await server.reply(try await server.call("thread/resume"), .object(["thread": thread(status: "active")]))
        try await server.reply(try await server.call("thread/turns/list"), .object([
            "data": .array([turn("run", status: "inProgress")])]))
        try await server.reply(try await server.call("turn/steer"), .object(["turnId": .string("run")]))
        _ = try await sending.value
        try await server.notify("turn/completed", ["threadId": .string("t"), "turn": turn("other")])
        try await server.notify("thread/started", ["thread": thread("other")])
        _ = try await events.next()
        let stopping = Task { try await transport.abortAgentRun(target: "codex:t") }
        let interrupt = try await server.call("turn/interrupt")
        #expect(interrupt["params"]?["turnId"] == .string("run"))
        try await server.reply(interrupt, .object([:]))
        try await stopping.value
        try await server.status("idle")
        _ = try await events.next()
        let next = Task { try await transport.promptAgent(AgentPromptParams(target: "codex:t", text: "Next")) }
        try await server.reply(try await server.call("turn/start"), .object(["turn": turn("next", status: "inProgress")]))
        _ = try await next.value
        try await transport.close()
    }

    @Test func aTurnStartedOnAnUnsubscribedThreadIsReadNotTracked() async throws {
        let (transport, server, _) = try await fixture([[thread(status: "active")]])
        let stream = try await transport.subscribeToEvents([])
        var events = stream.events.makeAsyncIterator()
        try await server.notify("turn/started", ["threadId": .string("t"), "turn": turn("desk", status: "inProgress")])
        try await server.notify("thread/started", ["thread": thread("other")])
        _ = try await events.next()
        let stopping = Task { try await transport.abortAgentRun(target: "codex:t") }
        try await server.reply(try await server.call("thread/turns/list"), .object([
            "data": .array([turn("desk", status: "inProgress")])]))
        let interrupt = try await server.call("turn/interrupt")
        #expect(interrupt["params"]?["turnId"] == .string("desk"))
        try await server.reply(interrupt, .object([:]))
        try await stopping.value
        try await transport.close()
    }

    /// B-30: the thread goes idle while Stop reads its newest turn, and the
    /// read answers with the turn as it was. Stop must not interrupt it.
    @Test func aReadAnsweredAfterTheTurnEndedIsNotInterrupted() async throws {
        let (transport, server, _) = try await fixture([[thread(status: "active")]])
        let stream = try await transport.subscribeToEvents([])
        var events = stream.events.makeAsyncIterator()
        let stopping = Task { try await transport.abortAgentRun(target: "codex:t") }
        let read = try await server.call("thread/turns/list")
        try await server.status("idle")
        _ = try await events.next()
        try await server.reply(read, .object(["data": .array([turn("run", status: "inProgress")])]))
        let pinging = Task {
            try await stopping.value
            return try await transport.ping()
        }
        let next = try await server.next()
        #expect(next["method"]?.stringValue == "thread/loaded/list", "Stop interrupted an ended turn")
        if next["method"]?.stringValue == "turn/interrupt" {
            try await server.reply(next, .object([:]))
            try await server.reply(try await server.call("thread/loaded/list"), .object(["data": .array([])]))
        } else {
            try await server.reply(next, .object(["data": .array([])]))
        }
        _ = try await pinging.value
        try await transport.close()
    }

    /// Review 177084: two Stops read the newest turn at once. The first
    /// reads turn `run` and interrupts it; the second's read, answered
    /// later, is its own (as on base): no running turn, or another turn.
    @Test(arguments: [nil, "desk"] as [String?])
    func overlappingReadsEachAnswerTheirOwnCaller(secondRunning: String?) async throws {
        let (transport, server, _) = try await fixture([[thread(status: "active")]])
        let first = Task { try await transport.abortAgentRun(target: "codex:t") }
        let firstRead = try await server.call("thread/turns/list")
        let second = Task { try await transport.abortAgentRun(target: "codex:t") }
        let secondRead = try await server.call("thread/turns/list")
        try await server.reply(firstRead, .object(["data": .array([turn("run", status: "inProgress")])]))
        let interrupt = try await server.call("turn/interrupt")
        #expect(interrupt["params"]?["turnId"] == .string("run"))
        try await server.reply(interrupt, .object([:]))
        try await first.value
        try await server.reply(secondRead, .object(["data": .array([
            secondRunning.map { turn($0, status: "inProgress") } ?? turn("run")])]))
        let pinging = Task {
            try await second.value
            return try await transport.ping()
        }
        let next = try await server.next()
        if let secondRunning {
            #expect(next["method"]?.stringValue == "turn/interrupt")
            #expect(next["params"]?["turnId"] == .string(secondRunning), "Stop interrupted another read's turn")
        } else {
            #expect(next["method"]?.stringValue == "thread/loaded/list", "Stop interrupted an ended turn")
        }
        if next["method"]?.stringValue == "turn/interrupt" {
            try await server.reply(next, .object([:]))
            try await server.reply(try await server.call("thread/loaded/list"), .object(["data": .array([])]))
        } else {
            try await server.reply(next, .object(["data": .array([])]))
        }
        _ = try await pinging.value
        try await transport.close()
    }

    // MARK: Pins: structured approvals (CODEX-06)

    @Test func aReplayedRequestReplacesItselfAndAClosedThreadDropsItsRequests() async throws {
        let (transport, server, _) = try await fixture()
        let stream = try await transport.subscribeToEvents([])
        var events = stream.events.makeAsyncIterator()
        for command in ["echo one", "echo two"] {
            try await server.serverRequest(1, "item/commandExecution/requestApproval", [
                "threadId": .string("t"), "command": .string(command)])
            _ = try await events.next()
        }
        #expect(try await transport.pendingAgentRequests(target: "codex:t") == [AgentPendingRequest(id: "1",
            kind: .command(command: "echo two", cwd: nil, reason: nil))])
        // A request for a thread that is not listed is never shown or answered.
        try await server.serverRequest(2, "item/commandExecution/requestApproval", [
            "threadId": .string("unknown"), "command": .string("echo")])
        try await server.notify("thread/closed", ["threadId": .string("t")])
        _ = try await events.next()
        #expect(try await transport.pendingAgentRequests(target: "codex:t").isEmpty)
        #expect(try await transport.pendingAgentRequests(target: "codex:unknown").isEmpty)
        await #expect(throws: TransportError.apiRejected(code: "agent_request_resolved", message: "This request was already resolved.")) {
            try await transport.answerAgentRequest(target: "codex:t", requestID: "1", answer: .allow)
        }
        let ping = Task { try await transport.ping() }
        try await server.reply(try await server.call("thread/loaded/list"), .object(["data": .array([])]))
        _ = try await ping.value
        try await transport.close()
    }
}

/// Scripted peer on the same in-memory duplex channel as the socket/RPC tests.
/// All server messages are genuine unmasked frames; every expected outbound
/// method is consumed in order, so an unexpected resume, retry or reply fails.
private actor CodexTestServer {
    nonisolated let channel = CodexMemoryChannel()
    private var consumed = 0

    func next() async throws -> JSONValue {
        while true {
            let frames = try await channel.waitForFrames(consumed + 1)
            let frame = frames[consumed]
            consumed += 1
            let message = try JSONDecoder().decode(JSONValue.self, from: frame.payload)
            if message["method"]?.stringValue == "initialized" { continue }
            return message
        }
    }
    func call(_ method: String) async throws -> JSONValue {
        let value = try await next()
        #expect(value["method"]?.stringValue == method)
        return value
    }
    func response() async throws -> JSONValue {
        let value = try await next()
        #expect(value["method"] == nil && value["result"] != nil)
        return value
    }
    func send(_ value: JSONValue) async throws {
        await channel.feed(CodexMemoryChannel.serverFrame(opcode: 1, payload: try JSONEncoder().encode(value)))
    }
    func reply(_ call: JSONValue, _ result: JSONValue) async throws {
        try await send(.object(["id": try #require(call["id"]), "result": result]))
    }
    func reject(_ call: JSONValue, _ message: String, code: Int = -32600) async throws {
        try await send(.object(["id": try #require(call["id"]), "error": .object(["code": .number(Double(code)), "message": .string(message)])]))
    }
    func notify(_ method: String, _ params: [String: JSONValue]) async throws {
        try await send(.object(["method": .string(method), "params": .object(params)]))
    }
    func serverRequest(_ id: Int, _ method: String, _ params: [String: JSONValue]) async throws {
        try await send(.object(["id": .number(Double(id)), "method": .string(method), "params": .object(params)]))
    }
    func status(_ type: String, flags: [String] = []) async throws {
        try await notify("thread/status/changed", ["threadId": .string("t"),
            "status": .object(["type": .string(type), "activeFlags": .array(flags.map(JSONValue.string))])])
    }
}
