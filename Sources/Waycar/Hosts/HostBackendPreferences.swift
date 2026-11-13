import Foundation
import Observation

/// Per-Host backend visibility preferences (ADR 0026). Kept out of `Host`
/// because editing a Host replaces its projections and drops its terminals
/// (`ConsoleStore.setHosts`).
///
/// Separate legacy and runtime-visibility UserDefaults keys, synced through
/// iCloud Sync (ADR 0019, `PreferenceSync`): `reload()` re-reads it after
/// another device changed it.
@MainActor
@Observable
final class HostBackendPreferences {
    static let defaultsKey = "host-backend-preferences"
    private static let blobVersion = 1
    // An older build rewrites the legacy blob without unknown fields.
    // Its writes must never erase runtime visibility on another device.
    static let runtimeVisibilityKey = "host-runtime-visibility"

    private struct RuntimeVisibilityBlob: Codable {
        let version: Int
        var hosts: [String: [String: Bool]]
    }

    private var runtimeVisibility: [String: [String: Bool]] = [:]

    static func canReadRuntimeVisibility(_ data: Data) -> Bool {
        (try? JSONDecoder().decode(RuntimeVisibilityBlob.self, from: data))?.version == blobVersion
    }

    private static func loadRuntimeVisibility(from defaults: UserDefaults) -> [String: [String: Bool]] {
        guard let data = defaults.data(forKey: runtimeVisibilityKey),
            let blob = try? JSONDecoder().decode(RuntimeVisibilityBlob.self, from: data),
            blob.version == blobVersion else { return [:] }
        return blob.hosts
    }

    private struct PersistedBlob: Codable {
        let version: Int
        let hosts: [String: Entry]
    }

    /// Absent visibility defaults to shown. Legacy launch defaults are ignored.
    private struct Entry: Codable, Equatable {
        var showsTmux: Bool?

        var isEmpty: Bool {
            showsTmux == nil
        }
    }

    private var entries: [Host.ID: Entry]
    /// Runs after `reload()` changed anything, so the Console can start or
    /// end tmux projections another device's choice asks for.
    @ObservationIgnored var onReload: @MainActor () -> Void = {}
    // UserDefaults is documented thread-safe; Sendable modulo that promise.
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = Self.load(from: defaults)
        runtimeVisibility = Self.loadRuntimeVisibility(from: defaults)
    }

    /// Whether this build can read a synced value: a newer build's blob is
    /// neither adopted nor overwritten (`SyncedPreference.canRead`).
    static func canRead(_ data: Data) -> Bool {
        (try? JSONDecoder().decode(PersistedBlob.self, from: data))?.version == blobVersion
    }

    /// Re-reads the preferences after iCloud Sync replaced them.
    func reload() {
        let loaded = Self.load(from: defaults)
        let visibility = Self.loadRuntimeVisibility(from: defaults)
        guard loaded != entries || visibility != runtimeVisibility else { return }
        entries = loaded
        runtimeVisibility = visibility
        onReload()
    }

    /// Whether a Host running both backends lists its tmux sessions. On by
    /// default (decision 2).
    func showsTmux(for hostID: Host.ID) -> Bool {
        entries[hostID]?.showsTmux ?? true
    }

    /// Stores the choice only; `ConsoleStore.setShowsTmux` also starts or
    /// ends the tmux projection and tells the Host.
    func setShowsTmux(_ shows: Bool, for hostID: Host.ID) {
        update(hostID) { $0.showsTmux = shows ? nil : false }
    }

    /// Runtime inventories are shown by default, independently of the lead.
    func showsRuntime(_ runtime: HerdrRuntime, for hostID: Host.ID) -> Bool {
        runtimeVisibility[hostID.uuidString]?[runtime.rawValue] ?? true
    }

    func setShowsRuntime(_ shows: Bool, runtime: HerdrRuntime, for hostID: Host.ID) {
        setVisibility(shows, key: runtime.rawValue, for: hostID)
    }

    /// Separate additive runtime key: old synced blobs retain their original meaning.
    func showsZellij(for hostID: Host.ID) -> Bool {
        runtimeVisibility[hostID.uuidString]?["zellij"] ?? true
    }

    func setShowsZellij(_ shows: Bool, for hostID: Host.ID) {
        setVisibility(shows, key: "zellij", for: hostID)
    }

    /// Whether the Host lists a server chat runtime's sessions; shown by default.
    func showsServerChat(_ server: ServerChatBackend, for hostID: Host.ID) -> Bool {
        runtimeVisibility[hostID.uuidString]?[server.visibilityKey] ?? true
    }

    func setShowsServerChat(_ shows: Bool, _ server: ServerChatBackend, for hostID: Host.ID) {
        setVisibility(shows, key: server.visibilityKey, for: hostID)
    }

    private func setVisibility(_ shows: Bool, key: String, for hostID: Host.ID) {
        guard (runtimeVisibility[hostID.uuidString]?[key] ?? true) != shows else { return }
        runtimeVisibility[hostID.uuidString, default: [:]][key] = shows ? nil : false
        if runtimeVisibility[hostID.uuidString]?.isEmpty == true {
            runtimeVisibility[hostID.uuidString] = nil
        }
        let blob = RuntimeVisibilityBlob(version: Self.blobVersion, hosts: runtimeVisibility)
        guard let data = try? JSONEncoder().encode(blob) else { return }
        defaults.set(data, forKey: Self.runtimeVisibilityKey)
    }

    private func update(_ hostID: Host.ID, _ change: (inout Entry) -> Void) {
        var entry = entries[hostID] ?? Entry()
        change(&entry)
        let next = entry.isEmpty ? nil : entry
        guard entries[hostID] != next else { return }
        entries[hostID] = next
        persist()
    }

    private static func load(from defaults: UserDefaults) -> [Host.ID: Entry] {
        guard let data = defaults.data(forKey: defaultsKey),
            let blob = try? JSONDecoder().decode(PersistedBlob.self, from: data),
            blob.version == blobVersion
        else { return [:] }
        var entries: [Host.ID: Entry] = [:]
        for (key, entry) in blob.hosts {
            guard let id = UUID(uuidString: key), !entry.isEmpty else { continue }
            entries[id] = entry
        }
        return entries
    }

    private func persist() {
        let blob = PersistedBlob(
            version: Self.blobVersion,
            hosts: Dictionary(uniqueKeysWithValues: entries.map { ($0.key.uuidString, $0.value) }))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(blob) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
