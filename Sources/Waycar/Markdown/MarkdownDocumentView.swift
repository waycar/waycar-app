import SwiftUI

/// A parsed Markdown file drawn as native views: headings in text styles by
/// level, wrapping prose, lists, quotes, monospaced code and tables. The
/// file comes flattened into rows, and one lazy stack draws only those in
/// view, so a long file opens at once; any row can be scrolled to by id,
/// which is how an `#anchor` link reaches its heading.
///
/// A link inside goes through the environment's `openURL`, which the
/// presenting sheet replaces, so nothing the remote-chosen file links to
/// opens without its say. No image is ever loaded: the parser has already
/// turned each one into placeholder text.
struct MarkdownDocumentView: View {
    let rows: MarkdownDocumentRows
    /// A row to bring to the top; reset to nil once scrolled to.
    @Binding var scrollTarget: MarkdownDocumentRow.ID?
    /// Drawn before the first row, inside the same scroll and readable width.
    var header: AnyView?
    /// Drawn after the last row, inside the same scroll and readable width.
    var footer: AnyView?

    /// The widest the text runs, so lines stay readable in a wide iPad sheet.
    static let readableWidth: CGFloat = 800

    @State private var tableOffsets = MarkdownTableScrollOffsets()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    header
                    ForEach(rows.rows) { row in
                        MarkdownRowView(row: row, tableOffsets: tableOffsets)
                            .id(row.id)
                    }
                    footer
                }
                // Selecting is a long press: a tap on a link still opens it,
                // as in a chat message.
                .textSelection(.enabled)
                .padding(16)
                .frame(maxWidth: Self.readableWidth)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                withAnimation { proxy.scrollTo(target, anchor: .top) }
                scrollTarget = nil
            }
        }
    }
}

/// One row: its content beside the quote bars and list markers of the
/// blocks holding it. A task item's first row is one element to VoiceOver,
/// its checkbox read as the value. The Changelog screen draws its releases'
/// rows with it too, so they read exactly like a help page.
struct MarkdownRowView: View {
    let row: MarkdownDocumentRow
    let tableOffsets: MarkdownTableScrollOffsets

    var body: some View {
        let guttered = MarkdownRowGutters(
            gutters: row.gutters[...], gapDepth: row.sharedGutterCount, gap: gap, content: content)
        if let checkbox = row.checkbox {
            guttered
                .accessibilityElement(children: .combine)
                .accessibilityValue(checkbox == .checked ? "checked" : "unchecked")
        } else {
            guttered
        }
    }

    private var gap: CGFloat {
        switch row.gap {
        case .flush: 0
        case .item: 6
        case .block: 12
        }
    }

    @ViewBuilder
    private var content: some View {
        switch row.content {
        case .heading(let level, let text, _):
            MarkdownHeadingView(level: level, text: text)
        case .paragraph(let text):
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        case .code(let code, let isFirst, let isLast):
            MarkdownCodeChunkView(code: code, isFirst: isFirst, isLast: isLast)
        case .table(let table):
            MarkdownTableView(table: table)
        case .tableRow(let table, let cells, let alignments, let isHeader):
            MarkdownWideTableRowView(
                table: table, cells: cells, alignments: alignments, isHeader: isHeader, offsets: tableOffsets)
        case .thematicBreak:
            Divider()
                .padding(.vertical, 4)
        }
    }
}

/// Wraps a row's content in its gutters, outermost first: a bar for a
/// quote, a marker column for a list item. The gap above the row goes
/// inside the gutters the row above shares, so a quote's bar runs on
/// unbroken from row to row. Nesting is capped by the parser, so the
/// recursion is too.
private struct MarkdownRowGutters<Content: View>: View {
    let gutters: ArraySlice<MarkdownDocumentRow.Gutter>
    /// How many gutters to go before the gap.
    let gapDepth: Int
    let gap: CGFloat
    let content: Content

    @ScaledMetric(relativeTo: .body) private var markerWidth: CGFloat = 20

    var body: some View {
        guttered
            .padding(.top, gapDepth == 0 ? gap : 0)
    }

