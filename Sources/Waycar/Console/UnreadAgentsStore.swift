import Foundation
import Observation

/// Agents the user marked unread on Console rows (Mark as Unread), keyed by
/// `(hostID, paneID)` — the same identity as `ConsoleAgent.ID`. herdr
/// derives Done as `idle && !seen` on the Host and offers no way to reset
/// `seen`, so the mark lives only on this device: an Idle Agent carrying it
/// is listed as Done in the Console index until the user opens it or herdr
/// reports activity for it — anything but Idle, or a `stateChangeSeq` other
/// than the one the row carried when it was marked (a Working turn that
/// came and went between two snapshots). Agent Notifications, banners, Live
/// Activities and `agent.focus` keep herdr's own status; only the index
/// reads `displayed(_:)`. Device-local, never an iCloud-synced preference.
@MainActor
@Observable
final class UnreadAgentsStore {
    static let defaultsKey = "unread-agents"
    private static let blobVersion = 1

    private struct PersistedBlob: Codable {
        let version: Int
        let entries: [Entry]
    }

    /// `stateChangeSeq` is optional on the wire and absent from blobs
    /// written before it was stored; a nil one falls back to the status
    /// check alone until a verified Idle row supplies it. `backend` is the
    /// marked row's (ADR 0026), absent from blobs written before tmux
    /// support, which read as herdr: only that backend's verified snapshots
    /// settle the mark.
    private struct Entry: Codable, Equatable {
        let hostID: UUID
        let paneID: String
        var stateChangeSeq: Int?
        var backend: HostBackend?

        init(_ id: ConsoleAgent.ID, stateChangeSeq: Int?, backend: HostBackend) {
            hostID = id.hostID
            paneID = id.paneID
            self.stateChangeSeq = stateChangeSeq
            self.backend = backend
        }

        var id: ConsoleAgent.ID { ConsoleAgent.ID(hostID: hostID, paneID: paneID) }
        var scopeBackend: HostBackend { backend ?? .herdr }
    }

