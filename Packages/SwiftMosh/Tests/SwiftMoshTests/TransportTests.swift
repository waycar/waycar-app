import Foundation
import Darwin
import Network
import XCTest
@testable import MoshTransport
@testable import MoshWire

final class TransportTests: XCTestCase {
    func testTransportClockAndAddressCodableHashable() throws {
        let now = TransportClock.nowMs()
        XCTAssertGreaterThan(now, 0)

        let address = UDPTransportEndpointAddress(host: "127.0.0.1", port: 60001)
        let encoded = try JSONEncoder().encode(address)
        let decoded = try JSONDecoder().decode(UDPTransportEndpointAddress.self, from: encoded)
        XCTAssertEqual(decoded, address)
    }

    /// Datagram timestamps must carry in-app elapsed time, not time since
    /// boot (privacy manifest reason 35F9.1). (Waycar patch.)
    func testTransportClockCountsFromFirstReadingAndNeverDecreases() throws {
        var previous = TransportClock.nowMs()
        XCTAssertGreaterThanOrEqual(previous, TransportClock.originOffsetMs, "0 means unset to callers")
        // The first reading may come from an earlier test, so bound the clock
        // by this process's age: well under 60 s early in a run, and never
        // anywhere near time since boot.
        let processAgeMs = try XCTUnwrap(Self.processAgeMs())
        XCTAssertLessThanOrEqual(previous - TransportClock.originOffsetMs, processAgeMs + 1_000)
        if processAgeMs < 50_000 {
            XCTAssertLessThan(previous, 60_000)
        }

        for _ in 0..<10_000 {
            let now = TransportClock.nowMs()
            XCTAssertGreaterThanOrEqual(now, previous)
            previous = now
        }
    }

