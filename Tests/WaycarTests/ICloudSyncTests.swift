import Foundation
import Synchronization
import Testing

@testable import Waycar

/// The user's iCloud Keychain as the app sees it, with a test-controlled
/// iCloud Sync switch. Several "devices" share one instance, which stands in
/// for iCloud Keychain having carried every item everywhere.
private final class FakeICloud: Sendable {
    let store = InMemorySecretStore()
    private let enabled = Mutex(true)

    func setEnabled(_ isOn: Bool) {
        enabled.withLock { $0 = isOn }
    }

    var sharedWhileEnabled: @Sendable () -> (any SecretStore)? {
        { [self] in enabled.withLock { $0 } ? store : nil }
    }

    /// iCloud Keychain losing every item on this device: turned off with
    /// "Delete from This iPhone", or reset.
    func loseEverything() throws {
        for account in try store.readAll().keys {
            try store.removeSecret(account: account)
        }
    }
}

/// A shared store whose writes fail, like a Keychain refusing an item.
private final class WriteFailingSecretStore: SecretStore {
    func read(account: String) throws -> Data? { nil }
    func readAll() throws -> [String: Data] { [:] }
    func write(_ secret: Data, account: String) throws {
        throw KeychainError.unexpectedStatus(-1)
    }
    func removeSecret(account: String) throws {}
}

/// A working store that starts refusing writes to accounts with a prefix.
private final class PrefixWriteFailingStore: SecretStore {
    private let backing = InMemorySecretStore()
    private let failingPrefix = Mutex<String?>(nil)

    func failWrites(toAccountsWithPrefix prefix: String) {
        failingPrefix.withLock { $0 = prefix }
    }
    func read(account: String) throws -> Data? { try backing.read(account: account) }
    func readAll() throws -> [String: Data] { try backing.readAll() }
    func write(_ secret: Data, account: String) throws {
        if let prefix = failingPrefix.withLock({ $0 }), account.hasPrefix(prefix) {
            throw KeychainError.unexpectedStatus(-1)
        }
        try backing.write(secret, account: account)
    }
    func removeSecret(account: String) throws { try backing.removeSecret(account: account) }
}

/// A working store that counts writes: each one is Keychain traffic iCloud
/// Keychain carries to every device.
private final class WriteCountingSecretStore: SecretStore {
    private let backing = InMemorySecretStore()
    private let count = Mutex(0)

    var writes: Int { count.withLock { $0 } }
    func read(account: String) throws -> Data? { try backing.read(account: account) }
    func readAll() throws -> [String: Data] { try backing.readAll() }
    func write(_ secret: Data, account: String) throws {
        count.withLock { $0 += 1 }
        try backing.write(secret, account: account)
    }
    func removeSecret(account: String) throws { try backing.removeSecret(account: account) }
}

private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
    let suiteName = "hm-icloud-sync-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
}

/// One device's view of iCloud Keychain, gated by that device's own iCloud
/// Sync flag the way production reads `ICloudSync.isEnabled()`.
private final class DeviceSync: @unchecked Sendable {
    let iCloud: FakeICloud
    let defaults: UserDefaults

    init(_ iCloud: FakeICloud, defaults: UserDefaults) {
        self.iCloud = iCloud
        self.defaults = defaults
    }

    var shared: @Sendable () -> (any SecretStore)? {
        { [self] in ICloudSync.isEnabled(in: defaults) ? iCloud.store : nil }
    }

    func set(_ isOn: Bool) {
        defaults.set(isOn, forKey: ICloudSync.enabledDefaultsKey)
    }
}

@Suite("iCloud Sync identities")
struct SyncedIdentityTests {
    @Test func existingDeviceKeyIsPublishedAndStaysInUse() throws {
        let iCloud = FakeICloud()
        let device = InMemorySecretStore()
        let before = try DeviceKeyStore(secrets: device).loadOrCreate()

        let synced = DeviceKeyStore(secrets: device, shared: iCloud.sharedWhileEnabled)

        #expect(try synced.loadOrCreate().openSSHPublicKey == before.openSSHPublicKey)
        #expect(try iCloud.store.readAll().keys.contains {
            $0.hasPrefix(DeviceKeyStore.recordPrefix)
        })
    }

    @Test func newDeviceUsesTheSyncedKeyWithoutMakingItsOwn() throws {
        let iCloud = FakeICloud()
        let phone = InMemorySecretStore()
        let phoneKey = try DeviceKeyStore(secrets: phone).loadOrCreate()
        try DeviceKeyStore(secrets: phone, shared: iCloud.sharedWhileEnabled).publishDeviceKey()
        let pad = InMemorySecretStore()

        let padKey = try DeviceKeyStore(secrets: pad, shared: iCloud.sharedWhileEnabled)
            .loadOrCreate()

        #expect(padKey.openSSHPublicKey == phoneKey.openSSHPublicKey)
        #expect(try pad.readAll().isEmpty)
    }

    /// The race a new iPad runs: it needs a key before the iPhone's has
    /// synced, makes one, and then the iPhone's arrives. Both devices must
    /// settle on the iPhone's key, which its Hosts already trust.
    @Test func keyFromBeforeSyncWinsOverOneMadeWhileWaiting() throws {
        let iCloud = FakeICloud()
        let phone = InMemorySecretStore()
        let phoneKey = try DeviceKeyStore(secrets: phone).loadOrCreate()
        let pad = DeviceKeyStore(secrets: InMemorySecretStore(), shared: iCloud.sharedWhileEnabled)
        let interimPadKey = try pad.loadOrCreate()
        #expect(interimPadKey.openSSHPublicKey != phoneKey.openSSHPublicKey)

        let syncedPhone = DeviceKeyStore(secrets: phone, shared: iCloud.sharedWhileEnabled)

        #expect(try syncedPhone.loadOrCreate().openSSHPublicKey == phoneKey.openSSHPublicKey)
        #expect(try pad.loadOrCreate().openSSHPublicKey == phoneKey.openSSHPublicKey)
    }

    /// iCloud Keychain losing the iPad's interim record must not promote that
    /// key when the iPad publishes it again.
    @Test func aRepublishedKeyKeepsItsRank() throws {
        let iCloud = FakeICloud()
        let pad = DeviceKeyStore(secrets: InMemorySecretStore(), shared: iCloud.sharedWhileEnabled)
        _ = try pad.loadOrCreate()
        try iCloud.loseEverything()
        try pad.publishDeviceKey()
        let phone = InMemorySecretStore()
        let phoneKey = try DeviceKeyStore(secrets: phone).loadOrCreate()

        try DeviceKeyStore(secrets: phone, shared: iCloud.sharedWhileEnabled).publishDeviceKey()

        #expect(try pad.loadOrCreate().openSSHPublicKey == phoneKey.openSSHPublicKey)
    }

    @Test func replacingTheKeySwitchesEveryDevice() throws {
        let iCloud = FakeICloud()
        let phoneDevice = InMemorySecretStore()
        let oldKey = try DeviceKeyStore(secrets: phoneDevice).loadOrCreate()
        let phone = DeviceKeyStore(secrets: phoneDevice, shared: iCloud.sharedWhileEnabled)
        try phone.publishDeviceKey()
        let pad = DeviceKeyStore(secrets: InMemorySecretStore(), shared: iCloud.sharedWhileEnabled)
        #expect(try pad.loadOrCreate().openSSHPublicKey == oldKey.openSSHPublicKey)

        let replacement = try pad.rotate()

        #expect(replacement.openSSHPublicKey != oldKey.openSSHPublicKey)
        #expect(try phone.loadOrCreate().openSSHPublicKey == replacement.openSSHPublicKey)
        #expect(try pad.loadOrCreate().openSSHPublicKey == replacement.openSSHPublicKey)
        // A later replacement wins over an earlier one.
        let second = try phone.rotate()
        #expect(try pad.loadOrCreate().openSSHPublicKey == second.openSSHPublicKey)
    }

    @Test func turningSyncOffKeepsTheKeyInUseOnTheDevice() throws {
        let iCloud = FakeICloud()
        let phone = InMemorySecretStore()
        let phoneKey = try DeviceKeyStore(secrets: phone).loadOrCreate()
        let padDevice = InMemorySecretStore()
        _ = try DeviceKeyStore(secrets: padDevice, shared: iCloud.sharedWhileEnabled).loadOrCreate()
        try DeviceKeyStore(secrets: phone, shared: iCloud.sharedWhileEnabled).publishDeviceKey()
        let recordsBefore = try iCloud.store.readAll().count

        try DeviceKeyStore(secrets: padDevice).adoptCanonicalKey(from: iCloud.store)

        #expect(try DeviceKeyStore(secrets: padDevice).loadOrCreate().openSSHPublicKey
            == phoneKey.openSSHPublicKey)
        // The iPad's own interim key is still recoverable from iCloud Keychain.
        #expect(try iCloud.store.readAll().count == recordsBefore)
    }

    @Test func corruptDeviceKeyDefersToTheSyncedKey() throws {
        let iCloud = FakeICloud()
        let phone = InMemorySecretStore()
        let phoneKey = try DeviceKeyStore(secrets: phone).loadOrCreate()
        try DeviceKeyStore(secrets: phone, shared: iCloud.sharedWhileEnabled).publishDeviceKey()
        let pad = InMemorySecretStore()
        try pad.write(Data("not-a-key".utf8), account: "device-ed25519-private-key")

        #expect(try DeviceKeyStore(secrets: pad, shared: iCloud.sharedWhileEnabled)
            .loadOrCreate().openSSHPublicKey == phoneKey.openSSHPublicKey)
        #expect(throws: DeviceKeyStoreError.storedKeyCorrupt) {
            try DeviceKeyStore(secrets: pad).loadOrCreate()
        }
    }

    @Test func newDeviceUsesTheSyncedRSAKey() throws {
        let iCloud = FakeICloud()
        let phone = InMemorySecretStore()
        let phoneKey = try RSAKeyStore(secrets: phone).loadOrCreate()
        try RSAKeyStore(secrets: phone, shared: iCloud.sharedWhileEnabled).publishDeviceKey()

        let padKey = try RSAKeyStore(secrets: InMemorySecretStore(), shared: iCloud.sharedWhileEnabled)
            .loadOrCreate()

        #expect(padKey.openSSHPublicKey == phoneKey.openSSHPublicKey)
    }
}

