import Foundation
import Synchronization
import Testing

@testable import Waycar

/// OpenCode 2.2.7 payload shapes from `docs/research/opencode-v2-server-2026-11.md`
/// and the contract run: list, get, create and request lists wrap their value
/// in `{data}`; PATCH and replies answer 204; a desk session has no `metadata`.
@Suite("OpenCode transport", .timeLimit(.minutes(1)))
struct OpenCodeTransportTests {
    static let presence = OpenCodePresence(
        path: "/home/me/.opencode/bin/opencode", version: "2.2.7", serverURL: "http://127.0.0.1:49374",
        registrationPath: "~/.local/state/opencode/service.json")

    static func session(
        _ id: String, dir: String = "/home/me/proj", title: String = "Task", idle: Double? = nil,
        viewed: Double? = nil, extra: [String: JSONValue] = [:]
    ) -> JSONValue {
        var time: [String: JSONValue] = ["created": .number(1_794_434_916_308), "updated": .number(1_794_434_916_308)]
        if let idle { time["idle"] = .number(idle) }
        if let viewed { time["viewed"] = .number(viewed) }
        return .object([
            "id": .string(id), "projectID": .string("4e3c5cd0a15ceba1efc52b4f3e2bf90d9d11c10b"), "cost": .number(0),
            "tokens": .object(["input": .number(0)]), "title": .string(title), "time": .object(time),
            "location": .object(["directory": .string(dir)])
        ].merging(extra) { _, new in new })
    }

    static func list(_ sessions: [JSONValue], next: String?) -> OpenCodeFakeResponse {
        .json(.object(["data": .array(sessions),
                       "cursor": .object(["previous": .null, "next": next.map(JSONValue.string) ?? .null])]))
    }

