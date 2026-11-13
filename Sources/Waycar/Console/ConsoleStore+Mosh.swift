import Foundation

/// mosh availability per Host and network, and the standbys kept ahead of
/// attaches (#105).
extension ConsoleStore {
enum MoshHostCapsuleState: Equatable, Sendable {
    case untested
    case testing
    case available
    case unavailable

    /// The transport word for menus: MOSH once a probe proved it, SSH
    /// otherwise, and a testing note while a forced probe runs.
    var transportLabel: String {
        switch self {
        case .available: "MOSH"
        case .testing: "Testing mosh…"
        case .untested, .unavailable: "SSH"
        }
    }
}

struct MoshProbeOutcome: Equatable {
        let generation: UInt64
        let available: Bool
    }

    /// Whether mosh was invalidated for the Host on `generation` or later,
    /// or by the user on any generation.
    private func moshInvalidated(_ hostID: Host.ID, through generation: UInt64) -> Bool {
        guard let record = moshInvalidations[hostID] else { return false }
        return record.cause == .userChoseSSH || record.generation >= generation
    }

    private func userChoseSSH(on hostID: Host.ID) -> Bool {
        moshInvalidations[hostID]?.cause == .userChoseSSH
    }

    /// The mosh runner's availability input: what is known now — this
    /// connection's probe or a mosh session's proof, else the outcome
    /// remembered for the network the device is on (#105), which is what a
    /// cold-restored Agent's first attach goes by. Unknown reads
    /// unavailable — SSH stays the backbone.
    func moshAvailability(for hostID: Host.ID, generation: UInt64) -> Bool {
        guard !SampleHost.isSample(hostID) else { return false }
        // Mosh compatibility is a Host property, not a per-tab or
        // per-generation one: the last proven outcome stands for every
        // attach until a newer probe (fresh connection generation, manual
        // test, network change, or a runtime mosh failure) replaces it.
        if userChoseSSH(on: hostID) { return false }
        if let state = moshStates[hostID] { return state.available }
        return rememberedMoshOutcome(for: hostID) == .available
    }

    /// What this device learned about the Host's mosh on the network it is
    /// on now, within the last day (#105).
    private func rememberedMoshOutcome(for hostID: Host.ID) -> MoshAvailabilityStore.Outcome? {
        guard let host = catalog[hostID] else { return nil }
        return moshFastPath.availability.outcome(
            for: host, network: moshFastPath.currentNetwork)
    }

    /// Marks mosh unavailable for the Host's current connection generation:
    /// the terminal runner reads SSH immediately, and the per-generation
    /// background probe may re-probe only on the next connection
    /// generation. The automatic fallback after a mosh failure and the
    /// connection dot's "Use SSH Instead" both route here; `cause`
    /// tells them apart. A user's SSH choice is never downgraded to an
    /// automatic fallback: a mosh run that began before it may still fail.
    func invalidateMosh(for hostID: Host.ID, cause: MoshInvalidationCause) {
        let generation = hostConnectionGenerations[hostID] ?? 0
        moshStates[hostID] = MoshProbeOutcome(generation: generation, available: false)
        if cause == .automaticFallback, moshInvalidations[hostID]?.cause == .userChoseSSH {
            return
        }
        moshInvalidations[hostID] = MoshInvalidationRecord(generation: generation, cause: cause)
    }

    /// What a mosh session's first contact proved (#105): an answer means
    /// mosh works on this network, a fresh server's silence that UDP does
    /// not get through. Remembered for `network`, the one the session
    /// started on, and the Host's state for this connection — unless a
    /// failure already invalidated it, or the device has moved to another
    /// network since: what was measured there says nothing about this one.
    func recordMoshOutcome(
        _ outcome: MoshAvailabilityStore.Outcome, for hostID: Host.ID, on network: NetworkPathKey?
    ) {
        guard let host = catalog[hostID], network == moshFastPath.currentNetwork else { return }
        moshFastPath.availability.record(outcome, for: host, network: network)
        let generation = hostConnectionGenerations[hostID] ?? 0
        if outcome == .available, moshInvalidated(hostID, through: generation) {
            return
        }
        let state = MoshProbeOutcome(generation: generation, available: outcome == .available)
        if moshStates[hostID] != state { moshStates[hostID] = state }
    }

    /// Test surface: the cached probe outcome, proving the probe ran (once)
    /// and how it was cached.
    func moshProbe(for hostID: Host.ID) -> (generation: UInt64, available: Bool)? {
        guard let probe = moshStates[hostID] else { return nil }
        return (probe.generation, probe.available)
    }

