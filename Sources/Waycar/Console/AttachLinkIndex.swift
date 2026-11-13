import Foundation
import Observation

/// One exact HTTP(S) target observed during the current Attach.
struct AttachLink: Identifiable, Equatable {
    let target: String
    let url: URL

    var id: String { target }
    var host: String { url.host ?? "" }
}

/// Owns the bounded, memory-only Attach Link collection and incremental
/// discovery state. A terminal pipeline may be replaced without replacing
/// this index; the enclosing `AgentAttachStore` clears it on leave.
///
/// A target is exact or provisional. A multiplexer that repaints by cursor
/// moves (`herdr`, mosh) draws a wrapped row as two rows, an agent TUI that
/// streams draws a URL a few characters at a time, and either may hand out
/// an OSC 8 target before its URL is whole, so a target nothing visibly
/// ended may be only the head of the one on screen. Such a target is
/// provisional, and gives way to a longer one it begins. A target becomes
/// exact once a delimiter on its own row ends it, in the stream or on
/// screen, or the screen shows its row ending where no next row could
/// carry it on; an exact target stays beside a longer one it begins.
///
/// The screen alone sees less than the stream: an OSC 8 label (`…?` of
/// `…?personal=true`) and a URL a TUI has streamed half way read there as
/// URLs of their own. A target only the screen found, never the stream,
/// is not taken beside a longer one the stream found, and gives way to a
/// longer one, unless the screen showed it whole: by text after it on its
/// row (`…/pull/1234 for you` stays beside `…/pull/1234/files`), or by
/// where its row broke (`AttachRowBreak.whole`).
@MainActor
@Observable
final class AttachLinkIndex {
    private static let maximumLinkCount = 20
    /// How many texts the stream printed as targets are remembered, listed
    /// or not.
    private static let maximumStreamSeenCount = 64

    private(set) var links: [AttachLink] = []

    private var scanner = AttachLinkScanner()
    private var exactTargets: Set<String> = []
    private var provisionalTargets: Set<String> = []
    /// The listed targets the stream found.
    @ObservationIgnored private var streamTargets: Set<String> = []
    /// The listed targets the stream itself showed whole: text after them
    /// on their row, or a line break, ended them.
    @ObservationIgnored private var streamWholeTargets: Set<String> = []
    /// The texts the stream printed as targets lately, listed or not,
    /// oldest first: an OSC 8 label never reaches it.
    @ObservationIgnored private var streamSeen: [String] = []
    /// The listed targets the screen showed whole: ended by text on their
    /// own row, or by where their row broke.
    @ObservationIgnored private var delimitedTargets: Set<String> = []
    /// The listed targets the screen showed ending a row above text that
    /// does not carry them on, or above a row with no text.
    @ObservationIgnored private var rowEndTargets: Set<String> = []
    /// The targets the last screen read found, and the text it read.
    @ObservationIgnored private var lastScreenTargets: Set<String> = []
    @ObservationIgnored private var lastScreenText: String?
    /// The URLs the Agent's transcript holds whole.
    @ObservationIgnored private var transcriptTargets: Set<String> = []

    /// What settles a row break the screen alone cannot: the URLs the
    /// transcript holds and the ones the stream printed (an OSC 8 target a
    /// cursor move inside its label left provisional included), as a tap
    /// reads them too (`AttachLinkRowJoin.continues`).
    var knownTargets: AttachKnownTargets {
        AttachKnownTargets(transcript: transcriptTargets, printed: streamTargets)
    }

    /// Discovers targets in the PTY stream. Each target is recorded at once,
    /// newest first, as exact or provisional as its ending shows so far.
    func receive(_ data: Data) {
        var scanner = scanner
        scanner.receive(data) { target, ending in
            record(target, ending, fromStream: true)
        }
        self.scanner = scanner
    }

    /// Supplements stream discovery from Ghostty's current visible text, a
    /// grid `columns` wide when known, read as
    /// `AttachTerminalScanner.receiveViewportText(_:columns:known:record:)`
    /// describes: a URL a row break split is read whole, and one that ends
    /// its row is exact only where the next row could not carry it on. Where
    /// the screen cannot tell, the targets the stream and the transcript
    /// hold decide. The screen never rewrites the stream's recency.
    ///
    /// A target the screen alone showed ending its row gives way when its
    /// row grew in place: the last read found it, this one does not, and
    /// this one finds a longer target it begins where it was, once the rows
    /// scrolled since are accounted for (`AttachViewportScroll`) — a TUI's
    /// half-streamed `…/way` become `…/waycar/…`; so does one a half-painted
    /// frame shows where the last read showed the longer one. One whose row
    /// scrolled off, one on a screen replaced whole, and one that still
    /// stands beside the longer one (`…/pull/1234` on a line of its own
    /// above `…/pull/1234/files`) stay.
    func receiveViewportText(_ text: String, columns: Int?) {
        var viewportScanner = AttachLinkScanner()
        var found: Set<String> = []
        viewportScanner.receiveViewportText(text, columns: columns, known: knownTargets) {
            target, ending in
            found.insert(target)
            record(target, ending, fromStream: false)
        }
        if let previous = lastScreenText {
            let screenOnly = { (target: String) in
                !self.streamWholeTargets.contains(target) && !self.delimitedTargets.contains(target)
            }
            let grown = rowEndTargets.filter { prefix in
                lastScreenTargets.contains(prefix) && !found.contains(prefix) && screenOnly(prefix)
                    && found.contains { $0 != prefix && $0.hasPrefix(prefix) }
            }
            let shrunk = rowEndTargets.filter { prefix in
                found.contains(prefix) && !lastScreenTargets.contains(prefix) && screenOnly(prefix)
                    && lastScreenTargets.contains { $0 != prefix && $0.hasPrefix(prefix) && !found.contains($0) }
            }
            var halfDrawn: Set<String> = []
            if !grown.isEmpty {
                halfDrawn.formUnion(
                    AttachViewportScroll.grownInPlace(grown, into: found, from: previous, to: text))
            }
            if !shrunk.isEmpty {
                halfDrawn.formUnion(
                    AttachViewportScroll.grownInPlace(shrunk, into: lastScreenTargets, from: text, to: previous))
            }
            if !halfDrawn.isEmpty {
                links.removeAll { halfDrawn.contains($0.target) }
                retainListedTargets()
            }
        }
        lastScreenTargets = found
        lastScreenText = text
    }

    /// Takes the URLs the Agent's transcript holds whole
    /// (`AttachKnownTargets.transcriptTargets(in:)`), and rereads `text`,
    /// the screen last read, `columns` wide, with them: a target the
    /// stream never showed whole that the earlier reading of `text` gave
    /// and this one does not (`…/docsREADME.md` once the transcript has
    /// `…/docs`; a head `…/untested/` the stream only saw cut by a cursor
    /// move, once the transcript runs it on) was a misreading, and is
    /// dropped.
    func receiveTranscriptTargets(_ targets: Set<String>, rereading text: String?, columns: Int?) {
        guard targets != transcriptTargets else { return }
        guard let text else {
            transcriptTargets = targets
            return
        }
        let earlier = screenTargets(in: text, columns: columns)
        transcriptTargets = targets
        let misread = earlier.subtracting(screenTargets(in: text, columns: columns))
            .subtracting(streamWholeTargets)
        if !misread.isEmpty {
            links.removeAll { misread.contains($0.target) }
            retainListedTargets()
        }
        receiveViewportText(text, columns: columns)
    }

    func finishOutput() {
        var scanner = scanner
        scanner.finishOutput { target, ending in
            record(target, ending, fromStream: true)
        }
        self.scanner = scanner
    }

    func clear() {
        scanner = AttachLinkScanner()
        exactTargets.removeAll(keepingCapacity: false)
        provisionalTargets.removeAll(keepingCapacity: false)
        streamTargets.removeAll(keepingCapacity: false)
        streamWholeTargets.removeAll(keepingCapacity: false)
        streamSeen.removeAll(keepingCapacity: false)
        delimitedTargets.removeAll(keepingCapacity: false)
        rowEndTargets.removeAll(keepingCapacity: false)
        lastScreenTargets.removeAll(keepingCapacity: false)
        lastScreenText = nil
        transcriptTargets.removeAll(keepingCapacity: false)
        links.removeAll(keepingCapacity: false)
    }

    /// The targets a reading of `text` gives, with what is known now.
    private func screenTargets(in text: String, columns: Int?) -> Set<String> {
        var viewportScanner = AttachLinkScanner()
        var targets: Set<String> = []
        viewportScanner.receiveViewportText(text, columns: columns, known: knownTargets) {
            target, _ in
            targets.insert(target)
        }
        return targets
    }

