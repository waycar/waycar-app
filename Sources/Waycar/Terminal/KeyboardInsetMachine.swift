import CoreGraphics
import Foundation

/// The terminal's own keyboard inset (`TerminalKeyboardInset`, ATTACH-13):
/// the published heights, a presentation coalescing toward its final frame,
/// a will-hide waiting to be confirmed as a real dismissal, and the
/// responder-handoff freeze with the dismissal it owes its exit.
///
/// Rules the owner relies on:
/// - A presentation is measured only while it can land (no freeze, capture
///   on): `willPresent` asks for the measurement, `presentationMeasured`
///   applies it. A frame that covers none of the window leaves a pending
///   presentation armed and, when it has a size, marks it missed for the
///   did-show to settle against the window's layout guide.
/// - The coalesce, confirmation and handoff fallbacks carry tokens; a
///   timer whose token is not the current one does nothing, which is what
///   cancelling its Task used to guarantee.
/// - A hide or an expiring confirmation inside a freeze becomes debt; every
///   exit (end, cancel, either fallback) releases the freeze, then asks for
///   the window's measurement, then reconciles the debt against it.
/// - Published values change only through `publish…` effects, in the order
///   the inset always assigned them, so a SwiftUI update that runs inside an
///   assignment sees the same partial state as before.
struct KeyboardInsetMachine: StateMachine {
    /// Which timer ends a responder handoff when nothing else does.
    enum HandoffKind: Equatable, Sendable {
        /// The inset's own fallback (Composer to terminal, owner side).
        case owner
        /// The destination terminal times out first; this is the later
        /// watchdog for a destination that went away.
        case destination
    }

    /// How a responder handoff is leaving its freeze.
    enum HandoffExit: Equatable, Sendable {
        /// The destination's keyboard settled (or its own timeout gave up).
        case end
        case cancel
        case fallback(HandoffKind)
    }

    enum Presentation: Equatable, Sendable {
        case none
        /// A measured presentation waiting out the coalesce delay.
        case coalescing(token: UInt64, height: CGFloat)
    }

    enum Dismissal: Equatable, Sendable {
        case none
        /// A will-hide (or an expected keyboard) waiting to be confirmed.
        case confirming(token: UInt64)
    }

    enum Handoff: Equatable, Sendable {
        case none
        /// The inset is frozen for `id`; `owesDismissal` is a hide inside the
        /// freeze, or one unconfirmed when it began or expiring during it.
        case holding(id: UUID, fallback: UInt64, kind: HandoffKind, owesDismissal: Bool)
    }

    struct State: Equatable, Sendable {
        var height: CGFloat = 0
        var lastPresentedHeight: CGFloat = 0
        var isSoftwareKeyboardDismissed = false
        var capturesPresentedHeight = true
        /// A presentation published a keyboard-sized end frame that covered
        /// none of the window, so it was dropped.
        var missedPresentationFrame = false
        var presentation = Presentation.none
        var dismissal = Dismissal.none
        var handoff = Handoff.none
    }

    enum Event: Equatable, Sendable {
        /// `keyboardWillShow` / `keyboardWillChangeFrame`.
        case willPresent(endFrame: CGRect?)
        /// The owner measured `willPresent`'s frame against its window.
        case presentationMeasured(frameHeight: CGFloat, height: CGFloat?)
        case coalesceElapsed(token: UInt64)
        case willDismiss
        case didShow
        /// The owner measured the window's keyboard layout guide.
        case windowKeyboardMeasured(CGFloat?)
        case expectSoftwareKeyboard
        case confirmationElapsed(token: UInt64)
        case pauseCapture
        case resumeCapture
        /// `id` is minted by the owner, which hands it to the destination.
        case beginHandoff(id: UUID, kind: HandoffKind)
        case fallbackElapsed(token: UInt64)
        case endHandoff(UUID)
        case cancelHandoff(UUID)
        /// The owner measured the window for an exit `measureHandoffExit`
        /// asked about.
        case handoffExitMeasured(exit: HandoffExit, owesDismissal: Bool, height: CGFloat?)
    }

