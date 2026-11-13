import Foundation
import Testing

@testable import Waycar

@MainActor
@Suite("Blocked prompt answerer")
struct BlockedPromptAnswererTests {
    /// A Blocked pane: the screens reads return, in order (the last
    /// repeats), and the keys that reached it.
    @MainActor
    final class FakePane {
        var screens: [String]
        var readError: (any Error)?
        var sendError: (any Error)?
        private(set) var reads = 0
        private(set) var sendAttempts = 0
        private(set) var sent: [[String]] = []
        /// Holds every read until released.
        var holdsReads = false
        private var heldReads: [CheckedContinuation<Void, Never>] = []

        init(_ screens: [String]) {
            self.screens = screens
        }

        func read() async throws -> String {
            if holdsReads {
                await withCheckedContinuation { heldReads.append($0) }
            }
            defer { reads += 1 }
            if let readError { throw readError }
            return screens[min(reads, screens.count - 1)]
        }

        func send(_ keys: [String]) async throws {
            sendAttempts += 1
            if let sendError { throw sendError }
            sent.append(keys)
        }

        func resetReads() { reads = 0 }

        func releaseReads() {
            holdsReads = false
            let held = heldReads
            heldReads = []
            held.forEach { $0.resume() }
        }

        var hasHeldRead: Bool { !heldReads.isEmpty }
        var heldReadCount: Int { heldReads.count }

        func answerer() -> BlockedPromptAnswerer {
            BlockedPromptAnswerer(
                readScreen: { try await self.read() }, sendKeys: { try await self.send($0) })
        }
    }

    struct LinkDown: Error {}

    static let permission = TmuxScreenDetectorTests.claudePermission
    static let otherPermission = permission.replacingOccurrences(
        of: " ❯ 1. Yes\n   2.", with: "   1. Yes\n ❯ 2.")
    static let idleClaude = TmuxScreenDetectorTests.claudeBox(above: [
        "❯ fix it", "⏺ Done.", "✻ Baked for 3s · done 3:25 PM",
    ])

    private func makeSnapshot(_ screen: String = permission) throws -> BlockedPromptSnapshot {
        try #require(BlockedPromptSnapshot(kind: "claude", fullScreen: screen))
    }

    // MARK: Guard

    @Test func screenTextKeepsTheLastTwelveVisibleLinesTrimmed() {
        let screen = (1...20).map { "line \($0)   " }.joined(separator: "\n\n")
        let text = BlockedPromptAnswerer.screenText(from: screen)
        #expect(text == (9...20).map { "line \($0)" }.joined(separator: "\n"))
        #expect(BlockedPromptAnswerer.screenText(from: " \n\t\n") == nil)
    }

    @Test func aMatchingScreenGetsTheKeys() async throws {
        let pane = FakePane([Self.permission])
        let shown = try #require(BlockedPromptAnswerer.screenText(from: Self.permission))
        let outcome = await pane.answerer().answer(keys: ["enter"], shown: shown)
        #expect(outcome == .sent)
        #expect(pane.sent == [["enter"]])
    }

