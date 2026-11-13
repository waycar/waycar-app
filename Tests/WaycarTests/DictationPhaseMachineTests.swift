import Testing

@testable import Waycar

@Suite("Dictation phase machine")
struct DictationPhaseMachineTests {
    @Test func startsOnlyWhileIdleAndClearsFailure() {
        var machine = DictationPhaseMachine()
        #expect(machine.handle(.start) == [.start(1)])
        #expect(machine.phase == .starting)
        #expect(machine.handle(.start) == [])
        #expect(machine.handle(.ended(1, .microphonePermissionDenied)) == [.end(1)])
        #expect(machine.phase == .idle)
        #expect(machine.failure == .microphonePermissionDenied)
        #expect(machine.level == 0)
        #expect(machine.handle(.start) == [.start(2)])
        #expect(machine.failure == nil)
    }

    @Test func downloadingListeningAndLevelsFollowEngineEvents() {
        var machine = DictationPhaseMachine().after([.start])
        #expect(machine.handle(.engine(1, .downloadingModel(fraction: 0.4))) == [])
        #expect(machine.phase == .downloadingModel(fraction: 0.4))
        #expect(machine.handle(.engine(1, .level(0.3))) == [])
        #expect(machine.level == 0.3)
        #expect(machine.handle(.engine(1, .listening)) == [])
        #expect(machine.phase == .listening)
        #expect(machine.level == 0.3)
        #expect(machine.handle(.engine(1, .level(0.7))) == [])
        #expect(machine.level == 0.7)
    }

    @Test func stopFlattensAndFinishingIgnoresLateProgressButNotWords() {
        var machine = DictationPhaseMachine().after([
            .start, .engine(1, .listening), .engine(1, .level(0.9)),
        ])
        #expect(machine.handle(.stop) == [.finish(1)])
        #expect(machine.phase == .finishing)
        #expect(machine.level == 0)
        #expect(machine.handle([
            .stop, .engine(1, .listening), .engine(1, .downloadingModel(fraction: 0.5)),
            .engine(1, .level(1)),
        ]) == [])
        #expect(machine.phase == .finishing)
        #expect(machine.level == 0)
        #expect(machine.handle(.engine(1, .transcript("last", isFinal: true))) == [
            .transcript(1, "last", isFinal: true),
        ])
        #expect(machine.handle(.ended(1, nil)) == [.end(1)])
        #expect(machine.phase == .idle)
    }

    @Test(arguments: [false, true])
    func stoppingStartupCancelsWithoutChangingItsVisiblePhase(downloading: Bool) {
        var machine = DictationPhaseMachine().after([.start])
        if downloading { _ = machine.handle(.engine(1, .downloadingModel(fraction: 0.2))) }
        let phase = machine.phase
        #expect(machine.handle(.stop) == [.cancel(1)])
        #expect(machine.phase == phase)
        #expect(machine.handle(.start) == [])
        #expect(machine.handle(.ended(1, nil)) == [.end(1)])
        #expect(machine.phase == .idle)
    }

    @Test func cancellationKeepsBufferedEventsUntilMatchingStreamEnds() {
        var machine = DictationPhaseMachine().after([.start, .engine(1, .listening)])
        #expect(machine.handle(.cancel) == [.cancel(1)])
        #expect(machine.phase == .listening)
        #expect(machine.handle(.engine(1, .transcript("partial", isFinal: false))) == [
            .transcript(1, "partial", isFinal: false),
        ])
        #expect(machine.handle(.engine(1, .level(0.2))) == [])
        #expect(machine.level == 0.2)
        #expect(machine.handle(.stop) == [.finish(1)])
        #expect(machine.phase == .finishing)
        #expect(machine.handle(.cancel) == [.cancel(1)])
        #expect(machine.handle(.engine(1, .level(1))) == [])
        #expect(machine.level == 0)
        #expect(machine.handle(.ended(1, nil)) == [.end(1)])
        #expect(machine.token == nil)
    }

    @Test func cancellingStartupRetainsProgressAndCanStillReceiveListening() {
        var machine = DictationPhaseMachine().after([.start, .cancel])
        #expect(machine.handle(.engine(1, .downloadingModel(fraction: 0.5))) == [])
        #expect(machine.phase == .downloadingModel(fraction: 0.5))
        #expect(machine.handle(.engine(1, .listening)) == [])
        #expect(machine.phase == .listening)
        #expect(machine.handle(.cancel) == [.cancel(1)])
    }

    @Test func staleSessionEventsCannotTouchTheReplacement() {
        var machine = DictationPhaseMachine().after([.start, .ended(1, nil), .start])
        #expect(machine.token == 2)
        #expect(machine.handle([
            .engine(1, .listening), .engine(1, .transcript("old", isFinal: true)),
            .ended(1, .message("old failure")),
        ]) == [])
        #expect(machine.phase == .starting)
        #expect(machine.failure == nil)
        #expect(machine.handle(.engine(2, .transcript("new", isFinal: true))) == [
            .transcript(2, "new", isFinal: true),
        ])
    }

    @Test func idleIgnoresSessionEventsAndDismissesFailure() {
        var machine = DictationPhaseMachine()
        #expect(machine.handle([.stop, .cancel, .engine(1, .listening), .ended(1, nil)]) == [])
        #expect(machine.phase == .idle)
        _ = machine.handle([.start, .ended(1, .message("failure"))])
        #expect(machine.handle(.dismissFailure) == [])
        #expect(machine.failure == nil)
    }
}
