import Foundation
import Testing

@testable import Waycar

@Suite("Chat message text: tildes")
struct ChatMessageTextTildeTests {
    @Test func approximateTildesDoNotStrikeThrough() {
        // Unescaped, `~$200 … (~` is a strikethrough pair.
        let prose = "A used R6 body is ~$200 and the R6S (~$150) is the deal."
        let text = ChatMessageText.attributed(prose)
        #expect(runs(of: text, with: .strikethrough).isEmpty)
        #expect(String(text.characters) == prose)
    }

    @Test func doubleTildesStillStrikeThrough() {
        let text = ChatMessageText.attributed("The old flag is ~~gone~~ now.")
        #expect(runs(of: text, with: .strikethrough).joined() == "gone")
        #expect(String(text.characters) == "The old flag is gone now.")
    }

    @Test func tildeInCodeSpanStaysLiteral() {
        let text = ChatMessageText.attributed("Add it to `~/.zshrc` and ~/.bashrc.")
        #expect(runs(of: text, with: .code).joined() == "~/.zshrc")
        #expect(String(text.characters) == "Add it to ~/.zshrc and ~/.bashrc.")
        #expect(runs(of: text, with: .strikethrough).isEmpty)
    }

    @Test func boldAfterATildeIsBold() {
        let text = ChatMessageText.attributed("The body runs ~$200, but **R6S (~$150)** is the deal.")
        #expect(runs(of: text, with: .stronglyEmphasized).joined() == "R6S (~$150)")
        #expect(runs(of: text, with: .strikethrough).isEmpty)
    }

    @Test func loneTildesOutsideCodeRenderLiterally() {
        let text = ChatMessageText.attributed(#"a ~b ~~c~~ `~d` ``x ` ~e`` \~f"#)
        #expect(String(text.characters) == "a ~b c ~d x ` ~e ~f")
        #expect(runs(of: text, with: .strikethrough) == ["c"])
        #expect(runs(of: text, with: .code) == ["~d", "x ` ~e"])

        // An unclosed backtick opens no code span.
        let unclosed = ChatMessageText.attributed("tick ` then ~1")
        #expect(String(unclosed.characters) == "tick ` then ~1")
        #expect(runs(of: unclosed, with: .strikethrough).isEmpty)
        #expect(runs(of: unclosed, with: .code).isEmpty)
    }

    @Test func tripleTildesStayLiteral() {
        let text = ChatMessageText.attributed("~~~x~~~")
        #expect(String(text.characters) == "~~~x~~~")
        #expect(runs(of: text, with: .strikethrough).isEmpty)
    }

    @Test func aBareURLsTrailingTildeLeavesNoBackslash() throws {
        let prose = "Mirror at https://example.com/a~ for ~$150."
        let text = ChatMessageText.attributed(prose)
        #expect(String(text.characters) == prose)
        #expect(runs(of: text, with: .strikethrough).isEmpty)
        let link = try #require(links(in: text).first)
        #expect(link.absoluteString.hasPrefix("https://example.com/a"))
        #expect(!link.absoluteString.contains("%5C") && !link.absoluteString.contains("\\"))
    }

    @Test func bareURLKeepsItsTilde() throws {
        let prose = "About ~$200 at https://example.com/~deals/r6, or ~$150 used."
        let text = ChatMessageText.attributed(prose)
        #expect(links(in: text) == [try #require(URL(string: "https://example.com/~deals/r6"))])
        #expect(String(text.characters) == prose)
        #expect(runs(of: text, with: .strikethrough).isEmpty)
    }

    @Test func angleAutolinkKeepsItsTilde() throws {
        let text = ChatMessageText.attributed("See <https://example.com/~user> for ~$150.")
        #expect(links(in: text) == [try #require(URL(string: "https://example.com/~user"))])
        #expect(String(text.characters) == "See https://example.com/~user for ~$150.")
        #expect(runs(of: text, with: .strikethrough).isEmpty)
    }

    @Test func inlineLinkDestinationKeepsItsTilde() throws {
        let text = ChatMessageText.attributed("Was ~$200, [now](https://example.com/~sale) ~$150.")
        #expect(links(in: text) == [try #require(URL(string: "https://example.com/~sale"))])
        #expect(runs(of: text, with: .strikethrough).isEmpty)
    }

    private func links(in text: AttributedString) -> [URL] {
        text.runs.compactMap(\.link)
    }

    private func runs(of text: AttributedString, with intent: InlinePresentationIntent) -> [String] {
        text.runs.compactMap { run in
            guard run.inlinePresentationIntent?.contains(intent) == true else { return nil }
            return String(text[run.range].characters)
        }
    }
}

@Suite("Chat message text: segments")
struct ChatMessageTextSegmentTests {
    @Test func fencesSplitProseAndCode() {
        #expect(
            ChatMessageText.segments(of: "Run this:\n```sh\nmake test\n```\nDone.")
                == [.prose("Run this:"), .code("make test"), .prose("Done.")])
    }

