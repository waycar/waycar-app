import CryptoKit
import Foundation

enum DeviceKeyStoreError: Error, Equatable {
    /// The stored bytes no longer parse as an Ed25519 key. Surfaced, never
    /// silently regenerated: a new key would lock the user out of every Host
    /// without explanation.
    case storedKeyCorrupt
}

/// Loads the Device Key, generating it on first use. The private key's raw
/// bytes exist only in the Keychain and the in-memory CryptoKit object. With
/// iCloud Sync on, the Keychain includes the user's iCloud Keychain and every
/// device uses one canonical key (`SyncedIdentityKeychain`, ADR 0019); there
/// is no other export path.
struct DeviceKeyStore: Sendable {
    static let recordPrefix = "ed25519-identity."

    private let identities: SyncedIdentityKeychain<Curve25519.Signing.PrivateKey>

    /// `secrets` is the device-only slot; `shared` returns the iCloud
    /// Keychain store while sync is on. Tests leave it off.
    init(
        secrets: any SecretStore,
        account: String = "device-ed25519-private-key",
        shared: @escaping @Sendable () -> (any SecretStore)? = { nil }
    ) {
        identities = SyncedIdentityKeychain(
            device: secrets,
            account: account,
            recordPrefix: Self.recordPrefix,
            shared: shared,
            decode: { try? Curve25519.Signing.PrivateKey(rawRepresentation: $0) },
            encode: { $0.rawRepresentation },
            publicKeyBlob: { DeviceKey(privateKey: $0).publicKeyBlob },
            corrupt: DeviceKeyStoreError.storedKeyCorrupt)
    }

    /// The production store: this device's Keychain, plus iCloud Keychain
    /// while iCloud Sync is on.
    init() {
        self.init(secrets: ICloudSync.deviceSSHKeychain, shared: ICloudSync.sharedWhileEnabled)
    }

    func loadOrCreate() throws -> DeviceKey {
        DeviceKey(privateKey: try identities.loadOrCreate { Curve25519.Signing.PrivateKey() })
    }

    /// The key in use, without generating one.
    func currentKey() throws -> DeviceKey? {
        try identities.current().map(DeviceKey.init(privateKey:))
    }

    /// Replaces the stored key only after a user-approved recovery flow. This
    /// is deliberately separate from `loadOrCreate`: silent replacement would
    /// invalidate access to every Host that trusts the previous public key.
    func replaceStoredKey() throws -> DeviceKey {
        DeviceKey(privateKey: try identities.replaceStoredKey { Curve25519.Signing.PrivateKey() })
    }

    /// Replaces the key on purpose (a lost or exposed device); see
    /// `SyncedIdentityKeychain.rotate`.
    func rotate() throws -> DeviceKey {
        DeviceKey(privateKey: try identities.rotate { Curve25519.Signing.PrivateKey() })
    }

    /// See `SyncedIdentityKeychain.publishDeviceKey`.
    func publishDeviceKey() throws {
        try identities.publishDeviceKey()
    }

    /// See `SyncedIdentityKeychain.adoptCanonicalKey`.
    func adoptCanonicalKey(from shared: any SecretStore) throws {
        try identities.adoptCanonicalKey(from: shared)
    }

    func canonicalAccount(in records: [String: Data]) -> String? {
        identities.canonicalAccount(in: records)
    }
}
