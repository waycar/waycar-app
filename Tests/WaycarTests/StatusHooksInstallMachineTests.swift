import Testing

@testable import Waycar

@Suite("Status hooks installation machine")
struct StatusHooksInstallMachineTests {
    private let report = StatusHooksReport(
        version: 1,
        hostTools: .init(version: "2.5.0", pluginRoot: "/home/dev/.waycar"),
        backends: .init(herdr: false, tmux: "3.4"),
        configDir: "/home/dev/.config/waycar", agents: [])

    @Test func installsOnceAndPublishesTheFreshReport() {
        var machine = StatusHooksInstallMachine()
        #expect(machine.handle(.install) == [.connect(1)])
        #expect(machine.isInstalling)
        #expect(machine.handle(.install).isEmpty)
        #expect(machine.handle(.connected(99)).isEmpty)
        #expect(machine.handle(.connected(1)) == [.install(1)])
        #expect(machine.handle(.completed(99, report)).isEmpty)
        #expect(machine.handle(.completed(1, report)) == [.publish(report)])
        #expect(!machine.isInstalling && machine.error == nil)
        #expect(machine.handle(.install) == [.connect(2)])
        #expect(machine.handle(.failed(1, "old")).isEmpty)
        #expect(machine.state == .connecting(2))
    }

    @Test func failureCanRetryAndChecksClearOnlyTheError() {
        var machine = StatusHooksInstallMachine().after([.install, .failed(1, "failure")])
        #expect(machine.error == "failure")
        #expect(machine.handle(.checksStarted).isEmpty)
        #expect(machine.error == nil)
        #expect(machine.handle(.install) == [.connect(2)])
        #expect(machine.handle(.checksStarted).isEmpty)
        #expect(machine.state == .connecting(2))
        #expect(machine.handle(.connected(2)) == [.install(2)])
        _ = machine.handle(.failed(2, "install failed"))
        #expect(machine.error == "install failed")
    }

    @Test func disableSuppressesTheOperationAndLatePublication() {
        let setups: [[StatusHooksInstallMachine.Event]] = [[.install], [.install, .connected(1)]]
        for setup in setups {
            var machine = StatusHooksInstallMachine().after(setup)
            #expect(machine.handle(.disabled).isEmpty)
            #expect(machine.state == .invalidated(1))
            #expect(machine.handle([.install, .connected(1), .completed(1, report), .failed(1, "old")]).isEmpty)
            #expect(machine.handle(.ended(2)).isEmpty)
            #expect(machine.isInstalling)
            #expect(machine.handle(.ended(1)).isEmpty)
            #expect(!machine.isInstalling && machine.error == nil)
        }
        var idle = StatusHooksInstallMachine()
        #expect(idle.handle([.disabled, .connected(1), .completed(1, report), .ended(1)]).isEmpty)
        #expect(idle.state == .idle(error: nil))
    }
}