    private var entries: [ConsoleAgent.ID: Entry]
    /// Marks re-keyed onto a moved pane's new id: the verified rows keep
    /// the old id until herdr's next snapshot lists the new one, so such a
    /// mark is not "gone" before its pane first appears. In memory only —
    /// after a relaunch the first verified snapshot settles it as usual.
    @ObservationIgnored private var awaitingPanes: Set<ConsoleAgent.ID> = []
    /// Marks whose pane a `pane.move` in flight is re-keying: herdr moves
    /// the pane before its reply names the new id, so a snapshot landing in
    /// between no longer lists the old one. Unlike `awaitingPanes`, a
    /// listing row does not end the hold; `rekey` or `cancelMove` does.
    @ObservationIgnored private var movingPanes: Set<ConsoleAgent.ID> = []
    // UserDefaults is documented thread-safe; Sendable modulo that promise.
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = Self.load(from: defaults)
    }

    private static func load(from defaults: UserDefaults) -> [ConsoleAgent.ID: Entry] {
        guard let data = defaults.data(forKey: defaultsKey),
            let blob = try? JSONDecoder().decode(PersistedBlob.self, from: data),
            // Marks are cheap to lose: an unknown version starts empty and
            // the next write replaces it.
            blob.version == blobVersion
        else { return [:] }
        return Dictionary(blob.entries.map { ($0.id, $0) }) { _, last in last }
    }

    func isMarkedUnread(_ id: ConsoleAgent.ID) -> Bool {
        entries[id] != nil
    }

    /// Only an Idle Agent can be marked: a Working or Blocked one has news
    /// coming anyway, a Done one is already unread on the Host, and a Shell
    /// has no Agent Status.
    func canMarkUnread(_ agent: ConsoleAgent) -> Bool {
        !agent.isShell && agent.agent.status == .idle && !isMarkedUnread(agent.id)
    }

    /// Returns whether the mark was added. It records the row's
    /// `stateChangeSeq` only while that still describes the Idle it shows:
    /// after a status delta it records none and takes the sequence from the
    /// next verified Idle row instead.
    @discardableResult
    func markUnread(_ agent: ConsoleAgent) -> Bool {
        guard canMarkUnread(agent) else { return false }
        entries[agent.id] = Entry(
            agent.id, stateChangeSeq: agent.agent.statusStateChangeSeq, backend: agent.backend)
        persist()
        return true
    }

    /// Clears the mark: the user opened the Agent, or chose Mark as Read.
    /// Returns whether there was a mark to clear.
    @discardableResult
    func markRead(_ id: ConsoleAgent.ID) -> Bool {
        guard entries.removeValue(forKey: id) != nil else { return false }
        awaitingPanes.remove(id)
        persist()
        return true
    }

    /// Holds `id`'s mark through the `pane.move` about to re-key its pane:
    /// a snapshot that no longer lists the old id does not clear it. Status
    /// activity still does. `rekey` or `cancelMove` ends the hold.
    func beginMove(_ id: ConsoleAgent.ID) {
        guard entries[id] != nil else { return }
        movingPanes.insert(id)
    }

    /// Ends the hold `beginMove` took when the move failed; the next
    /// verified snapshot settles the mark as usual.
    func cancelMove(_ id: ConsoleAgent.ID) {
        movingPanes.remove(id)
    }

    /// Carries a mark to the pane id herdr assigned a moved pane
    /// (`pane.move` re-keys it) and ends the move's hold. The new pane's
    /// `stateChangeSeq` is not known yet, so the mark takes it from the
    /// first verified Idle row.
    func rekey(_ id: ConsoleAgent.ID, toPaneID paneID: String) {
        movingPanes.remove(id)
        let target = ConsoleAgent.ID(hostID: id.hostID, paneID: paneID)
        guard target != id, let moved = entries.removeValue(forKey: id) else { return }
        awaitingPanes.remove(id)
        entries[target] = Entry(target, stateChangeSeq: nil, backend: moved.scopeBackend)
        awaitingPanes.insert(target)
        persist()
    }

    /// Settles one Host backend's marks against rows its live snapshot
    /// verified: a pane that is gone loses its mark, and so does one herdr
    /// reports activity for — anything but Idle, or a `stateChangeSeq` that
    /// moved since the mark (a turn that started and finished unobserved).
    /// New activity is the Host's own news again, and it must not come back
    /// as a stale Done. A mark without a recorded sequence adopts the Idle
    /// row's. A row whose status a delta replaced is judged by status alone:
    /// its `stateChangeSeq` belongs to the snapshot's status, not this one.
    /// Marks on the Host's other backend are left alone. Returns whether any
    /// mark was cleared.
    @discardableResult
    func reconcile(
        hostID: Host.ID, backend: HostBackend = .herdr, agents: [String: ConsoleAgent]
    ) -> Bool {
        var stale: [ConsoleAgent.ID] = []
        var adopted = false
        for (id, entry) in entries where id.hostID == hostID && entry.scopeBackend == backend {
            guard let row = agents[id.paneID] else {
                if !awaitingPanes.contains(id), !movingPanes.contains(id) { stale.append(id) }
                continue
            }
            awaitingPanes.remove(id)
            guard row.agent.status == .idle else {
                stale.append(id)
                continue
            }
            guard !row.agent.statusReplacedSinceSnapshot else { continue }
            let sequence = row.agent.stateChangeSeq
            if let recorded = entry.stateChangeSeq {
                if sequence != recorded { stale.append(id) }
            } else if sequence != nil {
                entries[id]?.stateChangeSeq = sequence
                adopted = true
            }
        }
        for id in stale {
            entries.removeValue(forKey: id)
        }
        if !stale.isEmpty || adopted { persist() }
        return !stale.isEmpty
    }

    /// Drops the marks of Hosts no longer in the catalog.
    func retainHosts(_ hostIDs: Set<Host.ID>) {
        let kept = entries.filter { hostIDs.contains($0.key.hostID) }
        guard kept.count != entries.count else { return }
        entries = kept
        awaitingPanes = awaitingPanes.filter { hostIDs.contains($0.hostID) }
        persist()
    }

    /// The row as the Console index lists it: a marked Idle Agent reads
    /// Done — its badge, colour, Status pills and sort bucket.
    func displayed(_ agent: ConsoleAgent) -> ConsoleAgent {
        guard agent.agent.status == .idle, isMarkedUnread(agent.id) else { return agent }
        var listed = agent
        listed.display(as: .done)
        return listed
    }

    private func persist() {
        let blob = PersistedBlob(version: Self.blobVersion, entries: Array(entries.values))
        guard let data = try? JSONEncoder().encode(blob) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
