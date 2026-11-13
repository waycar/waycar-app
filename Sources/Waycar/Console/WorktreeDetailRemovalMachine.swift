import Foundation

/// The detail's immutable confirmation, single dispatch claim, and terminal
/// outcome. Dismissing SwiftUI's dialog cannot revoke an accepted request.
struct WorktreeDetailRemovalMachine: StateMachine {
    enum Feedback: Equatable, Sendable { case presented, dismissed }
    enum State: Equatable, Sendable {
        case idle
        case confirming(WorktreeRemovalConfirmation)
        case dispatchPending(UInt64, WorktreeRemovalRequest)
        case removing(UInt64, WorktreeRemovalRequest)
        case removed(WorktreeRemovalReceipt)
        case failed(String)
        case stale(String, Feedback)
        case unconfirmed(Feedback)
    }
    enum Outcome: Equatable, Sendable {
        case removed(WorktreeRemovalReceipt)
        case failed(String)
        case stale(String)
        case unconfirmed
        case cancelled
    }
    enum Event: Equatable, Sendable {
        case prepare(WorktreeRemovalConfirmation)
        case cancelConfirmation
        case begin
        case dispatch(WorktreeRemovalRequest)
        case finished(UInt64, Outcome)
        case dismissFeedback
    }
    enum Effect: Equatable, Sendable {
        case confirmed(WorktreeRemovalRequest)
        case remove(UInt64, WorktreeRemovalRequest)
    }

    private(set) var state: State = .idle
    private var lastToken: UInt64 = 0

    var confirmation: WorktreeRemovalConfirmation? {
        guard case .confirming(let confirmation) = state else { return nil }
        return confirmation
    }
    var phase: WorktreeDetailStore.RemovalPhase {
        switch state {
        case .idle, .confirming: .idle
        case .dispatchPending, .removing: .removing
        case .removed(let receipt): .removed(receipt)
        case .failed(let message): .failed(message)
        case .stale(let message, _): .stale(message)
        case .unconfirmed: .unconfirmed
        }
    }
    var showsFeedback: Bool {
        switch state {
        case .failed, .stale(_, .presented), .unconfirmed(.presented): true
        case .idle, .confirming, .dispatchPending, .removing, .removed,
             .stale(_, .dismissed), .unconfirmed(.dismissed): false
        }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.idle, .prepare(let confirmation)), (.confirming, .prepare(let confirmation)):
            state = .confirming(confirmation)
        case (.confirming, .cancelConfirmation):
            state = .idle
        case (.confirming(let confirmation), .begin):
            lastToken &+= 1
            state = .dispatchPending(lastToken, confirmation.request)
            return [.confirmed(confirmation.request)]
        case (.dispatchPending(let token, let confirmed), .dispatch(let request)):
            guard request == confirmed else { return [] }
            state = .removing(token, confirmed)
            return [.remove(token, confirmed)]
        case (.removing(let current, _), .finished(let token, let outcome)):
            guard token == current else { return [] }
            switch outcome {
            case .removed(let receipt): state = .removed(receipt)
            case .failed(let message): state = .failed(message)
            case .stale(let message): state = .stale(message, .presented)
            case .unconfirmed: state = .unconfirmed(.presented)
            case .cancelled: state = .idle
            }
        case (.failed, .dismissFeedback): state = .idle
        case (.stale(let message, _), .dismissFeedback): state = .stale(message, .dismissed)
        case (.unconfirmed, .dismissFeedback): state = .unconfirmed(.dismissed)
        case (.idle, _), (.confirming, _), (.dispatchPending, _), (.removing, _),
             (.removed, _), (.failed, _), (.stale, _), (.unconfirmed, _):
            break
        }
        return []
    }
}
