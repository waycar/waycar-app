import SwiftUI

/// Pushed destinations under Settings › About.
///
/// Each case is the route identity *and* the concrete view type the
/// `NavigationLink` constructs. Tests bind the identity to
/// `destinationTypeName` so a decoy `LabeledContent` (or any other view) cannot
/// keep the route green while unlinking `AcknowledgementsView` (#161 / #135)
/// or `ChangelogView`.
enum SettingsAboutDestination: String, Equatable, CaseIterable, Sendable {
    case changelog = "settings.about.changelog"
    case acknowledgements = "settings.about.acknowledgements"

    /// Metatype of the view this route constructs: `ChangelogView` for
    /// `.changelog`, `AcknowledgementsView` for `.acknowledgements`.
    var destinationTypeName: String {
        switch self {
        case .changelog:
            String(reflecting: ChangelogView.self)
        case .acknowledgements:
            String(reflecting: AcknowledgementsView.self)
        }
    }

    @MainActor
    @ViewBuilder
    var destinationView: some View {
        switch self {
        case .changelog:
            ChangelogView()
        case .acknowledgements:
            AcknowledgementsView()
        }
    }
}

/// Uses the same identity/metatype/destination convention as About routes.
enum SettingsAgentListDestination: String, Sendable {
    case fields = "settings.agentList.fields"

    var destinationTypeName: String { String(reflecting: AgentListFieldsSettingsView.self) }

    @MainActor
    func destinationView(console: ConsoleStore, hosts: [Host]) -> AgentListFieldsSettingsView {
        AgentListFieldsSettingsView(console: console, hosts: hosts)
    }
}

/// Settings › Toolbar, on the same identity/metatype convention.
enum SettingsToolbarsDestination: String, Sendable {
    case toolbars = "settings.toolbars"

    var destinationTypeName: String { String(reflecting: ToolbarsSettingsView.self) }

    @MainActor
    func destinationView(terminal: TerminalSettings) -> ToolbarsSettingsView {
        ToolbarsSettingsView(toolbars: terminal.toolbars, snippets: terminal.snippets)
    }
}

/// Settings › Agent Footer, on the same identity/metatype convention.
enum SettingsAgentFooterDestination: String, Sendable {
    case footer = "settings.agentFooter"

    var destinationTypeName: String { String(reflecting: AgentFooterSettingsView.self) }

    @MainActor
    func destinationView(terminal: TerminalSettings) -> AgentFooterSettingsView {
        AgentFooterSettingsView(store: terminal.footer)
    }
}

/// Settings › Help (#161), under the same identity/metatype/destination
/// convention as About routes. Unlike the other rows it is pushed by value:
/// Help pushes its pages by value, and a value pushed over a view-destination
/// link pops that link (and Help's query) off the stack.
enum SettingsHelpDestination: String, Hashable, CaseIterable, Sendable {
    case help = "settings.support.help"

    var destinationTypeName: String {
        switch self {
        case .help:
            String(reflecting: HelpView.self)
        }
    }

    @MainActor
    func destinationView() -> HelpView {
        switch self {
        case .help:
            HelpView()
        }
    }
}

/// The settings sheet root: a shallow menu into Agent fields, appearance, notifications and
/// CodexBar (AI Usage display).
/// Keeping it a menu means the per-Host notification rows can grow without
/// pushing the appearance controls out of reach, and vice versa.
struct SettingsView: View {
    let terminal: TerminalSettings
    let appearance: AppAppearanceSettings
    let pushRegistration: PushRegistrationStore
    let notificationPreferences: NotificationPreferencesStore
    let relaySettings: NotificationRelaySettings
    let agentSummaries: AgentSummarySettings
    let liveActivities: HostLiveActivityCoordinator
    let console: ConsoleStore
    let hosts: [Host]
    let aiUsage: AIUsageStore
    /// Nil in compositions without iCloud Sync (demo screenshots).
    var iCloudSync: ICloudSyncCoordinator?
    /// The Chat Prompt override. Compositions that don't pass one read and
    /// write the same defaults key; the editor re-reads it on appear.
    var chatMode = ChatModeSettings()

