import Foundation
import MoshCore
import os
import Synchronization

/// Builds the mosh-backed session for one bootstrap: production is
/// ``MoshAttachSession/make(bootstrap:cols:rows:firstContactTimeout:registry:)``;
/// tests script the session instead of talking UDP.
typealias MoshSessionFactory =
    @Sendable (_ bootstrap: MoshBootstrap, _ cols: Int, _ rows: Int, _ firstContactTimeout: Duration)
    -> TerminalAttachSession

/// A mosh session whose server answered, then fell silent past the network
/// timeout: the link was lost (a long outage, a server that exited), not
/// mosh. The terminal reattaches rather than falling back to SSH (#105).
struct MoshLinkLost: Error, Equatable, Sendable {
    let timeoutMs: UInt32
}

/// One interactive terminal session carried over mosh's UDP transport, spoken
/// by the vendored swift-mosh client (`Packages/SwiftMosh`).
///
/// Each server state arrives as terminal bytes (`MoshHostOp.hostBytes`) that
/// transform an earlier screen into the new one, and they feed the Attach
/// output so Ghostty applies them like any other terminal output. swift-mosh
/// keeps the screens of recent states (Waycar patch 16, see
/// `Packages/SwiftMosh/PROVENANCE.md`): a state built on the screen Ghostty
/// shows passes through unchanged, and one the server built on an older
/// screen arrives as a repaint from swift-mosh's model instead. `repaint`
/// redraws the terminal from that model when the app returns to the
/// foreground. Keystrokes and resizes travel the other way as
/// `MoshClientOp`s. There is no local echo prediction: a keystroke shows
/// once the server's frame does.
///
/// Construction never throws: a session that cannot start or later fails
/// (wrong key, protocol violation) surfaces on `output` as a thrown
/// ``TransportError/moshSessionFailed(detail:)``, which the Attach store
/// presents as an ended session and falls back to SSH from. A server that is
/// unreachable or firewalled — or a `start()` that never completes — surfaces
/// the same way once the first-contact timeout passes without any server
/// state. A server that answered and then stays silent past the network
/// timeout surfaces as ``MoshLinkLost``. The server ending the session
/// because its command exited finishes `output` cleanly, like an SSH attach
/// whose remote side detached. The caller owns explicit teardown through
/// `end()`, which quits the session the way mosh's own client does:
/// mosh-server exits with its command once it acknowledges the shutdown,
/// instead of lingering and pinning the pane at this device's size (#19). A
/// Host that does not answer holds `end()` about a second at most;
/// `abandon()` skips that wait for a server presumed gone.
enum MoshAttachSession {
    /// mosh-server's `ACK_INTERVAL`: an idle server acks a client state
    /// with nothing new in it only this often (mosh 1.4.0
    /// network/transportsender.h).
    static let serverAckIntervalMs: UInt32 = 3_000
    /// 5 s past mosh-server's MOSH_SERVER_NETWORK_TMOUT=60: longer silence
    /// means the server has exited, so the session can only fail.
    static let networkTimeoutMs: UInt32 = 65_000
    /// Silence past mosh's own `server_late` (frontend/terminaloverlay.h)
    /// reads stalled: above two idle acks, so a single lost reply from a
    /// healthy idle server never shows the Reconnecting pill.
    static let stallThresholdMs: UInt32 = 6_500

    /// Assembles the mosh-backed session for a successful bootstrap. The
    /// UDP endpoint comes from the bootstrap; geometry is the attach
    /// request's initial PTY size. `firstContactTimeout` bounds how long the
    /// session waits for the server's first state before giving up on UDP.
    /// The running session joins `registry`, so a network path change
    /// rebinds it.
    static func make(
        bootstrap: MoshBootstrap, cols: Int, rows: Int,
        firstContactTimeout: Duration = .seconds(6),
        registry: MoshSessionRegistry? = nil
    ) -> TerminalAttachSession {
        let lifecycle = MoshSessionLifecycle(
            bootstrap: bootstrap, cols: cols, rows: rows,
            firstContactTimeout: firstContactTimeout, registry: registry)
        lifecycle.start()
        return TerminalAttachSession(
            output: lifecycle.outputGate.makeOutput,
            input: lifecycle.input,
            onEndStarted: lifecycle.outputGate.beginExplicitEnd,
            link: lifecycle,
            abandoner: { await lifecycle.end(abandoning: true) }
        ) {
            await lifecycle.end(abandoning: false)
        }
    }

