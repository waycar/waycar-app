import Foundation

/// One command's answer in tmux control mode: the lines between
/// `%begin <time> <number> <flags>` and the matching `%end` or `%error`.
///
/// Replies arrive in the order the commands were sent, so callers match
/// them first in, first out and never by `commandNumber`, which is a
/// server-global counter (design §1, T2). `flags` 0 marks the reply to the
/// attach command itself, which callers skip; client commands carry 1.
struct TmuxReply: Sendable, Equatable {
    let commandNumber: Int
    let flags: Int
    let lines: [String]
    let isError: Bool
}

/// One `%subscription-changed` push from a `refresh-client -B` format
/// subscription.
struct TmuxSubscriptionChange: Sendable, Equatable {
    /// The subscription's name, as given to `refresh-client -B`.
    let name: String
    /// The session the change was evaluated in (`$1`).
    let sessionID: String
    /// Window and pane scope; nil when tmux prints `-` (a session-scoped
    /// subscription).
    let windowID: String?
    let windowIndex: Int?
    let paneID: String?
    /// Everything after the first ` : `, unescaped: raw tabs, newlines and
    /// control bytes come through as is, on every tmux version.
    let value: String
}

/// A control-mode notification: a `%`-line outside any reply block.
/// Ids keep tmux's raw spelling (`$1`, `@2`, `%3`), without the app's
/// `tmux:` prefix.
enum TmuxNotification: Sendable, Equatable {
    case sessionsChanged
    case sessionChanged(sessionID: String, name: String)
    case sessionRenamed(sessionID: String, name: String)
    case sessionWindowChanged(sessionID: String, windowID: String)
    case windowAdd(windowID: String)
    case windowClose(windowID: String)
    case windowRenamed(windowID: String, name: String)
    case unlinkedWindowAdd(windowID: String)
    case unlinkedWindowClose(windowID: String)
    case unlinkedWindowRenamed(windowID: String, name: String)
    case windowPaneChanged(windowID: String, paneID: String)
    /// `layout` is the window's layout string; the visible layout and
    /// window flags tmux appends are dropped.
    case layoutChange(windowID: String, layout: String)
    case subscriptionChanged(TmuxSubscriptionChange)
    /// The control client is leaving; `reason` is tmux's text when it gave
    /// one.
    case exit(reason: String?)
    case pause(paneID: String)
    case `continue`(paneID: String)
    /// Pane output with tmux's `\ooo` escapes decoded back into bytes.
    case output(paneID: String, data: Data)
    /// Output for a client with `pause-after`; `age` is how long tmux held
    /// it, in milliseconds.
    case extendedOutput(paneID: String, age: Int, data: Data)
    case pasteBufferChanged(name: String)
    case pasteBufferDeleted(name: String)
    case clientDetached(client: String)
    case clientSessionChanged(client: String, sessionID: String, name: String)
    /// One line of a configuration-file error, as tmux reported it.
    case configError(String)
    /// Any line this parser does not know, whole: future notifications and
    /// the unframed error lines some commands print (T15).
    case unknown(String)
}

/// What one chunk of control-mode stdout decodes to, in arrival order.
enum TmuxControlMessage: Sendable, Equatable {
    case reply(TmuxReply)
    case notification(TmuxNotification)
}

/// Turns a `tmux -C` client's stdout into replies and notifications.
///
/// Pure and value-typed: the control channel owns one and feeds it every
/// chunk it reads. Chunks may split lines anywhere, and a line may run to
/// megabytes (a `capture-pane` of a long history); bytes are kept until
/// their line's LF arrives, and each byte is scanned for LF once. Text is
/// decoded as UTF-8, lossily; a trailing CR is ignored.
///
/// Block content is taken verbatim, `%`-lines included, until the guard
/// line that repeats the `%begin` line's time, number and flags. The one
/// exception is `%config-error`, which tmux writes inside the attach
/// command's own block (flags 0, recorded on 3.7c).
struct TmuxControlParser: Sendable {
    private var buffer: [UInt8] = []
    /// Bytes at the front of `buffer` already searched for LF.
    private var scanned = 0
    private var block: OpenBlock?

    private struct OpenBlock: Sendable {
        /// `<time> <number> <flags>` as the `%begin` line spelled it.
        let guardFields: String
        let commandNumber: Int
        let flags: Int
        var lines: [String] = []
    }

    init() {}

