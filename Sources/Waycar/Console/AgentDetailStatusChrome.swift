import SwiftUI

/// What the status row adds after "Working" for an Agent's progress (#210):
/// "· 3/7" and a short bar for an estimate, the dotted bar alone while
/// pending. Every other status, and an Agent without progress, shows the
/// plain row. Never a percent or time left.
struct AgentStatusRowProgress: Equatable {
    enum Bar: Equatable {
        case none
        case estimate
        case pending
    }

    /// The estimate's label ("3/7", "Exploring"); nil shows none.
    let label: String?
    /// The label recedes to secondary while the estimate is stale.
    let isLabelStale: Bool
    let bar: Bar
    /// The row's single VoiceOver element's value: "Working, 3 of 7 steps
    /// done", or the plain status.
    let spokenValue: String
    /// What the bar draws; nil with `.none`.
    let display: AgentProgressDisplay?

    static func resolve(
        status: AgentStatus, display: AgentProgressDisplay?, spokenProgress: String?
    ) -> AgentStatusRowProgress {
        let plain = status.rawValue.capitalized
        guard status == .working, let display else {
            return AgentStatusRowProgress(
                label: nil, isLabelStale: false, bar: .none, spokenValue: plain, display: nil)
        }
        switch display {
        case .estimate(let progress, let isStale):
            let spoken = spokenProgress.map { "\(plain), \($0)" } ?? plain
            return AgentStatusRowProgress(
                label: progress.label, isLabelStale: isStale, bar: .estimate,
                spokenValue: spoken, display: display)
        case .pending:
            return AgentStatusRowProgress(
                label: nil, isLabelStale: false, bar: .pending, spokenValue: plain, display: display)
        }
    }

    /// The row for `agent` at `now`: what the chrome draws on every tick.
    /// No Agent, or a status other than Working, reads plain.
    static func resolve(
        agent: ConsoleAgent?, status: AgentStatus, at now: Date
    ) -> AgentStatusRowProgress {
        guard status == .working, let agent else {
            return resolve(status: status, display: nil, spokenProgress: nil)
        }
        return resolve(
            status: status, display: agent.progressDisplay(at: now),
            spokenProgress: agent.spokenProgress(at: now))
    }

    /// Nothing beyond the plain status.
    var isPlain: Bool { bar == .none && label == nil }
}

/// Shared Agent Status + Host telemetry caption used by Composer and Direct
/// Input. One presentation keeps accessibility and visual treatment aligned.
/// A shell row passes `.shellTerminal` and reads "● Shell".
///
/// This row's height must never change: it sits in the input chrome's
/// bottom inset, so a taller or shorter row resizes the terminal's PTY and
/// makes the Agent's TUI redraw. `mediaStrip` is height-neutral by
/// construction (see `TerminalMediaStrip`); anything else added here must
/// be too. The progress bar is 3–4 pt, centred inside the text line, and
/// the narrowest variants drop it and then its label rather than wrap.
struct AgentDetailStatusChrome: View {
    let status: AgentStatus
    let hostTelemetry: HostTelemetryPresentation?
    let chromeColorScheme: ColorScheme
    /// The preview bar of files and links from the terminal, before the
    /// Host telemetry; nil shows none.
    var mediaStrip: TerminalMediaStrip? = nil
    /// The Agent whose progress shows after "Working"; nil shows none.
    /// Read at a date so the estimate turns stale without a new read.
    var progressAgent: ConsoleAgent? = nil

    private static let barWidth: CGFloat = 56

    var body: some View {
        // One structure in every state: swapping branches as progress comes
        // and goes would let the old and new rows stack for an animated
        // update, and a taller row resizes the PTY. Re-read every 15 s, the
        // cadence of the card's rail, so the estimate turns stale on time.
        TimelineView(.periodic(from: .now, by: 15)) { context in
            fittingRow(progress: AgentStatusRowProgress.resolve(
                agent: progressAgent, status: status, at: context.date))
        }
        .padding(.horizontal, 16)
        // Thumbnails come and go as their fetches end, outside any
        // transaction; the telemetry slides over with them.
        .animation(.easeOut(duration: 0.2), value: mediaStrip?.visibleIDs)
        .environment(\.colorScheme, chromeColorScheme)
    }

    /// The strip yields first: with too little width for its stack (a
    /// large Dynamic Type size, a narrow screen) the row shows its leading
    /// tile alone rather than wrap, then drops the progress bar, then its
    /// label, so the row's height never depends on either.
    private func fittingRow(progress: AgentStatusRowProgress) -> some View {
        ViewThatFits(in: .horizontal) {
            row(strip: mediaStrip, progress: progress, showsBar: true, showsLabel: true)
            row(strip: mediaStrip?.compact(), progress: progress, showsBar: true, showsLabel: true)
            if !progress.isPlain {
                row(strip: mediaStrip?.compact(), progress: progress, showsBar: false, showsLabel: true)
                row(strip: mediaStrip?.compact(), progress: progress, showsBar: false, showsLabel: false)
            }
        }
    }

    private func row(
        strip: TerminalMediaStrip?, progress: AgentStatusRowProgress,
        showsBar: Bool, showsLabel: Bool
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            statusLabel(progress: progress, showsBar: showsBar, showsLabel: showsLabel)
            Spacer(minLength: 8)
            if let strip {
                strip
            }
            if let hostTelemetry {
                hostTelemetryLabel(hostTelemetry)
            }
        }
    }

    private func statusLabel(
        progress: AgentStatusRowProgress, showsBar: Bool, showsLabel: Bool
    ) -> some View {
        // Centre-aligned: the bar sits on the text's middle while the Text
        // still gives the row its first baseline.
        HStack(spacing: 4) {
            if status == .working {
                SolvingOrbView(size: 10)
                    .accessibilityHidden(true)
            } else {
                Circle()
                    .fill(Color(status.inkUIColor))
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
            statusText(progress: progress, showsLabel: showsLabel)
                .lineLimit(1)
            if showsBar, progress.bar != .none, let display = progress.display {
                AgentProgressRail(display: display, status: status)
                    .frame(width: Self.barWidth)
                    .clipShape(Capsule())
                    .padding(.leading, 2)
            }
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(Color(status.inkUIColor))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status == .shellTerminal ? "Terminal" : "Agent status")
        .accessibilityValue(progress.spokenValue)
    }

    private func statusText(progress: AgentStatusRowProgress, showsLabel: Bool) -> Text {
        let title = Text(status.rawValue.capitalized)
        guard showsLabel, let label = progress.label else { return title }
        let suffix = Text(" · \(label)")
        return progress.isLabelStale
            ? Text("\(title)\(suffix.foregroundStyle(.secondary))")
            : Text("\(title)\(suffix)")
    }

    /// Deliberately quieter than Agent Status: it never changes color with the
    /// value and never animates, so a number that moves on its own cadence
    /// cannot pull attention away from the Agent the user came here for.
    private func hostTelemetryLabel(
        _ telemetry: HostTelemetryPresentation
    ) -> some View {
        Text(telemetry.title)
            .lineLimit(1)
            .font(.caption2)
            .monospacedDigit()
            // One step brighter on dark themes: tertiary gray recedes into a
            // near-black surface faster than it does into a light one.
            .foregroundStyle(
                chromeColorScheme == .dark
                    ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(telemetry.accessibilityLabel)
            .accessibilityValue(telemetry.accessibilityValue)
    }
}
