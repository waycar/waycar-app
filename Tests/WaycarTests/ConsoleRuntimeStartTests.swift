import Foundation
import Synchronization
import Testing

@testable import Waycar

/// Start Herdr TUI and Start Herdr Core (#389): Waycar never starts a
/// runtime on its own. A Host whose runtime is installed but stopped fails
/// that runtime's connection, every reconnect fails the same way, and only
/// the user's Start runs the starter: once per tap however often it is
/// tapped meanwhile, then that runtime is dialed again. A failed start keeps
/// its words and dials nothing.
@MainActor
@Suite("Console runtime start", .timeLimit(.minutes(1)))
struct ConsoleRuntimeStartTests {
    private static nonisolated let herdrSnapshot = SessionSnapshot.fixture(
        agents: [.fixture(paneID: "w1:p1")],
        workspaces: [.fixture(workspaceID: "w1", label: "Proj")])
    private static nonisolated let coreSnapshot = SessionSnapshot.fixture(
        agents: [.fixture(paneID: "hc:t1", workspaceID: "core:/srv")],
        workspaces: [.fixture(workspaceID: "core:/srv", label: "srv")])
    private static nonisolated let tmuxSnapshot = SessionSnapshot.fixture(
        agents: [.fixture(paneID: "tmux:%1", workspaceID: "tmux:$1")],
        workspaces: [.fixture(workspaceID: "tmux:$1", label: "work")])
    private static nonisolated let socketPath = "/home/dev/.config/herdr/herdr.sock"

    /// Plugins this build is happy with, so a fresh cached presence is not
    /// asked again (#209).
    private nonisolated static func plugin(_ mode: WaycarPluginInstall.Mode) -> WaycarPluginDetection {
        .installed(
            WaycarPluginInstall(
                version: mode == .core
                    ? WaycarPluginRequirement.coreMinimumVersion
                    : WaycarPluginRequirement.minimumVersion,
                mode: mode))
    }
    private static nonisolated let herdrOnly = HostBackendPresence(
        herdr: true, tmuxVersion: nil, waycarPlugin: plugin(.herdr), ultimate: [])
    private static nonisolated let coreOnly = HostBackendPresence(
        herdr: false, tmuxVersion: nil, waycarPlugin: plugin(.core),
        core: CorePresence(version: "0.1.14", path: "/home/dev/.local/bin/herdr-core"),
        ultimate: [])
    private static nonisolated let dual = HostBackendPresence(
        herdr: true, tmuxVersion: "3.4", waycarPlugin: plugin(.herdr), ultimate: [])

    /// What the store asked of the Host: connects and starts per runtime,
    /// and which runtimes a start left running.
    private final class Calls: Sendable {
        private struct State {
            var connects: [HostBackend] = []
            var starts: [HostBackend] = []
            var running: Set<HostBackend> = []
            var startFailures: [any Error] = []
        }
        private let state: Mutex<State>

        init(startFailures: [any Error]) {
            state = Mutex(State(startFailures: startFailures))
        }

        var starts: [HostBackend] { state.withLock { $0.starts } }
        func connects(_ backend: HostBackend) -> Int {
            state.withLock { $0.connects.filter { $0 == backend }.count }
        }
        func connected(_ backend: HostBackend) { state.withLock { $0.connects.append(backend) } }
        func isRunning(_ backend: HostBackend) -> Bool { state.withLock { $0.running.contains(backend) } }
        func startEntered(_ backend: HostBackend) { state.withLock { $0.starts.append(backend) } }
        /// Ends a start: it throws the next scripted failure, if any, or
        /// leaves the runtime running.
        func finishStart(_ backend: HostBackend) throws {
            let failure: (any Error)? = state.withLock { state in
                guard !state.startFailures.isEmpty else {
                    state.running.insert(backend)
                    return nil
                }
                return state.startFailures.removeFirst()
            }
            if let failure { throw failure }
        }
    }