    /// Appends `data` and returns every message it completed.
    mutating func feed(_ data: Data) -> [TmuxControlMessage] {
        guard !data.isEmpty else { return [] }
        buffer.append(contentsOf: data)
        var messages: [TmuxControlMessage] = []
        var lineStart = 0
        var searchFrom = scanned
        while let newline = buffer[searchFrom...].firstIndex(of: Self.lineFeed) {
            var lineEnd = newline
            if lineEnd > lineStart, buffer[lineEnd - 1] == Self.carriageReturn {
                lineEnd -= 1
            }
            if let message = handle(line: buffer[lineStart..<lineEnd]) {
                messages.append(message)
            }
            lineStart = newline + 1
            searchFrom = lineStart
        }
        if lineStart > 0 {
            buffer.removeSubrange(0..<lineStart)
        }
        scanned = buffer.count
        return messages
    }

    private mutating func handle(line: ArraySlice<UInt8>) -> TmuxControlMessage? {
        if var open = block {
            let text = Self.decode(line)
            if text == "%end " + open.guardFields || text == "%error " + open.guardFields {
                block = nil
                return .reply(TmuxReply(
                    commandNumber: open.commandNumber,
                    flags: open.flags,
                    lines: open.lines,
                    isError: text.hasPrefix("%error ")))
            }
            if open.flags == 0, text.hasPrefix("%config-error ") {
                return .notification(Self.notification(line))
            }
            open.lines.append(text)
            block = open
            return nil
        }
        guard !line.isEmpty else { return nil }
        if line.starts(with: Self.beginPrefix) {
            let fields = Self.decode(line.dropFirst(Self.beginPrefix.count))
            let parts = fields.split(separator: " ", omittingEmptySubsequences: false)
            if parts.count == 3, Int(parts[0]) != nil,
                let number = Int(parts[1]), let flags = Int(parts[2])
            {
                block = OpenBlock(guardFields: fields, commandNumber: number, flags: flags)
                return nil
            }
        }
        return .notification(Self.notification(line))
    }

    // MARK: Notifications

    private static func notification(_ line: ArraySlice<UInt8>) -> TmuxNotification {
        let nameEnd = line.firstIndex(of: space) ?? line.endIndex
        let name = decode(line[line.startIndex..<nameEnd])
        let body = nameEnd < line.endIndex ? line[(nameEnd + 1)...] : line[line.endIndex...]

        switch name {
        case "%output":
            let (pane, rest) = splitWord(body)
            guard isID(pane, sigil: "%") else { break }
            return .output(paneID: pane, data: decodeOctalEscapes(rest))
        case "%extended-output":
            if let parsed = extendedOutput(body) { return parsed }
        default:
            if let parsed = textNotification(name: name, body: decode(body)) { return parsed }
        }
        return .unknown(decode(line))
    }

    private static func textNotification(name: String, body: String) -> TmuxNotification? {
        let words = body.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let first = words.first ?? ""
        // Everything after the first word, spaces kept: names may hold them.
        let afterFirst = words.count > 1 ? words.dropFirst().joined(separator: " ") : ""

        switch name {
        case "%sessions-changed":
            return .sessionsChanged
        case "%session-changed" where isID(first, sigil: "$") && words.count > 1:
            return .sessionChanged(sessionID: first, name: afterFirst)
        case "%session-renamed" where isID(first, sigil: "$") && words.count > 1:
            return .sessionRenamed(sessionID: first, name: afterFirst)
        case "%session-window-changed"
        where words.count == 2 && isID(first, sigil: "$") && isID(words[1], sigil: "@"):
            return .sessionWindowChanged(sessionID: first, windowID: words[1])
        case "%window-add" where words.count == 1 && isID(first, sigil: "@"):
            return .windowAdd(windowID: first)
        case "%window-close" where words.count == 1 && isID(first, sigil: "@"):
            return .windowClose(windowID: first)
        case "%window-renamed" where isID(first, sigil: "@") && words.count > 1:
            return .windowRenamed(windowID: first, name: afterFirst)
        case "%unlinked-window-add" where words.count == 1 && isID(first, sigil: "@"):
            return .unlinkedWindowAdd(windowID: first)
        case "%unlinked-window-close" where words.count == 1 && isID(first, sigil: "@"):
            return .unlinkedWindowClose(windowID: first)
        case "%unlinked-window-renamed" where isID(first, sigil: "@") && words.count > 1:
            return .unlinkedWindowRenamed(windowID: first, name: afterFirst)
        case "%window-pane-changed"
        where words.count == 2 && isID(first, sigil: "@") && isID(words[1], sigil: "%"):
            return .windowPaneChanged(windowID: first, paneID: words[1])
        case "%layout-change" where isID(first, sigil: "@") && words.count > 1:
            return .layoutChange(windowID: first, layout: words[1])
        case "%subscription-changed":
            return subscriptionChange(body).map(TmuxNotification.subscriptionChanged)
        case "%exit":
            return .exit(reason: body.isEmpty ? nil : body)
        case "%pause" where words.count == 1 && isID(first, sigil: "%"):
            return .pause(paneID: first)
        case "%continue" where words.count == 1 && isID(first, sigil: "%"):
            return .continue(paneID: first)
        case "%paste-buffer-changed" where !body.isEmpty:
            return .pasteBufferChanged(name: body)
        case "%paste-buffer-deleted" where !body.isEmpty:
            return .pasteBufferDeleted(name: body)
        case "%client-detached" where !body.isEmpty:
            return .clientDetached(client: body)
        case "%client-session-changed" where words.count > 2 && isID(words[1], sigil: "$"):
            return .clientSessionChanged(
                client: first, sessionID: words[1],
                name: words.dropFirst(2).joined(separator: " "))
        case "%config-error":
            return .configError(body)
        default:
            return nil
        }
    }

