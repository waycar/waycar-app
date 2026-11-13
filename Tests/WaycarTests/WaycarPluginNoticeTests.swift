import Foundation
import Testing

@testable import Waycar

@MainActor
@Suite("Waycar plugin notice")
struct WaycarPluginNoticeTests {
    private static let outdated = WaycarPluginStatus.outdated(installed: "1.3.1", required: "1.4.0")

    // MARK: Not now

    @Test func notNowHidesTheRowForThatHostAtThatMinimumOnly() throws {
        let suiteName = "waycar-plugin-notice-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let dismissed = Host.fixture()
        let other = Host.fixture()

        let dismissals = WaycarPluginNoticeDismissals(defaults: defaults)
        #expect(!dismissals.isDismissed(dismissed.id, minimum: "1.4.0"))
        dismissals.dismiss(dismissed.id, minimum: "1.4.0")

        #expect(dismissals.isDismissed(dismissed.id, minimum: "1.4.0"))
        #expect(!dismissals.isDismissed(dismissed.id, minimum: "1.5.0"), "a newer minimum shows it again")
        #expect(!dismissals.isDismissed(other.id, minimum: "1.4.0"), "per Host")

        let relaunched = WaycarPluginNoticeDismissals(defaults: defaults)
        #expect(relaunched.isDismissed(dismissed.id, minimum: "1.4.0"), "kept on this device")
        #expect(!relaunched.isDismissed(other.id, minimum: "1.4.0"))
    }

    @Test func aDismissalKeepsTheOtherHostsDismissedElsewhere() throws {
        let suiteName = "waycar-plugin-notice-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = Host.fixture()
        let second = Host.fixture()
        let stale = WaycarPluginNoticeDismissals(defaults: defaults)

        WaycarPluginNoticeDismissals(defaults: defaults).dismiss(first.id, minimum: "1.4.0")
        stale.dismiss(second.id, minimum: "1.4.0")

        #expect(stale.isDismissed(first.id, minimum: "1.4.0"))
        let relaunched = WaycarPluginNoticeDismissals(defaults: defaults)
        #expect(relaunched.isDismissed(first.id, minimum: "1.4.0"), "not overwritten")
        #expect(relaunched.isDismissed(second.id, minimum: "1.4.0"))
    }

    // MARK: Update activity

    @Test func oneUpdateRunsPerHostAtATime() {
        let activity = WaycarPluginUpdateActivity()
        let host = Host.fixture()
        let other = Host.fixture()

        #expect(activity.begin(host.id))
        #expect(!activity.begin(host.id), "a second run on the same Host is refused")
        #expect(activity.begin(other.id), "per Host")
        #expect(activity.runningHosts == [host.id, other.id])

        activity.end(host.id)
        #expect(activity.runningHosts == [other.id])
        #expect(activity.begin(host.id), "allowed again once the first run ended")
    }

    // MARK: Console row

    @Test func onlyAnOutdatedUndismissedPluginGetsAnUpdateRow() throws {
        let host = Host.fixture(name: "mac")
        let row = try #require(
            ConsoleHostStatusPresentation(host: host, pluginStatus: Self.outdated, isDismissed: false))
        #expect(row.message == "mac: Waycar plugin 1.3.1 is out of date")
        #expect(row.detail == "This app needs 1.4.0.")
        #expect(row.severity == .warning)
        #expect(row.pluginOffer == .update)
        #expect(!row.navigates, "it updates in place, never through Host detail")
        #expect(row.retryScope == nil)