@Suite("iCloud Sync passwords")
struct SyncAwareSecretStoreTests {
    @Test func writesReachBothCopiesAndReadsPreferTheSyncedOne() throws {
        let iCloud = FakeICloud()
        let device = InMemorySecretStore()
        let store = SyncAwareSecretStore(device: device, shared: iCloud.sharedWhileEnabled)

        try store.write(Data("one".utf8), account: "a")
        #expect(try device.read(account: "a") == Data("one".utf8))
        #expect(try iCloud.store.read(account: "a") == Data("one".utf8))

        // Another device changed it.
        try iCloud.store.write(Data("two".utf8), account: "a")
        #expect(try store.read(account: "a") == Data("two".utf8))

        try store.removeSecret(account: "a")
        #expect(try device.read(account: "a") == nil)
        #expect(try iCloud.store.read(account: "a") == nil)
    }

    @Test func syncOffTouchesOnlyTheDevice() throws {
        let iCloud = FakeICloud()
        iCloud.setEnabled(false)
        let device = InMemorySecretStore()
        let store = SyncAwareSecretStore(device: device, shared: iCloud.sharedWhileEnabled)
        try iCloud.store.write(Data("synced".utf8), account: "a")

        try store.write(Data("local".utf8), account: "a")

        #expect(try store.read(account: "a") == Data("local".utf8))
        #expect(try iCloud.store.read(account: "a") == Data("synced".utf8))
    }

    @Test func listsOnlyItsOwnAccounts() throws {
        let iCloud = FakeICloud()
        let device = InMemorySecretStore()
        let store = SyncAwareSecretStore(
            device: device, shared: iCloud.sharedWhileEnabled, accountPrefix: "host-password-")
        try device.write(Data("key".utf8), account: "device-ed25519-private-key")
        try iCloud.store.write(Data("record".utf8), account: "ed25519-identity.abc")
        try store.write(Data("pw".utf8), account: "host-password-1")

        #expect(try store.readAll() == ["host-password-1": Data("pw".utf8)])
    }
}

@MainActor
@Suite("iCloud Sync Host catalog")
struct SyncedHostCatalogTests {
    private struct Device {
        let defaults: UserDefaults
        let secrets: InMemorySecretStore
        let store: HostStore
    }

    private func device(
        _ iCloud: FakeICloud, defaults: UserDefaults, secrets: InMemorySecretStore = .init()
    ) -> Device {
        let sync = DeviceSync(iCloud, defaults: defaults)
        return Device(
            defaults: defaults,
            secrets: secrets,
            store: HostStore(
                defaults: defaults,
                secrets: SyncAwareSecretStore(device: secrets, shared: sync.shared),
                sync: SyncedHostCatalog(store: sync.shared)))
    }

    @Test func anotherDevicesEditSurvivesThisDeviceTurningSyncBackOn() throws {
        let iCloud = FakeICloud()
        let (phoneDefaults, cleanPhone) = try makeDefaults()
        defer { cleanPhone() }
        let (padDefaults, cleanPad) = try makeDefaults()
        defer { cleanPad() }
        var host = Host.fixture(address: "old.example")
        let phone = device(iCloud, defaults: phoneDefaults)
        try phone.store.add(host)
        let pad = device(iCloud, defaults: padDefaults)
        try pad.store.reconcileWithSync(iCloud.store.readAll())
        host.address = "new.example"
        try phone.store.update(host)

        try pad.store.reconcileWithSync(iCloud.store.readAll(), preferLocal: true)

        #expect(pad.store.hosts.map(\.address) == ["new.example"])
        try phone.store.reconcileWithSync(iCloud.store.readAll())
        #expect(phone.store.hosts.map(\.address) == ["new.example"])
    }

    @Test func aHostDeletedWhileSyncWasOffIsDeletedEverywhere() throws {
        let iCloud = FakeICloud()
        let (phoneDefaults, cleanPhone) = try makeDefaults()
        defer { cleanPhone() }
        let (padDefaults, cleanPad) = try makeDefaults()
        defer { cleanPad() }
        let host = Host.fixture(authMethod: .password)
        let phone = device(iCloud, defaults: phoneDefaults)
        try phone.store.add(host, password: "hunter2")
        let pad = device(iCloud, defaults: padDefaults)
        try pad.store.reconcileWithSync(iCloud.store.readAll())
        let padSync = DeviceSync(iCloud, defaults: padDefaults)

        padSync.set(false)
        try pad.store.remove(host.id)
        padSync.set(true)
        try pad.store.reconcileWithSync(iCloud.store.readAll(), preferLocal: true)

        #expect(pad.store.hosts.isEmpty)
        #expect(try iCloud.store.read(account: HostStore.passwordAccount(for: host.id)) == nil)
        #expect(try phone.store.reconcileWithSync(iCloud.store.readAll()))
        #expect(phone.store.hosts.isEmpty)
    }

    /// A device that republishes a stale copy (its items were wiped before
    /// the tombstone reached it) cannot bring a deleted Host back.
    @Test func aTombstoneBeatsAStaleRepublishedHost() throws {
        let iCloud = FakeICloud()
        let (phoneDefaults, cleanPhone) = try makeDefaults()
        defer { cleanPhone() }
        let (padDefaults, cleanPad) = try makeDefaults()
        defer { cleanPad() }
        let host = Host.fixture()
        let phone = device(iCloud, defaults: phoneDefaults)
        try phone.store.add(host)
        let pad = device(iCloud, defaults: padDefaults)
        try pad.store.reconcileWithSync(iCloud.store.readAll())
        let stale = try #require(
            try iCloud.store.read(account: SyncedHostCatalog.account(for: host.id)))

        try phone.store.remove(host.id)
        try iCloud.store.write(stale, account: SyncedHostCatalog.account(for: host.id))
        try pad.store.reconcileWithSync(iCloud.store.readAll())

