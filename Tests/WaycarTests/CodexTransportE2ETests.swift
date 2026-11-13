import CryptoKit
import Foundation
import Synchronization
import Testing
import WaycarSSH

@testable import Waycar

/// The pinned real Codex daemon behind CI's disposable user-mode sshd. The
/// fixture owns HOME, CODEX_HOME, the complete npm package and the model mock;
/// no command here resolves the developer's Codex or touches their daemon.
@Suite(
    "Codex Transport e2e",
    .enabled(if: CodexE2EEnvironment.current != nil, "requires the disposable Codex SSH fixture"),
    .serialized)
struct CodexTransportE2ETests {
    @Test("Codex detection finds the pinned CLI without starting a daemon")
    func detectionStartsNothing() async throws {
        try await withHost(start: false) { host in
            let before = try await host.daemonProcesses()
            #expect(before.isEmpty)
            #expect(try await host.socketExists() == false)
            let presence = try await SSHTransportConnector().detectBackends(settings: host.environment.settings())
            let codex = try #require(presence.codex)
            #expect(codex.meetsFloor)
            #expect(codex.version == host.environment.version)
            #expect(codex.path == "\(host.environment.home)/.local/bin/codex")
            #expect(!presence.codexRunning)
            #expect(try await host.socketExists() == false)
            #expect(try await host.daemonProcesses() == before)
        }
    }

    @Test("Start Codex server over SSH makes detection report its running socket")
    func explicitStart() async throws {
        try await withHost(start: false) { host in
            try await SSHTransportConnector().startCodex(settings: host.environment.settings())
            let presence = try await SSHTransportConnector().detectBackends(settings: host.environment.settings())
            let codex = try #require(presence.codex)
            #expect(presence.codexRunning)
            #expect(codex.version == host.environment.version)
            #expect(codex.socketPath == (try await host.canonicalSocket()))
            #expect(try await host.socketExists())
        }
    }

    @Test("a named Codex launch is listed and a lost launch answer reconciles without duplication")
    func launchAndReconcile() async throws {
        try await withHost { host in
            try await withTransport(host.environment) { transport, _ in
                let name = "e2e-\(UUID().uuidString.lowercased())"
                let first = try await transport.startAgent(
                    AgentLaunchRequest(kind: "codex", name: name, cwd: host.environment.home))
                #expect(first.paneID.hasPrefix("codex:"))
                let snapshot = try await transport.sessionSnapshot()
                let row = try #require(snapshot.agents.first { $0.paneID == first.paneID })
                #expect(row.name == name)
                #expect(row.cwd == host.environment.home)
                let reconciled = try await transport.startAgent(
                    AgentLaunchRequest(kind: "codex", name: name, cwd: host.environment.home, mayHaveStarted: true))
                #expect(reconciled.paneID == first.paneID)
                #expect(try await transport.sessionSnapshot().agents.filter { $0.name == name }.count == 1)
                try await host.withRawClient { rpc in
                    let loaded = try await rpc.request(method: "thread/loaded/list", params: .object([:]))
                    #expect(loaded["data"]?.codexArray?.count == 1)
                    let record = try await rpc.request(method: "thread/read", params: .object([
                        "threadId": .string(String(first.paneID.dropFirst(6)))]))
                    #expect(record["thread"]?["threadSource"] == .string("waycar"))
                }
            }
        }
    }

