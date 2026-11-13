import Foundation
import Observation

/// The one-time Notification Ask (#71): once the user has spent time on an
/// Agent, Waycar asks whether to turn on Agent Notifications and Live
/// Activities for every Host on this device, for the Hosts in the catalog
/// now and those this device meets later. Before iOS has asked for
/// notification permission the sheet is the message right before the iOS
/// prompt, so it offers only Continue, which always goes on to that prompt
/// (`actions`); the user's answer there is the answer. Once iOS allows
/// notifications it is an in-app opt-in with Turn On and Not Now. Either
/// answer is final for this install.
///
/// It needs one Agent Session on this install (`AgentSessionClock`), then
/// waits for a natural break: the user returning to the Console, or Waycar
/// coming back to the foreground. Nothing else counts sessions, so an
/// update of a long-used install is asked after its next one. App-wide, so
/// an iPad with several windows asks in one of them only.
///
/// Everything lives in this device's defaults, never iCloud, so a reinstall
/// asks again: the answer, the session flag, the Hosts Turn On still has to
/// finish, and the Hosts it has already seen.
@MainActor
@Observable
final class NotificationAsk {
    enum Answer: String, Equatable, Sendable {
        case accepted
        case declined
    }

    /// One button the sheet shows.
    enum Action: Hashable, Sendable {
        /// Goes on to the iOS permission prompt; turns on like Turn On.
        case `continue`
        case turnOn
        case notNow

        var title: String {
            switch self {
            case .continue: NotificationPrivacyCopy.continueToPrompt
            case .turnOn: NotificationAskCopy.turnOn
            case .notNow: NotificationAskCopy.notNow
            }
        }

        /// Whether the button turns the ask down instead of going ahead.
        var declines: Bool { self == .notNow }
    }

    /// The buttons a screen about notifications offers for a push state.
    /// A screen shown right before the iOS permission prompt
    /// (`.needsPermission`) offers Continue alone, and it always leads to
    /// that prompt (App Review guideline 5.1.1(iv)): no way out but through
    /// the prompt. Once iOS allows notifications (`.waitingForToken`, then
    /// `.registered`) no system prompt follows, so the ask is an in-app
    /// opt-in: Turn On or Not Now. Where turning on is impossible
    /// (`.denied`) or the state is not known (`.unknown`, `.failed`) there
    /// is nothing to offer and the ask closes (`pushStateDidChange`).
    nonisolated static func actions(for state: PushRegistrationStore.State) -> [Action] {
        switch state {
        case .needsPermission: [.continue]
        case .waitingForToken, .registered: [.turnOn, .notNow]
        case .unknown, .denied, .failed: []
        }
    }

    /// The buttons for the push state now.
    var actions: [Action] { Self.actions(for: pushRegistration.state) }

    /// The unit-test host and previews never ask.
    static var isSuppressedInThisProcess: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

    /// The answer this process knows. Turn On sets it at once, so the sheet
    /// closes, but stores it only once the iOS prompt has been answered.
    var answer: Answer? { ask.answer }
    /// The window asking; nil while none is.
    var sceneID: UUID? { ask.sceneID }
    private var ask: NotificationAskMachine

    @ObservationIgnored private var hadAgentSession: Bool
    /// Enrollment intent and per-Host write exclusion; completed Hosts stay
    /// seen so turning one off later never opts it back in.
    @ObservationIgnored private var enrollment: NotificationEnrollmentMachine
    /// The launch's first window to activate (`isLaunchWindow`).
    @ObservationIgnored private var launchSceneID: UUID?

    @ObservationIgnored private let pushRegistration: PushRegistrationStore
    @ObservationIgnored private let preferences: NotificationPreferencesStore
    @ObservationIgnored private let liveActivities: HostLiveActivityCoordinator
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults
    @ObservationIgnored private let isDisabled: Bool

    private static let answerKey = "notification-ask.answer"
    private static let sessionKey = "notification-ask.had-agent-session"
    private static let pendingKey = "notification-ask.pending-hosts"
    private static let seenKey = "notification-ask.seen-hosts"

