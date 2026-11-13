import Foundation
import Testing

@testable import Waycar

/// What the app decides about Waycar's Host Tools on a herdr-core Host: which
/// install mode a detection reads, which plugin version a Host needs, how the
/// installer's success line reads, and where a `hc:<address>` row lands.
@Suite("herdr-core Host Tools in the app")
struct CoreHostToolsAppTests {
    // MARK: Install mode

    private static let corePath = "/home/me/.local/bin/herdr-core"
    private static let root = "/home/me/.local/share/waycar/plugin"

    /// The plugin a detection output reads, from the Host's backend lines
    /// and a Host Tools install at 2.2.1.
    private static func plugin(
        _ lines: [String], pluginList: [String]? = nil, tools: Bool = true
    ) -> WaycarPluginDetection? {
        var body = lines
        if let pluginList {
            body += [HostBackendDetection.pluginListBegin] + pluginList
                + [HostBackendDetection.pluginListEnd]
        }
        body += tools
            ? [
                "\(HostBackendDetection.hostToolsVersionPrefix)version = \"2.2.1\"",
                "\(HostBackendDetection.hostToolsRootPrefix)\(root)",
            ]
            : [HostBackendDetection.hostToolsNoneLine]
        let output = ([HostBackendDetection.beginMarker] + body + [HostBackendDetection.endMarker])
            .map { $0 + "\n" }.joined()
        return HostBackendDetection.presence(fromOutput: Data(output.utf8))?.waycarPlugin
    }

    private static let coreLines = ["core=0.1.14", "corepath=\(corePath)"]

    private static func mode(_ detection: WaycarPluginDetection?) -> WaycarPluginInstall.Mode? {
        guard case .installed(let install)? = detection else { return nil }
        return install.mode
    }

    @Test func hostToolsOnAHostWithOnlyHerdrCoreAreInCoreMode() {
        #expect(Self.mode(Self.plugin(Self.coreLines)) == .core)
        // A tmux too old to count is no tmux.
        #expect(Self.mode(Self.plugin(Self.coreLines + ["tmux=tmux 2.7"])) == .core)
    }

    @Test func aUsableTmuxOrNoCoreKeepsTmuxMode() {
        #expect(Self.mode(Self.plugin(Self.coreLines + ["tmux=tmux 3.4"])) == .tmux)
        #expect(Self.mode(Self.plugin(["tmux=tmux 3.4"])) == .tmux)
        #expect(Self.mode(Self.plugin([])) == .tmux)
    }

