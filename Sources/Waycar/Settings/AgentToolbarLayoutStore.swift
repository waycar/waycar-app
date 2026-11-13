import Foundation
import Observation
import UIKit

/// Which device-type toolbar catalog this device reads and writes. iPhone and
/// iPad each keep their own layout; Mac Catalyst and anything else use the
/// iPad one.
enum AgentToolbarDeviceKind: String, Sendable, CaseIterable {
    case phone
    case pad

    @MainActor static var current: AgentToolbarDeviceKind {
        UIDevice.current.userInterfaceIdiom == .phone ? .phone : .pad
    }
}

enum AgentToolbarLayoutStoreError: Error, Equatable {
    /// Persisted bytes could not be read by this build. They are left
    /// untouched and every write is refused until `resetUnreadableCatalog()`.
    case catalogUnreadable
    /// Two items refer to the same thing (key chord, action, Snippet or
    /// Custom Key).
    case duplicateItem
}

/// The synced toolbar catalog (ADR 0019): the Toolbar's one layout plus the
/// Custom Key library, kept per device type (iPhone, iPad) so each syncs
/// through iCloud on its own. With no stored layout the Toolbar follows the
/// code default, so improved defaults reach everyone who never customized.
///
/// Modeled on `AgentRowLayoutStore`: lenient decoding drops what this build
/// does not know (#320); a catalog it cannot read at all is kept byte for
/// byte, shows the defaults, and refuses writes until reset.
@MainActor
@Observable
final class AgentToolbarLayoutStore {
    static func defaultsKey(for idiom: AgentToolbarDeviceKind) -> String {
        "agent-toolbar-layouts.\(idiom.rawValue)"
    }

    /// The shared catalog key used before the per-device split. Adopted once
    /// into the device-type key, then removed so Reset cannot resurrect it.
    static let legacyDefaultsKey = "agent-toolbar-layouts"

    private(set) var catalog: AgentToolbarCatalog
    private(set) var catalogLoadError: AgentToolbarLayoutStoreError?
    // UserDefaults is documented thread-safe; Sendable modulo that promise.
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults
    @ObservationIgnored let defaultsKey: String

    init(defaults: UserDefaults = .standard, idiom: AgentToolbarDeviceKind = .current) {
        self.defaults = defaults
        defaultsKey = Self.defaultsKey(for: idiom)
        Self.adoptLegacyCatalog(in: defaults, key: defaultsKey)
        (catalog, catalogLoadError) = Self.load(from: defaults, key: defaultsKey)
    }

    private static func adoptLegacyCatalog(in defaults: UserDefaults, key: String) {
        guard let legacy = defaults.data(forKey: legacyDefaultsKey) else { return }
        if defaults.data(forKey: key) == nil {
            defaults.set(legacy, forKey: key)
        }
        defaults.removeObject(forKey: legacyDefaultsKey)
    }

    /// Re-reads the catalog after iCloud Sync replaced it (ADR 0019).
    func reload() {
        let (loaded, error) = Self.load(from: defaults, key: defaultsKey)
        if loaded != catalog { catalog = loaded }
        if error != catalogLoadError { catalogLoadError = error }
    }

    private static func load(
        from defaults: UserDefaults, key: String
    ) -> (AgentToolbarCatalog, AgentToolbarLayoutStoreError?) {
        guard let data = defaults.data(forKey: key) else { return (.empty, nil) }
        guard let catalog = decode(data) else { return (.empty, .catalogUnreadable) }
        return (catalog, nil)
    }

    /// Whether this build can read a persisted catalog, e.g. one another
    /// device synced (ADR 0019). Only an unknown `version` or undecodable
    /// JSON is unreadable; unknown items and actions are dropped.
    static func canRead(_ data: Data) -> Bool {
        decode(data) != nil
    }

    private static func decode(_ data: Data) -> AgentToolbarCatalog? {
        try? JSONDecoder().decode(AgentToolbarCatalog.self, from: data)
    }

    var isCatalogUnreadable: Bool { catalogLoadError != nil }

