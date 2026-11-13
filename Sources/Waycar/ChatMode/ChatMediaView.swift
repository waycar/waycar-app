import AVFoundation
import ImageIO
import QuickLook
import SwiftUI
import UIKit

/// Fetches one piece of chat media to a local file
/// (`ConsoleStore.chatMediaFile(for:agent:)`).
typealias ChatMediaLoader = @MainActor @Sendable (ChatMedia) async throws -> URL

/// A group of chat media as thumbnails: one item at its own aspect ratio,
/// more as a two-column square grid whose sixth tile counts the rest. A tap
/// opens Quick Look over the group's loaded files (zoom, share, video
/// playback); a failed tile retries. Videos and web items wait for a tap
/// (`ChatMedia.loadsOnTap`), then open once loaded. An item in
/// `silentFailures` that fails shows no tile (`ChatMediaGroupModel.visible`),
/// and the layout counts only the tiles left.
struct ChatMediaView: View {
    let media: [ChatMedia]
    let load: ChatMediaLoader
    /// Ids of media read from an Agent's prose whose path stays in the
    /// text: nothing says the file exists, so a failed fetch drops the
    /// tile instead of showing an error, and the path alone remains.
    var silentFailures: Set<ChatMedia.ID> = []

    @State private var model = ChatMediaGroupModel()
    @State private var preview: URL?
    /// The item a tap started fetching, opened in Quick Look once loaded.
    @State private var awaitingPreview: ChatMedia.ID?
    @Environment(\.displayScale) private var displayScale

    static let maximumTiles = 6
    static let singleMaxHeight: CGFloat = 280
    static let gridMaxWidth: CGFloat = 360
    /// About a phone bubble's width: the single thumbnail never shows wider.
    private static let singleThumbnailWidth: CGFloat = 300
    private static let spacing: CGFloat = 4