    /// The Console index's per-Host mosh capsule. Compatibility is a Host
    /// property, so the capsule state lives here rather than on any one
    /// terminal tab — every session on the Host shares it.

    /// What the Host's mosh capsule renders. A forced re-probe in flight
    /// shows testing; otherwise the last proven outcome, or untested
    /// before any probe has landed for the Host.
    func moshCapsuleState(for hostID: Host.ID) -> MoshHostCapsuleState {
        if moshProbeClaims[hostID] != nil { return .testing }
        guard let outcome = moshStates[hostID] else { return .untested }
        return outcome.available ? .available : .unavailable
    }

    /// The capsule's tap: re-probes mosh over the Host's live connection
    /// and, when mosh is there, upgrades the Host's SSH terminals to it. A
    /// failed probe just records unavailable — the SSH fallback is silent
    /// by design, and the Host's sessions keep running over SSH. The tap
    /// asks mosh again: it supersedes an earlier fallback or "Use SSH
    /// Instead". An invalidation during this probe still wins.
    func forceMoshReprobe(for hostID: Host.ID) async {
        guard !SampleHost.isSample(hostID) else { return }
        guard moshProbeClaims[hostID] == nil,
            let projection = moshProjection(on: hostID),
            projection.status == .connected
        else { return }
        moshInvalidations[hostID] = nil
        let generation = projection.transportGeneration
        // One probe per connection generation, whichever kicks first: a
        // capsule tap claims the generation so the connect-time probe
        // does not duplicate it.
        moshProbedGenerations[hostID] = generation
        let claim = UUID()
        moshProbeClaims[hostID] = claim
        startMoshProbe(on: hostID) { [weak self, weak projection] in
            guard let self else { return }
            defer {
                if moshProbeClaims[hostID] == claim {
                    moshProbeClaims[hostID] = nil
                }
            }
            guard let projection, moshProjection(on: hostID) === projection,
                projection.transportGeneration == generation,
                projection.status == .connected,
                let available = await probeMosh(over: projection)
            else { return }
            if moshProbeLandedStale(on: hostID, generation: generation) { return }
            moshStates[hostID] = MoshProbeOutcome(
                generation: generation, available: available)
            if available {
                agentTerminals.upgradeSSHAttachToMosh(for: hostID)
            }
        }
    }

    private func startMoshProbe(
        on hostID: Host.ID, _ probe: @escaping @MainActor () async -> Void
    ) {
        moshProbeTasks[hostID]?.cancel()
        moshProbeTasks[hostID] = Task { await probe() }
    }

    /// Runs the mosh handshake probe over `projection`'s connection. A
    /// definite answer — a handshake, or none getting through — is
    /// remembered for the network the probe began on (#105); a probe the
    /// link cut short is only this connection's unavailable. nil when the
    /// answer no longer counts: the probe was cancelled, or the device
    /// moved to another network meanwhile.
    private func probeMosh(over projection: HostConsoleProjection) async -> Bool? {
        let network = moshFastPath.currentNetwork
        let outcome: MoshAvailabilityStore.Outcome?
        let available: Bool
        do {
            available = try await projection.session.withTransport { transport in
                try await transport.probeMoshServer()
            }
            outcome = available ? .available : .unavailable
        } catch TransportError.moshSessionFailed {
            (available, outcome) = (false, .unavailable)
        } catch {
            (available, outcome) = (false, nil)
        }
        guard !Task.isCancelled, network == moshFastPath.currentNetwork else { return nil }
        if let outcome, let host = catalog[projection.host.id] {
            moshFastPath.availability.record(outcome, for: host, network: network)
        }
        return available
    }

    /// Newest-generation-wins and invalidation guards: a probe landing for
    /// a replaced connection must not override a newer generation's
    /// outcome, and a probe racing an invalidation must not re-mark a
    /// failed handshake as available before the next generation.
    private func moshProbeLandedStale(on hostID: Host.ID, generation: UInt64) -> Bool {
        if moshStates[hostID].map({ $0.generation > generation }) ?? false { return true }
        return moshInvalidated(hostID, through: generation)
    }

