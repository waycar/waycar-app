import Foundation
import Testing

@testable import Waycar

/// `UltimateInstanceStreamMachine`: one Ultimate project's stream, bootstrap and retry.
@Suite("Ultimate project stream machine")
struct UltimateInstanceStreamMachineTests {
    typealias Machine = UltimateInstanceStreamMachine

    private static let delays: [Duration] = [.seconds(1), .seconds(2), .seconds(5)]
    private static let summaries = [
        try! JSONDecoder().decode(UltimateConversationSummary.self, from: Data(#"{"id":1,"busy":true}"#.utf8))
    ]

    private let fresh = Machine(retryDelays: Self.delays).after([.streamOpened])
    /// Identified, listed and seeded with the shared UI.
    private var seeded: Machine {
        fresh.after([.identified, .listed(Self.summaries), .sharedUIApplied(snapshot: true)])
    }

    // MARK: Bootstrap

    @Test func listsAndSharedUIBeforeIdentityAreRefused() {
        var machine = fresh
        #expect(machine.handle(.listArrived) == [.refuseMissingIdentity])
        #expect(machine.handle(.sharedUIArrived) == [.refuseMissingIdentity])
        _ = machine.handle(.identified)
        #expect(machine.isIdentified)
        #expect(machine.handle(.listArrived).isEmpty)
        #expect(machine.handle(.sharedUIArrived).isEmpty)
    }

    @Test func nothingPublishesUntilTheListAndTheSharedUISnapshotArrive() {
        var machine = fresh.after([.identified])
        #expect(machine.handle(.eventDone).isEmpty)
        _ = machine.handle(.listed(Self.summaries))
        #expect(machine.handle(.eventDone).isEmpty)
        _ = machine.handle(.sharedUIApplied(snapshot: false))
        #expect(machine.handle(.eventDone).isEmpty, "uiOps before the ui snapshot does not seed")
        _ = machine.handle(.sharedUIApplied(snapshot: true))
        #expect(machine.handle(.eventDone) == [.publish(Self.summaries)])
        #expect(machine.handle(.eventDone) == [.publish(Self.summaries)], "every later event republishes")
    }

    @Test func theBoardSubscribesOnceAfterIdentityAndTheStreamID() {
        var machine = fresh.after([.streamAnnounced(id: "abcd")])
        #expect(machine.handle(.eventDone).isEmpty, "not before the identity check")
        _ = machine.handle(.identified)
        #expect(machine.handle(.eventDone) == [.subscribeBoard(streamID: "abcd")])
        _ = machine.handle(.boardSubscribed)
        #expect(machine.handle(.eventDone).isEmpty)
    }

    @Test func aStreamWithoutAnIDNeverSubscribesTheBoard() {
        var machine = fresh.after([.identified, .streamAnnounced(id: nil)])
        #expect(machine.handle(.eventDone).isEmpty)
    }

    @Test func boardSubscriptionComesBeforeThePublishOfTheSameEvent() {
        var machine = seeded.after([.streamAnnounced(id: "s1")])
        #expect(machine.handle(.eventDone) == [.subscribeBoard(streamID: "s1"), .publish(Self.summaries)])
    }

    @Test func everyAttemptStartsFromAFreshBootstrap() {
        var machine = seeded.after([.streamAnnounced(id: "s1"), .boardSubscribed, .streamFailed, .retryDecided(true)])
        _ = machine.handle(.backoffElapsed)
        _ = machine.handle(.streamOpened)
        #expect(!machine.isIdentified)
        #expect(machine.handle(.listArrived) == [.refuseMissingIdentity])
        _ = machine.handle(.identified)
        _ = machine.handle(.streamAnnounced(id: "s2"))
        #expect(machine.handle(.eventDone) == [.subscribeBoard(streamID: "s2")])
    }

    // MARK: Readiness

    @Test func theFirstPublishSignalsReadinessOnce() {
        var machine = seeded
        #expect(machine.handle(.published) == [.signalReady])
        #expect(machine.handle(.published).isEmpty)
        #expect(machine.handle(.stop).isEmpty)
    }

    @Test func aFailureBeforeAnyPublishSignalsReadinessOnceTheTransportDecided() {
        var machine = fresh
        #expect(machine.handle(.streamFailed) == [.report(afterRetry: false)])
        #expect(machine.handle(.retryDecided(true)) == [.signalReady, .backOff(.seconds(1))])
        _ = machine.handle(.backoffElapsed)
        _ = machine.handle(.streamOpened)
        #expect(machine.handle(.streamFailed) == [.report(afterRetry: true)])
        #expect(machine.handle(.retryDecided(true)) == [.backOff(.seconds(2))])
    }

    @Test func aPumpEndingBeforeItsFirstReportStillSignals() {
        var machine = fresh
        #expect(machine.handle(.stop) == [.signalReady])
        #expect(machine.state.phase == .stopped)
        #expect(machine.handle(.stop).isEmpty)
    }

    // MARK: Retry

    @Test func theTransportRefusingARetryStopsThePump() {
        var machine = seeded.after([.published, .streamFailed])
        #expect(machine.handle(.retryDecided(false)).isEmpty)
        #expect(machine.state.phase == .stopped)
        #expect(machine.handle(.streamOpened).isEmpty)
        #expect(machine.state.phase == .stopped)
    }

    @Test func backOffFollowsTheDelaysAndStaysAtTheLast() {
        var machine = fresh
        var delays: [Duration] = []
        for _ in 0..<5 {
            _ = machine.handle(.streamFailed)
            for case .backOff(let delay) in machine.handle(.retryDecided(true)) { delays.append(delay) }
            _ = machine.handle(.backoffElapsed)
            _ = machine.handle(.streamOpened)
        }
        #expect(delays == [.seconds(1), .seconds(2), .seconds(5), .seconds(5), .seconds(5)])
    }

    @Test func publishingAgainStartsTheRetriesOver() {
        var machine = fresh.after([.streamFailed, .retryDecided(true), .backoffElapsed, .streamOpened])
        #expect(machine.state.failures == 1)
        _ = machine.handle([.identified, .listed(Self.summaries), .sharedUIApplied(snapshot: true), .published])
        #expect(machine.state.failures == 0)
        #expect(machine.handle(.streamFailed) == [.report(afterRetry: false)])
    }

    @Test func anEmptyDelayListBacksOffThirtySeconds() {
        var machine = Machine(retryDelays: []).after([.streamOpened, .streamFailed])
        #expect(machine.handle(.retryDecided(true)).contains(.backOff(.seconds(30))))
    }
}
