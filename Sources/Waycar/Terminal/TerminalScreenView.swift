import GameController
import GhosttyTerminal
import Observation
import SwiftUI
import UIKit

/// Remote terminal output is untrusted. Only ordinary web links cross from
/// Ghostty into the system URL opener; local files and executable schemes do not.
enum TerminalLinkPolicy {
    static func url(for link: String) -> URL? {
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased() else {
            return nil
        }
        guard scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }
}

/// The standard keyboard asks the terminal for clipboard state synchronously.
/// Keep that system IPC behind a seam so unit tests never depend on the
/// Simulator pasteboard service being responsive.
@MainActor
struct TerminalClipboard {
    let string: () -> String?
    let hasStrings: () -> Bool

    static let system = TerminalClipboard(
        string: { UIPasteboard.general.string },
        hasStrings: { UIPasteboard.general.hasStrings })
}

/// A handle on the live terminal for chrome that sits outside it. The reference
/// is weak and set by the surface itself, so an Agent switch rebuilding the
/// terminal cannot leave the keyboard toggle or Composer quick keys driving a
/// dead one. First-responder state is observable so Direct Input chrome can
/// refresh without waiting on an unrelated SwiftUI invalidation.
@MainActor
@Observable
final class TerminalKeyboardControl {
    weak var terminal: WaycarTerminalView? {
        didSet {
            oldValue?.onFirstResponderChange = nil
            oldValue?.onTouchSelectionChange = nil
            if oldValue?.keyboardControl === self {
                oldValue?.keyboardControl = nil
            }
            terminal?.onFirstResponderChange = { [weak self] in
                self?.syncFirstResponder()
            }
            terminal?.onTouchSelectionChange = { [weak self] in
                self?.syncTouchSelection()
            }
            terminal?.keyboardControl = self
            syncFirstResponder()
            syncTouchSelection()
        }
    }

    /// Ghostty first-responder intent. Distinct from software-keyboard inset:
    /// a hardware keyboard can keep this true with a zero footprint.
    private(set) var isFirstResponder = false

    var isKeyboardUp: Bool { isFirstResponder }

    func toggleKeyboard() {
        guard let terminal else { return }
        if terminal.isFirstResponder {
            terminal.dismissKeyboard()
        } else {
            terminal.requestKeyboard()
        }
    }

    func requestKeyboard() {
        terminal?.requestKeyboard()
    }

    /// Re-runs the window's collection-view focus suppression while this
    /// surface is first responder: the Agent list the sidebar mounts later
    /// is focusable by default, and on a hardware-keyboard iPad the focus
    /// system would take arrows, Tab and Return before the terminal sees
    /// them (#80). The sidebar's visibility change is the call site.
    func resuppressSceneKeyboardFocus() {
        terminal?.resuppressSceneKeyboardFocus()
    }

    func dismissKeyboard() {
        _ = terminal?.dismissKeyboard()
    }

    /// One-shot sticky modifiers for the ⌃/⌥ caps on the terminal key
    /// surfaces (#270). Tapping a modifier arms it for the next key only —
    /// on-screen `sendQuickKey` or the next physical press / `insertText`.
    /// Firing any mapped key consumes and clears it; tapping the armed
    /// modifier again disarms it. No lock mode.
    private(set) var pendingModifiers = TerminalKeyModifiers()

    func isModifierArmed(_ modifier: TerminalKeyModifiers) -> Bool {
        pendingModifiers.contains(modifier)
    }

    func setModifierArmed(_ modifier: TerminalKeyModifiers, armed: Bool) {
        if armed {
            pendingModifiers.insert(modifier)
        } else {
            pendingModifiers.remove(modifier)
        }
    }

    func toggleModifier(_ modifier: TerminalKeyModifiers) {
        setModifierArmed(modifier, armed: !isModifierArmed(modifier))
    }

    @discardableResult
    func sendQuickKey(
        _ key: AgentQuickKey,
        combining physicalModifiers: TerminalKeyModifiers = []
    ) -> Bool {
        let modifiers = pendingModifiers.union(physicalModifiers)
        guard let terminal, terminal.sendQuickKey(key, modifiers: modifiers) else {
            return false
        }
        pendingModifiers = []
        return true
    }

    /// Sends exactly `key` with `modifiers`. Armed one-shot modifiers are
    /// discarded and physical modifiers ignored, so a fixed chord cannot pick
    /// up extra ones.
    func sendChord(_ key: AgentQuickKey, modifiers: TerminalKeyModifiers) {
        pendingModifiers = []
        terminal?.sendQuickKey(key, modifiers: modifiers)
    }

    /// Control-only interrupt (Ctrl-C). Pre-armed Alt/Shift are discarded so
    /// the advertised chord cannot become Ctrl+Alt+C.
    func sendInterrupt() {
        sendChord(.character("c"), modifiers: .control)
    }

    /// Stops inertial remote scroll, matching `sendQuickKey`'s reliable-input
    /// side effect, for routes that do not go through Ghostty `sendInput`.
    func noteReliableInputBegan() {
        terminal?.noteReliableInputBegan()
    }

    func setKeyboardMode(_ mode: TerminalKeyboardMode) {
        terminal?.setKeyboardMode(mode)
    }

    func paste(_ text: String) {
        terminal?.requestPaste(text)
    }

    /// A tap chrome over the terminal caught (the back-swipe strip), at
    /// `point` in the terminal view's own coordinates, handed on to it.
    func forwardTap(at point: CGPoint) {
        terminal?.handleForwardedTap(at: point)
    }

    /// Where the terminal's touch-selection handles take touches, in its own
    /// coordinates, so chrome over its edges (the back-swipe strip) can step
    /// aside where a handle is grabbable and nowhere else.
    private(set) var touchSelectionHandleAreas: [CGRect] = []

    private func syncTouchSelection() {
        let next = terminal?.touchSelectionHandleAreas ?? []
        guard touchSelectionHandleAreas != next else { return }
        touchSelectionHandleAreas = next
    }

    private func syncFirstResponder() {
        let next = terminal?.isFirstResponder ?? false
        guard isFirstResponder != next else { return }
        isFirstResponder = next
    }
}

/// The interactive Ghostty surface. PTY bytes flow into an in-memory Ghostty
/// session, while its write and resize callbacks flow back to Attach.
enum TerminalTextInputStyle: Equatable {
    case terminal
    case naturalLanguage
}

enum TerminalKeyboardHandoffOutcome: Equatable {
    case settled
    case timedOut
    case cancelled
}

/// Keeps the emulator, including offscreen output and scrollback, with a
/// retained connection. A new feed always gets a new surface.
@MainActor
final class TerminalSurfaceRetention {
    private var feed: TerminalByteFeed?
    private var surface: WaycarTerminalView?

    func surface(for feed: TerminalByteFeed, make: () -> WaycarTerminalView) -> WaycarTerminalView {
        if self.feed === feed, let surface { return surface }
        clear()
        let surface = make()
        self.feed = feed
        self.surface = surface
        return surface
    }

    func clear() {
        detachCallbacks()
        surface = nil
        feed = nil
    }

    /// Callbacks come off synchronously so a retired surface can never write
    /// into a store it no longer belongs to; the keyboard is released a turn
    /// later, because this runs inside `makeUIView` when a surface is
    /// replaced (see `WaycarTerminalView.retireLocalInput`).
    ///
    /// `keepingKeyboard` leaves first responder with the surface for the
    /// screen that is taking the keyboard over; see
    /// `WaycarTerminalView.retireLocalInput(keepingKeyboard:)`.
    func detachCallbacks(keepingKeyboard: Bool = false) {
        surface?.updateCallbacks(
            onSizeChanged: nil, onViewportTextChanged: nil,
            onSend: nil, onScroll: nil, onPaste: nil)
        surface?.onOpenLink = nil
        surface?.onPreviewFile = nil
        surface?.onConfirmLink = nil
        surface?.onRefusedFileLink = nil
        surface?.onFontSizeChanged = nil
        surface?.knownLinkTargets = nil
        surface?.onKeyboardHandoffEnded = nil
        surface?.retireLocalInput(keepingKeyboard: keepingKeyboard)
    }
}

struct TerminalScreenView: UIViewRepresentable {
    let feed: TerminalByteFeed
    var retention: TerminalSurfaceRetention?
    #if DEBUG
    /// Reports creation and feed attachment of the concrete UIKit surface.
    /// It does not claim that Ghostty presented a frame.
    var onSurfaceAttached: (() -> Void)?
    #endif
    var onSizeChanged: ((_ cols: Int, _ rows: Int) -> Void)?
    var onViewportTextChanged: ((String) -> Void)?
    var onSend: ((Data) -> Void)?
    var onScroll: ((_ sequence: Data, _ rows: Int) -> Void)?
    var onPaste: ((_ text: String, _ bracketed: Bool) -> Void)?
    /// Asked exactly once, as the surface is created: does this terminal
    /// inherit the keyboard from the one it replaced? Asking through a
    /// closure rather than a stored flag keeps the answer tied to the
    /// surface's creation instead of to how often SwiftUI evaluates the body.
    var claimsKeyboard: (@MainActor () -> Bool)?
    /// Reports whether an update-time responder handoff reached the current,
    /// visible terminal. The owner keeps Composer mounted on failure.
    var keyboardHandoffID: UUID?
    var isKeyboardHandoffCurrent: (@MainActor (_ id: UUID) -> Bool)?
    var onKeyboardHandoffResult: (@MainActor (_ id: UUID, _ succeeded: Bool) -> Void)?
    /// Reports whether this terminal settled the handoff or had to abandon it.
    var onKeyboardHandoffEnded: (@MainActor (
        _ id: UUID, _ outcome: TerminalKeyboardHandoffOutcome
    ) -> Void)?
    /// Handed the surface once it exists, so the Agent strip's toggle can
    /// raise and lower this terminal's keyboard.
    var keyboardControl: TerminalKeyboardControl?
    /// Handed the surface once it exists, so the message-jump chrome can
    /// drive remote scroll without holding the UIKit view itself.
    var scrollControl: TerminalScrollControl?
    var isLocalInputEnabled = true
    /// Applied before the first focus claim, including Agent tools handoffs.
    var initialKeyboardMode = TerminalKeyboardMode.text
    var textInputStyle = TerminalTextInputStyle.terminal
    /// A hardware keyboard's keys claim an unowned surface without the
    /// software keyboard when it reaches the window (#80). Disabled while
    /// an app-owned dock deliberately releases first responder.
    var hardwareKeyboardAutoFocus = true
    var theme: TerminalTheme = .default
    var fontSize: Float = TerminalZoomSettings.defaultFontSize
    var fontFamily: String?
    /// Pinch-to-zoom and the ⌘+/⌘- shortcut change the size in place; the
    /// screen forwards the new value so it lands in the global setting.
    var onFontSizeChanged: ((Float) -> Void)?
    /// Previews a file path tapped in the output; nil leaves paths inert.
    var onPreviewFile: ((TerminalFileReference) -> Void)?
    /// Confirms a link whose target is not its text; nil leaves such links
    /// inert.
    var onConfirmLink: ((TerminalLinkTarget) -> Void)?
    /// Says a tapped `file:` link names another machine (its host); nil
    /// leaves such links inert.
    var onRefusedFileLink: ((String) -> Void)?
    /// The URLs the Agent's transcript and stream hold whole, read at a
    /// tap so a link broken across rows opens as the Attach Links list
    /// reads it; nil reads the screen alone.
    var knownLinkTargets: (@MainActor () -> AttachKnownTargets)?
    @Environment(\.openURL) private var openURL

    func makeUIView(context: Context) -> WaycarTerminalView {
        let openURL = openURL
        let onKeyboardHandoffEnded = onKeyboardHandoffEnded
        let make = { Self.makeConfiguredTerminal(
            onSizeChanged: onSizeChanged,
            onViewportTextChanged: onViewportTextChanged,
            onSend: onSend,
            onScroll: onScroll,
            onPaste: onPaste,
            theme: theme,
            fontSize: fontSize,
            fontFamily: fontFamily,
            hardwareKeyboardAutoFocus: hardwareKeyboardAutoFocus) }
        let view = retention?.surface(for: feed, make: make) ?? make()
        view.updateCallbacks(
            onSizeChanged: onSizeChanged, onViewportTextChanged: onViewportTextChanged,
            onSend: onSend, onScroll: onScroll, onPaste: onPaste)
        view.applyTheme(theme)
        view.applyFontSize(fontSize)
        view.applyFontFamily(fontFamily)
        view.onOpenLink = { url in openURL(url) }
        view.onPreviewFile = onPreviewFile
        view.onConfirmLink = onConfirmLink
        view.onRefusedFileLink = onRefusedFileLink
        view.knownLinkTargets = knownLinkTargets
        // Only here, never in updateUIView: the intent belongs to this
        // terminal's first appearance, not to every state change after it.
        view.setKeyboardMode(initialKeyboardMode)
        view.raisesKeyboardWhenReady = claimsKeyboard?() ?? false
        view.isHardwareKeyboardAutoFocus = hardwareKeyboardAutoFocus
        keyboardControl?.terminal = view
        scrollControl?.terminal = view
        view.onKeyboardHandoffEnded = { [weak view, weak keyboardControl] id, outcome in
            guard let view else { return }
            if let keyboardControl, keyboardControl.terminal !== view { return }
            onKeyboardHandoffEnded?(id, outcome)
        }
        view.setTextInputStyle(textInputStyle)
        view.setLocalInputEnabled(isLocalInputEnabled)
        // The feed holds the surface weakly so a replaced UIKit view cannot be
        // kept alive by an obsolete terminal pipeline.
        feed.attach(view)
        #if DEBUG
        onSurfaceAttached?()
        #endif
        return view
    }

    @MainActor
    static func makeConfiguredTerminal(
        onSizeChanged: ((_ cols: Int, _ rows: Int) -> Void)? = nil,
        onViewportTextChanged: ((String) -> Void)? = nil,
        onSend: ((Data) -> Void)? = nil,
        onScroll: ((_ sequence: Data, _ rows: Int) -> Void)? = nil,
        onPaste: ((_ text: String, _ bracketed: Bool) -> Void)? = nil,
        theme: TerminalTheme = .default,
        fontSize: Float = TerminalZoomSettings.defaultFontSize,
        fontFamily: String? = nil,
        /// The center the terminal observes the keyboard through. Tests pass
        /// their own so one test's keyboard cannot end another test's
        /// handoff (#157); production keeps the default.
        notificationCenter: NotificationCenter = .default,
        clipboard: TerminalClipboard = .system,
        /// Whether a hardware keyboard's keys claim the surface without the
        /// software keyboard. The unit-test host reports no hardware
        /// keyboard, so a test of the claim also injects
        /// `isHardwareKeyboardConnected`. Production keeps the default.
        hardwareKeyboardAutoFocus: Bool = true
    ) -> WaycarTerminalView {
        let view = WaycarTerminalView(
            frame: .zero,
            onSizeChanged: onSizeChanged,
            onViewportTextChanged: onViewportTextChanged,
            onSend: onSend,
            onScroll: onScroll,
            onPaste: onPaste,
            theme: theme,
            fontSize: fontSize,
            fontFamily: fontFamily,
            clipboard: clipboard)
        view.isHardwareKeyboardAutoFocus = hardwareKeyboardAutoFocus
        view.installKeyboardSwitcher(notificationCenter: notificationCenter)
        return view
    }

