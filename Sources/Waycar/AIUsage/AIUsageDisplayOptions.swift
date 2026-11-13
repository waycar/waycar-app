import Foundation

/// Which rate-limit window(s) the pill — the summary on the Console's AI
/// Usage row — reports.
enum AIUsagePillWindow: String, Codable, CaseIterable, Identifiable, Sendable {
    /// The session window (5 h), else the shortest window.
    case session
    /// The weekly window, else the session window.
    case weekly
    /// Whichever of session and weekly has less left: the limit that binds.
    case automatic
    /// Session then weekly, each with its own number and color.
    case sessionAndWeekly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .session: "Session"
        case .weekly: "Weekly"
        case .automatic: "Automatic"
        case .sessionAndWeekly: "Session + Weekly"
        }
    }
}

/// How reset times read: a countdown or the wall-clock time.
enum AIUsageResetStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case countdown
    case clock

    var id: String { rawValue }

    var title: String {
        switch self {
        case .countdown: "Countdown"
        case .clock: "Clock Time"
        }
    }
}

/// App-wide choices for how AI Usage is displayed, modeled on CodexBar's own
/// display settings. A stored choice outlives a later change of default.
struct AIUsageDisplayOptions: Codable, Equatable, Sendable {
    /// The provider id (`claude`, `codex`) the pill names; nil names the most
    /// urgent provider. A provider missing from the report falls back to the
    /// most urgent one.
    var pillProviderID: String?
    var pillWindow: AIUsagePillWindow = .sessionAndWeekly
    /// Appends the first displayed window's reset to the pill.
    var pillShowsResetTime = false
    /// Percentages and bars show what is used instead of what is left.
    /// Colors still warn on little left.
    var showsUsed = false
    var resetStyle: AIUsageResetStyle = .countdown
    var showsPace = true
    var hidesAccountLabels = false
    /// Opening the sheet refreshes a live source not fetched in the last
    /// `openRefreshThreshold`.
    var refreshesWhenOpened = false

    static let openRefreshThreshold: TimeInterval = 30

    init() {}

    /// Field by field, like `AIUsageHostSettings`: an unreadable field
    /// costs only itself.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AIUsageDisplayOptions()
        pillProviderID = (try? container.decodeIfPresent(String.self, forKey: .pillProviderID)) ?? nil
        pillWindow = (try? container.decodeIfPresent(AIUsagePillWindow.self, forKey: .pillWindow))
            ?? defaults.pillWindow
        pillShowsResetTime = (try? container.decodeIfPresent(
            Bool.self, forKey: .pillShowsResetTime)) ?? defaults.pillShowsResetTime
        showsUsed = (try? container.decodeIfPresent(Bool.self, forKey: .showsUsed))
            ?? defaults.showsUsed
        resetStyle = (try? container.decodeIfPresent(AIUsageResetStyle.self, forKey: .resetStyle))
            ?? defaults.resetStyle
        showsPace = (try? container.decodeIfPresent(Bool.self, forKey: .showsPace))
            ?? defaults.showsPace
        hidesAccountLabels = (try? container.decodeIfPresent(
            Bool.self, forKey: .hidesAccountLabels)) ?? defaults.hidesAccountLabels
        refreshesWhenOpened = (try? container.decodeIfPresent(
            Bool.self, forKey: .refreshesWhenOpened)) ?? defaults.refreshesWhenOpened
    }

    private enum CodingKeys: String, CodingKey {
        case pillProviderID, pillWindow, pillShowsResetTime, showsUsed, resetStyle, showsPace
        case hidesAccountLabels, refreshesWhenOpened
    }
}

/// What the pill shows: one provider and one or two of its windows.
struct AIUsagePillSelection: Sendable, Equatable {
    let provider: AIUsageProvider
    /// Never empty.
    let windows: [AIUsageWindow]
}

extension AIUsageProvider {
    /// The window labelled Weekly or lasting 7 days.
    var weeklyWindow: AIUsageWindow? {
        windows.first(where: \.isWeeklyWindow)
    }

