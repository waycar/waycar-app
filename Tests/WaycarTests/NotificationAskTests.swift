import Foundation
import Testing
import UserNotifications

@testable import Waycar

/// The one-time Notification Ask (#71): when it asks, and what each answer
/// does to this device's registration and Live Activity on every Host.
/// Driven through the real push, preference, and Live Activity stores, with
/// only the system push boundary, ActivityKit, and the Hosts scripted.
@MainActor
@Suite("Notification Ask")
final class NotificationAskTests {
    private let host = Host(name: "mac-studio", address: "10.0.0.2", username: "z")
    private let tokenData = Data([0x0a, 0x1b, 0x2c, 0x3d])
    private let transport = ScriptedTransport()
    private let controller = FakeLiveActivityController()
    private let suiteName = "notification-ask-\(UUID().uuidString)"
    private let defaults: UserDefaults
    /// The system push boundary: permission status, the prompt's answer.
    private let scripted = ScriptedPushRegistrationClient()
    private let provider: ScriptedTransportProvider
    private let push: PushRegistrationStore
    private let preferences: NotificationPreferencesStore
    private let liveActivities: HostLiveActivityCoordinator

    convenience init() throws {
        try self.init(prompt: nil)
    }

    /// `prompt` stands in for the iOS permission prompt instead of the
    /// scripted one.
    init(prompt: (any PushRegistrationClient)?) throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
        let client = prompt ?? scripted
        let provider = ScriptedTransportProvider(transports: [host.id: transport])
        self.provider = provider
        let push = PushRegistrationStore(client: client, environment: .sandbox)
        self.push = push
        let keys = NotificationKeyStore(secrets: InMemorySecretStore())
        let preferences = NotificationPreferencesStore(
            transports: provider,
            deviceToken: { push.deviceToken },
            ceremony: NotificationRegistrationCeremony(keys: keys))
        preferences.setHosts([host])
        self.preferences = preferences
        liveActivities = HostLiveActivityCoordinator(
            controller: controller,
            preferences: LiveActivityPreferences(defaults: defaults),
            transports: provider,
            keys: keys,
            ceremony: NotificationRegistrationCeremony(keys: keys),
            deviceToken: { push.deviceToken },
            knownHostIDs: { [] },
            hostDisplayName: { _ in "" },
            isAwaitingSnapshot: { _ in true },
            connectionStatus: { _ in nil })
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    /// The store as a launch builds it, on an install that has already had
    /// an Agent Session unless told otherwise.
    private func makeAsk(hadAgentSession: Bool = true) -> NotificationAsk {
        let ask = NotificationAsk(
            pushRegistration: push, preferences: preferences, liveActivities: liveActivities,
            defaults: defaults, isDisabled: false)
        if hadAgentSession { ask.noteAgentSession() }
        return ask
    }

    /// iOS has never asked for notification permission on this device.
    private func permissionNotDetermined() async {
        scripted.status = .notDetermined
        await push.refresh()
    }

    /// Permission granted earlier; the token lands and each Host's
    /// registration file is read.
    private func permissionGrantedWithToken() async {
        scripted.status = .authorized
        await push.refresh()
        push.deviceTokenDidArrive(tokenData)
        await preferences.refresh()
    }

    private func isRegistered(on transport: ScriptedTransport) async throws -> Bool {
        let token = try #require(push.deviceToken)
        return try NotificationRegistrationFile.decode(await transport.notificationRegistration)
            .containsDevice(token: token.hex)
    }

    private func registrationWrites(on transport: ScriptedTransport) async -> Int {
        await transport.replacedNotificationRegistrations.count
    }

    // MARK: When it asks

    @Test(arguments: [true, false])
    func anAnsweredAskNeverAsksAgain(turnOn: Bool) async {
        await permissionGrantedWithToken()
        await preferences.setNotificationsEnabled(true, for: host)
        let ask = makeAsk()
        #expect(ask.isEligible)

        if turnOn {
            await ask.turnOn()
        } else {
            ask.decline()
        }
        // Something is off again, so only the answer keeps it from asking.
        liveActivities.setEnabled(false, for: host.id)

        #expect(!ask.isEligible)
        #expect(!makeAsk().isEligible)
    }

    @Test func deniedPermissionNeverAsks() async {
        scripted.status = .denied
        await push.refresh()

        #expect(!makeAsk().isEligible)
    }

