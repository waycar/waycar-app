import Foundation
import Synchronization
import Testing

@testable import Waycar

/// The Console's side of #105: an attach starts without waiting for its
/// Host's snapshot, guarded so a row whose pane is gone ends in the
/// pane-gone flow rather than an error; backend detection and a dual
/// Host's tmux connection wait until the Host's connection settles, and a
/// fresh detection is not asked again.
@MainActor
@Suite("Console store connect flow", .timeLimit(.minutes(1)))
struct ConsoleStoreConnectFlowTests {
    private static let request = TerminalAttachRequest(target: "w1:p1", cols: 80, rows: 24)
    private static let snapshot = SessionSnapshot.fixture(
        agents: [.fixture(paneID: "w1:p1")],
        workspaces: [.fixture(workspaceID: "w1", label: "Proj")])
    private static let tmuxSnapshot = SessionSnapshot.fixture(
        agents: [.fixture(paneID: "tmux:%1", workspaceID: "tmux:$1")],
        workspaces: [.fixture(workspaceID: "tmux:$1", label: "work")])
    /// A plugin this build is happy with, so a fresh presence holding it is
    /// not asked again (#209).
    private static let currentPlugin = WaycarPluginDetection.installed(
        WaycarPluginInstall(version: WaycarPluginRequirement.minimumVersion, mode: .herdr))
    private static let outdatedPlugin = WaycarPluginDetection.installed(
        WaycarPluginInstall(version: "1.3.1", mode: .herdr))
    private static let herdrProbed = HostBackendPresence(
        herdr: true, tmuxVersion: nil, waycarPlugin: currentPlugin, ultimate: [])
    private static let dual = HostBackendPresence(
        herdr: true, tmuxVersion: "3.4", waycarPlugin: currentPlugin, ultimate: [])
    private static let outdated = HostBackendPresence(
        herdr: true, tmuxVersion: nil, waycarPlugin: outdatedPlugin, ultimate: [])

    /// What the store asked of the fixture, in order: connects per backend
    /// and detections started, plus how many detections answered.
    private final class Calls: Sendable {
        enum Call: Equatable, Sendable {
            case connect(HostBackend)
            case detection
        }

        private let state = Mutex((log: [Call](), answered: 0))
        private let codexProbes = Mutex(0)
        var codexProbeCount: Int { codexProbes.withLock { $0 } }
        func probedCodex() { codexProbes.withLock { $0 += 1 } }
        private let openCodeProbes = Mutex(0)
        var openCodeProbeCount: Int { openCodeProbes.withLock { $0 } }
        func probedOpenCode() { openCodeProbes.withLock { $0 += 1 } }
        var log: [Call] { state.withLock { $0.log } }
        var detections: Int { log.filter { $0 == .detection }.count }
        var answeredDetections: Int { state.withLock { $0.answered } }
        func connects(_ backend: HostBackend) -> Int {
            log.filter { $0 == .connect(backend) }.count
        }
        /// Records a connect; returns how many `backend` has had, this one
        /// included.
        func connected(_ backend: HostBackend) -> Int {
            state.withLock { state in
                state.log.append(.connect(backend))
                return state.log.filter { $0 == .connect(backend) }.count
            }
        }
        /// Records a detection start; returns how many there were, this one
        /// included.
        func detected() -> Int {
            state.withLock { state in
                state.log.append(.detection)
                return state.log.filter { $0 == .detection }.count
            }
        }
        func answered() { state.withLock { $0.answered += 1 } }
    }

