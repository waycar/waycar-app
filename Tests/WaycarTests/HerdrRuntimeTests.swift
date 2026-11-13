import Foundation
import Testing

@testable import Waycar

/// Runtime inventories and TUI-first lead resolve from detection alone.
@Suite("Herdr runtime resolution")
struct HerdrRuntimeResolutionTests {
    private static let core = CorePresence(
        version: "0.1.14", path: "/home/dev/.local/bin/herdr-core")

    /// One row of the design's table, as an input and its herdr slot.
    struct Row: Sendable, CustomTestStringConvertible {
        let herdr: Bool
        let core: Bool
        /// The herdr slot; nil when neither runtime is found.
        let slot: HostBackend?

        var testDescription: String {
            "TUI \(herdr), core \(core) -> \(slot?.rawValue ?? "none")"
        }
    }

    static let rows: [Row] = [
        Row(herdr: true, core: false, slot: .herdr),
        Row(herdr: false, core: true, slot: .core),
        Row(herdr: true, core: true, slot: .herdr),
        Row(herdr: false, core: false, slot: nil),
    ]

    /// tmux as detection can report it: absent, usable, and too old.
    static let tmuxVersions: [String?] = [nil, "3.4", "2.7"]

    private func presence(_ row: Row, tmux: String?) -> HostBackendPresence {
        HostBackendPresence(
            herdr: row.herdr, tmuxVersion: tmux, core: row.core ? Self.core : nil)
    }

