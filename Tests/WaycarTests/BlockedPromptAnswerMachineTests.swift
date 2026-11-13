import Testing

@testable import Waycar

@MainActor
@Suite("Blocked prompt answer machine")
struct BlockedPromptAnswerMachineTests {
    typealias Machine = BlockedPromptAnswerMachine

    private func request(
        kind: Machine.Kind = .answer, mode: Machine.Mode = .live(queuesOffline: false)
    ) -> Machine.Request {
        Machine.Request(
            pending: PendingBlockedAnswer(label: "Deny", keys: ["esc"], shown: "same", snapshot: nil),
            mode: mode, kind: kind)
    }

    private func read(_ token: UInt64 = 1, full: String? = "same") -> Machine.Event {
        .read(token, full: full, unreachable: false, stillWanted: true, cancelled: false)
    }

    @Test func matchingScreenThenClaimDispatchesExactlyOnce() {
        var machine = Machine()
        #expect(machine.handle(.begin(request())) == [.read(1)])
        #expect(machine.isActing)
        #expect(machine.handle(read()) == [.claim(1)])
        #expect(machine.handle(.claimed(1, true)) == [.sendKeys(1, ["esc"])])
        #expect(machine.handle(.claimed(1, true)) == [])
        #expect(machine.handle(.keysSent(1, succeeded: true)) == [.complete(1, .answer(.sent))])
        #expect(machine.isActing)
        #expect(machine.handle(.completed(1)) == [])
        #expect(!machine.isActing)
        #expect(machine.handle(.keysSent(1, succeeded: false)) == [])
    }

