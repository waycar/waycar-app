import Foundation
import Synchronization
import Testing

@testable import Waycar

/// `EventsSession.updateSubscriptions` (#8): pane-scoped subscriptions come
/// and go with panes, so a live session must be able to swap its set without
/// tearing the SSH connection down or paying reconnect backoff.
@Suite("EventsSession subscription updates", .timeLimit(.minutes(1)))
struct EventsSessionSubscriptionsTests {
    private let initial: [EventSubscription] = [.global(.paneAgentDetected)]
    private let updated: [EventSubscription] = [
        .global(.paneAgentDetected),
        .pane(.agentStatusChanged, paneID: "w1:p1"),
    ]

    private func makeSession(
        transport: ScriptedTransport,
        reconnectPolicy: ReconnectPolicy = ReconnectPolicy(
            initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50))
    ) -> EventsSession {
        EventsSession(
            subscriptions: initial,
            connect: { transport },
            reconnectPolicy: reconnectPolicy,
            keepalive: nil)
    }

    /// A backoff no test waits out: what follows a `.reconnecting` stays put
    /// until the test cuts it short or ends the session.
    private let parkedPolicy = ReconnectPolicy(
        initialDelay: .seconds(3600), multiplier: 1, maxDelay: .seconds(3600))

    @Test func distinctTerminalsRunTogetherAndSixthWaitsForTeardown() async throws {
        let transport = ScriptedTransport()
        let session = makeSession(transport: transport)
        let gate = ScriptedTransportCallGate()
        let sixthGate = ScriptedTransportCallGate()
        await session.resume()
        let tasks = (1...5).map { index in
            Task {
                try await session.withTerminalTransport(target: .terminal("terminal-\(index)")) { _, _ in
                    await gate.waitUntilOpen()
                }
            }
        }
        try await waitUntil("five distinct terminals should hold permits concurrently") {
            await gate.entryCount == 5
        }
        let sixth = Task {
            try await session.withTerminalTransport(target: .terminal("sixth")) { _, _ in
                await sixthGate.waitUntilOpen()
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await sixthGate.entryCount == 0)
        await gate.open()
        await sixthGate.waitForEntry()
        await sixthGate.open()
        for task in tasks { try await task.value }
        try await sixth.value
        await session.end()
    }

    @Test func duplicateTargetWaitsAndCancellationDoesNotConsumeItsPermit() async throws {
        let transport = ScriptedTransport()
        let session = makeSession(transport: transport)
        let gate = ScriptedTransportCallGate()
        let target = TerminalAttachTarget.terminal("same")
        await session.resume()
        let first = Task {
            try await session.withTerminalTransport(target: target) { _, _ in
                await gate.waitUntilOpen()
            }
        }
        await gate.waitForEntry()
        let duplicate = Task {
            try await session.withTerminalTransport(target: target) { _, _ in
                Issue.record("duplicate target entered before its owner ended")
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        duplicate.cancel()
        await #expect(throws: CancellationError.self) { try await duplicate.value }
        await gate.open()
        try await first.value
        try await session.withTerminalTransport(target: target) { _, _ in }
        await session.end()
    }

    @Test func anUpdateDuringOrdinarySubscribeInstallsTheLatestSet() async throws {
        let transport = ScriptedTransport()
        let gate = ScriptedTransportCallGate()
        await transport.gateNextSubscription(using: gate)
        let session = makeSession(transport: transport)
        var updates = session.updates.makeAsyncIterator()
        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        await gate.waitForEntry()
        await session.updateSubscriptions(updated)
        await gate.open()
        #expect(await updates.next() == .status(.connected))
        #expect(await transport.capturedSubscriptions == [initial, updated])
        await session.end()
    }

    @Test func liveUpdateResubscribesOnTheSameConnectionWithoutReconnecting() async throws {
        let transport = ScriptedTransport()
        let session = makeSession(transport: transport)
        var updates = session.updates.makeAsyncIterator()

        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))
        #expect(await session.transportGeneration == 0)

        await session.updateSubscriptions(updated)

        // A fresh `.connected` follows with no `.reconnecting` in between:
        // the teardown was deliberate, not a failure.
        #expect(await updates.next() == .status(.connected))
        #expect(await session.transportGeneration == 0)
        #expect(await transport.capturedSubscriptions == [initial, updated])
        #expect(await !transport.isClosed, "resubscribe must reuse the SSH connection")

        // The new pane subscription is live: events flow on the new stream.
        let emitted = await transport.emit(
            .agentStatusChanged(paneID: "w1:p1", status: .blocked))
        #expect(emitted)
        #expect(
            await updates.next()
                == .event(.agentStatusChanged(paneID: "w1:p1", status: .blocked)))

        await session.end()
    }

    @Test func reconnectDropsProtocolDependentSubscriptionUntilFreshSnapshot() async throws {
        let first = ScriptedTransport()
        let replacement = ScriptedTransport()
        let connector = SequencedTransportConnector([first, replacement])
        let session = EventsSession(subscriptions: initial, connect: { try await connector.connect() }, keepalive: nil)
        var updates = session.updates.makeAsyncIterator()
        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))
        await session.updateSubscriptions(updated + [.global(.workspaceReordered)])
        #expect(await updates.next() == .status(.connected))
        #expect(await first.capturedSubscriptions.last == updated + [.global(.workspaceReordered)])
        await session.suspend()
        #expect(await updates.next() == .status(.suspended))
        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))
        #expect(await replacement.capturedSubscriptions == [initial])
        await session.end()
    }

    @Test func successfulConnectPingPublishesRoundTripLatency() async throws {
        let transport = ScriptedTransport()
        let session = makeSession(transport: transport)
        var updates = session.updates.makeAsyncIterator()
        var latencyUpdates = session.latencyUpdates.makeAsyncIterator()

        await session.resume()

        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))
        let latency = await latencyUpdates.next()
        #expect(latency != nil)
        if let latency {
            #expect(latency >= .zero)
        }

        await session.end()
    }

    @Test func terminalStartsBeforeEventSubscriptionIsReady() async throws {
        let first = ScriptedTransport(snapshot: .fixture())
        let replacement = ScriptedTransport(snapshot: .fixture())
        let firstSnapshotGate = ScriptedTransportCallGate()
        let subscriptionGate = ScriptedTransportCallGate()
        let attachGate = ScriptedTransportCallGate()
        await first.gateNextSnapshot(using: firstSnapshotGate)
        await replacement.gateNextSubscription(using: subscriptionGate)
        await replacement.gateNextAttach(using: attachGate)
        let connector = SequencedTransportConnector([first, replacement])
        let session = EventsSession(
            subscriptions: initial,
            connect: { try await connector.connect() },
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50)),
            keepalive: nil)
        let (projection, generationBarrier) = await MainActor.run {
            let barrier = ProjectionGenerationBarrier()
            let projection = HostConsoleProjection(
                host: .fixture(),
                session: session,
                snapshotRetryDelay: .milliseconds(10)
            ) { [barrier] in
                barrier.record()
            }
            barrier.projection = projection
            return (projection, barrier)
        }
        await MainActor.run { projection.start(isActive: true) }
        await firstSnapshotGate.waitForEntry()
        let snapshotsBeforeRecovery = await first.snapshotFetchCount
        await firstSnapshotGate.open()
        await projection.suspend()

        let terminal = Task { @MainActor in
            try await projection.terminalRunner()(
                Self.attachRequest,
                TerminalSessionHandler { attached in
                    await attached.end()
                })
        }
        await projection.resume()
        await subscriptionGate.waitForEntry()
        await attachGate.waitForEntry()
        await generationBarrier.wait(for: 1)

        #expect(await replacement.attachRequests == [Self.attachRequest])
        #expect(await replacement.snapshotFetchCount == 0)
        #expect(await first.snapshotFetchCount == snapshotsBeforeRecovery)
        #expect(await MainActor.run { projection.transportGeneration == 1 })
        await attachGate.open()
        try await terminal.value

        await subscriptionGate.open()
        await MainActor.run { projection.end() }
    }

    @Test func terminalStartsWhileProjectionSnapshotIsStillGated() async throws {
        let transport = ScriptedTransport(snapshot: .fixture())
        let snapshotGate = ScriptedTransportCallGate()
        let attachGate = ScriptedTransportCallGate()
        await transport.gateNextSnapshot(using: snapshotGate)
        await transport.gateNextAttach(using: attachGate)
        let session = makeSession(transport: transport)
        let projection = await MainActor.run {
            HostConsoleProjection(
                host: .fixture(),
                session: session,
                snapshotRetryDelay: .milliseconds(10)
            ) {}
        }
        await MainActor.run { projection.start(isActive: true) }

        await snapshotGate.waitForEntry()
        let terminal = Task { @MainActor in
            try await projection.terminalRunner()(
                Self.attachRequest,
                TerminalSessionHandler { attached in
                    await attached.end()
                })
        }
        await attachGate.waitForEntry()

        #expect(await transport.attachRequests == [Self.attachRequest])
        #expect(await snapshotGate.entryCount == 1)
        await attachGate.open()
        try await terminal.value

        await snapshotGate.open()
        await MainActor.run { projection.end() }
    }

    /// Attach first (#105): a terminal waiting for the Host's connection
    /// attaches as soon as the connection is authenticated and its socket
    /// path known — before its `ping` answers, and so before the events
    /// subscribe that waits for that answer.
    @Test func terminalAttachesOnTheNewTransportBeforeItsPingAnswers() async throws {
        let transport = ScriptedTransport()
        let pingGate = ScriptedTransportCallGate()
        let subscriptionGate = ScriptedTransportCallGate()
        let attachSessionGate = ScriptedTransportCallGate()
        await transport.gateNextPing(using: pingGate)
        await transport.gateNextSubscription(using: subscriptionGate)
        await transport.gateNextAttachSession(using: attachSessionGate)
        let (registrations, registrationContinuation) = AsyncStream.makeStream(of: Void.self)
        var registrationIterator = registrations.makeAsyncIterator()
        let session = EventsSession(
            subscriptions: initial,
            connect: { transport },
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50)),
            keepalive: nil,
            terminalWaiterDidRegister: { registrationContinuation.yield() })
        let projection = await MainActor.run {
            HostConsoleProjection(
                host: .fixture(),
                session: session,
                snapshotRetryDelay: .milliseconds(10)
            ) {}
        }
        let terminal = await MainActor.run {
            AttachTerminalStore(
                target: "w1:p1",
                takeover: true,
                transportGeneration: 0,
                runTerminal: projection.terminalRunner())
        }
        await MainActor.run { terminal.viewDidResize(cols: 80, rows: 24) }
        _ = await registrationIterator.next()
        #expect(await transport.attachRequests.isEmpty)
        #expect(await MainActor.run { terminal.status == .connecting })

        await session.resume()
        await pingGate.waitForEntry()
        await attachSessionGate.waitForEntry()

        #expect(await transport.attachRequests == [Self.attachRequest])
        #expect(await transport.pingCount == 1)
        #expect(await subscriptionGate.entryCount == 0)
        #expect(await MainActor.run { terminal.status == .connecting })
        await attachSessionGate.open()
        #expect(await transport.emitAttachOutput(Data("ready".utf8)))
        await terminal.stop()
        #expect(await MainActor.run { terminal.status == .stopped })

        await pingGate.open()
        await subscriptionGate.waitForEntry()
        await subscriptionGate.open()
        await MainActor.run { projection.end() }
        registrationContinuation.finish()
    }

    @Test func cancellationRemovesAReadinessWaiterAndReleasesTheTerminalPermit() async throws {
        let transport = ScriptedTransport()
        let subscriptionGate = ScriptedTransportCallGate()
        let attachGate = ScriptedTransportCallGate()
        await transport.gateNextSubscription(using: subscriptionGate)
        await transport.gateNextAttach(using: attachGate)
        let (registrations, registrationContinuation) = AsyncStream.makeStream(of: Void.self)
        var registrationIterator = registrations.makeAsyncIterator()
        let session = EventsSession(
            subscriptions: initial,
            connect: { transport },
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50)),
            keepalive: nil,
            terminalWaiterDidRegister: { registrationContinuation.yield() })
        let cancelled = Task {
            try await session.withTerminalTransport { _, _ in
                Issue.record("a cancelled readiness waiter reached its operation")
            }
        }

        _ = await registrationIterator.next()
        cancelled.cancel()
        await #expect(throws: CancellationError.self) {
            try await cancelled.value
        }

        await session.resume()
        await subscriptionGate.waitForEntry()
        let replacement = Task {
            try await session.withTerminalTransport { transport, generation in
                let attached = try await transport.attachTerminal(Self.attachRequest)
                await attached.end()
                return generation
            }
        }
        await attachGate.waitForEntry()
        await attachGate.open()
        #expect(try await replacement.value == 0)
        #expect(await transport.attachRequests == [Self.attachRequest])

        await subscriptionGate.open()
        await session.end()
        registrationContinuation.finish()
    }

    @Test func aRequestAfterConnectionFailureReceivesTheRealFailure() async throws {
        let transport = ScriptedTransport()
        let failure = TransportError.socketNotFound(path: "/remote/herdr.sock")
        await transport.failPing(atCall: 1, with: failure)
        let session = makeSession(transport: transport)
        var updates = session.updates.makeAsyncIterator()

        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.failed(failure)))

        do {
            try await session.withTerminalTransport { _, _ in
                Issue.record("a failed session handed out a terminal Transport")
            }
        } catch let error as TransportError {
            #expect(error == failure)
        } catch {
            Issue.record("expected \(failure), got \(error)")
        }

        await session.end()
    }

    // MARK: Silent transport replacement

    @Test func aSubscribeOnADistrustedTransportCannotBecomeLive() async throws {
        let first = ScriptedTransport()
        let replacement = ScriptedTransport()
        let connector = SequencedTransportConnector([first, replacement])
        let session = EventsSession(
            subscriptions: initial, connect: { try await connector.connect() }, keepalive: nil)
        var updates = session.updates.makeAsyncIterator()
        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))
        let gate = ScriptedTransportCallGate()
        await first.gateNextSubscription(using: gate)
        await session.updateSubscriptions(updated)
        await gate.waitForEntry()
        let (distrusted, continuation) = AsyncStream.makeStream(of: Void.self)
        var distrust = distrusted.makeAsyncIterator()
        await first.setOnDistrusted { continuation.yield() }
        let request = Task {
            try await session.withTransport { transport in
                if (transport as? ScriptedTransport) === first { throw TransportError.timedOut }
                return (transport as? ScriptedTransport) === replacement
            }
        }
        _ = await distrust.next()
        await gate.open()
        #expect(await updates.next() == .status(.connected))
        #expect(await connector.connectCount == 2)
        if await connector.connectCount == 2 {
            #expect(try await request.value)
        } else {
            request.cancel()
            _ = await request.result
        }
        continuation.finish()
        await session.end()
    }

    /// A subscription reinstall that finds the connection degraded replaces
    /// the Transport without announcing anything: the status stays
    /// `.connected` for the whole redial. The fresh-agent flow lands its
    /// first `agent.prompt` inside exactly that window — the launch's new
    /// pane forces the reinstall — and the send used to fail with
    /// `sshUnreachable` while every surface claimed the Host was connected.
    /// A caller now waits for the replacement Transport instead.
    @Test func aRequestWaitsOutTheSilentTransportReplacement() async throws {
        let first = ScriptedTransport(
            serverInfo: ServerInfo(version: "first", protocolVersion: 17))
        let replacement = ScriptedTransport(
            serverInfo: ServerInfo(version: "replacement", protocolVersion: 17))
        let connector = SequencedTransportConnector([first, replacement])
        let connectGate = ScriptedTransportCallGate()
        let session = EventsSession(
            subscriptions: initial,
            connect: {
                let transport = try await connector.connect()
                let dial = await connector.connectCount
                if dial > 1 {
                    await connectGate.waitUntilOpen()
                }
                return transport
            },
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50)),
            keepalive: nil)
        var updates = session.updates.makeAsyncIterator()

        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))

        // The degraded link the events reader has not reported yet: the
        // reinstall's transport check must replace it, silently.
        await first.setConnectionAlive(false)
        await session.updateSubscriptions(updated)

        let probe = Task {
            try await session.withTransport { transport in
                try await transport.ping().version
            }
        }
        // Hold the dial closed long enough that the old fail-fast behavior
        // would already have thrown.
        try await Task.sleep(for: .milliseconds(50))
        await connectGate.open()
        #expect(try await probe.value == "replacement")
        // The deliberate replacement never announced a failure or a new
        // activation; the fresh `.connected` is its only signal. It also
        // orders the check below: the probe's RPC is served once the
        // replacement is installed, before its events subscribe lands.
        #expect(await updates.next() == .status(.connected))
        // A fresh transport sees exactly one `events.subscribe`, with the
        // CURRENT set: the `[initial]` capture belongs to `first`, the
        // transport that was replaced. Same contract as the suspend/resume
        // replacement above (`replacement.capturedSubscriptions == [initial]`)
        // — accumulating `[initial, updated]` is the same-transport
        // resubscribe case, not a fresh dial.
        #expect(await replacement.capturedSubscriptions == [updated])
        #expect(await session.transportGeneration == 1)

        await session.end()
    }

    /// The same window, when the replacement dial fails: the waiter must be
    /// released with that real cause at the `.reconnecting` announcement
    /// instead of waiting through the backoff.
    @Test func aRequestWaitingThroughAReplacementFailsWithTheReconnectCause() async throws {
        let first = ScriptedTransport()
        let connector = SequencedTransportConnector([first])
        let session = EventsSession(
            subscriptions: initial,
            connect: {
                let transport = try await connector.connect()
                let dial = await connector.connectCount
                if dial > 1 {
                    throw TransportError.timedOut
                }
                return transport
            },
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50)),
            keepalive: nil)
        var updates = session.updates.makeAsyncIterator()

        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))

        await first.setConnectionAlive(false)
        await session.updateSubscriptions(updated)
        // The run loop must have cleared the dead transport and failed its
        // first dial before the caller arrives, so the caller parks as a
        // transport waiter instead of being handed the stale transport.
        try await Task.sleep(for: .milliseconds(50))

        let probe = Task {
            try await session.withTransport { _ in
                "delivered"
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        await #expect(throws: TransportError.timedOut) { try await probe.value }

        // The release rode the honest `.reconnecting` announcement.
        #expect(
            await updates.next()
                == .status(.reconnecting(
                    attempt: 1,
                    delay: .milliseconds(10),
                    failure: .timedOut)))

        await session.suspend()
        await session.end()
    }

    /// The other half of the degraded-link story: the events reader has not
    /// noticed the dead link yet, so a caller still receives the installed
    /// transport and its operation fails on it. withTransport marks the
    /// transport suspect, lets the run loop redial, and retries once on the
    /// replacement instead of surfacing a phantom unreachable Host.
    @Test func aSendFailedOnADeadTransportRetriesOnTheReplacement() async throws {
        let first = ScriptedTransport(
            serverInfo: ServerInfo(version: "first", protocolVersion: 17))
        let replacement = ScriptedTransport(
            serverInfo: ServerInfo(version: "replacement", protocolVersion: 17))
        let connector = SequencedTransportConnector([first, replacement])
        let connectGate = ScriptedTransportCallGate()
        let session = EventsSession(
            subscriptions: initial,
            connect: {
                let transport = try await connector.connect()
                let dial = await connector.connectCount
                if dial > 1 {
                    await connectGate.waitUntilOpen()
                }
                return transport
            },
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50)),
            keepalive: nil)
        var updates = session.updates.makeAsyncIterator()

        await session.resume()
        // `resume()` returns with the activation underway, not with `first`
        // installed. Killing the link any earlier lets the run loop's own
        // connect ping hit it: the probe is then either released with that
        // reconnect's cause or handed the replacement outright, and never
        // reaches the retry this test is about.
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))

        // The degraded link its events reader has not reported yet.
        await first.setConnectionAlive(false)

        let probe = Task {
            try await session.withTransport { transport in
                try await transport.ping().version
            }
        }
        // With no keepalive and no subscription change, only the failed
        // first attempt can end `first`'s stream, so the redial reaching the
        // closed gate proves the call failed on `first` and handed the
        // connection back to the run loop. The retry cannot find anything
        // installed until the gate opens.
        try await waitUntil("the failed call should force a redial") {
            await connectGate.entryCount == 1
        }
        await connectGate.open()
        #expect(try await probe.value == "replacement")
        // The replacement was silent: no `.reconnecting` before its `.connected`.
        #expect(await updates.next() == .status(.connected))

        await session.end()
    }

    /// The distrusted transport is dropped without `close()` (Terminals may
    /// still use it), so it is told once, and gives up what its replacement
    /// on the same connection needs: here the one tmux control slot, which
    /// the replacement's dial must take within its deadline.
    @Test func aDistrustedTransportIsToldOnceAndFreesItsReplacementsSlot() async throws {
        let first = ScriptedTransport(
            serverInfo: ServerInfo(version: "first", protocolVersion: 17))
        let replacement = ScriptedTransport(
            serverInfo: ServerInfo(version: "replacement", protocolVersion: 17))
        let connector = SequencedTransportConnector([first, replacement])
        let admission = SSHChannelAdmission()
        let firstSlot = try await admission.acquire(.control)
        await first.setOnDistrusted { await firstSlot.release() }
        let session = EventsSession(
            subscriptions: initial,
            connect: {
                let transport = try await connector.connect()
                if await connector.connectCount > 1 {
                    let slot = try await admission.acquire(.control, within: .waitCeiling)
                    await slot.release()
                }
                return transport
            },
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50)),
            keepalive: nil)
        var updates = session.updates.makeAsyncIterator()

        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))

        await first.setConnectionAlive(false)
        let version = try await session.withTransport { transport in
            try await transport.ping().version
        }

        #expect(version == "replacement")
        #expect(await first.distrustCount == 1)
        #expect(await !first.isClosed)
        #expect(await replacement.distrustCount == 0)

        await session.end()
    }

    /// A link failure cannot say whether herdr already received the request.
    /// An idempotent call still rides the one retry, but input that submits
    /// is never replayed — the shell may already have run the command — so
    /// the failure surfaces for a deliberate resend instead.
    @Test func aSubmittingPaneInputIsNeverReplayedAfterALinkFailure() async throws {
        let first = ScriptedTransport()
        let second = ScriptedTransport()
        let third = ScriptedTransport()
        let connector = SequencedTransportConnector([first, second, third])
        let session = EventsSession(
            subscriptions: initial,
            connect: { try await connector.connect() },
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50)),
            keepalive: nil)
        var updates = session.updates.makeAsyncIterator()
        await session.resume()
        // Live stream installed: the failed call can end it to force the redial.
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))

        // Typing without Enter is safe to replay: the swallowed first
        // attempt is retried once on the replacement.
        let typed = PaneSendInputParams(paneID: "w1:p1", text: "git st")
        #expect(!typed.submitsInput)
        await first.setConnectionAlive(false)
        await first.failPaneInput(
            atCall: 1, with: .sshUnreachable(detail: "dead link"))
        try await session.withTransport(retryOnLinkFailure: !typed.submitsInput) {
            try await $0.sendPaneInput(typed)
        }
        #expect(await first.paneInputParams == [typed])
        #expect(await second.paneInputParams == [typed])

        // The same failure on a submitting send: herdr may have run it, so
        // it is attempted exactly once and the failure propagates.
        let submit = PaneSendInputParams(paneID: "w1:p1", keys: ["enter"], text: "git push")
        #expect(submit.submitsInput)
        await second.setConnectionAlive(false)
        await second.failPaneInput(atCall: 2, with: .timedOut)
        await #expect(throws: TransportError.timedOut) {
            try await session.withTransport(retryOnLinkFailure: !submit.submitsInput) {
                try await $0.sendPaneInput(submit)
            }
        }
        #expect(await second.paneInputParams == [typed, submit])
        #expect(await third.paneInputParams.isEmpty)

        await session.end()
    }

    // MARK: Request recovery (HERDR-05)

    private func connectedSession(
        _ transports: [ScriptedTransport]
    ) -> (EventsSession, SequencedTransportConnector) {
        let connector = SequencedTransportConnector(transports)
        let session = EventsSession(
            subscriptions: initial, connect: { try await connector.connect() },
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50)),
            keepalive: nil)
        return (session, connector)
    }

    /// A server's answer says the link works: it is thrown as it is, never
    /// replayed, and the connection stays trusted and live.
    @Test func aServerAnswerIsNeitherReplayedNorDistrustsTheConnection() async throws {
        let transport = ScriptedTransport()
        let (session, connector) = connectedSession([transport])
        var updates = session.updates.makeAsyncIterator()
        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))

        let calls = DialCount()
        let rejection = TransportError.apiRejected(code: "agent_not_found", message: "gone")
        await #expect(throws: rejection) {
            try await session.withTransport { _ in
                _ = calls.next()
                throw rejection
            }
        }
        #expect(calls.value == 1)
        #expect(await transport.distrustCount == 0)
        #expect(await transport.emit(.agentStatusChanged(paneID: "w1:p1", status: .blocked)))
        #expect(
            await updates.next()
                == .event(.agentStatusChanged(paneID: "w1:p1", status: .blocked)))
        #expect(await connector.connectCount == 1)
        await session.end()
    }

    /// One replay only: a replay that fails on the link too reports its own
    /// failure, is not replayed again, and leaves the replacement trusted.
    @Test func aRequestIsReplayedOnceAndAFailedReplayReportsItsOwnFailure() async throws {
        let first = ScriptedTransport()
        let second = ScriptedTransport()
        let (session, connector) = connectedSession([first, second])
        var updates = session.updates.makeAsyncIterator()
        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))

        let calls = DialCount()
        await #expect(throws: TransportError.sshUnreachable(detail: "still dead")) {
            try await session.withTransport { transport in
                _ = calls.next()
                if (transport as? ScriptedTransport) === first {
                    throw TransportError.sshUnreachable(detail: "dead link")
                }
                throw TransportError.sshUnreachable(detail: "still dead")
            }
        }
        #expect(calls.value == 2)
        // Told on a detached Task, as the replacement dials.
        try await waitUntil("the dead Transport should be told it is distrusted") {
            await first.distrustCount == 1
        }
        #expect(await second.distrustCount == 0)
        #expect(await connector.connectCount == 2)
        await session.end()
    }

    /// A replay that runs out its own time reports the first failure, not
    /// a second wait's.
    @Test func aReplayThatTimesOutReportsTheFirstFailure() async throws {
        let first = ScriptedTransport()
        let second = ScriptedTransport()
        let (session, _) = connectedSession([first, second])
        var updates = session.updates.makeAsyncIterator()
        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))

        let calls = DialCount()
        await #expect(throws: TransportError.sshUnreachable(detail: "dead link")) {
            try await session.withTransport { transport in
                _ = calls.next()
                if (transport as? ScriptedTransport) === first {
                    throw TransportError.sshUnreachable(detail: "dead link")
                }
                throw TransportError.timedOut
            }
        }
        #expect(calls.value == 2)
        #expect(await second.distrustCount == 0)
        await session.end()
    }

    /// A link failure the Transport marked unsent is a link failure all the
    /// same: the connection is distrusted and the request replayed.
    @Test func anUnsentRequestIsReplayedLikeABareLinkFailure() async throws {
        let first = ScriptedTransport()
        let second = ScriptedTransport()
        let (session, _) = connectedSession([first, second])
        var updates = session.updates.makeAsyncIterator()
        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))

        let answer = try await session.withTransport { transport -> String in
            if (transport as? ScriptedTransport) === first {
                throw RequestNotSentError(
                    cause: TransportError.sshUnreachable(detail: "never written"))
            }
            return "second"
        }
        #expect(answer == "second")
        try await waitUntil("the dead Transport should be told it is distrusted") {
            await first.distrustCount == 1
        }
        await session.end()
    }

    /// A link failure on a Transport the run loop already replaced retries
    /// on the replacement without distrusting it.
    @Test func aLinkFailureOnAReplacedTransportRetriesWithoutDistrustingTheReplacement()
        async throws
    {
        let first = ScriptedTransport()
        let second = ScriptedTransport()
        let (session, connector) = connectedSession([first, second])
        var updates = session.updates.makeAsyncIterator()
        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))

        let gate = ScriptedTransportCallGate()
        let request = Task {
            try await session.withTransport { transport -> String in
                if (transport as? ScriptedTransport) === first {
                    await gate.waitUntilOpen()
                    throw TransportError.sshUnreachable(detail: "dead link")
                }
                return "second"
            }
        }
        await gate.waitForEntry()
        await first.setConnectionAlive(false)
        await first.failEventStream(.channelFailed(detail: "remote closed"))
        guard case .status(.reconnecting) = await updates.next() else {
            Issue.record("the dropped stream should reconnect")
            await gate.open()
            _ = await request.result
            await session.end()
            return
        }
        #expect(await updates.next() == .status(.connected))
        #expect(await connector.connectCount == 2)
        await gate.open()

        #expect(try await request.value == "second")
        #expect(await first.distrustCount == 0)
        #expect(await second.distrustCount == 0)
        await session.end()
    }

    /// Parity with `withTerminalTransport`: after the run loop stopped on an
    /// action-required failure, a Host-scoped RPC reports that cause instead
    /// of a generic unreachable Host.
    @Test func aRequestAfterConnectionFailureReceivesTheRealFailureToo() async throws {
        let transport = ScriptedTransport()
        let failure = TransportError.socketNotFound(path: "/remote/herdr.sock")
        await transport.failPing(atCall: 1, with: failure)
        let session = makeSession(transport: transport)
        var updates = session.updates.makeAsyncIterator()

        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.failed(failure)))

        do {
            try await session.withTransport { _ in
                Issue.record("a failed session handed out a Transport")
            }
        } catch let error as TransportError {
            #expect(error == failure)
        } catch {
            Issue.record("expected \(failure), got \(error)")
        }

        await session.end()
    }

    /// A suspended session has no run loop to install anything: the honest
    /// unreachable failure stays immediate.
    @Test func aRequestOnASuspendedSessionFailsAtOnceWithoutWaiting() async throws {
        let transport = ScriptedTransport()
        let session = makeSession(transport: transport)
        var updates = session.updates.makeAsyncIterator()

        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))

        await session.suspend()
        #expect(await updates.next() == .status(.suspended))

        await #expect(throws: TransportError.sshUnreachable(detail: "The Host is not connected.")) {
            try await session.withTransport { _ in
                Issue.record("a suspended session handed out a Transport")
            }
        }

        await session.end()
    }

    /// A terminal waiting on one activation's connection is cancelled by
    /// the next activation, never handed its connection. Terminals ride a
    /// connection from its dial on (attach first, #105), so the wait being
    /// invalidated is the one before the old activation's dial completes.
    @Test func aNewActivationInvalidatesTheOldReadinessWaiter() async throws {
        let first = ScriptedTransport()
        let second = ScriptedTransport()
        let firstDialGate = ScriptedTransportCallGate()
        let secondSubscriptionGate = ScriptedTransportCallGate()
        let secondAttachGate = ScriptedTransportCallGate()
        await second.gateNextSubscription(using: secondSubscriptionGate)
        await second.gateNextAttach(using: secondAttachGate)
        let connector = SequencedTransportConnector([first, second])
        let (registrations, registrationContinuation) = AsyncStream.makeStream(of: Void.self)
        var registrationIterator = registrations.makeAsyncIterator()
        let session = EventsSession(
            subscriptions: initial,
            connect: {
                let transport = try await connector.connect()
                // The first activation's dial hangs until the test ends.
                if (transport as? ScriptedTransport) === first {
                    await firstDialGate.waitUntilOpen()
                }
                return transport
            },
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50)),
            keepalive: nil,
            terminalWaiterDidRegister: { registrationContinuation.yield() })

        await session.resume()
        await firstDialGate.waitForEntry()
        let stale = Task {
            try await session.withTerminalTransport { transport, _ in
                _ = try await transport.attachTerminal(Self.attachRequest)
                Issue.record("an older activation handed out its Transport")
            }
        }
        _ = await registrationIterator.next()

        await session.retry()
        await #expect(throws: TransportError.cancelled) {
            try await stale.value
        }
        await secondSubscriptionGate.waitForEntry()

        let current = Task {
            try await session.withTerminalTransport { transport, generation in
                let attached = try await transport.attachTerminal(Self.attachRequest)
                await attached.end()
                return generation
            }
        }
        await secondAttachGate.waitForEntry()
        await secondAttachGate.open()
        #expect(try await current.value == 0)
        #expect(await first.attachRequests.isEmpty)
        #expect(await second.attachRequests == [Self.attachRequest])

        await firstDialGate.open()
        await secondSubscriptionGate.open()
        await session.end()
        registrationContinuation.finish()
    }

    @Test func unchangedSetIsANoOp() async throws {
        let transport = ScriptedTransport()
        let session = makeSession(transport: transport)
        var updates = session.updates.makeAsyncIterator()

        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))

        await session.updateSubscriptions(initial)

        #expect(await transport.capturedSubscriptions == [initial])
        await session.end()
    }

    @Test func aDistrustDuringConnectionCheckRedialsWithoutReconnecting() async throws {
        let first = ScriptedTransport()
        let replacement = ScriptedTransport()
        let connector = SequencedTransportConnector([first, replacement])
        let session = EventsSession(
            subscriptions: initial, connect: { try await connector.connect() }, keepalive: nil)
        var updates = session.updates.makeAsyncIterator()
        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))
        let gate = ScriptedTransportCallGate()
        await first.gateNextConnectionCheck(using: gate)
        await session.updateSubscriptions(updated)
        await gate.waitForEntry()
        let (distrusted, continuation) = AsyncStream.makeStream(of: Void.self)
        var distrust = distrusted.makeAsyncIterator()
        await first.setOnDistrusted { continuation.yield() }
        let request = Task {
            try await session.withTransport { transport in
                if (transport as? ScriptedTransport) === first { throw TransportError.timedOut }
                return (transport as? ScriptedTransport) === replacement
            }
        }
        _ = await distrust.next()
        await first.setConnectionAlive(false)
        await gate.open()
        let next = await updates.next()
        #expect(next == .status(.connected))
        if next == .status(.connected) {
            #expect(try await request.value)
        } else {
            request.cancel()
            _ = await request.result
        }
        await session.end()
        continuation.finish()
    }

    @Test func anOldConnectionCheckCannotClearANewerActivationsTransport() async throws {
        let first = ScriptedTransport()
        let replacement = ScriptedTransport()
        let connector = SequencedTransportConnector([first, replacement])
        let (outcomes, continuation) = AsyncStream.makeStream(of: Bool.self)
        var outcome = outcomes.makeAsyncIterator()
        let session = EventsSession(
            subscriptions: initial, connect: { try await connector.connect() }, keepalive: nil,
            terminalWaiterDidRegister: { continuation.yield(false) })
        var updates = session.updates.makeAsyncIterator()
        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))
        let oldRun = try #require(await session.runTaskForTesting)
        let gate = ScriptedTransportCallGate()
        await first.gateNextConnectionCheck(using: gate)
        await session.updateSubscriptions(updated)
        await gate.waitForEntry()
        await first.setConnectionAlive(false)
        await session.suspend(locally: true)
        #expect(await updates.next() == .status(.suspended))
        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))
        await gate.open()
        await oldRun.value

        // Registration means the newer transport was lost; a successful
        // operation means it is still installed. Neither outcome needs a timeout.
        let terminal = Task {
            try await session.withTerminalTransport { transport, _ in
                continuation.yield((transport as? ScriptedTransport) === replacement)
            }
        }
        let installed = await outcome.next()
        #expect(installed == true)
        terminal.cancel()
        _ = await terminal.result
        if installed == true {
            #expect(try await session.withTransport { ($0 as? ScriptedTransport) === replacement })
        }
        #expect(await connector.connectCount == 2)
        await session.end()
        continuation.finish()
    }

    private static let attachRequest = TerminalAttachRequest(
        target: "w1:p1", takeover: true, cols: 80, rows: 24)

    // MARK: Subscription lifecycle (HERDR-03)

    /// An early subscribe (#105) whose set changed while it was in flight is
    /// ended and replaced on the same connection: no second dial, and no
    /// status between the activation's `.connecting` and `.connected`.
    @Test func anEarlySubscribeOvertakenByAnUpdateIsReplacedOnTheSameConnection() async throws {
        let transport = ScriptedTransport(
            serverInfo: ServerInfo(version: "0.9.3", protocolVersion: 22))
        let gate = ScriptedTransportCallGate()
        await transport.gateNextSubscription(using: gate)
        let connector = SequencedTransportConnector([transport])
        let session = EventsSession(
            subscriptions: initial,
            connect: { try await connector.connect() },
            reconnectPolicy: parkedPolicy,
            keepalive: nil,
            connectionMemory: RememberedFacts(protocolVersion: 19))
        var updates = session.updates.makeAsyncIterator()

        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        await gate.waitForEntry()
        await session.updateSubscriptions(updated)
        await gate.open()

        #expect(await updates.next() == .status(.connected))
        #expect(await transport.capturedSubscriptions == [initial, updated])
        #expect(await connector.connectCount == 1)
        await session.end()
    }

    /// The fallback from a rejected seed to the global set happens once: the
    /// global set is no seed, so its own rejection is reported like any other.
    @Test func aRejectedSeedFallsBackOnceAndARejectedFallbackReconnectsVisibly() async throws {
        let transport = ScriptedTransport()
        await transport.rejectSubscribes(
            containing: .global(.paneAgentDetected), code: "invalid_params")
        let session = makeSession(transport: transport, reconnectPolicy: parkedPolicy)
        var updates = session.updates.makeAsyncIterator()

        await session.resume(seeding: updated)
        #expect(await updates.next() == .status(.connecting))
        let next = await updates.next()
        guard case .status(.reconnecting(1, _, .apiRejected(code: "invalid_params", _))) = next
        else {
            Issue.record("expected a visible reconnect, got \(String(describing: next))")
            await session.end()
            return
        }
        #expect(await transport.capturedSubscriptions == [updated, initial])
        await session.end()
    }

    /// A rejected seed that holds only global entries has nothing to fall
    /// back to: the rejection is reported at once.
    @Test func aRejectedSeedWithNothingToDropReconnectsVisibly() async throws {
        let transport = ScriptedTransport()
        await transport.rejectSubscribes(
            containing: .global(.paneAgentDetected), code: "invalid_params")
        let session = makeSession(transport: transport, reconnectPolicy: parkedPolicy)
        var updates = session.updates.makeAsyncIterator()

        await session.resume(seeding: initial)
        #expect(await updates.next() == .status(.connecting))
        let next = await updates.next()
        guard case .status(.reconnecting(1, _, .apiRejected(code: "invalid_params", _))) = next
        else {
            Issue.record("expected a visible reconnect, got \(String(describing: next))")
            await session.end()
            return
        }
        #expect(await transport.capturedSubscriptions == [initial])
        await session.end()
    }

    /// `pane_not_found` falls back to the global set whether or not the set
    /// was a seed: a live update naming an exited pane stays Connected.
    @Test func aPaneMissingFromALiveUpdateFallsBackToTheGlobalSetSilently() async throws {
        let transport = ScriptedTransport()
        let session = makeSession(transport: transport, reconnectPolicy: parkedPolicy)
        var updates = session.updates.makeAsyncIterator()
        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))

        await transport.setMissingPanes(["w1:p1"])
        await session.updateSubscriptions(updated)

        #expect(await updates.next() == .status(.connected))
        #expect(await transport.capturedSubscriptions == [initial, updated, initial])
        #expect(await !transport.isClosed)
        await session.end()
    }

    /// An update while a seed's subscribe is in flight makes the set no seed:
    /// the seed's answer is replaced, and a rejection of the update is
    /// reported instead of falling back silently.
    @Test func anUpdateDuringASeededSubscribeEndsTheSeedsFallback() async throws {
        let transport = ScriptedTransport()
        let gate = ScriptedTransportCallGate()
        await transport.gateNextSubscription(using: gate)
        let session = makeSession(transport: transport, reconnectPolicy: parkedPolicy)
        var updates = session.updates.makeAsyncIterator()
        let seed = initial + [.pane(.agentStatusChanged, paneID: "w1:p1")]
        let replacementSet = initial + [.global(.workspaceReordered)]

        await session.resume(seeding: seed)
        #expect(await updates.next() == .status(.connecting))
        await gate.waitForEntry()
        await transport.rejectSubscribes(
            containing: .global(.workspaceReordered), code: "invalid_params")
        await session.updateSubscriptions(replacementSet)
        await gate.open()

        let next = await updates.next()
        guard case .status(.reconnecting(1, _, .apiRejected(code: "invalid_params", _))) = next
        else {
            Issue.record("expected a visible reconnect, got \(String(describing: next))")
            await session.end()
            return
        }
        #expect(await transport.capturedSubscriptions == [seed, replacementSet])
        await session.end()
    }

    /// A dial that fails retryably is a disconnect too: the pane entries go
    /// before the retry subscribes.
    @Test func aFailedDialDropsThePaneSubscriptionsBeforeTheRetry() async throws {
        let transport = ScriptedTransport()
        let dials = DialCount()
        let session = EventsSession(
            subscriptions: initial,
            connect: { () async throws -> any Transport in
                if dials.next() == 1 { throw TransportError.sshUnreachable(detail: "no route") }
                return transport
            },
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50)),
            keepalive: nil)
        var updates = session.updates.makeAsyncIterator()

        await session.updateSubscriptions(updated)
        await session.resume()

        #expect(await updates.next() == .status(.connecting))
        guard case .status(.reconnecting(1, _, .sshUnreachable)) = await updates.next() else {
            Issue.record("the failed dial should reconnect")
            await session.end()
            return
        }
        #expect(await updates.next() == .status(.connected))
        #expect(await transport.capturedSubscriptions == [initial])
        await session.end()
    }

    /// B-46 (HERDR-03): a request that finds the link dead while the run
    /// loop backs off has no live channel to replace, so it asks for no
    /// re-subscribe. The next connection's first stream loss is a loss like
    /// any other and shows `.reconnecting`.
    @Test func aRequestThatFindsTheLinkDeadDuringABackoffLeavesTheNextLossVisible() async throws {
        let first = ScriptedTransport(
            serverInfo: ServerInfo(version: "first", protocolVersion: 17))
        let second = ScriptedTransport(
            serverInfo: ServerInfo(version: "second", protocolVersion: 17))
        let connector = SequencedTransportConnector([first, second])
        let session = EventsSession(
            subscriptions: initial, connect: { try await connector.connect() },
            reconnectPolicy: parkedPolicy, keepalive: nil)
        var updates = session.updates.makeAsyncIterator()
        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))

        let lost = TransportError.channelFailed(detail: "remote closed")
        await first.failEventStream(lost)
        #expect(
            await updates.next()
                == .status(.reconnecting(attempt: 1, delay: .seconds(3600), failure: lost)))

        let (distrusted, continuation) = AsyncStream.makeStream(of: Void.self)
        var distrust = distrusted.makeAsyncIterator()
        await first.setOnDistrusted { continuation.yield() }
        let request = Task {
            try await session.withTransport { transport in
                if (transport as? ScriptedTransport) === first { throw TransportError.timedOut }
                return try await transport.ping().version
            }
        }
        _ = await distrust.next()
        await session.redialNow(trigger: .pathChange)
        #expect(await updates.next() == .status(.connected))
        #expect(try await request.value == "second")

        await second.failEventStream(lost)
        #expect(
            await updates.next()
                == .status(.reconnecting(attempt: 1, delay: .seconds(3600), failure: lost)))
        #expect(await connector.connectCount == 2)
        #expect(await second.capturedSubscriptions == [initial])
        await session.end()
        continuation.finish()
    }

    // MARK: Lifecycle (HERDR-01)

    /// A connect closure whose first dial fails with `failure`; every later
    /// one answers `transport`. `dials` counts them.
    private func failingFirstDial(
        with failure: TransportError, then transport: ScriptedTransport, dials: DialCount
    ) -> @Sendable () async throws -> any Transport {
        { () async throws -> any Transport in
            if dials.next() == 1 { throw failure }
            return transport
        }
    }

    @Test func aRetryDuringABackoffStartsANewActivationAtOnce() async throws {
        let transport = ScriptedTransport()
        let dials = DialCount()
        let unreachable = TransportError.sshUnreachable(detail: "no route")
        let session = EventsSession(
            subscriptions: initial,
            connect: failingFirstDial(with: unreachable, then: transport, dials: dials),
            reconnectPolicy: parkedPolicy, keepalive: nil)
        var updates = session.updates.makeAsyncIterator()

        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(
            await updates.next()
                == .status(.reconnecting(attempt: 1, delay: .seconds(3600), failure: unreachable)))
        await session.retry()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))
        #expect(dials.value == 2)
        await session.end()
        #expect(await updates.next() == .status(.ended))
    }

    @Test func aRetryAfterAFailureConnectsAgain() async throws {
        let transport = ScriptedTransport()
        let dials = DialCount()
        let session = EventsSession(
            subscriptions: initial,
            connect: failingFirstDial(
                with: .authenticationFailed, then: transport, dials: dials),
            reconnectPolicy: parkedPolicy, keepalive: nil)
        var updates = session.updates.makeAsyncIterator()

        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.failed(.authenticationFailed)))
        // A failed activation waits for the user: a link coming back dials
        // nothing.
        await session.redialNow(trigger: .pathChange)
        #expect(dials.value == 1)

        await session.retry()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))
        #expect(dials.value == 2)
        await session.end()
    }

    @Test func aRetryWhileSuspendedActivates() async throws {
        let transport = ScriptedTransport()
        let session = makeSession(transport: transport, reconnectPolicy: parkedPolicy)
        var updates = session.updates.makeAsyncIterator()

        await session.retry()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))
        await session.end()
    }

    @Test func aSuspensionDuringABackoffEndsItAndTheReturnConnects() async throws {
        let transport = ScriptedTransport()
        let dials = DialCount()
        let unreachable = TransportError.sshUnreachable(detail: "no route")
        let session = EventsSession(
            subscriptions: initial,
            connect: failingFirstDial(with: unreachable, then: transport, dials: dials),
            reconnectPolicy: parkedPolicy, keepalive: nil)
        var updates = session.updates.makeAsyncIterator()

        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        guard case .status(.reconnecting) = await updates.next() else {
            Issue.record("the failed dial should back off")
            await session.end()
            return
        }
        await session.suspend()
        #expect(await updates.next() == .status(.suspended))
        #expect(dials.value == 1)

        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))
        #expect(dials.value == 2)
        await session.end()
    }

    @Test func endingDuringABackoffFinishesTheUpdates() async throws {
        let transport = ScriptedTransport()
        let dials = DialCount()
        let session = EventsSession(
            subscriptions: initial,
            connect: failingFirstDial(
                with: .sshUnreachable(detail: "no route"), then: transport, dials: dials),
            reconnectPolicy: parkedPolicy, keepalive: nil)
        var updates = session.updates.makeAsyncIterator()

        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        guard case .status(.reconnecting) = await updates.next() else {
            Issue.record("the failed dial should back off")
            await session.end()
            return
        }
        await session.end()
        #expect(await updates.next() == .status(.ended))
        #expect(await updates.next() == nil)
        #expect(dials.value == 1)
    }

    @Test func aResumeWhileActiveAndAnythingAfterEndAreNoOps() async throws {
        let transport = ScriptedTransport()
        let connector = SequencedTransportConnector([transport])
        let session = EventsSession(
            subscriptions: initial, connect: { try await connector.connect() },
            reconnectPolicy: parkedPolicy, keepalive: nil)
        var updates = session.updates.makeAsyncIterator()

        // Nothing is live while suspended: a link coming back dials nothing.
        await session.redialNow(trigger: .pathChange)
        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))
        await session.resume()
        // A live channel is `revalidate()`'s business, not a redial's.
        await session.redialNow(trigger: .pathChange)
        await session.end()
        await session.end()
        await session.resume()
        await session.retry()
        #expect(await updates.next() == .status(.ended))
        #expect(await updates.next() == nil)
        #expect(await connector.connectCount == 1)
        #expect(await transport.isClosed)
    }

    @Test func updateWhileSuspendedTakesEffectOnResume() async throws {
        let transport = ScriptedTransport()
        let session = makeSession(transport: transport)
        var updates = session.updates.makeAsyncIterator()

        await session.updateSubscriptions(updated)
        await session.resume()

        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))
        #expect(await transport.capturedSubscriptions == [updated])
        await session.end()
    }

    /// A pane can exit between the snapshot that produced a subscription set
    /// and the subscribe that carries it. herdr rejects the whole request for
    /// that one entry, which used to fail the connection outright.
    @Test func aPaneThatExitedDuringSubscribeRetriesWithoutSurfacingAFailure() async throws {
        let transport = ScriptedTransport()
        await transport.setMissingPanes(["w1:p1"])
        let session = EventsSession(
            subscriptions: updated,
            connect: { transport },
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50)),
            keepalive: nil)
        var updates = session.updates.makeAsyncIterator()

        await session.resume()

        // Straight to `.connected` after the activation's `.connecting`: the
        // missing-pane retry is immediate and the user never sees a reconnect
        // for what is an ordinary race.
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))
        #expect(await transport.capturedSubscriptions == [updated, initial])
        #expect(await !transport.isClosed, "the SSH connection must survive the rejection")

        await session.end()
    }

    /// The pane set is snapshot-derived, so it cannot outlive the connection
    /// it was taken on: a pane that dies while the Host is offline would
    /// otherwise wedge every reconnect forever.
    @Test func aDroppedConnectionDiscardsThePaneSubscriptions() async throws {
        let transport = ScriptedTransport()
        let session = makeSession(transport: transport)
        var updates = session.updates.makeAsyncIterator()

        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))
        await session.updateSubscriptions(updated)
        #expect(await updates.next() == .status(.connected))

        // The pane exits while the events channel is down.
        await transport.setMissingPanes(["w1:p1"])
        await transport.failEventStream(.channelFailed(detail: "remote closed"))

        guard case .status(.reconnecting) = await updates.next() else {
            Issue.record("a dropped stream should reconnect")
            return
        }
        #expect(await updates.next() == .status(.connected))
        #expect(await transport.capturedSubscriptions == [initial, updated, initial])

        await session.end()
    }

    /// The same guarantee for the explicit Reconnect button, which winds the
    /// session down rather than reconnecting in place.
    @Test func retryAfterADeadPaneDiscardsThePaneSubscriptions() async throws {
        let transport = ScriptedTransport()
        let session = makeSession(transport: transport)
        var updates = session.updates.makeAsyncIterator()

        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))
        await session.updateSubscriptions(updated)
        #expect(await updates.next() == .status(.connected))

        await transport.setMissingPanes(["w1:p1"])
        await session.retry()

        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))
        #expect(await transport.capturedSubscriptions == [initial, updated, initial])

        await session.end()
    }

    @Test func retryAnnouncesConnectingBeforeTeardownClosesTheTransport() async throws {
        let first = ScriptedTransport()
        let second = ScriptedTransport()
        let connector = SequencedTransportConnector([first, second])
        let session = EventsSession(
            subscriptions: initial,
            connect: { try await connector.connect() },
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50)),
            keepalive: nil)
        var updates = session.updates.makeAsyncIterator()

        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))

        let closeGate = ScriptedTransportCallGate()
        await first.gateNextClose(using: closeGate)
        let retrying = Task { await session.retry() }
        try await waitUntil("teardown should reach the installed transport") {
            await closeGate.entryCount == 1
        }
        #expect(await updates.next() == .status(.connecting))
        #expect(await !first.isClosed)
        await closeGate.open()
        await retrying.value
        #expect(await updates.next() == .status(.connected))
        #expect(await first.isClosed)
        await session.end()
    }

    @Test func permanentFailureStopsTheReconnectLoop() async throws {
        let connectionAttempts = Mutex(0)
        let session = EventsSession(
            subscriptions: initial,
            connect: { () async throws -> any Transport in
                connectionAttempts.withLock { $0 += 1 }
                throw TransportError.authenticationFailed
            },
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .milliseconds(1), multiplier: 1, maxDelay: .milliseconds(1)),
            keepalive: nil)
        var updates = session.updates.makeAsyncIterator()

        await session.resume()

        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.failed(.authenticationFailed)))
        try await Task.sleep(for: .milliseconds(30))
        #expect(connectionAttempts.withLock { $0 } == 1)

        await session.end()
    }

    @Test func corruptDeviceKeyStopsWithActionRequiredInsteadOfReconnecting() async throws {
        let connectionAttempts = Mutex(0)
        let session = EventsSession(
            subscriptions: initial,
            connect: { () async throws -> any Transport in
                connectionAttempts.withLock { $0 += 1 }
                throw DeviceKeyStoreError.storedKeyCorrupt
            },
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .milliseconds(1), multiplier: 1, maxDelay: .milliseconds(1)),
            keepalive: nil)
        var updates = session.updates.makeAsyncIterator()

        await session.resume()

        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.failed(.deviceKeyCorrupt)))
        try await Task.sleep(for: .milliseconds(30))
        #expect(connectionAttempts.withLock { $0 } == 1)

        await session.end()
    }

    @Test func corruptRSAKeyStopsWithRSARecoveryInsteadOfReconnecting() async throws {
        let connectionAttempts = Mutex(0)
        let session = EventsSession(
            subscriptions: initial,
            connect: { () async throws -> any Transport in
                connectionAttempts.withLock { $0 += 1 }
                throw RSAKeyStoreError.storedKeyCorrupt
            },
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .milliseconds(1), multiplier: 1, maxDelay: .milliseconds(1)),
            keepalive: nil)
        var updates = session.updates.makeAsyncIterator()

        await session.resume()

        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.failed(.rsaKeyCorrupt)))
        try await Task.sleep(for: .milliseconds(30))
        #expect(connectionAttempts.withLock { $0 } == 1)

        await session.end()
    }

    @Test func suspendDoesNotWaitForAStalledConnectionAttempt() async throws {
        let firstTransport = ScriptedTransport()
        let resumedTransport = ScriptedTransport()
        let gate = ScriptedTransportCallGate()
        let connector = StalledFirstConnection(
            gate: gate, first: firstTransport, resumed: resumedTransport)
        let session = EventsSession(
            subscriptions: initial,
            connect: { try await connector.connect() },
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50)),
            keepalive: nil)
        var updates = session.updates.makeAsyncIterator()

        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        try await waitUntil("the first connection should be in flight") {
            await gate.entryCount == 1
        }

        let completion = LifecycleCompletionProbe()
        let suspending = Task {
            await session.suspend()
            await completion.finish()
        }
        try await waitUntil("suspend must not inherit an unbounded wait from the SSH connection task") {
            await completion.isFinished
        }
        let suspendedPromptly = await completion.isFinished
        guard suspendedPromptly else {
            await gate.open()
            await suspending.value
            await session.end()
            return
        }
        await suspending.value
        #expect(await updates.next() == .status(.suspended))

        // A new activation can connect while the abandoned first attempt is
        // still parked. Releasing that stale attempt later only closes its
        // Transport; it cannot replace the current one or emit connected.
        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))
        #expect(await connector.attemptCount == 2)
        #expect(await !resumedTransport.isClosed)

        await gate.open()
        try await waitUntil("the stale connection should be discarded") {
            await firstTransport.isClosed
        }
        #expect(await !resumedTransport.isClosed)

        await session.end()
    }

    /// The opposite race, and the routine one on iOS: a quick
    /// background→foreground bounce lands `resume()` while `suspend()`'s
    /// teardown is still mid-flight. The session serializes lifecycle
    /// transitions itself, so the teardown completes fully before the new
    /// activation dials and the app layer never has to serialize its own
    /// calls. The interleaving is deterministic because the transport's
    /// `close()` is gated by the test, pinning `suspend()` inside its
    /// teardown when `resume()` is issued.
    @Test func resumeRacingIntoSuspendTeardownWaitsForTeardownToFinish() async throws {
        let first = ScriptedTransport()
        let second = ScriptedTransport()
        let closeGate = ScriptedTransportCallGate()
        await first.gateNextClose(using: closeGate)
        let connector = SequencedTransportConnector([first, second])
        let session = EventsSession(
            subscriptions: initial,
            connect: { try await connector.connect() },
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50)),
            keepalive: nil)
        var updates = session.updates.makeAsyncIterator()

        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))

        let suspending = Task { await session.suspend() }
        try await waitUntil("the teardown should park inside the transport close") {
            await closeGate.entryCount == 1
        }
        let resuming = Task { await session.resume() }
        // The bounce must not jump the queue: no new dial while the teardown
        // is parked at the gated close.
        try await Task.sleep(for: .milliseconds(200))
        #expect(await connector.connectCount == 1)

        await closeGate.open()
        await suspending.value
        await resuming.value

        #expect(await updates.next() == .status(.suspended))
        #expect(await updates.next() == .status(.connecting))
        #expect(await updates.next() == .status(.connected))
        #expect(await connector.connectCount == 2)
        #expect(await first.isClosed)
        #expect(await !second.isClosed)

        // The run loop reference survived the bounce: end() still tears the
        // second transport down — nothing leaks.
        await session.end()
        #expect(await updates.next() == .status(.ended))
        #expect(await updates.next() == nil)
        #expect(await second.isClosed)
    }
}

