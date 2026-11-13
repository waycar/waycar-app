import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Previews a file a terminal line named, after the user tapped it.
///
/// The path is resolved against the pane's working directory and the Host's
/// home, and read through the transport's bounded preview read. A Markdown
/// file of at most ``markdownRenderMaximumBytes`` is rendered by the app in
/// its own sheet (``markdownPreview``, #147); any other file, a larger
/// Markdown one included, is written to a private temporary file for Quick
/// Look. Either copy is removed again when its preview closes or the detail
/// goes away, with the copies of the files a Markdown preview's links
/// opened (``linkedPreview(_:workingDirectory:)``) and those a gallery
/// holds (``galleryCopy(of:workingDirectory:)``); copies a killed app left
/// behind are swept the first time a store starts. One preview shows at a
/// time: a new one closes the last. Nothing is ever fetched except the one
/// path tapped — at most with its fallback readings tried in turn while one
/// names no file (``TerminalFileReference/fallbackPaths``) — a link in a
/// Markdown preview the user confirmed, or what a gallery opened from Files
/// & Links asks for: the image or PDF on screen, and an image beside it,
/// which the strip already read for its thumbnail. A PDF is read only once
/// the user is on it (``TerminalPreviewGalleryModel``).
@MainActor
@Observable
final class TerminalFilePreviewStore {
    enum Phase: Equatable {
        case idle
        case loading(name: String)
        case failed(message: String)
    }

    @ObservationIgnored private var machine = TerminalFilePreviewMachine()

    /// Publication mirrors only: the machine owns the lifecycle. Bookkeeping
    /// and ignored events must not invalidate the terminal or its presenters.
    private(set) var phase: Phase = .idle
    /// The local copy Quick Look shows; nil while nothing is previewed.
    private(set) var previewURL: URL?
    /// The Markdown file the app renders, set instead of ``previewURL``;
    /// nil while none is shown.
    private(set) var markdownPreview: MarkdownFilePreview?

    /// The largest Markdown file rendered. A larger one is shown as text in
    /// Quick Look instead, so a huge document never stalls the parser or
    /// the layout.
    nonisolated static let markdownRenderMaximumBytes = 1_048_576

    private let read: PreviewFileReader
    private let resolveHome: @Sendable () async throws -> String
    private let temporaryRoot: URL
    /// The read in flight, if any; internal so a test can await a read it
    /// cancelled.
    private(set) var task: Task<Void, Never>?

