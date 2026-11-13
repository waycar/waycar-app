import Foundation
import Observation
import OSLog

/// The Console's Closed Sessions (CONTEXT.md **Closed Session**): Agents
/// that left their Pane, newest first, for 30 days after they closed.
///
/// Kept on this device as one file under Application Support, excluded from
/// backups and protected until the first unlock: records carry the working
/// directories, titles and labels `ConsoleInventoryCache` keeps out of
/// backups too. Synced like the Host catalog (ADR 0019,
/// `SyncedClosedSessionCatalog`): `reconcileWithSync` merges one iCloud
/// Keychain item per record, and forgetting a record leaves a tombstone. The
/// tombstones this device wrote are kept here too, so a record forgotten
/// while iCloud Sync was off is still forgotten everywhere once it is back on.
///
/// A tombstone forgets every copy of its record last seen running no later
/// than it. A device that was away captures, on its return, Agents that
/// closed long before; its last look at them predates a Forget made
/// elsewhere meanwhile, so they stay forgotten. The same session seen
/// running after a resume and closing again is a new closure.
///
/// Only the user's Forget and a used resume of a record without a session
/// write one. A record whose Agent is live again — resumed here or on
/// another device, or restored by herdr — is only left out of
/// `listedSessions` while it runs, each device judging from the rows it
/// lists, so no device can forget it for another.
@MainActor
@Observable
final class ClosedSessionsStore {
    /// How long a record lives after it closed.
    static let retention: TimeInterval = 30 * 24 * 60 * 60
    /// How far past this device's clock a synced time may lie. Another
    /// device's clock running ahead must not pin a record or tombstone
    /// beyond its expiry, nor let a tombstone forget later closures.
    static let clockTolerance: TimeInterval = 5 * 60
    private static let blobVersion = 1
    private static let fileName = "closed-sessions.json"
    private static let log = Logger(subsystem: "com.otreva.waycar", category: "ClosedSessionsStore")

    private struct PersistedBlob: Codable {
        let version: Int
        let sessions: [LossySession]
        /// When each forgotten record was forgotten, in milliseconds.
        let tombstones: [ClosedSession.ID: Int64]
        /// Records resumed and still pending when the blob was written, with
        /// when each resume began, in milliseconds. A relaunch resolves them
        /// as used: it never closes their Panes.
        let pendingResumes: [ClosedSession.ID: Int64]?
    }

    /// One persisted record, or nil when it no longer decodes (a kind this
    /// build dropped), so one bad record never costs the rest.
    private struct LossySession: Codable {
        let session: ClosedSession?

        init(_ session: ClosedSession) {
            self.session = session
        }

        init(from decoder: any Decoder) throws {
            session = try? ClosedSession(from: decoder)
        }

        func encode(to encoder: any Encoder) throws {
            try session?.encode(to: encoder)
        }
    }

    /// A resumed record whose Agent is live but not yet used from this app.
    struct PendingResume: Equatable, Sendable {
        let record: ClosedSession.ID
        /// When the resume began, in milliseconds.
        let beganAt: Int64
    }

