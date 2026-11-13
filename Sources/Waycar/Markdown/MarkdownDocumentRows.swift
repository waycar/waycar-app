import Foundation

/// A `MarkdownDocument` flattened into the rows one lazy stack draws (#147).
/// A file may run to a megabyte, and only the rows on screen should be laid
/// out: so every list item, every block inside a quote, every stretch of a
/// long paragraph or code block and every row of a big table is a row of its
/// own, carrying the quote bars and list markers drawn beside it.
struct MarkdownDocumentRows: Equatable, Sendable {
    let rows: [MarkdownDocumentRow]

    /// A code block is cut into rows of at most this many lines…
    static let codeChunkLineLimit = 100
    /// …and this many characters. A longer line is broken across lines: no
    /// view could lay it out whole.
    static let codeChunkCharacterLimit = 8_192
    /// A paragraph or heading longer than this many characters is cut into
    /// rows, at a space where there is one.
    static let textChunkCharacterLimit = 4_096
    /// A table is one grid, each column as wide as its widest cell, only
    /// when it is cheap to lay out whole: at most this many columns…
    static let gridColumnLimit = 16
    /// …this many cells, the header's included…
    static let gridCellLimit = 800
    /// …and no cell longer than this many characters. A bigger table is a
    /// row per table row, every column the same width.
    static let gridCellCharacterLimit = 512
    /// A cell of a table drawn row by row shows at most this many
    /// characters and an ellipsis; the raw text still shows all of it.
    static let tableCellCharacterLimit = 4_096

    /// Flattens `document`. Once the task is cancelled it stops, keeping the
    /// rows so far.
    init(_ document: MarkdownDocument) {
        var builder = Builder()
        builder.append(document.blocks)
        rows = builder.rows
    }

    /// Id of the row holding the heading whose anchor is `anchor`, however
    /// deep in lists and quotes; nil when no heading matches.
    func rowID(forAnchor anchor: String) -> MarkdownDocumentRow.ID? {
        rows.first { row in
            guard case .heading(_, _, let headingAnchor) = row.content else { return false }
            return headingAnchor == anchor
        }?.id
    }

    static func usesGrid(_ table: MarkdownTable) -> Bool {
        let columns = table.alignments.count
        guard columns <= gridColumnLimit, (table.rows.count + 1) * columns <= gridCellLimit else { return false }
        let isShort = { (cell: AttributedString) in cell.characters.count <= gridCellCharacterLimit }
        return table.header.allSatisfy(isShort) && table.rows.allSatisfy { $0.allSatisfy(isShort) }
    }

    /// `cell` cut to its first `tableCellCharacterLimit` characters, with an
    /// ellipsis after, when it is longer; otherwise `cell` itself.
    static func displayedTableCell(_ cell: AttributedString) -> AttributedString {
        let characters = cell.characters
        guard
            let end = characters.index(
                characters.startIndex, offsetBy: tableCellCharacterLimit, limitedBy: characters.endIndex),
            end < characters.endIndex
        else { return cell }
        var cut = AttributedString(cell[characters.startIndex..<end])
        cut.append(AttributedString("…"))
        return cut
    }

