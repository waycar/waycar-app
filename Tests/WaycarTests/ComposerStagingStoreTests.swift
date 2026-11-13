import Foundation
import Testing

@testable import Waycar

@MainActor
@Suite("Composer staging store")
struct ComposerStagingStoreTests {
    @Test(arguments: StagingTestMedium.allCases)
    func successfulUploadPublishesCompletionAndDiscardsPreparation(
        _ medium: StagingTestMedium
    ) async throws {
        let fixture = try await makeFixture(medium)
        defer { fixture.cleanup() }

        let id = try #require(fixture.begin(medium))
        try await waitUntil("staging should complete") { !fixture.events.events.isEmpty }

        #expect(fixture.store.state == .idle)
        #expect(fixture.store.activeOperationID == nil)
        #expect(fixture.events.events == [.completed(id: id, path: remotePath(for: medium))])
        #expect(!fixture.preparedFileExists(for: medium))
        #expect(await fixture.stageRequestCount(for: medium) == 1)
        #expect(await fixture.prepareCount(for: medium) == 1)
    }

    @Test(arguments: StagingTestMedium.allCases)
    func beginWhileBusyReturnsNilAndStartsNothing(_ medium: StagingTestMedium) async throws {
        let stageGate = ScriptedTransportCallGate()
        let fixture = try await makeFixture(medium, gates: stageGates(stageGate, for: medium))
        defer { fixture.cleanup() }

        let id = try #require(fixture.begin(medium))
        try await waitUntil("upload should reach the gate") { await stageGate.entryCount == 1 }

        #expect(fixture.begin(medium) == nil)
        #expect(fixture.begin(medium == .image ? .file : .image) == nil)
        #expect(fixture.store.activeOperationID == id)
        #expect(await fixture.prepareCount(for: .image) == (medium == .image ? 1 : 0))
        #expect(await fixture.prepareCount(for: .file) == (medium == .file ? 1 : 0))

        await stageGate.open()
        try await waitUntil("staging should complete") { !fixture.events.events.isEmpty }
        #expect(fixture.events.events == [.completed(id: id, path: remotePath(for: medium))])
        #expect(await fixture.stageRequestCount(for: medium) == 1)
    }