    func updateUIView(_ view: WaycarTerminalView, context: Context) {
        let openURL = openURL
        let onKeyboardHandoffEnded = onKeyboardHandoffEnded
        view.updateCallbacks(
            onSizeChanged: onSizeChanged,
            onViewportTextChanged: onViewportTextChanged,
            onSend: onSend,
            onScroll: onScroll,
            onPaste: onPaste)
        keyboardControl?.terminal = view
        scrollControl?.terminal = view
        view.onKeyboardHandoffEnded = { [weak view, weak keyboardControl] id, outcome in
            guard let view else { return }
            if let keyboardControl, keyboardControl.terminal !== view { return }
            onKeyboardHandoffEnded?(id, outcome)
        }
        let claimsKeyboardOnEnable = !view.isLocalInputEnabled
            && isLocalInputEnabled
            && (claimsKeyboard?() ?? false)
        view.isHardwareKeyboardAutoFocus = hardwareKeyboardAutoFocus
        view.setTextInputStyle(textInputStyle)
        view.setLocalInputEnabled(isLocalInputEnabled)
        if claimsKeyboardOnEnable, let keyboardHandoffID {
            DispatchQueue.main.async { [weak view, weak keyboardControl] in
                guard let view,
                      view.window != nil,
                      view.isLocalInputEnabled,
                      keyboardControl?.terminal === view,
                      isKeyboardHandoffCurrent?(keyboardHandoffID) == true
                else {
                    onKeyboardHandoffResult?(keyboardHandoffID, false)
                    return
                }
                onKeyboardHandoffResult?(
                    keyboardHandoffID,
                    view.requestKeyboardHandoff(id: keyboardHandoffID))
            }
        }
        view.applyTheme(theme)
        view.applyFontSize(fontSize)
        view.applyFontFamily(fontFamily)
        view.onFontSizeChanged = onFontSizeChanged
        // Deliberately no viewport read here. A SwiftUI update must not write
        // back into the state it was driven by: reporting the viewport text
        // feeds the Attach Link index, whose observers include this very view,
        // and the update loops on itself until the app is wedged. Terminal
        // output already schedules a snapshot in `receive`.
        view.onOpenLink = { url in openURL(url) }
        view.onPreviewFile = onPreviewFile
        view.onConfirmLink = onConfirmLink
        view.onRefusedFileLink = onRefusedFileLink
        view.knownLinkTargets = knownLinkTargets
    }
}

/// When a terminal re-asserts its Ghostty layer scale after a size change.
///
/// libghostty rebuilds the surface's IOSurface asynchronously. Until its
/// renderer has, the layer's `contentsScale` is derived from the old surface's
/// pixel height over the new point height, and libghostty corrects that drift
/// only after a render it drives itself (`TerminalSurfaceCoordinator`'s
/// `onPostRender`). A terminal with nothing to draw, such as an idle Agent
/// behind a focused Composer with no cursor blink, renders no such frame, so a
/// keyboard raise can leave its content drawn at old-height / new-height of
/// its size in the top-left corner (2/3 on a 13-inch iPad in portrait). A
/// later layout pass sets the scale directly and requests that render.
struct TerminalSurfaceScaleSettle: Equatable, Sendable {
    /// When the follow-up passes run after a size change, in seconds from
    /// that change: once the renderer has had a few frames, and again for a
    /// large surface that takes longer to rebuild.
    static let followUpDelays: [TimeInterval] = [0.1, 0.5]
    private var lastBoundsSize: CGSize?

    /// Records one layout pass at `size`. True when the size changed since
    /// the previous pass, including the first one with a real size. The
    /// follow-up passes themselves keep the size, so they never reschedule.
    mutating func boundsDidLayout(size: CGSize) -> Bool {
        defer { lastBoundsSize = size }
        guard size.width > 0, size.height > 0 else { return false }
        return lastBoundsSize != size
    }
}

/// A grid as the Host is told about it: the columns and rows a resize report
/// carries, with the pixel metrics Ghostty measures them from left behind.
struct TerminalGridSize: Equatable, Sendable, CustomStringConvertible {
    let columns: Int
    let rows: Int

    var description: String { "\(columns)x\(rows)" }
}

/// What the keyboard-transition grid freeze is doing.
///
/// The freeze's edges are lifecycle facts — a keyboard claimed, a settled
/// frame published, the last in-flight callback consumed — but until this
/// existed the only trace of them was *when* resize reports happened to reach
/// the Host. Timing is exactly what cannot be read back: the thaw rides
/// Ghostty's asynchronous resize callbacks, so silence means "still frozen",
/// "nothing to report" and "the engine has not answered yet" all at once, and
/// a caller waiting on reports cannot tell which (#263).
enum TerminalGridReportPhase: Equatable, Sendable {
    /// Reports reach the Host as they arrive.
    case live
    /// Every report is held back; the keyboard is still moving.
    case deferring
    /// The thaw was asked for and is waiting on the callbacks that had
    /// already left Ghostty when it was.
    case flushing
}

/// Bridges Ghostty's sendable session callbacks onto the UI's main-actor
/// closures without making the transport layer depend on Ghostty types.
private final class TerminalResizeSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: UInt64 = 0

    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        latest &+= 1
        return latest
    }

    func current() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }
}

@MainActor
final class TerminalSessionCallbackBridge {
    var onSizeChanged: ((Int, Int) -> Void)?
    var onViewportTextChanged: ((String) -> Void)?
    var onSend: ((Data) -> Void)?
    var onScroll: ((Data, Int) -> Void)?
    var onPaste: ((String, Bool) -> Void)?
    var onViewport: ((InMemoryTerminalViewport) -> Void)?
    var isSizeReportCurrent: ((_ columns: Int, _ rows: Int) -> Bool)?
    var onReliableInput: (() -> Void)?
    var onTerminalInput: ((Data) -> Void)?
    /// Reports every freeze transition. The return to `.live` carries the grid
    /// the thaw forwarded, or `nil` when the freeze had none to forward —
    /// the difference between "the settled grid reached the Host" and "the
    /// freeze ended having told it nothing", which nothing else records.
    var onGridReportPhaseChanged: ((
        _ phase: TerminalGridReportPhase, _ forwarded: TerminalGridSize?
    ) -> Void)?
    nonisolated private let resizeSequence = TerminalResizeSequence()
    /// The report sequence, the freeze and duplicate suppression; see
    /// ``GridReportMachine``.
    private var reports = GridReportMachine()

    /// Derived from the machine the reports obey, so the phase callers
    /// observe cannot drift from it.
    var gridReportPhase: TerminalGridReportPhase {
        reports.gridReportPhase
    }

    init(
        onSizeChanged: ((Int, Int) -> Void)?,
        onViewportTextChanged: ((String) -> Void)?,
        onSend: ((Data) -> Void)?,
        onScroll: ((Data, Int) -> Void)?,
        onPaste: ((String, Bool) -> Void)?
    ) {
        self.onSizeChanged = onSizeChanged
        self.onViewportTextChanged = onViewportTextChanged
        self.onSend = onSend
        self.onScroll = onScroll
        self.onPaste = onPaste
    }

    nonisolated func send(_ data: Data) {
        Task { @MainActor [weak self] in
            self?.onReliableInput?()
            self?.onTerminalInput?(data)
            self?.onSend?(data)
        }
    }

    func scroll(_ sequence: Data, rows: Int) {
        onScroll?(sequence, rows)
    }

    nonisolated func resize(_ viewport: InMemoryTerminalViewport) {
        let sequence = resizeSequence.next()
        Task { @MainActor [weak self] in
            self?.send(.reportArrived(sequence: sequence, viewport: viewport))
        }
    }

    /// Feeds the machine and performs its effects in order. Each callback is
    /// the last effect of its step; its continuation is sent once it returns,
    /// so a callback that re-entered the bridge has already been applied.
    private func send(_ event: GridReportMachine.Event) {
        for effect in reports.handle(event) {
            switch effect {
            case .checkCurrent(let viewport):
                let isCurrent = isSizeReportCurrent?(
                    Int(viewport.columns), Int(viewport.rows)) != false
                send(.currentnessChecked(viewport, isCurrent: isCurrent))
            case .deliverViewport(let viewport):
                onViewport?(viewport)
                send(.viewportDelivered(viewport))
            case .reportSize(let size, let then):
                onSizeChanged?(size.columns, size.rows)
                send(.sizeReported(then: then))
            case .forward(let size, let then):
                guard let onSizeChanged else {
                    send(.forwarded(size, delivered: false, then: then))
                    continue
                }
                onSizeChanged(size.columns, size.rows)
                send(.forwarded(size, delivered: true, then: then))
            case .notifyPhase(let phase, let forwarded, let then):
                onGridReportPhaseChanged?(phase, forwarded)
                send(.phaseNotified(then: then))
            }
        }
    }

    func beginSizeReportDeferral() {
        // A Ghostty resize may already have left its callback thread while its
        // main-actor delivery is still queued. It describes the layout before
        // this freeze and must not become the deferred result merely because
        // its Task happens to run after the handoff begins.
        send(.beginFreeze(latest: resizeSequence.current()))
    }

    func finishSizeReportDeferral() {
        // `resize` crosses onto the main actor asynchronously. Keep the freeze
        // in force until every callback that had already left Ghostty when the
        // thaw was requested has been consumed in sequence.
        send(.finishFreeze(latest: resizeSequence.current()))
    }

    func provideAuthoritativeDeferredSize(columns: Int, rows: Int) {
        send(.provideAuthoritative(TerminalGridSize(columns: columns, rows: rows)))
    }

    /// Tells the Host a grid it may have missed: a cancelled freeze discards
    /// the grid it held, and Ghostty reports again only when the grid
    /// changes. Held like any other report while a freeze is in force; the
    /// engine's matching callback, if still in flight, is consumed once.
    func reportSettledSize(columns: Int, rows: Int) {
        send(.reportSettled(TerminalGridSize(columns: columns, rows: rows)))
    }

    func cancelSizeReportDeferral() {
        send(.cancelFreeze(latest: resizeSequence.current()))
    }

    func paste(_ text: String, bracketed: Bool) {
        onPaste?(text, bracketed)
    }

    func viewportTextDidChange(_ text: String) {
        onViewportTextChanged?(text)
    }
}

private final class TerminalInputTextPosition: UITextPosition {
    let index: Int

    init(index: Int) {
        self.index = index
        super.init()
    }
}

private final class TerminalInputTextRange: UITextRange {
    private let startPosition: TerminalInputTextPosition
    private let endPosition: TerminalInputTextPosition

    override var start: UITextPosition { startPosition }
    override var end: UITextPosition { endPosition }
    override var isEmpty: Bool { startPosition.index == endPosition.index }
    var location: Int { startPosition.index }
    var length: Int { endPosition.index - startPosition.index }

    init(location: Int, length: Int) {
        startPosition = TerminalInputTextPosition(index: location)
        endPosition = TerminalInputTextPosition(index: location + length)
        super.init()
    }
}

/// Where ``WaycarTerminalView`` sends one hardware key press.
enum HardwarePressRoute: Equatable {
    /// ⌘+ / ⌘−: the view steps the terminal zoom and swallows the press.
    case zoom(Float)
    /// Any other ⌘ chord except ⌘Return: past Ghostty, up the responder chain
    /// to the scene's key commands.
    case sceneCommand
    /// Everything else, ⌘Return included: Ghostty, as before.
    case terminal
}

/// Identity of a physical key plus the modifiers that were actually held.
/// `pressesBegan` maps `UIPress` to this and calls
/// ``WaycarTerminalView/beginPhysicalKeyForArmedModifiers(_:token:)`` — the
/// only consume path for hardware presses.
struct ArmedModifierPhysicalKey: Equatable {
    var key: AgentQuickKey
    var physicalModifiers: TerminalKeyModifiers
}

private struct ArmedModifierEchoSuppression {
    let pressToken: ObjectIdentifier
    let expectedInsert: Character?
    let expectBackspace: Bool
}

