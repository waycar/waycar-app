import Foundation

/// How often a Host's CodexBar is asked for AI Usage while the app is in the
/// foreground. Each run fetches every enabled provider live (CodexBar has no
/// cache for `usage`), so the choices stop at once a minute.
enum AIUsageRefreshInterval: Int, CaseIterable, Codable, Sendable, Identifiable {
    case oneMinute = 1
    case twoMinutes = 2
    case fiveMinutes = 5
    case fifteenMinutes = 15

    static let `default`: AIUsageRefreshInterval = .fiveMinutes

    var id: Int { rawValue }

    var duration: Duration { .seconds(rawValue * 60) }

    var title: String {
        rawValue == 1 ? "Every minute" : "Every \(rawValue) minutes"
    }
}

/// Polling arithmetic, kept pure so the schedule can be tested without
/// sleeping.
enum AIUsagePollSchedule {
    /// Backoff never waits longer than this, unless the chosen interval is
    /// itself longer.
    static let maximumBackoff: Duration = .seconds(15 * 60)

    /// The interval doubles per consecutive failure, capped at
    /// ``maximumBackoff``; a success resets `consecutiveFailures` to zero.
    static func delay(interval: Duration, consecutiveFailures: Int) -> Duration {
        let cap = max(interval, maximumBackoff)
        var delay = interval
        for _ in 0..<max(consecutiveFailures, 0) {
            delay = delay * 2
            if delay >= cap { return cap }
        }
        return min(delay, cap)
    }

    /// How long until a Host's next fetch: at once for a Host never
    /// fetched, else the (backed-off) interval after its last fetch
    /// finished — measured from the finish, so a slow run never eats into
    /// the pause after it.
    static func delayUntilDue(
        lastFinishedAt: Date?, interval: Duration, consecutiveFailures: Int, now: Date
    ) -> Duration {
        guard let lastFinishedAt else { return .zero }
        let wait = delay(interval: interval, consecutiveFailures: consecutiveFailures)
        return delay(until: lastFinishedAt.addingTimeInterval(wait.timeInterval), now: now)
    }

    /// How long until `due`; zero once it has passed.
    static func delay(until due: Date, now: Date) -> Duration {
        let remaining = due.timeIntervalSince(now)
        return remaining > 0 ? .milliseconds(Int((remaining * 1000).rounded(.up))) : .zero
    }

    /// A `codexbar serve` answers with its last report once that is older
    /// than its 60 s cache and rebuilds in the background. A server report
    /// whose data is older than this when it arrives is asked for once more,
    /// ``serverFollowUpDelay`` later, to pick up the rebuilt one.
    static let serverRebuildAge: TimeInterval = 60
    static let serverFollowUpDelay: TimeInterval = 5

    /// Data older than three intervals is shown as stale.
    static func isStale(fetchedAt: Date, now: Date, interval: Duration) -> Bool {
        now.timeIntervalSince(fetchedAt) > 3 * interval.timeInterval
    }
}

/// Short, relative wording for resets, shared by the sheet, the pill and
/// their accessibility labels.
enum AIUsageFormat {
    /// "2h 14m", "3d 4h", "12m", "<1m".
    static func compactDuration(until date: Date, now: Date) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        guard seconds >= 60 else { return "<1m" }
        let minutes = seconds / 60
        let days = minutes / 1440
        let hours = (minutes % 1440) / 60
        let remainder = minutes % 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return remainder > 0 ? "\(hours)h \(remainder)m" : "\(hours)h" }
        return "\(remainder)m"
    }

    /// Spoken form: "resets in 2 hours 14 minutes".
    static func spokenReset(_ resetsAt: Date?, now: Date) -> String? {
        guard let resetsAt else { return nil }
        guard resetsAt > now else { return "resetting now" }
        let minutes = max(Int(resetsAt.timeIntervalSince(now)) / 60, 1)
        let days = minutes / 1440
        let hours = (minutes % 1440) / 60
        let remainder = minutes % 60
        var parts: [String] = []
        if days > 0 { parts.append(days == 1 ? "1 day" : "\(days) days") }
        if hours > 0 { parts.append(hours == 1 ? "1 hour" : "\(hours) hours") }
        if days == 0, remainder > 0 {
            parts.append(remainder == 1 ? "1 minute" : "\(remainder) minutes")
        }
        return "resets in " + parts.joined(separator: " ")
    }

    static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    /// "Claude Weekly, 12 percent remaining, resets in 2 hours".
    static func accessibilityLabel(
        provider: AIUsageProvider, window: AIUsageWindow, options: AIUsageDisplayOptions,
        now: Date
    ) -> String {
        let name: String
        if !options.hidesAccountLabels, let account = provider.account {
            name = "\(provider.displayName) \(account)"
        } else {
            name = provider.displayName
        }
        var parts = [
            "\(name) \(window.label)",
            spokenPercent(window, showsUsed: options.showsUsed),
        ]
        if options.showsPace, let pace = window.pace {
            if let summary = pace.summary { parts.append(summary) }
            if let outlook = pace.outlook(
                usesSessionWording: window.usesSessionPaceWording, now: now)
            {
                parts.append(outlook)
            }
        }
        if let reset = spokenReset(window.resetsAt, now: now, style: options.resetStyle) {
            parts.append(reset)
        }
        return parts.joined(separator: ", ")
    }
}

extension Duration {
    fileprivate var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