    @Test func operationIDsAreDistinctAcrossOperations() async throws {
        let fixture = try await makeFixture(.image)
        defer { fixture.cleanup() }

        let first = try #require(fixture.begin(.image))
        try await waitUntil("first should complete") { fixture.events.events.count == 1 }
        let second = try #require(fixture.begin(.file))
        try await waitUntil("second should complete") { fixture.events.events.count == 2 }

        #expect(first != second)
        #expect(
            fixture.events.events == [
                .completed(id: first, path: remotePath(for: .image)),
                .completed(id: second, path: remotePath(for: .file)),
            ])
    }

    @Test(arguments: StagingTestMedium.allCases)
    func activeOperationIDTracksPreparingAndUploading(_ medium: StagingTestMedium) async throws {
        let preparationGate = ScriptedTransportCallGate()
        let stageGate = ScriptedTransportCallGate()
        var gates = preparationGates(preparationGate, for: medium)
        switch medium {
        case .image: gates.imageStage = stageGate
        case .file: gates.fileStage = stageGate
        }
        let fixture = try await makeFixture(medium, gates: gates)
        defer { fixture.cleanup() }
        #expect(fixture.store.activeOperationID == nil)

        let id = try #require(fixture.begin(medium))
        #expect(fixture.store.state == .preparing(medium.storeMedium))
        #expect(fixture.store.activeOperationID == id)

        await preparationGate.open()
        try await waitUntil("upload should reach the gate") { await stageGate.entryCount == 1 }
        #expect(fixture.store.state.isUploading)
        #expect(fixture.store.activeOperationID == id)

        await stageGate.open()
        try await waitUntil("staging should complete") { fixture.store.state == .idle }
        #expect(fixture.store.activeOperationID == nil)
    }

    @Test(arguments: StagingTestMedium.allCases)
    func cancelDuringUploadPublishesCancelledAndDiscardsPreparation(
        _ medium: StagingTestMedium
    ) async throws {
        let stageGate = ScriptedTransportCallGate()
        let fixture = try await makeFixture(medium, gates: stageGates(stageGate, for: medium))
        defer { fixture.cleanup() }

        let id = try #require(fixture.begin(medium))
        try await waitUntil("upload should reach the gate") { await stageGate.entryCount == 1 }
        fixture.store.cancel(operationID: id)
        await stageGate.open()
        try await waitUntil("cancellation should publish") { !fixture.events.events.isEmpty }

        #expect(fixture.store.state == .idle)
        #expect(fixture.events.events == [.cancelled(id: id)])
        #expect(!fixture.preparedFileExists(for: medium))
        #expect(!fixture.store.retry(operationID: id))
    }

    @Test(arguments: StagingTestMedium.allCases)
    func cancelDuringPreparationDiscardsUnclaimedFileAndNeverUploads(
        _ medium: StagingTestMedium
    ) async throws {
        let preparationGate = ScriptedTransportCallGate()
        let fixture = try await makeFixture(
            medium, gates: preparationGates(preparationGate, for: medium))
        defer { fixture.cleanup() }

        let id = try #require(fixture.begin(medium))
        try await waitUntil("preparation should reach the gate") {
            await preparationGate.entryCount == 1
        }
        fixture.store.cancel(operationID: id)
        await preparationGate.open()
        try await waitUntil("cancellation should publish") { !fixture.events.events.isEmpty }

        #expect(fixture.store.state == .idle)
        #expect(fixture.events.events == [.cancelled(id: id)])
        #expect(!fixture.preparedFileExists(for: medium))
        #expect(await fixture.stageRequestCount(for: medium) == 0)
    }

    @Test(arguments: StagingTestMedium.allCases)
    func cancelWithStaleIDIsIgnored(_ medium: StagingTestMedium) async throws {
        let stageGate = ScriptedTransportCallGate()
        let fixture = try await makeFixture(medium, gates: stageGates(stageGate, for: medium))
        defer { fixture.cleanup() }

        let id = try #require(fixture.begin(medium))
        try await waitUntil("upload should reach the gate") { await stageGate.entryCount == 1 }
        fixture.store.cancel(operationID: id &+ 1)
        fixture.store.cancel(operationID: id &- 1)
        #expect(fixture.store.activeOperationID == id)

        await stageGate.open()
        try await waitUntil("staging should complete") { !fixture.events.events.isEmpty }
        #expect(fixture.events.events == [.completed(id: id, path: remotePath(for: medium))])
        #expect(fixture.store.state == .idle)
    }

    @Test(arguments: StagingTestMedium.allCases)
    func retryableFailureRetainsPreparationAndRetryReusesItUnderTheSameID(
        _ medium: StagingTestMedium
    ) async throws {
        let retriedPath = remotePath(for: medium, stem: "retried")
        let fixture = try await makeFixture(
            medium,
            stagePlans: [.failure(.transferFailed), .success(retriedPath)])
        defer { fixture.cleanup() }

        let id = try #require(fixture.begin(medium))
        try await waitUntil("staging should fail") { fixture.store.state.isFailed }

        let failure = try #require(fixture.store.state.failure)
        let message = "\(medium.displayName) upload failed."
        #expect(
            failure
                == ComposerStagingStore.Failure(
                    medium: medium.storeMedium, message: message, isRetryable: true))
        #expect(fixture.preparedFileExists(for: medium))
        #expect(fixture.store.activeOperationID == nil)
        #expect(fixture.events.events == [.failed(id: id, message: message, retryable: true)])

        #expect(!fixture.store.retry(operationID: id &+ 1))
        #expect(fixture.store.state.isFailed)

        #expect(fixture.store.retry(operationID: id))
        #expect(fixture.store.activeOperationID == id)
        try await waitUntil("retry should complete") { fixture.events.events.count == 2 }

        #expect(
            fixture.events.events == [
                .failed(id: id, message: message, retryable: true),
                .completed(id: id, path: retriedPath),
            ])
        #expect(fixture.store.state == .idle)
        #expect(await fixture.stageRequestCount(for: medium) == 2)
        #expect(await fixture.prepareCount(for: medium) == 1)
        #expect(!fixture.preparedFileExists(for: medium))
        #expect(!fixture.store.retry(operationID: id))
    }

    @Test(arguments: StagingTestMedium.allCases)
    func nonRetryableFailureDiscardsPreparationAndRefusesRetry(
        _ medium: StagingTestMedium
    ) async throws {
        let fixture = try await makeFixture(medium, stagePlans: [.failure(.sftpUnavailable)])
        defer { fixture.cleanup() }

        let id = try #require(fixture.begin(medium))
        try await waitUntil("staging should fail") { fixture.store.state.isFailed }

        let message = "SFTP is unavailable on this Host. Enable its SSH SFTP subsystem."
        #expect(
            fixture.store.state
                == .failed(
                    ComposerStagingStore.Failure(
                        medium: medium.storeMedium, message: message, isRetryable: false)))
        #expect(!fixture.preparedFileExists(for: medium))
        #expect(fixture.events.events == [.failed(id: id, message: message, retryable: false)])

        #expect(!fixture.store.retry(operationID: id))
        #expect(fixture.store.state.isFailed)
        #expect(await fixture.stageRequestCount(for: medium) == 1)
    }

    @Test(arguments: StagingTestMedium.allCases)
    func dismissDiscardsRetainedFailureSilently(_ medium: StagingTestMedium) async throws {
        let fixture = try await makeFixture(medium, stagePlans: [.failure(.transferFailed)])
        defer { fixture.cleanup() }

        let id = try #require(fixture.begin(medium))
        try await waitUntil("staging should fail") { fixture.store.state.isFailed }
        #expect(fixture.preparedFileExists(for: medium))
        let eventsBeforeDismiss = fixture.events.events

        fixture.store.dismiss(operationID: id &+ 1)
        #expect(fixture.store.state.isFailed)
        #expect(fixture.preparedFileExists(for: medium))

        fixture.store.dismiss(operationID: id)
        #expect(fixture.store.state == .idle)
        #expect(!fixture.preparedFileExists(for: medium))
        #expect(fixture.events.events == eventsBeforeDismiss)
        #expect(!fixture.store.retry(operationID: id))
    }

    @Test(arguments: StagingTestMedium.allCases)
    func dismissIsIgnoredWhileBusy(_ medium: StagingTestMedium) async throws {
        let stageGate = ScriptedTransportCallGate()
        let fixture = try await makeFixture(medium, gates: stageGates(stageGate, for: medium))
        defer { fixture.cleanup() }

        let id = try #require(fixture.begin(medium))
        try await waitUntil("upload should reach the gate") { await stageGate.entryCount == 1 }
        fixture.store.dismiss(operationID: id)
        #expect(fixture.store.activeOperationID == id)

        await stageGate.open()
        try await waitUntil("staging should complete") { !fixture.events.events.isEmpty }
        #expect(fixture.events.events == [.completed(id: id, path: remotePath(for: medium))])
    }

    @Test(arguments: StagingTestMedium.allCases)
    func backgroundDuringUploadRetainsPreparationAsRetryable(
        _ medium: StagingTestMedium
    ) async throws {
        let retriedPath = remotePath(for: medium, stem: "retried")
        let stageGate = ScriptedTransportCallGate()
        let fixture = try await makeFixture(
            medium,
            // The interrupted call throws at `Task.checkCancellation()` before
            // consuming a scripted outcome, so the retry's call takes the first one.
            stagePlans: [.success(retriedPath)],
            gates: stageGates(stageGate, for: medium))
        defer { fixture.cleanup() }

        let id = try #require(fixture.begin(medium))
        try await waitUntil("upload should reach the gate") { await stageGate.entryCount == 1 }
        fixture.store.didEnterBackground()
        await stageGate.open()
        try await waitUntil("background interruption should surface") {
            fixture.store.state.isBackgroundInterrupted
        }

        let message = "\(medium.displayName) upload paused when Waycar moved to the background."
        #expect(
            fixture.store.state
                == .backgroundInterrupted(
                    ComposerStagingStore.Failure(
                        medium: medium.storeMedium, message: message, isRetryable: true)))
        #expect(fixture.preparedFileExists(for: medium))
        #expect(fixture.store.activeOperationID == nil)
        #expect(fixture.events.events == [.failed(id: id, message: message, retryable: true)])

        #expect(fixture.store.retry(operationID: id))
        try await waitUntil("explicit retry should complete") {
            fixture.events.events.count == 2
        }
        #expect(fixture.events.events.last == .completed(id: id, path: retriedPath))
        #expect(await fixture.prepareCount(for: medium) == 1)
        #expect(await fixture.stageRequestCount(for: medium) == 2)
    }

    @Test(arguments: StagingTestMedium.allCases)
    func backgroundDuringPreparationPublishesRetryableFailure(
        _ medium: StagingTestMedium
    ) async throws {
        let preparationGate = ScriptedTransportCallGate()
        let fixture = try await makeFixture(
            medium, gates: preparationGates(preparationGate, for: medium))
        defer { fixture.cleanup() }

        let id = try #require(fixture.begin(medium))
        try await waitUntil("preparation should reach the gate") {
            await preparationGate.entryCount == 1
        }
        fixture.store.didEnterBackground()
        await preparationGate.open()
        try await waitUntil("background interruption should surface") {
            fixture.store.state.isBackgroundInterrupted
        }

        let message = "\(medium.displayName) upload paused when Waycar moved to the background."
        #expect(fixture.store.state.failure?.isRetryable == true)
        #expect(fixture.events.events == [.failed(id: id, message: message, retryable: true)])
        #expect(await fixture.stageRequestCount(for: medium) == 0)
        #expect(!fixture.preparedFileExists(for: medium))
    }

    @Test func didEnterBackgroundWhileIdleOrFailedChangesNothing() async throws {
        let fixture = try await makeFixture(.image, stagePlans: [.failure(.sftpUnavailable)])
        defer { fixture.cleanup() }

        fixture.store.didEnterBackground()
        #expect(fixture.store.state == .idle)

        fixture.begin(.image)
        try await waitUntil("staging should fail") { fixture.store.state.isFailed }
        let failedState = fixture.store.state
        fixture.store.didEnterBackground()
        #expect(fixture.store.state == failedState)
        #expect(fixture.events.events.count == 1)
    }

    @Test(arguments: StagingTestMedium.allCases)
    func leaveWhileBusyPublishesCancelledAndIgnoresLateResults(
        _ medium: StagingTestMedium
    ) async throws {
        let stager = NonCooperativeStager(path: remotePath(for: medium))
        let fixture = try await makeFixture(medium, nonCooperativeStager: stager)
        defer { fixture.cleanup() }

        let id = try #require(fixture.begin(medium))
        try await waitUntil("upload should reach the non-cooperative stager") {
            await stager.entryCount == 1
        }
        let leave = Task { await fixture.store.leave() }
        try await waitUntil("leave should cancel the in-flight operation") {
            await stager.hasObservedCancellation()
        }

        await stager.releaseLateProgress()
        try await waitUntil("the stale operation should report late progress") {
            await stager.lateProgressCount == 1
        }
        #expect(
            fixture.store.state
                == .uploading(
                    medium.storeMedium,
                    AttachmentStageProgress(
                        transferredBytes: 0,
                        totalBytes: fixture.preparedByteCount(for: medium))))
        #expect(fixture.events.events.isEmpty)

        await stager.releaseLateSuccess()
        await leave.value

        #expect(await stager.successCount == 1)
        #expect(fixture.store.state == .idle)
        #expect(fixture.events.events == [.cancelled(id: id)])
        #expect(!fixture.preparedFileExists(for: medium))

        await fixture.store.leave()
        #expect(fixture.store.state == .idle)
        #expect(fixture.events.events == [.cancelled(id: id)])
    }

    @Test(arguments: StagingTestMedium.allCases)
    func leaveWithRetainedFailureDiscardsItSilently(_ medium: StagingTestMedium) async throws {
        let fixture = try await makeFixture(medium, stagePlans: [.failure(.transferFailed)])
        defer { fixture.cleanup() }

        let id = try #require(fixture.begin(medium))
        try await waitUntil("staging should fail") { fixture.store.state.isFailed }
        let eventsBeforeLeave = fixture.events.events

        await fixture.store.leave()

        #expect(fixture.store.state == .idle)
        #expect(!fixture.preparedFileExists(for: medium))
        #expect(fixture.events.events == eventsBeforeLeave)
        #expect(!fixture.store.retry(operationID: id))
    }

    @Test func storeAcceptsNewWorkAfterLeave() async throws {
        let fixture = try await makeFixture(.image)
        defer { fixture.cleanup() }

        await fixture.store.leave()
        let id = try #require(fixture.begin(.image))
        try await waitUntil("staging should complete") { !fixture.events.events.isEmpty }
        #expect(fixture.events.events == [.completed(id: id, path: remotePath(for: .image))])
    }

    @Test(arguments: StagingTestMedium.allCases)
    func beginAfterRetainedFailureDiscardsItSilently(_ medium: StagingTestMedium) async throws {
        let other: StagingTestMedium = medium == .image ? .file : .image
        let nextGate = ScriptedTransportCallGate()
        let fixture = try await makeFixture(
            medium,
            stagePlans: [.failure(.transferFailed)],
            gates: preparationGates(nextGate, for: other))
        defer { fixture.cleanup() }

        let failedID = try #require(fixture.begin(medium))
        try await waitUntil("staging should fail") { fixture.store.state.isFailed }
        #expect(fixture.preparedFileExists(for: medium))
        let eventsAfterFailure = fixture.events.events

        let nextID = try #require(fixture.begin(other))
        #expect(nextID != failedID)
        #expect(fixture.store.state == .preparing(other.storeMedium))
        #expect(!fixture.preparedFileExists(for: medium))
        #expect(fixture.events.events == eventsAfterFailure)
        #expect(!fixture.store.retry(operationID: failedID))

        await nextGate.open()
        try await waitUntil("the replacement should complete") {
            fixture.events.events.count == 2
        }
        #expect(fixture.events.events.last == .completed(id: nextID, path: remotePath(for: other)))
    }

    @Test(arguments: [
        (ImagePreparationError.selectionUnavailable, "The selected photo is no longer available."),
        (ImagePreparationError.sourceTooLarge, "The selected image is too large to decode safely."),
        (ImagePreparationError.invalidImage, "The selected item is not a readable image."),
        (
            ImagePreparationError.unableToProduceBoundedOutput,
            "The image could not be reduced below the 16 MiB upload limit."
        ),
        (
            ImagePreparationError.localStorageFailed,
            "Waycar couldn't prepare the image in protected local storage."
        ),
    ])
    func imagePreparationFailuresMapToNonRetryableMessages(
        _ error: ImagePreparationError,
        _ message: String
    ) async throws {
        let fixture = try await makeFixture(.image, imagePreparationError: error)
        defer { fixture.cleanup() }

        let id = try #require(fixture.begin(.image))
        try await waitUntil("preparation should fail") { fixture.store.state.isFailed }

        #expect(
            fixture.store.state
                == .failed(
                    ComposerStagingStore.Failure(
                        medium: .image, message: message, isRetryable: false)))
        #expect(fixture.events.events == [.failed(id: id, message: message, retryable: false)])
        #expect(!fixture.store.retry(operationID: id))
        #expect(await fixture.stageRequestCount(for: .image) == 0)
    }

    @Test(arguments: [
        (FilePreparationError.selectionUnavailable, "The selected file is no longer available."),
        (FilePreparationError.sourceTooLarge, "The selected file exceeds the 64 MiB upload limit."),
        (
            FilePreparationError.localStorageFailed,
            "Waycar couldn't prepare the file in protected local storage."
        ),
    ])
    func filePreparationFailuresMapToNonRetryableMessages(
        _ error: FilePreparationError,
        _ message: String
    ) async throws {
        let fixture = try await makeFixture(.file, filePreparationError: error)
        defer { fixture.cleanup() }

        let id = try #require(fixture.begin(.file))
        try await waitUntil("preparation should fail") { fixture.store.state.isFailed }

        #expect(
            fixture.store.state
                == .failed(
                    ComposerStagingStore.Failure(
                        medium: .file, message: message, isRetryable: false)))
        #expect(fixture.events.events == [.failed(id: id, message: message, retryable: false)])
        #expect(!fixture.store.retry(operationID: id))
        #expect(await fixture.stageRequestCount(for: .file) == 0)
    }

    @Test(arguments: StagingTestMedium.allCases)
    func nonRetryableStagingErrorsUseGenericUploadMessage(
        _ medium: StagingTestMedium
    ) async throws {
        let fixture = try await makeFixture(
            medium, stagePlans: [.failure(.permissionEnforcementFailed)])
        defer { fixture.cleanup() }

        let id = try #require(fixture.begin(medium))
        try await waitUntil("staging should fail") { fixture.store.state.isFailed }

        let message = "\(medium.displayName) upload failed."
        #expect(fixture.events.events == [.failed(id: id, message: message, retryable: false)])
        #expect(!fixture.preparedFileExists(for: medium))
    }

    private func makeFixture(
        _ selectedMedium: StagingTestMedium,
        stagePlans: [StagingPlan]? = nil,
        gates: StagingGates = StagingGates(),
        nonCooperativeStager: NonCooperativeStager? = nil,
        imagePreparationError: (any Error & Sendable)? = nil,
        filePreparationError: (any Error & Sendable)? = nil
    ) async throws -> StagingFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("composer-staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let imageURL = directory.appendingPathComponent("prepared.jpg")
        let fileURL = directory.appendingPathComponent("prepared.txt")
        try Data(repeating: 0x41, count: 128).write(to: imageURL)
        try Data(repeating: 0x42, count: 256).write(to: fileURL)
        let image = PreparedImage(
            fileURL: imageURL,
            format: .jpeg,
            pixelWidth: 16,
            pixelHeight: 16,
            byteCount: 128)
        let file = PreparedFile(fileURL: fileURL, fileExtension: "txt", byteCount: 256)
        let transport = ScriptedTransport()
        let plans = stagePlans ?? [.success(remotePath(for: selectedMedium))]
        let imagePlans =
            selectedMedium == .image
            ? plans : [.success(remotePath(for: .image))]
        let filePlans =
            selectedMedium == .file
            ? plans : [.success(remotePath(for: .file))]
        try await transport.configureImageStaging(
            outcomes: imagePlans.map(Self.imageOutcome),
            gate: gates.imageStage)
        try await transport.configureFileStaging(
            outcomes: filePlans.map(Self.fileOutcome),
            gate: gates.fileStage)
        let imagePreparer = ScriptedStagingImagePreparer(
            prepared: image,
            gate: gates.imagePreparation,
            error: imagePreparationError)
        let filePreparer = ScriptedStagingFilePreparer(
            prepared: file,
            gate: gates.filePreparation,
            error: filePreparationError)
        let store = ComposerStagingStore(
            imagePreparer: imagePreparer,
            filePreparer: filePreparer,
            stageImage: { image, reporter in
                if selectedMedium == .image, let nonCooperativeStager {
                    return try await nonCooperativeStager.stageImage(
                        image,
                        reporter: reporter)
                }
                return try await transport.stageImage(image) { progress in
                    await reporter.report(progress)
                }
            },
            stageFile: { file, reporter in
                if selectedMedium == .file, let nonCooperativeStager {
                    return try await nonCooperativeStager.stageFile(
                        file,
                        reporter: reporter)
                }
                return try await transport.stageFile(file) { progress in
                    await reporter.report(progress)
                }
            })
        let events = StagingEventRecorder()
        store.onOperationEvent = { events.record($0) }
        return StagingFixture(
            store: store,
            transport: transport,
            imagePreparer: imagePreparer,
            filePreparer: filePreparer,
            events: events,
            directory: directory,
            preparedImage: image,
            preparedFile: file)
    }

    private static func imageOutcome(
        _ plan: StagingPlan
    ) throws -> Result<StagedImage, AttachmentStagingError> {
        switch plan {
        case .success(let path): .success(try StagedImage(path: path))
        case .failure(let error): .failure(error)
        }
    }

    private static func fileOutcome(
        _ plan: StagingPlan
    ) throws -> Result<StagedFile, AttachmentStagingError> {
        switch plan {
        case .success(let path): .success(try StagedFile(path: path))
        case .failure(let error): .failure(error)
        }
    }

    private func remotePath(
        for medium: StagingTestMedium,
        stem: String = "source"
    ) -> String {
        switch medium {
        case .image: "/tmp/staged/\(stem).jpg"
        case .file: "/tmp/staged/\(stem).txt"
        }
    }

    private func stageGates(
        _ gate: ScriptedTransportCallGate,
        for medium: StagingTestMedium
    ) -> StagingGates {
        switch medium {
        case .image: StagingGates(imageStage: gate)
        case .file: StagingGates(fileStage: gate)
        }
    }

    private func preparationGates(
        _ gate: ScriptedTransportCallGate,
        for medium: StagingTestMedium
    ) -> StagingGates {
        switch medium {
        case .image: StagingGates(imagePreparation: gate)
        case .file: StagingGates(filePreparation: gate)
        }
    }
}

