import CryptoKit
import Foundation

/// One SSH identity published to iCloud Keychain. The account is derived from
/// the public key, so two devices publishing different keys never overwrite
/// each other, and a record is never deleted: losing one would lock every
/// Host that trusts it out of every device.
struct SyncedIdentityRecord: Codable, Equatable, Sendable {
    /// Replaced on purpose (a lost or exposed device). Outranks every other
    /// origin; the newest replacement wins.
    static let rotated = "rotated"
    /// A device's key from before it synced, which its Hosts already trust.
    static let migrated = "migrated"
    /// Generated while sync was on, possibly only because the synced key had
    /// not arrived yet.
    static let created = "created"

    static let version = 1

    let v: Int
    /// The private key bytes, base64.
    let key: String
    /// One of the origins above; a newer build's value decodes but ranks last.
    let origin: String
    /// Seconds since 1970 when the key was first published.
    let createdAt: Double
}

/// The identity rules `DeviceKeyStore` and `RSAKeyStore` share (ADR 0019).
///
/// Every device keeps its own key in the device-only slot it always had
/// (`account` in `device`), plus a device-only note of the origin and time it
/// was first published under, so a record iCloud Keychain loses is published
/// again with the same rank instead of a guessed one. With iCloud Sync on,
/// every device uses one canonical record: the newest replacement if the user
/// ever replaced the key, otherwise the oldest key that predates sync, then
/// the oldest created since, then the account. A new iPad that makes its own
/// key before the iPhone's arrives therefore switches to the iPhone's key as
/// soon as it syncs, and the iPhone never switches away.
struct SyncedIdentityKeychain<Key: Sendable>: Sendable {
    let device: any SecretStore
    let account: String
    let recordPrefix: String
    let shared: @Sendable () -> (any SecretStore)?
    let decode: @Sendable (Data) -> Key?
    let encode: @Sendable (Key) -> Data
    let publicKeyBlob: @Sendable (Key) -> Data
    /// Thrown when the device-only slot holds bytes that are not a key.
    let corrupt: any Error & Sendable

    /// Origin and publication time of the key in the device slot.
    private struct Provenance: Codable {
        let recordAccount: String
        let origin: String
        let createdAt: Double
    }

    private var provenanceAccount: String { account + ".origin" }

    /// The key to use, generating and publishing one only when neither this
    /// device nor any synced record has one.
    func loadOrCreate(generate: () throws -> Key) throws -> Key {
        if let key = try current() { return key }
        return try storeNewKey(generate(), origin: SyncedIdentityRecord.created)
    }

    /// Replaces the device-only key after a user-approved recovery. With sync
    /// on this is only offered when no synced record exists (see `current`),
    /// so the replacement becomes the canonical key.
    func replaceStoredKey(generate: () throws -> Key) throws -> Key {
        try storeNewKey(generate(), origin: SyncedIdentityRecord.created)
    }

    /// Replaces the key on purpose, e.g. after losing a device: with sync on,
    /// every device switches to the new key, and the old key's record stays in
    /// iCloud Keychain. With sync off it replaces only this device's key,
    /// which is published like any key from before sync if sync is turned on
    /// later, so it is not forced on the other devices.
    func rotate(generate: () throws -> Key) throws -> Key {
        try storeNewKey(generate(), origin: SyncedIdentityRecord.rotated)
    }

    /// The key in use without generating one: the canonical synced record
    /// while sync is on, otherwise this device's own key. A corrupt device
    /// key is surfaced only when nothing synced can stand in for it.
    func current() throws -> Key? {
        guard let shared = shared() else { return try deviceKey() }
        let local = Result { try deviceKey() }
        if case .success(let key?) = local {
            try publish(key, to: shared)
        }
        if let canonical = try rankedRecords(in: shared.readAll()).first?.key {
            return canonical
        }
        return try local.get()
    }

    /// Publishes this device's own key if it has one and it is not published
    /// yet. Never generates, and skips a corrupt device key. Run on every
    /// sync pass so other devices get the key before this device next needs
    /// it, and so a record iCloud Keychain lost comes back.
    func publishDeviceKey() throws {
        guard let shared = shared(), let key = try? deviceKey() else { return }
        try publish(key, to: shared)
    }

    /// Turning sync off: the device-only slot takes the canonical key, so the
    /// Hosts this device used while syncing keep working. The previous device
    /// key is only replaced once it is itself published, so it stays
    /// recoverable from iCloud Keychain.
    func adoptCanonicalKey(from shared: any SecretStore) throws {
        guard let canonical = rankedRecords(in: try shared.readAll()).first else { return }
        if let existing = try? deviceKey() {
            guard try shared.read(account: recordAccount(for: existing)) != nil else { return }
        }
        try device.write(encode(canonical.key), account: account)
        try remember(
            Provenance(
                recordAccount: canonical.account, origin: canonical.record.origin,
                createdAt: canonical.record.createdAt))
    }

