import Foundation
import Synchronization

// The attach-first provisional handoff and the kept-connection probe and
// hedge (#105), split from EventsSession.swift by concern.
extension EventsSession {
    /// An events subscribe started alongside a new connection's `ping`
    /// (#105), with the set it asked for.
    struct EarlySubscription {
        let subscriptions: [EventSubscription]
        let stream: Task<HerdrEventStream, any Error>
    }

    /// A pooled connection held open across a suspension (#105).
    struct KeptConnection {
        let id: SharedConnection.ID
        let since: ContinuousClock.Instant
    }

    /// A kept connection's probe that answered (#105): its Transport, the
    /// pooled connection it rode, the generation terminals already ride it
    /// under, its early subscribe, and its ping.
    struct KeptProbe: Sendable {
        let transport: any Transport
        let connection: SharedConnection.ID?
        let proving: ProvisionalTransport
        let early: EarlySubscription?
        let latency: Duration
        let info: ServerInfo
    }

    /// What a kept connection's probe has handed out while it runs: undone
    /// if the probe loses or fails.
    struct KeptProbeHandout {
        let transport: any Transport
        let proving: ProvisionalTransport
        let early: EarlySubscription?
    }

    /// A fresh connection that proved itself while the one it replaces did
    /// not answer (#105).
    struct Replacement: Sendable {
        let transport: any Transport
        let connection: SharedConnection.ID?
        let latency: Duration
        let info: ServerInfo
    }

    /// Whether a new connection may subscribe before its `ping` answers:
    /// only when an earlier connection proved a protocol at or above the
    /// floor. The `ping` still decides — one that fails the floor fails the
    /// connection, early subscription and all.
    static func subscribesAlongsidePing(rememberedProtocol: Int?) -> Bool {
        guard let rememberedProtocol else { return false }
        return rememberedProtocol >= WaycarSSHTransport.minimumProtocolVersion
    }

    /// Ends a stream nobody will consume, whenever its subscribe settles.
    static func discard(_ stream: Task<HerdrEventStream, any Error>) {
        Task { try? await stream.value.end() }
    }

    /// `ensureTransport`'s plain dial: a fresh connection, offered to
    /// terminals once its socket path is ready, then proven by its `ping`.
    func dialFresh(
        for generation: UInt64
    ) async throws -> (transport: any Transport, early: EarlySubscription?) {
        let connected = try await dial()
        let transport = connected.transport
        var early: EarlySubscription?
        var offered: ProvisionalTransport?
        let firstChannel = NetworkInterval("first channel")
        do {
            guard activationIsCurrent(generation) else {
                throw TransportError.cancelled
            }
            // The clock must time the ping alone: the transport's
            // first-request prerequisites — herdr resolves the socket path
            // once per session, joining the dial-time prewarm — complete off
            // the clock (#87). A resolution failure surfaces through the
            // ping itself, which handles it like any other first-request
            // failure.
            await transport.awaitSocketPathReadiness()
            guard activationIsCurrent(generation) else {
                throw TransportError.cancelled
            }
            let proving = offerToTerminals(transport, activationGeneration: generation)
            firstChannel.end("offered")
            offered = proving
            early = startEarlySubscription(on: transport)
            let (latency, info) = try await measureLatency(on: transport)
            guard activationIsCurrent(generation) else {
                throw TransportError.cancelled
            }
            installProven(
                transport, on: connected.connection, generation: proving.generation,
                latency: latency, info: info)
            return (transport, early)
        } catch {
            forgetProtocolVersion(after: error)
            if offered == nil {
                firstChannel.end("failed")
            }
            if let offered {
                // Before the close, so a terminal the close ends reports
                // this failure rather than an ordinary end. A superseded
                // activation's teardown is no failure of the connection.
                if activationIsCurrent(generation) {
                    offered.rejection.reject(Self.transportFailure(error))
                }
                if provisional?.rejection === offered.rejection {
                    provisional = nil
                }
            }
            if let early { Self.discard(early.stream) }
            try? await transport.close()
            throw error
        }
    }

