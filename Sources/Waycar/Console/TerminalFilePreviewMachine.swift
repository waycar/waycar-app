import Foundation

/// One tapped-file read, with the previous viewer intentionally retained
/// while it loads or fails. Linked copies belong to that Markdown viewer;
/// gallery files have their own close generation, independent of the viewer.
struct TerminalFilePreviewMachine: StateMachine {
    struct Contents: Equatable, Sendable {
        var preview: LinkedFilePreview?
        var linkedCopies: [URL] = []
        var galleryFiles: Set<URL> = []
        var galleryGeneration = 0
    }

    enum State: Equatable, Sendable {
        case ready(Contents)
        case loading(UInt64, name: String, Contents)
        case failed(message: String, Contents)
    }

    enum Event: Equatable, Sendable {
        case request(name: String)
        case cancel
        case presented(UInt64, LinkedFilePreview)
        /// Nil token is a synchronous refusal, not a remote read completion.
        case failed(UInt64?, message: String)
        case dismissFailure
        case closeQuickLook
        case closeMarkdown
        case linkedCopyWritten(URL)
        case galleryFileWritten(URL)
        case removeGalleryFile(URL)
        case removeGalleryFiles
    }

    enum Effect: Equatable, Sendable {
        case startRead(UInt64)
        case cancelRead
        case removeDirectory(URL)
    }

    private(set) var state: State = .ready(Contents())
    private var lastToken: UInt64 = 0

    var contents: Contents {
        switch state {
        case .ready(let contents), .loading(_, _, let contents), .failed(_, let contents): contents
        }
    }

    var loadingToken: UInt64? {
        if case .loading(let token, _, _) = state { return token }
        return nil
    }

    var markdownPreview: MarkdownFilePreview? {
        if case .markdown(let preview) = contents.preview { return preview }
        return nil
    }

    var previewURL: URL? {
        if case .quickLook(let url) = contents.preview { return url }
        return nil
    }

    func acceptsLinkedRead(from preview: UUID?) -> Bool { markdownPreview?.id == preview }
    func acceptsGalleryRead(from generation: Int) -> Bool { contents.galleryGeneration == generation }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (_, .request(let name)):
            let retained = contents
            let cancels = loadingToken == nil ? [] : [Effect.cancelRead]
            lastToken &+= 1
            state = .loading(lastToken, name: name, retained)
            return cancels + [.startRead(lastToken)]
        case (.loading(_, _, let retained), .cancel):
            state = .ready(retained)
            return [.cancelRead]
        case (.ready, .cancel), (.failed, .cancel):
            return [.cancelRead]
        case (.loading(let token, _, var retained), .presented(let received, let preview)) where token == received:
            let removed = closePreviews(in: &retained)
            retained.preview = preview
            state = .ready(retained)
            return removed
        case (_, .failed(let received, let message)) where received == nil || received == loadingToken:
            state = .failed(message: message, contents)
            return []
        case (.failed(_, let retained), .dismissFailure):
            state = .ready(retained)
            return []
        case (_, .closeQuickLook):
            var retained = contents
            guard case .quickLook(let url) = retained.preview else { return [] }
            retained.preview = nil
            update(retained)
            return [.removeDirectory(url.deletingLastPathComponent())]
        case (_, .closeMarkdown):
            var retained = contents
            let removed = closeMarkdown(in: &retained)
            update(retained)
            return removed
        case (_, .linkedCopyWritten(let directory)):
            var retained = contents
            retained.linkedCopies.append(directory)
            update(retained)
            return []
        case (_, .galleryFileWritten(let directory)):
            var retained = contents
            retained.galleryFiles.insert(directory)
            update(retained)
            return []
        case (_, .removeGalleryFile(let directory)):
            var retained = contents
            guard retained.galleryFiles.remove(directory) != nil else { return [] }
            update(retained)
            return [.removeDirectory(directory)]
        case (_, .removeGalleryFiles):
            var retained = contents
            retained.galleryGeneration += 1
            let removed = retained.galleryFiles.map { Effect.removeDirectory($0) }
            retained.galleryFiles = []
            update(retained)
            return removed
        case (.ready, .presented), (.loading, .presented), (.failed, .presented),
             (.ready, .failed), (.loading, .failed), (.failed, .failed),
             (.ready, .dismissFailure), (.loading, .dismissFailure):
            return []
        }
    }

    private mutating func update(_ contents: Contents) {
        switch state {
        case .ready: state = .ready(contents)
        case .loading(let token, let name, _): state = .loading(token, name: name, contents)
        case .failed(let message, _): state = .failed(message: message, contents)
        }
    }

    private func closePreviews(in contents: inout Contents) -> [Effect] {
        var removed: [Effect] = []
        if case .quickLook(let url) = contents.preview {
            contents.preview = nil
            removed.append(.removeDirectory(url.deletingLastPathComponent()))
        }
        return removed + closeMarkdown(in: &contents)
    }

    private func closeMarkdown(in contents: inout Contents) -> [Effect] {
        var removed: [Effect] = []
        if case .markdown(let preview) = contents.preview {
            contents.preview = nil
            removed.append(.removeDirectory(preview.localURL.deletingLastPathComponent()))
        }
        removed += contents.linkedCopies.map { .removeDirectory($0) }
        contents.linkedCopies = []
        return removed
    }
}
