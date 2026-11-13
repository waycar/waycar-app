import Testing

@testable import Waycar

struct QuestionCardDeliveryMachineTests {
    private func question(_ ref: String = "1", text: String = "Which?", kind: String = "choice") -> ChatQuestion {
        .init(ref: ref, text: text, kind: kind, options: [
            .init(key: "a", label: "First", detail: nil, recommended: false),
            .init(key: "b", label: "Second", detail: nil, recommended: false),
        ])
    }

    @Test func onlyConfirmedDeliveryIsSentAndFailureAllowsRetry() {
        let q = question()
        var machine = QuestionCardDeliveryMachine().after([.show(q)])
        #expect(machine.handle(.pick("a")) == [.submit(1, reference: "1a")])
        #expect(machine.isAnswered)
        #expect(machine.sentKey == nil)
        #expect(machine.handle(.pick("b")).isEmpty)
        #expect(machine.handle(.finished(1, .notSent)).isEmpty)
        #expect(machine.state == .unanswered(q))
        #expect(!machine.isAnswered)
        #expect(machine.handle(.pick("b")) == [.submit(2, reference: "1b")])
        #expect(machine.handle(.finished(1, .sent)).isEmpty)
        #expect(machine.sentKey == nil)
        #expect(machine.handle(.finished(2, .sent)).isEmpty)
        #expect(machine.sentKey == "b")
        #expect(machine.handle(.pick("a")).isEmpty)
    }

    /// The tapped option stays highlighted while it sends or waits, and is
    /// released again when the send fails, so the user sees their pick.
    @Test func theTappedOptionStaysPickedUntilTheSendFails() {
        let q = question()
        var machine = QuestionCardDeliveryMachine().after([.show(q)])
        #expect(machine.pickedKey == nil)
        _ = machine.handle(.pick("a"))
        #expect(machine.pickedKey == "a")
        #expect(machine.sentKey == nil)
        _ = machine.handle(.finished(1, .queued))
        #expect(machine.pickedKey == "a")
        var failing = QuestionCardDeliveryMachine().after([.show(q), .pick("b"), .finished(1, .notSent)])
        #expect(failing.pickedKey == nil)
        _ = failing.handle(.pick("a"))
        _ = failing.handle(.finished(2, .sent))
        #expect(failing.pickedKey == "a")
        #expect(failing.sentKey == "a")
    }

    @Test func queuedAnswersStaySingleFlightButDoNotClaimSent() {
        let q = question()
        var machine = QuestionCardDeliveryMachine().after([.show(q), .pick("a"), .finished(1, .queued)])
        #expect(machine.state == .queued(q, option: "a"))
        #expect(machine.isAnswered)
        #expect(machine.sentKey == nil)
        #expect(machine.handle(.pick("b")).isEmpty)
        #expect(machine.handle(.finished(1, .sent)).isEmpty)
    }

    @Test func replacingAQuestionRejectsItsOldCompletionEvenWhenRefIsReused() {
        let original = question()
        let replacement = question(text: "Next?")
        var machine = QuestionCardDeliveryMachine().after([.show(original), .pick("a")])
        #expect(machine.handle(.show(original)).isEmpty)
        #expect(machine.isAnswered)
        #expect(machine.handle(.show(replacement)).isEmpty)
        #expect(machine.handle(.pick("b")) == [.submit(2, reference: "1b")])
        #expect(machine.handle(.finished(1, .sent)).isEmpty)
        #expect(machine.state == .submitting(replacement, token: 2, option: "b"))
        #expect(machine.handle(.finished(2, .sent)).isEmpty)
        #expect(machine.sentKey == "b")
        #expect(machine.handle(.show(nil)).isEmpty)
        #expect(machine.state == .absent)
        #expect(machine.handle(.finished(2, .sent)).isEmpty)
        #expect(machine.handle(.pick("a")).isEmpty)
    }

    @Test func unsupportedTapKindsAndUnknownOptionsNeverSubmit() {
        for kind in ["multi", "scale", "text"] {
            var machine = QuestionCardDeliveryMachine().after([.show(question(kind: kind))])
            #expect(machine.handle(.pick("a")).isEmpty)
        }
        var machine = QuestionCardDeliveryMachine().after([.show(question(kind: "future-kind"))])
        #expect(machine.handle(.pick("missing")).isEmpty)
        #expect(machine.handle(.pick("a")) == [.submit(1, reference: "1a")])
    }
}
