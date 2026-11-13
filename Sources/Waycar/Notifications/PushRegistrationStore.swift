import CarPlay
import Foundation
import Observation
import UIKit
import UserNotifications

/// Which APNs environment this build's device tokens belong to — the `env`
/// field of the Notification Registration file contract. Debug builds run
/// under development provisioning, whose tokens only exist on the sandbox
/// APNs host; Release builds (TestFlight, App Store) get production tokens.
enum APNSEnvironment: String, Sendable, Codable {
    case sandbox
    case production

    static var current: APNSEnvironment {
        #if DEBUG
            .sandbox
        #else
            .production
        #endif
    }
}

/// A captured APNs device token in the wire form the registration file
/// wants: lowercase hex plus the environment it belongs to.
struct APNSDeviceToken: Sendable, Equatable {
    let hex: String
    let environment: APNSEnvironment

    init(hex: String, environment: APNSEnvironment) {
        self.hex = hex
        self.environment = environment
    }

    init(tokenData: Data, environment: APNSEnvironment) {
        self.init(
            hex: tokenData.map { String(format: "%02x", $0) }.joined(),
            environment: environment)
    }
}

/// The system boundary of push bootstrap: iOS permission state and APNs
/// registration. A protocol so the store's state machine is testable; the
/// token itself still arrives through `UIApplicationDelegate` callbacks,
/// which `PushRegistrationDelegate` forwards into the store.
protocol PushRegistrationClient: Sendable {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async throws -> Bool
    @MainActor func registerForRemoteNotifications()
}

struct SystemPushRegistrationClient: PushRegistrationClient {
    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
    }

    @MainActor func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }
}

/// App-side push bootstrap (#71): asks for notification permission, registers
/// with APNs, and captures the device token that Notification Registration
/// (#72) will write to a Host. Apple says tokens can change between
/// launches, so `refresh` silently re-registers whenever permission already
/// exists instead of caching a token across runs.
@MainActor
@Observable
final class PushRegistrationStore {
    typealias State = PushRegistrationMachine.DisplayState

    var state: State { registration.display }
    private var registration = PushRegistrationMachine()

    private let client: any PushRegistrationClient
    private let environment: APNSEnvironment

    init(
        client: any PushRegistrationClient = SystemPushRegistrationClient(),
        environment: APNSEnvironment = .current
    ) {
        self.client = client
        self.environment = environment
    }

    /// The captured token, once APNs has answered.
    var deviceToken: APNSDeviceToken? {
        if case .registered(let token) = state { return token }
        return nil
    }

    /// Launch/foreground sync: re-register silently when permission already
    /// exists, otherwise just reflect where the user left the permission.
    func refresh() async {
        await perform(registration.handle(.refresh))
    }

    /// The user-initiated step: show the iOS permission prompt, then register.
    func enable() async {
        await perform(registration.handle(.enable))
    }

    func deviceTokenDidArrive(_ tokenData: Data) {
        let token = APNSDeviceToken(tokenData: tokenData, environment: environment)
        // Callback events only update state; they never request system work.
        _ = registration.handle(.deviceTokenArrived(token))
    }

    func registrationDidFail(_ error: any Error) {
        _ = registration.handle(.registrationFailed(error.localizedDescription))
    }

    private func perform(_ effects: [PushRegistrationMachine.Effect]) async {
        for effect in effects {
            switch effect {
            case .checkAuthorization(let token):
                let answer: PushRegistrationMachine.Authorization
                switch await client.authorizationStatus() {
                case .authorized, .provisional, .ephemeral: answer = .allowed
                case .denied: answer = .denied
                case .notDetermined: answer = .undetermined
                @unknown default: answer = .undetermined
                }
                await perform(registration.handle(.authorizationFinished(token, answer)))
            case .requestPermission(let token):
                let answer: PushRegistrationMachine.Permission
                do {
                    answer = try await client.requestAuthorization() ? .granted : .denied
                } catch {
                    answer = .failed(error.localizedDescription)
                }
                await perform(registration.handle(.permissionFinished(token, answer)))
            case .register:
                client.registerForRemoteNotifications()
            }
        }
    }
}

