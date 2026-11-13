import Foundation
import Synchronization

/// What `TmuxControlChannel.events` delivers: every notification, in arrival
/// order, then exactly one `.ended`.
enum TmuxControlEvent: Sendable, Equatable {
    case notification(TmuxNotification)
    case ended(TmuxControlEnd)
}

/// Why a control channel ended.
enum TmuxControlEnd: Sendable, Equatable {
    /// tmux sent `%exit` and then closed stdout; `reason` is its text.
    case exited(reason: String?)
    /// stdout ended, or reading failed, without `%exit`; a request timed out
    /// or could not be written; or `start()` was cancelled.
    case lost(String)
    /// `close()` ended it.
    case closed
}

/// One `tmux -C attach` client over a `HostControlChannel` (design §4.3).
///
/// The actor is the single writer: each `send` is one control line, queued
/// to one writer task in call order, and a FIFO of pending lines matches the
/// replies one reader task parses, since tmux answers in send order and its
/// command numbers are server-global (T2). A failing command ends its line:
/// tmux sends that `%error` block and nothing for the rest, so an error reply
/// completes its line early.
///
/// The channel never re-sends a line (ADR 0018): TmuxTransport decides which
/// commands an `%exit` left unanswered go out again on its replacement. A
/// cancelled `send` returns at once. A line still queued is withdrawn and
/// never written; one the writer has taken keeps its place in the FIFO with
/// no caller, so its replies are read and dropped and later lines still get
/// their own. Once a line's replies can no longer be attributed (timeout,
/// write failure), the channel ends, and every pending and later `send`
/// fails.
actor TmuxControlChannel {
    /// Everything that is not a reply, in arrival order, ending with
    /// `.ended`. Unbounded: nothing is dropped, but while the consumer lags
    /// a `%subscription-changed` replaces the queued one with the same name
    /// when only other subscription changes lie between them.
    nonisolated let events: AsyncStream<TmuxControlEvent>

    /// How long one read waits for stdout before trying again. An idle
    /// control client may say nothing for minutes; a read timing out is not
    /// an error.
    private static let readTimeout: Duration = .seconds(300)
    private static let readChunkBytes = 64 * 1_024

    private let requestTimeout: Duration
    private let open: @Sendable () async throws -> any HostControlChannel
    private let eventQueue: TmuxControlEventQueue

    private struct OutgoingLine: Sendable {
        let id: UInt64
        let data: Data
    }

    /// Startup, end and the pending lines (``TmuxControlChannelMachine``).
    private var machine = TmuxControlChannelMachine()
    private var channel: (any HostControlChannel)?
    private var startWaiter: CheckedContinuation<Void, any Error>?
    private var startTimer: Task<Void, Never>?
    private var reader: Task<Void, Never>?
    private var writer: Task<Void, Never>?
    private var outbox: AsyncStream<OutgoingLine>.Continuation?
    /// Each pending line's caller (none once it cancelled) and timer, by id.
    private var callers: [UInt64: CheckedContinuation<[TmuxReply], any Error>] = [:]
    private var timers: [UInt64: Task<Void, Never>] = [:]

    init(
        requestTimeout: Duration,
        open: @escaping @Sendable () async throws -> any HostControlChannel
    ) {
        self.requestTimeout = requestTimeout
        self.open = open
        let queue = TmuxControlEventQueue()
        eventQueue = queue
        events = AsyncStream(unfolding: { await queue.next() })
    }

    deinit {
        reader?.cancel()
        writer?.cancel()
        startTimer?.cancel()
        outbox?.finish()
        eventQueue.finish(.closed)
        if let channel {
            Task { await channel.close() }
        }
    }

    var isOpen: Bool { machine.isOpen }

    /// How the channel ended; nil while it has not.
    var end: TmuxControlEnd? { machine.end }

#if DEBUG
    /// Lines awaiting replies, including cancelled written ones.
    var pendingLineCountForTesting: Int { machine.state.pending.count }
#endif

    /// Opens the channel, starts the reader, and waits for the attach
    /// command's own reply (flags 0). An error reply throws
    /// `TmuxErrors.error(<its text>)` (e.g. `no sessions`, `can't find
    /// session`); `%config-error` lines are ignored. Times out after
    /// `requestTimeout`. A failed start ends the channel.
    func start() async throws {
        let starting = machine.handle(.start(cancelled: Task.isCancelled))
        await perform(starting)
        if let refusal = Self.refusal(in: starting) { throw refusal }
        let opened: any HostControlChannel
        do {
            opened = try await open()
        } catch {
            await perform(machine.handle(.openFailed(Self.describe(error))))
            throw error
        }
        let started = machine.handle(.opened)
        if let refusal = Self.refusal(in: started) {
            // `close()` ran while the channel was opening.
            await opened.close()
            throw refusal
        }
        channel = opened
        startWriter(opened)
        startReader(opened)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                startWaiter = continuation
                startTimer = Task { [weak self, requestTimeout] in
                    do { try await Task.sleep(for: requestTimeout) } catch { return }
                    await self?.startInterrupted(.lost("timed out"), failure: .timedOut)
                }
            }
        } onCancel: {
            Task { await self.startInterrupted(.lost("cancelled"), failure: .cancelled) }
        }
    }

    /// Writes one control line (`commands` joined with " ; ", plus "\n") and
    /// returns the replies tmux sent for it, in order. Each element must be
    /// exactly one command. A failing command ends the line: its error reply
    /// is the last element and the remaining commands have none. Times out
    /// after `requestTimeout`. Cancellation throws
    /// `TransportError.cancelled` and leaves the channel open: a queued line
    /// is withdrawn, a written one's replies are still consumed, and dropped.
    func send(_ commands: [String]) async throws -> [TmuxReply] {
        guard !commands.isEmpty else { return [] }
        if Task.isCancelled { throw TransportError.cancelled }
        if let refusal = machine.sendRefusal { throw refusal }
        guard let outbox else { throw TmuxControlChannelMachine.notOpen }
        var queued: UInt64?
        for case .enqueue(let id) in machine.handle(.lineQueued(expectedReplies: commands.count)) {
            queued = id
        }
        guard let id = queued else { throw TmuxControlChannelMachine.notOpen }
        let line = Data((commands.joined(separator: " ; ") + "\n").utf8)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<[TmuxReply], any Error>) in
                timers[id] = Task { [weak self, requestTimeout] in
                    do { try await Task.sleep(for: requestTimeout) } catch { return }
                    await self?.lineTimedOut(id)
                }
                callers[id] = continuation
                outbox.yield(OutgoingLine(id: id, data: line))
            }
        } onCancel: {
            Task { await self.lineCancelled(id) }
        }
    }

    /// Ends the channel (`.closed`): pending and later sends fail with
    /// `TransportError.cancelled`. Idempotent.
    func close() async {
        await perform(machine.handle(.close))
    }

    // MARK: Reader and writer

    private func startReader(_ channel: any HostControlChannel) {
        reader = Task { [weak self] in
            var parser = TmuxControlParser()
            while !Task.isCancelled {
                let chunk: Data?
                do {
                    chunk = try await channel.read(
                        maximumBytes: Self.readChunkBytes,
                        timeout: Self.readTimeout)
                } catch TransportError.timedOut {
                    continue
                } catch {
                    await self?.readerStopped(error)
                    return
                }
                guard let chunk else {
                    await self?.readerStopped(nil)
                    return
                }
                let messages = parser.feed(chunk)
                guard !messages.isEmpty else { continue }
                guard let self, await self.receive(messages) else { return }
            }
        }
    }

    private func startWriter(_ channel: any HostControlChannel) {
        let (lines, outbox) = AsyncStream<OutgoingLine>.makeStream()
        self.outbox = outbox
        writer = Task { [weak self, requestTimeout] in
            for await line in lines {
                // A line cancelled while queued is never written.
                guard let isPending = await self?.takeForWriting(line.id) else { return }
                guard isPending else { continue }
                do {
                    try await channel.write(line.data, timeout: requestTimeout)
                } catch {
                    await self?.writeFailed(error)
                    return
                }
            }
        }
    }

    /// Marks line `id` written, right before the writer writes it; false
    /// when it is no longer pending (withdrawn, or the channel ended).
    private func takeForWriting(_ id: UInt64) -> Bool {
        machine.handle(.lineTaken(id)).contains(.write(id))
    }

    /// Handles one chunk's messages; false once the channel has ended.
    private func receive(_ messages: [TmuxControlMessage]) async -> Bool {
        for message in messages {
            if machine.end != nil { return false }
            switch message {
            case .notification(let notification):
                if case .exit(let reason) = notification {
                    await perform(machine.handle(.exitNotified(reason: reason)))
                }
                eventQueue.yield(.notification(notification))
            case .reply(let reply):
                await perform(machine.handle(.reply(reply)))
            }
        }
        return machine.end == nil
    }

    private func readerStopped(_ error: (any Error)?) async {
        await perform(machine.handle(.readerStopped(error: error.map(Self.describe))))
    }

    private func writeFailed(_ error: any Error) async {
        await perform(machine.handle(.writeFailed(
            timedOut: error as? TransportError == .timedOut, detail: Self.describe(error))))
    }

    // MARK: Interruptions

    private func startInterrupted(
        _ end: TmuxControlEnd, failure: TmuxControlChannelMachine.Failure
    ) async {
        await perform(machine.handle(.startInterrupted(end, failure)))
    }

    private func lineTimedOut(_ id: UInt64) async {
        await perform(machine.handle(.lineTimedOut(id)))
    }

    /// A queued line is withdrawn: never written, so nothing will answer
    /// it. A written one keeps its place: its replies are consumed in order
    /// and dropped, and its timer still ends the channel if they never
    /// come. Either way only the caller is released.
    private func lineCancelled(_ id: UInt64) async {
        await perform(machine.handle(.lineCancelled(id)))
    }

    // MARK: Effects

    /// The first refusal among `effects`, for the caller to throw.
    private static func refusal(in effects: [TmuxControlChannelMachine.Effect]) -> TransportError? {
        for case .refuse(let error) in effects { return error }
        return nil
    }

    /// Performs the machine's effects in order. A refusal is the caller's
    /// to throw; starting the reader and writer, queueing and writing a
    /// line are the caller's steps too.
    private func perform(_ effects: [TmuxControlChannelMachine.Effect]) async {
        for effect in effects {
            switch effect {
            case .refuse, .startIO, .enqueue, .write:
                break
            case .resumeStart:
                startTimer?.cancel()
                startTimer = nil
                startWaiter?.resume()
                startWaiter = nil
            case .complete(let id, let replies):
                callers.removeValue(forKey: id)?.resume(returning: replies)
            case .releaseCaller(let id):
                callers.removeValue(forKey: id)?.resume(throwing: TransportError.cancelled)
            case .cancelTimer(let id):
                timers.removeValue(forKey: id)?.cancel()
            case .finish(let end, let failure, let lines):
                finish(end, failure: failure, lines: lines)
            case .closeChannel:
                await closeUnderlyingChannel()
            }
        }
    }

    // MARK: Ending

    /// Closes the underlying channel from a fresh task: the caller may be a
    /// cancelled task (the reader, a timer, a cancelled `close()` caller),
    /// and a close cut short by cancellation could leave the SSH channel up.
    private func closeUnderlyingChannel() async {
        guard let channel else { return }
        await Task { await channel.close() }.value
    }

    /// The machine ended the channel: fails every waiter (`start()`, then
    /// `lines` in send order) with `failure`, or the error `end` maps to,
    /// and stops the writer, the reader and the events.
    private func finish(
        _ end: TmuxControlEnd, failure: TmuxControlChannelMachine.Failure?, lines: [UInt64]
    ) {
        let error: any Error
        switch failure {
        case .timedOut: error = TransportError.timedOut
        case .cancelled: error = TransportError.cancelled
        case .attachRefused(let text): error = TmuxErrors.error(text)
        case nil: error = TmuxControlChannelMachine.error(for: end)
        }
        startTimer?.cancel()
        startTimer = nil
        startWaiter?.resume(throwing: error)
        startWaiter = nil
        for id in lines {
            timers.removeValue(forKey: id)?.cancel()
            callers.removeValue(forKey: id)?.resume(throwing: error)
        }
        outbox?.finish()
        outbox = nil
        writer?.cancel()
        writer = nil
        reader?.cancel()
        reader = nil
        eventQueue.finish(end)
    }

    private static func describe(_ error: any Error) -> String {
        String(describing: error)
    }
}

