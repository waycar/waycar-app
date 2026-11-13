import SwiftUI

/// The preview bar: the files an Agent printed paths to in its terminal and
/// the Attach Links it showed, as a small stack of tiles in the status row
/// (`AgentDetailStatusChrome`): Markdown files and PDFs as glyphs, images
/// as thumbnails, links as one link glyph after them. A document always
/// shows, since nothing is fetched for it until it is opened; an image
/// shows only once it loaded, so a path that is missing, too large, or not
/// decodable leaves no trace. With nothing to show the strip draws nothing
/// at all. A tap calls `open`, which lists every file and link.
///
/// Every kind present has a tile (`tiles(files:links:maximum:)`), so a run
/// of screenshots never hides the one report printed among them, nor files
/// the links.
///
/// Height-neutral by construction: the status row sits in the input
/// chrome's bottom inset, and any change to that row's height resizes the
/// terminal's PTY and makes the Agent's TUI redraw. The stack is laid out
/// zero points tall, centered on the caption's cap height, and drawn past
/// that box into the row's existing padding; only its width takes room.
///
/// Draws only; the model's owner fetches (`terminalMediaFetching`), since a
/// strip with nothing to show is not on screen to do it.
struct TerminalMediaStrip: View {
    let model: TerminalMediaStripModel
    /// The Attach's links, newest first (`AgentAttachStore.attachLinks`).
    let links: [AttachLink]
    let open: () -> Void
    /// One tile and no count: the status row's fallback where the full
    /// stack does not fit (`compact()`), so the list stays one tap away at
    /// any Dynamic Type size.
    private var isCompact = false

    init(model: TerminalMediaStripModel, links: [AttachLink], open: @escaping () -> Void) {
        self.model = model
        self.links = links
        self.open = open
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// How far above the caption baseline the stack centers: half of
    /// caption2's cap height, growing with Dynamic Type.
    @ScaledMetric(relativeTo: .caption2) private var capCenter: CGFloat = 4

    static let maximumTiles = 4
    /// How much each tile tucks under the one before it.
    private static let overlap: CGFloat = 10
    private static let minimumTapSide: CGFloat = 44

    /// What the status row animates on: the files and links listed.
    var visibleIDs: [String] {
        Self.items(files: model.files, links: links).map(\.id)
    }

    /// Everything the strip lists, in the list's order: the files newest
    /// first, then the links newest first.
    static func items(files: [TerminalStripFile], links: [AttachLink]) -> [TerminalStripItem] {
        files.map(TerminalStripItem.file) + links.map(TerminalStripItem.link)
    }

    /// The same strip drawn as its leading tile alone.
    func compact() -> TerminalMediaStrip {
        var strip = self
        strip.isCompact = true
        return strip
    }

    var body: some View {
        let files = model.files
        let tiles = Self.tiles(files: files, links: links, maximum: Self.maximumTiles)
        let shown = isCompact ? Array(tiles.prefix(1)) : tiles
        if !shown.isEmpty {
            Button(action: open) {
                stack(shown, overflow: isCompact ? 0 : Self.overflow(files: files, links: links, tiles: tiles))
                    // At least 44 pt to tap, without taking that room in
                    // the layout: out to the sides and down, never above
                    // the tiles, over the terminal's last row.
                    .contentShape(
                        TapArea(
                            outset: max(0, (Self.minimumTapSide - TerminalMediaStripModel.thumbnailSide) / 2)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Files and links from terminal")
            .accessibilityValue(Self.accessibilityValue(files: files, links: links))
            .accessibilityIdentifier("terminal.file-strip")
            .fixedSize()
            // The height invariant: zero points tall in layout, its box on
            // the caption's cap center, so the row is exactly as tall as
            // without it.
            .frame(height: 0)
            // The guide's closure is Sendable: read the metric here, on the
            // main actor, and hand it the value.
            .alignmentGuide(.firstTextBaseline) { [capCenter] _ in capCenter }
            .transition(tileTransition)
        }
    }

    /// The files counted by kind, Markdown first, then the links: "1
    /// Markdown file, 1 PDF, 10 images, 2 links".
    static func accessibilityValue(files: [TerminalStripFile], links: [AttachLink]) -> String {
        let fileCounts = TerminalFileKind.allCases.compactMap { kind -> String? in
            let count = files.count { $0.kind == kind }
            guard count > 0 else { return nil }
            let noun =
                switch kind {
                case .markdown: count == 1 ? "Markdown file" : "Markdown files"
                case .pdf: count == 1 ? "PDF" : "PDFs"
                case .image: count == 1 ? "image" : "images"
                }
            return "\(count) \(noun)"
        }
        let linkCount = links.isEmpty ? [] : ["\(links.count) \(links.count == 1 ? "link" : "links")"]
        return (fileCounts + linkCount).joined(separator: ", ")
    }

    /// At most `maximum` tiles for the stack: the files' tiles
    /// (`TerminalMediaStripModel.tiles`), then one tile for the newest link
    /// when there are links, which keeps its place however many files
    /// there are.
    static func tiles(
        files: [TerminalStripFile], links: [AttachLink], maximum: Int
    ) -> [TerminalStripItem] {
        guard let newestLink = links.first, maximum > 0 else {
            return TerminalMediaStripModel.tiles(of: files, maximum: maximum).map(TerminalStripItem.file)
        }
        return TerminalMediaStripModel.tiles(of: files, maximum: maximum - 1).map(TerminalStripItem.file)
            + [.link(newestLink)]
    }

    /// How many files and links a stack of `tiles` leaves out: its "+N".
    static func overflow(files: [TerminalStripFile], links: [AttachLink], tiles: [TerminalStripItem]) -> Int {
        max(0, files.count + links.count - tiles.count)
    }

    private func stack(_ shown: [TerminalStripItem], overflow: Int) -> some View {
        HStack(spacing: -Self.overlap) {
            // Each tile on top of the ones after it, which it overlaps.
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                TerminalStripItemIcon(item: item, side: TerminalMediaStripModel.thumbnailSide)
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                    .zIndex(Double(shown.count - index))
                    .transition(tileTransition)
            }
            if overflow > 0 {
                Text("+\(overflow)")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.leading, Self.overlap + 4)
            }
        }
    }

    /// A plain fade under Reduce Motion; otherwise a slight grow as well.
    private var tileTransition: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity)
    }
}

