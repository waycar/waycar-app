import Foundation

/// A help category (`help/categories.json`, the same list waycar.dev uses).
struct HelpCategory: Identifiable, Hashable, Sendable, Decodable {
    let id: String
    let label: String
}

/// One bundled waycar.dev help page.
struct HelpPage: Identifiable, Hashable, Sendable {
    let slug: String
    var id: String { slug }
    let title: String
    let description: String
    let categoryID: String
    /// Position within the category; `Int.max` when the page gives none, so
    /// it sorts last.
    let order: Int
    let keywords: [String]
    let related: [String]
    /// Markdown body without frontmatter and without image-only lines.
    let body: String
    /// `##`/`###` heading texts, for search.
    let headings: [String]

    /// Nil when the page is unusable: no title or no category.
    init?(slug: String, markdown: String) {
        let frontmatter = MarkdownFrontmatter.parse(markdown)
        guard !slug.isEmpty, let title = frontmatter.title, let category = frontmatter.category else {
            return nil
        }
        self.slug = slug
        self.title = title
        self.description = frontmatter.description ?? ""
        self.categoryID = category
        self.order = frontmatter.order ?? .max
        self.keywords = frontmatter.keywords
        self.related = frontmatter.related
        let body = Self.droppingImageLines(frontmatter.body)
        self.body = body
        self.headings = Self.headings(in: body)
    }

    /// The body without lines that are only an image (`![alt](src)`): the
    /// app ships no screenshots, and `MarkdownDocument` would otherwise show
    /// a placeholder for each.
    private static func droppingImageLines(_ body: String) -> String {
        body.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !isImageLine($0) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isImageLine(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("![") && trimmed.hasSuffix(")") && trimmed.contains("](")
    }

    /// `##` and `###` heading texts outside fenced code, inline markup
    /// stripped the way the site's rendered headings read.
    private static func headings(in body: String) -> [String] {
        var headings: [String] = []
        var fence: String?
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if trimmed.hasPrefix(open) { fence = nil }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(3))
                continue
            }
            let level = line.prefix { $0 == "#" }.count
            guard level == 2 || level == 3, line.dropFirst(level).first == " " else { continue }
            var text = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
            // A closing sequence of `#`s is not part of the heading.
            while text.hasSuffix("#") { text.removeLast() }
            text = HelpSearchText.plain(text).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { headings.append(text) }
        }
        return headings
    }
}

enum HelpCatalogError: Error, Equatable, LocalizedError {
    case categoriesMissing
    case categoriesUnreadable(String)
    case categoriesMalformed(String)
    case noCategories

    var errorDescription: String? {
        switch self {
        case .categoriesMissing: "The bundled help/categories.json is missing."
        case .categoriesUnreadable(let reason): "The bundled help categories could not be read: \(reason)"
        case .categoriesMalformed(let reason): "The bundled help categories are malformed: \(reason)"
        case .noCategories: "The bundled help categories list is empty."
        }
    }
}

/// The waycar.dev help pages bundled into the app (`help/`, the folder
/// `apps/web/src/content/help` copied whole), searchable offline.
struct HelpCatalog: Sendable {
    /// Bundle subdirectory holding `categories.json` and every `<slug>.md`.
    static let subdirectory = "help"

    /// Display order, as `categories.json` lists them.
    let categories: [HelpCategory]
    /// Category order, then `order`, then slug.
    let pages: [HelpPage]
    private let index: HelpSearchIndex

    private init(categories: [HelpCategory], pages: [HelpPage]) {
        self.categories = categories
        self.pages = pages
        self.index = HelpSearchIndex(pages: pages)
    }

    func page(_ slug: String) -> HelpPage? {
        pages.first { $0.slug == slug }
    }

    func pages(in categoryID: String) -> [HelpPage] {
        pages.filter { $0.categoryID == categoryID }
    }

    func category(_ id: String) -> HelpCategory? {
        categories.first { $0.id == id }
    }

    /// Ranked results; empty/whitespace query → []. See ``HelpSearchIndex``.
    func search(_ query: String) -> [HelpPage] {
        index.search(query).map { pages[$0] }
    }

    /// Loads `help/categories.json` and every `help/*.md` from the bundle.
    /// Lenient per page: a page that fails to parse is skipped, never
    /// crashes. Throws only when the category list is missing or malformed.
    static func bundled(in bundle: Bundle = .main) throws -> HelpCatalog {
        guard
            let categoriesURL = bundle.url(
                forResource: "categories", withExtension: "json", subdirectory: subdirectory)
        else { throw HelpCatalogError.categoriesMissing }
        let categoriesJSON: Data
        do {
            categoriesJSON = try Data(contentsOf: categoriesURL)
        } catch {
            throw HelpCatalogError.categoriesUnreadable(error.localizedDescription)
        }
        let pageURLs = bundle.urls(forResourcesWithExtension: "md", subdirectory: subdirectory) ?? []
        let pages = pageURLs.compactMap { url -> (slug: String, markdown: String)? in
            guard let data = try? Data(contentsOf: url), let markdown = String(data: data, encoding: .utf8) else {
                return nil
            }
            return (url.deletingPathExtension().lastPathComponent, markdown)
        }
        return try parse(categoriesJSON: categoriesJSON, pages: pages)
    }

    /// The catalog from raw inputs (`bundled(in:)`, and tests). A page with
    /// no title, no category, a category `categoriesJSON` does not list, or a
    /// slug already taken is skipped: the Help screen lists pages by
    /// category, so a page outside every category would be unreachable
    /// except through search.
    static func parse(categoriesJSON: Data, pages: [(slug: String, markdown: String)]) throws -> HelpCatalog {
        let decoded: [HelpCategory]
        do {
            decoded = try JSONDecoder().decode([HelpCategory].self, from: categoriesJSON)
        } catch {
            throw HelpCatalogError.categoriesMalformed(error.localizedDescription)
        }
        var categories: [HelpCategory] = []
        var rank: [String: Int] = [:]
        for category in decoded where !category.id.isEmpty && rank[category.id] == nil {
            rank[category.id] = categories.count
            categories.append(category)
        }
        guard !categories.isEmpty else { throw HelpCatalogError.noCategories }

        var seen: Set<String> = []
        let parsed = pages.compactMap { source -> HelpPage? in
            guard let page = HelpPage(slug: source.slug, markdown: source.markdown),
                rank[page.categoryID] != nil,
                seen.insert(page.slug).inserted
            else { return nil }
            return page
        }
        let sorted = parsed.sorted { lhs, rhs in
            let lhsRank = rank[lhs.categoryID] ?? .max
            let rhsRank = rank[rhs.categoryID] ?? .max
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            return lhs.slug < rhs.slug
        }
        return HelpCatalog(categories: categories, pages: sorted)
    }
}
