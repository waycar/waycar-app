import Foundation

/// Single-slot preparation/upload, including cancellation disposition and the
/// teardown barrier. Public operation ids survive Retry; each preparation and
/// upload gets a distinct task token so late results cannot reach a successor.
struct ComposerStagingMachine: StateMachine {
    typealias Medium = ComposerStagingStore.Medium
    typealias Prepared = ComposerStagingStore.PreparedSource
    typealias Failure = ComposerStagingStore.Failure
    typealias Presentation = ComposerStagingStore.State

    struct Selection: Equatable, Sendable {
        let token: UInt64
        let source: ComposerStagingStore.Source
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.token == rhs.token }
    }

    enum Work: Equatable, Sendable {
        case preparing(Medium)
        case uploading(Prepared, AttachmentStageProgress)

        var prepared: Prepared? {
            if case .uploading(let source, _) = self { return source }
            return nil
        }
        var presentation: Presentation {
            switch self {
            case .preparing(let medium): .preparing(medium)
            case .uploading(let source, let progress): .uploading(source.medium, progress)
            }
        }
    }

    enum Cancellation: Equatable, Sendable {
        case user
        case background(Failure)
    }

    enum State: Equatable, Sendable {
        case idle
        case preparing(operation: UInt64, attempt: UInt64, Medium)
        case uploading(operation: UInt64, attempt: UInt64, Prepared, AttachmentStageProgress)
        case cancelling(operation: UInt64, attempt: UInt64, Work, Cancellation)
        case leaving(UInt64, Presentation, Prepared?, cancelledOperation: UInt64?)
        case failed(UInt64, Failure, Prepared?, background: Bool)
    }

    enum Event: Sendable {
        case begin(ComposerStagingStore.Source)
        // Task results carry attempt tokens, never public operation ids.
        case prepared(UInt64, Prepared)
        case progress(UInt64, AttachmentStageProgress)
        case succeeded(UInt64, path: String)
        case failed(UInt64, Failure, cancelled: Bool)
        case cancel(UInt64)
        case background(Failure)
        case retry(UInt64)
        case dismiss(UInt64)
        case leave
        case left(UInt64)
    }

    enum Effect: Equatable, Sendable {
        case prepare(Selection)
        case upload(UInt64, Prepared)
        case discard(Prepared)
        case cancelTask(UInt64)
        case finishTask(UInt64)
        case publish(ComposerStagingStore.OperationEvent)
    }

    private(set) var state: State = .idle
    /// Operation ids, task attempts and leave barriers share one counter.
    private var lastToken: UInt64 = 0

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.idle, .begin(let source)), (.failed, .begin(let source)):
            let old = prepared.map { [Effect.discard($0)] } ?? []
            let operation = mintToken()
            let attempt = mintToken()
            state = .preparing(operation: operation, attempt: attempt, source.medium)
            return old + [.prepare(Selection(token: attempt, source: source))]
        case (.preparing(let operation, let attempt, _), .prepared(let token, let source)) where attempt == token:
            let upload = mintToken()
            state = .uploading(operation: operation, attempt: upload, source, Self.initialProgress(source))
            return [.finishTask(attempt), .upload(upload, source)]
        case (_, .prepared(_, let source)):
            // Preparation can return after cancellation/teardown. These bytes
            // never became the slot's retained source.
            return [.discard(source)]
        case (.uploading(let operation, let attempt, let source, _), .progress(let token, let progress)) where attempt == token:
            state = .uploading(operation: operation, attempt: attempt, source, progress)
            return []
        case (.cancelling(let operation, let attempt, .uploading(let source, _), let reason), .progress(let token, let progress))
            where attempt == token:
            state = .cancelling(operation: operation, attempt: attempt, .uploading(source, progress), reason)
            return []
        case (.uploading(let operation, let attempt, let source, _), .succeeded(let token, let path)) where attempt == token:
            state = .idle
            return [.finishTask(attempt), .discard(source), .publish(.completed(id: operation, path: path))]
        case (.preparing(let operation, let attempt, _), .failed(let token, let failure, let cancelled)) where attempt == token:
            return finish(operation: operation, attempt: attempt, failure: failure, prepared: nil, cancelled: cancelled)
        case (.uploading(let operation, let attempt, let source, _), .failed(let token, let failure, let cancelled)) where attempt == token:
            return finish(operation: operation, attempt: attempt, failure: failure, prepared: source, cancelled: cancelled)
        case (.cancelling(let operation, let attempt, let work, let reason), .succeeded(let token, _)) where attempt == token:
            return finishCancellation(operation: operation, attempt: attempt, prepared: work.prepared, reason: reason)
        case (.cancelling(let operation, let attempt, let work, let reason), .failed(let token, _, _)) where attempt == token:
            return finishCancellation(operation: operation, attempt: attempt, prepared: work.prepared, reason: reason)
        case (.preparing(let operation, let attempt, let medium), .cancel(let id)) where operation == id:
            state = .cancelling(operation: operation, attempt: attempt, .preparing(medium), .user)
            return [.cancelTask(attempt)]
        case (.uploading(let operation, let attempt, let source, let progress), .cancel(let id)) where operation == id:
            state = .cancelling(operation: operation, attempt: attempt, .uploading(source, progress), .user)
            return [.cancelTask(attempt)]
        case (.cancelling(let operation, let attempt, let work, _), .cancel(let id)) where operation == id:
            state = .cancelling(operation: operation, attempt: attempt, work, .user)
            return [.cancelTask(attempt)]
        case (.preparing(let operation, let attempt, let medium), .background(let failure)):
            state = .cancelling(operation: operation, attempt: attempt, .preparing(medium), .background(failure))
            return [.cancelTask(attempt)]
        case (.uploading(let operation, let attempt, let source, let progress), .background(let failure)):
            state = .cancelling(operation: operation, attempt: attempt, .uploading(source, progress), .background(failure))
            return [.cancelTask(attempt)]
        case (.cancelling(let operation, let attempt, let work, _), .background(let failure)):
            state = .cancelling(operation: operation, attempt: attempt, work, .background(failure))
            return [.cancelTask(attempt)]
        case (.failed(let operation, let failure, let source?, _), .retry(let id))
            where operation == id && failure.isRetryable && source.medium == failure.medium:
            let attempt = mintToken()
            state = .uploading(operation: operation, attempt: attempt, source, Self.initialProgress(source))
            return [.upload(attempt, source)]
        case (.failed(let operation, _, let source, _), .dismiss(let id)) where operation == id:
            state = .idle
            return source.map { [.discard($0)] } ?? []
        case (_, .leave):
            let display = presentation
            let retained = prepared
            let abandoned = activeOperationID
            let running = taskToken
            let barrier = mintToken()
            state = .leaving(barrier, display, retained, cancelledOperation: abandoned)
            return running.map { [.cancelTask($0), .finishTask($0)] } ?? []
        case (.leaving(let token, _, let source, let abandoned), .left(let id)) where token == id:
            state = .idle
            return (source.map { [.discard($0)] } ?? [])
                + (abandoned.map { [.publish(.cancelled(id: $0))] } ?? [])
        case (.idle, _), (.preparing, _), (.uploading, _), (.cancelling, _), (.leaving, _), (.failed, _):
            return []
        }
    }

    var presentation: Presentation {
        switch state {
        case .idle: .idle
        case .preparing(_, _, let medium): .preparing(medium)
        case .uploading(_, _, let source, let progress): .uploading(source.medium, progress)
        case .cancelling(_, _, let work, _): work.presentation
        case .leaving(_, let display, _, _): display
        case .failed(_, let failure, _, let background): background ? .backgroundInterrupted(failure) : .failed(failure)
        }
    }

    var activeOperationID: UInt64? {
        switch state {
        case .preparing(let operation, _, _), .uploading(let operation, _, _, _), .cancelling(let operation, _, _, _): operation
        case .leaving(_, _, _, let operation): operation
        case .idle, .failed: nil
        }
    }
    var leaveToken: UInt64? {
        if case .leaving(let token, _, _, _) = state { return token }
        return nil
    }
    var taskToken: UInt64? {
        switch state {
        case .preparing(_, let attempt, _), .uploading(_, let attempt, _, _), .cancelling(_, let attempt, _, _): attempt
        case .idle, .failed, .leaving: nil
        }
    }
    private var prepared: Prepared? {
        switch state {
        case .uploading(_, _, let source, _): source
        case .cancelling(_, _, let work, _): work.prepared
        case .failed(_, _, let source, _), .leaving(_, _, let source, _): source
        case .idle, .preparing: nil
        }
    }
    private mutating func mintToken() -> UInt64 {
        lastToken += 1
        return lastToken
    }
    private static func initialProgress(_ source: Prepared) -> AttachmentStageProgress {
        AttachmentStageProgress(transferredBytes: 0, totalBytes: source.byteCount)
    }
    private mutating func finish(
        operation: UInt64, attempt: UInt64, failure: Failure, prepared: Prepared?, cancelled: Bool
    ) -> [Effect] {
        if cancelled { return finishCancellation(operation: operation, attempt: attempt, prepared: prepared, reason: .user) }
        state = .failed(operation, failure, failure.isRetryable ? prepared : nil, background: false)
        return [.finishTask(attempt)]
            + (!failure.isRetryable ? prepared.map { [.discard($0)] } ?? [] : [])
            + [.publish(.failed(id: operation, message: failure.message, retryable: failure.isRetryable))]
    }
    private mutating func finishCancellation(
        operation: UInt64, attempt: UInt64, prepared: Prepared?, reason: Cancellation
    ) -> [Effect] {
        switch reason {
        case .user:
            state = .idle
            return [.finishTask(attempt)] + (prepared.map { [.discard($0)] } ?? []) + [.publish(.cancelled(id: operation))]
        case .background(let failure):
            state = .failed(operation, failure, prepared, background: true)
            return [.finishTask(attempt), .publish(.failed(id: operation, message: failure.message, retryable: true))]
        }
    }
}
