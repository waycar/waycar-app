import Testing

@testable import Waycar

@Suite("Codex approval machine")
struct CodexApprovalMachineTests {
    private typealias Machine = CodexApprovalMachine

    private static func request(_ id: Int64, _ command: String = "ls") -> Machine.Request {
        Machine.Request(id: .integer(id), request: AgentPendingRequest(
            id: String(id), kind: .command(command: command, cwd: nil, reason: nil)))
    }

    @Test func requestsAreListedInArrivalOrder() {
        var machine = Machine()
        #expect(machine.handle(.asked("t", Self.request(1))) == [.publish])
        #expect(machine.handle(.asked("t", Self.request(2))) == [.publish])
        #expect(machine.requests("t").map(\.id) == ["1", "2"])
        #expect(machine.request("t", shownAs: "2") == Self.request(2))
        #expect(machine.request("t", shownAs: "3") == nil && machine.requests("u").isEmpty)
    }

    @Test func aReplayedRequestReplacesTheOneListed() {
        var machine = Machine().after([.asked("t", Self.request(1)), .asked("t", Self.request(2))])
        #expect(machine.handle(.asked("t", Self.request(1, "pwd"))) == [.publish])
        #expect(machine.requests("t").map(\.id) == ["2", "1"])
        #expect(machine.request("t", shownAs: "1")?.request.kind == .command(command: "pwd", cwd: nil, reason: nil))
    }

    @Test func aWrittenAnswerRemovesItsRequestAndAlwaysPublishes() {
        var machine = Machine().after([.asked("t", Self.request(1))])
        #expect(machine.handle(.answered("t", .integer(1))) == [.publish])
        #expect(machine.requests("t").isEmpty)
        // Resolved elsewhere while the answer was written: still published.
        #expect(machine.handle(.answered("t", .integer(1))) == [.publish])
    }

    @Test func resolvedElsewherePublishesOnlyWhenSomethingLeft() {
        var machine = Machine().after([.asked("t", Self.request(1)), .asked("t", Self.request(2))])
        #expect(machine.handle(.resolvedElsewhere("t", .number(1))) == [.publish])
        #expect(machine.requests("t").map(\.id) == ["2"])
        #expect(machine.handle(.resolvedElsewhere("t", .number(1))).isEmpty)
        #expect(machine.handle(.resolvedElsewhere("t", .string("2"))).isEmpty)
        #expect(machine.handle(.resolvedElsewhere("u", .number(2))).isEmpty)
    }

    @Test func droppingAThreadForgetsItsRequestsQuietly() {
        var machine = Machine().after([.asked("t", Self.request(1)), .asked("u", Self.request(1))])
        #expect(machine.handle(.dropped("t")).isEmpty)
        #expect(machine.requests("t").isEmpty && machine.requests("u").map(\.id) == ["1"])
    }

    @Test func idsMatchTheirJSONForm() {
        #expect(CodexRPCID.integer(7).matches(.number(7)) && !CodexRPCID.integer(7).matches(.string("7")))
        #expect(CodexRPCID.string("a").matches(.string("a")) && !CodexRPCID.string("a").matches(.number(1)))
        #expect(CodexRPCID.integer(-3).displayString == "-3" && CodexRPCID.string("x").displayString == "x")
    }
}
