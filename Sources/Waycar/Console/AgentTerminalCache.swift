import Foundation

/// Agent attaches share the Host's bounded LRU retention budget with shells.
/// Entries are lazy: listing or constructing a detail never opens a PTY. A
/// shell row is cached like an Agent's, attached by terminal id; an entry
/// never survives its row changing between shell and Agent, whose Composer
/// delivery and staging differ.
@MainActor
final class AgentTerminalCache {
    @MainActor
    final class Entry {
        let agentID: ConsoleAgent.ID
        let terminalID: String
        let target: TerminalAttachTarget
        /// The row's backend: only its projection's snapshots and transport
        /// generations reconcile the entry (ADR 0026).
        let backend: HostBackend
        let attach: AgentAttachStore
        let surfaceRetention = TerminalSurfaceRetention()
        fileprivate let lifetime: Lifetime
        fileprivate var expiry: Task<Void, Never>?
        fileprivate var presentationOwnerID: UUID? { lifetime.retention.presentationOwnerID }
        var isRetained: Bool { lifetime.retention.isRetained }

        fileprivate init(
            agentID: ConsoleAgent.ID, terminalID: String, target: TerminalAttachTarget,
            backend: HostBackend, attach: AgentAttachStore, lifetime: Lifetime
        ) {
            self.agentID = agentID
            self.terminalID = terminalID
            self.target = target
            self.backend = backend
            self.attach = attach
            self.lifetime = lifetime
        }
    }

    @MainActor
    fileprivate final class Lifetime {
        let ownerID = UUID()
        var retention: AgentTerminalRetentionMachine
        var isPresented: (@MainActor () -> Bool)?

        init(presentationOwnerID: UUID) {
            retention = AgentTerminalRetentionMachine(ownerID: presentationOwnerID)
        }
    }

    private(set) var entries: [ConsoleAgent.ID: Entry] = [:]
    private var teardowns: [ConsoleAgent.ID: Task<Void, Never>] = [:]
    private let budget: TerminalRetentionBudget
    let idleTimeout: Duration
    /// The grid each layout last had, so an acquired Agent's attach starts
    /// at once (#105); nil waits for the view's first layout. The app's
    /// (`WaycarAppModel` owns it).
    var gridSizes: TerminalGridSizeMemory?

    init(
        budget: TerminalRetentionBudget = TerminalRetentionBudget(),
        idleTimeout: Duration = .seconds(300)
    ) {
        self.budget = budget
        self.idleTimeout = idleTimeout
    }

    /// Only the window holding the Host's Agent presentation may acquire.
    /// Offstage details keep private stores until they are activated.
    /// `windowLayout` is that window's, which the terminal's remembered grid
    /// is keyed by.
    func acquire(
        agent: ConsoleAgent, console: ConsoleStore, composer: AgentComposerStore,
        ownerID: UUID,
        windowLayout: @escaping @MainActor () -> TerminalGridSizeMemory.Layout? = { nil },
        isPresented: @escaping @MainActor () -> Bool = { true }
    ) -> Entry {
        if let current = entries[agent.id], current.terminalID == agent.agent.terminalID,
            current.target == agent.attachTarget, current.backend == agent.backend,
            !current.lifetime.retention.isVisible || current.presentationOwnerID == ownerID
        {
            _ = current.lifetime.retention.handle(.claimPresentation(ownerID))
            current.attach.windowLayout = windowLayout
            activate(current, ownerID: ownerID, isPresented: isPresented)
            console.noteAgentViewed(agent.id, windowLayout: windowLayout)
            return current
        }
        if let old = entries[agent.id] { evict(old) }
        let predecessor = teardowns[agent.id]
        let runner = console.terminalRunner(for: agent.hostID, backend: agent.backend)
        let lifetime = Lifetime(presentationOwnerID: ownerID)
        lifetime.isPresented = isPresented
        let attach = AgentAttachStore(
            target: agent.attachTarget,
            transportGeneration: console.connectionGeneration(for: agent),
            recordsNetworkTelemetry: agent.recordsNetworkTelemetry,
            gridSizes: gridSizes,
            isOnStage: { lifetime.retention.isRetained },
            runTerminal: { [weak self] request, handler in
                await predecessor?.value
                try Task.checkCancellation()
                guard let self else { throw CancellationError() }
                try await self.admit(agentID: agent.id, lifetime: lifetime)
                try Task.checkCancellation()
                try await runner(request, handler)
            },
            stageImage: console.imageStager(for: agent.hostID),
            stageFile: console.fileStager(for: agent.hostID),
            composer: composer,
            paneHistory: console.makePaneHistory(for: agent),
            closePane: { [weak console] in
                guard let console else { throw CancellationError() }
                try await console.closePane(agent.agent.paneID, on: agent.hostID)
            },
            invalidateMosh: { [weak console] cause in
                guard let console else { return }
                console.invalidateMosh(for: agent.hostID, cause: cause)
            },
            onUserInput: { [weak console] in
                console?.noteUserInput(to: agent.id)
            })
        let entry = Entry(
            agentID: agent.id, terminalID: agent.agent.terminalID, target: agent.attachTarget,
            backend: agent.backend, attach: attach, lifetime: lifetime)
        entries[agent.id] = entry
        attach.windowLayout = windowLayout
        // The detail exists: its attach starts now, not after its layout.
        attach.startAtIntent()
        console.noteAgentViewed(agent.id, windowLayout: windowLayout)
        return entry
    }

