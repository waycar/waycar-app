import Foundation
import Testing

@testable import Waycar

@Suite("Codex WebSocket", .timeLimit(.minutes(1)))
struct CodexWebSocketTests {
    @Test func handshakeAndRFCVector() async throws {
        #expect(CodexWebSocket.accept(for: "dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
        let channel = CodexMemoryChannel()
        let socket = try await CodexWebSocket.connect(channel: channel)
        let request = String(decoding: try #require(await channel.writes.first), as: UTF8.self)
        #expect(request.hasPrefix("GET / HTTP/1.1\r\nHost: localhost\r\n"))
        #expect(request.contains("Upgrade: websocket\r\nConnection: Upgrade\r\n"))
        #expect(request.contains("Sec-WebSocket-Version: 13\r\n"))
        #expect(!request.contains("Sec-WebSocket-Extensions"))
        #expect(!request.contains("Sec-WebSocket-Protocol:"))
        #expect(Data(base64Encoded: try #require(await channel.key))?.count == 16)
        await socket.close()
    }

    @Test func badAccept() async throws {
        let channel = CodexMemoryChannel(acceptOverride: "wrong")
        await #expect(throws: CodexWebSocketError.badAccept) {
            _ = try await CodexWebSocket.connect(channel: channel)
        }
        #expect(await channel.closed)
    }

    @Test func non101() async throws {
        let channel = CodexMemoryChannel(status: 403)
        await #expect(throws: CodexWebSocketError.status(403)) {
            _ = try await CodexWebSocket.connect(channel: channel)
        }
        #expect(await channel.closed)
    }

    @Test func masksClientFramesAndSerializesWrites() async throws {
        let channel = CodexMemoryChannel()
        let socket = try await CodexWebSocket.connect(channel: channel)
        async let first: Void = socket.send(text: "first")
        async let second: Void = socket.send(text: String(repeating: "x", count: 126))
        _ = try await (first, second)
        let frames = try await channel.clientFrames()
        #expect(Set(frames.map { String(decoding: $0.payload, as: UTF8.self) }) == ["first", String(repeating: "x", count: 126)])
        #expect(frames.allSatisfy { $0.opcode == 1 })
        #expect(await channel.maximumConcurrentWrites == 1)
        await socket.close()
    }

    @Test func fragmentedTextWithControlAndBinary() async throws {
        let bytes = Data("hello 👁".utf8)
        let channel = CodexMemoryChannel(afterHead:
            CodexMemoryChannel.serverFrame(opcode: 2, payload: Data([0xff]))
            + CodexMemoryChannel.serverFrame(opcode: 1, payload: Data(bytes.prefix(8)), final: false)
            + CodexMemoryChannel.serverFrame(opcode: 9, payload: Data("ping".utf8))
            + CodexMemoryChannel.serverFrame(opcode: 0, payload: Data(bytes.dropFirst(8))))
        let socket = try await CodexWebSocket.connect(channel: channel)
        #expect(try await socket.receive() == "hello 👁")
        let pong = try #require(try await channel.clientFrames().first)
        #expect(pong.opcode == 10)
        #expect(pong.payload == Data("ping".utf8))
        await socket.close()
    }

    @Test func upgradeTailAndByteBoundaries() async throws {
        let channel = CodexMemoryChannel(afterHead: CodexMemoryChannel.serverFrame(text: "tail"), bytewise: true)
        let socket = try await CodexWebSocket.connect(channel: channel)
        #expect(try await socket.receive() == "tail")
        await socket.close()
    }

    @Test func closeEchoesPayloadAndEnds() async throws {
        let payload = Data([3, 232]) + Data("bye".utf8)
        let channel = CodexMemoryChannel(afterHead: CodexMemoryChannel.serverFrame(opcode: 8, payload: payload))
        let socket = try await CodexWebSocket.connect(channel: channel)
        #expect(try await socket.receive() == nil)
        let echo = try #require(try await channel.clientFrames().first)
        #expect(echo.opcode == 8)
        #expect(echo.payload == payload)
        #expect(await channel.closed)
        await #expect(throws: CodexWebSocketError.closed) { try await socket.send(text: "late") }
    }

    @Test func oversizedHeaderRejectedBeforePayloadRead() async throws {
        let channel = CodexMemoryChannel(afterHead: Data([0x81, 127, 0, 0, 0, 0, 2, 0, 0, 1]))
        let socket = try await CodexWebSocket.connect(channel: channel)
        await #expect(throws: CodexWebSocketError.messageTooLarge) { _ = try await socket.receive() }
        #expect(await channel.closed)
    }

    @Test func fragmentedSizeIsCumulative() async throws {
        let channel = CodexMemoryChannel(afterHead:
            CodexMemoryChannel.serverFrame(opcode: 1, payload: Data("abc".utf8), final: false)
            + CodexMemoryChannel.serverFrame(opcode: 0, payload: Data("de".utf8)))
        let socket = try await CodexWebSocket.connect(channel: channel, maximumMessageBytes: 4)
        await #expect(throws: CodexWebSocketError.messageTooLarge) { _ = try await socket.receive() }
    }

    @Test func maskedServerRejected() async throws {
        let channel = CodexMemoryChannel(afterHead: Data([0x81, 0x80]))
        let socket = try await CodexWebSocket.connect(channel: channel)
        await #expect(throws: CodexWebSocketError.maskedServerFrame) { _ = try await socket.receive() }
    }

    @Test func reservedBitsRejected() async throws {
        let channel = CodexMemoryChannel(afterHead: Data([0xc1, 0]))
        let socket = try await CodexWebSocket.connect(channel: channel)
        await #expect(throws: CodexWebSocketError.reservedBits) { _ = try await socket.receive() }
    }
}

