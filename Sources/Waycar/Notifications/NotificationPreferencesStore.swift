import Foundation
import Observation

/// Scoped borrow of a Host's live connection for Notification Registration
/// work (#75). The Console already keeps one SSH connection per Host;
/// preference reads and writes ride it instead of dialing a second one. An
/// unreachable Host throws `TransportError` — never a silent no-op.
protocol NotificationTransportProvider: Sendable {
    func readHerdrSidebarLayout(for hostID: Host.ID) async throws -> Data?
    func withNotificationTransport<Value: Sendable>(
        for hostID: Host.ID,
        _ operation: @escaping @Sendable (any Transport) async throws -> Value
    ) async throws -> Value
}

extension NotificationTransportProvider {
    func readHerdrSidebarLayout(for hostID: Host.ID) async throws -> Data? {
        try await withNotificationTransport(for: hostID) { try await $0.readSidebarLayout() }
    }
}

/// Per-Host Agent Notification preferences (#75): the on/off registration
/// toggle and the separate Done flag, persisted in the Host's registration
/// file and filtered at the source by the plugin (the service extension
/// cannot silently drop a push). It also carries the app-wide AI summaries
/// choice into each Host's `notify.json`.
///
/// The displayed value is always the last state the Host confirmed: a toggle
/// never flips optimistically, a failed write re-reads the file before
/// reporting confirmed settings, and `refresh` shows the Host's
/// truth, not a local mirror.
@MainActor
@Observable
final class NotificationPreferencesStore {
    /// One Host's confirmed registration state, as its file last reported it.
    struct HostSettings: Equatable, Sendable {
        /// Whether this device has an entry in the Host's registration file.
        var isRegistered: Bool
        /// The entry's notify flags; meaningful only while registered.
        var notify: NotificationTriggerPreferences
    }

    enum HostState: Equatable, Sendable {
        /// The registration file read is in flight.
        case loading
        /// The Host's truth is unknown: unreachable, plugin missing, or push
        /// bootstrap incomplete. No toggle can act until a refresh succeeds.
        case unavailable(message: String)
        /// The Host answered; the toggles reflect `settings`.
        case idle(HostSettings)
        /// A preference write is in flight; `settings` stays the last
        /// confirmed truth until the Host acknowledges.
        case updating(HostSettings)
        /// A write failed; `settings` is the Host's re-read truth, which may
        /// include a registration that landed before a later config failure.
        case failed(message: String, settings: HostSettings)
    }

    private(set) var hosts: [Host] = []
    var states: [Host.ID: HostState] { preferences.displays }
    private var preferences = NotificationPreferencesMachine()

    private let transports: any NotificationTransportProvider
    private let deviceToken: @MainActor () -> APNSDeviceToken?
    /// The app-side custom Push Relay base URL, read at write time so a change
    /// in Settings lands on the next Host the user registers. `nil` — the
    /// empty/default setting — leaves each Host's `notify.json` untouched (#76).
    private let relayBaseURL: @MainActor () -> URL?
    /// The app's AI summaries setting (`AgentSummarySettings.isEnabled`),
    /// read at write time. Every Host gets it written, off as well as on.
    private let summariesEnabled: @MainActor () -> Bool
    /// Each Host's backends, so a Host with no herdr (tmux, herdr-core) is
    /// told to install Waycar's host tools instead of the herdr plugin. nil
    /// means herdr's wording.
    private let backendPresence: @MainActor (Host.ID) -> HostBackendPresence?
    private let ceremony: NotificationRegistrationCeremony
    @ObservationIgnored private var summaryReplication = SummaryChoiceReplicationMachine()
    /// Per Host, the `summary_enabled` write in flight. A registration waits
    /// it out: both rewrite `notify.json`, and interleaved read-merge-writes
    /// would drop one side's change.
    @ObservationIgnored private var summaryWrites: [UInt64: Task<Void, Never>] = [:]

