import Foundation
import Observation

/// The sheet's linked-file interaction, separate from document rendering.
/// Resolution only asks consent; only `open` may read a linked Host file.
@MainActor
@Observable
final class MarkdownLinkedFileInteraction {
    var path: [MarkdownFilePreview.ID] = []
    private(set) var linkedPages: [MarkdownFilePreview.ID: MarkdownFilePreview] = [:]

    /// The alert only writes nil; a resolver's tokened completion supplies
    /// both the confirmation and its directory in one transition.
    var pendingLink: PendingLinkConfirmation? {
        get {
            guard case .confirming(let consent) = interaction.state.confirmation else { return nil }
            return PendingLinkConfirmation(target: consent.target, destination: consent.destination)
        }
        set { if newValue == nil { send(.dismissConfirmation) } }
    }

    var refusedLink: URL? {
        get { interaction.state.refusedLink }
        set { send(.refusalChanged(newValue)) }
    }

    var quickLookURL: URL? {
        get { interaction.state.preview }
        set { send(.previewChanged(newValue)) }
    }

    var loadFailureMessage: String? {
        get { interaction.state.failure }
        set { send(.failureChanged(newValue)) }
    }

    var loadingName: String? { interaction.loadingName }

    private var interaction = MarkdownLinkedFileMachine()
    @ObservationIgnored private var resolutions: [UInt64: Task<Void, Never>] = [:]
    @ObservationIgnored private var reads: [UInt64: Task<Void, Never>] = [:]
    @ObservationIgnored private let loadLinkedFile:
        (TerminalFileReference, _ workingDirectory: String) async throws -> LinkedFilePreview
    @ObservationIgnored private let confirmationDetail: (TerminalLinkTarget, _ workingDirectory: String) async -> String
    @ObservationIgnored private let failureMessage: (any Error) -> String

    init(
        loadLinkedFile: @escaping (TerminalFileReference, _ workingDirectory: String) async throws -> LinkedFilePreview,
        confirmationDetail: @escaping (TerminalLinkTarget, _ workingDirectory: String) async -> String,
        failureMessage: @escaping (any Error) -> String
    ) {
        self.loadLinkedFile = loadLinkedFile
        self.confirmationDetail = confirmationDetail
        self.failureMessage = failureMessage
    }

    func confirm(_ target: TerminalLinkTarget, from page: MarkdownFilePreview) {
        send(.resolve(target, directory: page.directory))
    }

    /// Called after the alert's nil write and its synchronous Open action.
    func confirmationDidEnd() {
        send(.confirmationEnded)
    }

    func open(_ target: TerminalLinkTarget, openWeb: (URL) -> Void) {
        send(.confirmed(target), openWeb: openWeb)
    }

    func disappear() {
        send(.disappear)
    }

    func cancelLinkedFileLoad() {
        send(.cancelRead)
    }

    private func send(_ event: MarkdownLinkedFileMachine.Event, openWeb: (URL) -> Void = { _ in }) {
        for effect in interaction.handle(event) {
            switch effect {
            case .resolve(let token, let target, let directory):
                resolutions[token] = Task { [weak self, confirmationDetail] in
                    let destination = await confirmationDetail(target, directory)
                    guard !Task.isCancelled else { return }
                    self?.resolutions[token] = nil
                    self?.send(.resolved(token, destination: destination))
                }
            case .cancelResolution(let token):
                resolutions.removeValue(forKey: token)?.cancel()
            case .load(let token, let file, let directory):
                load(file, workingDirectory: directory, token: token)
            case .cancelRead(let token):
                reads.removeValue(forKey: token)?.cancel()
            case .openWeb(let url):
                openWeb(url)
            case .push(let page):
                // Keep popped pages through their animation; prune on the next push.
                linkedPages = linkedPages.filter { path.contains($0.key) }
                linkedPages[page.id] = page
                path.append(page.id)
            }
        }
    }

    private func load(_ file: TerminalFileReference, workingDirectory: String, token: UInt64) {
        reads[token] = Task { [weak self, loadLinkedFile, failureMessage] in
            do {
                let linked = try await loadLinkedFile(file, workingDirectory)
                try Task.checkCancellation()
                self?.reads[token] = nil
                self?.send(.readFinished(token, .preview(linked)))
            } catch {
                guard !Task.isCancelled else { return }
                let message = failureMessage(error is CancellationError ? TransportError.cancelled : error)
                self?.reads[token] = nil
                self?.send(.readFinished(token, .failed(message)))
            }
        }
    }
}
