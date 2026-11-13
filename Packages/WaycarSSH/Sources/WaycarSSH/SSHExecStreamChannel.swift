import Foundation
import Synchronization

/// A package-owned SSH session channel with one directly executed remote
/// command and no PTY: a long-lived, duplex byte stream on the command's
/// stdin and stdout, for line protocols such as `tmux -C`.
///
/// It shares `SSHPTYChannel`'s lifecycle and driver rules (ADR 0011 and its
/// #130 amendment): reads and writes take short turns on the driver, close is
/// a resource transition that stops accepting I/O before it yields, and
/// exit-status failure restores I/O so the caller can retry or close.
///
/// Stderr is a separate stream that `read` drains on every turn so it can
/// never hold stdout back; only its last `standardErrorTailCapacity` bytes
/// are kept, for diagnostics. A caller that stops reading stops that drain
/// as well, exactly as it stops stdout.
public final class SSHExecStreamChannel: Sendable {
    /// How many trailing stderr bytes `standardErrorTail()` keeps.
    public static let standardErrorTailCapacity = ExecStreamStandardErrorTail.capacity

    private let id: UInt64
    private let driver: SessionDriver
    private let standardError = ExecStreamStandardErrorTail()

    init(id: UInt64, driver: SessionDriver) {
        self.id = id
        self.driver = driver
    }

    /// Writes all of `data` to the command's stdin.
    public func write(_ data: Data, timeout: Duration) async throws {
        try await driver.writeExecStream(id: id, data: data, timeout: timeout)
    }

    /// Reads the command's stdout, or nil after orderly remote EOF.
    public func read(
        maximumBytes: Int = 16 * 1024,
        timeout: Duration
    ) async throws -> Data? {
        try await driver.readExecStream(
            id: id,
            maximumBytes: maximumBytes,
            standardError: standardError,
            timeout: timeout)
    }

    /// The last stderr bytes `read` has drained, decoded as UTF-8 with
    /// invalid sequences replaced. Survives `close`.
    public func standardErrorTail() async -> String {
        standardError.text
    }

    /// Completes the close handshake and returns the remote status after
    /// `read` has reported EOF.
    public func exitStatus(timeout: Duration) async throws -> Int32 {
        try await driver.execStreamExitStatus(id: id, timeout: timeout)
    }

    /// Closes only this channel. Idempotent.
    public func close(timeout: Duration) async throws {
        try await driver.closeExecStream(id: id, timeout: timeout)
    }

#if DEBUG
    func acceptsIOForTesting() async -> Bool {
        await driver.execStreamAcceptsIOForTesting(id: id)
    }
#endif

    deinit {
        let id = id
        let driver = driver
        Task { try? await driver.closeExecStream(id: id, timeout: .seconds(2)) }
    }
}

/// The bounded stderr tail of one exec stream. The driver appends to it from
/// inside a read turn; the channel handle reads it at any time, including
/// after the driver has dropped the channel.
final class ExecStreamStandardErrorTail: Sendable {
    static let capacity = 4 * 1_024

    private let bytes = Mutex(Data())

    func append(_ data: Data) {
        bytes.withLock { tail in
            tail.append(data)
            let excess = tail.count - Self.capacity
            if excess > 0 { tail.removeFirst(excess) }
        }
    }

    var text: String {
        String(decoding: bytes.withLock { $0 }, as: UTF8.self)
    }
}
