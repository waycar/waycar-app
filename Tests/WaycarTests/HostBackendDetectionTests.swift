import Foundation
import Testing

@testable import Waycar

@Suite("Host backend detection")
struct HostBackendDetectionTests {
    @Test func allDetectionLoopsRunInsidePOSIXShell() {
        let command = HostBackendDetection.command(socket: .defaultSession, probesPlugin: true)
        let quoted = command.components(separatedBy: "'")
        let outer = quoted.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element).joined()
        #expect(outer.contains("/bin/sh -c"))
        #expect(!outer.contains("for "))
        #expect(!outer.contains("do"))
        #expect(quoted.contains(where: { $0.contains("for home in") && $0.contains("\\000") }))
    }

    private func output(_ lines: [String], lineEnding: String = "\n") -> Data {
        Data(lines.map { $0 + lineEnding }.joined().utf8)
    }

    private func detected(_ body: [String], before: [String] = [], after: [String] = []) -> [String] {
        before + [HostBackendDetection.beginMarker] + body + [HostBackendDetection.endMarker] + after
    }

    @Test func herdrOnPathAndTmuxAfterLoginChatter() {
        let presence = HostBackendDetection.presence(fromOutput: output(detected(
            ["herdr=path", "tmux=tmux 3.7c"],
            before: ["Welcome to Ubuntu 24.04", "Last login: Tue Sep 30", "tmux=tmux 1.8"])))
        #expect(presence == HostBackendPresence(herdr: true, tmuxVersion: "3.7c"))
        #expect(presence?.backends == [.herdr, .tmux])
    }

    @Test func aSocketAloneCountsAsHerdrAndMissingTmuxIsNil() {
        let presence = HostBackendDetection.presence(fromOutput: output(detected(["herdr=socket"])))
        #expect(presence == HostBackendPresence(herdr: true, tmuxVersion: nil))
        #expect(presence?.backends == [.herdr])
    }

    @Test func tmuxOnlyHost() {
        let presence = HostBackendDetection.presence(fromOutput: output(detected(["tmux=tmux 3.4"])))
        #expect(presence == HostBackendPresence(herdr: false, tmuxVersion: "3.4"))
        #expect(presence?.backends == [.tmux])
    }

    @Test func aTmuxOlderThanTheMinimumLeavesOnlyHerdr() {
        #expect(HostBackendPresence(herdr: true, tmuxVersion: "2.7").backends == [.herdr])
    }

    @Test func neitherBackendLeavesHerdrsProjectionToReportIt() {
        let presence = HostBackendDetection.presence(fromOutput: output(detected([])))
        #expect(presence == HostBackendPresence(herdr: false, tmuxVersion: nil))
        #expect(presence?.backends == [.herdr])
    }

    @Test(arguments: [
        ("tmux next-3.6", "next-3.6"),
        ("tmux openbsd-7.5", "openbsd-7.5"),
        ("tmux master", "master"),
        ("tmux 3.2a", "3.2a"),
        ("3.5", "3.5"),
    ])
    func oddTmuxVersionsKeepTheVersionWord(reported: String, version: String) {
        let presence = HostBackendDetection.presence(
            fromOutput: output(detected(["tmux=\(reported)"])))
        #expect(presence?.tmuxVersion == version)
    }

    @Test func tmuxPrintingNoVersionCountsAsAbsent() {
        let presence = HostBackendDetection.presence(fromOutput: output(detected(["tmux=tmux", "tmux="])))
        #expect(presence?.tmuxVersion == nil)
    }

    @Test func carriageReturnsFromAPTYStyleShellAreIgnored() {
        let presence = HostBackendDetection.presence(
            fromOutput: output(detected(["herdr=path", "tmux=tmux 3.3a"]), lineEnding: "\r\n"))
        #expect(presence == HostBackendPresence(herdr: true, tmuxVersion: "3.3a"))
    }

    @Test func linesOutsideTheMarkersDoNotCount() {
        let presence = HostBackendDetection.presence(fromOutput: output(detected(
            ["tmux=tmux 3.6"],
            before: ["herdr=path"],
            after: ["herdr=socket", "logout"])))
        #expect(presence == HostBackendPresence(herdr: false, tmuxVersion: "3.6"))
    }

    @Test func aTruncatedOrForeignAnswerIsNotReadAsNothingInstalled() {
        #expect(HostBackendDetection.presence(fromOutput: Data()) == nil)
        #expect(
            HostBackendDetection.presence(fromOutput: output(
                [HostBackendDetection.beginMarker, "herdr=path"])) == nil)
        #expect(
            HostBackendDetection.presence(fromOutput: output(
                ["herdr=path", HostBackendDetection.endMarker])) == nil)
    }

    // MARK: Codex (design X1)

    @Test func noCodexIsAbsent() {
        let presence = HostBackendDetection.presence(fromOutput: output(detected([])))
        #expect(presence?.codex == nil)
        #expect(presence?.codexProbed == true)
    }

    private func codex(_ version: String = "0.167.1", daemon: [String]) -> HostBackendPresence? {
        HostBackendDetection.presence(fromOutput: output(detected([
            "codex=codex-cli \(version)", "codexpath=/home/dev/.local/bin/codex",
            "codexsocket=/custom/codex/app-server-control/app-server-control.sock",
            HostBackendDetection.codexDaemonBegin,
        ] + daemon + [HostBackendDetection.codexDaemonEnd])))
    }

    @Test func installedCodexWithNoDaemonIsNotProjected() {
        let presence = codex(daemon: ["", "codexexit=1"])
        #expect(presence?.codex == CodexPresence(
            version: "0.167.1", path: "/home/dev/.local/bin/codex",
            probeSocketPath: "/custom/codex/app-server-control/app-server-control.sock"))
        #expect(presence?.backends.contains(.codex) == false)
    }

    @Test func stoppedCodexKeepsItsExpectedSocketForCheapExternalStartChecks() {
        let presence = codex(daemon: ["codexexit=1"])
        #expect(presence?.codex?.probeSocketPath == "/custom/codex/app-server-control/app-server-control.sock")
    }

    @Test func runningCodexParsesTheSingleJSONAnswer() {
        let presence = codex(daemon: [
            #"{"status":"running","socketPath":"/home/dev/.codex/app-server-control/app-server-control.sock","cliVersion":"0.167.1","appServerVersion":"0.167.1","future":true}"#,
            "codexexit=0",
        ])
        #expect(presence?.codex?.isRunning == true)
        #expect(presence?.codex?.appServerVersion == "0.167.1")
        #expect(presence?.backends == [.codex])
    }

    @Test func oldCodexIsNotProjectedEvenWithADaemon() {
        let presence = codex("0.166.0", daemon: [
            #"{"status":"running","socketPath":"/tmp/codex.sock"}"#, "codexexit=0",
        ])
        #expect(presence?.codex?.isRunning == true)
        #expect(presence?.codex?.meetsFloor == false)
        #expect(presence?.backends.contains(.codex) == false)
    }

    @Test(arguments: [
        ["junk", "codexexit=0"],
        [#"{"status":"running","socketPath":"relative"}"#, "codexexit=0"],
        [#"{"status":"running","socketPath":"/tmp/codex.sock"}"#, "codexexit=1"],
        [#"{"status":"running","socketPath":"/tmp/codex.sock"}"#],
    ])
    func junkOrFailedDaemonOutputIsNotRunning(daemon: [String]) {
        #expect(codex(daemon: daemon)?.codex?.isRunning == false)
    }

    @Test func codexProbeUsesOnlyTheTwoSafeCommandsAndLoginPath() {
        let command = HostBackendDetection.command(
            socket: .defaultSession, probesPlugin: false, loginPATH: "/custom/bin:/usr/bin")
        #expect(command.contains("--version"))
        #expect(command.contains("app-server daemon version"))
        #expect(!command.contains("daemon start"))
        #expect(!command.contains("daemon stop"))
        #expect(command.contains("head -c 16384"))
        #expect(command.contains("/custom/bin:/usr/bin"))
        #expect(command.contains("/.nvm/versions/node/*/bin"))
    }

    // MARK: Programs that do not answer

    /// Every Host program the script runs goes through the watchdog, so one
    /// that never answers (an unapproved Homebrew codex over SSH) costs at
    /// most `probeLimitSeconds` and the other probes still run.
    @Test(arguments: [true, false])
    func everyProgramDetectionRunsIsTimeBoxed(probingPlugin: Bool) throws {
        let script = try detectionScript(probingPlugin: probingPlugin)
        #expect(script.contains(HostWatchdog.definition))
        #expect(script.contains("wo=$(waycar_watch \(HostBackendDetection.probeLimitSeconds) \"$@\""))
        // A program that hung after printing part of an answer leaves none.
        #expect(script.contains("-eq \(HostWatchdog.stoppedStatus) ]; then wo=; "))
        for probe in [
            "waycar_probe tmux tmux -V", #"waycar_probe "$hcc" "$hcp" --version"#,
            #"waycar_probe codex-version "$cp" --version"#,
            "waycar_watch \(HostBackendDetection.probeLimitSeconds) \"$cp\" app-server daemon version",
            #"waycar_probe opencode-version "$op" --version"#,
            #"waycar_probe opencode-service "$op" service status"#,
        ] {
            #expect(script.contains(probe), "\(probe)")
        }
        #expect(script.contains("waycar_probe herdr-plugins herdr plugin list --json") == probingPlugin)
        // No program runs bare in a command substitution.
        for bare in [#"$("$"#, "$(tmux", "$(herdr", #"{ "$cp""#] {
            #expect(!script.contains(bare), "\(bare)")
        }
    }

    @Test func programsThatDidNotAnswerAreNamedAndTheRestStillCount() {
        let presence = HostBackendDetection.presence(fromOutput: output(detected([
            "herdr=path", "tmux=tmux 3.4", "timedout=herdr-core", "timedout=codex-version",
            "timedout=codex-version", "timedout=future-probe",
            "opencode=opencode v2.2.7", "opencodepath=/home/dev/.opencode/bin/opencode",
            "timedout=opencode-service", "opencodestatus=",
        ])))
        #expect(presence?.unansweredProbes == [.herdrCore, .codexVersion, .opencodeService])
        #expect(presence?.codex == nil)
        #expect(presence?.core == nil)
        #expect(presence?.opencode?.isRunning == false)
        #expect(presence?.tmuxVersion == "3.4")
        #expect(presence?.unansweredProbe(of: .codex) == .codexVersion)
        #expect(presence?.unansweredProbe(of: .tmux) == nil)
        #expect(HostBackendDetection.presence(fromOutput: output(detected(["herdr=path"])))?
            .unansweredProbes == nil)
    }

    /// A `service status` that printed a URL and then hung is no running
    /// server.
    @Test func anOpenCodeStatusThatDidNotAnswerIsNotRunning() {
        let presence = HostBackendDetection.presence(fromOutput: output(detected([
            "opencode=opencode v2.2.7", "opencodepath=/home/dev/.opencode/bin/opencode",
            "timedout=opencode-service", "opencodestatus=http://127.0.0.1:49374",
        ])))
        #expect(presence?.opencode?.isRunning == false)
        #expect(presence?.runningServerChats.isEmpty == true)
    }

    /// `daemon version` reports the watchdog's stop on its exit line.
    @Test func aCodexDaemonThatDidNotAnswerIsNamedAndNotRunning() {
        let presence = codex(daemon: ["", "codexexit=\(HostWatchdog.stoppedStatus)"])
        #expect(presence?.codex?.isRunning == false)
        #expect(presence?.unansweredProbes == [.codexDaemon])
        #expect(codex(daemon: ["codexexit=1"])?.unansweredProbes == nil)
    }

    @Test func aTimedOutLineInsideThePluginListIsJSONNotAProbe() {
        let list = [HostBackendDetection.pluginListBegin, "timedout=tmux", HostBackendDetection.pluginListEnd]
        let presence = HostBackendDetection.presence(fromOutput: output(detected(["herdr=path"] + list)))
        #expect(presence?.unansweredProbes == nil)
    }

    /// Real-SSH fixtures search the exec's PATH and the account's own tool
    /// directories only: the runner's Homebrew holds real CLIs.
    @Test func withoutSystemDirectoriesDetectionSearchesOnlyTheAccountsOwn() throws {
        let command = HostBackendDetection.command(
            socket: .defaultSession, probesPlugin: true, searchesSystemDirectories: false)
        for system in ["/opt/homebrew", "/usr/local", "/home/linuxbrew", "/run/current-system"] {
            #expect(!command.contains(system), "\(system)")
        }
        for own in ["$HOME/.local/bin", "$HOME/.nix-profile/bin", "$HOME/.opencode/bin", "$HOME/.npm-global/bin"] {
            #expect(command.contains(own), "\(own)")
        }
        #expect(HostBackendDetection.command(socket: .defaultSession, probesPlugin: true)
            .contains(HerdrHostPath.corePathExport))
    }

    // MARK: OpenCode 2 (O1, O2)

    private func opencode(_ lines: [String]) -> HostBackendPresence? {
        HostBackendDetection.presence(fromOutput: output(detected(lines)))
    }

    private static let opencodeRegistration = [
        "opencodeservice=/home/dev/.local/state/opencode/service.json",
        #"opencodereg="version": "2.2.7""#,
        #"opencodereg="url": "http://127.0.0.1:49374""#,
        #"opencodereg="pid": 4242"#,
    ]

    @Test func openCodeOneIsNoOpenCodeBackend() {
        let presence = opencode(["opencode=1.19.5", "opencodepath=/home/dev/.opencode/bin/opencode"])
        #expect(presence?.opencode == nil)
        #expect(presence?.opencodeProbed == true)
        #expect(presence?.backends.contains(.opencode) == false)
        #expect(opencode([])?.opencode == nil)
    }

    @Test func runningOpenCodeReadsStatusAndRegistrationButNoPassword() throws {
        let presence = opencode([
            "opencode=opencode v2.2.7", "opencodepath=/home/dev/.opencode/bin/opencode",
            "opencodestatus=http://127.0.0.1:49374",
        ] + Self.opencodeRegistration)
        let found = try #require(presence?.opencode)
        #expect(found == OpenCodePresence(
            path: "/home/dev/.opencode/bin/opencode", version: "2.2.7", serverURL: "http://127.0.0.1:49374",
            registeredURL: "http://127.0.0.1:49374", registeredPID: 4242, registeredVersion: "2.2.7",
            registrationPath: "/home/dev/.local/state/opencode/service.json"))
        #expect(found.isRunning && found.meetsFloor)
        #expect(found.endpoint == OpenCodeEndpoint(host: "127.0.0.1", port: 49374))
        #expect(presence?.backends == [.opencode])
        let encoded = String(decoding: try JSONEncoder().encode(try #require(presence)), as: UTF8.self)
        #expect(!encoded.lowercased().contains("password"))
        #expect(try JSONDecoder().decode(HostBackendPresence.self, from: Data(encoded.utf8)) == presence)
    }

    @Test func stoppedOpenCodeKeepsItsRegisteredAddressForTheCheapProbe() throws {
        let presence = opencode([
            "opencode=opencode v2.2.7", "opencodepath=/opt/homebrew/bin/opencode", "opencodestatus=stopped",
        ] + Self.opencodeRegistration)
        let found = try #require(presence?.opencode)
        #expect(!found.isRunning && found.meetsFloor)
        #expect(found.endpoint == OpenCodeEndpoint(host: "127.0.0.1", port: 49374))
        #expect(presence?.backends.contains(.opencode) == false)
        #expect(presence?.runningServerChats.isEmpty == true)
    }

    @Test func openCodeBelowTheFloorIsInstalledButNeedsAnUpdate() throws {
        let presence = opencode(["opencode=opencode v2.1.9", "opencodepath=/home/dev/.opencode/bin/opencode"])
        let found = try #require(presence?.opencode)
        #expect(found.version == "2.1.9" && !found.meetsFloor && !found.isRunning)
        #expect(found.registrationPath == OpenCodePresence.defaultRegistrationPath)
        #expect(presence?.backends.contains(.opencode) == false)
        // A floor-passing server that answers is projected; junk never runs.
        #expect(opencode(["opencode=opencode v2.3.0", "opencodepath=/bin/opencode",
                          "opencodestatus=http://0.0.0.0:5000"])?.backends == [.opencode])
        #expect(opencode(["opencode=opencode v2.3.0", "opencodepath=/bin/opencode",
                          "opencodestatus=Error: no server"])?.opencode?.isRunning == false)
        #expect(opencode(["opencode=opencode v2.3.0", "opencodepath=relative/opencode"])?.opencode == nil)
    }

    @Test func openCodeProbeRunsOnlySideEffectFreeCommands() {
        let command = HostBackendDetection.command(
            socket: .defaultSession, probesPlugin: false, loginPATH: "/custom/bin:/usr/bin")
        #expect(command.contains("$HOME/.opencode/bin"))
        #expect(command.contains("service status"))
        #expect(command.contains("${XDG_STATE_HOME:-$HOME/.local/state}/opencode/service.json"))
        #expect(command.contains("grep -o -E"))
        #expect(!command.contains("opencode api"))
        #expect(!command.contains("service start"))
        #expect(!command.lowercased().contains("password"))
    }

    @Test func aCachedOpenCodePresenceRoundTripsWithoutAPassword() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "opencode-presence-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ConsoleInventoryCache(directory: directory)
        let host = Host.fixture()
        let opencode = OpenCodePresence(
            path: "/home/dev/.opencode/bin/opencode", version: "2.2.7", serverURL: "http://127.0.0.1:49374",
            registeredURL: "http://127.0.0.1:49374", registeredPID: 4242, registeredVersion: "2.2.7")
        let presence = HostBackendPresence(herdr: true, tmuxVersion: nil, ultimate: [], opencode: opencode)
        cache.savePresence(.init(presence: presence, verifiedAt: Date()), for: host)
        cache.flush()
        let file = try String(contentsOf: cache.presenceFileURL(for: host.id), encoding: .utf8)
        #expect(file.contains("49374") && !file.lowercased().contains("password"))
        #expect(cache.loadPresence(for: host)?.presence == presence)
        #expect(cache.connectionMemory(for: host).opencodePresence == opencode)
        #expect(cache.connectionMemory(for: host).codexPresence == nil)
    }

    // MARK: Waycar plugin (#209)

    private static let pluginRoot = "/home/dev/.config/herdr/plugins/waycar/src-root"
    private static let toolsRoot = "/home/dev/.local/share/waycar/plugin"

    /// `herdr plugin list --json` as herdr prints it: several lines.
    private func pluginList(_ entries: [String]) -> [String] {
        [HostBackendDetection.pluginListBegin, "{", "  \"result\": {", "    \"plugins\": ["]
            + entries.enumerated().map { index, entry in
                "      " + entry + (index == entries.count - 1 ? "" : ",")
            }
            + ["    ]", "  }", "}", HostBackendDetection.pluginListEnd]
    }

    private func entry(_ id: String, version: String, enabled: Bool = true) -> String {
        #"{"plugin_id": "\#(id)", "version": "\#(version)", "enabled": \#(enabled), "#
            + #""plugin_root": "\#(Self.pluginRoot)", "manifest_path": "\#(Self.pluginRoot)/herdr-plugin.toml"}"#
    }

    private func hostTools(_ version: String) -> String {
        HostBackendDetection.hostToolsVersionPrefix + #"version = "\#(version)""#
    }

    private func plugin(_ body: [String], lineEnding: String = "\n") -> WaycarPluginDetection? {
        HostBackendDetection.presence(fromOutput: output(detected(body), lineEnding: lineEnding))?
            .waycarPlugin
    }

    @Test func anEnabledWaycarEntryInHerdrsListIsHerdrModeAtItsVersionAndRoot() {
        let detected = plugin(
            ["herdr=path"] + pluginList([entry("other", version: "9.9.9"), entry("waycar", version: "1.3.1")])
                + [hostTools("1.4.0"), HostBackendDetection.hostToolsRootPrefix + Self.toolsRoot])
        #expect(
            detected == .installed(WaycarPluginInstall(version: "1.3.1", mode: .herdr, root: Self.pluginRoot)))
    }

    /// A Host still on the legacy plugin id counts as installed at that
    /// plugin's version, so it reads as outdated, with no root: install.sh
    /// replaces only a `waycar` entry. `waycar` wins over it.
    @Test func aLegacyPluginIDReadsAsOutdatedWithoutARootAndWaycarWinsOverIt() throws {
        let legacy = try #require(SSHTransportSettings.legacyNotificationPluginIDs.first)
        let detected = plugin(
            ["herdr=path"] + pluginList([entry(legacy, version: "1.2.0")])
                + [HostBackendDetection.hostToolsNoneLine])
        #expect(detected == .installed(WaycarPluginInstall(version: "1.2.0", mode: .herdr, root: nil)))
        #expect(
            WaycarPluginRequirement.status(of: detected)
                == .outdated(installed: "1.2.0", required: WaycarPluginRequirement.minimumVersion))

        let both = plugin(
            ["herdr=path"] + pluginList([entry(legacy, version: "1.2.0"), entry("waycar", version: "1.4.0")])
                + [HostBackendDetection.hostToolsNoneLine])
        #expect(
            both == .installed(WaycarPluginInstall(version: "1.4.0", mode: .herdr, root: Self.pluginRoot)))
    }

    @Test func theHostToolsRootIsReadAndAnEmptyOneIsUnknown() {
        let rooted = plugin(
            ["tmux=tmux 3.4", hostTools("1.4.0"), HostBackendDetection.hostToolsRootPrefix + Self.toolsRoot])
        #expect(
            rooted == .installed(WaycarPluginInstall(version: "1.4.0", mode: .tmux, root: Self.toolsRoot)))
        let unrooted = plugin(["tmux=tmux 3.4", hostTools("1.4.0"), HostBackendDetection.hostToolsRootPrefix])
        #expect(unrooted == .installed(WaycarPluginInstall(version: "1.4.0", mode: .tmux)))
    }

    @Test func aDisabledWaycarEntryFallsThroughToTheHostTools() {
        let detected = plugin(
            ["herdr=path"] + pluginList([entry("waycar", version: "1.3.1", enabled: false)])
                + [hostTools("1.4.0")])
        #expect(detected == .installed(WaycarPluginInstall(version: "1.4.0", mode: .tmux)))
    }

    @Test func hostToolsWithoutHerdrAreTmuxMode() {
        let detected = plugin(["tmux=tmux 3.4", hostTools("1.4.0")])
        #expect(detected == .installed(WaycarPluginInstall(version: "1.4.0", mode: .tmux)))
    }

    @Test func hostToolsBesideAHerdrListWithoutWaycarAreTmuxMode() {
        let detected = plugin(
            ["herdr=path"] + pluginList([entry("other", version: "2.0.0")]) + [hostTools("1.3.1")])
        #expect(detected == .installed(WaycarPluginInstall(version: "1.3.1", mode: .tmux)))
    }

    /// install.sh picks herdr whenever `herdr` is on the PATH, so Host Tools
    /// beside a list that cannot be read update in herdr mode.
    @Test func hostToolsBesideAnUnreadableHerdrListAreHerdrMode() {
        let unreadable = [HostBackendDetection.pluginListBegin, "", HostBackendDetection.pluginListEnd]
        let detected = plugin(["herdr=path"] + unreadable + [hostTools("1.3.1")])
        #expect(detected == .installed(WaycarPluginInstall(version: "1.3.1", mode: .herdr)))
    }

    @Test func neitherHerdrsPluginNorTheHostToolsIsNotInstalled() {
        #expect(plugin([HostBackendDetection.hostToolsNoneLine]) == .notInstalled)
        #expect(
            plugin(["herdr=path"] + pluginList([]) + [HostBackendDetection.hostToolsNoneLine])
                == .notInstalled)
    }

    @Test func hostToolsWithoutAReadableVersionAreInstalledAtAnUnknownVersion() {
        let detected = plugin([HostBackendDetection.hostToolsVersionPrefix])
        #expect(detected == .installed(WaycarPluginInstall(version: nil, mode: .tmux)))
        #expect(WaycarPluginRequirement.status(of: detected) == .unknown)
    }

    @Test(arguments: [
        (#"version = "1.4.0""#, "1.4.0"),
        (#"version="1.4.0-beta.1"  # comment"#, "1.4.0-beta.1"),
        (#"version = """#, nil),
        ("version = 1.4.0", nil),
        ("", nil),
    ] as [(String, String?)])
    func tomlVersionLinesYieldTheQuotedValue(line: String, version: String?) {
        #expect(HostBackendDetection.tomlVersion(fromLine: Substring(line)) == version)
    }

    @Test func carriageReturnsAroundTheMultiLinePluginListAreIgnored() {
        let detected = plugin(
            ["herdr=path"] + pluginList([entry("waycar", version: "1.4.0")])
                + [HostBackendDetection.hostToolsNoneLine],
            lineEnding: "\r\n")
        #expect(
            detected == .installed(WaycarPluginInstall(version: "1.4.0", mode: .herdr, root: Self.pluginRoot)))
    }

    @Test func linesInsideThePluginListAreNeverBackendLines() {
        let list = [HostBackendDetection.pluginListBegin, "tmux=tmux 9.9", HostBackendDetection.pluginListEnd]
        let presence = HostBackendDetection.presence(fromOutput: output(detected(
            ["herdr=path", "tmux=tmux 3.4"] + list + [HostBackendDetection.hostToolsNoneLine])))
        #expect(presence?.tmuxVersion == "3.4")
        #expect(presence?.waycarPlugin == .notInstalled)
    }

    /// A list that never ends swallowed the Host Tools line: the plugin is
    /// unknown, never "not installed", and the backends still count.
    @Test func anUnterminatedPluginListLeavesThePluginUnprobed() {
        let presence = HostBackendDetection.presence(fromOutput: output(detected(
            ["herdr=path", "tmux=tmux 3.4", HostBackendDetection.pluginListBegin, "{",
             hostTools("1.4.0")])))
        #expect(presence?.herdr == true)
        #expect(presence?.tmuxVersion == "3.4")
        #expect(presence?.waycarPlugin == nil)
    }

    @Test func anAnswerWithoutAPluginPartLeavesThePluginUnprobed() {
        #expect(plugin(["herdr=path", "tmux=tmux 3.4"]) == nil)
    }

    @Test func aTruncatedAnswerWithAPluginPartIsStillNoPresence() {
        let truncated = [HostBackendDetection.beginMarker, "herdr=path"]
            + pluginList([entry("waycar", version: "1.4.0")])
        #expect(HostBackendDetection.presence(fromOutput: output(truncated)) == nil)
    }

    private func detectionScript(probingPlugin: Bool) throws -> Substring {
        let command = HostBackendDetection.command(
            socket: .absolutePath("/run/herdr.sock"), probesPlugin: probingPlugin)
        let start = try #require(command.range(of: "/bin/sh -c '"))
        let end = try #require(command.range(of: "' waycar-detect "))
        return command[start.upperBound..<end.lowerBound]
    }

    /// The script is embedded in single quotes and may pass through fish:
    /// it must hold no single quote and no `\\`.
    @Test(arguments: [true, false])
    func theDetectionScriptStaysSingleQuoteSafe(probingPlugin: Bool) throws {
        let script = try detectionScript(probingPlugin: probingPlugin)
        #expect(!script.contains("'"))
        #expect(!script.contains("\\\\"))
    }

    /// tmux's connect detects without the plugin probe: no herdr plugin
    /// list and no Host Tools lookup on its path to the first rows.
    @Test func theConnectDetectionAsksNothingAboutThePlugin() throws {
        let script = try detectionScript(probingPlugin: false)
        #expect(!script.contains("plugin list"))
        #expect(!script.contains(HostBackendDetection.pluginListBegin))
        #expect(!script.contains(HostBackendDetection.hostToolsNoneLine))
        #expect(!script.contains("root_of"))
    }

    /// A presence cached by a build before the plugin probe decodes with the
    /// plugin unprobed, and one with it round-trips.
    @Test func aPresenceCachedBeforeThePluginProbeDecodesAsUnprobed() throws {
        let old = try JSONDecoder().decode(
            HostBackendPresence.self, from: Data(#"{"herdr":true,"tmuxVersion":"3.4"}"#.utf8))
        #expect(old == HostBackendPresence(
            herdr: true, tmuxVersion: "3.4", codexProbed: nil, opencodeProbed: nil))
        #expect(old.waycarPlugin == nil)

        let current = HostBackendPresence(
            herdr: false, tmuxVersion: "3.4",
            waycarPlugin: .installed(WaycarPluginInstall(version: "1.4.0", mode: .tmux, root: Self.toolsRoot)))
        let decoded = try JSONDecoder().decode(
            HostBackendPresence.self, from: JSONEncoder().encode(current))
        #expect(decoded == current)

        // A plugin cached before roots were probed decodes without one.
        let rootless = try JSONDecoder().decode(
            WaycarPluginInstall.self, from: Data(#"{"version":"1.3.1","mode":"herdr"}"#.utf8))
        #expect(rootless == WaycarPluginInstall(version: "1.3.1", mode: .herdr))
    }

    // MARK: herdr-core (ADR 0031, design §4)

    private static let corePath = "/home/dev/.local/bin/herdr-core"

    @Test func aCoreWithItsPathAfterLoginChatterIsFound() {
        let presence = HostBackendDetection.presence(fromOutput: output(detected(
            ["tmux=tmux 3.4", "core=0.1.14", "corepath=\(Self.corePath)"],
            before: ["Last login: Tue Sep 30", "core=9.9.9", "corepath=/tmp/liar"])))
        #expect(presence?.core == CorePresence(version: "0.1.14", path: Self.corePath))
        #expect(presence?.herdr == false)
        #expect(presence?.tmuxVersion == "3.4")
    }

    @Test func aCoreBesideTheTUIIsFoundToo() {
        let presence = HostBackendDetection.presence(fromOutput: output(detected(
            ["herdr=path", "core=0.1.14", "corepath=\(Self.corePath)"])))
        #expect(presence?.herdr == true)
        #expect(presence?.bothRuntimesFound == true)
    }

    @Test func noCoreLinesLeaveCoreNil() {
        let presence = HostBackendDetection.presence(fromOutput: output(detected(["herdr=path"])))
        #expect(presence?.core == nil)
        #expect(presence == HostBackendPresence(herdr: true, tmuxVersion: nil))
    }

    @Test func carriageReturnsAroundTheCoreLinesAreIgnored() {
        let presence = HostBackendDetection.presence(
            fromOutput: output(
                detected(["core=0.1.14", "corepath=\(Self.corePath)"], before: ["motd"]),
                lineEnding: "\r\n"))
        #expect(presence?.core == CorePresence(version: "0.1.14", path: Self.corePath))
    }

    /// A foreign `hc` (herbstclient prints `hc: herbstclient 0.9`) never gets
    /// the script to print core lines; and should one slip through, a version
    /// that does not start with a digit is no core.
    @Test(arguments: [
        ["core=herbstclient 0.9.5", "corepath=/usr/bin/hc"],
        ["core=", "corepath=\(corePath)"],
        ["core=0.1.14"],
        ["corepath=\(corePath)"],
        ["core=0.1.14", "corepath=bin/herdr-core"],
        ["core=0.1.14", "corepath="],
    ])
    func aCoreNeedsADigitVersionAndAnAbsolutePath(_ body: [String]) {
        let presence = HostBackendDetection.presence(fromOutput: output(detected(body)))
        #expect(presence != nil)
        #expect(presence?.core == nil)
    }

    @Test func aTruncatedAnswerWithCoreLinesIsStillNoPresence() {
        let cut = output([
            HostBackendDetection.beginMarker, "core=0.1.14", "corepath=\(Self.corePath)",
        ])
        #expect(HostBackendDetection.presence(fromOutput: cut) == nil)
    }

    @Test func coreLinesInsideThePluginListAreNeverCoreLines() {
        let presence = HostBackendDetection.presence(fromOutput: output(detected([
            HostBackendDetection.pluginListBegin, "core=0.1.14", "corepath=\(Self.corePath)",
            HostBackendDetection.pluginListEnd,
        ])))
        #expect(presence?.core == nil)
    }

    /// `--version` is the only call: `hc ls`, `hc server status` and
    /// `hc connect` each start a core on the Host (C2).
    @Test(arguments: [true, false])
    func theCoreProbeOnlyAsksForTheVersion(probingPlugin: Bool) throws {
        let script = try detectionScript(probingPlugin: probingPlugin)
        #expect(script.contains("herdr-core hc"))
        #expect(script.contains("--version"))
        #expect(script.contains("\"hc \"[0-9]*"))
        for starts in ["server", " ls", "connect", " attach", " update"] {
            #expect(!script.contains("\"$hcp\"\(starts)"), "\(starts)")
        }
        #expect(!script.contains("hc server"))
        #expect(!script.contains("hc connect"))
    }

    /// The Herdr app's directories beyond the ones herdr already searched,
    /// so `command -v herdr-core` finds a Nix or NixOS install.
    @Test func theDetectionPathSearchesTheHerdrAppsCoreDirectories() throws {
        let script = try detectionScript(probingPlugin: false)
        for directory in [
            "$HOME/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "$HOME/.cargo/bin",
            "$HOME/.nix-profile/bin", "/run/current-system/sw/bin",
        ] {
            #expect(script.contains(directory), "\(directory)")
        }
        #expect(script.contains("/mise}/shims"))
    }

    /// The Nix directories belong to herdr-core's lines only: the shared
    /// herdr PATH is pinned against the plugin (the update command's fixture).
    @Test func theNixDirectoriesJoinOnlyHerdrCoresPath() {
        #expect(!HerdrHostPath.extraPATH.contains("nix"))
        #expect(!HerdrHostPath.pathExport.contains("nix"))
        #expect(HerdrHostPath.corePathExport.contains(HerdrHostPath.extraPATH))
        #expect(HerdrHostPath.corePathExport.contains(HerdrHostPath.coreExtraPATH))
        #expect(!HerdrHostPath.wrappingBareHerdr("herdr plugin list").contains("nix"))
        #expect(HerdrHostPath.wrappingBareHerdr("herdr-core connect").contains("nix-profile"))
    }

    @Test func theHerdrCoreCommandIsRecognisedAsABareCommand() {
        #expect(HerdrHostPath.isBareCoreCommand("herdr-core connect"))
        #expect(HerdrHostPath.isBareCoreCommand("HC_NAME=x herdr-core attach t1"))
        #expect(!HerdrHostPath.isBareCoreCommand("/home/dev/.local/bin/herdr-core connect"))
        #expect(!HerdrHostPath.isBareCoreCommand("hc connect"))
        #expect(!HerdrHostPath.isBareCoreCommand("herdr agent attach"))
        #expect(!HerdrHostPath.isBareHerdrCommand("herdr-core connect"))
        // The PATH fix reaches it, so a bare herdr-core resolves under sshd's thin PATH.
        #expect(HerdrHostPath.wrappingBareHerdr("herdr-core connect").contains("exec herdr-core connect"))
        #expect(HerdrHostPath.wrappingBareHerdr("hc connect") == "hc connect")
        #expect(HerdrHostPath.missingBinaryError(exitStatus: 127, command: "herdr-core connect") == nil)
        #expect(
            HerdrHostPath.missingBinaryError(exitStatus: 127, command: "herdr x")
                == .herdrBinaryNotFound)
    }
}
