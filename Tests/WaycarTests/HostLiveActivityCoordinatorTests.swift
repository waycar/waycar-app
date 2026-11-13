import Foundation
import Testing

@testable import Waycar

@MainActor
@Suite("Host live activity coordinator")
struct HostLiveActivityCoordinatorTests {
    private let host = Host.fixture(name: "mbp", address: "mbp.local", username: "z")
    private let token = APNSDeviceToken(hex: "0a1b2c3d", environment: .sandbox)
    private let secrets = InMemorySecretStore()
    private let controller = FakeLiveActivityController()
    private let transport = ScriptedTransport()
    private let world = World()
    /// Observed-family herdr pane id (alphanumeric `w…:p…`, uppercase
    /// included). This suite treats it as an opaque string; the live shape
    /// keeps the fixtures from re-teaching the retired tmux-style `%N` habit.
    /// Pin cases below keep deliberately fake ids (`w:p-work`) because they
    /// only need a stable opaque token, not a live-shaped address.
    private let observedPaneID = "wV:p1"

    @MainActor
    private final class World {
        var knownHostIDs: Set<UUID> = []
        var hostNames: [UUID: String] = [:]
        var awaitingSnapshot: Set<UUID> = []
        var statuses: [UUID: EventsSessionStatus] = [:]
        var deviceToken: APNSDeviceToken?
        var layout: AgentRowLayout?
    }

    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "la-pref-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    private func makeCoordinator(
        defaults: UserDefaults,
        enable: Bool = true,
        pins: PinnedAgentsStore? = nil,
        transports: (any NotificationTransportProvider)? = nil
    ) -> HostLiveActivityCoordinator {
        let keys = NotificationKeyStore(secrets: secrets)
        let world = world
        let pinStore = pins
        let coordinator = HostLiveActivityCoordinator(
            controller: controller,
            preferences: LiveActivityPreferences(defaults: defaults),
            transports: transports ?? ScriptedTransportProvider(transports: [host.id: transport]),
            keys: keys,
            ceremony: NotificationRegistrationCeremony(keys: keys),
            deviceToken: { world.deviceToken },
            knownHostIDs: { world.knownHostIDs },
            hostDisplayName: { world.hostNames[$0] ?? "" },
            isAwaitingSnapshot: { world.awaitingSnapshot.contains($0) },
            connectionStatus: { world.statuses[$0] },
            pinnedPaneIDs: { pinStore?.pinnedPaneIDs(for: $0) ?? [] },
            rowLayout: { _ in world.layout },
            settleDuration: .milliseconds(20))
        if enable {
            coordinator.setEnabled(true, for: host.id)
        }
        return coordinator
    }

    private func armWorld(token: APNSDeviceToken? = nil) {
        world.knownHostIDs = [host.id]
        world.hostNames[host.id] = "mbp"
        world.awaitingSnapshot = []
        world.statuses[host.id] = .connected
        world.deviceToken = token ?? self.token
    }

    private func saveKey() throws {
        try NotificationKeyStore(secrets: secrets).save(
            NotificationKeyRecord(
                hostID: host.id, hostName: "mbp", key: NotificationKeyStore.generateKey()))
    }

    private func registerDevice() async throws {
        let keys = NotificationKeyStore(secrets: secrets)
        try await NotificationRegistrationCeremony(keys: keys).register(
            hostID: host.id, hostName: "mbp", deviceToken: token, over: transport)
    }

    private func agent(
        _ paneID: String, _ status: AgentStatus, title: String = "Task"
    ) -> ConsoleAgent {
        ConsoleAgent(
            hostID: host.id, hostName: "mbp",
            agent: Agent(.fixture(paneID: paneID, status: status, title: title)),
            workspaceLabel: nil, repositoryCheckout: nil)
    }

    private func waitPastSettle() async throws {
        try await Task.sleep(for: .milliseconds(80))
    }

    private func liveActivityToken() async throws -> String? {
        try NotificationRegistrationFile.decode(await transport.notificationRegistration)
            .liveActivity(forDeviceToken: token.hex)?.token
    }

    private func filePinnedPaneIDs() async throws -> [String]? {
        try NotificationRegistrationFile.decode(await transport.notificationRegistration)
            .liveActivity(forDeviceToken: token.hex)?.pinnedPaneIDs
    }

    private func notificationKey() throws -> Data {
        try #require(try NotificationKeyStore(secrets: secrets).record(forHost: host.id)?.key)
    }

    private func openedPaneIDs(_ state: AgentActivityAttributes.ContentState) throws -> [String] {
        let envelope = try #require(state.envelope)
        let details = try AgentActivityEnvelope.open(
            try JSONEncoder().encode(envelope), using: notificationKey())
        return details.agents.map(\.paneID)
    }

    // MARK: Start / settle / flap

    @Test func startsAfterTheSettleNotOnFirstSight() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        try await registerDevice()
        armWorld()
        let coordinator = makeCoordinator(defaults: defaults)

        coordinator.start()
        coordinator.agentsDidChange([agent(observedPaneID, .working)])
        #expect(controller.requested.isEmpty, "the desired state must settle first")

        try await waitUntil("a working Agent should start an activity once settled") {
            !controller.requested.isEmpty
        }
        #expect(controller.requested.count == 1)
        #expect(controller.requested[0].counts == .init(working: 1, blocked: 0, done: 0))
    }

    @Test func aFlapBackToTheAppliedDesireDoesNotEnd() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        try await registerDevice()
        armWorld()
        let coordinator = makeCoordinator(defaults: defaults)
        coordinator.start()
        coordinator.agentsDidChange([agent(observedPaneID, .working)])
        try await waitUntil("the activity should start") { !controller.requested.isEmpty }

        coordinator.agentsDidChange([])
        coordinator.agentsDidChange([agent(observedPaneID, .working)])
        try await waitPastSettle()

        #expect(controller.ended.isEmpty)
        #expect(controller.requested.count == 1)
        #expect(controller.updates.isEmpty)
    }

    @Test func updateCoalescesToTheLatestDesire() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        try await registerDevice()
        armWorld()
        let coordinator = makeCoordinator(defaults: defaults)
        coordinator.start()
        coordinator.agentsDidChange([agent(observedPaneID, .working)])
        try await waitUntil("the activity should start") { !controller.requested.isEmpty }

        coordinator.agentsDidChange([agent(observedPaneID, .blocked)])
        coordinator.agentsDidChange([agent(observedPaneID, .done)])
        try await waitUntil("only the latest desire should land as an update") {
            controller.updates.count == 1
        }
        try await waitPastSettle()
        #expect(controller.updates.count == 1)
        #expect(controller.updates[0].content.counts == .init(working: 0, blocked: 0, done: 1))
    }

    // MARK: Fail closed

    @Test func staysIdleWhenThePreferenceIsOff() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        try await registerDevice()
        armWorld()
        let coordinator = makeCoordinator(defaults: defaults, enable: false)
        coordinator.start()
        coordinator.agentsDidChange([agent(observedPaneID, .blocked)])
        try await waitPastSettle()
        #expect(controller.requested.isEmpty)
    }

    @Test func staysIdleWhenTheNotificationKeyIsMissing() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        armWorld()
        let coordinator = makeCoordinator(defaults: defaults)
        coordinator.start()
        coordinator.agentsDidChange([agent(observedPaneID, .blocked)])
        try await waitPastSettle()
        #expect(controller.requested.isEmpty)
    }

    @Test func staysIdleWhenTheDeviceTokenIsMissing() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        try saveKey()
        armWorld(token: nil)
        world.deviceToken = nil
        let coordinator = makeCoordinator(defaults: defaults)
        coordinator.start()
        coordinator.agentsDidChange([agent(observedPaneID, .done)])
        try await waitPastSettle()
        #expect(controller.requested.isEmpty)
    }

    @Test func staysIdleWhenActivitiesAreDisabledOrRequestThrows() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        try await registerDevice()
        armWorld()
        controller.areEnabled = false
        let coordinator = makeCoordinator(defaults: defaults)
        coordinator.start()
        coordinator.agentsDidChange([agent(observedPaneID, .working)])
        try await waitPastSettle()
        #expect(controller.requested.isEmpty)

        controller.areEnabled = true
        controller.requestError = LiveActivityRequestError.requestFailed()
        coordinator.agentsDidChange([agent(observedPaneID, .blocked)])
        try await waitPastSettle()
        #expect(controller.requested.isEmpty)
    }

    @Test func reconcileRetriesAFailedStartWithUnchangedAgents() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        try await registerDevice()
        armWorld()
        controller.requestError = LiveActivityRequestError.requestFailed()
        let coordinator = makeCoordinator(defaults: defaults)
        coordinator.start()
        coordinator.agentsDidChange([agent(observedPaneID, .working)])
        try await waitUntil("the initial start should fail") {
            coordinator.reconcileNotes[host.id]?.hasPrefix("start failed") == true
        }

        controller.requestError = nil
        coordinator.reconcile()

        try await waitUntil("foreground reconciliation should retry the failed start") {
            controller.requested.count == 1
        }
    }

    // MARK: End + token pipe

    @Test func disablingNotificationsCannotBeUndoneByAnActivityTokenWrite() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        try await registerDevice()
        armWorld()
        let provider = NotificationRegistrationWriter(
            transports: ScriptedTransportProvider(transports: [host.id: transport]))
        let preferences = NotificationPreferencesStore(
            transports: provider, deviceToken: { self.token },
            ceremony: NotificationRegistrationCeremony(keys: NotificationKeyStore(secrets: secrets)))
        preferences.setHosts([host])
        await preferences.refresh()
        let coordinator = makeCoordinator(defaults: defaults, transports: provider)
        coordinator.start()
        coordinator.agentsDidChange([agent(observedPaneID, .working)])
        try await waitUntil("the activity should start") { !controller.requestedHandles.isEmpty }
        let activityID = try #require(controller.requestedHandles.first?.id)
        let gate = ScriptedTransportCallGate()
        await transport.gateNextNotificationRegistrationWrite(gate)
        controller.emitToken(id: activityID, Data([0xaa]))
        await gate.waitForEntry()

        let removal = Task { await preferences.setNotificationsEnabled(false, for: host) }
        try await waitUntil("disabling should wait for the token ceremony") {
            if case .updating = preferences.states[host.id] { return true }
            return false
        }
        await gate.open()
        await removal.value
        // A later token rotation is ordered behind the held write, so its
        // read proves that the held write has finished.
        let readGate = ScriptedTransportCallGate()
        await transport.gateNextNotificationRegistrationRead(readGate)
        controller.emitToken(id: activityID, Data([0xbb]))
        await readGate.waitForEntry()
        await readGate.open()

        let file = try NotificationRegistrationFile.decode(await transport.notificationRegistration)
        #expect(!file.containsDevice(token: token.hex))
    }

    @Test func preferencesDoNotDiscardAFailedInFlightToken() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        try await registerDevice()
        armWorld()
        let coordinator = makeCoordinator(defaults: defaults)
        coordinator.start()
        coordinator.agentsDidChange([agent(observedPaneID, .working)])
        try await waitUntil("the activity should start") { !controller.requestedHandles.isEmpty }
        let activityID = try #require(controller.requestedHandles.first?.id)
        let gate = ScriptedTransportCallGate()
        await transport.setNotificationRegistrationWriteFailure(.writeFailed(detail: "offline"))
        await transport.gateNextNotificationRegistrationWrite(gate)
        controller.emitToken(id: activityID, Data([0xcc]))
        await gate.waitForEntry()

        world.layout = AgentRowLayout(rows: [[.init(.status)]])
        coordinator.layoutsDidChange()
        await transport.setNotificationRegistrationWriteFailure(nil)
        await gate.open()

        try await waitUntil("reconnect must retain the token as well as the new layout") {
            coordinator.connectionsDidChange()
            return try await liveActivityToken() == "cc"
        }
        let file = try NotificationRegistrationFile.decode(await transport.notificationRegistration)
        #expect(file.devices.first?["live_activity"]?["row_layout"] != nil)
    }

    @Test func endingOnEmptyClearsTheLiveActivityToken() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        try await registerDevice()
        armWorld()
        let coordinator = makeCoordinator(defaults: defaults)
        coordinator.start()
        coordinator.agentsDidChange([agent(observedPaneID, .working)])
        try await waitUntil("the activity should start") { !controller.requestedHandles.isEmpty }
        let activityID = try #require(controller.requestedHandles.first?.id)

        controller.emitToken(id: activityID, Data([0xde, 0xad]))
        try await waitUntil("the push token should land on the Host") {
            try await liveActivityToken() == "dead"
        }

        coordinator.agentsDidChange([])
        try await waitUntil("an empty eligible set should end the activity") {
            !controller.ended.isEmpty
        }
        #expect(controller.ended[0].immediate)
        try await waitUntil("ending should drop the registration field") {
            try await liveActivityToken() == nil
        }
    }

    @Test func tokenRotationRewritesTheRegistrationField() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        try await registerDevice()
        armWorld()
        let coordinator = makeCoordinator(defaults: defaults)
        coordinator.start()
        coordinator.agentsDidChange([agent(observedPaneID, .working)])
        try await waitUntil("the activity should start") { !controller.requestedHandles.isEmpty }
        let activityID = try #require(controller.requestedHandles.first?.id)

        controller.emitToken(id: activityID, Data([0xaa]))
        try await waitUntil("the first token should be written") {
            try await liveActivityToken() == "aa"
        }
        controller.emitToken(id: activityID, Data([0xbb]))
        try await waitUntil("a rotated token should replace the field") {
            try await liveActivityToken() == "bb"
        }
    }

    @Test func aDirtyTokenWriteRetriesAfterReconnect() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        try await registerDevice()
        armWorld()
        let coordinator = makeCoordinator(defaults: defaults)
        coordinator.start()
        coordinator.agentsDidChange([agent(observedPaneID, .working)])
        try await waitUntil("the activity should start") { !controller.requestedHandles.isEmpty }
        let activityID = try #require(controller.requestedHandles.first?.id)

        await transport.setNotificationRegistrationWriteFailure(
            .writeFailed(detail: "offline"))
        world.statuses[host.id] = .reconnecting(
            attempt: 1, delay: .seconds(1), failure: .sshUnreachable(detail: "down"))
        controller.emitToken(id: activityID, Data([0xcc]))
        try await waitPastSettle()
        #expect(try await liveActivityToken() == nil)

        await transport.setNotificationRegistrationWriteFailure(nil)
        world.statuses[host.id] = .connected
        coordinator.connectionsDidChange()
        try await waitUntil("a recovered connection should flush the dirty token") {
            try await liveActivityToken() == "cc"
        }
    }

    @Test func switchingThePreferenceOffEndsAndClears() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        try await registerDevice()
        armWorld()
        let coordinator = makeCoordinator(defaults: defaults)
        coordinator.start()
        coordinator.agentsDidChange([agent(observedPaneID, .blocked)])
        try await waitUntil("the activity should start") { !controller.requestedHandles.isEmpty }
        let activityID = try #require(controller.requestedHandles.first?.id)
        controller.emitToken(id: activityID, Data([0x11]))
        try await waitUntil("the token should be written") {
            try await liveActivityToken() == "11"
        }

        coordinator.setEnabled(false, for: host.id)
        #expect(controller.ended.count == 1)
        #expect(controller.ended[0].immediate)
        try await waitUntil("disabling should clear the registration field") {
            try await liveActivityToken() == nil
        }
    }

    // MARK: Cold launch

    @Test func startAdoptsAKnownActivityAndRewritesANewToken() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        try await registerDevice()
        armWorld()
        controller.seed(id: "act-cold", hostID: host.id)
        controller.emitToken(id: "act-cold", Data([0xee]))
        let coordinator = makeCoordinator(defaults: defaults)
        coordinator.start()
        #expect(controller.ended.isEmpty)
        #expect(controller.requested.isEmpty)

        try await waitUntil("adopting should write the current push token") {
            try await liveActivityToken() == "ee"
        }
    }

    @Test func startEndsAnOrphanActivityImmediately() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        armWorld()
        controller.seed(id: "act-orphan", hostID: UUID())
        let coordinator = makeCoordinator(defaults: defaults)
        coordinator.start()
        #expect(controller.ended.map(\.id) == ["act-orphan"])
        #expect(controller.ended[0].immediate)
    }

    /// iOS ends an activity at its 8-hour limit and leaves it on the Lock
    /// Screen, frozen, for up to 4 more hours. A launch must dismiss it, not
    /// adopt it: an ended activity takes no updates.
    @Test func launchDismissesAnExpiredActivityInsteadOfAdoptingIt() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        try await registerDevice()
        armWorld()
        controller.seed(id: "act-expired", hostID: host.id, state: .ended)
        let coordinator = makeCoordinator(defaults: defaults)
        coordinator.start()
        #expect(controller.ended.map(\.id) == ["act-expired"])
        #expect(controller.ended.first?.immediate == true)

        coordinator.agentsDidChange([agent(observedPaneID, .working)])
        try await waitUntil("a fresh activity should start") { controller.requested.count == 1 }
        #expect(!controller.updates.contains { $0.id == "act-expired" })
        #expect(controller.visibleActivityIDs == controller.requestedHandles.map(\.id))
    }

    @Test func reconnectEmptySliceDoesNotEndAnActiveActivity() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        try await registerDevice()
        armWorld()
        let coordinator = makeCoordinator(defaults: defaults)
        coordinator.start()
        coordinator.agentsDidChange([agent(observedPaneID, .working)])
        try await waitUntil("the activity should start") { !controller.requested.isEmpty }
        #expect(controller.ended.isEmpty)

        // ConsoleStore.rebuild assigns `agents` before `hostsAwaitingSnapshot`,
        // so the coordinator can see an empty slice while the hold is stale.
        coordinator.agentsDidChange([])
        world.awaitingSnapshot = [host.id]
        world.statuses[host.id] = .reconnecting(
            attempt: 1, delay: .seconds(1), failure: .sshUnreachable(detail: "down"))
        coordinator.connectionsDidChange()
        try await waitPastSettle()
        #expect(controller.ended.isEmpty, "an empty slice while reconnecting is not all-idle")

        world.awaitingSnapshot = []
        world.statuses[host.id] = .connected
        coordinator.agentsDidChange([agent(observedPaneID, .working)])
        coordinator.connectionsDidChange()
        try await waitPastSettle()
        #expect(controller.ended.isEmpty)
        #expect(controller.requested.count == 1)
    }

    @Test func emptySnapshotAfterReconnectEndsTheActivity() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        try await registerDevice()
        armWorld()
        let coordinator = makeCoordinator(defaults: defaults)
        coordinator.start()
        coordinator.agentsDidChange([agent(observedPaneID, .working)])
        try await waitUntil("the activity should start") { !controller.requested.isEmpty }

        coordinator.agentsDidChange([])
        world.awaitingSnapshot = [host.id]
        world.statuses[host.id] = .reconnecting(
            attempt: 1, delay: .seconds(1), failure: .sshUnreachable(detail: "down"))
        coordinator.connectionsDidChange()
        try await waitPastSettle()
        #expect(controller.ended.isEmpty)

        world.awaitingSnapshot = []
        world.statuses[host.id] = .connected
        coordinator.connectionsDidChange()
        try await waitUntil("an empty post-reconnect snapshot should end") {
            !controller.ended.isEmpty
        }
    }

    @Test func doesNotEndAnAdoptedActivityBeforeTheFirstSnapshot() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        try await registerDevice()
        armWorld()
        world.awaitingSnapshot = [host.id]
        controller.seed(id: "act-hold", hostID: host.id)
        let coordinator = makeCoordinator(defaults: defaults)
        coordinator.start()
        coordinator.agentsDidChange([])
        try await waitPastSettle()
        #expect(controller.ended.isEmpty)

        world.awaitingSnapshot = []
        coordinator.connectionsDidChange()
        try await waitUntil("an empty snapshot should end once it arrives") {
            !controller.ended.isEmpty
        }
        #expect(controller.ended[0].id == "act-hold")
    }

    @Test func dismissalWhileForegroundedClearsTheRegistrationField() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        try await registerDevice()
        armWorld()
        let coordinator = makeCoordinator(defaults: defaults)
        coordinator.start()
        coordinator.agentsDidChange([agent(observedPaneID, .working)])
        try await waitUntil("the activity should start") { !controller.requestedHandles.isEmpty }
        let activityID = try #require(controller.requestedHandles.first?.id)
        controller.emitToken(id: activityID, Data([0xdd]))
        try await waitUntil("the token should be written") {
            try await liveActivityToken() == "dd"
        }

        controller.emitState(id: activityID, .dismissed)
        try await waitUntil("a foreground dismissal should drop the field") {
            try await liveActivityToken() == nil
        }
        coordinator.reconcile()
        try await waitPastSettle()
        #expect(controller.requested.count == 1, "the same desire must not restart")
    }

    /// The duplicate seen on a Lock Screen: last night's activity, ended by
    /// iOS at its 8-hour limit, stayed beside the one the app started on
    /// its return.
    @Test func anExpiredActivityIsDismissedNotLeftBesideItsReplacement() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        try await registerDevice()
        armWorld()
        let coordinator = makeCoordinator(defaults: defaults)
        coordinator.start()
        coordinator.agentsDidChange([agent(observedPaneID, .working)])
        try await waitUntil("the activity should start") { !controller.requestedHandles.isEmpty }
        let expired = try #require(controller.requestedHandles.first?.id)

        controller.emitState(id: expired, .ended)
        coordinator.agentsDidChange([agent(observedPaneID, .done)])
        try await waitUntil("a fresh activity should replace the expired one") {
            controller.requestedHandles.count == 2
        }
        #expect(
            controller.ended.contains { $0.id == expired && $0.immediate },
            "the expired activity must be dismissed, not left beside its replacement")
        #expect(controller.visibleActivityIDs == controller.requestedHandles.dropFirst().map(\.id))
    }

    @Test func foregroundReturnDismissesAnActivityThatExpiredWhileSuspended() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        try await registerDevice()
        armWorld()
        let coordinator = makeCoordinator(defaults: defaults)
        coordinator.start()
        coordinator.agentsDidChange([agent(observedPaneID, .working)])
        try await waitUntil("the activity should start") { !controller.requestedHandles.isEmpty }
        let expired = try #require(controller.requestedHandles.first?.id)

        controller.setStateSilently(id: expired, .ended)
        coordinator.reconcile()
        #expect(controller.ended.contains { $0.id == expired && $0.immediate })
        try await waitUntil("the same Agents should get a fresh activity") {
            controller.requestedHandles.count == 2
        }
        #expect(controller.visibleActivityIDs == controller.requestedHandles.dropFirst().map(\.id))
    }

    @Test func layoutChangesUpdateActivityAndRetryBackgroundRegistration() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        try await registerDevice()
        armWorld()
        world.layout = AgentRowLayout(rows: [[.init(.host)]])
        let coordinator = makeCoordinator(defaults: defaults)
        coordinator.start()
        coordinator.agentsDidChange([agent(observedPaneID, .working)])
        try await waitUntil("the activity should start") { !controller.requestedHandles.isEmpty }
        let activityID = try #require(controller.requestedHandles.first?.id)
        controller.emitToken(id: activityID, Data([0xab]))
        try await waitUntil("the initial layout should be registered") {
            let file = try NotificationRegistrationFile.decode(await transport.notificationRegistration)
            return file.devices.first?["live_activity"]?["row_layout"] != nil
        }
        let initialFile = try NotificationRegistrationFile.decode(await transport.notificationRegistration)
        #expect(initialFile.devices.first?["live_activity"]?["host_name"] == .string("mbp"))

        await transport.setNotificationRegistrationWriteFailure(.writeFailed(detail: "offline"))
        world.layout = AgentRowLayout(rows: [[.init(.status, dim: true)]])
        coordinator.layoutsDidChange()
        try await waitUntil("layout-only edits should refresh the activity") { !controller.updates.isEmpty }
        let envelope = try #require(controller.updates.last?.content.envelope)
        let details = try AgentActivityEnvelope.open(
            try JSONEncoder().encode(envelope), using: notificationKey())
        #expect(details.agents.first?.rows == [[.init(text: "Working", dim: true)]])
        await transport.setNotificationRegistrationWriteFailure(nil)
        coordinator.connectionsDidChange()
        try await waitUntil("reconnection should retry the latest layout") {
            let file = try NotificationRegistrationFile.decode(await transport.notificationRegistration)
            guard case .array(let rows)? = file.devices.first?["live_activity"]?["row_layout"]?["rows"],
                  case .array(let fields)? = rows.first else { return false }
            return fields.first?["token"] == .string("status")
        }
        #expect(try await liveActivityToken() == "ab")
    }

    // MARK: Pins

    @Test func pinToggleRebuildsOrderAndWritesPinnedPaneIDs() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let (pinDefaults, pinCleanup) = try makeDefaults()
        defer { pinCleanup() }
        try await registerDevice()
        armWorld()
        let pins = PinnedAgentsStore(defaults: pinDefaults)
        let coordinator = makeCoordinator(defaults: defaults, pins: pins)
        coordinator.start()
        coordinator.agentsDidChange([
            agent("w:p-work", .working),
            agent("w:p-block", .blocked),
        ])
        try await waitUntil("the activity should start") { !controller.requested.isEmpty }
        #expect(try openedPaneIDs(controller.requested[0]) == ["w:p-block", "w:p-work"])
        #expect(controller.requested[0].counts == .init(working: 1, blocked: 1, done: 0))

        let activityID = try #require(controller.requestedHandles.first?.id)
        controller.emitToken(id: activityID, Data([0xab]))
        try await waitUntil("the token should be written") {
            try await liveActivityToken() == "ab"
        }
        #expect(try await filePinnedPaneIDs() == [])

        pins.togglePin(hostID: host.id, paneID: "w:p-work")
        coordinator.pinsDidChange()
        try await waitUntil("a pin toggle should reorder the lock-screen rows") {
            controller.updates.count == 1
        }
        #expect(try openedPaneIDs(controller.updates[0].content) == ["w:p-work", "w:p-block"])
        #expect(controller.updates[0].content.counts == .init(working: 1, blocked: 1, done: 0))
        try await waitUntil("the Host should receive the new pin list") {
            try await filePinnedPaneIDs() == ["w:p-work"]
        }
        #expect(controller.requested.count == 1)
        #expect(controller.ended.isEmpty)
    }

    @Test func pinningAnIneligibleAgentLeavesRowsAndUpdatesTheFile() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let (pinDefaults, pinCleanup) = try makeDefaults()
        defer { pinCleanup() }
        try await registerDevice()
        armWorld()
        let pins = PinnedAgentsStore(defaults: pinDefaults)
        let coordinator = makeCoordinator(defaults: defaults, pins: pins)
        coordinator.start()
        coordinator.agentsDidChange([
            agent("w:p-work", .working),
            agent("w:p-idle", .idle),
        ])
        try await waitUntil("the activity should start") { !controller.requestedHandles.isEmpty }
        let activityID = try #require(controller.requestedHandles.first?.id)
        controller.emitToken(id: activityID, Data([0x11]))
        try await waitUntil("the token should be written") {
            try await liveActivityToken() == "11"
        }

        pins.togglePin(hostID: host.id, paneID: "w:p-idle")
        coordinator.pinsDidChange()
        try await waitPastSettle()
        #expect(controller.updates.isEmpty, "ineligible pins must not change LA rows")
        try await waitUntil("the Host should still receive the pin list") {
            try await filePinnedPaneIDs() == ["w:p-idle"]
        }
    }

    @Test func pinToggleWhileOfflineDoesNotWriteUntilTheNextTokenWrite() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let (pinDefaults, pinCleanup) = try makeDefaults()
        defer { pinCleanup() }
        try await registerDevice()
        armWorld()
        let pins = PinnedAgentsStore(defaults: pinDefaults)
        let coordinator = makeCoordinator(defaults: defaults, pins: pins)
        coordinator.start()
        coordinator.agentsDidChange([
            agent("w:p-work", .working),
            agent("w:p-block", .blocked),
        ])
        try await waitUntil("the activity should start") { !controller.requestedHandles.isEmpty }
        let activityID = try #require(controller.requestedHandles.first?.id)
        controller.emitToken(id: activityID, Data([0xaa]))
        try await waitUntil("the first token should be written") {
            try await liveActivityToken() == "aa"
        }

        world.statuses[host.id] = .reconnecting(
            attempt: 1, delay: .seconds(1), failure: .sshUnreachable(detail: "down"))
        pins.togglePin(hostID: host.id, paneID: "w:p-work")
        coordinator.pinsDidChange()
        try await waitPastSettle()
        #expect(try await filePinnedPaneIDs() == [])

        world.statuses[host.id] = .connected
        controller.emitToken(id: activityID, Data([0xbb]))
        try await waitUntil("the next live_activity write should carry current pins") {
            let token = try await liveActivityToken()
            let pins = try await filePinnedPaneIDs()
            return token == "bb" && pins == ["w:p-work"]
        }
    }

    // MARK: Push-to-start

    private func startRegistration() async throws -> JSONValue? {
        try NotificationRegistrationFile.decode(await transport.notificationRegistration)
            .devices.first?["live_activity_start"]
    }

    @Test func aPushStartedActivityIsAdoptedInsteadOfRequested() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        try await registerDevice()
        armWorld()
        let coordinator = makeCoordinator(defaults: defaults)
        coordinator.start()

        controller.announce(id: "act-pushed", hostID: host.id)
        coordinator.agentsDidChange([agent(observedPaneID, .working)])
        try await waitUntil("the pushed activity should receive the settled content") {
            controller.updates.contains { $0.id == "act-pushed" }
        }
        try await waitPastSettle()
        #expect(controller.requested.isEmpty, "a pushed activity must not be duplicated")
        #expect(controller.ended.isEmpty)

        controller.emitToken(id: "act-pushed", Data([0x5a]))
        try await waitUntil("the pushed activity's update token should reach the Host") {
            try await liveActivityToken() == "5a"
        }
    }

    @Test func aLocalStartAdoptsAPushedActivityNotYetAnnounced() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        try await registerDevice()
        armWorld()
        let coordinator = makeCoordinator(defaults: defaults)
        coordinator.start()

        controller.seed(id: "act-pushed", hostID: host.id)
        coordinator.agentsDidChange([agent(observedPaneID, .blocked)])
        try await waitUntil("the settle should update the existing activity") {
            controller.updates.contains { $0.id == "act-pushed" }
        }
        #expect(controller.requested.isEmpty)
        #expect(controller.ended.isEmpty)
        #expect(controller.updates.last?.content.counts == .init(working: 0, blocked: 1, done: 0))
    }

    @Test func aPushedActivitySupersedesTheLocalOneForTheSameHost() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        try await registerDevice()
        armWorld()
        let coordinator = makeCoordinator(defaults: defaults)
        coordinator.start()
        coordinator.agentsDidChange([agent(observedPaneID, .working)])
        try await waitUntil("the activity should start") { !controller.requestedHandles.isEmpty }
        let localID = try #require(controller.requestedHandles.first?.id)
        controller.emitToken(id: localID, Data([0x11]))
        try await waitUntil("the local token should be written") {
            try await liveActivityToken() == "11"
        }

        controller.announce(id: "act-pushed", hostID: host.id)
        try await waitUntil("the older local activity should end") {
            controller.ended.map(\.id) == [localID]
        }
        try await waitUntil("the ended activity's token should be withdrawn") {
            try await liveActivityToken() == nil
        }
        controller.emitToken(id: "act-pushed", Data([0x22]))
        try await waitUntil("the newest activity's token should be written") {
            try await liveActivityToken() == "22"
        }

        coordinator.agentsDidChange([agent(observedPaneID, .blocked)])
        try await waitUntil("later changes should update the adopted activity") {
            controller.updates.last?.id == "act-pushed"
                && controller.updates.last?.content.counts.blocked == 1
        }
        #expect(controller.requested.count == 1)
    }

    @Test func startKeepsOnlyTheNewestActivityForAHost() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        try await registerDevice()
        armWorld()
        controller.seed(id: "act-old", hostID: host.id)
        controller.seed(id: "act-new", hostID: host.id)
        controller.emitToken(id: "act-new", Data([0x33]))
        let coordinator = makeCoordinator(defaults: defaults)
        coordinator.agentsDidChange([agent(observedPaneID, .done)])
        coordinator.start()

        #expect(controller.ended.map(\.id) == ["act-old"])
        try await waitUntil("the newest activity's token should be written") {
            try await liveActivityToken() == "33"
        }
        try await waitUntil("the kept activity should receive content") {
            controller.updates.contains { $0.id == "act-new" }
        }
        #expect(controller.requested.isEmpty)
    }

    @Test func pushToStartTokenFollowsRotationAndThePerHostToggle() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        try await registerDevice()
        armWorld()
        let coordinator = makeCoordinator(defaults: defaults)
        coordinator.start()

        controller.emitPushToStartToken(Data([0xf0, 0x0d]))
        try await waitUntil("the push-to-start token should reach the Host") {
            try await startRegistration()?["token"] == .string("f00d")
        }
        #expect(try await startRegistration()?["host_id"] == .string(host.id.uuidString))

        controller.emitPushToStartToken(Data([0xbe, 0xef]))
        try await waitUntil("a rotated push-to-start token should replace the field") {
            try await startRegistration()?["token"] == .string("beef")
        }

        coordinator.setEnabled(false, for: host.id)
        try await waitUntil("switching the Host off should withdraw the push-to-start token") {
            try await startRegistration() == nil
        }
        let file = try NotificationRegistrationFile.decode(await transport.notificationRegistration)
        #expect(file.containsDevice(token: token.hex), "the alert registration must survive")

        coordinator.setEnabled(true, for: host.id)
        try await waitUntil("switching the Host back on should offer the token again") {
            try await startRegistration()?["token"] == .string("beef")
        }
    }

    // MARK: One computer, two Host entries

    @Test func entriesThatTrustTheSameHostKeyShareOneActivity() {
        let tailscale = Host.fixture(name: "Personal", address: "mbp.tailnet.example", username: "z")
        let lan = Host.fixture(name: "Personal", address: "192.168.1.91", username: "z")
        let other = Host.fixture(name: "Devbox", address: "192.168.1.33", username: "z")
        let fresh = Host.fixture(name: "New", address: "new.local", username: "z")
        let digests: [String: Set<Data>] = [
            tailscale.address: [Data([1])], lan.address: [Data([1])], other.address: [Data([2])],
        ]
        let hosts = [lan, tailscale, other, fresh]

        let byCatalog = HostLiveActivityCoordinator.activityHostIDs(
            enabledHosts: hosts, isPreferred: { _ in true }, digests: { digests[$0.address] ?? [] })
        #expect(byCatalog == [lan.id, other.id, fresh.id])

        let byPreference = HostLiveActivityCoordinator.activityHostIDs(
            enabledHosts: hosts, isPreferred: { $0 != lan.id },
            digests: { digests[$0.address] ?? [] })
        #expect(byPreference == [tailscale.id, other.id, fresh.id])

        // One entry trusts two key types, which two others split between them.
        let both = Host.fixture(name: "Personal", address: "mbp.local", username: "z")
        let split: [String: Set<Data>] = [
            lan.address: [Data([1])], both.address: [Data([1]), Data([3])],
            tailscale.address: [Data([3])],
        ]
        let chained = [lan, tailscale, both]
        #expect(
            HostLiveActivityCoordinator.activityHostIDs(
                enabledHosts: chained, isPreferred: { _ in true },
                digests: { split[$0.address] ?? [] }) == [lan.id])
        #expect(
            HostLiveActivityCoordinator.computerHostIDs(
                of: tailscale.id, among: chained, digests: { split[$0.address] ?? [] })
                == [lan.id, tailscale.id, both.id])
        #expect(
            HostLiveActivityCoordinator.computerHostIDs(
                of: fresh.id, among: hosts, digests: { digests[$0.address] ?? [] }) == [fresh.id])
    }

    /// A ceremony through one entry holds every entry for its computer, so
    /// another through either entry waits for it, even after the catalog
    /// drops the entry the first one grouped under.
    @Test func ceremoniesForOneComputerNeverOverlapAcrossACatalogChange() async throws {
        let lan = UUID()
        let catalog = CatalogStandIn(entries: [host.id, lan])
        let writer = NotificationRegistrationWriter(
            transports: ScriptedTransportProvider(transports: [host.id: transport, lan: transport]),
            computer: { _ in await catalog.entries })
        let gate = ScriptedTransportCallGate()
        await transport.gateNextNotificationRegistrationRead(gate)
        let first = Task {
            try await writer.withNotificationTransport(for: lan) {
                try await $0.readNotificationRegistration()
            }
        }
        await gate.waitForEntry()
        await catalog.set([lan])
        let entered = CatalogStandIn(entries: [])
        let second = Task {
            try await writer.withNotificationTransport(for: lan) { _ in await entered.set([lan]) }
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await entered.entries.isEmpty)

        await gate.open()
        _ = try await first.value
        try await second.value
        #expect(await entered.entries == [lan])
    }

    /// The entry that showed the computer went offline, then the other entry
    /// took over: the offline one's activity ends at once, never beside it.
    @Test func anOfflineEntryThatStopsShowingTheComputerEndsAtOnce() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let (coordinator, lan) = try await makeAliasCoordinator(defaults: defaults)
        world.knownHostIDs = [lan.id]
        coordinator.start()
        coordinator.agentsDidChange([
            ConsoleAgent(
                hostID: lan.id, hostName: "mbp-lan", agent: agent(observedPaneID, .working).agent,
                workspaceLabel: nil, repositoryCheckout: nil),
        ])
        try await waitUntil("the LAN entry should start") { !controller.requestedHandles.isEmpty }
        let lanActivity = try #require(controller.requestedHandles.first?.id)
        world.statuses[lan.id] = .reconnecting(
            attempt: 1, delay: .seconds(1), failure: .sshUnreachable(detail: "away"))
        world.awaitingSnapshot = [lan.id]
        coordinator.connectionsDidChange()

        world.knownHostIDs = [host.id]
        coordinator.setEnabled(true, for: host.id)
        #expect(controller.ended.contains { $0.id == lanActivity && $0.immediate })
        coordinator.agentsDidChange([agent(observedPaneID, .working)])
        try await waitUntil("the first entry should start") { controller.requestedHandles.count == 2 }
        #expect(controller.visibleActivityIDs == [controller.requestedHandles[1].id])
    }

    /// A second, connected entry for `host`'s computer, registered on the same
    /// file, and a coordinator whose ceremonies queue per computer as the
    /// app's writer does. Only `host` is shown until the test says otherwise.
    private func makeAliasCoordinator(
        defaults: UserDefaults
    ) async throws -> (HostLiveActivityCoordinator, lan: Host) {
        let lan = Host.fixture(name: "mbp-lan", address: "192.168.1.91", username: "z")
        try await registerDevice()
        try await NotificationRegistrationCeremony(keys: NotificationKeyStore(secrets: secrets))
            .register(hostID: lan.id, hostName: "mbp-lan", deviceToken: token, over: transport)
        armWorld()
        world.hostNames[lan.id] = "mbp-lan"
        world.statuses[lan.id] = .connected
        let computer: Set<Host.ID> = [host.id, lan.id]
        let coordinator = makeCoordinator(
            defaults: defaults,
            transports: NotificationRegistrationWriter(
                transports: ScriptedTransportProvider(transports: [host.id: transport, lan.id: transport]),
                computer: { _ in computer }))
        coordinator.setEnabled(true, for: lan.id)
        return (coordinator, lan)
    }

    /// Two entries for one Mac (Tailscale name and LAN address) share its
    /// registration file and this device's one entry in it. Only the entry
    /// that shows the computer gets an activity, and the other one's
    /// toggle never takes back what the shown one registered.
    @Test func aSecondEntryForTheSameComputerNeitherShowsNorClearsTheFirst() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let (coordinator, lan) = try await makeAliasCoordinator(defaults: defaults)
        coordinator.start()
        controller.emitPushToStartToken(Data([0xf0, 0x0d]))
        try await waitUntil("the shown entry should offer push-to-start") {
            try await startRegistration()?["host_id"] == .string(host.id.uuidString)
        }

        let sameAgent = agent(observedPaneID, .working)
        let sameAgentViaLAN = ConsoleAgent(
            hostID: lan.id, hostName: "mbp-lan", agent: sameAgent.agent,
            workspaceLabel: nil, repositoryCheckout: nil)
        coordinator.agentsDidChange([sameAgent, sameAgentViaLAN])
        try await waitUntil("the shown entry should start its activity") {
            !controller.requestedHandles.isEmpty
        }
        let activityID = try #require(controller.requestedHandles.first?.id)
        controller.emitToken(id: activityID, Data([0xaa]))
        try await waitUntil("its token should land on the computer") {
            try await liveActivityToken() == "aa"
        }
        try await waitPastSettle()
        #expect(controller.requestedHandles.map(\.hostID) == [host.id])

        coordinator.setEnabled(false, for: lan.id)
        try await waitPastSettle()
        #expect(try await liveActivityToken() == "aa")
        #expect(try await startRegistration()?["host_id"] == .string(host.id.uuidString))
        #expect(controller.visibleActivityIDs == [activityID])
    }

    /// Live Activities off, on, then off again on the first entry: each time
    /// the computer's push-to-start offer names whichever entry shows it.
    @Test func thePushToStartOfferFollowsWhicheverEntryShowsTheComputer() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let (coordinator, lan) = try await makeAliasCoordinator(defaults: defaults)
        coordinator.start()
        controller.emitPushToStartToken(Data([0xf0, 0x0d]))
        let steps: [(shown: Host, toggled: Bool?)] = [
            (host, nil), (lan, false), (host, true), (lan, false),
        ]
        for (shown, toggled) in steps {
            if let toggled {
                world.knownHostIDs = [shown.id]
                coordinator.setEnabled(toggled, for: host.id)
            }
            try await waitUntil("the offer should name \(shown.name)") {
                try await startRegistration()?["host_id"] == .string(shown.id.uuidString)
            }
        }
    }
}

/// A set of Host entries a test changes while a ceremony runs.
private actor CatalogStandIn {
    private(set) var entries: Set<Host.ID>
    init(entries: Set<Host.ID>) { self.entries = entries }
    func set(_ entries: Set<Host.ID>) { self.entries = entries }
}
