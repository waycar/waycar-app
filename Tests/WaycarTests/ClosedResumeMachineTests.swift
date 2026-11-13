import Foundation
import Testing

@testable import Waycar

@Suite("Closed resume machine")
struct ClosedResumeMachineTests {
    private let host = UUID()
    private var agent: ConsoleAgent.ID { ConsoleAgent.ID(hostID: host, paneID: "p1") }
    private var other: ConsoleAgent.ID { ConsoleAgent.ID(hostID: host, paneID: "p2") }

    private func began(_ id: ConsoleAgent.ID? = nil, record: String = "r", at: Int64 = 10) -> ClosedResumeMachine.Event {
        .began(id ?? agent, record: record, beganAt: at, terminal: "t", backend: .herdr)
    }

    private func row(terminal: String) -> ConsoleAgent {
        ConsoleAgent(
            hostID: host, hostName: "Host",
            agent: Agent(
                terminalID: terminal, kind: "claude", title: "Task", status: .idle,
                workspaceID: "w1", tabID: "t1", paneID: "p1", cwd: "/repo", revision: 1),
            workspaceLabel: "repo", repositoryCheckout: nil)
    }

    private func project(_ listing: ClosedResumeMachine.Listing?) -> ClosedResumeMachine.Effect {
        .project(agent, listing)
    }

    private func project(
        _ id: ConsoleAgent.ID, _ listing: ClosedResumeMachine.Listing?
    ) -> ClosedResumeMachine.Effect {
        .project(id, listing)
    }

    private func phase(_ machine: ClosedResumeMachine, _ id: ConsoleAgent.ID? = nil) -> ClosedResumeMachine.Phase? {
        machine.state.resumes[id ?? agent]?.phase
    }

