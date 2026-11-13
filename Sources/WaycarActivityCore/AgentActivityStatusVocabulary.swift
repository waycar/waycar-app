import Foundation

// MARK: - Status vocabulary

/// One symbol and one word per wire status, shared by every presentation:
/// the Live Activity, CarPlay, the voice script, and the watch app.
enum AgentActivityStatusVocabulary {
    /// The SF Symbol for a wire status; unknown statuses get a plain dot.
    static func symbol(for status: String) -> String {
        switch status {
        case "blocked": "hand.raised.fill"
        case "done": "checkmark.circle.fill"
        case "working": "progress.indicator"
        case "idle": "moon.zzz.fill"
        default: "circle.fill"
        }
    }

    /// "Blocked", "Done", "Working", "Idle"; any other wire status is shown
    /// capitalized as sent.
    static func word(for status: String) -> String {
        status.capitalized
    }
}
