import Foundation
import Testing

@testable import Waycar

/// The local side of a tapped path's preview: what Quick Look is allowed to
/// render, which files the app renders as Markdown instead, and that the
/// fetched copy does not outlive the preview.
@MainActor
struct RemoteFilePreviewTests {
    @Test func aConfirmedRelativeFileKeepsTheDestinationTheUserApproved() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = ReadRecorder()
        let store = TerminalFilePreviewStore(
            read: { path, maxBytes in
                await recorder.record(path: path, maxBytes: maxBytes)
                return Data("x".utf8)
            }, resolveHome: { "/home/me" }, temporaryRoot: root)
        let target = TerminalLinkTarget.file(TerminalFileReference(path: "notes.txt"))
        let destination = await store.confirmationDetail(for: target, workingDirectory: "/first")
        let confirmation = PendingLinkConfirmation(target: target, destination: destination)
        guard case .file(let file) = confirmation.confirmedTarget else {
            Issue.record("expected a file")
            return
        }
        // The pane moved while its confirmation was on screen.
        store.preview(file, workingDirectory: "/second")
        try await waitUntil { store.previewURL != nil }
        store.close()
        #expect(await recorder.requests.map(\.path) == ["/first/notes.txt"])
    }

    /// The file is remote-chosen. Only types with contained viewers keep
    /// their extension; everything else is shown as text.
    @Test func onlyContainedViewerTypesKeepTheirExtension() {
        for kept in ["Shot 1.png", "a.JPEG", "r.heic", "doc.pdf", "notes.txt", "main.swift",
                     "data.json", "clip.mov", "clip.mp4", "clip.m4v", "song.mp3", "memo.m4a"] {
            #expect(TerminalFilePreviewStore.localFileName(forRemotePath: "/a/\(kept)") == kept, "\(kept)")
        }
        // Image formats outside the common raster set never reach ImageIO's
        // other decoders, even though they are images too.
        for shown in ["index.HTML", "page.xhtml", "logo.svg", "logo.svgz", "a.webarchive",
                      "scene.usdz", "report.docx", "deck.key", "feed.xml", "Makefile", "archive.zip",
                      "layers.psd", "shot.dng", "render.exr", "App.icns", "old.tga"] {
            #expect(
                TerminalFilePreviewStore.localFileName(forRemotePath: "/a/\(shown)") == shown + ".txt",
                "\(shown)")
        }
        #expect(TerminalFilePreviewStore.localFileName(forRemotePath: "/") == "file.txt")
    }

    /// The read gets the path the line named, resolved against the pane's
    /// directory or the Host's home, and never a larger size than the limit.
    @Test func readsTheResolvedPathWithinThePreviewLimit() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = ReadRecorder()
        let store = TerminalFilePreviewStore(
            read: { path, maxBytes in
                await recorder.record(path: path, maxBytes: maxBytes)
                return Data("x".utf8)
            },
            resolveHome: { "/home/me" },
            temporaryRoot: root)

        store.preview(TerminalFileReference(path: "notes.txt"), workingDirectory: "/w")
        try await waitUntil { store.previewURL != nil }
        store.previewDidClose()
        store.preview(TerminalFileReference(path: "~/pic.png"), workingDirectory: "/w")
        try await waitUntil { store.previewURL != nil }
        store.close()

        #expect(await recorder.requests == [
            ReadRecorder.Request(path: "/w/notes.txt", maxBytes: RemoteFilePreview.maximumBytes),
            ReadRecorder.Request(path: "/home/me/pic.png", maxBytes: RemoteFilePreview.maximumBytes),
        ])
    }

    /// A refused read ends in a failure naming its reason, not a quiet
    /// return to idle.
    @Test func aRefusedReadFailsWithItsReason() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TerminalFilePreviewStore(
            read: { _, _ in throw RemoteFilePreviewError.directory },
            resolveHome: { "/home/me" },
            temporaryRoot: root)
        store.preview(TerminalFileReference(path: "/w/src"), workingDirectory: nil)
        try await waitUntil { !store.isLoading }
        #expect(store.failureMessage == RemoteFilePreviewError.directory.errorDescription)
        #expect(store.previewURL == nil)
    }

    /// A relative path in a pane whose directory is unknown cannot be
    /// placed, so nothing is read for it.
    @Test func aRelativePathWithoutAWorkingDirectoryFailsWithoutAReading() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = ReadRecorder()
        let store = TerminalFilePreviewStore(
            read: { path, maxBytes in
                await recorder.record(path: path, maxBytes: maxBytes)
                return Data()
            },
            resolveHome: { "/home/me" },
            temporaryRoot: root)
        store.preview(TerminalFileReference(path: "notes.txt"), workingDirectory: nil)
        try await waitUntil { !store.isLoading }
        #expect(store.failureMessage == RemoteFilePreviewError.unresolvablePath.errorDescription)
        #expect(await recorder.requests.isEmpty)
    }

    /// A session winding down under the read (backgrounding, Retry) ends
    /// the loading state with a failure the user sees, not a quiet return to
    /// idle that reads as a tap doing nothing.
    @Test func aTransportCancellationEndsLoadingWithAFailure() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TerminalFilePreviewStore(
            read: { _, _ in throw TransportError.cancelled },
            resolveHome: { "/home/me" },
            temporaryRoot: root)
        store.preview(TerminalFileReference(path: "/a/b.png"), workingDirectory: nil)
        #expect(store.isLoading)
        try await waitUntil { !store.isLoading }
        #expect(store.failureMessage == TransportError.cancelled.presentation.message)
        #expect(store.previewURL == nil)
    }

    /// A task cancelled under the read that the store did not cancel — the
    /// session's own work winding down — reads as that, not as Swift's
    /// generic cancellation text.
    @Test func aCancellationTheUserDidNotCauseIsSaid() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TerminalFilePreviewStore(
            read: { _, _ in throw CancellationError() },
            resolveHome: { "/home/me" },
            temporaryRoot: root)
        store.preview(TerminalFileReference(path: "/a/b.png"), workingDirectory: nil)
        try await waitUntil { !store.isLoading }
        #expect(store.failureMessage == TransportError.cancelled.presentation.message)
    }

    /// Cancel, or a tap on another path, while a read is out: that read's
    /// answer is dropped without a word, its fallback readings are never
    /// read, and the later tap's file is the one shown.
    @Test func theUsersOwnCancelEndsTheReadQuietly() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = ReadRecorder()
        let gates = ["/slow/a.png": ReadGate(), "/slow/b.png": ReadGate()]
        defer { Task { for gate in gates.values { await gate.open() } } }
        let store = TerminalFilePreviewStore(
            read: { path, maxBytes in
                await recorder.record(path: path, maxBytes: maxBytes)
                if let gate = gates[path] {
                    await gate.wait()
                    throw RemoteFilePreviewError.missing
                }
                return Data("png".utf8)
            },
            resolveHome: { "/home/me" },
            temporaryRoot: root)

        store.preview(
            TerminalFileReference(path: "/slow/a.png", fallbackPaths: ["/w/a.png"]), workingDirectory: nil)
        try await waitUntil { await recorder.requests.count == 1 }
        let cancelled = try #require(store.task)
        store.cancel()
        #expect(store.phase == .idle)
        await gates["/slow/a.png"]?.open()
        await cancelled.value
        #expect(store.phase == .idle)
        #expect(await recorder.requests.map(\.path) == ["/slow/a.png"])

        store.preview(TerminalFileReference(path: "/slow/b.png"), workingDirectory: nil)
        try await waitUntil { await recorder.requests.count == 2 }
        let replaced = try #require(store.task)
        store.preview(TerminalFileReference(path: "/w/c.png"), workingDirectory: nil)
        try await waitUntil { store.previewURL != nil }
        await gates["/slow/b.png"]?.open()
        await replaced.value
        #expect(store.previewURL?.lastPathComponent == "c.png")
        #expect(store.failureMessage == nil)
        store.close()
    }

    /// A reading that cannot be placed gives way to the next; a transport
    /// failure ends the search at once.
    @Test func onlyReadingsThatNameNothingGiveWay() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = ReadRecorder()
        let unreachable = TransportError.sshUnreachable(detail: "gone")
        let store = TerminalFilePreviewStore(
            read: { path, maxBytes in
                await recorder.record(path: path, maxBytes: maxBytes)
                if path == "/w/down.png" { throw unreachable }
                return Data("png".utf8)
            },
            resolveHome: { "/home/me" },
            temporaryRoot: root)

        store.preview(TerminalFileReference(path: "rel.png", fallbackPaths: ["/w/shot.png"]), workingDirectory: nil)
        try await waitUntil { store.previewURL != nil }
        #expect(store.previewURL?.lastPathComponent == "shot.png")
        store.close()

        store.preview(TerminalFileReference(path: "/w/down.png", fallbackPaths: ["/w/shot.png"]), workingDirectory: nil)
        try await waitUntil { !store.isLoading }
        #expect(store.failureMessage == unreachable.presentation.message)

        #expect(await recorder.requests.map(\.path) == ["/w/shot.png", "/w/down.png"])
    }

    /// A link the app refuses outright is said the way a failed read is,
    /// and stops a read still loading: that read's answer is dropped.
    @Test func aRefusedLinkIsSaidAndStopsALoadingRead() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = ReadRecorder()
        let gate = ReadGate()
        defer { Task { await gate.open() } }
        let store = TerminalFilePreviewStore(
            read: { path, maxBytes in
                await recorder.record(path: path, maxBytes: maxBytes)
                await gate.wait()
                return Data("png".utf8)
            },
            resolveHome: { "/home/me" },
            temporaryRoot: root)
        store.preview(TerminalFileReference(path: "/w/a.png"), workingDirectory: nil)
        try await waitUntil { await recorder.requests.count == 1 }
        let loading = try #require(store.task)
        let refusal = RemoteFilePreviewError.onAnotherMachine(host: "build-box")
        store.refuse(refusal)
        #expect(store.failureMessage == refusal.errorDescription)
        await gate.open()
        await loading.value
        #expect(store.previewURL == nil)
        #expect(store.failureMessage == refusal.errorDescription)
    }

    /// A confirmation names the Host path a Preview would read: `~` is the
    /// Host's home, `..` folded. Without the home the path stays as printed.
    @Test func aConfirmationNamesTheHostPathARead() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let climbing = TerminalLinkTarget.file(TerminalFileReference(path: "~/ok/shot.png/../../../.ssh/id_ed25519"))
        let store = TerminalFilePreviewStore(
            read: { _, _ in Data() }, resolveHome: { "/home/me" }, temporaryRoot: root)
        #expect(
            await store.confirmationDetail(for: climbing, workingDirectory: "/w") == "/home/.ssh/id_ed25519")
        #expect(
            await store.confirmationDetail(
                for: .file(TerminalFileReference(path: "../x/.env")), workingDirectory: "/w/app") == "/w/x/.env")

        let homeless = TerminalFilePreviewStore(
            read: { _, _ in Data() },
            resolveHome: { throw TransportError.homeDirectoryUnresolvable(detail: "no home") },
            temporaryRoot: root)
        #expect(
            await homeless.confirmationDetail(for: climbing, workingDirectory: "/w")
                == "~/ok/shot.png/../../../.ssh/id_ed25519")
    }

    /// A path joined across a row break is read first; naming nothing, it
    /// gives way to the row's own reading. A reading of a file that is there
    /// but refused stops the search, and when every reading names nothing
    /// the first one's reason is shown.
    @Test func fallbackReadingsAreTriedInOrderWhileNoneNamesAFile() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = ReadRecorder()
        let store = TerminalFilePreviewStore(
            read: { path, maxBytes in
                await recorder.record(path: path, maxBytes: maxBytes)
                switch path {
                case "/w/shot.png": return Data("png".utf8)
                case "/w/dir": throw RemoteFilePreviewError.directory
                case "/w/secret.png": throw RemoteFilePreviewError.unreadable
                default: throw RemoteFilePreviewError.missing
                }
            },
            resolveHome: { "/home/me" },
            temporaryRoot: root)

        store.preview(
            TerminalFileReference(path: "/w/shotthen", fallbackPaths: ["~/shot.png", "shot.png"]),
            workingDirectory: "/w")
        try await waitUntil { store.previewURL != nil }
        #expect(store.previewURL?.lastPathComponent == "shot.png")
        store.close()

        store.preview(
            TerminalFileReference(path: "secret.png", fallbackPaths: ["shot.png"]),
            workingDirectory: "/w")
        try await waitUntil { !store.isLoading }
        #expect(store.failureMessage == RemoteFilePreviewError.unreadable.errorDescription)

        store.preview(
            TerminalFileReference(path: "gone.png", fallbackPaths: ["dir"]),
            workingDirectory: "/w")
        try await waitUntil { !store.isLoading }
        #expect(store.failureMessage == RemoteFilePreviewError.missing.errorDescription)

        #expect(await recorder.requests.map(\.path) == [
            "/w/shotthen", "/home/me/shot.png", "/w/shot.png",
            "/w/secret.png",
            "/w/gone.png", "/w/dir",
        ])
    }

    @Test func theCopyGoesWhenThePreviewOrTheDetailCloses() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TerminalFilePreviewStore(
            read: { _, _ in Data("hello".utf8) },
            resolveHome: { "/home/me" },
            temporaryRoot: root)

        store.preview(TerminalFileReference(path: "notes.txt"), workingDirectory: "/w")
        try await waitUntil { store.previewURL != nil }
        let first = try #require(store.previewURL)
        #expect(try String(contentsOf: first, encoding: .utf8) == "hello")
        store.previewDidClose()
        #expect(!FileManager.default.fileExists(atPath: first.path))

        store.preview(TerminalFileReference(path: "notes.txt"), workingDirectory: "/w")
        try await waitUntil { store.previewURL != nil }
        let second = try #require(store.previewURL)
        store.close()
        #expect(!FileManager.default.fileExists(atPath: second.path))
        #expect(store.previewURL == nil)
    }

    /// Copies a killed app left behind are swept when the first store on a
    /// root starts. A later store on that root — the view re-created, another
    /// window — leaves the copy Quick Look is showing alone.
    @Test func leftoversAreSweptOnce() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stale = root.appendingPathComponent("stale/secret.env")
        try FileManager.default.createDirectory(
            at: stale.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("KEY=1".utf8).write(to: stale)

        let first = TerminalFilePreviewStore(
            read: { _, _ in Data("live".utf8) }, resolveHome: { "/" }, temporaryRoot: root)
        #expect(!FileManager.default.fileExists(atPath: stale.path))

        first.preview(TerminalFileReference(path: "/a/live.txt"), workingDirectory: nil)
        try await waitUntil { first.previewURL != nil }
        let live = try #require(first.previewURL)
        _ = TerminalFilePreviewStore(read: { _, _ in Data() }, resolveHome: { "/" }, temporaryRoot: root)
        #expect(FileManager.default.fileExists(atPath: live.path))
        first.close()
    }

    /// A Markdown file within the render cap is rendered by the app, not
    /// handed to Quick Look: its text, decoded as UTF-8 with a bad byte
    /// replaced, and the Host path it was read from. The copy kept for Share
    /// keeps its name, and `.markdown` counts in any case.
    @Test func aMarkdownFileWithinTheCapIsRendered() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TerminalFilePreviewStore(
            read: { path, _ in
                path.hasSuffix(".md") ? Data("# Title\n".utf8) : Data([0x6F, 0x6B, 0xFF])
            },
            resolveHome: { "/home/me" },
            temporaryRoot: root)

        store.preview(TerminalFileReference(path: "README.md"), workingDirectory: "/w")
        try await waitUntil { store.markdownPreview != nil }
        let readme = try #require(store.markdownPreview)
        #expect(readme.text == "# Title\n")
        #expect(readme.remotePath == "/w/README.md")
        #expect(readme.name == "README.md")
        #expect(readme.localURL.lastPathComponent == "README.md")
        #expect(try String(contentsOf: readme.localURL, encoding: .utf8) == "# Title\n")
        #expect(store.previewURL == nil)

        store.preview(TerminalFileReference(path: "~/NOTES.MARKDOWN"), workingDirectory: "/w")
        try await waitUntil { store.markdownPreview?.remotePath == "/home/me/NOTES.MARKDOWN" }
        #expect(store.markdownPreview?.text == "ok\u{FFFD}")
        #expect(store.previewURL == nil)
        store.close()
    }

    /// Past the render cap a Markdown file is shown as text in Quick Look,
    /// as any other file is; at the cap it is still rendered. `.mdx` is no
    /// Markdown.
    @Test func markdownPastTheCapOrMDXGoesToQuickLookAsText() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cap = TerminalFilePreviewStore.markdownRenderMaximumBytes
        let store = TerminalFilePreviewStore(
            read: { path, _ in Data(repeating: 0x61, count: path == "/w/big.md" ? cap + 1 : cap) },
            resolveHome: { "/home/me" },
            temporaryRoot: root)

        store.preview(TerminalFileReference(path: "big.md"), workingDirectory: "/w")
        try await waitUntil { store.previewURL != nil }
        #expect(store.previewURL?.lastPathComponent == "big.md.txt")
        #expect(store.markdownPreview == nil)

        store.preview(TerminalFileReference(path: "page.mdx"), workingDirectory: "/w")
        try await waitUntil { store.previewURL?.lastPathComponent == "page.mdx.txt" }
        #expect(store.markdownPreview == nil)

        store.preview(TerminalFileReference(path: "full.md"), workingDirectory: "/w")
        try await waitUntil { store.markdownPreview != nil }
        #expect(store.markdownPreview?.text.utf8.count == cap)
        #expect(store.previewURL == nil)
        store.close()
    }

    /// One preview at a time: a Markdown file opened over a Quick Look copy
    /// closes it, and a file opened over a Markdown one closes that, each
    /// copy removed with its preview.
    @Test func aNewPreviewReplacesTheOneShowingAndRemovesItsCopy() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TerminalFilePreviewStore(
            read: { _, _ in Data("# Hi".utf8) }, resolveHome: { "/home/me" }, temporaryRoot: root)

        store.preview(TerminalFileReference(path: "/w/notes.txt"), workingDirectory: nil)
        try await waitUntil { store.previewURL != nil }
        let text = try #require(store.previewURL)

        store.preview(TerminalFileReference(path: "/w/README.md"), workingDirectory: nil)
        try await waitUntil { store.markdownPreview != nil }
        #expect(store.previewURL == nil)
        #expect(!FileManager.default.fileExists(atPath: text.path))
        let first = try #require(store.markdownPreview)

        store.preview(TerminalFileReference(path: "/w/PLAN.md"), workingDirectory: nil)
        try await waitUntil { store.markdownPreview?.remotePath == "/w/PLAN.md" }
        #expect(store.markdownPreview?.id != first.id)
        #expect(!FileManager.default.fileExists(atPath: first.localURL.path))
        let second = try #require(store.markdownPreview)

        store.preview(TerminalFileReference(path: "/w/shot.png"), workingDirectory: nil)
        try await waitUntil { store.previewURL != nil }
        #expect(store.markdownPreview == nil)
        #expect(!FileManager.default.fileExists(atPath: second.localURL.path))
        store.close()
        #expect(copies(in: root).isEmpty)
    }

    /// A confirmed link in a Markdown preview is read the way a tap is: a
    /// Markdown file comes back to be rendered, anything else as a Quick
    /// Look copy named the way a tap's is, and a file that is not there
    /// throws its reason. Closing the preview removes its copy and every
    /// linked one.
    @Test func linkedFilesOpenFromAMarkdownPreviewAndCloseWithIt() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TerminalFilePreviewStore(
            read: { path, _ in
                switch path {
                case "/w/README.md": return Data("[Spec](docs/spec.md)".utf8)
                case "/w/docs/spec.md": return Data("# Spec".utf8)
                case "/w/docs/shot.png": return Data("png".utf8)
                case "/w/docs/page.html": return Data("<p>".utf8)
                default: throw RemoteFilePreviewError.missing
                }
            },
            resolveHome: { "/home/me" },
            temporaryRoot: root)
        store.preview(TerminalFileReference(path: "README.md"), workingDirectory: "/w")
        try await waitUntil { store.markdownPreview != nil }
        let readme = try #require(store.markdownPreview)

        let spec = try await store.linkedPreview(
            TerminalFileReference(path: "docs/spec.md"), workingDirectory: "/w")
        guard case .markdown(let linked) = spec else {
            Issue.record("a linked Markdown file should be rendered, not \(spec)")
            return
        }
        #expect(linked.remotePath == "/w/docs/spec.md")
        #expect(linked.text == "# Spec")

        let shot = try await store.linkedPreview(
            TerminalFileReference(path: "shot.png"), workingDirectory: "/w/docs")
        guard case .quickLook(let shotURL) = shot else {
            Issue.record("a linked picture should open in Quick Look, not \(shot)")
            return
        }
        #expect(shotURL.lastPathComponent == "shot.png")
        let page = try await store.linkedPreview(
            TerminalFileReference(path: "/w/docs/page.html"), workingDirectory: "/w/docs")
        guard case .quickLook(let pageURL) = page else {
            Issue.record("a linked page should open in Quick Look, not \(page)")
            return
        }
        #expect(pageURL.lastPathComponent == "page.html.txt")

        await #expect(throws: RemoteFilePreviewError.missing) {
            _ = try await store.linkedPreview(TerminalFileReference(path: "gone.md"), workingDirectory: "/w")
        }
        #expect(store.markdownPreview == readme)
        for url in [readme.localURL, linked.localURL, shotURL, pageURL] {
            #expect(FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent)")
        }

        store.markdownPreviewDidClose()
        #expect(store.markdownPreview == nil)
        #expect(copies(in: root).isEmpty)
    }

    /// A linked read that answers after its Markdown preview closed, or
    /// after its task was cancelled, writes nothing and throws
    /// `CancellationError`.
    @Test func aLinkedReadOutlivingItsPreviewWritesNothing() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = ReadRecorder()
        let gate = ReadGate()
        defer { Task { await gate.open() } }
        let store = TerminalFilePreviewStore(
            read: { path, maxBytes in
                await recorder.record(path: path, maxBytes: maxBytes)
                if path != "/w/README.md" { await gate.wait() }
                return Data("# Doc".utf8)
            },
            resolveHome: { "/home/me" },
            temporaryRoot: root)
        store.preview(TerminalFileReference(path: "/w/README.md"), workingDirectory: nil)
        try await waitUntil { store.markdownPreview != nil }

        let orphaned = Task {
            try await store.linkedPreview(TerminalFileReference(path: "/w/a.md"), workingDirectory: nil)
        }
        try await waitUntil { await recorder.requests.count == 2 }
        store.markdownPreviewDidClose()
        await gate.open()
        await #expect(throws: CancellationError.self) { _ = try await orphaned.value }
        #expect(copies(in: root).isEmpty)

        store.preview(TerminalFileReference(path: "/w/README.md"), workingDirectory: nil)
        try await waitUntil { store.markdownPreview != nil }
        let cancelled = Task {
            try await store.linkedPreview(TerminalFileReference(path: "/w/b.md"), workingDirectory: nil)
        }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
        store.close()
        #expect(copies(in: root).isEmpty)
    }

    /// Whether the Markdown sheet shows rendered or raw text is one choice
    /// for the device: rendered until a flip to raw, which every later
    /// sheet opens on until it is flipped back.
    @Test func theRawTextChoiceIsRemembered() throws {
        let suiteName = "markdown-preview-raw-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(!RecentSelectionsStore(defaults: defaults).markdownPreviewShowsRaw)
        RecentSelectionsStore(defaults: defaults).rememberMarkdownPreviewShowsRaw(true)
        #expect(RecentSelectionsStore(defaults: defaults).markdownPreviewShowsRaw)
        RecentSelectionsStore(defaults: defaults).rememberMarkdownPreviewShowsRaw(false)
        #expect(!RecentSelectionsStore(defaults: defaults).markdownPreviewShowsRaw)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteFilePreviewTests-\(UUID().uuidString)", isDirectory: true)
    }

    /// The private directories under `root` still holding a copy.
    private func copies(in root: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    }
}

private actor ReadRecorder {
    struct Request: Equatable {
        let path: String
        let maxBytes: Int
    }

    private(set) var requests: [Request] = []

    func record(path: String, maxBytes: Int) {
        requests.append(Request(path: path, maxBytes: maxBytes))
    }
}

/// Holds reads until opened; stays open after.
private actor ReadGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
