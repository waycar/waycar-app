import Foundation
import Observation

/// The Composer Tray: the images and files added to one draft, in add order,
/// each shown as a chip. Items stage on the Host one at a time through the
/// bound Attach's `ComposerStagingStore`. An Agent's ready item keeps its Host
/// path on the chip until Send composes it into the prompt; a shell's ready
/// item inserts its path into the draft instead (`completedPathSink`).
/// Removing a ready item never deletes its Host file (ADR 0005).
@MainActor
@Observable
final class ComposerTray {
    static let capacity = 10

    struct Item: Identifiable, Equatable {
        enum Kind: Equatable {
            case image
            /// The picked file's `lastPathComponent`.
            case file(name: String)
        }

        enum Status: Equatable {
            case queued
            case staging(operationID: UInt64)
            case failed(message: String, isRetryable: Bool)
            case ready(path: String)
        }

        let id: UUID
        let kind: Kind
        /// Images only, filled asynchronously after the item is added.
        var thumbnail: ImageThumbnail?
        var status: Status

        /// A thumbnail compares by presence: `CGImage` has no value equality.
        static func == (lhs: Item, rhs: Item) -> Bool {
            lhs.id == rhs.id && lhs.kind == rhs.kind && lhs.status == rhs.status
                && (lhs.thumbnail == nil) == (rhs.thumbnail == nil)
        }
    }

    /// The bound staging store. Weak: the tray lives as long as the draft and
    /// outlives any one Attach. Boxed so binding is observed while the
    /// reference itself stays weak.
    private struct StagingBinding {
        weak var store: ComposerStagingStore?
    }

    /// One pending thumbnail decode. It holds the selection itself, so an
    /// item that becomes ready first still gets its preview.
    private struct ThumbnailJob {
        let id: Item.ID
        let selection: any ImageSelection
    }

    /// Item is the presentation value, also held by queued messages. Live
    /// entries alone own a source and its worker lifecycle.
    private struct Entry {
        let id: Item.ID
        let kind: Item.Kind
        var thumbnail: ImageThumbnail?
        var lifecycle: ComposerTrayItemMachine

        var item: Item? {
            guard let status = lifecycle.status else { return nil }
            return Item(id: id, kind: kind, thumbnail: thumbnail, status: status)
        }
    }

    private var entries: [Entry] = []
    var items: [Item] { entries.compactMap(\.item) }

    /// Why the last `add` left sources out: the tray was full. Cleared by
    /// the next `add` that takes everything, any `remove`, and
    /// `takeReadyItems()`.
    private(set) var notice: String?

    /// Shell mode: when set, a completed item's path is inserted
    /// (`"<path> "`) through this sink and the item leaves the tray.
    @ObservationIgnored var completedPathSink: (@MainActor (String) -> Void)?

    private var binding = StagingBinding()
    private let clipboard: any AttachmentClipboard
    /// Set during the bound Attach's teardown so the queue starts nothing
    /// new. Observed: it decides `isActive`, so Retry and the Send hint.
    private var isSuspended = false
    @ObservationIgnored private var pendingThumbnails: [ThumbnailJob] = []
    @ObservationIgnored private var thumbnailTask: Task<Void, Never>?

    private static let stoppedMessage = "Upload stopped when you left this screen."
    private nonisolated static let thumbnailMaxPixelSize = 384

    init(clipboard: any AttachmentClipboard = SystemAttachmentClipboard()) {
        self.clipboard = clipboard
    }

    var isEmpty: Bool { items.isEmpty }

    var remainingCapacity: Int { max(0, Self.capacity - items.count) }

    var canAdd: Bool { remainingCapacity > 0 }

    var hasReadyItems: Bool { items.contains { $0.status.readyPath != nil } }

    /// Ready items' Host paths in add order.
    var readyPaths: [String] { items.compactMap(\.status.readyPath) }

    /// Any queued, staging, or failed item holds Send back.
    var blocksSend: Bool { items.contains { $0.status.readyPath == nil } }

    /// Why Send is held back, or nil when it is not. A failure outranks
    /// pending items. Retry is offered only while the tray can act on it,
    /// and pending items can only finish while it is active.
    var sendHint: String? {
        let failed = items.filter(\.status.isFailed)
        if !failed.isEmpty {
            let subject: String
            if let only = failed.first, failed.count == 1 {
                subject = only.kind == .image ? "the failed image" : "the failed file"
            } else {
                subject = "the failed items"
            }
            let offersRetry = isActive && failed.contains(where: \.status.isRetryableFailure)
            return offersRetry ? "Retry or remove \(subject)" : "Remove \(subject)"
        }
        let pending = items.filter(\.status.isPending)
        guard !pending.isEmpty else { return nil }
        guard isActive else { return "Open the terminal to finish uploading" }
        let images = pending.filter { $0.kind == .image }.count
        switch (images, pending.count - images) {
        case (1, 0): return "Waiting for image…"
        case (let count, 0): return "Waiting for \(count) images…"
        case (0, 1): return "Waiting for file…"
        case (0, let count): return "Waiting for \(count) files…"
        default: return "Waiting for \(pending.count) items…"
        }
    }

