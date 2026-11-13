import Foundation
import Testing

@testable import Waycar

@MainActor
@Suite("Dictation store")
struct DictationStoreTests {
    @Test func theDraftStaysUntouchedUntilStopThenGetsEverythingAtTheCaret() async throws {
        let (engine, dictation, draft) = makeFixture(
            draft: "Hello world", selection: NSRange(location: 5, length: 0))

        dictation.start(into: draft)
        engine.emit(.listening)
        // A later volatile guess replaces the earlier one; finals accumulate,
        // and a leading-space final joins without doubling the space.
        engine.emit(.transcript("bag", isFinal: false))
        engine.emit(.transcript("big", isFinal: true))
        engine.emit(.transcript(" blue", isFinal: true))
        engine.emit(.transcript("sky", isFinal: false))
        try await applied(0.5, engine, dictation)
        #expect(draft.draft == "Hello world")

        await dictation.finish()

        #expect(draft.draft == "Hello big blue sky world")
        #expect(draft.draftSelection == NSRange(location: 18, length: 0))
        #expect(dictation.phase == .idle)
    }

    @Test func aSelectionIsReplacedByTheDictatedText() async throws {
        let (engine, dictation, draft) = makeFixture(
            draft: "Hello there world", selection: NSRange(location: 6, length: 5))

        dictation.start(into: draft)
        engine.emit(.listening)
        engine.emit(.transcript("big", isFinal: false))
        try await applied(0.5, engine, dictation)
        await dictation.finish()

        #expect(draft.draft == "Hello big world")
    }

    @Test func finishWaitsForTheLastWordsBeforeReturning() async throws {
        let (engine, dictation, draft) = makeFixture(draft: "", selection: NSRange())
        engine.finalSegmentOnFinish = "and ship it."

        dictation.start(into: draft)
        engine.emit(.listening)
        engine.emit(.transcript("Fix the bug", isFinal: true))
        try await applied(0.5, engine, dictation)

        await dictation.finish()

        #expect(draft.draft == "Fix the bug and ship it.")
        #expect(dictation.phase == .idle)
        #expect(engine.finishCount == 1)
    }

    /// Send enables on `holdsSpeech`; before the microphone opens, a stop
    /// abandons startup, so there is nothing to send yet.
    @Test func speechIsHeldOnlyFromListeningUntilItLands() async throws {
        let (engine, dictation, draft) = makeFixture(draft: "", selection: NSRange())

        dictation.start(into: draft)
        #expect(!dictation.holdsSpeech)
        engine.emit(.downloadingModel(fraction: 0.5))
        try await waitUntil { dictation.phase == .downloadingModel(fraction: 0.5) }
        #expect(!dictation.holdsSpeech)
        engine.emit(.listening)
        try await waitUntil { dictation.phase == .listening }
        #expect(dictation.holdsSpeech)

        dictation.stop()
        #expect(dictation.holdsSpeech)
        await dictation.finish()
        #expect(!dictation.holdsSpeech)
    }

    @Test func typingWhileListeningIsKeptAndSpeechLandsAtTheNewCaret() async throws {
        let (engine, dictation, draft) = makeFixture(draft: "", selection: NSRange())

        dictation.start(into: draft)
        engine.emit(.listening)
        engine.emit(.transcript("then run the tests", isFinal: true))
        try await applied(0.5, engine, dictation)

        draft.applyEditorDraft("Fix it.", selection: NSRange(location: 7, length: 0))
        #expect(dictation.phase == .listening)
        await dictation.finish()

        #expect(draft.draft == "Fix it. then run the tests")
        #expect(dictation.failure == nil)
    }

    @Test func stoppingFlattensTheWaveformWhileTheLastWordsFinish() async throws {
        let (engine, dictation, draft) = makeFixture(draft: "", selection: NSRange())

        dictation.start(into: draft)
        engine.emit(.listening)
        engine.emit(.level(0.8))
        try await waitUntil { dictation.phase == .listening && dictation.level == 0.8 }

        dictation.stop()

        #expect(dictation.phase == .finishing)
        #expect(dictation.level == 0)
        try await waitUntil { dictation.phase == .idle }
    }

