import Foundation

/// Message Agent's visible system keyboard moving to the terminal (⌨ while
/// typing in the Composer, ATTACH-11, `AgentTerminalView`): requested, the
/// destination terminal accepting it from its SwiftUI update, then settling
/// its own keyboard frame.
///
/// The id is the shared inset's handoff token (`TerminalKeyboardInset`
/// mints it and freezes the inset for it); the inset is shared by the
/// Console, so this machine, not the inset's active id, says whether the
/// handoff is this screen's.
///
/// - Requested: Composer stays mounted and the terminal is enabled so the
///   update-time claim can reach it; the terminal reports acceptance once it
///   holds first responder, and only then is Direct Input rendered.
/// - Settling: accepted, waiting for the destination's own keyboard frame
///   (or its timeout); the inset is released only then.
/// - A refusal or a cancel before acceptance also drops the keyboard intent
///   the request raised; after acceptance the terminal keeps it.
struct DirectKeyboardHandoffMachine: StateMachine {
    enum State: Equatable, Sendable {
        case idle
        case requested(UUID)
        /// `requestHeld` is false only after Direct Input was applied without
        /// preserving the handoff, which every caller refuses while one is in
        /// flight; kept so that state stays representable as it always was.
        case settling(UUID, requestHeld: Bool)
    }

    enum Event: Equatable, Sendable {
        /// ⌨ with the system keyboard up; the inset already froze for `id`.
        case begin(UUID)
        /// The terminal's answer to the update-time claim.
        case destinationAnswered(UUID, accepted: Bool)
        /// The terminal's own keyboard frame settled, or its timeout gave up.
        case destinationSettled(UUID)
        /// A refusal, a destination cancel, the inset's watchdog, a departure.
        case cancel(UUID)
        /// Whatever handoff is in flight is cancelled (departure, a new
        /// terminal pipeline).
        case cancelCurrent
        /// Direct Input applied without preserving the handoff.
        case requestCleared
    }

    enum Effect: Equatable, Sendable {
        /// Render Direct Input, keeping the handoff.
        case enterDirectInput
        case dropKeyboardIntent
        case endInsetHandoff(UUID)
        case cancelInsetHandoff(UUID)
    }

    private(set) var state = State.idle

    init() {}

    /// The handoff Composer is held for: what the terminal is asked to
    /// claim, and what keeps it enabled.
    var requestID: UUID? {
        switch state {
        case .idle: nil
        case .requested(let id): id
        case .settling(let id, let held): held ? id : nil
        }
    }

    var settlingID: UUID? {
        if case .settling(let id, _) = state { id } else { nil }
    }

    /// A second switch while the keyboard moves would strand it between the
    /// two inputs.
    var isInFlight: Bool { state != .idle }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.idle, .begin(let id)):
            state = .requested(id)
            return []
        case (.requested, .begin), (.settling, .begin):
            // Every caller refuses a second switch while one is in flight.
            return []

        case (.requested(let current), .destinationAnswered(let id, true)) where current == id,
            (.settling(let current, true), .destinationAnswered(let id, true)) where current == id:
            state = .settling(id, requestHeld: true)
            return [.enterDirectInput]
        case (.requested(let current), .destinationAnswered(let id, false)) where current == id,
            (.settling(let current, true), .destinationAnswered(let id, false)) where current == id:
            return cancel(id)
        case (_, .destinationAnswered):
            return []

        case (.settling(let current, _), .destinationSettled(let id)) where current == id:
            state = .idle
            return [.endInsetHandoff(id)]
        case (_, .destinationSettled):
            return []

        case (_, .cancel(let id)):
            return cancel(id)
        case (_, .cancelCurrent):
            guard let id = requestID ?? settlingID else { return [] }
            return cancel(id)

        case (.requested, .requestCleared):
            state = .idle
            return []
        case (.settling(let id, _), .requestCleared):
            state = .settling(id, requestHeld: false)
            return []
        case (.idle, .requestCleared):
            return []
        }
    }

    private mutating func cancel(_ id: UUID) -> [Effect] {
        switch state {
        case .requested(let current) where current == id:
            state = .idle
            return [.dropKeyboardIntent, .cancelInsetHandoff(id)]
        case .settling(let current, _) where current == id:
            state = .idle
            return [.cancelInsetHandoff(id)]
        case .idle, .requested, .settling:
            return []
        }
    }
}
