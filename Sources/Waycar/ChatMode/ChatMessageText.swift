import SwiftUI
import UIKit

/// One chat message's text: fenced ``` blocks become scrollable monospace
/// panels; everything else renders inline Markdown, keeping line breaks.
/// With a media loader (Agent messages only), the media the prose
/// references renders in place (`ChatMediaReferences`).
struct ChatMessageText: View {
    let text: String
    var foreground: Color = Brand.Colors.text
    /// Fetches referenced media; nil keeps every reference as text (user
    /// bubbles, the greeting).
    var loadMedia: ChatMediaLoader? = nil

    var body: some View {
        let segments = Self.segments(of: text, rendersMedia: loadMedia != nil)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .prose(let prose):
                    Text(Self.attributed(prose))
                        .foregroundStyle(foreground)
                        .fixedSize(horizontal: false, vertical: true)
                case .code(let code):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(code)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(Brand.Colors.termText)
                            .fixedSize(horizontal: true, vertical: true)
                            .padding(10)
                    }
                    .background(
                        Brand.Colors.ink,
                        in: RoundedRectangle(cornerRadius: Brand.Radius.keycap, style: .continuous))
                case .media(let media, let silentFailures):
                    if let loadMedia {
                        // Read from prose, not attached: one that fails to
                        // load is likely no file, so where its path stays in
                        // the text, the path alone shows it.
                        ChatMediaView(media: media, load: loadMedia, silentFailures: silentFailures)
                    }
                }
            }
        }
        .textSelection(.enabled)
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = text
            }
        }
    }

    enum Segment: Equatable, Sendable {
        case prose(String)
        case code(String)
        /// Media the prose references, in order (`rendersMedia` only).
        /// `silentFailures` holds the ids whose path stays in the prose
        /// (a sentence's or a code span's), so a failed fetch shows no
        /// tile; a standalone line or Markdown image leaves the prose and
        /// keeps its failed tile to retry.
        case media([ChatMedia], silentFailures: Set<ChatMedia.ID>)
    }

    /// Splits on lines that open or close a ``` fence. The info string after
    /// an opening fence is dropped; an unclosed fence runs to the end.
    /// `rendersMedia` further splits prose around the media it references.
    nonisolated static func segments(of text: String, rendersMedia: Bool = false) -> [Segment] {
        var result: [Segment] = []
        var mediaIDs: Set<ChatMedia.ID> = []
        var buffer: [Substring] = []
        var inCode = false

        func flush() {
            let joined = buffer.joined(separator: "\n")
            buffer.removeAll()
            if inCode {
                result.append(.code(joined))
            } else {
                let trimmed = joined.trimmingCharacters(in: .newlines)
                guard !trimmed.isEmpty else { return }
                if rendersMedia {
                    result.append(contentsOf: ChatMediaReferences.segments(ofProse: trimmed, counted: &mediaIDs))
                } else {
                    result.append(.prose(trimmed))
                }
            }
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                flush()
                inCode.toggle()
            } else {
                buffer.append(line)
            }
        }
        flush()
        return result
    }

    nonisolated static func attributed(_ prose: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: escapingLoneTildes(prose), options: options))
            ?? AttributedString(prose)
    }

    /// Apple's Markdown parser strikes through a single `~…~` pair, but
    /// Agents write `~` for "about" and in `~/paths`. Every `~` outside a
    /// `~~` run, code spans and URLs (bare or `<…>` autolinks, whose
    /// destination would keep the backslash) is escaped, so only `~~…~~`
    /// strikes.
    nonisolated static func escapingLoneTildes(_ prose: String) -> String {
        guard prose.contains("~") else { return prose }
        let characters = Array(prose)
        let spans = codeSpans(in: characters)
        var result = ""
        result.reserveCapacity(prose.utf8.count + 8)
        var spanIndex = 0
        var index = 0
        var escaped = false
        while index < characters.count {
            if spanIndex < spans.count, spans[spanIndex].lowerBound == index {
                result.append(contentsOf: characters[spans[spanIndex]])
                index = spans[spanIndex].upperBound
                spanIndex += 1
                continue
            }
            let character = characters[index]
            if escaped {
                result.append(character)
                escaped = false
                index += 1
            } else if character == "\\" {
                result.append(character)
                escaped = true
                index += 1
            } else if let end = autolinkEnd(in: characters, from: index) ?? bareURLEnd(in: characters, from: index),
                spanIndex >= spans.count || spans[spanIndex].lowerBound >= end
            {
                result.append(contentsOf: characters[index..<end])
                index = end
            } else if character == "~" {
                let run = runLength(of: "~", in: characters, from: index)
                if run == 1 {
                    result.append("\\~")
                } else {
                    result.append(contentsOf: characters[index..<(index + run)])
                }
                index += run
            } else {
                result.append(character)
                index += 1
            }
        }
        return result
    }

    /// The end of a CommonMark URI autolink `<scheme:…>` starting at
    /// `start`, past its `>`.
    private nonisolated static func autolinkEnd(in characters: [Character], from start: Int) -> Int? {
        guard characters[start] == "<", start + 1 < characters.count,
            characters[start + 1].isASCII, characters[start + 1].isLetter
        else { return nil }
        var index = start + 2
        while index < characters.count, characters[index].isASCII,
            characters[index].isLetter || characters[index].isNumber || "+.-".contains(characters[index])
        {
            index += 1
        }
        let schemeLength = index - start - 1
        guard (2...32).contains(schemeLength), index < characters.count, characters[index] == ":" else {
            return nil
        }
        while index < characters.count {
            let character = characters[index]
            if character == ">" { return index + 1 }
            if character == "<" || character.isWhitespace { return nil }
            index += 1
        }
        return nil
    }

    /// The end of a bare `http://` or `https://` URL starting at `start`,
    /// as GitHub's autolink extension reads it: after whitespace, `*`, `_`,
    /// `~` or `(`, up to whitespace or `<`, less trailing punctuation other
    /// than `~` and unbalanced `)`.
    private nonisolated static func bareURLEnd(in characters: [Character], from start: Int) -> Int? {
        guard characters[start] == "h" || characters[start] == "H" else { return nil }
        if start > 0 {
            let previous = characters[start - 1]
            guard previous.isWhitespace || "*_~(".contains(previous) else { return nil }
        }
        let prefix = String(characters[start..<min(start + 8, characters.count)]).lowercased()
        let schemeLength: Int
        if prefix.hasPrefix("https://") {
            schemeLength = 8
        } else if prefix.hasPrefix("http://") {
            schemeLength = 7
        } else {
            return nil
        }
        var end = start + schemeLength
        while end < characters.count, !characters[end].isWhitespace, characters[end] != "<" { end += 1 }
        let opening = characters[start..<end].count(where: { $0 == "(" })
        var closing = characters[start..<end].count(where: { $0 == ")" })
        while end > start + schemeLength {
            let last = characters[end - 1]
            // A trailing `~` stays: the parser drops it from the link, and
            // escaped it would leave a backslash in the destination.
            if "?!.,:*_'\"".contains(last) {
                end -= 1
            } else if last == ")", closing > opening {
                closing -= 1
                end -= 1
            } else {
                break
            }
        }
        return end > start + schemeLength ? end : nil
    }

    /// Inline code spans, as index ranges including their backticks: a run
    /// of n backticks up to the next run of exactly n. A backslash-escaped
    /// backtick opens none; an unmatched run is literal.
    nonisolated static func codeSpans(in characters: [Character]) -> [Range<Int>] {
        var spans: [Range<Int>] = []
        var index = 0
        var escaped = false
        while index < characters.count {
            let character = characters[index]
            if escaped {
                escaped = false
                index += 1
                continue
            }
            if character == "\\" {
                escaped = true
                index += 1
                continue
            }
            guard character == "`" else {
                index += 1
                continue
            }
            let opening = runLength(of: "`", in: characters, from: index)
            var probe = index + opening
            var closingEnd: Int?
            while probe < characters.count {
                guard characters[probe] == "`" else {
                    probe += 1
                    continue
                }
                let run = runLength(of: "`", in: characters, from: probe)
                if run == opening {
                    closingEnd = probe + run
                    break
                }
                probe += run
            }
            if let closingEnd {
                spans.append(index..<closingEnd)
                index = closingEnd
            } else {
                index += opening
            }
        }
        return spans
    }

    /// `characters` with every code span blanked to spaces, index for index.
    nonisolated static func maskingCodeSpans(_ characters: [Character]) -> [Character] {
        maskingCodeSpans(characters, spans: codeSpans(in: characters))
    }

    /// `characters` with `spans` (its `codeSpans(in:)`) blanked to spaces.
    nonisolated static func maskingCodeSpans(_ characters: [Character], spans: [Range<Int>]) -> [Character] {
        var masked = characters
        for span in spans {
            for index in span { masked[index] = " " }
        }
        return masked
    }

    private nonisolated static func runLength(
        of character: Character, in characters: [Character], from start: Int
    ) -> Int {
        var end = start
        while end < characters.count, characters[end] == character { end += 1 }
        return end - start
    }
}

