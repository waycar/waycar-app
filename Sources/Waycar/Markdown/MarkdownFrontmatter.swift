import Foundation

/// A bundled waycar.dev content file split into its frontmatter fields and
/// Markdown body: a help page (`apps/web/src/content/help/<slug>.md`) or a
/// changelog release (`apps/web/src/content/changelog/<version>.md`). The
/// site's content schemas validate the files at build time; this side stays
/// lenient and Foundation-only: it reads the YAML subset the files use
/// (plain, double- and single-quoted scalars, integers, inline `[a, b c]`
/// flow arrays, `- item` block lists), skips unknown keys and malformed
/// lines, and never throws. Whether the result is usable is the caller's
/// call (``HelpPage``, ``ChangelogEntry``).
struct MarkdownFrontmatter: Equatable, Sendable {
    var title: String?
    var description: String?
    var category: String?
    var order: Int?
    var keywords: [String] = []
    var related: [String] = []
    /// A changelog release's version, as written (`1.1.3`).
    var version: String?
    /// A changelog release's date, as written (`2026-10-04`).
    var date: String?
    /// The text after the closing fence; all of it when there is no
    /// frontmatter block.
    var body: String

    /// One field's value: a scalar, or a list (flow or block).
    private enum Value: Equatable {
        case scalar(String)
        case list([String])

        /// The trimmed text of a scalar; nil for a list or blank text.
        var text: String? {
            guard case .scalar(let text) = self else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }

        var items: [String] {
            switch self {
            case .list(let items): items
            // A lone scalar where a list belongs is a one-item list.
            case .scalar: text.map { [$0] } ?? []
            }
        }
    }

    static func parse(_ markdown: String) -> MarkdownFrontmatter {
        // CRLF first: "\r\n" is one grapheme cluster, so a split on "\n"
        // would miss every Windows line ending.
        var text = TerminalTextSafety.normalizingNewlines(markdown)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)

        guard let open = lines.firstIndex(where: { !$0.allSatisfy(\.isWhitespace) }),
            lines[open].trimmingCharacters(in: .whitespaces) == "---",
            let close = lines[(open + 1)...].firstIndex(where: {
                let fence = $0.trimmingCharacters(in: .whitespaces)
                return fence == "---" || fence == "..."
            })
        else { return MarkdownFrontmatter(body: text) }