        #expect(pad.store.hosts.isEmpty)
        #expect(try iCloud.store.read(account: SyncedHostCatalog.account(for: host.id)) == nil)
    }

    @Test func hostsAddedAndRemovedOnOneDeviceFollowOnAnother() throws {
        let iCloud = FakeICloud()
        let (phoneDefaults, cleanPhone) = try makeDefaults()
        defer { cleanPhone() }
        let (padDefaults, cleanPad) = try makeDefaults()
        defer { cleanPad() }
        let phone = device(iCloud, defaults: phoneDefaults)
        let pad = device(iCloud, defaults: padDefaults)
        let first = Host.fixture(name: "First", authMethod: .password)
        let second = Host.fixture(name: "Second")
        try phone.store.add(first, password: "hunter2")
        try phone.store.add(second)

        #expect(try pad.store.reconcileWithSync(iCloud.store.readAll()))
        #expect(pad.store.hosts == [first, second])
        #expect(try pad.store.password(for: first) == "hunter2")

        try pad.store.remove(first.id)
        #expect(try phone.store.reconcileWithSync(iCloud.store.readAll()))
        #expect(phone.store.hosts == [second])
        #expect(try phone.secrets.read(account: HostStore.passwordAccount(for: first.id)) == nil)
        // The mirror a device keeps if sync is turned off follows too.
        #expect(HostStore(defaults: phoneDefaults, secrets: InMemorySecretStore()).hosts == [second])
    }

    @Test func existingHostsJoinTheSyncedCatalogInsteadOfBeingReplaced() throws {
        let iCloud = FakeICloud()
        let (phoneDefaults, cleanPhone) = try makeDefaults()
        defer { cleanPhone() }
        let (padDefaults, cleanPad) = try makeDefaults()
        defer { cleanPad() }
        let phoneHost = Host.fixture(name: "Phone's")
        try device(iCloud, defaults: phoneDefaults).store.add(phoneHost)
        let padHost = Host.fixture(name: "Pad's")
        try HostStore(defaults: padDefaults, secrets: InMemorySecretStore()).add(padHost)
        let pad = device(iCloud, defaults: padDefaults)

        try pad.store.reconcileWithSync(iCloud.store.readAll(), preferLocal: true)

        // Published Hosts keep their list position ahead of later additions.
        #expect(pad.store.hosts == [padHost, phoneHost])
    }

    /// iCloud Keychain losing its items (turned off with "Delete", a reset,
    /// a restore that has not synced yet) is not every Host being deleted.
    @Test func missingSyncedHostsArePublishedAgainNotDeleted() throws {
        let iCloud = FakeICloud()
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let phone = device(iCloud, defaults: defaults)
        let host = Host.fixture(authMethod: .password)
        try phone.store.add(host, password: "hunter2")

        try iCloud.loseEverything()
        #expect(!(try phone.store.reconcileWithSync(iCloud.store.readAll())))

        #expect(phone.store.hosts == [host])
        #expect(try phone.secrets.read(account: HostStore.passwordAccount(for: host.id))
            == Data("hunter2".utf8))
        #expect(SyncedHostCatalog.contents(of: try iCloud.store.readAll()).records[host.id] != nil)
    }

    /// A deletion reaches a device that had sync off at the time, even when
    /// that device publishes its own Hosts on turning sync back on.
    @Test func aDeletionReachesADeviceThatWasNotSyncing() throws {
        let iCloud = FakeICloud()
        let (phoneDefaults, cleanPhone) = try makeDefaults()
        defer { cleanPhone() }
        let (padDefaults, cleanPad) = try makeDefaults()
        defer { cleanPad() }
        let phone = device(iCloud, defaults: phoneDefaults)
        let host = Host.fixture(authMethod: .password)
        try phone.store.add(host, password: "hunter2")
        let padSecrets = InMemorySecretStore()
        let pad = device(iCloud, defaults: padDefaults, secrets: padSecrets)
        try pad.store.reconcileWithSync(iCloud.store.readAll())
        try padSecrets.write(Data("hunter2".utf8), account: HostStore.passwordAccount(for: host.id))

        try phone.store.remove(host.id)
        #expect(try pad.store.reconcileWithSync(iCloud.store.readAll(), preferLocal: true))

        #expect(pad.store.hosts.isEmpty)
        #expect(try padSecrets.read(account: HostStore.passwordAccount(for: host.id)) == nil)
        #expect(SyncedHostCatalog.contents(of: try iCloud.store.readAll()).tombstones == [host.id])
    }

    @Test func turningSyncBackOnPublishesEditsMadeWhileItWasOff() throws {
        let iCloud = FakeICloud()
        let (phoneDefaults, cleanPhone) = try makeDefaults()
        defer { cleanPhone() }
        let (padDefaults, cleanPad) = try makeDefaults()
        defer { cleanPad() }
        var host = Host.fixture(address: "old.example")
        try device(iCloud, defaults: phoneDefaults).store.add(host)
        let pad = device(iCloud, defaults: padDefaults)
        try pad.store.reconcileWithSync(iCloud.store.readAll())
        host.address = "new.example"
        try HostStore(defaults: padDefaults, secrets: InMemorySecretStore()).update(host)
        let reopened = device(iCloud, defaults: padDefaults)

        try reopened.store.reconcileWithSync(iCloud.store.readAll(), preferLocal: true)

        let phone = device(iCloud, defaults: phoneDefaults)
        try phone.store.reconcileWithSync(iCloud.store.readAll())
        #expect(phone.store.hosts.map(\.address) == ["new.example"])
    }

    @Test func aSyncedHostThisBuildCannotReadIsKeptNotDeleted() throws {
        let iCloud = FakeICloud()
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let phone = device(iCloud, defaults: defaults)
        let host = Host.fixture(authMethod: .password)
        try phone.store.add(host, password: "hunter2")
        try iCloud.store.write(
            Data(#"{"v":99}"#.utf8), account: SyncedHostCatalog.account(for: host.id))

        #expect(!(try phone.store.reconcileWithSync(iCloud.store.readAll())))
        #expect(phone.store.hosts == [host])
        #expect(try phone.store.password(for: host) == "hunter2")
    }

    /// A record whose Host fails to decode must never reach the mirror, whose
    /// loader would then reject the whole catalog on the next launch.
    @Test func anUndecodableSyncedHostNeverBreaksTheCatalog() throws {
        let iCloud = FakeICloud()
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let phone = device(iCloud, defaults: defaults)
        let kept = Host.fixture(name: "Kept")
        try phone.store.add(kept)
        let broken = UUID()
        try iCloud.store.write(
            Data(#"{"v":1,"order":1,"host":{"id":"\#(broken.uuidString)","authMethod":"password"}}"#.utf8),
            account: SyncedHostCatalog.account(for: broken))

        try phone.store.reconcileWithSync(iCloud.store.readAll())

        let relaunched = HostStore(defaults: defaults, secrets: InMemorySecretStore())
        #expect(relaunched.catalogLoadError == nil)
        #expect(relaunched.hosts == [kept])
    }

    @Test func anotherDeviceMovingAHostOffPasswordsDropsTheStalePassword() throws {
        let iCloud = FakeICloud()
        let (phoneDefaults, cleanPhone) = try makeDefaults()
        defer { cleanPhone() }
        let (padDefaults, cleanPad) = try makeDefaults()
        defer { cleanPad() }
        let pad = device(iCloud, defaults: padDefaults)
        var host = Host.fixture(authMethod: .password)
        try pad.store.add(host, password: "leaked")
        let phone = device(iCloud, defaults: phoneDefaults)
        try phone.store.reconcileWithSync(iCloud.store.readAll())

        host.authMethod = .deviceKey
        try phone.store.update(host)
        try pad.store.reconcileWithSync(iCloud.store.readAll())

        #expect(try pad.secrets.read(account: HostStore.passwordAccount(for: host.id)) == nil)
    }

    @Test func aHostThatCannotBeSyncedIsNotAddedLocally() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = HostStore(
            defaults: defaults,
            secrets: InMemorySecretStore(),
            sync: SyncedHostCatalog(store: { WriteFailingSecretStore() }))

        #expect(throws: KeychainError.self) { try store.add(Host.fixture()) }
        #expect(store.hosts.isEmpty)
    }

    /// A removal iCloud Keychain refuses leaves the Host usable: still
    /// listed, still synced, and with its password.
    @Test func aRemovalThatCannotBeSyncedKeepsTheHostAndPassword() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let shared = PrefixWriteFailingStore()
        let store = HostStore(
            defaults: defaults,
            secrets: SyncAwareSecretStore(device: InMemorySecretStore(), shared: { shared }),
            sync: SyncedHostCatalog(store: { shared }))
        let host = Host.fixture(authMethod: .password)
        try store.add(host, password: "hunter2")
        shared.failWrites(toAccountsWithPrefix: SyncedHostCatalog.tombstonePrefix)

        #expect(throws: KeychainError.self) { try store.remove(host.id) }

        #expect(store.hosts == [host])
        #expect(try store.password(for: host) == "hunter2")
        #expect(SyncedHostCatalog.contents(of: try shared.readAll()).records[host.id] != nil)
    }
}