    @Test(arguments: rows)
    func everyRowOfTheTableResolvesWithAndWithoutTmux(_ row: Row) {
        for tmux in Self.tmuxVersions {
            let presence = presence(row, tmux: tmux)
            let usable = presence.tmuxUsable
            let expected: [HostBackend]
            if let slot = row.slot {
                let runtimes: [HostBackend] = row.herdr && row.core ? [.herdr, .core] : [slot]
                expected = usable ? runtimes + [.tmux] : runtimes
                #expect(presence.herdrSlot == slot)
            } else {
                // No herdr runtime: any tmux gets its projection (it reports a
                // too-old tmux itself); with neither, herdr's projection
                // reports what is missing.
                expected = tmux == nil ? [.herdr] : [.tmux]
            }
            #expect(
                presence.backends == expected,
                "tmux \(tmux ?? "absent")")
        }
    }

    @Test func bothRuntimesFoundIsAboutDetection() {
        #expect(HostBackendPresence(herdr: true, tmuxVersion: nil, core: Self.core).bothRuntimesFound)
        #expect(!HostBackendPresence(herdr: true, tmuxVersion: nil).bothRuntimesFound)
        #expect(!HostBackendPresence(herdr: false, tmuxVersion: nil, core: Self.core).bothRuntimesFound)
    }

    @Test func aPresenceCachedBeforeCoreStillDecodesWithoutIt() throws {
        let old = Data(#"{"herdr":true,"tmuxVersion":"3.4"}"#.utf8)
        let decoded = try JSONDecoder().decode(HostBackendPresence.self, from: old)
        #expect(decoded == HostBackendPresence(
            herdr: true, tmuxVersion: "3.4", codexProbed: nil, opencodeProbed: nil))
        #expect(decoded.core == nil)
    }

    @Test func aPresenceWithCoreRoundTrips() throws {
        let presence = HostBackendPresence(herdr: false, tmuxVersion: "3.4", core: Self.core)
        let data = try JSONEncoder().encode(presence)
        #expect(try JSONDecoder().decode(HostBackendPresence.self, from: data) == presence)
    }

    /// herdr-core is a herdr runtime: a Host with only core has nothing
    /// missing for New Agent.
    @Test func aCoreOnlyHostHasNoBackendGap() {
        let coreOnly = HostBackendPresence(herdr: false, tmuxVersion: nil, core: Self.core)
        #expect(HostBackendGap(presence: coreOnly) == nil)
        let oldTmux = HostBackendPresence(herdr: false, tmuxVersion: "2.7", core: Self.core)
        #expect(HostBackendGap(presence: oldTmux) == nil)
        #expect(HostBackendGap(presence: HostBackendPresence(herdr: false, tmuxVersion: nil)) == .noBackend)
    }

    @Test(arguments: [
        ("0.1.10", true), ("0.1.14", true), ("0.1.100", true), ("0.2.0", true), ("1.0.0", true),
        ("0.1.10-rc1", true), ("0.1.9", false), ("0.0.99", false), ("0.1", false),
        ("garbage", false), ("", false),
    ])
    func theFloorIsZeroOneTen(_ version: String, _ meets: Bool) {
        #expect(CorePresence(version: version, path: "/x").meetsFloor == meets)
    }

    @Test func coreStartsAgentsButNotTheTUIsExtras() {
        #expect(HostBackend.core.capabilities.startsAgents)
        #expect(!HostBackend.core.capabilities.takeover)
        #expect(!HostBackend.core.capabilities.pluginRowLayout)
        #expect(!HostBackend.core.capabilities.namedSessions)
        #expect(!HostBackend.core.capabilities.worktrees)
        #expect(!HostBackend.core.capabilities.renaming)
        // herdr and tmux keep what they had.
        #expect(HostBackend.herdr.capabilities.takeover)
        #expect(HostBackend.herdr.capabilities.pluginRowLayout)
        #expect(HostBackend.tmux.capabilities.worktrees)
    }

    @Test func theHerdrSlotIsHerdrOrCoreNeverTmux() {
        #expect(HostBackend.herdr.fillsHerdrSlot)
        #expect(HostBackend.core.fillsHerdrSlot)
        #expect(!HostBackend.tmux.fillsHerdrSlot)
    }

    @Test func rawValuesAndDisplayNamesAreStable() {
        #expect(HostBackend.core.rawValue == "core")
        #expect(HostBackend.allCases == [.herdr, .core, .tmux, .zellij, .ultimate, .codex, .opencode])
        #expect(HostBackend.opencode.rawValue == "opencode" && HostBackend.opencode.displayName == "OpenCode")
        #expect(HostBackend.herdr.displayName == "Herdr TUI")
        #expect(HostBackend.core.displayName == "Herdr Core")
        #expect(HerdrRuntime.tui.displayName == "Herdr TUI")
        #expect(HerdrRuntime.core.displayName == "Herdr Core")
        #expect(HerdrRuntime.tui.backend == .herdr && HerdrRuntime.core.backend == .core)
    }

    @Test(arguments: [
        (false, false, false, ConsoleSnapshot.Backend.herdr),
        (true, false, false, .herdr),
        (false, false, true, .tmux),
        (true, false, true, .both),
        (false, true, false, .core),
        (false, true, true, .coreTmux),
        (true, true, false, .herdrCore),
        (true, true, true, .all),
    ])
    func theConsoleAnalyticsNamesWhatTheConnectedHostsRun(
        herdr: Bool, core: Bool, tmux: Bool, expected: ConsoleSnapshot.Backend
    ) {
        #expect(ConsoleSnapshot.Backend(herdr: herdr, core: core, tmux: tmux) == expected)
    }

    @Test func theAnalyticsWordsForCoreAreFixed() {
        #expect(
            ConsoleSnapshot.Backend.allCases.map(\.rawValue)
                == ["herdr", "tmux", "both", "core", "core_tmux", "herdr_core", "all"])
    }

    @Test func theCoreBadgeMarksOnlyAHostWhoseOnlyBackendIsCore() {
        #expect(CoreBadge.isShown(for: [.core]))
        #expect(!CoreBadge.isShown(for: [.core, .tmux]))
        #expect(!CoreBadge.isShown(for: [.herdr]))
        #expect(!CoreBadge.isShown(for: [.tmux]))
        #expect(!CoreBadge.isShown(for: nil))
    }
}