@MainActor
private final class ProjectionGenerationBarrier {
    weak var projection: HostConsoleProjection?
    private var waiters: [
        (generation: UInt64, continuation: CheckedContinuation<Void, Never>)
    ] = []

    func record() {
        guard let generation = projection?.transportGeneration else { return }
        let reached = waiters.filter { generation >= $0.generation }
        waiters.removeAll { generation >= $0.generation }
        for waiter in reached {
            waiter.continuation.resume()
        }
    }

    func wait(for generation: UInt64) async {
        guard let current = projection?.transportGeneration, current < generation else {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append((generation, continuation))
        }
    }
}

/// How many dials a scripted connect closure has seen.
private final class DialCount: Sendable {
    private let count = Mutex(0)

    var value: Int { count.withLock { $0 } }

    /// Counts one more dial and returns its ordinal.
    func next() -> Int {
        count.withLock { count in
            count += 1
            return count
        }
    }
}

private actor LifecycleCompletionProbe {
    private(set) var isFinished = false

    func finish() {
        isFinished = true
    }
}

private actor StalledFirstConnection {
    private let gate: ScriptedTransportCallGate
    private let first: ScriptedTransport
    private let resumed: ScriptedTransport
    private(set) var attemptCount = 0

    init(
        gate: ScriptedTransportCallGate,
        first: ScriptedTransport,
        resumed: ScriptedTransport
    ) {
        self.gate = gate
        self.first = first
        self.resumed = resumed
    }

    func connect() async throws -> any Transport {
        attemptCount += 1
        if attemptCount == 1 {
            await gate.waitUntilOpen()
            return first
        }
        return resumed
    }
}
