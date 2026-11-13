import Foundation
import Testing

@testable import Waycar

/// `NotificationTransportProvider` double: hands each Host's scripted (or
/// real, in the e2e suite) Transport to the operation. Hosts without one are
/// unreachable, exactly like a Console projection that never connected — and
/// a Host can be cut off mid-test, like a connection dropping between the
/// settings screen loading and a toggle.
actor ScriptedTransportProvider: NotificationTransportProvider {
    private var transports: [Host.ID: any Transport]

    init(transports: [Host.ID: any Transport]) {
        self.transports = transports
    }

    func setTransport(_ transport: (any Transport)?, for hostID: Host.ID) {
        transports[hostID] = transport
    }

    func withNotificationTransport<Value: Sendable>(
        for hostID: Host.ID,
        _ operation: @escaping @Sendable (any Transport) async throws -> Value
    ) async throws -> Value {
        guard let transport = transports[hostID] else {
            throw TransportError.sshUnreachable(detail: "The Host is not connected.")
        }
        return try await operation(transport)
    }
}

/// The AI summaries choice plus a one-shot action run on the main actor when
/// the next Host borrow starts, so a test can change the choice while a
/// registration is in flight.
@MainActor
final class RegistrationHook {
    var choice = true
    var onNextBorrow: (@MainActor () async -> Void)?

    func runPendingAction() async {
        guard let action = onNextBorrow else { return }
        onNextBorrow = nil
        await action()
    }
}

struct HookedTransportProvider: NotificationTransportProvider {
    let transport: any Transport
    let hook: RegistrationHook

    func withNotificationTransport<Value: Sendable>(
        for hostID: Host.ID,
        _ operation: @escaping @Sendable (any Transport) async throws -> Value
    ) async throws -> Value {
        await hook.runPendingAction()
        return try await operation(transport)
    }
}

@MainActor
@Suite("Notification preferences store")
struct NotificationPreferencesStoreTests {
    private let host = Host(name: "mac-studio", address: "10.0.0.2", username: "z")
    private let token = APNSDeviceToken(hex: "0a1b2c3d", environment: .sandbox)
    private let secrets = InMemorySecretStore()
    private var keys: NotificationKeyStore { NotificationKeyStore(secrets: secrets) }

    private func makeStore(
        provider: ScriptedTransportProvider,
        deviceToken: APNSDeviceToken?
    ) -> NotificationPreferencesStore {
        let store = NotificationPreferencesStore(
            transports: provider,
            deviceToken: { deviceToken },
            ceremony: NotificationRegistrationCeremony(keys: keys))
        store.setHosts([host])
        return store
    }

    private func makeStore(
        transport: any Transport,
        deviceToken: APNSDeviceToken? = nil
    ) -> NotificationPreferencesStore {
        makeStore(
            provider: ScriptedTransportProvider(transports: [host.id: transport]),
            deviceToken: deviceToken ?? token)
    }

    private func makeStore(
        transport: any Transport,
        relayBaseURL: @escaping @MainActor () -> URL?
    ) -> NotificationPreferencesStore {
        let store = NotificationPreferencesStore(
            transports: ScriptedTransportProvider(transports: [host.id: transport]),
            deviceToken: { self.token },
            relayBaseURL: relayBaseURL,
            ceremony: NotificationRegistrationCeremony(keys: keys))
        store.setHosts([host])
        return store
    }

    // MARK: Reflecting the Host's truth

