import Foundation
import Testing

@testable import Waycar

/// `EventsSession.sampleLatency()`: the Hosts sheet's on-demand re-measure.
/// Unlike the keepalive it republishes the badge every call, it times a plain
/// `ping` rather than the transport's `revalidate()`, and a failure takes the
/// keepalive's own failure path.
@Suite("EventsSession sampleLatency", .timeLimit(.minutes(1)))
struct EventsSessionSampleLatencyTests {
    private let subscriptions: [EventSubscription] = [.global(.paneAgentDetected)]

    private func makeSession(connector: SequencedTransportConnector) -> EventsSession {
        EventsSession(
            subscriptions: subscriptions,
            connect: { try await connector.connect() },
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50)),
            keepalive: nil)
    }

    @Test func republishesLatencyOnEveryCallWhileConnected() async throws {
        let transport = ScriptedTransport()
        let session = makeSession(connector: SequencedTransportConnector([transport]))
        var updates = session.updates.makeAsyncIterator()
        let collector = LatencyUpdateCollector()
        let drain = Task {
            for await _ in session.latencyUpdates {
                await collector.record()
            }
        }
        defer { drain.cancel() }

        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))
        try await waitUntil("the connect path publishes once") { await collector.count == 1 }
        // The stream keeps only its newest value, so each sample is drained
        // before the next goes out.
        for expected in 2...4 {
            #expect(await session.sampleLatency())
            try await waitUntil("each sample should republish the latency") {
                await collector.count == expected
            }
        }
        #expect(await transport.pingCount == 4)
        #expect(await transport.revalidateCount == 0)

        await session.end()
    }

    /// Between connections — the stream failed and its replacement's connect
    /// ping is still held — nothing is live to measure: no ping goes out, no
    /// value appears, and the sample reports it proved nothing.
    @Test func doesNothingWhileNoChannelIsLive() async throws {
        let first = ScriptedTransport()
        let second = ScriptedTransport()
        let replacementPing = ScriptedTransportCallGate()
        await second.gateNextPing(using: replacementPing)
        let connector = SequencedTransportConnector([first, second])
        let session = makeSession(connector: connector)
        var updates = session.updates.makeAsyncIterator()

        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))

        // A dead link, so the session redials rather than resubscribing.
        await first.setConnectionAlive(false)
        await first.failEventStream(.timedOut)
        guard case .status(.reconnecting) = await updates.next() else {
            Issue.record("expected a .reconnecting transition after the stream failed")
            await session.end()
            return
        }
        try await waitUntil("the replacement's connect ping should be held") {
            await replacementPing.entryCount == 1
        }

        let firstPings = await first.pingCount
        #expect(await session.sampleLatency() == false)
        #expect(await first.pingCount == firstPings)
        #expect(await second.pingCount == 1)
        #expect(session.currentLatency == nil)

        await replacementPing.open()
        #expect(await updates.next() == .status(.connected))
        await session.end()
    }

    @Test func aFailedSampleTakesTheKeepaliveFailurePath() async throws {
        let first = ScriptedTransport()
        let second = ScriptedTransport()
        // Ping 1 is the connect path; ping 2 is the sample.
        await first.failPing(atCall: 2, with: .timedOut)
        let connector = SequencedTransportConnector([first, second])
        let session = makeSession(connector: connector)
        var updates = session.updates.makeAsyncIterator()

        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))

        #expect(await session.sampleLatency() == false)

        guard case .status(.reconnecting(let attempt, _, let failure)) = await updates.next()
        else {
            Issue.record("expected a .reconnecting transition after the failed sample")
            await session.end()
            return
        }
        #expect(attempt == 1)
        #expect(failure == .timedOut)
        #expect(await updates.next() == .status(.connected))
        #expect(await connector.connectCount == 2)

        await session.end()
    }
}