@Suite("iCloud Sync known hosts")
struct SyncedKnownHostsTests {
    private func fingerprint(_ marker: String) -> HostKeyFingerprint {
        let algorithm = "ssh-ed25519"
        var blob = Data()
        var length = UInt32(algorithm.utf8.count).bigEndian
        withUnsafeBytes(of: &length) { blob.append(contentsOf: $0) }
        blob.append(contentsOf: algorithm.utf8)
        blob.append(contentsOf: marker.utf8)
        return HostKeyFingerprint(publicKeyBlob: blob)
    }

    private func suite() -> (String, cleanup: () -> Void) {
        let name = "hm-icloud-known-\(UUID().uuidString)"
        return (name, { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) })
    }

    @Test func fingerprintsTrustedOnEitherDeviceReachTheOther() async throws {
        let iCloud = FakeICloud()
        let (phoneSuite, cleanPhone) = suite()
        defer { cleanPhone() }
        let (padSuite, cleanPad) = suite()
        defer { cleanPad() }
        let phone = try #require(
            UserDefaultsKnownHostsStore(suiteName: phoneSuite, shared: iCloud.sharedWhileEnabled))
        let pad = try #require(
            UserDefaultsKnownHostsStore(suiteName: padSuite, shared: iCloud.sharedWhileEnabled))
        await phone.setFingerprint(fingerprint("phone"), host: "a.example", port: 22)
        // Trusted on the iPad before it synced, so only the iPad has it.
        let padBeforeSync = try #require(UserDefaultsKnownHostsStore(suiteName: padSuite))
        await padBeforeSync.setFingerprint(fingerprint("pad"), host: "b.example", port: 22)

        #expect(await pad.syncWithShared(try iCloud.store.readAll()))
        #expect(await phone.syncWithShared(try iCloud.store.readAll()))

        #expect(
            await pad.fingerprint(host: "a.example", port: 22, algorithm: "ssh-ed25519")
                == fingerprint("phone"))
        #expect(
            await phone.fingerprint(host: "b.example", port: 22, algorithm: "ssh-ed25519")
                == fingerprint("pad"))
    }

    /// Sync adds trust a device lacks; it never replaces a host key a device
    /// already trusts. That mismatch is settled on the device.
    @Test func aDevicesOwnTrustDecisionIsNeverReplaced() async throws {
        let iCloud = FakeICloud()
        let (phoneSuite, cleanPhone) = suite()
        defer { cleanPhone() }
        let (padSuite, cleanPad) = suite()
        defer { cleanPad() }
        let phone = try #require(
            UserDefaultsKnownHostsStore(suiteName: phoneSuite, shared: iCloud.sharedWhileEnabled))
        await phone.setFingerprint(fingerprint("phone"), host: "a.example", port: 22)
        let padBeforeSync = try #require(UserDefaultsKnownHostsStore(suiteName: padSuite))
        await padBeforeSync.setFingerprint(fingerprint("pad"), host: "a.example", port: 22)
        let pad = try #require(
            UserDefaultsKnownHostsStore(suiteName: padSuite, shared: iCloud.sharedWhileEnabled))

        #expect(!(await pad.syncWithShared(try iCloud.store.readAll())))
        #expect(
            await pad.fingerprint(host: "a.example", port: 22, algorithm: "ssh-ed25519")
                == fingerprint("pad"))
    }
}

@Suite("iCloud Sync preferences")
struct PreferenceSyncTests {
    private static let key = "app-appearance"

    @Test func changesOnEitherDeviceReachTheOther() throws {
        let iCloud = FakeICloud()
        let (phoneDefaults, cleanPhone) = try makeDefaults()
        defer { cleanPhone() }
        let (padDefaults, cleanPad) = try makeDefaults()
        defer { cleanPad() }
        let phone = PreferenceSync(defaults: phoneDefaults, keys: [Self.key])
        let pad = PreferenceSync(defaults: padDefaults, keys: [Self.key])

        phoneDefaults.set("dark", forKey: Self.key)
        #expect(phone.reconcile(items: try iCloud.store.readAll(), shared: iCloud.store)
            .changedKeys.isEmpty)
        #expect(pad.reconcile(items: try iCloud.store.readAll(), shared: iCloud.store)
            .changedKeys == [Self.key])
        #expect(padDefaults.string(forKey: Self.key) == "dark")

        padDefaults.removeObject(forKey: Self.key)
        _ = pad.reconcile(items: try iCloud.store.readAll(), shared: iCloud.store)
        #expect(phone.reconcile(items: try iCloud.store.readAll(), shared: iCloud.store)
            .changedKeys == [Self.key])
        #expect(phoneDefaults.object(forKey: Self.key) == nil)
    }

    @Test func aNewDeviceAdoptsTheSharedValueOverItsOwn() throws {
        let iCloud = FakeICloud()
        let (phoneDefaults, cleanPhone) = try makeDefaults()
        defer { cleanPhone() }
        let (padDefaults, cleanPad) = try makeDefaults()
        defer { cleanPad() }
        phoneDefaults.set("dark", forKey: Self.key)
        _ = PreferenceSync(defaults: phoneDefaults, keys: [Self.key])
            .reconcile(items: try iCloud.store.readAll(), shared: iCloud.store)
        padDefaults.set("light", forKey: Self.key)

        _ = PreferenceSync(defaults: padDefaults, keys: [Self.key])
            .reconcile(items: try iCloud.store.readAll(), shared: iCloud.store)

        #expect(padDefaults.string(forKey: Self.key) == "dark")
    }

    @Test func onceSyncedThisDevicesUnsyncedChangeWins() throws {
        let iCloud = FakeICloud()
        let (phoneDefaults, cleanPhone) = try makeDefaults()
        defer { cleanPhone() }
        let (padDefaults, cleanPad) = try makeDefaults()
        defer { cleanPad() }
        let phone = PreferenceSync(defaults: phoneDefaults, keys: [Self.key])
        let pad = PreferenceSync(defaults: padDefaults, keys: [Self.key])
        phoneDefaults.set("system", forKey: Self.key)
        _ = phone.reconcile(items: try iCloud.store.readAll(), shared: iCloud.store)
        _ = pad.reconcile(items: try iCloud.store.readAll(), shared: iCloud.store)

        phoneDefaults.set("dark", forKey: Self.key)
        padDefaults.set("light", forKey: Self.key)
        _ = pad.reconcile(items: try iCloud.store.readAll(), shared: iCloud.store)
        _ = phone.reconcile(items: try iCloud.store.readAll(), shared: iCloud.store)

        #expect(phoneDefaults.string(forKey: Self.key) == "dark")
        #expect(pad.reconcile(items: try iCloud.store.readAll(), shared: iCloud.store)
            .changedKeys == [Self.key])
        #expect(padDefaults.string(forKey: Self.key) == "dark")
    }

    @Test func anAgreedRemovalKeepsLocalWinsForLaterConflicts() throws {
        let iCloud = FakeICloud()
        let (phoneDefaults, cleanPhone) = try makeDefaults()
        defer { cleanPhone() }
        let (padDefaults, cleanPad) = try makeDefaults()
        defer { cleanPad() }
        let phone = PreferenceSync(defaults: phoneDefaults, keys: [Self.key])
        let pad = PreferenceSync(defaults: padDefaults, keys: [Self.key])
        phoneDefaults.set("system", forKey: Self.key)
        _ = phone.reconcile(items: try iCloud.store.readAll(), shared: iCloud.store)
        _ = pad.reconcile(items: try iCloud.store.readAll(), shared: iCloud.store)

        padDefaults.removeObject(forKey: Self.key)
        _ = pad.reconcile(items: try iCloud.store.readAll(), shared: iCloud.store)
        _ = phone.reconcile(items: try iCloud.store.readAll(), shared: iCloud.store)
        // Reopen against the persisted baseline, not an in-memory agreement.
        let reopened = PreferenceSync(defaults: phoneDefaults, keys: [Self.key])
        phoneDefaults.set("dark", forKey: Self.key)
        padDefaults.set("light", forKey: Self.key)
        _ = pad.reconcile(items: try iCloud.store.readAll(), shared: iCloud.store)
        let outcome = reopened.reconcile(items: try iCloud.store.readAll(), shared: iCloud.store)

        #expect(outcome.changedKeys.isEmpty)
        #expect(phoneDefaults.string(forKey: Self.key) == "dark")
        _ = pad.reconcile(items: try iCloud.store.readAll(), shared: iCloud.store)
        #expect(padDefaults.string(forKey: Self.key) == "dark")
    }

    @Test func aMissingItemIsPublishedAgainNotTreatedAsRemoved() throws {
        let iCloud = FakeICloud()
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let phone = PreferenceSync(defaults: defaults, keys: [Self.key])
        defaults.set("dark", forKey: Self.key)
        _ = phone.reconcile(items: try iCloud.store.readAll(), shared: iCloud.store)

        try iCloud.loseEverything()
        _ = phone.reconcile(items: try iCloud.store.readAll(), shared: iCloud.store)

        #expect(defaults.string(forKey: Self.key) == "dark")
        #expect(try iCloud.store.read(account: PreferenceSync.accountPrefix + Self.key) != nil)
    }

    /// A synced value this build cannot read (a newer build's data) is
    /// neither adopted nor overwritten — not even after this device resets
    /// its own copy — so devices that can read it keep it.
    @Test func anUnreadableSyncedValueIsNeverAdoptedOrOverwritten() throws {
        let iCloud = FakeICloud()
        let (phoneDefaults, cleanPhone) = try makeDefaults()
        defer { cleanPhone() }
        let (padDefaults, cleanPad) = try makeDefaults()
        defer { cleanPad() }
        phoneDefaults.set("newer", forKey: Self.key)
        _ = PreferenceSync(defaults: phoneDefaults, keys: [Self.key])
            .reconcile(items: try iCloud.store.readAll(), shared: iCloud.store)
        let synced = try iCloud.store.read(account: PreferenceSync.accountPrefix + Self.key)
        let pad = PreferenceSync(defaults: padDefaults, keys: [Self.key])
        let olderBuild: (String, Any) -> Bool = { _, value in value as? String != "newer" }
        padDefaults.set("older", forKey: Self.key)

        _ = pad.reconcile(items: try iCloud.store.readAll(), shared: iCloud.store, canRead: olderBuild)
        padDefaults.removeObject(forKey: Self.key)
        _ = pad.reconcile(items: try iCloud.store.readAll(), shared: iCloud.store, canRead: olderBuild)

        #expect(padDefaults.object(forKey: Self.key) == nil)
        #expect(try iCloud.store.read(account: PreferenceSync.accountPrefix + Self.key) == synced)
    }
}

