import Foundation
import Testing

@testable import Waycar

@MainActor
@Suite("Attach user message index")
struct AttachUserMessageIndexTests {
    @Test func assemblesALineAcrossChunksIncludingAUTF8BoundarySplit() {
        let index = AttachUserMessageIndex()
        let text = "请实现这个解析器功能"
        let bytes = Array(text.utf8)
        #expect(bytes.count > 4)

        index.observeOutgoing(Data(bytes.prefix(1)))
        #expect(index.entries.isEmpty)
        index.observeOutgoing(Data(bytes.dropFirst(1).dropLast(2)))
        index.observeOutgoing(Data(bytes.suffix(2)))
        #expect(index.entries.isEmpty)

        index.observeOutgoing(Data([0x0D]))
        #expect(index.entries.map(\.rawText) == [text])
    }

    @Test func assemblesASCIIAcrossSeveralChunksThenCloses() {
        let index = AttachUserMessageIndex()
        index.observeOutgoing(Data("please ".utf8))
        index.observeOutgoing(Data("implement ".utf8))
        index.observeOutgoing(Data("the parser".utf8))
        index.observeOutgoing(Data([0x0D]))
        #expect(index.entries.map(\.rawText) == ["please implement the parser"])
    }

    @Test(arguments: [UInt8(0x7F), UInt8(0x08)])
    func backspaceRemovesTheLastCharacterBeforeSubmit(_ backspace: UInt8) {
        let index = AttachUserMessageIndex()
        index.observeOutgoing(Data("please implement the parserx".utf8))
        index.observeOutgoing(Data([backspace]))
        index.observeOutgoing(Data([0x0D]))
        #expect(index.entries.map(\.rawText) == ["please implement the parser"])
    }

    @Test func backspaceEditsAChineseCharacterNotItsUTF8Bytes() {
        let index = AttachUserMessageIndex()
        index.observeOutgoing(Data("请实现这个解析器功错".utf8))
        index.observeOutgoing(Data([0x7F]))
        index.observeOutgoing(Data("能".utf8))
        index.observeOutgoing(Data([0x0D]))
        #expect(index.entries.map(\.rawText) == ["请实现这个解析器功能"])
    }

    @Test(arguments: [
        Data([0x1B, 0x5B, 0x44]),
        Data([0x1B, 0x5B, 0x31, 0x3B, 0x32, 0x43]),
        Data([0x1B, 0x4F, 0x41]),
    ])
    func controlSequencesDoNotLandInTheIndexedText(_ sequence: Data) throws {
        let index = AttachUserMessageIndex()
        index.observeOutgoing(Data("please ".utf8))
        index.observeOutgoing(sequence)
        index.observeOutgoing(Data("implement the parser".utf8))
        index.observeOutgoing(Data([0x0D]))
        let raw = try #require(index.entries.first).rawText
        #expect(raw == "please implement the parser")
        #expect(!raw.contains("\u{1B}"))
    }

    @Test func aCSISequenceSplitAcrossChunksIsStillSkipped() {
        let index = AttachUserMessageIndex()
        index.observeOutgoing(Data("please ".utf8))
        index.observeOutgoing(Data([0x1B]))
        index.observeOutgoing(Data([0x5B, 0x44]))
        index.observeOutgoing(Data("implement the parser".utf8))
        index.observeOutgoing(Data([0x0D]))
        #expect(index.entries.map(\.rawText) == ["please implement the parser"])
    }

    @Test func csiIntermediateBytesAreSkipped() {
        let index = AttachUserMessageIndex()
        index.observeOutgoing(Data("please ".utf8))
        // CSI 2 SP q (DECSCUSR): SP is an intermediate byte (0x20).
        index.observeOutgoing(Data([0x1B, 0x5B, 0x32, 0x20, 0x71]))
        index.observeOutgoing(Data("implement the parser".utf8))
        index.observeOutgoing(Data([0x0D]))
        #expect(index.entries.map(\.rawText) == ["please implement the parser"])
    }

    @Test func anSS3SequenceSplitAfterEscapeIsStillSkipped() {
        let index = AttachUserMessageIndex()
        index.observeOutgoing(Data("please ".utf8))
        index.observeOutgoing(Data([0x1B]))
        index.observeOutgoing(Data([0x4F, 0x41]))
        index.observeOutgoing(Data("implement the parser".utf8))
        index.observeOutgoing(Data([0x0D]))
        #expect(index.entries.map(\.rawText) == ["please implement the parser"])
    }

    @Test func anSS3SequenceSplitAfterTheIntroducerIsStillSkipped() {
        let index = AttachUserMessageIndex()
        index.observeOutgoing(Data("please ".utf8))
        index.observeOutgoing(Data([0x1B, 0x4F]))
        index.observeOutgoing(Data([0x41]))
        index.observeOutgoing(Data("implement the parser".utf8))
        index.observeOutgoing(Data([0x0D]))
        #expect(index.entries.map(\.rawText) == ["please implement the parser"])
    }

    /// `0x9B` and `0x8F` are C1 CSI and SS3 only as a lone byte. Inside a
    /// UTF-8 scalar they are continuation bytes: `▛` is `E2 96 9B`, `🏏` is
    /// `F0 9F 8F 8F`. Split so the next write starts on `9B`.
    @Test func aTypedGlyphWhoseUTF8CarriesAC1ByteIsText() {
        let index = AttachUserMessageIndex()
        index.observeOutgoing(Data("please draw ".utf8) + Data([0xE2, 0x96]))
        index.observeOutgoing(Data([0x9B]) + Data(" and 🏏 now".utf8))
        index.observeOutgoing(Data([0x0D]))
        #expect(index.entries.map(\.rawText) == ["please draw ▛ and 🏏 now"])
    }

    @Test(arguments: [UInt8(0x0D), UInt8(0x0A)])
    func carriageReturnAndLineFeedBothCloseALine(_ terminator: UInt8) {
        let index = AttachUserMessageIndex()
        index.observeOutgoing(Data("please implement the parser".utf8))
        index.observeOutgoing(Data([terminator]))
        #expect(index.entries.map(\.rawText) == ["please implement the parser"])
    }

    @Test func aComposerInsertedMultilineDraftIsOneEntryAtSubmit() {
        let index = AttachUserMessageIndex()
        index.observeOutgoing(
            Data("please approve\nthen continue".utf8),
            source: .composerInsert)
        #expect(index.entries.isEmpty)
        index.observeOutgoing(Data([0x0D]))
        #expect(index.entries.map(\.rawText) == ["please approve\nthen continue"])
    }

    @Test(arguments: [
        "",
        "   ",
        "\t\t",
        "ok",
        "y",
        "1234567",
    ])
    func rejectsEmptyAndShortLines(_ text: String) {
        let index = AttachUserMessageIndex()
        index.observeOutgoing(Data(text.utf8))
        index.observeOutgoing(Data([0x0D]))
        #expect(index.entries.isEmpty)
    }

    @Test func acceptsALineAtTheMinimumCharacterCount() {
        let index = AttachUserMessageIndex()
        index.observeOutgoing(Data("12345678".utf8))
        index.observeOutgoing(Data([0x0D]))
        #expect(index.entries.map(\.rawText) == ["12345678"])
    }

    @Test func crlfClosesOnce() {
        let index = AttachUserMessageIndex()
        index.observeOutgoing(Data("please implement the parser\r\n".utf8))
        #expect(index.entries.map(\.rawText) == ["please implement the parser"])
    }

    @Test(arguments: [
        ("❯ please implement the parser", "please implement the parser"),
        ("› please implement the parser", "please implement the parser"),
        ("> please implement the parser", "please implement the parser"),
        ("▎ please implement the parser", "please implement the parser"),
        ("  please implement the parser", "please implement the parser"),
        ("│ please implement the parser", "please implement the parser"),
        ("▎❯ please implement the parser", "please implement the parser"),
    ])
    func normalizeStripsLeadingPromptAndBoxGlyphs(_ input: String, _ expected: String) {
        #expect(AttachUserMessageIndex.normalize(input) == expected)
    }

    @Test func normalizeJoinsASoftWrappedBoxSoItMatchesTheTypedLine() {
        let typed = "please implement the parser for user messages"
        let frame = """
            ▎ please implement the
            ▎ parser for user messages
            """
        #expect(AttachUserMessageIndex.normalize(frame) == typed)

        let index = AttachUserMessageIndex()
        index.record(submitted: typed)
        #expect(index.frameContainsMessage(frame))
    }