    init(
        read: @escaping PreviewFileReader,
        resolveHome: @escaping @Sendable () async throws -> String,
        temporaryRoot: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TerminalFilePreview", isDirectory: true)
    ) {
        self.read = read
        self.resolveHome = resolveHome
        self.temporaryRoot = temporaryRoot
        // Once per process, not per store: another window's store may be
        // showing a copy from this root right now.
        if Self.sweptRoots.insert(temporaryRoot.standardizedFileURL).inserted {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
    }

    private static var sweptRoots: Set<URL> = []

    var isLoading: Bool {
        if case .loading = phase { return true }
        return false
    }

    var failureMessage: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    func preview(_ file: TerminalFileReference, workingDirectory: String?) {
        cancel()
        let effects = machine.handle(.request(name: file.displayName))
        publishPhase()
        perform(effects) { token in
            startRead(file, workingDirectory: workingDirectory, token: token)
        }
    }

    private func startRead(_ file: TerminalFileReference, workingDirectory: String?, token: UInt64) {
        task = Task { [weak self, read, resolveHome] in
            do {
                let (data, path) = try await Self.readFirstFile(
                    of: file, workingDirectory: workingDirectory,
                    read: read, resolveHome: resolveHome)
                try Task.checkCancellation()
                self?.present(data, remotePath: path, token: token)
            } catch {
                // Cancelled here: another tap, Cancel, or the detail leaving.
                guard !Task.isCancelled else { return }
                // Anything else is said, never dropped — the session winding
                // down under the read (backgrounding, Retry) included — or
                // the tap would seem to have done nothing.
                self?.fail(error is CancellationError ? TransportError.cancelled : error, token: token)
            }
        }
    }

    /// Reads the first of the reference's paths that names a file. One that
    /// cannot be placed, names nothing, or names a folder gives way to the
    /// next; when every one does, the first one's reason stands, as the
    /// reading the tap most likely meant.
    private nonisolated static func readFirstFile(
        of file: TerminalFileReference,
        workingDirectory: String?,
        read: PreviewFileReader,
        resolveHome: @Sendable () async throws -> String
    ) async throws -> (data: Data, path: String) {
        var home: String?
        var firstFailure: RemoteFilePreviewError?
        for candidate in [file.path] + file.fallbackPaths {
            // A tap elsewhere, Cancel, or the detail leaving stops the
            // search before another remote read, not only after it.
            try Task.checkCancellation()
            do {
                if home == nil, TerminalPathResolver.needsHomeDirectory(candidate) {
                    home = try await resolveHome()
                }
                guard let path = TerminalPathResolver.resolve(
                    candidate, workingDirectory: workingDirectory, homeDirectory: home)
                else { throw RemoteFilePreviewError.unresolvablePath }
                return (try await read(path, RemoteFilePreview.maximumBytes), path)
            } catch let failure as RemoteFilePreviewError where failure.leavesAnotherReadingToTry {
                firstFailure = firstFailure ?? failure
            }
        }
        throw firstFailure ?? RemoteFilePreviewError.missing
    }

    /// Stops a preview still loading; a preview already on screen stays.
    func cancel() {
        perform(machine.handle(.cancel))
        publishPhase()
    }

    /// What a confirmation for `target` shows: for a file, the Host path a
    /// Preview would read, with `~` resolved against the Host's home. When
    /// the home cannot be learned the path stays as printed, and a Preview
    /// of it fails the same way.
    func confirmationDetail(for target: TerminalLinkTarget, workingDirectory: String?) async -> String {
        var home: String?
        if case .file(let file) = target, TerminalPathResolver.needsHomeDirectory(file.path) {
            home = try? await resolveHome()
        }
        return target.confirmationDetail(workingDirectory: workingDirectory, homeDirectory: home)
    }

    /// A tapped link the app will not read, said the way a failed read is.
    func refuse(_ reason: RemoteFilePreviewError) {
        cancel()
        fail(reason)
    }

    /// The detail is going away: stop any read and remove every copy, a
    /// gallery's included.
    func close() {
        cancel()
        closePreviews()
        removeGalleryFiles()
    }

    func dismissFailure() {
        perform(machine.handle(.dismissFailure))
        publishPhase()
    }

    /// Quick Look closed: its local copy goes with it.
    func previewDidClose() {
        let effects = machine.handle(.closeQuickLook)
        publishPreviewURL()
        perform(effects)
    }

    /// The Markdown sheet closed: its local copy goes with it, and so do
    /// those of the files its links opened.
    func markdownPreviewDidClose() {
        let effects = machine.handle(.closeMarkdown)
        publishMarkdownPreview()
        perform(effects)
    }

    /// Reads a file a link in the Markdown preview named, once the user
    /// confirmed it: the same bounded read and readings a tap gets, and the
    /// same choice of viewer — a Markdown file within the cap comes back to
    /// be rendered, anything else as a copy for Quick Look. The copy goes
    /// when the Markdown preview closes. Throws `CancellationError`, having
    /// written nothing, once the asking task is cancelled or the preview
    /// that asked has closed or been replaced.
    func linkedPreview(
        _ file: TerminalFileReference,
        workingDirectory: String?
    ) async throws -> LinkedFilePreview {
        let asking = markdownPreview?.id
        let (data, path) = try await Self.readFirstFile(
            of: file, workingDirectory: workingDirectory,
            read: read, resolveHome: resolveHome)
        try Task.checkCancellation()
        guard machine.acceptsLinkedRead(from: asking) else { throw CancellationError() }
        let copy = try writeCopy(of: data, remotePath: path)
        perform(machine.handle(.linkedCopyWritten(copy.directory)))
        return copy.preview
    }

    /// Reads a file for a gallery: the same bounded read and readings a tap
    /// gets, written to a private copy under the name Quick Look may be
    /// given (``localFileName(forRemotePath:)``), never rendered as
    /// Markdown, and nothing published to this store's own preview. The
    /// copy stays until ``removeGalleryFile(at:)``, ``removeGalleryFiles()``
    /// or ``close()``. Throws `CancellationError`, having written nothing,
    /// once the asking task is cancelled or every gallery file went while
    /// it read.
    func galleryCopy(of file: TerminalFileReference, workingDirectory: String?) async throws -> URL {
        let generation = machine.contents.galleryGeneration
        let (data, path) = try await Self.readFirstFile(
            of: file, workingDirectory: workingDirectory,
            read: read, resolveHome: resolveHome)
        try Task.checkCancellation()
        guard machine.acceptsGalleryRead(from: generation) else { throw CancellationError() }
        return try writeGalleryFile(data, named: Self.localFileName(forRemotePath: path))
    }

    /// Writes what a gallery shows for the file at `path` while it holds
    /// no copy of it — a stand-in while it loads, or its failure — beside
    /// the gallery's copies, as private and as short-lived. Named after
    /// the file, read the way a copy's name is, and what it stands in for
    /// (`chart.png (loading).png`), so one shared or saved from Quick Look
    /// is plainly not the file.
    func galleryStandIn(_ png: Data, forRemotePath path: String, note: String) throws -> URL {
        try writeGalleryFile(png, named: "\(Self.remoteFileName(path)) (\(note)).png")
    }

    /// Removes one gallery file and its private directory; a URL that is
    /// not a gallery file is left alone.
    func removeGalleryFile(at url: URL) {
        let directory = url.deletingLastPathComponent()
        perform(machine.handle(.removeGalleryFile(directory)))
    }

    /// The gallery closed: every copy and stand-in goes, and a read still
    /// in flight writes none.
    func removeGalleryFiles() {
        perform(machine.handle(.removeGalleryFiles))
    }

    private func writeGalleryFile(_ data: Data, named name: String) throws -> URL {
        let file = try writePrivateFile(data, named: name)
        perform(machine.handle(.galleryFileWritten(file.directory)))
        return file.url
    }

    private func present(_ data: Data, remotePath: String, token: UInt64) {
        guard machine.loadingToken == token else { return }
        task = nil
        do {
            let copy = try writeCopy(of: data, remotePath: remotePath)
            closePreviews()
            perform(machine.handle(.presented(token, copy.preview)))
            switch copy.preview {
            case .markdown: publishMarkdownPreview()
            case .quickLook: publishPreviewURL()
            }
            publishPhase()
        } catch {
            fail(error, token: token)
        }
    }

    /// Writes `data` to a fresh private directory: a Markdown file within
    /// ``markdownRenderMaximumBytes`` under its own name, to be rendered,
    /// and anything else under the name Quick Look may be given
    /// (``localFileName(forRemotePath:)``). The Markdown copy keeps its
    /// `.md` or `.markdown`: it is only ever offered to Share, never handed
    /// to Quick Look, so its extension picks no renderer.
    private func writeCopy(
        of data: Data,
        remotePath: String
    ) throws -> (preview: LinkedFilePreview, directory: URL) {
        let rendersMarkdown = Self.isMarkdown(pathExtension: (remotePath as NSString).pathExtension)
            && data.count <= Self.markdownRenderMaximumBytes
        let name = rendersMarkdown
            ? (remotePath as NSString).lastPathComponent
            : Self.localFileName(forRemotePath: remotePath)
        let file = try writePrivateFile(data, named: name)
        guard rendersMarkdown else { return (.quickLook(file.url), file.directory) }
        let preview = MarkdownFilePreview(
            id: UUID(), remotePath: remotePath,
            text: String(decoding: data, as: UTF8.self), localURL: file.url)
        return (.markdown(preview), file.directory)
    }

    /// Writes `data` as `name` in a fresh private directory under the
    /// store's root, readable only while the device is unlocked; nothing is
    /// left behind when that fails.
    private func writePrivateFile(_ data: Data, named name: String) throws -> (url: URL, directory: URL) {
        let directory = temporaryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(name)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            return (url, directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// One preview at a time: a new one closes whichever is showing, and
    /// its copies go with it.
    private func closePreviews() {
        previewDidClose()
        markdownPreviewDidClose()
    }

    private func fail(_ error: any Error, token: UInt64? = nil) {
        if let token, machine.loadingToken != token { return }
        task = nil
        perform(machine.handle(.failed(token, message: Self.failureMessage(for: error))))
        publishPhase()
    }

    private func publishPhase() {
        let next: Phase = switch machine.state {
        case .ready: .idle
        case .loading(_, let name, _): .loading(name: name)
        case .failed(let message, _): .failed(message: message)
        }
        if phase != next { phase = next }
    }

    private func publishPreviewURL() {
        let next = machine.previewURL
        if previewURL != next { previewURL = next }
    }

    private func publishMarkdownPreview() {
        let next = machine.markdownPreview
        if markdownPreview != next { markdownPreview = next }
    }

    private func perform(
        _ effects: [TerminalFilePreviewMachine.Effect],
        startRead: (UInt64) -> Void = { _ in }
    ) {
        for effect in effects {
            switch effect {
            case .startRead(let token): startRead(token)
            case .cancelRead:
                task?.cancel()
                task = nil
            case .removeDirectory(let directory):
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }

    /// What a failed preview says: a refused read's reason, a transport
    /// failure as the app words it everywhere, or the error's own
    /// description. The Markdown sheet says a failed link the same way.
    nonisolated static func failureMessage(for error: any Error) -> String {
        if let preview = error as? RemoteFilePreviewError {
            return preview.errorDescription ?? "This file can't be previewed."
        }
        if let transport = error as? TransportError {
            return transport.presentation.message
        }
        return error.localizedDescription
    }

    /// Whether a file with this extension is Markdown the app renders
    /// itself: `.md` or `.markdown`, in any case. Not `.mdx`, whose JSX is
    /// no Markdown. A bare name with one is a Terminal Link too
    /// (``TerminalLinkTarget``).
    nonisolated static func isMarkdown(pathExtension: String) -> Bool {
        ["md", "markdown"].contains(pathExtension.lowercased())
    }

    /// The remote name when its type is one Quick Look shows with a
    /// contained viewer — common raster images, PDF, plain text and source,
    /// and common audio and video — so it picks that viewer by extension.
    /// Anything else (web pages, SVG, camera RAW, Photoshop and other image
    /// formats, 3D and office documents, archives) gets `.txt` and is shown
    /// as text: the file is remote-chosen and the rest of Quick Look's
    /// renderers are not meant to be pointed at hostile input.
    nonisolated static func localFileName(forRemotePath path: String) -> String {
        let name = remoteFileName(path)
        guard isNativelyPreviewable(pathExtension: (name as NSString).pathExtension)
        else { return name + ".txt" }
        return name
    }

    /// The remote path's last component, or `file` when that names none.
    private nonisolated static func remoteFileName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty || name == "/" || name == "." || name == ".." ? "file" : name
    }

    /// Whether Quick Look shows a file with this extension in a contained
    /// viewer (`nativelyPreviewableTypes`). A chat's file attachments go
    /// through the same rule (`ChatMedia.fileExtension`).
    nonisolated static func isNativelyPreviewable(pathExtension: String) -> Bool {
        guard !pathExtension.isEmpty, let type = UTType(filenameExtension: pathExtension)
        else { return false }
        return nativelyPreviewableTypes.contains(type)
    }

    /// Matched exactly, never by conformance: a subtype would admit every
    /// decoder ImageIO has, and any type a third-party app exports for an
    /// extension would hand the bytes to that app's Quick Look extension.
    private nonisolated static let nativelyPreviewableTypes: Set<UTType> = {
        var types: Set<UTType> = [
            .png, .jpeg, .gif, .heic, .heif, .webP,
            .pdf,
            .plainText, .json,
            .swiftSource, .cSource, .cHeader, .cPlusPlusSource, .cPlusPlusHeader,
            .objectiveCSource, .objectiveCPlusPlusSource, .assemblyLanguageSource,
            .javaScript, .pythonScript, .rubyScript, .perlScript, .phpScript, .shellScript,
            .mp3, .mpeg4Audio, .wav,
            .mpeg4Movie, .quickTimeMovie,
        ]
        // What `.m4a` and `.m4v` name: the system's own types, with no named
        // constants.
        for identifier in ["com.apple.m4a-audio", "com.apple.m4v-video"] {
            if let type = UTType(identifier) { types.insert(type) }
        }
        return types
    }()
}

/// Shown over the terminal while a tapped file is fetched for its preview.
struct TerminalFilePreviewLoadingBadge: View {
    let name: String
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("Loading \(name)…")
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Button("Cancel", systemImage: "xmark.circle.fill", action: cancel)
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal.file-preview.loading")
    }
}