    @Test func everythingAlreadyOnDoesNotAsk() async {
        await permissionGrantedWithToken()
        await preferences.setNotificationsEnabled(true, for: host)
        liveActivities.setEnabled(true, for: host.id)

        #expect(!makeAsk().isEligible)
    }

    @Test func noTokenYetWithAHostAsks() async {
        await permissionNotDetermined()

        #expect(makeAsk().isEligible)
    }

    @Test func noAskBeforeAnyAgentSession() async {
        await permissionNotDetermined()

        #expect(!makeAsk(hadAgentSession: false).isEligible)
    }

    @Test func aRegisteredHostWithItsLiveActivityOffAsksWhileIOSAllowsThem() async {
        await permissionGrantedWithToken()
        await preferences.setNotificationsEnabled(true, for: host)
        let ask = makeAsk()

        controller.areEnabled = true
        #expect(ask.isEligible)

        controller.areEnabled = false
        #expect(!ask.isEligible)
    }

    /// Nothing counts sessions before this update: an install that used
    /// Waycar long before it, with notifications allowed but this device
    /// never registered on its Host, has no stored answer and is asked
    /// after its next Agent Session, on this launch or a later one.
    @Test func anUpdateOfALongUsedInstallAsksAfterItsNextAgentSession() async {
        await permissionGrantedWithToken()
        let ask = makeAsk(hadAgentSession: false)
        #expect(!ask.isEligible)

        ask.noteAgentSession()

        #expect(ask.isEligible)
        #expect(makeAsk(hadAgentSession: false).isEligible)
    }

    @Test func aHostWhoseStateIsUnknownDoesNotMakeAFullyOnDeviceAsk() async {
        let unreachable = Host(name: "mini", address: "10.0.0.3", username: "z")
        preferences.setHosts([host, unreachable])
        await permissionGrantedWithToken()
        await preferences.setNotificationsEnabled(true, for: host)
        liveActivities.setEnabled(true, for: host.id)

        #expect(!makeAsk().isEligible)
    }

    /// Not Now is offered once iOS allows notifications (`actions`).
    @Test func notNowSurvivesRecreatingTheStore() async {
        await permissionGrantedWithToken()
        makeAsk().decline()

        let relaunched = makeAsk()

        #expect(relaunched.answer == .declined)
        #expect(!relaunched.isEligible)
    }

    @Test func onlyTheFirstWindowToActivateIsTheLaunchWindow() {
        let ask = makeAsk()
        let first = UUID()
        let opened = UUID()

        #expect(ask.isLaunchWindow(first))
        #expect(!ask.isLaunchWindow(opened))
        #expect(ask.isLaunchWindow(first))
    }

    @Test func oneWindowAsksAtATimeUntilItIsAnswered() async {
        await permissionGrantedWithToken()
        let ask = makeAsk()
        let windowA = UUID()
        let windowB = UUID()

        ask.present(inScene: windowA)
        ask.present(inScene: windowB)
        #expect(ask.isShown(inScene: windowA))
        #expect(!ask.isShown(inScene: windowB))

        // Window A closes before an answer; the next break asks in B.
        ask.release(sceneID: windowA)
        ask.present(inScene: windowB)
        #expect(ask.isShown(inScene: windowB))

        ask.decline()
        #expect(!ask.isShown(inScene: windowB))
    }

    @Test func onlyTheFirstAnswerCounts() async {
        await permissionGrantedWithToken()
        let ask = makeAsk()

        ask.decline()
        await ask.turnOn()

        #expect(makeAsk().answer == .declined)
        #expect(await registrationWrites(on: transport) == 0)
    }

    // MARK: What the sheet offers

    /// The hint under the story never names a button the sheet does not show.
    private func expectHintNamesOnlyShownButtons(_ actions: [NotificationAsk.Action]) {
        let hint = NotificationAskCopy.hint(for: actions)
        let all: [NotificationAsk.Action] = [.continue, .turnOn, .notNow]
        for hidden in all where !actions.contains(hidden) {
            #expect(!hint.contains(hidden.title), "\(hidden)")
        }
    }

