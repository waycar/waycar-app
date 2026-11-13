import Foundation
import Testing

@testable import Waycar

@MainActor
@Suite("Sample Host", .timeLimit(.minutes(1)))
struct SampleHostTests {
    private func defaults() throws -> (UserDefaults, () -> Void) {
        let name = "sample-test-\(UUID().uuidString)"
        let value = try #require(UserDefaults(suiteName: name))
        return (value, { value.removePersistentDomain(forName: name) })
    }

    @Test func virtualHostNeverEntersPersistenceOrSyncAndAnyRealHostHidesIt() throws {
        let (defaults, cleanup) = try defaults()
        defer { cleanup() }
        let secrets = VolatileSecretStore()
        let shared = VolatileSecretStore()
        let catalog = HostStore(
            defaults: defaults, secrets: secrets,
            sync: SyncedHostCatalog(store: { shared }))
        #expect(catalog.sampleHost?.id == SampleHost.id)
        #expect(catalog.hosts.isEmpty)
        #expect(catalog.enabledHosts.isEmpty)
        _ = try catalog.reconcileWithSync(shared.readAll())
        #expect(try shared.readAll().isEmpty)
        #expect(defaults.data(forKey: "hosts") == nil)
        #expect(throws: HostStoreError.reservedHostID) { try catalog.add(SampleHost.host) }
        #expect(throws: HostStoreError.reservedHostID) { try catalog.update(SampleHost.host) }

        let host = Host.fixture()
        try catalog.add(host)
        try catalog.setEnabled(false, for: host.id)
        #expect(catalog.sampleHost == nil)
        #expect(catalog.enabledHosts.isEmpty)
        let reloaded = HostStore(defaults: defaults, secrets: secrets)
        #expect(reloaded.hosts.map(\.id) == [host.id])
        #expect(reloaded.sampleHost == nil)
        #expect(try shared.readAll()[SyncedHostCatalog.account(for: SampleHost.id)] == nil)
        try catalog.remove(host.id)
        #expect(catalog.sampleHost?.id == SampleHost.id)
        _ = try catalog.reconcileWithSync(shared.readAll())
        #expect(try shared.readAll()[SyncedHostCatalog.account(for: SampleHost.id)] == nil)
    }

    @Test func damagedCatalogDoesNotOfferASampleOverRecoverableUserData() throws {
        let (defaults, cleanup) = try defaults()
        defer { cleanup() }
        defaults.set(Data("not JSON".utf8), forKey: "hosts")
        let catalog = HostStore(defaults: defaults, secrets: VolatileSecretStore())
        #expect(catalog.catalogLoadError == .catalogUnreadable)
        #expect(catalog.sampleHost == nil)
    }

    @Test func sampleOpensWithoutCredentialsAndLeavesRealConsumersEmpty() async throws {
        let sample = try SampleSession()
        let catalog = HostStore(volatileHosts: [])
        let realConsole = ConsoleStore()
        let app = WaycarAppModel(
            pushRegistration: PushRegistrationStore(
                client: ScriptedPushRegistrationClient(), environment: .sandbox),
            sceneDirectory: AgentSceneDirectory(), hostStore: catalog, console: realConsole)
        app.start()
        await sample.start()
        try await waitForSample(sample)
        #expect(Set(sample.console.agents.map { $0.agent.status }) == [.blocked, .done, .working])
        #expect(realConsole.agents.isEmpty)
        #expect(realConsole.catalog.isEmpty)

        let watch = WatchStateBuilder.state(
            from: WatchStateSource.live(app, voiceTranscription: false),
            stamps: WatchStatusStamps(), now: Date())
        #expect(watch.hosts.isEmpty)
        #expect(watch.rows.isEmpty)
        let car = CarPlayListModel(agents: realConsole.agents, maximumItemCount: 12, now: Date())
        #expect(car.rows.isEmpty)
        await app.notificationPreferences.refresh()
        #expect(app.notificationPreferences.hosts.isEmpty)
        #expect(app.notificationPreferences.states.isEmpty)
        #expect(app.aiUsage.usage.isEmpty)
        let agentID = ConsoleAgent.ID(hostID: SampleHost.id, paneID: SampleFixture.donePaneID)
        sample.console.noteAgentIntent(agentID)
        await sample.console.forceMoshReprobe(for: SampleHost.id)
        #expect(sample.console.standbyAgents.isEmpty)
        #expect(sample.console.speculativeStandbys.isEmpty)
        #expect(sample.console.moshStates.isEmpty)
        await sample.stop()
        #expect(sample.console.agents.isEmpty)
    }