    /// A staging store is bound and no Attach teardown has suspended the
    /// tray: queued items can start and Retry can act.
    var isActive: Bool { binding.store != nil && !isSuspended }

    /// Retry can act only while the tray is active.
    var canRetry: Bool { isActive }

    /// Appends as many sources as there is room for, in order, then starts
    /// their thumbnails and the upload queue. Returns how many it took;
    /// sources past `capacity` are dropped and named by `notice`. Restoring
    /// a handed-over draft keeps every source, like `restore` keeps ready
    /// items beyond capacity. An empty `sources` changes nothing.
    @discardableResult
    func add(_ sources: [ComposerStagingStore.Source], restoring: Bool = false) -> Int {
        guard !sources.isEmpty else { return 0 }
        let accepted = sources.prefix(restoring ? sources.count : remainingCapacity)
        let dropped = sources.count - accepted.count
        notice = dropped > 0 ? Self.capacityNotice(dropped: dropped) : nil
        guard !accepted.isEmpty else { return 0 }
        var added: [Entry] = []
        for source in accepted {
            let id = UUID()
            added.append(Entry(
                id: id, kind: Self.kind(of: source), thumbnail: nil,
                lifecycle: ComposerTrayItemMachine(source: .init(id: id, value: source))))
            if case .photo(let selection) = source {
                pendingThumbnails.append(ThumbnailJob(id: id, selection: selection))
            }
        }
        entries.append(contentsOf: added)
        loadPendingThumbnails()
        startNextIfNeeded()
        return accepted.count
    }

    /// Removes an item. A staging upload is cancelled and a failed one's
    /// retained work discarded; a ready item's Host file stays (ADR 0005).
    func remove(_ id: Item.ID) {
        notice = nil
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        var entry = entries.remove(at: index)
        forget(id)
        perform(entry.lifecycle.handle(.remove))
        startNextIfNeeded()
    }

    /// Re-uploads a failed item's retained prepared file when staging still
    /// holds it; otherwise queues the item again at its position, to be
    /// prepared from its source. While the tray is not active the item stays
    /// failed: nothing could run it.
    func retry(_ id: Item.ID) {
        guard isActive, let staging = binding.store,
            let index = entries.firstIndex(where: { $0.id == id }),
            entries[index].lifecycle.status?.isFailed == true
        else { return }
        if let operationID = entries[index].lifecycle.retainedOperation,
            staging.retry(operationID: operationID)
        {
            send(.retryRetained(operationID), at: index)
            return
        }
        send(.retrySource, at: index)
        startNextIfNeeded()
    }

    /// The source an unfinished item is prepared from; nil once it is ready
    /// or removed.
    func source(of id: Item.ID) -> ComposerStagingStore.Source? {
        entries.first { $0.id == id }?.lifecycle.source
    }

    /// Copies a ready item's Host path to the local-only clipboard.
    func copyPath(_ id: Item.ID) {
        guard let path = items.first(where: { $0.id == id })?.status.readyPath else { return }
        try? clipboard.copy(path)
    }

    /// The upload fraction while this item is uploading; nil while it is
    /// queued, preparing, or anything else.
    func uploadProgress(for id: Item.ID) -> Double? {
        guard let staging = binding.store,
            case .staging(let operationID) = items.first(where: { $0.id == id })?.status,
            staging.activeOperationID == operationID,
            case .uploading(_, let progress) = staging.state
        else { return nil }
        return progress.fractionCompleted
    }

    /// Removes and returns the ready items, in order, for Send.
    func takeReadyItems() -> [Item] {
        notice = nil
        let ready = items.filter { $0.status.readyPath != nil }
        guard !ready.isEmpty else { return [] }
        let taken = entries.filter { $0.lifecycle.status?.readyPath != nil }
        entries.removeAll { $0.lifecycle.status?.readyPath != nil }
        for var entry in taken {
            forget(entry.id)
            perform(entry.lifecycle.handle(.take))
        }
        return ready
    }

    /// One item Send takes into a Queued Message: a ready item keeps its
    /// Host path, any other hands over the source to prepare it from.
    enum QueuedTake {
        case ready(Item)
        case unready(Item, ComposerStagingStore.Source)
    }

