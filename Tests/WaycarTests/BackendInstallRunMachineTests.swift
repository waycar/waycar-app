import Testing

@testable import Waycar

@Suite("Backend install run machine")
struct BackendInstallRunMachineTests {
    private let plan = BackendInstallPlan(target: .herdr)
    private let installed = BackendInstallRun(exitStatus: 0, reason: .ok, output: [])

    @Test func consentIsSingleFlightAndOutputIsBoundedToTheInstallStage() {
        var machine = BackendInstallRunMachine()
        #expect(machine.handle(.start(plan)) == [.install(1, plan)])
        #expect(machine.handle(.start(plan)).isEmpty)
        for line in 1...45 { _ = machine.handle(.output(1, "line \(line)")) }
        #expect(machine.run?.output == (6...45).map { "line \($0)" })
        #expect(machine.run?.phase == .installing(latestLine: "line 45"))
        #expect(machine.handle(.installerEnded(1, .success(installed))) == [.detect(1)])
        let checking = machine.state
        #expect(machine.handle(.output(1, "late")).isEmpty)
        #expect(machine.handle(.dismiss).isEmpty)
        #expect(machine.handle(.start(plan)).isEmpty)
        #expect(machine.state == checking)
    }

    @Test(arguments: [BackendInstallTarget.herdr, .core, .tmux(.aptGet)])
    func onlyFoundHerdrAndCoreStartARuntime(target: BackendInstallTarget) {
        let plan = BackendInstallPlan(target: target)
        let presence = HostBackendPresence(
            herdr: true, tmuxVersion: "3.4", core: CorePresence(version: "0.1.14", path: "/bin/herdr-core"))
        var machine = BackendInstallRunMachine().after([.start(plan), .installerEnded(1, .success(installed))])
        let outcome = BackendInstallCenter.Outcome(plan: plan, result: .found(presence))
        let effects = machine.handle(.detected(1, .success(presence)))
        switch target {
        case .herdr, .core:
            #expect(effects == [.startRuntime(1, target)])
            #expect(machine.run?.phase == .checking)
            #expect(machine.outcome == nil)
            #expect(machine.handle(.runtimeEnded(0)).isEmpty)
            #expect(machine.handle(.runtimeEnded(1)) == [.report(outcome)])
        case .tmux:
            #expect(effects == [.report(outcome)])
        }
        #expect(machine.outcome == outcome)
        #expect(machine.run == nil)
        #expect(machine.handle(.runtimeEnded(1)).isEmpty)
        #expect(machine.handle(.dismiss).isEmpty)
        #expect(machine.state == .idle)
        #expect(machine.handle(.start(plan)) == [.install(2, plan)])
        let newer = machine.state
        #expect(machine.handle(.installerEnded(1, .success(installed))).isEmpty)
        #expect(machine.handle(.output(1, "stale")).isEmpty)
        #expect(machine.state == newer)
    }

    @Test func failedAndInterruptedInstallsNeverDetect() {
        let cases: [(Result<BackendInstallRun, TransportError>, BackendInstallResult)] = [
            (.failure(.timedOut), .hostUnreachable(.timedOut)),
            (.success(.init(exitStatus: nil, reason: nil, output: [])),
             .hostUnreachable(.channelFailed(detail: "The connection ended during the install."))),
            (.success(.init(exitStatus: 1, reason: .admin, output: [])), .failed(.needsAdmin)),
        ]
        for (result, expected) in cases {
            var machine = BackendInstallRunMachine().after([.start(plan)])
            #expect(machine.handle(.installerEnded(0, result)).isEmpty)
            #expect(machine.handle(.installerEnded(1, result)) == [.report(.init(plan: plan, result: expected))])
        }
    }

    @Test func missingToolAndFailedDetectionNeverStart() {
        let missing = HostBackendPresence(herdr: false, tmuxVersion: nil)
        var machine = BackendInstallRunMachine().after([.start(plan), .installerEnded(1, .success(installed))])
        #expect(machine.handle(.detected(0, .success(.herdrOnly))).isEmpty)
        #expect(machine.handle(.detected(1, .success(missing))) == [.report(.init(plan: plan, result: .failed(.other(lastLine: nil))))])
        machine = BackendInstallRunMachine().after([.start(plan), .installerEnded(1, .success(installed))])
        #expect(machine.handle(.detected(1, .failure(.timedOut))) == [.report(.init(plan: plan, result: .hostUnreachable(.timedOut)))])
        #expect(machine.handle(.start(plan)) == [.install(2, plan)])
        #expect(machine.outcome == nil)
    }

    @Test func idleCompletionsDoNothing() {
        var machine = BackendInstallRunMachine()
        #expect(machine.handle([.output(1, "late"), .installerEnded(1, .success(installed)), .detected(1, .success(.herdrOnly)), .runtimeEnded(1), .dismiss]).isEmpty)
        #expect(machine.state == .idle)
    }
}