    /// How firmly the screen showed a target whole.
    private enum ScreenEnding {
        /// The stream's, or no more than text ending somewhere.
        case unknown
        /// Its row ended above text that does not carry it on.
        case rowEnd
        /// Text after it on its row, or where its row broke, ended it.
        case delimited
    }

    private func record(_ target: String, _ ending: AttachCandidateEnding, fromStream: Bool) {
        if fromStream {
            rememberStreamSeen(target)
        }
        let screenEnding = fromStream ? ScreenEnding.unknown : .delimited
        switch ending {
        case .whole:
            recordExactTarget(target, fromStream: fromStream, movesToFront: fromStream, screenEnding)
        case .wholeAtRowEnd:
            recordExactTarget(
                target, fromStream: fromStream, movesToFront: fromStream, fromStream ? .unknown : .rowEnd)
        case .cut:
            recordProvisionalTarget(target, fromStream: fromStream)
        case .confirmed:
            // Recorded a moment ago as `.cut`, or skipped for a longer one.
            recordExactTarget(target, fromStream: fromStream, movesToFront: false, screenEnding)
        }
    }

    /// Records a target shown whole, as firmly as `screenEnding` says. A
    /// target the stream never printed is not taken beside a longer one it
    /// did (an OSC 8 label beside its target) unless the screen showed it
    /// delimited.
    private func recordExactTarget(
        _ target: String, fromStream: Bool, movesToFront: Bool, _ screenEnding: ScreenEnding
    ) {
        let isDelimited = screenEnding == .delimited || delimitedTargets.contains(target)
        guard TerminalLinkPolicy.url(for: target) != nil,
              fromStream || isDelimited || streamTargets.contains(target)
                  || streamSeen.contains(target) || !hasLongerStreamTarget(than: target)
        else { return }
        let place = removeGivingWayPrefixes(of: target)
        guard record(target, moveExistingToFront: movesToFront, place: place) else { return }
        exactTargets.insert(target)
        provisionalTargets.remove(target)
        if fromStream {
            streamTargets.insert(target)
            streamWholeTargets.insert(target)
        }
        if isDelimited {
            delimitedTargets.insert(target)
        } else if screenEnding == .rowEnd {
            rowEndTargets.insert(target)
        }
    }

    /// Records a target that may have been cut short, unless a longer known
    /// target begins with it.
    private func recordProvisionalTarget(_ target: String, fromStream: Bool) {
        guard TerminalLinkPolicy.url(for: target) != nil else { return }
        guard
            !links.contains(where: {
                $0.target != target && $0.target.hasPrefix(target)
            })
        else {
            return
        }
        let place = removeGivingWayPrefixes(of: target)
        guard record(target, moveExistingToFront: fromStream, place: place) else { return }
        if !exactTargets.contains(target) {
            provisionalTargets.insert(target)
        }
        if fromStream { streamTargets.insert(target) }
    }

    private func hasLongerStreamTarget(than target: String) -> Bool {
        links.contains {
            $0.target != target && $0.target.hasPrefix(target) && streamTargets.contains($0.target)
        }
    }

    private func rememberStreamSeen(_ target: String) {
        if let index = streamSeen.firstIndex(of: target) {
            streamSeen.remove(at: index)
        } else if streamSeen.count == Self.maximumStreamSeenCount {
            streamSeen.removeFirst()
        }
        streamSeen.append(target)
    }

    /// Drops the listed targets `target` begins that give way to it,
    /// returning where the newest of them stood: provisional ones, and ones
    /// the screen alone found that it never showed whole — by text after
    /// them, or by their row ending (`receiveViewportText(_:columns:)`
    /// drops one grown in place).
    private func removeGivingWayPrefixes(of target: String) -> Int? {
        let prefixes = Set(
            links.lazy.map(\.target).filter { prefix in
                guard prefix != target, target.hasPrefix(prefix) else { return false }
                if self.provisionalTargets.contains(prefix) { return true }
                return !self.streamWholeTargets.contains(prefix)
                    && !self.delimitedTargets.contains(prefix) && !self.rowEndTargets.contains(prefix)
            })
        guard !prefixes.isEmpty else { return nil }
        let place = links.firstIndex { prefixes.contains($0.target) }
        links.removeAll { prefixes.contains($0.target) }
        retainListedTargets()
        return place
    }

    /// Puts `target` first, or, from the screen, which never rewrites the
    /// stream's recency, leaves a known target where it is and puts a new
    /// one in `place`, where the head it completes stood.
    @discardableResult
    private func record(
        _ target: String,
        moveExistingToFront: Bool,
        place: Int? = nil
    ) -> Bool {
        guard let url = TerminalLinkPolicy.url(for: target) else { return false }
        let isDistinct = !links.contains(where: { $0.target == target })
        if !moveExistingToFront, !isDistinct {
            return true
        }
        let link = AttachLink(target: target, url: url)
        links.removeAll { $0.target == link.target }
        links.insert(link, at: moveExistingToFront ? 0 : min(place ?? 0, links.count))
        if links.count > Self.maximumLinkCount {
            links.removeLast(links.count - Self.maximumLinkCount)
        }
        retainListedTargets()
        return true
    }

    /// Forgets what is known of targets no longer listed.
    private func retainListedTargets() {
        let retainedTargets = Set(links.map(\.target))
        exactTargets.formIntersection(retainedTargets)
        provisionalTargets.formIntersection(retainedTargets)
        streamTargets.formIntersection(retainedTargets)
        streamWholeTargets.formIntersection(retainedTargets)
        delimitedTargets.formIntersection(retainedTargets)
        rowEndTargets.formIntersection(retainedTargets)
    }
}

/// How two consecutive reads of the viewport line up, to tell a row a TUI
/// grew in place from one that scrolled away or a screen replaced whole.
enum AttachViewportScroll {
    /// Of `prefixes`, the targets the read of `previous` found that the
    /// read of `current` found grown in place. A prefix's row moved with
    /// the nearest row above it that each read shows once (`anchor(of:)`),
    /// or, with none, with the screen (`rowShift`); without either the
    /// screen was replaced (a clear, an alt-screen switch, a jump) and
    /// nothing grew. A row between the anchor and it that no longer reads
    /// the same once moved, or, where it moved to, a row the last read
    /// showed lower down, means the rows under a still header scrolled or
    /// were replaced: nothing grew either. Otherwise it grew where a target
    /// of `found` beginning with it starts in the cell it started in, and
    /// the row above or the words before it on its row say so (`see …/way`
    /// become `see …/waycar/docs`); or where its row changed and the row nearby
    /// reading the words before it, or the next, starts that target (a word
    /// wrapper moved the growing URL down whole: Kimi's `● See …/waycar/`,
    /// Maki's `maki> See https://exampl`). A row scrolled off grew nothing.
    static func grownInPlace(
        _ prefixes: Set<String>, into found: Set<String>, from previous: String, to current: String
    ) -> Set<String> {
        let before = previous.split(separator: "\n", omittingEmptySubsequences: false)
        let after = current.split(separator: "\n", omittingEmptySubsequences: false)
        let onceBefore = rowsShownOnce(before)
        let onceAfter = rowsShownOnce(after)
        let screenShift = rowShift(from: onceBefore, to: onceAfter)
        return prefixes.filter { prefix in
            let longer = found.filter { $0 != prefix && $0.hasPrefix(prefix) }
            return before.indices.contains { row in
                let columns = startColumns(of: prefix, in: before[row])
                guard !columns.isEmpty else { return false }
                let anchored = anchor(of: row, in: before, once: onceBefore, landing: onceAfter)
                guard let shift = anchored?.shift ?? screenShift else { return false }
                if let anchored {
                    let between = (anchored.row + 1)..<row
                    guard between.allSatisfy({ after.indices.contains($0 - shift) && after[$0 - shift] == before[$0] })
                    else { return false }
                }
                let moved = row - shift
                guard after.indices.contains(moved) else { return false }
                if let lastRow = onceBefore[after[moved]], lastRow > row { return false }
                return columns.contains { column in
                    let words = before[row].prefix(column)
                    let hasWords = words.contains(where: \.isLetter)
                    let isSettled = anchored != nil || (hasWords && after[moved].prefix(column) == words)
                    let rewrapped = hasWords && after[moved] != before[row]
                        ? rowOpening(with: words.drop(while: \.isWhitespace).droppingTrailingBlanks, near: moved, in: after)
                        : nil
                    return longer.contains { target in
                        if isSettled, startColumns(of: target, in: after[moved]).contains(column) { return true }
                        guard let rewrapped else { return false }
                        return !startColumns(of: target, in: after[rewrapped]).isEmpty
                            || (after.indices.contains(rewrapped + 1)
                                && !startColumns(of: target, in: after[rewrapped + 1]).isEmpty)
                    }
                }
            }
        }
    }