    /// Right before the iOS permission prompt the sheet is the message that
    /// leads to it, so it offers Continue alone: no Not Now, nothing that
    /// closes it without the prompt (App Review guideline 5.1.1(iv)).
    @Test func beforeTheIOSPromptTheOnlyActionIsContinue() async {
        await permissionNotDetermined()
        let ask = makeAsk()

        #expect(ask.isEligible)
        #expect(ask.actions == [.continue])
        #expect(!ask.actions.contains { $0.declines })
        expectHintNamesOnlyShownButtons(ask.actions)
    }

    /// Once iOS allows notifications no system prompt follows: the sheet is
    /// an in-app opt-in with Turn On and Not Now.
    @Test func onceIOSAllowsNotificationsTheSheetOffersTurnOnOrNotNow() async {
        await permissionGrantedWithToken()
        let ask = makeAsk()

        #expect(ask.isEligible)
        #expect(ask.actions == [.turnOn, .notNow])
        expectHintNamesOnlyShownButtons(ask.actions)
    }

    /// Every push state, so a new one has to be decided here: Continue
    /// alone before the prompt, Turn On or Not Now once iOS allows
    /// notifications, nothing where turning on is impossible or unknown.
    @Test func eachPushStateOffersItsActions() {
        let token = APNSDeviceToken(tokenData: tokenData, environment: .sandbox)
        let states: [PushRegistrationStore.State] = [
            .unknown, .needsPermission, .denied, .waitingForToken, .registered(token), .failed("x"),
        ]
        for state in states {
            let expected: [NotificationAsk.Action] =
                switch state {
                case .needsPermission: [.continue]
                case .waitingForToken, .registered: [.turnOn, .notNow]
                case .unknown, .denied, .failed: []
                }
            let actions = NotificationAsk.actions(for: state)
            #expect(actions == expected, "\(state)")
            if actions.contains(.continue) {
                #expect(!actions.contains { $0.declines }, "\(state)")
            }
        }
    }

    /// Don't Allow answered elsewhere (Settings in another window) while
    /// the ask is up ends it like Not Now; it never turns into Turn On on a
    /// device that refused notifications.
    @Test func aRefusalElsewhereClosesTheAskAsNotNow() async {
        await permissionNotDetermined()
        let ask = makeAsk()
        let window = UUID()
        ask.present(inScene: window)
        #expect(ask.isShown(inScene: window))

        scripted.status = .denied
        await push.refresh()
        ask.pushStateDidChange()

        #expect(!ask.isShown(inScene: window))
        #expect(makeAsk().answer == .declined)
        #expect(await registrationWrites(on: transport) == 0)
    }

    /// A failed registration only closes the ask: it is not an answer.
    @Test func aFailedRegistrationWhileAskingOnlyClosesTheAsk() async {
        await permissionNotDetermined()
        let ask = makeAsk()
        let window = UUID()
        ask.present(inScene: window)

        push.registrationDidFail(ScriptedPushRegistrationClient.Failure())
        ask.pushStateDidChange()

        #expect(!ask.isShown(inScene: window))
        #expect(ask.answer == nil)
        #expect(makeAsk().answer == nil)
    }

    /// Continue records the ask as answered once the iOS prompt is,
    /// whichever way: it never comes back after Allow or Don't Allow.
    @Test(arguments: [true, false])
    func continueIsAnsweredWhateverTheIOSPromptSays(allow: Bool) async {
        await permissionNotDetermined()
        scripted.grantResult = .success(allow)
        let ask = makeAsk()

        await ask.turnOn()

        #expect(makeAsk().answer == (allow ? .accepted : .declined))
    }

    // MARK: Turn On

    @Test func nothingIsWrittenToAHostBeforeTurnOn() async {
        await permissionGrantedWithToken()
        let ask = makeAsk()

        await ask.processPending()

        #expect(await registrationWrites(on: transport) == 0)
        #expect(!liveActivities.isEnabled(for: host.id))
    }

    @Test func turnOnRequestsPermissionThenRegistersEachHostOnceAndTurnsOnItsLiveActivity()
        async throws
    {
        await permissionNotDetermined()
        scripted.grantResult = .success(true)
        let ask = makeAsk()

        await ask.turnOn()

        // The iOS prompt was shown and granted; the token is on its way.
        #expect(push.state == .waitingForToken)
        #expect(scripted.registerCallCount == 1)
        #expect(!liveActivities.isEnabled(for: host.id))

        push.deviceTokenDidArrive(tokenData)
        await preferences.refresh()
        await ask.processPending()
        await ask.processPending()

        #expect(try await isRegistered(on: transport))
        #expect(await registrationWrites(on: transport) == 1)
        #expect(liveActivities.isEnabled(for: host.id))
    }

