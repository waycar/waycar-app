import Foundation
import Observation

/// Per-Host Live Activity state machine. The Console's Agent list is the
/// source of truth while the app is foregrounded; after a 3-second settle
/// the coordinator starts, updates, or ends one activity per Host. Push
/// tokens are written to the Host registration file so the plugin can keep
/// the activity alive after the app suspends, and this install's
/// push-to-start token lets the plugin start one while the app is not
/// running. An activity the plugin started is adopted, never duplicated:
/// when a Host has more than one, the newest wins and the rest end. One iOS
/// ended (its 8-hour limit) stays on the Lock Screen, frozen, until it is
/// dismissed, so it is dismissed and replaced, never adopted or left beside
/// a new one.
///
/// `knownHostIDs` holds one entry per computer (`activityHostIDs`): two Host
/// entries for the same machine share its registration file and its one
/// device entry, so every clear removes only what this Host wrote there.
@MainActor
@Observable
final class HostLiveActivityCoordinator {
    let preferences: LiveActivityPreferences

    @ObservationIgnored private let controller: any LiveActivityControlling
    @ObservationIgnored private let transports: any NotificationTransportProvider
    @ObservationIgnored private let keys: NotificationKeyStore
    @ObservationIgnored private let ceremony: NotificationRegistrationCeremony
    @ObservationIgnored private let deviceToken: @MainActor () -> APNSDeviceToken?
    @ObservationIgnored private let knownHostIDs: @MainActor () -> Set<Host.ID>
    @ObservationIgnored private let hostDisplayName: @MainActor (Host.ID) -> String
    @ObservationIgnored private let isAwaitingSnapshot: @MainActor (Host.ID) -> Bool
    @ObservationIgnored private let connectionStatus: @MainActor (Host.ID) -> EventsSessionStatus?
    @ObservationIgnored private let pinnedPaneIDs: @MainActor (Host.ID) -> [String]
    @ObservationIgnored private let rowLayout: @MainActor (Host.ID) -> AgentRowLayout?
    @ObservationIgnored private let settleDuration: Duration
    @ObservationIgnored private let now: @MainActor () -> Date

    @ObservationIgnored private var lifecycle = LiveActivityLifecycleMachine()
    private var didStart: Bool { lifecycle.state.isStarted }
    private var applied: [Host.ID: AgentActivityDesire] { lifecycle.applied }
    private var sessions: [Host.ID: LiveActivityLifecycleMachine.Session] { lifecycle.sessions }
    private var failedStarts: Set<Host.ID> { lifecycle.failedStarts }
    @ObservationIgnored private var latestAgents: [Host.ID: [ConsoleAgent]] = [:]
    @ObservationIgnored private var settleTasks: [UInt64: Task<Void, Never>] = [:]
    @ObservationIgnored private var watchers: [String: ActivityWatchers] = [:]
    @ObservationIgnored private var pipes: [Host.ID: LiveActivityRegistrationMachine] = [:]
    @ObservationIgnored private var pipeTasks: [Host.ID: [UInt64: Task<Void, Never>]] = [:]
    /// Activities this coordinator dropped or ended. ActivityKit may keep
    /// listing or re-announce them briefly; none may be adopted again, and
    /// any still listed is ended again, so none lingers on the Lock Screen.
    private var retiredActivityIDs: Set<String> { lifecycle.state.retiredIDs }
    /// This install's push-to-start token (hex); nil until ActivityKit
    /// reports one.
    @ObservationIgnored private var pushToStartToken: String?

    var areActivitiesEnabled: Bool { controller.areEnabled }

    /// Last reconcile verdict per Host, human-readable — the Settings
    /// diagnostic row that turns "no banner and no idea why" into a
    /// sentence (observable so the row updates live).
    private(set) var reconcileNotes: [Host.ID: String] = [:]

