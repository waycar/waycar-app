import SwiftUI

/// The one color rule for AI Usage, shared by the AI Usage sheet and the
/// Console's summary row and card.
///
/// - Gauges are always colored by what is left: green, amber, red.
/// - Numbers are colored only once they warn (low or critical); a normal
///   number reads in the primary color, so color draws the eye only where
///   it matters.
extension AIUsageLevel {
    /// Fuel-gauge colors: green with room to spare, amber under 25 %, red
    /// under 10 %.
    var color: Color {
        switch self {
        case .normal: .green
        case .low: .orange
        case .critical: .red
        }
    }

    /// A number's color: primary while there is room to spare, the gauge's
    /// warning color once it runs low.
    var numberColor: Color {
        self == .normal ? .primary : color
    }
}

/// A fuel gauge, drawn the same in the AI Usage sheet and the Console card:
/// the empty track, what is shown over it, and the pace tick where usage
/// should be by now. Hidden from VoiceOver on its own; callers label it.
struct AIUsageGaugeBar: View {
    /// 0...100.
    let percent: Double
    let pace: Double?
    let color: Color
    var barHeight: CGFloat = 6

    private var tickHeight: CGFloat { barHeight + 8 }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                    .frame(height: barHeight)
                Capsule()
                    .fill(color)
                    .frame(width: width * min(max(percent, 0), 100) / 100, height: barHeight)
                if let pace {
                    Capsule()
                        .fill(Color.primary.opacity(0.7))
                        .frame(width: 2, height: tickHeight)
                        .offset(x: min(max(width * pace / 100 - 1, 0), max(width - 2, 0)))
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: tickHeight)
    }
}
