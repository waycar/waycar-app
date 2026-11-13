import QuickLook
import SwiftUI
import UIKit

extension View {
    /// Presents the gallery over this view while `session` is non-nil.
    /// Sets it to nil on close and deletes every local copy it made.
    ///
    /// Quick Look itself, full screen from whatever presents this view (the
    /// Files & Links sheet included): swipe between pages, zoom, the list,
    /// Share with Save Image, and swipe down or Close to land back here.
    /// A page not read yet shows a stand-in — an image's thumbnail, or its
    /// kind's glyph — and a failed one its message, until its file lands
    /// (``TerminalPreviewGalleryModel``).
    func terminalPreviewGallery(
        session: Binding<TerminalPreviewGallerySession?>,
        store: TerminalFilePreviewStore
    ) -> some View {
        background(TerminalPreviewGalleryPresenter(session: session, store: store))
    }
}

/// An empty controller in the presenting view's hierarchy that presents
/// `QLPreviewController` from there. Presented modally rather than embedded
/// in a SwiftUI cover, Quick Look keeps its own chrome (Close, the list,
/// Share), its swipe-down dismissal and its full-screen presentation on
/// iPad too, over a form sheet.
private struct TerminalPreviewGalleryPresenter: UIViewControllerRepresentable {
    @Binding var session: TerminalPreviewGallerySession?
    let store: TerminalFilePreviewStore

    func makeCoordinator() -> TerminalPreviewGalleryController {
        TerminalPreviewGalleryController()
    }

    func makeUIViewController(context: Context) -> TerminalPreviewGalleryHost {
        let host = TerminalPreviewGalleryHost()
        host.didAppear = { [weak coordinator = context.coordinator] in coordinator?.reconcile() }
        return host
    }

    func updateUIViewController(_ host: TerminalPreviewGalleryHost, context: Context) {
        let binding = $session
        context.coordinator.update(
            wanted: session, store: store, host: host, close: { binding.wrappedValue = nil })
    }

    static func dismantleUIViewController(
        _ host: TerminalPreviewGalleryHost, coordinator: TerminalPreviewGalleryController
    ) {
        coordinator.tearDown()
    }
}

/// Tells the gallery once it is in a window, so a session set before then
/// still presents.
final class TerminalPreviewGalleryHost: UIViewController {
    var didAppear: (@MainActor () -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        // Only a presenter: it never takes a touch or a VoiceOver stop.
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        didAppear?()
    }
}

/// A gallery page as Quick Look takes it. Immutable: a page whose file
/// lands is handed over as a new item.
private final class TerminalPreviewGalleryItem: NSObject, QLPreviewItem, Sendable {
    let previewItemURL: URL?
    let previewItemTitle: String?

    init(url: URL?, title: String?) {
        previewItemURL = url
        previewItemTitle = title
    }
}