    @Test func frameContainsMessageIsFalseWhenTheFrameHasNoIndexedText() {
        let index = AttachUserMessageIndex()
        index.record(submitted: "please implement the parser")
        #expect(
            !index.frameContainsMessage(
                "the agent is thinking about a completely different topic"))
    }

    /// A message opens where a row's text starts with it. Agent prose that
    /// quotes it mid-row is not the message: matching there marked the
    /// message as already seen and cost the walk its real stop.
    @Test func aMessageQuotedInsideAgentProseIsNotFound() {
        let index = AttachUserMessageIndex()
        index.record(submitted: "please implement the parser")
        #expect(
            !index.frameContainsMessage(
                "The user asked: please implement the parser\nI'll start there."))
        #expect(index.frameContainsMessage("     please implement the parser\n I'll start there."))
    }

    @Test func frameContainsMessageMatchesABoundedPrefixOfALongEntry() {
        let long = String(repeating: "a", count: 120)
        let index = AttachUserMessageIndex()
        index.record(submitted: long)
        #expect(
            index.frameContainsMessage(
                String(repeating: "a", count: AttachUserMessageIndex.matchPrefixCharacterCount)))
        #expect(!index.frameContainsMessage(String(repeating: "b", count: 64)))
    }

    /// Round 1 of testloop, against a live Grok TUI at phone width. The TUI
    /// right-aligns the send time into the message's own first row, so the
    /// whole-frame join reads `...reply with the 7:49 PM word Charlie...` and
    /// no 64-character head of the submitted text is a substring of it.
    @Test func frameContainsMessageSurvivesAGutterTimestampOnTheMessageRow() {
        let submitted = "Test loop probe Charlie, reply with the word Charlie and change nothing"
        let frame = """
            ❯ Test loop probe Charlie, reply with the        7:49 PM
              word Charlie and change nothing
            """
        let index = AttachUserMessageIndex()
        index.record(submitted: submitted)

        #expect(!AttachUserMessageIndex.normalize(frame).contains(submitted))
        #expect(index.frameContainsMessage(frame))
    }

    /// The extension asked for after Round 1: history the user scrolled back
    /// through is jumpable even though this session submitted none of it.
    @Test func promptLinesAreTargetsWithoutAnySubmittedMessage() {
        let index = AttachUserMessageIndex()
        let keys = index.visibleMessageKeys(
            """
            ❯ what does the transport do when preflight fails
              and the host denies forwarding
            The answer is in ADR 0011.
            › a second question from another device
            """)

        #expect(index.entries.isEmpty)
        #expect(keys.count == 2)
    }

    /// A prompt line's key must not change as its message scrolls in a row at
    /// a time, or the jump loop reads one message as several.
    @Test func promptLineKeyIsStableAsTheMessageScrollsIn() {
        let index = AttachUserMessageIndex()
        let firstRowOnly = index.visibleMessageKeys(
            "❯ what does the transport do when preflight fails        7:49 PM")
        let fullyVisible = index.visibleMessageKeys(
            """
            ❯ what does the transport do when preflight fails        7:52 PM
              and the host denies forwarding
            """)

        #expect(!firstRowOnly.isEmpty)
        #expect(firstRowOnly == fullyVisible)
    }

    /// Captured from a live Claude Code pane scrolled back by wheel reports.
    /// Its user turns carry `❯`, its own turns `⏺`, and its tool output `⎿` —
    /// only the first is a jump target. `refs #268`.
    @Test func aScrolledClaudeFrameYieldsItsUserTurnsOnly() {
        let index = AttachUserMessageIndex()
        let keys = index.visibleMessageKeys(
            """
            ❯ herdr 没办法动

            ⏺ herdr 不动的话，iOS 这边只剩一条路径，先验证它有没有数据。

            ⎿  $ herdr pane read w2:p3 --source recent --lines 400
                 > /tmp/out.txt

            ❯ 从 ios 方面想办法

            ────────────────────────────────────────────
            ❯
            ────────────────────────────────────────────
            """)

        #expect(keys == ["line:herdr 没办法动", "line:从 ios 方面想办法"])
    }

    /// The length gate counted characters, so an ordinary Chinese prompt was
    /// silently not a jump target: `安装到我手机上` is seven characters but a
    /// whole sentence. Reported from device use. `refs #268`.
    @Test func aShortChineseMessageIsStillAJumpTarget() {
        let index = AttachUserMessageIndex()
        #expect(!index.visibleMessageKeys("❯ 安装到我手机上").isEmpty)

        index.record(submitted: "安装到我手机上")
        #expect(index.entries.count == 1)
    }

    /// The gate still has to drop the messages it exists for: keys are the
    /// message's own text, so two identical short replies collide into one
    /// target.
    @Test func aTwoCharacterReplyIsNotAJumpTarget() {
        let index = AttachUserMessageIndex()
        #expect(index.visibleMessageKeys("❯ 继续").isEmpty)
        #expect(index.visibleMessageKeys("> ok").isEmpty)

        index.record(submitted: "继续")
        #expect(index.entries.isEmpty)
    }

    /// An empty input box is drawn on every frame; it must not be a target.
    @Test func anEmptyPromptLineIsNotATarget() {
        let index = AttachUserMessageIndex()
        #expect(index.visibleMessageKeys("❯\n───────────").isEmpty)
    }

    /// Codex opens its session with `>_ OpenAI Codex (v0.152.0)`, which the
    /// walk stopped on until a prompt glyph had to be followed by a space.
    @Test func aGlyphNotFollowedByASpaceIsNotAPrompt() {
        let index = AttachUserMessageIndex()
        #expect(index.visibleMessageKeys(">_ OpenAI Codex (v0.152.0)").isEmpty)
        #expect(!index.visibleMessageKeys("> a genuine question from the user").isEmpty)
    }

    /// One row of an OpenCode frame as herdr repaints it: two columns of
    /// indent, then the row, then OpenCode's `█` scrollbar in the last column.
    private static func openCodeRow(_ text: String) -> String {
        "  " + text + String(repeating: " ", count: 6) + "\u{2588}"
    }

    /// Rows captured from OpenCode 1.19 over herdr at 120 columns. Its user
    /// turn is a `┃`-bordered cell with no prompt glyph; only the cell's first
    /// text row is the key, so the message is one target.
    @Test func anOpenCodeUserCellIsOneTarget() {
        let index = AttachUserMessageIndex()
        let frame = [
            "",
            Self.openCodeRow("┃"),
            Self.openCodeRow(
                "┃  Reply with exactly this markdown and nothing else, do not use any tools: Next, go to https://example.com/"),
            Self.openCodeRow(
                "┃  waycar/harness-audit/links-and-paths-check-0123456789. The plan is in `docs/plan.md` and the screenshot is /"),
            Self.openCodeRow(
                "┃  tmp/harness-audit/shot.png → see [the guide](https://example.org/guide/start) too."),
            Self.openCodeRow("┃"),
            "",
            "     + Thought: 7.4s",
            "",
            "     Next, go to https://example.com/waycar/harness-audit/links-and-paths-check-0123456789.",
            "",
            "     ▣  Build · Nemotron 3.5 Lightning Free · 9.9s",
        ].joined(separator: "\n")

        #expect(index.visibleMessageKeys(frame) == [
            "line:Reply with exactly this markdown and nothing else, do not use any tools: Next, go to https://example.com/"
        ])
    }

    /// OpenCode's other `┃` panels: the input box, closed by `╹▀▀▀` (here
    /// holding a typed draft and its agent footer), and a tool block, whose
    /// title sits five columns inside the border.
    @Test func openCodePanelsThatAreNotUserTurnsAreNotTargets() {
        let index = AttachUserMessageIndex()
        let frame = [
            "",
            "  ┃",
            "  ┃     # Bash list the files in the workspace",
            "  ┃",
            "  ┃  $ ls -la /private/tmp/harness-audit/ws-opencode",
            "  ┃",
            "",
            "  ┃",
            "  ┃  a draft the user has not submitted yet",
            "  ┃",
            "  ┃  Build · Nemotron 3.5 Lightning Free OpenCode Zen",
            "  ╹▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀",
            "   /private/tmp/harness-audit/ws-opencode        27.6K (11%)  ctrl+p commands",
        ].joined(separator: "\n")

        #expect(index.visibleMessageKeys(frame).isEmpty)
    }

    @Test func recordSubmittedIndexesComposerTextWithoutATerminator() {
        let index = AttachUserMessageIndex()
        index.record(submitted: "please implement the parser")
        #expect(index.entries.map(\.rawText) == ["please implement the parser"])
        #expect(index.entries.map(\.normalizedText) == ["please implement the parser"])
    }

    @Test func resetClearsEntriesAndPendingBytes() {
        let index = AttachUserMessageIndex()
        index.record(submitted: "please implement the parser")
        index.observeOutgoing(Data("leftover pending".utf8))
        index.reset()
        #expect(index.entries.isEmpty)

        index.observeOutgoing(Data("please implement the parser".utf8))
        index.observeOutgoing(Data([0x0D]))
        #expect(index.entries.map(\.rawText) == ["please implement the parser"])
    }

    @Test func escapeCancelsAComposerInsertedPendingLine() {
        let index = AttachUserMessageIndex()
        index.observeOutgoing(Data("please approve".utf8), source: .composerInsert)
        index.observeOutgoing(Data([0x1B]), source: .escapeKey)
        index.observeOutgoing(Data([0x0D]))
        #expect(index.entries.isEmpty)
    }

    @Test func escapeThenANewRequestDoesNotKeepComposerInsertedText() {
        let index = AttachUserMessageIndex()
        index.observeOutgoing(Data("please approve".utf8), source: .composerInsert)
        index.observeOutgoing(Data([0x1B]), source: .escapeKey)
        index.observeOutgoing(Data("new request".utf8))
        index.observeOutgoing(Data([0x0D]))
        #expect(index.entries.map(\.rawText) == ["new request"])
    }

    @Test func escapeKeyThenABracketRequestDoesNotKeepComposerInsertedText() {
        let index = AttachUserMessageIndex()
        index.observeOutgoing(Data("please approve".utf8), source: .composerInsert)
        index.observeOutgoing(Data([0x1B]), source: .escapeKey)
        index.observeOutgoing(Data("[review] do it".utf8))
        index.observeOutgoing(Data([0x0D]))
        #expect(index.entries.map(\.rawText) == ["[review] do it"])
    }

    @Test func keystrokeEscapeAfterComposerInsertCancelsBeforeABracketRequest() {
        let index = AttachUserMessageIndex()
        index.observeOutgoing(Data("please approve".utf8), source: .composerInsert)
        index.observeOutgoing(Data([0x1B]))
        index.observeOutgoing(Data("[review] do it".utf8))
        index.observeOutgoing(Data([0x0D]))
        #expect(index.entries.map(\.rawText) == ["[review] do it"])
    }

    @Test func keystrokeEscapePreservesPendingText() {
        let index = AttachUserMessageIndex()
        index.observeOutgoing(Data("please implement ".utf8))
        index.observeOutgoing(Data([0x1B]))
        index.observeOutgoing(Data("the parser".utf8))
        index.observeOutgoing(Data([0x0D]))
        #expect(index.entries.map(\.rawText) == ["please implement the parser"])
    }

    @Test func capsEntriesByDroppingTheOldest() {
        let index = AttachUserMessageIndex()
        for i in 0...AttachUserMessageIndex.maximumEntryCount {
            let n = String(format: "%03d", i)
            index.record(submitted: "message number \(n) is long enough")
        }
        #expect(index.entries.count == AttachUserMessageIndex.maximumEntryCount)
        #expect(index.entries.first?.rawText == "message number 001 is long enough")
        #expect(index.entries.last?.rawText == "message number 200 is long enough")
    }

    // MARK: User turns named by the Agent's transcript

    /// Pi's user turns, typed on the Host, are plain text at column 5 set
    /// apart only by a background colour: the screen alone names none. Its
    /// transcript names both, and each is one target on the captured rows.
    @Test func piUserTurnsTypedOnTheHostAreTargetsOnceItsTranscriptNamesThem() {
        let index = AttachUserMessageIndex()
        let frame = HarnessJumpCaptures.piRows.joined(separator: "\n")
        #expect(index.visibleMessageKeys(frame).isEmpty)

        index.receiveTranscript(HarnessJumpCaptures.piTranscript)

        #expect(index.visibleMessageKeys(frame) == ["transcript:45516a4b", "transcript:2748e3ed"])
    }

    /// Pi's thinking, its reply and its tool narration are on the same rows
    /// as the user turn's neighbours; none of them is a user turn.
    @Test func piAssistantRowsAreNotTargets() {
        let index = AttachUserMessageIndex()
        index.receiveTranscript(HarnessJumpCaptures.piTranscript)
        let rows = HarnessJumpCaptures.piRows
        // Thinking and reply of the first turn; thinking, tool narration
        // and reply of the second.
        for range in [2..<15, 17..<34] {
            #expect(index.visibleMessageKeys(rows[range].joined(separator: "\n")).isEmpty)
        }
    }

    /// omp draws its user turn at column 1, exactly like its own reply.
    @Test func ompUserTurnsAreTargetsAndItsRepliesAreNot() {
        let index = AttachUserMessageIndex()
        let rows = HarnessJumpCaptures.ompRows
        #expect(index.visibleMessageKeys(rows.joined(separator: "\n")).isEmpty)

        index.receiveTranscript(HarnessJumpCaptures.ompTranscript)

        #expect(
            index.visibleMessageKeys(rows.joined(separator: "\n"))
                == ["transcript:512f6c9a", "transcript:b7e5720f"])
        // Its reply, the fast-mode warning, the bulleted reply and the editor.
        #expect(index.visibleMessageKeys(rows[12..<22].joined(separator: "\n")).isEmpty)
        #expect(index.visibleMessageKeys(rows[25...].joined(separator: "\n")).isEmpty)
    }

    /// OpenCode's error panel is a user cell's exact shape, so the shape
    /// alone stops on it. Its transcript records the error as the reply, so
    /// once it covers the conversation only the user cells are targets.
    @Test func openCodeErrorPanelIsNotATargetOnceTheTranscriptCoversTheConversation() {
        let index = AttachUserMessageIndex()
        let frame = HarnessJumpCaptures.openCodeErrorRows.joined(separator: "\n")
        let guessed = index.visibleMessageKeys(frame)
        #expect(guessed.contains { $0.hasPrefix("line:Unauthorized:") })
        #expect(guessed.contains("line:Give one fun fact about starfish regenerating"))

        index.receiveTranscript(HarnessJumpCaptures.openCodeTranscript)

        #expect(
            index.visibleMessageKeys(frame) == [
                "transcript:msg_12c4194be001gLVjnlnf3ByT1T",
                "transcript:msg_12c426e39001Coup7CbHAQjydF",
            ])
    }

    /// The "message reverted" banner is a user cell's shape too. Only real
    /// user cells are targets once the transcript is known.
    @Test func openCodeRevertBannerIsNotATargetOnceTheTranscriptCoversTheConversation() {
        let index = AttachUserMessageIndex()
        let frame = HarnessJumpCaptures.openCodeRevertRows.joined(separator: "\n")
        #expect(index.visibleMessageKeys(frame).contains("line:1 message reverted"))

        index.receiveTranscript(HarnessJumpCaptures.openCodeTranscript)

        let keys = index.visibleMessageKeys(frame)
        #expect(!keys.contains { $0.hasPrefix("line:") })
        #expect(keys.contains("transcript:msg_12c40a78a001QUeVzI7qvHwRYn"))
        #expect(keys.contains("transcript:msg_12c4194be001gLVjnlnf3ByT1T"))
    }

    /// A transcript the reader cut to its newest messages cannot vouch for
    /// the cells above them, so a cell it does not name keeps its shape's
    /// key, the error panel's included.
    @Test func aCutTranscriptLeavesOpenCodeCellsToTheirShape() {
        let index = AttachUserMessageIndex()
        index.receiveTranscript(HarnessJumpCaptures.openCodeTranscript.cut(keepingLast: 2))
        let keys = index.visibleMessageKeys(
            HarnessJumpCaptures.openCodeErrorRows.joined(separator: "\n"))
        #expect(keys.contains("line:Now list three facts about sea urchins, as a"))
        #expect(keys.contains { $0.hasPrefix("line:Unauthorized:") })
        #expect(keys.contains("transcript:msg_12c426e39001Coup7CbHAQjydF"))
        #expect(keys.count == 3)
    }

    /// A failed read keeps the turns an earlier one named; a Host with no
    /// transcript for the Agent drops them, back to the screen alone.
    @Test func aFailedReadKeepsKnownTurnsAndAMissingTranscriptDropsThem() {
        let index = AttachUserMessageIndex()
        let frame = HarnessJumpCaptures.piRows.joined(separator: "\n")
        index.receiveTranscript(HarnessJumpCaptures.piTranscript)

        index.receiveTranscript(HarnessJumpCaptures.transcript(kind: "pi", status: .error))
        #expect(index.visibleMessageKeys(frame).count == 2)

        index.receiveTranscript(HarnessJumpCaptures.transcript(kind: "pi", status: .notFound))
        #expect(index.visibleMessageKeys(frame).isEmpty)
    }

    @Test func resetDropsTranscriptTurns() {
        let index = AttachUserMessageIndex()
        index.receiveTranscript(HarnessJumpCaptures.piTranscript)
        index.reset()
        #expect(
            index.visibleMessageKeys(HarnessJumpCaptures.piRows.joined(separator: "\n")).isEmpty)
    }

    // MARK: Kind marks, input boxes and menus

    /// Keys a frame of `rows` shows under `kind`'s jump profile.
    private func keys(_ rows: some Sequence<String>, kind: String) -> Set<String> {
        let profile = AgentMessageJumpProfile.forAgentKind(kind)
        let index = AttachUserMessageIndex(
            maximumPromptIndent: profile.maximumPromptIndent,
            userTurnMark: profile.userTurnMark)
        return index.visibleMessageKeys(rows.joined(separator: "\n"))
    }

    private static let replyKey = "line:Reply with exactly: See"

    /// Kimi Code marks its user's turn `✨` and answers behind `●`.
    @Test func kimiTurnsAreTargetsAndItsRepliesAreNot() {
        let rows = UntestedAgentCaptures.kimiRows
        #expect(keys(rows, kind: "kimi") == [Self.replyKey])
        #expect(keys(rows[3..<8], kind: "kimi").isEmpty)
        // Another kind's rules leave a Kimi reply alone too.
        #expect(keys(rows[3..<8], kind: "hermes").isEmpty)
    }

    /// Maki marks its user's turn `you>`, its own reply `maki>`, and a tool
    /// call `●`; its input box shows `❯` and a placeholder.
    @Test func makiTurnsAreTargetsAndItsRepliesToolsAndInputBoxAreNot() {
        let rows = UntestedAgentCaptures.makiRows
        #expect(keys(rows, kind: "maki") == [Self.replyKey])
        #expect(keys(rows[3..<13], kind: "maki").isEmpty)
        #expect(keys(UntestedAgentCaptures.makiStartupComposerRows, kind: "maki").isEmpty)
    }

    /// Hermes draws its user's turn `●` between two rules; its reasoning and
    /// reply are boxed.
    @Test func hermesTurnsAreTargetsAndItsReasoningAndReplyAreNot() {
        let rows = UntestedAgentCaptures.hermesRows
        #expect(keys(rows, kind: "hermes") == [Self.replyKey])
        #expect(keys(rows[..<15], kind: "hermes").isEmpty)
        #expect(keys(rows[19...], kind: "hermes").isEmpty)
        // Without its rule above, a `●` row is not a Hermes turn.
        #expect(keys(rows[16...], kind: "hermes").isEmpty)
    }

    /// Mastra Code bands its user's turn in `▄`/`▀` rows; its input box is
    /// the same band opening on `→`.
    @Test func mastraTurnsAreTargetsAndItsReplyAndInputBoxAreNot() {
        let rows = UntestedAgentCaptures.mastraRows
        #expect(keys(rows, kind: "mastracode") == [Self.replyKey])
        #expect(keys(rows[7...], kind: "mastracode").isEmpty)
    }

    /// Each kind's own mark is no mark for another: a `✨`, `you>` or band
    /// row means nothing to an Agent that draws a prompt glyph.
    @Test func kindMarksStayWithTheirKind() {
        for rows in [
            UntestedAgentCaptures.kimiRows, UntestedAgentCaptures.makiRows,
            UntestedAgentCaptures.hermesRows, UntestedAgentCaptures.mastraRows,
        ] {
            #expect(keys(rows, kind: "claude").isEmpty)
        }
    }

    /// Qwen boxes its input between rules: the placeholder and the
    /// suggestion it shows there are not turns; its sent turns still are.
    @Test func qwenInputBoxIsNotATargetAndItsTurnsAre() {
        let rows = UntestedAgentCaptures.qwenRows
        #expect(keys(rows, kind: "qwen") == ["line:Reply with exactly: See https://example.com/waycar/untes"])
        #expect(keys(rows[16...], kind: "qwen").isEmpty)
        #expect(keys(UntestedAgentCaptures.qwenPlaceholderRows, kind: "qwen").isEmpty)
    }

    /// Cline's input box shows `❯ Ask anything...`, or the draft being
    /// typed; only its sent turns are targets.
    @Test func clineInputBoxIsNotATargetAndItsTurnsAre() {
        let turn = "line:Reply with exactly: See https://example.com/waycar/"
        #expect(keys(UntestedAgentCaptures.clineRows, kind: "cline") == [turn])
        #expect(keys(UntestedAgentCaptures.clineRows[14...], kind: "cline").isEmpty)
        #expect(keys(UntestedAgentCaptures.clineDraftRows, kind: "cline") == [turn])
        #expect(keys(UntestedAgentCaptures.clineDraftRows[4...], kind: "cline").isEmpty)
    }

    /// A selection menu's cursor row is a prompt glyph before a numbered
    /// choice, with an `↑/↓` hint below.
    @Test(arguments: [
        ("agy", UntestedAgentCaptures.agyMenuRows),
        ("qodercli", UntestedAgentCaptures.qoderTrustRows),
        ("qodercli", UntestedAgentCaptures.qoderSignInRows),
    ])
    func selectionMenusAreNotTargets(_ kind: String, _ rows: [String]) {
        #expect(keys(rows, kind: kind).isEmpty)
    }

    /// A numbered list the user sent has no key hint under it.
    @Test func aNumberedListTheUserSentIsStillATarget() {
        let rows = ["> 1. fix the failing parser tests", "  2. then add docs", "", "⏺ Done."]
        #expect(keys(rows, kind: "claude") == ["line:1. fix the failing parser tests"])
    }

    // MARK: Review fixes

    /// OpenCode cell `Answer two things:` / `- say hi` / `- say bye…`, its
    /// first text row shorter than the probe and the scrollbar thumb on it.
    /// The transcript must keep the cell a target, under the turn's key.
    @Test func anOpenCodeCellWithAShortFirstRowUnderTheThumbStaysATarget() {
        let frame = HarnessJumpCaptures.openCodeShortFirstLineRows.joined(separator: "\n")
        #expect(AttachUserMessageIndex().visibleMessageKeys(frame) == ["line:Answer two things:"])

        let index = AttachUserMessageIndex()
        index.receiveTranscript(HarnessJumpCaptures.openCodeShortFirstLineTranscript)

        #expect(index.visibleMessageKeys(frame) == ["transcript:msg_12c9e2985001HAmulORCWlpddg"])
    }

    /// Two Pi turns typed on the Host open with the same 24 characters
    /// (`Please answer briefly: w`). Each frame names only the turn it shows.
    @Test func turnsThatOpenAlikeAreTwoTargets() {
        let index = AttachUserMessageIndex()
        index.receiveTranscript(HarnessJumpCaptures.piSharedOpeningTranscript)
        let rows = HarnessJumpCaptures.piSharedOpeningRows

        #expect(index.visibleMessageKeys(rows[..<12].joined(separator: "\n")) == ["transcript:5424d6a4"])
        #expect(index.visibleMessageKeys(rows[12...].joined(separator: "\n")) == ["transcript:3586a2c5"])
        #expect(
            index.visibleMessageKeys(rows.joined(separator: "\n"))
                == ["transcript:5424d6a4", "transcript:3586a2c5"])
        // Cut off after its first row, a turn still shows once its opening
        // characters are on screen.
        #expect(index.visibleMessageKeys(rows[12]) == ["transcript:3586a2c5"])
    }

    /// Mastra Code's first frame after attach stacks three `▄` rows while its
    /// band repaints; none of them is a turn.
    @Test func aStackedMastraBandIsNotATarget() {
        #expect(keys(UntestedAgentCaptures.mastraFirstFrameRows, kind: "mastracode").isEmpty)
    }

    /// Hermes's input is ruled off only above and runs to the bottom of the
    /// screen; a draft sitting in it is not a turn.
    @Test(arguments: [0, 3])
    func aHermesDraftIsNotATarget(trailingBlankRows: Int) {
        let rows =
            UntestedAgentCaptures.hermesDraftRows
            + Array(repeating: "", count: trailingBlankRows)
        #expect(keys(rows, kind: "hermes").isEmpty)
    }

    /// Kimi Code boxes its input in `╭─╮`/`╰─╯`; a draft in it is not a turn.
    @Test func aKimiDraftIsNotATarget() {
        #expect(keys(UntestedAgentCaptures.kimiDraftRows, kind: "kimi").isEmpty)
    }

    /// Copilot's boxed trust menu, as captured and with its cursor moved to
    /// each longer choice.
    @Test(arguments: [nil, 15, 16])
    func copilotsBoxedMenuIsNotATarget(cursorRow: Int?) {
        var rows = UntestedAgentCaptures.copilotTrustRows
        if let cursorRow { rows = Self.movingCursor(in: rows, from: 14, to: cursorRow) }
        #expect(keys(rows, kind: "copilot").isEmpty)
    }

    /// Droid's login menu has no key hint; its choices sit right above and
    /// below the cursor.
    @Test(arguments: [nil, 3])
    func droidsLoginMenuIsNotATarget(cursorRow: Int?) {
        var rows = UntestedAgentCaptures.droidLoginRows
        if let cursorRow { rows = Self.movingCursor(in: rows, from: 2, to: cursorRow) }
        #expect(keys(rows, kind: "droid").isEmpty)
    }

    /// A menu whose choices wrap and run past a dozen rows before its hint.
    @Test func aLongMenuWithWrappedChoicesIsNotATarget() {
        var rows = ["❯ 1. Allow this command to run in the current workspace"]
        for choice in 2...8 {
            rows += ["  \(choice). Allow every command like this one for the rest of", "     the session"]
        }
        rows += ["", "  ↑/↓ to navigate · enter to select"]
        #expect(keys(rows, kind: "claude").isEmpty)
    }

    // MARK: Second review fixes

    /// An earlier turn that the newer one starts with (`continue please`,
    /// then `continue please with the docs…`) claims neither the newer cell
    /// nor the newer Pi turn, however the newer one wraps, so Up from the
    /// newer turn still finds the older one new.
    @Test(arguments: [false, true])
    func anOlderTurnThatOpensANewerOneDoesNotClaimIt(wrapsAfterTheOlder: Bool) {
        let older = "continue please"
        let newer = ["continue please with the docs for the parser"]
        let newerRows =
            wrapsAfterTheOlder ? ["continue please", "with the docs for the parser"] : newer
        let transcript = HarnessJumpCaptures.transcript(
            kind: "opencode",
            messages: [("u1", .user, older), ("a1", .assistant, "Done."),
                       ("u2", .user, newer[0]), ("a2", .assistant, "Done.")])

        let openCode = AttachUserMessageIndex()
        openCode.receiveTranscript(transcript)
        let newerFrame = Self.openCodeFrame(cells: [newerRows])
        #expect(openCode.visibleMessageKeys(newerFrame) == ["transcript:u2"])
        let olderFrame = Self.openCodeFrame(cells: [[older]])
        #expect(openCode.visibleMessageKeys(olderFrame) == ["transcript:u1"])

        let pi = AttachUserMessageIndex()
        pi.receiveTranscript(transcript)
        #expect(pi.visibleMessageKeys(Self.piFrame(turn: newerRows)) == ["transcript:u2"])
        #expect(pi.visibleMessageKeys(Self.piFrame(turn: [older])) == ["transcript:u1"])
    }

    /// A short turn opens only a row that starts with it: the reply prose
    /// under the newer OpenCode cell mentions `run the tests`, and the older
    /// cell is still new when Up reaches it.
    @Test func aTurnQuotedInAReplyIsNotThatTurn() {
        let index = AttachUserMessageIndex()
        index.receiveTranscript(
            HarnessJumpCaptures.transcript(
                kind: "opencode",
                messages: [("u1", .user, "run the tests"), ("a1", .assistant, "All green."),
                           ("u2", .user, "Now write the docs for the parser module")]))
        let live =
            Self.openCodeFrame(cells: [["Now write the docs for the parser module"]])
            + "\n     Before writing docs I will run the tests again to be"
            + "\n     sure nothing regressed."

        #expect(index.visibleMessageKeys(live) == ["transcript:u2"])
        let olderCell = Self.openCodeFrame(cells: [["run the tests"]])
        #expect(index.visibleMessageKeys(olderCell) == ["transcript:u1"])
    }

    /// A turn typed with two spaces after a full stop runs on past the
    /// double space, where a TUI's gutter would start: Pi, omp and an
    /// OpenCode cell under a covering transcript all still find it.
    @Test func aTurnTypedWithADoubleSpaceIsFound() {
        let typed = "Fix the parser first.  Then add docs for the module please."
        let transcript = HarnessJumpCaptures.transcript(
            kind: "pi", messages: [("u1", .user, typed)])
        let rows = ["Fix the parser first.  Then add docs for the", "module please."]

        let pi = AttachUserMessageIndex()
        pi.receiveTranscript(transcript)
        #expect(pi.visibleMessageKeys(Self.piFrame(turn: rows)) == ["transcript:u1"])

        let openCode = AttachUserMessageIndex()
        openCode.receiveTranscript(transcript)
        #expect(openCode.visibleMessageKeys(Self.openCodeFrame(cells: [rows])) == ["transcript:u1"])

        let omp = AttachUserMessageIndex()
        omp.record(submitted: typed)
        #expect(omp.frameContainsMessage(rows.map { " \($0)" }.joined(separator: "\n")))
    }

    /// A Claude or Codex reply that mentions both arrows, or a user turn
    /// whose wrapped row opens with one, is no menu hint: the turn stays a
    /// target.
    @Test(arguments: [
        ("claude", ["> Add keyboard navigation to the picker list", "",
                    "⏺ Added ↑/↓ navigation to the picker list."],
         "line:Add keyboard navigation to the picker list"),
        ("codex", ["› Bind the arrow keys in the picker", "",
                   "• Bound ↑ and ↓ to move the selection."],
         "line:Bind the arrow keys in the picker"),
        ("codex", ["› Make the list navigable with keys,", "  ↑ moves up and ↓ moves down",
                   "", "• Done."],
         "line:Make the list navigable with keys,"),
    ])
    func arrowsInATurnOrReplyAreNoMenuHint(_ kind: String, _ rows: [String], _ key: String) {
        #expect(keys(rows, kind: kind) == [key])
    }

    /// `continue please`, then `continue please` / `with the docs for the
    /// parser` with a hard newline: a frame cut right after the newer
    /// turn's first row, or partway into its second, may be either turn
    /// and names neither. Shown whole, each names only itself.
    @Test func aFrameCutInsideALongerTurnNamesNeitherTurn() {
        let index = AttachUserMessageIndex()
        index.receiveTranscript(
            HarnessJumpCaptures.transcript(
                kind: "pi",
                messages: [
                    ("u1", .user, "continue please"),
                    ("u2", .user, "continue please\nwith the docs for the parser"),
                ]))
        let prose = " Ran the parser suite; all passed."

        let bottomEdge = [prose, "", "     continue please"]
        #expect(index.visibleMessageKeys(bottomEdge.joined(separator: "\n")).isEmpty)
        #expect(
            index.visibleMessageKeys(
                [prose, "", "     continue please", "     with the"].joined(separator: "\n")).isEmpty)
        #expect(
            index.visibleMessageKeys(
                ["     continue please", "     with the docs for the parser", prose]
                    .joined(separator: "\n")) == ["transcript:u2"])
        #expect(
            index.visibleMessageKeys(["     continue please", prose].joined(separator: "\n"))
                == ["transcript:u1"])
    }

    /// How each transcript harness draws a turn, a reply and its captured
    /// input box, for `continue please` and the newer `continue please` /
    /// `with the docs for the parser`.
    enum PinnedFooterHarness: CaseIterable, Sendable {
        case pi, omp, openCode

        var kind: String {
            switch self {
            case .pi: "pi"
            case .omp: "omp"
            case .openCode: "opencode"
            }
        }

        /// A user turn's rows, its padding included unless the message list
        /// is cut right after its text (`closed: false`).
        func turn(_ rows: [String], closed: Bool = true) -> [String] {
            switch self {
            case .pi: rows.map { "     \($0)" }
            case .omp: [""] + rows.map { " \($0)" } + (closed ? [""] : [])
            case .openCode: ["", "  ┃"] + rows.map { "  ┃  \($0)" } + (closed ? ["  ┃"] : [])
            }
        }

        /// A reply row, at the harness's reply indent.
        var reply: String {
            self == .openCode ? "     Ran the parser suite." : " Ran the parser suite."
        }

        /// The input box pinned under the message list, as captured.
        var footer: [String] {
            switch self {
            case .pi: HarnessJumpCaptures.piFooterRows
            case .omp: Array(HarnessJumpCaptures.ompRows[35...])
            case .openCode: Array(HarnessJumpCaptures.openCodeErrorRows[41...])
            }
        }
    }

    /// The message list ends at the input box pinned under it as it does at
    /// the frame's edge. With only the newer turn's first row above the box,
    /// the frame may show either turn and names neither; the older turn
    /// with its reply under it, or the newer turn whole, names only itself.
    @Test(arguments: PinnedFooterHarness.allCases)
    func aPrefixTurnAboveTheInputBoxNamesOnlyItself(_ harness: PinnedFooterHarness) {
        let index = AttachUserMessageIndex()
        index.receiveTranscript(
            HarnessJumpCaptures.transcript(
                kind: harness.kind,
                messages: [
                    ("u1", .user, "continue please"),
                    ("a1", .assistant, "Done."),
                    ("u2", .user, "continue please\nwith the docs for the parser"),
                ]))
        func keys(_ list: [String]) -> Set<String> {
            index.visibleMessageKeys(
                ([harness.reply, ""] + list + harness.footer).joined(separator: "\n"))
        }
        let newerFirstRow = harness.turn(["continue please"], closed: false)
        let older = harness.turn(["continue please"]) + ["", harness.reply]
        let newer = harness.turn(["continue please", "with the docs for the parser"])

        #expect(keys(newerFirstRow).isEmpty)
        #expect(keys(older) == ["transcript:u1"])
        #expect(keys(newer) == ["transcript:u2"])
    }

    /// Pi's editor holding a draft is still the input box: the newer turn's
    /// first row right above it names neither turn, and the older turn with
    /// its reply names itself.
    @Test func aPrefixTurnAbovePisEditorWithADraftNamesOnlyItself() {
        let index = AttachUserMessageIndex()
        index.receiveTranscript(
            HarnessJumpCaptures.transcript(
                kind: "pi",
                messages: [
                    ("u1", .user, "continue please"),
                    ("a1", .assistant, "Done."),
                    ("u2", .user, "continue please\nwith the docs for the parser"),
                ]))
        var footer = HarnessJumpCaptures.piFooterRows
        footer[1] = "fix the build"
        func keys(_ list: [String]) -> Set<String> {
            let frame = [" Ran the parser suite.", ""] + list + footer
            return index.visibleMessageKeys(frame.joined(separator: "\n"))
        }

        #expect(keys(["     continue please"]).isEmpty)
        #expect(keys(["     continue please", " Ran the parser suite."]) == ["transcript:u1"])
    }

    /// A rule or tool box inside Pi's message list is no input box: the
    /// older turn `continue please` right above one still names itself,
    /// with the newer `continue please` / `with the docs…` off screen or
    /// shown whole further down, above Pi's captured footer.
    @Test(arguments: [false, true])
    func aRuleOrToolBoxInsideTheListEndsNoMatch(isToolBox: Bool) {
        let rule = String(repeating: "─", count: 58)
        let toolBox = [
            "╭─ bash " + rule.dropLast(7) + "╮",
            "│ npm test" + String(repeating: " ", count: 49) + "│",
            "╰" + rule + "╯",
        ]
        let separator = isToolBox ? toolBox : ["──" + rule]
        let index = AttachUserMessageIndex()
        index.receiveTranscript(
            HarnessJumpCaptures.transcript(
                kind: "pi",
                messages: [
                    ("u1", .user, "continue please"),
                    ("a1", .assistant, "Done."),
                    ("u2", .user, "continue please\nwith the docs for the parser"),
                ]))
        let older = [" Ran the parser suite.", "", "     continue please"] + separator
            + [" Ran the tests and they passed.", ""]
        let newer = ["     continue please", "     with the docs for the parser", " Done."]
        func keys(_ list: [String]) -> Set<String> {
            let frame = list + HarnessJumpCaptures.piFooterRows
            return index.visibleMessageKeys(frame.joined(separator: "\n"))
        }

        #expect(keys(older) == ["transcript:u1"])
        #expect(keys(older + newer) == ["transcript:u1", "transcript:u2"])
    }

    /// OpenCode 1.19's user cells (`HarnessJumpCaptures.openCodeErrorRows`),
    /// each followed by a reply row.
    private static func openCodeFrame(cells: [[String]]) -> String {
        cells.flatMap { cell in
            ["", "  ┃"] + cell.map { "  ┃  \($0)" } + ["  ┃", "", "     Done."]
        }.joined(separator: "\n")
    }

    /// A Pi user turn at column 5 (`HarnessJumpCaptures.piRows`) and its reply.
    private static func piFrame(turn: [String]) -> String {
        (turn.map { "     \($0)" } + [" Done."]).joined(separator: "\n")
    }

    /// `rows` with the menu cursor moved from row `from` to row `to`, as the
    /// arrow keys move it.
    private static func movingCursor(in rows: [String], from: Int, to: Int) -> [String] {
        var rows = rows
        var source = Array(rows[from])
        var target = Array(rows[to])
        guard let column = source.firstIndex(where: { $0 == "❯" || $0 == ">" }),
            column < target.count
        else { return rows }
        target[column] = source[column]
        source[column] = " "
        rows[from] = String(source)
        rows[to] = String(target)
        return rows
    }
}

