import SwiftUI

// MARK: - Bar

/// Agent Progress under a row's status line and the W2 title: a 3 pt
/// capsule filling left to right in the status ink over a faint track of
/// the same hue, the fill at 40% once stale. Pending (Working, no estimate
/// yet) is a still dotted line: a bar is coming, not a measurement. Blocked
/// holds still. Decorative: the status line speaks the estimate.
struct WatchProgressBar: View {
    /// What to draw.
    let display: AgentProgressDisplay
    /// The raw wire status, for the colour.
    let status: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    /// The bar's height.
    static let thickness: CGFloat = 3
    /// The fill's opacity once the estimate is stale.
    static let staleFillOpacity = 0.4

    /// The filled capsule or the dotted line, full width.
    var body: some View {
        Group {
            switch display {
            case .estimate(let progress, let isStale):
                let fraction = min(max(progress.fraction, 0), 1)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(WatchBrand.Status.wash(for: status).opacity(0.18))
                        Capsule()
                            .fill(WatchBrand.Status.ink(for: status))
                            .opacity(isStale ? Self.staleFillOpacity : 1)
                            .frame(width: proxy.size.width * fraction)
                    }
                }
                .animation(isAnimated ? .easeOut(duration: 0.35) : nil, value: fraction)
            case .pending:
                WatchProgressBarLine()
                    .stroke(
                        WatchBrand.Status.ink(for: status).opacity(0.45),
                        style: StrokeStyle(lineWidth: Self.thickness, dash: [2, 5]))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.thickness)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    /// The fill tweens only with Reduce Motion off, outside Always On, and
    /// never for a Blocked Agent's frozen estimate.
    private var isAnimated: Bool {
        !reduceMotion && !isLuminanceReduced && status != "blocked"
    }
}

/// The bar's centre line, edge to edge, for the dotted pending stroke.
private struct WatchProgressBarLine: Shape {
    /// One horizontal line through the middle of `rect`.
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}