    /// How many rows above a target's own may say where its row moved.
    private static var neighbourhood: Int { 6 }
    /// How many rows from where a target's row moved a word wrapper may
    /// have put its words.
    private static var rewrapReach: Int { 2 }

    /// The nearest row above `row` within `neighbourhood` that `before`
    /// shows `once`, and how far it moved up to where the next read shows
    /// it (`landing`); nil where there is none, or the next read does not
    /// show it once.
    private static func anchor(
        of row: Int, in before: [Substring], once: [Substring: Int], landing: [Substring: Int]
    ) -> (row: Int, shift: Int)? {
        for anchor in stride(from: row - 1, through: max(0, row - neighbourhood), by: -1)
        where once[before[anchor]] == anchor {
            return landing[before[anchor]].map { (row: anchor, shift: anchor - $0) }
        }
        return nil
    }

    /// The row of `rows` within `rewrapReach` of `row`, nearest first,
    /// whose text opens with `words`.
    private static func rowOpening(with words: Substring, near row: Int, in rows: [Substring]) -> Int? {
        for distance in 0...rewrapReach {
            for candidate in distance == 0 ? [row] : [row - distance, row + distance]
            where rows.indices.contains(candidate) && rows[candidate].drop(while: \.isWhitespace).hasPrefix(words) {
                return candidate
            }
        }
        return nil
    }

    /// The non-blank rows of `rows` whose text no other row shows, by
    /// text: the only rows that say where they moved.
    static func rowsShownOnce(_ rows: [Substring]) -> [Substring: Int] {
        var once: [Substring: Int] = [:]
        var repeated: Set<Substring> = []
        for (row, text) in rows.enumerated() where !text.allSatisfy(\.isWhitespace) {
            if once.updateValue(row, forKey: text) != nil {
                repeated.insert(text)
            }
        }
        for text in repeated {
            once[text] = nil
        }
        return once
    }

    /// How many rows the screen's text moved up from `before` to `after`
    /// (negative: down), by the rows each shows once (`rowsShownOnce`):
    /// the shift more of them agree on than on any other, so a fixed
    /// header or input box standing still while a reply scrolls is
    /// outvoted; nil where none lines up, or two shifts tie.
    static func rowShift(from before: [Substring: Int], to after: [Substring: Int]) -> Int? {
        var votes: [Int: Int] = [:]
        for (text, row) in before {
            if let landed = after[text] {
                votes[row - landed, default: 0] += 1
            }
        }
        guard let best = votes.max(by: { $0.value < $1.value }),
              votes.allSatisfy({ $0.key == best.key || $0.value < best.value })
        else { return nil }
        return best.key
    }

    /// The cells in `row` where `target` starts: a web scheme opening a
    /// word that, trailing punctuation aside, is `target`, or, reaching the
    /// row's end (blanks and a frame column aside), begins it, as a row
    /// break leaves a URL's head.
    static func startColumns(of target: String, in row: Substring) -> [Int] {
        var columns: [Int] = []
        var column = 0
        var index = row.startIndex
        while index < row.endIndex {
            let rest = row[index...]
            if rest.prefix(4).lowercased() == "http" {
                let word = rest.prefix { !$0.isWhitespace && !$0.isFrameGlyph }
                let reachesRowEnd = rest[word.endIndex...].allSatisfy { $0.isWhitespace || $0.isFrameGlyph }
                var shown = word
                while let last = shown.last, shown != target, ".,;:!?)]}>*`'\"".contains(last) {
                    shown = shown.dropLast()
                }
                if shown == target || (reachesRowEnd && word.count < target.count && target.hasPrefix(word)) {
                    columns.append(column)
                }
            }
            index = row.index(after: index)
            column += 1
        }
        return columns
    }
}

/// What settles a row break the screen alone cannot, for the Attach Links
/// list and a tap alike: the URLs the Agent's transcript holds whole, and
/// the listed ones the stream printed. A URL as long as its row may have
/// been cut or only fit; one cut after its last `/` (OpenCode's
/// `…/untested/` above `averyveryverylongsegmentname`) shows nothing of a
/// URL in its rest.
struct AttachKnownTargets: Equatable, Sendable {
    /// How many transcript targets are kept, the newest turns' first.
    static let maximumTranscriptCount = 256
    /// How much of one turn's text is read.
    static let maximumTurnBytes = 64 * 1024

    private(set) var transcript: Set<String> = []
    private(set) var printed: Set<String> = []

    init() {}

    init(transcript: Set<String>, printed: Set<String>) {
        self.transcript = transcript
        self.printed = printed
    }

    /// The URLs `snapshot`'s turns hold, newest turns first, read as the
    /// stream reads printed text, at most `maximumTranscriptCount`; none
    /// unless the transcript was found. Pure, so a caller may run it off
    /// the main actor.
    static func transcriptTargets(in snapshot: ChatTranscriptSnapshot) -> Set<String> {
        guard snapshot.header.status == .ok else { return [] }
        var found: Set<String> = []
        for message in snapshot.messages.reversed() where found.count < maximumTranscriptCount {
            var scanner = AttachLinkScanner()
            let text = message.text.utf8.prefix(maximumTurnBytes)
            let record: AttachLinkScanner.Record = { target, _ in
                if found.count < maximumTranscriptCount { found.insert(target) }
            }
            scanner.receive(Data(text), record: record)
            scanner.finishOutput(record: record)
        }
        return found
    }

    /// Whether a known target runs on from `head`, the word a row ends
    /// with, into `next`, the next row's first word past its trailing
    /// punctuation.
    func continues(head: Substring, next: Substring) -> Bool {
        guard !next.isEmpty else { return false }
        func runsOn(_ target: String) -> Bool {
            target.count > head.count && target.hasPrefix(head)
                && target.dropFirst(head.count).hasPrefix(next)
        }
        return transcript.contains(where: runsOn) || printed.contains(where: runsOn)
    }

    /// Whether the transcript holds `head`, read as a whole URL, as one of
    /// its own above `next`, the next row's first word, empty above a row
    /// with no text. The transcript may predate the reply on screen: a word
    /// opening with one of `/?#&=` carries a URL on whatever it says
    /// (`…/pull/1234` named in an earlier turn, above `/files`), and one
    /// opening with `-._~%` does where it also holds a longer URL the head
    /// begins (`…/docs` and `…/docs-v1` above `-v2/…`); otherwise such a
    /// word is one of its own (`--verbose`, `_config.yml`, `%PATH%`).
    func holdsWhole(_ head: Substring, above next: Substring) -> Bool {
        let wholeHead = String(head)
        guard transcript.contains(wholeHead) else { return false }
        guard let first = next.first else { return true }
        if "/?#&=".contains(first) {
            return false
        }
        if "-._~%".contains(first) {
            return !transcript.contains { $0.count > wholeHead.count && $0.hasPrefix(wholeHead) }
        }
        return true
    }
}

/// How a candidate ended, as far as the text so far shows.
enum AttachCandidateEnding: Equatable {
    /// Something printed after it on its row ended it, or a line break: it
    /// is whole.
    case whole
    /// On screen, a row break no next row could carry it across: it is
    /// whole, though nothing printed after it on its row shows so.
    case wholeAtRowEnd
    /// A cursor move or the end of the text ended it, or a blank did with
    /// nothing printed after it on its row yet: it may be the head of a
    /// longer one a row break cut.
    case cut
    /// A candidate already reported `.cut`, ended by a blank, that later
    /// text on its row has shown whole.
    case confirmed
}

/// How the word being read meets a row break in viewport text.
enum AttachRowBreak: Equatable {
    /// The next row's text carries the word on.
    case continues
    /// The word was broken here, but the next row's text is not its rest.
    case cut
    /// The next row's text may or may not carry the word on.
    case ambiguous
    /// No next row's text could carry the word on, or no word is being read.
    case ends
    /// Where the break falls, or what is known, shows the word whole there,
    /// as text after it on its row would.
    case whole
}

/// Recognizes candidates in the printable bytes `AttachTerminalScanner`
/// passes through. Network chunk boundaries are invisible here; the
/// scanner ends a candidate itself or when the terminal stream ends one.
protocol AttachTextCandidateScanner {
    /// Whether an OSC 8 hyperlink's target is the candidate in place of its
    /// label. When it is, the label is not scanned, so it can neither hide
    /// nor replace the real destination; when not, the label is scanned like
    /// any other visible text and the target is ignored.
    static var collectsHyperlinkTargets: Bool { get }

    /// Whether `character` can be part of a candidate, as the first of a row
    /// that carries one on, or the last of a row broken at the grid's edge.
    static func isWordCharacter(_ character: Character) -> Bool