enum StagingTestMedium: CaseIterable, Sendable {
    case image
    case file

    var storeMedium: ComposerStagingStore.Medium {
        switch self {
        case .image: .image
        case .file: .file
        }
    }

    var displayName: String {
        switch self {
        case .image: "Image"
        case .file: "File"
        }
    }
}

private enum StagingPlan: Sendable {
    case success(String)
    case failure(AttachmentStagingError)
}

private struct StagingGates {
    var imagePreparation: ScriptedTransportCallGate?
    var filePreparation: ScriptedTransportCallGate?
    var imageStage: ScriptedTransportCallGate?
    var fileStage: ScriptedTransportCallGate?

    init(
        imagePreparation: ScriptedTransportCallGate? = nil,
        filePreparation: ScriptedTransportCallGate? = nil,
        imageStage: ScriptedTransportCallGate? = nil,
        fileStage: ScriptedTransportCallGate? = nil
    ) {
        self.imagePreparation = imagePreparation
        self.filePreparation = filePreparation
        self.imageStage = imageStage
        self.fileStage = fileStage
    }
}

@MainActor
private struct StagingFixture {
    let store: ComposerStagingStore
    let transport: ScriptedTransport
    let imagePreparer: ScriptedStagingImagePreparer
    let filePreparer: ScriptedStagingFilePreparer
    let events: StagingEventRecorder
    let directory: URL
    let preparedImage: PreparedImage
    let preparedFile: PreparedFile

