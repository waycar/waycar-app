import Foundation
import Testing

@testable import Waycar

/// The bundled waycar.dev help pages (#161): the lenient frontmatter reader,
/// the catalog built from raw pages, and the real `help/` folder the app
/// ships, which must hold every page of `apps/web/src/content/help`.
@Suite("Help catalog")
struct HelpCatalogTests {
    private static let categoriesJSON = Data(
        #"[{"id":"get-started","label":"Get started"},{"id":"hosts","label":"Hosts and connections"}]"#.utf8)

    // MARK: Frontmatter

    @Test func readsEveryFieldTheSitePagesUse() {
        let parsed = MarkdownFrontmatter.parse(
            """
            ---
            title: Use Waycar with tmux
            description: "Use Waycar with tmux 3.2 or later: your tmux sessions show up as Workspaces."
            category: hosts
            order: 40
            keywords: [update the waycar plugin, can't refresh, tmux, "quoted, with comma", 'single: quoted']
            related: [pairing, ssh-keys]
            ---

            Body text.
            """)
        #expect(parsed.title == "Use Waycar with tmux")
        #expect(parsed.description == "Use Waycar with tmux 3.2 or later: your tmux sessions show up as Workspaces.")
        #expect(parsed.category == "hosts")
        #expect(parsed.order == 40)
        #expect(
            parsed.keywords == [
                "update the waycar plugin", "can't refresh", "tmux", "quoted, with comma", "single: quoted",
            ])
        #expect(parsed.related == ["pairing", "ssh-keys"])
        #expect(parsed.body.trimmingCharacters(in: .whitespacesAndNewlines) == "Body text.")
    }

    @Test func unescapesQuotedScalars() {
        let parsed = MarkdownFrontmatter.parse(
            """
            ---
            title: 'It''s here'
            description: "Say \\"hi\\": now" # trailing comment
            ---
            """)
        #expect(parsed.title == "It's here")
        #expect(parsed.description == "Say \"hi\": now")
    }

    @Test func readsBlockListsWrappedScalarsAndWindowsLineEndings() {
        let parsed = MarkdownFrontmatter.parse(
            "---\r\ntitle: A title\r\ndescription: First line\r\n  second line\r\nkeywords:\r\n  - one item\r\n  - two\r\nrelated: []\r\n---\r\nBody")
        #expect(parsed.title == "A title")
        #expect(parsed.description == "First line second line")
        #expect(parsed.keywords == ["one item", "two"])
        #expect(parsed.related.isEmpty)
        #expect(parsed.body == "Body")
    }

    @Test func readsWrappedQuotedScalarsAndFlowArrays() {
        let parsed = MarkdownFrontmatter.parse(
            """
            ---
            title: 'It''s wrapped:
              over lines'
            description: "Pair a Host: scan the code,
              then confirm."
            keywords: [pairing, "a, b",
              host-keys]
            related: [pairing, ssh-keys,
              host-keys]
            category: hosts
            ---
            Body
            """)
        #expect(parsed.title == "It's wrapped: over lines")
        #expect(parsed.description == "Pair a Host: scan the code, then confirm.")
        #expect(parsed.keywords == ["pairing", "a, b", "host-keys"])
        #expect(parsed.related == ["pairing", "ssh-keys", "host-keys"])
        #expect(parsed.category == "hosts")
        #expect(parsed.body == "Body")
    }

    @Test func readsQuotedAndFlowValuesStartingBelowTheirKey() {
        let parsed = MarkdownFrontmatter.parse(
            """
            ---
            title:
              'It''s here'
            description:
              "Pair a Host: scan
              the code."
            keywords:
              [one, "two, three"]
            related:
              [pairing,
              ssh-keys]
            category:
              hosts
            ---
            Body
            """)
        #expect(parsed.title == "It's here")
        #expect(parsed.description == "Pair a Host: scan the code.")
        #expect(parsed.keywords == ["one", "two, three"])
        #expect(parsed.related == ["pairing", "ssh-keys"])
        #expect(parsed.category == "hosts")
    }

    @Test func blockIndicatorKeepsItsQuotesLiteral() {
        let parsed = MarkdownFrontmatter.parse("---\ndescription: >\n  \"Quoted\" text\n---\nBody")
        #expect(parsed.description == "\"Quoted\" text")
    }

    @Test func escapedLineBreakInDoubleQuotesJoinsWithoutSpace() {
        let parsed = MarkdownFrontmatter.parse("---\ntitle: \"abc\\\n  def\"\ndescription: \"a\\\\\n  b\"\n---\nBody")
        #expect(parsed.title == "abcdef")
        // An escaped backslash does not escape the break.
        #expect(parsed.description == "a\\ b")
    }

