import SwiftUI

// MARK: - Status line

/// Row line 2 and the detail status line (§3.5): inline glyph + status word
/// (SF Mono semibold, status ink) + " · progress · age · host" in secondary.
/// Nothing is dropped or truncated: when space runs out the line wraps
/// between segments, and the glyph and status word never break apart.
struct StatusLineView: View {
    /// The raw wire status.
    let status: String
    /// When the iPhone saw the status change; nil omits the age.
    let since: Date?
    /// The Host name, or nil when it isn't shown (one Host).
    let hostName: String?
    /// The clock the age is measured against.
    let now: Date
    /// The Agent's progress (#199); an estimate adds its label ("3/7",
    /// "Verifying") after the status word.
    var progress: AgentProgressDisplay?

    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    /// One wrapping line: glyph and word, then each segment after " · ".
    var body: some View {
        let ink = WatchBrand.Status.ink(for: status)
        let glyph = Text(Image(systemName: WatchStatusGlyph.name(for: status, outline: isLuminanceReduced)))
            .foregroundStyle(ink)
        let word = Text(verbatim: AgentActivityStatusVocabulary.word(for: status))
            .font(.system(.footnote, design: .monospaced, weight: .semibold))
            .foregroundStyle(ink)
        let rest = Text(
            verbatim: Self.trailing(
                label: progress?.watchLabel,
                age: since.map { WatchFormat.compactAge(since: $0, now: now) },
                hostName: hostName)
        )
        .foregroundStyle(WatchBrand.Colors.text2)
        Text("\(glyph)\u{00A0}\(word)\(rest)")
            .font(.footnote)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                Self.spokenLabel(status: status, since: since, hostName: hostName, now: now, progress: progress))
    }

    /// "Working, 3 of 7 steps done, 1 minute ago, studio": one VoiceOver
    /// element, no `·`, never a percent.
    nonisolated static func spokenLabel(
        status: String, since: Date?, hostName: String?, now: Date, progress: AgentProgressDisplay? = nil
    ) -> String {
        [
            AgentActivityStatusVocabulary.word(for: status),
            progress?.watchSpokenLabel,
            since.map { WatchFormat.spokenAge(since: $0, now: now) },
            hostName,
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }

    /// The text after the status word: " · " before each of the progress
    /// label, age and host. The no-break space keeps each "·" on the line
    /// of the segment before it, so a wrap starts a line with a segment.
    nonisolated static func trailing(label: String?, age: String?, hostName: String?) -> String {
        [label, age, hostName].compactMap { $0 }.map { "\u{00A0}· \($0)" }.joined()
    }
}
