import Foundation
import Testing
@testable import Waycar

struct WatchRecorderPresentationMachineTests {
    @Test func availabilityAndSingleOutcome() {
        var machine = WatchRecorderPresentationMachine()
        #expect(machine.handle(.begin(.unknown, busyReason: "busy")).isEmpty)
        #expect(machine.handle(.begin(.ready, busyReason: "busy")) == [.start])
        #expect(machine.handle(.listening) == [.announce("Listening")])
        let url = URL(fileURLWithPath: "/tmp/voice.m4a")
        #expect(machine.handle(.finished(url, duration: 2)) == [.send(url, duration: 2), .dismiss(toDetail: true)])
        #expect(machine.handle(.finished(url, duration: 2)).isEmpty)
        #expect(machine.handle(.cancelled("late", stays: false)).isEmpty)
    }

    @Test func unavailableAndReasons() {
        var missing = WatchRecorderPresentationMachine()
        #expect(missing.handle(.begin(.missing, busyReason: "busy")) == [.dismiss(toDetail: false)])
        var unsupported = WatchRecorderPresentationMachine()
        #expect(unsupported.handle(.begin(.unsupported, busyReason: "busy")) == [.dismiss(toDetail: true)])
        var busy = WatchRecorderPresentationMachine()
        #expect(busy.handle(.begin(.busy, busyReason: "busy")) == [.announce("busy"), .armReason(1)])
        #expect(busy.handle(.reasonElapsed(99)).isEmpty)
        #expect(busy.handle(.reasonElapsed(1)) == [.dismiss(toDetail: true)])
        #expect(busy.handle(.reasonElapsed(1)).isEmpty)
    }

    @Test func permissionReasonStaysUntilCancel() {
        var machine = WatchRecorderPresentationMachine().after([.begin(.ready, busyReason: "busy")])
        #expect(machine.handle(.cancelled("permission", stays: true)) == [.announce("permission")])
        #expect(machine.reason == "permission")
        #expect(machine.handle(.reasonElapsed(1)).isEmpty)
        #expect(machine.handle(.cancel) == [.dismiss(toDetail: true)])
    }

    /// B-10: an old presentation's timer must not navigate a reopened route.
    @Test func disappearedReasonCannotDismissReopenedRecorder() {
        var old = WatchRecorderPresentationMachine().after([.begin(.busy, busyReason: "busy")])
        #expect(old.handle(.disappear).isEmpty)
        let reopened = WatchRecorderPresentationMachine().after([.begin(.ready, busyReason: "busy")])
        #expect(old.handle(.reasonElapsed(1)).isEmpty)
        #expect(old.state == .dismissed)
        #expect(reopened.state == .recording)
    }

    @Test func cancellationWithoutReasonDismisses() {
        var machine = WatchRecorderPresentationMachine().after([.begin(.ready, busyReason: "busy")])
        #expect(machine.handle(.cancelled(nil, stays: false)) == [.dismiss(toDetail: true)])
    }
}