    @Test func turnOnForARegisteredHostOnlyTurnsItsLiveActivityOn() async throws {
        await permissionGrantedWithToken()
        await preferences.setNotificationsEnabled(true, for: host)
        let writes = await registrationWrites(on: transport)

        await makeAsk().turnOn()

        #expect(liveActivities.isEnabled(for: host.id))
        #expect(await registrationWrites(on: transport) == writes)
    }

    @Test func anUnreachableHostStaysPendingUntilItIsAvailable() async throws {
        await provider.setTransport(nil, for: host.id)
        await permissionGrantedWithToken()
        let ask = makeAsk()

        await ask.turnOn()
        await ask.processPending()

        #expect(!liveActivities.isEnabled(for: host.id))

        // Later, maybe after a relaunch, the Host comes back.
        let relaunched = makeAsk()
        await provider.setTransport(transport, for: host.id)
        await preferences.refresh()
        await relaunched.processPending()

        #expect(try await isRegistered(on: transport))
        #expect(liveActivities.isEnabled(for: host.id))
    }

    @Test func anUnreachableHostDoesNotHoldUpAReachableOne() async throws {
        let unreachable = Host(name: "mini", address: "10.0.0.3", username: "z")
        preferences.setHosts([unreachable, host])
        await permissionGrantedWithToken()

        await makeAsk().turnOn()

        #expect(try await isRegistered(on: transport))
        #expect(liveActivities.isEnabled(for: host.id))
        #expect(!liveActivities.isEnabled(for: unreachable.id))
    }

    /// Every registration attempt reads the Host's file before it writes, so
    /// the read count is the attempt count (a failed write records nothing).
    @Test func aFailedRegistrationWaitsForAFreshReadThenRetries() async throws {
        await permissionGrantedWithToken()
        await transport.setNotificationRegistrationWriteFailure(.writeFailed(detail: "disk full"))
        let ask = makeAsk()
        let readsBefore = await transport.notificationRegistrationReads

        await ask.turnOn()
        let readsAfterFirstAttempt = await transport.notificationRegistrationReads
        #expect(readsAfterFirstAttempt > readsBefore)

        await ask.processPending()

        #expect(await transport.notificationRegistrationReads == readsAfterFirstAttempt)
        #expect(!liveActivities.isEnabled(for: host.id))

        await transport.setNotificationRegistrationWriteFailure(nil)
        await preferences.refresh()
        await ask.processPending()

        #expect(try await isRegistered(on: transport))
        #expect(liveActivities.isEnabled(for: host.id))
    }

    @Test func refusingThePermissionPromptEndsTurnOn() async throws {
        await permissionNotDetermined()
        scripted.grantResult = .success(false)
        let ask = makeAsk()

        await ask.turnOn()
        #expect(push.state == .denied)

        // Allowing notifications in the Settings app later turns nothing
        // on, not even a Host added since.
        let added = Host(name: "mini", address: "10.0.0.3", username: "z")
        let addedTransport = ScriptedTransport()
        await provider.setTransport(addedTransport, for: added.id)
        preferences.setHosts([host, added])
        await permissionGrantedWithToken()
        await ask.processPending()
        await makeAsk().processPending()

        #expect(await registrationWrites(on: transport) == 0)
        #expect(await registrationWrites(on: addedTransport) == 0)
        #expect(!liveActivities.isEnabled(for: host.id))
        #expect(!liveActivities.isEnabled(for: added.id))
    }

    @Test func turnOnIsNotStoredWhileTheIOSPromptIsUp() async throws {
        let suite = try NotificationAskTests(prompt: HangingPushRegistrationClient())
        await suite.permissionNotDetermined()
        let ask = suite.makeAsk()

        let prompt = Task { await ask.turnOn() }
        try await waitUntil("Turn On should be accepted while permission is pending") {
            ask.answer == .accepted
        }

        // The app is killed with the prompt up; the next launch asks again.
        let relaunched = suite.makeAsk()
        #expect(relaunched.answer == nil)
        #expect(relaunched.isEligible)
        prompt.cancel()
        await prompt.value
    }

