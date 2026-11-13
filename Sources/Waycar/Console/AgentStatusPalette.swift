import UIKit

extension AgentStatus {
    /// The one status palette in the app, in two roles: `tintUIColor` is the
    /// wash (low-opacity capsule fills), `inkUIColor` the foreground (badge
    /// text, the switcher's dot). Both read from the same palette, so a
    /// colour never means two things. Blocked is blue, not red, to match
    /// herdr's sidebar, where the rows waiting on the user lead in blue —
    /// red is reserved for what this build cannot read.
    var tintUIColor: UIColor {
        switch self {
        case .blocked: AgentStatusPalette.blue
        case .done: AgentStatusPalette.green
        case .working: AgentStatusPalette.yellow
        // Unknown: something failed the palette cannot read, so it gets red.
        case .unknown: AgentStatusPalette.red
        // Idle, and anything this build cannot read: not asking for the
        // user, so it stays out of the way.
        default: AgentStatusPalette.muted
        }
    }

    /// The legible end of each status colour, for text and small solid
    /// indicators. Same hue as the wash; see `AgentStatusPalette` for why
    /// Latte cannot use the wash directly.
    var inkUIColor: UIColor {
        switch self {
        case .blocked: AgentStatusPalette.blueInk
        case .done: AgentStatusPalette.greenInk
        case .working: AgentStatusPalette.yellowInk
        case .unknown: AgentStatusPalette.redInk
        default: AgentStatusPalette.mutedInk
        }
    }
}

/// herdr's own agent colours, so the phone and the TUI agree on what green
/// means. herdr paints agent state from its Catppuccin palette; the two
/// flavours it ships pair straight into dynamic colours — Mocha on dark,
/// Latte on light. The values live in design/tokens.json (`status`) and
/// arrive through the generated `StatusPaletteTokens`.
enum AgentStatusPalette {
    /// Done.
    static let green = flavoured(StatusPaletteTokens.green)
    /// Working.
    static let yellow = flavoured(StatusPaletteTokens.yellow)
    /// Unknown.
    static let red = flavoured(StatusPaletteTokens.red)
    /// herdr's Catppuccin blue — the hue its sidebar paints the rows waiting
    /// on the user. Blocked carries it here for the same reason.
    static let blue = flavoured(StatusPaletteTokens.blue)
    /// herdr's muted-text role. Its Mocha `overlay0` is too dim to carry a
    /// label on a phone, so each flavour takes the legible end of the role:
    /// Mocha `overlay1`, Latte `subtext0`.
    static let muted = flavoured(StatusPaletteTokens.muted)

    /// Foreground counterparts. Mocha's pastels already clear 4.5:1 on the
    /// dark washes, so the dark flavour reuses them. Latte's bright hues do
    /// not (yellow measures 2.3:1 on its own capsule), and Catppuccin ships
    /// no darker accents — so the light inks keep each hue's OKLCH H and C
    /// and drop L until the badge text clears 4.5:1 on its wash. Muted has
    /// darker Catppuccin roles to reach for: Mocha `subtext0`,
    /// Latte `subtext1`.
    static let greenInk = flavoured(StatusPaletteTokens.greenInk)
    /// Working ink; see `greenInk`.
    static let yellowInk = flavoured(StatusPaletteTokens.yellowInk)
    /// Unknown ink; see `greenInk`.
    static let redInk = flavoured(StatusPaletteTokens.redInk)
    /// Same-hue darkening as the other Latte inks: Latte blue measures 2.2:1
    /// as badge text on its own capsule, so keep OKLCH H and C and drop L —
    /// the Latte ink clears 4.5:1 on the 0.15-op blue wash and 3:1 as a bare
    /// dot on the card.
    static let blueInk = flavoured(StatusPaletteTokens.blueInk)
    /// Idle (and unreadable statuses) ink; see `greenInk`.
    static let mutedInk = flavoured(StatusPaletteTokens.mutedInk)

    /// A dynamic colour: the Mocha value on dark, the Latte value on light.
    private static func flavoured(_ flavours: StatusPaletteTokens.Flavours) -> UIColor {
        UIColor { traits in
            UIColor(rgb: traits.userInterfaceStyle == .dark ? flavours.mocha : flavours.latte)
        }
    }
}

extension UIColor {
    /// An opaque sRGB colour from 0xRRGGBB.
    fileprivate convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1)
    }
}
