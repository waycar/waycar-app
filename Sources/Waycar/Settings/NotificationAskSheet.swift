import SwiftUI

/// The one-time Notification Ask (#71): what turning them on gives, then the same
/// privacy story the pre-permission explainer tells (#76), so the iOS
/// prompt can follow Continue directly. Copy lives in `NotificationAskCopy`.
/// Its buttons are `NotificationAsk.actions`: Continue alone right before
/// the iOS prompt, Turn On and Not Now once iOS allows notifications. Only
/// an answer closes it, and only the first tap answers. No answer is the
/// keyboard default, like the analytics question.
struct NotificationAskSheet: View {
    let actions: [NotificationAsk.Action]
    let onTurnOn: () -> Void
    let onNotNow: () -> Void

    @State private var hasAnswered = false
    @ScaledMetric(relativeTo: .body) private var badgeSize: CGFloat = 36

    /// Keeps lines readable on iPad instead of stretching across the sheet.
    private static let maxContentWidth: CGFloat = 560

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text(NotificationAskCopy.title)
                    .font(Brand.Fonts.display)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                VStack(alignment: .leading, spacing: 18) {
                    benefit(NotificationAskCopy.notificationsBenefit, systemImage: "bell.badge.fill")
                    benefit(
                        NotificationAskCopy.liveActivitiesBenefit,
                        systemImage: "platter.filled.top.iphone")
                }

                VStack(alignment: .leading, spacing: 16) {
                    Text(NotificationAskCopy.privacyTitle)
                        .font(.title3.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    NotificationDisclosureContent()
                    if let privacyURL = NotificationPrivacyCopy.privacyPolicyURL {
                        Link(NotificationPrivacyCopy.privacyDetailsLink, destination: privacyURL)
                            .font(.footnote)
                    }
                }

                Text(NotificationAskCopy.hint(for: actions))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Brand.Spacing.gutterCompact)
            .padding(.top, 36)
            .padding(.bottom, 20)
            .frame(maxWidth: Self.maxContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) { answers }
        .tint(Brand.Colors.accent)
        .interactiveDismissDisabled()
        .presentationSizing(.form)
    }

    private func benefit(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(Brand.Colors.white)
                .frame(width: badgeSize, height: badgeSize)
                .background(
                    Brand.Colors.accent,
                    in: RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous))
                .accessibilityHidden(true)
            Text(text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    /// Pinned under the scrolling story, so every answer stays on screen at
    /// any text size.
    private var answers: some View {
        VStack(spacing: 8) {
            ForEach(actions, id: \.self) { action in
                if action.declines {
                    Button {
                        answer(onNotNow)
                    } label: {
                        actionLabel(action)
                    }
                    .buttonStyle(.borderless)
                    .tint(Brand.Colors.quietAction)
                    .controlSize(.large)
                } else {
                    Button {
                        answer(onTurnOn)
                    } label: {
                        actionLabel(action)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
        }
        .disabled(hasAnswered)
        .padding(.horizontal, Brand.Spacing.gutterCompact)
        .padding(.vertical, 12)
        .frame(maxWidth: Self.maxContentWidth)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private func actionLabel(_ action: NotificationAsk.Action) -> some View {
        Text(action.title)
            .font(Brand.Fonts.buttonLg)
            .frame(maxWidth: .infinity)
    }

    private func answer(_ action: () -> Void) {
        guard !hasAnswered else { return }
        hasAnswered = true
        action()
    }
}

#Preview {
    Color.clear.sheet(isPresented: .constant(true)) {
        NotificationAskSheet(actions: [.continue], onTurnOn: {}, onNotNow: {})
    }
}
