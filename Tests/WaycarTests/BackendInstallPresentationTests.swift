import Foundation
import Testing

@testable import Waycar

/// What the install panel says (WAY-338): which Hosts have a gap, what the
/// consent sheet promises, and which screen each way an install ends gets.
@Suite("Backend install presentation")
struct BackendInstallPresentationTests {
    private static let herdrPlan = BackendInstallPlan(target: .herdr)
    private static let tmuxPlan = BackendInstallPlan(target: .tmux(.aptGet))

    private func screen(
        _ result: BackendInstallResult, plan: BackendInstallPlan = herdrPlan
    ) -> BackendInstallOutcomeScreen {
        BackendInstallOutcomeScreen(
            outcome: BackendInstallCenter.Outcome(plan: plan, result: result), hostName: "Studio VPS")
    }

    // MARK: Gap

    @Test func aGapIsNeitherBackendOrATmuxUnderTheFloorWithNoHerdr() {
        #expect(HostBackendGap(presence: nil) == nil)
        #expect(HostBackendGap(presence: HostBackendPresence(herdr: true, tmuxVersion: nil)) == nil)
        #expect(HostBackendGap(presence: HostBackendPresence(herdr: true, tmuxVersion: "2.7")) == nil)
        #expect(HostBackendGap(presence: HostBackendPresence(herdr: false, tmuxVersion: "3.2")) == nil)
        #expect(HostBackendGap(presence: HostBackendPresence(herdr: false, tmuxVersion: "next-3.6")) == nil)
        #expect(HostBackendGap(presence: HostBackendPresence(herdr: false, tmuxVersion: nil)) == .noBackend)
        #expect(
            HostBackendGap(presence: HostBackendPresence(herdr: false, tmuxVersion: "3.0"))
                == .tmuxTooOld(found: "3.0"))
    }

    @Test func onlyAHostWithNoTmuxIsOfferedInstallTmux() {
        #expect(HostBackendGap.noBackend.offersTmux)
        #expect(!HostBackendGap.tmuxTooOld(found: "3.0").offersTmux)
    }

    @Test func theConsoleBannerNamesTheGapAndOpensThePanelWhateverTheTransportReported() {
        let host = Host.fixture(name: "Studio VPS")
        let neither = ConsoleHostStatusPresentation(host: host, backendGap: .noBackend)
        let old = ConsoleHostStatusPresentation(host: host, backendGap: .tmuxTooOld(found: "3.0"))

        #expect(neither.message == "Studio VPS: No tmux or herdr on this Host. Tap to set up.")
        #expect(old.message == "Studio VPS: tmux on this Host is too old. Tap to set up.")
        for row in [neither, old] {
            #expect(row.opensBackendInstall)
            #expect(row.navigates)
            #expect(row.severity == .warning)
            #expect(!row.isPluginRow)
        }
    }

    // MARK: Consent

    @Test func herdrConsentSaysWhatTheInstallerDoesAndNothingMore() {
        let consent = BackendInstallConsent(plan: Self.herdrPlan)
        let text = consent.bullets.map(\.text).joined(separator: " ")

        // The command shown is the command that runs.
        #expect(consent.command == Self.herdrPlan.command)
        #expect(text.contains("~/.local/bin/herdr"))
        #expect(text.contains("checks the download against herdr.dev’s checksum"))
        #expect(text.contains("no admin rights"))
        #expect(text.contains("no shell files"))
        // A checked download is not a safe one, and the consent never says so.
        for word in ["safe", "verified", "trusted"] {
            #expect(!text.lowercased().contains(word), "\(word)")
        }
        #expect(consent.sourceNote.contains("not affiliated with herdr"))
    }

    @Test func tmuxConsentNamesTheManagerAndWhetherItUsesSudo() {
        let sudo = BackendInstallConsent(plan: BackendInstallPlan(target: .tmux(.dnf)))
        #expect(sudo.command == "sudo -n dnf install -y tmux")
        #expect(sudo.bullets.map(\.text).contains { $0.contains("dnf, using sudo without a password") })
        #expect(sudo.bullets.map(\.text).contains { $0.contains("Waycar never asks for one") })
        #expect(sudo.sourceNote.contains("(dnf)"))

        let root = BackendInstallConsent(
            plan: BackendInstallPlan(target: .tmux(.aptGet), runsAsRoot: true))
        #expect(root.command == "apt-get install -y tmux")
        #expect(!root.bullets.map(\.text).contains { $0.contains("sudo without") })

        let brew = BackendInstallConsent(plan: BackendInstallPlan(target: .tmux(.brew)))
        #expect(brew.command == "brew install tmux")
        #expect(brew.bullets.map(\.text).contains { $0.contains("no admin rights") })
    }

    // MARK: Outcomes

    @Test func aFoundHerdrShowsFoundWithNoExtraAction() {
        let found = screen(.found(HostBackendPresence(herdr: true, tmuxVersion: nil)))

        #expect(found.tone == .found)
        #expect(found.title == "Herdr TUI Found")
        #expect(found.reason == "Herdr TUI found on Studio VPS")
        #expect(found.note == nil)
        #expect(found.extra == nil)
        #expect(found.announcement == "Herdr TUI found on Studio VPS.")
    }

    @Test func aFoundTmuxWithoutHostToolsSaysAgentsShowUnknown() {
        let bare = screen(
            .found(HostBackendPresence(herdr: false, tmuxVersion: "3.4")), plan: Self.tmuxPlan)
        #expect(bare.reason == "tmux 3.4 found on Studio VPS")
        #expect(bare.note != nil)
        #expect(bare.announcement.contains("Agents show Unknown"))

        let withTools = screen(
            .found(
                HostBackendPresence(
                    herdr: false, tmuxVersion: "3.4",
                    waycarPlugin: .installed(WaycarPluginInstall(version: "1.4.0", mode: .tmux)))),
            plan: Self.tmuxPlan)
        #expect(withTools.note == nil)
        #expect(!withTools.announcement.contains("Unknown"))
    }

    @Test func noSudoOffersHerdrInsteadAndTheCommandAPersonTypes() {
        let failed = screen(.failed(.needsAdmin), plan: Self.tmuxPlan)

        #expect(failed.tone == .failed)
        #expect(failed.reason == "tmux needs admin rights. sudo on Studio VPS asked for a password.")
        #expect(failed.extra == .installHerdrInstead)
        // The exec runs `sudo -n`; a person at a terminal types plain sudo.
        #expect(failed.command == "sudo apt-get install -y tmux")
        #expect(failed.announcement.hasPrefix("Install failed."))
    }

    @Test func anUnreachableInstallerOffersRetry() {
        let failed = screen(.failed(.cannotReachInstaller))

        #expect(failed.reason == "Studio VPS could not reach herdr.dev.")
        #expect(failed.extra == .retry)
        #expect(failed.command == Self.herdrPlan.copyCommand)
    }

    @Test func aTmuxThatIsStillTooOldLeadsWithHerdrAndCopiesHerdrsCommand() {
        let failed = screen(.failed(.tmuxTooOld(found: "3.0")), plan: Self.tmuxPlan)

        #expect(failed.tone == .warning)
        #expect(failed.title == "tmux Too Old")
        #expect(failed.extra == .installHerdr)
        #expect(failed.command == Self.herdrPlan.copyCommand)
        #expect(
            failed.announcement
                == "Install finished, but tmux is still too old. Waycar needs 3.2 or later.")
    }

    @Test func failuresNoCommandCouldFixOfferNothingToCopy() {
        for failure in [
            BackendInstallFailure.noCurl, .noPackageManager, .unsupportedSystem,
        ] {
            #expect(screen(.failed(failure)).command == nil, "\(failure)")
        }
        #expect(screen(.failed(.noPackageManager), plan: Self.tmuxPlan).extra == .installHerdrInstead)
    }

    @Test func anUnnamedFailureShowsTheInstallersLastLineLocally() {
        let failed = screen(.failed(.other(lastLine: "E: Unable to locate package tmux")))

        #expect(failed.lastLine == "E: Unable to locate package tmux")
        #expect(failed.extra == .retry)
    }

    @Test func aLostLinkIsNotAFailureAndNeverClaimsTheInstallFailed() {
        let lost = screen(.hostUnreachable(.channelFailed(detail: "The connection ended.")))

        #expect(lost.title == "Install Not Confirmed")
        #expect(lost.extra == nil)
        #expect(lost.hint?.contains("Check Again") == true)
        #expect(lost.announcement.hasPrefix("Install not confirmed."))
    }

    // MARK: herdr-core (WAY-483, copy decided in WAY-482)

    private static let corePlan = BackendInstallPlan(target: .core)

    @Test func theThreeInstallButtonsAreNamedAndExplainedAsProductDecided() {
        #expect(BackendInstallTarget.herdr.installTitle == "Install Herdr TUI")
        #expect(BackendInstallTarget.tmux(.aptGet).installTitle == "Install tmux")
        #expect(BackendInstallTarget.core.installTitle == "Install Herdr Core")
        #expect(
            BackendInstallTarget.herdr.buttonDetail
                == "The terminal app. No admin rights. Adds one file in ~/.local/bin.")
        #expect(
            BackendInstallTarget.tmux(.aptGet).buttonDetail
                == "Needs admin rights on the Host (sudo without a password) or Homebrew.")
        #expect(
            BackendInstallTarget.core.buttonDetail
                == "For the Herdr app. Alerts and Chat Mode aren’t available on it yet. "
                + "No admin rights. Adds herdr-core to ~/.local/bin.")
    }

    @Test func theGapCopyNamesBothHerdrRuntimesAndStillTitlesTheOldWay() {
        #expect(HostBackendGap.noBackend.title == "No tmux or herdr on this Host")
        #expect(
            HostBackendGap.noBackend.explanation(hostName: "Studio VPS")
                == "Agents run inside Herdr TUI, herdr-core or tmux. "
                + "Studio VPS has none of them, so New Agent has nowhere to Launch one.")
        #expect(
            HostBackendGap.tmuxTooOld(found: "3.0").explanation(hostName: "Studio VPS")
                == "Waycar needs tmux 3.2 or later. Studio VPS has tmux 3.0. "
                + "Herdr TUI and herdr-core need no admin rights.")
        // Core needs no admin rights, so both gaps offer it.
        #expect(HostBackendGap.noBackend.offersCore)
        #expect(HostBackendGap.tmuxTooOld(found: "3.0").offersCore)
    }

    @Test func aHostWithOnlyCoreHasNoGap() {
        let coreOnly = HostBackendPresence(
            herdr: false, tmuxVersion: nil,
            core: CorePresence(version: "0.1.14", path: "/home/dev/.local/bin/herdr-core"))
        #expect(HostBackendGap(presence: coreOnly) == nil)
    }

    @Test func coreConsentIsTheApprovedCopyAndRunsTheCommandItShows() {
        let consent = BackendInstallConsent(plan: Self.corePlan)

        #expect(consent.title == "Install Herdr Core?")
        #expect(consent.confirmTitle == "Install Herdr Core")
        #expect(consent.command == Self.corePlan.command)
        #expect(
            consent.bullets.map(\.text) == [
                "Downloads herdr-core’s installer and runs it on the Host over SSH.",
                "Adds herdr-core to ~/.local/bin, and the folder if it is missing. "
                    + "Adds an hc shortcut there unless an hc already exists. "
                    + "The installer checks the download against Herdr’s published checksum.",
                "Uses no admin rights. Edits no shell files.",
                "Agents show a status only if they report one to herdr-core. Others show Unknown. "
                    + "Alerts and Chat Mode aren’t available on herdr-core yet.",
            ])
        #expect(
            consent.sourceNote
                == "herdr-core’s installer from releases.herdr.dev. Waycar is not affiliated with herdr.")
        // Core needs no wake step, so no bullet says Waycar starts anything.
        #expect(!consent.bullets.map(\.text).joined().contains("starts herdr"))
        // The not-affiliated sentence is the TUI sheet's, word for word.
        let tui = BackendInstallConsent(plan: Self.herdrPlan).sourceNote
        #expect(tui.hasSuffix("Waycar is not affiliated with herdr."))
        #expect(consent.sourceNote.hasSuffix("Waycar is not affiliated with herdr."))
    }

    @Test func theTUIConsentCarriesTheTUIName() {
        let consent = BackendInstallConsent(plan: Self.herdrPlan)
        #expect(consent.title == "Install Herdr TUI?")
        #expect(consent.confirmTitle == "Install Herdr TUI")
    }

    @Test func aFoundCoreSaysAlertsAndChatModeAreNotThereYetAndOffersNothingElse() {
        let found = screen(
            .found(
                HostBackendPresence(
                    herdr: false, tmuxVersion: nil,
                    core: CorePresence(version: "0.1.14", path: "/home/dev/.local/bin/herdr-core"))),
            plan: Self.corePlan)

        #expect(found.tone == .found)
        #expect(found.title == "Herdr Core Found")
        #expect(found.reason == "Herdr Core found on Studio VPS")
        #expect(found.note == "Alerts and Chat Mode aren’t available on herdr-core yet.")
        #expect(found.extra == nil)
        #expect(found.command == nil)
    }

    @Test func coreFailuresNameCoreAndItsInstallerNotHerdr() {
        let curl = screen(.failed(.noCurl), plan: Self.corePlan)
        #expect(curl.reason == "Studio VPS has no curl. herdr-core’s installer needs it.")
        #expect(curl.command == nil)

        let tar = screen(.failed(.noTar), plan: Self.corePlan)
        #expect(tar.reason == "Studio VPS has no tar. herdr-core’s installer needs it.")
        #expect(tar.command == nil)
        #expect(tar.tone == .failed)

        let unreachable = screen(.failed(.cannotReachInstaller), plan: Self.corePlan)
        #expect(unreachable.reason == "Studio VPS could not reach releases.herdr.dev.")
        #expect(unreachable.extra == .retry)
        #expect(unreachable.command == Self.corePlan.copyCommand)

        let system = screen(.failed(.unsupportedSystem), plan: Self.corePlan)
        #expect(system.reason == "herdr-core does not support the system on Studio VPS.")
        #expect(system.command == nil)

        let other = screen(.failed(.other(lastLine: "hc: the download is damaged")), plan: Self.corePlan)
        #expect(other.lastLine == "hc: the download is damaged")
        #expect(other.extra == .retry)
    }
}
