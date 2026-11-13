import Foundation
import Testing

@testable import Waycar

@Suite("Backend install")
struct BackendInstallTests {
    private func preflight(
        os: String = "Linux", arch: String = "x86_64", android: Bool = false, curl: Bool = true,
        managers: [HostPackageManager] = [.aptGet], root: Bool = false, sudo: Bool = true
    ) -> HostInstallPreflight {
        HostInstallPreflight(
            operatingSystem: os, architecture: arch, isAndroid: android, hasCurl: curl,
            packageManagers: managers, isRoot: root, sudoWithoutPassword: sudo)
    }

    private func run(
        _ status: Int32?, _ reason: BackendInstallRun.Reason?, _ output: [String] = []
    ) -> BackendInstallRun {
        BackendInstallRun(exitStatus: status, reason: reason, output: output)
    }

    // MARK: Preflight

    @Test func preflightReadsTheFactsBetweenTheMarkers() throws {
        let output = """
            Last login: Mon from 10.0.0.2
            \(HostInstallPreflight.beginMarker)
            os=Linux
            arch=aarch64
            android=0
            curl=1
            pm=apt-get
            pm=brew
            root=0
            sudo=1
            \(HostInstallPreflight.endMarker)
            """
        let facts = try #require(HostInstallPreflight(fromOutput: Data(output.utf8)))
        #expect(facts == preflight(arch: "aarch64", managers: [.aptGet, .brew]))
    }

    @Test func preflightOrdersManagersByPriorityWhateverTheOutputOrder() throws {
        let output = "\(HostInstallPreflight.beginMarker)\npm=brew\npm=dnf\npm=apt-get\npm=nix\n"
            + "\(HostInstallPreflight.endMarker)\n"
        let facts = try #require(HostInstallPreflight(fromOutput: Data(output.utf8)))
        #expect(facts.packageManagers == [.aptGet, .dnf, .brew])
    }

    @Test func preflightWithoutItsEndMarkerIsNotAnAnswer() {
        let truncated = "\(HostInstallPreflight.beginMarker)\nos=Linux\ncurl=1\n"
        #expect(HostInstallPreflight(fromOutput: Data(truncated.utf8)) == nil)
        #expect(HostInstallPreflight(fromOutput: Data("bash: sh: not found\n".utf8)) == nil)
    }

    @Test(arguments: [
        ("Linux", "x86_64", false, true),
        ("Linux", "aarch64", false, true),
        ("Darwin", "arm64", false, true),
        ("Linux", "aarch64", true, false),
        ("Linux", "riscv64", false, false),
        ("FreeBSD", "amd64", false, false),
        ("", "", false, false),
    ])
    func herdrSupportMatchesItsInstaller(os: String, arch: String, android: Bool, supported: Bool) {
        #expect(preflight(os: os, arch: arch, android: android).herdrSupported == supported)
    }

    @Test func aHostWithoutAdminRightsPrefersHomebrewOverAManagerThatNeedsThem() {
        #expect(preflight(managers: [.aptGet, .brew], sudo: false).usablePackageManager == .brew)
        #expect(preflight(managers: [.aptGet, .brew], sudo: true).usablePackageManager == .aptGet)
        #expect(preflight(managers: [.dnf, .brew], root: true, sudo: false).usablePackageManager == .dnf)
        // No admin rights and no Homebrew: the run stops at needsAdmin.
        #expect(preflight(managers: [.aptGet], sudo: false).usablePackageManager == .aptGet)
        #expect(preflight(managers: []).usablePackageManager == nil)
    }

    // MARK: Plans

    @Test(arguments: [
        (HostPackageManager.aptGet, "sudo -n apt-get install -y tmux", "sudo apt-get install -y tmux"),
        (.dnf, "sudo -n dnf install -y tmux", "sudo dnf install -y tmux"),
        (.yum, "sudo -n yum install -y tmux", "sudo yum install -y tmux"),
        (.zypper, "sudo -n zypper --non-interactive install tmux", "sudo zypper --non-interactive install tmux"),
        (.pacman, "sudo -n pacman -S --noconfirm tmux", "sudo pacman -S --noconfirm tmux"),
        (.apk, "sudo -n apk add tmux", "sudo apk add tmux"),
        (.brew, "brew install tmux", "brew install tmux"),
    ])
    func tmuxCommandsRunThroughSudoNOnlyAndCopyWithoutIt(
        manager: HostPackageManager, command: String, copy: String
    ) {
        let plan = BackendInstallPlan(target: .tmux(manager))
        #expect(plan.command == command)
        #expect(plan.copyCommand == copy)
        #expect(plan.usesSudo == (manager != .brew))
    }