/// Real screens and transcripts, captured over `herdr terminal attach` at
/// 60 columns (rows emulated with pyte, trailing blanks dropped) from one
/// session per harness, every prompt typed on the Host: Pi 0.80.6
/// (gemini-2.5-flash-lite via OpenRouter), omp 18.9.1 (Haiku 4.5) and
/// OpenCode 1.19.0, whose third turn ran on a model with a bad key. Each
/// transcript is the plugin reader's answer (`plugin/src/chat-read.js`) for
/// that session.
enum HarnessJumpCaptures {
    /// Pi's message area. User turns (rows 0–1, 15–16) sit on a `#343541`
    /// background, which the text does not carry.
    static let piRows = [
        #"     Reply with two short sentences about otters swimming"#,
        #"     in kelp forests."#,
        #" Crafting Otter Narratives"#,
        #""#,
        #" I'm focusing on describing the otters' playful"#,
        #" interactions within their kelp forest habitat. The request"#,
        #" is simple, requiring only imaginative prose without"#,
        #" external tools."#,
        #""#,
        #" Otters frolic gracefully through swaying kelp forests,"#,
        #" their sleek bodies navigating the underwater forest with"#,
        #" playful agility. These marine mammals find shelter and"#,
        #" sustenance among the dense fronds, creating a vibrant"#,
        #" ecosystem."#,
        #""#,
        #"     Now list three facts about sea urchins, as a bulleted"#,
        #"     list please."#,
        #" Searching for Sea Urchin Facts"#,
        #""#,
        #" I'm currently focused on gathering three key facts about"#,
        #" sea urchins. To accomplish this, I'm utilizing a web"#,
        #" search tool to find the most accurate and relevant"#,
        #" information. The immediate next step involves executing a"#,
        #" search query for "facts about sea urchins.""#,
        #""#,
        #" Gathering Sea Urchin Details"#,
        #""#,
        #" I'm narrowing down my focus to identify three distinct"#,
        #" facts regarding sea urchins. My current approach involves"#,
        #" leveraging a web search tool for this purpose. I am"#,
        #" proceeding with a direct search for "facts about sea"#,
        #" urchins" to procure the necessary information."#,
        #" I am sorry, I cannot fulfill this request. The"#,
        #" firecrawl-search tool is not available."#,
    ]