    /// `herdrReconnect` serves every herdr connect after the first, as a
    /// real reconnect gets a new connection. Detections answer `presence`,
    /// or `laterPresence` from the second on, each once `detectionGate`
    /// (when given) opens.
    private func makeStore(
        herdr: ScriptedTransport,
        herdrReconnect: ScriptedTransport? = nil,
        tmux: ScriptedTransport? = nil,
        calls: Calls = Calls(),
        presence: HostBackendPresence = .herdrOnly,
        laterPresence: HostBackendPresence? = nil,
        detectionGate: ScriptedTransportCallGate? = nil,
        probeCodexServer: @escaping @Sendable (Host, CodexPresence) async throws -> Bool = { _, _ in false },
        probeOpenCodeServer: @escaping @Sendable (Host, OpenCodePresence) async throws -> Bool = { _, _ in false },
        inventoryCache: ConsoleInventoryCache? = nil
    ) -> ConsoleStore {
        let defaults = UserDefaults(suiteName: "console-connect-flow-\(UUID().uuidString)") ?? .standard
        return ConsoleStore(
            snapshotRetryDelay: .milliseconds(10),
            pins: PinnedAgentsStore(defaults: defaults),
            unread: UnreadAgentsStore(defaults: defaults),
            backendPreferences: HostBackendPreferences(defaults: defaults),
            inventoryCache: inventoryCache,
            makeSession: { _, backend, subscriptions in
                EventsSession(
                    subscriptions: subscriptions,
                    connect: {
                        let number = calls.connected(backend)
                        switch backend {
                        case .ultimate, .zellij: throw TransportError.cancelled
                        case .codex, .opencode: return ScriptedTransport(snapshot: .fixture(agents: [], workspaces: []))
                        case .herdr, .core:
                            return number > 1 ? herdrReconnect ?? herdr : herdr
                        case .tmux:
                            guard let tmux else {
                                throw TransportError.tmuxNotInstalled
                            }
                            return tmux
                        }
                    },
                    reconnectPolicy: ReconnectPolicy(
                        initialDelay: .milliseconds(10), multiplier: 2,
                        maxDelay: .milliseconds(50)),
                    keepalive: nil)
            },
            detectBackends: { _ in
                let number = calls.detected()
                await detectionGate?.waitUntilOpen()
                calls.answered()
                return number > 1 ? laterPresence ?? presence : presence
            },
            probeServerRuntime: { host, server, presence in
                switch server {
                case .codex:
                    calls.probedCodex()
                    guard let codex = presence.codex else { return false }
                    return try await probeCodexServer(host, codex)
                case .opencode:
                    calls.probedOpenCode()
                    guard let opencode = presence.opencode else { return false }
                    return try await probeOpenCodeServer(host, opencode)
                }
            })
    }

