import Testing

@testable import Waycar

/// `UltimateTransportMachine`: the Ultimate transport across its projects.
@Suite("Ultimate transport machine")
struct UltimateTransportMachineTests {
    typealias Machine = UltimateTransportMachine

    /// Streaming at epoch 1.
    private let streaming = Machine().after([.subscribe])

    // MARK: One-shot reads (ULT-01)

    @Test func aReadAtTheCurrentEpochKeepsOrDropsItsProject() {
        var machine = Machine()
        #expect(machine.handle(.snapshotRead(epoch: 0, instance: "a", listed: true)) == [.keepListing(instance: "a")])
        #expect(machine.state.online == ["a"])
        #expect(machine.handle(.snapshotRead(epoch: 0, instance: "a", listed: false)) == [.dropListing(instance: "a")])
        #expect(machine.state.online.isEmpty)
    }

    @Test func aReadThatWaitedAcrossAStreamIsSuperseded() {
        for events in [[Machine.Event.subscribe], [.subscribe, .endStream(stream: 1)], [.distrust], [.close]] {
            var machine = Machine().after(events)
            #expect(machine.handle(.snapshotRead(epoch: 0, instance: "a", listed: true)) == [.superseded])
            #expect(machine.handle(.snapshotRead(epoch: 0, instance: "a", listed: false)) == [.superseded])
            #expect(machine.state.online.isEmpty)
        }
    }

    @Test func aFailedPingForgetsEveryProjectOnlyWithoutAStream() {
        var idle = Machine().after([.snapshotRead(epoch: 0, instance: "a", listed: true)])
        #expect(idle.handle(.pingFailed) == [.forgetConversations])
        #expect(idle.state.online.isEmpty)
        var live = streaming.after([.published(stream: 1, instance: "a")])
        #expect(live.handle(.pingFailed).isEmpty)
        #expect(live.state.online == ["a"])
    }

    // MARK: Streams

    @Test func subscribingStartsPumpsAtANewEpochAndClearsRetries() {
        var machine = Machine()
        #expect(machine.handle(.subscribe) == [.startPumps(stream: 1)])
        #expect(machine.state.streaming)
        #expect(machine.isCurrent(stream: 1))
        #expect(machine.handle(.subscribe).isEmpty, "one stream at a time")
        var again = streaming.after([
            .instanceFailed(stream: 1, instance: "a", afterRetry: true, projects: 2),
            .endStream(stream: 1),
        ])
        #expect(again.state.failedAfterRetry == ["a"])
        #expect(again.handle(.subscribe) == [.startPumps(stream: 3)])
        #expect(again.state.failedAfterRetry.isEmpty)
    }

    @Test func aPublishedProjectIsOnlineAndNoLongerFailing() {
        var machine = streaming.after([.instanceFailed(stream: 1, instance: "a", afterRetry: true, projects: 2)])
        #expect(machine.handle(.published(stream: 1, instance: "a")) == [.keepPublished(instance: "a")])
        #expect(machine.state.online == ["a"])
        #expect(machine.state.failedAfterRetry.isEmpty)
        #expect(machine.handle(.questionsCounted(stream: 1, instance: "a")) == [.keepQuestions(instance: "a")])
    }

    @Test func reportsOfAnEndedStreamAreIgnored() {
        var machine = streaming.after([.endStream(stream: 1)])
        #expect(machine.handle(.published(stream: 1, instance: "a")).isEmpty)
        #expect(machine.handle(.questionsCounted(stream: 1, instance: "a")).isEmpty)
        #expect(machine.handle(.instanceFailed(stream: 1, instance: "a", afterRetry: true, projects: 1)).isEmpty)
        #expect(machine.state.online.isEmpty)
        #expect(machine.state.lifecycle == .inService)
    }

    @Test func aFailingProjectIsForgottenAndRetried() {
        var machine = streaming.after([
            .published(stream: 1, instance: "a"), .published(stream: 1, instance: "b"),
        ])
        #expect(
            machine.handle(.instanceFailed(stream: 1, instance: "a", afterRetry: true, projects: 2))
                == [.forgetProject(instance: "a"), .retry])
        #expect(machine.state.online == ["b"])
        #expect(machine.state.lifecycle == .inService)
    }

    @Test func aFirstFailureNeverLosesTheTransport() {
        var machine = streaming
        #expect(
            machine.handle(.instanceFailed(stream: 1, instance: "a", afterRetry: false, projects: 1))
                == [.forgetProject(instance: "a"), .retry])
        #expect(machine.state.lifecycle == .inService)
    }

    @Test func everyProjectFailingAfterARetryLosesTheTransport() {
        var machine = streaming.after([.instanceFailed(stream: 1, instance: "a", afterRetry: true, projects: 2)])
        #expect(
            machine.handle(.instanceFailed(stream: 1, instance: "b", afterRetry: true, projects: 2))
                == [.forgetProject(instance: "b"), .failStream(Machine.offline), .endStream])
        #expect(machine.state.lifecycle == .lost)
        #expect(!machine.state.streaming)
        #expect(machine.refusal == Machine.offline)
    }

    @Test func anOldStreamsEndLeavesItsReplacement() {
        var machine = streaming.after([.endStream(stream: 1), .subscribe])
        #expect(machine.isCurrent(stream: 3))
        #expect(machine.handle(.endStream(stream: 1)).isEmpty)
        #expect(machine.isCurrent(stream: 3))
        #expect(machine.handle(.endStream(stream: 3)) == [.endStream])
        #expect(!machine.state.streaming)
    }

    // MARK: Lifetime

    @Test func distrustEndsTheStreamAndRefusesButKeepsTheHold() {
        var machine = streaming
        #expect(machine.handle(.distrust) == [.endStream])
        #expect(machine.state.lifecycle == .distrusted)
        #expect(machine.refusal == .cancelled)
        #expect(machine.handle(.close) == [.endStream, .release])
        #expect(machine.isClosed)
    }

    @Test func closeReleasesOnceAndWinsOverLost() {
        var machine = streaming.after([.instanceFailed(stream: 1, instance: "a", afterRetry: true, projects: 1)])
        #expect(machine.refusal == Machine.offline)
        #expect(machine.handle(.close) == [.endStream, .release])
        #expect(machine.refusal == .cancelled)
        #expect(machine.handle(.close).isEmpty)
        #expect(machine.handle(.distrust).isEmpty)
        #expect(machine.handle(.subscribe).isEmpty)
    }

    @Test func abandoningAFailedOpenClosesWithoutRelease() {
        var machine = Machine()
        #expect(machine.handle(.abandon).isEmpty)
        #expect(machine.isClosed)
        #expect(machine.handle(.close).isEmpty)
    }
}
