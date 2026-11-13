import Foundation
import Observation

enum HostStoreError: Error, Equatable {
    /// `update`/`remove` addressed a Host id the catalog does not contain.
    case unknownHost
    /// Persisted bytes could not be decoded. They are deliberately left
    /// untouched so a later write cannot turn a recoverable catalog into loss.
    case catalogUnreadable
    /// `add`/`update` was given the Sample Host's id (`SampleHost.id`). The
    /// Sample Host is virtual: it is never saved, so nothing can write it.
    case reservedHostID
}

/// The Sample Host (WAY-285): one virtual Host that lets a person with no
/// Host yet see labelled Agents, with no computer and no network. It is
/// never part of the catalog: `HostStore.hosts`, `HostStore.enabledHosts`,
/// the persisted catalog and every iCloud Sync record leave it out, so
/// nothing that reads them (notifications, Live Activities, the Watch,
/// CarPlay, AI Usage, Preflight, standby mosh, pairing, analytics counts)
/// ever meets it. Only `HostStore.sampleHost` returns it, and only the
/// first-run screen reads that.
enum SampleHost {
    /// Fixed so a test (and a screenshot run) can name it; no real Host has it.
    static let id = UUID(
        uuid: (
            0x53, 0x41, 0x4D, 0x50, 0x4C, 0x45, 0x40, 0x00,
            0x80, 0x00, 0x53, 0x41, 0x4D, 0x50, 0x4C, 0x45
        ))

    /// The reserved `.invalid` address never resolves, so even a bug that
    /// dialled it could reach no computer.
    static let host = Host(
        id: id,
        name: "Sample",
        address: "sample.waycar.invalid",
        username: "sample",
        authMethod: .password)

    static func isSample(_ id: Host.ID) -> Bool { id == Self.id }
}

/// Owns the Host catalog: add/edit/remove plus persistence. Host records go
/// to UserDefaults (no secrets in them); passwords go straight to the
/// injected `SecretStore` (the Keychain in the app), keyed by Host id.
///
/// With iCloud Sync on (`sync` returns a store, ADR 0019) every mutation
/// writes the Host's iCloud Keychain item (or a tombstone) before touching
/// the local copy, and `reconcileWithSync` merges what other devices wrote:
/// their Hosts arrive, tombstones remove Hosts, and anything this device has
/// that iCloud Keychain lacks is published again. UserDefaults keeps the
/// catalog, which is what the device holds if sync is turned off.
@MainActor
@Observable
final class HostStore {
    private static let defaultsKey = "hosts"
    private static let catalogVersion = 1
    /// iCloud Sync state kept on this device (ADR 0019): the Hosts this device
    /// and iCloud Keychain last agreed on, and changes made while sync was off.
    private static let syncBaseKey = "icloud-sync.host-base"
    private static let removedWhileOffKey = "icloud-sync.hosts-removed-while-off"
    private static let passwordsChangedWhileOffKey = "icloud-sync.passwords-changed-while-off"
    /// The Disabled Hosts (CONTEXT.md), as sorted UUID strings. Kept apart
    /// from the Host records so an edit, or an older build republishing a
    /// record it cannot fully read, never changes whether a Host is on; it
    /// syncs as its own preference instead (ADR 0019). Like every synced
    /// preference it syncs as one value: when two devices change it before
    /// either has seen the other's change, one device's list wins whole.
    static let disabledHostsKey = "disabled-hosts"

    /// Decodes each Host through its own decoder so a future authentication
    /// method hides only that Host from an older build. Other malformed Host
    /// data still fails the catalog instead of being discarded silently. The
    /// unrecognized future entries survive later writes from this build.
    private struct PersistedHosts: Codable {
        enum Entry: Equatable {
            case known(Host)
            case unknown(JSONValue)

            var knownHost: Host? {
                guard case .known(let host) = self else { return nil }
                return host
            }

            var knownHostID: Host.ID? { knownHost?.id }

