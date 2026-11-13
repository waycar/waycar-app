import SwiftUI

/// A connected Host's live transport: an accent-violet MOSH once a probe proved mosh,
/// grey SSH while SSH is the backbone, a spinner while a forced re-probe
/// runs. Shown in the Hosts list row and on the Host's details page.
struct MoshTransportBadge: View {
    let state: ConsoleStore.MoshHostCapsuleState

    var body: some View {
        Group {
            switch state {
            case .testing:
                ProgressView()
                    .controlSize(.mini)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
            case .available:
                HostRowBadge(text: "MOSH", tint: Color.accentColor)
            case .unavailable, .untested:
                HostRowBadge(text: "SSH", tint: .secondary, style: .muted)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        switch state {
        case .testing: "Testing mosh"
        case .available: "Connected over mosh"
        case .unavailable: "Connected over SSH, mosh unavailable"
        case .untested: "Connected over SSH"
        }
    }
}