    init()
    /// Reads one byte, recording at most one candidate it ends.
    mutating func receive(_ byte: UInt8, record: (String) -> Void)
    /// Ends the current candidate, returning it when it is one.
    mutating func finishOutput() -> String?
    /// Tells the scanner a cursor-positioning control sequence just ended
    /// the current candidate (`AttachTerminalScanner` has already finished
    /// it), so the next text starts wherever the cursor landed rather than
    /// after what came before it; `wrappingRow` when it moved on to the
    /// next row's first column right after text that reached the grid's
    /// edge, as a TUI moves on to the rest of a word it hard-wrapped.
    mutating func cursorDidMove(wrappingRow: Bool)
    /// Tells the scanner the row just read broke with no line break and its
    /// last word runs on into the next row's text.
    mutating func rowDidContinue()
    /// How the word being read meets a row break in viewport text, with
    /// `next` the next row's text past its indentation, whether the row
    /// ended at the grid's edge, the grid's width, and where on it the
    /// break falls, when known. Ghostty reports no soft wrap a multiplexer
    /// or an agent TUI drew, so a word broken across rows reads as two.
    /// Where the screen cannot tell, what is `known` may.
    func rowBreak(
        isBrokenAtEdge: Bool, columns: Int?, placement: AttachLinkRowJoin.Placement?,
        known: AttachKnownTargets, next: Substring
    ) -> AttachRowBreak
}

extension AttachTextCandidateScanner {
    mutating func cursorDidMove(wrappingRow: Bool) {}
    mutating func rowDidContinue() {}

    /// Bytes that always end a candidate: blanks and C0 controls, DEL,
    /// quotes, and angle brackets.
    static func isCandidateBoundary(_ byte: UInt8) -> Bool {
        byte <= 0x20 || byte == 0x7F
            || byte == 0x22 || byte == 0x27
            || byte == 0x3C || byte == 0x3E
    }
}

/// Whether a web URL a row break cut runs on into the next row, read the
/// same way for the Attach Links list and for a tap on the link. Ghostty
/// reports no soft wrap that a multiplexer repainting by cursor moves
/// (`herdr`, mosh) or an agent TUI wrapping its own text drew, so such a URL
/// is two words on two rows.
enum AttachLinkRowJoin {
    /// Where a row break falls on the grid, in cells from its first column,
    /// a character a cell.
    struct Placement: Equatable, Sendable {
        /// The cell the head row's last word starts in: the word holding the
        /// URL, a bracket or quote opening it included, or, when that word
        /// runs on from a row above, the row's text.
        var headStart: Int
        /// The cell just past the head row's last character, a frame
        /// column drawn past its text aside.
        var headEnd: Int
        /// The cell just past the last the head row's text can reach: the
        /// grid's width, or, where a frame column fills its last cell, that
        /// frame column's.
        var edge: Int
        /// The cell the next row's text starts in, past its indentation and
        /// a frame column opening it.
        var nextStart: Int

        init(headStart: Int, headEnd: Int, edge: Int, nextStart: Int) {
            self.headStart = headStart
            self.headEnd = headEnd
            self.edge = edge
            self.nextStart = nextStart
        }

        /// Whether a terminal broke the row inside a word: it wraps
        /// characters, not words, at its last cell, so a row whose text
        /// fills that cell runs on into a next row whose text starts in the
        /// first (a shell's `printf`, a raw log line). Agent TUIs indent,
        /// pad or frame the rows they wrap, or stop short of the last cell.
        var isTerminalWrap: Bool {
            nextStart == 0 && headEnd == edge
        }

        /// Whether, at a row an agent TUI's word wrapper broke near the
        /// edge, the next row's first word, `nextWordLength` cells long,
        /// runs on the head word, or nil where the placement cannot tell.
        /// A wrapper moves a word that fits down whole and hard-breaks only
        /// a longer one, filling the row to its own edge, where the head's
        /// row ends. A head word starting further into its row than the
        /// next row's text starts runs on only when the two together could
        /// not have been moved down whole up to that edge; a next row
        /// starting further in than the head word (Pi keeps the blank after
        /// a link it wrapped) holds a word of its own. A head word filling
        /// its row from the row's start is as long as a row: it may have
        /// been cut, or only fit. Nor can a next row starting in the first
        /// column below a row ending two or more cells short of the edge
        /// tell: a box that wraps by character (Maki's input) cuts a word
        /// anywhere there, with its rest unindented. A row a terminal
        /// wrapped ends a cell short only where a blank filled that cell.
        func wordWrapRunsOn(nextWordLength: Int) -> Bool? {
            if nextStart == 0, headEnd < edge - 1 {
                return nil
            }
            if headStart > nextStart {
                return nextStart + nextWordLength > headStart
            }
            return headStart < nextStart ? false : nil
        }

        /// Whether, at a row broken near the edge, the path word `head`
        /// ends it with runs on into `nextWord`, the next row's first word,
        /// by where the break falls, as the Files list and a tap read it: a
        /// terminal's wrap runs on, and so does a word with a `/` of its
        /// own, already a path that a prompt wrapping by character may cut
        /// anywhere (Cline's `… /` above `tmp/shot.png`, Maki's `/t` above
        /// `mp/shot.png`); a word without one above a rooted path (`and`
        /// above `/tmp/shot.png`) stays apart; any other runs on as
        /// `wordWrapRunsOn(nextWordLength:)` says, and nil where the
        /// placement cannot tell.
        func pathRunsOn(head: some StringProtocol, nextWord: some StringProtocol) -> Bool? {
            if isTerminalWrap || head.contains("/") {
                return true
            }
            if let first = nextWord.first, first == "/" || first == "~" {
                return false
            }
            return wordWrapRunsOn(nextWordLength: nextWord.count)
        }
    }

    /// Whether `nextRowText` carries on the URL `headWord` ends its row
    /// with. `headWord` is the row's last word from the URL's scheme, or a
    /// word ending in the first letters of one (`htt`); `nextRowText` is the
    /// next row's text, its indentation skipped here, and a frame column
    /// opening it on a row open on the right (Kilo's `┃`); `endsNearEdge`
    /// is whether the head's row ends within two cells of the grid's last
    /// column, or of a frame column drawn in it; `columns` is the grid's
    /// width, when known; `placement` is where on the grid the break falls,
    /// when known; `known` is what the stream and the Agent's transcript
    /// hold whole.
    ///
    /// The next row's first word carries the URL on only when it starts
    /// with a character a URL takes, holds a letter or number past its
    /// trailing punctuation, and begins nothing of its own: no `://` in it,
    /// and no scheme opening it (`mailto:`, `tel:+1`; a port, `ost:3000`,
    /// is no scheme). Then a known target that runs on from the URL into
    /// that word carries it on, wherever the row broke (OpenCode's
    /// `…/untested/` above `averyveryverylongsegmentname`). Otherwise no
    /// path does: a `~` opening the word, or a `/` other than one a wrapper
    /// cut a URL right before at the edge. A URL ending in one of
    /// `-_=&+~%#@` runs on, as no URL ends with one. Any other stays apart
    /// from a word a bracket or backtick opens.
    ///
    /// At the edge, a row a terminal wrapped (`Placement.isTerminalWrap`, a
    /// shell's `printf`) runs on; elsewhere a URL ended by a `.` stays apart
    /// from a word naming a file, and where the break falls may show the
    /// URL whole (`Placement.wordWrapRunsOn`): one that ended its row stays
    /// apart from `README.md`, `follow-up`, `e.g.`, `v1.2` or `10:30` it
    /// could have shared the next row with. Where it may have been cut, a
    /// URL the transcript holds whole stays apart, and the next word
    /// carries it on when it has a URL character (`/ . - _ ? = & # % ~ :`)
    /// past its trailing punctuation, or, of letters and digits alone
    /// (`…/trig_01Ur` above `4tPocEZW…`), when the two together are longer
    /// than the row. Off the edge (Codex, OpenCode), a URL ending in `/` or
    /// `.` runs on into a word with a `/` of its own, or with a query's `?`
    /// or `=` (or, after a `/`, a `&` or a fragment's `#`). A scheme broken
    /// at the edge (`htt` above `ps://…`) runs on into its rest.
    static func continues(
        headWord: Substring, nextRowText: Substring, endsNearEdge: Bool, columns: Int?,
        placement: Placement? = nil, known: AttachKnownTargets = AttachKnownTargets()
    ) -> Bool {
        rowBreak(
            headWord: headWord, next: nextRowText.rowContent(below: nil, columns: nil),
            endsNearEdge: endsNearEdge, columns: columns, placement: placement, known: known)
            == .continues
    }

