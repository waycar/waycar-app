import Testing

@testable import Waycar

@Suite("Dictation send machine")
struct DictationSendMachineTests {
    @Test func startAndCommitBufferTheWords() {
        var machine = DictationSendMachine()
        #expect(machine.handle(.start) == [.start(1)])
        #expect(machine.state == .recording(token: 1))
        #expect(machine.handle(.committed(1, "Hello")) == [])
        #expect(machine.state == .interrupted(token: 1, text: "Hello"))
        #expect(machine.text(for: 1) == "Hello")
        #expect(machine.text(for: 2).isEmpty)
        #expect(machine.handle(.committed(1, "Hello again")) == [])
        #expect(machine.handle(.keepInterrupted) == [.take("Hello again")])
        #expect(machine.state == .idle)
        #expect(machine.handle(.keepInterrupted) == [])
    }

    @Test func stopWaitsForItsFinalWordsAndConsumesOnce() {
        var machine = DictationSendMachine().after([.start])
        #expect(machine.handle(.stop) == [.finish(1)])
        #expect(machine.state == .stopping(token: 1, text: ""))
        #expect(machine.handle(.keepInterrupted) == [])
        #expect(machine.handle(.stop) == [.finish(1)])
        #expect(machine.handle(.committed(1, "  Last words \n")) == [])
        #expect(machine.handle(.finished(2)) == [])
        #expect(machine.state == .stopping(token: 1, text: "  Last words \n"))
        #expect(machine.handle(.finished(1)) == [.take("Last words")])
        #expect(machine.state == .idle)
        #expect(machine.handle(.finished(1)) == [])
    }

    @Test func stopAfterInterruptionTakesTheBufferedWords() {
        var machine = DictationSendMachine().after([.start, .committed(1, "Buffered")])
        #expect(machine.handle(.stop) == [.finish(1)])
        #expect(machine.handle(.finished(1)) == [.take("Buffered")])
    }

    @Test func emptyOrWhitespaceWordsAreNotTaken() {
        var machine = DictationSendMachine().after([.start, .stop])
        #expect(machine.handle(.finished(1)) == [])
        #expect(machine.handle([.start, .committed(2, " \n"), .keepInterrupted]) == [.start(2)])
        #expect(machine.state == .idle)
    }

    @Test func cancelDiscardsBufferedAndFutureWords() {
        let sessions: [[DictationSendMachine.Event]] = [
            [], [.start], [.start, .committed(1, "Buffered")],
            [.start, .stop, .committed(1, "Final")],
        ]
        for events in sessions {
            var machine = DictationSendMachine().after(events)
            #expect(machine.handle(.cancel) == [.cancel])
            #expect(machine.state == .discarded)
            #expect(machine.handle([
                .committed(1, "Late"), .finished(1), .keepInterrupted, .stop,
            ]) == [])
            #expect(machine.text(for: 1).isEmpty)
            #expect(machine.handle(.start) == [.start(events.isEmpty ? 1 : 2)])
        }
    }

    @Test func replacementIgnoresOldCommitsAndFinish() {
        var machine = DictationSendMachine().after([.start, .stop, .start])
        #expect(machine.state == .recording(token: 2))
        #expect(machine.handle([.committed(1, "Old"), .finished(1)]) == [])
        #expect(machine.state == .recording(token: 2))
        #expect(machine.handle(.committed(2, "New")) == [])
        #expect(machine.handle(.committed(1, "Still old")) == [])
        #expect(machine.handle(.keepInterrupted) == [.take("New")])
    }

    @Test func ignoredEventsDoNotInventASession() {
        var machine = DictationSendMachine()
        #expect(machine.handle([.stop, .finished(1), .committed(1, "Old"), .keepInterrupted]) == [])
        #expect(machine.state == .idle)
        #expect(machine.handle(.start) == [.start(1)])
        #expect(machine.handle([.keepInterrupted, .finished(1)]) == [])
        #expect(machine.state == .recording(token: 1))
    }
}
