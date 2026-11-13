import Foundation
import Observation

/// One gallery session: the index's images and PDFs, in index order.
struct TerminalPreviewGallerySession: Identifiable, Equatable {
    let id: UUID
    /// Only `.image` and `.pdf` kinds.
    let files: [TerminalStripFile]
    let startIndex: Int
    let workingDirectory: String?

    init(id: UUID = UUID(), files: [TerminalStripFile], startIndex: Int, workingDirectory: String?) {
        self.id = id
        self.files = files
        self.startIndex = startIndex
        self.workingDirectory = workingDirectory
    }

    /// The gallery a tap on `file` in the index opens: the index's images
    /// and PDFs in its order, starting at `file`. Nil for a Markdown file,
    /// which opens its own sheet, or a file the index does not list.
    init?(opening file: TerminalStripFile, in index: [TerminalStripFile], workingDirectory: String?) {
        let files = index.filter { Self.kinds.contains($0.kind) }
        guard let start = files.firstIndex(where: { $0.id == file.id }) else { return nil }
        self.init(files: files, startIndex: start, workingDirectory: workingDirectory)
    }

    /// What a gallery pages through. Markdown is rendered in its own sheet
    /// instead, and links are not files.
    static let kinds: Set<TerminalFileKind> = [.image, .pdf]
}

/// What a gallery holds and reads: a local copy of each page it shows,
/// fetched through the preview store (``TerminalFilePreviewStore/galleryCopy(of:workingDirectory:)``).
///
/// The page on screen is read first: the first page shown, the one tapped,
/// at once, and a page the user arrives on once they have stayed on it for
/// the model's dwell (``dwellDuration`` by default), so a page only swiped
/// past opens no channel. That matters: a read stopped still holds one of
/// a Host's few channels until its file's open and close on the Host
/// finish. Once the page on screen has loaded or failed, at most one image
/// beside it is read ahead, the next one before the previous: the strip
/// already read every image it lists for the thumbnail. A PDF is read only
/// while it is on screen, never ahead. A read carries on only while its
/// page is on screen or an image beside it: arriving on a page being read
/// ahead keeps that read as the page's own, and stepping back keeps it as
/// the read-ahead again, rather than stopping it to start it over. Any
/// other read stops — the page left, a PDF, or one no longer beside the
/// page on screen — and its page is read again when the user comes back.
/// So at most two reads are in flight, the current page's and one beside
/// it. A failed page keeps its message and holds up no other.
///
/// At most ``heldCopyLimit`` copies are kept: past it the one farthest from
/// the page on screen goes, and is read again on arrival. ``close()``
/// removes every copy, and the store's own `close()` does when the detail
/// goes.
@MainActor
@Observable
final class TerminalPreviewGalleryModel {
    typealias Page = TerminalPreviewGalleryMachine.Page

    static let heldCopyLimit = 5
    /// How long the user stays on a page they arrived on before it is read.
    nonisolated static let dwellDuration: Duration = .milliseconds(250)

    let session: TerminalPreviewGallerySession
    var pages: [Page] { gallery.pages }
    /// The page on screen.
    var current: Int { gallery.current }
    private var gallery: TerminalPreviewGalleryMachine
    /// Told each page whose state changed, after it changed.
    @ObservationIgnored var pageDidChange: (@MainActor (Int) -> Void)?

    @ObservationIgnored private let store: TerminalFilePreviewStore
    @ObservationIgnored private let dwell: @Sendable () async throws -> Void
    @ObservationIgnored private var reads: [UInt64: Task<Void, Never>] = [:]
    @ObservationIgnored private var dwells: [UInt64: Task<Void, Never>] = [:]

    /// `dwell` returns once the user has stayed long enough on a page they
    /// arrived on for it to be read, and throws once cancelled: the user
    /// left it, or the gallery closed.
    init(
        session: TerminalPreviewGallerySession, store: TerminalFilePreviewStore,
        dwell: @escaping @Sendable () async throws -> Void = {
            try await Task.sleep(for: TerminalPreviewGalleryModel.dwellDuration)
        }
    ) {
        self.session = session
        self.store = store
        self.dwell = dwell
        gallery = TerminalPreviewGalleryMachine(
            kinds: session.files.map(\.kind), startIndex: session.startIndex, heldCopyLimit: Self.heldCopyLimit)
    }

    /// The page at `index` is on screen. Reads carry on only for it and an
    /// image beside it, so the page left keeps its read only as such an
    /// image. This page is read unless it is held, failed or being read
    /// already: at once when it is the first page shown, the one tapped,
    /// and otherwise once the user has stayed on it for the dwell.
    func show(_ index: Int) {
        send(.show(index))
    }

    /// The gallery closed: every read stops and every copy goes.
    func close() {
        send(.close)
    }

    private func send(_ event: TerminalPreviewGalleryMachine.Event) {
        for effect in gallery.handle(event) {
            switch effect {
            case .read(let index, let token):
                startReading(index, token: token)
            case .cancelRead(let token):
                reads.removeValue(forKey: token)?.cancel()
            case .armDwell(let token):
                dwells[token] = Task { [weak self, dwell] in
                    do { try await dwell() } catch { return }
                    guard !Task.isCancelled else { return }
                    self?.dwells[token] = nil
                    self?.send(.dwellElapsed(token))
                }
            case .cancelDwell(let token):
                dwells.removeValue(forKey: token)?.cancel()
            case .pageChanged(let index):
                pageDidChange?(index)
            case .removeCopy(let url):
                store.removeGalleryFile(at: url)
            case .removeAllCopies:
                store.removeGalleryFiles()
            }
        }
    }

    private func startReading(_ index: Int, token: UInt64) {
        let file = TerminalFileReference(path: session.files[index].path)
        reads[token] = Task { [weak self, store, workingDirectory = session.workingDirectory] in
            do {
                let copy = try await store.galleryCopy(of: file, workingDirectory: workingDirectory)
                guard let self, !Task.isCancelled else {
                    store.removeGalleryFile(at: copy)
                    return
                }
                self.reads[token] = nil
                self.send(.readFinished(index: index, token: token, page: .ready(copy)))
            } catch {
                // Stopped here: the page was left or the gallery closed.
                guard !Task.isCancelled else { return }
                let failure: any Error = error is CancellationError ? TransportError.cancelled : error
                self?.reads[token] = nil
                self?.send(.readFinished(index: index, token: token, page: .failed(
                    message: TerminalFilePreviewStore.failureMessage(for: failure))))
            }
        }
    }
}