            /// The Host id of any entry, known or not; nil only for an
            /// unknown entry without a readable id, which then never syncs.
            var id: UUID? {
                switch self {
                case .known(let host): host.id
                case .unknown(let raw): raw["id"]?.stringValue.flatMap(UUID.init(uuidString:))
                }
            }

            /// The entry as persisted.
            func raw() throws -> JSONValue {
                switch self {
                case .known(let host):
                    try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(host))
                case .unknown(let raw):
                    raw
                }
            }

            /// One persisted Host. A missing authentication method is
            /// structural damage; an unrecognized one is a newer build's Host.
            init(raw: JSONValue) throws {
                guard let authMethodValue = raw["authMethod"]?.stringValue else {
                    throw HostStoreError.catalogUnreadable
                }
                guard Host.AuthMethod(rawValue: authMethodValue) != nil else {
                    self = .unknown(raw)
                    return
                }
                let data = try JSONEncoder().encode(raw)
                self = .known(try JSONDecoder().decode(Host.self, from: data))
            }
        }

        let entries: [Entry]
        var values: [Host] { entries.compactMap(\.knownHost) }

        init(entries: [Entry]) {
            self.entries = entries
        }

        init(from decoder: any Decoder) throws {
            var container = try decoder.unkeyedContainer()
            var entries: [Entry] = []
            while !container.isAtEnd {
                entries.append(try Entry(raw: try container.decode(JSONValue.self)))
            }
            self.entries = entries
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.unkeyedContainer()
            for entry in entries {
                switch entry {
                case .known(let host):
                    try container.encode(host)
                case .unknown(let rawHost):
                    try container.encode(rawHost)
                }
            }
        }
    }

    private struct PersistedCatalog: Codable {
        let version: Int
        let hosts: PersistedHosts
    }

    /// The catalog's Hosts in record form: `isEnabled` is always true here,
    /// as in `catalogEntries`, so comparisons with persisted and synced
    /// records never see enablement.
    private var records: [Host]
    /// The Disabled Hosts. May name a Host whose record has not arrived yet
    /// (the key can sync first); `hosts` only applies it to known ones.
    private var disabledHostIDs: Set<Host.ID>
    /// The catalog with each Host's enablement applied.
    var hosts: [Host] {
        records.map { record in
            var host = record
            host.isEnabled = !disabledHostIDs.contains(record.id)
            return host
        }
    }
    /// The Hosts the app contacts. A Disabled Host stays in `hosts` so its
    /// configuration and saved state are kept, but nothing dials it.
    var enabledHosts: [Host] { records.filter { !disabledHostIDs.contains($0.id) } }
    /// The Sample Host while the catalog holds no Host at all and could be
    /// read; nil once any Host exists, a Disabled one and one this build
    /// cannot read included. Never persisted or synced, and never in `hosts`
    /// or `enabledHosts`: only the first-run screen asks for it.
    var sampleHost: Host? {
        records.isEmpty && catalogEntries.isEmpty && catalogLoadError == nil
            ? SampleHost.host : nil
    }
    private(set) var catalogLoadError: HostStoreError?
    // UserDefaults is documented thread-safe; Sendable modulo that promise.
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults?
    @ObservationIgnored private let secrets: any SecretStore
    @ObservationIgnored private let sync: SyncedHostCatalog?
    @ObservationIgnored private var catalogEntries: [PersistedHosts.Entry]
    /// Each synced entry's list position (`SyncedHostCatalog.Record.order`).
    @ObservationIgnored private var order: [UUID: Double] = [:]

    init(
        defaults: UserDefaults = .standard,
        secrets: any SecretStore = ICloudSync.hostPasswords,
        sync: SyncedHostCatalog? = nil
    ) {
        self.defaults = defaults
        self.secrets = secrets
        self.sync = sync
        catalogEntries = []
        disabledHostIDs = Self.storedDisabledHostIDs(in: defaults)
        guard let data = defaults.data(forKey: Self.defaultsKey) else {
            records = []
            catalogLoadError = nil
            return
        }
        do {
            let decoder = JSONDecoder()
            if let catalog = try? decoder.decode(PersistedCatalog.self, from: data) {
                guard catalog.version == Self.catalogVersion else {
                    throw HostStoreError.catalogUnreadable
                }
                records = catalog.hosts.values
                catalogEntries = catalog.hosts.entries
            } else {
                // Version 0 was the bare Host array. Decode it once, then
                // immediately persist the versioned envelope.
                let legacyHosts = try decoder.decode(PersistedHosts.self, from: data)
                records = legacyHosts.values
                catalogEntries = legacyHosts.entries
                defaults.set(
                    try Self.encodedCatalog(entries: catalogEntries),
                    forKey: Self.defaultsKey)
            }
            catalogLoadError = nil
        } catch {
            records = []
            catalogEntries = []
            catalogLoadError = .catalogUnreadable
        }
    }

    /// A process-local catalog for previews and development compositions.
    /// Mutations remain in memory, and secrets use process-local storage.
    /// Unlike `add`, it honors `isEnabled` already set on the passed Hosts,
    /// so a preview or test can start with a Disabled Host.
    init(volatileHosts: [Host]) {
        defaults = nil
        secrets = VolatileSecretStore()
        sync = nil
        let records = volatileHosts.map(\.recordForm)
        self.records = records
        disabledHostIDs = Set(volatileHosts.filter { !$0.isEnabled }.map(\.id))
        catalogEntries = records.map(PersistedHosts.Entry.known)
        catalogLoadError = nil
    }

    /// Whether this catalog takes part in iCloud Sync at all. Previews, demo
    /// compositions and tests build catalogs that never do.
    var participatesInICloudSync: Bool { sync != nil }

    /// Hosts whose password was set on this device while iCloud Sync was off.
    /// Turning sync back on publishes exactly these passwords over the synced
    /// copies; every other device copy may be stale and never overrides one.
    var passwordsChangedWhileSyncWasOff: Set<UUID> {
        Set(storedIDs(forKey: Self.passwordsChangedWhileOffKey))
    }

    /// Called once turning sync back on has published those passwords.
    func forgetPasswordsChangedWhileSyncWasOff() {
        guard defaults?.object(forKey: Self.passwordsChangedWhileOffKey) != nil else { return }
        defaults?.removeObject(forKey: Self.passwordsChangedWhileOffKey)
    }

    /// Whether this catalog syncs but iCloud Sync is currently off, so a
    /// change must be remembered for when it is turned back on.
    private var isSyncPaused: Bool { sync != nil && sync?.store() == nil }

    /// Adds a Host, storing `password` in the secret store when given. A
    /// Host is always added enabled, whatever `host.isEnabled` says;
    /// enablement changes only through `setEnabled`.
    func add(_ host: Host, password: String? = nil) throws {
        guard host.id != SampleHost.id else { throw HostStoreError.reservedHostID }
        try ensureCatalogIsWritable()
        let record = host.recordForm
        try applyPassword(password, to: record)
        let entry = PersistedHosts.Entry.known(record)
        try publish(entry, order: Date().timeIntervalSince1970)
        records.append(record)
        catalogEntries.append(entry)
        try persist()
    }

    /// Replaces the stored Host with the same id. `password` nil leaves any
    /// stored password untouched, so editing unrelated fields never requires
    /// re-entering it. Enablement is not part of the record and is left as
    /// it was, whatever `host.isEnabled` says; `setEnabled` changes it.
    func update(_ host: Host, password: String? = nil) throws {
        guard host.id != SampleHost.id else { throw HostStoreError.reservedHostID }
        try ensureCatalogIsWritable()
        guard let index = records.firstIndex(where: { $0.id == host.id }) else {
            throw HostStoreError.unknownHost
        }
        guard let entryIndex = catalogEntries.firstIndex(where: {
            $0.knownHostID == host.id
        }) else {
            throw HostStoreError.catalogUnreadable
        }
        let record = host.recordForm
        try applyPassword(password, to: record)
        let entry = PersistedHosts.Entry.known(record)
        try publish(entry, order: order[host.id] ?? Date().timeIntervalSince1970)
        records[index] = record
        catalogEntries[entryIndex] = entry
        try persist()
    }

    /// Turns a Host on or off. A Disabled Host keeps its configuration and
    /// saved state. Only the Disabled Hosts key is written, never the Host
    /// record; iCloud Sync carries the key to the user's other devices.
    func setEnabled(_ isEnabled: Bool, for id: Host.ID) throws {
        try ensureCatalogIsWritable()
        guard records.contains(where: { $0.id == id }) else {
            throw HostStoreError.unknownHost
        }
        guard disabledHostIDs.contains(id) == isEnabled else { return }
        if isEnabled {
            disabledHostIDs.remove(id)
        } else {
            disabledHostIDs.insert(id)
        }
        persistDisabledHosts()
    }

    /// Turns a Host on or off from a switch or accessibility action.
    /// `setEnabled` throws only for an unknown Host, whose row and page
    /// disappear with it, or an unreadable catalog, which shows no rows, so
    /// no control that calls this can see a failure.
    func setHostEnabled(_ isEnabled: Bool, for id: Host.ID) {
        try? setEnabled(isEnabled, for: id)
    }

    /// Re-reads the Disabled Hosts after iCloud Sync replaced the key with
    /// another device's value.
    func reloadDisabledHosts() {
        guard let defaults else { return }
        let stored = Self.storedDisabledHostIDs(in: defaults)
        guard stored != disabledHostIDs else { return }
        disabledHostIDs = stored
    }

    /// Removes the Host and its stored password — with iCloud Sync on, from
    /// every device, through a tombstone that stays in iCloud Keychain so a
    /// device that was offline or had sync off still learns of the deletion.
    /// The tombstone goes first: if it fails nothing has changed, and if the
    /// password removal after it fails, the next sync pass finishes the
    /// removal here.
    func remove(_ id: Host.ID) throws {
        try ensureCatalogIsWritable()
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            throw HostStoreError.unknownHost
        }
        if let shared = sync?.store() {
            try shared.write(
                SyncedHostCatalog.tombstone, account: SyncedHostCatalog.tombstoneAccount(for: id))
            try? shared.removeSecret(account: SyncedHostCatalog.account(for: id))
        }
        try secrets.removeSecret(account: Self.passwordAccount(for: id))
        if isSyncPaused {
            remember(id, forKey: Self.removedWhileOffKey)
        }
        order[id] = nil
        records.remove(at: index)
        catalogEntries.removeAll { $0.knownHostID == id }
        try persist()
        // A removed Disabled Host's id stays listed: dropping it would sync
        // ahead of the tombstone, and a device still holding the record
        // would connect to it in between. `hosts` ignores ids without a
        // record, and Host ids are never reused.
    }

    /// The stored password for a Host, or nil when none was saved.
    func password(for host: Host) throws -> String? {
        try secrets.read(account: Self.passwordAccount(for: host.id))
            .map { String(decoding: $0, as: UTF8.self) }
    }

    /// Keychain account for a Host's password; shared with
    /// `HostCredentialsProvider` so lookup and storage cannot drift.
    nonisolated static func passwordAccount(for id: Host.ID) -> String {
        "host-password-\(id.uuidString)"
    }

    /// One sync pass over the Host items among `items` (a `readAll` of the
    /// shared store). Returns whether the local catalog changed.
    ///
    /// - A local Host iCloud Keychain does not know is published: its item
    ///   has not synced here yet or was lost, and absence never means
    ///   deletion.
    /// - Where the local Host and its record differ, the side that changed
    ///   since the two last agreed (the base this device keeps) wins. Local
    ///   edits write through while sync is on, so a local change here means
    ///   one made while sync was off. When both changed, `preferLocal` — the
    ///   first pass after sync is turned back on — lets this device win;
    ///   otherwise, and when there is no base, the record does.
    /// - With `preferLocal`, Hosts deleted here while sync was off are
    ///   tombstoned, unless another device has edited them since.
    /// - Live records add or replace local Hosts; a tombstone removes the
    ///   Host here, with its password.
    /// - An item this build cannot decode, or a record whose Host it cannot
    ///   read, keeps the local entry as it is; one this device never had is
    ///   left out rather than written into the mirror, whose loader would
    ///   reject it.
    ///
    /// Does nothing while the local catalog is unreadable, like every other
    /// write.
    @discardableResult
    func reconcileWithSync(_ items: [String: Data], preferLocal: Bool = false) throws -> Bool {
        guard let shared = sync?.store(), catalogLoadError == nil else { return false }
        var contents = SyncedHostCatalog.contents(of: items)
        let storedBase = defaults?.dictionary(forKey: Self.syncBaseKey) as? [String: Data] ?? [:]
        let agreed = storedBase.compactMapValues { try? JSONDecoder().decode(JSONValue.self, from: $0) }

        if preferLocal {
            for id in storedIDs(forKey: Self.removedWhileOffKey) {
                guard let record = contents.records[id],
                    agreed[id.uuidString] == nil || agreed[id.uuidString] == record.host
                else { continue }
                try shared.write(
                    SyncedHostCatalog.tombstone,
                    account: SyncedHostCatalog.tombstoneAccount(for: id))
                // Gone from this device already, so the tombstone cleanup
                // below never sees it; its synced password goes here.
                try? shared.removeSecret(account: Self.passwordAccount(for: id))
                contents.records[id] = nil
                contents.tombstones.insert(id)
                contents.overridden.insert(id)
            }
        }
        // A tombstone beats any live record for the same Host.
        for id in contents.overridden {
            try? shared.removeSecret(account: SyncedHostCatalog.account(for: id))
        }

        for (index, entry) in catalogEntries.enumerated() {
            guard let id = entry.id,
                !contents.tombstones.contains(id), !contents.unreadable.contains(id)
            else { continue }
            let raw = try entry.raw()
            let existing = contents.records[id]
            if let existing {
                guard existing.host != raw, let base = agreed[id.uuidString] else { continue }
                let localChanged = raw != base
                let remoteChanged = existing.host != base
                guard localChanged, !remoteChanged || preferLocal else { continue }
            }
            let position = existing?.order ?? order[id] ?? Double(index)
            try shared.write(
                SyncedHostCatalog.encode(host: raw, order: position),
                account: SyncedHostCatalog.account(for: id))
            contents.records[id] = SyncedHostCatalog.Record(
                v: SyncedHostCatalog.recordVersion, order: position, host: raw)
        }
        if preferLocal, defaults?.object(forKey: Self.removedWhileOffKey) != nil {
            defaults?.removeObject(forKey: Self.removedWhileOffKey)
        }
        saveSyncBase(contents.records, replacing: storedBase)

        var positioned: [(id: UUID, order: Double, entry: PersistedHosts.Entry)] = []
        for (id, record) in contents.records {
            if let entry = try? PersistedHosts.Entry(raw: record.host) {
                positioned.append((id, record.order, entry))
            } else if let local = catalogEntries.first(where: { $0.id == id }) {
                positioned.append((id, order[id] ?? record.order, local))
            }
        }
        for entry in catalogEntries {
            guard let id = entry.id, contents.unreadable.contains(id) else { continue }
            positioned.append((id, order[id] ?? .greatestFiniteMagnitude, entry))
        }
        positioned.sort { lhs, rhs in
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        // Entries without an id never sync; keep them rather than drop them.
        let entries = positioned.map(\.entry) + catalogEntries.filter { $0.id == nil }
        order = Dictionary(positioned.map { ($0.id, $0.order) }) { first, _ in first }
        guard entries != catalogEntries else { return false }

        let previous = Dictionary(records.map { ($0.id, $0) }) { first, _ in first }
        let updated = entries.compactMap(\.knownHost)
        for host in records where contents.tombstones.contains(host.id) {
            try? secrets.removeSecret(account: Self.passwordAccount(for: host.id))
        }
        // Another device moved a Host off password authentication; the same
        // hygiene `applyPassword` applies to a local edit.
        for host in updated
        where host.authMethod != .password && previous[host.id]?.authMethod == .password {
            try? secrets.removeSecret(account: Self.passwordAccount(for: host.id))
        }
        catalogEntries = entries
        records = updated
        try? persist()
        return true
    }

    /// Writes the entry's synced item first while sync is on, so a failure
    /// leaves the local catalog as it was instead of holding a Host the next
    /// sync would read as deleted.
    private func publish(_ entry: PersistedHosts.Entry, order position: Double) throws {
        guard let shared = sync?.store(), let id = entry.id else { return }
        try shared.write(
            SyncedHostCatalog.encode(host: entry.raw(), order: position),
            account: SyncedHostCatalog.account(for: id))
        order[id] = position
    }

    private func applyPassword(_ password: String?, to host: Host) throws {
        let account = Self.passwordAccount(for: host.id)
        switch host.authMethod {
        case .deviceKey, .rsaKey:
            // Secret hygiene: a Host switched off password auth keeps no
            // stale password around.
            try secrets.removeSecret(account: account)
        case .password:
            if let password {
                try secrets.write(Data(password.utf8), account: account)
                if isSyncPaused {
                    remember(host.id, forKey: Self.passwordsChangedWhileOffKey)
                }
            }
        }
    }

    /// The Hosts this device and iCloud Keychain agreed on at the end of the
    /// last pass, so the next pass can tell which side changed. Written only
    /// when it differs, so a pass that changes nothing writes nothing.
    private func saveSyncBase(
        _ records: [UUID: SyncedHostCatalog.Record], replacing storedBase: [String: Data]
    ) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var base: [String: Data] = [:]
        for (id, record) in records {
            guard let data = try? encoder.encode(record.host) else { continue }
            base[id.uuidString] = data
        }
        if base != storedBase {
            defaults?.set(base, forKey: Self.syncBaseKey)
        }
    }

    private func storedIDs(forKey key: String) -> [UUID] {
        (defaults?.stringArray(forKey: key) ?? []).compactMap(UUID.init(uuidString:))
    }

    private func remember(_ id: UUID, forKey key: String) {
        var ids = defaults?.stringArray(forKey: key) ?? []
        guard !ids.contains(id.uuidString) else { return }
        ids.append(id.uuidString)
        defaults?.set(ids, forKey: key)
    }

    private func ensureCatalogIsWritable() throws {
        if catalogLoadError != nil {
            throw HostStoreError.catalogUnreadable
        }
    }

    private func persist() throws {
        defaults?.set(
            try Self.encodedCatalog(entries: catalogEntries),
            forKey: Self.defaultsKey)
    }

    private func persistDisabledHosts() {
        guard let defaults else { return }
        if disabledHostIDs.isEmpty {
            defaults.removeObject(forKey: Self.disabledHostsKey)
        } else {
            defaults.set(disabledHostIDs.map(\.uuidString).sorted(), forKey: Self.disabledHostsKey)
        }
    }

    private static func storedDisabledHostIDs(in defaults: UserDefaults) -> Set<Host.ID> {
        Set((defaults.stringArray(forKey: disabledHostsKey) ?? []).compactMap(UUID.init(uuidString:)))
    }

    private static func encodedCatalog(entries: [PersistedHosts.Entry]) throws -> Data {
        try JSONEncoder().encode(
            PersistedCatalog(
                version: catalogVersion,
                hosts: PersistedHosts(entries: entries)))
    }
}
