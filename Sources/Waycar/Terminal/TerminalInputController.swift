import Foundation
import Observation

/// The only application-level writer for Attach input. Keyboard input, terminal
/// controls, reviewed Paste, and Snippets all cross this boundary so session
/// ownership applies consistently.
@MainActor
@Observable
final class TerminalInputController {
    typealias SessionGeneration = TerminalInputOwnershipMachine.Generation

    struct PasteReview: Sendable, Equatable {
        let lineCount: Int
        let characterCount: Int
        let preview: String
    }

    enum PasteRequestResult: Sendable, Equatable {
        case inserted
        case requiresReview(PasteReview)
        case rejected
        case blocked

        var requiresReview: Bool {
            if case .requiresReview = self { true } else { false }
        }
    }

    var liveGeneration: SessionGeneration? {
        access(keyPath: \.liveGeneration)
        return ownership.liveGeneration
    }
    private(set) var pendingPaste: PasteReview?
    private(set) var pasteErrorMessage: String?

    /// Submitted messages for this Attach session. Reset whenever the live
    /// writer is replaced, so entries cannot outlive the session they describe.
    let userMessageIndex = AttachUserMessageIndex()

    /// Runs when input the user made reaches the live writer: keys, Paste,
    /// Snippets, Composer text. Never for touch scrolling (`scroll`) or for
    /// the terminal's own replies to the remote application
    /// (`isTerminalReport`).
    @ObservationIgnored var onUserInput: (@MainActor () -> Void)?

    // Ordinary input must not invalidate views watching the session token.
    @ObservationIgnored private var ownership = TerminalInputOwnershipMachine()
    private var writer: ((Data) -> Void)?
    private var scroller: ((Data, Int) -> Void)?
    private var pendingPasteText: String?
    /// Captured when the paste is requested rather than read again at confirm
    /// time: the review sheet is what the user is looking at, so the framing
    /// they agreed to is the framing that was true when they were shown it.
    private var pendingPasteIsBracketed = false
    /// A tmux pane's copy-mode scroll path, for an Attach to a tmux pane:
    /// the Attach's own (``AgentAttachStore/paneHistory``), fixed for the
    /// controller's life so the scroll path and this hold can never part.
    /// tmux reads keys sent to a pane in copy mode as copy-mode commands
    /// (Enter copies and leaves, letters move), so while its view is away
    /// from live output (``TmuxPaneHistory/holdsInput``) input is held,
    /// copy mode is left, and the held input then goes out in order. The
    /// terminal's own replies are tmux's, not the pane's: they never wait.
    @ObservationIgnored let paneHistory: TmuxPaneHistory?
    @ObservationIgnored private var heldInput: [TerminalInputOwnershipMachine.Input] = []
    @ObservationIgnored private var releasingInput: Task<Void, Never>?

    init(paneHistory: TmuxPaneHistory? = nil) {
        self.paneHistory = paneHistory
    }

    var canConfirmPaste: Bool {
        writer != nil && pendingPasteText != nil
    }

    @discardableResult
    func beginSession(
        writer: @escaping (Data) -> Void,
        scroller: ((Data, Int) -> Void)? = nil
    ) -> SessionGeneration {
        withMutation(keyPath: \.liveGeneration) {
            _ = ownership.handle(.beginSession)
        }
        let generation = ownership.latestGeneration
        dropHeldInput()
        userMessageIndex.reset()
        self.writer = writer
        self.scroller = scroller
        return generation
    }

    func endSession(_ generation: SessionGeneration, preservingPendingPaste: Bool = false) {
        guard generation == liveGeneration else { return }
        withMutation(keyPath: \.liveGeneration) {
            _ = ownership.handle(.endSession(generation))
        }
        writer = nil
        scroller = nil
        dropHeldInput()
        userMessageIndex.reset()
        if !preservingPendingPaste {
            cancelPaste()
        }
    }

    /// Synchronously removes the predecessor Attach's input capabilities when
    /// replacement is scheduled. A reviewed Paste belongs to the surrounding
    /// interaction, so it remains pending for the replacement session.
    func detachSessionForReplacement() {
        withMutation(keyPath: \.liveGeneration) {
            _ = ownership.handle(.detachSession)
        }
        writer = nil
        scroller = nil
        dropHeldInput()
        userMessageIndex.reset()
    }

