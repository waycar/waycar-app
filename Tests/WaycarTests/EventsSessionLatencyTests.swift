import Foundation
import Testing

@testable import Waycar

/// `EventsSession.currentLatency` (#236): the measurement a consumer folds
/// against a status update.
///
/// `updates` and `latencyUpdates` are separate streams with separate
/// consumers, so nothing about the order one is drained in tells you anything
/// about the other. These tests pin the producer-side ordering that makes the
/// pairing exact regardless: the value is in place before the `.connected`
/// that announces a proven connection, and gone before the status that ends
/// one — even while the sample itself is still queued for its own consumer.
/// A session that stops answering simply never publishes again, so the suite
/// is bounded rather than left waiting for a status that will not arrive.
@Suite("EventsSession latency pairing", .timeLimit(.minutes(1)))
struct EventsSessionLatencyTests {
    private let subscriptions: [EventSubscription] = [.global(.paneAgentDetected)]

    private func makeSession(transport: ScriptedTransport) -> EventsSession {
        makeSession(connect: { transport })
    }

    private func makeSession(
        connect: @escaping @Sendable () async throws -> any Transport
    ) -> EventsSession {
        EventsSession(
            subscriptions: subscriptions,
            connect: connect,
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50)),
            keepalive: nil)
    }

    /// The connect ping is held open, so "unproven" is a fact here rather
    /// than a race: nothing can have answered yet.
    @Test func theConnectionIsUnprovenUntilItsPingAnswers() async throws {
        let transport = ScriptedTransport()
        let gate = ScriptedTransportCallGate()
        await transport.gateNextPing(using: gate)
        let session = makeSession(transport: transport)
        var updates = session.updates.makeAsyncIterator()

        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        try await waitUntil("the connect ping should be in flight") {
            await gate.entryCount == 1
        }
        #expect(session.currentLatency == nil)

        await gate.open()
        #expect(await updates.next() == .status(.connected))
        // Folding `.connected` and reading the value in the same turn must
        // never find the connection unproven: the sample is published before
        // the status that announces it.
        #expect(session.currentLatency != nil)

        await session.end()
    }

    /// The foreground re-proof must reach the transport's own `revalidate()`
    /// (tmux re-checks its control client there), not merely a ping.
    @Test func foregroundRevalidateUsesTheTransportsRevalidate() async throws {
        let transport = ScriptedTransport()
        let session = makeSession(transport: transport)
        var updates = session.updates.makeAsyncIterator()

        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))
        #expect(await transport.revalidateCount == 0)

        await session.revalidate()
        #expect(await transport.revalidateCount == 1)

        await session.end()
    }

    /// The exact shape of the race this property exists for: a consumer that
    /// has not drained `latencyUpdates` yet still finds nothing to present
    /// once the connection that measured the queued sample is gone.
    @Test func aQueuedSampleNeverOutlivesTheConnectionThatMeasuredIt() async throws {
        let transport = ScriptedTransport()
        let session = makeSession(transport: transport)
        var updates = session.updates.makeAsyncIterator()
        // Deliberately not drained until the very end.
        var samples = session.latencyUpdates.makeAsyncIterator()

        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))
        let proven = session.currentLatency
        #expect(proven != nil)

        await session.suspend()
        #expect(await updates.next() == .status(.suspended))
        #expect(session.currentLatency == nil)

        // The dead connection's sample is still sitting in its stream, and
        // arrives whenever that consumer gets around to it — long after the
        // status that ended the connection was published.
        #expect(await samples.next() == proven)
        #expect(session.currentLatency == nil)

        await session.end()
    }

    /// A reconnect stays unproven until its own ping answers: the previous
    /// connection's number is never inherited.
    @Test func aReconnectIsUnprovenUntilItsOwnPingAnswers() async throws {
        let transport = ScriptedTransport()
        let session = makeSession(transport: transport)
        var updates = session.updates.makeAsyncIterator()

        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))
        #expect(session.currentLatency != nil)

        await session.suspend()
        #expect(await updates.next() == .status(.suspended))

        let gate = ScriptedTransportCallGate()
        await transport.gateNextPing(using: gate)
        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        try await waitUntil("the replacement connection should be pinging") {
            await gate.entryCount == 1
        }
        // Held here on purpose: any value at this point could only be the
        // suspended connection's.
        #expect(session.currentLatency == nil)

        await gate.open()
        #expect(await updates.next() == .status(.connected))
        #expect(session.currentLatency != nil)

        await session.end()
    }

    /// A ping is only cancellable by request: `windDown` cancels the keepalive
    /// task without awaiting it, and a Transport may answer a request that was
    /// already in flight when its connection was torn down —
    /// `ScriptedTransport.ping()` returns successfully whether or not its task
    /// was cancelled, exactly as a real one is free to. Such an answer
    /// describes a connection the session no longer has, so it must neither
    /// resurrect its own value nor overwrite the replacement connection's —
    /// whether the foreground re-proof or the Hosts sheet's sample took it.
    @Test(arguments: [true, false])
    func aPingThatOutlivesItsConnectionCannotPublish(viaRevalidate: Bool) async throws {
        let first = ScriptedTransport()
        let second = ScriptedTransport()
        let connector = SequencedTransportConnector([first, second])
        let session = makeSession(connect: { try await connector.connect() })
        var updates = session.updates.makeAsyncIterator()

        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))
        #expect(session.currentLatency != nil)

        // A revalidate ping goes out on the live connection and is held there.
        let parked = ScriptedTransportCallGate()
        await first.gateNextPing(using: parked)
        // `revalidate()` reports nothing; only the sample's answer is checked.
        let revalidation = Task { () -> Bool? in
            if viaRevalidate {
                await session.revalidate()
                return nil
            }
            return await session.sampleLatency()
        }
        try await waitUntil("the revalidate ping should be in flight") {
            await parked.entryCount == 1
        }

        // The connection it was taken on goes away, and a different one
        // replaces it and proves itself.
        await session.suspend()
        #expect(await updates.next() == .status(.suspended))
        #expect(session.currentLatency == nil)

        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))
        let fresh = session.currentLatency
        #expect(fresh != nil)
        #expect(
            await connector.connectCount == 2,
            "the replacement connection must be a fresh dial with its own ping")

        // The parked ping answers at last, on a channel this session no longer
        // has.
        await parked.open()
        let proved = await revalidation.value
        if !viaRevalidate {
            #expect(proved == false, "an unpublished ping proves nothing")
        }
        #expect(await first.pingCount == 2, "the held ping did answer")
        #expect(session.currentLatency == fresh)

        await session.end()
    }

    /// Terminal teardown is a status like any other: `.ended` clears the
    /// value before it is published.
    @Test func endingTheSessionClearsTheValue() async throws {
        let transport = ScriptedTransport()
        let session = makeSession(transport: transport)
        var updates = session.updates.makeAsyncIterator()

        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))
        #expect(session.currentLatency != nil)

        await session.end()
        #expect(await updates.next() == .status(.ended))
        #expect(session.currentLatency == nil)
    }

    /// The badge times only the ping (#87, WS2): `ensureTransport` completes
    /// the transport's first-request prerequisites — the socket-path
    /// resolution a real herdr transport pays on its first request — before
    /// starting the clock, joining the session's dial-time prewarm. The
    /// scripted readiness stands in for that resolution, and an unresolved
    /// first `ping()` pays the same remainder, exactly like the real one.
    @Test func theBadgeExcludesTheSocketPathReadiness() async throws {
        let transport = ScriptedTransport()
        await transport.setSocketPathReadiness(delay: .milliseconds(400))
        let session = makeSession(transport: transport)
        var updates = session.updates.makeAsyncIterator()

        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))
        let measured = try #require(session.currentLatency)
        #expect(
            measured < .milliseconds(200),
            "the badge measured \(measured): socket-path readiness ran inside the clock")
        // The readiness was awaited exactly once — by the connect path, off
        // the clock — and the ping itself ran none of it a second time.
        #expect(await transport.socketPathReadinessCalls == 1)
        #expect(await transport.pingCount == 1)

        await session.end()
    }
}
