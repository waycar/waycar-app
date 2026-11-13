import Testing

@testable import Waycar

/// The toolbar's connection dot: what each attach state reads as.
@MainActor
@Suite("Terminal connection indicator")
struct TerminalConnectionIndicatorTests {
    private func indicator(
        _ status: AttachTerminalStore.Status,
        hostCondition: MissingAgentPresentation? = nil,
        isStalled: Bool = false,
        isSceneActive: Bool = true,
        endedWithMoshFailure: Bool = false,
        liveInAnotherWindow: Bool = false
    ) -> TerminalConnectionIndicator? {
        TerminalConnectionIndicator(
            status: status,
            presentation: TerminalStatusPresentation(status: status, hostCondition: hostCondition),
            isStalled: isStalled,
            isSceneActive: isSceneActive,
            endedWithMoshFailure: endedWithMoshFailure,
            liveInAnotherWindow: liveInAnotherWindow)
    }

    /// The Host condition an on-stage attach would carry for a Host in `status`.
    private func hostCondition(_ status: EventsSessionStatus) throws -> MissingAgentPresentation {
        let host = Host.fixture()
        let agentID = ConsoleAgent.ID(hostID: host.id, paneID: "w1:p1")
        return try #require(
            MissingAgentPresentation.attachHostCondition(
                agentID: agentID, hostStatuses: [host.id: status], hosts: [host],
                hostsAwaitingSnapshot: [host.id], hostStandingFailures: [:],
                hostsWithinReconnectGrace: []))
    }

    @Test func aLiveAttachIsLive() {
        #expect(indicator(.live) == .live)
    }

    @Test func connectingStatesReadAsReconnecting() throws {
        #expect(indicator(.connecting) == .reconnecting(message: nil, isStalled: false))
        #expect(indicator(.waitingForSize) == .reconnecting(message: nil, isStalled: false))
        // A Host still coming up speaks for the wait, and the dot repeats it.
        let coming = try hostCondition(
            .reconnecting(attempt: 2, delay: .seconds(1), failure: .timedOut))
        #expect(
            indicator(.connecting, hostCondition: coming)
                == .reconnecting(message: coming.message, isStalled: false))
    }

    @Test func aStalledLiveAttachReadsAsReconnectingWhileTheSceneIsActive() {
        #expect(
            indicator(.live, isStalled: true) == .reconnecting(message: nil, isStalled: true))
        #expect(indicator(.live, isStalled: true, isSceneActive: false) == .live)
    }

    @Test func anEndedAttachIsDetachedWithItsReason() {
        #expect(
            indicator(.ended("The session ended."))
                == .detached(message: "The session ended.", canUseSSH: false))
        #expect(
            indicator(.ended("mosh failed"), endedWithMoshFailure: true)
                == .detached(message: "mosh failed", canUseSSH: true))
    }

    @Test func aHostThatCannotBeReachedOutranksTheAttachWaitingOnIt() throws {
        let failed = try hostCondition(.failed(.authenticationFailed))
        #expect(
            indicator(.connecting, hostCondition: failed)
                == .hostUnavailable(title: failed.title, message: failed.message))
    }

    @Test func noDotWhereAnotherDialogSpeaksOrNothingRuns() {
        #expect(indicator(.live, liveInAnotherWindow: true) == nil)
        #expect(indicator(.ended("gone"), liveInAnotherWindow: true) == nil)
        #expect(indicator(.live, isStalled: true, liveInAnotherWindow: true) == nil)
        #expect(indicator(.stopped) == nil)
    }
}