    @Test func rootRunsThePackageManagerWithoutSudo() {
        let plan = BackendInstallPlan(target: .tmux(.aptGet), runsAsRoot: true)
        #expect(plan.command == "apt-get install -y tmux")
        #expect(plan.copyCommand == "apt-get install -y tmux")
        #expect(!plan.usesSudo)
    }

    @Test func herdrDownloadsToATempFileSoAFailedCurlIsSeen() {
        let plan = BackendInstallPlan(target: .herdr)
        #expect(plan.command.contains("curl --proto =https --tlsv1.2 -fsSL https://herdr.dev/install.sh -o \"$t\""))
        #expect(plan.command.contains("&& sh \"$t\""))
        #expect(!plan.command.contains("| sh"))
        #expect(plan.copyCommand == "curl -fsSL https://herdr.dev/install.sh | sh")
        #expect(!plan.usesSudo)
    }

    @Test func noCommandCarriesASingleQuoteOrAPasswordPath() {
        let plans = [BackendInstallPlan(target: .herdr)]
            + HostPackageManager.allCases.map { BackendInstallPlan(target: .tmux($0)) }
        for plan in plans {
            #expect(!plan.command.contains("'"))
            #expect(!plan.command.contains("sudo ") || plan.command.hasPrefix("sudo -n "))
            #expect(!plan.command.contains("sudo -S") && !plan.command.contains("askpass"))
        }
    }