    /// A permission request that fails answers nothing: once the app
    /// re-probes permission (every foreground return), the ask is due again,
    /// on this launch and the next.
    @Test func aFailedPermissionPromptLeavesTheAskUnanswered() async {
        await permissionNotDetermined()
        scripted.grantResult = .failure(ScriptedPushRegistrationClient.Failure())
        let ask = makeAsk()

        await ask.turnOn()
        await push.refresh()

        #expect(ask.answer == nil)
        #expect(ask.isEligible)
        #expect(makeAsk().answer == nil)
        #expect(makeAsk().isEligible)
    }

    /// Notifications turned off in the Settings app after Turn On only
    /// pause it: nothing is written meanwhile, and once they are back on,
    /// the Hosts still pending and any Host added in between turn on.
    @Test func turnOnWaitsWhileNotificationsAreOffInSettings() async throws {
        await permissionNotDetermined()
        scripted.grantResult = .success(true)
        let ask = makeAsk()
        await ask.turnOn()
        #expect(push.state == .waitingForToken)

        scripted.status = .denied
        await push.refresh()
        let added = Host(name: "mini", address: "10.0.0.3", username: "z")
        let addedTransport = ScriptedTransport()
        await provider.setTransport(addedTransport, for: added.id)
        preferences.setHosts([host, added])
        await ask.processPending()
        await makeAsk().processPending()

        #expect(await registrationWrites(on: transport) == 0)
        #expect(await registrationWrites(on: addedTransport) == 0)

        await permissionGrantedWithToken()
        await makeAsk().processPending()

        #expect(try await isRegistered(on: transport))
        #expect(try await isRegistered(on: addedTransport))
        #expect(liveActivities.isEnabled(for: host.id))
        #expect(liveActivities.isEnabled(for: added.id))
    }

    // MARK: After Turn On

    @Test func aHostAddedAfterTurnOnIsTurnedOnToo() async throws {
        await permissionGrantedWithToken()
        await makeAsk().turnOn()
        let added = Host(name: "mini", address: "10.0.0.3", username: "z")
        let addedTransport = ScriptedTransport()
        await provider.setTransport(addedTransport, for: added.id)

        preferences.setHosts([host, added])
        await preferences.refresh()
        await makeAsk().processPending()

        #expect(try await isRegistered(on: addedTransport))
        #expect(liveActivities.isEnabled(for: added.id))
    }

    @Test func aHostTurnedOffAfterTurnOnStaysOff() async throws {
        await permissionGrantedWithToken()
        let ask = makeAsk()
        await ask.turnOn()
        #expect(try await isRegistered(on: transport))
        #expect(liveActivities.isEnabled(for: host.id))

        await preferences.setNotificationsEnabled(false, for: host)
        liveActivities.setEnabled(false, for: host.id)
        await preferences.refresh()
        await ask.processPending()
        await makeAsk().processPending()

        #expect(try await !isRegistered(on: transport))
        #expect(!liveActivities.isEnabled(for: host.id))
    }
}

/// An iOS permission prompt nobody answers: `requestAuthorization` waits
/// until its task is cancelled.
private struct HangingPushRegistrationClient: PushRegistrationClient {
    func authorizationStatus() async -> UNAuthorizationStatus { .notDetermined }

    func requestAuthorization() async throws -> Bool {
        try await Task.sleep(for: .seconds(3600))
        return false
    }

    func registerForRemoteNotifications() {}
}

/// Screen time and natural breaks for the Notification Ask, one window.
@Suite("Agent session clock")
struct AgentSessionClockTests {
    private let start = ContinuousClock.now
    private let agent = ConsoleAgent.ID(hostID: UUID(), paneID: "wV:p1")
    private let other = ConsoleAgent.ID(hostID: UUID(), paneID: "wV:p2")

    private func at(_ seconds: Int) -> ContinuousClock.Instant {
        start + .seconds(seconds)
    }

    /// A foreground window with `agent` open since `start`.
    private func showingAgent() -> AgentSessionClock {
        var clock = AgentSessionClock()
        _ = clock.didBecomeActive(at: start, isLaunchWindow: true)
        _ = clock.pathDidChange(to: agent, isRetarget: false, at: start)
        return clock
    }

    @Test func leavingAnAgentAfter20SecondsIsASession() {
        var short = showingAgent()
        #expect(!short.pathDidChange(to: nil, isRetarget: false, at: at(19)).endedSession)

        var long = showingAgent()
        #expect(long.pathDidChange(to: nil, isRetarget: false, at: at(20)).endedSession)
    }

