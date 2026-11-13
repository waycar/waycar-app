import Foundation

/// Shared by the preference store and Live Activity coordinator. A whole
/// ceremony owns the Host's files, not just each individual SSH request:
/// otherwise two read-merge-writes can restore a removed registration.
/// Two Host entries can reach one machine (a Tailscale name and a LAN
/// address) and share its files, so a ceremony holds every entry for that
/// computer, its own included: one that started before a catalog change
/// still excludes a later one through either entry.
actor NotificationRegistrationWriter: NotificationTransportProvider {
    private let transports: any NotificationTransportProvider
    /// The Host entries for the same computer as the given one.
    private let computer: @Sendable (Host.ID) async -> Set<Host.ID>
    private var held: Set<Host.ID> = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(
        transports: any NotificationTransportProvider,
        computer: @escaping @Sendable (Host.ID) async -> Set<Host.ID> = { [$0] }
    ) {
        self.transports = transports
        self.computer = computer
    }

    func withNotificationTransport<Value: Sendable>(
        for hostID: Host.ID,
        _ operation: @escaping @Sendable (any Transport) async throws -> Value
    ) async throws -> Value {
        let entries = await computer(hostID).union([hostID])
        while !held.isDisjoint(with: entries) {
            await withCheckedContinuation { waiters.append($0) }
        }
        held.formUnion(entries)
        defer {
            held.subtract(entries)
            let woken = waiters
            waiters = []
            for waiter in woken { waiter.resume() }
        }
        try Task.checkCancellation()
        return try await transports.withNotificationTransport(for: hostID, operation)
    }
}

/// The per-Host Notification Registration ceremony (#72, ADR 0008): mint or
/// reuse the Host's Notification Key, then write this device's entry into
/// the registration file the Host's notify hook reads. The Transport owns
/// where that file lives and how it is replaced atomically; this type owns
/// the read-merge-write and the custody split (key in the device Keychain and
/// Host registration file, token only in the Host registration file).
///
/// Every failure is surfaced. A later config write can fail after the
/// registration landed; callers must re-read before reporting the Host's truth.
struct NotificationRegistrationCeremony: Sendable {
    let keys: NotificationKeyStore

    init(keys: NotificationKeyStore = NotificationKeyStore()) {
        self.keys = keys
    }

    /// Registers this device for Agent Notifications from one Host. The
    /// Notification Key is saved locally before the remote write: a write
    /// that fails after that leaves a key the retry reuses, whereas the
    /// reverse order could put a key on the Host that this device can no
    /// longer decrypt with. Re-registration with the same token is
    /// idempotent — the file keeps one entry per device token.
    /// `summaryEnabled` is the app's AI summaries setting; nil leaves the
    /// Host's `summary_enabled` as it is.
    @discardableResult
    func register(
        hostID: UUID,
        hostName: String,
        deviceToken: APNSDeviceToken,
        notify: NotificationTriggerPreferences = NotificationTriggerPreferences(),
        relayBaseURL: URL? = nil,
        summaryEnabled: Bool? = nil,
        over transport: any Transport
    ) async throws -> NotificationKeyRecord {
        let record = try hostRecord(hostID: hostID, hostName: hostName)
        try keys.save(record)
        let file = try NotificationRegistrationFile.decode(
            try await transport.readNotificationRegistration())
        let entry = NotificationDeviceEntry(
            token: deviceToken, key: record.key, notify: notify)
        try await transport.replaceNotificationRegistration(
            try file.upserting(entry).encoded())
        let relayURL = NotificationRelayEndpoint.resolve(customBaseURL: relayBaseURL)
        try await updateConfig(over: transport) { config in
            var updated = config
            // The resolved Push Relay base URL makes this Host's notify hook
            // POST there (#76). The production endpoint is written for the
            // empty/default app setting; self-builders can still supply an
            // explicit custom URL.
            if let relayURL { updated = updated.settingRelayURL(relayURL.absoluteString) }
            if let summaryEnabled { updated = updated.settingSummaryEnabled(summaryEnabled) }
            return updated
        }
        return record
    }

    /// Writes the app's AI summaries choice into the Host's `notify.json`,
    /// so the plugin starts or stops sending Agent screens to its harness's
    /// model. Needs no registration: summaries also label Console rows.
    func setSummaryEnabled(_ enabled: Bool, over transport: any Transport) async throws {
        try await updateConfig(over: transport) { $0.settingSummaryEnabled(enabled) }
    }

    /// Read-merge-write of the Host's `notify.json`: preserves the plugin's
    /// own knobs (`debounce_ms`, `retry_delay_ms`, and future fields) and
    /// skips the write when nothing changed.
    private func updateConfig(
        over transport: any Transport,
        _ change: (NotificationConfigFile) -> NotificationConfigFile
    ) async throws {
        let config = try NotificationConfigFile.decode(
            try await transport.readNotificationConfig())
        let updated = change(config)
        guard updated != config else { return }
        try await transport.replaceNotificationConfig(try updated.encoded())
    }

    /// Revokes this device on one Host: its entry leaves the registration
    /// file, then the local Notification Key record is dropped — in that
    /// order, so a failed remote removal keeps the key that still-armed
    /// pushes need. Removing a device that was never registered is a no-op.
    func remove(
        hostID: UUID,
        deviceToken: APNSDeviceToken,
        over transport: any Transport
    ) async throws {
        if let data = try await transport.readNotificationRegistration() {
            let file = try NotificationRegistrationFile.decode(data)
            if file.containsDevice(token: deviceToken.hex) {
                try await transport.replaceNotificationRegistration(
                    try file.removing(token: deviceToken.hex).encoded())
            }
        }
        try keys.removeRecord(forHost: hostID)
    }

