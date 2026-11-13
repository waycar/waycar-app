import Foundation
import WaycarSSH

private enum WaycarSSHNotificationFileError: Error, Sendable {
    case permissionVerificationFailed
}

#if DEBUG
struct WaycarSSHNotificationFileStateForTesting: Sendable, Equatable {
    let activeClientCount: Int
    let temporaryPaths: [String]
    let ordinarySessionCount: Int
    let connectionChannelCount: Int
    let writeIsDelayed: Bool
}

/// Internal staging milestones for deterministic test barriers. Not user-visible
/// progress — `AttachmentStageProgress` keeps its numeric meaning unchanged.
enum AttachmentStagingPhaseForTesting: Sendable, Hashable {
    /// Remote staging parent directory exists; payload transfer has not begun.
    case remoteParentReady
    /// About to enter the SFTP payload write loop.
    case payloadWriteReady
}
#endif

private actor WaycarSSHNotificationFileCompletion {
    private var finished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !finished else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        let pendingWaiters = waiters
        waiters.removeAll(keepingCapacity: false)
        for waiter in pendingWaiters { waiter.resume() }
    }
}

private struct StagingSource {
    let fileURL: URL
    let byteCount: Int64
    let remoteFilename: String
}

// Host files over SFTP: ranged reads, previews, directory listings,
// attachment staging and the private config files (ADR 0006, #325).
extension HostSSHSession {
    // MARK: File slice

    /// Reads one range of a Host file over a channel kept for exactly that.
    ///
    /// The holder is deliberate: a screen that looks every few seconds would
    /// otherwise allocate and release an SFTP subsystem channel on every tick.
    /// The lease is held for as long as the channel is (ADR 0011, #148): an
    /// app-side counter that ignored a channel still open would let the
    /// server's `MaxSessions` be spent while admission looked free. A failed
    /// read drops both, so the next look opens a fresh one rather than
    /// reading through a corpse. A cancelled read too: one cut off inside its
    /// SFTP request has had the subsystem shut down under it
    /// (`SSHSFTPClient`), so the holder may already be gone. While another
    /// read is still on the holder, that read settles it instead: it fails
    /// the same way if the channel is gone, and closing the channel under it
    /// would strand the channel mid-use. The channel is returned once nobody
    /// has read through it for `sessionFileClientIdleTimeout`.
    ///
    /// The holder's states are `RangedFileHolderMachine`'s.
    func readFileSlice(_ range: RemoteFileRange) async throws -> RemoteFileSlice {
        let start = sessionFileHolder.handle(.readStarted)
        defer { scheduleSessionFileClientIdleRelease(sessionFileHolder.handle(.readEnded)) }
        do {
            let client = try await sessionFileClientForReading(start)
            let slice = try await client.readFileRange(
                at: range.path,
                offset: range.offset,
                maxBytes: range.maxBytes,
                timeout: requestTimeout)
            return RemoteFileSlice(data: slice.data, length: slice.length)
        } catch {
            let mapped = mapOperationError(error)
            await performSessionFileHolder(sessionFileHolder.handle(.readFailed))
            throw mapped
        }
    }

    /// Reads a tapped path over an SFTP channel of its own: one open, `fstat`
    /// on that handle, every chunk from it, one close (see
    /// `SSHSFTPClient.readRegularFile`). No shell sees the path. It is not
    /// `readFileSlice`'s holder: a large file can take minutes to arrive,
    /// which the usage strip must not queue behind, and a read that is
    /// cancelled or times out has its subsystem shut down under it, which
    /// would fail whatever else was queued on a shared one — tapping a second
    /// path while the first still loads included. The channel is closed
    /// however the read ends, so a server stuck opening a FIFO swapped in
    /// after the check does not keep it.
    func readPreviewFile(atPath path: String, maxBytes: Int) async throws -> Data {
        guard path.hasPrefix("/") else { throw RemoteFilePreviewError.unresolvablePath }
        let read: SSHSFTPRegularFileRead
        do {
            read = try await channelAdmission.withChannel(.ordinarySession) {
                let sftp = try await self.openSFTPOutsideCancellation()
                do {
                    let read = try await sftp.readRegularFile(
                        at: path, maxBytes: maxBytes, timeout: self.requestTimeout)
                    try? await sftp.close(timeout: .seconds(2))
                    return read
                } catch {
                    try? await sftp.close(timeout: .seconds(2))
                    throw error
                }
            }
        } catch is CancellationError {
            throw TransportError.cancelled
        } catch {
            throw mapOperationError(error)
        }
        switch read {
        case .contents(let data): return data
        case .missing: throw RemoteFilePreviewError.missing
        case .permissionDenied: throw RemoteFilePreviewError.unreadable
        case .directory: throw RemoteFilePreviewError.directory
        case .notRegularFile: throw RemoteFilePreviewError.notRegularFile
        case .tooLarge(let size):
            throw RemoteFilePreviewError.tooLarge(size: size, limit: maxBytes)
        }
    }

