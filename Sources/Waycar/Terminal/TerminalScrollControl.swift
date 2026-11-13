import Observation

/// A handle on the live terminal's scroll path for chrome that sits outside
/// it. Same lifetime rules as ``TerminalKeyboardControl``: the reference is
/// weak and set by the surface, so an Agent switch rebuilding the terminal
/// cannot leave a jump control driving a dead one.
///
/// ``isAlternateScreen`` is observable so the message-jump chrome can hide
/// itself on the primary screen, where local scrollback already works and
/// remote wheel reports would be the wrong tool. `refs #268`.
@MainActor
@Observable
final class TerminalScrollControl {
    weak var terminal: WaycarTerminalView? {
        didSet {
            oldValue?.onAlternateScreenChange = nil
            oldValue?.onTouchScroll = nil
            oldValue?.paneHistory = nil
            // A mouse mode turning on or off means another application now
            // runs in the pane: its history may have come or gone.
            terminal?.onAlternateScreenChange = { [weak self] in
                self?.paneHistory?.refresh()
                self?.syncAlternateScreen()
            }
            terminal?.onTouchScroll = { [weak self] towardOlderContent, rows in
                guard let self, self.canScrollRemoteContent else { return }
                self.onTouchScroll?(towardOlderContent, rows)
            }
            terminal?.paneHistory = paneHistory
            claimAvailabilityChanges()
            syncAlternateScreen()
        }
    }

    /// The tmux pane's copy-mode scroll path, for an Attach to a tmux pane;
    /// nil on herdr. Scrolls whenever the application inside does not track
    /// the mouse, and counts toward ``canScrollRemoteContent`` while the
    /// pane has history to show. The Attach's own
    /// (``AgentAttachStore/paneHistory``), shared by every view SwiftUI
    /// builds for it.
    var paneHistory: TmuxPaneHistory? {
        didSet {
            if oldValue !== paneHistory, terminal != nil {
                oldValue?.onAvailabilityChange = nil
            }
            claimAvailabilityChanges()
            terminal?.paneHistory = paneHistory
            syncAlternateScreen()
        }
    }

    /// Only a control with a surface listens to the pane history: SwiftUI
    /// rebuilds the view on every parent re-render, and the throwaway
    /// copies' controls share the Attach's history but never mount, so one
    /// claiming it would take the callback from the control on screen.
    private func claimAvailabilityChanges() {
        guard terminal != nil else { return }
        paneHistory?.onAvailabilityChange = { [weak self] in
            self?.syncAlternateScreen()
        }
    }

    /// A drag or its momentum moved the remote application's view by `rows`
    /// rows. Fires only while ``canScrollRemoteContent`` is true, so
    /// primary-screen scrollback never reaches a listener that reasons about
    /// the remote TUI's position. The jump chrome uses it to learn that the
    /// viewport has left live output (or may have left the oldest message)
    /// without a jump, and how far one run of scrolling has gone. `refs #268`.
    var onTouchScroll: ((_ towardOlderContent: Bool, _ rows: Int) -> Void)?

    /// ``canScrollRemoteContent`` went false: mouse reporting ended (the
    /// agent exited, say) or the terminal went away. A jump still stepping
    /// would type cursor keys from here on where the application asked for
    /// alternate scroll (`applyScroll`), else scroll nothing. `refs #58`.
    var onRemoteScrollLost: (() -> Void)?

    /// Mirrors the surface's DECSET 1049/47/1047 state. False when no terminal
    /// is attached.
    private(set) var isAlternateScreen = false

