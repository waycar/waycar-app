import Foundation
import Testing

@testable import Waycar

@Suite("Queued Launch machine")
struct QueuedLaunchMachineTests {
    private typealias Machine = QueuedLaunchMachine
    private typealias Recovery = QueuedLaunchMachine.Recovery

    private static let joined = Machine.StartedAgent(paneID: "w1:pnew", joinedRunningAgent: true)
    private static let unknown = Recovery()
    private static let checked = Recovery(startedAgent: nil, mayHaveStarted: true)
    private static let started = Recovery(startedAgent: joined, mayHaveStarted: false)

    private func machine(_ state: Machine.State) -> Machine { Machine(state: state) }

    @Test func restoreTurnsAStartingOrLegacyLaunchIntoAWaitingOneThatChecksItsTag() {
        for interrupted in [Machine.State.starting(Self.started), .uncertain(Self.started)] {
            var launch = machine(interrupted)
            #expect(launch.handle(.restored) == [.save])
            #expect(launch.state == .waiting(Recovery(startedAgent: Self.joined, mayHaveStarted: true)))
            #expect(launch.state.pendingHandover == Self.joined)
        }
        for settled in [Machine.State.waiting(Self.unknown), .failed("x", Self.started)] {
            var launch = machine(settled)
            #expect(launch.handle(.restored).isEmpty)
            #expect(launch.state == settled)
        }
    }

    @Test func messagesNotKeptFailsTheLaunchFromAnyStateKeepingItsRecovery() {
        let states: [Machine.State] = [
            .waiting(Self.started), .starting(Self.checked), .failed("x", Self.unknown),
            .uncertain(Self.started),
        ]
        for state in states {
            var launch = machine(state)
            #expect(launch.handle(.messagesNotKept) == [.save])
            #expect(launch.state == .failed(Machine.messagesNotKeptMessage, state.recovery))
        }
    }

    @Test func onlyAFailedLaunchRetriesAndItWaitsWithItsRecovery() {
        var failed = machine(.failed("x", Self.started))
        #expect(failed.handle(.retry) == [.save, .drain])
        #expect(failed.state == .waiting(Self.started))
        for state in [Machine.State.waiting(Self.unknown), .starting(Self.started), .uncertain(Self.checked)] {
            var launch = machine(state)
            #expect(launch.handle(.retry).isEmpty)
            #expect(launch.state == state)
        }
    }

    @Test func onlyAWaitingLaunchDispatchesAndItIsSavedStartingFirst() {
        var waiting = machine(.waiting(Self.checked))
        #expect(waiting.handle(.dispatching) == [.save])
        #expect(waiting.state == .starting(Self.checked))
        #expect(waiting.state.isStarting)
        for state in [Machine.State.starting(Self.unknown), .failed("x", Self.unknown), .uncertain(Self.unknown)] {
            var launch = machine(state)
            #expect(launch.handle(.dispatching).isEmpty)
            #expect(launch.state == state)
        }
    }

