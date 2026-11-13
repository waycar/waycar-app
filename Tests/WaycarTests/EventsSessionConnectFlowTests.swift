import Foundation
import Synchronization
import Testing

@testable import Waycar

/// The connect path's order (#105): terminals ride a new connection before
/// its `ping`, a remembered protocol lets the first events subscribe ride
/// alongside that `ping`, and a seeded subscription set that the server
/// refuses falls back to the global set instead of failing the Host.
@Suite("EventsSession connect flow", .timeLimit(.minutes(1)))
struct EventsSessionConnectFlowTests {
    private let globals: [EventSubscription] = [.global(.paneAgentDetected)]
    private let fastPolicy = ReconnectPolicy(
        initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50))

    private func makeSession(
        connect: @escaping @Sendable () async throws -> any Transport,
        memory: (any HostConnectionMemory)? = nil
    ) -> EventsSession {
        EventsSession(
            subscriptions: globals, connect: connect, reconnectPolicy: fastPolicy,
            keepalive: nil, connectionMemory: memory)
    }

    @Test func aPingThatFailsAfterAnAttachClosesThatConnectionAndOffersTheNext() async throws {
        let first = ScriptedTransport()
        let second = ScriptedTransport()
        let pingGate = ScriptedTransportCallGate()
        await first.gateNextPing(using: pingGate)
        await first.failPing(atCall: 1, with: .timedOut)
        let connector = SequencedTransportConnector([first, second])
        let session = makeSession(connect: { try await connector.connect() })
        await session.resume()
        await pingGate.waitForEntry()

        // The ping is still out, and the terminal already has the connection.
        let attached = try await session.withTerminalTransport(target: .terminal("t1")) {
            transport, generation in
            (transport as? ScriptedTransport) === first ? generation : nil
        }
        #expect(attached == 0)

        await pingGate.open()
        try await waitUntil("the failed ping must close the connection it rode") {
            await first.isClosed
        }
        let replaced = try await session.withTerminalTransport(target: .terminal("t1")) {
            transport, generation in
            (transport as? ScriptedTransport) === second ? generation : nil
        }
        #expect(replaced == 1)
        await session.end()
    }

    /// Terminals ride a new connection ahead of its ping under the
    /// generation it will have; observers see that generation only once the
    /// ping proves the connection, so a dial that never proves itself shows
    /// them nothing that reads as a reconnection.
    @Test func aNewConnectionsGenerationIsPublishedOnlyOnceItsPingProvesIt() async throws {
        let first = ScriptedTransport()
        let second = ScriptedTransport()
        let pingGate = ScriptedTransportCallGate()
        await second.gateNextPing(using: pingGate)
        let connector = SequencedTransportConnector([first, second])
        let session = makeSession(connect: { try await connector.connect() })
        var updates = session.updates.makeAsyncIterator()
        var generations = session.terminalTransportGenerations.makeAsyncIterator()
        await session.resume()
        try await nextStatus(&updates) { $0 == .connected }
        #expect(await generations.next() == 0)

        await session.retry()
        await pingGate.waitForEntry()
        let attached = try await session.withTerminalTransport(target: .terminal("t1")) {
            transport, generation in
            (transport as? ScriptedTransport) === second ? generation : nil
        }
        #expect(attached == 1)
        #expect(await session.transportGeneration == 0)

        await pingGate.open()
        #expect(await generations.next() == 1)
        #expect(await session.transportGeneration == 1)
        await session.end()
    }

    /// A terminal riding a connection whose ping then fails is ended by that
    /// connection's close and told why, instead of seeing what reads as its
    /// pane ending normally.
    @Test func aTerminalOnAConnectionWhosePingFailsEndsWithThatFailure() async throws {
        let first = ScriptedTransport()
        let second = ScriptedTransport()
        let pingGate = ScriptedTransportCallGate()
        await first.gateNextPing(using: pingGate)
        await first.failPing(atCall: 1, with: .timedOut)
        let connector = SequencedTransportConnector([first, second])
        let session = makeSession(connect: { try await connector.connect() })
        await session.resume()
        await pingGate.waitForEntry()
        let terminal = Task {
            try await session.withTerminalTransport(target: .terminal("t1")) { transport, _ in
                let attached = try await transport.attachTerminal(Self.attachRequest)
                for try await _ in attached.output {}
            }
        }
        try await waitUntil("the terminal must attach before the ping answers") {
            await first.attachRequests == [Self.attachRequest]
        }

        await pingGate.open()
        await #expect(throws: TransportError.timedOut) { try await terminal.value }
        #expect(await first.isClosed)
        await session.end()
    }

    private static let attachRequest = TerminalAttachRequest(
        target: "w1:p1", takeover: true, cols: 80, rows: 24)

    @Test func aRememberedProtocolSubscribesAlongsideThePingAndIsRememberedAgain() async throws {
        let transport = ScriptedTransport(
            serverInfo: ServerInfo(version: "0.9.3", protocolVersion: 22))
        let pingGate = ScriptedTransportCallGate()
        await transport.gateNextPing(using: pingGate)
        let memory = RememberedFacts(protocolVersion: 19)
        let session = makeSession(connect: { transport }, memory: memory)
        var updates = session.updates.makeAsyncIterator()
        await session.resume()
        await pingGate.waitForEntry()

        try await waitUntil("the subscribe must go out while the ping is still unanswered") {
            await transport.capturedSubscriptions == [globals]
        }
        #expect(await pingGate.entryCount == 1)
        await pingGate.open()
        try await nextStatus(&updates) { $0 == .connected }
        #expect(await transport.capturedSubscriptions == [globals])
        #expect(memory.protocolVersion == 22)
        await session.end()
    }

    @Test func withoutARememberedProtocolTheSubscribeWaitsForThePing() async throws {
        let transport = ScriptedTransport()
        let pingGate = ScriptedTransportCallGate()
        await transport.gateNextPing(using: pingGate)
        let memory = RememberedFacts(protocolVersion: nil)
        let session = makeSession(connect: { transport }, memory: memory)
        var updates = session.updates.makeAsyncIterator()
        await session.resume()
        await pingGate.waitForEntry()
        try await Task.sleep(for: .milliseconds(30))
        #expect(await transport.capturedSubscriptions.isEmpty)

        await pingGate.open()
        try await nextStatus(&updates) { $0 == .connected }
        #expect(await transport.capturedSubscriptions == [globals])
        #expect(memory.protocolVersion == 17)
        await session.end()
    }

    /// The remembered protocol only lets the subscribe start early; the
    /// ping still decides, and a server below the floor fails the Host.
    @Test func aPingBelowTheFloorFailsTheConnectionItsEarlySubscribeRodeOn() async throws {
        let transport = ScriptedTransport()
        let pingGate = ScriptedTransportCallGate()
        await transport.gateNextPing(using: pingGate)
        let mismatch = TransportError.protocolVersionMismatch(server: 16, supported: 17)
        await transport.failPing(atCall: 1, with: mismatch)
        let memory = RememberedFacts(protocolVersion: 22)
        let session = makeSession(connect: { transport }, memory: memory)
        var updates = session.updates.makeAsyncIterator()
        await session.resume()
        try await waitUntil("the early subscribe must be out") {
            await transport.capturedSubscriptions.count == 1
        }

        await pingGate.open()
        try await nextStatus(&updates) { $0 == .failed(mismatch) }
        #expect(await transport.isClosed)
        #expect(memory.protocolVersion == nil)
        await session.end()
    }

    /// A seed promising an event kind the server refuses costs one silent
    /// retry with the global set, not a reconnect cycle the Host shows.
    @Test func aRejectedSeedFallsBackToTheGlobalSetOnceWithoutReconnecting() async throws {
        let transport = ScriptedTransport()
        await transport.rejectSubscribes(
            containing: .global(.workspaceReordered), code: "invalid_params")
        let session = makeSession(connect: { transport })
        var updates = session.updates.makeAsyncIterator()
        let seed =
            globals + [.global(.workspaceReordered), .pane(.agentStatusChanged, paneID: "w1:p1")]

        await session.resume(seeding: seed)
        let seen = try await nextStatus(&updates) { $0 == .connected }
        #expect(await transport.capturedSubscriptions == [seed, globals])
        #expect(seen == [.connecting, .connected])
        await session.end()
    }

    /// The same refusal of a set a live snapshot asked for goes down the
    /// ordinary visible reconnect path: only seeds get the silent fallback.
    @Test func aRejectedLiveSetReconnectsVisibly() async throws {
        let transport = ScriptedTransport()
        let session = makeSession(connect: { transport })
        var updates = session.updates.makeAsyncIterator()
        await session.resume()
        try await nextStatus(&updates) { $0 == .connected }

        await transport.rejectSubscribes(
            containing: .global(.workspaceReordered), code: "invalid_params")
        await session.updateSubscriptions(globals + [.global(.workspaceReordered)])
        try await nextStatus(&updates) {
            if case .reconnecting(_, _, .apiRejected(code: "invalid_params", _)) = $0 { return true }
            return false
        }
        await session.end()
    }

    // MARK: Helpers

    /// Consumes updates through the first status `matches` accepts and
    /// returns every status seen on the way, that one included.
    @discardableResult
    private func nextStatus(
        _ updates: inout AsyncStream<EventsSessionUpdate>.Iterator,
        where matches: (EventsSessionStatus) -> Bool
    ) async throws -> [EventsSessionStatus] {
        var seen: [EventsSessionStatus] = []
        while let update = await updates.next() {
            guard case .status(let status) = update else { continue }
            seen.append(status)
            if matches(status) { return seen }
        }
        Issue.record("the session ended before the expected status")
        return seen
    }
}

/// A `HostConnectionMemory` held in memory, for tests.
final class RememberedFacts: HostConnectionMemory {
    private let facts: Mutex<(home: String?, protocolVersion: Int?)>

    init(homeDirectory: String? = nil, protocolVersion: Int? = nil) {
        facts = Mutex((homeDirectory, protocolVersion))
    }

    var homeDirectory: String? { facts.withLock { $0.home } }
    var protocolVersion: Int? { facts.withLock { $0.protocolVersion } }

    func rememberHomeDirectory(_ home: String?) {
        facts.withLock { $0.home = home }
    }

    func rememberProtocolVersion(_ version: Int?) {
        facts.withLock { $0.protocolVersion = version }
    }
}
