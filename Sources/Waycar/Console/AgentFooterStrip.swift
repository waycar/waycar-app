import SwiftUI

/// The Agent Footer's lines as text: what the Agent screen draws under the
/// Toolbar and the Settings preview shows. Middle truncation keeps both ends
/// of a path or a long name readable.
struct AgentFooterStrip: View {
    let lines: [String]
    let pointSize: CGFloat

    var body: some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .font(.system(size: pointSize, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Agent footer: \(lines.joined(separator: ", "))")
        }
    }
}

/// The Agent Footer in the band between the Toolbar capsule and the screen's
/// bottom edge. The Agent screen lays it over the terminal rather than
/// insetting it, so the terminal — and its PTY — never resize for it.
struct AgentFooterBand: View {
    let layout: AgentFooterLayout
    let context: AgentFooterContext
    /// From ``lineCap(isCompactHeight:height:)``; the top strip's moved
    /// figures use the same cap.
    let maximumLines: Int
    let height: CGFloat
    @State private var width: CGFloat = 0

    /// The Toolbar capsule's bottom padding in `AgentInputChrome`: the part
    /// of the band above the bottom safe area.
    static let capsuleBottomGap: CGFloat = 6
    /// The capsule's horizontal padding plus its items' leading inset: the
    /// least side inset, used until the band's width is known.
    static let horizontalInset: CGFloat = 12 + InputChromeLayout.toolbarLeadingInset
    /// Each side keeps this share of the width clear, so on a portrait iPhone
    /// the text stays off the display's rounded bottom corners.
    static let sideInsetFraction: CGFloat = 0.08
    /// Landscape iPhone already sits inside its side safe areas and iPad's
    /// corners are small, so wider bands get no more than a portrait iPhone.
    static let sideInsetCap: CGFloat = 36
    /// iPad draws its keyboard and dictation buttons over the bottom-trailing
    /// corner; the footer stops short of them.
    static let padTrailingReserve: CGFloat = 120
    static let padTrailingReserveFraction: CGFloat = 0.2

    /// The capsule rests on the bottom safe area, so the band is that inset
    /// plus the capsule's own bottom padding.
    static func height(bottomSafeAreaInset: CGFloat) -> CGFloat {
        bottomSafeAreaInset + capsuleBottomGap
    }

    /// Landscape iPhone keeps one line; a band too short for a legible line
    /// (no home indicator) shows none, so no usage figure moves into it.
    /// `nonisolated`: pure, and called off the main actor (AGENTS.md, Conventions).
    nonisolated static func lineCap(isCompactHeight: Bool, height: CGFloat) -> Int {
        AgentFooterLayout.fittingLineCount(
            isCompactHeight ? 1 : AgentFooterLayout.maximumLines, availableHeight: height)
    }

    /// Whether the footer is configured to show every figure the top usage
    /// strip could: by configuration alone, not by the values known yet or the
    /// token-rate toggle, so the strip's reserved row never flips at runtime.
    /// `nonisolated`: pure, and called off the main actor (AGENTS.md, Conventions).
    nonisolated static func takesAllUsage(layout: AgentFooterLayout, maximumLines: Int) -> Bool {
        guard layout.isEnabled else { return false }
        let configured = Set(layout.shownLines(maximumLines: maximumLines).joined())
        let usage = Set(AgentFooterField.offered.filter(\.isUsage))
        return usage.isSubset(of: configured)
    }

    var body: some View {
        let lines = AgentFooterRenderer.render(
            layout: layout, context: context, maximumLines: maximumLines)
        // Sized by configured lines, so the text never jumps as values arrive.
        let lineCount = max(1, layout.shownLines(maximumLines: maximumLines).count)
        let pointSize = AgentFooterLayout.fittedPointSize(
            nominal: AgentFooterLayout.pointSize(layout.textSize, lineCount: lineCount),
            lineCount: lineCount,
            availableHeight: height)
        AgentFooterStrip(lines: lines, pointSize: pointSize)
            .padding(.leading, sideInset)
            .padding(.trailing, trailingInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .frame(height: height)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { newWidth in
                width = newWidth
            }
    }

    private var sideInset: CGFloat {
        max(Self.horizontalInset, min(Self.sideInsetFraction * width, Self.sideInsetCap))
    }

    private var trailingInset: CGFloat {
        guard AgentToolbarDeviceKind.current == .pad else { return sideInset }
        return max(Self.padTrailingReserve, Self.padTrailingReserveFraction * width)
    }
}