    @Test func refreshReflectsAnUnregisteredHost() async throws {
        let store = makeStore(transport: ScriptedTransport())

        await store.refresh()

        #expect(
            store.states[host.id]
                == .idle(
                    .init(isRegistered: false, notify: NotificationTriggerPreferences())))
    }

    @Test func refreshReflectsThisDevicesEntryFlags() async throws {
        let transport = ScriptedTransport()
        await transport.setNotificationRegistration(
            Data(
                (#"{"v":1,"devices":[{"token":"\#(token.hex)","key":"kk","env":"sandbox","#
                    + #""notify":{"blocked":true,"done":false}}]}"#).utf8))
        let store = makeStore(transport: transport)

        await store.refresh()

        #expect(
            store.states[host.id]
                == .idle(
                    .init(
                        isRegistered: true,
                        notify: NotificationTriggerPreferences(blocked: true, done: false))))
        #expect(await transport.replacedNotificationRegistrations.isEmpty)
    }

    /// Seen on a phone: a TestFlight build registered the token as
    /// production, a Debug build on the same device kept it, and APNs
    /// rejected every push to its sandbox Live Activity tokens.
    @Test func refreshReRegistersAnEntryFromTheOtherAPNsEnvironment() async throws {
        let transport = ScriptedTransport()
        await transport.setNotificationRegistration(
            Data(
                (#"{"v":1,"devices":[{"token":"\#(token.hex)","key":"kk","env":"production","#
                    + #""notify":{"blocked":true,"done":false},"#
                    + #""live_activity":{"token":"aa","started_at":"2026-11-10T13:20:46Z"}}]}"#)
                    .utf8))
        let store = makeStore(transport: transport)

        await store.refresh()

        let file = try NotificationRegistrationFile.decode(
            await transport.notificationRegistration)
        #expect(file.devices.first?["env"] == .string("sandbox"))
        #expect(
            file.preferences(token: token.hex)
                == NotificationTriggerPreferences(blocked: true, done: false))
        #expect(file.liveActivity(forDeviceToken: token.hex)?.token == "aa")
        #expect(
            store.states[host.id]
                == .idle(
                    .init(
                        isRegistered: true,
                        notify: NotificationTriggerPreferences(blocked: true, done: false))))
    }

    @Test func refreshWithoutAPushTokenIsUnavailable() async throws {
        let store = makeStore(
            provider: ScriptedTransportProvider(transports: [host.id: ScriptedTransport()]),
            deviceToken: nil)

        await store.refresh()

        guard case .unavailable = store.states[host.id] else {
            Issue.record("expected .unavailable, got \(String(describing: store.states[host.id]))")
            return
        }
    }

    @Test func refreshSurfacesAnUnreachableHost() async throws {
        let store = makeStore(
            provider: ScriptedTransportProvider(transports: [:]), deviceToken: token)

        await store.refresh()

        #expect(store.states[host.id] == .unavailable(message: "The Host is not connected."))
    }

    @Test func refreshSurfacesAMissingPlugin() async throws {
        let transport = ScriptedTransport()
        await transport.setNotificationRegistrationReadFailure(.pluginNotInstalled)
        let store = makeStore(transport: transport)

        await store.refresh()

        guard case .unavailable(let message) = store.states[host.id] else {
            Issue.record("expected .unavailable, got \(String(describing: store.states[host.id]))")
            return
        }
        #expect(
            message
                == NotificationPreferencesStore.message(
                    for: NotificationRegistrationError.pluginNotInstalled))
    }

    /// A tmux-only Host has Waycar's host tools, not the herdr plugin, so the
    /// fix names those and the one install command.
    @Test func refreshOnATmuxOnlyHostAsksForTheHostTools() async throws {
        let transport = ScriptedTransport()
        await transport.setNotificationRegistrationReadFailure(.pluginNotInstalled)
        let hostID = host.id
        let store = NotificationPreferencesStore(
            transports: ScriptedTransportProvider(transports: [host.id: transport]),
            deviceToken: { self.token },
            backendPresence: { id in
                id == hostID ? HostBackendPresence(herdr: false, tmuxVersion: "3.4") : nil
            },
            ceremony: NotificationRegistrationCeremony(keys: keys))
        store.setHosts([host])

        await store.refresh()

        let error = NotificationRegistrationError.pluginNotInstalled
        #expect(
            store.states[host.id]
                == .unavailable(message: NotificationPreferencesStore.message(for: error, hostToolsOnly: true)))
        #expect(
            store.states[host.id]
                != .unavailable(message: NotificationPreferencesStore.message(for: error, hostToolsOnly: false)))
    }

    /// herdr wording stays on any Host with herdr, tmux beside it or not.
    @Test func herdrHostsKeepThePluginWording() async throws {
        let transport = ScriptedTransport()
        await transport.setNotificationRegistrationReadFailure(.pluginNotInstalled)
        let store = NotificationPreferencesStore(
            transports: ScriptedTransportProvider(transports: [host.id: transport]),
            deviceToken: { self.token },
            backendPresence: { _ in HostBackendPresence(herdr: true, tmuxVersion: "3.4") },
            ceremony: NotificationRegistrationCeremony(keys: keys))
        store.setHosts([host])

        await store.refresh()

        #expect(
            store.states[host.id]
                == .unavailable(
                    message: NotificationPreferencesStore.message(
                        for: NotificationRegistrationError.pluginNotInstalled)))
    }

    @Test func removingAHostFromTheCatalogDropsItsState() async throws {
        let store = makeStore(transport: ScriptedTransport())
        await store.refresh()

        store.setHosts([])

        #expect(store.hosts.isEmpty)
        #expect(store.states.isEmpty)
    }

    @Test func anOlderRefreshCannotUnlockAnUpdatingHost() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport)
        let readGate = ScriptedTransportCallGate()
        await transport.gateNextNotificationRegistrationRead(readGate)
        let older = Task { await store.refresh() }
        await readGate.waitForEntry()

        await store.refresh()
        let writeGate = ScriptedTransportCallGate()
        await transport.gateNextNotificationRegistrationWrite(writeGate)
        let update = Task { await store.setNotificationsEnabled(true, for: host) }
        await writeGate.waitForEntry()
        await readGate.open()
        await older.value

        #expect(store.states[host.id] == .updating(
            .init(isRegistered: false, notify: NotificationTriggerPreferences())))
        await writeGate.open()
        await update.value
    }

    @Test func aRemovedHostCannotReturnFromAnInFlightRead() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport)
        let gate = ScriptedTransportCallGate()
        await transport.gateNextNotificationRegistrationRead(gate)
        let refresh = Task { await store.refresh() }
        await gate.waitForEntry()

        store.setHosts([])
        await gate.open()
        await refresh.value

        #expect(store.states.isEmpty)
    }

    // MARK: Per-Host on/off

    @Test func enablingRegistersTheDevice() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport)
        await store.refresh()

        await store.setNotificationsEnabled(true, for: host)

        #expect(
            store.states[host.id]
                == .idle(
                    .init(isRegistered: true, notify: NotificationTriggerPreferences())))
        let file = try NotificationRegistrationFile.decode(
            await transport.notificationRegistration)
        #expect(file.containsDevice(token: token.hex))
        #expect(try keys.record(forHost: host.id) != nil)
    }

    @Test func disablingRemovesTheDeviceEntryAndTheKey() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport)
        await store.refresh()
        await store.setNotificationsEnabled(true, for: host)

        await store.setNotificationsEnabled(false, for: host)

        #expect(
            store.states[host.id]
                == .idle(
                    .init(isRegistered: false, notify: NotificationTriggerPreferences())))
        let file = try NotificationRegistrationFile.decode(
            await transport.notificationRegistration)
        #expect(!file.containsDevice(token: token.hex))
        #expect(try keys.record(forHost: host.id) == nil)
    }

    @Test func aFailedEnableDoesNotFlipTheToggle() async throws {
        let transport = ScriptedTransport()
        await transport.setNotificationRegistrationWriteFailure(
            .writeFailed(detail: "disk full"))
        let store = makeStore(transport: transport)
        await store.refresh()

        await store.setNotificationsEnabled(true, for: host)

        guard case .failed(let message, let settings) = store.states[host.id] else {
            Issue.record("expected .failed, got \(String(describing: store.states[host.id]))")
            return
        }
        #expect(
            message
                == "Could not update notification settings on this Host. "
                + "Check the connection and try again.")
        #expect(!settings.isRegistered)
    }

    @Test(arguments: [false, true])
    func aConfigFailureReportsTheRegistrationThatActuallyLanded(doneToggle: Bool) async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport)
        await store.refresh()
        if doneToggle { await store.setNotificationsEnabled(true, for: host) }
        // Force a config change on re-registration as well as first enable.
        await transport.setNotificationConfig(nil)
        await transport.setNotificationConfigWriteFailure(.writeFailed(detail: "config is read-only"))

        if doneToggle {
            await store.setDoneEnabled(false, for: host)
        } else {
            await store.setNotificationsEnabled(true, for: host)
        }

        let file = try NotificationRegistrationFile.decode(await transport.notificationRegistration)
        #expect(file.containsDevice(token: token.hex))
        guard case .failed(_, let settings) = store.states[host.id] else {
            Issue.record("expected a failed config update with re-read settings")
            return
        }
        #expect(settings.isRegistered)
        #expect(settings.notify.done == !doneToggle)
        #expect(try keys.record(forHost: host.id) != nil)
    }

    @Test func togglingAnUnreachableHostFailsLoudlyWithoutFlipping() async throws {
        let provider = ScriptedTransportProvider(transports: [host.id: ScriptedTransport()])
        let store = makeStore(provider: provider, deviceToken: token)
        await store.refresh()
        // The Host drops off the network after the settings screen loaded.
        await provider.setTransport(nil, for: host.id)

        await store.setNotificationsEnabled(true, for: host)

        #expect(
            store.states[host.id]
                == .unavailable(message: "The Host is not connected."))
    }

    @Test func disablingAgainstAMissingPluginSurfacesAndKeepsTheKey() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport)
        await store.refresh()
        await store.setNotificationsEnabled(true, for: host)
        // The plugin was uninstalled on the Host after registration; `remove`
        // throws pluginNotInstalled and keeps the local key by design (#72).
        await transport.setNotificationRegistrationReadFailure(.pluginNotInstalled)

        await store.setNotificationsEnabled(false, for: host)

        guard case .unavailable(let message) = store.states[host.id] else {
            Issue.record("expected .unavailable, got \(String(describing: store.states[host.id]))")
            return
        }
        #expect(message.localizedCaseInsensitiveContains("plugin"))
        #expect(try keys.record(forHost: host.id) != nil)
    }

    @Test func togglingToTheCurrentValueWritesNothing() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport)
        await store.refresh()

        await store.setNotificationsEnabled(false, for: host)

        #expect(await transport.replacedNotificationRegistrations.isEmpty)
    }

    @Test func enablingWritesTheCustomRelayURLIntoNotifyConfig() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(
            transport: transport,
            relayBaseURL: { URL(string: "https://relay.example.com") })
        await store.refresh()

        await store.setNotificationsEnabled(true, for: host)

        let written = try #require(await transport.notificationConfig)
        let config = try NotificationConfigFile.decode(written)
        #expect(config.relayURL == "https://relay.example.com")
    }

    @Test func enablingWithNoCustomRelayWritesTheProductionRelay() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, relayBaseURL: { nil })
        await store.refresh()

        await store.setNotificationsEnabled(true, for: host)

        let written = try #require(await transport.notificationConfig)
        let config = try NotificationConfigFile.decode(written)
        #expect(config.relayURL == "https://waycar-apns.otreva.com")
    }

    // MARK: AI summaries setting

    private func summaryEnabled(on transport: ScriptedTransport) async throws -> Bool? {
        try NotificationConfigFile.decode(await transport.notificationConfig).summaryEnabled
    }

    /// The setting reaches every Host's `notify.json` whether or not this
    /// device registered for notifications there: turning it off has to
    /// stop Host-side generation with notifications off too.
    @Test func theSummarySettingReachesAHostWithoutNotificationRegistration() async throws {
        let transport = ScriptedTransport()
        await transport.setNotificationConfig(Data(#"{"summary_enabled":true}"#.utf8))
        let store = makeStore(
            provider: ScriptedTransportProvider(transports: [host.id: transport]),
            deviceToken: nil)

        await store.applySummaryChoice()
        #expect(try await summaryEnabled(on: transport) == false)
        #expect(await transport.notificationRegistration == nil)
    }

    @Test func theSummaryChoiceReachesAHostOnceItConnects() async throws {
        let transport = ScriptedTransport()
        await transport.setNotificationConfig(Data(#"{"debounce_ms":2000}"#.utf8))
        let provider = ScriptedTransportProvider(transports: [:])
        var choice = true
        let store = NotificationPreferencesStore(
            transports: provider, deviceToken: { self.token },
            summariesEnabled: { choice },
            ceremony: NotificationRegistrationCeremony(keys: keys))
        store.setHosts([host])

        await store.applySummaryChoice()
        #expect(await transport.replacedNotificationConfigs.isEmpty)

        await provider.setTransport(transport, for: host.id)
        await store.applySummaryChoice()
        #expect(try await summaryEnabled(on: transport) == true)
        let written = try #require(await transport.notificationConfig)
        let object = try #require(
            try JSONSerialization.jsonObject(with: written) as? [String: Any])
        #expect(object["debounce_ms"] as? Int == 2000)

        // Confirmed: later connection changes do not rewrite it.
        await store.applySummaryChoice()
        #expect(await transport.replacedNotificationConfigs.count == 1)

        choice = false
        await store.applySummaryChoice()
        #expect(try await summaryEnabled(on: transport) == false)
    }

    @Test func aChangedSummaryChoiceJoinsTheOldWriteThenReplays() async throws {
        let transport = ScriptedTransport()
        let gate = ScriptedTransportCallGate()
        await transport.gateNextNotificationConfigRead(gate)
        var choice = true
        let store = NotificationPreferencesStore(
            transports: ScriptedTransportProvider(transports: [host.id: transport]),
            deviceToken: { self.token }, summariesEnabled: { choice },
            ceremony: NotificationRegistrationCeremony(keys: keys))
        store.setHosts([host])
        let first = Task { await store.applySummaryChoice() }
        await gate.waitForEntry()
        choice = false
        var joining = false
        let second = Task {
            joining = true
            await store.applySummaryChoice()
        }
        try await waitUntil { joining }
        await gate.open()
        await first.value
        await second.value

        #expect(try await summaryEnabled(on: transport) == false)
        #expect(await transport.replacedNotificationConfigs.count == 2)
    }

    @Test func registeringCarriesTheSummaryChoice() async throws {
        let transport = ScriptedTransport()
        let store = NotificationPreferencesStore(
            transports: ScriptedTransportProvider(transports: [host.id: transport]),
            deviceToken: { self.token },
            summariesEnabled: { true },
            ceremony: NotificationRegistrationCeremony(keys: keys))
        store.setHosts([host])
        await store.refresh()

        await store.setNotificationsEnabled(true, for: host)

        #expect(try await summaryEnabled(on: transport) == true)
        // Relay and choice land in one read-merge-write.
        #expect(await transport.replacedNotificationConfigs.count == 1)
        let config = try NotificationConfigFile.decode(await transport.notificationConfig)
        #expect(config.relayURL == "https://waycar-apns.otreva.com")
    }

    @Test func aChoiceTurnedOffDuringRegistrationStillReachesTheHost() async throws {
        let transport = ScriptedTransport()
        let hook = RegistrationHook()
        let provider = HookedTransportProvider(transport: transport, hook: hook)
        let store = NotificationPreferencesStore(
            transports: provider, deviceToken: { self.token },
            summariesEnabled: { hook.choice },
            ceremony: NotificationRegistrationCeremony(keys: keys))
        store.setHosts([host])
        await store.refresh()

        // The registration has already read `true` when the user turns the
        // choice off; applying it then skips the Host being registered.
        hook.onNextBorrow = {
            hook.choice = false
            await store.applySummaryChoice()
        }
        await store.setNotificationsEnabled(true, for: host)

        #expect(try await summaryEnabled(on: transport) == false)
    }

    // MARK: Done flag

    @Test func doneToggleRewritesTheFlagOverSSH() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport)
        await store.refresh()
        await store.setNotificationsEnabled(true, for: host)
        let keyBefore = try #require(try keys.record(forHost: host.id)).key

        await store.setDoneEnabled(false, for: host)

        #expect(
            store.states[host.id]
                == .idle(
                    .init(
                        isRegistered: true,
                        notify: NotificationTriggerPreferences(blocked: true, done: false))))
        let file = try NotificationRegistrationFile.decode(
            await transport.notificationRegistration)
        let entry = try #require(
            file.devices.first { $0["token"]?.stringValue == token.hex })
        #expect(entry["notify"]?["done"] == .bool(false))
        #expect(entry["notify"]?["blocked"] == .bool(true))
        // Rewriting a flag must not rotate the Notification Key.
        #expect(try keys.record(forHost: host.id)?.key == keyBefore)
    }

    @Test func aFailedDoneToggleStaysOnTheConfirmedValue() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport)
        await store.refresh()
        await store.setNotificationsEnabled(true, for: host)
        await transport.setNotificationRegistrationWriteFailure(
            .writeFailed(detail: "read-only"))

        await store.setDoneEnabled(false, for: host)

        guard case .failed(_, let settings) = store.states[host.id] else {
            Issue.record("expected .failed, got \(String(describing: store.states[host.id]))")
            return
        }
        // Not flipped: the Host still holds done=true, so the UI must too.
        #expect(settings.notify.done)
        let file = try NotificationRegistrationFile.decode(
            await transport.notificationRegistration)
        let entry = try #require(
            file.devices.first { $0["token"]?.stringValue == token.hex })
        #expect(entry["notify"]?["done"] == .bool(true))
    }

    @Test func doneToggleOnAnUnregisteredHostIsIgnored() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport)
        await store.refresh()

        await store.setDoneEnabled(false, for: host)

        #expect(await transport.replacedNotificationRegistrations.isEmpty)
        #expect(
            store.states[host.id]
                == .idle(
                    .init(isRegistered: false, notify: NotificationTriggerPreferences())))
    }

    // MARK: Confirmed triggers for the in-app banner (#77)

    @Test func confirmedTriggersOfARegisteredHostAreItsFlags() async throws {
        let transport = ScriptedTransport()
        await transport.setNotificationRegistration(
            Data(
                (#"{"v":1,"devices":[{"token":"\#(token.hex)","key":"kk","env":"sandbox","#
                    + #""notify":{"blocked":true,"done":false}}]}"#).utf8))
        let store = makeStore(transport: transport)
        await store.refresh()

        #expect(
            store.confirmedTriggers(for: host.id)
                == NotificationTriggerPreferences(blocked: true, done: false))
    }

    @Test func confirmedTriggersOfAnUnregisteredHostAreNil() async throws {
        let store = makeStore(transport: ScriptedTransport())
        await store.refresh()

        #expect(store.confirmedTriggers(for: host.id) == nil)
    }

    /// Fail closed: before any refresh, and while the Host is unreachable,
    /// there is no confirmed truth to banner from.
    @Test func confirmedTriggersAreNilWhileTheHostsTruthIsUnknown() async throws {
        let provider = ScriptedTransportProvider(transports: [:])
        let store = makeStore(provider: provider, deviceToken: token)

        #expect(store.confirmedTriggers(for: host.id) == nil)

        await store.refresh()

        #expect(store.confirmedTriggers(for: host.id) == nil)
    }

    /// A failed write leaves the last confirmed truth in place, and that
    /// truth keeps gating banners.
    @Test func confirmedTriggersSurviveAFailedWrite() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport)
        await store.refresh()
        await store.setNotificationsEnabled(true, for: host)
        await transport.setNotificationRegistrationWriteFailure(
            .writeFailed(detail: "disk full"))

        await store.setDoneEnabled(false, for: host)

        #expect(
            store.confirmedTriggers(for: host.id)
                == NotificationTriggerPreferences(blocked: true, done: true))
    }
}
