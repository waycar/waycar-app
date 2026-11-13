import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Waycar

@MainActor
@Suite("Agent Composer store")
struct AgentComposerStoreTests {
    @Test func typingStaysLocalAndSendUsesOnePromptRPC() async throws {
        let transport = ScriptedTransport()
        let promptGate = ScriptedTransportCallGate()
        await transport.gateNextAgentPrompt(using: promptGate)
        let store = AgentComposerStore(target: "w1:p1") { params in
            try await transport.promptAgent(params)
        }

        store.replaceDraft(with: "Fix the failing tests")

        #expect(store.draft == "Fix the failing tests")
        #expect(await transport.agentPromptParams.isEmpty)

        let send = Task { await store.send() }
        try await waitUntil("the prompt should be waiting for its acknowledgment") {
            await promptGate.entryCount == 1
        }

        #expect(store.draft.isEmpty)
        #expect(store.messages.map(\.text) == ["Fix the failing tests"])
        #expect(store.messages.map(\.state) == [.sending])
        #expect(
            await transport.agentPromptParams == [
                AgentPromptParams(target: "w1:p1", text: "Fix the failing tests")
            ])

        await promptGate.open()
        await send.value

        #expect(store.messages.map(\.state) == [.delivered(.acknowledged)])
        #expect(await transport.agentPromptParams.count == 1)
    }

    @Test func statusPushesAdvanceAcknowledgedMessageFromWorkingToDone() async throws {
        let transport = ScriptedTransport()
        let (updates, continuation) = AsyncStream.makeStream(
            of: ConsoleStore.AgentStatusUpdate.self)
        let store = AgentComposerStore(
            target: "w1:p1", statusUpdates: updates
        ) { params in
            try await transport.promptAgent(params)
        }
        store.open()
        store.replaceDraft(with: "Continue")

        await store.send()
        #expect(store.messages.map(\.state) == [.delivered(.acknowledged)])

        continuation.yield(
            ConsoleStore.AgentStatusUpdate(status: .working, liveUpdatesAvailable: true))
        try await waitUntil("Working should come from the status stream") {
            store.messages.map(\.state) == [.delivered(.working)]
        }

        continuation.yield(
            ConsoleStore.AgentStatusUpdate(status: .done, liveUpdatesAvailable: true))
        try await waitUntil("Done should come from the status stream") {
            store.messages.map(\.state) == [.delivered(.done)]
        }

        #expect(await transport.agentPromptParams.count == 1)
        #expect(await transport.agentPromptParams.first?.wait == nil)
        continuation.finish()
    }

    @Test func queuedMessageWaitsForItsOwnWorkingPhaseBeforeDone() async {
        let transport = ScriptedTransport()
        let store = AgentComposerStore(target: "w1:p1") { params in
            try await transport.promptAgent(params)
        }
        store.replaceDraft(with: "First message")
        await store.send()
        store.agentStatusDidChange(.working)

        store.replaceDraft(with: "Queued message")
        await store.send()

        #expect(
            store.messages.map(\.state)
                == [.delivered(.working), .delivered(.agentBusy)])

        store.agentStatusDidChange(.done)
        #expect(
            store.messages.map(\.state)
                == [.delivered(.done), .delivered(.agentBusy)])

        store.agentStatusDidChange(.working)
        #expect(
            store.messages.map(\.state)
                == [.delivered(.done), .delivered(.working)])

        store.agentStatusDidChange(.done)
        #expect(
            store.messages.map(\.state)
                == [.delivered(.done), .delivered(.done)])
        #expect(await transport.agentPromptParams.count == 2)
    }

    @Test func queuedMessageStaysBusyWhenPriorWorkFinishesBeforeAcknowledgment() async throws {
        let transport = ScriptedTransport()
        let promptGate = ScriptedTransportCallGate()
        let store = AgentComposerStore(target: "w1:p1", initialStatus: .working) { params in
            try await transport.promptAgent(params)
        }
        await transport.gateNextAgentPrompt(using: promptGate)
        store.replaceDraft(with: "Queued message")
        let send = Task { await store.send() }
        try await waitUntil("the queued prompt should be in flight") {
            await promptGate.entryCount == 1
        }

        store.agentStatusDidChange(.done)
        await promptGate.open()
        await send.value

        #expect(store.messages.map(\.state) == [.delivered(.agentBusy)])
    }

    @Test func idleEndsAWorkingMessage() async {
        let transport = ScriptedTransport()
        let store = AgentComposerStore(target: "w1:p1") { params in
            try await transport.promptAgent(params)
        }
        store.replaceDraft(with: "Interrupt this")
        await store.send()
        store.agentStatusDidChange(.working)

        store.agentStatusDidChange(.idle)

        #expect(store.messages.map(\.state) == [.delivered(.done)])
        #expect(await transport.agentPromptParams.count == 1)
    }

    @Test func sendingWhileWorkingAcknowledgesThatTheAgentIsBusy() async {
        let transport = ScriptedTransport()
        let store = AgentComposerStore(target: "w1:p1", initialStatus: .working) { params in
            try await transport.promptAgent(params)
        }
        store.replaceDraft(with: "Queue this next")

        await store.send()

        #expect(store.messages.map(\.state) == [.delivered(.agentBusy)])
        #expect(await transport.agentPromptParams.count == 1)
    }

    @Test func priorDoneStatusDoesNotClaimThatANewMessageIsDone() async {
        let transport = ScriptedTransport()
        let store = AgentComposerStore(target: "w1:p1", initialStatus: .done) { params in
            try await transport.promptAgent(params)
        }
        store.replaceDraft(with: "One more request")

        await store.send()

        #expect(store.messages.map(\.state) == [.delivered(.acknowledged)])
    }

    @Test func statusArrivingBeforeAcknowledgmentIsAppliedAfterDelivery() async throws {
        let transport = ScriptedTransport()
        let promptGate = ScriptedTransportCallGate()
        await transport.gateNextAgentPrompt(using: promptGate)
        let store = AgentComposerStore(target: "w1:p1") { params in
            try await transport.promptAgent(params)
        }
        store.replaceDraft(with: "Start now")
        let send = Task { await store.send() }
        try await waitUntil("the prompt should be in flight") {
            await promptGate.entryCount == 1
        }

        store.agentStatusDidChange(.working)
        await promptGate.open()
        await send.value

        #expect(store.messages.map(\.state) == [.delivered(.working)])
    }

    @Test func failedSendCanRetryWithoutLosingItsText() async throws {
        let transport = ScriptedTransport()
        await transport.setAgentPromptFailure(TransportError.timedOut)
        let store = AgentComposerStore(target: "w1:p1") { params in
            try await transport.promptAgent(params)
        }
        store.replaceDraft(with: "Please retry this")
        await store.send()
        let message = try #require(store.messages.first)

        #expect(
            message.state
                == .failed("The Host did not answer. Check the connection and retry."))
        #expect(message.text == "Please retry this")

        await transport.setAgentPromptFailure(nil)
        let retryGate = ScriptedTransportCallGate()
        await transport.gateNextAgentPrompt(using: retryGate)
        let retry = Task { await store.retry(message.id) }
        try await waitUntil("retry should return to Sending") {
            await retryGate.entryCount == 1 && store.messages.first?.state == .sending
        }
        await retryGate.open()
        await retry.value

        #expect(store.messages.first?.text == "Please retry this")
        #expect(store.messages.first?.state == .delivered(.acknowledged))
        #expect(await transport.agentPromptParams.count == 2)
    }

    @Test func withdrawingFailurePreservesTheFailedTextAndNewDraft() async throws {
        let transport = ScriptedTransport()
        await transport.setAgentPromptFailure(
            TransportError.sshUnreachable(detail: "connection dropped"))
        let store = AgentComposerStore(target: "w1:p1") { params in
            try await transport.promptAgent(params)
        }
        store.replaceDraft(with: "Earlier message")
        await store.send()
        let failedID = try #require(store.messages.first?.id)
        store.replaceDraft(with: "New thought")

        store.withdrawToDraft(failedID)

        #expect(store.messages.isEmpty)
        #expect(store.draft == "Earlier message\nNew thought")
        #expect(await transport.agentPromptParams.count == 1)
    }

    @Test func withdrawingFailurePutsTheCaretAfterTheRestoredText() async throws {
        let transport = ScriptedTransport()
        await transport.setAgentPromptFailure(
            TransportError.sshUnreachable(detail: "connection dropped"))
        let store = AgentComposerStore(target: "w1:p1") { params in
            try await transport.promptAgent(params)
        }
        let restored = "Café 👋"
        store.replaceDraft(with: restored)
        await store.send()
        let firstID = try #require(store.messages.first?.id)
        store.withdrawToDraft(firstID)
        #expect(store.draft == restored)
        #expect(store.draftSelection
            == NSRange(location: (restored as NSString).length, length: 0))

        await store.send()
        let secondID = try #require(store.messages.first?.id)
        store.replaceDraft(with: "New thought")
        store.withdrawToDraft(secondID)
        let expected = "\(restored)\nNew thought"
        #expect(store.draft == expected)
        #expect(store.draftSelection
            == NSRange(location: (expected as NSString).length, length: 0))
    }

    // MARK: Review Prompt hooks

    @Test func anAgentComposerFiresTheDeliveredHookOncePerAcceptedMessage() async {
        let transport = ScriptedTransport()
        let store = AgentComposerStore(target: "w1:p1") { params in
            try await transport.promptAgent(params)
        }
        var delivered = 0
        store.onAgentMessageDelivered = { delivered += 1 }

        store.replaceDraft(with: "one")
        await store.send()
        #expect(delivered == 1)
        store.replaceDraft(with: "two")
        await store.send()
        #expect(delivered == 2)
    }

    @Test func aShellComposerFiresNeitherHook() async {
        let transport = ScriptedTransport()
        let store = AgentComposerStore(shellPaneID: "w1:p-shell") { params in
            try await transport.sendPaneInput(params)
        }
        var fired = 0
        store.onAgentMessageDelivered = { fired += 1 }
        store.onAgentTurnDone = { fired += 1 }
        store.replaceDraft(with: "git status")

        await store.send()

        #expect(store.messages.map(\.state) == [.delivered(.acknowledged)])
        #expect(fired == 0)
    }

    @Test func aFailedDeliveryFiresNeitherHook() async {
        let transport = ScriptedTransport()
        await transport.setAgentPromptFailure(
            HerdrAPIError(code: "agent_not_found", message: "agent target w1:p1 not found"))
        let store = AgentComposerStore(target: "w1:p1") { params in
            try await transport.promptAgent(params)
        }
        var fired = 0
        store.onAgentMessageDelivered = { fired += 1 }
        store.onAgentTurnDone = { fired += 1 }
        store.replaceDraft(with: "hello")

        #expect(await store.send() == .failed)
        #expect(fired == 0)
    }

    @Test func theTurnDoneHookFiresOncePerMessageAndNotOnRepeatObservations() async throws {
        let transport = ScriptedTransport()
        let feed = CountedStatusFeed()
        let store = AgentComposerStore(target: "w1:p1", statusUpdates: feed.updates) { params in
            try await transport.promptAgent(params)
        }
        var done = 0
        store.onAgentTurnDone = { done += 1 }
        store.open()
        store.replaceDraft(with: "Continue")
        await store.send()
        #expect(done == 0)

        for status in [AgentStatus.working, .done, .done, .done] {
            feed.yield(status)
        }
        try await waitUntil("the message should reach Done") {
            store.messages.map(\.state) == [.delivered(.done)]
        }
        // One more repeat, then wait until the Composer has handled every
        // update it was given and is asking for the next.
        feed.yield(.done)
        try await waitUntil("the Composer should have handled every update") { feed.isDrained }
        #expect(done == 1)
        feed.finish()
    }

    /// herdr refuses `agent.prompt` on a plain shell, so a shell row's
    /// Send types the draft and Enter in one atomic `pane.send_input`.
    @Test func shellComposerSendRunsTheDraftThroughPaneInput() async throws {
        let transport = ScriptedTransport()
        let store = AgentComposerStore(shellPaneID: "w1:p-shell") { params in
            try await transport.sendPaneInput(params)
        }
        store.replaceDraft(with: "git status")

        let result = await store.send()

        #expect(result == .deliveredViaPaneInput)
        #expect(store.draft.isEmpty)
        #expect(store.messages.map(\.state) == [.delivered(.acknowledged)])
        #expect(
            await transport.paneInputParams == [
                PaneSendInputParams(paneID: "w1:p-shell", keys: ["enter"], text: "git status")
            ])
        #expect(await transport.agentPromptParams.isEmpty)
    }

    /// herdr 0.8.0+ answers `agent.start` while the pane's agent is still
    /// booting, so the first prompt of a freshly started Agent is rejected
    /// with `agent_not_ready` ("agent wX:pY is not an active named agent")
    /// until the agent registers. The composer waits that launch out instead
    /// of surfacing the refusal.
    @Test func firstSendToAFreshAgentWaitsOutAgentNotReadyRejections() async throws {
        let transport = ScriptedTransport()
        let notReady = HerdrAPIError(
            code: "agent_not_ready",
            message: "agent w15:p1 is not an active named agent")
        await transport.setAgentPromptFailures([notReady, notReady])
        let store = AgentComposerStore(
            target: "w15:p1", agentNotReadyRetryDelay: .milliseconds(5)
        ) { params in
            try await transport.promptAgent(params)
        }
        store.replaceDraft(with: "First message")

        let result = await store.send()

        #expect(result == .deliveredViaPrompt)
        #expect(store.draft.isEmpty)
        #expect(store.messages.map(\.state) == [.delivered(.acknowledged)])
        #expect(await transport.agentPromptParams.count == 3)
        #expect(
            await transport.agentPromptParams.allSatisfy { $0 == AgentPromptParams(
                target: "w15:p1", text: "First message") })
    }

    /// The wait is bounded: an agent that never becomes active still
    /// surfaces herdr's refusal as a retryable failure once the budget is
    /// spent, and the budget keeps retrying past a first refusal.
    @Test func agentNotReadyRetryExhaustionSurfacesTheRefusalWithAttemptsLeft() async throws {
        let transport = ScriptedTransport()
        await transport.setAgentPromptFailure(
            HerdrAPIError(
                code: "agent_not_ready",
                message: "agent w15:p1 is not an active named agent"))
        let store = AgentComposerStore(
            target: "w15:p1",
            agentNotReadyRetryDelay: .milliseconds(5),
            agentNotReadyRetryBudget: .milliseconds(20)
        ) { params in
            try await transport.promptAgent(params)
        }
        store.replaceDraft(with: "Stuck launch")

        let result = await store.send()

        #expect(result == .failed)
        #expect(
            store.messages.map(\.state)
                == [.failed("herdr rejected the message: agent w15:p1 is not an active named agent")]
        )
        #expect(await transport.agentPromptParams.count > 1)
        #expect(store.messages.first?.text == "Stuck launch")
    }

    /// 0.9.1 also returns `agent_not_found` transiently on a freshly created
    /// pane ("agent target wX:pY not found") during the same registration
    /// window as `agent_not_ready`, so it is waited out with the same
    /// budget; a target that never registers surfaces the refusal at the
    /// budget's end.
    @Test func agentNotFoundOnAFreshPaneIsWaitedOutWithTheSameBudget() async throws {
        let transport = ScriptedTransport()
        await transport.setAgentPromptFailure(
            HerdrAPIError(code: "agent_not_found", message: "agent target w15:p1 not found"))
        let store = AgentComposerStore(
            target: "w15:p1",
            agentNotReadyRetryDelay: .milliseconds(5),
            agentNotReadyRetryBudget: .milliseconds(20)
        ) { params in
            try await transport.promptAgent(params)
        }
        store.replaceDraft(with: "Wrong target")

        let result = await store.send()

        #expect(result == .failed)
        #expect(
            store.messages.map(\.state)
                == [.failed("herdr rejected the message: agent target w15:p1 not found")])
        #expect(await transport.agentPromptParams.count > 1)
    }

    /// A launch herdr leaves pending refuses the prompt API for the whole
    /// budget. With the Attach live, the composer retries inside the budget
    /// and on exhaustion types the draft into the PTY without Enter:
    /// `agent_not_ready` does not prove the agent's input is on screen, so
    /// the user submits it themselves.
    @Test func persistentNotReadyWithLiveAttachTypesTheDraftWithoutSubmitting() async throws {
        let transport = ScriptedTransport()
        await transport.setAgentPromptFailure(
            HerdrAPIError(
                code: "agent_not_ready",
                message: "agent w15:p1 is not an active named agent"))
        var writes: [Data] = []
        let input = TerminalInputController()
        _ = input.beginSession { writes.append($0) }
        let store = AgentComposerStore(
            target: "w15:p1",
            agentNotReadyRetryDelay: .milliseconds(5),
            agentNotReadyRetryBudget: .milliseconds(40)
        ) { params in
            try await transport.promptAgent(params)
        }
        store.bindAttachInput(input)
        store.replaceDraft(with: "Stuck launch")

        let result = await store.send()

        #expect(result == .deliveredViaAttach)
        #expect(store.draft.isEmpty)
        #expect(writes.contains(Data("Stuck launch".utf8)))
        #expect(!writes.contains(Data([0x0D])))
        #expect(await transport.agentPromptParams.count > 1)
    }

    /// `agent_not_found` at the budget's end means herdr knows no agent in
    /// the pane, which may have fallen back to its shell: text typed there
    /// is one Enter away from running as a command, so the message fails
    /// instead of reaching the PTY.
    @Test func persistentNotFoundWithLiveAttachFailsWithoutTypingIntoThePTY() async throws {
        let transport = ScriptedTransport()
        await transport.setAgentPromptFailure(
            HerdrAPIError(code: "agent_not_found", message: "agent target w15:p1 not found"))
        var writes: [Data] = []
        let input = TerminalInputController()
        _ = input.beginSession { writes.append($0) }
        let store = AgentComposerStore(
            target: "w15:p1",
            agentNotReadyRetryDelay: .milliseconds(5),
            agentNotReadyRetryBudget: .milliseconds(40)
        ) { params in
            try await transport.promptAgent(params)
        }
        store.bindAttachInput(input)
        store.replaceDraft(with: "rm -rf build")

        let result = await store.send()

        #expect(result == .failed)
        #expect(
            store.messages.map(\.state)
                == [.failed("herdr rejected the message: agent target w15:p1 not found")])
        #expect(!writes.contains(Data("rm -rf build".utf8)))
        #expect(!writes.contains(Data([0x0D])))
        #expect(await transport.agentPromptParams.count > 1)
    }

    /// Until the agent's input is on screen an LF may be taken as Enter, so
    /// even `agent_not_ready` does not fall back to the PTY for text with a
    /// line break.
    @Test func persistentNotReadyWithLiveAttachFailsAMultiLineDraft() async throws {
        let transport = ScriptedTransport()
        await transport.setAgentPromptFailure(
            HerdrAPIError(
                code: "agent_not_ready",
                message: "agent w15:p1 is not an active named agent"))
        var writes: [Data] = []
        let input = TerminalInputController()
        _ = input.beginSession { writes.append($0) }
        let store = AgentComposerStore(
            target: "w15:p1",
            agentNotReadyRetryDelay: .milliseconds(5),
            agentNotReadyRetryBudget: .milliseconds(40)
        ) { params in
            try await transport.promptAgent(params)
        }
        store.bindAttachInput(input)
        store.replaceDraft(with: "first\nsecond")

        let result = await store.send()

        #expect(result == .failed)
        #expect(
            store.messages.map(\.state)
                == [.failed("herdr rejected the message: agent w15:p1 is not an active named agent")]
        )
        #expect(!writes.contains(Data("first\nsecond".utf8)))
        #expect(!writes.contains(Data([0x0D])))
        #expect(await transport.agentPromptParams.count > 1)
    }

    /// A claude launch in an untrusted folder stops on its trust dialog,
    /// which herdr reports as `blocked` while `agent.prompt` still answers
    /// `agent_not_ready`. A status push during the retry keeps the fallback
    /// out of the dialog entirely: typing could pick one of its choices, so
    /// the message fails and asks the user to answer the question first.
    @Test func persistentNotReadyTurnedBlockedFailsWithoutTypingIntoTheDialog() async throws {
        let transport = ScriptedTransport()
        await transport.setAgentPromptFailure(
            HerdrAPIError(
                code: "agent_not_ready",
                message: "agent w15:p1 is not an active named agent"))
        let (updates, continuation) = AsyncStream.makeStream(
            of: ConsoleStore.AgentStatusUpdate.self)
        var writes: [Data] = []
        let input = TerminalInputController()
        _ = input.beginSession { writes.append($0) }
        let store = AgentComposerStore(
            target: "w15:p1",
            statusUpdates: updates,
            agentNotReadyRetryDelay: .milliseconds(5),
            agentNotReadyRetryBudget: .milliseconds(40)
        ) { params in
            continuation.yield(
                ConsoleStore.AgentStatusUpdate(status: .blocked, liveUpdatesAvailable: true))
            return try await transport.promptAgent(params)
        }
        store.open()
        store.bindAttachInput(input)
        store.replaceDraft(with: "Trust this folder?")

        let result = await store.send()

        #expect(result == .failed)
        #expect(
            store.messages.map(\.state)
                == [
                    .failed(
                        "The Agent is asking a question. Answer it in the terminal, then send again."
                    )
                ])
        #expect(!writes.contains(Data("Trust this folder?".utf8)))
        #expect(!writes.contains(Data([0x0D])))
        continuation.finish()
    }

    /// The trust dialog can turn the Agent Blocked while its launch still
    /// answers `agent_not_ready`; once the live status reads Blocked the
    /// composer stops retrying, since another attempt could land in the
    /// dialog.
    @Test func notReadyRetryStopsOnceTheAgentTurnsBlocked() async throws {
        let transport = ScriptedTransport()
        await transport.setAgentPromptFailure(
            HerdrAPIError(
                code: "agent_not_ready",
                message: "agent w15:p1 is not an active named agent"))
        let flip = ComposerStatusFlip()
        let store = AgentComposerStore(
            target: "w15:p1",
            agentNotReadyRetryDelay: .milliseconds(5),
            agentNotReadyRetryBudget: .seconds(2)
        ) { params in
            do {
                return try await transport.promptAgent(params)
            } catch {
                await flip.block()
                throw error
            }
        }
        flip.store = store
        store.replaceDraft(with: "Start on the tests")

        let result = await store.send()

        #expect(result == .failed)
        #expect(await transport.agentPromptParams.count == 1)
    }

    /// With no live Attach there is nowhere to fall back to; the retry loop
    /// runs to the budget and the message fails.
    @Test func persistentNotReadyWithoutAttachFails() async throws {
        let transport = ScriptedTransport()
        await transport.setAgentPromptFailure(
            HerdrAPIError(
                code: "agent_not_ready",
                message: "agent w15:p1 is not an active named agent"))
        let store = AgentComposerStore(
            target: "w15:p1",
            agentNotReadyRetryDelay: .milliseconds(5),
            agentNotReadyRetryBudget: .milliseconds(20)
        ) { params in
            try await transport.promptAgent(params)
        }
        store.replaceDraft(with: "No attach yet")

        let result = await store.send()

        #expect(result == .failed)
        #expect(await transport.agentPromptParams.count > 1)
    }

    /// The Transport holds an opencode launch's prompts until its input box
    /// is on screen (`AgentInputNotReadyError`), which can outlast the
    /// plain budget by far: the composer keeps retrying until the gate's
    /// `opensAt`, and the message is delivered once the gate lets it out.
    @Test func inputGateHoldsAreRetriedPastThePlainBudgetUntilDelivered() async throws {
        let transport = ScriptedTransport()
        let held = AgentInputNotReadyError(
            kind: "opencode", target: "w15:p1", opensAt: ContinuousClock.now + .seconds(30))
        await transport.setAgentPromptFailures([held, held, held])
        let store = AgentComposerStore(
            target: "w15:p1",
            agentNotReadyRetryDelay: .milliseconds(5),
            agentNotReadyRetryBudget: .milliseconds(1)
        ) { params in
            try await transport.promptAgent(params)
        }
        store.replaceDraft(with: "First message")

        let result = await store.send()

        #expect(result == .deliveredViaPrompt)
        #expect(store.draft.isEmpty)
        #expect(store.messages.map(\.state) == [.delivered(.acknowledged)])
        #expect(await transport.agentPromptParams.count == 4)
    }

    /// A hold that outlasts its own `opensAt` fails visibly and keeps the
    /// text. It never falls back to the Attach the way `agent_not_ready`
    /// does: the hold means the TUI drops typed input, so the draft would
    /// be lost there the same way.
    @Test func inputGateExhaustionFailsWithoutTypingIntoTheAttach() async throws {
        let transport = ScriptedTransport()
        let opensAt = ContinuousClock.now + .milliseconds(30)
        await transport.setAgentPromptFailure(
            AgentInputNotReadyError(kind: "opencode", target: "w15:p1", opensAt: opensAt))
        var writes: [Data] = []
        let input = TerminalInputController()
        _ = input.beginSession { writes.append($0) }
        let store = AgentComposerStore(
            target: "w15:p1",
            agentNotReadyRetryDelay: .milliseconds(5),
            agentNotReadyRetryBudget: .milliseconds(1)
        ) { params in
            try await transport.promptAgent(params)
        }
        store.bindAttachInput(input)
        store.replaceDraft(with: "Too early")

        let result = await store.send()

        #expect(result == .failed)
        #expect(
            store.messages.map(\.state)
                == [.failed("OpenCode is still starting. Try again in a moment.")])
        #expect(ContinuousClock.now >= opensAt)
        #expect(await transport.agentPromptParams.count > 1)
        #expect(writes.isEmpty)
        let failed = try #require(store.messages.first)
        store.withdrawToDraft(failed.id)
        #expect(store.draft == "Too early")
    }

    /// An Agent on its sign-in screen (cursor, devin, kiro): the refusal is
    /// shown at once, not retried, and nothing reaches the Attach, where
    /// the text and Enter would drive the login too.
    @Test func signInRefusalFailsAtOnceWithoutTypingIntoTheAttach() async throws {
        let transport = ScriptedTransport()
        await transport.setAgentPromptFailure(
            AgentSignInRequiredError(kind: "cursor", target: "w15:p1"))
        var writes: [Data] = []
        let input = TerminalInputController()
        _ = input.beginSession { writes.append($0) }
        let store = AgentComposerStore(target: "w15:p1") { params in
            try await transport.promptAgent(params)
        }
        store.bindAttachInput(input)
        store.replaceDraft(with: "hello")

        let result = await store.send()

        #expect(result == .failed)
        #expect(
            store.messages.map(\.state)
                == [.failed("Sign in to Cursor Agent on the Host first.")])
        #expect(await transport.agentPromptParams.count == 1)
        #expect(writes.isEmpty)
    }

    /// An Agent on its folder-trust dialog (grok, gemini, qwen): the refusal
    /// is shown at once, not retried, and nothing reaches the Attach, where
    /// grok takes a typed `y` as "trust" and `n` as "quit".
    @Test func folderTrustRefusalFailsAtOnceWithoutTypingIntoTheAttach() async throws {
        let transport = ScriptedTransport()
        await transport.setAgentPromptFailure(
            AgentFolderTrustRequiredError(kind: "grok", target: "w15:p1"))
        var writes: [Data] = []
        let input = TerminalInputController()
        _ = input.beginSession { writes.append($0) }
        let store = AgentComposerStore(target: "w15:p1") { params in
            try await transport.promptAgent(params)
        }
        store.bindAttachInput(input)
        store.replaceDraft(with: "yes, hello")

        let result = await store.send()

        #expect(result == .failed)
        #expect(
            store.messages.map(\.state)
                == [.failed(
                    "Grok Build asks whether to trust this folder. Answer it in the terminal, then send again.")])
        #expect(await transport.agentPromptParams.count == 1)
        #expect(writes.isEmpty)
    }

    /// tmux reads grok's, gemini's, qwen's and muse's folder-trust dialogs
    /// as Blocked, as herdr does qwen's and muse's: a Blocked send asks the
    /// Transport's screen check first, and its refusal wins over typing
    /// into the Attach, where grok's `n` would quit.
    @Test(arguments: [true, false])
    func blockedScreenRefusalFailsWithoutTypingIntoTheAttach(trustDialog: Bool) async {
        let refusal: any Error = trustDialog
            ? AgentFolderTrustRequiredError(kind: "grok", target: "w15:p1")
            : AgentSignInRequiredError(kind: "muse", target: "w15:p1")
        let transport = ScriptedTransport()
        var writes: [Data] = []
        let input = TerminalInputController()
        _ = input.beginSession { writes.append($0) }
        let store = AgentComposerStore(
            target: "w15:p1", initialStatus: .blocked,
            checkInputScreen: { target in
                #expect(target == "w15:p1")
                throw refusal
            }
        ) { params in
            try await transport.promptAgent(params)
        }
        store.bindAttachInput(input)
        store.replaceDraft(with: "no thanks")

        let result = await store.send()

        #expect(result == .failed)
        #expect(store.messages.map(\.state) == [.failed(AgentComposerStore.message(for: refusal))])
        #expect(writes.isEmpty)
        #expect(await transport.agentPromptParams.isEmpty)
    }

    /// A tool approval's Blocked keeps typing into the Attach once the
    /// screen check finds no sign-in or trust screen, or cannot tell.
    @Test(arguments: [false, true])
    func blockedSendWithNoScreenRefusalStillTypesIntoTheAttach(checkFails: Bool) async {
        let transport = ScriptedTransport()
        var writes: [Data] = []
        let input = TerminalInputController()
        _ = input.beginSession { writes.append($0) }
        let store = AgentComposerStore(
            target: "w1:p1", initialStatus: .blocked,
            checkInputScreen: { _ in if checkFails { throw TransportError.timedOut } }
        ) { params in
            try await transport.promptAgent(params)
        }
        store.bindAttachInput(input)
        store.replaceDraft(with: "n")

        let result = await store.send()

        #expect(result == .deliveredViaAttach)
        #expect(writes == [Data("n".utf8)])
        #expect(await transport.agentPromptParams.isEmpty)
    }

    @Test func reconnectStatusUpdatesDoNotTouchTheLocalDraft() async throws {
        let transport = ScriptedTransport()
        let (updates, continuation) = AsyncStream.makeStream(
            of: ConsoleStore.AgentStatusUpdate.self)
        let store = AgentComposerStore(
            target: "w1:p1", statusUpdates: updates
        ) { params in
            try await transport.promptAgent(params)
        }
        store.open()
        store.replaceDraft(with: "Survive Attach, background, and reconnect")

        continuation.yield(
            ConsoleStore.AgentStatusUpdate(status: nil, liveUpdatesAvailable: false))
        continuation.yield(
            ConsoleStore.AgentStatusUpdate(status: .idle, liveUpdatesAvailable: true))
        try await waitUntil("status recovery should be consumed") {
            await transport.agentPromptParams.isEmpty
        }

        #expect(store.draft == "Survive Attach, background, and reconnect")
        #expect(store.messages.isEmpty)
        #expect(await transport.agentPromptParams.isEmpty)
        continuation.finish()
    }

    @Test func consoleOwnershipPreservesDraftAcrossReconnectViewReplacement() throws {
        let console = ConsoleStore()
        let hostID = try #require(
            UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        let agentBeforeReconnect = makeAgent(hostID: hostID, status: .working)
        let firstStore = console.composerStore(for: agentBeforeReconnect)
        firstStore.replaceDraft(with: "Keep this local draft")

        let agentAfterReconnect = makeAgent(hostID: hostID, status: .idle)
        let replacementStore = console.composerStore(for: agentAfterReconnect)

        #expect(firstStore === replacementStore)
        #expect(replacementStore.draft == "Keep this local draft")
    }

    @Test func sendingWhileBlockedInsertsIntoAttachWithoutEnterOrPrompt() async throws {
        let transport = ScriptedTransport()
        var writes: [Data] = []
        let input = TerminalInputController()
        _ = input.beginSession { writes.append($0) }
        let store = AgentComposerStore(target: "w1:p1", initialStatus: .blocked) {
            params in
            try await transport.promptAgent(params)
        }
        store.bindAttachInput(input)
        store.replaceDraft(with: "n")

        let result = await store.send()

        #expect(result == .deliveredViaAttach)
        #expect(store.draft.isEmpty)
        #expect(store.messages.map(\.text) == ["n"])
        #expect(store.messages.map(\.state) == [.delivered(.acknowledged)])
        #expect(writes == [Data("n".utf8)])
        #expect(!writes.contains { $0.contains(0x0D) })
        #expect(await transport.agentPromptParams.isEmpty)
    }

    @Test func sendingWhileWorkingStillUsesPromptWhenAttachIsLive() async {
        let transport = ScriptedTransport()
        var writes: [Data] = []
        let input = TerminalInputController()
        _ = input.beginSession { writes.append($0) }
        let store = AgentComposerStore(target: "w1:p1", initialStatus: .working) {
            params in
            try await transport.promptAgent(params)
        }
        store.bindAttachInput(input)
        store.replaceDraft(with: "Queue this next")

        let result = await store.send()

        #expect(result == .deliveredViaPrompt)
        #expect(store.messages.map(\.state) == [.delivered(.agentBusy)])
        #expect(writes.isEmpty)
        #expect(await transport.agentPromptParams.count == 1)
        #expect(await transport.agentPromptParams.first?.wait == nil)
    }

    @Test func agentBlockedPromptFallsThroughToAttachInsert() async throws {
        let transport = ScriptedTransport()
        await transport.setAgentPromptFailure(
            HerdrAPIError(code: "agent_blocked", message: "agent is blocked"))
        var writes: [Data] = []
        let input = TerminalInputController()
        _ = input.beginSession { writes.append($0) }
        let store = AgentComposerStore(target: "w1:p1") { params in
            try await transport.promptAgent(params)
        }
        store.bindAttachInput(input)
        store.replaceDraft(with: "approve")

        let result = await store.send()

        #expect(result == .deliveredViaAttach)
        #expect(store.draft.isEmpty)
        #expect(store.messages.map(\.state) == [.delivered(.acknowledged)])
        #expect(writes == [Data("approve".utf8)])
        #expect(
            await transport.agentPromptParams == [
                AgentPromptParams(target: "w1:p1", text: "approve")
            ])
        if case .failed(let detail) = store.messages.first?.state {
            Issue.record("expected Attach delivery, got failure: \(detail)")
        }
    }

    @Test func blockedSendWithoutLiveAttachFailsAndKeepsRetry() async throws {
        let transport = ScriptedTransport()
        let store = AgentComposerStore(target: "w1:p1", initialStatus: .blocked) {
            params in
            try await transport.promptAgent(params)
        }
        store.replaceDraft(with: "n")

        let result = await store.send()

        #expect(result == .failed)
        #expect(await transport.agentPromptParams.isEmpty)
        let message = try #require(store.messages.first)
        #expect(
            message.state
                == .failed("The message could not be sent. Check the connection and retry.")
        )
        #expect(message.text == "n")

        var writes: [Data] = []
        let input = TerminalInputController()
        _ = input.beginSession { writes.append($0) }
        store.bindAttachInput(input)
        let retry = await store.retry(message.id)

        #expect(retry == .deliveredViaAttach)
        #expect(store.messages.first?.state == .delivered(.acknowledged))
        #expect(writes == [Data("n".utf8)])
        #expect(await transport.agentPromptParams.isEmpty)
    }

    /// An answer to a question needs the Agent's terminal, so it is refused,
    /// not queued: queued, it would go out as a new prompt once the question
    /// was answered some other way. With the Host out of reach the refusal
    /// names that reason and keeps the draft, and Retry types it once the
    /// Host and its terminal are back.
    @Test func blockedSendWithTheHostOutOfReachIsRefusedForThatReasonAndRetriesWhenBack() async throws {
        let transport = ScriptedTransport()
        let store = AgentComposerStore(target: "w1:p1", initialStatus: .blocked) {
            params in
            try await transport.promptAgent(params)
        }
        store.setHostReachable(false)
        store.replaceDraft(with: "n")

        let result = await store.send()

        #expect(result == .failed)
        #expect(await transport.agentPromptParams.isEmpty)
        let message = try #require(store.messages.first)
        #expect(message.state == .failed(AgentComposerStore.offlineAttachMessage))
        #expect(!message.isWaiting, "a refused answer never waits in the queue")
        #expect(message.text == "n", "the draft is kept")

        // Back in reach, with the terminal attached again, Retry types it once.
        var writes: [Data] = []
        let input = TerminalInputController()
        _ = input.beginSession { writes.append($0) }
        store.bindAttachInput(input)
        store.setHostReachable(true)
        #expect(await store.retry(message.id) == .deliveredViaAttach)
        #expect(writes == [Data("n".utf8)])
        #expect(await transport.agentPromptParams.isEmpty)

        // Edit Draft puts a refused answer back in the draft.
        store.setHostReachable(false)
        store.replaceDraft(with: "y")
        store.bindAttachInput(nil)
        #expect(await store.send() == .failed)
        let refused = try #require(store.messages.last)
        store.withdrawToDraft(refused.id)
        #expect(store.draft == "y")
    }

    @Test func agentBlockedWithoutLiveAttachDoesNotShowHerdrRejection() async throws {
        let transport = ScriptedTransport()
        await transport.setAgentPromptFailure(
            HerdrAPIError(code: "agent_blocked", message: "agent is blocked"))
        let store = AgentComposerStore(target: "w1:p1") { params in
            try await transport.promptAgent(params)
        }
        store.replaceDraft(with: "n")

        let result = await store.send()

        #expect(result == .failed)
        let message = try #require(store.messages.first)
        #expect(message.text == "n")
        #expect(
            message.state
                == .failed("The message could not be sent. Check the connection and retry.")
        )
        if case .failed(let detail) = message.state {
            #expect(!detail.contains("herdr rejected"))
        }
        #expect(
            await transport.agentPromptParams == [
                AgentPromptParams(target: "w1:p1", text: "n")
            ])

        store.withdrawToDraft(message.id)
        #expect(store.messages.isEmpty)
        #expect(store.draft == "n")
    }

    @Test func blockedSendRejectsUnsafeScalarsWithoutWriting() async throws {
        let transport = ScriptedTransport()
        var writes: [Data] = []
        let input = TerminalInputController()
        _ = input.beginSession { writes.append($0) }
        let store = AgentComposerStore(target: "w1:p1", initialStatus: .blocked) {
            params in
            try await transport.promptAgent(params)
        }
        store.bindAttachInput(input)
        store.replaceDraft(with: "escape\u{1B}[31m")

        let result = await store.send()

        #expect(result == .failed)
        #expect(writes.isEmpty)
        #expect(await transport.agentPromptParams.isEmpty)
        let message = try #require(store.messages.first)
        #expect(
            message.state
                == .failed("The message contains unsafe terminal control characters."))

        store.withdrawToDraft(message.id)
        #expect(store.messages.isEmpty)
        #expect(store.draft == "escape\u{1B}[31m")
    }

    @Test func blockedAttachInsertDoesNotWrapBracketedPaste() async {
        let transport = ScriptedTransport()
        var writes: [Data] = []
        let input = TerminalInputController()
        _ = input.beginSession { writes.append($0) }
        let store = AgentComposerStore(target: "w1:p1", initialStatus: .blocked) {
            params in
            try await transport.promptAgent(params)
        }
        store.bindAttachInput(input)
        store.replaceDraft(with: "first\nsecond")

        let result = await store.send()

        #expect(result == .deliveredViaAttach)
        #expect(writes == [Data("first\nsecond".utf8)])
        #expect(writes.first?.starts(with: TerminalBracketedPaste.start) != true)
    }

    /// A CR submits in a TUI prompt, so a blocked insert normalizes CRLF and
    /// lone CR to LF: the line breaks stay content and nothing is submitted.
    @Test func blockedAttachInsertNormalizesCarriageReturnsToLineFeeds() async {
        let transport = ScriptedTransport()
        var writes: [Data] = []
        let input = TerminalInputController()
        _ = input.beginSession { writes.append($0) }
        let store = AgentComposerStore(target: "w1:p1", initialStatus: .blocked) {
            params in
            try await transport.promptAgent(params)
        }
        store.bindAttachInput(input)
        store.replaceDraft(with: "first\r\nsecond\rthird")

        let result = await store.send()

        #expect(result == .deliveredViaAttach)
        #expect(writes == [Data("first\nsecond\nthird".utf8)])
        #expect(!writes.contains { $0.contains(0x0D) })
    }

    @Test func blockedMultilineDraftIsIndexedOnceAtEnter() async {
        let transport = ScriptedTransport()
        var writes: [Data] = []
        let input = TerminalInputController()
        _ = input.beginSession { writes.append($0) }
        let store = AgentComposerStore(target: "w1:p1", initialStatus: .blocked) {
            params in
            try await transport.promptAgent(params)
        }
        store.bindAttachInput(input)
        let draft = "please approve\nthen continue"
        store.replaceDraft(with: draft)

        let result = await store.send()

        #expect(result == .deliveredViaAttach)
        #expect(writes == [Data(draft.utf8)])
        #expect(input.userMessageIndex.entries.isEmpty)

        #expect(input.send(Data([0x0D])))
        #expect(input.userMessageIndex.entries.map(\.rawText) == [draft])
    }

    @Test func blockedDeliveredEchoDoesNotClaimWorkingFromLaterStatus() async {
        let transport = ScriptedTransport()
        var writes: [Data] = []
        let input = TerminalInputController()
        _ = input.beginSession { writes.append($0) }
        let store = AgentComposerStore(target: "w1:p1", initialStatus: .blocked) {
            params in
            try await transport.promptAgent(params)
        }
        store.bindAttachInput(input)
        store.replaceDraft(with: "n")

        await store.send()
        store.agentStatusDidChange(.working)
        store.agentStatusDidChange(.done)

        #expect(store.messages.map(\.state) == [.delivered(.acknowledged)])
        #expect(await transport.agentPromptParams.isEmpty)
        #expect(writes == [Data("n".utf8)])
    }

    @Test func replaceTrailingTokenSwapsTheTokenAndKeepsTheRest() {
        let store = Self.draftOnlyStore()
        store.replaceDraft(with: "fix this /rev")

        store.replaceTrailingToken("/rev", with: "/code-review ")

        #expect(store.draft == "fix this /code-review ")
    }

    @Test func replaceTrailingTokenLeavesADraftThatNoLongerEndsWithIt() {
        let store = Self.draftOnlyStore()
        store.replaceDraft(with: "/rev then more")

        store.replaceTrailingToken("/rev", with: "/code-review ")

        #expect(store.draft == "/rev then more")
    }

    @Test func replaceTrailingTokenIgnoresAnEmptyToken() {
        let store = Self.draftOnlyStore()
        store.replaceDraft(with: "keep me")

        store.replaceTrailingToken("", with: "/code-review ")

        #expect(store.draft == "keep me")
    }

    @Test func promptDeliveryRecordsTheSubmittedMessageOnce() async {
        let transport = ScriptedTransport()
        let input = TerminalInputController()
        _ = input.beginSession { _ in }
        let store = AgentComposerStore(target: "w1:p1") { params in
            try await transport.promptAgent(params)
        }
        store.bindAttachInput(input)
        store.replaceDraft(with: "Fix the failing tests")

        let result = await store.send()

        #expect(result == .deliveredViaPrompt)
        #expect(input.userMessageIndex.entries.map(\.rawText) == ["Fix the failing tests"])
        #expect(await transport.agentPromptParams.count == 1)
    }

    @Test func failedPromptDoesNotRecordAUserMessage() async {
        let transport = ScriptedTransport()
        await transport.setAgentPromptFailure(TransportError.timedOut)
        let input = TerminalInputController()
        _ = input.beginSession { _ in }
        let store = AgentComposerStore(target: "w1:p1") { params in
            try await transport.promptAgent(params)
        }
        store.bindAttachInput(input)
        store.replaceDraft(with: "Fix the failing tests")

        let result = await store.send()

        #expect(result == .failed)
        #expect(input.userMessageIndex.entries.isEmpty)
    }

    @Test func blockedAttachInsertIsIndexedOnEnterNotTwice() async {
        let transport = ScriptedTransport()
        var writes: [Data] = []
        let input = TerminalInputController()
        _ = input.beginSession { writes.append($0) }
        let store = AgentComposerStore(target: "w1:p1", initialStatus: .blocked) {
            params in
            try await transport.promptAgent(params)
        }
        store.bindAttachInput(input)
        store.replaceDraft(with: "please approve the refactor")

        let result = await store.send()

        #expect(result == .deliveredViaAttach)
        #expect(writes == [Data("please approve the refactor".utf8)])
        #expect(input.userMessageIndex.entries.isEmpty)
        #expect(await transport.agentPromptParams.isEmpty)

        #expect(input.send(Data([0x0D])))
        #expect(
            input.userMessageIndex.entries.map(\.rawText)
                == ["please approve the refactor"])
    }

    @Test func promptDeliveryDoesNotRecordIntoAReplacementSession() async throws {
        let transport = ScriptedTransport()
        let promptGate = ScriptedTransportCallGate()
        await transport.gateNextAgentPrompt(using: promptGate)
        let input = TerminalInputController()
        let generationA = input.beginSession { _ in }
        let store = AgentComposerStore(target: "w1:p1") { params in
            try await transport.promptAgent(params)
        }
        store.bindAttachInput(input)
        store.replaceDraft(with: "Fix the failing tests")

        let send = Task { await store.send() }
        try await waitUntil("the prompt should be waiting for its acknowledgment") {
            await promptGate.entryCount == 1
        }

        input.detachSessionForReplacement()
        input.endSession(generationA, preservingPendingPaste: true)
        _ = input.beginSession { _ in }
        #expect(input.userMessageIndex.entries.isEmpty)

        await promptGate.open()
        let result = await send.value

        #expect(result == .deliveredViaPrompt)
        #expect(input.userMessageIndex.entries.isEmpty)

        store.replaceDraft(with: "rewrite the matching tests")
        #expect(await store.send() == .deliveredViaPrompt)
        #expect(
            input.userMessageIndex.entries.map(\.rawText)
                == ["rewrite the matching tests"])
    }

    @Test func blockedDraftEscapeCancelsTheIndexedLine() async {
        let transport = ScriptedTransport()
        let input = TerminalInputController()
        _ = input.beginSession { _ in }
        let store = AgentComposerStore(target: "w1:p1", initialStatus: .blocked) {
            params in
            try await transport.promptAgent(params)
        }
        store.bindAttachInput(input)
        store.replaceDraft(with: "please approve the refactor")

        #expect(await store.send() == .deliveredViaAttach)
        #expect(input.userMessageIndex.entries.isEmpty)
        #expect(input.sendEscapeKey())
        #expect(input.send(Data([0x0D])))
        #expect(input.userMessageIndex.entries.isEmpty)
    }

    @Test func textDropInsertsAtTheCaretWithoutSubmitting() async {
        let transport = ScriptedTransport()
        let store = AgentComposerStore(target: "w1:p1") { params in
            try await transport.promptAgent(params)
        }
        store.replaceDraft(with: "Hello World")
        store.setDraftSelection(NSRange(location: 6, length: 0))

        store.acceptDrop([.text("there ")])

        #expect(store.draft == "Hello there World")
        #expect(store.draftSelection == NSRange(location: 12, length: 0))
        #expect(store.messages.isEmpty)
        #expect(await transport.agentPromptParams.isEmpty)
    }

    @Test func textDropReplacesTheCurrentSelectionWithoutSubmitting() async {
        let transport = ScriptedTransport()
        let store = AgentComposerStore(target: "w1:p1") { params in
            try await transport.promptAgent(params)
        }
        store.replaceDraft(with: "Hello World")
        store.setDraftSelection(NSRange(location: 6, length: 5))

        store.acceptDrop([.text("iPad")])

        #expect(store.draft == "Hello iPad")
        #expect(store.messages.isEmpty)
        #expect(await transport.agentPromptParams.isEmpty)
    }

    @Test func snippetInsertPathPutsTextAtTheCaretWithoutSending() async {
        let transport = ScriptedTransport()
        let store = AgentComposerStore(target: "w1:p1") { params in
            try await transport.promptAgent(params)
        }
        store.replaceDraft(with: "ab")
        store.setDraftSelection(NSRange(location: 1, length: 0))

        store.insertIntoDraft("X")

        #expect(store.draft == "aXb")
        #expect(store.messages.isEmpty)
        #expect(await transport.agentPromptParams.isEmpty)
    }

    @Test func promptAppendsReadyPathsToTheTypedText() {
        let cases: [(text: String, paths: [String], expected: String)] = [
            ("", [], ""),
            ("hi", [], "hi"),
            ("", ["/a.jpg"], "/a.jpg "),
            ("", ["/a.jpg", "/b.jpg"], "/a.jpg /b.jpg "),
            ("look", ["/a.jpg"], "look /a.jpg"),
            ("look ", ["/a.jpg", "/b.jpg"], "look /a.jpg /b.jpg"),
            ("look\n", ["/a.jpg"], "look\n/a.jpg"),
            ("   ", ["/a.jpg"], "/a.jpg "),
        ]
        for (text, paths, expected) in cases {
            #expect(
                AgentComposerStore.prompt(text: text, paths: paths) == expected,
                "prompt(text: \(text.debugDescription), paths: \(paths))")
        }
    }

    @Test func imageDropsJoinTheTrayInDropOrderAndTextGoesToTheCaret() async throws {
        let gate = ScriptedTransportCallGate()
        let fixture = try Self.makeDropStagingFixture(
            remotePaths: ["/tmp/waycar-drop-a.jpg", "/tmp/waycar-drop-b.jpg"],
            stageGate: gate)
        defer { fixture.cleanup() }
        let secondImage = Data([0xFF, 0xD8, 0xFF, 0x02])
        fixture.store.replaceDraft(with: "ab")
        fixture.store.setDraftSelection(NSRange(location: 1, length: 0))

        fixture.store.acceptDrop([
            .text("first "),
            .image(fixture.droppedImageData, suggestedName: "a.png"),
            .text("second "),
            .image(secondImage, suggestedName: "b.png"),
        ])

        #expect(fixture.store.draft == "afirst second b")
        #expect(fixture.store.tray.items.map(\.kind) == [.image, .image])
        #expect(fixture.store.messages.isEmpty)

        await gate.open()
        try await waitUntil("both images should become ready") {
            fixture.store.tray.readyPaths.count == 2
        }

        #expect(
            fixture.store.tray.readyPaths == ["/tmp/waycar-drop-a.jpg", "/tmp/waycar-drop-b.jpg"])
        #expect(fixture.store.draft == "afirst second b")
        #expect(
            await fixture.preparer.loadedSelections()
                == [fixture.droppedImageData, secondImage])
        #expect(await fixture.transport.agentPromptParams.isEmpty)
    }

    @Test func emptyAndUnsupportedDropsChangeNeitherDraftNorTray() async throws {
        let fixture = try Self.makeDropStagingFixture()
        defer { fixture.cleanup() }
        fixture.store.replaceDraft(with: "Keep me")
        let selection = fixture.store.draftSelection

        fixture.store.acceptDrop([
            .text(""),
            .unsupported,
            .image(Data(), suggestedName: "empty.png"),
        ])

        #expect(fixture.store.draft == "Keep me")
        #expect(fixture.store.draftSelection == selection)
        #expect(fixture.store.tray.isEmpty)
        #expect(fixture.store.messages.isEmpty)
        #expect(fixture.staging.state == .idle)
        #expect(await fixture.preparer.loadedSelections().isEmpty)
    }

    @Test func attachStoreStagesDroppedImagesIntoTheTray() async throws {
        let store = Self.draftOnlyStore()
        let jpeg = try Self.tinyJPEGData()
        let attach = AgentAttachStore(
            target: .agentPane("w1:p1"),
            transportGeneration: nil,
            recordsNetworkTelemetry: true,
            isOnStage: { true },
            runTerminal: { _, _ in },
            stageImage: { _, _ in try StagedImage(path: "/tmp/waycar-drop.jpg") },
            stageFile: { _, _ in try StagedFile(path: "/tmp/waycar-drop.txt") },
            composer: store,
            closePane: {})
        // The detail view binds the Attach on screen; the store itself does not.
        store.bindStaging(attach.staging)

        store.acceptDrop([.image(jpeg, suggestedName: "x.jpg")])
        try await waitUntil("the drop should stage on the Attach") {
            store.tray.readyPaths == ["/tmp/waycar-drop.jpg"]
        }

        #expect(store.draft.isEmpty)
        #expect(store.messages.isEmpty)
        #expect(attach.staging.state == .idle)
    }

    @Test func pastedFileJoinsTheTrayAndItsCopyGoesOnceStaged() async throws {
        let store = Self.draftOnlyStore()
        let attach = AgentAttachStore(
            target: .agentPane("w1:p1"),
            transportGeneration: nil,
            recordsNetworkTelemetry: true,
            isOnStage: { true },
            runTerminal: { _, _ in },
            stageImage: { _, _ in try StagedImage(path: "/tmp/waycar-paste.jpg") },
            stageFile: { _, _ in try StagedFile(path: "/tmp/waycar-paste.pdf") },
            composer: store,
            closePane: {})
        store.bindStaging(attach.staging)
        let copy = try Self.localCopy(named: "report.pdf")

        store.acceptDrop([.file(copy)])

        #expect(store.tray.items.map(\.kind) == [.file(name: "report.pdf")])
        try await waitUntil("the pasted file should stage") {
            store.tray.readyPaths == ["/tmp/waycar-paste.pdf"]
        }
        #expect(!FileManager.default.fileExists(atPath: copy.deletingLastPathComponent().path))
        #expect(store.draft.isEmpty)
    }

    @Test func pastedFilePastTheTrayCapacityLosesItsCopy() throws {
        let store = Self.draftOnlyStore()
        let image = try Self.tinyJPEGData()
        store.acceptDrop(Array(
            repeating: .image(image, suggestedName: nil), count: ComposerTray.capacity))
        let copy = try Self.localCopy(named: "late.pdf")

        store.acceptDrop([.file(copy)])

        #expect(store.tray.items.count == ComposerTray.capacity)
        #expect(store.tray.notice != nil)
        #expect(!FileManager.default.fileExists(atPath: copy.deletingLastPathComponent().path))
    }

    /// A file in `ComposerTray.localCopiesDirectory`, as a paste leaves it.
    private static func localCopy(named name: String) throws -> URL {
        try ComposerTray.makeLocalCopy(named: name, write: { try Data("%PDF-1.4".utf8).write(to: $0) })
    }

    @Test func emptyPayloadsMapToUnsupported() {
        #expect(ComposerDropItem.textDrop("") == .unsupported)
        #expect(ComposerDropItem.imageDrop(Data(), suggestedName: "x.png") == .unsupported)
        #expect(ComposerDropItem.textDrop("keep") == .text("keep"))
    }

    @Test func targetedHighlightIsStrongerThanIdle() {
        let idle = ComposerDropHighlight(isTargeted: false)
        let targeted = ComposerDropHighlight(isTargeted: true)
        #expect(targeted.strokeWidth > idle.strokeWidth)
        #expect(targeted.fillOpacity > idle.fillOpacity)
        #expect(targeted.usesAccentStroke)
        #expect(!idle.usesAccentStroke)
    }

    @Test func sendIsIgnoredWhileATrayImageIsPending() async throws {
        let gate = ScriptedTransportCallGate()
        let fixture = try Self.makeDropStagingFixture(stageGate: gate)
        defer { fixture.cleanup() }
        fixture.store.replaceDraft(with: "hello")

        fixture.store.acceptDrop([
            .image(fixture.droppedImageData, suggestedName: "shot.png")
        ])
        try await waitUntil("the image should be in the upload") {
            await gate.entryCount == 1
        }

        #expect(fixture.store.isWaitingOnTray)
        #expect(!fixture.store.canSend)
        #expect(fixture.store.sendAccessibilityHint == "Waiting for image…")
        #expect(await fixture.store.send() == .ignored)
        #expect(fixture.store.messages.isEmpty)
        #expect(fixture.store.draft == "hello")
        #expect(fixture.store.tray.items.count == 1)
        #expect(await fixture.transport.agentPromptParams.isEmpty)
        await gate.open()
    }

    @Test func sendIsIgnoredWhileATrayImageHasFailed() async throws {
        let fixture = try Self.makeDropStagingFixture(
            stageResults: [.failure(.transferFailed)])
        defer { fixture.cleanup() }
        fixture.store.replaceDraft(with: "hello")

        fixture.store.acceptDrop([
            .image(fixture.droppedImageData, suggestedName: "shot.png")
        ])
        try await waitUntil("the image should fail") {
            Self.isFailed(fixture.store.tray.items.first?.status)
        }

        #expect(!fixture.store.canSend)
        #expect(
            fixture.store.sendAccessibilityHint == "Retry or remove the failed image")
        #expect(await fixture.store.send() == .ignored)
        #expect(fixture.store.messages.isEmpty)
        #expect(fixture.store.draft == "hello")
        #expect(await fixture.transport.agentPromptParams.isEmpty)
    }

    @Test func blockedSendIsIgnoredWhileATrayImageIsPending() async throws {
        let gate = ScriptedTransportCallGate()
        let fixture = try Self.makeDropStagingFixture(
            initialStatus: .blocked,
            stageGate: gate)
        defer { fixture.cleanup() }
        var writes: [Data] = []
        let input = TerminalInputController()
        _ = input.beginSession { writes.append($0) }
        fixture.store.bindAttachInput(input)
        fixture.store.replaceDraft(with: "hello")

        fixture.store.acceptDrop([
            .image(fixture.droppedImageData, suggestedName: "shot.png")
        ])
        try await waitUntil("the image should be in the upload") {
            await gate.entryCount == 1
        }

        #expect(await fixture.store.send() == .ignored)
        #expect(fixture.store.messages.isEmpty)
        #expect(writes.isEmpty)
        #expect(await fixture.transport.agentPromptParams.isEmpty)
        await gate.open()
    }

    @Test func imagesAloneCanBeSent() async throws {
        let fixture = try Self.makeDropStagingFixture()
        defer { fixture.cleanup() }
        #expect(!fixture.store.canSend)

        fixture.store.acceptDrop([
            .image(fixture.droppedImageData, suggestedName: "shot.png")
        ])
        try await waitUntil("the image should become ready") {
            fixture.store.tray.hasReadyItems
        }

        #expect(fixture.store.canSend)
        #expect(
            fixture.store.sendAccessibilityHint == "Delivers the complete draft to the Agent")
        #expect(await fixture.store.send() == .deliveredViaPrompt)
        #expect(
            await fixture.transport.agentPromptParams == [
                AgentPromptParams(target: "w1:p1", text: "/tmp/waycar-drop.jpg ")
            ])
        #expect(fixture.store.tray.isEmpty)
    }

    @Test func sendDeliversTheDraftWithReadyPathsInOnePrompt() async throws {
        let fixture = try Self.makeDropStagingFixture(
            remotePaths: ["/tmp/waycar-drop-a.jpg", "/tmp/waycar-drop-b.jpg"])
        defer { fixture.cleanup() }
        fixture.store.replaceDraft(with: "look")
        fixture.store.acceptDrop([
            .image(fixture.droppedImageData, suggestedName: "a.png"),
            .image(Data([0xFF, 0xD8, 0xFF, 0x02]), suggestedName: "b.png"),
        ])
        try await waitUntil("both images should become ready") {
            fixture.store.tray.readyPaths.count == 2
        }
        let expected = AgentComposerStore.prompt(
            text: "look", paths: fixture.store.tray.readyPaths)

        #expect(await fixture.store.send() == .deliveredViaPrompt)

        #expect(expected == "look /tmp/waycar-drop-a.jpg /tmp/waycar-drop-b.jpg")
        #expect(
            await fixture.transport.agentPromptParams == [
                AgentPromptParams(target: "w1:p1", text: expected)
            ])
        #expect(fixture.store.draft.isEmpty)
        #expect(!fixture.store.tray.hasReadyItems)
        #expect(fixture.store.tray.isEmpty)
        let message = try #require(fixture.store.messages.first)
        #expect(message.text == expected)
        #expect(message.draftText == "look")
        // Delivered: it can no longer go back to the draft, so it keeps no chips.
        #expect(message.trayItems.isEmpty)
    }

    @Test func deliveryReleasesTheSentTrayItemsWhileAFailureKeepsThem() async throws {
        let fixture = try Self.makeDropStagingFixture(
            remotePaths: ["/tmp/waycar-drop-a.jpg", "/tmp/waycar-drop-b.jpg"])
        defer { fixture.cleanup() }
        await fixture.transport.setAgentPromptFailure(TransportError.timedOut)
        fixture.store.replaceDraft(with: "look")
        fixture.store.acceptDrop([
            .image(fixture.droppedImageData, suggestedName: "a.png"),
            .image(Data([0xFF, 0xD8, 0xFF, 0x02]), suggestedName: "b.png"),
        ])
        try await waitUntil("both images should become ready") {
            fixture.store.tray.readyPaths.count == 2
        }
        let sentIDs = fixture.store.tray.items.map(\.id)

        #expect(await fixture.store.send() == .failed)

        let failed = try #require(fixture.store.messages.first)
        #expect(failed.trayItems.map(\.id) == sentIDs)
        #expect(
            failed.trayItems.map(\.status) == [
                .ready(path: "/tmp/waycar-drop-a.jpg"), .ready(path: "/tmp/waycar-drop-b.jpg"),
            ])

        await fixture.transport.setAgentPromptFailure(nil)
        #expect(await fixture.store.retry(failed.id) == .deliveredViaPrompt)

        let delivered = try #require(fixture.store.messages.first)
        #expect(delivered.state == .delivered(.acknowledged))
        #expect(delivered.text == "look /tmp/waycar-drop-a.jpg /tmp/waycar-drop-b.jpg")
        #expect(delivered.trayItems.isEmpty)
        #expect(fixture.store.tray.isEmpty)
    }

    @Test func withdrawingAFailedTraySendRestoresTextAndChipsSeparately() async throws {
        let fixture = try Self.makeDropStagingFixture(
            remotePaths: ["/tmp/waycar-drop-a.jpg", "/tmp/waycar-drop-b.jpg"])
        defer { fixture.cleanup() }
        await fixture.transport.setAgentPromptFailure(TransportError.timedOut)
        fixture.store.replaceDraft(with: "look")
        fixture.store.acceptDrop([
            .image(fixture.droppedImageData, suggestedName: "a.png"),
            .image(Data([0xFF, 0xD8, 0xFF, 0x02]), suggestedName: "b.png"),
        ])
        try await waitUntil("both images should become ready") {
            fixture.store.tray.readyPaths.count == 2
        }

        #expect(await fixture.store.send() == .failed)
        let failedID = try #require(fixture.store.messages.first?.id)
        #expect(fixture.store.messages.first?.trayItems.count == 2)
        #expect(fixture.store.tray.isEmpty)

        fixture.store.withdrawToDraft(failedID)

        #expect(fixture.store.messages.isEmpty)
        #expect(fixture.store.draft == "look")
        #expect(
            fixture.store.tray.readyPaths == ["/tmp/waycar-drop-a.jpg", "/tmp/waycar-drop-b.jpg"])
        #expect(fixture.store.canSend)

        await fixture.transport.setAgentPromptFailure(nil)
        #expect(await fixture.store.send() == .deliveredViaPrompt)
        #expect(
            await fixture.transport.agentPromptParams.last?.text
                == "look /tmp/waycar-drop-a.jpg /tmp/waycar-drop-b.jpg")
    }

    @Test func retryingAFailedTraySendResendsTheComposedText() async throws {
        let fixture = try Self.makeDropStagingFixture()
        defer { fixture.cleanup() }
        await fixture.transport.setAgentPromptFailure(TransportError.timedOut)
        fixture.store.replaceDraft(with: "see")
        fixture.store.acceptDrop([
            .image(fixture.droppedImageData, suggestedName: "shot.png")
        ])
        try await waitUntil("the image should become ready") {
            fixture.store.tray.hasReadyItems
        }
        #expect(await fixture.store.send() == .failed)
        let failedID = try #require(fixture.store.messages.first?.id)

        await fixture.transport.setAgentPromptFailure(nil)
        #expect(await fixture.store.retry(failedID) == .deliveredViaPrompt)

        #expect(
            await fixture.transport.agentPromptParams.map(\.text)
                == ["see /tmp/waycar-drop.jpg", "see /tmp/waycar-drop.jpg"])
        #expect(fixture.store.messages.map(\.state) == [.delivered(.acknowledged)])
        #expect(fixture.store.tray.isEmpty)
        #expect(fixture.store.draft.isEmpty)
    }

    @Test func directInputSendLeavesTheDraftAndTrayAlone() async throws {
        let fixture = try Self.makeDropStagingFixture()
        defer { fixture.cleanup() }
        fixture.store.replaceDraft(with: "typing")
        fixture.store.acceptDrop([
            .image(fixture.droppedImageData, suggestedName: "shot.png")
        ])
        try await waitUntil("the image should become ready") {
            fixture.store.tray.hasReadyItems
        }

        #expect(await fixture.store.send("spoken words") == .deliveredViaPrompt)

        #expect(
            await fixture.transport.agentPromptParams == [
                AgentPromptParams(target: "w1:p1", text: "spoken words")
            ])
        #expect(fixture.store.draft == "typing")
        #expect(fixture.store.tray.readyPaths == ["/tmp/waycar-drop.jpg"])
        #expect(fixture.store.messages.first?.trayItems.isEmpty == true)
    }

    @Test func shellComposerInsertsACompletedPathAtTheCaret() async throws {
        let fixture = try Self.makeDropStagingFixture(shellPaneID: "w1:p-shell")
        defer { fixture.cleanup() }
        fixture.store.replaceDraft(with: "cat | wc")
        fixture.store.setDraftSelection(NSRange(location: 4, length: 0))

        fixture.store.acceptDrop([
            .image(fixture.droppedImageData, suggestedName: "shot.png")
        ])
        try await waitUntil("the path should land in the draft") {
            fixture.store.draft == "cat /tmp/waycar-drop.jpg | wc"
        }

        #expect(fixture.store.tray.isEmpty)
        #expect(fixture.store.canSend)
        #expect(await fixture.store.send() == .deliveredViaPaneInput)
        #expect(
            await fixture.transport.paneInputParams == [
                PaneSendInputParams(
                    paneID: "w1:p-shell", keys: ["enter"],
                    text: "cat /tmp/waycar-drop.jpg | wc")
            ])
        #expect(await fixture.transport.agentPromptParams.isEmpty)
    }

    @Test func blockedSendInsertsTheComposedTextIntoTheAttach() async throws {
        let fixture = try Self.makeDropStagingFixture(initialStatus: .blocked)
        defer { fixture.cleanup() }
        var writes: [Data] = []
        let input = TerminalInputController()
        _ = input.beginSession { writes.append($0) }
        fixture.store.bindAttachInput(input)
        fixture.store.replaceDraft(with: "see")
        fixture.store.acceptDrop([
            .image(fixture.droppedImageData, suggestedName: "shot.png")
        ])
        try await waitUntil("the image should become ready") {
            fixture.store.tray.hasReadyItems
        }

        #expect(await fixture.store.send() == .deliveredViaAttach)

        #expect(writes == [Data("see /tmp/waycar-drop.jpg".utf8)])
        #expect(fixture.store.messages.map(\.text) == ["see /tmp/waycar-drop.jpg"])
        #expect(fixture.store.draft.isEmpty)
        #expect(fixture.store.tray.isEmpty)
        #expect(fixture.store.messages.first?.trayItems.isEmpty == true)
        #expect(await fixture.transport.agentPromptParams.isEmpty)
    }

    @Test func readyTrayItemsSurviveLeavingAndRejoiningTheAttach() async throws {
        let gate = ScriptedTransportCallGate()
        let counter = LeaveStageCounter(gate: gate)
        let jpeg = try Self.tinyJPEGData()
        let store = Self.draftOnlyStore()
        let attach = AgentAttachStore(
            target: .agentPane("w1:p1"),
            transportGeneration: nil,
            recordsNetworkTelemetry: true,
            isOnStage: { true },
            runTerminal: { _, _ in },
            stageImage: { _, _ in try await counter.stage() },
            stageFile: { _, _ in try StagedFile(path: "/tmp/waycar-drop.txt") },
            composer: store,
            closePane: {})
        store.bindStaging(attach.staging)
        await gate.open()
        store.acceptDrop([.image(jpeg, suggestedName: "a.jpg")])
        try await waitUntil("the image should become ready") {
            store.tray.readyPaths == ["/tmp/leave-1.jpg"]
        }
        let leftID = attach.terminalID

        await attach.leave().value
        #expect(store.tray.readyPaths == ["/tmp/leave-1.jpg"])
        #expect(store.canSend)

        attach.rejoin()
        try await waitUntil("rejoin should rebuild the terminal") {
            attach.terminalID != leftID
        }
        #expect(store.tray.readyPaths == ["/tmp/leave-1.jpg"])

        store.acceptDrop([.image(jpeg, suggestedName: "b.jpg")])
        try await waitUntil("a drop after rejoin should stage") {
            store.tray.readyPaths.count == 2
        }
        #expect(store.tray.readyPaths == ["/tmp/leave-1.jpg", "/tmp/leave-2.jpg"])
        #expect(await counter.count == 2)
    }

    @Test func trayResumesWhenARetainedAttachRejoins() async throws {
        let jpeg = try Self.tinyJPEGData()
        let store = Self.draftOnlyStore()
        let attach = AgentAttachStore(
            target: .agentPane("w1:p1"),
            transportGeneration: nil,
            recordsNetworkTelemetry: true,
            isOnStage: { true },
            runTerminal: { _, _ in },
            stageImage: { _, _ in try StagedImage(path: "/tmp/waycar-drop.jpg") },
            stageFile: { _, _ in try StagedFile(path: "/tmp/waycar-drop.txt") },
            composer: store,
            closePane: {})
        store.bindStaging(attach.staging)

        // Retention keeps the Attach active while its interactions leave.
        await attach.leaveInteractionsForRetention().value
        #expect(!store.tray.isActive)
        store.acceptDrop([.image(jpeg, suggestedName: "x.jpg")])
        #expect(store.tray.items.map(\.status) == [.queued])
        #expect(store.sendAccessibilityHint == "Open the terminal to finish uploading")

        attach.rejoin()

        try await waitUntil("the rejoin should resume the tray") {
            store.tray.readyPaths == ["/tmp/waycar-drop.jpg"]
        }
        #expect(store.tray.isActive)
        #expect(store.canSend)
    }

    @Test func teardownStopsTheInFlightImageAndHoldsTheQueue() async throws {
        let gate = ScriptedTransportCallGate()
        let fixture = try Self.makeDropStagingFixture(
            // The abandoned upload still consumes the first result.
            remotePaths: [
                "/tmp/waycar-drop-abandoned.jpg",
                "/tmp/waycar-drop-a.jpg",
                "/tmp/waycar-drop-b.jpg",
            ],
            stageGate: gate)
        defer { fixture.cleanup() }
        let secondImage = Data([0xFF, 0xD8, 0xFF, 0x02])
        fixture.store.acceptDrop([
            .image(fixture.droppedImageData, suggestedName: "a.png"),
            .image(secondImage, suggestedName: "b.png"),
        ])
        try await waitUntil("A should be in the upload") {
            await gate.entryCount == 1
        }

        fixture.store.suspendTrayForTeardown(of: fixture.staging)
        let leave = Task { await fixture.staging.leave() }
        await gate.open()
        await leave.value
        fixture.store.resumeTrayAfterRejoin(of: fixture.staging)

        #expect(
            fixture.store.tray.items.map(\.status) == [
                .failed(message: "Upload stopped when you left this screen.", isRetryable: true),
                .queued,
            ])
        #expect(await fixture.preparer.loadedSelections() == [fixture.droppedImageData])
        #expect(!fixture.store.canSend)
        #expect(fixture.store.draft.isEmpty)

        let stopped = try #require(fixture.store.tray.items.first?.id)
        fixture.store.tray.retry(stopped)
        try await waitUntil("retry should finish both in order") {
            fixture.store.tray.readyPaths.count == 2
        }
        #expect(
            fixture.store.tray.readyPaths == ["/tmp/waycar-drop-a.jpg", "/tmp/waycar-drop-b.jpg"])
    }

    private static func draftOnlyStore() -> AgentComposerStore {
        AgentComposerStore(target: "w1:p1") { _ in
            throw TransportError.timedOut
        }
    }

    private static func isFailed(_ status: ComposerTray.Item.Status?) -> Bool {
        if case .failed = status { true } else { false }
    }

    private static func tinyJPEGData() throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16))
        let image = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        return try #require(image.jpegData(compressionQuality: 0.8))
    }

    private static func makeDropStagingFixture(
        initialStatus: AgentStatus = .idle,
        shellPaneID: String? = nil,
        remotePaths: [String] = ["/tmp/waycar-drop.jpg"],
        stageResults: [DropStageResult]? = nil,
        stageGate: ScriptedTransportCallGate? = nil
    ) throws -> ComposerDropStagingFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "waycar-drop-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let droppedImageData = Data([0xFF, 0xD8, 0xFF, 0x01])
        let preparer = RecordingDropImagePreparer(directory: directory)
        let transport = ScriptedTransport()
        let store: AgentComposerStore
        if let shellPaneID {
            store = AgentComposerStore(shellPaneID: shellPaneID) { params in
                try await transport.sendPaneInput(params)
            }
        } else {
            store = AgentComposerStore(target: "w1:p1", initialStatus: initialStatus) {
                params in
                try await transport.promptAgent(params)
            }
        }
        let results = stageResults ?? remotePaths.map { DropStageResult.path($0) }
        let paths = DropStagePathQueue(results: results, gate: stageGate)
        let staging = ComposerStagingStore(
            imagePreparer: preparer,
            filePreparer: UnusedDropFilePreparer(),
            stageImage: { _, _ in try await paths.nextImage() },
            stageFile: { _, _ in try StagedFile(path: "/tmp/waycar-drop.txt") })
        store.bindStaging(staging)
        return ComposerDropStagingFixture(
            store: store,
            staging: staging,
            preparer: preparer,
            transport: transport,
            droppedImageData: droppedImageData,
            directory: directory)
    }

    /// A status stream that reports when its consumer has handled every
    /// update it was given and is waiting for the next: a drain a test can
    /// wait for, where a fixed sleep only hopes.
    @MainActor
    final class CountedStatusFeed {
        private var queue: [ConsoleStore.AgentStatusUpdate] = []
        private var waiter: CheckedContinuation<ConsoleStore.AgentStatusUpdate?, Never>?
        private var isFinished = false
        /// Updates handed to the consumer.
        private var handed = 0
        /// Times the consumer asked for an update.
        private var asked = 0

        var updates: AsyncStream<ConsoleStore.AgentStatusUpdate> {
            AsyncStream(unfolding: { await self.next() })
        }

        /// Every update given was handed over and the consumer, done with
        /// them, is parked asking for the next.
        var isDrained: Bool { queue.isEmpty && asked > handed }

        func yield(_ status: AgentStatus) {
            let update = ConsoleStore.AgentStatusUpdate(status: status, liveUpdatesAvailable: true)
            if let waiter {
                self.waiter = nil
                handed += 1
                waiter.resume(returning: update)
            } else {
                queue.append(update)
            }
        }

        /// Ends the stream, releasing a parked consumer.
        func finish() {
            isFinished = true
            waiter?.resume(returning: nil)
            waiter = nil
        }

        private func next() async -> ConsoleStore.AgentStatusUpdate? {
            asked += 1
            if !queue.isEmpty {
                handed += 1
                return queue.removeFirst()
            }
            if isFinished { return nil }
            return await withCheckedContinuation { waiter = $0 }
        }
    }

    private func makeAgent(hostID: Host.ID, status: AgentStatus) -> ConsoleAgent {
        ConsoleAgent(
            hostID: hostID,
            hostName: "devbox",
            agent: Agent(
                terminalID: "term-1", kind: "claude", title: "Task",
                status: status, workspaceID: "w1", tabID: "w1:t1", paneID: "w1:p1",
                cwd: "/work", revision: 1),
            workspaceLabel: "Project",
            repositoryCheckout: RepositoryCheckout(
                repoKey: "/work/Project/.git",
                repoName: "Project",
                repoRoot: "/work/Project",
                checkoutPath: "/work/Project",
                isLinkedWorktree: false))
    }
}

