import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Waycar

@MainActor
@Suite("Composer tray")
struct ComposerTrayTests {
    private static let stoppedMessage = "Upload stopped when you left this screen."

    private static func capacityNotice(_ outcome: String) -> String {
        "Only 10 images or files fit in one message. \(outcome)"
    }

    // MARK: Capacity

    @Test func addKeepsOrderAndDropsSourcesPastCapacity() {
        let tray = ComposerTray(clipboard: RecordingTrayClipboard())
        let sources = (0..<11).map { index in
            index.isMultiple(of: 2) ? imageSource(UInt8(index)) : fileSource("f\(index).txt")
        }
        let expectedKinds: [ComposerTray.Item.Kind] = (0..<10).map { index in
            index.isMultiple(of: 2) ? .image : .file(name: "f\(index).txt")
        }

        #expect(tray.add(sources) == 10)

        #expect(tray.items.map(\.kind) == expectedKinds)
        #expect(tray.items.allSatisfy { $0.status == .queued })
        #expect(tray.remainingCapacity == 0)
        #expect(!tray.canAdd)
        #expect(tray.notice == Self.capacityNotice("1 wasn't added."))

        #expect(tray.add([fileSource("late.txt"), fileSource("later.txt")]) == 0)
        #expect(tray.items.map(\.kind) == expectedKinds)
        #expect(tray.notice == Self.capacityNotice("2 weren't added."))

        tray.remove(tray.items[3].id)
        #expect(tray.remainingCapacity == 1)
        #expect(tray.canAdd)
        #expect(tray.notice == nil)
    }