/// The media an Agent's prose references:
/// - Markdown images `![alt](src)` leave the prose and render in place;
/// - a line that is only a media path or https URL (optionally a bullet)
///   renders as media;
/// - a path or https URL inside a sentence stays text, and its media
///   follows the paragraph; so does a code span that is only a rooted
///   image path (`codeSpanMedia(in:)`).
/// Sources are absolute, `~/` or relative Host paths, or https URLs to a
/// public host (`ChatMedia.isFetchableWebURL`), with a media extension
/// (`ChatMedia.kind(forPathExtension:)`). A bare file name counts only on
/// its own line or as an image source: in a sentence it is a mention. Any
/// other code span never counts, nor does a fenced block. A message shows
/// at most `maximumPerMessage` items; references past that stay text.
enum ChatMediaReferences {
    static let maximumPerMessage = 12

    /// - Parameter counted: the ids of the message's media so far, shared
    ///   across its prose segments; the cap applies to their total.
    static func segments(ofProse prose: String, counted: inout Set<ChatMedia.ID>) -> [ChatMessageText.Segment] {
        var builder = Builder(counted: counted)
        for line in prose.split(separator: "\n", omittingEmptySubsequences: false) {
            builder.consume(String(line))
        }
        builder.flushProse()
        counted = builder.counted
        return builder.result
    }

