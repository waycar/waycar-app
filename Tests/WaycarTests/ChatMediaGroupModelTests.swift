import Foundation
import Testing

@testable import Waycar

/// A chat's media group. Its fetches run to their end whatever the view
/// does: the detail column can report a disappear for a chat that stays on
/// screen, and a cancelled fetch there left the spinner up for good.
@MainActor
@Suite("Chat media group")
struct ChatMediaGroupModelTests {
    private let item = ChatMedia(
        id: "m1", kind: .image, mime: "image/png", source: .hostFile(path: "/a.png"))

    /// Appearing again while the first fetch is under way starts no second
    /// one, and the first fetch's file is what the tile shows.
    @Test func startFetchesEachItemOnceAndShowsItsFile() async throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let gate = FetchGate()
        let model = ChatMediaGroupModel()
        let load: ChatMediaLoader = { _ in try await gate.fetch(returning: file) }

        model.start([item], using: load, maxPixelSize: 64)
        await gate.firstFetchStarted()
        model.start([item], using: load, maxPixelSize: 64)
        gate.finishHeldFetch()
        try await waitUntil { !model.files(of: [item]).isEmpty }

        #expect(model.files(of: [item]) == [file])
        #expect(gate.fetches == 1)
    }

    /// A failed item fetches again on a tap, and only then.
    @Test func aFailedItemFetchesAgainOnTap() async throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        var attempts = 0
        let model = ChatMediaGroupModel()
        let load: ChatMediaLoader = { _ in
            attempts += 1
            if attempts == 1 { throw ChatMediaError.unavailable }
            return file
        }

        model.start([item], using: load, maxPixelSize: 64)
        try await waitUntil {
            if case .failed(.unavailable) = model.phases[item.id] { true } else { false }
        }
        model.start([item], using: load, maxPixelSize: 64)
        // `start` would mark the item loading at once had it fetched again.
        #expect({ if case .failed = model.phases[item.id] { true } else { false } }())

        model.restart([item], using: load, maxPixelSize: 64)
        try await waitUntil { !model.files(of: [item]).isEmpty }
        #expect(model.files(of: [item]) == [file])
        #expect(attempts == 2)
    }

    /// The chat's view reported gone right after it appeared (the detail
    /// column does that on a reopen): a fetch it started still finishes.
    @Test func aFetchOutlivesTheCancelledContextThatStartedIt() async throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let model = ChatMediaGroupModel()
        let load: ChatMediaLoader = { _ in
            try await Task.sleep(for: .milliseconds(20))
            return file
        }
        let item = item
        let caller = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            model.start([item], using: load, maxPixelSize: 64)
        }
        await caller.value
        try await waitUntil { !model.files(of: [item]).isEmpty }
        #expect(model.files(of: [item]) == [file])
    }

    /// Media whose path stays in a reply's text: a failed image in the
    /// silent set shows no tile, a loaded or loading one does. An item
    /// outside the set (a standalone line, a Markdown image, an
    /// attachment) keeps its failed tile to retry.
    @Test func hidingFailuresDropsFailedSilentItemsOnly() async throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let missing = ChatMedia(
            id: "ref:/tmp/gone.png", kind: .image, mime: nil, source: .hostFile(path: "/tmp/gone.png"))
        let video = ChatMedia(
            id: "ref:/tmp/clip.mp4", kind: .video, mime: nil, source: .hostFile(path: "/tmp/clip.mp4"))
        let media = [missing, item, video]
        let model = ChatMediaGroupModel()
        let load: ChatMediaLoader = { requested in
            if requested.id == missing.id { throw ChatMediaError.unavailable }
            return file
        }
        let all = Set(media.map(\.id))
        #expect(model.visible(media, hidingFailuresOf: all) == media)

        model.start(media, using: load, maxPixelSize: 64)
        try await waitUntil {
            guard case .failed = model.phases[missing.id] else { return false }
            return !model.files(of: [item]).isEmpty
        }

        #expect(model.visible(media, hidingFailuresOf: all) == [item, video])
        #expect(model.visible(media, hidingFailuresOf: [item.id, video.id]) == media)
        #expect(model.visible(media, hidingFailuresOf: []) == media)
    }

    /// An item still loading keeps its spinner tile while failures hide.
    @Test func hidingFailuresKeepsALoadingItem() async throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let gate = FetchGate()
        let model = ChatMediaGroupModel()
        let load: ChatMediaLoader = { _ in try await gate.fetch(returning: file) }

        model.start([item], using: load, maxPixelSize: 64)
        await gate.firstFetchStarted()
        #expect(model.visible([item], hidingFailuresOf: [item.id]) == [item])
        gate.finishHeldFetch()
        try await waitUntil { !model.files(of: [item]).isEmpty }
        #expect(model.visible([item], hidingFailuresOf: [item.id]) == [item])
    }

    /// An item that loads on a tap fetches only after one, so its failure
    /// keeps the tile to retry even while failures hide.
    @Test func aTappedItemThatFailsKeepsItsTile() async throws {
        let video = ChatMedia(
            id: "ref:/tmp/clip.mp4", kind: .video, mime: nil, source: .hostFile(path: "/tmp/clip.mp4"))
        let model = ChatMediaGroupModel()
        let load: ChatMediaLoader = { _ in throw ChatMediaError.unavailable }

        model.start([video], using: load, maxPixelSize: 64)
        #expect(model.phases[video.id] == nil)
        model.restart([video], using: load, maxPixelSize: 64)
        try await waitUntil {
            if case .failed = model.phases[video.id] { true } else { false }
        }

        #expect(model.visible([video], hidingFailuresOf: [video.id]) == [video])
    }

    private func temporaryFile() throws -> URL {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "chat-media-\(UUID().uuidString).png", directoryHint: .notDirectory)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: file)
        return file
    }
}

/// Holds the first fetch until released; later fetches return at once.
@MainActor
private final class FetchGate {
    private(set) var fetches = 0
    private var held: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var hasStarted = false

    func fetch(returning file: URL) async throws -> URL {
        fetches += 1
        if fetches == 1 {
            hasStarted = true
            started?.resume()
            started = nil
            await withCheckedContinuation { held = $0 }
        }
        return file
    }

    func firstFetchStarted() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { started = $0 }
    }

    func finishHeldFetch() {
        held?.resume()
        held = nil
    }
}
