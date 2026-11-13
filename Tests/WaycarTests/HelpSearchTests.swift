import Foundation
import Testing

@testable import Waycar

/// Offline help search ranks like the waycar.dev search palette
/// (`apps/web/src/lib/help-search.mjs`): every term must match, whole words
/// beat prefixes beat typos, and title matches beat body matches.
@Suite("Help search")
struct HelpSearchTests {
    private static let catalog: HelpCatalog? = try? HelpCatalog.parse(
        categoriesJSON: Data(#"[{"id":"all","label":"All"}]"#.utf8),
        pages: [
            page("body-pairing", order: 1, title: "Getting around", body: "Scan the pairing code on your Host."),
            page("pairing", order: 2, title: "Pairing", body: "Pair a Host."),
            page("notifications", order: 3, title: "Notifications", keywords: "[alerts, push]"),
            page("pairing-scanner", order: 4, title: "Pairing scanner", body: "Point the scanner at the code."),
            page("resume", order: 5, title: "Résumé builder", body: "Write a CV."),
            page("hosts", order: 6, title: "Hosts", body: "Add a host."),
            page("cant-connect", order: 7, title: "Can't connect to a Host", body: "Check the network."),
            page("connections", order: 8, title: "Connection messages", body: "What each message means."),
            page("tie-a", order: 10, title: "Tie", body: "Kettle."),
            page("tie-b", order: 9, title: "Tie", body: "Kettle."),
        ])

    private func slugs(_ query: String) throws -> [String] {
        try #require(Self.catalog).search(query).map(\.slug)
    }

    @Test func emptyOrTermlessQueriesFindNothing() throws {
        for query in ["", "   ", "\n\t", "!!! ???", "'"] {
            #expect(try slugs(query).isEmpty, "\(query)")
        }
    }

    @Test func titleMatchesBeatBodyMatches() throws {
        let results = try slugs("pairing")
        #expect(results.first == "pairing")
        let scanner = try #require(results.firstIndex(of: "pairing-scanner"))
        let bodyOnly = try #require(results.firstIndex(of: "body-pairing"))
        #expect(scanner < bodyOnly)
    }

    @Test func fieldsRankTitleKeywordsHeadingsDescriptionBody() throws {
        // Catalog order is the reverse of the expected ranking.
        let catalog = try HelpCatalog.parse(
            categoriesJSON: Data(#"[{"id":"all","label":"All"}]"#.utf8),
            pages: [
                Self.page("body", order: 1, title: "One", body: "A zephyr blows."),
                Self.page("description", order: 2, title: "Two", description: "About the zephyr."),
                Self.page("heading", order: 3, title: "Three", body: "## Zephyr\n\nText."),
                Self.page("keyword", order: 4, title: "Four", keywords: "[zephyr]"),
                Self.page("title", order: 5, title: "Zephyr"),
            ])
        #expect(catalog.search("zephyr").map(\.slug) == ["title", "keyword", "heading", "description", "body"])
    }

    @Test func everyTermMustMatch() throws {
        #expect(try slugs("pairing scanner") == ["pairing-scanner"])
        #expect(try slugs("pairing kettle").isEmpty)
    }

    @Test func termsMatchAsWordPrefixes() throws {
        #expect(try slugs("notif") == ["notifications"])
        #expect(try slugs("NOTIF").first == "notifications")
        #expect(try slugs("aler") == ["notifications"])
    }

    @Test func longTermsForgiveOneTypo() throws {
        // Substitution, deletion, insertion and a swapped pair.
        for query in ["notifixations", "notifcations", "notiffications", "notificaitons"] {
            #expect(try slugs(query) == ["notifications"], "\(query)")
        }
        // Five letters is long enough to forgive a typo.
        #expect(try slugs("hostz").contains("hosts"))
        // Under five letters a typo is a different word.
        #expect(try slugs("hots").isEmpty)
        // Two edits is too many.
        #expect(try slugs("notifixatoins").isEmpty)
    }

    @Test func wholeWordsBeatPrefixesBeatTypos() throws {
        let catalog = try HelpCatalog.parse(
            categoriesJSON: Data(#"[{"id":"all","label":"All"}]"#.utf8),
            pages: [
                Self.page("typo", order: 1, title: "Kettel"),
                Self.page("prefix", order: 2, title: "Kettlebells"),
                Self.page("whole", order: 3, title: "Kettle"),
            ])
        #expect(catalog.search("kettle").map(\.slug) == ["whole", "prefix", "typo"])
    }

    /// Mirrors help-search.test.mjs: only the title-phrase bonus puts
    /// "Chat Mode" ahead of the earlier "Mode for chat".
    @Test func aTitlePhraseBeatsTheSameWordsApart() throws {
        let catalog = try HelpCatalog.parse(
            categoriesJSON: Data(#"[{"id":"all","label":"All"}]"#.utf8),
            pages: [
                Self.page("mode-for-chat", order: 1, title: "Mode for chat"),
                Self.page("chat-mode", order: 2, title: "Chat Mode"),
            ])
        #expect(catalog.search("chat mode").map(\.slug) == ["chat-mode", "mode-for-chat"])
    }

    /// Fence info strings aren't page text on the site, so they don't match;
    /// the code inside a fence still does.
    @Test func codeFenceInfoStringsAreNotSearched() throws {
        let catalog = try HelpCatalog.parse(
            categoriesJSON: Data(#"[{"id":"all","label":"All"}]"#.utf8),
            pages: [
                Self.page("fenced", order: 1, title: "Fenced", body: "Run this:\n\n```text\nherdr status\n```\n\n~~~sh\nuptime\n~~~"),
            ])
        #expect(catalog.search("text").isEmpty)
        #expect(catalog.search("sh").isEmpty)
        #expect(catalog.search("herdr status").map(\.slug) == ["fenced"])
        #expect(catalog.search("uptime").map(\.slug) == ["fenced"])
    }

    @Test func apostrophesInsideWordsAreDropped() throws {
        for query in ["cant connect", "can't connect", "Can’t Connect", "CANT"] {
            #expect(try slugs(query).first == "cant-connect", "\(query)")
        }
    }

    @Test func diacriticsAreFolded() throws {
        #expect(try slugs("resume") == ["resume"])
        #expect(try slugs("RÉSUMÉ") == ["resume"])
        #expect(try slugs("résu") == ["resume"])
    }

    @Test func tiesKeepCatalogOrder() throws {
        #expect(try slugs("tie") == ["tie-b", "tie-a"])
    }

    @Test func tokensFollowTheSiteRules() {
        #expect(HelpSearchText.tokens("Can't connect—to a Host's café") == ["cant", "connect", "to", "a", "hosts", "cafe"])
        #expect(HelpSearchText.tokens("tmux 3.2 ssh-keys") == ["tmux", "3", "2", "ssh", "keys"])
        #expect(HelpSearchText.tokens("can'' t 'quoted'") == ["can", "t", "quoted"])
        #expect(HelpSearchText.terms("Pair pair PAIR") == ["pair"])
    }

    @Test func bundledPagesAnswerCommonQuestions() throws {
        let catalog = try HelpCatalog.bundled()
        #expect(catalog.search("cant connect").first?.slug == "cant-connect")
        #expect(catalog.search("can't connect").first?.slug == "cant-connect")
        #expect(catalog.search("notifcations").contains { $0.slug == "notifications" })
    }

    private static func page(
        _ slug: String, order: Int, title: String, description: String = "About this page.",
        keywords: String = "[]", body: String = "Body."
    ) -> (slug: String, markdown: String) {
        (
            slug,
            """
            ---
            title: \(title)
            description: \(description)
            category: all
            order: \(order)
            keywords: \(keywords)
            related: []
            ---

            \(body)
            """
        )
    }
}