    @ViewBuilder
    private var guttered: some View {
        if let gutter = gutters.first {
            let inner = MarkdownRowGutters(
                gutters: gutters.dropFirst(), gapDepth: gapDepth - 1, gap: gap, content: content)
            switch gutter {
            case .quote:
                inner
                    .foregroundStyle(.secondary)
                    .padding(.leading, 14)
                    .overlay(alignment: .leading) {
                        // The system hairline color, not the brand's white
                        // one: the sheet follows the app's appearance, and
                        // in light mode a white bar would not show.
                        Rectangle()
                            .fill(.separator)
                            .frame(width: 3)
                            .accessibilityHidden(true)
                    }
            case .listItem(let marker, let widestOrdinal):
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    MarkdownListMarker(marker: marker, widestOrdinal: widestOrdinal)
                        .frame(minWidth: markerWidth, alignment: .trailing)
                    inner
                }
            }
        } else {
            content
        }
    }
}

/// A list item's bullet, number or task checkbox, or on its later rows the
/// empty room one takes.
private struct MarkdownListMarker: View {
    let marker: MarkdownDocumentRow.Marker?
    let widestOrdinal: Int?

    private static let bullets = ["•", "◦", "▪"]

    var body: some View {
        ZStack(alignment: .trailing) {
            // Every row of the list leaves its widest number's room, so an
            // item's later rows, and every item, line up; and gives a row
            // without a marker a baseline to align by.
            Text(verbatim: widestOrdinal.map { "\($0)." } ?? " ")
                .monospacedDigit()
                .hidden()
                .accessibilityHidden(true)
            switch marker {
            case .checkbox(let checkbox):
                // The row reads the state as its value.
                Image(systemName: checkbox == .checked ? "checkmark.square" : "square")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            case .ordinal(let ordinal):
                Text(verbatim: "\(ordinal).")
                    .monospacedDigit()
            case .bullet(let level):
                // VoiceOver would read the glyph aloud before every item.
                Text(verbatim: Self.bullets[min(level, Self.bullets.count - 1)])
                    .accessibilityHidden(true)
            case nil:
                EmptyView()
            }
        }
    }
}

/// A heading: a text style per level, and a heading to VoiceOver at that
/// level, so the rotor walks the file's outline.
private struct MarkdownHeadingView: View {
    let level: Int
    let text: AttributedString

    var body: some View {
        Text(text)
            .font(font)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, level <= 2 ? 8 : 4)
            .accessibilityAddTraits(.isHeader)
            .accessibilityHeading(accessibilityLevel)
    }

    private var font: Font {
        switch level {
        case ...1: Brand.Fonts.title
        case 2: .system(.title2, weight: .semibold)
        case 3: .system(.title3, weight: .semibold)
        case 4: .headline
        case 5: .subheadline.weight(.semibold)
        default: .footnote.weight(.semibold)
        }
    }

    private var accessibilityLevel: AccessibilityHeadingLevel {
        switch level {
        case ...1: .h1
        case 2: .h2
        case 3: .h3
        case 4: .h4
        case 5: .h5
        default: .h6
        }
    }
}

/// One stretch of a fenced or indented code block: plain monospaced text on
/// the terminal's ground, scrolling sideways rather than wrapping. The
/// stretches of a block meet edge to edge, its first and last rounding its
/// ends.
private struct MarkdownCodeChunkView: View {
    let code: String
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(verbatim: code)
                .font(Brand.Fonts.code)
                .foregroundStyle(Brand.Colors.termText)
                .fixedSize(horizontal: true, vertical: true)
                .padding(.horizontal, 12)
                .padding(.top, isFirst ? 12 : 0)
                .padding(.bottom, isLast ? 12 : 0)
        }
        .background(
            Brand.Colors.ink,
            in: UnevenRoundedRectangle(
                topLeadingRadius: isFirst ? Brand.Radius.code : 0,
                bottomLeadingRadius: isLast ? Brand.Radius.code : 0,
                bottomTrailingRadius: isLast ? Brand.Radius.code : 0,
                topTrailingRadius: isFirst ? Brand.Radius.code : 0,
                style: .continuous))
    }
}