    /// The canonical record's account, for noticing that the key in use changed.
    func canonicalAccount(in records: [String: Data]) -> String? {
        rankedRecords(in: records).first?.account
    }

    /// A key made while sync is on is published under `origin` first, and
    /// only then written to this device, so a failed publish leaves nothing
    /// behind that a later pass could publish unannounced. A replacement is
    /// stamped after every earlier replacement, whatever the device clocks
    /// say, so the one just made is the one every device switches to.
    ///
    /// A key made while sync is off is this device's own key, which Hosts
    /// come to trust exactly like a key from before sync, so it records
    /// nothing and is published as `migrated` when sync is next turned on.
    private func storeNewKey(_ key: Key, origin: String) throws -> Key {
        guard let shared = shared() else {
            try device.write(encode(key), account: account)
            return key
        }
        var createdAt = Date().timeIntervalSince1970
        if origin == SyncedIdentityRecord.rotated {
            let newest = rankedRecords(in: try shared.readAll())
                .filter { $0.record.origin == SyncedIdentityRecord.rotated }
                .map(\.record.createdAt)
                .max()
            createdAt = max(createdAt, (newest ?? 0) + 1)
        }
        let provenance = Provenance(
            recordAccount: recordAccount(for: key), origin: origin, createdAt: createdAt)
        try write(key, as: provenance, to: shared)
        try device.write(encode(key), account: account)
        try remember(provenance)
        return key
    }

    private func deviceKey() throws -> Key? {
        guard let stored = try device.read(account: account) else { return nil }
        guard let key = decode(stored) else { throw corrupt }
        return key
    }

    /// Publishes `key` unless its record exists, under the provenance this
    /// device remembers for it — or, for a key that predates sync, as
    /// `migrated` now, which is then remembered.
    private func publish(_ key: Key, to shared: any SecretStore) throws {
        let recordAccount = recordAccount(for: key)
        guard try shared.read(account: recordAccount) == nil else { return }
        let provenance: Provenance
        if let remembered = try? rememberedProvenance(), remembered.recordAccount == recordAccount {
            provenance = remembered
        } else {
            provenance = Provenance(
                recordAccount: recordAccount, origin: SyncedIdentityRecord.migrated,
                createdAt: Date().timeIntervalSince1970)
            try remember(provenance)
        }
        try write(key, as: provenance, to: shared)
    }

    private func write(_ key: Key, as provenance: Provenance, to shared: any SecretStore) throws {
        let record = SyncedIdentityRecord(
            v: SyncedIdentityRecord.version,
            key: encode(key).base64EncodedString(),
            origin: provenance.origin,
            createdAt: provenance.createdAt)
        try shared.write(JSONEncoder().encode(record), account: provenance.recordAccount)
    }

    private func remember(_ provenance: Provenance) throws {
        try device.write(JSONEncoder().encode(provenance), account: provenanceAccount)
    }

    private func rememberedProvenance() throws -> Provenance? {
        try device.read(account: provenanceAccount)
            .map { try JSONDecoder().decode(Provenance.self, from: $0) }
    }

    private func recordAccount(for key: Key) -> String {
        let digest = SHA256.hash(data: publicKeyBlob(key))
        return recordPrefix + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Decodable records under `recordPrefix`, canonical first. Records that
    /// do not decode (a newer build's version, damage) are skipped rather
    /// than blocking the others.
    private func rankedRecords(
        in items: [String: Data]
    ) -> [(account: String, record: SyncedIdentityRecord, key: Key)] {
        items.compactMap { account, data -> (String, SyncedIdentityRecord, Key)? in
            guard account.hasPrefix(recordPrefix),
                let record = try? JSONDecoder().decode(SyncedIdentityRecord.self, from: data),
                record.v == SyncedIdentityRecord.version,
                let bytes = Data(base64Encoded: record.key),
                let key = decode(bytes)
            else { return nil }
            return (account, record, key)
        }
        .sorted { lhs, rhs in
            let lhsRank = Self.originRank(lhs.1.origin)
            let rhsRank = Self.originRank(rhs.1.origin)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            if lhs.1.createdAt != rhs.1.createdAt {
                // The newest replacement wins; otherwise the oldest key does.
                return lhs.1.origin == SyncedIdentityRecord.rotated
                    ? lhs.1.createdAt > rhs.1.createdAt
                    : lhs.1.createdAt < rhs.1.createdAt
            }
            return lhs.0 < rhs.0
        }
        .map { (account: $0.0, record: $0.1, key: $0.2) }
    }

    private static func originRank(_ origin: String) -> Int {
        switch origin {
        case SyncedIdentityRecord.rotated: 0
        case SyncedIdentityRecord.migrated: 1
        case SyncedIdentityRecord.created: 2
        default: 3
        }
    }
}
