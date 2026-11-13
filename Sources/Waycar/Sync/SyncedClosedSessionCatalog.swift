import Foundation

/// The iCloud Keychain side of Closed Sessions (ADR 0019), shaped like
/// `SyncedHostCatalog`: one item per record, `closed-session.<id>`, so
/// sessions closed on different devices merge item by item.
///
/// Forgetting a record — the user's Forget, or a used resume of a record
/// without a session — writes a tombstone, `closed-session-deleted.<id>`,
/// holding when that happened (never earlier than the record's own times). A
/// tombstone overrides a copy of the record whose Agent was last seen running
/// no later than it, so neither a device republishing a stale copy nor one
/// back from a suspension, noticing the closure only now, can bring the
/// record back, while the same session seen running after a resume and
/// closing again is a new record. Only a tombstone means "forgotten": a
/// missing record item is one iCloud Keychain has not delivered yet, or lost.
///
/// Expiry needs no tombstone: every device drops a record once its
/// `closedAt` is older than `ClosedSessionsStore.retention`, and a tombstone
/// once every record it could override has expired.
struct SyncedClosedSessionCatalog: Sendable {
    static let accountPrefix = "closed-session."
    static let tombstonePrefix = "closed-session-deleted."
    static let recordVersion = 1

    private struct Record: Codable {
        let v: Int
        let session: ClosedSession
    }

    private struct Tombstone: Codable {
        let v: Int
        /// When the record was forgotten, in whole milliseconds since 1970.
        let at: Int64
    }

    struct Contents: Equatable, Sendable {
        var records: [ClosedSession.ID: ClosedSession] = [:]
        /// When each forgotten record was forgotten, in milliseconds.
        var tombstones: [ClosedSession.ID: Int64] = [:]
        /// Record items that exist but do not decode as a record of this
        /// version — damage, or a newer build's record or kind. Never
        /// overwritten from here.
        var unreadable: Set<ClosedSession.ID> = []
    }

    /// The shared store while sync is on, nil while it is off.
    let store: @Sendable () -> (any SecretStore)?

    static let iCloud = SyncedClosedSessionCatalog(store: ICloudSync.sharedWhileEnabled)

    static func account(for id: ClosedSession.ID) -> String {
        accountPrefix + id
    }

    static func tombstoneAccount(for id: ClosedSession.ID) -> String {
        tombstonePrefix + id
    }

    /// The Closed Session items among `items` (a `readAll` of the shared
    /// store). A tombstone that does not decode is skipped; see `unreadable`
    /// for records.
    static func contents(of items: [String: Data]) -> Contents {
        var contents = Contents()
        let decoder = JSONDecoder()
        for (account, data) in items {
            if account.hasPrefix(tombstonePrefix) {
                let id = String(account.dropFirst(tombstonePrefix.count))
                if let tombstone = try? decoder.decode(Tombstone.self, from: data) {
                    contents.tombstones[id] = tombstone.at
                }
            } else if account.hasPrefix(accountPrefix) {
                let id = String(account.dropFirst(accountPrefix.count))
                if let record = try? decoder.decode(Record.self, from: data),
                    record.v == recordVersion, record.session.id == id
                {
                    contents.records[id] = record.session
                } else {
                    contents.unreadable.insert(id)
                }
            }
        }
        return contents
    }

    static func encode(_ session: ClosedSession) throws -> Data {
        try encoder.encode(Record(v: recordVersion, session: session))
    }

    static func encodeTombstone(at milliseconds: Int64) throws -> Data {
        try encoder.encode(Tombstone(v: 1, at: milliseconds))
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }
}
