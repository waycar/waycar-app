import Foundation
import Observation

@MainActor
@Observable
final class WorktreeDetailStore {
    enum BranchPresentation: Equatable {
        case loading
        case named(String)
        case detached
        case unavailable
    }

    enum RemovalPhase: Equatable {
        case idle
        case removing
        case removed(WorktreeRemovalReceipt)
        case failed(String)
        case stale(String)
        case unconfirmed
    }

    let request: WorktreeRemovalRequest
    let workspaceLabel: String
    let checkout: RepositoryCheckout

    private(set) var branch: BranchPresentation = .loading
    private var removal = WorktreeDetailRemovalMachine()
    var confirmation: WorktreeRemovalConfirmation? { removal.confirmation }
    var removalPhase: RemovalPhase { removal.phase }
    var showsFeedback: Bool { removal.showsFeedback }

    private let list: (String) async throws -> WorktreeListResponse
    private let remove: (WorktreeRemovalRequest) async throws -> WorktreeRemovalReceipt
    private let hasWorkingAgent: () -> Bool
    private var didLoadBranch = false

    init(
        request: WorktreeRemovalRequest,
        workspaceLabel: String,
        checkout: RepositoryCheckout,
        list: @escaping (String) async throws -> WorktreeListResponse,
        remove: @escaping (WorktreeRemovalRequest) async throws -> WorktreeRemovalReceipt,
        hasWorkingAgent: @escaping () -> Bool
    ) {
        self.request = request
        self.workspaceLabel = workspaceLabel
        self.checkout = checkout
        self.list = list
        self.remove = remove
        self.hasWorkingAgent = hasWorkingAgent
    }

    var canRemove: Bool {
        checkout.isLinkedWorktree && removalPhase == .idle
    }

    func loadBranchIfNeeded() async {
        guard !didLoadBranch else { return }
        didLoadBranch = true
        branch = .loading
        do {
            let response = try await list(request.identity.workspaceID)
            guard response.source.repoKey == request.identity.repoKey else {
                branch = .unavailable
                return
            }
            let entry = response.worktrees.first {
                $0.openWorkspaceID == request.identity.workspaceID
                    && $0.path == request.identity.checkoutPath
                    && $0.isLinkedWorktree
            }
            guard let entry else {
                branch = .unavailable
                return
            }
            if let name = entry.branch, !name.isEmpty {
                branch = .named(name)
            } else if entry.isDetached {
                branch = .detached
            } else {
                branch = .unavailable
            }
        } catch is CancellationError {
            didLoadBranch = false
            branch = .loading
        } catch TransportError.cancelled {
            didLoadBranch = false
            branch = .loading
        } catch {
            branch = .unavailable
        }
    }

    func retryBranch() async {
        didLoadBranch = false
        await loadBranchIfNeeded()
    }

    /// Captures one immutable request in the dialog. Final authorization is
    /// deliberately later, immediately before the wire begins writing.
    func prepareConfirmation() {
        guard canRemove else { return }
        _ = removal.handle(.prepare(WorktreeRemovalConfirmation.make(
            request: request,
            workspaceLabel: workspaceLabel,
            branch: confirmationBranch,
            hasWorkingAgent: hasWorkingAgent())))
    }

    func cancelConfirmation() {
        _ = removal.handle(.cancelConfirmation)
    }

    /// Captures and transitions the exact confirmed request synchronously.
    /// SwiftUI may clear the dialog binding immediately after this returns;
    /// the asynchronous dispatch no longer reads that mutable dialog state.
    func beginRemoval() -> WorktreeRemovalRequest? {
        guard canRemove else { return nil }
        for effect in removal.handle(.begin) {
            if case .confirmed(let request) = effect { return request }
        }
        return nil
    }

    func finishRemoval(_ request: WorktreeRemovalRequest) async {
        guard request == self.request else { return }
        for effect in removal.handle(.dispatch(request)) {
            guard case .remove(let token, let confirmed) = effect else { continue }
            let outcome: WorktreeDetailRemovalMachine.Outcome
            do {
                outcome = .removed(try await remove(confirmed))
            } catch WorktreeRemovalError.staleIdentity {
                outcome = .stale(WorktreeRemovalError.staleIdentity.message)
            } catch WorktreeRemovalError.outcomeUnconfirmed {
                outcome = .unconfirmed
            } catch is CancellationError {
                outcome = .cancelled
            } catch TransportError.cancelled {
                outcome = .cancelled
            } catch {
                outcome = .failed(WorktreeRemovalRefusal.message(for: error))
            }
            _ = removal.handle(.finished(token, outcome))
        }
    }

    func dismissFeedback() {
        _ = removal.handle(.dismissFeedback)
    }

    private var confirmationBranch: WorktreeRemovalConfirmation.Branch {
        switch branch {
        case .named(let name): .named(name)
        case .detached: .detached
        case .loading, .unavailable: .unavailable
        }
    }
}
