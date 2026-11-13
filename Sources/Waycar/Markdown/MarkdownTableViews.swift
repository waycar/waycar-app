import SwiftUI

/// A table small enough to lay out whole: a bold header row, then each row
/// under a divider, every column aligned as the file asks. Too wide for the
/// sheet, it scrolls sideways; a long cell wraps at a column's maximum width
/// rather than running on. A cell a row lacks is drawn empty.
struct MarkdownTableView: View {
    let table: MarkdownTable

    @ScaledMetric(relativeTo: .subheadline) private var maximumColumnWidth: CGFloat = 240

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    ForEach(table.alignments.indices, id: \.self) { column in
                        cell(table.header, column: column)
                            .bold()
                            .gridColumnAlignment(table.alignments[column].horizontalAlignment)
                    }
                }
                ForEach(table.rows.indices, id: \.self) { index in
                    Divider()
                        .gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(table.alignments.indices, id: \.self) { column in
                            cell(table.rows[index], column: column)
                        }
                    }
                }
            }
            .font(.subheadline)
            .padding(.vertical, 4)
        }
    }

    private func cell(_ cells: [AttributedString], column: Int) -> some View {
        MarkdownTableCellLayout(maximumWidth: maximumColumnWidth) {
            Text(cells.indices.contains(column) ? cells[column] : AttributedString())
                .multilineTextAlignment(table.alignments[column].textAlignment)
        }
    }
}

/// One row of a table too big to lay out whole, drawn as the document
/// scrolls to it: every column the same width, so the rows line up without
/// measuring one another. The table's rows scroll sideways together — the
/// one the user moves leads, the rest follow the table's offset in
/// `offsets`.
struct MarkdownWideTableRowView: View {
    let table: MarkdownBlock.ID
    let cells: [AttributedString]
    let alignments: [MarkdownTable.Alignment]
    let isHeader: Bool
    let offsets: MarkdownTableScrollOffsets

    @ScaledMetric(relativeTo: .subheadline) private var columnWidth: CGFloat = 160
    @State private var position = ScrollPosition(x: 0)
    /// The user is moving this row, so it leads rather than follows.
    @State private var isScrolledByUser = false

    var body: some View {
        // Only this table's rows watch its offset.
        let offset = offsets.offset(of: table)
        VStack(alignment: .leading, spacing: 8) {
            if !isHeader {
                Divider()
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(alignments.indices, id: \.self) { column in
                        Text(cells.indices.contains(column) ? cells[column] : AttributedString())
                            .bold(isHeader)
                            .multilineTextAlignment(alignments[column].textAlignment)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: columnWidth, alignment: alignments[column].frameAlignment)
                    }
                }
                .font(.subheadline)
            }
            .scrollPosition($position)
            .onScrollPhaseChange { _, phase, context in
                let leads = phase == .tracking || phase == .interacting || phase == .decelerating
                // The last move can land after the user lets go: where the
                // row settles is where the others end.
                if isScrolledByUser, !leads {
                    offset.x = context.geometry.contentOffset.x
                }
                isScrolledByUser = leads
            }
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x }) { _, x in
                guard isScrolledByUser else { return }
                offset.x = x
            }
            .onChange(of: offset.x) { _, x in
                follow(x)
            }
            .onAppear { follow(offset.x) }
        }
        .padding(.top, isHeader ? 4 : 8)
    }

    private func follow(_ x: CGFloat) {
        guard !isScrolledByUser else { return }
        position.scrollTo(x: x)
    }
}

/// The sideways offset of each wide table on a page, by table id: its rows
/// come and go as the page scrolls, so none of them can hold it. Not itself
/// observed — each table's offset is, so moving one table stirs only its
/// own rows.
@MainActor
final class MarkdownTableScrollOffsets {
    private var offsets: [MarkdownBlock.ID: MarkdownTableScrollOffset] = [:]

    /// `table`'s offset, made the first time a row of it asks.
    func offset(of table: MarkdownBlock.ID) -> MarkdownTableScrollOffset {
        if let offset = offsets[table] {
            return offset
        }
        let offset = MarkdownTableScrollOffset()
        offsets[table] = offset
        return offset
    }
}

/// How far one wide table is scrolled sideways.
@MainActor
@Observable
final class MarkdownTableScrollOffset {
    var x: CGFloat = 0
}

/// Lays a table cell out no wider than `maximumWidth`, wrapping it there
/// even when offered unlimited width, as a sideways-scrolling table offers
/// it; narrower text keeps its own width, so a short column stays narrow.
private struct MarkdownTableCellLayout: Layout {
    let maximumWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let cell = subviews.first else { return .zero }
        let width = min(proposal.width ?? maximumWidth, maximumWidth)
        return cell.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: bounds.origin,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

private extension MarkdownTable.Alignment {
    var horizontalAlignment: HorizontalAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    var frameAlignment: Alignment {
        switch self {
        case .leading: .topLeading
        case .center: .top
        case .trailing: .topTrailing
        }
    }

    var textAlignment: TextAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}
