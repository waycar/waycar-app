import Foundation

/// Prefills the New Agent sheet for a launch that hands the agent a document
/// (Help's Ask an Agent, the Keychain Fix). The user still reviews and taps Start.
struct AgentLaunchPreset: Equatable, Sendable {
    /// Sheet title, e.g. "Ask an Agent", "Fix AI Usage".
    var title: String
    /// Preselected Host; nil keeps the sheet's usual default.
    var hostID: Host.ID?
    /// Shows the Host picker disabled (the Keychain Fix targets one Host).
    var locksHost: Bool = false
    /// Suggested agent name; the store normalizes it like typed input.
    var suggestedName: String?
    /// Read-only label for what the agent is given, e.g. "Help: mosh".
    var attachmentTitle: String
    /// Contents of the Launch Prompt File the agent is told to read and follow.
    var firstMessage: String
}
