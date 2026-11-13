import XCTest
@testable import MoshTransport

/// `DatagramEndpointMachine`'s transitions (MOSH-11, patch 18); the owner
/// tests are the endpoint tests in `TransportTests`.
final class DatagramEndpointMachineTests: XCTestCase {
    private typealias Machine = DatagramEndpointMachine

    private var connecting: Machine { Machine().after([.start]) }
    private var opened: Machine { connecting.after([.reported(connection: 1, .ready)]) }

    func testAStartOpensAConnectionWithANewToken() {
        var machine = Machine()
        XCTAssertEqual(machine.handle(.start), [.open(connection: 1)])
        XCTAssertEqual(machine.state, .connecting(connection: 1))
        XCTAssertEqual(machine.connection, 1)
    }

    func testAStartWhileHoldingAConnectionChangesNothing() {
        for start in [connecting, opened, opened.after([.reported(connection: 1, .cancelled)])] {
            var machine = start
            XCTAssertEqual(machine.handle(.start), [])
            XCTAssertEqual(machine.state, start.state)
        }
    }

    func testReadyResumesTheStartAndItsReturnArmsTheReceiveLoop() {
        var machine = connecting
        XCTAssertEqual(machine.handle(.reported(connection: 1, .ready)), [.resumeStart])
        XCTAssertEqual(machine.state, .open(connection: 1))
        XCTAssertEqual(machine.handle(.startReturned(connection: 1)), [.armReceive(connection: 1)])
    }

    func testAFailureWhileConnectingFailsTheStartAndKeepsTheConnection() {
        var machine = connecting
        XCTAssertEqual(machine.handle(.reported(connection: 1, .failed("down"))), [.failAll(.network("down"))])
        XCTAssertEqual(machine.state, .failed(connection: 1))
        var cancelled = connecting
        XCTAssertEqual(cancelled.handle(.reported(connection: 1, .cancelled)), [.failAll(.cancelled)])
        XCTAssertEqual(cancelled.state, .failed(connection: 1))
        XCTAssertEqual(cancelled.connection, 1)
    }

    func testAFailureWhenOpenFailsTheWaitingReceives() {
        var machine = opened
        XCTAssertEqual(machine.handle(.reported(connection: 1, .failed("gone"))), [.failAll(.network("gone"))])
        XCTAssertEqual(machine.state, .failed(connection: 1))
        XCTAssertEqual(machine.handle(.reported(connection: 1, .cancelled)), [.failAll(.cancelled)])
        XCTAssertEqual(machine.state, .failed(connection: 1))
    }

    func testReadyOrOtherReportsOnceStartedDoNothing() {
        for start in [opened, opened.after([.reported(connection: 1, .cancelled)])] {
            var machine = start
            XCTAssertEqual(machine.handle(.reported(connection: 1, .ready)), [])
            XCTAssertEqual(machine.handle(.reported(connection: 1, .other)), [])
            XCTAssertEqual(machine.state, start.state)
        }
        var machine = connecting
        XCTAssertEqual(machine.handle(.reported(connection: 1, .other)), [])
        XCTAssertEqual(machine.state, .connecting(connection: 1))
    }

    func testAFailedConnectionStillDeliversItsReceives() {
        var machine = opened.after([.reported(connection: 1, .failed("gone"))])
        XCTAssertEqual(machine.handle(.receiveCompleted(connection: 1)), [.deliverReceive, .armReceive(connection: 1)])
        XCTAssertEqual(machine.handle(.startReturned(connection: 1)), [.armReceive(connection: 1)])
    }

    func testAReceiveIsDeliveredAndRearmed() {
        var machine = opened
        XCTAssertEqual(machine.handle(.receiveCompleted(connection: 1)), [.deliverReceive, .armReceive(connection: 1)])
        XCTAssertEqual(machine.state, .open(connection: 1))
    }

    func testStopClosesFromEveryState() {
        for start in [Machine(), connecting, opened, opened.after([.reported(connection: 1, .cancelled)])] {
            var machine = start
            XCTAssertEqual(machine.handle(.stop), [.close])
            XCTAssertEqual(machine.state, .stopped)
            XCTAssertNil(machine.connection)
        }
    }

    func testARestartMintsANewToken() {
        var machine = opened.after([.stop])
        XCTAssertEqual(machine.handle(.start), [.open(connection: 2)])
        XCTAssertEqual(machine.state, .connecting(connection: 2))
    }

    /// B-28: callbacks from a connection the endpoint no longer holds.
    func testAStoppedConnectionsCallbacksAreIgnored() {
        let restarted = opened.after([.stop, .start])
        for event: Machine.Event in [
            .reported(connection: 1, .cancelled), .reported(connection: 1, .failed("x")),
            .reported(connection: 1, .ready), .receiveCompleted(connection: 1), .startReturned(connection: 1),
        ] {
            var machine = restarted
            XCTAssertEqual(machine.handle(event), [], "\(event)")
            XCTAssertEqual(machine.state, .connecting(connection: 2))
        }
        var stopped = opened.after([.stop])
        XCTAssertEqual(stopped.handle(.receiveCompleted(connection: 1)), [])
        XCTAssertEqual(stopped.handle(.reported(connection: 1, .cancelled)), [])
        XCTAssertEqual(stopped.state, .stopped)
    }

    /// A start that returns after a stop and restart arms nothing: the
    /// restart arms its own connection.
    func testAStaleStartReturnArmsNothing() {
        var machine = opened.after([.stop, .start, .reported(connection: 2, .ready)])
        XCTAssertEqual(machine.handle(.startReturned(connection: 1)), [])
        XCTAssertEqual(machine.handle(.startReturned(connection: 2)), [.armReceive(connection: 2)])
        var stopped = opened.after([.stop])
        XCTAssertEqual(stopped.handle(.startReturned(connection: 1)), [])
    }
}
