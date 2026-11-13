import SwiftUI

/// A dialog drawn over the terminal, for the moments when the terminal itself
/// cannot answer: the Host is unavailable, or the terminal has not started yet.
///
/// It carries its own background on purpose. The first version was a bare
/// `ContentUnavailableView`, which is transparent by design — over a live
/// terminal that left the copy competing with whatever glyphs happened to be
/// underneath it, and losing.
///
/// The background is the terminal's, not the system's: the theme owns the
/// whole screen (see `surfaceBackground(for:)`), and a `.regularMaterial` card
/// over a Solarized or Nord grid reads as a piece of some other app. The card
/// lifts off the terminal background rather than matching it, or it would be
/// invisible on the surface it sits on.
enum TerminalStatusGlyph {
    case symbol(String)
    /// For states the app is actively working through, where a still icon
    /// would read as "stuck".
    case progress
}

/// The status overlay Agent detail presents for one terminal state.
/// Keeping this mapping as a value lets hosted lifecycle tests observe the
/// actual presentation choice without snapshotting Ghostty's live Metal tree.
struct TerminalStatusPresentation: Equatable {
    enum Kind: Equatable {
        case connecting
        case ended
        /// The Host cannot be reached until the user acts; no terminal
        /// action helps, so the dialog offers none.
        case hostUnavailable(systemImage: String)
    }

    let kind: Kind
    let title: String
    let message: String?
    let dimsBackground: Bool

    static let connecting = TerminalStatusPresentation(
        kind: .connecting,
        title: "Connecting…",
        message: nil,
        dimsBackground: false)

    /// The attach ended. No dialog or dim goes with it: the terminal keeps
    /// its last content readable and the toolbar's connection dot says so
    /// (`TerminalConnectionIndicator`).
    static func ended(message: String) -> TerminalStatusPresentation {
        TerminalStatusPresentation(
            kind: .ended,
            title: "Detached",
            message: message,
            dimsBackground: false)
    }

    init?(status: AttachTerminalStore.Status) {
        switch status {
        case .waitingForSize, .connecting:
            self = .connecting
        case .ended(let message):
            self = .ended(message: message)
        case .live, .stopped:
            return nil
        }
    }

    /// While the attach still waits on its Host, the Host's condition speaks
    /// for it once it is worth saying (see
    /// `MissingAgentPresentation.attachHostCondition`).
    init?(status: AttachTerminalStore.Status, hostCondition: MissingAgentPresentation?) {
        switch (status, hostCondition) {
        case (.waitingForSize, .some(let condition)), (.connecting, .some(let condition)):
            switch condition.renderingMode {
            case .progress:
                self.init(
                    kind: .connecting, title: condition.title, message: condition.message,
                    dimsBackground: false)
            case .staticUnavailable:
                self.init(
                    kind: .hostUnavailable(systemImage: condition.systemImage),
                    title: condition.title, message: condition.message, dimsBackground: true)
            }
        default:
            self.init(status: status)
        }
    }

    private init(
        kind: Kind,
        title: String,
        message: String?,
        dimsBackground: Bool
    ) {
        self.kind = kind
        self.title = title
        self.message = message
        self.dimsBackground = dimsBackground
    }
}

struct TerminalStatusDialog<Actions: View>: View {
    let glyph: TerminalStatusGlyph
    let title: String
    var message: String?
    /// The active terminal theme's colours. Defaults to the system palette so
    /// previews and pixel tests need not carry a theme.
    var palette: TerminalThemePalette = .system
    /// Dims the terminal behind the dialog. Off for transient states, where a
    /// full-screen dim would flash on every reconnect.
    var dimsBackground = true
    @ViewBuilder let actions: () -> Actions

    private static var cornerRadius: CGFloat { 20 }