/// The app-owned seam around libghostty-spm. It keeps keyboard policy and the
/// host-managed session lifecycle out of the SwiftUI screen.
final class WaycarTerminalView: UITerminalView, TerminalByteSink {
    private let callbackBridge: TerminalSessionCallbackBridge
    private let terminalController: TerminalController
    private let clipboard: TerminalClipboard
    let terminalSession: InMemoryTerminalSession
    private(set) var appliedTheme: TerminalTheme
    private(set) var appliedFontSize: Float
    private(set) var appliedFontFamily: String?
    var onFontSizeChanged: ((Float) -> Void)?
    var onOpenLink: ((URL) -> Void)?
    /// Previews a file a tap or the selection menu named. While nil, paths
    /// in the output are plain text.
    var onPreviewFile: ((TerminalFileReference) -> Void)?
    /// Asks before opening a link whose target the user cannot read on
    /// screen, or whose drawn text can pass for another host. While nil,
    /// such links are plain text.
    var onConfirmLink: ((TerminalLinkTarget) -> Void)?
    /// Tells the user a tapped `file:` link names another machine, which is
    /// never read. While nil, such links are plain text.
    var onRefusedFileLink: ((String) -> Void)?
    /// The URLs the Agent's transcript and stream hold whole, read at a
    /// tap to settle a row break the screen alone cannot
    /// (``joinedWebLink(in:hit:found:)``); nil reads the screen alone.
    var knownLinkTargets: (@MainActor () -> AttachKnownTargets)?
    /// Notifies ``TerminalKeyboardControl`` when the touch selection's
    /// handles appear, move, or go away.
    var onTouchSelectionChange: (() -> Void)?
    /// Raises the keyboard once this surface reaches a window. An Agent switch
    /// rebuilds the whole terminal, and the user who tapped a switcher chip
    /// was mid-conversation — dropping the keyboard would hide the switcher
    /// along with it.
    var raisesKeyboardWhenReady = false
    /// Notifies ``TerminalKeyboardControl`` when first-responder intent changes.
    var onFirstResponderChange: (() -> Void)?
    /// One-shot ⌃/⌥/⇧ from the app-owned key surfaces. Physical presses and
    /// `insertText` consult this so an armed modifier applies to the next
    /// hardware key; empty means Ghostty owns the event unchanged.
    weak var keyboardControl: TerminalKeyboardControl?
    /// Notifies ``TerminalScrollControl`` when DECSET alternate-screen state
    /// flips. `refs #268`.
    var onAlternateScreenChange: (() -> Void)?
    /// Notifies ``TerminalScrollControl`` that a touch (drag or momentum),
    /// trackpad, or mouse-wheel scroll moved by at least one row: which way,
    /// and by how many rows. Programmatic steps through
    /// ``scrollRows(towardOlderContent:rows:)`` do not fire it.
    var onTouchScroll: ((_ towardOlderContent: Bool, _ rows: Int) -> Void)?
    /// A tmux pane's copy-mode scroll path, set by ``TerminalScrollControl``:
    /// a scroll goes there whenever no wheel report or alternate-scroll key
    /// would reach the application (``applyScroll(towardOlderContent:rowCount:)``).
    weak var paneHistory: TmuxPaneHistory?
    /// Completes the app-owned inset freeze for a responder handoff after the
    /// terminal's own keyboard frame has settled.
    var onKeyboardHandoffEnded: ((UUID, TerminalKeyboardHandoffOutcome) -> Void)?
    /// How many times the input views have been rebuilt. Nothing else observes
    /// the rebuild that republishes the keyboard's settled frame after a
    /// handoff, and a lost rebuild costs the terminal a toolbar's worth of
    /// height without a crash to show for it.
    private(set) var inputViewRebuildCount = 0
    private var zoomBaseFontSize: Float?
    private var terminalInputView: UIView?
    private var modeTracker = TerminalModeTracker()
    private var lastInputWindowSize: CGSize?
    /// The keyboard-transition freeze: its cycle, the handoff that owns it
    /// and its queued input-view reload; see ``SurfaceKeyboardFreezeMachine``.
    private var keyboardFreeze = SurfaceKeyboardFreezeMachine()
    private var keyboardTransitionFallbackTask: Task<Void, Never>?
    /// Test seam for process-wide keyboard notification ownership. Production
    /// reads the window-local layout guide directly.
    var keyboardLayoutFrameProvider: ((UIWindow) -> CGRect)?
    /// How long an unsettled handoff may keep the grid frozen before the
    /// freeze force-ends anyway — a leash for production, where the settle
    /// signal can fail to arrive. Tests stretch it so a loaded runner cannot
    /// end a handoff out from under them (#225).
    var keyboardTransitionFallbackDelay: TimeInterval = 0.5
    private var keyboardGridReportTask: Task<Void, Never>?
    /// How long Ghostty gets to answer a settled layout before its grid is
    /// forwarded to the Host — long enough to coalesce one layout pass's
    /// several viewport reports into the final one.
    private static let gridSettleDelay: TimeInterval = 0.05
    /// How long the window must keep one size before its grid is forwarded.
    /// Longer than `gridSettleDelay`: a Stage Manager live resize pauses
    /// between drag samples, and every intermediate grid the Host hears is a
    /// full TUI redraw.
    private static let windowResizeSettleDelay: TimeInterval = 0.15
    private var windowResizeTracker = TerminalWindowResizeTracker()
    private var surfaceScaleSettle = TerminalSurfaceScaleSettle()
    private var surfaceScaleSettleTask: Task<Void, Never>?
    /// A window resize froze grid reports and no thaw has forwarded its
    /// settled grid yet. A cancelled freeze must then report it itself.
    private var windowResizeGridIsPending = false
    private var responderGate = TerminalKeyboardResponderGate()
    /// The user's standing wish for the keyboard on this surface. Unlike
    /// `isFirstResponder` it survives UIKit's own resigns (a sheet,
    /// backgrounding) and the deferred release of a retired surface, so a
    /// replacement surface can read what the user last asked for.
    var wantsKeyboard: Bool { responderGate.userWantsKeyboard }
    private var viewportSnapshotTask: Task<Void, Never>?
    private(set) var isLocalInputEnabled = true
    private var textInputStyle = TerminalTextInputStyle.terminal
    private var defaultLeadingAssistantGroups: [UIBarButtonItemGroup]?
    private var defaultTrailingAssistantGroups: [UIBarButtonItemGroup]?
    // Ghostty keeps only marked text in its UITextInput document. UIKit needs
    // committed text to remain in that document so Backspace can observe a
    // shrinking selection and continue its native key repeat.
    private var textInputStorage = ""
    private var textInputSelection = NSRange(location: 0, length: 0)
    private var terminalGridSize = (columns: 80, rows: 24)
    private var hasTerminalGridMetrics = false
    private var terminalCellSize = CGSize(width: 8, height: 16)
    private var touchScrollAccumulator = TerminalTouchScrollAccumulator()
    private var touchScrollMomentumDisplayLink: CADisplayLink?
    private var touchScrollMomentumVelocityY: CGFloat = 0
    private var touchScrollMomentumTimestamp: CFTimeInterval = 0
    /// Presses whose began event was rewritten through armed modifiers, so
    /// Ghostty must not also see their ended/cancelled counterparts.
    private var pressesConsumedByArmedModifiers: Set<ObjectIdentifier> = []
    /// ⌘ presses sent past Ghostty to the scene's key commands. Their
    /// releases follow the same path, so Ghostty never sees a release for a
    /// press it never received.
    private var pressesRoutedToSceneCommands: Set<ObjectIdentifier> = []
    /// Echo de-dup for the originating consumed press only. Cleared on that
    /// press's ended/cancelled, or on any non-matching insert/delete.
    private var echoSuppression: ArmedModifierEchoSuppression?