    @MainActor
    private struct Fixture {
        let store: ConsoleStore
        let host: Host
        let calls: Calls
        let directory: URL

        func scope(_ backend: HostBackend) -> ConsoleScope {
            ConsoleScope(hostID: host.id, backend: backend)
        }

        func end() {
            store.setHosts([])
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// A Host with `presence` already cached, whose runtimes in `stopped`
    /// fail their connects with that error until a start ran for them. Each
    /// start waits at `startGate` when given, then throws the next of
    /// `startFailures`, or succeeds.
    private func makeFixture(
        presence: HostBackendPresence,
        stopped: [HostBackend: TransportError],
        startFailures: [any Error] = [],
        startGate: ScriptedTransportCallGate? = nil
    ) -> Fixture {
        let host = Host.fixture()
        let calls = Calls(startFailures: startFailures)
        let herdr = ScriptedTransport(snapshot: Self.herdrSnapshot)
        let core = ScriptedTransport(snapshot: Self.coreSnapshot)
        let tmux = ScriptedTransport(snapshot: Self.tmuxSnapshot)
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "runtime-start-\(UUID().uuidString)", directoryHint: .isDirectory)
        let cache = ConsoleInventoryCache(directory: directory)
        cache.savePresence(.init(presence: presence, verifiedAt: Date()), for: host)
        cache.flush()
        let defaults = UserDefaults(suiteName: "runtime-start-\(UUID().uuidString)") ?? .standard
        let store = ConsoleStore(
            snapshotRetryDelay: .milliseconds(10),
            pins: PinnedAgentsStore(defaults: defaults),
            unread: UnreadAgentsStore(defaults: defaults),
            backendPreferences: HostBackendPreferences(defaults: defaults),
            inventoryCache: cache,
            makeSession: { _, backend, subscriptions in
                EventsSession(
                    subscriptions: subscriptions,
                    connect: {
                        calls.connected(backend)
                        if let stop = stopped[backend], !calls.isRunning(backend) { throw stop }
                        switch backend {
                        case .herdr: return herdr
                        case .core: return core
                        case .tmux: return tmux
                        case .codex, .opencode: return ScriptedTransport(snapshot: .fixture(agents: [], workspaces: []))
                        case .ultimate, .zellij: throw TransportError.cancelled
                        }
                    },
                    reconnectPolicy: ReconnectPolicy(
                        initialDelay: .milliseconds(10), multiplier: 2,
                        maxDelay: .milliseconds(50)),
                    keepalive: nil)
            },
            detectBackends: { _ in
                var detected = presence
                if calls.isRunning(.codex), detected.codex != nil {
                    detected.codex?.socketPath = "/tmp/codex.sock"
                }
                if calls.isRunning(.opencode), detected.opencode != nil {
                    detected.opencode?.serverURL = "http://127.0.0.1:49374"
                }
                return detected
            },
            startRuntime: { _, backend in
                calls.startEntered(backend)
                await startGate?.waitUntilOpen()
                try calls.finishStart(backend)
            })
        return Fixture(store: store, host: host, calls: calls, directory: directory)
    }

    private func start(_ fixture: Fixture) async {
        fixture.store.setHosts([fixture.host])
        await fixture.store.resume()
    }

    // MARK: Codex — Host detail only, never a Console start row

    @Test func codexStateComesFromPresenceAndHonorsTheFloor() {
        let fixture = makeFixture(presence: Self.herdrOnly, stopped: [:])
        defer { fixture.end() }
        let store = fixture.store
        let id = fixture.host.id
        store.setHosts([fixture.host])
        #expect(store.serverRuntimeState(.codex, on: id) == .notInstalled)
        var presence = Self.herdrOnly
        presence.codex = CodexPresence(version: "0.166.0", path: "/bin/codex")
        store.recordDetectedPresence(presence, on: id)
        #expect(store.serverRuntimeState(.codex, on: id) == .needsUpdate(version: "0.166.0"))
        presence.codex?.version = "0.167.0"
        store.recordDetectedPresence(presence, on: id)
        #expect(store.serverRuntimeState(.codex, on: id) == .stopped())
        presence.codex?.socketPath = "/tmp/codex.sock"
        store.recordDetectedPresence(presence, on: id)
        #expect(store.serverRuntimeState(.codex, on: id) == .running)
    }