    /// The connect-time half of the Host's mosh availability, once per
    /// connection generation on a mosh-capable projection (#105). What is
    /// remembered for this network answers at once — before the Host has
    /// even connected, so a cold-restored Agent attaches over mosh. With
    /// nothing fresh remembered the probe runs, but off the attach's path:
    /// after this connection's first snapshot, never while an attach
    /// bootstraps mosh on the Host. A probe proving mosh upgrades an SSH
    /// attach still connecting.
    func reconcileMoshAvailability(_ projection: HostConsoleProjection) {
        let hostID = projection.host.id
        guard !SampleHost.isSample(hostID) else { return }
        let generation = projection.transportGeneration
        guard projection === moshProjection(on: hostID),
            moshProbedGenerations[hostID] != generation
        else { return }
        if let remembered = rememberedMoshOutcome(for: hostID) {
            moshProbedGenerations[hostID] = generation
            guard !moshInvalidated(hostID, through: generation) else {
                return
            }
            let state = MoshProbeOutcome(
                generation: generation, available: remembered == .available)
            if moshStates[hostID] != state { moshStates[hostID] = state }
            return
        }
        guard projection.status == .connected, !projection.isAwaitingSnapshot,
            !userChoseSSH(on: hostID),
            !moshFastPath.standbys.hasAttachBootstrap(on: hostID)
        else { return }
        moshProbedGenerations[hostID] = generation
        startMoshProbe(on: hostID) { [weak self, weak projection] in
            guard let self, let projection, moshProjection(on: hostID) === projection,
                projection.transportGeneration == generation
            else { return }
            guard let available = await probeMosh(over: projection) else {
                // The answer no longer counts because the network changed
                // (and maybe changed back inside the debounce): give the
                // generation back so the next reconcile probes again. A
                // cancelled probe gives nothing back: whatever cancelled it
                // — a capsule re-probe, a new network — holds the claim now.
                if !Task.isCancelled, moshProbedGenerations[hostID] == generation {
                    moshProbedGenerations[hostID] = nil
                }
                return
            }
            if moshProbeLandedStale(on: hostID, generation: generation) { return }
            moshStates[hostID] = MoshProbeOutcome(
                generation: generation, available: available)
            if available {
                agentTerminals.upgradeSSHAttachToMosh(for: hostID, connectingOnly: true)
            }
        }
    }

    func reconcileMoshAvailability() {
        for projection in projections.values {
            reconcileMoshAvailability(projection)
        }
    }

    /// Puts in the app's fast path (#105) — remembered outcomes on disk,
    /// the app's network path — and starts it with the Console. Projections
    /// already running take it up at once.
    func installMoshFastPath(_ fastPath: MoshFastPath) {
        moshFastPath = fastPath
        fastPath.networkDidChange = { [weak self] key in self?.moshNetworkDidChange(to: key) }
        fastPath.standbys.attachBootstrapsDidSettle = { [weak self] _ in
            self?.reconcileMoshAvailability()
        }
        for projection in projections.values {
            projection.moshAttach = makeMoshAttach(for: projection)
        }
        fastPath.start()
        rebuild()
    }

    func makeMoshAttach(for projection: HostConsoleProjection) -> MoshAttachCoordinator {
        let hostID = projection.host.id
        return MoshAttachCoordinator(
            hostID: hostID, backend: projection.backend, fastPath: moshFastPath,
            available: { [weak self, weak projection] in
                guard let self, let projection else { return false }
                return moshAvailability(for: hostID, generation: projection.transportGeneration)
            },
            currentNetwork: { [weak self] in self?.moshFastPath.currentNetwork },
            recordOutcome: { [weak self] outcome, network in
                self?.recordMoshOutcome(outcome, for: hostID, on: network)
            },
            serverHeardAgain: { [weak self] in
                self?.moshServerAnsweredAfterStall(on: hostID)
            })
    }

    /// A mosh session's server answered again after a stall (#105): the
    /// link is back, often seconds before the Host's SSH would try again —
    /// a silent outage moves no network path, and a reconnect may be
    /// sleeping out its backoff or stuck on a dial that timed out. Every
    /// backend of the Host that is not connected redials at once
    /// (`EventsSession.redialNow(trigger:)`). At most once per
    /// `moshRecoveryRedialInterval` per Host, and never while suspended.
    func moshServerAnsweredAfterStall(on hostID: Host.ID) {
        guard isActive else { return }
        let stale = projections.values.filter { $0.host.id == hostID && $0.status != .connected }
        guard !stale.isEmpty else { return }
        let now = ContinuousClock.now
        if let last = moshRecoveryRedials[hostID], now - last < moshRecoveryRedialInterval {
            return
        }
        moshRecoveryRedials[hostID] = now
        NetworkLog.logger.notice("mosh answered after a stall: redialling its Host")
        for projection in stale {
            let session = projection.session
            Task { await session.redialNow(trigger: .moshRecovery) }
        }
    }

