import Foundation

@testable import Waycar

/// A `DictationEngine` the test drives by hand: it emits whatever events the
/// test pushes, and `finish` flushes an optional last final segment before
/// ending the stream, like the real analyzer's finalize.
final class ScriptedDictationEngine: DictationEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<DictationEvent, any Error>.Continuation?
    private var finishCountValue = 0
    private var wasTerminatedValue = false
    private var finalSegmentOnFinishValue: String?
    private var audioProfilesValue: [DictationAudioProfile] = []
    private var ignoresFinishValue = false

    /// Models the real engine stuck before `.listening` (a permission
    /// prompt, a model download): `finish` is counted and changes nothing.
    var ignoresFinish: Bool {
        get { lock.withLock { ignoresFinishValue } }
        set { lock.withLock { ignoresFinishValue = newValue } }
    }

    /// Emitted as a final transcript when the store asks to finish.
    var finalSegmentOnFinish: String? {
        get { lock.withLock { finalSegmentOnFinishValue } }
        set { lock.withLock { finalSegmentOnFinishValue = newValue } }
    }

    var finishCount: Int { lock.withLock { finishCountValue } }

    /// True once the consumer abandoned the stream (cancel, user edit,
    /// early stop) — the real engine releases the microphone then.
    var wasTerminated: Bool { lock.withLock { wasTerminatedValue } }

    /// The audio profile of every session started, in order.
    var audioProfiles: [DictationAudioProfile] { lock.withLock { audioProfilesValue } }

    /// True once a session asked for events and its stream is still open.
    var hasLiveSession: Bool { lock.withLock { continuation != nil } }

    func events(
        for _: DictationSessionID, locale _: Locale, audioProfile: DictationAudioProfile
    ) -> AsyncThrowingStream<DictationEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: DictationEvent.self, throwing: (any Error).self)
        continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination, let self else { return }
            self.lock.withLock { self.wasTerminatedValue = true }
        }
        lock.withLock {
            self.continuation = continuation
            wasTerminatedValue = false
            audioProfilesValue.append(audioProfile)
        }
        return stream
    }

    func finish(_: DictationSessionID) async {
        let (continuation, segment): (AsyncThrowingStream<DictationEvent, any Error>.Continuation?, String?) =
            lock.withLock {
                finishCountValue += 1
                guard !ignoresFinishValue else { return (nil, nil) }
                let current = self.continuation
                self.continuation = nil
                return (current, finalSegmentOnFinishValue)
            }
        if let segment {
            continuation?.yield(.transcript(segment, isFinal: true))
        }
        continuation?.finish()
    }

    func emit(_ event: DictationEvent) {
        lock.withLock { continuation }?.yield(event)
    }

    func fail(_ error: DictationEngineError) {
        lock.withLock { continuation }?.finish(throwing: error)
    }
}