    /// Newest first: every record kept here, hidden ones included. The
    /// Closed list reads `listedSessions`.
    private(set) var sessions: [ClosedSession] = []
    /// Every resume this device started, per resumed Agent row
    /// (`ClosedResumeMachine`). Device-local, never synced. The three
    /// dictionaries below are its projections, updated row by row as it
    /// reports a row's listing changed, so reading and changing them costs
    /// what it did.
    @ObservationIgnored private var resumes = ClosedResumeMachine()
    /// Pending resumes, keyed by the resumed Agent's row: backing out of the
    /// Agent unused closes its Pane and lists the record again; input makes
    /// the resume used.
    private(set) var pendingResumes: [ConsoleAgent.ID: PendingResume] = [:]
    /// Resumed Agents the user backed out of unused, to the record each
    /// resumed: their Panes closing, or closed with the closure not captured
    /// yet. The Console stops listing their rows and lists their records
    /// again at once; a close that fails brings the row back.
    private(set) var backedOutResumes: [ConsoleAgent.ID: ClosedSession.ID] = [:]
    /// Used resumes of records with a session, to that record: hidden while
    /// the Agent's row is listed, whatever session it reports meanwhile.
    private var usedResumes: [ConsoleAgent.ID: ClosedSession.ID] = [:]
    /// The session each Agent row the Console lists reports, as a
    /// `sessionKey` (`noteLiveAgents`).
    private var liveSessions: [ConsoleAgent.ID: String] = [:]
    /// The Closed list: every record but those whose Agent is live — a
    /// pending or used resume of it, or its session running on its Host. A
    /// record comes back as soon as that ends; nothing is forgotten for it.
    var listedSessions: [ClosedSession] {
        let hidden = Set(pendingResumes.values.lazy.map(\.record)).union(usedResumes.values)
        let live = liveSessionKeys
        let all = keptServerSessions.isEmpty ? sessions : Self.ordered(sessions + keptServerSessions)
        guard !hidden.isEmpty || !live.isEmpty else { return all }
        return all.filter { !hidden.contains($0.id) && !Self.runs($0, in: live) }
    }
    /// The records servers keep themselves (`ClosedSession(archived:)`:
    /// OpenCode's archived sessions), as the Console's projections last
    /// read them. Never persisted or synced: the server is their record.
    /// A Forget still forgets one, by its tombstone, until it is archived
    /// again.
    private(set) var serverSessions: [ClosedSession] = []

    /// Replaces the server-kept records (`ConsoleStore.rebuild`); publishes
    /// only a change.
    func setServerSessions(_ records: [ClosedSession]) {
        guard records != serverSessions else { return }
        serverSessions = records
    }

    /// Server-kept records not forgotten, not expired, and not already kept
    /// here under the same id.
    private var keptServerSessions: [ClosedSession] {
        guard !serverSessions.isEmpty else { return [] }
        let cutoff = cutoffMilliseconds()
        let local = Set(sessions.map(\.id))
        return serverSessions.filter {
            !local.contains($0.id) && !isForgotten($0)
                && ClosedSession.milliseconds($0.closedAt) >= cutoff
        }
    }
    /// The clock records and tombstones are stamped with. The Console stamps
    /// the snapshots it captures closures from with it too, so a capture's
    /// last-seen time and its record's closure time never disagree.
    @ObservationIgnored let now: @MainActor () -> Date
    /// Runs after a change made on this device — a capture or a Forget — so
    /// iCloud Sync can publish it soon. Never after a sync pass.
    @ObservationIgnored var onLocalChange: @MainActor () -> Void = {}
    /// Whether the Agent row a closure captured ran in Chat Mode, asked with
    /// that row so a marker another Agent left in the same pane does not
    /// count; nil records every closure as a terminal Agent. Set by
    /// `ConsoleStore` from its Chat Markers.
    @ObservationIgnored var chatModeLookup: (@MainActor (ConsoleAgent) -> Bool)?
    @ObservationIgnored private var tombstones: [ClosedSession.ID: Int64]
    @ObservationIgnored private let directory: URL?
    @ObservationIgnored private var preparedDirectory = false
    @ObservationIgnored private let sync: SyncedClosedSessionCatalog?

    /// - Parameter directory: where the records persist between launches;
    ///   nil keeps them in memory only.
    init(
        directory: URL? = nil,
        sync: SyncedClosedSessionCatalog? = nil,
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.directory = directory
        self.sync = sync
        self.now = now
        // A missing file and a locked device read the same: start empty.
        let blob = directory
            .flatMap { try? Data(contentsOf: $0.appending(path: Self.fileName)) }
            .flatMap { try? JSONDecoder().decode(PersistedBlob.self, from: $0) }
        // An unknown version starts empty: iCloud Keychain still holds the
        // records, and the next pass brings them back.
        guard let blob, blob.version == Self.blobVersion else {
            tombstones = [:]
            return
        }
        tombstones = blob.tombstones
        sessions = Self.ordered(blob.sessions.compactMap(\.session))
        pruneExpired()
        // A resume still pending at the last write was left by a relaunch;
        // its Agent may be in use elsewhere, so it counts as used. A record
        // with a session simply stays, unlisted while that session runs. One
        // without is forgotten, stamped when the resume began rather than
        // now: a closure of that Agent captured from a snapshot cached before
        // the relaunch must still be recorded.
        if let pending = blob.pendingResumes, !pending.isEmpty {
            let stamps = pending.filter { id, _ in
                sessions.contains { $0.id == id && $0.session == nil }
            }
            if stamps.isEmpty {
                persist()
            } else {
                forget(stamps)
            }
        }
    }