/// The strip's tap area: its box widened by `outset` on each side and
/// lengthened by twice that downward, keeping its top edge.
private struct TapArea: Shape {
    let outset: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(
            CGRect(
                x: rect.minX - outset, y: rect.minY,
                width: rect.width + 2 * outset, height: rect.height + 2 * outset))
    }
}

/// One entry the strip lists: a file the terminal printed a path to, or an
/// Attach Link.
enum TerminalStripItem: Identifiable, Equatable {
    case file(TerminalStripFile)
    case link(AttachLink)

    /// Kind-prefixed, so a link can never share an id with a printed path.
    var id: String {
        switch self {
        case .file(let file): "file:\(file.id)"
        case .link(let link): "link:\(link.id)"
        }
    }
}

/// One file the strip lists, by the path the terminal printed.
struct TerminalStripFile: Identifiable, Equatable {
    var id: String { path }
    /// As printed: unresolved, possibly relative or under `~/`.
    let path: String
    let kind: TerminalFileKind
    /// A loaded image's thumbnail; nil for a document.
    let thumbnail: ImageThumbnail?

    /// The same path and kind, and the very same decoded thumbnail: a
    /// refreshed image is a new file.
    static func == (lhs: TerminalStripFile, rhs: TerminalStripFile) -> Bool {
        lhs.path == rhs.path && lhs.kind == rhs.kind && lhs.thumbnail?.image === rhs.thumbnail?.image
    }
}

extension TerminalFileKind {
    /// The SF Symbol a file of this kind shows when it has no thumbnail.
    var symbolName: String {
        switch self {
        case .markdown: "doc.richtext"
        case .pdf: "doc.text"
        case .image: "photo"
        }
    }
}

