import CryptoKit
import Foundation
import Testing

@testable import Waycar

@MainActor
@Suite("Backend install center")
struct BackendInstallCenterTests {
    /// The center never dials; any dial would fail.
    private static let noDial = FakeTransportConnector.Outcome.unreachable(.timedOut)

    private static let herdrPlan = BackendInstallPlan(target: .herdr)
    private static let tmuxPlan = BackendInstallPlan(target: .tmux(.aptGet))

    private let hostID = UUID()
    private let settings = SSHTransportSettings(
        host: "host.example", port: 22, username: "dev",
        credentials: .ed25519(Curve25519.Signing.PrivateKey()),
        hostKeyPolicy: HostKeyPolicy(knownHosts: InMemoryKnownHostsStore()) { _ in false },
        socket: .defaultSession)

    private func run(
        _ status: Int32, _ reason: BackendInstallRun.Reason, _ output: [String] = []
    ) -> Result<BackendInstallRun, TransportError> {
        .success(BackendInstallRun(exitStatus: status, reason: reason, output: output))
    }

    private func makeCenter(
        runs: [Result<BackendInstallRun, TransportError>],
        before: HostBackendPresence = HostBackendPresence(herdr: false, tmuxVersion: nil),
        after: HostBackendPresence? = nil,
        progress: [String] = [],
        detectionError: TransportError? = nil,
        wakeError: TransportError? = nil
    ) async -> (BackendInstallCenter, FakeTransportConnector) {
        let connector = FakeTransportConnector(
            outcome: Self.noDial, presence: before, detectionError: detectionError)
        await connector.scriptInstall(
            runs: runs, progress: progress, presenceAfter: after, wakeError: wakeError)
        return (BackendInstallCenter(connector: connector), connector)
    }

    private func finish(_ center: BackendInstallCenter) async throws -> BackendInstallResult? {
        try await waitUntil("the run finishes") { center.outcomes[hostID] != nil }
        return center.outcomes[hostID]?.result
    }

    // MARK: Found only after the re-check

    @Test func herdrIsFoundAfterTheRecheckFindsItAndTheServerIsWoken() async throws {
        let found = HostBackendPresence(herdr: true, tmuxVersion: nil)
        let (center, connector) = await makeCenter(
            runs: [run(0, .ok, ["installed herdr"])], after: found)

        #expect(center.start(Self.herdrPlan, on: hostID, settings: settings))
        let result = try await finish(center)

        #expect(result == .found(found))
        #expect(center.runs[hostID] == nil)
        #expect(await connector.installPlans == [Self.herdrPlan])
        #expect(await connector.detectionCount == 1)
        // Install herdr is an explicit request to set it up: the installer
        // starts no server, so the center still starts it exactly once.
        #expect(await connector.wakeCount == 1)
    }

    @Test(arguments: [false, true])
    func aFoundCoreInstallStartsCoreOnceEvenIfTheStartFails(startFails: Bool) async throws {
        let found = HostBackendPresence(
            herdr: false, tmuxVersion: nil,
            core: CorePresence(version: "0.1.14", path: "/home/dev/.local/bin/herdr-core"))
        let (center, connector) = await makeCenter(
            runs: [run(0, .ok)], after: found,
            wakeError: startFails ? .channelFailed(detail: "start refused") : nil)
        center.start(BackendInstallPlan(target: .core), on: hostID, settings: settings)
        #expect(try await finish(center) == .found(found))
        #expect(await connector.coreStartCount == 1)
        #expect(await connector.wakeCount == 0)
        // Check Again is diagnostic, never a start.
        _ = try await center.detectBackends(settings: settings)
        #expect(await connector.coreStartCount == 1)
    }

    @Test func aCoreInstallNotFoundByDetectionStartsNothing() async throws {
        let (center, connector) = await makeCenter(runs: [run(0, .ok)])
        center.start(BackendInstallPlan(target: .core), on: hostID, settings: settings)
        _ = try await finish(center)
        #expect(await connector.coreStartCount == 0)
    }

