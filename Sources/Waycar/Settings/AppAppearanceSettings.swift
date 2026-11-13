import Foundation
import Observation
import SwiftUI

/// How the app itself should be lit. Separate from the terminal theme slots
/// (`TerminalThemeSettings`), which pick a palette *per* appearance — this
/// picks which appearance is in force in the first place.
enum AppAppearanceOption: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// nil hands the decision back to iOS, which is the default.
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// The app-wide light/dark override, applied once at the root view. Everything
/// downstream — including the terminal surfaces, which resolve their theme
/// against `\.colorScheme` — follows from that single `preferredColorScheme`.
@MainActor
@Observable
final class AppAppearanceSettings {
    static let defaultsKey = "app-appearance"

    private(set) var selection: AppAppearanceOption
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selection = Self.load(from: defaults)
    }

    /// Re-reads the choice after iCloud Sync changed it (ADR 0019).
    func reload() {
        let loaded = Self.load(from: defaults)
        if loaded != selection { selection = loaded }
    }

    private static func load(from defaults: UserDefaults) -> AppAppearanceOption {
        defaults.string(forKey: defaultsKey).flatMap(AppAppearanceOption.init(rawValue:)) ?? .system
    }

    var preferredColorScheme: ColorScheme? { selection.preferredColorScheme }

    func select(_ option: AppAppearanceOption) {
        guard option != selection else { return }
        selection = option
        defaults.set(option.rawValue, forKey: Self.defaultsKey)
    }
}
