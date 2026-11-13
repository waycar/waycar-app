import Foundation
import Observation

/// The Composer Tray's single-slot staging worker: prepares and uploads one
/// source at a time and reports each operation's terminal outcome through
/// `onOperationEvent`. It never touches the draft or the clipboard. Prepared
/// local files belong to this store; completed Host files intentionally
/// outlive it (ADR 0005).
@MainActor
@Observable
final class ComposerStagingStore {
    enum Source: Sendable {
        case photo(any ImageSelection)
        case file(URL)

        var medium: Medium {
            switch self {
            case .photo: .image
            case .file: .file
            }
        }
    }

    enum State: Sendable, Equatable {
        case idle
        case preparing(Medium)
        case uploading(Medium, AttachmentStageProgress)
        case failed(Failure)
        case backgroundInterrupted(Failure)

        var isBusy: Bool {
            switch self {
            case .preparing, .uploading:
                true
            case .idle, .failed, .backgroundInterrupted:
                false
            }
        }
    }

    enum Medium: Sendable, Equatable {
        case image
        case file

        fileprivate var displayName: String {
            switch self {
            case .image: "Image"
            case .file: "File"
            }
        }
    }

    struct Failure: Sendable, Equatable {
        let medium: Medium
        let message: String
        let isRetryable: Bool
    }

    /// Terminal outcomes for one `begin` operation, keyed by its id.
    enum OperationEvent: Equatable, Sendable {
        case completed(id: UInt64, path: String)
        case failed(id: UInt64, message: String, retryable: Bool)
        case cancelled(id: UInt64)
    }

    private struct ImageAdapter: Sendable {
        let preparer: any ImagePreparing
        let stage: ImageStager

        func prepare(_ selection: any ImageSelection) async throws -> PreparedSource {
            .image(try await preparer.prepare(selection))
        }

        func upload(
            _ image: PreparedImage,
            reporter: AttachmentStageProgressReporter
        ) async throws -> StagedSource {
            .image(try await stage(image, reporter))
        }
    }

    private struct FileAdapter: Sendable {
        let preparer: any FilePreparing
        let stage: FileStager

        func prepare(_ sourceURL: URL) async throws -> PreparedSource {
            .file(try await preparer.prepare(sourceURL))
        }

        func upload(
            _ file: PreparedFile,
            reporter: AttachmentStageProgressReporter
        ) async throws -> StagedSource {
            .file(try await stage(file, reporter))
        }
    }

    enum PreparedSource: Sendable, Equatable {
        case image(PreparedImage)
        case file(PreparedFile)

        var medium: Medium {
            switch self {
            case .image: .image
            case .file: .file
            }
        }

        var byteCount: Int64 {
            switch self {
            case .image(let image): image.byteCount
            case .file(let file): file.byteCount
            }
        }

        func remove() throws {
            switch self {
            case .image(let image): try image.remove()
            case .file(let file): try file.remove()
            }
        }
    }

    private enum StagedSource: Sendable {
        case image(StagedImage)
        case file(StagedFile)

        var medium: Medium {
            switch self {
            case .image: .image
            case .file: .file
            }
        }

        var path: String {
            switch self {
            case .image(let image): image.path
            case .file(let file): file.path
            }
        }
    }

    private var slot = ComposerStagingMachine()
    var state: State { slot.presentation }

    /// The current operation's id while preparing or uploading, else `nil`.
    var activeOperationID: UInt64? { slot.activeOperationID }

    private let imageAdapter: ImageAdapter
    private let fileAdapter: FileAdapter

    @ObservationIgnored private var tasks: [UInt64: Task<Void, Never>] = [:]
    @ObservationIgnored
    var onOperationEvent: (@MainActor (OperationEvent) -> Void)?

    init(
        imagePreparer: any ImagePreparing = ImagePreparer(),
        filePreparer: any FilePreparing = FilePreparer(),
        stageImage: @escaping ImageStager,
        stageFile: @escaping FileStager
    ) {
        imageAdapter = ImageAdapter(preparer: imagePreparer, stage: stageImage)
        fileAdapter = FileAdapter(preparer: filePreparer, stage: stageFile)
    }

    /// Starts one upload. Returns the operation id, or `nil` when busy. A
    /// retained failure is discarded silently. Retry keeps the same id.
    @discardableResult
    func begin(_ source: Source) -> UInt64? {
        let effects = slot.handle(.begin(source))
        guard effects.contains(where: { if case .prepare = $0 { true } else { false } }) else { return nil }
        perform(effects)
        return activeOperationID
    }

    /// Cancels the active operation; no-op for any other id. Ends `.idle`
    /// and publishes `.cancelled(id)`.
    func cancel(operationID id: UInt64) {
        send(.cancel(id))
    }

    /// Re-uploads the retained prepared file under the same id. Returns
    /// `false` when that operation holds no retryable failure or no file.
    @discardableResult
    func retry(operationID id: UInt64) -> Bool {
        let effects = slot.handle(.retry(id))
        let accepted = effects.contains { if case .upload = $0 { true } else { false } }
        perform(effects)
        return accepted
    }

    /// Discards that operation's retained failure and prepared file; publishes nothing.
    func dismiss(operationID id: UInt64) {
        send(.dismiss(id))
    }

