import Foundation
import os

/// One viewed Done cycle gets one attempt. Status transitions, re-entry and
/// connection replacement re-arm it; snapshot metadata (notably the stale
/// stateChangeSeq retained by status deltas) is never a completion identifier.
/// The attempt waits out `dwell` first: a Done Agent opened and left again
/// within it (a mis-tap) stays Done, and any change of target restarts it.
@MainActor
final class AgentFocusCoordinator {
    struct ViewingState: Equatable {
        let agentID: ConsoleAgent.ID
        let terminalID: String
        let transportGeneration: UInt64?
        let status: AgentStatus?
        let isHostReady: Bool
        let isSceneActive: Bool
        let isOnStage: Bool

        fileprivate var target: ViewedDoneMachine.Target? {
            guard status == .done, isHostReady, isSceneActive, isOnStage,
                let transportGeneration
            else { return nil }
            return ViewedDoneMachine.Target(
                agentID: agentID, terminalID: terminalID,
                transportGeneration: transportGeneration)
        }
    }

    private static let log = Logger(subsystem: "com.otreva.waycar", category: "AgentFocus")
    private var machine = ViewedDoneMachine()
    private var task: Task<Void, Never>?
    private var focus: (@MainActor (ConsoleAgent.ID) async throws -> Void)?
    private let onFailure: @MainActor (any Error) -> Void
    private let dwell: Duration

    var isInFlight: Bool { machine.isInFlight }

    init(dwell: Duration = .seconds(3), onFailure: @escaping @MainActor (any Error) -> Void = { error in
        AgentFocusCoordinator.log.error("agent.focus failed: \(String(describing: error), privacy: .private)")
    }) {
        self.dwell = dwell
        self.onFailure = onFailure
    }

    func update(
        _ state: ViewingState,
        focus: @escaping @MainActor (ConsoleAgent.ID) async throws -> Void
    ) {
        self.focus = focus
        perform(machine.handle(.update(state.target)))
    }

    func leave() {
        focus = nil
        perform(machine.handle(.leave))
    }

    private func perform(_ effects: [ViewedDoneMachine.Effect], failure: (any Error)? = nil) {
        for effect in effects {
            switch effect {
            case .startAttempt(let token, let target):
                startAttempt(token, target: target)
            case .cancelAttempt:
                task?.cancel()
            case .reportFailure:
                if let failure { onFailure(failure) }
            }
        }
    }

    private func startAttempt(_ token: UInt64, target: ViewedDoneMachine.Target) {
        guard let focus else { return }
        let dwell = dwell
        task = Task { [weak self] in
            guard let self else { return }
            do {
                if dwell > .zero { try await Task.sleep(for: dwell) }
                try Task.checkCancellation()
                self.perform(self.machine.handle(.dwellElapsed(token)))
                if self.machine.state == .sending(attempt: token, target) {
                    try await focus(target.agentID)
                }
            } catch {
                if !Task.isCancelled,
                    !(error is CancellationError), (error as? TransportError) != .cancelled
                {
                    self.perform(self.machine.handle(.failure(token)), failure: error)
                }
            }
            // Keep the cancelled task's slot until it actually returns. Even
            // a cancellation-insensitive transport cannot overlap a new call.
            self.task = nil
            self.perform(self.machine.handle(.finished(token)))
        }
    }
}
