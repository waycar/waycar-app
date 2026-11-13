#if DEBUG && targetEnvironment(simulator)
    import Foundation
    import SwiftUI
    import UIKit
    import UserNotifications

    /// The only entry point for deterministic product screenshots. The
    /// entire implementation is excluded from device and Release builds.
    enum DemoScreenshotMode {
        static let launchArgument = "--demo-screenshots"

        static var isEnabled: Bool {
            isEnabled(arguments: ProcessInfo.processInfo.arguments)
        }

        static func isEnabled(arguments: [String]) -> Bool {
            arguments.contains(launchArgument)
        }

        /// Opens the Studio Mac's Chat Mode Agent at launch, Blocked on its
        /// open turn's permission prompt, for the `chat` screenshot. It counts
        /// only alongside `launchArgument`; without it that Agent stays
        /// Working and nothing opens at launch:
        ///
        ///     xcrun simctl launch <udid> com.otreva.waycar --demo-screenshots --demo-chat-mode
        static let chatModeLaunchArgument = "--demo-chat-mode"

        static var isChatModeEnabled: Bool {
            isChatModeEnabled(arguments: ProcessInfo.processInfo.arguments)
        }

        static func isChatModeEnabled(arguments: [String]) -> Bool {
            isEnabled(arguments: arguments) && arguments.contains(chatModeLaunchArgument)
        }

        /// With `chatModeLaunchArgument`, gives the Chat Mode Agent a long
        /// history (hundreds of messages) ahead of its usual exchanges, for
        /// checking how a long chat opens and scrolls:
        ///
        ///     xcrun simctl launch <udid> com.otreva.waycar --demo-screenshots --demo-chat-mode --demo-long-chat
        static let longChatLaunchArgument = "--demo-long-chat"

        static var isLongChatEnabled: Bool {
            let arguments = ProcessInfo.processInfo.arguments
            return isChatModeEnabled(arguments: arguments) && arguments.contains(longChatLaunchArgument)
        }

        /// Opens the Dev Workstation's Ultimate leader chat at launch, mid
        /// run, with a transcript that exercises every Hybrid piece: cards,
        /// the working pill, the Stop composer and the iPad branch rail. It
        /// counts only alongside `launchArgument`:
        ///
        ///     xcrun simctl launch <udid> com.otreva.waycar --demo-screenshots --demo-ultimate-chat
        static let ultimateChatLaunchArgument = "--demo-ultimate-chat"

        static var isUltimateChatEnabled: Bool {
            isUltimateChatEnabled(arguments: ProcessInfo.processInfo.arguments)
        }

        static func isUltimateChatEnabled(arguments: [String]) -> Bool {
            isEnabled(arguments: arguments) && arguments.contains(ultimateChatLaunchArgument)
        }

        /// Opens the Build Server's Checkout Agent at launch, Blocked as in
        /// the `agent` screenshot, and starts Dictate to Agent once its
        /// terminal is on stage, listening to `DemoDictationEngine`'s
        /// scripted voice, for the `dictation` screenshot and the waycar.dev
        /// hero (`scripts/record-dictation-hero.sh`). It counts only
        /// alongside `launchArgument`; with `chatModeLaunchArgument` too, the
        /// Chat Mode Agent opens at launch instead:
        ///
        ///     xcrun simctl launch <udid> com.otreva.waycar --demo-screenshots --demo-dictation
        static let dictationLaunchArgument = "--demo-dictation"

        static var isDictationEnabled: Bool {
            isDictationEnabled(arguments: ProcessInfo.processInfo.arguments)
        }

        static func isDictationEnabled(arguments: [String]) -> Bool {
            isEnabled(arguments: arguments) && arguments.contains(dictationLaunchArgument)
        }

        /// Set once `--demo-dictation` has started Dictate to Agent, so it
        /// starts at most once per launch however often the Checkout Agent's
        /// terminal appears.
        @MainActor static var didStartDictation = false

        /// Holds every demo attach's first paint back by this many seconds,
        /// so the Ignition loader (#96) can be recorded without a Host:
        ///
        ///     xcrun simctl launch <udid> com.otreva.waycar --demo-screenshots --demo-attach-delay 2.5
        static let attachDelayLaunchArgument = "--demo-attach-delay"

        static var attachDelay: Duration {
            let arguments = ProcessInfo.processInfo.arguments
            guard isEnabled(arguments: arguments),
                let index = arguments.firstIndex(of: attachDelayLaunchArgument),
                arguments.indices.contains(index + 1),
                let seconds = Double(arguments[index + 1]), seconds > 0
            else { return .zero }
            // A minute is plenty to record; anything larger (or `inf`)
            // would trap converting to milliseconds.
            return .milliseconds(Int(min(seconds, 60) * 1000))
        }

        /// Treats every trip to the Home Screen and back as a return after
        /// suspension: the demo forwards scene phase to its activity
        /// coordinator with no grace period, so the Console tears its
        /// connections down and the Agent screen reattaches over its kept
        /// frame (#21), the warm Ignition loader (#96):
        ///
        ///     xcrun simctl launch <udid> com.otreva.waycar --demo-screenshots --demo-attach-delay 2.5 --demo-reconnect-on-foreground
        static let reconnectOnForegroundLaunchArgument = "--demo-reconnect-on-foreground"

        static var reconnectsOnForeground: Bool {
            let arguments = ProcessInfo.processInfo.arguments
            return isEnabled(arguments: arguments)
                && arguments.contains(reconnectOnForegroundLaunchArgument)
        }

        /// Takes the Build Server offline for 90 seconds, its rows and
        /// Agent kinds as last seen two hours ago, and lists an earlier Queued
        /// Launch on each Host that needs the user: a failed one on the Studio
        /// Mac and an interrupted one on the Build Server. New Agent on the
        /// Build Server then queues (CONTEXT.md **Queued Launch**), and the
        /// launch starts once the Build Server's next reconnect lands:
        ///
        ///     xcrun simctl launch <udid> com.otreva.waycar --demo-screenshots --demo-queued-launches
        static let queuedLaunchesLaunchArgument = "--demo-queued-launches"

        static var isQueuedLaunchesEnabled: Bool {
            let arguments = ProcessInfo.processInfo.arguments
            return isEnabled(arguments: arguments) && arguments.contains(queuedLaunchesLaunchArgument)
        }
    }

    /// A safe composition root for screenshot runs. It reuses the production
    /// Console, EventsSession, Transport, and terminal surfaces while keeping
    /// Hosts, secrets, settings, notifications, and SSH fully process-local.
    @MainActor
    struct DemoScreenshotRootView: View {
        @State private var hosts: HostStore
        @State private var console: ConsoleStore
        @State private var terminalThemes: TerminalThemeSettings
        @State private var terminalZoom: TerminalZoomSettings
        @State private var terminalFonts: TerminalFontSettings
        @State private var snippets: SnippetStore
        @State private var toolbars: AgentToolbarLayoutStore
        @State private var footer: AgentFooterLayoutStore
        @State private var backButton: AgentBackButtonSettings
        @State private var appearance: AppAppearanceSettings
        @State private var pushRegistration: PushRegistrationStore
        @State private var notificationPreferences: NotificationPreferencesStore
        @State private var relaySettings: NotificationRelaySettings
        @State private var agentSummaries: AgentSummarySettings
        @State private var chatModeSettings: ChatModeSettings
        @State private var notificationRouter: AgentNotificationRouter
        @State private var bannerStore: AgentNotificationBannerStore
        @State private var liveActivities: HostLiveActivityCoordinator
        @State private var activity: AppActivityCoordinator
        @State private var aiUsage: AIUsageStore
        @Environment(\.scenePhase) private var scenePhase

        init() {
            // The watch bridge's own, when it runs, so both see one Console.
            let composition =
                DemoScreenshotMode.isWatchBridgeEnabled
                ? DemoWatchBridge.composition : DemoScreenshotComposition.make()
            _hosts = State(initialValue: composition.hosts)
            _console = State(initialValue: composition.console)
            _terminalThemes = State(initialValue: composition.terminalThemes)
            _terminalZoom = State(initialValue: composition.terminalZoom)
            _terminalFonts = State(initialValue: composition.terminalFonts)
            _snippets = State(initialValue: composition.snippets)
            _toolbars = State(initialValue: composition.toolbars)
            _footer = State(initialValue: composition.footer)
            _backButton = State(initialValue: composition.backButton)
            _appearance = State(initialValue: composition.appearance)
            _pushRegistration = State(initialValue: composition.pushRegistration)
            _notificationPreferences = State(initialValue: composition.notificationPreferences)
            _relaySettings = State(initialValue: composition.relaySettings)
            _agentSummaries = State(initialValue: composition.agentSummaries)
            _chatModeSettings = State(initialValue: composition.chatModeSettings)
            _notificationRouter = State(initialValue: composition.notificationRouter)
            _bannerStore = State(initialValue: composition.bannerStore)
            _liveActivities = State(initialValue: composition.liveActivities)
            _activity = State(initialValue: composition.activity)
            _aiUsage = State(initialValue: composition.aiUsage)
        }

        private var terminal: TerminalSettings {
            TerminalSettings(
                themes: terminalThemes, zoom: terminalZoom, fonts: terminalFonts,
                snippets: snippets, toolbars: toolbars, backButton: backButton, footer: footer)
        }

        var body: some View {
            ConsoleView(
                hosts: hosts,
                console: console,
                terminal: terminal,
                appearance: appearance,
                pushRegistration: pushRegistration,
                notificationPreferences: notificationPreferences,
                relaySettings: relaySettings,
                agentSummaries: agentSummaries,
                chatModeSettings: chatModeSettings,
                notificationRouter: notificationRouter,
                bannerStore: bannerStore,
                liveActivities: liveActivities,
                activity: activity,
                aiUsage: aiUsage
            )
            .preferredColorScheme(appearance.preferredColorScheme)
            .task {
                console.setHosts(hosts.hosts)
                notificationPreferences.setHosts(hosts.hosts)
                aiUsage.setHosts(hosts.hosts)
                await console.resume()
                // The app's own `ConsoleActivityDriver`, which the demo
                // otherwise leaves out.
                if DemoScreenshotMode.reconnectsOnForeground {
                    await ConsoleActivityDriver(activity: activity, console: console).run()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                guard DemoScreenshotMode.reconnectsOnForeground else { return }
                switch phase {
                case .active: activity.didBecomeActive(.phone)
                case .background: activity.didEnterBackground(.phone)
                default: break
                }
            }
            .onChange(of: console.hostStatuses) { aiUsage.connectionsDidChange() }
        }
    }

    @MainActor
    struct DemoScreenshotComposition {
        let hosts: HostStore
        let console: ConsoleStore
        let terminalThemes: TerminalThemeSettings
        let terminalZoom: TerminalZoomSettings
        let terminalFonts: TerminalFontSettings
        let snippets: SnippetStore
        let toolbars: AgentToolbarLayoutStore
        let footer: AgentFooterLayoutStore
        let backButton: AgentBackButtonSettings
        let appearance: AppAppearanceSettings
        let pushRegistration: PushRegistrationStore
        let notificationPreferences: NotificationPreferencesStore
        let relaySettings: NotificationRelaySettings
        let agentSummaries: AgentSummarySettings
        let chatModeSettings: ChatModeSettings
        let notificationRouter: AgentNotificationRouter
        let bannerStore: AgentNotificationBannerStore
        let liveActivities: HostLiveActivityCoordinator
        let activity: AppActivityCoordinator
        let aiUsage: AIUsageStore

        static func make() -> DemoScreenshotComposition {
            let defaults = DemoScreenshotFixture.makeDefaults()
            // The Console shows summary lines, so Settings shows them turned on.
            defaults.set(true, forKey: AgentSummarySettings.defaultsKey)
            let opensChat = DemoScreenshotMode.isChatModeEnabled
            let console = DemoScreenshotFixture.makeConsoleStore(opensChat: opensChat)
            let pushRegistration = PushRegistrationStore(client: DemoPushRegistrationClient())
            let relaySettings = NotificationRelaySettings(defaults: defaults)
            let notificationRouter = AgentNotificationRouter()
            if DemoScreenshotMode.isUltimateChatEnabled {
                // The Ultimate leader chat, the same restored-route way.
                notificationRouter.path = [DemoScreenshotFixture.ultimateAgentID]
            } else if opensChat {
                // Placed on the path directly, like a restored window's route:
                // the detail shows the Host connecting until the row arrives.
                notificationRouter.path = [DemoScreenshotFixture.chatAgentID]
            } else if DemoScreenshotMode.isDictationEnabled {
                // The same restored route, for Dictate to Agent to start on.
                notificationRouter.path = [DemoScreenshotFixture.checkoutAgentID]
            }
            let notificationPreferences = NotificationPreferencesStore(
                transports: console,
                deviceToken: { nil },
                relayBaseURL: { nil })
            // Every demo Host has CodexBar; keep them all on, as the
            // screenshots have always shown, instead of letting probe order
            // decide which one defaults to on.
            let aiUsagePreferences = AIUsagePreferences(defaults: defaults)
            for host in DemoScreenshotFixture.hosts {
                aiUsagePreferences.update(AIUsageHostSettings(enabledChoice: true), for: host.id)
            }
            return DemoScreenshotComposition(
                hosts: HostStore(volatileHosts: DemoScreenshotFixture.activeHosts),
                console: console,
                terminalThemes: TerminalThemeSettings(defaults: defaults),
                terminalZoom: TerminalZoomSettings(defaults: defaults),
                terminalFonts: TerminalFontSettings(defaults: defaults),
                snippets: SnippetStore(defaults: defaults),
                toolbars: AgentToolbarLayoutStore(defaults: defaults, idiom: .current),
                footer: AgentFooterLayoutStore(defaults: defaults, idiom: .current),
                backButton: AgentBackButtonSettings(defaults: defaults),
                appearance: AppAppearanceSettings(defaults: defaults),
                pushRegistration: pushRegistration,
                notificationPreferences: notificationPreferences,
                relaySettings: relaySettings,
                agentSummaries: AgentSummarySettings(defaults: defaults),
                chatModeSettings: ChatModeSettings(defaults: defaults),
                notificationRouter: notificationRouter,
                bannerStore: AgentNotificationBannerStore(
                    presentedAgent: { notificationRouter.path.last },
                    triggers: { _ in nil },
                    playSound: {}),
                liveActivities: HostLiveActivityCoordinator(
                    controller: ActivityKitLiveActivityController(),
                    preferences: LiveActivityPreferences(defaults: defaults),
                    transports: console,
                    deviceToken: { nil },
                    knownHostIDs: { Set(DemoScreenshotFixture.activeHosts.map(\.id)) },
                    hostDisplayName: { id in
                        DemoScreenshotFixture.activeHosts.first(where: { $0.id == id })?.displayName
                            ?? ""
                    },
                    isAwaitingSnapshot: { _ in false },
                    connectionStatus: { _ in .connected }),
                activity: AppActivityCoordinator(
                    gracePeriod: DemoScreenshotMode.reconnectsOnForeground
                        ? .zero : AppActivityCoordinator.defaultGracePeriod),
                aiUsage: AIUsageStore(
                    preferences: aiUsagePreferences,
                    transports: console,
                    connectionStatus: { console.hostStatuses[$0] },
                    connectionGeneration: { console.hostConnectionGenerations[$0] }))
        }
    }

    enum DemoScreenshotFixture {
        static let studioHostID = UUID(
            uuid: (
                0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x41, 0x11,
                0x81, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11
            ))
        static let buildHostID = UUID(
            uuid: (
                0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x42, 0x22,
                0x82, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22
            ))

        static let hosts = [
            Host(
                id: studioHostID,
                name: "Studio Mac",
                address: "studio.demo.invalid",
                username: "developer"),
            Host(
                id: buildHostID,
                name: "Build Server",
                address: "build.demo.invalid",
                username: "builder"),
        ]

        /// The Hosts this run shows: the usual two, plus the Ultimate Dev
        /// Workstation only under `--demo-ultimate-chat`, so every other
        /// screenshot keeps its catalog.
        static var activeHosts: [Host] {
            DemoScreenshotMode.isUltimateChatEnabled ? hosts + [ultimateHost] : hosts
        }

        /// The demo Hosts under `--demo-screenshots`. The Studio Mac's Chat
        /// Mode Agent is Working, which keeps it out of Needs Attention; the
        /// Chat chip counts it either way.
        static let profiles = hostProfiles(chatAgentStatus: .working)

        /// `profiles` with the Chat Mode Agent Blocked on its open turn's
        /// permission prompt, so its chat ends in Allow, Cancel and Show
        /// Terminal (`--demo-chat-mode`).
        static let chatModeProfiles = hostProfiles(chatAgentStatus: .blocked)

        /// The Chat Mode Agent: a claude pane in the Studio Mac's iOS App
        /// workspace, mid-turn.
        static let chatAgentPaneID = "mobile:p5"
        static let chatAgentID = ConsoleAgent.ID(hostID: studioHostID, paneID: chatAgentPaneID)

        /// The Checkout Agent: an omp pane in the Build Server's Checkout
        /// workspace, Blocked on approval. `--demo-dictation` opens it.
        static let checkoutAgentPaneID = "checkout:p3"
        static let checkoutAgentID = ConsoleAgent.ID(hostID: buildHostID, paneID: checkoutAgentPaneID)

        /// The greeting the demo chat opens with, every run.
        static let chatGreeting = ChatGreeting.anytime[0]

        // MARK: Ultimate Hybrid chat (`--demo-ultimate-chat`)

        static let ultimateHostID = UUID(
            uuid: (
                0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x43, 0x33,
                0x83, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33
            ))

        static let ultimateHost = Host(
            id: ultimateHostID,
            name: "Dev Workstation",
            address: "ultimate.demo.invalid",
            username: "developer")

        /// The detection answer for the Dev Workstation: Ultimate only.
        static let ultimatePresence = HostBackendPresence(
            herdr: false, tmuxVersion: nil,
            ultimate: [
                UltimateInstance(
                    id: "waycar-demo", home: "/Users/developer/.ultimate/projects/waycar-demo",
                    project: "/workspace/waycar", name: "waycar", pid: 1, port: 4748)
            ])

        /// Pane ids in the Ultimate builder's shape:
        /// `ultimate:<instance>:<conversation>`.
        static let ultimateWorkspaceID = "ultimate:waycar-demo"
        static let ultimateLeaderConversation = 16432
        static let ultimateLeaderPaneID = "\(ultimateWorkspaceID):\(ultimateLeaderConversation)"
        static let ultimateAgentID = ConsoleAgent.ID(
            hostID: ultimateHostID, paneID: ultimateLeaderPaneID)

        /// The leader's branches, as the rail and the leader card fold them:
        /// one working, one finished, one waiting on an answer.
        static let ultimateChildren = [
            UltimateChildInfo(
                conversationId: 16968, paneID: "\(ultimateWorkspaceID):16968",
                name: "Transport: leader/child model", busy: true),
            UltimateChildInfo(
                conversationId: 17176, paneID: "\(ultimateWorkspaceID):17176",
                name: "Mockups: session screen", busy: false),
            UltimateChildInfo(
                conversationId: 18020, paneID: "\(ultimateWorkspaceID):18020",
                name: "Nightly contract run", busy: false, openQuestions: 1),
        ]

        /// The Dev Workstation: one Ultimate leader row, Working, whose
        /// transcript exercises every Hybrid piece (cards, pill, Stop).
        static func ultimateProfile(now: Date) -> DemoHostProfile {
            DemoHostProfile(
                snapshot: snapshot(
                    agents: [
                        AgentInfo(
                            agentStatus: .working, focused: false,
                            paneID: ultimateLeaderPaneID, revision: 0,
                            tabID: ultimateLeaderPaneID, terminalID: ultimateLeaderPaneID,
                            workspaceID: ultimateWorkspaceID, agent: "ultimate",
                            cwd: "/workspace/waycar", interactiveReady: true,
                            launchPending: false, name: "@ultimate",
                            terminalTitle: "waycar")
                    ],
                    workspaces: [
                        WorkspaceInfo(
                            activeTabID: ultimateLeaderPaneID, agentStatus: .working,
                            focused: false, label: "waycar", number: 1, paneCount: 1,
                            tabCount: 1, workspaceID: ultimateWorkspaceID)
                    ]),
                summaries: [
                    summary(
                        paneID: ultimateLeaderPaneID, status: .working, minutesAgo: 1,
                        text: "Folding branches into one leader card and hiding concluded "
                            + "subtrees behind it")
                ],
                chatTranscripts: [ultimateLeaderPaneID: ultimateTranscript(now: now)],
                ultimateChildren: [ultimateLeaderPaneID: ultimateChildren],
                ultimateQuestions: [ultimateLeaderPaneID: 1],
                resourceUsage: HostResourceUsage(cpu: 0.22, memory: 0.48, swap: nil))
        }

        /// Every Hybrid entry once, oldest first: a compaction divider, a
        /// user bubble, collapsed tool steps, a full-width markdown reply,
        /// two branch pointers, a two-question card and a failure card. The
        /// turn stays open so the working pill and Stop composer show.
        private static func ultimateTranscript(now: Date) -> ChatTranscriptSnapshot {
            func entry(
                _ id: String, _ role: ChatTranscriptMessage.Role, minutesAgo: Int,
                _ text: String = "", card: ChatTranscriptCard? = nil
            ) -> ChatTranscriptMessage {
                ChatTranscriptMessage(
                    id: id, role: role, text: text,
                    timestamp: now.addingTimeInterval(TimeInterval(-minutesAgo * 60)),
                    card: card)
            }
            let questions = ChatQuestionCard(
                body: "",
                questions: [
                    ChatQuestion(
                        ref: "1", text: "Where should the children's metadata live?",
                        kind: "choice",
                        options: [
                            ChatQuestionOption(
                                key: "a", label: "Generator customization",
                                detail: "Optional Ultimate children field in the wire types",
                                recommended: true),
                            ChatQuestionOption(
                                key: "b", label: "Namespaced label",
                                detail: "Children JSON in stateLabels; no generated changes",
                                recommended: false),
                        ]),
                    ChatQuestion(
                        ref: "2", text: "Keep concluded branches hidden by default?",
                        kind: "choice",
                        options: [
                            ChatQuestionOption(
                                key: "a", label: "Hide them",
                                detail: "A count in the rail footer", recommended: false),
                            ChatQuestionOption(
                                key: "b", label: "Show them greyed out",
                                detail: nil, recommended: false),
                        ]),
                ])
            return ChatTranscriptSnapshot(
                header: ChatTranscriptHeader(
                    kind: "ultimate", status: .ok, transcript: nil,
                    activity: "Pinning the history scenario in ultimate-contract.py",
                    turnOpen: true, truncated: false, error: nil),
                messages: [
                    entry(
                        "demo-ult-1", .assistant, minutesAgo: 34,
                        card: .divider(kind: "pi.compaction", label: "Context compacted")),
                    entry(
                        "demo-ult-2", .user, minutesAgo: 32,
                        "Fold branches into one leader card on the Console, and hide "
                            + "concluded ones."),
                    entry(
                        "demo-ult-3", .assistant, minutesAgo: 30,
                        card: .toolSteps(ChatToolStepsSummary(
                            count: 6, summary: "rg, read ×3, edit ×2"))),
                    entry(
                        "demo-ult-4", .assistant, minutesAgo: 29,
                        "Plan: one `@ultimate` card per project; branches fold into it. "
                            + "I started two branches — tap one to open its chat."),
                    entry(
                        "demo-ult-5", .assistant, minutesAgo: 28,
                        card: .branch(ChatBranchPointer(
                            conversationId: 16968, title: "Transport: leader/child model",
                            at: now.addingTimeInterval(-4 * 60)))),
                    entry(
                        "demo-ult-6", .assistant, minutesAgo: 27,
                        card: .branch(ChatBranchPointer(
                            conversationId: 17176, title: "Mockups: session screen",
                            at: now.addingTimeInterval(-12 * 60)))),
                    entry(
                        "demo-ult-7", .assistant, minutesAgo: 20,
                        card: .questions(questions)),
                    entry(
                        "demo-ult-8", .assistant, minutesAgo: 6,
                        card: .failure(ChatFailureCard(
                            conversationId: 18020, title: "Nightly contract run failed",
                            error: "ultimate-contract.py: history scenario pin mismatch",
                            step: "pin branchOf"))),
                ])
        }

        private static func hostProfiles(
            chatAgentStatus: AgentStatus
        ) -> [Host.ID: DemoHostProfile] {
            let now = Date()
            let chatCWD = "/workspace/waycar"
            let chatBlocked = chatAgentStatus == .blocked
            return [
                studioHostID: DemoHostProfile(
                    snapshot: snapshot(
                        agents: [
                            agent(
                                paneID: "mobile:p1", status: .working,
                                workspaceID: "mobile", kind: "codex",
                                name: "ios-polish", title: "Polish the Attach experience",
                                cwd: "/workspace/waycar"),
                            agent(
                                paneID: "docs:p2", status: .idle,
                                workspaceID: "docs", kind: "claude",
                                name: "docs-review", title: "Refresh the setup guide",
                                cwd: "/workspace/product-docs"),
                            agent(
                                paneID: "mobile:p4", status: .done,
                                workspaceID: "mobile", kind: "gemini",
                                name: "accessibility", title: "Audit VoiceOver labels",
                                cwd: "/workspace/waycar"),
                            agent(
                                paneID: chatAgentPaneID, status: chatAgentStatus,
                                workspaceID: "mobile", kind: "claude",
                                name: "reconnect-fix", title: "Fix the flaky reconnect test",
                                cwd: chatCWD),
                        ],
                        workspaces: [
                            workspace(
                                id: "mobile", label: "iOS App", repo: "waycar",
                                isLinkedWorktree: true),
                            workspace(id: "docs", label: "Product Docs", repo: "docs-site"),
                        ]),
                    summaries: [
                        // Just started: the phase stands in for steps.
                        summary(
                            paneID: "mobile:p1", status: .working, minutesAgo: 1,
                            text: "Reading the Attach reconnect code before smoothing the "
                                + "scroll position",
                            progress: AgentProgress(steps: nil, phase: .exploring)),
                        summary(
                            paneID: "docs:p2", status: .idle, minutesAgo: 1,
                            text: "Idle after updating the setup guide’s SSH section; waiting "
                                + "for your next prompt"),
                        // Written while the Agent was still working: stale now it is Done.
                        summary(
                            paneID: "mobile:p4", status: .working, minutesAgo: 2,
                            text: "Finished the VoiceOver audit: fixed 14 missing labels across "
                                + "Settings and the composer"),
                        // No estimate: Working draws the dotted rail; Blocked draws none.
                        chatBlocked
                            ? summary(
                                paneID: chatAgentPaneID, status: .blocked, minutesAgo: 1,
                                text: "Waiting for approval to run the full test suite on the "
                                    + "iPad simulator")
                            : summary(
                                paneID: chatAgentPaneID, status: .working, minutesAgo: 1,
                                text: "Running the full test suite on the iPad simulator after "
                                    + "fixing the reconnect race"),
                    ],
                    chatMarkers: [
                        ChatModeMarker(
                            paneID: chatAgentPaneID, terminalID: "terminal:\(chatAgentPaneID)",
                            kind: "claude", cwd: chatCWD,
                            session: ChatModeMarker.Session(
                                kind: "id", value: "5c1d7e2a-8f3b-4a6e-9d20-7b4e1f0c9a31"),
                            launchedAt: chatLaunch(near: now))
                    ],
                    chatTranscripts: [chatAgentPaneID: chatTranscript(now: now)],
                    screens: chatBlocked ? [chatAgentPaneID: chatPermissionPrompt] : [:],
                    resourceUsage: HostResourceUsage(cpu: 0.18, memory: 0.64, swap: nil)),
                buildHostID: DemoHostProfile(
                    snapshot: snapshot(
                        agents: [
                            agent(
                                paneID: checkoutAgentPaneID, status: .blocked,
                                workspaceID: "checkout", kind: "omp",
                                name: "reviewer", title: "Checkout review",
                                cwd: "/workspace/storefront"),
                            agent(
                                paneID: "api:p7", status: .working,
                                workspaceID: "api", kind: "opencode",
                                name: "api-tests", title: "Harden webhook retries",
                                cwd: "/workspace/payments-api"),
                        ],
                        workspaces: [
                            workspace(id: "checkout", label: "Checkout", repo: "storefront"),
                            workspace(id: "api", label: "Payments API", repo: "payments-api"),
                        ]),
                    summaries: [
                        // Blocked mid-plan: the rail holds at 3/6, in blue.
                        summary(
                            paneID: checkoutAgentPaneID, status: .blocked, minutesAgo: 1,
                            text: "Waiting for approval to run the checkout UI test suite on "
                                + "the iPhone 17 simulator",
                            progress: AgentProgress(steps: .init(done: 3, total: 6), phase: nil)),
                        summary(
                            paneID: "api:p7", status: .working, minutesAgo: 1,
                            text: "Adding exponential backoff to webhook retries; now writing "
                                + "tests for the 5xx path",
                            progress: AgentProgress(steps: .init(done: 6, total: 7), phase: nil)),
                    ],
                    resourceUsage: HostResourceUsage(cpu: 0.41, memory: 0.37, swap: 0.03)),
            ]
        }

        /// A whole-minute launch time half an hour or more before `now` whose
        /// chat opens with `chatGreeting`. The greeting hashes the launch
        /// time and draws on its hour, so a plain `now - 30m` changes it from
        /// run to run. The seed is the app's own `ChatGreeting.seed`. When no
        /// minute in the past day matches (only if `chatGreeting` left the
        /// pool), DEBUG stops here instead of capturing another greeting.
        private static func chatLaunch(near now: Date) -> Date {
            let minute: TimeInterval = 60
            let latest = (now.timeIntervalSince1970 / minute).rounded(.down) * minute - 30 * minute
            for step in 0..<(24 * 60) {
                let launchedAt = Date(timeIntervalSince1970: latest - TimeInterval(step) * minute)
                let seed = ChatGreeting.seed(
                    agentID: chatAgentID, terminalID: "terminal:\(chatAgentPaneID)",
                    launchedAt: launchedAt)
                if ChatGreeting.text(seed: seed, startedAt: launchedAt) == chatGreeting {
                    return launchedAt
                }
            }
            assertionFailure("No launch time in the past day opens the demo chat with \(chatGreeting)")
            return Date(timeIntervalSince1970: latest)
        }

        /// The Chat Mode Agent's screen while Blocked: claude asking to run
        /// the suite the last message asked for, short enough that the
        /// iPhone chat still shows the whole first exchange.
        private static let chatPermissionPrompt = """
             Bash command
               make test-ipad
             Do you want to proceed?
             ❯ 1. Yes
               2. No, and tell Claude what to do (esc)
            """

        /// Two exchanges about a flaky test; the last turn is still open.
        /// The first reply carries the timeline image its turn opened.
        private static func chatTranscript(now: Date) -> ChatTranscriptSnapshot {
            func message(
                _ id: String, _ role: ChatTranscriptMessage.Role, minutesAgo: Int, _ text: String,
                media: [ChatMedia] = []
            ) -> ChatTranscriptMessage {
                ChatTranscriptMessage(
                    id: id, role: role, text: text,
                    timestamp: now.addingTimeInterval(TimeInterval(-minutesAgo * 60)),
                    media: media)
            }
            return ChatTranscriptSnapshot(
                header: ChatTranscriptHeader(
                    kind: "claude", status: .ok, transcript: nil,
                    activity: "Running the tests", turnOpen: true, truncated: false, error: nil),
                messages: (DemoScreenshotMode.isLongChatEnabled ? longHistory(now: now) : []) + [
                    message(
                        "demo-u1", .user, minutesAgo: 26,
                        "The reconnect test fails about one run in five. Can you find out why?"),
                    message(
                        "demo-a1", .assistant, minutesAgo: 21,
                        "Found it: the fake clock ticks before the keepalive task starts "
                            + "listening, so the first ping sometimes fires early. The test now "
                            + "waits for the task, and it passed 200 runs in a row.",
                        media: [
                            ChatMedia(
                                id: "demo-reconnect-timeline", kind: .image, mime: "image/png",
                                source: .hostFile(path: DemoScreenshotTransport.timelineImagePath))
                        ]),
                    message(
                        "demo-u2", .user, minutesAgo: 1,
                        "Great. Now run the full suite on the iPad simulator."),
                ])
        }

        /// `--demo-long-chat`: 120 earlier exchanges of mixed length, oldest
        /// first, all before the usual two. A late reply shows four images,
        /// like a turn that opened several.
        private static func longHistory(now: Date) -> [ChatTranscriptMessage] {
            let sentences = [
                "The snapshot retry waits for the events session before it asks again.",
                "I checked the keepalive path and it only pings while the link is idle.",
                "That build took about ~4 minutes, roughly ~$0.12 of runner time.",
                "The flaky case only shows up when two reconnects overlap.",
                "Nothing else in the transport touches that clock.",
                "The iPad layout keeps the Composer above the keyboard now.",
            ]
            return (0..<120).flatMap { index -> [ChatTranscriptMessage] in
                let minutesAgo = 30 + (120 - index) * 3
                let reply = (0...(index % 6)).map { sentences[($0 + index) % sentences.count] }
                var paragraphs = index % 4 == 0
                    ? reply.joined(separator: " ") + "\n\n" + sentences[index % sentences.count]
                    : reply.joined(separator: " ")
                // A late reply names a web photo and a screen recording: both
                // wait for a tap.
                if index == 117 {
                    paragraphs += "\n\nhttps://images.example.com/boards/topton-n150.png"
                        + "\n/workspace/waycar/docs/reconnect.mp4"
                }
                return [
                    ChatTranscriptMessage(
                        id: "demo-h\(index)-u", role: .user,
                        text: index % 3 == 0
                            ? "Can you look at case \(index)?"
                            : "What about the retry path in case \(index), and does it still hold "
                                + "up when the Host drops mid-turn?",
                        timestamp: now.addingTimeInterval(TimeInterval(-minutesAgo * 60))),
                    ChatTranscriptMessage(
                        id: "demo-h\(index)-a", role: .assistant, text: paragraphs,
                        timestamp: now.addingTimeInterval(TimeInterval(-(minutesAgo - 1) * 60)),
                        media: index == 114
                            ? (1...4).map { n in
                                ChatMedia(
                                    id: "demo-board-\(n)", kind: .image, mime: "image/png",
                                    source: .hostFile(path: "/workspace/waycar/docs/board-\(n).png"))
                            }
                            : []),
                ]
            }
        }

        static func makeDefaults() -> UserDefaults {
            let suiteName = "com.otreva.waycar.demo-screenshots.\(UUID().uuidString)"
            return UserDefaults(suiteName: suiteName) ?? UserDefaults()
        }

        static let sidebarLayoutData = Data(
            #"{"v":1,"sidebar":{"agents":{"rows":[[{"token":"workspace"}],[{"token":"terminal_title_stripped"}],[{"token":"agent"}]]}}}"#.utf8)

        /// CodexBar's usage JSON with two fake Codex accounts and independent
        /// allowances. Reset times are relative to `now` so countdowns read
        /// true; each pace mark is the share of its window already elapsed.
        static func codexBarUsageJSON(now: Date) -> Data {
            func iso(_ minutes: Int) -> String {
                now.addingTimeInterval(TimeInterval(minutes * 60))
                    .formatted(.iso8601)
            }
            return Data(
                """
                [{"provider":"claude","source":"web","rateWindowLabels":{"primary":"Session","secondary":"Weekly"},\
                "pace":{"primary":{"stage":"behind","deltaPercent":-14,"expectedUsedPercent":55,"willLastToReset":true},\
                "secondary":{"stage":"farAhead","deltaPercent":20,"expectedUsedPercent":68,"etaSeconds":187200,"willLastToReset":false}},\
                "usage":{"primary":{"usedPercent":41,"windowMinutes":300,"resetsAt":"\(iso(134))"},\
                "secondary":{"usedPercent":88,"windowMinutes":10080,"resetsAt":"\(iso(2 * 1440 + 300))"},\
                "tertiary":null,"updatedAt":"\(iso(0))"}},\
                {"provider":"codex","account":"Work","cacheAccountKey":"demo-work","version":"0.157.1","source":"oauth","rateWindowLabels":{"primary":"Session","secondary":"Weekly"},\
                "pace":{"primary":{"stage":"slightlyBehind","deltaPercent":-5,"expectedUsedPercent":11,"willLastToReset":true},\
                "secondary":{"stage":"behind","deltaPercent":-8,"expectedUsedPercent":42,"willLastToReset":true}},\
                "usage":{"primary":{"usedPercent":6,"windowMinutes":300,"resetsAt":"\(iso(266))"},\
                "secondary":{"usedPercent":34,"windowMinutes":10080,"resetsAt":"\(iso(4 * 1440 + 60))"},\
                "tertiary":null,"updatedAt":"\(iso(0))"}},\
                {"provider":"codex","account":"Personal","cacheAccountKey":"demo-personal","version":"0.157.1","source":"oauth","rateWindowLabels":{"primary":"Session","secondary":"Weekly"},\
                "pace":{"primary":{"stage":"behind","deltaPercent":-12,"expectedUsedPercent":41,"willLastToReset":true},\
                "secondary":{"stage":"behind","deltaPercent":-8,"expectedUsedPercent":65,"willLastToReset":true}},\
                "usage":{"primary":{"usedPercent":29,"windowMinutes":300,"resetsAt":"\(iso(177))"},\
                "secondary":{"usedPercent":57,"windowMinutes":10080,"resetsAt":"\(iso(2 * 1440 + 647))"},\
                "tertiary":null,"updatedAt":"\(iso(0))"}},\
                {"provider":"gemini","source":"api","rateWindowLabels":{"primary":"Pro","secondary":"Flash"},\
                "pace":{"primary":{"stage":"farBehind","deltaPercent":-41,"expectedUsedPercent":63,"willLastToReset":true}},\
                "usage":{"primary":{"usedPercent":22,"windowMinutes":1440,"resetsAt":"\(iso(9 * 60))"},\
                "secondary":{"usedPercent":9,"windowMinutes":1440,"resetsAt":"\(iso(9 * 60))"},\
                "tertiary":null,"updatedAt":"\(iso(0))"}}]
                """.utf8)
        }

        /// - Parameter opensChat: serve `chatModeProfiles` instead of
        ///   `profiles` (`--demo-chat-mode`).
        @MainActor
        static func makeConsoleStore(opensChat: Bool = false) -> ConsoleStore {
            let defaults = makeDefaults()
            var mutableProfiles = opensChat ? chatModeProfiles : profiles
            if DemoScreenshotMode.isUltimateChatEnabled {
                mutableProfiles[ultimateHostID] = ultimateProfile(now: Date())
            }
            let hostProfiles = mutableProfiles
            let scratch = FileManager.default.temporaryDirectory
                .appending(path: "demo-chat-\(UUID().uuidString)", directoryHint: .isDirectory)
            let queuesLaunches = DemoScreenshotMode.isQueuedLaunchesEnabled
            let offlineUntil = Date().addingTimeInterval(90)
            let launchStore = queuesLaunches ? makeQueuedLaunches(in: scratch) : nil
            let messages = QueuedMessageStore(directory: scratch.appending(path: "messages"))
            if let waiting = launchStore?.launches(on: buildHostID).first(where: { $0.state == .waiting }),
                let identity = waiting.pendingIdentity
            {
                try? messages.save(QueuedMessage(
                    id: UUID(), hostID: waiting.hostID, agent: identity,
                    draftText: "Cover timeouts and rate limits with tests too.", attachments: [],
                    createdAt: waiting.createdAt.addingTimeInterval(60)))
            }
            return ConsoleStore(
                snapshotRetryDelay: .seconds(30),
                pins: PinnedAgentsStore(defaults: defaults),
                unread: UnreadAgentsStore(defaults: defaults),
                closedSessions: makeClosedSessionsStore(),
                chatMode: ChatModeStore(defaults: defaults),
                rowLayouts: AgentRowLayoutStore(defaults: defaults),
                inventoryCache: queuesLaunches
                    ? makeOfflineInventory(in: scratch, profiles: hostProfiles) : nil,
                // Chats keep their on-device copies as in the app, in a
                // throwaway directory, so reopening one behaves the same.
                chatTranscriptCache: ChatTranscriptCache(
                    directory: scratch.appending(path: "transcripts")),
                chatMediaCache: ChatMediaCache(directory: scratch.appending(path: "media")),
                queuedMessages: messages,
                queuedLaunches: launchStore,
                makeSession: { host, _, subscriptions in
                    EventsSession(
                        subscriptions: subscriptions,
                        connect: {
                            guard let profile = hostProfiles[host.id],
                                !(queuesLaunches && host.id == buildHostID && Date() < offlineUntil)
                            else {
                                throw TransportError.sshUnreachable(
                                    detail: "No demo profile for Host.")
                            }
                            return DemoScreenshotTransport(profile: profile)
                        },
                        reconnectPolicy: ReconnectPolicy(
                            initialDelay: .seconds(30), multiplier: 1, maxDelay: .seconds(30)),
                        keepalive: nil)
                },
                // The Dev Workstation is Ultimate-only; everything else
                // keeps the default herdr-only answer.
                detectBackends: { host in
                    host.id == ultimateHostID ? ultimatePresence : .herdrOnly
                })
        }

        /// `--demo-queued-launches`: the Build Server's rows and Agent kinds
        /// as a connection two hours ago left them on the device.
        private static func makeOfflineInventory(
            in scratch: URL, profiles: [Host.ID: DemoHostProfile]
        ) -> ConsoleInventoryCache? {
            guard let host = hosts.first(where: { $0.id == buildHostID }),
                let profile = profiles[buildHostID]
            else { return nil }
            let seenAt = Date().addingTimeInterval(-2 * 3600)
            let cache = ConsoleInventoryCache(directory: scratch.appending(path: "inventory"))
            cache.save(
                ConsoleInventoryCache.Entry(
                    snapshot: profile.snapshot, sidebarLayout: nil, verifiedAt: seenAt),
                for: host)
            cache.saveAgentKinds(
                CachedAgentKinds(kinds: [.claude, .codex, .omp], verifiedAt: seenAt), for: host)
            cache.flush()
            return cache
        }

        /// `--demo-queued-launches`: an earlier launch on each Host that
        /// waits on the user, a failed one and one the app closed on.
        private static func makeQueuedLaunches(in scratch: URL) -> QueuedLaunchStore {
            let store = QueuedLaunchStore(directory: scratch.appending(path: "launches"))
            func draft(
                _ hostID: Host.ID, _ kind: SupportedAgentKind, workspaceID: String, name: String,
                message: String
            ) -> LaunchDraft {
                LaunchDraft(
                    id: UUID(), hostID: hostID,
                    dispatch: StartAgentStore.Dispatch(
                        destination: .existingWorkspace, launch: .agent(kind), backend: .herdr),
                    workspaceID: workspaceID, originCwd: nil, name: name, suggestedName: nil,
                    userArguments: [], chatMode: false, presetFirstMessage: nil,
                    firstMessage: LaunchDraft.FirstMessage(text: message, attachments: []),
                    remembersLaunch: true, isQuickChat: false)
            }
            let now = Date()
            let launches = [
                QueuedLaunch(
                    draft: draft(
                        buildHostID, .omp, workspaceID: "api", name: "webhook-retries",
                        message: "Add retries with backoff to the webhook sender"),
                    state: .waiting,
                    createdAt: now.addingTimeInterval(-5 * 60)),
                QueuedLaunch(
                    draft: draft(
                        studioHostID, .codex, workspaceID: "docs", name: "api-docs",
                        message: "Regenerate the API reference from the OpenAPI spec"),
                    state: .failed("The Host did not answer in time."),
                    createdAt: now.addingTimeInterval(-25 * 60)),
                QueuedLaunch(
                    draft: draft(
                        buildHostID, .omp, workspaceID: "api", name: "retry-webhooks",
                        message: "Add retries with backoff to the webhook sender"),
                    state: .uncertain,
                    createdAt: now.addingTimeInterval(-50 * 60)),
            ]
            for launch in launches { try? store.save(launch) }
            return store
        }

        /// Closed Sessions arrive as another device's do: iCloud Keychain
        /// records, here in a process-local store merged once at launch.
        @MainActor
        static func makeClosedSessionsStore(now: Date = Date()) -> ClosedSessionsStore {
            let shared = VolatileSecretStore()
            for session in closedSessions(now: now) {
                try? shared.write(
                    SyncedClosedSessionCatalog.encode(session),
                    account: SyncedClosedSessionCatalog.account(for: session.id))
            }
            let store = ClosedSessionsStore(sync: SyncedClosedSessionCatalog(store: { shared }))
            _ = try? store.reconcileWithSync(
                shared.readAll(), knownHosts: Set(hosts.map(\.id)))
            return store
        }

        static func closedSessions(now: Date) -> [ClosedSession] {
            [
                closedSession(
                    hostID: buildHostID, kind: .pi, title: "Bump dependencies",
                    workspaceID: "checkout", workspaceLabel: "Checkout",
                    cwd: "/workspace/storefront", closedMinutesAgo: 5, now: now),
                closedSession(
                    hostID: studioHostID, kind: .claude, title: "Refactor auth",
                    workspaceID: "mobile", workspaceLabel: "iOS App",
                    cwd: "/workspace/waycar", closedMinutesAgo: 2 * 60, now: now),
                closedSession(
                    hostID: buildHostID, kind: .codex, title: "Fix flaky test",
                    workspaceID: "api", workspaceLabel: "Payments API",
                    cwd: "/workspace/payments-api", closedMinutesAgo: 26 * 60, now: now),
                closedSession(
                    hostID: studioHostID, kind: .omp, title: "Docs pass",
                    workspaceID: "docs", workspaceLabel: "Product Docs",
                    cwd: "/workspace/product-docs", closedMinutesAgo: 3 * 1440, now: now),
            ]
        }

        private static func closedSession(
            hostID: Host.ID,
            kind: SupportedAgentKind,
            title: String,
            workspaceID: String,
            workspaceLabel: String,
            cwd: String,
            closedMinutesAgo: Int,
            now: Date
        ) -> ClosedSession {
            let reference = ClosedSession.SessionReference(
                kind: .id, value: "demo-\(kind.rawValue)-\(workspaceID)")
            let closedAt = now.addingTimeInterval(-TimeInterval(closedMinutesAgo * 60))
            return ClosedSession(
                id: ClosedSession.recordID(
                    hostID: hostID, kind: kind, session: reference,
                    terminalID: "terminal:\(workspaceID):closed"),
                hostID: hostID,
                hostName: hosts.first { $0.id == hostID }?.name ?? "",
                kind: kind,
                agentName: nil,
                title: title,
                cwd: cwd,
                workspaceID: workspaceID,
                workspaceLabel: workspaceLabel,
                tabLabel: nil,
                session: reference,
                lastSeenRunningAt: closedAt.addingTimeInterval(-60),
                closedAt: closedAt)
        }

        private static func snapshot(
            agents: [AgentInfo], workspaces: [WorkspaceInfo]
        ) -> SessionSnapshot {
            SessionSnapshot(
                agents: agents,
                layouts: [],
                panes: [],
                protocolVersion: 17,
                tabs: [],
                version: "0.7.5-demo",
                workspaces: workspaces)
        }

        private static func summary(
            paneID: String, status: AgentStatus, minutesAgo: Int, text: String,
            progress: AgentProgress? = nil
        ) -> DemoSummary {
            DemoSummary(
                paneID: paneID, status: status, text: text, minutesAgo: minutesAgo,
                progress: progress)
        }

        private static func agent(
            paneID: String,
            status: AgentStatus,
            workspaceID: String,
            kind: String,
            name: String,
            title: String,
            cwd: String
        ) -> AgentInfo {
            AgentInfo(
                agentStatus: status,
                focused: false,
                paneID: paneID,
                revision: 1,
                tabID: "\(workspaceID):t1",
                terminalID: "terminal:\(paneID)",
                workspaceID: workspaceID,
                agent: kind,
                cwd: cwd,
                name: name,
                terminalTitleStripped: title)
        }

        private static func workspace(
            id: String,
            label: String,
            repo: String,
            isLinkedWorktree: Bool = false
        ) -> WorkspaceInfo {
            let repoRoot = isLinkedWorktree ? "/source/\(repo)" : "/workspace/\(repo)"
            return WorkspaceInfo(
                activeTabID: "\(id):t1",
                agentStatus: .unknown,
                focused: false,
                label: label,
                number: 1,
                paneCount: 1,
                tabCount: 1,
                workspaceID: id,
                worktree: WorkspaceWorktreeInfo(
                    checkoutPath: "/workspace/\(repo)",
                    isLinkedWorktree: isLinkedWorktree,
                    repoKey: "\(repoRoot)/.git",
                    repoName: repo,
                    repoRoot: repoRoot))
        }
    }

    struct DemoHostProfile: Sendable {
        let snapshot: SessionSnapshot
        /// Agent Summaries the demo Host's plugin holds, one per pane.
        let summaries: [DemoSummary]
        /// The Host's Chat Markers.
        var chatMarkers: [ChatModeMarker] = []
        /// What the Host's transcript reader answers, by pane id.
        var chatTranscripts: [String: ChatTranscriptSnapshot] = [:]
        /// What a visible-screen read of a pane answers, by pane id; any
        /// other pane reads "Ready.".
        var screens: [String: String] = [:]
        /// Ultimate branches by their leader's pane id (`--demo-ultimate-chat`).
        var ultimateChildren: [String: [UltimateChildInfo]] = [:]
        /// Open board questions by leader pane id.
        var ultimateQuestions: [String: Int] = [:]
        /// What the Hosts sheet's CPU / memory / swap line shows.
        var resourceUsage: HostResourceUsage?
    }

    /// One Agent Summary in the demo store, aged relative to each read so
    /// the cards always read "1m" or "2m", with the Agent Progress estimate
    /// the plugin stored beside it, if any.
    struct DemoSummary: Sendable {
        let paneID: String
        let status: AgentStatus
        let text: String
        let minutesAgo: Int
        var progress: AgentProgress?

        func summary(now: Date) -> AgentSummary {
            let written = now.addingTimeInterval(TimeInterval(-minutesAgo * 60 - 5))
            return AgentSummary(
                paneID: paneID, status: status, text: text,
                timestamp: Int64(written.timeIntervalSince1970 * 1000), progress: progress)
        }
    }

    /// One generated terminal frame (`DemoTerminalFrames`) and the width it
    /// was drawn for.
    struct DemoTerminalFrame: Sendable {
        let cols: Int
        let text: String

        /// What the TUI paints into a `cols`-wide window: the widest frame
        /// that fits without wrapping, or the narrowest when none does. Rows
        /// need no fitting: every frame is taller than any pane, so the paint
        /// scrolls its prompt onto the pane's bottom row.
        static func fitting(cols: Int) -> DemoTerminalFrame {
            DemoTerminalFrames.all.last(where: { $0.cols <= cols }) ?? DemoTerminalFrames.iphone
        }
    }

    private actor DemoScreenshotTransport: Transport {
        private let profile: DemoHostProfile
        private var isClosed = false
        private var eventContinuation: AsyncThrowingStream<HerdrEvent, any Error>.Continuation?
        private var terminalContinuation: AsyncThrowingStream<Data, any Error>.Continuation?
        private var terminalInput: TerminalAttachInputQueue?

        init(profile: DemoHostProfile) {
            self.profile = profile
        }

        func ping() async throws -> ServerInfo {
            ServerInfo(version: profile.snapshot.version, protocolVersion: 17)
        }

        func listAgents() async throws -> [Agent] {
            profile.snapshot.agents.map(Agent.init)
        }

        func availableAgentKinds() async throws -> [SupportedAgentKind] {
            [.claude, .codex, .gemini, .opencode]
        }

        func readSidebarLayout() async throws -> Data? {
            DemoScreenshotFixture.sidebarLayoutData
        }

        func readChatModeMarkers() async throws -> [ChatModeMarker] {
            profile.chatMarkers
        }

        func ultimateConversationChildren() async -> [String: [UltimateChildInfo]] {
            profile.ultimateChildren
        }

        func ultimateOpenQuestions() async -> [String: Int] {
            profile.ultimateQuestions
        }

        /// Answers as the plugin's reader does: the pane's transcript, from
        /// just after `after` when that id is known, else not found.
        func readChatTranscript(
            _ request: ChatTranscriptRequest
        ) async throws -> ChatTranscriptSnapshot {
            guard let transcript = profile.chatTranscripts[request.paneID] else {
                return ChatTranscriptSnapshot(
                    header: ChatTranscriptHeader(
                        kind: request.kind, status: .notFound, transcript: nil, activity: nil,
                        turnOpen: false, truncated: false, error: nil),
                    messages: [])
            }
            guard let after = request.after,
                let index = transcript.messages.firstIndex(where: { $0.id == after })
            else { return transcript }
            return ChatTranscriptSnapshot(
                header: transcript.header,
                messages: Array(transcript.messages[(index + 1)...]))
        }

        /// The Host file the demo chat's reply shows as an image.
        static let timelineImagePath = "/workspace/waycar/docs/reconnect-timeline.png"

        /// Serves the demo chat's images: the timeline, and under the long
        /// chat (`--demo-long-chat`) any PNG beside it. Every other path is missing.
        func readPreviewFile(atPath path: String, maxBytes: Int) async throws -> Data {
            let servesPath = path == Self.timelineImagePath
                || (DemoScreenshotMode.isLongChatEnabled
                    && path.hasPrefix("/workspace/waycar/docs/") && path.hasSuffix(".png"))
            guard servesPath else { throw RemoteFilePreviewError.missing }
            let data = await MainActor.run { DemoChatMedia.reconnectTimelinePNG() }
            guard let data else { throw RemoteFilePreviewError.unreadable }
            guard data.count <= maxBytes else {
                throw RemoteFilePreviewError.tooLarge(size: UInt64(data.count), limit: maxBytes)
            }
            return data
        }

        /// The demo transcripts hold no inline images.
        func readChatMedia(_ request: ChatMediaRequest) async throws -> Data {
            throw ChatMediaError.unavailable
        }

        func readAgentSummaries() async throws -> [String: AgentSummary] {
            let now = Date()
            return Dictionary(profile.summaries.map { ($0.paneID, $0.summary(now: now)) }) {
                first, _ in first
            }
        }

        func sessionSnapshot() async throws -> SessionSnapshot {
            profile.snapshot
        }

        func readPane(_ params: PaneReadParams) async throws -> PaneReadResult {
            let agent = profile.snapshot.agents.first(where: { $0.paneID == params.paneID })
            return PaneReadResult(
                format: .text,
                paneID: params.paneID,
                revision: 1,
                source: params.source,
                tabID: agent?.tabID ?? "demo:t1",
                text: profile.screens[params.paneID] ?? "Ready.",
                truncated: false,
                workspaceID: agent?.workspaceID ?? "demo")
        }

        func readAgent(_ params: AgentReadParams) async throws -> PaneReadResult {
            let agent = profile.snapshot.agents.first(where: { $0.paneID == params.target })
            return PaneReadResult(
                format: params.format ?? .text,
                paneID: params.target,
                revision: 1,
                source: params.source,
                tabID: agent?.tabID ?? "demo:t1",
                // agent.read has no window to fit, so it reads the narrowest.
                text: DemoTerminalFrames.iphone.text,
                truncated: false,
                workspaceID: agent?.workspaceID ?? "demo")
        }

        func promptAgent(_ params: AgentPromptParams) async throws -> Agent {
            guard let agent = profile.snapshot.agents.first(where: { $0.paneID == params.target })
            else {
                throw TransportError.malformedResponse("Demo profile has no matching Agent.")
            }
            return Agent(agent)
        }

        func checkAgentInputScreen(target: String) async throws {}

        func sendAgentKeys(_ params: AgentSendKeysParams) async throws {}

        func sendPaneInput(_ params: PaneSendInputParams) async throws {}

        func startAgent(_ request: AgentLaunchRequest) async throws -> Agent {
            try await reportLaunchSteps([.creatingTab, .startingAgent])
            return try firstAgent()
        }

        func startAgentInNewWorktree(
            _ request: AgentLaunchRequest, worktree: WorktreeSpec,
            attempt: WorktreeLaunchAttempt
        ) async throws -> Agent {
            try await reportLaunchSteps(
                Self.worktreeSteps(worktree) + [.creatingWorktree, .startingAgent])
            return try firstAgent()
        }

        func startAgentInNewWorkspace(
            _ request: AgentLaunchRequest, workspace: NewWorkspaceSpec
        ) async throws -> Agent {
            try await reportLaunchSteps([.creatingWorkspace, .startingAgent])
            return try firstAgent()
        }

        func startShellTerminal(_ request: ShellLaunchRequest) async throws -> ShellLaunchResult {
            try await reportLaunchSteps([.openingShell])
            throw TransportError.channelFailed(detail: "shells are not scripted in demo mode")
        }

        func startShellTerminalInNewWorktree(
            _ request: ShellLaunchRequest, worktree: WorktreeSpec,
            attempt: WorktreeLaunchAttempt
        ) async throws -> ShellLaunchResult {
            try await reportLaunchSteps(
                Self.worktreeSteps(worktree) + [.creatingWorktree, .openingShell])
            throw TransportError.channelFailed(detail: "shells are not scripted in demo mode")
        }

        func startShellTerminalInNewWorkspace(
            _ request: ShellLaunchRequest, workspace: NewWorkspaceSpec
        ) async throws -> ShellLaunchResult {
            try await reportLaunchSteps([.creatingWorkspace, .openingShell])
            throw TransportError.channelFailed(detail: "shells are not scripted in demo mode")
        }

        private func firstAgent() throws -> Agent {
            guard let first = profile.snapshot.agents.first else {
                throw TransportError.malformedResponse("Demo profile has no Agents.")
            }
            return Agent(first)
        }

        /// The steps a real worktree launch takes before `worktree.create`.
        private static func worktreeSteps(_ worktree: WorktreeSpec) -> [LaunchStep] {
            worktree.base == .latestDefaultBranch ? [.gettingLatestMain] : []
        }

        /// Reports `steps` the way the real Transport does, each as it
        /// begins, pausing on each so the sheet's launch banner shows in demo
        /// captures.
        private func reportLaunchSteps(_ steps: [LaunchStep]) async throws {
            for step in steps {
                LaunchProgress.report(step)
                try await Task.sleep(for: .milliseconds(700))
            }
        }

        func closePane(_ params: PaneTarget, closesWorktreeGroup: Bool) async throws {}
        func closeTab(_ params: TabTarget) async throws {}

        // Demo terminals are scripted fixture streams; there is no Host to
        // probe or bootstrap, so mosh reports unavailable and every attach
        // rides the SSH-shaped attachTerminal above.
        func probeMoshServer() async throws -> Bool { false }
        func runMoshBootstrap(_ request: TerminalAttachRequest) async throws -> MoshBootstrap {
            throw TransportError.channelFailed(detail: "mosh is not available in demo mode")
        }

        // Launch prompts land nowhere real; the paths only have to look like
        // a Host's so a demo Chat Mode launch reads as it would live.
        func stageLaunchPromptFiles(
            _ files: [LaunchPromptFile]
        ) async throws -> [StagedLaunchPromptFile] {
            files.map { file in
                switch file.destination {
                case .stageDirectory:
                    StagedLaunchPromptFile(file: file, path: "/tmp/waycar.demo/\(file.name)")
                case .codexProfile:
                    StagedLaunchPromptFile(
                        file: file, path: "/home/demo/.codex/\(file.name).config.toml")
                }
            }
        }

        func launchPromptCapabilities() async -> LaunchPromptCapabilities {
            LaunchPromptCapabilities(claudeAppendSystemPromptFile: true, codexProfileFile: true)
        }

        // A plausible CodexBar so AI Usage has something to show: Claude's
        // week running low, Codex and Gemini comfortable.
        func locateCodexBar(customPath: String?) async throws -> String? {
            customPath ?? "/opt/homebrew/bin/codexbar"
        }

        func codexBarUsage(executablePath: String) async throws -> AIUsageReport {
            try AIUsageReport.decode(DemoScreenshotFixture.codexBarUsageJSON(now: Date()))
        }

        func hostResourceUsage() async throws -> HostResourceUsage {
            guard let usage = profile.resourceUsage else { throw HostResourceUsage.Unsupported() }
            return usage
        }

        func movePane(_ params: PaneMoveParams) async throws -> PaneMoveResponse {
            throw TransportError.channelFailed(detail: "moves are not scripted in demo mode")
        }
        func focusAgent(_ target: AgentTarget) async throws {}
        func renameAgent(_ params: AgentRenameParams) async throws {}
        func renameWorkspace(_ params: WorkspaceRenameParams) async throws {}

        func subscribeToEvents(
            _ subscriptions: [EventSubscription]
        ) async throws -> HerdrEventStream {
            guard eventContinuation == nil else {
                throw TransportError.eventsChannelAlreadyOpen
            }
            let (events, continuation) = AsyncThrowingStream<HerdrEvent, any Error>.makeStream()
            eventContinuation = continuation
            return HerdrEventStream(events: events) { await self.endEvents() }
        }

        func attachTerminal(
            _ request: TerminalAttachRequest
        ) async throws -> TerminalAttachSession {
            guard terminalContinuation == nil else {
                throw TransportError.terminalChannelAlreadyOpen
            }
            let (output, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
            let input = TerminalAttachInputQueue()
            terminalContinuation = continuation
            terminalInput = input
            let firstFrame = Data(DemoTerminalFrame.fitting(cols: request.cols).text.utf8)
            let delay = DemoScreenshotMode.attachDelay
            Task {
                if delay > .zero { try? await Task.sleep(for: delay) }
                continuation.yield(firstFrame)
                // Repaint on every window change, as the TUI behind a real
                // PTY does; keystrokes and scrolling have nothing to drive.
                while let item = await input.next() {
                    if case .resize(let cols, _) = item {
                        continuation.yield(Data(DemoTerminalFrame.fitting(cols: cols).text.utf8))
                    }
                }
            }
            return TerminalAttachSession(output: { output }, input: input) {
                await self.endTerminal()
            }
        }

        var isConnected: Bool { !isClosed }

        func close() async throws {
            isClosed = true
            endEvents()
            endTerminal()
        }

        private func endEvents() {
            eventContinuation?.finish()
            eventContinuation = nil
        }

        private func endTerminal() {
            terminalInput?.finish()
            terminalInput = nil
            terminalContinuation?.finish()
            terminalContinuation = nil
        }
    }

    /// The image the demo chat's reply shows: a reconnect timeline chart,
    /// drawn rather than bundled so screenshot runs ship no asset.
    @MainActor
    private enum DemoChatMedia {
        static func reconnectTimelinePNG() -> Data? {
            let size = CGSize(width: 1200, height: 750)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let renderer = UIGraphicsImageRenderer(size: size, format: format)
            let image = renderer.image { context in
                UIColor(Brand.Colors.surface2).setFill()
                context.fill(CGRect(origin: .zero, size: size))
                let title: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 44, weight: .semibold),
                    .foregroundColor: UIColor(Brand.Colors.text),
                ]
                NSAttributedString(string: "Reconnect timeline", attributes: title)
                    .draw(at: CGPoint(x: 64, y: 56))
                let caption: [NSAttributedString.Key: Any] = [
                    .font: UIFont.monospacedSystemFont(ofSize: 26, weight: .regular),
                    .foregroundColor: UIColor(Brand.Colors.text3),
                ]
                // Each lane: its label and the spans (start, end, color) on a 0–10 s axis.
                let lanes: [(String, [(CGFloat, CGFloat, Color)])] = [
                    ("socket", [(0, 3.2, Brand.Colors.done), (3.2, 5.1, Brand.Colors.blocked),
                                (5.1, 10, Brand.Colors.done)]),
                    ("events", [(0, 3.3, Brand.Colors.done), (3.3, 6.4, Brand.Colors.working),
                                (6.4, 10, Brand.Colors.done)]),
                    ("terminal", [(0, 3.4, Brand.Colors.done), (3.4, 5.6, Brand.Colors.working),
                                  (5.6, 10, Brand.Colors.done)]),
                ]
                let axis = CGRect(x: 260, y: 170, width: 880, height: 480)
                let laneHeight = axis.height / CGFloat(lanes.count)
                for (index, lane) in lanes.enumerated() {
                    let y = axis.minY + CGFloat(index) * laneHeight
                    NSAttributedString(string: lane.0, attributes: caption)
                        .draw(at: CGPoint(x: 64, y: y + laneHeight / 2 - 18))
                    for (start, end, color) in lane.1 {
                        let bar = CGRect(
                            x: axis.minX + axis.width * start / 10, y: y + laneHeight * 0.3,
                            width: axis.width * (end - start) / 10 - 6, height: laneHeight * 0.4)
                        UIColor(color).setFill()
                        UIBezierPath(roundedRect: bar, cornerRadius: 10).fill()
                    }
                }
                UIColor(Brand.Colors.line2).setFill()
                context.fill(CGRect(x: axis.minX, y: axis.maxY + 8, width: axis.width, height: 2))
                for second in stride(from: 0, through: 10, by: 2) {
                    NSAttributedString(string: "\(second)s", attributes: caption)
                        .draw(at: CGPoint(x: axis.minX + axis.width * CGFloat(second) / 10 - 12, y: axis.maxY + 20))
                }
            }
            return image.pngData()
        }
    }

    private struct DemoPushRegistrationClient: PushRegistrationClient {
        func authorizationStatus() async -> UNAuthorizationStatus { .denied }
        func requestAuthorization() async throws -> Bool { false }
        @MainActor func registerForRemoteNotifications() {}
    }
#endif