    /// The Host catalog is `preferences.hosts`, the one registrations act on.
    init(
        pushRegistration: PushRegistrationStore,
        preferences: NotificationPreferencesStore,
        liveActivities: HostLiveActivityCoordinator,
        defaults: UserDefaults = .standard,
        isDisabled: Bool
    ) {
        self.pushRegistration = pushRegistration
        self.preferences = preferences
        self.liveActivities = liveActivities
        self.defaults = defaults
        self.isDisabled = isDisabled
        ask = NotificationAskMachine(
            answer: defaults.string(forKey: Self.answerKey).flatMap(Answer.init(rawValue:)))
        hadAgentSession = defaults.bool(forKey: Self.sessionKey)
        enrollment = NotificationEnrollmentMachine(
            seen: Self.readIDs(defaults, Self.seenKey),
            pending: Self.readIDs(defaults, Self.pendingKey))
    }

    /// Whether asking would offer anything: never answered, an Agent
    /// Session behind it, permission not refused, and something still off:
    /// notifications never allowed on this device, a Host this device is not
    /// registered on, or a registered Host with its Live Activity off while
    /// iOS allows them. Hosts whose state is unknown (unreachable, loading)
    /// count for nothing either way.
    var isEligible: Bool {
        guard !isDisabled, answer == nil, hadAgentSession else { return false }
        let hosts = preferences.hosts
        guard !hosts.isEmpty else { return false }
        switch pushRegistration.state {
        case .needsPermission:
            return true
        case .registered:
            return hosts.contains { hasSomethingOff($0.id) }
        case .unknown, .denied, .waitingForToken, .failed:
            return false
        }
    }

    /// A window showed one Agent long enough (`AgentSessionClock`).
    func noteAgentSession() {
        guard !hadAgentSession else { return }
        hadAgentSession = true
        defaults.set(true, forKey: Self.sessionKey)
    }

    /// Whether `sceneID` is this launch's first window to activate: its
    /// opening is a break (`AgentSessionClock`), a later window's is not.
    /// The first window to ask claims it; asking again gives the same answer.
    func isLaunchWindow(_ sceneID: UUID) -> Bool {
        if launchSceneID == nil { launchSceneID = sceneID }
        return launchSceneID == sceneID
    }

    /// Only while it has something to offer: a push state that leaves no
    /// action closes the sheet.
    func isShown(inScene sceneID: UUID) -> Bool {
        answer == nil && self.sceneID == sceneID && !actions.isEmpty
    }

    /// Shows the ask in this window at a natural break, unless another
    /// window already does or it is not eligible.
    func present(inScene sceneID: UUID) {
        _ = ask.handle(.present(sceneID, eligible: isEligible))
    }

    /// A window closing mid-ask drops it; the next break asks again.
    func release(sceneID: UUID) {
        _ = ask.handle(.release(sceneID))
    }

    /// Closes an ask the push state leaves nothing to offer, say after the
    /// user answered the iOS prompt from Settings in another window while
    /// it was up. Don't Allow ends it like Not Now; an unknown or failed
    /// state only drops it, so the next break asks again.
    func pushStateDidChange() {
        guard actions.isEmpty else { return }
        persistAnswer(ask.handle(.unavailable(denied: pushRegistration.state == .denied)))
    }

    /// Not Now: offered only once iOS allows notifications (`actions`), and
    /// what Don't Allow from elsewhere amounts to (`pushStateDidChange`).
    func decline() {
        persistAnswer(ask.handle(.decline))
    }

    /// Continue or Turn On. Closes the sheet at once and marks every Host
    /// not fully on as pending. When iOS has never asked (Continue), shows
    /// its prompt first (the sheet already showed the disclosure); the ask
    /// is stored as answered once the prompt is, Allow or Don't Allow, so a
    /// prompt cut short by the app being killed, or one that fails, leaves
    /// the ask to come back. Don't Allow ends it like Not Now: no Host is
    /// registered and no Live Activity turned on, now or once notifications
    /// are allowed later.
    func turnOn() async {
        await performAsk(ask.handle(.turnOn(needsPermission: pushRegistration.state == .needsPermission)))
    }