    /// Opens an SFTP channel the caller's cancellation cannot interrupt:
    /// libssh2 keeps one SFTP-init state per session, so an init abandoned
    /// once it started costs the whole SSH session (`SessionDriver.openSFTP`).
    /// A caller cancelled meanwhile gets the channel closed again instead.
    private func openSFTPOutsideCancellation() async throws -> SSHSFTPClient {
        let connection = connection
        let timeout = requestTimeout
        let client = try await Task {
            try await connection.openSFTP(timeout: timeout)
        }.value
        guard !Task.isCancelled else {
            try? await client.close(timeout: .seconds(2))
            throw CancellationError()
        }
        return client
    }

    /// The client `readStarted`'s effects lead to: the open one, the open in
    /// flight, or a new open.
    private func sessionFileClientForReading(
        _ effects: [RangedFileHolderMachine.Effect]
    ) async throws -> SSHSFTPClient {
        for effect in effects {
            switch effect {
            case .cancelIdleRelease:
                cancelSessionFileClientIdleRelease()
            case .use:
                if let sessionFileClient { return sessionFileClient }
            case .joinOpening:
                if let opening = sessionFileClientOpening { return try await opening.value }
            case .open(let token):
                let opening = openSessionFileClient(token: token)
                sessionFileClientOpening = opening
                return try await opening.value
            case .close, .armIdleRelease:
                continue
            }
        }
        throw TransportError.sshUnreachable(detail: "the Host is not connected")
    }

    /// Inherits this actor's isolation, so the task installs the holder
    /// itself; every caller, first or later, just awaits it.
    private func openSessionFileClient(token: UInt64) -> Task<SSHSFTPClient, any Error> {
        Task { () throws -> SSHSFTPClient in
            defer { sessionFileClientOpening = nil }
            do {
                let lease = try await channelAdmission.acquire(.ordinarySession)
                let client: SSHSFTPClient
                do {
                    client = try await connection.openSFTP(timeout: requestTimeout)
                } catch {
                    await lease.release()
                    throw error
                }
                guard connected else {
                    // Closed while the open was in flight: `close()` already
                    // drained the holders, so this channel would be unowned.
                    try? await client.close(timeout: .seconds(2))
                    await lease.release()
                    throw TransportError.sshUnreachable(detail: "the Host is not connected")
                }
                sessionFileClient = client
                sessionFileClientLease = lease
                _ = sessionFileHolder.handle(.opened(token: token))
                return client
            } catch {
                _ = sessionFileHolder.handle(.openFailed(token: token))
                throw error
            }
        }
    }

    /// A read's end: disarm the idle release, and arm it again when the read
    /// was the last one on an open channel. It never closes anything.
    private func scheduleSessionFileClientIdleRelease(
        _ effects: [RangedFileHolderMachine.Effect]
    ) {
        for effect in effects {
            switch effect {
            case .cancelIdleRelease:
                cancelSessionFileClientIdleRelease()
            case .armIdleRelease:
                sessionFileClientIdleRelease = Task { [weak self] in
                    try? await Task.sleep(for: Self.sessionFileClientIdleTimeout)
                    guard !Task.isCancelled else { return }
                    await self?.sessionFileClientIdleReleaseElapsed()
                }
            case .use, .joinOpening, .open, .close:
                assertionFailure("a read's end only schedules the idle release")
            }
        }
    }