    /// `name $s @w index %p : value`, with `-` for an absent window or
    /// pane. The value starts after the first ` : `; tmux writes ` : ` even
    /// when the value is empty, but a stripped trailing space is tolerated.
    private static func subscriptionChange(_ body: String) -> TmuxSubscriptionChange? {
        let head: Substring
        let value: Substring
        if let separator = body.range(of: " : ") {
            head = body[..<separator.lowerBound]
            value = body[separator.upperBound...]
        } else if body.hasSuffix(" :") {
            head = body.dropLast(2)
            value = ""
        } else {
            return nil
        }
        let fields = head.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 5, !fields[0].isEmpty, isID(fields[1], sigil: "$") else { return nil }
        let window = fields[2] == "-" ? nil : fields[2]
        let index = fields[3] == "-" ? nil : Int(fields[3])
        let pane = fields[4] == "-" ? nil : fields[4]
        guard window.map({ isID($0, sigil: "@") }) ?? true,
            fields[3] == "-" || index != nil,
            pane.map({ isID($0, sigil: "%") }) ?? true
        else { return nil }
        return TmuxSubscriptionChange(
            name: fields[0], sessionID: fields[1], windowID: window,
            windowIndex: index, paneID: pane, value: String(value))
    }

    /// `%extended-output %p <age> [reserved…] : <data>`.
    private static func extendedOutput(_ body: ArraySlice<UInt8>) -> TmuxNotification? {
        let (pane, rest) = splitWord(body)
        guard isID(pane, sigil: "%") else { return nil }
        let (ageWord, afterAge) = splitWord(rest)
        guard let age = Int(ageWord) else { return nil }
        // Reserved fields may follow the age; the data starts after the
        // first lone `:` word.
        var remaining = afterAge
        while !remaining.isEmpty {
            let (word, next) = splitWord(remaining)
            if word == ":" {
                return .extendedOutput(paneID: pane, age: age, data: decodeOctalEscapes(next))
            }
            remaining = next
        }
        return nil
    }

    // MARK: Bytes

    private static let lineFeed: UInt8 = 0x0A
    private static let carriageReturn: UInt8 = 0x0D
    private static let space: UInt8 = 0x20
    private static let backslash: UInt8 = 0x5C
    private static let beginPrefix = Array("%begin ".utf8)

    private static func decode(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    /// The first space-delimited word as text, and the bytes after its
    /// space (empty when the word ends the line).
    private static func splitWord(
        _ bytes: ArraySlice<UInt8>
    ) -> (word: String, rest: ArraySlice<UInt8>) {
        guard let end = bytes.firstIndex(of: space) else {
            return (decode(bytes), bytes[bytes.endIndex...])
        }
        return (decode(bytes[bytes.startIndex..<end]), bytes[(end + 1)...])
    }

    /// `$12`, `@3`, `%0`: the sigil followed by decimal digits only.
    private static func isID(_ word: String, sigil: Character) -> Bool {
        guard word.first == sigil else { return false }
        let digits = word.dropFirst()
        return !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Undoes tmux's output escaping: every byte below 0x20 and the
    /// backslash itself become `\ooo` (three octal digits); everything else,
    /// UTF-8 included, is sent raw. A backslash not followed by three octal
    /// digits is kept as it is.
    static func decodeOctalEscapes(_ bytes: ArraySlice<UInt8>) -> Data {
        var decoded = Data()
        decoded.reserveCapacity(bytes.count)
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let byte = bytes[index]
            if byte == backslash, bytes.endIndex - index >= 4,
                let value = octalValue(bytes[(index + 1)...(index + 3)])
            {
                decoded.append(value)
                index += 4
            } else {
                decoded.append(byte)
                index += 1
            }
        }
        return decoded
    }

    private static func octalValue(_ digits: ArraySlice<UInt8>) -> UInt8? {
        var value = 0
        for digit in digits {
            guard (0x30...0x37).contains(digit) else { return nil }
            value = value * 8 + Int(digit - 0x30)
        }
        return value <= 0xFF ? UInt8(value) : nil
    }
}