    init(
        transports: any NotificationTransportProvider,
        deviceToken: @escaping @MainActor () -> APNSDeviceToken?,
        relayBaseURL: @escaping @MainActor () -> URL? = { nil },
        summariesEnabled: @escaping @MainActor () -> Bool = { false },
        backendPresence: @escaping @MainActor (Host.ID) -> HostBackendPresence? = { _ in nil },
        ceremony: NotificationRegistrationCeremony = NotificationRegistrationCeremony()
    ) {
        self.transports = transports
        self.deviceToken = deviceToken
        self.relayBaseURL = relayBaseURL
        self.summariesEnabled = summariesEnabled
        self.backendPresence = backendPresence
        self.ceremony = ceremony
    }

    /// Aligns with the Host catalog; a removed Host drops its state.
    func setHosts(_ hosts: [Host]) {
        self.hosts = hosts
        let known = Set(hosts.map(\.id))
        _ = preferences.handle(.hostsChanged(known))
        _ = summaryReplication.handle(.catalogChanged(known))
    }

    /// Writes the AI summaries setting into every Host whose `notify.json`
    /// has not confirmed it yet, whether or not this device registered for
    /// notifications there: off must stop Host-side generation either way.
    /// An unreachable Host, or one without the plugin, stays unconfirmed and
    /// is tried again on the next call — the app calls this whenever the
    /// setting or a Host connection changes.
    func applySummaryChoice() async {
        let updating: Set<Host.ID> = Set(states.compactMap { host, state in
            if case .updating = state { return host }
            return nil
        })
        await performSummaryEffects(summaryReplication.handle(.apply(
            summariesEnabled(), hosts: hosts.map(\.id), updating: updating)))
    }

    private func performSummaryEffects(_ effects: [SummaryChoiceReplicationMachine.Effect]) async {
        for effect in effects {
            switch effect {
            case .write(let hostID, let token, let choice):
                let ceremony = ceremony
                let transports = transports
                summaryWrites[token] = Task { @MainActor [weak self] in
                    let confirmed: Bool
                    do {
                        try await transports.withNotificationTransport(for: hostID) { transport in
                            try await ceremony.setSummaryEnabled(choice, over: transport)
                        }
                        confirmed = true
                    } catch {
                        confirmed = false
                    }
                    guard let self else { return }
                    summaryWrites[token] = nil
                    _ = summaryReplication.handle(.writeFinished(hostID, token, succeeded: confirmed))
                }
            case .waitForWrites(let batch, let tokens):
                // Capture all tasks before awaiting: completed writes remove
                // their handles while another Host in this batch is suspended.
                let writes = tokens.compactMap { summaryWrites[$0] }
                for write in writes { await write.value }
                await performSummaryEffects(summaryReplication.handle(.batchFinished(
                    batch, currentChoice: summariesEnabled())))
            case .reapply:
                await applySummaryChoice()
            }
        }
    }

    /// Re-reads every Host's registration file so the toggles reflect what
    /// each Host actually holds.
    func refresh() async {
        await withTaskGroup { group in
            for host in hosts {
                group.addTask { await self.load(host) }
            }
        }
    }

    /// The per-Host on/off (registration add/remove). Enabling registers
    /// this device with both triggers on; disabling removes its entry and
    /// drops the local Notification Key.
    func setNotificationsEnabled(_ enabled: Bool, for host: Host) async {
        guard let settings = confirmedSettings(for: host.id),
            settings.isRegistered != enabled
        else { return }
        let relay = relayBaseURL()
        let summary = enabled ? summariesEnabled() : nil
        await write(for: host, from: settings, writingSummaryChoice: summary) {
            ceremony, token, transport in
            if enabled {
                let notify = NotificationTriggerPreferences()
                try await ceremony.register(
                    hostID: host.id, hostName: host.displayName,
                    deviceToken: token, notify: notify, relayBaseURL: relay,
                    summaryEnabled: summary, over: transport)
                return HostSettings(isRegistered: true, notify: notify)
            } else {
                try await ceremony.remove(
                    hostID: host.id, deviceToken: token, over: transport)
                return HostSettings(
                    isRegistered: false, notify: NotificationTriggerPreferences())
            }
        }
    }

