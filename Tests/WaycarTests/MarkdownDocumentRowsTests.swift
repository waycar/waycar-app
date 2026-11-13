import Foundation
import Testing

@testable import Waycar

/// A rendered Markdown file (#147) is drawn by one lazy stack, so the parsed
/// document is flattened into rows: nesting rides along on each row as
/// gutters, and long paragraphs, code blocks and big tables are cut so no
/// single row grows with the file.
@Suite("Markdown document rows")
struct MarkdownDocumentRowsTests {
    @Test func nestedListItemsEachGetARowWithTheirMarkersInOrder() {
        let rows = flatten("- one\n  1. first\n  2. second\n- [ ] todo\n- [x] done")
        #expect(rows.map(\.id) == Array(0..<5))
        #expect(rows.map(text) == ["one", "first", "second", "todo", "done"])
        #expect(rows.map(\.gutters) == [
            [item(.bullet(level: 0))],
            [item(nil), item(.ordinal(1), widest: 2)],
            [item(nil), item(.ordinal(2), widest: 2)],
            [item(.checkbox(.unchecked))],
            [item(.checkbox(.checked))],
        ])
        #expect(rows.map(\.checkbox) == [nil, nil, nil, .unchecked, .checked])
    }

    @Test func anItemsLaterBlocksKeepItsIndentWithoutRepeatingTheMarker() {
        let rows = flatten("- a\n\n  b\n- c")
        #expect(rows.map(text) == ["a", "b", "c"])
        #expect(rows.map(\.gutters) == [[item(.bullet(level: 0))], [item(nil)], [item(.bullet(level: 0))]])
        #expect(rows.map(\.sharedGutterCount) == [0, 1, 0])
        #expect(rows.map(\.gap) == [.flush, .item, .item])
    }

    @Test func aListInsideAQuoteCarriesTheQuoteOnEveryRow() {
        let rows = flatten("> intro\n>\n> - a\n>   - b\n\nafter")
        #expect(rows.map(text) == ["intro", "a", "b", "after"])
        #expect(rows.map(\.gutters) == [
            [.quote],
            [.quote, item(.bullet(level: 0))],
            [.quote, item(nil), item(.bullet(level: 1))],
            [],
        ])
        // The quote's bar runs on through the gaps inside it, not past it.
        #expect(rows.map(\.sharedGutterCount) == [0, 1, 2, 0])
        #expect(rows.map(\.gap) == [.flush, .item, .item, .block])
    }

    @Test func aHugeCodeBlockIsChunkedKeepingEveryLine() {
        let code = (1...250).map { "line \($0)" }.joined(separator: "\n")
        let rows = flatten("```swift\n\(code)\n```")
        let chunks = rows.compactMap(codeChunk)
        #expect(chunks.count == rows.count)
        #expect(chunks.map { $0.code.split(separator: "\n", omittingEmptySubsequences: false).count } == [100, 100, 50])
        #expect(chunks.map(\.code).joined(separator: "\n") == code)
        #expect(chunks.map(\.isFirst) == [true, false, false])
        #expect(chunks.map(\.isLast) == [false, false, true])
        #expect(rows.dropFirst().allSatisfy { $0.gap == .flush })
    }

    @Test func anOverlongCodeLineIsBrokenAcrossChunks() {
        let line = String(repeating: "x", count: 20_000)
        let chunks = MarkdownDocumentRows.codeChunks("short\n" + line)
        #expect(chunks.count == 4)
        #expect(chunks.allSatisfy { $0.count <= MarkdownDocumentRows.codeChunkCharacterLimit })
        #expect(chunks.joined() == "short" + line)
    }

    @Test func aLongParagraphIsCutAtSpacesKeepingAllItsText() {
        let paragraph = Array(repeating: "lorem", count: 2_000).joined(separator: " ")
        let rows = flatten(paragraph)
        let pieces = rows.compactMap(text)
        #expect(pieces.count == rows.count)
        #expect(pieces.count > 1)
        #expect(pieces.allSatisfy { $0.count <= MarkdownDocumentRows.textChunkCharacterLimit })
        #expect(pieces.dropLast().allSatisfy { $0.hasSuffix(" ") })
        #expect(pieces.joined() == paragraph)
        #expect(rows.dropFirst().allSatisfy { $0.gap == .flush })
    }

    @Test func anAnchorMapsToItsHeadingsRowWhereverItSits() throws {
        let document = MarkdownDocumentRows(
            MarkdownDocument.parse("# Top\n\n> ## Quoted heading\n\n- ### In a list\n\ntext"))
        #expect(document.rowID(forAnchor: "top") == 0)
        let quoted = try #require(document.rowID(forAnchor: "quoted-heading"))
        #expect(text(document.rows[quoted]) == "Quoted heading")
        #expect(document.rows[quoted].gutters == [.quote])
        let listed = try #require(document.rowID(forAnchor: "in-a-list"))
        #expect(text(document.rows[listed]) == "In a list")
        #expect(document.rows[listed].gutters == [item(.bullet(level: 0))])
        #expect(document.rowID(forAnchor: "missing") == nil)
    }

    @Test func aTableWithinTheGridLimitsIsOneRow() {
        let columns = MarkdownDocumentRows.gridColumnLimit
        let bodyRows = MarkdownDocumentRows.gridCellLimit / columns - 1
        let rows = flatten(table(columns: columns, rows: bodyRows))
        #expect(rows.count == 1)
        guard case .table(let table) = rows.first?.content else {
            Issue.record("expected one grid table, got \(rows)")
            return
        }
        #expect(table.rows.count == bodyRows)
    }

    @Test func aTablePastTheCellLimitGetsARowPerTableRow() {
        let bodyRows = MarkdownDocumentRows.gridCellLimit / 3
        let rows = flatten(table(columns: 3, rows: bodyRows))
        let tableRows = rows.compactMap(tableRow)
        #expect(tableRows.count == rows.count)
        #expect(tableRows.count == bodyRows + 1)
        #expect(tableRows.map(\.isHeader) == [true] + Array(repeating: false, count: tableRows.count - 1))
        #expect(Set(tableRows.map(\.table)).count == 1)
        #expect(tableRows[1].cells == ["0-1", "0-2", "0-3"])
        #expect(rows.dropFirst().allSatisfy { $0.gap == .flush })
    }

    @Test func aTablePastTheColumnLimitGetsARowPerTableRow() {
        let rows = flatten(table(columns: MarkdownDocumentRows.gridColumnLimit + 1, rows: 1))
        let tableRows = rows.compactMap(tableRow)
        #expect(tableRows.count == 2)
        #expect(tableRows.first?.cells.count == MarkdownDocumentRows.gridColumnLimit + 1)
        #expect(tableRows.first?.alignments.count == MarkdownDocumentRows.gridColumnLimit + 1)
    }

    @Test func aSmallTableWithOneLongCellGetsARowPerTableRow() {
        let atLimit = String(repeating: "x", count: MarkdownDocumentRows.gridCellCharacterLimit)
        let rows = flatten("| a | b |\n|---|---|\n| \(atLimit)x | 1 |")
        let tableRows = rows.compactMap(tableRow)
        #expect(tableRows.count == 2)
        #expect(tableRows.count == rows.count)
        #expect(tableRows.last?.cells == [atLimit + "x", "1"])

        let grid = flatten("| a | b |\n|---|---|\n| \(atLimit) | 1 |")
        #expect(grid.count == 1)
        guard case .table = grid.first?.content else {
            Issue.record("expected one grid table, got \(grid)")
            return
        }
    }

    @Test func aLongCellOfARowByRowTableIsCutKeepingItsStart() {
        let limit = MarkdownDocumentRows.tableCellCharacterLimit
        let long = (0..<(limit + 100)).map { String($0 % 10) }.joined()
        let atLimit = String(repeating: "y", count: limit)
        let rows = flatten("| \(atLimit) | b |\n|---|---|\n| \(long) | short |").compactMap(tableRow)
        #expect(rows.count == 2)
        #expect(rows.first?.cells == [atLimit, "b"])
        let cut = rows.last?.cells.first ?? ""
        #expect(cut == String(long.prefix(limit)) + "…")
        #expect(rows.last?.cells.last == "short")
    }

    // MARK: - Helpers

    private struct CodeChunk {
        let code: String
        let isFirst: Bool
        let isLast: Bool
    }

    private struct TableRow {
        let table: Int
        let cells: [String]
        let alignments: [MarkdownTable.Alignment]
        let isHeader: Bool
    }

    private func flatten(_ markdown: String) -> [MarkdownDocumentRow] {
        MarkdownDocumentRows(MarkdownDocument.parse(markdown)).rows
    }

    private func item(_ marker: MarkdownDocumentRow.Marker?, widest: Int? = nil) -> MarkdownDocumentRow.Gutter {
        .listItem(marker: marker, widestOrdinal: widest)
    }

    private func text(_ row: MarkdownDocumentRow) -> String? {
        switch row.content {
        case .paragraph(let text), .heading(_, let text, _): String(text.characters)
        default: nil
        }
    }

    private func codeChunk(_ row: MarkdownDocumentRow) -> CodeChunk? {
        guard case .code(let code, let isFirst, let isLast) = row.content else { return nil }
        return CodeChunk(code: code, isFirst: isFirst, isLast: isLast)
    }

    private func tableRow(_ row: MarkdownDocumentRow) -> TableRow? {
        guard case .tableRow(let table, let cells, let alignments, let isHeader) = row.content else { return nil }
        return TableRow(
            table: table, cells: cells.map { String($0.characters) }, alignments: alignments, isHeader: isHeader)
    }

    /// A table of `columns` columns and `rows` rows, cell `r-c` holding its
    /// row and column.
    private func table(columns: Int, rows: Int) -> String {
        let header = "|" + (1...columns).map { " h\($0) |" }.joined()
        let rule = "|" + String(repeating: "---|", count: columns)
        let body = (0..<rows).map { row in "|" + (1...columns).map { " \(row)-\($0) |" }.joined() }
        return ([header, rule] + body).joined(separator: "\n")
    }
}