    init(
        controller: any LiveActivityControlling,
        preferences: LiveActivityPreferences,
        transports: any NotificationTransportProvider,
        keys: NotificationKeyStore = NotificationKeyStore(),
        ceremony: NotificationRegistrationCeremony? = nil,
        deviceToken: @escaping @MainActor () -> APNSDeviceToken?,
        knownHostIDs: @escaping @MainActor () -> Set<Host.ID>,
        hostDisplayName: @escaping @MainActor (Host.ID) -> String,
        isAwaitingSnapshot: @escaping @MainActor (Host.ID) -> Bool,
        connectionStatus: @escaping @MainActor (Host.ID) -> EventsSessionStatus?,
        pinnedPaneIDs: @escaping @MainActor (Host.ID) -> [String] = { _ in [] },
        rowLayout: @escaping @MainActor (Host.ID) -> AgentRowLayout? = { _ in nil },
        settleDuration: Duration = .seconds(3),
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.controller = controller
        self.preferences = preferences
        self.transports = transports
        self.keys = keys
        self.ceremony = ceremony ?? NotificationRegistrationCeremony(keys: keys)
        self.deviceToken = deviceToken
        self.knownHostIDs = knownHostIDs
        self.hostDisplayName = hostDisplayName
        self.isAwaitingSnapshot = isAwaitingSnapshot
        self.connectionStatus = connectionStatus
        self.pinnedPaneIDs = pinnedPaneIDs
        self.rowLayout = rowLayout
        self.settleDuration = settleDuration
        self.now = now
    }

    func isEnabled(for hostID: Host.ID) -> Bool {
        preferences.isEnabled(for: hostID)
    }

    /// Settings toggle: persist the opt-in and apply immediately. Switching
    /// off ends the activity and clears both registration fields.
    func setEnabled(_ enabled: Bool, for hostID: Host.ID) {
        preferences.setEnabled(enabled, for: hostID)
        sendLifecycle(.cancelSettle(hostID))
        guard didStart else { return }
        if !enabled { endNow(hostID) }
        // Another entry for the same computer may give way (its activity
        // ends now, before this one starts) or take over.
        for other in Set(latestAgents.keys).union(sessions.keys) where other != hostID {
            scheduleSettle(for: other)
        }
        if enabled { apply(hostID) }
        syncStartRegistrations()
    }

    /// The Host catalog changed: a name, an enabled Host, or a second entry
    /// for a computer that now shows it instead.
    func hostsDidChange() {
        guard didStart else { return }
        layoutsDidChange()
        syncStartRegistrations()
    }

    /// Adopts (or ends) activities that survived a previous launch or that
    /// a Host's push-to-start created, then starts reflecting the current
    /// Agent list and watching for pushed activities and push-to-start
    /// token rotations. Unknown `hostID`s end immediately; a
    /// still-connecting or reconnecting known Host keeps its activity until
    /// the first post-connect snapshot arrives.
    func start() {
        guard !didStart else { return }
        sendLifecycle(.start)
        for (hostID, id) in newestSystemActivities() {
            adopt(LiveActivityHandle(id: id, hostID: hostID))
        }
        var hosts = Set(latestAgents.keys)
        hosts.formUnion(sessions.keys)
        for hostID in hosts {
            scheduleSettle(for: hostID)
        }
        observeSystemActivities()
    }

    /// The Console feed. First sight is current truth, not a baseline — a
    /// launch with already-working Agents should start an activity once the
    /// settle elapses. Newer input cancels an in-flight settle.
    func agentsDidChange(_ agents: [ConsoleAgent]) {
        let grouped = Dictionary(grouping: agents, by: \.hostID)
        var hosts = Set(latestAgents.keys)
        hosts.formUnion(grouped.keys)
        hosts.formUnion(sessions.keys)
        latestAgents = grouped
        guard didStart else { return }
        for hostID in hosts {
            scheduleSettle(for: hostID)
        }
    }

    /// Foreground return: notice dismissals that happened while we were away,
    /// adopt or orphan whatever ActivityKit still holds (including an
    /// activity a push-to-start created meanwhile), and retry dirty token
    /// writes.
    func reconcile() {
        guard didStart else { return }
        // Ended by iOS while we were away; the state stream may not have
        // said so yet.
        let ended = Set(controller.currentActivities().filter { $0.state == .ended }.map(\.id))
        for (hostID, session) in sessions where ended.contains(session.id) {
            expire(hostID)
        }
        let current = newestSystemActivities()

        // Dismissed or ended while we were away, or superseded by a newer
        // (pushed) activity for the same Host.
        for (hostID, session) in sessions where current[hostID] != session.id {
            dropSession(hostID, endOnController: false)
            clearToken(for: hostID)
        }

        for (hostID, id) in current where sessions[hostID] == nil {
            adopt(LiveActivityHandle(id: id, hostID: hostID))
        }

        syncStartRegistrations()
        retryDirtyPipes(onlyIfConnected: false)
        releaseSnapshotHolds()
        retryFailedStarts(onlyIfConnected: false)
    }