    /// install.sh picks herdr whenever herdr is on the PATH, so a Host with
    /// the TUI keeps herdr mode (list unreadable) or the `--tmux` flag (list
    /// readable, plugin not enabled), never core mode.
    @Test func aHostWithTheTUIIsNeverInCoreMode() {
        #expect(Self.mode(Self.plugin(["herdr=path"] + Self.coreLines)) == .herdr)
        #expect(
            Self.mode(Self.plugin(["herdr=path"] + Self.coreLines, pluginList: ["{\"result\":{\"plugins\":[]}}"]))
                == .tmux)
    }

    @Test func noHostToolsIsNotInstalledOnACoreHost() {
        #expect(Self.plugin(Self.coreLines, tools: false) == .notInstalled)
    }

    @Test func coreModeUpdatesNeedNoInstallerFlagButTmuxModeKeepsItsOwn() {
        func arguments(_ mode: WaycarPluginInstall.Mode?) -> [String] {
            WaycarPluginUpdate.installerArguments(
                for: WaycarPluginUpdateRequest(mode: mode, refreshHooks: true))
        }
        #expect(arguments(.core) == [])
        #expect(arguments(.tmux) == ["--tmux"])
        #expect(arguments(.herdr) == [])
    }

    // MARK: Which plugin a Host needs

    private static func installed(_ version: String) -> WaycarPluginDetection {
        .installed(WaycarPluginInstall(version: version, mode: .tmux, root: root))
    }

    @Test func aHostThatUsesCoreNeedsTheCoreModePlugin() {
        #expect(WaycarPluginRequirement.coreMinimumVersion == "2.2.0")
        for backends in [[HostBackend.core], [.core, .tmux]] {
            #expect(
                WaycarPluginRequirement.status(of: Self.installed("2.1.0"), backends: backends)
                    == .outdated(installed: "2.1.0", required: "2.2.0"))
            #expect(
                WaycarPluginRequirement.status(of: Self.installed("2.2.0"), backends: backends)
                    == .current(version: "2.2.0"))
        }
    }

    /// The pick decides: a Host with both runtimes that uses the TUI is
    /// measured as before, and so is every Host without core.
    @Test func otherHostsKeepTheOldMinimum() {
        for backends in [[HostBackend.herdr], [.herdr, .tmux], [.tmux], []] {
            #expect(
                WaycarPluginRequirement.status(of: Self.installed("2.1.0"), backends: backends)
                    == .current(version: "2.1.0"), "\(backends)")
            #expect(
                WaycarPluginRequirement.minimumVersion(for: backends)
                    == WaycarPluginRequirement.minimumVersion)
        }
        #expect(
            WaycarPluginRequirement.status(of: .notInstalled, backends: [.core]) == .notInstalled)
        #expect(WaycarPluginRequirement.status(of: nil, backends: [.core]) == .unknown)
    }

    // MARK: The installer's success line

    @Test(arguments: [
        ("waycar: installed Waycar plugin 2.2.1", "2.2.1"),
        ("waycar: installed Waycar 2.2.1 in /home/me/.local/share/waycar/plugin", "2.2.1"),
        ("waycar: installed Waycar 2.0.0 for tmux in /home/me/.local/share/waycar/plugin", "2.0.0"),
        ("waycar: installed Waycar 1.4.0-beta.1 in /x", "1.4.0-beta.1"),
    ])
    func theInstalledVersionReadsFromEveryWording(line: String, version: String) {
        #expect(WaycarPluginUpdate.installedVersion(in: line) == version)
    }

    @Test(arguments: [
        "waycar: installed the opencode Chat Prompt extension in /home/me/.config/opencode/plugins",
        "waycar: installed Waycar 2.2.1",
        "installed Waycar 2.2.1 in /x",
        "waycar: setting Waycar up for herdr-core 0.1.14",
    ])
    func otherInstallerLinesAreNoVersion(line: String) {
        #expect(WaycarPluginUpdate.installedVersion(in: line) == nil)
    }

    // MARK: core_enabled

    @Test func coreEnabledKeepsEveryOtherField() throws {
        let config = Data(#"{"debounce_ms":500,"tmux_enabled":false,"relay_url":"https://r.example"}"#.utf8)

        let off = try ConsoleStore.settingCoreEnabled(false, in: config)
        let fields = try JSONDecoder().decode([String: JSONValue].self, from: off)
        #expect(
            fields == [
                "debounce_ms": .number(500), "tmux_enabled": .bool(false),
                "relay_url": .string("https://r.example"), "core_enabled": .bool(false),
            ])

        let fresh = try ConsoleStore.settingCoreEnabled(true, in: nil)
        #expect(try JSONDecoder().decode([String: JSONValue].self, from: fresh) == ["core_enabled": .bool(true)])
        let unreadable = try ConsoleStore.settingCoreEnabled(true, in: Data("not json".utf8))
        #expect(
            try JSONDecoder().decode([String: JSONValue].self, from: unreadable)
                == ["core_enabled": .bool(true)])
    }

    // MARK: Where a core row lands

    @MainActor
    @Test func aTappedCoreRowOpensItsDetailAndHasNoTerminalOwnership() {
        let hostID = UUID()
        let row = ConsoleAgent(
            hostID: hostID, hostName: "lab",
            agent: Agent(.fixture(paneID: "hc:t7")),
            workspaceLabel: nil, repositoryCheckout: nil, backend: .core)
        let router = AgentNotificationRouter()
        router.agentsDidChange([row])

        router.open(AgentNotificationTarget(hostID: hostID, paneID: "hc:t7"))

        #expect(router.path == [row.id])
        #expect(router.backend(of: row.id) == .core)
        #expect(router.backend(of: ConsoleAgent.ID(hostID: hostID, paneID: "wV:p1")) == .herdr)
    }

    /// A push that arrives before the Host's first sync waits for its row.
    @MainActor
    @Test func aCorePushWaitsForItsRowLikeAnyOther() {
        let hostID = UUID()
        let router = AgentNotificationRouter()
        let target = AgentNotificationTarget(hostID: hostID, paneID: "hc:t7")

        router.open(target)
        #expect(router.pendingTarget == target)
        router.agentsDidChange([
            ConsoleAgent(
                hostID: hostID, hostName: "lab", agent: Agent(.fixture(paneID: "hc:t7")),
                workspaceLabel: nil, repositoryCheckout: nil, backend: .core)
        ])

        #expect(router.path == [target.agentID])
        #expect(router.pendingTarget == nil)
    }
}
