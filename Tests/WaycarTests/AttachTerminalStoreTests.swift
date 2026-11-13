import Foundation
import Observation
import Testing
import UIKit

@testable import Waycar

/// The Attach screen's store (#11) against a scripted transport: open on
/// first size report, bytes both ways, in-band resize (never a reattach),
/// remote-end surfacing with reattach — protocol level, no SSH, no UI.
@MainActor
@Suite("Attach terminal store")
struct AttachTerminalStoreTests {
    private func makeStore(
        transport: ScriptedTransport?, target: String = "w1:p1", takeover: Bool = false,
        input: TerminalInputController = TerminalInputController()
    ) -> (AttachTerminalStore, captured: Captured) {
        let store = AttachTerminalStore(
            target: target, takeover: takeover, input: input
        ) { request, handler in
            guard let transport else {
                throw TransportError.sshUnreachable(detail: "The Host is not connected.")
            }
            let session = try await transport.attachTerminal(request)
            try await handler.runEndingSession(session)
        }
        let captured = Captured()
        store.feed.attach(captured)
        return (store, captured)
    }

    /// Thread-safe record of the fallback wiring's calls and the runner's
    /// attempts, for the mosh auto-fallback tests.
    final class MoshFallbackTrace: @unchecked Sendable {
        let lock = NSLock()
        var attempts = 0
        var invalidations = 0
        var causes: [MoshInvalidationCause] = []
        var invalidatedBeforeSSH = false
    }

    /// Stands in for the Ghostty surface: a terminal the feed can deliver to,
    /// and one the test can drop to model SwiftUI replacing it.
    @MainActor
    private final class Captured: TerminalByteSink {
        var chunks: [Data] = []
        var text: String {
            String(decoding: chunks.reduce(Data(), +), as: UTF8.self)
        }

        func receive(_ data: Data) {
            chunks.append(data)
        }
    }

    /// What a real attach puts on the wire first: the TUI clearing the
    /// screen. The transport withholds the login shell's noise, so the first
    /// paint is also the moment the session stops being "Connecting…".
    private static let firstPaint = Data("\u{1B}[2J".utf8)

    /// The remote's first paint, once the channel is actually up.
    private func paint(
        _ transport: ScriptedTransport, _ bytes: Data = firstPaint
    ) async throws {
        try await waitUntil("attach should open") { await transport.hasLiveAttachSession }
        #expect(await transport.emitAttachOutput(bytes))
    }

    /// Brings a store up the way an attach does: the first size report opens
    /// the channel, the remote's first paint makes it live.
    private func goLive(
        _ store: AttachTerminalStore, _ transport: ScriptedTransport,
        cols: Int = 80, rows: Int = 24, firstPaint: Data = firstPaint
    ) async throws {
        store.viewDidResize(cols: cols, rows: rows)
        try await paint(transport, firstPaint)
        try await waitUntil("store should go live") { store.status == .live }
    }

    @Test func openChannelStaysConnectingUntilTheRemotePaints() async throws {
        // The flicker fix, from the store's side: an open channel with
        // nothing on it yet is still a blank screen, so the Connecting loader
        // has to outlive the channel open.
        let transport = ScriptedTransport()
        let (store, _) = makeStore(transport: transport)

        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("attach should open") { await transport.hasLiveAttachSession }
        #expect(store.status == .connecting)

        #expect(await transport.emitAttachOutput(Self.firstPaint))
        try await waitUntil("the first paint should go live") { store.status == .live }

        await store.stop()
    }

    @Test func firstSizeReportOpensAttachWithGeometry() async throws {
        let transport = ScriptedTransport()
        let (store, captured) = makeStore(transport: transport)
        #expect(store.status == .waitingForSize)

        // Raw PTY bytes feed straight through — no frame decoding anywhere.
        try await goLive(store, transport, firstPaint: Data("\u{1B}[2JTUI".utf8))

        let request = try #require(await transport.attachRequests.first)
        #expect(
            request == TerminalAttachRequest(target: "w1:p1", takeover: false, cols: 80, rows: 24))
        #expect(captured.text == "\u{1B}[2JTUI")

        await store.stop()
    }

    @Test func takeoverRidesThroughToTheRequest() async throws {
        let transport = ScriptedTransport()
        let (store, _) = makeStore(transport: transport, takeover: true)

        try await goLive(store, transport)

        #expect(await transport.attachRequests.first?.takeover == true)
        await store.stop()
    }

    // MARK: Returning from the background (#141)

    @Test func returningToTheForegroundAsksTheRemoteToRepaint() async throws {
        // `herdr agent attach` is ratatui: it repaints on change, never on a
        // timer, so "no bytes" is its normal steady state and cannot itself
        // be a liveness signal. A window-change is the one thing that makes a
        // live remote speak without waiting on the agent — and the frame it
        // answers with is exactly what a surface that came back empty needs.
        let transport = ScriptedTransport()
        let (store, _) = makeStore(transport: transport)

        try await goLive(store, transport, cols: 80, rows: 24)
        store.didBecomeActive()

        try await waitUntil("the return should nudge the remote PTY") {
            await transport.attachInputs == [
                .resize(cols: 79, rows: 24),
                .resize(cols: 80, rows: 24),
            ]
        }
        await store.stop()
    }

    @Test func keystrokesForwardToTheSession() async throws {
        let transport = ScriptedTransport()
        let (store, _) = makeStore(transport: transport)

        try await goLive(store, transport)

        store.send(Data("y".utf8))
        store.send(Data([0x1B, 0x5B, 0x41]))  // Up arrow from the terminal emulator.
        await store.stop()

        #expect(
            await transport.attachInputs == [
                .keystrokes(Data("y".utf8)),
                .keystrokes(Data([0x1B, 0x5B, 0x41])),
            ])
    }

    @Test func touchScrollingUsesTheBoundedScrollPath() async throws {
        let transport = ScriptedTransport()
        let input = TerminalInputController()
        let (store, _) = makeStore(transport: transport, input: input)
        let sequence = Data("wheel".utf8)

        try await goLive(store, transport)

        input.scroll(sequence, rows: 5)
        try await waitUntil("scroll rows should reach the session in bounded batches") {
            await transport.attachInputs.count == 2
        }
        await store.stop()

        #expect(
            await transport.attachInputs == [
                .scroll(sequence + sequence + sequence),
                .scroll(sequence + sequence),
            ])
    }

    @Test func inputControllerOwnsTheLiveWriter() async throws {
        let transport = ScriptedTransport()
        let input = TerminalInputController()
        let (store, _) = makeStore(transport: transport, input: input)

        try await goLive(store, transport)
        #expect(input.liveGeneration != nil)

        store.send(Data("before".utf8))
        await store.stop()
        store.send(Data("after".utf8))

        #expect(await transport.attachInputs == [.keystrokes(Data("before".utf8))])
        #expect(input.liveGeneration == nil)
    }

    @Test func reattachAdvancesTheInputSessionGeneration() async throws {
        let transport = ScriptedTransport()
        let input = TerminalInputController()
        let (store, _) = makeStore(transport: transport, input: input)

        try await goLive(store, transport)
        let first = try #require(input.liveGeneration)

        await transport.endAttachFromRemote()
        try await waitUntil("the remote end should surface") {
            if case .ended = store.status { return true }
            return false
        }
        #expect(input.liveGeneration == nil)

        store.retry()
        try await paint(transport)
        try await waitUntil("store should reattach") { store.status == .live }
        let second = try #require(input.liveGeneration)
        #expect(first != second)

        await store.stop()
    }

    @Test func resizeForwardsWindowChangeWithoutReattaching() async throws {
        // The acceptance criterion's rotation path: geometry changes ride
        // SSH window-change on the live channel — attach is never reopened
        // (the whole point of a live PTY rather than fixed-size snapshots).
        let transport = ScriptedTransport()
        let (store, _) = makeStore(transport: transport)

        try await goLive(store, transport)

        store.viewDidResize(cols: 100, rows: 30)
        await store.stop()

        #expect(await transport.attachRequests.count == 1)
        #expect(await transport.attachInputs == [.resize(cols: 100, rows: 30)])
    }

    @Test func duplicateSizeReportsSendNothing() async throws {
        let transport = ScriptedTransport()
        let (store, _) = makeStore(transport: transport)

        try await goLive(store, transport)
        store.viewDidResize(cols: 80, rows: 24)
        await store.stop()

        #expect(await transport.attachRequests.count == 1)
        #expect(await transport.attachInputs.isEmpty)
    }

    @Test func remoteEndSurfacesAndReattachWorks() async throws {
        // The user detaching inside the TUI (or the pane closing) ends the
        // stream cleanly; the store surfaces it and offers a way back.
        let transport = ScriptedTransport()
        let (store, _) = makeStore(transport: transport)

        try await goLive(store, transport)

        await transport.endAttachFromRemote()
        try await waitUntil("the remote end should surface") {
            if case .ended = store.status { return true }
            return false
        }

        store.retry()
        try await paint(transport)
        try await waitUntil("retry should reattach") {
            await transport.attachRequests.count == 2 && store.status == .live
        }

        await store.stop()
    }

    /// A channel that dies under a live attach reattaches once, silently:
    /// the user sees Connecting, never `.ended`, and the next paint is live
    /// again.
    @Test func aDroppedChannelReattachesOnceWithoutEnding() async throws {
        let transport = ScriptedTransport()
        let (store, _) = makeStore(transport: transport)
        try await goLive(store, transport)

        await transport.failAttachStream(.channelFailed(detail: "attach channel: closed"))
        try await waitUntil("the retry should open a second attach") {
            await transport.attachRequests.count == 2 && store.status == .connecting
        }

        try await paint(transport)
        try await waitUntil("the retry should go live") { store.status == .live }

        await store.stop()
    }

    /// The retry is one per episode: when it fails too, the session ends
    /// with the failure's message and nothing keeps retrying.
    @Test func aFailedRetryEndsAndDoesNotLoop() async throws {
        let transport = ScriptedTransport()
        let (store, _) = makeStore(transport: transport)
        try await goLive(store, transport)

        await transport.failAttachStream(Self.channelDrop("host went away"))
        try await waitUntil("the retry should open a second attach") {
            await Self.isAttached(transport, requests: 2)
        }
        await transport.failAttachStream(Self.channelDrop("host went away"))
        try await waitUntil("the second failure should surface") {
            if case .ended(let message) = store.status { return message.contains("host went away") }
            return false
        }

        try await Task.sleep(for: .milliseconds(50))
        #expect(await transport.attachRequests.count == 2)
        guard case .ended = store.status else {
            #expect(false, "expected .ended, got \(store.status)")
            return
        }
        await store.stop()
    }

    /// Going live again earns the next drop its own retry.
    @Test func goingLiveAgainRestoresTheRetry() async throws {
        let transport = ScriptedTransport()
        let (store, _) = makeStore(transport: transport)
        try await goLive(store, transport)

        await transport.failAttachStream(Self.channelDrop("first drop"))
        try await waitUntil("the first retry should open") {
            await Self.isAttached(transport, requests: 2)
        }
        try await paint(transport)
        try await waitUntil("the first retry should go live") { store.status == .live }

        await transport.failAttachStream(Self.channelDrop("second drop"))
        try await waitUntil("the second drop should retry too") {
            await transport.attachRequests.count == 3 && store.status == .connecting
        }

        await store.stop()
    }

    /// A cold failure has nothing on the terminal to read; an attach that
    /// went live keeps what it showed through a later end.
    @Test func onlyAnAttachThatWentLiveHasContentToRead() async throws {
        let cold = AttachTerminalStore(target: "w1:p1") { _, _ in
            throw TransportError.authenticationFailed
        }
        cold.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("the cold attach should end") {
            if case .ended = cold.status { return true }
            return false
        }
        #expect(!cold.hasBeenLive)

        let transport = ScriptedTransport()
        let (store, _) = makeStore(transport: transport)
        try await goLive(store, transport)
        await transport.endAttachFromRemote()
        try await waitUntil("the attach should end") {
            if case .ended = store.status { return true }
            return false
        }
        #expect(store.hasBeenLive)
        await store.stop()
    }

    /// What the Host or the user decided is shown at once: refused
    /// credentials, the remote command's own exit status, and a channel
    /// failure that isn't the attach channel dying (a mosh bootstrap).
    @Test(
        arguments: [
            TransportError.authenticationFailed,
            TransportError.channelFailed(
                detail: "\(HostSSHSession.attachRemoteExitDetailPrefix) 1"),
            TransportError.channelFailed(detail: "mosh bootstrap printed no banner"),
            TransportError.herdrBinaryNotFound,
        ])
    func aRefusalEndsWithoutRetrying(failure: TransportError) async throws {
        let transport = ScriptedTransport()
        let (store, _) = makeStore(transport: transport)
        try await goLive(store, transport)

        await transport.failAttachStream(failure)
        try await waitUntil("the failure should surface") {
            if case .ended = store.status { return true }
            return false
        }

        try await Task.sleep(for: .milliseconds(50))
        #expect(await transport.attachRequests.count == 1)
        await store.stop()
    }

    @Test func aCleanRemoteExitEndsWithoutRetrying() async throws {
        let transport = ScriptedTransport()
        let (store, _) = makeStore(transport: transport)
        try await goLive(store, transport)

        await transport.endAttachFromRemote()
        try await waitUntil("the exit should surface") {
            store.status == .ended("The session ended.")
        }

        try await Task.sleep(for: .milliseconds(50))
        #expect(await transport.attachRequests.count == 1)
        await store.stop()
    }

    /// A stop that lands while the channel is dying wins: no second attach
    /// is opened behind it.
    @Test func aStoppedStoreNeverRetries() async throws {
        let gate = ScriptedTransportCallGate()
        let trace = MoshFallbackTrace()
        let store = AttachTerminalStore(target: "w1:p1") { _, _ in
            trace.lock.withLock { trace.attempts += 1 }
            await gate.waitUntilOpen()
            throw Self.channelDrop("dropped")
        }
        store.viewDidResize(cols: 80, rows: 24)
        await gate.waitForEntry()

        let stopping = Task { await store.stop() }
        await Task.yield()
        await gate.open()
        await stopping.value

        try await Task.sleep(for: .milliseconds(50))
        #expect(trace.lock.withLock { trace.attempts } == 1)
        #expect(store.status == .stopped)
    }

    private nonisolated static func channelDrop(_ detail: String) -> TransportError {
        .channelFailed(detail: "\(HostSSHSession.attachChannelDetailPrefix) \(detail)")
    }

    /// Whether the transport has taken `requests` attach requests and the
    /// latest one is up.
    private static func isAttached(_ transport: ScriptedTransport, requests: Int) async -> Bool {
        let taken = await transport.attachRequests.count
        let live = await transport.hasLiveAttachSession
        return taken == requests && live
    }

    @Test func missingTransportEndsActionably() async throws {
        let (store, _) = makeStore(transport: nil)
        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("the store should surface the missing transport") {
            store.status == .ended("The Host is not connected.")
        }
    }

    /// A mosh failure after the banner auto-falls back to SSH exactly once:
    /// the invalidation runs before the restart, the second run lands live
    /// on SSH, and no `.ended` overlay ever shows.
    @Test func moshSessionFailureFallsBackToSSHAutomaticallyOnce() async throws {
        let trace = MoshFallbackTrace()
        let store = AttachTerminalStore(
            target: "w1:p1", takeover: true,
            onMoshFailure: { cause in
                trace.lock.withLock {
                    trace.invalidations += 1
                    trace.causes.append(cause)
                }
            }
        ) { _, _ in
            trace.lock.withLock { trace.attempts += 1 }
            let attempts = trace.lock.withLock { trace.attempts }
            if attempts == 1 {
                throw TransportError.moshSessionFailed(
                    detail: "mosh session failed (exit status 1)")
            }
            trace.lock.withLock { trace.invalidatedBeforeSSH = trace.invalidations > 0 }
            throw TransportError.sshUnreachable(detail: "scripted SSH failure")
        }

        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("the fallback should restart over SSH") {
            let (attempts, invalidations) = trace.lock.withLock { (trace.attempts, trace.invalidations) }
            return attempts == 2 && invalidations == 1
        }
        #expect(trace.lock.withLock { trace.invalidatedBeforeSSH })
        // Automatic: a network change may give mosh another chance (#105).
        #expect(trace.lock.withLock { trace.causes } == [.automaticFallback])
        // The SSH attempt's own failure ends the session — no mosh message,
        // no second fallback.
        #expect(
            store.status == .ended("The Host is not connected."))

        await store.stop()
    }

    /// Without fallback wiring the mosh failure ends the session once, with
    /// the mosh message and the "Use SSH Instead" affordance — and
    /// `retryOverSSH` cannot loop: one invalidation, one restart, and the
    /// budget stays spent.
    @Test func moshFailureWithoutFallbackEndsAndOffersSSHInstead() async throws {
        let store = AttachTerminalStore(
            target: "w1:p1", takeover: true
        ) { _, _ in
            throw TransportError.moshSessionFailed(
                detail: "mosh session failed (exit status 1)")
        }
        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("the mosh failure should surface") {
            store.status == .ended("The mosh session failed: mosh session failed (exit status 1)")
        }
        #expect(store.endedWithMoshFailure)

        store.retryOverSSH()
        try await waitUntil("the forced reattach should end again") {
            if case .ended = store.status { return true }
            return false
        }
        // One restart only: the second failure ends, never loops.
        try await Task.sleep(for: .milliseconds(50))
        guard case .ended = store.status else {
            #expect(false, "expected .ended, got \(store.status)")
            return
        }
    }

    /// The overlay's "Use SSH Instead" is the user's choice, and says so
    /// (#105): unlike the automatic fallback, no network change undoes it.
    @Test func useSSHInsteadInvalidatesAsTheUsersChoice() async throws {
        let trace = MoshFallbackTrace()
        let store = AttachTerminalStore(
            target: "w1:p1", takeover: true,
            onMoshFailure: { cause in trace.lock.withLock { trace.causes.append(cause) } }
        ) { _, _ in
            let attempts = trace.lock.withLock {
                trace.attempts += 1
                return trace.attempts
            }
            if attempts <= 2 {
                throw TransportError.moshSessionFailed(detail: "mosh session failed (exit status 1)")
            }
            throw TransportError.sshUnreachable(detail: "scripted SSH failure")
        }
        store.viewDidResize(cols: 80, rows: 24)
        // The automatic fallback runs first; its mosh retry fails again and
        // the overlay offers SSH.
        try await waitUntil("the second mosh failure should end the session") {
            store.endedWithMoshFailure && trace.lock.withLock { trace.attempts } == 2
        }
        store.retryOverSSH()
        try await waitUntil("the user's choice should reattach over SSH") {
            trace.lock.withLock { trace.attempts } == 3
        }
        #expect(trace.lock.withLock { trace.causes } == [.automaticFallback, .userChoseSSH])
        await store.stop()
    }

    /// #151: when a store is the refused second consumer, the refusal must
    /// end only that store's run. The transport's gate leaves the legitimate
    /// consumer running; an unconditional `end()` in the runner's catch
    /// would reach through the shared session and tear down the very
    /// terminal the gate just protected — so the runner's owned teardown
    /// (`runEndingSession`, which `HostConsoleProjection.terminalRunner`
    /// uses) skips exactly that error, and the refusal stays visible on the
    /// offending store. Both consumers are real stores: the proof is the
    /// first app terminal staying live and its screen still receiving.
    @Test(.timeLimit(.minutes(1)))
    func aRefusedSecondConsumerStoreLeavesTheFirstTerminalRunning() async throws {
        let gate = WaycarSSHAttachOutputGate()
        let shared = TerminalAttachSession(
            output: gate.makeOutput,
            input: TerminalAttachInputQueue(),
            onEndStarted: gate.beginExplicitEnd
        ) {}
        let runSharedSession: TerminalSessionRunner = { _, handler in
            try await handler.runEndingSession(shared)
        }

        let first = AttachTerminalStore(target: "w1:p1", runTerminal: runSharedSession)
        let firstScreen = Captured()
        first.feed.attach(firstScreen)
        first.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("the first store should claim the gate") {
            gate.hasParkedConsumerForTesting
        }
        gate.yield(Self.firstPaint)
        try await waitUntil("the first store should go live") { first.status == .live }

        let second = AttachTerminalStore(target: "w1:p1", runTerminal: runSharedSession)
        second.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("the refusal should surface on the offending store") {
            second.status == .ended("Another terminal is already open on this Host.")
        }

        // The refused store must not have ended the shared session: the
        // first terminal is still live, still registered on the gate, and
        // its screen still receives output. Two chunks, so silent early
        // termination cannot pass for survival.
        #expect(first.status == .live, "the refusal ended the first store's session")
        try await waitUntil("the first store should stay parked on the gate") {
            gate.hasParkedConsumerForTesting
        }
        gate.yield(Data("after-the-refusal".utf8))
        gate.yield(Data("still-flowing".utf8))
        try await waitUntil("the first terminal should keep receiving output") {
            firstScreen.text == "\u{1B}[2J" + "after-the-refusal" + "still-flowing"
        }
        #expect(first.status == .live, "later output must reach a still-live first terminal")

        await first.stop()
    }

    @Test func stopEndsTheSessionAndIsTerminal() async throws {
        let transport = ScriptedTransport()
        let (store, _) = makeStore(transport: transport)

        try await goLive(store, transport)

        await store.stop()
        #expect(store.status == .stopped)
        #expect(await transport.hasLiveAttachSession == false)

        // Late size reports (the view tearing down) must not resurrect it.
        store.viewDidResize(cols: 40, rows: 12)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await transport.attachRequests.count == 1)
        #expect(store.status == .stopped)
    }

    @Test func stopIsIdempotentAcrossDetachAndBackstopPaths() async throws {
        // The Detach button stops before dismissing; the cover's onDisappear
        // backstop then stops again. The first stop must end the session for
        // real, the second must be a harmless no-op.
        let transport = ScriptedTransport()
        let (store, _) = makeStore(transport: transport)

        try await goLive(store, transport)

        await store.stop()
        #expect(store.status == .stopped)
        #expect(await transport.hasLiveAttachSession == false)

        await store.stop()
        #expect(store.status == .stopped)
        #expect(await transport.attachRequests.count == 1)
        #expect(await transport.hasLiveAttachSession == false)
    }

    @Test func stopAbortsARunStillWaitingForTheTerminalChannel() async throws {
        // Before a session exists the run can be queued for the Host's
        // terminal channel. Teardown must abort that wait — a stop that sits
        // behind whoever holds the channel wedges the whole lifecycle queue.
        let store = AttachTerminalStore(target: "w1:p1") { _, _ in
            // Parked as a queued acquire would be: indefinitely, but
            // cancellation-aware.
            try await Task.sleep(for: .seconds(60))
        }
        store.viewDidResize(cols: 80, rows: 24)
        #expect(store.status == .connecting)

        let began = ContinuousClock.now
        await store.stop()
        #expect(store.status == .stopped)
        #expect(ContinuousClock.now - began < .seconds(5))
    }

    @Test func concurrentStopsFromDetachAndBackstopBothComplete() async throws {
        // The two paths can overlap (the backstop fires while the Detach
        // stop is still awaiting teardown); both must complete and the
        // session must be gone.
        let transport = ScriptedTransport()
        let (store, _) = makeStore(transport: transport)

        try await goLive(store, transport)

        async let detachStop: Void = store.stop()
        async let backstopStop: Void = store.stop()
        _ = await (detachStop, backstopStop)

        #expect(store.status == .stopped)
        #expect(await transport.hasLiveAttachSession == false)
        #expect(await transport.attachRequests.count == 1)
    }

    @Test func resizeRacingThePendingOpenIsForwardedOnceLive() async throws {
        // The view can resize (keyboard, rotation) while the channel is
        // still coming up; the session must end up at the latest geometry.
        let transport = ScriptedTransport()
        let (store, _) = makeStore(transport: transport)

        store.viewDidResize(cols: 80, rows: 24)
        store.viewDidResize(cols: 100, rows: 30)
        try await paint(transport)
        try await waitUntil("store should go live") { store.status == .live }
        // Depending on when the open task read the dims, the session either
        // opened at the latest geometry or got a catch-up resize.
        try await waitUntil("the latest geometry should reach the session") {
            if let request = await transport.attachRequests.first,
                request.cols == 100, request.rows == 30
            {
                return true
            }
            return await transport.attachInputs.contains(.resize(cols: 100, rows: 30))
        }
        #expect(await transport.attachRequests.count == 1)

        await store.stop()
    }
}