    /// Sends ordinary terminal bytes if a live Attach session exists.
    /// Returns whether the bytes reached a live writer. Empty payloads and a
    /// missing session are no-ops and return false.
    @discardableResult
    func send(_ data: Data) -> Bool {
        guard let writer, !data.isEmpty else { return false }
        write(data, using: writer, source: .keystroke)
        return true
    }

    /// Inserts Composer text into the live Attach PTY without submitting.
    /// Indexed as a composer insertion: embedded newlines are content, and a
    /// later Escape key cancels this pending line.
    @discardableResult
    func insertComposerDraft(_ text: String) -> Bool {
        guard let writer, !text.isEmpty else { return false }
        write(Data(text.utf8), using: writer, source: .composerInsert)
        return true
    }

    /// The Esc quick key. Distinct from a raw `0x1B` that may start CSI/SS3.
    @discardableResult
    func sendEscapeKey() -> Bool {
        guard let writer else { return false }
        write(Data([0x1B]), using: writer, source: .escapeKey)
        return true
    }

    /// Touch scrolling is deliberately separate from reliable terminal input.
    /// The live session can coalesce and shed stale momentum without changing
    /// keyboard, Paste, or Snippet delivery semantics.
    func scroll(_ sequence: Data, rows: Int) {
        guard !sequence.isEmpty, rows > 0 else { return }
        scroller?(sequence, rows)
    }

    /// Sends a Snippet's text. It never carries a submit byte of its own — a
    /// Snippet is stored with carriage returns already collapsed to line feeds
    /// (see `Snippet.make`) — and multiline text is framed as a paste so the
    /// remote application reads it as one block rather than a run of keys.
    ///
    /// Unlike Paste, there is no review step: the user wrote this text, named
    /// it, and can see it on the button they just tapped.
    @discardableResult
    func insertSnippet(_ text: String, bracketedPaste: Bool) -> Bool {
        guard let writer, !text.isEmpty,
            TerminalTextSafety.containsOnlySafeScalars(text)
        else { return false }
        write(
            TerminalBracketedPaste.encode(
                text, bracketed: bracketedPaste && TerminalTextSafety.isMultiline(text)),
            using: writer,
            source: .snippet)
        return true
    }

    @discardableResult
    func requestPaste(_ text: String, bracketedPaste: Bool = false) -> PasteRequestResult {
        pasteErrorMessage = nil
        guard writer != nil else { return .blocked }
        guard TerminalTextSafety.containsOnlySafeScalars(text) else {
            cancelPaste()
            pasteErrorMessage = "The clipboard contains unsafe terminal control characters."
            return .rejected
        }
        guard TerminalTextSafety.isMultiline(text) else {
            if !text.isEmpty, let writer {
                write(Data(text.utf8), using: writer, source: .paste)
            }
            return .inserted
        }

        let review = PasteReview(
            lineCount: Self.lineCount(text),
            characterCount: text.count,
            preview: Self.preview(text))
        pendingPasteText = text
        pendingPasteIsBracketed = bracketedPaste
        pendingPaste = review
        return .requiresReview(review)
    }

    @discardableResult
    func confirmPaste() -> Bool {
        guard canConfirmPaste, let writer, let text = pendingPasteText else { return false }
        // Reviewed text is still multiline text: without framing its newlines
        // reach the pane as separate key events, which is the very thing the
        // review sheet leaves the user unable to prevent.
        write(
            TerminalBracketedPaste.encode(text, bracketed: pendingPasteIsBracketed),
            using: writer,
            source: .paste)
        cancelPaste()
        return true
    }

    func cancelPaste() {
        pendingPasteText = nil
        pendingPasteIsBracketed = false
        pendingPaste = nil
    }

    func clearPasteError() {
        pasteErrorMessage = nil
    }

    /// Records a Composer `agent.prompt` delivery against `generation`.
    /// Drops the write if that session is no longer live, so a reconnect
    /// cannot inherit a predecessor's jump target.
    func recordSubmitted(_ text: String, generation: SessionGeneration) {
        guard generation == liveGeneration else { return }
        userMessageIndex.record(submitted: text)
    }

    private func write(
        _ data: Data,
        using writer: @escaping (Data) -> Void,
        source: AttachUserMessageIndex.OutgoingSource
    ) {
        let isReport = source == .keystroke && Self.isTerminalReport(data)
        perform(
            ownership.handle(.input(
                .init(data: data, source: source),
                isTerminalReport: isReport,
                historyHoldsInput:
                    !isReport && !ownership.isHoldingInput && paneHistory?.holdsInput == true)),
            using: writer)
    }

