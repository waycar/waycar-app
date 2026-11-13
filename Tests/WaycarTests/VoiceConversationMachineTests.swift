import Foundation
import Testing
@testable import Waycar

@Suite("Voice conversation machine")
struct VoiceConversationMachineTests {
    private typealias Machine = VoiceConversationMachine
    private let now = ContinuousClock.now

    private func listening() -> Machine {
        Machine(idle: .seconds(10)).after([.start, .introduced(1, now: now)])
    }

    @Test func introductionIsNamedAndStartIsSingleUse() {
        var machine = Machine(idle: .seconds(10))
        #expect(machine.state == .ready)
        #expect(machine.handle(.start) == [.introduce(1)])
        #expect(machine.state == .introducing(1))
        #expect(machine.phase == nil, "No new presentation during introduction")
        #expect(machine.handle(.start).isEmpty)
        #expect(machine.handle(.introduced(99, now: now)).isEmpty)
        #expect(machine.handle(.introduced(1, now: now)) == [.phase(.listening(followUp: false)), .listen(2)])
    }

    @Test func silenceRetainsTheOriginalQuietDeadline() {
        var machine = listening()
        #expect(machine.handle(.listened(2, .silence, isExit: false, now: now + .seconds(5))) == [.listen(3)])
        #expect(machine.state == .listening(3, followUp: false, quietSince: now))
        #expect(machine.handle(.listened(3, .silence, isExit: false, now: now + .seconds(10))) == [.announce(4)])
        #expect(machine.phase == .listening(followUp: false))
        #expect(machine.handle(.announced(4, now: now)) == [.endAudio, .clearTask, .phase(.ended(.silence))])
        #expect(machine.isEnded)
    }

    @Test func speechAutoSendsAndAFailureFinishesAfterSpeakingAndAnnouncements() {
        var machine = listening()
        #expect(machine.handle(.listened(2, .heard("Question"), isExit: false, now: now)) == [.phase(.sending), .send(3, "Question")])
        #expect(machine.handle(.sent(3, .failed("Not sent"))) == [.speak(4, "Not sent")])
        #expect(machine.phase == .sending)
        #expect(machine.handle(.spoken(4)) == [.announce(5)])
        #expect(machine.handle(.announced(5, now: now)) == [.endAudio, .clearTask, .phase(.ended(.finished))])
    }

    @Test func listeningFailureSpeaksBeforeEnding() {
        var machine = listening()
        #expect(machine.handle(.listened(2, .failed("Unavailable"), isExit: false, now: now)) == [.speak(3, "Unavailable")])
        #expect(machine.handle(.spoken(3)) == [.announce(4)])
        #expect(machine.handle(.announced(4, now: now)) == [.endAudio, .clearTask, .phase(.ended(.finished))])
    }

    @Test func anExitIsNeverSent() {
        var machine = listening()
        #expect(machine.handle(.listened(2, .heard("stop"), isExit: true, now: now)) == [.cancelTask, .endAudio, .phase(.ended(.driver))])
        #expect(machine.isEnded)
    }

    @Test func closeIsTerminalFromEveryInFlightPhase() {
        let states: [Machine.State] = [
            .ready, .introducing(1), .listening(2, followUp: false, quietSince: now),
            .sending(3), .waiting(4), .replying(5), .announcing(6),
            .finishing(7, .finished, lastPhase: .waiting, announcing: false),
            .finishing(8, .finished, lastPhase: .waiting, announcing: true),
        ]
        // Reach each state through events rather than mutating machine state.
        let cursor = AgentVoiceService.ReplyCursor(
            agentID: ConsoleAgent.ID(hostID: UUID(), paneID: "pane"), identity: "Agent",
            transcriptAvailable: false, lastMessageID: nil, knownAssistantIDs: [], summaryBefore: nil)
        let prefixes: [[Machine.Event]] = [
            [], [.start], [.start, .introduced(1, now: now)],
            [.start, .introduced(1, now: now), .listened(2, .heard("Q"), isExit: false, now: now)],
        ]
        let sending = prefixes[3]
        let waiting = sending + [.sent(3, .delivered(cursor))]
        let replying = waiting + [.replied(4, .answer("Reply"))]
        let finishing = waiting + [.replied(4, .final("Final"))]
        let all = prefixes + [waiting, replying, replying + [.spoken(5)], finishing, finishing + [.spoken(5)]]
        #expect(all.count == states.count)
        for prefix in all {
            var machine = Machine(idle: .seconds(10)).after(prefix)
            #expect(machine.handle(.close(releasingAudio: false)) == [.cancelTask, .stopAudio, .phase(.ended(.driver))])
            #expect(machine.handle([.start, .introduced(1, now: now), .spoken(5), .announced(6, now: now), .close(releasingAudio: true)]).isEmpty)
        }
    }

    @Test func replyThenAnnouncementThenFollowUp() {
        let cursor = AgentVoiceService.ReplyCursor(
            agentID: ConsoleAgent.ID(hostID: UUID(), paneID: "pane"), identity: "Agent",
            transcriptAvailable: false, lastMessageID: nil, knownAssistantIDs: [], summaryBefore: nil)
        var machine = listening().after([.listened(2, .heard("Q"), isExit: false, now: now)])
        #expect(machine.handle(.sent(3, .delivered(cursor))) == [.phase(.waiting), .reply(4, cursor)])
        #expect(machine.handle(.replied(4, .answer("Reply"))) == [.phase(.replying), .speak(5, "Reply")])
        #expect(machine.handle(.spoken(5)) == [.announce(6)])
        #expect(machine.handle(.announced(6, now: now)) == [.phase(.listening(followUp: true)), .listen(7)])
        #expect(machine.handle(.listened(2, .heard("stale"), isExit: false, now: now)).isEmpty)
        #expect(machine.phase == .listening(followUp: true))
    }

    @Test func outOfOrderAndStaleCompletionsAreIgnored() {
        var machine = listening()
        let before = machine.state
        #expect(machine.handle([
            .introduced(1, now: now), .listened(1, .silence, isExit: false, now: now),
            .sent(2, .failed("No")), .replied(2, .final("No")), .spoken(2),
            .announced(2, now: now), .start,
        ]).isEmpty)
        #expect(machine.state == before)
    }
}
