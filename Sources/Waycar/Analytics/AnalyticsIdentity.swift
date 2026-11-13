import Foundation

/// The anonymous distinct id analytics events carry: a random UUID, never
/// derived from the device, the Apple Account or any advertising id.
///
/// It lives in this device's Keychain and, while iCloud Sync is on, also as
/// a synchronizable item in the user's iCloud Keychain (ADR 0019), so the
/// same person's iPhone and iPad count as one user. The synced copy wins:
/// a device that made its own id before another device's arrived adopts the
/// synced one. With sync off, or without iCloud Keychain, the id stays
/// device-local. Opting out of analytics deletes it (`forget()`), so opting
/// back in starts a new, unlinked id.
struct AnalyticsIdentity: Sendable {
    /// Same account in both stores. The synced service is shared with every
    /// other synced item, which each select by their own account prefix.
    static let account = "analytics.distinct-id"

    let device: any SecretStore
    let shared: @Sendable () -> (any SecretStore)?

    static let production = AnalyticsIdentity(
        device: KeychainSecretStore(service: "com.otreva.waycar.analytics"),
        shared: ICloudSync.sharedWhileEnabled)

    /// The id to send, creating and storing one when neither store has it.
    /// A Keychain failure yields an id for this launch only rather than
    /// blocking analytics; it is not written anywhere.
    func resolve() -> String {
        (try? loadOrCreate()) ?? Self.newID()
    }

    func loadOrCreate() throws -> String {
        let sharedStore = shared()
        let deviceID = try device.read(account: Self.account).flatMap(Self.decode)
        // An unreadable synced copy falls back to this device's id rather
        // than failing: iCloud Keychain may be unavailable right now.
        let sharedID = sharedStore.flatMap { try? $0.read(account: Self.account) }
            .flatMap(Self.decode)
        if let sharedID {
            if deviceID != sharedID {
                try? device.write(Self.encode(sharedID), account: Self.account)
            }
            return sharedID
        }
        if let deviceID {
            // Published on the first launch with sync on, so this device's
            // other devices adopt it instead of minting their own.
            try? sharedStore?.write(Self.encode(deviceID), account: Self.account)
            return deviceID
        }
        let id = Self.newID()
        // The synced copy first, as for Host passwords: a failure there
        // still leaves this device a stable id.
        try? sharedStore?.write(Self.encode(id), account: Self.account)
        try device.write(Self.encode(id), account: Self.account)
        return id
    }

    /// Deletes the id from iCloud Keychain (while sync is on) and from this
    /// device, as Host passwords are removed, so the next `resolve()` mints a
    /// new one. Another of the user's devices that still has analytics on
    /// republishes its own id the next time it sends an event.
    func forget() throws {
        try shared()?.removeSecret(account: Self.account)
        try device.removeSecret(account: Self.account)
    }

    private static func newID() -> String {
        UUID().uuidString.lowercased()
    }

    private static func encode(_ id: String) -> Data {
        Data(id.utf8)
    }

    /// Anything that is not a UUID counts as missing and is replaced.
    private static func decode(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8),
            let uuid = UUID(uuidString: text)
        else { return nil }
        return uuid.uuidString.lowercased()
    }
}