    @Test func aResumeBeginsPendingAndReplacesAnyBefore() {
        var machine = ClosedResumeMachine()
        #expect(machine.handle(began()) == [project(.pending("r", beganAt: 10)), .persist])
        #expect(phase(machine) == .pending(beganAt: 10))
        #expect(machine.state.resumes[agent]?.token == 1)
        _ = machine.handle(.backOutRequested(agent))
        #expect(machine.handle(began(record: "s", at: 20)) == [project(.pending("s", beganAt: 20)), .persist])
        // The same listing again changes no projection.
        #expect(machine.handle(began(record: "s", at: 20)) == [.persist])
        #expect(machine.state.resumes[agent]?.token == 3)
        _ = machine.handle(began(record: "s", at: 20))
        #expect(machine.state.resumes[agent] == .init(
            token: 4, record: "s", phase: .pending(beganAt: 20),
            terminal: .init(id: "t", backend: .herdr)))
    }

    @Test(arguments: [
        (ClosedResumeMachine.Record.gone, ClosedResumeMachine.Effect.persist, nil as ClosedResumeMachine.Phase?),
        (.withSession, .persist, .used),
        (.sessionless, .forget("r"), nil),
    ])
    func inputResolvesAPendingResumeByItsRecord(
        record: ClosedResumeMachine.Record, effect: ClosedResumeMachine.Effect,
        after: ClosedResumeMachine.Phase?
    ) {
        var machine = ClosedResumeMachine().after([began()])
        let listing: ClosedResumeMachine.Listing? = after == .used ? .used("r") : nil
        #expect(machine.handle(.inputSent(agent, record)) == [project(listing), effect])
        #expect(phase(machine) == after)
    }

    @Test func inputToAnythingButAPendingResumeDoesNothing() {
        var machine = ClosedResumeMachine()
        #expect(machine.handle(.inputSent(agent, .withSession)).isEmpty)
        machine = machine.after([began(), .backOutRequested(agent)])
        #expect(machine.handle(.inputSent(agent, .withSession)).isEmpty)
        #expect(phase(machine) == .backingOut(beganAt: 10, forgotten: false))
    }

    @Test func useElsewhereOfAResumeEndedInTheSamePassWritesOnlyForAGoneRecord() {
        var machine = ClosedResumeMachine().after([began()])
        #expect(machine.handle(.usedElsewhere(agent, record: "r", .withSession)) == [project(.used("r")), .persist])
        #expect(phase(machine) == .used)
        #expect(machine.handle(.usedElsewhere(other, record: "r", .gone)) == [.persist])
        #expect(machine.handle(.usedElsewhere(other, record: "r", .withSession)).isEmpty)
        #expect(phase(machine) == .used)
    }

    @Test func aBackOutVerifiesThenClosesAnUnusedRow() {
        var machine = ClosedResumeMachine().after([began()])
        #expect(machine.handle(.backOutRequested(agent)) == [project(.backedOut("r")), .persist, .verify(1)])
        #expect(machine.handle(.backOutRequested(agent)).isEmpty)
        #expect(machine.handle(.verified(agent, token: 1, terminalID: "t", isShell: false, .unused)) == [.close(1)])
        #expect(phase(machine) == .backingOut(beganAt: 10, forgotten: false))
    }

    @Test func aBackOutOfAnotherTerminalOrAShellEndsTheResume() {
        for (terminal, shell) in [("x", false), ("t", true)] {
            var machine = ClosedResumeMachine().after([began(), .backOutRequested(agent)])
            #expect(machine.handle(.verified(agent, token: 1, terminalID: terminal, isShell: shell, .unused)) == [project(nil), .persist])
            #expect(machine.state.resumes.isEmpty)
        }
    }

    @Test func aBusyRowIsUsed() {
        var machine = ClosedResumeMachine().after([began(), .backOutRequested(agent)])
        #expect(machine.handle(.verified(agent, token: 1, terminalID: "t", isShell: false, .busy(.withSession))) == [project(.used("r")), .persist])
        #expect(phase(machine) == .used)
    }

    @Test func aStaleTokenAnswersNothing() {
        var machine = ClosedResumeMachine().after([began(), .backOutRequested(agent), began()])
        let before = machine.state
        #expect(machine.handle(.verified(agent, token: 1, terminalID: "t", isShell: false, .unused)).isEmpty)
        #expect(machine.handle(.backOutFailed(agent, token: 1, .other(.withSession))).isEmpty)
        #expect(machine.handle(.backOutFailed(agent, token: 1, .notVerified(.withSession))).isEmpty)
        #expect(machine.state == before)
        // The right token on a resume that is no longer backing out, too.
        #expect(machine.handle(.verified(agent, token: 2, terminalID: "t", isShell: false, .unused)).isEmpty)
    }

    @Test func notVerifiedGoesBackToPendingUnlessForgottenOrGone() {
        var machine = ClosedResumeMachine().after([began(), .backOutRequested(agent)])
        #expect(machine.handle(.backOutFailed(agent, token: 1, .notVerified(.withSession))) == [project(.pending("r", beganAt: 10)), .persist])
        #expect(phase(machine) == .pending(beganAt: 10))
        #expect(machine.handle(.backOutRequested(agent)) == [project(.backedOut("r")), .persist, .verify(1)])
        #expect(machine.handle(.backOutFailed(agent, token: 1, .notVerified(.gone))) == [project(nil), .persist])
        #expect(machine.state.resumes.isEmpty)

        machine = ClosedResumeMachine().after([began(), .backOutRequested(agent), .forgotten(["r": 5])])
        #expect(machine.handle(.backOutFailed(agent, token: 1, .notVerified(.withSession))) == [project(nil), .persist])
        #expect(machine.state.resumes.isEmpty)
    }

    @Test func anyOtherFailureUsesTheResume() {
        var machine = ClosedResumeMachine().after([began(), .backOutRequested(agent)])
        #expect(machine.handle(.backOutFailed(agent, token: 1, .other(.sessionless))) == [project(nil), .forget("r")])
        #expect(machine.state.resumes.isEmpty)
    }

    @Test func aCaptureEndsTheResumeAndSaysWhoseClosureItIs() {
        var machine = ClosedResumeMachine().after([began()])
        #expect(machine.handle(.captured(agent)) == [project(nil), .captureIsResume("r", wasPending: true)])
        machine = machine.after([began(), .backOutRequested(agent)])
        #expect(machine.handle(.captured(agent)) == [project(nil), .captureIsResume("r", wasPending: false)])
        machine = machine.after([began(), .backOutRequested(agent), .forgotten(["r": 1])])
        #expect(machine.handle(.captured(agent)) == [project(nil), .dropCapture])
        machine = machine.after([began(), .inputSent(agent, .withSession)])
        #expect(machine.handle(.captured(agent)) == [project(nil)])
        #expect(machine.state.resumes.isEmpty)
        #expect(machine.handle(.captured(agent)).isEmpty)
    }

    @Test func verifiedSnapshotsMarkTheTerminalSeenAndEndItOnceGoneOrReplaced() {
        var machine = ClosedResumeMachine().after([began()])
        #expect(machine.handle(.verifiedSnapshot(host, .herdr, rows: [:])).isEmpty)
        #expect(machine.state.resumes[agent]?.terminal.seen == false)
        #expect(machine.handle(.verifiedSnapshot(UUID(), .herdr, rows: [:])).isEmpty)
        #expect(machine.handle(.verifiedSnapshot(host, .tmux, rows: ["p1": row(terminal: "x")])).isEmpty)
        #expect(machine.handle(.verifiedSnapshot(host, .herdr, rows: ["p1": row(terminal: "t")])).isEmpty)
        #expect(machine.state.resumes[agent]?.terminal.seen == true)
        #expect(machine.handle(.verifiedSnapshot(host, .herdr, rows: [:])) == [project(nil), .persist])
        #expect(machine.state.resumes.isEmpty)

        // Ending a resume that is not pending writes nothing.
        machine = machine.after([began(), .backOutRequested(agent)])
        #expect(machine.handle(.verifiedSnapshot(host, .herdr, rows: ["p1": row(terminal: "x")])) == [project(nil)])
        #expect(machine.state.resumes.isEmpty)
    }

    @Test func listingEndsOnlyUsedResumesOfUnlistedRows() {
        var machine = ClosedResumeMachine().after([
            began(), .inputSent(agent, .withSession), began(other),
        ])
        #expect(machine.handle(.listed([])) == [project(nil)])
        #expect(phase(machine) == nil)
        #expect(phase(machine, other) == .pending(beganAt: 10))
    }

    @Test func forgettingEndsPendingAndUsedResumesAndMarksBackOuts() {
        var machine = ClosedResumeMachine().after([
            began(), .inputSent(agent, .withSession), began(other), began(ConsoleAgent.ID(hostID: host, paneID: "p3")),
            .backOutRequested(ConsoleAgent.ID(hostID: host, paneID: "p3")), began(ConsoleAgent.ID(hostID: host, paneID: "p4"), record: "kept"),
        ])
        let p3 = ConsoleAgent.ID(hostID: host, paneID: "p3")
        // A forgotten back-out keeps its listing: only the pending and used
        // rows change, in no promised order.
        let effects = machine.handle(.forgotten(["r": 1]))
        #expect(effects.count == 2)
        #expect(effects.contains(project(nil)) && effects.contains(project(other, nil)))
        #expect(machine.state.resumes[p3]?.listing == .backedOut("r"))
        #expect(phase(machine) == nil)
        #expect(phase(machine, other) == nil)
        #expect(phase(machine, ConsoleAgent.ID(hostID: host, paneID: "p3")) == .backingOut(beganAt: 10, forgotten: true))
        #expect(phase(machine, ConsoleAgent.ID(hostID: host, paneID: "p4")) == .pending(beganAt: 10))
    }
}
