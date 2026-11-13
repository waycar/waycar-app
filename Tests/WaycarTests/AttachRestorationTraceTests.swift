#if DEBUG
import Testing

@testable import Waycar

@Suite("Attach restoration trace")
struct AttachRestorationTraceTests {
    @Test func phaseGateRecordsEachPhaseOnce() {
        var state = AttachRestorationTraceState()

        let recordedRecovery = state.record(.foregroundRecoveryStarted)
        let recordedRecoveryAgain = state.record(.foregroundRecoveryStarted)
        let recordedAbort = state.record(.foregroundRecoveryAborted)
        let recordedAbortAgain = state.record(.foregroundRecoveryAborted)
        let recordedAppearance = state.record(.agentDetailVisible)
        let recordedAppearanceAgain = state.record(.agentDetailVisible)
        let recordedTransport = state.record(.transportAcquired)

        #expect(recordedRecovery)
        #expect(!recordedRecoveryAgain)
        #expect(recordedAbort)
        #expect(!recordedAbortAgain)
        #expect(recordedAppearance)
        #expect(!recordedAppearanceAgain)
        #expect(recordedTransport)
        #expect(state.emittedPhases == [
            .foregroundRecoveryStarted,
            .foregroundRecoveryAborted,
            .agentDetailVisible,
            .transportAcquired,
        ])
    }

    @Test func separatePipelinesHaveIndependentPhaseGates() {
        var initialEntry = AttachRestorationTraceState()
        var foregroundRecovery = AttachRestorationTraceState()

        let initialRecordedOutput = initialEntry.record(.firstOutputBytes)
        let recoveryRecordedOutput = foregroundRecovery.record(.firstOutputBytes)
        let recoveryRecordedOutputAgain = foregroundRecovery.record(.firstOutputBytes)

        #expect(initialRecordedOutput)
        #expect(recoveryRecordedOutput)
        #expect(!recoveryRecordedOutputAgain)
    }

    @Test func replacementPipelineRecordsItsOwnVisibilityMarker() {
        var initialEntry = AttachRestorationTraceState()
        var foregroundRecovery = AttachRestorationTraceState()

        let initialVisible = initialEntry.record(.agentDetailVisible)
        let recoveryVisible = foregroundRecovery.record(.agentDetailVisible)

        #expect(initialVisible)
        #expect(recoveryVisible)
    }
}
#endif
