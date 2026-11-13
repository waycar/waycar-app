import Testing
@testable import Waycar

struct WatchLinkMachineTests {
    let none = WatchLinkMachine.Requests(inFlight: false, paused: false)
    let flying = WatchLinkMachine.Requests(inFlight: true, paused: false)
    let paused = WatchLinkMachine.Requests(inFlight: true, paused: true)

    @Test func downRequiresKnownReachabilityAndDebounce() {
        var machine = WatchLinkMachine(active: true, reachable: nil)
        #expect(machine.handle(.evaluate(none)) == [.cancelDebounce, .armDebounce(1)])
        #expect(machine.handle(.elapsed(1, liveReachable: false)) == [.losePaused])
        #expect(!machine.isDown)
        #expect(machine.handle(.reachable(false, none)) == [.cancelDebounce, .armDebounce(2)])
        #expect(machine.handle(.elapsed(1, liveReachable: true)).isEmpty)
        #expect(machine.handle(.elapsed(2, liveReachable: false)) == [.losePaused, .failWaiting])
        #expect(machine.isDown)
        #expect(machine.handle(.reachable(false, none)).isEmpty)
        #expect(machine.handle(.active(false, liveReachable: false, none)) == [.cancelDebounce])
        #expect(!machine.isDown)
    }

    @Test func flapResumesWithoutResending() {
        var machine = WatchLinkMachine(active: true, reachable: true)
        #expect(machine.handle(.reachable(false, flying)) == [.cancelDebounce, .pause, .armDebounce(1)])
        #expect(!machine.isReady)
        #expect(machine.handle(.reachable(true, paused)) == [.cancelDebounce, .resume, .transmitWaiting])
        #expect(machine.isReady)
        #expect(machine.handle(.elapsed(1, liveReachable: false)).isEmpty)
    }

    @Test func wristDownLosesOnlyAfterWindowAndActivationRereads() {
        var machine = WatchLinkMachine(active: true, reachable: true)
        #expect(machine.handle(.active(false, liveReachable: true, flying)) == [.cancelDebounce, .pause, .armDebounce(1)])
        #expect(machine.handle(.elapsed(1, liveReachable: true)) == [.losePaused])
        #expect(machine.handle(.active(true, liveReachable: false, none)) == [.cancelDebounce, .armDebounce(2)])
        #expect(machine.handle(.elapsed(2, liveReachable: true)) == [.losePaused, .failWaiting])
        #expect(machine.isDown)
    }

    @Test func doubtUsesLiveReachabilityNotTheOldCallback() {
        var machine = WatchLinkMachine(active: true, reachable: true)
        #expect(machine.handle(.linkError(none)) == [.cancelDebounce, .pause, .armDebounce(1)])
        #expect(machine.handle(.elapsed(1, liveReachable: true)) == [.resume, .transmitWaiting])
        #expect(machine.isReady)
        #expect(machine.handle(.reachable(true, none)).isEmpty)
        #expect(machine.handle(.active(true, liveReachable: false, none)).isEmpty)
    }

    @Test func inactiveWithoutWorkDoesNotArmAndReadyWaitsForDebounce() {
        var machine = WatchLinkMachine(active: false, reachable: true)
        #expect(machine.handle(.evaluate(none)) == [.cancelDebounce])
        #expect(machine.handle(.active(true, liveReachable: true, none)) == [.cancelDebounce, .armDebounce(1)])
        #expect(machine.handle(.elapsed(1, liveReachable: true)) == [.resume, .transmitWaiting])
        #expect(machine.isReady)
    }
}
