import SwiftUI

extension EnvironmentValues {
    /// Opens the New Agent sheet prefilled from `preset`, closing whatever
    /// Help sits in. The Console sets it at its root so every Help surface
    /// inherits it; nil hides Help's **Ask an Agent**.
    @Entry var askAgent: (@MainActor (AgentLaunchPreset) -> Void)? = nil
}
