import Foundation
import Testing

@testable import Waycar

/// The file transcriber's failure paths, availability gate, and transcript
/// assembly. None of these need a downloaded speech model: every failure is
/// caught before model work, and assembly runs on scripted results.
struct AudioFileTranscriberTests {
    /// A missing recording reports a capture failure instead of crashing.
    @Test func missingFileThrowsCaptureFailed() async throws {
        guard #available(iOS 26, *) else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).m4a")
        await expectCaptureFailed {
            _ = try await SpeechAudioFileTranscriber().transcribe(
                fileAt: url, locale: Locale(identifier: "en-US"))
        }
    }

    /// Bytes that are not audio report a capture failure.
    @Test func unreadableFileThrowsCaptureFailed() async throws {
        guard #available(iOS 26, *) else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("garbage-\(UUID().uuidString).m4a")
        try Data("not audio".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        await expectCaptureFailed {
            _ = try await SpeechAudioFileTranscriber().transcribe(
                fileAt: url, locale: Locale(identifier: "en-US"))
        }
    }

    /// iOS 26 always offers a file transcriber; below it there is none.
    @Test func fileTranscriberAvailabilityFollowsOS() {
        if #available(iOS 26, *) {
            #expect(DictationEngines.fileTranscriber != nil)
        } else {
            #expect(DictationEngines.fileTranscriber == nil)
        }
    }

    /// A result the analyzer never finalized still counts: iOS 27's
    /// short-form presets report a recording's only result that way, and a
    /// final-only reader turned every watch reply into "no words" (#202).
    @Test func unfinalizedOnlyResultKeepsItsWords() {
        var transcript = RecordingTranscript()
        transcript.add("Please run the tests", isFinal: false)
        #expect(transcript.text == "Please run the tests")
    }

    /// Each volatile result replaces the one before, and the final one
    /// replaces them all, so nothing repeats.
    @Test func finalResultReplacesVolatileResults() {
        var transcript = RecordingTranscript()
        transcript.add("Please", isFinal: false)
        transcript.add("Please run the test", isFinal: false)
        transcript.add("Please run the tests.", isFinal: true)
        #expect(transcript.text == "Please run the tests.")
    }

    /// Final segments follow each other in order; a trailing unfinalized
    /// one follows them.
    @Test func finalSegmentsPrecedeTrailingUnfinalizedText() {
        var transcript = RecordingTranscript()
        transcript.add("Rerun the unit tests.", isFinal: true)
        transcript.add(" If they", isFinal: false)
        transcript.add(" If they pass, open a PR.", isFinal: true)
        transcript.add(" Thanks", isFinal: false)
        #expect(transcript.text == "Rerun the unit tests. If they pass, open a PR. Thanks")
    }

    /// No results is an empty transcript, which the bridge reports as no
    /// words.
    @Test func noResultsIsEmpty() {
        #expect(RecordingTranscript().text.isEmpty)
    }

    /// The recording preset gets its results finalized, so the final pass
    /// corrects the first: a short-form preset needs frequent finalization
    /// for that on iOS 27 (#202).
    @Test func recordingPresetFinalizesItsResults() {
        guard #available(iOS 26, *) else { return }
        let preset = Transcriber.recordingPreset
        #expect(
            !preset.contentHints.contains(.shortForm)
                || preset.reportingOptions.contains(.frequentFinalization))
    }

    /// Runs `body` and records an issue unless it throws `.captureFailed`.
    private func expectCaptureFailed(_ body: () async throws -> Void) async {
        do {
            try await body()
            Issue.record("expected captureFailed")
        } catch let error as DictationEngineError {
            guard case .captureFailed = error else {
                Issue.record("expected captureFailed, got \(error)")
                return
            }
        } catch {
            Issue.record("expected DictationEngineError, got \(error)")
        }
    }
}