    @Test("a plain desk Codex TUI reports user origin and links to its real tmux pane")
    func deskTUIThreadLinksByOrigin() async throws {
        try await withHost { host in
            try await host.withDeskTUI {
                try await withTransport(host.environment) { transport, _ in
                    let paneTransport = try await SSHTransportConnector().connect(
                        settings: host.environment.settings(), backend: .tmux)
                    let outcome: Result<Void, any Error>
                    do {
                        let info = try #require(try await codexEventuallyValue {
                            let facts = await transport.serverSessionLinkFacts()
                            return try await transport.sessionSnapshot().agents.first {
                                facts.sessionOrigins[String($0.paneID.dropFirst(6))] == "user"
                            }
                        }, "plain desk TUI created no user thread")
                        let pane = try #require(try await codexEventuallyValue {
                            try await paneTransport.sessionSnapshot().agents.first { $0.agent == "codex" }
                        }, "the fixture's tmux pane did not run Codex")
                        try await host.withRawClient { rpc in
                            let record = try await rpc.request(method: "thread/read", params: .object([
                                "threadId": .string(String(info.paneID.dropFirst(6)))]))
                            #expect(record["thread"]?["source"] == .string("vscode"))
                            #expect(record["thread"]?["threadSource"] == .string("user"))
                        }
                        try #require(try await codexEventually {
                            guard let row = try await transport.sessionSnapshot().agents.first(where: { $0.paneID == info.paneID }),
                                row.agentSession != nil, row.agentStatus == .idle || row.agentStatus == .done
                            else { return false }
                            let transcript = try await transport.readChatTranscript(transcriptRequest(info.paneID))
                            return transcript.messages.contains { $0.role == .user && $0.text == "WAYCAR_DESK_ORIGIN" }
                                && transcript.messages.contains {
                                    $0.role == .assistant && $0.text.contains("waycar-mock-reply: WAYCAR_DESK_ORIGIN")
                                }
                        }, "desk thread history did not return its prompt and reply")
                        let nativeFacts = await transport.serverSessionLinkFacts()
                        let terminalFacts = await paneTransport.serverSessionLinkFacts()
                        await MainActor.run {
                            let hostID = UUID()
                            var threadRow = ConsoleAgent(hostID: hostID, hostName: "Fixture", agent: Agent(info),
                                workspaceLabel: nil, repositoryCheckout: nil, backend: .codex)
                            threadRow.serverSessionOrigin = nativeFacts.sessionOrigins[String(info.paneID.dropFirst(6))]
                            var paneRow = ConsoleAgent(hostID: hostID, hostName: "Fixture", agent: Agent(pane),
                                workspaceLabel: nil, repositoryCheckout: nil, backend: .tmux)
                            paneRow.paneCommandLine = terminalFacts.commandLines[pane.paneID]
                            #expect(threadRow.serverSessionOrigin == "user")
                            #expect(paneRow.paneCommandLine != nil)
                            let merged = ServerSessionLinks.merge([threadRow, paneRow]) { _ in nil }
                            #expect(merged.count == 1 && merged.first?.linkedTerminal?.id == paneRow.id)
                        }
                        outcome = .success(())
                    } catch { outcome = .failure(error) }
                    try await paneTransport.close()
                    try outcome.get()
                }
            }
        }
    }

    @Test("a Codex turn pushes Working then Done and its transcript contains prompt and reply")
    func turnRoundTrip() async throws {
        try await withHost { host in
            try await withTransport(host.environment) { transport, feed in
                let agent = try await launch(transport, host)
                let prompt = "hello WAYCAR_ROUND_TRIP"
                _ = try await transport.promptAgent(AgentPromptParams(target: agent.paneID, text: prompt))
                try await feed.wait(for: agent.paneID, status: .working)
                try await feed.wait(for: agent.paneID, status: .done)
                let statuses = feed.statuses(for: agent.paneID)
                let working = try #require(statuses.firstIndex(of: .working))
                let done = try #require(statuses.firstIndex(of: .done))
                #expect(working < done)
                let transcript = try await transport.readChatTranscript(transcriptRequest(agent.paneID))
                #expect(transcript.messages.contains { $0.role == .user && $0.text == prompt })
                #expect(transcript.messages.contains {
                    $0.role == .assistant && $0.text.contains("waycar-mock-reply: WAYCAR_ROUND_TRIP")
                })
                #expect(!transcript.header.turnOpen)
            }
        }
    }

    @Test("a Codex command approval blocks until Allow and the reply includes the tool output")
    func commandApproval() async throws {
        try await withHost { host in
            try await withTransport(host.environment) { transport, feed in
                let agent = try await launch(transport, host)
                let request = try await approval(transport, feed, agent.paneID)
                guard case .command(let command, let cwd, _) = request.kind else {
                    Issue.record("expected a command approval, got \(request.kind)")
                    return
                }
                #expect(command.hasPrefix("/bin/"))
                #expect(command.hasSuffix(" -lc 'echo waycar-tool-ok'"))
                #expect(cwd == host.environment.home)
                try await transport.answerAgentRequest(target: agent.paneID, requestID: request.id, answer: .allow)
                try await feed.wait(for: agent.paneID, status: .done)
                let transcript = try await transport.readChatTranscript(transcriptRequest(agent.paneID))
                #expect(transcript.messages.contains { $0.role == .assistant && $0.text.contains("saw waycar-tool-ok") })
            }
        }
    }

    @Test("a Codex approval answered on another client disappears and a late answer is refused")
    func approvalResolvedElsewhere() async throws {
        try await withHost { host in
            try await withTransport(host.environment) { transport, feed in
                let agent = try await launch(transport, host)
                let request = try await approval(transport, feed, agent.paneID)
                try await host.withRawClient { rpc in
                    let requests = CodexRawRequests(rpc.events)
                    _ = try await rpc.request(method: "thread/resume", params: .object([
                        "threadId": .string(String(agent.paneID.dropFirst(6))), "excludeTurns": .bool(true),
                    ]))
                    let id = try #require(try await codexEventuallyValue {
                        requests.approvalID
                    }, "second client received no replayed approval")
                    try await rpc.respond(to: id, result: .object(["decision": .string("accept")]))
                    try #require(try await codexEventually {
                        let requests = try await transport.pendingAgentRequests(target: agent.paneID)
                        let status = try await transport.sessionSnapshot().agents
                            .first { $0.paneID == agent.paneID }?.agentStatus
                        return requests.isEmpty && status == .working
                    }, "resolved request was not removed before the turn completed")
                    let error = await #expect(throws: TransportError.self) {
                        try await transport.answerAgentRequest(target: agent.paneID, requestID: request.id, answer: .cancel)
                    }
                    if case .apiRejected(let code, _) = error {
                        #expect(code == "agent_request_resolved")
                    } else { Issue.record("expected agent_request_resolved, got \(String(describing: error))") }
                    try await feed.wait(for: agent.paneID, status: .done)
                    await requests.end()
                }
            }
        }
    }

    @Test("Stop interrupts a slow Codex turn without a completed assistant reply")
    func stopInterrupts() async throws {
        try await withHost { host in
            try await withTransport(host.environment) { transport, feed in
                let agent = try await launch(transport, host)
                _ = try await transport.promptAgent(AgentPromptParams(target: agent.paneID, text: "WAYCAR_SLOW"))
                try await feed.wait(for: agent.paneID, status: .working)
                try await transport.abortAgentRun(target: agent.paneID)
                try await feed.wait(for: agent.paneID, status: .done)
                // X12 pins the wire status; a transcript need not have an error
                // card when Codex supplies no error.message for an interrupt.
                try await host.withRawClient { rpc in
                    let turns = try await rpc.request(method: "thread/turns/list", params: .object([
                        "threadId": .string(String(agent.paneID.dropFirst(6))), "limit": .number(1),
                    ]))
                    #expect(turns["data"]?.codexArray?.first?["status"]?.stringValue == "interrupted")
                }
                let transcript = try await transport.readChatTranscript(transcriptRequest(agent.paneID))
                #expect(!transcript.header.turnOpen)
                #expect(transcript.messages.contains { $0.role == .user && $0.text == "WAYCAR_SLOW" })
                #expect(!transcript.messages.contains { $0.role == .assistant && !$0.text.isEmpty })
            }
        }
    }

    @Test("stopping the Codex daemon ends its transport event stream with an error")
    func daemonStopEndsStream() async throws {
        try await withHost { host in
            try await withTransport(host.environment) { _, feed in
                try await host.stop()
                try #require(try await codexEventually { feed.ending != nil }, "the event stream stayed open")
                #expect(feed.ending?.hasPrefix("failed:") == true, "stream ending: \(feed.ending ?? "none")")
            }
        }
    }

    private func launch(_ transport: any Transport, _ host: CodexFixtureHost) async throws -> Agent {
        try await transport.startAgent(AgentLaunchRequest(
            kind: "codex", name: "e2e-\(UUID().uuidString.lowercased())", cwd: host.environment.home))
    }

    private func approval(
        _ transport: any Transport, _ feed: CodexEventFeed, _ paneID: String
    ) async throws -> AgentPendingRequest {
        _ = try await transport.promptAgent(AgentPromptParams(target: paneID, text: "WAYCAR_TOOL"))
        try await feed.wait(for: paneID, status: .blocked)
        return try #require(try await codexEventuallyValue {
            try await transport.pendingAgentRequests(target: paneID).first
        }, "Blocked had no pending approval")
    }

    private func transcriptRequest(_ paneID: String) -> ChatTranscriptRequest {
        ChatTranscriptRequest(paneID: paneID, kind: "codex", sessionKind: nil, sessionValue: nil,
                              cwd: nil, launchedAt: nil, status: nil, after: nil)
    }

    private func withHost(
        start: Bool = true, _ body: (CodexFixtureHost) async throws -> Void
    ) async throws {
        let environment = try #require(CodexE2EEnvironment.current)
        let host = try await CodexFixtureHost.open(environment)
        let outcome: Result<Void, any Error>
        do {
            try await host.stop()
            if start { try await SSHTransportConnector().startCodex(settings: environment.settings()) }
            try await body(host)
            outcome = .success(())
        } catch { outcome = .failure(error) }
        let cleanup: Result<Void, any Error>
        do { try await host.stop(); cleanup = .success(()) }
        catch { cleanup = .failure(error) }
        await host.close()
        try outcome.get()
        try cleanup.get()
    }

    private func withTransport(
        _ environment: CodexE2EEnvironment,
        _ body: (any Transport, CodexEventFeed) async throws -> Void
    ) async throws {
        let transport = try await SSHTransportConnector().connect(settings: environment.settings(), backend: .codex)
        #expect(transport is CodexTransport)
        let feed = CodexEventFeed(try await transport.subscribeToEvents([]), transport: transport)
        let outcome: Result<Void, any Error>
        do { try await body(transport, feed); outcome = .success(()) }
        catch { outcome = .failure(error) }
        await feed.end()
        try await transport.close()
        try outcome.get()
    }
}