    @Test func addAcceptsOnlyTheRemainingRoom() {
        let tray = ComposerTray(clipboard: RecordingTrayClipboard())
        #expect(tray.add((0..<8).map { fileSource("f\($0).txt") }) == 8)
        #expect(tray.notice == nil)
        #expect(tray.remainingCapacity == 2)
        #expect(tray.canAdd)

        #expect(tray.add((8..<12).map { fileSource("f\($0).txt") }) == 2)

        #expect(
            tray.items.map(\.kind)
                == (0..<10).map { ComposerTray.Item.Kind.file(name: "f\($0).txt") })
        #expect(tray.remainingCapacity == 0)
        #expect(!tray.canAdd)
        #expect(tray.notice == Self.capacityNotice("2 weren't added."))
    }

    @Test func addThatTakesEverythingClearsTheCapacityNotice() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let sink = PathSinkRecorder()
        fixture.tray.completedPathSink = { sink.paths.append($0) }
        #expect(fixture.tray.add((0..<11).map { fileSource("f\($0).txt") }) == 10)
        #expect(fixture.tray.notice == Self.capacityNotice("1 wasn't added."))

        // A shell's completed item leaves the tray: room without a remove.
        try await complete(fixture, call: 0, path: "/tmp/staged/f0.txt")
        try await waitUntil("the first path should be inserted") {
            sink.paths == ["/tmp/staged/f0.txt "]
        }
        #expect(fixture.tray.remainingCapacity == 1)
        #expect(fixture.tray.notice == Self.capacityNotice("1 wasn't added."))

        #expect(fixture.tray.add([fileSource("late.txt")]) == 1)

        #expect(fixture.tray.notice == nil)
        #expect(fixture.tray.items.last?.kind == .file(name: "late.txt"))
        await fixture.staging.leave()
    }

    @Test func takingReadyItemsClearsTheCapacityNotice() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        #expect(fixture.tray.add((0..<12).map { fileSource("f\($0).txt") }) == 10)
        #expect(fixture.tray.notice == Self.capacityNotice("2 weren't added."))
        try await complete(fixture, call: 0, path: "/tmp/staged/f0.txt")
        try await waitUntil("the first item should turn ready") {
            fixture.tray.readyPaths == ["/tmp/staged/f0.txt"]
        }
        #expect(fixture.tray.notice == Self.capacityNotice("2 weren't added."))

        #expect(fixture.tray.takeReadyItems().count == 1)

        #expect(fixture.tray.notice == nil)
        await fixture.staging.leave()
    }

    // MARK: Serial queue

    @Test func itemsStageOneAtATimeInAddOrder() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let ids = try add(fixture, [imageSource(1), fileSource("notes.txt"), imageSource(3)])

        try await waitForStageCall(fixture, 0)
        #expect(fixture.stagingItemCount == 1)
        #expect(fixture.status(ids[0])?.stagingOperationID != nil)
        #expect(fixture.status(ids[1]) == .queued)
        #expect(fixture.status(ids[2]) == .queued)
        #expect(await fixture.preparer.labels == ["image-1"])
        #expect(await fixture.stager.callCount == 1)

        try await complete(fixture, call: 0, path: "/tmp/staged/one.jpg")
        try await waitUntil("the first item should turn ready") {
            fixture.status(ids[0]) == .ready(path: "/tmp/staged/one.jpg")
        }
        #expect(fixture.status(ids[1])?.stagingOperationID != nil)
        #expect(fixture.status(ids[2]) == .queued)
        try await waitForStageCall(fixture, 1)
        #expect(fixture.stagingItemCount == 1)
        #expect(await fixture.stager.callCount == 2)

        try await complete(fixture, call: 1, path: "/tmp/staged/notes.txt")
        try await waitUntil("the second item should turn ready") {
            fixture.status(ids[1]) == .ready(path: "/tmp/staged/notes.txt")
        }
        #expect(fixture.status(ids[2])?.stagingOperationID != nil)

        try await complete(fixture, call: 2, path: "/tmp/staged/three.jpg")
        try await waitUntil("the third item should turn ready") {
            fixture.status(ids[2]) == .ready(path: "/tmp/staged/three.jpg")
        }

        #expect(
            fixture.tray.readyPaths
                == ["/tmp/staged/one.jpg", "/tmp/staged/notes.txt", "/tmp/staged/three.jpg"])
        #expect(await fixture.stager.calls.map(\.kind) == [.image, .file, .image])
        #expect(await fixture.preparer.labels == ["image-1", "notes.txt", "image-3"])
        #expect(!fixture.tray.blocksSend)
    }

    // MARK: Remove

    @Test func removingAQueuedItemSkipsItsUpload() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let ids = try add(fixture, [imageSource(1), imageSource(2), imageSource(3)])
        try await waitForStageCall(fixture, 0)

        fixture.tray.remove(ids[1])

        #expect(fixture.ids == [ids[0], ids[2]])
        #expect(fixture.status(ids[0])?.stagingOperationID != nil)
        try await complete(fixture, call: 0, path: "/tmp/staged/one.jpg")
        try await complete(fixture, call: 1, path: "/tmp/staged/three.jpg")
        try await waitUntil("the remaining items should turn ready") {
            fixture.tray.readyPaths == ["/tmp/staged/one.jpg", "/tmp/staged/three.jpg"]
        }
        #expect(await fixture.preparer.labels == ["image-1", "image-3"])
        #expect(await fixture.stager.cancelledCalls.isEmpty)
    }

    @Test func removingTheStagingItemCancelsItAndStartsTheNext() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let ids = try add(fixture, [imageSource(1), imageSource(2)])
        try await waitForStageCall(fixture, 0)
        let removedPreparedURL = try await preparedURL(fixture, call: 0)

        fixture.tray.remove(ids[0])

        #expect(fixture.ids == [ids[1]])
        try await waitForStageCall(fixture, 1)
        #expect(await fixture.stager.cancelledCalls == [0])
        #expect(!FileManager.default.fileExists(atPath: removedPreparedURL.path))
        #expect(fixture.status(ids[1])?.stagingOperationID != nil)
        #expect(await fixture.preparer.labels == ["image-1", "image-2"])

        try await complete(fixture, call: 1, path: "/tmp/staged/two.jpg")
        try await waitUntil("the next item should turn ready") {
            fixture.tray.readyPaths == ["/tmp/staged/two.jpg"]
        }
    }

    @Test func removingARetainedFailureDiscardsItsFileAndResumesTheQueue() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let ids = try add(fixture, [imageSource(1), imageSource(2)])
        try await fail(fixture, call: 0, with: .transferFailed)
        try await waitUntil("the first item should fail retryably") {
            fixture.status(ids[0]) == .failed(message: "Image upload failed.", isRetryable: true)
        }
        let retainedURL = try await preparedURL(fixture, call: 0)
        #expect(FileManager.default.fileExists(atPath: retainedURL.path))
        #expect(fixture.status(ids[1]) == .queued)

        fixture.tray.remove(ids[0])

        #expect(fixture.ids == [ids[1]])
        #expect(!FileManager.default.fileExists(atPath: retainedURL.path))
        #expect(fixture.status(ids[1])?.stagingOperationID != nil)
        try await complete(fixture, call: 1, path: "/tmp/staged/two.jpg")
        try await waitUntil("the next item should turn ready") {
            fixture.tray.readyPaths == ["/tmp/staged/two.jpg"]
        }
        #expect(await fixture.preparer.labels == ["image-1", "image-2"])
    }

    @Test func removingAReadyItemLeavesTheActiveUploadAlone() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let ids = try add(fixture, [imageSource(1), imageSource(2)])
        try await complete(fixture, call: 0, path: "/tmp/staged/one.jpg")
        try await waitUntil("the first item should turn ready") {
            fixture.status(ids[0]) == .ready(path: "/tmp/staged/one.jpg")
        }
        try await waitForStageCall(fixture, 1)
        let activeOperationID = try #require(fixture.staging.activeOperationID)

        fixture.tray.remove(ids[0])

        #expect(fixture.ids == [ids[1]])
        #expect(fixture.tray.readyPaths.isEmpty)
        #expect(fixture.staging.activeOperationID == activeOperationID)
        #expect(fixture.status(ids[1]) == .staging(operationID: activeOperationID))
        try await complete(fixture, call: 1, path: "/tmp/staged/two.jpg")
        try await waitUntil("the remaining item should turn ready") {
            fixture.tray.readyPaths == ["/tmp/staged/two.jpg"]
        }
        #expect(await fixture.stager.cancelledCalls.isEmpty)
        #expect(await fixture.stager.callCount == 2)
        #expect(await fixture.preparer.labels == ["image-1", "image-2"])
    }

    // MARK: Failures

    @Test func retryableFailurePausesTheQueueUntilRetried() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let ids = try add(fixture, [imageSource(1), imageSource(2), imageSource(3)])
        try await fail(fixture, call: 0, with: .transferFailed)
        try await waitUntil("the first item should fail retryably") {
            fixture.status(ids[0]) == .failed(message: "Image upload failed.", isRetryable: true)
        }
        #expect(fixture.status(ids[1]) == .queued)
        #expect(fixture.status(ids[2]) == .queued)
        #expect(fixture.stagingItemCount == 0)
        #expect(await fixture.stager.callCount == 1)

        fixture.tray.retry(ids[0])

        #expect(fixture.status(ids[0])?.stagingOperationID != nil)
        #expect(fixture.status(ids[1]) == .queued)
        try await complete(fixture, call: 1, path: "/tmp/staged/one.jpg")
        try await waitUntil("the retried item should turn ready") {
            fixture.status(ids[0]) == .ready(path: "/tmp/staged/one.jpg")
        }
        // The retained prepared file is re-uploaded, not prepared again.
        let firstUploadURL = try await preparedURL(fixture, call: 0)
        let reuploadedURL = try await preparedURL(fixture, call: 1)
        #expect(reuploadedURL == firstUploadURL)
        #expect(fixture.status(ids[1])?.stagingOperationID != nil)
        #expect(fixture.status(ids[2]) == .queued)

        try await complete(fixture, call: 2, path: "/tmp/staged/two.jpg")
        try await complete(fixture, call: 3, path: "/tmp/staged/three.jpg")
        try await waitUntil("every item should turn ready in add order") {
            fixture.tray.readyPaths
                == ["/tmp/staged/one.jpg", "/tmp/staged/two.jpg", "/tmp/staged/three.jpg"]
        }
        #expect(await fixture.preparer.labels == ["image-1", "image-2", "image-3"])
    }

    @Test func nonRetryableFailureLetsTheQueueContinue() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let ids = try add(fixture, [imageSource(1), fileSource("notes.txt")])
        let sftpMessage = "SFTP is unavailable on this Host. Enable its SSH SFTP subsystem."
        try await fail(fixture, call: 0, with: .sftpUnavailable)
        try await waitUntil("the first item should fail permanently") {
            fixture.status(ids[0]) == .failed(message: sftpMessage, isRetryable: false)
        }
        #expect(fixture.status(ids[1])?.stagingOperationID != nil)
        let discardedURL = try await preparedURL(fixture, call: 0)
        #expect(!FileManager.default.fileExists(atPath: discardedURL.path))

        try await complete(fixture, call: 1, path: "/tmp/staged/notes.txt")
        try await waitUntil("the next item should turn ready") {
            fixture.status(ids[1]) == .ready(path: "/tmp/staged/notes.txt")
        }
        #expect(fixture.status(ids[0]) == .failed(message: sftpMessage, isRetryable: false))
        #expect(fixture.tray.readyPaths == ["/tmp/staged/notes.txt"])
        #expect(fixture.tray.blocksSend)
    }

    // MARK: Teardown and rebinding

    @Test func teardownFailsTheInFlightItemAndRetryReprepares() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let ids = try add(fixture, [imageSource(1), imageSource(2), imageSource(3)])
        try await complete(fixture, call: 0, path: "/tmp/staged/one.jpg")
        try await waitUntil("the first item should turn ready") {
            fixture.status(ids[0]) == .ready(path: "/tmp/staged/one.jpg")
        }
        try await waitForStageCall(fixture, 1)
        let interruptedURL = try await preparedURL(fixture, call: 1)

        fixture.tray.suspendForTeardown(of: fixture.staging)
        await fixture.staging.leave()

        #expect(fixture.status(ids[0]) == .ready(path: "/tmp/staged/one.jpg"))
        #expect(fixture.status(ids[1]) == .failed(message: Self.stoppedMessage, isRetryable: true))
        #expect(fixture.status(ids[2]) == .queued)
        #expect(!FileManager.default.fileExists(atPath: interruptedURL.path))

        fixture.tray.resumeAfterRejoin(of: fixture.staging)

        #expect(fixture.status(ids[1]) == .failed(message: Self.stoppedMessage, isRetryable: true))
        #expect(fixture.status(ids[2]) == .queued)
        #expect(fixture.staging.state == .idle)
        #expect(await fixture.stager.callCount == 2)
        #expect(await fixture.preparer.labels == ["image-1", "image-2"])

        fixture.tray.retry(ids[1])

        #expect(fixture.status(ids[1])?.stagingOperationID != nil)
        #expect(fixture.status(ids[2]) == .queued)
        try await complete(fixture, call: 2, path: "/tmp/staged/two.jpg")
        try await waitUntil("the retried item should turn ready") {
            fixture.status(ids[1]) == .ready(path: "/tmp/staged/two.jpg")
        }
        try await complete(fixture, call: 3, path: "/tmp/staged/three.jpg")
        try await waitUntil("the queue should continue in add order") {
            fixture.tray.readyPaths
                == ["/tmp/staged/one.jpg", "/tmp/staged/two.jpg", "/tmp/staged/three.jpg"]
        }
        // The interrupted item was prepared again from its source.
        #expect(
            await fixture.preparer.labels == ["image-1", "image-2", "image-2", "image-3"])
    }

    @Test func retryWhileSuspendedKeepsTheItemFailedUntilRejoin() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let ids = try add(fixture, [imageSource(1)])
        try await waitForStageCall(fixture, 0)
        #expect(fixture.tray.isActive)
        #expect(fixture.tray.canRetry)
        fixture.tray.suspendForTeardown(of: fixture.staging)
        await fixture.staging.leave()

        #expect(!fixture.tray.isActive)
        #expect(!fixture.tray.canRetry)

        fixture.tray.retry(ids[0])

        #expect(fixture.status(ids[0]) == .failed(message: Self.stoppedMessage, isRetryable: true))
        #expect(fixture.staging.state == .idle)
        #expect(await fixture.stager.callCount == 1)

        fixture.tray.resumeAfterRejoin(of: fixture.staging)

        // Rejoining retries nothing by itself.
        #expect(fixture.tray.canRetry)
        #expect(fixture.status(ids[0]) == .failed(message: Self.stoppedMessage, isRetryable: true))

        fixture.tray.retry(ids[0])

        #expect(fixture.status(ids[0])?.stagingOperationID != nil)
        try await complete(fixture, call: 1, path: "/tmp/staged/one.jpg")
        try await waitUntil("the retried item should turn ready") {
            fixture.status(ids[0]) == .ready(path: "/tmp/staged/one.jpg")
        }
    }

    @Test func lifecycleCallsForAnUnboundStagingAreIgnored() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let departing = fixture.staging
        let successor = fixture.makeStaging()
        fixture.tray.bind(successor)

        // The departing Attach's queued teardown lands after its successor bound.
        fixture.tray.suspendForTeardown(of: departing)

        #expect(fixture.tray.isActive)
        let ids = try add(fixture, [imageSource(1), imageSource(2)])
        let firstOperationID = try #require(fixture.status(ids[0])?.stagingOperationID)
        #expect(successor.activeOperationID == firstOperationID)
        try await complete(fixture, call: 0, path: "/tmp/staged/one.jpg")
        try await waitUntil("the queue should keep running on the successor") {
            fixture.status(ids[1])?.stagingOperationID != nil
        }

        // Nor can the departing Attach lift the successor's own suspension.
        fixture.tray.suspendForTeardown(of: successor)
        fixture.tray.resumeAfterRejoin(of: departing)
        #expect(!fixture.tray.isActive)

        fixture.tray.resumeAfterRejoin(of: successor)

        #expect(fixture.tray.isActive)
        try await complete(fixture, call: 1, path: "/tmp/staged/two.jpg")
        try await waitUntil("the second item should turn ready") {
            fixture.tray.readyPaths == ["/tmp/staged/one.jpg", "/tmp/staged/two.jpg"]
        }
        #expect(departing.state == .idle)
    }

    @Test func rebindingTheSameStagingClearsATeardownSuspension() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let ids = try add(fixture, [imageSource(1), imageSource(2)])
        try await waitForStageCall(fixture, 0)
        let inFlightID = try #require(fixture.status(ids[0])?.stagingOperationID)
        fixture.tray.suspendForTeardown(of: fixture.staging)
        #expect(!fixture.tray.isActive)

        fixture.tray.bind(fixture.staging)

        #expect(fixture.tray.isActive)
        // The same instance's upload is still alive: it is not failed.
        #expect(fixture.status(ids[0]) == .staging(operationID: inFlightID))
        try await complete(fixture, call: 0, path: "/tmp/staged/one.jpg")
        try await waitUntil("the queue should move on after the rebind") {
            fixture.status(ids[1])?.stagingOperationID != nil
        }
        try await complete(fixture, call: 1, path: "/tmp/staged/two.jpg")
        try await waitUntil("both items should turn ready") {
            fixture.tray.readyPaths == ["/tmp/staged/one.jpg", "/tmp/staged/two.jpg"]
        }
    }

    @Test func itemsAddedWhileSuspendedStartWhenTheSameStagingRebinds() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        fixture.tray.suspendForTeardown(of: fixture.staging)
        let ids = try add(fixture, [imageSource(1), fileSource("notes.txt")])

        #expect(fixture.status(ids[0]) == .queued)
        #expect(fixture.status(ids[1]) == .queued)
        #expect(fixture.staging.state == .idle)

        fixture.tray.bind(fixture.staging)

        #expect(fixture.status(ids[0])?.stagingOperationID != nil)
        #expect(fixture.status(ids[1]) == .queued)
        try await complete(fixture, call: 0, path: "/tmp/staged/one.jpg")
        try await complete(fixture, call: 1, path: "/tmp/staged/notes.txt")
        try await waitUntil("both items should turn ready in add order") {
            fixture.tray.readyPaths == ["/tmp/staged/one.jpg", "/tmp/staged/notes.txt"]
        }
        #expect(await fixture.preparer.labels == ["image-1", "notes.txt"])
    }

    @Test func rebindingFailsTheOldInFlightItemAndIgnoresTheOldStaging() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let ids = try add(fixture, [imageSource(1), imageSource(2)])
        try await waitForStageCall(fixture, 0)
        let replacement = fixture.makeStaging()

        fixture.tray.bind(replacement)

        #expect(fixture.status(ids[0]) == .failed(message: Self.stoppedMessage, isRetryable: true))
        #expect(fixture.status(ids[1]) == .queued)
        #expect(replacement.state == .idle)

        fixture.tray.retry(ids[0])
        let replacementOperationID = try #require(fixture.status(ids[0])?.stagingOperationID)
        #expect(replacement.activeOperationID == replacementOperationID)
        try await waitForStageCall(fixture, 1)

        // The old staging finishes its upload under an id the replacement may
        // reuse; the tray must not take that path.
        await fixture.stager.send(.succeed(path: "/tmp/staged/stale.jpg"), toCall: 0)
        try await waitUntil("the old staging should finish its upload") {
            fixture.staging.state == .idle
        }
        #expect(fixture.status(ids[0]) == .staging(operationID: replacementOperationID))
        #expect(fixture.tray.readyPaths.isEmpty)

        await fixture.stager.send(.succeed(path: "/tmp/staged/one.jpg"), toCall: 1)
        try await waitUntil("the item should turn ready from the replacement") {
            fixture.status(ids[0]) == .ready(path: "/tmp/staged/one.jpg")
        }
        #expect(fixture.status(ids[1])?.stagingOperationID != nil)
        #expect(replacement.activeOperationID != nil)
        try await complete(fixture, call: 2, path: "/tmp/staged/two.jpg")
        try await waitUntil("the queue should continue on the replacement") {
            fixture.tray.readyPaths == ["/tmp/staged/one.jpg", "/tmp/staged/two.jpg"]
        }
        #expect(fixture.staging.state == .idle)
        #expect(await fixture.preparer.labels == ["image-1", "image-1", "image-2"])
    }

    @Test func backgroundInterruptionPausesTheQueueAndRetryReuploads() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let ids = try add(fixture, [imageSource(1), fileSource("notes.txt")])
        try await waitForStageCall(fixture, 0)

        fixture.staging.didEnterBackground()

        try await waitUntil("the in-flight item should fail retryably") {
            fixture.status(ids[0])
                == .failed(
                    message: "Image upload paused when Waycar moved to the background.",
                    isRetryable: true)
        }
        #expect(fixture.status(ids[1]) == .queued)
        #expect(fixture.stagingItemCount == 0)
        #expect(await fixture.stager.callCount == 1)
        let retainedURL = try await preparedURL(fixture, call: 0)
        #expect(FileManager.default.fileExists(atPath: retainedURL.path))

        fixture.tray.retry(ids[0])

        try await complete(fixture, call: 1, path: "/tmp/staged/one.jpg")
        try await waitUntil("the retried item should turn ready") {
            fixture.status(ids[0]) == .ready(path: "/tmp/staged/one.jpg")
        }
        let reuploadedURL = try await preparedURL(fixture, call: 1)
        #expect(reuploadedURL == retainedURL)
        try await complete(fixture, call: 2, path: "/tmp/staged/notes.txt")
        try await waitUntil("the queue should continue after the retry") {
            fixture.tray.readyPaths == ["/tmp/staged/one.jpg", "/tmp/staged/notes.txt"]
        }
        #expect(await fixture.preparer.labels == ["image-1", "notes.txt"])
    }

    // MARK: Shell mode

    @Test func shellModeInsertsCompletedPathsInsteadOfKeepingReadyItems() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let sink = PathSinkRecorder()
        fixture.tray.completedPathSink = { sink.paths.append($0) }
        let ids = try add(fixture, [imageSource(1), fileSource("notes.txt")])

        try await complete(fixture, call: 0, path: "/tmp/staged/one.jpg")
        try await waitUntil("the first path should be inserted") {
            sink.paths == ["/tmp/staged/one.jpg "]
        }
        #expect(fixture.ids == [ids[1]])
        #expect(fixture.status(ids[1])?.stagingOperationID != nil)
        #expect(!fixture.tray.hasReadyItems)

        try await complete(fixture, call: 1, path: "/tmp/staged/notes.txt")
        try await waitUntil("the second path should be inserted") {
            sink.paths == ["/tmp/staged/one.jpg ", "/tmp/staged/notes.txt "]
        }
        #expect(fixture.tray.isEmpty)
        #expect(fixture.tray.readyPaths.isEmpty)
        #expect(!fixture.tray.blocksSend)
        #expect(fixture.tray.sendHint == nil)
    }

    // MARK: Send gating

    @Test func pendingItemsHoldSendWithACountedHint() async throws {
        let cases: [(images: Int, files: Int, hint: String)] = [
            (1, 0, "Waiting for image…"),
            (3, 0, "Waiting for 3 images…"),
            (0, 1, "Waiting for file…"),
            (0, 2, "Waiting for 2 files…"),
            (2, 1, "Waiting for 3 items…"),
        ]
        for hintCase in cases {
            let fixture = try makeFixture()
            defer { fixture.cleanup() }
            fixture.tray.add(
                (0..<hintCase.images).map { imageSource(UInt8($0)) }
                    + (0..<hintCase.files).map { fileSource("f\($0).txt") })
            let comment: Comment = "\(hintCase.images) images, \(hintCase.files) files"
            #expect(fixture.tray.isActive, comment)
            #expect(fixture.tray.blocksSend, comment)
            #expect(!fixture.tray.hasReadyItems, comment)
            #expect(fixture.tray.sendHint == hintCase.hint, comment)
            await fixture.staging.leave()
        }
    }

    @Test func pendingItemsOnAnInactiveTrayPointToTheTerminal() async throws {
        let unbound = ComposerTray(clipboard: RecordingTrayClipboard())
        unbound.add([imageSource(1), fileSource("notes.txt")])
        #expect(!unbound.isActive)
        #expect(unbound.blocksSend)
        #expect(unbound.sendHint == "Open the terminal to finish uploading")

        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let ids = try add(fixture, [imageSource(1), imageSource(2)])
        try await complete(fixture, call: 0, path: "/tmp/staged/one.jpg")
        try await waitUntil("the first item should turn ready") {
            fixture.status(ids[0]) == .ready(path: "/tmp/staged/one.jpg")
        }
        try await waitForStageCall(fixture, 1)
        #expect(fixture.tray.sendHint == "Waiting for image…")

        fixture.tray.suspendForTeardown(of: fixture.staging)

        #expect(fixture.tray.sendHint == "Open the terminal to finish uploading")

        fixture.tray.resumeAfterRejoin(of: fixture.staging)

        #expect(fixture.tray.sendHint == "Waiting for image…")
        await fixture.staging.leave()
    }

    @Test func readyItemsAreNotCountedAsPending() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let ids = try add(fixture, [imageSource(1), imageSource(2)])
        try await complete(fixture, call: 0, path: "/tmp/staged/one.jpg")
        try await waitUntil("the first item should turn ready") {
            fixture.status(ids[0]) == .ready(path: "/tmp/staged/one.jpg")
        }

        #expect(fixture.tray.hasReadyItems)
        #expect(fixture.tray.blocksSend)
        #expect(fixture.tray.sendHint == "Waiting for image…")

        try await complete(fixture, call: 1, path: "/tmp/staged/two.jpg")
        try await waitUntil("the second item should turn ready") {
            fixture.status(ids[1]) == .ready(path: "/tmp/staged/two.jpg")
        }
        #expect(fixture.tray.hasReadyItems)
        #expect(!fixture.tray.blocksSend)
        #expect(fixture.tray.sendHint == nil)
    }

    @Test func failedImageHintTakesPrecedenceOverPendingItems() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let ids = try add(fixture, [imageSource(1), imageSource(2)])
        try await fail(fixture, call: 0, with: .transferFailed)
        try await waitUntil("the first item should fail") {
            fixture.status(ids[0]) == .failed(message: "Image upload failed.", isRetryable: true)
        }

        #expect(fixture.tray.blocksSend)
        #expect(!fixture.tray.hasReadyItems)
        #expect(fixture.tray.sendHint == "Retry or remove the failed image")

        // Suspended, Retry could not act: only Remove is offered.
        fixture.tray.suspendForTeardown(of: fixture.staging)
        #expect(fixture.tray.sendHint == "Remove the failed image")

        fixture.tray.resumeAfterRejoin(of: fixture.staging)
        #expect(fixture.tray.sendHint == "Retry or remove the failed image")
    }

    @Test func failedFileHintOffersRetryOnlyForARetryableFailure() async throws {
        let retryable = try makeFixture()
        defer { retryable.cleanup() }
        let retryableIDs = try add(retryable, [fileSource("notes.txt")])
        try await fail(retryable, call: 0, with: .transferFailed)
        try await waitUntil("the file should fail retryably") {
            retryable.status(retryableIDs[0])?.isRetryableFailure == true
        }
        #expect(retryable.tray.blocksSend)
        #expect(retryable.tray.sendHint == "Retry or remove the failed file")

        let permanent = try makeFixture()
        defer { permanent.cleanup() }
        let permanentIDs = try add(permanent, [fileSource("notes.txt")])
        try await fail(permanent, call: 0, with: .sftpUnavailable)
        try await waitUntil("the file should fail permanently") {
            permanent.status(permanentIDs[0])?.isFailed == true
        }
        #expect(permanent.status(permanentIDs[0])?.isRetryableFailure == false)
        #expect(permanent.tray.blocksSend)
        #expect(permanent.tray.sendHint == "Remove the failed file")
    }

    @Test func severalPermanentFailuresShareARemoveHint() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let ids = try add(fixture, [imageSource(1), fileSource("notes.txt")])
        try await fail(fixture, call: 0, with: .sftpUnavailable)
        try await fail(fixture, call: 1, with: .sftpUnavailable)
        try await waitUntil("both items should fail") {
            ids.allSatisfy { fixture.status($0)?.isFailed == true }
        }

        #expect(fixture.tray.blocksSend)
        #expect(fixture.tray.sendHint == "Remove the failed items")
    }

    @Test func oneRetryableFailureAmongSeveralOffersRetryWhileActive() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let ids = try add(fixture, [fileSource("first.txt"), imageSource(2)])
        try await fail(fixture, call: 0, with: .sftpUnavailable)
        try await fail(fixture, call: 1, with: .transferFailed)
        try await waitUntil("both items should fail") {
            ids.allSatisfy { fixture.status($0)?.isFailed == true }
        }
        #expect(fixture.status(ids[0])?.isRetryableFailure == false)
        #expect(fixture.status(ids[1])?.isRetryableFailure == true)

        #expect(fixture.tray.sendHint == "Retry or remove the failed items")

        fixture.tray.suspendForTeardown(of: fixture.staging)

        #expect(fixture.tray.sendHint == "Remove the failed items")
    }

    // MARK: Send and restore

    @Test func takeReadyItemsRemovesOnlyReadyItemsAndRestorePrependsThem() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let ids = try add(fixture, [imageSource(1), fileSource("notes.txt"), imageSource(3)])
        try await complete(fixture, call: 0, path: "/tmp/staged/one.jpg")
        try await complete(fixture, call: 1, path: "/tmp/staged/notes.txt")
        try await waitUntil("the first two items should turn ready") {
            fixture.status(ids[1]) == .ready(path: "/tmp/staged/notes.txt")
        }
        #expect(fixture.status(ids[2])?.stagingOperationID != nil)

        let taken = fixture.tray.takeReadyItems()

        #expect(taken.map(\.id) == [ids[0], ids[1]])
        #expect(
            taken.map(\.status)
                == [.ready(path: "/tmp/staged/one.jpg"), .ready(path: "/tmp/staged/notes.txt")])
        #expect(fixture.ids == [ids[2]])
        #expect(fixture.status(ids[2])?.stagingOperationID != nil)
        #expect(!fixture.tray.hasReadyItems)
        #expect(fixture.tray.takeReadyItems().isEmpty)

        let notReady = ComposerTray.Item(id: UUID(), kind: .image, thumbnail: nil, status: .queued)
        fixture.tray.restore(taken + [notReady])

        #expect(fixture.ids == [ids[0], ids[1], ids[2]])
        #expect(fixture.tray.readyPaths == ["/tmp/staged/one.jpg", "/tmp/staged/notes.txt"])
        try await complete(fixture, call: 2, path: "/tmp/staged/three.jpg")
        try await waitUntil("the staging item should still complete after restore") {
            fixture.tray.readyPaths
                == ["/tmp/staged/one.jpg", "/tmp/staged/notes.txt", "/tmp/staged/three.jpg"]
        }
    }

    @Test func restoreReturnsSentItemsEvenPastCapacity() {
        let tray = ComposerTray(clipboard: RecordingTrayClipboard())
        tray.add((0..<ComposerTray.capacity).map { fileSource("f\($0).txt") })
        let sent = ComposerTray.Item(
            id: UUID(), kind: .image, thumbnail: nil, status: .ready(path: "/tmp/staged/sent.jpg"))

        tray.restore([sent])

        #expect(tray.items.count == ComposerTray.capacity + 1)
        #expect(tray.items.first?.id == sent.id)
        #expect(tray.readyPaths == ["/tmp/staged/sent.jpg"])
        #expect(tray.remainingCapacity == 0)
        #expect(!tray.canAdd)
    }

    // MARK: Copy path and progress

    @Test func copyPathCopiesOnlyAReadyItemsPath() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let ids = try add(fixture, [imageSource(1), imageSource(2)])
        try await complete(fixture, call: 0, path: "/tmp/staged/one.jpg")
        try await waitUntil("the first item should turn ready") {
            fixture.status(ids[0]) == .ready(path: "/tmp/staged/one.jpg")
        }

        fixture.tray.copyPath(ids[1])
        fixture.tray.copyPath(UUID())
        #expect(fixture.clipboard.copiedPaths.isEmpty)

        fixture.tray.copyPath(ids[0])
        #expect(fixture.clipboard.copiedPaths == ["/tmp/staged/one.jpg"])

        try await fail(fixture, call: 1, with: .transferFailed)
        try await waitUntil("the second item should fail") {
            fixture.status(ids[1]) == .failed(message: "Image upload failed.", isRetryable: true)
        }
        fixture.tray.copyPath(ids[1])
        #expect(fixture.clipboard.copiedPaths == ["/tmp/staged/one.jpg"])
    }

    @Test func uploadProgressFollowsOnlyTheUploadingItem() async throws {
        let preparationGate = ScriptedTransportCallGate()
        let fixture = try makeFixture(preparationGate: preparationGate)
        defer { fixture.cleanup() }
        let ids = try add(fixture, [imageSource(1), imageSource(2)])
        await preparationGate.waitForEntry()

        #expect(fixture.status(ids[0])?.stagingOperationID != nil)
        #expect(fixture.tray.uploadProgress(for: ids[0]) == nil)
        #expect(fixture.tray.uploadProgress(for: ids[1]) == nil)

        await preparationGate.open()
        try await waitForStageCall(fixture, 0)
        #expect(fixture.tray.uploadProgress(for: ids[0]) == 0)

        await fixture.stager.send(.progress(transferredBytes: 16), toCall: 0)
        try await waitUntil("a quarter should be reported") {
            fixture.tray.uploadProgress(for: ids[0]) == 0.25
        }
        await fixture.stager.send(.progress(transferredBytes: 48), toCall: 0)
        try await waitUntil("three quarters should be reported") {
            fixture.tray.uploadProgress(for: ids[0]) == 0.75
        }
        #expect(fixture.tray.uploadProgress(for: ids[1]) == nil)

        await fixture.stager.send(.succeed(path: "/tmp/staged/one.jpg"), toCall: 0)
        try await waitUntil("the first item should turn ready") {
            fixture.status(ids[0]) == .ready(path: "/tmp/staged/one.jpg")
        }
        #expect(fixture.tray.uploadProgress(for: ids[0]) == nil)
        try await waitForStageCall(fixture, 1)
        #expect(fixture.tray.uploadProgress(for: ids[1]) == 0)
    }

    // MARK: Thumbnails

    @Test func imageItemsGetABoundedThumbnailAndFilesNever() async throws {
        let png = try makePNG(width: 800, height: 400)
        let tray = ComposerTray(clipboard: RecordingTrayClipboard())
        tray.add([
            .photo(DataImageSelection(data: Data([0x00, 0x01, 0x02]))),
            .photo(DataImageSelection(data: png)),
            fileSource("notes.txt"),
        ])
        try #require(tray.items.count == 3)

        // Thumbnails decode serially in add order, so once the PNG has one
        // the undecodable image's attempt is already over.
        try await waitUntil("the PNG should get a thumbnail") {
            tray.items[1].thumbnail != nil
        }
        let thumbnail = try #require(tray.items[1].thumbnail)
        #expect(max(thumbnail.image.width, thumbnail.image.height) <= 384)
        #expect(thumbnail.image.width > thumbnail.image.height)
        #expect(tray.items[0].thumbnail == nil)
        #expect(tray.items[2].thumbnail == nil)
    }

    // MARK: Fixture

    private func makeFixture(
        preparationGate: ScriptedTransportCallGate? = nil
    ) throws -> TrayFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("composer-tray-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let preparer = TrayPreparer(directory: directory, gate: preparationGate)
        let stager = TrayStager()
        let clipboard = RecordingTrayClipboard()
        let fixture = TrayFixture(
            tray: ComposerTray(clipboard: clipboard),
            staging: TrayFixture.makeStaging(preparer: preparer, stager: stager),
            preparer: preparer,
            stager: stager,
            clipboard: clipboard,
            directory: directory)
        fixture.tray.bind(fixture.staging)
        return fixture
    }

    private func add(
        _ fixture: TrayFixture,
        _ sources: [ComposerStagingStore.Source]
    ) throws -> [ComposerTray.Item.ID] {
        fixture.tray.add(sources)
        try #require(fixture.tray.items.count == sources.count)
        return fixture.ids
    }

    private func imageSource(_ tag: UInt8) -> ComposerStagingStore.Source {
        .photo(DataImageSelection(data: Data([tag])))
    }

    private func fileSource(_ name: String) -> ComposerStagingStore.Source {
        .file(URL(fileURLWithPath: "/provider/\(name)"))
    }

    private func waitForStageCall(_ fixture: TrayFixture, _ index: Int) async throws {
        try await waitUntil("stage call \(index) should start") {
            await fixture.stager.callCount > index
        }
    }

    private func complete(_ fixture: TrayFixture, call index: Int, path: String) async throws {
        try await waitForStageCall(fixture, index)
        await fixture.stager.send(.succeed(path: path), toCall: index)
    }

    private func fail(
        _ fixture: TrayFixture,
        call index: Int,
        with error: AttachmentStagingError
    ) async throws {
        try await waitForStageCall(fixture, index)
        await fixture.stager.send(.fail(error), toCall: index)
    }

    private func preparedURL(_ fixture: TrayFixture, call index: Int) async throws -> URL {
        let calls = await fixture.stager.calls
        return try #require(
            index < calls.count ? calls[index].preparedURL : nil,
            "stage call \(index) should exist")
    }

    private func makePNG(width: Int, height: Int) throws -> Data {
        let context = try #require(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(
                data as CFMutableData, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

@MainActor
private struct TrayFixture {
    let tray: ComposerTray
    let staging: ComposerStagingStore
    let preparer: TrayPreparer
    let stager: TrayStager
    let clipboard: RecordingTrayClipboard
    let directory: URL

    var ids: [ComposerTray.Item.ID] { tray.items.map(\.id) }

    var stagingItemCount: Int {
        tray.items.filter { $0.status.stagingOperationID != nil }.count
    }

    func status(_ id: ComposerTray.Item.ID) -> ComposerTray.Item.Status? {
        tray.items.first { $0.id == id }?.status
    }

    /// Another Attach's staging over the same fake preparer and Host.
    func makeStaging() -> ComposerStagingStore {
        Self.makeStaging(preparer: preparer, stager: stager)
    }

    static func makeStaging(preparer: TrayPreparer, stager: TrayStager) -> ComposerStagingStore {
        ComposerStagingStore(
            imagePreparer: preparer,
            filePreparer: preparer,
            stageImage: { image, reporter in
                try await stager.stageImage(image, reporter: reporter)
            },
            stageFile: { file, reporter in
                try await stager.stageFile(file, reporter: reporter)
            })
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Prepares every source into a fresh local file and records which source
/// it prepared (`image-<first byte>` or the file's name), in order.
private actor TrayPreparer: ImagePreparing, FilePreparing {
    static let byteCount: Int64 = 64

    private let directory: URL
    private let gate: ScriptedTransportCallGate?
    private(set) var labels: [String] = []

    init(directory: URL, gate: ScriptedTransportCallGate?) {
        self.directory = directory
        self.gate = gate
    }

    func prepare(_ selection: any ImageSelection) async throws -> PreparedImage {
        let data = try await selection.loadData()
        let fileURL = try await makeFile(label: "image-\(data.first ?? 0)")
        return PreparedImage(
            fileURL: fileURL,
            format: .jpeg,
            pixelWidth: 16,
            pixelHeight: 16,
            byteCount: Self.byteCount)
    }

    func prepare(_ sourceURL: URL) async throws -> PreparedFile {
        let fileURL = try await makeFile(label: sourceURL.lastPathComponent)
        return PreparedFile(fileURL: fileURL, fileExtension: "txt", byteCount: Self.byteCount)
    }

    private func makeFile(label: String) async throws -> URL {
        labels.append(label)
        await gate?.waitUntilOpen()
        let url = directory.appendingPathComponent("prepared-\(UUID().uuidString).bin")
        try Data(repeating: 0x41, count: Int(Self.byteCount)).write(to: url)
        return url
    }
}

/// A fake Host: each stage call (numbered from 0 across every staging
/// instance) waits for the test's commands. Cancellation ends the call.
private actor TrayStager {
    enum Kind: Sendable, Equatable {
        case image
        case file
    }

    enum Command: Sendable {
        case progress(transferredBytes: Int64)
        case succeed(path: String)
        case fail(AttachmentStagingError)
    }

    struct Call: Sendable, Equatable {
        let kind: Kind
        let preparedURL: URL
    }

    private(set) var calls: [Call] = []
    private(set) var cancelledCalls: [Int] = []
    private var channels:
        [Int: (stream: AsyncStream<Command>, continuation: AsyncStream<Command>.Continuation)] =
        [:]

    var callCount: Int { calls.count }

    func send(_ command: Command, toCall index: Int) {
        channel(index).continuation.yield(command)
    }

    func stageImage(
        _ image: PreparedImage,
        reporter: AttachmentStageProgressReporter
    ) async throws -> StagedImage {
        let path = try await stage(
            Call(kind: .image, preparedURL: image.fileURL),
            byteCount: image.byteCount,
            reporter: reporter)
        return try StagedImage(path: path)
    }

    func stageFile(
        _ file: PreparedFile,
        reporter: AttachmentStageProgressReporter
    ) async throws -> StagedFile {
        let path = try await stage(
            Call(kind: .file, preparedURL: file.fileURL),
            byteCount: file.byteCount,
            reporter: reporter)
        return try StagedFile(path: path)
    }

    private func stage(
        _ call: Call,
        byteCount: Int64,
        reporter: AttachmentStageProgressReporter
    ) async throws -> String {
        let index = calls.count
        calls.append(call)
        let commands = channel(index).stream
        for await command in commands {
            switch command {
            case .progress(let transferredBytes):
                await reporter.report(
                    AttachmentStageProgress(
                        transferredBytes: transferredBytes,
                        totalBytes: byteCount))
            case .succeed(let path):
                return path
            case .fail(let error):
                throw error
            }
        }
        // The stream ends only when the staging task is cancelled.
        cancelledCalls.append(index)
        throw CancellationError()
    }

    private func channel(
        _ index: Int
    ) -> (stream: AsyncStream<Command>, continuation: AsyncStream<Command>.Continuation) {
        if let channel = channels[index] { return channel }
        let channel = AsyncStream.makeStream(of: Command.self)
        channels[index] = channel
        return channel
    }
}

@MainActor
private final class RecordingTrayClipboard: AttachmentClipboard {
    private(set) var copiedPaths: [String] = []

    func copy(_ path: String) throws {
        copiedPaths.append(path)
    }
}

@MainActor
private final class PathSinkRecorder {
    var paths: [String] = []
}

extension ComposerTray.Item.Status {
    fileprivate var stagingOperationID: UInt64? {
        if case .staging(let operationID) = self { return operationID }
        return nil
    }
}
