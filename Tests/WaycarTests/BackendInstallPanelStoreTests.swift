import Foundation
import Testing

@testable import Waycar

/// The install panel's flow (WAY-338) against the fake connector: which
/// buttons the preflight earns, consent before every run, Hide that keeps a
/// run going, and Check Again.
@MainActor
@Suite("Backend install panel")
struct BackendInstallPanelStoreTests {
    private static let noDial = FakeTransportConnector.Outcome.unreachable(.timedOut)
    private static let neither = HostBackendPresence(herdr: false, tmuxVersion: nil)
    private static let herdrFound = HostBackendPresence(herdr: true, tmuxVersion: nil)

    /// What the panel read and reported, and the presence it follows.
    @MainActor
    private final class Console {
        var presence: HostBackendPresence?
        var recorded: [HostBackendPresence] = []
        var found: [HostBackendPresence] = []
        init(_ presence: HostBackendPresence?) { self.presence = presence }
    }

    private static func facts(
        managers: [HostPackageManager] = [.aptGet], curl: Bool = true, sudo: Bool = true
    ) -> HostInstallPreflight {
        HostInstallPreflight(
            operatingSystem: "Linux", architecture: "x86_64", isAndroid: false, hasCurl: curl,
            packageManagers: managers, isRoot: false, sudoWithoutPassword: sudo)
    }

    private func run(
        _ status: Int32, _ reason: BackendInstallRun.Reason
    ) -> Result<BackendInstallRun, TransportError> {
        .success(BackendInstallRun(exitStatus: status, reason: reason, output: []))
    }

    private struct Setup {
        let panel: BackendInstallPanelStore
        let center: BackendInstallCenter
        let connector: FakeTransportConnector
        let console: Console
        let host: Host
    }

    private func makeSetup(
        presence: HostBackendPresence? = neither,
        preflight: Result<HostInstallPreflight, TransportError>? = .success(facts()),
        runs: [Result<BackendInstallRun, TransportError>] = [],
        presenceAfter: HostBackendPresence? = nil,
        detected: HostBackendPresence = neither,
        host: Host = .fixture()
    ) async -> Setup {
        let connector = FakeTransportConnector(outcome: Self.noDial, presence: detected)
        await connector.scriptInstall(
            preflight: preflight, runs: runs, presenceAfter: presenceAfter)
        let center = BackendInstallCenter(connector: connector)
        let console = Console(presence)
        let panel = BackendInstallPanelStore(
            host: host, center: center,
            presence: { console.presence },
            recordPresence: { console.recorded.append($0) },
            foundBackend: { console.found.append($0) },
            credentials: HostCredentialsProvider(
                deviceKeys: DeviceKeyStore(secrets: InMemorySecretStore()),
                rsaKeys: RSAKeyStore(secrets: InMemorySecretStore()),
                secrets: InMemorySecretStore()),
            knownHosts: InMemoryKnownHostsStore())
        return Setup(panel: panel, center: center, connector: connector, console: console, host: host)
    }

    // MARK: Buttons

    @Test func herdrLeadsAndTmuxFollowsOnAHostWithNeitherAndAManager() async {
        let setup = await makeSetup()
        await setup.panel.loadPreflight()

        #expect(setup.panel.herdrPlan?.target == .herdr)
        #expect(setup.panel.tmuxPlan?.target == .tmux(.aptGet))
    }

    @Test func aTooOldTmuxOffersOnlyHerdr() async {
        let setup = await makeSetup(presence: HostBackendPresence(herdr: false, tmuxVersion: "3.0"))
        await setup.panel.loadPreflight()

        #expect(setup.panel.herdrPlan != nil)
        #expect(setup.panel.tmuxPlan == nil)
    }