    private lazy var touchScrollGesture = UIPanGestureRecognizer(
        target: self,
        action: #selector(handleHerdrTouchScrollGesture(_:)))

    /// Trackpad and mouse-wheel scrolling. Ghostty's own wheel recognizer
    /// scrolls through `sendMouseScroll`, which bypasses the paced remote path
    /// and the jump control's scroll signal, so it is disabled with the other
    /// Ghostty pans and this one routes through ``scrollTouch(translationY:)``.
    private lazy var scrollWheelGesture = TerminalScrollEventGestureRecognizer(
        target: self,
        action: #selector(handleHerdrScrollWheelGesture(_:)))

    private lazy var zoomGesture = UIPinchGestureRecognizer(
        target: self,
        action: #selector(handleHerdrZoomGesture(_:)))

    private lazy var tapGesture = UITapGestureRecognizer(
        target: self,
        action: #selector(handleHerdrTap(_:)))

    override var inputView: UIView? {
        terminalInputView
    }

    // Correction traits are pinned .no in every style: a terminal never
    // autocorrects (QuickType turns Space into accept-suggestion AND
    // send-key — double input to the PTY). The Composer pins identical
    // values (see AgentComposerUITextView); matching traits keep one
    // keyboard context across the Direct Input responder transfer
    // (de36399). Only autocapitalization still varies with the style.
    override var autocapitalizationType: UITextAutocapitalizationType {
        get { textInputStyle == .naturalLanguage ? .sentences : .none }
        set {}
    }

    override var beginningOfDocument: UITextPosition {
        guard super.markedTextRange == nil else {
            return super.beginningOfDocument
        }
        return TerminalInputTextPosition(index: 0)
    }

    override var endOfDocument: UITextPosition {
        guard super.markedTextRange == nil else {
            return super.endOfDocument
        }
        return TerminalInputTextPosition(index: textInputStorage.utf16.count)
    }

    override var selectedTextRange: UITextRange? {
        get {
            guard super.markedTextRange == nil else {
                return super.selectedTextRange
            }
            return TerminalInputTextRange(
                location: textInputSelection.location,
                length: textInputSelection.length)
        }
        set {
            guard super.markedTextRange == nil,
                  let range = newValue as? TerminalInputTextRange
            else {
                super.selectedTextRange = newValue
                return
            }
            let length = textInputStorage.utf16.count
            let location = min(max(range.location, 0), length)
            let end = min(max(range.location + range.length, location), length)
            textInputSelection = NSRange(location: location, length: end - location)
        }
    }

    override func textRange(
        from fromPosition: UITextPosition,
        to toPosition: UITextPosition
    ) -> UITextRange? {
        guard super.markedTextRange == nil,
              let from = fromPosition as? TerminalInputTextPosition,
              let to = toPosition as? TerminalInputTextPosition
        else {
            return super.textRange(from: fromPosition, to: toPosition)
        }
        return TerminalInputTextRange(
            location: min(from.index, to.index),
            length: abs(to.index - from.index))
    }

    override func position(
        from position: UITextPosition,
        offset: Int
    ) -> UITextPosition? {
        guard super.markedTextRange == nil,
              let position = position as? TerminalInputTextPosition
        else {
            return super.position(from: position, offset: offset)
        }
        let index = position.index + offset
        guard index >= 0, index <= textInputStorage.utf16.count else { return nil }
        return TerminalInputTextPosition(index: index)
    }

    override func position(
        from position: UITextPosition,
        in direction: UITextLayoutDirection,
        offset: Int
    ) -> UITextPosition? {
        guard position is TerminalInputTextPosition else {
            return super.position(from: position, in: direction, offset: offset)
        }
        return self.position(from: position, offset: offset)
    }

    override func compare(
        _ position: UITextPosition,
        to other: UITextPosition
    ) -> ComparisonResult {
        guard let lhs = position as? TerminalInputTextPosition,
              let rhs = other as? TerminalInputTextPosition
        else {
            return super.compare(position, to: other)
        }
        if lhs.index < rhs.index { return .orderedAscending }
        if lhs.index > rhs.index { return .orderedDescending }
        return .orderedSame
    }

    override func offset(
        from: UITextPosition,
        to toPosition: UITextPosition
    ) -> Int {
        guard let from = from as? TerminalInputTextPosition,
              let to = toPosition as? TerminalInputTextPosition
        else {
            return super.offset(from: from, to: toPosition)
        }
        return to.index - from.index
    }

    override func text(in range: UITextRange) -> String? {
        guard super.markedTextRange == nil,
              let range = range as? TerminalInputTextRange
        else {
            return super.text(in: range)
        }
        let text = textInputStorage as NSString
        guard range.location >= 0, range.length >= 0,
              range.location + range.length <= text.length
        else { return nil }
        return text.substring(
            with: NSRange(location: range.location, length: range.length))
    }

    /// Nothing rides the keyboard any more: the input chrome lives in the app
    /// (see `AgentInputChrome`), where a keyboard-mode switch cannot tear it
    /// down, and where UIKit's candidate-row teardown cannot move it.
    override var inputAccessoryView: UIView? {
        nil
    }

    /// Only the app's tap policy raises the keyboard, so the surface refuses
    /// first responder until asked. The gate tracks the *user's* intent, and
    /// that intent survives a UIKit-initiated resign on purpose: backgrounding
    /// the app or presenting a sheet resigns the first responder, and UIKit
    /// restores it afterwards by asking again. Refusing there would leave the
    /// accessory bar on screen with no keyboard behind it and no way to type.
    /// `dismissKeyboard()` is what clears the intent.
    ///
    /// The gate also refuses mid-touch requests: Ghostty's `touchesEnded`
    /// toggles the keyboard on every body tap, which would take it down
    /// again right after the tap that raised it, or raise it from a tap the
    /// tap policy spent on something else (a link, a flick's halt).
    override var canBecomeFirstResponder: Bool {
        isLocalInputEnabled && responderGate.mayBecomeFirstResponder
    }

    /// UIKit skips the `canBecomeFirstResponder` check when the view already
    /// *is* first responder — and a short backgrounding leaves exactly that
    /// state behind: the keyboard hides but the first responder survives.
    /// Ghostty's `touchesEnded` toggle would then re-present the keyboard
    /// from any body tap, so the gate has to be applied here as well.
    @discardableResult
    override func becomeFirstResponder() -> Bool {
        if isFirstResponder, !responderGate.mayBecomeFirstResponder {
            return true
        }
        let accepted = super.becomeFirstResponder()
        if accepted {
            suppressSceneKeyboardFocus()
        }
        onFirstResponderChange?()
        return accepted
    }

    /// Ghostty's `touchesEnded` dismisses the keyboard after any body tap or
    /// scroll. The accessory's dismiss button is this app's only intended
    /// dismissal, so a resign arriving mid-touch is Ghostty's and is refused;
    /// UIKit's resigns (sheets, backgrounding) arrive outside touch sequences
    /// and pass.
    @discardableResult
    override func resignFirstResponder() -> Bool {
        guard responderGate.mayResignFirstResponder else { return false }
        let resigned = super.resignFirstResponder()
        if resigned {
            restoreSceneKeyboardFocus()
            onFirstResponderChange?()
        }
        return resigned
    }

    /// The collection views this terminal made unfocusable while it holds
    /// the keyboard, handed back when it resigns or leaves its window.
    private var focusSuppressedCollectionViews: [WeakCollectionView] = []
    /// Re-applies the suppression when focus lands anyway, on a List mounted
    /// after the walk (the sidebar revealed or rebuilt).
    private var focusUpdateObserver: (any NSObjectProtocol)?

    private struct WeakCollectionView {
        weak var view: UICollectionView?
    }

    /// On an iPad with a hardware keyboard the focus system takes arrows,
    /// Tab and Return before the first responder: arrows walk a focused
    /// Agent row (moving the List's selection), and Return either activates
    /// the focused item or, with nothing focused, is spent engaging focus.
    /// Either way the terminal never received it (#80). While the terminal
    /// holds the keyboard nothing in its window may take focus, so every key
    /// reaches the PTY; the Agent list becomes focusable again on resign.
    /// iPhone has no focus system, so nothing is walked there.
    private func suppressSceneKeyboardFocus() {
        guard let window, let focusSystem = UIFocusSystem.focusSystem(for: window) else { return }
        suppressCollectionViewFocus(in: window)
        // A row already holding focus keeps it until the system looks again.
        focusSystem.requestFocusUpdate(to: window)
        installFocusUpdateObserver()
    }

    /// Re-runs the suppression while this surface holds the keyboard: the
    /// sidebar's List mounts after the mount-time walk, focusable by
    /// default, and on a hardware-keyboard iPad the focus system would take
    /// arrows, Tab and Return before the terminal sees them (#80). Called
    /// when the sidebar becomes visible; `focusUpdateObserver` is the
    /// backstop for lists that mount without a visibility change.
    func resuppressSceneKeyboardFocus() {
        guard isFirstResponder, let window else { return }
        if suppressCollectionViewFocus(in: window) {
            if let focusSystem = UIFocusSystem.focusSystem(for: window) {
                focusSystem.requestFocusUpdate(to: window)
            }
        }
    }

    private func installFocusUpdateObserver() {
        guard focusUpdateObserver == nil else { return }
        focusUpdateObserver = NotificationCenter.default.addObserver(
            forName: UIFocusSystem.didUpdateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isFirstResponder, let window = self.window,
                      let focusSystem = UIFocusSystem.focusSystem(for: window),
                      focusSystem.focusedItem != nil,
                      // Only a newly suppressed list warrants another update;
                      // focus on anything else would otherwise loop.
                      self.suppressCollectionViewFocus(in: window)
                else { return }
                focusSystem.requestFocusUpdate(to: window)
            }
        }
    }

    /// Makes every focusable collection view in `window` unfocusable and
    /// records it; true when it found one.
    @discardableResult
    private func suppressCollectionViewFocus(in window: UIWindow) -> Bool {
        var found = false
        var stack: [UIView] = [window]
        while let node = stack.popLast() {
            if let collection = node as? UICollectionView, collection.allowsFocus {
                collection.allowsFocus = false
                focusSuppressedCollectionViews.append(WeakCollectionView(view: collection))
                found = true
            }
            stack.append(contentsOf: node.subviews)
        }
        return found
    }

    private func restoreSceneKeyboardFocus() {
        if let focusUpdateObserver {
            NotificationCenter.default.removeObserver(focusUpdateObserver)
            self.focusUpdateObserver = nil
        }
        for entry in focusSuppressedCollectionViews {
            entry.view?.allowsFocus = true
        }
        focusSuppressedCollectionViews = []
    }

    init(
        frame: CGRect,
        onSizeChanged: ((Int, Int) -> Void)?,
        onViewportTextChanged: ((String) -> Void)?,
        onSend: ((Data) -> Void)?,
        onScroll: ((Data, Int) -> Void)?,
        onPaste: ((String, Bool) -> Void)?,
        theme: TerminalTheme,
        fontSize: Float,
        fontFamily: String?,
        clipboard: TerminalClipboard
    ) {
        self.clipboard = clipboard
        let callbackBridge = TerminalSessionCallbackBridge(
            onSizeChanged: onSizeChanged,
            onViewportTextChanged: onViewportTextChanged,
            onSend: onSend,
            onScroll: onScroll,
            onPaste: onPaste)
        self.callbackBridge = callbackBridge
        terminalSession = InMemoryTerminalSession(
            write: { [weak callbackBridge] data in
                callbackBridge?.send(data)
            },
            resize: { [weak callbackBridge] viewport in
                callbackBridge?.resize(viewport)
            },
            suppressesPixelOnlyResizes: true)
        // Font size rides the controller's per-session configuration rather
        // than the surface's one-shot option, so later changes reach the live
        // surface through the same path the initial value took.
        let clampedFontSize = TerminalZoomSettings.clamped(fontSize)
        terminalController = TerminalController(
            theme: theme,
            terminalConfiguration: Self.terminalConfiguration(
                size: clampedFontSize, family: fontFamily))
        appliedTheme = theme
        appliedFontSize = clampedFontSize
        appliedFontFamily = fontFamily
        super.init(frame: frame)
        // The view is its own surface delegate so orphan-layer cleanup runs
        // wherever the view is used, not only under the SwiftUI representable.
        delegate = self
        callbackBridge.onTerminalInput = { [weak self] data in
            self?.recordTerminalInput(data)
        }
        pasteConfiguration = UIPasteConfiguration(forAccepting: String.self)
        inputAccessoryItems = []
        configuration = TerminalSurfaceOptions(backend: .inMemory(terminalSession))
        controller = terminalController
        callbackBridge.isSizeReportCurrent = { [weak self] columns, rows in
            guard let self, hasTerminalGridMetrics else { return true }
            return terminalGridSize.columns == columns && terminalGridSize.rows == rows
        }
        callbackBridge.onReliableInput = { [weak self] in
            self?.reliableInputDidBegin()
        }
        installTouchScrolling()
        installZoom()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func updateCallbacks(
        onSizeChanged: ((Int, Int) -> Void)?,
        onViewportTextChanged: ((String) -> Void)?,
        onSend: ((Data) -> Void)?,
        onScroll: ((Data, Int) -> Void)?,
        onPaste: ((String, Bool) -> Void)?
    ) {
        callbackBridge.onSizeChanged = onSizeChanged
        callbackBridge.onViewportTextChanged = onViewportTextChanged
        callbackBridge.onSend = onSend
        callbackBridge.onScroll = onScroll
        callbackBridge.onPaste = onPaste
    }

    @discardableResult
    func applyTheme(_ theme: TerminalTheme) -> Bool {
        guard theme != appliedTheme, terminalController.setTheme(theme) else {
            return false
        }
        appliedTheme = theme
        return true
    }

    @discardableResult
    func applyFontSize(_ fontSize: Float) -> Bool {
        let clamped = TerminalZoomSettings.clamped(fontSize)
        guard clamped != appliedFontSize,
            terminalController.setTerminalConfiguration(
                Self.terminalConfiguration(
                    size: clamped, family: appliedFontFamily))
        else {
            return false
        }
        appliedFontSize = clamped
        return true
    }

    @discardableResult
    func applyFontFamily(_ family: String?) -> Bool {
        guard family != appliedFontFamily,
            terminalController.setTerminalConfiguration(
                Self.terminalConfiguration(
                    size: appliedFontSize, family: family))
        else {
            return false
        }
        appliedFontFamily = family
        return true
    }

    /// ghostty treats `font-family` as a set that repeated values append to,
    /// so switching fonts has to clear it with an empty value first or the
    /// old family stays in the fallback chain ahead of the new one.
    private static func terminalConfiguration(
        size: Float, family: String?
    ) -> TerminalConfiguration {
        // These surfaces forward keys to a remote application. Host shortcuts
        // (paste, zoom, selection) are handled by UIKit/Waycar, so Ghostty's
        // desktop bindings must not intercept the shared keyboard's chords.
        // Touch selection presses with shift to select over a program that
        // captured the mouse; `never` keeps any program from claiming shift.
        var configuration = TerminalConfiguration()
            .custom("keybind", "clear")
            .custom("mouse-shift-capture", "never")
            .fontSize(size)
            .fontFamily("")
        if let family {
            configuration = configuration.fontFamily(family)
        }
        return configuration
    }

    /// Applies a zoom the user performed on this terminal and reports it, so
    /// the global setting follows the gesture instead of fighting it.
    private func zoom(to fontSize: Float) {
        guard applyFontSize(fontSize) else { return }
        onFontSizeChanged?(appliedFontSize)
    }

    func receive(_ data: Data) {
        let wasAlternateScreen = modeTracker.isAlternateScreen
        let didTrackMouse = modeTracker.tracksMouse
        modeTracker.receive(data)
        if modeTracker.isAlternateScreen != wasAlternateScreen
            || modeTracker.tracksMouse != didTrackMouse
        {
            onAlternateScreenChange?()
        }
        terminalSession.receive(data)
        scheduleViewportSnapshot()
    }

    /// Whether the remote application currently has the alternate screen
    /// active (DECSET 47 / 1047 / 1049). Read by ``TerminalScrollControl``.
    var isAlternateScreen: Bool { modeTracker.isAlternateScreen }

    /// Whether the remote application asked for mouse reporting. Only then can
    /// a scroll step reach its own history: without it, `applyScroll` falls
    /// back to cursor keys, which a non-TUI application reads as input rather
    /// than as scrolling. Read by ``TerminalScrollControl``. `refs #268`.
    var remoteTracksMouse: Bool { modeTracker.tracksMouse }

    /// Rows the grid currently shows, or nil until the surface has reported
    /// real metrics. The jump control sizes its scroll steps from this: a step
    /// larger than the viewport would move content past without it ever being
    /// rendered, and a message in that gap would be skipped. `refs #268`.
    var viewportRows: Int? {
        hasTerminalGridMetrics ? terminalGridSize.rows : nil
    }

    /// Viewport reads are supplemental to raw-stream discovery. Ghostty
    /// parses host output off-main, so coalescing briefly lets redraw bursts
    /// settle without making terminal rendering wait on link collection.
    func reportViewportText() {
        guard let text = terminalSession.readViewportText() else { return }
        callbackBridge.viewportTextDidChange(text)
    }

    private func scheduleViewportSnapshot() {
        viewportSnapshotTask?.cancel()
        viewportSnapshotTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            self?.reportViewportText()
        }
    }

    /// Takes over the keyboard from the terminal this one replaced.
    ///
    /// The keyboard must not drop between the two: it carries the switcher, so
    /// a dip would make every switch flash the row the user is switching from.
    /// So the surface claims first responder in the same pass it reaches the
    /// window — and freezes its grid until UIKit has settled the keyboard,
    /// because Ghostty's first viewport report on a fresh surface carries a
    /// zero cell size. Measured against that half-built grid, the surface
    /// draws a band shorter than the view and leaves an unpainted strip above
    /// the toolbar.
    private func inheritKeyboard() {
        guard raisesKeyboardWhenReady, window != nil else { return }
        raisesKeyboardWhenReady = false
        // A keyboard that never left reports no did-show, only a frame change.
        sendKeyboardFreeze(.inherit)
        raiseKeyboard()
        // Only a first responder is handed the settle signal that ends this
        // freeze (see `notificationSettlesOwnKeyboard`), so a claim UIKit
        // refused leaves nothing that can end it: the grid stays frozen and
        // `layoutSubviews` stays suppressed until the wall-clock leash fires.
        // No keyboard is coming, so end it here on the same terms the leash
        // would have — thawing rather than cancelling, because the surface's
        // first grid still has to reach the Host.
        if !isFirstResponder {
            finishKeyboardTransitionLayout(handoffOutcome: .cancelled)
        }
    }

    /// Whether a hardware keyboard's keys should reach this terminal without
    /// the user asking for the keyboard first: one is attached and this is
    /// an iPad, where plain keys and arrows only reach the first responder.
    /// iPhone has no focus system to satisfy (#80), so its taps keep the
    /// keyboard-off default. The unit-test host reports no hardware
    /// keyboard (`HardwareShiftTracker`); tests that need one inject this.
    var isHardwareKeyboardAutoFocus = true
    var isHardwareKeyboardConnected: @MainActor () -> Bool = {
        HardwareShiftTracker.shared.isKeyboardConnected && UIDevice.current.userInterfaceIdiom == .pad
    }

    /// A hardware keyboard is attached and the terminal takes local input:
    /// claim first responder without raising the on-screen keyboard, so
    /// plain keys and arrows reach the PTY when no other input owns them
    /// (#80). Automatic claims must not replace explicit input such as the
    /// Agent search field. The user's tap keeps its meaning: with the
    /// on-screen keyboard down it raises it as it always has, because the
    /// keyboard is down while this claim holds it. The claim leaves
    /// `userWantsKeyboard` as it is: a wish a UIKit-initiated resign left
    /// pending must survive for UIKit's own restore.
    func claimHardwareKeyboardFocus() {
        guard isHardwareKeyboardAutoFocus, isLocalInputEnabled, !isFirstResponder,
            let window, isHardwareKeyboardConnected(),
            !hasFirstResponder(in: window)
        else { return }
        responderGate.hardwareFocusClaim = true
        responderGate.beginUserDrivenChange(wantsKeyboard: responderGate.userWantsKeyboard)
        _ = becomeFirstResponder()
        responderGate.endUserDrivenChange()
    }

    /// Stay in this window: another scene's input must not block this one.
    private func hasFirstResponder(in view: UIView) -> Bool {
        if view.isFirstResponder { return true }
        return view.subviews.contains { hasFirstResponder(in: $0) }
    }

    /// Re-arms a hardware-keyboard focus claim after the keyboard connects
    /// or the view was covered: plain keys and arrows must reach the surface
    /// the moment it is visible (#80). A user's dismissal ends the claim.
    func rearmHardwareKeyboardFocus() {
        claimHardwareKeyboardFocus()
    }

    /// Raises the keyboard, and records that the user wants it up.
    func requestKeyboard() {
        guard isLocalInputEnabled else { return }
        sendKeyboardFreeze(.requestKeyboard)
        raiseKeyboard()
    }

    /// Transfers an already-visible keyboard to this terminal without
    /// exposing the intermediate layouts UIKit publishes between responders.
    @discardableResult
    func requestKeyboardHandoff(id: UUID) -> Bool {
        guard isLocalInputEnabled, window != nil else { return false }
        sendKeyboardFreeze(.requestHandoff(id))
        raiseKeyboard()
        guard isFirstResponder else {
            cancelKeyboardTransitionLayoutDeferral()
            return false
        }
        return true
    }

    private func raiseKeyboard() {
        responderGate.beginUserDrivenChange(wantsKeyboard: true)
        defer { responderGate.endUserDrivenChange() }
        _ = becomeFirstResponder()
    }

    /// Takes the keyboard down on the user's behalf. This is the *only* way
    /// the keyboard goes away for good: a plain `resignFirstResponder()` is
    /// something UIKit does on its own (backgrounding, a sheet taking focus)
    /// and must stay recoverable.
    ///
    /// Only the first responder may release it. A surface whose keyboard
    /// another responder has already taken over is not first responder any
    /// more, yet resigning it still tears the keyboard down on iOS 27 —
    /// traced on an iPhone 17 Pro Max: a replaced Shell Terminal surface
    /// released its keyboard a turn after its replacement had claimed it,
    /// and the keyboard dropped under the new owner and rose again. The
    /// intent is still recorded, so the surface stays down if it returns.
    @discardableResult
    func dismissKeyboard() -> Bool {
        responderGate.beginUserDrivenChange(wantsKeyboard: false)
        defer { responderGate.endUserDrivenChange() }
        guard isFirstResponder else { return false }
        let resigned = resignFirstResponder()
        // A user's own dismissal ends the hardware-keyboard claim: the next
        // tap raises the keyboard again, as the keyboard button does. UIKit's
        // own resigns (backgrounding, a sheet) keep it, so the plain keys and
        // arrows come back when the surface returns.
        if resigned { responderGate.hardwareFocusClaim = false }
        return resigned
    }

    func setLocalInputEnabled(_ isEnabled: Bool) {
        guard isLocalInputEnabled != isEnabled else { return }
        isLocalInputEnabled = isEnabled
        if !isEnabled {
            cancelKeyboardTransitionLayoutDeferral()
        }
        if !isEnabled, isFirstResponder {
            _ = dismissKeyboard()
        }
    }

    /// Ends local input for a surface leaving the stage or being replaced,
    /// without resigning first responder on the spot.
    ///
    /// `TerminalSurfaceRetention` retires a surface from inside
    /// `makeUIView`, which SwiftUI runs during its attribute-graph update.
    /// Resigning there makes UIKit look for the next responder and ask the
    /// hosting view `canBecomeFirstResponder`, which re-enters the graph and
    /// aborts in AttributeGraph (crash seen live on iOS 27 while switching
    /// between an Agent and a Workspace terminal). Input is refused at once;
    /// the responder itself is released on the next run-loop turn, and only
    /// if nothing re-enabled the surface in between.
    ///
    /// `keepingKeyboard` is the surface leaving for a screen that takes the
    /// keyboard over: it must not resign at all, or the keyboard drops before
    /// the destination can claim it. Leaving the window ends its responder
    /// status regardless, and the destination's claim moves the keyboard
    /// across without a hide.
    func retireLocalInput(keepingKeyboard: Bool = false) {
        setLocalInputEnabledWithoutResigning(false)
        guard !keepingKeyboard else { return }
        DispatchQueue.main.async { [self] in
            guard !isLocalInputEnabled else { return }
            _ = dismissKeyboard()
        }
    }

    private func setLocalInputEnabledWithoutResigning(_ isEnabled: Bool) {
        guard isLocalInputEnabled != isEnabled else { return }
        isLocalInputEnabled = isEnabled
        if !isEnabled {
            cancelKeyboardTransitionLayoutDeferral()
        }
    }

    func setTextInputStyle(_ style: TerminalTextInputStyle) {
        guard textInputStyle != style else { return }
        textInputStyle = style
        applyInputAssistantStyle()
    }

    func installInputAssistantStyle() {
        defaultLeadingAssistantGroups = inputAssistantItem.leadingBarButtonGroups
        defaultTrailingAssistantGroups = inputAssistantItem.trailingBarButtonGroups
        applyInputAssistantStyle()
    }

    private func applyInputAssistantStyle() {
        switch textInputStyle {
        case .terminal:
            inputAssistantItem.leadingBarButtonGroups = []
            inputAssistantItem.trailingBarButtonGroups = []
        case .naturalLanguage:
            inputAssistantItem.leadingBarButtonGroups = defaultLeadingAssistantGroups ?? []
            inputAssistantItem.trailingBarButtonGroups = defaultTrailingAssistantGroups ?? []
        }
    }

    func requestPaste(_ text: String?) {
        guard isLocalInputEnabled, let text else { return }
        reliableInputDidBegin()
        recordCommittedText(text)
        callbackBridge.paste(text, bracketed: usesBracketedPaste)
    }

    /// Soft-keyboard Return arrives here as `"\n"` (UIKeyInput). Direct Input
    /// and Shell treat Enter as PTY CR (`0x0D`), matching shortcut Enter and
    /// `AgentQuickKey.enter` — not LF.
    override func insertText(_ text: String) {
        guard isLocalInputEnabled else { return }
        if consumeMatchingInsertEcho(text) {
            return
        }
        if applyArmedModifiers(toInsertedText: text) {
            return
        }
        if text == "\n" {
            // A hardware keyboard's Return and Shift+Return both reach a
            // terminal on iPadOS as this same "\n", with no key event and no
            // modifiers (#80). The live Shift state tells them apart:
            // Shift+Return is the newline omp and Claude Code bind to Ctrl+J
            // (LF); a plain Return stays the CR that submits. Where the press
            // did arrive, its key path already sent the key and this "\n" is
            // the echo `super` suppresses.
            if Self.isHardwareShiftHeld, !isExpectingHardwareKeyEcho {
                sendQuickKey(.character("j"), modifiers: .control)
                return
            }
            super.insertText("\r")
            return
        }
        super.insertText(text)
    }

    /// Whether a hardware keyboard's Shift is down right now. False without a
    /// hardware keyboard, so the software keyboard's Return is never a newline.
    private static var isHardwareShiftHeld: Bool {
        HardwareShiftTracker.shared.isHeld
    }

    override func deleteBackward() {
        if consumeMatchingBackspaceEcho() {
            return
        }
        guard isLocalInputEnabled else { return }

        // Ghostty already synchronizes marked-text deletion with UIKit. Raw
        // terminal deletion also changes the remote document, so it must send
        // the same notifications or the software keyboard stops key repeat.
        guard markedTextRange == nil else {
            super.deleteBackward()
            return
        }

        guard let deletionRange = textInputDeletionRange() else {
            super.deleteBackward()
            return
        }

        inputDelegate?.textWillChange(self)
        inputDelegate?.selectionWillChange(self)
        deleteFromTextInputStorage(in: deletionRange)
        super.deleteBackward()
        inputDelegate?.selectionDidChange(self)
        inputDelegate?.textDidChange(self)
    }

    private func recordTerminalInput(_ data: Data) {
        guard !data.contains(0x1B), !data.contains(0x7F),
              !data.contains(where: { $0 < 0x20 && $0 != 0x0A && $0 != 0x0D }),
              let text = String(data: data, encoding: .utf8)
        else { return }
        recordCommittedText(text)
    }

    private func recordCommittedText(_ text: String) {
        let storage = NSMutableString(string: textInputStorage)
        storage.replaceCharacters(in: textInputSelection, with: text)
        textInputStorage = storage as String

        if let lineBreak = textInputStorage.rangeOfCharacter(
            from: .newlines, options: .backwards)
        {
            textInputStorage = String(textInputStorage[lineBreak.upperBound...])
        }
        textInputSelection = NSRange(
            location: textInputStorage.utf16.count,
            length: 0)
    }

    private func textInputDeletionRange() -> NSRange? {
        let storage = NSMutableString(string: textInputStorage)
        if textInputSelection.length > 0 {
            return textInputSelection
        }
        guard textInputSelection.location > 0 else { return nil }
        return storage.rangeOfComposedCharacterSequence(
            at: textInputSelection.location - 1)
    }

    private func deleteFromTextInputStorage(in deletionRange: NSRange) {
        let storage = NSMutableString(string: textInputStorage)
        storage.deleteCharacters(in: deletionRange)
        textInputStorage = storage as String
        textInputSelection = NSRange(location: deletionRange.location, length: 0)
    }

    override func paste(_ sender: Any?) {
        guard isLocalInputEnabled, let text = clipboard.string() else { return }

        // The keyboard's clipboard suggestion invokes this standard action
        // directly, bypassing Ghostty's text-input handler. Tell UIKit about
        // the external document change or the IME keeps its pre-paste context
        // and subsequent phonetic input can remain Latin marked text.
        inputDelegate?.textWillChange(self)
        requestPaste(text)
        inputDelegate?.textDidChange(self)
    }

    override func paste(itemProviders: [NSItemProvider]) {
        guard isLocalInputEnabled else { return }
        for provider in itemProviders where provider.canLoadObject(ofClass: NSString.self) {
            provider.loadObject(ofClass: NSString.self) { [weak self] object, _ in
                guard let text = object as? String else { return }
                Task { @MainActor [weak self] in
                    self?.requestPaste(text)
                }
            }
            return
        }
    }

    override func canPaste(_ itemProviders: [NSItemProvider]) -> Bool {
        isLocalInputEnabled
            && itemProviders.contains {
                $0.canLoadObject(ofClass: NSString.self)
            }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) {
            return isLocalInputEnabled && clipboard.hasStrings()
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func reloadInputViews() {
        inputViewRebuildCount += 1
        super.reloadInputViews()
    }

    override func layoutSubviews() {
        guard !keyboardFreeze.isFrozen else { return }
        // Before Ghostty's layout, so the freeze is in force by the time the
        // pass reports its grid.
        deferGridReportsForWindowResize()
        super.layoutSubviews()
        reloadInputViewsAfterWindowResize()
        settleSurfaceScaleAfterResize()
    }

    /// Lays out again after a size change so Ghostty's layer scale is set once
    /// its renderer has rebuilt the surface; see ``TerminalSurfaceScaleSettle``.
    /// The follow-up goes through `layoutSubviews`, so the keyboard and window
    /// resize freezes still apply, and an unchanged grid reports nothing.
    private func settleSurfaceScaleAfterResize() {
        guard surfaceScaleSettle.boundsDidLayout(size: bounds.size) else { return }
        surfaceScaleSettleTask?.cancel()
        surfaceScaleSettleTask = Task { @MainActor [weak self] in
            var elapsed: TimeInterval = 0
            for delay in TerminalSurfaceScaleSettle.followUpDelays {
                try? await Task.sleep(for: .seconds(delay - elapsed))
                elapsed = delay
                guard !Task.isCancelled, let self, self.window != nil else { return }
                self.setNeedsLayout()
                self.layoutIfNeeded()
            }
        }
    }

    /// Stage Manager live resize, like rotation, changes the window's size on
    /// consecutive frames, and Ghostty reports a PTY resize for every grid
    /// that passes by. Those reports go through the same freeze the keyboard
    /// handoff uses: held while the window keeps changing, then forwarded
    /// once, as the grid the window settled on. A keyboard or split-view
    /// column change leaves the window's size alone and reports as before.
    private func deferGridReportsForWindowResize() {
        guard let windowSize = window?.bounds.size,
              windowResizeTracker.windowDidLayout(size: windowSize)
        else { return }
        // A freeze already holding (a keyboard settle still waiting to
        // report, or this burst's previous frame) keeps its deferred grid;
        // re-arming it would throw that grid away.
        if callbackBridge.gridReportPhase != .deferring {
            callbackBridge.beginSizeReportDeferral()
        }
        windowResizeGridIsPending = true
        keyboardGridReportTask?.cancel()
        let settleDelay = Self.windowResizeSettleDelay
        keyboardGridReportTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(settleDelay))
            guard !Task.isCancelled, let self else { return }
            keyboardGridReportTask = nil
            windowResizeGridIsPending = false
            if hasTerminalGridMetrics {
                // Ghostty reports a grid only when it changes, so a burst
                // that returns to a grid it already passed through produces
                // no final callback. The surface's synchronous metrics are
                // the grid the window settled on either way.
                callbackBridge.provideAuthoritativeDeferredSize(
                    columns: terminalGridSize.columns,
                    rows: terminalGridSize.rows)
            }
            callbackBridge.finishSizeReportDeferral()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            // Leaving the window can end responder status without the
            // resign override running; the Agent list must not stay
            // unfocusable for the rest of the session.
            restoreSceneKeyboardFocus()
            stopTouchScrollMomentum()
            responderGate.invalidateTouches()
            surfaceScaleSettleTask?.cancel()
            surfaceScaleSettleTask = nil
        } else {
            inheritKeyboard()
            claimHardwareKeyboardFocus()
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        responderGate.directTouchesBegan(Self.directTouchCount(in: touches))
        super.touchesBegan(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Ghostty's touchesEnded is where its tap-to-dismiss resign fires, so
        // the touches stay counted until super returns.
        super.touchesEnded(touches, with: event)
        responderGate.directTouchesEnded(Self.directTouchCount(in: touches))
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        responderGate.directTouchesEnded(Self.directTouchCount(in: touches))
    }

    private static func directTouchCount(in touches: Set<UITouch>) -> Int {
        touches.count { $0.type == .direct }
    }

    override func gestureRecognizerShouldBegin(
        _ gestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        if gestureRecognizer === touchScrollGesture {
            let velocity = touchScrollGesture.velocity(in: self)
            return abs(velocity.y) > abs(velocity.x)
        }
        if gestureRecognizer === tapGesture {
            return takesTaps
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    /// Whether the surface's own tap recognizer takes a tap. A running flick
    /// claims any tap, to halt itself. A selection on screen owns every other
    /// tap (Ghostty's touch layer shows its menu or dismisses it). Otherwise
    /// every tap is taken, on either buffer and with or without mouse
    /// tracking, and ``tapAction(at:input:)`` decides what it means. Gating
    /// on the terminal's modes here left an Agent the phone sees on the
    /// normal buffer without mouse reporting (omp or pi over mosh, which
    /// never forwards `?1049h`) raising the keyboard only from the caret's
    /// 44 pt band, while the same Agent over SSH answered any tap.
    private var takesTaps: Bool {
        if isTouchScrollMomentumRunning { return true }
        return !hasSelection
    }

    /// A tap that chrome over the surface caught first — the back-swipe
    /// strip along its leading edge — handled as the surface's own tap
    /// recognizer would have, so a path drawn in the first columns still
    /// previews. `location` is in this view's coordinates.
    func handleForwardedTap(at location: CGPoint) {
        guard bounds.contains(location), takesTaps else { return }
        handleTap(at: location)
    }

    private func reloadInputViewsAfterWindowResize() {
        guard let windowSize = window?.bounds.size else { return }
        defer { lastInputWindowSize = windowSize }
        guard let lastInputWindowSize, lastInputWindowSize != windowSize, isFirstResponder else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, self.isFirstResponder else { return }
            UIView.performWithoutAnimation {
                self.reloadInputViews()
            }
        }
    }

    /// Ghostty synchronizes its grid and reports a PTY resize from every
    /// `layoutSubviews` pass, and a keyboard changing hands passes through
    /// several transient heights — both accessories ride the keyboard at once
    /// while it does. Each one would cost a full-screen TUI redraw, so the
    /// grid stays fixed until the keyboard has settled.
    ///
    /// Only a handoff needs this. An ordinary presentation or dismissal moves
    /// in one step, because the terminal sizes itself to the keyboard's own
    /// frame rather than through SwiftUI's two-stage avoidance — see
    /// ``TerminalKeyboardInset``.
    ///
    /// Feeds the freeze machine and performs its effects in order. The
    /// machine has already moved when they run, so a `layoutSubviews` or a
    /// settle that UIKit re-enters synchronously from them sees the new
    /// state, as it always did.
    private func sendKeyboardFreeze(_ event: SurfaceKeyboardFreezeMachine.Event) {
        for effect in keyboardFreeze.handle(event) {
            switch effect {
            case .cancelGridReport:
                keyboardGridReportTask?.cancel()
                keyboardGridReportTask = nil
            case .beginBridgeFreeze:
                callbackBridge.beginSizeReportDeferral()
            case .cancelBridgeFreeze:
                callbackBridge.cancelSizeReportDeferral()
            case .cancelFallback:
                keyboardTransitionFallbackTask?.cancel()
                keyboardTransitionFallbackTask = nil
            case .armFallback(let cycle):
                let fallbackDelay = keyboardTransitionFallbackDelay
                keyboardTransitionFallbackTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(fallbackDelay))
                    guard !Task.isCancelled else { return }
                    self?.sendKeyboardFreeze(.fallbackElapsed(cycle: cycle))
                }
            case .scheduleReload(let cycle):
                // The first owned frame can arrive synchronously from
                // `becomeFirstResponder()`: rebuild only once the handoff's
                // owner has accepted the request.
                DispatchQueue.main.async { [weak self] in
                    self?.sendKeyboardFreeze(.queuedReloadFired(cycle: cycle))
                }
            case .reloadInputViews:
                UIView.performWithoutAnimation { reloadInputViews() }
            case .layoutNow:
                setNeedsLayout()
                layoutIfNeeded()
            case .provideAuthoritativeGrid:
                guard hasTerminalGridMetrics else { continue }
                // A fresh surface can publish its first grid just before the
                // handoff freeze begins. The bridge correctly rejects that
                // queued pre-freeze callback, and libghostty may suppress an
                // identical post-layout callback. Seed the deferral from the
                // surface delegate's synchronous final metrics so Attach
                // still receives its initial size, without letting the stale
                // grid escape.
                callbackBridge.provideAuthoritativeDeferredSize(
                    columns: terminalGridSize.columns,
                    rows: terminalGridSize.rows)
            case .scheduleGridReport:
                scheduleGridReport(after: Self.gridSettleDelay)
            case .reportPendingWindowResizeGrid:
                guard windowResizeGridIsPending else { continue }
                windowResizeGridIsPending = false
                guard hasTerminalGridMetrics else { continue }
                // The cancelled freeze held the grid a window resize settled
                // on. Without this the Host keeps the pre-resize PTY size
                // until the grid happens to change again.
                callbackBridge.reportSettledSize(
                    columns: terminalGridSize.columns,
                    rows: terminalGridSize.rows)
            case .notifyHandoffEnded(let id, let outcome):
                onKeyboardHandoffEnded?(id, outcome)
            }
        }
    }

    private func scheduleGridReport(after delay: TimeInterval) {
        keyboardGridReportTask?.cancel()
        keyboardGridReportTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.keyboardGridReportTask = nil
            // This thaw forwards the authoritative grid, covering any window
            // resize the freeze had absorbed.
            self?.windowResizeGridIsPending = false
            self?.callbackBridge.finishSizeReportDeferral()
        }
    }

    /// The keyboard reached its end frame. An inherited keyboard never leaves,
    /// so this is the only settled signal it gets — there is no did-show to
    /// wait for. Show/hide notifications are process-wide and carry no scene
    /// ownership, so they cannot safely end a handoff. Whose keyboard it is,
    /// the caller answers from the end frame: only one that leaves the
    /// keyboard covering this terminal's own window may thaw the freeze
    /// (#157).
    func keyboardFrameDidSettle() {
        sendKeyboardFreeze(.frameSettled)
    }

    /// Ends the freeze, thawing the grid: the input views are rebuilt for an
    /// inherited keyboard whose queued rebuild never ran (both terminals'
    /// accessories were on the frame it published, and UIKit publishes no
    /// other when the outgoing one leaves), the surface lays out, and the
    /// settled grid is reported shortly after.
    func finishKeyboardTransitionLayout(
        handoffOutcome: TerminalKeyboardHandoffOutcome = .settled
    ) {
        sendKeyboardFreeze(.finish(handoffOutcome))
    }

    private func cancelKeyboardTransitionLayoutDeferral() {
        sendKeyboardFreeze(.cancel)
    }

    var usesApplicationCursorKeys: Bool {
        modeTracker.usesApplicationCursorKeys
    }

    var usesBracketedPaste: Bool {
        modeTracker.usesBracketedPaste
    }

    func setTerminalInputView(_ inputView: UIView?) {
        terminalInputView = inputView
    }

    /// The caret's own row at the standard tap height, in either buffer.
    /// Link taps yield to the keyboard here: it is where a shell draws its
    /// prompt, and `herdr terminal attach` keeps every pane on the
    /// alternate screen, so the band applies there too.
    var inputRowRegion: CGRect {
        TerminalKeyboardTapTarget.region(
            caretRect: caretRect(for: endOfDocument),
            in: bounds,
            minimumHeight: TerminalKeyboardTapTarget.minimumHeight)
    }

    /// Reports a touch as a left click when the remote application asked for
    /// mouse tracking. Returns whether anything was sent.
    @discardableResult
    func clickTouch(at point: CGPoint) -> Bool {
        guard isLocalInputEnabled,
            let cell = gridPointMapper.cell(at: point),
            let report = modeTracker.remoteClickSequence(
                column: cell.column,
                row: cell.row)
        else { return false }

        terminalSession.sendInput(report)
        return true
    }

    /// The grid Ghostty last measured this surface against, or `nil` before
    /// the surface has reported one. This is the value a thawing freeze
    /// forwards to the Host as the settled grid.
    var measuredGrid: TerminalGridSize? {
        guard hasTerminalGridMetrics else { return nil }
        return TerminalGridSize(
            columns: terminalGridSize.columns, rows: terminalGridSize.rows)
    }

    /// Where the keyboard-transition grid freeze currently stands.
    var gridReportPhase: TerminalGridReportPhase {
        callbackBridge.gridReportPhase
    }

    /// Observes the freeze's transitions. See ``TerminalGridReportPhase``.
    var onGridReportPhaseChanged: ((
        _ phase: TerminalGridReportPhase, _ forwarded: TerminalGridSize?
    ) -> Void)? {
        get { callbackBridge.onGridReportPhaseChanged }
        set { callbackBridge.onGridReportPhaseChanged = newValue }
    }

    /// Where Ghostty's grid currently sits inside the view, rebuilt from the
    /// metrics of the last resize.
    var gridPointMapper: TerminalGridPointMapper {
        TerminalGridPointMapper(
            viewSize: bounds.size,
            cellSize: terminalCellSize,
            columns: terminalGridSize.columns,
            rows: terminalGridSize.rows,
            scale: window?.screen.nativeScale ?? traitCollection.displayScale)
    }

    @discardableResult
    func scrollTouch(translationY: CGFloat) -> Int {
        let rows = touchScrollAccumulator.rows(
            for: translationY,
            pointsPerRow: max(8, terminalCellSize.height))
        guard rows != 0 else { return 0 }
        applyScroll(towardOlderContent: rows > 0, rowCount: abs(rows))
        onTouchScroll?(rows > 0, abs(rows))
        return rows
    }

    /// One scroll step of `rowCount` lines for chrome that is not a gesture.
    /// Shares ``applyScroll(towardOlderContent:rowCount:)`` with
    /// ``scrollTouch(translationY:)`` and leaves the touch accumulator alone.
    func scrollRows(towardOlderContent: Bool, rows rowCount: Int) {
        guard rowCount > 0 else { return }
        applyScroll(towardOlderContent: towardOlderContent, rowCount: rowCount)
    }

    /// Test seam observing local Ghostty binding actions from scroll paths.
    var didPerformBindingAction: ((String) -> Void)?

    /// Remote wheel / cursor sequence when the mode tracker supplies one;
    /// else tmux copy mode for a tmux pane (``paneHistory``), whose attach
    /// shows only tmux's redraw; otherwise local `scroll_page_lines`.
    /// Shared by touch and the jump control so they cannot drift.
    /// `refs #268`.
    private func applyScroll(towardOlderContent: Bool, rowCount: Int) {
        if let sequence = modeTracker.remoteScrollSequence(
            towardOlderContent: towardOlderContent,
            columns: terminalGridSize.columns,
            rows: terminalGridSize.rows)
        {
            callbackBridge.scroll(sequence, rows: rowCount)
        } else if let paneHistory {
            paneHistory.scroll(towardOlderContent: towardOlderContent, rows: rowCount)
        } else {
            let localRows = towardOlderContent ? -rowCount : rowCount
            let action = "scroll_page_lines:\(localRows)"
            _ = performBindingAction(action)
            didPerformBindingAction?(action)
        }
    }

    private func installTouchScrolling() {
        // Ghostty's touch pan and its wheel pan both yield to the app's
        // recognizers. The wheel pan's `allowedTouchTypes` is UIKit's default
        // (every type), so it already matches the direct-touch test; the
        // scroll-mask test keeps it off even if Ghostty narrows that list.
        let directTouch = NSNumber(value: UITouch.TouchType.direct.rawValue)
        for case let pan as UIPanGestureRecognizer in gestureRecognizers ?? []
        where pan.allowedTouchTypes.contains(directTouch)
            || !pan.allowedScrollTypesMask.isEmpty
        {
            pan.isEnabled = false
        }

        touchScrollGesture.allowedTouchTypes = [directTouch]
        touchScrollGesture.maximumNumberOfTouches = 1
        touchScrollGesture.cancelsTouchesInView = false
        touchScrollGesture.delegate = self
        addGestureRecognizer(touchScrollGesture)

        addGestureRecognizer(scrollWheelGesture)

        tapGesture.allowedTouchTypes = [directTouch]
        tapGesture.numberOfTouchesRequired = 1
        tapGesture.cancelsTouchesInView = false
        tapGesture.delegate = self
        addGestureRecognizer(tapGesture)
    }

    /// Ghostty ships its own pinch handler that mutates the surface font size
    /// behind the app's back. Zoom has to be app state to persist, so that
    /// gesture steps aside for one that routes through `onFontSizeChanged`.
    private func installZoom() {
        for case let pinch as UIPinchGestureRecognizer in gestureRecognizers ?? [] {
            pinch.isEnabled = false
        }
        addGestureRecognizer(zoomGesture)
    }

    @objc private func handleHerdrZoomGesture(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            zoomBaseFontSize = appliedFontSize
        case .changed:
            guard let zoomBaseFontSize else { return }
            zoom(to: zoomBaseFontSize * Float(gesture.scale))
        case .ended, .cancelled, .failed:
            zoomBaseFontSize = nil
        default:
            break
        }
    }

    /// ⌘+ / ⌘- would otherwise reach Ghostty's own font-size keybinds, which
    /// leaves the global setting stale. Handle them here and swallow both the
    /// press and its release so Ghostty never sees the shortcut.
    ///
    /// Every other ⌘ chord goes up the responder chain instead of to Ghostty,
    /// whose `pressesBegan` never calls super: a text-input first responder
    /// gets key presses before the scene's key commands, so a swallowed chord
    /// would leave every app shortcut dead while the terminal is focused.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let incoming = Set(presses.map(ObjectIdentifier.init))
        if let token = echoSuppression?.pressToken, !incoming.contains(token) {
            echoSuppression = nil
        }
        var forwarded: Set<UIPress> = []
        var sceneCommands: Set<UIPress> = []
        for press in presses {
            if press.key.map({ Self.hardwarePressRoute(for: $0) }) == .sceneCommand {
                pressesRoutedToSceneCommands.insert(ObjectIdentifier(press))
                sceneCommands.insert(press)
                continue
            }
            guard let step = Self.zoomShortcutStep(for: press) else {
                if let key = press.key,
                    let physical = Self.physicalKey(
                        keyCode: key.keyCode,
                        characters: key.characters,
                        charactersIgnoringModifiers: key.charactersIgnoringModifiers,
                        modifierFlags: key.modifierFlags),
                    beginPhysicalKeyForArmedModifiers(
                        physical, token: ObjectIdentifier(press))
                {
                    pressesConsumedByArmedModifiers.insert(ObjectIdentifier(press))
                    continue
                }
                forwarded.insert(press)
                continue
            }
            zoom(to: appliedFontSize + step)
        }
        if !sceneCommands.isEmpty {
            next?.pressesBegan(sceneCommands, with: event)
        }
        guard !forwarded.isEmpty else { return }
        super.pressesBegan(forwarded, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let sceneCommands = presses.filter { forgetSceneCommandPress($0) }
        if !sceneCommands.isEmpty {
            next?.pressesEnded(sceneCommands, with: event)
        }
        let forwarded = presses.subtracting(sceneCommands).filter { press in
            let consumed = forgetConsumedArmedModifierPress(press)
            endPhysicalKeyForArmedModifiers(token: ObjectIdentifier(press))
            return Self.zoomShortcutStep(for: press) == nil && !consumed
        }
        guard !forwarded.isEmpty else { return }
        super.pressesEnded(Set(forwarded), with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Filter only presses this feature consumed. Zoom ⌘+/⌘− cancellations
        // must reach the superclass exactly as they did before this override.
        let sceneCommands = presses.filter { forgetSceneCommandPress($0) }
        if !sceneCommands.isEmpty {
            next?.pressesCancelled(sceneCommands, with: event)
        }
        var forwarded: Set<UIPress> = []
        for press in presses.subtracting(sceneCommands) {
            let consumed = forgetConsumedArmedModifierPress(press)
            cancelPhysicalKeyForArmedModifiers(token: ObjectIdentifier(press))
            if !consumed {
                forwarded.insert(press)
            }
        }
        guard !forwarded.isEmpty else { return }
        super.pressesCancelled(Set(forwarded), with: event)
    }

    /// Applies a one-shot ⌃/⌥/⇧, unioned with modifiers the physical key
    /// already held. Returns false when nothing is armed, or when encoding
    /// the key fails, so Ghostty still receives the original event. A failed
    /// send leaves the armed set in place for a later key the encoder can
    /// represent.
    @discardableResult
    func applyArmedModifiers(
        to key: AgentQuickKey,
        physicalModifiers: TerminalKeyModifiers = []
    ) -> Bool {
        guard let keyboardControl, !keyboardControl.pendingModifiers.isEmpty else {
            return false
        }
        return keyboardControl.sendQuickKey(key, combining: physicalModifiers)
    }

    /// The only consume path `pressesBegan` uses. Tests drive the same seam
    /// with `(key identity, physical modifier flags)` because `UIPress` cannot
    /// be constructed in the suite.
    @discardableResult
    func beginPhysicalKeyForArmedModifiers(
        _ key: ArmedModifierPhysicalKey,
        token: ObjectIdentifier
    ) -> Bool {
        guard applyArmedModifiers(to: key.key, physicalModifiers: key.physicalModifiers) else {
            return false
        }
        switch key.key {
        case .character(let character):
            echoSuppression = ArmedModifierEchoSuppression(
                pressToken: token, expectedInsert: character, expectBackspace: false)
        case .backspace:
            echoSuppression = ArmedModifierEchoSuppression(
                pressToken: token, expectedInsert: nil, expectBackspace: true)
        default:
            echoSuppression = ArmedModifierEchoSuppression(
                pressToken: token, expectedInsert: nil, expectBackspace: false)
        }
        return true
    }

    func endPhysicalKeyForArmedModifiers(token: ObjectIdentifier) {
        clearEchoSuppression(for: token)
    }

    func cancelPhysicalKeyForArmedModifiers(token: ObjectIdentifier) {
        clearEchoSuppression(for: token)
    }

    /// Maps a hardware `UIKey` to the press seam. ⌘ chords return nil so they
    /// are never intercepted. Printable identity prefers `characters` so
    /// Shift+c stays `"C"`. Characters the Ghostty US-key encoder cannot
    /// represent also return nil; `applyArmedModifiers` still refuses a
    /// failed send so an unmapped or unencodable press is forwarded.
    static func physicalKey(
        keyCode: UIKeyboardHIDUsage,
        characters: String,
        charactersIgnoringModifiers: String,
        modifierFlags: UIKeyModifierFlags
    ) -> ArmedModifierPhysicalKey? {
        guard !modifierFlags.contains(.command),
            let identity = quickKey(
                keyCode: keyCode,
                characters: characters,
                charactersIgnoringModifiers: charactersIgnoringModifiers)
        else { return nil }
        return ArmedModifierPhysicalKey(
            key: identity,
            physicalModifiers: physicalModifiers(from: modifierFlags))
    }

    private func applyArmedModifiers(toInsertedText text: String) -> Bool {
        if text == "\n" || text == "\r" {
            return applyArmedModifiers(to: .enter)
        }
        guard text.count == 1, let character = text.first else { return false }
        return applyArmedModifiers(to: .character(character))
    }

    private func consumeMatchingInsertEcho(_ text: String) -> Bool {
        guard let suppression = echoSuppression else { return false }
        if text.count == 1, text.first == suppression.expectedInsert {
            echoSuppression = nil
            return true
        }
        echoSuppression = nil
        return false
    }

    private func consumeMatchingBackspaceEcho() -> Bool {
        guard let suppression = echoSuppression else { return false }
        if suppression.expectBackspace {
            echoSuppression = nil
            return true
        }
        echoSuppression = nil
        return false
    }

    private func clearEchoSuppression(for pressToken: ObjectIdentifier) {
        if echoSuppression?.pressToken == pressToken {
            echoSuppression = nil
        }
    }

    private func forgetSceneCommandPress(_ press: UIPress) -> Bool {
        pressesRoutedToSceneCommands.remove(ObjectIdentifier(press)) != nil
    }

    private func forgetConsumedArmedModifierPress(_ press: UIPress) -> Bool {
        pressesConsumedByArmedModifiers.remove(ObjectIdentifier(press)) != nil
    }

    private static func physicalModifiers(
        from flags: UIKeyModifierFlags
    ) -> TerminalKeyModifiers {
        var modifiers = TerminalKeyModifiers()
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.alternate) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
    }

    private static func printableCharacter(_ string: String) -> Character? {
        guard string.count == 1, let character = string.first,
            !character.unicodeScalars.contains(where: {
                $0.properties.generalCategory == .control
            })
        else {
            return nil
        }
        return character
    }

    private static func quickKey(
        keyCode: UIKeyboardHIDUsage,
        characters: String,
        charactersIgnoringModifiers: String
    ) -> AgentQuickKey? {
        switch keyCode {
        case .keyboardEscape: return .escape
        case .keyboardTab: return .tab
        case .keyboardReturnOrEnter: return .enter
        case .keyboardDeleteOrBackspace: return .backspace
        case .keyboardDeleteForward: return .forwardDelete
        case .keyboardLeftArrow: return .left
        case .keyboardRightArrow: return .right
        case .keyboardUpArrow: return .up
        case .keyboardDownArrow: return .down
        case .keyboardHome: return .home
        case .keyboardEnd: return .end
        case .keyboardPageUp: return .pageUp
        case .keyboardPageDown: return .pageDown
        case .keyboardInsert: return .insert
        case .keyboardF1: return .function(.f1)
        case .keyboardF2: return .function(.f2)
        case .keyboardF3: return .function(.f3)
        case .keyboardF4: return .function(.f4)
        case .keyboardF5: return .function(.f5)
        case .keyboardF6: return .function(.f6)
        case .keyboardF7: return .function(.f7)
        case .keyboardF8: return .function(.f8)
        case .keyboardF9: return .function(.f9)
        case .keyboardF10: return .function(.f10)
        case .keyboardF11: return .function(.f11)
        case .keyboardF12: return .function(.f12)
        default:
            if let character = printableCharacter(characters)
                ?? printableCharacter(charactersIgnoringModifiers),
                TerminalKeyPress(typing: character) != nil
            {
                return .character(character)
            }
            return nil
        }
    }

    private static func zoomShortcutStep(for press: UIPress) -> Float? {
        guard let key = press.key,
            case .zoom(let step) = hardwarePressRoute(for: key)
        else { return nil }
        return step
    }

    private static func hardwarePressRoute(for key: UIKey) -> HardwarePressRoute {
        hardwarePressRoute(
            charactersIgnoringModifiers: key.charactersIgnoringModifiers,
            modifierFlags: key.modifierFlags)
    }

    /// Where a hardware press goes. ⌘+ / ⌘− step the zoom here, any other ⌘
    /// chord belongs to the scene's key commands, and everything else,
    /// including Ctrl, Esc, and arrows, reaches Ghostty unchanged.
    ///
    /// ⌘Return is the exception among the ⌘ chords: it is a submit in the
    /// terminal, and Ghostty sends it as a plain Return. Kept here so it also
    /// submits in Shell and Workspace terminals, which register no Console
    /// commands; where iPadOS delivers no press, an Agent terminal gets the
    /// same Return from the Send command instead (#80).
    static func hardwarePressRoute(
        charactersIgnoringModifiers: String,
        modifierFlags: UIKeyModifierFlags
    ) -> HardwarePressRoute {
        guard modifierFlags.contains(.command) else { return .terminal }
        switch charactersIgnoringModifiers {
        case "+", "=": return .zoom(1)
        case "-", "_": return .zoom(-1)
        case "\r": return .terminal
        default: return .sceneCommand
        }
    }

    /// The tap recognizer above reports taps to a program tracking the
    /// mouse; Ghostty's own tap click would report each one a second time.
    override var sendsTapClicksToSurface: Bool {
        false
    }

    override func touchSelectionWillBegin() {
        stopTouchScrollMomentum()
        touchScrollAccumulator.reset()
    }

    override var isHostMomentumScrolling: Bool {
        isTouchScrollMomentumRunning
    }

    override func touchSelectionHandlesDidChange() {
        onTouchSelectionChange?()
    }

    /// Open Link or Preview when the selection is exactly a link. Selected
    /// text is on screen, so it opens directly — except what a tap on it
    /// would confirm too: a `file:` URL, a web link whose host its text can
    /// disguise, or a path that climbs back out of a name with `..`.
    override func touchSelectionMenuElements(
        forSelectedText text: String
    ) -> [UIMenuElement] {
        let action = selectionLinkAction(forSelectedText: text)
        let target: TerminalLinkTarget
        switch action {
        case .openLink(let found), .confirmLink(let found):
            target = found
        case .haltMomentum, .report, .refuseFile, nil:
            return []
        }
        let (title, symbol) = target.isFile ? ("Preview", "eye") : ("Open Link", "safari")
        return [
            UIAction(title: title, image: UIImage(systemName: symbol)) { [weak self] _ in
                self?.performLinkAction(action)
            }
        ]
    }

    /// What the selection menu does with `text` when it is exactly a link:
    /// the same decision as a tap on link text drawn on screen. A selection
    /// over more than one row is a link only when it covers exactly a path
    /// broken across them (``selectedPathRun()``), read whole.
    func selectionLinkAction(forSelectedText text: String) -> TerminalTapAction? {
        var raw = text
        if text.trimmingCharacters(in: .whitespacesAndNewlines).contains(where: \.isNewline) {
            guard let run = selectedPathRun() else { return nil }
            raw = run.text
        }
        guard let target = TerminalLinkTarget(raw) else { return nil }
        return linkAction(for: target, raw: raw, isVisibleText: true)
    }

    @objc private func handleHerdrTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        handleTap(at: gesture.location(in: self))
    }

