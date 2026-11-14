import Testing

@testable import Waycar

/// `EventsSubscriptionMachine` (HERDR-03): one test per transition, plus the
/// stale and ignored cases. The owner suites are
/// `EventsSessionSubscriptionsTests` and `EventsSessionConnectFlowTests`.
@Suite("EventsSubscriptionMachine")
struct EventsSubscriptionMachineTests {
    private let globals: [EventSubscription] = [.global(.paneAgentDetected)]
    private var withPane: [EventSubscription] {
        globals + [.pane(.agentStatusChanged, paneID: "w1:p1")]
    }
    private var withReorder: [EventSubscription] { globals + [.global(.workspaceReordered)] }
    private let rejection = TransportError.apiRejected(code: "invalid_params", message: "no")
    private let missingPane = TransportError.apiRejected(code: "pane_not_found", message: "gone")

    private func live(_ subscriptions: [EventSubscription]) -> EventsSubscriptionMachine {
        EventsSubscriptionMachine(subscriptions: subscriptions).after([
            .answered(asked: subscriptions), .accepted, .goLive,
        ])
    }

    @Test func aFreshSetIsASeed() {
        let machine = EventsSubscriptionMachine(subscriptions: withPane)
        #expect(machine.state.stage == .seeded)
        #expect(machine.requested == withPane)
        #expect(machine.liveChannel == nil)
    }

    @Test func seedingReplacesTheSetAndMakesItASeed() {
        var machine = EventsSubscriptionMachine(subscriptions: globals).after([
            .update(withPane, active: false)
        ])
        #expect(machine.state.stage == .subscribing)
        #expect(machine.handle(.seed(withReorder)) == [])
        #expect(machine.state.stage == .seeded)
        #expect(machine.requested == withReorder)
    }

    @Test func anUnchangedUpdateDoesNothing() {
        var machine = live(globals)
        let before = machine.state
        #expect(machine.handle(.update(globals, active: true)) == [])
        #expect(machine.state == before)
    }

    @Test func anUpdateWithNoLiveChannelReplacesTheSetAndEndsTheSeed() {
        var machine = EventsSubscriptionMachine(subscriptions: globals)
        #expect(machine.handle(.update(withPane, active: true)) == [])
        #expect(machine.state == .init(requested: withPane, stage: .subscribing))
    }

    @Test func anUpdateWhileLiveEndsTheChannelAndAsksForAReplacement() {
        var machine = live(globals)
        #expect(machine.handle(.update(withPane, active: true)) == [.endChannel(1)])
        #expect(machine.state == .init(requested: withPane, stage: .live(channel: 1), replacing: true))
    }

    @Test func anUpdateWhileLiveButInactiveOnlyReplacesTheSet() {
        var machine = live(globals)
        #expect(machine.handle(.update(withPane, active: false)) == [])
        #expect(machine.state == .init(requested: withPane, stage: .live(channel: 1)))
    }

    @Test func anAnswerForTheRequestedSetGoesOn() {
        var machine = EventsSubscriptionMachine(subscriptions: globals)
        #expect(machine.handle(.answered(asked: globals)) == [])
    }

    @Test func anAnswerForAnOlderSetSubscribesAgain() {
        var machine = EventsSubscriptionMachine(subscriptions: globals).after([
            .update(withPane, active: true)
        ])
        #expect(machine.handle(.answered(asked: globals)) == [.subscribeAgain])
        #expect(machine.state.stage == .subscribing)
    }

    @Test func anAnswerOnAReplacedTransportClearsTheReplacementForTheCurrentRun() {
        var machine = live(globals).after([.replace, .channelEnded(channel: 1)])
        #expect(machine.state.replacing)
        #expect(machine.handle(.answeredOnReplacedTransport(activationCurrent: true)) == [.subscribeAgain])
        #expect(!machine.state.replacing)
    }

    @Test func anAnswerOnAReplacedTransportOfAStaleRunKeepsTheReplacement() {
        var machine = live(globals).after([.replace, .channelEnded(channel: 1)])
        #expect(machine.handle(.answeredOnReplacedTransport(activationCurrent: false)) == [.subscribeAgain])
        #expect(machine.state.replacing)
    }

    @Test func acceptanceEndsTheSeed() {
        var machine = EventsSubscriptionMachine(subscriptions: withPane)
        #expect(machine.handle(.accepted) == [])
        #expect(machine.state.stage == .subscribing)
        #expect(machine.handle(.connectFailed(rejection)) == [])
        #expect(machine.requested == withPane)
    }

    @Test func goingLiveKeepsTheStreamUnderAFreshChannel() {
        var machine = EventsSubscriptionMachine(subscriptions: globals).after([.accepted])
        #expect(machine.handle(.goLive) == [.retain(channel: 1)])
        #expect(machine.liveChannel == 1)
        _ = machine.handle([.channelEnded(channel: 1), .streamFinished, .accepted])
        #expect(machine.handle(.goLive) == [.retain(channel: 2)])
        #expect(machine.isLive(2))
        #expect(!machine.isLive(1))
    }

