import Foundation
import Testing

@testable import Waycar

@Suite("iCloud pass machine")
struct ICloudPassMachineTests {
    private let date = Date(timeIntervalSince1970: 123)

    @Test func disabledRequestsAreInertAndEnableStartsOnDemand() {
        var machine = ICloudPassMachine(enabled: false)
        #expect(machine.handle([.request, .disable, .finished(1)]) == [])
        #expect(!machine.isEnabled)
        #expect(machine.handle(.enable) == [])
        #expect(machine.state == .idle)
        #expect(machine.handle(.request) == [.run(1)])
        #expect(machine.accepts(1))
        #expect(!machine.accepts(2))
    }

    @Test func requestsQueuedBeforeWorkBeginsJoinThatPass() {
        var machine = ICloudPassMachine(enabled: true).after([.request, .request])
        #expect(machine.handle(.began(999)) == [])
        #expect(machine.state == .syncing(token: 1, rerun: true))
        #expect(machine.handle(.began(1)) == [])
        #expect(machine.state == .syncing(token: 1, rerun: false))
        #expect(machine.handle(.finished(1)) == [])
        #expect(machine.state == .idle)
    }

    @Test func aPassPublishesThenFinishesOrRunsOneCoalescedRequest() {
        var machine = ICloudPassMachine(enabled: true)
        #expect(machine.handle(.request) == [.run(1)])
        #expect(machine.handle(.result(1, completedAt: date, error: nil, retry: true, identities: ["key", nil]))
            == [.publish(date, error: nil, identities: ["key", nil]), .retryConnections])
        #expect(machine.handle([.request, .request]) == [])
        #expect(machine.handle(.finished(1)) == [.run(2)])
        #expect(machine.handle(.failed(2, "failed")) == [.reportError("failed")])
        #expect(machine.handle(.finished(2)) == [])
        #expect(machine.state == .idle)
        #expect(machine.handle(.disable) == [])
        #expect(machine.state == .disabled)
    }

    @Test func staleResultsAndFinishesCannotAffectTheNextPass() {
        var machine = ICloudPassMachine(enabled: true).after([.request, .request, .finished(1)])
        #expect(machine.handle([
            .result(1, completedAt: date, error: "old", retry: true),
            .failed(1, "old"), .finished(1), .enable,
        ]) == [])
        #expect(machine.state == .syncing(token: 2, rerun: false))
        #expect(machine.handle(.result(2, completedAt: date, error: "partial", retry: false))
            == [.publish(date, error: "partial")])
    }

    @Test func disableInvalidatesPublicationAndQueuedReruns() {
        var machine = ICloudPassMachine(enabled: true).after([.request, .request, .disable])
        #expect(machine.state == .draining(token: 1, enabled: false, rerun: false))
        #expect(!machine.accepts(1))
        #expect(machine.handle([
            .result(1, completedAt: date, error: nil, retry: true), .failed(1, "old"), .request,
        ]) == [])
        #expect(machine.handle(.finished(1)) == [])
        #expect(machine.state == .disabled)
    }

    @Test func reenableWhileDrainingKeepsFreshDemandButNotOldResults() {
        var machine = ICloudPassMachine(enabled: true).after([
            .request, .disable, .enable, .request,
        ])
        #expect(machine.isEnabled)
        #expect(machine.handle(.finished(999)) == [])
        #expect(machine.handle(.result(1, completedAt: date, error: nil, retry: true)) == [])
        #expect(machine.handle(.finished(1)) == [.run(2)])
        #expect(machine.accepts(2))
    }

    @Test func disablingAgainClearsDemandAndReenableAloneDoesNotRequest() {
        var machine = ICloudPassMachine(enabled: true).after([
            .request, .disable, .enable, .request, .disable, .enable,
        ])
        #expect(machine.handle(.finished(1)) == [])
        #expect(machine.state == .idle)
        #expect(machine.handle([.finished(1), .failed(1, "old"), .enable]) == [])
    }
}
