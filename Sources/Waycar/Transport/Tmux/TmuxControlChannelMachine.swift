import Foundation

/// One `tmux -C attach` client's startup, end and pending lines
/// (``TmuxControlChannel``, design §4.3).
///
/// Startup: the underlying channel opens, the reader and writer start, and
/// the attach command's own reply (flags 0) opens the client; an error
/// reply, the request timeout or cancellation ends it. `close()` while it
/// opens ends it too, and what opened is closed.
///
/// Pending lines are matched first in, first out, since tmux answers in
/// send order and its command numbers are server-global (T2); a failing
/// command ends its line, so an error reply completes it early. A line
/// cancelled while queued is withdrawn and never written; one the writer
/// took keeps its place with no caller, so its replies are read and
/// dropped. Once replies can no longer be attributed (a line timed out, a
/// write failed) the client ends and every pending line fails. A `%exit`
/// makes the next EOF or read error an orderly exit. The client never
/// re-sends a line (ADR 0018).
struct TmuxControlChannelMachine: StateMachine {
    enum Phase: Equatable, Sendable {
        case idle
        /// `start()` opens the underlying channel.
        case opening
        /// The reader and writer run; the attach command's reply is awaited.
        case attaching
        case open
        case ended(TmuxControlEnd)
    }

    /// One control line awaiting its replies.
    struct Line: Equatable, Sendable {
        let id: UInt64
        let expectedReplies: Int
        var replies: [TmuxReply] = []
        /// The writer took the line, so tmux may answer it.
        var written = false
        /// The caller cancelled after it was written: the replies are dropped.
        var callerGone = false
    }

    struct State: Equatable, Sendable {
        var phase: Phase = .idle
        /// In send order.
        var pending: [Line] = []
        /// `%exit` arrived; `exitReason` is its text.
        var exitSeen = false
        var exitReason: String?
    }

    /// What a failure fails its waiters with, when not what its end maps to.
    enum Failure: Equatable, Sendable {
        case timedOut
        case cancelled
        /// The attach command's error reply, its text.
        case attachRefused(String)
    }

    enum Event: Equatable, Sendable {
        /// `start()`; `cancelled` when its task already is.
        case start(cancelled: Bool)
        case opened
        /// Opening failed, described.
        case openFailed(String)
        /// The start timer fired, or the start was cancelled, while attaching.
        case startInterrupted(TmuxControlEnd, Failure)
        /// A line of `expectedReplies` commands is queued for writing.
        case lineQueued(expectedReplies: Int)
        /// The writer is about to write line `id`.
        case lineTaken(UInt64)
        case reply(TmuxReply)
        case exitNotified(reason: String?)
        case lineCancelled(UInt64)
        case lineTimedOut(UInt64)
        /// The reader ended: EOF (nil) or a read error, described.
        case readerStopped(error: String?)
        case writeFailed(timedOut: Bool, detail: String)
        case close
    }

    enum Effect: Equatable, Sendable {
        /// Fail the caller of `start()` or `send` with this.
        case refuse(TransportError)
        /// Keep what opened; start the reader and writer.
        case startIO
        /// The attach reply came: resume `start()`.
        case resumeStart
        /// Queue line `id` for the writer.
        case enqueue(UInt64)
        /// Write line `id`.
        case write(UInt64)
        /// Line `id` is answered.
        case complete(UInt64, [TmuxReply])
        /// Fail line `id`'s caller as cancelled.
        case releaseCaller(UInt64)
        case cancelTimer(UInt64)
        /// End the client: fail `start()` and the pending lines (`lines`, in
        /// send order) with `failure`, or what `end` maps to; finish the
        /// writer, reader and events.
        case finish(TmuxControlEnd, Failure?, lines: [UInt64])
        /// Close the underlying channel.
        case closeChannel
    }

    static let alreadyStarted = TransportError.channelFailed(
        detail: "the tmux control channel was already started")
    static let notOpen = TransportError.channelFailed(detail: "the tmux control channel is not open")

    private(set) var state = State()
    private var lastLineID: UInt64 = 0

    init() {}

    var isOpen: Bool { state.phase == .open }

    /// How the client ended; nil while it has not.
    var end: TmuxControlEnd? {
        guard case .ended(let end) = state.phase else { return nil }
        return end
    }

    /// Why a `send` cannot go now; nil while open.
    var sendRefusal: TransportError? {
        switch state.phase {
        case .open: nil
        case .ended(let end): Self.error(for: end)
        case .idle, .opening, .attaching: Self.notOpen
        }
    }