private struct ComposerDropStagingFixture {
    let store: AgentComposerStore
    let staging: ComposerStagingStore
    let preparer: RecordingDropImagePreparer
    let transport: ScriptedTransport
    let droppedImageData: Data
    let directory: URL

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private actor RecordingDropImagePreparer: ImagePreparing {
    private let directory: URL
    private var selections: [Data] = []

    init(directory: URL) {
        self.directory = directory
    }

    func prepare(_ selection: any ImageSelection) async throws -> PreparedImage {
        let data = try await selection.loadData()
        selections.append(data)
        let fileURL = directory.appendingPathComponent("\(UUID().uuidString).jpg")
        try data.write(to: fileURL)
        return PreparedImage(
            fileURL: fileURL,
            format: .jpeg,
            pixelWidth: 1,
            pixelHeight: 1,
            byteCount: Int64(data.count))
    }

    func loadedSelections() -> [Data] { selections }
}

private enum DropStageResult: Sendable {
    case path(String)
    case failure(AttachmentStagingError)
}

private actor DropStagePathQueue {
    private let results: [DropStageResult]
    private let gate: ScriptedTransportCallGate?
    private var index = 0

    init(results: [DropStageResult], gate: ScriptedTransportCallGate?) {
        self.results = results
        self.gate = gate
    }

    func nextImage() async throws -> StagedImage {
        if let gate {
            await gate.waitUntilOpen()
        }
        let result = results[min(index, max(results.count - 1, 0))]
        index += 1
        switch result {
        case .path(let path):
            return try StagedImage(path: path)
        case .failure(let error):
            throw error
        }
    }
}

private actor UnusedDropFilePreparer: FilePreparing {
    func prepare(_: URL) async throws -> PreparedFile {
        throw FilePreparationError.selectionUnavailable
    }
}

private actor LeaveStageCounter {
    let gate: ScriptedTransportCallGate
    private(set) var count = 0

    init(gate: ScriptedTransportCallGate) {
        self.gate = gate
    }

    func stage() async throws -> StagedImage {
        await gate.waitUntilOpen()
        count += 1
        return try StagedImage(path: "/tmp/leave-\(count).jpg")
    }
}

/// Turns a composer's live status Blocked from inside its prompt closure.
@MainActor
private final class ComposerStatusFlip {
    weak var store: AgentComposerStore?

