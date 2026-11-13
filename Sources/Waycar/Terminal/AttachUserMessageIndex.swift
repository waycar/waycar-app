import Foundation

/// What the user has submitted to one Attach session, so a later frame can be
/// recognised as carrying it.
///
/// The conversation on iOS is a repainted terminal grid, not a message model
/// (ADR 0013). Nothing in the frames marks which rows the user authored: no
/// agent CLI emits OSC 133, herdr's API exposes no transcript, and Ghostty's
/// C API reads cell text without its style. So the jump control works from
/// what the grid does show — the prompt glyph a TUI draws on the user's own
/// turns — backed by the Agent's own transcript where the Host can read it,
/// and by what the app itself sent.
///
/// Two submission paths feed this index, because Agent detail has two:
/// keystrokes crossing `TerminalInputController` (Direct Input, ADR 0016) and
/// Composer sends that leave over `agent.prompt` without touching the PTY.
/// `AgentComposerStore.messages` is not a substitute — it is in-memory, scoped
/// to the Composer, and empty in Direct Input mode.
///
/// Jump targets come from three sources, unioned:
///
/// 1. **Prompt lines seen in a frame.** Most agent TUIs Waycar attaches to
///    draw the user's own turns behind a prompt glyph (`>`, `›`, `❯`), and
///    OpenCode draws them as a `┃`-bordered cell (see `opensBorderedCell`).
///    A few kinds mark them their own way (``UserTurnMark``: Kimi Code `✨`,
///    Maki `you>`, Hermes `●`, Mastra Code's `▄`/`▀` band). A line carrying
///    one is a user message wherever it came from — a desktop herdr, another
///    device, or before the app attached — so scrolling back through history
///    makes that history jumpable. The same glyphs also draw an input box
///    and a selection menu's cursor, which are not turns (see `isInInputBox`
///    and `isMenuChoice`).
/// 2. **User turns in the Agent's transcript** (``receiveTranscript(_:)``,
///    read by the Chat Mode reader). Pi and omp draw no prompt glyph:
///    captured over herdr, their user turn is plain text set apart only by a
///    background colour (Pi at column 5, omp at column 1 like its own
///    prose), so no text rule can tell it from agent output. Their transcript
///    names every user turn, whoever typed it, and a row whose text starts
///    with one turn's opening (read on across rows, whitespace aside, so
///    wrapping does not matter) is showing that turn. OpenCode's error
///    panel and "message reverted" banner have a user cell's exact shape and
///    differ only in border colour; its transcript records neither as a
///    user turn. A cell that opens a transcript turn takes that turn's key,
///    and while a transcript covers the whole conversation it vetoes a cell
///    that opens none.
/// 3. **Messages this session submitted**, matched the same way as
///    transcript turns, for an Agent whose transcript the Host cannot read.
///
/// Every source answers ``visibleMessageKeys(_:)`` with *stable identities*
/// rather than a yes/no match, because the jump loop walks by noticing that a
/// message it had not seen has come into view. An identity must therefore not
/// change as a message scrolls in a row at a time: a prompt line's key is
/// derived from that one line, never from how much of the message is on screen.
///
/// Known limits, all of which cost jump-target accuracy rather than correctness
/// elsewhere. A wrong or missing target means a jump scrolls to the top and
/// reports that it found nothing.
///
/// - Direct Input Shift-Enter is a keystroke LF (`AgentQuickKey.shiftEnter`),
///   and a keystroke LF closes the pending line, so one multiline Direct Input
///   message is indexed as its LF-delimited fragments. Making it otherwise would
///   mean guessing intent from a byte that carries none.
/// - While a Composer insert is pending, a write ending on an unresolved `ESC`
///   is read as the Escape *key* and cancels that draft. A CSI or SS3 sequence
///   split exactly at its introducer would therefore be misread during that
///   window. This is the deliberate trade for cancelling a hardware-keyboard
///   Escape, which arrives through Ghostty as anonymous `.keystroke` bytes and
///   is otherwise indistinguishable; no current key producer splits a sequence
///   that way. Pending text from any other source keeps full split tolerance.
/// - A prompt glyph is a heuristic, narrowed by rules taken from live
///   captures: the glyph must be followed by a space, it must sit within
///   ``maximumPromptIndent`` columns, and its line must be neither ruled off
///   as an input box nor a menu's cursor row. Together those reject a `>_
///   OpenAI Codex` banner, an indented `> /tmp/out.txt` shell redirection, a
///   `>   Type your message` placeholder and a `❯ 1. Trust folder` menu. What
///   survives is a flush-left quoted block in agent prose, which costs one
///   surplus press on the walk. A menu with no key hint whose cursor sits on
///   its first or last choice is not recognised (Droid's login menu, where
///   both are too short to be targets anyway).
/// - A prompt line's key is its first row, so a TUI that rewraps that row
///   (Qwen narrows its text a column while its scrollbar shows) changes the
///   key and costs one surplus stop.
/// - A transcript turn or submitted message is recognised by the opening
///   characters a row starts with, so agent output that starts a row
///   quoting them verbatim is one surplus stop, and a turn the TUI draws
///   differently from its text (Markdown it restyles) is not recognised.
/// - Two identical messages share their opening, so both keys show with
///   either one and a walk counts them as one stop.
/// - A transcript read is as fresh as the last status or session change;
///   until the next, OpenCode cells of turns it has not seen are vetoed.
/// - Without a transcript, or when the reader cut older messages, OpenCode's
///   error panel and "message reverted" banner each remain one surplus stop.
///
/// `refs #268`.
@MainActor
final class AttachUserMessageIndex {
    private let promptIndentLimit: Int
    private let userTurnMark: UserTurnMark?

