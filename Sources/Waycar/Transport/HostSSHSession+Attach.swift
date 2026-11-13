import Foundation
import Synchronization
import WaycarSSH

private enum WaycarSSHAttachPumpError: Error, Sendable {
    case input(String)
    case output(String)
    /// Remote process exited nonzero. Distinct from a channel I/O failure so
    /// Attach can map a bare-`herdr` exit 127 onto the PATH problem (#206).
    case remoteExit(Int32)
}

/// The live PTY operations used by the Attach pumps. `SSHPTYChannel` is the
/// production implementation; tests replace it at this boundary.
protocol WaycarSSHAttachChannel: Sendable {
    func write(_ data: Data, timeout: Duration) async throws
    func read(maximumBytes: Int, timeout: Duration) async throws -> Data?
    func resize(columns: Int, rows: Int, timeout: Duration) async throws
    func exitStatus(timeout: Duration) async throws -> Int32
}

extension SSHPTYChannel: WaycarSSHAttachChannel {}

private final class WaycarSSHAttachPumpCancellation: Sendable {
    private let flushWithheld = Mutex(false)

    func requestDiagnosticFlush() {
        flushWithheld.withLock { $0 = true }
    }

    var shouldFlushDiagnostic: Bool {
        flushWithheld.withLock { $0 }
    }
}

/// Linearizes explicit Attach shutdown with terminal output delivery.
///
/// `AsyncThrowingStream.Continuation.finish()` preserves buffered elements,
/// so a finished stream alone cannot guarantee that `end()` makes later
/// iterator reads return nil. This gate owns the buffer so explicit end can
/// discard it, while clean remote exit still drains every accepted byte.
///
/// The stream has exactly one consumer task. The first task to read claims
/// the stream; reads from another task are refused with
/// `TransportError.terminalChannelAlreadyOpen` and leave the claimant running,
/// whether output is parked or buffered; see `next()`.
final class WaycarSSHAttachOutputGate: Sendable {
    private enum Completion {
        case finished
        case failed(any Error)
    }

    private struct State: ~Copyable {
        var buffered: [Data] = []
        var bufferedIndex = 0
        var waiter: CheckedContinuation<Data?, any Error>?
        var completion: Completion?
        var isExplicitlyEnding = false
        var isConsumerCancelled = false
        var consumer: TaskIdentity?
    }

    /// A stable scalar derived from the task performing a read. The unfolding
    /// stream does not expose iterator identity, and `UnsafeCurrentTask` is
    /// explicitly non-Sendable, so the gate retains only its hash value.
    private struct TaskIdentity: Equatable {
        private let value: Int

        static var current: TaskIdentity {
            withUnsafeCurrentTask { task in
                TaskIdentity(value: task?.hashValue ?? 0)
            }
        }
    }

    private let state = Mutex(State())

    #if DEBUG
        /// Whether a consumer is parked waiting for the next chunk. Lets
        /// tests enter the double-consumer window deterministically instead
        /// of guessing at it with a sleep.
        var hasParkedConsumerForTesting: Bool {
            state.withLock { $0.waiter != nil }
        }
    #endif

    static func makeStream() -> (
        output: AsyncThrowingStream<Data, any Error>,
        gate: WaycarSSHAttachOutputGate
    ) {
        let gate = WaycarSSHAttachOutputGate()
        return (gate.makeOutput(), gate)
    }

