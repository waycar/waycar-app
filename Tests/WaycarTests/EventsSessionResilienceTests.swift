import Foundation
import Testing

@testable import Waycar

/// Keeping the Host's SSH connection across a suspension, and the liveness
/// deadlines around it (#105). The suspension keeps the pooled connection
/// open, and the return probes it with a short deadline, racing a hedged
/// fresh dial once the probe is slow. Keepalive and revalidation pings fail
/// within seconds, not at the RPC budget. A path that comes back cuts every
/// reconnect short.
///
/// The connection layer is a `ScriptedSharedConnection` and time is a
/// `ScriptedLivenessClock`: measured round trips are zero, so the deadline
/// is its 2 s floor and the hedge delay its 200 ms floor, and both pass only
/// when the test fires them.
@Suite("EventsSession resilience", .timeLimit(.minutes(1)))
struct EventsSessionResilienceTests {
    private let subscriptions: [EventSubscription] = [.global(.paneAgentDetected)]
    private static let kept = PooledConnectionID(key: "host", serial: 1)
    private static let fresh = PooledConnectionID(key: "host", serial: 2)
    private static let deadline = Duration.seconds(2)
    private static let hedgeDelay = Duration.milliseconds(200)
    private static let setupDeadline = Duration.seconds(3)
    /// Revalidation times itself from its own latency, never the ping's:
    /// until one is observed it takes `LivenessTiming`'s patient defaults.
    private static let revalidateDeadline = Duration.seconds(5)
    private static let revalidateHedgeDelay = Duration.milliseconds(800)
    private static let fastReconnect = ReconnectPolicy(
        initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50))

    private func makeSession(
        _ sharing: ScriptedSharedConnection,
        clock: ScriptedLivenessClock,
        keepalive: KeepalivePolicy? = nil,
        reconnect: ReconnectPolicy = Self.fastReconnect
    ) -> EventsSession {
        EventsSession(
            subscriptions: subscriptions,
            connection: sharing.connection,
            reconnectPolicy: reconnect,
            keepalive: keepalive,
            clock: clock.clock)
    }

    @Test func aKeptConnectionThatAnswersIsReusedWithoutADial() async throws {
        let first = ScriptedTransport()
        let returning = ScriptedTransport()
        let sharing = ScriptedSharedConnection()
        await sharing.answer(.transport(first, on: Self.kept))
        await sharing.answer(.transport(returning, on: Self.kept))
        let clock = ScriptedLivenessClock()
        let session = makeSession(sharing, clock: clock)
        let log = UpdateLog(following: session)

        await session.resume()
        try await log.waitForStatus(.connected, count: 1)
        await session.suspend()
        try await log.waitForStatus(.suspended, count: 1)
        // Quiesced: the Transport and every channel on it closed, while the
        // connection itself is held for the return.
        #expect(await first.isClosed)
        #expect(await sharing.calls == [.connect(replacing: nil), .keep(Self.kept)])

        let probe = ScriptedTransportCallGate()
        await returning.gateNextPing(using: probe)
        await session.resume()
        // The pool handed back the kept connection: its ping is a liveness
        // probe under the deadline, racing the hedge timer, not a new dial's
        // first ping under the RPC budget.
        #expect(await clock.waitForSleep(Self.hedgeDelay))
        #expect(await clock.waitForSleep(Self.deadline))
        await probe.open()
        try await log.waitForStatus(.connected, count: 2)

        // It answered: nothing was dialed beside it, and the keep's hold
        // went back to the Transport that proved it.
        #expect(
            await sharing.calls == [
                .connect(replacing: nil), .keep(Self.kept),
                .connect(replacing: nil), .release(Self.kept),
            ])
        #expect(await returning.capturedSubscriptions == [subscriptions])
        await session.end()
    }

    @Test func theHedgeWinsWhenTheKeptConnectionStallsAndTheLoserIsClosed() async throws {
        let first = ScriptedTransport()
        let stalled = ScriptedTransport()
        let replacement = ScriptedTransport()
        let sharing = ScriptedSharedConnection()
        await sharing.answer(.transport(first, on: Self.kept))
        await sharing.answer(.transport(stalled, on: Self.kept))
        await sharing.answer(.transport(replacement, on: Self.fresh))
        let clock = ScriptedLivenessClock()
        let session = makeSession(sharing, clock: clock)
        let log = UpdateLog(following: session)

        await session.resume()
        try await log.waitForStatus(.connected, count: 1)
        await session.suspend()
        try await log.waitForStatus(.suspended, count: 1)

        let stall = ScriptedTransportCallGate()
        await stalled.gateNextPing(using: stall)
        await session.resume()
        #expect(await clock.waitForSleep(Self.hedgeDelay))
        clock.fire(Self.hedgeDelay)
        try await log.waitForStatus(.connected, count: 2)

        // The hedge dialed a replacement for the kept connection, proved it
        // first, and the kept connection stopped being shared.
        #expect(
            await sharing.calls == [
                .connect(replacing: nil), .keep(Self.kept),
                .connect(replacing: nil), .connect(replacing: Self.kept), .retire(Self.kept),
            ])
        try await waitUntil("the kept connection's Transport should close") {
            await stalled.isClosed
        }
        #expect(await replacement.capturedSubscriptions == [subscriptions])
        #expect(await stalled.capturedSubscriptions.isEmpty)
        // Published under a generation of its own: not the first
        // connection's 0, nor the 1 the kept connection's probe reserved.
        #expect(await session.transportGeneration == 2)
        #expect(await !log.sawReconnecting)
        await stall.open()
        await session.end()
    }

    /// The deadline passes while the hedge is still dialing: the probe's
    /// ping, cancelled by that deadline, then fails as `.cancelled`. The
    /// race is the hedge's to win, not lost to the proof's own teardown.
    @Test func aDeadlinePassingWhileTheHedgeDialsLeavesTheResumeToTheHedge() async throws {
        let first = ScriptedTransport()
        let stalled = ScriptedTransport()
        let replacement = ScriptedTransport()
        let dialing = ScriptedTransportCallGate()
        let sharing = ScriptedSharedConnection()
        await sharing.answer(.transport(first, on: Self.kept))
        await sharing.answer(.transport(stalled, on: Self.kept))
        await sharing.answer(.gated(replacement, on: Self.fresh, dialing))
        let clock = ScriptedLivenessClock()
        let session = makeSession(sharing, clock: clock)
        let log = UpdateLog(following: session)

        await session.resume()
        try await log.waitForStatus(.connected, count: 1)
        await session.suspend()
        try await log.waitForStatus(.suspended, count: 1)

        let stall = ScriptedTransportCallGate()
        await stalled.gateNextPing(using: stall)
        await stalled.failPing(atCall: 1, with: .cancelled)
        await session.resume()
        #expect(await clock.waitForSleep(Self.hedgeDelay))
        clock.fire(Self.hedgeDelay)
        try await waitUntil("the hedge should be dialing") {
            await sharing.calls.contains(.connect(replacing: Self.kept))
        }
        #expect(clock.fire(Self.deadline) == 1)
        // Let the deadline settle before the cancelled ping comes back.
        try await Task.sleep(for: .milliseconds(100))
        await stall.open()
        try await Task.sleep(for: .milliseconds(100))
        await dialing.open()
        try await log.waitForStatus(.connected, count: 2)

        #expect(await !log.sawReconnecting)
        #expect(
            await sharing.calls == [
                .connect(replacing: nil), .keep(Self.kept),
                .connect(replacing: nil), .connect(replacing: Self.kept), .retire(Self.kept),
            ])
        #expect(await replacement.capturedSubscriptions == [subscriptions])
        #expect(await session.transportGeneration == 2)
        await session.end()
    }

    /// tmux's probe of a kept connection runs detection and its control-mode
    /// open before any ping. A slow setup on a healthy connection starts no
    /// clock: no replacement is dialed beside it, and the Host still rides
    /// one connection when the probe answers.
    @Test func aSlowSetupOnAHealthyKeptConnectionDialsNoReplacement() async throws {
        let first = ScriptedTransport()
        let returning = ScriptedTransport()
        let setup = ScriptedTransportCallGate()
        let sharing = ScriptedSharedConnection()
        await sharing.answer(.transport(first, on: Self.kept))
        await sharing.answer(.gated(returning, on: Self.kept, setup))
        let clock = ScriptedLivenessClock()
        let session = makeSession(sharing, clock: clock)
        let log = UpdateLog(following: session)

        await session.resume()
        try await log.waitForStatus(.connected, count: 1)
        await session.suspend()
        try await log.waitForStatus(.suspended, count: 1)

        let ping = ScriptedTransportCallGate()
        await returning.gateNextPing(using: ping)
        await session.resume()
        // Only the setup's own bound runs while the Transport is set up.
        #expect(await clock.waitForSleep(Self.setupDeadline))
        #expect(!clock.isSleeping(Self.hedgeDelay))
        #expect(!clock.isSleeping(Self.deadline))
        await setup.open()
        // The ping's clocks start once the probe holds its Transport.
        #expect(await clock.waitForSleep(Self.hedgeDelay))
        #expect(await clock.waitForSleep(Self.deadline))
        await ping.open()
        try await log.waitForStatus(.connected, count: 2)

        #expect(
            await sharing.calls == [
                .connect(replacing: nil), .keep(Self.kept),
                .connect(replacing: nil), .release(Self.kept),
            ])
        #expect(await !log.sawReconnecting)
        await session.end()
    }

    /// A setup that never finishes counts as a link failure at its bound:
    /// the replacement is dialed then, and the kept connection retired.
    @Test func aSetupThatNeverFinishesIsReplacedAtTheSetupDeadline() async throws {
        let first = ScriptedTransport()
        let replacement = ScriptedTransport()
        let sharing = ScriptedSharedConnection()
        await sharing.answer(.transport(first, on: Self.kept))
        await sharing.answer(.hang)
        await sharing.answer(.transport(replacement, on: Self.fresh))
        let clock = ScriptedLivenessClock()
        let session = makeSession(sharing, clock: clock)
        let log = UpdateLog(following: session)

        await session.resume()
        try await log.waitForStatus(.connected, count: 1)
        await session.suspend()
        try await log.waitForStatus(.suspended, count: 1)

        await session.resume()
        #expect(await clock.waitForSleep(Self.setupDeadline))
        clock.fire(Self.setupDeadline)
        try await log.waitForStatus(.connected, count: 2)
        #expect(
            await sharing.calls == [
                .connect(replacing: nil), .keep(Self.kept),
                .connect(replacing: nil), .connect(replacing: Self.kept), .retire(Self.kept),
            ])
        #expect(await !log.sawReconnecting)
        await session.end()
    }

    @Test func aConnectionKeptForMoreThanTenMinutesIsRedialed() async throws {
        let first = ScriptedTransport()
        let redialed = ScriptedTransport()
        let sharing = ScriptedSharedConnection()
        await sharing.answer(.transport(first, on: Self.kept))
        await sharing.answer(.transport(redialed, on: Self.fresh))
        let clock = ScriptedLivenessClock()
        let session = makeSession(sharing, clock: clock)
        let log = UpdateLog(following: session)

        await session.resume()
        try await log.waitForStatus(.connected, count: 1)
        await session.suspend()
        try await log.waitForStatus(.suspended, count: 1)

        clock.advance(by: .seconds(601))
        await session.resume()
        try await log.waitForStatus(.connected, count: 2)

        // Retired unprobed before the dial, so the pool dials anew.
        #expect(
            await sharing.calls == [
                .connect(replacing: nil), .keep(Self.kept),
                .retire(Self.kept), .connect(replacing: nil),
            ])
        #expect(await redialed.capturedSubscriptions == [subscriptions])
        await session.end()
    }

    @Test func aKeepaliveThatGoesUnansweredFailsAtTheLivenessDeadline() async throws {
        let first = ScriptedTransport()
        let second = ScriptedTransport()
        let sharing = ScriptedSharedConnection()
        await sharing.answer(.transport(first, on: Self.kept))
        await sharing.answer(.transport(second, on: Self.fresh))
        let clock = ScriptedLivenessClock()
        let session = makeSession(
            sharing, clock: clock, keepalive: KeepalivePolicy(interval: .milliseconds(500)))
        let log = UpdateLog(following: session)

        await session.resume()
        try await log.waitForStatus(.connected, count: 1)
        let hung = ScriptedTransportCallGate()
        await first.gateNextPing(using: hung)

        // The idle keepalive's ping waits out the 2 s liveness deadline, not
        // the 15 s RPC budget.
        #expect(await clock.waitForSleep(Self.deadline))
        clock.fire(Self.deadline)
        try await log.waitForStatus(.connected, count: 2)
        #expect(await log.reconnectFailures == [.timedOut])
        // Found dead by a deadline the SSH layer has not reached: the pool
        // stops handing it out, so the redial does not ride it again.
        #expect(await sharing.calls.contains(.retire(Self.kept)))
        #expect(await second.capturedSubscriptions == [subscriptions])
        await hung.open()
        await session.end()
    }

    /// The revalidation ping fails on the link, so the hedge dials at once,
    /// and the hedge fails on the link too: the race settles with the
    /// hedge's failure then, without waiting for the deadline.
    @Test func aProofAndHedgeThatBothFailSettleWithoutTheDeadline() async throws {
        let original = ScriptedTransport()
        let redial = ScriptedTransport()
        let sharing = ScriptedSharedConnection()
        await sharing.answer(.transport(original, on: Self.kept))
        await sharing.answer(.failure(.sshUnreachable(detail: "hedge failed")))
        await sharing.answer(.transport(redial, on: Self.fresh))
        let clock = ScriptedLivenessClock()
        let session = makeSession(sharing, clock: clock)
        let log = UpdateLog(following: session)

        await session.resume()
        try await log.waitForStatus(.connected, count: 1)
        await original.failPing(atCall: 2, with: .sshUnreachable(detail: "proof failed"))
        let revalidation = Task { await session.revalidate() }
        await revalidation.value

        let calls = await sharing.calls
        #expect(
            Array(calls.prefix(2)) == [.connect(replacing: nil), .connect(replacing: Self.kept)])
        #expect(clock.fire(Self.revalidateDeadline) == 0)
        await session.end()
    }

    @Test func aRevalidationThatGoesUnansweredFailsAtTheLivenessDeadline() async throws {
        let transport = ScriptedTransport()
        let second = ScriptedTransport()
        let connector = SequencedTransportConnector([transport, second])
        let clock = ScriptedLivenessClock()
        let session = EventsSession(
            subscriptions: subscriptions,
            connect: { try await connector.connect() },
            reconnectPolicy: Self.fastReconnect,
            keepalive: nil,
            clock: clock.clock)
        let log = UpdateLog(following: session)

        await session.resume()
        try await log.waitForStatus(.connected, count: 1)
        let hung = ScriptedTransportCallGate()
        await transport.gateNextPing(using: hung)
        let revalidation = Task { await session.revalidate() }

        #expect(await clock.waitForSleep(Self.revalidateDeadline))
        // No pooled connection to replace it, so no hedge either.
        #expect(!clock.isSleeping(Self.revalidateHedgeDelay))
        clock.fire(Self.revalidateDeadline)
        await revalidation.value
        try await log.waitForStatus(.connected, count: 2)
        #expect(await log.reconnectFailures == [.timedOut])
        #expect(await connector.connectCount == 2)
        await hung.open()
        await session.end()
    }

    /// The path-change probe: a connection the old path carried does not
    /// answer, and a fresh one replaces it without the Host ever showing a
    /// reconnect.
    @Test func aRevalidationHedgeReplacesAnUnansweredConnectionSilently() async throws {
        let original = ScriptedTransport()
        let replacement = ScriptedTransport()
        let sharing = ScriptedSharedConnection()
        await sharing.answer(.transport(original, on: Self.kept))
        await sharing.answer(.transport(replacement, on: Self.fresh))
        let clock = ScriptedLivenessClock()
        let session = makeSession(sharing, clock: clock)
        let log = UpdateLog(following: session)

        await session.resume()
        try await log.waitForStatus(.connected, count: 1)
        let hung = ScriptedTransportCallGate()
        await original.gateNextPing(using: hung)
        let revalidation = Task { await session.revalidate() }

        #expect(await clock.waitForSleep(Self.revalidateHedgeDelay))
        clock.fire(Self.revalidateHedgeDelay)
        await revalidation.value
        // The events channel moved to the replacement: a fresh `.connected`
        // (the consumer's resync) and never a `.reconnecting`.
        try await log.waitForStatus(.connected, count: 2)
        #expect(await !log.sawReconnecting)
        #expect(
            await sharing.calls == [
                .connect(replacing: nil), .connect(replacing: Self.kept), .retire(Self.kept),
            ])
        try await waitUntil("the unanswered connection's Transport should close") {
            await original.isClosed
        }
        #expect(await replacement.capturedSubscriptions == [subscriptions])
        #expect(await session.transportGeneration == 1)
        await hung.open()
        await session.end()
    }

    /// As above, but the deadline passes while the hedge is dialing and the
    /// cancelled revalidation ping then fails as `.cancelled`: the hedge
    /// still replaces the unanswered connection.
    @Test func aDeadlinePassingWhileTheHedgeDialsLeavesTheRevalidationToTheHedge()
        async throws
    {
        let original = ScriptedTransport()
        let replacement = ScriptedTransport()
        let dialing = ScriptedTransportCallGate()
        let sharing = ScriptedSharedConnection()
        await sharing.answer(.transport(original, on: Self.kept))
        await sharing.answer(.gated(replacement, on: Self.fresh, dialing))
        let clock = ScriptedLivenessClock()
        let session = makeSession(sharing, clock: clock)
        let log = UpdateLog(following: session)

        await session.resume()
        try await log.waitForStatus(.connected, count: 1)
        let hung = ScriptedTransportCallGate()
        await original.gateNextPing(using: hung)
        await original.failPing(atCall: 2, with: .cancelled)
        let revalidation = Task { await session.revalidate() }

        #expect(await clock.waitForSleep(Self.revalidateHedgeDelay))
        clock.fire(Self.revalidateHedgeDelay)
        try await waitUntil("the hedge should be dialing") {
            await sharing.calls.contains(.connect(replacing: Self.kept))
        }
        #expect(clock.fire(Self.revalidateDeadline) == 1)
        try await Task.sleep(for: .milliseconds(100))
        await hung.open()
        try await Task.sleep(for: .milliseconds(100))
        await dialing.open()
        await revalidation.value

        try await log.waitForStatus(.connected, count: 2)
        #expect(await !log.sawReconnecting)
        #expect(
            await sharing.calls == [
                .connect(replacing: nil), .connect(replacing: Self.kept), .retire(Self.kept),
            ])
        #expect(await session.transportGeneration == 1)
        await session.end()
    }

    /// tmux's revalidate on an idle dual Host runs a `tmux ls` exec where
    /// its ping is local, so a ping-proven round trip of ~0 must not time
    /// it. A healthy revalidation slower than the ping's 200 ms hedge floor
    /// dials no replacement, and the Host never rides two connections;
    /// once observed, its own latency times the next one.
    @Test func aSlowRevalidateOnAHealthyConnectionDialsNoReplacement() async throws {
        let original = ScriptedTransport()
        let sharing = ScriptedSharedConnection()
        await sharing.answer(.transport(original, on: Self.kept))
        let clock = ScriptedLivenessClock()
        let session = makeSession(sharing, clock: clock)
        let log = UpdateLog(following: session)

        await session.resume()
        try await log.waitForStatus(.connected, count: 1)
        let generation = await session.transportGeneration
        let recheck = ScriptedTransportCallGate()
        await original.gateNextPing(using: recheck)
        let revalidation = Task { await session.revalidate() }

        #expect(await clock.waitForSleep(Self.revalidateHedgeDelay))
        #expect(await clock.waitForSleep(Self.revalidateDeadline))
        #expect(!clock.isSleeping(Self.hedgeDelay))
        #expect(clock.fire(Self.hedgeDelay) == 0)
        clock.advance(by: .milliseconds(600))
        await recheck.open()
        await revalidation.value

        // 600 ms observed: clamp(2 × 600 ms + 150 ms, 200, 800) = 800 ms
        // hedge, clamp(4 × 600 ms + 1 s, 2, 5) = 3.4 s deadline.
        let next = ScriptedTransportCallGate()
        await original.gateNextPing(using: next)
        let second = Task { await session.revalidate() }
        #expect(await clock.waitForSleep(.milliseconds(3_400)))
        await next.open()
        await second.value

        #expect(await sharing.calls == [.connect(replacing: nil)])
        #expect(await !log.sawReconnecting)
        #expect(await original.revalidateCount == 2)
        #expect(await session.transportGeneration == generation, "no replacement installed")
        await session.end()
    }

    @Test func aPathBackCutsAReconnectBackoffShort() async throws {
        let transport = ScriptedTransport()
        let sharing = ScriptedSharedConnection()
        await sharing.answer(.failure(.sshUnreachable(detail: "no route to host")))
        await sharing.answer(.transport(transport, on: Self.kept))
        let clock = ScriptedLivenessClock()
        let session = makeSession(
            sharing, clock: clock,
            reconnect: ReconnectPolicy(
                initialDelay: .seconds(60), multiplier: 2, maxDelay: .seconds(60)))
        let log = UpdateLog(following: session)

        await session.resume()
        try await waitUntil("the first dial should fail into a long backoff") {
            await log.sawReconnecting
        }
        await session.redialNow(trigger: .pathChange)
        try await log.waitForStatus(.connected, count: 1)
        #expect(await sharing.connectCalls.count == 2)
        await session.end()
    }

    @Test func aPathBackCancelsAStuckDialAndDialsAgainAtOnce() async throws {
        let transport = ScriptedTransport()
        let sharing = ScriptedSharedConnection()
        await sharing.answer(.hang)
        await sharing.answer(.transport(transport, on: Self.kept))
        let clock = ScriptedLivenessClock()
        let session = makeSession(sharing, clock: clock)
        let log = UpdateLog(following: session)

        await session.resume()
        try await waitUntil("the first dial should be in flight") {
            await sharing.connectCalls.count == 1
        }
        await session.redialNow(trigger: .pathChange)
        try await log.waitForStatus(.connected, count: 1)

        // The stuck dial is dropped and no later connect joins it; the redial
        // is no failure of the Host's, so no `.reconnecting` either.
        #expect(
            await sharing.calls == [
                .connect(replacing: nil), .abandonDial, .connect(replacing: nil),
            ])
        #expect(await !log.sawReconnecting)
        await session.end()
    }

    /// One recovery fires two redials, the path's return and a mosh
    /// server answering after its stall: the second leaves the fresh dial
    /// the first started alone instead of cancelling it mid-handshake.
    @Test func aSecondRedialLeavesTheFirstRedialsDialAlone() async throws {
        let transport = ScriptedTransport()
        let sharing = ScriptedSharedConnection()
        let handshake = ScriptedTransportCallGate()
        await sharing.answer(.hang)
        await sharing.answer(.gated(transport, on: Self.kept, handshake))
        let clock = ScriptedLivenessClock()
        let session = makeSession(sharing, clock: clock)
        let log = UpdateLog(following: session)

        await session.resume()
        try await waitUntil("the first dial should be in flight") {
            await sharing.connectCalls.count == 1
        }
        await session.redialNow(trigger: .pathChange)
        try await waitUntil("the path return's dial should be in flight") {
            await sharing.connectCalls.count == 2
        }
        await session.redialNow(trigger: .moshRecovery)
        await handshake.open()
        try await log.waitForStatus(.connected, count: 1)

        #expect(
            await sharing.calls == [
                .connect(replacing: nil), .abandonDial, .connect(replacing: nil),
            ])
        await session.end()
    }

    /// The reverse order: mosh's redial cut a backoff short, and the
    /// path's return that follows leaves the dial it started alone.
    @Test func aPathReturnLeavesAMoshRecoveryDialAlone() async throws {
        let transport = ScriptedTransport()
        let sharing = ScriptedSharedConnection()
        let handshake = ScriptedTransportCallGate()
        await sharing.answer(.failure(.sshUnreachable(detail: "no route to host")))
        await sharing.answer(.gated(transport, on: Self.kept, handshake))
        let clock = ScriptedLivenessClock()
        let session = makeSession(
            sharing, clock: clock,
            reconnect: ReconnectPolicy(
                initialDelay: .seconds(60), multiplier: 2, maxDelay: .seconds(60)))
        let log = UpdateLog(following: session)

        await session.resume()
        try await waitUntil("the first dial should fail into a long backoff") {
            await log.sawReconnecting
        }
        await session.redialNow(trigger: .moshRecovery)
        try await waitUntil("the mosh recovery's dial should be in flight") {
            await sharing.connectCalls.count == 2
        }
        await session.redialNow(trigger: .pathChange)
        await handshake.open()
        try await log.waitForStatus(.connected, count: 1)

        #expect(await sharing.calls == [.connect(replacing: nil), .connect(replacing: nil)])
        await session.end()
    }

    /// The expiration path: no background time is left, so the suspension
    /// quiesces locally and returns while a close is still parked.
    @Test func aLocalSuspensionWaitsForNoClose() async throws {
        let transport = ScriptedTransport()
        let connector = SequencedTransportConnector([transport])
        let session = EventsSession(
            subscriptions: subscriptions,
            connect: { try await connector.connect() },
            reconnectPolicy: Self.fastReconnect,
            keepalive: nil)
        let log = UpdateLog(following: session)

        await session.resume()
        try await log.waitForStatus(.connected, count: 1)
        let closing = ScriptedTransportCallGate()
        await transport.gateNextClose(using: closing)
        let returned = Flag()
        Task {
            await session.suspend(locally: true)
            await returned.set()
        }

        try await waitUntil("a local suspension should return without waiting on the close") {
            await returned.isSet
        }
        try await log.waitForStatus(.suspended, count: 1)
        try await waitUntil("the close runs on its own, parked at the gate") {
            await closing.entryCount == 1
        }
        #expect(await !transport.isClosed)
        await closing.open()
        try await waitUntil("the close should still finish on its own") {
            await transport.isClosed
        }
        await session.end()
    }
}

/// A session's updates, drained as they come so a test waits on a bounded
/// poll rather than blocking on `next()`.
private actor UpdateLog {
    private(set) var updates: [EventsSessionUpdate] = []

    init(following session: EventsSession) {
        Task { [weak self] in
            for await update in session.updates {
                await self?.append(update)
            }
        }
    }

    private func append(_ update: EventsSessionUpdate) {
        updates.append(update)
    }

    var statuses: [EventsSessionStatus] {
        updates.compactMap { update in
            if case .status(let status) = update { status } else { nil }
        }
    }

    var sawReconnecting: Bool {
        !reconnectFailures.isEmpty
    }

    var reconnectFailures: [TransportError] {
        statuses.compactMap { status in
            if case .reconnecting(_, _, let failure) = status { failure } else { nil }
        }
    }

    func waitForStatus(
        _ status: EventsSessionStatus, count: Int, timeout: Duration = .waitCeiling
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if statuses.filter({ $0 == status }).count >= count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        let seen = statuses
        #expect(
            seen.filter { $0 == status }.count >= count,
            "expected \(count) × \(status), saw \(seen)")
    }
}

private actor Flag {
    private(set) var isSet = false

    func set() {
        isSet = true
    }
}