    func handleTap(at location: CGPoint) {
        let action = tapAction(at: location)
        switch action {
        case .haltMomentum:
            stopTouchScrollMomentum()
            touchScrollAccumulator.reset()
        case .openLink, .confirmLink, .refuseFile:
            openTappedLink(action, at: location)
        case .report(let raisesKeyboard):
            clickTouch(at: location)
            if raisesKeyboard {
                requestKeyboard()
            }
        }
    }

    /// A mouse or trackpad click on a link opens it as a finger tap would,
    /// and Ghostty never sees the click: herdr keeps mouse tracking on, so
    /// the program would otherwise take it and the link would never open.
    /// Every other click stays Ghostty's to report or select with.
    override func claimPointerClick(
        at point: CGPoint,
        modifiers: TerminalInputModifiers
    ) -> (@MainActor () -> Void)? {
        let action = tapAction(at: point, input: .pointer(modifiers: modifiers))
        switch action {
        case .openLink, .confirmLink, .refuseFile:
            return { [weak self] in self?.openTappedLink(action, at: point) }
        case .haltMomentum, .report:
            return nil
        }
    }

    private func openTappedLink(_ action: TerminalTapAction, at location: CGPoint) {
        flashLink(at: location)
        performLinkAction(action)
    }

    /// What a tap means, given what the terminal is currently doing.
    ///
    /// Any settled tap on the surface asks for the keyboard: the user taps the
    /// terminal to type into it, wherever the caret or the TUI's own input box
    /// happens to be parked. The earlier caret-band / alternate-screen policy
    /// (caret bands per #90, the bottom quarter, and #92's whole-screen trial)
    /// is superseded by that intent. Scrolling is untouched: pans stay with the
    /// touch-scroll gesture recognizer, and a tap that only stops a running
    /// flick answers with momentum halt instead of a keyboard raise. A tap on
    /// link text opens the link instead, and neither clicks nor raises the
    /// keyboard — except on the input row (``inputRowRegion``), where a
    /// shell draws its prompt: a prompt's own path (`~/code/app$`) is a link
    /// to Ghostty, and a tap there has always meant "let me type".
    ///
    /// In Composer mode the raise is a no-op: `requestKeyboard()` refuses
    /// surfaces without local input, and the Composer field owns the keyboard.
    ///
    /// A mouse or trackpad click (`.pointer`) is a link's on the same terms,
    /// and otherwise Ghostty's, which reports it or selects with it as it
    /// always has (`.report(raisesKeyboard: false)`). A click with a
    /// modifier held is always Ghostty's — ⌘-click opens a link its own way
    /// — as is one while a selection is up or a flick is running.
    func tapAction(at location: CGPoint, input: TerminalTapInput = .touch) -> TerminalTapAction {
        if case .pointer(let modifiers) = input {
            guard modifiers.isDisjoint(with: Self.pointerClickModifiers),
                  !hasSelection, !isTouchScrollMomentumRunning,
                  !inputRowRegion.contains(location),
                  let link = tapLink(at: location)
            else { return .report(raisesKeyboard: false) }
            return link
        }
        if isTouchScrollMomentumRunning { return .haltMomentum }
        if inputRowRegion.contains(location) { return .report(raisesKeyboard: true) }
        if let link = tapLink(at: location) { return link }
        return .report(raisesKeyboard: true)
    }