    /// A Codex whose detection program never answered reads as not
    /// responding, never as not installed or as a server to start.
    @Test func aCodexThatDidNotAnswerIsNotRespondingNotAbsent() {
        let fixture = makeFixture(presence: Self.herdrOnly, stopped: [:])
        defer { fixture.end() }
        let store = fixture.store
        let id = fixture.host.id
        store.setHosts([fixture.host])
        var presence = Self.herdrOnly
        presence.unansweredProbes = [.codexVersion]
        store.recordDetectedPresence(presence, on: id)
        #expect(store.serverRuntimeState(.codex, on: id) == .notResponding(.codexVersion))
        #expect(store.serverRuntimeState(.opencode, on: id) == .notInstalled)
        #expect(!store.serverRuntimeState(.codex, on: id).isAvailable)
        presence.codex = CodexPresence(version: "0.167.1", path: "/bin/codex")
        presence.unansweredProbes = [.codexDaemon]
        store.recordDetectedPresence(presence, on: id)
        #expect(store.serverRuntimeState(.codex, on: id) == .notResponding(.codexDaemon))
        #expect(HostDetectionProbe.codexVersion.message == "Codex didn't respond (codex --version timed out)")
        #expect(HostDetectionProbe.codexDaemon.message
            == "Codex server didn't respond (codex app-server daemon version timed out)")
    }

    @Test func codexStartRedetectsAndConnectsItsNewProjection() async throws {
        var presence = Self.herdrOnly
        presence.codex = CodexPresence(version: "0.167.1", path: "/bin/codex")
        let gate = ScriptedTransportCallGate()
        let fixture = makeFixture(presence: presence, stopped: [:], startGate: gate)
        defer { fixture.end() }
        let store = fixture.store
        let id = fixture.host.id
        await start(fixture)
        #expect(store.serverRuntimeState(.codex, on: id) == .stopped())
        #expect(fixture.calls.connects(.codex) == 0)
        let starting = Task { await store.startRuntime(.codex, on: id) }
        await gate.waitForEntry()
        #expect(store.serverRuntimeState(.codex, on: id) == .starting)
        #expect(!store.offersStart(of: .codex, on: id))
        #expect(await store.startRuntime(.codex, on: id) == false)
        await gate.open()
        #expect(await starting.value)
        try await waitUntil("fresh detection should connect Codex") {
            store.scopeStatuses[fixture.scope(.codex)] == .connected
        }
        #expect(store.serverRuntimeState(.codex, on: id) == .running)
        #expect(fixture.calls.starts == [.codex])
        #expect(fixture.calls.connects(.codex) == 1)
        #expect(fixture.calls.connects(.herdr) == 1)
    }