    @Test func sampleIsNotAnEligibleLiveActivityHostEvenWithAnExistingActivity() throws {
        let (defaults, cleanup) = try defaults()
        defer { cleanup() }
        let catalog = HostStore(volatileHosts: [])
        let controller = FakeLiveActivityController()
        controller.seed(id: "accidental-sample-activity", hostID: SampleHost.id)
        let coordinator = HostLiveActivityCoordinator(
            controller: controller, preferences: LiveActivityPreferences(defaults: defaults),
            transports: ScriptedTransportProvider(transports: [:]),
            keys: NotificationKeyStore(secrets: VolatileSecretStore()),
            deviceToken: { nil },
            knownHostIDs: { Set(catalog.enabledHosts.map(\.id)) },
            hostDisplayName: { _ in "Sample" },
            isAwaitingSnapshot: { _ in false }, connectionStatus: { _ in .connected })
        coordinator.start()
        #expect(controller.ended.map(\.id) == ["accidental-sample-activity"])
        #expect(controller.currentActivities().isEmpty)
        #expect(controller.requested.isEmpty)
    }

    @Test func sampleRefusesALaunch() async throws {
        let sample = try SampleSession()
        await sample.start()
        try await waitForSample(sample)
        // The sample is read-only. A direct launch bypassing the UI must
        // refuse the write instead of returning a fake successful Agent.
        do {
            _ = try await sample.console.startAgent(
                AgentLaunchRequest(kind: "codex", name: "sample-launch", workspaceID: "mobile"),
                on: SampleHost.id)
            Issue.record("A read-only sample unexpectedly launched an Agent")
        } catch {
            #expect(error is TransportError)
        }
        await sample.stop()
    }

    @Test func sampleAgentsDoNotRecordAttachTelemetryAndRealOnesDo() {
        func agent(on hostID: Host.ID) -> ConsoleAgent {
            ConsoleAgent(
                hostID: hostID, hostName: "h",
                agent: Agent(SampleFixture.snapshot.agents[0]),
                workspaceLabel: nil, repositoryCheckout: nil)
        }
        #expect(!agent(on: SampleHost.id).recordsNetworkTelemetry)
        #expect(agent(on: UUID()).recordsNetworkTelemetry)
    }

    @Test func sampleTransportAllowsOneAttachPerTargetNotOnePerHost() async throws {
        let transport = SampleTransport()
        func request(_ pane: String) -> TerminalAttachRequest {
            TerminalAttachRequest(
                target: .agentPane(pane), cols: 80, rows: 24)
        }
        let blocked = try await transport.attachTerminal(request(SampleFixture.blockedPaneID))
        let done = try await transport.attachTerminal(request(SampleFixture.donePaneID))
        await #expect(throws: TransportError.self) {
            _ = try await transport.attachTerminal(request(SampleFixture.donePaneID))
        }
        await done.end()
        let reopened = try await transport.attachTerminal(request(SampleFixture.donePaneID))
        await reopened.end()
        await blocked.end()
    }

    private func waitForSample(_ sample: SampleSession) async throws {
        let deadline = ContinuousClock.now + .waitCeiling
        while ContinuousClock.now < deadline {
            if sample.console.hostStatuses[SampleHost.id] == .connected,
                sample.console.agents.count == SampleFixture.snapshot.agents.count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Sample inventory did not arrive through the production session factory")
        throw CancellationError()
    }
}
