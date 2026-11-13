import Foundation
import Synchronization
import Testing

@testable import Waycar

/// Starting an agent on herdr-core (design §9): the shared launch builder,
/// the folder and PATH rules, `terminal.run` against a scripted core, the
/// plain missing-program message and the first-prompt gate.
@Suite("herdr-core launches", .timeLimit(.minutes(1)))
struct CoreLaunchTests {
    // MARK: Fixtures

    static let launchPATH = "/home/u/.local/bin:/usr/bin:/bin"
    static let pathMarker = "@@WAYCAR-LAUNCH-PATH@@"

    /// `machine.exec`'s answer for `code`, with core's base64 output fields.
    static func execReply(code: Int, stdout: String = "") -> String {
        let encoded = Data(stdout.utf8).base64EncodedString()
        return CoreTransportTests.json(
            ["code": code, "signal": NSNull(), "stdout": encoded, "stderr": "", "timed_out": false, "ms": 3]
                as [String: Any])
    }

    /// The Host's exec: the login PATH, then the launch PATH built from it.
    /// `launchPaths` is handed out one per computation (the last repeats).
    static func exec(launchPaths: [String] = [launchPATH]) -> FakeHostSSHServices.ExecHandler {
        let next = Mutex(0)
        return { command, _ in
            if command == CoreLoginPath.command {
                return FakeHostSSHServices.result(
                    stdout: "@@WAYCAR-LOGIN-PATH@@/home/u/bin:/usr/bin@@WAYCAR-LOGIN-PATH@@")
            }
            if command.contains(pathMarker) {
                let index = next.withLock { value -> Int in
                    defer { value += 1 }
                    return min(value, launchPaths.count - 1)
                }
                return FakeHostSSHServices.result(stdout: pathMarker + launchPaths[index] + pathMarker)
            }
            return FakeHostSSHServices.result(exitStatus: 127)
        }
    }

    /// A core that holds `terminals`, answers `machine.exec` with `exec` and
    /// `terminal.run` with `run`, and takes `terminal.send`.
    static func channel(
        terminals: [String] = [], exec: @escaping @Sendable (JSONValue) -> FakeCoreChannel.Reply,
        run: @escaping @Sendable (JSONValue) -> FakeCoreChannel.Reply,
        read: @escaping @Sendable (JSONValue) -> FakeCoreChannel.Reply = { _ in
            .result(CoreTransportTests.json(["text": "", "complete": true] as [String: Any]))
        },
        send: @escaping @Sendable (JSONValue) -> FakeCoreChannel.Reply = { _ in .result("{}") },
        get: @escaping @Sendable (JSONValue) -> FakeCoreChannel.Reply = { _ in .none }
    ) -> FakeCoreChannel {
        CoreTransportTests.channel(terminals: terminals) { method, params in
            switch method {
            case "machine.exec": return exec(params)
            case "terminal.run": return run(params)
            case "terminal.read": return read(params)
            case "terminal.send": return send(params)
            case "terminal.get": return get(params)
            case "terminal.list":
                return .result("{\"terminals\":[" + terminals.joined(separator: ",") + "]}")
            default: return .none
            }
        }
    }

    static func open(
        _ channel: FakeCoreChannel, launchPaths: [String] = [launchPATH],
        unreportedWait: Duration = .milliseconds(100),
        memory: (any HostConnectionMemory)? = nil
    ) async throws -> (transport: CoreTransport, session: FakeHostSSHServices, stream: HerdrEventStream) {
        let session = FakeHostSSHServices(exec: exec(launchPaths: launchPaths))
        await session.serveCore(channel)
        var configuration = CoreTransportTests.configuration()
        configuration.unreportedWait = unreportedWait
        let transport = try await CoreTransport.open(
            session: session, configuration: configuration, memory: memory,
            corePath: CoreTransportTests.detectedCorePath)
        let stream = try await transport.subscribeToEvents([])
        return (transport, session, stream)
    }

    static let accepts: @Sendable (JSONValue) -> FakeCoreChannel.Reply = { _ in
        .result(execReply(code: 0))
    }

    static func runs(_ record: String) -> @Sendable (JSONValue) -> FakeCoreChannel.Reply {
        { _ in .result(record) }
    }

    // MARK: Launching

