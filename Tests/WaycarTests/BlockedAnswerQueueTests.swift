import Foundation
import Testing

@testable import Waycar

@MainActor
@Suite("Blocked answer queue")
struct BlockedAnswerQueueTests {
    private let hostA = Host.ID()
    private let hostB = Host.ID()

    private func pending(_ label: String = "Allow") -> PendingBlockedAnswer {
        PendingBlockedAnswer(label: label, keys: ["enter"], shown: "screen", snapshot: nil)
    }

    private func agent(_ host: Host.ID, _ pane: String = "w1:p1") -> ConsoleAgent.ID {
        ConsoleAgent.ID(hostID: host, paneID: pane)
    }

    /// A sleep that returns only when released, so an expiry fires on cue.
    @MainActor
    private final class Clock {
        private var waiters: [CheckedContinuation<Void, any Error>] = []
        var hasParkedSleeper: Bool { !waiters.isEmpty }

        func sleep(_: Duration) async throws {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { waiters.append($0) }
            } onCancel: {}
        }
        func fire() {
            let all = waiters
            waiters = []
            all.forEach { $0.resume() }
        }
    }

    @Test func anAnswerAlreadySendingCannotExpire() async {
        let queue = BlockedAnswerQueue()
        let id = agent(hostA)
        let entry = queue.enqueue(pending(), for: id)
        var finished: [BlockedAnswerQueue.Finish] = []
        queue.onFinished = { _, finish in finished.append(finish) }
        let (started, didStart) = AsyncStream.makeStream(of: Void.self)
        let (ack, acknowledge) = AsyncStream.makeStream(of: Void.self)
        let answerer = BlockedPromptAnswerer(
            readScreen: { "screen" },
            sendKeys: { _ in
                didStart.yield(())
                for await _ in ack { break }
            })
        let replay = Task {
            let outcome = await answerer.replay(
                entry.pending,
                stillWanted: { queue.entry(for: id)?.id == entry.id },
                willSend: { queue.beginSending(entry) })
            if outcome == .sent { queue.finish(entry, .sent) }
        }
        for await _ in started { break }
        // The expiry callback arrives while the send's acknowledgement is held.
        queue.finish(entry, .expired)
        acknowledge.yield(())
        await replay.value
        #expect(finished == [.sent])
    }

    @Test func aNewerAnswerReplacesTheOlderForTheSameAgent() {
        let queue = BlockedAnswerQueue()
        let id = agent(hostA)
        queue.enqueue(pending("Allow"), for: id)
        let second = queue.enqueue(pending("Deny"), for: id)
        #expect(queue.entry(for: id) == second)
        #expect(queue.entries.count == 1)
    }

    @Test func withdrawingIsSilent() {
        let queue = BlockedAnswerQueue()
        var reported = 0
        queue.onFinished = { _, _ in reported += 1 }
        let id = agent(hostA)
        queue.enqueue(pending(), for: id)
        queue.withdraw(agentID: id)
        #expect(queue.entry(for: id) == nil)
        #expect(reported == 0)
    }

    @Test func aHostChangeDropsOnlyThatHostsAnswers() {
        let queue = BlockedAnswerQueue()
        queue.enqueue(pending(), for: agent(hostA))
        queue.enqueue(pending(), for: agent(hostB))
        queue.withdrawAll(on: hostA)
        #expect(queue.entry(for: agent(hostA)) == nil)
        #expect(queue.entry(for: agent(hostB)) != nil)
        queue.retainHosts([])
        #expect(queue.entries.isEmpty)
    }

    @Test func anAnswerExpiresAndIsReported() async throws {
        let clock = Clock()
        let queue = BlockedAnswerQueue(maxAge: .seconds(600)) { try await clock.sleep($0) }
        var finished: [BlockedAnswerQueue.Finish] = []
        queue.onFinished = { _, finish in finished.append(finish) }
        let id = agent(hostA)
        queue.enqueue(pending(), for: id)
        try await waitUntil("the expiry timer should park before it is fired") { clock.hasParkedSleeper }
        clock.fire()
        try await waitUntil("the expired answer should be reported") { finished == [.expired] }
        #expect(queue.entry(for: id) == nil)
    }

    @Test func aReplacedAnswerNeverExpiresTheNewOne() async throws {
        let clock = Clock()
        let queue = BlockedAnswerQueue(maxAge: .seconds(600)) { try await clock.sleep($0) }
        var finished: [BlockedAnswerQueue.Finish] = []
        queue.onFinished = { _, finish in finished.append(finish) }
        let id = agent(hostA)
        let first = queue.enqueue(pending("Allow"), for: id)
        queue.enqueue(pending("Deny"), for: id)
        // The superseded entry ending late reports nothing.
        queue.finish(first, .sent)
        #expect(finished.isEmpty)
        #expect(queue.entry(for: id)?.pending.label == "Deny")
    }
}
