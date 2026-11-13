import SwiftUI

/// Files & Links: everything the status row's strip held when the list
/// opened. Files first (`TerminalMediaStripModel.files`), newest first: an
/// image's thumbnail or a document's glyph, its name, and the folder it was
/// printed with. Then the Attach Links, newest first: the host and the
/// full URL. An image or PDF row opens the gallery over this list, at that
/// file, swiping through the list's images and PDFs in list order
/// (``TerminalPreviewGallerySession``); a Markdown row hands the file to
/// `openFile`, and the presenter renders it in its own sheet over this
/// list. Either way the sheet stays up, so closing the preview lands back
/// here, scrolled and sized as it was. While a Markdown file loads,
/// `preview`'s badge shows over the rows and can cancel it. A link row
/// hands the link to `openLink`; the presenter closes this sheet first and
/// opens it after, in the browser, with its copy recovery if that fails. A
/// link's context menu copies it, leaving the sheet up.
struct TerminalFilesAndLinksSheet: View {
    /// The file preview a Markdown row starts, watched for its loading
    /// badge; the presenter wires its sheets and alert onto this view. The
    /// gallery reads through it too.
    let preview: TerminalFilePreviewStore
    /// The folder relative paths resolve against, as for a tapped terminal
    /// path.
    let workingDirectory: String?
    /// A file row the gallery does not take: a Markdown file.
    let openFile: (TerminalStripFile) -> Void
    let openLink: (AttachLink) -> Void
    let copyLink: (AttachLink) -> Void

    /// The strip's files and links as the list opened, thumbnails included:
    /// the terminal keeps printing while the sheet is up, and a row must not
    /// move or vanish under the finger reaching for it. Taken once per
    /// presentation; later ones from the presenter are ignored.
    @State private var files: [TerminalStripFile]
    @State private var links: [AttachLink]
    /// Opens full height: the half-height glass sheet lets the terminal
    /// show through the rows.
    @State private var detent: PresentationDetent = .large
    /// The gallery an image or PDF row opened, over this list.
    @State private var gallerySession: TerminalPreviewGallerySession?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// A row's icon, growing with the name beside it up to `maximumIconSide`.
    @ScaledMetric(relativeTo: .headline) private var scaledIconSide: CGFloat = 44

    /// Past this an image's thumbnail (decoded for the strip's tile) blurs,
    /// and the icon only takes width from the name.
    static let maximumIconSide: CGFloat = 64

    init(
        files: [TerminalStripFile], links: [AttachLink],
        preview: TerminalFilePreviewStore,
        workingDirectory: String?,
        openFile: @escaping (TerminalStripFile) -> Void,
        openLink: @escaping (AttachLink) -> Void,
        copyLink: @escaping (AttachLink) -> Void
    ) {
        _files = State(initialValue: files)
        _links = State(initialValue: links)
        self.preview = preview
        self.workingDirectory = workingDirectory
        self.openFile = openFile
        self.openLink = openLink
        self.copyLink = copyLink
    }

    var body: some View {
        NavigationStack {
            content
                // The terminal hides its own badge while this list is up.
                .overlay(alignment: .top) {
                    if case .loading(let name) = preview.phase {
                        TerminalFilePreviewLoadingBadge(name: name) { preview.cancel() }
                            .padding(.top, 8)
                    }
                }
                .navigationTitle("Files & Links")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("terminal.file-list.done")
                    }
                }
        }
        .terminalPreviewGallery(session: $gallerySession, store: preview)
        .accessibilityIdentifier("terminal.file-list")
        .presentationDetents([.large, .medium], selection: $detent)
    }

    /// The strip hides with nothing in it, so this shows only if it emptied
    /// in the moment before the list opened.
    @ViewBuilder
    private var content: some View {
        if files.isEmpty && links.isEmpty {
            ContentUnavailableView(
                "No Files or Links", systemImage: "doc",
                description: Text("Images, PDFs, Markdown files, and web links the terminal prints show here."))
        } else {
            List {
                if !files.isEmpty {
                    Section("Files") {
                        ForEach(files) { file in
                            row(file)
                        }
                    }
                }
                if !links.isEmpty {
                    Section("Links") {
                        ForEach(links) { link in
                            row(link)
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private func row(_ file: TerminalStripFile) -> some View {
        // At accessibility sizes a name or folder wraps rather than shrink
        // to a few letters.
        let lineLimit = dynamicTypeSize.isAccessibilitySize ? nil : 1
        return Button {
            open(file)
        } label: {
            HStack(spacing: 12) {
                TerminalStripItemIcon(item: .file(file), side: min(scaledIconSide, Self.maximumIconSide))
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.name(of: file.path))
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(lineLimit)
                        .truncationMode(.middle)
                    Text(Self.displayedFolder(of: file.path))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(lineLimit)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        // A button already reads as one element; this names its parts.
        .accessibilityLabel(Self.accessibilityLabel(for: file))
        .accessibilityIdentifier("terminal.file-list.row")
    }

    /// An image or PDF opens the gallery at it, over the list's images and
    /// PDFs as the list opened; a Markdown file goes to `openFile`. Any
    /// preview still loading stops first, so it never lands under the
    /// gallery.
    private func open(_ file: TerminalStripFile) {
        guard let session = TerminalPreviewGallerySession(
            opening: file, in: files, workingDirectory: workingDirectory)
        else {
            openFile(file)
            return
        }
        preview.cancel()
        gallerySession = session
    }

    private func row(_ link: AttachLink) -> some View {
        Button {
            openLink(link)
        } label: {
            HStack(spacing: 12) {
                TerminalStripItemIcon(item: .link(link), side: min(scaledIconSide, Self.maximumIconSide))
                VStack(alignment: .leading, spacing: 2) {
                    Text(link.host)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(link.target)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .accessibilityLabel(link.host)
        .accessibilityValue(link.target)
        .accessibilityHint("Opens in your default browser")
        .accessibilityAction(named: "Copy Link") {
            copyLink(link)
        }
        .contextMenu {
            Button("Copy Link", systemImage: "doc.on.doc") {
                copyLink(link)
            }
        }
        .accessibilityIdentifier("terminal.file-list.link-row")
    }

    /// The file's own name, or the printed path when it ends in none.
    static func name(of path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    /// The folder as printed, or "Current folder" for a bare name, which
    /// resolves against the pane's working directory.
    static func folder(of path: String) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        return folder.isEmpty ? "Current folder" : folder
    }

    /// `folder(of:)` as the row draws it: a printed folder isolated left to
    /// right (U+2066 … U+2069), so a right-to-left name in it cannot swap
    /// its segments around, nor the row's own direction reorder them.
    static func displayedFolder(of path: String) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        return folder.isEmpty ? Self.folder(of: path) : "\u{2066}\(folder)\u{2069}"
    }

    /// One element per row: "README.md, Markdown, docs".
    static func accessibilityLabel(for file: TerminalStripFile) -> String {
        [name(of: file.path), kindName(file.kind), folder(of: file.path)].joined(separator: ", ")
    }

    static func kindName(_ kind: TerminalFileKind) -> String {
        switch kind {
        case .markdown: "Markdown"
        case .pdf: "PDF"
        case .image: "Image"
        }
    }
}
