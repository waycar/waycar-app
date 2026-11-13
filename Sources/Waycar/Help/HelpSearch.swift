import Foundation

/// Offline help search, ranked like waycar.dev's search palette
/// (`apps/web/src/lib/help-search.mjs`; keep the two in step).
///
/// Text is compared as tokens: lowercased, diacritics removed, split on
/// anything that is not a letter or digit, except that an apostrophe inside a
/// word is dropped rather than split on (`Can't` → `cant`). Every query term
/// must match some field of a page, as a whole word, as the start of a word
/// (search as you type), or, for terms of 5+ characters, as a word one edit
/// away (insert, delete, substitute, or swap two neighbours). A term scores
/// its best field weight times its match quality; a page scores the sum over
/// its terms, plus a bonus when the whole query starts a word of its title.
/// Ties keep catalog order.
struct HelpSearchIndex: Sendable {
    /// Field weights, strongest first.
    private enum Field: Int, CaseIterable {
        case title, keywords, headings, description, body

        var weight: Double {
            switch self {
            case .title: 10
            case .keywords: 6
            case .headings: 4
            case .description: 3
            case .body: 1
            }
        }
    }

    private static let wholeWord = 1.0
    private static let prefix = 0.5
    private static let typo = 0.3
    private static let typoMinimumLength = 5
    private static let titlePhraseBonus = 8.0

    private struct Entry: Sendable {
        /// Distinct tokens per field, indexed by `Field.rawValue`.
        let fields: [[String]]
        /// The title's tokens joined by single spaces, for the phrase bonus.
        let title: String
    }

    private let entries: [Entry]
    /// Every indexed word, with its scalars for the typo check.
    private let vocabulary: [(word: String, scalars: [Unicode.Scalar])]

    init(pages: [HelpPage]) {
        var vocabulary: Set<String> = []
        func words(_ text: String) -> [String] {
            var seen: Set<String> = []
            let tokens = HelpSearchText.tokens(text).filter { seen.insert($0).inserted }
            vocabulary.formUnion(tokens)
            return tokens
        }
        entries = pages.map { page in
            Entry(
                fields: [
                    words(page.title),
                    words(page.keywords.joined(separator: " ")),
                    words(page.headings.joined(separator: " ")),
                    words(page.description),
                    words(HelpSearchText.plain(HelpSearchText.droppingFenceLines(page.body))),
                ],
                title: HelpSearchText.tokens(page.title).joined(separator: " "))
        }
        self.vocabulary = vocabulary.sorted().map { ($0, Array($0.unicodeScalars)) }
    }

    /// Positions (in the pages the index was built from) of the pages
    /// matching every term of `query`, best first. Empty for a query with
    /// no terms.
    func search(_ query: String) -> [Int] {
        let terms = HelpSearchText.terms(query)
        guard !terms.isEmpty else { return [] }
        let perTerm = terms.map { termMatches($0) }
        guard perTerm.allSatisfy({ !$0.isEmpty }) else { return [] }
        let phrase = " " + terms.joined(separator: " ")

        var results: [(position: Int, score: Double)] = []
        pageLoop: for (position, entry) in entries.enumerated() {
            var score = 0.0
            for matches in perTerm {
                var best = 0.0
                for field in Field.allCases where field.weight > best {
                    for word in entry.fields[field.rawValue] {
                        if let quality = matches[word] { best = max(best, field.weight * quality) }
                    }
                }
                guard best > 0 else { continue pageLoop }
                score += best
            }
            if (" " + entry.title).contains(phrase) { score += Self.titlePhraseBonus }
            results.append((position, score))
        }
        // Positions break ties so the order never depends on the sort.
        results.sort { $0.score != $1.score ? $0.score > $1.score : $0.position < $1.position }
        return results.map(\.position)
    }

