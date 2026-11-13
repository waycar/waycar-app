import QuickLook
import SwiftUI

/// A Markdown file the user tapped in the terminal, rendered, or shown as
/// raw text — the choice remembered for every file after.
///
/// The file is remote-chosen, so nothing it links to opens on a tap alone:
/// a web link asks first, as a terminal link does; a Host file it names is
/// read after the same go-ahead, a Markdown one pushed onto this sheet's
/// stack and anything else shown in Quick Look over it; an `#anchor` scrolls
/// to its heading; any other scheme is refused.
struct MarkdownFilePreviewSheet: View {
    let preview: MarkdownFilePreview
    @Binding var showsRaw: Bool
    @State private var interaction: MarkdownLinkedFileInteraction
    /// Opens full height: a document is read, not peeked at, and the
    /// half-height glass sheet lets the terminal show through the text.
    @State private var detent: PresentationDetent = .large
    @Environment(\.dismiss) private var dismiss
    /// The real opener, for a web link once confirmed: the rendered pages
    /// get one that only asks.
    @Environment(\.openURL) private var openURL

    init(
        preview: MarkdownFilePreview,
        showsRaw: Binding<Bool>,
        loadLinkedFile: @escaping (TerminalFileReference, _ workingDirectory: String) async throws -> LinkedFilePreview,
        confirmationDetail: @escaping (TerminalLinkTarget, _ workingDirectory: String) async -> String,
        failureMessage: @escaping (any Error) -> String
    ) {
        self.preview = preview
        _showsRaw = showsRaw
        _interaction = State(initialValue: MarkdownLinkedFileInteraction(
            loadLinkedFile: loadLinkedFile, confirmationDetail: confirmationDetail, failureMessage: failureMessage))
    }

    var body: some View {
        @Bindable var interaction = interaction
        NavigationStack(path: $interaction.path) {
            page(preview)
                .navigationDestination(for: MarkdownFilePreview.ID.self) { id in
                    if let linked = interaction.linkedPages[id] {
                        page(linked)
                    }
                }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("markdown-preview.sheet")
        .linkConfirmationAlert($interaction.pendingLink) { target in
            interaction.open(target, openWeb: { openURL($0) })
        }
        // The alert clears `pendingLink` before handing over the target, so
        // the folder is still there for `open`.
        .onChange(of: interaction.pendingLink == nil) { _, ended in
            if ended { interaction.confirmationDidEnd() }
        }
        .quietCancelAlert(
            "Can't Open Link",
            isPresented: Binding(
                get: { interaction.refusedLink != nil },
                set: { if !$0 { interaction.refusedLink = nil } })
        ) {
            Button("OK", role: .cancel) { interaction.refusedLink = nil }
                .tint(Brand.Colors.quietAction)
        } message: {
            Text(interaction.refusedLink?.absoluteString ?? "")
        }
        .quietCancelAlert(
            "Couldn't Preview File",
            isPresented: Binding(
                get: { interaction.loadFailureMessage != nil },
                set: { if !$0 { interaction.loadFailureMessage = nil } })
        ) {
            Button("OK", role: .cancel) { interaction.loadFailureMessage = nil }
                .tint(Brand.Colors.quietAction)
        } message: {
            Text(interaction.loadFailureMessage ?? "")
        }
        .quickLookPreview($interaction.quickLookURL)
        .onDisappear { interaction.disappear() }
        .presentationDetents([.large, .medium], selection: $detent)
    }

    /// Pushed pages share the raw toggle and the interaction's loading badge.
    private func page(_ page: MarkdownFilePreview) -> some View {
        MarkdownFilePreviewPage(
            preview: page,
            showsRaw: $showsRaw,
            loadingName: interaction.loadingName,
            done: { dismiss() },
            cancelLoading: { interaction.cancelLinkedFileLoad() },
            confirm: { interaction.confirm($0, from: page) },
            refuse: { interaction.refusedLink = $0 })
    }
}

/// One file on the sheet's stack: raw, or rendered once parsed — parsed the
/// first time it is shown rendered, never just to sit behind the raw text.
private struct MarkdownFilePreviewPage: View {
    let preview: MarkdownFilePreview
    @Binding var showsRaw: Bool
    let loadingName: String?
    /// Closes the whole sheet; a pushed page's own `dismiss` would pop it.
    let done: () -> Void
    let cancelLoading: () -> Void
    /// Asks the go-ahead for a web link or a Host file.
    let confirm: (TerminalLinkTarget) -> Void
    /// Says a link of a scheme the app never opens was refused.
    let refuse: (URL) -> Void

    @State private var rows: MarkdownDocumentRows?
    @State private var scrollTarget: MarkdownDocumentRow.ID?

    var body: some View {
        ZStack {
            if showsRaw {
                rawText
            } else if let rows {
                rendered(rows)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .top) {
            if let loadingName {
                TerminalFilePreviewLoadingBadge(name: loadingName, cancel: cancelLoading)
                    .padding(.top, 8)
            }
        }
        .navigationTitle(preview.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarItems }
        .task(id: showsRaw) {
            // Switching back to raw, or the page closing, cancels the parse.
            guard !showsRaw else { return }
            await parse()
        }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        // A long name loses its middle, so its extension still shows.
        ToolbarItem(placement: .principal) {
            Text(preview.name)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityAddTraits(.isHeader)
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Done", action: done)
                .accessibilityIdentifier("markdown-preview.done")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button(
                showsRaw ? "Show Rendered" : "Show Raw Text",
                systemImage: showsRaw ? "doc.richtext" : "doc.plaintext"
            ) {
                showsRaw.toggle()
            }
            .accessibilityIdentifier("markdown-preview.toggle")
            ShareLink(item: preview.localURL)
        }
    }

    /// A megabyte of text is laid out only as far as it is in view.
    private var rawText: some View {
        ReadOnlyTextView(
            text: preview.text,
            readableWidth: MarkdownDocumentView.readableWidth,
            accessibilityIdentifier: "markdown-preview.raw")
    }

    private func rendered(_ rows: MarkdownDocumentRows) -> some View {
        MarkdownDocumentView(rows: rows, scrollTarget: $scrollTarget)
            // Every link in the file comes here, never straight to the
            // system.
            .environment(\.openURL, OpenURLAction { url in
                open(url, in: rows)
                return .handled
            })
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("markdown-preview.rendered")
    }

    /// A Host file link keeps its path as written: relative ones are
    /// resolved against this page's folder when confirmed and read.
    private func open(_ url: URL, in rows: MarkdownDocumentRows) {
        switch MarkdownLinkDestination.resolve(url) {
        case .anchor(let anchor):
            // A heading the file lacks makes a dead link in it: nothing to do.
            if let row = rows.rowID(forAnchor: anchor) {
                scrollTarget = row
            }
        case .web(let webURL):
            confirm(.web(webURL))
        case .hostFile(let path):
            confirm(.file(TerminalFileReference(path: path)))
        case nil:
            refuse(url)
        }
    }

    /// Parsed and flattened off the main actor: a file may run to a
    /// megabyte. The work is cancelled with the task that waits on it, and a
    /// cancelled parse leaves the page as it was.
    private func parse() async {
        guard rows == nil else { return }
        let text = preview.text
        let work = Task.detached(priority: .userInitiated) { () -> MarkdownDocumentRows? in
            let document = MarkdownDocument.parse(text)
            guard !Task.isCancelled else { return nil }
            let rows = MarkdownDocumentRows(document)
            return Task.isCancelled ? nil : rows
        }
        let parsed = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        guard !Task.isCancelled, let parsed else { return }
        rows = parsed
    }
}
