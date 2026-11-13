import CryptoKit
import Foundation
import OSLog
import Synchronization

/// The images and videos chats have shown, kept on this device so a chat
/// scrolled back to, reopened, or opened in Quick Look does not fetch them
/// from the Host or the web again.
///
/// One file per key under Caches (so the system may purge it), excluded
/// from backups and written with complete file protection. Keys name Host
/// paths and URLs, so file names carry only their SHA-256 digests. A file's
/// modification date is its last use: a lookup touches it, the least
/// recently used files go first once the total passes `capacity`, and
/// `prune(olderThan:)` drops the ones unused that long.
final class ChatMediaCache: Sendable {
    private struct Entry {
        let url: URL
        let size: Int
        var lastUsed: Date
    }

    private struct State {
        /// By key digest; nil until the directory is first read.
        var entries: [String: Entry]?
    }

    /// 300 MB, the most the files may total.
    static let capacityBytes = 300 * 1_000_000

    let directory: URL
    let capacity: Int
    private let now: @Sendable () -> Date
    private let queue = DispatchQueue(label: "com.otreva.waycar.chat-media-cache")
    private let state = Mutex(State())
    private static let log = Logger(subsystem: "com.otreva.waycar", category: "ChatMediaCache")

    init(
        directory: URL, now: @escaping @Sendable () -> Date = { Date() },
        capacity: Int = ChatMediaCache.capacityBytes
    ) {
        self.directory = directory
        self.now = now
        self.capacity = capacity
    }

    /// `<Caches>/ChatMedia`, or nil when Caches cannot be resolved — chats
    /// then fetch every time into a temporary directory.
    static func caches() -> ChatMediaCache? {
        guard
            let base = try? FileManager.default.url(
                for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        else { return nil }
        return ChatMediaCache(directory: base.appending(path: "ChatMedia", directoryHint: .isDirectory))
    }

    /// The file a key was stored under, `<digest>.<ext>`.
    static func fileName(for key: String, pathExtension: String) -> String {
        "\(digest(key)).\(pathExtension)"
    }

    /// The stored file for `key`, marked used now; nil when none (or it vanished).
    func file(for key: String) -> URL? {
        let name = Self.digest(key)
        return queue.sync {
            guard var entry = loadedEntries()[name] else { return nil }
            guard FileManager.default.fileExists(atPath: entry.url.path(percentEncoded: false)) else {
                state.withLock { $0.entries?[name] = nil }
                return nil
            }
            entry.lastUsed = now()
            try? FileManager.default.setAttributes(
                [.modificationDate: entry.lastUsed], ofItemAtPath: entry.url.path(percentEncoded: false))
            state.withLock { $0.entries?[name] = entry }
            return entry.url
        }
    }

    /// Writes `data` as `key`'s file, replacing any earlier one, then evicts
    /// the least recently used others until the total fits `capacity`.
    func store(_ data: Data, for key: String, pathExtension: String) throws -> URL {
        let name = Self.digest(key)
        let url = directory.appending(
            path: Self.fileName(for: key, pathExtension: pathExtension), directoryHint: .notDirectory)
        return try queue.sync {
            let manager = FileManager.default
            let previous = loadedEntries()[name]
            try prepareDirectory()
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            if let previous, previous.url != url { try? manager.removeItem(at: previous.url) }
            let used = now()
            try? manager.setAttributes(
                [.modificationDate: used], ofItemAtPath: url.path(percentEncoded: false))
            let evicted: [URL] = state.withLock { state in
                var entries = state.entries ?? [:]
                entries[name] = Entry(url: url, size: data.count, lastUsed: used)
                var total = entries.values.reduce(0) { $0 + $1.size }
                var evicted: [URL] = []
                for (other, entry) in entries.sorted(by: { $0.value.lastUsed < $1.value.lastUsed })
                where total > capacity && other != name {
                    entries[other] = nil
                    total -= entry.size
                    evicted.append(entry.url)
                }
                state.entries = entries
                return evicted
            }
            for file in evicted { try? manager.removeItem(at: file) }
            return url
        }
    }

    /// Deletes the files unused for more than `age` before `now()`.
    func prune(olderThan age: Duration) {
        let parts = age.components
        let cutoff = now().addingTimeInterval(
            -(TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18))
        queue.async { [self] in
            var entries = loadedEntries()
            let stale = entries.filter { $0.value.lastUsed < cutoff }
            for name in stale.keys { entries[name] = nil }
            state.withLock { $0.entries = entries }
            for entry in stale.values { try? FileManager.default.removeItem(at: entry.url) }
        }
    }

    /// Waits for every write and removal queued so far.
    func flush() {
        queue.sync {}
    }

    /// The index, read from the directory the first time. On the queue.
    private func loadedEntries() -> [String: Entry] {
        if let entries = state.withLock({ $0.entries }) { return entries }
        var entries: [String: Entry] = [:]
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: keys)) ?? []
        for url in files {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                values.isRegularFile == true
            else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            let entry = Entry(
                url: url, size: values.fileSize ?? 0,
                lastUsed: values.contentModificationDate ?? .distantPast)
            // Two extensions for one key: keep the newer, drop the other.
            if let existing = entries[name] {
                let (keep, drop) = existing.lastUsed >= entry.lastUsed ? (existing, entry) : (entry, existing)
                entries[name] = keep
                try? FileManager.default.removeItem(at: drop.url)
            } else {
                entries[name] = entry
            }
        }
        state.withLock { $0.entries = entries }
        return entries
    }

    /// Creates the directory with complete file protection, excluded from backup.
    private func prepareDirectory() throws {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: directory.path(percentEncoded: false)) else { return }
        try manager.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var root = directory
        do {
            try root.setResourceValues(values)
        } catch {
            Self.log.debug("Chat media cache backup exclusion skipped: \(error.localizedDescription)")
        }
    }

    private static func digest(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