/// UIKit shim: APNs delivers the device token only through
/// `UIApplicationDelegate` callbacks, so the SwiftUI app installs this via
/// `@UIApplicationDelegateAdaptor`. It owns the store so the callbacks have
/// somewhere to land before any view exists.
@MainActor
final class PushRegistrationDelegate: NSObject, UIApplicationDelegate {
    let registration = PushRegistrationStore()
    /// Home Screen quick actions (New Chat) waiting for a window.
    let quickActions = QuickActionCenter.shared
    /// The windows Agent Notification taps land in (#74). Each window owns
    /// its own navigation router; this app-wide directory picks which one a
    /// tap drives, so it has to exist before any window does.
    let sceneDirectory: AgentSceneDirectory
    /// App-wide analytics, built before any window so a notification tap
    /// that cold-starts the app is counted too.
    let analytics: any Analytics
    private let notificationCenterDelegate: AgentNotificationCenterDelegate
    /// Whether a window is on screen, for `willPresent`'s decision.
    private let phoneWindowPresence = PhoneWindowPresence()
    private var sceneConnectionObserver: (any NSObjectProtocol)?
    /// Where a notification's text reply goes; connected at launch.
    private let textReplies = NotificationTextReplies()

    /// The stores every window shares. Built on first use rather than here,
    /// so the Debug screenshot mode never constructs the production ones.
    private(set) lazy var appModel: WaycarAppModel = {
        let model = WaycarAppModel(
            pushRegistration: registration, sceneDirectory: sceneDirectory, analytics: analytics)
        notificationCenterDelegate.attentionBadge = model.attentionBadge
        notificationCenterDelegate.bannerStore = model.bannerStore
        // The watch follows the Console from the moment the model exists;
        // a turn later, since the bridge reads the model this builds.
        Task { @MainActor [weak self] in self?.startWatchPublishing() }
        return model
    }()

    /// The Apple Watch app's phone end. Built on first use: activated at
    /// launch where a watch can pair. In the Debug screenshot mode only with
    /// `-WaycarWatchBridgeDemo YES`, over the demo Console.
    private(set) lazy var watchBridge: WatchBridge = {
        let channel = ConnectivityWatchSession()
        var dependencies = WatchBridge.Dependencies.live(model: { [unowned self] in self.appModel })
        #if DEBUG && targetEnvironment(simulator)
            if DemoScreenshotMode.isWatchBridgeEnabled {
                dependencies = .demo(DemoWatchBridge.composition)
            }
        #endif
        let bridge = WatchBridge(channel: channel, dependencies: dependencies)
        channel.receiver = bridge
        return bridge
    }()
    /// Whether `willFinishLaunching` activated the watch bridge.
    private var isWatchBridgeRunning = false

    override init() {
        let directory = AgentSceneDirectory()
        let analytics = AppAnalytics.make()
        sceneDirectory = directory
        self.analytics = analytics
        let presence = phoneWindowPresence
        let textReplies = textReplies
        notificationCenterDelegate = AgentNotificationCenterDelegate(
            directory: directory, isPhoneWindowOnScreen: { presence.isOnScreen },
            analytics: analytics,
            sendTextReply: { target, text in
                await textReplies.send(text, to: target.agentID)
            })
        super.init()
    }

    func application(
        _ application: UIApplication,
        willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Apple requires the notification delegate installed before launch
        // finishes; otherwise a tap that cold-starts the app never reaches
        // didReceive and the killed-state deep link is lost.
        UNUserNotificationCenter.current().delegate = notificationCenterDelegate
        // Done's Reply opens the watch recorder where this iPhone can
        // transcribe watch audio, else it is a text reply sent from here.
        UNUserNotificationCenter.current().setNotificationCategories(
            AgentNotificationCategories.categories(
                voiceReplyOnWatch: DictationEngines.fileTranscriber != nil))
        phoneWindowPresence.startObserving()
        // The CarPlay scene reaches the model through this; nothing builds
        // it until a scene asks.
        AppModelRegistry.shared.register { [unowned self] in self.appModel }
        // Activated before launch finishes, so watch messages and transfers
        // queued while the app was not running are delivered now.
        if Self.runsWatchBridge(watchSupported: ConnectivityWatchSession.isSupported) {
            isWatchBridgeRunning = true
            watchBridge.activate()
            #if DEBUG && targetEnvironment(simulator)
                // The demo never builds the app model, which starts publishing.
                if DemoScreenshotMode.isWatchBridgeEnabled { watchBridge.startPublishing() }
            #endif
        }
        connectTextReplies()
        return true
    }

