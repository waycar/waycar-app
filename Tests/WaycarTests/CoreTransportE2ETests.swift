import CryptoKit
import Foundation
import Synchronization
import Testing
import WaycarSSH

@testable import Waycar

/// herdr-core's Transport (ADR 0031) against a real sshd and a real
/// `herdr-core`: nothing is scripted. The Host is the core lab
/// (`scripts/core-lab`, a throwaway Ubuntu container) or a Mac with a
/// throwaway user-mode sshd whose sessions run under a scratch `HOME`
/// (macOS: no `/run/user`, a state-dir socket). The suite skips without
/// `WAYCAR_CORE_E2E_CONFIG`; a simulator run gets it from
/// `TEST_RUNNER_WAYCAR_CORE_E2E_CONFIG`. CI's iOS lane is such a Mac: it
/// builds that Host and runs this suite as a pinned lane
/// (`scripts/run-ci-ios-tests.sh`, 15 tests, no skips).
///
/// Every test starts its own terminals through `herdr-core run --bg`, labelled
/// with the run's id, and kills and removes them afterwards: the Host's other
/// terminals are never touched.
@Suite(
    "herdr-core Transport e2e",
    .enabled(if: CoreE2EEnvironment.current != nil, "requires a Host with herdr-core installed"),
    .serialized)
struct CoreTransportE2ETests {
    @Test("detection finds herdr-core and its version")
    func detectionFindsCore() async throws {
        try await withHost { host in
            let presence = try await SSHTransportConnector().detectBackends(
                settings: host.environment.settings())
            let core = try #require(presence.core)
            #expect(core.meetsFloor, "version \(core.version)")
            #expect(core.path.hasSuffix("/herdr-core") || core.path.hasSuffix("/hc"))
        }
    }

    @Test("a stopped core stays stopped until the explicit SSH start and then connects")
    func stoppedCoreRequiresExplicitStart() async throws {
        try await withHost { host in
            // This Host is disposable, but refuse to kill anyone's terminals
            // if a manually configured lab has programs outside this suite.
            let listing = try await host.hc("ls --json")
            let data = try #require(listing.data(using: .utf8))
            let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let terminals = try #require(object["terminals"] as? [[String: Any]])
            try #require(terminals.isEmpty, "stopped-core test requires an empty disposable core")
            _ = try await host.hc("server stop")
            #expect(try await host.coreIsRunning() == false)
            do {
                let unexpected = try await SSHTransportConnector().connect(
                    settings: host.environment.settings(), backend: .core)
                try? await unexpected.close()
                Issue.record("a stopped core connected")
            } catch {
                #expect(error as? TransportError == .coreNotRunning)
            }
            #expect(try await host.coreIsRunning() == false, "connect started a core")
            try await SSHTransportConnector().startCore(settings: host.environment.settings())
            #expect(try await host.coreIsRunning())
            try await withTransport(host.environment) { transport in
                let info = try await transport.ping()
                #expect(info.backend == .core)
            }
        }
    }

