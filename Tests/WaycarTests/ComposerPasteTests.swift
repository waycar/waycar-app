import Foundation
import Testing
import UIKit
import UniformTypeIdentifiers

@testable import Waycar

@MainActor
@Suite("Composer paste")
struct ComposerPasteTests {
    @Test func pasteboardItemsMapToWhatTheComposerTakes() {
        let cases: [(types: [UTType], expected: ComposerPasteContent?)] = [
            // A copied screenshot.
            ([.png], .image(.png)),
            // Safari's Copy on an image also carries its address.
            ([.jpeg, .url], .image(.jpeg)),
            ([.png, .html], .image(.png)),
            // Text with an image preview (spreadsheet cells) stays text, as
            // UIKit pasted it.
            ([.png, .utf8PlainText], .text(.utf8PlainText)),
            ([.html, .utf8PlainText], .text(.utf8PlainText)),
            ([.html], .text(.html)),
            ([.url], .text(.url)),
            // Files' Copy on a document.
            ([.pdf, .fileURL], .file(.pdf)),
            ([.zip], .file(.zip)),
            ([.fileURL], nil),
        ]
        for (types, expected) in cases {
            #expect(
                ComposerPasteContent(types: types) == expected,
                "types: \(types.map(\.identifier))")
        }
    }

    @Test func pastedFileNamesKeepTheirNameAndGainAnExtension() {
        #expect(ComposerPasteContent.fileName(suggested: "report.pdf", type: .pdf) == "report.pdf")
        #expect(ComposerPasteContent.fileName(suggested: "report", type: .pdf) == "report.pdf")
        #expect(ComposerPasteContent.fileName(suggested: "a/../b.zip", type: .zip) == "b.zip")
        #expect(ComposerPasteContent.fileName(suggested: nil, type: .pdf) == "Pasted.pdf")
        #expect(ComposerPasteContent.fileName(suggested: " ", type: .pdf) == "Pasted.pdf")
    }

    @Test func pastingAScreenshotHandsTheImageToTheComposer() throws {
        let png = try Self.tinyPNGData()
        let paste = Paste(items: [[UTType.png.identifier: png]])
        defer { paste.end() }

        #expect(paste.textView.canPerformAction(Self.pasteAction, withSender: nil))
        paste.textView.paste(nil)

        guard case .image(let data, _)? = paste.received?.first, paste.received?.count == 1 else {
            Issue.record("expected one image, got \(String(describing: paste.received))")
            return
        }
        #expect(data == png)
        #expect(paste.textView.text.isEmpty)
    }

    @Test func pastingADocumentHandsALocalCopyToTheComposer() throws {
        let pdf = Data("%PDF-1.4 pasted".utf8)
        let paste = Paste(items: [[UTType.pdf.identifier: pdf]])
        defer { paste.end() }

        paste.textView.paste(nil)

        guard case .file(let url)? = paste.received?.first, paste.received?.count == 1 else {
            Issue.record("expected one file, got \(String(describing: paste.received))")
            return
        }
        defer { ComposerTray.discardLocalCopy(.file(url)) }
        #expect(url.lastPathComponent == "Pasted.pdf")
        #expect(
            url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path
                == ComposerTray.localCopiesDirectory.standardizedFileURL.path)
        #expect(try Data(contentsOf: url) == pdf)
    }

    @Test func textAndLinksBesideAnImageKeepClipboardOrder() throws {
        let png = try Self.tinyPNGData()
        let link = try #require(URL(string: "https://waycar.dev/help"))
        let paste = Paste(items: [
            [UTType.utf8PlainText.identifier: "see this "],
            [UTType.url.identifier: link],
            [UTType.png.identifier: png],
        ])
        defer { paste.end() }

        paste.textView.paste(nil)

        #expect(paste.received.map { Array($0.prefix(2)) } == [.text("see this "), .text(link.absoluteString)])
        guard case .image(let data, _)? = paste.received?.last, paste.received?.count == 3 else {
            Issue.record("expected two texts then one image, got \(String(describing: paste.received))")
            return
        }
        #expect(data == png)
    }

    @Test func aTextOnlyClipboardLeavesPasteToUIKit() {
        let paste = Paste(items: [[UTType.utf8PlainText.identifier: "plain"]])
        defer { paste.end() }

        #expect(ComposerPasteContent.items(on: paste.pasteboard) == nil)
    }

    @Test func anUnreadableAttachmentLeavesPasteToUIKit() {
        let paste = Paste(items: [[UTType.png.identifier: Data()]])
        defer { paste.end() }

        #expect(ComposerPasteContent.contents(of: paste.pasteboard) == [.image(.png)])
        #expect(ComposerPasteContent.items(on: paste.pasteboard) == nil)
    }

    @Test func aReadOnlyTextViewOffersNoPaste() throws {
        let paste = Paste(items: [[UTType.png.identifier: try Self.tinyPNGData()]])
        defer { paste.end() }
        paste.textView.isEditable = false

        #expect(!paste.textView.canPerformAction(Self.pasteAction, withSender: nil))
    }

    private static let pasteAction = #selector(UIResponderStandardEditActions.paste(_:))

    private static func tinyPNGData() throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        let image = renderer.image { context in
            UIColor.systemRed.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        return try #require(image.pngData())
    }
}

/// A Composer text view reading a private pasteboard that holds `items`.
@MainActor
private final class Paste {
    let pasteboard = UIPasteboard.withUniqueName()
    let textView = ComposerPasteTextView()
    private(set) var received: [ComposerDropItem]?

    init(items: [[String: Any]]) {
        pasteboard.setItems(items)
        textView.pasteboard = pasteboard
        textView.onPasteAttachments = { [unowned self] in received = $0 }
    }

    func end() {
        UIPasteboard.remove(withName: pasteboard.name)
    }
}
