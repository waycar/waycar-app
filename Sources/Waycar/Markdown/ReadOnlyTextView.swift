import SwiftUI
import UIKit

/// Plain monospaced text in a read-only, selectable UIKit text view that
/// does its own scrolling. UIKit lays out only the lines in view, so a file
/// of a megabyte opens at once where one SwiftUI `Text` would lay out the
/// lot first. Nothing in it is detected or linked: the text is
/// remote-chosen, and a raw view of it should only ever show it.
struct ReadOnlyTextView: UIViewRepresentable {
    let text: String
    /// The widest the lines run; a wider view centres them.
    let readableWidth: CGFloat
    let accessibilityIdentifier: String

    func makeUIView(context: Context) -> ReadableTextView {
        let textView = ReadableTextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isSelectable = true
        textView.dataDetectorTypes = []
        textView.backgroundColor = .clear
        // The system label colour, not the brand's dark-only text: the sheet
        // follows the app's appearance, as the rendered page does.
        textView.textColor = .label
        textView.font = UIFontMetrics(forTextStyle: .footnote)
            .scaledFont(for: .monospacedSystemFont(ofSize: ReadableTextView.footnoteSize, weight: .regular))
        textView.adjustsFontForContentSizeCategory = true
        textView.alwaysBounceVertical = true
        textView.accessibilityIdentifier = accessibilityIdentifier
        return textView
    }

    func updateUIView(_ textView: ReadableTextView, context: Context) {
        textView.readableWidth = readableWidth
        textView.show(text)
    }
}

/// A text view that keeps its lines to a readable width, centred, and
/// comes back to the top whenever it is given new text.
final class ReadableTextView: UITextView {
    /// The footnote style's size at the default text size, which the font
    /// metrics scale from.
    static let footnoteSize = UIFont.preferredFont(
        forTextStyle: .footnote,
        compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
    ).pointSize
    private static let margin: CGFloat = 16

    var readableWidth: CGFloat = .greatestFiniteMagnitude {
        didSet {
            if readableWidth != oldValue {
                setNeedsLayout()
            }
        }
    }

    /// The last text shown, kept to tell new text from the same without
    /// reading a megabyte back out of the view.
    private var shownText: String?
    private var needsScrollToTop = false

    func show(_ newText: String) {
        guard newText != shownText else { return }
        shownText = newText
        text = newText
        needsScrollToTop = true
        setNeedsLayout()
    }

    override func layoutSubviews() {
        let side = max(Self.margin, (bounds.width - readableWidth) / 2 + Self.margin)
        let inset = UIEdgeInsets(top: Self.margin, left: side, bottom: Self.margin, right: side)
        if textContainerInset != inset {
            textContainerInset = inset
        }
        super.layoutSubviews()
        if needsScrollToTop, bounds.width > 0 {
            needsScrollToTop = false
            setContentOffset(CGPoint(x: 0, y: -adjustedContentInset.top), animated: false)
        }
    }
}
