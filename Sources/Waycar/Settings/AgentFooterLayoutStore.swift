import Foundation
import Observation

enum AgentFooterLayoutStoreError: Error, Equatable {
    /// Persisted bytes could not be read by this build. They are left
    /// untouched and every write is refused until `resetUnreadableCatalog()`.
    case catalogUnreadable
}

/// The synced Agent Footer layout (ADR 0019), kept per device type like the
/// Toolbar so iPhone and iPad each sync their own. With no stored layout the
/// footer follows the code default, so improved defaults reach everyone who
/// never customized.
///
/// Modeled on `AgentToolbarLayoutStore`: lenient decoding drops what this
/// build does not know (#320); a catalog it cannot read at all is kept byte
/// for byte, shows the default, and refuses writes until reset.
@MainActor
@Observable
final class AgentFooterLayoutStore {
    static func defaultsKey(for idiom: AgentToolbarDeviceKind) -> String {
        "agent-footer-layouts.\(idiom.rawValue)"
    }

    private static let version = 1

    private struct Catalog: Codable {
        let version: Int
        let layout: AgentFooterLayout
    }

    private var stored: AgentFooterLayout?
    private(set) var catalogLoadError: AgentFooterLayoutStoreError?
    // UserDefaults is documented thread-safe; Sendable modulo that promise.
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults
    @ObservationIgnored let defaultsKey: String

    init(defaults: UserDefaults = .standard, idiom: AgentToolbarDeviceKind = .current) {
        self.defaults = defaults
        defaultsKey = Self.defaultsKey(for: idiom)
        (stored, catalogLoadError) = Self.load(from: defaults, key: defaultsKey)
    }

    /// Re-reads the layout after iCloud Sync replaced it (ADR 0019).
    func reload() {
        let (loaded, error) = Self.load(from: defaults, key: defaultsKey)
        if loaded != stored { stored = loaded }
        if error != catalogLoadError { catalogLoadError = error }
    }

    private static func load(
        from defaults: UserDefaults, key: String
    ) -> (AgentFooterLayout?, AgentFooterLayoutStoreError?) {
        guard let data = defaults.data(forKey: key) else { return (nil, nil) }
        guard let layout = decode(data) else { return (nil, .catalogUnreadable) }
        return (layout, nil)
    }

    /// Whether this build can read a persisted layout, e.g. one another
    /// device synced (ADR 0019). Only an unknown `version` or undecodable
    /// JSON is unreadable; unknown fields are dropped.
    static func canRead(_ data: Data) -> Bool {
        decode(data) != nil
    }

    private static func decode(_ data: Data) -> AgentFooterLayout? {
        guard let catalog = try? JSONDecoder().decode(Catalog.self, from: data),
            catalog.version == version
        else { return nil }
        return catalog.layout.normalized()
    }

    var isCatalogUnreadable: Bool { catalogLoadError != nil }

    /// Discards an unreadable layout so the footer follows its default again
    /// and writes are accepted. The only way out of `catalogLoadError`; a
    /// readable layout is left alone.
    func resetUnreadableCatalog() {
        guard catalogLoadError != nil else { return }
        defaults.removeObject(forKey: defaultsKey)
        stored = nil
        catalogLoadError = nil
    }

    /// The stored layout (normalized) or the default.
    var layout: AgentFooterLayout { stored ?? .default }

    /// Whether a stored layout replaces the default ("Customized", enables Reset).
    var isCustomized: Bool { stored != nil }

    /// Normalizes and saves `layout`. A layout equal to the default removes
    /// the stored one.
    func setLayout(_ layout: AgentFooterLayout) throws {
        let normalized = layout.normalized()
        try persist(normalized == .default ? nil : normalized)
    }

    func resetLayout() throws {
        try persist(nil)
    }

    private func persist(_ updated: AgentFooterLayout?) throws {
        guard catalogLoadError == nil else { throw AgentFooterLayoutStoreError.catalogUnreadable }
        if let updated {
            defaults.set(try JSONEncoder().encode(Catalog(version: Self.version, layout: updated)), forKey: defaultsKey)
        } else {
            defaults.removeObject(forKey: defaultsKey)
        }
        if updated != stored { stored = updated }
    }
}