    /// Connection or snapshot-hold change: retry token writes for Hosts that
    /// are reachable again, hold live activities while the Agent list is
    /// unknown, and apply a deferred end/update once the first snapshot lands.
    func connectionsDidChange() {
        guard didStart else { return }
        retryDirtyPipes(onlyIfConnected: true)
        for hostID in sessions.keys {
            holdIfUnknown(hostID)
        }
        releaseSnapshotHolds()
        retryFailedStarts(onlyIfConnected: true)
    }

    /// Pin set change: rebuild LA content through the existing settle, and
    /// push `pinned_pane_ids` to Hosts that are connected and already
    /// showing an activity. Offline Hosts pick up the current set on the
    /// next live_activity write — no queue.
    func pinsDidChange() {
        guard didStart else { return }
        var hosts = Set(latestAgents.keys)
        hosts.formUnion(sessions.keys)
        for hostID in hosts {
            scheduleSettle(for: hostID)
            if sessions[hostID] != nil, connectionStatus(hostID) == .connected {
                enqueue(.setPreferences, for: hostID)
            }
        }
    }

    /// Rebuild visible content and queue the same layout for background pushes.
    /// Offline writes stay dirty and retry on reconnect through the token pipe.
    func layoutsDidChange() {
        guard didStart else { return }
        for hostID in Set(latestAgents.keys).union(sessions.keys) {
            scheduleSettle(for: hostID)
            if sessions[hostID] != nil { enqueue(.setPreferences, for: hostID) }
        }
    }

    // MARK: Desire / settle

    private func scheduleSettle(for hostID: Host.ID) {
        if endIfNotShown(hostID) { return }
        holdIfUnknown(hostID)
        if shouldDeferApply(for: hostID) {
            sendLifecycle(.cancelSettle(hostID))
            return
        }
        let desired = computeDesired(for: hostID)
        if isUnchanged(hostID: hostID, desired: desired) {
            sendLifecycle(.cancelSettle(hostID))
            return
        }
        sendLifecycle(.schedule(hostID))
    }

    private func apply(_ hostID: Host.ID) {
        guard didStart else { return }
        if endIfNotShown(hostID) { return }
        holdIfUnknown(hostID)
        if shouldDeferApply(for: hostID) { return }
        let desired = computeDesired(for: hostID)
        if isUnchanged(hostID: hostID, desired: desired) { return }

        guard let desired else {
            reconcileNotes[hostID] = "idle — \(desireBlocker(for: hostID))"
            endNow(hostID)
            return
        }
        guard let key = notificationKey(for: hostID),
            let content = AgentActivityContentBuilder.content(for: desired, key: key)
        else {
            reconcileNotes[hostID] = "sealing the update failed"
            return
        }

        if let session = sessions[hostID] {
            controller.update(id: session.id, content: content)
            sendLifecycle(.applied(hostID, desired))
            reconcileNotes[hostID] = "active — updated"
            return
        }
        guard controller.areEnabled else {
            reconcileNotes[hostID] = "idle — iOS has Live Activities disabled for Waycar"
            return
        }
        if let existing = newestSystemActivities(onlyFor: hostID)[hostID] {
            // A push-to-start ActivityKit has not announced yet already
            // shows this Host: adopt it instead of requesting a duplicate.
            beginSession(
                LiveActivityHandle(id: existing, hostID: hostID), awaitingFirstSnapshot: false)
            controller.update(id: existing, content: content)
            sendLifecycle(.applied(hostID, desired))
            reconcileNotes[hostID] = "active — adopted"
            return
        }
        do {
            let handle = try controller.request(
                attributes: AgentActivityAttributes(hostID: hostID.uuidString),
                content: content)
            beginSession(handle, awaitingFirstSnapshot: false)
            sendLifecycle(.applied(hostID, desired))
            reconcileNotes[hostID] = "active — started"
        } catch {
            // Retain the failed start for reconnect or foreground reconcile,
            // even when the Agents' desire has not changed meanwhile.
            sendLifecycle(.startFailed(hostID))
            reconcileNotes[hostID] = "start failed — \(requestFailureReason(error))"
        }
    }

