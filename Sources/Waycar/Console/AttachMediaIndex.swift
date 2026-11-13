import Foundation
import Observation

/// An image or document path the current Attach's terminal printed, as
/// printed and unresolved, with its kind and, for an image, how many times
/// the output stream printed it. A viewport rescan never counts: it redraws
/// what is already on screen. A path first found only on screen counts 1
/// as well, so it is fetched like any other, and the stream's first print
/// of it is that same sighting. A document always counts 1: it is read
/// only when tapped, and a TUI repainting a line that names it is no news.
struct AttachMediaCandidate: Equatable, Hashable, Sendable {
    let path: String
    let sightings: Int
    let kind: TerminalFileKind
}

/// Owns the bounded, memory-only list of image and document paths printed
/// during the current Attach, newest first, each exactly as printed:
/// absolute, under `~/`, or relative with a directory in it — or, for a
/// Markdown or PDF document, a bare name (`README.md`) — and resolved
/// against the Agent's directory only when fetched. A terminal pipeline
/// may be replaced without replacing this index; the enclosing
/// `AgentAttachStore` clears it on leave, like its `AttachLinkIndex`.
@MainActor
@Observable
final class AttachMediaIndex {
    /// How many paths the index keeps, newest first; an older one is dropped.
    nonisolated static let maximumPathCount = 25
    private(set) var candidates: [AttachMediaCandidate] = []

    /// The candidates' paths, in the same order.
    var paths: [String] {
        candidates.map(\.path)
    }

    private var scanner = AttachMediaScanner()
    private var streamObservedPaths: Set<String> = []
    private var viewportOnlyPaths: Set<String> = []

    /// The grid's width, when known: the stream tells a path a TUI
    /// hard-wrapped at the edge (`/tmp` above `/shot.png`) by its rows
    /// reaching it, and takes no rest of one on its own.
    var gridColumns: Int? {
        get { scanner.columns }
        set { if scanner.columns != newValue { scanner.columns = newValue } }
    }

    func receive(_ data: Data) {
        var scanner = scanner
        scanner.receive(data) { path, ending in
            // A confirmation repeats a path already counted.
            if ending != .confirmed {
                recordStreamPath(path)
            }
        }
        self.scanner = scanner
    }

    /// Supplements stream discovery from Ghostty's current visible text, on
    /// the same terms as `AttachLinkIndex.receiveViewportText(_:columns:)`:
    /// every snapshot stands alone, and of an ambiguous prefix family only
    /// the longest path seen solely on screen is kept.
    ///
    /// A snapshot is applied at once. A path found only on screen takes its
    /// place by where it stands: the lower a row, the later it was drawn, so
    /// such a path is older than every known path below it and goes right
    /// after the oldest of them, or first when none is below it. A known
    /// path keeps its place, so the screen never rewrites the stream's
    /// recency, and a repeated snapshot changes nothing. At most
    /// `maximumPathCount` new paths are taken, the lowest first, and making
    /// room drops only paths the screen alone found, oldest first: a screen
    /// full of names never evicts a path the stream printed.
    ///
    /// Rows are read as `AttachTerminalScanner.receiveViewportText` reads
    /// them for links, as `UITerminalView.pathRun(at:)` reads them for a
    /// tap: a multiplexer that repaints by cursor moves (`herdr terminal
    /// attach`, mosh) and an agent TUI that wraps its own text both break a
    /// long path with no wrap Ghostty can see, so a path broken at the
    /// grid's edge, or after a `-` or before the rest of its directories,
    /// is read whole — unless the word the row ends with already names a
    /// file, so a list of paths each reaching the edge stays a list, or the
    /// next row opens a URL, or a sentence's `.` ends the row above a path
    /// of its own (`it.` above `/tmp/shot.png`, `release.` above
    /// `docs/notes.md`), as `AttachMediaPathScanner.rowBreak` says. A word
    /// run across such a break is never taken as a bare document name:
    /// prose wrapped at the edge (`see the` above `README.md`) would
    /// otherwise run two words into one. Where a row was cut but the next
    /// row's text is not its rest (`docs/` above `plan.md`), a relative
    /// path starting the next row is that cut's tail and is not taken.
    func receiveViewportText(_ text: String, columns: Int?) {
        var viewportScanner = AttachMediaScanner()
        var found: [String] = []
        viewportScanner.receiveViewportText(
            text, columns: columns, known: AttachKnownTargets()
        ) { path, ending in
            // A confirmation repeats a path already found.
            if ending != .confirmed {
                found.append(path)
            }
        }
        recordViewportPaths(found)
    }