    /// A new network (#105): what was known about mosh held for the old one,
    /// so each Host answers again from what is remembered for this one, or
    /// probes; a probe still running on the old one is dropped. Running
    /// sessions were already asked to rebind. A Host the user moved to SSH
    /// stays there: only automatic invalidations held for the old network
    /// alone. Losing the path (`nil`) is no new network: nothing is known
    /// there and nothing can be probed, so what is known stays for the
    /// path's return.
    private func moshNetworkDidChange(to network: NetworkPathKey?) {
        for probe in moshProbeTasks.values { probe.cancel() }
        moshProbeTasks = [:]
        guard network != nil else { return }
        let userChoices = moshInvalidations.filter { $0.value.cause == .userChoseSSH }
        for hostID in moshStates.keys where userChoices[hostID] == nil {
            moshStates[hostID] = nil
        }
        moshProbedGenerations = moshProbedGenerations.filter { userChoices[$0.key] != nil }
        moshInvalidations = userChoices
        reconcileMoshAvailability()
    }

    // MARK: Standby mosh (#105)

    struct SpeculativeStandby {
        let agentID: ConsoleAgent.ID
        let key: StandbyMoshStore.Key
        let task: Task<Void, Never>
    }

    /// At Background Grace expiry, before suspension tears the attaches
    /// down: every live mosh Agent attach gets a standby for its target over
    /// its Host's still-open SSH connection, all within `budget`; the
    /// teardown then goes ahead as before. A return within
    /// `StandbyMoshStore.maxAge` starts the shown Agent's client straight
    /// at its standby.
    func prepareMoshStandbys(within budget: Duration) async {
        var preparations: [Task<Void, Never>] = []
        for entry in agentTerminals.entries.values where entry.attach.terminalRunsLiveMosh {
            guard case .agentPane = entry.target,
                let projection = projection(on: entry.agentID.hostID, backend: entry.backend),
                projection.status == .connected
            else { continue }
            let size = entry.attach.terminalGridSize
            let request = TerminalAttachRequest(
                target: entry.target, takeover: true,
                cols: size?.cols ?? 80, rows: size?.rows ?? 24)
            let key = StandbyMoshStore.Key(
                hostID: entry.agentID.hostID, backend: entry.backend, target: entry.target)
            if let preparation = moshFastPath.standbys.prepare(
                key, origin: .graceExpiry, budget: budget,
                bootstrap: MoshFastPath.standbyBootstrap(
                    over: projection.session, priority: .interactive, request))
            {
                preparations.append(preparation)
            }
        }
        guard !preparations.isEmpty else { return }
        // A speculative preparation already running keeps its own budget;
        // the teardown waits for none past this one.
        _ = try? await AsyncDeadline.run(for: budget) { [preparations] in
            for preparation in preparations {
                await preparation.value
            }
        }
    }

    /// The Agent whose screen was just opened, from the terminal cache: its
    /// Host's speculative standby follows it, at the grid of the window it
    /// was opened in.
    func noteAgentViewed(
        _ id: ConsoleAgent.ID,
        windowLayout: @escaping @MainActor () -> TerminalGridSizeMemory.Layout? = { nil }
    ) {
        standbyLayouts[id.hostID] = windowLayout
        guard standbyAgents[id.hostID] != id else { return }
        standbyAgents[id.hostID] = id
        reconcileSpeculativeStandbys()
    }

    /// A notification, Live Activity or link named this Agent: its Host's
    /// standby is made for it now, so the attach that follows finds it.
    /// Someone is about to wait on that first preparation, so it runs
    /// `.interactive`; its timed renewals stay `.normal`.
    func noteAgentIntent(_ id: ConsoleAgent.ID) {
        guard !SampleHost.isSample(id.hostID) else { return }
        if standbyAgents[id.hostID] != id { standbyLayouts[id.hostID] = nil }
        standbyAgents[id.hostID] = id
        // The same Agent's renewal may be asleep: it looks again now.
        if speculativeStandbys[id.hostID]?.agentID == id {
            speculativeStandbys.removeValue(forKey: id.hostID)?.task.cancel()
        }
        reconcileSpeculativeStandbys(namedByIntent: id)
    }