    static let piTranscript = transcript(
        kind: "pi",
        messages: [
            ("45516a4b", .user, "Reply with two short sentences about otters swimming in kelp forests."),
            (
                "999dfa82", .assistant,
                "Otters frolic gracefully through swaying kelp forests, their sleek bodies navigating "
                    + "the underwater forest with playful agility. These marine mammals find shelter "
                    + "and sustenance among the dense fronds, creating a vibrant ecosystem."
            ),
            ("2748e3ed", .user, "Now list three facts about sea urchins, as a bulleted list please."),
            (
                "ead9bb11", .assistant,
                "I am sorry, I cannot fulfill this request. The `firecrawl-search` tool is not available."
            ),
        ])

    /// omp's screen from its banner to its editor. User turns (rows 9–12,
    /// 22–25, padding included) sit on a `#073642` background at column 1,
    /// like its reply.
    static let ompRows = [
        #""#,
        #"              ████████████"#,
        #"                 ██  ██       ▄▀▀▄ █▀▄▀▄ █▀▀▄"#,
        #"                 ██  ██       ▀▄▄▀ █ █ █ █▄▄▀"#,
        #"                 ▒▒  ██                  █"#,
        #"                     ██       v18.9.1"#,
        #""#,
        #"        Tip: Psst, omp has a natural habitat 🐦 tern"#,
        #""#,
        #""#,
        #" Reply with two short sentences about otters swimming in"#,
        #" kelp forests."#,
        #""#,
        #""#,
        #" Sea otters dive through kelp forests gripping prey like"#,
        #" sea urchins and crabs with their paws. Their dense fur and"#,
        #" rapid metabolism keep them warm while hunting among the"#,
        #" swaying kelp canopy."#,
        #""#,
        #" Warning: priority: Priority/fast mode rejected for this"#,
        #" model; retried without it. Fast mode is now off."#,
        #""#,
        #""#,
        #" Now list three facts about sea urchins, as a bulleted list"#,
        #" please."#,
        #""#,
        #""#,
        #" - Sea urchins are covered in spines that protect them from"#,
        #"   predators and help them move across the ocean floor."#,
        #" - They graze on kelp and algae, and their populations"#,
        #"   explode when otters are absent, causing kelp forest"#,
        #"   collapse."#,
        #" - Sea urchins have no brain but possess a distributed"#,
        #"   nervous system that allows them to sense light,"#,
        #"   chemicals, and touch."#,
        #""#,
        #"╭── π > ◔ Haiku 4.5 🙈 > 🗑 …ilder ▶─7%───────────┃──200K───╮"#,
        #"╰─                                                        ─╯"#,
    ]