    private static func processAgeMs() -> UInt64? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        let startSeconds = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
        let age = Date().timeIntervalSince1970 - startSeconds
        return age >= 0 ? UInt64(age * 1_000) : nil
    }

    func testInMemoryEndpointLifecycleAndDelivery() async throws {
        let (left, right) = await InMemoryDatagramPair.makeLinked()

        do {
            _ = try await left.receive()
            XCTFail("Expected notStarted")
        } catch {
            guard case .notStarted = error as? TransportError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        try await left.start()
        try await right.start()

        do {
            try await left.start()
            XCTFail("Expected alreadyStarted")
        } catch {
            guard case .alreadyStarted = error as? TransportError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        try await left.send(Data([0x01, 0x02]))
        let datagram = try await right.receive()
        XCTAssertEqual(datagram.data, Data([0x01, 0x02]))

        let waiting = Task {
            try await right.receive()
        }
        await right.stop()

        do {
            _ = try await waiting.value
            XCTFail("Expected cancelled")
        } catch {
            guard let typed = error as? TransportError else {
                return XCTFail("Unexpected error: \(error)")
            }
            switch typed {
            case .cancelled, .notStarted:
                break
            default:
                XCTFail("Unexpected error: \(error)")
            }
        }

        do {
            try await right.send(Data([0x03]))
            XCTFail("Expected notStarted")
        } catch {
            guard case .notStarted = error as? TransportError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testInMemoryEndpointSendWithoutPeerThrowsNotStarted() async throws {
        let endpoint = InMemoryDatagramEndpoint()
        try await endpoint.start()

        do {
            try await endpoint.send(Data([0xAA]))
            XCTFail("Expected notStarted without peer")
        } catch {
            guard case .notStarted = error as? TransportError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testNetworkEndpointPreStartAndInvalidPort() async {
        let endpoint = NetworkDatagramEndpoint(remote: .init(host: "127.0.0.1", port: 9999))

        do {
            try await endpoint.send(Data([1]))
            XCTFail("Expected notStarted")
        } catch {
            guard case .notStarted = error as? TransportError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        do {
            _ = try await endpoint.receive()
            XCTFail("Expected notStarted")
        } catch {
            guard case .notStarted = error as? TransportError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let invalidPort = NetworkDatagramEndpoint(remote: .init(host: "127.0.0.1", port: 0))
        do {
            try await invalidPort.start()
            XCTFail("Expected invalidPort")
        } catch {
            guard case .invalidPort(0) = error as? TransportError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        await endpoint.stop()
    }

    func testNetworkEndpointLoopbackAndAlreadyStartedAndStopCancellation() async throws {
        var portA = try reserveUDPPort()
        var portB = try reserveUDPPort()
        if portA == portB {
            portB = try reserveUDPPort()
        }
        if portA == portB {
            portA = try reserveUDPPort()
        }

        let endpointA = NetworkDatagramEndpoint(remote: .init(host: "127.0.0.1", port: portB), localPort: portA)
        let endpointB = NetworkDatagramEndpoint(remote: .init(host: "127.0.0.1", port: portA), localPort: portB)

        try await endpointA.start()
        try await endpointB.start()

        do {
            try await endpointA.start()
            XCTFail("Expected alreadyStarted")
        } catch {
            guard case .alreadyStarted = error as? TransportError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let waitFirst = Task { try await endpointB.receive() }
        try await endpointA.send(Data([0x99]))
        let first = try await waitFirst.value
        XCTAssertEqual(first.data, Data([0x99]))

        let waitSecond = Task { try await endpointB.receive() }
        await endpointB.stop()

        do {
            _ = try await waitSecond.value
            XCTFail("Expected cancelled")
        } catch {
            guard let typed = error as? TransportError else {
                return XCTFail("Unexpected error: \(error)")
            }
            switch typed {
            case .cancelled, .notStarted:
                break
            default:
                XCTFail("Unexpected error: \(error)")
            }
        }

        await endpointA.stop()
    }

    func testNetworkEndpointDeterministicSendReceiveAndStopCoverage() async throws {
        let fake = FakeUDPConnection()
        let endpoint = NetworkDatagramEndpoint(
            remote: .init(host: "127.0.0.1", port: 60001),
            connectionFactory: { _, _, _ in fake }
        )

        let startTask = Task { try await endpoint.start() }
        let hasStateHandler = await waitUntil { fake.hasStateHandler }
        XCTAssertTrue(hasStateHandler)
        try? await Task.sleep(nanoseconds: 2_000_000)
        fake.emitState(.ready)
        try await startTask.value
        let hasReceiveHandler = await waitUntil { fake.hasReceiveHandler }
        XCTAssertTrue(hasReceiveHandler)

        fake.emitReceive(content: Data([0xFA]), error: nil)
        let didRearmReceive = await waitUntil { fake.receiveRegistrationCount >= 2 }
        XCTAssertTrue(didRearmReceive)

        let buffered = try await endpoint.receive()
        XCTAssertEqual(buffered.data, Data([0xFA]))

        fake.sendError = .posix(.ECONNABORTED)
        do {
            try await endpoint.send(Data([0x01]))
            XCTFail("Expected sendFailure")
        } catch {
            guard case .sendFailure = error as? TransportError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        fake.sendError = nil

        let waitingOnError = Task { try await endpoint.receive() }
        // An error that comes before the receive waits is dropped.
        let errorAwaited = await waitUntil { await endpoint._testPendingReceiveCount() == 1 }
        XCTAssertTrue(errorAwaited)
        fake.emitReceive(content: nil, error: .posix(.ECONNRESET))
        do {
            _ = try await waitingOnError.value
            XCTFail("Expected networkFailure")
        } catch {
            guard case .networkFailure = error as? TransportError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        fake.emitReceive(content: nil, error: nil)
        try? await Task.sleep(nanoseconds: 2_000_000)

        let waitingOnStop = Task { try await endpoint.receive() }
        let stopAwaited = await waitUntil { await endpoint._testPendingReceiveCount() == 1 }
        XCTAssertTrue(stopAwaited)
        await endpoint.stop()
        do {
            _ = try await waitingOnStop.value
            XCTFail("Expected cancelled")
        } catch {
            guard case .cancelled = error as? TransportError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        await endpoint._testArmReceiveLoop()
    }

    func testNetworkEndpointDeterministicStateFailureAndCancellationCoverage() async throws {
        let failedConnection = FakeUDPConnection()
        let failedEndpoint = NetworkDatagramEndpoint(
            remote: .init(host: "127.0.0.1", port: 60002),
            connectionFactory: { _, _, _ in failedConnection }
        )

        let failedStart = Task { try await failedEndpoint.start() }
        let failedReady = await waitUntil { failedConnection.hasStateHandler && failedConnection.startCallCount > 0 }
        XCTAssertTrue(failedReady)
        try? await Task.sleep(nanoseconds: 2_000_000)
        failedConnection.emitState(.failed(.posix(.ECONNREFUSED)))
        do {
            try await failedStart.value
            XCTFail("Expected networkFailure")
        } catch {
            guard case .networkFailure = error as? TransportError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let cancelledConnection = FakeUDPConnection()
        let cancelledEndpoint = NetworkDatagramEndpoint(
            remote: .init(host: "127.0.0.1", port: 60003),
            connectionFactory: { _, _, _ in cancelledConnection }
        )

        let cancelledStart = Task { try await cancelledEndpoint.start() }
        let cancelledReady = await waitUntil { cancelledConnection.hasStateHandler && cancelledConnection.startCallCount > 0 }
        XCTAssertTrue(cancelledReady)
        try? await Task.sleep(nanoseconds: 2_000_000)
        cancelledConnection.emitState(.ready)
        try await cancelledStart.value

        let waitingReceive = Task { try await cancelledEndpoint.receive() }
        let cancelAwaited = await waitUntil { await cancelledEndpoint._testPendingReceiveCount() == 1 }
        XCTAssertTrue(cancelAwaited)
        cancelledConnection.emitState(.cancelled)
        do {
            _ = try await waitingReceive.value
            XCTFail("Expected cancelled")
        } catch {
            guard case .cancelled = error as? TransportError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    // MARK: - Endpoint lifecycle (MOSH-11)

    /// A stopped endpoint starts again on a fresh connection, and the new
    /// connection's callbacks drive it as the first one's did.
    func testNetworkEndpointStartsAgainOnAFreshConnectionAfterStop() async throws {
        let connections = FakeConnectionSequence()
        let endpoint = NetworkDatagramEndpoint(
            remote: .init(host: "127.0.0.1", port: 60010),
            connectionFactory: { _, _, _ in connections.next() }
        )

        let first = try await startReady(endpoint, on: connections, index: 0)
        await endpoint.stop()
        XCTAssertEqual(first.cancelCallCount, 1, "stop cancels the connection")
        do {
            _ = try await endpoint.receive()
            XCTFail("Expected notStarted after stop")
        } catch {
            guard case .notStarted = error as? TransportError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let second = try await startReady(endpoint, on: connections, index: 1)
        XCTAssertEqual(connections.count, 2, "a restart opens a new connection")
        XCTAssertEqual(second.receiveRegistrationCount, 1, "the new connection's receive loop is armed")

        let waiting = Task { try await endpoint.receive() }
        let receiveAwaited = await waitUntil { await endpoint._testPendingReceiveCount() == 1 }
        XCTAssertTrue(receiveAwaited)
        second.emitReceive(content: Data([0x42]), error: nil)
        let datagram = try await waiting.value
        XCTAssertEqual(datagram.data, Data([0x42]))
        await endpoint.stop()
    }

    /// A start while one is connecting, or after one failed, is refused:
    /// the failed connection stays the endpoint's until `stop()`.
    func testNetworkEndpointRefusesASecondStartUntilStopped() async throws {
        let connections = FakeConnectionSequence()
        let endpoint = NetworkDatagramEndpoint(
            remote: .init(host: "127.0.0.1", port: 60011),
            connectionFactory: { _, _, _ in connections.next() }
        )

        let starting = Task { try await endpoint.start() }
        let opened = await waitUntil { connections.count == 1 && connections[0].startCallCount == 1 }
        XCTAssertTrue(opened)
        do {
            try await endpoint.start()
            XCTFail("Expected alreadyStarted while connecting")
        } catch {
            guard case .alreadyStarted = error as? TransportError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        connections[0].emitState(.failed(.posix(.ENETUNREACH)))
        do {
            try await starting.value
            XCTFail("Expected networkFailure")
        } catch {
            guard case .networkFailure = error as? TransportError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(connections[0].receiveRegistrationCount, 0, "a failed start arms no receive")
        do {
            try await endpoint.start()
            XCTFail("Expected alreadyStarted after a failed start")
        } catch {
            guard case .alreadyStarted = error as? TransportError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(connections.count, 1)

        await endpoint.stop()
        _ = try await startReady(endpoint, on: connections, index: 1)
        await endpoint.stop()
    }

    /// `stop()` ends a start still waiting for its connection.
    func testNetworkEndpointStopEndsAStartInFlight() async throws {
        let connections = FakeConnectionSequence()
        let endpoint = NetworkDatagramEndpoint(
            remote: .init(host: "127.0.0.1", port: 60012),
            connectionFactory: { _, _, _ in connections.next() }
        )
        let starting = Task { try await endpoint.start() }
        let opened = await waitUntil { connections.count == 1 && connections[0].startCallCount == 1 }
        XCTAssertTrue(opened)
        await endpoint.stop()
        do {
            try await starting.value
            XCTFail("Expected cancelled")
        } catch {
            guard case .cancelled = error as? TransportError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(connections[0].cancelCallCount, 1)
        do {
            try await endpoint.send(Data([1]))
            XCTFail("Expected notStarted")
        } catch {
            guard case .notStarted = error as? TransportError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    /// A connection that fails after it was ready fails the receives
    /// waiting on it; a buffered datagram is kept until `stop()`, which
    /// drops it.
    func testNetworkEndpointFailureAfterReadyFailsWaitingReceives() async throws {
        let connections = FakeConnectionSequence()
        let endpoint = NetworkDatagramEndpoint(
            remote: .init(host: "127.0.0.1", port: 60013),
            connectionFactory: { _, _, _ in connections.next() }
        )
        let connection = try await startReady(endpoint, on: connections, index: 0)

        let waiting = Task { try await endpoint.receive() }
        let receiveAwaited = await waitUntil { await endpoint._testPendingReceiveCount() == 1 }
        XCTAssertTrue(receiveAwaited)
        connection.emitState(.failed(.posix(.ENETDOWN)))
        do {
            _ = try await waiting.value
            XCTFail("Expected networkFailure")
        } catch {
            guard case .networkFailure = error as? TransportError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        connection.emitReceive(content: Data([0x07]), error: nil)
        let rearmed = await waitUntil { connection.receiveRegistrationCount == 2 }
        XCTAssertTrue(rearmed)
        let buffered = try await endpoint.receive()
        XCTAssertEqual(buffered.data, Data([0x07]), "a datagram that arrives is still delivered")

        connection.emitReceive(content: Data([0x08]), error: nil)
        let rearmedAgain = await waitUntil { connection.receiveRegistrationCount == 3 }
        XCTAssertTrue(rearmedAgain)
        await endpoint.stop()
        let restarted = try await startReady(endpoint, on: connections, index: 1)
        let waitingAfterRestart = Task { try await endpoint.receive() }
        let restartAwaited = await waitUntil { await endpoint._testPendingReceiveCount() == 1 }
        XCTAssertTrue(restartAwaited, "stop drops the old connection's buffered datagram")
        restarted.emitReceive(content: Data([0x09]), error: nil)
        let fresh = try await waitingAfterRestart.value
        XCTAssertEqual(fresh.data, Data([0x09]))
        await endpoint.stop()
    }

    // MARK: - Late callbacks from a stopped connection (B-28)

    /// `stop()` cancels the connection, and NWConnection reports
    /// `.cancelled` later. Arriving after a restart began, it must not fail
    /// the new connection's start.
    func testALateCancelFromAStoppedConnectionDoesNotFailTheRestart() async throws {
        let connections = FakeConnectionSequence()
        let endpoint = NetworkDatagramEndpoint(
            remote: .init(host: "127.0.0.1", port: 60020),
            connectionFactory: { _, _, _ in connections.next() }
        )
        let old = try await startReady(endpoint, on: connections, index: 0)
        await endpoint.stop()

        let outcome = StartOutcome()
        let restarting = Task {
            do {
                try await endpoint.start()
                outcome.set("started")
            } catch {
                outcome.set("\(error)")
            }
        }
        let opened = await waitUntil { connections.count == 2 && connections[1].startCallCount == 1 }
        XCTAssertTrue(opened)
        old.emitState(.cancelled)
        let settledEarly = await waitUntil(within: 0.3) { outcome.value != nil }
        XCTAssertFalse(settledEarly, "the old connection's cancel settled the restart: \(outcome.value ?? "")")

        connections[1].emitState(.ready)
        await restarting.value
        XCTAssertEqual(outcome.value, "started")
        await endpoint.stop()
    }

    /// A receive the stopped connection completes late (with the error
    /// cancelling it brings) must not fail a receive on the new connection,
    /// nor arm a second receive there.
    func testALateReceiveErrorFromAStoppedConnectionDoesNotFailTheNewOne() async throws {
        let connections = FakeConnectionSequence()
        let endpoint = NetworkDatagramEndpoint(
            remote: .init(host: "127.0.0.1", port: 60021),
            connectionFactory: { _, _, _ in connections.next() }
        )
        let old = try await startReady(endpoint, on: connections, index: 0)
        await endpoint.stop()
        let current = try await startReady(endpoint, on: connections, index: 1)

        let waiting = Task { try await endpoint.receive() }
        let receiveAwaited = await waitUntil { await endpoint._testPendingReceiveCount() == 1 }
        XCTAssertTrue(receiveAwaited)
        old.emitReceive(content: nil, error: .posix(.ECANCELED))
        let disturbed = await waitUntil(within: 0.3) {
            if current.receiveRegistrationCount != 1 { return true }
            return await endpoint._testPendingReceiveCount() != 1
        }
        XCTAssertFalse(disturbed, "the old connection's receive reached the new connection")

        current.emitReceive(content: Data([0x0B]), error: nil)
        let datagram = try await waiting.value
        XCTAssertEqual(datagram.data, Data([0x0B]))
        await endpoint.stop()
    }

    /// A datagram the stopped connection delivers late is not the next
    /// connection's to receive.
    func testALateDatagramFromAStoppedConnectionIsNotReceivedAfterTheRestart() async throws {
        let connections = FakeConnectionSequence()
        let endpoint = NetworkDatagramEndpoint(
            remote: .init(host: "127.0.0.1", port: 60022),
            connectionFactory: { _, _, _ in connections.next() }
        )
        let old = try await startReady(endpoint, on: connections, index: 0)
        await endpoint.stop()
        old.emitReceive(content: Data([0x0A]), error: nil)
        // Gives the late delivery time to reach the endpoint, as it would
        // between a stop and the next start.
        _ = await waitUntil(within: 0.3) { false }

        let current = try await startReady(endpoint, on: connections, index: 1)
        let waiting = Task { try await endpoint.receive() }
        let receiveAwaited = await waitUntil { await endpoint._testPendingReceiveCount() == 1 }
        XCTAssertTrue(receiveAwaited, "nothing from the old connection waits in the buffer")
        current.emitReceive(content: Data([0x0B]), error: nil)
        let datagram = try await waiting.value
        XCTAssertEqual(datagram.data, Data([0x0B]))
        await endpoint.stop()
    }

    /// Starts `endpoint` on `connections[index]`, reporting it ready.
    private func startReady(
        _ endpoint: NetworkDatagramEndpoint, on connections: FakeConnectionSequence, index: Int
    ) async throws -> FakeUDPConnection {
        let starting = Task { try await endpoint.start() }
        let opened = await waitUntil {
            connections.count > index && connections[index].hasStateHandler
                && connections[index].startCallCount == 1
        }
        XCTAssertTrue(opened, "start must open connection \(index)")
        let connection = connections[index]
        connection.emitState(.ready)
        try await starting.value
        return connection
    }

    func testTransportEngineSendReceiveSnapshotRestoreAndFiltering() async throws {
        setenv("SWIFTMOSH_DEBUG_REAL_E2E", "1", 1)
        defer { unsetenv("SWIFTMOSH_DEBUG_REAL_E2E") }

        let endpoint = StubDatagramEndpoint()
        let engine = TransportEngine(endpoint: endpoint, outgoingDirection: .toServer, mtu: 40)

        try await engine.start()
        let seq0 = await engine.reserveOutgoingSequence()
        XCTAssertEqual(seq0, 0)

        let sendPayload = Data((0..<50).map(UInt8.init))
        try await engine.sendPayload(sendPayload, sequence: seq0)
        let sentCount = await endpoint.sentCount()
        XCTAssertGreaterThan(sentCount, 1)
        let sentDatagrams = await endpoint.sentDatagrams()
        let sentPackets = try sentDatagrams.map(MoshPacketCodec.decode)
        for (index, packet) in sentPackets.enumerated() {
            XCTAssertEqual(packet.sequence, UInt64(index))
        }

        var snapshot = await engine.makeSnapshot()
        XCTAssertEqual(snapshot.nextOutgoingSequence, UInt64(sentCount))
        XCTAssertEqual(snapshot.nextInstructionID, 1)
        XCTAssertNotNil(snapshot.lastSentAtMs)

        snapshot.expectedIncomingSequence = 3
        await engine.restore(from: snapshot)

        // wrong direction packet (toServer) should be skipped
        await endpoint.inject(datagramFromPacket(seq: 3, dir: .toServer, fragmentID: 1, fragmentNumber: 0, final: true, contents: Data([0xA0])))
        // stale packet (seq 2) should be skipped
        await endpoint.inject(datagramFromPacket(seq: 2, dir: .toClient, fragmentID: 1, fragmentNumber: 0, final: true, contents: Data([0xA1])))

        let fullPayload = Data([0x10, 0x11, 0x12, 0x13, 0x14])
        await endpoint.inject(datagramFromPacket(seq: 3, dir: .toClient, fragmentID: 7, fragmentNumber: 0, final: false, contents: Data(fullPayload.prefix(2))))
        await endpoint.inject(datagramFromPacket(seq: 3, dir: .toClient, fragmentID: 7, fragmentNumber: 1, final: true, contents: Data(fullPayload.suffix(3))))

        let received = try await engine.receivePayload()
        XCTAssertEqual(received.sequence, 3)
        XCTAssertEqual(received.direction, .toClient)
        XCTAssertEqual(received.payload, fullPayload)

        let restoredSnapshot = await engine.makeSnapshot()
        XCTAssertEqual(restoredSnapshot.expectedIncomingSequence, 4)
        XCTAssertNotNil(restoredSnapshot.lastReceivedAtMs)

        await engine.stop()
        let stopped = await endpoint.isStopped()
        XCTAssertTrue(stopped)
    }

    func testTransportEnginePropagatesMalformedDatagramError() async throws {
        let endpoint = StubDatagramEndpoint()
        let engine = TransportEngine(endpoint: endpoint, outgoingDirection: .toServer)
        try await engine.start()

        await endpoint.inject(TransportDatagram(data: Data([0x01])))

        do {
            _ = try await engine.receivePayload()
            XCTFail("Expected wire decode failure")
        } catch {
            XCTAssertTrue(error is MoshWireError)
        }

        await engine.stop()
    }

    func testTransportEngineReceivePayloadWithDebugDisabled() async throws {
        unsetenv("SWIFTMOSH_DEBUG_REAL_E2E")

        let endpoint = StubDatagramEndpoint()
        let engine = TransportEngine(endpoint: endpoint, outgoingDirection: .toServer, mtu: 128)
        try await engine.start()

        let payload = Data([0x55, 0x56, 0x57])
        await endpoint.inject(
            datagramFromPacket(
                seq: 0,
                dir: .toClient,
                fragmentID: 44,
                fragmentNumber: 0,
                final: true,
                contents: payload
            )
        )

        let received = try await engine.receivePayload()
        XCTAssertEqual(received.payload, payload)
        XCTAssertEqual(received.sequence, 0)
        await engine.stop()
    }

    func testTransportEngineReceivePayloadThrowsCancelledWhenTaskIsCancelled() async throws {
        let endpoint = StubDatagramEndpoint()
        let engine = TransportEngine(endpoint: endpoint, outgoingDirection: .toServer)
        try await engine.start()

        let receiveTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await engine.receivePayload()
        }

        do {
            _ = try await receiveTask.value
            XCTFail("Expected cancelled")
        } catch {
            guard case .cancelled = error as? TransportError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        await engine.stop()
    }

    private func datagramFromPacket(
        seq: UInt64,
        dir: MoshDirection,
        fragmentID: UInt64,
        fragmentNumber: UInt16,
        final: Bool,
        contents: Data
    ) -> TransportDatagram {
        let fragment = MoshFragment(id: fragmentID, fragmentNumber: fragmentNumber, final: final, contents: contents)
        let packet = MoshPacket(sequence: seq, direction: dir, timestamp: 1, timestampReply: UInt16.max, payload: fragment.encoded())
        return TransportDatagram(data: MoshPacketCodec.encode(packet), receivedAtMs: TransportClock.nowMs())
    }
}

private func reserveUDPPort() throws -> UInt16 {
    let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    guard fd >= 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    defer { close(fd) }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(0).bigEndian
    address.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)

    let bindResult = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindResult == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    var bound = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &bound) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(fd, $0, &len)
        }
    }
    guard nameResult == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    return UInt16(bigEndian: bound.sin_port)
}

private actor StubDatagramEndpoint: DatagramEndpoint {
    private(set) var started = false
    private(set) var stopped = false
    private var receiveQueue: [TransportDatagram] = []
    private var sent: [Data] = []

    func start() async throws {
        if started {
            throw TransportError.alreadyStarted
        }
        started = true
        stopped = false
    }

    func stop() async {
        stopped = true
        started = false
    }

    func send(_ data: Data) async throws {
        guard started else {
            throw TransportError.notStarted
        }
        sent.append(data)
    }

    func receive() async throws -> TransportDatagram {
        guard started else {
            throw TransportError.notStarted
        }
        guard !receiveQueue.isEmpty else {
            throw TransportError.cancelled
        }
        return receiveQueue.removeFirst()
    }

    func inject(_ datagram: TransportDatagram) {
        receiveQueue.append(datagram)
    }

    func sentCount() -> Int {
        sent.count
    }

    func sentDatagrams() -> [Data] {
        sent
    }

    func isStopped() -> Bool {
        stopped
    }
}

private final class FakeUDPConnection: UDPConnection, @unchecked Sendable {
    private let lock = NSLock()

    private var _stateUpdateHandler: (@Sendable (NWConnection.State) -> Void)?
    private var _receiveCompletion: (@Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void)?

    private(set) var startCallCount: Int = 0
    private(set) var receiveRegistrationCount: Int = 0
    private(set) var cancelCallCount: Int = 0
    var sendError: NWError?

    var hasStateHandler: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _stateUpdateHandler != nil
    }

    var hasReceiveHandler: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _receiveCompletion != nil
    }

    func setStateUpdateHandler(_ handler: (@Sendable (NWConnection.State) -> Void)?) {
        lock.lock()
        _stateUpdateHandler = handler
        lock.unlock()
    }

    func start(queue: DispatchQueue) {
        lock.lock()
        startCallCount += 1
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelCallCount += 1
        lock.unlock()
    }

    func send(content: Data?, completion: NWConnection.SendCompletion) {
        let error: NWError?
        lock.lock()
        error = sendError
        lock.unlock()

        if case .contentProcessed(let callback) = completion {
            callback(error)
        }
    }

    func receiveMessage(completion: @escaping @Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void) {
        lock.lock()
        _receiveCompletion = completion
        receiveRegistrationCount += 1
        lock.unlock()
    }

    func emitState(_ state: NWConnection.State) {
        let callback: (@Sendable (NWConnection.State) -> Void)?
        lock.lock()
        callback = _stateUpdateHandler
        lock.unlock()
        callback?(state)
    }

    func emitReceive(content: Data?, error: NWError?) {
        let callback: (@Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void)?
        lock.lock()
        callback = _receiveCompletion
        lock.unlock()
        callback?(content, nil, true, error)
    }
}

/// How a start ended, set once from the task that awaited it.
private final class StartOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: String?

    var value: String? {
        lock.withLock { outcome }
    }

    func set(_ value: String) {
        lock.withLock { outcome = value }
    }
}

/// Hands out a new `FakeUDPConnection` per `NetworkDatagramEndpoint`
/// start, keeping each so a test can drive an old one's callbacks.
private final class FakeConnectionSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [FakeUDPConnection] = []

    var count: Int {
        lock.withLock { made.count }
    }

    subscript(index: Int) -> FakeUDPConnection {
        lock.withLock { made[index] }
    }

    func next() -> FakeUDPConnection {
        let connection = FakeUDPConnection()
        lock.withLock { made.append(connection) }
        return connection
    }
}
