import Foundation
import Testing
@testable import Waycar

struct WatchMessengerMachineTests {
    let url = URL(fileURLWithPath: "/tmp/watch-voice.m4a")

    @Test func ackOutcomeAndFinalCleanup() {
        var machine = WatchMessengerMachine(recording: url)
        #expect(machine.handle(.deliver) == [.deliver(1, recording: url)])
        #expect(machine.handle(.acknowledged(99)).isEmpty)
        #expect(machine.handle(.acknowledged(1)) == [.acknowledged])
        #expect(machine.handle(.phase(.transcribing)) == [.stopTimer, .armTimer(2)])
        #expect(machine.handle(.phase(.sent(text: "hello", at: .distantPast))) == [
            .stopTimer, .forgetAttempt, .cancelTransfer, .deleteRecording(url),
        ])
        #expect(machine.state == .settled)
        #expect(machine.handle(.transferFailed(1)).isEmpty)
        #expect(machine.handle(.timerElapsed(2)).isEmpty)
        #expect(machine.handle(.settle).isEmpty)
    }

    @Test func uncertaintyKeepsRecordingAndLateOutcomeCanRetry() {
        var machine = WatchMessengerMachine(recording: url).after([
            .deliver, .phase(.transcribing),
        ])
        #expect(machine.handle(.restartTimer) == [.stopTimer, .armTimer(3)])
        #expect(machine.handle(.timerElapsed(2)).isEmpty)
        #expect(machine.handle(.timerElapsed(3)) == [.timedOut])
        #expect(machine.handle(.phase(.unknown)) == [.stopTimer])
        #expect(machine.handle(.deliver).isEmpty)
        #expect(machine.handle(.phase(.notSent(reason: "late"))) == [.stopTimer])
        #expect(machine.handle(.phase(.sending)).isEmpty)
        #expect(machine.handle(.deliver) == [.deliver(4, recording: url)])
        #expect(machine.handle(.transferFailed(1)).isEmpty)
        #expect(machine.handle(.acknowledged(1)).isEmpty)
        #expect(machine.handle(.transferFailed(4)) == [.transferFailed])
    }

    @Test func failureInvalidatesAttemptButRetainsRecording() {
        var machine = WatchMessengerMachine(recording: url).after([.deliver])
        #expect(machine.handle(.ackFailed(99, reason: "old", cancelTransfer: true)).isEmpty)
        #expect(machine.handle(.ackFailed(1, reason: "offline", cancelTransfer: true)) == [
            .cancelTransfer, .forgetAttempt, .ackFailed("offline"),
        ])
        #expect(machine.handle(.phase(.notSent(reason: "offline"))) == [.stopTimer])
        #expect(machine.handle(.transferFailed(1)).isEmpty)
        #expect(machine.handle(.phase(.sending)).isEmpty)
        #expect(machine.handle(.deliver) == [.deliver(2, recording: url)])
    }

    @Test func replacementCleansUpAndTextHasNoFileEffects() {
        var voice = WatchMessengerMachine(recording: url)
        #expect(voice.handle(.settle) == [.stopTimer, .forgetAttempt, .cancelTransfer, .deleteRecording(url)])
        var text = WatchMessengerMachine(recording: nil).after([.deliver])
        #expect(text.handle(.deliver) == [.deliver(2, recording: nil)])
        #expect(text.handle(.phase(.delivering)) == [.stopTimer, .armTimer(3)])
        #expect(text.handle(.phase(.noWords)) == [.stopTimer, .forgetAttempt])
    }

    @Test func seededAckHasNoTimerUntilForeground() {
        var machine = WatchMessengerMachine(recording: nil)
        #expect(machine.handle(.seed(.transcribing)).isEmpty)
        #expect(machine.handle(.timerElapsed(1)).isEmpty)
        #expect(machine.handle(.restartTimer) == [.stopTimer, .armTimer(1)])
    }
}
