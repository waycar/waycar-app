import Foundation
import Observation

/// One Host's AI Usage choices.
struct AIUsageHostSettings: Codable, Equatable, Sendable {
    /// Whether this Host may be probed for CodexBar and used as the AI Usage
    /// source; nil is undecided. `AIUsageStore` decides it when CodexBar is
    /// first found: on unless another Host is explicitly on and not known to
    /// lack CodexBar. Any user change to an undecided Host decides it on.
    var enabledChoice: Bool?
    /// Undecided Hosts are probed and usable like Hosts that are on.
    var isEnabled: Bool { enabledChoice != false }
    var refreshInterval: AIUsageRefreshInterval = .default
    /// The CodexBar executable to use instead of auto-detection; nil
    /// auto-detects.
    var customPath: String?

    init(
        enabledChoice: Bool? = nil,
        refreshInterval: AIUsageRefreshInterval = .default,
        customPath: String? = nil
    ) {
        self.enabledChoice = enabledChoice
        self.refreshInterval = refreshInterval
        self.customPath = customPath
    }

    /// Field by field, so a field this build does not know is dropped and a
    /// retyped one falls back to its default instead of discarding the Host.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabledChoice = try? container.decodeIfPresent(Bool.self, forKey: .enabledChoice)
        refreshInterval = (try? container.decodeIfPresent(
            AIUsageRefreshInterval.self, forKey: .refreshInterval)) ?? .default
        customPath = (try? container.decodeIfPresent(String.self, forKey: .customPath)) ?? nil
    }

    private enum CodingKeys: String, CodingKey {
        case enabledChoice = "isEnabled"
        case refreshInterval, customPath
    }
}

/// Per-Host AI Usage settings, one versioned JSON catalog keyed by Host id in
/// `UserDefaults` (the `AgentRowLayoutStore` shape). Device-local: a custom
/// CodexBar path describes one Host's filesystem, and the choices are cheap
/// to redo. A catalog this build cannot read is ignored and replaced by the
/// next change, since nothing in it is worth refusing writes over.
///
/// Also holds the app-wide display options, one JSON blob of their own.
@MainActor
@Observable
final class AIUsagePreferences {
    static let defaultsKey = "ai-usage.host-settings"
    static let displayDefaultsKey = "ai-usage.display"
    private static let catalogVersion = 1

    private struct Catalog: Codable {
        let version: Int
        let hosts: [Host.ID: AIUsageHostSettings]
    }

    private(set) var hosts: [Host.ID: AIUsageHostSettings]
    private(set) var display: AIUsageDisplayOptions
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hosts = Self.load(from: defaults)
        display = defaults.data(forKey: Self.displayDefaultsKey)
            .flatMap { try? JSONDecoder().decode(AIUsageDisplayOptions.self, from: $0) }
            ?? AIUsageDisplayOptions()
    }

    func updateDisplay(_ options: AIUsageDisplayOptions) {
        guard options != display else { return }
        display = options
        guard let data = try? JSONEncoder().encode(options) else { return }
        defaults.set(data, forKey: Self.displayDefaultsKey)
    }

    func settings(for hostID: Host.ID) -> AIUsageHostSettings {
        hosts[hostID] ?? AIUsageHostSettings()
    }

    func update(_ settings: AIUsageHostSettings, for hostID: Host.ID) {
        var normalized = settings
        let trimmed = settings.customPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.customPath = trimmed?.isEmpty == false ? trimmed : nil
        var updated = hosts
        updated[hostID] = normalized == AIUsageHostSettings() ? nil : normalized
        guard updated != hosts else { return }
        hosts = updated
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(
            Catalog(version: Self.catalogVersion, hosts: hosts))
        else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private static func load(from defaults: UserDefaults) -> [Host.ID: AIUsageHostSettings] {
        guard let data = defaults.data(forKey: defaultsKey),
            let catalog = try? JSONDecoder().decode(Catalog.self, from: data),
            catalog.version == catalogVersion
        else { return [:] }
        return catalog.hosts
    }
}
