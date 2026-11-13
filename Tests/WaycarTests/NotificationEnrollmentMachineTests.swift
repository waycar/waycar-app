import Foundation
import Testing

@testable import Waycar

@Suite("Notification enrollment machine")
struct NotificationEnrollmentMachineTests {
    private let host = UUID()

    @Test func completedHostsStaySeenAndOnlyNewHostsBecomePending() {
        let added = UUID()
        var machine = NotificationEnrollmentMachine(seen: [host], pending: [])
        #expect(machine.handle(.discover([host, added])) == [.save])
        #expect(machine.pending == [added])
        #expect(machine.handle(.discover([host, added])) == [])
        #expect(machine.handle(.consider(host, .idleUnregistered, liveEnabled: false)) == [])
    }

    @Test func waitingHostRegistersOnceAndCompletesWithLiveActivity() {
        var machine = NotificationEnrollmentMachine(seen: [host], pending: [host])
        #expect(machine.handle(.consider(host, .unknownOrFailed, liveEnabled: false)) == [])
        #expect(machine.handle(.consider(host, .idleUnregistered, liveEnabled: false))
            == [.register(host, token: 1)])
        #expect(machine.handle(.consider(host, .registered, liveEnabled: false)) == [])
        #expect(machine.handle(.registered(host, token: 999, confirmed: true, liveEnabled: false)) == [])
        #expect(machine.handle(.registered(host, token: 1, confirmed: true, liveEnabled: false))
            == [.enableLiveActivity(host), .save])
        #expect(machine.pending.isEmpty)
        #expect(machine.seen == [host])
        #expect(machine.handle(.registered(host, token: 1, confirmed: true, liveEnabled: false)) == [])
    }

    @Test func failureWaitsForFreshIdleReadAndRetryMintsANewToken() {
        var machine = NotificationEnrollmentMachine(seen: [host], pending: [host])
        #expect(machine.handle(.consider(host, .idleUnregistered, liveEnabled: false))
            == [.register(host, token: 1)])
        #expect(machine.handle(.registered(host, token: 1, confirmed: false, liveEnabled: false)) == [])
        #expect(machine.state.hosts[host] == .waiting)
        #expect(machine.handle(.consider(host, .unknownOrFailed, liveEnabled: false)) == [])
        #expect(machine.handle(.consider(host, .idleUnregistered, liveEnabled: false))
            == [.register(host, token: 2)])
        #expect(machine.handle(.registered(host, token: 1, confirmed: true, liveEnabled: false)) == [])
        #expect(machine.handle(.registered(host, token: 2, confirmed: true, liveEnabled: true)) == [.save])
    }

    @Test func confirmedRegistrationCanCompleteWithoutWritingOrEnablingAgain() {
        var machine = NotificationEnrollmentMachine(seen: [host], pending: [host])
        #expect(machine.handle(.consider(host, .registered, liveEnabled: true)) == [.save])
        #expect(machine.handle(.consider(host, .registered, liveEnabled: false)) == [])
        #expect(machine.handle(.consider(UUID(), .registered, liveEnabled: false)) == [])
    }

    @Test func initializeAndClearInvalidateInFlightWritesWithoutReusingTokens() {
        var machine = NotificationEnrollmentMachine(seen: [], pending: [])
        #expect(machine.handle(.initialize(seen: [host], pending: [host])) == [])
        #expect(machine.handle(.consider(host, .idleUnregistered, liveEnabled: false)) == [.register(host, token: 1)])
        #expect(machine.handle(.clear) == [])
        #expect(machine.handle(.registered(host, token: 1, confirmed: true, liveEnabled: false)) == [])
        #expect(machine.handle(.discover([host])) == [.save])
        #expect(machine.handle(.consider(host, .idleUnregistered, liveEnabled: false)) == [.register(host, token: 2)])
    }
}