    /// Whether this process talks to an Apple Watch: only where one can
    /// pair, never in the unit-test host, nor in the Debug screenshot mode
    /// (which never builds the production stores) unless
    /// `-WaycarWatchBridgeDemo YES` runs it over the demo Console.
    static func runsWatchBridge(watchSupported: Bool) -> Bool {
        #if DEBUG && targetEnvironment(simulator)
            if DemoScreenshotMode.isEnabled {
                return watchSupported && DemoScreenshotMode.isWatchBridgeEnabled
            }
        #endif
        return watchSupported && ICloudSync.runsInThisProcess
    }

    private func startWatchPublishing() {
        guard isWatchBridgeRunning else { return }
        watchBridge.startPublishing()
    }

    /// Points notification text replies at the watch bridge where it runs,
    /// and at the app model for the draft fallback. Not in the Debug
    /// screenshot mode, which never builds the production stores.
    private func connectTextReplies() {
        #if DEBUG && targetEnvironment(simulator)
            if DemoScreenshotMode.isEnabled { return }
        #endif
        var send: (@MainActor (String, ConsoleAgent.ID) async -> AgentActionService.SendOutcome)?
        if isWatchBridgeRunning {
            let bridge = watchBridge
            send = { text, id in await bridge.sendNotificationReply(text, to: id) }
        }
        textReplies.dependencies = NotificationTextReplies.Dependencies(
            send: send,
            agent: { [unowned self] id in self.appModel.console.agents.first { $0.id == id } },
            keepAsDraft: { [unowned self] text, id in
                self.appModel.agentActions.keepAsDraft(text, for: id)
            },
            notify: NotificationTextReplies.postLocalNotification(title:body:))
    }

