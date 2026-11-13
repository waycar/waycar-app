import Foundation
import Testing

@testable import Waycar

@Suite("Agent terminal retention machine")
struct AgentTerminalRetentionMachineTests {
    private let owner = UUID()

    @Test func repeatedActivationCancelsExpiryAndIdleReleaseReplacesItsTimer() {
        var machine = AgentTerminalRetentionMachine(ownerID: owner)
        #expect(machine.isRetained)
        #expect(machine.isVisible)
        #expect(machine.presentationOwnerID == owner)
        #expect(machine.handle(.activate(owner)) == [.cancelExpiry])
        #expect(machine.handle(.release(owner)) == [.scheduleExpiry(1)])
        #expect(machine.state == .retainedIdle(owner: owner, expiry: 1))
        #expect(machine.isRetained)
        #expect(!machine.isVisible)
        #expect(machine.handle(.release(owner)) == [.scheduleExpiry(2)])
        #expect(machine.handle(.expiryElapsed(1)).isEmpty)
        #expect(machine.handle(.activate(owner)) == [.cancelExpiry])
        #expect(machine.state == .presented(owner: owner))
        #expect(machine.handle(.expiryElapsed(2)).isEmpty)
    }

    @Test func onlyAnIdleEntryCanTransferPresentationAndOldCallbacksLoseOwnership() {
        let next = UUID()
        var machine = AgentTerminalRetentionMachine(ownerID: owner)
        #expect(machine.handle(.claimPresentation(owner)).isEmpty)
        #expect(machine.handle(.claimPresentation(next)).isEmpty)
        #expect(machine.handle([.activate(next), .release(next)]).isEmpty)
        #expect(machine.state == .presented(owner: owner))
        machine = machine.after([.release(owner)])
        #expect(machine.handle(.claimPresentation(next)).isEmpty)
        #expect(machine.state == .retainedIdle(owner: next, expiry: 1))
        #expect(machine.handle([.activate(owner), .release(owner)]).isEmpty)
        #expect(machine.handle(.activate(next)) == [.cancelExpiry])
        #expect(machine.presentationOwnerID == next)
        #expect(machine.handle(.expiryElapsed(1)).isEmpty)
        #expect(machine.handle(.release(owner)).isEmpty)
        #expect(machine.isVisible)
    }

    @Test func matchingExpiryRequestsEvictionButAStaleExpiryDoesNothing() {
        var machine = AgentTerminalRetentionMachine(ownerID: owner).after([.release(owner)])
        #expect(machine.handle(.expiryElapsed(8)).isEmpty)
        #expect(machine.handle(.expiryElapsed(1)) == [.evict])
        #expect(machine.handle(.evict) == [.tearDown(2)])
        #expect(machine.state == .evicting(teardown: 2))
        #expect(!machine.isRetained)
        #expect(!machine.isVisible)
        #expect(machine.presentationOwnerID == nil)
        #expect(machine.handle(.expiryElapsed(1)).isEmpty)
        #expect(machine.handle(.teardownFinished(1)).isEmpty)
        #expect(machine.state == .evicting(teardown: 2))
        #expect(machine.handle(.teardownFinished(2)).isEmpty)
        #expect(machine.state == .removed)
    }

    @Test func directEvictionIsOneWayAndDuplicateOrStaleWorkCannotResurrectIt() {
        var machine = AgentTerminalRetentionMachine(ownerID: owner)
        #expect(machine.handle(.expiryElapsed(1)).isEmpty)
        #expect(machine.handle(.teardownFinished(1)).isEmpty)
        #expect(machine.handle(.evict) == [.tearDown(1)])
        let ignored: [AgentTerminalRetentionMachine.Event] = [
            .evict, .activate(owner), .release(owner), .claimPresentation(UUID()),
            .expiryElapsed(1), .teardownFinished(9),
        ]
        #expect(machine.handle(ignored).isEmpty)
        #expect(machine.state == .evicting(teardown: 1))
        #expect(machine.handle(.teardownFinished(1)).isEmpty)
        #expect(machine.handle(ignored + [.teardownFinished(1)]).isEmpty)
        #expect(machine.state == .removed)
        #expect(!machine.isRetained)
        #expect(!machine.isVisible)
    }
}