    nonisolated static let agentListDestination = SettingsAgentListDestination.fields
    nonisolated static let toolbarsDestination = SettingsToolbarsDestination.toolbars
    nonisolated static let agentFooterDestination = SettingsAgentFooterDestination.footer
    nonisolated static let chatModeDestination = SettingsChatModeDestination.chatMode
    nonisolated static let helpDestination = SettingsHelpDestination.help
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// iOS owns the icon choice, so this reads it back rather than taking an
    /// injected store.
    @State private var appIcon = AppIconSettings()
    /// The AI Summaries opt-in alert is up; the toggle stays off until "Turn On".
    @State private var confirmingAgentSummaries = false
    /// The app's share sheet (Settings › About › Share Waycar) is up.
    @State private var isSharingApp = false
    /// Nil in compositions without analytics (previews, demo screenshots).
    @Environment(\.analytics) private var analytics
    /// The CarPlay Voice pick, read here so the row follows a change.
    @AppStorage(CarVoiceSelection.voiceKey) private var carVoice = ""
    @AppStorage(NaturalVoiceSettings.enabledKey) private var naturalVoiceEnabled = false
    @AppStorage(NaturalVoiceSettings.activeModelKey) private var naturalVoiceModel = NaturalVoiceModelID.kokoro

    /// The voice the car speaks with now, by name: worked out when the pick
    /// changes, not on every body evaluation (ranking reads every voice).
    @State private var carVoiceName = "Default"

    /// Semantic identity of the About → Acknowledgements route.
    ///
    /// Equals `SettingsAboutDestination.acknowledgements.rawValue`. Tests assert
    /// the id, the destination mapping, and the source wiring together so a
    /// decoy row cannot stand in for the real screen (#161, same lesson as #135).
    nonisolated static let acknowledgementsRouteID = SettingsAboutDestination.acknowledgements.rawValue

    /// Semantic identity of the About → Changelog route, under the same
    /// convention as `acknowledgementsRouteID`.
    nonisolated static let changelogRouteID = SettingsAboutDestination.changelog.rawValue

    /// Rows in the About section, in display order. The body iterates this
    /// list; the Changelog and Acknowledgements entries are navigation
    /// destinations, not static labels, with ids `changelogRouteID` and
    /// `acknowledgementsRouteID`.
    /// `nonisolated`: pure, and called off the main actor (AGENTS.md, Conventions).
    nonisolated static var aboutRows: [AboutRow] {
        var rows: [AboutRow] = [.version, .changelog, .acknowledgements]
        if NotificationPrivacyCopy.privacyPolicyURL != nil {
            rows.append(.privacyPolicy)
        }
        if AppStoreListing.writeReviewURL != nil {
            rows.append(.rateWaycar)
        }
        if AppStoreListing.shareURL != nil {
            rows.append(.shareWaycar)
        }
        return rows
    }

    /// One About-section row. Enum cases are identity: a decoy string label is
    /// not `.acknowledgements` or `.changelog`.
    enum AboutRow: Equatable, Identifiable {
        case version
        case changelog
        case acknowledgements
        case privacyPolicy
        case rateWaycar
        case shareWaycar

        var id: String {
            switch self {
            case .version: "settings.about.version"
            case .changelog: SettingsView.changelogRouteID
            case .acknowledgements: SettingsView.acknowledgementsRouteID
            case .privacyPolicy: "settings.about.privacyPolicy"
            case .rateWaycar: "settings.about.rate"
            case .shareWaycar: "settings.about.share"
            }
        }
    }

    /// Maps an About row to a pushed destination, or `nil` for rows that do
    /// not navigate (version, external links). The Changelog and
    /// Acknowledgements `NavigationLink`s are built only through this mapping.
    /// `nonisolated`: pure, and called off the main actor (AGENTS.md, Conventions).
    nonisolated static func aboutDestination(for row: AboutRow) -> SettingsAboutDestination? {
        switch row {
        case .changelog:
            .changelog
        case .acknowledgements:
            .acknowledgements
        case .version, .privacyPolicy, .rateWaycar, .shareWaycar:
            nil
        }
    }

