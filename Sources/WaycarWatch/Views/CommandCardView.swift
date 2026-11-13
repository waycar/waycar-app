import SwiftUI

// MARK: - Command card

/// The W3 command card: the full command in SF Mono, never truncated,
/// wrapped at the character level at the column limit. Continuation lines
/// get a dim `arrow.turn.down.right` in a fixed-width leading gutter column;
/// the command sits in its own column, so the marker never overlaps a
/// character and is not part of the command. Blocked wash at 15% with a
/// 1 pt Blocked ink border at 40%.
struct CommandCardView: View {
    /// The lossless command text.
    let command: String

    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    /// The width the card's lines get, gutter included, measured.
    @State private var textWidth: CGFloat = 0
    /// One SF Mono column, measured.
    @State private var glyphWidth: CGFloat = 0
    /// The gutter column's width, scaling with the marker's text size.
    @ScaledMetric(relativeTo: .caption2) private var gutterWidth: CGFloat = 14

    /// The command's font (Footnote 1, SF Mono).
    private static let font = Font.system(.footnote, design: .monospaced)
    /// How many glyphs the column measurement averages.
    private static let sampleLength = 20
    /// The status whose colors the card wears.
    private static let status = "blocked"

    /// The card.
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: WatchBrand.Radii.card, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Self.lines(for: command, columns: columns)) { line in
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    gutter(isContinuation: line.isContinuation)
                    Text(verbatim: line.text)
                        .font(Self.font)
                        .foregroundStyle(WatchBrand.Colors.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
        .background(alignment: .topLeading) {
            Text(verbatim: String(repeating: "0", count: Self.sampleLength))
                .font(Self.font)
                .fixedSize()
                .hidden()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                    glyphWidth = $0 / CGFloat(Self.sampleLength)
                }
        }
        .padding(WatchLayout.cardPadding)
        .background {
            shape.fill(WatchBrand.Status.wash(for: Self.status).opacity(isLuminanceReduced ? 0 : 0.15))
        }
        .overlay {
            shape.strokeBorder(WatchBrand.Status.ink(for: Self.status).opacity(0.4), lineWidth: 1)
        }
        .privacySensitive()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: command))
    }

    /// The fixed-width leading column: the continuation marker, or empty
    /// space so every line's command text starts at the same x.
    private func gutter(isContinuation: Bool) -> some View {
        Image(systemName: "arrow.turn.down.right")
            .font(.caption2)
            .foregroundStyle(WatchBrand.Colors.text2)
            .opacity(isContinuation ? 0.6 : 0)
            .frame(width: gutterWidth, alignment: .leading)
            .accessibilityHidden(true)
    }

    /// Columns per line once measured; nil lets `Text` wrap on its own.
    private var columns: Int? {
        guard glyphWidth > 0, textWidth > gutterWidth else { return nil }
        // Half a point of slack so rounding never pushes a full line into a
        // second, unmarked visual line.
        let usable = textWidth - gutterWidth - 0.5
        return max(1, Int((usable / glyphWidth).rounded(.down)))
    }

    /// One drawn line of the command.
    struct Line: Identifiable, Equatable {
        /// Position in the card.
        let id: Int
        /// The characters on this line.
        let text: String
        /// Whether it continues the line above (gets the marker).
        let isContinuation: Bool
    }

    /// Splits `command` at its own newlines, then every `columns`
    /// characters. Every character lands on exactly one line, in order.
    static func lines(for command: String, columns: Int?) -> [Line] {
        var lines: [Line] = []
        for segment in command.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            guard let columns, segment.count > columns else {
                lines.append(Line(id: lines.count, text: String(segment), isContinuation: false))
                continue
            }
            var start = segment.startIndex
            while start < segment.endIndex {
                let end = segment.index(start, offsetBy: columns, limitedBy: segment.endIndex) ?? segment.endIndex
                lines.append(
                    Line(id: lines.count, text: String(segment[start..<end]), isContinuation: start != segment.startIndex))
                start = end
            }
        }
        return lines
    }
}