@MainActor
@Suite("Agent Attach store")
struct AgentAttachStoreTests {
    @Test func unchangedGenerationAllowsConsecutiveForegroundRecoveries() async throws {
        let transport = ScriptedTransport()
        let generation = TerminalGenerationSource(1)
        let runner: TerminalSessionRunner = { request, handler in
            let readyGeneration = await generation.acquire()
            await handler.transportDidBecomeReady(readyGeneration, flavor: .ssh)
            let session = try await transport.attachTerminal(request)
            try await handler.runEndingSession(session)
        }
        let store = makeStore(
            transport: transport,
            generation: 1,
            runTerminal: runner)

        let initialSessionGate = ScriptedTransportCallGate()
        await transport.gateNextAttachSession(using: initialSessionGate)
        store.viewDidResize(cols: 80, rows: 24)
        await initialSessionGate.waitForEntry()
        let initialStatusChanges = observeStatusChanges(of: store)
        #expect(await transport.emitAttachOutput(Data("initial".utf8)))
        await initialSessionGate.open()
        await initialStatusChanges.next()
        #expect(store.terminalStatus == .live)

        let firstRecoveryChanges = observeTerminalChanges(of: store)
        store.didBecomeActive(afterPossibleSuspension: true)
        await firstRecoveryChanges.next()
        let firstRecoveryID = store.terminalID

        let firstRecoveryGate = ScriptedTransportCallGate()
        await transport.gateNextAttachSession(using: firstRecoveryGate)
        store.viewDidResize(cols: 100, rows: 30)
        await firstRecoveryGate.waitForEntry()
        #expect(await transport.attachRequests.count == 2)
        let firstRecoveryStatusChanges = observeStatusChanges(of: store)
        #expect(await transport.emitAttachOutput(Data("first recovery".utf8)))
        await firstRecoveryGate.open()
        await firstRecoveryStatusChanges.next()
        #expect(store.terminalStatus == .live)

        // No second projection is emitted for generation 1. Acquiring the
        // already-projected generation must still release the recovery latch.
        let secondRecoveryChanges = observeTerminalChanges(of: store)
        store.didBecomeActive(afterPossibleSuspension: true)
        await secondRecoveryChanges.next()
        let secondRecoveryID = store.terminalID
        #expect(secondRecoveryID != firstRecoveryID)

        let secondRecoveryGate = ScriptedTransportCallGate()
        await transport.gateNextAttachSession(using: secondRecoveryGate)
        store.viewDidResize(cols: 100, rows: 30)
        await secondRecoveryGate.waitForEntry()
        #expect(await transport.attachRequests.count == 3)
        let secondRecoveryStatusChanges = observeStatusChanges(of: store)
        #expect(await transport.emitAttachOutput(Data("second recovery".utf8)))
        await secondRecoveryGate.open()
        await secondRecoveryStatusChanges.next()
        #expect(store.terminalStatus == .live)
        #expect(store.terminalID == secondRecoveryID)

        await store.leave().value
        #expect(await transport.attachRequests.count == 3)
        #expect(await !transport.hasLiveAttachSession)
    }

    @Test func foregroundRecoveryDoesNotAbsorbANewerTransportGeneration() async throws {
        let transport = ScriptedTransport()
        let generation = TerminalGenerationSource(1)
        let runner: TerminalSessionRunner = { request, handler in
            let readyGeneration = await generation.acquire()
            await handler.transportDidBecomeReady(readyGeneration, flavor: .ssh)
            let session = try await transport.attachTerminal(request)
            try await handler.runEndingSession(session)
        }
        let store = makeStore(
            transport: transport,
            generation: 1,
            runTerminal: runner)

        let firstSessionGate = ScriptedTransportCallGate()
        await transport.gateNextAttachSession(using: firstSessionGate)
        store.viewDidResize(cols: 80, rows: 24)
        await firstSessionGate.waitForEntry()
        let firstStatusChanges = observeStatusChanges(of: store)
        #expect(await transport.emitAttachOutput(Data("first".utf8)))
        await firstSessionGate.open()
        await firstStatusChanges.next()
        #expect(store.terminalStatus == .live)

        await generation.set(2)
        let predecessorID = store.terminalID
        let terminalChanges = observeTerminalChanges(of: store)
        store.didBecomeActive(afterPossibleSuspension: true)
        await terminalChanges.next()
        let recoveryID = store.terminalID
        #expect(recoveryID != predecessorID)
        #expect(store.terminalStatus == .waitingForSize)

        let secondSessionGate = ScriptedTransportCallGate()
        await transport.gateNextAttachSession(using: secondSessionGate)
        store.viewDidResize(cols: 100, rows: 30)
        await secondSessionGate.waitForEntry()
        #expect(await transport.attachRequests.count == 2)

        // Coalesce away the projection edge for generation 2, then publish 3
        // while pipeline 2 is still connecting. Generation 3 is not an
        // acknowledgement of pipeline 2 and must replace it.
        await generation.set(3)
        let replacementChanges = observeTerminalChanges(of: store)
        store.transportGenerationDidChange(3)
        await secondSessionGate.open()
        await replacementChanges.next()
        let latestRecoveryID = store.terminalID
        #expect(latestRecoveryID != recoveryID)
        #expect(await transport.attachRequests.count == 2)

        let thirdSessionGate = ScriptedTransportCallGate()
        await transport.gateNextAttachSession(using: thirdSessionGate)
        store.viewDidResize(cols: 100, rows: 30)
        await thirdSessionGate.waitForEntry()
        #expect(await transport.attachRequests.count == 3)
        let latestStatusChanges = observeStatusChanges(of: store)
        #expect(await transport.emitAttachOutput(Data("latest".utf8)))
        await thirdSessionGate.open()
        await latestStatusChanges.next()
        #expect(store.terminalStatus == .live)

        await store.leave().value
        #expect(store.terminalID == latestRecoveryID)
        #expect(await transport.attachRequests.count == 3)
        #expect(await !transport.hasLiveAttachSession)
    }

    @Test func foregroundRecoveryAbsorbsItsAcquiredTransportGeneration() async throws {
        let transport = ScriptedTransport()
        let generation = TerminalGenerationSource(1)
        let runner: TerminalSessionRunner = { request, handler in
            let readyGeneration = await generation.acquire()
            await handler.transportDidBecomeReady(readyGeneration, flavor: .ssh)
            let session = try await transport.attachTerminal(request)
            try await handler.runEndingSession(session)
        }
        let store = makeStore(
            transport: transport,
            generation: 1,
            runTerminal: runner)

        let firstSessionGate = ScriptedTransportCallGate()
        await transport.gateNextAttachSession(using: firstSessionGate)
        store.viewDidResize(cols: 80, rows: 24)
        await firstSessionGate.waitForEntry()
        let firstStatusChanges = observeStatusChanges(of: store)
        #expect(await transport.emitAttachOutput(Data("first".utf8)))
        await firstSessionGate.open()
        await firstStatusChanges.next()
        #expect(store.terminalStatus == .live)

        await generation.set(2)
        let recoveryChanges = observeTerminalChanges(of: store)
        store.didBecomeActive(afterPossibleSuspension: true)
        await recoveryChanges.next()
        let recoveryID = store.terminalID

        let secondSessionGate = ScriptedTransportCallGate()
        await transport.gateNextAttachSession(using: secondSessionGate)
        store.viewDidResize(cols: 100, rows: 30)
        await secondSessionGate.waitForEntry()

        // The exact edge acknowledges this already-acquired pipeline and must
        // not enqueue a duplicate writer behind it.
        store.transportGenerationDidChange(2)
        #expect(store.terminalID == recoveryID)
        #expect(await transport.attachRequests.count == 2)

        let secondStatusChanges = observeStatusChanges(of: store)
        #expect(await transport.emitAttachOutput(Data("second".utf8)))
        await secondSessionGate.open()
        await secondStatusChanges.next()
        #expect(store.terminalStatus == .live)

        await store.leave().value
        #expect(store.terminalID == recoveryID)
        #expect(await transport.attachRequests.count == 2)
        #expect(await !transport.hasLiveAttachSession)
    }

    @Test func projectionFirstRecoveryAbsorbsItsMatchingAcquisition() async throws {
        let transport = ScriptedTransport()
        let generation = TerminalGenerationSource(1)
        let runner: TerminalSessionRunner = { request, handler in
            let readyGeneration = await generation.acquire()
            await handler.transportDidBecomeReady(readyGeneration, flavor: .ssh)
            let session = try await transport.attachTerminal(request)
            try await handler.runEndingSession(session)
        }
        let store = makeStore(
            transport: transport,
            generation: 1,
            runTerminal: runner)

        let firstSessionGate = ScriptedTransportCallGate()
        await transport.gateNextAttachSession(using: firstSessionGate)
        store.viewDidResize(cols: 80, rows: 24)
        await firstSessionGate.waitForEntry()
        let firstStatusChanges = observeStatusChanges(of: store)
        #expect(await transport.emitAttachOutput(Data("first".utf8)))
        await firstSessionGate.open()
        await firstStatusChanges.next()

        await generation.set(2)
        let readyGate = ScriptedTransportCallGate()
        await generation.gateNextAcquisition(using: readyGate)
        let recoveryChanges = observeTerminalChanges(of: store)
        store.didBecomeActive(afterPossibleSuspension: true)
        await recoveryChanges.next()
        let recoveryID = store.terminalID

        let secondSessionGate = ScriptedTransportCallGate()
        await transport.gateNextAttachSession(using: secondSessionGate)
        store.viewDidResize(cols: 100, rows: 30)
        await readyGate.waitForEntry()

        // Projection reaches the owner before the waiter records generation 2.
        store.transportGenerationDidChange(2)
        #expect(store.terminalID == recoveryID)
        #expect(await transport.attachRequests.count == 1)

        await readyGate.open()
        await secondSessionGate.waitForEntry()
        let secondStatusChanges = observeStatusChanges(of: store)
        #expect(await transport.emitAttachOutput(Data("second".utf8)))
        await secondSessionGate.open()
        await secondStatusChanges.next()
        #expect(store.terminalStatus == .live)
        #expect(store.terminalID == recoveryID)
        #expect(await transport.attachRequests.count == 2)

        await store.leave().value
        #expect(await !transport.hasLiveAttachSession)
    }

    @Test func projectionFirstRecoveryReplacesOnceForANewerGeneration() async throws {
        let transport = ScriptedTransport()
        let generation = TerminalGenerationSource(1)
        let runner: TerminalSessionRunner = { request, handler in
            let readyGeneration = await generation.acquire()
            await handler.transportDidBecomeReady(readyGeneration, flavor: .ssh)
            let session = try await transport.attachTerminal(request)
            try await handler.runEndingSession(session)
        }
        let store = makeStore(
            transport: transport,
            generation: 1,
            runTerminal: runner)

        let firstSessionGate = ScriptedTransportCallGate()
        await transport.gateNextAttachSession(using: firstSessionGate)
        store.viewDidResize(cols: 80, rows: 24)
        await firstSessionGate.waitForEntry()
        let firstStatusChanges = observeStatusChanges(of: store)
        #expect(await transport.emitAttachOutput(Data("first".utf8)))
        await firstSessionGate.open()
        await firstStatusChanges.next()

        await generation.set(2)
        let readyGate = ScriptedTransportCallGate()
        await generation.gateNextAcquisition(using: readyGate)
        let recoveryChanges = observeTerminalChanges(of: store)
        store.didBecomeActive(afterPossibleSuspension: true)
        await recoveryChanges.next()
        let recoveryID = store.terminalID

        let secondSessionGate = ScriptedTransportCallGate()
        await transport.gateNextAttachSession(using: secondSessionGate)
        store.viewDidResize(cols: 100, rows: 30)
        await readyGate.waitForEntry()

        // Generation 3 is latched before pipeline 2 records its acquisition.
        // Reconciliation must replace pipeline 2 once, after its exact
        // generation becomes known.
        let replacementChanges = observeTerminalChanges(of: store)
        store.transportGenerationDidChange(3)
        #expect(store.terminalID == recoveryID)
        #expect(await transport.attachRequests.count == 1)

        await readyGate.open()
        await secondSessionGate.waitForEntry()
        await secondSessionGate.open()
        await replacementChanges.next()
        let latestRecoveryID = store.terminalID
        #expect(latestRecoveryID != recoveryID)
        #expect(await transport.attachRequests.count == 2)

        await generation.set(3)
        let thirdSessionGate = ScriptedTransportCallGate()
        await transport.gateNextAttachSession(using: thirdSessionGate)
        store.viewDidResize(cols: 100, rows: 30)
        await thirdSessionGate.waitForEntry()
        let latestStatusChanges = observeStatusChanges(of: store)
        #expect(await transport.emitAttachOutput(Data("latest".utf8)))
        await thirdSessionGate.open()
        await latestStatusChanges.next()
        #expect(store.terminalStatus == .live)
        #expect(store.terminalID == latestRecoveryID)
        #expect(await transport.attachRequests.count == 3)

        await store.leave().value
        #expect(await !transport.hasLiveAttachSession)
    }

    @Test func productionAttachTakesOverAnExistingRemoteClient() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("attach should open") {
            await transport.attachRequests.count == 1
        }

