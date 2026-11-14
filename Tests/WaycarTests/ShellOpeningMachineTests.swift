import Foundation
import Testing

@testable import Waycar

@Suite("Shell opening machine")
struct ShellOpeningMachineTests {
    typealias Machine = ShellOpeningMachine
    private static let host = UUID()
    private static let token = UUID()
    private static let request = ShellTerminalCreationRequest(workspaceID: "w1", cwd: "/work")
    private static let identity = ShellTerminalIdentity(paneID: "w1:p9", tabID: "w1:t9", terminalID: "t9")
    private static let row = ConsoleAgent.ID(hostID: host, paneID: "w1:p9")
    private static let shellA = ConsoleAgent.ID(hostID: host, paneID: "w1:pA")
    private static let shellB = ConsoleAgent.ID(hostID: host, paneID: "w1:pB")

    private static func open(
        shells: [ConsoleAgent.ID] = [], request: ShellTerminalCreationRequest? = request,
        sample: Bool = false, token: UUID? = token
    ) -> Machine.Event {
        .openTapped(handoffToken: token, shells: shells, request: request, runsSample: sample)
    }

    @Test func oneShellOpensAndSeveralAskWhich() {
        var one = Machine()
        #expect(one.handle(Self.open(shells: [Self.shellA])) == [.openShell(Self.shellA, handoffToken: Self.token)])
        var several = Machine()
        #expect(several.handle(Self.open(shells: [Self.shellA, Self.shellB])) == [.presentChooser])
        #expect(several.handle(.shellChosen(Self.shellB)) == [.openShell(Self.shellB, handoffToken: Self.token)])
        var cancelled = Machine().after([Self.open(shells: [Self.shellA, Self.shellB])])
        #expect(cancelled.handle(.chooserCancelled) == [.cancelShellHandoff(Self.token)])
    }

    @Test func noShellCreatesOneAndWaitsForItsRow() {
        var machine = Machine()
        #expect(machine.handle(Self.open()) == [.startAttempt(attempt: 1, .create(attempt: 1, Self.request))])
        #expect(machine.isResolving)
        #expect(machine.handle(.created(attempt: 1, Self.identity, row: Self.row))
            == [.continueAttempt(.awaitRow(attempt: 1, Self.row))])
        #expect(machine.state.created == .init(identity: Self.identity, row: Self.row))
        #expect(machine.handle(.rowAwaited(attempt: 1, found: true, visible: true))
            == [.openShell(Self.row, handoffToken: Self.token)])
        #expect(machine.isResolving)
        #expect(machine.handle(.attemptFinished(attempt: 1)) == [])
        #expect(!machine.isResolving)
    }

    @Test func aRowThatLeftTheDetailBehindReleasesTheHandoff() {
        var machine = Machine().after([Self.open(), .created(attempt: 1, Self.identity, row: Self.row)])
        #expect(machine.handle(.rowAwaited(attempt: 1, found: true, visible: false))
            == [.cancelShellHandoff(Self.token)])
    }

    @Test func aMissingRowIsReportedAndTheTerminalIsRememberedForARetry() {
        var machine = Machine().after([Self.open(), .created(attempt: 1, Self.identity, row: Self.row)])
        #expect(machine.handle(.rowAwaited(attempt: 1, found: false, visible: false))
            == [.cancelShellHandoff(Self.token), .presentFailure(Machine.rowNotRefreshedMessage)])
        _ = machine.handle(.attemptFinished(attempt: 1))
        let retry = UUID()
        // The remembered terminal wins over the Workspace's shells.
        #expect(machine.handle(Self.open(shells: [Self.shellA], token: retry))
            == [.startAttempt(attempt: 2, .refresh(attempt: 2))])
        #expect(machine.handle(.refreshed(attempt: 2)) == [.continueAttempt(.awaitRow(attempt: 2, Self.row))])
        #expect(machine.handle(.rowAwaited(attempt: 2, found: true, visible: true))
            == [.openShell(Self.row, handoffToken: retry)])
    }

    @Test func aFailedCreationReportsAndReleasesItsOwnToken() {
        var machine = Machine().after([Self.open()])
        #expect(machine.handle(.creationFailed(attempt: 1, message: "no"))
            == [.cancelShellHandoff(Self.token), .presentFailure("no")])
        #expect(machine.state.created == nil)
        _ = machine.handle(.attemptFinished(attempt: 1))
        #expect(machine.handle(Self.open()) == [.startAttempt(attempt: 2, .create(attempt: 2, Self.request))])
    }

    @Test func aTapWhileResolvingGivesOnlyItsOwnTokenBack() {
        let later = UUID()
        var machine = Machine().after([Self.open()])
        #expect(machine.handle(Self.open(token: later)) == [.cancelShellHandoff(later)])
        // The running attempt keeps the token it started with.
        _ = machine.handle(.created(attempt: 1, Self.identity, row: Self.row))
        #expect(machine.handle(.rowAwaited(attempt: 1, found: true, visible: true))
            == [.openShell(Self.row, handoffToken: Self.token)])
    }

    @Test func noRequestOrASampleCreatesNothing() {
        var unavailable = Machine()
        #expect(unavailable.handle(Self.open(request: nil)) == [.cancelShellHandoff(Self.token)])
        #expect(!unavailable.isResolving)
        var sample = Machine()
        #expect(sample.handle(Self.open(sample: true)) == [.cancelShellHandoff(Self.token), .connectSample])
        var fromChooser = Machine().after([Self.open(shells: [Self.shellA, Self.shellB])])
        #expect(fromChooser.handle(.createRequested(request: Self.request, runsSample: false))
            == [.startAttempt(attempt: 1, .create(attempt: 1, Self.request))])
    }

    @Test func eventsOfAnotherAttemptAreIgnored() {
        var machine = Machine().after([Self.open()])
        #expect(machine.handle(.created(attempt: 7, Self.identity, row: Self.row)) == [])
        #expect(machine.handle(.creationFailed(attempt: 7, message: "x")) == [])
        #expect(machine.handle(.refreshed(attempt: 1)) == [])
        #expect(machine.handle(.rowAwaited(attempt: 1, found: true, visible: true)) == [])
        #expect(machine.handle(.attemptFinished(attempt: 7)) == [])
        #expect(machine.isResolving)
    }
}