    private func admit(agentID: ConsoleAgent.ID, lifetime: Lifetime) async throws {
        guard let entry = entries[agentID], entry.lifetime === lifetime, lifetime.retention.isRetained else {
            throw CancellationError()
        }
        try await budget.admit(
            key: key(for: entry), ownerID: lifetime.ownerID,
            isVisible: {
                lifetime.retention.isRetained && lifetime.retention.isVisible && (lifetime.isPresented?() ?? false)
            },
            onEvict: { [weak self, weak entry] in
                guard let self, let entry else { return }
                await self.evict(entry).value
            })
        guard lifetime.retention.isRetained else { throw CancellationError() }
    }

    func activate(
        _ entry: Entry, ownerID: UUID,
        isPresented: @escaping @MainActor () -> Bool = { true }
    ) {
        guard entries[entry.agentID] === entry, entry.presentationOwnerID == ownerID else { return }
        for case .cancelExpiry in entry.lifetime.retention.handle(.activate(ownerID)) {
            entry.expiry?.cancel()
            entry.expiry = nil
        }
        entry.lifetime.isPresented = isPresented
        budget.touch(key: key(for: entry), ownerID: entry.lifetime.ownerID)
        entry.attach.rejoin()
    }

    /// `keepingKeyboard` is a departure whose keyboard the next screen takes
    /// over; the surface then keeps first responder until that claim.
    func release(_ entry: Entry, ownerID: UUID, keepingKeyboard: Bool = false) {
        guard entries[entry.agentID] === entry, entry.presentationOwnerID == ownerID else { return }
        let effects = entry.lifetime.retention.handle(.release(ownerID))
        entry.lifetime.isPresented = nil
        entry.attach.leaveInteractionsForRetention()
        entry.surfaceRetention.detachCallbacks(keepingKeyboard: keepingKeyboard)
        budget.markIdle(key: key(for: entry), ownerID: entry.lifetime.ownerID)
        for case .scheduleExpiry(let token) in effects {
            entry.expiry?.cancel()
            entry.expiry = Task { @MainActor [weak self, weak entry] in
                guard let self, let entry else { return }
                do { try await Task.sleep(for: idleTimeout) } catch { return }
                guard entries[entry.agentID] === entry else { return }
                for case .evict in entry.lifetime.retention.handle(.expiryElapsed(token)) {
                    await evict(entry).value
                }
            }
        }
    }