    @Test func codexFailureStaysInHostStateNotConsoleErrors() async {
        var presence = Self.herdrOnly
        presence.codex = CodexPresence(version: "0.167.1", path: "/bin/codex")
        let fixture = makeFixture(
            presence: presence, stopped: [:],
            startFailures: [HerdrStartError(output: "package incomplete")])
        defer { fixture.end() }
        await start(fixture)
        let store = fixture.store
        let id = fixture.host.id
        #expect(await store.startRuntime(.codex, on: id) == false)
        #expect(store.serverRuntimeState(.codex, on: id) == .stopped(
            error: "Codex server did not start: package incomplete"))
        #expect(store.startErrors(on: id).isEmpty)
        #expect(!store.offersStart(of: .codex, on: id))
        #expect(fixture.calls.connects(.codex) == 0)
    }

    // MARK: OpenCode — Host detail and New Agent only, like Codex

    @Test func openCodeStateComesFromPresenceAndHonorsTheFloor() {
        let fixture = makeFixture(presence: Self.herdrOnly, stopped: [:])
        defer { fixture.end() }
        let store = fixture.store
        let id = fixture.host.id
        store.setHosts([fixture.host])
        #expect(store.serverRuntimeState(.opencode, on: id) == .notInstalled)
        var presence = Self.herdrOnly
        presence.opencode = OpenCodePresence(path: "/home/me/.opencode/bin/opencode", version: "2.1.9")
        store.recordDetectedPresence(presence, on: id)
        #expect(store.serverRuntimeState(.opencode, on: id) == .needsUpdate(version: "2.1.9"))
        presence.opencode?.version = "2.2.0"
        store.recordDetectedPresence(presence, on: id)
        #expect(store.serverRuntimeState(.opencode, on: id) == .stopped())
        #expect(store.serverRuntimeState(.codex, on: id) == .notInstalled)
        presence.opencode?.serverURL = "http://127.0.0.1:49374"
        store.recordDetectedPresence(presence, on: id)
        #expect(store.serverRuntimeState(.opencode, on: id) == .running)
        #expect(store.backendPresence(on: id)?.backends == [.herdr, .opencode])
    }

    @Test func openCodeStartRedetectsAndConnectsItsNewProjection() async throws {
        var presence = Self.herdrOnly
        presence.opencode = OpenCodePresence(path: "/home/me/.opencode/bin/opencode", version: "2.2.7")
        let fixture = makeFixture(presence: presence, stopped: [:])
        defer { fixture.end() }
        let store = fixture.store
        let id = fixture.host.id
        await start(fixture)
        #expect(store.serverRuntimeState(.opencode, on: id) == .stopped())
        #expect(!store.offersStart(of: .opencode, on: id))
        #expect(fixture.calls.connects(.opencode) == 0)
        #expect(await store.startRuntime(.opencode, on: id))
        try await waitUntil("fresh detection should connect OpenCode") {
            store.scopeStatuses[fixture.scope(.opencode)] == .connected
        }
        #expect(store.serverRuntimeState(.opencode, on: id) == .running)
        #expect(fixture.calls.starts == [.opencode])
        #expect(fixture.calls.connects(.opencode) == 1)
    }

    @Test func openCodeFailureStaysInHostStateNotConsoleErrors() async {
        var presence = Self.herdrOnly
        presence.opencode = OpenCodePresence(path: "/home/me/.opencode/bin/opencode", version: "2.2.7")
        let fixture = makeFixture(
            presence: presence, stopped: [:],
            startFailures: [HerdrStartError(output: "port in use")])
        defer { fixture.end() }
        await start(fixture)
        let store = fixture.store
        let id = fixture.host.id
        #expect(await store.startRuntime(.opencode, on: id) == false)
        #expect(store.serverRuntimeState(.opencode, on: id) == .stopped(
            error: "OpenCode server did not start: port in use"))
        #expect(store.startErrors(on: id).isEmpty)
        #expect(fixture.calls.connects(.opencode) == 0)
    }

    // MARK: Herdr TUI

    @Test(arguments: [
        TransportError.herdrNotRunning(path: socketPath),
        .streamLocalOpenFailed(path: socketPath),
    ])
    func aStoppedHerdrIsOfferedItsStartAndOnlyTheStartRunsIt(stop: TransportError) async throws {
        let fixture = makeFixture(presence: Self.herdrOnly, stopped: [.herdr: stop])
        defer { fixture.end() }
        let store = fixture.store
        let hostID = fixture.host.id
        await start(fixture)
        try await waitUntil("herdr should fail as stopped") {
            store.scopeStatuses[fixture.scope(.herdr)] == .failed(stop)
        }
        #expect(store.offersStart(of: .herdr, on: hostID))
        #expect(!store.offersStart(of: .core, on: hostID))

        // A reconnect dials again and fails the same way; nothing starts.
        await store.retryHost(hostID)
        try await waitUntil("the reconnect should fail the same way") {
            fixture.calls.connects(.herdr) == 2
                && store.scopeStatuses[fixture.scope(.herdr)] == .failed(stop)
        }
        #expect(fixture.calls.starts.isEmpty)

        #expect(await store.startRuntime(.herdr, on: hostID))
        #expect(fixture.calls.starts == [.herdr])
        try await waitUntil("herdr should connect after the start") {
            store.scopeStatuses[fixture.scope(.herdr)] == .connected
        }
        #expect(fixture.calls.connects(.herdr) == 3)
        #expect(!store.offersStart(of: .herdr, on: hostID))
        #expect(!store.isStarting(.herdr, on: hostID))
        #expect(store.startError(.herdr, on: hostID) == nil)
    }

    @Test func overlappingTapsStartHerdrOnce() async throws {
        let gate = ScriptedTransportCallGate()
        let stop = TransportError.herdrNotRunning(path: Self.socketPath)
        let fixture = makeFixture(
            presence: Self.herdrOnly, stopped: [.herdr: stop], startGate: gate)
        defer { fixture.end() }
        let store = fixture.store
        let hostID = fixture.host.id
        await start(fixture)
        try await waitUntil("herdr should fail as stopped") {
            store.scopeStatuses[fixture.scope(.herdr)] == .failed(stop)
        }

        let first = Task { await store.startRuntime(.herdr, on: hostID) }
        await gate.waitForEntry()
        #expect(store.isStarting(.herdr, on: hostID))
        #expect(store.offersStart(of: .herdr, on: hostID))
        #expect(await store.startRuntime(.herdr, on: hostID) == false)

        await gate.open()
        #expect(await first.value)
        #expect(fixture.calls.starts == [.herdr])
        try await waitUntil("herdr should connect after the start") {
            store.scopeStatuses[fixture.scope(.herdr)] == .connected
        }
    }

    /// The outcome of a start belongs to the Host as it was: one removed or
    /// pointed elsewhere while it ran keeps no words and redials nothing.
    @Test(arguments: [false, true])
    func aStartOutlivedByItsHostLeavesNothingBehind(edited: Bool) async throws {
        let gate = ScriptedTransportCallGate()
        let stop = TransportError.herdrNotRunning(path: Self.socketPath)
        let fixture = makeFixture(
            presence: Self.herdrOnly, stopped: [.herdr: stop],
            startFailures: [HerdrStartError(output: "refused")], startGate: gate)
        defer { fixture.end() }
        let store = fixture.store
        let hostID = fixture.host.id
        await start(fixture)
        try await waitUntil("herdr should fail as stopped") {
            store.scopeStatuses[fixture.scope(.herdr)] == .failed(stop)
        }

        let started = Task { await store.startRuntime(.herdr, on: hostID) }
        await gate.waitForEntry()
        if edited {
            var moved = fixture.host
            moved.address = "elsewhere.example"
            store.setHosts([moved])
        } else {
            store.setHosts([])
        }
        await gate.open()
        #expect(await started.value == false)
        #expect(store.startError(.herdr, on: hostID) == nil)
        #expect(!store.isStarting(.herdr, on: hostID))
    }

    /// A start herdr refuses keeps herdr's words; one the link refuses, the
    /// link's. Neither dials herdr again.
    @Test func aFailedStartKeepsItsWordsAndDialsNothing() async throws {
        let refusals: [(any Error, String)] = [
            (
                HerdrStartError(output: "herdr: config.toml: invalid key\n"),
                "Herdr TUI did not start: herdr: config.toml: invalid key"
            ),
            (
                TransportError.sshUnreachable(detail: "down"),
                TransportError.sshUnreachable(detail: "down").presentation.message
            ),
        ]
        for (refusal, words) in refusals {
            let stop = TransportError.herdrNotRunning(path: Self.socketPath)
            let fixture = makeFixture(
                presence: Self.herdrOnly, stopped: [.herdr: stop], startFailures: [refusal])
            defer { fixture.end() }
            let store = fixture.store
            let hostID = fixture.host.id
            await start(fixture)
            try await waitUntil("herdr should fail as stopped") {
                store.scopeStatuses[fixture.scope(.herdr)] == .failed(stop)
            }

            #expect(await store.startRuntime(.herdr, on: hostID) == false)
            #expect(store.startError(.herdr, on: hostID) == words)
            #expect(store.startErrors(on: hostID) == [.herdr: words])
            try await Task.sleep(for: .milliseconds(50))
            #expect(fixture.calls.connects(.herdr) == 1)
            #expect(store.scopeStatuses[fixture.scope(.herdr)] == .failed(stop))
            #expect(store.offersStart(of: .herdr, on: hostID))
            #expect(!store.isStarting(.herdr, on: hostID))

            // The next tap clears the words, and a start that works keeps
            // none once herdr connects.
            #expect(await store.startRuntime(.herdr, on: hostID))
            try await waitUntil("herdr should connect after the second start") {
                store.scopeStatuses[fixture.scope(.herdr)] == .connected
            }
            #expect(store.startError(.herdr, on: hostID) == nil)
            #expect(fixture.calls.starts == [.herdr, .herdr])
        }
    }

    /// A missing herdr, and a named session that does not exist, are no
    /// stopped server: starting would install nothing, or create a session.
    @Test(arguments: [
        TransportError.socketNotFound(path: socketPath),
        .herdrSessionNotFound(path: "/home/dev/.config/herdr/sessions/work/herdr.sock"),
    ])
    func aMissingHerdrOrSessionIsOfferedNoStart(failure: TransportError) async throws {
        let fixture = makeFixture(presence: Self.herdrOnly, stopped: [.herdr: failure])
        defer { fixture.end() }
        let store = fixture.store
        await start(fixture)
        try await waitUntil("herdr should fail") {
            store.scopeStatuses[fixture.scope(.herdr)] == .failed(failure)
        }
        #expect(!store.offersStart(of: .herdr, on: fixture.host.id))
        #expect(fixture.calls.starts.isEmpty)
    }

    /// herdr stopped beside a tmux that has sessions: tmux leads, and
    /// herdr's own row starts it.
    @Test func aStoppedHerdrBesideTmuxIsOfferedItsStartOnItsOwnRow() async throws {
        let stop = TransportError.herdrNotRunning(path: Self.socketPath)
        let fixture = makeFixture(presence: Self.dual, stopped: [.herdr: stop])
        defer { fixture.end() }
        let store = fixture.store
        let hostID = fixture.host.id
        await start(fixture)
        try await waitUntil("tmux should lead while herdr is stopped") {
            store.hostLeadBackends[hostID] == .tmux
                && store.scopeStatuses[fixture.scope(.tmux)] == .connected
                && store.scopeStatuses[fixture.scope(.herdr)] == .failed(stop)
        }
        #expect(store.offersStart(of: .herdr, on: hostID))
        let secondary = try #require(store.failedSecondaryScopes(on: hostID).first)
        let row = ConsoleHostStatusPresentation(
            host: fixture.host, failedScope: secondary.scope, failure: secondary.failure,
            startErrors: store.startErrors(on: hostID))
        #expect(row.startsRuntime == .herdr)
        #expect(!row.navigates)

        #expect(await store.startRuntime(.herdr, on: hostID))
        try await waitUntil("herdr should connect after the start") {
            store.scopeStatuses[fixture.scope(.herdr)] == .connected
        }
        #expect(fixture.calls.starts == [.herdr])
        #expect(store.failedSecondaryScopes(on: hostID).isEmpty)
    }

    // MARK: Herdr Core

    /// The same path for a core-only Host: offered, one start for two taps,
    /// its words when it fails, and a redial once it worked.
    @Test func aStoppedCoreIsOfferedStartHerdrCoreAndRedialedAfterIt() async throws {
        let gate = ScriptedTransportCallGate()
        let fixture = makeFixture(
            presence: Self.coreOnly, stopped: [.core: .coreNotRunning],
            startFailures: [HerdrStartError(output: "hc: socket busy")], startGate: gate)
        defer { fixture.end() }
        let store = fixture.store
        let hostID = fixture.host.id
        await start(fixture)
        try await waitUntil("core should fail as stopped") {
            store.scopeStatuses[fixture.scope(.core)] == .failed(.coreNotRunning)
        }
        #expect(store.hostLeadBackends[hostID] == .core)
        #expect(store.offersStart(of: .core, on: hostID))
        #expect(!store.offersStart(of: .herdr, on: hostID))
        await store.retryHost(hostID)
        try await waitUntil("the reconnect should fail the same way") {
            fixture.calls.connects(.core) == 2
                && store.scopeStatuses[fixture.scope(.core)] == .failed(.coreNotRunning)
        }
        #expect(fixture.calls.starts.isEmpty)

        // Two taps while the first start runs: one start, which fails.
        let first = Task { await store.startRuntime(.core, on: hostID) }
        await gate.waitForEntry()
        #expect(store.isStarting(.core, on: hostID))
        #expect(await store.startRuntime(.core, on: hostID) == false)
        await gate.open()
        #expect(await first.value == false)
        #expect(fixture.calls.starts == [.core])
        #expect(store.startError(.core, on: hostID) == "Herdr Core did not start: hc: socket busy")
        try await Task.sleep(for: .milliseconds(50))
        #expect(fixture.calls.connects(.core) == 2)

        #expect(await store.startRuntime(.core, on: hostID))
        #expect(fixture.calls.starts == [.core, .core])
        try await waitUntil("core should connect after the start") {
            store.scopeStatuses[fixture.scope(.core)] == .connected
        }
        #expect(fixture.calls.connects(.core) == 3)
        #expect(!store.offersStart(of: .core, on: hostID))
        #expect(store.startError(.core, on: hostID) == nil)
    }

    // MARK: Production starter

    @Test func theSSHStarterStartsTheRuntimeAskedForAndNothingElse() async throws {
        let connector = FakeTransportConnector(
            outcome: .connects(
                pingResult: .success(ServerInfo(version: "0.9.5", protocolVersion: 22))))
        let knownHosts = InMemoryKnownHostsStore()
        let starter = ConsoleStore.sshRuntimeStarter(
            connector: connector, knownHosts: knownHosts,
            credentials: HostCredentialsProvider(
                deviceKeys: DeviceKeyStore(secrets: InMemorySecretStore()),
                rsaKeys: RSAKeyStore(secrets: InMemorySecretStore()),
                secrets: InMemorySecretStore()),
            trustPollInterval: .milliseconds(10))
        let host = Host.fixture()

        try await starter(host, .herdr)
        #expect(await connector.wakeCount == 1)
        #expect(await connector.coreStartCount == 0)
        try await starter(host, .core)
        #expect(await connector.wakeCount == 1)
        #expect(await connector.coreStartCount == 1)
        #expect(await connector.codexStartCount == 0)
        try await starter(host, .codex)
        #expect(await connector.codexStartCount == 1)
        #expect(await connector.openCodeStartCount == 0)
        try await starter(host, .opencode)
        #expect(await connector.openCodeStartCount == 1)
        try await starter(host, .tmux)
        try await starter(SampleHost.host, .herdr)
        try await starter(SampleHost.host, .codex)
        try await starter(SampleHost.host, .opencode)
        #expect(await connector.wakeCount == 1)
        #expect(await connector.coreStartCount == 1)
        #expect(await connector.codexStartCount == 1)
        #expect(await connector.openCodeStartCount == 1)
    }
}