    /// One stream view over this gate. The gate owns all buffering and the
    /// consumer claim, so views are stateless and interchangeable for the
    /// claimant — but they are not shareable across readers: an unfolding
    /// stream instance keeps one produce storage for all its iterators, and
    /// the standard library clears it from a cancellation handler that runs
    /// before `next()` is ever invoked when the reading task is already
    /// cancelled. Hand each potential reader its own view (#164).
    func makeOutput() -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { try await self.next() }
    }

    func beginExplicitEnd() {
        state.withLock { state in
            guard !state.isExplicitlyEnding else { return }
            state.isExplicitlyEnding = true
            state.buffered.removeAll(keepingCapacity: false)
            state.bufferedIndex = 0
            state.waiter?.resume(returning: nil)
            state.waiter = nil
        }
    }

    func yield(_ bytes: Data) {
        state.withLock { state in
            guard
                !state.isExplicitlyEnding,
                !state.isConsumerCancelled,
                state.completion == nil
            else { return }
            if let waiting = state.waiter {
                state.waiter = nil
                waiting.resume(returning: bytes)
            } else {
                state.buffered.append(bytes)
            }
        }
    }

    func finish(throwing failure: (any Error)? = nil) {
        state.withLock { state in
            guard state.completion == nil else { return }
            state.completion = failure.map(Completion.failed) ?? .finished
            guard
                state.bufferedIndex == state.buffered.count,
                let waiter = state.waiter
            else { return }
            state.waiter = nil
            if let failure {
                waiter.resume(throwing: failure)
            } else {
                waiter.resume(returning: nil)
            }
        }
    }

    private func next() async throws -> Data? {
        let reader = TaskIdentity.current
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.withLock { state in
                    // A parked waiter only identifies overlapping reads. A
                    // buffered read completes synchronously, so the claim
                    // must persist across calls and be checked before every
                    // branch. The first task to read owns the stream (#153).
                    guard state.consumer == nil || state.consumer == reader else {
                        continuation.resume(
                            throwing: TransportError.terminalChannelAlreadyOpen)
                        return
                    }
                    state.consumer = reader
                    if state.isExplicitlyEnding || state.isConsumerCancelled {
                        continuation.resume(returning: nil)
                        return
                    }
                    if state.bufferedIndex < state.buffered.count {
                        let bytes = state.buffered[state.bufferedIndex]
                        state.bufferedIndex += 1
                        if state.bufferedIndex == state.buffered.count {
                            state.buffered.removeAll(keepingCapacity: true)
                            state.bufferedIndex = 0
                        }
                        continuation.resume(returning: bytes)
                        return
                    }
                    if let completion = state.completion {
                        switch completion {
                        case .finished:
                            continuation.resume(returning: nil)
                        case .failed(let failure):
                            continuation.resume(throwing: failure)
                        }
                        return
                    }
                    // Throwing at the extra consumer is load-bearing: an
                    // unfolding stream shares storage across iterators, and
                    // returning nil here would end the legitimate consumer's
                    // stream too (#137).
                    state.waiter = continuation
                }
            }
        } onCancel: {
            cancelConsumer(reader)
        }
    }

    /// Ends delivery because a consumer's task was cancelled.
    ///
    /// The cancellation handler is installed by every reader before the
    /// claim check in `next()` can refuse it, and it can fire at any point
    /// after installation. Without the ownership guard, a refused second
    /// consumer whose task is cancelled around its read would clear the
    /// buffer and resume the claimant's waiter with nil — silently ending a
    /// terminal it never owned (#164). Only the claimant, or a first reader
    /// still racing its own claim, may cancel delivery.
    private func cancelConsumer(_ reader: TaskIdentity) {
        state.withLock { state in
            guard state.consumer == nil || state.consumer == reader else { return }
            guard !state.isConsumerCancelled else { return }
            state.isConsumerCancelled = true
            state.buffered.removeAll(keepingCapacity: false)
            state.bufferedIndex = 0
            state.waiter?.resume(returning: nil)
            state.waiter = nil
        }
    }
}

// The generic PTY Attach: one reserved `.attach` channel per call, its
// output gate, input queue, pumps, resize and exit status. The command is the
// backend's; it prints the bootstrap marker right before its `exec`.
extension HostSSHSession {
    func attachTerminal(
        command: String, request: TerminalAttachRequest
    ) async throws -> TerminalAttachSession {
        try await attachTerminal(
            command: command, request: request, exitCommand: command, onChannelEnded: {})
    }

    /// Opens the PTY Attach `command` runs on. A nonzero remote exit maps
    /// through `attachChannelFailure` against `exitCommand`, the attach
    /// command word the backend exec's, so a bare `herdr` exiting 127 reads
    /// as the PATH problem. `onChannelEnded` runs once the channel is closed
    /// and its lease returned, before the output stream finishes.
    func attachTerminal(
        command: String,
        request: TerminalAttachRequest,
        exitCommand: String,
        onChannelEnded: @escaping @Sendable () async -> Void
    ) async throws -> TerminalAttachSession {
        let lease = try await channelAdmission.acquire(.attach)
        let channel: SSHPTYChannel
        do {
            channel = try await connection.openPTY(
                command: command,
                columns: request.cols,
                rows: request.rows,
                timeout: requestTimeout)
        } catch {
            await lease.release()
            throw mapOperationError(error)
        }

        let outputGate = WaycarSSHAttachOutputGate()
        let input = TerminalAttachInputQueue()
        let readerTask = Task {
            await self.runAttachChannel(
                channel: channel,
                admissionLease: lease,
                input: input,
                output: outputGate,
                exitCommand: exitCommand,
                onChannelEnded: onChannelEnded)
        }
        return TerminalAttachSession(
            output: outputGate.makeOutput,
            input: input,
            onEndStarted: outputGate.beginExplicitEnd
        ) {
            input.finish()
            readerTask.cancel()
            await readerTask.value
        }
    }

    /// How the `channelFailed` details of an attach channel's own I/O
    /// failures begin. Other `channelFailed` errors (a mosh bootstrap, tmux)
    /// are not this channel dying.
    static let attachChannelDetailPrefix = "attach channel:"
    static let attachInputDetailPrefix = "attach input:"
    /// How an attach channel failure caused by the remote command's own exit
    /// status begins: the Host answered and refused, so unlike an I/O failure
    /// a retry would only hear the same exit.
    static let attachRemoteExitDetailPrefix = "\(attachChannelDetailPrefix) remote exit status"

