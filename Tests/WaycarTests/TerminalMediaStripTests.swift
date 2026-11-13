import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Waycar

/// The status row's strip of files the terminal printed paths to: every
/// Markdown file and PDF, never fetched, and the images that loaded, newest
/// first. Image fetches wait for the list to settle, run one at a time, and
/// stop for paths that left the list.
@MainActor
@Suite("Terminal media strip")
struct TerminalMediaStripTests {
    @Test func everyKindCountsOncePerPathUpToTwentyFive() {
        let candidates = [
            Self.candidate("/tmp/shot.PNG"), Self.candidate("README.md"), Self.candidate("~/b.webp"),
            Self.candidate("/tmp/shot.PNG", sightings: 3), Self.candidate("out/report.pdf"),
        ]
        #expect(
            TerminalMediaStripModel.listed(in: candidates).map(\.path)
                == ["/tmp/shot.PNG", "README.md", "~/b.webp", "out/report.pdf"])
        let many = (0..<40).map { Self.candidate($0.isMultiple(of: 2) ? "/\($0).png" : "/\($0).md") }
        let listed = TerminalMediaStripModel.listed(in: many)
        #expect(TerminalMediaStripModel.maximumPaths == 25)
        #expect(listed.map(\.path) == Array(many.prefix(25)).map(\.path))
        #expect(
            TerminalMediaStripModel.media(for: "~/b.webp")
                == ChatMedia(
                    id: "ref:~/b.webp", kind: .image, mime: nil, source: .hostFile(path: "~/b.webp"), alt: nil))
    }

    /// Documents list at once, without a fetch, even before the list
    /// settles.
    @Test func documentsListWithoutAFetch() async throws {
        let loads = Loads { _ in try Self.pngFile() }
        let model = TerminalMediaStripModel()
        defer { Self.clean(model) }

        model.note([Self.candidate("README.md"), Self.candidate("/out/report.PDF")])
        #expect(model.files.map(\.path) == ["README.md", "/out/report.PDF"])
        model.settle(using: loads.load, maxPixelSize: 64)
        try await waitUntil { model.isIdle }

        #expect(loads.paths.isEmpty)
        #expect(model.files.map(\.kind) == [.markdown, .pdf])
        #expect(model.files.allSatisfy { $0.thumbnail == nil })
    }

    /// Among documents, only the images fetch; the files keep the list's
    /// order.
    @Test func imagesFetchAmongDocuments() async throws {
        let loads = Loads { _ in try Self.pngFile() }
        let model = TerminalMediaStripModel()
        defer { Self.clean(model) }

        model.note(["docs/a.md", "/shot.png", "b.pdf"].map { Self.candidate($0) })
        #expect(model.files.map(\.path) == ["docs/a.md", "b.pdf"])
        model.settle(using: loads.load, maxPixelSize: 64)
        try await waitUntil { model.isIdle }

        #expect(loads.paths == ["/shot.png"])
        #expect(model.files.map(\.path) == ["docs/a.md", "/shot.png", "b.pdf"])
        #expect(model.files.map { $0.thumbnail != nil } == [false, true, false])
    }

    /// A missing, unreadable or undecodable image is silent: no entry, no
    /// error, and no copy left on disk.
    @Test func aFailedLoadShowsNothing() async throws {
        var undecodable: URL?
        let loads = Loads { media in
            switch media.source {
            case .hostFile(path: "/gone.png"): throw ChatMediaError.unavailable
            case .hostFile(path: "rel/denied.jpg"): throw RemoteFilePreviewError.unresolvablePath
            case .hostFile(path: "/junk.png"):
                let file = try Self.junkFile()
                undecodable = file
                return file
            default: return try Self.pngFile()
            }
        }
        let model = TerminalMediaStripModel()
        defer { Self.clean(model) }

        model.note(["/gone.png", "/ok.png", "rel/denied.jpg", "/junk.png"].map { Self.candidate($0) })
        model.settle(using: loads.load, maxPixelSize: 64)
        try await waitUntil { model.isIdle }

        #expect(loads.paths.count == 4)
        #expect(model.files.map(\.path) == ["/ok.png"])
        let junk = try #require(undecodable)
        #expect(!FileManager.default.fileExists(atPath: junk.path(percentEncoded: false)))
    }

    /// Fetches run one at a time, newest first; files keep the list's
    /// order.
    @Test func fetchesRunNewestFirstOneAtATime() async throws {
        let gates = ["/a.png": Gate(), "/b.png": Gate(), "/c.png": Gate()]
        let loads = Loads { media in
            guard case .hostFile(let path) = media.source else { throw ChatMediaError.unavailable }
            await gates[path]?.wait()
            return try Self.pngFile()
        }
        let model = TerminalMediaStripModel()
        defer { Self.clean(model) }

        model.note(["/a.png", "/b.png", "/c.png"].map { Self.candidate($0) })
        model.settle(using: loads.load, maxPixelSize: 64)
        try await waitUntil { loads.paths == ["/a.png"] }
        gates["/a.png"]?.open()
        try await waitUntil { loads.paths == ["/a.png", "/b.png"] }
        gates["/c.png"]?.open()
        gates["/b.png"]?.open()
        try await waitUntil { model.isIdle }

        #expect(loads.paths == ["/a.png", "/b.png", "/c.png"])
        #expect(model.files.map(\.path) == ["/a.png", "/b.png", "/c.png"])
    }

    /// Paths that passed through before the list settled never fetch.
    @Test func nothingFetchesBeforeTheListSettles() async throws {
        let loads = Loads { _ in try Self.pngFile() }
        let model = TerminalMediaStripModel()
        defer { Self.clean(model) }

        model.note([Self.candidate("/passing.png")])
        model.note([Self.candidate("/next.png"), Self.candidate("/passing.png")])
        model.note([Self.candidate("/final.png")])
        #expect(model.isIdle)
        model.settle(using: loads.load, maxPixelSize: 64)
        try await waitUntil { model.isIdle }

        #expect(loads.paths == ["/final.png"])
        #expect(model.files.map(\.path) == ["/final.png"])
    }

    /// A path that leaves the list before its turn never starts a transfer;
    /// one that leaves mid-fetch or after loading drops its thumbnail. No
    /// copy outlives its fetch.
    @Test func evictedPathsDropStateAndNoCopiesRemain() async throws {
        let gate = Gate()
        var copies: [String: URL] = [:]
        let loads = Loads { media in
            guard case .hostFile(let path) = media.source else { throw ChatMediaError.unavailable }
            if path == "/slow.png" { await gate.wait() }
            let file = try Self.pngFile()
            copies[path] = file
            return file
        }
        let model = TerminalMediaStripModel()
        defer { Self.clean(model) }

        model.note([Self.candidate("/kept.png")])
        model.settle(using: loads.load, maxPixelSize: 64)
        try await waitUntil { model.isIdle }
        let kept = try #require(copies["/kept.png"])
        #expect(model.files.map(\.path) == ["/kept.png"])
        #expect(!FileManager.default.fileExists(atPath: kept.path(percentEncoded: false)))

        model.note([Self.candidate("/slow.png"), Self.candidate("/queued.png"), Self.candidate("/kept.png")])
        model.settle(using: loads.load, maxPixelSize: 64)
        try await waitUntil { loads.paths.last == "/slow.png" }
        // Everything leaves while /slow.png is in flight.
        model.note([])
        #expect(model.files.isEmpty)
        model.settle(using: loads.load, maxPixelSize: 64)
        gate.open()
        try await waitUntil { model.isIdle }

        #expect(loads.paths == ["/kept.png", "/slow.png"])
        #expect(model.files.isEmpty)
        let slow = try #require(copies["/slow.png"])
        #expect(!FileManager.default.fileExists(atPath: slow.path(percentEncoded: false)))
    }

    /// Documents coming and going while an image waits its turn neither
    /// pause the fetches nor restart the settle: the image key leaves them
    /// out, and the queued image fetches without another `settle`.
    @Test func documentChurnNeverHoldsBackImageFetches() async throws {
        let gate = Gate()
        let loads = Loads { media in
            if case .hostFile(path: "/a.png") = media.source { await gate.wait() }
            return try Self.pngFile()
        }
        let model = TerminalMediaStripModel()
        defer { Self.clean(model) }
        let images = [Self.candidate("/a.png"), Self.candidate("/b.png")]

        model.note(images)
        model.settle(using: loads.load, maxPixelSize: 64)
        try await waitUntil { loads.paths == ["/a.png"] }
        let churned = [Self.candidate("notes.md")] + images + [Self.candidate("out/report.pdf")]
        model.note(churned)
        #expect(
            TerminalMediaStripModel.imageCandidates(in: churned)
                == TerminalMediaStripModel.imageCandidates(in: images))
        #expect(model.files.map(\.path) == ["notes.md", "out/report.pdf"])
        gate.open()
        try await waitUntil { model.isIdle }

        #expect(loads.paths == ["/a.png", "/b.png"])
        #expect(model.files.map(\.path) == ["notes.md", "/a.png", "/b.png", "out/report.pdf"])
        #expect(
            TerminalMediaStripModel.imageCandidates(in: [Self.candidate("/b.png", sightings: 2)] + churned)
                != TerminalMediaStripModel.imageCandidates(in: churned))
    }

    /// A failed path printed again retries, at most every 2 s and 5 times.
    @Test func aFailedPathRetriesWhenSightedAgain() async throws {
        let clock = FakeClock()
        var exists = false
        let loads = Loads { _ in
            guard exists else { throw ChatMediaError.unavailable }
            return try Self.pngFile()
        }
        let model = TerminalMediaStripModel(now: { clock.now })
        defer { Self.clean(model) }
        let path = "/out.png"

        model.note([Self.candidate(path, sightings: 1)])
        model.settle(using: loads.load, maxPixelSize: 64)
        try await waitUntil { model.isIdle }
        #expect(loads.paths.count == 1)

        // Too soon: no retry.
        clock.advance(.seconds(1))
        model.note([Self.candidate(path, sightings: 2)])
        model.settle(using: loads.load, maxPixelSize: 64)
        try await waitUntil { model.isIdle }
        #expect(loads.paths.count == 1)

        // A redraw of the same list is not a sighting.
        clock.advance(.seconds(5))
        model.note([Self.candidate(path, sightings: 2)])
        model.settle(using: loads.load, maxPixelSize: 64)
        try await waitUntil { model.isIdle }
        #expect(loads.paths.count == 1)

        exists = true
        model.note([Self.candidate(path, sightings: 3)])
        model.settle(using: loads.load, maxPixelSize: 64)
        try await waitUntil { model.isIdle }
        #expect(loads.paths.count == 2)
        #expect(model.files.map(\.path) == [path])
    }

    @Test func retriesStopAfterFive() async throws {
        let clock = FakeClock()
        let loads = Loads { _ in throw ChatMediaError.unavailable }
        let model = TerminalMediaStripModel(now: { clock.now })
        let path = "/never.png"

        for sightings in 1...8 {
            model.note([Self.candidate(path, sightings: sightings)])
            model.settle(using: loads.load, maxPixelSize: 64)
            try await waitUntil { model.isIdle }
            clock.advance(.seconds(3))
        }

        #expect(loads.paths.count == 1 + TerminalMediaStripModel.maximumRetries)
    }

    /// A loaded path printed again refreshes at most every 60 s, its old
    /// thumbnail showing until the new one decodes, and kept if it fails.
    /// Each fetch's copy is deleted once decoded; only thumbnails stay.
    @Test func aLoadedPathRefreshesKeepingItsThumbnail() async throws {
        let clock = FakeClock()
        let gate = Gate()
        var mode = "png"
        var copies: [URL] = []
        let loads = Loads { _ in
            let file: URL
            switch mode {
            case "gated":
                await gate.wait()
                file = try Self.pngFile()
            case "junk": file = try Self.junkFile()
            default: file = try Self.pngFile()
            }
            copies.append(file)
            return file
        }
        let model = TerminalMediaStripModel(now: { clock.now })
        defer { Self.clean(model) }
        let path = "/live.png"

        model.note([Self.candidate(path, sightings: 1)])
        model.settle(using: loads.load, maxPixelSize: 64)
        try await waitUntil { model.isIdle }
        let shown = model.files
        #expect(shown.map(\.path) == [path])

        clock.advance(.seconds(30))
        model.note([Self.candidate(path, sightings: 2)])
        model.settle(using: loads.load, maxPixelSize: 64)
        try await waitUntil { model.isIdle }
        #expect(loads.paths.count == 1)

        // A failed refresh keeps the old thumbnail.
        clock.advance(.seconds(60))
        mode = "junk"
        model.note([Self.candidate(path, sightings: 3)])
        model.settle(using: loads.load, maxPixelSize: 64)
        try await waitUntil { model.isIdle }
        #expect(loads.paths.count == 2)
        #expect(model.files == shown)

        // The old thumbnail shows while the refresh is in flight.
        clock.advance(.seconds(60))
        mode = "gated"
        model.note([Self.candidate(path, sightings: 4)])
        model.settle(using: loads.load, maxPixelSize: 64)
        try await waitUntil { loads.paths.count == 3 }
        #expect(model.files == shown)
        gate.open()
        try await waitUntil { model.isIdle }

        #expect(model.files.map(\.path) == [path])
        #expect(model.files != shown)
        #expect(copies.count == 3)
        #expect(copies.allSatisfy { !FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) })
    }

    /// Ten images, a PDF and a Markdown file: the stack shows both
    /// documents and the two newest images, documents first.
    @Test func tilesShowEveryKindPresent() {
        let images = (0..<10).map { Self.file("/\($0).png") }
        let files = Array(images[0..<5]) + [Self.file("out/report.pdf")] + Array(images[5...])
            + [Self.file("README.md")]

        let tiles = TerminalMediaStripModel.tiles(of: files, maximum: 4)

        #expect(tiles.map(\.path) == ["README.md", "out/report.pdf", "/0.png", "/1.png"])
    }

    @Test func tilesOfImagesOnlyAreTheNewest() {
        let files = (0..<6).map { Self.file("/\($0).png") }

        #expect(
            TerminalMediaStripModel.tiles(of: files, maximum: 4).map(\.path)
                == ["/0.png", "/1.png", "/2.png", "/3.png"])
    }

    /// The newest of each document kind, then the newest of the rest,
    /// grouped by kind.
    @Test func tilesOfDocumentsOnly() {
        let files = ["a.md", "a.pdf", "b.md", "c.md", "b.pdf"].map { Self.file($0) }

        #expect(
            TerminalMediaStripModel.tiles(of: files, maximum: 4).map(\.path)
                == ["a.md", "b.md", "c.md", "a.pdf"])
    }

    @Test func fewerFilesThanTilesAllShow() {
        let files = [Self.file("/shot.png"), Self.file("notes.markdown")]

        #expect(
            TerminalMediaStripModel.tiles(of: files, maximum: 4).map(\.path) == ["notes.markdown", "/shot.png"])
        #expect(TerminalMediaStripModel.tiles(of: [], maximum: 4).isEmpty)
    }

    @Test func accessibilityValueCountsByKindThenLinks() throws {
        let mixed = (0..<10).map { Self.file("/\($0).png") } + [Self.file("r.pdf"), Self.file("a.md")]
        #expect(
            TerminalMediaStrip.accessibilityValue(files: mixed, links: [])
                == "1 Markdown file, 1 PDF, 10 images")
        let documents = ["a.md", "b.md", "a.pdf", "b.pdf"].map { Self.file($0) } + [Self.file("/1.png")]
        let oneLink = [try Self.link("https://a.example")]
        #expect(
            TerminalMediaStrip.accessibilityValue(files: documents, links: oneLink)
                == "2 Markdown files, 2 PDFs, 1 image, 1 link")
        let links = try ["https://a.example", "https://b.example"].map(Self.link)
        #expect(TerminalMediaStrip.accessibilityValue(files: [], links: links) == "2 links")
    }

    /// Links alone are enough to show the strip: one link tile, the newest.
    @Test func linksAloneShowTheNewestLinkTile() throws {
        let links = try ["https://new.example/a", "https://old.example/b"].map(Self.link)

        #expect(
            TerminalMediaStrip.tiles(files: [], links: links, maximum: 4).map(\.id)
                == ["link:https://new.example/a"])
        #expect(TerminalMediaStrip.tiles(files: [], links: [], maximum: 4).isEmpty)
    }

    /// The link tile follows the files' tiles and keeps its place however
    /// many files there are; the files keep their kind order, and "+N"
    /// counts every file and link left out.
    @Test func theLinkTileFollowsTheFiles() throws {
        let files = (0..<6).map { Self.file("/\($0).png") } + [Self.file("README.md")]
        let links = try ["https://new.example", "https://old.example"].map(Self.link)

        let tiles = TerminalMediaStrip.tiles(files: files, links: links, maximum: 4)

        #expect(tiles.map(\.id) == ["file:README.md", "file:/0.png", "file:/1.png", "link:https://new.example"])
        #expect(TerminalMediaStrip.overflow(files: files, links: links, tiles: tiles) == 5)
    }

    /// However few tiles fit, the stack fills exactly that many, and the
    /// newest link holds the last one.
    @Test(arguments: [
        (0, [String]()),
        (1, ["link:https://new.example"]),
        (2, ["file:c.md", "link:https://new.example"]),
    ])
    func aSmallMaximumKeepsTheNewestLinkLast(maximum: Int, expectedIDs: [String]) throws {
        let files = [Self.file("/a.png"), Self.file("b.pdf"), Self.file("c.md")]
        let links = try ["https://new.example", "https://old.example"].map(Self.link)

        let tiles = TerminalMediaStrip.tiles(files: files, links: links, maximum: maximum)

        #expect(tiles.map(\.id) == expectedIDs)
    }

    /// The list's order: every file newest first, then every link newest
    /// first.
    @Test func itemsListFilesBeforeLinks() throws {
        let files = [Self.file("/new.png"), Self.file("old.md")]
        let links = try ["https://new.example", "https://old.example"].map(Self.link)

        #expect(
            TerminalMediaStrip.items(files: files, links: links).map(\.id)
                == ["file:/new.png", "file:old.md", "link:https://new.example", "link:https://old.example"])
    }

    /// Every path a test uses names a kind the strip collects.
    private static func candidate(_ path: String, sightings: Int = 1) -> AttachMediaCandidate {
        AttachMediaCandidate(path: path, sightings: sightings, kind: TerminalFileKind.kind(forPath: path) ?? .image)
    }

    private static func file(_ path: String) -> TerminalStripFile {
        TerminalStripFile(path: path, kind: TerminalFileKind.kind(forPath: path) ?? .image, thumbnail: nil)
    }

    private static func link(_ target: String) throws -> AttachLink {
        AttachLink(target: target, url: try #require(URL(string: target)))
    }

    /// Drops every path and stops fetching.
    private static func clean(_ model: TerminalMediaStripModel) {
        model.stop()
        model.note([])
    }

    /// Counts loads in order, by printed path.
    @MainActor
    private final class Loads {
        private(set) var paths: [String] = []
        private let body: ChatMediaLoader

        init(_ body: @escaping ChatMediaLoader) {
            self.body = body
        }

        var load: ChatMediaLoader {
            { [self] media in
                if case .hostFile(let path) = media.source { paths.append(path) }
                return try await body(media)
            }
        }
    }

    /// Holds a load until opened.
    @MainActor
    private final class Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    @MainActor
    private final class FakeClock {
        private(set) var now = ContinuousClock.now

        func advance(_ duration: Duration) {
            now += duration
        }
    }

    /// Bytes that do not decode as an image.
    private static func junkFile() throws -> URL {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "terminal-media-\(UUID().uuidString).png", directoryHint: .notDirectory)
        try Data("not an image".utf8).write(to: file)
        return file
    }

    private struct EncodingFailed: Error {}

    /// A real 8×8 PNG in a temporary file, so the thumbnail decodes.
    private static func pngFile() throws -> URL {
        guard
            let context = CGContext(
                data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw EncodingFailed() }
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        guard let image = context.makeImage() else { throw EncodingFailed() }
        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output as CFMutableData, UTType.png.identifier as CFString, 1, nil)
        else { throw EncodingFailed() }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw EncodingFailed() }
        let file = FileManager.default.temporaryDirectory
            .appending(path: "terminal-media-\(UUID().uuidString).png", directoryHint: .notDirectory)
        try (output as Data).write(to: file)
        return file
    }
}
