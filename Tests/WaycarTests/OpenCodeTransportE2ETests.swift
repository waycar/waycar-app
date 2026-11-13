import CryptoKit
import Foundation
import Synchronization
import Testing
import WaycarSSH

@testable import Waycar

/// The pinned real OpenCode 2 server behind CI's disposable user-mode sshd,
/// reached as the app reaches it: the password over SSH exec, HTTP and the
/// event stream over direct-tcpip. The fixture owns HOME and every XDG
/// directory, the server's port and the model stand-in; nothing here
/// resolves the developer's OpenCode or touches their server.
@Suite(
    "OpenCode Transport e2e",
    .enabled(if: OpenCodeE2EEnvironment.current != nil, "requires the disposable OpenCode SSH fixture"),
    .serialized)
struct OpenCodeTransportE2ETests {
    @Test("the password comes from the Host's registration over SSH and Basic auth reaches the server")
    func openAndPing() async throws {
        try await withHost { host in
            let refused = try await host.api("GET", "/api/info", authorized: false)
            #expect(refused.status == 401)
            #expect(refused.body?["_tag"]?.stringValue == "UnauthorizedError")
            try await withTransport(host) { transport, _ in
                let info = try await transport.ping()
                #expect(info.version == host.environment.version)
                #expect(await transport.isConnected)
            }
            var missing = host.environment.presence
            missing.registrationPath = "~/.local/state/opencode/missing.json"
            let session = try await HostSSHSession.dial(settings: host.environment.settings())
            let error = await #expect(throws: TransportError.self) {
                _ = try await OpenCodeTransport.open(session: session, presence: missing)
            }
            await session.release()
            guard case .apiRejected(let code, _)? = error else {
                Issue.record("expected opencode_password_unavailable, got \(String(describing: error))")
                return
            }
            #expect(code == "opencode_password_unavailable")
        }
    }

    @Test("every unarchived top-level session is an Agent, one Workspace per folder, desk sessions included")
    func inventory() async throws {
        try await withHost { host in
            let first = host.environment.home + "/inv-a"
            let second = host.environment.home + "/inv-b"
            _ = try await host.shell("mkdir -p \(ShellWord.quoted(first)) \(ShellWord.quoted(second))")
            var desk = ""
            var archived = ""
            try await withTransport(host) { transport, _ in
                _ = try await launch(transport, host, directory: first)
                _ = try await launch(transport, host, directory: first)
                _ = try await launch(transport, host, directory: second)
                desk = try await host.createDeskSession(directory: second)
                archived = try await host.createDeskSession(directory: first)
                try await host.expectStatus(204, try await host.api(
                    "PATCH", "/api/session/\(archived)", .object(["archived": .bool(true)])))
                try await eventually("the stream lists the desk session and drops the archived one") {
                    let ids = try await transport.sessionSnapshot().agents.map(\.paneID)
                    return ids.contains("opencode:\(desk)") && !ids.contains("opencode:\(archived)")
                }
                try await expectInventory(transport, host)
            }
            // A fresh transport's first read lists the same sessions.
            try await withTransport(host) { transport, _ in
                let snapshot = try await expectInventory(transport, host)
                let row = try #require(snapshot.agents.first { $0.paneID == "opencode:\(desk)" })
                #expect(row.cwd == second && row.name == "desk")
                #expect(!snapshot.agents.contains { $0.paneID == "opencode:\(archived)" })
                let rows = snapshot.agents.filter { $0.cwd == first }
                let workspace = try #require(snapshot.workspaces.first { $0.workspaceID == "opencode:cwd:\(first)" })
                #expect(rows.count == 2 && workspace.paneCount == 2 && workspace.label == "inv-a")
                #expect(rows.allSatisfy { $0.workspaceID == workspace.workspaceID })
            }
        }
    }

    @Test("a held prompt is Working until the model answers, then Done, with prompt and reply in the transcript")
    func promptRoundTrip() async throws {
        try await withHost { host in
            try await withTransport(host) { transport, feed in
                let agent = try await launch(transport, host)
                let prompt = "WAYCAR_HOLD WAYCAR_ROUND_TRIP \(token())"
                _ = try await transport.promptAgent(AgentPromptParams(target: agent.paneID, text: prompt))
                try await feed.wait(for: agent.paneID, status: .working)
                let hold = try await host.waitForHold(prompt)
                #expect(try await status(transport, agent.paneID) == .working)
                #expect(try await host.release(hold))
                try await feed.wait(for: agent.paneID, status: .done)
                let statuses = feed.statuses(for: agent.paneID)
                let working = try #require(statuses.firstIndex(of: .working))
                #expect(working < (statuses.lastIndex(of: .done) ?? -1))
                let transcript = try await transport.readChatTranscript(transcriptRequest(agent.paneID))
                #expect(transcript.messages.contains { $0.role == .user && $0.text == prompt })
                #expect(transcript.messages.contains {
                    $0.role == .assistant && $0.text.contains("waycar-mock-reply: WAYCAR_HOLD WAYCAR_ROUND_TRIP")
                })
                #expect(!transcript.header.turnOpen)
            }
        }
    }

    @Test("Stop interrupts a held turn: no longer Working and the transcript ends quietly")
    func stopInterrupts() async throws {
        try await withHost { host in
            try await withTransport(host) { transport, feed in
                let agent = try await launch(transport, host)
                let prompt = "WAYCAR_HOLD WAYCAR_STOP \(token())"
                _ = try await transport.promptAgent(AgentPromptParams(target: agent.paneID, text: prompt))
                try await feed.wait(for: agent.paneID, status: .working)
                let hold = try await host.waitForHold(prompt)
                try await transport.abortAgentRun(target: agent.paneID)
                try await eventually("Stop ended the turn") {
                    let state = try await status(transport, agent.paneID)
                    return state != nil && state != .working
                }
                _ = try await host.release(hold)  // the interrupt may already have dropped it
                let newest = try await host.messages(sessionID(agent)).first
                #expect(newest?["type"]?.stringValue == "idle" && newest?["outcome"]?.stringValue == "interrupted")
                let transcript = try await transport.readChatTranscript(transcriptRequest(agent.paneID))
                #expect(!transcript.header.turnOpen)
                #expect(transcript.messages.contains { $0.role == .user && $0.text == prompt })
                #expect(!transcript.messages.contains { $0.role == .assistant && !$0.text.isEmpty })
                #expect(!transcript.messages.contains { if case .failure = $0.card { true } else { false } })
            }
        }
    }

    @Test("a shell permission is Blocked until Allow, the turn completes, and a second answer is refused")
    func commandApproval() async throws {
        try await withHost { host in
            try await withTransport(host) { transport, feed in
                let agent = try await launch(transport, host)
                let request = try await approval(transport, feed, agent.paneID)
                guard case .command(let command, let cwd, _) = request.kind else {
                    Issue.record("expected a command approval, got \(request.kind)")
                    return
                }
                #expect(command == "echo waycar-tool-ok")
                #expect(cwd == host.environment.project)
                try await transport.answerAgentRequest(target: agent.paneID, requestID: request.id, answer: .allow)
                try await feed.wait(for: agent.paneID, status: .done)
                let statuses = feed.statuses(for: agent.paneID)
                let blocked = try #require(statuses.firstIndex(of: .blocked))
                #expect(blocked < (statuses.lastIndex(of: .done) ?? -1))
                let transcript = try await transport.readChatTranscript(transcriptRequest(agent.paneID))
                #expect(transcript.messages.contains {
                    $0.role == .assistant && $0.text.contains("waycar-tool-done: saw waycar-tool-ok")
                })
                let error = await #expect(throws: TransportError.self) {
                    try await transport.answerAgentRequest(target: agent.paneID, requestID: request.id, answer: .allow)
                }
                guard case .apiRejected(let code, _)? = error else {
                    Issue.record("expected agent_request_resolved, got \(String(describing: error))")
                    return
                }
                #expect(code == "agent_request_resolved")
                let id = try sessionID(agent)
                let late = try await host.api("POST", "/api/session/\(id)/permission/\(request.id)/reply",
                                              .object(["decision": .string("once")]))
                #expect(late.status == 404 && late.body?["_tag"]?.stringValue == "PermissionNotFoundError")
            }
        }
    }

    @Test("Cancel on a shell permission ends the turn without an idle item, and nothing hangs")
    func commandRejected() async throws {
        try await withHost { host in
            try await withTransport(host) { transport, feed in
                let agent = try await launch(transport, host)
                let request = try await approval(transport, feed, agent.paneID)
                try await transport.answerAgentRequest(target: agent.paneID, requestID: request.id, answer: .cancel)
                try await eventually("the rejected turn ended") {
                    let state = try await status(transport, agent.paneID)
                    return state != nil && state != .working && state != .blocked
                }
                let id = try sessionID(agent)
                #expect(try await host.activeSessionIDs().contains(id) == false)
                #expect(try await host.messages(id).contains { $0["type"]?.stringValue == "idle" } == false)
                let transcript = try await transport.readChatTranscript(transcriptRequest(agent.paneID))
                #expect(!transcript.header.turnOpen)
                #expect(transcript.messages.contains { $0.role == .user && $0.text == "WAYCAR_TOOL" })
                #expect(!transcript.messages.contains { if case .failure = $0.card { true } else { false } })
                #expect(try await transport.pendingAgentRequests(target: agent.paneID).isEmpty)
            }
        }
    }

    @Test("the question tool shows as a questions card and the answer Blue completes the turn")
    func question() async throws {
        try await withHost { host in
            try await withTransport(host) { transport, feed in
                let agent = try await launch(transport, host)
                _ = try await transport.promptAgent(AgentPromptParams(target: agent.paneID, text: "WAYCAR_ASK"))
                try await feed.wait(for: agent.paneID, status: .blocked)
                let request = try await eventuallyValue("Blocked had no pending question") {
                    try await transport.pendingAgentRequests(target: agent.paneID).first
                }
                guard case .questions(let card) = request.kind else {
                    Issue.record("expected a questions card, got \(request.kind)")
                    return
                }
                let field = try #require(card.questions.first)
                #expect(card.questions.count == 1 && field.ref == "q0" && field.kind == "choice")
                #expect(field.options.map(\.label) == ["Red", "Blue"])
                try await transport.answerAgentRequest(
                    target: agent.paneID, requestID: request.id, answer: .answers(["q0": ["Blue"]]))
                try await feed.wait(for: agent.paneID, status: .done)
                #expect(try await host.messages(sessionID(agent)).first?["outcome"]?.stringValue == "succeeded")
                #expect(try await transport.pendingAgentRequests(target: agent.paneID).isEmpty)
            }
        }
    }

    @Test("a launch retried with its minted id after a lost answer makes one session and one first message")
    func launchIdempotent() async throws {
        try await withHost { host in
            try await withTransport(host) { transport, feed in
                let id = OpenCodeSessionID.mint()
                let message = "WAYCAR_LAUNCH_ONCE \(token())"
                let launch = OpenCodeSessionLaunch(sessionID: id, title: "e2e-launch", directory: host.environment.project,
                                                   firstMessage: message)
                let first = try await transport.startSession(launch)
                var retry = launch
                retry.mayHaveStarted = true
                let second = try await transport.startSession(retry)
                #expect(first.paneID == "opencode:\(id)" && second.paneID == first.paneID)
                try await feed.wait(for: first.paneID, status: .done)
                let listed = try await host.sessions("limit=200").filter { $0["id"]?.stringValue == id }
                #expect(listed.count == 1)
                #expect(listed.first?["metadata"]?["waycar"]?["launch"]?.stringValue == id)
                let prompts = try await host.messages(id).filter {
                    $0["type"]?.stringValue == "user" && $0["text"]?.stringValue == message
                }
                #expect(prompts.count == 1)
                #expect(try await transport.sessionSnapshot().agents.filter { $0.paneID == first.paneID }.count == 1)
            }
        }
    }

    @Test("Archive removes the session from the inventory and unarchive brings it back")
    func archiveAndUnarchive() async throws {
        try await withHost { host in
            var paneID = ""
            try await withTransport(host) { transport, _ in
                let agent = try await launch(transport, host)
                paneID = agent.paneID
                // The Agent's Archive action (its card's close).
                try await transport.closePane(PaneTarget(paneID: agent.paneID), closesWorktreeGroup: false)
                #expect(try await status(transport, agent.paneID) == nil)
            }
            let id = String(paneID.dropFirst("opencode:".count))
            #expect(try await host.sessions("parentID=null&archived=false&limit=200")
                .contains { $0["id"]?.stringValue == id } == false)
            let record = try await host.api("GET", "/api/session/\(id)")
            #expect(record.body?["data"]?["time"]?["archived"]?.codexNumber != nil)
            // A fresh first read leaves it out too; a Closed Session's Resume brings it back.
            try await withTransport(host) { transport, _ in
                #expect(try await status(transport, paneID) == nil)
                try await transport.setArchived(sessionID: id, false)
                #expect(try await status(transport, paneID) != nil)
            }
            #expect(try await host.sessions("parentID=null&archived=false&limit=200")
                .contains { $0["id"]?.stringValue == id })
            try await withTransport(host) { transport, _ in
                let state = try await status(transport, paneID)
                #expect(state == .idle)
            }
        }
    }

    @Test("after a server restart the stream comes back, re-reads the inventory and drops cancelled requests")
    func serverRestart() async throws {
        try await withHost { host in
            try await withTransport(host) { transport, feed in
                let blocked = try await launch(transport, host)
                let request = try await approval(transport, feed, blocked.paneID)
                let running = try await launch(transport, host)
                let prompt = "WAYCAR_HOLD WAYCAR_RESTART \(token())"
                _ = try await transport.promptAgent(AgentPromptParams(target: running.paneID, text: prompt))
                try await feed.wait(for: running.paneID, status: .working)
                let hold = try await host.waitForHold(prompt)
                let before = try await host.serverPID()
                try await host.restart()
                #expect(try await host.serverPID() != before)
                // Only a reconnected stream (its event or its re-list) can show this one.
                let desk = try await host.createDeskSession(directory: host.environment.project)
                try await eventually("the reconnected transport lists a session created after the restart") {
                    try await status(transport, "opencode:\(desk)") != nil
                }
                #expect(try await status(transport, blocked.paneID) != nil)
                #expect(try await status(transport, running.paneID) != nil)
                let blockedID = try sessionID(blocked)
                try await eventually("the re-read matches the server's pending requests") {
                    let pending = try await host.permissionIDs(blockedID)
                    let state = try await status(transport, blocked.paneID)
                    return !pending.contains(request.id) && (state == .blocked) == !pending.isEmpty
                }
                let error = await #expect(throws: TransportError.self) {
                    try await transport.answerAgentRequest(target: blocked.paneID, requestID: request.id, answer: .allow)
                }
                if case .apiRejected(let code, _)? = error { #expect(code == "agent_request_resolved") }
                else { Issue.record("expected agent_request_resolved, got \(String(describing: error))") }
                _ = try await host.release(hold)  // SIGTERM may already have dropped it
                try await eventually("the resumed turn completes") {
                    // A resumed turn may ask the model again with the same prompt.
                    if let again = try await host.held(prompt) { _ = try await host.release(again) }
                    return try await status(transport, running.paneID) == .done
                }
                #expect(feed.ending == nil, "stream ending: \(feed.ending ?? "none")")
                #expect(await transport.isConnected)
            }
        }
    }

    // MARK: Helpers

    private func launch(
        _ transport: OpenCodeTransport, _ host: OpenCodeFixtureHost, directory: String? = nil
    ) async throws -> Agent {
        try await transport.startSession(OpenCodeSessionLaunch(
            sessionID: OpenCodeSessionID.mint(), title: "e2e-\(token())",
            directory: directory ?? host.environment.project))
    }

    private func approval(
        _ transport: OpenCodeTransport, _ feed: OpenCodeEventFeed, _ paneID: String
    ) async throws -> AgentPendingRequest {
        _ = try await transport.promptAgent(AgentPromptParams(target: paneID, text: "WAYCAR_TOOL"))
        try await feed.wait(for: paneID, status: .blocked)
        return try await eventuallyValue("Blocked had no pending request") {
            try await transport.pendingAgentRequests(target: paneID).first
        }
    }

    /// The transport's whole inventory against the server's own list.
    @discardableResult
    private func expectInventory(
        _ transport: OpenCodeTransport, _ host: OpenCodeFixtureHost
    ) async throws -> SessionSnapshot {
        let truth = try await host.sessions("parentID=null&archived=false&limit=200")
        let snapshot = try await transport.sessionSnapshot()
        #expect(Set(snapshot.agents.map(\.paneID)) == Set(truth.compactMap { $0["id"]?.stringValue }.map { "opencode:\($0)" }))
        #expect(truth.count == snapshot.agents.count)
        let folders = Dictionary(grouping: snapshot.agents) { $0.cwd ?? "" }
        #expect(Set(snapshot.workspaces.map(\.workspaceID)) == Set(folders.keys.map { "opencode:cwd:\($0)" }))
        for workspace in snapshot.workspaces {
            #expect(workspace.paneCount == folders[String(workspace.workspaceID.dropFirst("opencode:cwd:".count))]?.count)
        }
        return snapshot
    }

    private func status(_ transport: OpenCodeTransport, _ paneID: String) async throws -> AgentStatus? {
        try await transport.sessionSnapshot().agents.first { $0.paneID == paneID }?.agentStatus
    }

    private func sessionID(_ agent: Agent) throws -> String {
        try #require(agent.paneID.hasPrefix("opencode:") ? String(agent.paneID.dropFirst("opencode:".count)) : nil)
    }

    private func token() -> String { String(UUID().uuidString.prefix(8)).lowercased() }

    private func transcriptRequest(_ paneID: String) -> ChatTranscriptRequest {
        ChatTranscriptRequest(paneID: paneID, kind: "opencode", sessionKind: nil, sessionValue: nil,
                              cwd: nil, launchedAt: nil, status: nil, after: nil)
    }

    private func withHost(_ body: (OpenCodeFixtureHost) async throws -> Void) async throws {
        let environment = try #require(OpenCodeE2EEnvironment.current)
        let host = try await OpenCodeFixtureHost.open(environment)
        let outcome: Result<Void, any Error>
        do {
            try await host.ensureRunning()
            try await body(host)
            outcome = .success(())
        } catch { outcome = .failure(error) }
        await host.close()
        try outcome.get()
    }

    private func withTransport(
        _ host: OpenCodeFixtureHost, _ body: (OpenCodeTransport, OpenCodeEventFeed) async throws -> Void
    ) async throws {
        let session = try await HostSSHSession.dial(settings: host.environment.settings())
        let transport: OpenCodeTransport
        do { transport = try await OpenCodeTransport.open(session: session, presence: host.environment.presence) }
        catch {
            await session.release()
            throw error
        }
        let outcome: Result<Void, any Error>
        var feed: OpenCodeEventFeed?
        do {
            let opened = OpenCodeEventFeed(try await transport.subscribeToEvents([]), transport: transport)
            feed = opened
            try await body(transport, opened)
            outcome = .success(())
        } catch { outcome = .failure(error) }
        await feed?.end()
        try await transport.close()
        try outcome.get()
    }
}