    func finishOutput() {
        var scanner = scanner
        scanner.finishOutput { path, ending in
            if ending != .confirmed {
                recordStreamPath(path)
            }
        }
        self.scanner = scanner
    }

    func clear() {
        scanner = AttachMediaScanner()
        streamObservedPaths.removeAll(keepingCapacity: false)
        viewportOnlyPaths.removeAll(keepingCapacity: false)
        candidates.removeAll(keepingCapacity: false)
    }

    private func recordStreamPath(_ path: String) {
        // The scanner takes only paths that have a kind.
        guard let kind = TerminalFileKind.kind(forPath: path) else { return }
        removeViewportOnlyPrefixes(of: path)
        var sightings = 1
        if !kind.isDocument, !viewportOnlyPaths.contains(path),
           let existing = candidates.first(where: { $0.path == path })
        {
            sightings = existing.sightings + 1
        }
        record(AttachMediaCandidate(path: path, sightings: sightings, kind: kind))
        streamObservedPaths.insert(path)
        viewportOnlyPaths.remove(path)
    }

    /// Applies one snapshot's paths, `found` in screen order, top row first,
    /// as `receiveViewportText(_:columns:)` describes.
    private func recordViewportPaths(_ found: [String]) {
        // Lowest on screen first; a path shown twice stands where it was
        // drawn last.
        var onScreen: [String] = []
        var shown: Set<String> = []
        for path in found.reversed() where shown.insert(path).inserted {
            onScreen.append(path)
        }
        guard !onScreen.isEmpty else { return }

        // A path only the screen found, now shown longer, was cut short.
        let cutPrefixes = viewportOnlyPaths.filter { prefix in
            shown.contains(where: { $0 != prefix && $0.hasPrefix(prefix) })
        }
        var updated = candidates
        if !cutPrefixes.isEmpty {
            updated.removeAll { cutPrefixes.contains($0.path) }
        }

        var insertion = 0
        var insertedCount = 0
        for path in onScreen {
            if let index = updated.firstIndex(where: { $0.path == path }) {
                insertion = max(insertion, index + 1)
                continue
            }
            guard insertedCount < Self.maximumPathCount,
                  let kind = TerminalFileKind.kind(forPath: path),
                  !updated.contains(where: { $0.path != path && $0.path.hasPrefix(path) }),
                  !shown.contains(where: { $0 != path && $0.hasPrefix(path) })
            else { continue }
            let candidate = AttachMediaCandidate(path: path, sightings: 1, kind: kind)
            updated.insert(candidate, at: insertion)
            insertion += 1
            insertedCount += 1
        }

        // Room is made among the paths the screen alone found, oldest first.
        var excess = updated.count - Self.maximumPathCount
        for index in updated.indices.reversed() where excess > 0 {
            guard !streamObservedPaths.contains(updated[index].path) else { continue }
            updated.remove(at: index)
            excess -= 1
        }

        guard updated != candidates else { return }
        candidates = updated
        let retainedPaths = Set(updated.map(\.path))
        streamObservedPaths.formIntersection(retainedPaths)
        viewportOnlyPaths = retainedPaths.subtracting(streamObservedPaths)
    }

    private func removeViewportOnlyPrefixes(of path: String) {
        let prefixes = viewportOnlyPaths.filter {
            $0 != path && path.hasPrefix($0)
        }
        guard !prefixes.isEmpty else { return }
        candidates.removeAll { prefixes.contains($0.path) }
        viewportOnlyPaths.subtract(prefixes)
    }

    /// Puts `candidate` first in place of any earlier entry for its path,
    /// dropping the oldest past `maximumPathCount`.
    private func record(_ candidate: AttachMediaCandidate) {
        var updated = candidates
        updated.removeAll { $0.path == candidate.path }
        updated.insert(candidate, at: 0)
        if updated.count > Self.maximumPathCount {
            updated.removeLast(updated.count - Self.maximumPathCount)
        }
        guard updated != candidates else { return }
        candidates = updated
        let retainedPaths = Set(updated.map(\.path))
        streamObservedPaths.formIntersection(retainedPaths)
        viewportOnlyPaths.formIntersection(retainedPaths)
    }
}

