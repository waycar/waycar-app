/// One production recognizer session. Its token is local to the captured
/// Session object (which is never restarted); the engine additionally fences
/// its process-wide claim by DictationSessionID and object identity.
/// No audio-session ownership policy lives here.
struct SpeechSessionMachine: StateMachine {
    enum Stage: Equatable, Sendable, CaseIterable {
        case permission, transcriber, reservation, installation, analyzerPreparation, analyzerStart, microphone

        var next: Stage {
            switch self {
            case .permission: .transcriber
            case .transcriber: .reservation
            case .reservation: .installation
            case .installation: .analyzerPreparation
            case .analyzerPreparation: .analyzerStart
            case .analyzerStart, .microphone: .microphone
            }
        }
    }

    enum Disposition: Equatable, Sendable {
        case unfinished, finalizing, cancelled, cancelledFinalization

        var wasCancelled: Bool { self == .cancelled || self == .cancelledFinalization }
        var wasFinalizing: Bool { self == .finalizing || self == .cancelledFinalization }
        var cancelling: Disposition { wasFinalizing ? .cancelledFinalization : .cancelled }
    }

    enum State: Equatable, Sendable {
        case preparing(UInt64, Stage)
        case capturing(UInt64)
        case finalizing(UInt64)
        case cancelling(UInt64, Disposition)
        case releasing(UInt64, Disposition)
        case released(UInt64, Disposition)
    }

    enum Event: Equatable, Sendable {
        case checkpoint(UInt64, Stage, taskCancelled: Bool)
        case microphoneOpened(UInt64)
        case finish
        case finalized(UInt64, succeeded: Bool)
        case cancel
        case teardown
        case tornDown(UInt64)
    }

    enum Effect: Equatable, Sendable {
        case continueStartup
        case releaseClaim
        case stopCapture
        case discardInput
        case finalize(UInt64)
        case cancelAnalyzer
        case releaseResources
    }

    /// Minted once per Session lifetime; there is deliberately no restart
    /// transition that could reuse a completion from an old recognizer.
    let token: UInt64 = 1
    private(set) var state: State = .preparing(1, .permission)

    private var disposition: Disposition {
        switch state {
        case .preparing, .capturing: .unfinished
        case .finalizing: .finalizing
        case .cancelling(_, let value), .releasing(_, let value), .released(_, let value): value
        }
    }

    var wasCancelled: Bool { disposition.wasCancelled }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.preparing(let token, let expected), .checkpoint(let current, let stage, let cancelled)):
            guard current == token, stage == expected, !cancelled else { return [] }
            state = .preparing(token, stage.next)
            return [.continueStartup]
        case (.preparing(let token, .microphone), .microphoneOpened(let current)):
            guard current == token else { return [] }
            state = .capturing(token)
            return []
        case (.preparing(let token, _), .finish):
            state = .cancelling(token, .cancelled)
            return [.releaseClaim, .stopCapture, .cancelAnalyzer]
        case (.capturing(let token), .finish):
            state = .finalizing(token)
            return [.stopCapture, .finalize(token)]
        case (.preparing(let token, _), .cancel), (.capturing(let token), .cancel),
            (.finalizing(let token), .cancel):
            state = .cancelling(token, disposition.cancelling)
            return [.releaseClaim, .stopCapture, .cancelAnalyzer]
        case (.releasing(let token, let disposition), .cancel):
            guard !disposition.wasCancelled else { return [] }
            state = .releasing(token, disposition.cancelling)
            return [.releaseClaim, .stopCapture, .cancelAnalyzer]
        case (_, .finalized(let current, let succeeded)):
            guard current == token, disposition.wasFinalizing else { return [] }
            // Finalization may return after results ended/teardown. Its own
            // analyzer is cancelled on error, never another session's.
            return succeeded ? [] : [.cancelAnalyzer]
        case (_, .teardown):
            let disposition = disposition
            state = .releasing(token, disposition)
            return [.stopCapture, .discardInput] + (disposition.wasFinalizing ? [] : [.cancelAnalyzer])
        case (.releasing(let token, let disposition), .tornDown(let current)):
            guard current == token else { return [] }
            state = .released(token, disposition)
            return [.releaseResources]
        case (.preparing, _), (.capturing, _), (.finalizing, _), (.cancelling, _),
            (.releasing, _), (.released, _):
            return []
        }
    }
}
