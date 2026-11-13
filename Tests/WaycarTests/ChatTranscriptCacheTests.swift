import Foundation
import Synchronization
import Testing

@testable import Waycar

/// The on-device last transcript per Chat Mode Agent: what a chat may paint
/// before the Host answers, and what it must refuse to show.
@Suite("Chat transcript cache")
struct ChatTranscriptCacheTests {
    private let directory = FileManager.default.temporaryDirectory
        .appending(path: "chat-transcripts-\(UUID().uuidString)", directoryHint: .isDirectory)

    private func key(
        host: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID(),
        pane: String = "w1:p1", terminal: String = "t1",
        launchedAt: String = "2026-09-30T12:00:00.000Z"
    ) -> ChatTranscriptCache.Key {
        ChatTranscriptCache.Key(hostID: host, paneID: pane, terminalID: terminal, launchedAt: launchedAt)
    }

    private func message(_ index: Int, text: String? = nil) -> ChatTranscriptMessage {
        ChatTranscriptMessage(
            id: "m\(index)", role: index.isMultiple(of: 2) ? .user : .assistant,
            text: text ?? "message \(index)",
            timestamp: index.isMultiple(of: 3) ? nil : Date(timeIntervalSince1970: 1_800_000_000.5 + Double(index)))
    }

