import CryptoKit
import Foundation

/// No extensions are negotiated: Codex's optional compression is deliberately off.
enum CodexWebSocketError: Error, Equatable {
    case invalidHandshake, badAccept, status(Int), timedOut
    case maskedServerFrame, reservedBits, messageTooLarge, protocolViolation, invalidUTF8
    case unexpectedEOF, closed, concurrentReceive
}

/// RFC 6455 over a forwarding channel. One consumer calls `receive`; all writes,
/// including control replies, share a queue so SSH writes cannot interleave.
actor CodexWebSocket {
    private let channel: any UltimateByteChannel
    private let maximumMessageBytes: Int
    private let writeTimeout: Duration
    private var buffer: Data
    private var fragmentOpcode: UInt8?
    private var fragmentBytes = Data()
    private var receiving = false
    private var ended = false
    private var writeTail: Task<Void, any Error>?

    private init(
        channel: any UltimateByteChannel, buffer: Data,
        maximumMessageBytes: Int, writeTimeout: Duration
    ) {
        self.channel = channel
        self.buffer = buffer
        self.maximumMessageBytes = maximumMessageBytes
        self.writeTimeout = writeTimeout
    }

    static func connect(
        channel: any UltimateByteChannel, timeout: Duration = .seconds(30),
        maximumMessageBytes: Int = 32 * 1024 * 1024
    ) async throws -> CodexWebSocket {
        let key = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
        let request = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
        let deadline = ContinuousClock.now.advanced(by: timeout)
        func remaining() throws -> Duration {
            let left = ContinuousClock.now.duration(to: deadline)
            guard left > .zero else { throw CodexWebSocketError.timedOut }
            return left
        }
        do {
            try await channel.write(Data(request.utf8), timeout: remaining())
            var buffer = Data()
            while true {
                if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    guard end.lowerBound - buffer.startIndex <= 64 * 1024 else {
                        throw CodexWebSocketError.invalidHandshake
                    }
                    try validateHead(Data(buffer[..<end.lowerBound]), key: key)
                    return CodexWebSocket(
                        channel: channel, buffer: Data(buffer[end.upperBound...]),
                        maximumMessageBytes: max(0, maximumMessageBytes), writeTimeout: timeout)
                }
                guard buffer.count <= 64 * 1024 else { throw CodexWebSocketError.invalidHandshake }
                guard let bytes = try await channel.read(maximumBytes: 64 * 1024, timeout: remaining()) else {
                    throw CodexWebSocketError.unexpectedEOF
                }
                buffer.append(bytes)
            }
        } catch {
            try? await channel.close(timeout: .seconds(2))
            throw error
        }
    }

    static func accept(for key: String) -> String {
        Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)))
            .base64EncodedString()
    }

    private static func validateHead(_ data: Data, key: String) throws {
        guard let text = String(data: data, encoding: .utf8) else { throw CodexWebSocketError.invalidHandshake }
        let lines = text.components(separatedBy: "\r\n")
        let status = (lines.first ?? "").split(separator: " ", maxSplits: 2)
        guard status.count >= 2, status[0] == "HTTP/1.1", let code = Int(status[1]) else {
            throw CodexWebSocketError.invalidHandshake
        }
        guard code == 101 else { throw CodexWebSocketError.status(code) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else {
                throw CodexWebSocketError.invalidHandshake
            }
            let name = line[..<colon].lowercased()
            guard headers[name] == nil else { throw CodexWebSocketError.invalidHandshake }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let connection = headers["connection"]?.lowercased().split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        guard headers["upgrade"]?.lowercased() == "websocket", connection.contains("upgrade"),
            headers["sec-websocket-extensions"] == nil, headers["sec-websocket-protocol"] == nil
        else { throw CodexWebSocketError.invalidHandshake }
        guard headers["sec-websocket-accept"] == accept(for: key) else { throw CodexWebSocketError.badAccept }
    }

    func send(text: String, shouldSend: @escaping @Sendable () async -> Bool = { true }) async throws {
        guard !ended else { throw CodexWebSocketError.closed }
        let payload = Data(text.utf8)
        guard payload.count <= maximumMessageBytes else { throw CodexWebSocketError.messageTooLarge }
        do { try await write(opcode: 1, payload: payload, shouldSend: shouldSend) }
        catch is CancellationError { throw CancellationError() }
        catch { await end(); throw error }
    }

    /// Binary messages are consumed but not exposed; Codex RPC uses text only.
    func receive() async throws -> String? {
        guard !receiving else { throw CodexWebSocketError.concurrentReceive }
        guard !ended else { return nil }
        receiving = true
        defer { receiving = false }
        do {
            while !ended {
                try Task.checkCancellation()
                let (opcode, final, payload) = try await readFrame()
                switch opcode {
                case 8:
                    guard payload.count != 1 else { throw CodexWebSocketError.protocolViolation }
                    if payload.count >= 2 {
                        let code = Int(payload[payload.startIndex]) * 256 + Int(payload[payload.startIndex + 1])
                        guard (1000...1014).contains(code) && ![1004, 1005, 1006].contains(code)
                            || (3000...4999).contains(code) else { throw CodexWebSocketError.protocolViolation }
                        guard String(data: payload.dropFirst(2), encoding: .utf8) != nil else {
                            throw CodexWebSocketError.invalidUTF8
                        }
                    }
                    // Queue the echo before making close visible to concurrent senders.
                    let echo = enqueue(opcode: 8, payload: payload)
                    ended = true
                    try await echo.value
                    await end()
                    return nil
                case 9: try await write(opcode: 10, payload: payload)
                case 10: continue
                case 0, 1, 2:
                    if opcode == 0 {
                        guard fragmentOpcode != nil else { throw CodexWebSocketError.protocolViolation }
                    } else {
                        guard fragmentOpcode == nil else { throw CodexWebSocketError.protocolViolation }
                        fragmentOpcode = opcode
                    }
                    guard payload.count <= maximumMessageBytes - fragmentBytes.count else {
                        throw CodexWebSocketError.messageTooLarge
                    }
                    fragmentBytes.append(payload)
                    if final {
                        let isText = fragmentOpcode == 1
                        let message = fragmentBytes
                        fragmentOpcode = nil
                        fragmentBytes = Data()
                        if isText {
                            guard let text = String(data: message, encoding: .utf8) else {
                                throw CodexWebSocketError.invalidUTF8
                            }
                            return text
                        }
                    }
                default: throw CodexWebSocketError.protocolViolation
                }
            }
            return nil
        } catch {
            await end()
            throw error
        }
    }

    func close() async {
        if !ended {
            let close = enqueue(opcode: 8, payload: Data())
            ended = true
            _ = try? await close.value
        }
        await end()
    }

    private func end() async {
        ended = true
        fragmentBytes = Data()
        writeTail?.cancel()
        try? await channel.close(timeout: .seconds(2))
    }

    private func write(
        opcode: UInt8, payload: Data, shouldSend: @escaping @Sendable () async -> Bool = { true }
    ) async throws {
        guard !ended else { throw CodexWebSocketError.closed }
        let task = enqueue(opcode: opcode, payload: payload, shouldSend: shouldSend)
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    private func enqueue(
        opcode: UInt8, payload: Data, shouldSend: @escaping @Sendable () async -> Bool = { true }
    ) -> Task<Void, any Error> {
        let previous = writeTail
        let bytes = Self.frame(opcode: opcode, payload: payload)
        let channel = channel
        let timeout = writeTimeout
        let task = Task {
            if let previous {
                do { try await previous.value }
                catch is CancellationError { /* A skipped frame does not break the queue. */ }
            }
            try Task.checkCancellation()
            guard await shouldSend() else { throw CancellationError() }
            try Task.checkCancellation()
            try await channel.write(bytes, timeout: timeout)
        }
        writeTail = task
        return task
    }

    private static func frame(opcode: UInt8, payload: Data) -> Data {
        var frame = Data([0x80 | opcode])
        if payload.count < 126 { frame.append(0x80 | UInt8(payload.count)) }
        else {
            let count = UInt64(payload.count)
            frame.append(payload.count <= 65535 ? 0xfe : 0xff)
            for shift in stride(from: payload.count <= 65535 ? 8 : 56, through: 0, by: -8) {
                frame.append(UInt8(truncatingIfNeeded: count >> shift))
            }
        }
        let mask = (0..<4).map { _ in UInt8.random(in: .min ... .max) }
        frame.append(contentsOf: mask)
        frame.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        return frame
    }

    private func fill(_ count: Int) async throws {
        while buffer.count < count {
            guard !ended else { throw CodexWebSocketError.closed }
            // No application heartbeat is required by Codex. Per-request RPC timers
            // bound calls independently of this otherwise idle connection.
            guard let bytes = try await channel.read(maximumBytes: 64 * 1024, timeout: .seconds(86400)) else {
                throw CodexWebSocketError.unexpectedEOF
            }
            guard !ended else { throw CodexWebSocketError.closed }
            buffer.append(bytes)
        }
    }

    private func readFrame() async throws -> (UInt8, Bool, Data) {
        try await fill(2)
        var header = Array(buffer.prefix(2))
        guard header[0] & 0x70 == 0 else { throw CodexWebSocketError.reservedBits }
        guard header[1] & 0x80 == 0 else { throw CodexWebSocketError.maskedServerFrame }
        let opcode = header[0] & 0x0f
        let final = header[0] & 0x80 != 0
        guard [0, 1, 2, 8, 9, 10].contains(opcode) else { throw CodexWebSocketError.protocolViolation }
        let marker = header[1] & 0x7f
        if opcode >= 8, !final || marker > 125 { throw CodexWebSocketError.protocolViolation }
        let headerCount = marker == 127 ? 10 : marker == 126 ? 4 : 2
        try await fill(headerCount)
        header = Array(buffer.prefix(headerCount))
        var count = UInt64(marker)
        if marker >= 126 {
            count = header.dropFirst(2).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            guard count >> 63 == 0, count >= (marker == 126 ? 126 : 65536) else {
                throw CodexWebSocketError.protocolViolation
            }
        }
        guard count <= UInt64(maximumMessageBytes) || opcode >= 8 else { throw CodexWebSocketError.messageTooLarge }
        if opcode < 8, count > UInt64(maximumMessageBytes - fragmentBytes.count) {
            throw CodexWebSocketError.messageTooLarge
        }
        try await fill(headerCount + Int(count))
        buffer.removeFirst(headerCount)
        let payload = Data(buffer.prefix(Int(count)))
        buffer.removeFirst(Int(count))
        return (opcode, final, payload)
    }
}