    static let ompTranscript = transcript(
        kind: "omp",
        messages: [
            ("512f6c9a", .user, "Reply with two short sentences about otters swimming in kelp forests."),
            (
                "b38441f5", .assistant,
                "Sea otters dive through kelp forests gripping prey like sea urchins and crabs with "
                    + "their paws. Their dense fur and rapid metabolism keep them warm while hunting "
                    + "among the swaying kelp canopy."
            ),
            ("b7e5720f", .user, "Now list three facts about sea urchins, as a bulleted list please."),
            (
                "aa1a2b22", .assistant,
                "- Sea urchins are covered in spines that protect them from predators and help them "
                    + "move across the ocean floor.\n- They graze on kelp and algae, and their "
                    + "populations explode when otters are absent, causing kelp forest collapse.\n"
                    + "- Sea urchins have no brain but possess a distributed nervous system that "
                    + "allows them to sense light, chemicals, and touch."
            ),
        ])

    /// OpenCode's message list (rows 0–40, its scrollbar's extent), a blank
    /// row, then its input box (rows 42–48).
    /// The error panel (rows 34–38) has the user cells' shape; on screen its
    /// border is red where theirs is blue.
    static let openCodeErrorRows = [
        #"     + Thought: 463ms"#,
        #""#,
        #"     Sea otters glide through kelp forests, wrapping"#,
        #"     themselves in swaying fronds to anchor against the"#,
        #"     current. Their fur glistens as they float and dive"#,
        #"     among the emerald canopy."#,
        #""#,
        #"     !/Users/someuser/bin/rename-tab "Done""#,
        #""#,
        #"     ▣  Build · Ling 3.1 Flash Free · 6.2s"#,
        #""#,
        #"  ┃"#,
        #"  ┃  Now list three facts about sea urchins, as a"#,
        #"  ┃  bulleted list please."#,
        #"  ┃"#,
        #""#,
        #"     + Thought: 417ms"#,
        #""#,
        #"     - Sea urchins have five-sided radial symmetry and"#,
        #"       move using hundreds of tiny tube feet."#,
        #"     - Their spines help them graze on algae, making"#,
        #"       them key kelp forest herbivores."#,
        #"     - Some species can live 100+ years and regenerate"#,
        #"       damaged spines."#,
        #""#,
        #"     !/Users/someuser/bin/rename-tab "Done""#,
        #""#,
        #"     ▣  Build · Ling 3.1 Flash Free · 7.1s"#,
        #""#,
        #"  ┃"#,
        #"  ┃  Give one fun fact about starfish regenerating"#,
        #"  ┃  their arms."#,
        #"  ┃"#,
        #""#,
        #"  ┃"#,
        #"  ┃  Unauthorized: {"status":401,"title":"Unauthorized", ▄"#,
        #"  ┃  "detail":"Invalid JWT serialization: Missing dot    █"#,
        #"  ┃  delimiter(s)"}                                      █"#,
        #"  ┃                                                      █"#,
        #"                                                         █"#,
        #"     ▣  Build · Kimi K3                                  █"#,
        #""#,
        #"  ┃"#,
        #"  ┃"#,
        #"  ┃"#,
        #"  ┃  Build · Kimi K3 Nvidia"#,
        #"  ╹▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀"#,
        #"   /private/tmp/                 26.6K (10%)ctrl+p"#,
        #"   JumpToMessageBuilder                     commands"#,
    ]

