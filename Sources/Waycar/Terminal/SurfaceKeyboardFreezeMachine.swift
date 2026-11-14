import Foundation

/// The terminal surface's keyboard-transition freeze (ATTACH-14,
/// `WaycarTerminalView`): while a keyboard changes hands the surface skips
/// `layoutSubviews` and holds its grid reports, until the keyboard's own
/// frame settles, the leash runs out, or the transfer is cancelled.
///
/// Rules the owner relies on:
/// - Each freeze is a cycle with its own token. The reload a first owned
///   frame queues and the leash both carry it; a newer freeze, a thaw or a
///   cancel makes them do nothing.
/// - An inherited keyboard first publishes a frame that still includes both
///   responders' accessories, so the first settle only queues an input-view
///   reload, and duplicates coalesce until it runs. The reload is marked done
///   before it runs: UIKit can publish the settled frame from inside it, and
///   that settle must thaw.
/// - A thaw clears the freeze before any of its effects, so the layout it
///   runs is not suppressed and a settle arriving from inside its reload is
///   ignored. It reports the outcome to the handoff that owned the freeze
///   last, once the grid report is scheduled.
/// - A cancel thaws the bridge before the owner hears `.cancelled`.
struct SurfaceKeyboardFreezeMachine: StateMachine {
    enum Reload: Equatable, Sendable {
        case notYet
        /// Queued for the next main-queue turn.
        case scheduled
        case done
    }

    enum State: Equatable, Sendable {
        case live
        /// `handoff` is the Composer-to-terminal handoff that owns the
        /// freeze, if any; `endsOnFrameChange` is an inherited keyboard,
        /// which never leaves and so settles on a frame change.
        case frozen(cycle: UInt64, endsOnFrameChange: Bool, reload: Reload, handoff: UUID?)
    }

    enum Event: Equatable, Sendable {
        /// The surface reached its window to inherit the keyboard.
        case inherit
        /// An explicit handoff asked this surface to take the keyboard.
        case requestHandoff(UUID)
        /// `keyboardDidChangeFrame` that leaves this surface's own window
        /// covered.
        case frameSettled
        case queuedReloadFired(cycle: UInt64)
        case fallbackElapsed(cycle: UInt64)
        case finish(TerminalKeyboardHandoffOutcome)
        /// `requestKeyboard()`: ends a freeze no handoff owns.
        case requestKeyboard
        case cancel
    }

    enum Effect: Equatable, Sendable {
        case cancelGridReport
        case beginBridgeFreeze
        case cancelBridgeFreeze
        case cancelFallback
        case armFallback(cycle: UInt64)
        case scheduleReload(cycle: UInt64)
        case reloadInputViews
        case layoutNow
        /// Seed the bridge from the surface's synchronous final metrics.
        case provideAuthoritativeGrid
        case scheduleGridReport
        /// A window resize the cancelled freeze held still owes its grid.
        case reportPendingWindowResizeGrid
        case notifyHandoffEnded(UUID, TerminalKeyboardHandoffOutcome)
    }

    private(set) var state = State.live
    private var lastToken: UInt64 = 0

    init() {}

    var isFrozen: Bool { state != .live }

    var endsOnFrameChange: Bool {
        if case .frozen(_, let ends, _, _) = state { ends } else { false }
    }

    var handoffID: UUID? {
        if case .frozen(_, _, _, let handoff) = state { handoff } else { nil }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.live, .inherit):
            return begin(handoff: nil)
        case (.frozen(_, _, _, let handoff), .inherit):
            return begin(handoff: handoff)
        case (_, .requestHandoff(let id)):
            return begin(handoff: id)

        case (.frozen(_, false, _, _), .frameSettled):
            return []
        case (.frozen(let cycle, true, .notYet, let handoff), .frameSettled):
            state = .frozen(cycle: cycle, endsOnFrameChange: true, reload: .scheduled, handoff: handoff)
            return [.scheduleReload(cycle: cycle)]
        case (.frozen(_, true, .scheduled, _), .frameSettled):
            return []
        case (.frozen(_, true, .done, _), .frameSettled):
            return finish(.settled)
        case (.live, .frameSettled):
            return []

        case (.frozen(let cycle, true, .scheduled, let handoff), .queuedReloadFired(let fired))
        where fired == cycle:
            state = .frozen(cycle: cycle, endsOnFrameChange: true, reload: .done, handoff: handoff)
            return [.reloadInputViews]
        case (.frozen, .queuedReloadFired), (.live, .queuedReloadFired):
            return []

        case (.frozen(let cycle, _, _, _), .fallbackElapsed(let fired)) where fired == cycle:
            return finish(.timedOut)
        case (.frozen, .fallbackElapsed), (.live, .fallbackElapsed):
            return []

        case (_, .finish(let outcome)):
            return finish(outcome)

        case (.frozen(_, _, _, nil), .requestKeyboard), (.live, .requestKeyboard):
            return finish(.cancelled)
        case (.frozen, .requestKeyboard):
            return []

        case (.live, .cancel), (.frozen, .cancel):
            let handoff = handoffID
            state = .live
            var effects: [Effect] = [
                .cancelFallback, .cancelGridReport, .cancelBridgeFreeze,
                .reportPendingWindowResizeGrid,
            ]
            if let handoff { effects.append(.notifyHandoffEnded(handoff, .cancelled)) }
            return effects
        }
    }

    private mutating func begin(handoff: UUID?) -> [Effect] {
        lastToken += 1
        state = .frozen(
            cycle: lastToken, endsOnFrameChange: true, reload: .notYet, handoff: handoff)
        return [.cancelGridReport, .beginBridgeFreeze, .cancelFallback, .armFallback(cycle: lastToken)]
    }

    private mutating func finish(_ outcome: TerminalKeyboardHandoffOutcome) -> [Effect] {
        guard case .frozen(_, let inherited, let reload, let handoff) = state else { return [] }
        state = .live
        var effects: [Effect] = [.cancelFallback]
        // Both terminals' accessories were on the keyboard while it changed
        // hands; rebuilding the input views makes UIKit publish the settled
        // frame, unless the queued rebuild already did.
        if inherited, reload != .done { effects.append(.reloadInputViews) }
        effects += [.layoutNow, .provideAuthoritativeGrid, .scheduleGridReport]
        if inherited, let handoff { effects.append(.notifyHandoffEnded(handoff, outcome)) }
        return effects
    }
}