    /// How the URL `headWord` meets the row break above `next`, its text
    /// already past its indentation, as
    /// `continues(headWord:nextRowText:endsNearEdge:columns:placement:known:)`
    /// reads it: `.continues` where the next row carries it on, `.whole`
    /// where the break's placement or the transcript shows it whole, and
    /// nil where it stays apart but may still have been cut.
    fileprivate static func rowBreak(
        headWord: Substring, next: Substring, endsNearEdge: Bool, columns: Int?,
        placement: Placement?, known: AttachKnownTargets
    ) -> AttachRowBreak? {
        guard headWord.contains("://") else {
            return endsNearEdge && continuesScheme(headWord, next: next) ? .continues : nil
        }
        // Where the row broke near the edge, as far as its placement shows.
        let wrapped = endsNearEdge ? placement : nil
        let isTerminalWrap = wrapped?.isTerminalWrap == true
        let word = firstWord(of: next)
        if word.isEmpty {
            // Above a row with no text, which a streaming TUI may not have
            // drawn yet, only the transcript can show the URL whole.
            return known.holdsWhole(trimmingTrailingPunctuation(headWord), above: word) ? .whole : nil
        }
        guard let first = word.first, PlainAttachLinkScanner.isWordCharacter(first),
              !word.contains("://"), !beginsScheme(word)
        else { return nil }
        // A bullet's `-` or a lone mark carries nothing on.
        let trimmed = trimmingTrailingPunctuation(word)
        guard trimmed.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        if known.continues(head: headWord, next: trimmed) {
            return .continues
        }
        // A wrapper may cut a URL right before one of its own `/`s; a `/`
        // opening the row anywhere else, or a `~`, opens a path.
        if !isTerminalWrap,
           first == "~" || (first == "/" && (wrapped == nil || headWord.last == "/"))
        {
            return nil
        }
        switch headWord.last {
        case "-", "_", "=", "&", "+", "~", "%", "#", "@":
            return .continues
        default:
            break
        }
        if "([{`".contains(first) {
            return nil
        }
        if isTerminalWrap {
            return .continues
        }
        if headWord.last == "." && namesFile(trimmed) {
            return nil
        }
        if wrapped?.wordWrapRunsOn(nextWordLength: word.count) == false {
            return .whole
        }
        if endsNearEdge {
            if known.holdsWhole(trimmingTrailingPunctuation(headWord), above: word) {
                return .whole
            }
            guard trimmed.contains(where: isURLCharacter) else {
                guard let columns, headWord.count + trimmed.count > columns else { return nil }
                return .continues
            }
            return .continues
        }
        switch headWord.last {
        case "/" where word.contains("/") || trimmed.contains(where: { "?=&#".contains($0) }),
            "." where word.contains("/") || trimmed.contains(where: { "?=".contains($0) }):
            return .continues
        default:
            return nil
        }
    }

    /// Whether `word` could carry a URL on, though it may begin its own
    /// candidate or be one's tail instead: it starts with a character a URL
    /// takes, holds no new URL, and has a URL character and a letter or
    /// number past its trailing punctuation.
    fileprivate static func couldCarryURL(_ word: Substring) -> Bool {
        guard let first = word.first, PlainAttachLinkScanner.isWordCharacter(first),
              !word.contains("://")
        else { return false }
        let trimmed = trimmingTrailingPunctuation(word)
        return trimmed.contains(where: isURLCharacter)
            && trimmed.contains(where: { $0.isLetter || $0.isNumber })
    }

    /// Whether `word` opens with a URI scheme of its own, `name:` with no
    /// digit after it, as a port would have.
    private static func beginsScheme(_ word: Substring) -> Bool {
        guard let colon = word.firstIndex(of: ":") else { return false }
        let name = word[..<colon]
        guard name.count >= 2, let initial = name.first, initial.isASCII, initial.isLetter,
              name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+.-".contains($0)) })
        else { return false }
        let rest = word[word.index(after: colon)...]
        return !(rest.first.map { $0.isASCII && $0.isNumber } ?? false)
    }

    fileprivate static func firstWord(of text: Substring) -> Substring {
        text.prefix { !$0.isWhitespace }
    }

    /// Whether `head` ends with the first letters of a web scheme the next
    /// row's text completes.
    private static func continuesScheme(_ head: Substring, next: Substring) -> Bool {
        for scheme in ["https://", "http://"] {
            for length in 1..<scheme.count {
                let start = scheme.prefix(length)
                guard head.count >= length,
                      head.suffix(length).lowercased() == start,
                      next.lowercased().hasPrefix(scheme.dropFirst(length))
                else { continue }
                return true
            }
        }
        return false
    }

    private static func isURLCharacter(_ character: Character) -> Bool {
        "/.-_?=&#%~:".contains(character)
    }

    private static func trimmingTrailingPunctuation(_ word: Substring) -> Substring {
        var text = word
        while let last = text.last {
            if ".,;:!?*`".contains(last) {
                text = text.dropLast()
            } else if let opener = ([")": "(", "]": "[", "}": "{"] as [Character: Character])[last],
                text.filter({ $0 == last }).count > text.filter({ $0 == opener }).count
            {
                text = text.dropLast()
            } else {
                break
            }
        }
        return text
    }

    /// Whether `word`'s last path component ends in a file extension.
    private static func namesFile(_ word: Substring) -> Bool {
        let name = word.split(separator: "/").last ?? word
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let pathExtension = name[name.index(after: dot)...]
        return (1...8).contains(pathExtension.count)
            && pathExtension.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
            && pathExtension.contains(where: \.isLetter)
    }
}

private typealias AttachLinkScanner = AttachTerminalScanner<PlainAttachLinkScanner>

/// Removes terminal control content while preserving stream state across
/// arbitrary PTY chunks. SGR styling is transparent to visible candidates;
/// other controls end plain candidates. OSC 8 targets are collected
/// explicitly when `Candidates` asks for them, so their labels cannot hide
/// or replace the real destination.
///
/// Text is read as Ghostty draws it, UTF-8 throughout: only 7-bit escape
/// sequences are controls. A lone 0x80–0x9F byte would be a C1 control to
/// an 8-bit terminal, but Ghostty decodes UTF-8 first, and such a byte is
/// the second or third of many characters Agent TUIs draw (`❯` is E2 9D AF,
/// `│` is E2 94 82), so it is text.
///
/// Each candidate is reported with how it ended. A character printed right
/// after it (a quote, an angle bracket, a glyph `Candidates` does not take)
/// or a line break ends it `.whole`. A cursor move ends it `.cut`:
/// a multiplexer repainting by cursor moves leaves the rest of a wrapped
/// URL on the next row, and a diff frame or a streaming TUI may move on
/// before the rest is drawn. A blank, a box-drawing or block glyph (a
/// scrollbar `█` drawn in the cell after it), or a control that does not
/// move the cursor, ends it `.cut` too, until printable ASCII or a line
/// break on its row shows it `.confirmed`: Pi pads a URL it cut with a
/// blank, OpenCode with blanks and a scrollbar, Qwen with its input box's
/// scrollbar alone, before the next row. An OSC 8 target is reported
/// `.cut`, as an agent TUI streams one before its URL is whole (OpenCode,
/// oh-my-pi), and confirmed the same way once its label closes with no
/// cursor move inside it.
///
/// The stream's cursor is followed as far as its moves and text show, on a
/// grid `columns` wide when known: a move to the next row's first column
/// right after text that reached the edge is how a TUI moves on to the
/// rest of a word it hard-wrapped (`Candidates.cursorDidMove(wrappingRow:)`).
struct AttachTerminalScanner<Candidates: AttachTextCandidateScanner> {
    typealias Record = (_ candidate: String, _ ending: AttachCandidateEnding) -> Void

    private enum State: Equatable {
        case text
        case escape
        case escapeSequence
        case csi
        case osc
        case oscEscape
        case stringControl
        case stringControlEscape
    }

    /// How the scanner itself ends the plain candidate being read.
    private enum Break {
        case cut
        /// `.cut` until something printed on its row confirms it.
        case unconfirmed
        /// `.wholeAtRowEnd`.
        case rowEnd
        /// `.whole`.
        case whole
    }

    /// How many blank cells may follow a row's text for the row still to
    /// read as broken at the edge, as `UITerminalView.pathRunEdgeSlack`.
    private static var rowEdgeSlack: Int { 2 }
    private static var maximumCSIParameter: Int { 10_000 }

    /// The grid's width, when known, for following the stream's cursor.
    var columns: Int?

    private var state = State.text
    private var plain = Candidates()
    private var osc = OSC8Accumulator()
    private var isOSC8LabelActive = false
    /// The last candidate a blank or a non-moving control ended, reported
    /// `.cut`, while nothing after it on its row has shown it whole.
    private var unconfirmed: String?
    /// The open OSC 8 hyperlink's target, while no cursor move has broken
    /// its label.
    private var hyperlinkTarget: String?
    /// The two text bytes read before the current one, to tell the glyph a
    /// candidate ended on.
    private var previousTextBytes: (UInt8, UInt8) = (0, 0)
    /// The CSI sequence being read: how many `;` it has had, and its first
    /// two parameters' values so far, capped.
    private var csiSeparators = 0
    private var csiFirstParameter = 0
    private var csiSecondParameter = 0
    /// The stream's cursor, one-based, where its moves and text show it.
    private var cursorRow: Int?
    private var cursorColumn: Int?