    /// Answers the reads every (re)connect makes; `extra` answers the rest.
    static func handler(
        sessions: @escaping @Sendable () -> [JSONValue], active: @escaping @Sendable () -> [String] = { [] },
        permissions: [String: [JSONValue]] = [:], forms: [String: [JSONValue]] = [:],
        extra: @escaping @Sendable (OpenCodeFakeRequest) -> OpenCodeFakeResponse? = { _ in nil }
    ) -> OpenCodeFakeServer.Handler {
        { request in
            if let response = extra(request) { return response }
            switch (request.method, request.route) {
            case ("GET", "/api/session"): return list(sessions(), next: nil)
            case ("GET", "/api/session/active"):
                return .json(.object(["data": .object(Dictionary(uniqueKeysWithValues: active().map {
                    ($0, JSONValue.object(["type": .string("running")])) }))]))
            default: break
            }
            let parts = request.route.split(separator: "/").map(String.init)
            if request.method == "GET", parts.count == 4, parts[0] == "api", parts[1] == "session" {
                if parts[3] == "permission" { return .json(.object(["data": .array(permissions[parts[2]] ?? [])])) }
                if parts[3] == "form" { return .json(.object(["data": .array(forms[parts[2]] ?? [])])) }
            }
            if request.method == "GET", parts.count == 3, parts[1] == "session",
               let found = sessions().first(where: { $0["id"]?.stringValue == parts[2] }) {
                return .json(.object(["data": found]))
            }
            return OpenCodeFakeResponse(status: 404, body: #"{"_tag":"SessionNotFoundError","message":"missing"}"#)
        }
    }

    static func open(
        _ handler: @escaping OpenCodeFakeServer.Handler, passwords: [String] = ["pw1"],
        presence: OpenCodePresence = Self.presence
    ) async throws -> (OpenCodeTransport, OpenCodeFakeServer, FakeHostSSHServices) {
        let server = OpenCodeFakeServer(handler: handler)
        let box = PasswordBox(passwords)
        let services = FakeHostSSHServices(exec: { command, _ in
            guard command.contains("service.json") else { return FakeHostSSHServices.result(exitStatus: 1) }
            return FakeHostSSHServices.result(stdout: #"{"id":"x","version":"2.2.7","url":"http://127.0.0.1:49374","pid":7,"password":"\#(box.next())"}"#)
        })
        await services.serveUltimate { _ in OpenCodeFakeChannel(server: server) }
        let transport = try await OpenCodeTransport.open(
            session: services, presence: presence, retryDelays: [.milliseconds(20), .milliseconds(20)])
        return (transport, server, services)
    }

    static func basic(_ password: String) -> String {
        "Basic " + Data("opencode:\(password)".utf8).base64EncodedString()
    }

    @Test("Inventory pages newest first, one Workspace per folder, status from active, requests and views")
    func inventoryAndStatus() async throws {
        let fillers = (0..<96).map { Self.session(String(format: "ses_f%03d", $0), dir: "/work/other") }
        let page1 = fillers + [
            Self.session("ses_work"), Self.session("ses_block"),
            Self.session("ses_done", dir: "/home/me", idle: 200, viewed: 100),
            Self.session("ses_desk", extra: ["metadata": .null])
        ]
        let page2 = [
            Self.session("ses_seen", idle: 100, viewed: 200),
            Self.session("ses_new", title: "  "),
            Self.session("ses_child", extra: ["parentID": .string("ses_work")]),
            Self.session("ses_arch", extra: ["time": .object(["created": .number(1), "updated": .number(1), "archived": .number(2)])])
        ]
        let permission: JSONValue = .object([
            "id": .string("per_1"), "sessionID": .string("ses_block"), "action": .string("shell"),
            "resources": .array([.string("echo waycar-tool-ok")]), "save": .array([.string("echo *")]),
            "source": .object(["type": .string("tool"), "messageID": .string("msg_1"), "id": .string("call_1")])])
        let (transport, server, services) = try await Self.open(Self.handler(
            sessions: { page1 + page2 }, active: { ["ses_work", "ses_block", "ses_gone"] },
            permissions: ["ses_block": [permission]],
            extra: { request in
                if request.route == "/api/session/ses_done/view" { return OpenCodeFakeResponse(status: 204, body: nil) }
                guard request.method == "GET", request.route == "/api/session" else { return nil }
                return request.query.contains("cursor=c1") ? Self.list(page2, next: nil) : Self.list(page1, next: "c1")
            }))
        // Closed Sessions' one archived page is read apart from the inventory.
        let lists = await server.requests("GET", "/api/session").filter { !$0.query.contains("archived=true") }
        #expect(lists.count == 2)
        #expect(lists.first?.query == "parentID=null&archived=false&limit=100&order=desc")
        #expect(lists.last?.query == "parentID=null&archived=false&limit=100&cursor=c1")
        // Only running sessions have pending requests to read.
        #expect(await server.requests("GET", "/api/session/ses_work/permission").count == 1)
        #expect(await server.requests("GET", "/api/session/ses_done/permission").isEmpty)
        for request in await server.requests {
            #expect(request.headers["authorization"] == Self.basic("pw1"))
        }
        #expect(await services.execs.first?.command == #"cat -- "$HOME"/.local/state/opencode/service.json"#)
        #expect(Set(await services.openCodeDials) == ["127.0.0.1:49374"])

        let snapshot = try await transport.sessionSnapshot()
        #expect(snapshot.agents.count == 102)
        let status = Dictionary(uniqueKeysWithValues: snapshot.agents.map { ($0.paneID, $0.agentStatus) })
        #expect(status["opencode:ses_work"] == .working)
        #expect(status["opencode:ses_block"] == .blocked)
        #expect(status["opencode:ses_done"] == .done)
        #expect(status["opencode:ses_seen"] == .idle)
        #expect(status["opencode:ses_desk"] == .idle)
        #expect(status["opencode:ses_child"] == nil && status["opencode:ses_arch"] == nil)
        let named = Dictionary(uniqueKeysWithValues: snapshot.agents.map { ($0.paneID, $0.name) })
        #expect(named["opencode:ses_new"] == "OpenCode")
        #expect(named["opencode:ses_work"] == "Task")
        #expect(Set(snapshot.workspaces.map(\.label)) == ["~", "proj", "other"])
        #expect(snapshot.workspaces.first { $0.label == "proj" }?.agentStatus == .blocked)
        #expect(snapshot.workspaces.first { $0.label == "other" }?.paneCount == 96)
        let agent = try #require(snapshot.agents.first { $0.paneID == "opencode:ses_block" })
        #expect(agent.agent == "opencode" && agent.cwd == "/home/me/proj" && agent.workspaceID == "opencode:cwd:/home/me/proj")
        #expect(agent.agentSession?.value == "ses_block")
        #expect(try await transport.availableAgentKinds() == [.opencode])

        let requests = try await transport.pendingAgentRequests(target: "opencode:ses_block")
        #expect(requests == [AgentPendingRequest(id: "per_1", kind: .command(
            command: "echo waycar-tool-ok", cwd: "/home/me/proj", reason: nil))])

        // Opening the Agent (the Console's focus) marks the result seen.
        try await transport.focusAgent(AgentTarget(target: "opencode:ses_done"))
        #expect(await server.requests("POST", "/api/session/ses_done/view").first?.body == .object(["idle": .number(200)]))
        #expect(try await transport.sessionSnapshot().agents.first { $0.paneID == "opencode:ses_done" }?.agentStatus == .idle)
        try await transport.close()
        #expect(await services.releaseCount == 1)
    }

    @Test("Events keep the inventory current and publish inventory changes")
    func events() async throws {
        let (transport, server, _) = try await Self.open(Self.handler(sessions: { [Self.session("ses_a")] }, extra: { request in
            request.route == "/api/session/ses_b"
                ? .json(.object(["data": Self.session("ses_b", dir: "/work/b")])) : nil
        }))
        #expect(try await transport.sessionSnapshot().agents.map(\.paneID) == ["opencode:ses_a"])
        let stream = try await transport.subscribeToEvents([])
        let probe = OpenCodeChangeProbe()
        let reader = Task { for try await _ in stream.events { await probe.changed() } }
        func status(_ id: String) async throws -> AgentStatus? {
            try await transport.sessionSnapshot().agents.first { $0.paneID == "opencode:\(id)" }?.agentStatus
        }

        await server.push("session.created", ["sessionID": .string("ses_b"), "title": .string("Task")])
        try await waitUntil("the created session is listed") { try await status("ses_b") == .idle }
        await server.push("session.execution.started", ["sessionID": .string("ses_b")])
        try await waitUntil("started is Working") { try await status("ses_b") == .working }
        await server.push("permission.asked", ["id": .string("per_9"), "sessionID": .string("ses_b"), "action": .string("edit"),
                                               "resources": .array([.string("src/a.swift")]), "message": .string("Edit a.swift")])
        try await waitUntil("a permission is Blocked") { try await status("ses_b") == .blocked }
        await server.push("permission.replied", ["sessionID": .string("ses_b"), "requestID": .string("per_9"),
                                                 "reply": .string("once")])
        try await waitUntil("a reply is Working again") { try await status("ses_b") == .working }
        await server.push("form.created", ["form": .object(["id": .string("frm_1"), "sessionID": .string("ses_b"),
            "title": .string("Questions"), "metadata": .object(["kind": .string("question")]),
            "fields": .array([.object(["key": .string("q0"), "type": .string("string")])])])])
        try await waitUntil("a Form is Blocked") { try await status("ses_b") == .blocked }
        await server.push("form.replied", ["id": .string("frm_1"), "sessionID": .string("ses_b"), "answer": .object([:])])
        try await waitUntil("answered is Working again") { try await status("ses_b") == .working }
        await server.push("session.execution.succeeded", ["sessionID": .string("ses_b")], created: 1_794_434_999_000)
        try await waitUntil("a finished turn is Done") { try await status("ses_b") == .done }
        await server.push("session.viewed", ["sessionID": .string("ses_b"), "idle": .number(1_794_434_999_000)])
        try await waitUntil("viewed is Idle") { try await status("ses_b") == .idle }
        await server.push("session.renamed", ["sessionID": .string("ses_b"), "title": .string("Renamed")])
        try await waitUntil("renamed") {
            try await transport.sessionSnapshot().agents.first { $0.paneID == "opencode:ses_b" }?.name == "Renamed"
        }
        await server.push("session.archived", ["sessionID": .string("ses_a")])
        try await waitUntil("archived leaves the list") {
            try await transport.sessionSnapshot().agents.map(\.paneID) == ["opencode:ses_b"]
        }
        // Unknown sessions and kinds change nothing.
        await server.push("session.execution.started", ["sessionID": .string("ses_child")])
        await server.push("session.text.delta", ["sessionID": .string("ses_b")])
        try await waitUntil("every change was published") { await probe.changes >= 10 }
        await stream.end()
        reader.cancel()
        try await transport.close()
    }

    @Test("A reconnect or server restart re-lists and re-reads what runs and waits")
    func reconnectRefetch() async throws {
        let listed = Mutex([Self.session("ses_a")])
        let active = Mutex<[String]>([])
        let form: JSONValue = .object([
            "id": .string("frm_1"), "sessionID": .string("ses_b"), "title": .string("Questions"),
            "metadata": .object(["kind": .string("question"), "tool": .object([:])]),
            "fields": .array([.object(["key": .string("q0"), "type": .string("string")])])])
        let (transport, server, _) = try await Self.open(Self.handler(
            sessions: { listed.withLock { $0 } }, active: { active.withLock { $0 } }, forms: ["ses_b": [form]]))
        let stream = try await transport.subscribeToEvents([])
        listed.withLock { $0 = [Self.session("ses_b")] }
        active.withLock { $0 = ["ses_b"] }
        await server.dropStream()
        try await waitUntil("the new stream's re-read replaces the old picture") {
            try await transport.sessionSnapshot().agents.map(\.paneID) == ["opencode:ses_b"]
        }
        #expect(try await transport.sessionSnapshot().agents.first?.agentStatus == .blocked)
        #expect(await server.requests("GET", "/api/session/active").count == 2)
        #expect(await server.requests("GET", "/api/event").count == 2)
        #expect(await server.requests("GET", "/api/event").first?.query
                == OpenCodeTransport.eventTypes.map { "types=\($0)" }.joined(separator: "&"))
        // A second server.connected on the same stream (a restart) re-reads too.
        active.withLock { $0 = [] }
        await server.pushConnected()
        try await waitUntil("the restart's re-read clears the request") {
            try await transport.sessionSnapshot().agents.first?.agentStatus == .idle
        }
        #expect(await transport.isConnected)
        await stream.end()
        try await transport.close()
    }

    @Test("The stream is lost after its retries, and the transport says so")
    func lostAfterRetries() async throws {
        let (transport, server, _) = try await Self.open(Self.handler(sessions: { [] }))
        let stream = try await transport.subscribeToEvents([])
        await server.refuseStreams(status: 503)
        await server.dropStream()
        await #expect(throws: TransportError.self) { for try await _ in stream.events {} }
        #expect(!(await transport.isConnected))
        try await transport.close()
    }

    @Test("A 401 re-reads the password once; a second 401 is an auth failure")
    func passwordReread() async throws {
        let (transport, server, services) = try await Self.open({ request in
            guard request.headers["authorization"] == Self.basic("new") else {
                return OpenCodeFakeResponse(status: 401, body: #"{"_tag":"UnauthorizedError"}"#)
            }
            return Self.handler(sessions: { [Self.session("ses_a")] })(request)
        }, passwords: ["old", "new"])
        #expect(await services.execs.count == 2)
        #expect(try await transport.sessionSnapshot().agents.count == 1)
        let refused = await server.requests.filter { $0.headers["authorization"] == Self.basic("old") }
        #expect(refused.map(\.route) == ["/api/event"])
        await server.setHandler { _ in OpenCodeFakeResponse(status: 401, body: #"{"_tag":"UnauthorizedError"}"#) }
        do {
            try await transport.abortAgentRun(target: "opencode:ses_a")
            Issue.record("A second 401 must fail")
        } catch let error as TransportError {
            #expect(error == .apiRejected(code: "opencode_unauthorized", message: "The OpenCode server refused its password."))
            #expect(!"\(error)".contains("new") && !"\(error)".contains("old"))
        }
        #expect(await services.execs.count == 3)
        try await transport.close()
    }

    @Test("A missing registration fails the open without its contents")
    func missingPassword() async throws {
        let server = OpenCodeFakeServer(handler: Self.handler(sessions: { [] }))
        let services = FakeHostSSHServices(exec: { _, _ in
            FakeHostSSHServices.result(stdout: #"{"id":"x","url":"http://127.0.0.1:1"}"#)
        })
        await services.serveUltimate { _ in OpenCodeFakeChannel(server: server) }
        await #expect(throws: TransportError.apiRejected(code: "opencode_password_unavailable",
            message: "Waycar could not read the OpenCode server's password on this Host.")) {
            _ = try await OpenCodeTransport.open(session: services, presence: Self.presence)
        }
        #expect(await server.requests.isEmpty)
        #expect(await services.releaseCount == 0)
    }

    @Test("Prompt and interrupt bodies; images go as data URIs")
    func promptAndInterrupt() async throws {
        let (transport, server, _) = try await Self.open(Self.handler(sessions: { [Self.session("ses_a")] }, extra: { request in
            switch request.route {
            case "/api/session/ses_a/prompt":
                return .json(.object(["data": .object(["id": .string("msg_x"), "delivery": .string("steer")])]))
            case "/api/session/ses_a/interrupt": return .json(.object(["interrupted": .bool(true)]))
            default: return nil
            }
        }))
        let agent = try await transport.promptAgent(AgentPromptParams(target: "opencode:ses_a", text: "hello"))
        #expect(agent.paneID == "opencode:ses_a")
        _ = try await transport.prompt(target: "opencode:ses_a", text: "look",
            files: [OpenCodePromptFile(mime: "image/png", data: Data([1, 2, 3]), name: "red.png")])
        try await transport.abortAgentRun(target: "opencode:ses_a")
        let prompts = await server.requests("POST", "/api/session/ses_a/prompt")
        #expect(prompts.map(\.body) == [
            .object(["text": .string("hello")]),
            .object(["text": .string("look"), "files": .array([.object([
                "uri": .string("data:image/png;base64,AQID"), "name": .string("red.png")])])])
        ])
        let interrupt = try #require(await server.requests("POST", "/api/session/ses_a/interrupt").first)
        #expect(interrupt.body == nil)
        await #expect(throws: TransportError.self) {
            _ = try await transport.promptAgent(AgentPromptParams(target: "opencode:../../api/x", text: "x"))
        }
        try await transport.close()
    }

    @Test("The 2.2.7 export's history builds the chat: prompts, images, tools, replies, quiet interrupts")
    func transcript() async throws {
        let items = try JSONDecoder().decode(JSONValue.self, from: Data(Self.exportMessages.utf8)).codexArray ?? []
        let newestFirst = Array(items.reversed())
        let (transport, server, _) = try await Self.open(Self.handler(
            sessions: { [Self.session("ses_waycarFixture0001")] }, extra: { request in
                if request.route == "/api/session/ses_waycarFixture0001/message/msg_1cca83c21001oNEhmy6PGxcfqA" {
                    return .json(.object(["data": items[13]]))
                }
                guard request.route == "/api/session/ses_waycarFixture0001/message" else { return nil }
                return .json(.object(["data": .array(newestFirst), "cursor": .object([
                    "previous": .string("newer"), "next": .null])]))
            }))
        let request = ChatTranscriptRequest(paneID: "opencode:ses_waycarFixture0001", kind: "opencode", sessionKind: nil,
            sessionValue: nil, cwd: nil, launchedAt: nil, status: nil, after: nil)
        let snapshot = try await transport.readChatTranscript(request)
        // A null `cursor.next` is the last page.
        #expect(await server.requests("GET", "/api/session/ses_waycarFixture0001/message").count == 1)
        #expect(await server.requests("GET", "/api/session/ses_waycarFixture0001/message").first?.query
                == "limit=100&order=desc")
        #expect(snapshot.header.kind == "opencode" && !snapshot.header.truncated && !snapshot.header.turnOpen)
        let all = snapshot
        #expect(all.messages.map(\.role) == [.user, .assistant, .user, .assistant, .assistant, .user, .assistant,
                                             .user, .assistant, .assistant, .user, .assistant, .user])
        #expect(all.messages.map(\.text) == [
            "hello fixture", "waycar-mock-reply: fixture",
            "run it WAYCAR_TOOL", "", "waycar-tool-done: saw waycar-tool-ok",
            "run again WAYCAR_TOOL", "",
            "ask WAYCAR_ASK", "", "waycar-tool-done: tool output missing waycar-tool-ok",
            "look at this image", "waycar-mock-reply: image",
            "slow WAYCAR_SLOW"])
        #expect(all.messages[3].card == .toolSteps(ChatToolStepsSummary(count: 1, summary: "shell")))
        #expect(all.messages[3].id == "msg_1cca7f922001b2CVCUiuCmp9Po:tools")
        #expect(all.messages[6].card == .toolSteps(ChatToolStepsSummary(count: 1, summary: "shell")))
        #expect(all.messages[8].card == .toolSteps(ChatToolStepsSummary(count: 1, summary: "question")))
        let image = try #require(all.messages[10].media.first)
        #expect(image.kind == .image && image.mime == "image/png" && image.alt == "red.png")
        #expect(image.source == .sessionInline(session: "ses_waycarFixture0001",
            pointer: "/msg_1cca83c21001oNEhmy6PGxcfqA/files/0/data", agentKind: "opencode"))
        let png = try await transport.readChatMedia(.sessionInline(session: "ses_waycarFixture0001", id: image.id,
            pointer: "/msg_1cca83c21001oNEhmy6PGxcfqA/files/0/data", agentKind: "opencode", maxBytes: 1_000))
        #expect(png.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
        // Incremental reads continue after the cursor; a reply at the
        // cursor comes again, since it may have grown.
        let after = OpenCodeSnapshotBuilder.transcript(sessionID: "s", items: newestFirst, truncated: false,
            running: true, after: "msg_1cca83c44001mx1EtTIKyUWJQi")
        #expect(after.messages.map(\.text) == ["waycar-mock-reply: image", "slow WAYCAR_SLOW"] && after.header.turnOpen)
        let onPrompt = OpenCodeSnapshotBuilder.transcript(sessionID: "s", items: newestFirst, truncated: false,
            running: true, after: "msg_1cca8441e001NcbVjcvvDSJ9A8")
        #expect(onPrompt.messages.isEmpty && onPrompt.header.afterFound)
        let onTools = OpenCodeSnapshotBuilder.transcript(sessionID: "s", items: newestFirst, truncated: false,
            running: false, after: "msg_1cca7f922001b2CVCUiuCmp9Po:tools")
        #expect(onTools.messages.first?.id == "msg_1cca7f922001b2CVCUiuCmp9Po:tools")
        // A failed turn ends with a failure card; a cut history drops its orphaned head.
        let failed = OpenCodeSnapshotBuilder.transcript(sessionID: "s", items: [
            .object(["id": .string("msg_i"), "type": .string("idle"), "outcome": .string("failed"), "time": .object(["created": .number(3)])]),
            .object(["id": .string("msg_a"), "type": .string("assistant"), "content": .array([]), "finish": .string("error"),
                     "error": .object(["type": .string("provider"), "message": .string("Rate limited\nretry later")])]),
            .object(["id": .string("msg_u"), "type": .string("user"), "text": .string("go")]),
            .object(["id": .string("msg_old"), "type": .string("assistant"),
                     "content": .array([.object(["type": .string("text"), "text": .string("orphan")])])])
        ], truncated: true, running: false, after: nil)
        #expect(failed.messages.map(\.id) == ["msg_u", "msg_i:failure"])
        #expect(failed.messages.last?.card == .failure(ChatFailureCard(conversationId: nil, title: nil,
                                                                       error: "Rate limited", step: nil)))
        try await transport.close()
    }

    @Test("A reply that grows in one assistant message reaches the Chat in full on the next incremental read")
    @MainActor
    func growingReplyOnIncrementalRead() async throws {
        func history(_ parts: [String], idle: Bool) -> JSONValue {
            var items: [JSONValue] = []
            if idle { items.append(.object(["id": .string("msg_3"), "type": .string("idle"), "outcome": .string("succeeded")])) }
            items.append(.object(["id": .string("msg_2"), "type": .string("assistant"), "content": .array(parts.map {
                .object(["type": .string("text"), "text": .string($0)]) })]))
            items.append(.object(["id": .string("msg_1"), "type": .string("user"), "text": .string("go")]))
            return .object(["data": .array(items), "cursor": .object(["next": .null])])
        }
        let page = Mutex(history(["Part one."], idle: false))
        let (transport, _, _) = try await Self.open(Self.handler(
            sessions: { [Self.session("ses_a")] }, active: { ["ses_a"] }, extra: { request in
                request.route == "/api/session/ses_a/message" ? .json(page.withLock { $0 }) : nil
            }))
        let afters = Mutex<[String?]>([])
        let store = ChatTranscriptStore(
            read: { after in
                afters.withLock { $0.append(after) }
                return try await transport.readChatTranscript(ChatTranscriptRequest(
                    paneID: "opencode:ses_a", kind: "opencode", sessionKind: nil, sessionValue: nil, cwd: nil,
                    launchedAt: nil, status: nil, after: after))
            },
            readScreen: { "" }, sendKeys: { _ in }, initialStatus: .idle, statusUpdateSource: { nil },
            retryDelays: [.seconds(60)], workingPollInterval: .seconds(60))
        await store.refresh()
        #expect(store.messages.map(\.text) == ["go", "Part one."])
        // OpenCode appends the next text part to the same message, and the turn ends.
        page.withLock { $0 = history(["Part one.", "Part two."], idle: true) }
        await store.refresh()
        #expect(afters.withLock { $0 } == [nil, "msg_2"])
        #expect(store.messages.map(\.id) == ["msg_1", "msg_2"])
        #expect(store.messages.last?.text == "Part one.\n\nPart two.")
        try await transport.close()
    }

    @Test("Permissions and question Forms map to cards; answers reply once, reject, or the Form's values")
    func requestsAndAnswers() async throws {
        let shell: JSONValue = .object(["id": .string("per_s"), "sessionID": .string("ses_a"), "action": .string("shell"),
            "resources": .array([.string("echo waycar-tool-ok")]), "message": .string("Run it")])
        let edit: JSONValue = .object(["id": .string("per_e"), "sessionID": .string("ses_a"), "action": .string("write"),
            "resources": .array([.string("/home/me/proj/a.txt")])])
        let web: JSONValue = .object(["id": .string("per_w"), "sessionID": .string("ses_a"), "action": .string("webfetch"),
            "resources": .array([.string("https://example.com")])])
        let question: JSONValue = .object(["id": .string("frm_q"), "sessionID": .string("ses_a"), "title": .string("Questions"),
            "metadata": .object(["kind": .string("question"), "tool": .object(["id": .string("call_7")])]),
            "fields": .array([
                .object(["key": .string("q0"), "title": .string("Color"), "description": .string("Pick a color"),
                         "type": .string("string"), "custom": .bool(true), "options": .array([
                            .object(["value": .string("Red"), "label": .string("Red"), "description": .string("warm")]),
                            .object(["value": .string("blue"), "label": .string("Blue"), "description": .string("cool")])])]),
                .object(["key": .string("q1"), "title": .string("Sizes"), "type": .string("multiselect"), "options": .array([
                    .object(["value": .string("s"), "label": .string("Small")]),
                    .object(["value": .string("l"), "label": .string("Large")])])])])])
        let other: JSONValue = .object(["id": .string("frm_o"), "sessionID": .string("ses_a"), "title": .string("Provider"),
            "metadata": .object(["kind": .string("websearch.provider")]),
            "fields": .array([.object(["key": .string("k"), "type": .string("string")])])])
        let forms = Mutex([question, other])
        let (transport, server, _) = try await Self.open(Self.handler(
            sessions: { [Self.session("ses_a")] }, active: { ["ses_a"] },
            permissions: ["ses_a": [shell, edit, web]], extra: { request in
                switch request.route {
                case "/api/session/ses_a/form" where request.method == "GET":
                    return .json(.object(["data": .array(forms.withLock { $0 })]))
                case "/api/session/ses_a/permission/per_s/reply", "/api/session/ses_a/form/frm_q/reply":
                    return OpenCodeFakeResponse(status: 204, body: nil)
                case "/api/session/ses_a/permission/per_e/reply":
                    return OpenCodeFakeResponse(status: 404, body: #"{"_tag":"PermissionNotFoundError","requestID":"per_e","message":"gone"}"#)
                case "/api/session/ses_a/form/frm_gone/reply":
                    return OpenCodeFakeResponse(status: 409, body: #"{"_tag":"FormAlreadySettledError","id":"frm_gone","message":"settled"}"#)
                default: return nil
                }
            }))
        let pending = try await transport.pendingAgentRequests(target: "opencode:ses_a")
        #expect(pending.map(\.id) == ["per_s", "per_e", "per_w", "frm_q", "frm_o"])
        #expect(pending[0].kind == .command(command: "echo waycar-tool-ok", cwd: "/home/me/proj", reason: "Run it"))
        #expect(pending[1].kind == .fileChange(reason: nil, paths: ["/home/me/proj/a.txt"]))
        #expect(pending[2].kind == .unsupported(method: "permission:webfetch"))
        #expect(pending[3].kind == .questions(ChatQuestionCard(body: "", questions: [
            ChatQuestion(ref: "q0", text: "Pick a color", kind: "choice", options: [
                ChatQuestionOption(key: "a", label: "Red", detail: "warm", recommended: false),
                ChatQuestionOption(key: "b", label: "Blue", detail: "cool", recommended: false)]),
            ChatQuestion(ref: "q1", text: "Sizes", kind: "multi", options: [
                ChatQuestionOption(key: "a", label: "Small", detail: nil, recommended: false),
                ChatQuestionOption(key: "b", label: "Large", detail: nil, recommended: false)])])))
        #expect(pending[4].kind == .unsupported(method: "form"))

        try await transport.answerAgentRequest(target: "opencode:ses_a", requestID: "per_s", answer: .allow)
        #expect(await server.requests("POST", "/api/session/ses_a/permission/per_s/reply").first?.body
                == .object(["decision": .string("once")]))
        try await transport.answerAgentRequest(target: "opencode:ses_a", requestID: "frm_q",
                                               answer: .answers(["q0": ["Blue"], "q1": ["Small", "Large"]]))
        #expect(await server.requests("POST", "/api/session/ses_a/form/frm_q/reply").first?.body == .object([
            "answer": .object(["q0": .string("blue"), "q1": .array([.string("s"), .string("l")])])]))
        let resolved = TransportError.apiRejected(code: "agent_request_resolved", message: "This request was already resolved.")
        await #expect(throws: resolved) {
            try await transport.answerAgentRequest(target: "opencode:ses_a", requestID: "per_e", answer: .cancel)
        }
        #expect(await server.requests("POST", "/api/session/ses_a/permission/per_e/reply").first?.body
                == .object(["decision": .string("reject")]))
        await #expect(throws: resolved) {
            try await transport.answerAgentRequest(target: "opencode:ses_a", requestID: "per_unknown", answer: .allow)
        }
        await #expect(throws: TransportError.apiRejected(code: "unsupported",
            message: "OpenCode sessions support messages and Chat Mode only.")) {
            try await transport.answerAgentRequest(target: "opencode:ses_a", requestID: "per_w", answer: .allow)
        }
        // A Form answered at the desk between the list and the reply.
        forms.withLock { $0.append(.object(["id": .string("frm_gone"), "sessionID": .string("ses_a"),
            "title": .string("Q"), "metadata": .object(["kind": .string("question")]),
            "fields": .array([.object(["key": .string("q0"), "type": .string("string")])])])) }
        _ = try await transport.pendingAgentRequests(target: "opencode:ses_a")
        await #expect(throws: resolved) {
            try await transport.answerAgentRequest(target: "opencode:ses_a", requestID: "frm_gone", answer: .answers(["q0": ["x"]]))
        }
        #expect(await server.requests("POST", "/api/session/ses_a/form/frm_gone/reply").count == 1)
        try await transport.close()
    }

    @Test("Minted ids follow OpenCode's format and sort newest first")
    func mintedIDs() {
        var minter = OpenCodeSessionID()
        let random = [UInt8](repeating: 61, count: 14)
        // ~(1794434916308 * 0x1000 + 1), low 48 bits: OpenCode's own encoding.
        #expect(minter.next(timestamp: 1_794_434_916_308, random: random) == "ses_e3358202bffezzzzzzzzzzzzzz")
        #expect(minter.next(timestamp: 1_794_434_916_308, random: random) == "ses_e3358202bffdzzzzzzzzzzzzzz")
        let older = OpenCodeSessionID.mint(now: Date(timeIntervalSince1970: 1_000))
        let newer = OpenCodeSessionID.mint(now: Date(timeIntervalSince1970: 2_000))
        #expect(newer < older)
        for id in [older, newer] {
            #expect(id.wholeMatch(of: /ses_[0-9a-f]{12}[0-9A-Za-z]{14}/) != nil)
        }
    }

    @Test("A create retried with the same id reuses the session and never repeats the first message")
    func createIdempotentOnRetry() async throws {
        let created = Mutex<JSONValue?>(nil)
        let (transport, server, _) = try await Self.open(Self.handler(sessions: { [] }, extra: { request in
            switch (request.method, request.route) {
            case ("POST", "/api/session"):
                let id = request.body?["id"]?.stringValue ?? ""
                let session = created.withLock { value in
                    // Repeating the same create returns the existing session (O11).
                    if value == nil { value = Self.session(id, dir: "/home/me/new", title: "Fix it",
                        extra: ["metadata": request.body?["metadata"] ?? .null]) }
                    return value ?? .null
                }
                return .json(.object(["data": session]))
            case ("POST", let route) where route.hasSuffix("/prompt"):
                return .json(.object(["data": .object(["id": .string("msg_p")])]))
            case ("GET", let route) where route.hasSuffix("/message"):
                return .json(.object(["data": .array([.object(["id": .string("msg_p"), "type": .string("user"),
                    "text": .string("first")])]), "cursor": .object([:])]))
            default: return nil
            }
        }))
        let id = OpenCodeSessionID.mint()
        var launch = OpenCodeSessionLaunch(sessionID: id, title: "Fix it", directory: "/home/me/new",
            model: .init(id: "mock-model", providerID: "mock"), firstMessage: "first")
        let first = try await transport.startSession(launch)
        launch.mayHaveStarted = true
        let retry = try await transport.startSession(launch)
        #expect(first.paneID == "opencode:\(id)" && retry.paneID == first.paneID)
        let creates = await server.requests("POST", "/api/session")
        #expect(creates.count == 2)
        #expect(creates.allSatisfy { $0.body == creates[0].body })
        #expect(creates[0].body == .object([
            "id": .string(id), "title": .string("Fix it"),
            "metadata": .object(["waycar": .object(["launch": .string(id), "origin": .string("waycar")])]),
            "location": .object(["directory": .string("/home/me/new")]),
            "model": .object(["id": .string("mock-model"), "providerID": .string("mock")])]))
        #expect(await server.requests("POST", "/api/session/\(id)/prompt").map(\.body) == [.object(["text": .string("first")])])
        let snapshot = try await transport.sessionSnapshot()
        #expect(snapshot.agents.map(\.paneID) == ["opencode:\(id)"])
        #expect(snapshot.workspaces.map(\.label) == ["new"])
        try await transport.close()
    }

    @Test("Closing an OpenCode card archives the session; unarchive lists it again")
    func archive() async throws {
        let (transport, server, _) = try await Self.open(Self.handler(sessions: { [Self.session("ses_a")] }, extra: { request in
            request.method == "PATCH" ? OpenCodeFakeResponse(status: 204, body: nil) : nil
        }))
        try await transport.closePane(PaneTarget(paneID: "opencode:ses_a"), closesWorktreeGroup: false)
        #expect(await server.requests("PATCH", "/api/session/ses_a").first?.body == .object(["archived": .bool(true)]))
        #expect(try await transport.sessionSnapshot().agents.isEmpty)
        // A Closed Session's Resume unarchives the session it names.
        let resumed = try await transport.startAgentInNewWorkspace(
            ServerChatBackend.opencode.resumeRequest(
                sessionID: "ses_a", name: "Task", cwd: "/home/me/proj", launchID: UUID()),
            workspace: NewWorkspaceSpec(directory: "/home/me/proj", label: nil))
        #expect(resumed.paneID == "opencode:ses_a")
        #expect(await server.requests("PATCH", "/api/session/ses_a").last?.body == .object(["archived": .bool(false)]))
        #expect(await server.requests("POST", "/api/session").isEmpty)
        #expect(try await transport.sessionSnapshot().agents.map(\.paneID) == ["opencode:ses_a"])
        try await transport.close()
    }

    @Test("Paging follows cursor.next, not the page size")
    func pagingOnCursor() async throws {
        let (transport, server, _) = try await Self.open(Self.handler(sessions: { [] }, extra: { request in
            switch (request.method, request.route) {
            case ("GET", "/api/session"):
                return request.query.contains("cursor=c1")
                    ? Self.list([Self.session("ses_c")], next: nil)
                    : Self.list([Self.session("ses_a"), Self.session("ses_b")], next: "c1")
            case ("GET", "/api/session/ses_a/message"):
                let older = request.query.contains("cursor=m1")
                return .json(.object([
                    "data": .array([.object(["id": .string(older ? "msg_1" : "msg_2"), "type": .string("user"),
                                             "text": .string(older ? "first" : "second")])]),
                    "cursor": .object(["next": older ? .null : .string("m1")])]))
            default: return nil
            }
        }))
        // Two short pages: the first had a next cursor, the second none.
        #expect(await server.requests("GET", "/api/session").filter { $0.query.contains("archived=false") }.count == 2)
        #expect(try await transport.sessionSnapshot().agents.map(\.paneID).sorted()
                == ["opencode:ses_a", "opencode:ses_b", "opencode:ses_c"])
        let chat = try await transport.readChatTranscript(ChatTranscriptRequest(
            paneID: "opencode:ses_a", kind: "opencode", sessionKind: nil, sessionValue: nil, cwd: nil,
            launchedAt: nil, status: nil, after: nil))
        #expect(await server.requests("GET", "/api/session/ses_a/message").map(\.query)
                == ["limit=100&order=desc", "limit=100&cursor=m1"])
        #expect(chat.messages.map(\.text) == ["first", "second"] && !chat.header.truncated)
        try await transport.close()
    }

    @Test("A descendant session's request shows on its top-level card and is answered in the child")
    func descendantRequests() async throws {
        let all = Mutex([
            Self.session("ses_root"),
            Self.session("ses_kid", extra: ["parentID": .string("ses_root")]),
            Self.session("ses_gk", extra: ["parentID": .string("ses_kid")])
        ])
        let active = Mutex(["ses_root", "ses_gk"])
        let shell: JSONValue = .object(["id": .string("per_gk"), "sessionID": .string("ses_gk"),
            "action": .string("shell"), "resources": .array([.string("make test")])])
        let (transport, server, _) = try await Self.open(Self.handler(
            sessions: { all.withLock { $0 } }, active: { active.withLock { $0 } },
            permissions: ["ses_gk": [shell]], extra: { request in
                request.route.hasSuffix("/reply") ? OpenCodeFakeResponse(status: 204, body: nil) : nil
            }))
        func status() async throws -> AgentStatus? {
            try await transport.sessionSnapshot().agents.first { $0.paneID == "opencode:ses_root" }?.agentStatus
        }
        // Only the top-level session is an Agent; the grandchild's approval blocks it.
        #expect(try await transport.sessionSnapshot().agents.map(\.paneID) == ["opencode:ses_root"])
        #expect(try await status() == .blocked)
        let pending = try await transport.pendingAgentRequests(target: "opencode:ses_root")
        #expect(pending == [AgentPendingRequest(id: "per_gk", kind: .command(
            command: "make test", cwd: "/home/me/proj", reason: nil))])
        try await transport.answerAgentRequest(target: "opencode:ses_root", requestID: "per_gk", answer: .allow)
        #expect(await server.requests("POST", "/api/session/ses_gk/permission/per_gk/reply").first?.body
                == .object(["decision": .string("once")]))
        #expect(await server.requests("POST", "/api/session/ses_root/permission/per_gk/reply").isEmpty)
        #expect(try await status() == .working)

        let stream = try await transport.subscribeToEvents([])
        // A child created now: its parent comes with the event, no read.
        await server.push("session.created", ["sessionID": .string("ses_new"), "parentID": .string("ses_root")])
        await server.push("session.execution.started", ["sessionID": .string("ses_new")])
        await server.push("form.created", ["form": .object(["id": .string("frm_n"), "sessionID": .string("ses_new"),
            "title": .string("Questions"), "metadata": .object(["kind": .string("question")]),
            "fields": .array([.object(["key": .string("q0"), "type": .string("string")])])])])
        try await waitUntil("the child's question blocks the top-level card") { try await status() == .blocked }
        #expect(await server.requests("GET", "/api/session/ses_new").isEmpty)
        await server.push("form.replied", ["id": .string("frm_n"), "sessionID": .string("ses_new")])
        try await waitUntil("answered at the desk clears it") { try await status() == .working }
        // A known grandchild asks again; its turn ending drops what it asked.
        await server.push("permission.asked", ["id": .string("per_2"), "sessionID": .string("ses_gk"),
            "action": .string("edit"), "resources": .array([.string("a.swift")])])
        try await waitUntil("the grandchild's edit blocks it") { try await status() == .blocked }
        await server.push("session.execution.interrupted", ["sessionID": .string("ses_gk")])
        try await waitUntil("the grandchild's end drops its request, the parent still runs") {
            try await status() == .working
        }
        await server.push("session.execution.succeeded", ["sessionID": .string("ses_root")])
        try await waitUntil("the top-level turn ends") { try await status() == .done }
        await stream.end()
        try await transport.close()
    }

    @Test("A child that outlives its parent's turn keeps the card Blocked until its requests resolve")
    func childOutlivesParentTurn() async throws {
        let sessions = [Self.session("ses_root"), Self.session("ses_kid", extra: ["parentID": .string("ses_root")])]
        func shell(_ id: String) -> JSONValue {
            .object(["id": .string(id), "sessionID": .string("ses_kid"), "action": .string("shell"),
                     "resources": .array([.string("make \(id)")])])
        }
        let (transport, server, _) = try await Self.open(Self.handler(
            sessions: { sessions }, active: { ["ses_root", "ses_kid"] },
            permissions: ["ses_kid": [shell("per_1"), shell("per_2")]], extra: { request in
                request.route.hasSuffix("/reply") ? OpenCodeFakeResponse(status: 204, body: nil) : nil
            }))
        func root() async throws -> AgentInfo? {
            try await transport.sessionSnapshot().agents.first { $0.paneID == "opencode:ses_root" }
        }
        #expect(try await root()?.agentStatus == .blocked)
        let stream = try await transport.subscribeToEvents([])
        // The parent's turn ends while its child still waits for an answer.
        await server.push("session.execution.succeeded", ["sessionID": .string("ses_root")])
        await server.push("session.renamed", ["sessionID": .string("ses_root"), "title": .string("Renamed")])
        try await waitUntil("both events are applied") { try await root()?.name == "Renamed" }
        #expect(try await root()?.agentStatus == .blocked)
        let pending = try await transport.pendingAgentRequests(target: "opencode:ses_root")
        #expect(pending.map(\.id) == ["per_1", "per_2"])
        #expect(try await root()?.agentStatus == .blocked)
        // Still answered in the child, from the root card.
        try await transport.answerAgentRequest(target: "opencode:ses_root", requestID: "per_1", answer: .allow)
        #expect(await server.requests("POST", "/api/session/ses_kid/permission/per_1/reply").first?.body
                == .object(["decision": .string("once")]))
        #expect(try await root()?.agentStatus == .blocked)
        // The other one is answered at the desk: the card is Done.
        await server.push("permission.replied", ["sessionID": .string("ses_kid"), "requestID": .string("per_2")])
        try await waitUntil("the child's last request resolves") { try await root()?.agentStatus == .done }
        await stream.end()
        try await transport.close()
    }

    @Test("Ping names OpenCode; the server's registered address is the one dialed")
    func pingAndDialedHost() async throws {
        let info: OpenCodeFakeServer.Handler = { request in
            request.route == "/api/info" ? .json(.object(["version": .string("2.2.7"), "pid": .number(7)]))
                : Self.handler(sessions: { [] })(request)
        }
        var anyAddress = Self.presence
        anyAddress.serverURL = "http://0.0.0.0:50123"
        let (wildcard, _, wildcardServices) = try await Self.open(info, presence: anyAddress)
        let ping = try await wildcard.ping()
        #expect(ping.backend == .opencode && ping.version == "2.2.7")
        #expect(Set(await wildcardServices.openCodeDials) == ["127.0.0.1:50123"])
        try await wildcard.close()
        var lan = Self.presence
        lan.serverURL = "http://10.0.0.5:50124"
        let (remote, _, remoteServices) = try await Self.open(info, presence: lan)
        #expect(Set(await remoteServices.openCodeDials) == ["10.0.0.5:50124"])
        try await remote.close()
        var stopped = Self.presence
        stopped.serverURL = nil
        stopped.registeredURL = "http://127.0.0.1:49374"
        await #expect(throws: TransportError.channelFailed(detail: "OpenCode's server is not running.")) {
            _ = try await OpenCodeTransport.open(session: FakeHostSSHServices(exec: { _, _ in
                FakeHostSSHServices.result(exitStatus: 1) }), presence: stopped)
        }
        #expect(OpenCodeEndpoint(url: "http://localhost:1") == OpenCodeEndpoint(host: "127.0.0.1", port: 1))
        #expect(OpenCodeEndpoint(url: "http://[::]:2") == OpenCodeEndpoint(host: "127.0.0.1", port: 2))
        #expect(OpenCodeEndpoint(url: "http://[::1]:3") == OpenCodeEndpoint(host: "::1", port: 3))
        #expect(OpenCodeEndpoint(url: "stopped") == nil)
    }

    // MARK: Pins: connection lifetime, stream, reconnect and re-list (OPENCODE-01, OPENCODE-02)

    @Test("Distrust refuses requests and ends events; only Close releases, once")
    func distrustThenClose() async throws {
        let (transport, _, services) = try await Self.open(Self.handler(sessions: { [Self.session("ses_a")] }))
        let stream = try await transport.subscribeToEvents([])
        await transport.transportDistrusted()
        for try await _ in stream.events {}
        #expect(!(await transport.isConnected))
        await #expect(throws: TransportError.cancelled) { _ = try await transport.sessionSnapshot() }
        await #expect(throws: TransportError.cancelled) { try await transport.abortAgentRun(target: "opencode:ses_a") }
        #expect(await services.releaseCount == 0)
        try await transport.close()
        try await transport.close()
        await transport.transportDistrusted()
        #expect(await services.releaseCount == 1)
    }

    @Test("A lost transport refuses requests as ended until distrusted or closed")
    func lostRefuses() async throws {
        let (transport, server, services) = try await Self.open(Self.handler(sessions: { [] }))
        let stream = try await transport.subscribeToEvents([])
        await server.refuseStreams(status: 503)
        await server.dropStream()
        await #expect(throws: TransportError.self) { for try await _ in stream.events {} }
        // The dropped stream and two refused ones: one per retry delay.
        #expect(await server.requests("GET", "/api/event").count == 3)
        let ended = TransportError.channelFailed(detail: "OpenCode ended its connection.")
        await #expect(throws: ended) { _ = try await transport.sessionSnapshot() }
        await #expect(throws: ended) { _ = try await transport.subscribeToEvents([]) }
        await transport.transportDistrusted()
        await #expect(throws: TransportError.cancelled) { _ = try await transport.sessionSnapshot() }
        #expect(await services.releaseCount == 0)
        try await transport.close()
        #expect(await services.releaseCount == 1)
    }

    @Test("A refused first stream fails the open at once and leaves the hold with the caller")
    func refusedFirstStream() async throws {
        let server = OpenCodeFakeServer(handler: Self.handler(sessions: { [] }))
        await server.refuseStreams(status: 503)
        let services = FakeHostSSHServices(exec: { _, _ in FakeHostSSHServices.result(stdout: #"{"password":"pw1"}"#) })
        await services.serveUltimate { _ in OpenCodeFakeChannel(server: server) }
        await #expect(throws: TransportError.self) {
            _ = try await OpenCodeTransport.open(session: services, presence: Self.presence,
                                                 retryDelays: [.milliseconds(20), .milliseconds(20)])
        }
        #expect(await server.requests("GET", "/api/event").count == 1)
        #expect(await server.requests("GET", "/api/session").isEmpty)
        #expect(await services.releaseCount == 0)
    }

    @Test("A complete re-list resets the retry budget")
    func retryBudgetResets() async throws {
        let (transport, server, _) = try await Self.open(Self.handler(sessions: { [Self.session("ses_a")] }))
        let stream = try await transport.subscribeToEvents([])
        for round in 1...2 {
            await server.refuseNextStreams(1, status: 503)
            await server.dropStream()
            try await waitUntil("round \(round) re-lists") {
                await server.requests("GET", "/api/session/active").count == round + 1
            }
        }
        #expect(await transport.isConnected)
        #expect(await server.requests("GET", "/api/event").count == 5)
        await stream.end()
        try await transport.close()
    }

    @Test("A 401 on the stream re-reads the password once per complete re-list; two in a row lose it")
    func streamUnauthorized() async throws {
        let accepted = Mutex("pw1")
        let sessions = Self.handler(sessions: { [Self.session("ses_a")] })
        let (transport, server, services) = try await Self.open({ request in
            request.headers["authorization"] == Self.basic(accepted.withLock { $0 })
                ? sessions(request) : OpenCodeFakeResponse(status: 401, body: #"{"_tag":"UnauthorizedError"}"#)
        }, passwords: ["pw1", "pw2", "pw3"])
        let stream = try await transport.subscribeToEvents([])
        for (round, password) in ["pw2", "pw3"].enumerated() {
            accepted.withLock { $0 = password }
            await server.dropStream()
            try await waitUntil("re-listed with \(password)") {
                await server.requests("GET", "/api/session/active").count == round + 2
            }
        }
        #expect(await services.execs(containing: "service.json").count == 3)
        // Refused again right after its re-read: the stream is lost.
        accepted.withLock { $0 = "never" }
        await server.dropStream()
        await #expect(throws: TransportError.apiRejected(code: "opencode_unauthorized",
            message: "The OpenCode server refused its password.")) { for try await _ in stream.events {} }
        #expect(await services.execs(containing: "service.json").count == 4)
        #expect(!(await transport.isConnected))
        try await transport.close()
    }

    @Test("A re-list that fails is retried on a new stream")
    func failedRelistRetries() async throws {
        let failing = Mutex(false)
        let (transport, server, _) = try await Self.open(Self.handler(sessions: { [Self.session("ses_a")] }, extra: { request in
            guard request.route == "/api/session/active",
                  failing.withLock({ value in defer { value = false }; return value }) else { return nil }
            return OpenCodeFakeResponse(status: 500, body: #"{"_tag":"InternalError","message":"boom"}"#)
        }))
        let stream = try await transport.subscribeToEvents([])
        failing.withLock { $0 = true }
        await server.pushConnected()
        try await waitUntil("a new stream re-lists") {
            await server.requests("GET", "/api/session/active").count == 3
        }
        #expect(await server.requests("GET", "/api/event").count == 2)
        #expect(await transport.isConnected)
        await stream.end()
        try await transport.close()
    }

    // MARK: Pins: session activity and Done (OPENCODE-04)

    @Test("A failed or interrupted turn is Done until viewed; a re-list takes the server's own times")
    func turnEndsAndRelist() async throws {
        let listed = Mutex([Self.session("ses_a", idle: 100, viewed: 100)])
        let (transport, server, _) = try await Self.open(Self.handler(sessions: { listed.withLock { $0 } }, extra: { request in
            request.route == "/api/session/ses_a/view" ? OpenCodeFakeResponse(status: 204, body: nil) : nil
        }))
        let stream = try await transport.subscribeToEvents([])
        func status() async throws -> AgentStatus? { try await transport.sessionSnapshot().agents.first?.agentStatus }
        #expect(try await status() == .idle)
        // Seen already: opening it posts nothing.
        try await transport.focusAgent(AgentTarget(target: "opencode:ses_a"))
        #expect(await server.requests("POST", "/api/session/ses_a/view").isEmpty)
        for (end, created) in [("session.execution.failed", 5_000.0), ("session.execution.interrupted", 6_000)] {
            await server.push("session.execution.started", ["sessionID": .string("ses_a")])
            try await waitUntil("\(end): started is Working") { try await status() == .working }
            await server.push(end, ["sessionID": .string("ses_a")], created: created)
            try await waitUntil("\(end) is Done") { try await status() == .done }
        }
        try await transport.focusAgent(AgentTarget(target: "opencode:ses_a"))
        #expect(await server.requests("POST", "/api/session/ses_a/view").map(\.body) == [.object(["idle": .number(6_000)])])
        #expect(try await status() == .idle)
        // An unseen result the server reports comes back with the re-list.
        listed.withLock { $0 = [Self.session("ses_a", idle: 7_000, viewed: 6_000)] }
        await server.pushConnected()
        try await waitUntil("the re-list's idle is Done") { try await status() == .done }
        await stream.end()
        try await transport.close()
    }

    /// B-38. Live, OpenCode 2.2.7 (2026-11-12, scratch server): a rejected
    /// permission ends the turn with `session.execution.interrupted`
    /// `{reason: "shutdown"}` and writes no `time.idle`; `/interrupt` sends
    /// `{reason: "user"}` and writes `time.idle` at the event's `created`.
    @Test("A turn ended by a rejected approval is Idle, not Done, and posts no view")
    func rejectedApprovalIsNotDone() async throws {
        let (transport, server, _) = try await Self.open(Self.handler(
            sessions: { [Self.session("ses_a", idle: 100, viewed: 100)] }, extra: { request in
                request.route == "/api/session/ses_a/view" ? OpenCodeFakeResponse(status: 204, body: nil) : nil
            }))
        let stream = try await transport.subscribeToEvents([])
        func status() async throws -> AgentStatus? { try await transport.sessionSnapshot().agents.first?.agentStatus }
        await server.push("session.execution.started", ["sessionID": .string("ses_a")])
        try await waitUntil("started is Working") { try await status() == .working }
        await server.push("session.execution.interrupted", ["sessionID": .string("ses_a"), "reason": .string("shutdown")],
                          created: 5_000)
        try await waitUntil("the rejected turn ended") { try await status() != .working }
        #expect(try await status() == .idle)
        try await transport.focusAgent(AgentTarget(target: "opencode:ses_a"))
        #expect(await server.requests("POST", "/api/session/ses_a/view").isEmpty)
        await stream.end()
        try await transport.close()
    }

    /// B-41: a 401 re-reads the password; Close lands while that read runs.
    @Test("A password re-read that finishes after Close is not kept")
    func rereadAfterCloseIsNotKept() async throws {
        let (transport, server, services) = try await Self.open(Self.handler(sessions: { [Self.session("ses_a")] }))
        #expect(await transport.holdsServerPassword)
        await server.setHandler { _ in OpenCodeFakeResponse(status: 401, body: #"{"_tag":"UnauthorizedError"}"#) }
        let (entered, enteredInput) = AsyncStream<Void>.makeStream()
        let (release, releaseInput) = AsyncStream<Void>.makeStream()
        await services.holdNextExec(containing: "service.json", entered: enteredInput, until: release)
        let aborting = Task { try await transport.abortAgentRun(target: "opencode:ses_a") }
        var reads = entered.makeAsyncIterator()
        _ = await reads.next()
        try await transport.close()
        #expect(!(await transport.holdsServerPassword))
        releaseInput.yield(())
        await #expect(throws: TransportError.self) { try await aborting.value }
        #expect(!(await transport.holdsServerPassword))
    }

    @Test("Loopback requests carry extra headers and PATCH bodies; Ultimate's stay as before")
    func clientHeaders() throws {
        let client = UltimateHTTPClient(port: 49374, openChannel: { throw CancellationError() })
        let bytes = try client.requestBytes(method: "PATCH", path: "/api/session/ses_a", body: Data("{}".utf8),
                                            headers: [("Authorization", "Basic b3BlbmNvZGU6cHc=")])
        #expect(String(decoding: bytes, as: UTF8.self) == "PATCH /api/session/ses_a HTTP/1.1\r\nHost: 127.0.0.1:49374\r\nConnection: close\r\nAccept: application/json, text/event-stream\r\nAuthorization: Basic b3BlbmNvZGU6cHc=\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}")
        #expect(throws: UltimateHTTPError.invalidRequest) {
            try client.requestBytes(method: "GET", path: "/", body: nil, headers: [("X", "a\r\nInjected: 1")])
        }
        #expect(throws: UltimateHTTPError.invalidRequest) {
            try client.requestBytes(method: "TRACE", path: "/", body: nil)
        }
    }

    /// The 2.2.7 export's `messages` (same item shapes as `/message`, O15),
    /// oldest first, with token and cost fields left out.
    static let exportMessages = #"[{"id":"msg_1cca7dff9001nxML8t7SJGmNtS","time":{"created":1794434916718},"text":"hello fixture","type":"user"},{"id":"msg_1cca7e1780014OZXVGyc2jAqLp","time":{"created":1794434916739,"streamed":1794434922764,"completed":1794434922765},"type":"assistant","agent":"build","model":{"id":"mock-model","providerID":"mock"},"content":[{"type":"text","text":"waycar-mock-reply: fixture"}],"finish":"stop"},{"id":"msg_1cca7f90f001fxexPZivM1VmTB","time":{"created":1794434922767},"type":"idle","outcome":"succeeded"},{"id":"msg_1cca7f9190011VC6GfMsbN803w","time":{"created":1794434922783},"text":"run it WAYCAR_TOOL","type":"user"},{"id":"msg_1cca7f922001b2CVCUiuCmp9Po","time":{"created":1794434922789,"streamed":1794434924302,"completed":1794434926809},"type":"assistant","agent":"build","model":{"id":"mock-model","providerID":"mock"},"content":[{"type":"tool","id":"call_waycar_2","name":"shell","executed":false,"state":{"status":"completed","input":{"command":"echo waycar-tool-ok"},"content":[{"type":"text","text":"waycar-tool-ok\n"}],"metadata":{"status":"completed","truncated":false,"exit":0}},"time":{"created":1794434924297,"ran":1794434924301,"completed":1794434926807}}],"finish":"tool-calls"},{"id":"msg_1cca808de001vNWV2M849aWsuL","time":{"created":1794434926816,"streamed":1794434928328,"completed":1794434928329},"type":"assistant","agent":"build","model":{"id":"mock-model","providerID":"mock"},"content":[{"type":"text","text":"waycar-tool-done: saw waycar-tool-ok"}],"finish":"stop"},{"id":"msg_1cca80ecb001jtJz3v3OqoLDsw","time":{"created":1794434928331},"type":"idle","outcome":"succeeded"},{"id":"msg_1cca810be001Ne357kvzR3WKPy","time":{"created":1794434928834},"text":"run again WAYCAR_TOOL","type":"user"},{"id":"msg_1cca810c6001EjcVtOWfQUGO9E","time":{"created":1794434928841,"streamed":1794434930357,"completed":1794434932854},"type":"assistant","agent":"build","model":{"id":"mock-model","providerID":"mock"},"content":[{"type":"tool","id":"call_waycar_5","name":"shell","executed":false,"state":{"status":"error","input":{"command":"echo waycar-tool-ok"},"error":{"type":"aborted","message":"The user declined this tool call"}},"time":{"created":1794434930352,"ran":1794434930355,"completed":1794434932852}}],"finish":"error","error":{"type":"aborted","message":"Step interrupted"}},{"id":"msg_1cca82474001iqQwdwuox0jX12","time":{"created":1794434933880},"text":"ask WAYCAR_ASK","type":"user"},{"id":"msg_1cca8247d001CAtTcuLJs60o0x","time":{"created":1794434933887,"streamed":1794434935425,"completed":1794434937900},"type":"assistant","agent":"build","model":{"id":"mock-model","providerID":"mock"},"content":[{"type":"tool","id":"call_waycar_7","name":"question","executed":false,"state":{"status":"completed","input":{"questions":[{"question":"Pick a color","header":"Color","options":[{"label":"Red","description":"warm"},{"label":"Blue","description":"cool"}],"multiple":false}]},"content":[{"type":"text","text":"User has answered your questions: \"Pick a color\"=\"Blue\". You can now continue with the user's answers in mind."}],"metadata":{"answers":[["Blue"]],"truncated":false}},"time":{"created":1794434935396,"ran":1794434935423,"completed":1794434937898}}],"finish":"tool-calls"},{"id":"msg_1cca83431001R6dvwAoL6Urqub","time":{"created":1794434937908,"streamed":1794434939421,"completed":1794434939421},"type":"assistant","agent":"build","model":{"id":"mock-model","providerID":"mock"},"content":[{"type":"text","text":"waycar-tool-done: tool output missing waycar-tool-ok"}],"finish":"stop"},{"id":"msg_1cca83a1f001GWX9iX6MMpojLV","time":{"created":1794434939423},"type":"idle","outcome":"succeeded"},{"id":"msg_1cca83c21001oNEhmy6PGxcfqA","time":{"created":1794434939969},"text":"look at this image","files":[{"data":"iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGP4z8AARAwQCgAf7gP9i18U1AAAAABJRU5ErkJggg==","mime":"image/png","source":{"type":"inline"},"name":"red.png"}],"type":"user"},{"id":"msg_1cca83c44001mx1EtTIKyUWJQi","time":{"created":1794434939975,"streamed":1794434941486,"completed":1794434941487},"type":"assistant","agent":"build","model":{"id":"mock-model","providerID":"mock"},"content":[{"type":"text","text":"waycar-mock-reply: image"}],"finish":"stop"},{"id":"msg_1cca84231001qiREIsH7JITgTu","time":{"created":1794434941489},"type":"idle","outcome":"succeeded"},{"id":"msg_1cca8441e001NcbVjcvvDSJ9A8","time":{"created":1794434941987},"text":"slow WAYCAR_SLOW","type":"user"},{"id":"msg_1cca844270018robz36zLRWDzt","time":{"created":1794434941994,"completed":1794434944995},"type":"assistant","agent":"build","model":{"id":"mock-model","providerID":"mock"},"content":[],"finish":"error","error":{"type":"aborted","message":"Step interrupted"}},{"id":"msg_1cca84fe4001yJAygqhcjzW5rY","time":{"created":1794434944996},"type":"idle","outcome":"interrupted"}]"#
}

@Suite("OpenCode server start")
struct OpenCodeServerCommandTests {
    @Test func plainStartExecsTheDetectedBinary() {
        let start = OpenCodeServerCommand.start(
            path: "/home/me/.opencode/bin/opencode", loginPATH: "/login/bin:/usr/bin", inLoginSession: false)
        #expect(start.command.contains("exec \"$p\" service start"))
        #expect(start.command.contains("$HOME/.opencode/bin"))
        #expect(start.command.contains(ShellWord.quoted("/home/me/.opencode/bin/opencode")))
        #expect(start.command.contains(ShellWord.quoted("/login/bin:/usr/bin")))
        #expect(!start.command.contains("launchctl") && !start.command.contains("LC_ALL"))
        #expect(start.input.isEmpty)
    }

    @Test func loginStartRunsAsTheSharedOneShotJob() {
        let start = OpenCodeServerCommand.start(
            path: "/opt/homebrew/bin/opencode", loginPATH: nil, inLoginSession: true)
        let job = String(decoding: start.input, as: UTF8.self)
        #expect(start.command.contains("launchctl bootstrap") && start.command.contains("Interactive"))
        #expect(start.command.contains("XDG_STATE_HOME"))
        #expect(start.command.contains("exec \"$p\" service start")) // fallback without launchd
        #expect(job.contains("unset WAYCAR_OPENCODE_PATH") && job.contains("service start"))
        #expect(job.contains("cd \"$HOME\""))
    }

    @Test func aFailedStartKeepsOpenCodesWords() throws {
        try OpenCodeServerCommand.validateStart(
            exitStatus: 0, reachedEOF: true, stdout: Data("http://127.0.0.1:49374\n".utf8), stderr: Data())
        #expect(throws: HerdrStartError(output: "port in use")) {
            try OpenCodeServerCommand.validateStart(
                exitStatus: 1, reachedEOF: true, stdout: Data(), stderr: Data("port in use\n".utf8))
        }
    }
}