    /// Discards an unreadable catalog so the Toolbar follows its default
    /// again and writes are accepted. The only way out of
    /// `catalogLoadError`; a readable catalog is left alone.
    func resetUnreadableCatalog() {
        guard catalogLoadError != nil else { return }
        defaults.removeObject(forKey: defaultsKey)
        catalog = .empty
        catalogLoadError = nil
    }

    // MARK: Layout

    /// The stored layout (normalized) or the default. Snippet and Custom Key
    /// references are not filtered here; resolve against an
    /// `AgentToolbarAvailability` to render.
    var layout: AgentToolbarLayout {
        catalog.layout ?? .default
    }

    /// Whether a stored layout or spacing replaces the default ("Customized"
    /// tag, enables Reset).
    var isCustomized: Bool {
        catalog.layout != nil || catalog.storedItemSpacing != nil
    }

    /// What the Toolbar shows for this Agent view.
    func resolvedLayout(availability: AgentToolbarAvailability) -> AgentToolbarLayout {
        availability.resolve(layout)
    }

    /// Saves `layout`. Duplicates are rejected. A layout equal to the default
    /// removes the stored one.
    func setLayout(_ layout: AgentToolbarLayout) throws {
        var seen = Set<AgentToolbarItem.Content>()
        for item in layout.items {
            guard seen.insert(item.content).inserted else { throw AgentToolbarLayoutStoreError.duplicateItem }
        }
        var updated = catalog
        updated.setLayout(layout)
        try persist(updated)
    }

    /// Back to the code default layout and spacing. The Custom Key library
    /// is kept.
    func resetLayout() throws {
        var updated = catalog
        updated.setLayout(nil)
        updated.setItemSpacing(nil)
        try persist(updated)
    }

    // MARK: Spacing

    /// Gap between Toolbar buttons in points (default 12, 1…24, step 1).
    var itemSpacing: Double { catalog.itemSpacing }

    /// Saves the spacing, clamped to 1…24 and snapped to 1 pt steps.
    func setItemSpacing(_ spacing: Double) throws {
        var updated = catalog
        updated.setItemSpacing(spacing)
        try persist(updated)
    }

    // MARK: Custom Keys

    var customKeys: [CustomKey] { catalog.customKeys }

    func customKey(_ id: CustomKey.ID) -> CustomKey? {
        catalog.customKey(id)
    }

    /// Whether the Custom Key is on the Toolbar.
    func isOnBar(_ id: CustomKey.ID) -> Bool {
        layout.contains(.customKey(id))
    }

    /// Adds or replaces `key` (validated and normalized). `addToBar` appends
    /// it to the end of the Toolbar when it is not there yet and removes it
    /// when false; an item already on the bar keeps its place.
    func upsertCustomKey(_ key: CustomKey, addToBar: Bool) throws {
        let validKey = try key.validated()
        var updated = catalog
        if let index = updated.customKeys.firstIndex(where: { $0.id == validKey.id }) {
            updated.customKeys[index] = validKey
        } else {
            updated.customKeys.append(validKey)
        }
        let content = AgentToolbarItem.Content.customKey(validKey.id)
        var edited = layout
        if addToBar, !edited.contains(content) {
            edited.items.append(AgentToolbarItem(content))
            updated.setLayout(edited)
        } else if !addToBar, edited.contains(content) {
            edited.remove(content)
            updated.setLayout(edited)
        }
        try persist(updated)
    }

    /// Removes the Custom Key and every reference to it.
    func deleteCustomKey(_ id: CustomKey.ID) throws {
        var updated = catalog
        updated.customKeys.removeAll { $0.id == id }
        let content = AgentToolbarItem.Content.customKey(id)
        if catalog.layout != nil, layout.contains(content) {
            var edited = layout
            edited.remove(content)
            updated.setLayout(edited)
        }
        try persist(updated)
    }

    // MARK: Persistence

    private func persist(_ updated: AgentToolbarCatalog) throws {
        guard catalogLoadError == nil else { throw AgentToolbarLayoutStoreError.catalogUnreadable }
        if updated.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
        } else {
            defaults.set(try JSONEncoder().encode(updated), forKey: defaultsKey)
        }
        if updated != catalog { catalog = updated }
    }
}