    /// Whether a scroll step can actually move the remote application's own
    /// view: while it tracks the mouse, so a step is a wheel report, or
    /// while a tmux pane's history can be scrolled in copy mode
    /// (``paneHistory``).
    ///
    /// `herdr terminal attach` puts the client on the alternate screen, so
    /// `isAlternateScreen` says nothing about the application inside it.
    /// herdr 0.9.3 turns mouse reporting on for every attach and routes the
    /// wheel itself (its own scrollback for primary-screen panes such as
    /// inline agents, the application's mouse or alternate-scroll keys
    /// otherwise; live in the harness lab). A tmux attach passes the pane's
    /// mouse modes through and drops DECSET 1007, and shows only tmux's
    /// redraw, so an inline agent's or a shell's history is reachable only
    /// through copy mode. Alternate scroll alone does not count: its Up/Down
    /// keys are not proven to scroll anything, and in codex 0.162.1, the one
    /// agent that asks for it without a mouse mode, they recall composer
    /// history over the user's draft (live, tmux and raw input through
    /// `herdr agent attach`). An alternate-screen application leaves no
    /// herdr-side scrollback for `pane.read` to return, so nothing else can
    /// stand in. `refs #268`.
    private(set) var canScrollRemoteContent = false

    /// One scroll step of `rows` lines. Same branch `scrollTouch` takes
    /// (remote sequence when the mode tracker supplies one, tmux copy mode
    /// for a pane history, local `scroll_page_lines` otherwise), without
    /// touching the gesture accumulator.
    func scrollRows(towardOlderContent: Bool, rows: Int) {
        terminal?.scrollRows(towardOlderContent: towardOlderContent, rows: rows)
    }

    /// Stops a coasting flick before a jump takes over the viewport.
    /// `refs #58`.
    func haltMomentum() {
        terminal?.haltTouchScrollMomentum()
    }

    /// Rows the live grid shows, or nil when unknown. Bounds the jump loop's
    /// step size so no row can pass by unrendered.
    var viewportRows: Int? { terminal?.viewportRows }

    /// Whether a scroll goes to the pane's copy mode rather than as a wheel
    /// report: the same test `applyScroll` makes.
    var scrollsPaneHistory: Bool {
        paneHistory != nil && !(terminal?.remoteTracksMouse ?? false)
    }

    private func syncAlternateScreen() {
        let nextAlternate = terminal?.isAlternateScreen ?? false
        if isAlternateScreen != nextAlternate {
            isAlternateScreen = nextAlternate
        }
        let tracksMouse = terminal?.remoteTracksMouse ?? false
        let nextScrollable = terminal != nil
            && (tracksMouse || paneHistory?.isAvailable == true)
        if canScrollRemoteContent != nextScrollable {
            canScrollRemoteContent = nextScrollable
            if !nextScrollable {
                onRemoteScrollLost?()
            }
        }
    }
}

/// tmux copy mode as the scroll path of a tmux pane whose application is
/// neither on the alternate screen nor tracking the mouse: inline agents
/// (omp, gemini, agy, the hermes REPL, kiro) and shells. A tmux attach
/// shows only tmux's redraw of the pane, so their history lives in tmux
/// alone. Each scroll is a control-mode command
/// (``Transport/scrollPaneHistory(paneID:towardOlderContent:rows:)``);
/// rows that pile up while one is in flight go out together on the next.
///
/// Copy mode is pane state the desk's tmux clients share, so it is kept
/// bounded: scrolling back to the bottom leaves it (`copy-mode -e`), typed
/// input and a jump to live leave it at once (``leave()``), and leaving the
/// Attach leaves the copy mode this history entered (``depart()``).
@MainActor
@Observable
final class TmuxPaneHistory {
    typealias Scroll = @MainActor (_ towardOlderContent: Bool, _ rows: Int) async throws
        -> PaneHistoryScroll
    typealias Leave = @MainActor () async throws -> Void

    /// Where the pane's view was last seen; nil until the first answer.
    private(set) var position: PaneHistoryPosition?
    /// One of this history's scrolls took the view into copy mode
    /// (``PaneHistoryScroll/enteredHistory``), and no answer since has seen
    /// it leave: the departure's to undo. Copy mode a desk client or
    /// another device entered is not, even one entered since the last read.
    @ObservationIgnored private(set) var enteredHistory = false