    private func perform(
        _ effects: [TerminalInputOwnershipMachine.Effect],
        using writer: ((Data) -> Void)? = nil
    ) {
        for effect in effects {
            switch effect {
            case .deliver(let input):
                guard let writer else { continue }
                deliver(input.data, using: writer, source: input.source)
            case .hold(let input):
                heldInput.append(input)
            case .leaveHistory(let generation):
                leaveHistory(generation: generation)
            case .releaseHeldInput:
                let held = heldInput
                heldInput = []
                releasingInput = nil
                guard let writer = self.writer else { continue }
                for input in held {
                    deliver(input.data, using: writer, source: input.source)
                }
            }
        }
    }

    private func deliver(
        _ data: Data,
        using writer: (Data) -> Void,
        source: AttachUserMessageIndex.OutgoingSource
    ) {
        userMessageIndex.observeOutgoing(data, source: source)
        writer(data)
        if source != .keystroke || !Self.isTerminalReport(data) {
            onUserInput?()
        }
    }

    /// Queues input behind ``TmuxPaneHistory/leave()``. Held input belongs
    /// to the session it was typed into: a session that ends or is
    /// replaced meanwhile drops it.
    private func leaveHistory(generation: SessionGeneration) {
        guard releasingInput == nil, let paneHistory else { return }
        releasingInput = Task { [weak self] in
            await paneHistory.leave()
            guard let self else { return }
            self.perform(self.ownership.handle(.historyLeft(generation)))
        }
    }

    private func dropHeldInput() {
        heldInput = []
        releasingInput?.cancel()
        releasingInput = nil
    }

    /// Whether `data` is only replies the terminal sends on its own through
    /// the keystroke path: device attributes, cursor-position and status
    /// reports, focus in/out, mode and window reports, kitty keyboard
    /// replies, and OSC/DCS/APC replies. Mouse button reports are user taps,
    /// so they are not reports.
    static func isTerminalReport(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return false }
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 0x1B, index + 1 < bytes.count else { return false }
            switch bytes[index + 1] {
            case UInt8(ascii: "["):
                var cursor = index + 2
                let paramsStart = cursor
                while cursor < bytes.count, (0x30...0x3F).contains(bytes[cursor]) { cursor += 1 }
                let params = bytes[paramsStart..<cursor]
                while cursor < bytes.count, (0x20...0x2F).contains(bytes[cursor]) { cursor += 1 }
                guard cursor < bytes.count else { return false }
                let final = bytes[cursor]
                cursor += 1
                switch final {
                case UInt8(ascii: "c"), UInt8(ascii: "R"), UInt8(ascii: "n"), UInt8(ascii: "I"),
                    UInt8(ascii: "O"), UInt8(ascii: "y"), UInt8(ascii: "t"):
                    break
                case UInt8(ascii: "M"), UInt8(ascii: "m"):
                    // SGR/X10 mouse button reports on the keystroke path are
                    // the user's taps; wheel scrolling goes through `scroll`.
                    return false
                case UInt8(ascii: "u"):
                    guard params.first == UInt8(ascii: "?") else { return false }
                default:
                    return false
                }
                index = cursor
            case UInt8(ascii: "]"), UInt8(ascii: "P"), UInt8(ascii: "_"):
                var cursor = index + 2
                var terminated = false
                while cursor < bytes.count {
                    if bytes[cursor] == 0x07 {
                        cursor += 1
                        terminated = true
                        break
                    }
                    if bytes[cursor] == 0x1B, cursor + 1 < bytes.count,
                        bytes[cursor + 1] == UInt8(ascii: "\\")
                    {
                        cursor += 2
                        terminated = true
                        break
                    }
                    cursor += 1
                }
                guard terminated else { return false }
                index = cursor
            default:
                return false
            }
        }
        return true
    }

    private static func lineCount(_ text: String) -> Int {
        var count = 1
        var previousWasCarriageReturn = false
        for scalar in text.unicodeScalars {
            if scalar.value == 0x0A {
                if !previousWasCarriageReturn { count += 1 }
            } else if scalar.value == 0x0D {
                count += 1
            }
            previousWasCarriageReturn = scalar.value == 0x0D
        }
        return count
    }

    private static func preview(_ text: String) -> String {
        let limit = 2_000
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }
}
