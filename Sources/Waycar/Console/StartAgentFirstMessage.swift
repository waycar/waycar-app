import SwiftUI
import UIKit

/// New Agent's first message row: the Composer Tray's chips over a growing
/// text field whose Paste also takes images and files, as the Agent
/// Composer's does (`ComposerPasteTextView`), and a drop target for both.
/// Nothing uploads from here: the chips wait, unbound, until Start prepares
/// them, and the message reaches the started Agent as a Queued Message
/// (CONTEXT.md **Queued Launch**). Add Image and Add File live in the row
/// under it (`StartAgentFirstMessageAddMenu`); the sheet presents their
/// pickers.
struct StartAgentFirstMessageEditor: View {
    let store: StartAgentStore
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ComposerTrayView(tray: store.firstMessageTray)
            FirstMessageTextView(
                text: store.firstMessageText,
                selectedRange: selection,
                attachmentCount: store.firstMessageAttachments.count,
                onEdit: { text, range in
                    if store.firstMessageText != text { store.firstMessageText = text }
                    selection = range
                },
                onPasteAttachments: accept)
                .overlay(alignment: .topLeading) {
                    if store.firstMessageText.isEmpty {
                        Text("Optional")
                            .foregroundStyle(.tertiary)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
        }
        .padding(.vertical, 4)
        .composerDropDestination(isEnabled: true, isTargeted: $isDropTargeted, accept: accept)
        // A drag over the row tints it, as the Composer card's does.
        .listRowBackground(isDropTargeted ? Color.accentColor.opacity(0.12) : nil)
    }

    /// A paste or drop, in order: text lands at the caret, images and files
    /// join the tray as far as it has room. A pasted file's copy that did
    /// not fit is deleted, as the Composer does.
    private func accept(_ items: [ComposerDropItem]) {
        var sources: [ComposerStagingStore.Source] = []
        for item in items {
            switch item {
            case .text(let text):
                insert(text)
            case .image(let data, _):
                sources.append(.photo(DataImageSelection(data: data)))
            case .file(let url):
                sources.append(.file(url))
            case .unsupported:
                continue
            }
        }
        let taken = store.addFirstMessageAttachments(sources)
        sources.dropFirst(taken).forEach(ComposerTray.discardLocalCopy)
    }

    private func insert(_ text: String) {
        let current = store.firstMessageText as NSString
        let location = min(selection.location, current.length)
        let range = NSRange(
            location: location, length: min(selection.length, current.length - location))
        store.firstMessageText = current.replacingCharacters(in: range, with: text)
        selection = NSRange(location: location + (text as NSString).length, length: 0)
    }
}

/// The row under the first message: Add Image and Add File, the Agent
/// Composer's own `+` entries (`AgentActionMenuItem`), off once the tray is
/// full.
struct StartAgentFirstMessageAddMenu: View {
    let canAdd: Bool
    let addImage: () -> Void
    let addFile: () -> Void

    var body: some View {
        Menu {
            button(.addImage, action: addImage)
            button(.addFile, action: addFile)
        } label: {
            Label("Add Image or File", systemImage: "plus")
        }
        .accessibilityHint("Adds images or files to the first message")
    }

    private func button(_ item: AgentActionMenuItem, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label {
                Text(item.title)
                if !canAdd {
                    Text("\(ComposerTray.capacity) per message")
                }
            } icon: {
                Image(systemName: item.systemImage)
            }
        }
        .disabled(!canAdd)
    }
}

/// The first message's text: a body-sized text view three lines tall that
/// grows to ten, then scrolls. Return breaks the line; the sheet's Start
/// sends. Paste with images or files goes to `onPasteAttachments`; the chips
/// it adds push the text down, so the Form scrolls the caret back above the
/// keyboard.
private struct FirstMessageTextView: UIViewRepresentable {
    let text: String
    let selectedRange: NSRange
    /// The tray's item count: a rise while typing reveals the caret.
    let attachmentCount: Int
    let onEdit: (String, NSRange) -> Void
    let onPasteAttachments: @MainActor ([ComposerDropItem]) -> Void

    private static let minimumLines: CGFloat = 3
    private static let maximumLines: CGFloat = 10

    func makeCoordinator() -> Coordinator {
        Coordinator(onEdit: onEdit, attachmentCount: attachmentCount)
    }

    func makeUIView(context: Context) -> ComposerPasteTextView {
        let textView = ComposerPasteTextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = false
        textView.accessibilityLabel = "First Message"
        return textView
    }

    func updateUIView(_ textView: ComposerPasteTextView, context: Context) {
        context.coordinator.onEdit = onEdit
        textView.onPasteAttachments = onPasteAttachments
        if textView.text != text {
            textView.text = text
            textView.invalidateIntrinsicContentSize()
        }
        let length = (textView.text as NSString).length
        if selectedRange.location + selectedRange.length <= length,
            textView.selectedRange != selectedRange
        {
            textView.selectedRange = selectedRange
        }
        let coordinator = context.coordinator
        if attachmentCount != coordinator.attachmentCount {
            let grew = attachmentCount > coordinator.attachmentCount
            coordinator.attachmentCount = attachmentCount
            if grew, textView.isFirstResponder {
                // Once the row has grown around the new chips.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak textView] in
                    textView?.revealCaretInEnclosingScrollView()
                }
            }
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, uiView: ComposerPasteTextView, context _: Context
    ) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let measured = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude))
        let lineHeight = uiView.font?.lineHeight ?? 20
        let maximumHeight = lineHeight * Self.maximumLines
        uiView.isScrollEnabled = measured.height > maximumHeight
        return CGSize(
            width: width,
            height: min(max(lineHeight * Self.minimumLines, measured.height), maximumHeight))
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var onEdit: (String, NSRange) -> Void
        var attachmentCount: Int

        init(onEdit: @escaping (String, NSRange) -> Void, attachmentCount: Int) {
            self.onEdit = onEdit
            self.attachmentCount = attachmentCount
        }

        func textViewDidChange(_ textView: UITextView) {
            onEdit(textView.text, textView.selectedRange)
            textView.invalidateIntrinsicContentSize()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            onEdit(textView.text, textView.selectedRange)
        }
    }
}

private extension UITextView {
    /// Scrolls the nearest enclosing scroll view, the Form's, until the
    /// caret shows clear of the keyboard.
    func revealCaretInEnclosingScrollView() {
        guard let end = selectedTextRange?.end else { return }
        var ancestor = superview
        while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
        guard let scrollView = ancestor as? UIScrollView else { return }
        let caret = convert(caretRect(for: end), to: scrollView).insetBy(dx: 0, dy: -16)
        scrollView.scrollRectToVisible(caret, animated: true)
    }
}
