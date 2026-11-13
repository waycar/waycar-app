import ImageIO
import UIKit
import UniformTypeIdentifiers

/// What one pasteboard item gives the Composer, read from its registered
/// types, highest fidelity first. An item carrying plain text pastes as text,
/// as UIKit always pasted it, even with an image preview beside it; an image
/// ImageIO decodes joins the Composer Tray as an image; a link or rich text
/// pastes as text; any other typed file joins the tray as a file. Nil:
/// nothing the Composer takes.
enum ComposerPasteContent: Equatable, Sendable {
    case image(UTType)
    /// The representation a mixed paste reads the text from.
    case text(UTType)
    case file(UTType)

    init?(types: [UTType]) {
        if let plainText = types.first(where: { $0.conforms(to: .plainText) }) {
            self = .text(plainText)
        } else if let image = types.first(where: {
            $0.conforms(to: .image) && Self.decodableImageTypes.contains($0.identifier)
        }) {
            self = .image(image)
        } else if let text = types.first(where: {
            $0.conforms(to: .text) || ($0.conforms(to: .url) && !$0.conforms(to: .fileURL))
        }) {
            self = .text(text)
        } else if let file = types.first(where: {
            $0.conforms(to: .data) && !$0.conforms(to: .url)
                && $0.preferredFilenameExtension != nil
        }) {
            self = .file(file)
        } else {
            return nil
        }
    }

    var isAttachment: Bool {
        if case .text = self { false } else { true }
    }

    /// Each item's content, from type names alone. Those never raise the
    /// system's paste notice, so the edit menu can ask this freely.
    static func contents(of pasteboard: UIPasteboard) -> [ComposerPasteContent?] {
        (pasteboard.types(forItemSet: nil) ?? []).map { identifiers in
            ComposerPasteContent(types: identifiers.compactMap { UTType($0) })
        }
    }

    /// Reads every item, in order, into what the draft and tray accept, or
    /// nil when no item would join the tray or none can be read: UIKit pastes
    /// that as text. An unreadable item maps to `.unsupported`, which they
    /// skip.
    // ponytail: synchronous reads, as UITextView's own paste does, so a very
    // large file stalls the main thread while it copies; load the items'
    // NSItemProvider file representations off the main thread if that bites.
    @MainActor
    static func items(on pasteboard: UIPasteboard) -> [ComposerDropItem]? {
        let contents = contents(of: pasteboard)
        guard contents.contains(where: { $0?.isAttachment == true }) else { return nil }
        let names = pasteboard.itemProviders.map(\.suggestedName)
        let items = contents.enumerated().map { index, content -> ComposerDropItem in
            let item = IndexSet(integer: index)
            let suggestedName = names.indices.contains(index) ? names[index] : nil
            func read(_ type: UTType) -> Data? {
                pasteboard.data(forPasteboardType: type.identifier, inItemSet: item)?.first
            }
            switch content {
            case .image(let type):
                return read(type).map { .imageDrop($0, suggestedName: suggestedName) } ?? .unsupported
            case .text(let type):
                let value = pasteboard.values(forPasteboardType: type.identifier, inItemSet: item)?.first
                let text = (value as? String) ?? (value as? URL)?.absoluteString
                return text.map(ComposerDropItem.textDrop) ?? .unsupported
            case .file(let type):
                let name = fileName(suggested: suggestedName, type: type)
                guard let data = read(type), !data.isEmpty,
                    let copy = try? ComposerTray.makeLocalCopy(
                        named: name, write: { try data.write(to: $0) })
                else { return .unsupported }
                return .file(copy)
            case nil:
                return .unsupported
            }
        }
        return items.contains(where: { $0 != .unsupported }) ? items : nil
    }

    /// The suggested name, given `type`'s extension when it has none;
    /// "Pasted" when the source named nothing usable.
    static func fileName(suggested: String?, type: UTType) -> String {
        let base = (suggested.map { ($0 as NSString).lastPathComponent } ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = ["", "/", ".", ".."].contains(base) ? "Pasted" : base
        guard (name as NSString).pathExtension.isEmpty,
            let fileExtension = type.preferredFilenameExtension
        else { return name }
        return "\(name).\(fileExtension)"
    }

    private static let decodableImageTypes =
        Set(CGImageSourceCopyTypeIdentifiers() as? [String] ?? [])
}

/// A draft text view whose Paste also takes images and files: when the
/// clipboard holds any, they go to `onPasteAttachments` (the Composer Tray)
/// along with any text items, in clipboard order. A text-only clipboard, or
/// one whose items can't be read, pastes as UIKit always does.
class ComposerPasteTextView: UITextView {
    var onPasteAttachments: (@MainActor ([ComposerDropItem]) -> Void)?
    /// Tests use a named pasteboard. UIKit's own text paste always reads the
    /// general one.
    var pasteboard: UIPasteboard = .general

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), isEditable, onPasteAttachments != nil,
            ComposerPasteContent.contents(of: pasteboard).contains(where: { $0?.isAttachment == true })
        {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        guard let onPasteAttachments, isEditable,
            let items = ComposerPasteContent.items(on: pasteboard)
        else { return super.paste(sender) }
        onPasteAttachments(items)
    }
}
