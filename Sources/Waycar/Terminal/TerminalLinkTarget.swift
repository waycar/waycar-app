import Foundation
import UniformTypeIdentifiers

/// A file a terminal line names, as it was printed: possibly relative or under
/// `~`, with the `:line:column` a compiler, linter, or grep appends split off.
struct TerminalFileReference: Equatable, Sendable {
    let path: String
    let line: Int?
    let column: Int?
    /// Other readings of the same text, tried in order when `path` names no
    /// file: a path joined across a row break falls back to the row's own
    /// match, in case the text only ended at the edge.
    let fallbackPaths: [String]

    init(path: String, line: Int? = nil, column: Int? = nil, fallbackPaths: [String] = []) {
        self.path = path
        self.line = line
        self.column = column
        self.fallbackPaths = fallbackPaths
    }

    /// The name a preview shows while the file loads.
    var displayName: String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    func fallingBack(to paths: [String]) -> TerminalFileReference {
        TerminalFileReference(path: path, line: line, column: column, fallbackPaths: paths)
    }

    /// Whether any reading climbs back out of a directory it names, with a
    /// `..` after a name (`shot.png/../../.ssh/key`, `~/..`). Folding that
    /// `..` undoes a name drawn before it, so the file read is not the one
    /// the text names — whatever joined the text: a row break, a blank, or
    /// a `..` glued to the neighbouring row's name. Leading `..` segments
    /// only climb from the pane's directory before any name, so without a
    /// later one every name drawn is in the path read, in order.
    var climbsBackOut: Bool {
        ([path] + fallbackPaths).contains { reading in
            var named = false
            for segment in reading.split(separator: "/") where segment != "." {
                if segment == ".." {
                    if named { return true }
                } else {
                    named = true
                }
            }
            return false
        }
    }
}

/// What a link in terminal output leads to.
///
/// Ghostty finds the link (an OSC 8 hyperlink's target, or text its URL and
/// path matcher recognizes); this decides what the app may do with it. Remote
/// output is untrusted: a web link must pass ``TerminalLinkPolicy``, a file is
/// only ever fetched for a read-only preview, and every other scheme (`ssh:`,
/// `mailto:`, `tel:`, custom app schemes) is not a link at all.
enum TerminalLinkTarget: Equatable, Sendable {
    case web(URL)
    case file(TerminalFileReference)

    init?(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !Self.containsControlCharacter(text) else { return nil }

        if let scheme = Self.scheme(of: text) {
            switch scheme {
            case "http", "https":
                // Taken as given: Ghostty's matcher already leaves sentence
                // punctuation out of a URL in text, and an OSC 8 target is
                // exactly what the program asked to open.
                guard let url = TerminalLinkPolicy.url(for: text) else { return nil }
                self = .web(url)
            case "file":
                // Only a file on this Host: no host, or `localhost`. A named
                // host is ambiguous (`ls --hyperlink` names the machine it ran
                // on, which remote output can claim to be anything), so it is
                // refused rather than guessed.
                guard let url = URL(string: text), url.isFileURL, !url.path.isEmpty,
                      url.path.hasPrefix("/"), Self.foreignHost(of: url) == nil,
                      !Self.containsFormatCharacter(url.path)
                else { return nil }
                self = .file(TerminalFileReference(path: url.path))
            default:
                return nil
            }
            return
        }

        let (path, line, column) = Self.splittingPosition(
            Self.trimmingSurroundingPunctuation(Self.cuttingTrailingProse(text)))
        guard Self.isPathLike(path), !Self.containsFormatCharacter(path) else { return nil }
        self = .file(TerminalFileReference(path: path, line: line, column: column))
    }

    /// Whether a web link could read as another host even drawn in full:
    /// userinfo (`https://paypal.com@evil.example` opens evil.example), or a
    /// non-ASCII character in the authority — a look-alike host, or a
    /// look-alike slash such as U+2215 that hides the `@` after it. `raw` is
    /// the target as found, before `URL` percent-encodes any of it.
    static func disguisesItsHost(_ raw: String) -> Bool {
        guard case .web(let url)? = TerminalLinkTarget(raw) else { return false }
        if url.user != nil || url.password != nil { return true }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = text.range(of: "://") else { return false }
        let authority = text[separator.upperBound...].prefix { !"/?#".contains($0) }
        return authority.contains("@") || !authority.unicodeScalars.allSatisfy(\.isASCII)
    }

    /// Whether `raw` names a file by URL. Such a target is never what the
    /// text around it reads as, so it is always confirmed before a fetch.
    static func isFileURL(_ raw: String) -> Bool {
        scheme(of: raw.trimmingCharacters(in: .whitespacesAndNewlines)) == "file"
    }

