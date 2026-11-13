import Foundation
import UserNotifications

/// Thin UNUserNotificationCenter delegate (#74). Every decision is pure and
/// unit-tested — `AgentNotificationRouting` resolves the push,
/// `AgentDeepLinkPolicy` picks the window, and each window's MainActor
/// `AgentNotificationRouter` holds its navigation state — because real iOS
/// notification presentation is not automatable (spec #68).
///
/// The completion-handler forms are deliberate: UIKit invokes these callbacks
/// on a background queue, and the tap completion drives main-thread-only
/// UIKit state restoration (SIGABRT otherwise). The async forms hand the
/// completion to whatever executor the continuation resumes on, so only the
/// handler forms let us pin it to the main thread. The push is resolved on
/// the callback queue; only the Sendable target crosses.
final class AgentNotificationCenterDelegate: NSObject, UNUserNotificationCenterDelegate,
    @unchecked Sendable
{
    private let directory: AgentSceneDirectory
    /// Counts taps (`notification_opened`) and nothing about the push itself.
    private let analytics: (any Analytics)?
    private let loadKeys: @Sendable () -> [NotificationKeyRecord]
    /// Whether a phone or iPad window is on screen, active or not; read on
    /// the callback queue (`PhoneWindowPresence`).
    private let isPhoneWindowOnScreen: @Sendable () -> Bool
    /// What the CarPlay voice is doing; read on the callback queue.
    private let carVoice: @Sendable () -> CarVoiceActivity.State
    /// Queues a Blocked push for the car to announce after its line.
    private let queueAnnouncement: @Sendable (CarVoiceActivity.PendingAnnouncement) -> Void
    /// The app's badge, once the app model exists; a foreground push hands
    /// the badge back to it.
    @MainActor weak var attentionBadge: AttentionBadgeCoordinator?
    /// The in-app banner, once the app model exists; a foreground push hands
    /// it the Agent Summary the silenced system banner would have shown.
    @MainActor weak var bannerStore: AgentNotificationBannerStore?
    /// Sends a Reply typed into a notification's text input to its Agent;
    /// nil reports every typed reply as not sent (nothing wired to send it).
    private let sendTextReply: (@MainActor (AgentNotificationTarget, String) async -> Void)?
    /// Posts a local notification with this title and body: tells the user
    /// a typed reply that had nowhere to go was not sent.
    private let notify: @MainActor (_ title: String, _ body: String) -> Void

    init(
        directory: AgentSceneDirectory,
        isPhoneWindowOnScreen: @escaping @Sendable () -> Bool,
        carVoice: @escaping @Sendable () -> CarVoiceActivity.State = {
            CarVoiceActivity.shared.state
        },
        queueAnnouncement: @escaping @Sendable (CarVoiceActivity.PendingAnnouncement) -> Void = {
            CarVoiceActivity.shared.enqueue($0)
        },
        analytics: (any Analytics)? = nil,
        loadKeys: @escaping @Sendable () -> [NotificationKeyRecord] = {
            (try? NotificationKeyStore().allRecords()) ?? []
        },
        sendTextReply: (@MainActor (AgentNotificationTarget, String) async -> Void)? = nil,
        notify: @escaping @MainActor (_ title: String, _ body: String) -> Void = { title, body in
            NotificationTextReplies.postLocalNotification(title: title, body: body)
        }
    ) {
        self.directory = directory
        self.isPhoneWindowOnScreen = isPhoneWindowOnScreen
        self.carVoice = carVoice
        self.queueAnnouncement = queueAnnouncement
        self.analytics = analytics
        self.loadKeys = loadKeys
        self.sendTextReply = sendTextReply
        self.notify = notify
    }

    /// Pushes never present while a window is on screen (#77): there the
    /// live event stream announces transitions through the in-app banner
    /// (`AgentNotificationBannerStore`), so the system banner, list entry,
    /// sound, and badge are fully silenced, and the push hands the in-app
    /// banner the decrypted Agent Summary the live stream lacks. Foreground
    /// without a window on screen means CarPlay holds the app while the
    /// phone is locked or in another app: no in-app banner can show, so the
    /// system presents the push to the Lock Screen and the Watch as it would
    /// for a backgrounded app (docs/design/carplay.md §6). Either way the
    /// extension has already folded the push's attention count into the
    /// stored per-Host counts, and that count can be older than the app's
    /// live one, so the app re-asserts its live counts and sets the badge
    /// itself. Background and killed-state delivery is untouched —
    /// willPresent only runs for a foregrounded app.
    ///
    /// A CarPlay voice turn presents pushes quietly (ADR 0008 amendment):
    /// a banner's sound takes the audio session and cuts the spoken reply,
    /// and the reply being spoken is the Agent's own Done. A quieted push
    /// still reaches Notification Center, the Lock Screen and the Watch
    /// (`.list` only), and a Blocked push from another Agent is queued for
    /// the car to announce after its line. The turn's Agent stays quiet for
    /// the whole turn; every Agent while the car speaks or listens.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions)
            -> Void
    ) {
        let windowOnScreen = isPhoneWindowOnScreen()
        let push = AgentNotificationRouting.resolve(
            userInfo: notification.request.content.userInfo, keys: loadKeys())
        let voice = carVoice()
        let options = Self.presentationOptions(
            phoneWindowOnScreen: windowOnScreen, target: push?.target, carVoice: voice)
        if let push,
            let pending = Self.pendingAnnouncement(
                target: push.target, payload: push.payload, carVoice: voice)
        {
            queueAnnouncement(pending)
        }
        Task { @MainActor [weak self] in
            self?.attentionBadge?.pushDidArrive()
            // The in-app banner applies the same CarPlay voice gate, deferring
            // its banner until the turn ends.
            if windowOnScreen, let push {
                self?.bannerStore?.pushDidArrive(target: push.target, payload: push.payload)
            }
        }
        completionHandler(options)
    }

    /// Silent while a window shows the in-app banner; list-only (no banner,
    /// no sound) while the CarPlay voice quiets `target`; otherwise what a
    /// backgrounded app's push gets, less the badge the app sets itself.
    static func presentationOptions(
        phoneWindowOnScreen: Bool, target: AgentNotificationTarget?,
        carVoice: CarVoiceActivity.State
    ) -> UNNotificationPresentationOptions {
        guard !phoneWindowOnScreen else { return [] }
        guard !carVoice.quiets(target) else { return [.list] }
        return [.banner, .list, .sound]
    }

    /// A Blocked push from an Agent other than the turn's, arriving while
    /// the car speaks or listens, is announced by the car after its line:
    /// the driver must hear that an Agent waits on them.
    static func pendingAnnouncement(
        target: AgentNotificationTarget, payload: NotificationPayload,
        carVoice: CarVoiceActivity.State
    ) -> CarVoiceActivity.PendingAnnouncement? {
        guard payload.status == .blocked, carVoice.isBusy(),
            target.agentID != carVoice.agent
        else { return nil }
        return CarVoiceActivity.PendingAnnouncement(
            target: target, alert: AgentNotificationRenderer.alert(for: payload))
    }

    /// What a notification response asks the iPhone to do.
    enum ResponseAction: Equatable, Sendable {
        /// Deep-link to the Agent through the single-window rule.
        case open
        /// Send the text typed into the Reply text input to the Agent.
        case sendText(String)
        /// Route nowhere (dismissal, unknown action, empty text).
        case ignore
    }

    /// The tap (default action) and the Open, Review and Reply buttons
    /// chosen on the iPhone open the Agent; a Reply typed into the text
    /// input sends that text; anything else routes nowhere.
    static func responseAction(actionIdentifier: String, userText: String?) -> ResponseAction {
        switch actionIdentifier {
        case UNNotificationDefaultActionIdentifier, AgentNotificationCategories.openAction,
            AgentNotificationCategories.reviewAction, AgentNotificationCategories.replyAction:
            return .open
        case AgentNotificationCategories.textReplyAction:
            guard let userText,
                !userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return .ignore }
            return .sendText(userText)
        default:
            return .ignore
        }
    }

    /// Resolves the response on the callback queue, then acts on the main
    /// actor and completes only after a text reply's send returns, so iOS
    /// keeps the app running for the whole send.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = Self.responseAction(
            actionIdentifier: response.actionIdentifier,
            userText: (response as? UNTextInputNotificationResponse)?.userText)
        let target = resolveTarget(
            for: action, userInfo: response.notification.request.content.userInfo)
        let complete = UncheckedSendable(completionHandler)
        Task { @MainActor [self] in
            await respond(action, target: target)
            complete.value()
        }
    }

    /// The Agent `action` acts on. A typed reply sends only to the Agent
    /// named inside the envelope this device decrypts: the plaintext ids are
    /// unauthenticated, so they never pick a pane to type into. Opening may
    /// fall back to them (the envelope may be unreadable while the device
    /// is locked); the worst a forged id does there is open a screen.
    func resolveTarget(for action: ResponseAction, userInfo: [AnyHashable: Any])
        -> AgentNotificationTarget?
    {
        if action == .ignore { return nil }
        if let target = AgentNotificationRouting.target(userInfo: userInfo, keys: loadKeys()) {
            return target
        }
        guard action == .open else { return nil }
        guard let ids = AgentNotificationCategories.target(from: userInfo) else { return nil }
        return AgentNotificationTarget(hostID: ids.hostID, paneID: ids.paneID)
    }

    /// Acts on a resolved response. Open with no target lands on the
    /// Console. A text reply with no target (an envelope this device can't
    /// decrypt) or no sender sends nothing, and a local notification asks
    /// the user to send it again: a typed reply is never dropped silently.
    @MainActor
    func respond(_ action: ResponseAction, target: AgentNotificationTarget?) async {
        switch action {
        case .open:
            directory.open(target)
            analytics?.capture(.notificationOpened)
        case .sendText(let text):
            guard let target, let sendTextReply else {
                notify(
                    NotificationTextReplies.Copy.replyNotSent, NotificationTextReplies.Copy.sendAgain)
                return
            }
            await sendTextReply(target, text)
        case .ignore:
            return
        }
    }
}

/// Carries UIKit's non-Sendable completion handlers to the main actor; each
/// is invoked exactly once there.
private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
