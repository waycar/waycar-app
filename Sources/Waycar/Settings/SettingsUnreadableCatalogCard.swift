import SwiftUI

/// A synced catalog that can't be decoded: announced before any edit, with its
/// one way out. Mirrors the Agent List Fields error card (`AgentLayoutErrorView`).
struct SettingsUnreadableCatalogCard: View {
    let title: String
    let message: String
    let resetTitle: String
    let confirmTitle: String
    let confirmMessage: String
    /// Prefix of the card's accessibility identifiers, e.g. `settings.toolbars`.
    let identifierPrefix: String
    let reset: () -> Void

    @State private var confirming = false

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                }
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("\(identifierPrefix).unreadable")
                Button(resetTitle, role: .destructive) { confirming = true }
                    .buttonStyle(.bordered)
                    .font(.subheadline.weight(.medium))
                    .padding(.top, 4)
                    .accessibilityIdentifier("\(identifierPrefix).resetUnreadable")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .quietCancelDialog(confirmTitle, isPresented: $confirming, titleVisibility: .visible) {
                Button(resetTitle, role: .destructive, action: reset)
                Button("Cancel", role: .cancel) {}.tint(Brand.Colors.quietAction)
            } message: {
                Text(confirmMessage)
            }
        }
    }
}

/// A settings screen's last refused edit, shown above its controls.
struct SettingsErrorSection: View {
    let message: String
    let identifier: String

    var body: some View {
        Section {
            Label {
                Text(verbatim: message).font(.footnote)
            } icon: {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            }
            .accessibilityIdentifier(identifier)
        }
    }
}
