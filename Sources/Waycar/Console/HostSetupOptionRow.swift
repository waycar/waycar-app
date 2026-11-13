import SwiftUI

/// The quiet, full-width choices above the first-Host setup steps.
struct HostSetupOptionRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: .rect(cornerRadius: Brand.Radius.control))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }
}

/// The first thing a new user sees: an offer to look for their computers.
/// Scan opens Find Computers, whose browse brings up the Local Network
/// prompt. It is a feature card among the other paths on the screen, not a
/// pre-permission alert, and it stays until a Host exists, so a user who
/// declined iOS's prompt can come back to it.
struct FindComputersSetupCard: View {
    let scan: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: "wifi")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text("Waycar looks on this Wi-Fi for computers with SSH on.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Button(action: scan) {
                Text("Scan Computers on My Network")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("setup.find-computers")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: .rect(cornerRadius: Brand.Radius.control))
    }
}
