import Foundation
import Synchronization
import Testing

@testable import Waycar

/// The on-device copies of chat media: found again across launches, kept
/// under the byte cap by recency of use, and dropped once unused too long.
@Suite("Chat media cache")
struct ChatMediaCacheTests {
    private let directory = FileManager.default.temporaryDirectory
        .appending(path: "chat-media-\(UUID().uuidString)", directoryHint: .isDirectory)
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    @Test func aStoredFileIsFoundAgainAfterARelaunch() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data("png bytes".utf8)
        let writer = ChatMediaCache(directory: directory)
        let url = try writer.store(bytes, for: "host|file|/a/shot.png", pathExtension: "png")
        #expect(url.pathExtension == "png")
        #expect(!url.lastPathComponent.contains("shot"), "file names carry only digests")
        #expect(try Data(contentsOf: url) == bytes)
        #expect(writer.file(for: "host|file|/a/shot.png") == url)

        let reader = ChatMediaCache(directory: directory)
        #expect(reader.file(for: "host|file|/a/shot.png") == url)
        #expect(reader.file(for: "host|file|/a/other.png") == nil)
    }

    @Test func storingAKeyAgainReplacesItsFile() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ChatMediaCache(directory: directory)
        let first = try cache.store(Data([1]), for: "k", pathExtension: "jpg")
        let second = try cache.store(Data([2]), for: "k", pathExtension: "png")
        #expect(!exists(first))
        #expect(cache.file(for: "k") == second)
        #expect(try Data(contentsOf: second) == Data([2]))
    }

    @Test func aFileDeletedBehindTheCacheIsAMiss() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ChatMediaCache(directory: directory)
        let url = try cache.store(Data([1]), for: "k", pathExtension: "png")
        try FileManager.default.removeItem(at: url)
        #expect(cache.file(for: "k") == nil)
    }

    @Test func passingTheCapEvictsTheLeastRecentlyUsed() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = MediaTestClock(start)
        let cache = ChatMediaCache(directory: directory, now: { clock.now }, capacity: 250)
        let a = try cache.store(Data(count: 100), for: "a", pathExtension: "png")
        clock.advance(60)
        let b = try cache.store(Data(count: 100), for: "b", pathExtension: "png")
        clock.advance(60)
        // Looking `a` up makes `b` the least recently used.
        #expect(cache.file(for: "a") == a)
        clock.advance(60)
        let c = try cache.store(Data(count: 100), for: "c", pathExtension: "png")

        #expect(!exists(b))
        #expect(cache.file(for: "b") == nil)
        #expect(cache.file(for: "a") == a)
        #expect(cache.file(for: "c") == c)
    }

    @Test func recencyOfUseSurvivesARelaunch() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = MediaTestClock(start)
        let writer = ChatMediaCache(directory: directory, now: { clock.now }, capacity: 250)
        let a = try writer.store(Data(count: 100), for: "a", pathExtension: "png")
        clock.advance(60)
        let b = try writer.store(Data(count: 100), for: "b", pathExtension: "png")
        clock.advance(60)
        #expect(writer.file(for: "a") == a)

        clock.advance(60)
        let reader = ChatMediaCache(directory: directory, now: { clock.now }, capacity: 250)
        _ = try reader.store(Data(count: 100), for: "c", pathExtension: "png")
        #expect(!exists(b))
        #expect(exists(a))
    }

    @Test func pruneDropsFilesUnusedThatLong() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = MediaTestClock(start)
        let writer = ChatMediaCache(directory: directory, now: { clock.now })
        let stale = try writer.store(Data([1]), for: "stale", pathExtension: "png")
        let used = try writer.store(Data([2]), for: "used", pathExtension: "png")
        clock.advance(20 * 24 * 3600)
        #expect(writer.file(for: "used") == used)

        clock.advance(11 * 24 * 3600)
        // A relaunch: the index is rebuilt from the files' dates.
        let pruner = ChatMediaCache(directory: directory, now: { clock.now })
        pruner.prune(olderThan: .seconds(30 * 24 * 3600))
        pruner.flush()

        #expect(!exists(stale))
        #expect(pruner.file(for: "stale") == nil)
        #expect(pruner.file(for: "used") == used)
    }
}

/// A settable `now` for the cache's injected clock.
private final class MediaTestClock: Sendable {
    private let date: Mutex<Date>
    init(_ date: Date) { self.date = Mutex(date) }
    var now: Date { date.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { date.withLock { $0 = $0.addingTimeInterval(seconds) } }
}
