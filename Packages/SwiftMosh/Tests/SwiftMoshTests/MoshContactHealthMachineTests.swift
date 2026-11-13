import XCTest
@testable import MoshCore
@testable import MoshTransport

/// `MoshContactHealthMachine`'s transitions (MOSH-07, patch 20); the owner
/// tests are the connectivity and network-timeout tests in
/// `WaycarNetworkPatchTests` and `CoreAndAdapterTests`.
final class MoshContactHealthMachineTests: XCTestCase {
    private typealias Machine = MoshContactHealthMachine

    private let fresh = Machine(stallThresholdMs: 200, networkTimeoutMs: 1_000)
    private var healthy: Machine { fresh.after([.started(nowMs: 100)]) }
    private var stalled: Machine { healthy.after([.tick(nowMs: 300)]) }

    func testItStartsUnjudgedWithNoContact() {
        XCTAssertEqual(fresh.state, .notRunning(lastContactMs: 0))
        XCTAssertNil(fresh.connectivity)
        XCTAssertEqual(fresh.lastContactMs, 0)
    }

    func testAStartCountsAsContactAndPublishesConnected() {
        var machine = fresh
        XCTAssertEqual(machine.handle(.started(nowMs: 100)), [.publish(.connected)])
        XCTAssertEqual(machine.state, .healthy(lastContactMs: 100))
        XCTAssertEqual(machine.connectivity, .connected)
    }

    func testAZeroThresholdStartsStalled() {
        var machine = Machine(stallThresholdMs: 0, networkTimeoutMs: 1_000)
        XCTAssertEqual(machine.handle(.started(nowMs: 100)), [.publish(.stalled)])
        XCTAssertEqual(machine.state, .stalled(lastContactMs: 100))
    }

    func testSilenceShortOfTheThresholdStaysHealthyWithoutPublishing() {
        var machine = healthy
        XCTAssertEqual(machine.handle(.tick(nowMs: 299)), [])
        XCTAssertEqual(machine.state, .healthy(lastContactMs: 100))
    }

    func testSilenceAtTheThresholdStalls() {
        var machine = healthy
        XCTAssertEqual(machine.handle(.tick(nowMs: 300)), [.publish(.stalled)])
        XCTAssertEqual(machine.state, .stalled(lastContactMs: 100))
        XCTAssertEqual(machine.handle(.tick(nowMs: 400)), [], "a stall is published once")
    }

    func testContactWhileRunningRecovers() {
        var machine = stalled
        XCTAssertEqual(machine.handle(.contact(nowMs: 350, judged: true)), [.publish(.connected)])
        XCTAssertEqual(machine.state, .healthy(lastContactMs: 350))
        XCTAssertEqual(machine.handle(.contact(nowMs: 360, judged: true)), [])
        XCTAssertEqual(machine.state, .healthy(lastContactMs: 360))
    }

    func testContactWhileNotRunningIsRecordedButNotJudged() {
        var shuttingDown = stalled
        XCTAssertEqual(shuttingDown.handle(.contact(nowMs: 350, judged: false)), [])
        XCTAssertEqual(shuttingDown.state, .stalled(lastContactMs: 350))
        XCTAssertEqual(shuttingDown.connectivity, .stalled)
        var quiet = healthy
        XCTAssertEqual(quiet.handle(.contact(nowMs: 150, judged: false)), [])
        XCTAssertEqual(quiet.state, .healthy(lastContactMs: 150))
        var unstarted = fresh
        XCTAssertEqual(unstarted.handle(.contact(nowMs: 150, judged: true)), [])
        XCTAssertEqual(unstarted.state, .notRunning(lastContactMs: 150))
    }

    func testTheTimeoutIsJudgedBeforeTheStallAndKeepsTheLastConnectivity() {
        var machine = healthy
        XCTAssertEqual(machine.handle(.tick(nowMs: 1_100)), [.expire(timeoutMs: 1_000)])
        XCTAssertEqual(machine.state, .expired(lastContactMs: 100, connectivity: .connected))
        XCTAssertEqual(machine.connectivity, .connected)
        var fromStall = stalled
        XCTAssertEqual(fromStall.handle(.tick(nowMs: 1_100)), [.expire(timeoutMs: 1_000)])
        XCTAssertEqual(fromStall.connectivity, .stalled)
    }

    func testAnExpiredSessionIsNotJudgedAgain() {
        var machine = healthy.after([.tick(nowMs: 1_100)])
        XCTAssertEqual(machine.handle(.tick(nowMs: 5_000)), [])
        XCTAssertEqual(machine.handle(.contact(nowMs: 5_000, judged: false)), [])
        XCTAssertEqual(machine.state, .expired(lastContactMs: 5_000, connectivity: .connected))
    }

    func testAClockBehindTheLastContactIsNoSilence() {
        var machine = healthy
        XCTAssertEqual(machine.handle(.tick(nowMs: 50)), [])
        XCTAssertEqual(machine.state, .healthy(lastContactMs: 100))
    }

    func testEndingClearsConnectivityAndKeepsTheLastContact() {
        for start in [healthy, stalled, healthy.after([.tick(nowMs: 1_100)]), fresh] {
            var machine = start
            XCTAssertEqual(machine.handle(.ended), [])
            XCTAssertEqual(machine.state, .notRunning(lastContactMs: start.lastContactMs))
            XCTAssertNil(machine.connectivity)
        }
    }

    func testATickWhileNotRunningDoesNothing() {
        var machine = healthy.after([.ended])
        XCTAssertEqual(machine.handle(.tick(nowMs: 5_000)), [])
        XCTAssertEqual(machine.state, .notRunning(lastContactMs: 100))
    }

    func testARestartAfterASuspensionCountsAsContactAgain() {
        var machine = stalled.after([.ended])
        XCTAssertEqual(machine.handle(.started(nowMs: 9_000)), [.publish(.connected)])
        XCTAssertEqual(machine.state, .healthy(lastContactMs: 9_000))
    }
}