    /// A Host no longer shown (disabled, or another entry for the same
    /// computer took over) loses its activity at once, whatever its
    /// connection: a snapshot hold must not keep it beside the new one.
    private func endIfNotShown(_ hostID: Host.ID) -> Bool {
        guard sessions[hostID] != nil, !knownHostIDs().contains(hostID) else { return false }
        sendLifecycle(.cancelSettle(hostID))
        endNow(hostID)
        reconcileNotes[hostID] = "idle — \(desireBlocker(for: hostID))"
        return true
    }

    private func retryFailedStarts(onlyIfConnected: Bool) {
        for hostID in failedStarts {
            guard knownHostIDs().contains(hostID), computeDesired(for: hostID) != nil else {
                sendLifecycle(.forgetFailure(hostID))
                continue
            }
            if onlyIfConnected, connectionStatus(hostID) != .connected { continue }
            scheduleSettle(for: hostID)
        }
    }

    /// The gate that kept `computeDesired` from producing content, in the
    /// order the gates run — surfaced by the Settings diagnostic row.
    private func desireBlocker(for hostID: Host.ID) -> String {
        if !controller.areEnabled { return "iOS has Live Activities disabled for Waycar" }
        if !preferences.isEnabled(for: hostID) { return "the per-Host toggle is off" }
        if !knownHostIDs().contains(hostID) {
            return "the Host is disabled, or another Host shows the same computer"
        }
        if deviceToken() == nil { return "no push device token yet" }
        if notificationKey(for: hostID) == nil { return "no Notification Key for this Host" }
        return "no working, blocked, or done agents"
    }

    private func requestFailureReason(_ error: any Error) -> String {
        if case LiveActivityRequestError.requestFailed(let reason) = error, !reason.isEmpty {
            return reason
        }
        return String(describing: error)
    }

    private func computeDesired(for hostID: Host.ID) -> AgentActivityDesire? {
        guard controller.areEnabled else { return nil }
        guard preferences.isEnabled(for: hostID) else { return nil }
        guard knownHostIDs().contains(hostID) else { return nil }
        guard deviceToken() != nil else { return nil }
        guard notificationKey(for: hostID) != nil else { return nil }
        let agents = latestAgents[hostID] ?? []
        return AgentActivityContentBuilder.desire(
            from: agents,
            hostName: resolvedHostName(hostID, agents: agents),
            pinnedPaneIDs: pinnedPaneIDs(hostID), layout: rowLayout(hostID))
    }

    private func isUnchanged(hostID: Host.ID, desired: AgentActivityDesire?) -> Bool {
        switch desired {
        case .some(let next):
            return applied[hostID] == next
        case .none:
            return applied[hostID] == nil && sessions[hostID] == nil
        }
    }

    /// True while this Host's Agent list is unverified: an empty slice is
    /// loading, not all-idle. Covers cold-launch adoption and a reconnect,
    /// whose last-known rows the Console withholds from this feed until the
    /// next live snapshot verifies them.
    private func shouldDeferApply(for hostID: Host.ID) -> Bool {
        if isUnknownAgentInventory(hostID) { return true }
        if sessions[hostID]?.awaitingFirstSnapshot == true { return true }
        return false
    }

    private func isUnknownAgentInventory(_ hostID: Host.ID) -> Bool {
        if isAwaitingSnapshot(hostID) { return true }
        if sessions[hostID] != nil, let status = connectionStatus(hostID),
            status != .connected
        {
            return true
        }
        return false
    }

    /// Marks a live activity so `releaseSnapshotHolds` applies once the
    /// post-reconnect snapshot arrives — including an empty one.
    private func holdIfUnknown(_ hostID: Host.ID) {
        guard sessions[hostID] != nil, isUnknownAgentInventory(hostID) else { return }
        sendLifecycle(.hold(hostID))
    }

    private func releaseSnapshotHolds() {
        for (hostID, session) in sessions where session.awaitingFirstSnapshot {
            guard !isUnknownAgentInventory(hostID) else { continue }
            sendLifecycle(.releaseHold(hostID))
            scheduleSettle(for: hostID)
        }
    }