    mutating func receive(_ data: Data, record: Record) {
        for byte in data {
            receive(byte, record: record)
        }
    }

    mutating func finishOutput(record: Record) {
        finishPlainCandidate(.cut, record: record)
        unconfirmed = nil
        hyperlinkTarget = nil
        state = .text
        osc.reset()
        isOSC8LabelActive = false
    }

    /// Reads Ghostty's visible text, one row per line, from a grid `columns`
    /// wide when known. Each row's trailing blanks are dropped, and a frame
    /// column drawn past them (a box's `│`, OpenCode's scrollbar `█`, any
    /// U+2500–U+259F glyph) with them, as is one glued to the row's text in
    /// the grid's last cell (Qwen's scrollbar); its indentation is skipped,
    /// and a frame column that opens it as `Substring.rowContent(below:columns:)`
    /// says. At each row break, `Candidates.rowBreak` says how the word
    /// being read meets the next row, told where the break falls
    /// (`AttachLinkRowJoin.Placement`) and what is `known`: the edge is the
    /// last of `columns` within `rowEdgeSlack` cells, counting a character
    /// a cell, so a wide one makes a row look shorter and errs toward an
    /// ordinary break. A word the next row carries on is read across the
    /// break; one cut there ends `.cut` and the next row's text starts as
    /// after a cursor move; an ambiguous one ends `.cut`; any other ends
    /// `.wholeAtRowEnd`. The text's end is no row break: a word reaching it
    /// ends `.cut`. Without `columns`, no row breaks at the edge.
    mutating func receiveViewportText(
        _ text: String, columns: Int?, known: AttachKnownTargets, record: Record
    ) {
        var above: Substring?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let content = line.rowContent(below: above, columns: columns)
            defer { above = line }
            if let above {
                confirmCandidate(record: record)
                let placement = Self.placement(above: above, next: line, content, columns: columns)
                switch plain.rowBreak(
                    isBrokenAtEdge: placement.map { Self.isBrokenAtEdge(above, at: $0, columns: columns) }
                        ?? false,
                    columns: columns, placement: placement, known: known, next: content)
                {
                case .continues:
                    plain.rowDidContinue()
                case .cut:
                    finishPlainCandidate(.cut, record: record)
                    plain.cursorDidMove(wrappingRow: false)
                case .ambiguous:
                    finishPlainCandidate(.cut, record: record)
                    receive(0x0A, record: record)
                case .ends:
                    finishPlainCandidate(.rowEnd, record: record)
                    receive(0x0A, record: record)
                case .whole:
                    finishPlainCandidate(.whole, record: record)
                    receive(0x0A, record: record)
                }
            }
            for byte in content.utf8 {
                receive(byte, record: record)
            }
        }
        confirmCandidate(record: record)
        finishOutput(record: record)
    }

    private mutating func receive(_ byte: UInt8, record: Record) {
        switch state {
        case .text:
            receiveText(byte, record: record)

        case .escape:
            receiveAfterEscape(byte, record: record)

        case .escapeSequence:
            if (0x30...0x7E).contains(byte) {
                state = .text
            } else if byte == 0x1B {
                state = .escape
            }

        case .csi:
            if (0x40...0x7E).contains(byte) {
                finishCSI(byte, record: record)
            } else if byte == 0x1B {
                finishPlainCandidate(.unconfirmed, record: record)
                state = .escape
            } else if byte == 0x3B {
                csiSeparators += 1
            } else if (0x30...0x39).contains(byte) {
                let digit = Int(byte - 0x30)
                switch csiSeparators {
                case 0:
                    csiFirstParameter = min(csiFirstParameter * 10 + digit, Self.maximumCSIParameter)
                case 1:
                    csiSecondParameter = min(csiSecondParameter * 10 + digit, Self.maximumCSIParameter)
                default:
                    break
                }
            }

        case .osc:
            if byte == 0x07 {
                finishOSC(record: record)
            } else if byte == 0x1B {
                state = .oscEscape
            } else {
                osc.receive(byte)
            }

        case .oscEscape:
            if byte == 0x5C {
                finishOSC(record: record)
            } else {
                osc.invalidate()
                state = byte == 0x1B ? .oscEscape : .osc
            }

        case .stringControl:
            if byte == 0x1B {
                state = .stringControlEscape
            }

        case .stringControlEscape:
            state = byte == 0x5C ? .text : .stringControl
        }
    }

    private mutating func receiveText(_ byte: UInt8, record: Record) {
        guard byte != 0x1B else {
            state = .escape
            return
        }
        followCursor(over: byte)
        // Printable ASCII or a line break shows the row went on past the
        // blank; more blanks, styling, and frame glyphs do not.
        if (0x21...0x7E).contains(byte) || byte == 0x0A || byte == 0x0D {
            confirmCandidate(record: record)
        }
        defer { previousTextBytes = (previousTextBytes.1, byte) }
        guard !isOSC8LabelActive else { return }
        var ended: String?
        plain.receive(byte) { ended = $0 }
        guard let ended else { return }
        if byte == 0x20 || byte == 0x09 || endsFrameGlyph(byte) {
            record(ended, .cut)
            unconfirmed = ended
        } else {
            record(ended, .whole)
        }
    }

    /// Moves the followed cursor past a text byte: a character a cell (the
    /// first byte of each), a carriage return to the row's start, a line
    /// feed down a row; a tab leaves the column unknown.
    private mutating func followCursor(over byte: UInt8) {
        switch byte {
        case 0x0D:
            cursorColumn = 1
        case 0x0A:
            cursorRow = cursorRow.map { $0 + 1 }
        case 0x08:
            cursorColumn = cursorColumn.map { max($0 - 1, 1) }
        case 0x09:
            cursorColumn = nil
        case 0x20...0x7E, 0xC0...0xFF:
            cursorColumn = cursorColumn.map { $0 + 1 }
        default:
            break
        }
    }

    /// Whether `byte` is the last of a box-drawing or block glyph,
    /// U+2500–U+259F (E2 94 80 – E2 96 9F), after the two text bytes before
    /// it.
    private func endsFrameGlyph(_ byte: UInt8) -> Bool {
        guard previousTextBytes.0 == 0xE2 else { return false }
        switch previousTextBytes.1 {
        case 0x94, 0x95: return (0x80...0xBF).contains(byte)
        case 0x96: return (0x80...0x9F).contains(byte)
        default: return false
        }
    }

    private mutating func receiveAfterEscape(_ byte: UInt8, record: Record) {
        switch byte {
        case 0x5B:
            csiSeparators = 0
            csiFirstParameter = 0
            csiSecondParameter = 0
            state = .csi
        case 0x5D:
            osc.reset()
            state = .osc
        case 0x50, 0x58, 0x5E, 0x5F:
            finishPlainCandidate(.unconfirmed, record: record)
            state = .stringControl
        case 0x20...0x2F:
            finishPlainCandidate(.unconfirmed, record: record)
            state = .escapeSequence
        case 0x38:  // DECRC: back to a saved cursor
            cursorDidMove(to: (nil, nil), record: record)
            state = .text
        case 0x44:  // IND
            cursorDidMove(to: (cursorRow.map { $0 + 1 }, cursorColumn), record: record)
            state = .text
        case 0x45:  // NEL
            cursorDidMove(to: (cursorRow.map { $0 + 1 }, 1), record: record)
            state = .text
        case 0x4D:  // RI
            cursorDidMove(to: (cursorRow.map { $0 - 1 }, cursorColumn), record: record)
            state = .text
        case 0x63:  // RIS
            cursorDidMove(to: (1, 1), record: record)
            state = .text
        default:
            finishPlainCandidate(.unconfirmed, record: record)
            state = .text
        }
    }

    private mutating func finishCSI(_ final: UInt8, record: Record) {
        state = .text
        guard final != 0x6D else { return }
        if Self.isCursorMoveFinal(final) {
            cursorDidMove(to: cursorTarget(final), record: record)
        } else {
            finishPlainCandidate(.unconfirmed, record: record)
        }
    }

    /// Where the cursor move the CSI sequence ending in `final` lands, row
    /// and column, as far as the followed cursor and its parameters show.
    private func cursorTarget(_ final: UInt8) -> (row: Int?, column: Int?) {
        let count = max(csiFirstParameter, 1)
        switch final {
        case 0x48, 0x66:  // CUP, HVP
            return (count, csiSeparators == 0 ? 1 : max(csiSecondParameter, 1))
        case 0x41:  // CUU
            return (cursorRow.map { $0 - count }, cursorColumn)
        case 0x42, 0x65:  // CUD, VPR
            return (cursorRow.map { $0 + count }, cursorColumn)
        case 0x43, 0x61:  // CUF, HPR
            return (cursorRow, cursorColumn.map { $0 + count })
        case 0x44:  // CUB
            return (cursorRow, cursorColumn.map { max($0 - count, 1) })
        case 0x45:  // CNL
            return (cursorRow.map { $0 + count }, 1)
        case 0x46:  // CPL
            return (cursorRow.map { $0 - count }, 1)
        case 0x47, 0x60:  // CHA, HPA
            return (cursorRow, count)
        case 0x64:  // VPA
            return (count, cursorColumn)
        case 0x4C, 0x4D:  // IL, DL
            return (cursorRow, 1)
        case 0x72:  // DECSTBM
            return (1, 1)
        default:  // tabs
            return (cursorRow, nil)
        }
    }

    /// Ends the candidate at a cursor move landing at `target`, telling
    /// `Candidates` whether the move goes on to the next row's first column
    /// right after text that reached the grid's edge.
    private mutating func cursorDidMove(to target: (row: Int?, column: Int?), record: Record) {
        var wrapsRow = false
        if target.column == 1, let columns, let column = cursorColumn,
           column - 1 >= columns - Self.rowEdgeSlack
        {
            if let row = cursorRow, let next = target.row {
                wrapsRow = next == row + 1
            } else {
                wrapsRow = true
            }
        }
        cursorRow = target.row
        cursorColumn = target.column
        finishPlainCandidate(.cut, record: record)
        unconfirmed = nil
        hyperlinkTarget = nil
        plain.cursorDidMove(wrappingRow: wrapsRow)
    }

    private mutating func finishOSC(record: Record) {
        defer {
            osc.reset()
            state = .text
        }
        finishPlainCandidate(.unconfirmed, record: record)
        guard Candidates.collectsHyperlinkTargets, let hyperlink = osc.hyperlink else {
            return
        }

        switch hyperlink {
        case .close:
            isOSC8LabelActive = false
            if let target = hyperlinkTarget {
                hyperlinkTarget = nil
                unconfirmed = target
            }
        case .open(let target):
            isOSC8LabelActive = true
            hyperlinkTarget = target
            if let target {
                record(target, .cut)
            }
        }
    }

    private mutating func finishPlainCandidate(_ end: Break, record: Record) {
        guard !isOSC8LabelActive, let target = plain.finishOutput() else { return }
        switch end {
        case .cut:
            record(target, .cut)
        case .unconfirmed:
            record(target, .cut)
            unconfirmed = target
        case .rowEnd:
            record(target, .wholeAtRowEnd)
        case .whole:
            record(target, .whole)
        }
    }

    private mutating func confirmCandidate(record: Record) {
        guard let target = unconfirmed else { return }
        unconfirmed = nil
        record(target, .confirmed)
    }

    /// CSI final bytes that move the cursor: `A`–`H` (up, down, forward,
    /// back, next and previous line, column, position), `I` and `Z` (tab
    /// forward and back), `L` and `M` (insert and delete lines, which return
    /// to the left margin), `` ` `` and `a` (column absolute and relative),
    /// `d` and `e` (row absolute and relative), `f` (position), and `r`
    /// (scroll region, which homes the cursor).
    private static func isCursorMoveFinal(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x41...0x49, 0x4C, 0x4D, 0x5A, 0x60, 0x61, 0x64...0x66, 0x72:
            true
        default:
            false
        }
    }

    /// Whether `line`, trimmed, ends with a word character within
    /// `rowEdgeSlack` cells of `placement`'s edge: the grid's last column,
    /// or, when a frame column drawn past its text fills that last cell,
    /// the frame, as `UITerminalView.pathRun(at:)` reads a framed row for a
    /// tap.
    private static func isBrokenAtEdge(
        _ line: Substring, at placement: AttachLinkRowJoin.Placement, columns: Int?
    ) -> Bool {
        guard let last = line.trimmingRowEnd(columns: columns).last,
              Candidates.isWordCharacter(last)
        else { return false }
        return placement.headEnd >= placement.edge - rowEdgeSlack
    }

    /// Where the break between `above` and `next`, whose text past its
    /// indentation is `content`, falls on a grid `columns` wide: where
    /// `above`'s last word starts and its text ends, the edge it can reach,
    /// and where `content` starts. Nil without `columns`.
    private static func placement(
        above: Substring, next: Substring, _ content: Substring, columns: Int?
    ) -> AttachLinkRowJoin.Placement? {
        guard let columns else { return nil }
        let head = above.trimmingRowEnd(columns: columns)
        let wordStart = head.lastIndex(where: \.isWhitespace).map(head.index(after:))
            ?? head.startIndex
        let headEnd = above.distance(from: above.startIndex, to: head.endIndex)
        let drawn = above.droppingTrailingBlanks.count
        return AttachLinkRowJoin.Placement(
            headStart: above.distance(from: above.startIndex, to: wordStart),
            headEnd: headEnd,
            edge: drawn == columns && drawn != headEnd ? columns - 1 : columns,
            nextStart: next.distance(from: next.startIndex, to: content.startIndex))
    }
}