    init(
        maximumPromptIndent: Int = AttachUserMessageIndex.maximumPromptIndent,
        userTurnMark: UserTurnMark? = nil
    ) {
        self.promptIndentLimit = max(0, maximumPromptIndent)
        self.userTurnMark = userTurnMark
    }

    /// How one Agent kind marks its user's turns where the shared prompt
    /// glyphs do not, each taken from a live capture over herdr. Each is
    /// scoped to its kind because another kind draws the same marker on its
    /// own output: Kimi Code answers behind `●`, Maki marks tool calls `●`.
    enum UserTurnMark: Equatable, Sendable {
        /// The turn's first row opens with this marker within the prompt
        /// indent: Kimi Code `✨ ` (column 1), Maki `you> ` (column 0).
        case leader(String)
        /// As ``leader(_:)``, on the row right under a horizontal rule.
        /// Hermes draws its turn `● ` between two rules.
        case leaderBelowRule(String)
        /// Text rows inside a band of `▄` above and `▀` below: Mastra Code.
        /// Its composer is the same band, opening on `→`.
        case halfBlockBand
    }

    /// One submitted message, oldest first in `entries`.
    struct Entry: Identifiable, Equatable {
        let id: UUID
        /// Exactly what the user submitted, for display and diagnostics.
        let rawText: String
        /// `rawText` under `normalize(_:)`, precomputed for matching.
        let normalizedText: String
        fileprivate let key: String
        fileprivate let match: MatchText
    }

    /// A user turn the Agent's transcript records, with the key it shows as.
    private struct TranscriptTurn {
        let key: String
        let match: MatchText
    }

    /// Key prefix of a transcript turn.
    private static let transcriptKeyPrefix = "transcript:"

    /// One frame row as messages are matched against it: its text after
    /// leading decorations (and the kind's ``UserTurnMark/leader(_:)``),
    /// without whitespace or trailing box glyphs, so a TUI's wrap — between
    /// words or inside one — and a scrollbar thumb do not break a match.
    fileprivate struct CompactRow {
        let text: String
        /// Where the row's text would end if cut at its first double space,
        /// the gutter TUIs right-align a send time or token count into.
        let gutter: String.Index
        /// The row belongs to an input box or editor (``inputBoxRows(_:)``):
        /// the message list above ends here, as it does at the frame's edge.
        let isInputBox: Bool
    }

    /// A message's opening as a frame shows it: its normalised text without
    /// whitespace. Cut once rather than on every frame of a walk.
    fileprivate struct MatchText: Equatable {
        /// At most ``matchPrefixCharacterCount`` characters.
        let head: String
        /// `head` is the whole message.
        let isWhole: Bool

        init(_ normalizedText: String) {
            let compact = AttachUserMessageIndex.compacted(normalizedText)
            head = String(compact.prefix(AttachUserMessageIndex.matchPrefixCharacterCount))
            isWhole = head.count == compact.count
        }

        /// How a message lines up with a frame from the start of one row.
        enum Opening: Equatable {
            /// The message opens there; `length` characters of it show.
            case opens(length: Int)
            /// The frame agrees with the message for `length` characters,
            /// then ends: too few to name it, enough to rule out a shorter
            /// message it starts with.
            case cutOff(length: Int)
        }

        /// How `head` lines up with the frame from the start of `rows[row]`
        /// on, through the rows below it (blank rows skipped) as far as an
        /// input box; nil when this message does not open there.
        ///
        /// Any character that differs rejects the match, so two messages
        /// that open alike part where their text does. A row's gutter is
        /// passed over: a difference inside it ends the row. A whole message
        /// that ends before its row's typed text does is a shorter message
        /// opening a longer one (`continue`, `continue with the docs`), and
        /// rejected. A message list that ends first, at the frame's edge or
        /// at the input box pinned under it, must still have shown
        /// ``lineMatchPrefixCharacterCount`` characters to open it.
        func opening(_ rows: [CompactRow], at row: Int) -> Opening? {
            guard !head.isEmpty, !rows[row].text.isEmpty, !rows[row].isInputBox else { return nil }
            var expected = head.startIndex
            var matched = 0
            for line in rows[row...] {
                if line.isInputBox { break }
                var cursor = line.text.startIndex
                while cursor < line.text.endIndex {
                    if expected == head.endIndex {
                        return isWhole && cursor < line.gutter ? nil : .opens(length: matched)
                    }
                    guard line.text[cursor] == head[expected] else {
                        guard cursor >= line.gutter else { return nil }
                        break
                    }
                    matched += 1
                    head.formIndex(after: &expected)
                    line.text.formIndex(after: &cursor)
                }
                if expected == head.endIndex { return .opens(length: matched) }
            }
            if matched >= AttachUserMessageIndex.lineMatchPrefixCharacterCount {
                return .opens(length: matched)
            }
            return matched > 0 ? .cutOff(length: matched) : nil
        }
    }

    /// Minimum ``weight(of:)`` for a message to be a jump target.
    ///
    /// The gate exists because a very short message is a bad target: `y`,
    /// `ok`, `继续` recur, and since keys are the message's own text, two
    /// identical short messages collide into one target.
    static let minimumEntryWeight = 8

    /// How much a character contributes to the length gate. A CJK ideograph,
    /// kana, or hangul syllable is a word, not a letter, so counting
    /// characters flatly excluded ordinary Chinese prompts — `安装到我手机上`
    /// is seven characters and was silently not a jump target. `refs #268`.
    static func weight(of text: String) -> Int {
        text.unicodeScalars.reduce(0) { total, scalar in
            total + (isIdeographic(scalar) ? 2 : 1)
        }
    }