    var body: some View {
        let shown = visibleMedia
        Group {
            if shown.count == 1, let item = shown.first {
                tile(item, overflow: 0, isGridTile: false)
            } else if !shown.isEmpty {
                // Eager rows of two, not a lazy grid: a lazy container inside
                // the chat's scroll view lays out from estimates.
                let tiles = Array(shown.prefix(Self.maximumTiles).enumerated())
                let rest = Self.overflowCount(of: shown.count)
                VStack(alignment: .leading, spacing: Self.spacing) {
                    ForEach(Array(stride(from: 0, to: tiles.count, by: 2)), id: \.self) { start in
                        HStack(spacing: Self.spacing) {
                            ForEach(tiles[start..<min(start + 2, tiles.count)], id: \.element.id) {
                                offset, item in
                                let overflow = offset == Self.maximumTiles - 1 ? rest : 0
                                tile(item, overflow: overflow, isGridTile: true)
                                    .frame(maxWidth: .infinity)
                            }
                            if start + 1 == tiles.count {
                                Color.clear.frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
                .frame(maxWidth: Self.gridMaxWidth)
            }
        }
        .accessibilityElement(children: .contain)
        // Fetched as soon as the group appears, and never cancelled: on a
        // reopen the detail column reports the chat gone right after it
        // appeared, with no appear after it, and nothing that waits for
        // visibility (`.task`, scroll visibility) runs again there. Each
        // Host runs two transfers at a time (`ChatMediaTransfers`), so a
        // chat full of images leaves its transcript reads a channel. Items
        // that load on a tap are left for it.
        .onAppear { model.start(media, using: load, maxPixelSize: thumbnailPixels) }
        .onChange(of: media.map(\.id)) {
            model.start(media, using: load, maxPixelSize: thumbnailPixels)
        }
        .onChange(of: model.files(of: media)) {
            guard let id = awaitingPreview else { return }
            switch model.phases[id] {
            case .loaded(let file, _):
                awaitingPreview = nil
                preview = file
            case .failed:
                awaitingPreview = nil
            case .loading, nil:
                break
            }
        }
        .quickLookPreview($preview, in: model.files(of: media))
    }

    /// The items showing a tile, in order.
    private var visibleMedia: [ChatMedia] {
        model.visible(media, hidingFailuresOf: silentFailures)
    }

    /// What the sixth tile's "+N" counts: itself and every item after it.
    private static func overflowCount(of count: Int) -> Int {
        count > maximumTiles ? count - maximumTiles + 1 : 0
    }

    /// Sized by the whole group, not its visible tiles, so every fetch of
    /// a group decodes alike; an item left alone by hidden failures shows
    /// at its grid size.
    private var thumbnailPixels: Int {
        let points = media.count == 1 ? Self.singleThumbnailWidth : Self.gridMaxWidth / 2
        return Int((points * displayScale).rounded(.up))
    }

    // MARK: Tiles

    private func tile(_ item: ChatMedia, overflow: Int, isGridTile: Bool) -> some View {
        let phase = model.phases[item.id]
        let shape = RoundedRectangle(cornerRadius: Brand.Radius.bubble, style: .continuous)
        return Button {
            tapped(item, overflow: overflow)
        } label: {
            Group {
                if isGridTile {
                    Color.clear
                        .aspectRatio(1, contentMode: .fit)
                        .overlay { tileContent(item, phase: phase) }
                } else {
                    singleContent(item, phase: phase)
                }
            }
            .overlay {
                if overflow > 0 {
                    ZStack {
                        Brand.Colors.black.opacity(0.55)
                        Text("+\(overflow)")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(Brand.Colors.white)
                    }
                }
            }
            .clipShape(shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(overflow > 0 ? "\(overflow) more" : Self.label(for: item, phase: phase))
        .accessibilityValue(Self.value(for: phase, item: item))
        .accessibilityHint(Self.isFailed(phase) ? "Retries" : "")
    }

    @ViewBuilder
    private func singleContent(_ item: ChatMedia, phase: ChatMediaGroupModel.Phase?) -> some View {
        if case .loaded(_, let thumbnail?) = phase {
            Image(decorative: thumbnail.image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                // Never upscaled past its own size, so an icon stays small.
                .frame(
                    maxWidth: max(CGFloat(thumbnail.image.width) / displayScale, 44),
                    maxHeight: Self.singleMaxHeight)
                .overlay {
                    if item.kind == .video { Self.playGlyph(size: 44) }
                }
        } else {
            tileContent(item, phase: phase)
                .frame(width: 240, height: 180)
        }
    }

    /// A tile's face: the thumbnail filling the tile, or a placeholder.
    @ViewBuilder
    private func tileContent(_ item: ChatMedia, phase: ChatMediaGroupModel.Phase?) -> some View {
        switch phase {
        case .loaded(_, let thumbnail?):
            Image(decorative: thumbnail.image, scale: 1)
                .resizable()
                .scaledToFill()
                .overlay {
                    if item.kind == .video { Self.playGlyph(size: 30) }
                }
        case .loaded(_, nil):
            // Fetched but not decodable here; Quick Look may still show it.
            placeholder {
                Image(systemName: Self.fetchedKindGlyph(item.kind))
                    .font(.title2)
                    .foregroundStyle(Brand.Colors.text2)
            }
        case .failed(let failure):
            placeholder {
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title3)
                    Text(failure == .pluginOutdated ? "Update the Waycar plugin" : "Can't load")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(Brand.Colors.text2)
                .padding(8)
            }
        case .loading:
            placeholder {
                ProgressView()
                    .tint(Brand.Colors.text2)
            }
        case nil:
            if item.loadsOnTap {
                tapToLoad(item)
            } else {
                placeholder {
                    ProgressView()
                        .tint(Brand.Colors.text2)
                }
            }
        }
    }

    /// An item waiting for a tap: a play glyph for a video, a photo glyph
    /// for a web image, a document glyph for a file, and the host a web
    /// item would load from.
    private func tapToLoad(_ item: ChatMedia) -> some View {
        placeholder {
            VStack(spacing: 6) {
                switch item.kind {
                case .video:
                    Self.playGlyph(size: 36)
                case .file:
                    Image(systemName: "doc")
                        .font(.title2)
                        .foregroundStyle(Brand.Colors.text2)
                case .image:
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(Brand.Colors.text2)
                }
                if let host = item.webHost {
                    Text("Tap to load from \(host)")
                        .font(.caption)
                        .foregroundStyle(Brand.Colors.text2)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(8)
        }
    }

    private func placeholder<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ZStack {
            Brand.Colors.chatAgent
            content()
        }
    }

    /// The placeholder glyph for media that was fetched but not decodable
    /// here; Quick Look may still open it. `.file` can be anything, so it
    /// gets the document glyph.
    private static func fetchedKindGlyph(_ kind: ChatMedia.Kind) -> String {
        switch kind {
        case .video: "play.rectangle"
        case .file: "doc"
        case .image: "photo"
        }
    }

    private static func playGlyph(size: CGFloat) -> some View {
        Image(systemName: "play.circle.fill")
            .font(.system(size: size))
            .foregroundStyle(Brand.Colors.white.opacity(0.92))
            .shadow(color: Brand.Colors.black.opacity(0.4), radius: 4)
    }

    private func tapped(_ item: ChatMedia, overflow: Int) {
        // The "+N" tile stands for itself and the hidden rest.
        let items = overflow > 0 ? Array(visibleMedia.dropFirst(Self.maximumTiles - 1)) : [item]
        switch model.phases[item.id] {
        case .loaded(let file, _):
            if FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
                preview = file
            } else {
                // Evicted from the cache or the scratch directory: fetch again.
                awaitingPreview = item.id
                model.reload([item], using: load, maxPixelSize: thumbnailPixels)
            }
        case .failed:
            if overflow == 0, item.loadsOnTap { awaitingPreview = item.id }
            model.restart(items, using: load, maxPixelSize: thumbnailPixels)
        case .loading, nil:
            if overflow > 0, let file = model.files(of: items).first {
                preview = file
            } else {
                if overflow == 0, item.loadsOnTap { awaitingPreview = item.id }
                model.restart(items, using: load, maxPixelSize: thumbnailPixels)
            }
        }
    }

    // MARK: Accessibility

    private static func label(for item: ChatMedia, phase: ChatMediaGroupModel.Phase?) -> String {
        let noun = switch item.kind {
        case .image: "image"
        case .video: "video"
        case .file: "file"
        }
        if phase == nil, item.loadsOnTap {
            if let host = item.webHost { return "Load \(noun) from \(host)" }
            return "Load \(noun)"
        }
        if let alt = item.alt, !alt.isEmpty { return alt }
        return noun.capitalized
    }

    private static func value(for phase: ChatMediaGroupModel.Phase?, item: ChatMedia) -> String {
        switch phase {
        case .loaded: ""
        case .failed(.some(.pluginOutdated)): "Update the Waycar plugin"
        case .failed: "Can't load"
        case .loading: "Loading"
        case nil: item.loadsOnTap ? (item.alt ?? "") : "Loading"
        }
    }

    private static func isFailed(_ phase: ChatMediaGroupModel.Phase?) -> Bool {
        if case .failed = phase { true } else { false }
    }
}

/// One media group's fetches and thumbnails, by media id. A fetch is never
/// cancelled: it runs to its end and records the outcome, so an item shown
/// as loading always has a fetch under way. Failed items fetch again on a
/// tap. ConsoleStore shares one fetch per item across groups and chats.
@MainActor
@Observable
final class ChatMediaGroupModel {
    enum Phase {
        case loading
        /// A nil thumbnail: the file could not be decoded here.
        case loaded(file: URL, thumbnail: ImageThumbnail?)
        /// A nil error: a failure other than a `ChatMediaError`.
        case failed(ChatMediaError?)
    }

    private(set) var phases: [ChatMedia.ID: Phase] = [:]

    /// The items of `media` that show a tile, in order. A failed item in
    /// `silent` is dropped, except one that loads on a tap
    /// (`ChatMedia.loadsOnTap`): it fetches only when the user taps it
    /// (or the "+N" tile), so its failure answers that tap and keeps its
    /// tile to retry. A dropped item is never retried by the group: a
    /// later appearance of the message fetches it again.
    func visible(_ media: [ChatMedia], hidingFailuresOf silent: Set<ChatMedia.ID>) -> [ChatMedia] {
        guard !silent.isEmpty else { return media }
        return media.filter { item in
            guard silent.contains(item.id), case .failed = phases[item.id] else { return true }
            return item.loadsOnTap
        }
    }

    /// The loaded files of `media` still on disk, in order: Quick Look's
    /// gallery. A file the cache evicted is skipped.
    func files(of media: [ChatMedia]) -> [URL] {
        media.compactMap { item -> URL? in
            guard case .loaded(let file, _) = phases[item.id],
                FileManager.default.fileExists(atPath: file.path(percentEncoded: false))
            else { return nil }
            return file
        }
    }

    /// Fetches the items not fetched yet, except those that load on a tap
    /// (`ChatMedia.loadsOnTap`). Items loading, loaded or failed are left alone.
    func start(_ media: [ChatMedia], using load: @escaping ChatMediaLoader, maxPixelSize: Int) {
        fetch(
            media.filter { phases[$0.id] == nil && !$0.loadsOnTap }, using: load, maxPixelSize: maxPixelSize)
    }

    /// Fetches loaded items again, as when their file is gone. Items
    /// already loading are left alone.
    func reload(_ media: [ChatMedia], using load: @escaping ChatMediaLoader, maxPixelSize: Int) {
        fetch(
            media.filter { item in
                if case .loading = phases[item.id] { false } else { true }
            },
            using: load, maxPixelSize: maxPixelSize)
    }

    /// A tap: fetches the failed items (and any never fetched) again.
    func restart(_ media: [ChatMedia], using load: @escaping ChatMediaLoader, maxPixelSize: Int) {
        fetch(
            media.filter { item in
                switch phases[item.id] {
                case nil, .failed: true
                case .loading, .loaded: false
                }
            },
            using: load, maxPixelSize: maxPixelSize)
    }

    private func fetch(_ media: [ChatMedia], using load: @escaping ChatMediaLoader, maxPixelSize: Int) {
        for item in media {
            phases[item.id] = .loading
            Task {
                do {
                    let file = try await load(item)
                    let thumbnail = await ImageThumbnail.make(
                        for: file, kind: item.kind, maxPixelSize: maxPixelSize)
                    phases[item.id] = .loaded(file: file, thumbnail: thumbnail)
                } catch {
                    phases[item.id] = .failed(error as? ChatMediaError)
                }
            }
        }
    }
}

extension ImageThumbnail {
    /// Decodes off the main actor: images (and files, whose type is unknown)
    /// through ImageIO at most `maxPixelSize` on their long side, videos as
    /// their first frame.
    fileprivate static func make(for file: URL, kind: ChatMedia.Kind, maxPixelSize: Int) async -> ImageThumbnail? {
        switch kind {
        case .image, .file:
            // A file attachment's type is unknown: an image decodes, and
            // anything else gets no thumbnail and opens in Quick Look.
            return await make(contentsOf: file, maxPixelSize: maxPixelSize)
        case .video:
            return await Task.detached(priority: .userInitiated) { () -> ImageThumbnail? in
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
                guard let frame = try? await generator.image(at: .zero) else { return nil }
                return ImageThumbnail(image: frame.image)
            }.value
        }
    }
}
