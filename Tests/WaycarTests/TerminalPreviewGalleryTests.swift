import Foundation
import Testing

@testable import Waycar

/// What a gallery opened from Files & Links reads, and when: the page on
/// screen first — the tapped one at once, one arrived on once the user has
/// stayed on it — at most one image beside it ahead, never a PDF ahead, no
/// read stopped only to be started again, and no copy outliving its need.
@MainActor
struct TerminalPreviewGalleryTests {
    /// Markdown opens its own sheet and is never paged to; the gallery
    /// keeps the index's order and opens on the tapped file.
    @Test func theGalleryPagesThroughTheIndexsImagesAndPDFs() throws {
        let index = [image(0), markdown("README"), pdf(1), image(2)]
        let session = try #require(
            TerminalPreviewGallerySession(opening: pdf(1), in: index, workingDirectory: "/w"))
        #expect(session.files.map(\.path) == ["/w/0.png", "/w/1.pdf", "/w/2.png"])
        #expect(session.startIndex == 1)
        #expect(TerminalPreviewGallerySession(opening: markdown("README"), in: index, workingDirectory: "/w") == nil)
    }

    @Test func thePageOnScreenIsReadFirst() async throws {
        let (root, reader, store) = setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = gallery([image(0), image(1), image(2)], start: 1, store: store)
        defer { model.close() }

        try await waitUntil { await reader.active == ["/w/1.png"] }
        #expect(await reader.started == ["/w/1.png"])
        await reader.answer("/w/1.png")
        try await waitUntil { await reader.active == ["/w/2.png"] }
        #expect(isReady(model.pages[1]))
        #expect(await reader.started == ["/w/1.png", "/w/2.png"])
    }

    /// A read ahead carries on as the page's own when the user arrives on
    /// it, and one beside a page picked from the list carries on next to
    /// that page's read; nothing more is ever started.
    @Test func noMoreThanOneReadIsInFlightBeyondThePageOnScreen() async throws {
        let (root, reader, store) = setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = gallery((0..<6).map(image), start: 0, store: store)
        defer { model.close() }

        try await waitUntil { await reader.active == ["/w/0.png"] }
        await reader.answer("/w/0.png")
        try await waitUntil { await reader.active == ["/w/1.png"] }
        model.show(1)
        await reader.answer("/w/1.png")
        try await waitUntil { await reader.active == ["/w/2.png"] }
        #expect(await reader.started == ["/w/0.png", "/w/1.png", "/w/2.png"])

        model.show(3)
        try await waitUntil { await Set(reader.active) == ["/w/2.png", "/w/3.png"] }
        await reader.answer("/w/3.png")
        try await waitUntil { isReady(model.pages[3]) }
        // Page 3 has landed, but page 2 is still being read: 4 waits.
        #expect(model.pages[4] == .waiting)
        #expect(await reader.active == ["/w/2.png"])
        await reader.answer("/w/2.png")
        try await waitUntil { await reader.active == ["/w/4.png"] }

        #expect(await reader.mostActive == 2)
        #expect(await reader.cancelled.isEmpty)
    }

    /// A PDF is read only once it is on screen; an image beside one is
    /// still read ahead.
    @Test func aPDFIsNeverReadAhead() async throws {
        let (root, reader, store) = setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = gallery([pdf(0), image(1), pdf(2), image(3)], start: 1, store: store)
        defer { model.close() }

        try await waitUntil { await reader.active == ["/w/1.png"] }
        await reader.answer("/w/1.png")
        try await waitUntil { isReady(model.pages[1]) }
        // Page 1 has landed: neither PDF beside it is read ahead.
        #expect(model.pages[0] == .waiting)
        #expect(model.pages[2] == .waiting)
        #expect(await reader.started == ["/w/1.png"])

        model.show(2)
        try await waitUntil { await reader.active == ["/w/2.pdf"] }
        await reader.answer("/w/2.pdf")
        try await waitUntil { await reader.active == ["/w/3.png"] }
        #expect(await reader.started == ["/w/1.png", "/w/2.pdf", "/w/3.png"])
    }

    /// Leaving a page stops its read unless it is an image beside the page
    /// arrived on, which carries on as the read-ahead. A PDF left stops,
    /// and so does a read ahead no longer beside the page on screen; none
    /// writes a copy, and a page stopped is read again on arrival.
    @Test func leavingAPageStopsItsRead() async throws {
        let (root, reader, store) = setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = gallery([image(0), pdf(1), image(2), image(3)], start: 1, store: store)
        defer { model.close() }

        try await waitUntil { await reader.active == ["/w/1.pdf"] }
        model.show(2)
        try await waitUntil { await reader.cancelled == ["/w/1.pdf"] }
        #expect(model.pages[1] == .waiting)
        try await waitUntil { await reader.active == ["/w/2.png"] }
        await reader.answer("/w/2.png")
        try await waitUntil { await reader.active == ["/w/3.png"] }

        model.show(0)
        try await waitUntil { await reader.cancelled == ["/w/1.pdf", "/w/3.png"] }
        try await waitUntil { await reader.active == ["/w/0.png"] }

        model.show(1)
        try await waitUntil { await Set(reader.active) == ["/w/0.png", "/w/1.pdf"] }
        #expect(await reader.cancelled == ["/w/1.pdf", "/w/3.png"])
        #expect(await reader.started == ["/w/1.pdf", "/w/2.png", "/w/3.png", "/w/0.png", "/w/1.pdf"])
        #expect(copies(in: root).count == 1)
    }

    /// Pages only swiped past open no read: one the user arrives on is
    /// read once they have stayed on it, and leaving it first cancels the
    /// wait. The page tapped is read at once.
    @Test func aPageOnlySwipedPastIsNeverRead() async throws {
        let (root, reader, store) = setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let dwell = DwellGate()
        let model = gallery((0..<6).map(image), start: 1, store: store, dwell: { try await dwell.pass() })
        defer { model.close() }

        try await waitUntil { await reader.active == ["/w/1.png"] }
        model.show(2)
        try await waitUntil { await dwell.entries == 1 }
        model.show(3)
        try await waitUntil { await dwell.cancelled == 1 }
        try await waitUntil { await dwell.entries == 2 }
        model.show(4)
        try await waitUntil { await dwell.cancelled == 2 }
        try await waitUntil { await dwell.entries == 3 }
        #expect(model.pages[2] == .waiting)
        #expect(model.pages[3] == .waiting)
        #expect(model.pages[4] == .waiting)

        await dwell.open()
        try await waitUntil { await reader.active == ["/w/4.png"] }
        #expect(await reader.started == ["/w/1.png", "/w/4.png"])
        #expect(model.pages[2] == .waiting)
        #expect(model.pages[3] == .waiting)
    }

    /// A page being read ahead keeps that read when the user arrives on
    /// it, without waiting for them to stay, and keeps it again when they
    /// step back and forth: it is read once.
    @Test func arrivingOnAPageBeingReadAheadKeepsThatRead() async throws {
        let (root, reader, store) = setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let dwell = DwellGate()
        let model = gallery((0..<4).map(image), start: 0, store: store, dwell: { try await dwell.pass() })
        defer { model.close() }

        try await waitUntil { await reader.active == ["/w/0.png"] }
        await reader.answer("/w/0.png")
        try await waitUntil { await reader.active == ["/w/1.png"] }
        model.show(1)
        model.show(0)
        model.show(1)
        await reader.answer("/w/1.png")
        try await waitUntil { isReady(model.pages[1]) }
        try await waitUntil { await reader.active == ["/w/2.png"] }

        #expect(await reader.started == ["/w/0.png", "/w/1.png", "/w/2.png"])
        #expect(await reader.cancelled.isEmpty)
        #expect(await dwell.entries == 0)
    }

    /// Past the limit the copy farthest from the page on screen goes, from
    /// disk too, and is read again when the user comes back to it.
    @Test func copiesPastTheLimitGoFarthestFirst() async throws {
        let paths = (0..<8).map { "/w/\($0).png" }
        let (root, reader, store) = setUp(answering: paths)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = gallery((0..<8).map(image), start: 0, store: store)
        defer { model.close() }

        try await waitUntil { isReady(model.pages[0]) }
        guard case .ready(let first) = model.pages[0] else { return }
        for page in 1..<8 {
            model.show(page)
            try await waitUntil { isReady(model.pages[page]) }
        }
        try await waitUntil { await reader.started.count == 8 }

        #expect(model.pages.indices.filter { isReady(model.pages[$0]) } == [3, 4, 5, 6, 7])
        #expect(copies(in: root).count == TerminalPreviewGalleryModel.heldCopyLimit)
        #expect(!FileManager.default.fileExists(atPath: first.path))

        model.show(0)
        try await waitUntil { isReady(model.pages[0]) }
        #expect(await reader.started.filter { $0 == "/w/0.png" }.count == 2)
        #expect(model.pages.filter(isReady).count <= TerminalPreviewGalleryModel.heldCopyLimit)
        #expect(copies(in: root).count == model.pages.filter(isReady).count)
    }

    /// Closing the gallery stops its read and removes every copy and
    /// stand-in it wrote.
    @Test func closingTheGalleryRemovesEverything() async throws {
        let (root, reader, store) = setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = gallery([image(0), image(1)], start: 0, store: store)

        try await waitUntil { await reader.active == ["/w/0.png"] }
        await reader.answer("/w/0.png")
        try await waitUntil { await reader.active == ["/w/1.png"] }
        _ = try store.galleryStandIn(Data("stand-in".utf8), forRemotePath: "/w/1.png", note: "loading")
        #expect(copies(in: root).count == 2)

        model.close()
        #expect(copies(in: root).isEmpty)
        try await waitUntil { await reader.cancelled == ["/w/1.png"] }
    }

    /// A stand-in shared or saved from Quick Look while its page is not
    /// read is named after the file and what it stands in for, so it is
    /// plainly not the file; a path naming no file reads as `file`.
    @Test func aStandInIsNamedForWhatItStandsIn() throws {
        let (root, _, store) = setUp()
        defer { try? FileManager.default.removeItem(at: root) }

        let loading = try store.galleryStandIn(Data("png".utf8), forRemotePath: "shots/chart.png", note: "loading")
        #expect(loading.lastPathComponent == "chart.png (loading).png")
        let unnamed = try store.galleryStandIn(Data("png".utf8), forRemotePath: "/", note: "unavailable")
        #expect(unnamed.lastPathComponent == "file (unavailable).png")
    }

    /// The detail leaving removes a gallery's copies with the store's own,
    /// and a gallery read still in flight then writes none.
    @Test func theDetailClosingRemovesTheGallerysCopies() async throws {
        let (root, reader, store) = setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = gallery([image(0), image(1)], start: 0, store: store)
        defer { model.close() }

        try await waitUntil { await reader.active == ["/w/0.png"] }
        await reader.answer("/w/0.png")
        try await waitUntil { await reader.active == ["/w/1.png"] }
        store.close()
        #expect(copies(in: root).isEmpty)

        await reader.answer("/w/1.png")
        try await waitUntil { model.pages[1] != .loading }
        #expect(!isReady(model.pages[1]))
        #expect(copies(in: root).isEmpty)
    }

    /// A page whose read fails says why in place, and the image beside it
    /// is read all the same.
    @Test func aFailedPageDoesNotHoldUpItsNeighbours() async throws {
        let (root, reader, store) = setUp(failing: ["/w/1.png"])
        defer { try? FileManager.default.removeItem(at: root) }
        let model = gallery([image(0), image(1), image(2)], start: 1, store: store)
        defer { model.close() }

        try await waitUntil { model.pages[1] != .loading }
        #expect(model.pages[1] == .failed(
            message: TerminalFilePreviewStore.failureMessage(for: RemoteFilePreviewError.missing)))
        try await waitUntil { await reader.active == ["/w/2.png"] }
        await reader.answer("/w/2.png")
        try await waitUntil { isReady(model.pages[2]) }

        model.show(0)
        try await waitUntil { await reader.active == ["/w/0.png"] }
    }

    /// Bad selections and repeated teardown are harmless through the
    /// model's public API, including an empty session.
    @Test func closedAndEmptyGalleriesNeverStartMoreWork() async throws {
        let (root, reader, store) = setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = gallery([], start: 0, store: store)
        empty.show(-1)
        empty.show(1)
        #expect(empty.pages.isEmpty)
        empty.close()
        empty.close()

        let model = gallery([pdf(0), pdf(1)], start: 0, store: store)
        try await waitUntil { await reader.active == ["/w/0.pdf"] }
        model.show(-1)
        model.show(2)
        #expect(model.current == 0)
        model.close()
        model.close()
        model.show(1)
        try await waitUntil { await reader.cancelled == ["/w/0.pdf"] }
        #expect(model.current == 0)
        #expect(await reader.started == ["/w/0.pdf"])
    }

    @Test func pageNotificationsFollowTheChangedPresentation() async throws {
        let (root, reader, store) = setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = TerminalPreviewGalleryModel(
            session: TerminalPreviewGallerySession(files: [pdf(0)], startIndex: 0, workingDirectory: "/w"),
            store: store)
        defer { model.close() }
        var changes: [TerminalPreviewGalleryModel.Page] = []
        model.pageDidChange = { index in changes.append(model.pages[index]) }
        model.show(0)
        try await waitUntil { await reader.active == ["/w/0.pdf"] }
        #expect(changes == [.loading])
        await reader.answer("/w/0.pdf")
        try await waitUntil { changes.count == 2 }
        #expect(isReady(changes[1]))
        model.show(0)
        #expect(changes.count == 2)
    }

    // MARK: Helpers

    private func setUp(
        answering answered: [String] = [], failing failed: [String] = []
    ) -> (URL, ScriptedReader, TerminalFilePreviewStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TerminalPreviewGalleryTests-\(UUID().uuidString)", isDirectory: true)
        var standing: [String: Result<Data, any Error>] = [:]
        for path in answered { standing[path] = .success(Data(path.utf8)) }
        for path in failed { standing[path] = .failure(RemoteFilePreviewError.missing) }
        let reader = ScriptedReader(standing: standing)
        let store = TerminalFilePreviewStore(
            read: { path, _ in try await reader.read(path) },
            resolveHome: { "/home/me" },
            temporaryRoot: root)
        return (root, reader, store)
    }

    /// A page arrived on is read as soon as `dwell` returns: at once unless
    /// a test holds it.
    private func gallery(
        _ files: [TerminalStripFile], start: Int, store: TerminalFilePreviewStore,
        dwell: @escaping @Sendable () async throws -> Void = {}
    ) -> TerminalPreviewGalleryModel {
        let model = TerminalPreviewGalleryModel(
            session: TerminalPreviewGallerySession(files: files, startIndex: start, workingDirectory: "/w"),
            store: store, dwell: dwell)
        model.show(start)
        return model
    }

    private func image(_ number: Int) -> TerminalStripFile {
        TerminalStripFile(path: "/w/\(number).png", kind: .image, thumbnail: nil)
    }

    private func pdf(_ number: Int) -> TerminalStripFile {
        TerminalStripFile(path: "/w/\(number).pdf", kind: .pdf, thumbnail: nil)
    }

    private func markdown(_ name: String) -> TerminalStripFile {
        TerminalStripFile(path: "/w/\(name).md", kind: .markdown, thumbnail: nil)
    }

    private func isReady(_ page: TerminalPreviewGalleryModel.Page) -> Bool {
        if case .ready = page { return true }
        return false
    }

    /// The private directories under `root` still holding a file.
    private func copies(in root: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    }

    /// Polls until `condition` holds, and fails the test when it still
    /// does not by the deadline.
    private func waitUntil(
        timeout: Duration = .waitCeiling,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await condition(), "timed out waiting", sourceLocation: sourceLocation)
    }
}

