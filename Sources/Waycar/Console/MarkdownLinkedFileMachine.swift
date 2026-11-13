import Foundation

/// Resolving a link only prepares consent. Reads start on confirmation,
/// never on resolution. Resolution, a previously consented read, and the
/// sheet's alerts/Quick Look may overlap; serializing them would cancel work
/// the old sheet deliberately kept. The ending confirmation retains its
/// directory across the alert's nil-before-Open write until onChange runs.
struct MarkdownLinkedFileMachine: StateMachine {
    struct Consent: Equatable, Sendable {
        let target: TerminalLinkTarget
        let destination: String
        let directory: String
    }

    enum Resolution: Equatable, Sendable {
        case idle
        case resolving(token: UInt64, target: TerminalLinkTarget, directory: String)
    }

    enum Confirmation: Equatable, Sendable {
        case idle
        case confirming(Consent)
        case ending(directory: String)

        var directory: String? {
            switch self {
            case .idle: nil
            case .confirming(let consent): consent.directory
            case .ending(let directory): directory
            }
        }
    }

    enum Read: Equatable, Sendable {
        case idle
        case loading(token: UInt64, name: String)
    }

    /// Parallel regions: a new tap must not cancel a consented read, and
    /// neither a new read nor a new confirmation dismisses an older error
    /// or Quick Look presentation.
    struct State: Equatable, Sendable {
        var resolution: Resolution = .idle
        var confirmation: Confirmation = .idle
        var read: Read = .idle
        var refusedLink: URL?
        var failure: String?
        var preview: URL?
    }

    enum Outcome: Equatable, Sendable {
        case preview(LinkedFilePreview)
        case failed(String)
    }

    enum Event: Equatable, Sendable {
        case resolve(TerminalLinkTarget, directory: String)
        case resolved(UInt64, destination: String)
        case dismissConfirmation
        case confirmationEnded
        /// The alert's explicit Open/Preview action, after its nil write.
        case confirmed(TerminalLinkTarget)
        case readFinished(UInt64, Outcome)
        case cancelRead
        case disappear
        case refusalChanged(URL?)
        case failureChanged(String?)
        case previewChanged(URL?)
    }

    enum Effect: Equatable, Sendable {
        case resolve(UInt64, TerminalLinkTarget, directory: String)
        case cancelResolution(UInt64)
        case load(UInt64, TerminalFileReference, directory: String)
        case cancelRead(UInt64)
        case openWeb(URL)
        case push(MarkdownFilePreview)
    }

    private(set) var state = State()
    private var lastToken: UInt64 = 0

    var loadingName: String? {
        if case .loading(_, let name) = state.read { name } else { nil }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .resolve(let target, let directory):
            var effects = cancelResolution()
            lastToken &+= 1
            state.resolution = .resolving(token: lastToken, target: target, directory: directory)
            effects.append(.resolve(lastToken, target, directory: directory))
            return effects
        case .resolved(let token, let destination):
            guard case .resolving(let current, let target, let directory) = state.resolution,
                  current == token else { return [] }
            state.resolution = .idle
            state.confirmation = .confirming(Consent(target: target, destination: destination, directory: directory))
            return []
        case .dismissConfirmation:
            switch state.confirmation {
            case .confirming(let consent): state.confirmation = .ending(directory: consent.directory)
            case .idle, .ending: break
            }
            return []
        case .confirmationEnded:
            if case .ending = state.confirmation { state.confirmation = .idle }
            return []
        case .confirmed(let target):
            switch target {
            case .web(let url):
                return [.openWeb(url)]
            case .file(let file):
                guard let directory = state.confirmation.directory else { return [] }
                var effects = cancelRead()
                lastToken &+= 1
                state.read = .loading(token: lastToken, name: file.displayName)
                effects.append(.load(lastToken, file, directory: directory))
                return effects
            }
        case .readFinished(let token, let outcome):
            guard case .loading(let current, _) = state.read, current == token else { return [] }
            state.read = .idle
            switch outcome {
            case .preview(.markdown(let page)): return [.push(page)]
            case .preview(.quickLook(let url)): state.preview = url
            case .failed(let message): state.failure = message
            }
            return []
        case .cancelRead:
            return cancelRead()
        case .disappear:
            return cancelResolution() + cancelRead()
        case .refusalChanged(let url):
            state.refusedLink = url
            return []
        case .failureChanged(let message):
            state.failure = message
            return []
        case .previewChanged(let url):
            state.preview = url
            return []
        }
    }

    private mutating func cancelResolution() -> [Effect] {
        switch state.resolution {
        case .idle: return []
        case .resolving(let token, _, _):
            state.resolution = .idle
            return [.cancelResolution(token)]
        }
    }

    private mutating func cancelRead() -> [Effect] {
        switch state.read {
        case .idle: return []
        case .loading(let token, _):
            state.read = .idle
            return [.cancelRead(token)]
        }
    }
}
