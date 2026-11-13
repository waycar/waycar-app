import Foundation
import WaycarSSH

/// Minimal duplex surface; HTTP never depends on SSH-library details.
protocol UltimateByteChannel: Sendable {
    func write(_ data: Data, timeout: Duration) async throws
    func read(maximumBytes: Int, timeout: Duration) async throws -> Data?
    func close(timeout: Duration) async throws
}

extension SSHStreamLocalChannel: UltimateByteChannel {}

enum UltimateHTTPError: Error, Equatable {
    case malformedResponse
    case responseTooLarge
    case invalidRequest
    case timedOut
    case status(Int)
}

struct UltimateHTTPHead: Sendable, Equatable {
    let status: Int
    /// Lowercase field names.
    let headers: [String: String]
}

struct UltimateHTTPResponse: Sendable {
    let head: UltimateHTTPHead
    let body: Data
}

/// One loopback HTTP/1.1 channel per request (Ultimate, OpenCode). The caller
/// owns admission and SSH connection reuse. `headers` are extra request
/// fields (OpenCode's `Authorization`); they never reach an error.
struct UltimateHTTPClient: Sendable {
    let port: UInt16
    let openChannel: @Sendable () async throws -> any UltimateByteChannel

    func request(
        method: String = "GET", path: String, body: Data? = nil,
        headers: [(String, String)] = [], timeout: Duration = .seconds(30)
    ) async throws -> UltimateHTTPResponse {
        let bytes = try requestBytes(method: method, path: path, body: body, headers: headers)
        let channel = try await openChannel()
        do {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            try await channel.write(bytes, timeout: remaining(until: deadline))
            var decoder = UltimateHTTPDecoder()
            var output = Data()
            while !decoder.isComplete {
                let input = try await channel.read(
                    maximumBytes: 64 * 1024, timeout: remaining(until: deadline))
                let part = try decoder.append(input ?? Data(), eof: input == nil)
                guard output.count + part.count <= 16 * 1024 * 1024 else {
                    throw UltimateHTTPError.responseTooLarge
                }
                output.append(part)
            }
            guard let head = decoder.head else { throw UltimateHTTPError.malformedResponse }
            try await channel.close(timeout: .seconds(2))
            return UltimateHTTPResponse(head: head, body: output)
        } catch {
            try? await channel.close(timeout: .seconds(2))
            throw error
        }
    }

