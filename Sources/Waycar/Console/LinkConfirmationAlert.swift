import SwiftUI
import UIKit

/// A link awaiting the go-ahead, and where its confirmation says it leads:
/// the web link's scheme, host, and address, or the Host path a Preview
/// reads (``TerminalLinkTarget/confirmationDetail(workingDirectory:homeDirectory:)``).
struct PendingLinkConfirmation: Equatable {
    let target: TerminalLinkTarget
    let destination: String

    /// Preview the path that was displayed, not a relative reference that
    /// could resolve elsewhere after the pane changes directory.
    var confirmedTarget: TerminalLinkTarget {
        guard case .file(let file) = target, destination.hasPrefix("/") else { return target }
        return .file(TerminalFileReference(path: destination, line: file.line, column: file.column))
    }
}

extension View {
    /// Asks before opening a link whose destination the screen did not
    /// show faithfully — one tapped in the terminal, or any link in a
    /// Markdown File Preview — naming where it leads. Preview or Open
    /// clears `pending` and hands the target to `open`; Copy puts the link
    /// on the pasteboard. A plain `.alert` with its Cancel tinted, not
    /// `quietCancelAlert`, whose quiet anchor would gray Preview and Open
    /// too.
    func linkConfirmationAlert(
        _ pending: Binding<PendingLinkConfirmation?>,
        open: @escaping (TerminalLinkTarget) -> Void
    ) -> some View {
        let title = pending.wrappedValue?.target.isFile == true ? "Preview This Host File?" : "Open This Link?"
        return alert(
            title,
            isPresented: Binding(
                get: { pending.wrappedValue != nil },
                set: { if !$0 { pending.wrappedValue = nil } }),
            presenting: pending.wrappedValue
        ) { confirmation in
            Button(confirmation.target.isFile ? "Preview" : "Open") {
                pending.wrappedValue = nil
                open(confirmation.confirmedTarget)
            }
            Button("Copy") { UIPasteboard.general.string = confirmation.target.copyableText }
            Button("Cancel", role: .cancel) {}
                .tint(Brand.Colors.quietAction)
        } message: { confirmation in
            Text(confirmation.destination)
        }
    }
}