/// A strip entry as a square tile: an image's thumbnail, or its kind's
/// glyph (a link's for a link) on a Brand surface, `side` points square
/// with the strip's corner shape at any size. Decorative: whatever shows
/// it says what the entry is.
struct TerminalStripItemIcon: View {
    let item: TerminalStripItem
    let side: CGFloat

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        // The chip radius at the strip's size, scaled with the tile.
        let shape = RoundedRectangle(
            cornerRadius: Brand.Radius.chip * side / TerminalMediaStripModel.thumbnailSide, style: .continuous)
        tile
            .frame(width: side, height: side)
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(Color.primary.opacity(0.2), lineWidth: 1 / max(displayScale, 1))
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder private var tile: some View {
        switch item {
        case .file(let file):
            if let thumbnail = file.thumbnail {
                Image(decorative: thumbnail.image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                glyph(file.kind.symbolName, color: file.kind == .pdf ? Brand.Colors.danger : Brand.Colors.violetSoft)
            }
        case .link:
            glyph("link", color: Brand.Colors.violetSoft)
        }
    }

    private func glyph(_ symbolName: String, color: Color) -> some View {
        ZStack {
            Brand.Colors.surface3
            Image(systemName: symbolName)
                .font(.system(size: side * 0.5, weight: .semibold))
                .foregroundStyle(color)
        }
    }
}

/// The terminal strip's files and image fetches, keyed by printed path.
/// Owned by the Agent screen, so status-row redraws never fetch again.
///
/// Bounded: only the paths in the latest candidate list
/// (`AgentAttachStore.attachMediaCandidates`, at most `maximumPaths`) are
/// listed, and an image path that leaves the list drops its thumbnail at
/// once. A fetched image's local copy is deleted as soon as its thumbnail
/// decodes: the list's preview fetches the file again when tapped.
/// Documents are only listed, never fetched: the list opens one through
/// the file preview when tapped. Image fetches wait
/// until the image paths have settled (`settle`), then run one at a time,
/// newest first, so a path that scrolled through and out again before its
/// turn never starts a transfer. Documents coming and going never hold
/// the image fetches back.
///
/// An image path printed again (its `sightings` grew) fetches again: a
/// failed one at most every `retryInterval`, `maximumRetries` times, since
/// a tool call prints its output path before the file exists; a loaded one
/// at most every `refreshInterval`, keeping its thumbnail until the new one
/// decodes.
@MainActor
@Observable
final class TerminalMediaStripModel {
    /// A tile's side, in points: about a caption line and a half, drawn
    /// into the status row's padding.
    static let thumbnailSide: CGFloat = 22
    /// How long the candidate list must hold still before fetches start.
    static let settleInterval: Duration = .milliseconds(500)
    static let retryInterval: Duration = .seconds(2)
    static let maximumRetries = 5
    static let refreshInterval: Duration = .seconds(60)
    static let maximumPaths = 25

    private enum Status {
        /// Due a fetch once the list settles.
        case waiting
        case fetching
        case failed
        case loaded
    }

    /// One image path's fetch.
    private struct Entry {
        /// The sightings last acted on.
        var sightings: Int
        var status = Status.waiting
        /// Kept through a refresh, so the strip never flickers.
        var thumbnail: ImageThumbnail?
        var lastAttempt: ContinuousClock.Instant?
        var retries = 0
    }

    /// The listed candidates, newest first, every kind.
    private var listed: [AttachMediaCandidate] = []
    /// The listed images' fetches; documents have none.
    private var entries: [String: Entry] = [:]
    @ObservationIgnored private var isSettled = false
    @ObservationIgnored private var load: ChatMediaLoader?
    @ObservationIgnored private var maxPixelSize = 0
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var workerGeneration = 0
    @ObservationIgnored private let now: @MainActor () -> ContinuousClock.Instant

    init(now: @escaping @MainActor () -> ContinuousClock.Instant = { .now }) {
        self.now = now
    }

    /// Decoded big enough for a wide or tall image to still fill the
    /// square tile at its short side.
    static func maxPixelSize(displayScale: CGFloat) -> Int {
        Int((thumbnailSide * 3 * max(displayScale, 1)).rounded(.up))
    }