    /// ``isAvailable`` changed.
    @ObservationIgnored var onAvailabilityChange: (() -> Void)?

    @ObservationIgnored private let scrollAction: Scroll
    @ObservationIgnored private let leaveAction: Leave
    /// Rows asked for and not yet sent; positive toward older content.
    @ObservationIgnored private var pendingRows = 0
    /// A position read was asked for and not yet sent.
    @ObservationIgnored private var wantsRefresh = false
    /// The request in flight moves the view (rather than only reading it).
    @ObservationIgnored private(set) var isMoving = false
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var leaving: Task<Void, Never>?

    init(scroll: @escaping Scroll, leave: @escaping Leave) {
        scrollAction = scroll
        leaveAction = leave
    }

    /// Whether the pane has history to scroll: its application is not on
    /// the alternate screen, or the view is in copy mode already.
    var isAvailable: Bool { position == .live || position == .inHistory }

    /// Whether input must wait for ``leave()``: the view is above live
    /// output, or a scroll that may take it there is in flight or queued.
    var holdsInput: Bool {
        position == .inHistory || isMoving || pendingRows != 0 || leaving != nil
    }

    /// Moves the view `rows` rows; coalesced with any request in flight.
    func scroll(towardOlderContent: Bool, rows: Int) {
        guard rows > 0, leaving == nil else { return }
        pendingRows += towardOlderContent ? rows : -rows
        startPump()
    }

    /// Reads where the view is without moving it: the application may have
    /// changed (an alternate-screen TUI started or ended), or a desk client
    /// left copy mode.
    func refresh() {
        guard leaving == nil else { return }
        wantsRefresh = true
        startPump()
    }

    /// Leaves copy mode and returns once the pane takes input again. A
    /// request in flight finishes first; rows not yet sent are dropped. A
    /// failed leave still ends the wait: input then goes out as before.
    func leave() async {
        await leave(onlyIfEntered: false)
    }

    /// The Attach's departure: like ``leave()``, but only out of the copy
    /// mode this history entered (``enteredHistory``). A desk client keeps
    /// its own copy mode and scroll position when the phone looks away.
    func depart() async {
        await leave(onlyIfEntered: true)
    }

    private func leave(onlyIfEntered: Bool) async {
        if let leaving {
            await leaving.value
            // A departure that kept someone else's copy mode does not
            // stand in for input's leave.
            guard !onlyIfEntered, position == .inHistory else { return }
            return await leave(onlyIfEntered: false)
        }
        let task = Task { [weak self] in
            guard let self else { return }
            self.pendingRows = 0
            self.wantsRefresh = false
            await self.pump?.value
            if self.position == .inHistory, !onlyIfEntered || self.enteredHistory {
                try? await self.leaveAction()
                self.update(.live)
            }
            self.leaving = nil
        }
        leaving = task
        await task.value
    }

    /// One request at a time: the rows piled up meanwhile, or a bare read.
    /// A failed request drops what is pending; the next scroll asks again.
    private func startPump() {
        guard pump == nil else { return }
        pump = Task { [weak self] in
            guard let self else { return }
            while self.pendingRows != 0 || self.wantsRefresh {
                let rows = self.pendingRows
                self.pendingRows = 0
                self.wantsRefresh = false
                self.isMoving = rows != 0
                let answer = try? await self.scrollAction(rows > 0, abs(rows))
                self.isMoving = false
                guard let answer else {
                    self.pendingRows = 0
                    self.wantsRefresh = false
                    break
                }
                self.update(answer.position)
                if answer.enteredHistory { self.enteredHistory = true }
            }
            self.pump = nil
        }
    }

    private func update(_ next: PaneHistoryPosition) {
        let wasAvailable = isAvailable
        if next != .inHistory { enteredHistory = false }
        if position != next { position = next }
        if isAvailable != wasAvailable { onAvailabilityChange?() }
    }
}
