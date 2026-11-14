import SwiftUI

/// What stands in for the Agents before any Host exists, in order of how
/// much we want each: the scan for computers in the middle of the screen,
/// the Sample Host under it, and "Set up by hand" folded at the bottom, with
/// Scan to Pair and Add Manually docked under everything: text links beside
/// the scan's button, the one prominent button without it.
///
/// The two choices above the manual steps are slots, each empty until its
/// owner fills it: `findComputersRow` (the offer to scan for computers with
/// SSH on, the quickest way to a Host) and `sampleHostRow` (the Sample
/// Host). They sit centered in the space between the title and "Set up by
/// hand"; with both empty the steps stand alone under the title.
struct HostSetupGuide: View {
    let scan: () -> Void
    let addManually: () -> Void
    /// The Console passes it, since it shows no bottom bar before the first
    /// Host; the Hosts sheet passes none.
    var showSettings: (() -> Void)? = nil
    /// The Console passes it so its own sheet shows the install page and
    /// counts as covering its keyboard commands; the Hosts sheet passes none.
    var showHelp: (() -> Void)? = nil
    /// Slot, second: the Sample Host row.
    var sampleHostRow: AnyView? = nil
    /// Slot, first: the Find computers card.
    var findComputersRow: AnyView? = nil
    /// The heading over everything; the Sample Host's own "connect" page
    /// replaces it.
    var title = "Add Your First Host"

    private static let readableWidth: CGFloat = 560

    /// "Set up by hand" starts folded whenever rows sit above it.
    @State private var showsManualSteps = false