    enum Effect: Equatable, Sendable {
        /// Measure `endFrame` and send `presentationMeasured`.
        case measurePresentation(endFrame: CGRect)
        /// Read the window's keyboard layout guide and send
        /// `windowKeyboardMeasured`.
        case measureWindowKeyboard
        case cancelCoalesce
        case armCoalesce(token: UInt64)
        case cancelConfirmation
        case armConfirmation(token: UInt64)
        case cancelHandoffFallback
        case armHandoffFallback(token: UInt64, kind: HandoffKind)
        /// The armed fallback fired: drop its Task and closures.
        case forgetHandoffFallback
        case publishHeight(CGFloat)
        case publishLastPresentedHeight(CGFloat)
        case publishSoftwareKeyboardDismissed(Bool)
        case publishHandoffID(UUID?)
        /// The freeze for `id` is released: measure the window with the
        /// exit's closure and send `handoffExitMeasured`.
        case measureHandoffExit(id: UUID, exit: HandoffExit, owesDismissal: Bool)
    }

    private(set) var state = State()
    private var lastToken: UInt64 = 0

    init() {}

    var isConfirmingDismissal: Bool {
        if case .confirming = state.dismissal { true } else { false }
    }

    var handoffID: UUID? {
        if case .holding(let id, _, _, _) = state.handoff { id } else { nil }
    }

    private var isHolding: Bool { handoffID != nil }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .willPresent(let endFrame):
            guard !isHolding, state.capturesPresentedHeight, let endFrame else { return [] }
            return [.measurePresentation(endFrame: endFrame)]

        case .presentationMeasured(let frameHeight, let height):
            guard !isHolding, state.capturesPresentedHeight, let height else { return [] }
            guard height > 0 else {
                state.missedPresentationFrame = frameHeight > 0
                return []
            }
            state.missedPresentationFrame = false
            state.dismissal = .none
            state.isSoftwareKeyboardDismissed = false
            let token = mint()
            state.presentation = .coalescing(token: token, height: height)
            return [
                .cancelConfirmation, .publishSoftwareKeyboardDismissed(false),
                .cancelCoalesce, .armCoalesce(token: token),
            ]

        case .coalesceElapsed(let token):
            guard case .coalescing(token, let height) = state.presentation else { return [] }
            return apply(height)

        case .willDismiss:
            state.missedPresentationFrame = false
            if case .holding(let id, let fallback, let kind, _) = state.handoff {
                state.handoff = .holding(
                    id: id, fallback: fallback, kind: kind, owesDismissal: true)
                return []
            }
            state.presentation = .none
            return [.cancelCoalesce] + apply(0) + confirmDismissal()

        case .didShow:
            guard state.missedPresentationFrame, !isHolding, state.capturesPresentedHeight
            else { return [] }
            state.missedPresentationFrame = false
            return [.measureWindowKeyboard]

        case .windowKeyboardMeasured(let height):
            guard let height, height > 0 else { return [] }
            state.presentation = .none
            return [.cancelCoalesce] + settleDismissal(height)

        case .expectSoftwareKeyboard:
            state.isSoftwareKeyboardDismissed = false
            return [.publishSoftwareKeyboardDismissed(false)] + confirmDismissal()

        case .confirmationElapsed(let token):
            guard state.dismissal == .confirming(token: token) else { return [] }
            state.dismissal = .none
            guard state.height == 0 else { return [] }
            // A handoff freezes the inset; its exit settles the dismissal.
            if case .holding(let id, let fallback, let kind, _) = state.handoff {
                state.handoff = .holding(
                    id: id, fallback: fallback, kind: kind, owesDismissal: true)
                return []
            }
            state.isSoftwareKeyboardDismissed = true
            return [.publishSoftwareKeyboardDismissed(true)]

        case .pauseCapture:
            state.capturesPresentedHeight = false
            state.presentation = .none
            return [.cancelCoalesce]

        case .resumeCapture:
            state.capturesPresentedHeight = true
            return []

