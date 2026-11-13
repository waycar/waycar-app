import Observation
import UIKit

/// The two logo marks the app icon comes in.
enum AppIconMark: String, CaseIterable, Identifiable, Sendable {
    /// A flat caboose with a `>_` shell prompt on its side.
    case caboose
    /// The `>_` prompt alone, its underscore riding on two wheels.
    case prompt

    var id: Self { self }

    var title: String {
        switch self {
        case .caboose: "Caboose"
        case .prompt: "Prompt"
        }
    }
}

/// Every home-screen icon the app ships. Raw values are the `.icon` bundle
/// names under `Sources/Waycar/AppIcons`, which `scripts/generate-app-icons.py`
/// writes and `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES` lists; all three
/// must agree.
enum AppIconOption: String, CaseIterable, Identifiable, Sendable {
    case cabooseDefault = "AppIcon"
    case caboosePhosphor = "AppIconCaboosePhosphor"
    case cabooseTomato = "AppIconCabooseTomato"
    case cabooseSignal = "AppIconCabooseSignal"
    case cabooseCobalt = "AppIconCabooseCobalt"
    case cabooseMono = "AppIconCabooseMono"
    case cabooseBlack = "AppIconCabooseBlack"
    case cabooseTeal = "AppIconCabooseTeal"
    case promptPhosphor = "AppIconPromptPhosphor"
    case promptAmber = "AppIconPromptAmber"
    case promptMono = "AppIconPromptMono"
    case promptBlack = "AppIconPromptBlack"
    case promptCoral = "AppIconPromptCoral"

    static let primary = Self.cabooseDefault

    var id: Self { self }

    /// The name `UIApplication.setAlternateIconName` takes; nil is the
    /// primary icon.
    var alternateIconName: String? {
        self == .primary ? nil : rawValue
    }

    /// The icon for an `alternateIconName`. An unknown name (an icon a newer
    /// build shipped, then an older one was restored) reads as the primary.
    init(alternateIconName: String?) {
        self = alternateIconName.flatMap(Self.init(rawValue:)) ?? .primary
    }

    var mark: AppIconMark {
        switch self {
        case .cabooseDefault, .caboosePhosphor, .cabooseTomato, .cabooseSignal, .cabooseCobalt, .cabooseMono, .cabooseBlack, .cabooseTeal:
            .caboose
        case .promptPhosphor, .promptAmber, .promptMono, .promptBlack, .promptCoral:
            .prompt
        }
    }

    /// The palette name, unique within a mark.
    var title: String {
        switch self {
        case .cabooseDefault: "Violet"
        case .caboosePhosphor, .promptPhosphor: "Phosphor"
        case .cabooseTomato: "Tomato"
        case .cabooseSignal: "Signal"
        case .cabooseCobalt: "Cobalt"
        case .cabooseMono, .promptMono: "White"
        case .cabooseBlack, .promptBlack: "Black"
        case .cabooseTeal: "Teal"
        case .promptAmber: "Amber"
        case .promptCoral: "Coral"
        }
    }

    /// iOS cannot hand back an alternate icon's image, so the generator also
    /// renders each one into `AppIconPreviews.xcassets`.
    var previewImageName: String { "\(rawValue)Preview" }

    static func options(for mark: AppIconMark) -> [Self] {
        allCases.filter { $0.mark == mark }
    }
}

/// What `AppIconSettings` needs from `UIApplication`, so tests can stand in.
@MainActor
protocol AlternateIconHost: AnyObject {
    var supportsAlternateIcons: Bool { get }
    var alternateIconName: String? { get }
    func setAlternateIconName(_ alternateIconName: String?) async throws
}

extension UIApplication: AlternateIconHost {}

/// The chosen home-screen icon. iOS stores the choice itself (per device, and
/// it survives updates), so there is nothing to persist or sync here: this
/// reads it back and asks iOS to change it.
@MainActor
@Observable
final class AppIconSettings {
    private(set) var selection: AppIconOption
    /// Set when iOS refused the last change; cleared by the next attempt.
    private(set) var lastError: String?
    @ObservationIgnored private let host: any AlternateIconHost

    init(host: any AlternateIconHost = UIApplication.shared) {
        self.host = host
        selection = AppIconOption(alternateIconName: host.alternateIconName)
    }

    var isSupported: Bool { host.supportsAlternateIcons }

    func select(_ option: AppIconOption) async {
        guard option != selection else { return }
        lastError = nil
        do {
            try await host.setAlternateIconName(option.alternateIconName)
            selection = option
        } catch {
            lastError = error.localizedDescription
            selection = AppIconOption(alternateIconName: host.alternateIconName)
        }
    }
}