/// `waitUntil` under the real-sshd budget, failing the test when it runs out.
private func eventually(
    _ comment: Comment, isolation: isolated (any Actor)? = #isolation, _ condition: () async throws -> Bool
) async throws {
    var met = false
    try await waitUntil(comment, timeout: .sshdBudget(30)) {
        met = try await condition()
        return met
    }
    try #require(met, comment)
}

private func eventuallyValue<T>(
    _ comment: Comment, isolation: isolated (any Actor)? = #isolation, _ value: () async throws -> T?
) async throws -> T {
    var found: T?
    try await waitUntil(comment, timeout: .sshdBudget(30)) {
        found = try await value()
        return found != nil
    }
    return try #require(found, comment)
}

private struct OpenCodeE2EEnvironment: Sendable {
    let host: String
    let port: UInt16
    let username: String
    let deviceKey: Curve25519.Signing.PrivateKey
    let home: String
    let serverPort: UInt16
    let modelPort: UInt16
    let version: String
    var project: String { "\(home)/project" }
    var url: String { "http://127.0.0.1:\(serverPort)" }
    var presence: OpenCodePresence {
        OpenCodePresence(path: "\(home)/.local/bin/opencode", version: version, serverURL: url,
                         registrationPath: "~/.local/state/opencode/service.json")
    }