        case .beginHandoff(let id, let kind):
            state.presentation = .none
            // An unconfirmed hide from before the freeze, or one a replaced
            // freeze still owed, is carried into it rather than dropped.
            let carried: Bool
            if case .holding(_, _, _, let owes) = state.handoff {
                carried = owes || isConfirmingDismissal
            } else {
                carried = isConfirmingDismissal
            }
            let token = mint()
            state.handoff = .holding(id: id, fallback: token, kind: kind, owesDismissal: carried)
            state.dismissal = .none
            return [
                .cancelCoalesce, .cancelHandoffFallback, .publishHandoffID(id),
                .cancelConfirmation, .armHandoffFallback(token: token, kind: kind),
            ]

        case .fallbackElapsed(let token):
            guard case .holding(let id, token, let kind, let owes) = state.handoff
            else { return [] }
            state.handoff = .none
            return [
                .forgetHandoffFallback, .publishHandoffID(nil),
                .measureHandoffExit(id: id, exit: .fallback(kind), owesDismissal: owes),
            ]

        case .endHandoff(let id), .cancelHandoff(let id):
            guard case .holding(id, _, _, let owes) = state.handoff else { return [] }
            state.handoff = .none
            let exit: HandoffExit = if case .endHandoff = event { .end } else { .cancel }
            return [
                .cancelHandoffFallback, .publishHandoffID(nil),
                .measureHandoffExit(id: id, exit: exit, owesDismissal: owes),
            ]

        case .handoffExitMeasured(let exit, let owes, let measured):
            switch exit {
            case .end:
                return reconcileHandoffExit(
                    owesDismissal: owes, measuredHeight: measured, keepsVisibleHeight: true)
            case .cancel, .fallback(.destination):
                return reconcileHandoffExit(owesDismissal: owes, measuredHeight: measured)
            case .fallback(.owner):
                return reconcileHandoffExit(
                    owesDismissal: owes, measuredHeight: owes ? measured ?? 0 : measured)
            }
        }
    }

    private mutating func mint() -> UInt64 {
        lastToken += 1
        return lastToken
    }

    /// Arms a fresh confirmation, replacing any running one.
    private mutating func confirmDismissal() -> [Effect] {
        let token = mint()
        state.dismissal = .confirming(token: token)
        return [.cancelConfirmation, .armConfirmation(token: token)]
    }

    /// Every handoff exit reconciles against the owning window. An owed
    /// dismissal is settled against the measurement; `keepsVisibleHeight`
    /// keeps a positive frozen height while the keyboard still measures up.
    /// With nothing owed, a frozen zero inset adopts a keyboard measured up
    /// at exit: its presentation was discarded inside the freeze.
    private mutating func reconcileHandoffExit(
        owesDismissal: Bool,
        measuredHeight: CGFloat?,
        keepsVisibleHeight: Bool = false
    ) -> [Effect] {
        if owesDismissal {
            if keepsVisibleHeight, let measuredHeight, measuredHeight > 0, state.height > 0 {
                return []
            }
            return settleDismissal(measuredHeight)
        }
        if state.height == 0, let measuredHeight, measuredHeight > 0 {
            return settleDismissal(measuredHeight)
        }
        return []
    }

    /// Commits an owed dismissal. A measurement is authoritative; without
    /// one the frozen height stands, and a zero height still gets its
    /// confirmation.
    private mutating func settleDismissal(_ measuredHeight: CGFloat?) -> [Effect] {
        var effects: [Effect] = []
        if let measuredHeight {
            effects += apply(max(0, measuredHeight))
        }
        if state.height > 0 {
            state.dismissal = .none
            state.isSoftwareKeyboardDismissed = false
            effects += [.cancelConfirmation, .publishSoftwareKeyboardDismissed(false)]
        } else {
            effects += confirmDismissal()
        }
        return effects
    }

    /// Lands a height. Whatever was coalescing is done: every caller other
    /// than the coalesce timer itself has cancelled it first.
    private mutating func apply(_ height: CGFloat) -> [Effect] {
        state.presentation = .none
        var effects: [Effect] = []
        if height > 0 {
            state.lastPresentedHeight = height
            effects.append(.publishLastPresentedHeight(height))
        }
        guard height != state.height else { return effects }
        state.height = height
        effects.append(.publishHeight(height))
        return effects
    }
}