    /// The first `events.subscribe` alongside a new connection's `ping`,
    /// when the remembered protocol allows it.
    func startEarlySubscription(on transport: any Transport) -> EarlySubscription? {
        guard Self.subscribesAlongsidePing(rememberedProtocol: connectionMemory?.protocolVersion)
        else { return nil }
        let subscriptions = subscriptions
        return EarlySubscription(
            subscriptions: subscriptions,
            stream: Task { try await Self.subscribe(transport, subscriptions) })
    }

    /// Claims the connection kept across the last suspension (#105). One
    /// kept too long is retired instead, and nil returned, so the activation
    /// dials anew.
    func takeKeptConnection() async -> SharedConnection.ID? {
        guard let kept = keptConnection else { return nil }
        keptConnection = nil
        guard clock.now() - kept.since <= LivenessTiming.keptConnectionMaxAge else {
            await sharing.retire(kept.id)
            return nil
        }
        return kept.id
    }

    /// Reaches the Host through the connection kept across the suspension
    /// (#105). Getting a Transport on it may itself take round trips (tmux
    /// runs backend detection and its control-mode open), bounded by
    /// `LivenessTiming.setupDeadline`; a setup that fails on the link calls
    /// for a fresh dial at once. Only once the Transport is in hand does the
    /// liveness race start, so its `LivenessTiming.deadline` and
    /// `LivenessTiming.hedgeDelay` time the ping, not the setup, and a
    /// healthy connection whose setup is slow is not raced by a
    /// replacement. The Transport is offered to terminals at once (attach
    /// first), and its `ping` follows. A fresh dial starts beside it once
    /// the ping goes unanswered for the hedge delay, or fails on the link.
    /// If the probe answers first, the kept connection stands and the
    /// keep's hold goes back. If the hedge does, the probe's Transport is
    /// rejected and closed, the kept connection is retired, and the
    /// replacement is installed under a generation of its own. `path` names
    /// which stood.
    func resumeKept(
        _ kept: SharedConnection.ID, for generation: UInt64
    ) async throws -> (
        transport: any Transport, early: EarlySubscription?, path: NetworkAnalytics.ConnectPath
    ) {
        let outcome: LivenessRace.Outcome<KeptProbe, Replacement>
        do {
            outcome = try await probeOrReplaceKept(kept, generation: generation)
        } catch {
            forgetProtocolVersion(after: error)
            abandonKeptProbe(Self.transportFailure(error), generation: generation)
            // A link failure means the kept connection is dead; a server's
            // answer means only herdr has a problem there.
            if Self.isTransportLinkFailure(error) {
                await sharing.retire(kept)
            } else {
                await sharing.release(kept)
            }
            throw error
        }
        switch outcome {
        case .proof(let probe):
            keptProbe = nil
            // Proven: its Transport holds the connection now, not the keep.
            await sharing.release(kept)
            guard activationIsCurrent(generation) else {
                probe.proving.rejection.reject(.cancelled)
                if let early = probe.early { Self.discard(early.stream) }
                Self.close(probe.transport)
                throw TransportError.cancelled
            }
            installProven(
                probe.transport, on: probe.connection, generation: probe.proving.generation,
                latency: probe.latency, info: probe.info)
            return (probe.transport, probe.early, .kept)
        case .hedge(let replacement):
            // Terminals already riding the kept connection learn that it
            // failed, and its Transport closes without being waited for.
            abandonKeptProbe(.timedOut, generation: generation)
            await sharing.retire(kept)
            guard activationIsCurrent(generation) else {
                Self.close(replacement.transport)
                throw TransportError.cancelled
            }
            install(replacement)
            return (replacement.transport, nil, .hedge)
        }
    }