    @Test func withoutMediaEveryReferenceStaysText() {
        let text = "Look:\n/tmp/a.png\n![Chart](/tmp/chart.png)"
        #expect(ChatMessageText.segments(of: text) == [.prose(text)])
    }

    @Test func linesThatAreOnlyMediaFormOneGroup() {
        let text = """
            Here you go:
            /Users/me/shot.png
            ~/Movies/demo.mp4
            https://example.com/cat.webp
            - docs/diagram.jpg
            That is all.
            """
        #expect(
            describe(text) == [
                "prose Here you go:",
                "media image file /Users/me/shot.png | video file ~/Movies/demo.mp4 | "
                    + "image web https://example.com/cat.webp | image file docs/diagram.jpg",
                "prose That is all.",
            ])
    }

    @Test func absolutePathAloneMayHaveSpaces() {
        #expect(
            describe("/Users/me/Desktop/Screenshot 2026-10-01 at 10.00.png")
                == ["media image file /Users/me/Desktop/Screenshot 2026-10-01 at 10.00.png"])
    }

    @Test func markdownImageRendersInPlace() {
        #expect(
            describe("Before\n![Chart](/tmp/chart.png \"Weekly\")\nAfter")
                == ["prose Before", "media image file /tmp/chart.png [Chart]", "prose After"])
        #expect(
            describe("See ![the chart](docs/chart.png) for details.")
                == ["prose See", "media image file docs/chart.png [the chart]", "prose for details."])
    }

    @Test func pathInASentenceStaysTextAndItsMediaFollows() {
        let text = "I saved it to /tmp/out.png for you.\nAnything else?"
        #expect(describe(text) == ["prose \(text)", "media image file /tmp/out.png"])
        #expect(
            describe("Saved [the clip](https://example.com/clip.mov).\n\nNext paragraph.")
                == [
                    "prose Saved [the clip](https://example.com/clip.mov).",
                    "media video web https://example.com/clip.mov",
                    "prose Next paragraph.",
                ])
    }

    @Test(arguments: [
        "Updated logo.png and the docs.",
        "http://example.com/a.png",
        "/tmp/notes.txt",
        "https://example.com/page",
        "![x](http://example.com/a.png)",
        "file:///tmp/a.png",
    ])
    func nonMediaStaysText(_ text: String) {
        #expect(describe(text) == ["prose \(text)"])
    }

    @Test func codeBlocksNeverRenderMedia() {
        #expect(
            ChatMessageText.segments(of: "```\n/tmp/a.png\n```", rendersMedia: true)
                == [.code("/tmp/a.png")])
        #expect(
            ChatMessageText.segments(of: "```\n`/tmp/a.png`\n```", rendersMedia: true)
                == [.code("`/tmp/a.png`")])
    }

    @Test func repeatedReferenceShowsOnce() {
        #expect(describe("/tmp/a.png\n/tmp/a.png") == ["media image file /tmp/a.png"])
    }

    // MARK: Code spans

    /// "Saved to `/tmp/out.png`.": the span stays code, and its image
    /// follows the paragraph like a sentence's path.
    @Test func codeSpanThatIsOneRootedImagePathShowsItsImage() {
        let text = "Saved to `/tmp/out.png`.\nAnything else?"
        #expect(describe(text) == ["prose \(text)", "media image file /tmp/out.png"])
        #expect(describe("`/tmp/a.png`") == ["prose `/tmp/a.png`", "media image file /tmp/a.png"])
        #expect(
            describe("Open `~/shots/a.png` there.")
                == ["prose Open `~/shots/a.png` there.", "media image file ~/shots/a.png"])
        #expect(
            describe("Double: `` /tmp/b.JPEG ``")
                == ["prose Double: `` /tmp/b.JPEG ``", "media image file /tmp/b.JPEG"])
    }

    @Test func codeSpanMediaFollowsReadingOrder() {
        let text = "Before `/tmp/a.png`, then /tmp/b.png and `/tmp/c.webp`."
        #expect(
            describe(text) == [
                "prose \(text)",
                "media image file /tmp/a.png | image file /tmp/b.png | image file /tmp/c.webp",
            ])
    }

    @Test(arguments: [
        "Run `cat /tmp/a.png` now.",
        "Open `a.png` there.",
        "Open `docs/a.png` there.",
        "All of `/tmp/*.png` changed.",
        "One of `/tmp/shot?.png` changed.",
        "Each `~/${name}.png` file.",
        "Each `/tmp/{a,b}.png` file.",
        "Watch `/tmp/clip.mp4` now.",
        "Read `/tmp/notes.txt` first.",
        "Fetch `https://example.com/a.png` later.",
    ])
    func otherCodeSpansStayCode(_ text: String) {
        #expect(describe(text) == ["prose \(text)"])
    }

    @Test func codeSpanPathDedupesWithTheSamePathInTheSentence() {
        let text = "Wrote /tmp/a.png (see `/tmp/a.png`)."
        #expect(describe(text) == ["prose \(text)", "media image file /tmp/a.png"])
    }

    @Test func codeSpanPathsCountTowardTheCap() {
        let spans = (1...(ChatMediaReferences.maximumPerMessage + 3)).map { "`/tmp/\($0).png`" }
        let text = "Saved " + spans.joined(separator: " ") + "."
        let media = ChatMessageText.segments(of: text, rendersMedia: true).flatMap { segment -> [ChatMedia] in
            if case .media(let items, _) = segment { items } else { [] }
        }
        #expect(media.count == ChatMediaReferences.maximumPerMessage)
        #expect(media.first?.id == "ref:/tmp/1.png")
    }

    @Test func codeSpanMediaIsAHostImageReference() {
        #expect(
            ChatMediaReferences.codeSpanMedia(in: ArraySlice(Array("`/tmp/out.png`")))
                == ChatMedia(
                    id: "ref:/tmp/out.png", kind: .image, mime: nil, source: .hostFile(path: "/tmp/out.png"),
                    alt: nil))
    }

    // MARK: Tables

    @Test(arguments: [
        "|/tmp/shot.png|2.1 MB|",
        "| /tmp/shot.png | 2.1 MB |",
        "│/tmp/shot.png│",
        "│ /tmp/shot.png │ 2.1 MB │",
        "|name|/tmp/shot.png|",
    ])
    func pathInATableCellShowsItsImage(_ text: String) {
        #expect(describe(text) == ["prose \(text)", "media image file /tmp/shot.png"])
    }

    // MARK: Failures

    /// A sentence's or code span's path stays in the prose, so its failed
    /// fetch hides; a standalone line or Markdown image leaves the prose,
    /// so its failed tile stays to retry.
    @Test func onlyMediaWhosePathStaysInTheProseFailSilently() {
        #expect(silentFailures("Wrote /tmp/a.png and `/tmp/b.png`.") == [["ref:/tmp/a.png", "ref:/tmp/b.png"]])
        #expect(silentFailures("/tmp/chart.png") == [[]])
        #expect(silentFailures("See ![chart](/tmp/chart.png)") == [[]])
    }

    /// A sentence's media joining a standalone line's group keeps each
    /// item's own failure handling.
    @Test func aGroupMixesSilentAndShownFailures() {
        let text = "Wrote /tmp/a.png.\n/tmp/b.png"
        #expect(describe(text) == ["prose Wrote /tmp/a.png.", "media image file /tmp/a.png | image file /tmp/b.png"])
        #expect(silentFailures(text) == [["ref:/tmp/a.png"]])
    }

    private func silentFailures(_ text: String) -> [Set<ChatMedia.ID>] {
        ChatMessageText.segments(of: text, rendersMedia: true).compactMap { segment in
            if case .media(_, let silent) = segment { silent } else { nil }
        }
    }

    private func describe(_ text: String) -> [String] {
        ChatMessageText.segments(of: text, rendersMedia: true).map { segment in
            switch segment {
            case .prose(let prose): return "prose \(prose)"
            case .code(let code): return "code \(code)"
            case .media(let media, _): return "media " + media.map(describe).joined(separator: " | ")
            }
        }
    }

    private func describe(_ media: ChatMedia) -> String {
        let source: String
        switch media.source {
        case .hostFile(let path): source = "file \(path)"
        case .web(let url): source = "web \(url.absoluteString)"
        case .inline, .sessionInline: source = "inline"
        }
        return "\(media.kind.rawValue) \(source)" + (media.alt.map { " [\($0)]" } ?? "")
    }
}
