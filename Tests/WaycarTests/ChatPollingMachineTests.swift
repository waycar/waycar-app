import Foundation
import Testing

@testable import Waycar

@Suite("Chat polling machine")
struct ChatPollingMachineTests {
    @Test func demandStartsExactlyOneLoopAndIdleOrStopCancelsItsToken() {
        var machine = ChatPollingMachine()
        #expect(machine.handle(.configure(started: false, status: .working, turnOpen: false)).isEmpty)
        #expect(machine.handle(.configure(started: true, status: .idle, turnOpen: false)).isEmpty)
        #expect(machine.state == .quiescent)
        #expect(machine.handle(.configure(started: true, status: .working, turnOpen: false)) == [.start(1)])
        #expect(machine.handle(.configure(started: true, status: .working, turnOpen: true)).isEmpty)
        #expect(machine.handle(.configure(started: true, status: .idle, turnOpen: false)) == [.cancel(1)])
        #expect(machine.handle(.configure(started: true, status: .idle, turnOpen: true)) == [.start(2)])
        #expect(machine.handle(.stop) == [.cancel(2)])
        #expect(machine.handle(.stop).isEmpty)
        #expect(machine.pollToken == nil)
    }

    @Test func blockedPollsOnlyTheScreenUnlessThereIsAnOpenTurn() {
        let now = ContinuousClock.now
        var machine = ChatPollingMachine().after([.configure(started: true, status: .blocked, turnOpen: false)])
        #expect(machine.handle(.tick(1, now: now, status: .blocked, turnOpen: false)) == [.poll(readTranscript: false)])
        #expect(machine.handle(.tick(1, now: now, status: .blocked, turnOpen: true)) == [.poll(readTranscript: true)])
        #expect(machine.handle(.tick(1, now: now, status: .working, turnOpen: false)) == [.poll(readTranscript: true)])
        #expect(machine.handle(.tick(1, now: now, status: .idle, turnOpen: false)) == [.cancel(1)])
        #expect(machine.handle(.tick(1, now: now, status: .working, turnOpen: false)).isEmpty)
    }

    @Test func localFollowExpiresAtItsDeadlineAndNeverOnAClockReadInsideTheMachine() {
        let now = ContinuousClock.now
        var machine = ChatPollingMachine()
        #expect(machine.handle(.follow(deadline: now + .seconds(100), knownAssistantIDs: ["old"],
                                       started: true, status: .idle, turnOpen: false)) == [.start(1)])
        #expect(machine.handle(.tick(1, now: now + .seconds(99), status: .idle, turnOpen: false)) == [.poll(readTranscript: true)])
        #expect(machine.handle(.tick(1, now: now + .seconds(100), status: .idle, turnOpen: false)) == [.cancel(1)])
        #expect(machine.state == .quiescent)
    }

    @Test func anOldAssistantOrANewUserIsNotTheLocalReplyAndARepeatedSendReplacesTheBaseline() {
        let now = ContinuousClock.now
        var machine = ChatPollingMachine().after([
            .follow(deadline: now + .seconds(100), knownAssistantIDs: ["old"],
                    started: true, status: .idle, turnOpen: false),
        ])
        _ = machine.handle(.messagesChanged([Self.message("old", .assistant), Self.message("new-user", .user)]))
        #expect(machine.handle(.tick(1, now: now, status: .idle, turnOpen: false)) == [.poll(readTranscript: true)])
        #expect(machine.handle(.follow(deadline: now + .seconds(200), knownAssistantIDs: ["old", "a2"],
                                       started: true, status: .idle, turnOpen: false)).isEmpty)
        _ = machine.handle(.messagesChanged([Self.message("a2", .assistant)]))
        #expect(machine.handle(.tick(1, now: now + .seconds(100), status: .idle, turnOpen: false)) == [.poll(readTranscript: true)])
        _ = machine.handle(.messagesChanged([Self.message("a3", .assistant)]))
        // Demand is reconciled by read-loop completion, not by publishing bubbles.
        #expect(machine.pollToken == 1)
        #expect(machine.handle(.configure(started: true, status: .idle, turnOpen: false)) == [.cancel(1)])
    }

    @Test func stopKeepsTheFollowButStaleTicksCannotExpireOrReadForItsReplacement() {
        let now = ContinuousClock.now
        var machine = ChatPollingMachine().after([
            .follow(deadline: now + .seconds(100), knownAssistantIDs: ["old"],
                    started: true, status: .idle, turnOpen: false), .stop,
        ])
        #expect(machine.handle(.tick(1, now: now + .seconds(200), status: .idle, turnOpen: false)).isEmpty)
        #expect(machine.handle(.configure(started: true, status: .idle, turnOpen: false)) == [.start(2)])
        #expect(machine.handle(.tick(1, now: now + .seconds(200), status: .idle, turnOpen: false)).isEmpty)
        #expect(machine.handle(.tick(2, now: now, status: .idle, turnOpen: false)) == [.poll(readTranscript: true)])
        #expect(machine.handle(.configure(started: false, status: .idle, turnOpen: false)) == [.cancel(2)])
        _ = machine.handle(.messagesChanged([Self.message("new", .assistant)]))
        #expect(machine.handle(.configure(started: true, status: .idle, turnOpen: false)).isEmpty)
        #expect(machine.state == .quiescent)
    }

    @Test func followingWhileStoppedWaitsForStartAndBlockedStillPollsAfterExpiry() {
        let now = ContinuousClock.now
        var machine = ChatPollingMachine()
        #expect(machine.handle(.follow(deadline: now, knownAssistantIDs: [],
                                       started: false, status: .idle, turnOpen: false)).isEmpty)
        #expect(machine.handle(.configure(started: true, status: .blocked, turnOpen: false)) == [.start(1)])
        #expect(machine.handle(.tick(1, now: now, status: .blocked, turnOpen: false)) == [.poll(readTranscript: false)])
        #expect(machine.handle(.stop) == [.cancel(1)])
        #expect(machine.handle(.configure(started: true, status: .idle, turnOpen: false)).isEmpty)
        #expect(machine.handle(.stop).isEmpty)
        #expect(machine.handle(.messagesChanged([Self.message("new", .assistant)])).isEmpty)
    }

    private static func message(_ id: String, _ role: ChatTranscriptMessage.Role) -> ChatTranscriptMessage {
        .init(id: id, role: role, text: "", timestamp: nil)
    }
}
