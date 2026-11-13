import Foundation
import Synchronization
import Testing
import WaycarSSH

@testable import Waycar

/// A `HostConnectionMemory` that keeps the login PATH it is told to.
final class CoreTestMemory: HostConnectionMemory {
    private struct Values {
        var home: String?
        var protocolVersion: Int?
        var loginPATH: String?
    }

    private let values: Mutex<Values>

    init(loginPATH: String? = nil) {
        values = Mutex(Values(loginPATH: loginPATH))
    }

    var homeDirectory: String? { values.withLock { $0.home } }
    func rememberHomeDirectory(_ home: String?) { values.withLock { $0.home = home } }
    var protocolVersion: Int? { values.withLock { $0.protocolVersion } }
    func rememberProtocolVersion(_ version: Int?) { values.withLock { $0.protocolVersion = version } }
    var loginPATH: String? { values.withLock { $0.loginPATH } }
    func rememberLoginPATH(_ path: String?) { values.withLock { $0.loginPATH = path } }
}

/// Reads an event stream one event at a time. A test calls `next()` from one
/// task at a time, so the iterator is never used concurrently.
final class EventReader: @unchecked Sendable {
    private var iterator: AsyncThrowingStream<HerdrEvent, any Error>.Iterator

    init(_ stream: AsyncThrowingStream<HerdrEvent, any Error>) {
        iterator = stream.makeAsyncIterator()
    }

    func next() async throws -> HerdrEvent? {
        try await iterator.next()
    }
}

/// `CoreTransport` against a scripted herdr-core (`FakeCoreChannel`) and
/// `FakeHostSSHServices`: connecting, the inventory and its events, failure,
/// input, close, Attach and the members core does not offer yet.
@Suite("herdr-core Transport", .timeLimit(.minutes(1)))
struct CoreTransportTests {
    // MARK: Fixtures

    static let hostPATH = "/opt/tools/bin:/usr/bin"
    static let detectedCorePath = "/opt/herdr/bin/herdr-core"
    /// The first eight characters of `FakeCoreChannel.helloReply`'s core id.
    static let corePrefix = "b16ea034"

    struct Rig: Sendable {
        let session: FakeHostSSHServices
        let channel: FakeCoreChannel
        let transport: CoreTransport
    }

    static let loginPathExec: FakeHostSSHServices.ExecHandler = { command, _ in
        if command == CoreLoginPath.command {
            return FakeHostSSHServices.result(
                stdout: "@@WAYCAR-LOGIN-PATH@@\(CoreTransportTests.hostPATH)@@WAYCAR-LOGIN-PATH@@")
        }
        return FakeHostSSHServices.result(exitStatus: 127)
    }

    static func configuration(debounce: Duration = .milliseconds(10)) -> CoreTransport.Configuration {
        var configuration = CoreTransport.Configuration(requestTimeout: .seconds(5))
        configuration.resyncDebounce = debounce
        return configuration
    }

