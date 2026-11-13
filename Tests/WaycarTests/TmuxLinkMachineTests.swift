import Testing

@testable import Waycar

/// `TmuxLinkMachine`: a tmux transport's control link, its dials and how
/// the transport ends.
@Suite("tmux link machine")
struct TmuxLinkMachineTests {
    typealias Machine = TmuxLinkMachine

    private let dialing = Machine().after([.connect, .dialStarted])
    private let kept = Machine().after([
        .connect, .dialStarted, .sessionsListed(generation: 1, anchored: true),
        .startupAnswered(generation: 1), .dialEnded,
    ])

    // MARK: Dialing

    @Test func aDialIsSingleFlight() {
        var machine = Machine()
        #expect(machine.handle(.connect) == [.dial])
        #expect(machine.state.dialing)
        #expect(machine.handle(.connect) == [.join])
        #expect(machine.handle(.dialEnded).isEmpty)
        #expect(!machine.state.dialing)
        #expect(machine.handle(.connect) == [.dial])
    }

    @Test func aDialListsUnderTheNextGeneration() {
        var machine = Machine().after([.connect])
        #expect(machine.handle(.dialStarted) == [.listSessions(generation: 1)])
        #expect(machine.state.generation == 1)
        #expect(machine.state.link == .idle)
    }

    @Test func aDialOverAKeptClientClosesItFirst() {
        var machine = kept.after([.connect])
        #expect(machine.handle(.dialStarted)
            == [.closeClient(generation: 1), .listSessions(generation: 2)])
        #expect(machine.state.link == .lost)
        #expect(!machine.accepts(generation: 1))
    }

    @Test func noSessionToAnchorOnGoesIdle() {
        var machine = dialing
        #expect(machine.handle(.sessionsListed(generation: 1, anchored: false)) == [.enterIdle])
        #expect(machine.state.link == .idle)
    }

    @Test func anAnchorOpensAClientThatIsKeptOnceItAnswers() {
        var machine = dialing
        #expect(machine.handle(.sessionsListed(generation: 1, anchored: true))
            == [.openClient(generation: 1)])
        #expect(machine.handle(.startupAnswered(generation: 1))
            == [.recordServer, .keep(generation: 1)])
        #expect(machine.state.link == .control(generation: 1))
        #expect(machine.controlGeneration == 1)
        #expect(machine.accepts(generation: 1))
        #expect(!machine.accepts(generation: 0))
    }

    @Test func aSupersededDialIsDiscarded() {
        var machine = dialing.after([.sessionsListed(generation: 1, anchored: true)])
        #expect(machine.handle(.startupAnswered(generation: 0))
            == [.recordServer, .discard(generation: 0)])
        #expect(machine.state.link == .idle)
    }

    // MARK: Ending a client

    @Test func aClientEndedInOrderEndsTheEvents() {
        var machine = kept
        #expect(machine.handle(.clientEnded(.closed)) == [.finishEvents(nil)])
        #expect(machine.state.link == .lost)
        #expect(machine.controlGeneration == nil)
    }

    @Test func aLostClientFailsTheEvents() {
        var machine = kept
        #expect(machine.handle(.clientEnded(.lost("boom")))
            == [.finishEvents(.channelFailed(detail: "tmux control channel lost: boom"))])
        #expect(machine.state.link == .lost)
    }

    @Test func anExitedClientIsDialedAgain() {
        var machine = kept
        #expect(machine.handle(.clientEnded(.exited(reason: "detached"))) == [.reattach])
        #expect(machine.state.link == .lost)
        #expect(machine.handle(.connect) == [.dial])
    }

    // MARK: Distrust and close

    @Test func distrustEndsControlAndSupersedesTheDialInFlight() {
        var machine = dialing.after([.sessionsListed(generation: 1, anchored: true)])
        #expect(machine.handle(.distrust) == [.endControl(closing: nil)])
        #expect(machine.state.standing == .distrusted)
        #expect(machine.refusal == Machine.replacedError)
        #expect(machine.handle(.startupAnswered(generation: 1)) == [.refuse(Machine.replacedError)])
        #expect(machine.handle(.distrust).isEmpty)
    }

    @Test func distrustClosesTheKeptClientAndRefusesEveryDial() {
        var machine = kept
        #expect(machine.handle(.distrust) == [.endControl(closing: 1)])
        #expect(machine.state.link == .lost)
        #expect(!machine.accepts(generation: 1))
        #expect(!machine.isClosed)
        #expect(machine.handle(.connect) == [.dial])
        #expect(machine.handle(.dialStarted) == [.refuse(Machine.replacedError)])
        #expect(machine.handle(.sessionsListed(generation: 2, anchored: true))
            == [.refuse(Machine.replacedError)])
    }

    @Test func closeEndsControlOnceAndRefusesEverything() {
        var machine = kept
        #expect(machine.handle(.close) == [.endControl(closing: 1)])
        #expect(machine.isClosed)
        #expect(machine.refusal == Machine.closedError)
        #expect(!machine.accepts(generation: 1))
        #expect(machine.handle(.close).isEmpty)
        #expect(machine.handle(.distrust).isEmpty)
        #expect(machine.handle(.dialStarted) == [.refuse(Machine.closedError)])
    }

    @Test func closeAfterDistrustStillCloses() {
        var machine = kept.after([.distrust])
        #expect(machine.handle(.close) == [.endControl(closing: nil)])
        #expect(machine.isClosed)
        #expect(machine.refusal == Machine.closedError)
    }

    @Test func aDialClosedWhileItListsIsRefused() {
        var machine = dialing.after([.close])
        #expect(machine.handle(.sessionsListed(generation: 1, anchored: true))
            == [.refuse(Machine.closedError)])
        #expect(machine.handle(.startupAnswered(generation: 1)) == [.refuse(Machine.closedError)])
    }
}
