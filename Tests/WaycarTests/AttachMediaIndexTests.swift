import Foundation
import Observation
import Synchronization
import Testing

@testable import Waycar

/// The Attach's printed-file discovery: which words of terminal output are
/// image or document paths a Host can serve, read the way Ghostty draws them.
@MainActor
@Suite("Attach media index")
struct AttachMediaIndexTests {
    private func makeIndex(receiving text: String) -> AttachMediaIndex {
        let index = AttachMediaIndex()
        index.receive(Data(text.utf8))
        return index
    }

    @Test func rootedHomeAndRelativeImagePathsAreKeptAsPrinted() {
        let index = makeIndex(
            receiving: "saved /tmp/a.png and ~/Pictures/b.JPG plus ./c.webp, out/d.heic: done\n"
                + "error at /tmp/err.png:12:3\n")

        #expect(
            index.paths == [
                "/tmp/err.png",
                "out/d.heic",
                "./c.webp",
                "~/Pictures/b.JPG",
                "/tmp/a.png",
            ])
    }

    @Test func bareImageNamesProseOtherFilesGlobsAndURLsAreNotTaken() {
        let index = makeIndex(
            receiving: """
                logo.png and/or src/main.swift docs/notes.txt out/clip.mp4
                *.png out/*.png out/shot?.png out/{a,b}.png $HOME/x.png out/frame_%04d.png
                https://cdn.example/a.png file:///tmp/a.png file:/tmp/b.png
                ~bob/a.png out/../../etc/x.png --out=x.png

                """)

        #expect(index.paths.isEmpty)
    }

    /// A Markdown or PDF document is taken with or without a folder, in any
    /// case: agents name the docs they write bare. Each path keeps its kind.
    @Test func markdownAndPDFPathsAreKeptWithOrWithoutAFolder() {
        let index = makeIndex(
            receiving: "wrote README.md and ./docs/spec.md, /tmp/notes.markdown ~/PLAN.MD\n"
                + "then report.pdf, out/Q3.PDF and notes.MARKDOWN; see /tmp/a.png\n")

        #expect(
            index.paths == [
                "/tmp/a.png",
                "notes.MARKDOWN",
                "out/Q3.PDF",
                "report.pdf",
                "~/PLAN.MD",
                "/tmp/notes.markdown",
                "./docs/spec.md",
                "README.md",
            ])
        #expect(
            index.candidates.map(\.kind) == [
                .image, .markdown, .pdf, .pdf, .markdown, .markdown, .markdown, .markdown,
            ])
    }

    /// Only a document may be bare. A hidden name with no extension, `.mdx`,
    /// audio, video, source and text are no strip file, and a document
    /// behind a glob, template, URL, another user's home, or a climb back
    /// out is no one file the Agent wrote.
    @Test func bareImagesHiddenNamesMDXOtherFilesAndGlobbedDocumentsAreNotTaken() {
        let index = makeIndex(
            receiving: """
                shot.png photo.JPG .md docs/.md *.md out/*.pdf notes.mdx docs/page.mdx
                song.mp3 out/talk.mov README.txt src/App.swift ~bob/a.md $HOME/a.md
                report_%02d.pdf https://example.com/a.pdf file:///tmp/a.md out/../../etc/a.md

                """)

        #expect(index.paths.isEmpty)
    }

    @Test func toolCallsMarkdownOptionsAndQuotedPathsYieldThePathInside() {
        let index = makeIndex(
            receiving: """
                ⏺ Read(/tmp/shot.png)
                ![alt](./out/md.png)
                --output=out/opt.png
                (see build/out(1).png).
                `/tmp/tick.png`

                """)

        #expect(
            index.paths == [
                "/tmp/tick.png",
                "build/out(1).png",
                "out/opt.png",
                "./out/md.png",
                "/tmp/shot.png",
            ])
    }

    /// A document's path is read out of a tool call, a Markdown link, a
    /// code span, a parenthetical, or an option's value, bare name included.
    @Test func toolCallsLinksAndOptionsYieldTheDocumentInside() {
        let index = makeIndex(
            receiving: """
                ⏺ Read(docs/plan.md)
                [spec](./spec.pdf)
                Wrote `README.md`.
                (see report.pdf)
                ⏺ Write(CHANGELOG.md)
                --output=summary.pdf

                """)

        #expect(
            index.paths == [
                "summary.pdf",
                "CHANGELOG.md",
                "report.pdf",
                "README.md",
                "./spec.pdf",
                "docs/plan.md",
            ])
    }

    @Test func tableRulesAroundACellAreNotPartOfThePath() {
        let index = makeIndex(
            receiving: """
                │ /tmp/a.png │
                |/tmp/b.png|
                │/tmp/c.png│
                ┃ `out/d.gif` ┃

                """)

        #expect(index.paths == ["out/d.gif", "/tmp/c.png", "/tmp/b.png", "/tmp/a.png"])
    }

    /// One byte per chunk splits every UTF-8 character and escape sequence.
    /// Styling inside a path is transparent, a box rule's bytes are text
    /// rather than C1 controls, and an OSC 8 link contributes its visible
    /// label, never its hidden target.
    @Test func pathsSurviveByteChunksStylingAndHyperlinks() {
        let index = AttachMediaIndex()
        let output =
            "│\u{1B}[1;31m/tmp/caf\u{1B}[0m\u{E9}.png\u{1B}[0m│ "
            + "\u{1B}]8;;file:///etc/hidden.png\u{1B}\\out/label.png\u{1B}]8;;\u{1B}\\\n"
            + "/tmp/cut\u{1B}[Kshort.png\n"

        for byte in Data(output.utf8) {
            index.receive(Data([byte]))
        }

        #expect(index.paths == ["out/label.png", "/tmp/caf\u{E9}.png"])
    }

    @Test func aPathEndedOnlyByTheEndOfOutputIsRecordedThen() {
        let index = makeIndex(receiving: "wrote out/tail.png")
        #expect(index.paths.isEmpty)

        index.finishOutput()

        #expect(index.paths == ["out/tail.png"])
    }

    @Test func anOversizedWordIsIgnoredWhole() {
        let oversized = "/tmp/" + String(repeating: "a", count: 4096) + ".png"

        let index = makeIndex(receiving: "\(oversized) /tmp/ok.png\n")

        #expect(index.paths == ["/tmp/ok.png"])
    }

    @Test func exactRepeatsMoveToFrontAndTheOldestPathIsEvictedPast25() {
        let index = makeIndex(receiving: "/tmp/a.png /tmp/b.png /tmp/c.png /tmp/a.png\n")
        #expect(index.paths == ["/tmp/a.png", "/tmp/c.png", "/tmp/b.png"])

        // Images and documents share the one bound.
        let crowded = AttachMediaIndex()
        let printed = (0...25).map { $0.isMultiple(of: 2) ? "/tmp/\($0).png" : "notes-\($0).md" }
        crowded.receive(Data(printed.joined(separator: "\n").utf8))
        crowded.finishOutput()

        #expect(crowded.paths.count == 25)
        #expect(crowded.paths.first == "notes-25.md")
        #expect(crowded.paths.last == "notes-1.md")
        #expect(!crowded.paths.contains("/tmp/0.png"))
    }

    @Test func clearingDropsPathsAndAnyPartialWord() {
        let index = makeIndex(receiving: "/tmp/a.png\n/tmp/partial")

        index.clear()
        index.receive(Data("/b.png\n".utf8))

        #expect(index.paths == ["/b.png"])
    }

    @Test func viewportRowsAreHardBoundariesAndDoNotRewriteStreamRecency() {
        let index = makeIndex(receiving: "/tmp/older.png\n/tmp/newer.png\n")

        index.receiveViewportText("/tmp/older.png\n/tmp/sp\nlit.png", columns: 80)

        #expect(index.paths == ["/tmp/newer.png", "/tmp/older.png"])
    }

    @Test func viewportKeepsOnlyTheLongestOfAnAmbiguousPrefixFamily() {
        let index = AttachMediaIndex()

        index.receiveViewportText("/tmp/shots/a.png", columns: 80)
        index.receiveViewportText("/tmp/shots/a.png.webp", columns: 80)
        #expect(index.paths == ["/tmp/shots/a.png.webp"])

        index.receiveViewportText("/tmp/shots/a.png", columns: 80)
        #expect(index.paths == ["/tmp/shots/a.png.webp"])
    }

    @Test func aStreamObservedPrefixSurvivesALongerViewportPath() {
        let index = makeIndex(receiving: "/tmp/shots/a.png\n")

        index.receiveViewportText("/tmp/shots/a.png.webp", columns: 80)

        #expect(index.paths == ["/tmp/shots/a.png.webp", "/tmp/shots/a.png"])
    }

    @Test func aStreamPathReplacesItsViewportOnlyPrefix() {
        let index = AttachMediaIndex()
        index.receiveViewportText("/tmp/shots/a.png", columns: 80)

        index.receive(Data("/tmp/shots/a.png.webp\n".utf8))

        #expect(index.paths == ["/tmp/shots/a.png.webp"])
    }

    /// The stream counts every print of a path; the screen only finds paths,
    /// at one sighting, and the stream's first print of one it found is
    /// that same sighting.
    @Test func streamRepeatsCountSightingsAndViewportRescansDoNot() {
        let index = makeIndex(receiving: "/tmp/a.png /tmp/b.png /tmp/a.png\n")
        #expect(
            index.candidates == [
                AttachMediaCandidate(path: "/tmp/a.png", sightings: 2, kind: .image),
                AttachMediaCandidate(path: "/tmp/b.png", sightings: 1, kind: .image),
            ])

        let screen = "/tmp/a.png\n/tmp/b.png\nout/screen.png"
        index.receiveViewportText(screen, columns: 80)
        index.receiveViewportText(screen, columns: 80)
        #expect(
            index.candidates == [
                AttachMediaCandidate(path: "out/screen.png", sightings: 1, kind: .image),
                AttachMediaCandidate(path: "/tmp/a.png", sightings: 2, kind: .image),
                AttachMediaCandidate(path: "/tmp/b.png", sightings: 1, kind: .image),
            ])

        index.receive(Data("out/screen.png /tmp/b.png\n".utf8))
        #expect(
            index.candidates == [
                AttachMediaCandidate(path: "/tmp/b.png", sightings: 2, kind: .image),
                AttachMediaCandidate(path: "out/screen.png", sightings: 1, kind: .image),
                AttachMediaCandidate(path: "/tmp/a.png", sightings: 2, kind: .image),
            ])

        index.receive(Data("out/screen.png\n".utf8))
        #expect(
            index.candidates.first
                == AttachMediaCandidate(path: "out/screen.png", sightings: 2, kind: .image))
    }

    /// An Agent's TUI redraws by cursor moves, so the stream can miss a path
    /// the screen then shows. Found later, it is still older than every path
    /// drawn below it, and a repeated snapshot moves nothing.
    @Test func aPathFoundOnlyOnScreenStandsByItsRowNotByWhenItWasFound() {
        let index = makeIndex(
            receiving: "\u{1B}[2J\u{1B}[Hshots/a.png\r\nshots/b.png\r\nshots/c.png\r\n"
                + "shots/d.png\r\nshots/e.png\r\nreport.pdf\r\ndocs/plan.md\r\n")
        #expect(
            index.paths == [
                "docs/plan.md", "report.pdf", "shots/e.png", "shots/d.png", "shots/c.png",
                "shots/b.png",
            ])

        let screen = """
            shots/a.png
            shots/b.png
            shots/c.png
            shots/d.png
            shots/e.png
            report.pdf
            docs/plan.md

            """
        index.receiveViewportText(screen, columns: 80)

        #expect(
            index.paths == [
                "docs/plan.md", "report.pdf", "shots/e.png", "shots/d.png", "shots/c.png",
                "shots/b.png", "shots/a.png",
            ])

        let settled = index.candidates
        index.receiveViewportText(screen, columns: 80)

        #expect(index.candidates == settled)
    }

    /// A document is read only when tapped: a TUI repainting the line that
    /// names it neither counts a sighting nor tells observers anything.
    @Test func aReprintedDocumentKeepsOneSightingAndChangesNothing() {
        let index = makeIndex(receiving: "wrote README.md\n")
        let changed = Mutex(false)
        withObservationTracking {
            _ = index.candidates
        } onChange: {
            changed.withLock { $0 = true }
        }

        index.receive(Data("wrote README.md\n\u{1B}[1Gwrote README.md\n".utf8))

        #expect(
            index.candidates == [
                AttachMediaCandidate(path: "README.md", sightings: 1, kind: .markdown)
            ])
        #expect(!changed.withLock { $0 })
    }

    /// A screen naming more files than the index keeps takes the lowest
    /// `maximumPathCount` at once, makes room only among paths the screen
    /// alone found, and settles: showing it again changes nothing.
    @Test func aCrowdedScreenKeepsStreamPathsAndSettles() {
        let index = makeIndex(receiving: "/tmp/a.png /tmp/b.png\n")
        let screen = (0..<30).map { "doc-\($0).md" }.joined(separator: "\n")

        index.receiveViewportText(screen, columns: 80)

        let settled = index.candidates
        #expect(settled.count == AttachMediaIndex.maximumPathCount)
        #expect(
            index.paths
                == (7..<30).reversed().map { "doc-\($0).md" } + ["/tmp/b.png", "/tmp/a.png"])

        let changed = Mutex(false)
        withObservationTracking {
            _ = index.candidates
        } onChange: {
            changed.withLock { $0 = true }
        }
        index.receiveViewportText(screen, columns: 80)

        #expect(index.candidates == settled)
        #expect(!changed.withLock { $0 })
    }

    /// A long path broken across rows at the grid's edge, as a multiplexer
    /// repaints a soft-wrapped line, is one path again; so is one an agent
    /// TUI wrapped onto an indented row.
    @Test func viewportRejoinsAPathBrokenAtTheRowEdge() {
        let path =
            "/Users/someuser/.herdr/worktrees/waycar/social-posts/docs/marketing/social/assets/ads/reddit/ad-02-4x3.png"
        let line = Array("⏺ Saved " + path)
        let columns = 30
        let rows = stride(from: 0, to: line.count, by: columns).map {
            String(line[$0..<min($0 + columns, line.count)])
        }
        let index = AttachMediaIndex()

        index.receiveViewportText(rows.joined(separator: "\n") + "\n  done", columns: columns)

        #expect(index.paths == [path])

        let indented = "  ⎿  Wrote /tmp/wrapped/sub"
        index.receiveViewportText(
            indented + "\n     dir/shot.png in place", columns: indented.count + 1)

        #expect(index.paths == ["/tmp/wrapped/subdir/shot.png", path])
    }

    /// Without its row's head, a path's tail is no relative path. A row
    /// that already ends in a whole image path does not run into the next.
    @Test func viewportTakesNoRelativePathStartingARowAfterOneBrokenAtTheEdge() {
        let index = AttachMediaIndex()

        index.receiveViewportText("x /tmp/a.png\nout/b.png\n  out/c.png", columns: 12)

        #expect(index.paths == ["out/c.png", "/tmp/a.png"])

        index.receiveViewportText("x /tmp/a.png\n/tmp/d.png\n", columns: 12)

        #expect(index.paths == ["/tmp/d.png", "out/c.png", "/tmp/a.png"])
    }

    /// A word starting where a cursor move landed is taken only as a rooted
    /// path: a relative reading may be a cut path's tail. Styling, erasing,
    /// and the blanks herdr pads a row with before it keep that; a bracket
    /// or a quote before the path does not. One byte per chunk carries it
    /// across chunks.
    @Test func streamTakesNoRelativePathStartingRightAfterACursorMove() {
        let index = AttachMediaIndex()
        let output =
            "\u{1B}[3;1Hsaved /Users/me/docs/mark\u{1B}[4;1Heting/ads/ad-02.png"
            + "\u{1B}[5;1H\u{1B}[1mout/styled.png\u{1B}[0m"
            + "\u{1B}[6;1H\u{1B}[Kdocs/erased.png"
            + "\u{1B}[7;3H  out/indented.png"
            + "\u{1B}[8;1H/tmp/abs.png"
            + "\u{1B}[9;1H~/x/home.png"
            + "\u{1B}[10;1H(out/paren.png)"
            + "\u{1B}[11;1H  \"out/quoted.png\"\n"

        for byte in Data(output.utf8) {
            index.receive(Data([byte]))
        }

        #expect(
            index.paths == [
                "out/quoted.png",
                "out/paren.png",
                "~/x/home.png",
                "/tmp/abs.png",
            ])
    }

    /// A bare document name never spans a row break, where wrapped prose
    /// would run its last word into the next row's name, nor starts where a
    /// cursor move landed, where it may be a cut path's tail. A document
    /// path naming a directory rejoins across the edge as an image path does.
    @Test func aBareDocumentNameNeverSpansARowBreakOrFollowsACursorMove() {
        let viewport = AttachMediaIndex()

        viewport.receiveViewportText(
            "Wrote to docs/\nREADME.md; see\nPLAN.md\nnotes.md", columns: 14)

        #expect(viewport.paths == ["notes.md", "docs/README.md"])

        let stream = makeIndex(receiving: "\u{1B}[3;1HREADME.md\u{1B}[4;1H(report.pdf)\n")

        #expect(stream.paths == ["report.pdf"])
    }

    /// Codex and OpenCode wrap their own text short of the grid's edge,
    /// breaking a path after a `-` or a `/`, and herdr pads the row with
    /// blanks (OpenCode's with its scrollbar `█`) before moving to the next.
    /// The tail is no relative path of its own, in the stream or on screen,
    /// and the screen reads a path whose tail has a `/` whole. Trimmed from
    /// captures of Codex 0.162 and OpenCode 1.19 at 120 columns.
    @Test func aPathAnAgentWrappedShortOfTheEdgeLeavesNoTail() {
        let codexStream = makeIndex(
            receiving: "\u{1B}]8;;\u{1B}\\. The plan is in `docs/plan.md` and the screenshot is "
                + "/tmp/harness-     \u{1B}[16;1H  audit/shot.png \u{2192}\u{1B}[16;19H see\n")
        #expect(codexStream.paths == ["docs/plan.md"])

        let openCodeStream = makeIndex(
            receiving: "the screenshot is /\u{1B}[0;38;2;255;255;255;48;2;20;20;20m  "
                + "\u{1B}[4;118H\u{1B}[0;38;2;72;72;72;48;2;30;30;30m█"
                + "\u{1B}[5;3H\u{1B}[0;38;2;92;156;245;48;2;10;10;10m┃"
                + "\u{1B}[5;4H\u{1B}[0;38;2;255;255;255;48;2;20;20;20m  "
                + "\u{1B}[0;38;2;238;238;238;48;2;20;20;20mtmp/harness-audit/shot.png \u{2192}\n")
        #expect(openCodeStream.paths.isEmpty)

        let codexScreen = AttachMediaIndex()
        codexScreen.receiveViewportText(
            """
            › Reply with exactly this markdown and nothing else, do not use any tools: Next, go to https://example.com/waycar/
              harness-audit/links-and-paths-check-0123456789. The plan is in `docs/plan.md` and the screenshot is /tmp/harness-
              audit/shot.png → see [the guide](https://example.org/guide/start) too.
            """,
            columns: 120)
        #expect(codexScreen.paths == ["/tmp/harness-audit/shot.png", "docs/plan.md"])

        func framed(_ text: String) -> String {
            text.padding(toLength: 117, withPad: " ", startingAt: 0) + "█"
        }
        let openCodeScreen = AttachMediaIndex()
        openCodeScreen.receiveViewportText(
            [
                framed("  ┃  Reply with exactly this markdown and nothing else, do not use any tools: Next, go to https://example.com/"),
                framed("  ┃  waycar/harness-audit/links-and-paths-check-0123456789. The plan is in `docs/plan.md` and the screenshot is /"),
                framed("  ┃  tmp/harness-audit/shot.png → see [the guide](https://example.org/guide/start) too."),
                framed(""),
                framed("     Next, go to https://example.com/waycar/harness-audit/links-and-paths-check-0123456789. The plan is in docs/"),
                framed("     plan.md and the screenshot is /tmp/harness-audit/shot.png → see the guide (https://example.org/guide/start)"),
            ].joined(separator: "\n"),
            columns: 120)
        #expect(openCodeScreen.paths == ["/tmp/harness-audit/shot.png", "docs/plan.md"])
    }

    /// A bullet, arrow, ellipsis or box rule glued to a path, and Markdown
    /// emphasis or a code span around it, are not part of it.
    @Test func glyphsAndMarkdownAroundAPathAreNotPartOfIt() {
        let index = makeIndex(
            receiving: """
                a **docs/one.md** b
                a docs/two.md… b
                a →docs/three.md b
                a docs/four.md→ b
                a •docs/five.md b
                a ⎿docs/six.md b
                │docs/seven.md│
                a `docs/eight.md` b
                a ●/tmp/nine.png b

                """)

        #expect(
            index.paths == [
                "/tmp/nine.png", "docs/eight.md", "docs/seven.md", "docs/six.md", "docs/five.md",
                "docs/four.md", "docs/three.md", "docs/two.md", "docs/one.md",
            ])
    }

    /// A row ending a sentence, above a row opening with a path, is no
    /// path's head: `it.` does not join `/tmp/…`, nor `release.` an
    /// indented `docs/…` — wherever the row ends, for a `.` above a name
    /// with a file's extension.
    @Test func aSentenceEndingARowAboveAPathStaysApart() {
        let index = AttachMediaIndex()

        index.receiveViewportText(
            """
            I saved it.
            /tmp/harness-audit/shot.png shows the result, see https://example.com.
            docs/plan.md has the details.
            Notes are written for the release.
              docs/release-notes.md
            """,
            columns: 80)

        #expect(
            index.paths == [
                "docs/release-notes.md", "docs/plan.md", "/tmp/harness-audit/shot.png",
            ])

        let edge = AttachMediaIndex()
        edge.receiveViewportText("Notes for the release.\ndocs/release-notes.md", columns: 22)

        #expect(edge.paths == ["docs/release-notes.md"])
    }

    /// A prose word ending a row two cells short of the edge is no path's
    /// head above a rooted path: Kilo and Maki wrap words with their rest
    /// unindented. The row is verbatim from captures of both at 120
    /// columns.
    @Test func aProseWordEndingARowNearTheEdgeStaysApartFromAPathBelow() {
        let row: String = "you> Reply with exactly: See https://example.com/waycar/untested/links-and-paths-check"
            + "-0123456789 and docs/plan.md and"
        let index = AttachMediaIndex()

        index.receiveViewportText(row + "\n/tmp/shot.png\nmaki> done", columns: 120)

        #expect(index.paths == ["/tmp/shot.png", "docs/plan.md"])
    }

    /// A box that wraps by character (Maki's input) cuts a word two cells
    /// short of the edge with its rest unindented: a path cut so is one
    /// path again, and a bare name cut so is no document of its own.
    @Test func aPathABoxCutShortOfItsEdgeRunsOn() {
        let rule = String(repeating: "─", count: 60)
        let screens: [(head: String, rest: String, paths: [String])] = [
            (head: "we keep the plan file at zz do", rest: "cs/plan.md and more", paths: ["docs/plan.md"]),
            (head: "we keep the plan file at READ", rest: "ME.md and more", paths: []),
        ]

        for screen in screens {
            let head = String(repeating: "y", count: 58 - screen.head.count) + screen.head
            let index = AttachMediaIndex()
            index.receiveViewportText([rule, head, screen.rest, rule].joined(separator: "\n"), columns: 60)

            #expect(index.paths == screen.paths)
        }
    }

    /// A path a TUI hard-wrapped at the edge reaches the stream as two
    /// words, the second where the cursor moved on to the next row's first
    /// column right after text reaching the edge (`/tmp` above
    /// `/shot.png`, as Hermes echoes a prompt): the tail is not taken on its
    /// own, and the screen reads the path whole. A path opening a row after
    /// one that ended short of the edge is taken. From a capture of Hermes
    /// at 60 columns.
    @Test func theRestOfAPathCutAtARowEndIsNotTakenFromTheStream() {
        let index = AttachMediaIndex()
        index.gridColumns = 60
        index.receive(
            Data("\u{1B}[36;40Hdocs/plan.md\u{1B}[36;53Hand\u{1B}[36;57H/tmp\u{1B}[37;1H/shot.png\n".utf8))

        #expect(index.paths.isEmpty)

        let row: String = String(repeating: " ", count: 39) + "docs/plan.md and /tmp"
        index.receiveViewportText(row + "\n/shot.png", columns: 60)

        #expect(index.paths == ["/tmp/shot.png", "docs/plan.md"])

        let shortRow = AttachMediaIndex()
        shortRow.gridColumns = 60
        shortRow.receive(Data("Saved the screenshot to\u{1B}[2;1H/tmp/shot.png for you\u{1B}[3;1H".utf8))

        #expect(shortRow.paths == ["/tmp/shot.png"])
    }

    /// A rule or box edge reaching the grid's edge is no path a TUI cut:
    /// the path opening the next row (below Hermes' `───┐`) is taken from
    /// the stream.
    @Test func aPathBelowARuleReachingTheEdgeIsTakenFromTheStream() {
        let rule: String = String(repeating: "─", count: 59) + "┐"
        let index = AttachMediaIndex()
        index.gridColumns = 60

        index.receive(Data("\u{1B}[5;1H\(rule)\u{1B}[6;1H/tmp/shot.png is ready\u{1B}[7;1H".utf8))

        #expect(index.paths == ["/tmp/shot.png"])
    }

    /// A row framed on both sides is a box's, no continuation of the
    /// unframed path above it that reaches the edge, as a tap reads it; a
    /// row a frame column opens but leaves open on the right (Kilo's `┃`)
    /// still carries the path on.
    @Test func aBoxRowBelowAnUnframedPathDoesNotCarryItOn() {
        let head: String = "~/plain/" + String(repeating: "p", count: 32)
        let screens: [(next: String, paths: [String])] = [
            (next: "│ th.png and more │", paths: []),
            (next: "┃ th.png and more", paths: [head + "th.png"]),
        ]

        for screen in screens {
            let index = AttachMediaIndex()
            index.receiveViewportText(head + "\n" + screen.next, columns: head.count)

            #expect(index.paths == screen.paths)
        }
    }

    /// A path a wrapper cut at the edge right after a dot directory's `.`
    /// runs on into the rest of it, as Pi prints `~/.agents/…`.
    @Test func aDotDirectoryCutAtTheEdgeRunsOn() {
        let screens = [
            (rows: ["see ~/.", "agents/skills/jev-browser/SKILL.md ok"], path: "~/.agents/skills/jev-browser/SKILL.md"),
            (rows: ["/Users/me/.", "claude/plans/plan-v1.2.md"], path: "/Users/me/.claude/plans/plan-v1.2.md"),
            (rows: [".", "github/workflows/README.md"], path: ".github/workflows/README.md"),
        ]

        for screen in screens {
            let index = AttachMediaIndex()
            index.receiveViewportText(
                screen.rows.joined(separator: "\n"), columns: screen.rows[0].count)

            #expect(index.paths == [screen.path])
        }
    }

    /// A prose dash ending a row carries no path on; a path's own `-` does.
    @Test func aProseDashEndingARowCarriesNoPathOn() {
        let screens = [
            (rows: ["I updated the plan -", "docs/plan.md now covers setup."], path: "docs/plan.md"),
            (rows: ["I updated the plan --", "docs/plan.md now covers setup."], path: "docs/plan.md"),
            (rows: ["⏺ I updated the docs -", "  README.md now covers setup."], path: "README.md"),
            (rows: ["the screenshot is /tmp/harness-", "  audit/shot.png → see"], path: "/tmp/harness-audit/shot.png"),
        ]

        for screen in screens {
            let index = AttachMediaIndex()
            index.receiveViewportText(screen.rows.joined(separator: "\n"), columns: 80)

            #expect(index.paths == [screen.path])
        }
    }

    /// Codex's welcome lists its slash commands, `/init - create an
    /// AGENTS.md file`: a bare document name describing a command is no file
    /// the Agent wrote, in the stream or on screen. A path, or the name on
    /// any other row, still is. Trimmed from a capture of Codex 0.162.
    @Test func aSlashCommandsDescriptionNamesNoDocument() {
        let stream = makeIndex(
            receiving: "\u{1B}[7;1H  /init\u{1B}[0;2;39;49m - create an AGENTS.md file with "
                + "instructions for Codex\u{1B}[8;1H  wrote NOTES.md\n")
        #expect(stream.paths == ["NOTES.md"])

        let screen = AttachMediaIndex()
        screen.receiveViewportText(
            """
              To get started, describe a task or try one of these commands:

              /init - create an AGENTS.md file with instructions for Codex
              /review - review docs/plan.md and README.md

            Wrote CHANGELOG.md
            """,
            columns: 120)
        #expect(screen.paths == ["CHANGELOG.md", "docs/plan.md"])
    }
}