    /// The modifiers that make a pointer click Ghostty's own; caps lock and
    /// num lock do not.
    private static let pointerClickModifiers: TerminalInputModifiers = [
        .shift, .ctrl, .alt, .super_, .shiftRight, .ctrlRight, .altRight, .superRight,
    ]

    /// What a tap at `location` does with a link there: `.openLink` for a
    /// web link the policy allows or a previewable path whose text is its
    /// target, `.confirmLink` for one the screen does not faithfully show (an
    /// OSC 8 target that differs from its text, any `file:` URL, a web link
    /// with userinfo or a non-ASCII authority, a path that climbs back out
    /// of a name with `..`), `.refuseFile` for a `file:` link to another
    /// machine. Ghostty finds it — an OSC 8 target first,
    /// then URL and path text, soft wraps included — and
    /// ``TerminalLinkTarget`` decides what it may be. Text Ghostty cannot
    /// see whole is read off the grid: a web link broken across rows
    /// (``joinedWebLink(in:hit:found:)``) and path text
    /// (``drawnFile(in:matched:)``).
    func tapLink(at location: CGPoint) -> TerminalTapAction? {
        let hit = linkHit(at: location)
        let found = hit.flatMap { TerminalLinkTarget($0.target) }
        // Only text drawn on screen is read off the grid — and an OSC 8
        // web link's label a cursor move split (Kilo's answer), which opens
        // as drawn only where the joined rows spell its target.
        let drawn = hit?.isVisibleText != false
        var labelsWebTarget = false
        if case .web? = found { labelsWebTarget = !drawn }
        if drawn || labelsWebTarget, let rows = pathRun(at: location, joiningRowsShortOfEdge: true),
           let joined = joinedWebLink(in: rows, hit: hit, found: found)
        {
            return linkAction(for: joined.target, raw: joined.raw, isVisibleText: true)
        }
        let run = drawn ? pathRun(at: location)?.keepingPathBreaks : nil
        if let hit, let found,
           !found.isFile || !hit.isVisibleText || TerminalLinkTarget.isFileURL(hit.target)
        {
            return linkAction(for: found, raw: hit.target, isVisibleText: hit.isVisibleText)
        }
        if let hit, found == nil,
           let host = TerminalLinkTarget.otherMachine(ofFileURL: hit.target)
        {
            return onPreviewFile == nil || onRefusedFileLink == nil ? nil : .refuseFile(host: host)
        }
        // Any other refused OSC 8 target (`ssh:`) under other text is no
        // link, whatever that text reads as.
        if let hit, found == nil, !hit.isVisibleText { return nil }
        var matched: TerminalFileReference?
        if case .file(let file)? = found { matched = file }
        guard let drawn = drawnFile(in: run, matched: matched) else { return nil }
        return linkAction(for: .file(drawn.file), raw: drawn.raw, isVisibleText: drawn.isVisibleText)
    }