    static let current: OpenCodeE2EEnvironment? = {
        guard let encoded = ProcessInfo.processInfo.environment["WAYCAR_OPENCODE_E2E_CONFIG"],
              let data = Data(base64Encoded: encoded),
              let fixture = try? JSONDecoder().decode(Fixture.self, from: data),
              let key = try? RealSSHFixture.deviceKey(seed: fixture.deviceKeySeed)
        else { return nil }
        return OpenCodeE2EEnvironment(host: fixture.host, port: fixture.port, username: fixture.username,
            deviceKey: key, home: fixture.home, serverPort: fixture.serverPort, modelPort: fixture.modelPort,
            version: fixture.version)
    }()

    func settings() -> SSHTransportSettings {
        var settings = SSHTransportSettings(host: host, port: Int(port), username: username,
            credentials: .ed25519(deviceKey),
            hostKeyPolicy: HostKeyPolicy(knownHosts: InMemoryKnownHostsStore()) { _ in true }, socket: .defaultSession)
        settings.requestTimeout = .sshdBudget(20)
        settings.wakesInLoginSession = false
        settings.detectionSearchesSystemDirectories = false
        return settings
    }

    private struct Fixture: Decodable {
        let host: String
        let port: UInt16
        let username: String
        let deviceKeySeed: String
        let home: String
        let serverPort: UInt16
        let modelPort: UInt16
        let version: String
    }
}