    /// Whether Send may take the tray as it is into a Queued Message (the
    /// Host is offline): some item is not ready, none is uploading, and each
    /// unready one is waiting its turn or failed in a way a retry cures, with
    /// its source still at hand.
    var canQueueUnreadyItems: Bool {
        let unready = items.filter { $0.status.readyPath == nil }
        guard !unready.isEmpty else { return false }
        return unready.allSatisfy { item in
            source(of: item.id) != nil
                && (item.status == .queued || item.status.isRetryableFailure)
        }
    }

    /// Removes and returns every item in order, for a Queued Message. A
    /// failed item's retained staging work is discarded: the queue prepares
    /// its own copy from the source.
    func takeItemsForQueue() -> [QueuedTake] {
        notice = nil
        let taken: [QueuedTake] = items.compactMap { item in
            if item.status.readyPath != nil { return .ready(item) }
            return source(of: item.id).map { .unready(item, $0) }
        }
        let removed = entries
        entries.removeAll()
        for var entry in removed {
            forget(entry.id)
            perform(entry.lifecycle.handle(.take))
        }
        return taken
    }

    /// Puts previously sent ready items back in front (Edit Draft). They
    /// return even past `capacity`: they are the user's sent content.
    func restore(_ restored: [Item]) {
        let ready = restored.compactMap { item -> Entry? in
            guard let path = item.status.readyPath else { return nil }
            return Entry(id: item.id, kind: item.kind, thumbnail: item.thumbnail,
                lifecycle: ComposerTrayItemMachine(readyPath: path))
        }
        guard !ready.isEmpty else { return }
        entries.insert(contentsOf: ready, at: 0)
    }

    /// Binds the current Attach's staging. Events from any other instance
    /// are ignored; an item still staging on a previous one becomes a
    /// retryable failure, since that upload is gone. Binding either
    /// instance clears a teardown suspension and restarts the queue.
    func bind(_ staging: ComposerStagingStore) {
        if binding.store !== staging {
            for index in entries.indices {
                send(.bindingChanged(stoppedMessage: Self.stoppedMessage), at: index)
            }
            binding = StagingBinding(store: staging)
        }
        staging.onOperationEvent = { [weak self, weak staging] event in
            guard let self, let staging, self.binding.store === staging else { return }
            self.handle(event)
        }
        isSuspended = false
        startNextIfNeeded()
    }

    /// `staging`'s Attach is tearing down: start nothing new. The in-flight
    /// item's cancellation turns into a retryable failure, which keeps the
    /// queue paused. Ignored unless `staging` is the bound instance, so a
    /// departing Attach cannot suspend its successor's tray.
    func suspendForTeardown(of staging: ComposerStagingStore) {
        guard binding.store === staging else { return }
        isSuspended = true
    }

    /// After `staging`'s teardown leave has finished and its Attach rejoined.
    /// An unresolved retryable failure still pauses the queue: nothing
    /// retries implicitly. Ignored unless `staging` is the bound instance.
    func resumeAfterRejoin(of staging: ComposerStagingStore) {
        guard binding.store === staging else { return }
        isSuspended = false
        startNextIfNeeded()
    }

    private func handle(_ event: ComposerStagingStore.OperationEvent) {
        switch event {
        case .completed(let operationID, let path):
            // A removed item's late completion finds nothing; its Host file
            // is left orphaned by design (ADR 0005).
            if let index = indexOfStaging(operationID) {
                complete(at: index, operationID: operationID, path: path)
            }
        case .failed(let operationID, let message, let retryable):
            if let index = indexOfStaging(operationID) {
                send(.failed(operationID, message: message, retryable: retryable), at: index)
            }
        case .cancelled(let operationID):
            // Remove takes the item out first, so a cancellation that still
            // finds it came from teardown.
            if let index = indexOfStaging(operationID) {
                send(.failed(operationID, message: Self.stoppedMessage, retryable: true), at: index)
            }
        }
        startNextIfNeeded()
    }

    /// Agent: the item turns ready, its chip keeping the path until Send.
    /// Shell: the path goes into the draft and the item leaves the tray.
    private func complete(at index: Int, operationID: UInt64, path: String) {
        send(.completed(operationID, path: path), at: index)
        if let completedPathSink {
            let id = entries.remove(at: index).id
            forget(id)
            completedPathSink("\(path) ")
        }
    }

    private func send(_ event: ComposerTrayItemMachine.Event, at index: Int) {
        perform(entries[index].lifecycle.handle(event))
    }

    private func perform(_ effects: [ComposerTrayItemMachine.Effect]) {
        for effect in effects {
            switch effect {
            case .discardSource(let source): Self.discardLocalCopy(source.value)
            case .cancel(let operationID): binding.store?.cancel(operationID: operationID)
            case .dismiss(let operationID): binding.store?.dismiss(operationID: operationID)
            }
        }
    }