        #expect(await transport.attachRequests.first?.takeover == true)
        await store.leave().value
    }

    @Test func plainWebURLsBecomeAttachLinksInMostRecentOrder() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        try await goLive(store, transport)

        await transport.emitAttachOutput(
            Data(
                """
                Preview: https://example.com/build/42?mode=full#result
                Local: http://localhost:3000/health

                """.utf8))
        try await waitUntil("both links should become observable") {
            store.attachLinks.map(\.target) == [
                "http://localhost:3000/health",
                "https://example.com/build/42?mode=full#result",
            ]
        }

        await store.leave().value
    }

    @Test func aNewDistinctLinkIsIndexedWithoutSendingTerminalInput() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        try await goLive(store, transport)

        await transport.emitAttachOutput(
            Data("https://example.com/new?signature=exact#result\n".utf8))

        try await waitUntil("the new distinct link should be indexed") {
            store.attachLinks.first?.target
                == "https://example.com/new?signature=exact#result"
        }
        #expect(await transport.attachInputs.isEmpty)

        await store.leave().value
    }

    @Test func failedOpenKeepsTheLinkAndOffersExactCopyRecovery() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)
        let exactTarget = "https://example.com/signed?q=a%2Fb#Exact"

        try await goLive(store, transport)
        await transport.emitAttachOutput(Data((exactTarget + "\n").utf8))
        try await waitUntil("the exact link should be collected") {
            store.attachLinks.first?.target == exactTarget
        }
        let link = try #require(store.attachLinks.first)

        store.openAttachLink(link) { url in
            #expect(url.absoluteString == exactTarget)
            return false
        }

        #expect(store.attachLinks.map(\.target) == [exactTarget])
        try await waitUntil("the failed open should offer copy recovery") {
            store.attachLinkOpenFailure?.link == link
        }
        #expect(store.attachLinkOpenFailure?.message.contains(link.host) == true)

        var copiedTarget: String?
        store.copyFailedAttachLink { copiedTarget = $0 }
        #expect(copiedTarget == exactTarget)
        #expect(store.attachLinks.map(\.target) == [exactTarget])
        #expect(store.attachLinkOpenFailure == nil)

        await store.leave().value
    }

    @Test func anOlderFailedOpenCannotReplaceTheLatestSuccessfulOpen() async throws {
        let transport = ScriptedTransport()
        let opener = DeferredAttachLinkOpener()
        let store = makeStore(transport: transport, generation: 0)

        try await goLive(store, transport)
        await transport.emitAttachOutput(
            Data(
                """
                https://example.com/first
                https://example.com/latest

                """.utf8))
        try await waitUntil("both links should be collected") {
            store.attachLinks.count == 2
        }
        let first = try #require(
            store.attachLinks.first { $0.target == "https://example.com/first" })
        let latest = try #require(
            store.attachLinks.first { $0.target == "https://example.com/latest" })

        store.openAttachLink(first, using: opener.open)
        try await waitUntil("the first system open should be pending") {
            opener.pendingTargets == [first.target]
        }
        store.openAttachLink(latest, using: opener.open)
        try await waitUntil("both system opens should be pending") {
            Set(opener.pendingTargets) == Set([first.target, latest.target])
        }

        opener.complete(latest.target, accepted: true)
        for _ in 0..<10 {
            await Task.yield()
        }
        #expect(store.attachLinkOpenFailure == nil)

        opener.complete(first.target, accepted: false)
        for _ in 0..<10 {
            await Task.yield()
        }
        #expect(store.attachLinkOpenFailure == nil)
        #expect(store.attachLinks.count == 2)

        await store.leave().value
    }

    @Test func leavingAttachCancelsAPendingSystemOpenWithoutLaterMutation() async throws {
        let transport = ScriptedTransport()
        let opener = CancellationAwareAttachLinkOpener()
        let store = makeStore(transport: transport, generation: 0)

        try await goLive(store, transport)
        await transport.emitAttachOutput(Data("https://example.com/leaving-open\n".utf8))
        try await waitUntil("the link should be collected") {
            store.attachLinks.count == 1
        }
        let link = try #require(store.attachLinks.first)

        store.openAttachLink(link, using: opener.open)
        try await waitUntil("the system open should be pending") {
            opener.pendingTarget == link.target
        }

        await store.leave().value
        try await waitUntil("leaving Attach should cancel the system open") {
            opener.cancelledTargets == [link.target]
        }

        #expect(store.attachLinks.isEmpty)
        #expect(store.attachLinkOpenFailure == nil)
    }

    @Test func styledTextAndOSC8HyperlinksExposeTheirRealTargets() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        try await goLive(store, transport)

        await transport.emitAttachOutput(
            Data(
                "\u{001B}Phttps://hidden-control.example\u{001B}\\"
                    .utf8))
        await transport.emitAttachOutput(
            Data(
                "\u{001B}]0;https://hidden-title.example\u{0007}"
                    .utf8))
        await transport.emitAttachOutput(
            Data("See (\u{001B}[31mhttps://styled.exa".utf8))
        await transport.emitAttachOutput(
            Data("mple/path\u{001B}[0m),\n".utf8))
        await transport.emitAttachOutput(
            Data(
                "\u{001B}]8;;https://actual.example/build/42?mode=full#result\u{0007}"
                    .utf8))
        await transport.emitAttachOutput(
            Data("https://misleading.example\u{001B}]8;;\u{0007}\n".utf8))
        await transport.emitAttachOutput(
            Data("\u{001B}]8;id=docs;https://docs.example/guide\u{001B}".utf8))
        await transport.emitAttachOutput(
            Data("\\Documentation\u{001B}]8;;\u{001B}\\\n".utf8))

        try await waitUntil("styled and explicit hyperlink targets should settle") {
            store.attachLinks.map(\.target) == [
                "https://docs.example/guide",
                "https://actual.example/build/42?mode=full#result",
                "https://styled.example/path",
            ]
        }

        await store.leave().value
    }

    /// A line break in the stream ends a URL. On screen, an agent TUI that
    /// wraps its own text short of the edge (Codex, OpenCode) breaks a URL
    /// after a `/` and draws its rest on the next row: that rest, with a
    /// `/` of its own, carries the URL on.
    @Test func streamLineBreaksEndURLsButTheScreenRejoinsOneWrappedAfterASlash() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        try await goLive(store, transport)

        await transport.emitAttachOutput(
            Data("https://\nredrawn.example/result\n".utf8))
        store.viewportTextDidChange(
            """
            Result: (https://redrawn.example/result).
            see https://
            split.example/path
            """)

        try await waitUntil("the complete redrawn targets should be observed") {
            store.attachLinks.map(\.target) == [
                "https://split.example/path",
                "https://redrawn.example/result",
            ]
        }

        await store.leave().value
    }

    @Test func softWrappedViewportDoesNotAddPrefixesOfStreamTargets() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)
        let target = "https://127.0.0.1:8443/private?token=literal#frag"

        try await goLive(store, transport)

        await transport.emitAttachOutput(Data("\(target)\n".utf8))
        try await waitUntil("the complete stream target should be observed") {
            store.attachLinks.map(\.target) == [target]
        }

        store.viewportTextDidChange(
            "https://127.0.0                  \n"
                + ".1:8443/private?to             \n"
                + "ken=literal#frag               ")

        #expect(store.attachLinks.map(\.target) == [target])

        await store.leave().value
    }

    /// The screen is rescanned on every viewport snapshot, so a screen holding
    /// more links than the index keeps must settle. It did not: the overflow
    /// was evicted, the next scan read the evicted targets as new, and
    /// reinserting them evicted others — the list churned forever. Each churn
    /// invalidated every view observing it, which drove SwiftUI back into the
    /// terminal's update, which took another snapshot. That loop hung the app
    /// on any agent whose screen carried enough links.
    @MainActor
    @Test func rescanningACrowdedScreenLeavesTheLinkListAlone() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)
        try await goLive(store, transport)
        // Equal-length and mutually non-prefixing, so the index's ambiguous
        // prefix rule cannot quietly drop them instead.
        let crowded = (0..<30)
            .map { "https://example.com/p\(String(format: "%03d", $0))" }
            .joined(separator: " \n")

        store.viewportTextDidChange(crowded)
        let settled = store.attachLinks.map(\.target)
        #expect(!settled.isEmpty)

        for _ in 0..<5 {
            store.viewportTextDidChange(crowded)
            #expect(
                store.attachLinks.map(\.target) == settled,
                "the same screen produced a different link list on rescan")
        }

        await store.leave().value
    }

    @Test func repeatedViewportLayoutsKeepTheLongestAmbiguousTarget() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)
        let target =
            "https://softwrap.example/this/is/a/very/long/path?token=literal#finish"

        try await goLive(store, transport)

        store.viewportTextDidChange(target)
        #expect(store.attachLinks.map(\.target) == [target])

        store.viewportTextDidChange(
            "https://softwrap.example/this/is/a/very")
        store.viewportTextDidChange("https://softwrap")

        #expect(store.attachLinks.map(\.target) == [target])

        await store.leave().value
    }

    @Test func repeatedViewportSnapshotsDoNotRewriteStreamRecency() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        try await goLive(store, transport)
        await transport.emitAttachOutput(
            Data(
                """
                https://older.example/result
                https://newer.example/result

                """.utf8))
        try await waitUntil("stream order should settle") {
            store.attachLinks.map(\.target) == [
                "https://newer.example/result",
                "https://older.example/result",
            ]
        }

        store.viewportTextDidChange("https://older.example/result")

        #expect(
            store.attachLinks.map(\.target) == [
                "https://newer.example/result",
                "https://older.example/result",
            ])

        await store.leave().value
    }

    /// A Claude Code pane as herdr repaints it, trimmed: its banner, prompt
    /// and box glyphs are UTF-8 whose middle bytes fall in 0x80–0x9F (`▐`
    /// is E2 96 90, `▛` E2 96 9B, `▝` E2 96 9D, `❯` E2 9D AF, `┐` E2 94 90).
    /// Read as 8-bit C1 controls, they opened string controls that
    /// swallowed the URL below them until a `✻` (E2 9C BB) ended them.
    private static let claudeCodeTarget: String = "https://claude.ai/code/routines/trig_X"
    private static let claudeCodeFrame: String = [
        "\u{1B}[?1049h\u{1B}[?1000h\u{1B}[?1002h\u{1B}[?1003h\u{1B}[?1015h\u{1B}[?1006h",
        "\u{1B}[?2026h\u{1B}[?25l\u{1B}]8;;\u{1B}\\\u{1B}[2J\u{1B}[1;1H",
        "\u{1B}[2;1H\u{1B}[0;38;2;215;119;87;49m ▐\u{1B}[2;3H▛\u{1B}[2;4H███▛█",
        "\u{1B}[0;39;49m   \u{1B}[0;1;39;49mClaude Code\u{1B}[0;39;49m v2.1.296   ",
        "\u{1B}[3;1H\u{1B}[0;38;2;215;119;87;49m▝\u{1B}[3;2H▜███████▀",
        "\u{1B}[0;39;49m  Haiku 4.5 · Claude Max   ",
        "\u{1B}[5;1H┌────────┐ ← back   \u{1B}[6;1H└────────┘   ",
        "\u{1B}[7;1H\u{1B}[0;38;2;153;153;153;48;2;55;55;55m❯\u{1B}[7;2H prompt   ",
        "\u{1B}[10;1H\u{1B}[0;38;2;255;255;255;49m⏺\u{1B}[10;2H\u{1B}[0;39;49m ",
        "\u{1B}[0;1;39;49mTo delete it permanently,\u{1B}[0;39;49m go to ",
        "\(claudeCodeTarget).   ",
        "\u{1B}[12;1H\u{1B}[0;38;2;153;153;153;49m✻\u{1B}[12;2H Cogitated for 15s   ",
        "\u{1B}[0m\u{1B}[24;3H\u{1B}[?25h\u{1B}[?2026l",
    ].joined()
    private static let claudeCodeScreen: String = """
         ▐▛███▛█   Claude Code v2.1.296
        ▝▜███████▀  Haiku 4.5 · Claude Max

        ┌────────┐ ← back
        └────────┘
        ❯ prompt


        ⏺ To delete it permanently, go to \(claudeCodeTarget).

        ✻ Cogitated for 15s
        """

    @Test func claudeCodeGlyphsDoNotHideAStreamedURL() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        try await goLive(store, transport, cols: 120, rows: 24)
        await transport.emitAttachOutput(Data(Self.claudeCodeFrame.utf8))

        try await waitUntil("the URL under Claude Code's glyphs should be found") {
            store.attachLinks.map(\.target) == [Self.claudeCodeTarget]
        }

        await store.leave().value
    }

    @Test func claudeCodeGlyphsDoNotHideAURLOnScreen() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        try await goLive(store, transport, cols: 120, rows: 24)
        store.viewportTextDidChange(Self.claudeCodeScreen)

        #expect(store.attachLinks.map(\.target) == [Self.claudeCodeTarget])

        await store.leave().value
    }

    /// herdr repaints a row the TUI wrapped as two rows drawn by cursor
    /// moves, so a URL reaching the right edge arrives as its head, a jump
    /// to the next row, and its tail.
    private static let cutHead = "https://claude.ai/code/ro"
    private static let cutFrame: String = {
        let prompt = "❯ go to"
        let gap = String(repeating: " ", count: 80 - prompt.count - cutHead.count)
        return "\u{1B}[?2026h\u{1B}[5;1H\(prompt)\(gap)\(cutHead)"
            + "\u{1B}[6;1Hutines/trig_X.\u{1B}[0m\u{1B}[24;3H\u{1B}[?2026l"
    }()
    private static let wholeFrame: String =
        "\u{1B}[?2026h\u{1B}[8;1H⏺ go to \(claudeCodeTarget).\u{1B}[0m\u{1B}[24;3H\u{1B}[?2026l"

    /// The head a cursor move ended stands in, provisionally, only until
    /// the whole URL is printed.
    @Test func aURLCutAtTheRowEdgeGivesWayToTheWholeURL() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        try await goLive(store, transport, cols: 80, rows: 24)
        await transport.emitAttachOutput(Data(Self.cutFrame.utf8))
        try await waitUntil("the provisional head is all the stream has shown so far") {
            store.attachLinks.map(\.target) == [Self.cutHead]
        }

        await transport.emitAttachOutput(Data(Self.wholeFrame.utf8))

        try await waitUntil("the whole URL should replace its provisional head") {
            store.attachLinks.map(\.target) == [Self.claudeCodeTarget]
        }

        await store.leave().value
    }

    /// The transport splits output anywhere: inside the cursor move that
    /// cuts the head, inside the head, inside the whole URL.
    @Test func chunksSplitInsideACursorMoveOrAURLFindTheSameLinks() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)
        let cut = Data(Self.cutFrame.utf8)
        let whole = Data(Self.wholeFrame.utf8)
        let headEnd = try #require(cut.firstRange(of: Data("/ro\u{1B}[6".utf8))).upperBound
        let urlMiddle = try #require(whole.firstRange(of: Data("routines".utf8))).lowerBound

        try await goLive(store, transport, cols: 80, rows: 24)
        await transport.emitAttachOutput(cut[..<(headEnd - 6)])
        await transport.emitAttachOutput(cut[(headEnd - 6)..<headEnd])
        await transport.emitAttachOutput(cut[headEnd...])
        try await waitUntil("the provisional head should be found across chunks") {
            store.attachLinks.map(\.target) == [Self.cutHead]
        }

        await transport.emitAttachOutput(whole[..<urlMiddle])
        await transport.emitAttachOutput(whole[urlMiddle...])
        try await waitUntil("the whole URL should be found across chunks") {
            store.attachLinks.map(\.target) == [Self.claudeCodeTarget]
        }

        await store.leave().value
    }

    /// Only a longer URL it begins replaces a provisional head: an
    /// unrelated URL printed after it leaves it standing.
    @Test func aCutHeadStaysWhenNothingLongerFollows() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        try await goLive(store, transport, cols: 80, rows: 24)
        await transport.emitAttachOutput(Data(Self.cutFrame.utf8))
        await transport.emitAttachOutput(
            Data("\u{1B}[10;1Hsee https://example.org/other \u{1B}[24;3H".utf8))

        try await waitUntil("the head should stay beside the unrelated URL") {
            store.attachLinks.map(\.target) == ["https://example.org/other", Self.cutHead]
        }

        await store.leave().value
    }

    /// A URL a cursor move ends may be the head of a longer one, so the
    /// stream alone lets `https://example.com/docs` replace it. The screen,
    /// showing it alone on its row above another URL, shows it whole and
    /// brings it back beside the longer one.
    @Test func urlsEndedByCursorMovesInsideTheRowAreKeptBesideLongerOnes() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        try await goLive(store, transport, cols: 80, rows: 24)
        await transport.emitAttachOutput(
            Data(
                ("\u{1B}[?2026h\u{1B}[3;3Hhttps://example.com\u{1B}[0m"
                    + "\u{1B}[4;3Hhttps://example.com/docs\u{1B}[0m\u{1B}[24;3H\u{1B}[?2026l"
                    + "https://example.org\r\nhttps://example.org/docs\r\n").utf8))
        try await waitUntil("the stream alone should keep what lines ended") {
            store.attachLinks.map(\.target) == [
                "https://example.org/docs",
                "https://example.org",
                "https://example.com/docs",
            ]
        }

        store.viewportTextDidChange("\n\n  https://example.com\n  https://example.com/docs\n")

        #expect(
            store.attachLinks.map(\.target) == [
                "https://example.com",
                "https://example.org/docs",
                "https://example.org",
                "https://example.com/docs",
            ])

        await store.leave().value
    }

    /// OpenCode streams a reply by redrawing it, each frame's OSC 8 target
    /// as far as the URL has come, and a diff frame skips a cell that did
    /// not change. Trimmed from a capture of OpenCode 1.19 under herdr.
    @Test func openCodeStreamingPrefixesGiveWayToTheURLsOnScreen() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)
        let target = "https://example.com/waycar/harness-audit/links-and-paths-check-0123456789"
        func frame(_ prefix: String) -> String {
            "\u{1B}[?2026h\u{1B}[10;18H\u{1B}[0;4;38;2;86;182;194;48;2;10;10;10m"
                + "\u{1B}]8;;\(prefix)\u{1B}\\\(prefix)\u{1B}[0;4;38;2;250;178;131;48;2;10;10;10m"
                + " (\(prefix))\u{1B}]8;;\u{1B}\\\u{1B}[0m\u{1B}[40;6H\u{1B}[?2026l"
        }

        try await goLive(store, transport, cols: 120, rows: 44)
        await transport.emitAttachOutput(
            Data(
                ("\u{1B}[?2026h\u{1B}[11;79H\u{1B}[0;38;2;238;238;238;48;2;10;10;10m(https://ex"
                    + "\u{1B}[11;91Hmple.org/x)\u{1B}[0;38;2;255;255;255;48;2;10;10;10m   "
                    + "\u{1B}[0m\u{1B}[40;6H\u{1B}[?2026l").utf8))
        try await waitUntil("the diff frame's cut head stands in for now") {
            store.attachLinks.map(\.target) == ["https://ex"]
        }

        for prefix in ["https://example.com/", "https://example.com/waycar/har", target] {
            await transport.emitAttachOutput(Data(frame(prefix).utf8))
        }
        try await waitUntil("the cut head and each streamed prefix should give way") {
            store.attachLinks.map(\.target) == [target]
        }

        store.viewportTextDidChange(
            "     Next, go to \(target). The plan\n"
                + "     is in docs/plan.md, see (https://example.org/x) too.")

        #expect(store.attachLinks.map(\.target) == ["https://example.org/x", target])

        await store.leave().value
    }

    /// oh-my-pi links a URL with OSC 8 while it streams, from its first
    /// characters. Trimmed from a capture of omp 18.9 under herdr.
    @Test func ompHyperlinkTargetsStreamedPartlyGiveWayToTheWholeOne() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)
        let target = "https://example.com/waycar/harness-audit/links-and-paths-check-0123456789"

        try await goLive(store, transport, cols: 120, rows: 44)
        await transport.emitAttachOutput(
            Data(
                ("\u{1B}[?2026h\u{1B}[18;3H\u{1B}[0;4;38;2;38;139;210;49m"
                    + "\u{1B}]8;;https://example.c\u{1B}\\https://example.c\u{1B}[18;5H"
                    + "\u{1B}[0;38;2;88;110;117;49m\u{1B}]8;;\u{1B}\\W\u{1B}[0m\u{1B}[21;4H"
                    + "\u{1B}[?2026l").utf8))
        await transport.emitAttachOutput(
            Data(
                ("\u{1B}[?2026h\u{1B}[16;3H\u{1B}[0;4;38;2;38;139;210;49m"
                    + "\u{1B}]8;;\(target)\u{1B}\\\(target)\u{1B}[0;39;49m\u{1B}]8;;\u{1B}\\."
                    + "\u{1B}[16;89HThe\u{1B}[0m\u{1B}[21;4H\u{1B}[?2026l").utf8))

        try await waitUntil("only the whole target should remain") {
            store.attachLinks.map(\.target) == [target]
        }

        await store.leave().value
    }

    /// At a narrow grid, Claude Code breaks a URL at the right edge and
    /// indents the rest; Pi breaks it a cell short and pads it with a blank.
    /// Each is one link on screen, and the head the stream cut gives way to
    /// it. Trimmed from captures at 60 columns under herdr.
    @Test func aURLWrappedAtANarrowGridIsOneLinkOnScreen() async throws {
        let target = "https://example.com/waycar/harness-audit/links-and-paths-check-0123456789"
        let claude = (
            head: "https://example.com/waycar/harness-audit/links",
            stream: "\u{1B}[20;1H\u{1B}[0;38;2;255;255;255;49m⏺\u{1B}[20;3H\u{1B}[0;39;49mNext,"
                + "\u{1B}[20;9Hgo\u{1B}[20;12Hto\u{1B}[20;15H"
                + "https://example.com/waycar/harness-audit/links"
                + "\u{1B}[21;3H-and-paths-check-0123456789.\u{1B}[21;32HThe",
            screen: """
                ⏺ Next, go to https://example.com/waycar/harness-audit/links
                  -and-paths-check-0123456789. The plan is in docs/plan.md
                """)
        let pi = (
            head: "https://example.com/waycar/harness-audit/links-and-paths-c",
            stream: "\u{1B}[31;1H \u{1B}[0;4;38;2;129;162;190;49m"
                + "https://example.com/waycar/harness-audit/links-and-paths-c"
                + "\u{1B}[0;38;2;129;162;190;49m \u{1B}[32;1H\u{1B}[0;39;49m "
                + "\u{1B}[0;4;38;2;129;162;190;49mheck-0123456789\u{1B}[0;39;49m. The plan",
            screen: """
                 Next, go to
                 https://example.com/waycar/harness-audit/links-and-paths-c
                 heck-0123456789. The plan is in docs/plan.md and the
                """)

        for capture in [claude, pi] {
            let transport = ScriptedTransport()
            let store = makeStore(transport: transport, generation: 0)
            try await goLive(store, transport, cols: 60, rows: 39)
            await transport.emitAttachOutput(Data(capture.stream.utf8))
            try await waitUntil("the stream should find the cut head") {
                store.attachLinks.map(\.target) == [capture.head]
            }

            store.viewportTextDidChange(capture.screen)

            #expect(store.attachLinks.map(\.target) == [target])
            await store.leave().value
        }
    }

    /// A herdr frame drawing `rows` from the top, each by a cursor move, as
    /// herdr draws every row: it never sends a line break.
    private static func herdrFrame(_ rows: [String]) -> Data {
        var frame = "\u{1B}[?2026h"
        for (index, row) in rows.enumerated() {
            frame += "\u{1B}[\(index + 1);1H\(row)"
        }
        return Data((frame + "\u{1B}[30;1H\u{1B}[?2026l").utf8)
    }

    /// Streams `rows` as herdr draws them, then shows them on screen, on a
    /// grid `columns` wide.
    private func showRows(
        _ rows: [String], columns: Int, on store: AgentAttachStore, _ transport: ScriptedTransport
    ) async throws {
        try await goLive(store, transport, cols: columns, rows: 24)
        await transport.emitAttachOutput(Self.herdrFrame(rows))
        try await waitUntil("the stream should find a link") { !store.attachLinks.isEmpty }
        store.viewportTextDidChange(rows.joined(separator: "\n"))
    }

    /// A sentence ending its row in a URL and a full stop, above a row that
    /// opens with a path, is two words, in the links and in the files.
    @Test func aSentenceEndingARowAboveAPathStaysApart() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        try await showRows(
            [
                "I saved it.",
                "/tmp/harness-audit/shot.png shows the result, see https://example.com.",
                "docs/plan.md has the details.",
            ],
            columns: 80, on: store, transport)

        #expect(store.attachLinks.map(\.target) == ["https://example.com"])
        #expect(
            store.attachMediaCandidates.map(\.path)
                == ["docs/plan.md", "/tmp/harness-audit/shot.png"])

        await store.leave().value
    }

    /// Claude Code and Pi wrap prose at the full width, so a URL ending a
    /// row often reaches the edge: the next row's prose word, or a list's
    /// `-`, is no part of it.
    @Test func aURLAtTheRowEdgeDoesNotRunIntoTheNextRowsProse() async throws {
        let screens = [
            (
                columns: 66,
                rows: [
                    "⏺ The setup guide for this project is at https://example.com/setup",
                    "  and the rest is in docs/plan.md for later.",
                ]
            ),
            (columns: 29, rows: ["see https://example.com/setup", "- item"]),
        ]

        for screen in screens {
            let transport = ScriptedTransport()
            let store = makeStore(transport: transport, generation: 0)
            try await showRows(screen.rows, columns: screen.columns, on: store, transport)

            #expect(store.attachLinks.map(\.target) == ["https://example.com/setup"])
            await store.leave().value
        }
    }

    /// herdr ends every row with a cursor move, so only the screen can show
    /// that a URL ending its row above prose is whole. Shown whole, it
    /// stays beside a longer URL it begins.
    @Test func aURLEndingItsRowAboveProseStaysBesideALongerOne() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        try await showRows(
            [
                "Server now listening on http://localhost:3000",
                "  and the docs are at http://localhost:3000/docs too.",
            ],
            columns: 80, on: store, transport)

        #expect(
            Set(store.attachLinks.map(\.target))
                == ["http://localhost:3000", "http://localhost:3000/docs"])
        #expect(store.attachLinks.count == 2)

        await store.leave().value
    }

    /// A URL opening the next row behind Markdown emphasis or a bracket is
    /// a link of its own, even below a URL reaching the edge.
    @Test func aURLOpeningTheNextRowBehindMarkupIsALinkOfItsOwn() async throws {
        let screens = [
            (columns: 31, rows: ["Docs: https://example.com/guide", "**https://example.org/other** too"]),
            (columns: 30, rows: ["see https://example.com/setup", "(https://example.org/other) too"]),
        ]

        for screen in screens {
            let transport = ScriptedTransport()
            let store = makeStore(transport: transport, generation: 0)
            try await showRows(screen.rows, columns: screen.columns, on: store, transport)

            let head = String(screen.rows[0].split(separator: " ")[1])
            #expect(Set(store.attachLinks.map(\.target)) == [head, "https://example.org/other"])
            #expect(store.attachLinks.count == 2)
            await store.leave().value
        }
    }

    /// The screen completing a head the stream cut puts the whole URL where
    /// the head stood, behind links the stream printed after it.
    @Test func theScreenCompletesAHeadInItsPlace() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        try await showRows(
            ["go to https://example.com/wa", "ycar/x", "see https://example.org/y "],
            columns: 28, on: store, transport)

        #expect(
            store.attachLinks.map(\.target)
                == ["https://example.org/y", "https://example.com/waycar/x"])

        await store.leave().value
    }

    /// Claude Code's hard wrap can break a URL inside its scheme.
    @Test func aSchemeSplitAtTheRowEdgeIsRejoined() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)
        let head = String(repeating: "x", count: 39) + " please go to htt"

        try await goLive(store, transport, cols: head.count, rows: 24)
        store.viewportTextDidChange(head + "\n  ps://example.com/waycar/notes. Thanks")

        #expect(store.attachLinks.map(\.target) == ["https://example.com/waycar/notes"])

        await store.leave().value
    }

    /// A word wrapper hard-breaks only a word longer than the row, so a URL
    /// cut at the edge inside a token or a hash runs on into the letters
    /// and digits that open the next row.
    @Test func aURLHardBrokenInsideATokenAtTheEdgeIsOneLink() async throws {
        let screens = [
            (
                rows: ["see https://claude.ai/code/routines/trig_01Ur", "4tPocEZW828mbGT8RmRC now"],
                target: "https://claude.ai/code/routines/trig_01Ur4tPocEZW828mbGT8RmRC"
            ),
            (
                rows: [
                    "go https://github.com/o/r/commit/0a1b2c3d4e5f60718",
                    "293a4b5c6d7e8f9a0b1c2d3e4f5 done",
                ],
                target: "https://github.com/o/r/commit/0a1b2c3d4e5f60718293a4b5c6d7e8f9a0b1c2d3e4f5"
            ),
        ]

        for screen in screens {
            let transport = ScriptedTransport()
            let store = makeStore(transport: transport, generation: 0)
            try await showRows(screen.rows, columns: screen.rows[0].count, on: store, transport)

            #expect(store.attachLinks.map(\.target) == [screen.target])
            await store.leave().value
        }
    }

    /// A URL reaching the edge stays apart from a next row opening with a
    /// scheme of its own, a bracket, or, after a full stop, a file's name.
    /// A port is no scheme: `localh` above `ost:3000/docs` is one URL.
    @Test func aURLAtTheEdgeStaysApartFromASchemeABracketOrAFileBelowIt() async throws {
        let screens = [
            (rows: ["see https://example.com/a", "mailto:x@y.com"], links: ["https://example.com/a"]),
            (rows: ["see https://example.com/a", "tel:+15551234 ok"], links: ["https://example.com/a"]),
            (
                rows: ["(see https://example.com/guide)", "(e.g. the setup) more"],
                links: ["https://example.com/guide"]
            ),
            (
                rows: ["[guide](https://example.com/guide)", "(docs/plan.md) more"],
                links: ["https://example.com/guide"]
            ),
            (
                rows: [
                    "⏺ The setup guide for this project is at https://example.com/setup.",
                    "  README.md has more.",
                ],
                links: ["https://example.com/setup"]
            ),
            (rows: ["see http://localh", "ost:3000/docs ok"], links: ["http://localhost:3000/docs"]),
        ]

        for screen in screens {
            let transport = ScriptedTransport()
            let store = makeStore(transport: transport, generation: 0)
            try await showRows(screen.rows, columns: screen.rows[0].count, on: store, transport)

            #expect(store.attachLinks.map(\.target) == screen.links)
            await store.leave().value
        }
    }

    /// A row framed at the grid's last column reaches its edge two blanks
    /// short of the frame, as a tap reads it.
    @Test func aFramedRowReachesItsEdgeAtTheFrame() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)
        let head = "┊  see https://example.com/"
        let url = head + String(repeating: "o", count: 60 - head.count - 3)
        let rows = [
            url + "  █",
            "┊  pen/x.html more".padding(toLength: 59, withPad: " ", startingAt: 0) + "█",
        ]

        try await goLive(store, transport, cols: 60, rows: 24)
        store.viewportTextDidChange(rows.joined(separator: "\n"))

        #expect(
            store.attachLinks.map(\.target)
                == ["https://example.com/" + String(repeating: "o", count: 30) + "pen/x.html"])

        await store.leave().value
    }

    /// Claude Code and Pi move a word that fits down whole, so a URL that
    /// only ended its row at the edge is whole above a URL-ish word that
    /// could have shared the next row with it; Pi keeps the blank after a
    /// link it wrapped. The rows are verbatim from captures of Claude Code
    /// (haiku) and Pi under herdr at 60 columns.
    @Test func aURLEndingAtTheEdgeStaysApartFromAURLishWordBelow() async throws {
        let screens: [(rows: [String], url: String)] = [
            (["⏺ Alpha bravo charlie delta echo fo https://example.com/docs", "  README.md is the place to look."],
             "https://example.com/docs"),
            (["  Alpha bravo charlie delta echo fo https://example.com/plan", "  follow-up items are listed."],
             "https://example.com/plan"),
            (["  Alpha bravo charlie delta echo f https://example.com/guide", "  e.g. the second section."],
             "https://example.com/guide"),
            (["  Alpha bravo charlie delta echo f https://example.com/notes", "  v1.2 shipped on Tuesday."],
             "https://example.com/notes"),
            (["  Alpha bravo charlie delta echo fo https://example.com/meet", "  10:30 is when we start."],
             "https://example.com/meet"),
            ([" Alpha bravo charlie delta echo fo https://example.com/docs", "  README.md is the place to look."],
             "https://example.com/docs"),
            ([" Alpha bravo charlie delta echo fo https://example.com/plan", "  follow-up items are listed."],
             "https://example.com/plan"),
            ([" Alpha bravo charlie delta echo f https://example.com/guide", "  e.g. the second section."],
             "https://example.com/guide"),
            ([" Alpha bravo charlie delta echo f https://example.com/notes", "  v1.2 shipped on Tuesday."],
             "https://example.com/notes"),
            ([" Alpha bravo charlie delta echo fo https://example.com/meet", "  10:30 is when we start."],
             "https://example.com/meet"),
        ]

        for screen in screens {
            let transport = ScriptedTransport()
            let store = makeStore(transport: transport, generation: 0)
            try await showRows(screen.rows, columns: 60, on: store, transport)

            #expect(store.attachLinks.map(\.target) == [screen.url])
            await store.leave().value
        }
    }

    /// A word wrapper hard-breaks a URL longer than the row wherever its
    /// own edge falls: mid-row at the grid's edge or short of it (Claude
    /// Code's prompt, two cells short), or on a row of its own (Qwen,
    /// Hermes and Mastra Code two cells short, Maki a cell short with its
    /// rest unindented), and may cut it right before one of its `/`s. Each
    /// is one link again.
    @Test func aURLAWordWrapperHardBrokeIsOneLinkWhereverItsEdgeFalls() async throws {
        let token: String = "https://example.com/hooks/trig_01Ur4tPocEZW828mbGT8RmRCxQ7vYhJ2kLmN0pQrStUvWxYz"
            + "0123456789abcdefABCDEF0123456789zz/view"
        let url = "https://example.com/waycar/harness-audit/links-and-paths-check-0123456789"
        let ownRowHead: String = "    " + String(url.prefix(54))
        let ownRowRest: String = "    " + String(url.dropFirst(54)) + ". done"
        let unindentedHead = String(url.prefix(59))
        let unindentedRest: String = String(url.dropFirst(59)) + " done"
        let screens: [(rows: [String], columns: Int, target: String)] = [
            (
                rows: [
                    "  docs. Paragraph 7: Token https://example.com/hooks/trig_",
                    "  01Ur4tPocEZW828mbGT8RmRCxQ7vYhJ2kLmN0pQrStUvWxYz012345678",
                    "  9abcdefABCDEF0123456789zz/view ok.",
                ],
                columns: 60, target: token
            ),
            (
                rows: [
                    "  Token https://example.com/hooks/trig_01Ur4tPocEZW828mbGT8R",
                    "  mRCxQ7vYhJ2kLmN0pQrStUvWxYz0123456789abcdefABCDEF012345678",
                    "  9zz/view ok.",
                ],
                columns: 60, target: token
            ),
            (rows: ["    See", ownRowHead, ownRowRest], columns: 60, target: url),
            (rows: ["maki> See", unindentedHead, unindentedRest], columns: 60, target: url),
            (
                rows: [
                    "  (`src/terminal/state.rs`); https://developer.apple.com",
                    "  /27f07ce/spoken/the/promotional/its-adr-citadel",
                ],
                columns: 56, target: "https://developer.apple.com/27f07ce/spoken/the/promotional/its-adr-citadel"
            ),
        ]

        for screen in screens {
            let transport = ScriptedTransport()
            let store = makeStore(transport: transport, generation: 0)
            try await showRows(screen.rows, columns: screen.columns, on: store, transport)

            #expect(store.attachLinks.map(\.target) == [screen.target])
            await store.leave().value
        }
    }

    /// A terminal wraps characters, so a URL a shell's `printf` ran past
    /// the last cell runs on into the next row's first, whatever opens it;
    /// a raw row that stops short of the last cell ended its URL. The
    /// first screen is from a capture of a shell at 120 columns.
    @Test func aURLATerminalWrappedRunsOnOnlyFromAFullRow() async throws {
        let printed: String = "https://example.com/waycar/harness-audit/raw-printf-check-0123456789/and/a"
            + "/longer/path/so/it/splits/at/one-twenty"
        let printedHead: String = "fetching " + String(printed.dropLast(2))
        let screens: [(rows: [String], columns: Int, links: [String])] = [
            (rows: [printedHead, "ty done"], columns: 120, links: [printed]),
            (rows: ["see https://example.com", "/waycar/notes ok"], columns: 23, links: ["https://example.com/waycar/notes"]),
            (rows: ["log: fetched https://example.com/a/b", "README.md next"], columns: 37, links: ["https://example.com/a/b"]),
        ]

        for screen in screens {
            let transport = ScriptedTransport()
            let store = makeStore(transport: transport, generation: 0)
            try await showRows(screen.rows, columns: screen.columns, on: store, transport)

            #expect(store.attachLinks.map(\.target) == screen.links)
            await store.leave().value
        }
    }

    /// Where the break shows a URL ending its row whole — its next word
    /// could have shared the next row with it — it stays beside a longer
    /// URL it begins, and apart from a path below it.
    @Test func aURLTheBreakShowsWholeStaysBesideALongerOne() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        try await showRows(
            [
                "⏺ The full setup guide for this project is at https://example.com/",
                "  README.md has more, and https://example.com/setup too.",
                "⏺ The screenshot of the Waycar app is at https://example.com/shots",
                "  /tmp/shot.png has a copy.",
            ],
            columns: 66, on: store, transport)

        #expect(
            store.attachLinks.map(\.target)
                == ["https://example.com/", "https://example.com/shots", "https://example.com/setup"])

        await store.leave().value
    }

    /// OpenCode wraps a URL short of its frame after a `/`, above the
    /// query and fragment it carries on with; a `/` ending a row above
    /// prose stays apart. The cell is from a capture of OpenCode 1.19 at
    /// 60 columns.
    @Test func aURLWrappedAfterASlashRunsOnIntoItsQuery() async throws {
        let cell: [String] = [
            "  ┃                                                      █  ",
            "  ┃  Reply with only this text, verbatim, no tools: See  █  ",
            "  ┃  https://github.com/manaflow-ai/waycar/pull/1234/    █  ",
            "  ┃  files?diff=split&w=1#diff-abcdef0123456789-long-    █  ",
            "  ┃  anchor-name and the file /private/tmp/              █  ",
            "  ┃  then done.                                          █  ",
        ]
        let prose: [String] = [
            "Docs are at https://example.com/",
            "e.g. the guide, and https://example.org/",
            "README.md lists it.",
        ]
        let pullRequest: String = "https://github.com/manaflow-ai/waycar/pull/1234/files?diff=split&w=1"
            + "#diff-abcdef0123456789-long-anchor-name"
        let screens: [(rows: [String], columns: Int, links: [String])] = [
            (rows: cell, columns: 60, links: [pullRequest]),
            (rows: prose, columns: 60, links: ["https://example.com/", "https://example.org/"]),
        ]

        for screen in screens {
            let transport = ScriptedTransport()
            let store = makeStore(transport: transport, generation: 0)
            try await showRows(screen.rows, columns: screen.columns, on: store, transport)

            #expect(Set(store.attachLinks.map(\.target)) == Set(screen.links))
            #expect(store.attachLinks.count == screen.links.count)
            await store.leave().value
        }
    }

    /// A URL a TUI streamed half way (`…links-and-` above `paths-` above a
    /// row it has not drawn yet, Kilo; `● See …/waycar/` that its word
    /// wrapper then moves down whole, Kimi) is no link beside the whole
    /// one, whichever the screen shows first; a URL the stream ended
    /// visibly stays beside a longer one it begins. Rows from captures of
    /// Kilo and Kimi at 60 columns.
    @Test func aURLStreamedHalfWayGivesWayToTheWholeOne() async throws {
        let whole = "https://example.com/waycar/untested/links-and-paths-check-0123456789"
        let kiloWhole: String = "     See https://example.com/waycar/untested/links-and-\n"
            + "     paths-check-0123456789 and docs/plan.md\n\n     ▣  Code"
        let kiloPartial: String = "     See https://example.com/waycar/untested/links-and-\n     paths-\n\n     ▣  Code"
        let kimiPrompt: String = " Kimi Code\n ✨ Reply with exactly: the link\n\n"
        let kimiWhole: String = kimiPrompt + " ● See\n   https://example.com/waycar/untested/links-and-paths-chec\n"
            + "   k-0123456789 and docs/plan.md\n\n ╭───╮"
        let kimiPartial: String = kimiPrompt + " ● See https://example.com/waycar/\n\n ╭───╮"
        let pairs: [(whole: String, partial: String)] = [(kiloWhole, kiloPartial), (kimiWhole, kimiPartial)]

        for pair in pairs {
            for screens in [[pair.whole, pair.partial], [pair.partial, pair.whole]] {
                let listed = try await listedTargets(reading: screens)
                #expect(listed == [whole])
            }
        }

        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)
        try await goLive(store, transport)
        await transport.emitAttachOutput(
            Data("see https://example.com/docs\nsee https://example.com/docs/api\n".utf8))
        try await waitUntil("the stream should find both") { store.attachLinks.count == 2 }

        #expect(Set(store.attachLinks.map(\.target)) == ["https://example.com/docs", "https://example.com/docs/api"])
        await store.leave().value
    }

    /// Qwen draws its input box's scrollbar `█` right after the URL it cut
    /// at the box's edge: the stream does not take the head for whole, and
    /// it gives way to the whole URL. From a capture of Qwen at 60 columns.
    @Test func aURLAFrameGlyphFollowsGivesWayToTheWholeOne() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)
        let whole = "https://example.com/waycar/untested/links-and-paths-check-0123456789"

        try await goLive(store, transport, cols: 60, rows: 24)
        await transport.emitAttachOutput(
            Data(
                ("\u{1B}[17;5HSee https://example.com/waycar/unte\u{2588}"
                    + "\u{1B}[18;5Hsted/links-and-paths-check-0123456789 and more\r\n").utf8))
        try await waitUntil("the stream should find the head") { !store.attachLinks.isEmpty }
        store.viewportTextDidChange("    See \(whole) and more")

        #expect(store.attachLinks.map(\.target) == [whole])
        await store.leave().value
    }

    /// A URL an ellipsis cuts short with nothing after it on its row is a
    /// truncated display (Qwen's queued prompt preview), no link, in the
    /// stream or on screen. From a capture of Qwen at 60 columns.
    @Test func aURLAnEllipsisCutsShortIsNoLink() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        try await goLive(store, transport, cols: 60, rows: 24)
        await transport.emitAttachOutput(
            Data(
                ("\u{1B}[28;3HReply: See https://example.com/waycar/untest\u{2026}"
                    + "\u{1B}[29;3HCtrl+Q to queue\r\nsee https://example.org/after\n").utf8))
        try await waitUntil("the stream should find the later link") { !store.attachLinks.isEmpty }
        store.viewportTextDidChange(
            "  Reply: See https://example.com/waycar/untest\u{2026}\n  Ctrl+Q to queue")

        #expect(store.attachLinks.map(\.target) == ["https://example.org/after"])
        await store.leave().value
    }

    /// An OSC 8 label that shows only the start of its target reads on
    /// screen as a URL of its own; it is no link beside its target. From a
    /// capture of Cline's ClinePass dialog at 60 columns.
    @Test func anOSC8LabelShowingPartOfItsTargetIsNoSecondLink() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)
        let target = "https://app.cline.bot/dashboard/subscription?personal=true"

        try await goLive(store, transport, cols: 60, rows: 24)
        await transport.emitAttachOutput(
            Data(
                ("\u{1B}]8;;\(target)\u{1B}\\https://app.cline.bot/dashboard/subscription?"
                    + "\u{1B}[0m\u{1B}]8;;\u{1B}\\\r\n   Open ClinePass\r\n").utf8))
        try await waitUntil("the stream should find the target") { !store.attachLinks.isEmpty }
        store.viewportTextDidChange("   https://app.cline.bot/dashboard/subscription?\n   Open ClinePass")

        #expect(store.attachLinks.map(\.target) == [target])
        await store.leave().value
    }

    /// A URL exactly as long as its row may have been cut or only fit: the
    /// Agent's transcript settles it once read, dropping the screen's
    /// misreading (`…/xREADME.md`) and rejoining a cut it left apart
    /// (`…/langua` above `ge`, as Pi hard-breaks it a cell short).
    @Test func theTranscriptSettlesAURLAsLongAsItsRow() async throws {
        let fit = "https://example.com/docs/setup-guide/x"
        let cut = "https://developer.apple.com/local/pane/facts-code-two/the/language"
        let cutHead = String(cut.dropLast(2))
        let fitRows: [String] = ["  \(fit)", "  README.md has more."]
        let cutRows: [String] = [" \(cutHead)", " ge and more."]
        let screens: [(rows: [String], columns: Int, misread: String, reply: String, target: String)] = [
            (
                rows: fitRows, columns: fitRows[0].count,
                misread: "\(fit)README.md", reply: "See \(fit) README.md has more.", target: fit
            ),
            (rows: cutRows, columns: cut.count, misread: cutHead, reply: "Open \(cut) and more.", target: cut),
        ]

        for screen in screens {
            let transport = ScriptedTransport()
            let store = makeStore(transport: transport, generation: 0)
            try await showRows(screen.rows, columns: screen.columns, on: store, transport)
            #expect(store.attachLinks.map(\.target) == [screen.misread])

            store.receiveTranscript(
                ChatTranscriptSnapshot(
                    header: ChatTranscriptHeader(
                        kind: "claude", status: .ok, transcript: nil, activity: nil, turnOpen: false,
                        truncated: false, error: nil),
                    messages: [
                        ChatTranscriptMessage(id: "a1", role: .assistant, text: screen.reply, timestamp: nil)
                    ]))
            try await waitUntil("the transcript should settle the row break") {
                store.attachLinks.map(\.target) == [screen.target]
            }
            await store.leave().value
        }
    }

    /// A transcript snapshot of the Agent's turns `texts`, found.
    private static func foundTranscript(_ texts: [String]) -> ChatTranscriptSnapshot {
        ChatTranscriptSnapshot(
            header: ChatTranscriptHeader(
                kind: "claude", status: .ok, transcript: nil, activity: nil, turnOpen: false,
                truncated: false, error: nil),
            messages: texts.enumerated().map { index, text in
                ChatTranscriptMessage(id: "t\(index)", role: .assistant, text: text, timestamp: nil)
            })
    }

    /// A URL a row break split reaches the stream only in pieces; the
    /// screen shows it whole, ended by text on its row, and it stays beside
    /// a longer URL it begins, as a tap opens it. Rows as Claude Code wraps
    /// them at 45 columns.
    @Test func aURLTheScreenShowedWholeStaysBesideALongerOne() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)
        let rows: [String] = [
            "⏺ Opened https://github.com/manaflow-ai/wayca",
            "  r/pull/1234 for you. Review the diff at",
            "  https://github.com/manaflow-ai/waycar/pull/",
            "  1234/files",
        ]

        try await showRows(rows, columns: 45, on: store, transport)

        #expect(
            store.attachLinks.map(\.target) == [
                "https://github.com/manaflow-ai/waycar/pull/1234/files",
                "https://github.com/manaflow-ai/waycar/pull/1234",
            ])
        await store.leave().value
    }

    /// However many URLs a TUI streams a character at a time, a link the
    /// stream printed whole stays listed beside a longer one it begins.
    @Test func aLinkTheStreamPrintedStaysBesideALongerOneAfterManyMore() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)
        var output: String = "see https://github.com/o/r and more\r\n"
        for index in 0..<6 {
            let url: String = "https://example.com/streamed/url-\(index)/abcdefgh"
            for length in 12...url.count {
                output += "\u{1B}[\(5 + index);1Hsee " + String(url.prefix(length))
            }
            output += " ok\r\n"
        }
        output += "\u{1B}[20;1Hsee https://github.com/o/r/pull/5 now\r\n"

        try await goLive(store, transport)
        await transport.emitAttachOutput(Data(output.utf8))
        try await waitUntil("the stream should find the longer link") {
            store.attachLinks.first?.target == "https://github.com/o/r/pull/5"
        }

        #expect(store.attachLinks.map(\.target).contains("https://github.com/o/r"))
        await store.leave().value
    }

    /// A box that wraps by character cuts a URL two cells short of the
    /// edge, its rest unindented (Maki's input); Qwen's input box glues its
    /// scrollbar `█` to the URL it cut in the grid's last cell. Each is one
    /// link on screen.
    @Test func aURLABoxCutShortOfItsEdgeIsOneLink() async throws {
        let rule = String(repeating: "─", count: 60)
        let makiHead: String = String(repeating: "x", count: 17) + " check-0123456 and https://example.com/ab"
        let qwenHead: String = "  Reply with exactly: See https://example.com/waycar/unte"
        let qwenRest: String = "    sted/links-and-paths-check-0123456789 and more"
        let screens: [(rows: [String], target: String)] = [
            (rows: [rule, makiHead, "out/team now", rule], target: "https://example.com/about/team"),
            (
                rows: [
                    qwenHead.padding(toLength: 59, withPad: " ", startingAt: 0) + "█",
                    qwenRest.padding(toLength: 59, withPad: " ", startingAt: 0) + "█",
                ],
                target: "https://example.com/waycar/untested/links-and-paths-check-0123456789"
            ),
        ]

        for screen in screens {
            let transport = ScriptedTransport()
            let store = makeStore(transport: transport, generation: 0)
            try await showRows(screen.rows, columns: 60, on: store, transport)

            #expect(store.attachLinks.map(\.target) == [screen.target])
            await store.leave().value
        }
    }

    /// A URL `See` opens a row with and that fills it to the edge may have
    /// been cut or only fit: the next row's word with a URL character runs
    /// it on until the transcript holds it whole, and prose letters stay
    /// apart. Rows as Claude Code wraps them at 60 columns.
    @Test func theTranscriptSettlesASeeURLRowAtTheEdge() async throws {
        let url = "https://docs.example.com/guide/abcdefghijabcdefghijabc"
        let seeRow: String = "⏺ See " + url

        let prose = ScriptedTransport()
        let proseStore = makeStore(transport: prose, generation: 0)
        try await showRows([seeRow, "  Alpha bravo charlie."], columns: 60, on: proseStore, prose)
        #expect(proseStore.attachLinks.map(\.target) == [url])
        await proseStore.leave().value

        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)
        try await showRows([seeRow, "  README.md has more."], columns: 60, on: store, transport)
        #expect(store.attachLinks.map(\.target) == [url + "README.md"])

        store.receiveTranscript(Self.foundTranscript(["See \(url) README.md has more."]))
        try await waitUntil("the transcript should settle the row break") {
            store.attachLinks.map(\.target) == [url]
        }
        #expect(store.knownLinkTargets.transcript.contains(url))
        await store.leave().value
    }

    /// A transcript read before the reply on screen, naming a shorter URL
    /// in an earlier turn, does not split the longer one on screen: a next
    /// row opening with `/` carries a URL on whatever the transcript says.
    @Test func anEarlierTurnsURLDoesNotSplitALongerOneOnScreen() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)
        let earlier = "https://github.com/manaflow-ai/waycar/pull/1234"

        try await showRows(["  \(earlier)", "  /files when ready."], columns: 49, on: store, transport)
        store.receiveTranscript(Self.foundTranscript(["Earlier: \(earlier) merged."]))
        try await waitUntil("the transcript should land") {
            store.knownLinkTargets.transcript.contains(earlier)
        }

        #expect(store.attachLinks.map(\.target) == [earlier + "/files"])
        await store.leave().value
    }

    /// OpenCode wraps a URL after its last `/` above a final segment with
    /// nothing of a URL in it; the target its OSC 8 link streamed carries it
    /// on, and the cut head is no link of its own. From a capture of
    /// OpenCode 1.19 at 60 columns.
    @Test func aURLWrappedAfterItsLastSlashRunsOnAsTheStreamPrintedIt() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)
        let target = "https://example.com/waycar/untested/averyveryverylongsegmentname"
        let head: String = "     Read https://example.com/waycar/untested/"
        let rest: String = "     averyveryverylongsegmentname now."

        try await goLive(store, transport, cols: 60, rows: 24)
        await transport.emitAttachOutput(
            Data(
                ("\u{1B}[5;6HRead \u{1B}]8;;\(target)\u{1B}\\https://example.com/waycar/untested/"
                    + "\u{1B}[6;6Haveryveryverylongsegmentname\u{1B}]8;;\u{1B}\\ now.\r\n").utf8))
        try await waitUntil("the stream should find the target") { !store.attachLinks.isEmpty }
        store.viewportTextDidChange(
            head.padding(toLength: 57, withPad: " ", startingAt: 0) + "█\n"
                + rest.padding(toLength: 57, withPad: " ", startingAt: 0) + "█")

        #expect(store.attachLinks.map(\.target) == [target])
        #expect(store.knownLinkTargets.printed == [target])
        await store.leave().value
    }

    /// A link set on a line of its own above a blank row is whole, as the
    /// screen draws it row by row, and stays beside a longer one it begins.
    @Test func aURLOnALineOfItsOwnStaysBesideALongerOne() async throws {
        let pullRequest = "https://github.com/manaflow-ai/waycar/pull/1234"
        let files: String = pullRequest + "/files"
        let screens: [[String]] = [
            ["⏺ The PR is ready:", "", "  " + pullRequest, "", "  Review the diff at " + files],
            ["⏺ The PR is ready:", "", "  " + pullRequest + ".", "", "  Review the diff at " + files],
        ]

        for rows in screens {
            let transport = ScriptedTransport()
            let store = makeStore(transport: transport, generation: 0)
            try await goLive(store, transport)
            for count in 1...rows.count {
                store.viewportTextDidChange(rows.prefix(count).joined(separator: "\n"))
            }

            #expect(store.attachLinks.map(\.target) == [files, pullRequest])
            await store.leave().value
        }
    }

    /// A transcript naming a shorter URL in an earlier turn, beside a longer
    /// one it begins, does not split a longer one on screen whose rest opens
    /// with `-`; a URL the transcript holds whole stays apart from a word of
    /// its own opening with `-`, `_`, `%` or `.` below it.
    @Test func theTranscriptSettlesAWordOpeningWithPunctuation() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)
        let earlier = "https://example.com/manaflow/waycar/docs"

        try await showRows(
            ["  \(earlier)", "  -v2/getting-started.html for the update."], columns: 42, on: store, transport)
        store.receiveTranscript(Self.foundTranscript(["See \(earlier) and \(earlier)-v1/old.html earlier."]))
        try await waitUntil("the transcript should land") {
            store.knownLinkTargets.transcript.contains(earlier)
        }
        #expect(store.attachLinks.map(\.target) == [earlier + "-v2/getting-started.html"])
        await store.leave().value

        let url = "https://docs.example.com/guide/abcdefghijabcdefghijabc"
        let words: [String] = ["--verbose for more.", "_config.yml has it.", "%PATH% is set.", ".env holds it."]
        for word in words {
            let wordTransport = ScriptedTransport()
            let wordStore = makeStore(transport: wordTransport, generation: 0)
            try await showRows(["⏺ See " + url, "  " + word], columns: 60, on: wordStore, wordTransport)
            wordStore.receiveTranscript(Self.foundTranscript(["See \(url) \(word)"]))
            try await waitUntil("the transcript should keep the word apart") {
                wordStore.attachLinks.map(\.target) == [url]
            }
            await wordStore.leave().value
        }
    }

    /// The screens `rows` tall a TUI paints printing `lines` between a
    /// fixed `header` and `footer`, read every `step` lines it prints.
    private static func scrolledScreens(
        _ lines: [String], rows: Int, every step: Int = 1, header: [String] = [], footer: [String] = []
    ) -> [String] {
        let region = rows - header.count - footer.count
        var counts: [Int] = Array(stride(from: 1, through: lines.count, by: step))
        if counts.last != lines.count {
            counts.append(lines.count)
        }
        return counts.map { count in
            let shown: [String] = Array(lines[max(0, count - region)..<count])
            let padding = [String](repeating: "", count: region - shown.count)
            return (header + shown + padding + footer).joined(separator: "\n")
        }
    }

    /// `count` lines of a reply, each its own text, behind `gutter`.
    private static func replyLines(_ count: Int, gutter: String = "") -> [String] {
        (0..<count).map { "\(gutter)  Summary line \($0) about the change and what it does." }
    }

    /// The targets an Attach lists having read `screens`, one after
    /// another, 60 columns wide.
    private func listedTargets(reading screens: [String]) async throws -> Set<String> {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)
        try await goLive(store, transport, cols: 60, rows: 24)
        for screen in screens {
            store.viewportTextDidChange(screen)
        }
        let targets = Set(store.attachLinks.map(\.target))
        await store.leave().value
        return targets
    }

    /// A link ending its row stays listed once its row scrolls off, though
    /// a longer one it begins is still on screen: it never grew in place.
    @Test func aURLScrolledOffStaysBesideALongerOneStillOnScreen() async throws {
        let pullRequest = "https://github.com/manaflow-ai/waycar/pull/1234"
        let files: String = pullRequest + "/files"
        let ownLine: String = "  " + pullRequest
        let diffLine: String = "  The diff is at " + files
        let summary: [String] = Self.replyLines(44)
        let layouts: [(lines: [String], links: Set<String>)] = [
            (lines: ["⏺ Opened the pull request:", "", ownLine, "", diffLine, ""], links: [files, pullRequest]),
            (
                lines: ["⏺ The repo is https://github.com/acme/app", "  Open https://github.com/acme/app/pull/12 next."],
                links: ["https://github.com/acme/app/pull/12", "https://github.com/acme/app"]
            ),
        ]

        for rows in [40, 12, 8] {
            for layout in layouts {
                let lines: [String] = layout.lines + summary.prefix(rows + 4)
                let screens: [String] = Self.scrolledScreens(lines, rows: rows)
                let listed = try await listedTargets(reading: screens)
                #expect(listed == layout.links)
            }
        }
    }

    /// Rows the screen shows more than once (a Kilo gutter `  ┃`, a rule, a
    /// bullet of the same words) say nothing of where a scrolled-off link's
    /// row went: it stays listed, scrolled a few rows a read, or cut off by
    /// the keyboard shrinking the screen.
    @Test func aRowRepeatedOnScreenDoesNotPlaceAScrolledOffURL() async throws {
        let pullRequest = "https://github.com/manaflow-ai/waycar/pull/1234"
        let files: String = pullRequest + "/files"
        let rule = String(repeating: "─", count: 58)
        let kinds: [(filler: String, lead: String, gutter: String)] = [
            (filler: "  ┃", lead: "  ┃  ", gutter: "  ┃"),
            (filler: rule, lead: "  ", gutter: ""),
            (filler: "  - done", lead: "  ", gutter: ""),
        ]

        for kind in kinds {
            let head: [String] = [
                kind.filler, kind.lead + pullRequest, kind.filler, kind.lead + "Then " + files, kind.filler,
            ]
            let scrolled: [String] = Self.scrolledScreens(
                head + Self.replyLines(26, gutter: kind.gutter), rows: 20, every: 3)
            let listedScrolled = try await listedTargets(reading: scrolled)
            #expect(listedScrolled == [pullRequest, files])

            var resized: [String] = Self.scrolledScreens(head + Self.replyLines(14, gutter: kind.gutter), rows: 20)
            let lastRows = resized.last?.split(separator: "\n", omittingEmptySubsequences: false) ?? []
            resized.append(lastRows.suffix(10).joined(separator: "\n"))
            let listedResized = try await listedTargets(reading: resized)
            #expect(listedResized == [pullRequest, files])
        }
    }

    /// A header standing still above a reply that scrolls (as Kilo's,
    /// Claude's and Codex's conversations do) does not pin a scrolled-off
    /// link's row to where it was, though it outnumbers the reply's rows
    /// still on screen (a three-row header over 60×8, a reply of blank or
    /// gutter rows scrolling three rows a read), or the three rows between
    /// it and an input box at 60×10 are replaced whole, a longer link
    /// landing in the shorter one's cell.
    @Test func aFixedHeaderDoesNotPlaceAScrolledOffURL() async throws {
        let pullRequest = "https://github.com/manaflow-ai/waycar/pull/1234"
        let files: String = pullRequest + "/files"
        let header: [String] = ["  Session: harness-gaps · waycar"]
        let inputBox: [String] = [
            "╭" + String(repeating: "─", count: 56) + "╮", "│ >" + String(repeating: " ", count: 54) + "│",
            "╰" + String(repeating: "─", count: 56) + "╯", "  ? for shortcuts",
        ]
        let worked: String = "─ Worked for 5s " + String(repeating: "─", count: 42)
        let kilo: [String] = ["  ┃", "  ┃  " + pullRequest, "  ┃", "  ┃  Then " + files, "  ┃"]
        let claude: [String] = ["⏺ Opened the pull request:", "", "  " + pullRequest, "", "  The diff is at " + files, ""]
        let codex: [String] = ["• Opened " + pullRequest, worked, "• The diff is at " + files, worked]
        let layouts: [(lines: [String], rows: Int, step: Int, footer: [String])] = [
            (lines: kilo + Self.replyLines(20, gutter: "  ┃"), rows: 12, step: 1, footer: []),
            (lines: claude + Self.replyLines(20), rows: 12, step: 2, footer: inputBox),
            (lines: codex + Self.replyLines(28), rows: 20, step: 3, footer: ["› "]),
        ]

        for layout in layouts {
            let screens: [String] = Self.scrolledScreens(
                layout.lines, rows: layout.rows, every: layout.step, header: header, footer: layout.footer)
            let listed = try await listedTargets(reading: screens)
            #expect(listed == [pullRequest, files])
        }

        let tallHeader: [String] = ["  Kilo Code v1.2", "  Session: review the PR", "  " + String(repeating: "━", count: 56)]
        for filler in ["", "  ┃"] {
            let reply: [String] = ["  " + pullRequest, filler, "  The diff is at:", "  " + files]
                + [String](repeating: filler, count: 12)
            let screens: [String] = Self.scrolledScreens(reply, rows: 8, every: 3, header: tallHeader)
            let listed = try await listedTargets(reading: screens)
            #expect(listed == [pullRequest, files])
        }

        let replaced: [[String]] = [
            ["", "  " + pullRequest, ""], ["  The diff is at:", "  " + files, ""],
        ]
        let screens: [String] = replaced.map { (tallHeader + $0 + inputBox).joined(separator: "\n") }
        let listed = try await listedTargets(reading: screens)
        #expect(listed == [pullRequest, files])
    }

    /// A screen replaced whole between reads (a jump to another message, a
    /// clear, an alt-screen viewer) grew nothing, though it draws a longer
    /// link where a shorter one was, or on the row under it.
    @Test func aReplacedScreenGrowsNothing() async throws {
        let pullRequest = "https://github.com/manaflow-ai/waycar/pull/1234"
        let files: String = pullRequest + "/files"
        var earlier: [String] = (0..<12).map { "  Old line \($0) of an earlier turn." }
        earlier[4] = "  " + pullRequest
        let banner: [String] = ["  Waycar CLI v1.0", "  cwd: ~/src/waycar", ""]
        var pairs: [(before: [String], after: [String])] = [
            (before: banner + ["> q", "  " + pullRequest], after: banner + ["> q2", "  " + files]),
            (before: banner + ["> q", "  " + pullRequest], after: banner + ["> q2", "⏺ Here:", "  " + files]),
            (before: ["> q", "  " + pullRequest], after: ["> q2", "  " + files]),
            (
                before: banner + ["> q", "  " + pullRequest],
                after: ["  " + files] + [String](repeating: "~", count: 11)
            ),
        ]
        let jumps: [(row: Int, text: String)] = [(row: 4, text: "  " + files), (row: 5, text: "  Then " + files)]
        for (row, text) in jumps {
            var jumped: [String] = (0..<12).map { "  Line \($0) of the turn jumped to." }
            jumped[row] = text
            pairs.append((before: earlier, after: jumped))
        }

        for pair in pairs {
            let screens: [String] = [
                (pair.before + [""]).joined(separator: "\n"), (pair.after + [""]).joined(separator: "\n"),
            ]
            let listed = try await listedTargets(reading: screens)
            #expect(listed == [pullRequest, files])
        }
    }

    /// A half-streamed link whose row grew in place gives way to the
    /// longer one: the words before it on its row, or the row above, read
    /// as they did, though the input box below moved down or a tall header
    /// stands above; or, Maki's, its word wrapper moved it down whole under
    /// its words. Also while the reply scrolls a row.
    @Test func aURLGrownInPlaceGivesWay() async throws {
        let docs = "https://example.com/waycar/docs"
        let whole = "https://example.com/waycar/untested/links-and-paths-check-0123456789"
        let prompt: [String] = ["⏺ Reply with exactly:", ""]
        let earlier: [String] = (0..<11).map { "  Earlier line \($0)." }
        let inputBox: [String] = [
            "╭" + String(repeating: "─", count: 56) + "╮", "│ >" + String(repeating: " ", count: 54) + "│",
            "╰" + String(repeating: "─", count: 56) + "╯",
        ]
        let tallHeader: [String] = ["  Kilo Code v1.2", "  Session: review the PR", "  " + String(repeating: "━", count: 56)]
        let growths: [(before: [String], after: [String], link: String)] = [
            (before: prompt + ["  see https://example.com/way"], after: prompt + ["  see " + docs + " now"], link: docs),
            (before: prompt + ["  https://example.com/way"], after: prompt + ["  " + docs], link: docs),
            (
                before: earlier + ["  see https://example.com/way"],
                after: Array(earlier.dropFirst()) + ["  see " + docs + " and", "  more"], link: docs
            ),
            (
                before: prompt + ["maki> See https://exampl"],
                after: prompt + [
                    "maki> See", "https://example.com/waycar/untested/links-and-paths-check-0",
                    "123456789 and docs/plan.md",
                ],
                link: whole
            ),
            (
                before: prompt + ["  https://example.com/way", ""] + inputBox,
                after: prompt + [
                    "  https://example.com/waycar/untested/links-and-paths-check-", "  0123456789", "",
                ] + inputBox,
                link: whole
            ),
            (
                before: tallHeader + ["  https://example.com/way", ""] + inputBox,
                after: tallHeader + ["  " + docs, ""] + inputBox, link: docs
            ),
        ]

        for growth in growths {
            let screens: [String] = [
                growth.before.joined(separator: "\n"), growth.after.joined(separator: "\n"),
            ]
            let listed = try await listedTargets(reading: screens)
            #expect(listed == [growth.link])
        }
    }

    /// A root or directory URL ending in `/` on a line of its own stays
    /// beside longer ones under it.
    @Test func aURLEndingInASlashOnALineOfItsOwnStays() async throws {
        let screens: [(rows: [String], links: Set<String>)] = [
            (
                rows: ["  http://localhost:5173/", "", "  Open http://localhost:5173/about to see it."],
                links: ["http://localhost:5173/about", "http://localhost:5173/"]
            ),
            (
                rows: ["  https://docs.example.com/guide/", "", "  Then https://docs.example.com/guide/install next."],
                links: ["https://docs.example.com/guide/install", "https://docs.example.com/guide/"]
            ),
        ]
        for screen in screens {
            let reads: [String] = (1...screen.rows.count).map { screen.rows.prefix($0).joined(separator: "\n") }
            let listed = try await listedTargets(reading: reads)
            #expect(listed == screen.links)
        }
    }

    /// Attached after OpenCode finished its reply, the repaint shows its URL
    /// cut after the last `/` and the stream only sees the head cut by a
    /// cursor move; once the transcript runs it on, the head is no link of
    /// its own. Rows from a capture of OpenCode 1.19 at 60 columns.
    @Test func aHeadTheTranscriptRunsOnGivesWayAfterARepaint() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)
        let target = "https://example.com/waycar/untested/averyveryverylongsegmentname"
        let head: String = "     Read https://example.com/waycar/untested/"
        let rest: String = "     averyveryverylongsegmentname now."
        let rows: [String] = [
            head.padding(toLength: 57, withPad: " ", startingAt: 0) + "█",
            rest.padding(toLength: 57, withPad: " ", startingAt: 0) + "█",
        ]

        try await showRows(rows, columns: 60, on: store, transport)
        #expect(store.attachLinks.map(\.target) == ["https://example.com/waycar/untested/"])

        store.receiveTranscript(Self.foundTranscript(["Read \(target) now."]))
        try await waitUntil("the transcript should run the head on") {
            store.attachLinks.map(\.target) == [target]
        }
        await store.leave().value
    }

    /// An ellipsis, arrow, bullet or box rule glued to a URL ends it, and
    /// Markdown emphasis or a code span around it is not part of it; an
    /// internationalized host's letters are.
    @Test func glyphsAndMarkdownAroundAURLAreNotPartOfIt() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        try await goLive(store, transport)
        store.viewportTextDidChange(
            """
            │ https://x.com/box│
            see https://x.com/ellipsis… more
            https://x.com/arrow→next
            •https://x.com/bullet
            **https://x.com/bold**
            `https://x.com/tick`
            ⎿ https://bücher.de/x
            """)

        #expect(
            store.attachLinks.map(\.target) == [
                "https://bücher.de/x",
                "https://x.com/tick",
                "https://x.com/bold",
                "https://x.com/bullet",
                "https://x.com/arrow",
                "https://x.com/ellipsis",
                "https://x.com/box",
            ])

        await store.leave().value
    }

    @Test func osc8TargetsReuseWebValidationAndCollectionBounds() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)
        let prefix = "https://bounded.example/"
        let maximumTarget =
            prefix
            + String(
                repeating: "a",
                count: 32 * 1024 - prefix.utf8.count)
        let oversizedTarget = maximumTarget + "b"

        try await goLive(store, transport)

        await emitOSC8(
            maximumTarget, label: "maximum", transport: transport)
        await emitOSC8(
            oversizedTarget, label: "oversized", transport: transport)
        await emitOSC8(
            "file:///tmp/result", label: "unsafe", transport: transport)
        await emitOSC8(
            "https:///missing-host", label: "missing", transport: transport)

        try await waitUntil("only the maximum valid target should be observed") {
            store.attachLinks.map(\.target) == [maximumTarget]
        }

        for index in 0..<21 {
            await emitOSC8(
                "https://example.com/item/\(index)",
                label: "item \(index)",
                transport: transport)
        }

        try await waitUntil("OSC targets should use the same bounded collection") {
            store.attachLinks.count == 20
                && store.attachLinks.first?.target == "https://example.com/item/20"
        }
        #expect(store.attachLinks.last?.target == "https://example.com/item/1")
        #expect(!store.attachLinks.contains { $0.target == maximumTarget })

        await store.leave().value
    }

    @Test func exactRepeatsMoveToFrontAndTheLeastRecentLinkIsEvicted() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        try await goLive(store, transport)

        for index in 0..<21 {
            await transport.emitAttachOutput(
                Data("https://example.com/item?index=\(index)#detail\n".utf8))
        }
        await transport.emitAttachOutput(
            Data("https://example.com/item?index=1#detail\n".utf8))

        try await waitUntil("the bounded collection should settle") {
            store.attachLinks.count == 20
                && store.attachLinks.first?.target
                    == "https://example.com/item?index=1#detail"
        }
        #expect(
            !store.attachLinks.contains {
                $0.target == "https://example.com/item?index=0#detail"
            })
        #expect(
            store.attachLinks.contains {
                $0.target == "https://example.com/item?index=20#detail"
            })

        await store.leave().value
    }

    @Test func oneOutputChunkKeepsTheLatestLinksBeyondCollectionCapacity() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)
        let output = (0..<25)
            .map { "https://example.com/item/\($0)" }
            .joined(separator: "\n") + "\n"

        try await goLive(store, transport)

        await transport.emitAttachOutput(Data(output.utf8))

        try await waitUntil("the complete output chunk should be observed") {
            store.attachLinks.count == 20
                && store.attachLinks.first?.target == "https://example.com/item/24"
        }
        #expect(store.attachLinks.last?.target == "https://example.com/item/5")
        #expect(
            !store.attachLinks.contains {
                $0.target == "https://example.com/item/4"
            })

        await store.leave().value
    }

    @Test func targetAtTheByteLimitIsAcceptedAndAnOversizedTargetIsIgnoredWhole()
        async throws
    {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)
        let prefix = "https://example.com/"
        let maximumTarget =
            prefix
            + String(
                repeating: "a",
                count: 32 * 1024 - prefix.utf8.count)
        let oversizedTarget = maximumTarget + "b"

        try await goLive(store, transport)

        await transport.emitAttachOutput(Data((maximumTarget + "\n").utf8))
        await transport.emitAttachOutput(Data((oversizedTarget + "\n").utf8))
        await transport.emitAttachOutput(Data("https://example.com/sentinel\n".utf8))

        try await waitUntil("the output after the oversized target should be observed") {
            store.attachLinks.first?.target == "https://example.com/sentinel"
        }
        #expect(
            store.attachLinks.map(\.target) == [
                "https://example.com/sentinel",
                maximumTarget,
            ])

        await store.leave().value
    }

    @Test func balancedURLPunctuationIsRetainedWhileSurroundingPunctuationIsExcluded()
        async throws
    {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        try await goLive(store, transport)

        await transport.emitAttachOutput(
            Data(
                """
                Docs: (https://example.com/wiki/Function_(mathematics)).

                """.utf8))
        try await waitUntil("the literal target should be observed") {
            !store.attachLinks.isEmpty
        }
        #expect(
            store.attachLinks.map(\.target) == [
                "https://example.com/wiki/Function_(mathematics)"
            ])

        await store.leave().value
    }

    @Test func arbitraryOutputChunksJoinButRealLineBreaksDoNot() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        try await goLive(store, transport)

        await transport.emitAttachOutput(Data("Preview https://exa".utf8))
        await transport.emitAttachOutput(Data("mple.com/a/visually-".utf8))
        await transport.emitAttachOutput(Data("wrapped?q=1#result ".utf8))
        await transport.emitAttachOutput(Data("https://\nexample.com\n".utf8))

        try await waitUntil("the complete chunked target should be observed") {
            store.attachLinks.map(\.target) == [
                "https://example.com/a/visually-wrapped?q=1#result"
            ]
        }

        await store.leave().value
    }

    @Test func webPolicyRejectsUnsafeTargetsAndKeepsPrivateTargetsLiteral() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        try await goLive(store, transport)

        await transport.emitAttachOutput(
            Data(
                """
                file:///tmp/result https:///missing-host
                echo http://127.0.0.1:8443/path?q=x#fragment
                http://192.168.1.9:3000/private

                """.utf8))
        try await waitUntil("both literal private targets should be observed") {
            store.attachLinks.count == 2
        }
        #expect(
            store.attachLinks.map(\.target) == [
                "http://192.168.1.9:3000/private",
                "http://127.0.0.1:8443/path?q=x#fragment",
            ])

        await store.leave().value
    }

    @Test func linksSurviveTerminalRecoveryButLeavingAttachClearsThem() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        try await goLive(store, transport)
        await transport.emitAttachOutput(Data("https://before.example/retry\n".utf8))
        try await waitUntil("the first link should be observed") {
            store.attachLinks.count == 1
        }

        await transport.endAttachFromRemote()
        try await waitUntil("the terminal end should surface") {
            if case .ended = store.terminalStatus { return true }
            return false
        }
        store.retryTerminal()
        try await paint(transport)
        try await waitUntil("the terminal should retry") {
            store.terminalStatus == .live
        }
        #expect(store.attachLinks.map(\.target) == ["https://before.example/retry"])

        await transport.emitAttachOutput(Data("https://after.example/retry\n".utf8))
        try await waitUntil("the retry output should be observed") {
            store.attachLinks.count == 2
        }
        let terminalID = store.terminalID
        store.transportGenerationDidChange(1)
        try await waitUntil("the Transport replacement should land") {
            store.terminalID != terminalID
        }
        #expect(
            store.attachLinks.map(\.target) == [
                "https://after.example/retry",
                "https://before.example/retry",
            ])

        await store.leave().value
        #expect(store.attachLinks.isEmpty)

        let laterAttach = makeStore(transport: transport, generation: 1)
        #expect(laterAttach.attachLinks.isEmpty)
        await laterAttach.leave().value
    }

    @Test func printedImagePathsBecomeAttachMediaAcrossChunksAndSurviveRecovery()
        async throws
    {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        try await goLive(store, transport)
        await transport.emitAttachOutput(Data("⏺ Read(/tmp/sh".utf8))
        // The cell's closing `│` (E2 94 82) is split across chunks.
        await transport.emitAttachOutput(
            Data("ot.png)\n│ \u{1B}[1m~/Desktop/after.png\u{1B}[0m".utf8) + Data([0xE2]))
        await transport.emitAttachOutput(Data([0x94, 0x82, 0x0A]))
        await transport.emitAttachOutput(
            Data(
                "\u{1B}]8;;file:///Users/me/hidden.png\u{07}out/linked.png\u{1B}]8;;\u{07}\n"
                    .utf8))
        await transport.emitAttachOutput(
            Data("logo.png and/or out/*.png https://cdn.example/a.png\nwrote out/final.png".utf8))
        try await waitUntil("the ended words should be observed") {
            store.attachLinks.count == 1
                && store.attachMediaCandidates.map(\.path) == [
                    "out/linked.png",
                    "~/Desktop/after.png",
                    "/tmp/shot.png",
                ]
        }
        #expect(store.attachLinks.map(\.target) == ["https://cdn.example/a.png"])

        await transport.endAttachFromRemote()
        try await waitUntil("the end of output should finish the last path") {
            store.attachMediaCandidates.first?.path == "out/final.png"
        }
        try await waitUntil("the terminal end should surface") {
            if case .ended = store.terminalStatus { return true }
            return false
        }
        store.retryTerminal()
        try await paint(transport)
        try await waitUntil("the terminal should retry") {
            store.terminalStatus == .live
        }
        #expect(
            store.attachMediaCandidates.map(\.path) == [
                "out/final.png",
                "out/linked.png",
                "~/Desktop/after.png",
                "/tmp/shot.png",
            ])

        await store.leave().value
        #expect(store.attachMediaCandidates.isEmpty)
    }

    @Test func viewportImagePathsJoinAttachMediaBesideLinks() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)
        let screen = """
            │ File              │ Status │
            │ docs/screen.png   │ saved  │
            |/tmp/piped.png|
            ⎿  Wrote logo.png, see https://docs.example/a.png
            """

        try await goLive(store, transport)
        store.viewportTextDidChange(screen)

        #expect(store.attachMediaCandidates.map(\.path) == ["/tmp/piped.png", "docs/screen.png"])
        #expect(store.attachLinks.map(\.target) == ["https://docs.example/a.png"])

        store.viewportTextDidChange(screen)
        #expect(store.attachMediaCandidates.map(\.path) == ["/tmp/piped.png", "docs/screen.png"])

        await transport.emitAttachOutput(Data("saved /tmp/stream.png\n".utf8))
        try await waitUntil("a later stream path should lead") {
            store.attachMediaCandidates.map(\.path)
                == ["/tmp/stream.png", "/tmp/piped.png", "docs/screen.png"]
        }

        await store.leave().value
        #expect(store.attachMediaCandidates.isEmpty)
        store.viewportTextDidChange(screen)
        #expect(store.attachMediaCandidates.isEmpty)
    }

    /// The viewport reads rows against the live grid's width, so a path
    /// broken at its edge is found whole, and the tail alone is not.
    @Test func viewportRejoinsAnImagePathBrokenAtTheGridEdge() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)
        let head = "⏺ Saved /Users/me/project/assets/"

        try await goLive(store, transport, cols: head.count, rows: 24)
        store.viewportTextDidChange(head + "\nads/reddit/ad-02.png\n")

        #expect(
            store.attachMediaCandidates == [
                AttachMediaCandidate(
                    path: "/Users/me/project/assets/ads/reddit/ad-02.png", sightings: 1,
                    kind: .image)
            ])

        await store.leave().value
    }

    @Test func transportReplacementStopsTheOldTerminalBeforeReattaching() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)
        let initialID = store.terminalID

        try await goLive(store, transport)

        store.transportGenerationDidChange(1)
        try await waitUntil("the terminal pipeline should be replaced") {
            store.terminalID != initialID
        }
        #expect(await transport.hasLiveAttachSession == false)

        try await goLive(store, transport, cols: 100, rows: 30)
        #expect(await transport.attachRequests.count == 2)

        await store.leave().value
    }

    @Test func rapidTransportReplacementsCoalesceToTheLatestGeneration() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)
        let initialID = store.terminalID

        try await goLive(store, transport)

        store.transportGenerationDidChange(1)
        store.transportGenerationDidChange(2)
        try await waitUntil("the latest replacement should land") {
            store.terminalID != initialID
        }
        try await goLive(store, transport, cols: 100, rows: 30)
        #expect(await transport.attachRequests.count == 2)

        await store.leave().value
    }

    /// A stale queued replacement must not hide recovery owned by the latest
    /// Transport generation. Both changes arrive in one MainActor turn: the
    /// first observes that it is stale, while the second remains parked in the
    /// predecessor PTY's explicit teardown.
    @Test func rapidTransportReplacementsKeepLatestRecoveryVisibleUntilTeardownFinishes()
        async throws
    {
        let transport = ScriptedTransport()
        let endGate = ScriptedTransportCallGate()
        await transport.gateNextAttachEnd(on: endGate)
        let store = makeStore(transport: transport, generation: 0)
        let initialID = store.terminalID

        try await goLive(store, transport)

        store.transportGenerationDidChange(1)
        #expect(store.terminalStatus == .connecting)
        store.transportGenerationDidChange(2)
        #expect(store.terminalStatus == .connecting)

        try await waitUntil("the latest replacement should reach the old PTY teardown") {
            await endGate.entryCount == 1
        }
        #expect(store.terminalID == initialID)
        #expect(
            store.terminalStatus == .connecting,
            "stale replacement cleanup must not expose the predecessor's live presentation")
        #expect(await transport.attachRequests.count == 1)

        await endGate.open()
        try await waitUntil("the latest replacement should land") {
            store.terminalID != initialID
        }
        #expect(
            store.terminalStatus == .waitingForSize,
            "completed recovery must not leave a stale Connecting overlay")

        try await goLive(store, transport, cols: 100, rows: 30)
        #expect(await transport.attachRequests.count == 2)
        #expect(store.terminalStatus == .live)

        await store.leave().value
    }

    /// SwiftUI may pair the foreground recovery with a synchronous
    /// disappear/appear transaction. The returning screen still owns the
    /// recovery presentation while the predecessor PTY is ending; exposing
    /// that predecessor's `.live` status here produces a silent black screen.
    @Test func leaveAndRejoinDuringRecoveryStaysConnectingUntilTheLatestPipelineLands()
        async throws
    {
        let transport = ScriptedTransport()
        let endGate = ScriptedTransportCallGate()
        await transport.gateNextAttachEnd(on: endGate)
        let store = makeStore(transport: transport, generation: 0)
        let predecessorID = store.terminalID

        try await goLive(store, transport)

        store.didBecomeActive(afterPossibleSuspension: true)
        try await waitUntil("recovery should reach the predecessor PTY teardown") {
            await endGate.entryCount == 1
        }
        #expect(store.terminalID == predecessorID)
        #expect(store.terminalStatus == .connecting)

        // Stack several newer Transport generations behind the suspended
        // recovery. None of their stale cleanup paths may take presentation
        // ownership from the later rejoin.
        store.transportGenerationDidChange(1)
        store.transportGenerationDidChange(2)
        store.transportGenerationDidChange(3)

        let leaveTask = store.leave()
        store.rejoin()

        #expect(store.terminalID == predecessorID)
        #expect(
            store.terminalStatus == .connecting,
            "the returning screen must retain recovery while its predecessor is still ending")
        #expect(await transport.attachRequests.count == 1)

        await endGate.open()
        await leaveTask.value
        try await waitUntil("the rejoined pipeline should supersede the recovery pipeline") {
            store.terminalID != predecessorID && store.terminalStatus == .waitingForSize
        }
        #expect(
            store.terminalStatus == .waitingForSize,
            "completed recovery must not retain a stale Connecting overlay")

        try await goLive(store, transport, cols: 100, rows: 30)
        #expect(await transport.attachRequests.count == 2)
        #expect(store.terminalStatus == .live)

        await store.leave().value
    }

    @Test func staleRecoveryCannotPublishATerminalAfterLeaveAndRejoinChangesOwner()
        async throws
    {
        let transport = ScriptedTransport()
        let terminalEndGate = ScriptedTransportCallGate()
        await transport.gateNextAttachEnd(on: terminalEndGate)
        let imageGate = ScriptedTransportCallGate()
        let imageStager = GatedAttachImageStager(gate: imageGate)
        let stage = SelectedPane(current: "w1:p1")
        let store = makeStore(
            transport: transport, generation: 0,
            isOnStage: { stage.contains("w1:p1") },
            stageImage: { image, reporter in
                try await imageStager.stage(image, reporter)
            })

        try await goLive(store, transport)
        let predecessorID = store.terminalID

        // Keep the later real leave suspended after the stale recovery gets
        // its publication opportunity. This exposes the exact pipeline that a
        // render pass could resize before the latest rejoin replaces it.
        store.staging.begin(.photo(DataImageSelection(data: try tinyJPEGData())))
        try await waitUntil("image staging should be pending") {
            await imageStager.preparedFileURL != nil
        }
        store.didBecomeActive(afterPossibleSuspension: true)
        try await waitUntil("recovery should wait for predecessor teardown") {
            await terminalEndGate.entryCount == 1
        }

        // This is a real owner change, not the delayed on-stage disappear that
        // possible-suspension recovery deliberately absorbs.
        stage.current = "w1:p2"
        let leaveTask = store.leave()
        stage.current = "w1:p1"
        store.rejoin()
        await terminalEndGate.open()
        try await waitUntil("the real leave should cancel image staging") {
            await imageStager.cancellationRequestCount == 1
        }

        #expect(
            store.terminalID == predecessorID,
            "a recovery that lost ownership must not publish an intermediate terminal")
        store.viewDidResize(cols: 100, rows: 30)

        await imageGate.open()
        await leaveTask.value
        try await waitUntil("the latest rejoin should publish its terminal") {
            store.terminalID != predecessorID
        }
        try await goLive(store, transport, cols: 100, rows: 30)
        #expect(
            await transport.attachRequests.count == 2,
            "only the predecessor and latest rejoin may open Attach channels")

        await store.leave().value
    }

    @Test func staleRejoinCannotPublishATerminalAfterANewerLeaveAndRejoin()
        async throws
    {
        let transport = ScriptedTransport()
        let terminalEndGate = ScriptedTransportCallGate()
        await transport.gateNextAttachEnd(on: terminalEndGate)
        let imageGate = ScriptedTransportCallGate()
        let imageStager = GatedAttachImageStager(gate: imageGate)
        let store = makeStore(
            transport: transport, generation: 0,
            stageImage: { image, reporter in
                try await imageStager.stage(image, reporter)
            })

        try await goLive(store, transport)
        let predecessorID = store.terminalID

        let firstLeaveTask = store.leave()
        store.rejoin()
        try await waitUntil("the first leave should wait for predecessor teardown") {
            await terminalEndGate.entryCount == 1
        }

        // The terminal input session remains live until teardown completes, so
        // this real image operation can hold the newer leave immediately after
        // the stale rejoin's publication point.
        store.staging.begin(.photo(DataImageSelection(data: try tinyJPEGData())))
        try await waitUntil("image staging should be pending") {
            await imageStager.preparedFileURL != nil
        }
        let latestLeaveTask = store.leave()
        store.rejoin()

        await terminalEndGate.open()
        await firstLeaveTask.value
        try await waitUntil("the newer leave should cancel image staging") {
            await imageStager.cancellationRequestCount == 1
        }

        #expect(
            store.terminalID == predecessorID,
            "a rejoin that lost ownership must not publish an intermediate terminal")
        store.viewDidResize(cols: 100, rows: 30)

        await imageGate.open()
        await latestLeaveTask.value
        try await waitUntil("the latest rejoin should publish its terminal") {
            store.terminalID != predecessorID
        }
        try await goLive(store, transport, cols: 100, rows: 30)
        #expect(
            await transport.attachRequests.count == 2,
            "only the predecessor and latest rejoin may open Attach channels")

        await store.leave().value
    }

    @Test func transportReplacementPreservesComposerStagingState() async throws {
        // A reconnect replaces the terminal pipeline but must not touch the
        // staging interaction: its stager resolves the live Transport per
        // call, so surfaced failures and results stay actionable.
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        try await goLive(store, transport)

        // One byte of garbage: preparation fails and the failure surfaces.
        store.staging.begin(.photo(DataImageSelection(data: Data([0x01]))))
        try await waitUntil("the failed staging operation should surface") {
            if case .failed = store.staging.state { true } else { false }
        }
        let surfacedFailure = store.staging.state
        let initialID = store.terminalID

        store.transportGenerationDidChange(1)
        try await waitUntil("the terminal pipeline should be replaced") {
            store.terminalID != initialID
        }

        #expect(store.staging.state == surfacedFailure)

        await store.leave().value
        #expect(store.staging.state == .idle)
    }

    /// Agent detail builds a placeholder Attach (and, on every re-render, a
    /// throwaway one) before retention swaps the real one in. Only the screen
    /// binds the Composer Tray, so the placeholder's queued teardown — which
    /// lands after the successor's screen bound — must leave it running.
    @Test func placeholderTeardownLeavesTheSuccessorsTrayRunning() async throws {
        let transport = ScriptedTransport()
        let composer = makeComposer()
        let placeholder = makeStore(
            transport: transport, generation: 0,
            stageImage: { _, _ in try StagedImage(path: "/tmp/placeholder.jpg") },
            composer: composer)
        composer.bindStaging(placeholder.staging)
        let successor = makeStore(
            transport: transport, generation: 0,
            stageImage: { _, _ in try StagedImage(path: "/tmp/successor.jpg") },
            composer: composer)

        let placeholderTeardown = placeholder.leaveForTerminalHandoff()
        composer.bindStaging(successor.staging)
        _ = makeStore(
            transport: transport, generation: 0,
            stageImage: { _, _ in try StagedImage(path: "/tmp/throwaway.jpg") },
            composer: composer)
        await placeholderTeardown.value

        composer.tray.add([.photo(DataImageSelection(data: try tinyJPEGData()))])
        try await waitUntil("the item should stage on the successor's Attach") {
            composer.tray.readyPaths == ["/tmp/successor.jpg"]
        }
        #expect(!composer.tray.blocksSend)

        await successor.leave().value
    }

    /// A retained Attach comes back still `.active` (`AgentTerminalCache`'s
    /// activate): its rejoin must resume the tray its retention suspended.
    @Test func retainedRejoinResumesTheTraysQueuedItem() async throws {
        let transport = ScriptedTransport()
        let composer = makeComposer()
        let store = makeStore(
            transport: transport, generation: 0,
            stageImage: { _, _ in try StagedImage(path: "/tmp/retained.jpg") },
            composer: composer)
        composer.bindStaging(store.staging)
        try await goLive(store, transport)
        let liveID = store.terminalID

        await store.leaveInteractionsForRetention().value
        composer.tray.add([.photo(DataImageSelection(data: try tinyJPEGData()))])
        #expect(
            composer.tray.items.map(\.status) == [.queued],
            "a released Attach starts no upload")

        store.rejoin()
        try await waitUntil("the queued item should stage after the retained rejoin") {
            composer.tray.readyPaths == ["/tmp/retained.jpg"]
        }
        #expect(store.terminalID == liveID, "the retained PTY stays the same pipeline")
        #expect(store.terminalStatus == .live)
        #expect(await transport.attachRequests.count == 1)

        await store.leave().value
    }

    /// A quick return can rejoin before the retention teardown has run; the
    /// resume queues behind it instead of being undone by its suspension.
    @Test func retainedRejoinLandsAfterThePendingRetentionTeardown() async throws {
        let transport = ScriptedTransport()
        let composer = makeComposer()
        let store = makeStore(
            transport: transport, generation: 0,
            stageImage: { _, _ in try StagedImage(path: "/tmp/returned.jpg") },
            composer: composer)
        composer.bindStaging(store.staging)
        try await goLive(store, transport)

        let retention = store.leaveInteractionsForRetention()
        store.rejoin()
        await retention.value
        composer.tray.add([.photo(DataImageSelection(data: try tinyJPEGData()))])

        try await waitUntil("the item should stage once the rejoin has landed") {
            composer.tray.readyPaths == ["/tmp/returned.jpg"]
        }

        await store.leave().value
    }

    @Test func leaveDuringQueuedReplacementDoesNotResurrectTheTerminal() async throws {
        // leave() can race in behind a queued transport replacement; the
        // replacement must observe it and never rebuild the pipeline.
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        try await goLive(store, transport)
        let initialID = store.terminalID

        store.transportGenerationDidChange(1)
        await store.leave().value

        #expect(store.terminalID == initialID)
        #expect(store.terminalStatus == .stopped)
        #expect(await transport.hasLiveAttachSession == false)
        #expect(await transport.attachRequests.count == 1)

        // Generation changes arriving after leave must stay dead too.
        store.transportGenerationDidChange(2)
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.terminalID == initialID)
        #expect(await transport.attachRequests.count == 1)
    }

    @Test func rejoinAfterLeaveReattachesTheScreenThatCameBack() async throws {
        // onDisappear/onAppear are not always a real departure and return:
        // SwiftUI hands out removals the user never made, and the state that
        // comes back is the one that left. The store that comes back must
        // attach again instead of staying stopped behind a black surface.
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        try await goLive(store, transport)
        let leftID = store.terminalID

        await store.leave().value
        #expect(store.terminalStatus == .stopped)

        store.rejoin()
        // The screen is on stage again, so it must never read as a finished
        // session while the replacement is on its way.
        #expect(store.terminalStatus == .connecting)
        try await waitUntil("the terminal pipeline should be rebuilt") {
            store.terminalID != leftID
        }

        try await goLive(store, transport)
        #expect(await transport.attachRequests.count == 2)

        // The rejoined pipeline is wired end to end, not just opened.
        await transport.emitAttachOutput(Data("https://example.com/back\n".utf8))
        try await waitUntil("output should reach the rejoined screen") {
            store.attachLinks.map(\.target) == ["https://example.com/back"]
        }

        await store.leave().value
    }

    @Test func sameTransactionDisappearAppearPairComesBackConnecting() async throws {
        // SwiftUI can hand the spurious disappear/appear pair out
        // back-to-back in one transaction (a notification deep link or the
        // new-agent push landing amid sheet-dismissal churn). The departure
        // must be recorded synchronously: a Task-deferred leave() runs only
        // after rejoin() has already no-opped in the active lifecycle state,
        // and the visible screen keeps a permanently stopped terminal — black,
        // no overlay, no recovery.
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        try await goLive(store, transport)
        let leftID = store.terminalID

        store.leave()
        store.rejoin()

        // On stage throughout: never a black surface with nothing to say.
        #expect(store.terminalStatus != .stopped)
        try await waitUntil("the terminal pipeline should be rebuilt") {
            store.terminalID != leftID
        }

        try await goLive(store, transport)
        #expect(await transport.attachRequests.count == 2)

        await store.leave().value
    }

    @Test func foregroundMountChurnCannotStrandTheCurrentOnStageAttach() async throws {
        // The R3 device trace reached foreground after the predecessor had
        // already left. Its replacement view established a fresh terminal,
        // claimed the pending possible-suspension activation, then SwiftUI
        // delivered the mount's appear/disappear churn in the opposite order:
        // the appear was a no-op while active and the delayed disappear cleared
        // the queued recovery before stopping its terminal. The router still
        // named this Agent throughout, so the visible owner must recover rather
        // than remain permanently stopped.
        let transport = ScriptedTransport()
        let stage = SelectedPane(current: "w1:p1")
        let store = makeStore(
            transport: transport, generation: 0,
            isOnStage: { stage.contains("w1:p1") })

        try await goLive(store, transport)
        await store.leave().value
        let predecessorID = store.terminalID

        store.rejoin()
        try await waitUntil("the mounting view should establish a fresh terminal") {
            store.terminalID != predecessorID
        }
        let mountingTerminalID = store.terminalID

        store.didBecomeActive(afterPossibleSuspension: true)
        store.rejoin()
        store.leave()

        try await waitUntil("the current on-stage owner should replace the stopped terminal") {
            store.terminalID != mountingTerminalID
        }
        try #require(
            store.terminalID != mountingTerminalID,
            "the current on-stage owner was stranded on its stopped mounting terminal")
        try await waitUntil("the recovered owner should open one replacement Attach") {
            store.viewDidResize(cols: 80, rows: 24)
            return await transport.attachRequests.count == 2
        }
        #expect(await transport.emitAttachOutput(Data("recovered".utf8)))
        try await waitUntil("the visible replacement Attach should become live") {
            store.terminalStatus == .live
        }

        for _ in 0..<10 { await Task.yield() }
        #expect(store.terminalStatus == .live)
        #expect(await transport.attachRequests.count == 2)

        stage.current = "w1:p2"
        await store.leave().value
        #expect(await transport.hasLiveAttachSession == false)
    }

    @Test func queuedRejoinDoesNotBuildATerminalAfterTheRouteMovesOffStage() async throws {
        // A spurious disappear/appear can queue rejoin behind the old PTY's
        // teardown. The router may then select another Agent before this
        // view receives its real onDisappear, leaving the lifecycle active
        // while the queued operation becomes runnable. The route remains
        // authoritative.
        let transport = ScriptedTransport()
        let endGate = ScriptedTransportCallGate()
        await transport.gateNextAttachEnd(on: endGate)
        let stage = SelectedPane(current: "w1:p1")
        let store = makeStore(
            transport: transport, generation: 0,
            isOnStage: { stage.contains("w1:p1") })

        try await goLive(store, transport)
        let leftID = store.terminalID

        let leaveTask = store.leave()
        store.rejoin()
        try await waitUntil("the queued rejoin should wait behind PTY teardown") {
            await endGate.entryCount == 1
        }

        stage.current = "w1:p2"
        let routeChecksBeforeRelease = stage.readCount
        await endGate.open()
        await leaveTask.value

        // Either the queued operation rechecks the route, or the defective
        // implementation visibly replaces the terminal. This makes settling
        // deterministic on both sides of the TDD cycle without a time delay.
        try await waitUntil("the queued rejoin should settle") {
            stage.readCount > routeChecksBeforeRelease || store.terminalID != leftID
        }

        #expect(store.terminalID == leftID)
        #expect(store.terminalStatus == .stopped)
        #expect(await transport.attachRequests.count == 1)
        #expect(await transport.hasLiveAttachSession == false)

        await store.leave().value
    }

    @Test func fastRouteReturnAfterOffStageRejoinAbortBuildsANewTerminal() async throws {
        // SwiftUI can delay the departing screen's real onDisappear after a
        // spurious disappear/appear pair queued a rejoin. If the route moves
        // away while that rejoin waits for PTY teardown, the queued operation
        // must abort without making the later on-stage rejoin a no-op.
        let transport = ScriptedTransport()
        let endGate = ScriptedTransportCallGate()
        await transport.gateNextAttachEnd(on: endGate)
        let stage = SelectedPane(current: "w1:p1")
        let store = makeStore(
            transport: transport, generation: 0,
            isOnStage: { stage.contains("w1:p1") })

        try await goLive(store, transport)
        let leftID = store.terminalID

        let leaveTask = store.leave()
        store.rejoin()
        try await waitUntil("the queued rejoin should wait behind PTY teardown") {
            await endGate.entryCount == 1
        }

        stage.current = "w1:p2"
        let routeChecksBeforeRelease = stage.readCount
        await endGate.open()
        await leaveTask.value
        try await waitUntil("the queued rejoin should abort off stage") {
            stage.readCount > routeChecksBeforeRelease
        }

        #expect(store.terminalID == leftID)
        #expect(store.terminalStatus == .stopped)
        #expect(await transport.attachRequests.count == 1)
        #expect(await transport.hasLiveAttachSession == false)

        // The route returns before SwiftUI delivers the delayed onDisappear.
        // No second leave() records the departure for us: rejoin itself must recover
        // the stopped pipeline instead of leaving a permanent Connecting view.
        stage.current = "w1:p1"
        store.rejoin()
        #expect(store.terminalStatus == .connecting)
        try await waitUntil("the returned screen should build a terminal") {
            store.terminalID != leftID
        }

        try await goLive(store, transport)
        #expect(store.terminalStatus == .live)
        #expect(await transport.attachRequests.count == 2)

        await store.leave().value
    }

    @Test func fastRouteReturnAfterPreStopRecoveryAbortReplacesTheWholeTerminal() async throws {
        // Recovery is scheduled while this screen owns the route, but its
        // queued operation may not run until after the route moved away. The
        // first guard then aborts before stopping the predecessor. Returning
        // before delayed onDisappear must still replace that untrusted `.live`
        // pipeline rather than making rejoin() a no-op.
        let transport = ScriptedTransport()
        let endGate = ScriptedTransportCallGate()
        await transport.gateNextAttachEnd(on: endGate)
        let stage = SelectedPane(current: "w1:p1")
        let store = makeStore(
            transport: transport, generation: 0,
            isOnStage: { stage.contains("w1:p1") })

        try await goLive(store, transport)
        let predecessorID = store.terminalID

        store.didBecomeActive(afterPossibleSuspension: true)
        let routeChecksBeforeAbort = stage.readCount
        stage.current = "w1:p2"
        try await waitUntil("recovery should hit its first guard off stage") {
            stage.readCount > routeChecksBeforeAbort
        }

        #expect(store.terminalID == predecessorID)
        #expect(await transport.attachRequests.count == 1)

        stage.current = "w1:p1"
        store.rejoin()
        #expect(
            store.terminalStatus == .connecting,
            "the returned screen must not expose its untrusted predecessor as live")
        try await waitUntil("the returned screen should stop the whole predecessor pipeline") {
            await endGate.entryCount == 1
        }

        await endGate.open()
        try await waitUntil("the returned screen should build a terminal") {
            store.terminalID != predecessorID
        }
        try await goLive(store, transport)

        #expect(store.terminalStatus == .live)
        #expect(await transport.attachRequests.count == 2)

        await store.leave().value
    }

    @Test func fastRouteReturnAfterOffStageRecoveryAbortBuildsANewTerminal() async throws {
        // A possible-suspension recovery can stop its predecessor while the
        // router moves this screen off stage, before SwiftUI delivers the
        // corresponding onDisappear. If the route returns just as quickly,
        // rejoin must be able to replace that now-stopped pipeline.
        let transport = ScriptedTransport()
        let endGate = ScriptedTransportCallGate()
        await transport.gateNextAttachEnd(on: endGate)
        let stage = SelectedPane(current: "w1:p1")
        let store = makeStore(
            transport: transport, generation: 0,
            isOnStage: { stage.contains("w1:p1") })

        try await goLive(store, transport)
        let predecessorID = store.terminalID

        store.didBecomeActive(afterPossibleSuspension: true)
        try await waitUntil("recovery should wait for the predecessor PTY to end") {
            await endGate.entryCount == 1
        }

        stage.current = "w1:p2"
        let routeChecksBeforeRelease = stage.readCount
        await endGate.open()
        try await waitUntil("recovery should observe the authoritative off-stage route") {
            stage.readCount > routeChecksBeforeRelease
        }

        #expect(store.terminalID == predecessorID)
        #expect(store.terminalStatus == .stopped)
        #expect(await transport.attachRequests.count == 1)
        #expect(await transport.hasLiveAttachSession == false)

        // The route returns before a delayed onDisappear can call leave().
        stage.current = "w1:p1"
        store.rejoin()
        #expect(store.terminalStatus == .connecting)
        try await waitUntil("the returned screen should build a terminal") {
            store.terminalID != predecessorID
        }

        try await goLive(store, transport)
        #expect(store.terminalStatus == .live)
        #expect(await transport.attachRequests.count == 2)

        await store.leave().value
    }

    @Test func delayedLeaveAfterRecoveryAbortStillCleansTheWholeAttachInteraction()
        async throws
    {
        // A recovery that stopped its predecessor can abort off stage before
        // SwiftUI delivers the real onDisappear. The abort must make rejoin
        // possible without pretending leave cleanup already ran: that delayed
        // leave still owns links and staging preparation.
        let transport = ScriptedTransport()
        let terminalEndGate = ScriptedTransportCallGate()
        await transport.gateNextAttachEnd(on: terminalEndGate)
        let imageGate = ScriptedTransportCallGate()
        let imageStager = GatedAttachImageStager(gate: imageGate)
        let opener = CancellationAwareAttachLinkOpener()
        let stage = SelectedPane(current: "w1:p1")
        let store = makeStore(
            transport: transport, generation: 0,
            isOnStage: { stage.contains("w1:p1") },
            stageImage: { image, reporter in
                try await imageStager.stage(image, reporter)
            })

        try await goLive(store, transport)
        await transport.emitAttachOutput(Data("https://example.com/leave-cleanup\n".utf8))
        try await waitUntil("the link should be collected") {
            store.attachLinks.count == 1
        }
        let link = try #require(store.attachLinks.first)
        store.openAttachLink(link, using: opener.open)
        try await waitUntil("the system open should be pending") {
            opener.pendingTarget == link.target
        }

        store.staging.begin(.photo(DataImageSelection(data: try tinyJPEGData())))
        try await waitUntil("image staging should retain its prepared file") {
            await imageStager.preparedFileURL != nil
        }
        let preparedFileURL = try #require(await imageStager.preparedFileURL)
        #expect(FileManager.default.fileExists(atPath: preparedFileURL.path))

        let predecessorID = store.terminalID
        store.didBecomeActive(afterPossibleSuspension: true)
        try await waitUntil("recovery should wait for the predecessor PTY to end") {
            await terminalEndGate.entryCount == 1
        }

        stage.current = "w1:p2"
        let routeChecksBeforeRelease = stage.readCount
        await terminalEndGate.open()
        try await waitUntil("recovery should abort after stopping off stage") {
            stage.readCount > routeChecksBeforeRelease
        }
        #expect(store.terminalID == predecessorID)
        #expect(store.terminalStatus == .stopped)

        let leaveTask = store.leave()
        try await waitUntil("leave should clear links and cancel the pending opener") {
            store.attachLinks.isEmpty && opener.cancelledTargets == [link.target]
        }

        await imageGate.open()
        await leaveTask.value
        try await waitUntil("staging leave cleanup should settle") {
            store.staging.state == .idle
        }

        #expect(store.staging.state == .idle)
        #expect(!FileManager.default.fileExists(atPath: preparedFileURL.path))
        #expect(await imageStager.cancellationCount == 1)

        // Repeated leave observes the same completed cleanup rather than
        // cancelling or clearing any boundary a second time.
        await store.leave().value
        #expect(opener.cancelledTargets == [link.target])
        #expect(await imageStager.cancellationCount == 1)

        opener.resolvePending(accepted: false)
        if let id = store.staging.activeOperationID { store.staging.cancel(operationID: id) }
    }

    @Test func delayedRealLeaveAfterRecoveryAbortCancelsReviewedPaste() async throws {
        let transport = ScriptedTransport()
        let terminalEndGate = ScriptedTransportCallGate()
        await transport.gateNextAttachEnd(on: terminalEndGate)
        let stage = SelectedPane(current: "w1:p1")
        let store = makeStore(
            transport: transport, generation: 0,
            isOnStage: { stage.contains("w1:p1") })
        let text = "git status\ngit diff"

        try await goLive(store, transport)
        store.requestPaste(text, bracketedPaste: true)
        #expect(store.pendingPaste != nil)

        store.didBecomeActive(afterPossibleSuspension: true)
        try await waitUntil("recovery should wait for predecessor teardown") {
            await terminalEndGate.entryCount == 1
        }
        stage.current = "w1:p2"
        let routeChecksBeforeRelease = stage.readCount
        await terminalEndGate.open()
        try await waitUntil("recovery should abort after stopping off stage") {
            stage.readCount > routeChecksBeforeRelease
        }
        #expect(store.pendingPaste != nil)

        await store.leave().value
        #expect(
            store.pendingPaste == nil,
            "a real departure must clear Paste even after replacement detached its writer")

        stage.current = "w1:p1"
        store.rejoin()
        let stoppedID = store.terminalID
        try await waitUntil("the later rejoin should publish a terminal") {
            store.terminalID != stoppedID
        }
        try await goLive(store, transport)
        #expect(!store.canConfirmPaste)
        store.confirmPaste()
        #expect(await transport.attachInputs.compactMap { input -> Data? in
            if case .keystrokes(let data) = input { return data }
            return nil
        }.isEmpty)

        await store.leave().value
    }

    @Test func offStageSizeReportDoesNotStartARejoinedTerminal() async throws {
        // Rejoin legitimately builds a fresh pipeline while this Agent is on
        // stage. If the route changes before SwiftUI's departing view reports
        // its next size, that callback must not open an invisible Attach.
        let transport = ScriptedTransport()
        let endGate = ScriptedTransportCallGate()
        await transport.gateNextAttachEnd(on: endGate)
        let stage = SelectedPane(current: "w1:p1")
        let store = makeStore(
            transport: transport, generation: 0,
            isOnStage: { stage.contains("w1:p1") })

        try await goLive(store, transport)
        let leftID = store.terminalID

        let leaveTask = store.leave()
        store.rejoin()
        try await waitUntil("the rejoin should wait behind PTY teardown") {
            await endGate.entryCount == 1
        }
        await endGate.open()
        await leaveTask.value
        try await waitUntil("the on-stage rejoin should build its terminal") {
            store.terminalID != leftID
        }
        #expect(store.terminalStatus == .waitingForSize)

        stage.current = "w1:p2"
        store.viewDidResize(cols: 100, rows: 30)

        #expect(store.terminalStatus == .waitingForSize)
        #expect(await transport.attachRequests.count == 1)
        #expect(await transport.hasLiveAttachSession == false)

        await store.leave().value
    }

    @Test func teardownRunsEvenAfterTheStoreItselfIsReleased() async throws {
        // The owner is `@State` on a view SwiftUI discards right after
        // `onDisappear`, so the teardown task is often the store's last
        // holder. It must run to completion regardless — a skipped teardown
        // leaves the live session holding the Host's only terminal channel,
        // and every later attach queues behind it forever.
        let transport = ScriptedTransport()
        var store: AgentAttachStore? = makeStore(transport: transport, generation: 0)
        try await goLive(store!, transport)

        store!.leave()
        store = nil  // SwiftUI discarding the view's state.

        try await waitUntil("the session must end without its owner") {
            await transport.hasLiveAttachSession == false
        }
    }

    @Test func aSpuriousReappearanceOffStageDoesNotResurrectTheTerminal() async throws {
        // The same disappear/appear pair also lands on *departing* screens
        // (an Agent switch, a notification deep link), whose views keep
        // laying out through the exit transition. A rebuilt pipeline there
        // would attach unseen and hold the Host's only terminal channel.
        let transport = ScriptedTransport()
        let stage = SelectedPane(current: "w1:p1")
        let store = makeStore(
            transport: transport, generation: 0,
            isOnStage: { stage.current == "w1:p1" })

        try await goLive(store, transport)
        let leftID = store.terminalID

        // The Console moves to another Agent; churn hands this screen a
        // spurious pair while its view keeps reporting sizes on the way out.
        stage.current = "w1:p2"
        store.leave()
        store.rejoin()
        for _ in 0..<20 {
            store.viewDidResize(cols: 100, rows: 30)
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(store.terminalID == leftID)
        #expect(store.terminalStatus == .stopped)
        #expect(await transport.attachRequests.count == 1)
        #expect(await transport.hasLiveAttachSession == false)
    }

    @Test func aDepartingScreensChurnCannotStarveTheNextScreensAttach() async throws {
        // The stuck-Connecting regression: the Host has one terminal channel
        // and attaches queue FIFO behind it (EventsSession's permit). A
        // departing screen resurrected by the spurious pair would take that
        // channel unseen, and the screen the user is actually looking at
        // would wait on "Connecting…" forever.
        let transport = ScriptedTransport()
        let permit = TerminalChannelPermit()
        let stage = SelectedPane(current: "w1:p1")
        let runner = permitGatedRunner(transport, permit)

        let departing = makeStore(
            transport: transport, generation: 0, target: "w1:p1",
            isOnStage: { stage.current == "w1:p1" }, runTerminal: runner)
        try await goLive(departing, transport)

        stage.current = "w1:p2"
        departing.leave()
        departing.rejoin()
        for _ in 0..<20 {
            departing.viewDidResize(cols: 100, rows: 30)
            try await Task.sleep(for: .milliseconds(5))
        }
        try await waitUntil("the departing screen's attach should end") {
            await transport.hasLiveAttachSession == false
        }

        let incoming = makeStore(
            transport: transport, generation: 0, target: "w1:p2",
            isOnStage: { stage.current == "w1:p2" }, runTerminal: runner)
        try await goLive(incoming, transport)

        // The channel went to the screen on stage, never to a zombie.
        #expect(
            await transport.attachRequests.map(\.target)
                == [.agentPane("w1:p1"), .agentPane("w1:p2")])

        await incoming.leave().value
    }

    @Test func rejoinWithoutLeaveLeavesTheLiveTerminalAlone() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        try await goLive(store, transport)
        let liveID = store.terminalID

        store.rejoin()
        try await Task.sleep(for: .milliseconds(50))

        #expect(store.terminalID == liveID)
        #expect(store.terminalStatus == .live)
        #expect(await transport.attachRequests.count == 1)

        await store.leave().value
    }

    @Test func leaveRacingARejoinKeepsTheAttachDown() async throws {
        // The reverse race of `leaveDuringQueuedReplacementDoesNotResurrect…`:
        // a rejoin already queued must not rebuild behind a later leave.
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)

        try await goLive(store, transport)

        await store.leave().value
        let leftID = store.terminalID
        store.rejoin()
        await store.leave().value

        try await Task.sleep(for: .milliseconds(50))
        #expect(store.terminalID == leftID)
        #expect(store.terminalStatus == .stopped)
        #expect(await transport.attachRequests.count == 1)
    }

    @Test func everyTerminalPresentsAnIdentityNoDiscardedTerminalEverHeld() {
        // The reconnect path is a teardown followed by a replacement moments
        // later, which is the allocation pattern most likely to hand the
        // replacement its predecessor's address. Building and dropping stores
        // in a tight loop is that pattern with the timing taken out: an
        // address-derived identity collapses onto a handful of reused values,
        // an identity the store owns cannot (#143).
        let transport = ScriptedTransport()
        var identities: [AnyHashable] = []
        for _ in 0..<200 {
            identities.append(
                AnyHashable(makeStore(transport: transport, generation: 0).terminalID))
        }

        #expect(Set(identities).count == 200)
    }

    @Test func aReplacedTerminalGetsASurfaceOfItsOwnThatItsBytesReach() async throws {
        // The identity's whole job: a replacement terminal must make SwiftUI
        // build a new surface, because `makeUIView` is the only place the new
        // feed is attached. A surface that is not rebuilt leaves the new
        // session writing into a feed with nowhere to go — bytes buffered
        // forever behind a stale screen, with the session reading as live.
        //
        // One replacement pins the identity being *per pipeline* rather than
        // shared, and nothing more: the predecessor is still held while the
        // replacement is allocated, so even an address could not collide here.
        // Address reuse needs two replacements between renders — see
        // `aTerminalTwoReplacementsPastTheLastRenderStillGetsASurfaceOfItsOwn`.
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)
        let stage = SurfaceIdentityStage()
        stage.update(id: store.terminalID, feed: store.terminalFeed)

        try await goLive(store, transport)
        await transport.emitAttachOutput(Data("before".utf8))
        try await waitUntil("the first session should reach the first surface") {
            stage.surfaces.last?.text.contains("before") == true
        }
        #expect(stage.surfaces.count == 1)

        let replacedID = store.terminalID
        store.transportGenerationDidChange(1)
        try await waitUntil("the terminal pipeline should be replaced") {
            store.terminalID != replacedID
        }

        stage.update(id: store.terminalID, feed: store.terminalFeed)
        #expect(stage.surfaces.count == 2)

        try await goLive(store, transport, cols: 100, rows: 30)
        await transport.emitAttachOutput(Data("after".utf8))
        try await waitUntil("the replacement's bytes should reach its own surface") {
            stage.surfaces.last?.text.contains("after") == true
        }
        #expect(stage.surfaces.first?.text.contains("after") == false)

        await store.leave().value
    }

    @Test func aTerminalTwoReplacementsPastTheLastRenderStillGetsASurfaceOfItsOwn() async throws {
        // SwiftUI does not compare a pipeline's identity against the live
        // predecessor — it compares against the identity it recorded at its
        // last render. Two replacements between renders put a *freed*
        // generation on the other side of that comparison: generation N is
        // released before N+2 is allocated, and the allocator hands the
        // address straight back. Measured, thirteen consecutive terminal
        // generations occupied two addresses, so N and N+2 necessarily share
        // one. An address-derived identity leaves the surface unbuilt and the
        // third generation's feed without a sink (#143).
        //
        // Whether the shipped screen really skips a render between two
        // replacements is unproven and needs a hosted-view harness (#152).
        // The identity has to survive it either way.
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)
        let stage = SurfaceIdentityStage()
        stage.update(id: store.terminalID, feed: store.terminalFeed)

        try await goLive(store, transport)
        await transport.emitAttachOutput(Data("before".utf8))
        try await waitUntil("the first session should reach the first surface") {
            stage.surfaces.last?.text.contains("before") == true
        }
        #expect(stage.surfaces.count == 1)

        for generation in UInt64(1)...2 {
            let replacedID = store.terminalID
            store.transportGenerationDidChange(generation)
            try await waitUntil("terminal generation \(generation) should be built") {
                store.terminalID != replacedID
            }
        }

        stage.update(id: store.terminalID, feed: store.terminalFeed)
        #expect(stage.surfaces.count == 2)

        try await goLive(store, transport, cols: 100, rows: 30)
        await transport.emitAttachOutput(Data("after".utf8))
        try await waitUntil("the third generation's bytes should reach its own surface") {
            stage.surfaces.last?.text.contains("after") == true
        }
        #expect(stage.surfaces.first?.text.contains("after") == false)

        await store.leave().value
    }

    /// SwiftUI's `.id()` rule with nothing else in it: an unchanged identity
    /// keeps the surface already built, a changed one builds another. The
    /// attach mirrors `TerminalScreenView.makeUIView`, which is the only place
    /// a feed ever acquires a sink.
    @MainActor
    private final class SurfaceIdentityStage {
        private(set) var surfaces: [Surface] = []
        private var currentID: AnyHashable?

        func update(id: some Hashable, feed: TerminalByteFeed) {
            let id = AnyHashable(id)
            guard id != currentID else { return }
            currentID = id
            let surface = Surface()
            surfaces.append(surface)
            feed.attach(surface)
        }
    }

    @MainActor
    private final class Surface: TerminalByteSink {
        private(set) var chunks: [Data] = []
        var text: String {
            String(decoding: chunks.reduce(Data(), +), as: UTF8.self)
        }

        func receive(_ data: Data) {
            chunks.append(data)
        }
    }

    @Test func successfulCloseLeavesTheWholeAttachInteraction() async throws {
        let transport = ScriptedTransport()
        let closeCalls = CloseCallRecorder()
        let store = makeStore(
            transport: transport, generation: 0,
            close: { await closeCalls.record() })

        try await goLive(store, transport)

        #expect(await store.closeAgent())
        #expect(await closeCalls.count == 1)
        #expect(store.terminalStatus == .stopped)
        #expect(await transport.hasLiveAttachSession == false)
    }

    #if DEBUG
    @Test func foregroundRecoveryTraceAdoptsTheDirectReplacement() async throws {
        let transport = ScriptedTransport()
        let endGate = ScriptedTransportCallGate()
        await transport.gateNextAttachEnd(on: endGate)
        let store = makeStore(transport: transport, generation: 0)
        try await goLive(store, transport)
        let predecessorID = store.terminalID

        store.didBecomeActive(afterPossibleSuspension: true)
        let trace = try #require(store.pendingForegroundRecoveryTrace)
        try await waitUntil("recovery should reach predecessor teardown") {
            await endGate.entryCount == 1
        }
        await endGate.open()
        try await waitUntil("recovery replacement should publish") {
            store.terminalID != predecessorID
        }

        #expect(store.terminal.restorationTrace === trace)
        #expect(store.pendingForegroundRecoveryTrace == nil)
        await store.leave().value
    }

    @Test func foregroundRecoveryTraceAdoptsAnAlreadyPendingReplacement() async throws {
        let transport = ScriptedTransport()
        let endGate = ScriptedTransportCallGate()
        await transport.gateNextAttachEnd(on: endGate)
        let store = makeStore(transport: transport, generation: 0)
        try await goLive(store, transport)
        let predecessorID = store.terminalID

        store.transportGenerationDidChange(1)
        try await waitUntil("ordinary replacement should reach predecessor teardown") {
            await endGate.entryCount == 1
        }
        store.didBecomeActive(afterPossibleSuspension: true)
        let trace = try #require(store.pendingForegroundRecoveryTrace)
        await endGate.open()
        try await waitUntil("pending replacement should publish") {
            store.terminalID != predecessorID
        }

        #expect(store.terminal.restorationTrace === trace)
        #expect(store.pendingForegroundRecoveryTrace == nil)
        await store.leave().value
    }

    @Test func repeatedForegroundActivationKeepsOnePendingTrace() async throws {
        let transport = ScriptedTransport()
        let endGate = ScriptedTransportCallGate()
        await transport.gateNextAttachEnd(on: endGate)
        let store = makeStore(transport: transport, generation: 0)
        try await goLive(store, transport)

        store.transportGenerationDidChange(1)
        try await waitUntil("ordinary replacement should reach predecessor teardown") {
            await endGate.entryCount == 1
        }
        store.didBecomeActive(afterPossibleSuspension: true)
        let trace = try #require(store.pendingForegroundRecoveryTrace)
        store.didBecomeActive(afterPossibleSuspension: true)

        #expect(store.pendingForegroundRecoveryTrace === trace)
        #expect(trace.recordedPhases.contains(.foregroundRecoveryStarted))
        await endGate.open()
        await store.leave().value
    }

    @Test func offStageRecoveryAbortRecordsTerminalTraceEventAndClearsPendingTrace() async throws {
        let transport = ScriptedTransport()
        let endGate = ScriptedTransportCallGate()
        await transport.gateNextAttachEnd(on: endGate)
        var isOnStage = true
        let store = makeStore(
            transport: transport, generation: 0, isOnStage: { isOnStage })
        try await goLive(store, transport)

        store.transportGenerationDidChange(1)
        try await waitUntil("ordinary replacement should reach predecessor teardown") {
            await endGate.entryCount == 1
        }
        store.didBecomeActive(afterPossibleSuspension: true)
        let trace = try #require(store.pendingForegroundRecoveryTrace)
        isOnStage = false
        await endGate.open()
        try await waitUntil("off-stage recovery should clear its trace") {
            store.pendingForegroundRecoveryTrace == nil
        }

        #expect(trace.recordedPhases.contains(.foregroundRecoveryAborted))
        await store.leave().value
    }

    @Test func supersedingOnStageReplacementCarriesPendingForegroundTrace() async throws {
        let transport = ScriptedTransport()
        let endGate = ScriptedTransportCallGate()
        await transport.gateNextAttachEnd(on: endGate)
        let store = makeStore(transport: transport, generation: 0)
        try await goLive(store, transport)
        let predecessorID = store.terminalID

        store.transportGenerationDidChange(1)
        try await waitUntil("first replacement should reach predecessor teardown") {
            await endGate.entryCount == 1
        }
        store.transportGenerationDidChange(2)
        store.didBecomeActive(afterPossibleSuspension: true)
        let trace = try #require(store.pendingForegroundRecoveryTrace)
        await endGate.open()
        try await waitUntil("superseding replacement should publish") {
            store.terminalID != predecessorID
        }

        #expect(store.terminal.restorationTrace === trace)
        #expect(store.pendingForegroundRecoveryTrace == nil)
        await store.leave().value
    }
    #endif

    private func makeStore(
        transport: ScriptedTransport,
        generation: UInt64?,
        target: String = "w1:p1",
        isOnStage: @escaping () -> Bool = { true },
        runTerminal: TerminalSessionRunner? = nil,
        stageImage: ImageStager? = nil,
        composer: AgentComposerStore? = nil,
        close: @escaping () async throws -> Void = {}
    ) -> AgentAttachStore {
        let composer = composer ?? makeComposer(target: target)
        return AgentAttachStore(
            target: .agentPane(target),
            transportGeneration: generation,
            recordsNetworkTelemetry: true,
            isOnStage: isOnStage,
            runTerminal: runTerminal ?? { request, handler in
                let session = try await transport.attachTerminal(request)
                try await handler.runEndingSession(session)
            },
            stageImage: stageImage ?? { _, _ in
                throw AttachmentStagingError.transferFailed
            },
            stageFile: { _, _ in
                throw AttachmentStagingError.transferFailed
            },
            composer: composer,
            closePane: close)
    }

    private func makeComposer(target: String = "w1:p1") -> AgentComposerStore {
        AgentComposerStore(target: target) { _ in
            Agent(.fixture(paneID: target))
        }
    }

    /// The host-level mosh capsule's tap: a live SSH session restarts so
    /// the runner re-selects mosh. Two synchronous taps must schedule only
    /// one restart.
    @Test func upgradeToMoshIfNeededRestartsALiveSSHSession() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport, generation: 0)
        try await goLive(store, transport)
        #expect(store.lastSessionFlavor == .ssh)
        #expect(store.terminalStatus == .live)
        #expect(await transport.attachRequests.count == 1)

        store.upgradeToMoshIfNeeded()
        store.upgradeToMoshIfNeeded()
        try await waitUntil("the reattach should open for the upgrade") {
            await transport.attachRequests.count == 2
        }
        try await paint(transport)
        try await waitUntil("the upgraded session should be live again") {
            store.terminalStatus == .live
        }
        #expect(await transport.attachRequests.count == 2)

        await store.leave().value
    }

    /// A session already riding mosh (or not live) is left alone: the
    /// upgrade is only for SSH sessions on a Host whose probe proved mosh.
    @Test func upgradeToMoshIfNeededNoOpsForASessionAlreadyOnMosh() async throws {
        let transport = ScriptedTransport()
        let store = makeStore(
            transport: transport, generation: 0,
            runTerminal: { request, handler in
                await handler.transportDidBecomeReady(0, flavor: .mosh)
                let session = try await transport.attachTerminal(request)
                try await handler.runEndingSession(session)
            })
        try await goLive(store, transport)
        #expect(store.lastSessionFlavor == .mosh)
        #expect(store.terminalStatus == .live)

        store.upgradeToMoshIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.terminalStatus == .live)
        #expect(await transport.attachRequests.count == 1)

        await store.leave().value
    }

    private func observeTerminalChanges(
        of store: AgentAttachStore
    ) -> ObservationChangeProbe {
        let (changes, continuation) = AsyncStream.makeStream(of: Void.self)
        withObservationTracking {
            _ = store.terminalID
        } onChange: {
            continuation.yield()
            continuation.finish()
        }
        return ObservationChangeProbe(changes)
    }

    private func observeStatusChanges(
        of store: AgentAttachStore
    ) -> ObservationChangeProbe {
        let (changes, continuation) = AsyncStream.makeStream(of: Void.self)
        withObservationTracking {
            _ = store.terminalStatus
        } onChange: {
            continuation.yield()
            continuation.finish()
        }
        return ObservationChangeProbe(changes)
    }

    private func tinyJPEGData() throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16))
        let image = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        return try #require(image.jpegData(compressionQuality: 0.8))
    }

    /// Brings the terminal up the way an attach does: the size report opens
    /// the channel, and the remote's first paint is what makes it live. The
    /// paint is a bare screen clear, so it adds nothing for the link index to
    /// find.
    private func goLive(
        _ store: AgentAttachStore, _ transport: ScriptedTransport,
        cols: Int = 80, rows: Int = 24
    ) async throws {
        store.viewDidResize(cols: cols, rows: rows)
        try await paint(transport)
        try await waitUntil("the terminal should go live") {
            store.terminalStatus == .live
        }
    }

    /// The remote's first paint, once the channel is actually up.
    private func paint(_ transport: ScriptedTransport) async throws {
        try await waitUntil("attach should open") { await transport.hasLiveAttachSession }
        #expect(await transport.emitAttachOutput(Data("\u{1B}[2J".utf8)))
    }

    private func emitOSC8(
        _ target: String,
        label: String,
        transport: ScriptedTransport
    ) async {
        await transport.emitAttachOutput(
            Data(
                "\u{001B}]8;;\(target)\u{0007}\(label)\u{001B}]8;;\u{0007}\n"
                    .utf8))
    }

    /// A runner with `EventsSession.withTerminalTransport`'s semantics: one
    /// Attach owns the Host's terminal channel for its entire lifetime,
    /// including teardown, and later attaches queue FIFO behind it.
    private func permitGatedRunner(
        _ transport: ScriptedTransport, _ permit: TerminalChannelPermit
    ) -> TerminalSessionRunner {
        { request, handler in
            try await permit.acquire()
            do {
                let session = try await transport.attachTerminal(request)
                try await handler.runEndingSession(session)
            } catch {
                await permit.release()
                throw error
            }
            await permit.release()
        }
    }
}

