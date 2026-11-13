import SwiftUI

/// Agent Progress along a Console card's bottom edge (#189): a 3 pt rail,
/// 4 pt under Increase Contrast. An estimate fills from the leading edge in
/// the status ink over a faint track of the same hue, at 40 % while stale;
/// Blocked is the same rail in blue, held still. `.pending` (Working, no
/// estimate yet) is a still dotted line with no fill: a bar is coming, not
/// a measurement. Decorative: `AgentStatusLabel` speaks the estimate.
struct AgentProgressRail: View {
    let display: AgentProgressDisplay
    let status: AgentStatus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// On iPad the list stays mounted under the Agent screen; nothing there
    /// should tween.
    @Environment(\.consoleListIsCovered) private var isCovered
    @Environment(\.colorSchemeContrast) private var contrast

    private var thickness: CGFloat { contrast == .increased ? 4 : 3 }

    var body: some View {
        Group {
            switch display {
            case .estimate(let progress, let isStale):
                Rectangle()
                    .fill(Color(status.tintUIColor).opacity(contrast == .increased ? 0.30 : 0.18))
                    .overlay {
                        // Full width scaled from the leading edge: no
                        // GeometryReader, and the tween is a cheap transform.
                        Rectangle()
                            .fill(Color(status.inkUIColor))
                            .opacity(isStale ? 0.4 : 1)
                            .scaleEffect(x: progress.fraction, anchor: .leading)
                            .flipsForRightToLeftLayoutDirection(true)
                            .animation(
                                reduceMotion || isCovered ? nil : .easeOut(duration: 0.35),
                                value: progress.fraction)
                    }
            case .pending:
                AgentProgressRailLine()
                    .stroke(
                        Color(status.inkUIColor).opacity(0.45),
                        style: StrokeStyle(lineWidth: thickness, dash: [2, 5]))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: thickness)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// The rail's centre line, edge to edge, for the dotted pending stroke.
private struct AgentProgressRailLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

/// `AgentCardChrome`'s bottom edge for one Agent: the rail clipped to the
/// card's corners, inset inside whatever outline is drawn over the card
/// (the selection ring, Selection Mode's checked outline). Re-read every
/// 15 s so the switch to stale keeps up without a new read, the cadence
/// of the summary line. Nothing at all when the Agent shows no progress:
/// only a status change brings one, and that redraws the card.
struct AgentCardProgressEdge: View {
    let agent: ConsoleAgent
    let shape: RoundedRectangle
    let inset: CGFloat

    var body: some View {
        if agent.progressDisplay(at: .now) != nil {
            TimelineView(.periodic(from: .now, by: 15)) { context in
                if let display = agent.progressDisplay(at: context.date) {
                    AgentProgressRail(display: display, status: agent.agent.status)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(inset)
            .clipShape(shape.inset(by: inset))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
