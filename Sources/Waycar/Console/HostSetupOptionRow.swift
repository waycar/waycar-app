import SwiftUI

/// A quiet second choice under the scan, such as the Sample: tinted text with
/// a short line under it, no card, so the scan stays the one primary action.
struct HostSetupOptionRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Label(title, systemImage: symbol)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.accentColor)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityElement(children: .combine)
    }
}

/// The first thing a new user sees: an offer to look for their computers,
/// in the middle of the screen. Scan opens Find Computers, whose browse
/// brings up the Local Network prompt. It is the screen's primary action,
/// not a pre-permission alert, and it stays until a Host exists, so a user
/// who declined iOS's prompt can come back to it.
struct FindComputersSetupCard: View {
    let scan: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi")
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text("Waycar looks on this Wi-Fi for computers with SSH on.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: scan) {
                Text("Scan Computers on My Network")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("setup.find-computers")
        }
        .frame(maxWidth: .infinity)
    }
}