    @Test func theLiveChannelEndingStopsTheKeepaliveAndForgetsIt() {
        var machine = live(globals)
        #expect(machine.handle(.channelEnded(channel: 1)) == [.stopKeepalive, .forget(channel: 1)])
        #expect(machine.state.stage == .subscribing)
    }

    @Test func anOlderChannelEndingIsIgnored() {
        var machine = live(globals).after([
            .channelEnded(channel: 1), .streamFinished, .accepted, .goLive,
        ])
        let before = machine.state
        #expect(machine.handle(.channelEnded(channel: 1)) == [])
        #expect(machine.state == before)
    }

    @Test func aStreamFinishedOnPurposeSubscribesAgainOnce() {
        var machine = live(globals).after([.update(withPane, active: true), .channelEnded(channel: 1)])
        #expect(machine.handle(.streamFinished) == [.subscribeAgain])
        #expect(machine.handle(.streamFinished) == [])
    }

    @Test func aStreamThatFailedOnItsOwnAsksNothing() {
        var machine = live(globals).after([.channelEnded(channel: 1)])
        #expect(machine.handle(.streamFinished) == [])
    }

    @Test func aRejectedSeedFallsBackToTheGlobalSetOnce() {
        var machine = EventsSubscriptionMachine(subscriptions: withReorder)
        #expect(machine.handle(.connectFailed(rejection)) == [.retryAtOnce])
        #expect(machine.state == .init(requested: globals, stage: .globalFallback))
        #expect(machine.handle(.connectFailed(rejection)) == [])
        #expect(machine.requested == globals)
    }

    @Test func aRejectedSeedWithNothingToDropIsASeedNoMore() {
        var machine = EventsSubscriptionMachine(subscriptions: globals)
        #expect(machine.handle(.connectFailed(rejection)) == [])
        #expect(machine.state == .init(requested: globals, stage: .subscribing))
    }

    @Test func aMissingPaneFallsBackWhetherOrNotTheSetIsASeed() {
        var machine = EventsSubscriptionMachine(subscriptions: globals).after([
            .accepted, .update(withPane, active: true),
        ])
        #expect(machine.handle(.connectFailed(missingPane)) == [.retryAtOnce])
        #expect(machine.state.stage == .globalFallback)
        #expect(machine.handle(.connectFailed(missingPane)) == [])
    }

    @Test func aLinkFailureLeavesTheSetForTheDisconnect() {
        var machine = EventsSubscriptionMachine(subscriptions: withPane)
        #expect(machine.handle(.connectFailed(.sshUnreachable(detail: "gone"))) == [])
        #expect(machine.state == .init(requested: withPane, stage: .seeded))
        #expect(machine.handle(.disconnected) == [])
        #expect(machine.state == .init(requested: globals, stage: .globalFallback))
    }

    @Test func aDisconnectWithNothingToDropKeepsTheSet() {
        var machine = live(globals).after([.channelEnded(channel: 1)])
        #expect(machine.handle(.disconnected) == [])
        #expect(machine.state == .init(requested: globals, stage: .subscribing))
    }

    @Test func aReplacementEndsTheLiveChannel() {
        var machine = live(globals)
        #expect(machine.handle(.replace) == [.endChannel(1)])
        #expect(machine.state.replacing)
    }

    /// B-46: with no live channel there is nothing to replace, and the run
    /// loop subscribes afresh anyway, so nothing is requested: the next
    /// channel's loss is an ordinary one.
    @Test func aReplacementWithNoLiveChannelRequestsNothing() {
        var machine = live(globals).after([.channelEnded(channel: 1)])
        #expect(machine.handle(.replace) == [])
        #expect(!machine.state.replacing)
        _ = machine.handle([.accepted, .goLive, .channelEnded(channel: 2)])
        #expect(machine.handle(.streamFinished) == [])
    }

    @Test func teardownTakesTheLiveChannel() {
        var machine = live(withPane)
        #expect(machine.handle(.windDownStarted) == [.take(channel: 1)])
        #expect(machine.liveChannel == nil)
        #expect(machine.handle(.windDownStarted) == [])
    }

    @Test func teardownEndsWithTheGlobalSetAndNoReplacement() {
        var machine = live(withPane).after([.replace, .windDownStarted])
        #expect(machine.handle(.woundDown) == [])
        #expect(machine.state == .init(requested: globals, stage: .globalFallback))
    }

    @Test func anUpdateDuringTeardownIsDroppedWithIt() {
        var machine = live(globals).after([.windDownStarted, .update(withPane, active: true)])
        #expect(machine.requested == withPane)
        _ = machine.handle(.woundDown)
        #expect(machine.requested == globals)
    }
}