    /// Performs a failed read's or the idle release's effects.
    private func performSessionFileHolder(_ effects: [RangedFileHolderMachine.Effect]) async {
        for effect in effects {
            switch effect {
            case .cancelIdleRelease:
                cancelSessionFileClientIdleRelease()
            case .armIdleRelease:
                scheduleSessionFileClientIdleRelease([effect])
            case .close:
                let client = sessionFileClient
                sessionFileClient = nil
                let lease = sessionFileClientLease
                sessionFileClientLease = nil
                try? await client?.close(timeout: .seconds(2))
                await lease?.release()
            case .use, .joinOpening, .open:
                continue
            }
        }
    }

    private func sessionFileClientIdleReleaseElapsed() async {
        await performSessionFileHolder(sessionFileHolder.handle(.idleElapsed))
    }

    func cancelSessionFileClientIdleRelease() {
        sessionFileClientIdleRelease?.cancel()
        sessionFileClientIdleRelease = nil
    }

    // MARK: Directory listing

    /// Directories-only listing of one absolute quotable remote path, for
    /// the remote directory browser (#280). Paths that cannot be passed to
    /// the Host's login shell throw `TransportError.invalidDirectoryPath`
    /// before any channel opens.
    func listDirectories(at path: String) async throws -> RemoteDirectoryListing {
        guard Self.validatedDirectoryPath(path) != nil else {
            throw TransportError.invalidDirectoryPath(path: path)
        }
        return try await channelAdmission.withChannel(.ordinarySession) {
            let sftp = try await self.connection.openSFTP(timeout: self.requestTimeout)
            do {
                let listing = try await sftp.listDirectories(
                    at: path,
                    timeout: self.requestTimeout)
                try? await sftp.close(timeout: .seconds(2))
                return RemoteDirectoryListing(
                    directories: listing.entries.map(\.name),
                    truncated: listing.truncated)
            } catch {
                try? await sftp.close(timeout: .seconds(2))
                throw error
            }
        }
    }

    /// The path when it is absolute and quotable for the Host's login
    /// shell, nil otherwise. `RemoteShellPath` refuses empty and relative
    /// paths plus quote, backslash, and control characters; NUL (`\0`)
    /// arrives as a control character and is refused the same way.
    static func validatedDirectoryPath(_ path: String) -> String? {
        guard !path.isEmpty, RemoteShellPath.isQuotableAbsolute(path) else {
            return nil
        }
        return path
    }

    // MARK: Config files

    func readConfigFile(named name: String, inDirectory directory: String) async throws -> Data? {
        try await Self.withNotificationFileDeadline(requestTimeout) {
            guard await self.isConnected else {
                throw NotificationRegistrationError.readFailed(
                    detail: "The SSH connection is unavailable.")
            }
            return try await self.readConfigFileWithinDeadline(
                named: name, inDirectory: directory)
        }
    }

    func replaceConfigFile(
        named name: String, inDirectory directory: String, subdirectory: String?,
        contents: Data
    ) async throws {
        try await Self.withNotificationFileDeadline(requestTimeout) {
            guard await self.isConnected else {
                throw NotificationRegistrationError.writeFailed(
                    detail: "The SSH connection is unavailable.")
            }
            try await self.replaceConfigFileWithinDeadline(
                named: name, inDirectory: directory, subdirectory: subdirectory,
                contents: contents)
        }
    }

    func deleteConfigFile(
        named name: String, inDirectory directory: String, subdirectory: String?
    ) async throws {
        try await Self.withNotificationFileDeadline(requestTimeout) {
            guard await self.isConnected else {
                throw NotificationRegistrationError.writeFailed(
                    detail: "The SSH connection is unavailable.")
            }
            try await self.deleteConfigFileWithinDeadline(
                named: name, inDirectory: directory, subdirectory: subdirectory)
        }
    }

    /// `readConfigFile` for a caller that already runs the availability
    /// check and the deadline around a longer operation (herdr resolves its
    /// plugin config dir inside the same budget).
    func readConfigFileWithinDeadline(
        named name: String, inDirectory directory: String
    ) async throws -> Data? {
        let path = "\(directory)/\(name)"
        let operationID = UUID()
        return try await channelAdmission.withChannel(.ordinarySession) {
            try await self.performNotificationFileRead(
                at: path,
                configDirectory: directory,
                operationID: operationID)
        }
    }

