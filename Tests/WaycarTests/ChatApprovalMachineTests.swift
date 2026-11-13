import Testing

@testable import Waycar

@Suite("Chat approval machine")
struct ChatApprovalMachineTests {
    @Test func terminalReadRetryAndClearKeepTheExistingPresentation() {
        var machine = ChatApprovalMachine()
        #expect(machine.screen == nil && !machine.screenUnreadable)
        #expect(machine.handle(.screenRead(nil)).isEmpty)
        #expect(machine.screenUnreadable)
        #expect(machine.handle(.retry).isEmpty)
        #expect(!machine.screenUnreadable && machine.screen == nil)
        _ = machine.handle(.screenRead("Question"))
        #expect(machine.screen == "Question")
        #expect(machine.handle(.reset(.clear)) == [.cancelRecheck])
        #expect(machine.state == .terminal(.reading, .ready, .idle))
    }

    @Test func terminalAnswerHasAnExactGuardAndSameScreenStaysAnswered() {
        var machine = ChatApprovalMachine().after([.screenRead("Question")])
        #expect(machine.handle(.answerScreen) == [.checkScreen(1, shown: "Question")])
        #expect(machine.wantsScreenAnswer(1, shown: "Question"))
        #expect(!machine.wantsScreenAnswer(1, shown: "Another"))
        #expect(machine.handle(.answerScreen).isEmpty)
        #expect(machine.handle(.screenAnswered(1, .sent)) == [.cancelRecheck, .armRecheck(2)])
        _ = machine.handle(.screenRead("Question"))
        #expect(machine.isAnswering)
        #expect(machine.handle(.recheckElapsed(99)).isEmpty)
        #expect(machine.handle(.recheckElapsed(2)) == [.refreshScreen])
        #expect(machine.handle(.recheckElapsed(2)).isEmpty)
        _ = machine.handle(.screenRead(nil))
        #expect(machine.screenUnreadable && machine.isAnswering)
        _ = machine.handle(.screenRead("Another"))
        #expect(!machine.isAnswering && machine.screen == "Another")
        #expect(!machine.wantsScreenAnswer(1, shown: "Question"))
    }

    @Test(arguments: [BlockedPromptAnswerer.Outcome.cancelled, .sendFailed, .queued, .unreachable])
    func nonDeliveredTerminalAnswersReopenTheShownPrompt(outcome: BlockedPromptAnswerer.Outcome) {
        var machine = ChatApprovalMachine().after([.screenRead("Question"), .answerScreen])
        #expect(machine.handle(.screenAnswered(1, outcome)).isEmpty)
        #expect(!machine.isAnswering && machine.screen == "Question")
        #expect(machine.handle(.answerScreen) == [.checkScreen(2, shown: "Question")])
    }

    @Test(arguments: [BlockedPromptAnswerer.Outcome.abandoned, .busy, .refused])
    func terminalRefusalsKeepTheirExistingClaim(outcome: BlockedPromptAnswerer.Outcome) {
        var machine = ChatApprovalMachine().after([.screenRead("Question"), .answerScreen])
        #expect(machine.handle(.screenAnswered(1, outcome)).isEmpty)
        #expect(machine.isAnswering && machine.wantsScreenAnswer(1, shown: "Question"))
    }

    @Test(arguments: [nil, "Next question"] as [String?])
    func aChangedPromptIsShownButNotAnswered(current: String?) {
        var machine = ChatApprovalMachine().after([.screenRead("Question"), .answerScreen])
        _ = machine.handle(.screenAnswered(1, .promptChanged(current: current)))
        #expect(!machine.isAnswering && machine.screen == current)
        #expect(machine.screenUnreadable == (current == nil))
    }

    @Test func stopAndRestartInvalidateTheOldTerminalAnswerAndTimer() {
        var machine = ChatApprovalMachine().after([
            .screenRead("Question"), .answerScreen, .screenAnswered(1, .sent),
        ])
        #expect(machine.handle(.stop) == [.cancelRecheck])
        #expect(machine.isAnswering && machine.screen == "Question")
        #expect(!machine.wantsScreenAnswer(1, shown: "Question"))
        _ = machine.handle(.reset(.start))
        #expect(machine.screen == nil && !machine.isAnswering)
        _ = machine.handle([.screenRead("Question"), .answerScreen])
        #expect(machine.handle(.screenAnswered(1, .sent)).isEmpty)
        #expect(machine.handle(.recheckElapsed(2)).isEmpty)
        #expect(machine.wantsScreenAnswer(3, shown: "Question"))
        _ = machine.handle(.reset(.statusChanged))
        #expect(!machine.isAnswering && machine.screen == "Question")
    }