    /// App-owned file copies the tray reads from: Edit Draft's copies of a
    /// Queued Message's files that never uploaded
    /// (`AgentComposerStore.unsentSources`) and pasted files. Each sits in
    /// its own folder here, deleted once the tray has uploaded or dropped
    /// it, or the queue has prepared it again, and swept at launch.
    static var localCopiesDirectory: URL {
        FileManager.default.temporaryDirectory
            .appending(path: "WaycarAttachmentCopies", directoryHint: .isDirectory)
    }

    /// Has `write` create the file `name` in a fresh folder under
    /// `localCopiesDirectory` and returns its URL; a failed write leaves no
    /// folder behind.
    static func makeLocalCopy(named name: String, write: (URL) throws -> Void) throws -> URL {
        let folder = localCopiesDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let copy = folder.appending(path: name, directoryHint: .notDirectory)
        do {
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete])
            try write(copy)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.complete], ofItemAtPath: copy.path)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return copy
    }

    /// Deletes `source`'s folder when it is one of the local copies.
    static func discardLocalCopy(_ source: ComposerStagingStore.Source) {
        guard case .file(let url) = source else { return }
        let folder = url.deletingLastPathComponent().standardizedFileURL
        guard folder.deletingLastPathComponent().path
            == localCopiesDirectory.standardizedFileURL.path
        else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Deletes every leftover local copy; the app calls it at launch.
    static func sweepLocalCopies() {
        try? FileManager.default.removeItem(at: localCopiesDirectory)
    }

    /// Begins the first queued item, one upload at a time. A retryable
    /// failure pauses the queue until it is retried or removed.
    private func startNextIfNeeded() {
        guard !isSuspended, let staging = binding.store, !staging.state.isBusy,
            !items.contains(where: { $0.status.isStaging || $0.status.isRetryableFailure }),
            let index = entries.firstIndex(where: { $0.lifecycle.status == .queued }),
            let source = entries[index].lifecycle.source,
            let operationID = staging.begin(source)
        else { return }
        send(.started(operationID), at: index)
    }

    private func indexOfStaging(_ operationID: UInt64) -> Int? {
        entries.firstIndex { $0.lifecycle.status == .staging(operationID: operationID) }
    }

    private func forget(_ id: Item.ID) {
        pendingThumbnails.removeAll { $0.id == id }
    }

    /// Decodes pending thumbnails serially, so at most one source blob is
    /// loaded at a time.
    private func loadPendingThumbnails() {
        guard thumbnailTask == nil, !pendingThumbnails.isEmpty else { return }
        thumbnailTask = Task { [weak self] in
            while let job = self?.nextThumbnailJob() {
                let thumbnail = await Self.thumbnail(for: job.selection)
                self?.setThumbnail(thumbnail, for: job.id)
            }
        }
    }

    /// The next job, or nil — ending the decode task — when none is left.
    private func nextThumbnailJob() -> ThumbnailJob? {
        guard !pendingThumbnails.isEmpty else {
            thumbnailTask = nil
            return nil
        }
        return pendingThumbnails.removeFirst()
    }

    private func setThumbnail(_ thumbnail: ImageThumbnail?, for id: Item.ID) {
        guard let thumbnail, let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].thumbnail = thumbnail
    }

    private nonisolated static func thumbnail(
        for selection: any ImageSelection
    ) async -> ImageThumbnail? {
        guard let data = try? await selection.loadData() else { return nil }
        return await ImageThumbnail.make(data: data, maxPixelSize: thumbnailMaxPixelSize)
    }

    private static func kind(of source: ComposerStagingStore.Source) -> Item.Kind {
        switch source {
        case .photo: .image
        case .file(let url): .file(name: url.lastPathComponent)
        }
    }

    private static func capacityNotice(dropped: Int) -> String {
        let outcome = dropped == 1 ? "1 wasn't added." : "\(dropped) weren't added."
        return "Only \(capacity) images or files fit in one message. \(outcome)"
    }
}

extension ComposerTray.Item.Status {
    var readyPath: String? {
        if case .ready(let path) = self { return path }
        return nil
    }

    var failureMessage: String? {
        if case .failed(let message, _) = self { return message }
        return nil
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    var isRetryableFailure: Bool {
        if case .failed(_, true) = self { return true }
        return false
    }

    var isStaging: Bool {
        if case .staging = self { return true }
        return false
    }

    /// Queued or staging: on its way to ready.
    var isPending: Bool {
        switch self {
        case .queued, .staging: true
        case .failed, .ready: false
        }
    }
}