@MainActor
@Suite("iCloud Sync coordinator")
struct ICloudSyncCoordinatorTests {
    private struct Device {
        let defaults: UserDefaults
        let passwords: InMemorySecretStore
        let keys: InMemorySecretStore
        let hosts: HostStore
        let closed: ClosedSessionsStore
        let sync: ICloudSyncCoordinator
    }

    /// A device running sync. `before` fills its catalog, passwords and keys
    /// as a build without sync would have, before the coordinator starts.
    private func device(
        _ iCloud: FakeICloud,
        deviceSSH: (any SecretStore)? = nil,
        before: (HostStore, InMemorySecretStore) throws -> Void = { _, _ in },
        syncKnownHosts: (@MainActor ([String: Data]) async -> Bool)? = nil,
        retryConnections: @escaping @MainActor () async -> Void = {}
    ) throws -> (Device, cleanup: () -> Void) {
        let (defaults, cleanDefaults) = try makeDefaults()
        let knownSuite = "hm-icloud-coordinator-\(UUID().uuidString)"
        let passwords = InMemorySecretStore()
        let keys = InMemorySecretStore()
        try before(HostStore(defaults: defaults, secrets: passwords), keys)
        let deviceSync = DeviceSync(iCloud, defaults: defaults)
        let hosts = HostStore(
            defaults: defaults,
            secrets: SyncAwareSecretStore(device: passwords, shared: deviceSync.shared),
            sync: SyncedHostCatalog(store: deviceSync.shared))
        let closed = ClosedSessionsStore(sync: SyncedClosedSessionCatalog(store: deviceSync.shared))
        let sync = ICloudSyncCoordinator(
            hostStore: hosts,
            closedSessions: closed,
            preferences: [:],
            retryConnections: retryConnections,
            defaults: defaults,
            shared: iCloud.store,
            deviceSSH: deviceSSH ?? passwords,
            knownHosts: try #require(
                UserDefaultsKnownHostsStore(suiteName: knownSuite, shared: deviceSync.shared)),
            deviceKeys: DeviceKeyStore(secrets: keys, shared: deviceSync.shared),
            rsaKeys: RSAKeyStore(secrets: keys, shared: deviceSync.shared),
            syncKnownHosts: syncKnownHosts)
        let cleanup = {
            cleanDefaults()
            UserDefaults(suiteName: knownSuite)?.removePersistentDomain(forName: knownSuite)
        }
        return (
            Device(
                defaults: defaults, passwords: passwords, keys: keys, hosts: hosts,
                closed: closed, sync: sync),
            cleanup
        )
    }

    @Test func requestsBeforeThePassStartsJoinItWithoutAnExtraPass() async throws {
        var passes = 0
        let (phone, cleanup) = try device(FakeICloud(), syncKnownHosts: { _ in
            passes += 1
            return false
        })
        defer { cleanup() }
        let first = try #require(phone.sync.syncNow())
        _ = phone.sync.syncNow()
        await first.value
        #expect(passes == 1)
    }

    @Test func aRequestDuringAnInvalidatedPassRunsFreshAfterReenable() async throws {
        var finish: CheckedContinuation<Bool, Never>?
        var passes = 0
        var retries = 0
        let (phone, cleanup) = try device(
            FakeICloud(), syncKnownHosts: { _ in
                passes += 1
                if passes == 1 { return await withCheckedContinuation { finish = $0 } }
                return false
            }, retryConnections: { retries += 1 })
        defer { cleanup() }
        let first = try #require(phone.sync.syncNow())
        try await waitUntil { finish != nil }
        phone.sync.turnOffAnyway()
        phone.sync.setEnabled(true)
        let continuation = try #require(finish)
        continuation.resume(returning: true)
        await first.value
        #expect(passes == 2)
        #expect(phone.sync.lastPassAt != nil)
        #expect(retries == 0)
    }

    @Test func aPassFinishingAfterDisableCannotPublishOrRetry() async throws {
        var finish: CheckedContinuation<Bool, Never>?
        var retries = 0
        let (phone, cleanup) = try device(
            FakeICloud(),
            syncKnownHosts: { _ in
                await withCheckedContinuation { finish = $0 }
            },
            retryConnections: { retries += 1 })
        defer { cleanup() }
        let pass = try #require(phone.sync.syncNow())
        try await waitUntil { finish != nil }
        phone.sync.turnOffAnyway()
        let continuation = try #require(finish)
        continuation.resume(returning: true)
        await pass.value

        #expect(!phone.sync.isEnabled)
        #expect(phone.sync.lastPassAt == nil)
        #expect(phone.sync.lastError == nil)
        #expect(retries == 0)
    }

    /// The iPhone updates to the first build with sync; a new iPad opens it.
    @Test func aNewDeviceGetsHostsPasswordsAndTheKey() async throws {
        let iCloud = FakeICloud()
        let host = Host.fixture(authMethod: .password)
        var phoneKey: DeviceKey?
        let (phone, cleanPhone) = try device(iCloud) { catalog, keys in
            try catalog.add(host, password: "pw")
            phoneKey = try DeviceKeyStore(secrets: keys).loadOrCreate()
        }
        defer { cleanPhone() }
        let (pad, cleanPad) = try device(iCloud)
        defer { cleanPad() }

        await phone.sync.syncNow()?.value
        await pad.sync.syncNow()?.value

        #expect(pad.hosts.hosts == [host])
        #expect(try pad.hosts.password(for: host) == "pw")
        #expect(try DeviceKeyStore(secrets: pad.keys, shared: iCloud.sharedWhileEnabled)
            .loadOrCreate().openSSHPublicKey == phoneKey?.openSSHPublicKey)
        #expect(pad.sync.lastError == nil)
    }

    /// A session closed on the iPhone reaches the iPad in the same pass that
    /// brings its Host.
    @Test func aPassCarriesClosedSessionsAlongWithTheirHosts() async throws {
        let iCloud = FakeICloud()
        let host = Host.fixture()
        let (phone, cleanPhone) = try device(iCloud) { catalog, _ in try catalog.add(host) }
        defer { cleanPhone() }
        let (pad, cleanPad) = try device(iCloud)
        defer { cleanPad() }
        let row = ConsoleAgent(
            hostID: host.id, hostName: host.displayName,
            agent: Agent(
                terminalID: "t1", kind: "claude", title: "Task", status: .idle,
                workspaceID: "w1", tabID: "w1:t1", paneID: "w1:p1", cwd: "/work", revision: 1),
            workspaceLabel: nil, repositoryCheckout: nil)
        phone.closed.record([ClosedAgentCapture(row: row, session: nil, lastSeenRunningAt: Date())])

        await phone.sync.syncNow()?.value
        await pad.sync.syncNow()?.value

        #expect(pad.hosts.hosts == [host])
        #expect(pad.closed.sessions == phone.closed.sessions)
        #expect(pad.closed.sessions.count == 1)
    }

    @Test func losingICloudKeychainItemsWipesNothing() async throws {
        let iCloud = FakeICloud()
        let (phone, cleanup) = try device(iCloud)
        defer { cleanup() }
        let host = Host.fixture(authMethod: .password)
        try phone.hosts.add(host, password: "pw")
        await phone.sync.syncNow()?.value

        try iCloud.loseEverything()
        await phone.sync.syncNow()?.value

        #expect(phone.hosts.hosts == [host])
        #expect(try phone.hosts.password(for: host) == "pw")
        let items = try iCloud.store.readAll()
        #expect(SyncedHostCatalog.contents(of: items).records[host.id] != nil)
        #expect(items[HostStore.passwordAccount(for: host.id)] == Data("pw".utf8))
    }

    @Test func turningSyncOffKeepsWhatCameFromOtherDevices() async throws {
        let iCloud = FakeICloud()
        let (phone, cleanPhone) = try device(iCloud)
        defer { cleanPhone() }
        let phoneKey = try DeviceKeyStore(secrets: phone.keys).loadOrCreate()
        let host = Host.fixture(authMethod: .password)
        try phone.hosts.add(host, password: "pw")
        await phone.sync.syncNow()?.value
        let (pad, cleanPad) = try device(iCloud)
        defer { cleanPad() }
        await pad.sync.syncNow()?.value

        pad.sync.setEnabled(false)

        #expect(!pad.sync.isEnabled)
        #expect(try pad.passwords.read(account: HostStore.passwordAccount(for: host.id))
            == Data("pw".utf8))
        #expect(try DeviceKeyStore(secrets: pad.keys).loadOrCreate().openSSHPublicKey
            == phoneKey.openSSHPublicKey)
    }

    @Test func turningSyncOffStaysOnWhenAPasswordCannotBeKept() async throws {
        let iCloud = FakeICloud()
        let (phone, cleanPhone) = try device(iCloud)
        defer { cleanPhone() }
        try phone.hosts.add(Host.fixture(authMethod: .password), password: "pw")
        await phone.sync.syncNow()?.value
        let (pad, cleanPad) = try device(iCloud, deviceSSH: WriteFailingSecretStore())
        defer { cleanPad() }
        await pad.sync.syncNow()?.value

        pad.sync.setEnabled(false)

        #expect(pad.sync.isEnabled)
        #expect(pad.sync.lastError != nil)
    }

    /// Turning sync back on publishes a password changed on this device while
    /// sync was off, and never an unchanged, stale device copy of one that
    /// another device changed meanwhile.
    @Test func turningSyncBackOnPublishesOnlyPasswordsChangedHere() async throws {
        let iCloud = FakeICloud()
        let (phone, cleanPhone) = try device(iCloud)
        defer { cleanPhone() }
        let editedHere = Host.fixture(name: "Edited here", authMethod: .password)
        let editedThere = Host.fixture(name: "Edited there", authMethod: .password)
        try phone.hosts.add(editedHere, password: "one")
        try phone.hosts.add(editedThere, password: "one")
        await phone.sync.syncNow()?.value
        let (pad, cleanPad) = try device(iCloud)
        defer { cleanPad() }
        await pad.sync.syncNow()?.value

        pad.sync.setEnabled(false)
        try pad.hosts.update(editedHere, password: "pad")
        try phone.hosts.update(editedThere, password: "phone")
        pad.sync.setEnabled(true)
        await pad.sync.syncNow()?.value

        #expect(try iCloud.store.read(account: HostStore.passwordAccount(for: editedHere.id))
            == Data("pad".utf8))
        #expect(try iCloud.store.read(account: HostStore.passwordAccount(for: editedThere.id))
            == Data("phone".utf8))
        #expect(try pad.hosts.password(for: editedThere) == "phone")
    }
}