    /// `replaceConfigFile` inside the caller's deadline: `subdirectory` of
    /// `directory` is created (0700) when missing.
    func replaceConfigFileWithinDeadline(
        named name: String, inDirectory configDirectory: String, subdirectory: String?,
        contents: Data
    ) async throws {
        let directory = subdirectory.map { "\(configDirectory)/\($0)" } ?? configDirectory
        let path = "\(directory)/\(name)"
        let operationID = UUID()
        try await channelAdmission.withChannel(.ordinarySession) {
            try await self.performNotificationFileReplace(
                contents,
                at: path,
                configDirectory: directory,
                createsDirectory: subdirectory != nil,
                operationID: operationID)
        }
    }

    /// `deleteConfigFile` inside the caller's deadline.
    func deleteConfigFileWithinDeadline(
        named name: String, inDirectory configDirectory: String, subdirectory: String?
    ) async throws {
        let directory = subdirectory.map { "\(configDirectory)/\($0)" } ?? configDirectory
        let path = "\(directory)/\(name)"
        try await channelAdmission.withChannel(.ordinarySession) {
            try await self.performConfigFileDelete(at: path)
        }
    }

    /// Runs one config-file operation within `budget`. On timeout or
    /// cancellation it still waits for the operation to unwind, so its SFTP
    /// channel and temporary file are settled before the caller hears back.
    static func withNotificationFileDeadline<T: Sendable>(
        _ budget: Duration,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let completion = WaycarSSHNotificationFileCompletion()
        do {
            return try await withDeadline(budget) {
                do {
                    let value = try await operation()
                    await completion.finish()
                    return value
                } catch {
                    await completion.finish()
                    throw error
                }
            }
        } catch {
            await completion.wait()
            throw error
        }
    }

    private func performConfigFileDelete(at path: String) async throws {
        let sftp: SSHSFTPClient
        do {
            sftp = try await connection.openSFTP(timeout: requestTimeout)
        } catch {
            try Self.notificationWriteError(error)
        }
        do {
            try Task.checkCancellation()
            do {
                try await sftp.removeFile(at: path, timeout: requestTimeout)
            } catch SSHError.sftpFailure(let status) where status == Self.sftpNoSuchFileStatus {
                // Already gone (the plugin's GC, or an earlier retire).
            }
            try await sftp.close(timeout: .seconds(2))
        } catch {
            try? await sftp.close(timeout: .seconds(2))
            if !(await connection.isConnected) { noteConnectionInvalidated() }
            try Self.notificationWriteError(error)
        }
    }

    /// SFTP's `SSH_FX_NO_SUCH_FILE`.
    private static let sftpNoSuchFileStatus: UInt64 = 2

    private func performNotificationFileRead(
        at path: String,
        configDirectory: String,
        operationID: UUID
    ) async throws -> Data? {
        let sftp: SSHSFTPClient
        do {
            sftp = try await connection.openSFTP(timeout: requestTimeout)
        } catch {
            try Self.notificationReadError(error)
        }
        notificationFileClients[operationID] = sftp

        do {
            try Task.checkCancellation()
            try await enforceNotificationPermissions(
                0o700,
                at: configDirectory,
                over: sftp)
            let contents = try await sftp.readFileIfPresent(
                at: path,
                timeout: requestTimeout)
            if contents != nil {
                try await enforceNotificationPermissions(0o600, at: path, over: sftp)
            }
            notificationFileClients[operationID] = nil
            try await sftp.close(timeout: requestTimeout)
            return contents
        } catch {
            notificationFileClients[operationID] = nil
            try? await sftp.close(timeout: .seconds(2))
            try Self.notificationReadError(error)
        }
    }