    @Test(arguments: [false, true])
    func aRecheckRetainedAfterADifferentScreenStillTestsWhetherAnAnswerIsActive(answeringNext: Bool) {
        var machine = ChatApprovalMachine().after([
            .screenRead("Question"), .answerScreen, .screenAnswered(1, .sent), .screenRead("Next"),
        ])
        if answeringNext { _ = machine.handle(.answerScreen) }
        #expect(machine.handle(.recheckElapsed(2)) == (answeringNext ? [.refreshScreen] : []))
        #expect(machine.isAnswering == answeringNext)
    }

    @Test func requestReadsRetainCardsOnFailureAndRetryKeepsThemUnreadableUntilRead() {
        var machine = ChatApprovalMachine(structured: true).after([.requestsRead([Self.command])])
        _ = machine.handle(.requestsRead(nil))
        #expect(machine.requests == [Self.command] && machine.requestsUnreadable)
        _ = machine.handle(.retry)
        #expect(machine.requests == [Self.command] && machine.requestsUnreadable)
        _ = machine.handle(.requestsRead([]))
        #expect(machine.requests.isEmpty && !machine.requestsUnreadable)
        #expect(machine.handle(.answerRequest(Self.command.id, .allow)).isEmpty)
    }

    @Test(arguments: [true, false])
    func structuredAnswersHoldTheirClaimThroughRefreshAndNeverReplay(resolved: Bool) {
        let answer = AgentRequestAnswer.answers(["q": ["Keep it"]])
        var machine = ChatApprovalMachine(structured: true).after([.requestsRead([Self.command, Self.form])])
        #expect(machine.handle(.answerRequest("form", answer)) == [.sendRequest(1, id: "form", answer: answer)])
        #expect(machine.isAnswering && !machine.requestAnswerFailed)
        #expect(machine.handle(.answerRequest(Self.command.id, .allow)).isEmpty)
        #expect(machine.handle(.requestAnswered(99, resolved: true)).isEmpty)
        #expect(machine.handle(.requestAnswered(1, resolved: resolved)) == [.refreshAfterRequest(1)])
        #expect(machine.requests == (resolved ? [Self.command] : [Self.command, Self.form]))
        #expect(machine.requestAnswerFailed == !resolved)
        #expect(machine.isAnswering)
        #expect(machine.handle(.answerRequest("form", answer)).isEmpty)
        _ = machine.handle(.requestsRead([Self.command])) // Re-list after resolution elsewhere.
        #expect(machine.handle(.requestRefreshed(99)).isEmpty)
        _ = machine.handle(.requestRefreshed(1))
        #expect(!machine.isAnswering && machine.requests == [Self.command])
        _ = machine.handle(.retry)
        #expect(!machine.requestAnswerFailed)
    }

    @Test func structuredRestartAndStatusChangesRejectOldCompletions() {
        var machine = ChatApprovalMachine(structured: true).after([
            .requestsRead([Self.command]), .answerRequest(Self.command.id, .allow), .stop,
        ])
        #expect(machine.isAnswering)
        _ = machine.handle(.reset(.start))
        #expect(!machine.isAnswering && machine.requests == [Self.command])
        #expect(machine.handle(.answerRequest(Self.command.id, .cancel)) == [.sendRequest(2, id: Self.command.id, answer: .cancel)])
        #expect(machine.handle(.requestAnswered(1, resolved: true)).isEmpty)
        _ = machine.handle(.reset(.statusChanged))
        #expect(machine.handle(.requestAnswered(2, resolved: false)).isEmpty)
        #expect(!machine.isAnswering && !machine.requestAnswerFailed)
        _ = machine.handle(.reset(.clear))
        #expect(machine.requests.isEmpty && !machine.requestsUnreadable)
    }

    @Test func modesIgnoreEachOthersEventsAndUnownedCompletions() {
        var terminal = ChatApprovalMachine()
        #expect(terminal.handle([
            .requestsRead([Self.command]), .answerRequest(Self.command.id, .allow),
            .requestAnswered(1, resolved: true), .requestRefreshed(1), .answerScreen,
            .screenAnswered(1, .sent), .recheckElapsed(1),
        ]).isEmpty)
        #expect(terminal.state == .terminal(.reading, .ready, .idle))
        var structured = ChatApprovalMachine(structured: true)
        #expect(structured.handle([
            .screenRead("Question"), .answerScreen, .screenAnswered(1, .sent), .recheckElapsed(1),
            .requestAnswered(1, resolved: true), .requestRefreshed(1),
        ]).isEmpty)
        #expect(structured.state == .structured(.known([]), .ready(failed: false)))
    }

    private static let command = AgentPendingRequest(id: "command", kind: .command(command: "pwd", cwd: nil, reason: nil))
    private static let form = AgentPendingRequest(id: "form", kind: .questions(.init(body: "", questions: [])))
}
