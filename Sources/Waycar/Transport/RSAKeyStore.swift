import Foundation

enum RSAKeyStoreError: Error, Equatable {
    /// The stored bytes no longer parse as an RSA key. Never silently replace
    /// them because every registered public key would stop working.
    case storedKeyCorrupt
}

/// Loads the RSA identity, generating it on first use. Its private PKCS#1
/// bytes live only in the Keychain — with iCloud Sync on, including the
/// user's iCloud Keychain, where every device uses one canonical key
/// (`SyncedIdentityKeychain`, ADR 0019) — and in memory while the key is used.
struct RSAKeyStore: Sendable {
    static let recordPrefix = "rsa-identity."

    private let identities: SyncedIdentityKeychain<RSAKey>

    /// `secrets` is the device-only slot; `shared` returns the iCloud
    /// Keychain store while sync is on. Tests leave it off.
    init(
        secrets: any SecretStore,
        account: String = "rsa-private-key",
        shared: @escaping @Sendable () -> (any SecretStore)? = { nil }
    ) {
        identities = SyncedIdentityKeychain(
            device: secrets,
            account: account,
            recordPrefix: Self.recordPrefix,
            shared: shared,
            decode: { try? RSAKey(privateKeyDER: $0) },
            encode: { $0.privateKeyDER },
            publicKeyBlob: { $0.publicKeyBlob },
            corrupt: RSAKeyStoreError.storedKeyCorrupt)
    }

    /// The production store: this device's Keychain, plus iCloud Keychain
    /// while iCloud Sync is on.
    init() {
        self.init(secrets: ICloudSync.deviceSSHKeychain, shared: ICloudSync.sharedWhileEnabled)
    }

    func loadOrCreate() throws -> RSAKey {
        try identities.loadOrCreate { try RSAKey.generate() }
    }

    /// The key in use, without generating one.
    func currentKey() throws -> RSAKey? {
        try identities.current()
    }

    /// Replaces the identity only after a user-approved recovery flow. Every
    /// Host registration for the previous public key then needs updating.
    func replaceStoredKey() throws -> RSAKey {
        try identities.replaceStoredKey { try RSAKey.generate() }
    }

    /// Replaces the key on purpose (a lost or exposed device); see
    /// `SyncedIdentityKeychain.rotate`.
    func rotate() throws -> RSAKey {
        try identities.rotate { try RSAKey.generate() }
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