    /// What waiters fail with when the client ends with `end`.
    static func error(for end: TmuxControlEnd) -> TransportError {
        switch end {
        case .exited(let reason):
            let suffix = reason.map { ": \($0)" } ?? ""
            return .channelFailed(detail: "tmux control mode exited\(suffix)")
        case .lost(let detail):
            return .channelFailed(detail: "tmux control channel lost: \(detail)")
        case .closed:
            return .cancelled
        }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state.phase, event) {
        // Startup.
        case (.idle, .start(let cancelled)):
            guard !cancelled else { return finish(.lost("cancelled")) + [.refuse(.cancelled)] }
            state.phase = .opening
            return []
        case (.opening, .start), (.attaching, .start), (.open, .start), (.ended, .start):
            return [.refuse(Self.alreadyStarted)]

        case (.opening, .opened):
            state.phase = .attaching
            return [.startIO]
        case (.ended(let end), .opened):
            // `close()` ran while the channel was opening.
            return [.refuse(Self.error(for: end))]
        case (.idle, .opened), (.attaching, .opened), (.open, .opened):
            return []

        case (.opening, .openFailed(let detail)):
            return finish(.lost(detail))
        case (.idle, .openFailed), (.attaching, .openFailed), (.open, .openFailed),
            (.ended, .openFailed):
            return []

        case (.attaching, .startInterrupted(let end, let failure)):
            return finish(end, failure: failure) + [.closeChannel]
        case (.idle, .startInterrupted), (.opening, .startInterrupted), (.open, .startInterrupted),
            (.ended, .startInterrupted):
            return []

        // Lines.
        case (.open, .lineQueued(let expectedReplies)):
            lastLineID += 1
            state.pending.append(Line(id: lastLineID, expectedReplies: expectedReplies))
            return [.enqueue(lastLineID)]
        case (.idle, .lineQueued), (.opening, .lineQueued), (.attaching, .lineQueued),
            (.ended, .lineQueued):
            return []

        case (_, .lineTaken(let id)):
            // A line withdrawn, or one the end failed, is never written.
            guard let index = state.pending.firstIndex(where: { $0.id == id }) else { return [] }
            state.pending[index].written = true
            return [.write(id)]

        case (.attaching, .reply(let reply)):
            guard reply.flags == 0 else { return [] }
            guard !reply.isError else {
                let text = reply.lines.joined(separator: "\n")
                return finish(.lost("tmux attach failed: \(text)"), failure: .attachRefused(text))
                    + [.closeChannel]
            }
            state.phase = .open
            return [.resumeStart]
        case (.open, .reply(let reply)):
            // Flags 0 is the attach command's own block; nothing pending
            // means nothing to attribute the reply to.
            guard reply.flags != 0, !state.pending.isEmpty else { return [] }
            state.pending[0].replies.append(reply)
            let line = state.pending[0]
            guard reply.isError || line.replies.count >= line.expectedReplies else { return [] }
            state.pending.removeFirst()
            return [.cancelTimer(line.id), .complete(line.id, line.replies)]
        case (.idle, .reply), (.opening, .reply), (.ended, .reply):
            return []

        case (.ended, .exitNotified):
            return []
        case (_, .exitNotified(let reason)):
            state.exitSeen = true
            state.exitReason = reason
            return []

        case (.ended, .lineCancelled):
            return []
        case (_, .lineCancelled(let id)):
            guard let index = state.pending.firstIndex(where: { $0.id == id }),
                !state.pending[index].callerGone
            else { return [] }
            guard state.pending[index].written else {
                state.pending.remove(at: index)
                return [.cancelTimer(id), .releaseCaller(id)]
            }
            state.pending[index].callerGone = true
            return [.releaseCaller(id)]

        case (.ended, .lineTimedOut):
            return []
        case (_, .lineTimedOut(let id)):
            guard state.pending.contains(where: { $0.id == id }) else { return [] }
            return finish(.lost("timed out"), failure: .timedOut) + [.closeChannel]

        // The end.
        case (.ended, .readerStopped):
            return []
        case (_, .readerStopped(let error)):
            let end: TmuxControlEnd =
                state.exitSeen
                ? .exited(reason: state.exitReason)
                : .lost(error ?? "tmux closed the control channel")
            return finish(end) + [.closeChannel]

        case (.ended, .writeFailed):
            return []
        case (_, .writeFailed(let timedOut, let detail)):
            guard timedOut else { return finish(.lost(detail)) + [.closeChannel] }
            return finish(.lost("timed out"), failure: .timedOut) + [.closeChannel]

        case (.ended, .close):
            return [.closeChannel]
        case (_, .close):
            return finish(.closed) + [.closeChannel]
        }
    }

    /// Ends the client: every pending line goes with it.
    private mutating func finish(_ end: TmuxControlEnd, failure: Failure? = nil) -> [Effect] {
        let lines = state.pending.map(\.id)
        state.phase = .ended(end)
        state.pending = []
        return [.finish(end, failure, lines: lines)]
    }
}