        let fields = parseFields(lines[(open + 1)..<close])
        return MarkdownFrontmatter(
            title: fields["title"]?.text,
            description: fields["description"]?.text,
            category: fields["category"]?.text,
            order: fields["order"]?.text.flatMap { Int($0) },
            keywords: fields["keywords"]?.items ?? [],
            related: fields["related"]?.items ?? [],
            version: fields["version"]?.text,
            date: fields["date"]?.text,
            body: lines[(close + 1)...].joined(separator: "\n"))
    }

    private static func parseFields(_ lines: ArraySlice<Substring>) -> [String: Value] {
        var fields: [String: Value] = [:]
        var currentKey: String?
        // A quoted scalar or flow array whose closing quote or `]` is on a
        // later line: YAML folds the following lines into it with a space.
        var pending: (key: String, raw: String)?
        // The key's value starts on the next line (nothing after the colon,
        // not a `|`/`>` block indicator), so that line may be quoted or flow.
        var valueOnNextLine = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indented = line.first?.isWhitespace == true
            if let open = pending {
                if indented || trimmed.isEmpty {
                    if trimmed.isEmpty { continue }
                    let raw: String
                    if open.raw.hasPrefix("[") {
                        // A `#` comment inside a multi-line flow array.
                        let content = withoutFlowComment(trimmed)
                        if content.isEmpty { continue }
                        raw = open.raw + " " + content
                    } else if open.raw.hasPrefix("\""), endsInEscape(open.raw) {
                        // `\` at the end of a double-quoted line escapes the
                        // break: the lines join with no space.
                        raw = String(open.raw.dropLast()) + trimmed
                    } else {
                        raw = open.raw + " " + trimmed
                    }
                    fields[open.key] = value(raw)
                    pending = isUnclosed(raw) ? (open.key, raw) : nil
                    continue
                }
                // An unclosed value ends at the next top-level line.
                pending = nil
            }
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let startsValue = valueOnNextLine
            valueOnNextLine = false

            if !indented, let field = topLevelField(line) {
                currentKey = field.key
                // Nothing (or a `|`/`>` block indicator) after the colon: the
                // value, list or text, follows on the next lines.
                let opensBlock = field.rest.isEmpty || ["|", ">", "|-", ">-", "|+", ">+"].contains(field.rest)
                valueOnNextLine = field.rest.isEmpty
                let rest = field.rest.hasPrefix("[") ? withoutFlowComment(field.rest) : field.rest
                fields[field.key] = opensBlock ? .list([]) : value(rest)
                if !opensBlock, isUnclosed(rest) { pending = (field.key, rest) }
                continue
            }
            guard let key = currentKey else { continue }

            // A block list item, indented or not under its key.
            if trimmed.hasPrefix("- "), case .list(let items)? = fields[key] {
                let item = scalar(String(trimmed.dropFirst(2)))
                fields[key] = .list(item.isEmpty ? items : items + [item])
                continue
            }
            // Anything else at zero indentation is noise that ends the field.
            guard indented else {
                currentKey = nil
                continue
            }
            // The first line of a value that starts below its key is read as
            // a value of its own: it may be quoted or a flow array.
            if startsValue, case .list(let items)? = fields[key], items.isEmpty {
                let raw = trimmed.hasPrefix("[") ? withoutFlowComment(trimmed) : trimmed
                fields[key] = value(raw)
                if isUnclosed(raw) { pending = (key, raw) }
                continue
            }
            // An indented line continues a text value; YAML folds the lines
            // with a space.
            switch fields[key] {
            case .scalar(let existing)?:
                fields[key] = .scalar(existing.isEmpty ? trimmed : existing + " " + trimmed)
            case .list(let items)? where items.isEmpty:
                fields[key] = .scalar(trimmed)
            default:
                continue
            }
        }
        return fields
    }

    /// `key: value` at zero indentation.
    private static func topLevelField(_ line: Substring) -> (key: String, rest: String)? {
        guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { return nil }
        let key = line[..<colon]
        guard key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
            return nil
        }
        let rest = line[line.index(after: colon)...]
        // `key:value` is not a mapping in YAML; the space (or end) is required.
        guard rest.isEmpty || rest.first?.isWhitespace == true else { return nil }
        return (String(key), rest.trimmingCharacters(in: .whitespaces))
    }

    private static func value(_ text: String) -> Value {
        if text.hasPrefix("[") {
            return .list(flowItems(text.dropFirst()).items.map(scalar).filter { !$0.isEmpty })
        }
        return .scalar(scalar(text))
    }

    /// Whether `text` opens a quoted scalar or flow array it doesn't close.
    private static func isUnclosed(_ text: String) -> Bool {
        let raw = Substring(text)
        switch raw.first {
        case "\"": return !doubleQuoted(raw.dropFirst()).closed
        case "'": return !singleQuoted(raw.dropFirst()).closed
        case "[": return !flowItems(raw.dropFirst()).closed
        default: return false
        }
    }

    /// Whether `text` ends in a `\` that is not itself escaped.
    private static func endsInEscape(_ text: String) -> Bool {
        text.reversed().prefix(while: { $0 == "\\" }).count % 2 == 1
    }

    /// A flow-array line without its `#` comment: one starting the line or
    /// following whitespace, outside quotes.
    private static func withoutFlowComment(_ line: String) -> String {
        var quote: Character?
        var previous: Character = " "
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if let open = quote {
                if character == "\\", open == "\"" {
                    index = line.index(after: index)
                    if index < line.endIndex { previous = line[index]; index = line.index(after: index) }
                    continue
                }
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                if previous.isWhitespace || previous == "[" || previous == "," { quote = character }
            } else if character == "#", previous.isWhitespace {
                return line[..<index].trimmingCharacters(in: .whitespaces)
            }
            previous = character
            index = line.index(after: index)
        }
        return line
    }

    /// A scalar's text: quoted strings unescaped (anything after the closing
    /// quote dropped), plain ones cut at a ` #` comment.
    private static func scalar(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("\"") { return doubleQuoted(text.dropFirst()).text }
        if text.hasPrefix("'") { return singleQuoted(text.dropFirst()).text }
        if let comment = text.range(of: " #") {
            return text[..<comment.lowerBound].trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    /// The items of a flow array, given the text after its `[`: split on
    /// commas outside quotes, up to the closing `]`. An unclosed array keeps
    /// what it has.
    private static func flowItems(_ text: Substring) -> (items: [String], closed: Bool) {
        var items: [String] = []
        var current = ""
        var rest = text
        while let character = rest.first {
            if character == "\"" || character == "'", current.allSatisfy(\.isWhitespace) {
                // A quote opens a quoted item only at the item's start
                // (`can't` is plain). Keep the quotes so `scalar` unquotes
                // the item as a whole.
                let quoted = character == "\"" ? doubleQuoted(rest.dropFirst()) : singleQuoted(rest.dropFirst())
                current += rest[rest.startIndex..<quoted.rest.startIndex]
                rest = quoted.rest
            } else if character == "," {
                items.append(current)
                current = ""
                rest = rest.dropFirst()
            } else if character == "]" {
                items.append(current)
                return (items, true)
            } else {
                current.append(character)
                rest = rest.dropFirst()
            }
        }
        items.append(current)
        return (items, false)
    }

    /// The text of a double-quoted scalar, given what follows its opening
    /// quote, what follows its closing quote, and whether it was closed.
    private static func doubleQuoted(_ text: Substring) -> (text: String, rest: Substring, closed: Bool) {
        var result = ""
        var rest = text
        while let character = rest.first {
            rest = rest.dropFirst()
            switch character {
            case "\"":
                return (result, rest, true)
            case "\\":
                guard let escaped = rest.first else { return (result, rest, false) }
                rest = rest.dropFirst()
                switch escaped {
                case "n": result.append("\n")
                case "t": result.append("\t")
                default: result.append(escaped)
                }
            default:
                result.append(character)
            }
        }
        return (result, rest, false)
    }

    /// As ``doubleQuoted(_:)`` for single quotes, where `''` is a quote.
    private static func singleQuoted(_ text: Substring) -> (text: String, rest: Substring, closed: Bool) {
        var result = ""
        var rest = text
        while let character = rest.first {
            rest = rest.dropFirst()
            if character == "'" {
                guard rest.first == "'" else { return (result, rest, true) }
                rest = rest.dropFirst()
            }
            result.append(character)
        }
        return (result, rest, false)
    }
}
