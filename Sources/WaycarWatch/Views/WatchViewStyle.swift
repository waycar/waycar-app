import SwiftUI
import WatchKit

// MARK: - Layout

/// Size-class metrics from the design spec book
/// (docs/design/apple-watch-v0.md §3.1, §3.3). The Small column is the 40mm
/// canvas, the Large column the 49mm one.
@MainActor
enum WatchLayout {
    /// Whether this watch takes the Large column. §3.1 maps 41mm and 42mm
    /// (at most 223 pt tall) to Small and 44mm and up (224 pt or taller) to
    /// Large; width alone can't split them, since the 42mm screen (187 pt) is
    /// wider than the 44mm one (184 pt).
    static let isLarge = screenSize.height >= 224

    /// The screen in points; fixed for the life of the app.
    static let screenSize = WKInterfaceDevice.current().screenBounds.size

    /// Bottom content inset so the last line clears the floating mic.
    static var micClearance: CGFloat { isLarge ? 64 : 56 }

    /// The recorder's mic disc diameter (W4).
    static var recorderDisc: CGFloat { isLarge ? 76 : 64 }

    /// Vertical rhythm between blocks.
    static var blockSpacing: CGFloat { isLarge ? 8 : 6 }

    /// Capsule button height (Allow, Deny, Try again).
    static var capsuleHeight: CGFloat { isLarge ? 48 : 44 }

    /// Inner padding of a card (the Blocked command card).
    static var cardPadding: CGFloat { isLarge ? 12 : 10 }

    /// Edge margin for content the system doesn't inset (the W1 banner).
    static var edgeMargin: CGFloat { isLarge ? 10 : 8 }

    /// Count pill height.
    static var pillHeight: CGFloat { isLarge ? 24 : 22 }

    /// Count pill horizontal padding.
    static var pillPadding: CGFloat { isLarge ? 9 : 8 }

    /// Gap between count pills.
    static var pillGap: CGFloat { isLarge ? 5 : 4 }

    /// Leading inset that caps the You-bubble at 86% of the screen width.
    static var bubbleLeadingInset: CGFloat { screenSize.width * 0.14 }
}

// MARK: - Formatting

/// The watch's compact time and age strings.
enum WatchFormat {
    /// Whole minutes from `since` to `now`, never negative.
    static func minutes(since: Date, now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(since) / 60))
    }

    /// "now", "4m", "1h", "2d": the same compact age CarPlay shows.
    static func compactAge(since: Date, now: Date) -> String {
        let minutes = minutes(since: since, now: now)
        switch minutes {
        case 0: return "now"
        case ..<60: return "\(minutes)m"
        case ..<(24 * 60): return "\(minutes / 60)h"
        default: return "\(minutes / (24 * 60))d"
        }
    }

    /// "just now" under a minute, otherwise "3m ago".
    static func ago(since: Date, now: Date) -> String {
        minutes(since: since, now: now) == 0 ? "just now" : "\(compactAge(since: since, now: now)) ago"
    }

    /// The spoken age for VoiceOver: "now", "1 minute ago".
    static func spokenAge(since: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        let seconds = TimeInterval(minutes(since: since, now: now) * 60)
        return formatter.localizedString(fromTimeInterval: -seconds)
    }

    /// "10:10": the clock time on the Sent, Allowed, and Denied stamps.
    static func clock(_ date: Date) -> String {
        date.formatted(Date.FormatStyle().hour(.defaultDigits(amPM: .omitted)).minute(.twoDigits))
    }

    /// "0:06": a recording's length.
    static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }

    /// The title as VoiceOver reads it: the `·` separator is not read.
    static func spokenTitle(_ title: String) -> String {
        title.replacingOccurrences(of: " · ", with: " ")
    }
}

// MARK: - Status glyphs

/// The status glyph name, outlined in Always On (§3.6).
enum WatchStatusGlyph {
    /// The vocabulary symbol; with `outline`, its `.fill` variant is dropped.
    static func name(for status: String, outline: Bool) -> String {
        let name = AgentActivityStatusVocabulary.symbol(for: status)
        let fill = ".fill"
        guard outline, name.hasSuffix(fill) else { return name }
        return String(name.dropLast(fill.count))
    }
}