private actor ObservationChangeProbe {
    private let changes: AsyncStream<Void>

    init(_ changes: AsyncStream<Void>) {
        self.changes = changes
    }

    func next() async {
        for await _ in changes { return }
    }
}

private actor TerminalGenerationSource {
    private(set) var value: UInt64
    private var nextAcquisitionGate: ScriptedTransportCallGate?

    init(_ value: UInt64) {
        self.value = value
    }

    func set(_ value: UInt64) {
        self.value = value
    }

    func gateNextAcquisition(using gate: ScriptedTransportCallGate) {
        nextAcquisitionGate = gate
    }

    func acquire() async -> UInt64 {
        let generation = value
        let gate = nextAcquisitionGate
        nextAcquisitionGate = nil
        await gate?.waitUntilOpen()
        return generation
    }
}

/// Which pane the Console's router currently has on stage.
@MainActor
private final class SelectedPane {
    var current: String
    private(set) var readCount = 0

    init(current: String) {
        self.current = current
    }

    func contains(_ paneID: String) -> Bool {
        readCount += 1
        return current == paneID
    }
}

/// The Host's single terminal channel, as `EventsSession` arbitrates it:
/// waiters are FIFO and, like the real `acquireTerminal`, cancellation-aware.
private actor TerminalChannelPermit {
    private var inUse = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []

    func acquire() async throws {
        let id = UUID()
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if inUse {
                    waiters.append((id, continuation))
                } else {
                    inUse = true
                    continuation.resume()
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func release() {
        if waiters.isEmpty {
            inUse = false
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

private actor CloseCallRecorder {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

@MainActor
private final class DeferredAttachLinkOpener {
    private var continuations: [String: CheckedContinuation<Bool, Never>] = [:]

    var pendingTargets: [String] {
        continuations.keys.sorted()
    }

    func open(_ url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            continuations[url.absoluteString] = continuation
        }
    }

    func complete(_ target: String, accepted: Bool) {
        continuations.removeValue(forKey: target)?.resume(returning: accepted)
    }
}

@MainActor
private final class CancellationAwareAttachLinkOpener {
    private var continuation: CheckedContinuation<Bool, Never>?
    private(set) var pendingTarget: String?
    private(set) var cancelledTargets: [String] = []

    func open(_ url: URL) async -> Bool {
        let target = url.absoluteString
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                pendingTarget = target
                self.continuation = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(target)
            }
        }
    }

    private func cancel(_ target: String) {
        guard pendingTarget == target else { return }
        pendingTarget = nil
        cancelledTargets.append(target)
        continuation?.resume(returning: false)
        continuation = nil
    }

    func resolvePending(accepted: Bool) {
        pendingTarget = nil
        continuation?.resume(returning: accepted)
        continuation = nil
    }
}

private actor GatedAttachImageStager {
    let gate: ScriptedTransportCallGate
    private(set) var preparedFileURL: URL?
    private(set) var cancellationRequestCount = 0
    private(set) var cancellationCount = 0

    init(gate: ScriptedTransportCallGate) {
        self.gate = gate
    }

    func stage(
        _ image: PreparedImage,
        _ reporter: AttachmentStageProgressReporter
    ) async throws -> StagedImage {
        preparedFileURL = image.fileURL
        await reporter.report(
            AttachmentStageProgress(transferredBytes: 0, totalBytes: image.byteCount))
        await withTaskCancellationHandler {
            await gate.waitUntilOpen()
        } onCancel: {
            Task { await self.recordCancellationRequest() }
        }
        do {
            try Task.checkCancellation()
        } catch {
            cancellationCount += 1
            throw error
        }
        throw AttachmentStagingError.transferFailed
    }

    private func recordCancellationRequest() {
        cancellationRequestCount += 1
    }
}

/// The Attach screen's owner, covering only what the foreground return has to
/// travel through to reach the terminal pipeline (#141).
@MainActor
@Suite("Agent attach store foreground")
struct AgentAttachStoreForegroundTests {
    private func makeStore(
        transport: ScriptedTransport, isOnStage: @escaping () -> Bool = { true }
    ) -> AgentAttachStore {
        let composer = AgentComposerStore(target: "w1:p1") { _ in
            Agent(.fixture(paneID: "w1:p1"))
        }
        return AgentAttachStore(
            target: .agentPane("w1:p1"),
            transportGeneration: 1,
            recordsNetworkTelemetry: true,
            isOnStage: isOnStage,
            runTerminal: { request, handler in
                let session = try await transport.attachTerminal(request)
                try await handler.runEndingSession(session)
            },
            stageImage: { _, _ in throw TransportError.cancelled },
            stageFile: { _, _ in throw TransportError.cancelled },
            composer: composer,
            closePane: {})
    }

    @Test func theForegroundReturnReachesTheLiveTerminal() async throws {
        // `didBecomeActive()` used to forward to the image store alone, so
        // nothing on the Attach path reacted to foregrounding at all.
        let transport = ScriptedTransport()
        let store = makeStore(transport: transport)

        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("attach should open") { await transport.hasLiveAttachSession }
        #expect(await transport.emitAttachOutput(Data("\u{1B}[2J".utf8)))
        try await waitUntil("terminal should go live") { store.terminalStatus == .live }

        store.didBecomeActive()

        try await waitUntil("the return should reach the terminal's remote") {
            await transport.attachInputs == [
                .resize(cols: 79, rows: 24),
                .resize(cols: 80, rows: 24),
            ]
        }
        await store.leave().value
    }

    @Test func activationDoesNotRecoverAnAgentThatAlreadyLeftTheStage() async throws {
        let transport = ScriptedTransport()
        var isOnStage = true
        let store = makeStore(transport: transport, isOnStage: { isOnStage })

        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("attach should open") { await transport.hasLiveAttachSession }
        #expect(await transport.emitAttachOutput(Data("opening".utf8)))
        try await waitUntil("terminal should go live") { store.terminalStatus == .live }
        let terminalID = store.terminalID

        // The router switches first. SwiftUI's onDisappear can arrive later,
        // so the lifecycle is still active when this old view observes
        // activation.
        isOnStage = false
        store.didBecomeActive(afterPossibleSuspension: true)
        try await Task.sleep(for: .milliseconds(100))

        #expect(store.terminalID == terminalID)
        #expect(store.terminalStatus == .live)
        #expect(await transport.attachRequests.count == 1)
        #expect(await transport.hasLiveAttachSession)

        await store.leave().value
    }

    @Test func leavingTheStageDuringRecoveryDoesNotBuildAnInvisibleAttach() async throws {
        let transport = ScriptedTransport()
        let endGate = ScriptedTransportCallGate()
        await transport.gateNextAttachEnd(on: endGate)
        var isOnStage = true
        let store = makeStore(transport: transport, isOnStage: { isOnStage })

        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("attach should open") { await transport.hasLiveAttachSession }
        #expect(await transport.emitAttachOutput(Data("opening".utf8)))
        try await waitUntil("terminal should go live") { store.terminalStatus == .live }
        let terminalID = store.terminalID

        store.didBecomeActive(afterPossibleSuspension: true)
        try await waitUntil("recovery should begin stopping the old PTY") {
            await endGate.entryCount == 1
        }
        isOnStage = false
        await endGate.open()
        try await waitUntil("the old PTY should finish stopping") {
            await transport.hasLiveAttachSession == false
        }
        try await Task.sleep(for: .milliseconds(50))

        #expect(store.terminalID == terminalID)
        #expect(
            store.terminalStatus == .stopped,
            "a cancelled off-stage recovery must not leave a stale Connecting state")
        #expect(await transport.attachRequests.count == 1)
        #expect(await transport.hasLiveAttachSession == false)

        await store.leave().value
    }

    @Test func deliberateTerminalHandoffTearsDownAnOnStageActivationRecovery() async throws {
        let transport = ScriptedTransport()
        let endGate = ScriptedTransportCallGate()
        await transport.gateNextAttachEnd(on: endGate)
        let store = makeStore(transport: transport)

        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("attach should open") { await transport.hasLiveAttachSession }
        #expect(await transport.emitAttachOutput(Data("opening".utf8)))
        try await waitUntil("terminal should go live") { store.terminalStatus == .live }
        store.didBecomeActive(afterPossibleSuspension: true)
        try await waitUntil("recovery should reach the predecessor PTY teardown") {
            await endGate.entryCount == 1
        }

        let handoff = store.leaveForTerminalHandoff()
        await endGate.open()
        await handoff.value

        #expect(store.terminalStatus == .stopped)
        #expect(await transport.attachRequests.count == 1)
        #expect(await transport.hasLiveAttachSession == false)
    }

    @Test func recoveryDoesNotConfirmReviewedPasteThroughThePredecessorWriter() async throws {
        let transport = ScriptedTransport()
        let endGate = ScriptedTransportCallGate()
        await transport.gateNextAttachEnd(on: endGate)
        let store = makeStore(transport: transport)
        let text = "git status\ngit diff"

        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("attach should open") { await transport.hasLiveAttachSession }
        #expect(await transport.emitAttachOutput(Data("opening".utf8)))
        try await waitUntil("terminal should go live") { store.terminalStatus == .live }
        store.requestPaste(text, bracketedPaste: true)
        let review = try #require(store.pendingPaste)

        store.didBecomeActive(afterPossibleSuspension: true)
        try await waitUntil("recovery should begin stopping the old PTY") {
            await endGate.entryCount == 1
        }

        #expect(!store.canConfirmPaste)
        store.confirmPaste()
        #expect(store.pendingPaste == review)
        #expect(await transport.attachInputs.compactMap { input -> Data? in
            if case .keystrokes(let data) = input { return data }
            return nil
        }.isEmpty)

        let predecessorID = store.terminalID
        await endGate.open()
        try await waitUntil("the replacement pipeline should be created") {
            store.terminalID != predecessorID
        }
        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil("the replacement Attach should open") {
            await transport.attachRequests.count == 2
        }
        #expect(await transport.emitAttachOutput(Data("recovered".utf8)))
        try await waitUntil("the replacement Attach should become live") {
            store.terminalStatus == .live
        }

        #expect(store.canConfirmPaste)
        store.confirmPaste()
        let expectedPaste = TerminalBracketedPaste.encode(text, bracketed: true)
        try await waitUntil("Paste should use the replacement writer exactly once") {
            await transport.attachInputs.compactMap { input -> Data? in
                if case .keystrokes(let data) = input { return data }
                return nil
            } == [expectedPaste]
        }
        #expect(store.pendingPaste == nil)

        await store.leave().value
    }

}