    /// Tears down the Host's entries: every backend's, or with `backend`
    /// only that one's (its projection ended).
    func removeHost(_ hostID: Host.ID, backend: HostBackend? = nil) async {
        let entryBackends = entries.mapValues(\.backend)
        await remove { id in
            guard id.hostID == hostID else { return false }
            guard let backend else { return true }
            // A teardown still running without its entry belongs to whichever
            // backend it was; waiting on it is harmless either way.
            return entryBackends[id].map { $0 == backend } ?? true
        }
    }

    func suspend() async {
        await remove { _ in true }
    }

    /// Starts every matching teardown before awaiting any. Ending a mosh
    /// terminal waits up to about a second for its Host to acknowledge, and
    /// suspension runs on the few seconds of background time left (#19).
    private func remove(where matches: (ConsoleAgent.ID) -> Bool) async {
        let identities = Set(entries.keys).union(teardowns.keys).filter(matches)
        for id in identities {
            if let entry = entries[id] { evict(entry) }
        }
        for id in identities {
            let teardown = teardowns[id]
            await teardown?.value
            // Another eviction may have replaced the teardown while this one ended.
            if teardowns[id] == teardown { teardowns[id] = nil }
        }
    }

    /// A held terminal off screen goes with its connection, except one on
    /// mosh: its UDP session never rode that connection (#105).
    func transportGenerationDidChange(
        _ generation: UInt64?, for hostID: Host.ID, backend: HostBackend = .herdr,
        isCurrent: @escaping @MainActor () -> Bool = { true }
    ) async {
        for entry in entries.values.filter({ $0.agentID.hostID == hostID && $0.backend == backend }) {
            guard isCurrent() else { return }
            if entry.lifetime.retention.isVisible || entry.attach.terminalRunsMosh {
                entry.attach.transportGenerationDidChange(generation)
            } else {
                await evict(entry).value
            }
        }
    }

    /// The host-level mosh capsule's tap: every visible Agent terminal on
    /// the Host still riding SSH gets restarted so the runner re-selects
    /// mosh now that the Host's probe proved it; with `connectingOnly`,
    /// only one still opening (a connect-time probe landing, #105).
    func upgradeSSHAttachToMosh(for hostID: Host.ID, connectingOnly: Bool = false) {
        for entry in entries.values.filter({ $0.agentID.hostID == hostID })
        where entry.lifetime.retention.isVisible {
            entry.attach.upgradeToMoshIfNeeded(connectingOnly: connectingOnly)
        }
    }

    func reconcile(
        hostID: Host.ID, backend: HostBackend = .herdr, agents: [ConsoleAgent],
        isCurrent: @escaping @MainActor () -> Bool = { true }
    ) async {
        for entry in entries.values.filter({ $0.agentID.hostID == hostID && $0.backend == backend }) {
            guard isCurrent() else { return }
            if !agents.contains(where: {
                $0.id == entry.agentID && $0.agent.terminalID == entry.terminalID
                    && $0.attachTarget == entry.target
            }) {
                await evict(entry).value
            }
        }
    }

    private func key(for entry: Entry) -> TerminalRetentionBudget.Key {
        TerminalRetentionBudget.Key(hostID: entry.agentID.hostID, terminalID: entry.terminalID)
    }

    @discardableResult
    private func evict(_ entry: Entry) -> Task<Void, Never> {
        let id = entry.agentID
        guard case .tearDown(let token)? = entry.lifetime.retention.handle(.evict).first else {
            return teardowns[id] ?? Task {}
        }
        entry.expiry?.cancel()
        entry.expiry = nil
        entry.lifetime.isPresented = nil
        if entries[id] === entry { entries[id] = nil }
        let prior = teardowns[id]
        let leaving = entry.attach.leaveForTerminalHandoff()
        let key = key(for: entry)
        let budget = budget
        let task = Task { @MainActor in
            await prior?.value
            await leaving.value
            entry.surfaceRetention.clear()
            budget.remove(key: key, ownerID: entry.lifetime.ownerID)
            _ = entry.lifetime.retention.handle(.teardownFinished(token))
        }
        teardowns[id] = task
        return task
    }
}