    var body: some View {
        ZStack {
            if dimsBackground {
                Rectangle()
                    .fill(.black.opacity(0.45))
                    .ignoresSafeArea()
            }

            VStack(spacing: 12) {
                switch glyph {
                case .symbol(let name):
                    Image(systemName: name)
                        .font(.system(size: 34))
                        .foregroundStyle(palette.foreground.opacity(0.7))
                case .progress:
                    ProgressView()
                        .controlSize(.large)
                        .tint(palette.accent)
                }
                Text(title)
                    .font(.headline)
                    .foregroundStyle(palette.foreground)
                if let message {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(palette.foreground.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
                actions()
                    .tint(palette.accent)
                    .padding(.top, 4)
            }
            .padding(24)
            .frame(maxWidth: 320)
            .background(cardBackground, in: .rect(cornerRadius: Self.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .strokeBorder(palette.foreground.opacity(0.12))
            }
            .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
            .padding(24)
        }
        .accessibilityElement(children: .contain)
    }

    private var cardBackground: Color {
        palette.statusCardBackground
    }
}

/// The compact Reconnecting pill over a live mosh terminal whose Host went
/// quiet (#105): the terminal keeps its live frame readable around it while
/// mosh waits for the Host to answer again.
struct TerminalReconnectingIndicator: View {
    var palette: TerminalThemePalette = .system

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(palette.accent)
            Text("Reconnecting…")
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(palette.foreground)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(palette.statusCardBackground, in: Capsule())
        .overlay {
            Capsule().strokeBorder(palette.foreground.opacity(0.12))
        }
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reconnecting")
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("terminal.reconnecting")
    }
}

/// The offline card over a terminal that is not live while a saved copy of
/// the conversation exists: it says the connection is down (`title`) and
/// offers the saved copy (`subtitle`). A button of its own, so the veil under
/// it stays untouchable and the rest of the screen keeps its touches.
struct TerminalReadSavedPill: View {
    var palette: TerminalThemePalette = .system
    var systemImage = "wifi.slash"
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(palette.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(palette.statusCardInk)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(palette.statusCardInk)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(palette.statusCardInk.opacity(0.6))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .background(palette.statusCardBackground, in: .rect(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(palette.statusCardInk.opacity(0.18))
            }
            .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title). \(subtitle)")
        .accessibilityHint("Shows the conversation this device saved, as text")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("terminal.readSaved")
    }
}

extension TerminalThemePalette {
    /// The terminal's background, lifted toward its foreground just enough to
    /// separate a status card from the grid it sits on — the same trick a TUI
    /// uses for a popup, and it works for a light theme and a dark one alike.
    var statusCardBackground: Color {
        background.mix(with: foreground, by: 0.08)
    }

    /// The ink for text on the status card: the theme's foreground, unless
    /// that does not reach 4.5:1 against the card (a theme's own light-on-light
    /// pairing may not), then black or white, whichever reads better.
    var statusCardInk: Color {
        let card = statusCardBackground
        if Self.contrastRatio(foreground, card) >= 4.5 { return foreground }
        return Self.contrastRatio(.black, card) >= Self.contrastRatio(.white, card)
            ? .black : .white
    }

    /// WCAG contrast ratio of two opaque colors.
    static func contrastRatio(_ a: Color, _ b: Color) -> Double {
        func luminance(_ color: Color) -> Double {
            let resolved = color.resolve(in: EnvironmentValues())
            return 0.2126 * Double(resolved.linearRed) + 0.7152 * Double(resolved.linearGreen)
                + 0.0722 * Double(resolved.linearBlue)
        }
        let (high, low) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (high + 0.05) / (low + 0.05)
    }
}

extension TerminalStatusDialog where Actions == EmptyView {
    init(
        glyph: TerminalStatusGlyph,
        title: String,
        message: String? = nil,
        palette: TerminalThemePalette = .system,
        dimsBackground: Bool = true
    ) {
        self.init(
            glyph: glyph, title: title, message: message, palette: palette,
            dimsBackground: dimsBackground, actions: { EmptyView() })
    }
}

#Preview("Host Unavailable") {
    let palette = TerminalThemeOption.solarized.palette(for: .dark)
    ZStack {
        palette.background
        TerminalStatusDialog(
            glyph: .symbol("wifi.slash"),
            title: "Host Unavailable",
            message: "The Host is not reachable.",
            palette: palette)
    }
}

#Preview("Connecting") {
    let palette = TerminalThemeOption.solarized.palette(for: .dark)
    ZStack {
        palette.background
        TerminalStatusDialog(
            glyph: .progress, title: "Connecting…", palette: palette, dimsBackground: false)
    }
}
