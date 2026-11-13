import Foundation
import Testing

@testable import Waycar

@Suite("herdr-core frame codec", .timeLimit(.minutes(1)))
struct CoreFrameCodecTests {
    private static func decodeAll(_ data: Data, chunkSize: Int) throws -> [CoreFrame] {
        var decoder = CoreFrameDecoder()
        var frames: [CoreFrame] = []
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = min(offset + chunkSize, data.endIndex)
            frames += try decoder.feed(Data(data[offset..<end]))
            offset = end
        }
        return frames
    }

    /// The client-to-core capture without its plain `hello` line.
    private static var clientFrameBytes: Data {
        Data(CoreTranscripts.wireMinimalFromClient.dropFirst(CoreTranscripts.wireMinimalHelloLineBytes))
    }

    @Test func decodesTheCapturedSession() throws {
        var decoder = CoreFrameDecoder()
        let frames = try decoder.feed(CoreTranscripts.wireMinimalFromCore)
        #expect(
            frames.map { [Int($0.channel), Int($0.kind.byte), $0.payload.count] }
                == [[0, 0, 583], [1, 0, 228], [1, 0, 6], [1, 2, 0]])
        #expect(frames.map(\.kind) == [.data, .data, .data, .close])
        #expect(
            String(decoding: frames[0].payload.prefix(39), as: UTF8.self)
                == #"{"id":1,"jsonrpc":"2.0","result":{"chan"#)
        #expect(frames[2].payload == Data("x\r\nx\r\n".utf8))
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test func decodesTheClientSideOfTheCapture() throws {
        let frames = try Self.decodeAll(Self.clientFrameBytes, chunkSize: 1_000)
        #expect(frames.map(\.kind) == [.data, .credit, .data, .credit, .resize, .close])
        #expect(frames.map(\.channel) == [0, 1, 1, 1, 1, 1])
        #expect(CoreFrameCodec.creditBytes(of: frames[1]) == 228)
        #expect(CoreFrameCodec.creditBytes(of: frames[3]) == 6)
        #expect(frames[2].payload == Data("x\r".utf8))
        #expect(frames[4].payload == Data([40, 0, 20, 0]))
    }

    @Test func encodingReproducesTheCapturedBytes() throws {
        let captured = Self.clientFrameBytes
        let frames = try Self.decodeAll(captured, chunkSize: captured.count)
        #expect(frames.map { CoreFrameCodec.encode($0) }.reduce(Data(), +) == captured)
        // And the helpers build the same frames the probe sent.
        #expect(CoreFrameCodec.credit(channel: 1, bytes: 228) == CoreFrameCodec.encode(frames[1]))
        #expect(CoreFrameCodec.data(channel: 1, Data("x\r".utf8)) == CoreFrameCodec.encode(frames[2]))
        #expect(CoreFrameCodec.credit(channel: 1, bytes: 6) == CoreFrameCodec.encode(frames[3]))
        #expect(
            CoreFrameCodec.resize(channel: 1, cols: 40, rows: 20) == CoreFrameCodec.encode(frames[4]))
        #expect(CoreFrameCodec.close(channel: 1) == CoreFrameCodec.encode(frames[5]))
    }

    @Test func creditCarriesALittleEndianU32() {
        #expect(
            CoreFrameCodec.credit(channel: 1, bytes: 753)
                == Data([1, 0, 0, 0, 1, 4, 0, 0, 0, 0xF1, 0x02, 0, 0]))
        #expect(
            CoreFrameCodec.credit(channel: 0x0102_0304, bytes: 0x0A0B_0C0D)
                == Data([4, 3, 2, 1, 1, 4, 0, 0, 0, 0x0D, 0x0C, 0x0B, 0x0A]))
    }

    @Test func frameBoundariesCanBeAnywhere() throws {
        let whole = try Self.decodeAll(
            CoreTranscripts.wireMinimalFromCore, chunkSize: CoreTranscripts.wireMinimalFromCore.count)
        #expect(whole.count == 4)
        // One byte at a time: every header and payload is split.
        #expect(try Self.decodeAll(CoreTranscripts.wireMinimalFromCore, chunkSize: 1) == whole)
        // Two reads cut at every possible offset.
        let bytes = CoreTranscripts.wireMinimalFromCore
        for cut in 0...bytes.count {
            var decoder = CoreFrameDecoder()
            let frames =
                try decoder.feed(Data(bytes.prefix(cut))) + decoder.feed(Data(bytes.dropFirst(cut)))
            #expect(frames == whole, "cut at \(cut)")
        }
    }

    @Test func aPartialFrameWaitsForTheRest() throws {
        var decoder = CoreFrameDecoder()
        let frame = CoreFrameCodec.data(channel: 7, Data("hello".utf8))
        #expect(try decoder.feed(frame.prefix(4)).isEmpty)
        #expect(try decoder.feed(frame.dropFirst(4).prefix(6)).isEmpty)  // header done, 1 payload byte
        #expect(decoder.bufferedByteCount == 10)
        let frames = try decoder.feed(frame.dropFirst(10))
        #expect(frames == [CoreFrame(channel: 7, kind: .data, payload: Data("hello".utf8))])
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test func unknownKindsDecodeAndTheStreamGoesOn() throws {
        var bytes = CoreFrameCodec.encode(CoreFrame(channel: 3, kind: .unknown(9), payload: Data([1, 2])))
        bytes += CoreFrameCodec.data(channel: 3, Data("after".utf8))
        var decoder = CoreFrameDecoder()
        let frames = try decoder.feed(bytes)
        #expect(frames.map(\.kind) == [.unknown(9), .data])
        #expect(frames[0].payload == Data([1, 2]))
        #expect(frames[1].payload == Data("after".utf8))
        #expect(CoreFrameKind(byte: 5) == .facts)
        #expect(CoreFrameKind.unknown(200).byte == 200)
    }

    @Test func aHeaderOverSixteenMebibytesThrowsAndKeepsThrowing() throws {
        var decoder = CoreFrameDecoder()
        let tooLarge = CoreFrameCodec.maximumPayloadBytes + 1
        let header = Data([1, 0, 0, 0, 0] + littleEndian(tooLarge))
        #expect(throws: CoreFrameError.payloadTooLarge(length: tooLarge)) {
            try decoder.feed(header)
        }
        #expect(throws: CoreFrameError.self) {
            try decoder.feed(CoreFrameCodec.data(channel: 0, Data("x".utf8)))
        }
    }

    @Test func aHeaderForExactlySixteenMebibytesIsAccepted() throws {
        var decoder = CoreFrameDecoder()
        let header = Data([1, 0, 0, 0, 0] + littleEndian(CoreFrameCodec.maximumPayloadBytes))
        #expect(try decoder.feed(header).isEmpty)
        #expect(decoder.bufferedByteCount == 9)
    }

    @Test func anOversizedDataPayloadIsSplitIntoValidFrames() throws {
        let payload = Data(repeating: 0x61, count: CoreFrameCodec.maximumPayloadBytes + 10)
        let wire = CoreFrameCodec.data(channel: 4, payload)
        var decoder = CoreFrameDecoder()
        let frames = try decoder.feed(wire)
        #expect(frames.map(\.payload.count) == [CoreFrameCodec.maximumPayloadBytes, 10])
        #expect(frames.allSatisfy { $0.channel == 4 && $0.kind == .data })
    }

    @Test func anEmptyCloseIsAHeaderOnly() {
        #expect(CoreFrameCodec.close(channel: 2) == Data([2, 0, 0, 0, 2, 0, 0, 0, 0]))
        #expect(
            CoreFrameCodec.focus(channel: 2, focused: true) == Data([2, 0, 0, 0, 4, 1, 0, 0, 0, 1]))
    }

    private func littleEndian(_ value: Int) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }
}
