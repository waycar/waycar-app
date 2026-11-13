import Observation

/// Owns delivery Tasks outside the View. Exact questions, not reference
/// prefixes, retain a pick; replacement invalidates a late acknowledgement.
@MainActor
@Observable
final class QuestionCardDeliveryStore {
    typealias Submit = @MainActor (String) async -> QuestionCardDeliveryMachine.Outcome

    private struct Attempt: Hashable {
        let ref: String
        let token: UInt64
    }

    private var machines: [String: QuestionCardDeliveryMachine] = [:]
    @ObservationIgnored private var tasks: [Attempt: Task<Void, Never>] = [:]

    var inFlightCount: Int { tasks.count }

    func show(_ questions: [ChatQuestion]) {
        for ref in Array(machines.keys) where !questions.contains(where: { $0.ref == ref }) {
            _ = machines[ref]?.handle(.show(nil))
        }
        for question in questions {
            var machine = machines[question.ref] ?? QuestionCardDeliveryMachine()
            _ = machine.handle(.show(question))
            machines[question.ref] = machine
        }
    }

    func isAnswered(_ question: ChatQuestion) -> Bool {
        guard let machine = machines[question.ref], machine.question == question else { return false }
        return machine.isAnswered
    }

    func sentKey(for question: ChatQuestion) -> String? {
        guard let machine = machines[question.ref], machine.question == question else { return nil }
        return machine.sentKey
    }

    func pickedKey(for question: ChatQuestion) -> String? {
        guard let machine = machines[question.ref], machine.question == question else { return nil }
        return machine.pickedKey
    }

    func pick(_ key: String, for question: ChatQuestion, submit: @escaping Submit) {
        var machine = machines[question.ref] ?? QuestionCardDeliveryMachine()
        _ = machine.handle(.show(question))
        let effects = machine.handle(.pick(key))
        machines[question.ref] = machine
        for effect in effects {
            switch effect {
            case .submit(let token, let reference):
                let attempt = Attempt(ref: question.ref, token: token)
                tasks[attempt] = Task { [weak self] in
                    let outcome = await submit(reference)
                    self?.finish(attempt, outcome: outcome)
                }
            }
        }
    }

    private func finish(_ attempt: Attempt, outcome: QuestionCardDeliveryMachine.Outcome) {
        tasks[attempt] = nil
        _ = machines[attempt.ref]?.handle(.finished(attempt.token, outcome))
    }
}