    /// The separate Done flag (User Story 9): rewrites this device's entry
    /// over SSH so the plugin stops (or resumes) sending Done pushes at the
    /// source. Ignored while unregistered — there is no entry to update.
    func setDoneEnabled(_ enabled: Bool, for host: Host) async {
        guard let settings = confirmedSettings(for: host.id),
            settings.isRegistered, settings.notify.done != enabled
        else { return }
        let notify = NotificationTriggerPreferences(
            blocked: settings.notify.blocked, done: enabled)
        let relay = relayBaseURL()
        let summary = summariesEnabled()
        await write(for: host, from: settings, writingSummaryChoice: summary) {
            ceremony, token, transport in
            // Re-registration is the flag update: it upserts this device's
            // entry reusing the stored Notification Key (#72 idempotence).
            try await ceremony.register(
                hostID: host.id, hostName: host.displayName,
                deviceToken: token, notify: notify, relayBaseURL: relay,
                summaryEnabled: summary, over: transport)
            return HostSettings(isRegistered: true, notify: notify)
        }
    }

    private func load(_ host: Host) async {
        let token = deviceToken()
        let effects = preferences.handle(.load(host.id, hasDeviceToken: token != nil))
        guard case .read(let operationID) = effects.first, let token else { return }
        do {
            let file = try await readFile(for: host.id)
            let notify = file.preferences(token: token.hex)
            let settings = HostSettings(
                isRegistered: notify != nil,
                notify: notify ?? NotificationTriggerPreferences())
            for effect in preferences.handle(.loaded(
                host.id, operationID, settings,
                needsRegistration: settings.isRegistered
                    && !file.entry(token: token.hex, isIn: token.environment))) {
                if case .reregister(let confirmed) = effect {
                    await reregister(host, keeping: confirmed)
                }
            }
        } catch {
            _ = preferences.handle(.loadFailed(host.id, operationID, message(for: error, on: host.id)))
        }
    }

    /// The entry names the other APNs environment: a build of the other kind
    /// (TestFlight, then a Debug build on the same device) registered this
    /// token, and APNs rejects every push the plugin sends there, Live
    /// Activity updates included. Re-registering rewrites `env` and keeps
    /// the notify flags.
    private func reregister(_ host: Host, keeping settings: HostSettings) async {
        let relay = relayBaseURL()
        let summary = summariesEnabled()
        await write(for: host, from: settings, writingSummaryChoice: summary) {
            ceremony, token, transport in
            try await ceremony.register(
                hostID: host.id, hostName: host.displayName,
                deviceToken: token, notify: settings.notify, relayBaseURL: relay,
                summaryEnabled: summary, over: transport)
            return settings
        }
    }

    /// Shared write choreography: hold the confirmed settings while the
    /// ceremony runs, publish the new truth on success, and re-read on
    /// failure: the registration may have landed before a config write failed.
    /// `writtenSummaryChoice` is the AI summaries value the operation writes,
    /// if any; success confirms it for the Host.
    private func write(
        for host: Host,
        from settings: HostSettings,
        writingSummaryChoice writtenSummaryChoice: Bool? = nil,
        _ operation: @escaping @Sendable (
            NotificationRegistrationCeremony, APNSDeviceToken, any Transport
        ) async throws -> HostSettings
    ) async {
        let token = deviceToken()
        let effects = preferences.handle(.write(host.id, settings, hasDeviceToken: token != nil))
        guard case .write(let operationID) = effects.first, let token else { return }
        if let pending = summaryReplication.inFlight(for: host.id) {
            await summaryWrites[pending]?.value
        }
        do {
            let ceremony = ceremony
            let confirmed = try await transports.withNotificationTransport(
                for: host.id
            ) { transport in
                try await operation(ceremony, token, transport)
            }
            await completeWrite(preferences.handle(.written(
                host.id, operationID, confirmed, summaryChoice: writtenSummaryChoice)), for: host.id)
        } catch {
            let failureMessage = message(for: error, on: host.id)
            let recovery = preferences.handle(.writeFailed(host.id, operationID, failureMessage))
            guard case .reread(let recoveryID) = recovery.first else { return }
            do {
                let file = try await readFile(for: host.id)
                let notify = file.preferences(token: token.hex)
                await completeWrite(preferences.handle(.recovered(
                    host.id, recoveryID,
                    HostSettings(isRegistered: notify != nil,
                        notify: notify ?? NotificationTriggerPreferences()))), for: host.id)
            } catch {
                await completeWrite(preferences.handle(.recoveryFailed(host.id, recoveryID)), for: host.id)
            }
        }
    }