    /// Moves Turn On along; the app calls it whenever the push state, the
    /// Host catalog, or a Host's registration state changes. A Host this
    /// device is confirmed not registered on gets registered; once it is
    /// registered its Live Activity goes on and it is done. Unknown Hosts
    /// wait. A failed write leaves the Host `.failed`, which is skipped
    /// until its next fresh read, so a failure retries on the next
    /// connection or token change and never loops. While notifications are
    /// off in the Settings app it waits, Hosts added meanwhile included, and
    /// finishes once they are back on.
    func processPending() async {
        guard ask.canEnroll,
            pushRegistration.state != .denied
        else { return }
        let hosts = preferences.hosts
        await performEnrollment(enrollment.handle(.discover(Set(hosts.map(\.id)))))
        guard pushRegistration.deviceToken != nil else { return }
        for host in hosts {
            let registration: NotificationEnrollmentMachine.Registration
            if case .idle(let settings) = preferences.states[host.id], !settings.isRegistered {
                registration = .idleUnregistered
            } else if isConfirmedRegistered(host.id) == true {
                registration = .registered
            } else {
                registration = .unknownOrFailed
            }
            await performEnrollment(enrollment.handle(.consider(
                host.id, registration, liveEnabled: liveActivities.isEnabled(for: host.id))), host: host)
        }
    }

    /// Synchronous ask entrypoints can only emit answer persistence.
    private func persistAnswer(_ effects: [NotificationAskMachine.Effect]) {
        for effect in effects {
            if case .persist(let answer) = effect {
                defaults.set(answer.rawValue, forKey: Self.answerKey)
            }
        }
    }

    private func performAsk(_ effects: [NotificationAskMachine.Effect]) async {
        for effect in effects {
            switch effect {
            case .initializeEnrollment:
                let hosts = preferences.hosts
                _ = enrollment.handle(.initialize(
                    seen: Set(hosts.map(\.id)),
                    pending: Set(hosts.map(\.id).filter {
                        !(isConfirmedRegistered($0) == true && liveActivities.isEnabled(for: $0))
                    })))
            case .clearEnrollment:
                _ = enrollment.handle(.clear)
            case .requestPermission(let token):
                await pushRegistration.enable()
                let result: NotificationAskMachine.Permission
                switch pushRegistration.state {
                case .denied: result = .denied
                case .failed: result = .failed
                case .unknown, .needsPermission, .waitingForToken, .registered: result = .allowed
                }
                await performAsk(ask.handle(.permissionFinished(token, result)))
            case .persist(let answer):
                defaults.set(answer.rawValue, forKey: Self.answerKey)
            case .saveEnrollment:
                save()
            case .processEnrollment:
                await processPending()
            }
        }
    }

    private func performEnrollment(
        _ effects: [NotificationEnrollmentMachine.Effect], host: Host? = nil
    ) async {
        for effect in effects {
            switch effect {
            case .register(let id, let token):
                guard let host, host.id == id else { continue }
                await preferences.setNotificationsEnabled(true, for: host)
                await performEnrollment(enrollment.handle(.registered(
                    id, token: token, confirmed: isConfirmedRegistered(id) == true,
                    liveEnabled: liveActivities.isEnabled(for: id))))
            case .enableLiveActivity(let id):
                liveActivities.setEnabled(true, for: id)
            case .save:
                save()
            }
        }
    }

    private func hasSomethingOff(_ hostID: Host.ID) -> Bool {
        switch isConfirmedRegistered(hostID) {
        case false?:
            true
        case true?:
            liveActivities.areActivitiesEnabled && !liveActivities.isEnabled(for: hostID)
        case nil:
            false
        }
    }

    /// The Host's last confirmed answer; nil while unknown.
    private func isConfirmedRegistered(_ hostID: Host.ID) -> Bool? {
        switch preferences.states[hostID] {
        case .idle(let settings), .failed(_, let settings):
            settings.isRegistered
        case .loading, .unavailable, .updating, nil:
            nil
        }
    }

    private func save() {
        defaults.set(enrollment.pending.map(\.uuidString).sorted(), forKey: Self.pendingKey)
        defaults.set(enrollment.seen.map(\.uuidString).sorted(), forKey: Self.seenKey)
    }

    private static func readIDs(_ defaults: UserDefaults, _ key: String) -> Set<Host.ID> {
        Set((defaults.stringArray(forKey: key) ?? []).compactMap(UUID.init(uuidString:)))
    }
}

