import Foundation
import GhosttyTerminal

/// How Ghostty's resize reports reach the Host (ATTACH-15,
/// `TerminalSessionCallbackBridge`): in sequence, past the freeze a keyboard
/// handoff or window resize holds them in, and without the one duplicate a
/// thaw already told the Host.
///
/// Reports leave Ghostty's thread with a sequence number and reach the main
/// actor in any order; they are consumed strictly in sequence. A freeze
/// discards every report that left before it began, holds the newest one
/// after, and thaws only once every report that had left when the thaw was
/// asked for has been consumed.
///
/// The owner's callbacks may re-enter the bridge, so the machine never
/// decides past a callback: every callback is the last effect of its step,
/// and the owner sends the step's continuation back once it returns. The
/// continuation reads the state the callback left (a freeze begun from
/// `onViewport` holds that very report; a thaw's suppression token replaces
/// one a nested report set), exactly where the bridge used to read it.
struct GridReportMachine: StateMachine {
    enum Phase: Equatable, Sendable {
        case live
        /// Held; `deferred` is the grid the thaw will forward.
        case deferring(deferred: TerminalGridSize?)
        /// The thaw waits for every report through `through`.
        case flushing(through: UInt64, deferred: TerminalGridSize?)
    }

    /// What a step does once the callback it ended on has returned.
    enum Continuation: Equatable, Sendable {
        case nothing
        /// Consume the next report in sequence, if it arrived.
        case nextReport
        /// Complete a ready thaw, then stop.
        case complete
        /// Complete a ready thaw, then consume the next report.
        case completeThenNextReport
        /// Record a settled report's duplicate-suppression token.
        case suppress(TerminalGridSize)
    }

    struct State: Equatable, Sendable {
        var phase = Phase.live
        var pending: [UInt64: InMemoryTerminalViewport] = [:]
        var lastProcessed: UInt64 = 0
        var discardsThrough: UInt64 = 0
        /// The grid the Host was just told directly, whose engine copy is
        /// consumed once.
        var suppressesDuplicate: TerminalGridSize?
        var lastNotifiedPhase = TerminalGridReportPhase.live
    }

    enum Event: Equatable, Sendable {
        case reportArrived(sequence: UInt64, viewport: InMemoryTerminalViewport)
        /// `latest` is the newest sequence number handed out so far.
        case beginFreeze(latest: UInt64)
        case finishFreeze(latest: UInt64)
        case cancelFreeze(latest: UInt64)
        case provideAuthoritative(TerminalGridSize)
        case reportSettled(TerminalGridSize)
        /// Continuations, sent once the effect's callback returned.
        case currentnessChecked(InMemoryTerminalViewport, isCurrent: Bool)
        case viewportDelivered(InMemoryTerminalViewport)
        case sizeReported(then: Continuation)
        case forwarded(TerminalGridSize, delivered: Bool, then: Continuation)
        case phaseNotified(then: Continuation)
    }

    enum Effect: Equatable, Sendable {
        /// Ask `isSizeReportCurrent`, then send `currentnessChecked`.
        case checkCurrent(InMemoryTerminalViewport)
        /// Call `onViewport`, then send `viewportDelivered`.
        case deliverViewport(InMemoryTerminalViewport)
        /// Call `onSizeChanged`, then send `sizeReported`.
        case reportSize(TerminalGridSize, then: Continuation)
        /// The thaw's grid: call `onSizeChanged` if there is one, then send
        /// `forwarded` saying whether there was.
        case forward(TerminalGridSize, then: Continuation)
        /// Call `onGridReportPhaseChanged`, then send `phaseNotified`.
        case notifyPhase(TerminalGridReportPhase, forwarded: TerminalGridSize?, then: Continuation)
    }

    private(set) var state = State()

    init() {}

    var gridReportPhase: TerminalGridReportPhase {
        switch state.phase {
        case .live: .live
        case .deferring: .deferring
        case .flushing: .flushing
        }
    }

    private var defers: Bool { state.phase != .live }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .reportArrived(let sequence, let viewport):
            state.pending[sequence] = viewport
            return nextReport()

