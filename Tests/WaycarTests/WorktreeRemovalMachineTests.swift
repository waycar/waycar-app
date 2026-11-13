import Foundation
import Testing

@testable import Waycar

@Suite("Worktree removal machine")
struct WorktreeRemovalMachineTests {
    private let host = Host.fixture()

    private func makeRequest() -> WorktreeRemovalRequest {
        WorktreeRemovalRequest(identity: WorktreeIdentity(
            hostID: host.id, workspaceID: "w1",
            checkout: RepositoryCheckout(
                repoKey: "repo", repoName: "repo", repoRoot: "/work/repo",
                checkoutPath: "/work/linked", isLinkedWorktree: true)))
    }

    @Test func authorizationCapturesOnlyTheProvenRowsAndDispatchKeepsThem() {
        let request = makeRequest()
        let affected: Set<ConsoleAgent.ID> = [.init(hostID: host.id, paneID: "p")]
        var machine = WorktreeRemovalMachine(request: request)
        #expect(machine.requiresIdentityProof)
        #expect(machine.handle(.authorize(request, affected: nil)) == [.reject(.staleIdentity)])
        #expect(machine.state == .preparing)
        #expect(machine.handle(.authorize(request, affected: affected)).isEmpty)
        #expect(machine.state == .authorized(affected: affected))
        #expect(machine.handle(.dispatched(request, snapshotGeneration: 4)).isEmpty)
        #expect(machine.state == .dispatched(affected: affected, snapshotGeneration: 4))
        #expect(machine.isDispatched && !machine.requiresIdentityProof)
        // A retry's authorization is a no-op even if the current snapshot
        // cannot prove identity, and never replaces its affected Agents.
        #expect(machine.handle(.authorize(request, affected: nil)).isEmpty)
        #expect(machine.handle(.authorize(request, affected: [])).isEmpty)
        #expect(machine.handle(.dispatched(request, snapshotGeneration: 99)).isEmpty)
        #expect(machine.state == .dispatched(affected: affected, snapshotGeneration: 4))
        let receipt = WorktreeRemovalReceipt(request: request, affectedAgentIDs: affected)
        #expect(machine.handle(.succeeded(request, snapshotGeneration: 5)) == [
            .record(receipt, snapshotGeneration: 5), .finish,
        ])
        #expect(machine.state == .removed(receipt))
    }

    @Test func repeatedPreDispatchAuthorizationUsesTheLatestProof() {
        let request = makeRequest()
        var machine = WorktreeRemovalMachine(request: request).after([
            .authorize(request, affected: [.init(hostID: host.id, paneID: "old")]),
        ])
        #expect(machine.requiresIdentityProof)
        #expect(machine.handle(.authorize(request, affected: nil)) == [.reject(.staleIdentity)])
        #expect(machine.handle(.authorize(request, affected: [])).isEmpty)
        #expect(machine.state == .authorized(affected: []))
    }

    @Test func aRequestWithTheSameUUIDButAnotherIdentityCannotAdvanceTheOperation() {
        let request = makeRequest()
        let changed = WorktreeRemovalRequest(id: request.id, identity: WorktreeIdentity(
            hostID: host.id, workspaceID: "w2",
            checkout: RepositoryCheckout(
                repoKey: "repo", repoName: "repo", repoRoot: "/work/repo",
                checkoutPath: "/work/other", isLinkedWorktree: true)))
        var machine = WorktreeRemovalMachine(request: request)
        let events: [WorktreeRemovalMachine.Event] = [
            .authorize(changed, affected: []), .dispatched(changed, snapshotGeneration: 1),
            .unconfirmed(changed), .succeeded(changed, snapshotGeneration: 1),
        ]
        for event in events {
            #expect(machine.handle(event) == [.reject(.staleIdentity)])
            #expect(machine.state == .preparing)
        }
    }

    @Test func anUnansweredDispatchNeedsAStrictlyLaterSnapshot() {
        let request = makeRequest()
        let affected: Set<ConsoleAgent.ID> = [.init(hostID: host.id, paneID: "p")]
        var machine = WorktreeRemovalMachine(request: request).after([
            .authorize(request, affected: affected), .dispatched(request, snapshotGeneration: 4),
        ])
        #expect(machine.handle(.snapshot(generation: 5, stillPresent: false)).isEmpty)
        #expect(machine.handle(.unconfirmed(request)).isEmpty)
        #expect(machine.state == .unconfirmed(affected: affected, snapshotGeneration: 4))
        #expect(machine.handle(.authorize(request, affected: affected)) == [.reject(.staleIdentity)])
        #expect(!machine.canReconcileSnapshot(generation: 4))
        #expect(machine.handle(.snapshot(generation: 4, stillPresent: false)).isEmpty)
        #expect(machine.canReconcileSnapshot(generation: 5))
        let receipt = WorktreeRemovalReceipt(request: request, affectedAgentIDs: affected)
        #expect(machine.handle(.snapshot(generation: 5, stillPresent: false)) == [
            .record(receipt, snapshotGeneration: 5), .finish,
        ])
        #expect(machine.state == .removed(receipt))
        #expect(machine.handle(.snapshot(generation: 6, stillPresent: false)).isEmpty)
    }

    @Test func aLaterSnapshotStillShowingTheCheckoutReleasesWithoutASuccessReceipt() {
        let request = makeRequest()
        var machine = WorktreeRemovalMachine(request: request).after([
            .authorize(request, affected: []), .dispatched(request, snapshotGeneration: 4),
            .unconfirmed(request),
        ])
        #expect(machine.handle(.snapshot(generation: 5, stillPresent: true)) == [.finish])
        #expect(machine.state == .refused)
        #expect(machine.handle(.succeeded(request, snapshotGeneration: 6)) == [.reject(.staleIdentity)])
    }

    @Test func definiteRefusalReleasesAnyActivePhase() {
        let request = makeRequest()
        let setups: [[WorktreeRemovalMachine.Event]] = [
            [], [.authorize(request, affected: [])],
            [.dispatched(request, snapshotGeneration: 1)],
            [.dispatched(request, snapshotGeneration: 1), .unconfirmed(request)],
        ]
        for setup in setups {
            var machine = WorktreeRemovalMachine(request: request).after(setup)
            #expect(machine.handle(.refused) == [.finish])
            #expect(machine.state == .refused)
            #expect(machine.handle(.refused).isEmpty)
            #expect(machine.handle(.dispatched(request, snapshotGeneration: 9)).isEmpty)
        }
    }

    @Test func aReplyCanFinishBeforeTheDispatchCallbackButUncertaintyCannot() {
        let request = makeRequest()
        var machine = WorktreeRemovalMachine(request: request)
        #expect(machine.handle(.unconfirmed(request)) == [.reject(.staleIdentity)])
        let receipt = WorktreeRemovalReceipt(request: request, affectedAgentIDs: [])
        #expect(machine.handle(.succeeded(request, snapshotGeneration: 1)) == [
            .record(receipt, snapshotGeneration: 1), .finish,
        ])
        #expect(machine.handle(.succeeded(request, snapshotGeneration: 2)) == [.reject(.staleIdentity)])
    }
}
