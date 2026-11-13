import Foundation
import Synchronization
import Testing

@testable import Waycar

/// A Host running herdr and tmux (ADR 0026, design §4.1): one projection per
/// backend over scripted transports, both listed in one Console, each
/// reconciling only its own rows, and a Host status that stays herdr's
/// until tmux has sessions of its own.
@MainActor
@Suite("Console dual backend", .timeLimit(.minutes(1)))
struct ConsoleDualBackendTests {
    private static nonisolated let fastPolicy = ReconnectPolicy(
        initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50))
    /// Its plugin is current and Ultimate was probed (none found), so a fresh
    /// cached copy is not asked again (#209).
    private static nonisolated let dual = HostBackendPresence(
        herdr: true, tmuxVersion: "3.4",
        waycarPlugin: .installed(
            WaycarPluginInstall(version: WaycarPluginRequirement.minimumVersion, mode: .herdr)),
        ultimate: [])

    private let herdrAgent = AgentInfo.fixture(paneID: "w1:p1", workspaceID: "w1")
    private let tmuxAgent = AgentInfo.fixture(paneID: "tmux:%1", workspaceID: "tmux:$1")

    private var herdrSnapshot: SessionSnapshot {
        .fixture(
            agents: [herdrAgent], workspaces: [.fixture(workspaceID: "w1", label: "Project")])
    }

    private var tmuxSnapshot: SessionSnapshot {
        .fixture(
            agents: [tmuxAgent], workspaces: [.fixture(workspaceID: "tmux:$1", label: "work")])
    }

    @MainActor
    private struct Fixture {
        let store: ConsoleStore
        let host: Host
        let herdr: ScriptedTransport
        let core: ScriptedTransport
        let tmux: ScriptedTransport
        let closed: ClosedSessionsStore
        let calls: Calls

        var herdrScope: ConsoleScope { ConsoleScope(hostID: host.id, backend: .herdr) }
        var coreScope: ConsoleScope { ConsoleScope(hostID: host.id, backend: .core) }
        var tmuxScope: ConsoleScope { ConsoleScope(hostID: host.id, backend: .tmux) }

        func id(_ paneID: String) -> ConsoleAgent.ID {
            ConsoleAgent.ID(hostID: host.id, paneID: paneID)
        }

        func row(_ paneID: String) -> ConsoleAgent? {
            store.agents.first { $0.id == id(paneID) }
        }
    }

    /// What the store asked the fixture for: the backends its session
    /// factory built, each session's connect attempts, and detections run.
    private final class Calls: Sendable {
        private struct State {
            var sessionsMade: [HostBackend] = []
            var connects: [HostBackend] = []
            var detections = 0
        }
        private let state = Mutex(State())

        var sessionsMade: [HostBackend] { state.withLock { $0.sessionsMade } }
        var detections: Int { state.withLock { $0.detections } }
        func connects(_ backend: HostBackend) -> Int {
            state.withLock { $0.connects.filter { $0 == backend }.count }
        }
        func madeSession(_ backend: HostBackend) { state.withLock { $0.sessionsMade.append(backend) } }
        func connected(_ backend: HostBackend) { state.withLock { $0.connects.append(backend) } }
        func detected() { state.withLock { $0.detections += 1 } }
    }

    /// A store whose session factory serves each backend its own scripted
    /// transport, or fails its connect with `failures[backend]`, and whose
    /// detection reports `presence` (or runs `detect` instead). Every store
    /// is isolated from `UserDefaults.standard`.
    private func makeFixture(
        herdr: ScriptedTransport? = nil,
        core: ScriptedTransport? = nil,
        tmux: ScriptedTransport? = nil,
        presence: HostBackendPresence = Self.dual,
        detect: (@Sendable (Host) async throws -> HostBackendPresence)? = nil,
        failures: [HostBackend: TransportError] = [:],
        hidingTmux: Bool = false,
        host: Host = .fixture(),
        inventoryCache: ConsoleInventoryCache? = nil
    ) -> Fixture {
        let herdrTransport = herdr ?? ScriptedTransport(snapshot: herdrSnapshot)
        let coreTransport = core ?? ScriptedTransport(snapshot: Self.coreSnapshot)
        let tmuxTransport = tmux ?? ScriptedTransport(snapshot: tmuxSnapshot)
        let suite = "console-dual-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        let preferences = HostBackendPreferences(defaults: defaults)
        if hidingTmux { preferences.setShowsTmux(false, for: host.id) }
        let closed = ClosedSessionsStore()
        let calls = Calls()
        let detector = detect ?? { _ in presence }
        let store = ConsoleStore(
            snapshotRetryDelay: .milliseconds(10),
            pins: PinnedAgentsStore(defaults: defaults),
            unread: UnreadAgentsStore(defaults: defaults),
            closedSessions: closed,
            chatMode: ChatModeStore(defaults: defaults),
            rowLayouts: AgentRowLayoutStore(defaults: defaults),
            backendPreferences: preferences,
            inventoryCache: inventoryCache,
            makeSession: { _, backend, subscriptions in
                calls.madeSession(backend)
                return EventsSession(
                    subscriptions: subscriptions,
                    connect: {
                        calls.connected(backend)
                        if let failure = failures[backend] { throw failure }
                        switch backend {
                        case .herdr: return herdrTransport
                        case .core: return coreTransport
                        case .tmux: return tmuxTransport
                        case .zellij, .ultimate, .codex, .opencode: throw TransportError.cancelled
                        }
                    },
                    reconnectPolicy: Self.fastPolicy,
                    keepalive: nil)
            },
            detectBackends: { host in
                defer { calls.detected() }
                return try await detector(host)
            })
        return Fixture(
            store: store, host: host, herdr: herdrTransport, core: coreTransport,
            tmux: tmuxTransport,
            closed: closed, calls: calls)
    }

    private final class Flag: Sendable {
        private let state = Mutex(false)
        var isSet: Bool { state.withLock { $0 } }
        func set() { state.withLock { $0 = true } }
    }

    /// Waits until the store has recorded `presence` as the Host's detected
    /// backends. The store reconciles its projections in the same main-actor
    /// turn it records a new presence, so the projections are final then.
    private func waitForDetectedPresence(
        _ fixture: Fixture, _ presence: HostBackendPresence
    ) async throws {
        try await waitUntil { fixture.store.backendPresence(on: fixture.host.id) == presence }
    }

    private func start(_ fixture: Fixture) async {
        fixture.store.setHosts([fixture.host])
        await fixture.store.resume()
    }

    /// Both projections verified their rows.
    private func waitForBothVerified(_ fixture: Fixture) async throws {
        try await waitUntil {
            fixture.row(herdrAgent.paneID) != nil && fixture.row(tmuxAgent.paneID) != nil
                && fixture.store.scopeStatuses[fixture.herdrScope] == .connected
                && fixture.store.scopeStatuses[fixture.tmuxScope] == .connected
                && fixture.store.scopesAwaitingSnapshot.isEmpty
        }
    }

    /// Serves `snapshot` on the transport's next resync and triggers one.
    private func resync(_ transport: ScriptedTransport, to snapshot: SessionSnapshot) async {
        await transport.setSnapshot(snapshot)
        #expect(
            await transport.emit(
                HerdrEvent(kind: GlobalEventKind.paneExited.kind, data: .object([:]))))
    }

    @Test func aDualHostListsBothBackendsRowsStampedWithTheirBackend() async throws {
        let fixture = makeFixture()
        defer { fixture.store.setHosts([]) }
        await start(fixture)
        try await waitForBothVerified(fixture)

        #expect(fixture.store.presentBackends(on: fixture.host.id) == [.herdr, .tmux])
        #expect(fixture.store.backendPresence(on: fixture.host.id) == Self.dual)
        #expect(fixture.row(herdrAgent.paneID)?.backend == .herdr)
        #expect(fixture.row(tmuxAgent.paneID)?.backend == .tmux)
        #expect(
            fixture.store.workspaces(for: fixture.host.id).map { [$0.id, $0.backend.rawValue] }
                == [["w1", "herdr"], ["tmux:$1", "tmux"]])
        #expect(fixture.store.hostStatuses[fixture.host.id] == .connected)
        // Both rows are banner and Live Activity fact once both verified.
        #expect(fixture.store.verifiedAgents.count == 2)
    }

    @Test func aFailingTmuxLeavesTheHostConnectedAndShowsItsOwnFailure() async throws {
        let fixture = makeFixture(failures: [.tmux: .tmuxNotInstalled])
        defer { fixture.store.setHosts([]) }
        await start(fixture)

        try await waitUntil {
            fixture.store.scopeStatuses[fixture.tmuxScope] == .failed(.tmuxNotInstalled)
                && fixture.store.hostStatuses[fixture.host.id] == .connected
                && fixture.row(herdrAgent.paneID) != nil
        }
        #expect(fixture.store.scopeStandingFailures[fixture.tmuxScope] == .tmuxNotInstalled)
        #expect(fixture.store.hostStandingFailures[fixture.host.id] == nil)
        // A failed projection is never ended for failing.
        #expect(fixture.store.presentBackends(on: fixture.host.id) == [.herdr, .tmux])
    }

    // MARK: Hosts with no usable backend (WAY-338)

    @Test func aHostDetectedWithNeitherBackendNamesTheGapBehindItsFailure() async throws {
        let fixture = makeFixture(
            presence: HostBackendPresence(herdr: false, tmuxVersion: nil),
            failures: [.herdr: .socketNotFound(path: "~/.config/herdr/herdr.sock")])
        defer { fixture.store.setHosts([]) }
        await start(fixture)

        try await waitUntil {
            fixture.store.backendPresence(on: fixture.host.id)
                == HostBackendPresence(herdr: false, tmuxVersion: nil)
                && fixture.store.backendGapBehindFailure(on: fixture.host.id) == .noBackend
        }
    }

    @Test func anUnreachableHostKeepsItsRealCauseWhateverItsPresenceSays() async throws {
        let fixture = makeFixture(
            presence: HostBackendPresence(herdr: false, tmuxVersion: nil),
            failures: [.herdr: .sshUnreachable(detail: "no route")])
        defer { fixture.store.setHosts([]) }
        await start(fixture)
        fixture.store.recordDetectedPresence(
            HostBackendPresence(herdr: false, tmuxVersion: nil), on: fixture.host.id)

        try await waitUntil {
            if case .reconnecting = fixture.store.hostStatuses[fixture.host.id] { true } else { false }
        }
        #expect(fixture.store.backendGapBehindFailure(on: fixture.host.id) == nil)
    }

    @Test func aHostWithHerdrInstalledHasNoGapWhenItsServerIsNotRunning() async throws {
        let fixture = makeFixture(
            presence: HostBackendPresence(herdr: true, tmuxVersion: nil),
            failures: [.herdr: .socketNotFound(path: "~/.config/herdr/herdr.sock")])
        defer { fixture.store.setHosts([]) }
        await start(fixture)

        try await waitUntil {
            if case .failed = fixture.store.hostStatuses[fixture.host.id] { true } else { false }
        }
        #expect(fixture.store.backendGapBehindFailure(on: fixture.host.id) == nil)
    }

    private static let noBackends = HostBackendPresence(herdr: false, tmuxVersion: nil)

    private func ended(
        _ result: BackendInstallResult, target: BackendInstallTarget = .tmux(.aptGet)
    ) -> BackendInstallCenter.Outcome {
        BackendInstallCenter.Outcome(plan: BackendInstallPlan(target: target), result: result)
    }

    /// A Host with neither backend, as the Console detected it.
    private func startedWithNoBackend() async throws -> Fixture {
        let fixture = makeFixture(
            presence: Self.noBackends,
            failures: [.herdr: .socketNotFound(path: "~/.config/herdr/herdr.sock")])
        await start(fixture)
        try await waitForDetectedPresence(fixture, Self.noBackends)
        return fixture
    }

    @Test func aTmuxThatLandedUnderTheFloorBecomesTheHostsTmuxSoThePanelOffersHerdr() async throws {
        let fixture = try await startedWithNoBackend()
        defer { fixture.store.setHosts([]) }

        fixture.store.backendInstallEnded(
            on: fixture.host.id, outcome: ended(.failed(.tmuxTooOld(found: "3.0"))))

        let presence = fixture.store.backendPresence(on: fixture.host.id)
        #expect(presence == HostBackendPresence(herdr: false, tmuxVersion: "3.0"))
        #expect(HostBackendGap(presence: presence) == .tmuxTooOld(found: "3.0"))
    }

    @Test func anInstallThatFoundHerdrIsRecordedAsTheHostsBackend() async throws {
        let fixture = try await startedWithNoBackend()
        defer { fixture.store.setHosts([]) }
        let found = HostBackendPresence(herdr: true, tmuxVersion: nil)

        fixture.store.backendInstallEnded(
            on: fixture.host.id, outcome: ended(.found(found), target: .herdr))

        #expect(fixture.store.backendPresence(on: fixture.host.id) == found)
        #expect(HostBackendGap(presence: fixture.store.backendPresence(on: fixture.host.id)) == nil)
    }

    @Test func anInstallThatFailedOrWentUnconfirmedLeavesWhatTheConsoleKnows() async throws {
        let fixture = try await startedWithNoBackend()
        defer { fixture.store.setHosts([]) }

        for result in [
            BackendInstallResult.failed(.needsAdmin),
            .failed(.cannotReachInstaller),
            .hostUnreachable(.channelFailed(detail: "The connection ended.")),
        ] {
            fixture.store.backendInstallEnded(on: fixture.host.id, outcome: ended(result))
            #expect(fixture.store.backendPresence(on: fixture.host.id) == Self.noBackends)
        }
    }

    @Test func aFailedHerdrWithTmuxSessionsLeavesTheHostConnected() async throws {
        let fixture = makeFixture(failures: [.herdr: .herdrBinaryNotFound])
        defer { fixture.store.setHosts([]) }
        await start(fixture)

        try await waitUntil {
            fixture.store.scopeStatuses[fixture.herdrScope] == .failed(.herdrBinaryNotFound)
                && fixture.store.scopeStatuses[fixture.tmuxScope] == .connected
                && fixture.row(tmuxAgent.paneID) != nil
        }
        #expect(fixture.store.hostStatuses[fixture.host.id] == .connected)
        #expect(!fixture.store.hostsAwaitingSnapshot.contains(fixture.host.id))
        #expect(
            fixture.store.scopeStandingFailures[fixture.herdrScope] == .herdrBinaryNotFound)
        // The detection that failure asked for still finds herdr installed,
        // so its projection stays and keeps presenting its own failure.
        try await waitForDetectedPresence(fixture, Self.dual)
        #expect(fixture.store.presentBackends(on: fixture.host.id) == [.herdr, .tmux])
    }

    @Test func aFailedHerdrWithNoTmuxSessionsShowsHerdrsFailure() async throws {
        let fixture = makeFixture(
            tmux: ScriptedTransport(snapshot: .fixture()),
            failures: [.herdr: .herdrBinaryNotFound])
        defer { fixture.store.setHosts([]) }
        await start(fixture)

        try await waitUntil {
            fixture.store.scopeStatuses[fixture.tmuxScope] == .connected
                && !fixture.store.scopesAwaitingSnapshot.contains(fixture.tmuxScope)
                && fixture.store.hostStatuses[fixture.host.id] == .failed(.herdrBinaryNotFound)
        }
        #expect(fixture.store.hostStandingFailures[fixture.host.id] == .herdrBinaryNotFound)
    }

    @Test func aTmuxSnapshotDroppingATmuxAgentRecordsOnlyThatClosure() async throws {
        let fixture = makeFixture()
        defer { fixture.store.setHosts([]) }
        await start(fixture)
        try await waitForBothVerified(fixture)
        let herdrRow = try #require(fixture.row(herdrAgent.paneID))
        let tmuxRow = try #require(fixture.row(tmuxAgent.paneID))
        fixture.store.markUnread(herdrRow)
        fixture.store.markUnread(tmuxRow)

        await resync(fixture.tmux, to: .fixture())

        try await waitUntil { fixture.closed.sessions.count == 1 }
        let recorded = try #require(fixture.closed.sessions.first)
        #expect(recorded.backend == .tmux)
        #expect(recorded.workspaceID == "tmux:$1")
        #expect(fixture.row(tmuxAgent.paneID) == nil)
        // The herdr row and its Unread Mark are herdr's projection's alone.
        #expect(fixture.row(herdrAgent.paneID) != nil)
        #expect(fixture.store.unread.isMarkedUnread(fixture.id(herdrAgent.paneID)))
        #expect(!fixture.store.unread.isMarkedUnread(fixture.id(tmuxAgent.paneID)))
        // Later herdr snapshots leave the tmux record alone too.
        let herdrFetches = await fixture.herdr.snapshotFetchCount
        await resync(fixture.herdr, to: herdrSnapshot)
        try await waitUntil { await fixture.herdr.snapshotFetchCount > herdrFetches }
        try await waitUntil { fixture.store.scopesAwaitingSnapshot.isEmpty }
        await Task.yield()
        #expect(fixture.closed.sessions == [recorded])
    }

    @Test func hidingTmuxEndsItsProjectionRecordingNothing() async throws {
        let config = Data(#"{"debounce_ms":500}"#.utf8)
        let herdr = ScriptedTransport(snapshot: herdrSnapshot)
        await herdr.setNotificationConfig(config)
        // Detections after `upgraded` flips report a distinct presence, so
        // the store's recording it proves that later detection was handled.
        let upgraded = Flag()
        let laterPresence = HostBackendPresence(herdr: true, tmuxVersion: "3.5a")
        let fixture = makeFixture(
            herdr: herdr,
            detect: { _ in upgraded.isSet ? laterPresence : Self.dual })
        defer { fixture.store.setHosts([]) }
        await start(fixture)
        try await waitForBothVerified(fixture)
        let tmuxRow = try #require(fixture.row(tmuxAgent.paneID))
        fixture.store.markUnread(tmuxRow)

        await fixture.store.setShowsTmux(false, for: fixture.host.id)

        #expect(!fixture.store.backendPreferences.showsTmux(for: fixture.host.id))
        #expect(fixture.store.presentBackends(on: fixture.host.id) == [.herdr])
        #expect(fixture.row(tmuxAgent.paneID) == nil)
        #expect(fixture.store.workspaces(for: fixture.host.id).map(\.id) == ["w1"])
        #expect(fixture.closed.sessions.isEmpty)
        #expect(fixture.store.unread.isMarkedUnread(fixture.id(tmuxAgent.paneID)))
        let written = try #require(await herdr.notificationConfig)
        let fields = try JSONDecoder().decode([String: JSONValue].self, from: written)
        #expect(fields == ["debounce_ms": .number(500), "tmux_enabled": .bool(false)])

        // An activation's detection still finds tmux, and keeps it hidden.
        // Activations ask again only once the detected presence is stale.
        upgraded.set()
        let stale = Date().addingTimeInterval(ConsoleStore.backendPresenceFreshness + 1)
        fixture.store.now = { stale }
        await fixture.store.reactivate()
        try await waitForDetectedPresence(fixture, laterPresence)
        #expect(fixture.store.presentBackends(on: fixture.host.id) == [.herdr])
    }

    @Test func showingTmuxStartsItsProjectionAndTellsTheHost() async throws {
        let fixture = makeFixture(hidingTmux: true)
        defer { fixture.store.setHosts([]) }
        await start(fixture)
        try await waitUntil {
            fixture.row(herdrAgent.paneID) != nil
                && fixture.store.scopeStatuses[fixture.herdrScope] == .connected
        }
        try await waitForDetectedPresence(fixture, Self.dual)
        #expect(fixture.store.presentBackends(on: fixture.host.id) == [.herdr])
        #expect(fixture.row(tmuxAgent.paneID) == nil)

        await fixture.store.setShowsTmux(true, for: fixture.host.id)

        #expect(fixture.store.backendPreferences.showsTmux(for: fixture.host.id))
        try await waitForBothVerified(fixture)
        #expect(fixture.store.presentBackends(on: fixture.host.id) == [.herdr, .tmux])
        let written = try #require(await fixture.herdr.notificationConfig)
        let fields = try JSONDecoder().decode([String: JSONValue].self, from: written)
        #expect(fields == ["tmux_enabled": .bool(true)])
    }

    @Test func launchesRouteByWorkspaceOwnershipThenExplicitBackendThenDefault() async throws {
        let fixture = makeFixture()
        defer { fixture.store.setHosts([]) }
        await start(fixture)
        try await waitForBothVerified(fixture)
        let hostID = fixture.host.id

        try await fixture.store.startAgent(
            AgentLaunchRequest(kind: "claude", name: "a", arguments: [], workspaceID: "tmux:$1"),
            on: hostID)
        try await fixture.store.startAgent(
            AgentLaunchRequest(kind: "claude", name: "b", arguments: [], workspaceID: "w1"),
            on: hostID)
        #expect(await fixture.tmux.agentStarts.map(\.name) == ["a"])
        #expect(await fixture.herdr.agentStarts.map(\.name) == ["b"])

        // No Workspace: the explicit backend, else the Host's default.
        let directory = NewWorkspaceSpec(directory: "/work/new", label: nil)
        try await fixture.store.startAgent(
            AgentLaunchRequest(kind: "claude", name: "c", arguments: []),
            at: .newWorkspace(directory), on: hostID, backend: .tmux)
        try await fixture.store.startAgentInNewWorkspace(
            AgentLaunchRequest(kind: "claude", name: "d", arguments: []),
            workspace: directory, on: hostID)
        #expect(await fixture.tmux.workspaceStarts.map { $0.request.name } == ["c"])
        #expect(await fixture.herdr.workspaceStarts.map { $0.request.name } == ["d"])

        #expect(fixture.store.defaultNewAgentBackend(on: hostID) == .herdr)
        try await fixture.store.startAgentInNewWorkspace(
            AgentLaunchRequest(kind: "claude", name: "e", arguments: []),
            workspace: directory, on: hostID)
        #expect(await fixture.tmux.workspaceStarts.map { $0.request.name } == ["c"])
        #expect(await fixture.herdr.workspaceStarts.map { $0.request.name } == ["d", "e"])
    }

    @Test func detectionLeavesATmuxOnlyHostWithOnlyATmuxProjection() async throws {
        let fixture = makeFixture(presence: HostBackendPresence(herdr: false, tmuxVersion: "3.4"))
        defer { fixture.store.setHosts([]) }
        await start(fixture)

        try await waitUntil {
            fixture.store.presentBackends(on: fixture.host.id) == [.tmux]
                && fixture.row(tmuxAgent.paneID) != nil
                && fixture.store.hostStatuses[fixture.host.id] == .connected
        }
        #expect(fixture.row(herdrAgent.paneID) == nil)
        #expect(fixture.store.scopeStatuses[fixture.herdrScope] == nil)
        // The herdr projection ended for its backend's absence: nothing closed.
        #expect(fixture.closed.sessions.isEmpty)
        #expect(fixture.store.defaultNewAgentBackend(on: fixture.host.id) == .tmux)
        #expect(
            fixture.store.backendPresence(on: fixture.host.id)
                == HostBackendPresence(herdr: false, tmuxVersion: "3.4"))
    }

    @Test func aFailedHerdrBesideServingTmuxGetsItsOwnIssueWhoseRetryRestartsOnlyHerdr() async throws {
        let fixture = makeFixture(failures: [.herdr: .herdrBinaryNotFound])
        defer { fixture.store.setHosts([]) }
        await start(fixture)
        try await waitUntil {
            fixture.store.scopeStatuses[fixture.herdrScope] == .failed(.herdrBinaryNotFound)
                && fixture.store.hostStatuses[fixture.host.id] == .connected
                && fixture.row(tmuxAgent.paneID) != nil
        }

        let failed = fixture.store.failedSecondaryScopes(on: fixture.host.id)
        #expect(failed.map { $0.scope } == [fixture.herdrScope])
        #expect(failed.map { $0.failure } == [.herdrBinaryNotFound])
        let issue = try #require(failed.first.map {
            ConsoleHostStatusPresentation(host: fixture.host, failedScope: $0.scope, failure: $0.failure)
        })
        #expect(issue.hostID == fixture.host.id)
        #expect(issue.retryScope?.backend == .herdr)
        #expect(issue.retryScope == fixture.herdrScope)
        // The Host's own row stays quiet: it presents the serving tmux.
        #expect(
            ConsoleHostStatusPresentation(
                host: fixture.host, status: fixture.store.hostStatuses[fixture.host.id],
                syncError: nil) == nil)

        let tmuxGeneration = fixture.store.scopeConnectionGenerations[fixture.tmuxScope]
        let herdrConnects = fixture.calls.connects(.herdr)
        let tmuxConnects = fixture.calls.connects(.tmux)
        let retry = try #require(issue.retryScope)
        await fixture.store.retry(retry)

        // herdr dials again (and fails again); tmux is not redialled.
        try await waitUntil {
            fixture.calls.connects(.herdr) > herdrConnects
                && fixture.store.scopeStatuses[fixture.herdrScope] == .failed(.herdrBinaryNotFound)
        }
        #expect(fixture.calls.connects(.tmux) == tmuxConnects)
        #expect(fixture.store.scopeConnectionGenerations[fixture.tmuxScope] == tmuxGeneration)
        #expect(fixture.store.scopeStatuses[fixture.tmuxScope] == .connected)
    }

    @Test func hostExecFeaturesUseTmuxWhenHerdrFailedAtConnect() async throws {
        let fixture = makeFixture(failures: [.herdr: .herdrBinaryNotFound])
        defer { fixture.store.setHosts([]) }
        await fixture.tmux.setAvailableAgentKinds([.codex])
        await start(fixture)
        try await waitUntil {
            fixture.store.scopeStatuses[fixture.herdrScope] == .failed(.herdrBinaryNotFound)
                && fixture.store.scopeStatuses[fixture.tmuxScope] == .connected
        }

        #expect(try await fixture.store.availableAgentKinds(on: fixture.host.id) == [.codex])
        #expect(await fixture.tmux.agentDiscoveryCount == 1)
        #expect(await fixture.herdr.agentDiscoveryCount == 0)
        #expect(
            fixture.store.hostConnectionGenerations[fixture.host.id]
                == fixture.store.scopeConnectionGenerations[fixture.tmuxScope])
    }

    @Test func aSessionlessTmuxOnlyHostOffersStartSessionReachingTmux() async throws {
        let fixture = makeFixture(
            tmux: ScriptedTransport(snapshot: .fixture()),
            presence: HostBackendPresence(herdr: false, tmuxVersion: "3.4"))
        defer { fixture.store.setHosts([]) }
        await start(fixture)
        try await waitUntil { fixture.store.needsTmuxSession(on: fixture.host.id) }

        try await fixture.store.startTmuxSession(on: fixture.host.id)

        #expect(await fixture.tmux.mainSessionStarts == 1)
        try await waitUntil { !fixture.store.needsTmuxSession(on: fixture.host.id) }
        #expect(fixture.store.workspaces(for: fixture.host.id).map(\.id) == ["tmux:$9"])
    }

    /// Start Session per Host: a failure's text stays on its Host, the next
    /// start clears it as it begins, and a tap while one is in flight starts
    /// nothing.
    @Test func startSessionKeepsOneStartInFlightAndClearsItsErrorOnRetry() async throws {
        let fixture = makeFixture(
            tmux: ScriptedTransport(snapshot: .fixture()),
            presence: HostBackendPresence(herdr: false, tmuxVersion: "3.4"))
        defer { fixture.store.setHosts([]) }
        await start(fixture)
        try await waitUntil { fixture.store.needsTmuxSession(on: fixture.host.id) }
        let hostID = fixture.host.id
        let starter = TmuxSessionStarter()

        await starter.start(on: hostID) { _ in throw TransportError.timedOut }
        #expect(starter.error(on: hostID) != nil)
        #expect(starter.error(on: UUID()) == nil)
        #expect(!starter.isStarting(on: hostID))

        let (released, release) = AsyncStream<Void>.makeStream()
        let retry = Task {
            await starter.start(on: hostID) { id in
                for await _ in released { break }
                try await fixture.store.startTmuxSession(on: id)
            }
        }
        try await waitUntil { starter.isStarting(on: hostID) }
        #expect(starter.error(on: hostID) == nil)
        await starter.start(on: hostID) { try await fixture.store.startTmuxSession(on: $0) }
        release.yield()
        release.finish()
        await retry.value
        #expect(!starter.isStarting(on: hostID))
        #expect(starter.error(on: hostID) == nil)
        #expect(await fixture.tmux.mainSessionStarts == 1)
    }

    @Test func aDualHostWithEmptyTmuxDoesNotOfferStartSession() async throws {
        let fixture = makeFixture(tmux: ScriptedTransport(snapshot: .fixture()))
        defer { fixture.store.setHosts([]) }
        await start(fixture)
        try await waitUntil {
            fixture.store.scopeStatuses[fixture.tmuxScope] == .connected
                && fixture.store.scopesAwaitingSnapshot.isEmpty
        }
        #expect(!fixture.store.needsTmuxSession(on: fixture.host.id))
    }

    @Test func recencyComparesStateChangeSeqOnlyWithinOneBackend() {
        let host = Host.fixture()
        func row(_ paneID: String, seq: Int, backend: HostBackend) -> ConsoleAgent {
            ConsoleAgent(
                hostID: host.id, hostName: host.displayName,
                agent: Agent(.fixture(paneID: paneID, status: .idle, stateChangeSeq: seq)),
                workspaceLabel: nil, repositoryCheckout: nil, backend: backend)
        }
        // tmux's seq is wall-clock nanoseconds, always far above herdr's.
        let rows = [
            row("tmux:%1", seq: 1_700_000_000_000_000_000, backend: .tmux),
            row("w1:p1", seq: 3, backend: .herdr),
            row("tmux:%2", seq: 1_700_000_000_000_000_500, backend: .tmux),
            row("w1:p2", seq: 7, backend: .herdr),
        ]
        #expect(
            rows.consoleSorted().map(\.agent.paneID)
                == ["w1:p2", "w1:p1", "tmux:%2", "tmux:%1"])
    }

    @Test func rowActionsReachOnlyTheRowsOwnBackend() async throws {
        // Focus is sent only for a Done Agent (it acknowledges the Done);
        // any other status ends the call with CancellationError by design.
        let fixture = makeFixture(
            herdr: ScriptedTransport(snapshot: .fixture(
                agents: [.fixture(paneID: herdrAgent.paneID, status: .done, workspaceID: "w1")],
                workspaces: [.fixture(workspaceID: "w1", label: "Project")])),
            tmux: ScriptedTransport(snapshot: .fixture(
                agents: [.fixture(paneID: tmuxAgent.paneID, status: .done, workspaceID: "tmux:$1")],
                workspaces: [.fixture(workspaceID: "tmux:$1", label: "work")])))
        defer { fixture.store.setHosts([]) }
        await start(fixture)
        try await waitForBothVerified(fixture)
        let hostID = fixture.host.id

        try await fixture.store.focusAgent(tmuxAgent.paneID, on: hostID)
        #expect(await fixture.tmux.agentFocuses.map(\.target) == [tmuxAgent.paneID])
        #expect(await fixture.herdr.agentFocuses.isEmpty)
        try await fixture.store.focusAgent(herdrAgent.paneID, on: hostID)
        #expect(await fixture.herdr.agentFocuses.map(\.target) == [herdrAgent.paneID])
        #expect(await fixture.tmux.agentFocuses.count == 1)

        _ = try await fixture.store.promptAgent(
            AgentPromptParams(target: tmuxAgent.paneID, text: "hi"), on: hostID)
        #expect(await fixture.tmux.agentPromptParams.map(\.target) == [tmuxAgent.paneID])
        #expect(await fixture.herdr.agentPromptParams.isEmpty)
        _ = try await fixture.store.promptAgent(
            AgentPromptParams(target: herdrAgent.paneID, text: "hi"), on: hostID)
        #expect(await fixture.herdr.agentPromptParams.map(\.target) == [herdrAgent.paneID])
        #expect(await fixture.tmux.agentPromptParams.count == 1)

        try await fixture.store.closePane(of: try #require(fixture.row(tmuxAgent.paneID)))
        #expect(await fixture.tmux.closedPanes.map(\.paneID) == [tmuxAgent.paneID])
        #expect(await fixture.herdr.closedPanes.isEmpty)
        try await fixture.store.closePane(of: try #require(fixture.row(herdrAgent.paneID)))
        #expect(await fixture.herdr.closedPanes.map(\.paneID) == [herdrAgent.paneID])
        #expect(await fixture.tmux.closedPanes.count == 1)
    }

    @Test func hidingTmuxEvictsOnlyTmuxTerminals() async throws {
        let fixture = makeFixture()
        defer { fixture.store.setHosts([]) }
        await start(fixture)
        try await waitForBothVerified(fixture)
        let store = fixture.store
        for paneID in [herdrAgent.paneID, tmuxAgent.paneID] {
            let row = try #require(fixture.row(paneID))
            _ = store.agentTerminals.acquire(
                agent: row, console: store, composer: store.composerStore(for: row),
                ownerID: UUID())
        }
        #expect(store.agentTerminals.entries.count == 2)

        await store.setShowsTmux(false, for: fixture.host.id)

        try await waitUntil { store.agentTerminals.entries[fixture.id(tmuxAgent.paneID)] == nil }
        #expect(store.agentTerminals.entries[fixture.id(herdrAgent.paneID)]?.backend == .herdr)
        #expect(store.agentTerminals.entries.count == 1)
    }

    struct HerdrOnlyDetection: Sendable, CustomTestStringConvertible {
        let name: String
        let detect: @Sendable (Host) async throws -> HostBackendPresence
        var testDescription: String { name }
    }

    nonisolated static let herdrOnlyDetections = [
        HerdrOnlyDetection(name: "herdr only") { _ in .herdrOnly },
        HerdrOnlyDetection(name: "tmux too old") { _ in
            HostBackendPresence(herdr: true, tmuxVersion: "2.7")
        },
        HerdrOnlyDetection(name: "detection fails") { _ in
            throw TransportError.sshUnreachable(detail: "no detection")
        },
    ]

    @Test(arguments: herdrOnlyDetections)
    func aHostWithoutUsableTmuxRunsOnlyHerdr(_ detection: HerdrOnlyDetection) async throws {
        let fixture = makeFixture(detect: detection.detect)
        defer { fixture.store.setHosts([]) }
        await start(fixture)
        try await waitUntil {
            fixture.row(herdrAgent.paneID) != nil
                && fixture.store.scopeStatuses[fixture.herdrScope] == .connected
                && fixture.store.scopesAwaitingSnapshot.isEmpty
        }
        try await waitUntil { fixture.calls.detections >= 1 }
        await Task.yield()

        #expect(fixture.calls.sessionsMade == [.herdr])
        #expect(fixture.store.presentBackends(on: fixture.host.id) == [.herdr])
        #expect(fixture.store.verifiedAgents.map(\.id) == [fixture.id(herdrAgent.paneID)])
        #expect(fixture.row(tmuxAgent.paneID) == nil)
    }
}

extension ConsoleDualBackendTests {
    @Test func aColdLaunchedDualHostSeedsBothProjectionsFromCacheBeforeDetection() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "console-dual-cache-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = Host.fixture()
        let writer = ConsoleInventoryCache(directory: directory)
        writer.save(.init(snapshot: herdrSnapshot, sidebarLayout: nil), for: host, backend: .herdr)
        writer.save(.init(snapshot: tmuxSnapshot, sidebarLayout: nil), for: host, backend: .tmux)
        writer.savePresence(.init(presence: Self.dual, verifiedAt: nil), for: host)
        writer.flush()

        // Detection does not answer and neither backend connects: anything
        // listed comes from the cache.
        let fixture = makeFixture(
            detect: { _ in
                try await Task.sleep(for: .seconds(30))
                return .herdrOnly
            },
            failures: [
                .herdr: .sshUnreachable(detail: "offline"),
                .tmux: .sshUnreachable(detail: "offline"),
            ],
            host: host,
            inventoryCache: ConsoleInventoryCache(directory: directory))
        defer { fixture.store.setHosts([]) }
        await start(fixture)

        try await waitUntil {
            fixture.row(herdrAgent.paneID) != nil && fixture.row(tmuxAgent.paneID) != nil
        }
        #expect(fixture.store.presentBackends(on: host.id) == [.herdr, .tmux])
        #expect(Set(fixture.calls.sessionsMade) == [.herdr, .tmux])
        #expect(fixture.row(herdrAgent.paneID)?.backend == .herdr)
        #expect(fixture.row(tmuxAgent.paneID)?.backend == .tmux)
        #expect(fixture.calls.detections == 0)
    }

    /// Hidden before its deferred start (#105): a dual Host's tmux waits for
    /// herdr's first snapshot, and hiding it meanwhile ends its projection —
    /// its last-known rows leave unrecorded — and it never connects.
    @Test func hidingTmuxBeforeItsDeferredStartEndsItWithoutConnecting() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "console-dual-hide-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = Host.fixture()
        let writer = ConsoleInventoryCache(directory: directory)
        writer.save(.init(snapshot: herdrSnapshot, sidebarLayout: nil), for: host, backend: .herdr)
        writer.save(.init(snapshot: tmuxSnapshot, sidebarLayout: nil), for: host, backend: .tmux)
        writer.savePresence(.init(presence: Self.dual, verifiedAt: Date()), for: host)
        writer.flush()
        let herdr = ScriptedTransport(snapshot: herdrSnapshot)
        let herdrSnapshotGate = ScriptedTransportCallGate()
        await herdr.gateNextSnapshot(using: herdrSnapshotGate)
        let fixture = makeFixture(
            herdr: herdr, host: host, inventoryCache: ConsoleInventoryCache(directory: directory))
        defer { fixture.store.setHosts([]) }
        await start(fixture)
        await herdrSnapshotGate.waitForEntry()
        #expect(fixture.row(tmuxAgent.paneID) != nil)
        #expect(fixture.calls.connects(.tmux) == 0)

        await fixture.store.setShowsTmux(false, for: host.id)
        #expect(fixture.store.presentBackends(on: host.id) == [.herdr])
        #expect(fixture.row(tmuxAgent.paneID) == nil)

        await herdrSnapshotGate.open()
        try await waitUntil {
            fixture.store.scopeStatuses[fixture.herdrScope] == .connected
                && fixture.store.scopesAwaitingSnapshot.isEmpty
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(fixture.calls.connects(.tmux) == 0)
        #expect(fixture.closed.sessions.isEmpty)
        #expect(fixture.calls.detections == 0)
    }
}