    @Test("a tagged retry returns its earlier Agent without running or joining")
    func taggedRetryReturnsEarlierAgent() async throws {
        let id = UUID()
        let record = CoreTransportTests.record(
            "t5", labels: ["waycar.kind": "claude", "waycar.launch": id.uuidString],
            argv: ["claude"], status: "idle")
        let channel = Self.channel(terminals: [record], exec: Self.accepts, run: Self.runs(record))
        let (transport, _, stream) = try await Self.open(channel)
        let steps = LaunchStepLog()
        let agent = try await steps.recording {
            try await transport.startAgent(AgentLaunchRequest(
                kind: "claude", name: "claude-1", cwd: "/work/app",
                launchID: id, mayHaveStarted: true))
        }
        #expect(agent.paneID == "hc:t5")
        #expect(channel.params(of: "terminal.run").isEmpty)
        #expect(!steps.all.contains(.joiningRunningAgent))
        await stream.end()
        try await transport.close()
    }

    @Test("a launch checks the folder, then runs the program with the Waycar labels, its name and the Host's PATH")
    func launchRunsTheProgramWithTheLoginPath() async throws {
        let channel = Self.channel(
            exec: Self.accepts,
            run: Self.runs(CoreTransportTests.record("t5", argv: ["claude"], cwd: "/work/app")))
        let (transport, _, stream) = try await Self.open(channel)

        let agent = try await transport.startAgent(
            AgentLaunchRequest(
                kind: "claude", name: "claude-1", arguments: ["--model", "opus"],
                workspaceID: nil, cwd: "/work/app"))

        #expect(agent.paneID == "hc:t5")
        #expect(agent.kind == "claude")
        let order = CoreTransportTests.methods(channel).filter { $0 == "machine.exec" || $0 == "terminal.run" }
        #expect(order == ["machine.exec", "terminal.run"])
        #expect(
            channel.params(of: "machine.exec")
                == [
                    .object([
                        "argv": .array([.string("test"), .string("-d"), .string("/work/app")]),
                        "env": .object(["PATH": .string(Self.launchPATH)]), "timeout": .number(20),
                    ])
                ])
        #expect(
            channel.params(of: "terminal.run")
                == [
                    .object([
                        "argv": .array([.string("claude"), .string("--model"), .string("opus")]),
                        "cwd": .string("/work/app"),
                        "env": .object(["PATH": .string(Self.launchPATH)]),
                        "labels": .object([
                            "waycar": .string("1"), "waycar.kind": .string("claude"),
                            "waycar.name": .string("claude-1"),
                        ]),
                    ])
                ])
        await stream.end()
    }

    @Test("the request's environment rides env beside PATH, and PATH is the request's when it sets one")
    func environmentRidesTheRun() async throws {
        let channel = Self.channel(
            exec: Self.accepts,
            run: Self.runs(CoreTransportTests.record("t5", argv: ["hermes"], cwd: "/work/app")))
        let (transport, _, stream) = try await Self.open(channel)
        _ = try await transport.startAgent(
            AgentLaunchRequest(
                kind: "hermes", name: "h", cwd: "/work/app",
                environment: ["HERMES_EPHEMERAL_SYSTEM_PROMPT": "be brief"]))
        let run = try #require(channel.params(of: "terminal.run").first)
        #expect(
            run["env"]
                == .object([
                    "HERMES_EPHEMERAL_SYSTEM_PROMPT": .string("be brief"),
                    "PATH": .string(Self.launchPATH),
                ]))
        await stream.end()
    }

    @Test("a launch into an existing Workspace uses the folder its terminals started in")
    func existingWorkspaceLaunchesInItsFolder() async throws {
        let channel = Self.channel(
            terminals: [
                CoreTransportTests.record("t1", cwd: "/srv/api"),
                CoreTransportTests.record("t2", cwd: "/srv/web"),
            ],
            exec: Self.accepts,
            run: Self.runs(CoreTransportTests.record("t3", argv: ["claude"], cwd: "/srv/web")))
        let (transport, _, stream) = try await Self.open(channel)
        let web = CoreID.workspace(key: "/srv/web")

        _ = try await transport.startAgent(
            AgentLaunchRequest(kind: "claude", name: "c", workspaceID: web))

        #expect(channel.params(of: "terminal.run").first?["cwd"] == .string("/srv/web"))
        let unknown = await CoreTransportTests.apiError {
            try await transport.startAgent(
                AgentLaunchRequest(kind: "claude", name: "c", workspaceID: CoreID.workspace(key: "/gone")))
        }
        #expect(unknown?.code == "workspace_not_found")
        await stream.end()
    }

    @Test("a new folder launches there, and the Workspace label is not used")
    func newWorkspaceIsAFolder() async throws {
        let channel = Self.channel(
            exec: Self.accepts,
            run: Self.runs(CoreTransportTests.record("t3", argv: ["claude"], cwd: "/srv/new")))
        let (transport, _, stream) = try await Self.open(channel)
        _ = try await transport.startAgentInNewWorkspace(
            AgentLaunchRequest(kind: "claude", name: "c"),
            workspace: NewWorkspaceSpec(directory: "/srv/new", label: "Ignored"))
        #expect(channel.params(of: "terminal.run").first?["cwd"] == .string("/srv/new"))
        let params = try #require(channel.params(of: "terminal.run").first)
        #expect(params["name"] == nil)
        #expect(params["template"] == nil)
        #expect(params["wait"] == nil)
        await stream.end()
    }

    @Test("codex gets --no-daemon when its --help lists it, never twice, never when it does not")
    func codexNoDaemon() async throws {
        let withFlag = Self.channel(
            exec: { params in
                params["argv"] == .array([.string("codex"), .string("--help")])
                    ? .result(Self.execReply(code: 0, stdout: "Options:\n  --no-daemon  run in process\n"))
                    : .result(Self.execReply(code: 0))
            },
            run: Self.runs(CoreTransportTests.record("t3", argv: ["codex"], cwd: "/work/app")))
        let first = try await Self.open(withFlag)
        _ = try await first.transport.startAgent(
            AgentLaunchRequest(kind: "codex", name: "c", arguments: ["resume"], cwd: "/work/app"))
        _ = try await first.transport.startAgent(
            AgentLaunchRequest(kind: "codex", name: "c", arguments: ["--no-daemon"], cwd: "/work/app"))
        _ = try await first.transport.startAgent(
            AgentLaunchRequest(
                kind: "codex", name: "c", arguments: ["resume", "thread"], cwd: "/work/app",
                joinsCodexServer: true))
        let argvs = withFlag.params(of: "terminal.run").map { $0["argv"] }
        #expect(
            argvs == [
                .array([.string("codex"), .string("--no-daemon"), .string("resume")]),
                .array([.string("codex"), .string("--no-daemon")]),
                .array([.string("codex"), .string("resume"), .string("thread")]),
            ])
        // `codex --help` was asked once for the two launches.
        #expect(
            withFlag.params(of: "machine.exec")
                .filter { $0["argv"] == .array([.string("codex"), .string("--help")]) }.count == 1)
        await first.stream.end()

        let without = Self.channel(
            exec: Self.accepts,
            run: Self.runs(CoreTransportTests.record("t3", argv: ["codex"], cwd: "/work/app")))
        let second = try await Self.open(without)
        _ = try await second.transport.startAgent(
            AgentLaunchRequest(kind: "codex", name: "c", cwd: "/work/app"))
        #expect(without.params(of: "terminal.run").first?["argv"] == .array([.string("codex")]))
        await second.stream.end()
    }

    @Test func detectedCodexSkipsProbeAndMissingProgramIsNotCached() async throws {
        let channel = Self.channel(exec: { params in
            .result(Self.execReply(code: params["argv"] == .array([.string("codex"), .string("--help")]) ? 127 : 0))
        }, run: Self.runs(CoreTransportTests.record("t3", argv: ["codex"], cwd: "/work/app")))
        let (transport, session, stream) = try await Self.open(channel)
        await session.setCodexPresence(.init(version: "0.167.0", path: "/home/u/.nvm/bin/codex"))
        _ = try await transport.startAgent(.init(kind: "codex", name: "c", cwd: "/work/app"))
        _ = try await transport.startAgent(.init(kind: "codex", name: "c", cwd: "/work/app", joinsCodexServer: true))
        #expect(channel.params(of: "terminal.run").map { $0["argv"] } == [
            .array([.string("codex"), .string("--no-daemon")]), .array([.string("codex")])])
        let probeArgv: JSONValue = .array([.string("codex"), .string("--help")])
        #expect(channel.params(of: "machine.exec").filter { $0["argv"] == probeArgv }.count == 0)
        await session.setCodexPresence(nil)
        #expect(await transport.codexSupportsNoDaemon() == false)
        #expect(await transport.codexSupportsNoDaemon() == false)
        #expect(channel.params(of: "machine.exec").filter { $0["argv"] == probeArgv }.count == 2)
        await stream.end()
        try await transport.close()
    }

    // MARK: Folder

    @Test("a relative folder is refused and ~ expands from the Host's home")
    func folderRules() async throws {
        let channel = Self.channel(
            exec: Self.accepts,
            run: Self.runs(CoreTransportTests.record("t3", argv: ["claude"], cwd: "/home/me/proj")))
        let (transport, _, stream) = try await Self.open(channel)

        let relative = await CoreTransportTests.apiError {
            try await transport.startAgent(
                AgentLaunchRequest(kind: "claude", name: "c", cwd: "proj/app"))
        }
        #expect(relative?.code == "invalid_argument")
        #expect(channel.requests.filter { $0.method == "terminal.run" }.isEmpty)

        _ = try await transport.startAgent(
            AgentLaunchRequest(kind: "claude", name: "c", cwd: "~/proj"))
        #expect(channel.params(of: "terminal.run").first?["cwd"] == .string("\(FakeHostSSHServices.homeDirectory)/proj"))
        await stream.end()
    }

    @Test("a folder that is not there is refused before core is asked to run anything")
    func missingFolder() async throws {
        let channel = Self.channel(
            exec: { _ in .result(Self.execReply(code: 1)) },
            run: Self.runs(CoreTransportTests.record("t3", argv: ["claude"])))
        let (transport, _, stream) = try await Self.open(channel)
        let error = await CoreTransportTests.apiError {
            try await transport.startAgent(
                AgentLaunchRequest(kind: "claude", name: "c", cwd: "/nope"))
        }
        #expect(error?.code == "folder_not_found")
        #expect(error?.message == "/nope is not a folder on this Host.")
        #expect(channel.params(of: "terminal.run").isEmpty)
        await stream.end()
    }

    // MARK: Missing program

    @Test("a program core cannot find says it is not installed, and a PATH that did not change is not retried")
    func missingProgram() async throws {
        let channel = Self.channel(
            exec: Self.accepts,
            run: { _ in
                .error(
                    kind: "spawn_failed",
                    message: "cannot start \"claude\": No such file or directory (os error 2)",
                    hint: "check the program name and cwd")
            })
        let (transport, _, stream) = try await Self.open(channel)
        let error = await CoreTransportTests.apiError {
            try await transport.startAgent(
                AgentLaunchRequest(kind: "claude", name: "c", cwd: "/work/app"))
        }
        #expect(error?.code == "agent_start_failed")
        #expect(error?.message == "claude is not installed on this Host, or is not on its PATH")
        #expect(channel.params(of: "terminal.run").count == 1)
        await stream.end()
    }

    @Test("a login PATH that gained ~/.local/bin since it was cached is picked up and the launch retried once")
    func staleLoginPathIsRefreshed() async throws {
        let attempts = Mutex(0)
        let channel = Self.channel(
            exec: Self.accepts,
            run: { params in
                let attempt = attempts.withLock { value -> Int in
                    value += 1
                    return value
                }
                if attempt == 1 {
                    return .error(kind: "spawn_failed", message: "cannot start", hint: "")
                }
                return .result(CoreTransportTests.record("t3", argv: ["claude"], cwd: "/work/app"))
            })
        let (transport, _, stream) = try await Self.open(
            channel, launchPaths: ["/usr/bin:/bin", "/home/u/.local/bin:/usr/bin:/bin"])

        let agent = try await transport.startAgent(
            AgentLaunchRequest(kind: "claude", name: "c", cwd: "/work/app"))

        #expect(agent.paneID == "hc:t3")
        let paths = channel.params(of: "terminal.run").map { $0["env"]?["PATH"] }
        #expect(
            paths == [.string("/usr/bin:/bin"), .string("/home/u/.local/bin:/usr/bin:/bin")])
        await stream.end()
    }

    // MARK: First prompt

    @Test("an agent that reports idle takes its first prompt; one still silent does not")
    func firstPromptWaitsForTheReport() async throws {
        let channel = Self.channel(
            terminals: [CoreTransportTests.record("t5", argv: ["claude"], cwd: "/work/app")],
            exec: Self.accepts,
            run: Self.runs(CoreTransportTests.record("t5", argv: ["claude"], cwd: "/work/app")))
        let (transport, _, stream) = try await Self.open(channel, unreportedWait: .seconds(30))
        let reader = EventReader(stream.events)
        _ = try await transport.startAgent(
            AgentLaunchRequest(kind: "claude", name: "c", cwd: "/work/app"))

        let early = await CoreTransportTests.apiError {
            try await transport.promptAgent(AgentPromptParams(target: "hc:t5", text: "hi"))
        }
        #expect(early?.code == "agent_not_ready")
        #expect(channel.params(of: "terminal.send").isEmpty)

        channel.pushEvent(seq: 11, type: "status", terminal: "t5", data: CoreTransportTests.statusData("idle"))
        _ = try await reader.next()
        _ = try await transport.promptAgent(AgentPromptParams(target: "hc:t5", text: "hi"))
        #expect(
            channel.params(of: "terminal.send")
                == [.object(["terminal": .string("t5"), "text": .string("hi")])])
        await stream.end()
    }

    @Test("an agent that never reports is read after the wait and prompted only when its input is on screen")
    func silentAgentIsReadFirst() async throws {
        let screen = Mutex("")
        let channel = Self.channel(
            terminals: [CoreTransportTests.record("t6", argv: ["opencode"], cwd: "/work/app")],
            exec: Self.accepts,
            run: Self.runs(CoreTransportTests.record("t6", argv: ["opencode"], cwd: "/work/app")),
            read: { _ in
                .result(
                    CoreTransportTests.json(
                        ["text": screen.withLock { $0 }, "complete": true] as [String: Any]))
            })
        let (transport, _, stream) = try await Self.open(channel, unreportedWait: .milliseconds(100))
        _ = try await transport.startAgent(
            AgentLaunchRequest(kind: "opencode", name: "o", cwd: "/work/app"))

        // Inside the wait: held, and the screen is not even read.
        let inside = await CoreTransportTests.apiError {
            try await transport.promptAgent(AgentPromptParams(target: "hc:t6", text: "hi"))
        }
        #expect(inside?.code == "agent_not_ready")
        let readsInside = channel.params(of: "terminal.read").count

        try await Task.sleep(for: .milliseconds(150))
        // After the wait the screen is read; no input box yet: still held.
        let blank = await CoreTransportTests.apiError {
            try await transport.promptAgent(AgentPromptParams(target: "hc:t6", text: "hi"))
        }
        #expect(blank?.code == "agent_not_ready")
        #expect(channel.params(of: "terminal.read").count > readsInside)
        #expect(channel.params(of: "terminal.send").isEmpty)

        screen.withLock { $0 = "opencode\n┃ Ask anything…\n" }
        _ = try await transport.promptAgent(AgentPromptParams(target: "hc:t6", text: "hi"))
        #expect(channel.params(of: "terminal.send").count == 1)
        await stream.end()
    }

    @Test("a failed send is never sent again by the transport")
    func neverResends() async throws {
        let channel = Self.channel(
            terminals: [CoreTransportTests.record("t5", argv: ["claude"], status: "idle")],
            exec: Self.accepts,
            run: Self.runs(CoreTransportTests.record("t5", argv: ["claude"], cwd: "/work/app")),
            send: { _ in .error(kind: "internal", message: "boom", hint: "") })
        let (transport, _, stream) = try await Self.open(channel)
        _ = try await transport.startAgent(
            AgentLaunchRequest(kind: "claude", name: "c", cwd: "/work/app"))
        let error = await CoreTransportTests.apiError {
            try await transport.promptAgent(AgentPromptParams(target: "hc:t5", text: "hi"))
        }
        #expect(error?.code == "core_error")
        #expect(channel.params(of: "terminal.send").count == 1)
        await stream.end()
    }

    @Test("a transport nobody subscribed events on still sees the agent's report")
    func unsubscribedTransportReadsTheRecord() async throws {
        let reported = CoreTransportTests.record("t5", argv: ["claude"], status: "idle")
        let channel = Self.channel(
            exec: Self.accepts,
            run: Self.runs(CoreTransportTests.record("t5", argv: ["claude"], cwd: "/work/app")),
            get: { _ in .result(reported) })
        let session = FakeHostSSHServices(exec: Self.exec())
        await session.serveCore(channel)
        var configuration = CoreTransportTests.configuration()
        configuration.unreportedWait = .seconds(30)
        let transport = try await CoreTransport.open(
            session: session, configuration: configuration, memory: nil,
            corePath: CoreTransportTests.detectedCorePath)
        _ = try await transport.startAgent(
            AgentLaunchRequest(kind: "claude", name: "c", cwd: "/work/app"))

        _ = try await transport.promptAgent(AgentPromptParams(target: "hc:t5", text: "hi"))

        // One read for the gate, one for the Agent the prompt returns.
        #expect(
            channel.params(of: "terminal.get")
                == Array(repeating: CoreTransportTests.terminalObject("t5"), count: 2))
        #expect(channel.params(of: "terminal.send").count == 1)
        try await transport.close()
    }

    @Test("a gate let through stays open: later prompts read nothing, even on a blank screen")
    func openedGateStaysOpen() async throws {
        let screen = Mutex("opencode\n┃ Ask anything…\n")
        let channel = Self.channel(
            terminals: [CoreTransportTests.record("t6", argv: ["opencode"], cwd: "/work/app")],
            exec: Self.accepts,
            run: Self.runs(CoreTransportTests.record("t6", argv: ["opencode"], cwd: "/work/app")),
            read: { _ in
                .result(
                    CoreTransportTests.json(
                        ["text": screen.withLock { $0 }, "complete": true] as [String: Any]))
            })
        // No unreported wait: this pins that an opened gate stays open, not
        // how long the gate waits.
        let (transport, _, stream) = try await Self.open(channel, unreportedWait: .zero)
        _ = try await transport.startAgent(
            AgentLaunchRequest(kind: "opencode", name: "o", cwd: "/work/app"))
        _ = try await transport.promptAgent(AgentPromptParams(target: "hc:t6", text: "one"))
        let reads = channel.params(of: "terminal.read").count
        screen.withLock { $0 = "" }
        _ = try await transport.promptAgent(AgentPromptParams(target: "hc:t6", text: "two"))
        #expect(channel.params(of: "terminal.read").count == reads)
        #expect(channel.params(of: "terminal.send").count == 2)
        await stream.end()
    }

    @Test("a tagged retry holds the earlier terminal's first prompt again until it reports")
    func taggedRetryArmsTheGate() async throws {
        let id = UUID()
        let record = CoreTransportTests.record(
            "t5", labels: ["waycar.kind": "claude", "waycar.launch": id.uuidString],
            argv: ["claude"], cwd: "/work/app")
        let channel = Self.channel(terminals: [record], exec: Self.accepts, run: Self.runs(record))
        let (transport, _, stream) = try await Self.open(channel, unreportedWait: .seconds(30))
        let reader = EventReader(stream.events)
        _ = try await transport.startAgent(AgentLaunchRequest(
            kind: "claude", name: "c", cwd: "/work/app", launchID: id, mayHaveStarted: true))
        #expect(channel.params(of: "terminal.run").isEmpty)
        let held = await CoreTransportTests.apiError {
            try await transport.promptAgent(AgentPromptParams(target: "hc:t5", text: "hi"))
        }
        #expect(held?.code == "agent_not_ready")
        channel.pushEvent(seq: 11, type: "status", terminal: "t5", data: CoreTransportTests.statusData("idle"))
        _ = try await reader.next()
        _ = try await transport.promptAgent(AgentPromptParams(target: "hc:t5", text: "hi"))
        #expect(channel.params(of: "terminal.send").count == 1)
        await stream.end()
    }

    @Test("a terminal Waycar did not launch is never held, even before it reports")
    func unlaunchedTerminalIsNeverHeld() async throws {
        let channel = Self.channel(
            terminals: [CoreTransportTests.record("t7", argv: ["claude"], cwd: "/work/app")],
            exec: Self.accepts, run: { _ in .none })
        let (transport, _, stream) = try await Self.open(channel, unreportedWait: .seconds(30))
        _ = try await transport.promptAgent(AgentPromptParams(target: "hc:t7", text: "hi"))
        #expect(channel.params(of: "terminal.send").count == 1)
        #expect(channel.params(of: "terminal.read").isEmpty)
        await stream.end()
    }

    // MARK: Pure rules

    @Test("an agent that has reported is ready, one that has not waits, a finished one is let to fail")
    func readinessRules() {
        let silent = CoreTerminal(address: "t1", argv: ["claude"])
        let reported = CoreTerminal(
            address: "t1", status: CoreStatus(state: "idle"), reported: true)
        let finished = CoreTerminal(address: "t1", state: "finished")
        let wait = Duration.seconds(5)
        #expect(CoreLaunch.readiness(of: reported, elapsed: .zero, unreportedWait: wait) == .ready)
        #expect(CoreLaunch.readiness(of: finished, elapsed: .zero, unreportedWait: wait) == .ready)
        #expect(CoreLaunch.readiness(of: silent, elapsed: .seconds(4), unreportedWait: wait) == .waiting)
        #expect(CoreLaunch.readiness(of: silent, elapsed: .seconds(5), unreportedWait: wait) == .readScreen)
        #expect(CoreLaunch.readiness(of: nil, elapsed: .seconds(1), unreportedWait: wait) == .waiting)
        #expect(CoreLaunch.readiness(of: nil, elapsed: .seconds(6), unreportedWait: wait) == .readScreen)
    }

    @Test("a kind with no marker needs something drawn; a marker kind needs its input box")
    func screenRules() {
        let wait = Duration.seconds(5)
        #expect(
            CoreLaunch.screenDecision(kind: "pi", screen: " \n", elapsed: .seconds(6), unreportedWait: wait)
                == .waiting)
        #expect(
            CoreLaunch.screenDecision(kind: "pi", screen: "pi 1.0\n> ", elapsed: .seconds(6), unreportedWait: wait)
                == .ready)
        #expect(
            CoreLaunch.screenDecision(kind: "opencode", screen: "loading", elapsed: .seconds(60), unreportedWait: wait)
                == .waiting)
        #expect(
            CoreLaunch.screenDecision(kind: "opencode", screen: "┃ ask", elapsed: .seconds(6), unreportedWait: wait)
                == .ready)
    }

    @Test("folders: absolute stays, ~ and ~/x expand, everything else is refused")
    func absoluteFolders() async throws {
        let home: @Sendable () async throws -> String = { "/home/me" }
        #expect(try await CoreLaunch.absoluteFolder("/srv/app", home: home) == "/srv/app")
        #expect(try await CoreLaunch.absoluteFolder(" /srv/app \n", home: home) == "/srv/app")
        #expect(try await CoreLaunch.absoluteFolder("~", home: home) == "/home/me")
        #expect(try await CoreLaunch.absoluteFolder("~/code/app", home: home) == "/home/me/code/app")
        #expect(try await CoreLaunch.absoluteFolder("~/x", home: { "/home/me/" }) == "/home/me/x")
        #expect(try await CoreLaunch.absoluteFolder("app", home: home) == nil)
        #expect(try await CoreLaunch.absoluteFolder("~root/x", home: home) == nil)
        #expect(try await CoreLaunch.absoluteFolder("", home: home) == nil)
        #expect(try await CoreLaunch.absoluteFolder("/a\u{7}b", home: home) == nil)
    }

    @Test("the launch PATH exec passes the login PATH as one quoted argument and parses between markers")
    func launchPathCommand() {
        let command = CoreLaunch.launchPathCommand(loginPATH: "/a b/bin:/it's/bin")
        #expect(command.hasSuffix(" launch '/a b/bin:/it'\\''s/bin'"))
        #expect(command.contains("$HOME/.local/bin"))
        #expect(
            CoreLaunch.parseLaunchPath("noise\n\(Self.pathMarker)/a:/b\(Self.pathMarker)tail") == "/a:/b")
        #expect(CoreLaunch.parseLaunchPath("no markers") == nil)
        #expect(CoreLaunch.parseLaunchPath("\(Self.pathMarker)/a\n/b\(Self.pathMarker)") == nil)
    }
}

