import SwiftUI

/// SwiftUI presents alerts and confirmation dialogs as a `UIAlertController`.
/// These wrappers present from a clear anchor behind the view that carries
/// `Brand.Colors.quietAction` as its SwiftUI tint, so on iOS 26 and earlier
/// the Cancel is gray while the presenting view keeps its violet controls.
/// On iOS 27 the alert controller ignores SwiftUI's `.tint` and draws its
/// Cancel in the AccentColor violet; no public API reaches it. The paired
/// destructive action keeps its red through `role: .destructive`.
///
/// Titles take `some StringProtocol` and display verbatim, like SwiftUI's
/// own `StringProtocol` overloads; the app ships no string catalogs, so the
/// dropped `LocalizedStringKey` lookup is inert today.
///
/// Presentations that mix a non-destructive primary action with the Cancel
/// (Trust, Copy Link, Replace Rows) stay on plain `.alert`/`.confirmationDialog`
/// with a per-button Cancel tint: on iOS 26 and earlier the anchor's quiet
/// SwiftUI tint would also gray their primary.
extension View {
    /// An alert whose only action is the dismissive Cancel/OK.
    func quietCancelAlert(
        _ title: some StringProtocol,
        isPresented: Binding<Bool>,
        @ViewBuilder actions: () -> some View
    ) -> some View {
        quietPresentation { $0.alert(title, isPresented: isPresented, actions: actions) }
    }

    /// An alert with a message whose only action is the dismissive Cancel/OK.
    func quietCancelAlert(
        _ title: some StringProtocol,
        isPresented: Binding<Bool>,
        @ViewBuilder actions: () -> some View,
        @ViewBuilder message: () -> some View
    ) -> some View {
        quietPresentation {
            $0.alert(title, isPresented: isPresented, actions: actions, message: message)
        }
    }

    /// An alert with a message whose only action is the dismissive Cancel/OK,
    /// passing `presenting` data into the actions and message.
    func quietCancelAlert<A>(
        _ title: some StringProtocol,
        isPresented: Binding<Bool>,
        presenting data: A?,
        @ViewBuilder actions: (A) -> some View,
        @ViewBuilder message: (A) -> some View
    ) -> some View {
        quietPresentation {
            $0.alert(title, isPresented: isPresented, presenting: data, actions: actions, message: message)
        }
    }

    /// A confirmation dialog with a message whose primary action is destructive.
    func quietCancelDialog(
        _ title: some StringProtocol,
        isPresented: Binding<Bool>,
        titleVisibility: Visibility = .automatic,
        @ViewBuilder actions: () -> some View,
        @ViewBuilder message: () -> some View
    ) -> some View {
        quietPresentation {
            $0.confirmationDialog(
                title, isPresented: isPresented, titleVisibility: titleVisibility,
                actions: actions, message: message)
        }
    }

    /// A confirmation dialog with a message whose primary action is
    /// destructive, passing `presenting` data into the actions and message.
    func quietCancelDialog<A>(
        _ title: some StringProtocol,
        isPresented: Binding<Bool>,
        titleVisibility: Visibility = .automatic,
        presenting data: A?,
        @ViewBuilder actions: (A) -> some View,
        @ViewBuilder message: (A) -> some View
    ) -> some View {
        quietPresentation {
            $0.confirmationDialog(
                title, isPresented: isPresented, titleVisibility: titleVisibility,
                presenting: data, actions: actions, message: message)
        }
    }

    /// Attaches `present`'s alert or dialog to a quiet anchor behind this view.
    private func quietPresentation(_ present: (QuietAlertAnchor) -> some View) -> some View {
        background { present(QuietAlertAnchor()) }
    }
}

/// The clear anchor a quiet presentation hangs off, carrying the quiet
/// SwiftUI tint.
private struct QuietAlertAnchor: View {
    var body: some View {
        Color.clear.tint(Brand.Colors.quietAction)
    }
}
