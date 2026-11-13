import Foundation

/// The iCloud Keychain side of the Host catalog (ADR 0019): one item per Host,
/// `host.<uuid>`, holding the Host exactly as the catalog persists it plus its
/// place in the list. One item per Host lets iCloud Keychain itself merge
/// Hosts added on different devices.
///
/// A deleted Host gets a tombstone under its own account, `host-deleted.<uuid>`,
/// which no live write ever touches and which is never removed: it overrides
/// any live record for that Host wherever it is seen, so a device that was
/// offline, had sync off, or republished a stale copy still drops the Host.
///
/// Only a tombstone means "deleted". A Host whose item is simply missing is
/// unknown to iCloud Keychain — the item has not synced here yet, or iCloud
/// Keychain lost it — so the device that has the Host publishes it again.
struct SyncedHostCatalog: Sendable {
    static let accountPrefix = "host."
    static let tombstonePrefix = "host-deleted."
    static let recordVersion = 1

    struct Record: Codable, Equatable, Sendable {
        let v: Int
        /// Ascending list position. Hosts published from an existing catalog
        /// get their index; Hosts added later get the time they were added,
        /// so they land after every published one.
        let order: Double
        /// The Host as the catalog persists it, kept raw so a Host from a
        /// newer build (an unknown authentication method) survives a trip
        /// through this build untouched.
        let host: JSONValue
    }

    struct Contents: Equatable, Sendable {
        /// Live Host records without a tombstone, keyed by Host id.
        var records: [UUID: Record] = [:]
        /// Hosts deleted on some device.
        var tombstones: Set<UUID> = []
        /// Live records a tombstone overrides; their items should go.
        var overridden: Set<UUID> = []
        /// Hosts whose item exists but does not decode as a record of this
        /// version — damage, or a newer build's record. Left untouched in the
        /// Keychain; callers treat them as present, never as deleted.
        var unreadable: Set<UUID> = []
    }

    /// The shared store while sync is on, nil while it is off.
    let store: @Sendable () -> (any SecretStore)?

    static let iCloud = SyncedHostCatalog(store: ICloudSync.sharedWhileEnabled)

    static func account(for id: UUID) -> String {
        accountPrefix + id.uuidString
    }

    static func tombstoneAccount(for id: UUID) -> String {
        tombstonePrefix + id.uuidString
    }

    /// The Host items among `items` (a `readAll` of the shared store).
    static func contents(of items: [String: Data]) -> Contents {
        var contents = Contents()
        for account in items.keys where account.hasPrefix(tombstonePrefix) {
            if let id = UUID(uuidString: String(account.dropFirst(tombstonePrefix.count))) {
                contents.tombstones.insert(id)
            }
        }
        for (account, data) in items where account.hasPrefix(accountPrefix) {
            guard let id = UUID(uuidString: String(account.dropFirst(accountPrefix.count))) else {
                continue
            }
            if contents.tombstones.contains(id) {
                contents.overridden.insert(id)
                continue
            }
            guard let record = try? JSONDecoder().decode(Record.self, from: data),
                record.v == recordVersion,
                record.host["id"]?.stringValue.flatMap(UUID.init(uuidString:)) == id
            else {
                contents.unreadable.insert(id)
                continue
            }
            contents.records[id] = record
        }
        return contents
    }

    static func encode(host: JSONValue, order: Double) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(Record(v: recordVersion, order: order, host: host))
    }

    /// A tombstone's content is irrelevant; its account is the signal.
    static let tombstone = Data(#"{"v":1}"#.utf8)
}