    /// Rows after `/undo` of the errored turn: the banner (rows 35–38) has
    /// the user cells' shape, and the undone prompt is back in the input box.
    static let openCodeRevertRows = [
        #"                                                         █"#,
        #"  ┃                                                      █"#,
        #"  ┃  Reply with two short sentences about otters         █"#,
        #"  ┃  swimming in kelp forests.                           █"#,
        #"  ┃                                                      █"#,
        #"                                                         █"#,
        #"     + Thought: 463ms                                    █"#,
        #"                                                         █"#,
        #"     Sea otters glide through kelp forests, wrapping     █"#,
        #"     themselves in swaying fronds to anchor against the  █"#,
        #"     current. Their fur glistens as they float and dive  █"#,
        #"     among the emerald canopy.                           █"#,
        #"                                                         █"#,
        #"     !/Users/someuser/bin/rename-tab "Done"              █"#,
        #"                                                         █"#,
        #"     ▣  Build · Ling 3.1 Flash Free · 6.2s               █"#,
        #"                                                         █"#,
        #"  ┃                                                      █"#,
        #"  ┃  Now list three facts about sea urchins, as a        █"#,
        #"  ┃  bulleted list please.                               █"#,
        #"  ┃                                                      █"#,
        #"                                                         █"#,
        #"     + Thought: 417ms                                    █"#,
        #"                                                         █"#,
        #"     - Sea urchins have five-sided radial symmetry and   █"#,
        #"       move using hundreds of tiny tube feet.            █"#,
        #"     - Their spines help them graze on algae, making     █"#,
        #"       them key kelp forest herbivores.                  █"#,
        #"     - Some species can live 100+ years and regenerate   █"#,
        #"       damaged spines.                                   █"#,
        #"                                                         █"#,
        #"     !/Users/someuser/bin/rename-tab "Done"              █"#,
        #"                                                         █"#,
        #"     ▣  Build · Ling 3.1 Flash Free · 7.1s               █"#,
        #"                                                         █"#,
        #"  ┃                                                      █"#,
        #"  ┃  1 message reverted                                  █"#,
        #"  ┃  ctrl+x r or /redo to restore                        █"#,
        #"  ┃                                                      █"#,
        #"                                                         █"#,
        #""#,
        #"  ┃"#,
        #"  ┃  Give one fun fact about starfish regenerating"#,
        #"  ┃  their arms."#,
        #"  ┃"#,
        #"  ┃  Build · Kimi K3 Nvidia"#,
        #"  ╹▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀"#,
        #"   /private/tmp/                 26.6K (10%)ctrl+p"#,
        #"   JumpToMessageBuilder                     commands"#,
    ]

    /// The reader's answer for that OpenCode session. The error is the
    /// third turn's reply; the export still holds the undone turn.
    static let openCodeTranscript = transcript(
        kind: "opencode",
        messages: [
            (
                "msg_12c40a78a001QUeVzI7qvHwRYn", .user,
                "Reply with two short sentences about otters swimming in kelp forests."
            ),
            (
                "msg_12c40a800001Yz5KUlwDLWYd7F", .assistant,
                "Sea otters glide through kelp forests, wrapping themselves in swaying fronds to "
                    + "anchor against the current. Their fur glistens as they float and dive among "
                    + "the emerald canopy.\n\n!/Users/someuser/bin/rename-tab \"Done\""
            ),
            (
                "msg_12c4194be001gLVjnlnf3ByT1T", .user,
                "Now list three facts about sea urchins, as a bulleted list please."
            ),
            (
                "msg_12c41953d001eK8feq6vgS0q6H", .assistant,
                "- Sea urchins have five-sided radial symmetry and move using hundreds of tiny tube "
                    + "feet.\n- Their spines help them graze on algae, making them key kelp forest "
                    + "herbivores.\n- Some species can live 100+ years and regenerate damaged spines."
                    + "\n\n!/Users/someuser/bin/rename-tab \"Done\""
            ),
            (
                "msg_12c426e39001Coup7CbHAQjydF", .user,
                "Give one fun fact about starfish regenerating their arms."
            ),
            (
                "msg_12c426ebd001RruRZfjzz4Bh9o", .assistant,
                #"Unauthorized: {"status":401,"title":"Unauthorized","detail":"Invalid JWT "#
                    + #"serialization: Missing dot delimiter(s)"}"#
            ),
        ])

    /// Pi 0.80.6, two turns typed on the Host that open with the same 24
    /// characters; the model's replies are provider errors. Rows from the
    /// first user turn on.
    static let piSharedOpeningRows = [
        #"     Please answer briefly: what is two plus two? Reply"#,
        #"     with one word."#,
        #" Error: {"error":{"message":"{\n  \"error\": {\n"#,
        #" \"code\": 404,\n    \"message\": \"This model"#,
        #" models/gemini-2.5-pro is no longer available to new users."#,
        #" Please update your code to use"#,
        #" models/gemini-3.1-pro-preview for the latest features and"#,
        #" improvements. We recommend you to use the Interactions API"#,
        #" (https://ai.google.dev/gemini-api/docs/get-started).\",\n"#,
        #" \"status\": \"NOT_FOUND\"\n"#,
        #" }\n}\n","code":404,"status":"Not Found"}}"#,
        #""#,
        #"     Please answer briefly: what is three plus three? Reply"#,
        #"     with one word."#,
        #" Error: {"error":{"message":"{\n  \"error\": {\n"#,
        #" \"code\": 404,\n    \"message\": \"This model"#,
        #" models/gemini-2.5-pro is no longer available to new users."#,
        #" Please update your code to use"#,
        #" models/gemini-3.1-pro-preview for the latest features and"#,
        #" improvements. We recommend you to use the Interactions API"#,
        #" (https://ai.google.dev/gemini-api/docs/get-started).\",\n"#,
        #" \"status\": \"NOT_FOUND\"\n"#,
        #" }\n}\n","code":404,"status":"Not Found"}}"#,
    ]

    /// The reader's user turns for that Pi session.
    static let piSharedOpeningTranscript = transcript(
        kind: "pi",
        messages: [
            ("5424d6a4", .user, "Please answer briefly: what is two plus two? Reply with one word."),
            ("3586a2c5", .user, "Please answer briefly: what is three plus three? Reply with one word."),
        ])

    /// Pi's editor and status rows under its message list, from the same
    /// session as `piRows`.
    static let piFooterRows = [
        #"────────────────────────────────────────────────────────────"#,
        #""#,
        #"────────────────────────────────────────────────────────────"#,
        #"/private/tmp/JumpToMessageBuilder • 🔔 otter kelp sentences"#,
        #"↑7.3k ↓205 R11k CH88.0% $0.001 0.6%/1.0M (auto)  google/gemi"#,
        #"usage left: Codex n/a · Claude 72%5h 62%wk minimal UI cla..."#,
    ]