    /// The production location, or nil when Application Support cannot be
    /// resolved — the records then live in memory only.
    static func applicationSupportDirectory() -> URL? {
        guard
            let base = try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
        else { return nil }
        return base.appending(path: "ClosedSessions", directoryHint: .isDirectory)
    }

    /// Records the Agents a live snapshot no longer runs as closed now.
    ///
    /// A capture whose Agent was last seen running longer ago than a record
    /// lives, or at an unknown time, is skipped: the device was away, and
    /// the tombstones that would have forgotten such a closure may have
    /// expired everywhere. So is one a tombstone forgets. A capture replaces
    /// the record already here only when it saw the Agent running later: the
    /// same session closed again. Either way the record stays in Chat Mode
    /// once either copy is (`chatModeLookup`).
    func record(_ captures: [ClosedAgentCapture]) {
        let closedAt = now()
        let cutoff = cutoffMilliseconds()
        var byID = Dictionary(sessions.map { ($0.id, $0) }) { first, _ in first }
        var changed = false
        for capture in captures {
            let lastSeen = capture.lastSeenRunningAt
            // The Pane of a resume never used — backed out of, or closed
            // some other way — keeps the record it resumed, listed again as
            // it was, whatever id this capture would get. A used one closed
            // like any Agent: its capture is a later closure of the session.
            var resumed: ClosedSession.ID?
            var forgotten = false
            for effect in send(.captured(capture.row.id)) {
                switch effect {
                case .captureIsResume(let record, let wasPending):
                    resumed = record
                    if wasPending { changed = true }
                case .dropCapture:
                    forgotten = true
                case .project, .persist, .verify, .close, .forget:
                    break // Projected by `send`; `captured` asks for no other.
                }
            }
            if forgotten {
                continue
            }
            if let resumed, let original = byID[resumed] {
                let seen = lastSeen.map {
                    original.seenRunning(until: ClosedSession.milliseconds($0))
                }
                if let seen, seen != original {
                    byID[resumed] = seen
                    changed = true
                }
                continue
            }
            guard let lastSeen, ClosedSession.milliseconds(lastSeen) >= cutoff else { continue }
            guard
                let session = ClosedSession(
                    closing: capture.row, session: capture.session,
                    lastSeenRunningAt: lastSeen, closedAt: closedAt,
                    chatMode: chatModeLookup?(capture.row) ?? false),
                !isForgotten(session)
            else { continue }
            let next: ClosedSession
            if let existing = byID[session.id] {
                next =
                    Self.isLater(session, than: existing)
                    ? session.mergingChatMode(of: existing)
                    : existing.mergingChatMode(of: session)
                guard next != existing else { continue }
            } else {
                next = session
            }
            byID[session.id] = next
            changed = true
        }
        guard changed else { return }
        sessions = Self.ordered(byID.values)
        persist()
        onLocalChange()
    }

    /// The user's Forget: forgets a record everywhere.
    func forget(_ id: ClosedSession.ID) {
        forget([id])
    }

    /// A resume of `id` started `agentID`, running `terminalID`: the record
    /// is live, so it leaves the Closed list, but is kept until the user uses
    /// that Agent.
    func beginPendingResume(
        _ id: ClosedSession.ID, agent agentID: ConsoleAgent.ID, terminal terminalID: String
    ) {
        guard let record = sessions.first(where: { $0.id == id }) else { return }
        perform(send(.began(
            agentID, record: id, beganAt: ClosedSession.milliseconds(now()), terminal: terminalID,
            backend: record.backend)))
    }

    /// The user sent input to `agentID` from this app: a pending resume of
    /// it was used. Input after backing out of it is lost with the Pane, so
    /// it counts for nothing.
    func noteUserInput(to agentID: ConsoleAgent.ID) {
        guard let pending = pendingResumes[agentID] else { return }
        perform(send(.inputSent(agentID, recordState(pending.record))))
    }

