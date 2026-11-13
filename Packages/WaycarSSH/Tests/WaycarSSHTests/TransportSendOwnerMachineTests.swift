import CLibSSH2
import Testing

@testable import WaycarSSH

@Suite("Transport send owner machine")
struct TransportSendOwnerMachineTests {
    private typealias Machine = TransportSendOwnerMachine

    @Test("an EAGAIN with outbound pending takes ownership")
    func anEAGAINWithOutboundTakesOwnership() {
        var machine = Machine()
        #expect(machine.handle(.wouldBlock(call: 1, outboundPending: true)) == [])
        #expect(machine.state == .owned(call: 1))
        #expect(machine.owner == 1)
    }

    @Test("an EAGAIN with nothing outbound takes nothing")
    func anEAGAINWithoutOutboundTakesNothing() {
        var machine = Machine()
        _ = machine.handle(.wouldBlock(call: 1, outboundPending: false))
        #expect(machine.state == .free)
        #expect(machine.owner == nil)
    }

    @Test("another call's EAGAIN never takes an owned send")
    func anotherCallCannotTakeAnOwnedSend() {
        var machine = Machine().after([.wouldBlock(call: 1, outboundPending: true)])
        _ = machine.handle(.wouldBlock(call: 2, outboundPending: true))
        #expect(machine.state == .owned(call: 1))
    }

    @Test("only the owner's own result ends its ownership")
    func onlyTheOwnersResultEndsIt() {
        var machine = Machine().after([.wouldBlock(call: 1, outboundPending: true)])
        #expect(machine.handle(.finished(call: 2, result: 0, outboundPending: false)) == [])
        #expect(machine.state == .owned(call: 1))
        #expect(machine.handle(.finished(call: 1, result: 0, outboundPending: true)) == [.cleared])
        #expect(machine.state == .free)
    }

    @Test("a failure with nothing outbound clears; one with outbound invalidates")
    func aFailureClearsOrInvalidates() {
        var drained = Machine().after([.wouldBlock(call: 1, outboundPending: true)])
        #expect(drained.handle(.finished(
            call: 1, result: LIBSSH2_ERROR_SOCKET_SEND, outboundPending: false)) == [.cleared])
        #expect(drained.state == .free)

        var stuck = Machine().after([.wouldBlock(call: 1, outboundPending: true)])
        #expect(stuck.handle(.finished(
            call: 1, result: LIBSSH2_ERROR_SOCKET_SEND, outboundPending: true)) == [.invalidate])
        // Owned until the invalidation completes.
        #expect(stuck.state == .owned(call: 1))
        _ = stuck.handle(.sessionReleased)
        #expect(stuck.state == .free)
    }

    @Test("a result with no owner changes nothing")
    func aResultWithNoOwnerChangesNothing() {
        var machine = Machine()
        #expect(machine.handle(.finished(call: 1, result: 0, outboundPending: true)) == [])
        #expect(machine.state == .free)
    }

    @Test("releasing the session frees the send")
    func releasingTheSessionFreesTheSend() {
        var machine = Machine().after([.wouldBlock(call: 3, outboundPending: true)])
        #expect(machine.handle(.sessionReleased) == [])
        #expect(machine.owner == nil)
        _ = machine.handle(.wouldBlock(call: 4, outboundPending: true))
        #expect(machine.owner == 4)
    }
}