    /// A printed image path as chat media: the same id and source a chat
    /// message's own path reference gets.
    static func media(for path: String) -> ChatMedia {
        ChatMedia(id: "ref:\(path)", kind: .image, mime: nil, source: .hostFile(path: path), alt: nil)
    }

    /// The candidates the strip lists, in order, each path once, at most
    /// `maximumPaths`.
    static func listed(in candidates: [AttachMediaCandidate]) -> [AttachMediaCandidate] {
        var seen = Set<String>()
        let unique = candidates.filter { seen.insert($0.path).inserted }
        return Array(unique.prefix(maximumPaths))
    }

    /// The files to show, newest first: every listed document, and the
    /// listed images that loaded with a thumbnail.
    var files: [TerminalStripFile] {
        listed.compactMap { candidate in
            guard !candidate.kind.isDocument else {
                return TerminalStripFile(path: candidate.path, kind: candidate.kind, thumbnail: nil)
            }
            return entries[candidate.path]?.thumbnail.map {
                TerminalStripFile(path: candidate.path, kind: candidate.kind, thumbnail: $0)
            }
        }
    }

    /// At most `maximum` of `files` (newest first) for the strip's stack:
    /// the newest of each kind present, then the newest of the rest, so no
    /// kind is crowded out by another. Grouped by kind in
    /// `TerminalFileKind.allCases` order (Markdown, PDF, images), newest
    /// first within a kind: the document glyphs lead the stack, ahead of the
    /// photos, and stay put as images load.
    static func tiles(of files: [TerminalStripFile], maximum: Int) -> [TerminalStripFile] {
        var picked = Set<String>()
        for kind in TerminalFileKind.allCases where picked.count < maximum {
            if let newest = files.first(where: { $0.kind == kind }) { picked.insert(newest.id) }
        }
        for file in files where picked.count < maximum {
            picked.insert(file.id)
        }
        let chosen = files.filter { picked.contains($0.id) }
        return TerminalFileKind.allCases.flatMap { kind in chosen.filter { $0.kind == kind } }
    }

    /// No fetch in flight or about to start.
    var isIdle: Bool {
        worker == nil
    }

    /// The listed images, by path and sightings: what the fetches settle
    /// on. Documents are left out, so their churn never delays a fetch.
    static func imageCandidates(in candidates: [AttachMediaCandidate]) -> [AttachMediaCandidate] {
        listed(in: candidates).filter { $0.kind == .image }
    }

    /// Takes the latest candidate list. Image paths that left it are
    /// forgotten; new ones and re-sighted ones wait for `settle`, and
    /// fetches pause until then. A change to the documents alone lists
    /// them and leaves the fetches running.
    func note(_ candidates: [AttachMediaCandidate]) {
        let listed = Self.listed(in: candidates)
        let images = listed.filter { $0.kind == .image }
        defer { self.listed = listed }
        guard images != self.listed.filter({ $0.kind == .image }) else { return }
        isSettled = false
        let kept = Set(images.map(\.path))
        for path in entries.keys where !kept.contains(path) {
            entries[path] = nil
        }
        for candidate in images {
            guard var entry = entries[candidate.path] else {
                entries[candidate.path] = Entry(sightings: candidate.sightings)
                continue
            }
            if candidate.sightings > entry.sightings {
                entry.sightings = candidate.sightings
                resighted(&entry)
                entries[candidate.path] = entry
            }
        }
    }

    /// The list held still: fetches the waiting images, one at a time,
    /// newest first.
    func settle(using load: @escaping ChatMediaLoader, maxPixelSize: Int) {
        self.load = load
        self.maxPixelSize = maxPixelSize
        isSettled = true
        runWorker()
    }

    /// Off screen: no further fetch starts, and the one in flight is
    /// abandoned; its path waits for the next `settle`.
    func stop() {
        worker?.cancel()
        worker = nil
        isSettled = false
        for (path, entry) in entries where entry.status == .fetching {
            entries[path]?.status = .waiting
        }
    }