private func codexEventually(
    _ condition: @Sendable () async throws -> Bool
) async throws -> Bool {
    let deadline = ContinuousClock.now + .sshdBudget(20)
    while true {
        if try await condition() { return true }
        if ContinuousClock.now >= deadline { return false }
        try await Task.sleep(for: .milliseconds(50))
    }
}

private func codexEventuallyValue<T: Sendable>(_ value: @Sendable () async throws -> T?) async throws -> T? {
    let deadline = ContinuousClock.now + .sshdBudget(20)
    while true {
        if let result = try await value() { return result }
        if ContinuousClock.now >= deadline { return nil }
        try await Task.sleep(for: .milliseconds(50))
    }
}

private struct CodexE2EEnvironment: Sendable {
    let host: String
    let port: UInt16
    let username: String
    let deviceKey: Curve25519.Signing.PrivateKey
    let home: String
    let physicalSocket: String
    let version: String
    var socket: String { "\(home)/.codex/app-server-control/app-server-control.sock" }

    static let current: CodexE2EEnvironment? = {
        guard let encoded = ProcessInfo.processInfo.environment["WAYCAR_CODEX_E2E_CONFIG"],
              let data = Data(base64Encoded: encoded),
              let fixture = try? JSONDecoder().decode(Fixture.self, from: data),
              let key = try? RealSSHFixture.deviceKey(seed: fixture.deviceKeySeed)
        else { return nil }
        return CodexE2EEnvironment(host: fixture.host, port: fixture.port, username: fixture.username,
            deviceKey: key, home: fixture.home, physicalSocket: fixture.physicalSocket, version: fixture.version)
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
        let physicalSocket: String
        let version: String
    }
}

