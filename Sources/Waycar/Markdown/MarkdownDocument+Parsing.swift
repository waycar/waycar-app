import Foundation

extension MarkdownDocument {
    /// Parses GitHub-flavoured Markdown with Foundation's parser. Pure and
    /// never fails: input Foundation rejects outright becomes one paragraph
    /// of the raw text. Foundation reports blocks only as each run's
    /// `presentationIntent` (innermost component first, no separators), so
    /// the runs are regrouped into a tree by component identity first.
    /// Cancelling the calling task stops the regrouping early: what is
    /// built so far comes back, which is nothing when cancelled up front.
    static func parse(_ text: String) -> MarkdownDocument {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            guard !text.isEmpty else { return MarkdownDocument(blocks: []) }
            return MarkdownDocument(blocks: [MarkdownBlock(id: 0, kind: .paragraph(AttributedString(text)))])
        }
        var builder = MarkdownBlockBuilder()
        return MarkdownDocument(blocks: builder.blocks(from: MarkdownNode.tree(of: parsed)))
    }
}

/// How many runs or blocks are handled between checks for cancellation.
private let cancellationCheckInterval = 64

/// One `PresentationIntent` component regrouped from the parser's flat runs.
private final class MarkdownNode {
    /// Identity for text that arrived with no block intent at all.
    static let looseTextIdentity = -1

    let kind: PresentationIntent.Kind
    let identity: Int
    var children: [MarkdownNode] = []
    var inline = AttributedString()

    init(kind: PresentationIntent.Kind, identity: Int) {
        self.kind = kind
        self.identity = identity
    }

    /// Regroups the runs by component identity. Past
    /// `MarkdownDocument.maximumNestingDepth` quotes and lists a run's
    /// deeper components are dropped and its text lands in a paragraph of
    /// the deepest container kept, so the tree — and everything that walks
    /// it — stays shallow however deep the remote file nests.
    static func tree(of parsed: AttributedString) -> [MarkdownNode] {
        let root = MarkdownNode(kind: .paragraph, identity: Int.min)
        for (index, run) in parsed.runs.enumerated() {
            if index.isMultiple(of: cancellationCheckInterval), Task.isCancelled { break }
            let piece = inlinePiece(parsed[run.range], attributes: run.attributes)
            let components = run.presentationIntent?.components ?? []
            var parent = root
            if components.isEmpty {
                parent = root.child(kind: .paragraph, identity: looseTextIdentity)
            }
            var depth = 0
            for component in components.reversed() {
                if isContainer(component.kind) {
                    guard depth < MarkdownDocument.maximumNestingDepth else {
                        // `components` is non-empty here; its first is the
                        // innermost block, so each deep block stays its own
                        // paragraph.
                        parent = parent.child(kind: .paragraph, identity: components[0].identity)
                        break
                    }
                    depth += 1
                }
                parent = parent.child(kind: component.kind, identity: component.identity)
            }
            parent.inline.append(piece)
        }
        return root.children
    }

    /// Whether `kind` nests other blocks and counts toward the depth cap.
    /// A list item sits inside its list, so the list alone is counted.
    private static func isContainer(_ kind: PresentationIntent.Kind) -> Bool {
        switch kind {
        case .blockQuote, .orderedList, .unorderedList: true
        default: false
        }
    }

    /// The last child when it is the same component (runs of one block are
    /// contiguous), otherwise a new child.
    private func child(kind: PresentationIntent.Kind, identity: Int) -> MarkdownNode {
        if let last = children.last, last.identity == identity {
            return last
        }
        let node = MarkdownNode(kind: kind, identity: identity)
        children.append(node)
        return node
    }

    /// The run's text without its block intent. An image run (its text is
    /// the alt, or U+FFFC when the alt is empty) becomes a placeholder and
    /// loses `imageURL`, so nothing downstream can ever load it; a link the
    /// image sits in is kept.
    private static func inlinePiece(_ slice: AttributedSubstring, attributes: AttributeContainer) -> AttributedString {
        guard attributes.imageURL != nil else {
            var piece = AttributedString(slice)
            piece.presentationIntent = nil
            return piece
        }
        var placeholderAttributes = attributes
        placeholderAttributes.imageURL = nil
        placeholderAttributes.presentationIntent = nil
        let alt = String(slice.characters)
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return AttributedString("\u{1F5BC} " + (alt.isEmpty ? "Image" : alt), attributes: placeholderAttributes)
    }
}

/// Turns the regrouped tree into display blocks, numbering every block and
/// list item and deduplicating heading anchors in document order.
private struct MarkdownBlockBuilder {
    private var nextID = 0
    /// Every anchor handed out, mapped to how many suffixes its slug has
    /// tried — github-slugger's bookkeeping.
    private var anchorOccurrences: [String: Int] = [:]