@MainActor
@Suite("iCloud Sync closed sessions")
struct SyncedClosedSessionCatalogTests {
    private struct Device {
        let sync: DeviceSync
        let store: ClosedSessionsStore

        /// One sync pass as the coordinator runs it, with `hosts` as this
        /// device's Host catalog.
        @MainActor @discardableResult
        func pass(_ iCloud: FakeICloud, hosts: Set<Host.ID>) throws -> Bool {
            try store.reconcileWithSync(iCloud.store.readAll(), knownHosts: hosts)
        }
    }

    private func device(
        _ iCloud: FakeICloud, clock: ManualClock
    ) throws -> (Device, cleanup: () -> Void) {
        let (defaults, cleanup) = try makeDefaults()
        let sync = DeviceSync(iCloud, defaults: defaults)
        let store = ClosedSessionsStore(
            sync: SyncedClosedSessionCatalog(store: sync.shared), now: { clock.now })
        return (Device(sync: sync, store: store), cleanup)
    }

    /// Session `session` on `host`, last seen running at `seen`.
    private func capture(host: Host.ID, session: String, seen: Date) -> ClosedAgentCapture {
        let row = ConsoleAgent(
            hostID: host, hostName: "alpha",
            agent: Agent(
                terminalID: "t-\(session)", kind: "claude", title: "Task", status: .idle,
                workspaceID: "w1", tabID: "w1:t1", paneID: "p-\(session)", cwd: "/work",
                revision: 1),
            workspaceLabel: nil, repositoryCheckout: nil)
        return ClosedAgentCapture(
            row: row,
            session: AgentSessionInfo(
                agent: "claude", kind: .id, source: "herdr:claude", value: session),
            lastSeenRunningAt: seen)
    }

    private func recordID(host: Host.ID, session: String) -> ClosedSession.ID {
        ClosedSession.recordID(
            hostID: host, kind: .claude, session: .init(kind: .id, value: session),
            terminalID: "t-\(session)")
    }

    private func recordItems(_ iCloud: FakeICloud) throws -> [String: Data] {
        try iCloud.store.readAll().filter {
            $0.key.hasPrefix(SyncedClosedSessionCatalog.accountPrefix)
        }
    }

    private func tombstoneItems(_ iCloud: FakeICloud) throws -> [ClosedSession.ID: Int64] {
        SyncedClosedSessionCatalog.contents(of: try iCloud.store.readAll()).tombstones
    }

    @Test func sessionsClosedOnEitherDeviceReachTheOther() throws {
        let iCloud = FakeICloud()
        let clock = ManualClock()
        let host = UUID()
        let (phone, cleanPhone) = try device(iCloud, clock: clock)
        defer { cleanPhone() }
        let (pad, cleanPad) = try device(iCloud, clock: clock)
        defer { cleanPad() }
        phone.store.record([capture(host: host, session: "on-phone", seen: clock.now)])
        clock.advance(by: 1)
        pad.store.record([capture(host: host, session: "on-pad", seen: clock.now)])

        try phone.pass(iCloud, hosts: [host])
        #expect(try pad.pass(iCloud, hosts: [host]))
        #expect(try phone.pass(iCloud, hosts: [host]))

        #expect(phone.store.sessions.map(\.session?.value) == ["on-pad", "on-phone"])
        #expect(pad.store.sessions == phone.store.sessions)
        #expect(try recordItems(iCloud).count == 2)
    }