    @discardableResult
    func begin(_ medium: StagingTestMedium) -> UInt64? {
        switch medium {
        case .image:
            store.begin(.photo(DataImageSelection(data: Data([0x01]))))
        case .file:
            store.begin(.file(URL(fileURLWithPath: "/provider/report.txt")))
        }
    }

    func preparedFileExists(for medium: StagingTestMedium) -> Bool {
        let url = medium == .image ? preparedImage.fileURL : preparedFile.fileURL
        return FileManager.default.fileExists(atPath: url.path)
    }

    func preparedByteCount(for medium: StagingTestMedium) -> Int64 {
        medium == .image ? preparedImage.byteCount : preparedFile.byteCount
    }

    func stageRequestCount(for medium: StagingTestMedium) async -> Int {
        switch medium {
        case .image: await transport.stageRequests.count
        case .file: await transport.fileStageRequests.count
        }
    }

    func prepareCount(for medium: StagingTestMedium) async -> Int {
        switch medium {
        case .image: await imagePreparer.callCount
        case .file: await filePreparer.callCount
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private actor ScriptedStagingImagePreparer: ImagePreparing {
    let prepared: PreparedImage
    let gate: ScriptedTransportCallGate?
    let error: (any Error & Sendable)?
    private(set) var callCount = 0

    init(prepared: PreparedImage, gate: ScriptedTransportCallGate?, error: (any Error & Sendable)?) {
        self.prepared = prepared
        self.gate = gate
        self.error = error
    }

    func prepare(_ selection: any ImageSelection) async throws -> PreparedImage {
        callCount += 1
        await gate?.waitUntilOpen()
        if let error { throw error }
        return prepared
    }
}

private actor ScriptedStagingFilePreparer: FilePreparing {
    let prepared: PreparedFile
    let gate: ScriptedTransportCallGate?
    let error: (any Error & Sendable)?
    private(set) var callCount = 0

    init(prepared: PreparedFile, gate: ScriptedTransportCallGate?, error: (any Error & Sendable)?) {
        self.prepared = prepared
        self.gate = gate
        self.error = error
    }

    func prepare(_ sourceURL: URL) async throws -> PreparedFile {
        callCount += 1
        await gate?.waitUntilOpen()
        if let error { throw error }
        return prepared
    }
}

private actor NonCooperativeStager {
    private let path: String
    private let cancellation = StagingCancellationRecorder()
    private let lateProgressGate = ScriptedTransportCallGate()
    private let lateSuccessGate = ScriptedTransportCallGate()
    private(set) var entryCount = 0
    private(set) var lateProgressCount = 0
    private(set) var successCount = 0

    init(path: String) {
        self.path = path
    }

    func stageImage(
        _ image: PreparedImage,
        reporter: AttachmentStageProgressReporter
    ) async throws -> StagedImage {
        try await stage(
            byteCount: image.byteCount,
            reporter: reporter,
            makeResult: { try StagedImage(path: $0) })
    }

    func stageFile(
        _ file: PreparedFile,
        reporter: AttachmentStageProgressReporter
    ) async throws -> StagedFile {
        try await stage(
            byteCount: file.byteCount,
            reporter: reporter,
            makeResult: { try StagedFile(path: $0) })
    }

    func hasObservedCancellation() async -> Bool {
        await cancellation.observed
    }

    func releaseLateProgress() async {
        await lateProgressGate.open()
    }

    func releaseLateSuccess() async {
        await lateSuccessGate.open()
    }

    private func stage<Result: Sendable>(
        byteCount: Int64,
        reporter: AttachmentStageProgressReporter,
        makeResult: (String) throws -> Result
    ) async throws -> Result {
        entryCount += 1
        await withTaskCancellationHandler {
            await lateProgressGate.waitUntilOpen()
        } onCancel: { [cancellation] in
            Task { await cancellation.record() }
        }
        await reporter.report(
            AttachmentStageProgress(
                transferredBytes: byteCount,
                totalBytes: byteCount))
        lateProgressCount += 1
        await lateSuccessGate.waitUntilOpen()
        successCount += 1
        return try makeResult(path)
    }
}

private actor StagingCancellationRecorder {
    private(set) var observed = false

    func record() {
        observed = true
    }
}

@MainActor
private final class StagingEventRecorder {
    private(set) var events: [ComposerStagingStore.OperationEvent] = []

    func record(_ event: ComposerStagingStore.OperationEvent) {
        events.append(event)
    }
}

extension ComposerStagingStore.State {
    fileprivate var isFailed: Bool {
        if case .failed = self { true } else { false }
    }

    fileprivate var isUploading: Bool {
        if case .uploading = self { true } else { false }
    }

    fileprivate var isBackgroundInterrupted: Bool {
        if case .backgroundInterrupted = self { true } else { false }
    }

    fileprivate var failure: ComposerStagingStore.Failure? {
        switch self {
        case .failed(let failure), .backgroundInterrupted(let failure): failure
        case .idle, .preparing, .uploading: nil
        }
    }
}