    @Test func noUsablePackageManagerHidesInstallTmuxAndSaysWhy() async {
        let setup = await makeSetup(preflight: .success(Self.facts(managers: [])))
        await setup.panel.loadPreflight()

        #expect(setup.panel.herdrPlan != nil)
        #expect(setup.panel.tmuxPlan == nil)
        #expect(
            setup.panel.tmuxUnavailableReason
                == "Waycar did not find a package manager it can use on \(setup.host.displayName).")
    }

    @Test func noCurlHidesInstallHerdrAndSaysWhy() async {
        let setup = await makeSetup(preflight: .success(Self.facts(curl: false)))
        await setup.panel.loadPreflight()

        #expect(setup.panel.herdrPlan == nil)
        #expect(
            setup.panel.herdrUnavailableReason
                == "\(setup.host.displayName) has no curl. herdr’s installer needs it.")
        #expect(setup.panel.tmuxPlan != nil)
    }

    @Test func anUnreadableHostOffersNoInstallAtAll() async {
        let setup = await makeSetup(preflight: .failure(.sshUnreachable(detail: "no route")))
        await setup.panel.loadPreflight()

        guard case .failed = setup.panel.preflight else {
            Issue.record("expected a failed preflight, got \(setup.panel.preflight)")
            return
        }
        #expect(setup.panel.herdrPlan == nil)
        #expect(setup.panel.tmuxPlan == nil)
    }

    // MARK: Consent and runs

    @Test func cancellingTheConsentRunsNothingOnTheHost() async throws {
        let setup = await makeSetup(runs: [run(0, .ok)])
        await setup.panel.loadPreflight()
        let plan = try #require(setup.panel.herdrPlan)

        setup.panel.chooseInstall(plan)
        #expect(setup.panel.sheet == .consent(plan))
        setup.panel.cancelConsent()

        #expect(setup.panel.sheet == nil)
        #expect(setup.center.runs[setup.host.id] == nil)
        #expect(await setup.connector.installPlans.isEmpty)
    }

    @Test func hidingARunLeavesItGoingAndShowOpensItAgain() async throws {
        let setup = await makeSetup(runs: [run(0, .ok)], presenceAfter: Self.herdrFound)
        await setup.connector.holdInstalls()
        await setup.panel.loadPreflight()
        let plan = try #require(setup.panel.herdrPlan)
        setup.panel.chooseInstall(plan)
        setup.panel.confirmInstall()

        guard case .running(let running) = setup.panel.sheet else {
            Issue.record("expected the run on screen, got \(String(describing: setup.panel.sheet))")
            return
        }
        #expect(running.plan == plan)

        setup.panel.hide()
        #expect(setup.panel.sheet == nil)
        #expect(setup.panel.run != nil)
        #expect(setup.panel.showsCard)

        setup.panel.show()
        #expect(setup.panel.run != nil)
        guard case .running = setup.panel.sheet else {
            Issue.record("expected the run on screen again")
            return
        }

        await setup.connector.releaseInstalls()
        try await waitUntil("the run ends") { setup.panel.outcome != nil }
        guard case .outcome(let outcome) = setup.panel.sheet else {
            Issue.record("expected the result on screen, got \(String(describing: setup.panel.sheet))")
            return
        }
        #expect(outcome.result == .found(Self.herdrFound))
    }

    @Test func aFoundResultIsSpentWhenTheUserTapsDone() async throws {
        let setup = await makeSetup(runs: [run(0, .ok)], presenceAfter: Self.herdrFound)
        await setup.panel.loadPreflight()
        setup.panel.chooseInstall(try #require(setup.panel.herdrPlan))
        setup.panel.confirmInstall()
        try await waitUntil("the run ends") { setup.panel.outcome != nil }

        setup.panel.finish()

        #expect(setup.panel.outcome == nil)
        #expect(setup.panel.sheet == nil)
    }

    @Test func retryAsksForConsentAgainBeforeAnythingRunsTwice() async throws {
        let setup = await makeSetup(runs: [run(1, .download), run(0, .ok)], presenceAfter: Self.herdrFound)
        await setup.panel.loadPreflight()
        let plan = try #require(setup.panel.herdrPlan)
        setup.panel.chooseInstall(plan)
        setup.panel.confirmInstall()
        try await waitUntil("the run fails") { setup.panel.outcome != nil }
        #expect(setup.panel.outcome?.result == .failed(.cannotReachInstaller))
        #expect(await setup.connector.installPlans.count == 1)

        setup.panel.retry(plan)

        #expect(setup.panel.sheet == .consent(plan))
        #expect(setup.panel.outcome == nil)
        #expect(await setup.connector.installPlans.count == 1, "nothing ran before the new consent")
        setup.panel.confirmInstall()
        try await waitUntil("the second run ends") { setup.panel.outcome != nil }
        #expect(await setup.connector.installPlans.count == 2)
        #expect(setup.panel.outcome?.result == .found(Self.herdrFound))
    }

    @Test func herdrInsteadOpensHerdrsOwnConsentAfterATmuxFailure() async throws {
        let setup = await makeSetup(runs: [run(1, .admin)])
        await setup.panel.loadPreflight()
        setup.panel.chooseInstall(try #require(setup.panel.tmuxPlan))
        setup.panel.confirmInstall()
        try await waitUntil("the run fails") { setup.panel.outcome != nil }
        #expect(setup.panel.outcome?.result == .failed(.needsAdmin))

        setup.panel.installHerdr()

        #expect(setup.panel.sheet == .consent(BackendInstallPlan(target: .herdr)))
        #expect(setup.panel.outcome == nil)
    }

    @Test func aMissingPasswordStopsTheRunBeforeItStarts() async throws {
        let setup = await makeSetup(
            runs: [run(0, .ok)], host: .fixture(authMethod: .password))
        await setup.panel.loadPreflight()
        // The preflight needs the same credentials, so there is no button to
        // tap: reach the consent the way a Retry would.
        setup.panel.chooseInstall(BackendInstallPlan(target: .herdr))

        setup.panel.confirmInstall()

        #expect(setup.panel.startFailure != nil)
        #expect(setup.panel.sheet == .consent(BackendInstallPlan(target: .herdr)))
        #expect(setup.center.runs[setup.host.id] == nil)
        #expect(await setup.connector.installPlans.isEmpty)
    }

    /// Two windows hold a panel for one Host through one center. When the
    /// second window takes the failure the first one shows, the first sheet
    /// is gone with no tap, and must not reopen for the second window's run.
    @Test func aSheetThatEndedByItselfStaysClosedWhenTheNextRunStarts() async throws {
        let setup = await makeSetup(runs: [run(1, .admin), run(0, .ok)], presenceAfter: Self.herdrFound)
        let console = Console(Self.neither)
        let other = BackendInstallPanelStore(
            host: setup.host, center: setup.center,
            presence: { console.presence },
            recordPresence: { console.recorded.append($0) },
            foundBackend: { console.found.append($0) },
            credentials: HostCredentialsProvider(
                deviceKeys: DeviceKeyStore(secrets: InMemorySecretStore()),
                rsaKeys: RSAKeyStore(secrets: InMemorySecretStore()),
                secrets: InMemorySecretStore()),
            knownHosts: InMemoryKnownHostsStore())
        await setup.panel.loadPreflight()
        setup.panel.chooseInstall(try #require(setup.panel.herdrPlan))
        setup.panel.confirmInstall()
        try await waitUntil("the first run fails") { setup.panel.outcome != nil }
        guard case .outcome = setup.panel.sheet else {
            Issue.record("expected the failure on screen")
            return
        }

        other.chooseInstall(BackendInstallPlan(target: .herdr))
        #expect(setup.panel.sheet == nil, "the outcome is gone, so the first sheet is gone")
        setup.panel.sheetEnded()
        other.confirmInstall()

        try await waitUntil("the second run ends") { other.outcome != nil }
        #expect(setup.panel.sheet == nil)
    }

    // MARK: Check Again

    @Test func checkAgainThatFindsHerdrReportsItWithoutWakingAndClosesTheSheet() async throws {
        let setup = await makeSetup(detected: Self.herdrFound)
        await setup.panel.loadPreflight()
        setup.panel.chooseInstall(try #require(setup.panel.herdrPlan))

        await setup.panel.checkAgain()

        #expect(setup.console.found == [Self.herdrFound])
        #expect(setup.console.recorded.isEmpty)
        #expect(await setup.connector.wakeCount == 0)
        #expect(setup.panel.sheet == nil)
        // Nothing ran: this was a look.
        #expect(await setup.connector.installPlans.isEmpty)
    }

    @Test func checkAgainThatFindsAnOldTmuxSaysSoRecordsItAndReadsTheHostAgain() async {
        let old = HostBackendPresence(herdr: false, tmuxVersion: "3.0")
        let setup = await makeSetup(detected: old)
        await setup.panel.loadPreflight()
        #expect(await setup.connector.preflightCount == 1)

        await setup.panel.checkAgain()

        #expect(setup.console.found.isEmpty)
        #expect(setup.console.recorded == [old])
        #expect(setup.panel.checkNote == "Checked just now. Found: tmux 3.0")
        #expect(await setup.connector.preflightCount == 2)
        #expect(await setup.connector.wakeCount == 0)
    }

    @Test func checkAgainOnAnUnreachableHostSaysWhyAndChangesNothing() async {
        let connector = FakeTransportConnector(
            outcome: Self.noDial, detectionError: .sshUnreachable(detail: "no route"))
        let center = BackendInstallCenter(connector: connector)
        let console = Console(Self.neither)
        let panel = BackendInstallPanelStore(
            host: .fixture(), center: center,
            presence: { console.presence },
            recordPresence: { console.recorded.append($0) },
            foundBackend: { console.found.append($0) },
            credentials: HostCredentialsProvider(
                deviceKeys: DeviceKeyStore(secrets: InMemorySecretStore()),
                rsaKeys: RSAKeyStore(secrets: InMemorySecretStore()),
                secrets: InMemorySecretStore()),
            knownHosts: InMemoryKnownHostsStore())

        await panel.checkAgain()

        #expect(panel.checkNote?.isEmpty == false)
        #expect(console.found.isEmpty)
        #expect(console.recorded.isEmpty)
        #expect(!panel.isChecking)
    }

    // MARK: herdr-core (WAY-483)

    private static let coreFound = HostBackendPresence(
        herdr: false, tmuxVersion: nil,
        core: CorePresence(version: "0.1.14", path: "/home/dev/.local/bin/herdr-core"))

    @Test func coreIsOfferedOnAHostWithNeitherAndOnAHostWithATooOldTmux() async {
        let bare = await makeSetup()
        await bare.panel.loadPreflight()
        #expect(bare.panel.corePlan?.target == .core)

        let old = await makeSetup(presence: HostBackendPresence(herdr: false, tmuxVersion: "3.0"))
        await old.panel.loadPreflight()
        #expect(old.panel.corePlan?.target == .core)
        #expect(old.panel.herdrPlan != nil)
        #expect(old.panel.tmuxPlan == nil)
    }

    @Test func noCoreOfferOnAHostThatHasARuntime() async {
        let setup = await makeSetup(presence: Self.coreFound)
        await setup.panel.loadPreflight()

        #expect(setup.panel.gap == nil)
        #expect(setup.panel.corePlan == nil)
        #expect(setup.panel.coreUnavailableReason == nil)
    }

    @Test func noCurlHidesInstallCoreAndSaysWhy() async {
        let setup = await makeSetup(preflight: .success(Self.facts(curl: false)))
        await setup.panel.loadPreflight()

        #expect(setup.panel.corePlan == nil)
        #expect(
            setup.panel.coreUnavailableReason
                == "\(setup.host.displayName) has no curl. herdr-core’s installer needs it.")
    }

    @Test func aCoreInstallAsksConsentRunsTheCoreInstallerAndIsFoundWithNoWake() async throws {
        let setup = await makeSetup(runs: [run(0, .ok)], presenceAfter: Self.coreFound)
        await setup.panel.loadPreflight()
        let plan = try #require(setup.panel.corePlan)

        setup.panel.chooseInstall(plan)
        #expect(setup.panel.sheet == .consent(plan))
        #expect(await setup.connector.installPlans.isEmpty)
        setup.panel.confirmInstall()
        try await waitUntil("the run ends") { setup.panel.outcome != nil }

        #expect(setup.panel.outcome?.result == .found(Self.coreFound))
        #expect(await setup.connector.installPlans == [plan])
        // A fresh core is started by the first connect, not by the install.
        #expect(await setup.connector.wakeCount == 0)
    }

    @Test func aCoreInstallThatLeavesNoCoreAtTheFloorIsNotFound() async throws {
        let setup = await makeSetup(runs: [run(0, .ok)], presenceAfter: Self.neither)
        await setup.panel.loadPreflight()
        setup.panel.chooseInstall(try #require(setup.panel.corePlan))
        setup.panel.confirmInstall()
        try await waitUntil("the run ends") { setup.panel.outcome != nil }

        guard case .failed(.other)? = setup.panel.outcome?.result else {
            Issue.record("expected a failure, got \(String(describing: setup.panel.outcome?.result))")
            return
        }
    }

    @Test func checkAgainThatFindsOnlyCoreReportsItAndNamesItWithoutWakingHerdr() async {
        let setup = await makeSetup(detected: Self.coreFound)
        await setup.panel.loadPreflight()

        await setup.panel.checkAgain()

        #expect(setup.console.found == [Self.coreFound])
        #expect(await setup.connector.wakeCount == 0)
    }
}