    /// The machine a `file:` URL names when it is not this Host
    /// (`ls --hyperlink` writes `file://build-box/…`): such a file is never
    /// fetched, but the tap on it is told so. Nil for any other text.
    static func otherMachine(ofFileURL raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard scheme(of: text) == "file", let url = URL(string: text) else { return nil }
        return foreignHost(of: url)
    }

    /// The host a `file:` URL names when that is not this Host — none, or
    /// `localhost` in any case or encoding, is this Host — percent-encoded,
    /// so a look-alike or reordering character in it shows as its code.
    private static func foreignHost(of url: URL) -> String? {
        guard let host = url.host(percentEncoded: false), !host.isEmpty,
              host.lowercased() != "localhost"
        else { return nil }
        return url.host(percentEncoded: true) ?? host
    }

    /// Whether `text` holds a control character — a newline, tab, NUL or
    /// escape. A link holding one is not the text it was drawn as.
    static func containsControlCharacter(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    /// Whether `text` holds a format character — a bidi override or
    /// isolate, a zero-width space or joiner. Such a character draws
    /// nothing, or reorders what is drawn, so a path holding one is not the
    /// text on screen or in a confirmation, and is no link.
    static func containsFormatCharacter(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.properties.generalCategory == .format }
    }

    /// What a confirmation shows before opening a link the user could not
    /// read on screen: the web link's scheme and host (percent-encoded, so a
    /// look-alike Unicode host is not disguised) and the full address — just
    /// the address for one with no host, a `mailto:` from a Markdown file —
    /// or the Host path a Preview reads, resolved against the pane's
    /// directory and the Host's home, `..` folded. A path whose base is not
    /// known stays as printed; a read of it fails for the same reason.
    func confirmationDetail(workingDirectory: String?, homeDirectory: String?) -> String {
        switch self {
        case .web(let url):
            guard let host = url.host(percentEncoded: true) else { return url.absoluteString }
            let scheme = url.scheme?.lowercased() ?? ""
            return "\(scheme)://\(host)\n\n\(url.absoluteString)"
        case .file(let file):
            return TerminalPathResolver.resolve(
                file.path, workingDirectory: workingDirectory, homeDirectory: homeDirectory)
                ?? file.path
        }
    }

    var isFile: Bool {
        if case .file = self { return true }
        return false
    }

    /// What Copy puts on the pasteboard from that confirmation.
    var copyableText: String {
        switch self {
        case .web(let url): url.absoluteString
        case .file(let file): file.path
        }
    }