    @Test("rows carry idle, working, blocked, done and error, and a shell row")
    func rowsCarryEveryStatus() async throws {
        try await withHost { host in
            let names = try await host.startAgents()
            let shell = try await host.start(name: host.unique("shell"), command: nil)
            try await withTransport(host.environment) { transport in
                let snapshot = try await transport.sessionSnapshot()
                let byName = Dictionary(
                    snapshot.agents.compactMap { info in info.name.map { ($0, info) } },
                    uniquingKeysWith: { first, _ in first })
                for (state, status) in Self.expectedStatuses {
                    let info = try #require(byName[names[state] ?? ""], "no row for \(state)")
                    #expect(info.agentStatus == status, "\(state) shows \(info.agentStatus)")
                    #expect(info.paneID.hasPrefix("hc:"))
                    #expect(info.stateChangeSeq != nil)
                }
                let pane = try #require(
                    snapshot.panes.first { $0.paneID == CoreID.pane(shell.address) },
                    "no row for the shell")
                #expect(pane.agent == nil)
                #expect(pane.agentStatus == .unknown)
            }
        }
    }

    @Test("the Herdr app's labels build one Workspace with two Tabs")
    func labelsBuildWorkspacesAndTabs() async throws {
        try await withHost { host in
            let space = host.unique("space")
            _ = try await host.start(
                name: host.unique("one"), command: host.agentCommand(name: "one"),
                labels: ["herdr.space": space, "herdr.tab": "alpha"])
            _ = try await host.start(
                name: host.unique("two"), command: host.agentCommand(name: "two"),
                labels: ["herdr.space": space, "herdr.tab": "beta"])
            try await withTransport(host.environment) { transport in
                let snapshot = try await transport.sessionSnapshot()
                let workspace = try #require(
                    snapshot.workspaces.first { $0.tabCount == 2 && $0.paneCount == 2 },
                    "no Workspace with two Tabs")
                let tabs = snapshot.tabs.filter { $0.workspaceID == workspace.workspaceID }
                #expect(tabs.count == 2)
            }
        }
    }

    @Test("a status change reaches the event stream within two seconds")
    func statusChangeIsFast() async throws {
        try await withHost { host in
            let agent = try await host.start(
                name: host.unique("fast"), command: host.agentCommand(name: "fast"))
            try await withTransport(host.environment) { transport in
                try await withEvents(transport) { feed in
                    _ = try await host.hc("send \(agent.address) work")
                    let sent = ContinuousClock.now
                    let reached = try await eventually(within: .seconds(2)) {
                        feed.events.contains { event in
                            event.kind == PaneEventKind.agentStatusChanged.kind
                                && event.data["pane_id"]?.stringValue == CoreID.pane(agent.address)
                                && event.data["agent_status"]?.stringValue == "working"
                        }
                    }
                    let elapsed = sent.duration(to: .now)
                    #expect(reached, "no working status within 2 s (\(elapsed))")
                    let snapshot = try await transport.sessionSnapshot()
                    let row = try #require(
                        snapshot.agents.first { $0.paneID == CoreID.pane(agent.address) })
                    #expect(row.agentStatus == .working)
                }
            }
        }
    }

    @Test("a prompt arrives, a blocked agent refuses it, and down enter answers it")
    func promptAndKeysArrive() async throws {
        try await withHost { host in
            let agent = try await host.start(
                name: host.unique("talk"), command: host.agentCommand(name: "talk"))
            let reader = try await host.start(
                name: host.unique("keys"), command: host.readerCommand)
            try await withTransport(host.environment) { transport in
                try await withEvents(transport) { _ in
                    let paneID = CoreID.pane(agent.address)
                    _ = try await transport.promptAgent(
                        AgentPromptParams(target: paneID, text: "hello there"))
                    let arrived = try await eventually {
                        try await transport.readPane(
                            PaneReadParams(paneID: paneID, source: .visible)
                        ).text.contains("GOT:hello there")
                    }
                    #expect(arrived, "the prompt never reached the agent")

                    // A blocked agent is refused with agent_blocked, nothing typed.
                    _ = try await host.hc("send \(agent.address) ask")
                    let blocked = try await eventually {
                        try await transport.sessionSnapshot().agents
                            .first { $0.paneID == paneID }?.agentStatus == .blocked
                    }
                    #expect(blocked)
                    await #expect(throws: HerdrAPIError.self) {
                        _ = try await transport.promptAgent(
                            AgentPromptParams(target: paneID, text: "nope"))
                    }

                    // Keys are never refused: down, enter reach a raw reader.
                    let readerID = CoreID.pane(reader.address)
                    try await transport.sendAgentKeys(
                        AgentSendKeysParams(keys: ["down", "enter"], target: readerID))
                    let typed = try await eventually {
                        let text = try await transport.readPane(
                            PaneReadParams(paneID: readerID, source: .visible)
                        ).text
                        // ESC [ B then CR, as hex lines.
                        return text.contains("B:1b") && text.contains("B:5b")
                            && text.contains("B:42") && text.contains("B:0d")
                    }
                    #expect(typed, "down enter never reached the reader")
                }
            }
        }
    }

    @Test("Attach shows the screen, types, resizes and ends cleanly when the program exits")
    func attachLifecycle() async throws {
        try await withHost { host in
            let reader = try await host.start(
                name: host.unique("attach"), command: host.readerCommand)
            try await withTransport(host.environment) { transport in
                let request = TerminalAttachRequest(
                    target: .agentPane(CoreID.pane(reader.address)), cols: 80, rows: 24)
                let session = try await transport.attachTerminal(request)
                let output = CoreAttachFeed(session)
                let outcome: Result<Void, any Error>
                do {
                    #expect(try await output.waitFor("READY"), "the attach drew no screen")
                    session.send(Data("q".utf8))
                    #expect(try await output.waitFor("B:71"), "a typed byte never echoed")
                    session.resize(cols: 100, rows: 30)
                    let resized = try await eventually {
                        let record = try await host.record(reader.address)
                        return record.cols == 100 && record.rows == 30
                    }
                    #expect(resized, "the terminal never took the phone's size")
                    session.send(Data("w".utf8))
                    #expect(try await output.waitFor("B:77"))
                    #expect(await output.ending == nil, "the attach ended on its own")
                    outcome = .success(())
                } catch {
                    outcome = .failure(error)
                }
                await session.end()
                await output.finished()
                try outcome.get()
                // The viewer left: the terminal snaps back to its headless size.
                let snapped = try await eventually {
                    let record = try await host.record(reader.address)
                    return record.cols == 200 && record.rows == 120
                }
                #expect(snapped, "the size did not return after the attach closed")
            }

            let short = try await host.start(
                name: host.unique("short"),
                command: "sh -c 'sleep 2; echo bye; exit 0'")
            try await withTransport(host.environment) { transport in
                let session = try await transport.attachTerminal(
                    TerminalAttachRequest(
                        target: .agentPane(CoreID.pane(short.address)), cols: 80, rows: 24))
                let output = CoreAttachFeed(session)
                let ended = try await eventually {
                    await output.ending != nil
                }
                #expect(ended, "the attach did not end when the program exited")
                #expect(await output.ending == "finished")
                await session.end()
                await output.finished()
            }
        }
    }

    @Test("Close kills the terminal")
    func closeKills() async throws {
        try await withHost { host in
            let victim = try await host.start(
                name: host.unique("close"), command: "sh -c 'sleep 600'")
            try await withTransport(host.environment) { transport in
                try await transport.closePane(
                    PaneTarget(paneID: CoreID.pane(victim.address)), closesWorktreeGroup: false)
                let gone = try await eventually {
                    try await host.record(victim.address).state == "finished"
                }
                #expect(gone, "the terminal is still running")
                let record = try await host.record(victim.address)
                #expect(record.reason == "killed")
            }
        }
    }

    @Test("a core restart ends the stream and a new connection finds the rows intact")
    func serverRestartReconnects() async throws {
        try await withHost { host in
            let agent = try await host.start(
                name: host.unique("keep"), command: host.agentCommand(name: "keep"))
            let transport = try await SSHTransportConnector().connect(
                settings: host.environment.settings(), backend: .core)
            let stream = try await transport.subscribeToEvents([])
            let failedFlag = Mutex(false)
            let drain = Task {
                do {
                    for try await _ in stream.events {}
                } catch {
                    failedFlag.withLock { $0 = true }
                }
            }
            _ = try await host.hc("server restart")
            let streamFailed = try await eventually {
                failedFlag.withLock { $0 }
            }
            #expect(streamFailed, "the event stream did not end with the restart")
            drain.cancel()
            try? await transport.close()

            // Reconnect no longer starts a service. Explicitly start the
            // replacement core; its terminal holders survived the restart.
            try await SSHTransportConnector().startCore(settings: host.environment.settings())
            try await withTransport(host.environment) { fresh in
                let snapshot = try await fresh.sessionSnapshot()
                #expect(snapshot.agents.contains { $0.paneID == CoreID.pane(agent.address) })
            }
            #expect(try await host.record(agent.address).state == "live")
        }
    }

    @Test("a core that errors before hello shows its message and hint")
    func erroringCoreShowsMessageAndHint() async throws {
        try await withHost { host in
            let restore = try await host.wrapCoreFailingConnect(
                message: "the socket path is too long", hint: "use a shorter session name")
            let outcome: Result<Void, any Error>
            do {
                _ = try await SSHTransportConnector().connect(
                    settings: host.environment.settings(), backend: .core)
                outcome = .success(())
            } catch {
                outcome = .failure(error)
            }
            try await restore()
            guard case .failure(let error) = outcome else {
                Issue.record("a core that exits before hello connected")
                return
            }
            #expect(
                error as? TransportError
                    == .coreRefused(
                        message: "the socket path is too long", hint: "use a shorter session name"))
        }
    }

    @Test("login chatter above the shell's guard does not stop the connection")
    func noisyLoginStillConnects() async throws {
        try await withHost { host in
            let file = try await host.noisyStartupFile()
            let restore = try await host.addNoise(to: file)
            let outcome: Result<Void, any Error>
            do {
                try await withTransport(host.environment) { transport in
                    let info = try await transport.ping()
                    #expect(info.backend == .core)
                    #expect(!info.version.isEmpty)
                }
                outcome = .success(())
            } catch {
                outcome = .failure(error)
            }
            try await restore()
            try outcome.get()
        }
    }

    // MARK: Starting an agent (design §9)

    @Test("a kind installed in ~/.local/bin launches though the SSH PATH lacks it, with and without a first prompt")
    func launchesAKindTheSSHPathLacks() async throws {
        try await withHost { host in
            let kind = host.unique("agent")
            let remove = try await host.installFakeAgent(kind)
            let outcome: Result<Void, any Error>
            do {
                // The premise: the exec channel cannot find it.
                await #expect(throws: (any Error).self) {
                    _ = try await host.shell("command -v \(kind)")
                }
                let folder = await host.scratchDirectory()
                try await withTransport(host.environment) { transport in
                    // No first prompt: the terminal runs and reports idle.
                    let plain = try await transport.startAgent(
                        AgentLaunchRequest(kind: kind, name: "plain", cwd: folder))
                    let idle = try await eventually {
                        try await transport.sessionSnapshot().agents
                            .first { $0.paneID == plain.paneID }?.agentStatus == .idle
                    }
                    #expect(idle, "the launched agent never reported idle")

                    // A first prompt, retried the way the Composer does until
                    // the gate lets it through; it arrives once.
                    let prompted = try await transport.startAgent(
                        AgentLaunchRequest(kind: kind, name: "prompted", cwd: folder))
                    let delivered = try await eventually {
                        do {
                            _ = try await transport.promptAgent(
                                AgentPromptParams(target: prompted.paneID, text: "first prompt"))
                            return true
                        } catch let error as HerdrAPIError where error.code == "agent_not_ready" {
                            return false
                        }
                    }
                    #expect(delivered, "the first prompt never went out")
                    let arrived = try await eventually {
                        try await transport.readPane(
                            PaneReadParams(paneID: prompted.paneID, source: .visible)
                        ).text.contains("GOT:first prompt")
                    }
                    #expect(arrived, "the first prompt never reached the agent")
                    let screen = try await transport.readPane(
                        PaneReadParams(paneID: prompted.paneID, source: .visible)).text
                    #expect(screen.components(separatedBy: "GOT:first prompt").count == 2)
                }
                outcome = .success(())
            } catch {
                outcome = .failure(error)
            }
            try await remove()
            try outcome.get()
        }
    }

    @Test("a terminal Waycar starts sees the Host's login PATH, not the SSH one")
    func launchedTerminalSeesTheLoginPath() async throws {
        try await withHost { host in
            let kind = host.unique("env")
            let remove = try await host.installProgram(
                kind, body: "printf 'SEEN-PATH=%s\\n' \"$PATH\"; exec sleep 60")
            let outcome: Result<Void, any Error>
            do {
                let folder = await host.scratchDirectory()
                try await withTransport(host.environment) { transport in
                    let started = try await transport.startAgent(
                        AgentLaunchRequest(kind: kind, name: "env", cwd: folder))
                    let text = try await eventuallyValue { () -> String? in
                        let screen = try await transport.readPane(
                            PaneReadParams(paneID: started.paneID, source: .visible)
                        ).text
                        return screen.contains("SEEN-PATH=") ? screen : nil
                    }
                    let screen = try #require(text, "the program printed no PATH")
                    #expect(screen.contains("/.local/bin"), "PATH has no ~/.local/bin: \(screen)")
                    #expect(screen.contains("/usr/bin"), "PATH has no /usr/bin: \(screen)")
                }
                outcome = .success(())
            } catch {
                outcome = .failure(error)
            }
            try await remove()
            try outcome.get()
        }
    }

    @Test("a kind that is not installed says so, and starts nothing")
    func missingKindSaysSo() async throws {
        try await withHost { host in
            let kind = host.unique("missing")
            let folder = await host.scratchDirectory()
            try await withTransport(host.environment) { transport in
                let before = try await transport.sessionSnapshot().panes.count
                let error = await #expect(throws: HerdrAPIError.self) {
                    _ = try await transport.startAgent(
                        AgentLaunchRequest(kind: kind, name: "gone", cwd: folder))
                }
                #expect(error?.code == "agent_start_failed")
                #expect(
                    error?.message == "\(kind) is not installed on this Host, or is not on its PATH")
                #expect(try await transport.sessionSnapshot().panes.count == before)
            }
        }
    }

    @Test("a folder that is not there is refused before anything starts")
    func missingFolderIsRefused() async throws {
        try await withHost { host in
            let kind = host.unique("agent")
            let remove = try await host.installFakeAgent(kind)
            let outcome: Result<Void, any Error>
            do {
                try await withTransport(host.environment) { transport in
                    let error = await #expect(throws: HerdrAPIError.self) {
                        _ = try await transport.startAgent(
                            AgentLaunchRequest(
                                kind: kind, name: "x", cwd: "/waycar-e2e-no-such-folder"))
                    }
                    #expect(error?.code == "folder_not_found")
                }
                outcome = .success(())
            } catch {
                outcome = .failure(error)
            }
            try await remove()
            try outcome.get()
        }
    }

    // MARK: Helpers

    private static let expectedStatuses: [String: AgentStatus] = [
        "idle": .idle, "working": .working, "blocked": .blocked, "done": .done,
        "error": .blocked,
    ]

    private func withHost(_ body: (CoreFixtureHost) async throws -> Void) async throws {
        let environment = try #require(CoreE2EEnvironment.current)
        let host = try await CoreFixtureHost.open(environment)
        let outcome: Result<Void, any Error>
        do {
            try await host.prepare()
            try await SSHTransportConnector().startCore(settings: environment.settings())
            try await body(host)
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        await host.cleanUp()
        await host.close()
        try outcome.get()
    }

    private func withTransport(
        _ environment: CoreE2EEnvironment, _ body: (any Transport) async throws -> Void
    ) async throws {
        let transport = try await SSHTransportConnector().connect(
            settings: environment.settings(), backend: .core)
        #expect(transport is CoreTransport)
        let outcome: Result<Void, any Error>
        do {
            try await body(transport)
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        try? await transport.close()
        try outcome.get()
    }

    private func withEvents(
        _ transport: any Transport, _ body: (CoreEventFeed) async throws -> Void
    ) async throws {
        let feed = CoreEventFeed(try await transport.subscribeToEvents([]))
        let outcome: Result<Void, any Error>
        do {
            try await body(feed)
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        await feed.end()
        try outcome.get()
    }
}

private func eventually(
    within budget: Duration = .waitCeiling, _ condition: () async throws -> Bool
) async throws -> Bool {
    let deadline = ContinuousClock.now + budget
    while true {
        if try await condition() { return true }
        if ContinuousClock.now >= deadline { return false }
        try await Task.sleep(for: .milliseconds(50))
    }
}

private func eventuallyValue<T>(
    within budget: Duration = .waitCeiling, _ produce: () async throws -> T?
) async throws -> T? {
    let deadline = ContinuousClock.now + budget
    while true {
        if let value = try await produce() { return value }
        if ContinuousClock.now >= deadline { return nil }
        try await Task.sleep(for: .milliseconds(50))
    }
}

// MARK: Fixture

/// What `WAYCAR_CORE_E2E_CONFIG` carries (base64 JSON): where the Host is and
/// the throwaway Ed25519 seed its sshd authorizes.
struct CoreE2EEnvironment: Sendable {
    let host: String
    let port: UInt16
    let username: String
    let deviceKey: Curve25519.Signing.PrivateKey

    static let current: CoreE2EEnvironment? = {
        guard
            let encoded = ProcessInfo.processInfo.environment["WAYCAR_CORE_E2E_CONFIG"],
            let data = Data(base64Encoded: encoded),
            let fixture = try? JSONDecoder().decode(Fixture.self, from: data),
            let deviceKey = try? RealSSHFixture.deviceKey(seed: fixture.deviceKeySeed)
        else { return nil }
        return CoreE2EEnvironment(
            host: fixture.host, port: fixture.port, username: fixture.username,
            deviceKey: deviceKey)
    }()

    func settings() -> SSHTransportSettings {
        var settings = SSHTransportSettings(
            host: host, port: Int(port), username: username,
            credentials: .ed25519(deviceKey),
            hostKeyPolicy: HostKeyPolicy(knownHosts: InMemoryKnownHostsStore()) { _ in true },
            socket: .defaultSession)
        settings.requestTimeout = .sshdBudget(15)
        settings.wakesInLoginSession = false
        settings.detectionSearchesSystemDirectories = false
        return settings
    }

    private struct Fixture: Decodable {
        let host: String
        let port: UInt16
        let username: String
        let deviceKeySeed: String
    }
}

/// A fake agent for the Host: `argv[1]` is its name; it reports OSC 7501
/// status and acts on the lines it reads (`work`, `done`, `ask`, `fail`,
/// `idle`), echoing anything else as `GOT:<line>`.
private let fakeAgentScript = """
    #!/bin/sh
    name=$1
    mode=${2:-idle}
    r() { printf '\\033]7501;state=%s:app=%s%s\\033\\\\' "$1" "$name" "$2"; }
    r "$mode" "$( [ "$mode" = blocked ] && printf ':kind=permission' )"
    while IFS= read -r line; do
      case "$line" in
        work) r working;;
        done) r done;;
        ask) r blocked :kind=permission;;
        fail) r error;;
        idle) r idle;;
        *) printf 'GOT:%s\\n' "$line"; r idle;;
      esac
    done
    """

/// A raw reader: prints READY, then each byte it reads as `B:xx`.
private let readerScript = """
    #!/bin/sh
    stty raw -echo opost onlcr 2>/dev/null
    printf 'READY\\n'
    while :; do
      b=$(dd bs=1 count=1 2>/dev/null | od -An -tx1 | tr -d ' ')
      [ -z "$b" ] && exit 0
      printf 'B:%s\\n' "$b"
    done
    """

/// Exec access to the Host, for starting terminals and inspecting them. One
/// SSH connection; every terminal it starts carries this run's label.
private actor CoreFixtureHost {
    struct Terminal: Sendable {
        let address: String
        let name: String
    }

    struct Record: Sendable {
        let state: String
        let reason: String?
        let cols: Int?
        let rows: Int?
    }

    nonisolated let environment: CoreE2EEnvironment
    private let connection: SSHConnection
    nonisolated let run = String(UUID().uuidString.lowercased().prefix(8))
    private var scratch = ""
    private var home = ""

    private init(environment: CoreE2EEnvironment, connection: SSHConnection) {
        self.environment = environment
        self.connection = connection
    }

    static func open(_ environment: CoreE2EEnvironment) async throws -> CoreFixtureHost {
        let key = DeviceKey(privateKey: environment.deviceKey)
        let connection = try await SSHConnection.connect(
            to: SSHEndpoint(host: environment.host, port: environment.port),
            timeout: .sshdBudget(5))
        do {
            try await connection.authenticate(
                username: environment.username,
                publicKey: key.publicKeyBlob,
                signer: { data in try key.privateKey.signature(for: data) },
                timeout: .sshdBudget(5))
        } catch {
            try? await connection.close(timeout: .sshdBudget(2))
            throw error
        }
        return CoreFixtureHost(environment: environment, connection: connection)
    }

    func close() async {
        try? await connection.close(timeout: .sshdBudget(2))
    }

    nonisolated func unique(_ word: String) -> String {
        "e2e-\(word)-\(run)"
    }

    /// Installs herdr-core for the Host's user when it has none, and writes
    /// the fixture scripts into a scratch directory.
    func prepare() async throws {
        home = try await shell("printf %s \"$HOME\"")
        scratch = "\(home)/.waycar-core-e2e-\(run)"
        let installed = try await shell(
            "[ -x \"$HOME/.local/bin/herdr-core\" ] && echo yes || echo no")
        if installed.trimmingCharacters(in: .whitespacesAndNewlines) != "yes" {
            _ = try await shell("curl -fsSL https://releases.herdr.dev/core/install.sh | sh")
        }
        _ = try await shell("mkdir -p \(quoted(scratch))")
        try await write(fakeAgentScript, to: "\(scratch)/agent.sh")
        try await write(readerScript, to: "\(scratch)/reader.sh")
    }

    nonisolated func agentCommand(name: String, mode: String = "idle") -> String {
        "sh $HOME/.waycar-core-e2e-\(run)/agent.sh \(name) \(mode)"
    }

    nonisolated var readerCommand: String { "sh $HOME/.waycar-core-e2e-\(run)/reader.sh" }

    /// The scratch directory's absolute path, where launches start.
    func scratchDirectory() -> String { scratch }

    /// A program in `~/.local/bin`, which an SSH exec's PATH does not have
    /// on Ubuntu (it is added only when a login shell finds the directory):
    /// what a kind installed there looks like. The returned closure removes
    /// it. `body` is the script after its shebang.
    func installProgram(
        _ name: String, body: String
    ) async throws -> @Sendable () async throws -> Void {
        let directory = "\(home)/.local/bin"
        _ = try await shell("mkdir -p \(quoted(directory))")
        try await write("#!/bin/sh\n" + body + "\n", to: "\(directory)/\(name)")
        _ = try await shell("chmod 755 \(quoted(directory))/\(name)")
        return { [self] in
            _ = try await shell("rm -f \(quoted(directory))/\(name)")
        }
    }

    /// A fake agent as a program: reports OSC 7501 and echoes prompts.
    func installFakeAgent(_ name: String) async throws -> @Sendable () async throws -> Void {
        try await installProgram(
            name, body: "exec sh \"$HOME/.waycar-core-e2e-\(run)/agent.sh\" \(name) idle")
    }

    /// One terminal per status word the Console shows, named after it.
    func startAgents() async throws -> [String: String] {
        var names: [String: String] = [:]
        for (state, mode) in [
            ("idle", "idle"), ("working", "working"), ("blocked", "blocked"), ("done", "done"),
            ("error", "error"),
        ] {
            let name = unique(state)
            _ = try await start(name: name, command: agentCommand(name: name, mode: mode))
            names[state] = name
        }
        return names
    }

    /// `herdr-core run --bg`; `command` nil runs the Host's own shell.
    func start(
        name: String, command: String?, labels: [String: String] = [:]
    ) async throws -> Terminal {
        var line = "run --bg --json --no-parent --name \(name) --cwd \(quoted(scratch))"
        line += " --label waycar-e2e=\(run)"
        for (key, value) in labels.sorted(by: { $0.key < $1.key }) {
            line += " --label \(quoted("\(key)=\(value)"))"
        }
        if let command { line += " -- \(command)" }
        let output = try await hc(line)
        guard let data = output.data(using: .utf8),
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let address = object["address"] as? String
        else {
            throw CoreE2EError.unexpectedOutput(output)
        }
        return Terminal(address: address, name: name)
    }

    func record(_ address: String) async throws -> Record {
        let output = try await hc("get \(address) --json")
        guard let data = output.data(using: .utf8),
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw CoreE2EError.unexpectedOutput(output) }
        return Record(
            state: object["state"] as? String ?? "", reason: object["reason"] as? String,
            cols: object["cols"] as? Int, rows: object["rows"] as? Int)
    }

    @discardableResult
    func hc(_ arguments: String) async throws -> String {
        try await shell("\"$HOME/.local/bin/herdr-core\" \(arguments)")
    }

    func coreIsRunning() async throws -> Bool {
        let output = try await shell(
            "/bin/sh -c '\(CoreConnectCommand.socketScript)"
                + "if \(CoreConnectCommand.runningProbeScript); then echo running; else echo stopped; fi'")
        return output.trimmingCharacters(in: .whitespacesAndNewlines) == "running"
    }

    /// Kills and removes every terminal this run started (by label, and the
    /// ones Waycar's own launches started, which carry `waycar=1` and the
    /// scratch directory as their folder), and its scratch directory.
    func cleanUp() async {
        var addresses: [String] = []
        let selectors: [(String, String?)] = [("waycar-e2e=\(run)", nil), ("waycar=1", scratch)]
        for (selector, folder) in selectors {
            guard
                let listing = try? await hc("ls --all --json --label \(selector)"),
                let data = listing.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let terminals = object["terminals"] as? [[String: Any]]
            else { continue }
            for terminal in terminals {
                guard let address = terminal["address"] as? String else { continue }
                if let folder, terminal["cwd"] as? String != folder { continue }
                if !addresses.contains(address) { addresses.append(address) }
            }
        }
        for address in addresses { _ = try? await hc("kill \(address)") }
        if !addresses.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
        for address in addresses { _ = try? await hc("rm \(address)") }
        if !scratch.isEmpty { _ = try? await shell("rm -rf \(quoted(scratch))") }
    }

    // MARK: Login noise

    /// The startup file that prints for a non-interactive exec under this
    /// user's login shell: bash reads `.bashrc` above its guard (Debian and
    /// Ubuntu), zsh reads `.zshenv`.
    func noisyStartupFile() async throws -> String {
        let login = try await shell("printf %s \"$SHELL\"")
        let name = login.hasSuffix("zsh") ? ".zshenv" : ".bashrc"
        return "\(home)/\(name)"
    }

    /// Puts an `echo` on the first line of `file`; the returned closure
    /// restores it.
    func addNoise(to file: String) async throws -> @Sendable () async throws -> Void {
        let backup = "\(scratch)/startup.backup"
        _ = try await shell(
            "if [ -f \(quoted(file)) ]; then cp \(quoted(file)) \(quoted(backup)); else : > \(quoted(backup)); touch \(quoted(scratch))/startup.absent; fi; "
                + "{ echo 'echo NOISE-ABOVE-THE-GUARD'; cat \(quoted(backup)); } > \(quoted(file))")
        let scratch = scratch
        return { [self] in
            _ = try await shell(
                "if [ -f \(quoted(scratch))/startup.absent ]; then rm -f \(quoted(file)); "
                    + "else cp \(quoted(backup)) \(quoted(file)); fi")
        }
    }

    // MARK: A core that fails

    /// Puts a wrapper where detection finds herdr-core: it answers
    /// `--version` as the real binary and, for `connect`, prints `hc`'s own
    /// one-line error to stderr and exits 2, as `hc connect` does when it
    /// cannot start (a socket path over the limit). `mv` swaps the file
    /// because the running core server holds the binary open. The returned
    /// closure puts the real binary back.
    func wrapCoreFailingConnect(
        message: String, hint: String
    ) async throws -> @Sendable () async throws -> Void {
        let binary = "\(home)/.local/bin/herdr-core"
        let real = "\(scratch)/herdr-core.real"
        let error = #"{"error":{"hint":"\#(hint)","kind":"usage","message":"\#(message)"}}"#
        let wrapper = """
            #!/bin/sh
            if [ "$1" = connect ]; then printf '%s\\n' '\(error)' >&2; exit 2; fi
            exec \(quoted(real)) "$@"
            """
        _ = try await shell("cp \(quoted(binary)) \(quoted(real))")
        try await write(wrapper, to: "\(scratch)/wrapper.sh")
        _ = try await shell(
            "chmod 755 \(quoted(scratch))/wrapper.sh && mv -f \(quoted(scratch))/wrapper.sh \(quoted(binary))")
        let scratch = scratch
        return { [self] in
            _ = try await shell("mv -f \(quoted(scratch))/herdr-core.real \(quoted(binary))")
        }
    }

    // MARK: Exec

    @discardableResult
    func shell(_ command: String) async throws -> String {
        let result = try await connection.execute(command, timeout: .sshdBudget(60))
        guard result.exitStatus == 0 else {
            throw CoreE2EError.commandFailed(
                command: command, exitStatus: result.exitStatus,
                stderr: String(decoding: result.stderr, as: UTF8.self))
        }
        return String(decoding: result.stdout, as: UTF8.self)
    }

    private func write(_ text: String, to path: String) async throws {
        let encoded = Data(text.utf8).base64EncodedString()
        _ = try await shell("printf %s \(quoted(encoded)) | base64 -d > \(quoted(path))")
    }

    private nonisolated func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private enum CoreE2EError: Error, CustomStringConvertible {
    case commandFailed(command: String, exitStatus: Int32, stderr: String)
    case unexpectedOutput(String)

    var description: String {
        switch self {
        case .commandFailed(let command, let exitStatus, let stderr):
            "`\(command)` exited \(exitStatus): \(stderr)"
        case .unexpectedOutput(let output):
            "unexpected output: \(output)"
        }
    }
}

/// Drains one event stream into a log the test searches.
private final class CoreEventLog: Sendable {
    let events = Mutex<[HerdrEvent]>([])
}

private final class CoreEventFeed: Sendable {
    private let log = CoreEventLog()
    private let stream: HerdrEventStream
    private let pump: Task<Void, Never>

    init(_ stream: HerdrEventStream) {
        self.stream = stream
        let log = log
        pump = Task {
            do {
                for try await event in stream.events {
                    log.events.withLock { $0.append(event) }
                }
            } catch {}
        }
    }

    var events: [HerdrEvent] { log.events.withLock { $0 } }

    func end() async {
        await stream.end()
        await pump.value
    }
}

/// Raw attach output, searchable, with how the stream ended.
private final class CoreAttachLog: Sendable {
    struct State {
        var bytes = Data()
        var ending: String?
    }

    let state = Mutex(State())
}

private final class CoreAttachFeed: Sendable {
    private let log = CoreAttachLog()
    private let pump: Task<Void, Never>

    init(_ session: TerminalAttachSession) {
        let log = log
        pump = Task {
            do {
                for try await chunk in session.output {
                    log.state.withLock { $0.bytes.append(chunk) }
                }
                log.state.withLock { $0.ending = "finished" }
            } catch {
                log.state.withLock { $0.ending = "failed: \(error)" }
            }
        }
    }

    var ending: String? {
        get async { log.state.withLock { $0.ending } }
    }

    func waitFor(_ marker: String, within budget: Duration = .sshdBudget(30)) async throws -> Bool {
        try await eventually(within: budget) {
            self.log.state.withLock { $0.bytes.range(of: Data(marker.utf8)) != nil }
        }
    }

    func finished() async {
        await pump.value
    }
}