    /// OpenCode 1.19.0 at 60×20, scrolled to the top of a session whose one
    /// turn was typed on the Host over three lines (Shift-Enter). The
    /// scrollbar thumb sits on the cell's first rows.
    static let openCodeShortFirstLineRows = [
        #"                                                         █"#,
        #"  ┃                                                      █"#,
        #"  ┃  Answer two things:                                  ▀"#,
        #"  ┃  - say hi"#,
        #"  ┃  - say bye, with no tools"#,
        #"  ┃"#,
        #""#,
        #"     + Thought: 3.3s"#,
        #""#,
        #"     hi"#,
        #""#,
        #""#,
        #"  ┃"#,
        #"  ┃"#,
        #"  ┃"#,
        #"  ┃  Build · Ling 3.1 Flash Free OpenCode Zen"#,
        #"  ╹▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀"#,
        #"   /private/tmp/                 tab agents ctrl+p"#,
        #"   JumpToMessageBuilder                     commands"#,
    ]

    /// The reader's answer for that OpenCode session.
    static let openCodeShortFirstLineTranscript = transcript(
        kind: "opencode",
        messages: [
            (
                "msg_12c9e2985001HAmulORCWlpddg", .user,
                "Answer two things:\n- say hi\n- say bye, with no tools"
            ),
            ("msg_12c9e29f5001MG2Gbtk3TnFc4a", .assistant, "hi\n\nbye"),
        ])

    static func transcript(
        kind: String,
        status: ChatTranscriptHeader.Status = .ok,
        messages: [(id: String, role: ChatTranscriptMessage.Role, text: String)] = []
    ) -> ChatTranscriptSnapshot {
        ChatTranscriptSnapshot(
            header: ChatTranscriptHeader(
                kind: kind, status: status, transcript: nil, activity: nil,
                turnOpen: false, truncated: false, error: nil),
            messages: messages.map {
                ChatTranscriptMessage(id: $0.id, role: $0.role, text: $0.text, timestamp: nil)
            })
    }
}

extension ChatTranscriptSnapshot {
    /// This read as the reader answers when it cut all but its newest
    /// `count` messages.
    func cut(keepingLast count: Int) -> Self {
        ChatTranscriptSnapshot(
            header: ChatTranscriptHeader(
                kind: header.kind, status: header.status, transcript: header.transcript,
                activity: header.activity, turnOpen: header.turnOpen, truncated: true,
                error: header.error),
            messages: Array(messages.suffix(count)))
    }
}

/// Live screens from Agent kinds with no transcript reader, captured over
/// `herdr terminal attach` at 60 columns (rows emulated with pyte, trailing
/// blanks dropped), each sent the same prompt twice from the Host: Kimi Code
/// 2.1.1, Maki 0.6.3, Hermes, Mastra Code 0.46.0, Qwen Code 0.25.1 and Cline
/// on gemini-2.5-flash-lite, and the first screens of Antigravity and Qoder
/// CLI 1.1.68. `clineDraftRows` is Cline mid-send, the prompt still in its
/// input box.
enum UntestedAgentCaptures {
    static let kimiRows = [
        #" ✨ Reply with exactly: See"#,
        #"    https://example.com/waycar/untested/links-and-paths-che"#,
        #"    ck-0123456789 and docs/plan.md and /tmp/shot.png"#,
        #""#,
        #" ● See"#,
        #"   https://example.com/waycar/untested/links-and-paths-chec"#,
        #"   k-0123456789 and docs/plan.md and /tmp/shot.png"#,
        #""#,
        #" ✨ Reply with exactly: See"#,
        #"    https://example.com/waycar/untested/links-and-paths-che"#,
        #"    ck-0123456789 and docs/plan.md and /tmp/shot.png"#,
        #""#,
        #" ● See"#,
        #"   https://example.com/waycar/untested/links-and-paths-chec"#,
        #"   k-0123456789 and docs/plan.md and /tmp/shot.png"#,
        #""#,
        #" ╭────────────────────────────────────────────────────────╮"#,
        #" │ >                                                      │"#,
        #" ╰────────────────────────────────────────────────────────╯"#,
        #" google/gemini-2.5-flash-lite  …/untested/ws/kimi"#,
        #"                                   context: 2% (16.5k/977k)"#,
    ]
    static let makiRows = [
        #"you> Reply with exactly: See"#,
        #"https://example.com/waycar/untested/links-and-paths-check-0"#,
        #"123456789 and docs/plan.md and /tmp/shot.png"#,
        #""#,
        #"● write> response.txt (107 bytes)"#,
        #"  1 See"#,
        #"https://example.com/waycar/untested/links-and-paths-check-0"#,
        #"123456789 and docs/plan.md and /tmp/shot.png"#,
        #""#,
        #"maki> See"#,
        #"https://example.com/waycar/untested/links-and-paths-check-0"#,
        #"123456789 and docs/plan.md and /tmp/shot.png"#,
        #""#,
        #"you> Reply with exactly: See"#,
        #"https://example.com/waycar/untested/links-and-paths-check-0"#,
        #"123456789 and docs/plan.md and /tmp/shot.png"#,
        #""#,
        #"● write> response.txt (107 bytes)"#,
        #"  1 See"#,
        #"https://example.com/waycar/untested/links-and-paths-check-0"#,
        #"123456789 and docs/plan.md and /tmp/shot.png"#,
        #""#,
        #"maki> See"#,
        #"https://example.com/waycar/untested/links-and-paths-check-0"#,
        #"123456789 and docs/plan.md and /tmp/shot.png"#,
        #""#,
        #""#,
        #""#,
        #""#,
        #""#,
        #""#,
        #""#,
        #""#,
        #""#,
        #""#,
        #""#,
        #"────────────────────────────────────────────────────────────"#,
        #"❯"#,
        #"────────────────────────────────────────────────────────────"#,
        #" [BUILD]..ted/ws/maki  ..-flash-lite  4.5k/1.0m (0%) $0.002"#,
    ]
    static let makiStartupComposerRows = [
        #"............................................................"#,
        #"────────────────────────────────────────────────────────────"#,
        #"❯ Ask maki to refactor a module..."#,
        #"────────────────────────────────────────────────────────────"#,
        #" [BUILD]..untested/ws/maki  ..i-2.5-flash-lite  0/1.0m (0%)"#,
    ]
    static let hermesRows = [
        #"**Formulating Exact Output**"#,
        #""#,
        #"I've realized the core of this task isn't about data retriev"#,
        #"al or analysis, but a direct output instruction. Therefore,"#,
        #"I will bypass tool usage and provide the requested informati"#,
        #"on verbatim as a literal string."#,
        #""#,
        #"└──────────────────────────────────────────────────────────┘"#,
        #""#,
        #"╭─ ⚕ Hermes ───────────────────────────────────────────────╮"#,
        #"    See"#,
        #"    https://example.com/waycar/untested/links-and-paths-ch"#,
        #"    eck-0123456789 and docs/plan.md and /tmp/shot.png"#,
        #"╰──────────────────────────────────────────────────────────╯"#,
        #""#,
        #"────────────────────────────────────────"#,
        #"● Reply with exactly: See"#,
        #"https://example.com/waycar/untested/links-and-paths-check-01"#,
        #"23456789 and docs/plan.md and /tmp/shot.png"#,
        #"────────────────────────────────────────"#,
        #""#,
        #""#,
        #"┌─ Reasoning ──────────────────────────────────────────────┐"#,
        #"**Generating Requested Output**"#,
        #""#,
        #"I am preparing to deliver the exact string requested, which"#,
        #"includes a URL and both relative and absolute file paths. No"#,
        #" external tools are necessary; I will simply present the inf"#,
        #"ormation as provided."#,
        #""#,
        #"└──────────────────────────────────────────────────────────┘"#,
        #""#,
        #"╭─ ⚕ Hermes ───────────────────────────────────────────────╮"#,
        #"    See"#,
        #"    https://example.com/waycar/untested/links-and-paths-ch"#,
        #"    eck-0123456789 and docs/plan.md and /tmp/shot.png"#,
        #"╰──────────────────────────────────────────────────────────╯"#,
        #" ⚕ gemini-2.5-flash-lite · 1% · 13m"#,
        #"────────────────────────────────────────────────────────────"#,
        #"❯"#,
    ]
    static let mastraRows = [
        #"   shift+tab  cycle modes ·  /help  info & shortcuts"#,
        #""#,
        #"▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄"#,
        #"  Reply with exactly: See"#,
        #"  https://example.com/waycar/untested/links-and-paths-chec"#,
        #"  k-0123456789 and docs/plan.md and /tmp/shot.png"#,
        #"▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀"#,
        #""#,
        #" Created thread: 18a98225-73dd-4d63-aa8f-19c134de4cba"#,
        #""#,
        #"╭──────────────────────────────────────────────────────────╮"#,
        #"│ Tool call was not approved by the user                   │"#,
        #"├──────────────────────────────────────────────────────────┤"#,
        #"│ $ /private/tmp/untested/ws/mastracode                    │"#,
        #"├──────────────────────────────────────────────────────────┤"#,
        #"│ ✓ Open links and paths                             1m10s │"#,
        #"╰──────────────────────────────────────────────────────────╯"#,
        #""#,
        #"  I can do that for you."#,
        #""#,
        #"  Here are the links and paths you requested:"#,
        #""#,
        #"  - https://example.com/waycar/untested/links-and-paths-ch"#,
        #"    eck-0123456789"#,
        #"  - docs/plan.md"#,
        #"  - /tmp/shot.png"#,
        #""#,
        #""#,
        #"▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄"#,
        #" →"#,
        #"▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀"#,
        #" build · openrouter/gemini-2.5-flash-lite 1m12s ✓"#,
        #" /private/tmp/untested/ws/mastracode"#,
    ]
    static let qwenRows = [
        #"  ● Read context files: ~/.qwen/output-language.md"#,
        #""#,
        #"  > Reply with exactly: See https://example.com/waycar/untes"#,
        #"    ted/links-and-paths-check-0123456789 and docs/plan.md"#,
        #"    and /tmp/shot.png"#,
        #""#,
        #"  ◆ I will reply with the provided links and file paths."#,
        #"    https://example.com/waycar/untested/links-and-paths-ch"#,
        #"    eck-0123456789 and docs/plan.md and /tmp/shot.png"#,
        #""#,
        #"  > Reply with exactly: See https://example.com/waycar/untes"#,
        #"    ted/links-and-paths-check-0123456789 and docs/plan.md"#,
        #"    and /tmp/shot.png"#,
        #""#,
        #"  ◆ See https://example.com/waycar/untested/links-and-path"#,
        #"    s-check-0123456789 and docs/plan.md and /tmp/shot.png"#,
        #""#,
        #"────────────────────────────────────────────────────────────"#,
        #"> blame the changes"#,
        #"────────────────────────────────────────────────────────────"#,
        #"  ➜ qwen · google/gemini-2.5-flash-lite · 1.0m Context"#,
        #"  1.5% used"#,
        #"  Auto mode (shift + tab to cycle)"#,
        #"  1.5% used"#,
    ]
    static let qwenPlaceholderRows = [
        #""#,
        #"────────────────────────────────────────────────────────────"#,
        #">   Type your message or @path/to/file"#,
        #"────────────────────────────────────────────────────────────"#,
        #"  ➜ qwen · google/gemini-2.5-flash-lite · 1.0m Context"#,
    ]
    static let clineRows = [
        #""#,
        #" ❯ Reply with exactly: See https://example.com/waycar/"#,
        #"   untested/links-and-paths-check-0123456789 and docs/"#,
        #"   plan.md and /tmp/shot.png"#,
        #""#,
        #" * See https://example.com/waycar/untested/links-and-paths-"#,
        #"   check-0123456789 and docs/plan.md and /tmp/shot.png"#,
        #""#,
        #" ❯ Reply with exactly: See https://example.com/waycar/"#,
        #"   untested/links-and-paths-check-0123456789 and docs/"#,
        #"   plan.md and /tmp/shot.png"#,
        #""#,
        #" * See https://example.com/waycar/untested/links-and-paths-"#,
        #"   check-0123456789 and docs/plan.md and /tmp/shot.png"#,
        #""#,
        #""#,
        #""#,
        #""#,
        #""#,
        #""#,
        #""#,
        #""#,
        #""#,
        #""#,
        #""#,
        #""#,
        #""#,
        #""#,
        #""#,
        #""#,
        #""#,
        #""#,
        #""#,
        #"────────────────────────────────────────────────────────────"#,
        #"❯ Ask anything..."#,
        #"────────────────────────────────────────────────────────────"#,
        #" Gemini 2.5 Flash-Lite                   ○ Plan ● Act (Tab)"#,
        #" ██████ (3,034) $0.00"#,
        #" cline"#,
        #" ⏵⏵ Auto-approve all enabled (Shift+Tab)"#,
    ]
    static let clineDraftRows = [
        #" ❯ Reply with exactly: See https://example.com/waycar/"#,
        #"   untested/links-and-paths-check-0123456789 and docs/"#,
        #"   plan.md and /tmp/shot.png"#,
        #""#,
        #" ⠋ Thinking... (esc to cancel)"#,
        #""#,
        #""#,
        #"                   @@@@@@@@@@@@@@@@@@@@"#,
        #"                 @@@@@@@@@@@@@@@@@@@@@@@@"#,
        #"                 @@@@##@@@@@@@@@@@@@@@@@@"#,
        #"                 @@@@@@@@@@@@@@@@@@@@@@@@#"#,
        #"                 @@@    @@@     @@@@@@@@@+"#,
        #"                 @@@    @@@#    @@@@@@@@"#,
        #"                 @@@@@@@@@@@@@@@@@@@@@@@"#,
        #"                 +@@@@@@@@@@@@@@@@@@@#"#,
        #"                  ;@@@@@@@@@@@@@@@@*"#,
        #""#,
        #"                   What can I do for you?"#,
        #""#,
        #" Use / for slash commands, @ for file mentions, Ctrl+P for"#,
        #" menu"#,
        #""#,
        #"────────────────────────────────────────────────────────────"#,
        #"❯ Reply with exactly: See https://example.com/waycar/"#,
        #"  untested/links-and-paths-check-0123456789 and docs/plan.md"#,
        #"  and /tmp/shot.png"#,
        #"────────────────────────────────────────────────────────────"#,
        #""#,
        #" Gemini 2.5 Flash-Lite                   ○ Plan ● Act (Tab)"#,
        #" ██████ (0) $0.00"#,
        #" cline"#,
        #" ⏵⏵ Auto-approve all enabled (Shift+Tab)"#,
    ]
    static let agyMenuRows = [
        #" Welcome to the Antigravity CLI. You are currently not"#,
        #" signed in."#,
        #""#,
        #" Select login method:"#,
        #" > 1. Google OAuth"#,
        #"   2. Use a Google Cloud project"#,
        #""#,
        #"   ↑/↓ Navigate · enter Select"#,
    ]
    static let qoderTrustRows = [
        #" Do you trust the files in this folder?"#,
        #"────────────────────────────────────────────────────────────"#,
        #" Please confirm this is your own project or from a trusted"#,
        #" source. Once trusted, Qoder CLI can read, modify, and"#,
        #" execute files here, and will load local configurations"#,
        #" (commands, hooks, MCP servers, agents, skills, settings)."#,
        #""#,
        #" /private/tmp/untested/ws/qodercli"#,
        #""#,
        #"  ❯ 1. Trust folder"#,
        #"    2. Don't trust and exit"#,
        #""#,
        #" ↑/↓ navigate · Enter select · Esc back"#,
    ]
    static let qoderSignInRows = [
        #" Welcome to Qoder CLI"#,
        #"────────────────────────────────────────────────────────────"#,
        #" Sign in to get started, or exit the application."#,
        #""#,
        #"  ❯ 1. Sign in to continue"#,
        #"    2. Exit the application"#,
        #""#,
        #" ↑/↓ navigate · Enter select · Esc back"#,
    ]

