import Foundation
import Synchronization

/// The remote object one interactive PTY Attach resolves.
///
/// Agent Attach addresses herdr's Agent-facing command with a Pane id. An
/// ordinary shell terminal instead addresses `herdr terminal attach` with the
/// terminal id returned by `tab.create`. Keeping the distinction in the
/// request prevents UI code from selecting remote commands itself.
enum TerminalAttachTarget: Sendable, Hashable {
    case agentPane(String)
    case terminal(String)

    var identifier: String {
        switch self {
        case .agentPane(let identifier), .terminal(let identifier):
            identifier
        }
    }
}

/// One interactive terminal request: its typed remote target, herdr's
/// takeover flag, and the initial PTY geometry.
struct TerminalAttachRequest: Sendable, Equatable {
    let target: TerminalAttachTarget
    let takeover: Bool
    let cols: Int
    let rows: Int

    init(
        target: TerminalAttachTarget,
        takeover: Bool = false,
        cols: Int,
        rows: Int
    ) {
        self.target = target
        self.takeover = takeover
        self.cols = cols
        self.rows = rows
    }

    /// Compatibility spelling for existing Agent Attach callers. New call
    /// sites that can target more than an Agent use the typed initializer.
    init(target: String, takeover: Bool = false, cols: Int, rows: Int) {
        self.init(
            target: .agentPane(target),
            takeover: takeover,
            cols: cols,
            rows: rows)
    }
}

/// The handshake that separates an attach channel's pre-attach noise from
/// the attach session itself.
///
/// OpenSSH still hands every exec request to the remote account shell as
/// `shell -c command`, even when Waycar requests a PTY and an exec together
/// (no interactive login shell, no socat bootstrap). The account shell or SSH
/// session can still emit generic startup or rc chatter before the `printf` of
/// this marker and the subsequent `exec herdr agent attach`. None of that
/// belongs on the terminal: it would paint until the TUI's first frame wiped
/// it, a flash of unrelated output on every attach.
///
/// So the attach exec command prints this marker immediately before it
/// execs attach, and everything up to it is dropped. Printing it as real
/// control bytes is what makes it unambiguous: chatter that contains the
/// literal text `\033` has no ESC byte, so it cannot open the gate. APC is the
/// one string terminals are required to ignore, which keeps a stray copy
/// harmless.
enum AttachBootstrapHandshake {
    static let marker = Data("\u{1B}_waycar-attach\u{1B}\\".utf8)
    /// `marker` as a `printf` format. Octal throughout: the format has to
    /// survive the Host's account shell (fish included) and `/bin/sh` before
    /// printf ever sees it, and octal escapes are the portable spelling.
    static let markerPrintfFormat = "\\033_waycar-attach\\033\\134"
}

/// Holds an attach channel's output back until the bootstrap handshake lands.
///
/// The withheld bytes are buffered rather than dropped: a channel that dies
/// before the handshake has said everything it is ever going to say in that
/// startup diagnostic, so `flush()` hands it back.
struct AttachBootstrapGate {
    /// A ceiling for a channel that never handshakes. The tail is what
    /// carries the failure, and it stays far longer than the marker, so a
    /// marker split across chunks still matches after a trim.
    static let maximumWithheldBytes = 8 * 1024

    private(set) var isOpen = false
    private var withheld = Data()

    /// The bytes the terminal should paint: nothing until the marker arrives,
    /// everything after it once it has.
    mutating func admit(_ bytes: Data) -> Data {
        if isOpen { return bytes }
        withheld.append(bytes)
        guard let marker = withheld.range(of: AttachBootstrapHandshake.marker) else {
            if withheld.count > Self.maximumWithheldBytes {
                withheld = Data(withheld.suffix(Self.maximumWithheldBytes))
            }
            return Data()
        }
        isOpen = true
        let session = Data(withheld[marker.upperBound...])
        withheld = Data()
        return session
    }

    /// The withheld noise, for a channel that ended before it handshook.
    /// Empty once the gate is open — by then the noise is long past.
    mutating func flush() -> Data {
        guard !isOpen else { return Data() }
        defer { withheld = Data() }
        return withheld
    }
}

/// Input riding down a live Attach session. Keystrokes and resizes are
/// reliable, while touch scrolling is bounded and may be coalesced.
enum TerminalAttachInput: Sendable, Equatable {
    case keystrokes(Data)
    case scroll(Data)
    case resize(cols: Int, rows: Int)
}

/// The live PTY's mixed-reliability input queue.
///
/// Keystrokes and resizes are reliable and ordered. Touch scrolling is an
/// ephemeral viewport intent: keeping every momentum row under backpressure
/// only makes stale scrolling delay later keyboard input. Scroll rows are
/// therefore coalesced, bounded, and discarded as soon as a reliable key
/// arrives. The writer asks for one item only after the previous SSH write
/// completes, so priority is decided at the last useful moment.
final class TerminalAttachInputQueue: Sendable {
    static let maximumPendingScrollRows = 12
    static let maximumScrollRowsPerWrite = 3
    static let scrollPacingInterval = Duration.milliseconds(33)