    private func completeWrite(
        _ effects: [NotificationPreferencesMachine.Effect], for hostID: Host.ID
    ) async {
        for effect in effects {
            guard case .writeCompleted(let choice) = effect else { continue }
            if let choice { _ = summaryReplication.handle(.registrationConfirmed(hostID, choice)) }
            // A choice changed during registration (or removal, which writes
            // none) must be applied now, not on the next connection change.
            if summaryReplication.confirmedChoice(for: hostID) != summariesEnabled() {
                await applySummaryChoice()
            }
        }
    }

    private func readFile(for hostID: Host.ID) async throws -> NotificationRegistrationFile {
        try NotificationRegistrationFile.decode(
            try await transports.withNotificationTransport(for: hostID) { transport in
                try await transport.readNotificationRegistration()
            })
    }

    /// The gate the in-app banner reads (#77): the Host's confirmed notify
    /// flags, or nil when this device is not registered or the Host's truth
    /// is unknown (unreachable, still loading, never refreshed) — in which
    /// case the banner fails closed, matching the plugin's semantics.
    func confirmedTriggers(for hostID: Host.ID) -> NotificationTriggerPreferences? {
        guard let settings = confirmedSettings(for: hostID), settings.isRegistered
        else { return nil }
        return settings.notify
    }

    private func confirmedSettings(for hostID: Host.ID) -> HostSettings? {
        switch states[hostID] {
        case .idle(let settings), .failed(_, let settings):
            settings
        case .loading, .unavailable, .updating, nil:
            nil
        }
    }

    /// The Host's wording: a Host with no herdr (tmux, herdr-core, or both)
    /// has Waycar's host tools where a herdr Host has the plugin.
    private func message(for error: any Error, on hostID: Host.ID) -> String {
        let backends = backendPresence(hostID)?.backends ?? []
        return Self.message(
            for: error, hostToolsOnly: !backends.isEmpty && !backends.contains(.herdr))
    }

    static func message(for error: any Error, hostToolsOnly: Bool = false) -> String {
        switch error {
        case NotificationRegistrationError.pluginNotInstalled:
            hostToolsOnly
                ? "Install Waycar's host tools on this Host with "
                    + "\(WaycarPluginRequirement.installCommand), then check again."
                : "Install the Waycar plugin on this Host, then check again."
        case NotificationRegistrationError.pluginProbeFailed:
            (hostToolsOnly
                ? "Could not check Waycar's host tools on this Host. "
                : "Could not check the Waycar plugin on this Host. ")
                + "Check the connection and try again."
        case NotificationRegistrationError.readFailed:
            "Could not read notification settings from this Host. "
                + "Check the connection and try again."
        case NotificationRegistrationError.writeFailed:
            "Could not update notification settings on this Host. "
                + "Check the connection and try again."
        case NotificationRegistrationError.unsupportedFileVersion:
            "This Host was registered by a newer app version. Update the app."
        case NotificationRegistrationError.deviceNotRegistered:
            "Register this device for notifications on this Host first."
        case TransportError.sshUnreachable:
            "The Host is not connected."
        case TransportError.timedOut:
            "The Host did not answer in time."
        case TransportError.herdrBinaryNotFound:
            TransportError.herdrBinaryNotFound.presentation.message
        case is TransportError:
            "The connection to the Host failed."
        default:
            "Could not update notification settings. Try again."
        }
    }
}