    @Test func theReportedAgentIsRecordedAndHoldsItsPaneWhateverThePhase() {
        let states: [Machine.State] = [
            .starting(Self.checked), .waiting(Self.unknown), .failed("x", Self.unknown),
            .uncertain(Self.unknown),
        ]
        for state in states {
            var launch = machine(state)
            #expect(
                launch.handle(.agentStarted(paneID: "w1:pnew", joinedRunningAgent: false))
                    == [.save, .holdRecipient(paneID: "w1:pnew")])
            let agent = Machine.StartedAgent(paneID: "w1:pnew", joinedRunningAgent: false)
            #expect(launch.state.pendingHandover == agent)
            #expect(launch.state.awaitsReplay == state.awaitsReplay)
            #expect(launch.state.isStarting == state.isStarting)
        }
    }

    @Test func aStartedAnswerRecordsTheAgentAndHandsOver() {
        var launch = machine(.starting(Self.checked))
        #expect(
            launch.handle(.started(paneID: "w1:pnew", joinedRunningAgent: nil))
                == [.save, .handOver(paneID: "w1:pnew")])
        let agent = Machine.StartedAgent(paneID: "w1:pnew", joinedRunningAgent: nil)
        #expect(launch.state == .starting(Recovery(startedAgent: agent, mayHaveStarted: true)))
        #expect(launch.handle(.handoverFailed) == [.save])
        #expect(
            launch.state
                == .failed(Machine.handoverFailedMessage, Recovery(startedAgent: agent, mayHaveStarted: true)))
        #expect(launch.state.letsNextReplayGo)
    }

    @Test func theOtherAnswersSettleAStartingLaunch() {
        var notSent = machine(.starting(Self.unknown))
        #expect(notSent.handle(.notSent) == [.save])
        #expect(notSent.state == .waiting(Self.unknown))
        #expect(!notSent.state.letsNextReplayGo)

        var lost = machine(.starting(Recovery(startedAgent: nil, mayHaveStarted: false)))
        #expect(lost.handle(.answerLost) == [.save])
        #expect(lost.state == .waiting(Self.checked))
        #expect(!lost.state.letsNextReplayGo)

        var refused = machine(.starting(Self.started))
        #expect(refused.handle(.refused("No start")) == [.save])
        #expect(refused.state == .failed("No start", Self.started))
        #expect(refused.state.letsNextReplayGo)
    }

    @Test func answersOutsideAReplayAreIgnored() {
        let answers: [Machine.Event] = [
            .started(paneID: "w1:p", joinedRunningAgent: nil), .handoverFailed, .notSent,
            .answerLost, .refused("x"),
        ]
        for state in [Machine.State.waiting(Self.unknown), .failed("x", Self.checked), .uncertain(Self.unknown)] {
            for answer in answers {
                var launch = machine(state)
                #expect(launch.handle(answer).isEmpty)
                #expect(launch.state == state)
            }
        }
    }

    @Test func derivedValues() {
        #expect(Machine.State.waiting(Self.unknown).awaitsReplay)
        #expect(!Machine.State.uncertain(Self.unknown).awaitsReplay)
        #expect(!Machine.State.failed("x", Self.unknown).isStarting)
        #expect(Machine.State.starting(Self.unknown).letsNextReplayGo)
        #expect(!Machine.State.uncertain(Self.unknown).letsNextReplayGo)
        #expect(Machine.State.starting(Self.started).recovery == Self.started)
    }

    /// Every combination of the record's fields maps to a state and back
    /// unchanged, nil versus false and a stray `joinedRunningAgent` included.
    @Test func everyRecordMapsToItsStateAndBackUnchanged() {
        let draft = LaunchDraft(
            id: UUID(), hostID: UUID(),
            dispatch: .init(destination: .existingWorkspace, launch: .agent(.claude), backend: .herdr),
            workspaceID: "w1", originCwd: nil, name: nil, suggestedName: nil, userArguments: [],
            chatMode: false, presetFirstMessage: nil, firstMessage: nil, remembersLaunch: true,
            isQuickChat: false)
        let phases: [QueuedLaunch.State] = [.waiting, .starting, .uncertain, .failed("x")]
        let flags: [Bool?] = [nil, false, true]
        for phase in phases {
            for pane in [nil, "w1:pnew"] as [String?] {
                for joined in flags {
                    for mayHaveStarted in flags {
                        var record = QueuedLaunch(draft: draft, state: phase, createdAt: Date())
                        record.startedPaneID = pane
                        record.joinedRunningAgent = joined
                        record.mayHaveStarted = mayHaveStarted
                        var mapped = record
                        mapped.lifecycle = record.lifecycle
                        #expect(mapped == record)
                        #expect(record.lifecycle.recovery.mayHaveStarted == mayHaveStarted)
                        #expect(record.lifecycle.pendingHandover?.paneID == pane)
                    }
                }
            }
        }
    }

    /// The record's own `handle` writes the machine's new state back.
    @Test func aRecordFeedsItsMachine() {
        let draft = LaunchDraft(
            id: UUID(), hostID: UUID(),
            dispatch: .init(destination: .existingWorkspace, launch: .agent(.claude), backend: .herdr),
            workspaceID: "w1", originCwd: nil, name: nil, suggestedName: nil, userArguments: [],
            chatMode: false, presetFirstMessage: nil, firstMessage: nil, remembersLaunch: true,
            isQuickChat: false)
        var record = QueuedLaunch(draft: draft, state: .starting, createdAt: Date())
        #expect(record.handle(.agentStarted(paneID: "w1:pnew", joinedRunningAgent: true))
            == [.save, .holdRecipient(paneID: "w1:pnew")])
        #expect(record.startedPaneID == "w1:pnew")
        #expect(record.joinedRunningAgent == true)
        #expect(record.handle(.restored) == [.save])
        #expect(record.state == .waiting)
        #expect(record.mayHaveStarted == true)
        #expect(record.startedPaneID == "w1:pnew")
    }
}
