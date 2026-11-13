import SwiftUI

extension EnvironmentValues {
    @Entry var sampleConnect: (() -> Void)? = nil
    @Entry var dismissSample: (() -> Void)? = nil
}

/// Labels the production Console and its sheets while they show fictional data.
///
/// The label stacks above the content rather than in a top safe-area inset:
/// UIKit lays out a navigation bar, and the Agent screen its Back row, from
/// the window's top, so an inset drew the label over a sheet's Done and an
/// Agent's Back. Below the label, the content's own top chrome stays visible.
struct SampleContextModifier: ViewModifier {
    var showsActions = false
    @Environment(\.sampleConnect) private var connect
    @Environment(\.dismissSample) private var dismiss

    func body(content: Content) -> some View {
        if let connect {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sample")
                            .font(.headline)
                        Text("Not a live computer")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: 0)
                    if showsActions {
                        Button("Connect", action: connect)
                            .font(.subheadline.weight(.semibold))
                            .accessibilityLabel("Connect your machine")
                        if let dismiss {
                            Button(action: dismiss) {
                                Image(systemName: "xmark")
                                    .padding(12)
                                    .contentShape(.rect)
                            }
                            .accessibilityLabel("Close sample")
                        }
                    }
                }
                .padding(.leading, 16)
                .padding(.trailing, 4)
                .padding(.vertical, 8)
                .background(.bar)
                .overlay(alignment: .bottom) { Divider() }
                content
            }
        } else {
            content
        }
    }
}

/// A presentation-only composition. Its Console never enters WaycarAppModel.
struct SampleConsoleView: View {
    let session: SampleSession
    let appearance: AppAppearanceSettings
    let pushRegistration: PushRegistrationStore
    let notificationPreferences: NotificationPreferencesStore
    let relaySettings: NotificationRelaySettings
    let liveActivities: HostLiveActivityCoordinator
    let activity: AppActivityCoordinator
    let close: () -> Void
    let addHost: (HostAddition) -> Void
    @State private var router = AgentNotificationRouter()
    @State private var isShowingConnect = false
    @State private var terminal: TerminalSettings
    @State private var chatMode: ChatModeSettings

    init(
        session: SampleSession,
        appearance: AppAppearanceSettings,
        pushRegistration: PushRegistrationStore,
        notificationPreferences: NotificationPreferencesStore,
        relaySettings: NotificationRelaySettings,
        liveActivities: HostLiveActivityCoordinator,
        activity: AppActivityCoordinator,
        close: @escaping () -> Void,
        addHost: @escaping (HostAddition) -> Void
    ) {
        self.session = session
        self.appearance = appearance
        self.pushRegistration = pushRegistration
        self.notificationPreferences = notificationPreferences
        self.relaySettings = relaySettings
        self.liveActivities = liveActivities
        self.activity = activity
        self.close = close
        self.addHost = addHost
        let defaults = session.defaults
        _terminal = State(initialValue: TerminalSettings(
            themes: TerminalThemeSettings(defaults: defaults),
            zoom: TerminalZoomSettings(defaults: defaults),
            fonts: TerminalFontSettings(defaults: defaults),
            snippets: SnippetStore(defaults: defaults),
            toolbars: AgentToolbarLayoutStore(defaults: defaults),
            edgeDock: EdgeDockSettings(defaults: defaults),
            backButton: AgentBackButtonSettings(defaults: defaults),
            footer: AgentFooterLayoutStore(defaults: defaults)))
        _chatMode = State(initialValue: ChatModeSettings(defaults: defaults))
    }

    var body: some View {
        ConsoleView(
            hosts: session.hostStore,
            console: session.console,
            terminal: terminal,
            appearance: appearance,
            pushRegistration: pushRegistration,
            notificationPreferences: notificationPreferences,
            relaySettings: relaySettings,
            agentSummaries: session.agentSummaries,
            chatModeSettings: chatMode,
            notificationRouter: router,
            bannerStore: session.bannerStore,
            liveActivities: liveActivities,
            activity: activity,
            aiUsage: session.aiUsage,
            sampleConnect: { isShowingConnect = true })
        .modifier(SampleContextModifier(showsActions: true))
        .sheet(isPresented: $isShowingConnect) {
            NavigationStack {
                HostSetupGuide(
                    scan: { addHost(.scan) },
                    addManually: { addHost(.manual) },
                    title: "Connect your machine")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { isShowingConnect = false }
                    }
                }
            }
            .modifier(SampleContextModifier())
        }
        .defaultAppStorage(session.defaults)
        .environment(\.sampleConnect, { isShowingConnect = true })
        .environment(\.dismissSample, close)
        .environment(\.analytics, nil)
        .environment(\.agentSceneRouting, nil)
        .environment(\.agentLastFrames, nil)
        .task { await session.start() }
        .onChange(of: session.console.agents, initial: true) {
            router.agentsDidChange(session.console.agents)
        }
    }
}
