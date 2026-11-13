#if DEBUG || WAYCAR_ADMIN
import SwiftUI

/// Settings › Admin: test controls for Debug and admin TestFlight builds
/// (`AppEnvironment.allowsAdmin`); the App Review build compiles none of it.
/// Today that is the Review Prompt (`docs/design/review-prompt.md`).
struct AdminSettingsView: View {
    let reviewPrompt: ReviewPromptStore
    @State private var requestNote: String?

    var body: some View {
        Form {
            reviewPromptSection(reviewPrompt)
        }
        .navigationTitle("Admin")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func reviewPromptSection(_ store: ReviewPromptStore) -> some View {
        Section {
            Stepper(
                value: Binding(
                    get: { store.state.valueEventCount },
                    set: { store.adjustValueEventsForAdmin(by: $0 - store.state.valueEventCount) }),
                in: 0...1000
            ) {
                LabeledContent(
                    "Value Events",
                    value: "\(store.state.valueEventCount) of \(ReviewPromptPolicy.minimumValueEvents)")
            }
            .accessibilityIdentifier("settings.admin.reviewEvents")
            LabeledContent(
                "Days Used",
                value: "\(store.state.eventDays.count) of \(ReviewPromptPolicy.minimumDistinctDays)")
            LabeledContent(
                "First Event",
                value: store.state.firstEventAt.map { $0.formatted(date: .abbreviated, time: .omitted) }
                    ?? "None")
            LabeledContent(
                "Last Asked",
                value: store.state.lastPromptAt.map {
                    "\($0.formatted(date: .abbreviated, time: .omitted)) (\(store.state.lastPromptedVersion ?? "?"))"
                } ?? "Never")
            LabeledContent("Eligible Now", value: store.shouldPrompt(blocked: false) ? "Yes" : "No")
            Button("Reset Counter") { store.resetCounterForAdmin() }
                .accessibilityIdentifier("settings.admin.reviewResetCounter")
            Button("Reset 120-Day Gap") { store.resetGapForAdmin() }
                .accessibilityIdentifier("settings.admin.reviewResetGap")
            Button("Make Eligible Now") { store.makeEligibleNowForAdmin() }
                .accessibilityIdentifier("settings.admin.reviewEligible")
            Button("Reset Review Prompt") { store.resetForAdmin() }
                .accessibilityIdentifier("settings.admin.reviewReset")
            Button("Request Review Sheet in 5 s") {
                requestNote =
                    store.requestSheetForAdmin() == nil
                    ? "No window is registered to ask, so nothing was requested." : nil
            }
            .accessibilityIdentifier("settings.admin.reviewRequestNow")
            if let requestNote {
                Text(requestNote).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Review Prompt")
        } footer: {
            Text(
                "Test builds only. Once eligible, Apple's rating prompt is requested when an Agent "
                    + "you prompted finishes while you're on the Console or that Agent. Apple decides "
                    + "whether it shows.\n\n"
                    + "Dismiss Settings and stay on the Console; Apple's sheet should appear 5 s "
                    + "after the tap. If nothing appears with In-App Ratings & Reviews on, the "
                    + "device is declining.")
        }
    }
}
#endif