extension Substring {
    fileprivate var droppingTrailingBlanks: Substring {
        var text = self
        while text.last?.isWhitespace == true {
            text = text.dropLast()
        }
        return text
    }

    /// A viewport row without its trailing blanks, and without a frame
    /// column drawn past them, or glued to its text in the last cell of a
    /// grid `columns` wide (Qwen's scrollbar `█` after `…/unte`).
    fileprivate func trimmingRowEnd(columns: Int?) -> Substring {
        var row = droppingTrailingBlanks
        if let last = row.last, last.isFrameGlyph {
            let rest = row.dropLast()
            if rest.last?.isWhitespace ?? true || row.count == columns {
                row = rest.droppingTrailingBlanks
            }
        }
        return row
    }

    /// A viewport row's text, trailing blanks and a frame column past them
    /// aside (`trimmingRowEnd(columns:)`), past its indentation and a frame
    /// column opening it — where the row is open on the right (Kilo's `┃`)
    /// or the row `above` opens with the same glyph in the same column (a
    /// box's or OpenCode's cell's rows), as
    /// `UITerminalView.pathRunContentStart` reads a row for a tap. A row
    /// framed on both sides below an unframed one is a box's, no
    /// continuation of it, so its text starts at its border.
    fileprivate func rowContent(below above: Substring?, columns: Int?) -> Substring {
        let text = trimmingRowEnd(columns: columns).drop(while: \.isWhitespace)
        guard let first = text.first, first.isFrameGlyph,
              text.dropFirst().first?.isWhitespace ?? true
        else { return text }
        let column = distance(from: startIndex, to: text.startIndex)
        let isOpenOnTheRight = droppingTrailingBlanks.last?.isFrameGlyph != true
        let sharesBoxAbove = above.map { row in
            row.count > column && row[row.index(row.startIndex, offsetBy: column)] == first
        } ?? false
        guard isOpenOnTheRight || sharesBoxAbove else { return text }
        return text.dropFirst().drop(while: \.isWhitespace)
    }
}

extension Character {
    /// Box drawing and block elements, U+2500–U+259F.
    fileprivate var isFrameGlyph: Bool {
        unicodeScalars.allSatisfy { (0x2500...0x259F).contains($0.value) }
    }
}

private struct OSC8Accumulator {
    enum Hyperlink {
        case open(String?)
        case close
    }

    private enum Field: Equatable {
        case command
        case parameters
        case target
        case ignored
    }

    private static let maximumTargetBytes = 32 * 1024
    private static let maximumCommandBytes = 16

    private var field = Field.command
    private var command = Data()
    private var target = Data()
    private var isTargetOversized = false

    var hyperlink: Hyperlink? {
        guard field == .target else { return nil }
        guard !target.isEmpty else { return .close }
        guard !isTargetOversized,
            let target = String(data: target, encoding: .utf8)
        else {
            return .open(nil)
        }
        return .open(target)
    }

    mutating func receive(_ byte: UInt8) {
        switch field {
        case .command:
            if byte == 0x3B {
                field = command == Data("8".utf8) ? .parameters : .ignored
            } else if command.count < Self.maximumCommandBytes {
                command.append(byte)
            } else {
                field = .ignored
            }

        case .parameters:
            if byte == 0x3B {
                field = .target
            }

        case .target:
            guard !isTargetOversized else { return }
            guard target.count < Self.maximumTargetBytes else {
                target.removeAll(keepingCapacity: false)
                isTargetOversized = true
                return
            }
            target.append(byte)

        case .ignored:
            break
        }
    }

    mutating func invalidate() {
        field = .ignored
        command.removeAll(keepingCapacity: false)
        target.removeAll(keepingCapacity: false)
        isTargetOversized = false
    }

