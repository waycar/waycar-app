import Foundation
import Testing

@testable import Waycar

@MainActor
@Suite("Agent voice service")
struct AgentVoiceServiceTests {
    @MainActor
    final class FakeSpeaker: AgentVoiceSpeaker {
        private(set) var spoken: [String] = []
        /// False plays a head unit that asked for silence: nothing is heard.
        var isHeard = true
        private(set) var turnsBegun = 0
        private(set) var turnsEnded = 0

        func beginTurn() { turnsBegun += 1 }
        func speak(_ text: String) async -> Bool {
            spoken.append(text)
            return isHeard
        }
        func stop() {}
        func endTurn() { turnsEnded += 1 }
    }

    /// The Console calls the service makes, recorded.
    @MainActor
    final class FakeConsole {
        var agents: [ConsoleAgent]
        var screens: [String] = []
        private(set) var screenReads = 0
        private(set) var keys: [[String]] = []
        private(set) var prompts: [AgentPromptParams] = []
        var promptError: (any Error)?
        /// Returned in order; the last repeats. Empty throws.
        var transcripts: [ChatTranscriptSnapshot] = []
        private(set) var transcriptReads: [String?] = []
        private(set) var drafts: [String] = []
        var statuses: [AgentStatus] = []

        init(_ agents: [ConsoleAgent]) {
            self.agents = agents
        }

        var dependencies: AgentVoiceService.Dependencies {
            AgentVoiceService.Dependencies(
                agent: { id in self.agents.first { $0.id == id } },
                readScreen: { _ in
                    defer { self.screenReads += 1 }
                    guard !self.screens.isEmpty else { throw TransportError.cancelled }
                    return self.screens[min(self.screenReads, self.screens.count - 1)]
                },
                sendKeys: { keys, _ in self.keys.append(keys) },
                promptAgent: { params, _ in
                    self.prompts.append(params)
                    if let error = self.promptError { throw error }
                },
                readTranscript: { _, after in
                    defer { self.transcriptReads.append(after) }
                    guard !self.transcripts.isEmpty else { throw TransportError.cancelled }
                    return self.transcripts[
                        min(self.transcriptReads.count, self.transcripts.count - 1)]
                },
                statusUpdates: { _ in
                    let (stream, continuation) = AsyncStream.makeStream(
                        of: ConsoleStore.AgentStatusUpdate.self)
                    for status in self.statuses {
                        continuation.yield(.init(status: status, liveUpdatesAvailable: true))
                    }
                    return stream
                },
                insertDraft: { _, text in self.drafts.append(text) })
        }
    }

    struct LinkDown: Error {}

    private let host = Host.fixture(name: "studio")

    private func agent(
        _ status: AgentStatus, kind: String = "claude", summary: String? = nil, name: String? = nil
    ) -> ConsoleAgent {
        ConsoleAgent(
            hostID: host.id, hostName: host.displayName,
            agent: Agent(.fixture(paneID: "w1:p1", status: status, kind: kind, name: name)),
            workspaceLabel: "iOS App", repositoryCheckout: nil,
            summary: summary.map {
                AgentSummary(
                    paneID: "w1:p1", status: status, text: $0,
                    timestamp: Int64(Date().timeIntervalSince1970 * 1000))
            },
            backend: .herdr)
    }

    private static var timing: AgentVoiceService.Timing {
        var timing = AgentVoiceService.Timing()
        timing.endOfSpeech = .milliseconds(60)
        timing.noSpeech = .milliseconds(120)
        timing.confirmNoSpeech = .milliseconds(120)
        timing.maximumListen = .seconds(3)
        timing.startup = .seconds(3)
        timing.listenTick = .milliseconds(5)
        timing.replyPoll = .milliseconds(5)
        timing.replyTimeout = .seconds(3)
        timing.finishGrace = .milliseconds(80)
        timing.correctionTimeout = .milliseconds(80)
        timing.screenRecheckDelay = .seconds(30)
        timing.speechSettle = .zero
        return timing
    }

    private func service(
        _ console: FakeConsole, dictation: (any DictationEngine)? = nil,
        timing: AgentVoiceService.Timing = Self.timing
    ) -> (AgentVoiceService, FakeSpeaker) {
        let speaker = FakeSpeaker()
        let service = AgentVoiceService(
            dependencies: console.dependencies, dictation: dictation, speaker: speaker,
            timing: timing, locale: { Locale(identifier: "en_US") })
        return (service, speaker)
    }

    private static func transcript(_ messages: [ChatTranscriptMessage]) -> ChatTranscriptSnapshot {
        ChatTranscriptSnapshot(
            header: ChatTranscriptHeader(
                kind: "claude", status: .ok, transcript: "/t.jsonl", activity: nil,
                turnOpen: false, truncated: false, error: nil),
            messages: messages)
    }

    private static func message(_ id: String, _ role: ChatTranscriptMessage.Role, _ text: String)
        -> ChatTranscriptMessage
    {
        ChatTranscriptMessage(id: id, role: role, text: text, timestamp: nil)
    }

    // MARK: Asking