    private func modificationDate(_ url: URL) throws -> Date? {
        try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.modificationDate] as? Date
    }

    @Test func aSavedTranscriptReadsBackAfterARelaunch() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let messages = (0..<5).map { message($0) }
        let writer = ChatTranscriptCache(directory: directory)
        writer.save(messages, for: key())
        #expect(writer.messages(for: key()) == messages)
        writer.flush()

        let reader = ChatTranscriptCache(directory: directory)
        #expect(reader.messages(for: key()) == messages)
    }

    @Test func richCardsReadBackAfterARelaunch() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let cards: [ChatTranscriptCard] = [
            .questions(ChatQuestionCard(body: "Choose", questions: [ChatQuestion(
                ref: "1", text: "Which?", kind: "choice", options: [ChatQuestionOption(
                    key: "a", label: "First", detail: "Recommended", recommended: true)])])),
            .branch(ChatBranchPointer(conversationId: 42, title: "Fix", at: Date(timeIntervalSince1970: 123))),
            .failure(ChatFailureCard(conversationId: 42, title: "Fix", error: "Failed", step: "Test")),
            .divider(kind: "reset", label: "Reset"),
            .toolSteps(ChatToolStepsSummary(count: 3, summary: "read ×3")),
        ]
        let messages = cards.enumerated().map { index, card in
            ChatTranscriptMessage(id: String(index), role: .assistant, text: "", timestamp: nil, card: card)
        }
        let writer = ChatTranscriptCache(directory: directory)
        writer.save(messages, for: key())
        writer.flush()
        #expect(ChatTranscriptCache(directory: directory).messages(for: key()) == messages)
        #expect(ChatTranscriptCache.formatVersion == 3)
    }

    @Test func mediaOfEverySourceReadsBackAfterARelaunch() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try #require(URL(string: "https://example.com/shot.png"))
        let reply = ChatTranscriptMessage(
            id: "a1", role: .assistant, text: "Here.", timestamp: nil,
            media: [
                ChatMedia(id: "blob:sha256:ab", kind: .image, mime: "image/webp",
                          source: .hostFile(path: "/Users/x/.omp/agent/blobs/ab")),
                ChatMedia(id: "inline:9:/p", kind: .image, mime: nil,
                          source: .inline(transcript: "/t/s.jsonl", offset: 9, pointer: "/p")),
                ChatMedia(id: "inline:/messages/0/parts/1/url", kind: .image, mime: "image/png",
                          source: .sessionInline(
                              session: "ses_demo", pointer: "/messages/0/parts/1/url", agentKind: nil)),
                ChatMedia(id: "inline:/messages/1/parts/0/url", kind: .image, mime: "image/png",
                          source: .sessionInline(
                              session: "ses_kilo", pointer: "/messages/1/parts/0/url", agentKind: "kilo")),
                ChatMedia(id: "file:/Users/me/demo/shot.png", kind: .file, mime: "image/png",
                          source: .hostFile(path: "/Users/me/demo/shot.png")),
                ChatMedia(id: "web", kind: .video, mime: "video/mp4", source: .web(url), alt: "Demo"),
            ])
        let writer = ChatTranscriptCache(directory: directory)
        writer.save([message(0), reply], for: key())
        writer.flush()

        let reader = ChatTranscriptCache(directory: directory)
        #expect(reader.messages(for: key()) == [message(0), reply])
    }

    @Test func aFirstVersionFileReadsEmptyAndIsDeleted() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = ChatTranscriptCache(directory: directory)
        writer.save([message(1)], for: key())
        writer.flush()
        let url = writer.fileURL(for: key())
        let current = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var first = current
        // Only the version differs, so the version alone is refused.
        first["version"] = 1
        try JSONSerialization.data(withJSONObject: first).write(to: url)

        let reader = ChatTranscriptCache(directory: directory)
        #expect(reader.messages(for: key()).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }

    @Test func anotherTerminalOrLaunchHasNoMessages() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = ChatTranscriptCache(directory: directory)
        writer.save([message(1)], for: key())
        writer.flush()

        let reader = ChatTranscriptCache(directory: directory)
        #expect(reader.messages(for: key(terminal: "t2")).isEmpty)
        #expect(reader.messages(for: key(launchedAt: "")).isEmpty)
        #expect(reader.messages(for: key(pane: "w1:p2")).isEmpty)
        #expect(reader.messages(for: key()) == [message(1)])
    }

    @Test func theMessageCapKeepsTheNewestInOrder() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let messages = (0..<(ChatTranscriptCache.maxMessages + 50)).map { message($0) }
        let writer = ChatTranscriptCache(directory: directory)
        writer.save(messages, for: key())
        writer.flush()

        let read = ChatTranscriptCache(directory: directory).messages(for: key())
        #expect(read == Array(messages.suffix(ChatTranscriptCache.maxMessages)))
    }

    @Test func anOversizeListDropsTheOldestToFitTheByteLimit() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let big = String(repeating: "x", count: 100_000)
        let messages = (0..<40).map { message($0, text: big) }
        let writer = ChatTranscriptCache(directory: directory)
        writer.save(messages, for: key())
        writer.flush()

        let read = ChatTranscriptCache(directory: directory).messages(for: key())
        #expect(!read.isEmpty)
        #expect(read.count < messages.count)
        #expect(read == Array(messages.suffix(read.count)))
        let size = try Data(contentsOf: writer.fileURL(for: key())).count
        #expect(size <= ChatTranscriptCache.maxBytes)
    }

    @Test func anIdenticalSaveWritesNothing() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let messages = (0..<3).map { message($0) }
        let writer = ChatTranscriptCache(directory: directory)
        writer.save(messages, for: key())
        writer.flush()
        let url = writer.fileURL(for: key())
        let before = try Data(contentsOf: url)
        let beforeDate = try modificationDate(url)

        // After a relaunch the file's copy counts as held.
        let reader = ChatTranscriptCache(directory: directory, now: { Date().addingTimeInterval(3_600) })
        #expect(reader.messages(for: key()) == messages)
        reader.save(messages, for: key())
        reader.flush()
        writer.save(messages, for: key())
        writer.flush()

        #expect(try Data(contentsOf: url) == before)
        #expect(try modificationDate(url) == beforeDate)
    }

    @Test func aCorruptFileReadsEmptyAndIsDeleted() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = ChatTranscriptCache(directory: directory)
        writer.save([message(1)], for: key())
        writer.flush()
        let url = writer.fileURL(for: key())
        try Data("not json".utf8).write(to: url)

        let reader = ChatTranscriptCache(directory: directory)
        #expect(reader.messages(for: key()).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }

    @Test func removingAPaneRemovesOnlyThatPane() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ChatTranscriptCache(directory: directory)
        cache.save([message(1)], for: key(pane: "w1:p1"))
        cache.save([message(1)], for: key(pane: "w1:p1", terminal: "t2"))
        cache.save([message(2)], for: key(pane: "w1:p2"))
        cache.flush()

        cache.remove(hostID: key().hostID, paneID: "w1:p1")
        #expect(cache.messages(for: key(pane: "w1:p1")).isEmpty)
        cache.flush()

        let reader = ChatTranscriptCache(directory: directory)
        #expect(reader.messages(for: key(pane: "w1:p1")).isEmpty)
        #expect(reader.messages(for: key(pane: "w1:p1", terminal: "t2")).isEmpty)
        #expect(reader.messages(for: key(pane: "w1:p2")) == [message(2)])
    }

    @Test func retainOnlyRemovesOtherHosts() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let kept = UUID()
        let dropped = UUID()
        let cache = ChatTranscriptCache(directory: directory)
        cache.save([message(1)], for: key(host: kept))
        cache.save([message(2)], for: key(host: dropped))
        cache.flush()

        cache.retainOnly([kept])
        cache.flush()

        let reader = ChatTranscriptCache(directory: directory)
        #expect(reader.messages(for: key(host: kept)) == [message(1)])
        #expect(reader.messages(for: key(host: dropped)).isEmpty)
    }

    @Test func pruneRemovesStaleFilesAndKeepsFreshOnes() {
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = TestClock(start)
        let cache = ChatTranscriptCache(directory: directory, now: { clock.now })
        cache.save([message(1)], for: key(pane: "stale"))
        cache.flush()
        clock.now = start.addingTimeInterval(20 * 24 * 3600)
        cache.save([message(2)], for: key(pane: "fresh"))
        cache.flush()

        clock.now = start.addingTimeInterval(31 * 24 * 3600)
        cache.prune(olderThan: .seconds(30 * 24 * 3600))
        cache.flush()

        #expect(!FileManager.default.fileExists(
            atPath: cache.fileURL(for: key(pane: "stale")).path(percentEncoded: false)))
        let reader = ChatTranscriptCache(directory: directory)
        #expect(reader.messages(for: key(pane: "stale")).isEmpty)
        #expect(reader.messages(for: key(pane: "fresh")) == [message(2)])
    }
}

/// A settable `now` for the cache's injected clock.
private final class TestClock: Sendable {
    private let date: Mutex<Date>
    init(_ date: Date) { self.date = Mutex(date) }
    var now: Date {
        get { date.withLock { $0 } }
        set { date.withLock { $0 = newValue } }
    }
}