    /// A device republishing a stale copy (its items were wiped before the
    /// tombstone reached it) cannot bring a forgotten session back.
    @Test func aForgottenSessionGoesEverywhereAndAStaleCopyCannotReturnIt() throws {
        let iCloud = FakeICloud()
        let clock = ManualClock()
        let host = UUID()
        let (phone, cleanPhone) = try device(iCloud, clock: clock)
        defer { cleanPhone() }
        let (pad, cleanPad) = try device(iCloud, clock: clock)
        defer { cleanPad() }
        phone.store.record([capture(host: host, session: "s", seen: clock.now)])
        try phone.pass(iCloud, hosts: [host])
        try pad.pass(iCloud, hosts: [host])
        let id = try #require(pad.store.sessions.first?.id)
        let stale = try #require(
            try iCloud.store.read(account: SyncedClosedSessionCatalog.account(for: id)))

        clock.advance(by: 10)
        pad.store.forget(id)
        try pad.pass(iCloud, hosts: [host])
        #expect(try phone.pass(iCloud, hosts: [host]))
        #expect(phone.store.sessions.isEmpty)

        try iCloud.store.write(stale, account: SyncedClosedSessionCatalog.account(for: id))
        try phone.pass(iCloud, hosts: [host])
        #expect(phone.store.sessions.isEmpty)
        #expect(try recordItems(iCloud).isEmpty)
    }

    /// The iPad was suspended while the Agent ran. Meanwhile it closed on
    /// the iPhone and was forgotten there. Coming back, the iPad notices
    /// the closure only now, but it last saw the Agent running before the
    /// Forget, so its capture cannot bring the session back anywhere.
    @Test func aDeviceBackFromASuspensionCannotReturnAForgottenSession() throws {
        let iCloud = FakeICloud()
        let clock = ManualClock()
        let host = UUID()
        let (phone, cleanPhone) = try device(iCloud, clock: clock)
        defer { cleanPhone() }
        let (pad, cleanPad) = try device(iCloud, clock: clock)
        defer { cleanPad() }
        let padLastSaw = clock.now
        clock.advance(by: 30)
        phone.store.record([capture(host: host, session: "s", seen: clock.now)])
        try phone.pass(iCloud, hosts: [host])
        clock.advance(by: 30)
        phone.store.forget(try #require(phone.store.sessions.first?.id))
        try phone.pass(iCloud, hosts: [host])

        clock.advance(by: 600)
        pad.store.record([capture(host: host, session: "s", seen: padLastSaw)])
        try pad.pass(iCloud, hosts: [host])
        try phone.pass(iCloud, hosts: [host])

        #expect(pad.store.sessions.isEmpty)
        #expect(phone.store.sessions.isEmpty)
        #expect(try recordItems(iCloud).isEmpty)
    }

    @Test func theSameSessionClosingAgainAfterAForgetReachesTheOtherDevice() throws {
        let iCloud = FakeICloud()
        let clock = ManualClock()
        let host = UUID()
        let (phone, cleanPhone) = try device(iCloud, clock: clock)
        defer { cleanPhone() }
        let (pad, cleanPad) = try device(iCloud, clock: clock)
        defer { cleanPad() }
        phone.store.record([capture(host: host, session: "s", seen: clock.now)])
        try phone.pass(iCloud, hosts: [host])
        try pad.pass(iCloud, hosts: [host])
        // Forgotten on the iPad.
        pad.store.forget(try #require(pad.store.sessions.first?.id))
        try pad.pass(iCloud, hosts: [host])
        try phone.pass(iCloud, hosts: [host])
        #expect(phone.store.sessions.isEmpty)

        clock.advance(by: 600)
        phone.store.record([capture(host: host, session: "s", seen: clock.now)])
        try phone.pass(iCloud, hosts: [host])
        #expect(try pad.pass(iCloud, hosts: [host]))

        #expect(pad.store.sessions.map(\.session?.value) == ["s"])
    }

    /// The session closed, was forgotten here, then was resumed and closed
    /// again before a pass ran: the pass publishes the new closure under the
    /// same item the forgotten copy held, and must not then delete it.
    @Test func aPassKeepsTheRecordItemItWroteOverAForgottenCopy() throws {
        let iCloud = FakeICloud()
        let clock = ManualClock()
        let host = UUID()
        let (phone, cleanPhone) = try device(iCloud, clock: clock)
        defer { cleanPhone() }
        let (pad, cleanPad) = try device(iCloud, clock: clock)
        defer { cleanPad() }
        phone.store.record([capture(host: host, session: "s", seen: clock.now)])
        try phone.pass(iCloud, hosts: [host])
        clock.advance(by: 10)
        phone.store.forget(recordID(host: host, session: "s"))
        clock.advance(by: 10)
        let seenAgain = clock.now
        clock.advance(by: 5)
        phone.store.record([capture(host: host, session: "s", seen: seenAgain)])

        try phone.pass(iCloud, hosts: [host])

        let item = try #require(
            SyncedClosedSessionCatalog.contents(of: try iCloud.store.readAll())
                .records[recordID(host: host, session: "s")])
        #expect(item.lastSeenRunningAt == seenAgain)
        #expect(try pad.pass(iCloud, hosts: [host]))
        #expect(pad.store.sessions == phone.store.sessions)
    }

    /// Forgotten here long after an older tombstone for the same record
    /// expired: the pass replaces the expired item and keeps the new one.
    @Test func aPassKeepsTheTombstoneItemItWroteOverAnExpiredOne() throws {
        let iCloud = FakeICloud()
        let clock = ManualClock()
        let host = UUID()
        let (phone, cleanPhone) = try device(iCloud, clock: clock)
        defer { cleanPhone() }
        let (pad, cleanPad) = try device(iCloud, clock: clock)
        defer { cleanPad() }
        let id = recordID(host: host, session: "s")
        pad.store.forget(id)
        try pad.pass(iCloud, hosts: [host])

        clock.advance(by: ClosedSessionsStore.retention + 60)
        phone.store.record([capture(host: host, session: "s", seen: clock.now)])
        clock.advance(by: 1)
        phone.store.forget(id)
        try phone.pass(iCloud, hosts: [host])

        #expect(try tombstoneItems(iCloud)[id] == ClosedSession.milliseconds(clock.now))
    }

    @Test func aSessionWhoseHostHasNotSyncedHereYetWaitsForIt() throws {
        let iCloud = FakeICloud()
        let clock = ManualClock()
        let host = UUID()
        let (phone, cleanPhone) = try device(iCloud, clock: clock)
        defer { cleanPhone() }
        let (pad, cleanPad) = try device(iCloud, clock: clock)
        defer { cleanPad() }
        phone.store.record([capture(host: host, session: "s", seen: clock.now)])
        try phone.pass(iCloud, hosts: [host])

        #expect(try !pad.pass(iCloud, hosts: []))
        #expect(pad.store.sessions.isEmpty)
        #expect(try recordItems(iCloud).count == 1)

        #expect(try pad.pass(iCloud, hosts: [host]))
        #expect(pad.store.sessions.count == 1)
    }

    /// Expiry needs no tombstone, and tombstones expire too.
    @Test func expiredSessionsAndTombstonesLeaveICloudKeychain() throws {
        let iCloud = FakeICloud()
        let clock = ManualClock()
        let host = UUID()
        let (phone, cleanPhone) = try device(iCloud, clock: clock)
        defer { cleanPhone() }
        let (pad, cleanPad) = try device(iCloud, clock: clock)
        defer { cleanPad() }
        phone.store.record([
            capture(host: host, session: "kept", seen: clock.now),
            capture(host: host, session: "forgotten", seen: clock.now),
        ])
        try phone.pass(iCloud, hosts: [host])
        try pad.pass(iCloud, hosts: [host])
        clock.advance(by: 10)
        pad.store.forget(recordID(host: host, session: "forgotten"))
        try pad.pass(iCloud, hosts: [host])
        #expect(try tombstoneItems(iCloud).count == 1)

        clock.advance(by: ClosedSessionsStore.retention + 1)
        try phone.pass(iCloud, hosts: [host])
        try pad.pass(iCloud, hosts: [host])

        #expect(phone.store.sessions.isEmpty)
        #expect(pad.store.sessions.isEmpty)
        #expect(try iCloud.store.readAll().keys.allSatisfy {
            !$0.hasPrefix(SyncedClosedSessionCatalog.accountPrefix)
                && !$0.hasPrefix(SyncedClosedSessionCatalog.tombstonePrefix)
        })
    }

    /// The iPhone's clock runs a minute ahead of the iPad's. Forgetting on
    /// the iPad a session the iPhone recorded still forgets it everywhere.
    @Test func forgettingOnADeviceWhoseClockIsBehindStillForgets() throws {
        let iCloud = FakeICloud()
        let padClock = ManualClock()
        let phoneClock = ManualClock(padClock.now.addingTimeInterval(60))
        let host = UUID()
        let (phone, cleanPhone) = try device(iCloud, clock: phoneClock)
        defer { cleanPhone() }
        let (pad, cleanPad) = try device(iCloud, clock: padClock)
        defer { cleanPad() }
        phone.store.record([capture(host: host, session: "s", seen: phoneClock.now)])
        try phone.pass(iCloud, hosts: [host])
        try pad.pass(iCloud, hosts: [host])

        padClock.advance(by: 10)
        pad.store.forget(try #require(pad.store.sessions.first?.id))
        try pad.pass(iCloud, hosts: [host])
        try phone.pass(iCloud, hosts: [host])
        try pad.pass(iCloud, hosts: [host])

        #expect(pad.store.sessions.isEmpty)
        #expect(phone.store.sessions.isEmpty)
        #expect(try recordItems(iCloud).isEmpty)
    }

    /// A device whose clock ran a year ahead forgot the session: its
    /// tombstone counts as written now, so the session seen running and
    /// closing an hour later is listed again.
    @Test func aTombstoneFromAClockFarAheadDoesNotForgetLaterClosures() throws {
        let iCloud = FakeICloud()
        let clock = ManualClock()
        let host = UUID()
        let (phone, cleanPhone) = try device(iCloud, clock: clock)
        defer { cleanPhone() }
        let id = recordID(host: host, session: "s")
        try iCloud.store.write(
            SyncedClosedSessionCatalog.encodeTombstone(
                at: ClosedSession.milliseconds(clock.now.addingTimeInterval(365 * 24 * 3600))),
            account: SyncedClosedSessionCatalog.tombstoneAccount(for: id))
        try phone.pass(iCloud, hosts: [host])

        clock.advance(by: 3600)
        phone.store.record([capture(host: host, session: "s", seen: clock.now)])

        #expect(phone.store.sessions.map(\.id) == [id])
    }

    /// A record stamped by a clock a year ahead expires on this device's
    /// clock, not a year late.
    @Test func aRecordStampedFarAheadExpiresOnThisDevicesClock() throws {
        let iCloud = FakeICloud()
        let clock = ManualClock()
        let host = UUID()
        let (phone, cleanPhone) = try device(iCloud, clock: clock)
        defer { cleanPhone() }
        let ahead = clock.now.addingTimeInterval(365 * 24 * 3600)
        let record = ClosedSession.fixture(
            hostID: host, session: .init(kind: .id, value: "s"), lastSeenRunningAt: ahead,
            closedAt: ahead)
        try iCloud.store.write(
            SyncedClosedSessionCatalog.encode(record),
            account: SyncedClosedSessionCatalog.account(for: record.id))
        try phone.pass(iCloud, hosts: [host])
        #expect(phone.store.sessions.map(\.id) == [record.id])

        clock.advance(by: ClosedSessionsStore.retention + ClosedSessionsStore.clockTolerance + 1)
        try phone.pass(iCloud, hosts: [host])

        #expect(phone.store.sessions.isEmpty)
        #expect(try recordItems(iCloud).isEmpty)
    }

    /// The iPad's clock runs a day ahead, and it republishes its own record
    /// and tombstone over any other copy. The iPhone clamps them once and
    /// holds that: after one round of writes neither device writes again,
    /// and the tombstone does not grow to forget a closure the iPhone
    /// captures later.
    @Test func aClockFarAheadRepublishingItsTimesCausesNoWriteChurn() throws {
        let shared = WriteCountingSecretStore()
        let phoneClock = ManualClock()
        let padClock = ManualClock(phoneClock.now.addingTimeInterval(24 * 3600))
        let phone = ClosedSessionsStore(
            sync: SyncedClosedSessionCatalog(store: { shared }), now: { phoneClock.now })
        let pad = ClosedSessionsStore(
            sync: SyncedClosedSessionCatalog(store: { shared }), now: { padClock.now })
        let host = UUID()
        pad.record([
            capture(host: host, session: "kept", seen: padClock.now),
            capture(host: host, session: "forgotten", seen: padClock.now),
        ])
        let forgotten = recordID(host: host, session: "forgotten")
        let forgottenAt = ClosedSession.milliseconds(padClock.now)
        pad.forget(forgotten)
        func passes() throws {
            phoneClock.advance(by: 10 * 60)
            padClock.advance(by: 10 * 60)
            try pad.reconcileWithSync(shared.readAll(), knownHosts: [host])
            try phone.reconcileWithSync(shared.readAll(), knownHosts: [host])
        }

        // The iPad publishes, the iPhone writes its clamps back, and the
        // iPad republishes its own times over them.
        try passes()
        try passes()
        let writes = shared.writes
        let held = phone.sessions
        #expect(held.map(\.session?.value) == ["kept"])
        for _ in 0..<4 {
            try passes()
        }

        #expect(shared.writes == writes)
        #expect(phone.sessions == held)
        #expect(
            SyncedClosedSessionCatalog.contents(of: try shared.readAll()).tombstones[forgotten]
                == forgottenAt)
        phone.record([capture(host: host, session: "forgotten", seen: phoneClock.now)])
        #expect(phone.sessions.map(\.id).contains(forgotten))
    }

    @Test func aSessionForgottenWhileSyncWasOffIsForgottenOnceItIsBackOn() throws {
        let iCloud = FakeICloud()
        let clock = ManualClock()
        let host = UUID()
        let (phone, cleanPhone) = try device(iCloud, clock: clock)
        defer { cleanPhone() }
        let (pad, cleanPad) = try device(iCloud, clock: clock)
        defer { cleanPad() }
        phone.store.record([capture(host: host, session: "s", seen: clock.now)])
        try phone.pass(iCloud, hosts: [host])
        try pad.pass(iCloud, hosts: [host])

        pad.sync.set(false)
        clock.advance(by: 10)
        pad.store.forget(try #require(pad.store.sessions.first?.id))
        #expect(try !pad.pass(iCloud, hosts: [host]))
        pad.sync.set(true)
        try pad.pass(iCloud, hosts: [host])

        #expect(pad.store.sessions.isEmpty)
        #expect(try phone.pass(iCloud, hosts: [host]))
        #expect(phone.store.sessions.isEmpty)
    }

    @Test func losingICloudKeychainItemsWipesNoSession() throws {
        let iCloud = FakeICloud()
        let clock = ManualClock()
        let host = UUID()
        let (phone, cleanPhone) = try device(iCloud, clock: clock)
        defer { cleanPhone() }
        phone.store.record([capture(host: host, session: "s", seen: clock.now)])
        try phone.pass(iCloud, hosts: [host])

        try iCloud.loseEverything()
        try phone.pass(iCloud, hosts: [host])

        #expect(phone.store.sessions.count == 1)
        #expect(try recordItems(iCloud).count == 1)
    }

    /// A record this build cannot read — a newer build's kind — is never
    /// replaced by this device's copy of the same session.
    @Test func aNewerBuildsRecordIsLeftAlone() throws {
        let iCloud = FakeICloud()
        let clock = ManualClock()
        let host = UUID()
        let (phone, cleanPhone) = try device(iCloud, clock: clock)
        defer { cleanPhone() }
        phone.store.record([capture(host: host, session: "s", seen: clock.now)])
        let id = try #require(phone.store.sessions.first?.id)
        let newer = Data(#"{"v":2,"session":{"id":"\#(id)","kind":"future-agent"}}"#.utf8)
        try iCloud.store.write(newer, account: SyncedClosedSessionCatalog.account(for: id))

        try phone.pass(iCloud, hosts: [host])

        #expect(try iCloud.store.read(account: SyncedClosedSessionCatalog.account(for: id)) == newer)
        #expect(phone.store.sessions.count == 1)
    }
}