    func block() {
        store?.agentStatusDidChange(.blocked)
    }
}

@MainActor
@Suite("Agent Composer send button")
struct AgentComposerSendButtonTests {
    @Test
    func buttonKeepsOriginalVisualDiameter() async throws {
        let image = try await Self.render(isEnabled: true, colorScheme: .dark)
        let bounds = try #require(Self.visibleContentBounds(in: image))
        let width = bounds.width / image.scale

        #expect(
            (30...34).contains(width),
            "Send visual diameter should remain about 32pt; rendered width was \(width)")
    }

    @Test
    func buttonKeepsItsArrowVisibleAcrossStatesAndAppearances() async throws {
        for isEnabled in [false, true] {
            for colorScheme in [ColorScheme.light, .dark] {
                let image = try await Self.render(
                    isEnabled: isEnabled,
                    colorScheme: colorScheme)
                let range = try #require(
                    Self.luminanceRange(
                        in: image,
                        unitRect: CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3)))

                #expect(
                    range > 0.12,
                    "Send center has no visible arrow when isEnabled=\(isEnabled), colorScheme=\(colorScheme); luminance range was \(range)")
            }
        }
    }

    private static func render(isEnabled: Bool, colorScheme: ColorScheme) async throws -> UIImage {
        let bounds = CGRect(x: 0, y: 0, width: 64, height: 64)
        let renderer = ImageRenderer(
            content: ZStack {
                Color(uiColor: .secondarySystemBackground)
                AgentComposerSendButton(isEnabled: isEnabled) {}
            }
            .environment(\.colorScheme, colorScheme))
        renderer.proposedSize = ProposedViewSize(width: bounds.width, height: bounds.height)
        renderer.scale = 1
        return try #require(renderer.uiImage)
    }

    private static func luminanceRange(in image: UIImage, unitRect: CGRect) -> Double? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard
            let context = CGContext(
                data: &pixels, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let minX = max(0, Int(unitRect.minX * CGFloat(width)))
        let maxX = min(width, Int(unitRect.maxX * CGFloat(width)))
        let minY = max(0, Int(unitRect.minY * CGFloat(height)))
        let maxY = min(height, Int(unitRect.maxY * CGFloat(height)))
        var minimum = Double.greatestFiniteMagnitude
        var maximum = -Double.greatestFiniteMagnitude
        for y in minY..<maxY {
            for x in minX..<maxX {
                let offset = (y * width + x) * 4
                let luminance =
                    (0.2126 * Double(pixels[offset])
                        + 0.7152 * Double(pixels[offset + 1])
                        + 0.0722 * Double(pixels[offset + 2])) / 255
                minimum = min(minimum, luminance)
                maximum = max(maximum, luminance)
            }
        }
        return maximum - minimum
    }

    private static func visibleContentBounds(in image: UIImage) -> CGRect? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard
            let context = CGContext(
                data: &pixels, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let background = Self.luminance(at: 0, in: pixels)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                guard abs(Self.luminance(at: offset, in: pixels) - background) > 0.25 else {
                    continue
                }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private static func luminance(at offset: Int, in pixels: [UInt8]) -> Double {
        (0.2126 * Double(pixels[offset])
            + 0.7152 * Double(pixels[offset + 1])
            + 0.0722 * Double(pixels[offset + 2])) / 255
    }
}