/// Reads that answer when the test says so, or at once for a path given a
/// standing answer; a cancelled read ends with `CancellationError`, the
/// way the transport closes the channel.
private actor ScriptedReader {
    private(set) var started: [String] = []
    private(set) var active: [String] = []
    private(set) var cancelled: [String] = []
    /// The most reads waiting at once.
    private(set) var mostActive = 0
    private let standing: [String: Result<Data, any Error>]
    private var waiting: [String: CheckedContinuation<Data, any Error>] = [:]

    init(standing: [String: Result<Data, any Error>]) {
        self.standing = standing
    }

    func read(_ path: String) async throws -> Data {
        started.append(path)
        if let answer = standing[path] { return try answer.get() }
        active.append(path)
        mostActive = max(mostActive, active.count)
        defer { if let index = active.firstIndex(of: path) { active.remove(at: index) } }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiting[path] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(path) }
        }
    }

    /// Answers the read of `path` waiting now.
    func answer(_ path: String) {
        waiting.removeValue(forKey: path)?.resume(returning: Data(path.utf8))
    }

    private func cancel(_ path: String) {
        cancelled.append(path)
        waiting.removeValue(forKey: path)?.resume(throwing: CancellationError())
    }
}

/// The user staying on a page, as long as the test says: each wait holds
/// until ``open()``, and one cancelled — the user left the page — ends at
/// once with `CancellationError`.
private actor DwellGate {
    /// Waits begun, and how many of them were cancelled.
    private(set) var entries = 0
    private(set) var cancelled = 0
    private var waiting: [Int: CheckedContinuation<Void, any Error>] = [:]

    func pass() async throws {
        entries += 1
        let id = entries
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    cancelled += 1
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiting[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    /// Ends every wait held now.
    func open() {
        let held = waiting
        waiting = [:]
        for continuation in held.values { continuation.resume() }
    }

    private func cancel(_ id: Int) {
        guard let continuation = waiting.removeValue(forKey: id) else { return }
        cancelled += 1
        continuation.resume(throwing: CancellationError())
    }
}