    mutating func blocks(from nodes: [MarkdownNode]) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        for (index, node) in nodes.enumerated() {
            if index.isMultiple(of: cancellationCheckInterval), Task.isCancelled { break }
            blocks.append(contentsOf: self.blocks(from: node))
        }
        return blocks
    }

    private mutating func blocks(from node: MarkdownNode) -> [MarkdownBlock] {
        switch node.kind {
        case .paragraph:
            return [block(.paragraph(node.inline))] + blocks(from: node.children)
        case .header(let level):
            return [heading(level: level, text: node.inline)]
        case .orderedList:
            return [list(node, ordered: true)]
        case .unorderedList:
            return [list(node, ordered: false)]
        case .blockQuote:
            let id = makeID()
            return [MarkdownBlock(id: id, kind: .blockQuote(contents(of: node)))]
        case .codeBlock(let languageHint):
            var code = String(node.inline.characters)
            if code.last?.isNewline == true {
                code.removeLast()
            }
            let language = languageHint?.trimmingCharacters(in: .whitespaces)
            return [block(.codeBlock(language: language?.isEmpty == false ? language : nil, code: code))]
        case .thematicBreak:
            return [block(.thematicBreak)]
        case .table(let columns):
            return [table(node, columns: columns)]
        case .listItem, .tableHeaderRow, .tableRow, .tableCell:
            // Only reachable for a malformed tree; keep the text visible.
            return contents(of: node)
        @unknown default:
            return contents(of: node)
        }
    }

    /// A node's own text as a leading paragraph, then its child blocks.
    private mutating func contents(of node: MarkdownNode) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        if !node.inline.characters.isEmpty {
            blocks.append(block(.paragraph(node.inline)))
        }
        blocks.append(contentsOf: self.blocks(from: node.children))
        return blocks
    }

    /// A repeated slug gets the first unused `-1`, `-2`… suffix, skipping
    /// any a heading already took verbatim: `A`, `A 1`, `A` anchor as `a`,
    /// `a-1`, `a-2`, as on GitHub.
    private mutating func heading(level: Int, text: AttributedString) -> MarkdownBlock {
        let slug = MarkdownDocument.slug(String(text.characters))
        var anchor = slug
        while anchorOccurrences[anchor] != nil {
            let suffix = anchorOccurrences[slug, default: 0] + 1
            anchorOccurrences[slug] = suffix
            anchor = "\(slug)-\(suffix)"
        }
        anchorOccurrences[anchor] = 0
        return block(.heading(level: level, text: text, anchor: anchor))
    }

    private mutating func list(_ node: MarkdownNode, ordered: Bool) -> MarkdownBlock {
        let id = makeID()
        var items: [MarkdownListItem] = []
        for (index, child) in node.children.enumerated() {
            if index.isMultiple(of: cancellationCheckInterval), Task.isCancelled { break }
            let itemID = makeID()
            var ordinal = items.count + 1
            if case .listItem(let reported) = child.kind {
                ordinal = reported
            }
            var blocks = contents(of: child)
            let checkbox = Self.takeCheckbox(from: &blocks)
            items.append(MarkdownListItem(id: itemID, ordinal: ordinal, checkbox: checkbox, blocks: blocks))
        }
        return MarkdownBlock(id: id, kind: .list(ordered: ordered, items: items))
    }

    /// Foundation leaves GitHub task-list markers in the item's text; move a
    /// leading `[ ] ` / `[x] ` / `[X] ` out of the first paragraph.
    private static func takeCheckbox(from blocks: inout [MarkdownBlock]) -> MarkdownListItem.Checkbox? {
        guard let first = blocks.first, case .paragraph(let text) = first.kind else { return nil }
        let markers: [(String, MarkdownListItem.Checkbox)] = [
            ("[ ] ", .unchecked), ("[x] ", .checked), ("[X] ", .checked),
        ]
        guard let match = markers.first(where: { text.characters.starts(with: $0.0) }) else {
            return nil
        }
        var stripped = text
        let markerEnd = stripped.characters.index(stripped.startIndex, offsetBy: match.0.count)
        stripped.removeSubrange(stripped.startIndex..<markerEnd)
        blocks[0] = MarkdownBlock(id: first.id, kind: .paragraph(stripped))
        return match.1
    }

    /// Cells go where the parser numbers them; a row is as long as its
    /// last cell, and anything past `MarkdownTable.maximumColumns` is
    /// dropped.
    private mutating func table(
        _ node: MarkdownNode, columns: [PresentationIntent.TableColumn]
    ) -> MarkdownBlock {
        let id = makeID()
        let alignments = columns.prefix(MarkdownTable.maximumColumns).map(Self.alignment)
        var header: [AttributedString] = []
        var rows: [[AttributedString]] = []
        for row in node.children {
            var cells: [AttributedString] = []
            for cell in row.children {
                guard case .tableCell(let column) = cell.kind, alignments.indices.contains(column) else { continue }
                while cells.count <= column {
                    cells.append(AttributedString())
                }
                cells[column] = cell.inline
            }
            if case .tableHeaderRow = row.kind {
                header = cells
            } else {
                rows.append(cells)
            }
        }
        return MarkdownBlock(id: id, kind: .table(MarkdownTable(alignments: alignments, header: header, rows: rows)))
    }

    private static func alignment(_ column: PresentationIntent.TableColumn) -> MarkdownTable.Alignment {
        switch column.alignment {
        case .center: .center
        case .right: .trailing
        default: .leading
        }
    }

    private mutating func block(_ kind: MarkdownBlock.Kind) -> MarkdownBlock {
        MarkdownBlock(id: makeID(), kind: kind)
    }

    private mutating func makeID() -> Int {
        defer { nextID += 1 }
        return nextID
    }
}