private typealias AttachMediaScanner = AttachTerminalScanner<AttachMediaPathScanner>

/// Picks image and document paths out of printable terminal text, word by
/// word: the words `AttachLinkIndex` reads, ended by blanks, quotes and
/// angle brackets. Text is read as Ghostty draws it, UTF-8 throughout, so a
/// table's `│` stays one character and an OSC 8 label is scanned like any
/// other visible text. The word buffer has a hard upper bound.
///
/// A word that starts with a path character where the cursor was moved to,
/// past any blanks, may be the tail of a path a row break cut: a
/// multiplexer repainting a wrapped line by cursor moves draws its next row
/// that way, and pads the row it cut with blanks first. Such a word is
/// taken only as an absolute or `~/` path, never as a relative one or a
/// bare name; its head, without a slash before the break, was dropped.
///
/// A row that opens with a slash command and a dash (`/init - create an
/// AGENTS.md file`, Codex's welcome) describes the command: a bare
/// document name on it is no file the Agent wrote.
private struct AttachMediaPathScanner: AttachTextCandidateScanner {
    static let collectsHyperlinkTargets = false

    /// Where the row being read stands on opening with a slash command.
    private enum SlashCommandRow {
        /// No word of the row has ended yet.
        case opening
        /// Its first word is a slash command (`/init`).
        case command
        /// A dash followed the command: the rest describes it.
        case description
        case other
    }

    /// Longer than any path a Host opens (`PATH_MAX` is 4096 on Linux).
    private static let maximumWordBytes = 4096
    private static let dot = UInt8(ascii: ".")
    /// What Ghostty's path matcher takes as part of a path besides word
    /// characters (`path_chars` in its `src/config/url.zig`), as
    /// `UITerminalView.isPathRunCharacter(_:)` reads it.
    private static let pathSymbols: Set<Character> = [
        "_", "-", ".", "~", ":", "/", "?", "#", "@", "!", "$", "&", "*", "+", ";", "=", "%",
    ]

    private var word: [UInt8] = []
    private var isOversized = false
    /// Whether the word being read, or the next when none is, starts where
    /// the cursor was moved to. Blanks, styling and other controls before
    /// its first character keep it; a quote or angle bracket, a line break,
    /// or a word's end clears it.
    private var followsCursorMove = false
    /// Whether the word being read runs on from the row above, past a
    /// break with no wrap Ghostty could see. A word's end clears it.
    private var continuesAcrossRows = false
    /// Whether the word just ended could still run on as a path (it named
    /// no file).
    private var endedWordCouldRunOn = false
    /// Whether the word being read, or the next when none is, is the rest
    /// of such a word that reached the grid's edge, on the row the cursor
    /// moved on to (`/tmp` above `/shot.png`, as Hermes hard-wraps its
    /// echo): the stream cannot see the two whole, so the screen reads them.
    private var continuesCutWord = false
    private var slashCommandRow = SlashCommandRow.opening

