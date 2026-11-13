import Testing
@testable import Waycar

@Suite("Car speaker line machine")
struct CarSpeakerLineMachineTests {
    typealias Machine = CarSpeakerLineMachine

    @Test func startAndCompletion() {
        var machine = Machine()
        let line = Machine.Line(token: 0, attempt: .primary, text: "One.")
        #expect(machine.handle(.start("One.")) == [.play(line)])
        #expect(machine.state == .playing(line))
        #expect(machine.handle(.completed(0, .spoken)) == [.release, .finished(true)])
        #expect(machine.state == .idle)
    }

    @Test(arguments: [Machine.Outcome.stopped, .silenced])
    func stoppedOrSilencedNeverRetry(_ outcome: Machine.Outcome) {
        var machine = Machine().after([.start("One.")])
        #expect(machine.handle(.completed(0, outcome)) == [.release, .finished(false)])
        #expect(machine.state == .idle)
    }

    @Test func retryThenFallbackRetainUnfinishedText() {
        var machine = Machine().after([.start("One. Two.")])
        #expect(machine.handle(.completed(0, .failed(rest: "Two.", usedSystem: false))) == [.release, .waitForInterruption(0)])
        let retry = Machine.Line(token: 0, attempt: .retry, text: "Two.")
        #expect(machine.state == .retrying(retry))
        #expect(machine.handle(.retryReady(0, cancelled: false)) == [.play(retry)])
        let fallback = Machine.Line(token: 0, attempt: .system, text: "Two.")
        #expect(machine.handle(.completed(0, .failed(rest: "Two.", usedSystem: false))) == [.release, .play(fallback)])
        #expect(machine.state == .systemFallback(fallback))
        #expect(machine.handle(.completed(0, .failed(rest: "Two.", usedSystem: true))) == [.release, .finished(false)])
    }

    @Test func aSystemRetryDoesNotFallbackAgain() {
        var machine = Machine().after([
            .start("One."), .completed(0, .failed(rest: "One.", usedSystem: true)),
            .retryReady(0, cancelled: false),
        ])
        #expect(machine.handle(.completed(0, .failed(rest: "One.", usedSystem: true))) == [.release, .finished(false)])
    }

    @Test func replacementOwnsCallbacksAndWatchTokens() {
        var machine = Machine().after([.start("Old"), .hold, .stop, .start("New"), .hold])
        let held = machine.state
        #expect(machine.stops == 1)
        #expect(machine.handle(.completed(0, .spoken)) == [.finished(false)])
        #expect(machine.handle(.holdExpired(1)).isEmpty)
        #expect(machine.handle(.retryReady(0, cancelled: false)) == [.finished(false)])
        #expect(machine.state == held)
        #expect(machine.holds(2))
        #expect(!machine.holds(1))
    }

    @Test func cancelledRetryStopsBeforePlaying() {
        var machine = Machine().after([.start("One"), .completed(0, .failed(rest: "One", usedSystem: false))])
        #expect(machine.handle(.retryReady(0, cancelled: true)) == [.finished(false)])
        #expect(machine.state == .idle)
    }

    @Test func holdResumeAndRepeatedProgressWindows() {
        var machine = Machine().after([.start("One")])
        #expect(machine.handle(.hold) == [.watchHold(1)])
        #expect(machine.isHeld)
        #expect(machine.handle(.resume(progress: 3, succeeded: true)) == [.release, .watchProgress(2)])
        #expect(machine.handle(.progress(1, 3)).isEmpty)
        #expect(machine.handle(.progress(2, 4)).isEmpty)
        #expect(machine.handle(.progress(2, 4)) == [.stopEngine])
        #expect(!machine.isHeld)
    }

    @Test func anotherPauseInvalidatesThePreviousProgressWatch() {
        var machine = Machine().after([.start("One"), .hold, .resume(progress: 0, succeeded: true)])
        #expect(machine.handle(.hold) == [.watchHold(3)])
        let held = machine.state
        #expect(machine.handle(.progress(2, 0)).isEmpty)
        #expect(machine.state == held)
        #expect(machine.handle(.stop) == [.stopEngine, .release])
        #expect(machine.handle(.completed(0, .spoken)) == [.finished(false)])
        #expect(machine.state == .idle)
    }

    @Test func failedResumeAndExpiredHoldCutTheEngine() {
        var machine = Machine().after([.start("One"), .hold])
        #expect(machine.handle(.resume(progress: 0, succeeded: false)) == [.release, .stopEngine])
        #expect(machine.handle(.hold) == [.watchHold(2)])
        #expect(machine.handle(.holdExpired(2)) == [.stopEngine])
        #expect(!machine.isHeld)
    }

    @Test func fallbackCanPauseAndResumeOrExpire() {
        var machine = Machine().after([
            .start("One"), .completed(0, .failed(rest: "One", usedSystem: false)),
            .retryReady(0, cancelled: false), .completed(0, .failed(rest: "One", usedSystem: false)),
            .hold,
        ])
        #expect(machine.handle(.resume(progress: 0, succeeded: false)) == [.release, .stopEngine])
        guard case .systemFallback = machine.state else { Issue.record("Lost fallback attempt"); return }
        #expect(machine.handle(.hold) == [.watchHold(2)])
        #expect(machine.handle(.holdExpired(2)) == [.stopEngine])
        guard case .systemFallback = machine.state else { Issue.record("Lost fallback after hold"); return }
    }

    @Test func ignoredEventsAndReplacedHold() {
        var machine = Machine()
        #expect(machine.handle([.hold, .resume(progress: 0, succeeded: true), .progress(1, 0), .holdExpired(1)]).isEmpty)
        _ = machine.handle(.start("One"))
        _ = machine.handle(.hold)
        #expect(machine.handle(.hold) == [.watchHold(2)])
        #expect(machine.handle(.holdExpired(1)).isEmpty)
        _ = machine.handle(.completed(0, .failed(rest: "One", usedSystem: false)))
        #expect(machine.handle(.hold).isEmpty)
        #expect(machine.handle(.stop) == [.stopEngine, .release])
        #expect(machine.state == .idle)
    }
}
