import Foundation
import OSLog

/// What this device last learned about mosh on each Host, per network
/// (#105): a mosh session that reached its server proves mosh available
/// there; one whose server never answered marks UDP blocked on that network,
/// so attaches there go straight to SSH. The connect-time probe records its
/// answer the same way. Kept across launches for a day, so a cold-restored
/// Agent rides mosh from its first attach and the probe only runs where
/// nothing fresh is known.
///
/// Keyed by the Host and the network it was learned on; an outcome learned
/// for one connection target never answers for another
/// (`ConsoleInventoryCache.Target`), and is dropped once the Host is
/// re-targeted or removed. One JSON file in its own directory, left out of
/// device backups like the Console's last-known inventory, written
/// atomically with complete file protection; nil keeps everything in
/// memory.
@MainActor
final class MoshAvailabilityStore {
    enum Outcome: String, Codable, Sendable {
        case available
        /// UDP does not get through on this network, or the Host's probe
        /// found no working mosh-server.
        case unavailable
    }

    private struct Record: Codable, Equatable, Sendable {
        let target: ConsoleInventoryCache.Target
        let outcome: Outcome
        let recordedAt: Date
    }

    private struct Envelope: Codable, Sendable {
        let version: Int
        /// Host id → network → what was learned there.
        let hosts: [String: [String: Record]]
    }

    static let formatVersion = 1
    static let freshness: TimeInterval = 24 * 3600

    private let fileURL: URL?
    private let now: @MainActor () -> Date
    private let readFile: @Sendable (URL) -> ConsoleInventoryCache.ReadResult
    private var hosts: [String: [String: Record]] = [:]
    /// The file has been read (or found missing or corrupt). False while it
    /// exists but is unreadable: a CarPlay launch can start the app with the
    /// phone locked, and taking the `.complete` file for empty then would
    /// write what little was learned since over a day of outcomes. Until it
    /// loads nothing is written, and every use tries the read again.
    private var isLoaded = false
    /// The last `retainOnly` targets and the Hosts forgotten while the file
    /// was unreadable; the load drops them from what it holds too.
    private var pendingRetainedTargets: [String: ConsoleInventoryCache.Target]?
    private var pendingForgottenHostIDs: Set<String> = []
    private nonisolated static let log = Logger(
        subsystem: "com.otreva.waycar", category: "MoshAvailability")

    init(
        fileURL: URL? = nil, now: @escaping @MainActor () -> Date = { Date() },
        readFile: @escaping @Sendable (URL) -> ConsoleInventoryCache.ReadResult =
            ConsoleInventoryCache.FileAccess.live.read
    ) {
        self.fileURL = fileURL
        self.now = now
        self.readFile = readFile
        loadIfNeeded()
    }

    /// Reads the file once it can be read; what was learned meanwhile wins
    /// over what it holds for the same Host and network.
    private func loadIfNeeded() {
        guard !isLoaded else { return }
        guard let fileURL else {
            isLoaded = true
            return
        }
        let stored: [String: [String: Record]]
        switch readFile(fileURL) {
        case .unreadable:
            return
        case .missing:
            stored = [:]
        case .data(let data):
            stored = Self.decode(data, at: fileURL) ?? [:]
        }
        isLoaded = true
        // Hosts forgotten or not retained while the file was unreadable lose
        // what it holds for them too (memory already dropped them).
        var loaded: [String: [String: Record]] = [:]
        for (hostID, networks) in stored where !pendingForgottenHostIDs.contains(hostID) {
            guard let targets = pendingRetainedTargets else {
                loaded[hostID] = networks
                continue
            }
            guard let target = targets[hostID] else { continue }
            let kept = networks.filter { $0.value.target == target }
            if !kept.isEmpty { loaded[hostID] = kept }
        }
        pendingRetainedTargets = nil
        pendingForgottenHostIDs = []
        for (hostID, networks) in hosts {
            loaded[hostID, default: [:]].merge(networks) { _, newer in newer }
        }
        // What has expired since the last write goes now, not at the next.
        let cutoff = now().addingTimeInterval(-Self.freshness)
        hosts = loaded.mapValues { $0.filter { $0.value.recordedAt > cutoff } }
            .filter { !$0.value.isEmpty }
        if hosts != stored { persist() }
    }

