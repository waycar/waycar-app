import Testing

@testable import Waycar

@Suite("Codex thread activity machine")
struct CodexThreadActivityMachineTests {
    private typealias Machine = CodexThreadActivityMachine

    private static func status(_ type: String, _ flags: [String] = []) -> JSONValue {
        .object(["type": .string(type), "activeFlags": .array(flags.map(JSONValue.string))])
    }

    private static let idle = status("idle")
    private static let active = status("active")
    private static let blocked = status("active", ["waitingOnApproval"])
    private static let error = status("systemError")

    @Test func theInitialStatusIsNeverDone() {
        #expect(Machine(status: Self.idle, hasTurns: false).agentStatus == .idle)
        #expect(Machine(status: Self.active, hasTurns: true).agentStatus == .working)
        #expect(Machine(status: Self.blocked, hasTurns: true).agentStatus == .blocked)
        #expect(Machine(status: Self.error, hasTurns: false).agentStatus == .unknown)
    }

    @Test func aTurnStartingMakesItWorkingWithAConversation() {
        var machine = Machine(status: Self.idle, hasTurns: false)
        #expect(machine.handle(.statusChanged(Self.active)) == [.dropRequests, .publish])
        #expect(machine.agentStatus == .working && machine.isActive && machine.state.hasTurns)
    }

    @Test func aSeenTurnEndIsDoneUntilAcknowledged() {
        var machine = Machine(status: Self.active, hasTurns: true)
        #expect(machine.handle(.statusChanged(Self.idle)) == [.forgetTurn, .dropRequests, .publish])
        #expect(machine.agentStatus == .done && machine.isDone)
        #expect(machine.handle(.acknowledged) == [.publish])
        #expect(machine.agentStatus == .idle)
        #expect(machine.handle(.acknowledged).isEmpty)
    }

    @Test func anIdleNeverSeenActiveIsNotDone() {
        var machine = Machine(status: Self.active, hasTurns: true).after([.statusChanged(Self.error)])
        #expect(machine.agentStatus == .unknown)
        _ = machine.handle(.statusChanged(Self.idle))
        #expect(machine.agentStatus == .idle)
    }

    @Test func doneOutlastsAnotherStatusAndCanBeAcknowledgedThere() {
        var machine = Machine(status: Self.active, hasTurns: true).after([.statusChanged(Self.idle)])
        #expect(machine.handle(.statusChanged(Self.error)) == [.forgetTurn, .dropRequests, .publish])
        #expect(machine.agentStatus == .unknown && machine.isDone)
        _ = machine.handle(.statusChanged(Self.idle))
        #expect(machine.agentStatus == .done)
        _ = machine.handle(.statusChanged(Self.error))
        #expect(machine.handle(.acknowledged) == [.publish])
        _ = machine.handle(.statusChanged(Self.idle))
        #expect(machine.agentStatus == .idle)
    }

    @Test func blockedResumesAndKeepsRequests() {
        var machine = Machine(status: Self.active, hasTurns: true)
        #expect(machine.handle(.statusChanged(Self.blocked)) == [.publish, .resumeBlocked])
        #expect(machine.agentStatus == .blocked)
        #expect(machine.handle(.statusChanged(Self.active)) == [.dropRequests, .publish])
    }

    @Test func anUnchangedStatusChangesNothing() {
        var machine = Machine(status: Self.active, hasTurns: true).after([.statusChanged(Self.idle)])
        #expect(machine.handle(.statusChanged(Self.idle)).isEmpty)
        #expect(machine.agentStatus == .done)
    }

    @Test func aTurnStartGivesItAConversationQuietly() {
        var machine = Machine(status: Self.idle, hasTurns: false)
        #expect(machine.handle(.turnStarted).isEmpty)
        #expect(machine.state.hasTurns && machine.agentStatus == .idle)
    }
}
