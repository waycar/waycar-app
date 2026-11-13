import Foundation
import Observation

/// The Chat Markers each Host reported, plus the ones this device just
/// wrote, keyed like `ConsoleAgent.ID`. Persisted so a cold launch shows
/// the Chat view before the Host answers; the Host's list stays
/// authoritative through `replaceMarkers(_:for:)`, except for the markers
/// this device retired, whose Host copies stay ignored until deleted.
@MainActor
@Observable
final class ChatModeStore {
    static let defaultsKey = "chat-mode-markers"
    private static let blobVersion = 1
    /// How long a locally recorded marker survives a Host list that lacks
    /// it: the Host write may still be in flight.
    static let localRecordGrace = ChatMarkerAuthorityMachine.localRecordGrace

    private struct PersistedBlob: Codable {
        let version: Int
        let entries: [Entry]
        /// Absent from blobs written before markers were tombstoned.
        let tombstones: [Tombstone]?
    }

    /// A marker this device retired, by the launch it described.
    private struct Tombstone: Codable {
        let hostID: UUID
        let paneID: String
        let launchedAt: Date
    }

    /// What a Host's marker list leaves for the caller to fix on the Host.
    struct HostRepairs: Equatable, Sendable {
        /// Markers recorded here within `localRecordGrace` that the Host
        /// lacks: write them again.
        var rewrites: [ChatModeMarker] = []
        /// Panes whose retired marker the Host still lists: delete it again.
        var deletes: [String] = []
    }

    /// The existing on-disk shape. Machine states are mapped at this boundary
    /// so older installs can still read local records and tombstones.
    private struct Entry: Codable, Equatable {
        let hostID: UUID
        let marker: ChatModeMarker
        let recordedAt: Date?
    }

