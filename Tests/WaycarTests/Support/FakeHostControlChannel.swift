import Foundation
import Synchronization

@testable import Waycar

/// A scripted `HostControlChannel`: tests queue what each `read` returns
/// (stdout bytes, EOF, a failure, or a read timeout) and observe the lines
/// written. Reads park until something is queued; `close()` fails a parked
/// read and every later read or write, as a closed SSH channel does.
final class FakeHostControlChannel: HostControlChannel {
    enum ReadResult: Sendable {
        case data(Data)
        case eof
        case failure(TransportError)
        /// The read's own timeout expiring with no data, as
        /// `HostSSHControlChannel` reports it.
        case timeout
    }

    private struct WriteWaiter {
        let count: Int
        let continuation: CheckedContinuation<[String], Never>
    }

    private struct State {
        var reads: [ReadResult] = []
        var reader: CheckedContinuation<ReadResult, Never>?
        var writes: [String] = []
        var writtenBytes: [Data] = []
        var writeWaiters: [WriteWaiter] = []
        var closeWaiters: [CheckedContinuation<Void, Never>] = []
        var closeCount = 0
        var timedOutReads = 0
        var exitStatus: Int32?
        var standardError = ""
    }

    static let closedError = TransportError.channelFailed(detail: "fake control channel closed")

    private let state = Mutex(State())

    // MARK: Scripting

    func feed(_ data: Data) {
        enqueue(.data(data))
    }

    func feed(_ text: String) {
        feed(Data(text.utf8))
    }

    /// Each line LF-terminated, in one read.
    func feed(lines: [String]) {
        feed(lines.map { $0 + "\n" }.joined())
    }

    /// `data` split into reads of at most `chunkSize` bytes.
    func feed(_ data: Data, chunkSize: Int) {
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = min(offset + chunkSize, data.endIndex)
            enqueue(.data(Data(data[offset..<end])))
            offset = end
        }
    }

    func finishOutput() {
        enqueue(.eof)
    }

    /// The command ending the way `hc connect` does when it fails: stdout
    /// closes, the exit status and the stderr text become readable.
    func finishCommand(exitStatus: Int32, standardError: String = "") {
        state.withLock { state in
            state.exitStatus = exitStatus
            state.standardError = standardError
        }
        enqueue(.eof)
    }

    func failRead(_ error: TransportError) {
        enqueue(.failure(error))
    }

    func timeOutReads(_ count: Int) {
        for _ in 0..<count { enqueue(.timeout) }
    }

    private func enqueue(_ result: ReadResult) {
        let reader: CheckedContinuation<ReadResult, Never>? = state.withLock { state in
            if let reader = state.reader {
                state.reader = nil
                return reader
            }
            state.reads.append(result)
            return nil
        }
        reader?.resume(returning: result)
    }

    // MARK: Observation

    var writtenLines: [String] {
        state.withLock { $0.writes }
    }

    /// Each `write` call's exact bytes, in order (`writtenLines` decodes them
    /// as UTF-8, which is lossy for binary frames).
    var writtenData: [Data] {
        state.withLock { $0.writtenBytes }
    }

    var closeCount: Int {
        state.withLock { $0.closeCount }
    }

    var isClosed: Bool {
        closeCount > 0
    }

    /// Read timeouts already reported to the reader.
    var timedOutReads: Int {
        state.withLock { $0.timedOutReads }
    }

    /// Waits until at least `count` lines were written; returns them all.
    func waitForWrites(_ count: Int) async -> [String] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[String], Never>) in
            let ready: [String]? = state.withLock { state in
                if state.writes.count >= count { return state.writes }
                state.writeWaiters.append(WriteWaiter(count: count, continuation: continuation))
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    func waitUntilClosed() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let closed: Bool = state.withLock { state in
                if state.closeCount > 0 { return true }
                state.closeWaiters.append(continuation)
                return false
            }
            if closed { continuation.resume() }
        }
    }

    // MARK: HostControlChannel

    func write(_ data: Data, timeout: Duration) async throws {
        let line = String(decoding: data, as: UTF8.self)
        let outcome: (closed: Bool, ready: [(CheckedContinuation<[String], Never>, [String])]) =
            state.withLock { state in
                guard state.closeCount == 0 else { return (true, []) }
                state.writes.append(line)
                state.writtenBytes.append(data)
                let writes = state.writes
                var ready: [(CheckedContinuation<[String], Never>, [String])] = []
                state.writeWaiters.removeAll { waiter in
                    guard writes.count >= waiter.count else { return false }
                    ready.append((waiter.continuation, writes))
                    return true
                }
                return (false, ready)
            }
        if outcome.closed { throw Self.closedError }
        for (continuation, writes) in outcome.ready {
            continuation.resume(returning: writes)
        }
    }

    func read(maximumBytes: Int, timeout: Duration) async throws -> Data? {
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<ReadResult, Never>) in
            let ready: ReadResult? = state.withLock { state in
                if state.closeCount > 0 { return .failure(Self.closedError) }
                if !state.reads.isEmpty { return state.reads.removeFirst() }
                state.reader = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
        switch result {
        case .data(let data):
            return data
        case .eof:
            return nil
        case .failure(let error):
            throw error
        case .timeout:
            state.withLock { $0.timedOutReads += 1 }
            throw TransportError.timedOut
        }
    }

    func exitStatus(timeout: Duration) async throws -> Int32 {
        guard let status = state.withLock({ $0.exitStatus }) else { throw TransportError.timedOut }
        return status
    }

    func standardErrorTail() async -> String {
        state.withLock { $0.standardError }
    }

    func close() async {
        let waiters: (reader: CheckedContinuation<ReadResult, Never>?, closed: [CheckedContinuation<Void, Never>]) =
            state.withLock { state in
                state.closeCount += 1
                let reader = state.reader
                state.reader = nil
                let closed = state.closeWaiters
                state.closeWaiters = []
                return (reader, closed)
            }
        waiters.reader?.resume(returning: .failure(Self.closedError))
        for waiter in waiters.closed { waiter.resume() }
    }
}
