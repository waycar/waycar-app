import Foundation
import Observation
import SwiftUI

/// The app's AI summaries setting: whether each Host's `waycar` plugin may
/// send an Agent's screen text to its own model for an Agent Summary
/// (`CONTEXT.md`), and whether Agent cards show them. Off by default; the
/// setting is written into every Host's `notify.json` as `summary_enabled`.
///
/// `choice` stays nil until the user picks, and nil reads as off: only an
/// explicit `true` (stored after the opt-in confirmation) turns it on. Both
/// answers to the confirmation are stored, so it is asked at most once.
@MainActor
@Observable
final class AgentSummarySettings {
    static let defaultsKey = "agent-summaries-enabled"

    /// The user's explicit choice; nil until the first one.
    private(set) var choice: Bool?

    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        choice = defaults.object(forKey: Self.defaultsKey) as? Bool
    }

    var isEnabled: Bool { choice ?? false }

    /// No answer yet: the first time the user turns on a Host's
    /// notifications, Waycar asks.
    var needsChoice: Bool { choice == nil }

    func setEnabled(_ enabled: Bool) {
        choice = enabled
        defaults.set(enabled, forKey: Self.defaultsKey)
    }

    /// Re-reads the choice after iCloud Sync changed it (ADR 0019).
    /// Assigning only on a difference keeps observers from re-applying it.
    func reload() {
        let stored = defaults.object(forKey: Self.defaultsKey) as? Bool
        if stored != choice { choice = stored }
    }
}

extension View {
    /// The AI Summaries opt-in: "Turn On" stores true, "Not Now" stores
    /// false. The unsolicited ask after turning on a Host's notifications
    /// is not repeated once either is stored; the Settings switch always
    /// confirms before turning on. Neither answer is styled as the default,
    /// so nothing is preselected.
    func agentSummariesConfirmation(
        isPresented: Binding<Bool>, settings: AgentSummarySettings
    ) -> some View {
        alert(NotificationPrivacyCopy.agentSummariesConfirmTitle, isPresented: isPresented) {
            Button(NotificationPrivacyCopy.agentSummariesConfirm) {
                settings.setEnabled(true)
            }
            Button(NotificationPrivacyCopy.agentSummariesCancel) {
                settings.setEnabled(false)
            }
            .tint(Brand.Colors.quietAction)
        } message: {
            Text(NotificationPrivacyCopy.agentSummariesConfirmMessage)
        }
    }
}
