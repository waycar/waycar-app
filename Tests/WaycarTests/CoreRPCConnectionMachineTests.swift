import Testing

@testable import Waycar

/// `CoreRPCConnectionMachine`: one framed `herdr-core connect`.
@Suite("herdr-core RPC connection machine")
struct CoreRPCConnectionMachineTests {
    typealias Machine = CoreRPCConnectionMachine

    private let open = Machine().after([.openRequested, .handshakeFinished])
    private let lost = TransportError.channelFailed(detail: "herdr-core ended the connection")

    // MARK: Opening

    @Test func aNewConnectionOpensOnce() {
        var machine = Machine()
        #expect(machine.handle(.openRequested).isEmpty)
        #expect(machine.state == .opening)
        #expect(machine.isOpening && !machine.isOpen)
        #expect(machine.handle(.handshakeFinished) == [.startIO])
        #expect(machine.state == .open(.none))
        #expect(machine.isOpen)
    }

    @Test func openingAgainIsRefused() {
        var opening = Machine().after([.openRequested])
        #expect(opening.handle(.openRequested) == [.refuse(Machine.alreadyOpened)])
        var open = open
        #expect(open.handle(.openRequested) == [.refuse(Machine.alreadyOpened)])
        #expect(open.state == .open(.none))
    }

    @Test func aFailedConnectionRefusesWithItsReason() {
        var machine = Machine().after([.openRequested, .failed(.cancelled)])
        #expect(machine.handle(.openRequested) == [.refuse(.cancelled)])
        #expect(machine.handle(.handshakeFinished).isEmpty, "a handshake after a close does not open it")
        #expect(machine.state == .failed(.cancelled))
        #expect(machine.failure == .cancelled)
    }

    @Test func callsAreRefusedUntilOpenAndAfterFailure() {
        #expect(Machine().callRefusal == Machine.notOpen)
        #expect(Machine().after([.openRequested]).callRefusal == Machine.notOpen)
        #expect(open.callRefusal == nil)
        #expect(open.after([.failed(.timedOut)]).callRefusal == .timedOut)
        #expect(Machine().failure == Machine.notOpen)
    }

    // MARK: Subscription

    @Test func aSubscribeIsRequestedThenLiveOnItsReply() {
        var machine = open
        #expect(machine.handle(.subscribeRequested).isEmpty)
        #expect(machine.state == .open(.requested))
        #expect(machine.eventsChannel == nil)
        #expect(machine.handle(.subscribeReplied(channel: 7)) == [.startLiveness])
        #expect(machine.state == .open(.live(channel: 7)))
        #expect(machine.eventsChannel == 7)
    }

    @Test func aSecondSubscribeIsRefusedWhileRequestedLiveOrClosed() {
        for events in [
            [Machine.Event.subscribeRequested],
            [.subscribeRequested, .subscribeReplied(channel: 7)],
            [.subscribeRequested, .subscribeReplied(channel: 7), .eventsClosed],
        ] {
            var machine = open.after(events)
            let before = machine.state
            #expect(machine.handle(.subscribeRequested) == [.refuse(.eventsChannelAlreadyOpen)])
            #expect(machine.state == before)
        }
    }

    @Test func subscribingBeforeOpenOrAfterFailureIsRefusedLikeACall() {
        var new = Machine()
        #expect(new.handle(.subscribeRequested) == [.refuse(Machine.notOpen)])
        var failed = open.after([.failed(lost)])
        #expect(failed.handle(.subscribeRequested) == [.refuse(lost)])
    }

    @Test func aFailedSubscribeGoesBackToNoneAndMayBeRetried() {
        var machine = open.after([.subscribeRequested])
        #expect(machine.handle(.subscribeFailed) == [.forgetEvents, .stopLiveness])
        #expect(machine.state == .open(.none))
        #expect(machine.handle(.subscribeRequested).isEmpty)
        #expect(machine.state == .open(.requested))
    }

    @Test func aReplyChannelOutsideARequestIsIgnored() {
        var machine = open
        #expect(machine.handle(.subscribeReplied(channel: 3)).isEmpty)
        #expect(machine.state == .open(.none))
    }

    @Test func aCloseFrameEndsTheEventsAndStopsTheSilenceCheck() {
        var machine = open.after([.subscribeRequested, .subscribeReplied(channel: 7)])
        #expect(machine.handle(.eventsClosed) == [.endEvents(Machine.eventsStreamClosed), .stopLiveness])
        #expect(machine.state == .open(.closed))
        #expect(machine.eventsChannel == nil)
        #expect(machine.isOpen)
        #expect(machine.handle(.eventsClosed).isEmpty)
    }

    @Test func aCloseFrameWithoutALiveSubscriptionIsIgnored() {
        var machine = open.after([.subscribeRequested])
        #expect(machine.handle(.eventsClosed).isEmpty)
        #expect(machine.state == .open(.requested))
    }

    // MARK: Failure

    @Test func theFirstFailureTearsDownAndWins() {
        for events in [
            [Machine.Event](), [.openRequested], [.openRequested, .handshakeFinished],
            [.openRequested, .handshakeFinished, .subscribeRequested, .subscribeReplied(channel: 7)],
        ] {
            var machine = Machine().after(events)
            #expect(machine.handle(.failed(lost)) == [.tearDown(lost)])
            #expect(machine.handle(.failed(.cancelled)).isEmpty)
            #expect(machine.state == .failed(lost))
            #expect(machine.eventsChannel == nil)
            #expect(!machine.isOpen)
        }
    }

    @Test func eventsAfterFailureChangeNothing() {
        var machine = open.after([.failed(lost)])
        for event in [Machine.Event.subscribeReplied(channel: 1), .subscribeFailed, .eventsClosed, .handshakeFinished] {
            #expect(machine.handle(event).isEmpty)
        }
        #expect(machine.state == .failed(lost))
    }
}