private actor CodexFixtureHost {
    nonisolated let environment: CodexE2EEnvironment
    private let connection: SSHConnection

    private init(_ environment: CodexE2EEnvironment, _ connection: SSHConnection) {
        self.environment = environment
        self.connection = connection
    }

    static func open(_ environment: CodexE2EEnvironment) async throws -> CodexFixtureHost {
        let key = DeviceKey(privateKey: environment.deviceKey)
        let connection = try await SSHConnection.connect(
            to: SSHEndpoint(host: environment.host, port: environment.port), timeout: .sshdBudget(5))
        do {
            try await connection.authenticate(username: environment.username, publicKey: key.publicKeyBlob,
                signer: { try key.privateKey.signature(for: $0) }, timeout: .sshdBudget(5))
            // Refuse a misconfigured/manual fixture before a mutating command.
            let host = CodexFixtureHost(environment, connection)
            let home = try await host.shell("printf %s \"$HOME\"")
            try #require(home == environment.home && home.hasPrefix("/tmp/waycar-ci.") && home.hasSuffix("/cx"))
            return host
        } catch {
            try? await connection.close(timeout: .sshdBudget(2))
            throw error
        }
    }

    func close() async { try? await connection.close(timeout: .sshdBudget(2)) }

    func socketExists() async throws -> Bool {
        let alias = ShellWord.quoted(environment.socket)
        let physical = ShellWord.quoted(environment.physicalSocket)
        return try await shell("if [ -e \(alias) ] || [ -L \(alias) ] || [ -e \(physical) ]; then echo yes; else echo no; fi")
            .trimmingCharacters(in: .whitespacesAndNewlines) == "yes"
    }

    func canonicalSocket() async throws -> String {
        try await shell("cd \"$HOME/.codex/app-server-control\" && printf '%s/app-server-control.sock' \"$(pwd -P)\"")
    }

    func daemonProcesses() async throws -> [String] {
        try await shell("ps -axo pid=,command=").components(separatedBy: .newlines).filter {
            $0.contains(environment.home + "/") && $0.contains("codex")
        }.sorted()
    }

    func stop() async throws {
        // X20: stopping an absent daemon is nonzero. Do not invoke lifecycle
        // commands on an unstarted HOME merely to clean up detection.
        if try await socketExists() {
            _ = try await shell("\"$HOME/.local/bin/codex\" app-server daemon stop")
            try #require(try await codexEventually { try await self.socketExists() == false }, "daemon left its socket")
        }
    }

    func withDeskTUI(_ body: @Sendable () async throws -> Void) async throws {
        // Only this fixture's private default tmux socket, never the user's.
        let directory = try await shell("printf %s \"$TMUX_TMPDIR\"")
        try #require(directory == environment.home + "/tmux")
        _ = try await shell("tmux -f /dev/null new-session -d -s desk -x 120 -y 40 -c \"$HOME\" "
            + ShellWord.quoted("exec codex --no-alt-screen WAYCAR_DESK_ORIGIN"))
        let outcome: Result<Void, any Error>
        do { try await body(); outcome = .success(()) }
        catch { outcome = .failure(error) }
        _ = try await shell("tmux kill-server")
        try outcome.get()
    }

    func withRawClient(_ body: @Sendable (CodexRPCClient) async throws -> Void) async throws {
        let session = try await HostSSHSession.dial(settings: environment.settings())
        let outcome: Result<Void, any Error>
        var rpc: CodexRPCClient?
        do {
            let channel = try await session.openCodexChannel(socketPath: environment.socket)
            let socket = try await CodexWebSocket.connect(channel: channel)
            let client = await CodexRPCClient.connect(webSocket: socket, requestTimeout: .sshdBudget(20))
            rpc = client
            try await client.initialize(clientName: "waycar_e2e_observer", version: "1")
            try await body(client)
            outcome = .success(())
        } catch { outcome = .failure(error) }
        await rpc?.close()
        await session.release()
        try outcome.get()
    }

    private func shell(_ command: String) async throws -> String {
        let result = try await connection.execute(command, timeout: .sshdBudget(60))
        try #require(result.exitStatus == 0,
            "\(command): exit \(String(describing: result.exitStatus)); \(String(decoding: result.stderr, as: UTF8.self))")
        return String(decoding: result.stdout, as: UTF8.self)
    }
}

/// Snapshot observations are driven only by the production event stream,
/// never a polling inventory RPC. Keep their order to prove Working → Done.
private final class CodexEventFeed: Sendable {
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

    init(_ stream: HerdrEventStream, transport: any Transport) {
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
        try #require(try await codexEventually { self.statuses(for: paneID).contains(status) },
                     "no event-driven \(status) for \(paneID); observed \(statuses(for: paneID)); ending \(ending ?? "none")")
    }
    func end() async { await stream.end(); await pump.value }
}

private final class CodexRawRequests: Sendable {
    private final class Log: Sendable {
        let id = Mutex<CodexRPCID?>(nil)
    }
    private let log = Log()
    private let pump: Task<Void, Never>
    init(_ events: AsyncThrowingStream<CodexRPCEvent, any Error>) {
        let log = log
        pump = Task {
            do {
                for try await event in events {
                    if case .serverRequest(let requestID, "item/commandExecution/requestApproval", _) = event {
                        log.id.withLock { $0 = requestID }
                    }
                }
            } catch {}
        }
    }
    var approvalID: CodexRPCID? { log.id.withLock { $0 } }
    func end() async { pump.cancel(); await pump.value }
}
