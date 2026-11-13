import Testing

@testable import Waycar

@Suite("Host checks machine")
struct HostChecksMachineTests {
    @Test func detectsChecksPublishesAndFinishes() {
        var machine = HostChecksMachine(enabled: true, presence: .herdrOnly)
        #expect(machine.handle(.request) == [.run(1)])
        #expect(machine.isRunning && machine.accepts(1))
        #expect(machine.facts.presence == .herdrOnly)
        #expect(machine.handle(.detected(99, .herdrOnly)).isEmpty)
        #expect(machine.handle(.detected(1, .herdrOnly)).isEmpty)
        guard case .checking = machine.state else {
            Issue.record("detection should advance the checks")
            return
        }
        var facts = machine.facts
        facts.report = .allPassed
        _ = machine.handle(.factsChanged(facts))
        #expect(machine.handle(.ended(99)).isEmpty)
        #expect(machine.isRunning)
        #expect(machine.handle(.ended(1)).isEmpty)
        #expect(machine.hasFinished && !machine.isRunning)
        #expect(machine.facts.report == .allPassed)
        #expect(!machine.accepts(1))
        #expect(machine.handle(.request) == [.run(2)])
        #expect(machine.facts.report == nil)
    }

    @Test func repeatedRequestsCoalesceIntoOneFreshRun() {
        var machine = HostChecksMachine(enabled: true).after([.request, .request, .request])
        #expect(machine.handle(.ended(1)) == [.run(2)])
        #expect(machine.accepts(2) && !machine.accepts(1))
        #expect(machine.handle(.ended(1)).isEmpty)
        #expect(machine.handle(.ended(2)).isEmpty)
        #expect(machine.hasFinished)
        var checking = HostChecksMachine(enabled: true).after([
            .request, .detected(1, .herdrOnly), .request,
        ])
        #expect(checking.handle(.ended(1)) == [.run(2)])
    }

    @Test func disabledWorkNeverRevivesButAnExplicitRerunCanFollowIt() {
        let setups: [[HostChecksMachine.Event]] = [
            [.request], [.request, .detected(1, .herdrOnly)],
        ]
        for setup in setups {
            var machine = HostChecksMachine(enabled: true).after(setup)
            _ = machine.handle(.enabled(false))
            #expect(!machine.isEnabled && !machine.accepts(1))
            #expect(machine.handle(.request).isEmpty)
            _ = machine.handle(.enabled(true))
            #expect(machine.isEnabled && !machine.accepts(1))
            #expect(machine.handle(.detected(1, .herdrOnly)).isEmpty)
            #expect(machine.handle(.ended(1)).isEmpty)
            #expect(machine.hasFinished)
        }
        var rerun = HostChecksMachine(enabled: true).after([
            .request, .enabled(false), .enabled(true), .request,
        ])
        #expect(rerun.handle(.ended(1)) == [.run(2)])
    }

    @Test func disablingDoesNotEraseAnExistingReportOrStartWork() {
        var machine = HostChecksMachine(enabled: false)
        #expect(machine.handle([.request, .ended(1), .detected(1, .herdrOnly)]).isEmpty)
        #expect(!machine.isRunning && !machine.hasFinished)
        _ = machine.handle(.enabled(true))
        _ = machine.handle(.request)
        var facts = machine.facts
        facts.report = .allPassed
        _ = machine.handle([.factsChanged(facts), .ended(1), .enabled(false)])
        #expect(machine.facts.report == .allPassed)
        #expect(machine.hasFinished && !machine.isEnabled)
        #expect(machine.handle(.request).isEmpty)
    }
}
