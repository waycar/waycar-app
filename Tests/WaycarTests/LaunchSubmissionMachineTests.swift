import Foundation
import Testing

@testable import Waycar

@Suite("New Agent submission transitions")
struct LaunchSubmissionMachineTests {
    private let id = ConsoleAgent.ID(hostID: UUID(), paneID: "pane")
    private let date = Date(timeIntervalSince1970: 1)

    @Test func progressIsOrderedDeduplicatedAndOnlyTheRunningStepFails() {
        var machine = LaunchSubmissionMachine().after([.submissionBegan, .preparing])
        #expect(machine.presentation == .starting)
        #expect(machine.handle(.launchBegan) == [.launch(1)])
        _ = machine.handle([
            .step(1, .creatingTab, date, title: "tab"),
            .step(1, .creatingTab, date, title: "duplicate"),
            .step(1, .startingAgent, date, title: "agent")
        ])
        #expect(machine.report.steps.map(\.status) == [.done, .running])
        #expect(machine.report.steps.map(\.title) == ["tab", "agent"])
        _ = machine.handle([.operationFailed(1), .launchFailed(1, "failed")])
        #expect(machine.report.steps.map(\.status) == [.done, .failed])
        #expect(machine.presentation == .failed("failed"))
        #expect(machine.handle(.resetFailure).isEmpty)
        #expect(machine.presentation == .editing && machine.report.steps.isEmpty)
    }

    @Test func startedMetadataQueueAndPreparationFailureKeepTheirExistingProjections() {
        var machine = LaunchSubmissionMachine().after([
            .submissionBegan, .keepsLaunch(false), .launchBegan,
            .started(1, id, .agent(.claude, chat: true))
        ])
        #expect(machine.presentation == .started(id))
        #expect(machine.report.launchedKind == .claude && machine.report.launchedChat)
        _ = machine.handle([.submissionBegan, .preparing, .failed("attachment")])
        #expect(machine.presentation == .failed("attachment"))
        // These describe the previous success until another one publishes.
        #expect(machine.report.launchedKind == .claude && machine.report.launchedChat)
        let launchID = UUID()
        _ = machine.handle([.keepsLaunch(true), .queued(launchID)])
        #expect(machine.presentation == .queued(launchID) && machine.report.keepsLaunch)
        _ = machine.handle([.submissionBegan, .launchBegan, .started(2, id, .shell)])
        #expect(!machine.report.launchedChat && machine.report.launchedKind == .claude)
        // Resetting a Host only clears a failure, not an in-flight or queued outcome.
        #expect(machine.handle(.resetFailure).isEmpty)
        #expect(machine.presentation == .started(id))
    }

    @Test func lateProgressAndCompletionCannotPublishForAnotherLaunch() {
        var machine = LaunchSubmissionMachine().after([.launchBegan, .launchBegan])
        _ = machine.handle([
            .step(1, .creatingTab, date, title: "old"), .operationFailed(1),
            .launchFailed(1, "old"), .started(1, id, .agent(.claude, chat: true))
        ])
        #expect(machine.presentation == .starting && machine.report.steps.isEmpty)
        #expect(machine.handle(.step(2, .opening, date, title: "open")).isEmpty)
        _ = machine.handle(.started(2, id, .agent(nil, chat: false)))
        #expect(machine.presentation == .started(id))
        #expect(machine.report.launchedKind == nil && !machine.report.launchedChat)
        _ = machine.handle([.editing, .failed("form"), .resetFailure])
        #expect(machine.presentation == .editing && machine.report.steps.isEmpty)
    }
}