/// Feeds Quick Look the model's pages and follows its page changes.
///
/// Quick Look asks for a page once and keeps what it got, a stand-in
/// included, even after the file lands and the user swipes to it (seen on
/// the iOS 27 simulator). So the URL served for each page is remembered,
/// and the page on screen is refreshed whenever what it should show
/// differs: when its read lands or fails, and when the user arrives on it.
/// Arrival is observed through key-value observing on
/// `currentPreviewItemIndex`, which Quick Look updates on every swipe and
/// list pick.
@MainActor
final class TerminalPreviewGalleryController: NSObject, QLPreviewControllerDataSource,
    @preconcurrency QLPreviewControllerDelegate
{
    private enum StandIn: Equatable {
        case loading
        case failed(String)
    }

    private weak var host: TerminalPreviewGalleryHost?
    private var store: TerminalFilePreviewStore?
    private var wanted: TerminalPreviewGallerySession?
    private var close: (() -> Void)?

    private var model: TerminalPreviewGalleryModel?
    private var preview: QLPreviewController?
    private var observation: NSKeyValueObservation?
    /// What Quick Look last got for each page it asked for; nil inside
    /// when that was no file.
    private var served: [Int: URL?] = [:]
    private var standIns: [Int: (kind: StandIn, url: URL)] = [:]

    func update(
        wanted: TerminalPreviewGallerySession?, store: TerminalFilePreviewStore,
        host: TerminalPreviewGalleryHost, close: @escaping () -> Void
    ) {
        self.wanted = wanted
        self.store = store
        self.host = host
        self.close = close
        // Never present from inside a view update.
        Task { @MainActor [weak self] in self?.reconcile() }
    }

    /// Presents the wanted session, or dismisses the one showing once it
    /// is no longer wanted and then presents the next.
    func reconcile() {
        if let model, model.session.id != wanted?.id {
            let leaving = preview
            finish()
            // Still up: the next one presents once it is gone, from here
            // or from its own dismissal. Already gone without telling its
            // delegate: nothing holds the next one up.
            if let leaving, leaving.presentingViewController != nil {
                if !leaving.isBeingDismissed {
                    leaving.dismiss(animated: true) { [weak self] in self?.reconcile() }
                }
                return
            }
        }
        guard model == nil, let wanted, let store, let host, host.view.window != nil,
            host.presentedViewController == nil
        else { return }
        guard !wanted.files.isEmpty else {
            close?()
            return
        }
        let model = TerminalPreviewGalleryModel(session: wanted, store: store)
        let preview = QLPreviewController()
        // Before the start page is set: Quick Look keeps it within the
        // count the data source gives, none without the model.
        self.model = model
        self.preview = preview
        model.pageDidChange = { [weak self] index in self?.pageDidChange(index) }
        preview.dataSource = self
        preview.delegate = self
        preview.currentPreviewItemIndex = model.current
        observation = preview.observe(\.currentPreviewItemIndex) { [weak self] preview, _ in
            MainActor.assumeIsolated {
                self?.previewDidMove(to: preview.currentPreviewItemIndex)
            }
        }
        model.show(model.current)
        host.present(preview, animated: true)
    }

    /// The presenting view went away: close the gallery with it. Nothing
    /// is wanted any more, so its dismissal presents nothing in its place.
    func tearDown() {
        wanted = nil
        let leaving = preview
        finish()
        if let leaving, leaving.presentingViewController != nil, !leaving.isBeingDismissed {
            leaving.dismiss(animated: true)
        }
    }

    /// Stops every read and removes every copy; the controller itself is
    /// dismissed by the caller, or already by the user.
    private func finish() {
        observation = nil
        model?.close()
        model = nil
        preview = nil
        served = [:]
        standIns = [:]
    }

    private func previewDidMove(to index: Int) {
        model?.show(index)
        removeLandedStandIns()
        refreshIfStale()
    }

    /// Only the page on screen is refreshed for its own change. Another
    /// page's change — a read ahead starting, a copy evicted — leaves what
    /// it shows as it was, and would refresh it again before Quick Look
    /// asked for what the last refresh offered.
    private func pageDidChange(_ index: Int) {
        guard index == preview?.currentPreviewItemIndex else { return }
        refreshIfStale()
    }

    private func refreshIfStale() {
        guard let preview, let model else { return }
        let index = preview.currentPreviewItemIndex
        guard model.pages.indices.contains(index), let shown = served[index], shown != url(for: index)
        else { return }
        preview.refreshCurrentPreviewItem()
    }

    // MARK: QLPreviewControllerDataSource

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        model?.session.files.count ?? 0
    }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
        guard let model, model.session.files.indices.contains(index) else {
            return TerminalPreviewGalleryItem(url: nil, title: nil)
        }
        let url = url(for: index)
        served[index] = url
        let title = TerminalFileReference(path: model.session.files[index].path).displayName
        return TerminalPreviewGalleryItem(url: url, title: title)
    }

    // MARK: QLPreviewControllerDelegate

    func previewControllerDidDismiss(_ controller: QLPreviewController) {
        guard controller === preview else {
            // One given up for another session is gone: that one can
            // present now, outside this callback.
            Task { @MainActor [weak self] in self?.reconcile() }
            return
        }
        finish()
        close?()
    }

    // MARK: Pages

    /// The page's copy once it landed, else its stand-in; nil only when
    /// the stand-in could not be written.
    private func url(for index: Int) -> URL? {
        guard let model else { return nil }
        switch model.pages[index] {
        case .ready(let copy): return copy
        case .waiting, .loading: return standIn(.loading, for: index)
        case .failed(let message): return standIn(.failed(message), for: index)
        }
    }

    private func standIn(_ kind: StandIn, for index: Int) -> URL? {
        if let held = standIns[index], held.kind == kind { return held.url }
        guard let model, let store else { return nil }
        if let stale = standIns.removeValue(forKey: index) { store.removeGalleryFile(at: stale.url) }
        let file = model.session.files[index]
        let failure: String? = if case .failed(let message) = kind { message } else { nil }
        let image = TerminalPreviewGalleryStandIn.render(
            kind: file.kind, thumbnail: file.thumbnail, failure: failure)
        let note = kind == .loading ? String(localized: "loading") : String(localized: "unavailable")
        guard let data = image.pngData(),
            let url = try? store.galleryStandIn(data, forRemotePath: file.path, note: note)
        else { return nil }
        standIns[index] = (kind, url)
        return url
    }

    /// Removes the stand-ins of pages whose copy landed, once they are
    /// more than a page from the one on screen. Quick Look may still be
    /// showing one beside it; a page farther off now has its copy, which
    /// arriving on it refreshes it to (``refreshIfStale()``). A stand-in
    /// Quick Look was last served for its page is kept, since Quick Look
    /// holds on to that URL until the refresh; it goes once the page is
    /// served its copy, or when the gallery closes.
    private func removeLandedStandIns() {
        guard let model, let store else { return }
        for (index, standIn) in standIns where abs(index - model.current) > 1 {
            guard case .ready = model.pages[index], served[index] != .some(standIn.url) else { continue }
            store.removeGalleryFile(at: standIn.url)
            standIns[index] = nil
        }
    }
}