    /// JSON text of `object`, keys sorted.
    static func json(_ object: Any) -> String {
        let data =
            (try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// One terminal record as core's `terminal.list`, `events.subscribe` and
    /// `created` carry it: an agent when `status` is given, else a plain
    /// terminal running its `argv`.
    static func record(
        _ address: String, name: String? = nil, labels: [String: String] = [:],
        argv: [String] = ["zsh"], cwd: String = "/work/app", status: String? = nil,
        app: String = "claude-code", turn: Int = 0, title: String = "", statusMs: Int = 1000
    ) -> String {
        var object: [String: Any] = [
            "address": address, "labels": labels, "argv": argv, "cwd": cwd, "state": "live",
            "reported": status != nil, "turn": turn, "title": title, "pid": 4000, "cols": 200,
            "rows": 120,
            "foreground": [
                "pid": 4001, "name": argv.first ?? "sh", "argv": argv, "cwd": cwd,
            ] as [String: Any],
        ]
        if let name { object["name"] = name }
        if let status {
            object["status"] = ["state": status, "app": app]
            object["status_ms"] = statusMs
        } else {
            object["status"] = NSNull()
        }
        return json(object)
    }

    /// The `data` of a `status` event.
    static func statusData(_ word: String, app: String = "claude-code", statusMs: Int = 2000) -> String {
        json(["status": ["state": word, "app": app], "reported": true, "status_ms": statusMs] as [String: Any])
    }

    /// A core that answers `server.status` and `events.subscribe` (with
    /// `terminals` at `seq`), and everything else with `extra`.
    static func channel(
        terminals: [String] = [], seq: Int = 10, noise: String = "",
        hello: String = FakeCoreChannel.helloReply(),
        extra: @escaping FakeCoreChannel.Responder = { _, _ in .none }
    ) -> FakeCoreChannel {
        FakeCoreChannel(noise: noise, hello: hello) { method, params in
            switch method {
            case "doc.get":
                // `extra` may serve a desktop-app document; empty otherwise.
                if case .result = extra(method, params) { return extra(method, params) }
                return .result(#"{"value":null,"version":0}"#)
            case "server.status":
                return .result(#"{"ok":true}"#)
            case "events.subscribe":
                return .result(FakeCoreChannel.subscribeResult(seq: seq, terminals: terminals))
            default:
                return extra(method, params)
            }
        }
    }

    /// A core that answers `terminal.send`, `terminal.keys` and
    /// `terminal.kill` with an empty result.
    static func acceptingChannel(terminals: [String]) -> FakeCoreChannel {
        channel(terminals: terminals) { method, _ in
            switch method {
            case "terminal.send", "terminal.keys", "terminal.kill": return .result("{}")
            default: return .none
            }
        }
    }

    static func open(
        _ channel: FakeCoreChannel, memory: (any HostConnectionMemory)? = nil,
        corePath: String? = CoreTransportTests.detectedCorePath,
        debounce: Duration = .milliseconds(10),
        exec: @escaping FakeHostSSHServices.ExecHandler = CoreTransportTests.loginPathExec
    ) async throws -> Rig {
        let session = FakeHostSSHServices(exec: exec)
        await session.serveCore(channel)
        let transport = try await CoreTransport.open(
            session: session, configuration: configuration(debounce: debounce), memory: memory,
            corePath: corePath)
        return Rig(session: session, channel: channel, transport: transport)
    }

    /// An open transport with its events subscribed.
    static func subscribed(
        _ channel: FakeCoreChannel, debounce: Duration = .milliseconds(10)
    ) async throws -> (rig: Rig, stream: HerdrEventStream) {
        let rig = try await open(channel, debounce: debounce)
        let stream = try await rig.transport.subscribeToEvents([])
        return (rig, stream)
    }

    /// The error a failing open throws, and the session it ran on.
    static func openFailure(
        _ channel: FakeCoreChannel
    ) async -> (session: FakeHostSSHServices, error: (any Error)?) {
        let session = FakeHostSSHServices(exec: loginPathExec)
        await session.serveCore(channel)
        let error = await thrown {
            try await CoreTransport.open(
                session: session, configuration: configuration(), memory: nil, corePath: nil)
        }
        return (session, error)
    }

    static func thrown<T>(_ operation: () async throws -> T) async -> (any Error)? {
        do {
            _ = try await operation()
            return nil
        } catch {
            return error
        }
    }

    static func statuses(_ snapshot: SessionSnapshot) -> [String: AgentStatus] {
        Dictionary(uniqueKeysWithValues: snapshot.agents.map { ($0.paneID, $0.agentStatus) })
    }

    static func methods(_ channel: FakeCoreChannel) -> [String] {
        // Existing traffic assertions concern terminal operations, not layout name reads.
        channel.requests.map { $0.method }.filter { $0 != "doc.get" }
    }

    static func statusEvent(_ paneID: String, _ word: String) -> HerdrEvent {
        HerdrEvent(
            kind: PaneEventKind.agentStatusChanged.kind,
            data: .object(["pane_id": .string(paneID), "agent_status": .string(word)]))
    }

    static func terminalObject(_ address: String) -> JSONValue {
        .object(["terminal": .string(address)])
    }

    @Test func desktopDocumentEventRefetchesNamesAndInvalidatesSnapshot() async throws {
        let document = Mutex(#"{"value":null,"version":0}"#)
        let channel = Self.channel(
            terminals: [Self.record("t15", labels: CoreAppLayoutFixture.labels, cwd: "/work/tmp")]
        ) { method, _ in
            method == "doc.get" ? .result(document.withLock { $0 }) : .none
        }
        let (rig, stream) = try await Self.subscribed(channel)
        let reader = EventReader(stream.events)
        #expect(try await rig.transport.sessionSnapshot().workspaces.first?.label == "tmp")
        document.withLock { $0 = CoreAppLayoutFixture.captured }
        channel.pushEvent(seq: 11, type: "doc", terminal: nil, data: #"{"name":"herdr-app","version":34}"#)
        _ = try await reader.next()
        let snapshot = try await rig.transport.sessionSnapshot()
        #expect(snapshot.workspaces.first?.label == "Ultimate")
        #expect(snapshot.tabs.first?.label == "router/caddy")
        #expect(channel.params(of: "doc.get") == [
            .object(["name": .string("herdr-app")]),
            .object(["name": .string("herdr-app")]),
        ])
        try await rig.transport.close()
    }

    // MARK: 1. The connect line

    @Test("the connect line carries the login PATH and the detected binary, after login noise")
    func connectLineCarriesLoginPathAndBinary() async throws {
        let memory = CoreTestMemory()
        let channel = Self.channel(noise: "Last login: Tue Oct 27\nWelcome to the box\n")
        let rig = try await Self.open(channel, memory: memory)
        let commands = await rig.session.coreCommands
        #expect(commands.count == 1)
        let arguments = " \(ShellWord.quoted(Self.hostPATH)) \(ShellWord.quoted(Self.detectedCorePath))"
        #expect(commands.first?.hasSuffix(arguments) == true)
        #expect(memory.loginPATH == Self.hostPATH)
        let loginExecs = await rig.session.execs.filter { $0.command == CoreLoginPath.command }
        #expect(loginExecs.count == 1)
        try await rig.transport.close()
    }

    @Test("a remembered login PATH is used without asking the Host again")
    func rememberedLoginPathIsNotResolvedAgain() async throws {
        let memory = CoreTestMemory(loginPATH: "/remembered/bin")
        let rig = try await Self.open(Self.channel(), memory: memory)
        let commands = await rig.session.coreCommands
        #expect(commands.first?.hasSuffix(" /remembered/bin \(Self.detectedCorePath)") == true)
        #expect(await rig.session.execs.isEmpty)
        #expect(memory.loginPATH == "/remembered/bin")
        try await rig.transport.close()
    }

    enum LoginExecFailure: CaseIterable, Sendable {
        case exitsNonZero
        case printsNoMarkers
        case printsEmptyPath

        var handler: FakeHostSSHServices.ExecHandler {
            switch self {
            case .exitsNonZero:
                return { _, _ in FakeHostSSHServices.result(exitStatus: 1) }
            case .printsNoMarkers:
                return { _, _ in FakeHostSSHServices.result(stdout: "no markers in here\n") }
            case .printsEmptyPath:
                return { _, _ in
                    FakeHostSSHServices.result(stdout: "@@WAYCAR-LOGIN-PATH@@@@WAYCAR-LOGIN-PATH@@")
                }
            }
        }
    }

    @Test(
        "a login PATH exec that fails or prints no PATH falls back to an empty PATH argument",
        arguments: LoginExecFailure.allCases)
    func failedLoginPathFallsBack(failure: LoginExecFailure) async throws {
        let memory = CoreTestMemory()
        let rig = try await Self.open(Self.channel(), memory: memory, exec: failure.handler)
        let commands = await rig.session.coreCommands
        #expect(commands.first?.hasSuffix(" '' \(Self.detectedCorePath)") == true)
        #expect(memory.loginPATH == nil)
        #expect(await rig.transport.isConnected)
        try await rig.transport.close()
    }

    // MARK: 2. Identity and open failures

    @Test("ping is the core's identity after a server.status round trip")
    func pingReportsIdentity() async throws {
        let rig = try await Self.open(Self.channel())
        let info = try await rig.transport.ping()
        #expect(info == ServerInfo(version: "0.1.14", protocolVersion: 1, backend: .core))
        #expect(Self.methods(rig.channel) == ["server.status"])
        try await rig.transport.close()
    }

    enum UnfitCore: CaseIterable, Sendable {
        case belowFloor
        case lacksKeys

        var hello: String {
            switch self {
            case .belowFloor:
                return FakeCoreChannel.helloReply(version: "0.1.9")
            case .lacksKeys:
                return FakeCoreChannel.helloReply(
                    methods: FakeCoreChannel.defaultMethods.filter { $0 != "terminal.keys" })
            }
        }

        /// What the update message names.
        var needle: String {
            switch self {
            case .belowFloor: return "0.1.9"
            case .lacksKeys: return "terminal.keys"
            }
        }
    }

    @Test("a core below the floor or without terminal.keys needs an update, and the caller keeps its hold",
        arguments: UnfitCore.allCases)
    func unfitCoreNeedsUpdate(core: UnfitCore) async throws {
        let channel = Self.channel(hello: core.hello)
        let failure = await Self.openFailure(channel)
        guard case .coreNeedsUpdate(let detail)? = failure.error as? TransportError else {
            Issue.record("open failed with \(String(describing: failure.error))")
            return
        }
        #expect(detail.contains(core.needle))
        #expect(channel.isClosed)
        #expect(await failure.session.releaseCount == 0)
    }

    @Test("exit 127 with core's not-installed text is coreNotInstalled")
    func exit127IsNotInstalled() async {
        let channel = FakeCoreChannel(emitsMarker: false) { _, _ in .none }
        channel.finishCommand(exitStatus: 127, standardError: "herdr-core is not installed here\n")
        let failure = await Self.openFailure(channel)
        #expect(failure.error as? TransportError == TransportError.coreNotInstalled)
        #expect(await failure.session.releaseCount == 0)
    }

    @Test("a stopped core exits before the marker and reports coreNotRunning")
    func stoppedCoreIsNotRunning() async {
        let channel = FakeCoreChannel(emitsMarker: false) { _, _ in .none }
        channel.finishCommand(
            exitStatus: CoreConnectCommand.notRunningStatus,
            standardError: CoreConnectCommand.notRunningText + "\n")
        let failure = await Self.openFailure(channel)
        #expect(failure.error as? TransportError == .coreNotRunning)
        #expect(await failure.session.releaseCount == 0)
    }

    @Test("core's own refusal on stderr is coreRefused with its message and hint")
    func refusalCarriesMessageAndHint() async {
        let channel = FakeCoreChannel(emitsMarker: false) { _, _ in .none }
        channel.finishCommand(
            exitStatus: 1,
            standardError:
                #"{"error":{"kind":"state_locked","message":"another core owns this state","hint":"stop it first"}}"#
                + "\n")
        let failure = await Self.openFailure(channel)
        #expect(
            failure.error as? TransportError
                == TransportError.coreRefused(
                    message: "another core owns this state", hint: "stop it first"))
        #expect(await failure.session.releaseCount == 0)
    }

    // MARK: 3. Snapshot and events

    @Test("subscribing sends one unfiltered events.subscribe, and snapshots then need no request")
    func snapshotComesFromTheInventory() async throws {
        let channel = Self.channel(terminals: [Self.record("t1", status: "idle")])
        let rig = try await Self.open(channel)
        let stream = try await rig.transport.subscribeToEvents([])
        #expect(Self.methods(channel) == ["events.subscribe"])
        #expect(channel.requests.first?.params == .object([:]))
        let first = try await rig.transport.sessionSnapshot()
        let second = try await rig.transport.sessionSnapshot()
        #expect(first == second)
        #expect(Self.statuses(first) == ["hc:t1": .idle])
        #expect(Self.methods(channel) == ["events.subscribe"])
        await stream.end()
    }

    @Test("status words map onto Agent statuses, and a plain terminal is a Shell row")
    func statusWordsAndShellRows() async throws {
        let channel = Self.channel(terminals: [
            Self.record("t1", status: "idle"), Self.record("t2", status: "working"),
            Self.record("t3", status: "blocked"), Self.record("t4", status: "done"),
            Self.record("t5", status: "error"),
            // Recognized by its program, but never reported a status.
            Self.record("t6", argv: ["claude"]),
            Self.record("t7", argv: ["zsh"]),
        ])
        let (rig, stream) = try await Self.subscribed(channel)
        let snapshot = try await rig.transport.sessionSnapshot()
        #expect(
            Self.statuses(snapshot) == [
                "hc:t1": .idle, "hc:t2": .working, "hc:t3": .blocked, "hc:t4": .done,
                "hc:t5": .blocked, "hc:t6": .unknown,
            ])
        let agentRow = try #require(snapshot.panes.first { $0.paneID == "hc:t1" })
        #expect(agentRow.agent == "claude")
        let shellRow = try #require(snapshot.panes.first { $0.paneID == "hc:t7" })
        #expect(shellRow.agent == nil)
        #expect(shellRow.agentStatus == .unknown)
        #expect(!snapshot.agents.contains { $0.paneID == "hc:t7" })
        await stream.end()
    }

    @Test("a status event is one pane.agent_status_changed, and the snapshot follows it")
    func statusEventYieldsOneDeltaAndUpdatesTheSnapshot() async throws {
        let channel = Self.channel(terminals: [
            Self.record("t1", status: "idle"), Self.record("t2", status: "idle"),
        ])
        let (rig, stream) = try await Self.subscribed(channel)
        let events = EventReader(stream.events)
        channel.pushEvent(seq: 11, type: "status", terminal: "t1", data: Self.statusData("working"))
        // A second event behind it proves the first yielded exactly one.
        channel.pushEvent(seq: 12, type: "status", terminal: "t2", data: Self.statusData("blocked"))
        #expect(try await events.next() == Self.statusEvent("hc:t1", "working"))
        #expect(try await events.next() == Self.statusEvent("hc:t2", "blocked"))
        let snapshot = try await rig.transport.sessionSnapshot()
        #expect(Self.statuses(snapshot) == ["hc:t1": .working, "hc:t2": .blocked])
        #expect(Self.methods(channel) == ["events.subscribe"])
        await stream.end()
    }

    @Test("a title event is a pane.updated carrying the pane")
    func titleEventYieldsPaneUpdated() async throws {
        let channel = Self.channel(terminals: [Self.record("t1", status: "idle")])
        let (rig, stream) = try await Self.subscribed(channel)
        let events = EventReader(stream.events)
        channel.pushEvent(seq: 11, type: "title", terminal: "t1", data: #"{"title":"Fix the build"}"#)
        let event = try #require(try await events.next())
        #expect(event.kind == GlobalEventKind.paneUpdated.kind)
        #expect(event.data["pane"]?["pane_id"]?.stringValue == "hc:t1")
        #expect(event.data["pane"]?["terminal_title"]?.stringValue == "Fix the build")
        let snapshot = try await rig.transport.sessionSnapshot()
        #expect(snapshot.panes.first { $0.paneID == "hc:t1" }?.terminalTitle == "Fix the build")
        await stream.end()
    }

    @Test("created, finished and removed events inside the debounce are one resync, and the snapshot follows")
    func membershipEventsCoalesceIntoOneResync() async throws {
        let channel = Self.channel(terminals: [
            Self.record("t1", status: "idle"), Self.record("t2", status: "idle"),
            Self.record("t3", status: "idle"),
        ])
        let (rig, stream) = try await Self.subscribed(channel, debounce: .milliseconds(300))
        let events = EventReader(stream.events)
        channel.pushEvent(seq: 11, type: "created", terminal: "t4", data: Self.record("t4", status: "working"))
        channel.pushEvent(
            seq: 12, type: "finished", terminal: "t2",
            data: #"{"exit_code":0,"finished_ms":5,"reason":"exited"}"#)
        channel.pushEvent(seq: 13, type: "removed", terminal: "t3", data: "{}")
        let resync = try #require(try await events.next())
        #expect(resync.kind == GlobalEventKind.workspaceMetadataUpdated.kind)
        // Nothing but a delta follows: the three events made one resync.
        channel.pushEvent(seq: 14, type: "status", terminal: "t1", data: Self.statusData("blocked"))
        #expect(try await events.next() == Self.statusEvent("hc:t1", "blocked"))
        let snapshot = try await rig.transport.sessionSnapshot()
        #expect(Self.statuses(snapshot) == ["hc:t1": .blocked, "hc:t4": .working])
        await stream.end()
    }

    @Test("events at or below the snapshot's seq are ignored")
    func staleEventsAreIgnored() async throws {
        let channel = Self.channel(terminals: [Self.record("t1", status: "idle")], seq: 10)
        let (rig, stream) = try await Self.subscribed(channel)
        let events = EventReader(stream.events)
        channel.pushEvent(seq: 10, type: "status", terminal: "t1", data: Self.statusData("working"))
        channel.pushEvent(seq: 5, type: "status", terminal: "t1", data: Self.statusData("working"))
        channel.pushEvent(seq: 11, type: "status", terminal: "t1", data: Self.statusData("blocked"))
        #expect(try await events.next() == Self.statusEvent("hc:t1", "blocked"))
        let snapshot = try await rig.transport.sessionSnapshot()
        #expect(Self.statuses(snapshot) == ["hc:t1": .blocked])
        await stream.end()
    }

    @Test("a heartbeat yields no event, and is acknowledged like any frame")
    func heartbeatYieldsNothing() async throws {
        let channel = Self.channel(terminals: [Self.record("t1", status: "idle")])
        let (rig, stream) = try await Self.subscribed(channel)
        defer { withExtendedLifetime(rig) {} }
        let events = EventReader(stream.events)
        channel.pushHeartbeat(seq: 11)
        channel.pushEvent(seq: 12, type: "status", terminal: "t1", data: Self.statusData("working"))
        #expect(try await events.next() == Self.statusEvent("hc:t1", "working"))
        await channel.waitForCredits(2)
        let credits = channel.credits
        #expect(credits.map { $0.channel } == [FakeCoreChannel.eventsChannel, FakeCoreChannel.eventsChannel])
        #expect(credits.allSatisfy { $0.bytes > 0 })
        await stream.end()
    }

    // MARK: 4. Failure and closing

    @Test("EOF finishes the stream with a retryable failure, and later calls fail instead of hanging")
    func eofEndsTheConnection() async throws {
        let channel = Self.channel(terminals: [Self.record("t1", status: "idle")])
        let (rig, stream) = try await Self.subscribed(channel)
        let events = EventReader(stream.events)
        channel.end()
        let failure = await Self.thrown { try await events.next() }
        let transportFailure = try #require(failure as? TransportError, "the stream ended without failing")
        #expect(transportFailure.isRetryable)
        #expect(await rig.transport.isConnected == false)
        let ping = await Self.thrown { try await rig.transport.ping() }
        #expect(ping as? TransportError != nil)
        let kill = await Self.thrown {
            try await rig.transport.closePane(PaneTarget(paneID: "hc:t1"), closesWorktreeGroup: false)
        }
        #expect(kill as? TransportError != nil)
    }

    @Test("close finishes the stream, closes the channel and releases the session once")
    func closeReleasesOnce() async throws {
        let channel = Self.channel()
        let (rig, stream) = try await Self.subscribed(channel)
        let events = EventReader(stream.events)
        try await rig.transport.close()
        #expect(try await events.next() == nil)
        #expect(channel.isClosed)
        #expect(await rig.session.releaseCount == 1)
        try await rig.transport.close()
        #expect(await rig.session.releaseCount == 1)
        #expect(await rig.transport.isConnected == false)
    }

    @Test("a distrusted transport closes its channel but keeps the session hold until close")
    func distrustKeepsTheHold() async throws {
        let channel = Self.channel()
        let (rig, stream) = try await Self.subscribed(channel)
        let events = EventReader(stream.events)
        await rig.transport.transportDistrusted()
        #expect(channel.isClosed)
        #expect(await rig.session.releaseCount == 0)
        #expect(try await events.next() == nil)
        let ping = await Self.thrown { try await rig.transport.ping() }
        if case .sshUnreachable? = ping as? TransportError {
        } else {
            Issue.record("ping after distrust threw \(String(describing: ping))")
        }
        try await rig.transport.close()
        #expect(await rig.session.releaseCount == 1)
    }

    // MARK: 5. Input

    @Test("promptAgent sends terminal.send with the text alone, and returns the Agent")
    func promptSendsTextAndReturnsTheAgent() async throws {
        let channel = Self.acceptingChannel(terminals: [Self.record("t1", status: "idle")])
        let (rig, stream) = try await Self.subscribed(channel)
        let agent = try await rig.transport.promptAgent(
            AgentPromptParams(
                target: "hc:t1", text: "fix it",
                wait: AgentPromptWaitOptions(timeoutMs: 1000, until: [.idle])))
        #expect(agent.paneID == "hc:t1")
        #expect(agent.kind == "claude")
        #expect(Self.methods(channel) == ["events.subscribe", "terminal.send"])
        #expect(
            channel.params(of: "terminal.send")
                == [.object(["terminal": .string("t1"), "text": .string("fix it")])])
        await stream.end()
    }

    @Test("a successful send still succeeds when its Agent finishes before the reply")
    func promptAcknowledgedAfterAgentFinished() async throws {
        let (sends, sent) = AsyncStream<Void>.makeStream()
        let channel = Self.channel(terminals: [Self.record("t1", status: "idle")]) { method, _ in
            if method == "terminal.send" { sent.yield(()) }
            return .none
        }
        let (rig, stream) = try await Self.subscribed(channel)
        let events = EventReader(stream.events)
        let prompt = Task {
            try await rig.transport.promptAgent(AgentPromptParams(target: "hc:t1", text: "hi"))
        }
        var sendsIterator = sends.makeAsyncIterator()
        _ = await sendsIterator.next()
        channel.pushEvent(
            seq: 11, type: "finished", terminal: "t1",
            data: #"{"exit_code":0,"finished_ms":5,"reason":"exited"}"#)
        _ = try await events.next()
        #expect(try await rig.transport.sessionSnapshot().agents.isEmpty)
        channel.answer("terminal.send", result: "{}")
        let result = await prompt.result
        #expect(try result.get().paneID == "hc:t1")
        #expect(channel.params(of: "terminal.send").count == 1)
        await stream.end()
    }

    @Test(
        "core's refusal kinds become the codes the UI branches on",
        arguments: [
            ("blocked", "agent_blocked"), ("unavailable", "agent_not_ready"),
            ("not_found", "agent_not_found"),
        ])
    func promptRefusalsMapToCodes(kind: String, code: String) async throws {
        let channel = Self.channel(terminals: [Self.record("t1", status: "idle")]) { method, _ in
            method == "terminal.send" ? .error(kind: kind, message: "no thanks", hint: "") : .none
        }
        let (rig, stream) = try await Self.subscribed(channel)
        let error = await Self.thrown {
            try await rig.transport.promptAgent(AgentPromptParams(target: "hc:t1", text: "hi"))
        }
        #expect(error as? HerdrAPIError == HerdrAPIError(code: code, message: "no thanks"))
        await stream.end()
    }

    @Test("a prompt after the link failed is a request that never left")
    func promptAfterLinkFailureWasNotSent() async throws {
        let channel = Self.acceptingChannel(terminals: [Self.record("t1", status: "idle")])
        let (rig, stream) = try await Self.subscribed(channel)
        let events = EventReader(stream.events)
        channel.end()
        _ = await Self.thrown { try await events.next() }
        let error = await Self.thrown {
            try await rig.transport.promptAgent(AgentPromptParams(target: "hc:t1", text: "hi"))
        }
        #expect(error is RequestNotSentError)
        #expect(!Self.methods(channel).contains("terminal.send"))
    }

    @Test("an Agent on its sign-in screen is refused and nothing is sent")
    func signInScreenRefusesThePrompt() async throws {
        let screen = AgentScreenTests.cursorFirstScreen.joined(separator: "\n")
        let channel = Self.channel(
            terminals: [Self.record("t1", status: "idle", app: "cursor")]
        ) { method, _ in
            method == "terminal.read"
                ? .result(Self.json(["text": screen, "complete": true] as [String: Any])) : .result("{}")
        }
        let (rig, stream) = try await Self.subscribed(channel)
        let error = await Self.thrown {
            try await rig.transport.promptAgent(AgentPromptParams(target: "hc:t1", text: "hi"))
        }
        #expect(error as? AgentSignInRequiredError == AgentSignInRequiredError(kind: "cursor", target: "hc:t1"))
        #expect(
            channel.params(of: "terminal.read")
                == [.object(["terminal": .string("t1"), "lines": .number(0)])])
        #expect(channel.params(of: "terminal.send").isEmpty)
        await stream.end()
    }

    @Test("an Agent of a sign-in kind showing its prompt still gets the text")
    func readyScreenDoesNotRefuseThePrompt() async throws {
        let channel = Self.channel(
            terminals: [Self.record("t1", status: "idle", app: "cursor")]
        ) { method, _ in
            method == "terminal.read"
                ? .result(Self.json(["text": "> ready for your next task", "complete": true] as [String: Any]))
                : .result("{}")
        }
        let (rig, stream) = try await Self.subscribed(channel)
        _ = try await rig.transport.promptAgent(AgentPromptParams(target: "hc:t1", text: "hi"))
        #expect(channel.params(of: "terminal.send").count == 1)
        await stream.end()
    }

    @Test("agent keys are renamed for core and sent as one terminal.keys")
    func agentKeysAreRenamed() async throws {
        let channel = Self.acceptingChannel(terminals: [Self.record("t1", status: "idle")])
        let (rig, stream) = try await Self.subscribed(channel)
        try await rig.transport.sendAgentKeys(AgentSendKeysParams(keys: ["minus", "esc"], target: "hc:t1"))
        #expect(
            channel.params(of: "terminal.keys")
                == [.object(["terminal": .string("t1"), "keys": .array([.string("-"), .string("esc")])])])
        await stream.end()
    }

    @Test("a key core cannot type by name is refused before anything is sent")
    func unsupportedKeySendsNothing() async throws {
        let channel = Self.acceptingChannel(terminals: [Self.record("t1", status: "idle")])
        let (rig, stream) = try await Self.subscribed(channel)
        let error = await Self.thrown {
            try await rig.transport.sendAgentKeys(AgentSendKeysParams(keys: ["esc", "plus"], target: "hc:t1"))
        }
        #expect((error as? HerdrAPIError)?.code == "unsupported")
        #expect(Self.methods(channel) == ["events.subscribe"])
        await stream.end()
    }

    @Test("pane input: text with Enter is terminal.send, keys alone are terminal.keys, text alone is unsupported")
    func paneInputShapes() async throws {
        let channel = Self.acceptingChannel(terminals: [Self.record("t1")])
        let (rig, stream) = try await Self.subscribed(channel)
        try await rig.transport.sendPaneInput(
            PaneSendInputParams(paneID: "hc:t1", keys: ["Enter"], text: "ls -la"))
        #expect(
            channel.params(of: "terminal.send")
                == [.object(["terminal": .string("t1"), "text": .string("ls -la")])])
        #expect(channel.params(of: "terminal.keys").isEmpty)
        try await rig.transport.sendPaneInput(PaneSendInputParams(paneID: "hc:t1", keys: ["up", "enter"]))
        #expect(
            channel.params(of: "terminal.keys")
                == [.object(["terminal": .string("t1"), "keys": .array([.string("up"), .string("enter")])])])
        let before = channel.requests.count
        let error = await Self.thrown {
            try await rig.transport.sendPaneInput(PaneSendInputParams(paneID: "hc:t1", text: "no enter"))
        }
        #expect((error as? HerdrAPIError)?.code == "unsupported")
        #expect(channel.requests.count == before)
        await stream.end()
    }

