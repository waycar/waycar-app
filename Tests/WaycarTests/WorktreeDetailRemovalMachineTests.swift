import Foundation
import Testing

@testable import Waycar

@Suite("Worktree detail removal machine")
struct WorktreeDetailRemovalMachineTests {
    private func confirmation() -> WorktreeRemovalConfirmation {
        let checkout = RepositoryCheckout(
            repoKey: "/repo/.git", repoName: "repo", repoRoot: "/repo",
            checkoutPath: "/worktree", isLinkedWorktree: true)
        return .make(
            request: .init(identity: .init(hostID: UUID(), workspaceID: "w1", checkout: checkout)),
            workspaceLabel: "worktree", branch: .unavailable, hasWorkingAgent: false)
    }

    @Test func dialogDismissalCannotRevokeOrDuplicateADispatch() {
        let confirmation = confirmation()
        var machine = WorktreeDetailRemovalMachine().after([.prepare(confirmation)])
        #expect(machine.confirmation == confirmation)
        #expect(machine.handle(.begin) == [.confirmed(confirmation.request)])
        #expect(machine.handle(.cancelConfirmation).isEmpty)
        #expect(machine.confirmation == nil)
        #expect(machine.phase == .removing)
        #expect(machine.handle(.begin).isEmpty)
        #expect(machine.handle(.dispatch(confirmation.request)) == [.remove(1, confirmation.request)])
        #expect(machine.handle(.dispatch(confirmation.request)).isEmpty)
        #expect(machine.handle(.finished(0, .cancelled)).isEmpty)
        let receipt = WorktreeRemovalReceipt(request: confirmation.request, affectedAgentIDs: [])
        _ = machine.handle(.finished(1, .removed(receipt)))
        #expect(machine.phase == .removed(receipt))
        #expect(!machine.showsFeedback)
    }

    @Test func cancellationAndRefusalAllowRetryButUncertainOutcomesDoNot() {
        let confirmation = confirmation()
        var machine = WorktreeDetailRemovalMachine().after([.prepare(confirmation), .cancelConfirmation])
        #expect(machine.state == .idle)
        #expect(machine.handle(.dispatch(confirmation.request)).isEmpty)
        _ = machine.handle([.prepare(confirmation), .begin, .dispatch(confirmation.request), .finished(1, .cancelled)])
        #expect(machine.state == .idle)
        _ = machine.handle([.prepare(confirmation), .begin, .dispatch(confirmation.request), .finished(2, .failed("refused"))])
        #expect(machine.showsFeedback)
        _ = machine.handle(.dismissFeedback)
        #expect(machine.state == .idle)
        _ = machine.handle([.prepare(confirmation), .begin, .dispatch(confirmation.request), .finished(3, .stale("stale"))])
        #expect(machine.showsFeedback)
        _ = machine.handle(.dismissFeedback)
        #expect(machine.phase == .stale("stale"))
        #expect(!machine.showsFeedback)
        #expect(machine.handle(.prepare(confirmation)).isEmpty)

        var uncertain = WorktreeDetailRemovalMachine().after([
            .prepare(confirmation), .begin, .dispatch(confirmation.request), .finished(1, .unconfirmed)
        ])
        #expect(uncertain.showsFeedback)
        _ = uncertain.handle(.dismissFeedback)
        #expect(uncertain.phase == .unconfirmed)
        #expect(!uncertain.showsFeedback)
    }
}