    private func resolvedHostName(_ hostID: Host.ID, agents: [ConsoleAgent]) -> String {
        let catalog = hostDisplayName(hostID)
        if !catalog.isEmpty { return catalog }
        return agents.first?.hostName ?? ""
    }

    private func notificationKey(for hostID: Host.ID) -> Data? {
        guard let record = try? keys.record(forHost: hostID), record.key.count == 32 else {
            return nil
        }
        return record.key
    }

    // MARK: Sessions

    private struct ActivityWatchers {
        var tokenTask: Task<Void, Never>
        var stateTask: Task<Void, Never>
    }

    /// ActivityKit's activities reduced to the newest live one per known
    /// Host (optionally just `onlyFor`). ActivityKit lists oldest first, so a
    /// push-to-start that raced a local start, or a pushed activity left
    /// over from an earlier episode, loses to the later entry and ends.
    /// Everything else still on the Lock Screen ends too: an unknown Host's,
    /// one iOS ended, and one retired earlier that ActivityKit still lists.
    private func newestSystemActivities(onlyFor only: Host.ID? = nil) -> [Host.ID: String] {
        let current = controller.currentActivities().map {
            LiveActivityLifecycleMachine.SystemActivity(id: $0.id, hostID: $0.hostID, state: $0.state)
        }
        sendLifecycle(.inventory(current, known: knownHostIDs(), only: only))
        return lifecycle.state.newest
    }

    /// Takes over an activity the app did not just request — one from a
    /// previous launch or a Host's push-to-start. Its content came from
    /// elsewhere, so the next settle refreshes it; its push token flows into
    /// the registration file like a locally started one.
    private func adopt(_ handle: LiveActivityHandle) {
        beginSession(handle, awaitingFirstSnapshot: isAwaitingSnapshot(handle.hostID))
        sendLifecycle(.applied(handle.hostID, nil))
        scheduleSettle(for: handle.hostID)
    }

    private func observeSystemActivities() {
        let announced = controller.activityUpdates()
        let startTokens = controller.pushToStartTokenUpdates()
        Task { [weak self] in
            for await handle in announced {
                self?.activityDidAppear(handle)
            }
        }
        Task { [weak self] in
            for await token in startTokens {
                self?.pushToStartTokenDidChange(token)
            }
        }
    }

    /// ActivityKit announced an activity, typically one a push-to-start
    /// created. The newest per Host wins, so it replaces a running session
    /// instead of duplicating it; the replaced activity's token is cleared
    /// until the new one's token arrives.
    private func activityDidAppear(_ handle: LiveActivityHandle) {
        guard !retiredActivityIDs.contains(handle.id),
            sessions[handle.hostID]?.id != handle.id
        else { return }
        guard knownHostIDs().contains(handle.hostID) else {
            retire(handle.id)
            return
        }
        if sessions[handle.hostID] != nil {
            dropSession(handle.hostID, endOnController: true)
            clearToken(for: handle.hostID)
        }
        adopt(handle)
        reconcileNotes[handle.hostID] = "active — started by the Host"
    }

    private func retire(_ id: String) {
        sendLifecycle(.retire(id))
    }

    private func beginSession(
        _ handle: LiveActivityHandle, awaitingFirstSnapshot: Bool
    ) {
        sendLifecycle(.begin(handle, awaitingSnapshot: awaitingFirstSnapshot))
    }

    private func watch(_ handle: LiveActivityHandle) {
        let tokenTask = Task { [weak self] in
            guard let self else { return }
            for await token in self.controller.pushTokenUpdates(for: handle) {
                self.considerToken(token, hostID: handle.hostID)
            }
        }
        let stateTask = Task { [weak self] in
            guard let self else { return }
            for await state in self.controller.stateUpdates(for: handle) {
                self.considerState(state, of: handle)
            }
        }
        watchers[handle.id] = ActivityWatchers(tokenTask: tokenTask, stateTask: stateTask)
    }

    private func considerToken(_ token: Data, hostID: Host.ID) {
        let hex = Self.hexEncoded(token)
        guard !hex.isEmpty else { return }
        sendPipe(.activityToken(hex, startedAt: now()), for: hostID)
    }

