import Testing

@testable import Waycar

/// The old View-local Set and Void callback have no testable delivery API.
/// This store is the new seam for B-20; filtering still uses the existing API.
@MainActor
struct QuestionCardDeliveryStoreTests {
    private func question(_ ref: String = "1") -> ChatQuestion {
        ChatQuestion(ref: ref, text: "Which?", kind: "choice", options: [
            ChatQuestionOption(key: "a", label: "First", detail: nil, recommended: false),
            ChatQuestionOption(key: "b", label: "Second", detail: nil, recommended: false),
        ])
    }

    @Test func existingTapFilteringAndNativePickOrderingStayUnchanged() {
        for kind in ["choice", "confirm", "future-kind"] {
            #expect(ChatQuestionCardView.tapAnswers(.init(ref: "1", text: "Q", kind: kind, options: [])))
        }
        for kind in ["multi", "scale", "text"] {
            #expect(!ChatQuestionCardView.tapAnswers(.init(ref: "1", text: "Q", kind: kind, options: [])))
        }
        let q = question()
        let multi = ChatQuestion(ref: q.ref, text: q.text, kind: "multi", options: q.options)
        #expect(ChatQuestionCardView.picking(q.options[0], in: multi, after: ["Second"]) == ["First", "Second"])
    }

    @Test func failedSendLeavesTheCardUnsentAndRetryable() async throws {
        let store = QuestionCardDeliveryStore()
        let q = question()
        store.show([q])
        var calls = 0
        store.pick("a", for: q) { reference in
            #expect(reference == "1a")
            calls += 1
            return .notSent
        }
        #expect(store.sentKey(for: q) == nil, "a tap is not a delivery acknowledgement")
        try await waitUntil("failed answer becomes retryable") { calls == 1 && !store.isAnswered(q) }
        #expect(store.sentKey(for: q) == nil)
        store.pick("b", for: q) { _ in .sent }
        try await waitUntil("retry is confirmed sent") { store.sentKey(for: q) == "b" }
    }

    @Test func inFlightAndQueuedAnswersSuppressDuplicatesWithoutClaimingSent() async throws {
        let store = QuestionCardDeliveryStore()
        let q = question()
        store.show([q])
        var result: CheckedContinuation<QuestionCardDeliveryMachine.Outcome, Never>?
        var calls = 0
        store.pick("a", for: q) { _ in
            calls += 1
            return await withCheckedContinuation { result = $0 }
        }
        defer { result?.resume(returning: .notSent) }
        try await waitUntil("answer in flight") { result != nil }
        store.pick("b", for: q) { _ in calls += 1; return .sent }
        #expect(calls == 1)
        #expect(store.isAnswered(q))
        #expect(store.sentKey(for: q) == nil)
        let held = result
        result = nil
        held?.resume(returning: .queued)
        try await waitUntil("queued completion consumed") { store.inFlightCount == 0 }
        #expect(store.isAnswered(q))
        #expect(store.sentKey(for: q) == nil)
    }
}
