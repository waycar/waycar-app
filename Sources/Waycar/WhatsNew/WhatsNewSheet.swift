import SwiftUI
import UIKit

/// Shows the CI-written summaries of every build newer than the one the user
/// last saw, newest first, dressed in the app icon's palette so an update
/// feels like Waycar rather than a settings list. One button continues into
/// the app.
struct WhatsNewSheet: View {
    let builds: [WhatsNewBuild]
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false
    @ScaledMetric(relativeTo: .largeTitle) private var markHeight: CGFloat = 88
    @ScaledMetric(relativeTo: .body) private var badgeSize: CGFloat = 36

    /// Keeps lines readable on iPad instead of stretching across the sheet.
    private static let maxContentWidth: CGFloat = 560

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                header
                // Offset, not build: a local entry may share a CI build's number.
                ForEach(Array(builds.enumerated()), id: \.offset) { index, build in
                    buildCard(build, firstStep: firstStep(ofBuildAt: index))
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 36)
            .padding(.bottom, 20)
            .frame(maxWidth: Self.maxContentWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) { footer }
        .background { background }
        // The sheet is always dark, so keep system chrome (scroll indicators,
        // focus rings) in its dark variant regardless of the app's setting.
        .preferredColorScheme(.dark)
        .presentationBackground(Brand.Colors.markGround)
        .onAppear { revealed = true }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 14) {
            WaycarCabooseMark()
                .frame(height: markHeight)
            Text("What's New")
                .font(.largeTitle.bold())
                .fontDesign(.rounded)
                .foregroundStyle(Brand.Colors.markInk)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            if let range = buildRange {
                Text(range.text)
                    .font(.subheadline.weight(.semibold))
                    .fontDesign(.rounded)
                    .monospacedDigit()
                    .foregroundStyle(Brand.Colors.markGround)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Brand.Colors.markAccent, in: Capsule())
                    .accessibilityLabel(range.spoken)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// "Build 123", or "Builds 121–123" when the user skipped some updates;
    /// the spoken form avoids VoiceOver reading the en dash literally.
    private var buildRange: (text: String, spoken: String)? {
        let numbers = builds.map(\.build)
        guard let oldest = numbers.min(), let newest = numbers.max() else { return nil }
        if oldest == newest { return ("Build \(newest)", "Build \(newest)") }
        return ("Builds \(oldest)–\(newest)", "Builds \(oldest) through \(newest)")
    }

    // MARK: - Builds

    private func buildCard(_ build: WhatsNewBuild, firstStep: Int) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // A lone build is already named by the header pill.
            if builds.count > 1 {
                Text("Build \(String(build.build)) · \(Self.formattedDate(build.date))")
                    .font(.caption.weight(.semibold))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(Brand.Colors.markHighlight)
                    .accessibilityAddTraits(.isHeader)
            }
            ForEach(Array(build.items.enumerated()), id: \.offset) { offset, item in
                row(item)
                    .modifier(StaggeredReveal(step: firstStep + 1 + offset, revealed: revealed, reduceMotion: reduceMotion))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Brand.Colors.markSurface.opacity(0.45),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .modifier(StaggeredReveal(step: firstStep, revealed: revealed, reduceMotion: reduceMotion))
    }

    private func row(_ item: WhatsNewItem) -> some View {
        HStack(spacing: 14) {
            Image(systemName: Self.symbolName(item.symbol))
                .font(.body.weight(.semibold))
                .foregroundStyle(Brand.Colors.markGround)
                .frame(width: badgeSize, height: badgeSize)
                .background(Brand.Colors.markAccent, in: RoundedRectangle(cornerRadius: badgeSize * 0.28, style: .continuous))
                .accessibilityHidden(true)
            Text(item.text)
                .font(.body)
                .foregroundStyle(Brand.Colors.markInk)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    /// Reveal order: each card's caption first, then its rows, continuing
    /// across cards so the stagger reads top to bottom.
    private func firstStep(ofBuildAt index: Int) -> Int {
        builds.prefix(index).reduce(index) { $0 + $1.items.count }
    }

    /// CI validates symbols against an allowlist, but an older OS may not
    /// know a newer glyph; `sparkles` keeps the badge from rendering empty.
    private static func symbolName(_ symbol: String) -> String {
        UIImage(systemName: symbol) == nil ? "sparkles" : symbol
    }

    /// `YYYY-MM-DD` from CI, shown in the user's locale. Parsed in the local
    /// time zone so the calendar day doesn't slip back a day west of UTC.
    private static func formattedDate(_ raw: String) -> String {
        let style = Date.ISO8601FormatStyle(timeZone: .current).year().month().day()
        guard let date = try? style.parse(raw) else { return raw }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    // MARK: - Chrome

    private var footer: some View {
        Button("OK", action: onDismiss)
            .buttonStyle(CabooseButtonStyle())
            .keyboardShortcut(.defaultAction)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: Self.maxContentWidth)
            .frame(maxWidth: .infinity)
            .background(alignment: .bottom) {
                // Content scrolls under a fade rather than a hard bar edge;
                // a faint track runs beneath the button like the icon's rail.
                ZStack(alignment: .bottom) {
                    LinearGradient(
                        colors: [Self.deepGround.opacity(0), Self.deepGround],
                        startPoint: .top, endPoint: .center)
                    RailMotif()
                        .frame(height: 10)
                        .opacity(0.6)
                        .padding(.bottom, 2)
                }
                .ignoresSafeArea(edges: .bottom)
            }
    }

    private var background: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Brand.Colors.markGround, Self.deepGround], startPoint: .top, endPoint: .bottom)
            // A faint wash behind the caboose, as if from its cupola window.
            RadialGradient(
                colors: [Brand.Colors.markHighlight.opacity(0.12), .clear],
                center: .top, startRadius: 0, endRadius: 320)
        }
        .ignoresSafeArea()
    }

    /// The bottom of the ground gradient; the footer fade must end on it.
    private static let deepGround = Brand.Colors.markGround.mix(with: .black, by: 0.3)
}

