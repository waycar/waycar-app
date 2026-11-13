import Foundation
import Observation
import Testing

@testable import Waycar

@MainActor
@Suite("Dictation sender")
struct DictationSenderTests {
    @Test func stopSendsEverythingHeardAndLeavesTheDraftAlone() async throws {
        let (engine, sender, transport, composer) = makeFixture()
        composer.replaceDraft(with: "half-typed draft")
        engine.finalSegmentOnFinish = "and ship it. "

        sender.start()
        engine.emit(.listening)
        engine.emit(.transcript("  Fix the bug", isFinal: true))
        try await applied(0.5, engine, sender.dictation)

        let result = await sender.stopAndSend(through: composer)

        #expect(result == .deliveredViaPrompt)
        #expect(
            await transport.agentPromptParams == [
                AgentPromptParams(target: "w1:p1", text: "Fix the bug and ship it.")
            ])
        #expect(composer.draft == "half-typed draft")
        #expect(sender.dictation.phase == .idle)
    }

    @Test func nothingSaidSendsNothing() async throws {
        let (engine, sender, transport, composer) = makeFixture()

        sender.start()
        engine.emit(.listening)
        engine.emit(.transcript("   ", isFinal: true))
        try await applied(0.5, engine, sender.dictation)

        #expect(await sender.stopAndSend(through: composer) == .ignored)
        #expect(await transport.agentPromptParams.isEmpty)
        #expect(composer.messages.isEmpty)
    }

    /// Leaving the collapsed Composer or changing Agent mid-sentence must
    /// not deliver the half-sentence later.
    @Test func teardownDropsWhatWasHeard() async throws {
        let (engine, sender, transport, composer) = makeFixture()

        sender.start()
        engine.emit(.listening)
        engine.emit(.transcript("Half a thought", isFinal: false))
        try await applied(0.5, engine, sender.dictation)
        sender.cancel()
        try await waitUntil { sender.dictation.phase == .idle }

        #expect(await sender.stopAndSend(through: composer) == .ignored)

        sender.start()
        engine.emit(.listening)
        engine.emit(.transcript("A new thought", isFinal: true))
        try await applied(0.25, engine, sender.dictation)

        #expect(await sender.stopAndSend(through: composer) == .deliveredViaPrompt)
        #expect(
            await transport.agentPromptParams == [
                AgentPromptParams(target: "w1:p1", text: "A new thought")
            ])
    }

    @Test(arguments: [false, true])
    func teardownAfterRecognitionDropsBufferedWords(send: Bool) async throws {
        let (engine, sender, transport, composer) = makeFixture()
        composer.replaceDraft(with: "Existing draft")
        sender.start()
        engine.emit(.listening)
        engine.emit(.transcript("Discard these words", isFinal: true))
        try await applied(0.5, engine, sender.dictation)
        await engine.finish(DictationSessionID())
        try await waitUntil { sender.dictation.phase == .idle }

        sender.cancel()

        if send {
            #expect(await sender.stopAndSend(through: composer) == .ignored)
        } else {
            #expect(!sender.keepInterrupted(in: composer))
            #expect(!(await sender.stopAndKeep(in: composer)))
        }
        #expect(composer.draft == "Existing draft")
        #expect(await transport.agentPromptParams.isEmpty)
    }

    @Test func stopAndKeepPutsWhatWasHeardInTheDraftAndSendsNothing() async throws {
        let (engine, sender, transport, composer) = makeFixture()
        composer.replaceDraft(with: "half-typed draft")
        engine.finalSegmentOnFinish = "and ship it. "

        sender.start()
        engine.emit(.listening)
        engine.emit(.transcript("  Fix the bug", isFinal: true))
        try await applied(0.5, engine, sender.dictation)

        #expect(await sender.stopAndKeep(in: composer))
        #expect(composer.draft == "half-typed draft Fix the bug and ship it.")
        #expect(await transport.agentPromptParams.isEmpty)
        #expect(composer.messages.isEmpty)
        #expect(sender.dictation.phase == .idle)
    }

    /// A call or route change ends the session without the person's stop;
    /// what was heard is kept for review rather than sent unasked.
    @Test func interruptionKeepsWhatWasHeardInTheDraftAndSendsNothing() async throws {
        let (engine, sender, transport, composer) = makeFixture()
        composer.replaceDraft(with: "half-typed draft")

        sender.start()
        engine.emit(.listening)
        engine.emit(.transcript("Fix the bug", isFinal: true))
        try await applied(0.5, engine, sender.dictation)
        // The live engine's interruption handler finishes its own session.
        await engine.finish(DictationSessionID())
        try await waitUntil { sender.dictation.phase == .idle }

        #expect(sender.keepInterrupted(in: composer))
        #expect(composer.draft == "half-typed draft Fix the bug")
        #expect(await transport.agentPromptParams.isEmpty)
        #expect(composer.messages.isEmpty)
        #expect(!sender.keepInterrupted(in: composer))
        #expect(composer.draft == "half-typed draft Fix the bug")
    }

    @Test func interruptionAfterTeardownKeepsNothing() async throws {
        let (engine, sender, transport, composer) = makeFixture()
        composer.replaceDraft(with: "half-typed draft")

        sender.start()
        engine.emit(.listening)
        engine.emit(.transcript("Half a thought", isFinal: true))
        try await applied(0.5, engine, sender.dictation)
        sender.cancel()
        try await waitUntil { sender.dictation.phase == .idle }

        #expect(!sender.keepInterrupted(in: composer))
        #expect(composer.draft == "half-typed draft")
        #expect(await transport.agentPromptParams.isEmpty)
    }

    /// The Composer checks for an interruption whenever the phase turns
    /// idle, including the idle a stop ends in; that check must not take the
    /// words the stop is about to send.
    @Test func interruptionCheckDuringStopDoesNotDeliverTwice() async throws {
        let (engine, sender, transport, composer) = makeFixture()

        sender.start()
        engine.emit(.listening)
        engine.emit(.transcript("Ship it", isFinal: true))
        try await applied(0.5, engine, sender.dictation)

        let checks = InterruptionChecks()
        Self.onEveryPhaseChange(of: sender.dictation) {
            checks.results.append(sender.keepInterrupted(in: composer))
        }
        let result = await sender.stopAndSend(through: composer)

        // listening → finishing, then finishing → idle once the words landed.
        #expect(checks.results == [false, false])
        #expect(result == .deliveredViaPrompt)
        #expect(
            await transport.agentPromptParams == [
                AgentPromptParams(target: "w1:p1", text: "Ship it")
            ])
        #expect(composer.draft.isEmpty)
    }

    @Test func teardownWhileStopWaitsDiscardsItsFinalWords() async throws {
        let (engine, sender, transport, composer) = makeFixture()
        engine.ignoresFinish = true
        sender.start()
        engine.emit(.listening)
        engine.emit(.transcript("Do not send", isFinal: true))
        try await applied(0.5, engine, sender.dictation)

        let stop = Task { await sender.stopAndSend(through: composer) }
        try await waitUntil { sender.dictation.phase == .finishing }
        sender.cancel()

        #expect(await stop.value == .ignored)
        #expect(composer.draft.isEmpty)
        #expect(await transport.agentPromptParams.isEmpty)
    }

    // MARK: - Fixture

    private func makeFixture()
        -> (ScriptedDictationEngine, DictationSender, ScriptedTransport, AgentComposerStore)
    {
        let engine = ScriptedDictationEngine()
        let sender = DictationSender(
            dictation: DictationStore(engine: engine, locale: { Locale(identifier: "en_US") }))
        let transport = ScriptedTransport()
        let composer = AgentComposerStore(target: "w1:p1") { params in
            try await transport.promptAgent(params)
        }
        return (engine, sender, transport, composer)
    }

    @MainActor
    private final class InterruptionChecks {
        var results: [Bool] = []
    }

    /// Runs `action` synchronously as each phase change begins, while the
    /// store is still mid-transition.
    private static func onEveryPhaseChange(
        of dictation: DictationStore, _ action: @escaping @MainActor @Sendable () -> Void
    ) {
        withObservationTracking {
            _ = dictation.phase
        } onChange: {
            MainActor.assumeIsolated {
                action()
                onEveryPhaseChange(of: dictation, action)
            }
        }
    }

    /// A trailing level event proves every earlier event was applied.
    private func applied(
        _ marker: Float, _ engine: ScriptedDictationEngine, _ dictation: DictationStore
    ) async throws {
        engine.emit(.level(marker))
        try await waitUntil { dictation.level == marker }
    }
}
