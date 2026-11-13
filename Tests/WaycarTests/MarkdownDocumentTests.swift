import Foundation
import Testing

@testable import Waycar

/// The rendered Markdown preview (#147) parses a remote-chosen file with
/// Foundation's GitHub-flavoured parser and regroups its flat runs into
/// display blocks; images must never survive as loadable URLs.
@Suite("Markdown document")
struct MarkdownDocumentTests {
    @Test func headingsCarryLevelsAndGitHubSlugsWithDuplicateSuffixes() {
        let document = MarkdownDocument.parse(
            "# Getting Started!\n\n## Getting Started\n\n### Getting   Started\n\n#### API_v2 — Notes\n\n# Getting Started")
        let headings = document.blocks.compactMap(heading)
        #expect(headings.map(\.level) == [1, 2, 3, 4, 1])
        #expect(headings.map(\.text) == [
            "Getting Started!", "Getting Started", "Getting   Started", "API_v2 — Notes", "Getting Started",
        ])
        #expect(headings.map(\.anchor) == [
            "getting-started", "getting-started-1", "getting---started", "api_v2--notes", "getting-started-2",
        ])
    }

    @Test func duplicateAnchorsSkipSuffixesAHeadingAlreadyTook() {
        let first = MarkdownDocument.parse("# A\n\n# A 1\n\n# A").blocks.compactMap(heading)
        #expect(first.map(\.anchor) == ["a", "a-1", "a-2"])
        let second = MarkdownDocument.parse("# A\n\n# A\n\n# A 1").blocks.compactMap(heading)
        #expect(second.map(\.anchor) == ["a", "a-1", "a-1-1"])
    }

    @Test func blockIDsAreUniqueAcrossNestedBlocks() {
        let document = MarkdownDocument.parse("# A\n\n> - one\n>   - two\n\n| x |\n|---|\n| 1 |\n\n---\n\ntext")
        var ids: [Int] = []
        for block in document.blocks {
            collectIDs(block, into: &ids)
        }
        #expect(ids.count > 6)
        #expect(Set(ids).count == ids.count)
    }

    @Test func orderedListNestedInUnorderedKeepsItsOwnOrdinals() throws {
        let document = MarkdownDocument.parse("- top\n  1. one\n  2. two\n- next")
        let outer = try #require(list(document.blocks.first))
        #expect(outer.ordered == false)
        #expect(outer.items.map(\.ordinal) == [1, 2])
        #expect(outer.items.map { plain($0.blocks.first) } == ["top", "next"])
        let inner = try #require(list(outer.items[0].blocks.last))
        #expect(inner.ordered)
        #expect(inner.items.map(\.ordinal) == [1, 2])
        #expect(inner.items.map { plain($0.blocks.first) } == ["one", "two"])
    }

    @Test func taskListMarkersBecomeCheckboxesAndLeaveTheText() throws {
        let document = MarkdownDocument.parse("- [ ] todo\n- [x] done\n- [X] shouted\n- plain [ ] item\n- [ ]")
        let items = try #require(list(document.blocks.first)).items
        #expect(items.map(\.checkbox) == [.unchecked, .checked, .checked, nil, nil])
        #expect(items.prefix(4).map { plain($0.blocks.first) } == ["todo", "done", "shouted", "plain [ ] item"])
    }

    @Test func tableKeepsColumnAlignmentsAndLeavesRaggedRowsShort() throws {
        let document = MarkdownDocument.parse("| a | b | c |\n|---|:-:|--:|\n| 1 |\n| x | | **z** |")
        guard case .table(let table) = document.blocks.first?.kind else {
            Issue.record("expected a table, got \(document.blocks)")
            return
        }
        #expect(table.alignments == [.leading, .center, .trailing])
        #expect(table.header.map(plain) == ["a", "b", "c"])
        #expect(table.rows.map { $0.map(plain) } == [["1"], ["x", "", "z"]])
        let bold = try #require(table.rows[1][2].runs.first?.inlinePresentationIntent)
        #expect(bold.contains(.stronglyEmphasized))
    }

    @Test func tableColumnsPastTheCapAreDropped() {
        let names = (0..<100).map { "c\($0)" }
        let text = "| " + names.joined(separator: " | ") + " |\n|" + String(repeating: "---|", count: 100)
            + "\n| " + names.joined(separator: " | ") + " |"
        guard case .table(let table) = MarkdownDocument.parse(text).blocks.first?.kind else {
            Issue.record("expected a table")
            return
        }
        #expect(table.alignments.count == MarkdownTable.maximumColumns)
        #expect(table.alignments.count == 64)
        #expect(table.header.map(plain) == Array(names.prefix(64)))
        #expect(table.rows.map(\.count) == [64])
    }

    @Test func blockQuoteHoldsANestedList() throws {
        let document = MarkdownDocument.parse("> intro\n>\n> - a\n> - b")
        #expect(document.blocks.count == 1)
        guard case .blockQuote(let quoted) = document.blocks.first?.kind else {
            Issue.record("expected a block quote, got \(document.blocks)")
            return
        }
        #expect(plain(quoted.first) == "intro")
        let nested = try #require(list(quoted.last))
        #expect(nested.items.map { plain($0.blocks.first) } == ["a", "b"])
    }

    @Test func fencedCodeKeepsItsLanguageHintAndDropsOnlyTheFinalNewline() {
        let document = MarkdownDocument.parse("```swift\nlet x = 1\n\n```\n\n```\nplain  text\n```")
        let codeBlocks = document.blocks.compactMap { block -> (String?, String)? in
            guard case .codeBlock(let language, let code) = block.kind else { return nil }
            return (language, code)
        }
        #expect(codeBlocks.count == 2)
        #expect(codeBlocks.first?.0 == "swift")
        #expect(codeBlocks.first?.1 == "let x = 1\n")
        #expect(codeBlocks.last?.0 == nil)
        #expect(codeBlocks.last?.1 == "plain  text")
    }

    @Test func thematicBreakSeparatesParagraphs() {
        let document = MarkdownDocument.parse("above\n\n---\n\nbelow")
        #expect(document.blocks.count == 3)
        #expect(document.blocks[1].kind == .thematicBreak)
        #expect(plain(document.blocks.first) == "above")
        #expect(plain(document.blocks.last) == "below")
    }

    @Test func inlineEmphasisCodeStrikethroughAndLinksSurvive() throws {
        let document = MarkdownDocument.parse("Some **bold**, `code`, ~~gone~~ and [docs](docs/spec.md).")
        guard case .paragraph(let text) = document.blocks.first?.kind else {
            Issue.record("expected a paragraph, got \(document.blocks)")
            return
        }
        #expect(String(text.characters) == "Some bold, code, gone and docs.")
        let intents = text.runs.compactMap(\.inlinePresentationIntent)
        #expect(intents.contains { $0.contains(.stronglyEmphasized) })
        #expect(intents.contains { $0.contains(.code) })
        #expect(intents.contains { $0.contains(.strikethrough) })
        let link = try #require(text.runs.compactMap(\.link).first)
        #expect(link.relativeString == "docs/spec.md")
    }

    @Test func softLineBreaksStayInsideOneParagraph() {
        let document = MarkdownDocument.parse("first line\nsecond line")
        #expect(document.blocks.count == 1)
        #expect(plain(document.blocks.first) == "first line second line")
    }

    @Test func imagesBecomeAltPlaceholdersAndNeverKeepTheirURL() {
        let document = MarkdownDocument.parse(
            """
            # Logo ![mark](https://example.com/h.png)

            ![diagram](https://example.com/d.png) and ![](/tmp/x.png)

            - ![item](i.png)

            > ![quoted](q.png)

            | pic |
            |-----|
            | ![cell](c.png) |
            """)
        var texts: [AttributedString] = []
        for block in document.blocks {
            collectInlineText(block, into: &texts)
        }
        #expect(texts.count == 6)
        #expect(texts.allSatisfy { text in text.runs.allSatisfy { $0.imageURL == nil } })
        let joined = texts.map { String($0.characters) }.joined(separator: "|")
        #expect(joined.contains("\u{1F5BC} diagram and \u{1F5BC} Image"))
        for alt in ["mark", "item", "quoted", "cell"] {
            #expect(joined.contains("\u{1F5BC} \(alt)"), "\(alt)")
        }
        #expect(!joined.contains("example.com"))
        #expect(!joined.contains("\u{FFFC}"))
    }

    @Test func emptyAndGarbageInputNeverCrash() {
        #expect(MarkdownDocument.parse("").blocks.isEmpty)
        for garbage in [
            "\u{0}\u{1}[[[](((", "```", "| |\n|", "> > > > >", "- - - -", "![", "[x](", "\u{FFFC}\u{FFFF}",
            String(repeating: "[", count: 5_000), String(repeating: "> ", count: 500) + "deep",
        ] {
            _ = MarkdownDocument.parse(garbage)
        }
        #expect(plain(MarkdownDocument.parse("\u{0}\u{1}[[[](((").blocks.first).contains("[[["))
    }

    @Test func nestingPastTheCapIsFlattenedWithItsTextKept() {
        #expect(MarkdownDocument.maximumNestingDepth == 16)
        for text in [String(repeating: ">", count: 10_000) + " deep", String(repeating: "- ", count: 5_000) + "deep"] {
            let document = MarkdownDocument.parse(text)
            #expect(document.blocks.map(nestingDepth) == [MarkdownDocument.maximumNestingDepth])
            var texts: [AttributedString] = []
            for block in document.blocks {
                collectInlineText(block, into: &texts)
            }
            #expect(texts.contains { plain($0).contains("deep") }, "\(text.prefix(20))")
        }
    }

    @Test func nestingUpToTheCapIsKept() {
        let document = MarkdownDocument.parse(String(repeating: ">", count: 16) + " sixteen")
        #expect(document.blocks.map(nestingDepth) == [16])
    }

    @Test func parsingInACancelledTaskStopsEarly() async {
        let text = (1...2_000).map { "Paragraph \($0)" }.joined(separator: "\n\n")
        #expect(MarkdownDocument.parse(text).blocks.count == 2_000)
        let task = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            return MarkdownDocument.parse(text)
        }
        task.cancel()
        #expect(await task.value.blocks.isEmpty)
    }

    // MARK: - Helpers

    private func heading(_ block: MarkdownBlock) -> (level: Int, text: String, anchor: String)? {
        guard case .heading(let level, let text, let anchor) = block.kind else { return nil }
        return (level, String(text.characters), anchor)
    }

    private func list(_ block: MarkdownBlock?) -> (ordered: Bool, items: [MarkdownListItem])? {
        guard case .list(let ordered, let items) = block?.kind else { return nil }
        return (ordered, items)
    }

    private func plain(_ text: AttributedString) -> String {
        String(text.characters)
    }

    private func plain(_ block: MarkdownBlock?) -> String {
        guard case .paragraph(let text) = block?.kind else { return "<not a paragraph: \(String(describing: block))>" }
        return plain(text)
    }

    /// Quotes and lists nested in one another at `block`, counted together.
    private func nestingDepth(_ block: MarkdownBlock) -> Int {
        switch block.kind {
        case .list(_, let items):
            1 + (items.flatMap(\.blocks).map(nestingDepth).max() ?? 0)
        case .blockQuote(let blocks):
            1 + (blocks.map(nestingDepth).max() ?? 0)
        case .heading, .paragraph, .codeBlock, .table, .thematicBreak:
            0
        }
    }

    private func collectIDs(_ block: MarkdownBlock, into ids: inout [Int]) {
        ids.append(block.id)
        switch block.kind {
        case .list(_, let items):
            for item in items {
                ids.append(item.id)
                for child in item.blocks {
                    collectIDs(child, into: &ids)
                }
            }
        case .blockQuote(let blocks):
            for child in blocks {
                collectIDs(child, into: &ids)
            }
        case .heading, .paragraph, .codeBlock, .table, .thematicBreak:
            break
        }
    }

    private func collectInlineText(_ block: MarkdownBlock, into texts: inout [AttributedString]) {
        switch block.kind {
        case .heading(_, let text, _), .paragraph(let text):
            texts.append(text)
        case .list(_, let items):
            for child in items.flatMap(\.blocks) {
                collectInlineText(child, into: &texts)
            }
        case .blockQuote(let blocks):
            for child in blocks {
                collectInlineText(child, into: &texts)
            }
        case .table(let table):
            texts.append(contentsOf: (table.header + table.rows.flatMap { $0 }).filter { !$0.characters.isEmpty })
        case .codeBlock, .thematicBreak:
            break
        }
    }
}