/// Fades and lifts a piece of the sheet in on first appearance, delayed by its
/// place in the reading order. Skipped entirely with Reduce Motion.
private struct StaggeredReveal: ViewModifier {
    let step: Int
    let revealed: Bool
    let reduceMotion: Bool

    /// Caps the tail so long lists don't keep the user waiting.
    private var delay: Double { Double(min(step, 10)) * 0.05 }

    func body(content: Content) -> some View {
        let shown = revealed || reduceMotion
        return content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 12)
            .animation(reduceMotion ? nil : .spring(duration: 0.45, bounce: 0.15).delay(delay), value: revealed)
    }
}

/// `markAccent` capsule with `markGround` text, the app icon's own colors:
/// the icon cuts its prompt out of the car, down to the ground.
private struct CabooseButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Brand.Colors.markGround)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Brand.Colors.markAccent.opacity(configuration.isPressed ? 0.8 : 1), in: Capsule())
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// A rail with sleepers, echoing the track under the icon's caboose.
private struct RailMotif: View {
    var body: some View {
        Canvas { context, size in
            let sleeperWidth: CGFloat = 3
            let spacing: CGFloat = 26
            var x = (size.width.truncatingRemainder(dividingBy: spacing) + spacing - sleeperWidth) / 2
            while x < size.width {
                context.fill(
                    Path(roundedRect: CGRect(x: x, y: 0, width: sleeperWidth, height: size.height), cornerRadius: 1.5),
                    with: .color(Brand.Colors.markSurface.opacity(0.7)))
                x += spacing
            }
            context.fill(
                Path(roundedRect: CGRect(x: 0, y: size.height / 2 - 1.5, width: size.width, height: 3), cornerRadius: 1.5),
                with: .color(Brand.Colors.markSurface))
        }
        .accessibilityHidden(true)
    }
}

#Preview("Several builds") {
    WhatsNewSheet(
        builds: [
            WhatsNewBuild(build: 123, date: "2026-09-26", items: [
                WhatsNewItem(symbol: "sparkles", text: "What's New now shows a short summary after each update."),
                WhatsNewItem(symbol: "icloud.fill", text: "Hosts sync across your devices with iCloud."),
                WhatsNewItem(symbol: "ant.fill", text: "The composer no longer drops input after reconnecting."),
            ]),
            WhatsNewBuild(build: 122, date: "2026-09-24", items: [
                WhatsNewItem(symbol: "bolt.fill", text: "Sessions reconnect faster after the app wakes."),
                WhatsNewItem(symbol: "keyboard.fill", text: "New hardware keyboard shortcuts for switching tabs."),
            ]),
        ],
        onDismiss: {})
}

#Preview("One build") {
    WhatsNewSheet(
        builds: [
            WhatsNewBuild(build: 123, date: "2026-09-26", items: [
                WhatsNewItem(symbol: "sparkles", text: "What's New now shows a short summary after each update."),
                WhatsNewItem(symbol: "paintbrush.fill", text: "The sheet now wears Waycar's colors."),
            ]),
        ],
        onDismiss: {})
}