    @Test func aCleanExitIsNotAnInstallUntilTheRecheckFindsTheTool() async throws {
        let (center, connector) = await makeCenter(
            runs: [run(0, .ok, ["installed herdr to /home/dev/.local/bin/herdr"])],
            after: HostBackendPresence(herdr: false, tmuxVersion: nil))

        center.start(Self.herdrPlan, on: hostID, settings: settings)
        let result = try await finish(center)

        #expect(
            result == .failed(.other(lastLine: "installed herdr to /home/dev/.local/bin/herdr")))
        #expect(await connector.detectionCount == 1)
        #expect(await connector.wakeCount == 0)
    }

    @Test func tmuxBelowTheFloorIsTooOldWhateverTheInstallerSaid() async throws {
        let (center, connector) = await makeCenter(
            runs: [run(0, .ok, ["Setting up tmux (2.7)"])],
            after: HostBackendPresence(herdr: false, tmuxVersion: "2.7"))

        center.start(Self.tmuxPlan, on: hostID, settings: settings)

        #expect(try await finish(center) == .failed(.tmuxTooOld(found: "2.7")))
        #expect(await connector.wakeCount == 0)
    }

    @Test func tmuxAtTheFloorIsFoundWithoutWakingHerdr() async throws {
        let found = HostBackendPresence(herdr: false, tmuxVersion: "3.4")
        let (center, connector) = await makeCenter(runs: [run(0, .ok)], after: found)

        center.start(Self.tmuxPlan, on: hostID, settings: settings)

        #expect(try await finish(center) == .found(found))
        #expect(await connector.wakeCount == 0)
    }

    @Test func aFailedWakeStillLeavesHerdrFound() async throws {
        let found = HostBackendPresence(herdr: true, tmuxVersion: nil)
        let (center, connector) = await makeCenter(
            runs: [run(0, .ok)], after: found, wakeError: .channelFailed(detail: "no herdr"))

        center.start(Self.herdrPlan, on: hostID, settings: settings)

        #expect(try await finish(center) == .found(found))
        #expect(await connector.wakeCount == 1)
    }

    // MARK: Failures

    @Test(arguments: [
        (BackendInstallRun.Reason.noCurl, BackendInstallFailure.noCurl),
        (.download, .cannotReachInstaller),
        (.admin, .needsAdmin),
        (.noPackageManager, .noPackageManager),
        (.failed, .other(lastLine: "boom")),
    ])
    func eachFailureReachesTheOutcomeAndRunsNoRecheck(
        reason: BackendInstallRun.Reason, failure: BackendInstallFailure
    ) async throws {
        let (center, connector) = await makeCenter(
            runs: [run(1, reason, ["boom"])],
            after: HostBackendPresence(herdr: true, tmuxVersion: "3.4"))

        center.start(Self.tmuxPlan, on: hostID, settings: settings)

        #expect(try await finish(center) == .failed(failure))
        // A failed install is never "installed", whatever the Host has now.
        #expect(await connector.detectionCount == 0)
        #expect(await connector.wakeCount == 0)
    }

    @Test func anInstallerThatRefusesTheSystemIsUnsupportedSystem() async throws {
        let (center, _) = await makeCenter(
            runs: [
                run(
                    1, .failed,
                    [
                        "  > detected linux/aarch64",
                        "  ✗ Android/Termux is not currently supported by Herdr release binaries.",
                    ])
            ])

        center.start(Self.herdrPlan, on: hostID, settings: settings)

        #expect(try await finish(center) == .failed(.unsupportedSystem))
    }

    @Test func aRunThatNeverPrintedItsMarkerIsHostUnreachableNotAFailedInstall() async throws {
        let (center, connector) = await makeCenter(
            runs: [
                .success(BackendInstallRun(exitStatus: nil, reason: nil, output: ["Reading package lists..."]))
            ])

        center.start(Self.tmuxPlan, on: hostID, settings: settings)

        #expect(
            try await finish(center)
                == .hostUnreachable(
                    .channelFailed(
                        detail: "The connection ended during the install. Last line: Reading package lists...")))
        #expect(await connector.detectionCount == 0)
    }

    @Test func aDeadLinkIsHostUnreachableNotAFailedInstall() async throws {
        let (center, connector) = await makeCenter(runs: [.failure(.sshUnreachable(detail: "reset"))])

        center.start(Self.herdrPlan, on: hostID, settings: settings)

        #expect(try await finish(center) == .hostUnreachable(.sshUnreachable(detail: "reset")))
        #expect(await connector.detectionCount == 0)
    }

    @Test func aRecheckThatCannotReachTheHostIsHostUnreachable() async throws {
        let (center, connector) = await makeCenter(
            runs: [run(0, .ok)], detectionError: .timedOut)

        center.start(Self.herdrPlan, on: hostID, settings: settings)

        #expect(try await finish(center) == .hostUnreachable(.timedOut))
        #expect(await connector.wakeCount == 0)
    }

    // MARK: One run per Host

    @Test func aSecondRunOnTheSameHostIsRefusedWhileOneRuns() async throws {
        let found = HostBackendPresence(herdr: true, tmuxVersion: nil)
        let (center, connector) = await makeCenter(runs: [run(0, .ok)], after: found)
        await connector.holdInstalls()

        #expect(center.start(Self.herdrPlan, on: hostID, settings: settings))
        try await waitUntil("the first run reaches the Host") { center.runs[hostID] != nil }
        #expect(center.start(Self.tmuxPlan, on: hostID, settings: settings) == false)
        // Another Host is not held up by it.
        #expect(center.start(Self.tmuxPlan, on: UUID(), settings: settings))

        await connector.releaseInstalls()
        #expect(try await finish(center) == .found(found))
        #expect(await connector.installPlans.filter { $0 == Self.herdrPlan }.count == 1)
        // Done, the Host takes a new run.
        #expect(center.start(Self.tmuxPlan, on: hostID, settings: settings))
        _ = try await finish(center)
    }

    @Test func aRunReportsItsLatestLineAndThenChecking() async throws {
        let found = HostBackendPresence(herdr: true, tmuxVersion: nil)
        let (center, connector) = await makeCenter(
            runs: [run(0, .ok)], after: found, progress: ["fetching", "downloading v0.9.5"])
        await connector.holdInstalls()

        center.start(Self.herdrPlan, on: hostID, settings: settings)

        try await waitUntil("the latest line shows") {
            center.runs[hostID]?.phase == .installing(latestLine: "downloading v0.9.5")
        }
        #expect(center.runs[hostID]?.plan == Self.herdrPlan)
        await connector.releaseInstalls()
        _ = try await finish(center)
        #expect(center.runs[hostID] == nil)
    }

    @Test func aRunKeepsEveryLineItPrintedForTheLog() async throws {
        let lines = (1...3).map { "line \($0)" }
        let (center, connector) = await makeCenter(
            runs: [run(0, .ok)], after: HostBackendPresence(herdr: true, tmuxVersion: nil),
            progress: lines)
        await connector.holdInstalls()

        center.start(Self.herdrPlan, on: hostID, settings: settings)

        try await waitUntil("every line shows") { center.runs[hostID]?.output == lines }
        await connector.releaseInstalls()
        _ = try await finish(center)
    }

    @Test func aRunKeepsOnlyItsLatestLines() async throws {
        let lines = (1...(BackendInstallCenter.Run.outputLimit + 5)).map { "line \($0)" }
        let (center, connector) = await makeCenter(
            runs: [run(0, .ok)], after: HostBackendPresence(herdr: true, tmuxVersion: nil),
            progress: lines)
        await connector.holdInstalls()

        center.start(Self.herdrPlan, on: hostID, settings: settings)

        try await waitUntil("the last line shows") { center.runs[hostID]?.output.last == lines.last }
        #expect(center.runs[hostID]?.output.count == BackendInstallCenter.Run.outputLimit)
        #expect(center.runs[hostID]?.output.first == "line 6")
        await connector.releaseInstalls()
        _ = try await finish(center)
    }

    @Test func aFinishedRunIsReportedToTheOwnerWithItsOutcome() async throws {
        let found = HostBackendPresence(herdr: true, tmuxVersion: nil)
        let (center, _) = await makeCenter(runs: [run(0, .ok)], after: found)
        var reported: [(Host.ID, BackendInstallCenter.Outcome)] = []
        center.onOutcome = { reported.append(($0, $1)) }

        center.start(Self.herdrPlan, on: hostID, settings: settings)
        _ = try await finish(center)

        #expect(reported.count == 1)
        #expect(reported.first?.0 == hostID)
        #expect(reported.first?.1.result == .found(found))
        #expect(reported.first?.1.plan == Self.herdrPlan)
    }

    @Test func aHiddenRunCompletesAndKeepsItsOutcome() async throws {
        let found = HostBackendPresence(herdr: true, tmuxVersion: nil)
        let (center, connector) = await makeCenter(runs: [run(0, .ok)], after: found)
        await connector.holdInstalls()

        // The sheet that starts the run is dismissed: its task is cancelled.
        let sheet = Task { @MainActor in
            center.start(Self.herdrPlan, on: hostID, settings: settings)
            try? await Task.sleep(for: .seconds(60))
        }
        try await waitUntil("the run reaches the Host") { center.runs[hostID] != nil }
        sheet.cancel()
        await sheet.value

        #expect(center.runs[hostID] != nil)
        await connector.releaseInstalls()
        #expect(try await finish(center) == .found(found))
        // Reopening sees the outcome until it is dismissed.
        center.dismissOutcome(for: hostID)
        #expect(center.outcomes[hostID] == nil)
    }

    @Test func aNewRunClearsTheHostsPreviousOutcome() async throws {
        let (center, _) = await makeCenter(
            runs: [run(1, .admin), run(1, .admin)])
        center.start(Self.tmuxPlan, on: hostID, settings: settings)
        #expect(try await finish(center) == .failed(.needsAdmin))

        center.start(Self.tmuxPlan, on: hostID, settings: settings)

        #expect(center.outcomes[hostID] == nil)
        #expect(center.runs[hostID] != nil)
        _ = try await finish(center)
    }

    // MARK: Preflight

    @Test func preflightIsOneExecThroughTheConnector() async throws {
        let facts = HostInstallPreflight(
            operatingSystem: "Linux", architecture: "x86_64", isAndroid: false, hasCurl: true,
            packageManagers: [.aptGet], isRoot: false, sudoWithoutPassword: false)
        let connector = FakeTransportConnector(outcome: Self.noDial)
        await connector.scriptInstall(preflight: .success(facts))
        let center = BackendInstallCenter(connector: connector)

        #expect(try await center.preflight(settings: settings) == facts)
        #expect(await connector.preflightCount == 1)
        #expect(await connector.detectionCount == 0)
    }
}