    /// The windows the pill shows for `mode`; empty only without windows.
    func pillWindows(_ mode: AIUsagePillWindow) -> [AIUsageWindow] {
        guard let session = sessionWindow else { return [] }
        switch mode {
        case .session:
            return [session]
        case .weekly:
            return [weeklyWindow ?? session]
        case .automatic:
            guard let weekly = weeklyWindow, weekly.remainingPercent < session.remainingPercent
            else { return [session] }
            return [weekly]
        case .sessionAndWeekly:
            guard let weekly = weeklyWindow, weekly.id != session.id else { return [session] }
            return [session, weekly]
        }
    }
}

extension AIUsageReport {
    /// The pill's provider and windows: the chosen provider when the report
    /// has it with data, else the one whose displayed windows have the least
    /// left. Error-only providers never qualify; ties keep sheet order.
    func pillSelection(_ options: AIUsageDisplayOptions) -> AIUsagePillSelection? {
        let candidates = providers.compactMap { provider -> AIUsagePillSelection? in
            let windows = provider.pillWindows(options.pillWindow)
            return windows.isEmpty ? nil : AIUsagePillSelection(provider: provider, windows: windows)
        }
        if let chosen = options.pillProviderID,
            let match = candidates.first(where: { $0.provider.providerID == chosen })
        {
            return match
        }
        func least(_ selection: AIUsagePillSelection) -> Double {
            selection.windows.map(\.remainingPercent).min() ?? 100
        }
        return candidates.enumerated().min { lhs, rhs in
            let left = least(lhs.element)
            let right = least(rhs.element)
            return left != right ? left < right : lhs.offset < rhs.offset
        }?.element
    }
}

extension AIUsageWindow {
    /// The window labelled Weekly or lasting 7 days.
    var isWeeklyWindow: Bool {
        label.caseInsensitiveCompare("Weekly") == .orderedSame || windowMinutes == 10080
    }

    /// The percentage shown: used or remaining.
    func displayPercent(showsUsed: Bool) -> Double {
        showsUsed ? usedPercent : remainingPercent
    }

    /// Where the pace tick sits on the displayed gauge.
    func displayPacePercent(showsUsed: Bool) -> Double? {
        guard let expected = expectedUsedPercent else { return nil }
        let clamped = AIUsageReport.clampedPercent(expected)
        return showsUsed ? clamped : 100 - clamped
    }
}

