import Foundation

// herdr-core's framed connection (design §5, fact C3; research
// `attach-facts.md` §1): after the plain `hello` line, both directions carry
// frames `[channel u32 LE][kind u8][len u32 LE][payload]`, a 9-byte header and
// at most 16 MiB of payload. Frame boundaries are arbitrary: a read can end
// anywhere, inside a header or a payload.

/// What a frame is for. An unknown kind decodes as `.unknown` and readers
/// ignore it (core's API only grows).
enum CoreFrameKind: Equatable, Hashable, Sendable {
    /// Stream bytes: JSON-RPC lines on channel 0, notification lines on the
    /// events channel, terminal bytes on an attach channel.
    case data
    /// u32 LE count of payload bytes the receiver consumed.
    case credit
    /// End of a channel (the payload may carry a JSON reason).
    case close
    /// u16 LE columns, u16 LE rows.
    case resize
    /// One byte: 1 focus in, 0 focus out.
    case focus
    /// Viewer facts (colors, cell size) as JSON.
    case facts
    case unknown(UInt8)

    init(byte: UInt8) {
        switch byte {
        case 0: self = .data
        case 1: self = .credit
        case 2: self = .close
        case 3: self = .resize
        case 4: self = .focus
        case 5: self = .facts
        default: self = .unknown(byte)
        }
    }

    var byte: UInt8 {
        switch self {
        case .data: 0
        case .credit: 1
        case .close: 2
        case .resize: 3
        case .focus: 4
        case .facts: 5
        case .unknown(let byte): byte
        }
    }
}

struct CoreFrame: Equatable, Sendable {
    var channel: UInt32
    var kind: CoreFrameKind
    var payload: Data

    init(channel: UInt32, kind: CoreFrameKind, payload: Data = Data()) {
        self.channel = channel
        self.kind = kind
        self.payload = payload
    }
}

enum CoreFrameError: Error, Equatable, Sendable {
    /// A header announced more than ``CoreFrameCodec/maximumPayloadBytes``.
    /// The stream cannot be re-synchronised after it.
    case payloadTooLarge(length: Int)
}

enum CoreFrameCodec {
    static let headerBytes = 9
    static let maximumPayloadBytes = 16 * 1024 * 1024

    /// The wire bytes of `frame`. A payload over the limit is cut into
    /// consecutive frames of the same channel and kind, which every stream
    /// kind (`data`) accepts; the other kinds never come near the limit.
    static func encode(_ frame: CoreFrame) -> Data {
        var output = Data()
        var offset = frame.payload.startIndex
        repeat {
            let end = min(offset + maximumPayloadBytes, frame.payload.endIndex)
            let chunk = frame.payload[offset..<end]
            output.reserveCapacity(output.count + headerBytes + chunk.count)
            append(frame.channel, to: &output)
            output.append(frame.kind.byte)
            append(UInt32(chunk.count), to: &output)
            output.append(chunk)
            offset = end
        } while offset < frame.payload.endIndex
        return output
    }

    static func data(channel: UInt32, _ payload: Data) -> Data {
        encode(CoreFrame(channel: channel, kind: .data, payload: payload))
    }

    /// Tells core `bytes` of the channel's payload were consumed, so it may
    /// send that much more (each stream starts with 256 KiB of credit).
    static func credit(channel: UInt32, bytes: Int) -> Data {
        var payload = Data()
        append(UInt32(clamping: max(bytes, 0)), to: &payload)
        return encode(CoreFrame(channel: channel, kind: .credit, payload: payload))
    }

    static func close(channel: UInt32) -> Data {
        encode(CoreFrame(channel: channel, kind: .close))
    }

    static func resize(channel: UInt32, cols: UInt16, rows: UInt16) -> Data {
        var payload = Data()
        append(cols, to: &payload)
        append(rows, to: &payload)
        return encode(CoreFrame(channel: channel, kind: .resize, payload: payload))
    }

    static func focus(channel: UInt32, focused: Bool) -> Data {
        encode(CoreFrame(channel: channel, kind: .focus, payload: Data([focused ? 1 : 0])))
    }

    /// The u32 LE a CREDIT frame carries; nil when the payload is not 4 bytes.
    static func creditBytes(of frame: CoreFrame) -> Int? {
        guard frame.kind == .credit, frame.payload.count == 4 else { return nil }
        return Int(readUInt32(Array(frame.payload), at: 0))
    }

    fileprivate static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        let b0 = UInt32(bytes[offset])
        let b1 = UInt32(bytes[offset + 1]) << 8
        let b2 = UInt32(bytes[offset + 2]) << 16
        let b3 = UInt32(bytes[offset + 3]) << 24
        return b0 | b1 | b2 | b3
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private static func append(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }
}

/// Turns the bytes of a framed connection, in whatever pieces they arrive,
/// into frames. Bytes of an incomplete header or payload wait for the next
/// `feed`.
struct CoreFrameDecoder: Sendable {
    private var buffer: [UInt8] = []
    private var failure: CoreFrameError?

    init() {}

    /// Bytes held back, waiting for the rest of a frame.
    var bufferedByteCount: Int { buffer.count }

    /// Every frame `data` completes, in order. Throws once a header announces
    /// more than 16 MiB; the decoder then keeps throwing, because the bytes
    /// after a bad header cannot be told apart from frames.
    mutating func feed(_ data: Data) throws -> [CoreFrame] {
        if let failure { throw failure }
        buffer.append(contentsOf: data)
        var frames: [CoreFrame] = []
        var offset = 0
        while buffer.count - offset >= CoreFrameCodec.headerBytes {
            let length = Int(CoreFrameCodec.readUInt32(buffer, at: offset + 5))
            if length > CoreFrameCodec.maximumPayloadBytes {
                let error = CoreFrameError.payloadTooLarge(length: length)
                failure = error
                buffer.removeAll()
                throw error
            }
            let end = offset + CoreFrameCodec.headerBytes + length
            guard buffer.count >= end else { break }
            let channel = CoreFrameCodec.readUInt32(buffer, at: offset)
            frames.append(
                CoreFrame(
                    channel: channel, kind: CoreFrameKind(byte: buffer[offset + 4]),
                    payload: Data(buffer[(offset + CoreFrameCodec.headerBytes)..<end])))
            offset = end
        }
        if offset > 0 { buffer.removeSubrange(0..<offset) }
        return frames
    }
}
