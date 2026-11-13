import Foundation
import Testing

@testable import Waycar

@Suite("New Agent form preparation transitions")
struct LaunchPreparationMachineTests {
    private let hostID = UUID()

    private var target: LaunchPreparationMachine.Target {
        .init(hostID: hostID, workspaceID: "first", dispatch: .init(
            destination: .existingWorkspace, launch: .agent(.claude)), queuedBackend: .herdr)
    }

    private func draft(workspaceID: String = "first") -> LaunchDraft {
        LaunchDraft(id: UUID(), hostID: hostID, dispatch: target.dispatch,
            workspaceID: workspaceID, originCwd: nil, name: nil, suggestedName: nil,
            userArguments: [], chatMode: false, presetFirstMessage: nil, firstMessage: nil,
            remembersLaunch: true, isQuickChat: false)
    }

    @Test func preparationHasOneOwnerUntilFinished() {
        var machine = LaunchPreparationMachine()
        #expect(machine.handle(.begin(hostID)) == [.assemble(1)])
        #expect(machine.handle(.begin(UUID())).isEmpty)
        #expect(machine.state == .assembling(1, hostID))
        #expect(machine.handle(.preparing(1, target)).isEmpty)
        #expect(machine.state == .preparing(1, target))
        let launch = draft()
        #expect(machine.handle(.prepared(1, launch)) == [.useDraft(launch)])
        #expect(machine.state == .prepared(1, launch))
        #expect(machine.isPreparing)
        #expect(machine.handle(.finish(1)).isEmpty)
        #expect(machine.state == .editing)
        #expect(machine.handle(.begin(hostID)) == [.assemble(2)])
        #expect(machine.handle(.finish(1)).isEmpty)
        #expect(machine.state == .assembling(2, hostID))
    }

    @Test func homeApplicabilityAndTokensGateAssembly() {
        var machine = LaunchPreparationMachine().after([.begin(hostID), .resolvingHome(1)])
        #expect(machine.state == .resolvingHome(1, hostID))
        #expect(machine.handle(.homeResolved(2, applies: true)).isEmpty)
        #expect(machine.handle(.homeResolved(1, applies: true)) == [.assemble(1)])
        #expect(machine.state == .assembling(1, hostID))
        _ = machine.handle([.resolvingHome(1), .homeResolved(1, applies: false)])
        #expect(machine.state == .editing && !machine.isPreparing)
        #expect(machine.handle(.prepared(1, draft())).isEmpty)
    }

    @Test func anotherHostsWorkspaceCannotBecomeThePreparedDraft() {
        var machine = LaunchPreparationMachine().after([.begin(hostID), .preparing(1, target)])
        #expect(machine.handle(.prepared(1, draft(workspaceID: "second"))).isEmpty)
        #expect(machine.state == .preparing(1, target))
        #expect(machine.handle(.prepared(2, draft())).isEmpty)
        let wrongHost = LaunchPreparationMachine.Target(hostID: UUID(), workspaceID: "first",
            dispatch: target.dispatch, queuedBackend: .herdr)
        machine = LaunchPreparationMachine().after([.begin(hostID), .preparing(1, wrongHost)])
        #expect(machine.state == .assembling(1, hostID))
        #expect(machine.handle(.finish(1)).isEmpty)
        #expect(machine.state == .editing)
    }
}
