import Foundation
import Testing

@testable import Waycar

/// A Queued Answer through the Console: it goes out once, only while the same
/// prompt is on screen, and only for an Agent that is still Blocked.
@MainActor
@Suite("Queued Answer replay", .timeLimit(.minutes(1)))
struct BlockedAnswerReplayTests {
    private let hostID = UUID()
    private let id: ConsoleAgent.ID

    init() {
        id = ConsoleAgent.ID(hostID: hostID, paneID: "w1:p1")
    }

    private var shown: String {
        BlockedPromptAnswerer.screenText(from: TmuxScreenDetectorTests.claudePermission) ?? ""
    }

    private func pending() -> PendingBlockedAnswer {
        PendingBlockedAnswer(label: "Allow", keys: ["enter"], shown: shown, snapshot: nil)
    }

    private func makeConsole(
        _ transport: ScriptedTransport
    ) -> ConsoleStore {
        ConsoleStore(
            snapshotRetryDelay: .milliseconds(10),
            pins: PinnedAgentsStore(
                defaults: UserDefaults(suiteName: "replay-pins-\(UUID().uuidString)")
                    ?? .standard)
        ) { _, _, subscriptions in
            EventsSession(
                subscriptions: subscriptions, connect: { transport },
                reconnectPolicy: ReconnectPolicy(
                    initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50)),
                keepalive: nil)
        }
    }

    private func blocked(_ status: AgentStatus = .blocked) -> ScriptedTransport {
        ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: status)]))
    }

    @Test func theSamePromptSendsTheKeysOnceWhenTheHostIsBack() async throws {
        let transport = blocked()
        await transport.setPaneReadText(TmuxScreenDetectorTests.claudePermission)
        let console = makeConsole(transport)
        defer { console.setHosts([]) }
        var finished: [BlockedAnswerQueue.Finish] = []
        console.blockedAnswers.onFinished = { _, finish in finished.append(finish) }
        console.setHosts([Host.fixture(id: hostID)])
        console.queueBlockedAnswer(pending(), for: id)

        await console.resume()
        try await pollUntil("the answer should go out") { finished == [.sent] }
        #expect(
            await transport.agentKeyParams == [AgentSendKeysParams(keys: ["enter"], target: "w1:p1")])
        #expect(console.blockedAnswers.entry(for: id) == nil)
    }

    @Test func aChangedPromptSendsNothingAndSaysSo() async throws {
        let transport = blocked()
        await transport.setPaneReadText(
            BlockedPromptAnswererTests.otherPermission)
        let console = makeConsole(transport)
        defer { console.setHosts([]) }
        var finished: [BlockedAnswerQueue.Finish] = []
        console.blockedAnswers.onFinished = { _, finish in finished.append(finish) }
        console.setHosts([Host.fixture(id: hostID)])
        console.queueBlockedAnswer(pending(), for: id)

        await console.resume()
        try await pollUntil("the answer should end unsent") { finished == [.promptChanged] }
        #expect(await transport.agentKeyParams.isEmpty)
    }

    @Test func anAgentThatIsNoLongerBlockedDropsTheAnswerSilently() async throws {
        let transport = blocked(.working)
        await transport.setPaneReadText(TmuxScreenDetectorTests.claudePermission)
        let console = makeConsole(transport)
        defer { console.setHosts([]) }
        var finished: [BlockedAnswerQueue.Finish] = []
        console.blockedAnswers.onFinished = { _, finish in finished.append(finish) }
        console.setHosts([Host.fixture(id: hostID)])
        console.queueBlockedAnswer(pending(), for: id)

        await console.resume()
        try await pollUntil("the answer should be dropped") {
            console.blockedAnswers.entry(for: id) == nil
        }
        #expect(finished.isEmpty)
        #expect(await transport.agentKeyParams.isEmpty)
    }

    @Test func aWithdrawnAnswerSendsNothing() async throws {
        let transport = blocked()
        await transport.setPaneReadText(TmuxScreenDetectorTests.claudePermission)
        let console = makeConsole(transport)
        defer { console.setHosts([]) }
        console.setHosts([Host.fixture(id: hostID)])
        console.queueBlockedAnswer(pending(), for: id)
        console.blockedAnswers.withdraw(agentID: id)

        await console.resume()
        try await pollUntil("the Host should be verified") {
            await !transport.paneReadParams.isEmpty || console.agents.contains { $0.id == id }
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(await transport.agentKeyParams.isEmpty)
    }
}
