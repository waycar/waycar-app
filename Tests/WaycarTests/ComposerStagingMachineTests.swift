import Foundation
import Testing

@testable import Waycar

@Suite("Composer staging machine")
struct ComposerStagingMachineTests {
    private let source = ComposerStagingStore.Source.file(URL(fileURLWithPath: "/picked.txt"))
    private var prepared: ComposerStagingMachine.Prepared {
        .file(PreparedFile(fileURL: URL(fileURLWithPath: "/prepared.txt"), fileExtension: "txt", byteCount: 8))
    }
    private let progress = AttachmentStageProgress(transferredBytes: 4, totalBytes: 8)
    private let failure = ComposerStagingStore.Failure(medium: .file, message: "failed", isRetryable: true)

    private func uploading() -> ComposerStagingMachine {
        ComposerStagingMachine().after([.begin(source), .prepared(2, prepared)])
    }

    @Test func beginPrepareProgressAndSuccess() {
        var machine = ComposerStagingMachine()
        #expect(machine.handle(.begin(source)) == [.prepare(.init(token: 2, source: source))])
        #expect(machine.state == .preparing(operation: 1, attempt: 2, .file))
        #expect(machine.activeOperationID == 1)
        #expect(machine.taskToken == 2)
        #expect(machine.handle(.begin(source)) == [])
        #expect(machine.handle(.prepared(2, prepared)) == [.finishTask(2), .upload(3, prepared)])
        #expect(machine.activeOperationID == 1)
        #expect(machine.taskToken == 3)
        // Public ids cannot be used as asynchronous attempt tokens, or vice versa.
        #expect(machine.handle([.progress(1, progress), .failed(2, failure, cancelled: false),
            .succeeded(2, path: "/late-preparation"), .cancel(3)]) == [])
        #expect(machine.handle(.progress(3, progress)) == [])
        #expect(machine.presentation == .uploading(.file, progress))
        #expect(machine.handle(.succeeded(3, path: "/host")) == [
            .finishTask(3), .discard(prepared), .publish(.completed(id: 1, path: "/host")),
        ])
        #expect(machine.state == .idle)
        #expect(machine.activeOperationID == nil)
    }

    @Test func retryAndDismissRequireTheRetainedFailureID() {
        var machine = uploading()
        #expect(machine.handle(.failed(3, failure, cancelled: false)) == [
            .finishTask(3), .publish(.failed(id: 1, message: "failed", retryable: true)),
        ])
        #expect(machine.handle(.retry(3)) == [])
        #expect(machine.handle(.dismiss(3)) == [])
        #expect(machine.handle(.retry(1)) == [.upload(4, prepared)])
        #expect(machine.activeOperationID == 1)
        #expect(machine.handle(.dismiss(1)) == [])
        _ = machine.handle(.failed(4, failure, cancelled: false))
        #expect(machine.handle(.dismiss(1)) == [.discard(prepared)])
        #expect(machine.state == .idle)
    }

    @Test(arguments: [false, true])
    func retryIgnoresOldAttemptResultsAndPublishesTheOperationID(failRetry: Bool) {
        var machine = uploading()
        _ = machine.handle(.failed(3, failure, cancelled: false))
        #expect(machine.handle(.retry(1)) == [.upload(4, prepared)])
        let retry = machine.state
        #expect(retry == .uploading(operation: 1, attempt: 4, prepared,
            AttachmentStageProgress(transferredBytes: 0, totalBytes: 8)))
        #expect(machine.handle([.progress(3, progress), .failed(3, failure, cancelled: false),
            .succeeded(3, path: "/old-upload")]) == [])
        #expect(machine.state == retry)
        #expect(machine.activeOperationID == 1)
        #expect(machine.taskToken == 4)
        #expect(machine.handle(.progress(4, progress)) == [])
        #expect(machine.presentation == .uploading(.file, progress))
        if failRetry {
            #expect(machine.handle(.failed(4, failure, cancelled: false)) == [
                .finishTask(4), .publish(.failed(id: 1, message: "failed", retryable: true)),
            ])
            #expect(machine.handle(.retry(1)) == [.upload(5, prepared)])
            #expect(machine.taskToken == 5)
        } else {
            #expect(machine.handle(.succeeded(4, path: "/retried")) == [
                .finishTask(4), .discard(prepared), .publish(.completed(id: 1, path: "/retried")),
            ])
            #expect(machine.state == .idle)
        }
    }

    @Test func nonRetryableAndUnpreparedFailuresCannotRetry() {
        let fatal = ComposerStagingStore.Failure(medium: .file, message: "fatal", isRetryable: false)
        var machine = uploading()
        #expect(machine.handle(.failed(3, fatal, cancelled: false)) == [
            .finishTask(3), .discard(prepared), .publish(.failed(id: 1, message: "fatal", retryable: false)),
        ])
        #expect(machine.handle(.retry(1)) == [])
        #expect(machine.handle(.begin(source)) == [.prepare(.init(token: 5, source: source))])
        #expect(machine.activeOperationID == 4)
        _ = machine.handle(.failed(5, failure, cancelled: false))
        #expect(machine.handle(.retry(4)) == [])
    }

    @Test(arguments: [false, true]) func userCancellationDiscardsOnlyClaimedBytes(uploading: Bool) {
        var machine = uploading ? self.uploading() : ComposerStagingMachine().after([.begin(source)])
        let attempt: UInt64 = uploading ? 3 : 2
        #expect(machine.handle(.cancel(9)) == [])
        #expect(machine.handle(.cancel(attempt)) == [])
        #expect(machine.handle(.cancel(1)) == [.cancelTask(attempt)])
        let effects = machine.handle(.failed(attempt, failure, cancelled: true))
        #expect(effects == [.finishTask(attempt)] + (uploading ? [.discard(prepared)] : []) + [.publish(.cancelled(id: 1))])
        #expect(machine.state == .idle)
    }

    @Test func spontaneousCancellationIsAlsoCancellation() {
        var machine = uploading()
        #expect(machine.handle(.failed(3, failure, cancelled: true)) == [
            .finishTask(3), .discard(prepared), .publish(.cancelled(id: 1)),
        ])
    }

    @Test(arguments: [false, true]) func backgroundKeepsOnlyClaimedBytes(uploading: Bool) {
        var machine = uploading ? self.uploading() : ComposerStagingMachine().after([.begin(source)])
        let attempt: UInt64 = uploading ? 3 : 2
        #expect(machine.handle(.background(failure)) == [.cancelTask(attempt)])
        #expect(machine.handle(.failed(attempt, failure, cancelled: true)) == [
            .finishTask(attempt), .publish(.failed(id: 1, message: "failed", retryable: true)),
        ])
        #expect(machine.presentation == .backgroundInterrupted(failure))
        #expect(machine.handle(.retry(1)) == (uploading ? [.upload(4, prepared)] : []))
    }

    @Test func latestCancellationDispositionWinsEvenIfUploadReturnsSuccess() {
        var machine = uploading()
        _ = machine.handle([.cancel(1), .background(failure)])
        #expect(machine.handle(.progress(3, progress)) == [])
        #expect(machine.presentation == .uploading(.file, progress))
        #expect(machine.handle(.succeeded(3, path: "/orphan")) == [
            .finishTask(3), .publish(.failed(id: 1, message: "failed", retryable: true)),
        ])
        _ = machine.handle(.retry(1))
        _ = machine.handle([.background(failure), .cancel(1)])
        #expect(machine.handle(.succeeded(4, path: "/orphan")) == [
            .finishTask(4), .discard(prepared), .publish(.cancelled(id: 1)),
        ])
    }

    @Test func leaveInvalidatesResultsAndWaitsBeforeDisposal() {
        var machine = uploading()
        let display = machine.presentation
        #expect(machine.handle(.leave) == [.cancelTask(3), .finishTask(3)])
        #expect(machine.leaveToken == 4)
        #expect(machine.activeOperationID == 1)
        #expect(machine.presentation == display)
        #expect(machine.handle([.progress(3, progress), .succeeded(3, path: "/late"), .failed(3, failure, cancelled: true), .left(3)]) == [])
        #expect(machine.presentation == display)
        #expect(machine.handle(.left(4)) == [.discard(prepared), .publish(.cancelled(id: 1))])
        #expect(machine.state == .idle)
        #expect(machine.handle(.begin(source)) == [.prepare(.init(token: 6, source: source))])
        #expect(machine.activeOperationID == 5)
        #expect(machine.handle(.left(4)) == [])
    }

    @Test func leaveAfterRetryCancelsTheAttemptButPublishesTheOperationID() {
        var machine = uploading().after([.failed(3, failure, cancelled: false), .retry(1)])
        #expect(machine.handle(.leave) == [.cancelTask(4), .finishTask(4)])
        #expect(machine.activeOperationID == 1)
        #expect(machine.leaveToken == 5)
        #expect(machine.handle(.left(5)) == [.discard(prepared), .publish(.cancelled(id: 1))])
    }

    @Test func idleAndFailedLeaveAreSilentAndNewWorkDiscardsRetainedBytes() {
        var machine = ComposerStagingMachine()
        #expect(machine.handle(.leave) == [])
        #expect(machine.handle(.left(1)) == [])
        machine = uploading()
        _ = machine.handle(.failed(3, failure, cancelled: false))
        #expect(machine.handle(.begin(source)) == [.discard(prepared), .prepare(.init(token: 5, source: source))])
        _ = machine.handle(.failed(5, failure, cancelled: false))
        #expect(machine.handle(.leave) == [])
        #expect(machine.handle(.left(6)) == [])
    }

    @Test func leaveDuringPreparationOrCancellationDropsLateWorkAndFailureLeaveIsSilent() {
        var machine = ComposerStagingMachine().after([.begin(source)])
        #expect(machine.handle(.leave) == [.cancelTask(2), .finishTask(2)])
        #expect(machine.activeOperationID == 1)
        #expect(machine.handle(.prepared(2, prepared)) == [.discard(prepared)])
        #expect(machine.handle(.left(3)) == [.publish(.cancelled(id: 1))])
        machine = uploading().after([.cancel(1)])
        #expect(machine.handle(.leave) == [.cancelTask(3), .finishTask(3)])
        #expect(machine.handle(.left(4)) == [.discard(prepared), .publish(.cancelled(id: 1))])
        machine = uploading().after([.failed(3, failure, cancelled: false)])
        #expect(machine.handle(.leave) == [])
        #expect(machine.activeOperationID == nil)
        #expect(machine.handle(.left(4)) == [.discard(prepared)])
    }

    @Test func stalePreparedBytesAreDisposedAndOtherStaleOrIdleEventsAreIgnored() {
        var machine = uploading()
        #expect(machine.handle(.prepared(99, prepared)) == [.discard(prepared)])
        #expect(machine.handle([.progress(99, progress), .succeeded(99, path: "/late"), .failed(99, failure, cancelled: false), .retry(1), .dismiss(1), .left(1)]) == [])
        machine = ComposerStagingMachine()
        #expect(machine.handle([.progress(1, progress), .succeeded(1, path: "/late"), .failed(1, failure, cancelled: true), .retry(1), .dismiss(1), .cancel(1), .background(failure), .left(1)]) == [])
    }
}