    /// `code` in chunks of at most `codeChunkLineLimit` lines and
    /// `codeChunkCharacterLimit` characters; never empty. Joined by newlines
    /// they give back every line, an overlong one broken where it was cut.
    static func codeChunks(_ code: String) -> [String] {
        var chunks: [String] = []
        var lines: [Substring] = []
        var length = 0
        func add(_ line: Substring) {
            let count = line.count
            if !lines.isEmpty, lines.count == codeChunkLineLimit || length + count > codeChunkCharacterLimit {
                chunks.append(lines.joined(separator: "\n"))
                lines.removeAll(keepingCapacity: true)
                length = 0
            }
            lines.append(line)
            length += count
        }
        for line in code.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var rest = line
            repeat {
                let end = rest.index(rest.startIndex, offsetBy: codeChunkCharacterLimit, limitedBy: rest.endIndex)
                    ?? rest.endIndex
                add(rest[..<end])
                rest = rest[end...]
            } while !rest.isEmpty
        }
        chunks.append(lines.joined(separator: "\n"))
        return chunks
    }

    /// `text` in pieces of at most `textChunkCharacterLimit` characters, each
    /// cut after the last space within the limit when there is one; never
    /// empty. Concatenated they give back `text`.
    static func textChunks(_ text: AttributedString) -> [AttributedString] {
        let characters = text.characters
        guard characters.count > textChunkCharacterLimit else { return [text] }
        var chunks: [AttributedString] = []
        var start = characters.startIndex
        while start < characters.endIndex {
            var end = characters.index(start, offsetBy: textChunkCharacterLimit, limitedBy: characters.endIndex)
                ?? characters.endIndex
            if end < characters.endIndex,
                let space = characters[start..<end].lastIndex(where: \.isWhitespace)
            {
                end = characters.index(after: space)
            }
            chunks.append(AttributedString(text[start..<end]))
            start = end
        }
        return chunks
    }
}

/// One row of a flattened Markdown document.
struct MarkdownDocumentRow: Identifiable, Equatable, Sendable {
    /// The row's position in the document.
    let id: Int
    /// The quotes and list items holding the row, outermost first.
    let gutters: [Gutter]
    /// How many of `gutters`, from the outside, held the row above too:
    /// their quote bars run on through the gap between the two.
    let sharedGutterCount: Int
    /// The space above the row.
    let gap: Gap
    let content: Content

    enum Gutter: Equatable, Sendable {
        case quote
        /// `marker` is set on the item's first row only. `widestOrdinal` is
        /// the largest number in an ordered list, so every row of it leaves
        /// that number's room; nil for a bulleted list.
        case listItem(marker: Marker?, widestOrdinal: Int?)
    }

    enum Marker: Equatable, Sendable {
        /// `level` counts the lists outside this one, which picks the glyph.
        case bullet(level: Int)
        case ordinal(Int)
        case checkbox(MarkdownListItem.Checkbox)
    }

    enum Gap: Int, Comparable, Sendable {
        /// No space: the row opens the document, or goes on from the one
        /// above — a later stretch of the same paragraph, code block or table.
        case flush
        /// Another item or another block inside a list or quote.
        case item
        /// A new top-level block.
        case block

        static func < (lhs: Gap, rhs: Gap) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    enum Content: Equatable, Sendable {
        /// Only the first row of a long heading holds its anchor.
        case heading(level: Int, text: AttributedString, anchor: String)
        case paragraph(AttributedString)
        /// One stretch of a code block; the first and last carry its rounded
        /// ends.
        case code(String, isFirst: Bool, isLast: Bool)
        /// A table small enough for one grid.
        case table(MarkdownTable)
        /// One row of a bigger table. Its rows share `table`, the table
        /// block's id, to scroll sideways together; a cell the row lacks is
        /// drawn empty, and a long one is cut by `displayedTableCell`.
        case tableRow(
            table: MarkdownBlock.ID, cells: [AttributedString], alignments: [MarkdownTable.Alignment],
            isHeader: Bool)
        case thematicBreak
    }

    /// The checkbox of the innermost task item this row starts, which
    /// VoiceOver reads as the row's value.
    var checkbox: MarkdownListItem.Checkbox? {
        for gutter in gutters.reversed() {
            if case .listItem(.checkbox(let checkbox)?, _) = gutter {
                return checkbox
            }
        }
        return nil
    }
}

/// Walks the block tree depth first, keeping the open quotes and list items
/// as a stack of gutters. Nesting is capped by the parser, so the recursion
/// is too.
private struct Builder {
    private(set) var rows: [MarkdownDocumentRow] = []
    private var gutters: [MarkdownDocumentRow.Gutter] = []
    /// One id per open quote or list item, telling a container from the
    /// next one at the same depth.
    private var gutterIDs: [Int] = []
    private var previousGutterIDs: [Int] = []
    private var nextGutterID = 0
    private var listLevel = 0
    private var pendingGap = MarkdownDocumentRow.Gap.flush