    /// Keeps one standby per Host for its last-viewed Agent while the
    /// Console is in front and the Host connected, renewed before it ages
    /// out (#105). An Agent whose own terminal is still held needs none: a
    /// tap shows that terminal. Another Agent taking the Host's place drops
    /// the standby kept for the one before; one whose renewal merely stops
    /// (its terminal opened, the Console left) stays for an attach to take.
    func reconcileSpeculativeStandbys(namedByIntent intent: ConsoleAgent.ID? = nil) {
        let hostIDs = projectedHostIDs
        for (hostID, standby) in speculativeStandbys {
            let wanted = hostIDs.contains(hostID) ? speculativeStandbyAgent(on: hostID) : nil
            guard wanted != standby.agentID else { continue }
            standby.task.cancel()
            speculativeStandbys[hostID] = nil
            if wanted != nil {
                moshFastPath.standbys.discard(standby.key)
            }
        }
        for hostID in hostIDs where speculativeStandbys[hostID] == nil {
            guard let agentID = speculativeStandbyAgent(on: hostID),
                let agent = agents.first(where: { $0.id == agentID })
            else { continue }
            speculativeStandbys[hostID] = SpeculativeStandby(
                agentID: agentID,
                key: StandbyMoshStore.Key(
                    hostID: hostID, backend: agent.backend, target: agent.attachTarget),
                task: Task { [weak self] in
                    await self?.keepSpeculativeStandby(
                        for: agentID, firstAwaited: agentID == intent)
                })
        }
    }

    private func speculativeStandbyAgent(on hostID: Host.ID) -> ConsoleAgent.ID? {
        guard isActive, let agentID = standbyAgents[hostID],
            let agent = agents.first(where: { $0.id == agentID }),
            case .agentPane = agent.attachTarget,
            let projection = projection(on: hostID, backend: agent.backend),
            projection.status == .connected,
            moshAvailability(for: hostID, generation: projection.transportGeneration),
            agentTerminals.entries[agentID]?.isRetained != true
        else { return nil }
        return agentID
    }

    private func keepSpeculativeStandby(
        for agentID: ConsoleAgent.ID, firstAwaited: Bool
    ) async {
        let standbys = moshFastPath.standbys
        var priority: TransportPriority = firstAwaited ? .interactive : .normal
        while !Task.isCancelled {
            guard speculativeStandbyAgent(on: agentID.hostID) == agentID,
                let agent = agents.first(where: { $0.id == agentID }),
                let projection = projection(on: agentID.hostID, backend: agent.backend)
            else { return }
            let key = StandbyMoshStore.Key(
                hostID: agentID.hostID, backend: agent.backend, target: agent.attachTarget)
            let refresh = moshFastPath.speculativeStandbyRefresh
            if standbys.standby(for: key).map({ standbys.age(of: $0) >= refresh }) ?? true {
                let size = speculativeStandbySize(on: agentID.hostID)
                let request = TerminalAttachRequest(
                    target: agent.attachTarget, takeover: true,
                    cols: size?.cols ?? 80, rows: size?.rows ?? 24)
                await standbys.prepare(
                    key, origin: .speculative,
                    // An intent's first preparation is about to be waited
                    // on; a renewal nobody waits on queues behind other work.
                    bootstrap: MoshFastPath.standbyBootstrap(
                        over: projection.session, priority: priority, request)
                )?.value
                priority = .normal
            }
            let wait = standbys.standby(for: key).map { refresh - standbys.age(of: $0) } ?? refresh
            do { try await Task.sleep(for: max(wait, .milliseconds(100))) } catch { return }
        }
    }

    /// The grid the Host's speculative standby starts at: what the window
    /// its Agent was last opened in had, else the grid reported last.
    private func speculativeStandbySize(on hostID: Host.ID) -> TerminalGridSizeMemory.GridSize? {
        guard let gridSizes = agentTerminals.gridSizes else { return nil }
        return gridSizes.size(for: standbyLayouts[hostID]?()) ?? gridSizes.lastRecordedSize
    }

    /// Drops everything kept for standbys on the Host: it left, or its
    /// connection target or backends changed.
    func forgetMoshStandbys(on hostID: Host.ID) {
        speculativeStandbys.removeValue(forKey: hostID)?.task.cancel()
        standbyAgents[hostID] = nil
        standbyLayouts[hostID] = nil
        moshFastPath.standbys.discard(hostID: hostID)
    }
}