    private struct PendingScroll: Sendable {
        let sequence: Data
        var rows: Int
    }

    private struct State: ~Copyable {
        var reliable: [TerminalAttachInput] = []
        var pendingScroll: PendingScroll?
        var waiter: CheckedContinuation<TerminalAttachInput?, Never>?
        var isFinished = false
    }

    private enum NextDecision {
        case wait
        case resume(TerminalAttachInput?)
    }

    private let state = Mutex(State())

    func send(_ keystrokes: Data) {
        guard !keystrokes.isEmpty else { return }
        enqueueReliable(.keystrokes(keystrokes), discardingPendingScroll: true)
    }

    func scroll(_ sequence: Data, rows: Int) {
        guard !sequence.isEmpty, rows > 0 else { return }

        var resumed: (CheckedContinuation<TerminalAttachInput?, Never>, TerminalAttachInput)?
        state.withLock { state in
            guard !state.isFinished else { return }

            if let waiter = state.waiter {
                state.waiter = nil
                let deliveredRows = min(rows, Self.maximumScrollRowsPerWrite)
                let remainingRows = min(
                    rows - deliveredRows,
                    Self.maximumPendingScrollRows - deliveredRows)
                if remainingRows > 0 {
                    state.pendingScroll = PendingScroll(
                        sequence: sequence,
                        rows: remainingRows)
                }
                resumed = (waiter, .scroll(Self.repeated(sequence, count: deliveredRows)))
                return
            }

            if var pending = state.pendingScroll, pending.sequence == sequence {
                pending.rows = min(
                    Self.maximumPendingScrollRows,
                    pending.rows + rows)
                state.pendingScroll = pending
            } else {
                // A direction change makes the previous momentum stale.
                state.pendingScroll = PendingScroll(
                    sequence: sequence,
                    rows: min(rows, Self.maximumPendingScrollRows))
            }
        }
        if let resumed {
            resumed.0.resume(returning: resumed.1)
        }
    }

    func resize(cols: Int, rows: Int) {
        enqueueReliable(.resize(cols: cols, rows: rows), discardingPendingScroll: false)
    }

    func next() async -> TerminalAttachInput? {
        await withCheckedContinuation { continuation in
            let decision = state.withLock { state -> NextDecision in
                if !state.reliable.isEmpty {
                    return .resume(state.reliable.removeFirst())
                }
                if let scroll = state.pendingScroll {
                    let deliveredRows = min(scroll.rows, Self.maximumScrollRowsPerWrite)
                    let remainingRows = scroll.rows - deliveredRows
                    state.pendingScroll =
                        remainingRows > 0
                        ? PendingScroll(sequence: scroll.sequence, rows: remainingRows)
                        : nil
                    return .resume(
                        .scroll(Self.repeated(scroll.sequence, count: deliveredRows)))
                }
                if state.isFinished {
                    return .resume(nil)
                }
                precondition(state.waiter == nil, "Attach input has more than one consumer")
                state.waiter = continuation
                return .wait
            }

            if case .resume(let input) = decision {
                continuation.resume(returning: input)
            }
        }
    }

    func finish() {
        var waiter: CheckedContinuation<TerminalAttachInput?, Never>?
        state.withLock { state in
            guard !state.isFinished else { return }
            state.isFinished = true
            // Explicit shutdown still drains reliable input already accepted
            // by the session. Only ephemeral scroll momentum is abandoned.
            state.pendingScroll = nil
            waiter = state.waiter
            state.waiter = nil
        }
        waiter?.resume(returning: nil)
    }

    private func enqueueReliable(
        _ input: TerminalAttachInput,
        discardingPendingScroll: Bool
    ) {
        var waiter: CheckedContinuation<TerminalAttachInput?, Never>?
        state.withLock { state in
            guard !state.isFinished else { return }
            if discardingPendingScroll {
                state.pendingScroll = nil
            }
            if state.reliable.isEmpty, let waiting = state.waiter {
                state.waiter = nil
                waiter = waiting
            } else {
                state.reliable.append(input)
            }
        }
        waiter?.resume(returning: input)
    }

    /// Drains the queue onto a live PTY channel until the queue finishes or
    /// the task is cancelled. Scroll batches are paced so momentum cannot
    /// monopolize the channel ahead of keystrokes.
    func pump(
        write: (Data) async throws -> Void,
        resize: (Int, Int) async throws -> Void
    ) async throws {
        while let item = await next() {
            guard !Task.isCancelled else { return }
            switch item {
            case .keystrokes(let data):
                try await write(data)
            case .scroll(let data):
                try await write(data)
                try await Task.sleep(for: Self.scrollPacingInterval)
            case .resize(let cols, let rows):
                try await resize(cols, rows)
            }
        }
    }

    private static func repeated(_ sequence: Data, count: Int) -> Data {
        var result = Data(capacity: sequence.count * count)
        for _ in 0..<count {
            result.append(sequence)
        }
        return result
    }
}

