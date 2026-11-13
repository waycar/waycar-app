import Testing

@testable import Waycar

/// `CoreEventsMachine`: a herdr-core connection's subscription and its consumer.
@Suite("herdr-core events machine")
struct CoreEventsMachineTests {
    typealias Machine = CoreEventsMachine

    private let ended = TransportError.channelFailed(detail: "herdr-core ended the connection")
    /// Opening, connected, its subscribe under token 1.
    private let subscribing = Machine().after([.subscribeRequested, .connected])
    /// One consumer (stream 2) on a subscribed connection (pump 1).
    private let delivering = Machine().after([
        .subscribeRequested, .connected, .subscribed(token: 1), .attach, .openingEnded,
    ])

    // MARK: The first consumer

    @Test func theFirstConsumerSubscribesThenGetsItsStream() {
        var machine = Machine()
        #expect(machine.handle(.subscribeRequested).isEmpty)
        #expect(machine.state.consumer == .opening)
        #expect(machine.handle(.connected) == [.subscribe(token: 1)])
        #expect(machine.state.remote == .subscribing(token: 1))
        #expect(machine.handle(.subscribed(token: 1)) == [.startPump(pump: 1)])
        #expect(machine.state.remote == .subscribed(pump: 1))
        #expect(machine.handle(.attach) == [.deliver(stream: 2)])
        #expect(machine.state.consumer == .delivering(stream: 2))
        #expect(machine.handle(.openingEnded).isEmpty)
        #expect(machine.state.consumer == .delivering(stream: 2))
    }

    @Test func anotherConsumerWhileOneOpensOrDeliversIsRefused() {
        for start in [Machine().after([.subscribeRequested]), subscribing, delivering] {
            var machine = start
            #expect(machine.handle(.subscribeRequested) == [.refuse(.eventsChannelAlreadyOpen)])
            #expect(machine.state == start.state)
        }
    }

    @Test func aFailedSubscribeLeavesTheConnectionUnsubscribedForTheNextCall() {
        var machine = subscribing
        #expect(machine.handle(.subscribeFailed(token: 1)).isEmpty)
        #expect(machine.state.remote == .unsubscribed)
        _ = machine.handle(.openingEnded)
        #expect(machine.state.consumer == .none)
        _ = machine.handle(.subscribeRequested)
        #expect(machine.handle(.connected) == [.subscribe(token: 2)])
    }

    @Test func aStaleSubscribeAnswerIsIgnored() {
        var machine = subscribing
        #expect(machine.handle(.subscribed(token: 7)).isEmpty)
        #expect(machine.handle(.subscribeFailed(token: 7)).isEmpty)
        #expect(machine.state.remote == .subscribing(token: 1))
    }

    // MARK: Later consumers

    @Test func aLaterConsumerOfASubscribedConnectionNeedsNoRoundTrip() {
        var machine = delivering.after([.consumerEnded(stream: 2), .subscribeRequested])
        #expect(machine.handle(.connected).isEmpty)
        #expect(machine.handle(.attach) == [.deliver(stream: 3)])
        #expect(machine.state.remote == .subscribed(pump: 1))
    }

    @Test func endingTheStreamFinishesItCleanlyOnce() {
        var machine = delivering
        #expect(machine.handle(.consumerEnded(stream: 2)) == [.finishStream(failure: nil), .cancelResyncs])
        #expect(machine.state.consumer == .none)
        #expect(machine.handle(.consumerEnded(stream: 2)).isEmpty)
        #expect(machine.state.remote == .subscribed(pump: 1), "the subscription outlives its consumer")
    }

    @Test func aTerminatedStreamIsForgotten() {
        var machine = delivering
        #expect(machine.handle(.consumerTerminated(stream: 2)) == [.forgetStream, .cancelResyncs])
        #expect(machine.state.consumer == .none)
    }

    @Test func anOldStreamsEndLeavesItsReplacement() {
        var machine = delivering.after([.consumerEnded(stream: 2), .subscribeRequested, .connected, .attach])
        #expect(machine.state.consumer == .delivering(stream: 3))
        #expect(machine.handle(.consumerEnded(stream: 2)).isEmpty)
        #expect(machine.handle(.consumerTerminated(stream: 2)).isEmpty)
        #expect(machine.state.consumer == .delivering(stream: 3))
    }

    // MARK: The connection ending

    @Test func thePumpEndingFailsTheConsumerAndUnsubscribes() {
        var machine = delivering
        #expect(machine.handle(.connectionEnded(pump: 1, ended)) == [.finishStream(failure: ended), .cancelResyncs])
        #expect(machine.state == Machine.State(remote: .unsubscribed, consumer: .none))
    }

    @Test func thePumpEndingWithNoConsumerOnlyUnsubscribes() {
        var machine = delivering.after([.consumerEnded(stream: 2)])
        #expect(machine.handle(.connectionEnded(pump: 1, ended)) == [.cancelResyncs])
        #expect(machine.state.remote == .unsubscribed)
    }

    @Test func aStalePumpEndingIsIgnored() {
        var machine = delivering
        #expect(machine.handle(.connectionEnded(pump: 9, ended)).isEmpty)
        #expect(machine.state.consumer == .delivering(stream: 2))
    }

    @Test func closingTheLinkEndsTheConsumerCleanlyAndCancelsThePump() {
        var machine = delivering
        #expect(machine.handle(.linkClosed) == [.finishStream(failure: nil), .cancelResyncs, .cancelPump])
        #expect(machine.state == Machine.State(remote: .unsubscribed, consumer: .none))
        // The cancelled pump's own end changes nothing.
        #expect(machine.handle(.connectionEnded(pump: 1, ended)).isEmpty)
    }

    @Test func closingTheLinkWhileASubscribeRunsLeavesTheCallToEndItself() {
        var machine = subscribing
        #expect(machine.handle(.linkClosed) == [.cancelResyncs, .cancelPump])
        #expect(machine.state == Machine.State(remote: .unsubscribed, consumer: .opening))
        #expect(machine.handle(.subscribed(token: 1)).isEmpty)
        _ = machine.handle(.openingEnded)
        #expect(machine.state.consumer == .none)
    }
}
