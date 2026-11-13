import Foundation

/// A parsed Markdown file as a tree of display blocks (#147). Built by
/// `parse(_:)` from Foundation's GitHub-flavoured Markdown parser, so the app
/// carries no Markdown dependency. Inline content stays an
/// `AttributedString` with bold, italic, code, strikethrough and links;
/// images are already rewritten to text placeholders, so no run anywhere in
/// the document carries `imageURL` and nothing is ever fetched.
struct MarkdownDocument: Equatable, Sendable {
    /// The most quotes and lists nested in one another, counted together.
    /// The file is remote-chosen, so anything deeper is flattened into
    /// paragraphs of the deepest container kept, text intact; whatever
    /// walks the blocks may recurse without bound checks.
    static let maximumNestingDepth = 16

    let blocks: [MarkdownBlock]

    /// GitHub's heading-anchor slug: lowercased, everything but letters,
    /// marks, digits, `_`, `-` and spaces removed, each space turned into
    /// `-`. Duplicate suffixes (`-1`, `-2`…) are the parser's job.
    static func slug(_ text: String) -> String {
        var slug = String.UnicodeScalarView()
        for scalar in text.lowercased().unicodeScalars {
            if scalar == " " {
                slug.append("-")
            } else if scalar == "-" || isSlugScalar(scalar) {
                slug.append(scalar)
            }
        }
        return String(slug)
    }

    private static func isSlugScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
            .nonspacingMark, .spacingMark, .enclosingMark,
            .decimalNumber, .letterNumber, .otherNumber,
            .connectorPunctuation:
            true
        default:
            false
        }
    }
}

/// One block-level element of a `MarkdownDocument`.
struct MarkdownBlock: Identifiable, Equatable, Sendable {
    /// Unique within its document.
    let id: Int
    let kind: Kind

    enum Kind: Equatable, Sendable {
        /// `anchor` is the GitHub slug; repeats get `-1`, `-2`… in document order.
        case heading(level: Int, text: AttributedString, anchor: String)
        case paragraph(AttributedString)
        case list(ordered: Bool, items: [MarkdownListItem])
        case blockQuote([MarkdownBlock])
        /// `language` is nil when the fence has no info string; `code` has its
        /// final newline trimmed.
        case codeBlock(language: String?, code: String)
        case table(MarkdownTable)
        case thematicBreak
    }
}

/// One item of a Markdown list. `ordinal` is the item's 1-based position as
/// the parser reports it; a GitHub task-list item has its `[ ] ` / `[x] `
/// prefix moved out of the text into `checkbox`.
struct MarkdownListItem: Identifiable, Equatable, Sendable {
    let id: Int
    let ordinal: Int
    let checkbox: Checkbox?
    let blocks: [MarkdownBlock]

    enum Checkbox: Equatable, Sendable {
        case unchecked, checked
    }
}

/// A GitHub-flavoured Markdown table. A row, header included, holds the
/// cells the parser gave it, never more than `alignments.count`; a ragged
/// row is shorter, and a view shows its missing cells as empty.
struct MarkdownTable: Equatable, Sendable {
    /// Columns past this are dropped, alignments and cells alike.
    static let maximumColumns = 64

    enum Alignment: Equatable, Sendable {
        case leading, center, trailing
    }

    let alignments: [Alignment]
    let header: [AttributedString]
    let rows: [[AttributedString]]
}