    /// How well each vocabulary word matches `term`: whole word, prefix, or
    /// typo.
    private func termMatches(_ term: String) -> [String: Double] {
        var matches: [String: Double] = [:]
        let termScalars = Array(term.unicodeScalars)
        let allowsTypo = termScalars.count >= Self.typoMinimumLength
        for (word, scalars) in vocabulary {
            if word == term {
                matches[word] = Self.wholeWord
            } else if word.hasPrefix(term) {
                matches[word] = Self.prefix
            } else if allowsTypo,
                HelpSearchText.editDistance(termScalars, scalars, maximum: 1) <= 1
            {
                matches[word] = Self.typo
            }
        }
        return matches
    }
}

/// Text handling shared by help search and the help page model.
enum HelpSearchText {
    /// Lowercase without diacritics: `Résumé` → `resume`.
    static func normalize(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.decomposedStringWithCompatibilityMapping.unicodeScalars where !isMark(scalar) {
            scalars.append(scalar)
        }
        return String(scalars).lowercased()
    }

    /// Normalized words of `text`: runs of letters and digits, an apostrophe
    /// (`'` or `’`) between two of them dropped rather than split on.
    static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var word = String.UnicodeScalarView()
        var apostrophe = false
        func flush() {
            if !word.isEmpty { tokens.append(String(word)) }
            word = String.UnicodeScalarView()
            apostrophe = false
        }
        for scalar in normalize(text).unicodeScalars {
            if isWordScalar(scalar) {
                word.append(scalar)
                apostrophe = false
            } else if (scalar == "'" || scalar == "\u{2019}"), !word.isEmpty, !apostrophe {
                apostrophe = true
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }

    /// The query's distinct terms, in order.
    static func terms(_ query: String) -> [String] {
        var seen: Set<String> = []
        return tokens(query).filter { seen.insert($0).inserted }
    }

    /// `markdown` without its code-fence delimiter lines (```` ```sh ````,
    /// `~~~`), whose info strings the site's rendered-text index never sees.
    /// Code inside the fences stays, as on the site.
    static func droppingFenceLines(_ markdown: String) -> String {
        var fence: String?
        return markdown.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if let open = fence {
                    guard trimmed.hasPrefix(open) else { return true }
                    fence = nil
                    return false
                }
                guard trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") else { return true }
                fence = String(trimmed.prefix(3))
                return false
            }
            .joined(separator: "\n")
    }

    /// Markdown inline text as it reads: link destinations dropped, and the
    /// `[`, `]`, `` ` `` and `*` markup removed.
    static func plain(_ markdown: String) -> String {
        var result = ""
        var rest = Substring(markdown)
        while let character = rest.first {
            if character == "]", rest.dropFirst().first == "(", let close = rest.firstIndex(of: ")") {
                rest = rest[rest.index(after: close)...]
                continue
            }
            if !"[]`*".contains(character) { result.append(character) }
            rest = rest.dropFirst()
        }
        return result
    }

    /// Optimal string alignment distance between `a` and `b`, or
    /// `maximum + 1` once it exceeds `maximum`.
    static func editDistance(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar], maximum: Int) -> Int {
        if abs(a.count - b.count) > maximum { return maximum + 1 }
        var rows: [[Int]] = [Array(0...b.count)]
        for i in stride(from: 1, through: a.count, by: 1) {
            var row = [i]
            var best = i
            for j in stride(from: 1, through: b.count, by: 1) {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var value = min(rows[i - 1][j] + 1, row[j - 1] + 1, rows[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    value = min(value, rows[i - 2][j - 2] + 1)
                }
                row.append(value)
                best = min(best, value)
            }
            if best > maximum { return maximum + 1 }
            rows.append(row)
        }
        return rows[a.count][b.count]
    }

    private static func isMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: true
        default: false
        }
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
            .nonspacingMark, .spacingMark, .enclosingMark,
            .decimalNumber, .letterNumber, .otherNumber:
            true
        default:
            false
        }
    }
}