// MARK: - Type

/// Footnote 2 (§3.2): 12 pt at the Large Dynamic Type default, scaling with
/// the user's text size. SwiftUI has no watch Footnote 2 style.
struct MetaFont: ViewModifier {
    /// Monospaced (SF Mono) instead of SF Compact.
    let monospaced: Bool
    /// Letter spacing in em.
    let trackingEm: CGFloat
    /// The scaled point size.
    @ScaledMetric(relativeTo: .footnote) private var size: CGFloat = 12

    /// Applies the scaled font and tracking.
    func body(content: Content) -> some View {
        content
            .font(.system(size: size, design: monospaced ? .monospaced : .default))
            .tracking(trackingEm * size)
    }
}

extension View {
    /// Footnote 2: meta lines, the banner, the footer, the kicker.
    func metaFont(monospaced: Bool = false, trackingEm: CGFloat = 0) -> some View {
        modifier(MetaFont(monospaced: monospaced, trackingEm: trackingEm))
    }

    /// A capsule glass button (Deny, Try again): Liquid Glass on watchOS 26,
    /// the system bordered platter before it.
    @ViewBuilder
    func glassCapsuleButton() -> some View {
        if #available(watchOS 26.0, *) {
            buttonStyle(.glass).buttonBorderShape(.capsule)
        } else {
            buttonStyle(.bordered).buttonBorderShape(.capsule)
        }
    }

    /// A round glass button (the W2 mic, the W4 ✕): the label keeps its own
    /// color on clear glass, so the accent tint never fills the circle and
    /// hides an accent glyph.
    @ViewBuilder
    func glassCircleButton() -> some View {
        if #available(watchOS 26.0, *) {
            buttonStyle(.glass).buttonBorderShape(.circle)
        } else {
            buttonStyle(.bordered).buttonBorderShape(.circle)
        }
    }

    /// Always On text at 60% (§3.6).
    func alwaysOnDimmed(_ isLuminanceReduced: Bool) -> some View {
        opacity(isLuminanceReduced ? 0.6 : 1)
    }
}

// MARK: - Activity line

/// A short "working on it" line: an animated progress glyph plus copy
/// ("Reading prompt…", "Sending…", "Waiting for reply").
struct WatchActivityLine: View {
    /// The copy after the glyph.
    let text: String
    /// Footnote 2 when true, Footnote 1 otherwise.
    var isMeta = false

    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The glyph and copy on one baseline.
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: "progress.indicator")
                .symbolEffect(.variableColor.iterative, isActive: !isLuminanceReduced && !reduceMotion)
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .modifier(ActivityLineFont(isMeta: isMeta))
        .foregroundStyle(WatchBrand.Colors.text2)
        .accessibilityElement(children: .combine)
    }
}

/// Picks Footnote 1 or Footnote 2 for `WatchActivityLine`.
private struct ActivityLineFont: ViewModifier {
    /// Footnote 2 when true.
    let isMeta: Bool
    /// Applies the chosen style.
    @ViewBuilder
    func body(content: Content) -> some View {
        if isMeta {
            content.metaFont()
        } else {
            content.font(.footnote)
        }
    }
}

// MARK: - Availability

/// Whether an Agent's actions (mic, Allow, Deny, Try again) are enabled:
/// only while the iPhone answers, the Agent is in the Watch State, and its
/// Host is confirmed (§6.3).
enum WatchAvailability {
    /// True when the store can act on `agentID` right now.
    @MainActor
    static func canAct(on agentID: WatchAgentID, in store: WatchStore) -> Bool {
        guard store.isReachable, let state = store.state, store.row(agentID) != nil else { return false }
        return state.hosts.first { $0.id == agentID.hostID }?.condition == .confirmed
    }
}

// MARK: - Load key

/// What W2 and W3 reload on: the Agent's status changing, or the iPhone
/// coming back, so a "not reachable" failure doesn't stick.
struct WatchLoadKey: Hashable {
    /// The Agent's wire status; nil when the Agent isn't in the Watch State.
    let status: String?
    /// Whether the iPhone answers.
    let isReachable: Bool
}