    /// The ended attach's detail for a failed swift-mosh session.
    static func failureDetail(_ failure: MoshSessionFailure) -> String {
        switch failure {
        case .timeout(let timeoutMs):
            timeoutDetail(timeoutMs)
        case .protocolViolation(let message):
            "The Host's mosh-server sent something unexpected. (\(message))"
        case .authenticationFailure:
            "The Host's UDP replies failed authentication with this session's key."
        case .retryLimitExceeded(_, let retryCount):
            "The Host stopped acknowledging input after \(retryCount) retries."
        case .circuitBreakerTripped(_, let message):
            "The mosh connection kept failing. (\(message))"
        case .transportFailure(let message):
            "The UDP connection failed. (\(message))"
        }
    }

    static func timeoutDetail(_ timeoutMs: UInt32) -> String {
        "The Host stopped answering over UDP for \(timeoutMs / 1000)s."
    }

    /// The ended attach's detail for a server that never sent its first state.
    static func firstContactTimeoutDetail(_ timeout: Duration) -> String {
        "The Host did not answer over UDP within \(max(1, timeout.components.seconds))s."
    }

    /// MoshCore checks for a stall every 50 ms. Two checks after the call,
    /// `.connected` means a datagram arrived within its stall threshold of
    /// now — after a freeze longer than that, only one received since the
    /// return (or held for it by the socket) can say so. An idle server
    /// answers a state with nothing new only at its 3 s ack cadence, so the
    /// check sends one with something in it (`elicitServerReply()`), which
    /// a live server acks within its 100 ms ack delay.
    static func awaitServerContact(
        of session: some MoshServerContactSource, within timeout: Duration
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        let settle = min(timeout, .milliseconds(120))
        do { try await Task.sleep(for: settle) } catch { return false }
        if await session.connectivity == .connected { return true }
        let remaining = deadline - ContinuousClock.now
        guard remaining > .zero else { return false }
        let updates = await session.connectivityStream()
        await session.elicitServerReply()
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await connectivity in updates where connectivity == .connected {
                    return true
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: remaining)
                return false
            }
            let heard = await group.next() ?? false
            group.cancelAll()
            return heard
        }
    }
}

/// What a server-contact check reads and sends on a running mosh client
/// (#105).
protocol MoshServerContactSource: Sendable {
    var connectivity: MoshConnectivity? { get async }
    func connectivityStream() async -> AsyncStream<MoshConnectivity>
    /// Sends a client state the server must ack at once.
    @discardableResult func elicitServerReply() async -> Bool
}

extension MoshClientSession: MoshServerContactSource {}

/// What a network path change does to mosh (#105): every running session
/// gets a fresh UDP flow, so the server roams to the device's new address
/// at once instead of after mosh's own retransmit backoff.
protocol MoshTransportRebinding: AnyObject, Sendable {
    func rebindTransport() async
}

extension MoshClientSession: MoshTransportRebinding {}

/// The running mosh sessions, for the path monitor to rebind. A session
/// joins once its client starts and leaves when its run ends.
final class MoshSessionRegistry: Sendable {
    private let sessions = Mutex<[UUID: any MoshTransportRebinding]>([:])

    init() {}

    var count: Int { sessions.withLock { $0.count } }

    func register(_ session: any MoshTransportRebinding) -> UUID {
        let id = UUID()
        sessions.withLock { $0[id] = session }
        return id
    }

    func unregister(_ id: UUID) {
        sessions.withLock { _ = $0.removeValue(forKey: id) }
    }

    /// Rebinds every running session, each in its own task: a rebind waits
    /// for its new flow to connect, which offline can take until the
    /// network returns, and no session waits behind another.
    func rebindAll() {
        for session in sessions.withLock({ Array($0.values) }) {
            Task { await session.rebindTransport() }
        }
    }
}

/// Owns one live swift-mosh session and the tasks around it: `run` drives
/// the session and drains its host stream into the Attach output gate;
/// `pump` feeds the Attach input queue into the session; the first-contact
/// watchdog gives up on a server that never answers. The lifecycle is
/// `MoshAttachMachine`; it and everything that is not a value (the session,
/// tasks, continuations) sit behind one mutex, and each step feeds the
/// machine and performs its effects in the lock section the step always
/// used. The class is Sendable so the terminal machinery can reach it from
/// any isolation domain.
private final class MoshSessionLifecycle: TerminalSessionLink, Sendable {
    private enum StartOutcome: Sendable {
        case started
        case failed(any Error)
        case abandoned
    }

