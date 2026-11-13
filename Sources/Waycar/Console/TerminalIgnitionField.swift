import SwiftUI
import UIKit

/// Ghostty's cell grid in the loader's coordinates.
struct TerminalIgnitionGrid: Equatable {
    var origin: CGPoint
    var cell: CGSize
    var columns: Int
    var rows: Int

    /// Ghostty sizes its font and padding in pixels at 96 per inch, so a
    /// point size draws 96/72 as large.
    private static let pixelScale: CGFloat = 96 / 72

    // ponytail: SF Mono metrics at the terminal's font size and Ghostty's
    // default padding, for the frames before the surface measures its grid
    // (a cold open measures before it attaches, so this barely shows);
    // ceiling: a custom terminal font's cell differs by a few points;
    // upgrade: read the font family's metrics if that ever shows.
    static func approximateCell(fontSize: CGFloat) -> CGSize {
        let font = UIFont.monospacedSystemFont(
            ofSize: max(fontSize, 6) * pixelScale, weight: .regular)
        return CGSize(
            width: ("M" as NSString).size(withAttributes: [.font: font]).width,
            height: font.lineHeight)
    }

    static func approximate(in size: CGSize, cell: CGSize) -> TerminalIgnitionGrid {
        let padding: CGFloat = 2 * pixelScale
        guard cell.width > 0, cell.height > 0 else {
            return TerminalIgnitionGrid(origin: .zero, cell: .zero, columns: 0, rows: 0)
        }
        return TerminalIgnitionGrid(
            origin: CGPoint(x: padding, y: padding),
            cell: cell,
            columns: max(1, Int((size.width - 2 * padding) / cell.width)),
            rows: max(1, Int((size.height - 2 * padding) / cell.height)))
    }

    var isDrawable: Bool { cell.width > 0 && cell.height > 0 && columns > 0 && rows > 0 }

    var dotRadius: CGFloat { max(0.75, min(cell.width, cell.height) * 0.09) }

    func rowCenter(_ row: Int) -> CGFloat { origin.y + (CGFloat(row) + 0.5) * cell.height }

    func columnCenter(_ column: Int) -> CGFloat { origin.x + (CGFloat(column) + 0.5) * cell.width }

    /// The columns whose centres fall in `minX...maxX`, or nil when none do.
    func columns(from minX: CGFloat, to maxX: CGFloat) -> ClosedRange<Int>? {
        let first = max(0, Int(((minX - origin.x) / cell.width - 0.5).rounded(.up)))
        let last = min(columns - 1, Int(((maxX - origin.x) / cell.width - 0.5).rounded(.down)))
        return first <= last ? first...last : nil
    }

    func dot(at center: CGPoint) -> CGRect {
        let radius = dotRadius
        return CGRect(
            x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }
}

extension WaycarTerminalView {
    /// The grid Ghostty measured, in window coordinates; nil before it has
    /// measured one.
    var ignitionGrid: TerminalIgnitionGrid? {
        guard measuredGrid != nil, window != nil else { return nil }
        let mapper = gridPointMapper
        return TerminalIgnitionGrid(
            origin: convert(mapper.gridOrigin, to: nil),
            cell: mapper.cellSize, columns: mapper.columns, rows: mapper.rows)
    }

    /// The cursor cell's centre in window coordinates, from the IME caret.
    /// Nil while it still sits in the first cell, where a surface that has
    /// not drawn yet parks it.
    var ignitionCursor: CGPoint? {
        guard measuredGrid != nil, window != nil else { return nil }
        let caret = caretRect(for: endOfDocument)
        let center = CGPoint(x: caret.midX, y: caret.midY)
        guard caret.height > 0, let cell = gridPointMapper.cell(at: center),
            cell.column > 1 || cell.row > 1
        else { return nil }
        return convert(center, to: nil)
    }
}

/// The reveal's expanding circle at one instant.
struct IgnitionWave {
    let origin: CGPoint
    let radius: CGFloat
    /// The glint's strength, fading as the wave reaches the corners.
    let fade: Double

    var rect: CGRect {
        CGRect(x: origin.x - radius, y: origin.y - radius, width: radius * 2, height: radius * 2)
    }

    func covers(_ point: CGPoint) -> Bool {
        let dx = point.x - origin.x
        let dy = point.y - origin.y
        return dx * dx + dy * dy < radius * radius
    }

    /// Everything the reveal has not reached yet: `bounds` less each row's
    /// run of cells whose centres the circle covers.
    func unrevealed(in bounds: CGRect, grid: TerminalIgnitionGrid) -> Path {
        var path = Path(bounds)
        guard grid.isDrawable else { return path }
        let revealSquared = radius * radius
        for row in 0..<grid.rows {
            let dy = grid.rowCenter(row) - origin.y
            guard dy * dy < revealSquared else { continue }
            let half = (revealSquared - dy * dy).squareRoot()
            guard let run = grid.columns(from: origin.x - half, to: origin.x + half) else {
                continue
            }
            path.addRect(
                CGRect(
                    x: grid.origin.x + CGFloat(run.lowerBound) * grid.cell.width,
                    y: grid.origin.y + CGFloat(row) * grid.cell.height,
                    width: CGFloat(run.count) * grid.cell.width,
                    height: grid.cell.height))
        }
        return path
    }