    @Test("reading a pane: visible asks for no scrollback, recent asks its lines, blank rows are trimmed")
    func readPaneAsksAndTrims() async throws {
        let rows = (1...60).map { "row \($0)" }
        let tall = rows.joined(separator: "\n") + "\n\n   \n"
        let channel = Self.channel(terminals: [Self.record("t1")]) { method, params in
            guard method == "terminal.read" else { return .none }
            let text = params["lines"] == .number(0) ? "top\nprompt $\n\n\n" : tall
            return .result(Self.json(["text": text, "complete": true] as [String: Any]))
        }
        let (rig, stream) = try await Self.subscribed(channel)
        let visible = try await rig.transport.readPane(PaneReadParams(paneID: "hc:t1", source: .visible))
        #expect(visible.text == "top\nprompt $")
        #expect(visible.source == .visible)
        #expect(!visible.truncated)
        let recent = try await rig.transport.readPane(
            PaneReadParams(paneID: "hc:t1", source: .recent, lines: 40))
        #expect(recent.text == rows.suffix(40).joined(separator: "\n"))
        #expect(recent.truncated)
        #expect(
            channel.params(of: "terminal.read")
                == [
                    .object(["terminal": .string("t1"), "lines": .number(0)]),
                    .object(["terminal": .string("t1"), "lines": .number(40)]),
                ])
        await stream.end()
    }

    // MARK: 6. Close and seen

    @Test("closePane is exactly one terminal.kill")
    func closePaneKillsOnce() async throws {
        let channel = Self.acceptingChannel(terminals: [Self.record("t1"), Self.record("t2")])
        let (rig, stream) = try await Self.subscribed(channel)
        try await rig.transport.closePane(PaneTarget(paneID: "hc:t2"), closesWorktreeGroup: true)
        #expect(Self.methods(channel) == ["events.subscribe", "terminal.kill"])
        #expect(channel.params(of: "terminal.kill") == [Self.terminalObject("t2")])
        await stream.end()
    }

    @Test("closeTab kills every terminal of the Tab and no others; an unknown tab sends nothing")
    func closeTabKillsItsTerminals() async throws {
        let shared = ["herdr.space": "proj", "herdr.tab": "main"]
        let channel = Self.acceptingChannel(terminals: [
            Self.record("t1", labels: shared), Self.record("t2", labels: shared),
            Self.record("t3", labels: ["herdr.space": "proj", "herdr.tab": "other"]),
        ])
        let (rig, stream) = try await Self.subscribed(channel)
        let snapshot = try await rig.transport.sessionSnapshot()
        let tabID = try #require(snapshot.panes.first { $0.paneID == "hc:t1" }?.tabID)
        #expect(snapshot.panes.first { $0.paneID == "hc:t2" }?.tabID == tabID)
        #expect(snapshot.tabs.first { $0.tabID == tabID }?.paneCount == 2)
        try await rig.transport.closeTab(TabTarget(tabID: tabID))
        #expect(
            channel.params(of: "terminal.kill")
                == [Self.terminalObject("t1"), Self.terminalObject("t2")])
        let error = await Self.thrown {
            try await rig.transport.closeTab(TabTarget(tabID: "hc:tab:nope"))
        }
        #expect((error as? HerdrAPIError)?.code == "tab_not_found")
        #expect(channel.params(of: "terminal.kill").count == 2)
        await stream.end()
    }

    @Test("focusing a Done Agent presents Idle with no request, and Done returns when the status word changes")
    func focusAgentIsAnOverlay() async throws {
        let channel = Self.channel(terminals: [
            Self.record("t1", status: "done", turn: 3), Self.record("t2", status: "done", turn: 1),
        ])
        let (rig, stream) = try await Self.subscribed(channel)
        let events = EventReader(stream.events)
        #expect(Self.statuses(try await rig.transport.sessionSnapshot()) == ["hc:t1": .done, "hc:t2": .done])
        try await rig.transport.focusAgent(AgentTarget(target: "hc:t1"))
        #expect(Self.statuses(try await rig.transport.sessionSnapshot()) == ["hc:t1": .idle, "hc:t2": .done])
        #expect(Self.methods(channel) == ["events.subscribe"])
        // The agent goes back to work and finishes again.
        channel.pushEvent(seq: 11, type: "status", terminal: "t1", data: Self.statusData("working"))
        #expect(try await events.next() == Self.statusEvent("hc:t1", "working"))
        channel.pushEvent(seq: 12, type: "status", terminal: "t1", data: Self.statusData("done", statusMs: 3000))
        #expect(try await events.next() == Self.statusEvent("hc:t1", "done"))
        #expect(Self.statuses(try await rig.transport.sessionSnapshot()) == ["hc:t1": .done, "hc:t2": .done])
        await stream.end()
    }

    // MARK: 7. Attach and members core does not offer yet

    @Test("attaching an Agent pane runs core's attach line for its address; takeover means nothing")
    func attachRunsTheCoreLine() async throws {
        let rig = try await Self.open(Self.channel())
        let attach = ScriptedAttachSession()
        await rig.session.serveAttach(attach.session)
        let request = TerminalAttachRequest(
            target: .agentPane("hc:t3"), takeover: true, cols: 100, rows: 30)
        _ = try await rig.transport.attachTerminal(request)
        let commands = await rig.session.attachCommands
        #expect(commands.count == 1)
        let command = try #require(commands.first)
        #expect(command.hasSuffix(" t3"))
        #expect(command.contains(CoreConnectCommand.notInstalledText))
        #expect(command.contains(AttachBootstrapHandshake.markerPrintfFormat))
        #expect(command.contains("attach"))
        #expect(command.contains(Self.hostPATH))
        #expect(command.contains(Self.detectedCorePath))
        #expect(!command.contains("takeover"))
        #expect(await rig.session.attachRequests == [request])
        try await rig.transport.close()
    }

    @Test("a Terminal id of this core attaches to its address; one of another core state is not found")
    func attachByTerminalID() async throws {
        let rig = try await Self.open(Self.channel())
        let attach = ScriptedAttachSession()
        await rig.session.serveAttach(attach.session)
        _ = try await rig.transport.attachTerminal(
            TerminalAttachRequest(
                target: .terminal("hc:\(Self.corePrefix):t3"), cols: 80, rows: 24))
        #expect(await rig.session.attachCommands.count == 1)
        #expect(await rig.session.attachCommands.first?.hasSuffix(" t3") == true)
        let error = await Self.thrown {
            try await rig.transport.attachTerminal(
                TerminalAttachRequest(target: .terminal("hc:deadbeef:t3"), cols: 80, rows: 24))
        }
        #expect((error as? HerdrAPIError)?.code == "pane_not_found")
        #expect(await rig.session.attachCommands.count == 1)
        try await rig.transport.close()
    }

    @Test("an address that cannot be quoted is refused before any command runs")
    func attachRefusesAQuote() async throws {
        let rig = try await Self.open(Self.channel())
        let attach = ScriptedAttachSession()
        await rig.session.serveAttach(attach.session)
        let error = await Self.thrown {
            try await rig.transport.attachTerminal(
                TerminalAttachRequest(target: .agentPane("hc:t'3"), cols: 80, rows: 24))
        }
        #expect(error as? TransportError != nil)
        #expect(await rig.session.attachCommands.isEmpty)
        try await rig.transport.close()
    }

    @Test("no mosh server, and the members core lacks fail as unsupported without a request")
    func notYetMembersAreUnsupported() async throws {
        let rig = try await Self.open(Self.channel())
        let transport = rig.transport
        #expect(try await transport.probeMoshServer() == false)

        let others: [(String, HerdrAPIError?)] = [
            (
                "startAgentInNewWorktree",
                await Self.apiError {
                    try await transport.startAgentInNewWorktree(
                        AgentLaunchRequest(kind: "claude", name: "x"), worktree: WorktreeSpec(),
                        attempt: WorktreeLaunchAttempt())
                }
            ),
            (
                "renameAgent",
                await Self.apiError {
                    try await transport.renameAgent(AgentRenameParams(target: "hc:t1", name: "new"))
                }
            ),
            (
                "movePane",
                await Self.apiError {
                    try await transport.movePane(
                        PaneMoveParams(
                            destination: .newTab(PaneMoveDestinationNewTab()), paneID: "hc:t1"))
                }
            ),
            (
                "listWorktrees",
                await Self.apiError {
                    try await transport.listWorktrees(forWorkspaceID: "hc:ws:/work/app")
                }
            ),
        ]
        for (name, error) in others {
            #expect(error?.code == "unsupported", "\(name)")
            #expect(error?.message.hasSuffix("is not available on herdr-core yet.") == true, "\(name)")
        }
        #expect(rig.channel.requests.isEmpty)
        try await transport.close()
    }

    static func apiError<T>(_ operation: () async throws -> T) async -> HerdrAPIError? {
        await thrown(operation) as? HerdrAPIError
    }

    // MARK: 8. A second subscription

    @Test("a stream ended and another asked for share the connection and its inventory")
    func resubscribingReusesTheConnection() async throws {
        let channel = Self.channel(terminals: [Self.record("t1", status: "idle")], seq: 10)
        let session = FakeHostSSHServices(exec: Self.loginPathExec)
        await session.serveCore(channel)
        let transport = try await CoreTransport.open(
            session: session, configuration: Self.configuration(), memory: nil,
            corePath: Self.detectedCorePath)

        // EventsSession resubscribes whenever its pane set changes.
        let firstStream = try await transport.subscribeToEvents([])
        #expect(Self.statuses(try await transport.sessionSnapshot()) == ["hc:t1": .idle])
        await firstStream.end()
        let ended = EventReader(firstStream.events)
        #expect(try await ended.next() == nil)

        // An event that lands while nobody consumes still moves the inventory.
        channel.pushEvent(seq: 11, type: "status", terminal: "t1", data: Self.statusData("working"))
        await channel.waitForCredits(1)

        let secondStream = try await transport.subscribeToEvents([])
        #expect(await session.coreCommands.count == 1, "the connection is reused")
        #expect(Self.methods(channel) == ["events.subscribe"], "one subscription per connection")
        #expect(!channel.isClosed)
        #expect(Self.statuses(try await transport.sessionSnapshot()) == ["hc:t1": .working])

        let events = EventReader(secondStream.events)
        channel.pushEvent(seq: 12, type: "status", terminal: "t1", data: Self.statusData("done"))
        #expect(try await events.next() == Self.statusEvent("hc:t1", "done"))
        try await transport.close()
    }

    // MARK: 9. Lifetime (CORE-01)

    @Test("a stopped core fails connect with coreNotRunning and nothing starts it")
    func stoppedCoreIsNeverStartedByConnect() async {
        let channel = FakeCoreChannel(emitsMarker: false) { _, _ in .none }
        channel.finishCommand(
            exitStatus: CoreConnectCommand.notRunningStatus,
            standardError: CoreConnectCommand.notRunningText + "\n")
        let failure = await Self.openFailure(channel)
        #expect(failure.error as? TransportError == .coreNotRunning)
        #expect(await failure.session.coreCommands.count == 1, "one connect line, no redial")
        #expect(
            await failure.session.execs.allSatisfy { $0.command == CoreLoginPath.command },
            "no start exec, only the login PATH")
        #expect(channel.isClosed)
    }

    @Test("a lost link stays lost: calls and subscribes fail with no second dial")
    func lostLinkIsNeverRedialed() async throws {
        let channel = Self.channel(terminals: [Self.record("t1", status: "idle")])
        let (rig, stream) = try await Self.subscribed(channel)
        let events = EventReader(stream.events)
        channel.end()
        _ = await Self.thrown { try await events.next() }
        for _ in 0..<2 {
            let ping = await Self.thrown { try await rig.transport.ping() }
            #expect((ping as? TransportError)?.isRetryable == true)
        }
        let resubscribe = await Self.thrown { try await rig.transport.subscribeToEvents([]) }
        #expect(resubscribe as? TransportError != nil)
        #expect(resubscribe as? TransportError != .eventsChannelAlreadyOpen)
        #expect(await rig.session.coreCommands.count == 1)
        #expect(await rig.transport.isConnected == false)
        try await rig.transport.close()
        #expect(await rig.session.releaseCount == 1)
    }

    @Test("close after distrust releases once and calls then fail as cancelled")
    func closeAfterDistrust() async throws {
        let rig = try await Self.open(Self.channel())
        await rig.transport.transportDistrusted()
        await rig.transport.transportDistrusted()
        #expect(await rig.session.releaseCount == 0)
        try await rig.transport.close()
        #expect(await rig.session.releaseCount == 1)
        let ping = await Self.thrown { try await rig.transport.ping() }
        #expect(ping as? TransportError == .cancelled)
        await rig.transport.transportDistrusted()
        try await rig.transport.close()
        #expect(await rig.session.releaseCount == 1)
        #expect(rig.channel.closeCount == 1)
    }

    @Test("distrust after close changes nothing")
    func distrustAfterClose() async throws {
        let rig = try await Self.open(Self.channel())
        try await rig.transport.close()
        await rig.transport.transportDistrusted()
        let ping = await Self.thrown { try await rig.transport.ping() }
        #expect(ping as? TransportError == .cancelled)
        #expect(await rig.session.releaseCount == 1)
        #expect(await rig.transport.isConnected == false)
    }

    @Test("an open transport is connected while its link is open, and not once distrusted")
    func isConnectedFollowsTheLink() async throws {
        let rig = try await Self.open(Self.channel())
        #expect(await rig.transport.isConnected)
        await rig.transport.transportDistrusted()
        #expect(await rig.transport.isConnected == false)
        try await rig.transport.close()
    }

    @Test("a transport dropped without close closes its channel and releases its hold once")
    func droppedTransportReleases() async throws {
        let session = FakeHostSSHServices(exec: Self.loginPathExec)
        let channel = Self.channel()
        await session.serveCore(channel)
        do {
            let transport = try await CoreTransport.open(
                session: session, configuration: Self.configuration(), memory: nil,
                corePath: Self.detectedCorePath)
            _ = try await transport.ping()
        }
        try await waitUntil("the dropped transport releases its hold") {
            await session.releaseCount == 1
        }
        try await waitUntil("the dropped transport closes its channel") { channel.isClosed }
    }

    @Test("a closed or distrusted transport dropped later releases its hold exactly once", arguments: [true, false])
    func droppedAfterCloseOrDistrust(closes: Bool) async throws {
        let session = FakeHostSSHServices(exec: Self.loginPathExec)
        await session.serveCore(Self.channel())
        do {
            let transport = try await CoreTransport.open(
                session: session, configuration: Self.configuration(), memory: nil,
                corePath: Self.detectedCorePath)
            if closes {
                try await transport.close()
            } else {
                await transport.transportDistrusted()
            }
        }
        try await waitUntil("the hold is released") { await session.releaseCount >= 1 }
        // Nothing else may release it a second time.
        try await Task.sleep(for: .milliseconds(100))
        #expect(await session.releaseCount == 1)
    }

    // MARK: 10. Event consumers (CORE-02)

    @Test("a second consumer while the first still subscribes, or while it is live, is refused")
    func secondConsumerIsRefused() async throws {
        let channel = FakeCoreChannel { method, _ in
            switch method {
            case "doc.get": return .result(#"{"value":null,"version":0}"#)
            default: return .none
            }
        }
        let rig = try await Self.open(channel)
        let first = Task { try await rig.transport.subscribeToEvents([]) }
        await channel.waitForRequests(1)
        let during = await Self.thrown { try await rig.transport.subscribeToEvents([]) }
        #expect(during as? TransportError == .eventsChannelAlreadyOpen)
        channel.answer(
            "events.subscribe",
            result: FakeCoreChannel.subscribeResult(seq: 10, terminals: [Self.record("t1", status: "idle")]))
        let stream = try await first.value
        let live = await Self.thrown { try await rig.transport.subscribeToEvents([]) }
        #expect(live as? TransportError == .eventsChannelAlreadyOpen)
        #expect(Self.statuses(try await rig.transport.sessionSnapshot()) == ["hc:t1": .idle])
        #expect(Self.methods(channel) == ["events.subscribe"])
        await stream.end()
        try await rig.transport.close()
    }

    @Test("ending an old stream again does not end the stream that replaced it")
    func staleEndLeavesTheReplacement() async throws {
        let channel = Self.channel(terminals: [Self.record("t1", status: "idle")])
        let rig = try await Self.open(channel)
        let first = try await rig.transport.subscribeToEvents([])
        await first.end()
        let second = try await rig.transport.subscribeToEvents([])
        await first.end()
        let events = EventReader(second.events)
        channel.pushEvent(seq: 11, type: "status", terminal: "t1", data: Self.statusData("working"))
        #expect(try await events.next() == Self.statusEvent("hc:t1", "working"))
        let third = await Self.thrown { try await rig.transport.subscribeToEvents([]) }
        #expect(third as? TransportError == .eventsChannelAlreadyOpen)
        try await rig.transport.close()
    }

    @Test("a consumer that stops iterating frees its slot for the next")
    func abandonedConsumerFreesTheSlot() async throws {
        let channel = Self.channel(terminals: [Self.record("t1", status: "idle")])
        let rig = try await Self.open(channel)
        let first = try await rig.transport.subscribeToEvents([])
        let iterating = Task {
            do { for try await _ in first.events {} } catch {}
        }
        iterating.cancel()
        await iterating.value
        let box = StreamBox()
        try await waitUntil("the terminated stream frees the slot") {
            guard let stream = try? await rig.transport.subscribeToEvents([]) else { return false }
            await box.keep(stream)
            return true
        }
        let second = try #require(await box.stream)
        let events = EventReader(second.events)
        channel.pushEvent(seq: 11, type: "status", terminal: "t1", data: Self.statusData("blocked"))
        #expect(try await events.next() == Self.statusEvent("hc:t1", "blocked"))
        #expect(Self.methods(channel) == ["events.subscribe"])
        try await rig.transport.close()
    }

    @Test("a resync pending when its consumer ends is never delivered to the next one")
    func pendingResyncDiesWithItsConsumer() async throws {
        let channel = Self.channel(terminals: [Self.record("t1", status: "idle")])
        let rig = try await Self.open(channel, debounce: .milliseconds(200))
        let first = try await rig.transport.subscribeToEvents([])
        channel.pushEvent(seq: 11, type: "created", terminal: "t2", data: Self.record("t2", status: "idle"))
        // Applied, so its resync is armed for the first stream.
        try await waitUntil("the created terminal is in the inventory") {
            try await rig.transport.sessionSnapshot().panes.contains { $0.paneID == "hc:t2" }
        }
        await first.end()
        let second = try await rig.transport.subscribeToEvents([])
        let events = EventReader(second.events)
        // Well past the debounce window the first stream armed.
        try await Task.sleep(for: .milliseconds(400))
        channel.pushEvent(seq: 12, type: "status", terminal: "t1", data: Self.statusData("working"))
        #expect(try await events.next() == Self.statusEvent("hc:t1", "working"))
        try await rig.transport.close()
    }

    @Test("close while the first subscribe waits fails it and hands out no stream")
    func closeDuringTheFirstSubscribe() async throws {
        let channel = FakeCoreChannel { method, _ in
            method == "doc.get" ? .result(#"{"value":null,"version":0}"#) : .none
        }
        let rig = try await Self.open(channel)
        let subscribing = Task { try await rig.transport.subscribeToEvents([]) }
        await channel.waitForRequests(1)
        try await rig.transport.close()
        let error = await Self.thrown { try await subscribing.value }
        #expect(error as? TransportError != nil)
        #expect(await rig.session.releaseCount == 1)
    }

    @Test("a refused events.subscribe is retried on the same connection")
    func refusedSubscribeIsRetried() async throws {
        let refusals = Mutex(1)
        let channel = FakeCoreChannel { method, _ in
            switch method {
            case "doc.get":
                return .result(#"{"value":null,"version":0}"#)
            case "events.subscribe":
                let refuse = refusals.withLock { count -> Bool in
                    defer { count -= 1 }
                    return count > 0
                }
                if refuse { return .error(kind: "internal", message: "not now", hint: "") }
                return .result(
                    FakeCoreChannel.subscribeResult(
                        seq: 10, terminals: [CoreTransportTests.record("t1", status: "idle")]))
            default:
                return .none
            }
        }
        let rig = try await Self.open(channel)
        let refused = await Self.thrown { try await rig.transport.subscribeToEvents([]) }
        #expect(refused != nil)
        let stream = try await rig.transport.subscribeToEvents([])
        #expect(Self.statuses(try await rig.transport.sessionSnapshot()) == ["hc:t1": .idle])
        #expect(Self.methods(channel) == ["events.subscribe", "events.subscribe"])
        #expect(await rig.session.coreCommands.count == 1)
        await stream.end()
        try await rig.transport.close()
    }

    // MARK: 11. Done acknowledgement (CORE-08)

    @Test("focusing a Working Agent never hides its next Done")
    func focusWhileWorkingKeepsTheNextDone() async throws {
        let channel = Self.channel(terminals: [Self.record("t1", status: "working", turn: 2)])
        let (rig, stream) = try await Self.subscribed(channel)
        let events = EventReader(stream.events)
        try await rig.transport.focusAgent(AgentTarget(target: "hc:t1"))
        channel.pushEvent(seq: 11, type: "status", terminal: "t1", data: Self.statusData("done"))
        #expect(try await events.next() == Self.statusEvent("hc:t1", "done"))
        #expect(Self.statuses(try await rig.transport.sessionSnapshot()) == ["hc:t1": .done])
        await stream.end()
        try await rig.transport.close()
    }

    @Test("focusing an unknown pane, or a transport nobody subscribed, changes nothing")
    func focusWithoutARecordIsIgnored() async throws {
        let channel = Self.channel(terminals: [Self.record("t1", status: "done", turn: 1)]) { method, _ in
            method == "terminal.list"
                ? .result("{\"terminals\":[" + CoreTransportTests.record("t1", status: "done", turn: 1) + "]}")
                : .none
        }
        let rig = try await Self.open(channel)
        try await rig.transport.focusAgent(AgentTarget(target: "hc:t1"))
        #expect(Self.statuses(try await rig.transport.sessionSnapshot()) == ["hc:t1": .done])
        let stream = try await rig.transport.subscribeToEvents([])
        try await rig.transport.focusAgent(AgentTarget(target: "hc:t9"))
        try await rig.transport.focusAgent(AgentTarget(target: "not-a-core-pane"))
        #expect(Self.statuses(try await rig.transport.sessionSnapshot()) == ["hc:t1": .done])
        await stream.end()
        try await rig.transport.close()
    }

    @Test("a removed and re-created address does not inherit the seen Done")
    func recreatedAddressShowsDone() async throws {
        let channel = Self.channel(terminals: [Self.record("t1", status: "done", turn: 3)])
        let (rig, stream) = try await Self.subscribed(channel)
        try await rig.transport.focusAgent(AgentTarget(target: "hc:t1"))
        #expect(Self.statuses(try await rig.transport.sessionSnapshot()) == ["hc:t1": .idle])
        channel.pushEvent(seq: 11, type: "removed", terminal: "t1", data: "{}")
        try await waitUntil("the terminal is removed") {
            try await rig.transport.sessionSnapshot().agents.isEmpty
        }
        channel.pushEvent(
            seq: 12, type: "created", terminal: "t1", data: Self.record("t1", status: "done", turn: 3))
        try await waitUntil("the new terminal at the address shows Done") {
            Self.statuses(try await rig.transport.sessionSnapshot()) == ["hc:t1": .done]
        }
        await stream.end()
        try await rig.transport.close()
    }

    @Test("B-23: a seen Done that finishes another turn shows Done again, in the snapshot and as an event")
    func newTurnAfterASeenDoneShowsDone() async throws {
        let channel = Self.channel(terminals: [
            Self.record("t1", status: "done", turn: 3), Self.record("t2", status: "idle"),
        ])
        let (rig, stream) = try await Self.subscribed(channel)
        let events = EventReader(stream.events)
        try await rig.transport.focusAgent(AgentTarget(target: "hc:t1"))
        // The Console reads the Idle it now presents (and the snapshot caches it).
        #expect(Self.statuses(try await rig.transport.sessionSnapshot())["hc:t1"] == .idle)
        // The agent finishes another turn without its status word changing.
        channel.pushEvent(seq: 11, type: "turn", terminal: "t1", data: #"{"turn":4}"#)
        // A later event on another terminal proves the turn was applied first.
        channel.pushEvent(seq: 12, type: "status", terminal: "t2", data: Self.statusData("working"))
        let first = try await events.next()
        #expect(first == Self.statusEvent("hc:t1", "done"))
        if first == Self.statusEvent("hc:t1", "done") {
            #expect(try await events.next() == Self.statusEvent("hc:t2", "working"))
        }
        #expect(
            Self.statuses(try await rig.transport.sessionSnapshot()) == ["hc:t1": .done, "hc:t2": .working])
        await stream.end()
        try await rig.transport.close()
    }

    @Test("a turn event for a terminal nobody has seen yields no event")
    func turnWithoutASeenDoneIsSilent() async throws {
        let channel = Self.channel(terminals: [
            Self.record("t1", status: "done", turn: 3), Self.record("t2", status: "idle"),
        ])
        let (rig, stream) = try await Self.subscribed(channel)
        let events = EventReader(stream.events)
        channel.pushEvent(seq: 11, type: "turn", terminal: "t1", data: #"{"turn":4}"#)
        channel.pushEvent(seq: 12, type: "status", terminal: "t2", data: Self.statusData("working"))
        #expect(try await events.next() == Self.statusEvent("hc:t2", "working"))
        #expect(Self.statuses(try await rig.transport.sessionSnapshot())["hc:t1"] == .done)
        await stream.end()
        try await rig.transport.close()
    }

    @Test("a missed snapshot keeps a seen Done that still matches and drops one that moved on")
    func missedSnapshotPrunesSeenDone() async throws {
        let channel = Self.channel(terminals: [
            Self.record("t1", status: "done", turn: 3), Self.record("t2", status: "done", turn: 5),
        ])
        let (rig, stream) = try await Self.subscribed(channel)
        try await rig.transport.focusAgent(AgentTarget(target: "hc:t1"))
        try await rig.transport.focusAgent(AgentTarget(target: "hc:t2"))
        #expect(
            Self.statuses(try await rig.transport.sessionSnapshot()) == ["hc:t1": .idle, "hc:t2": .idle])
        let terminals = [
            Self.record("t1", status: "done", turn: 3), Self.record("t2", status: "done", turn: 6),
        ].joined(separator: ",")
        channel.pushMissed(seq: 20, terminals: terminals)
        try await waitUntil("the missed snapshot applies") {
            Self.statuses(try await rig.transport.sessionSnapshot())["hc:t2"] == .done
        }
        #expect(
            Self.statuses(try await rig.transport.sessionSnapshot()) == ["hc:t1": .idle, "hc:t2": .done])
        await stream.end()
        try await rig.transport.close()
    }
}

/// Keeps the stream a `waitUntil` condition obtained.
actor StreamBox {
    private(set) var stream: HerdrEventStream?
    func keep(_ stream: HerdrEventStream) { self.stream = stream }
}