    private var hasRowsAboveSteps: Bool {
        sampleHostRow != nil || findComputersRow != nil
    }

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { scroller in
                ScrollView {
                    content(scroller)
                        // At least the visible height, so the spacers
                        // center the scan between the title and the
                        // folded steps.
                        .frame(minHeight: viewport.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        // Docked, so the default is in reach without scrolling: the setup on
        // waycar.dev ends with the Pairing Code already on screen.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            actions
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private static let stepsAnchor = "setup.by-hand.anchor"

    private func content(_ scroller: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            header
            if hasRowsAboveSteps {
                Spacer(minLength: 8)
                VStack(spacing: 20) {
                    if let findComputersRow { findComputersRow }
                    if let sampleHostRow { sampleHostRow }
                }
                Spacer(minLength: 8)
                setUpByHandToggle(scroller)
                    // Room above it once it is scrolled to the top.
                    .padding(.top, 16)
                    .id(Self.stepsAnchor)
                if showsManualSteps {
                    manualSteps
                    HelpLink(.install, action: showHelp)
                }
            } else {
                manualSteps
                HelpLink(.install, action: showHelp)
            }
        }
        .frame(maxWidth: Self.readableWidth, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text(title)
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 12)
            if let showSettings {
                Button(action: showSettings) {
                    Image(systemName: "gearshape")
                        .font(.title3)
                        .padding(12)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .hoverEffect(.highlight)
                .accessibilityLabel("Settings")
                // Laid out at the glyph's size, so it lines up with the
                // text column and leaves the row the title's height at
                // every text size; the 12pt around it stays tappable
                // (about 44pt at the default size).
                .padding(-12)
            }
        }
    }

    /// The manual steps fold away at the bottom: with a scan in the middle,
    /// most people never need them. Opening them scrolls them into view.
    private func setUpByHandToggle(_ scroller: ScrollViewProxy) -> some View {
        Button {
            withAnimation(.snappy) {
                showsManualSteps.toggle()
            } completion: {
                // Only once the opening has settled: a scroll during it
                // still finds the folded content, which fits the screen,
                // and goes nowhere.
                guard showsManualSteps else { return }
                withAnimation(.snappy) { scroller.scrollTo(Self.stepsAnchor, anchor: .top) }
            }
        } label: {
            HStack(spacing: 12) {
                Text("Set up by hand")
                    .font(.headline)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(showsManualSteps ? 90 : 0))
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityAddTraits(.isHeader)
        .accessibilityValue(showsManualSteps ? "Expanded" : "Collapsed")
        .accessibilityIdentifier("setup.by-hand")
    }

    private var manualSteps: some View {
        VStack(alignment: .leading, spacing: 22) {
            // Each detail is a single literal, so Text parses its
            // Markdown links.
            HostSetupStep(
                number: 1, title: "Install herdr or tmux on your first Host",
                detail: Text("""
                    Get herdr at [herdr.dev](https://herdr.dev), \
                    or use tmux 3.2 or later.
                    """))
            HostSetupStep(
                number: 2, title: "Turn on SSH",
                detail: Text("""
                    On a Mac, turn on [Remote Login](https://support.apple.com/guide/mac-help/allow-a-remote-computer-to-access-your-mac-mchlp1066/mac). \
                    On Linux, install and start the OpenSSH server.
                    """))
            HostSetupStep(
                number: 3, title: "Install Mosh (optional)",
                detail: Text("""
                    Steadier terminals on spotty networks. \
                    See how at [mosh.org](https://mosh.org/#getting).
                    """))
            // The installer's prompts ([Y/n], then the address
            // checklist) both accept Return, and both run in the
            // terminal that ran the installer, on a herdr and a tmux
            // Host alike, so the step says only "on your Host".
            // Pairing is optional, so the step names the manual path
            // too.
            HostSetupStep(
                number: 4, title: "Get a Pairing Code",
                detail: Text("""
                    Run this on your Host, then tap Scan to Pair. \
                    Or skip it and tap Add Manually to type the address.
                    """),
                command: WaycarPluginRequirement.installCommand)
        }
    }

    private var actions: some View {
        Group {
            // Text links when a scan for computers sits above: that is the
            // path most people should take, and an outlined button beside
            // it read as disabled.
            if hasRowsAboveSteps {
                HStack(spacing: 0) {
                    textLink("Scan to Pair", action: scan)
                    textLink("Add Manually", action: addManually)
                }
            } else {
                VStack(spacing: 4) {
                    Button(action: scan) {
                        Label("Scan to Pair", systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .hoverEffect(.highlight)
                    textLink("Add Manually", action: addManually)
                }
            }
        }
        .frame(maxWidth: Self.readableWidth)
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
        .overlay(alignment: .top) { Divider() }
    }

    /// Tinted text, at least 44 pt tall across its half of the row.
    private func textLink(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .hoverEffect(.highlight)
    }
}

private struct HostSetupStep: View {
    let number: Int
    let title: String
    let detail: Text
    var command: String?
    @ScaledMetric(relativeTo: .subheadline) private var badgeSize: CGFloat = 28

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number, format: .number)
                .font(.subheadline.weight(.semibold).monospaced())
                .foregroundStyle(Color.accentColor)
                .frame(width: badgeSize, height: badgeSize)
                .background(Color.accentColor.opacity(0.15), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                    .accessibilityLabel("Step \(number): \(title)")
                    .accessibilityAddTraits(.isHeader)
                detail
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let command {
                    HostSetupCommand(command: command, step: number)
                        .padding(.top, 4)
                }
            }
        }
    }
}

/// A command to run on the Host: tapping the text or Copy copies it, and
/// Share hands the same plain text to the system share sheet (Messages, Notes,
/// AirDrop, Mail) so it can reach a computer this phone is not paired with.
/// Nothing but the command text is shared. A Mac on the same Apple Account
/// pastes it through Universal Clipboard; the tip under it says so as a
/// bonus, since a Linux Host runs it too. Find Computers' pairing page shows
/// the same block, with no step number.
struct HostSetupCommand: View {
    let command: String
    var step: Int?
    /// Counts copies, so every tap gets its haptic and restarts the checkmark.
    @State private var copies = 0
    @State private var isCopied = false

    private var commandName: String {
        step.map { "Step \($0) Command" } ?? "Command"
    }

    private func copy() {
        UIPasteboard.general.string = command
        isCopied = true
        copies += 1
        AccessibilityNotification.Announcement("Copied").post()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 10) {
                // The text is a tap target for sighted users only: Copy below
                // is the one control VoiceOver offers, so it is not read twice.
                Button(action: copy) {
                    Text(command)
                        .font(Brand.Fonts.code)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        // A button label keeps one line; the whole command
                        // has to show.
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)
                HStack(spacing: 24) {
                    Button(action: copy) {
                        Label(
                            isCopied ? "Copied" : "Copy",
                            systemImage: isCopied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .hoverEffect(.highlight)
                    .accessibilityLabel(isCopied ? "Copied" : "Copy \(commandName)")
                    .accessibilityValue(command)
                    ShareLink(item: command) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.plain)
                    .hoverEffect(.highlight)
                    .accessibilityLabel("Share \(commandName)")
                    .accessibilityValue(command)
                    Spacer(minLength: 0)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.accentColor)
            }
            .padding(14)
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: .rect(cornerRadius: Brand.Radius.control))
            Label(
                "A Mac signed in to your Apple Account can paste it.",
                systemImage: "laptopcomputer.and.iphone")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sensoryFeedback(.success, trigger: copies)
        // The checkmark says what the pasteboard holds only for a moment:
        // copying something else replaces it.
        .task(id: copies) {
            guard copies > 0 else { return }
            do {
                try await Task.sleep(for: .seconds(1.5))
            } catch {
                return
            }
            isCopied = false
        }
    }
}

#Preview {
    HostSetupGuide(scan: {}, addManually: {}, showSettings: {})
}