/// `TmuxControlChannel.events`' buffer: unbounded, pulled by the stream's
/// consumer. While the consumer lags, a subscription change replaces the
/// queued change with the same name inside the trailing run of subscription
/// changes; subscriptions are independent snapshots, so only the latest of
/// each matters, and no other notification is reordered.
private final class TmuxControlEventQueue: Sendable {
    private struct State {
        var items: [TmuxControlEvent] = []
        var head = 0
        var finished = false
        var cancelled = false
        /// Set only while `items` has nothing unread.
        var waiter: CheckedContinuation<TmuxControlEvent?, Never>?

        mutating func coalesce(_ change: TmuxSubscriptionChange) -> Bool {
            var index = items.count - 1
            while index >= head {
                guard case .notification(.subscriptionChanged(let queued)) = items[index] else {
                    return false
                }
                if queued.name == change.name {
                    items[index] = .notification(.subscriptionChanged(change))
                    return true
                }
                index -= 1
            }
            return false
        }

        mutating func popFirst() -> TmuxControlEvent? {
            guard head < items.count else { return nil }
            let event = items[head]
            head += 1
            if head == items.count {
                items.removeAll(keepingCapacity: true)
                head = 0
            } else if head >= 64, head * 2 >= items.count {
                items.removeFirst(head)
                head = 0
            }
            return event
        }
    }