    func drawGlint(in context: inout GraphicsContext, color: Color) {
        guard radius > 0, fade > 0 else { return }
        let ring = Path(ellipseIn: rect)
        context.stroke(ring, with: .color(color.opacity(0.15 * fade)), lineWidth: 8)
        context.stroke(ring, with: .color(color.opacity(0.6 * fade)), lineWidth: 1.5)
    }
}

/// The cold curtain at rest: the theme's background with one faint dot per
/// cell. It depends on nothing that moves, so the loader's frame clock
/// never redraws it; the band and the reveal draw over it.
struct IgnitionBaseField: View, Equatable {
    static let dotAlpha = 0.13

    let grid: TerminalIgnitionGrid
    let palette: TerminalThemePalette

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(palette.background))
            guard grid.isDrawable else { return }
            var dots = Path()
            for row in 0..<grid.rows {
                let y = grid.rowCenter(row)
                for column in 0..<grid.columns {
                    dots.addEllipse(in: grid.dot(at: CGPoint(x: grid.columnCenter(column), y: y)))
                }
            }
            context.fill(dots, with: .color(palette.foreground.opacity(Self.dotAlpha)))
        }
    }
}

/// The light band drifting across the dots, drawn every frame. Only the
/// cells near its diagonal are visited, and its dots are bucketed by
/// strength and tint into a few dozen paths.
struct IgnitionBand {
    static let peakAlpha = 0.7
    static let period = 2.4
    static let width = 0.075
    static let levels = 6
    static let tints = 6

    let grid: TerminalIgnitionGrid
    let palette: TerminalThemePalette
    let time: Double
    let wave: IgnitionWave?

    func draw(in context: inout GraphicsContext, size: CGSize) {
        guard grid.isDrawable, size.width > 0, size.height > 0 else { return }
        let diagonal = Double(size.width + size.height)
        let center = -0.25 + 1.5 * (time / Self.period).truncatingRemainder(dividingBy: 1)
        // Where x + y reaches the band's edges, past which a dot is too
        // faint to draw.
        let reach = 2.5 * Self.width
        let low = CGFloat((center - reach) * diagonal)
        let high = CGFloat((center + reach) * diagonal)
        var band = [Path](repeating: Path(), count: Self.levels * Self.tints)
        for row in 0..<grid.rows {
            let y = grid.rowCenter(row)
            guard let run = grid.columns(from: low - y, to: high - y) else { continue }
            for column in run {
                let point = CGPoint(x: grid.columnCenter(column), y: y)
                if let wave, wave.covers(point) { continue }
                let distance = (Double(point.x + y) / diagonal - center) / Self.width
                let strength = exp(-0.5 * distance * distance)
                guard strength >= 0.05 else { continue }
                let level = min(Self.levels - 1, Int(strength * Double(Self.levels)))
                let tint = min(
                    Self.tints - 1, max(0, Int(Double(point.x / size.width) * Double(Self.tints))))
                band[level * Self.tints + tint].addEllipse(in: grid.dot(at: point))
            }
        }
        for level in 0..<Self.levels {
            let strength = (Double(level) + 0.5) / Double(Self.levels)
            for tint in 0..<Self.tints {
                let path = band[level * Self.tints + tint]
                guard !path.isEmpty else { continue }
                let hue = palette.magenta.mix(
                    with: palette.cyan, by: (Double(tint) + 0.5) / Double(Self.tints))
                let color = palette.foreground.mix(with: hue, by: strength)
                    .opacity(Self.peakAlpha * strength)
                context.fill(path, with: .color(color))
            }
        }
    }

    /// The warm sweep: a wide, faint magenta to cyan band across the kept
    /// frame.
    static func drawSweep(
        in context: inout GraphicsContext, size: CGSize, time: Double,
        palette: TerminalThemePalette
    ) {
        let span = size.width + size.height
        let center = (-0.3 + 1.6 * (time / 2.8).truncatingRemainder(dividingBy: 1)) * span
        let half = 0.35 * span / 2
        // Along (1, 1), so the band's edges run on the diagonal x + y = k.
        let start = (center - half) / 2
        let end = (center + half) / 2
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: palette.magenta.opacity(0), location: 0),
                    .init(color: palette.magenta.opacity(0.1), location: 0.35),
                    .init(color: palette.cyan.opacity(0.1), location: 0.65),
                    .init(color: palette.cyan.opacity(0), location: 1),
                ]),
                startPoint: CGPoint(x: start, y: start),
                endPoint: CGPoint(x: end, y: end)))
    }
}
