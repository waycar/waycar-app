import Foundation

/// iCloud Sync (ADR 0019): Hosts, Host passwords, the SSH identities, trusted
/// host fingerprints and app preferences travel between the user's devices
/// as synchronizable iCloud Keychain items. There is no account and no
/// sign-in: iOS syncs the items for whatever Apple Account the device uses,
/// provided iCloud Keychain is turned on — which no API reveals, so nothing
/// here ever claims an item reached another device.
enum ICloudSync {
    /// Every synced item lives under this one service. Device-only items keep
    /// their existing services, so a synced item never shadows one of them.
    static let service = "com.otreva.waycar.sync"
    static let enabledDefaultsKey = "icloud-sync.enabled"
    /// Set after the first pass since sync was turned on (or since the update
    /// that introduced sync) that published this device's Hosts and passwords
    /// over the synced copies. Cleared when sync is turned off, so turning it
    /// back on lets this device's edits win again.
    static let attachedDefaultsKey = "icloud-sync.attached"

    /// On unless the user turned it off on this device.
    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledDefaultsKey) as? Bool ?? true
    }

    /// False in the app process that hosts the unit tests: a pass there would
    /// read and write the simulator's real iCloud Keychain items and app
    /// preferences while the tests run against them (window-rendering tests
    /// failed under it). The tests build their own coordinators instead.
    static var runsInThisProcess: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
    }

    /// The user's iCloud Keychain, as this app sees it.
    static let sharedKeychain = KeychainSecretStore(service: service, synchronizable: true)

    /// The shared store while iCloud Sync is on for this device, nil while it
    /// is off. Read per call, so turning sync off takes effect immediately for
    /// stores built once at launch.
    static let sharedWhileEnabled: @Sendable () -> (any SecretStore)? = {
        isEnabled() ? sharedKeychain : nil
    }

    /// Device-only home of Host passwords and the pre-sync SSH identities.
    static let deviceSSHKeychain = KeychainSecretStore(service: "com.otreva.waycar.ssh")

    /// The production store for Host passwords.
    static let hostPasswords = SyncAwareSecretStore(
        device: deviceSSHKeychain, shared: sharedWhileEnabled, accountPrefix: "host-password-")
}

/// Host passwords under iCloud Sync. While sync is on, every write and
/// removal lands in both the device-only store and the shared iCloud
/// Keychain store, and reads prefer the shared copy because another device
/// may have changed it since. The device copy is what this device keeps when
/// sync is turned off; while sync is off only the device store is touched.
struct SyncAwareSecretStore: SecretStore {
    let device: any SecretStore
    let shared: @Sendable () -> (any SecretStore)?
    /// `readAll` lists only accounts with this prefix. Both services hold
    /// other items — the device keys, every other synced item — that are
    /// not this store's to list.
    var accountPrefix = ""

    func read(account: String) throws -> Data? {
        if let shared = shared(), let value = try shared.read(account: account) {
            return value
        }
        return try device.read(account: account)
    }

    func readAll() throws -> [String: Data] {
        var all = try device.readAll()
        if let shared = shared() {
            all.merge(try shared.readAll()) { _, shared in shared }
        }
        return all.filter { $0.key.hasPrefix(accountPrefix) }
    }

    /// The shared copy goes first: a failure then leaves both copies as they
    /// were instead of a device copy that never reaches the other devices.
    func write(_ secret: Data, account: String) throws {
        try shared()?.write(secret, account: account)
        try device.write(secret, account: account)
    }

    func removeSecret(account: String) throws {
        try shared()?.removeSecret(account: account)
        try device.removeSecret(account: account)
    }
}