    /// Interrupts the active operation as a retryable failure, keeping any prepared file.
    func didEnterBackground() {
        let medium: Medium
        switch state {
        case .preparing(let value), .uploading(let value, _): medium = value
        case .idle, .failed, .backgroundInterrupted: return
        }
        send(.background(Failure(
            medium: medium,
            message: "\(medium.displayName) upload paused when Waycar moved to the background.",
            isRetryable: true)))
    }

    /// Cancels and awaits the active operation (publishing `.cancelled`),
    /// silently discards any retained failure, and ends `.idle`.
    func leave() async {
        let task = slot.taskToken.flatMap { tasks[$0] }
        send(.leave)
        guard let token = slot.leaveToken else { return }
        await task?.value
        send(.left(token))
    }

    private func send(_ event: ComposerStagingMachine.Event) {
        perform(slot.handle(event))
    }

    private func perform(_ effects: [ComposerStagingMachine.Effect]) {
        for effect in effects {
            switch effect {
            case .prepare(let selection):
                tasks[selection.token] = Task { [weak self] in
                    await self?.runSelection(selection.source, attemptToken: selection.token)
                }
            case .upload(let token, let source):
                tasks[token] = Task { [weak self] in
                    await self?.runUploadBody(source, attemptToken: token)
                }
            case .discard(let source): try? source.remove()
            case .cancelTask(let token): tasks[token]?.cancel()
            case .finishTask(let token): tasks[token] = nil
            case .publish(let event): onOperationEvent?(event)
            }
        }
    }

    private func runSelection(_ source: Source, attemptToken: UInt64) async {
        var unclaimedSource: PreparedSource?
        do {
            let prepared = try await prepare(source)
            unclaimedSource = prepared
            try Task.checkCancellation()
            unclaimedSource = nil
            let task = tasks[attemptToken]
            for effect in slot.handle(.prepared(attemptToken, prepared)) {
                if case .upload(let token, let source) = effect {
                    // The same Task continues the first upload, but under
                    // its newly minted attempt token. Capture its handle
                    // before finishTask removes the preparation's key.
                    tasks[token] = task
                    await runUploadBody(source, attemptToken: token)
                } else {
                    perform([effect])
                }
            }
        } catch {
            try? unclaimedSource?.remove()
            finish(error: error, medium: source.medium, attemptToken: attemptToken)
        }
    }

    private func prepare(_ source: Source) async throws -> PreparedSource {
        switch source {
        case .photo(let selection):
            try await imageAdapter.prepare(selection)
        case .file(let sourceURL):
            try await fileAdapter.prepare(sourceURL)
        }
    }

    private func runUploadBody(_ source: PreparedSource, attemptToken: UInt64) async {
        do {
            let reporter = AttachmentStageProgressReporter { [weak self] progress in
                await self?.send(.progress(attemptToken, progress))
            }
            let staged: StagedSource
            switch source {
            case .image(let image):
                staged = try await imageAdapter.upload(image, reporter: reporter)
            case .file(let file):
                staged = try await fileAdapter.upload(file, reporter: reporter)
            }
            try Task.checkCancellation()
            send(.succeeded(attemptToken, path: staged.path))
        } catch {
            finish(error: error, medium: source.medium, attemptToken: attemptToken)
        }
    }

    private func finish(error: any Error, medium: Medium, attemptToken: UInt64) {
        send(.failed(attemptToken, Self.failure(for: error, medium: medium),
            cancelled: Self.isCancellation(error)))
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? AttachmentStagingError) == .cancelled
    }

    private static func failure(for error: any Error, medium: Medium) -> Failure {
        switch error {
        case TransportError.sshUnreachable:
            Failure(
                medium: medium,
                message: "The Host is not connected. Reconnect, then retry the upload.",
                isRetryable: true)
        case AttachmentStagingError.sftpUnavailable:
            Failure(
                medium: medium,
                message: "SFTP is unavailable on this Host. Enable its SSH SFTP subsystem.",
                isRetryable: false)
        case let staging as AttachmentStagingError:
            Failure(
                medium: medium,
                message: "\(medium.displayName) upload failed.",
                isRetryable: staging.isRetryable)
        case ImagePreparationError.selectionUnavailable:
            Failure(
                medium: medium,
                message: "The selected photo is no longer available.",
                isRetryable: false)
        case ImagePreparationError.sourceTooLarge:
            Failure(
                medium: medium,
                message: "The selected image is too large to decode safely.",
                isRetryable: false)
        case ImagePreparationError.invalidImage:
            Failure(
                medium: medium,
                message: "The selected item is not a readable image.",
                isRetryable: false)
        case ImagePreparationError.unableToProduceBoundedOutput:
            Failure(
                medium: medium,
                message: "The image could not be reduced below the 16 MiB upload limit.",
                isRetryable: false)
        case ImagePreparationError.localStorageFailed:
            Failure(
                medium: medium,
                message: "Waycar couldn't prepare the image in protected local storage.",
                isRetryable: false)
        case FilePreparationError.selectionUnavailable:
            Failure(
                medium: medium,
                message: "The selected file is no longer available.",
                isRetryable: false)
        case FilePreparationError.sourceTooLarge:
            Failure(
                medium: medium,
                message: "The selected file exceeds the 64 MiB upload limit.",
                isRetryable: false)
        case FilePreparationError.localStorageFailed:
            Failure(
                medium: medium,
                message: "Waycar couldn't prepare the file in protected local storage.",
                isRetryable: false)
        default:
            Failure(
                medium: medium,
                message: "\(medium.displayName) preparation failed.",
                isRetryable: false)
        }
    }
}
