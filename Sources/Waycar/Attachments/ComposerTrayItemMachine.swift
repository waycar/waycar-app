import Foundation

/// One tray item's source and worker token live only until its Host path is
/// ready. Worker ids come from ComposerStagingStore; a binding change forgets
/// them because those ids are local to a staging instance.
struct ComposerTrayItemMachine: StateMachine {
    /// Photo selections have no value equality. This handle identifies the
    /// selection handed to this item, not its bytes or eventual thumbnail.
    struct Source: Equatable, Sendable {
        let id: UUID
        let value: ComposerStagingStore.Source

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    }

    enum State: Equatable, Sendable {
        case queued(Source)
        case staging(Source, operation: UInt64)
        case failed(Source, message: String, retryable: Bool, operation: UInt64?)
        case ready(String)
        case removed
    }

    enum Event: Sendable {
        case started(UInt64)
        case completed(UInt64, path: String)
        case failed(UInt64, message: String, retryable: Bool)
        case retryRetained(UInt64)
        case retrySource
        case bindingChanged(stoppedMessage: String)
        case remove
        /// Taking into the queue hands over the source; unlike Remove it
        /// does not discard its local copy.
        case take
    }

    enum Effect: Equatable, Sendable {
        case discardSource(Source)
        case cancel(UInt64)
        case dismiss(UInt64)
    }

    private(set) var state: State

    init(source: Source) { state = .queued(source) }
    init(readyPath: String) { state = .ready(readyPath) }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.queued(let source), .started(let operation)):
            state = .staging(source, operation: operation)
            return []
        case (.staging(let source, let operation), .completed(let token, let path))
            where operation == token:
            state = .ready(path)
            return [.discardSource(source)]
        case (.staging(let source, let operation), .failed(let token, let message, let retryable))
            where operation == token:
            state = .failed(source, message: message, retryable: retryable, operation: operation)
            return []
        case (.failed(let source, _, _, let operation), .retryRetained(let token))
            where operation == token:
            state = .staging(source, operation: token)
            return []
        case (.failed(let source, _, _, _), .retrySource):
            state = .queued(source)
            return []
        case (.staging(let source, _), .bindingChanged(let message)):
            state = .failed(source, message: message, retryable: true, operation: nil)
            return []
        case (.failed(let source, let message, let retryable, _), .bindingChanged):
            state = .failed(source, message: message, retryable: retryable, operation: nil)
            return []
        case (.queued(let source), .remove):
            state = .removed
            return [.discardSource(source)]
        case (.staging(let source, let operation), .remove):
            state = .removed
            return [.discardSource(source), .cancel(operation)]
        case (.failed(let source, _, _, let operation), .remove):
            state = .removed
            return [.discardSource(source)] + (operation.map { [.dismiss($0)] } ?? [])
        case (.failed(_, _, _, let operation), .take):
            state = .removed
            return operation.map { [.dismiss($0)] } ?? []
        case (.queued, .take), (.staging, .take), (.ready, .take), (.ready, .remove):
            state = .removed
            return []
        case (.queued, _), (.staging, _), (.failed, _), (.ready, _), (.removed, _):
            return []
        }
    }

    var source: ComposerStagingStore.Source? {
        switch state {
        case .queued(let source), .staging(let source, _), .failed(let source, _, _, _): source.value
        case .ready, .removed: nil
        }
    }

    var retainedOperation: UInt64? {
        if case .failed(_, _, _, let operation) = state { return operation }
        return nil
    }

    var status: ComposerTray.Item.Status? {
        switch state {
        case .queued: .queued
        case .staging(_, let operation): .staging(operationID: operation)
        case .failed(_, let message, let retryable, _): .failed(message: message, isRetryable: retryable)
        case .ready(let path): .ready(path: path)
        case .removed: nil
        }
    }
}