    /// Resolves every pending resume of `id` as used: its Agent stays live.
    func resolvePendingResumeAsUsed(_ id: ClosedSession.ID) {
        for (agentID, pending) in pendingResumes where pending.record == id {
            perform(send(.usedElsewhere(agentID, record: id, recordState(id))))
        }
    }

    /// The user backed out of `agentID`. A pending resume of it was never
    /// used: its row leaves the Console and its record is listed again as it
    /// was, at once, while its Pane closes.
    ///
    /// `verifiedRow` reads the row the Host's verified snapshot has at that
    /// pane; `closePane` closes it. The Pane closes only while that row still
    /// runs the resumed terminal, is an Agent, and is idle, done or unknown.
    /// Working or blocked, it was used from another client: the resume
    /// counts as used. Another terminal at the pane (herdr reused the id) or
    /// a Shell there means the resumed Agent is gone already and its closure
    /// will never be captured: the resume is dropped, the record listed.
    ///
    /// A Pane already gone counts as closed. Any other failure leaves the
    /// Agent live: its row comes back, and the resume counts as used. The
    /// Pane closes even when its record is gone meanwhile (another device
    /// forgot it): the Agent was never used, and its closure is captured as
    /// a fresh record — unless the user forgot it here.
    ///
    /// The Console's own `agent_not_found` means only that the row is not
    /// in verified inventory yet: the resume stays pending, so the row is
    /// listed again and a later back-out can close it.
    func backedOut(
        of agentID: ConsoleAgent.ID,
        verifiedRow: (ConsoleAgent.ID) async throws -> ConsoleAgent,
        closePane: (ConsoleAgent) async throws -> Void
    ) async {
        guard let pending = pendingResumes[agentID] else { return }
        let started = send(.backOutRequested(agentID))
        perform(started)
        guard case .verify(let token)? = started.last else { return }
        do {
            let row = try await verifiedRow(agentID)
            // The token answers nothing once a capture of its closure, a
            // verified snapshot or a new resume ended this one (B-22).
            let verified: ClosedResumeMachine.Verified =
                Self.closableStatuses.contains(row.agent.status)
                ? .unused : .busy(recordState(pending.record))
            let effects = send(.verified(
                agentID, token: token, terminalID: row.agent.terminalID, isShell: row.isShell,
                verified))
            perform(effects)
            guard effects == [.close(token)] else { return }
            try await closePane(row)
        } catch where Self.errorCode(error) == "pane_not_found" {
            // Already gone: closed from the detail, a swipe, another device,
            // or the Agent exited. Listed again like a close from here.
        } catch where Self.errorCode(error) == "agent_not_found" {
            perform(send(.backOutFailed(
                agentID, token: token, .notVerified(recordState(pending.record)))))
        } catch {
            perform(send(.backOutFailed(agentID, token: token, .other(recordState(pending.record)))))
        }
    }

    /// The statuses of an Agent nobody is using: only these close on a
    /// back-out.
    private static let closableStatuses: Set<AgentStatus> = [.idle, .done, .unknown]

    /// Notes the rows one backend's verified snapshot of `hostID` has, by
    /// pane id: a resume on that backend whose pane runs another terminal
    /// now, or is gone after it was listed, is over, and its entries go. Its
    /// record stays, listed again. The other backend's snapshots never touch
    /// it.
    func noteVerifiedAgents(
        on hostID: Host.ID, backend: HostBackend = .herdr, rows: [String: ConsoleAgent]
    ) {
        guard !resumes.state.resumes.isEmpty else { return }
        perform(send(.verifiedSnapshot(hostID, backend, rows: rows)))
    }

    /// Feeds the resume machine and updates the rows whose listing it
    /// changed, before the caller performs what it asked for.
    private func send(_ event: ClosedResumeMachine.Event) -> [ClosedResumeMachine.Effect] {
        let effects = resumes.handle(event)
        for case .project(let agentID, let listing) in effects {
            project(agentID, listing)
        }
        return effects
    }