// MARK: Fake OpenCode server

struct OpenCodeFakeRequest: Sendable {
    let method: String
    let route: String
    let query: String
    /// Lowercase names.
    let headers: [String: String]
    let body: JSONValue?
}

struct OpenCodeFakeResponse: Sendable {
    let status: Int
    let body: String?

    static func json(_ value: JSONValue) -> OpenCodeFakeResponse {
        OpenCodeFakeResponse(status: 200, body: String(decoding: (try? JSONEncoder().encode(value)) ?? Data(), as: UTF8.self))
    }
}

final class PasswordBox: Sendable {
    private let passwords: Mutex<[String]>
    init(_ passwords: [String]) { self.passwords = Mutex(passwords) }
    /// Each read returns the next password; the last one stays.
    func next() -> String {
        passwords.withLock { list in list.count > 1 ? list.removeFirst() : (list.first ?? "") }
    }
}

actor OpenCodeChangeProbe {
    private(set) var changes = 0
    func changed() { changes += 1 }
}

/// Answers each loopback channel's one request through `handler`; an
/// `/api/event` request becomes a stream the test pushes frames into.
actor OpenCodeFakeServer {
    typealias Handler = @Sendable (OpenCodeFakeRequest) -> OpenCodeFakeResponse
    private(set) var requests: [OpenCodeFakeRequest] = []
    private var handler: Handler
    private var refusedStreamStatus: Int?
    private var refusedStreams: (count: Int, status: Int)?
    private var streams: [OpenCodeFakeChannel] = []
    private var eventNumber = 0

    init(handler: @escaping Handler) { self.handler = handler }

    func setHandler(_ handler: @escaping Handler) { self.handler = handler }
    func refuseStreams(status: Int) { refusedStreamStatus = status }
    /// Refuses only the next `count` stream requests.
    func refuseNextStreams(_ count: Int, status: Int) { refusedStreams = (count, status) }

    func requests(_ method: String, _ route: String) -> [OpenCodeFakeRequest] {
        requests.filter { $0.method == method && $0.route == route }
    }

    func respond(_ request: OpenCodeFakeRequest, channel: OpenCodeFakeChannel) -> (Data, streaming: Bool) {
        requests.append(request)
        if request.route == "/api/event" {
            var refused = refusedStreamStatus
            if let next = refusedStreams, next.count > 0 {
                refused = next.status
                refusedStreams = (next.count - 1, next.status)
            }
            let status = refused ?? (handler(request).status == 401 ? 401 : 200)
            guard status == 200 else { return (Self.http(status, #"{"_tag":"UnauthorizedError"}"#), false) }
            streams.append(channel)
            let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\n\r\n"
            return (Data((head + connectedFrame() + ": heartbeat\n\n").utf8), true)
        }
        let response = handler(request)
        return (Self.http(response.status, response.body), false)
    }

    private func connectedFrame() -> String {
        eventNumber += 1
        return "data: {\"id\":\"evt_c\(eventNumber)\",\"type\":\"server.connected\",\"data\":{}}\n\n"
    }

    func push(_ type: String, _ data: [String: JSONValue], created: Double = 1_794_434_950_000) async {
        eventNumber += 1
        var event: [String: JSONValue] = ["id": .string("evt_\(eventNumber)"), "created": .number(created),
                                          "type": .string(type), "data": .object(data)]
        if type.hasPrefix("session.") {
            event["durable"] = .object(["aggregateID": data["sessionID"] ?? .null, "seq": .number(Double(eventNumber)),
                                        "version": .number(1)])
        }
        let json = String(decoding: (try? JSONEncoder().encode(JSONValue.object(event))) ?? Data(), as: UTF8.self)
        await streams.last?.push(Data("data: \(json)\n\n".utf8))
    }

    func pushConnected() async {
        await streams.last?.push(Data(connectedFrame().utf8))
    }

    func dropStream() async { await streams.last?.end() }

    private static func http(_ status: Int, _ body: String?) -> Data {
        guard let body else { return Data("HTTP/1.1 \(status) No Content\r\n\r\n".utf8) }
        return Data("HTTP/1.1 \(status) OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)
    }
}

actor OpenCodeFakeChannel: UltimateByteChannel {
    let server: OpenCodeFakeServer
    private var input = Data()
    private var output: [Data] = []
    private var streaming = false
    private var ended = false
    private var answered = false
    private(set) var closed = false

    init(server: OpenCodeFakeServer) { self.server = server }

    func write(_ data: Data, timeout: Duration) async {
        input.append(data)
        guard !answered, let headEnd = input.range(of: Data("\r\n\r\n".utf8)) else { return }
        let lines = String(decoding: input[..<headEnd.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let start = (lines.first ?? "").split(separator: " ").map(String.init)
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = input[headEnd.upperBound...]
        guard body.count >= length, start.count >= 2 else { return }
        answered = true
        let target = start[1].split(separator: "?", maxSplits: 1).map(String.init)
        let request = OpenCodeFakeRequest(
            method: start[0], route: target[0], query: target.count > 1 ? target[1] : "", headers: headers,
            body: length > 0 ? try? JSONDecoder().decode(JSONValue.self, from: Data(body.prefix(length))) : nil)
        let (response, streaming) = await server.respond(request, channel: self)
        self.streaming = streaming
        output.append(response)
    }

    func read(maximumBytes: Int, timeout: Duration) async throws -> Data? {
        while true {
            if !output.isEmpty { return output.removeFirst() }
            if !streaming || ended || closed { return nil }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func push(_ data: Data) { output.append(data) }
    func end() { ended = true }
    func close(timeout: Duration) { closed = true }
}
