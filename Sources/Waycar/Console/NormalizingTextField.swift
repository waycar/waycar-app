import SwiftUI
import UIKit

/// A single-line field whose bound value may be rewritten by its owner as
/// the user types (a space becoming `-`, capitals lowered). SwiftUI's
/// `TextField` keeps showing the raw keystrokes while it is focused even
/// after the binding's owner rewrites the value, so this bridge writes each
/// edit through the binding, reads the canonical value back, and puts it in
/// the field itself, keeping the cursor the same distance from the end.
/// Nothing is written while the keyboard is composing marked text (dead-key
/// accents, pinyin), so a composition is never broken mid-way.
struct NormalizingTextField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var font: UIFont = .preferredFont(forTextStyle: .body)
    var autocapitalization: UITextAutocapitalizationType = .none
    var accessibilityLabel: String?

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.textAlignment = .right
        field.adjustsFontForContentSizeCategory = true
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartDashesType = .no
        field.smartQuotesType = .no
        field.smartInsertDeleteType = .no
        field.clearButtonMode = .never
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.addTarget(
            context.coordinator, action: #selector(Coordinator.editingChanged(_:)),
            for: .editingChanged)
        // Any target for this event makes Return end editing and dismiss the
        // keyboard, as the SwiftUI fields in the same sheet do.
        field.addTarget(
            context.coordinator, action: #selector(Coordinator.returnPressed(_:)),
            for: .editingDidEndOnExit)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.text = $text
        field.placeholder = placeholder
        field.font = font
        field.autocapitalizationType = autocapitalization
        field.accessibilityLabel = accessibilityLabel
        if field.markedTextRange == nil, field.text != text {
            Coordinator.replaceText(of: field, with: text)
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, uiView: UITextField, context: Context
    ) -> CGSize? {
        CGSize(
            width: proposal.width ?? uiView.intrinsicContentSize.width,
            height: uiView.intrinsicContentSize.height)
    }

    @MainActor
    final class Coordinator: NSObject {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        @objc func editingChanged(_ field: UITextField) {
            guard field.markedTextRange == nil else { return }
            let typed = field.text ?? ""
            if text.wrappedValue != typed {
                text.wrappedValue = typed
            }
            let canonical = text.wrappedValue
            if canonical != typed {
                Self.replaceText(of: field, with: canonical)
            }
        }

        @objc func returnPressed(_ field: UITextField) {}

        /// Replaces the field's text. The cursor keeps its distance from the
        /// end while the text after it is unchanged (a rewrite behind the
        /// cursor never throws it to the end of the line); when the rewrite
        /// reached past it (the 32-character cap cutting the tail), it keeps
        /// its distance from the start instead. The undo stack is cleared
        /// because UIKit's pending typing record can point past the shorter
        /// text and crash a later undo.
        static func replaceText(of field: UITextField, with value: String) {
            let typed = field.text ?? ""
            let caret = field.selectedTextRange?.end ?? field.endOfDocument
            let fromStart = field.offset(from: field.beginningOfDocument, to: caret)
            let fromEnd = field.offset(from: caret, to: field.endOfDocument)
            let sharedSuffix = zip(typed.utf16.reversed(), value.utf16.reversed())
                .prefix(while: { $0 == $1 }).count
            field.text = value
            field.undoManager?.removeAllActions()
            let length = field.offset(from: field.beginningOfDocument, to: field.endOfDocument)
            let target = fromEnd <= sharedSuffix
                ? max(0, length - fromEnd) : min(fromStart, length)
            if let position = field.position(from: field.beginningOfDocument, offset: target) {
                field.selectedTextRange = field.textRange(from: position, to: position)
            }
        }
    }
}