    /// A URL scheme, lowercased, when `text` starts with one. `src/a.swift:3`
    /// and `C:` are not: a scheme is at least two characters and comes before
    /// any slash. Nor is `shot.png:12` or `shot.png:12:3`: what follows the
    /// colon is a line and column, not a URL.
    private static func scheme(of text: String) -> String? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let candidate = text[..<colon]
        guard candidate.count >= 2,
              let first = candidate.unicodeScalars.first,
              CharacterSet.letters.contains(first),
              candidate.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || "+-.".unicodeScalars.contains($0)
              }),
              !isPosition(trimmingSurroundingPunctuation(String(text[text.index(after: colon)...])))
        else { return nil }
        return candidate.lowercased()
    }

    /// Whether `text` is `line` or `line:column`.
    private static func isPosition(_ text: String) -> Bool {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        return (1...2).contains(parts.count)
            && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }
    }

    /// Ghostty's path matcher runs on across a blank while text follows, so
    /// `/tmp/a.png. Done.` matches whole. A `. ` or `, ` after a name with a
    /// known file extension (and any `:line:column`) ends the path there:
    /// the rest is the sentence.
    private static func cuttingTrailingProse(_ text: String) -> String {
        var index = text.startIndex
        while let found = text[index...].firstIndex(where: { ".,".contains($0) }) {
            let next = text.index(after: found)
            let head = String(text[..<found])
            let pathExtension = (splittingPosition(head).path as NSString).pathExtension
            if next < text.endIndex, text[next].isWhitespace, !pathExtension.isEmpty,
               let type = UTType(filenameExtension: pathExtension), !type.isDynamic
            {
                return head
            }
            index = next
        }
        return text
    }

    /// Sentence punctuation, an opening bracket or quote, and an unmatched
    /// closing one are the prose around a path, not part of it: `(./out.png).`
    /// names `./out.png`, while `build/out(1).txt` keeps its parentheses.
    static func trimmingSurroundingPunctuation(_ text: String) -> String {
        var result = Substring(text)
        while let first = result.first, "([{<'\"`".contains(first) {
            result = result.dropFirst()
        }
        let pairs: [Character: Character] = [")": "(", "]": "[", "}": "{", ">": "<"]
        while let last = result.last {
            if ".,;:!?'\"`".contains(last) {
                result = result.dropLast()
            } else if let opener = pairs[last],
                      result.filter({ $0 == last }).count > result.filter({ $0 == opener }).count
            {
                result = result.dropLast()
            } else {
                break
            }
        }
        return String(result)
    }

    /// Splits `path:line` or `path:line:column` off the end.
    static func splittingPosition(_ text: String) -> (path: String, line: Int?, column: Int?) {
        var parts = text.split(separator: ":", omittingEmptySubsequences: false)
        var numbers: [Int] = []
        while parts.count > 1, numbers.count < 2,
              let last = parts.last, !last.isEmpty,
              last.allSatisfy(\.isASCII), last.allSatisfy(\.isNumber),
              let number = Int(last)
        {
            numbers.insert(number, at: 0)
            parts.removeLast()
        }
        let path = parts.joined(separator: ":")
        guard !path.isEmpty else { return (text, nil, nil) }
        return (path, numbers.first, numbers.count > 1 ? numbers[1] : nil)
    }

    /// The shapes Ghostty's path matcher recognizes: rooted at `/`, `./`,
    /// `../`, `~/`, or `$HOME/`, or a relative path with a dot in it
    /// (`src/a.swift`, `.config/app`) — plus a bare media or Markdown file
    /// name (`shot.png`, `README.md`), which that matcher leaves alone.
    /// Selected text is held to the same shapes a tap is, so prose such as
    /// `and/or`, `I/O`, `24/7`, or a date like `2026/09/26` is not offered
    /// as a file.
    private static func isPathLike(_ path: String) -> Bool {
        if ["/", "./", "../", "~/", "$HOME/"].contains(where: { path.hasPrefix($0) }) { return true }
        if path.contains("/") { return path.contains(".") }
        return isBareFileName(path)
    }

    /// Extensions a bare name may end in and still be taken for a file: the
    /// images, PDF, audio and video Quick Look shows in a contained viewer.
    /// A bare `v1.2.3` or `Node.js` is far more often prose than a file the
    /// user means, and `ls`, an agent's `Read(shot.png)`, or "saved
    /// shot.png" name a picture without a directory.
    private static let mediaFileExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "pdf",
        "mp3", "m4a", "wav", "mp4", "mov",
    ]

    /// A bare media name, or a bare Markdown name (`README.md`,
    /// `notes.markdown`, not `.mdx`): agents name the docs they write
    /// without a directory, and the app renders those itself (#147). A
    /// glob or template (`*.png`, `[ab].png`, `frame_%04d.png`, `$f.png`)
    /// names no one file, so it is not taken for one.
    private static func isBareFileName(_ name: String) -> Bool {
        guard !name.contains(where: { $0.isWhitespace || "*?[]%$".contains($0) }) else { return false }
        let stem = (name as NSString).deletingPathExtension
        let pathExtension = (name as NSString).pathExtension
        return !stem.isEmpty
            && (mediaFileExtensions.contains(pathExtension.lowercased())
                || TerminalFilePreviewStore.isMarkdown(pathExtension: pathExtension))
    }
}

/// Turns a path as printed into an absolute Host path.
enum TerminalPathResolver {
    /// Whether resolving `path` needs the Host's home directory.
    static func needsHomeDirectory(_ path: String) -> Bool {
        path == "~" || path.hasPrefix("~/") || path == "$HOME" || path.hasPrefix("$HOME/")
    }

    /// The absolute path `path` names: `~` and `$HOME` resolve against the
    /// Host's home, anything relative against the pane's working directory,
    /// and `.` and `..` segments are folded. Nil when a needed directory is
    /// unknown or the path names another user's home or another variable.
    static func resolve(
        _ path: String,
        workingDirectory: String?,
        homeDirectory: String?
    ) -> String? {
        let joined: String
        if needsHomeDirectory(path) {
            guard let home = absolute(homeDirectory) else { return nil }
            let rest = path.hasPrefix("~") ? path.dropFirst() : path.dropFirst("$HOME".count)
            joined = home + "/" + rest
        } else if path.hasPrefix("~") || path.hasPrefix("$") {
            return nil
        } else if path.hasPrefix("/") {
            joined = path
        } else {
            guard let directory = absolute(workingDirectory) else { return nil }
            joined = directory + "/" + path
        }
        return normalized(joined)
    }

    private static func absolute(_ directory: String?) -> String? {
        guard let directory, directory.hasPrefix("/") else { return nil }
        return directory
    }

    private static func normalized(_ path: String) -> String {
        var components: [Substring] = []
        for component in path.split(separator: "/") {
            switch component {
            case ".":
                continue
            case "..":
                if !components.isEmpty { components.removeLast() }
            default:
                components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }
}
