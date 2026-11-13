import Foundation
import Synchronization

@testable import Waycar

/// A `TerminalAttachSession` whose PTY the test drives: it pushes output and
/// ends or kills the channel, and reads what the session sent down it
/// (keystrokes, window changes) the way the channel's input pump would.
final class ScriptedAttachSession: Sendable {
    let session: TerminalAttachSession
    private let output: AsyncThrowingStream<Data, any Error>.Continuation
    private let log: Recorder
    private let pump: Task<Void, Never>

    private final class Recorder: Sendable {
        private struct Log {
            var inputs: [TerminalAttachInput] = []
            var endCalls = 0
        }

        private let log = Mutex(Log())

        var inputs: [TerminalAttachInput] { log.withLock { $0.inputs } }
        var endCalls: Int { log.withLock { $0.endCalls } }
        func record(_ input: TerminalAttachInput) { log.withLock { $0.inputs.append(input) } }
        func recordEnd() { log.withLock { $0.endCalls += 1 } }
    }

    init() {
        let (stream, output) = AsyncThrowingStream<Data, any Error>.makeStream()
        let input = TerminalAttachInputQueue()
        let log = Recorder()
        self.log = log
        self.output = output
        session = TerminalAttachSession(output: { stream }, input: input) {
            log.recordEnd()
            output.finish()
        }
        pump = Task {
            while let item = await input.next() {
                log.record(item)
            }
        }
    }

    deinit { pump.cancel() }

    /// PTY output, as one channel read.
    func emit(_ text: String) {
        output.yield(Data(text.utf8))
    }

    /// The remote attach exits cleanly.
    func exitCleanly() {
        output.finish()
    }

    /// The channel dies.
    func fail(_ error: any Error) {
        output.finish(throwing: error)
    }

    var inputs: [TerminalAttachInput] { log.inputs }
    var endCalls: Int { log.endCalls }

    /// Every window-change the session sent, in order.
    var resizes: [String] {
        inputs.compactMap { input in
            if case .resize(let cols, let rows) = input { "\(cols)x\(rows)" } else { nil }
        }
    }
}
