import Foundation

/// Incremental, bounded change-feed decoder. Only a complete B…E frame replaces inventory.
/// LF-containing session names cannot be represented by ls's physical lines: continuation lines
/// without [Created] are dropped; the final fragment cannot resolve panes, so has no Workspace.
/// Such sessions are intentionally invisible rather than inventing a second discovery protocol.
struct ZellijFrameParser: Sendable {
    struct Batch: Sendable {
        var frames: [ZellijFrame] = []
        var heartbeat = false
    }

    static let maximumBytes = 8 * 1024 * 1024
    private var line: [UInt8] = []
    private var lines: [String]? = nil
    private var frameBytes = 0
    private var droppingLine = false

    mutating func feed(_ bytes: Data) -> Batch {
        var result = Batch()
        for byte in bytes {
            if byte == 10 {
                if !droppingLine {
                    if line.last == 13 { line.removeLast() }
                    consume(String(decoding: line, as: UTF8.self), into: &result)
                }
                line.removeAll(keepingCapacity: true)
                droppingLine = false
            } else if !droppingLine {
                guard line.count < Self.maximumBytes else {
                    line.removeAll(keepingCapacity: true)
                    lines = nil
                    frameBytes = 0
                    droppingLine = true
                    continue
                }
                line.append(byte)
            }
        }
        return result
    }

    private mutating func consume(_ line: String, into result: inout Batch) {
        if line == "\u{1E}B" {
            lines = []
            frameBytes = 0
        } else if line == "\u{1E}E" {
            if let lines { result.frames.append(ZellijFrame.decode(lines)) }
            lines = nil
            frameBytes = 0
        } else if lines != nil {
            frameBytes += line.utf8.count + 1
            if frameBytes > Self.maximumBytes {
                lines = nil
                frameBytes = 0
            } else {
                lines?.append(line)
            }
        } else if line.isEmpty {
            result.heartbeat = true
        }
    }
}

struct ZellijSessionRecord: Sendable, Equatable {
    let name: String
    let closed: Bool

    /// One-shot ls -n retains ages; normalize only the final creation suffix as the watch does.
    static func listing(_ text: String) -> [Self] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let marker = line.range(of: " [Created ", options: .backwards),
                let end = line[marker.upperBound...].firstIndex(of: "]") else { return nil }
            return parse(String(line[..<marker.lowerBound]) + " [Created]" + line[line.index(after: end)...])
        }
    }

    /// Read metadata from the end, never strip marker-like text out of a session's name.
    /// The watcher replaces only the last age with [Created], preserving Zellij's status suffix.
    static func parse(_ line: String) -> Self? {
        var body = line
        while body.last == " " { body.removeLast() }
        let closedSuffix = " (EXITED - attach to resurrect)"
        let currentSuffix = " (current)"
        let closed = body.hasSuffix(closedSuffix)
        if closed {
            body = String(body.dropLast(closedSuffix.count))
        } else if body.hasSuffix(currentSuffix) {
            body = String(body.dropLast(currentSuffix.count))
        }
        let marker = " [Created]"
        guard body.hasSuffix(marker) else { return nil }
        let name = String(body.dropLast(marker.count))
        guard ZellijPaneID.isSessionName(name) else { return nil }
        return Self(name: name, closed: closed)
    }
}

struct ZellijFrame: Sendable, Equatable {
    var sessions: [ZellijSessionRecord] = []
    var panes: [String: [ZellijPaneRecord]] = [:]
    var documents: [String: ZellijPaneState] = [:]

    var closedSessions: [ZellijSessionRecord] { sessions.filter(\.closed) }

    fileprivate static func decode(_ lines: [String]) -> Self {
        enum Section { case sessions, panes, hooks }
        var section = Section.sessions
        var session: String?
        var result = Self()
        let decoder = JSONDecoder()
        var json = ""
        func storePanes() {
            if let session {
                result.panes[session] =
                    (try? decoder.decode(
                        [ZellijPaneRecord].self, from: Data(json.utf8))) ?? []
            }
            json = ""
        }
        for line in lines {
            if line == "\u{1E}P" {
                section = .panes
                continue
            }
            if line == "\u{1E}H" {
                storePanes()
                session = nil
                section = .hooks
                continue
            }
            switch section {
            case .sessions:
                if let record = ZellijSessionRecord.parse(line),
                    !result.sessions.contains(where: { $0.name == record.name })
                {
                    result.sessions.append(record)
                }
            case .panes:
                if line.hasPrefix("\u{1E}S") {
                    storePanes()
                    let name = String(line.dropFirst(2))
                    session = result.sessions.contains { $0.name == name && !$0.closed } ? name : nil
                } else if session != nil {
                    json += line + "\n"
                }
            case .hooks:
                if let state = ZellijPaneState.decode(Data(line.utf8)) {
                    result.documents[state.pane.description] = state
                }
            }
        }
        storePanes()
        return result
    }
}