    @Test func changedOrBlankScreenDoesNotClaim() {
        for full in ["different", " \n", nil] {
            var machine = Machine().after([.begin(request())])
            #expect(machine.handle(read(full: full)) == [
                .complete(1, .answer(.promptChanged(current: full.flatMap(BlockedPromptAnswerer.screenText(from:))))),
            ])
        }
    }

    @Test func sameTextMustStillVerifyTheSavedClassification() throws {
        let full = BlockedPromptAnswererTests.permission
        let snapshot = try #require(BlockedPromptSnapshot(kind: "claude", fullScreen: full))
        let pending = PendingBlockedAnswer(
            label: "Allow", keys: ["enter"], shown: "same", snapshot: snapshot)
        var machine = Machine().after([.begin(.init(pending: pending, mode: .replay, kind: .answer))])
        #expect(machine.handle(read()) == [.complete(1, .answer(.promptChanged(current: "same")))])
    }

    @Test func unwantedTakesPriorityOverCancellationAndUnreachable() {
        var machine = Machine().after([.begin(request(mode: .replay))])
        #expect(machine.handle(.read(1, full: nil, unreachable: true, stillWanted: false, cancelled: true)) == [
            .complete(1, .answer(.abandoned)),
        ])
        machine = Machine().after([.begin(request())])
        #expect(machine.handle(.read(1, full: "same", unreachable: false, stillWanted: true, cancelled: true)) == [
            .complete(1, .answer(.cancelled)),
        ])
    }

    @Test func onlyOfflineLiveRequestsQueueAndReplaysRemainUnreachable() {
        let live = request(mode: .live(queuesOffline: true))
        var machine = Machine().after([.begin(live)])
        #expect(machine.handle(.read(1, full: nil, unreachable: true, stillWanted: true, cancelled: false)) == [
            .queue(live.pending), .complete(1, .answer(.queued)),
        ])
        machine = Machine().after([.begin(request(mode: .replay))])
        #expect(machine.handle(.read(1, full: nil, unreachable: true, stillWanted: true, cancelled: false)) == [
            .complete(1, .answer(.unreachable)),
        ])
        machine = Machine().after([.begin(request())])
        #expect(machine.handle(.read(1, full: nil, unreachable: true, stillWanted: true, cancelled: false)) == [
            .complete(1, .answer(.promptChanged(current: nil))),
        ])
    }

    @Test func rejectedClaimAndFailedSendNeverRetryKeys() {
        var machine = Machine().after([.begin(request()), read()])
        #expect(machine.handle(.claimed(1, false)) == [.complete(1, .answer(.abandoned))])
        machine = Machine().after([.begin(request()), read(), .claimed(1, true)])
        #expect(machine.handle(.keysSent(1, succeeded: false)) == [.complete(1, .answer(.sendFailed))])
        #expect(machine.handle([read(), .claimed(1, true)]) == [])
    }

    @Test func correctionWaitsAfterDenyThenPromptsOnce() {
        var machine = Machine().after([.begin(request(kind: .correction("fix"))), read(), .claimed(1, true)])
        #expect(machine.handle(.keysSent(1, succeeded: true)) == [.waitUnblocked(1)])
        #expect(machine.handle(.unblocked(1, true)) == [.prompt(1, "fix")])
        #expect(machine.handle(.prompted(1, .sent)) == [.complete(1, .correction(.prompted))])
    }

    @Test func correctionDenyFailureDoesNotPromptOrDraft() {
        var machine = Machine().after([.begin(request(kind: .correction("fix"))), read(), .claimed(1, true)])
        #expect(machine.handle(.keysSent(1, succeeded: false)) == [.complete(1, .correction(.denyFailed(.sendFailed)))])
        #expect(machine.handle(.unblocked(1, true)) == [])
    }

    @Test func blockedTimeoutOrAnUnsentRefusalDraftsTheCorrection() {
        var machine = Machine().after([
            .begin(request(kind: .correction("fix"))), read(), .claimed(1, true), .keysSent(1, succeeded: true),
        ])
        var refused = machine
        #expect(machine.handle(.unblocked(1, false)) == [.draft(1, "fix")])
        #expect(machine.handle(.drafted(1)) == [.complete(1, .correction(.drafted))])
        #expect(refused.handle(.unblocked(1, true)) == [.prompt(1, "fix")])
        #expect(refused.handle(.prompted(1, .refusedUnsent)) == [.draft(1, "fix")])
        #expect(refused.handle(.drafted(1)) == [.complete(1, .correction(.drafted))])
    }

    @Test func uncertainPromptIsNeverDraftedOrRetried() {
        var machine = Machine().after([
            .begin(request(kind: .correction("fix"))), read(), .claimed(1, true),
            .keysSent(1, succeeded: true), .unblocked(1, true),
        ])
        #expect(machine.handle(.prompted(1, .failed)) == [.complete(1, .correction(.promptFailed))])
        #expect(machine.handle([.unblocked(1, true), .prompted(1, .refusedUnsent)]) == [])
    }

    @Test func busyAdmissionDoesNotReleaseTheCurrentAction() {
        var machine = Machine().after([.begin(request())])
        let state = machine.state
        #expect(machine.handle(.begin(request())) == [.busy(.answer(.busy))])
        #expect(machine.handle(.begin(request(kind: .correction("fix")))) == [.busy(.correction(.denyFailed(.busy)))])
        #expect(machine.state == state)
    }

    @Test func staleCompletionsAreIgnoredAtEveryStageAndAfterRestart() {
        let stages = [
            Machine().after([.begin(request(kind: .correction("fix")))]),
            Machine().after([.begin(request(kind: .correction("fix"))), read()]),
            Machine().after([.begin(request(kind: .correction("fix"))), read(), .claimed(1, true)]),
            Machine().after([.begin(request(kind: .correction("fix"))), read(), .claimed(1, true), .keysSent(1, succeeded: true)]),
            Machine().after([.begin(request(kind: .correction("fix"))), read(), .claimed(1, true), .keysSent(1, succeeded: true), .unblocked(1, true)]),
            Machine().after([.begin(request(kind: .correction("fix"))), read(), .claimed(1, true), .keysSent(1, succeeded: true), .unblocked(1, false)]),
            Machine().after([.begin(request()), read(), .claimed(1, true), .keysSent(1, succeeded: true)]),
        ]
        for var machine in stages {
            let state = machine.state
            #expect(machine.handle([
                read(99), .claimed(99, true), .keysSent(99, succeeded: true), .unblocked(99, true),
                .prompted(99, .sent), .drafted(99), .completed(99),
            ]) == [])
            #expect(machine.state == state)
        }
        var machine = Machine().after([.begin(request()), read(), .claimed(1, true), .keysSent(1, succeeded: true), .completed(1)])
        #expect(machine.handle(.begin(request())) == [.read(2)])
        #expect(machine.handle([read(1), .completed(1)]) == [])
    }

    @Test func idleIgnoresCompletions() {
        var machine = Machine()
        #expect(machine.handle([read(), .claimed(1, true), .keysSent(1, succeeded: true), .unblocked(1, true), .drafted(1), .completed(1)]) == [])
    }
}
