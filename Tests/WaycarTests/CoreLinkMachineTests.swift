import Testing

@testable import Waycar

/// `CoreLinkMachine`: one herdr-core transport's connection and lifetime.
@Suite("herdr-core link machine")
struct CoreLinkMachineTests {
    typealias Machine = CoreLinkMachine

    private let ended = TransportError.channelFailed(detail: "herdr-core ended the connection")
    private let clientGone = TransportError.channelFailed(detail: "the herdr-core connection ended")
    private let connecting = Machine().after([.connect])
    private let open = Machine().after([.connect, .dialed(token: 1)])

    // MARK: Dialing

    @Test func theFirstCallerDialsUnderAFreshToken() {
        var machine = Machine()
        #expect(machine.handle(.connect) == [.dial(token: 1)])
        #expect(machine.state == .connecting(token: 1))
        #expect(machine.refusal == nil)
    }

    @Test func callersWhileDialingJoinAndNeverDialAgain() {
        var machine = connecting
        #expect(machine.handle(.connect).isEmpty)
        #expect(machine.state == .connecting(token: 1))
    }

    @Test func theDialLandingIsTheLink() {
        var machine = connecting
        #expect(machine.handle(.dialed(token: 1)) == [.keep(token: 1)])
        #expect(machine.state == .open(token: 1))
    }

    @Test func aFailedDialLosesTheLinkForGood() {
        var machine = connecting
        #expect(machine.handle(.dialFailed(token: 1, .coreNotRunning)).isEmpty)
        #expect(machine.state == .lost(.coreNotRunning))
        #expect(machine.handle(.connect).isEmpty, "a lost link is never redialed")
        #expect(machine.state == .lost(.coreNotRunning))
    }

    @Test func aStaleDialResultIsDiscardedAndAStaleFailureIgnored() {
        var machine = connecting
        #expect(machine.handle(.dialed(token: 9)) == [.discard(token: 9)])
        #expect(machine.handle(.dialFailed(token: 9, .timedOut)).isEmpty)
        #expect(machine.state == .connecting(token: 1))
    }

    @Test func aDialLandingAfterCloseOrDistrustIsDiscarded() {
        for end in [Machine.Event.close(releasesHold: true), .distrust] {
            var machine = connecting.after([end])
            #expect(machine.handle(.dialed(token: 1)) == [.discard(token: 1)])
            #expect(machine.handle(.dialFailed(token: 1, .cancelled)).isEmpty)
            #expect(machine.state == (end == .distrust ? .distrusted : .closed))
        }
    }

    // MARK: Ending the link

    @Test func thePumpEndingAnOpenLinkLosesIt() {
        var machine = open
        #expect(machine.handle(.connectionEnded(ended)).isEmpty)
        #expect(machine.state == .lost(ended))
    }

    @Test func thePumpNeverOverwritesALostLink() {
        var machine = open.after([.clientEnded(clientGone)])
        #expect(machine.handle(.connectionEnded(ended)).isEmpty)
        #expect(machine.state == .lost(clientGone))
    }

    @Test func aCallerThatSawTheClientEndNamesTheFailureEvenOverThePumps() {
        var machine = open
        _ = machine.handle(.clientEnded(clientGone))
        #expect(machine.state == .lost(clientGone))
        var pumpFirst = open.after([.connectionEnded(ended)])
        _ = pumpFirst.handle(.clientEnded(clientGone))
        #expect(pumpFirst.state == .lost(clientGone))
    }

    @Test func linkEndingsAfterTheTransportEndedChangeNothing() {
        for end in [Machine.Event.close(releasesHold: true), .distrust] {
            var machine = open.after([end])
            let before = machine.state
            #expect(machine.handle(.clientEnded(clientGone)).isEmpty)
            #expect(machine.handle(.connectionEnded(ended)).isEmpty)
            #expect(machine.handle(.connect).isEmpty)
            #expect(machine.state == before)
        }
    }

    // MARK: Distrust and close

    @Test func distrustClosesTheLinkAndKeepsTheHold() {
        for start in [Machine(), connecting, open, open.after([.connectionEnded(ended)])] {
            var machine = start
            #expect(machine.handle(.distrust) == [.closeLink])
            #expect(machine.state == .distrusted)
            #expect(machine.refusal == Machine.replaced)
            #expect(machine.handle(.distrust).isEmpty)
        }
    }

    @Test func closeClosesTheLinkAndReleasesOnce() {
        for start in [Machine(), connecting, open, open.after([.connectionEnded(ended)]), open.after([.distrust])] {
            var machine = start
            #expect(machine.handle(.close(releasesHold: true)) == [.closeLink, .release])
            #expect(machine.state == .closed)
            #expect(machine.isClosed)
            #expect(machine.refusal == .cancelled)
            #expect(machine.handle(.close(releasesHold: true)).isEmpty)
            #expect(machine.handle(.distrust).isEmpty)
        }
    }

    @Test func abandoningAFailedOpenLeavesTheHold() {
        var machine = connecting.after([.dialFailed(token: 1, .coreNotRunning)])
        #expect(machine.handle(.close(releasesHold: false)) == [.closeLink])
        #expect(machine.state == .closed)
        #expect(machine.handle(.close(releasesHold: true)).isEmpty, "the caller's hold is the caller's")
    }

    @Test func onlyAnEndedTransportRefusesCalls() {
        #expect(Machine().refusal == nil)
        #expect(open.refusal == nil)
        #expect(open.after([.connectionEnded(ended)]).refusal == nil, "a lost link fails on its own")
    }
}