    /// The media for one reference source, or nil when it is not one.
    /// - Parameter standalone: alone on its line or an image source, so a
    ///   bare file name counts, and spaces do in an absolute or `~/` path.
    static func media(fromSource source: String, alt: String?, standalone: Bool) -> ChatMedia? {
        guard !source.isEmpty, !source.contains("`"),
            !source.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else { return nil }
        if source.lowercased().hasPrefix("https://") {
            guard !source.contains(where: \.isWhitespace),
                let url = URL(string: source), ChatMedia.isFetchableWebURL(url),
                let kind = ChatMedia.kind(forPathExtension: url.pathExtension.lowercased())
            else { return nil }
            return ChatMedia(id: "ref:\(source)", kind: kind, mime: nil, source: .web(url), alt: alt)
        }
        // Any other scheme (http, file, data, …) is not a Host path.
        if let colon = source.firstIndex(of: ":"), !source[..<colon].contains("/") { return nil }
        if source.hasPrefix("~"), !source.hasPrefix("~/") { return nil }
        guard !source.hasSuffix("/") else { return nil }
        let isRooted = source.hasPrefix("/") || source.hasPrefix("~/")
        if source.contains(where: \.isWhitespace), !(standalone && isRooted) { return nil }
        if !standalone, !isRooted, !source.contains("/") { return nil }
        let name = (source as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension
        guard name.count > ext.count + 1,
            let kind = ChatMedia.kind(forPathExtension: ext.lowercased())
        else { return nil }
        return ChatMedia(id: "ref:\(source)", kind: kind, mime: nil, source: .hostFile(path: source), alt: alt)
    }

    /// The media of a line that is only media references, else nil.
    static func standaloneMedia(in line: String) -> [ChatMedia]? {
        var candidate = line.trimmingCharacters(in: .whitespaces)
        for marker in ["- ", "* ", "+ "] where candidate.hasPrefix(marker) {
            candidate = String(candidate.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        guard !candidate.isEmpty else { return nil }
        if candidate.hasPrefix("![") {
            let characters = Array(candidate)
            let masked = ChatMessageText.maskingCodeSpans(characters)
            var items: [ChatMedia] = []
            var index = 0
            while index < characters.count {
                if characters[index].isWhitespace {
                    index += 1
                    continue
                }
                guard let image = markdownImage(in: characters, masked: masked, from: index),
                    image.range.lowerBound == index, let media = image.media
                else { return nil }
                items.append(media)
                index = image.range.upperBound
            }
            return items.isEmpty ? nil : items
        }
        if candidate.hasPrefix("<"), candidate.hasSuffix(">") {
            candidate = String(candidate.dropFirst().dropLast())
        }
        return media(fromSource: candidate, alt: nil, standalone: true).map { [$0] }
    }

    /// The next Markdown image at or after `start`, found in `masked` (code
    /// spans blanked) and read from `characters`. `media` is nil when its
    /// source is no media reference; the syntax then stays text.
    static func markdownImage(
        in characters: [Character], masked: [Character], from start: Int
    ) -> (range: Range<Int>, media: ChatMedia?)? {
        var index = start
        while index + 1 < masked.count {
            guard masked[index] == "!", masked[index + 1] == "[",
                index == 0 || masked[index - 1] != "\\"
            else {
                index += 1
                continue
            }
            guard let close = masked[(index + 2)...].firstIndex(of: "]"),
                close + 1 < masked.count, masked[close + 1] == "("
            else {
                index += 2
                continue
            }
            let open = close + 2
            let source: String
            let end: Int
            if open < masked.count, masked[open] == "<" {
                guard let angle = masked[(open + 1)...].firstIndex(of: ">"),
                    let paren = masked[(angle + 1)...].firstIndex(of: ")")
                else {
                    index += 2
                    continue
                }
                source = String(characters[(open + 1)..<angle])
                end = paren + 1
            } else {
                guard let paren = masked[open...].firstIndex(of: ")") else {
                    index += 2
                    continue
                }
                // A title may follow the source: `![alt](src "title")`.
                source = String(
                    String(characters[open..<paren]).trimmingCharacters(in: .whitespaces)
                        .prefix { !$0.isWhitespace })
                end = paren + 1
            }
            let alt = String(characters[(index + 2)..<close]).trimmingCharacters(in: .whitespaces)
            return (index..<end, media(fromSource: source, alt: alt.isEmpty ? nil : alt, standalone: true))
        }
        return nil
    }

    /// Paths and URLs inside a sentence, from text with code spans blanked.
    /// Table pipes (`|`, box-drawing `│`) part tokens like whitespace, so a
    /// compact cell `|/tmp/shot.png|` yields its path.
    static func sentenceMedia(in masked: ArraySlice<Character>) -> [ChatMedia] {
        let leading: Set<Character> = ["(", "[", "<", "{", "\"", "'", "*", "_"]
        let trailing: Set<Character> = [")", "]", ">", "}", "\"", "'", "*", "_", ".", ",", ";", ":", "!", "?"]
        let separators: Set<Character> = ["|", "│"]
        return String(masked).split { $0.isWhitespace || separators.contains($0) }.compactMap { token in
            var candidate = token
            // A Markdown link's target: `[label](docs/chart.png)`.
            if let link = candidate.range(of: "](", options: .backwards) {
                candidate = candidate[link.upperBound...]
            }
            candidate = candidate.drop { leading.contains($0) }
            while let last = candidate.last, trailing.contains(last) { candidate = candidate.dropLast() }
            return media(fromSource: String(candidate), alt: nil, standalone: false)
        }
    }

    /// The image of a code span, backticks included, whose whole content is
    /// one rooted image path: "Saved to `/tmp/out.png`." The span stays
    /// code, and its image follows the paragraph like a sentence's path.
    /// Anything else in a code span is code: a command (`open /tmp/a.png`),
    /// a relative path, a glob or template (`/tmp/*.png`, `~/${name}.png`),
    /// a video.
    static func codeSpanMedia(in span: ArraySlice<Character>) -> ChatMedia? {
        let fence = span.prefix { $0 == "`" }.count
        guard span.count > 2 * fence else { return nil }
        let content = String(span.dropFirst(fence).dropLast(fence)).trimmingCharacters(in: .whitespaces)
        let templateCharacters: Set<Character> = ["*", "?", "{", "}", "$"]
        guard content.hasPrefix("/") || content.hasPrefix("~/"),
            !content.contains(where: { $0.isWhitespace || templateCharacters.contains($0) }),
            let item = media(fromSource: content, alt: nil, standalone: false), item.kind == .image
        else { return nil }
        return item
    }

    private struct Builder {
        private(set) var result: [ChatMessageText.Segment] = []
        /// Every media id the message shows, this builder's and earlier ones'.
        private(set) var counted: Set<ChatMedia.ID>
        /// The open prose segment's lines.
        private var lines: [String] = []
        /// Media referenced inside the open paragraph's sentences.
        private var pending: [ChatMedia] = []

        init(counted: Set<ChatMedia.ID>) {
            self.counted = counted
        }

        mutating func consume(_ line: String) {
            if let media = ChatMediaReferences.standaloneMedia(in: line), admits(media) {
                flushProse()
                appendMedia(media)
                return
            }
            if line.allSatisfy(\.isWhitespace) {
                // A paragraph ends: its sentences' media follows it.
                if pending.isEmpty { lines.append(line) } else { flushProse() }
                return
            }
            let characters = Array(line)
            let spans = ChatMessageText.codeSpans(in: characters)
            let masked = ChatMessageText.maskingCodeSpans(characters, spans: spans)
            var start = 0
            var index = 0
            while let image = ChatMediaReferences.markdownImage(in: characters, masked: masked, from: index) {
                index = image.range.upperBound
                guard let media = image.media, admits([media]) else { continue }
                noteInlineMedia(
                    in: start..<image.range.lowerBound, characters: characters, masked: masked, spans: spans)
                var before = characters[start..<image.range.lowerBound]
                while before.last?.isWhitespace == true { before = before.dropLast() }
                if !before.isEmpty { lines.append(String(before)) }
                flushProse()
                appendMedia([media])
                start = image.range.upperBound
                while start < characters.count, characters[start].isWhitespace { start += 1 }
                index = start
            }
            noteInlineMedia(in: start..<characters.count, characters: characters, masked: masked, spans: spans)
            if start == 0 {
                lines.append(line)
            } else if start < characters.count {
                lines.append(String(characters[start...]))
            }
        }

        /// Ends the open prose segment, then shows its sentences' media.
        mutating func flushProse() {
            let joined = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
            lines.removeAll()
            if !joined.allSatisfy(\.isWhitespace) {
                result.append(.prose(joined))
            }
            let media = pending
            pending.removeAll()
            appendMedia(media, silentFailures: true)
        }

        /// Adds media after the last segment, joining a media segment
        /// already there so consecutive references form one group.
        /// `silentFailures` marks media whose path stays in the prose.
        private mutating func appendMedia(_ media: [ChatMedia], silentFailures: Bool = false) {
            guard !media.isEmpty else { return }
            let silent = silentFailures ? Set(media.map(\.id)) : []
            if case .media(let group, let groupSilent)? = result.last {
                result[result.count - 1] = .media(
                    Self.adding(media, to: group), silentFailures: groupSilent.union(silent))
            } else {
                result.append(.media(Self.adding(media, to: []), silentFailures: silent))
            }
        }

        private mutating func notePending(_ media: [ChatMedia]) {
            var admitted: [ChatMedia] = []
            for item in media where admits([item]) { admitted.append(item) }
            pending = Self.adding(admitted, to: pending)
        }

        /// Notes the media of `range`'s sentences and of its code spans
        /// that are one rooted image path, in reading order. A Markdown
        /// image never starts or ends inside a code span, so each span lies
        /// wholly inside or outside `range`.
        private mutating func noteInlineMedia(
            in range: Range<Int>, characters: [Character], masked: [Character], spans: [Range<Int>]
        ) {
            var cursor = range.lowerBound
            for span in spans where span.lowerBound >= range.lowerBound && span.upperBound <= range.upperBound {
                notePending(ChatMediaReferences.sentenceMedia(in: masked[cursor..<span.lowerBound]))
                if let media = ChatMediaReferences.codeSpanMedia(in: characters[span]) {
                    notePending([media])
                }
                cursor = span.upperBound
            }
            notePending(ChatMediaReferences.sentenceMedia(in: masked[cursor..<range.upperBound]))
        }

        /// Counts `media` toward the message's cap when all of it fits;
        /// an item already counted always fits.
        private mutating func admits(_ media: [ChatMedia]) -> Bool {
            let fresh = Set(media.map(\.id)).subtracting(counted)
            guard counted.count + fresh.count <= ChatMediaReferences.maximumPerMessage else { return false }
            counted.formUnion(fresh)
            return true
        }

        private static func adding(_ media: [ChatMedia], to group: [ChatMedia]) -> [ChatMedia] {
            var group = group
            for item in media where !group.contains(where: { $0.id == item.id }) {
                group.append(item)
            }
            return group
        }
    }
}