    /// `resumeKept`'s two phases: the kept connection's Transport within the
    /// setup deadline, then its ping raced against the hedge. A setup that
    /// fails on the link goes straight to the replacement.
    private func probeOrReplaceKept(
        _ kept: SharedConnection.ID, generation: UInt64
    ) async throws -> LivenessRace.Outcome<KeptProbe, Replacement> {
        let hedge = replacementHedge(replacing: kept)
        let sharing = sharing
        let connected: SharedTransport
        do {
            connected = try await LivenessRace.withDeadline(
                LivenessTiming.setupDeadline(roundTrip: lastRoundTrip), clock: clock
            ) {
                let connected = try await sharing.connect(nil)
                // Too late: the deadline passed or the activation moved on.
                if Task.isCancelled {
                    Self.close(connected.transport)
                    throw TransportError.cancelled
                }
                return connected
            }
        } catch let error where Self.isTransportLinkFailure(error) {
            return .hedge(try await hedge.start())
        }
        return try await LivenessRace.run(
            deadline: LivenessTiming.deadline(roundTrip: lastRoundTrip),
            clock: clock,
            proof: { try await self.probeKept(connected, generation: generation) },
            hedge: hedge)
    }

    /// `resumeKept`'s probe: the kept connection's Transport offered to
    /// terminals, then its `ping`. Runs in the race's own task; once the
    /// race is decided that task is cancelled, and a probe that only then
    /// starts closes the Transport instead of handing it out.
    func probeKept(
        _ connected: SharedTransport, generation: UInt64
    ) async throws -> KeptProbe {
        let transport = connected.transport
        guard activationIsCurrent(generation) else {
            Self.close(transport)
            throw TransportError.cancelled
        }
        let firstChannel = NetworkInterval("first channel")
        await transport.awaitSocketPathReadiness()
        guard activationIsCurrent(generation) else {
            firstChannel.end("cancelled")
            Self.close(transport)
            throw TransportError.cancelled
        }
        let proving = offerToTerminals(transport, activationGeneration: generation)
        firstChannel.end("offered on kept connection")
        keptTransportGeneration = proving.generation
        let early = startEarlySubscription(on: transport)
        keptProbe = KeptProbeHandout(transport: transport, proving: proving, early: early)
        let measured = try await Self.measure(transport, revalidating: false, now: clock.now)
        return KeptProbe(
            transport: transport, connection: connected.connection, proving: proving,
            early: early, latency: measured.latency, info: measured.info)
    }

    /// Undoes what a kept connection's probe handed out, once it lost or
    /// failed: terminals riding its Transport learn `failure`, its early
    /// subscribe is dropped, and it closes without being waited for.
    func abandonKeptProbe(_ failure: TransportError, generation: UInt64) {
        guard let handout = keptProbe else { return }
        keptProbe = nil
        if activationIsCurrent(generation) {
            handout.proving.rejection.reject(failure)
        }
        if provisional?.rejection === handout.proving.rejection {
            provisional = nil
        }
        if let early = handout.early { Self.discard(early.stream) }
        Self.close(handout.transport)
    }

    /// A fresh connection dialed beside one that may have died, started
    /// once that one's ping is slow or has failed on the link. `roundTrip`
    /// times the hedge; it defaults to the ping's.
    func replacementHedge(
        replacing connection: SharedConnection.ID, roundTrip: Duration?? = nil
    ) -> LivenessRace.Hedging<Replacement> {
        let sharing = sharing
        let now = clock.now
        return LivenessRace.Hedging(
            after: LivenessTiming.hedgeDelay(roundTrip: roundTrip ?? lastRoundTrip),
            startsOn: { Self.isTransportLinkFailure($0) },
            start: { try await Self.dialReplacement(sharing, replacing: connection, now: now) },
            discard: { try? await $0.transport.close() })
    }