    @Test func aQuestionCarriesTheSpokenReplySuffixOnOneSafeLine() async {
        let row = agent(.idle)
        let console = FakeConsole([row])
        let (voice, _) = service(console)
        let result = await voice.send("what failed\u{1B}[31m?\nand why", to: row.id)
        guard case .delivered = result else {
            Issue.record("expected delivery, got \(result)")
            return
        }
        #expect(
            console.prompts == [
                AgentPromptParams(
                    target: "w1:p1",
                    text: "what failed[31m? and why \(CarVoiceScript.spokenReplyInstruction)")
            ])
    }

    @Test func theReplyIsTrimmedToTwoSentences() async {
        let row = agent(.idle)
        let console = FakeConsole([row])
        console.transcripts = [
            Self.transcript([Self.message("u1", .user, "hi"), Self.message("a1", .assistant, "Old.")]),
            Self.transcript([]),
            Self.transcript([
                Self.message("u2", .user, "what failed"),
                Self.message("a2", .assistant, "Two tests failed. Both are flaky. I reran them."),
            ]),
        ]
        let (voice, _) = service(console)
        let reply = await voice.ask("what failed", to: row.id)
        #expect(reply == "Two tests failed. Both are flaky.")
        // Every poll reads after the last message seen before sending.
        #expect(console.transcriptReads.dropFirst().allSatisfy { $0 == "a1" })
    }

    @Test func withoutATranscriptTheNewSummaryIsTheReply() async {
        let row = agent(.working, summary: "Running the tests.")
        let console = FakeConsole([row])
        let (voice, _) = service(console)
        guard case .delivered(let cursor) = await voice.send("status?", to: row.id) else {
            Issue.record("expected delivery")
            return
        }
        console.agents = [agent(.done, summary: "All tests pass.")]
        let reply = await voice.reply(after: cursor)
        #expect(
            reply
                == .answer(
                    CarVoiceScript.finished(
                        identity: AgentVoiceService.spokenIdentity(of: row),
                        summary: "All tests pass.")))
    }

    @Test func aFailedPromptIsNeverResent() async {
        let row = agent(.idle)
        let console = FakeConsole([row])
        console.promptError = LinkDown()
        let (voice, _) = service(console)
        let reply = await voice.ask("what failed", to: row.id)
        #expect(reply == CarVoiceScript.notConfirmed)
        #expect(console.prompts.count == 1)
        #expect(console.drafts.isEmpty)
    }

    /// The driver closed the turn while "Sending…" showed: nothing is
    /// prompted, and the question is kept as the draft rather than lost.
    @Test func aCancelledSendPromptsNothingAndKeepsTheDraft() async {
        let row = agent(.idle)
        let console = FakeConsole([row])
        let (voice, _) = service(console)
        let send = Task { await voice.send("what failed", to: row.id) }
        send.cancel()
        #expect(await send.value == .failed(CarVoiceScript.notSent))
        #expect(console.prompts.isEmpty)
        #expect(console.drafts == ["what failed"])
    }

    @Test func aBlockedAgentGetsNoQuestionButADraft() async {
        let row = agent(.blocked)
        let console = FakeConsole([row])
        let (voice, _) = service(console)
        let result = await voice.send("use pnpm", to: row.id)
        #expect(
            result
                == .failed(
                    CarVoiceScript.blockedKeptDraft(
                        identity: AgentVoiceService.spokenIdentity(of: row))))
        #expect(console.prompts.isEmpty)
        #expect(console.drafts == ["use pnpm"])
    }

    /// A sign-in screen or folder-trust dialog refuses the prompt before
    /// anything is typed: the question is kept, never "unconfirmed".
    @Test(arguments: [true, false])
    func aRefusedPromptIsKeptAsADraft(signIn: Bool) async {
        let row = agent(.idle)
        let console = FakeConsole([row])
        console.promptError =
            signIn
            ? AgentSignInRequiredError(kind: "cursor", target: row.agent.paneID)
            : AgentFolderTrustRequiredError(kind: "grok", target: row.agent.paneID)
        let (voice, _) = service(console)
        let identity = AgentVoiceService.spokenIdentity(of: row)
        let result = await voice.send("use pnpm", to: row.id)
        #expect(
            result
                == .failed(
                    signIn
                        ? CarVoiceScript.signInKeptDraft(identity: identity)
                        : CarVoiceScript.trustKeptDraft(identity: identity)))
        #expect(console.prompts.count == 1)
        #expect(console.drafts == ["use pnpm"])
    }

    /// After a Deny, a correction refused by a sign-in screen or trust
    /// dialog lands in the draft, as a Blocked refusal does.
    @Test func aCorrectionRefusedUnsentLandsInTheDraft() async {
        let row = agent(.blocked)
        let console = FakeConsole([row])
        console.screens = [Self.permission]
        console.statuses = [.blocked, .working]
        console.promptError = AgentFolderTrustRequiredError(kind: "grok", target: row.agent.paneID)
        let (voice, _) = service(console)
        let turn = await voice.blockedTurn(for: row.id)
        let answer = await voice.denyAndInstruct(turn, text: "use pnpm instead")
        #expect(answer.spoken == CarVoiceScript.correctionDrafted)
        #expect(console.drafts == ["use pnpm instead"])
    }

    // MARK: Blocked

    static let permission = TmuxScreenDetectorTests.claudePermission
    static let risky = permission.replacingOccurrences(
        of: " touch x.txt", with: " git push --force origin main")
    static let multiLine = permission.replacingOccurrences(
        of: " touch x.txt", with: " touch x.txt &&\n touch y.txt")

    @Test func aPlainYesPermissionOffersDenyAndAllowWithTheExactCommand() async {
        let row = agent(.blocked)
        let console = FakeConsole([row])
        console.screens = [Self.permission]
        let (voice, _) = service(console)
        let turn = await voice.blockedTurn(for: row.id)
        #expect(turn.buttons == .denyAndAllow)
        #expect(
            turn.question
                == CarVoiceScript.blockedQuestion(
                    identity: AgentVoiceService.spokenIdentity(of: row), command: "touch x.txt"))
    }

    @Test func riskyAndLongPromptsAreHeld() async {
        let row = agent(.blocked)
        let identity = AgentVoiceService.spokenIdentity(of: row)
        let console = FakeConsole([row])
        let (voice, _) = service(console)

        console.screens = [Self.risky]
        let risky = await voice.blockedTurn(for: row.id)
        #expect(risky.buttons == .denyAndHold)
        #expect(risky.question.contains("looks risky"))
        #expect(risky.question.contains("git push --force origin main"))

        console.agents = [agent(.blocked)]
        console.screens = [Self.multiLine]
        let long = await voice.blockedTurn(for: row.id)
        #expect(long.buttons == .denyAndHold)
        #expect(long.question == CarVoiceScript.tooLongHold(identity: identity))
    }

    @Test func trustQuestionsAndYesNoAreReadOnly() async {
        let claude = agent(.blocked)
        let console = FakeConsole([claude])
        let (voice, _) = service(console)
        console.screens = [TmuxScreenDetectorTests.claudeTrust]
        let trust = await voice.blockedTurn(for: claude.id)
        #expect(trust.buttons == .readOnly)
        #expect(
            trust.question
                == CarVoiceScript.trustQuestion(identity: AgentVoiceService.spokenIdentity(of: claude)))

        let codex = agent(.blocked, kind: "codex")
        let codexConsole = FakeConsole([codex])
        codexConsole.screens = ["› Install\n  Proceed with installation? [y/n]"]
        let (codexVoice, _) = service(codexConsole)
        let yesNo = await codexVoice.blockedTurn(for: codex.id)
        #expect(yesNo.buttons == .readOnly)
        #expect(yesNo.question.contains("yes/no"))
    }

    @Test func heldAndReadOnlyPromptsNeverGetEnter() async {
        let row = agent(.blocked)
        let console = FakeConsole([row])
        let (voice, _) = service(console)
        for screen in [Self.risky, Self.multiLine, TmuxScreenDetectorTests.claudeTrust] {
            console.screens = [screen]
            let turn = await voice.blockedTurn(for: row.id)
            await voice.speakQuestion(turn, saying: turn.question)
            let answer = await voice.allow(turn)
            #expect(answer.spoken == CarVoiceScript.notAllowedFromCar)
        }
        #expect(console.keys.isEmpty)
    }

    @Test func allowSendsEnterAndDenySendsEsc() async {
        let row = agent(.blocked)
        let console = FakeConsole([row])
        console.screens = [Self.permission]
        let (voice, _) = service(console)
        let turn = await voice.blockedTurn(for: row.id)
        await voice.speakQuestion(turn, saying: turn.question)
        #expect(await voice.allow(turn) == .init(spoken: CarVoiceScript.allowed, next: nil, outcome: .sent))
        #expect(await voice.deny(turn) == .init(spoken: CarVoiceScript.denied, next: nil, outcome: .sent))
        #expect(console.keys == [["enter"], ["esc"]])
    }

    @Test func failedDispatchNeverPresentsDone() async {
        let row = agent(.blocked)
        let console = FakeConsole([row])
        console.screens = [Self.permission]
        var dependencies = console.dependencies
        dependencies.sendKeys = { _, _ in throw LinkDown() }
        let voice = AgentVoiceService(
            dependencies: dependencies, dictation: nil, speaker: FakeSpeaker(), timing: Self.timing)
        let turn = await voice.blockedTurn(for: row.id)
        let answer = await voice.deny(turn)
        #expect(answer.outcome == .notSent)
        #expect(CarPlayTemplateCoordinator.screen(for: answer) == .checking)
    }

    @Test func doneWaitsForDispatchCompletion() async throws {
        let row = agent(.blocked)
        let console = FakeConsole([row])
        console.screens = [Self.permission]
        var waiting: CheckedContinuation<Void, Never>?
        var dependencies = console.dependencies
        dependencies.sendKeys = { _, _ in
            await withCheckedContinuation { waiting = $0 }
        }
        let voice = AgentVoiceService(
            dependencies: dependencies, dictation: nil, speaker: FakeSpeaker(), timing: Self.timing)
        let turn = await voice.blockedTurn(for: row.id)
        var answer: AgentVoiceService.BlockedAnswer?
        let sending = Task { answer = await voice.deny(turn) }
        try await waitUntil { waiting != nil }
        #expect(answer == nil)
        waiting?.resume()
        await sending.value
        let completed = try #require(answer)
        #expect(completed.outcome == .sent)
        #expect(CarPlayTemplateCoordinator.screen(for: completed) == .answered)
    }

    @Test func correctionDoneWaitsForThePromptAcknowledgement() async throws {
        let row = agent(.blocked)
        let console = FakeConsole([row])
        console.screens = [Self.permission]
        console.statuses = [.working]
        var waiting: CheckedContinuation<Void, Never>?
        var dependencies = console.dependencies
        dependencies.promptAgent = { _, _ in
            await withCheckedContinuation { waiting = $0 }
        }
        let voice = AgentVoiceService(
            dependencies: dependencies, dictation: nil, speaker: FakeSpeaker(), timing: Self.timing)
        let turn = await voice.blockedTurn(for: row.id)
        var answer: AgentVoiceService.BlockedAnswer?
        let sending = Task { answer = await voice.denyAndInstruct(turn, text: "use pnpm instead") }
        try await waitUntil { waiting != nil }
        #expect(answer == nil)
        #expect(console.keys == [["esc"]])
        waiting?.resume()
        await sending.value
        let completed = try #require(answer)
        #expect(completed.outcome == .sent)
        #expect(CarPlayTemplateCoordinator.screen(for: completed) == .answered)
    }

    @Test func uncertainCorrectionDoesNotPresentDone() async {
        let row = agent(.blocked)
        let console = FakeConsole([row])
        console.screens = [Self.permission]
        console.statuses = [.working]
        console.promptError = LinkDown()
        let (voice, _) = service(console)
        let turn = await voice.blockedTurn(for: row.id)
        let answer = await voice.denyAndInstruct(turn, text: "use pnpm instead")
        #expect(answer.spoken == CarVoiceScript.correctionNotConfirmed)
        #expect(answer.outcome == .notSent)
        #expect(CarPlayTemplateCoordinator.screen(for: answer) == .checking)
    }

    @Test func queuedAndDraftedAnswersDoNotPresentDone() async {
        let queued = AgentVoiceService.BlockedAnswer(
            spoken: CarVoiceScript.denyQueued, next: nil, outcome: .queued)
        #expect(CarPlayTemplateCoordinator.screen(for: queued) == .checking)
        let row = agent(.blocked)
        let console = FakeConsole([row])
        console.screens = [Self.permission]
        console.statuses = [.blocked]
        let (voice, _) = service(console)
        let turn = await voice.blockedTurn(for: row.id)
        let drafted = await voice.denyAndInstruct(turn, text: "use pnpm instead")
        #expect(drafted.outcome == .notSent)
        #expect(CarPlayTemplateCoordinator.screen(for: drafted) == .checking)
    }

    /// No Allow before the read-back: a question not heard in full, or not
    /// spoken at all, is never allowed.
    @Test func allowRefusesAQuestionThatWasNotHeard() async {
        let row = agent(.blocked)
        let console = FakeConsole([row])
        console.screens = [Self.permission]
        let (voice, speaker) = service(console)
        let turn = await voice.blockedTurn(for: row.id)
        #expect(await voice.allow(turn).spoken == CarVoiceScript.notAllowedFromCar)

        speaker.isHeard = false
        #expect(await voice.speakQuestion(turn, saying: turn.question) == false)
        #expect(await voice.allow(turn).spoken == CarVoiceScript.notAllowedFromCar)
        #expect(console.keys.isEmpty)
    }

    @Test func aSupersededSpeechCompletionCannotAuthorizeItsOldQuestion() async throws {
        @MainActor final class SuspendedSpeaker: AgentVoiceSpeaker {
            var waiting: [String: CheckedContinuation<Bool, Never>] = [:]
            func beginTurn() {}
            func stop() {}
            func endTurn() {}
            func speak(_ text: String) async -> Bool {
                await withCheckedContinuation { waiting[text] = $0 }
            }
            func complete(_ text: String, spoken: Bool) {
                waiting.removeValue(forKey: text)?.resume(returning: spoken)
            }
        }
        let row = agent(.blocked)
        let console = FakeConsole([row])
        console.screens = [Self.permission]
        let speaker = SuspendedSpeaker()
        let voice = AgentVoiceService(
            dependencies: console.dependencies, dictation: nil, speaker: speaker,
            timing: Self.timing)
        let first = await voice.blockedTurn(for: row.id)
        let replacement = AgentVoiceService.BlockedTurn(
            agentID: first.agentID, identity: first.identity, question: "Replacement question",
            buttons: first.buttons, snapshot: first.snapshot)
        let oldSpeech = Task { await voice.speakQuestion(first, saying: "first") }
        try await waitUntil { speaker.waiting["first"] != nil }
        let newSpeech = Task { await voice.speakQuestion(replacement, saying: "next") }
        try await waitUntil { speaker.waiting["next"] != nil }
        speaker.complete("next", spoken: false)
        #expect(await newSpeech.value == false)
        speaker.complete("first", spoken: true)
        #expect(await oldSpeech.value)
        #expect(await voice.allow(first).spoken == CarVoiceScript.notAllowedFromCar)
        #expect(console.keys.isEmpty)
    }

    @Test func aChangedPromptIsAnnouncedAgainAndNotAnswered() async {
        let row = agent(.blocked)
        let console = FakeConsole([row])
        console.screens = [Self.permission, Self.risky]
        let (voice, _) = service(console)
        let turn = await voice.blockedTurn(for: row.id)
        await voice.speakQuestion(turn, saying: turn.question)
        let answer = await voice.allow(turn)
        #expect(console.keys.isEmpty)
        #expect(answer.next?.buttons == .denyAndHold)
        #expect(answer.spoken.hasPrefix("The prompt changed."))
    }

    @Test func aCorrectionThatCannotGoOutLandsInTheDraft() async {
        let row = agent(.blocked)
        let console = FakeConsole([row])
        console.screens = [Self.permission]
        console.statuses = [.blocked]
        let (voice, _) = service(console)
        let turn = await voice.blockedTurn(for: row.id)
        let answer = await voice.denyAndInstruct(turn, text: "use pnpm instead")
        #expect(answer.spoken == CarVoiceScript.correctionDrafted)
        #expect(console.keys == [["esc"]])
        #expect(console.prompts.isEmpty)
        #expect(console.drafts == ["use pnpm instead"])
    }

    @Test func aCorrectionGoesOutWithTheSuffixOnceUnblocked() async {
        let row = agent(.blocked)
        let console = FakeConsole([row])
        console.screens = [Self.permission]
        console.statuses = [.blocked, .working]
        let (voice, _) = service(console)
        let turn = await voice.blockedTurn(for: row.id)
        let answer = await voice.denyAndInstruct(turn, text: "use pnpm instead")
        #expect(answer.spoken == CarVoiceScript.deniedAndSent)
        #expect(
            console.prompts.map(\.text)
                == [CarVoiceScript.outgoingPrompt(transcript: "use pnpm instead")])
    }

    /// A correction the Host took counts as one Review Prompt value event,
    /// through the shared action service; a drafted one counts nothing.
    @Test(arguments: [true, false])
    func aCorrectionCountsOnlyWhenItGoesOut(goesOut: Bool) async {
        @MainActor final class Counter { var events = 0 }
        let counter = Counter()
        let row = agent(.blocked)
        let console = FakeConsole([row])
        console.screens = [Self.permission]
        console.statuses = goesOut ? [.blocked, .working] : [.blocked]
        let shared = console.dependencies
        let actions = AgentActionService(
            dependencies: AgentActionService.Dependencies(
                agent: shared.agent, readScreen: shared.readScreen, sendKeys: shared.sendKeys,
                promptAgent: shared.promptAgent, insertDraft: shared.insertDraft,
                recordValueEvent: { counter.events += 1 }))
        let voice = AgentVoiceService(
            dependencies: shared, actions: actions, dictation: nil, speaker: FakeSpeaker(),
            timing: Self.timing, locale: { Locale(identifier: "en_US") })
        let turn = await voice.blockedTurn(for: row.id)
        _ = await voice.denyAndInstruct(turn, text: "use pnpm instead")
        #expect(counter.events == (goesOut ? 1 : 0))
    }

    /// A correction the Host took is followed to its Done, and the finished
    /// turn noted, by the shared action service; a drafted one is not watched.
    @Test(arguments: [true, false])
    func aCorrectionTheHostTookIsWatchedToItsDone(goesOut: Bool) async throws {
        @MainActor final class Recorder {
            var turnsDone: [ConsoleAgent.ID] = []
            var streamsRequested = 0
        }
        let recorder = Recorder()
        let row = agent(.blocked)
        let console = FakeConsole([row])
        console.screens = [Self.permission]
        console.statuses = goesOut ? [.blocked, .working] : [.blocked]
        // What the Console tells the watcher once the correction is out:
        // the Agent was Blocked at the send (the seed), then works, then
        // is done.
        let (watched, feed) = AsyncStream.makeStream(of: ConsoleStore.AgentStatusUpdate.self)
        feed.yield(.init(status: .working, liveUpdatesAvailable: true))
        feed.yield(.init(status: .done, liveUpdatesAvailable: true))
        let shared = console.dependencies
        let actions = AgentActionService(
            dependencies: AgentActionService.Dependencies(
                agent: shared.agent, readScreen: shared.readScreen, sendKeys: shared.sendKeys,
                promptAgent: shared.promptAgent, insertDraft: shared.insertDraft,
                noteTurnCompleted: { recorder.turnsDone.append($0) },
                statusUpdates: { _ in
                    recorder.streamsRequested += 1
                    return watched
                }))
        let voice = AgentVoiceService(
            dependencies: shared, actions: actions, dictation: nil, speaker: FakeSpeaker(),
            timing: Self.timing, locale: { Locale(identifier: "en_US") })
        let turn = await voice.blockedTurn(for: row.id)
        _ = await voice.denyAndInstruct(turn, text: "use pnpm instead")
        let expected: [ConsoleAgent.ID] = goesOut ? [row.id] : []
        if goesOut {
            try await waitUntil { recorder.turnsDone == expected }
        }
        #expect(recorder.turnsDone == expected)
        #expect(recorder.streamsRequested == (goesOut ? 1 : 0))
    }

    // MARK: Listening

    @Test func listeningUsesTheCarProfileAndEndsAfterSpeech() async throws {
        let engine = ScriptedDictationEngine()
        let console = FakeConsole([agent(.idle)])
        let (voice, speaker) = service(console, dictation: engine)
        let listen = Task { await voice.listen() }
        try await waitUntil { engine.hasLiveSession }
        engine.emit(.listening)
        engine.emit(.transcript("what failed", isFinal: false))
        #expect(await listen.value == .heard("what failed"))
        #expect(engine.audioProfiles == [.car])
        #expect(engine.finishCount == 1)
        #expect(speaker.turnsBegun == 1)
    }

    @Test func silenceGivesUp() async throws {
        let engine = ScriptedDictationEngine()
        let (voice, _) = service(FakeConsole([agent(.idle)]), dictation: engine)
        let listen = Task { await voice.listen() }
        try await waitUntil { engine.hasLiveSession }
        engine.emit(.listening)
        #expect(await listen.value == .silence)
    }

    /// An engine stuck before the microphone opens (a permission prompt
    /// nobody can answer with the phone locked, a model download) ignores
    /// `finish`; the startup bound still ends the listen and the session.
    @Test func aListenStuckInStartupEndsAtTheBound() async throws {
        let engine = ScriptedDictationEngine()
        engine.ignoresFinish = true
        var timing = Self.timing
        timing.startup = .milliseconds(80)
        let (voice, _) = service(FakeConsole([agent(.idle)]), dictation: engine, timing: timing)
        #expect(await voice.listen() == .failed(AgentVoiceService.voiceNotReady))
        #expect(engine.wasTerminated)
    }

    @Test func engineErrorsAreSpeakable() async throws {
        let engine = ScriptedDictationEngine()
        let (voice, _) = service(FakeConsole([agent(.idle)]), dictation: engine)
        let listen = Task { await voice.listen() }
        try await waitUntil { engine.hasLiveSession }
        engine.fail(.microphonePermissionDenied)
        #expect(await listen.value == .failed("Waycar doesn't have microphone access."))
        let (unavailable, _) = service(FakeConsole([]))
        #expect(await unavailable.listen() == .failed(AgentVoiceService.voiceUnavailable))
    }

    @Test func confirmationAndApprovalVocabulariesAreClosed() {
        #expect(AgentVoiceService.confirmation(in: "Send.") == .send)
        #expect(AgentVoiceService.confirmation(in: "uh, yes please") == .send)
        #expect(AgentVoiceService.confirmation(in: "Don't send") == .cancel)
        #expect(AgentVoiceService.confirmation(in: "send it to Codex instead") == nil)
        #expect(AgentVoiceService.spokenApproval(in: "Allow.") == .allow)
        #expect(AgentVoiceService.spokenApproval(in: "um, approve please") == .allow)
        #expect(AgentVoiceService.spokenApproval(in: "No") == .deny)
        #expect(AgentVoiceService.spokenApproval(in: "cancel") == .stop)
        #expect(AgentVoiceService.spokenApproval(in: "yes do it") == nil)
        #expect(AgentVoiceService.correction(in: "No, use pnpm instead.") == "use pnpm instead.")
        #expect(AgentVoiceService.correction(in: "no") == nil)
    }

    /// A Blocked reply: exits end the turn before any correction is
    /// read back; a lone unknown word is no answer.
    @Test func blockedRepliesExitBeforeCorrecting() {
        #expect(AgentVoiceService.blockedReply(to: "Allow") == .allow)
        #expect(AgentVoiceService.blockedReply(to: "no") == .deny)
        #expect(AgentVoiceService.blockedReply(to: "cancel") == .exit)
        #expect(AgentVoiceService.blockedReply(to: "never mind") == .exit)
        #expect(AgentVoiceService.blockedReply(to: "That's all.") == .exit)
        #expect(AgentVoiceService.blockedReply(to: "No thank you") == .exit)
        #expect(
            AgentVoiceService.blockedReply(to: "No, use pnpm instead.")
                == .correction("use pnpm instead."))
        #expect(AgentVoiceService.blockedReply(to: "banana") == .unrecognized)
    }

    @Test func endpointingRules() {
        let start = ContinuousClock.now
        var endpointer = Endpointer(
            startedAt: start, endOfSpeech: .milliseconds(1200), noSpeech: .seconds(8),
            maximum: .seconds(20), startup: .seconds(15))
        #expect(endpointer.finishReason(now: start + .seconds(14)) == nil)
        #expect(endpointer.finishReason(now: start + .seconds(15)) == .startup)
        endpointer.listeningStarted(at: start + .seconds(1))
        #expect(endpointer.finishReason(now: start + .seconds(8)) == nil)
        #expect(endpointer.finishReason(now: start + .seconds(9)) == .noSpeech)
        endpointer.heardSpeech(at: start + .seconds(2))
        #expect(endpointer.finishReason(now: start + .seconds(3)) == nil)
        #expect(endpointer.finishReason(now: start + .milliseconds(3200)) == .endOfSpeech)
        endpointer.heardSpeech(at: start + .seconds(21))
        #expect(endpointer.finishReason(now: start + .seconds(21)) == .maximum)
    }

    // MARK: Conversation

    /// A conversation over a scripted microphone, its phases recorded.
    @MainActor
    final class ConversationHarness {
        let engine = ScriptedDictationEngine()
        let console: FakeConsole
        let speaker: FakeSpeaker
        let conversation: AgentVoiceConversation
        private(set) var phases: [AgentVoiceConversation.Phase] = []

        init(console: FakeConsole, agentID: ConsoleAgent.ID, timing: AgentVoiceService.Timing) {
            self.console = console
            let speaker = FakeSpeaker()
            self.speaker = speaker
            let voice = AgentVoiceService(
                dependencies: console.dependencies, dictation: engine, speaker: speaker,
                timing: timing, locale: { Locale(identifier: "en_US") })
            var record: (AgentVoiceConversation.Phase) -> Void = { _ in }
            conversation = AgentVoiceConversation(agentID: agentID, voice: voice) { record($0) }
            record = { [unowned self] in self.phases.append($0) }
        }
    }

    /// "what failed", then a pause: the question goes out with no read-back.
    private func askOnce(_ harness: ConversationHarness) async throws {
        harness.conversation.start()
        try await say("what failed", listen: 1, on: harness.engine)
    }

    /// Waits for the `listen`th microphone session and speaks `text` into it.
    private func say(_ text: String, listen: Int, on engine: ScriptedDictationEngine) async throws {
        try await waitUntil { engine.audioProfiles.count == listen && engine.hasLiveSession }
        engine.emit(.listening)
        engine.emit(.transcript(text, isFinal: false))
    }

    private func repliedConsole() -> (FakeConsole, ConsoleAgent) {
        let row = agent(.idle)
        let console = FakeConsole([row])
        console.transcripts = [
            Self.transcript([Self.message("a1", .assistant, "Old.")]),
            Self.transcript([
                Self.message("u2", .user, "what failed"),
                Self.message("a2", .assistant, "Two tests failed. Both are flaky. I reran them."),
            ]),
        ]
        return (console, row)
    }

    /// A pause sends what was heard at once: no read-back, no Send. The
    /// reply is spoken on the session the question went out on, then the
    /// same Agent is listened to again.
    @Test func aPauseSendsTheQuestionAndTheReplyIsSpokenOnTheSameSession() async throws {
        let (console, row) = repliedConsole()
        let harness = ConversationHarness(console: console, agentID: row.id, timing: Self.timing)
        try await askOnce(harness)
        try await waitUntil { harness.engine.audioProfiles.count == 2 && harness.engine.hasLiveSession }
        #expect(
            console.prompts.map(\.text) == [CarVoiceScript.outgoingPrompt(transcript: "what failed")])
        #expect(
            harness.phases == [
                .listening(followUp: false), .sending, .waiting, .replying,
                .listening(followUp: true),
            ])
        // The introduction, then the reply: nothing read back.
        #expect(harness.speaker.spoken.count == 2)
        #expect(harness.speaker.spoken.last == "Two tests failed. Both are flaky.")
        #expect(!harness.speaker.spoken.contains { $0.hasSuffix("Send?") })
        // Never released between the send and the reply.
        #expect(harness.speaker.turnsEnded == 0)
        harness.conversation.end()
    }

    /// A second question on the follow-up listen goes out the same way.
    @Test func aFollowUpQuestionIsSentToo() async throws {
        let (console, row) = repliedConsole()
        let harness = ConversationHarness(console: console, agentID: row.id, timing: Self.timing)
        try await askOnce(harness)
        try await say("and why", listen: 2, on: harness.engine)
        try await waitUntil { console.prompts.count == 2 }
        #expect(
            console.prompts.last?.text == CarVoiceScript.outgoingPrompt(transcript: "and why"))
        harness.conversation.end()
    }

    /// Silence is no end: the microphone opens again and again until
    /// nothing was said for `conversationIdle`, then the turn ends quietly
    /// and gives the audio back.
    @Test func silenceKeepsListeningUntilTheIdleCap() async throws {
        // Several silent listens fit in the cap even on a loaded simulator.
        var timing = Self.timing
        timing.conversationIdle = .seconds(1)
        let (console, row) = repliedConsole()
        let harness = ConversationHarness(console: console, agentID: row.id, timing: timing)
        harness.conversation.start()
        var listens = 0
        while !harness.conversation.isEnded, listens < 50 {
            listens += 1
            try await waitUntil {
                harness.conversation.isEnded
                    || (harness.engine.audioProfiles.count == listens
                        && harness.engine.hasLiveSession)
            }
            harness.engine.emit(.listening)
        }
        #expect(harness.engine.audioProfiles.count >= 3)
        #expect(harness.phases == [.listening(followUp: false), .ended(.silence)])
        #expect(console.prompts.isEmpty)
        // The introduction only.
        #expect(harness.speaker.spoken.count == 1)
        #expect(harness.speaker.turnsEnded == 1)
    }

    /// A reply the speaker could not get out (after its own retry and
    /// fallback) still leaves the driver free to ask again.
    @Test func anUnheardReplyStillListensAgain() async throws {
        let (console, row) = repliedConsole()
        let harness = ConversationHarness(console: console, agentID: row.id, timing: Self.timing)
        harness.speaker.isHeard = false
        try await askOnce(harness)
        try await waitUntil { harness.engine.audioProfiles.count == 2 && harness.engine.hasLiveSession }
        #expect(harness.speaker.spoken.last == "Two tests failed. Both are flaky.")
        #expect(harness.phases.last == .listening(followUp: true))
        #expect(harness.speaker.turnsEnded == 0)
        harness.conversation.end()
    }

    /// CarPlay's close on the follow-up listen: the microphone closes,
    /// nothing more is said or listened to.
    @Test func closingEndsTheFollowUpListen() async throws {
        let (console, row) = repliedConsole()
        let harness = ConversationHarness(console: console, agentID: row.id, timing: Self.timing)
        try await askOnce(harness)
        try await waitUntil { harness.engine.audioProfiles.count == 2 && harness.engine.hasLiveSession }
        let spokenBefore = harness.speaker.spoken.count
        let endedBefore = harness.speaker.turnsEnded
        harness.conversation.end()
        #expect(harness.phases.last == .ended(.driver))
        #expect(harness.speaker.turnsEnded == endedBefore + 1)
        try await waitUntil { harness.engine.wasTerminated }
        try await Task.sleep(for: .milliseconds(200))
        #expect(harness.engine.audioProfiles.count == 2)
        #expect(harness.speaker.spoken.count == spokenBefore)
        #expect(harness.phases.filter { if case .ended = $0 { true } else { false } }.count == 1)
        #expect(console.prompts.count == 1)
    }

    /// The scene left the car's screen while the reply was awaited: the
    /// reply that lands later is never spoken and nothing listens again.
    @Test func backgroundWhileWaitingEndsWithoutSpeakingTheReply() async throws {
        let row = agent(.working)
        let console = FakeConsole([row])
        console.transcripts = [Self.transcript([Self.message("a1", .assistant, "Old.")])]
        let harness = ConversationHarness(console: console, agentID: row.id, timing: Self.timing)
        try await askOnce(harness)
        try await waitUntil { harness.phases.last == .waiting }
        // The session stays up while the Agent works.
        #expect(harness.speaker.turnsEnded == 0)
        let spokenBefore = harness.speaker.spoken.count
        harness.conversation.end()
        console.transcripts = [
            Self.transcript([Self.message("a1", .assistant, "Old.")]),
            Self.transcript([Self.message("a2", .assistant, "Late answer.")]),
        ]
        console.agents = [agent(.done)]
        try await Task.sleep(for: .milliseconds(200))
        #expect(harness.phases.last == .ended(.driver))
        #expect(harness.speaker.spoken.count == spokenBefore)
        #expect(harness.engine.audioProfiles.count == 1)
        #expect(console.prompts.count == 1)
    }

    /// "That's all" on the follow-up listen ends it quietly: nothing sent,
    /// no draft, and the screen closes at once.
    @Test func aSpokenExitOnTheFollowUpEndsQuietly() async throws {
        let (console, row) = repliedConsole()
        let harness = ConversationHarness(console: console, agentID: row.id, timing: Self.timing)
        try await askOnce(harness)
        try await waitUntil { harness.engine.audioProfiles.count == 2 && harness.engine.hasLiveSession }
        let spokenBefore = harness.speaker.spoken.count
        harness.engine.emit(.listening)
        harness.engine.emit(.transcript("Okay, that's all.", isFinal: false))
        try await waitUntil { harness.conversation.isEnded }
        #expect(harness.phases.last == .ended(.driver))
        #expect(harness.speaker.spoken.count == spokenBefore)
        #expect(harness.speaker.turnsEnded == 1)
        #expect(console.prompts.count == 1)
        #expect(console.drafts.isEmpty)
        #expect(
            harness.phases.last.map(CarPlayTemplateCoordinator.screen(for:))
                == .close(after: .zero))
    }

    @Test func conversationPhasesMapToTheTemplate() {
        typealias Screen = CarPlayTemplateCoordinator.ConversationScreen
        let cases: [(AgentVoiceConversation.Phase, Screen)] = [
            (.listening(followUp: false), .show(.listening)),
            (.listening(followUp: true), .show(.listening)),
            (.sending, .show(.sending)),
            (.waiting, .show(.waiting)),
            (.replying, .show(.replying)),
            // A close, a spoken exit, the scene leaving the car's screen.
            (.ended(.driver), .close(after: .zero)),
            (.ended(.silence), .close(after: CarPlayTemplateCoordinator.minimumStateDwell)),
            (.ended(.finished), .close(after: CarPlayTemplateCoordinator.minimumStateDwell)),
        ]
        for (phase, screen) in cases {
            #expect(CarPlayTemplateCoordinator.screen(for: phase) == screen, "\(phase)")
        }
    }

    // MARK: Car speaker

    /// A speech engine whose lines play, fail, or hang until stopped.
    @MainActor
    final class FakeSpeechEngine: CarSpeechEngine {
        /// Each line's result in order; once empty, lines play.
        var results: [Bool] = []
        /// The next line plays until `stop()`.
        var holdsNextLine = false
        /// `pause()` holds the line; else the speaker has to stop it.
        var pausable = false
        var resumable = true
        var spokenOffset = 0
        var playbackProgress = 0
        var onExternalPause: (@MainActor () -> Void)?
        private(set) var lines: [String] = []
        private(set) var pauses = 0
        private(set) var resumes = 0
        private(set) var isPaused = false
        private var held: CheckedContinuation<Bool, Never>?
        var delaysStopCompletion = false
        private var stoppedLine: CheckedContinuation<Bool, Never>?

        func finishStoppedLine() {
            stoppedLine?.resume(returning: false)
            stoppedLine = nil
        }

        var isHolding: Bool { held != nil }

        func speak(_ text: String) async -> Bool {
            lines.append(text)
            if holdsNextLine {
                holdsNextLine = false
                return await withCheckedContinuation { held = $0 }
            }
            return results.isEmpty ? true : results.removeFirst()
        }

        func stop() {
            isPaused = false
            if delaysStopCompletion {
                stoppedLine = held
            } else {
                held?.resume(returning: false)
            }
            held = nil
        }

        func pause() -> Bool {
            guard pausable, held != nil else { return false }
            pauses += 1
            isPaused = true
            return true
        }

        func resume() -> Bool {
            guard isPaused, resumable else { return false }
            resumes += 1
            isPaused = false
            return true
        }

        /// The held line ends: played out, or cut by iOS (`didCancel`).
        func finishHeld(_ spoken: Bool) {
            held?.resume(returning: spoken)
            held = nil
        }

        /// iOS paused the synthesizer without an interruption (`didPause`).
        func pauseExternally() {
            isPaused = true
            onExternalPause?()
        }
    }

    @MainActor
    final class FakeAudioSession {
        private(set) var activations = 0
        private(set) var deactivations = 0
        /// This many activations are refused, then they succeed.
        var refusals = 0

        var session: CarSpeaker.AudioSession {
            CarSpeaker.AudioSession(
                activate: {
                    self.activations += 1
                    guard self.refusals == 0 else {
                        self.refusals -= 1
                        throw LinkDown()
                    }
                },
                deactivate: { self.deactivations += 1 },
                isSilenced: { false },
                route: { "out=CarAudio in=CarAudio rate=48000" })
        }
    }

    @Test func anOldLineCannotReleaseItsReplacementsEngine() async throws {
        let engine = FakeSpeechEngine()
        engine.delaysStopCompletion = true
        engine.pausable = true
        let audio = FakeAudioSession()
        let speaker = CarSpeaker(system: engine, natural: { nil }, session: audio.session)
        speaker.beginTurn()
        engine.holdsNextLine = true
        let first = Task { await speaker.speak("First") }
        try await waitUntilTrue("first line started") { engine.lines == ["First"] }
        engine.holdsNextLine = true
        let second = Task { await speaker.speak("Second") }
        try await waitUntilTrue("replacement started") { engine.lines == ["First", "Second"] }
        engine.finishStoppedLine()
        #expect(await first.value == false)
        #expect(engine.onExternalPause != nil)
        speaker.interruptionBegan()
        #expect(engine.pauses == 1, "the replacement still owns interruption handling")
        engine.delaysStopCompletion = false
        speaker.stop()
        #expect(!engine.isHolding, "stop must still reach the replacement")
        // Release even on the broken implementation, which lost `speaking`.
        engine.finishHeld(false)
        #expect(await second.value == false)
        speaker.endTurn()
    }

    /// A Natural voice line that fails is tried once more on a reactivated
    /// session, then spoken by the system voice.
    @Test func aFailedLineIsRetriedThenSpokenByTheSystemVoice() async {
        let natural = FakeSpeechEngine()
        natural.results = [false, false]
        let system = FakeSpeechEngine()
        let audio = FakeAudioSession()
        let speaker = CarSpeaker(system: system, natural: { natural }, session: audio.session)
        speaker.beginTurn()
        #expect(await speaker.speak("Two tests failed."))
        #expect(natural.lines == ["Two tests failed.", "Two tests failed."])
        #expect(system.lines == ["Two tests failed."])
        // The turn's activation, then the retry's.
        #expect(audio.activations == 2)
        #expect(audio.deactivations == 0)
    }

    /// A Natural voice that switched itself off after failing is not tried
    /// again: the retry goes to the system voice, which speaks once.
    @Test func theRetryPicksTheEngineAgain() async {
        let natural = FakeSpeechEngine()
        natural.results = [false]
        let system = FakeSpeechEngine()
        // Off once it has tried a line, as `NaturalVoice.fail` leaves it.
        let speaker = CarSpeaker(
            system: system, natural: { natural.lines.isEmpty ? natural : nil },
            session: FakeAudioSession().session)
        speaker.beginTurn()
        #expect(await speaker.speak("Two tests failed."))
        #expect(natural.lines == ["Two tests failed."])
        #expect(system.lines == ["Two tests failed."])
    }

    /// The silent-reply bug: the session would not activate for the reply.
    /// The retry activates it again and the line is heard.
    @Test func aRefusedActivationIsRetriedBeforeTheLineIsDropped() async {
        let system = FakeSpeechEngine()
        let audio = FakeAudioSession()
        audio.refusals = 2
        let speaker = CarSpeaker(system: system, natural: { nil }, session: audio.session)
        speaker.beginTurn()
        #expect(await speaker.speak("Two tests failed."))
        #expect(system.lines == ["Two tests failed."])
        #expect(audio.activations == 3)

        let refused = FakeAudioSession()
        refused.refusals = 10
        let silent = CarSpeaker(system: system, natural: { nil }, session: refused.session)
        silent.beginTurn()
        #expect(await silent.speak("Gone.") == false)
    }

    /// A refused activation never starts the line, so the engine's offset
    /// still belongs to its previous line: the retry speaks the whole line.
    @Test func aStaleOffsetAfterARefusedActivationReplaysTheWholeLine() async {
        let system = FakeSpeechEngine()
        // Where the previous reply ended.
        system.spokenOffset = "Done. Pushed the fix to".utf16.count
        let audio = FakeAudioSession()
        // The line's own activation is refused; the retry's succeeds.
        audio.refusals = 1
        let speaker = CarSpeaker(system: system, natural: { nil }, session: audio.session)
        let text = "Done. Pushed the fix to main."
        #expect(await speaker.speak(text))
        #expect(system.lines == [text])
    }

    /// A stopped line is the driver's doing: no retry, no fallback.
    @Test func aStoppedLineIsNotRetried() async throws {
        let natural = FakeSpeechEngine()
        natural.holdsNextLine = true
        let system = FakeSpeechEngine()
        let speaker = CarSpeaker(
            system: system, natural: { natural }, session: FakeAudioSession().session)
        speaker.beginTurn()
        let line = Task { await speaker.speak("Two tests failed.") }
        try await waitUntil { natural.isHolding }
        speaker.stop()
        #expect(await line.value == false)
        #expect(natural.lines.count == 1)
        #expect(system.lines.isEmpty)
    }

    /// An interruption cuts the line at once instead of leaving it hanging;
    /// once it ends, the session comes back and the line plays again.
    @Test func anInterruptionCutsTheLineAndItsEndPlaysItAgain() async throws {
        let system = FakeSpeechEngine()
        system.holdsNextLine = true
        let audio = FakeAudioSession()
        let speaker = CarSpeaker(
            system: system, natural: { nil }, session: audio.session,
            interruptionWait: .seconds(3))
        speaker.beginTurn()
        let line = Task { await speaker.speak("Two tests failed.") }
        try await waitUntil { system.isHolding }
        speaker.interruptionBegan()
        try await Task.sleep(for: .milliseconds(150))
        // Waiting the interruption out, not retrying into it.
        #expect(system.lines.count == 1)
        speaker.interruptionEnded(shouldResume: true)
        #expect(await line.value)
        #expect(system.lines.count == 2)
        #expect(audio.activations > 1)
    }

    /// A notification over a reply pauses the line where it is; its end
    /// plays the same line on, without speaking anything again.
    @Test func anInterruptionPausesTheLineAndItsEndResumesIt() async throws {
        let system = FakeSpeechEngine()
        system.holdsNextLine = true
        system.pausable = true
        let audio = FakeAudioSession()
        let speaker = CarSpeaker(
            system: system, natural: { nil }, session: audio.session,
            interruptionWait: .seconds(3))
        speaker.beginTurn()
        let line = Task { await speaker.speak("Two tests failed. Fixing them now.") }
        try await waitUntil { system.isHolding }
        speaker.interruptionBegan()
        #expect(system.isPaused)
        try await Task.sleep(for: .milliseconds(150))
        #expect(system.isHolding)
        speaker.interruptionEnded(shouldResume: true)
        #expect(system.resumes == 1)
        #expect(!system.isPaused)
        system.finishHeld(true)
        #expect(await line.value)
        #expect(system.lines == ["Two tests failed. Fixing them now."])
        #expect(audio.activations > 1)
    }

    /// A resumed line that plays nothing (iOS flushed its queued audio) is
    /// cut once the stall wait passes and replayed from its sentence; one
    /// that makes progress keeps playing.
    @Test func aResumedLineWithoutProgressReplaysFromItsSentence() async throws {
        let system = FakeSpeechEngine()
        system.holdsNextLine = true
        system.pausable = true
        let speaker = CarSpeaker(
            system: system, natural: { nil }, session: FakeAudioSession().session,
            interruptionWait: .seconds(3), resumeStallWait: .milliseconds(200))
        speaker.beginTurn()
        let text = "Two tests failed. Fixing them now."
        let line = Task { await speaker.speak(text) }
        try await waitUntil { system.isHolding }
        system.spokenOffset = "Two tests failed. Fix".utf16.count
        speaker.interruptionBegan()
        speaker.interruptionEnded(shouldResume: true)
        #expect(system.resumes == 1)
        #expect(await line.value)
        #expect(system.lines == [text, "Fixing them now."])

        system.holdsNextLine = true
        let next = Task { await speaker.speak(text) }
        try await waitUntil { system.isHolding }
        speaker.interruptionBegan()
        speaker.interruptionEnded(shouldResume: true)
        // Audible progress throughout: every window sees some.
        for _ in 0..<8 {
            system.playbackProgress += 1
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(system.isHolding)
        system.finishHeld(true)
        #expect(await next.value)
        #expect(system.lines.count == 3)
    }

    /// The stall watch keeps watching after the first window shows
    /// progress: a line that stalls later is still cut and replayed.
    @Test func theResumeStallWatchReArms() async throws {
        let system = FakeSpeechEngine()
        system.holdsNextLine = true
        system.pausable = true
        let speaker = CarSpeaker(
            system: system, natural: { nil }, session: FakeAudioSession().session,
            interruptionWait: .seconds(3), resumeStallWait: .milliseconds(200))
        speaker.beginTurn()
        let text = "Two tests failed. Fixing them now."
        let line = Task { await speaker.speak(text) }
        try await waitUntil { system.isHolding }
        system.spokenOffset = "Two tests failed. Fix".utf16.count
        speaker.interruptionBegan()
        speaker.interruptionEnded(shouldResume: true)
        #expect(system.resumes == 1)
        // Progress inside the first window only, then nothing.
        try await Task.sleep(for: .milliseconds(100))
        system.playbackProgress += 1
        try await Task.sleep(for: .milliseconds(150))
        #expect(system.isHolding)
        #expect(await line.value)
        #expect(system.lines == [text, "Fixing them now."])
    }

    /// An interruption that outlasts the wait cuts the paused line, which
    /// plays again from the start of the sentence it stopped in.
    @Test func aLineNotResumedInTimeReplaysFromItsSentence() async throws {
        let system = FakeSpeechEngine()
        system.holdsNextLine = true
        system.pausable = true
        let speaker = CarSpeaker(
            system: system, natural: { nil }, session: FakeAudioSession().session,
            interruptionWait: .milliseconds(300))
        speaker.beginTurn()
        let text = "Two tests failed. Fixing them now. Then pushing."
        let line = Task { await speaker.speak(text) }
        try await waitUntil { system.isHolding }
        // Mid-way through "Fixing".
        system.spokenOffset = "Two tests failed. Fix".utf16.count
        speaker.interruptionBegan()
        #expect(await line.value)
        #expect(system.lines == [text, "Fixing them now. Then pushing."])
    }

    /// iOS paused the synthesizer with no interruption posted: the line is
    /// held, then resumed on a reactivated session.
    @Test func anExternalPauseIsResumed() async throws {
        let system = FakeSpeechEngine()
        system.holdsNextLine = true
        let audio = FakeAudioSession()
        let speaker = CarSpeaker(
            system: system, natural: { nil }, session: audio.session,
            interruptionWait: .seconds(3))
        speaker.beginTurn()
        let line = Task { await speaker.speak("Two tests failed.") }
        try await waitUntil { system.isHolding }
        system.pauseExternally()
        try await waitUntil { system.resumes == 1 }
        system.finishHeld(true)
        #expect(await line.value)
        #expect(system.lines == ["Two tests failed."])
        #expect(audio.activations == 2)
    }

    /// iOS cancelled the line (`didCancel`) with no interruption posted:
    /// the rest is spoken from the start of the sentence it stopped in.
    @Test func anExternalCancelReplaysFromItsSentence() async throws {
        let system = FakeSpeechEngine()
        system.holdsNextLine = true
        let speaker = CarSpeaker(
            system: system, natural: { nil }, session: FakeAudioSession().session)
        speaker.beginTurn()
        let line = Task { await speaker.speak("Two tests failed. Fixing them now.") }
        try await waitUntil { system.isHolding }
        system.spokenOffset = "Two tests failed. Fixing them".utf16.count
        system.finishHeld(false)
        #expect(await line.value)
        #expect(system.lines == ["Two tests failed. Fixing them now.", "Fixing them now."])
    }

    @Test func unfinishedTextStartsAtTheSentenceReached() {
        let text = "One.  Two words here. Three?"
        #expect(CarLine.unfinished(text, from: 0) == text)
        #expect(CarLine.unfinished(text, from: 2) == text)
        #expect(CarLine.unfinished(text, from: "One.  Tw".utf16.count) == "Two words here. Three?")
        #expect(CarLine.unfinished(text, from: text.utf16.count) == "Three?")
    }

    /// The session is the turn's: lines come and go, and only the turn's
    /// end gives the car its audio back.
    @Test func theSessionIsReleasedOnlyWhenTheTurnEnds() async {
        let audio = FakeAudioSession()
        let speaker = CarSpeaker(
            system: FakeSpeechEngine(), natural: { nil }, session: audio.session)
        speaker.beginTurn()
        #expect(await speaker.speak("Sending."))
        #expect(await speaker.speak("Two tests failed."))
        #expect(audio.deactivations == 0)
        speaker.endTurn()
        #expect(audio.deactivations == 1)
        #expect(audio.activations == 1)
    }

    @Test func spokenExitsAreWholeUtterancesOnly() {
        for exit in ["Stop.", "done", "uh, that's all", "No thanks!", "thank you", "That’s it"] {
            #expect(AgentVoiceService.isConversationExit(exit), "\(exit)")
        }
        for question in ["stop the server", "is it done", "thanks, now run the tests", ""] {
            #expect(!AgentVoiceService.isConversationExit(question), "\(question)")
        }
    }

    /// The microphone opens only after the line before it had time to
    /// stop ringing out in the car.
    @Test func theMicrophoneOpensAfterTheSpeechSettles() async throws {
        let engine = ScriptedDictationEngine()
        var timing = Self.timing
        timing.speechSettle = .milliseconds(250)
        let (voice, _) = service(FakeConsole([agent(.idle)]), dictation: engine, timing: timing)
        let started = ContinuousClock.now
        let listen = Task { await voice.listen() }
        try await waitUntil { engine.hasLiveSession }
        #expect(started.duration(to: .now) >= .milliseconds(250))
        engine.emit(.listening)
        #expect(await listen.value == .silence)
    }

    @Test func spokenIdentityUsesTheAgentName() {
        #expect(AgentVoiceService.spokenIdentity(of: agent(.idle, name: "notes")) == "iOS App notes")
        #expect(AgentVoiceService.spokenIdentity(of: agent(.idle)) == "iOS App Claude")
        #expect(!AgentVoiceService.spokenIdentity(of: agent(.idle)).contains("·"))
    }
}
