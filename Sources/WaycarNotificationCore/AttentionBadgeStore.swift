import Foundation

/// The Attention Badge's per-Host counts, kept in the shared app-group
/// container so the app and the Notification Service Extension agree on one
/// cross-Host total (CONTEXT.md, Attention Badge).
///
/// Each Host's count is its own file, so the two writers never
/// read-modify-write a shared document: the app replaces the counts of Hosts
/// whose Agent Inventory it currently knows, prunes Hosts that left the
/// catalog, and mirrors the catalog for the extension; the extension
/// replaces the one Host a push came from. The badge is the sum of the
/// stored counts of catalog Hosts. A Host whose inventory is unknown keeps
/// its last stored count — last known, never guessed.
///
/// Every count is clamped to `NotificationPayload.maximumAttention` on read
/// and write and the sum saturates, so no stored value can overflow it.
///
/// Best-effort like `NotificationKeyMirror`: an unwritable container or an
/// unreadable file degrades to "no count for that Host", never an error.
struct AttentionBadgeStore: Sendable {
    /// Injectable for tests; the production value is the shared app-group
    /// container.
    var containerURL: URL? = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: NotificationKeyStore.sharedAccessGroup)

    private var directoryURL: URL? {
        containerURL?.appendingPathComponent("attention-badge", isDirectory: true)
    }

    /// Every stored count by Host, catalog or not.
    func counts() -> [UUID: Int] {
        storedCounts().mapValues(\.attention)
    }

    /// The badge: the sum of the stored counts of catalog Hosts.
    func total() -> Int {
        Self.sum(counts(), in: catalog())
    }

    /// The push path: a payload carrying its Host's attention count replaces
    /// that Host's stored count, and the answer is the new badge. Nil — leave
    /// the badge alone — when the payload carries no count.
    ///
    /// The count is not stored when the Host is outside the app's mirrored
    /// catalog (a removed Host whose Notification Key lingers), or when the
    /// push is older than the one that stored the current count: the Host
    /// sends one push per transition, and APNs does not keep them in order.
    func badge(after payload: NotificationPayload, from hostID: UUID) -> Int? {
        guard let attention = payload.attention else { return nil }
        let catalog = catalog()
        let asOf = Int(payload.timestamp.timeIntervalSince1970)
        let isStale = storedCounts()[hostID]?.asOf.map { asOf < $0 } ?? false
        if catalog?.contains(hostID) ?? true, !isStale {
            write(StoredCount(v: 1, attention: attention, asOf: asOf), for: hostID)
        }
        return Self.sum(counts(), in: catalog)
    }

    /// Replaces the given Hosts' counts, drops every Host outside `catalog`,
    /// mirrors `catalog` for the extension, and answers the total before and
    /// after. Hosts in the catalog but not in `counts` keep what they had.
    /// The app's counts are live, so they carry no push timestamp: the
    /// Host's next push always lands.
    func replace(
        _ counts: [UUID: Int], pruningTo catalog: Set<UUID>
    ) -> (previous: Int, current: Int) {
        let stored = storedCounts()
        let mirrored = self.catalog()
        let previous = Self.sum(stored.mapValues(\.attention), in: mirrored)
        if mirrored != catalog {
            writeCatalog(catalog)
        }
        for hostID in stored.keys where !catalog.contains(hostID) {
            remove(hostID)
        }
        for (hostID, attention) in counts
        where catalog.contains(hostID) && stored[hostID]?.attention != Self.clamped(attention) {
            write(StoredCount(v: 1, attention: attention, asOf: nil), for: hostID)
        }
        return (previous, total())
    }

    /// The Host catalog the app last mirrored. Nil until the app has written
    /// one, and then every Host counts, as before the mirror existed.
    private func catalog() -> Set<UUID>? {
        guard let directoryURL,
            let data = try? Data(contentsOf: directoryURL.appendingPathComponent(Self.catalogName)),
            let stored = try? JSONDecoder().decode(StoredCatalog.self, from: data),
            stored.v == 1
        else { return nil }
        return Set(stored.hosts)
    }

    private func storedCounts() -> [UUID: StoredCount] {
        guard let directoryURL,
            let names = try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path)
        else { return [:] }
        var counts: [UUID: StoredCount] = [:]
        for name in names where name.hasSuffix(Self.fileExtension) {
            guard let hostID = UUID(uuidString: String(name.dropLast(Self.fileExtension.count))),
                let data = try? Data(contentsOf: directoryURL.appendingPathComponent(name)),
                let stored = try? JSONDecoder().decode(StoredCount.self, from: data),
                stored.v == 1, stored.attention >= 0
            else { continue }
            counts[hostID] = StoredCount(
                v: stored.v, attention: Self.clamped(stored.attention), asOf: stored.asOf)
        }
        return counts
    }

    private static func clamped(_ attention: Int) -> Int {
        min(attention, NotificationPayload.maximumAttention)
    }

    /// Saturating, so even a corrupt store can never trap the sum.
    private static func sum(_ counts: [UUID: Int], in catalog: Set<UUID>?) -> Int {
        counts.reduce(0) { total, entry in
            guard catalog?.contains(entry.key) ?? true else { return total }
            let (sum, overflow) = total.addingReportingOverflow(entry.value)
            return overflow ? .max : sum
        }
    }

    private func write(_ count: StoredCount, for hostID: UUID) {
        guard count.attention >= 0 else { return }
        let bounded = StoredCount(
            v: count.v, attention: Self.clamped(count.attention), asOf: count.asOf)
        guard let data = try? JSONEncoder().encode(bounded) else { return }
        write(data, to: hostID.uuidString + Self.fileExtension)
    }

    private func writeCatalog(_ catalog: Set<UUID>) {
        guard let data = try? JSONEncoder().encode(StoredCatalog(v: 1, hosts: Array(catalog)))
        else { return }
        write(data, to: Self.catalogName)
    }

    private func write(_ data: Data, to name: String) {
        guard let directoryURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: directoryURL, withIntermediateDirectories: true)
            try data.write(
                to: directoryURL.appendingPathComponent(name),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            // A stale count only costs badge accuracy until the next write.
        }
    }

    private func remove(_ hostID: UUID) {
        guard let directoryURL else { return }
        try? FileManager.default.removeItem(
            at: directoryURL.appendingPathComponent(hostID.uuidString + Self.fileExtension))
    }

    private static let fileExtension = ".json"
    /// Not a UUID, so the count scan never reads it as a Host.
    private static let catalogName = "catalog.json"

    private struct StoredCount: Codable {
        let v: Int
        let attention: Int
        /// The push timestamp (unix seconds) the count came from; nil when
        /// the app wrote it from a live inventory.
        let asOf: Int?
    }

    private struct StoredCatalog: Codable {
        let v: Int
        let hosts: [UUID]
    }
}