    /// One row's entries in the three published dictionaries; each changes
    /// only when its value does.
    private func project(_ agentID: ConsoleAgent.ID, _ listing: ClosedResumeMachine.Listing?) {
        var pending: PendingResume?
        var backedOut: ClosedSession.ID?
        var used: ClosedSession.ID?
        switch listing {
        case .pending(let record, let beganAt)?:
            pending = PendingResume(record: record, beganAt: beganAt)
        case .backedOut(let record)?:
            backedOut = record
        case .used(let record)?:
            used = record
        case nil:
            break
        }
        if pendingResumes[agentID] != pending { pendingResumes[agentID] = pending }
        if backedOutResumes[agentID] != backedOut { backedOutResumes[agentID] = backedOut }
        if usedResumes[agentID] != used { usedResumes[agentID] = used }
    }

    /// The machine's synchronous effects; `verify` and `close` belong to
    /// the back-out awaiting them.
    private func perform(_ effects: [ClosedResumeMachine.Effect]) {
        for effect in effects {
            switch effect {
            case .persist:
                persist()
            case .forget(let id):
                forget([id])
            case .project, .verify, .close, .captureIsResume, .dropCapture:
                break
            }
        }
    }

    /// What a resume's record is now.
    private func recordState(_ id: ClosedSession.ID) -> ClosedResumeMachine.Record {
        guard let record = sessions.first(where: { $0.id == id }) else { return .gone }
        return record.session == nil ? .sessionless : .withSession
    }

    /// Notes the Agent rows every Host lists now, last-known ones included:
    /// a record whose session one of them runs — resumed on some device, or
    /// brought back by herdr's own restore — is not listed until it closes,
    /// nor one whose used resume's row is still here (a `pane.move` re-keys
    /// it). Hiding forgets nothing, so a stale row costs nothing lasting.
    /// Runs on every Console rebuild; publishes only a change.
    func noteLiveAgents(_ agents: some Sequence<ConsoleAgent>) {
        var next: [ConsoleAgent.ID: String] = [:]
        var listed: Set<ConsoleAgent.ID> = []
        for row in agents where !row.isShell {
            if !usedResumes.isEmpty { listed.insert(row.id) }
            guard let session = row.agent.agentSession, !session.value.isEmpty else { continue }
            next[row.id] = Self.sessionKey(
                hostID: row.hostID, kind: row.agent.kind, value: session.value)
        }
        if usedResumes.contains(where: { !listed.contains($0.key) }) {
            perform(send(.listed(listed)))
        }
        guard next != liveSessions else { return }
        liveSessions = next
    }

    /// The session keys the listed Agent rows run, but for those backed out
    /// of: their records are listed again while their Panes close.
    private var liveSessionKeys: Set<String> {
        guard !backedOutResumes.isEmpty else { return Set(liveSessions.values) }
        return Set(liveSessions.lazy.filter { self.backedOutResumes[$0.key] == nil }.map(\.value))
    }

    private static func runs(_ session: ClosedSession, in live: Set<String>) -> Bool {
        guard !live.isEmpty, let reference = session.session else { return false }
        return live.contains(
            sessionKey(hostID: session.hostID, kind: session.kind.rawValue, value: reference.value))
    }

    /// The rejection code of a herdr or Console refusal, if any.
    private static func errorCode(_ error: any Error) -> String? {
        switch error {
        case TransportError.apiRejected(let code, _): code
        case let error as HerdrAPIError: error.code
        default: nil
        }
    }

    /// Drops the records of Hosts no longer in the catalog. Their iCloud
    /// Keychain items stay until they expire: a Host this device does not
    /// know yet may still arrive.
    func retainHosts(_ hostIDs: Set<Host.ID>) {
        let kept = sessions.filter { hostIDs.contains($0.hostID) }
        guard kept.count != sessions.count else { return }
        sessions = kept
        persist()
    }

    /// Drops records older than `retention`, and tombstones every record
    /// they could override has outlived. Runs on every Console rebuild, so
    /// it returns before copying anything when nothing expired.
    func pruneExpired() {
        let cutoff = cutoffMilliseconds()
        // Newest first: the last record is the oldest.
        let sessionsExpired = sessions.last.map { $0.closedAtMilliseconds < cutoff } ?? false
        guard sessionsExpired || tombstones.values.contains(where: { $0 < cutoff }) else {
            return
        }
        let kept = sessions.filter { $0.closedAtMilliseconds >= cutoff }
        let keptTombstones = tombstones.filter { $0.value >= cutoff }
        sessions = kept
        tombstones = keptTombstones
        persist()
    }