        for status in [WaycarPluginStatus.current(version: "1.4.0"), .unknown] {
            #expect(
                ConsoleHostStatusPresentation(host: host, pluginStatus: status, isDismissed: false)
                    == nil)
        }
        #expect(
            ConsoleHostStatusPresentation(host: host, pluginStatus: Self.outdated, isDismissed: true)
                == nil)
    }

    @Test func aHostWithoutThePluginGetsAnInstallRowUnlessDismissed() throws {
        let host = Host.fixture(name: "mac")
        let row = try #require(
            ConsoleHostStatusPresentation(host: host, pluginStatus: .notInstalled, isDismissed: false))
        #expect(row.message == "Install Waycar Host Tools on mac")
        #expect(row.pluginOffer == .install)
        #expect(row.isPluginRow)
        #expect(!row.navigates)
        #expect(
            ConsoleHostStatusPresentation(host: host, pluginStatus: .notInstalled, isDismissed: true)
                == nil)
    }

    // MARK: Host Tools offer

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let fourteenDays: TimeInterval = 14 * 24 * 60 * 60

    private func makeOffer(_ defaults: UserDefaults) -> HostToolsOffer {
        HostToolsOffer(defaults: defaults)
    }

    @Test func notNowHidesTheOfferForThatHostOnlyForFourteenDays() throws {
        let suiteName = "waycar-host-tools-offer-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let dismissed = Host.fixture()
        let other = Host.fixture()
        let offer = makeOffer(defaults)
        #expect(!offer.isHidden(dismissed.id, now: Self.now), "offered by default")

        offer.notNow(dismissed.id, now: Self.now)

        #expect(offer.isHidden(dismissed.id, now: Self.now))
        #expect(!offer.isHidden(other.id, now: Self.now), "per Host")
        let almost = Self.now.addingTimeInterval(Self.fourteenDays - 1)
        #expect(offer.isHidden(dismissed.id, now: almost))
        let after = Self.now.addingTimeInterval(Self.fourteenDays)
        #expect(!offer.isHidden(dismissed.id, now: after), "it comes back")

        let relaunched = makeOffer(defaults)
        #expect(relaunched.isHidden(dismissed.id, now: almost), "kept on this device")
        #expect(!relaunched.isHidden(other.id, now: almost))
    }

    @Test func theOfferComesBackOnceAndASecondNotNowEndsIt() throws {
        let suiteName = "waycar-host-tools-offer-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let host = Host.fixture()
        let offer = makeOffer(defaults)
        let returned = Self.now.addingTimeInterval(Self.fourteenDays)

        offer.notNow(host.id, now: Self.now)
        #expect(!offer.isHidden(host.id, now: returned))
        offer.notNow(host.id, now: returned)

        let aYearOn = returned.addingTimeInterval(365 * 24 * 60 * 60)
        #expect(offer.isHidden(host.id, now: returned))
        #expect(offer.isHidden(host.id, now: aYearOn), "no third offer")
        #expect(makeOffer(defaults).isHidden(host.id, now: aYearOn))
    }

    @Test func theSwitchOffHidesTheOfferForGoodAndOnBringsItBack() throws {
        let suiteName = "waycar-host-tools-offer-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let host = Host.fixture()
        let other = Host.fixture()
        let offer = makeOffer(defaults)
        #expect(offer.reminds(host.id), "on by default")

        offer.setReminds(false, for: host.id)

        let aYearOn = Self.now.addingTimeInterval(365 * 24 * 60 * 60)
        #expect(!offer.reminds(host.id))
        #expect(offer.isHidden(host.id, now: Self.now))
        #expect(offer.isHidden(host.id, now: aYearOn))
        #expect(offer.reminds(other.id), "per Host")
        #expect(!offer.isHidden(other.id, now: Self.now))
        #expect(!makeOffer(defaults).reminds(host.id), "kept on this device")

        offer.notNow(host.id, now: Self.now)
        offer.setReminds(true, for: host.id)
        #expect(offer.reminds(host.id))
        #expect(!offer.isHidden(host.id, now: Self.now), "on forgets the earlier answers")
    }

    @Test func anAnswerKeepsTheOtherHostsAnsweredElsewhere() throws {
        let suiteName = "waycar-host-tools-offer-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = Host.fixture()
        let second = Host.fixture()
        let stale = makeOffer(defaults)

        makeOffer(defaults).notNow(first.id, now: Self.now)
        stale.setReminds(false, for: second.id)

        let relaunched = makeOffer(defaults)
        #expect(relaunched.isHidden(first.id, now: Self.now), "not overwritten")
        #expect(!relaunched.reminds(second.id))
    }

    /// Deleting the app wipes UserDefaults; iCloud Sync brings the Hosts back
    /// with their ids, and the answers with them, so the offers stay hidden.
    @Test func answersComeBackAfterAReinstallThroughICloudSync() throws {
        let firstSuite = "waycar-host-tools-offer-\(UUID().uuidString)"
        let first = try #require(UserDefaults(suiteName: firstSuite))
        defer { first.removePersistentDomain(forName: firstSuite) }
        let reinstalledSuite = "waycar-host-tools-offer-\(UUID().uuidString)"
        let reinstalled = try #require(UserDefaults(suiteName: reinstalledSuite))
        defer { reinstalled.removePersistentDomain(forName: reinstalledSuite) }
        let iCloud = InMemorySecretStore()
        let keys = [HostToolsOffer.defaultsKey, WaycarPluginNoticeDismissals.defaultsKey]
        let canRead: (String, Any) -> Bool = { key, value in
            key == HostToolsOffer.defaultsKey
                ? (value as? Data).map(HostToolsOffer.canRead) ?? false
                : value is [String: String]
        }
        let declined = Host.fixture()
        let postponed = Host.fixture()
        let outdated = Host.fixture()
        makeOffer(first).setReminds(false, for: declined.id)
        makeOffer(first).notNow(postponed.id, now: Self.now)
        WaycarPluginNoticeDismissals(defaults: first).dismiss(outdated.id, minimum: "1.4.0")
        _ = PreferenceSync(defaults: first, keys: keys)
            .reconcile(items: try iCloud.readAll(), shared: iCloud, canRead: canRead)

        let offer = makeOffer(reinstalled)
        let dismissals = WaycarPluginNoticeDismissals(defaults: reinstalled)
        #expect(!offer.isHidden(declined.id, now: Self.now), "the reinstall forgot it here")

        let outcome = PreferenceSync(defaults: reinstalled, keys: keys)
            .reconcile(items: try iCloud.readAll(), shared: iCloud, canRead: canRead)
        offer.reload()
        dismissals.reload()

        #expect(outcome.changedKeys.count == 2)
        #expect(!offer.reminds(declined.id))
        #expect(offer.isHidden(declined.id, now: Self.now.addingTimeInterval(365 * 24 * 60 * 60)))
        #expect(offer.isHidden(postponed.id, now: Self.now))
        #expect(!offer.isHidden(postponed.id, now: Self.now.addingTimeInterval(Self.fourteenDays)))
        #expect(dismissals.isDismissed(outdated.id, minimum: "1.4.0"))
    }

    @Test func thePluginRowShowsOnlyWhenTheHostHasNoOtherRow() throws {
        let host = Host.fixture()
        let connecting = try #require(
            ConsoleHostStatusPresentation(host: host, status: .connecting, syncError: nil))
        let backendFailure = ConsoleHostStatusPresentation(
            host: host, failedScope: ConsoleScope(hostID: host.id, backend: .tmux),
            failure: .authenticationFailed)

        for status in [Self.outdated, .notInstalled] {
            let plugin = try #require(
                ConsoleHostStatusPresentation(host: host, pluginStatus: status, isDismissed: false))
            #expect(
                ConsoleHostStatusPresentation.hostRows(
                    condition: connecting, backendFailures: [], pluginNotice: plugin) == [connecting])
            #expect(
                ConsoleHostStatusPresentation.hostRows(
                    condition: nil, backendFailures: [backendFailure], pluginNotice: plugin)
                    == [backendFailure])
            #expect(
                ConsoleHostStatusPresentation.hostRows(
                    condition: nil, backendFailures: [], pluginNotice: plugin) == [plugin])
            #expect(plugin.id != connecting.id, "its own list identity")
        }
        #expect(
            ConsoleHostStatusPresentation.hostRows(
                condition: nil, backendFailures: [], pluginNotice: nil).isEmpty)
    }

    // MARK: Move off Node (WAY-451)

    private func pluginRow(
        host: Host, detection: WaycarPluginDetection?,
        noticeDismissals: WaycarPluginNoticeDismissals, offer: HostToolsOffer?, now: Date = Self.now
    ) -> ConsoleHostStatusPresentation? {
        ConsoleHostStatusPresentation.pluginRow(
            host: host,
            pluginStatus: WaycarPluginRequirement.status(of: detection),
            nativeToolsStatus: WaycarPluginRequirement.nativeToolsStatus(of: detection),
            noticeDismissals: noticeDismissals, hostToolsOffer: offer, now: now)
    }

    private static func detection(_ version: String?) -> WaycarPluginDetection {
        .installed(WaycarPluginInstall(version: version, mode: .herdr))
    }

    @Test func aWorkingNodeEraPluginGetsAnUpdateRowAndNothingElseDoes() throws {
        let suiteName = "waycar-native-prompt-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let host = Host.fixture(name: "mac")
        let dismissals = WaycarPluginNoticeDismissals(defaults: defaults)
        let offer = makeOffer(defaults)

        for version in ["1.7.0", "1.99.0"] {
            let row = try #require(
                pluginRow(
                    host: host, detection: Self.detection(version), noticeDismissals: dismissals,
                    offer: offer))
            #expect(row.pluginOffer == .moveToNative, "\(version)")
            #expect(row.severity == .warning)
            #expect(row.isPluginRow)
            #expect(!row.navigates, "it updates in place, never through Host detail")
            #expect(row.message == "mac: Update Waycar to stop needing Node")
        }
        for detection in [
            Self.detection("2.0.0"), Self.detection("2.0.0-beta"), Self.detection("2.1.0"),
            Self.detection(nil), Self.detection("garbage"), nil,
        ] {
            #expect(
                pluginRow(host: host, detection: detection, noticeDismissals: dismissals, offer: offer)
                    == nil, "\(String(describing: detection))")
        }
        let missing = try #require(
            pluginRow(host: host, detection: .notInstalled, noticeDismissals: dismissals, offer: offer))
        #expect(missing.pluginOffer == .install, "no plugin gets the install offer, not this one")
        let belowMinimum = try #require(
            pluginRow(
                host: host, detection: Self.detection("1.3.1"), noticeDismissals: dismissals,
                offer: offer))
        #expect(belowMinimum.pluginOffer == .update, "below this build's minimum stays an Update")
        #expect(
            pluginRow(
                host: host, detection: Self.detection("1.7.0"), noticeDismissals: dismissals,
                offer: nil) == nil, "previews have no offer record, so none is shown")
    }

    @Test func notNowOnTheNativePromptHoldsForFourteenDaysThenOnceMoreThenEnds() throws {
        let suiteName = "waycar-native-prompt-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let host = Host.fixture()
        let other = Host.fixture()
        let detection = Self.detection("1.7.0")
        let dismissals = WaycarPluginNoticeDismissals(defaults: defaults)
        let offer = makeOffer(defaults)
        func shows(_ host: Host, at time: Date, _ offer: HostToolsOffer) -> Bool {
            pluginRow(host: host, detection: detection, noticeDismissals: dismissals, offer: offer, now: time)
                != nil
        }
        #expect(shows(host, at: Self.now, offer))

        offer.nativeToolsNotNow(host.id, now: Self.now)

        let almost = Self.now.addingTimeInterval(Self.fourteenDays - 1)
        let returned = Self.now.addingTimeInterval(Self.fourteenDays)
        #expect(!shows(host, at: Self.now, offer))
        #expect(!shows(host, at: almost, offer))
        #expect(shows(other, at: Self.now, offer), "per Host")
        #expect(!shows(host, at: almost, makeOffer(defaults)), "survives a restart")
        #expect(shows(host, at: returned, offer), "it comes back")

        offer.nativeToolsNotNow(host.id, now: returned)
        let aYearOn = returned.addingTimeInterval(365 * 24 * 60 * 60)
        #expect(!shows(host, at: returned, offer))
        #expect(!shows(host, at: aYearOn, makeOffer(defaults)), "a second Not now ends it")
    }

    /// "Not now" is keyed to the constant it answered: an answer made for
    /// another minimum, or the outdated row's older Not now, never hides it.
    @Test func anOlderNotNowDoesNotHideTheNativePrompt() throws {
        let suiteName = "waycar-native-prompt-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let host = Host.fixture()
        let dismissals = WaycarPluginNoticeDismissals(defaults: defaults)
        let offer = makeOffer(defaults)
        let older = "1.4.0"
        #expect(older != WaycarPluginRequirement.nativeToolsMinimumVersion)

        dismissals.dismiss(host.id, minimum: older)
        offer.nativeToolsNotNow(host.id, minimum: older, now: Self.now)
        offer.notNow(host.id, now: Self.now)
        offer.notNow(host.id, now: Self.now)

        #expect(!offer.isNativeToolsPromptHidden(host.id, now: Self.now))
        #expect(
            pluginRow(
                host: host, detection: Self.detection("1.7.0"), noticeDismissals: dismissals,
                offer: makeOffer(defaults)) != nil)

        // A newer constant asks again after an answer at this one.
        offer.nativeToolsNotNow(host.id, now: Self.now)
        #expect(offer.isNativeToolsPromptHidden(host.id, now: Self.now))
        #expect(!offer.isNativeToolsPromptHidden(host.id, minimum: "2.1.0", now: Self.now))
    }

    @Test func theHostsReminderSwitchHidesTheNativePromptToo() throws {
        let suiteName = "waycar-native-prompt-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let host = Host.fixture()
        let offer = makeOffer(defaults)

        offer.setReminds(false, for: host.id)
        #expect(offer.isNativeToolsPromptHidden(host.id, now: Self.now))

        offer.setReminds(true, for: host.id)
        #expect(!offer.isNativeToolsPromptHidden(host.id, now: Self.now))
        offer.nativeToolsNotNow(host.id, now: Self.now)
        offer.setReminds(false, for: host.id)
        offer.setReminds(true, for: host.id)
        #expect(!offer.isNativeToolsPromptHidden(host.id, now: Self.now), "on forgets the earlier answers")
    }

    /// A record written before the prompt existed has no native answers and
    /// still decodes: its Install answers stay.
    @Test func anOfferRecordFromBeforeThePromptStillDecodes() throws {
        let suiteName = "waycar-native-prompt-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let host = Host.fixture()
        let legacy = """
            {"\(host.id.uuidString)":{"reminds":true,"notNowCount":1,"lastNotNow":\(Self.now.timeIntervalSinceReferenceDate)}}
            """
        defaults.set(Data(legacy.utf8), forKey: HostToolsOffer.defaultsKey)

        let offer = makeOffer(defaults)
        #expect(offer.isHidden(host.id, now: Self.now), "the earlier Install Not now is kept")
        #expect(!offer.isNativeToolsPromptHidden(host.id, now: Self.now))
    }

    // MARK: Agent card hint

    private static func row(
        _ status: AgentStatus, progress: AgentProgress? = nil, hostReportsProgress: Bool = false,
        kind: String = "claude"
    ) -> ConsoleAgent {
        ConsoleAgent(
            hostID: UUID(), hostName: "mac",
            agent: Agent(
                terminalID: "t", kind: kind, title: "", status: status,
                workspaceID: "w1", tabID: "w1:t1", paneID: "w1:p1", cwd: "/", revision: 1),
            workspaceLabel: nil, repositoryCheckout: nil,
            summary: AgentSummary(
                paneID: "w1:p1", status: status, text: "adding retries",
                timestamp: Int64(Date.now.timeIntervalSince1970 * 1000), progress: progress),
            hostReportsProgress: hostReportsProgress)
    }

    @Test func theProgressHintShowsOnlyWhereAnOutdatedPluginLeavesTheBarEmpty() throws {
        #expect(Self.row(.working).showsPluginProgressHint(summariesEnabled: true, pluginStatus: Self.outdated))
        #expect(Self.row(.blocked).showsPluginProgressHint(summariesEnabled: true, pluginStatus: Self.outdated))

        #expect(!Self.row(.working).showsPluginProgressHint(summariesEnabled: false, pluginStatus: Self.outdated))
        for status in [WaycarPluginStatus.current(version: "1.4.0"), .unknown, .notInstalled] {
            #expect(!Self.row(.working).showsPluginProgressHint(summariesEnabled: true, pluginStatus: status))
        }
        let estimate = try #require(AgentProgress(steps: .init(done: 3, total: 7), phase: nil))
        #expect(
            !Self.row(.working, progress: estimate)
                .showsPluginProgressHint(summariesEnabled: true, pluginStatus: Self.outdated))
        #expect(
            !Self.row(.working, hostReportsProgress: true)
                .showsPluginProgressHint(summariesEnabled: true, pluginStatus: Self.outdated))
        for status in [AgentStatus.idle, .done, .unknown] {
            #expect(!Self.row(status).showsPluginProgressHint(summariesEnabled: true, pluginStatus: Self.outdated))
        }
        #expect(
            !Self.row(.working, kind: Agent.shellKind)
                .showsPluginProgressHint(summariesEnabled: true, pluginStatus: Self.outdated))
    }

    // MARK: Chat re-check

    @Test func aPluginUpdateReadsTheChatAgain() async throws {
        let reader = PluginTranscriptReader()
        let store = reader.makeStore(retryDelays: [.milliseconds(5)])

        store.start()
        try await waitUntil("outdated") { store.availability == .pluginOutdated }
        try await Task.sleep(for: .milliseconds(40))
        #expect(reader.reads == 1, "an outdated plugin is not retried on its own")

        reader.isOutdated = false
        store.recheckPlugin()
        try await waitUntil("the updated plugin answers") { store.availability == .ready }
        store.stop()
    }

    @Test func aRecheckRetriesAStillOutdatedAnswerThroughTheDelaysOnce() async throws {
        let reader = PluginTranscriptReader()
        let store = reader.makeStore(retryDelays: [.milliseconds(5), .milliseconds(5)])

        store.start()
        try await waitUntil("outdated") { store.availability == .pluginOutdated }
        store.recheckPlugin()
        try await waitUntil("the recheck and its retries") { reader.reads == 4 }
        try await Task.sleep(for: .milliseconds(60))
        #expect(reader.reads == 4, "then believed again")
        #expect(store.availability == .pluginOutdated)
        store.stop()
    }

    @Test func aRecheckLeavesAWorkingChatAlone() async throws {
        let reader = PluginTranscriptReader()
        reader.isOutdated = false
        let store = reader.makeStore(retryDelays: [.seconds(60)])

        store.start()
        try await waitUntil("ready") { store.availability == .ready }
        store.recheckPlugin()
        try await Task.sleep(for: .milliseconds(40))
        #expect(reader.reads == 1)
        store.stop()
    }
}

/// A Host whose transcript reader is missing until the plugin is updated.
@MainActor
private final class PluginTranscriptReader {
    var isOutdated = true
    private(set) var reads = 0

    func makeStore(retryDelays: [Duration]) -> ChatTranscriptStore {
        ChatTranscriptStore(
            read: { [self] _ in
                reads += 1
                if isOutdated { throw ChatTranscriptError.readerUnavailable }
                return ChatTranscriptSnapshot(
                    header: ChatTranscriptHeader(
                        kind: "claude", status: .ok, transcript: nil, activity: nil,
                        turnOpen: false, truncated: false, error: nil, afterFound: true),
                    messages: [])
            },
            readScreen: { "" },
            sendKeys: { _ in },
            initialStatus: .idle,
            statusUpdates: nil,
            retryDelays: retryDelays)
    }
}