    /// Maps a remote attach exit onto the Transport taxonomy. Exit 127 is
    /// `herdrBinaryNotFound` only when the exec'd command is still a bare
    /// `herdr` word; injectable scripts keep the generic channel failure.
    static func attachChannelFailure(
        exitStatus: Int32, attachCommand: String
    ) -> TransportError {
        HerdrHostPath.missingBinaryError(exitStatus: exitStatus, command: attachCommand)
            ?? .channelFailed(detail: "\(attachRemoteExitDetailPrefix) \(exitStatus)")
    }

    private func runAttachChannel(
        channel: SSHPTYChannel,
        admissionLease: SSHChannelAdmissionLease,
        input: TerminalAttachInputQueue,
        output: WaycarSSHAttachOutputGate,
        exitCommand: String,
        onChannelEnded: @Sendable () async -> Void
    ) async {
        var failure: TransportError?
        var sawCleanEnd = false
        var pumpFailure: WaycarSSHAttachPumpError?

        do {
            do {
                sawCleanEnd = try await Self.runAttachPumps(
                    channel: channel,
                    input: input,
                    output: output,
                    requestTimeout: requestTimeout)
            } catch let error as WaycarSSHAttachPumpError {
                pumpFailure = error
                throw error
            }
            failure = nil
        } catch is CancellationError {
            failure = nil
        } catch {
            if Task.isCancelled || sawCleanEnd {
                failure = nil
            } else {
                switch pumpFailure {
                case .input(let detail):
                    failure = .channelFailed(detail: "\(Self.attachInputDetailPrefix) \(detail)")
                case .output(let detail):
                    failure = .channelFailed(detail: "\(Self.attachChannelDetailPrefix) \(detail)")
                case .remoteExit(let status):
                    failure = Self.attachChannelFailure(
                        exitStatus: status, attachCommand: exitCommand)
                case nil:
                    failure = .channelFailed(detail: "\(Self.attachChannelDetailPrefix) \(error)")
                }
            }
        }

        do {
            try await channel.close(timeout: .seconds(2))
        } catch {
            let cleanupFailure = mapOperationError(error)
            if failure == nil, !Task.isCancelled, !sawCleanEnd {
                failure = cleanupFailure
            }
        }
        await admissionLease.release()

        input.finish()
        await onChannelEnded()
        if let failure {
            output.finish(throwing: failure)
        } else {
            output.finish()
        }
    }

    /// Runs the same input and output pumps used by `runAttachChannel`, while
    /// leaving connection teardown and actor state to its caller.
    static func runAttachPumps(
        channel: any WaycarSSHAttachChannel,
        input: TerminalAttachInputQueue,
        output: WaycarSSHAttachOutputGate,
        requestTimeout: Duration
    ) async throws -> Bool {
        let cancellation = WaycarSSHAttachPumpCancellation()
        return try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    try await input.pump(
                        write: { data in
                            try await channel.write(data, timeout: requestTimeout)
                        },
                        resize: { columns, rows in
                            try await channel.resize(
                                columns: columns,
                                rows: rows,
                                timeout: requestTimeout)
                        })
                    return false
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    guard !Task.isCancelled else { throw CancellationError() }
                    cancellation.requestDiagnosticFlush()
                    throw WaycarSSHAttachPumpError.input(String(describing: error))
                }
            }
            group.addTask {
                // Remote startup chatter stays off the terminal until the
                // attach exec prints the bootstrap marker.
                var gate = AttachBootstrapGate()
                func yieldAdmitted(_ bytes: Data) {
                    guard !bytes.isEmpty else { return }
                    output.yield(bytes)
                }
                do {
                    while !Task.isCancelled {
                        let bytes: Data?
                        do {
                            bytes = try await channel.read(
                                maximumBytes: 16 * 1024,
                                timeout: .seconds(1))
                        } catch SSHError.timedOut {
                            continue
                        }
                        guard let bytes else {
                            let status = try await channel.exitStatus(timeout: requestTimeout)
                            guard status == 0 else {
                                yieldAdmitted(gate.flush())
                                throw WaycarSSHAttachPumpError.remoteExit(status)
                            }
                            yieldAdmitted(gate.flush())
                            return true
                        }
                        yieldAdmitted(gate.admit(bytes))
                    }
                    throw CancellationError()
                } catch is CancellationError {
                    // A sibling input failure requests one diagnostic flush;
                    // explicit cancellation leaves the request false.
                    if cancellation.shouldFlushDiagnostic {
                        yieldAdmitted(gate.flush())
                    }
                    throw CancellationError()
                } catch let error as WaycarSSHAttachPumpError {
                    throw error
                } catch {
                    yieldAdmitted(gate.flush())
                    throw WaycarSSHAttachPumpError.output(String(describing: error))
                }
            }
            defer {
                input.finish()
                group.cancelAll()
            }
            return try await group.next() ?? true
        }
    }
}
