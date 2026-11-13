import Foundation
import Testing
@testable import Waycar

struct WatchRecorderMachineTests {
    private func recording() -> WatchRecorderMachine {
        WatchRecorderMachine().after([.start, .permission(1, granted: true), .began(1)])
    }

    @Test func permissionStartAndCapture() {
        var machine = WatchRecorderMachine()
        #expect(machine.handle(.start) == [.requestPermission(1)])
        #expect(machine.phase == .requestingPermission)
        #expect(machine.handle(.permission(99, granted: true)).isEmpty)
        #expect(machine.handle(.permission(1, granted: true)) == [.haptic(.start), .begin(1)])
        #expect(machine.handle(.began(99)).isEmpty)
        #expect(machine.handle(.began(1)) == [.meter(1)])
        #expect(machine.phase == .listening)
        #expect(machine.handle(.start).isEmpty)
        #expect(machine.handle(.sample(99, .stop(.noSpeech))).isEmpty)
        #expect(machine.handle(.sample(1, .listening(silenceProgress: 0.5))).isEmpty)
        #expect(machine.phase == .paused(progress: 0.5))
        #expect(machine.handle(.sample(1, .listening(silenceProgress: 0))).isEmpty)
        #expect(machine.phase == .listening)
    }

    @Test func cancellationInvalidatesPendingPermissionAndSupersededStarts() {
        var machine = WatchRecorderMachine().after([.start])
        #expect(machine.handle(.start) == [.requestPermission(2)])
        #expect(machine.handle(.permission(1, granted: true)).isEmpty)
        #expect(machine.handle(.cancel) == [.teardown(delete: true)])
        #expect(machine.handle(.permission(2, granted: true)).isEmpty)
        #expect(machine.phase == .cancelled(nil))
        #expect(machine.handle(.start) == [.requestPermission(3)])
    }

    @Test func permissionDenialAndStartFailure() {
        var denied = WatchRecorderMachine().after([.start])
        #expect(denied.handle(.permission(1, granted: false)) == [.stopObservingInterruptions, .haptic(.failure)])
        #expect(denied.phase == .cancelled(WatchRecorderMachine.permissionCopy))
        var failed = WatchRecorderMachine().after([.start, .permission(1, granted: true)])
        #expect(failed.handle(.failed(99)).isEmpty)
        #expect(failed.handle(.failed(1)) == [.teardown(delete: true), .haptic(.failure)])
        #expect(failed.phase == .cancelled(WatchRecorderMachine.startFailedCopy))
    }

    @Test func detectorStopsAndFinishedFileIsKept() {
        var noSpeech = recording()
        #expect(noSpeech.handle(.sample(1, .stop(.noSpeech))) == [.teardown(delete: true), .haptic(.failure)])
        #expect(noSpeech.phase == .cancelled(WatchRecorderMachine.noSpeechCopy))
        var machine = recording()
        #expect(machine.handle(.sample(1, .stop(.silence))) == [.stop])
        #expect(machine.handle(.sample(1, .stop(.maximumDuration))) == [.stop])
        let url = URL(fileURLWithPath: "/tmp/voice.m4a")
        #expect(machine.handle(.stop(url, duration: 3)) == [.teardown(delete: false), .haptic(.stop)])
        #expect(machine.phase == .finished(url: url, duration: 3))
        #expect(machine.handle(.interrupt).isEmpty)
        #expect(machine.handle(.sample(1, .stop(.noSpeech))).isEmpty)
    }

    @Test func interruptionCancelsPendingPermissionAndLateGrantCannotStartAudio() {
        var machine = WatchRecorderMachine().after([.start])
        #expect(machine.handle(.interrupt) == [.teardown(delete: true), .haptic(.failure)])
        #expect(machine.phase == .cancelled(WatchRecorderMachine.interruptedCopy))
        #expect(machine.handle(.permission(1, granted: true)).isEmpty)
        #expect(machine.handle(.start) == [.requestPermission(2)])
        #expect(machine.handle(.permission(1, granted: true)).isEmpty)
        #expect(machine.handle(.permission(2, granted: true)) == [.haptic(.start), .begin(2)])
        #expect(machine.handle(.interrupt) == [.teardown(delete: true), .haptic(.failure)])
        #expect(machine.handle(.began(2)).isEmpty)
    }

    @Test func recordingInterruptsAndIdleEventsAreIgnored() {
        var idle = WatchRecorderMachine()
        #expect(idle.handle([.interrupt, .began(1), .failed(1), .permission(1, granted: true)]).isEmpty)
        var machine = recording()
        #expect(machine.handle(.interrupt) == [.teardown(delete: true), .haptic(.failure)])
        #expect(machine.phase == .cancelled(WatchRecorderMachine.interruptedCopy))
    }
}