    @Test func aChangedScreenSendsNothing() async throws {
        let pane = FakePane([Self.otherPermission])
        let shown = try #require(BlockedPromptAnswerer.screenText(from: Self.permission))
        let outcome = await pane.answerer().answer(keys: ["enter"], shown: shown)
        #expect(
            outcome
                == .promptChanged(current: BlockedPromptAnswerer.screenText(from: Self.otherPermission)))
        #expect(pane.sendAttempts == 0)
    }

    @Test func anUnreadableScreenSendsNothing() async throws {
        let pane = FakePane([Self.permission])
        pane.readError = LinkDown()
        let shown = try #require(BlockedPromptAnswerer.screenText(from: Self.permission))
        #expect(await pane.answerer().answer(keys: ["esc"], shown: shown) == .promptChanged(current: nil))
        #expect(pane.sendAttempts == 0)
    }

    @Test func anUnwantedAnswerIsAbandonedAfterTheRead() async throws {
        let pane = FakePane([Self.permission])
        let shown = try #require(BlockedPromptAnswerer.screenText(from: Self.permission))
        let outcome = await pane.answerer().answer(keys: ["enter"], shown: shown) { false }
        #expect(outcome == .abandoned)
        #expect(pane.reads == 1)
        #expect(pane.sendAttempts == 0)
    }

    @Test func aFailedSendIsNeverRetried() async throws {
        let pane = FakePane([Self.permission])
        pane.sendError = LinkDown()
        let answerer = pane.answerer()
        let snapshot = try makeSnapshot()
        #expect(await answerer.allow(snapshot) == .sendFailed)
        #expect(pane.sendAttempts == 1)
        #expect(pane.sent.isEmpty)
    }

    // MARK: Queued answers

    private func queueingAnswerer(
        _ pane: FakePane, into queued: @escaping @MainActor (PendingBlockedAnswer) -> Void
    ) -> BlockedPromptAnswerer {
        BlockedPromptAnswerer(
            readScreen: { try await pane.read() }, sendKeys: { try await pane.send($0) },
            queueAnswer: queued)
    }

    private final class Collected {
        var answers: [PendingBlockedAnswer] = []
    }

    @Test func anUnreachableHostQueuesAnAllowInsteadOfSendingIt() async throws {
        let pane = FakePane([Self.permission])
        pane.readError = RequestNotSentError(cause: TransportError.timedOut)
        let collected = Collected()
        let answerer = queueingAnswerer(pane) { collected.answers.append($0) }
        let snapshot = try makeSnapshot()
        #expect(await answerer.allow(snapshot) == .queued)
        #expect(pane.sendAttempts == 0)
        #expect(
            collected.answers
                == [
                    PendingBlockedAnswer(
                        label: "Allow", keys: ["enter"], shown: snapshot.screen, snapshot: snapshot)
                ])
    }

    @Test func aQueuedAnswerSendsOnlyWhileTheSamePromptIsOnScreen() async throws {
        let pane = FakePane([Self.permission])
        pane.readError = RequestNotSentError(cause: TransportError.timedOut)
        let collected = Collected()
        let answerer = queueingAnswerer(pane) { collected.answers.append($0) }
        let snapshot = try makeSnapshot()
        _ = await answerer.allow(snapshot)
        let pending = try #require(collected.answers.first)

        // Still down: it waits.
        #expect(await answerer.replay(pending) == .unreachable)
        #expect(pane.sendAttempts == 0)

        // Back, but another prompt is showing: nothing goes out.
        pane.readError = nil
        pane.screens = [Self.otherPermission]
        let outcome = await answerer.replay(pending)
        #expect(
            outcome
                == .promptChanged(current: BlockedPromptAnswerer.screenText(from: Self.otherPermission)))
        #expect(pane.sendAttempts == 0)

        // Back with the prompt the user answered: the keys go out once.
        pane.screens = [Self.permission]
        pane.resetReads()
        #expect(await answerer.replay(pending) == .sent)
        #expect(pane.sent == [["enter"]])
    }

    @Test func anAnswerThatDoesNotQueueReadsAsAnUnreadableScreen() async throws {
        let pane = FakePane([Self.permission])
        pane.readError = RequestNotSentError(cause: TransportError.timedOut)
        let collected = Collected()
        let answerer = queueingAnswerer(pane) { collected.answers.append($0) }
        let snapshot = try makeSnapshot()
        #expect(await answerer.allow(snapshot, queuesOffline: false) == .promptChanged(current: nil))
        #expect(await answerer.deny(snapshot, queuesOffline: false) == .promptChanged(current: nil))
        #expect(collected.answers.isEmpty)
    }

    @Test func aFailureThatIsNotTheLinkIsNotQueued() async throws {
        let pane = FakePane([Self.permission])
        pane.readError = TransportError.apiRejected(code: "agent_not_found", message: "gone")
        let collected = Collected()
        let answerer = queueingAnswerer(pane) { collected.answers.append($0) }
        let shown = try #require(BlockedPromptAnswerer.screenText(from: Self.permission))
        #expect(await answerer.answer(keys: ["esc"], shown: shown) == .promptChanged(current: nil))
        #expect(collected.answers.isEmpty)
    }

    @Test func aReplayWithdrawnWhileItsScreenIsReadSendsNothing() async throws {
        let pane = FakePane([Self.permission])
        let snapshot = try makeSnapshot()
        let pending = PendingBlockedAnswer(
            label: "Allow", keys: ["enter"], shown: snapshot.screen, snapshot: snapshot)
        let outcome = await pane.answerer().replay(pending, stillWanted: { false })
        #expect(outcome == .abandoned)
        #expect(pane.sendAttempts == 0)
    }

    // MARK: Car rules

    @Test func allowSendsEnterOnlyForTheAnnouncedPlainYes() async throws {
        let pane = FakePane([Self.permission])
        let snapshot = try makeSnapshot()
        #expect(await pane.answerer().allow(snapshot) == .sent)
        #expect(pane.sent == [["enter"]])
    }

    @Test(arguments: [
        // Risky.
        TmuxScreenDetectorTests.claudePermission.replacingOccurrences(
            of: " touch x.txt", with: " git push --force origin main"),
        // Not lossless.
        TmuxScreenDetectorTests.claudePermission.replacingOccurrences(
            of: " touch x.txt", with: " touch x.txt &&\n touch y.txt"),
        // Trust and question: read-only.
        TmuxScreenDetectorTests.claudeTrust,
        TmuxScreenDetectorTests.claudeQuestion,
    ])
    func heldAndReadOnlyPromptsNeverGetEnter(screen: String) async throws {
        let pane = FakePane([screen])
        let snapshot = try makeSnapshot(screen)
        let outcome = await pane.answerer().allow(snapshot)
        #expect(outcome == .refused)
        #expect(pane.reads == 0)
        #expect(pane.sendAttempts == 0)
    }

    @Test func trustIsNeverDenied() async throws {
        let pane = FakePane([TmuxScreenDetectorTests.claudeTrust])
        let snapshot = try makeSnapshot(TmuxScreenDetectorTests.claudeTrust)
        #expect(await pane.answerer().deny(snapshot) == .refused)
        #expect(pane.sendAttempts == 0)
    }

    @Test func denySendsEscThroughTheGuard() async throws {
        let pane = FakePane([Self.permission])
        let snapshot = try makeSnapshot()
        #expect(await pane.answerer().deny(snapshot) == .sent)
        #expect(pane.sent == [["esc"]])
    }

    @Test func oneCarActionAtATime() async throws {
        let pane = FakePane([Self.permission])
        pane.holdsReads = true
        let answerer = pane.answerer()
        let snapshot = try makeSnapshot()
        let first = Task { await answerer.allow(snapshot) }
        try await waitUntil { pane.hasHeldRead }
        #expect(await answerer.deny(snapshot) == .busy)
        pane.releaseReads()
        #expect(await first.value == .sent)
        #expect(pane.sent == [["enter"]])
    }

    // MARK: Deny with a correction

    private func updates(_ statuses: [AgentStatus]) -> AsyncStream<ConsoleStore.AgentStatusUpdate> {
        let (stream, continuation) = AsyncStream.makeStream(of: ConsoleStore.AgentStatusUpdate.self)
        for status in statuses {
            continuation.yield(.init(status: status, liveUpdatesAvailable: true))
        }
        return stream
    }

    @Test func genericAnswersRetainIndependentAdmissionFromCarActions() async throws {
        let pane = FakePane([Self.permission])
        pane.holdsReads = true
        let answerer = pane.answerer()
        let snapshot = try makeSnapshot()
        let car = Task { await answerer.allow(snapshot) }
        try await waitUntil { pane.heldReadCount == 1 }
        let generic = Task { await answerer.answer(keys: ["esc"], shown: snapshot.screen) }
        try await waitUntil { pane.heldReadCount == 2 }
        #expect(answerer.isActing)
        pane.releaseReads()
        #expect(await car.value == .sent)
        #expect(await generic.value == .sent)
        #expect(pane.sendAttempts == 2)
        #expect(!answerer.isActing)
    }

    @Test func replayClaimsOnlyAfterTheScreenGuardAndHonorsARejectedClaim() async throws {
        let pane = FakePane([Self.otherPermission, Self.permission])
        let answerer = pane.answerer()
        let snapshot = try makeSnapshot()
        let pending = PendingBlockedAnswer(
            label: "Allow", keys: ["enter"], shown: snapshot.screen, snapshot: snapshot)
        var claims = 0
        let changed = await answerer.replay(pending, willSend: { claims += 1; return false })
        #expect(changed == .promptChanged(current: BlockedPromptAnswerer.screenText(from: Self.otherPermission)))
        #expect(claims == 0)
        #expect(await answerer.replay(pending, willSend: { claims += 1; return false }) == .abandoned)
        #expect(claims == 1)
        #expect(pane.sendAttempts == 0)
    }

    @Test func aCorrectionIsPromptedOnceTheAgentLeavesBlocked() async throws {
        let pane = FakePane([Self.permission])
        var prompts: [String] = []
        var drafts: [String] = []
        let outcome = try await pane.answerer().denyAndInstruct(
            makeSnapshot(), text: "use pnpm instead",
            statusUpdates: updates([.blocked, .idle]),
            prompt: { prompts.append($0) }, draft: { drafts.append($0) },
            timeout: .seconds(5), screenRecheckDelay: .seconds(30))
        #expect(outcome == .prompted)
        #expect(pane.sent == [["esc"]])
        #expect(prompts == ["use pnpm instead"])
        #expect(drafts.isEmpty)
    }

    @Test func aCorrectionFollowsTheOneScreenRecheck() async throws {
        // The status lags at Blocked; the screen already shows Claude idle.
        let pane = FakePane([Self.permission, Self.idleClaude])
        var prompts: [String] = []
        let outcome = try await pane.answerer().denyAndInstruct(
            makeSnapshot(), text: "use pnpm instead",
            statusUpdates: updates([.blocked]),
            prompt: { prompts.append($0) }, draft: { _ in },
            timeout: .seconds(5), screenRecheckDelay: .milliseconds(20))
        #expect(outcome == .prompted)
        #expect(pane.reads == 2)
        #expect(prompts == ["use pnpm instead"])
    }

    @Test func aCorrectionGoesToTheDraftWhenTheAgentStaysBlocked() async throws {
        let pane = FakePane([Self.permission])
        var prompts: [String] = []
        var drafts: [String] = []
        let outcome = try await pane.answerer().denyAndInstruct(
            makeSnapshot(), text: "use pnpm instead",
            statusUpdates: updates([.blocked]),
            prompt: { prompts.append($0) }, draft: { drafts.append($0) },
            timeout: .milliseconds(60), screenRecheckDelay: .milliseconds(10))
        #expect(outcome == .drafted)
        #expect(pane.sent == [["esc"]])
        #expect(prompts.isEmpty)
        #expect(drafts == ["use pnpm instead"])
    }

    @Test func aPromptRefusedAsBlockedIsDrafted() async throws {
        let pane = FakePane([Self.permission])
        var drafts: [String] = []
        let outcome = try await pane.answerer().denyAndInstruct(
            makeSnapshot(), text: "use pnpm instead",
            statusUpdates: updates([.idle]),
            prompt: { _ in throw HerdrAPIError(code: "agent_blocked", message: "blocked") },
            draft: { drafts.append($0) },
            timeout: .seconds(5), screenRecheckDelay: .seconds(30))
        #expect(outcome == .drafted)
        #expect(drafts == ["use pnpm instead"])
    }

    @Test func aPromptLostOnTheLinkIsNeitherResentNorDrafted() async throws {
        let pane = FakePane([Self.permission])
        var attempts = 0
        var drafts: [String] = []
        let outcome = try await pane.answerer().denyAndInstruct(
            makeSnapshot(), text: "use pnpm instead",
            statusUpdates: updates([.idle]),
            prompt: { _ in
                attempts += 1
                throw LinkDown()
            },
            draft: { drafts.append($0) },
            timeout: .seconds(5), screenRecheckDelay: .seconds(30))
        #expect(outcome == .promptFailed)
        #expect(attempts == 1)
        #expect(drafts.isEmpty)
    }

    @Test func aChangedPromptGetsNoEscAndNoCorrection() async throws {
        let pane = FakePane([Self.otherPermission])
        var prompts: [String] = []
        var drafts: [String] = []
        let outcome = try await pane.answerer().denyAndInstruct(
            makeSnapshot(), text: "use pnpm instead",
            statusUpdates: updates([.idle]),
            prompt: { prompts.append($0) }, draft: { drafts.append($0) })
        guard case .denyFailed(.promptChanged) = outcome else {
            Issue.record("expected the guard to refuse, got \(outcome)")
            return
        }
        #expect(pane.sendAttempts == 0)
        #expect(prompts.isEmpty)
        #expect(drafts.isEmpty)
    }
}