    private struct State {
        var machine = MoshAttachMachine()
        var session: MoshClientSession?
        var runTask: Task<Void, Never>?
        var pumpTask: Task<Void, Never>?
        var watchdog: Task<Void, Never>?
        var relayTask: Task<Void, Never>?
        var firstContactWaiters: [CheckedContinuation<TerminalLinkFirstContact, Never>] = []
        /// The stall under way, for its log line (#105).
        var stall: NetworkInterval?
        var connectivitySubscribers: [UUID: AsyncStream<TerminalLinkConnectivity>.Continuation] = [:]
        var registration: UUID?
    }

    let input = TerminalAttachInputQueue()
    let outputGate = WaycarSSHAttachOutputGate()

    private let state = Mutex(State())
    private let bootstrap: MoshBootstrap
    private let initialCols: Int32
    private let initialRows: Int32
    private let firstContactTimeout: Duration
    private let registry: MoshSessionRegistry?
    /// Carries the first start outcome to `run`. `start()` runs in its own
    /// task because it can wait forever on a network path that never becomes
    /// ready, and stopping the session does not reach a start in flight;
    /// `run` must still be able to give up on it so `end()` can return.
    private let startOutcomes: AsyncStream<StartOutcome>
    private let startOutcomeSink: AsyncStream<StartOutcome>.Continuation

    init(
        bootstrap: MoshBootstrap, cols: Int, rows: Int, firstContactTimeout: Duration,
        registry: MoshSessionRegistry?
    ) {
        self.bootstrap = bootstrap
        initialCols = Int32(max(1, cols))
        initialRows = Int32(max(1, rows))
        self.firstContactTimeout = firstContactTimeout
        self.registry = registry
        (startOutcomes, startOutcomeSink) = AsyncStream.makeStream(of: StartOutcome.self)
    }

    func start() {
        let runTask = Task<Void, Never> { [self] in
            await run()
        }
        state.withLock { $0.runTask = runTask }
    }

    /// Explicit teardown. `TerminalAttachSession.end()` has already finished
    /// the input queue, so the pump winds down on its own; stopping the
    /// session finishes its host stream, which lets `run` close the output.
    /// `abandoning` skips mosh's shutdown handshake (no acknowledgement
    /// wait) for a server presumed gone. A start still in flight is
    /// abandoned rather than awaited, since it may never return.
    func end(abandoning: Bool) async {
        let (effects, session, runTask, pumpTask, watchdog) = state.withLock { current in
            let effects = current.machine.handle(.endRequested(abandoning: abandoning))
            let watchdog = current.watchdog
            current.watchdog = nil
            return (effects, current.session, current.runTask, current.pumpTask, watchdog)
        }
        for effect in effects {
            switch effect {
            case .cancelWatchdog:
                watchdog?.cancel()
            case .reportStart(.abandoned):
                startOutcomeSink.yield(.abandoned)
            case .stopSession(abandoning: true):
                await session?.abandon()
            case .stopSession(abandoning: false):
                await session?.shutdown()
            default:
                break
            }
        }
        await watchdog?.value
        await pumpTask?.value
        await runTask?.value
    }

    // MARK: TerminalSessionLink