    private let state = Mutex(State())

    func yield(_ event: TmuxControlEvent) {
        let waiter: CheckedContinuation<TmuxControlEvent?, Never>? = state.withLock { state in
            guard !state.finished, !state.cancelled else { return nil }
            if let waiter = state.waiter {
                state.waiter = nil
                return waiter
            }
            if case .notification(.subscriptionChanged(let change)) = event, state.coalesce(change) {
                return nil
            }
            state.items.append(event)
            return nil
        }
        waiter?.resume(returning: event)
    }

    /// Queues `.ended(end)` as the last event. Later calls do nothing.
    func finish(_ end: TmuxControlEnd) {
        let event = TmuxControlEvent.ended(end)
        let waiter: CheckedContinuation<TmuxControlEvent?, Never>? = state.withLock { state in
            guard !state.finished else { return nil }
            state.finished = true
            guard !state.cancelled else { return nil }
            if let waiter = state.waiter {
                state.waiter = nil
                return waiter
            }
            state.items.append(event)
            return nil
        }
        waiter?.resume(returning: event)
    }

    func next() async -> TmuxControlEvent? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<TmuxControlEvent?, Never>) in
                let ready: TmuxControlEvent?? = state.withLock { state in
                    if let event = state.popFirst() { return .some(event) }
                    if state.finished || state.cancelled { return .some(nil) }
                    state.waiter = continuation
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        } onCancel: {
            cancel()
        }
    }

    /// The consumer stopped iterating: drop everything from now on.
    private func cancel() {
        let waiter = state.withLock { state in
            state.cancelled = true
            state.items = []
            state.head = 0
            let waiter = state.waiter
            state.waiter = nil
            return waiter
        }
        waiter?.resume(returning: nil)
    }
}