    static func dialReplacement(
        _ sharing: SharedConnection, replacing connection: SharedConnection.ID,
        now: @escaping @Sendable () -> ContinuousClock.Instant
    ) async throws -> Replacement {
        let fresh = try await sharing.connect(connection)
        do {
            await fresh.transport.awaitSocketPathReadiness()
            let measured = try await measure(fresh.transport, revalidating: false, now: now)
            return Replacement(
                transport: fresh.transport, connection: fresh.connection,
                latency: measured.latency, info: measured.info)
        } catch {
            try? await fresh.transport.close()
            throw error
        }
    }

    /// Installs a replacement its own ping proved (#105): published under a
    /// generation of its own, and handed to waiting RPCs and terminals.
    func install(_ replacement: Replacement) {
        installProven(
            replacement.transport, on: replacement.connection,
            generation: reserveTransportGeneration(),
            latency: replacement.latency, info: replacement.info)
        resumeTerminalTransportWaiters(
            with: TerminalTransportReady(
                transport: replacement.transport, activationGeneration: activationGeneration,
                transportGeneration: transportGeneration, rejection: nil))
    }

    /// A replacement won `revalidate()`'s hedge (#105): the installed
    /// connection did not answer in time. The replacement is installed. The
    /// events channel rode the connection that lost, so it re-subscribes on
    /// the replacement without a `.reconnecting`. The lost connection is
    /// retired and its Transport closed.
    func adopt(
        _ replacement: Replacement, replacing old: any Transport, on stream: HerdrEventStream
    ) async {
        guard isLiveStream(stream), isSameTransport(currentTransport, old) else {
            Self.close(replacement.transport)
            return
        }
        if let lost = currentConnection { await sharing.retire(lost) }
        guard isLiveStream(stream), isSameTransport(currentTransport, old) else {
            Self.close(replacement.transport)
            return
        }
        stopKeepalive()
        install(replacement)
        Self.close(old)
        resubscribeRequested = true
        await stream.end()
    }

    /// Closes `transport` without waiting: nothing on the caller's path may
    /// wait on a connection that stopped answering.
    static func close(_ transport: any Transport) {
        Task { try? await transport.close() }
    }

    /// Hands a new connection's Transport to terminals ahead of its `ping`
    /// (#105): every terminal waiting for this activation gets it, under the
    /// generation reserved for it. Observers see that generation only once
    /// the `ping` proves the connection.
    func offerToTerminals(
        _ transport: any Transport, activationGeneration: UInt64
    ) -> ProvisionalTransport {
        let offered = ProvisionalTransport(
            transport: transport, generation: reserveTransportGeneration())
        provisional = offered
        transportSuspect = false
        resumeTerminalTransportWaiters(
            with: offered.ready(activationGeneration: activationGeneration))
        return offered
    }

    /// The next generation for a new connection: the first connection's is
    /// 0, and each later one's is one past the last reserved.
    func reserveTransportGeneration() -> UInt64 {
        if hasReservedTransportGeneration {
            reservedTransportGeneration &+= 1
        } else {
            hasReservedTransportGeneration = true
        }
        return reservedTransportGeneration
    }

    /// A connection offered to terminals ahead of its `ping` (#105).
    struct ProvisionalTransport {
        let transport: any Transport
        /// Published as `transportGeneration` once the `ping` proves it.
        let generation: UInt64
        let rejection = ProvisionalRejection()

        func ready(activationGeneration: UInt64) -> TerminalTransportReady {
            TerminalTransportReady(
                transport: transport, activationGeneration: activationGeneration,
                transportGeneration: generation, rejection: rejection)
        }
    }

    /// Why a provisional connection's `ping` failed, kept for the terminals
    /// already riding it so they report that failure (`withTerminalTransport`).
    final class ProvisionalRejection: Sendable {
        private let state = Mutex<TransportError?>(nil)

        var failure: TransportError? { state.withLock { $0 } }

        func reject(_ failure: TransportError) {
            state.withLock { $0 = failure }
        }
    }
}