    /// Writes this device's Live Activity push token into the matching
    /// registration entry. The device must already be registered — there is
    /// no entry to hang the token on otherwise, and inventing one would
    /// omit the Notification Key the plugin still needs for alerts.
    func setLiveActivityToken(
        tokenHex: String,
        startedAt: Date,
        deviceToken: APNSDeviceToken,
        pinnedPaneIDs: [String] = [],
        rowLayout: AgentRowLayout? = nil,
        hostName: String? = nil,
        over transport: any Transport
    ) async throws {
        let file = try NotificationRegistrationFile.decode(
            try await transport.readNotificationRegistration())
        guard file.containsDevice(token: deviceToken.hex) else {
            throw NotificationRegistrationError.deviceNotRegistered
        }
        try await transport.replaceNotificationRegistration(
            try file.settingLiveActivity(
                token: tokenHex, startedAt: startedAt, forDeviceToken: deviceToken.hex,
                pinnedPaneIDs: pinnedPaneIDs, rowLayout: rowLayout, hostName: hostName
            ).encoded())
    }

    /// Updates `pinned_pane_ids` on this device's existing `live_activity`
    /// object. No-op when the device is unregistered or the field is absent.
    func setLiveActivityPinnedPaneIDs(
        _ pinnedPaneIDs: [String],
        rowLayout: AgentRowLayout? = nil,
        hostName: String? = nil,
        deviceToken: APNSDeviceToken,
        over transport: any Transport
    ) async throws {
        guard let data = try await transport.readNotificationRegistration() else { return }
        let file = try NotificationRegistrationFile.decode(data)
        var updated = file.settingLiveActivityPinnedPaneIDs(
            pinnedPaneIDs, forDeviceToken: deviceToken.hex)
        if let rowLayout {
            updated = updated.settingLiveActivityRowLayout(
                rowLayout, hostName: hostName, forDeviceToken: deviceToken.hex)
        }
        guard updated != file else { return }
        try await transport.replaceNotificationRegistration(try updated.encoded())
    }

    /// Drops `live_activity` from this device's entry, leaving the rest of
    /// the object (alert token, key, notify flags, unknown fields) intact.
    /// An unregistered device is a no-op, matching `remove`. With
    /// `onlyIfToken`, the field stays unless it still holds that token: two
    /// Host entries for one computer share this device entry.
    func clearLiveActivityToken(
        deviceToken: APNSDeviceToken,
        onlyIfToken expected: String? = nil,
        over transport: any Transport
    ) async throws {
        guard let data = try await transport.readNotificationRegistration() else { return }
        let file = try NotificationRegistrationFile.decode(data)
        if let expected, file.liveActivity(forDeviceToken: deviceToken.hex)?.token != expected {
            return
        }
        let updated = file.clearingLiveActivity(forDeviceToken: deviceToken.hex)
        guard updated != file else { return }
        try await transport.replaceNotificationRegistration(try updated.encoded())
    }

    /// Writes this install's push-to-start token and the Host's `hostID` into
    /// the matching registration entry, so the plugin can start this Host's
    /// Live Activity while the app is not running. Fails closed like
    /// `setLiveActivityToken` when the device is not registered; rewriting
    /// an identical value leaves the file alone.
    func setLiveActivityStartToken(
        tokenHex: String,
        hostID: UUID,
        deviceToken: APNSDeviceToken,
        over transport: any Transport
    ) async throws {
        let file = try NotificationRegistrationFile.decode(
            try await transport.readNotificationRegistration())
        guard file.containsDevice(token: deviceToken.hex) else {
            throw NotificationRegistrationError.deviceNotRegistered
        }
        let updated = file.settingLiveActivityStart(
            token: tokenHex, hostID: hostID, forDeviceToken: deviceToken.hex)
        guard updated != file else { return }
        try await transport.replaceNotificationRegistration(try updated.encoded())
    }

    /// Drops `live_activity_start` from this device's entry so the plugin
    /// stops starting activities for it. Absent field or unregistered
    /// device is a no-op. With `onlyIfHostID`, the field stays unless it
    /// names that Host: another entry for the same computer may own it.
    func clearLiveActivityStartToken(
        deviceToken: APNSDeviceToken,
        onlyIfHostID hostID: UUID? = nil,
        over transport: any Transport
    ) async throws {
        guard let data = try await transport.readNotificationRegistration() else { return }
        let file = try NotificationRegistrationFile.decode(data)
        if let hostID, file.liveActivityStartHostID(forDeviceToken: deviceToken.hex) != hostID {
            return
        }
        let updated = file.clearingLiveActivityStart(forDeviceToken: deviceToken.hex)
        guard updated != file else { return }
        try await transport.replaceNotificationRegistration(try updated.encoded())
    }

    /// The Host's key record: the existing key when one is stored (the
    /// service extension must keep decrypting with the key the Host already
    /// holds), refreshed with the current display name; a fresh key
    /// otherwise.
    private func hostRecord(hostID: UUID, hostName: String) throws -> NotificationKeyRecord {
        let key = try keys.record(forHost: hostID)?.key ?? NotificationKeyStore.generateKey()
        return NotificationKeyRecord(hostID: hostID, hostName: hostName, key: key)
    }
}