    @Test func flowArrayCommentsAreDropped() {
        let parsed = MarkdownFrontmatter.parse(
            """
            ---
            keywords: [a, # old
              # x,
              b, "c # kept"] # trailing
            related: [one, two] # note
            ---
            Body
            """)
        #expect(parsed.keywords == ["a", "b", "c # kept"])
        #expect(parsed.related == ["one", "two"])
    }

    @Test func missingOptionalFieldsFallBackToDefaults() throws {
        let catalog = try HelpCatalog.parse(
            categoriesJSON: Self.categoriesJSON,
            pages: [
                (slug: "bare", markdown: "---\ntitle: Bare page\ncategory: hosts\n---\nJust a body."),
                (slug: "ordered", markdown: Self.page(title: "Ordered", category: "hosts", order: 50)),
            ])
        let page = try #require(catalog.page("bare"))
        #expect(page.title == "Bare page")
        #expect(page.description.isEmpty)
        // A page without `order` sorts after the ordered pages in its category.
        #expect(catalog.pages(in: "hosts").map(\.slug) == ["ordered", "bare"])
        #expect(page.keywords.isEmpty)
        #expect(page.related.isEmpty)
        #expect(page.body == "Just a body.")
    }

    @Test func malformedPagesAreSkippedNotFatal() throws {
        let catalog = try HelpCatalog.parse(
            categoriesJSON: Self.categoriesJSON,
            pages: [
                (slug: "good", markdown: Self.page(title: "Good", category: "hosts", order: 1)),
                (slug: "no-frontmatter", markdown: "# Just Markdown\n\nNo fence."),
                (slug: "unclosed", markdown: "---\ntitle: Unclosed\ncategory: hosts\n"),
                (slug: "no-title", markdown: "---\ncategory: hosts\norder: 2\n---\nBody"),
                (slug: "no-category", markdown: "---\ntitle: Lost\n---\nBody"),
                (slug: "unknown-category", markdown: Self.page(title: "Elsewhere", category: "nowhere", order: 1)),
                (slug: "garbage", markdown: "---\n: : :\n[[[\n\"\n---\n"),
                (slug: "", markdown: Self.page(title: "No slug", category: "hosts", order: 3)),
                (slug: "good", markdown: Self.page(title: "Duplicate", category: "hosts", order: 4)),
            ])
        #expect(catalog.pages.map(\.slug) == ["good"])
        #expect(catalog.page("good")?.title == "Good")
    }

