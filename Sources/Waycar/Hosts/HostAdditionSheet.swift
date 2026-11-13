import SwiftUI

/// The ways to add a Host. Scan to Pair is the default (ADR 0007); the
/// manual form is the alternative, and the scanner's fallback when the
/// camera can't scan. Duplicate opens the manual form prefilled from an
/// existing Host.
enum HostAddition: Identifiable, Hashable {
    case scan, manual
    case duplicate(Host)

    var id: Self { self }
}

/// Presents a `HostAddition` and hands the saved Host to `onAdded` only once
/// its sheet has fully dismissed. What follows is the Host's page (its
/// onboarding preflight, session discovery included), which may at once ask
/// to trust the host key, and an alert or sheet requested while a sheet is
/// still animating away is silently dropped.
struct HostAdditionSheet: ViewModifier {
    let store: HostStore
    @Binding var addition: HostAddition?
    let onAdded: (Host.ID) -> Void
    /// Runs after every dismissal, once the sheet is fully gone.
    var onDismissed: () -> Void = {}
    @State private var addedHostID: Host.ID?
    /// The scanner's Add Manually: the form follows once the scanner is gone,
    /// so the two sheets never overlap.
    @State private var fallsBackToManual = false

    func body(content: Content) -> some View {
        content.sheet(item: $addition, onDismiss: sheetDidDismiss) { method in
            switch method {
            case .scan:
                PairingScanView(catalog: store) { paired in
                    addedHostID = paired.id
                } onAddManually: {
                    fallsBackToManual = true
                }
            case .manual:
                HostFormView(store: store) { saved in
                    addedHostID = saved.id
                }
            case .duplicate(let source):
                HostFormView(store: store, duplicating: source) { saved in
                    addedHostID = saved.id
                }
            }
        }
    }

    private func sheetDidDismiss() {
        if fallsBackToManual {
            fallsBackToManual = false
            addition = .manual
        } else if let id = addedHostID {
            addedHostID = nil
            onAdded(id)
        }
        onDismissed()
    }
}