// MARK: Quick chat's live-snapshot gate

extension ConsoleDualBackendTests {
    /// herdr verified while tmux's snapshot is still in flight: the Host's
    /// lead state already reads live, but tmux's sessions are not known yet.
    @Test func aDualHostHasLiveSnapshotsOnlyOnceTmuxsSnapshotLands() async throws {
        let fixture = makeFixture()
        defer { fixture.store.setHosts([]) }
        let tmuxGate = ScriptedTransportCallGate()
        await fixture.tmux.gateNextSnapshot(using: tmuxGate)
        await start(fixture)
        await tmuxGate.waitForEntry()
        try await waitUntil {
            fixture.store.scopeStatuses[fixture.herdrScope] == .connected
                && !fixture.store.scopesAwaitingSnapshot.contains(fixture.herdrScope)
                && fixture.store.scopeStatuses[fixture.tmuxScope] == .connected
                && fixture.store.scopesAwaitingSnapshot.contains(fixture.tmuxScope)
        }
        #expect(fixture.store.hostStatuses[fixture.host.id] == .connected)
        #expect(!fixture.store.hostsAwaitingSnapshot.contains(fixture.host.id))
        #expect(!fixture.store.hasLiveSnapshots(on: fixture.host.id))

        await tmuxGate.open()
        try await waitUntil { fixture.store.hasLiveSnapshots(on: fixture.host.id) }
    }