/// The Attach store's byte pipe: opening bytes buffer for the first surface,
/// while bytes from an obsolete pipeline are not replayed into a later one.
@MainActor
@Suite("Terminal byte feed")
struct TerminalByteFeedTests {
    /// Stands in for the Ghostty surface the representable view creates.
    @MainActor
    private final class Surface: TerminalByteSink {
        var chunks: [Data] = []

        func receive(_ data: Data) {
            chunks.append(data)
        }
    }

    @Test func bytesWrittenBeforeAnySurfaceAreHeldForTheFirstOne() {
        let feed = TerminalByteFeed()

        feed.write(Data("opening".utf8))

        let surface = Surface()
        feed.attach(surface)
        #expect(surface.chunks == [Data("opening".utf8)])
    }

    @Test func bytesWrittenIntoALiveSurfaceAreDelivered() {
        let feed = TerminalByteFeed()
        let surface = Surface()
        feed.attach(surface)

        feed.write(Data("frame".utf8))
        #expect(surface.chunks == [Data("frame".utf8)])
    }

    @Test func bytesWrittenAfterTheSurfaceIsGoneAreNotReplayed() {
        let feed = TerminalByteFeed()
        var surface: Surface? = Surface()
        if let surface { feed.attach(surface) }
        surface = nil

        feed.write(Data("obsolete".utf8))
        let replacement = Surface()
        feed.attach(replacement)
        #expect(replacement.chunks.isEmpty)
    }

    @Test func anEmptyChunkDoesNotReachTheSurface() {
        let feed = TerminalByteFeed()
        let surface = Surface()
        feed.attach(surface)

        feed.write(Data())
        #expect(surface.chunks.isEmpty)
    }
}
