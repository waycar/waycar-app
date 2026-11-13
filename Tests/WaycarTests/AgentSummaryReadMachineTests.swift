import Testing

@testable import Waycar

@Suite("Agent summary read machine")
struct AgentSummaryReadMachineTests {
    private let summary = AgentSummary(paneID: "p", status: .working, text: "working", timestamp: 1)

    @Test func requestsCoalesceIntoExactlyOneFollowUp() {
        var machine = AgentSummaryReadMachine()
        #expect(machine.handle(.request(epoch: 3, enabled: true)) == [.read(token: 1)])
        #expect(machine.handle(.request(epoch: 3, enabled: true)).isEmpty)
        #expect(machine.handle(.request(epoch: 3, enabled: true)).isEmpty)
        #expect(machine.state == .readingAgain(token: 1, epoch: 3, availability: .available))
        #expect(machine.handle(.finished(
            token: 1, currentEpoch: 3, outcome: .summaries(["p": summary])))
            == [.apply(["p": summary]), .requestFollowUp])
        #expect(machine.handle(.request(epoch: 3, enabled: true)) == [.read(token: 2)])
        #expect(machine.handle(.finished(token: 2, currentEpoch: 3, outcome: .failed)).isEmpty)
        #expect(machine.state == .idle)
    }

    @Test func staleCapabilityResultDrainsTheReplacementConnectionsRequest() {
        var machine = AgentSummaryReadMachine().after([
            .request(epoch: 1, enabled: true), .connectionChanged,
            .request(epoch: 2, enabled: true),
        ])
        #expect(machine.handle(.finished(
            token: 1, currentEpoch: 2, outcome: .pluginMissing)) == [.requestFollowUp])
        #expect(machine.handle(.request(epoch: 2, enabled: true)) == [.read(token: 2)])
        #expect(machine.state == .reading(token: 2, epoch: 2, availability: .available))
        #expect(!machine.isUnavailable)
    }

    @Test func staleSummariesCannotReplaceTheRows() {
        var machine = AgentSummaryReadMachine().after([.request(epoch: 1, enabled: true)])
        #expect(machine.handle(.finished(
            token: 1, currentEpoch: 2, outcome: .summaries(["p": summary]))).isEmpty)
        #expect(machine.state == .idle)
    }

    @Test func missingPluginDropsTheFollowUpUntilTheNextConnection() {
        var machine = AgentSummaryReadMachine().after([
            .request(epoch: 1, enabled: true), .request(epoch: 1, enabled: true),
        ])
        #expect(machine.handle(.finished(
            token: 1, currentEpoch: 1, outcome: .pluginMissing)) == [.pluginMissing])
        #expect(machine.state == .unavailable)
        #expect(machine.handle(.request(epoch: 1, enabled: true)).isEmpty)
        #expect(machine.handle(.connectionChanged).isEmpty)
        #expect(machine.handle(.request(epoch: 2, enabled: true)) == [.read(token: 2)])
    }

    @Test func refreshCapabilityDoesNotCancelTheReadOrClearItsSuccessfulAnswer() {
        var machine = AgentSummaryReadMachine().after([
            .request(epoch: 1, enabled: true), .request(epoch: 1, enabled: true), .pluginMissing,
        ])
        #expect(machine.isUnavailable)
        #expect(machine.readToken == 1)
        #expect(machine.handle(.finished(
            token: 1, currentEpoch: 1, outcome: .summaries(["p": summary])))
            == [.apply(["p": summary]), .requestFollowUp])
        #expect(machine.handle(.request(epoch: 1, enabled: true)).isEmpty)
        #expect(machine.state == .unavailable)
    }

    @Test func connectionResetClearsCapabilityButKeepsTheReadAndFollowUp() {
        var machine = AgentSummaryReadMachine().after([
            .request(epoch: 1, enabled: true), .request(epoch: 1, enabled: true), .pluginMissing,
        ])
        #expect(machine.handle(.connectionChanged).isEmpty)
        #expect(machine.state == .readingAgain(token: 1, epoch: 1, availability: .available))
        #expect(machine.handle(.finished(token: 1, currentEpoch: 2, outcome: .failed)) == [.requestFollowUp])
        #expect(machine.handle(.request(epoch: 2, enabled: true)) == [.read(token: 2)])
    }

    @Test func followUpSamplesTheGateAndEpochAfterPublishingTheResult() {
        var machine = AgentSummaryReadMachine()
        #expect(machine.handle(.request(epoch: 1, enabled: false)).isEmpty)
        #expect(machine.state == .idle)
        _ = machine.handle([
            .request(epoch: 1, enabled: true), .request(epoch: 1, enabled: true),
        ])
        #expect(machine.handle(.finished(
            token: 1, currentEpoch: 1, outcome: .summaries(["p": summary])))
            == [.apply(["p": summary]), .requestFollowUp])
        // Publication can disable summaries or reconnect the projection.
        #expect(machine.handle(.request(epoch: 1, enabled: false)).isEmpty)
        #expect(machine.state == .idle)
        #expect(machine.handle(.connectionChanged).isEmpty)
        #expect(machine.handle(.request(epoch: 2, enabled: true)) == [.read(token: 2)])
        #expect(machine.state == .reading(token: 2, epoch: 2, availability: .available))
    }

    @Test func completionTokensAndEndRejectLateWork() {
        var machine = AgentSummaryReadMachine().after([.request(epoch: 1, enabled: true)])
        #expect(machine.handle(.finished(token: 99, currentEpoch: 1, outcome: .pluginMissing)).isEmpty)
        #expect(machine.state == .reading(token: 1, epoch: 1, availability: .available))
        #expect(machine.handle(.end) == [.cancel(token: 1)])
        #expect(machine.handle([
            .finished(token: 1, currentEpoch: 1, outcome: .summaries(["p": summary])),
            .connectionChanged, .request(epoch: 2, enabled: true), .pluginMissing, .end,
        ]).isEmpty)
        #expect(machine.state == .ended)
    }
}