    private var authorities: [ConsoleAgent.ID: ChatMarkerAuthorityMachine]
    /// Increments on every marker change so views re-evaluate Chat Mode.
    private(set) var revision: UInt64 = 0
    // UserDefaults is documented thread-safe; Sendable modulo that promise.
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
        authorities = Self.load(from: defaults)
    }

    private static func load(from defaults: UserDefaults) -> [ConsoleAgent.ID: ChatMarkerAuthorityMachine] {
        guard let data = defaults.data(forKey: defaultsKey),
            let blob = try? JSONDecoder().decode(PersistedBlob.self, from: data),
            // A cache of Host state: unknown versions start empty and the next Host refresh refills it.
            blob.version == blobVersion
        else { return [:] }
        var loaded: [ConsoleAgent.ID: ChatMarkerAuthorityMachine] = [:]
        for entry in blob.entries {
            let state: ChatMarkerAuthorityMachine.State = entry.recordedAt.map {
                .local(entry.marker, recordedAt: $0)
            } ?? .confirmed(entry.marker)
            loaded[ConsoleAgent.ID(hostID: entry.hostID, paneID: entry.marker.paneID)] = .init(state: state)
        }
        for tombstone in blob.tombstones ?? [] {
            loaded[ConsoleAgent.ID(hostID: tombstone.hostID, paneID: tombstone.paneID)] =
                .init(state: .retired(launchedAt: tombstone.launchedAt))
        }
        return loaded
    }

    func marker(for id: ConsoleAgent.ID) -> ChatModeMarker? {
        authorities[id]?.marker
    }

    /// Whether `agent` is a Chat Mode Agent: its pane has a Chat Mode
    /// marker that still describes the Agent running there.
    func isChatMode(_ agent: ConsoleAgent) -> Bool {
        guard let marker = marker(for: agent.id), marker.chatMode else { return false }
        return marker.applies(to: agent.agent)
    }

    /// Whether `agent`'s pane has a marker, Chat Mode or a plain launch's
    /// pin, that still describes the Agent running there.
    func hasMarker(_ agent: ConsoleAgent) -> Bool {
        marker(for: agent.id)?.applies(to: agent.agent) ?? false
    }

    /// The Host's list wins except for recent local writes and retired
    /// launches. A Host refresh changes the revision at most once.
    @discardableResult
    func replaceMarkers(_ markers: [ChatModeMarker], for hostID: Host.ID) -> HostRepairs {
        var reported: [String: ChatModeMarker] = [:]
        for marker in markers {
            if let existing = reported[marker.paneID], existing.launchedAt >= marker.launchedAt { continue }
            reported[marker.paneID] = marker
        }
        let ids = Set(authorities.keys.filter { $0.hostID == hostID })
            .union(reported.keys.map { ConsoleAgent.ID(hostID: hostID, paneID: $0) })
        let currentTime = now()
        var effects: [(ConsoleAgent.ID, ChatMarkerAuthorityMachine.Effect)] = []
        for id in ids {
            effects += send(.reported(reported[id.paneID], now: currentTime), for: id).map { (id, $0) }
        }
        return perform(effects)
    }

    /// A local launch ends the pane's tombstone immediately.
    func record(_ marker: ChatModeMarker, hostID: Host.ID) {
        let id = ConsoleAgent.ID(hostID: hostID, paneID: marker.paneID)
        perform(send(.record(marker, now: now()), for: id).map { (id, $0) })
    }

    /// Best-effort Host deletion cannot resurrect a retired launch.
    func retire(_ id: ConsoleAgent.ID) {
        perform(send(.retire, for: id).map { (id, $0) })
    }

    /// A newly discovered session is a local write until the Host lists it.
    func updateSession(
        _ session: ChatModeMarker.Session, for id: ConsoleAgent.ID
    ) -> ChatModeMarker? {
        let effects = send(.session(session, now: now()), for: id)
        perform(effects.map { (id, $0) })
        return effects.isEmpty ? nil : marker(for: id)
    }

    /// Keep terminal AND session current across a herdr restore. Nil terminal
    /// stays nil; a missing live session retains the marker's existing one.
    func follow(_ agent: ConsoleAgent) -> ChatModeMarker? {
        let effects = send(.follow(agent.agent, now: now()), for: agent.id)
        perform(effects.map { (agent.id, $0) })
        return effects.isEmpty ? nil : marker(for: agent.id)
    }

    private func send(
        _ event: ChatMarkerAuthorityMachine.Event, for id: ConsoleAgent.ID
    ) -> [ChatMarkerAuthorityMachine.Effect] {
        var machine = authorities[id] ?? ChatMarkerAuthorityMachine()
        let previous = machine.state
        let effects = machine.handle(event)
        if machine.state != previous {
            authorities[id] = machine.state == .absent ? nil : machine
        }
        return effects
    }

    @discardableResult
    private func perform(_ effects: [(ConsoleAgent.ID, ChatMarkerAuthorityMachine.Effect)]) -> HostRepairs {
        var repairs = HostRepairs()
        var changed = false
        var revises = false
        for (id, effect) in effects {
            switch effect {
            case .changed(let revision):
                changed = true
                revises = revises || revision
            case .rewrite(let marker): repairs.rewrites.append(marker)
            case .delete: repairs.deletes.append(id.paneID)
            }
        }
        if revises { revision += 1 }
        if changed { persist() }
        return repairs
    }

    private func persist() {
        var entries: [Entry] = []
        var tombstones: [Tombstone] = []
        for (id, machine) in authorities {
            switch machine.state {
            case .local(let marker, let stamp):
                entries.append(Entry(hostID: id.hostID, marker: marker, recordedAt: stamp))
            case .confirmed(let marker):
                entries.append(Entry(hostID: id.hostID, marker: marker, recordedAt: nil))
            case .retired(let launch):
                tombstones.append(Tombstone(hostID: id.hostID, paneID: id.paneID, launchedAt: launch))
            case .absent: break
            }
        }
        let blob = PersistedBlob(version: Self.blobVersion, entries: entries, tombstones: tombstones)
        guard let data = try? JSONEncoder().encode(blob) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