/// What a page shows until its file lands: the image's thumbnail, dimmed,
/// or the kind's glyph, with "Loading…" or the reason it failed.
private enum TerminalPreviewGalleryStandIn {
    /// Long side, in pixels: big enough that Quick Look's fit-to-screen
    /// scaling keeps the text legible.
    static let side: CGFloat = 1200

    static func render(kind: TerminalFileKind, thumbnail: ImageThumbnail?, failure: String?) -> UIImage {
        let size: CGSize
        if let thumbnail, thumbnail.image.width > 0, thumbnail.image.height > 0 {
            let width = CGFloat(thumbnail.image.width)
            let height = CGFloat(thumbnail.image.height)
            let scale = side / max(width, height)
            size = CGSize(width: (width * scale).rounded(), height: (height * scale).rounded())
        } else {
            size = CGSize(width: side * 3 / 4, height: side)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let bounds = CGRect(origin: .zero, size: size)
            UIColor.secondarySystemBackground.resolvedColor(with: dark).setFill()
            context.fill(bounds)
            if let thumbnail {
                UIImage(cgImage: thumbnail.image).draw(in: bounds)
                UIColor.black.withAlphaComponent(0.55).setFill()
                // Normal, not the copy `fill(_:)` may use: the thumbnail
                // shows dimmed through it.
                context.fill(bounds, blendMode: .normal)
            }
            let glyphName = failure == nil
                ? (thumbnail == nil ? kind.symbolName : nil)
                : "exclamationmark.triangle"
            var textTop = bounds.midY
            if let glyphName,
                let glyph = UIImage(
                    systemName: glyphName,
                    withConfiguration: UIImage.SymbolConfiguration(pointSize: side / 8, weight: .regular))?
                    .withTintColor(.white.withAlphaComponent(0.85), renderingMode: .alwaysOriginal)
            {
                let origin = CGPoint(x: bounds.midX - glyph.size.width / 2, y: bounds.midY - glyph.size.height - 24)
                glyph.draw(at: origin)
                textTop = bounds.midY + 8
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let text = NSAttributedString(
                string: failure ?? String(localized: "Loading…"),
                attributes: [
                    .font: UIFont.systemFont(ofSize: side / 22, weight: .semibold),
                    .foregroundColor: UIColor.white,
                    .paragraphStyle: paragraph,
                ])
            let inset = size.width / 10
            let textBounds = CGRect(
                x: inset, y: textTop - (glyphName == nil ? side / 30 : 0),
                width: size.width - inset * 2, height: size.height - textTop)
            text.draw(with: textBounds, options: [.usesLineFragmentOrigin], context: nil)
        }
    }
}