    /// Mastra Code's first frame after attach (its first synchronized
    /// update), the input band three `▄` rows tall while it repaints.
    static let mastraFirstFrameRows = [
        #""#,
        #"╰───────────────────────────────────────────────────────────"#,
        #"───────────────────╯"#,
        #""#,
        #""#,
        #"  I can do that for you."#,
        #""#,
        #""#,
        #""#,
        #""#,
        #""#,
        #"  Here are the links and paths you requested:"#,
        #""#,
        #""#,
        #""#,
        #""#,
        #""#,
        #"  - https://example.com/waycar/untested/links-and-paths-chec"#,
        #"k-0123456789"#,
        #""#,
        #"  - docs/plan.md"#,
        #""#,
        #""#,
        #"  - /tmp/shot.png"#,
        #""#,
        #""#,
        #""#,
        #""#,
        #"▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄"#,
        #"▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄"#,
        #"▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄"#,
        #" →"#,
        #""#,
        #""#,
        #"▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀"#,
        #"▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀"#,
        #"▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀"#,
        #" build · openrouter/google/gemini-2.5-flash-lite 1m12s ✓ · 0"#,
        #".1/70k 0% · /private/tmp/untested/ws/mastracode"#,
    ]

    /// Hermes's screen as the second prompt sits in its input, before it is
    /// sent (a synchronized-update frame of the reply capture).
    static let hermesDraftRows = [
        #"└──────────────────────────────────────────────────────────┘"#,
        #""#,
        #"╭─ ⚕ Hermes ───────────────────────────────────────────────╮"#,
        #"    See"#,
        #"    https://example.com/waycar/untested/links-and-paths-ch"#,
        #"    eck-0123456789 and docs/plan.md and /tmp/shot.png"#,
        #"╰──────────────────────────────────────────────────────────╯"#,
        #" ⚕ gemini-2.5-flash-lite · 1% · 13m"#,
        #"────────────────────────────────────────────────────────────"#,
        #"❯ Reply with exactly: See https://example.com/waycar/unteste"#,
        #"d/links-and-paths-check-0123456789 and docs/plan.md and /tmp"#,
        #"/shot.png"#,
    ]

    /// Kimi Code's screen as the second prompt sits in its boxed input.
    static let kimiDraftRows = [
        #"    https://example.com/waycar/untested/links-and-paths-che"#,
        #"    ck-0123456789 and docs/plan.md and /tmp/shot.png"#,
        #""#,
        #" ● See"#,
        #"   https://example.com/waycar/untested/links-and-paths-chec"#,
        #"   k-0123456789 and docs/plan.md and /tmp/shot.png"#,
        #""#,
        #" ╭────────────────────────────────────────────────────────╮"#,
        #" │ > Reply with exactly: See                              │"#,
        #" │   https://example.com/waycar/untested/links-and-path   │"#,
        #" │   s-check-0123456789 and docs/plan.md and              │"#,
        #" │   /tmp/shot.png                                        │"#,
        #" ╰────────────────────────────────────────────────────────╯"#,
        #" google/gemini-2.5-flash-lite  …/untested/ws/kimi"#,
        #"                                   context: 2% (16.5k/977k)"#,
    ]

    /// Copilot CLI 1.0.95's folder-trust dialog on its first screen.
    static let copilotTrustRows = [
        #"╭──────────────────────────────────────────────────────────╮"#,
        #"│ Confirm folder trust                                     │"#,
        #"│ ──────────────────────────────────────────────────────── │"#,
        #"│ ╭──────────────────────────────────────────────────────╮ │"#,
        #"│ │ /private/tmp/untested/ws/copilot                     │ │"#,
        #"│ ╰──────────────────────────────────────────────────────╯ │"#,
        #"│                                                          │"#,
        #"│ Copilot can read files in this folder and, with your     │"#,
        #"│ permission, edit them or run code and shell commands. It │"#,
        #"│  will remember your permissions for the rest of this     │"#,
        #"│ session.                                                 │"#,
        #"│                                                          │"#,
        #"│ Do you trust the files in this folder?                   │"#,
        #"│                                                          │"#,
        #"│ ❯ 1. Yes                                                 │"#,
        #"│   2. Yes, and remember this folder for future sessions   │"#,
        #"│   3. No (Esc)                                            │"#,
        #"│                                                          │"#,
        #"│ ↑/↓ to navigate · enter to select · esc to cancel        │"#,
        #"╰──────────────────────────────────────────────────────────╯"#,
    ]

    /// Droid 0.238.0's login menu on its first screen.
    static let droidLoginRows = [
        #"Please login with your Factory account to continue."#,
        #""#,
        #"> Login"#,
        #"  Sign into a Factory Private deployment"#,
        #"  Exit"#,
    ]
}