@MainActor
@Suite("Herdr runtime visibility")
struct HerdrRuntimeVisibilityTests {
    @Test func runtimeVisibilitySurvivesAnOlderBuildRewritingBackendPreferences() throws {
        let defaults = makeDefaults()
        let host = UUID()
        let preferences = HostBackendPreferences(defaults: defaults)
        preferences.setShowsRuntime(false, runtime: .core, for: host)
        let data = try #require(defaults.data(forKey: HostBackendPreferences.runtimeVisibilityKey))
        #expect(HostBackendPreferences.canReadRuntimeVisibility(data))
        #expect(!HostBackendPreferences.canReadRuntimeVisibility(Data(#"{"version":2,"hosts":{}}"#.utf8)))
        defaults.set(Data(#"{"version":1,"hosts":{}}"#.utf8),
                     forKey: HostBackendPreferences.defaultsKey)
        preferences.reload()
        #expect(!preferences.showsRuntime(.core, for: host))
        #expect(!HostBackendPreferences(defaults: defaults).showsRuntime(.core, for: host))
    }

    private func makeDefaults() -> UserDefaults {
        let name = "herdr-runtime-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func runtimeVisibilityPersistsIndependently() {
        let defaults = makeDefaults()
        let host = UUID()
        let preferences = HostBackendPreferences(defaults: defaults)
        #expect(preferences.showsRuntime(.tui, for: host))
        #expect(preferences.showsRuntime(.core, for: host))
        preferences.setShowsRuntime(false, runtime: .core, for: host)
        let reloaded = HostBackendPreferences(defaults: defaults)
        #expect(!reloaded.showsRuntime(.core, for: host))
        #expect(reloaded.showsRuntime(.tui, for: host))
        reloaded.setShowsRuntime(true, runtime: .core, for: host)
        #expect(HostBackendPreferences(defaults: defaults).showsRuntime(.core, for: host))
    }
}

@Suite("Herdr-core preflight")
struct HerdrCorePreflightTests {
    @Test func theChecklistIsTheConnectionThenDetectionThenTheTransport() {
        #expect(
            PreflightCheck.checks(for: .core)
                == [
                    .connection, .remoteEnvironment, .coreInstalled, .coreVersion, .coreHello,
                    .coreEvents,
                ])
    }

    @Test func aFoundCoreAtTheFloorPassesEveryCheck() {
        let presence = HostBackendPresence(
            herdr: false, tmuxVersion: nil,
            core: CorePresence(version: "0.1.10", path: "/home/dev/.local/bin/herdr-core"))
        let report = PreflightReport.core(presence: presence)

        #expect(report.backend == .core)
        #expect(report.isFullyPassed)
        for check in PreflightCheck.checks(for: .core) {
            #expect(report[check] == .passed)
        }
    }

    @Test func aMissingCoreFailsItsInstalledCheckAndBlocksTheVersionCheck() {
        let report = PreflightReport.core(presence: HostBackendPresence(herdr: false, tmuxVersion: nil))

        #expect(!report.isFullyPassed)
        #expect(report[.connection] == .passed)
        guard case .failed(let hint) = report[.coreInstalled] else {
            Issue.record("herdr-core installed should fail")
            return
        }
        #expect(
            hint == "Herdr Core was not found on the Host. "
                + "Install herdr-core there, then run the checks again.")
        #expect(report[.coreVersion] == .blocked)
    }

    @Test func aCoreBelowTheFloorSaysToUpdateIt() {
        let report = PreflightReport.core(
            presence: HostBackendPresence(
                herdr: false, tmuxVersion: nil,
                core: CorePresence(version: "0.1.9", path: "/usr/local/bin/herdr-core")))

        #expect(report[.coreInstalled] == .passed)
        guard case .failed(let hint) = report[.coreVersion] else {
            Issue.record("the version check should fail")
            return
        }
        #expect(hint.contains("0.1.9"))
        #expect(hint.contains("0.1.10"))
        #expect(hint.contains("herdr-core update"))
    }

    @Test func aConnectionFailureOnCoreKeepsItsConnectionCheck() {
        let report = PreflightReport.failure(
            .sshUnreachable(detail: "refused"), authMethod: .password, backend: .core)

        #expect(report.backend == .core)
        guard case .failed = report[.connection] else {
            Issue.record("the connection check should fail")
            return
        }
        #expect(report[.coreInstalled] == .blocked)
    }
}
