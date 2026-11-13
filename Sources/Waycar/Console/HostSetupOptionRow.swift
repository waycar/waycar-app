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

struct FindComputersSetupRow: View {
    let action: () -> Void

    var body: some View {
        HostSetupOptionRow(
            title: "Find Computers", subtitle: "On this Wi-Fi, with SSH on",
            symbol: "wifi", action: action)
            .accessibilityIdentifier("setup.find-computers")
    }
}
