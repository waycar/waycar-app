import SwiftUI

/// The ways to add a Host. Scan to Pair is the default (ADR 0007); the
/// manual form is the alternative, and the scanner's fallback when the
/// camera can't scan. Duplicate opens the manual form prefilled from an
/// existing Host.
enum HostAddition: Identifiable, Hashable {
    case scan, manual, find
    case duplicate(Host)
    case prefilled(HostDraft)

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
    /// Discovery's sign-in and the scanner can hand off to a form, but only
    /// after the first sheet has finished dismissing.
    @State private var followUp: HostAddition?

    func body(content: Content) -> some View {
        content.sheet(item: $addition, onDismiss: sheetDidDismiss) { method in
            switch method {
            case .scan:
                PairingScanView(catalog: store) { paired in
                    addedHostID = paired.id
                } onAddManually: {
                    followUp = .manual
                }
            case .find:
                FindComputersView(
                    catalog: store,
                    onFollowUp: { followUp = $0 },
                    onAdded: { addedHostID = $0.id })
            case .prefilled(let draft):
                HostFormView(store: store, prefilled: draft, addMethod: .discovered) { saved in
                    addedHostID = saved.id
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
        if let next = followUp {
            followUp = nil
            addition = next
        } else if let id = addedHostID {
            addedHostID = nil
            onAdded(id)
        }
        onDismissed()
    }
}