    /// One iCloud Sync pass over the Closed Session items among `items` (a
    /// `readAll` of the shared store). Returns whether this device's records
    /// changed.
    ///
    /// - Records and tombstones this device has and iCloud Keychain lacks
    ///   are published; absence never means deletion.
    /// - A record another device wrote arrives when its Host is in
    ///   `knownHosts`; one for a Host that has not synced here yet waits.
    /// - A time another device wrote more than `clockTolerance` past this
    ///   device's clock counts as that much past it, and only the first time
    ///   this device sees it: the device whose clock runs ahead republishes
    ///   its own value over any other copy, and clamping again would move
    ///   this device's copy forward with its clock and trade writes with that
    ///   device every pass. The clamped value is written back only then, so
    ///   the item still expires on time once that device stops publishing it.
    /// - Where both hold a record, the copy last seen running later wins,
    ///   in Chat Mode when either copy is.
    /// - Tombstones remove the records they override, here and in iCloud
    ///   Keychain; expired records and tombstones go from both. An item is
    ///   removed only when this device keeps nothing under its account, so
    ///   a pass never deletes what it just wrote.
    /// - A record item this build cannot read is never overwritten.
    @discardableResult
    func reconcileWithSync(_ items: [String: Data], knownHosts: Set<Host.ID>) throws -> Bool {
        guard let shared = sync?.store() else { return false }
        let cutoff = cutoffMilliseconds()
        let latest = ClosedSession.milliseconds(now().addingTimeInterval(Self.clockTolerance))
        let remote = SyncedClosedSessionCatalog.contents(of: items)
        let remoteRecords = remote.records.mapValues { $0.clamped(notAfter: latest) }

        // Ids whose iCloud time lies past `latest` and that this pass clamps
        // for the first time. A clamp this device already holds stays put.
        var firstClampedTombstones: Set<ClosedSession.ID> = []
        var firstClampedRecords: Set<ClosedSession.ID> = []
        var mergedTombstones = tombstones
        for (id, remoteAt) in remote.tombstones {
            let at: Int64
            if remoteAt <= latest {
                at = remoteAt
            } else if let held = mergedTombstones[id] {
                at = held
            } else {
                at = latest
                firstClampedTombstones.insert(id)
            }
            mergedTombstones[id] = max(mergedTombstones[id] ?? at, at)
        }
        mergedTombstones = mergedTombstones.filter { $0.value >= cutoff }

        var merged = Dictionary(sessions.map { ($0.id, $0) }) { first, _ in first }
        for (id, record) in remoteRecords where knownHosts.contains(record.hostID) {
            let isClamped = remote.records[id] != record
            guard let local = merged[id] else {
                merged[id] = record
                if isClamped { firstClampedRecords.insert(id) }
                continue
            }
            if !isClamped
                && (Self.isLater(record, than: local)
                    || (!Self.isLater(local, than: record) && record != local))
            {
                merged[id] = record.mergingChatMode(of: local)
            } else if record.chatMode, !local.chatMode {
                merged[id] = local.mergingChatMode(of: record)
            }
        }
        merged = merged.filter { id, session in
            session.closedAtMilliseconds >= cutoff
                && !Self.isOverridden(session, by: mergedTombstones[id])
        }

        let nextSessions = Self.ordered(merged.values)
        let changed = nextSessions != sessions
        if changed || mergedTombstones != tombstones {
            sessions = nextSessions
            tombstones = mergedTombstones
            persist()
        }

        for (id, at) in mergedTombstones
        where remote.tombstones[id].map({ $0 < at || firstClampedTombstones.contains(id) }) ?? true
        {
            try shared.write(
                SyncedClosedSessionCatalog.encodeTombstone(at: at),
                account: SyncedClosedSessionCatalog.tombstoneAccount(for: id))
        }
        for session in nextSessions where !remote.unreadable.contains(session.id) {
            if let published = remote.records[session.id],
                published == session
                    || (remoteRecords[session.id] != published
                        && !firstClampedRecords.contains(session.id))
            {
                continue
            }
            try shared.write(
                SyncedClosedSessionCatalog.encode(session),
                account: SyncedClosedSessionCatalog.account(for: session.id))
        }
        for (id, record) in remoteRecords
        where merged[id] == nil
            && (record.closedAtMilliseconds < cutoff
                || Self.isOverridden(record, by: mergedTombstones[id]))
        {
            try? shared.removeSecret(account: SyncedClosedSessionCatalog.account(for: id))
        }
        for id in remote.tombstones.keys where mergedTombstones[id] == nil {
            try? shared.removeSecret(account: SyncedClosedSessionCatalog.tombstoneAccount(for: id))
        }
        return changed
    }