    mutating func reset() {
        field = .command
        command.removeAll(keepingCapacity: true)
        target.removeAll(keepingCapacity: true)
        isTargetOversized = false
    }
}

/// Recognizes plain web targets from printable terminal text. Network chunk
/// boundaries are invisible here; actual whitespace terminates candidates.
/// A character outside ASCII ends a candidate too, unless it is a letter, a
/// number, or a mark, as an internationalized host's are: an ellipsis, an
/// arrow, or a box rule glued to a URL is not part of it. A URL an ellipsis
/// ends with nothing printed after it on its row is a truncated display
/// (Qwen's queued prompt, `…/untest…`), no target at all; one with text
/// after it (`see https://x.com/guide… more`) is the URL it shows. All
/// state buffers have hard upper bounds.
private struct PlainAttachLinkScanner: AttachTextCandidateScanner {
    static let collectsHyperlinkTargets = true

    private static let maximumTargetBytes = 32 * 1024
    private static let longestSchemeBytes = Array("https://".utf8)
    private static let webSchemes = [
        Array("http://".utf8),
        Array("https://".utf8),
    ]
    private static let trailingSentencePunctuation = CharacterSet(charactersIn: ".,;:!*`")
    /// `…`, U+2026.
    private static let ellipsis: [UInt8] = [0xE2, 0x80, 0xA6]

    private var recent: [UInt8] = []
    private var candidate: [UInt8] = []
    private var isOversized = false
    /// The bytes of a character outside ASCII the candidate is reading, and
    /// how many it takes.
    private var scalar: [UInt8] = []
    private var scalarLength = 0
    /// A candidate an ellipsis ended, while nothing printed after it on its
    /// row has shown it more than a truncated display.
    private var elided: String?

    static func isWordCharacter(_ character: Character) -> Bool {
        if let byte = character.asciiValue {
            return !isCandidateBoundary(byte)
        }
        return character.unicodeScalars.allSatisfy(continuesTarget)
    }

    /// Runs a URL on across the row break when `AttachLinkRowJoin` says
    /// the next row carries it on, and ends it whole where it says the
    /// break's placement or the transcript shows it whole. A URL that does
    /// not run on is whole above prose, a new URL, or nothing that could
    /// carry it on (`.ends`): a link set on a line of its own above a blank
    /// row is whole too. It stays provisional where it may still have been
    /// cut: it reached the grid's edge, or the next word could have carried
    /// it on, or it ends in one of `-_=&+~%#@`, which no URL ends with. One
    /// a TUI streaming it stops a row short of the rest of (Kimi's
    /// `…/waycar/`) gives way once the row grows in place
    /// (`AttachLinkIndex.receiveViewportText(_:columns:)`).
    func rowBreak(
        isBrokenAtEdge: Bool, columns: Int?, placement: AttachLinkRowJoin.Placement?,
        known: AttachKnownTargets, next: Substring
    ) -> AttachRowBreak {
        let head: String
        if !candidate.isEmpty, !isOversized, scalar.isEmpty {
            head = String(decoding: candidate, as: UTF8.self)
        } else if candidate.isEmpty, !isOversized, !recent.isEmpty {
            head = String(decoding: recent, as: UTF8.self)
        } else {
            return .ends
        }
        if let joined = AttachLinkRowJoin.rowBreak(
            headWord: head[...], next: next, endsNearEdge: isBrokenAtEdge, columns: columns,
            placement: placement, known: known)
        {
            return joined
        }
        guard let last = candidate.last else { return .ends }
        let word = AttachLinkRowJoin.firstWord(of: next)
        if "-_=&+~%#@".utf8.contains(last) {
            return .ambiguous
        }
        if word.isEmpty {
            return isBrokenAtEdge ? .ambiguous : .ends
        }
        if isBrokenAtEdge {
            return word.first.map(Self.isWordCharacter) == true ? .ambiguous : .ends
        }
        return AttachLinkRowJoin.couldCarryURL(word) ? .ambiguous : .ends
    }

    mutating func receive(_ byte: UInt8, record: (String) -> Void) {
        if let shown = elided {
            switch byte {
            case 0x21...0x7E:
                // Text after the ellipsis: the URL is what it shows.
                elided = nil
                record(shown)
            case 0x0A, 0x0D:
                elided = nil
            default:
                break
            }
        }
        if Self.isCandidateBoundary(byte) {
            if let target = finishCandidate() {
                record(target)
            }
            recent.removeAll(keepingCapacity: true)
            return
        }

        if !candidate.isEmpty || isOversized {
            if byte < 0x80, scalar.isEmpty {
                appendToCandidate(byte)
            } else if let target = receiveScalarByte(byte) {
                record(target)
                recent.removeAll(keepingCapacity: true)
            }
            return
        }

        recent.append(byte)
        if recent.count > Self.longestSchemeBytes.count {
            recent.removeFirst(recent.count - Self.longestSchemeBytes.count)
        }
        guard let scheme = Self.webSchemes.first(where: { recentEnds(with: $0) })
        else { return }
        candidate = Array(recent.suffix(scheme.count))
        recent.removeAll(keepingCapacity: true)
    }

    mutating func finishOutput() -> String? {
        defer { recent.removeAll(keepingCapacity: true) }
        elided = nil
        return finishCandidate()
    }

    /// Reads one byte of a character outside ASCII inside a candidate,
    /// returning the candidate when the whole character ends it. A
    /// malformed sequence is kept as read, so the candidate fails to decode.
    private mutating func receiveScalarByte(_ byte: UInt8) -> String? {
        if scalar.isEmpty {
            switch byte {
            case 0xC2...0xDF: scalarLength = 2
            case 0xE0...0xEF: scalarLength = 3
            case 0xF0...0xF4: scalarLength = 4
            default:
                appendToCandidate(byte)
                return nil
            }
            scalar.append(byte)
            return nil
        }
        guard (0x80...0xBF).contains(byte) else {
            for read in scalar {
                appendToCandidate(read)
            }
            scalar.removeAll(keepingCapacity: true)
            appendToCandidate(byte)
            return nil
        }
        scalar.append(byte)
        guard scalar.count == scalarLength else { return nil }
        defer { scalar.removeAll(keepingCapacity: true) }
        let continues = String(decoding: scalar, as: UTF8.self).unicodeScalars
            .allSatisfy(Self.continuesTarget)
        guard continues else {
            // A display that elides its text shows a URL only with text
            // after it on its row.
            if scalar == Self.ellipsis {
                elided = finishCandidate()
                return nil
            }
            return finishCandidate()
        }
        for read in scalar {
            appendToCandidate(read)
        }
        return nil
    }

    private static func continuesTarget(_ scalar: Unicode.Scalar) -> Bool {
        let properties = scalar.properties
        if properties.isAlphabetic || properties.numericType != nil {
            return true
        }
        switch properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark:
            return true
        default:
            return false
        }
    }

    private mutating func appendToCandidate(_ byte: UInt8) {
        guard !isOversized else { return }
        guard candidate.count < Self.maximumTargetBytes else {
            candidate.removeAll(keepingCapacity: false)
            isOversized = true
            return
        }
        candidate.append(byte)
    }

    private mutating func finishCandidate() -> String? {
        defer {
            candidate.removeAll(keepingCapacity: true)
            scalar.removeAll(keepingCapacity: true)
            isOversized = false
        }
        guard !isOversized, let text = String(bytes: candidate, encoding: .utf8) else {
            return nil
        }
        let target = Self.removingSurroundingPunctuation(from: text)
        return target.isEmpty ? nil : target
    }

    private func recentEnds(with suffix: [UInt8]) -> Bool {
        guard recent.count >= suffix.count else { return false }
        return zip(recent.suffix(suffix.count), suffix).allSatisfy {
            Self.lowercasedASCII($0.0) == $0.1
        }
    }

    private static func lowercasedASCII(_ byte: UInt8) -> UInt8 {
        (0x41...0x5A).contains(byte) ? byte + 0x20 : byte
    }

    private static func removingSurroundingPunctuation(from text: String) -> String {
        var target = text
        var removedCharacter = true
        while removedCharacter, let last = target.last {
            removedCharacter = false
            if last.unicodeScalars.allSatisfy(trailingSentencePunctuation.contains) {
                target.removeLast()
                removedCharacter = true
                continue
            }
            for (opening, closing) in [("(", ")"), ("[", "]"), ("{", "}")] {
                guard last == Character(closing) else { continue }
                let openingCount = target.reduce(into: 0) {
                    if $1 == Character(opening) { $0 += 1 }
                }
                let closingCount = target.reduce(into: 0) {
                    if $1 == Character(closing) { $0 += 1 }
                }
                if closingCount > openingCount {
                    target.removeLast()
                    removedCharacter = true
                }
                break
            }
        }
        return target
    }
}
