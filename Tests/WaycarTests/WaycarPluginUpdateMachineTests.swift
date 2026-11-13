import Testing

@testable import Waycar

@Suite("Host Tools update machine")
struct WaycarPluginUpdateMachineTests {
    private let result = WaycarPluginUpdateResult(
        installedVersion: nil, warnings: [], codexHooksNeedReview: false, output: [])

    @Test func refusalDoesNotReleaseAnotherRunsHostAndRetryGetsANewToken() {
        var machine = WaycarPluginUpdateMachine()
        #expect(machine.phase == .confirm)
        #expect(machine.handle(.start) == [.acquire(1)])
        #expect(machine.handle(.start).isEmpty)
        #expect(machine.handle(.acquired(0, true)).isEmpty)
        #expect(machine.handle(.acquired(1, false)).isEmpty)
        #expect(!machine.isRunning)
        #expect(machine.phase == .failed(message: "An update is already running on this Host.", lastLine: nil, keptVersion: nil))
        #expect(machine.handle(.start) == [.acquire(2)])
        #expect(machine.handle(.acquired(2, true)) == [.install(2)])
        #expect(machine.handle(.released(1)).isEmpty)
        #expect(machine.isRunning)
    }

    @Test(arguments: [false, true])
    func successRetainsTheLockThroughVerificationAndNotification(outdated: Bool) {
        var machine = WaycarPluginUpdateMachine().after([.start, .acquired(1, true)])
        #expect(machine.handle(.output(1, "installed")).isEmpty)
        #expect(machine.handle(.installerEnded(1, .success(result))) == [.verify(1, .installed(result))])
        #expect(machine.phase == .running(latestLine: "installed"))
        #expect(machine.handle(.start).isEmpty)
        #expect(machine.handle(.output(1, "late")).isEmpty)
        #expect(machine.handle(.verified(0, presence: nil, stillOutdated: true, keptVersion: nil)).isEmpty)
        // Nil presence intentionally still reports success, never an update gate.
        #expect(machine.handle(.verified(1, presence: nil, stillOutdated: outdated, keptVersion: nil)) == [.notify(nil), .release(1)])
        #expect(machine.phase == .succeeded(result, stillOutdated: outdated))
        #expect(machine.isRunning)
        #expect(machine.handle(.start).isEmpty, "callbacks cannot re-enter Start")
        #expect(machine.handle(.released(0)).isEmpty)
        #expect(machine.handle(.released(1)).isEmpty)
        #expect(!machine.isRunning)
        #expect(machine.handle(.start) == [.acquire(2)])
        #expect(machine.handle(.installerEnded(1, .success(result))).isEmpty)
        #expect(machine.handle(.verified(1, presence: .herdrOnly, stillOutdated: false, keptVersion: nil)).isEmpty)
    }

    @Test(arguments: [false, true])
    func failureVerifiesTheKeptVersionAndOnlyDuplicatesUnembeddedOutput(includesLine: Bool) {
        var machine = WaycarPluginUpdateMachine().after([.start, .acquired(1, true), .output(1, "last output")])
        let error = WaycarPluginUpdateMachine.Failure(message: "failed", includesLastLine: includesLine)
        let verification = WaycarPluginUpdateMachine.Verification.failed(
            message: "failed", lastLine: includesLine ? nil : "last output")
        #expect(machine.handle(.installerEnded(1, .failure(error))) == [.verify(1, verification)])
        #expect(machine.handle(.verified(1, presence: nil, stillOutdated: false, keptVersion: "1.7.0")) == [.release(1)])
        #expect(machine.phase == .failed(message: "failed", lastLine: includesLine ? nil : "last output", keptVersion: "1.7.0"))
        #expect(machine.handle(.released(1)).isEmpty)
        #expect(!machine.isRunning)
    }

    @Test func missingCredentialsReleaseWithoutInstallingOrVerifying() {
        var machine = WaycarPluginUpdateMachine().after([.start, .acquired(1, true)])
        #expect(machine.handle(.credentialsFailed(0, "old")).isEmpty)
        #expect(machine.handle(.credentialsFailed(1, "missing password")) == [.release(1)])
        #expect(machine.phase == .failed(message: "missing password", lastLine: nil, keptVersion: nil))
        #expect(machine.isRunning)
        #expect(machine.handle(.released(1)).isEmpty)
        #expect(!machine.isRunning)
    }

    @Test func completionsWithoutARunDoNothing() {
        var machine = WaycarPluginUpdateMachine()
        #expect(machine.handle([.acquired(1, true), .output(1, "late"), .credentialsFailed(1, "late"), .installerEnded(1, .success(result)), .verified(1, presence: nil, stillOutdated: false, keptVersion: nil), .released(1)]).isEmpty)
        #expect(machine.state == .confirm)
    }
}