    func connectivity() -> AsyncStream<TerminalLinkConnectivity> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: TerminalLinkConnectivity.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        let subscribed = state.withLock { current -> Bool in
            guard !current.machine.state.linkEnded else { return false }
            if let connectivity = current.machine.state.connectivity {
                continuation.yield(connectivity)
            }
            current.connectivitySubscribers[id] = continuation
            return true
        }
        guard subscribed else {
            continuation.finish()
            return stream
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.connectivitySubscribers.removeValue(forKey: id) }
        }
        return stream
    }

    func firstContact() async -> TerminalLinkFirstContact {
        await withCheckedContinuation { continuation in
            state.withLock { current in
                if let settled = current.machine.state.firstContact {
                    continuation.resume(returning: settled)
                } else {
                    current.firstContactWaiters.append(continuation)
                }
            }
        }
    }

    func awaitServerContact(within timeout: Duration) async -> Bool {
        guard let session = state.withLock({ $0.session }) else { return false }
        return await MoshAttachSession.awaitServerContact(of: session, within: timeout)
    }

    func repaint(cols: Int, rows: Int) async {
        guard let session = state.withLock({ $0.session }) else { return }
        await session.repaintScreen(cols: cols, rows: rows)
    }

    // MARK: Run

    private func run() async {
        defer { settleLink() }
        guard let port = UInt16(bootstrap.udpPort), port > 0 else {
            outputGate.finish(throwing: TransportError.moshSessionFailed(
                detail: "mosh-server announced an unusable UDP port (\(bootstrap.udpPort))."))
            return
        }
        let session = MoshClientSession(
            endpoint: MoshEndpoint(host: bootstrap.host, port: port, keyBase64_22: bootstrap.key),
            config: MoshClientConfig(
                networkTimeoutMs: MoshAttachSession.networkTimeoutMs,
                stallThresholdMs: MoshAttachSession.stallThresholdMs))
        // Publishing the session and reading the end flag under one lock
        // means `end()` either sees this session to stop, or this task sees
        // the end request — never neither. The watchdog is armed under the
        // same lock so `end()` always finds it to cancel.
        let proceed = state.withLock { current -> Bool in
            current.session = session
            var proceed = false
            for effect in current.machine.handle(.sessionCreated) {
                guard case .armWatchdog(let token) = effect else { continue }
                current.watchdog = Task<Void, Never> { [self] in
                    await watchForFirstContact(session, token: token)
                }
                proceed = true
            }
            return proceed
        }
        guard proceed else {
            outputGate.finish()
            return
        }
        // Whatever ends `run` — a failed start, a failed session, a remote
        // exit before any state — the watchdog has nothing left to guard.
        defer { disarmWatchdog() }

        // Subscribe before starting, so no early frame can be missed.
        let hostOps = await session.hostOpStream()
        Task<Void, Never> { [self] in
            await startSession(session)
        }
        switch await nextStartOutcome() {
        case .started:
            break
        case .failed(let error):
            await session.shutdown()
            outputGate.finish(throwing: TransportError.moshSessionFailed(
                detail: "The mosh session could not start. (\(error))"))
            return
        case .abandoned:
            // The party that gave up already settled the output: the
            // watchdog failed it, or `end()` began the explicit end.
            outputGate.finish()
            return
        }

        // `end()` stops a session that has started by itself; it only needs
        // the pump not to start behind its back.
        let connectivity = await session.connectivityStream()
        state.withLock { current in
            guard current.machine.handle(.runReady) == [.startRelayAndPump] else { return }
            current.registration = registry?.register(session)
            current.relayTask = Task<Void, Never> { [self] in
                for await update in connectivity {
                    publish(update == .connected ? .connected : .stalled)
                }
            }
            current.pumpTask = Task<Void, Never> { [input] in
                // swift-mosh refuses input only once the session stops
                // running; input typed while it swaps transports during a
                // network handoff is queued and retransmitted. A refused
                // item is dropped: the session's end surfaces on `output`,
                // and `end()` stops the pump by finishing the input queue.
                _ = try? await input.pump(
                    write: { data in
                        _ = try? await session.enqueue(.keystrokes(data))
                    },
                    resize: { cols, rows in
                        guard cols > 0, rows > 0 else { return }
                        _ = try? await session.enqueue(
                            .resize(cols: Int32(cols), rows: Int32(rows)))
                    })
            }
        }

        var awaitingFirstContact = true
        for await op in hostOps {
            if awaitingFirstContact {
                awaitingFirstContact = false
                send(.firstHostOp)
            }
            if case .hostBytes(let bytes) = op, !bytes.isEmpty {
                outputGate.yield(bytes)
            }
        }

        // The host stream finishes when the session stops: the server shut
        // it down (its command exited), `end()` or the watchdog stopped it,
        // or it failed. A watchdog timeout has already failed the output,
        // and the gate keeps the first completion.
        let answered = state.withLock { $0.machine.hostAnswered }
        switch await session.failure {
        case .some(.timeout(let timeoutMs)) where answered:
            NetworkLog.logger.notice("mosh timed out after \(timeoutMs, privacy: .public) ms of silence")
            outputGate.finish(throwing: MoshLinkLost(timeoutMs: timeoutMs))
        case .some(let failure):
            outputGate.finish(throwing: TransportError.moshSessionFailed(
                detail: MoshAttachSession.failureDetail(failure)))
        case nil:
            outputGate.finish()
        }
    }

    /// Starts the session and reports the outcome to `run`. A start that
    /// succeeds after the watchdog or `end()` abandoned it would leave a
    /// running session nobody drains, so it shuts that session down itself.
    private func startSession(_ session: MoshClientSession) async {
        do {
            try await session.start()
            try await session.enqueue(.resize(cols: initialCols, rows: initialRows))
        } catch {
            for case .reportStart(.failed) in send(.startFailed) {
                startOutcomeSink.yield(.failed(error))
            }
            return
        }
        for effect in send(.startSucceeded) {
            switch effect {
            case .reportStart(.started):
                startOutcomeSink.yield(.started)
            case .shutdownStartedSession:
                await session.shutdown()
            default:
                break
            }
        }
    }

    private func nextStartOutcome() async -> StartOutcome {
        var outcomes = startOutcomes.makeAsyncIterator()
        return await outcomes.next() ?? .abandoned
    }

    /// Fails the output when no server state arrives in time. swift-mosh
    /// keeps retrying a silent server forever, and the Attach store only
    /// falls back to SSH on a thrown `moshSessionFailed`, so without this a
    /// blocked UDP port would leave an empty terminal indefinitely.
    private func watchForFirstContact(_ session: MoshClientSession, token: UInt64) async {
        do {
            try await Task.sleep(for: firstContactTimeout)
        } catch {
            return
        }
        // Two steps, as ever: the start first, then first contact. The
        // answer may win after the first; only the party that settles first
        // contact fails the output.
        for case .timeOutFirstContact(let abandonsStart) in send(.watchdogElapsed(token: token)) {
            for effect in send(.firstContactTimedOut(abandonsStart: abandonsStart)) {
                switch effect {
                case .reportStart(.abandoned):
                    startOutcomeSink.yield(.abandoned)
                case .abandonSession:
                    // Nothing answered, so nothing would acknowledge a shutdown.
                    await session.abandon()
                default:
                    break
                }
            }
        }
    }

    private func disarmWatchdog() {
        send(.disarmWatchdog)
    }

    private func publish(_ connectivity: TerminalLinkConnectivity) {
        send(.connectivity(connectivity))
    }

    /// The run is over: a first contact still pending never comes, then the
    /// session leaves the registry and its connectivity subscribers finish.
    private func settleLink() {
        send(.runEnded)
        send(.linkEnded)
    }

    /// Feeds `MoshAttachMachine` under the lock, does the effects' lock-side
    /// bookkeeping in that same section, then performs the effects that
    /// need nothing from the caller, in order. Returns the rest (reporting
    /// the start, stopping the session) for the caller, which holds what
    /// they need.
    @discardableResult
    private func send(_ event: MoshAttachMachine.Event) -> [MoshAttachMachine.Effect] {
        var waiters: [CheckedContinuation<TerminalLinkFirstContact, Never>] = []
        var watchdog: Task<Void, Never>?
        var subscribers: [AsyncStream<TerminalLinkConnectivity>.Continuation] = []
        var recovered: NetworkInterval?
        var registration: UUID?
        var relay: Task<Void, Never>?
        var stall: NetworkInterval?
        let effects = state.withLock { current in
            let effects = current.machine.handle(event)
            for effect in effects {
                switch effect {
                case .settleFirstContact:
                    waiters = current.firstContactWaiters
                    current.firstContactWaiters.removeAll()
                case .cancelWatchdog:
                    watchdog = current.watchdog
                    current.watchdog = nil
                case .relayConnectivity(let connectivity):
                    recovered = connectivity == .stalled ? nil : current.stall
                    current.stall = connectivity == .stalled ? NetworkInterval("mosh stall") : nil
                    subscribers = Array(current.connectivitySubscribers.values)
                case .endLink:
                    (registration, relay, stall) = (current.registration, current.relayTask, current.stall)
                    subscribers = Array(current.connectivitySubscribers.values)
                    current.registration = nil
                    current.connectivitySubscribers.removeAll()
                    current.relayTask = nil
                    current.stall = nil
                default:
                    break
                }
            }
            return effects
        }
        var forCaller: [MoshAttachMachine.Effect] = []
        for effect in effects {
            switch effect {
            case .settleFirstContact(let outcome):
                for waiter in waiters { waiter.resume(returning: outcome) }
            case .cancelWatchdog:
                watchdog?.cancel()
            case .failFirstContact:
                NetworkLog.logger.notice(
                    "mosh first contact timed out after \(self.firstContactTimeout.wholeMilliseconds, privacy: .public) ms"
                )
                outputGate.finish(throwing: TransportError.moshSessionFailed(
                    detail: MoshAttachSession.firstContactTimeoutDetail(firstContactTimeout)))
            case .relayConnectivity(let connectivity):
                if connectivity == .stalled { NetworkLog.logger.notice("mosh stalled") }
                recovered?.end("recovered")
                for subscriber in subscribers { subscriber.yield(connectivity) }
            case .endLink:
                stall?.end("ended")
                relay?.cancel()
                if let registration { registry?.unregister(registration) }
                for subscriber in subscribers { subscriber.finish() }
            case .armWatchdog, .skipRun, .reportStart, .shutdownStartedSession, .stopSession,
                 .timeOutFirstContact, .abandonSession, .startRelayAndPump:
                forCaller.append(effect)
            }
        }
        return forCaller
    }
}
