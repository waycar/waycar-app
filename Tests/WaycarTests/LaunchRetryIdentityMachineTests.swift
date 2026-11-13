import Foundation
import Testing

@testable import Waycar

@Suite("Launch retry identity machine")
struct LaunchRetryIdentityMachineTests {
    private let inputs = LaunchRetryIdentityMachine.Inputs(
        hostID: UUID(), workspaceID: "w1", base: .latestDefaultBranch)

    @Test func aFreshFormMintsAndARetryWithTheSameInputsReusesIt() {
        var machine = LaunchRetryIdentityMachine()
        #expect(machine.handle(.branchNeeded(inputs)) == [.mint])
        #expect(machine.state == .fresh)
        #expect(machine.handle(.minted("worktree/a", inputs: inputs)).isEmpty)
        #expect(machine.state == .retrying(branch: "worktree/a", inputs: inputs))
        #expect(machine.handle(.branchNeeded(inputs)) == [.reuse("worktree/a")])
        #expect(machine.handle(.branchNeeded(inputs)) == [.reuse("worktree/a")])
    }

    @Test func otherInputsMintAndReplaceTheKeptBranch() {
        let changes = [
            LaunchRetryIdentityMachine.Inputs(hostID: UUID(), workspaceID: "w1", base: inputs.base),
            .init(hostID: inputs.hostID, workspaceID: "w2", base: inputs.base),
            .init(hostID: inputs.hostID, workspaceID: "w1", base: .sourceHead),
        ]
        for other in changes {
            var machine = LaunchRetryIdentityMachine().after([.minted("worktree/a", inputs: inputs)])
            #expect(machine.handle(.branchNeeded(other)) == [.mint])
            #expect(machine.state == .retrying(branch: "worktree/a", inputs: inputs))
            _ = machine.handle(.minted("worktree/b", inputs: other))
            #expect(machine.handle(.branchNeeded(inputs)) == [.mint])
            #expect(machine.handle(.branchNeeded(other)) == [.reuse("worktree/b")])
        }
    }

    // MARK: B-40: an OpenCode session is finished, not duplicated

    private let session = LaunchRetryIdentityMachine.SessionInputs(
        hostID: UUID(),
        dispatch: .init(destination: .newWorkspace(NewWorkspaceSpec(directory: "/work/app", label: nil)),
                        launch: .agent(.opencode), backend: .opencode),
        workspaceID: nil, originCwd: nil, name: "review", suggestedName: nil, chatMode: true)

    @Test func aFirstOpenCodeTryMintsItsOwnSession() {
        var machine = LaunchRetryIdentityMachine()
        #expect(machine.handle(.openCodeSessionNeeded(session)).isEmpty)
        #expect(machine.state == .fresh)
    }

    @Test func aFailedOpenCodeTrysRetryFinishesTheSameSession() {
        var machine = LaunchRetryIdentityMachine()
        #expect(machine.handle(.openCodeLaunchFailed(sessionID: "ses_a", launchName: "review", inputs: session)).isEmpty)
        #expect(machine.state == .retryingOpenCodeSession(sessionID: "ses_a", launchName: "review", inputs: session))
        #expect(machine.handle(.openCodeSessionNeeded(session))
            == [.reuseOpenCodeSession(sessionID: "ses_a", launchName: "review")])
        // It fails again: still the same session.
        _ = machine.handle(.openCodeLaunchFailed(sessionID: "ses_a", launchName: "review", inputs: session))
        #expect(machine.handle(.openCodeSessionNeeded(session))
            == [.reuseOpenCodeSession(sessionID: "ses_a", launchName: "review")])
        // A branch is never reused from an OpenCode session.
        #expect(machine.handle(.branchNeeded(inputs)) == [.mint])
    }

    @Test func aRetryWithOtherInputsIsANewSession() {
        let other = LaunchRetryIdentityMachine.SessionInputs(
            hostID: session.hostID,
            dispatch: .init(destination: .newWorkspace(NewWorkspaceSpec(directory: "/work/other", label: nil)),
                            launch: .agent(.opencode), backend: .opencode),
            workspaceID: nil, originCwd: nil, name: "review", suggestedName: nil, chatMode: true)
        var machine = LaunchRetryIdentityMachine().after([
            .openCodeLaunchFailed(sessionID: "ses_a", launchName: "review", inputs: session),
        ])
        #expect(machine.handle(.openCodeSessionNeeded(other)).isEmpty)
        _ = machine.handle(.openCodeLaunchFailed(sessionID: "ses_b", launchName: "review", inputs: other))
        #expect(machine.handle(.openCodeSessionNeeded(session)).isEmpty)
    }

    @Test(arguments: [LaunchRetryIdentityMachine.Event.launchStarted, .launchKept])
    func aStartedOrKeptOpenCodeLaunchEndsTheRetry(_ end: LaunchRetryIdentityMachine.Event) {
        var machine = LaunchRetryIdentityMachine().after([
            .openCodeLaunchFailed(sessionID: "ses_a", launchName: "review", inputs: session),
        ])
        #expect(machine.handle(end).isEmpty)
        #expect(machine.state == .fresh)
        #expect(machine.handle(.openCodeSessionNeeded(session)).isEmpty)
    }

    @Test(arguments: [LaunchRetryIdentityMachine.Event.launchStarted, .launchKept])
    func aStartedOrKeptLaunchEndsTheRetry(_ end: LaunchRetryIdentityMachine.Event) {
        var machine = LaunchRetryIdentityMachine().after([.minted("worktree/a", inputs: inputs)])
        #expect(machine.handle(end).isEmpty)
        #expect(machine.state == .fresh)
        #expect(machine.handle(.branchNeeded(inputs)) == [.mint])
        var fresh = LaunchRetryIdentityMachine()
        #expect(fresh.handle(end).isEmpty)
        #expect(fresh.state == .fresh)
    }
}
