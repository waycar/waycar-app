import Foundation
import Observation

enum SnippetStoreError: Error, Equatable {
    /// `update`/`remove` addressed a Snippet id the catalog does not contain.
    case unknownSnippet
    /// Persisted bytes could not be decoded. They are deliberately left
    /// untouched so a later write cannot turn a recoverable catalog into loss.
    case catalogUnreadable
}

/// Owns the Snippet catalog: add/edit/remove/reorder plus persistence. One
/// global set, deliberately not scoped to a Host or an Agent — these describe
/// how the user talks, not what they are talking to.
///
/// Order is the user's, never usage-derived: the value of a Snippet is that
/// your thumb knows where it is, and a list that re-sorts itself destroys
/// exactly that.
@MainActor
@Observable
final class SnippetStore {
    static let defaultsKey = "snippets"
    private static let catalogVersion = 1

    private struct PersistedCatalog: Codable {
        let version: Int
        let snippets: [Snippet]
    }

    private var catalog = SnippetCatalogMachine()
    var snippets: [Snippet] { catalog.snippets }
    var catalogLoadError: SnippetStoreError? { catalog.catalogLoadError }
    // UserDefaults is documented thread-safe; Sendable modulo that promise.
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        _ = catalog.handle(.reloaded(Self.load(from: defaults)))
    }

    /// Re-reads the catalog after iCloud Sync replaced it (ADR 0019).
    func reload() {
        let loaded = Self.load(from: defaults)
        if loaded != catalog.state { _ = catalog.handle(.reloaded(loaded)) }
    }

    private static func load(from defaults: UserDefaults) -> SnippetCatalogMachine.State {
        guard let data = defaults.data(forKey: defaultsKey) else { return .available([]) }
        guard let snippets = decode(data) else { return .unreadable }
        return .available(snippets)
    }

    /// Whether this build can read a persisted catalog, e.g. one another
    /// device synced (ADR 0019).
    static func canRead(_ data: Data) -> Bool {
        decode(data) != nil
    }

    private static func decode(_ data: Data) -> [Snippet]? {
        guard let catalog = try? JSONDecoder().decode(PersistedCatalog.self, from: data),
            catalog.version == catalogVersion
        else { return nil }
        return catalog.snippets
    }

    func add(_ snippet: Snippet) throws {
        try send(.add(snippet))
    }

    func update(_ snippet: Snippet) throws {
        try send(.update(snippet))
    }

    func remove(_ id: Snippet.ID) throws {
        try send(.remove(id))
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) throws {
        try send(.move(source, to: destination))
    }

    /// Case- and diacritic-insensitive match over both the Title and the body,
    /// because a user searching for "review" may have written it in either.
    func matching(_ query: String) -> [Snippet] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return snippets }
        return snippets.filter { snippet in
            snippet.title.localizedStandardContains(trimmed)
                || snippet.body.localizedStandardContains(trimmed)
        }
    }

    private func send(_ event: SnippetCatalogMachine.Event) throws {
        for effect in catalog.handle(event) {
            switch effect {
            case .refuse(let error):
                throw error
            case .persist(let items):
                let encoded = try JSONEncoder().encode(
                    PersistedCatalog(version: Self.catalogVersion, snippets: items))
                defaults.set(encoded, forKey: Self.defaultsKey)
            }
        }
    }
}
