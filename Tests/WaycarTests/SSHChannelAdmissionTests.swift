import Foundation
import Testing

@testable import Waycar

@Suite("SSH channel admission")
struct SSHChannelAdmissionTests {
    @Test func productionLimitsReserveEventsAndAttachWithinTheConnectionCeiling() async throws {
        let limits = SSHChannelAdmission.Limits.production
        #expect(limits.ordinaryForwarding == 8)
        #expect(limits.events == 1)
        #expect(limits.ordinarySession == 4)
        #expect(limits.attach == 5)
        // Production `connection` restates the category sum; it is not a
        // tighter live ceiling under these four budgets (#133, ADR 0011).
        #expect(
            limits.connection
                == limits.ordinaryForwarding + limits.events
                + limits.ordinarySession + limits.attach)
        // Session categories leave headroom under sshd's default MaxSessions.
        #expect(limits.ordinarySession + limits.attach < 10)

        let admission = SSHChannelAdmission()
        var sessions: [SSHChannelAdmissionLease] = []
        for _ in 0..<limits.ordinarySession {
            sessions.append(try await admission.acquire(.ordinarySession))
        }
        let attach = try await admission.acquire(.attach)
        #expect(await admission.snapshot().ordinarySession == 4)
        #expect(await admission.snapshot().attach == 1)
        #expect(await admission.snapshot().connection == 5)
        await attach.release()
        for session in sessions {
            await session.release()
        }
    }

    @Test func sessionSaturationDoesNotBlockForwardingAdmission() async throws {
        let admission = SSHChannelAdmission(
            limits: .init(
                ordinaryForwarding: 1,
                events: 1,
                ordinarySession: 1,
                attach: 1,
                connection: 4))
        let session = try await admission.acquire(.ordinarySession)
        let forwarding = try await admission.acquire(.ordinaryForwarding)

        #expect(await admission.snapshot() == .init(
            ordinaryForwarding: 1,
            events: 0,
            ordinarySession: 1,
            attach: 0,
            control: 0,
            connection: 2))
        await forwarding.release()
        await session.release()
    }

    @Test func connectionCeilingBoundsForwardingAndSessionTogether() async throws {
        let admission = SSHChannelAdmission(
            limits: .init(
                ordinaryForwarding: 2,
                events: 1,
                ordinarySession: 2,
                attach: 1,
                connection: 2))
        let forwarding = try await admission.acquire(.ordinaryForwarding)
        let session = try await admission.acquire(.ordinarySession)
        let entered = ChannelAdmissionGate()
        let waiting = Task {
            let events = try await admission.acquire(.events)
            await entered.open()
            await events.release()
        }

        await Task.yield()
        #expect(await admission.snapshot().connection == 2)
        await forwarding.release()
        await entered.waitUntilOpen()
        try await waiting.value
        await session.release()
        #expect(await admission.snapshot().connection == 0)
    }

    @Test func cancelledWaiterDoesNotLeakConnectionCapacity() async throws {
        let admission = SSHChannelAdmission(
            limits: .init(
                ordinaryForwarding: 1,
                events: 1,
                ordinarySession: 1,
                attach: 1,
                connection: 1))
        let session = try await admission.acquire(.ordinarySession)
        let waiting = Task { try await admission.acquire(.ordinaryForwarding) }
        await Task.yield()
        waiting.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await waiting.value
        }

        await session.release()
        let forwarding = try await admission.acquire(.ordinaryForwarding)
        #expect(await admission.snapshot().connection == 1)
        await forwarding.release()
        #expect(await admission.snapshot().connection == 0)
    }

    @Test func productionControlBudgetKeepsSessionChannelsUnderMaxSessions() {
        let limits = SSHChannelAdmission.Limits.production
        #expect(limits.control == 1)
        #expect(limits.connection == 18)
        // Control spends an ordinary slot: control 1 + ordinary 3 + attach 5.
        #expect(limits.ordinarySession + limits.attach == 9)
    }

    @Test func aHeldControlChannelLeavesThreeOrdinarySessions() async throws {
        let admission = SSHChannelAdmission()
        let control = try await admission.acquire(.control)
        var sessions: [SSHChannelAdmissionLease] = []
        for _ in 0..<3 {
            sessions.append(try await admission.acquire(.ordinarySession))
        }
        let entered = ChannelAdmissionGate()
        let fourth = Task {
            let lease = try await admission.acquire(.ordinarySession)
            await entered.open()
            return lease
        }

        await Task.yield()
        #expect(await admission.snapshot().ordinarySession == 3)
        #expect(await admission.snapshot().control == 1)

        await control.release()
        await entered.waitUntilOpen()
        sessions.append(try await fourth.value)
        #expect(await admission.snapshot().ordinarySession == 4)
        #expect(await admission.snapshot().control == 0)
        for session in sessions {
            await session.release()
        }
        #expect(await admission.snapshot().connection == 0)
    }

    /// A Host running herdr-core and tmux together: 1 control + 1 core +
    /// 2 ordinary + 5 attach = 9 session channels, one under sshd's default
    /// `MaxSessions` of 10, and neither long-lived channel waits for the
    /// other.
    @Test func coreAndTmuxOpenTheirChannelsTogetherUnderMaxSessions() async throws {
        let limits = SSHChannelAdmission.Limits.production
        #expect(limits.control == 1 && limits.core == 1)
        #expect(limits.control + limits.core + 2 + limits.attach == 9)

        let admission = SSHChannelAdmission()
        let control = try await admission.acquire(.control, within: .milliseconds(50))
        let core = try await admission.acquire(.core, within: .milliseconds(50))
        #expect(await admission.snapshot().control == 1)
        #expect(await admission.snapshot().core == 1)

        // Two ordinary sessions still fit; a third waits for a long-lived one.
        var sessions: [SSHChannelAdmissionLease] = []
        for _ in 0..<2 {
            sessions.append(try await admission.acquire(.ordinarySession, within: .milliseconds(50)))
        }
        await #expect(throws: TransportError.timedOut) {
            _ = try await admission.acquire(.ordinarySession, within: .milliseconds(50))
        }
        var attaches: [SSHChannelAdmissionLease] = []
        for _ in 0..<5 {
            attaches.append(try await admission.acquire(.attach, within: .milliseconds(50)))
        }
        let snapshot = await admission.snapshot()
        #expect(snapshot.control + snapshot.core + snapshot.ordinarySession + snapshot.attach == 9)

        await core.release()
        sessions.append(try await admission.acquire(.ordinarySession, within: .milliseconds(50)))
        await control.release()
        for lease in sessions + attaches { await lease.release() }
        #expect(await admission.snapshot().connection == 0)
    }

    @Test func aSecondCoreChannelWaitsForTheFirst() async throws {
        let admission = SSHChannelAdmission()
        let first = try await admission.acquire(.core)
        await #expect(throws: TransportError.timedOut) {
            _ = try await admission.acquire(.core, within: .milliseconds(50))
        }
        await first.release()
        let next = try await admission.acquire(.core, within: .milliseconds(50))
        #expect(await admission.snapshot().core == 1)
        await next.release()
    }

    /// The core slot spends an ordinary session slot, as control does: with
    /// four ordinary sessions open a core open waits instead of taking a
    /// fifth session channel.
    @Test func coreWaitsForAnOrdinarySlotWhenFourSessionsAreOpen() async throws {
        let admission = SSHChannelAdmission()
        var sessions: [SSHChannelAdmissionLease] = []
        for _ in 0..<4 {
            sessions.append(try await admission.acquire(.ordinarySession))
        }
        await #expect(throws: TransportError.timedOut) {
            _ = try await admission.acquire(.core, within: .milliseconds(50))
        }
        await sessions.removeLast().release()
        let core = try await admission.acquire(.core, within: .milliseconds(50))
        #expect(await admission.snapshot().ordinarySession == 3)
        await core.release()
        for session in sessions { await session.release() }
    }

    @Test func controlWaitsForAnOrdinarySlotWhenFourSessionsAreOpen() async throws {
        let admission = SSHChannelAdmission()
        var sessions: [SSHChannelAdmissionLease] = []
        for _ in 0..<4 {
            sessions.append(try await admission.acquire(.ordinarySession))
        }
        let entered = ChannelAdmissionGate()
        let control = Task {
            let lease = try await admission.acquire(.control)
            await entered.open()
            return lease
        }

        await Task.yield()
        #expect(await admission.snapshot().control == 0)

        await sessions.removeLast().release()
        await entered.waitUntilOpen()
        let lease = try await control.value
        #expect(await admission.snapshot().ordinarySession == 3)
        #expect(await admission.snapshot().control == 1)
        await lease.release()
        for session in sessions {
            await session.release()
        }
    }

    @Test func onlyOneControlChannelIsAdmittedAtATime() async throws {
        let admission = SSHChannelAdmission()
        let first = try await admission.acquire(.control)
        let entered = ChannelAdmissionGate()
        let second = Task {
            let lease = try await admission.acquire(.control)
            await entered.open()
            return lease
        }

        await Task.yield()
        #expect(await admission.snapshot().control == 1)
        // Attach and forwarding do not queue behind the control channel.
        let attach = try await admission.acquire(.attach)
        let forwarding = try await admission.acquire(.ordinaryForwarding)

        await first.release()
        await entered.waitUntilOpen()
        let lease = try await second.value
        #expect(await admission.snapshot().control == 1)
        await lease.release()
        await attach.release()
        await forwarding.release()
        #expect(await admission.snapshot().connection == 0)
    }

    /// A control holder that never releases (a transport dropped without
    /// `close()`) must not park the next control open forever.
    @Test func aControlWaitPastItsDeadlineTimesOutAndLeavesNoWaiter() async throws {
        let admission = SSHChannelAdmission()
        let held = try await admission.acquire(.control)
        let clock = ContinuousClock()
        let started = clock.now
        await #expect(throws: TransportError.timedOut) {
            _ = try await admission.acquire(.control, within: .milliseconds(50))
        }
        #expect(clock.now - started < .seconds(5))
        #expect(await admission.snapshot().control == 1)
        #expect(await admission.snapshot().connection == 1)
        #expect(await admission.waiterCountForTesting() == 0)

        // The expired wait is gone: a release is not handed to it.
        await held.release()
        #expect(await admission.snapshot().connection == 0)
        let next = try await admission.acquire(.control, within: .milliseconds(50))
        #expect(await admission.snapshot().control == 1)
        await next.release()
        #expect(await admission.snapshot().connection == 0)
    }

    @Test func aControlWaitWithADeadlineIsGrantedOnRelease() async throws {
        let admission = SSHChannelAdmission()
        let held = try await admission.acquire(.control)
        let entered = ChannelAdmissionGate()
        let second = Task {
            let lease = try await admission.acquire(.control, within: .seconds(30))
            await entered.open()
            return lease
        }

        // Provably parked behind the held slot before it is released.
        let deadline = ContinuousClock.now + .waitCeiling
        while await admission.waiterCountForTesting() < 1, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await admission.waiterCountForTesting() == 1)
        #expect(await admission.snapshot().control == 1)
        await held.release()
        await entered.waitUntilOpen()
        let lease = try await second.value
        #expect(await admission.waiterCountForTesting() == 0)
        #expect(await admission.snapshot().control == 1)
        await lease.release()
        #expect(await admission.snapshot().connection == 0)
    }

    /// A one-shot RPC returns its response before its channel has closed
    /// (C-CLOSE). The slot must stay spent until the SSH layer reports the
    /// channel gone, or pending closes would let the budget overrun.
    @Test func aChannelReleasedByItsOperationStaysAdmittedUntilTheReleaseRuns() async throws {
        let admission = SSHChannelAdmission(
            limits: .init(
                ordinaryForwarding: 1,
                events: 1,
                ordinarySession: 1,
                attach: 1,
                connection: 4))
        let pendingClose = PendingChannelRelease()
        let response = try await admission.withChannel(
            .ordinaryForwarding,
            releasedBy: { release in
                await pendingClose.store(release)
                return "response"
            })
        #expect(response == "response")
        #expect(await admission.snapshot().ordinaryForwarding == 1)

        let next = Task { try await admission.acquire(.ordinaryForwarding) }
        let deadline = ContinuousClock.now + .waitCeiling
        while await admission.waiterCountForTesting() < 1, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await admission.waiterCountForTesting() == 1)

        await pendingClose.run()
        let lease = try await next.value
        #expect(await admission.snapshot().ordinaryForwarding == 1)
        // The release is the lease's: running it again frees nothing more.
        await pendingClose.run()
        #expect(await admission.snapshot().ordinaryForwarding == 1)
        await lease.release()
        #expect(await admission.snapshot().connection == 0)
    }

    @Test func aThrowingReleasedByOperationFreesItsChannelAtOnce() async throws {
        let admission = SSHChannelAdmission()
        let pendingClose = PendingChannelRelease()
        await #expect(throws: TransportError.timedOut) {
            _ = try await admission.withChannel(
                .ordinaryForwarding,
                releasedBy: { release -> String in
                    await pendingClose.store(release)
                    throw TransportError.timedOut
                })
        }
        #expect(await admission.snapshot().connection == 0)
    }
}

private actor ChannelAdmissionGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilOpen() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let parked = waiters
        waiters.removeAll()
        for waiter in parked {
            waiter.resume()
        }
    }
}

private actor PendingChannelRelease {
    private var release: (@Sendable () async -> Void)?

    func store(_ release: @escaping @Sendable () async -> Void) {
        self.release = release
    }

    func run() async {
        await release?()
    }
}
