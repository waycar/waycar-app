import CoreGraphics
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// A value-typed drop or paste payload. The views adapt `Transferable`
/// values and pasteboard items into these cases; the Composer store is the
/// only place that mutates the draft or starts staging.
enum ComposerDropItem: Equatable, Sendable {
    case text(String)
    case image(Data, suggestedName: String?)
    /// A pasted file's copy under `ComposerTray.localCopiesDirectory`. The
    /// store owns it from here and deletes it if the tray has no room.
    case file(URL)
    case unsupported

    static func textDrop(_ text: String) -> ComposerDropItem {
        text.isEmpty ? .unsupported : .text(text)
    }

    static func imageDrop(_ data: Data, suggestedName: String?) -> ComposerDropItem {
        data.isEmpty ? .unsupported : .image(data, suggestedName: suggestedName)
    }
}

/// Targeted-state chrome for the Composer card. Matches the existing idle
/// hairline; a drop hover uses the accent tint the tools keyboard already
/// uses for the selected tab.
struct ComposerDropHighlight: Equatable, Sendable {
    var isTargeted: Bool

    var strokeWidth: CGFloat { isTargeted ? 2 : 1 }
    var fillOpacity: Double { isTargeted ? 0.08 : 0 }
    var usesAccentStroke: Bool { isTargeted }
}

/// Import-only `Transferable` adapter for Notes/Files text and Photos/Files
/// images. Mapping stays here so `AgentComposerView` only forwards items.
struct ComposerDropTransfer: Transferable, Equatable, Sendable {
    let item: ComposerDropItem

    init(_ item: ComposerDropItem) {
        self.item = item
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let url = received.file
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            let data = try Data(contentsOf: url)
            return ComposerDropTransfer(.imageDrop(data, suggestedName: url.lastPathComponent))
        }
        DataRepresentation(importedContentType: .image) { data in
            ComposerDropTransfer(.imageDrop(data, suggestedName: nil))
        }
        DataRepresentation(importedContentType: .utf8PlainText) { data in
            ComposerDropTransfer(.textDrop(String(decoding: data, as: UTF8.self)))
        }
        DataRepresentation(importedContentType: .plainText) { data in
            ComposerDropTransfer(.textDrop(String(decoding: data, as: UTF8.self)))
        }
        ProxyRepresentation(importing: { (text: String) in
            ComposerDropTransfer(.textDrop(text))
        })
    }
}

extension View {
    /// Drop is a no-op when `isEnabled` is false (Direct Input / shell).
    func composerDropDestination(
        isEnabled: Bool,
        isTargeted: Binding<Bool>,
        accept: @escaping ([ComposerDropItem]) -> Void
    ) -> some View {
        modifier(
            ComposerDropDestinationModifier(
                isEnabled: isEnabled,
                isTargeted: isTargeted,
                accept: accept))
    }
}

private struct ComposerDropDestinationModifier: ViewModifier {
    let isEnabled: Bool
    @Binding var isTargeted: Bool
    let accept: ([ComposerDropItem]) -> Void

    func body(content: Content) -> some View {
        if isEnabled {
            content.dropDestination(for: ComposerDropTransfer.self) { transfers, _ in
                accept(transfers.map(\.item))
                return true
            } isTargeted: { targeted in
                isTargeted = targeted
            }
        } else {
            content
        }
    }
}