/// Whether a datagram transport's server has been heard from lately: what a
/// live terminal shows as stalled (#105). MoshCore's connectivity, without
/// its module.
enum TerminalLinkConnectivity: Sendable, Equatable {
    case connected
    case stalled
}

/// How a datagram session's first contact with its server went.
enum TerminalLinkFirstContact: Sendable, Equatable {
    /// The server answered.
    case answered
    /// The first-contact timeout passed in silence: nothing got through.
    case timedOut
    /// The session ended or failed some other way before any answer.
    case ended
}

/// What a datagram attach (mosh) adds to a session: the server's liveness,
/// which an SSH channel has no notion of, and a local repaint. nil on SSH
/// sessions.
protocol TerminalSessionLink: Sendable {
    /// Connectivity while the session runs: the current value, then each
    /// change; finishes when the session ends.
    func connectivity() -> AsyncStream<TerminalLinkConnectivity>
    /// Waits for the session's first contact to settle.
    func firstContact() async -> TerminalLinkFirstContact
    /// Whether the server is heard from within `timeout`, judged after the
    /// call: a session frozen with the app reads stalled until it is.
    func awaitServerContact(within timeout: Duration) async -> Bool
    /// Redraws the whole terminal from the session's last known screen,
    /// in order with the output stream and without a round trip, when that
    /// screen is `cols`×`rows` (the terminal's size). No-op before the first
    /// screen arrives, at another size, or once the session has ended.
    func repaint(cols: Int, rows: Int) async
}

/// A live interactive Attach session over its Host's dedicated terminal
/// channel: raw PTY bytes out, keystrokes and window changes in. The byte
/// stream feeds the terminal emulator directly without app-level framing.
///
/// Ending is explicit: call `end()`. The channel is closed by the session's
/// own teardown, which nothing else invokes — dropping the session, or
/// cancelling the task reading `output`, leaves the channel open until the
/// SSH connection closes.
final class TerminalAttachSession: Sendable {
    /// Raw PTY output in arrival order. Finishes without error when the
    /// remote attach exits cleanly (the user detached inside the TUI) or
    /// after `end()`; finishes throwing if the channel dies.
    ///
    /// Each access returns its own stream over the shared source. An
    /// unfolding stream keeps one produce storage per stream *instance*,
    /// shared by every iterator, and its own cancellation handler clears
    /// that storage for a reader whose task is already cancelled — before
    /// the source underneath can refuse the read. Through a single shared
    /// instance, such a reader silently terminates the legitimate consumer's
    /// iteration (#164). A per-access stream confines the damage to the
    /// offending reader; who may consume at all is still decided underneath,
    /// where the first reading task claims the output (#153).
    var output: AsyncThrowingStream<Data, any Error> { makeOutput() }
    /// The datagram transport's liveness, for a mosh session; nil over SSH.
    let link: (any TerminalSessionLink)?
    private let makeOutput: @Sendable () -> AsyncThrowingStream<Data, any Error>
    private let input: TerminalAttachInputQueue
    private let onEndStarted: @Sendable () -> Void
    private let ender: @Sendable () async -> Void
    private let abandoner: (@Sendable () async -> Void)?

    init(
        output makeOutput: @escaping @Sendable () -> AsyncThrowingStream<Data, any Error>,
        input: TerminalAttachInputQueue,
        onEndStarted: @escaping @Sendable () -> Void = {},
        link: (any TerminalSessionLink)? = nil,
        abandoner: (@Sendable () async -> Void)? = nil,
        ender: @escaping @Sendable () async -> Void
    ) {
        self.makeOutput = makeOutput
        self.input = input
        self.onEndStarted = onEndStarted
        self.link = link
        self.abandoner = abandoner
        self.ender = ender
    }

    /// Forwards raw keystroke bytes to the remote PTY. Fire-and-forget: a
    /// dead channel drops them, and the death surfaces on `output`.
    func send(_ keystrokes: Data) {
        input.send(keystrokes)
    }

    /// Coalesces touch-scroll rows behind at most one small in-flight batch.
    /// Pending rows are intentionally lossy so typing never waits behind old
    /// momentum after the user's intent has changed.
    func scroll(_ sequence: Data, rows: Int) {
        input.scroll(sequence, rows: rows)
    }

    /// Propagates a terminal geometry change (rotation, split view) to the
    /// remote PTY via SSH window-change; no reattach needed.
    func resize(cols: Int, rows: Int) {
        input.resize(cols: cols, rows: rows)
    }

    /// Closes the terminal channel explicitly and waits for its teardown;
    /// `output` then finishes without error. Idempotent.
    func end() async {
        onEndStarted()
        input.finish()
        await ender()
    }

    /// `end()` for a session whose server is presumed gone (#105): a mosh
    /// session stops at once instead of waiting out its shutdown
    /// handshake's acknowledgement. The same as `end()` over SSH.
    func abandon() async {
        onEndStarted()
        input.finish()
        await (abandoner ?? ender)()
    }
}