    /// Every scene that connects, new or restored from a saved session,
    /// posts `UIScene.willConnectNotification`; the first app window or
    /// CarPlay scene among them starts the Host dials, ahead of its window's
    /// layout (#105). `configurationForConnecting` runs only for new scene
    /// sessions, so a relaunch restoring one would not dial early there. A
    /// background launch connects no scene and dials nothing;
    /// `connectAtLaunch` dials once.
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        sceneConnectionObserver = NotificationCenter.default.addObserver(
            forName: UIScene.willConnectNotification, object: nil, queue: .main
        ) { [weak self] notification in
            // Delivered on the main queue, where the posting scene lives.
            nonisolated(unsafe) let notification = notification
            MainActor.assumeIsolated {
                // The Keychain probe only matters until the dials start.
                guard let self, !self.appModel.hasStartedDials,
                    Self.startsDials(
                        forConnecting: notification,
                        keychainReadable: KeychainReadability.isReadable())
                else { return }
                self.appModel.connectAtLaunch()
            }
        }
        return true
    }

    /// Gives a CarPlay session the CarPlay scene's delegate. Windows keep
    /// SwiftUI's own scene configuration plus the quick-action callback,
    /// and the action that cold-launched the app, if any, is posted.
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if connectingSceneSession.role == .carTemplateApplication {
            let configuration = UISceneConfiguration(
                name: "CarPlay", sessionRole: connectingSceneSession.role)
            configuration.sceneClass = CPTemplateApplicationScene.self
            configuration.delegateClass = CarPlaySceneDelegate.self
            return configuration
        }
        if let item = options.shortcutItem, let action = QuickAction(shortcutType: item.type) {
            quickActions.post(action)
        }
        let configuration = UISceneConfiguration(
            name: connectingSceneSession.configuration.name,
            sessionRole: connectingSceneSession.role)
        configuration.delegateClass = QuickActionSceneDelegate.self
        return configuration
    }

    /// Whether a connecting scene starts the Host dials (#105): only an app
    /// window the user will see or the CarPlay scene, with the Keychain
    /// readable. A locked phone qualifies: the secrets are
    /// `AfterFirstUnlock`, and a CarPlay launch with the phone in a pocket
    /// must dial (docs/design/carplay.md §6); below iOS 26.4 the CarPlay
    /// scene shows only a static screen and dials nothing. Not in the Debug
    /// screenshot mode, which never builds the production stores.
    static func startsDials(
        forConnecting notification: Notification, keychainReadable: Bool
    ) -> Bool {
        guard let scene = notification.object as? UIScene else { return false }
        return startsDials(connecting: scene.session.role, keychainReadable: keychainReadable)
    }

    static func startsDials(
        connecting role: UISceneSession.Role, keychainReadable: Bool,
        carPlaySupported: Bool = CarPlaySupport.isAvailable
    ) -> Bool {
        #if DEBUG && targetEnvironment(simulator)
            if DemoScreenshotMode.isEnabled { return false }
        #endif
        let shows =
            role == .windowApplication || (role == .carTemplateApplication && carPlaySupported)
        return shows && keychainReadable
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        registration.deviceTokenDidArrive(deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {
        registration.registrationDidFail(error)
    }
}

/// Sends a Done notification's typed reply (below iOS 26) through the watch
/// bridge, which wakes the app, waits for the Host, and sends only to a
/// listed Agent. A reply is never dropped silently: one that wasn't sent
/// becomes the Agent's Composer draft (unless sending already kept it
/// there) and a local notification says so; one with nothing left to send
/// after cleanup asks to be sent again; one that may have been delivered is
/// reported as such and kept nowhere, so it is never sent twice. A reply
/// that never reaches here (no Agent the envelope names) is reported by
/// `AgentNotificationCenterDelegate`. Built before the bridge exists (the
/// notification delegate is), so `willFinishLaunching` connects it.
@MainActor
final class NotificationTextReplies {
    /// What a reply goes through, as closures so tests run it against fakes.
    struct Dependencies {
        /// The watch bridge's `sendNotificationReply`; nil where no bridge
        /// runs, so every reply is kept as a draft.
        var send: (@MainActor (String, ConsoleAgent.ID) async -> AgentActionService.SendOutcome)?
        /// The Agent's Console row, for its title and its draft; nil when the
        /// Console doesn't have it.
        var agent: @MainActor (ConsoleAgent.ID) -> ConsoleAgent?
        /// `AgentActionService.keepAsDraft`.
        var keepAsDraft: @MainActor (String, ConsoleAgent.ID) -> Void
        /// Posts a local notification with this title and body.
        var notify: @MainActor (_ title: String, _ body: String) -> Void
    }

    /// The local notification's copy.
    enum Copy {
        /// Kept as the draft.
        static let keptAsDraft = "Kept as a draft on your iPhone."
        /// It may have been delivered.
        static let notConfirmed = "Couldn't confirm it was delivered."
        /// The title when the Console has no row for the Agent.
        static let replyNotSent = "Reply not sent"
        /// Not sent, and no draft could be kept.
        static let sendAgain = "Open Waycar and send it again."
        /// The title for an unconfirmed reply when the Console has no row.
        static let yourReply = "Your reply"

        /// The title of a reply that wasn't sent: "Not sent to site · Codex".
        static func notSent(to title: String) -> String { "Not sent to \(title)" }
    }

    /// Set in `willFinishLaunching`, before any reply can arrive.
    var dependencies: Dependencies?

    /// Sends `text` to the Agent, without the CarPlay reply suffix, and
    /// tells the user when it didn't go out.
    func send(_ text: String, to agentID: ConsoleAgent.ID) async {
        guard let dependencies else { return }
        guard !AgentActionService.hygienic(text).isEmpty else {
            dependencies.notify(Copy.replyNotSent, Copy.sendAgain)
            return
        }
        let outcome = await dependencies.send?(text, agentID)
        let identity = dependencies.agent(agentID).map { AgentGlanceList.title(for: $0) }
        switch outcome {
        case .sent:
            return
        case .unknown:
            dependencies.notify(identity ?? Copy.yourReply, Copy.notConfirmed)
        case .keptAsDraft:
            dependencies.notify(identity.map(Copy.notSent(to:)) ?? Copy.replyNotSent, Copy.keptAsDraft)
        case .notSent, nil:
            guard let identity else {
                dependencies.notify(Copy.replyNotSent, Copy.sendAgain)
                return
            }
            dependencies.keepAsDraft(text, agentID)
            dependencies.notify(Copy.notSent(to: identity), Copy.keptAsDraft)
        }
    }

    /// Posts a local notification now; with the phone locked it shows on
    /// the watch.
    static func postLocalNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