/// The fixture's own view of the Host: shell commands in the scratch HOME,
/// the server's HTTP API and the model stand-in's control API, all over one
/// SSH connection of its own.
private actor OpenCodeFixtureHost {
    nonisolated let environment: OpenCodeE2EEnvironment
    private let session: HostSSHSession

    private init(_ environment: OpenCodeE2EEnvironment, _ session: HostSSHSession) {
        self.environment = environment
        self.session = session
    }

    static func open(_ environment: OpenCodeE2EEnvironment) async throws -> OpenCodeFixtureHost {
        let session = try await HostSSHSession.dial(settings: environment.settings())
        let host = OpenCodeFixtureHost(environment, session)
        do {
            // Refuse a misconfigured/manual fixture before a mutating command.
            let home = try await host.shell("printf %s \"$HOME\"")
            try #require(home == environment.home && home.contains("/tmp/waycar-ci.") && home.hasSuffix("/oc"))
            return host
        } catch {
            await session.release()
            throw error
        }
    }

    func close() async { await session.release() }

    func shell(_ command: String) async throws -> String {
        let result = try await session.runExec(command, input: Data(), timeout: .sshdBudget(60))
        try #require(result.exitStatus == 0,
            "\(command): exit \(result.exitStatus); \(String(decoding: result.stderr, as: UTF8.self))")
        return String(decoding: result.stdout, as: UTF8.self)
    }

    private func service(_ arguments: String) async throws -> String {
        try await shell("\"$HOME/.local/bin/opencode\" service \(arguments)")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `service status` starts nothing (O2); start only a stopped server.
    func ensureRunning() async throws {
        let status = try await service("status")
        if status == environment.url { return }
        try #require(status == "stopped", "unexpected service status: \(status)")
        try #require(try await service("start").contains(environment.url))
    }

    func serverPID() async throws -> Int {
        let text = try await shell("cat \"$HOME/.local/state/opencode/service.json\"")
        let record = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        return Int(try #require(record["pid"]?.codexNumber))
    }

    /// As the contract restarts it (O20): SIGTERM, then `service start`.
    func restart() async throws {
        let pid = try await serverPID()
        _ = try await shell("kill -TERM \(pid)")
        let probe = "nc -z 127.0.0.1 \(environment.serverPort) && echo up || echo down"
        try await eventually("the server stopped listening") {
            try await self.shell(probe).contains("down")
        }
        try #require(try await service("start").contains(environment.url))
    }

    private func password() async throws -> String {
        let text = try await shell("cat \"$HOME/.local/state/opencode/service.json\"")
        let record = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        return try #require(record["password"]?.stringValue)
    }

    private func http(
        port: UInt16, _ method: String, _ path: String, _ body: JSONValue?, headers: [(String, String)]
    ) async throws -> (status: Int, body: JSONValue?) {
        let session = session
        let client = UltimateHTTPClient(port: port) { try await session.openUltimateChannel(port: port) }
        let response = try await client.request(method: method, path: path,
            body: try body.map { try JSONEncoder().encode($0) }, headers: headers, timeout: .sshdBudget(20))
        let value = response.body.isEmpty ? nil : try JSONDecoder().decode(JSONValue.self, from: response.body)
        return (response.head.status, value)
    }

    func api(
        _ method: String, _ path: String, _ body: JSONValue? = nil, authorized: Bool = true
    ) async throws -> (status: Int, body: JSONValue?) {
        let headers = authorized
            ? [("Authorization", "Basic " + Data("opencode:\(try await password())".utf8).base64EncodedString())] : []
        return try await http(port: environment.serverPort, method, path, body, headers: headers)
    }

    func expectStatus(_ status: Int, _ response: (status: Int, body: JSONValue?)) throws {
        try #require(response.status == status, "HTTP \(response.status): \(String(describing: response.body))")
    }

    private func data(_ method: String, _ path: String, _ body: JSONValue? = nil) async throws -> JSONValue {
        let response = try await api(method, path, body)
        try expectStatus(200, response)
        return try #require(response.body?["data"])
    }

    func sessions(_ query: String) async throws -> [JSONValue] {
        try #require(try await data("GET", "/api/session?\(query)").codexArray)
    }

    /// Newest first (O15).
    func messages(_ id: String) async throws -> [JSONValue] {
        try #require(try await data("GET", "/api/session/\(id)/message?limit=100").codexArray)
    }

    func permissionIDs(_ id: String) async throws -> [String] {
        try #require(try await data("GET", "/api/session/\(id)/permission").codexArray).compactMap { $0["id"]?.stringValue }
    }

    func activeSessionIDs() async throws -> Set<String> {
        guard case .object(let map) = try await data("GET", "/api/session/active") else { return [] }
        return Set(map.keys)
    }

    /// As a desk TUI makes one: no `metadata` at all (O9).
    func createDeskSession(directory: String) async throws -> String {
        let id = OpenCodeSessionID.mint()
        let created = try await data("POST", "/api/session", .object([
            "id": .string(id), "title": .string("desk"), "location": .object(["directory": .string(directory)])]))
        try #require(created["id"]?.stringValue == id && created["metadata"] == nil)
        return id
    }

    private func model(_ method: String, _ path: String, _ body: JSONValue? = nil) async throws -> JSONValue {
        let response = try await http(port: environment.modelPort, method, path, body, headers: [])
        try expectStatus(200, response)
        return try #require(response.body)
    }

    func held(_ text: String) async throws -> String? {
        try await model("GET", "/_health")["holds"]?.codexArray?
            .first { $0["lastUser"]?.stringValue == text }?["id"]?.stringValue
    }

    func waitForHold(_ text: String) async throws -> String {
        try await eventuallyValue("the model never held \(text)") { try await self.held(text) }
    }

    func release(_ id: String) async throws -> Bool {
        try await model("POST", "/_release", .object(["id": .string(id)]))["released"] == .bool(true)
    }
}

/// Snapshot observations driven only by the transport's own event stream,
/// never a polling inventory RPC. Keep their order to prove Working → Done.
private final class OpenCodeEventFeed: Sendable {
    private struct State {
        var snapshots: [SessionSnapshot] = []
        var ending: String?
    }
    private final class Log: Sendable {
        let state = Mutex(State())
    }
    private let log = Log()
    private let stream: HerdrEventStream
    private let pump: Task<Void, Never>

    init(_ stream: HerdrEventStream, transport: OpenCodeTransport) {
        self.stream = stream
        let log = log
        pump = Task {
            do {
                for try await _ in stream.events {
                    let snapshot = try await transport.sessionSnapshot()
                    log.state.withLock { $0.snapshots.append(snapshot) }
                }
                log.state.withLock { $0.ending = "finished" }
            } catch { log.state.withLock { $0.ending = "failed: \(error)" } }
        }
    }

    var ending: String? { log.state.withLock { $0.ending } }
    func statuses(for paneID: String) -> [AgentStatus] {
        log.state.withLock { $0.snapshots.compactMap { $0.agents.first { $0.paneID == paneID }?.agentStatus } }
    }
    func wait(for paneID: String, status: AgentStatus) async throws {
        try await eventually("no event-driven \(status) for \(paneID); ending \(ending ?? "none")") {
            self.statuses(for: paneID).contains(status)
        }
    }
    func end() async { await stream.end(); await pump.value }
}
