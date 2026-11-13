import Foundation

/// What this device has seen of the user's real use of Waycar, for deciding
/// whether Apple's rating prompt may be requested (`ReviewPromptPolicy`).
/// Plain values, local only: nothing here is sent anywhere.
struct ReviewPromptState: Codable, Equatable, Sendable {
    /// Successful phone-side actions that show real use (a Launch, a
    /// delivered Composer message), counted since the first one.
    var valueEventCount = 0
    /// The start of each calendar day on which one happened, oldest first.
    /// Capped at `ReviewPromptPolicy.minimumDistinctDays`: more days change no
    /// answer, so more are not kept.
    var eventDays: [Date] = []
    var firstEventAt: Date?
    var lastPromptAt: Date?
    /// The marketing version (`CFBundleShortVersionString`) that last asked.
    var lastPromptedVersion: String?

    /// Counts one value event at `now`.
    mutating func recordValueEvent(at now: Date, calendar: Calendar) {
        valueEventCount += 1
        if firstEventAt == nil { firstEventAt = now }
        let day = calendar.startOfDay(for: now)
        if eventDays.count < ReviewPromptPolicy.minimumDistinctDays,
            !eventDays.contains(where: { calendar.isDate($0, inSameDayAs: day) })
        {
            eventDays.append(day)
        }
    }

    /// Notes that the system prompt was requested at `now` by `version`, and
    /// starts the count again: every ask needs fresh use, so the thresholds
    /// gate each ask, not just the first. Events after this count toward the
    /// next ask only.
    mutating func recordPrompt(at now: Date, version: String) {
        lastPromptAt = now
        lastPromptedVersion = version
        valueEventCount = 0
        eventDays = []
        firstEventAt = nil
    }
}

/// When Waycar may ask Apple's system rating prompt to appear. A pure
/// decision over `ReviewPromptState`: the caller supplies the clock, so every
/// boundary is testable.
///
/// The prompt is never tied to any reward, and nothing here knows whether a
/// review was written (StoreKit never says). It is only ever the system's own
/// sheet (`docs/design/review-prompt.md`).
struct ReviewPromptPolicy: Equatable, Sendable {
    /// Value events needed (since the last ask, if any) before each ask.
    static let minimumValueEvents = 15
    /// Distinct calendar days those events must fall on.
    static let minimumDistinctDays = 3
    /// Days that must have passed since the first value event.
    static let minimumDaysSinceFirstEvent = 7
    /// Days between two asks, whatever the version.
    static let minimumDaysBetweenPrompts = 120
    /// How long after an Agent finished a turn the user sent it the moment
    /// stays positive; later, the turn is stale and nothing is asked.
    static let positiveMomentWindow: TimeInterval = 10 * 60

    /// How long the moment must hold before the ask is made, so a screen
    /// the user is still reading is left alone.
    static let positiveMomentSettle: Duration = .seconds(2)

    /// How often a blocked ask re-checks while the moment lasts, since a
    /// sheet closing is not an event SwiftUI reports.
    static let positiveMomentRetryInterval: Duration = .seconds(2)

    /// Every rule must hold. `blocked` is the caller's word that the user is
    /// in the way of something: an Agent waiting on them, any sheet or error
    /// showing.
    func isEligible(
        _ state: ReviewPromptState,
        marketingVersion: String,
        blocked: Bool,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        guard !blocked else { return false }
        guard state.valueEventCount >= Self.minimumValueEvents else { return false }
        guard state.eventDays.count >= Self.minimumDistinctDays else { return false }
        guard let first = state.firstEventAt,
            let matured = calendar.date(
                byAdding: .day, value: Self.minimumDaysSinceFirstEvent, to: first),
            now >= matured
        else { return false }
        guard state.lastPromptedVersion != marketingVersion else { return false }
        if let last = state.lastPromptAt {
            guard let reopens = calendar.date(
                byAdding: .day, value: Self.minimumDaysBetweenPrompts, to: last),
                now >= reopens
            else { return false }
        }
        return true
    }
}