    @Test func finishingSuppressesQueuedProgressAndStillKeepsTheLastWords() async throws {
        let (engine, dictation, draft) = makeFixture(draft: "", selection: NSRange())
        engine.ignoresFinish = true
        dictation.start(into: draft)
        engine.emit(.listening)
        try await applied(0.5, engine, dictation)
        dictation.stop()
        try await waitUntil { engine.finishCount == 1 }
        engine.emit(.downloadingModel(fraction: 0.4))
        engine.emit(.listening)
        engine.emit(.level(0.9))
        engine.emit(.transcript("Last words", isFinal: true))
        engine.ignoresFinish = false
        await engine.finish(DictationSessionID())
        await dictation.finish()

        #expect(draft.draft == "Last words")
        #expect(dictation.phase == .idle)
        #expect(dictation.level == 0)
    }

    @Test func stoppingBeforeTheMicrophoneOpensAbandonsStartup() async throws {
        let (engine, dictation, draft) = makeFixture(draft: "Keep", selection: NSRange())

        dictation.start(into: draft)
        engine.emit(.downloadingModel(fraction: 0.25))
        try await waitUntil { dictation.phase == .downloadingModel(fraction: 0.25) }

        dictation.stop()

        try await waitUntil { dictation.phase == .idle }
        #expect(engine.wasTerminated)
        #expect(engine.finishCount == 0)
        #expect(draft.draft == "Keep")
    }

    @Test func cancelReleasesTheMicrophoneAndKeepsWhatWasHeard() async throws {
        let (engine, dictation, draft) = makeFixture(draft: "", selection: NSRange())

        dictation.start(into: draft)
        engine.emit(.listening)
        engine.emit(.transcript("Half a thought", isFinal: false))
        try await applied(0.5, engine, dictation)

        dictation.cancel()

        try await waitUntil { dictation.phase == .idle }
        #expect(engine.wasTerminated)
        #expect(draft.draft == "Half a thought")
        #expect(dictation.level == 0)
    }

    @Test func failuresKeepPartialTextAndRouteByCause() async throws {
        let (engine, dictation, draft) = makeFixture(draft: "", selection: NSRange())

        dictation.start(into: draft)
        engine.emit(.listening)
        engine.emit(.transcript("partial", isFinal: true))
        try await applied(0.5, engine, dictation)
        engine.fail(.captureFailed("test"))
        try await waitUntil { dictation.phase == .idle }
        #expect(draft.draft == "partial")
        guard case .message = dictation.failure else {
            Issue.record("expected a message failure, got \(String(describing: dictation.failure))")
            return
        }

        // The next start clears the old failure; a denied microphone gets
        // its own case so the Composer can offer Settings.
        dictation.start(into: draft)
        #expect(dictation.failure == nil)
        engine.fail(.microphonePermissionDenied)
        try await waitUntil { dictation.phase == .idle }
        #expect(dictation.failure == .microphonePermissionDenied)
    }

    @Test func noEngineMeansNoDictation() {
        let dictation = DictationStore(engine: nil)
        dictation.start(into: Self.draftStore())
        #expect(!dictation.isAvailable)
        #expect(dictation.phase == .idle)
    }

    @Test func segmentsJoinWithSpacesOnlyWhereWordsWouldRunTogether() {
        #expect(DictationComposition.join("Hello", "world") == "Hello world")
        #expect(DictationComposition.join("Hello", " world") == "Hello world")
        #expect(DictationComposition.join("Hello", ", world") == "Hello, world")
        #expect(DictationComposition.join("你好", "世界") == "你好世界")

        let composition = DictationComposition(
            draft: "Ask it.", selection: NSRange(location: 6, length: 0))
        #expect(composition.compose("  twice ").text == "Ask it twice.")
        #expect(composition.compose("").text == "Ask it.")
    }

    // MARK: - Fixture

    private func makeFixture(draft: String, selection: NSRange)
        -> (ScriptedDictationEngine, DictationStore, AgentComposerStore)
    {
        let engine = ScriptedDictationEngine()
        let dictation = DictationStore(engine: engine, locale: { Locale(identifier: "en_US") })
        let store = Self.draftStore()
        store.applyEditorDraft(draft, selection: selection)
        return (engine, dictation, store)
    }

    private static func draftStore() -> AgentComposerStore {
        AgentComposerStore(target: "w1:p1") { _ in throw TransportError.timedOut }
    }

    /// The draft no longer changes while listening, so a trailing level event
    /// is the observable proof that every earlier event was applied in order.
    private func applied(
        _ marker: Float, _ engine: ScriptedDictationEngine, _ dictation: DictationStore
    ) async throws {
        engine.emit(.level(marker))
        try await waitUntil { dictation.level == marker }
    }
}