    mutating func append(_ blocks: [MarkdownBlock]) {
        for block in blocks {
            guard !Task.isCancelled else { return }
            requestGap(gutters.isEmpty ? .block : .item)
            append(block)
        }
    }

    private mutating func append(_ block: MarkdownBlock) {
        switch block.kind {
        case .heading(let level, let text, let anchor):
            for (index, chunk) in MarkdownDocumentRows.textChunks(text).enumerated() {
                emit(.heading(level: level, text: chunk, anchor: index == 0 ? anchor : ""))
            }
        case .paragraph(let text):
            for chunk in MarkdownDocumentRows.textChunks(text) {
                emit(.paragraph(chunk))
            }
        case .list(let ordered, let items):
            appendList(ordered: ordered, items: items)
        case .blockQuote(let blocks):
            open(.quote)
            append(blocks)
            close()
        case .codeBlock(_, let code):
            let chunks = MarkdownDocumentRows.codeChunks(code)
            for (index, chunk) in chunks.enumerated() {
                emit(.code(chunk, isFirst: index == 0, isLast: index == chunks.count - 1))
            }
        case .table(let table):
            appendTable(table, id: block.id)
        case .thematicBreak:
            emit(.thematicBreak)
        }
    }

    private mutating func appendList(ordered: Bool, items: [MarkdownListItem]) {
        let level = listLevel
        let widestOrdinal = ordered ? items.map(\.ordinal).max() : nil
        listLevel += 1
        defer { listLevel -= 1 }
        for (index, item) in items.enumerated() {
            if index > 0 {
                requestGap(.item)
            }
            let marker: MarkdownDocumentRow.Marker =
                if let checkbox = item.checkbox {
                    .checkbox(checkbox)
                } else if ordered {
                    .ordinal(item.ordinal)
                } else {
                    .bullet(level: level)
                }
            open(.listItem(marker: marker, widestOrdinal: widestOrdinal))
            append(item.blocks)
            // An item with nothing to show still shows its marker.
            if case .listItem(.some, _)? = gutters.last {
                emit(.paragraph(AttributedString()))
            }
            close()
        }
    }

    private mutating func appendTable(_ table: MarkdownTable, id: MarkdownBlock.ID) {
        guard !MarkdownDocumentRows.usesGrid(table) else {
            emit(.table(table))
            return
        }
        emitTableRow(table.header, of: table, id: id, isHeader: true)
        for row in table.rows {
            guard !Task.isCancelled else { return }
            emitTableRow(row, of: table, id: id, isHeader: false)
        }
    }

    private mutating func emitTableRow(
        _ cells: [AttributedString], of table: MarkdownTable, id: MarkdownBlock.ID, isHeader: Bool
    ) {
        emit(
            .tableRow(
                table: id, cells: cells.map(MarkdownDocumentRows.displayedTableCell),
                alignments: table.alignments, isHeader: isHeader))
    }

    private mutating func requestGap(_ gap: MarkdownDocumentRow.Gap) {
        pendingGap = max(pendingGap, gap)
    }

    private mutating func open(_ gutter: MarkdownDocumentRow.Gutter) {
        gutters.append(gutter)
        gutterIDs.append(nextGutterID)
        nextGutterID += 1
    }

    private mutating func close() {
        gutters.removeLast()
        gutterIDs.removeLast()
    }

    private mutating func emit(_ content: MarkdownDocumentRow.Content) {
        var shared = 0
        while shared < gutterIDs.count, shared < previousGutterIDs.count,
            gutterIDs[shared] == previousGutterIDs[shared]
        {
            shared += 1
        }
        rows.append(
            MarkdownDocumentRow(
                id: rows.count,
                gutters: gutters,
                sharedGutterCount: shared,
                gap: rows.isEmpty ? .flush : pendingGap,
                content: content))
        previousGutterIDs = gutterIDs
        pendingGap = .flush
        // Each marker shows on its item's first row only.
        for index in gutters.indices {
            if case .listItem(.some, let widestOrdinal) = gutters[index] {
                gutters[index] = .listItem(marker: nil, widestOrdinal: widestOrdinal)
            }
        }
    }
}
