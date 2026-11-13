import Foundation
import Observation
import Testing

@testable import Waycar

/// Characterization through the pre-machine store API (ATTACH-19).
@MainActor
struct TerminalFilePreviewOwnerTests {
    @Test func aLoadingOrCancelledReplacementKeepsTheExistingMarkdownAndItsLinks() async throws {
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let reads = PreviewOwnerReadGate()
        defer { Task { await reads.releaseAll() } }
        let store = TerminalFilePreviewStore(
            read: { path, _ in await reads.read(path) }, resolveHome: { "/home/test" }, temporaryRoot: root)
        store.preview(TerminalFileReference(path: "/visible.md"), workingDirectory: nil)
        try await waitUntil { store.markdownPreview != nil }
        let visible = try #require(store.markdownPreview)
        let linked = try await store.linkedPreview(TerminalFileReference(path: "/link.txt"), workingDirectory: nil)
        guard case .quickLook(let linkURL) = linked else {
            Issue.record("expected a Quick Look link")
            return
        }

        store.preview(TerminalFileReference(path: "/held.md"), workingDirectory: nil)
        try await waitUntil { await reads.pendingPaths.contains("/held.md") }
        let cancelled = try #require(store.task)
        #expect(store.isLoading)
        #expect(store.markdownPreview == visible)
        #expect(store.previewURL == nil)
        store.cancel()
        await reads.release("/held.md")
        await cancelled.value
        #expect(store.phase == .idle)
        #expect(store.markdownPreview == visible)
        #expect(FileManager.default.fileExists(atPath: linkURL.path))
        store.close()
        #expect(!FileManager.default.fileExists(atPath: visible.localURL.path))
        #expect(!FileManager.default.fileExists(atPath: linkURL.path))
    }

    @Test func aCancelledReadCannotReplaceTheNewerPreview() async throws {
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let reads = PreviewOwnerReadGate()
        defer { Task { await reads.releaseAll() } }
        let store = TerminalFilePreviewStore(
            read: { path, _ in await reads.read(path) }, resolveHome: { "/home/test" }, temporaryRoot: root)
        store.preview(TerminalFileReference(path: "/held.md"), workingDirectory: nil)
        try await waitUntil { await reads.pendingPaths.contains("/held.md") }
        let oldRead = try #require(store.task)
        store.preview(TerminalFileReference(path: "/visible.md"), workingDirectory: nil)
        try await waitUntil { store.markdownPreview?.remotePath == "/visible.md" }
        let visible = try #require(store.markdownPreview)
        await reads.release("/held.md")
        await oldRead.value
        #expect(store.markdownPreview == visible)
        #expect(store.phase == .idle)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 1)
        store.close()
    }

    @Test func closingTheGalleryFencesItsReadWithoutClosingTheMarkdown() async throws {
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let reads = PreviewOwnerReadGate()
        defer { Task { await reads.releaseAll() } }
        let store = TerminalFilePreviewStore(
            read: { path, _ in await reads.read(path) }, resolveHome: { "/home/test" }, temporaryRoot: root)
        store.preview(TerminalFileReference(path: "/visible.md"), workingDirectory: nil)
        try await waitUntil { store.markdownPreview != nil }
        let visible = try #require(store.markdownPreview)
        let gallery = Task {
            try await store.galleryCopy(of: TerminalFileReference(path: "/held.png"), workingDirectory: nil)
        }
        try await waitUntil { await reads.pendingPaths.contains("/held.png") }
        store.removeGalleryFiles()
        await reads.release("/held.png")
        await #expect(throws: CancellationError.self) { _ = try await gallery.value }
        #expect(store.markdownPreview == visible)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 1)
        store.close()
    }

    @Test(arguments: ["/visible.md", "/visible.txt"])
    func galleryBookkeepingAndNoOpEventsDoNotInvalidatePreviewPublications(_ path: String) async throws {
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TerminalFilePreviewStore(
            read: { _, _ in Data("# Visible".utf8) }, resolveHome: { "/home/test" }, temporaryRoot: root)
        defer { store.close() }
        store.preview(TerminalFileReference(path: path), workingDirectory: nil)
        try await waitUntil { !store.isLoading && (store.previewURL != nil || store.markdownPreview != nil) }
        let visibleURL = store.previewURL
        let visibleMarkdown = store.markdownPreview
        let phaseChanges = PreviewPublicationChanges()
        let urlChanges = PreviewPublicationChanges()
        let markdownChanges = PreviewPublicationChanges()
        phaseChanges.observe { _ = store.phase }
        urlChanges.observe { _ = store.previewURL }
        markdownChanges.observe { _ = store.markdownPreview }

        let gallery = try await store.galleryCopy(
            of: TerminalFileReference(path: "/gallery.png"), workingDirectory: nil)
        _ = try store.galleryStandIn(Data(), forRemotePath: "/loading.png", note: "loading")
        store.removeGalleryFile(at: gallery)
        store.removeGalleryFiles()
        store.removeGalleryFiles()
        store.removeGalleryFile(at: root.appendingPathComponent("unowned/file.png"))
        store.dismissFailure()
        store.cancel()
        if visibleMarkdown != nil {
            _ = try await store.linkedPreview(TerminalFileReference(path: "/linked.txt"), workingDirectory: nil)
            store.previewDidClose()
        } else {
            store.markdownPreviewDidClose()
        }
        #expect(store.phase == .idle)
        #expect(store.previewURL == visibleURL)
        #expect(store.markdownPreview == visibleMarkdown)
        #expect(phaseChanges.count == 0)
        #expect(urlChanges.count == 0)
        #expect(markdownChanges.count == 0)

        // Prove the observers are armed, and that actual publications remain
        // independent: a failure changes only phase; close changes only its viewer.
        store.refuse(.missing)
        #expect(phaseChanges.count == 1)
        #expect(urlChanges.count == 0)
        #expect(markdownChanges.count == 0)
        store.close()
        #expect(urlChanges.count == (visibleURL == nil ? 0 : 1))
        #expect(markdownChanges.count == (visibleMarkdown == nil ? 0 : 1))
    }

    private static func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("preview-owner-\(UUID())")
    }
}

@MainActor
private final class PreviewPublicationChanges {
    var count = 0

    func observe(_ read: () -> Void) {
        withObservationTracking(read) {
            MainActor.assumeIsolated { self.count += 1 }
        }
    }
}

private actor PreviewOwnerReadGate {
    private var waiting: [String: CheckedContinuation<Data, Never>] = [:]
    var pendingPaths: Set<String> { Set(waiting.keys) }

    func read(_ path: String) async -> Data {
        if !path.hasPrefix("/held") { return Data("# Visible".utf8) }
        return await withCheckedContinuation { waiting[path] = $0 }
    }

    func release(_ path: String) {
        waiting.removeValue(forKey: path)?.resume(returning: Data("# Held".utf8))
    }

    func releaseAll() {
        for continuation in waiting.values { continuation.resume(returning: Data()) }
        waiting.removeAll()
    }
}