    /// Cancelling the consumer cancels its reader and closes only its channel.
    /// `timeout` bounds silence (heartbeats count), not the stream's lifetime.
    func events(
        path: String = "/api/events", headers: [(String, String)] = [], timeout: Duration = .seconds(45)
    ) -> AsyncThrowingStream<UltimateServerEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var channel: (any UltimateByteChannel)?
                do {
                    let bytes = try requestBytes(method: "GET", path: path, body: nil, headers: headers)
                    let opened = try await openChannel()
                    channel = opened
                    try await opened.write(bytes, timeout: timeout)
                    var http = UltimateHTTPDecoder()
                    var sse = UltimateEventStream()
                    while !http.isComplete {
                        try Task.checkCancellation()
                        let input = try await opened.read(maximumBytes: 64 * 1024, timeout: timeout)
                        let body = try http.append(input ?? Data(), eof: input == nil)
                        if let head = http.head {
                            guard head.status == 200 else { throw UltimateHTTPError.status(head.status) }
                            guard head.headers["content-type"]?.lowercased()
                                .hasPrefix("text/event-stream") == true
                            else { throw UltimateHTTPError.malformedResponse }
                        }
                        for event in try sse.append(body) { continuation.yield(event) }
                    }
                    try await opened.close(timeout: .seconds(2))
                    continuation.finish()
                } catch {
                    if let channel { try? await channel.close(timeout: .seconds(2)) }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func remaining(until deadline: ContinuousClock.Instant) throws -> Duration {
        let duration = ContinuousClock.now.duration(to: deadline)
        guard duration > .zero else { throw UltimateHTTPError.timedOut }
        return duration
    }

    func requestBytes(
        method: String, path: String, body: Data?, headers: [(String, String)] = []
    ) throws -> Data {
        guard port > 0, ["GET", "POST", "DELETE", "PATCH", "PUT"].contains(method),
            path.hasPrefix("/"), !path.utf8.contains(where: { $0 <= 32 || $0 >= 127 })
        else { throw UltimateHTTPError.invalidRequest }
        var text = "\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\nAccept: application/json, text/event-stream\r\n"
        for (name, value) in headers {
            // A token name and a value without control bytes: no header injection.
            guard !name.isEmpty, name.utf8.allSatisfy({ $0 > 32 && $0 < 127 && $0 != UInt8(ascii: ":") }),
                !value.utf8.contains(where: { $0 < 32 || $0 == 127 })
            else { throw UltimateHTTPError.invalidRequest }
            text += "\(name): \(value)\r\n"
        }
        if let body { text += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n" }
        var data = Data((text + "\r\n").utf8)
        if let body { data.append(body) }
        return data
    }
}

/// Incremental HTTP/1.1 response framing shared by finite JSON and infinite SSE.
/// Only framing bytes are buffered; body bytes are returned as soon as available.
struct UltimateHTTPDecoder {
    private enum State {
        case head, length(Int), untilEOF, chunkSize, chunk(Int), chunkEnd, trailers, done
    }
    private var state = State.head
    private var buffer = Data()
    private(set) var head: UltimateHTTPHead?
    var isComplete: Bool { if case .done = state { return true }; return false }
    private static let crlf = Data("\r\n".utf8)
    private static let headEnd = Data("\r\n\r\n".utf8)

    mutating func append(_ bytes: Data, eof: Bool = false) throws -> Data {
        buffer.append(bytes)
        var output = Data()
        while true {
            switch state {
            case .head:
                guard let range = buffer.range(of: Self.headEnd) else {
                    guard buffer.count <= 64 * 1024 else { throw UltimateHTTPError.responseTooLarge }
                    if eof { throw UltimateHTTPError.malformedResponse }
                    return output
                }
                guard range.lowerBound - buffer.startIndex <= 64 * 1024 else {
                    throw UltimateHTTPError.responseTooLarge
                }
                let parsed = try parseHead(Data(buffer[..<range.lowerBound]))
                buffer.removeSubrange(..<range.upperBound)
                if (100..<200).contains(parsed.status) {
                    guard parsed.status != 101 else { throw UltimateHTTPError.malformedResponse }
                    continue
                }
                head = parsed
                if parsed.status == 204 || parsed.status == 304 { state = .done }
                else if let transfer = parsed.headers["transfer-encoding"] {
                    guard transfer.lowercased() == "chunked", parsed.headers["content-length"] == nil else {
                        throw UltimateHTTPError.malformedResponse
                    }
                    state = .chunkSize
                } else if let length = parsed.headers["content-length"] {
                    guard !length.isEmpty, length.utf8.allSatisfy({ (48...57).contains($0) }),
                        let count = Int(length)
                    else { throw UltimateHTTPError.malformedResponse }
                    state = .length(count)
                } else { state = .untilEOF }
            case .length(let count), .chunk(let count):
                let chunked: Bool
                if case .chunk = state { chunked = true } else { chunked = false }
                let consumed = min(count, buffer.count)
                output.append(buffer.prefix(consumed))
                buffer.removeFirst(consumed)
                if consumed == count { state = chunked ? .chunkEnd : .done }
                else {
                    state = chunked ? .chunk(count - consumed) : .length(count - consumed)
                    if eof { throw UltimateHTTPError.malformedResponse }
                    return output
                }
            case .untilEOF:
                output.append(buffer)
                buffer.removeAll(keepingCapacity: true)
                if eof { state = .done }
                return output
            case .chunkSize:
                guard let line = try takeLine(eof: eof) else { return output }
                let size = line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
                guard !size.isEmpty, size.utf8.allSatisfy({
                    (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
                }), let count = Int(size, radix: 16) else { throw UltimateHTTPError.malformedResponse }
                state = count == 0 ? .trailers : .chunk(count)
            case .chunkEnd:
                guard buffer.count >= 2 else {
                    if eof { throw UltimateHTTPError.malformedResponse }; return output
                }
                guard buffer.starts(with: Self.crlf) else { throw UltimateHTTPError.malformedResponse }
                buffer.removeFirst(2)
                state = .chunkSize
            case .trailers:
                guard let line = try takeLine(eof: eof) else { return output }
                if line.isEmpty { state = .done }
            case .done:
                return output
            }
        }
    }

    private mutating func takeLine(eof: Bool) throws -> String? {
        guard let range = buffer.range(of: Self.crlf) else {
            guard buffer.count <= 64 * 1024 else { throw UltimateHTTPError.responseTooLarge }
            if eof { throw UltimateHTTPError.malformedResponse }; return nil
        }
        guard range.lowerBound - buffer.startIndex <= 64 * 1024,
            let line = String(data: buffer[..<range.lowerBound], encoding: .utf8)
        else { throw UltimateHTTPError.malformedResponse }
        buffer.removeSubrange(..<range.upperBound)
        return line
    }

    private func parseHead(_ data: Data) throws -> UltimateHTTPHead {
        guard let text = String(data: data, encoding: .utf8) else { throw UltimateHTTPError.malformedResponse }
        let lines = text.components(separatedBy: "\r\n")
        let status = (lines.first ?? "").split(separator: " ", maxSplits: 2)
        guard status.count >= 2, status[0] == "HTTP/1.1", status[1].count == 3,
            let code = Int(status[1]), (100...599).contains(code)
        else { throw UltimateHTTPError.malformedResponse }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else {
                throw UltimateHTTPError.malformedResponse
            }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if headers[name] != nil { throw UltimateHTTPError.malformedResponse }
            headers[name] = value
        }
        return UltimateHTTPHead(status: code, headers: headers)
    }
}
