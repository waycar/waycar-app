import Testing

@testable import Waycar

@Suite("Terminal recovery generation machine")
struct TerminalRecoveryGenerationMachineTests {
    @Test func inactiveSignalsCannotStartRecovery() {
        let pipeline = TerminalSurfaceID()
        var machine = TerminalRecoveryGenerationMachine()
        #expect(machine.handle([
            .bind(pipeline), .project(2), .acquire(2, by: pipeline), .clearBound(pipeline), .clear,
        ]).isEmpty)
        #expect(machine.state == .inactive)
        #expect(!machine.isActive)
    }

    @Test func beginIsIdempotentAndUnboundProjectionWaitsForBinding() {
        let pipeline = TerminalSurfaceID()
        var machine = TerminalRecoveryGenerationMachine().after([.begin(projected: 3)])
        #expect(machine.isActive)
        #expect(machine.handle(.begin(projected: 9)).isEmpty)
        #expect(machine.handle(.acquire(3, by: pipeline)).isEmpty)
        #expect(machine.handle(.clearBound(pipeline)).isEmpty)
        #expect(machine.state == .unbound(projected: 3))
        #expect(machine.handle(.project(2)) == [.decide(.pending)])
        #expect(machine.state == .unbound(projected: 3))
        #expect(machine.handle(.project(4)) == [.decide(.pending)])
        #expect(machine.handle(.bind(pipeline)).isEmpty)
        #expect(machine.state == .bound(pipeline, acquired: nil, projected: 4))
        #expect(machine.handle(.begin(projected: 8)).isEmpty)
        #expect(machine.handle(.acquire(4, by: pipeline)) == [.decide(.acknowledge(4))])
        #expect(machine.state == .inactive)
    }

    @Test func eitherSignalOrderMakesExactlyOneDecision() {
        for acquired in UInt64(3)...5 {
            for projectionFirst in [false, true] {
                let pipeline = TerminalSurfaceID()
                var machine = TerminalRecoveryGenerationMachine().after([
                    .begin(projected: nil), .bind(pipeline),
                ])
                let first: TerminalRecoveryGenerationMachine.Event = projectionFirst
                    ? .project(4) : .acquire(acquired, by: pipeline)
                let second: TerminalRecoveryGenerationMachine.Event = projectionFirst
                    ? .acquire(acquired, by: pipeline) : .project(4)
                let decision: TerminalRecoveryGenerationMachine.Decision = acquired == 4
                    ? .acknowledge(4) : (acquired < 4 ? .replace(4) : .retain(5))
                #expect(machine.handle(first) == [.decide(.pending)])
                #expect(machine.handle(second) == [.decide(decision)])
                #expect(machine.state == .inactive)
                #expect(machine.handle(second).isEmpty)
            }
        }
    }

    @Test func rebindingFencesOldSignalsAndForgetsOnlyAcquisition() {
        let old = TerminalSurfaceID()
        let current = TerminalSurfaceID()
        var machine = TerminalRecoveryGenerationMachine().after([
            .begin(projected: nil), .bind(old), .acquire(7, by: old), .bind(current),
        ])
        #expect(machine.handle(.acquire(7, by: old)).isEmpty)
        #expect(machine.handle(.clearBound(old)).isEmpty)
        #expect(machine.handle(.project(8)) == [.decide(.pending)])
        #expect(machine.handle(.project(2)) == [.decide(.pending)])
        #expect(machine.handle(.bind(current)).isEmpty)
        #expect(machine.state == .bound(current, acquired: nil, projected: 8))
        #expect(machine.handle(.acquire(6, by: current)) == [.decide(.replace(8))])
    }

    @Test func clearingOnlyTheMatchingBindingOrAllRecoveryDeactivatesIt() {
        let pipeline = TerminalSurfaceID()
        var machine = TerminalRecoveryGenerationMachine().after([.begin(projected: 1), .bind(pipeline)])
        #expect(machine.handle(.clearBound(pipeline)).isEmpty)
        #expect(machine.state == .inactive)
        machine = machine.after([.begin(projected: nil)])
        #expect(machine.handle(.clear).isEmpty)
        #expect(machine.state == .inactive)
        machine = machine.after([.begin(projected: 1), .bind(pipeline)])
        #expect(machine.handle(.clear).isEmpty)
        #expect(machine.state == .inactive)
    }
}