/// The builder tmux and herdr-core share (`AgentLaunchBuilder`).
@Suite("Agent launch builder")
struct AgentLaunchBuilderTests {
    private func request(
        _ kind: String, arguments: [String] = [], environment: [String: String] = [:]
    ) -> AgentLaunchRequest {
        AgentLaunchRequest(kind: kind, name: "n", arguments: arguments, environment: environment)
    }

    @Test("the argv is the kind's executable and the request's arguments")
    func argv() async throws {
        let words = try await AgentLaunchBuilder.argv(
            for: request("claude", arguments: ["--model", "opus 4"]), codexSupportsNoDaemon: { false })
        #expect(words == ["claude", "--model", "opus 4"])
    }

    @Test(arguments: [true, false], [true, false])
    func herdrCodexLaunchArguments(knowsFlag: Bool, joinsServer: Bool) async throws {
        let params = try await WaycarSSHTransport.agentStartParams(
            .init(kind: "codex", name: "c", arguments: ["resume", "thread"], joinsCodexServer: joinsServer),
            paneID: "pane", codexSupportsNoDaemon: { knowsFlag })
        #expect(params.args == (knowsFlag && !joinsServer
            ? ["--no-daemon", "resume", "thread"] : ["resume", "thread"]))
    }

    @Test(arguments: ["0.162.1", nil] as [String?])
    func olderOrUnknownCodexUsesTheCapabilityProbe(version: String?) async throws {
        let probed = Mutex(false)
        let presence = version.map { CodexPresence(version: $0, path: "/bin/codex") }
        let knowsFlag = await AgentLaunchBuilder.codexSupportsNoDaemon(presence: presence) {
            probed.withLock { $0 = true }
            return true
        }
        let words = try await AgentLaunchBuilder.argv(for: request("codex"),
            codexSupportsNoDaemon: { knowsFlag })
        #expect(probed.withLock { $0 })
        #expect(words == ["codex", "--no-daemon"])
    }

    @Test func missingCodexIsNotAnUnsupportedCapability() throws {
        #expect(throws: TransportError.self) {
            _ = try AgentLaunchBuilder.codexNoDaemonProbe(stdout: "", stderr: "codex: not found", exitCode: 127)
        }
        #expect(try AgentLaunchBuilder.codexNoDaemonProbe(stdout: "Options: --help", stderr: "", exitCode: 0) == false)
        #expect(try AgentLaunchBuilder.codexNoDaemonProbe(stdout: "Options: --no-daemon", stderr: "", exitCode: 0))
    }

    @Test("codex gets --no-daemon only when it knows it, and only once")
    func codex() async throws {
        let plain = try await AgentLaunchBuilder.argv(
            for: request("codex"), codexSupportsNoDaemon: { true })
        #expect(plain == ["codex", "--no-daemon"])
        let twice = try await AgentLaunchBuilder.argv(
            for: request("codex", arguments: ["--no-daemon", "x"]), codexSupportsNoDaemon: { true })
        #expect(twice == ["codex", "--no-daemon", "x"])
        let unknown = try await AgentLaunchBuilder.argv(
            for: request("codex"), codexSupportsNoDaemon: { false })
        #expect(unknown == ["codex"])
        // Only codex is asked.
        let asked = Mutex(false)
        _ = try await AgentLaunchBuilder.argv(
            for: request("claude"), codexSupportsNoDaemon: { asked.withLock { $0 = true }; return true })
        #expect(!asked.withLock { $0 })
    }

    @Test("tmux's shell line: env prefix in name order, bare words bare, the rest quoted")
    func shellLine() async throws {
        let line = try await AgentLaunchBuilder.shellLine(
            for: request(
                "codex", arguments: ["--", "fix it's bug"], environment: ["B": "2 3", "A": "1"]),
            codexSupportsNoDaemon: { true })
        #expect(line == "env A=1 'B=2 3' codex --no-daemon -- 'fix it'\\''s bug'")
    }

    @Test("a kind that is not one plain word, and an environment name env cannot set, are refused")
    func refusals() async {
        let kind = await thrown { try await AgentLaunchBuilder.argv(for: request("a b"), codexSupportsNoDaemon: { false }) }
        #expect((kind as? HerdrAPIError)?.code == "invalid_agent_kind")
        let name = await thrown {
            try await AgentLaunchBuilder.shellLine(
                for: request("claude", environment: ["1X": "v"]), codexSupportsNoDaemon: { false })
        }
        #expect((name as? HerdrAPIError)?.code == "invalid_env")
        #expect(AgentLaunchBuilder.isEnvironmentName("COPILOT_CUSTOM_INSTRUCTIONS_DIRS"))
        #expect(!AgentLaunchBuilder.isEnvironmentName("A-B"))
        #expect(!AgentLaunchBuilder.isEnvironmentName(""))
    }

    private func thrown(_ operation: () async throws -> some Any) async -> (any Error)? {
        do {
            _ = try await operation()
            return nil
        } catch {
            return error
        }
    }
}