    /// Withdraws the `live_activity` token this Host wrote. Nothing to
    /// withdraw when it never wrote one; a token left by an earlier run ends
    /// with the plugin's next push (APNs 410).
    private func clearToken(for hostID: Host.ID) {
        sendPipe(.clearToken, for: hostID)
    }

    private func considerState(_ state: LiveActivityRunState, of handle: LiveActivityHandle) {
        sendLifecycle(.activityState(handle, state))
    }

    /// iOS ended the activity (its 8-hour limit) and keeps it on the Lock
    /// Screen, frozen, for up to 4 more hours. Dismiss it, and unlike a
    /// user's dismissal let the next settle start a fresh one while Agents
    /// still want it.
    private func expire(_ hostID: Host.ID) {
        sendLifecycle(.expire(hostID))
    }

    private func endNow(_ hostID: Host.ID) {
        sendLifecycle(.end(hostID))
    }

    private func dropSession(_ hostID: Host.ID, endOnController: Bool) {
        sendLifecycle(.drop(hostID, end: endOnController))
    }

    private func sendLifecycle(_ event: LiveActivityLifecycleMachine.Event) {
        for effect in lifecycle.handle(event) {
            switch effect {
            case .armSettle(let hostID, let token):
                let duration = settleDuration
                settleTasks[token] = Task { [weak self] in
                    try? await Task.sleep(for: duration)
                    guard !Task.isCancelled else { return }
                    self?.settleTasks[token] = nil
                    self?.sendLifecycle(.settleElapsed(hostID, token))
                }
            case .cancelSettle(let token):
                settleTasks.removeValue(forKey: token)?.cancel()
            case .apply(let hostID):
                apply(hostID)
            case .watch(let handle):
                watch(handle)
            case .cancelWatch(let id):
                let tasks = watchers.removeValue(forKey: id)
                tasks?.tokenTask.cancel()
                tasks?.stateTask.cancel()
            case .endActivity(let id):
                controller.end(id: id, finalContent: nil, immediate: true)
            case .clearToken(let hostID):
                clearToken(for: hostID)
            case .schedule(let hostID):
                scheduleSettle(for: hostID)
            }
        }
    }

    // MARK: Push-to-start registration

    private func pushToStartTokenDidChange(_ token: Data) {
        let hex = Self.hexEncoded(token)
        guard !hex.isEmpty, hex != pushToStartToken else { return }
        pushToStartToken = hex
        syncStartRegistrations()
    }

    /// Every shown Host, and every Host that asked before: one that stopped
    /// being shown withdraws its offer, so a later turn as the shown entry
    /// writes it again.
    private func syncStartRegistrations() {
        let requested = pipes.compactMap { $0.value.state.requestedStart == nil ? nil : $0.key }
        for hostID in knownHostIDs().union(requested) {
            syncStartRegistration(for: hostID)
        }
    }

    /// Offers this install's push-to-start token to a Host whose Live
    /// Activity is wanted, and withdraws it otherwise, so the plugin never
    /// starts an activity the app would immediately end. The withdrawal
    /// removes only this Host's own offer: a second entry for the same
    /// computer must not take back the one that shows it.
    private func syncStartRegistration(for hostID: Host.ID) {
        guard let token = pushToStartToken else { return }
        let job: StartJob =
            controller.areEnabled && preferences.isEnabled(for: hostID)
                && knownHostIDs().contains(hostID)
            ? .set(hex: token) : .clear
        sendPipe(.requestStart(job), for: hostID)
    }

    // MARK: Token pipe

    private typealias TokenJob = LiveActivityRegistrationMachine.ActivityJob
    private typealias StartJob = LiveActivityRegistrationMachine.StartJob
    private typealias PipeJob = LiveActivityRegistrationMachine.Job

    private func enqueue(_ job: TokenJob, for hostID: Host.ID) {
        sendPipe(.enqueue(job), for: hostID)
    }

    private func sendPipe(_ event: LiveActivityRegistrationMachine.Event, for hostID: Host.ID) {
        var pipe = pipes[hostID] ?? LiveActivityRegistrationMachine()
        let effects = pipe.handle(event)
        pipes[hostID] = pipe
        for effect in effects {
            switch effect {
            case .write(let token, let job):
                pipeTasks[hostID, default: [:]][token] = Task { [weak self] in
                    guard let self else { return }
                    let succeeded = await self.perform(job, hostID: hostID)
                    self.pipeTasks[hostID]?[token] = nil
                    self.sendPipe(.finished(token, succeeded: succeeded), for: hostID)
                }
            }
        }
    }