    /// A backend that failed lists nothing to wait for.
    @Test func aFailedTmuxDoesNotHoldTheLiveSnapshotGate() async throws {
        let fixture = makeFixture(failures: [.tmux: .tmuxNotInstalled])
        defer { fixture.store.setHosts([]) }
        await start(fixture)
        try await waitUntil {
            fixture.store.scopeStatuses[fixture.tmuxScope] == .failed(.tmuxNotInstalled)
                && fixture.store.hasLiveSnapshots(on: fixture.host.id)
        }
    }
}

// MARK: Chat Mode on a Host running both

extension ConsoleDualBackendTests {
    nonisolated private static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])

    /// claude in tmux's pane tmux:%1, reporting `session`.
    private func tmuxChatAgent(session: String) -> AgentInfo {
        AgentInfo(
            agentStatus: .idle, focused: false, paneID: "tmux:%1", revision: 1,
            tabID: "tmux:$1:t1", terminalID: "term_tmux:%1", workspaceID: "tmux:$1",
            agent: "claude",
            agentSession: AgentSessionInfo(agent: "claude", kind: .id, source: "hook", value: session),
            cwd: "/work/tmux")
    }

    private func snapshotOfTmux(_ agent: AgentInfo) -> SessionSnapshot {
        .fixture(agents: [agent], workspaces: [.fixture(workspaceID: "tmux:$1", label: "work")])
    }

    /// A Chat Marker for `agent` as launched, holding `session` when given.
    private func chatMarker(
        for agent: AgentInfo, session: String? = nil, launchedAt: Date = Date()
    ) -> ChatModeMarker {
        ChatModeMarker(
            paneID: agent.paneID, terminalID: agent.terminalID, kind: "claude", cwd: "/work/tmux",
            session: session.map { ChatModeMarker.Session(kind: "id", value: $0) },
            launchedAt: launchedAt)
    }

    @Test func aTmuxChatAgentsMediaIsReadOverTmuxOnly() async throws {
        let fixture = makeFixture()
        defer { fixture.store.setHosts([]) }
        await fixture.tmux.setChatMediaResponder { _ in Self.png }
        await fixture.tmux.setPreviewFileResponder { _, _ in Self.png }
        await start(fixture)
        try await waitForBothVerified(fixture)
        let agent = try #require(fixture.row(tmuxAgent.paneID))

        _ = try await fixture.store.chatMediaFile(
            for: ChatMedia(
                id: "inline", kind: .image, mime: "image/png",
                source: .inline(transcript: "/t/s.jsonl", offset: 7, pointer: "/p")),
            agent: agent)
        _ = try await fixture.store.chatMediaFile(
            for: ChatMedia(id: "file", kind: .image, mime: "image/png", source: .hostFile(path: "/shots/a.png")),
            agent: agent)

        #expect(
            await fixture.tmux.chatMediaRequests == [
                ChatMediaRequest.line(
                    transcript: "/t/s.jsonl", offset: 7, pointer: "/p",
                    maxBytes: ChatMedia.maximumImageBytes)
            ])
        let tmuxFileReads = await fixture.tmux.previewFileReads
        #expect(tmuxFileReads.map { $0.path } == ["/shots/a.png"])
        #expect(await fixture.herdr.chatMediaRequests.isEmpty)
        #expect(await fixture.herdr.previewFileReads.isEmpty)
    }

    @Test func aClosingTmuxChatDeletesItsMarkerOverTmux() async throws {
        let fixture = makeFixture()
        defer { fixture.store.setHosts([]) }
        let probe = ChatModeMarker(
            paneID: "w9:gone", terminalID: "term_w9:gone", kind: "claude", cwd: "/work/w9",
            session: nil, launchedAt: Date())
        await fixture.herdr.setChatModeMarkers([probe])
        await start(fixture)
        try await waitForBothVerified(fixture)
        try await waitUntil { fixture.store.chatMode.marker(for: fixture.id(probe.paneID)) == probe }
        fixture.store.chatMode.record(chatMarker(for: tmuxAgent), hostID: fixture.host.id)

        await resync(fixture.tmux, to: .fixture())

        try await waitUntil { await fixture.tmux.chatModeMarkerDeletes == [tmuxAgent.paneID] }
        #expect(await fixture.herdr.chatModeMarkerDeletes.isEmpty)
        #expect(fixture.store.chatMode.marker(for: fixture.id(tmuxAgent.paneID)) == nil)
    }

    /// With the herdr plugin installed, the Host's markers are read over
    /// its primary projection (herdr) alone, and a tmux chat Agent's
    /// marker follows its live session over tmux once that read confirmed it.
    @Test func markersAreReadOverThePrimaryAndATmuxChatFollowsOverTmux() async throws {
        let agent = tmuxChatAgent(session: "s-1")
        let fixture = makeFixture(tmux: ScriptedTransport(snapshot: snapshotOfTmux(agent)))
        defer { fixture.store.setHosts([]) }
        let launched = chatMarker(for: agent)
        await fixture.herdr.setChatModeMarkers([launched])
        // tmux verifies only after herdr's read landed, so herdr is the
        // primary projection throughout.
        let tmuxGate = ScriptedTransportCallGate()
        await fixture.tmux.gateNextSnapshot(using: tmuxGate)
        await start(fixture)
        try await waitUntil { fixture.store.chatMode.marker(for: fixture.id(agent.paneID)) == launched }
        await tmuxGate.open()
        try await waitForBothVerified(fixture)

        let followed = chatMarker(for: agent, session: "s-1", launchedAt: launched.launchedAt)
        try await waitUntil { await fixture.tmux.chatModeMarkerWrites == [followed] }
        #expect(fixture.store.chatMode.marker(for: fixture.id(agent.paneID)) == followed)
        #expect(await fixture.herdr.chatModeMarkerReadCount > 0)
        #expect(await fixture.tmux.chatModeMarkerReadCount == 0)
        #expect(await fixture.herdr.chatModeMarkerWrites.isEmpty)
    }

    /// herdr runs without the Waycar herdr plugin (`install.sh --tmux`):
    /// its transport has no marker dir, so the markers are read, confirmed
    /// and written over tmux, and tmux chats still follow.
    @Test func aHerdrWithoutThePluginHandsTheMarkersToTmux() async throws {
        let agent = tmuxChatAgent(session: "s-1")
        let fixture = makeFixture(tmux: ScriptedTransport(snapshot: snapshotOfTmux(agent)))
        defer { fixture.store.setHosts([]) }
        await fixture.herdr.setChatModeMarkerReadFailure(NotificationRegistrationError.pluginNotInstalled)
        await fixture.herdr.setChatModeMarkerWriteFailure(NotificationRegistrationError.pluginNotInstalled)
        let launched = chatMarker(for: agent)
        await fixture.tmux.setChatModeMarkers([launched])
        // herdr, the primary projection, answers first; tmux verifies after.
        let tmuxGate = ScriptedTransportCallGate()
        await fixture.tmux.gateNextSnapshot(using: tmuxGate)
        await start(fixture)
        try await waitUntil { await fixture.herdr.chatModeMarkerReadCount > 0 }
        await tmuxGate.open()
        try await waitForBothVerified(fixture)

        let followed = chatMarker(for: agent, session: "s-1", launchedAt: launched.launchedAt)
        try await waitUntil { await fixture.tmux.chatModeMarkerWrites == [followed] }
        #expect(await fixture.tmux.chatModeMarkerReadCount > 0)
        #expect(fixture.store.chatMode.marker(for: fixture.id(agent.paneID)) == followed)

        let next = ChatModeMarker(
            paneID: "tmux:%2", terminalID: "term_tmux:%2", kind: "codex", cwd: "/work/tmux",
            session: nil, launchedAt: Date())
        await fixture.store.recordChatModeLaunch(next, hostID: fixture.host.id)
        #expect(await fixture.tmux.chatModeMarkerWrites == [followed, next])
        #expect(await fixture.herdr.chatModeMarkerWrites.isEmpty)
    }

    /// Only tmux reconnects, herdr staying verified, and another device
    /// retires the tmux chat's marker during the gap: nothing is followed
    /// and written back from the cached marker; the Host's markers are read
    /// again first, and the retired one is dropped.
    @Test func aTmuxOnlyGapFollowsNothingUntilTheMarkersAreReadAgain() async throws {
        let agent = tmuxChatAgent(session: "s-1")
        let fixture = makeFixture(tmux: ScriptedTransport(snapshot: snapshotOfTmux(agent)))
        defer { fixture.store.setHosts([]) }
        let id = fixture.id(agent.paneID)
        let cached = chatMarker(
            for: agent, session: "s-1", launchedAt: Date(timeIntervalSince1970: 1_790_000_000))
        await fixture.herdr.setChatModeMarkers([cached])
        await start(fixture)
        try await waitForBothVerified(fixture)
        try await waitUntil { fixture.store.chatMode.marker(for: id) == cached }

        // The gap: tmux alone drops; meanwhile the chat Agent switched
        // session in place and another device retired its marker.
        let reconnect = ScriptedTransportCallGate()
        await fixture.tmux.gateNextSnapshot(using: reconnect)
        await fixture.tmux.setSnapshot(snapshotOfTmux(tmuxChatAgent(session: "s-2")))
        await fixture.tmux.failEventStream(.channelFailed(detail: "tmux control client dropped"))
        try await waitUntil { fixture.store.scopesAwaitingSnapshot.contains(fixture.tmuxScope) }
        #expect(!fixture.store.scopesAwaitingSnapshot.contains(fixture.herdrScope))
        await fixture.herdr.setChatModeMarkers([])
        let readsBefore = await fixture.herdr.chatModeMarkerReadCount

        await reconnect.open()
        try await waitUntil {
            let reads = await fixture.herdr.chatModeMarkerReadCount
            return reads > readsBefore
                && fixture.row(agent.paneID)?.agent.agentSession?.value == "s-2"
                && !fixture.store.scopesAwaitingSnapshot.contains(fixture.tmuxScope)
                && fixture.store.chatMode.marker(for: id) == nil
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await fixture.tmux.chatModeMarkerWrites.isEmpty, "a retired marker is not written back")
        #expect(await fixture.herdr.chatModeMarkerWrites.isEmpty)
        #expect(fixture.store.chatMode.marker(for: id) == nil)
    }
}