        case .currentnessChecked(let viewport, let isCurrent):
            guard isCurrent else { return completeIfReady(then: .nextReport) }
            return [.deliverViewport(viewport)]

        case .viewportDelivered(let viewport):
            let size = TerminalGridSize(columns: Int(viewport.columns), rows: Int(viewport.rows))
            if defers {
                hold(size)
                return completeIfReady(then: .nextReport)
            }
            if let suppressed = state.suppressesDuplicate {
                state.suppressesDuplicate = nil
                if suppressed == size { return completeIfReady(then: .nextReport) }
            }
            return [.reportSize(size, then: .completeThenNextReport)]

        case .sizeReported(let then), .phaseNotified(let then):
            return proceed(then)

        case .forwarded(let size, let delivered, let then):
            // The thaw's grid came from the surface's synchronous metrics;
            // the engine's own copy may still be in flight and is consumed
            // once. A different grid clears the token and is delivered.
            if delivered { state.suppressesDuplicate = size }
            return notify(forwarded: delivered ? size : nil, then: then)

        case .beginFreeze(let latest):
            // A report may have left Ghostty while its main-actor delivery is
            // still queued; it describes the layout before this freeze.
            state.discardsThrough = max(state.discardsThrough, latest)
            state.phase = .deferring(deferred: nil)
            state.suppressesDuplicate = nil
            return notify(forwarded: nil, then: .nothing)

        case .finishFreeze(let latest):
            switch state.phase {
            case .live:
                return []
            case .deferring(let deferred), .flushing(_, let deferred):
                state.phase = .flushing(through: latest, deferred: deferred)
                return notify(forwarded: nil, then: .complete)
            }

        case .cancelFreeze(let latest):
            state.discardsThrough = max(state.discardsThrough, latest)
            state.phase = .live
            state.suppressesDuplicate = nil
            return notify(forwarded: nil, then: .nothing)

        case .provideAuthoritative(let size):
            guard defers else { return [] }
            hold(size)
            return []

        case .reportSettled(let size):
            guard !defers else {
                hold(size)
                return []
            }
            return [.reportSize(size, then: .suppress(size))]
        }
    }

    private mutating func hold(_ size: TerminalGridSize) {
        switch state.phase {
        case .live: break
        case .deferring: state.phase = .deferring(deferred: size)
        case .flushing(let through, _): state.phase = .flushing(through: through, deferred: size)
        }
    }

    private mutating func proceed(_ continuation: Continuation) -> [Effect] {
        switch continuation {
        case .nothing: return []
        case .nextReport: return nextReport()
        case .complete: return completeIfReady(then: .nothing)
        case .completeThenNextReport: return completeIfReady(then: .nextReport)
        case .suppress(let size):
            state.suppressesDuplicate = size
            return []
        }
    }

    private mutating func nextReport() -> [Effect] {
        guard let viewport = state.pending.removeValue(forKey: state.lastProcessed &+ 1)
        else { return [] }
        state.lastProcessed &+= 1
        guard state.lastProcessed > state.discardsThrough else {
            return completeIfReady(then: .nextReport)
        }
        return [.checkCurrent(viewport)]
    }

    /// Thaws once every report through the thaw's sequence is consumed. The
    /// Host hears the settled grid first, and the phase says `.live` only
    /// once it has.
    private mutating func completeIfReady(then continuation: Continuation) -> [Effect] {
        guard case .flushing(let through, let deferred) = state.phase,
              state.lastProcessed >= through
        else { return proceed(continuation) }
        state.phase = .live
        guard let deferred else { return notify(forwarded: nil, then: continuation) }
        return [.forward(deferred, then: continuation)]
    }

    private mutating func notify(
        forwarded: TerminalGridSize?, then continuation: Continuation
    ) -> [Effect] {
        let phase = gridReportPhase
        guard phase != state.lastNotifiedPhase else { return proceed(continuation) }
        state.lastNotifiedPhase = phase
        return [.notifyPhase(phase, forwarded: forwarded, then: continuation)]
    }
}
