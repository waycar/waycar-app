import Foundation

/// The output side of one PTY Attach (`WaycarSSHAttachOutputGate`): what
/// the pumps yielded and the one consumer has not read, how the output
/// ends, and which task consumes it.
///
/// A clean or failed finish still drains every accepted chunk before the
/// consumer sees the end (or the failure). An explicit end, or the
/// consumer's own task being cancelled, discards what is buffered and ends
/// delivery at once; later output is dropped. The first task to read claims
/// the stream; reads from any other task are refused and leave the claimant
/// alone, and only the claimant (or a first reader still racing its claim)
/// may end delivery by being cancelled (#137, #153, #164). Readers are
/// identified by the owner's hash of their task.
struct AttachOutputMachine: StateMachine {
    /// Accepted chunks not yet read, in order.
    struct Buffer: Equatable, Sendable {
        var chunks: [Data] = []
        var index = 0

        var isEmpty: Bool { index == chunks.count }

        mutating func append(_ bytes: Data) { chunks.append(bytes) }

        mutating func next() -> Data {
            let bytes = chunks[index]
            index += 1
            if index == chunks.count {
                chunks.removeAll(keepingCapacity: true)
                index = 0
            }
            return bytes
        }
    }

    enum Delivery: Equatable, Sendable {
        /// Output flows; `waiting` when the consumer is parked, which only
        /// happens with nothing buffered.
        case open(Buffer, waiting: Bool)
        /// The pumps finished (`failed`: with an error); what is buffered
        /// drains, then every read ends or fails.
        case finishing(Buffer, failed: Bool)
        /// Ended explicitly or by the consumer's cancellation: every read
        /// ends, nothing more is accepted.
        case ended
    }

    struct State: Equatable, Sendable {
        var delivery: Delivery = .open(Buffer(), waiting: false)
        /// The task that read first.
        var consumer: Int?
    }

    enum Event: Equatable, Sendable {
        case read(reader: Int)
        case yield(Data)
        /// The pumps ended, with a failure the owner holds when `failed`.
        case finish(failed: Bool)
        case beginExplicitEnd
        /// `reader`'s task was cancelled around its read.
        case consumerCancelled(reader: Int)
    }

    enum Answer: Equatable, Sendable {
        case bytes(Data)
        case end
        /// The finish's failure.
        case failure
        /// `TransportError.terminalChannelAlreadyOpen`.
        case alreadyClaimed
    }

    enum Effect: Equatable, Sendable {
        /// Answer the read in progress.
        case answer(Answer)
        /// Park the read in progress until the next chunk or the end.
        case park
        /// Answer the parked consumer.
        case resumeWaiter(Answer)
        /// Hold on to the failure the first finish brought.
        case keepFailure
    }

    private(set) var state = State()

    init() {}

    var hasParkedConsumer: Bool {
        if case .open(_, waiting: true) = state.delivery { return true }
        return false
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state.delivery, event) {
        case (_, .read(let reader)):
            // A buffered read completes at once, so the claim persists across
            // reads and is checked before every branch.
            guard state.consumer == nil || state.consumer == reader else {
                return [.answer(.alreadyClaimed)]
            }
            state.consumer = reader
            return read()

        case (.open(var buffer, let waiting), .yield(let bytes)):
            if waiting {
                state.delivery = .open(buffer, waiting: false)
                return [.resumeWaiter(.bytes(bytes))]
            }
            buffer.append(bytes)
            state.delivery = .open(buffer, waiting: false)
            return []
        case (.finishing, .yield), (.ended, .yield):
            return []

        case (.open(let buffer, let waiting), .finish(let failed)):
            state.delivery = .finishing(buffer, failed: failed)
            let keep: [Effect] = failed ? [.keepFailure] : []
            guard waiting else { return keep }
            return keep + [.resumeWaiter(failed ? .failure : .end)]
        case (.finishing, .finish), (.ended, .finish):
            return []

        case (.open(_, let waiting), .beginExplicitEnd):
            state.delivery = .ended
            return waiting ? [.resumeWaiter(.end)] : []
        case (.finishing, .beginExplicitEnd):
            state.delivery = .ended
            return []
        case (.ended, .beginExplicitEnd):
            return []

        case (.open(_, let waiting), .consumerCancelled(let reader)):
            guard state.consumer == nil || state.consumer == reader else { return [] }
            state.delivery = .ended
            return waiting ? [.resumeWaiter(.end)] : []
        case (.finishing, .consumerCancelled(let reader)):
            guard state.consumer == nil || state.consumer == reader else { return [] }
            state.delivery = .ended
            return []
        case (.ended, .consumerCancelled):
            return []
        }
    }

    /// The claimant's read.
    private mutating func read() -> [Effect] {
        switch state.delivery {
        case .ended:
            return [.answer(.end)]
        case .open(var buffer, _) where !buffer.isEmpty:
            let bytes = buffer.next()
            state.delivery = .open(buffer, waiting: false)
            return [.answer(.bytes(bytes))]
        case .open(let buffer, _):
            state.delivery = .open(buffer, waiting: true)
            return [.park]
        case .finishing(var buffer, let failed):
            guard !buffer.isEmpty else { return [.answer(failed ? .failure : .end)] }
            let bytes = buffer.next()
            state.delivery = .finishing(buffer, failed: failed)
            return [.answer(.bytes(bytes))]
        }
    }
}