    private static func isIdeographic(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF: true  // Hiragana + Katakana
        case 0x3400...0x4DBF: true  // CJK Unified Extension A
        case 0x4E00...0x9FFF: true  // CJK Unified
        case 0xAC00...0xD7AF: true  // Hangul Syllables
        case 0xF900...0xFAFF: true  // CJK Compatibility Ideographs
        case 0x20000...0x3FFFF: true  // CJK Unified Extensions B and beyond
        default: false
        }
    }

    /// Oldest entries are dropped past this so a long session stays bounded.
    static let maximumEntryCount = 200

    /// How many leading characters of a message, whitespace aside, a frame
    /// must spell for the message to be on screen. TUIs may truncate or
    /// reflow a long message, so matching all of it would miss those frames;
    /// this many is still a distinctive jump target.
    nonisolated static let matchPrefixCharacterCount = 64

    /// Characters, whitespace aside, that find where a message begins in a
    /// single rendered line, and the least of it a frame cut off at its
    /// edge must show. It must fit on one line of a phone-width terminal.
    /// TUIs right-align gutter content (timestamps, token counts) into the
    /// same row as the message's first line, so each row is read only up to
    /// its gutter (``compactLine(_:)``). Measured against a live Grok TUI at
    /// 40 columns, where a 64-character head never fit. `refs #268`.
    nonisolated static let lineMatchPrefixCharacterCount = 24

    /// Where a PTY write originated. LF and Escape mean different things
    /// depending on the source, not on the byte alone.
    enum OutgoingSource: Sendable, Equatable {
        /// Direct Input and tools-keyboard `send`. LF submits; Escape is skipped.
        case keystroke
        /// Blocked Composer insert. LF is content; Escape cancels this pending line.
        case composerInsert
        /// Snippet body. LF is content; Escape is skipped.
        case snippet
        /// Reviewed or single-line paste. Newlines are content; Escape is skipped.
        case paste
        /// The Esc quick key. Cancels a Composer-inserted pending line and
        /// does not start CSI/SS3 lookahead.
        case escapeKey
    }

    /// Submitted messages, oldest first.
    private(set) var entries: [Entry] = []

    /// User turns from the Agent's last usable transcript read, oldest first.
    private var transcriptTurns: [TranscriptTurn] = []
    /// The transcript read named every user turn of the conversation: the
    /// reader cut none. Only then may it overrule the cell-shape guess.
    private var transcriptCoversConversation = false

    private var pendingText = ""
    private var pendingSource: OutgoingSource = .keystroke
    private var utf8Remainder: [UInt8] = []
    private var scanState = ScanState.text

    private enum ScanState {
        case text
        /// Saw ESC (`0x1B`); waiting to learn whether a CSI or SS3 follows.
        case escape
        /// CSI: ESC `[` or C1 `0x9B`, skipped until a final byte `0x40...0x7E`.
        case csi
        /// SS3: ESC `O` or C1 `0x8F`, skipped for one payload byte.
        case ss3
    }

    /// Bytes the app is about to write to the Attach PTY. Printable content
    /// accumulates; a keystroke carriage return or line feed closes the
    /// pending line. Newlines inside a Composer insert, Snippet, or Paste are
    /// content. The Esc quick key cancels a Composer-inserted pending line.
    /// A keystroke write that ends on an unresolved ESC does the same when
    /// that pending line is a Composer insert (hardware Esc); keystroke
    /// pending keeps CSI/SS3 split-tolerant scanning.
    func observeOutgoing(_ data: Data, source: OutgoingSource = .keystroke) {
        if source == .escapeKey {
            if pendingSource == .composerInsert {
                cancelPending()
            }
            scanState = .text
            return
        }

        var bytes: [UInt8]
        if utf8Remainder.isEmpty {
            bytes = Array(data)
        } else {
            bytes = utf8Remainder
            bytes.append(contentsOf: data)
            utf8Remainder.removeAll(keepingCapacity: true)
        }

        var offset = 0
        while offset < bytes.count {
            switch scanState {
            case .escape:
                switch bytes[offset] {
                case 0x5B:
                    scanState = .csi
                    offset += 1
                case 0x4F:
                    scanState = .ss3
                    offset += 1
                default:
                    // Raw ESC that is not CSI/SS3. Skip it; do not infer the
                    // Esc key. Cancellation is `.escapeKey` provenance.
                    scanState = .text
                }
                continue

            case .csi:
                let byte = bytes[offset]
                offset += 1
                if (0x40...0x7E).contains(byte) {
                    scanState = .text
                } else if byte == 0x1B {
                    scanState = .escape
                }
                continue

            case .ss3:
                offset += 1
                scanState = .text
                continue

            case .text:
                break
            }

            let byte = bytes[offset]
            if byte == 0x1B {
                scanState = .escape
                offset += 1
                continue
            }
            if byte == 0x9B {
                scanState = .csi
                offset += 1
                continue
            }
            if byte == 0x8F {
                scanState = .ss3
                offset += 1
                continue
            }
            if byte == 0x0D {
                if Self.newlineIsContent(source) {
                    if !pendingText.isEmpty {
                        appendPending("\r", source: source)
                    }
                } else {
                    closePendingLine()
                }
                offset += 1
                continue
            }
            if byte == 0x0A {
                if Self.newlineIsContent(source) {
                    if !pendingText.isEmpty {
                        appendPending("\n", source: source)
                    }
                } else {
                    closePendingLine()
                }
                offset += 1
                continue
            }
            if byte == 0x08 || byte == 0x7F {
                if !pendingText.isEmpty {
                    pendingText.removeLast()
                    if pendingText.isEmpty {
                        pendingSource = .keystroke
                    }
                }
                offset += 1
                continue
            }
            if byte < 0x20 {
                offset += 1
                continue
            }
            if byte < 0x80 {
                appendPending(Character(Unicode.Scalar(byte)), source: source)
                offset += 1
                continue
            }

            switch Self.utf8Step(bytes, at: offset) {
            case .incomplete:
                utf8Remainder = Array(bytes[offset...])
                return
            case .invalid:
                offset += 1
            case .scalar(let scalar, let width):
                appendPending(Character(scalar), source: source)
                offset += width
            }
        }
        // Hardware Esc arrives as a keystroke write of `0x1B`. If the pending
        // line is a Composer insert, that is cancel, not CSI lookahead.
        if scanState == .escape, pendingSource == .composerInsert {
            cancelPending()
            scanState = .text
        }
    }

    /// A message delivered out of band — the Composer's `agent.prompt` path,
    /// which never crosses the PTY.
    func record(submitted text: String) {
        appendEntry(rawText: text)
    }

    /// Takes the user turns of a read of the Agent's own transcript (the
    /// Chat Mode reader), replacing those of any earlier read.
    ///
    /// A transcript the Host has not got (`notFound`, `unsupported`) drops
    /// what an earlier read named, while a failed read (`error`) keeps it: one
    /// bad read must not cost the walk targets it already had.
    func receiveTranscript(_ snapshot: ChatTranscriptSnapshot) {
        switch snapshot.header.status {
        case .ok:
            transcriptTurns = snapshot.messages.compactMap { message in
                guard message.role == .user else { return nil }
                let normalized = Self.normalize(message.text)
                guard Self.weight(of: normalized) >= Self.minimumEntryWeight else { return nil }
                return TranscriptTurn(key: "transcript:\(message.id)", match: MatchText(normalized))
            }
            transcriptCoversConversation = !snapshot.header.truncated
        case .notFound, .unsupported:
            transcriptTurns = []
            transcriptCoversConversation = false
        case .error:
            break
        }
    }

    /// Drops everything. Called when the Attach session is replaced, because
    /// entries describe one session's scrollback and must not outlive it.
    func reset() {
        entries.removeAll(keepingCapacity: false)
        transcriptTurns.removeAll(keepingCapacity: false)
        transcriptCoversConversation = false
        pendingText = ""
        pendingSource = .keystroke
        utf8Remainder.removeAll(keepingCapacity: false)
        scanState = .text
    }

    /// Stable identities of every user message visible in `frameText`.
    ///
    /// This is what `TerminalMessageJumpController` is constructed with: it
    /// walks until a key it has not seen appears, so the keys must identify a
    /// message, not a frame. A prompt line's key comes from that line alone,
    /// so it is the same whether one row of the message is on screen or all of
    /// them; a submitted entry's or transcript turn's key is its identity,
    /// independent of which of its rows the frame happens to show.
    func visibleMessageKeys(_ frameText: String) -> Set<String> {
        let rows = frameText.split(
            omittingEmptySubsequences: false,
            whereSeparator: \.isNewline
        )
        let lines = rows.map { Self.strip(String($0)) }
        guard !lines.isEmpty else { return [] }
        let openings = messageOpenings(rows, lines)

        var keys = Set<String>()
        for row in lines.indices {
            if let key = lineKey(rows, lines, openings, at: row) {
                keys.insert(key)
            }
        }
        for opened in openings.values {
            keys.formUnion(opened)
        }
        return keys
    }

    /// The submitted messages and transcript turns that open on each row,
    /// by key: a message opens where a row's text starts with it, never in
    /// the middle of agent prose. Where several open on one row, only the
    /// longest match counts, so an earlier `continue` does not also claim
    /// `continue` / `with the docs` wrapped after its first word. A row
    /// that a longer message agrees with as far as the message list goes
    /// names nothing yet: at the list's end, `continue` may be either turn.
    private func messageOpenings(
        _ rows: [Substring], _ lines: [StrippedLine]
    ) -> [Int: [String]] {
        guard !entries.isEmpty || !transcriptTurns.isEmpty else { return [:] }
        let inputBox = inputBoxRows(rows)
        let compactRows = lines.indices.map {
            compactRow(lines[$0].text, isInputBox: inputBox[$0])
        }
        var openings: [Int: [String]] = [:]
        for row in compactRows.indices where !compactRows[row].text.isEmpty {
            var longest = 0
            var longestCutOff = 0
            var opened: [String] = []
            func consider(_ key: String, _ match: MatchText) {
                switch match.opening(compactRows, at: row) {
                case nil:
                    return
                case .cutOff(let length):
                    longestCutOff = max(longestCutOff, length)
                case .opens(let length) where length >= longest:
                    if length > longest {
                        longest = length
                        opened.removeAll(keepingCapacity: true)
                    }
                    opened.append(key)
                case .opens:
                    return
                }
            }
            for entry in entries { consider(entry.key, entry.match) }
            for turn in transcriptTurns { consider(turn.key, turn.match) }
            if !opened.isEmpty, longestCutOff < longest { openings[row] = opened }
        }
        return openings
    }

    /// Whether `frameText` appears to contain any user message.
    func frameContainsMessage(_ frameText: String) -> Bool {
        !visibleMessageKeys(frameText).isEmpty
    }

    /// Collapses a terminal frame or a submitted line to a comparable form:
    /// per line, drop leading box and prompt glyphs and surrounding
    /// whitespace; join the lines with a single space; collapse every
    /// whitespace run to one space; trim.
    ///
    /// Joining across lines is what makes a soft-wrapped message match. The
    /// per-line glyph strip is what makes a message inside a TUI's bordered
    /// input box match.
    static func normalize(_ text: String) -> String {
        let strippedLines = text.split(
            omittingEmptySubsequences: false,
            whereSeparator: \.isNewline
        ).map { stripLeadingDecorations(String($0)) }
        let joined = strippedLines.joined(separator: " ")
        return joined.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func closePendingLine() {
        let raw = pendingText
        pendingText = ""
        pendingSource = .keystroke
        appendEntry(rawText: raw)
    }

    private func cancelPending() {
        pendingText = ""
        pendingSource = .keystroke
        utf8Remainder.removeAll(keepingCapacity: false)
    }

    private func appendPending(_ character: Character, source: OutgoingSource) {
        if pendingText.isEmpty || source == .composerInsert {
            pendingSource = source
        }
        pendingText.append(character)
    }

    private static func newlineIsContent(_ source: OutgoingSource) -> Bool {
        switch source {
        case .keystroke, .escapeKey: false
        case .composerInsert, .snippet, .paste: true
        }
    }

    private func appendEntry(rawText: String) {
        let normalized = Self.normalize(rawText)
        guard Self.weight(of: normalized) >= Self.minimumEntryWeight else { return }
        let id = UUID()
        entries.append(
            Entry(
                id: id, rawText: rawText, normalizedText: normalized,
                key: "sent:\(id.uuidString)", match: MatchText(normalized)))
        if entries.count > Self.maximumEntryCount {
            entries.removeFirst(entries.count - Self.maximumEntryCount)
        }
    }

    /// Columns of leading whitespace a prompt glyph may sit behind. Measured
    /// on live panes: claude and codex draw the user's turn in column 0, while
    /// their tool output is indented to column 5 and deeper. A box-drawing
    /// glyph is not whitespace, so a bordered input box still qualifies.
    nonisolated static let maximumPromptIndent = 2

    /// One frame line with its leading decorations removed, remembering
    /// whether a prompt glyph was among them and how far the line was indented
    /// before any of them.
    private struct StrippedLine {
        var text: String
        var hasPromptGlyph: Bool
        var indent: Int
    }

    /// Identity for the line at `row` when it opens a user message, or nil
    /// when it does not: an OpenCode user cell, a prompt-glyph line that is
    /// neither the input box nor a selection menu, or the Agent kind's own
    /// ``UserTurnMark``.
    private func lineKey(
        _ rows: [Substring], _ lines: [StrippedLine], _ openings: [Int: [String]], at row: Int
    ) -> String? {
        if opensBorderedCell(rows, at: row) {
            return borderedCellKey(lines[row], opened: openings[row])
        }
        let line = lines[row]
        if line.hasPromptGlyph, line.indent <= promptIndentLimit {
            guard !Self.isInInputBox(rows, at: row), !Self.isMenuChoice(rows, at: row)
            else { return nil }
            return Self.messageKey(line.text[...])
        }
        return markedLineKey(rows, at: row)
    }

    /// An OpenCode cell shaped like a user turn takes the key of the
    /// transcript turn it opens (`opened`), so the cell and the turn are one
    /// target. OpenCode draws its error panel and "message reverted" banner
    /// in the same shape; while the transcript covers the whole
    /// conversation, a cell that opens none of its user turns is one of
    /// those and no target.
    private func borderedCellKey(_ line: StrippedLine, opened: [String]?) -> String? {
        guard let key = Self.messageKey(line.text[...]) else { return nil }
        if let turn = opened?.first(where: { $0.hasPrefix(Self.transcriptKeyPrefix) }) {
            return turn
        }
        return transcriptCoversConversation ? nil : key
    }

    /// Identity for text that opens a user message.
    ///
    /// Only the text before the line's first double space contributes. TUIs
    /// right-align gutter content into the message's own row (a send time, a
    /// token count), and some of it is relative and repaints — a key that
    /// included it would change under the jump loop and read as a different
    /// message. Everything the user typed is a single-spaced run, so cutting
    /// at the gutter keeps the part that identifies the message. A scrollbar
    /// thumb or box border at the row's end comes and goes, so it is dropped.
    private static func messageKey(_ text: Substring) -> String? {
        let collapsed = beforeGutter(text).split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard weight(of: collapsed) >= minimumEntryWeight else { return nil }
        return "line:\(collapsed)"
    }

    /// `text` up to its first double space, without trailing decorations.
    private static func beforeGutter(_ text: Substring) -> Substring {
        trimmingTrailingDecorations(text.range(of: "  ").map { text[..<$0.lowerBound] } ?? text)
    }

    /// `text` without trailing blanks, box glyphs or block elements (a
    /// scrollbar thumb, a box's right border).
    private static func trimmingTrailingDecorations(_ text: Substring) -> Substring {
        var body = text
        while let last = body.unicodeScalars.last,
            CharacterSet.whitespaces.contains(last) || isBoxGlyph(last)
        {
            body = body.dropLast()
        }
        return body
    }

    /// `text` (a row past its leading decorations) as messages are matched
    /// against it. The gutter is kept, because a message typed with a
    /// double space runs on past it; ``MatchText`` passes over it instead.
    private func compactRow(_ text: String, isInputBox: Bool) -> CompactRow {
        var body = Self.trimmingTrailingDecorations(text[...])
        if case .leader(let marker) = userTurnMark, body.hasPrefix(marker) {
            body = body.dropFirst(marker.count)
        } else if case .leaderBelowRule(let marker) = userTurnMark, body.hasPrefix(marker) {
            body = body.dropFirst(marker.count)
        }
        let gutterStart = body.range(of: "  ")?.lowerBound ?? body.endIndex
        let typed = Self.compacted(Self.trimmingTrailingDecorations(body[..<gutterStart]))
        var compact = typed
        compact.append(Self.compacted(body[gutterStart...]))
        let gutter = compact.utf8.index(compact.utf8.startIndex, offsetBy: typed.utf8.count)
        return CompactRow(text: compact, gutter: gutter, isInputBox: isInputBox)
    }

    /// Which rows draw the input box or editor pinned under the message
    /// list, where that list ends. Pi rules its editor off with `─` rows;
    /// omp frames it in a box whose top edge carries its status (`╭── π > ◔
    /// Haiku 4.5 … ──╮`); OpenCode draws a `┃` run closed by `╹▀▀▀`. Only
    /// the last such block counts, reaching the bottom of the frame past at
    /// most ``footerStatusRowLimit`` status rows (Pi's cwd and usage rows,
    /// OpenCode's). A rule or tool box inside the list is the list's own and
    /// ends nothing.
    private func inputBoxRows(_ rows: [Substring]) -> [Bool] {
        var edge = rows.map { Self.isRule($0, allowingCorners: true) || Self.isBoxTop($0) }
        for row in rows.indices {
            guard case .closing(let column) = borderedRow(rows[row]) else { continue }
            edge[row] = true
            var above = row - 1
            while above >= rows.startIndex, borderedRow(rows[above]).isCellBody(column: column) {
                edge[above] = true
                above -= 1
            }
        }
        var inputBox = Array(repeating: false, count: rows.count)
        guard let bottom = edge.lastIndex(of: true),
            rows[(bottom + 1)...].count(where: { !Self.isBlank($0) }) <= Self.footerStatusRowLimit
        else { return inputBox }
        // The block's top: first the editor's own rows, which may hold a
        // draft, up to the nearest edge above with no blank row between (Pi
        // rules its editor off above and below); then any further edges and
        // blank or border-only rows.
        var top = bottom
        var row = bottom - 1
        while row >= rows.startIndex, !edge[row], !Self.isBlank(rows[row]) {
            row -= 1
        }
        if row >= rows.startIndex, edge[row], row < bottom - 1 {
            top = row
        } else {
            row = bottom
        }
        row -= 1
        while row >= rows.startIndex, edge[row] || Self.isDecorationOnly(rows[row]) {
            if edge[row] { top = row }
            row -= 1
        }
        inputBox.replaceSubrange(top..., with: repeatElement(true, count: rows.count - top))
        return inputBox
    }

    /// Status rows a TUI draws under its input box: Pi three, OpenCode two.
    private static let footerStatusRowLimit = 4

    /// A row of blanks and box glyphs only.
    private static func isDecorationOnly(_ row: Substring) -> Bool {
        row.unicodeScalars.allSatisfy { CharacterSet.whitespaces.contains($0) || isBoxGlyph($0) }
    }

    /// A box's top edge with a label in it: opens with `╭` or `┌`, closes
    /// with `╮` or `┐`, and draws at least ``minimumRuleWidth`` of `─`.
    private static func isBoxTop(_ row: Substring) -> Bool {
        let scalars = row.unicodeScalars.drop { CharacterSet.whitespaces.contains($0) }
        guard let first = scalars.first, first == "\u{256D}" || first == "\u{250C}",
            let last = scalars.reversed().first(where: { !CharacterSet.whitespaces.contains($0) }),
            last == "\u{256E}" || last == "\u{2510}"
        else { return false }
        let rule = scalars.lazy.filter { $0 == "\u{2500}" || $0 == "\u{2501}" }
        return rule.count >= minimumRuleWidth
    }

    /// `text` with its whitespace removed.
    fileprivate nonisolated static func compacted(_ text: some StringProtocol) -> String {
        let scalars = text.unicodeScalars.lazy.filter { !$0.properties.isWhitespace }
        return String(String.UnicodeScalarView(scalars))
    }

    /// Key for a row the kind's ``UserTurnMark`` opens a user turn on.
    private func markedLineKey(_ rows: [Substring], at row: Int) -> String? {
        guard let userTurnMark else { return nil }
        let scalars = rows[row].unicodeScalars
        let indent = scalars.prefix { CharacterSet.whitespaces.contains($0) }.count
        guard indent <= promptIndentLimit else { return nil }
        let rest = Substring(scalars.dropFirst(indent))
        switch userTurnMark {
        case .leader(let marker):
            guard rest.hasPrefix(marker) else { return nil }
            return Self.messageKey(rest.dropFirst(marker.count))
        case .leaderBelowRule(let marker):
            guard row > 0, Self.isRule(rows[row - 1]), rest.hasPrefix(marker)
            else { return nil }
            return Self.messageKey(rest.dropFirst(marker.count))
        case .halfBlockBand:
            // A band repainting at a new width can stack its `▄` rows.
            guard row > 0, Self.isRow(rows[row - 1], allOf: Self.lowerHalfBlock),
                !Self.isRow(rows[row], allOf: Self.lowerHalfBlock),
                !Self.isRow(rows[row], allOf: Self.upperHalfBlock),
                !rest.hasPrefix("→")
            else { return nil }
            return Self.messageKey(rest)
        }
    }

    /// Whether the prompt line at `row` is a TUI's input box rather than a
    /// turn it sent: it sits right under a horizontal rule or a box's top
    /// edge, and its rows run on to a closing rule or edge, or to the last
    /// thing on screen. Qwen, Cline, Maki, Hermes and Kimi Code box their
    /// input that way, and what the box shows — a placeholder (`>   Type
    /// your message or @path/to/file`, `❯ Ask anything...`), a suggestion
    /// (`> blame the changes`) or a draft — changes under a walk and read as
    /// a new message. A sent turn is never ruled off like this.
    private static func isInInputBox(_ rows: [Substring], at row: Int) -> Bool {
        guard row > 0, isRule(rows[row - 1], allowingCorners: true) else { return false }
        for next in rows.indices.dropFirst(row + 1) {
            if isRule(rows[next], allowingCorners: true) { return true }
            if isBlank(rows[next]) {
                return rows[next...].allSatisfy(isBlank)
            }
        }
        return true
    }

    /// Whether the prompt line at `row` is the cursor row of a selection
    /// menu (`> 1. Google OAuth`, `│ ❯ 2. Yes, and remember this folder…`,
    /// Droid's `> Sign into a Factory Private deployment`). Either the other
    /// choices sit right above and below it, aligned with its text; or below
    /// it, past choices, their wrapped continuations and blank or box-only
    /// rows, comes the menu's key hint (`↑/↓ to navigate`). A turn the user
    /// sent is set off by a blank row from what came before it, and what
    /// follows it — its own wrapped rows, then the reply — names no arrow
    /// pair the way a hint does, whatever arrows its prose mentions.
    private static func isMenuChoice(_ rows: [Substring], at row: Int) -> Bool {
        guard let cursor = contentStart(of: rows[row]) else { return false }
        if row > 0, row + 1 < rows.count,
            let above = contentStart(of: rows[row - 1]),
            let below = contentStart(of: rows[row + 1]),
            !above.isPrompt, !below.isPrompt,
            above.column == cursor.column, below.column == cursor.column
        {
            return true
        }
        for next in rows.indices.dropFirst(row + 1) {
            if isKeyHint(rows[next]) { return true }
            guard let below = contentStart(of: rows[next]) else { continue }
            guard !below.isPrompt, below.column >= cursor.column else { return false }
        }
        return false
    }

    /// A menu's key hint: the row's text, past whitespace and box glyphs,
    /// opens with the arrow pair, `↑/↓` or `↑↓` (`↑/↓ to navigate · enter to
    /// select`). Prose that opens with one arrow (`↑ moves up and ↓ moves
    /// down`) is no hint.
    private static func isKeyHint(_ row: Substring) -> Bool {
        let text = row.unicodeScalars.drop {
            CharacterSet.whitespaces.contains($0) || isBoxGlyph($0)
        }
        return keyHintOpenings.contains { text.starts(with: $0.unicodeScalars) }
    }

    private static let keyHintOpenings = ["\u{2191}/\u{2193}", "\u{2191}\u{2193}"]

    /// Where a row's text begins, past whitespace, box glyphs and a prompt
    /// glyph; nil for a row with no text.
    private static func contentStart(of row: Substring) -> (column: Int, isPrompt: Bool)? {
        var column = 0
        var isPrompt = false
        var scalars = row.unicodeScalars[...]
        while let scalar = scalars.first {
            if CharacterSet.whitespaces.contains(scalar) || isBoxGlyph(scalar) {
                column += 1
            } else if isPromptGlyph(scalar),
                scalars.dropFirst().first.map({ CharacterSet.whitespaces.contains($0) }) ?? true
            {
                isPrompt = true
                column += 1
            } else {
                return (column, isPrompt)
            }
            scalars = scalars.dropFirst()
        }
        return nil
    }

    private static func isBlank(_ row: Substring) -> Bool {
        row.allSatisfy(\.isWhitespace)
    }

    /// A row drawn only with `─`, `━` or `═`, at least ``minimumRuleWidth``
    /// wide; with `allowingCorners`, a box's top or bottom edge as well.
    private static func isRule(_ row: Substring, allowingCorners: Bool = false) -> Bool {
        var width = 0
        for scalar in row.unicodeScalars where !CharacterSet.whitespaces.contains(scalar) {
            switch scalar.value {
            case 0x2500, 0x2501, 0x2550: width += 1
            case 0x250C, 0x2510, 0x2514, 0x2518, 0x256D...0x2570:
                guard allowingCorners else { return false }
            default: return false
            }
        }
        return width >= minimumRuleWidth
    }

    /// A row drawn only with `scalar`, at least ``minimumRuleWidth`` wide.
    private static func isRow(_ row: Substring, allOf scalar: Unicode.Scalar) -> Bool {
        var width = 0
        for candidate in row.unicodeScalars where !CharacterSet.whitespaces.contains(candidate) {
            guard candidate == scalar else { return false }
            width += 1
        }
        return width >= minimumRuleWidth
    }

    /// Narrower runs are glyphs in a logo or a table, not a rule.
    private static let minimumRuleWidth = 8

    /// `▄` and `▀`, the edges of a Mastra Code band.
    private static let lowerHalfBlock: Unicode.Scalar = "\u{2584}"
    private static let upperHalfBlock: Unicode.Scalar = "\u{2580}"

    /// Whether `rows[row]` is the first text row of an OpenCode user turn.
    ///
    /// OpenCode (1.19, captured over herdr) draws a user turn as a cell with a
    /// `┃` left border, no right border, one padding row above the text, and
    /// the text two columns inside the border:
    ///
    ///     (blank)
    ///       ┃
    ///       ┃  Reply with exactly this markdown and nothing else, …
    ///       ┃  waycar/harness-audit/links-and-paths-check-0123456789. …
    ///       ┃
    ///
    /// Its other `┃` panels differ in shape. A tool block puts its title five
    /// columns inside the border, and its body follows a title row rather
    /// than a padding row. The input box is closed by a `╹▀▀▀` row. A row
    /// counts only when it is the first text row after the padding row, so the
    /// key comes from that one line and stays stable as the cell scrolls in.
    private func opensBorderedCell(_ rows: [Substring], at row: Int) -> Bool {
        guard row >= 2,
            case .text(let column, let gap) = borderedRow(rows[row]),
            gap == Self.borderedCellTextGap,
            borderedRow(rows[row - 1]) == .padding(column: column),
            !borderedRow(rows[row - 2]).isCellBody(column: column)
        else { return false }

        var next = row + 1
        while next < rows.count {
            let shape = borderedRow(rows[next])
            if shape == .closing(column: column) { return false }
            guard shape.isCellBody(column: column) else { return true }
            next += 1
        }
        return true
    }

    /// Columns between OpenCode's `┃` border and a user turn's text.
    private static let borderedCellTextGap = 2

    /// How one frame row relates to an OpenCode `┃` cell border.
    private enum BorderedRow: Equatable {
        case none
        /// `┃` followed only by blanks or a scrollbar column.
        case padding(column: Int)
        /// `┃`, `gap` blanks, then text.
        case text(column: Int, gap: Int)
        /// `╹`, the bottom-left corner that closes the input box.
        case closing(column: Int)

        func isCellBody(column: Int) -> Bool {
            switch self {
            case .padding(let border), .text(let border, _): border == column
            case .none, .closing: false
            }
        }
    }

    private func borderedRow(_ row: Substring) -> BorderedRow {
        let scalars = row.unicodeScalars
        var cursor = scalars.startIndex
        var column = 0
        while cursor < scalars.endIndex, CharacterSet.whitespaces.contains(scalars[cursor]) {
            column += 1
            scalars.formIndex(after: &cursor)
        }
        guard column <= promptIndentLimit, cursor < scalars.endIndex else { return .none }
        let border = scalars[cursor]
        scalars.formIndex(after: &cursor)
        switch border.value {
        case 0x2503: break
        case 0x2579: return .closing(column: column)
        default: return .none
        }
        var gap = 0
        while cursor < scalars.endIndex, CharacterSet.whitespaces.contains(scalars[cursor]) {
            gap += 1
            scalars.formIndex(after: &cursor)
        }
        // OpenCode draws its scrollbar (`█`, a Block Element) in the last
        // column, so a padding row can end in one.
        let isPadding = scalars[cursor...].allSatisfy {
            CharacterSet.whitespaces.contains($0) || (0x2580...0x259F).contains($0.value)
        }
        return isPadding ? .padding(column: column) : .text(column: column, gap: gap)
    }

    private static func stripLeadingDecorations(_ line: String) -> String {
        strip(line).text
    }

    private static func strip(_ line: String) -> StrippedLine {
        var text = line
        var sawPrompt = false
        let indent = line.unicodeScalars.prefix {
            CharacterSet.whitespaces.contains($0)
        }.count
        while true {
            text = text.trimmingCharacters(in: .whitespaces)
            guard let first = text.unicodeScalars.first else {
                return StrippedLine(
                    text: text, hasPromptGlyph: sawPrompt, indent: indent)
            }
            if isPromptGlyph(first) {
                // A prompt glyph is separated from what the user typed. Without
                // this, a banner like `>_ OpenAI Codex (v0.152.0)` reads as a
                // user message and becomes a stop on the walk.
                let rest = text.unicodeScalars.dropFirst()
                guard rest.first.map({ CharacterSet.whitespaces.contains($0) }) ?? true
                else {
                    return StrippedLine(
                        text: text, hasPromptGlyph: sawPrompt, indent: indent)
                }
                sawPrompt = true
            } else if !isBoxGlyph(first) {
                return StrippedLine(
                    text: text, hasPromptGlyph: sawPrompt, indent: indent)
            }
            text = String(text.unicodeScalars.dropFirst())
        }
    }

    /// Prompt glyphs actually observed in agent TUI captures: claude `>`,
    /// codex `›`, grok `❯`.
    private static func isPromptGlyph(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x003E, 0x203A, 0x276F: true
        default: false
        }
    }

    /// Box Drawing and Block Elements, which TUIs draw around an input box
    /// (`▎` is U+258E).
    private static func isBoxGlyph(_ scalar: Unicode.Scalar) -> Bool {
        (0x2500...0x259F).contains(scalar.value)
    }

    private enum UTF8Step {
        case scalar(Unicode.Scalar, width: Int)
        case incomplete
        case invalid
    }

    private static func utf8Step(_ bytes: [UInt8], at offset: Int) -> UTF8Step {
        let lead = bytes[offset]
        let available = bytes.count - offset
        let width: Int
        switch lead {
        case 0xC2...0xDF:
            width = 2
        case 0xE0...0xEF:
            width = 3
        case 0xF0...0xF4:
            width = 4
        default:
            return .invalid
        }
        if available < width {
            return .incomplete
        }
        let slice = Data(bytes[offset..<(offset + width)])
        guard let decoded = String(data: slice, encoding: .utf8),
            let scalar = decoded.unicodeScalars.first,
            decoded.unicodeScalars.count == 1
        else {
            return .invalid
        }
        return .scalar(scalar, width: width)
    }
}
