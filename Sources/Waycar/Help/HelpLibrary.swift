import Foundation

/// The bundled Help catalogue, read once per process off the main actor:
/// loading reads every page and builds the search index, so no screen pays
/// for it during its first render. Concurrent callers share the one load.
/// Nil when the bundle's `help/` folder could not be read; Help then points
/// at waycar.dev instead.
enum HelpLibrary {
    @MainActor private static var load: Task<HelpCatalog?, Never>?

    @MainActor static func catalog() async -> HelpCatalog? {
        if let load {
            return await load.value
        }
        let task = Task.detached(priority: .userInitiated) { try? HelpCatalog.bundled() }
        load = task
        return await task.value
    }
}
