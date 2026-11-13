import Foundation

struct UltimateServerEvent: Sendable, Equatable {
    let name: String
    let data: String
    let id: String?
}

/// SSE framing, independent of HTTP chunk boundaries and UTF-8 byte boundaries.
/// A partial final event is discarded on EOF, as required by SSE.
struct UltimateEventStream {
    private var line = Data()
    private var skipLF = false
    private var firstLine = true
    private var eventName = ""
    private var dataLines: [String] = []
    private var eventBytes = 0
    private var lastID: String?
    private(set) var retryMilliseconds: Int?
    private let maximumEventBytes = 8 * 1024 * 1024

    mutating func append(_ bytes: Data) throws -> [UltimateServerEvent] {
        var events: [UltimateServerEvent] = []
        for byte in bytes {
            if skipLF {
                skipLF = false
                if byte == 10 { continue }
            }
            if byte == 10 || byte == 13 {
                if let event = processLine() { events.append(event) }
                line.removeAll(keepingCapacity: true)
                skipLF = byte == 13
            } else {
                line.append(byte)
            }
            eventBytes += 1
            guard line.count <= maximumEventBytes, eventBytes <= maximumEventBytes else {
                throw UltimateHTTPError.responseTooLarge
            }
        }
        return events
    }

    private mutating func processLine() -> UltimateServerEvent? {
        var text = String(decoding: line, as: UTF8.self)
        if firstLine {
            firstLine = false
            if text.hasPrefix("\u{feff}") { text.removeFirst() }
        }
        if text.isEmpty {
            defer {
                dataLines.removeAll(keepingCapacity: true)
                eventName = ""
                eventBytes = 0
            }
            guard !dataLines.isEmpty else { return nil }
            return UltimateServerEvent(
                name: eventName.isEmpty ? "message" : eventName,
                data: dataLines.joined(separator: "\n"), id: lastID)
        }
        if text.hasPrefix(":") { return nil }
        let colon = text.firstIndex(of: ":") ?? text.endIndex
        let field = String(text[..<colon])
        var value = colon == text.endIndex ? "" : String(text[text.index(after: colon)...])
        if value.hasPrefix(" ") { value.removeFirst() }
        switch field {
        case "event": eventName = value
        case "data": dataLines.append(value)
        case "id": if !value.utf8.contains(0) { lastID = value }
        case "retry":
            if !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) {
                retryMilliseconds = Int(value)
            }
        default: break
        }
        return nil
    }
}