    static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || pathSymbols.contains(character)
    }

    /// The next row carries the word on when its first word starts with a
    /// path character and begins no path or URL of its own (a URL, or,
    /// after a `.`, a name with a file's extension), and the row broke at
    /// the grid's edge, where a path's rest may start with its `/`, or
    /// after a character a wrapper breaks a path after, above a word that
    /// starts with no `/` or `~`: one of `-_=&+~%#@` always, `/` or `.`
    /// only when the next word has a `/` of its own. At the edge, where the
    /// break falls decides as it does for a tap
    /// (`AttachLinkRowJoin.Placement.pathRunsOn(head:nextWord:)`): a word a
    /// word wrapper could have moved down whole with the next one, or a
    /// word with no `/` above a rooted path (`and` above `/tmp/shot.png`),
    /// ends there, and one the placement cannot tell about runs on. A word
    /// with nothing of a path in it (a prose `-` or `--`) never runs on,
    /// nor does one that already names a file, so a list stays a list; one
    /// cut at the edge or after a `/` or `.` leaves the next row's text as
    /// after a cursor move.
    func rowBreak(
        isBrokenAtEdge: Bool, columns: Int?, placement: AttachLinkRowJoin.Placement?,
        known: AttachKnownTargets, next: Substring
    ) -> AttachRowBreak {
        guard !isOversized, let end = word.last else { return .ends }
        let nextWord = next.prefix { !$0.isWhitespace }
        guard let first = nextWord.first, Self.isWordCharacter(first),
              !nextWord.contains("://")
        else { return .ends }
        // A prose dash (`-`, `--`) carries no path on.
        if !word.contains(where: Self.isPathStem) {
            return .ends
        }
        // A sentence's `.` above a file's name ends there, but a dot
        // directory cut at the edge right after its `.` (`~/.` above
        // `agents/…`) runs on.
        let isDotDirectoryCut = isBrokenAtEdge
            && (word.count == 1 || word.dropLast().last == UInt8(ascii: "/"))
        if end == Self.dot, !isDotDirectoryCut, Self.filePath(in: String(nextWord)) != nil {
            return .ends
        }
        if pendingWordNamesFile {
            return isBrokenAtEdge ? .cut : .ends
        }
        if isBrokenAtEdge {
            let runsOn = placement?.pathRunsOn(
                head: String(decoding: word, as: UTF8.self), nextWord: nextWord)
            return runsOn == false ? .ends : .continues
        }
        if first == "/" || first == "~" {
            return .ends
        }
        switch end {
        case UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "="), UInt8(ascii: "&"),
            UInt8(ascii: "+"), UInt8(ascii: "~"), UInt8(ascii: "%"), UInt8(ascii: "#"),
            UInt8(ascii: "@"):
            return .continues
        case UInt8(ascii: "/"), Self.dot:
            return nextWord.contains("/") ? .continues : .cut
        default:
            return .ambiguous
        }
    }

    /// Whether `byte` can start or root a path: a letter or number (or any
    /// byte of a character outside ASCII), or `/`, `.` or `~`.
    private static func isPathStem(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x80...0xFF, 0x2E, 0x2F, 0x7E:
            true
        default:
            false
        }
    }

    /// Whether the word read so far, ended here, would name a file.
    private var pendingWordNamesFile: Bool {
        guard !isOversized, word.contains(Self.dot),
              let text = String(bytes: word, encoding: .utf8)
        else { return false }
        return Self.filePath(in: text) != nil
    }

    mutating func receive(_ byte: UInt8, record: (String) -> Void) {
        guard !Self.isCandidateBoundary(byte) else {
            let path = finishOutput()
            if byte == 0x0A || byte == 0x0D {
                startRow()
            } else if byte != 0x20, byte != 0x09 {
                followsCursorMove = false
            }
            if let path {
                record(path)
            }
            return
        }
        guard !isOversized else { return }
        guard word.count < Self.maximumWordBytes else {
            word.removeAll(keepingCapacity: false)
            isOversized = true
            return
        }
        word.append(byte)
    }

    mutating func cursorDidMove(wrappingRow: Bool) {
        let cutWord = wrappingRow && endedWordCouldRunOn
        startRow()
        followsCursorMove = true
        continuesCutWord = cutWord
    }

    mutating func rowDidContinue() {
        continuesAcrossRows = true
    }

    mutating func finishOutput() -> String? {
        let endsWord = !word.isEmpty || isOversized
        let describesCommand = slashCommandRow == .description
        let path = endsWord ? finishedPath(describesCommand: describesCommand) : nil
        // A rule or box edge reaching the edge (`───┐`, `▄▄▄`) is no path a
        // TUI cut: the word must hold a letter, digit, `.`, `/` or `~` of
        // ASCII.
        endedWordCouldRunOn = endsWord && !isOversized && !pendingWordNamesFile
            && word.contains(where: { $0 < 0x80 && Self.isPathStem($0) })
        if endsWord {
            followsCursorMove = false
            continuesCutWord = false
            advanceSlashCommandRow()
        }
        word.removeAll(keepingCapacity: true)
        isOversized = false
        continuesAcrossRows = false
        return path
    }

    /// The path the word being read names as it ends, or nil.
    private func finishedPath(describesCommand: Bool) -> String? {
        // Every accepted path ends in an extension; most words have no dot,
        // and skip the decoding and classification below.
        guard !isOversized, !continuesCutWord, word.contains(Self.dot),
              let text = String(bytes: word, encoding: .utf8),
              let path = Self.filePath(in: text)
        else { return nil }
        if followsCursorMove, !Self.isRooted(path), let first = text.first,
           Self.isWordCharacter(first)
        {
            return nil
        }
        // Two words of wrapped prose run together read as one bare name; a
        // path that really runs across the break names a directory. A bare
        // name describing a slash command is the command's subject.
        if continuesAcrossRows || describesCommand, !path.contains("/") {
            return nil
        }
        return path
    }

    private mutating func startRow() {
        followsCursorMove = false
        continuesCutWord = false
        slashCommandRow = .opening
    }

    /// Moves `slashCommandRow` past the word just read.
    private mutating func advanceSlashCommandRow() {
        switch slashCommandRow {
        case .opening:
            slashCommandRow = Self.isSlashCommand(word) ? .command : .other
        case .command:
            slashCommandRow = word == [UInt8(ascii: "-")] ? .description : .other
        case .description, .other:
            break
        }
    }

    /// `/` and a lowercase name, as agent TUIs list their commands.
    private static func isSlashCommand(_ word: [UInt8]) -> Bool {
        guard word.count > 1, word.first == UInt8(ascii: "/") else { return false }
        return word.dropFirst().allSatisfy {
            (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == UInt8(ascii: "-")
        }
    }

    /// The image or document path a printed word names, as printed, or nil.
    /// A path an agent's tool call or a Markdown image or link wraps
    /// (`Read(/tmp/shot.png)`, `![shot](./out/shot.png)`,
    /// `[spec](./spec.pdf)`, `--output=out/shot.png`) is read from after the
    /// opening parenthesis or `=` when the whole word is none.
    private static func filePath(in word: String) -> String? {
        if let path = acceptedPath(word) {
            return path
        }
        guard let opener = word.firstIndex(where: { $0 == "(" || $0 == "=" }) else {
            return nil
        }
        return acceptedPath(String(word[word.index(after: opener)...]))
    }

    /// The path `word` names when it is a file of a ``TerminalFileKind`` a
    /// Host path can reach: absolute, under `~/`, or relative with a
    /// directory in it. A bare image name is too often prose or relative to
    /// somewhere else, but a bare Markdown or PDF name (`README.md`,
    /// `report.pdf`) is how agents name the documents they write in their
    /// directory. A URL, a glob or template (`*.png`, `{a,b}.png`,
    /// `$OUT/a.png`, `frame_%04d.png`), and a path that climbs back out of
    /// a directory it names are no one file. A trailing `:line:column` is
    /// not part of the path.
    private static func acceptedPath(_ word: String) -> String? {
        let text = trimmingEdges(word)
        guard !text.contains("://"), !TerminalLinkTarget.isFileURL(text),
              !text.contains(where: { "*?[]{}$%".contains($0) }),
              case .file(let file)? = TerminalLinkTarget(text),
              !file.climbsBackOut,
              let kind = TerminalFileKind.kind(forPath: file.path),
              isReachable(file.path, kind: kind)
        else { return nil }
        return file.path
    }

    private static func isReachable(_ path: String, kind: TerminalFileKind) -> Bool {
        if isRooted(path) { return true }
        // `~user/…` is another user's home, never the Agent's directory, and
        // a relative `--out=dir/a.png` is an option whose value follows `=`.
        return !path.hasPrefix("~") && !path.contains("=")
            && (path.contains("/") || kind.isDocument)
    }

    /// Whether `path` names the same file wherever it is resolved from.
    private static func isRooted(_ path: String) -> Bool {
        path.hasPrefix("/") || path.hasPrefix("~/")
    }

    /// Strips what surrounds a path in prose, Markdown and the tables and
    /// lists agents draw: sentence punctuation, brackets and quotes, `*`
    /// emphasis, a `|` rule, and any glyph outside ASCII that is no letter
    /// or number — a box rule (`│`) a cell's edge leaves glued to it, a
    /// bullet (`•`, `●`, `⎿`), an arrow, or an ellipsis cutting it short.
    private static func trimmingEdges(_ word: String) -> String {
        var text = word
        while true {
            var edges = Substring(text)
            while let first = edges.first, isEdgeGlyph(first) {
                edges = edges.dropFirst()
            }
            while let last = edges.last, isEdgeGlyph(last) {
                edges = edges.dropLast()
            }
            let trimmed = TerminalLinkTarget.trimmingSurroundingPunctuation(String(edges))
            if trimmed == text {
                return text
            }
            text = trimmed
        }
    }

    private static func isEdgeGlyph(_ character: Character) -> Bool {
        character == "|" || character == "*"
            || (!character.isASCII && !character.isLetter && !character.isNumber)
    }
}
