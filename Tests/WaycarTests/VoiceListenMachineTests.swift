import Foundation
import Testing
@testable import Waycar

@Suite("Voice listen machine")
struct VoiceListenMachineTests {
    private let now = ContinuousClock.now
    private func machine() -> VoiceListenMachine {
        VoiceListenMachine(endpointer: Endpointer(
            startedAt: now, endOfSpeech: .seconds(2), noSpeech: .seconds(4),
            maximum: .seconds(10), startup: .seconds(3)), startupFailure: "Not ready")
    }

    @Test func startupCancelsWhereNormalEndpointingOnlyFinishes() {
        var starting = machine()
        #expect(starting.handle(.tick(1, now: now + .seconds(2))).isEmpty)
        #expect(starting.handle(.tick(1, now: now + .seconds(3))) == [.cancelConsumer(1), .finishEngine(1)])
        #expect(starting.handle(.tick(1, now: now + .seconds(5))).isEmpty)
        _ = starting.handle(.streamEnded(1, failure: "Cancelled"))
        #expect(starting.result == .failed("Not ready"))

        var listening = machine().after([.engine(1, .listening, now: now)])
        #expect(listening.handle(.tick(1, now: now + .seconds(4))) == [.finishEngine(1)])
        _ = listening.handle(.streamEnded(1, failure: nil))
        #expect(listening.result == .silence)
    }

    @Test func trailingSilenceWaitsForChangedWordsAndKeepsFinalWords() {
        var machine = machine().after([
            .engine(1, .listening, now: now),
            .engine(1, .transcript("First", isFinal: false), now: now + .seconds(1)),
            .engine(1, .transcript("First", isFinal: false), now: now + .seconds(2)),
        ])
        guard case .listeningSpeech = machine.state else { Issue.record("Expected speech"); return }
        #expect(machine.handle(.tick(1, now: now + .seconds(3))) == [.finishEngine(1)])
        _ = machine.handle(.engine(1, .transcript("First words", isFinal: true), now: now + .seconds(4)))
        _ = machine.handle(.engine(1, .transcript("last words", isFinal: true), now: now + .seconds(4)))
        _ = machine.handle(.streamEnded(1, failure: nil))
        #expect(machine.result == .heard("First words last words"))
        let ended = machine.state
        #expect(machine.handle([.engine(1, .listening, now: now), .tick(1, now: now), .streamEnded(1, failure: "Late")]).isEmpty)
        #expect(machine.state == ended)
    }

    @Test func maximumAndFailureAndEarlyStreamEnd() {
        var maximum = machine().after([
            .engine(1, .listening, now: now),
            .engine(1, .transcript("Hello", isFinal: false), now: now + .seconds(9)),
        ])
        #expect(maximum.handle(.tick(1, now: now + .seconds(10))) == [.finishEngine(1)])
        _ = maximum.handle(.streamEnded(1, failure: "Interrupted"))
        #expect(maximum.result == .failed("Interrupted"))
        var early = machine().after([.engine(1, .transcript("Early", isFinal: false), now: now)])
        guard case .starting = early.state else { Issue.record("Microphone not open yet"); return }
        _ = early.handle(.streamEnded(1, failure: nil))
        #expect(early.result == .heard("Early"), "Preserve words delivered before the listening event")
    }

    @Test func whitespaceLevelsAndStaleEventsDoNotAdvanceTheListen() {
        var machine = machine()
        let before = machine.state
        #expect(machine.handle([
            .engine(2, .listening, now: now), .tick(2, now: now + .seconds(10)),
            .streamEnded(2, failure: nil),
        ]).isEmpty)
        #expect(machine.state == before)
        _ = machine.handle(.engine(1, .listening, now: now))
        _ = machine.handle(.engine(1, .transcript(" ", isFinal: false), now: now))
        _ = machine.handle(.engine(1, .level(0.5), now: now))
        guard case .listeningQuiet = machine.state else { Issue.record("Whitespace is not speech"); return }
        _ = machine.handle(.streamEnded(1, failure: nil))
        #expect(machine.result == .silence)
    }
}
