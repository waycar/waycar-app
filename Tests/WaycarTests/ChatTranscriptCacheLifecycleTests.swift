import Foundation
import Synchronization
import Testing

@testable import Waycar

/// Pins the transcript cache's per-key lifecycle (CHAT-07) through its own
/// API: the on-disk envelope, what memory remembers of a missing file, and
/// which removals forget what.
@Suite("Chat transcript cache lifecycle")
struct ChatTranscriptCacheLifecycleTests {
    private let directory = FileManager.default.temporaryDirectory
        .appending(path: "chat-transcripts-\(UUID().uuidString)", directoryHint: .isDirectory)
    private let host = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA") ?? UUID()

    private func key(pane: String = "w1:p1", terminal: String = "t1") -> ChatTranscriptCache.Key {
        ChatTranscriptCache.Key(
            hostID: host, paneID: pane, terminalID: terminal, launchedAt: "2026-09-30T12:00:00.000Z")
    }

    private func message(_ id: String, _ text: String) -> ChatTranscriptMessage {
        ChatTranscriptMessage(
            id: id, role: .assistant, text: text,
            timestamp: Date(timeIntervalSince1970: 1_800_000_000.25))
    }

    private func object(_ url: URL) throws -> NSDictionary {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? NSDictionary)
    }

    /// Round trip: a hand-written version-3 envelope reads back, and a save of
    /// what it held writes the same JSON object.
    @Test func theEnvelopeReadsAndWritesUnchanged() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let saved = Date(timeIntervalSince1970: 1_800_000_100)
        let golden = """
            {"version":3,"savedAt":"\(ChatModeTimestamp.string(from: saved))",\
            "hostID":"\(host.uuidString)","paneID":"w1:p1","terminalID":"t1",\
            "launchedAt":"2026-09-30T12:00:00.000Z","identity":"agent-a",\
            "messages":[{"id":"m1","role":"assistant","text":"hello",\
            "ts":"\(ChatModeTimestamp.string(from: Date(timeIntervalSince1970: 1_800_000_000.25)))",\
            "media":[{"id":"i1","kind":"image","mime":"image/png","path":"/tmp/a.png"}]}]}
            """
        let seed = ChatTranscriptCache(directory: directory)
        let url = seed.fileURL(for: key())
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(golden.utf8).write(to: url)

        let reader = ChatTranscriptCache(directory: directory, now: { saved })
        let read = reader.messages(for: key(), identity: "agent-a")
        #expect(read.count == 1)
        #expect(read.first?.text == "hello")
        #expect(read.first?.media.first?.source == .hostFile(path: "/tmp/a.png"))
        #expect(reader.savedAt(for: key(), identity: "agent-a") == saved)
        #expect(reader.messages(for: key(), identity: "agent-b").isEmpty)

        // Written again by a cache that never read it: the same object.
        try FileManager.default.removeItem(at: url)
        let writer = ChatTranscriptCache(directory: directory, now: { saved })
        writer.save(read, for: key(), identity: "agent-a")
        writer.flush()
        let expected = try #require(
            try JSONSerialization.jsonObject(with: Data(golden.utf8)) as? NSDictionary)
        #expect(try object(url) == expected)
    }

    @Test func aKeyFoundMissingIsNotAskedAgainUntilItsPaneIsRemoved() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ChatTranscriptCache(directory: directory)
        #expect(cache.messages(for: key()).isEmpty)

        // Another writer's file is not seen: memory knows the key is missing.
        let other = ChatTranscriptCache(directory: directory)
        other.save([message("m1", "other")], for: key())
        other.flush()
        #expect(cache.messages(for: key()).isEmpty)
        #expect(cache.savedAt(for: key()) == nil)

        // Removing a different pane leaves that knowledge alone.
        cache.remove(hostID: host, paneID: "w1:p9")
        cache.flush()
        #expect(cache.messages(for: key()).isEmpty)

        // Removing its pane forgets it, so the disk is asked again.
        cache.remove(hostID: host, paneID: "w1:p1")
        cache.flush()
        other.remove(key())
        other.save([message("m2", "again")], for: key())
        other.flush()
        #expect(cache.messages(for: key()) == [message("m2", "again")])
    }

    @Test func removingAKeyMarksItMissingAndRemovingItsHostForgetsThat() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ChatTranscriptCache(directory: directory)
        cache.save([message("m1", "one")], for: key())
        cache.flush()
        cache.remove(key())
        cache.flush()

        let other = ChatTranscriptCache(directory: directory)
        other.save([message("m2", "two")], for: key())
        other.flush()
        #expect(cache.messages(for: key()).isEmpty)

        cache.remove(hostID: host)
        cache.flush()
        let third = ChatTranscriptCache(directory: directory)
        third.save([message("m3", "three")], for: key())
        third.flush()
        #expect(cache.messages(for: key()) == [message("m3", "three")])
    }

    @Test func retainOnlyForgetsHeldListsButRemembersMissingKeys() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ChatTranscriptCache(directory: directory)
        let held = key(pane: "held")
        let missing = key(pane: "missing")
        cache.save([message("m1", "held")], for: held)
        #expect(cache.messages(for: missing).isEmpty)
        cache.flush()

        cache.retainOnly([])
        cache.flush()
        let other = ChatTranscriptCache(directory: directory)
        other.save([message("m2", "new held")], for: held)
        other.save([message("m3", "new missing")], for: missing)
        other.flush()

        // The held list is gone from memory, so the disk answers; the missing
        // key is still known missing.
        #expect(cache.messages(for: held) == [message("m2", "new held")])
        #expect(cache.messages(for: missing).isEmpty)
    }

    @Test func pruneForgetsAPrunedListSoTheDiskIsAskedAgain() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = LifecycleClock(start)
        let cache = ChatTranscriptCache(directory: directory, now: { clock.now })
        cache.save([message("m1", "old")], for: key())
        cache.flush()
        clock.now = start.addingTimeInterval(40 * 24 * 3600)
        cache.prune(olderThan: .seconds(30 * 24 * 3600))
        cache.flush()
        #expect(!FileManager.default.fileExists(atPath: cache.fileURL(for: key()).path(percentEncoded: false)))

        let other = ChatTranscriptCache(directory: directory)
        other.save([message("m2", "fresh")], for: key())
        other.flush()
        #expect(cache.messages(for: key()) == [message("m2", "fresh")])
    }

    @Test func anotherIdentitysSaveReplacesTheListAndOnlyItsOwnerConfirms() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = LifecycleClock(start)
        let cache = ChatTranscriptCache(directory: directory, now: { clock.now })
        cache.save([message("m1", "a")], for: key(), identity: "a")
        cache.save([message("m1", "a")], for: key(), identity: "b")
        #expect(cache.messages(for: key(), identity: "a").isEmpty)
        #expect(cache.messages(for: key(), identity: "b") == [message("m1", "a")])
        cache.flush()
        #expect(try object(cache.fileURL(for: key()))["identity"] as? String == "b")

        clock.now = start.addingTimeInterval(600)
        #expect(!cache.confirm(key(), identity: "a"))
        #expect(cache.savedAt(for: key(), identity: "b") == start)
        #expect(cache.confirm(key(), identity: "b"))
        cache.flush()
        #expect(cache.savedAt(for: key(), identity: "b") == start.addingTimeInterval(600))
        #expect(ChatTranscriptCache(directory: directory).savedAt(for: key(), identity: "b")
            == start.addingTimeInterval(600))
    }

    @Test func savesBeforeTheWriteLandsWriteTheNewestList() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ChatTranscriptCache(directory: directory)
        for index in 1...20 {
            cache.save([message("m\(index)", "text \(index)")], for: key())
        }
        cache.remove(key(pane: "w1:p1", terminal: "unrelated"))
        cache.save([message("last", "last")], for: key())
        #expect(cache.messages(for: key()) == [message("last", "last")])
        cache.flush()
        #expect(ChatTranscriptCache(directory: directory).messages(for: key()) == [message("last", "last")])
    }
}

/// A settable `now` for the cache's injected clock.
private final class LifecycleClock: Sendable {
    private let date: Mutex<Date>
    init(_ date: Date) { self.date = Mutex(date) }
    var now: Date {
        get { date.withLock { $0 } }
        set { date.withLock { $0 = newValue } }
    }
}