    private func resighted(_ entry: inout Entry) {
        let elapsed = entry.lastAttempt.map { now() - $0 }
        switch entry.status {
        case .failed:
            guard entry.retries < Self.maximumRetries, elapsed.map({ $0 >= Self.retryInterval }) ?? true
            else { return }
            entry.retries += 1
            entry.status = .waiting
        case .loaded:
            guard elapsed.map({ $0 >= Self.refreshInterval }) ?? true else { return }
            entry.status = .waiting
        case .waiting, .fetching:
            break
        }
    }

    private func runWorker() {
        guard worker == nil, isSettled else { return }
        workerGeneration += 1
        let generation = workerGeneration
        worker = Task { [weak self] in
            while !Task.isCancelled, let job = self?.nextJob() {
                await self?.fetch(job.path, using: job.load, maxPixelSize: job.maxPixelSize)
            }
            if let self, self.workerGeneration == generation { self.worker = nil }
        }
    }

    private func nextJob() -> (path: String, load: ChatMediaLoader, maxPixelSize: Int)? {
        guard isSettled, let load,
            let path = listed.first(where: { entries[$0.path]?.status == .waiting })?.path
        else { return nil }
        entries[path]?.status = .fetching
        entries[path]?.lastAttempt = now()
        return (path, load, maxPixelSize)
    }

    private func fetch(_ path: String, using load: ChatMediaLoader, maxPixelSize: Int) async {
        let file: URL
        do {
            file = try await load(Self.media(for: path))
        } catch {
            finish(path, thumbnail: nil)
            return
        }
        let thumbnail = await ImageThumbnail.make(contentsOf: file, maxPixelSize: maxPixelSize)
        // Only the thumbnail is kept: a tap previews the file afresh.
        Self.remove(file)
        finish(path, thumbnail: thumbnail)
    }

    private func finish(_ path: String, thumbnail: ImageThumbnail?) {
        guard var entry = entries[path], entry.status == .fetching else { return }
        if let thumbnail { entry.thumbnail = thumbnail }
        entry.status = entry.thumbnail == nil ? .failed : .loaded
        entries[path] = entry
    }

    /// Removes a copy and, once empty, the per-file folder the fetch made
    /// to keep the Host file's name (`ConsoleStore.loadChatMedia`).
    private static func remove(_ file: URL) {
        let manager = FileManager.default
        try? manager.removeItem(at: file)
        let folder = file.deletingLastPathComponent()
        if (try? manager.contentsOfDirectory(atPath: folder.path(percentEncoded: false)))?.isEmpty == true {
            try? manager.removeItem(at: folder)
        }
    }
}

extension View {
    /// Lists the strip's files and fetches its images as `candidates`
    /// appear and change, for as long as this view lives. Applied by the
    /// model's owner, not the strip: the strip draws nothing until it has a
    /// file to show. Fetches start once the image paths have held still for
    /// `TerminalMediaStripModel.settleInterval`, and stop on disappear;
    /// documents list at once and never restart the wait.
    func terminalMediaFetching(
        _ candidates: [AttachMediaCandidate], into model: TerminalMediaStripModel,
        using load: @escaping ChatMediaLoader
    ) -> some View {
        modifier(TerminalMediaFetching(candidates: candidates, model: model, load: load))
    }
}

private struct TerminalMediaFetching: ViewModifier {
    let candidates: [AttachMediaCandidate]
    let model: TerminalMediaStripModel
    let load: ChatMediaLoader
    @Environment(\.displayScale) private var displayScale

    func body(content: Content) -> some View {
        content
            .onChange(of: candidates) { model.note(candidates) }
            .task(id: TerminalMediaStripModel.imageCandidates(in: candidates)) {
                model.note(candidates)
                do {
                    try await Task.sleep(for: TerminalMediaStripModel.settleInterval)
                } catch {
                    return
                }
                model.settle(
                    using: load, maxPixelSize: TerminalMediaStripModel.maxPixelSize(displayScale: displayScale))
            }
            .onDisappear { model.stop() }
    }
}
