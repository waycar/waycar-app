import SwiftUI

/// The caboose from the app icon, without its square ground, so it can sit on
/// any branded surface. Drawn from the icon's own geometry (1024-unit space,
/// `scripts/generate-app-icons.py`) rather than a bitmap so it stays crisp at
/// every size and can light its cupola window.
///
/// The window breathes with a slow glow; with Reduce Motion on it holds a
/// steady, softer glow instead. Purely decorative, so hidden from VoiceOver.
struct WaycarCabooseMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let glow = reduceMotion ? 0.5 : CabooseDrawing.glow(at: timeline.date)
            Canvas { context, size in
                CabooseDrawing.draw(in: &context, size: size, glow: glow)
            }
        }
        .aspectRatio(CabooseDrawing.viewBox.width / CabooseDrawing.viewBox.height, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// Geometry lifted verbatim from the `caboose` mark in
/// `scripts/generate-app-icons.py`, in SVG units.
private enum CabooseDrawing {
    /// The caboose's bounds plus a little air for the window glow, rather
    /// than the 1024 square, which would waste the margins the icon needs
    /// but a free-standing mark does not.
    static let viewBox = CGRect(x: 104, y: 206, width: 816, height: 608)

    /// Seconds for one full breath of the window glow.
    private static let glowPeriod = 3.2

    /// 0...1 window intensity for `date`, a slow sine so it never snaps.
    static func glow(at date: Date) -> Double {
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: glowPeriod) / glowPeriod
        return 0.5 + 0.5 * sin(phase * 2 * .pi)
    }

    static func draw(in context: inout GraphicsContext, size: CGSize, glow: Double) {
        let scale = min(size.width / viewBox.width, size.height / viewBox.height)
        guard scale > 0 else { return }
        // Aspect-fit: scale SVG units to points, then center the view box.
        let transform = CGAffineTransform(
            translationX: (size.width - viewBox.width * scale) / 2 - viewBox.minX * scale,
            y: (size.height - viewBox.height * scale) / 2 - viewBox.minY * scale)
            .scaledBy(x: scale, y: scale)

        context.fill(
            roundedRect(x: 120, y: 778, width: 784, height: 20, radius: 10).applying(transform),
            with: .color(Brand.Colors.markSurface))

        // The car. The icon cuts its prompt and wheel hubs through to the
        // ground; with no ground of our own, punch them out of the car's
        // layer so the mark works on any surface.
        context.drawLayer { car in
            for shape in carShapes {
                car.fill(shape.applying(transform), with: .color(Brand.Colors.markAccent))
            }
            car.blendMode = .destinationOut
            for hub in [circle(360, 716, 20), circle(664, 716, 20)] {
                car.fill(hub.applying(transform), with: .color(.black))
            }
            car.stroke(
                prompt.applying(transform), with: .color(.black),
                style: StrokeStyle(lineWidth: 38 * 1.15 * scale, lineCap: .round, lineJoin: .round))
        }

        // The cupola window, brightening and throwing a soft halo as it glows.
        context.drawLayer { lit in
            lit.addFilter(.shadow(
                color: Brand.Colors.markHighlight.opacity(0.2 + 0.4 * glow),
                radius: 36 * scale))
            let light = Brand.Colors.markHighlight.mix(with: Brand.Colors.markAccent, by: 0.25 * (1 - glow))
            lit.fill(
                roundedRect(x: 452, y: 278, width: 120, height: 60, radius: 16).applying(transform),
                with: .color(light))
        }
    }

    /// Filled one at a time rather than merged: overlapping subpaths with
    /// opposite windings would cancel under the non-zero rule.
    private static var carShapes: [Path] {
        [
            roundedRect(x: 392, y: 236, width: 240, height: 150, radius: 28),  // cupola
            roundedRect(x: 196, y: 352, width: 632, height: 36, radius: 18),  // roof
            roundedRect(x: 232, y: 370, width: 560, height: 330, radius: 44),  // body
            circle(360, 716, 58), circle(664, 716, 58),
        ]
    }

    /// `>_` centred on (512, 540) at 1.15×: `M-100 -62 L-30 0 L-100 62` and
    /// `M20 62 L110 62`.
    private static var prompt: Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { point(512 + x * 1.15, 540 + y * 1.15) }
        var path = Path()
        path.move(to: p(-100, -62))
        path.addLine(to: p(-30, 0))
        path.addLine(to: p(-100, 62))
        path.move(to: p(20, 62))
        path.addLine(to: p(110, 62))
        return path
    }

    private static func roundedRect(
        x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, radius: CGFloat
    ) -> Path {
        Path(
            roundedRect: CGRect(x: x, y: y, width: width, height: height),
            cornerRadius: radius, style: .circular)
    }

    private static func circle(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
    }

    private static func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: x, y: y)
    }
}

#Preview {
    WaycarCabooseMark()
        .frame(height: 160)
        .padding()
        .background(Brand.Colors.markGround)
}