/// A real duplex fixture: reads wait for fed bytes, close or cancellation.
/// The handshake derives its accept from the random key the client actually sent.
actor CodexMemoryChannel: UltimateByteChannel {
    struct ClientFrame: Sendable {
        let opcode: UInt8
        let payload: Data
    }
    private let status: Int
    private let acceptOverride: String?
    private let afterHead: Data
    private let bytewise: Bool
    private var queued: [Data] = []
    private var waiter: (UUID, CheckedContinuation<Data?, any Error>)?
    private var blockWrite = false
    private var blockedWrite: CheckedContinuation<Void, Never>?
    func blockNextWrite() { blockWrite = true }
    func releaseWrite() { blockedWrite?.resume(); blockedWrite = nil }
    private var concurrentWrites = 0
    private(set) var maximumConcurrentWrites = 0
    private(set) var writes: [Data] = []
    private(set) var key: String?
    private(set) var closed = false

    init(status: Int = 101, acceptOverride: String? = nil, afterHead: Data = Data(), bytewise: Bool = false) {
        self.status = status
        self.acceptOverride = acceptOverride
        self.afterHead = afterHead
        self.bytewise = bytewise
    }

    func write(_ data: Data, timeout: Duration) async throws {
        concurrentWrites += 1
        maximumConcurrentWrites = max(maximumConcurrentWrites, concurrentWrites)
        defer { concurrentWrites -= 1 }
        writes.append(data)
        if blockWrite {
            blockWrite = false
            await withCheckedContinuation { blockedWrite = $0 }
        }
        await Task.yield()
        if writes.count == 1 {
            let request = String(decoding: data, as: UTF8.self)
            key = request.components(separatedBy: "\r\n")
                .first { $0.hasPrefix("Sec-WebSocket-Key: ") }?.replacingOccurrences(of: "Sec-WebSocket-Key: ", with: "")
            let accept = acceptOverride ?? CodexWebSocket.accept(for: key ?? "")
            let response = Data("HTTP/1.1 \(status) Response\r\nUpgrade: websocket\r\nConnection: keep-alive, Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n".utf8) + afterHead
            if bytewise { for byte in response { feed(Data([byte])) } }
            else { feed(response) }
        }
    }

    func feed(_ data: Data) {
        if let (_, continuation) = waiter {
            waiter = nil
            continuation.resume(returning: data)
        } else { queued.append(data) }
    }

    func read(maximumBytes: Int, timeout: Duration) async throws -> Data? {
        try Task.checkCancellation()
        if !queued.isEmpty { return queued.removeFirst() }
        if closed { return nil }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiter = (id, continuation) }
            }
        } onCancel: { Task { await self.cancelRead(id) } }
    }

    private func cancelRead(_ id: UUID) {
        guard let (current, continuation) = waiter, current == id else { return }
        waiter = nil
        continuation.resume(throwing: CancellationError())
    }

    func close(timeout: Duration) {
        closed = true
        if let (_, continuation) = waiter {
            waiter = nil
            continuation.resume(returning: nil)
        }
    }

    func waitForFrames(_ count: Int) async throws -> [ClientFrame] {
        let deadline = ContinuousClock.now.advanced(by: .waitCeiling)
        while writes.count - 1 < count {
            guard ContinuousClock.now < deadline else { throw CodexRPCClientError.timedOut }
            try await Task.sleep(for: .milliseconds(1))
        }
        return try clientFrames()
    }

    func clientFrames() throws -> [ClientFrame] {
        try writes.dropFirst().map { frame in
            let bytes = Array(frame)
            #expect(bytes[1] & 0x80 != 0)
            var count = Int(bytes[1] & 0x7f)
            var offset = 2
            if count == 126 { count = Int(bytes[2]) * 256 + Int(bytes[3]); offset = 4 }
            else if count == 127 {
                count = bytes[2..<10].reduce(0) { ($0 << 8) | Int($1) }
                offset = 10
            }
            let mask = Array(bytes[offset..<(offset + 4)])
            let payload = Data(bytes[(offset + 4)...].enumerated().map { $0.element ^ mask[$0.offset % 4] })
            #expect(payload.count == count)
            return ClientFrame(opcode: bytes[0] & 0x0f, payload: payload)
        }
    }

    static func serverFrame(text: String) -> Data { serverFrame(opcode: 1, payload: Data(text.utf8)) }

    static func serverFrame(opcode: UInt8, payload: Data, final: Bool = true) -> Data {
        var frame = Data([(final ? 0x80 : 0) | opcode])
        if payload.count < 126 { frame.append(UInt8(payload.count)) }
        else {
            frame.append(126)
            frame.append(UInt8(truncatingIfNeeded: payload.count >> 8))
            frame.append(UInt8(truncatingIfNeeded: payload.count))
        }
        return frame + payload
    }
}