    @Test func backgroundTimeIsNotScreenTime() {
        var clock = showingAgent()
        #expect(!clock.didEnterBackground(at: at(15)).endedSession)
        _ = clock.didBecomeActive(at: at(600), isLaunchWindow: true)

        #expect(!clock.pathDidChange(to: nil, isRetarget: false, at: at(610)).endedSession)
    }

    @Test func goingToTheBackgroundAfter20SecondsIsASession() {
        var clock = showingAgent()

        #expect(clock.didEnterBackground(at: at(25)).endedSession)
    }

    @Test func aMoveKeepsTheAgentsTime() {
        var clock = showingAgent()

        let move = clock.pathDidChange(to: other, isRetarget: true, at: at(15))
        #expect(move == AgentSessionClock.Change())

        #expect(clock.pathDidChange(to: nil, isRetarget: false, at: at(25)).endedSession)
    }

    @Test func movingToAnotherAgentIsNotABreak() {
        var clock = showingAgent()

        let change = clock.pathDidChange(to: other, isRetarget: false, at: at(30))

        #expect(change.endedSession)
        #expect(change.newBreak == nil)
    }

    @Test func returningToTheConsoleIsABreakUntilTheNextNavigation() throws {
        var clock = showingAgent()

        let back = try #require(clock.pathDidChange(to: nil, isRetarget: false, at: at(5)).newBreak)
        #expect(back.kind == .returnedToConsole)
        #expect(clock.stillHolds(back, lastRouteRequest: nil))

        _ = clock.pathDidChange(to: other, isRetarget: false, at: at(6))
        #expect(!clock.stillHolds(back, lastRouteRequest: nil))
    }

    @Test func theLaunchWindowOpeningAndReturningToTheForegroundAreBreaks() throws {
        var clock = AgentSessionClock()
        let launch = try #require(clock.didBecomeActive(at: start, isLaunchWindow: true).newBreak)
        #expect(launch.kind == .cameToForeground)

        _ = clock.pathDidChange(to: agent, isRetarget: false, at: at(1))
        _ = clock.didEnterBackground(at: at(2))
        let back = try #require(clock.didBecomeActive(at: at(3), isLaunchWindow: true).newBreak)
        #expect(clock.stillHolds(back, lastRouteRequest: nil))

        _ = clock.pathDidChange(to: other, isRetarget: false, at: at(4))
        #expect(!clock.stillHolds(back, lastRouteRequest: nil))
    }

    /// A tap is routed while the scene is still inactive, so the request
    /// lands just before the foreground break it brought about.
    @Test func aRouteRequestJustBeforeComingToTheForegroundCancelsThatBreak() throws {
        var clock = showingAgent()
        _ = clock.didEnterBackground(at: at(30))
        let back = try #require(clock.didBecomeActive(at: at(100), isLaunchWindow: true).newBreak)

        #expect(!clock.stillHolds(back, lastRouteRequest: at(98)))
        #expect(clock.stillHolds(back, lastRouteRequest: at(90)))
    }

    /// A tap on the Agent already on screen changes no navigation; the
    /// request alone cancels the break.
    @Test func aRouteRequestAfterComingToTheForegroundCancelsTheBreak() throws {
        var clock = showingAgent()
        _ = clock.didEnterBackground(at: at(30))
        let back = try #require(clock.didBecomeActive(at: at(100), isLaunchWindow: true).newBreak)

        #expect(!clock.stillHolds(back, lastRouteRequest: at(100) + .milliseconds(500)))
    }

    /// Open in New Window lands on the Agent the user just asked for: that
    /// window's opening is no break, but its later returns are.
    @Test func aLaterWindowsOpeningIsNotABreak() {
        var clock = AgentSessionClock()
        _ = clock.pathDidChange(to: agent, isRetarget: false, at: start)

        #expect(clock.didBecomeActive(at: start, isLaunchWindow: false).newBreak == nil)

        _ = clock.didEnterBackground(at: at(30))
        #expect(clock.didBecomeActive(at: at(60), isLaunchWindow: false).newBreak != nil)
    }

    @Test func anActivationWithoutABackgroundIsNotABreak() {
        var clock = showingAgent()

        #expect(clock.didBecomeActive(at: at(5), isLaunchWindow: true).newBreak == nil)
    }
}