    private func performNotificationFileReplace(
        _ contents: Data,
        at path: String,
        configDirectory: String,
        createsDirectory: Bool = false,
        operationID: UUID
    ) async throws {
        let sftp: SSHSFTPClient
        do {
            sftp = try await connection.openSFTP(timeout: requestTimeout)
        } catch {
            try Self.notificationWriteError(error)
        }
        notificationFileClients[operationID] = sftp
        var temporaryPath: String? = "\(path).tmp-\(UUID().uuidString.lowercased())"
        notificationTemporaryPaths[operationID] = temporaryPath

        do {
            try Task.checkCancellation()
            if createsDirectory {
                try await createNotificationDirectoryIfMissing(configDirectory, over: sftp)
            }
            try await enforceNotificationPermissions(
                0o700,
                at: configDirectory,
                over: sftp)
            guard let currentTemporaryPath = temporaryPath else {
                throw NotificationRegistrationError.writeFailed(
                    detail: "The private temporary file is unavailable.")
            }
            let file = try await sftp.openFileForWriting(
                at: currentTemporaryPath,
                permissions: 0o600,
                timeout: requestTimeout)
            do {
                try await enforceNotificationPermissions(
                    0o600,
                    at: currentTemporaryPath,
                    over: sftp)
                if !contents.isEmpty {
                    try await file.write(contents, timeout: requestTimeout)
                }
                try await file.close(timeout: requestTimeout)
            } catch {
                try? await file.close(timeout: .seconds(2))
                throw error
            }

            let temporaryAttributes = try await sftp.attributes(
                at: currentTemporaryPath,
                timeout: requestTimeout)
            guard
                temporaryAttributes.size == UInt64(contents.count),
                temporaryAttributes.permissions == 0o600
            else {
                throw NotificationRegistrationError.writeFailed(
                    detail: "The private temporary file failed verification.")
            }
            try Task.checkCancellation()
            try await sftp.renameFileAtomically(
                from: currentTemporaryPath,
                to: path,
                timeout: requestTimeout)
            temporaryPath = nil
            notificationTemporaryPaths[operationID] = nil
            try await sftp.close(timeout: .seconds(2))
            notificationFileClients[operationID] = nil
        } catch {
            let operationError = error
            var compensationFailed = false
            if let temporaryPath {
                do {
                    try await removeNotificationTemporaryFile(
                        at: temporaryPath,
                        over: sftp)
                } catch {
                    compensationFailed = true
                }
            }
            notificationTemporaryPaths[operationID] = nil
            try? await sftp.close(timeout: .seconds(2))
            notificationFileClients[operationID] = nil
            if !(await connection.isConnected) { noteConnectionInvalidated() }
            if compensationFailed {
                throw NotificationRegistrationError.writeFailed(
                    detail: "The incomplete temporary file could not be removed safely.")
            }
            try Self.notificationWriteError(operationError)
        }
    }

    private func enforceNotificationPermissions(
        _ permissions: UInt32,
        at path: String,
        over sftp: SSHSFTPClient
    ) async throws {
        try await sftp.setPermissions(permissions, at: path, timeout: requestTimeout)
        let attributes = try await sftp.attributes(at: path, timeout: requestTimeout)
        guard attributes.permissions == permissions else {
            throw WaycarSSHNotificationFileError.permissionVerificationFailed
        }
    }

    /// Creates `directory` (0700) unless it already exists. Losing a race
    /// to another creator is fine: the directory is then there all the same.
    private func createNotificationDirectoryIfMissing(
        _ directory: String,
        over sftp: SSHSFTPClient
    ) async throws {
        guard (try? await sftp.attributes(at: directory, timeout: requestTimeout)) == nil else {
            return
        }
        do {
            try await sftp.createDirectory(
                at: directory, permissions: 0o700, timeout: requestTimeout)
        } catch {
            guard (try? await sftp.attributes(at: directory, timeout: requestTimeout)) != nil else {
                throw error
            }
        }
    }

    private func removeNotificationTemporaryFile(
        at path: String,
        over currentSFTP: SSHSFTPClient
    ) async throws {
        try await currentSFTP.removeFileForCompensation(
            at: path,
            timeout: .seconds(2))
    }

    private static func notificationReadError(_ error: any Error) throws -> Never {
        if isNotificationCancellation(error) { throw TransportError.cancelled }
        if isNotificationTimeout(error) { throw TransportError.timedOut }
        if let error = error as? NotificationRegistrationError { throw error }
        throw NotificationRegistrationError.readFailed(
            detail: notificationFailureDetail(error))
    }

    private static func notificationWriteError(_ error: any Error) throws -> Never {
        if isNotificationCancellation(error) { throw TransportError.cancelled }
        if isNotificationTimeout(error) { throw TransportError.timedOut }
        if let error = error as? NotificationRegistrationError { throw error }
        throw NotificationRegistrationError.writeFailed(
            detail: notificationFailureDetail(error))
    }