    /// A web link `herdr terminal attach` or an agent TUI broke across rows
    /// with no soft wrap, read whole from the path run around the tap: on
    /// a narrow grid Ghostty's matcher sees only the tapped row's fragment,
    /// and the head alone opens a truncated URL. The run joins rows however
    /// far short of the edge or their frame their text ends (OpenCode and
    /// Kilo wrap a URL at a `/` or `-` well before it), each break marked
    /// near the edge or not and placed on the grid. The URL starts at
    /// Ghostty's web match drawn on the tapped row, or else — tapped on a
    /// row Ghostty matched no web link on (nothing, a path, `ss-audit/x`,
    /// a bare `https://`), or on an OSC 8 link whose label is split — at
    /// the nearest scheme on that row or one above. Each row break carries
    /// it on only by the link scanner's own rule (``AttachLinkRowJoin``),
    /// told whether that row ended near the edge, where on the grid the
    /// break falls, and the URLs the Agent's transcript and stream hold
    /// whole (``knownLinkTargets``), so the tap and the Attach Links list
    /// read a screen alike: the next row stays apart when it starts a path
    /// or link of its own, a bracket or a backtick, or holds no letter or
    /// number; at the edge, a URL that fit its row stays apart from
    /// `README.md`, `follow-up` or `10:30` it could have shared the next
    /// row with, while one cut mid-word runs on; short of the edge, it runs
    /// on only after a `-`-like mark, or a `/` or `.` above a word with a
    /// `/` or a query, or where a known URL runs on. The tapped row must be
    /// part of what is carried. Drawn on screen, the joined text, sentence
    /// punctuation aside, opens on the same terms as a link on one row; an
    /// OSC 8 link's only where it is the link's target.
    private func joinedWebLink(
        in run: TerminalPathRun,
        hit: TerminalLinkHit?,
        found: TerminalLinkTarget?
    ) -> (target: TerminalLinkTarget, raw: String)? {
        guard run.spansRows else { return nil }
        let first: Int
        var url: String
        if case .web? = found, let hit, hit.isVisibleText {
            guard let start = run.rowText.range(of: hit.target)?.lowerBound else { return nil }
            first = run.tappedRow
            url = String(run.rowText[start...])
        } else {
            guard let head = run.rows[...run.tappedRow].lastIndex(where: { $0.contains("://") }),
                  let scheme = run.rows[head].range(of: "://")
            else { return nil }
            let text = run.rows[head]
            var start = scheme.lowerBound
            while start > text.startIndex, text[text.index(before: start)].isLetter {
                start = text.index(before: start)
            }
            first = head
            url = String(text[start...])
        }
        var last = first
        let columns = measuredGrid?.columns
        let known = knownLinkTargets?() ?? AttachKnownTargets()
        while last + 1 < run.rows.count,
              AttachLinkRowJoin.continues(
                  headWord: Substring(url),
                  nextRowText: Substring(run.layouts[last + 1].text),
                  endsNearEdge: run.layouts[last].endsNearEdge,
                  columns: columns,
                  placement: run.placement(after: last),
                  known: known)
        {
            last += 1
            url += run.rows[last]
        }
        guard last > first, last >= run.tappedRow else { return nil }
        let raw = TerminalLinkTarget.trimmingSurroundingPunctuation(url)
        if let hit, !hit.isVisibleText, raw != hit.target { return nil }
        guard let target = TerminalLinkTarget(raw), case .web = target else { return nil }
        return (target, raw)
    }