extension AIUsageFormat {
    /// "2:27 PM" today, "Tomorrow 2:27 PM", "Mon 2:27 PM" when under six
    /// days away, else "Oct 3".
    static func clockTime(
        _ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        var time = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar)
        time.timeZone = calendar.timeZone
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(time) }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
            calendar.isDate(date, inSameDayAs: tomorrow)
        {
            return "Tomorrow \(date.formatted(time))"
        }
        var style = Date.FormatStyle(locale: locale, calendar: calendar)
        style.timeZone = calendar.timeZone
        if date.timeIntervalSince(now) < 6 * 86_400 {
            return date.formatted(style.weekday(.abbreviated).hour().minute())
        }
        return date.formatted(style.month(.abbreviated).day())
    }

    /// "Resets in 2h 14m" or "Resets 2:27 PM"; nil without a reset time.
    static func resetText(
        _ resetsAt: Date?, now: Date, style: AIUsageResetStyle,
        calendar: Calendar = .current, locale: Locale = .current
    ) -> String? {
        guard let resetsAt else { return nil }
        guard resetsAt > now else { return "Resetting now" }
        switch style {
        case .countdown:
            return "Resets in \(compactDuration(until: resetsAt, now: now))"
        case .clock:
            return "Resets \(clockTime(resetsAt, now: now, calendar: calendar, locale: locale))"
        }
    }

    /// The pill's short reset: "2h 14m" or "2:27 PM".
    static func pillReset(
        _ resetsAt: Date?, now: Date, style: AIUsageResetStyle,
        calendar: Calendar = .current, locale: Locale = .current
    ) -> String? {
        guard let resetsAt else { return nil }
        guard resetsAt > now else { return "now" }
        switch style {
        case .countdown: return compactDuration(until: resetsAt, now: now)
        case .clock: return clockTime(resetsAt, now: now, calendar: calendar, locale: locale)
        }
    }

    /// "Claude 64% · 12% · 2h 14m": Session + Weekly showing both, session
    /// first, or Session, needs no letters. Otherwise the window is unclear
    /// and each number is lettered: "Claude W12%", or "Claude S64%" when
    /// Session + Weekly falls back to one window. The reset is the first
    /// window's.
    static func pillTitle(
        _ selection: AIUsagePillSelection, options: AIUsageDisplayOptions, now: Date,
        calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        let labelsWindows = switch options.pillWindow {
        case .session: false
        case .sessionAndWeekly: selection.windows.count != 2
        case .weekly, .automatic: true
        }
        var parts = selection.windows.map { window in
            let number = percent(window.displayPercent(showsUsed: options.showsUsed))
            guard labelsWindows else { return number }
            let letter = window.id == selection.provider.weeklyWindow?.id ? "W" : "S"
            return letter + number
        }
        if options.pillShowsResetTime,
            let reset = pillReset(
                selection.windows.first?.resetsAt, now: now, style: options.resetStyle,
                calendar: calendar, locale: locale)
        {
            parts.append(reset)
        }
        return "\(selection.provider.displayName) " + parts.joined(separator: " · ")
    }

    /// Ever shorter pill titles for a narrow bar: in full, without the
    /// reset, then only the first window.
    static func pillTitles(
        _ selection: AIUsagePillSelection, options: AIUsageDisplayOptions, now: Date,
        calendar: Calendar = .current, locale: Locale = .current
    ) -> [String] {
        var withoutReset = options
        withoutReset.pillShowsResetTime = false
        let first = AIUsagePillSelection(
            provider: selection.provider, windows: Array(selection.windows.prefix(1)))
        return [
            pillTitle(selection, options: options, now: now, calendar: calendar, locale: locale),
            pillTitle(selection, options: withoutReset, now: now, calendar: calendar, locale: locale),
            pillTitle(first, options: withoutReset, now: now, calendar: calendar, locale: locale),
        ]
    }

    /// "Claude Session, 64 percent remaining, resets in 2 hours; Weekly, 12
    /// percent remaining, …".
    static func pillAccessibilityValue(
        _ selection: AIUsagePillSelection, options: AIUsageDisplayOptions, now: Date,
        calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        selection.windows.enumerated().map { index, window in
            let name = index == 0
                ? "\(selection.provider.displayName) \(window.label)" : window.label
            var parts = [name, spokenPercent(window, showsUsed: options.showsUsed)]
            if let reset = spokenReset(
                window.resetsAt, now: now, style: options.resetStyle,
                calendar: calendar, locale: locale)
            {
                parts.append(reset)
            }
            return parts.joined(separator: ", ")
        }
        .joined(separator: "; ")
    }

    /// "12 percent remaining" or "88 percent used".
    static func spokenPercent(_ window: AIUsageWindow, showsUsed: Bool) -> String {
        let value = Int(window.displayPercent(showsUsed: showsUsed).rounded())
        return "\(value) percent \(showsUsed ? "used" : "remaining")"
    }

    static func spokenReset(
        _ resetsAt: Date?, now: Date, style: AIUsageResetStyle,
        calendar: Calendar = .current, locale: Locale = .current
    ) -> String? {
        switch style {
        case .countdown:
            return spokenReset(resetsAt, now: now)
        case .clock:
            guard let resetsAt else { return nil }
            guard resetsAt > now else { return "resetting now" }
            return "resets \(clockTime(resetsAt, now: now, calendar: calendar, locale: locale))"
        }
    }
}