    private func makeCache(presence: HostBackendPresence, verifiedAt: Date, for host: Host)
        -> (ConsoleInventoryCache, URL)
    {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "connect-flow-\(UUID().uuidString)", directoryHint: .isDirectory)
        let cache = ConsoleInventoryCache(directory: directory)
        cache.savePresence(.init(presence: presence, verifiedAt: verifiedAt), for: host)
        cache.flush()
        return (cache, directory)
    }

    // MARK: Attach first

    @Test func anAttachStartsBeforeTheHostsSnapshotVerifiesItsRow() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: Self.snapshot)
        let snapshotGate = ScriptedTransportCallGate()
        let attachEnd = ScriptedTransportCallGate()
        await transport.gateNextSnapshot(using: snapshotGate)
        let store = makeStore(herdr: transport)
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        await snapshotGate.waitForEntry()

        let runner = store.terminalRunner(for: host.id)
        let attach = Task {
            try await runner(Self.request, TerminalSessionHandler { _ in
                await attachEnd.waitUntilOpen()
            })
        }
        try await waitUntil("the attach must open while the snapshot is unanswered") {
            await transport.attachRequests == [Self.request]
        }
        #expect(store.hostsAwaitingSnapshot.contains(host.id))

        await snapshotGate.open()
        try await waitUntil("the snapshot should verify the row") {
            !store.hostsAwaitingSnapshot.contains(host.id)
        }
        await attachEnd.open()
        try await attach.value
        #expect(await transport.attachRequests == [Self.request])
    }

    /// An attach that ends before the Host's rows are verified is not shown
    /// as ended: the row is verified first, and still listing the pane it
    /// is attached once more.
    @Test func anAttachEndingBeforeVerificationIsRetriedOnceTheRowIsVerified() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: Self.snapshot)
        let snapshotGate = ScriptedTransportCallGate()
        await transport.gateNextSnapshot(using: snapshotGate)
        let store = makeStore(herdr: transport)
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        await snapshotGate.waitForEntry()

        let runner = store.terminalRunner(for: host.id)
        let attach = Task {
            try await runner(Self.request, TerminalSessionHandler { _ in })
        }
        try await waitUntil("the first attach should run") {
            await transport.attachRequests.count == 1
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(await transport.attachRequests.count == 1)
        #expect(store.hostsAwaitingSnapshot.contains(host.id))

        await snapshotGate.open()
        try await attach.value
        #expect(await transport.attachRequests == [Self.request, Self.request])
    }

    /// A pane gone by the time the Host answers: the attach's failure waits
    /// for verification — no error before it — and is not retried.
    @Test func anAttachToAPaneGoneByVerificationFailsOnlyAfterItAndOnlyOnce() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: Self.snapshot)
        let snapshotGate = ScriptedTransportCallGate()
        await transport.gateNextSnapshot(using: snapshotGate)
        let store = makeStore(herdr: transport)
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        await snapshotGate.waitForEntry()

        let gone = TerminalAttachRequest(target: "w1:p9", cols: 80, rows: 24)
        let failure = TransportError.channelFailed(detail: "agent_not_found")
        let runner = store.terminalRunner(for: host.id)
        let attach = Task {
            try await runner(gone, TerminalSessionHandler { _ in throw failure })
        }
        try await waitUntil("the attach should run") {
            await transport.attachRequests.count == 1
        }
        try await Task.sleep(for: .milliseconds(30))
        let finishedEarly = Flag()
        Task { _ = try? await attach.value; finishedEarly.set() }
        try await Task.sleep(for: .milliseconds(30))
        #expect(!finishedEarly.isSet)

        await snapshotGate.open()
        await #expect(throws: failure) { try await attach.value }
        #expect(await transport.attachRequests == [gone])
    }

    // MARK: Deferred connect work

    @Test func aFreshDetectionIsNotAskedAgain() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: Self.snapshot)
        let calls = Calls()
        let (cache, directory) = makeCache(presence: Self.herdrProbed, verifiedAt: Date(), for: host)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(herdr: transport, calls: calls, inventoryCache: cache)
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil("the Host should verify") {
            store.hostStatuses[host.id] == .connected
                && !store.hostsAwaitingSnapshot.contains(host.id)
        }
        await store.reactivate()
        try await Task.sleep(for: .milliseconds(50))

        #expect(calls.detections == 0)
        #expect(calls.codexProbeCount == 0)
    }

    @Test func aFreshCacheFromBeforeCodexDiscoveryIsAskedAgain() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: Self.snapshot)
        let calls = Calls()
        var legacy = Self.herdrProbed
        legacy.codexProbed = nil
        // The old cache's missing key must decode as never probed, not absent.
        let decoded = try JSONDecoder().decode(
            HostBackendPresence.self, from: JSONEncoder().encode(legacy))
        #expect(decoded.codexProbed == nil)
        let (cache, directory) = makeCache(presence: decoded, verifiedAt: Date(), for: host)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(
            herdr: transport, calls: calls, presence: Self.herdrProbed, inventoryCache: cache)
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil("an unprobed cache should detect Codex") {
            store.backendPresence(on: host.id)?.codexProbed == true
        }
        #expect(calls.detections == 1)
        await store.reactivate()
        try await Task.sleep(for: .milliseconds(50))
        #expect(calls.detections == 1)
        #expect(calls.codexProbeCount == 0)
    }

    @Test(arguments: [false, true])
    func stoppedCodexUsesOnlyASocketProbeUntilAnExternalStart(reconnecting: Bool) async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: Self.snapshot)
        let calls = Calls()
        var stopped = Self.herdrProbed
        stopped.codex = CodexPresence(
            version: "0.167.1", path: "/bin/codex", probeSocketPath: "/custom/codex.sock")
        var running = stopped
        running.codex?.socketPath = "/custom/codex.sock"
        let externallyStarted = Mutex(false)
        let (cache, directory) = makeCache(presence: stopped, verifiedAt: Date(), for: host)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(
            herdr: transport, herdrReconnect: ScriptedTransport(snapshot: Self.snapshot),
            calls: calls, presence: running,
            probeCodexServer: { _, presence in
                #expect(presence.probeSocketPath == "/custom/codex.sock")
                return externallyStarted.withLock { $0 }
            }, inventoryCache: cache)
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil("stopped Codex should get one socket probe after connect") {
            calls.codexProbeCount == 1
        }
        #expect(calls.detections == 0)
        #expect(calls.connects(.codex) == 0)
        externallyStarted.withLock { $0 = true }
        if reconnecting {
            await store.retryHost(host.id)
        } else {
            await store.reactivate()
        }
        try await waitUntil("a socket listener should trigger detection and connect Codex") {
            store.scopeStatuses[ConsoleScope(hostID: host.id, backend: .codex)] == .connected
        }
        #expect(calls.codexProbeCount == 2)
        #expect(calls.detections == 1)
        #expect(store.backendPresence(on: host.id)?.codexRunning == true)
    }

    @Test func stoppedOpenCodeUsesOnlyAPortProbeUntilAnExternalStart() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: Self.snapshot)
        let calls = Calls()
        var stopped = Self.herdrProbed
        stopped.opencode = OpenCodePresence(
            path: "/home/me/.opencode/bin/opencode", version: "2.2.7",
            registeredURL: "http://127.0.0.1:50123", registeredPID: 7)
        var running = stopped
        running.opencode?.serverURL = "http://127.0.0.1:50123"
        let externallyStarted = Mutex(false)
        let (cache, directory) = makeCache(presence: stopped, verifiedAt: Date(), for: host)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(
            herdr: transport, calls: calls, presence: running,
            probeOpenCodeServer: { _, presence in
                #expect(presence.endpoint == OpenCodeEndpoint(host: "127.0.0.1", port: 50123))
                return externallyStarted.withLock { $0 }
            }, inventoryCache: cache)
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil("stopped OpenCode should get one port probe after connect") {
            calls.openCodeProbeCount == 1
        }
        #expect(calls.detections == 0)
        #expect(calls.connects(.opencode) == 0)
        #expect(store.serverRuntimeState(.opencode, on: host.id) == .stopped())
        externallyStarted.withLock { $0 = true }
        await store.reactivate()
        try await waitUntil("an answering port should trigger detection and connect OpenCode") {
            store.scopeStatuses[ConsoleScope(hostID: host.id, backend: .opencode)] == .connected
        }
        #expect(calls.openCodeProbeCount == 2)
        #expect(calls.codexProbeCount == 0)
        #expect(calls.detections == 1)
        #expect(store.serverRuntimeState(.opencode, on: host.id) == .running)
    }

    @Test func aStaleDetectionWaitsForTheFirstSnapshot() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: Self.snapshot)
        let snapshotGate = ScriptedTransportCallGate()
        await transport.gateNextSnapshot(using: snapshotGate)
        let calls = Calls()
        let stale = Date().addingTimeInterval(-ConsoleStore.backendPresenceFreshness - 60)
        let (cache, directory) = makeCache(presence: .herdrOnly, verifiedAt: stale, for: host)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(herdr: transport, calls: calls, inventoryCache: cache)
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        await snapshotGate.waitForEntry()
        try await Task.sleep(for: .milliseconds(30))
        #expect(calls.detections == 0)

        await snapshotGate.open()
        // The saved presence lands after the detection answers, so wait for
        // it, not for the call counter (the counter flips when the detection
        // starts).
        let reader = ConsoleInventoryCache(directory: directory)
        try await waitUntil("the detection should save its presence after the snapshot") {
            reader.loadPresence(for: host)?.verifiedAt.map { $0 > stale } == true
        }
        #expect(calls.detections == 1)
    }

    /// A fresh presence still yields to a failure that says a backend is
    /// gone: the Host is asked at once.
    @Test func aMissingBackendIsDetectedAtOnceWhateverItsAge() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: Self.snapshot)
        await transport.failPing(atCall: 1, with: .socketNotFound(path: "/h/.config/herdr/herdr.sock"))
        let calls = Calls()
        let (cache, directory) = makeCache(presence: Self.herdrProbed, verifiedAt: Date(), for: host)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(herdr: transport, calls: calls, inventoryCache: cache)
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()

        try await waitUntil("the missing herdr should be asked about") {
            calls.detections == 1
        }
    }

    /// A fresh presence whose plugin was never probed (cached by an older
    /// build), is missing (WAY-341) or is outdated is asked again once the
    /// Host settles (#209), so an install or update made in a terminal
    /// clears the prompt; once current, an activation inside the freshness
    /// window asks nothing.
    @Test(arguments: [
        HostBackendPresence(herdr: true, tmuxVersion: nil),
        HostBackendPresence(herdr: true, tmuxVersion: nil, waycarPlugin: .notInstalled),
        HostBackendPresence(
            herdr: true, tmuxVersion: nil,
            waycarPlugin: .installed(WaycarPluginInstall(version: "1.3.1", mode: .herdr))),
    ])
    func aFreshPresenceWithAnUnprobedMissingOrOutdatedPluginIsAskedAgain(
        cached: HostBackendPresence
    ) async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: Self.snapshot)
        let calls = Calls()
        let (cache, directory) = makeCache(presence: cached, verifiedAt: Date(), for: host)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(
            herdr: transport, calls: calls, presence: Self.herdrProbed, inventoryCache: cache)
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()

        let current = WaycarPluginStatus.current(version: WaycarPluginRequirement.minimumVersion)
        try await waitUntil("the plugin should be asked about once the Host settles") {
            store.waycarPluginStatus(on: host.id) == current
        }
        #expect(calls.detections == 1)
        await store.reactivate()
        try await Task.sleep(for: .milliseconds(50))
        #expect(calls.detections == 1)
    }

    /// A fresh presence cached by a build before the Ultimate backend never
    /// asked about Ultimate projects: the Host is asked again once it
    /// settles, so a running Ultimate appears without waiting out the
    /// freshness window; once probed, an activation asks nothing.
    @Test func aFreshPresenceThatNeverProbedUltimateIsAskedAgain() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: Self.snapshot)
        let calls = Calls()
        let cached = HostBackendPresence(
            herdr: true, tmuxVersion: nil, waycarPlugin: Self.currentPlugin)
        let (cache, directory) = makeCache(presence: cached, verifiedAt: Date(), for: host)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(
            herdr: transport, calls: calls, presence: Self.herdrProbed, inventoryCache: cache)
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()

        try await waitUntil("the Host should be asked about Ultimate once it settles") {
            calls.answeredDetections == 1
        }
        await store.reactivate()
        try await Task.sleep(for: .milliseconds(50))
        #expect(calls.detections == 1)
    }

    /// After an update the installer's presence is recorded at once and the
    /// Host reconnects through its session factory on a new connection, so
    /// per-connection plugin caches start over (#209). A detection the
    /// outdated presence started, answering after the update, is dropped.
    @Test func aPluginUpdateRecordsThePresenceAndReconnects() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: Self.snapshot)
        let replacement = ScriptedTransport(snapshot: Self.snapshot)
        let calls = Calls()
        let detectionGate = ScriptedTransportCallGate()
        let (cache, directory) = makeCache(presence: Self.outdated, verifiedAt: Date(), for: host)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(
            herdr: transport, herdrReconnect: replacement, calls: calls, presence: Self.outdated,
            detectionGate: detectionGate, inventoryCache: cache)
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        // The outdated plugin is asked about again once the Host settles;
        // that detection's answer is held until after the update.
        await detectionGate.waitForEntry()
        #expect(
            store.waycarPluginStatus(on: host.id)
                == .outdated(installed: "1.3.1", required: WaycarPluginRequirement.minimumVersion))
        #expect(calls.connects(.herdr) == 1)

        store.waycarPluginUpdated(on: host.id, presence: Self.herdrProbed)

        #expect(store.backendPresence(on: host.id) == Self.herdrProbed)
        try await waitUntil("the Host should reconnect on a new connection") {
            calls.connects(.herdr) == 2 && store.hostStatuses[host.id] == .connected
                && !store.hostsAwaitingSnapshot.contains(host.id)
        }
        #expect(await transport.isClosed)
        #expect(await !replacement.capturedSubscriptions.isEmpty)

        await detectionGate.open()
        try await waitUntil("the held detection should answer") {
            calls.answeredDetections == 1
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.backendPresence(on: host.id) == Self.herdrProbed)
        #expect(calls.detections == 1)
    }

    /// An update whose follow-up detection failed asks the Host again, but
    /// only once the reconnect settles, so the exec never races the new
    /// connection's first snapshot (#105).
    @Test func aPluginUpdateWithoutAPresenceAsksAgainAfterTheReconnect() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: Self.snapshot)
        let replacement = ScriptedTransport(snapshot: Self.snapshot)
        let calls = Calls()
        let (cache, directory) = makeCache(presence: Self.outdated, verifiedAt: Date(), for: host)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(
            herdr: transport, herdrReconnect: replacement, calls: calls, presence: Self.outdated,
            laterPresence: Self.herdrProbed, inventoryCache: cache)
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        try await waitUntil("the outdated plugin should be asked about once the Host settles") {
            calls.answeredDetections == 1
        }

        store.waycarPluginUpdated(on: host.id, presence: nil)

        let current = WaycarPluginStatus.current(version: WaycarPluginRequirement.minimumVersion)
        try await waitUntil("the Host should be asked again after it reconnects") {
            store.waycarPluginStatus(on: host.id) == current
        }
        #expect(calls.log == [.connect(.herdr), .detection, .connect(.herdr), .detection])
        #expect(store.hostStatuses[host.id] == .connected)
    }

    /// On a Host running both backends, tmux connects once herdr's rows are
    /// verified, so the Host's first rows and attaches never queue behind
    /// tmux's control client and snapshot.
    @Test func aDualHostsTmuxConnectsAfterHerdrsFirstSnapshot() async throws {
        let host = Host.fixture()
        let herdr = ScriptedTransport(snapshot: Self.snapshot)
        let tmux = ScriptedTransport(snapshot: Self.tmuxSnapshot)
        let snapshotGate = ScriptedTransportCallGate()
        await herdr.gateNextSnapshot(using: snapshotGate)
        let calls = Calls()
        let (cache, directory) = makeCache(presence: Self.dual, verifiedAt: Date(), for: host)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(
            herdr: herdr, tmux: tmux, calls: calls, presence: Self.dual, inventoryCache: cache)
        defer { store.setHosts([]) }
        store.setHosts([host])
        await store.resume()
        await snapshotGate.waitForEntry()
        try await Task.sleep(for: .milliseconds(30))
        #expect(store.presentBackends(on: host.id) == [.herdr, .tmux])
        #expect(calls.connects(.tmux) == 0)

        await snapshotGate.open()
        try await waitUntil("tmux should connect once herdr verified") {
            calls.connects(.tmux) == 1
                && store.scopeStatuses[ConsoleScope(hostID: host.id, backend: .tmux)] == .connected
        }
    }

    // MARK: Helpers

    private final class Flag: Sendable {
        private let state = Mutex(false)
        var isSet: Bool { state.withLock { $0 } }
        func set() { state.withLock { $0 = true } }
    }
}