    /// Only the speaking voice's name: the active natural model's voice
    /// ("Heart") while Natural Voice is on and that model is installed, else
    /// the Apple voice ("Ava"). No model name, quality or speed.
    private func refreshCarVoiceName() {
        let voice: String
        if naturalVoiceEnabled, NaturalVoiceModel.isInstalled(naturalVoiceModel) {
            let info = NaturalVoiceCatalog.info(naturalVoiceModel)
            let selected = NaturalVoiceSettings.voice(for: naturalVoiceModel)
            voice = info.voices.first { $0.id == selected }?.name ?? selected
        } else {
            voice =
                CarVoiceSelection.choice(stored: carVoice, among: CarVoice.installed())?.name ?? "Default"
        }
        carVoiceName = CarVoiceSelection.rowText(voice: voice)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        Self.agentListDestination.destinationView(console: console, hosts: hosts)
                            .listSectionSpacing(.default)
                    } label: {
                        Label("Agent List Fields", systemImage: "list.bullet.rectangle")
                    }
                    .accessibilityIdentifier(Self.agentListDestination.rawValue)
                    NavigationLink {
                        Self.toolbarsDestination.destinationView(terminal: terminal)
                            .listSectionSpacing(.default)
                    } label: {
                        Label("Toolbar", systemImage: "keyboard.badge.ellipsis")
                    }
                    .accessibilityIdentifier(Self.toolbarsDestination.rawValue)
                    NavigationLink {
                        Self.agentFooterDestination.destinationView(terminal: terminal)
                    } label: {
                        Label("Agent Footer", systemImage: "rectangle.bottomthird.inset.filled")
                    }
                    .accessibilityIdentifier(Self.agentFooterDestination.rawValue)
                    NavigationLink {
                        Self.chatModeDestination.destinationView(
                            settings: chatMode, console: console, hosts: hosts)
                            .listSectionSpacing(.default)
                    } label: {
                        Label("Chat Mode", systemImage: "bubble.left.and.bubble.right")
                    }
                    .accessibilityIdentifier(Self.chatModeDestination.rawValue)
                    if CarPlaySupport.isAvailable {
                        NavigationLink {
                            CarVoiceSettingsView()
                                .listSectionSpacing(.default)
                        } label: {
                            HStack {
                                Label("CarPlay Voice", systemImage: "car")
                                Spacer()
                                Text(carVoiceName).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("settings.carPlayVoice")
                        .task(id: "\(carVoice)|\(naturalVoiceEnabled)|\(naturalVoiceModel.rawValue)") {
                            refreshCarVoiceName()
                        }
                        .onAppear(perform: refreshCarVoiceName)
                        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
                            refreshCarVoiceName()
                        }
                    }
                    NavigationLink {
                        NotificationSettingsView(
                            pushRegistration: pushRegistration,
                            notificationPreferences: notificationPreferences,
                            relaySettings: relaySettings,
                            agentSummaries: agentSummaries,
                            liveActivities: liveActivities)
                        .listSectionSpacing(.default)
                    } label: {
                        Label("Notifications", systemImage: "bell.badge")
                    }
                    appearancePicker
                    if appIcon.isSupported {
                        NavigationLink {
                            AppIconPickerView(settings: appIcon)
                                .listSectionSpacing(.default)
                        } label: {
                            Label {
                                Text("App Icon")
                            } icon: {
                                Image(appIcon.selection.previewImageName)
                                    .resizable()
                                    .scaledToFit()
                            }
                        }
                        .accessibilityIdentifier("settings.appIcon")
                    }
                    if let iCloudSync {
                        NavigationLink {
                            ICloudSyncSettingsView(sync: iCloudSync)
                                .listSectionSpacing(.default)
                        } label: {
                            Label("iCloud Sync", systemImage: "icloud")
                        }
                        .accessibilityIdentifier("settings.icloudSync")
                    }
                    NavigationLink {
                        TerminalAppearanceSettingsView(terminal: terminal)
                            .listSectionSpacing(.default)
                    } label: {
                        Label("Terminal Appearance", systemImage: "paintpalette")
                    }
                    NavigationLink {
                        AIUsageDisplaySettingsView(store: aiUsage)
                            .listSectionSpacing(.default)
                    } label: {
                        Label("CodexBar", systemImage: "gauge.with.dots.needle.33percent")
                    }
                    .accessibilityIdentifier("settings.codexBar")
                }

