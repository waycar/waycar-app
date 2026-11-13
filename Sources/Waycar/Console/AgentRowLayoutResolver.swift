/// Saved Host layouts take precedence. Otherwise, import herdr's first two
/// rows and initialize Waycar's third row with the directory.
/// Waycar's default is the silent last resort: it is never shown as a
/// choice and the user never edits it. Whatever the source, the Console
/// receives the three-slot shape without `state_icon`.
///
/// The herdr plugin's snapshot describes herdr rows only: a backend without
/// `pluginRowLayout` (tmux, ADR 0026) resolves as a Host with no plugin
/// layout does, its saved layout or Waycar's default.
enum AgentRowLayoutResolver {
    static func resolve(
        hostLayout: AgentRowLayout?,
        pluginSnapshot: AgentRowLayoutSnapshot?,
        backend: HostBackend = .herdr
    ) -> AgentRowLayout {
        if let hostLayout { return hostLayout.normalizedForConsole() }
        let plugin = backend.capabilities.pluginRowLayout ? pluginSnapshot : nil
        return (plugin?.layout ?? .waycarDefault).withWaycarRow()
    }
}