    private static func isNotificationCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if error as? SSHError == .cancelled { return true }
        if error as? TransportError == .cancelled { return true }
        return false
    }

    private static func isNotificationTimeout(_ error: any Error) -> Bool {
        if error as? SSHError == .timedOut { return true }
        if error as? TransportError == .timedOut { return true }
        return false
    }

    private static func notificationFailureDetail(_ error: any Error) -> String {
        if let error = error as? SSHError,
            case .sftpFailure(let status) = error
        {
            return "SFTP failed with status \(status)."
        }
        if error as? SSHError == .sftpUnavailable {
            return "SFTP is unavailable."
        }
        return "The SSH file operation failed."
    }

    // MARK: Attachment staging

    func stageImage(
        _ image: PreparedImage,
        progress: @escaping @Sendable (AttachmentStageProgress) async -> Void
    ) async throws -> StagedImage {
        guard
            image.byteCount > 0,
            image.byteCount <= Int64(ImagePreparer.maximumEncodedByteCount),
            let localSize = try? FileManager.default.attributesOfItem(
                atPath: image.fileURL.path)[.size] as? NSNumber,
            localSize.int64Value == image.byteCount
        else {
            throw AttachmentStagingError.invalidPreparedSource
        }
        let path = try await stage(
            StagingSource(
                fileURL: image.fileURL,
                byteCount: image.byteCount,
                remoteFilename: "image.\(image.format.fileExtension)"),
            progress: progress)
        return try StagedImage(path: path)
    }

    func stageFile(
        _ file: PreparedFile,
        progress: @escaping @Sendable (AttachmentStageProgress) async -> Void
    ) async throws -> StagedFile {
        guard
            file.byteCount > 0,
            file.byteCount <= Int64(FilePreparer.maximumByteCount),
            let localSize = try? FileManager.default.attributesOfItem(
                atPath: file.fileURL.path)[.size] as? NSNumber,
            localSize.int64Value == file.byteCount
        else {
            throw AttachmentStagingError.invalidPreparedSource
        }
        let path = try await stage(
            StagingSource(
                fileURL: file.fileURL,
                byteCount: file.byteCount,
                remoteFilename: file.remoteFilename),
            progress: progress)
        return try StagedFile(path: path)
    }

    private func stage(
        _ source: StagingSource,
        progress: @escaping @Sendable (AttachmentStageProgress) async -> Void
    ) async throws -> String {
        guard connected, await connection.isConnected else {
            throw AttachmentStagingError.transferFailed
        }

        await progress(
            AttachmentStageProgress(transferredBytes: 0, totalBytes: source.byteCount))
        let parentDirectory = try await createStageParentDirectory()
#if DEBUG
        await signalStagingPhaseForTesting(.remoteParentReady)
#endif
        let operationID = UUID()

        do {
            // No cancellation handler. One used to race the staging task from
            // `onCancel:`, closing the SFTP client out from under it so the
            // compensation had to open a fresh one to unlink the `.part` — and
            // that fresh open is what killed the connection on a slow link
            // (#136). Cancellation reaches the blocked write on its own:
            // `checkProgress` and the socket wait the driver parks in are both
            // cancellable, so the write unwinds and the structured compensation
            // below runs with the client it already owns.
            return try await channelAdmission.withChannel(.ordinarySession) {
                try await self.performStage(
                    source,
                    parentDirectory: parentDirectory,
                    operationID: operationID,
                    progress: progress)
            }
        } catch let error as AttachmentStagingError {
            throw error
        } catch is CancellationError {
            throw AttachmentStagingError.cancelled
        } catch {
            throw Task.isCancelled
                ? AttachmentStagingError.cancelled : AttachmentStagingError.transferFailed
        }
    }

    private func createStageParentDirectory() async throws -> String {
        do {
            let result = try await runExec(Self.cLocaleCommand(stageDirectoryCommand))
            guard
                result.exitStatus == 0,
                result.reachedEOF,
                let directory = Self.markerValue(
                    in: result.stdout,
                    prefix: Self.stageDirectoryOutputPrefix)
            else {
                throw AttachmentStagingError.remoteTemporaryDirectoryFailed
            }
            return try StagedImage(path: "\(directory)/placeholder").fileURL
                .deletingLastPathComponent().path
        } catch let error as AttachmentStagingError {
            throw error
        } catch TransportError.cancelled {
            throw AttachmentStagingError.cancelled
        } catch {
            let connectionIsConnected = await connection.isConnected
            if !connected || !connectionIsConnected {
                throw AttachmentStagingError.transferFailed
            }
            throw AttachmentStagingError.remoteTemporaryDirectoryFailed
        }
    }

    private func performStage(
        _ source: StagingSource,
        parentDirectory: String,
        operationID: UUID,
        progress: @escaping @Sendable (AttachmentStageProgress) async -> Void
    ) async throws -> String {
        let sftp: SSHSFTPClient
        do {
            sftp = try await connection.openSFTP(timeout: requestTimeout)
        } catch SSHError.sftpUnavailable {
            throw AttachmentStagingError.sftpUnavailable
        } catch {
            if Task.isCancelled { throw AttachmentStagingError.cancelled }
            throw AttachmentStagingError.transferFailed
        }
        imageStageClients[operationID] = sftp

        let stageID = UUID().uuidString.lowercased()
        let remoteDirectory = "\(parentDirectory)/stage-\(stageID)"
        let finalPath = "\(remoteDirectory)/\(source.remoteFilename)"
        var partPath: String? = "\(finalPath).part"

        do {
            try await enforcePermissions(0o700, at: parentDirectory, over: sftp)
            try await sftp.createDirectory(
                at: remoteDirectory,
                permissions: 0o700,
                timeout: requestTimeout)
            try await enforcePermissions(0o700, at: remoteDirectory, over: sftp)

            guard let currentPartPath = partPath else {
                throw AttachmentStagingError.transferFailed
            }
            try await streamFile(
                at: source.fileURL,
                byteCount: source.byteCount,
                to: currentPartPath,
                over: sftp,
                progress: progress)
            try Task.checkCancellation()

            let uploadedAttributes = try await sftp.attributes(
                at: currentPartPath,
                timeout: requestTimeout)
            guard uploadedAttributes.size == UInt64(source.byteCount) else {
                throw AttachmentStagingError.byteCountMismatch
            }
            guard uploadedAttributes.permissions == 0o600 else {
                throw AttachmentStagingError.permissionEnforcementFailed
            }
            try await sftp.renameFileAtomically(
                from: currentPartPath,
                to: finalPath,
                timeout: requestTimeout)
            partPath = nil

            let finalAttributes = try await sftp.attributes(
                at: finalPath,
                timeout: requestTimeout)
            guard finalAttributes.size == UInt64(source.byteCount) else {
                throw AttachmentStagingError.byteCountMismatch
            }
            guard finalAttributes.permissions == 0o600 else {
                throw AttachmentStagingError.permissionEnforcementFailed
            }
            imageStageClients[operationID] = nil
            try await sftp.close(timeout: requestTimeout)
            return finalPath
        } catch {
            imageStageClients[operationID] = nil
            if let partPath {
                await bestEffortRemoveRemoteFile(at: partPath, over: sftp)
            }
            try? await sftp.close(timeout: .seconds(2))
            if Task.isCancelled { throw AttachmentStagingError.cancelled }
            if let stagingError = error as? AttachmentStagingError {
                throw stagingError
            }
            if error as? SSHError == .sftpUnavailable {
                throw AttachmentStagingError.sftpUnavailable
            }
            throw AttachmentStagingError.transferFailed
        }
    }

    private func enforcePermissions(
        _ permissions: UInt32,
        at path: String,
        over sftp: SSHSFTPClient
    ) async throws {
        try await sftp.setPermissions(permissions, at: path, timeout: requestTimeout)
        let attributes = try await sftp.attributes(at: path, timeout: requestTimeout)
        guard attributes.permissions == permissions else {
            throw AttachmentStagingError.permissionEnforcementFailed
        }
    }

    private func streamFile(
        at localURL: URL,
        byteCount: Int64,
        to remotePath: String,
        over sftp: SSHSFTPClient,
        progress: @escaping @Sendable (AttachmentStageProgress) async -> Void
    ) async throws {
        let localFile: FileHandle
        do {
            localFile = try FileHandle(forReadingFrom: localURL)
        } catch {
            throw AttachmentStagingError.localReadFailed
        }
        defer { try? localFile.close() }

        let remoteFile = try await sftp.openFileForWriting(
            at: remotePath,
            permissions: 0o600,
            timeout: requestTimeout)
        do {
            try await enforcePermissions(0o600, at: remotePath, over: sftp)
#if DEBUG
            await signalStagingPhaseForTesting(.payloadWriteReady)
#endif
            let chunkSize = 64 * 1_024
            var transferred: Int64 = 0
            while transferred < byteCount {
                try Task.checkCancellation()
                let remaining = byteCount - transferred
                let requested = min(chunkSize, Int(remaining))
                guard
                    let data = try localFile.read(upToCount: requested),
                    !data.isEmpty
                else {
                    throw AttachmentStagingError.byteCountMismatch
                }
                try await remoteFile.write(data, timeout: requestTimeout)
                transferred += Int64(data.count)
                await progress(AttachmentStageProgress(
                    transferredBytes: transferred,
                    totalBytes: byteCount))
            }
            guard try localFile.read(upToCount: 1)?.isEmpty != false else {
                throw AttachmentStagingError.byteCountMismatch
            }
            try await remoteFile.close(timeout: requestTimeout)
        } catch {
            try? await remoteFile.close(timeout: .seconds(2))
            throw error
        }
    }

    /// Unlinks one abandoned `.part` so the user's attachment bytes do not outlive
    /// the failed operation, on the SFTP client that operation already owns.
    ///
    /// Detached, because the caller is usually a cancelled task and the unlink
    /// would inherit that cancellation and skip. Never on a *fresh* client:
    /// `SessionDriver.openSFTP` invalidates the whole session when its own
    /// budget expires, deliberately — an abandoned `libssh2_sftp_init` leaves
    /// session state no later call can clean up — and a cleanup that can kill
    /// the connection is not best-effort. Opening one here on a two-second
    /// budget is what made cancelling an upload over a slow link report
    /// `.sshUnreachable` on the user's next request (#136).
    private func bestEffortRemoveRemoteFile(
        at path: String,
        over sftp: SSHSFTPClient
    ) async {
        let cleanup = Task {
            try? await sftp.removeFile(at: path, timeout: .seconds(2))
        }
        await cleanup.value
    }