    /// The file path drawn in `run`, the path run under the tap cut where
    /// a word wrapper only broke a row (``TerminalPathRun/keepingPathBreaks``),
    /// with the text it was read from and the row's own reading to fall
    /// back on. A path broken across rows comes first: `herdr terminal attach`
    /// repaints a pane by cursor moves and agent TUIs wrap their own text,
    /// so on a phone's narrow grid
    /// Ghostty's matcher sees one row's fragment of most absolute paths, or
    /// nothing where the fragment has no slash. The row's own match follows,
    /// for a path that only ended at the edge; where Ghostty matched nothing,
    /// a bare media file name (`shot.png`) stands in for it — unless the row
    /// holds the tail of an earlier row's word. The joined reading is only
    /// taken where the tapped fragment could be part of a path, so a word
    /// or a rule under a path at the edge stays plain text; a `file:` URL
    /// joined across rows is returned alone, with its text, to be confirmed.
    /// A joined path holds the tapped text itself, extended only by the
    /// text drawn at a row edge next to it; one that climbs back out of a
    /// name with `..` is confirmed like any other path that does.
    private func drawnFile(
        in run: TerminalPathRun?,
        matched: TerminalFileReference?
    ) -> (file: TerminalFileReference, raw: String, isVisibleText: Bool)? {
        guard onPreviewFile != nil else { return nil }
        guard let run else { return matched.map { ($0, $0.path, true) } }
        var own = matched
        if own == nil, !run.continuesFromPreviousRow, !run.rowText.contains("/"),
           !TerminalLinkTarget.isFileURL(run.rowText),
           case .file(let bare)? = TerminalLinkTarget(run.rowText)
        {
            own = bare
        }
        if run.spansRows, own != nil || run.rowText.contains(where: { "/.~".contains($0) }),
           case .file(let joined)? = TerminalLinkTarget(run.text)
        {
            if TerminalLinkTarget.isFileURL(run.text) { return (joined, run.text, true) }
            var fallbacks: [String] = []
            if let own, own.path != joined.path { fallbacks.append(own.path) }
            return (joined.fallingBack(to: fallbacks), joined.path, true)
        }
        return own.map { ($0, $0.path, true) }
    }

    /// Opens a link directly only when the screen shows where it leads.
    /// Anything else is asked about first: a target that is not the text
    /// drawn, a `file:` URL, a web link that can disguise its host, and a
    /// path that climbs back out of a name it draws with `..`
    /// (``TerminalFileReference/climbsBackOut``) — remote output could hang
    /// `/../../.ssh/id_ed25519` off a harmless `shot.png` across a row break
    /// or a blank, and a tap on `shot.png` would read the key. A confirmed
    /// file is read at the one path the confirmation names, no fallback.
    private func linkAction(
        for target: TerminalLinkTarget,
        raw: String,
        isVisibleText: Bool
    ) -> TerminalTapAction? {
        var climbsBackOut = false
        if case .file(let file) = target {
            guard onPreviewFile != nil else { return nil }
            climbsBackOut = file.climbsBackOut
        }
        guard isVisibleText, !climbsBackOut,
              !TerminalLinkTarget.isFileURL(raw),
              !TerminalLinkTarget.disguisesItsHost(raw)
        else {
            guard onConfirmLink != nil else { return nil }
            if case .file(let file) = target { return .confirmLink(.file(file.fallingBack(to: []))) }
            return .confirmLink(target)
        }
        return .openLink(target)
    }

    private func performLinkAction(_ action: TerminalTapAction?) {
        switch action {
        case .openLink(.web(let url)):
            onOpenLink?(url)
        case .openLink(.file(let file)):
            onPreviewFile?(file)
        case .confirmLink(let target):
            onConfirmLink?(target)
        case .refuseFile(let host):
            onRefusedFileLink?(host)
        case .haltMomentum, .report, nil:
            break
        }
    }

    var isTouchScrollMomentumRunning: Bool {
        touchScrollMomentumDisplayLink != nil
    }

    @objc private func handleHerdrTouchScrollGesture(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            stopTouchScrollMomentum()
            touchScrollAccumulator.reset()
        case .changed:
            _ = scrollTouch(translationY: gesture.translation(in: self).y)
            gesture.setTranslation(.zero, in: self)
        case .ended:
            startTouchScrollMomentum(velocityY: gesture.velocity(in: self).y)
        case .cancelled, .failed:
            stopTouchScrollMomentum()
            touchScrollAccumulator.reset()
        default:
            break
        }
    }

    /// A trackpad scroll ends when the fingers lift. No flick momentum is
    /// synthesized after it: a mouse wheel reaches this recognizer the same way
    /// and would overshoot every notch. The row remainder survives between
    /// gestures so slow notches on a zoomed-in grid still add up to a row; the
    /// accumulator drops it on a direction change.
    @objc private func handleHerdrScrollWheelGesture(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            stopTouchScrollMomentum()
            fallthrough
        case .changed, .ended:
            _ = scrollTouch(translationY: gesture.translation(in: self).y)
            gesture.setTranslation(.zero, in: self)
        case .cancelled, .failed:
            touchScrollAccumulator.reset()
        default:
            break
        }
    }

    func startTouchScrollMomentum(velocityY: CGFloat) {
        guard abs(velocityY) >= 80 else {
            touchScrollAccumulator.reset()
            return
        }
        stopTouchScrollMomentum()
        touchScrollMomentumVelocityY = max(-4_000, min(4_000, velocityY))
        touchScrollMomentumTimestamp = 0
        let displayLink = CADisplayLink(
            target: self,
            selector: #selector(advanceTouchScrollMomentum(_:)))
        touchScrollMomentumDisplayLink = displayLink
        displayLink.add(to: .main, forMode: .common)
    }

    @objc private func advanceTouchScrollMomentum(_ displayLink: CADisplayLink) {
        guard abs(touchScrollMomentumVelocityY) >= 20 else {
            stopTouchScrollMomentum()
            touchScrollAccumulator.reset()
            return
        }
        guard touchScrollMomentumTimestamp > 0 else {
            touchScrollMomentumTimestamp = displayLink.timestamp
            return
        }

        let elapsed = min(1.0 / 30.0, displayLink.timestamp - touchScrollMomentumTimestamp)
        touchScrollMomentumTimestamp = displayLink.timestamp
        _ = scrollTouch(translationY: touchScrollMomentumVelocityY * elapsed)
        touchScrollMomentumVelocityY *= pow(0.998, elapsed * 1_000)
    }

    private func stopTouchScrollMomentum() {
        touchScrollMomentumDisplayLink?.invalidate()
        touchScrollMomentumDisplayLink = nil
        touchScrollMomentumVelocityY = 0
        touchScrollMomentumTimestamp = 0
    }

    private func reliableInputDidBegin() {
        stopTouchScrollMomentum()
        touchScrollAccumulator.reset()
    }

    /// Stops inertial remote scroll. App-owned Esc no longer goes through
    /// Ghostty `sendInput`, so it calls this instead of relying on that hook.
    func noteReliableInputBegan() {
        reliableInputDidBegin()
    }

    /// Stops a coasting flick. A jump control pressed mid-flick calls this: a
    /// tap on SwiftUI chrome never reaches the terminal's own tap-to-halt, and
    /// the next momentum row would cancel the jump it started. `refs #58`.
    func haltTouchScrollMomentum() {
        reliableInputDidBegin()
    }
}

extension TerminalPathRun {
    /// Where the break after row `row` falls on the grid, as the link and
    /// media scanners place a break they read off the viewport.
    fileprivate func placement(after row: Int) -> AttachLinkRowJoin.Placement {
        let head = layouts[row]
        return AttachLinkRowJoin.Placement(
            headStart: head.wordStart, headEnd: head.end, edge: head.edge,
            nextStart: layouts[row + 1].textStart)
    }

    /// The rows around the tapped one a path runs on across, read top down
    /// as `AttachMediaIndex` reads a break at the edge
    /// (`AttachLinkRowJoin.Placement.pathRunsOn(head:nextWord:)`), told
    /// the path word read so far: a terminal's wrap, or a word with a `/`
    /// of its own, runs on, and a word wrapper's break runs on unless where
    /// it falls shows the next row's word could have shared that row (`and`
    /// above `/tmp/shot.png`, which the wrapper moved down whole).
    fileprivate var keepingPathBreaks: TerminalPathRun {
        var first = 0
        var last = rows.count - 1
        var head = ""
        for row in 0 ..< rows.count - 1 {
            head += rows[row]
            let nextWord = layouts[row + 1].text.prefix { !$0.isWhitespace }
            guard layouts[row].endsNearEdge,
                  placement(after: row).pathRunsOn(head: head, nextWord: nextWord) == false
            else { continue }
            if row >= tappedRow {
                last = row
                break
            }
            first = row + 1
            head = ""
        }
        guard first > 0 || last + 1 < rows.count else { return self }
        return TerminalPathRun(
            rows: Array(rows[first ... last]), layouts: Array(layouts[first ... last]),
            tappedRow: tappedRow - first)
    }
}

extension WaycarTerminalView: TerminalSurfaceOpenURLDelegate,
    TerminalSurfaceLifecycleDelegate, TerminalSurfaceGridResizeDelegate
{
    func terminalDidRequestOpenURL(_ url: String, kind _: TerminalOpenURLKind) {
        guard let url = TerminalLinkPolicy.url(for: url) else { return }
        onOpenLink?(url)
    }

    /// The one metrics source that still carries cell dimensions. Since
    /// GhosttyTerminal 1.4.0 the in-memory session's resize dispatches come
    /// from the engine's receive-resize callback, which reports the logical
    /// grid to the Host, while this delegate keeps `terminalCellSize` real so
    /// tap-to-cell mapping and touch-scroll row heights don't fall back to the
    /// 8×16 default.
    func terminalDidResize(_ size: TerminalGridMetrics) {
        terminalGridSize = (Int(size.columns), Int(size.rows))
        hasTerminalGridMetrics = true
        guard size.cellWidthPixels > 0, size.cellHeightPixels > 0 else { return }
        let scale = window?.screen.nativeScale ?? traitCollection.displayScale
        guard scale > 0 else { return }
        terminalCellSize = CGSize(
            width: CGFloat(size.cellWidthPixels) / scale,
            height: CGFloat(size.cellHeightPixels) / scale)
    }

    func terminalDidAttachSurface(_: TerminalSurface) {}

    func terminalDidDetachSurface() {
        removeOrphanedSurfaceLayers()
    }
}

/// A pan recognizer fed by trackpad and mouse-wheel scroll events alone.
/// A scroll event reaches a pan only through `allowedScrollTypesMask`;
/// refusing every other event keeps fingers on the touch pan and a pointer
/// drag on Ghostty's selection pan.
// Adapted from libghostty-spm's TerminalScrollWheelGestureRecognizer (MIT, © Lakr233; Packages/GhosttyTerminal/LICENSE).
final class TerminalScrollEventGestureRecognizer: UIPanGestureRecognizer {
    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        allowedScrollTypesMask = [.continuous, .discrete]
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func shouldReceive(_ event: UIEvent) -> Bool {
        event.type == .scroll
    }
}

/// The hardware keyboard's live Shift state, and whether one is attached,
/// read from GameController.
/// On device `GCKeyboard.coalesced` was still nil when first read as Return
/// arrived (#80): it fills in only once GameController delivers the
/// keyboard's connect, so monitoring starts with the app's first window.
/// Shift is read straight from the keyboard, never from a recorded copy that
/// a missed release could leave stuck.
@MainActor
final class HardwareShiftTracker {
    static let shared = HardwareShiftTracker()

    private var connectObserver: (any NSObjectProtocol)?

    private init() {}

    /// Whether a hardware keyboard is attached. Reads false until
    /// GameController delivers the keyboard's connect after `start()`.
    /// The Simulator always reports one (`GCKeyboard.coalesced` is never
    /// nil there, even on a simulator that never saw the Mac's keyboard):
    /// check the on-screen keyboard on a device. The unit-test host reads
    /// false, or every iPad terminal claims first responder on mount under
    /// suites that assume no keyboard (#66); tests that need one inject it.
    var isKeyboardConnected: Bool {
        !Self.isUnitTestHost && GCKeyboard.coalesced != nil
    }

    private static let isUnitTestHost =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    var isHeld: Bool {
        guard let keys = GCKeyboard.coalesced?.keyboardInput else { return false }
        return keys.button(forKeyCode: .leftShift)?.isPressed == true
            || keys.button(forKeyCode: .rightShift)?.isPressed == true
    }

    /// Starts GameController's keyboard monitoring; `WaycarApp` calls it as
    /// its first window appears. The observation is what starts it, so the
    /// observer itself does nothing.
    func start() {
        guard connectObserver == nil else { return }
        connectObserver = NotificationCenter.default.addObserver(
            forName: .GCKeyboardDidConnect, object: nil, queue: .main
        ) { _ in }
    }
}