                // App-wide, off by default: it governs the Agent card lines
                // and each Host's `summary_enabled`, notifications or not.
                // Turning it on asks first; only "Turn On" stores true, and
                // "Not Now" stores false so the notifications ask is skipped.
                Section {
                    Toggle(
                        isOn: Binding(
                            get: { agentSummaries.isEnabled },
                            set: { enabled in
                                if enabled {
                                    confirmingAgentSummaries = true
                                } else {
                                    agentSummaries.setEnabled(false)
                                }
                            })
                    ) {
                        Label {
                            Text(NotificationPrivacyCopy.agentSummariesToggle)
                        } icon: {
                            Image(systemName: "text.quote").foregroundStyle(.secondary)
                        }
                    }
                    .agentSummariesConfirmation(
                        isPresented: $confirmingAgentSummaries, settings: agentSummaries)
                } footer: {
                    Text(NotificationPrivacyCopy.agentSummariesFooter)
                }

                // Per device, off until the user allows it on first launch:
                // usage counts tied to a random ID only.
                if let analytics {
                    Section {
                        Toggle(
                            isOn: Binding(
                                get: { analytics.isEnabled },
                                set: { analytics.setEnabled($0) })
                        ) {
                            Label {
                                Text(AppAnalytics.toggleTitle)
                            } icon: {
                                Image(systemName: "chart.bar").foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("settings.analytics")
                    } footer: {
                        Text(AppAnalytics.toggleFooter)
                    }
                }

                Section {
                    NavigationLink(value: Self.helpDestination) {
                        Label("Help", systemImage: "questionmark.circle")
                    }
                    .accessibilityIdentifier(Self.helpDestination.rawValue)
                    if let email = SupportLinks.email {
                        externalLinkRow("Email Support", systemImage: "envelope", destination: email)
                            .accessibilityIdentifier("settings.support.email")
                    }
                    if let community = SupportLinks.community {
                        externalLinkRow(
                            "Community on Reddit", systemImage: "bubble.left.and.bubble.right",
                            destination: community)
                            .accessibilityIdentifier("settings.support.community")
                    }
                } header: {
                    Text("Support")
                } footer: {
                    Text(SupportLinks.footer)
                }

                Section {
                    ForEach(Self.aboutRows) { row in
                        aboutRow(row)
                    }
                } header: {
                    Text("About")
                } footer: {
                    Text(
                        "A waycar is the crew car at the end of a train — the crew rode along "
                            + "and kept watch over the whole run from its cupola. Waycar keeps you "
                            + "riding along with your agents.")
                }

                #if DEBUG || WAYCAR_ADMIN
                if AppEnvironment.allowsAdmin, let reviewPrompt = console.reviewPrompt {
                    Section {
                        NavigationLink {
                            AdminSettingsView(reviewPrompt: reviewPrompt)
                                .listSectionSpacing(.default)
                        } label: {
                            Label("Admin", systemImage: "wrench.and.screwdriver")
                        }
                        .accessibilityIdentifier("settings.admin")
                    } footer: {
                        Text("Test builds only.")
                    }
                }
                #endif
            }
            // Row icons stay neutral gray; the accent is for a few controls only.
            .labelStyle(SettingsRowLabelStyle())
            // iPad's taller sheet fits the whole root list, footer included,
            // with compact spacing. Pushed screens get `.default` back (or
            // set their own) so this doesn't leak into them.
            .listSectionSpacing(horizontalSizeClass == .regular ? .compact : .default)
            .navigationDestination(for: SettingsHelpDestination.self) { destination in
                destination.destinationView()
                    .listSectionSpacing(.default)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        // Sheets don't take the app root's tint; Toggles default to green.
        .tint(Brand.Colors.accent)
    }

    @ViewBuilder
    private func aboutRow(_ row: AboutRow) -> some View {
        switch row {
        case .version:
            LabeledContent("Version", value: Self.versionString)
        case .changelog:
            // Destination comes only from `aboutDestination(for:)` so the
            // route identity and `ChangelogView` cannot drift apart.
            if let destination = Self.aboutDestination(for: row) {
                NavigationLink {
                    destination.destinationView
                } label: {
                    Label("Changelog", systemImage: "list.bullet.rectangle")
                }
                .accessibilityIdentifier(destination.rawValue)
            }
        case .acknowledgements:
            // Destination comes only from `aboutDestination(for:)` so the
            // route identity and `AcknowledgementsView` cannot drift apart.
            if let destination = Self.aboutDestination(for: row) {
                NavigationLink {
                    destination.destinationView
                        .listSectionSpacing(.default)
                } label: {
                    Label("Acknowledgements", systemImage: "doc.text")
                }
                .accessibilityIdentifier(destination.rawValue)
            }
        case .privacyPolicy:
            if let privacyURL = NotificationPrivacyCopy.privacyPolicyURL {
                externalLinkRow("Privacy Policy", systemImage: "hand.raised", destination: privacyURL)
            }
        case .rateWaycar:
            // Apple's own review page for the listing: a plain link, nothing
            // is offered or tracked for following it.
            if let reviewURL = AppStoreListing.writeReviewURL {
                externalLinkRow("Rate Waycar", systemImage: "star", destination: reviewURL)
                    .accessibilityIdentifier(row.id)
            }
        case .shareWaycar:
            // Sharing the app, nothing else: the link carries only App Store's
            // campaign tag, and no reward is offered or earned for it.
            if let shareURL = AppStoreListing.shareURL {
                Button {
                    // A deliberate share intent, counted once per tap of the
                    // row. The sheet's cancellation, recipients and anything
                    // after it are not observable here and are never reported.
                    analytics?.capture(.inviteShared)
                    isSharingApp = true
                } label: {
                    Label("Share Waycar", systemImage: "square.and.arrow.up")
                }
                .foregroundStyle(.primary)
                .accessibilityIdentifier(row.id)
                .sheet(isPresented: $isSharingApp) {
                    ShareSheet(items: [shareURL])
                }
            }
        }
    }

    /// A row that leaves the app (Safari, Mail): trailing arrow, not a chevron.
    private func externalLinkRow(
        _ title: LocalizedStringKey, systemImage: String, destination: URL
    ) -> some View {
        Link(destination: destination) {
            HStack {
                Label {
                    Text(title)
                } icon: {
                    Image(systemName: systemImage).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.forward.square")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(.primary)
    }

    /// The app's own light/dark override. A menu picker, not a pushed screen:
    /// three options do not earn a navigation level. Its value is gray like
    /// the row icons: the accent stays for the few controls that call for it.
    private var appearancePicker: some View {
        Picker(
            selection: Binding(
                get: { appearance.selection },
                set: { appearance.select($0) })
        ) {
            ForEach(AppAppearanceOption.allCases) { option in
                Text(option.title).tag(option)
            }
        } label: {
            Label {
                Text("Appearance")
            } icon: {
                Image(systemName: "circle.lefthalf.filled").foregroundStyle(.secondary)
            }
        }
        .tint(Color.secondary)
    }

    /// "0.1.0 (1)": marketing version plus build number, the pair App Store
    /// Connect and TestFlight feedback identify a build by.
    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(version) (\($0))" } ?? version
    }
}

/// A settings row label whose icon is the secondary gray rather than the tint.
private struct SettingsRowLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        Label {
            configuration.title
        } icon: {
            configuration.icon.foregroundStyle(.secondary)
        }
    }
}

/// The system share sheet around the campaign-tagged App Store link. The
/// row's tap already counted the share intent, so this presents plain
/// `UIActivityViewController` and reports nothing itself. On iPad it presents
/// as a sheet, so no popover anchor is needed.
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Settings › Support destinations, also named on waycar.dev/support.
enum SupportLinks {
    static let email = URL(string: "mailto:support@waycar.dev")
    static let community = URL(string: "https://www.reddit.com/r/waycar/")
    static let footer =
        "Email for one-on-one help, or join r/waycar for discussion, bugs, and feature requests."
}