    /// Tombstones go only to the user's Forget and to a used resume of a
    /// record without a session. Each is stamped no earlier than the record
    /// it forgets: that record's times may come from a device whose clock
    /// runs ahead of this one, and a tombstone earlier than them would
    /// forget nothing.
    private func forget(_ ids: [ClosedSession.ID]) {
        let current = ClosedSession.milliseconds(now())
        forget(Dictionary(ids.map { ($0, current) }) { first, _ in first })
    }

    /// Forgets each record with a tombstone stamped at its time, or at the
    /// record's own times when later. A row backed out of stays unlisted
    /// until its closure is captured.
    private func forget(_ stamps: [ClosedSession.ID: Int64]) {
        guard !stamps.isEmpty else { return }
        for (id, stamp) in stamps {
            let shown = sessions.first { $0.id == id }.map {
                max($0.closedAtMilliseconds, $0.lastSeenRunningAtMilliseconds)
            }
            let at = max(stamp, shown ?? stamp)
            tombstones[id] = max(tombstones[id] ?? at, at)
        }
        perform(send(.forgotten(stamps)))
        sessions.removeAll { stamps[$0.id] != nil }
        persist()
        onLocalChange()
    }

    private func isForgotten(_ session: ClosedSession) -> Bool {
        Self.isOverridden(session, by: tombstones[session.id])
    }

    /// A tombstone forgets a copy last seen running no later than it: one
    /// seen running afterwards closed again.
    private static func isOverridden(_ session: ClosedSession, by tombstone: Int64?) -> Bool {
        guard let tombstone else { return false }
        return session.lastSeenRunningAtMilliseconds <= tombstone
    }

    /// Whether `candidate` is a later closure than `current`, a copy of the
    /// same record: its Agent was seen running later, or as late and it was
    /// noticed gone later.
    private static func isLater(_ candidate: ClosedSession, than current: ClosedSession) -> Bool {
        (candidate.lastSeenRunningAtMilliseconds, candidate.closedAtMilliseconds)
            > (current.lastSeenRunningAtMilliseconds, current.closedAtMilliseconds)
    }

    private func cutoffMilliseconds() -> Int64 {
        ClosedSession.milliseconds(now().addingTimeInterval(-Self.retention))
    }

    /// A session as it runs on one Host: another Host running the same
    /// session id says nothing about this one's.
    private static func sessionKey(hostID: Host.ID, kind: String, value: String) -> String {
        "\(hostID.uuidString)\u{1F}\(kind)\u{1F}\(value)"
    }

    private static func ordered(_ sessions: some Sequence<ClosedSession>) -> [ClosedSession] {
        sessions.sorted {
            if $0.closedAtMilliseconds != $1.closedAtMilliseconds {
                return $0.closedAtMilliseconds > $1.closedAtMilliseconds
            }
            return $0.id < $1.id
        }
    }

    /// Small and infrequent (a capture, a Forget, a pass that changed
    /// something), so written in place rather than queued.
    private func persist() {
        guard let directory else { return }
        let blob = PersistedBlob(
            version: Self.blobVersion, sessions: sessions.map(LossySession.init),
            tombstones: tombstones,
            pendingResumes: pendingResumes.isEmpty
                ? nil
                : Dictionary(pendingResumes.values.map { ($0.record, $0.beganAt) }, uniquingKeysWith: min))
        do {
            try prepare(directory)
            try JSONEncoder().encode(blob).write(
                to: directory.appending(path: Self.fileName),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            Self.log.error("Closed Sessions write failed: \(error.localizedDescription)")
        }
    }

    /// The backup exclusion sits on the directory: an atomic write replaces
    /// the file, and with it any attribute set on the file itself.
    private func prepare(_ directory: URL) throws {
        guard !preparedDirectory else { return }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = directory
        try url.setResourceValues(values)
        preparedDirectory = true
    }
}
