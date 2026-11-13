import Foundation

/// Everything the Attach surface and the Keys keyboard need to know about how
/// a terminal should look and what the user can send into it. Bundled into one
/// value because it was already four separate parameters threaded through
/// three screens, and the Keys keyboard needs all of them at once.
@MainActor
struct TerminalSettings {
    let themes: TerminalThemeSettings
    let zoom: TerminalZoomSettings
    let fonts: TerminalFontSettings
    let snippets: SnippetStore
    /// The Toolbar layout plus the Custom Key library.
    /// Required, so no test ever falls back to `UserDefaults.standard`.
    let toolbars: AgentToolbarLayoutStore
    /// Where the floating edge controls rest; defaulted so the many call
    /// sites that never move them need not know it exists.
    var edgeDock: EdgeDockSettings = EdgeDockSettings()
    /// Whether the ‹ at an Agent's top left shows; defaulted so the many
    /// call sites that never hide it need not know it exists.
    var backButton: AgentBackButtonSettings = AgentBackButtonSettings()
    /// The Agent Footer layout below the Toolbar; defaulted so the many
    /// call sites that never show it need not know it exists.
    var footer: AgentFooterLayoutStore = AgentFooterLayoutStore()
}