#if DEBUG
    private func signalStagingPhaseForTesting(_ phase: AttachmentStagingPhaseForTesting) async {
        guard let hold = stagingPhaseHoldsForTesting.removeValue(forKey: phase) else { return }
        await hold()
    }

    func delayNextNotificationSFTPWriteForTesting(_ delay: Duration) async {
        await connection.delayNextSFTPWriteForTesting(delay)
    }

    func holdNextOutboundWriteParkForTesting(
        _ hold: @escaping @Sendable () async -> Void
    ) async {
        await connection.holdNextOutboundWriteParkForTesting(hold)
    }

    func holdStagingPhaseForTesting(
        _ phase: AttachmentStagingPhaseForTesting,
        _ hold: @escaping @Sendable () async -> Void
    ) {
        stagingPhaseHoldsForTesting[phase] = hold
    }

    func notificationFileStateForTesting() async -> WaycarSSHNotificationFileStateForTesting {
        let admission = await channelAdmission.snapshot()
        return WaycarSSHNotificationFileStateForTesting(
            activeClientCount: notificationFileClients.count,
            temporaryPaths: notificationTemporaryPaths.values.sorted(),
            ordinarySessionCount: admission.ordinarySession,
            connectionChannelCount: admission.connection,
            writeIsDelayed: await connection.isSFTPWriteDelayedForTesting)
    }

    func readRemoteFileForTesting(at path: String) async throws -> Data? {
        try await channelAdmission.withChannel(.ordinarySession) {
            let sftp = try await self.connection.openSFTP(timeout: self.requestTimeout)
            do {
                let contents = try await sftp.readFileIfPresent(
                    at: path,
                    timeout: self.requestTimeout)
                try await sftp.close(timeout: .seconds(2))
                return contents
            } catch {
                try? await sftp.close(timeout: .seconds(2))
                throw error
            }
        }
    }
#endif
}