/// One window's Agent screen time and its natural breaks, for the
/// Notification Ask. An Agent Session is one Agent shown for
/// `sessionLength` of continuous foreground time; it is counted when the
/// window leaves that Agent or goes to the background. A break is the user
/// returning to the Console, or the window coming back to the foreground
/// from the background. A window's own opening is a break only for the
/// launch's first window: a window opened later (Open in New Window, a
/// dragged row) opens on what the user just asked for. Moving between
/// Agents is never a break, and a re-keyed pane (a move) is the same
/// Agent, so its time carries over. A foreground return that a notification,
/// Live Activity, or link tap brought about is the user going somewhere,
/// not a break.
struct AgentSessionClock: Equatable, Sendable {
    typealias Instant = ContinuousClock.Instant

    static let sessionLength: Duration = .seconds(20)
    /// How long before a foreground break a route request still counts as
    /// what brought the app forward: a tap is routed while the scene is
    /// still inactive.
    static let routeRequestLead: Duration = .seconds(3)

    /// A moment the ask may show, once it has settled and still holds.
    struct Break: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case returnedToConsole
            case cameToForeground
        }

        let kind: Kind
        /// The navigation it followed; any later one cancels it.
        fileprivate let navigation: UInt64
        fileprivate let at: Instant

        /// Lets the navigation transition, or the foreground return, finish.
        var settle: Duration {
            switch kind {
            case .returnedToConsole: .milliseconds(500)
            case .cameToForeground: .seconds(1)
            }
        }
    }

    struct Change: Equatable, Sendable {
        /// The Agent just left (or backgrounded) made an Agent Session.
        var endedSession = false
        var newBreak: Break?
    }

    private(set) var shownAgent: ConsoleAgent.ID?
    /// Start of the current foreground stretch on `shownAgent`.
    private var shownSince: Instant?
    private var isForeground = false
    /// Whether this window has been active before, so the next activation
    /// is a return rather than its opening.
    private var hasBeenActive = false
    private var navigation: UInt64 = 0

    init() {}

    mutating func pathDidChange(
        to agent: ConsoleAgent.ID?, isRetarget: Bool, at now: Instant
    ) -> Change {
        guard agent != shownAgent else { return Change() }
        if isRetarget {
            shownAgent = agent
            return Change()
        }
        let left = shownAgent
        let ended = endsSession(at: now)
        shownAgent = agent
        shownSince = agent != nil && isForeground ? now : nil
        navigation &+= 1
        let newBreak =
            left != nil && agent == nil
            ? Break(kind: .returnedToConsole, navigation: navigation, at: now) : nil
        return Change(endedSession: ended, newBreak: newBreak)
    }

    mutating func didEnterBackground(at now: Instant) -> Change {
        guard isForeground else { return Change() }
        let ended = endsSession(at: now)
        isForeground = false
        shownSince = nil
        return Change(endedSession: ended)
    }

    /// A return from the background is a break, and so is the opening of
    /// the launch's first window (`isLaunchWindow`); an `.inactive` blip in
    /// between is not.
    mutating func didBecomeActive(at now: Instant, isLaunchWindow: Bool) -> Change {
        guard !isForeground else { return Change() }
        isForeground = true
        if shownAgent != nil { shownSince = now }
        let isOpening = !hasBeenActive
        hasBeenActive = true
        guard !isOpening || isLaunchWindow else { return Change() }
        return Change(
            newBreak: Break(kind: .cameToForeground, navigation: navigation, at: now))
    }

    /// The break still stands after its settle: no navigation since, and
    /// a return to the Console is still on the Console. A foreground break
    /// also falls to a route request (`AgentNotificationRouter.open`) made
    /// just before it or any time since, even one for the Agent already on
    /// screen, which moves no navigation. A restored route is no request:
    /// returning to the screen the user left is a break.
    func stillHolds(_ brk: Break, lastRouteRequest: Instant?) -> Bool {
        guard brk.navigation == navigation else { return false }
        switch brk.kind {
        case .returnedToConsole:
            return shownAgent == nil
        case .cameToForeground:
            guard let lastRouteRequest else { return true }
            return lastRouteRequest < brk.at - Self.routeRequestLead
        }
    }

    private func endsSession(at now: Instant) -> Bool {
        guard shownAgent != nil, let shownSince else { return false }
        return now - shownSince >= Self.sessionLength
    }
}
