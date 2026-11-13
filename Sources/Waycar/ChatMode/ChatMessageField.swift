import SwiftUI
import UIKit

/// Chat Mode's growing message field. With a hardware keyboard attached,
/// Return sends and Shift+Return breaks the line; without one, Return breaks
/// the line and the input bar's Send button sends. Grows to six lines, then
/// scrolls.
struct ChatMessageField: UIViewRepresentable {
    let text: String
    let selectedRange: NSRange
    let onEdit: (String, NSRange) -> Void
    @Binding var isFocused: Bool
    let onReturn: () -> Void
    /// A paste holding images or files; see `ComposerPasteTextView`.
    let onPasteAttachments: @MainActor ([ComposerDropItem]) -> Void

    /// Grows to this many lines, then scrolls.
    private static let maximumLines: CGFloat = 6

    func makeCoordinator() -> Coordinator {
        Coordinator(onEdit: onEdit, onReturn: onReturn, isFocused: $isFocused)
    }

    func makeUIView(context: Context) -> ComposerPasteTextView {
        let textView = ComposerPasteTextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = UIColor(Brand.Colors.text)
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.keyboardAppearance = Brand.colorScheme == .dark ? .dark : .light
        textView.isScrollEnabled = false
        textView.accessibilityLabel = "Message"
        return textView
    }

    func updateUIView(_ textView: ComposerPasteTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onEdit = onEdit
        coordinator.onReturn = onReturn
        textView.onPasteAttachments = onPasteAttachments
        if textView.text != text {
            textView.text = text
            textView.invalidateIntrinsicContentSize()
        }
        if textView.selectedRange != selectedRange {
            textView.selectedRange = selectedRange
        }
        let shouldFocus = isFocused
        coordinator.wantsFocus = shouldFocus
        guard shouldFocus != textView.isFirstResponder else { return }
        DispatchQueue.main.async { [weak textView] in
            guard let textView else { return }
            if shouldFocus {
                guard !textView.isFirstResponder else { return }
                textView.becomeFirstResponder()
            } else {
                // A stale `false` flushed from inside `becomeFirstResponder`
                // must not undo the focus it raced.
                guard !coordinator.wantsFocus else { return }
                _ = textView.resignFirstResponder()
            }
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: ComposerPasteTextView,
        context _: Context
    ) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let measured = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude))
        let lineHeight = uiView.font?.lineHeight ?? 20
        let maximumHeight = lineHeight * Self.maximumLines
        uiView.isScrollEnabled = measured.height > maximumHeight
        return CGSize(width: width, height: min(max(lineHeight, measured.height), maximumHeight))
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var onEdit: (String, NSRange) -> Void
        var onReturn: () -> Void
        /// The latest focus intent, from either SwiftUI or UIKit, so a
        /// deferred focus change can recheck it before acting.
        var wantsFocus = false
        private var isFocused: Binding<Bool>

        init(
            onEdit: @escaping (String, NSRange) -> Void,
            onReturn: @escaping () -> Void,
            isFocused: Binding<Bool>
        ) {
            self.onEdit = onEdit
            self.onReturn = onReturn
            self.isFocused = isFocused
        }

        /// Injected by tests; whether a hardware keyboard is attached.
        var isHardwareKeyboardConnected: @MainActor () -> Bool = {
            HardwareShiftTracker.shared.isKeyboardConnected
        }
        /// Injected by tests; reads the hardware keyboard's live Shift.
        var isHardwareShiftHeld: @MainActor () -> Bool = { HardwareShiftTracker.shared.isHeld }

        /// Return arrives as a lone "\n" from either keyboard, and on iPadOS
        /// a hardware Return carries no key event to read Shift from (#80),
        /// so the live keyboard state decides: with a hardware keyboard,
        /// Return sends and Shift+Return inserts the newline; without one,
        /// the on-screen Return inserts it (the Send button sends). Pastes
        /// arrive whole and insert, except a clipboard holding only a line
        /// break while a hardware keyboard is attached, which counts as
        /// Return. IME composition keeps its Return.
        func textView(
            _ textView: UITextView,
            shouldChangeTextIn _: NSRange,
            replacementText text: String
        ) -> Bool {
            guard text == "\n", textView.markedTextRange == nil,
                isHardwareKeyboardConnected(), !isHardwareShiftHeld()
            else {
                return true
            }
            onReturn()
            return false
        }

        func textViewDidChange(_ textView: UITextView) {
            onEdit(textView.text, textView.selectedRange)
            textView.invalidateIntrinsicContentSize()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            onEdit(textView.text, textView.selectedRange)
        }

        func textViewDidBeginEditing(_: UITextView) {
            wantsFocus = true
            isFocused.wrappedValue = true
        }

        func textViewDidEndEditing(_: UITextView) {
            wantsFocus = false
            isFocused.wrappedValue = false
        }
    }
}