    /// The production location: its own directory under Application
    /// Support, which `persist()` keeps out of backups; nil when it cannot
    /// be resolved, which keeps outcomes in memory.
    static func applicationSupportFile() -> URL? {
        try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appending(path: "MoshAvailability", directoryHint: .isDirectory)
            .appending(path: "MoshAvailability.json")
    }

    /// What was learned about `host` on `network` within the last day; nil
    /// when nothing fresh is known, or the device has no usable path.
    func outcome(for host: Host, network: NetworkPathKey?) -> Outcome? {
        loadIfNeeded()
        guard let network,
            let record = hosts[host.id.uuidString]?[network.moshAvailabilityKey],
            record.target == ConsoleInventoryCache.Target(host),
            now().timeIntervalSince(record.recordedAt) < Self.freshness
        else { return nil }
        return record.outcome
    }

    func record(_ outcome: Outcome, for host: Host, network: NetworkPathKey?) {
        loadIfNeeded()
        guard let network else { return }
        let record = Record(
            target: ConsoleInventoryCache.Target(host), outcome: outcome, recordedAt: now())
        var networks = hosts[host.id.uuidString] ?? [:]
        // A Host re-targeted since keeps nothing from its old address.
        networks = networks.filter { $0.value.target == record.target }
        networks[network.moshAvailabilityKey] = record
        hosts[host.id.uuidString] = networks
        persist()
    }

    /// Keeps only `hosts`, and of each only what was learned for its
    /// current connection target: a removed or re-targeted Host's old
    /// coordinates do not stay on the device.
    func retainOnly(_ hosts: [Host]) {
        loadIfNeeded()
        let targets = Dictionary(
            hosts.map { ($0.id.uuidString, ConsoleInventoryCache.Target($0)) }
        ) { _, last in last }
        if !isLoaded { pendingRetainedTargets = targets }
        var retained: [String: [String: Record]] = [:]
        for (hostID, networks) in self.hosts {
            guard let target = targets[hostID] else { continue }
            let kept = networks.filter { $0.value.target == target }
            if !kept.isEmpty { retained[hostID] = kept }
        }
        guard retained != self.hosts else { return }
        self.hosts = retained
        persist()
    }

    /// Forgets everything learned about the Host: it was removed, or its
    /// connection details changed.
    func forget(hostID: Host.ID) {
        loadIfNeeded()
        if !isLoaded { pendingForgottenHostIDs.insert(hostID.uuidString) }
        guard hosts.removeValue(forKey: hostID.uuidString) != nil else { return }
        persist()
    }

    private func persist() {
        // Before the file loads, writing would drop what it holds.
        guard let fileURL, isLoaded else { return }
        let cutoff = now().addingTimeInterval(-Self.freshness)
        let envelope = Envelope(
            version: Self.formatVersion,
            hosts: hosts.mapValues { $0.filter { $0.value.recordedAt > cutoff } }
                .filter { !$0.value.isEmpty })
        Self.queue.async {
            do {
                try Self.prepareDirectory(of: fileURL)
                let data = try JSONEncoder().encode(envelope)
                try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
            } catch {
                Self.log.debug("Mosh availability write skipped: \(error.localizedDescription)")
            }
        }
    }

    /// The file's directory, created protected and excluded from backups:
    /// an atomic write replaces the file itself, so the exclusion lives on
    /// the directory (as `ConsoleInventoryCache`'s does).
    private nonisolated static func prepareDirectory(of fileURL: URL) throws {
        var directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
    }

    /// Writes land in order, off the main actor.
    private nonisolated static let queue = DispatchQueue(
        label: "com.otreva.waycar.mosh-availability")

    private static func decode(_ data: Data, at url: URL) -> [String: [String: Record]]? {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
            envelope.version == formatVersion
        else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return envelope.hosts
    }
}

extension NetworkPathKey {
    /// The key's identity as text, for keying what was learned on it.
    var moshAvailabilityKey: String {
        [interface.rawValue, interfaceName ?? "", addressPrefix ?? ""].joined(separator: "|")
    }
}