// MARK: The herdr slot: Herdr TUI or herdr-core (ADR 0031)

extension ConsoleDualBackendTests {
    fileprivate static let coreFound = CorePresence(
        version: "0.1.14", path: "/home/dev/.local/bin/herdr-core")
    /// Both herdr runtimes and tmux on the Host; the plugin is current and
    /// Ultimate was probed, so a fresh cached copy is not asked again.
    fileprivate static let bothRuntimes = HostBackendPresence(
        herdr: true, tmuxVersion: "3.4", waycarPlugin: dual.waycarPlugin, core: coreFound,
        ultimate: [])
    fileprivate static let coreAndTmux = HostBackendPresence(
        herdr: false, tmuxVersion: "3.4", waycarPlugin: dual.waycarPlugin, core: coreFound,
        ultimate: [])

    fileprivate static var coreAgent: AgentInfo {
        AgentInfo.fixture(paneID: "hc:t1", workspaceID: "core:/srv")
    }

    fileprivate static var coreSnapshot: SessionSnapshot {
        .fixture(
            agents: [coreAgent], workspaces: [.fixture(workspaceID: "core:/srv", label: "srv")])
    }

    @Test func failedTUIWithConnectedCoreNamesTheRuntimesStillServing() async throws {
        let failure = TransportError.streamLocalOpenFailed(path: "/tmp/herdr.sock")
        for hasTmux in [false, true] {
            let presence = HostBackendPresence(
                herdr: true, tmuxVersion: hasTmux ? "3.4" : nil,
                waycarPlugin: Self.dual.waycarPlugin, core: Self.coreFound, ultimate: [])
            let fixture = makeFixture(
                core: ScriptedTransport(snapshot: .fixture()),
                tmux: ScriptedTransport(snapshot: .fixture()),
                presence: presence, failures: [.herdr: failure])
            let store = fixture.store
            let hostID = fixture.host.id
            defer { store.setHosts([]) }
            await start(fixture)
            try await waitUntil {
                store.hostStatuses[hostID] == .failed(failure)
                    && store.scopeStatuses[fixture.coreScope] == .connected
                    && (!hasTmux || store.scopeStatuses[fixture.tmuxScope] == .connected)
            }
            let connected = store.connectedSecondaryBackends(on: hostID)
            #expect(connected == (hasTmux ? [.core, .tmux] : [.core]))
            let connectedMessage = hasTmux
                ? "Herdr Core and tmux are connected." : "Herdr Core is connected."
            for status in [EventsSessionStatus.failed(failure), .connecting] {
                // A stopped TUI's row is the calm one: its suggestion on the
                // second line, its Start in place (#389).
                let row = try #require(ConsoleHostStatusPresentation(
                    host: fixture.host, status: status, standingFailure: failure,
                    connectedBackends: connected, syncError: nil))
                #expect(
                    row.message
                        == "\(fixture.host.displayName): \(failure.presentation.explanation) \(connectedMessage)")
                #expect(row.detail == failure.presentation.recoverySuggestion)
                #expect(row.startsRuntime == .herdr)
                let footer = HostOnboardingConnectionPresentation(
                    status: status, standingFailure: failure, connectedBackends: connected,
                    isManualReconnectInFlight: false)
                #expect(footer.footerMessage == "\(failure.presentation.message) \(connectedMessage)")
            }
        }
    }

    /// Both inventories remain visible with a deterministic TUI lead.
    @Test func bothRuntimesStayVisibleAndTheTUILeadsAcrossRelaunch() async throws {
        let fixture = makeFixture(presence: Self.bothRuntimes)
        let hostID = fixture.host.id
        defer { fixture.store.setHosts([]) }
        await start(fixture)
        try await waitForBothVerified(fixture)
        try await waitForDetectedPresence(fixture, Self.bothRuntimes)

        try await waitUntil { fixture.row(Self.coreAgent.paneID) != nil }
        #expect(fixture.store.presentBackends(on: hostID) == [.herdr, .core, .tmux])
        #expect(fixture.store.leadBackend(on: hostID) == .herdr)

        try await waitUntil {
            fixture.row(Self.coreAgent.paneID) != nil
                && fixture.store.scopeStatuses[fixture.coreScope] == .connected
                && fixture.store.scopesAwaitingSnapshot.isEmpty
        }
        #expect(fixture.store.presentBackends(on: hostID) == [.herdr, .core, .tmux])
        #expect(fixture.store.leadBackend(on: hostID) == .herdr)
        #expect(fixture.store.hostLeadBackends[hostID] == .herdr)
        #expect(fixture.store.primaryProjection(on: hostID)?.backend == .herdr)
        #expect(fixture.store.defaultNewAgentBackend(on: hostID) == .herdr)
        #expect(fixture.row(Self.coreAgent.paneID)?.backend == .core)
        #expect(fixture.row(herdrAgent.paneID)?.backend == .herdr)
        #expect(fixture.row(tmuxAgent.paneID)?.backend == .tmux)
        // Every backend keeps one connection.
        #expect(fixture.calls.connects(.tmux) == 1)
        #expect(fixture.store.workspaces(for: hostID).contains { $0.id == "core:/srv" })
        #expect(fixture.calls.connects(.herdr) == 1)
        #expect(fixture.calls.connects(.core) == 1)

        // A relaunch keeps the same TUI-first priority and both inventories.
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "runtime-relaunch-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = ConsoleInventoryCache(directory: directory)
        writer.savePresence(
            .init(presence: Self.bothRuntimes, verifiedAt: Date()), for: fixture.host)
        writer.flush()
        let relaunched = makeFixture(
            presence: Self.bothRuntimes, host: fixture.host,
            inventoryCache: ConsoleInventoryCache(directory: directory))
        defer { relaunched.store.setHosts([]) }
        fixture.store.setHosts([])
        await start(relaunched)
        try await waitUntil {
            relaunched.row(Self.coreAgent.paneID) != nil
                && relaunched.row(tmuxAgent.paneID) != nil
        }
        #expect(relaunched.store.presentBackends(on: relaunched.host.id) == [.herdr, .core, .tmux])
        #expect(relaunched.store.leadBackend(on: relaunched.host.id) == .herdr)
    }

    @Test func concurrentVisibilityWritesKeepBothFlagsAndUnrelatedFields() async throws {
        let fixture = makeFixture(presence: Self.bothRuntimes)
        defer { fixture.store.setHosts([]) }
        await start(fixture)
        try await waitForBothVerified(fixture)
        try await waitForDetectedPresence(fixture, Self.bothRuntimes)
        try await waitUntil {
            await fixture.herdr.replacedNotificationConfigs.count > 0
        }
        await fixture.herdr.setNotificationConfig(
            Data(#"{"core_enabled":true,"tmux_enabled":true,"debounce_ms":500}"#.utf8))
        let gate = ScriptedTransportCallGate()
        await fixture.herdr.gateNextNotificationConfigRead(gate)
        let tmux = Task { await fixture.store.setShowsTmux(false, for: fixture.host.id) }
        await gate.waitForEntry()
        let core = Task {
            await fixture.store.setShowsRuntime(false, runtime: .core, for: fixture.host.id)
        }
        try await waitUntil {
            !fixture.store.backendPreferences.showsRuntime(.core, for: fixture.host.id)
        }
        await gate.open()
        await tmux.value
        await core.value
        let data = try #require(await fixture.herdr.notificationConfig)
        let fields = try JSONDecoder().decode([String: JSONValue].self, from: data)
        #expect(fields == ["core_enabled": .bool(false), "tmux_enabled": .bool(false),
                           "debounce_ms": .number(500)])
    }

    /// Core notifications follow visibility, never lead priority.
    @Test func visibilityNotLeadControlsCoreEnabledAndRuntimeProjections() async throws {
        let host = Host.fixture()
        let hostID = host.id
        let herdr = ScriptedTransport(snapshot: herdrSnapshot)
        let core = ScriptedTransport(snapshot: Self.coreSnapshot)
        let tmux = ScriptedTransport(snapshot: tmuxSnapshot)
        // A legacy value is replaced by the current visibility preference.
        for transport in [herdr, core, tmux] {
            await transport.setNotificationConfig(Data(#"{"core_enabled":"unset"}"#.utf8))
        }
        let fixture = makeFixture(
            herdr: herdr, core: core, tmux: tmux, presence: Self.bothRuntimes, host: host)
        defer { fixture.store.setHosts([]) }
        await start(fixture)
        try await waitForBothVerified(fixture)
        try await waitForDetectedPresence(fixture, Self.bothRuntimes)

        /// Every `core_enabled` a transport's `notify.json` holds.
        func writtenCoreEnabled() async -> [Bool] {
            var values: [Bool] = []
            for transport in [herdr, core, tmux] {
                guard let data = await transport.notificationConfig,
                    let fields = try? JSONDecoder().decode([String: JSONValue].self, from: data),
                    case .bool(let value)? = fields["core_enabled"]
                else { continue }
                values.append(value)
            }
            return values
        }

        try await waitUntil { await writtenCoreEnabled().contains(true) }
        #expect(!(await writtenCoreEnabled()).contains(false))

        await fixture.store.setShowsRuntime(false, runtime: .core, for: hostID)
        #expect(fixture.store.leadBackend(on: hostID) == .herdr)
        #expect(await writtenCoreEnabled().contains(false))
        #expect(fixture.row(Self.coreAgent.paneID) == nil)
        #expect(fixture.row(herdrAgent.paneID) != nil)
        await fixture.store.setShowsRuntime(true, runtime: .core, for: hostID)
        try await waitUntil { fixture.row(Self.coreAgent.paneID) != nil }
        #expect(fixture.store.leadBackend(on: hostID) == .herdr)
        await fixture.store.setShowsRuntime(false, runtime: .tui, for: hostID)
        #expect(fixture.store.leadBackend(on: hostID) == .core)
        #expect(fixture.row(herdrAgent.paneID) == nil)
        #expect(fixture.row(Self.coreAgent.paneID) != nil)
        #expect(fixture.store.presentBackends(on: hostID) == [.core, .tmux])
    }

    @Test func bothRuntimesKeepMoshAndSidebarOnTheTUI() async throws {
        let host = Host.fixture()
        let herdr = ScriptedTransport(snapshot: herdrSnapshot)
        let layout = Data(#"{"v":1,"sidebar":{}}"#.utf8)
        await herdr.setSidebarLayout(layout)
        await herdr.setMoshProbeAvailable(true)
        let fixture = makeFixture(herdr: herdr, presence: Self.bothRuntimes,
                                  host: host)
        defer { fixture.store.setHosts([]) }
        await start(fixture)
        try await waitForBothVerified(fixture)
        #expect(fixture.store.moshProjection(on: host.id)?.backend == .herdr)
        await fixture.store.forceMoshReprobe(for: host.id)
        try await waitUntil { fixture.store.moshCapsuleState(for: host.id) == .available }
        #expect(await fixture.core.moshProbeCount == 0)
        #expect(try await fixture.store.readHerdrSidebarLayout(for: host.id) == layout)
        #expect(await fixture.core.sidebarLayoutReads == 0)
    }

    @Test func hidingTheLastCoreProjectionWritesSuppressionBeforeClosing() async throws {
        let fixture = makeFixture(presence: Self.bothRuntimes, hidingTmux: true)
        defer { fixture.store.setHosts([]) }
        await start(fixture)
        try await waitUntil { fixture.store.scopeStatuses[fixture.coreScope] == .connected }
        await fixture.store.setShowsRuntime(false, runtime: .tui, for: fixture.host.id)
        await fixture.store.setShowsRuntime(false, runtime: .core, for: fixture.host.id)
        let config = try #require(await fixture.core.notificationConfig)
        let fields = try JSONDecoder().decode([String: JSONValue].self, from: config)
        #expect(fields["core_enabled"] == .bool(false))
        #expect(fixture.store.projection(on: fixture.host.id, backend: .core) == nil)
    }

    /// Re-enabling core after every runtime was hidden must restore pushes:
    /// the enable reconciles a projection first, then writes
    /// `core_enabled: true` through it (review finding on 3a2b3b69).
    @Test func reenablingCoreAfterHidingEverythingRestoresNotifications() async throws {
        let fixture = makeFixture(presence: Self.bothRuntimes, hidingTmux: true)
        defer { fixture.store.setHosts([]) }
        await start(fixture)
        try await waitUntil { fixture.store.scopeStatuses[fixture.coreScope] == .connected }
        await fixture.store.setShowsRuntime(false, runtime: .tui, for: fixture.host.id)
        await fixture.store.setShowsRuntime(false, runtime: .core, for: fixture.host.id)
        #expect(fixture.store.projection(on: fixture.host.id, backend: .core) == nil)
        await fixture.store.setShowsRuntime(true, runtime: .core, for: fixture.host.id)
        try await waitUntil {
            guard let config = await fixture.core.notificationConfig,
                let fields = try? JSONDecoder().decode([String: JSONValue].self, from: config)
            else { return false }
            return fields["core_enabled"] == .bool(true)
        }
    }

    /// A core-only Host (with tmux): core fills the slot, and the Host
    /// presents its state while tmux lists no sessions.
    @Test func aCoreHostWithTmuxLeadsWithCoreThenHandsToTmuxWhenCoreFails() async throws {
        let fixture = makeFixture(
            presence: Self.coreAndTmux, failures: [.core: .herdrBinaryNotFound])
        defer { fixture.store.setHosts([]) }
        await start(fixture)

        try await waitUntil {
            fixture.store.scopeStatuses[fixture.coreScope] == .failed(.herdrBinaryNotFound)
                && fixture.store.scopeStatuses[fixture.tmuxScope] == .connected
                && fixture.row(tmuxAgent.paneID) != nil
        }
        // The failed core is the herdr slot, so tmux's connected sessions
        // lead the Host; core's failure keeps its own row.
        #expect(fixture.store.hostLeadBackends[fixture.host.id] == .tmux)
        #expect(fixture.store.hostStatuses[fixture.host.id] == .connected)
        #expect(
            fixture.store.failedSecondaryScopes(on: fixture.host.id).map { $0.scope }
                == [fixture.coreScope])
        #expect(fixture.store.presentBackends(on: fixture.host.id) == [.core, .tmux])
    }

    @Test func aCoreHostLeadsWithCoreWhileTmuxListsNoSessions() async throws {
        let fixture = makeFixture(
            tmux: ScriptedTransport(snapshot: .fixture()), presence: Self.coreAndTmux)
        defer { fixture.store.setHosts([]) }
        await start(fixture)

        try await waitUntil {
            fixture.row(Self.coreAgent.paneID) != nil
                && fixture.store.scopeStatuses[fixture.tmuxScope] == .connected
                && fixture.store.scopesAwaitingSnapshot.isEmpty
        }
        #expect(fixture.store.hostLeadBackends[fixture.host.id] == .core)
        #expect(fixture.store.hostStatuses[fixture.host.id] == .connected)
    }

    /// tmux connects once the herdr slot's connection settles, whichever
    /// runtime fills it (#105): core's snapshot in flight holds tmux back.
    @Test func tmuxWaitsForCoreAsItWaitsForTheTUI() async throws {
        let core = ScriptedTransport(snapshot: Self.coreSnapshot)
        let gate = ScriptedTransportCallGate()
        await core.gateNextSnapshot(using: gate)
        let fixture = makeFixture(core: core, presence: Self.coreAndTmux)
        defer { fixture.store.setHosts([]) }
        await start(fixture)
        await gate.waitForEntry()
        #expect(fixture.calls.connects(.tmux) == 0)

        await gate.open()

        try await waitUntil {
            fixture.calls.connects(.tmux) == 1 && fixture.row(tmuxAgent.paneID) != nil
        }
    }

    @Test func aCachedTUILeadDefersCoreAndTmuxUntilItsSnapshotSettles() async throws {
        let host = Host.fixture()
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "tui-lead-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ConsoleInventoryCache(directory: directory)
        cache.savePresence(.init(presence: Self.bothRuntimes, verifiedAt: Date()), for: host)
        cache.flush()
        let herdr = ScriptedTransport(snapshot: herdrSnapshot)
        let gate = ScriptedTransportCallGate()
        await herdr.gateNextSnapshot(using: gate)
        let fixture = makeFixture(
            herdr: herdr, presence: Self.bothRuntimes, host: host,
            inventoryCache: cache)
        defer { fixture.store.setHosts([]) }
        await start(fixture)
        await gate.waitForEntry()
        #expect(fixture.calls.connects(.core) == 0)
        #expect(fixture.calls.connects(.tmux) == 0)
        await gate.open()
        try await waitForBothVerified(fixture)
        #expect(fixture.store.hostLeadBackends[host.id] == .herdr)
    }

    /// Without TUI, the internal New Agent fallback uses core.
    @Test func theNewAgentDefaultFollowsTheHerdrSlot() async throws {
        let fixture = makeFixture(presence: Self.coreAndTmux)
        defer { fixture.store.setHosts([]) }
        await start(fixture)
        try await waitUntil {
            fixture.row(Self.coreAgent.paneID) != nil && fixture.row(tmuxAgent.paneID) != nil
        }
        let hostID = fixture.host.id

        #expect(fixture.store.defaultNewAgentBackend(on: hostID) == .core)
    }

    /// Both installed runtimes contribute their plugin requirements,
    /// independently of the lead.
    @Test func aHostThatUsesCoreNeedsTheCoreModePlugin() async throws {
        func presence(
            herdr: Bool = false, tmux: String? = nil, plugin: WaycarPluginDetection
        ) -> HostBackendPresence {
            HostBackendPresence(
                herdr: herdr, tmuxVersion: tmux, waycarPlugin: plugin, core: Self.coreFound)
        }
        func tools(_ version: String) -> WaycarPluginDetection {
            .installed(WaycarPluginInstall(version: version, mode: .core))
        }
        let coreOnly = presence(plugin: .notInstalled)
        let fixture = makeFixture(presence: coreOnly)
        defer { fixture.store.setHosts([]) }
        await start(fixture)
        try await waitForDetectedPresence(fixture, coreOnly)
        let hostID = fixture.host.id
        #expect(fixture.store.resolvedBackends(on: hostID) == [.core])

        #expect(fixture.store.waycarPluginStatus(on: hostID) == .notInstalled)
        fixture.store.recordDetectedPresence(presence(plugin: tools("2.1.0")), on: hostID)
        #expect(
            fixture.store.waycarPluginStatus(on: hostID)
                == .outdated(installed: "2.1.0", required: "2.2.0"))
        fixture.store.recordDetectedPresence(presence(tmux: "3.4", plugin: tools("2.1.0")), on: hostID)
        #expect(
            fixture.store.waycarPluginStatus(on: hostID)
                == .outdated(installed: "2.1.0", required: "2.2.0"))
        fixture.store.recordDetectedPresence(presence(plugin: tools("2.2.1")), on: hostID)
        #expect(fixture.store.waycarPluginStatus(on: hostID) == .current(version: "2.2.1"))

        // Preferring the TUI does not remove core's plugin requirement.
        fixture.store.recordDetectedPresence(presence(herdr: true, plugin: tools("2.1.0")), on: hostID)
        #expect(fixture.store.resolvedBackends(on: hostID) == [.herdr, .core])
        #expect(fixture.store.waycarPluginStatus(on: hostID)
            == .outdated(installed: "2.1.0", required: "2.2.0"))
    }

    // MARK: Install herdr-core and the core_enabled default (WAY-483)

    /// An install that found core connects the Host at once, with no
    /// failure shown: core's projection starts on the recorded presence.
    @Test func anInstalledCoreConnectsTheHostAtOnce() async throws {
        let fixture = try await startedWithNoBackend()
        defer { fixture.store.setHosts([]) }
        let found = HostBackendPresence(herdr: false, tmuxVersion: nil, core: Self.coreFound)

        fixture.store.backendInstallEnded(
            on: fixture.host.id, outcome: ended(.found(found), target: .core))

        try await waitUntil {
            fixture.row(Self.coreAgent.paneID) != nil
                && fixture.store.scopeStatuses[fixture.coreScope] == .connected
        }
        #expect(fixture.store.presentBackends(on: fixture.host.id) == [.core])
        #expect(HostBackendGap(presence: fixture.store.backendPresence(on: fixture.host.id)) == nil)
        #expect(fixture.store.hostStatuses[fixture.host.id] == .connected)
    }

    /// The installer's update branch restarts a core that is already
    /// running, which ends every connection in EOF: the Console reconnects
    /// core's projection on a new connection and ends up connected.
    @Test func anInstallOverARunningCoreReconnectsItsProjection() async throws {
        let fixture = makeFixture(presence: Self.coreAndTmux)
        defer { fixture.store.setHosts([]) }
        await start(fixture)
        try await waitUntil {
            fixture.row(Self.coreAgent.paneID) != nil
                && fixture.store.scopeStatuses[fixture.coreScope] == .connected
        }
        let before = fixture.calls.connects(.core)

        fixture.store.backendInstallEnded(
            on: fixture.host.id, outcome: ended(.found(Self.coreAndTmux), target: .core))

        try await waitUntil {
            fixture.calls.connects(.core) > before
                && fixture.store.scopeStatuses[fixture.coreScope] == .connected
        }
        #expect(fixture.row(Self.coreAgent.paneID) != nil)
        #expect(fixture.store.hostStatuses[fixture.host.id] == .connected)
    }

    /// Both inventories show from first detection, so core pushes are on.
    @Test func bothRuntimesWithNoPickEnableCoreOnTheFirstDetection() async throws {
        let herdr = ScriptedTransport(snapshot: herdrSnapshot)
        let core = ScriptedTransport(snapshot: Self.coreSnapshot)
        let tmux = ScriptedTransport(snapshot: tmuxSnapshot)
        let fixture = makeFixture(
            herdr: herdr, core: core, tmux: tmux, presence: Self.bothRuntimes)
        defer { fixture.store.setHosts([]) }
        await start(fixture)

        // The initial TUI lead carries the Host-level config write.
        try await waitUntil {
            for transport in [herdr, tmux] {
                guard let data = await transport.notificationConfig,
                    let fields = try? JSONDecoder().decode([String: JSONValue].self, from: data)
                else { continue }
                if fields["core_enabled"] == .bool(true) { return true }
            }
            return false
        }
        // Both inventories show without a stored lead preference.
        #expect(fixture.store.resolvedBackends(on: fixture.host.id) == [.herdr, .core, .tmux])
    }

    /// Repairing the legacy switch preserves unrelated notification fields.
    @Test func theFirstDetectionRepairsALegacyCoreDisabledWithoutChangingOtherFields() async throws {
        let herdr = ScriptedTransport(snapshot: herdrSnapshot)
        await herdr.setNotificationConfig(Data(#"{"core_enabled":false,"push":"on"}"#.utf8))
        let fixture = makeFixture(
            herdr: herdr, presence: Self.bothRuntimes)
        defer { fixture.store.setHosts([]) }
        await start(fixture)
        try await waitForBothVerified(fixture)
        try await waitForDetectedPresence(fixture, Self.bothRuntimes)
        try await waitUntil("detection should repair the legacy core switch") {
            guard let config = await herdr.notificationConfig else { return false }
            let fields = try JSONDecoder().decode([String: JSONValue].self, from: config)
            return fields["core_enabled"] == .bool(true)
        }

        let config = try #require(await herdr.notificationConfig)
        let fields = try JSONDecoder().decode([String: JSONValue].self, from: config)
        #expect(fields["core_enabled"] == .bool(true))
        #expect(fields["push"] == .string("on"))
    }

    /// A Host with one runtime has no legacy exclusivity switch to repair.
    @Test func bothProjectionsStayVisibleAndOneRuntimeNeedsNoDefaultWrite() async throws {
        let host = Host.fixture()
        let bothRuntimes = makeFixture(presence: Self.bothRuntimes, host: host)
        defer { bothRuntimes.store.setHosts([]) }
        await start(bothRuntimes)
        try await waitUntil { bothRuntimes.row(Self.coreAgent.paneID) != nil }
        try await waitForDetectedPresence(bothRuntimes, Self.bothRuntimes)

        let single = makeFixture(presence: Self.dual)
        defer { single.store.setHosts([]) }
        await start(single)
        try await waitForBothVerified(single)
        try await waitForDetectedPresence(single, Self.dual)
        try await Task.sleep(for: .milliseconds(100))

        #expect(bothRuntimes.store.presentBackends(on: host.id) == [.herdr, .core, .tmux])
        for transport in [single.herdr, single.core, single.tmux] {
            #expect(await transport.replacedNotificationConfigs.isEmpty)
        }
    }
}
