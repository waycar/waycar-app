import Foundation
import Observation

/// The app's Hide Back Button setting: whether an Agent's screen shows the
/// ‹ at its top left on iPhone. Shown by default; hiding it leaves the swipe
/// from the left edge as the way back.
///
/// Unset reads as shown: only an explicit `true` hides it.
@MainActor
@Observable
final class AgentBackButtonSettings {
    static let defaultsKey = "agent-back-button-hidden"

    private(set) var isHidden: Bool

    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isHidden = defaults.bool(forKey: Self.defaultsKey)
    }

    func setHidden(_ hidden: Bool) {
        if hidden != isHidden { isHidden = hidden }
        defaults.set(hidden, forKey: Self.defaultsKey)
    }

    /// Re-reads the setting after iCloud Sync changed it (ADR 0019).
    /// Assigning only on a difference keeps observers from re-applying it.
    func reload() {
        let stored = defaults.bool(forKey: Self.defaultsKey)
        if stored != isHidden { isHidden = stored }
    }
}