    @Test func plansFollowThePreflight() {
        #expect(BackendInstallPlan.make(installing: .herdr, preflight: preflight()) == .success(.init(target: .herdr)))
        #expect(
            BackendInstallPlan.make(installing: .tmux, preflight: preflight(managers: [.dnf], root: true))
                == .success(.init(target: .tmux(.dnf), runsAsRoot: true)))
    }

    @Test(arguments: [
        (HostBackend.herdr, "Linux", "aarch64", true, true, BackendInstallFailure.unsupportedSystem),
        (.herdr, "FreeBSD", "amd64", false, true, .unsupportedSystem),
        (.herdr, "Linux", "x86_64", false, false, .noCurl),
        (.tmux, "Linux", "aarch64", true, true, .unsupportedSystem),
    ])
    func aHostThatCannotRunTheInstallGetsItsReasonWithoutARun(
        backend: HostBackend, os: String, arch: String, android: Bool, curl: Bool,
        failure: BackendInstallFailure
    ) {
        let facts = preflight(os: os, arch: arch, android: android, curl: curl)
        #expect(BackendInstallPlan.make(installing: backend, preflight: facts) == .failure(failure))
    }

    @Test func tmuxWithoutAPackageManagerWaycarCanRunIsNoPackageManager() {
        #expect(
            BackendInstallPlan.make(installing: .tmux, preflight: preflight(managers: []))
                == .failure(.noPackageManager))
    }

    // MARK: The exec

    @Test func theExecRunsThePlansCommandVerbatim() {
        let plans = [BackendInstallPlan(target: .herdr)]
            + HostPackageManager.allCases.map { BackendInstallPlan(target: .tmux($0)) }
            + [BackendInstallPlan(target: .tmux(.aptGet), runsAsRoot: true)]
        for plan in plans {
            let exec = BackendInstall.execCommand(for: plan)
            #expect(exec.contains(plan.command))
            #expect(exec.hasPrefix("LC_ALL=C /bin/sh -c '"))
            #expect(exec.hasSuffix("' waycar-install </dev/null 2>&1"))
            // One quoted body: the only single quotes are its two ends.
            #expect(exec.filter { $0 == "'" }.count == 2)
        }
    }

    @Test func theExecChecksWhatTheCommandNeedsBeforeRunningIt() throws {
        func position(_ needle: String, in text: String) throws -> String.Index {
            try #require(text.range(of: needle)).lowerBound
        }
        let herdr = BackendInstall.execCommand(for: BackendInstallPlan(target: .herdr))
        #expect(try position("command -v curl", in: herdr) < position("curl --proto", in: herdr))

        let apt = BackendInstallPlan(target: .tmux(.aptGet))
        let tmux = BackendInstall.execCommand(for: apt)
        let manager = try position("command -v apt-get", in: tmux)
        let sudo = try position("sudo -n true", in: tmux)
        let install = try position(apt.command, in: tmux)
        #expect(manager < sudo && sudo < install)

        // Nothing to ask sudo for when the account is root or the manager is Homebrew.
        let root = BackendInstall.execCommand(for: BackendInstallPlan(target: .tmux(.aptGet), runsAsRoot: true))
        let brew = BackendInstall.execCommand(for: BackendInstallPlan(target: .tmux(.brew)))
        #expect(!root.contains("sudo"))
        #expect(!brew.contains("sudo"))
    }

    // MARK: Reading a run

    @Test func readsTheMarkerAndLeavesItOutOfTheOutput() {
        let lines = ["downloading", "\(BackendInstall.exitMarker)=0 reason=ok"]
        #expect(BackendInstall.run(fromOutput: lines) == run(0, .ok, ["downloading"]))
        #expect(BackendInstall.run(fromOutput: lines).succeeded)
    }

    @Test func aRunWithoutItsMarkerHasNoStatus() {
        let result = BackendInstall.run(fromOutput: ["Reading package lists..."])
        #expect(result == run(nil, nil, ["Reading package lists..."]))
        #expect(!result.succeeded)
    }

    @Test func aZeroStatusWithAnotherReasonIsNotASuccess() {
        #expect(!run(0, .failed).succeeded)
        #expect(!run(1, .ok).succeeded)
        #expect(!run(0, nil).succeeded)
    }

    @Test func installerColourCodesNeverReachTheOutput() throws {
        let output = Data("  \u{1B}[32m>\u{1B}[0m installed herdr\n  \u{1B}[31m✗\u{1B}[0m oops\n\n".utf8)
        #expect(BackendInstall.lines(fromOutput: output) == ["  > installed herdr", "  ✗ oops"])
        #expect(BackendInstall.stripTerminalEscapes("a\u{1B}[1;32mb\u{1B}[0mc\u{1B}") == "abc")
        #expect(BackendInstall.stripTerminalEscapes("plain") == "plain")
    }

    // MARK: The failure list

    @Test(arguments: [
        (BackendInstallRun.Reason.noCurl, BackendInstallFailure.noCurl),
        (.download, .cannotReachInstaller),
        (.admin, .needsAdmin),
        (.noPackageManager, .noPackageManager),
    ])
    func theWrappersReasonDecidesTheFailure(reason: BackendInstallRun.Reason, failure: BackendInstallFailure) {
        // Whatever the text says: the status-based reason wins.
        let output = ["can't reach https://herdr.dev/latest.json"]
        #expect(BackendInstall.failure(for: .herdr, run: run(1, reason, output)) == failure)
        #expect(BackendInstall.failure(for: .tmux(.aptGet), run: run(1, reason, output)) == failure)
    }

    @Test(arguments: [
        ("requires 'curl' — install it first, or download a binary manually", BackendInstallFailure.noCurl),
        ("can't reach https://herdr.dev/latest.json. Please try again later", .cannotReachInstaller),
        ("download failed from https://example/herdr", .cannotReachInstaller),
        ("unsupported OS: FreeBSD", .unsupportedSystem),
        ("unsupported architecture: riscv64", .unsupportedSystem),
        ("Android/Termux is not currently supported by Herdr release binaries.", .unsupportedSystem),
        ("release manifest does not include a binary for linux-aarch64", .unsupportedSystem),
    ])
    func herdrsOwnRefusalsAreRead(line: String, failure: BackendInstallFailure) {
        let output = ["  > detected linux/x86_64", "  ✗ " + line]
        #expect(BackendInstall.failure(for: .herdr, run: run(1, .failed, output)) == failure)
        #expect(BackendInstall.failure(for: .herdr, run: run(nil, nil, output)) == failure)
    }

    @Test(arguments: [
        "sudo: a password is required",
        "sudo: no tty present and no askpass program specified",
        "sudo: sorry, you must have a tty to run sudo",
        "deploy is not in the sudoers file.",
    ])
    func aSudoRefusalMidRunIsNeedsAdmin(line: String) {
        let output = ["Reading package lists...", line]
        #expect(BackendInstall.failure(for: .tmux(.aptGet), run: run(1, .failed, output)) == .needsAdmin)
    }

    @Test func tmuxsRefusalLinesDoNotReadAsHerdrFailures() {
        let output = ["E: Unable to locate package tmux"]
        #expect(
            BackendInstall.failure(for: .tmux(.aptGet), run: run(100, .failed, output))
                == .other(lastLine: "E: Unable to locate package tmux"))
        // A password line from a herdr run is not herdr's to name.
        #expect(
            BackendInstall.failure(for: .herdr, run: run(1, .failed, ["sudo: a password is required"]))
                == .other(lastLine: "sudo: a password is required"))
    }

    @Test func anythingElseIsOtherWithTheLastNonEmptyLine() {
        #expect(
            BackendInstall.failure(for: .herdr, run: run(1, .failed, ["step one", "  boom  ", "  "]))
                == .other(lastLine: "boom"))
        #expect(BackendInstall.failure(for: .herdr, run: run(nil, nil)) == .other(lastLine: nil))
    }

    // MARK: Re-check

    private func presence(herdr: Bool = false, tmux: String? = nil) -> HostBackendPresence {
        HostBackendPresence(herdr: herdr, tmuxVersion: tmux)
    }

    @Test func herdrIsFoundOnlyWhenTheRecheckFindsIt() {
        let ok = run(0, .ok, ["installed herdr to /home/dev/.local/bin/herdr"])
        #expect(
            BackendInstall.result(afterInstalling: .herdr, run: ok, presence: presence(herdr: true))
                == .found(presence(herdr: true)))
        #expect(
            BackendInstall.result(afterInstalling: .herdr, run: ok, presence: presence())
                == .failed(.other(lastLine: "installed herdr to /home/dev/.local/bin/herdr")))
    }

    @Test(arguments: [
        ("3.2", true), ("3.2a", true), ("3.4", true), ("3.7c", true), ("next-3.6", true),
        ("master", true), ("3.0", false), ("2.7", false), ("3.1c", false),
    ])
    func tmuxIsFoundOnlyAtTheFloorOrAbove(version: String, usable: Bool) {
        let result = BackendInstall.result(
            afterInstalling: .tmux(.dnf), run: run(0, .ok), presence: presence(tmux: version))
        #expect(result == (usable ? .found(presence(tmux: version)) : .failed(.tmuxTooOld(found: version))))
    }

    @Test func tmuxMissingAfterACleanInstallIsAFailure() {
        let result = BackendInstall.result(
            afterInstalling: .tmux(.aptGet), run: run(0, .ok, ["Setting up tmux"]), presence: presence())
        #expect(result == .failed(.other(lastLine: "Setting up tmux")))
    }

    // MARK: herdr-core (WAY-483)

    private static let coreFound = CorePresence(
        version: "0.1.14", path: "/home/dev/.local/bin/herdr-core")

    @Test func coreDownloadsItsInstallerToATempFileAndNeedsNoAdminRights() {
        let plan = BackendInstallPlan(target: .core)
        let url = "https://releases.herdr.dev/core/install.sh"
        #expect(plan.command.contains("curl --proto =https --tlsv1.2 -fsSL \(url) -o \"$t\""))
        #expect(plan.command.contains("&& sh \"$t\""))
        #expect(!plan.command.contains("| sh"))
        #expect(!plan.command.contains("'"))
        #expect(plan.copyCommand == "curl -fsSL \(url) | sh")
        #expect(!plan.usesSudo)
        #expect(plan.target.backend == .core)
    }

    static let coreSystems: [(String, String, Bool, Bool, BackendInstallFailure?)] = [
        ("Linux", "x86_64", false, true, nil),
        ("Darwin", "arm64", false, true, nil),
        ("Linux", "aarch64", true, true, .unsupportedSystem),
        ("FreeBSD", "amd64", false, true, .unsupportedSystem),
        ("Linux", "riscv64", false, true, .unsupportedSystem),
        ("Linux", "x86_64", false, false, .noCurl),
    ]

    @Test(arguments: BackendInstallTests.coreSystems)
    func coreIsOfferedOnWhatItsInstallerSupports(
        os: String, arch: String, android: Bool, curl: Bool, failure: BackendInstallFailure?
    ) {
        let facts = preflight(os: os, arch: arch, android: android, curl: curl)
        let made = BackendInstallPlan.make(installing: .core, preflight: facts)
        let expected: Result<BackendInstallPlan, BackendInstallFailure> =
            failure.map { .failure($0) } ?? .success(BackendInstallPlan(target: .core))
        #expect(made == expected)
    }

    @Test func theCoreExecChecksCurlBeforeDownloadingAndRunsTheCommandVerbatim() throws {
        let plan = BackendInstallPlan(target: .core)
        let exec = BackendInstall.execCommand(for: plan)
        #expect(exec.contains(plan.command))
        #expect(exec.filter { $0 == "'" }.count == 2)
        let check = try #require(exec.range(of: "command -v curl"))
        let download = try #require(exec.range(of: "curl --proto"))
        #expect(check.lowerBound < download.lowerBound)
        // herdr's installer runs without an ignored SIGPIPE, so does core's.
        #expect(!exec.contains("trap \"\" PIPE"))
        // The herdr PATH, so `~/.local/bin` resolves for its `command -v hc`.
        #expect(exec.contains(HerdrHostPath.pathExport))
    }

    @Test(arguments: [
        ("hc: needs curl", BackendInstallFailure.noCurl),
        ("hc: needs tar", .noTar),
        ("hc: cannot reach https://releases.herdr.dev/core/latest.json", .cannotReachInstaller),
        ("hc: download failed: https://releases.herdr.dev/core/0.1.14/hc-linux-x86_64.tar.gz", .cannotReachInstaller),
        ("hc: hc runs on Linux and macOS for now", .unsupportedSystem),
        ("hc: no build for riscv64", .unsupportedSystem),
        ("hc: no build for linux-aarch64 in https://releases.herdr.dev/core/latest.json", .unsupportedSystem),
        ("hc: the download is damaged (checksum mismatch); try again", .other(lastLine: "hc: the download is damaged (checksum mismatch); try again")),
        ("hc: the downloaded hc does not run on this machine", .other(lastLine: "hc: the downloaded hc does not run on this machine")),
        ("hc: updating /home/dev/.local/bin/herdr-core failed (see above)", .other(lastLine: "hc: updating /home/dev/.local/bin/herdr-core failed (see above)")),
    ])
    func coresOwnRefusalsAreRead(line: String, failure: BackendInstallFailure) {
        // Exit 1 for all, as the installer's `fail`.
        #expect(BackendInstall.failure(for: .core, run: run(1, .failed, [line])) == failure)
        #expect(BackendInstall.failure(for: .core, run: run(1, .failed, ["step", line])) == failure)
    }

    @Test func theWrappersReasonDecidesACoreFailureToo() {
        #expect(BackendInstall.failure(for: .core, run: run(1, .noCurl, ["hc: needs tar"])) == .noCurl)
        #expect(BackendInstall.failure(for: .core, run: run(1, .download, [])) == .cannotReachInstaller)
    }

    @Test func herdrsRefusalLinesDoNotReadAsCoreFailuresAndTheOtherWayRound() {
        #expect(
            BackendInstall.failure(for: .core, run: run(1, .failed, ["✗ unsupported OS: FreeBSD"]))
                == .other(lastLine: "✗ unsupported OS: FreeBSD"))
        #expect(
            BackendInstall.failure(for: .herdr, run: run(1, .failed, ["hc: needs tar"]))
                == .other(lastLine: "hc: needs tar"))
    }

    @Test func coreIsFoundOnlyWhenTheRecheckFindsItAtOrAboveTheFloor() {
        let ok = run(0, .ok, ["hc 0.1.14 installed into /home/dev/.local/bin/herdr-core."])
        let found = HostBackendPresence(herdr: false, tmuxVersion: nil, core: Self.coreFound)
        #expect(BackendInstall.result(afterInstalling: .core, run: ok, presence: found) == .found(found))

        let oldCore = HostBackendPresence(
            herdr: false, tmuxVersion: nil,
            core: CorePresence(version: "0.1.9", path: "/home/dev/.local/bin/herdr-core"))
        let last = "hc 0.1.14 installed into /home/dev/.local/bin/herdr-core."
        #expect(
            BackendInstall.result(afterInstalling: .core, run: ok, presence: oldCore)
                == .failed(.other(lastLine: last)))
        // herdr alone on the Host is not what this install was after.
        #expect(
            BackendInstall.result(afterInstalling: .core, run: ok, presence: presence(herdr: true))
                == .failed(.other(lastLine: last)))
    }
}
