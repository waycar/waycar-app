/// A single question's one-tap answer is Sent only after acknowledgement.
/// Queued answers stay single-flight, without claiming delivery; failed or
/// ignored sends return to the existing unanswered presentation.
struct QuestionCardDeliveryMachine: StateMachine {
    enum State: Equatable, Sendable {
        case absent
        case unanswered(ChatQuestion)
        case submitting(ChatQuestion, token: UInt64, option: String)
        case queued(ChatQuestion, option: String)
        case sent(ChatQuestion, option: String)
    }

    enum Outcome: Equatable, Sendable {
        case sent
        case queued
        case notSent
    }

    enum Event: Equatable, Sendable {
        case show(ChatQuestion?)
        case pick(String)
        case finished(UInt64, Outcome)
    }

    enum Effect: Equatable, Sendable {
        case submit(UInt64, reference: String)
    }

    private(set) var state: State = .absent
    private var lastToken: UInt64 = 0

    var question: ChatQuestion? {
        switch state {
        case .absent: nil
        case .unanswered(let question), .submitting(let question, _, _),
             .queued(let question, _), .sent(let question, _): question
        }
    }

    var isAnswered: Bool {
        switch state {
        case .submitting, .queued, .sent: true
        case .absent, .unanswered: false
        }
    }

    var sentKey: String? {
        if case .sent(_, let option) = state { return option }
        return nil
    }

    /// The option the user tapped, from the tap on: the card keeps it
    /// highlighted while it sends or waits in the queue, not only once sent.
    var pickedKey: String? {
        switch state {
        case .submitting(_, _, let option), .queued(_, let option), .sent(_, let option): option
        case .absent, .unanswered: nil
        }
    }

    static func tapAnswers(_ question: ChatQuestion) -> Bool {
        question.kind != "multi" && question.kind != "scale" && question.kind != "text"
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (_, .show(let replacement)):
            guard replacement != question else { return [] }
            state = replacement.map { .unanswered($0) } ?? .absent
            return []
        case (.unanswered(let question), .pick(let key)):
            guard Self.tapAnswers(question), question.options.contains(where: { $0.key == key }) else { return [] }
            lastToken += 1
            state = .submitting(question, token: lastToken, option: key)
            return [.submit(lastToken, reference: question.ref + key)]
        case (.submitting(let question, let token, let key), .finished(let received, let outcome))
            where token == received:
            switch outcome {
            case .sent: state = .sent(question, option: key)
            case .queued: state = .queued(question, option: key)
            case .notSent: state = .unanswered(question)
            }
            return []
        case (.absent, .pick), (.submitting, .pick), (.queued, .pick), (.sent, .pick),
             (.absent, .finished), (.unanswered, .finished), (.submitting, .finished),
             (.queued, .finished), (.sent, .finished):
            return []
        }
    }
}