    private func perform(_ job: PipeJob, hostID: Host.ID) async -> Bool {
        guard let token = deviceToken() else { return false }
        let pins = pinnedPaneIDs(hostID)
        let layout = rowLayout(hostID)
        let hostName = resolvedHostName(hostID, agents: latestAgents[hostID] ?? [])
        do {
            try await transports.withNotificationTransport(for: hostID) { [ceremony] transport in
                switch job {
                case .activity(.set(let hex, let startedAt)):
                    try await ceremony.setLiveActivityToken(
                        tokenHex: hex, startedAt: startedAt, deviceToken: token,
                        pinnedPaneIDs: pins, rowLayout: layout, hostName: hostName,
                        over: transport)
                case .activity(.setPreferences):
                    try await ceremony.setLiveActivityPinnedPaneIDs(
                        pins, rowLayout: layout, hostName: hostName, deviceToken: token, over: transport)
                case .activity(.clear(let hex)):
                    try await ceremony.clearLiveActivityToken(
                        deviceToken: token, onlyIfToken: hex, over: transport)
                case .start(.set(let hex)):
                    try await ceremony.setLiveActivityStartToken(
                        tokenHex: hex, hostID: hostID, deviceToken: token, over: transport)
                case .start(.clear):
                    try await ceremony.clearLiveActivityStartToken(
                        deviceToken: token, onlyIfHostID: hostID, over: transport)
                }
            }
            return true
        } catch {
            return false
        }
    }

    private func retryDirtyPipes(onlyIfConnected: Bool) {
        for (hostID, pipe) in pipes where pipe.isDirty {
            if onlyIfConnected, connectionStatus(hostID) != .connected { continue }
            sendPipe(.retry, for: hostID)
        }
    }

    private static func hexEncoded(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// The Hosts that get a Live Activity: the enabled ones, minus a second
    /// entry for a computer another entry already shows (the same Mac added
    /// by Tailscale name and by LAN address, say). Within one computer the
    /// first entry with Live Activities on wins, then catalog order.
    static func activityHostIDs(
        enabledHosts: [Host],
        isPreferred: (Host.ID) -> Bool,
        digests: (Host) -> Set<Data>
    ) -> Set<Host.ID> {
        Set(computers(among: enabledHosts, digests: digests).compactMap { entries in
            (entries.first { isPreferred($0.id) } ?? entries.first)?.id
        })
    }

    /// Every entry in `hosts` for the same computer as `hostID`, itself
    /// included: what a registration-file ceremony through `hostID` holds.
    static func computerHostIDs(
        of hostID: Host.ID, among hosts: [Host], digests: (Host) -> Set<Data>
    ) -> Set<Host.ID> {
        let entries = computers(among: hosts, digests: digests).first { $0.contains { $0.id == hostID } }
        return Set(entries?.map(\.id) ?? []).union([hostID])
    }

    /// `hosts` grouped by computer, each group in catalog order. Entries that
    /// trust a common host-key digest are one computer, transitively (one
    /// entry may trust two key types another two entries split). An entry
    /// that never connected has no digest and stands alone.
    private static func computers(
        among hosts: [Host], digests: (Host) -> Set<Data>
    ) -> [[Host]] {
        var groups: [(members: [Int], digests: Set<Data>)] = []
        for (index, host) in hosts.enumerated() {
            var group = (members: [index], digests: digests(host))
            for other in groups.indices.reversed()
            where !groups[other].digests.isDisjoint(with: group.digests) {
                group.members += groups[other].members
                group.digests.formUnion(groups[other].digests)
                groups.remove(at: other)
            }
            groups.append(group)
        }
        return groups.map { $0.members.sorted().map { hosts[$0] } }
    }
}

extension Host {
    /// The host-key digests this device trusts for this entry's endpoint.
    var trustedHostKeyDigests: Set<Data> {
        UserDefaultsKnownHostsStore.trustedDigests(host: address, port: port)
    }
}