    @Test func malformedOrEmptyCategoriesThrow() {
        #expect(throws: HelpCatalogError.self) {
            try HelpCatalog.parse(categoriesJSON: Data("{".utf8), pages: [])
        }
        #expect(throws: HelpCatalogError.noCategories) {
            try HelpCatalog.parse(categoriesJSON: Data("[]".utf8), pages: [])
        }
    }

    // MARK: Body and headings

    @Test func bodyDropsImageLinesAndHeadingsSkipCodeAndMarkup() throws {
        let catalog = try HelpCatalog.parse(
            categoriesJSON: Self.categoriesJSON,
            pages: [
                (
                    slug: "page",
                    markdown: Self.page(
                        title: "Page", category: "hosts", order: 1,
                        body: """
                            Intro with ![inline](x.png) kept.

                            ![A screenshot](../../assets/screens/iphone.png)

                            # Not collected
                            ## What does `waycar hooks status` say?
                            ### See [pairing](/help/pairing) ##
                            #### Too deep
                            ```sh
                            ## a shell comment
                            ```
                            Done.
                            """)
                )
            ])
        let page = try #require(catalog.page("page"))
        #expect(!page.body.contains("../../assets"))
        #expect(page.body.hasPrefix("Intro with ![inline](x.png) kept."))
        #expect(page.headings == ["What does waycar hooks status say?", "See pairing"])
    }

    // MARK: Order and lookup

    @Test func pagesFollowCategoryOrderThenOrder() throws {
        let catalog = try HelpCatalog.parse(
            categoriesJSON: Self.categoriesJSON,
            pages: [
                (slug: "host-b", markdown: Self.page(title: "Host B", category: "hosts", order: 20)),
                (slug: "start-b", markdown: Self.page(title: "Start B", category: "get-started", order: 20)),
                (slug: "host-a", markdown: Self.page(title: "Host A", category: "hosts", order: 10)),
                (slug: "start-a", markdown: Self.page(title: "Start A", category: "get-started", order: 10)),
            ])
        #expect(catalog.categories.map(\.id) == ["get-started", "hosts"])
        #expect(catalog.pages.map(\.slug) == ["start-a", "start-b", "host-a", "host-b"])
        #expect(catalog.pages(in: "hosts").map(\.slug) == ["host-a", "host-b"])
        #expect(catalog.pages(in: "nowhere").isEmpty)
        #expect(catalog.category("hosts")?.label == "Hosts and connections")
        #expect(catalog.category("nowhere") == nil)
        #expect(catalog.page("missing") == nil)
    }

    // MARK: The bundled pages

    @Test func bundleCarriesEveryHelpPage() throws {
        let catalog = try HelpCatalog.bundled()
        let files = Bundle.main.urls(forResourcesWithExtension: "md", subdirectory: HelpCatalog.subdirectory) ?? []
        #expect(!files.isEmpty)
        #expect(catalog.pages.count == files.count)
        #expect(Set(catalog.pages.map(\.slug)) == Set(files.map { $0.deletingPathExtension().lastPathComponent }))
    }

    /// The bounds the site's strict schema (`apps/web/src/content.config.ts`)
    /// already enforces; a parsed value outside them means the app misread
    /// YAML the site accepted. Lengths in UTF-16 to match JS `.length`.
    @Test func everyBundledPageIsComplete() throws {
        let catalog = try HelpCatalog.bundled()
        #expect(!catalog.categories.isEmpty)
        for page in catalog.pages {
            #expect(catalog.category(page.categoryID) != nil, "\(page.slug): unknown category \(page.categoryID)")
            #expect(!page.title.isEmpty, "\(page.slug)")
            #expect(page.title.utf16.count <= 60, "\(page.slug): title \(page.title)")
            #expect((70...160).contains(page.description.utf16.count), "\(page.slug): description \(page.description)")
            #expect(page.order > 0, "\(page.slug)")
            // `.max` is HelpPage's sentinel for an `order` the app could not read.
            #expect(page.order != .max, "\(page.slug): unreadable order")
            #expect((3...10).contains(page.keywords.count), "\(page.slug): keywords \(page.keywords)")
            #expect((2...4).contains(page.related.count), "\(page.slug): related \(page.related)")
            #expect(Set(page.related).count == page.related.count, "\(page.slug): duplicate related")
            #expect(!page.related.contains(page.slug), "\(page.slug): relates to itself")
            #expect(!page.body.isEmpty, "\(page.slug)")
            #expect(!page.body.contains("](../../assets/"), "\(page.slug): image line left in the body")
            for slug in page.related {
                #expect(catalog.page(slug) != nil, "\(page.slug): related \(slug) is not a page")
            }
        }
    }

    /// Every link in a bundled page opens something in the app, and every
    /// anchor lands on a heading of the page as ``HelpPageView`` renders it.
    @MainActor
    @Test func everyBundledHelpLinkResolves() throws {
        let catalog = try HelpCatalog.bundled()
        func expectAnchor(_ anchor: String, on target: HelpPage, from source: HelpPage) {
            let rows = MarkdownDocumentRows(MarkdownDocument.parse(HelpPageView.markdown(for: target)))
            #expect(
                rows.rowID(forAnchor: anchor) != nil,
                "\(source.slug): no heading #\(anchor) on \(target.slug)")
        }
        for page in catalog.pages {
            for target in page.body.components(separatedBy: "](").dropFirst() {
                guard let end = target.firstIndex(of: ")") else { continue }
                let link = String(target[..<end])
                guard let url = URL(string: link), let destination = HelpLinkDestination.resolve(url) else {
                    Issue.record("\(page.slug): the app can't open \(link)")
                    continue
                }
                switch destination {
                case .page(let slug, let anchor):
                    guard let linked = catalog.page(slug) else {
                        Issue.record("\(page.slug): links to missing page \(slug)")
                        continue
                    }
                    if let anchor { expectAnchor(anchor, on: linked, from: page) }
                case .anchor(let anchor):
                    expectAnchor(anchor, on: page, from: page)
                default:
                    break
                }
            }
        }
    }

    @Test(arguments: HelpTopic.allCases)
    func everyHelpTopicResolvesToABundledPage(topic: HelpTopic) throws {
        let catalog = try HelpCatalog.bundled()
        #expect(catalog.page(topic.rawValue) != nil)
        #expect(HelpWeb.pageURL(topic.rawValue) != nil)
    }

    // MARK: Helpers

    static func page(title: String, category: String, order: Int, body: String = "Body.") -> String {
        """
        ---
        title: \(title)
        description: About \(title).
        category: \(category)
        order: \(order)
        keywords: [example]
        related: []
        ---

        \(body)
        """
    }
}
