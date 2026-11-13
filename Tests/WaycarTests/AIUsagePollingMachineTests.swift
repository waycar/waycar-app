import Foundation
import Testing

@testable import Waycar

@Suite("AI Usage polling machine")
struct AIUsagePollingMachineTests {
    private let host = UUID()
    private let other = UUID()
    private let id = UUID()
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private let path = "/usr/local/bin/codexbar"
    private var report: AIUsageReport { AIUsageReport(providers: [], commandError: nil) }
    private func token(_ sequence: UInt64) -> AIUsagePollingMachine.FetchToken {
        .init(requestID: id, sequence: sequence)
    }
    private func fetch(_ host: UUID, scheduled: Bool = false) -> AIUsagePollingMachine.Event {
        .fetch(host, path: path, scheduled: scheduled, requestID: id)
    }

    @Test func waitsAreReplacedAndStaleWakeupsAreIgnored() {
        var machine = AIUsagePollingMachine()
        let due = AIUsagePollingMachine.Due(hostID: host, delay: .seconds(30), isFollowUp: false)
        #expect(machine.handle(.schedule(due)) == [.armPoll(1, after: .seconds(30))])
        #expect(machine.state == .waiting(due, timer: 1))
        #expect(machine.handle(.schedule(due)) == [.cancelPoll(1), .armPoll(2, after: .seconds(30))])
        #expect(machine.handle(.pollElapsed(1)) == [])
        #expect(machine.handle(.pollElapsed(2)) == [.retirePoll(2), .checkSchedule])
        #expect(machine.state == .paused)
        #expect(machine.handle(.pollElapsed(2)) == [])
        _ = machine.handle(.schedule(due))
        #expect(machine.handle(.schedule(nil)) == [.cancelPoll(3)])
        #expect(machine.handle(.schedule(nil)) == [])
        #expect(machine.state == .paused)
    }

    @Test func aFetchOwnsTheOnlySlotAndSuccessStoresItsReport() {
        var machine = AIUsagePollingMachine()
        #expect(machine.handle(fetch(host)) == [.fetch(host, path: path, token: token(1))])
        #expect(machine.fetchingHostID == host)
        #expect(machine.fetchToken == token(1))
        #expect(machine.handle([fetch(other), .schedule(nil), .pollElapsed(1)]) == [])
        #expect(machine.handle(.finished(token(1), .success(report), at: date, hostIsEnabled: true)) == [
            .retireFetch(token(1)), .reschedule,
        ])
        #expect(machine.fetchingHostID == nil)
        #expect(machine.usage[host]?.snapshot == AIUsageSnapshot(report: report, fetchedAt: date))
        #expect(machine.usage[host]?.lastFinishedAt == date)
        let completed = machine.usage
        #expect(machine.handle(.finished(token(1), .failed("late", executableMissing: false), at: date, hostIsEnabled: true)) == [])
        #expect(machine.usage == completed)
    }

    @Test func manualFetchCancelsAPollAndUnownedCompletionsCannotLand() {
        var machine = AIUsagePollingMachine().after([.schedule(.init(hostID: host, delay: .seconds(10), isFollowUp: true))])
        #expect(machine.handle(fetch(host)) == [.cancelPoll(1), .fetch(host, path: path, token: token(2))])
        let current = machine.state
        let foreign = AIUsagePollingMachine.FetchToken(requestID: UUID(), sequence: 2)
        #expect(machine.handle(.finished(foreign, .success(report), at: date, hostIsEnabled: true)) == [])
        #expect(machine.state == current)
        #expect(machine.handle(.pollElapsed(1)) == [])
    }

    @Test func failuresBackOffButAnInterruptionKeepsThePreviousReportAndFailure() {
        var machine = AIUsagePollingMachine().after([
            fetch(host), .finished(token(1), .success(report), at: date, hostIsEnabled: true), fetch(host),
        ])
        _ = machine.handle(.finished(token(2), .failed("timeout", executableMissing: false), at: date, hostIsEnabled: true))
        #expect(machine.usage[host]?.consecutiveFailures == 1)
        #expect(machine.usage[host]?.lastFailure == "timeout")
        _ = machine.handle(fetch(host))
        let later = date.addingTimeInterval(10)
        _ = machine.handle(.finished(token(3), .interrupted, at: later, hostIsEnabled: true))
        #expect(machine.usage[host]?.consecutiveFailures == 1)
        #expect(machine.usage[host]?.lastFailure == "timeout")
        #expect(machine.usage[host]?.snapshot?.report == report)
        #expect(machine.usage[host]?.lastFinishedAt == later)
        _ = machine.handle(fetch(host))
        #expect(machine.handle(.finished(token(4), .failed("missing", executableMissing: true), at: later, hostIsEnabled: true)) == [
            .retireFetch(token(4)), .redetect(host),
        ])
        _ = machine.handle(fetch(host))
        _ = machine.handle(.finished(token(5), .success(report), at: later, hostIsEnabled: true))
        #expect(machine.usage[host]?.consecutiveFailures == 0)
        #expect(machine.usage[host]?.lastFailure == nil)
    }

    @Test func forgettingAHostCancelsItsOwnershipAndRejectsItsLateAnswer() {
        var machine = AIUsagePollingMachine().after([
            fetch(host), .finished(token(1), .success(report), at: date, hostIsEnabled: true), fetch(host),
        ])
        #expect(machine.handle(.forget(other)) == [])
        #expect(machine.fetchingHostID == host)
        #expect(machine.handle(.forget(host)) == [.cancelFetch(token(2))])
        #expect(machine.usage[host] == nil)
        #expect(machine.state == .paused)
        _ = machine.handle(fetch(host))
        #expect(machine.handle(.finished(token(2), .success(report), at: date, hostIsEnabled: true)) == [])
        #expect(machine.fetchToken == token(3))
        #expect(machine.usage[host] == nil)
        #expect(machine.handle(.finished(token(3), .success(report), at: date, hostIsEnabled: false)) == [
            .retireFetch(token(3)), .reschedule,
        ])
        #expect(machine.usage[host] == nil)
    }

    @Test func anOldServerReportGetsOneFollowUpUntilTheNextScheduledPoll() {
        var old = report
        old.source = .server
        old.oldestUpdatedAt = date.addingTimeInterval(-AIUsagePollSchedule.serverRebuildAge - 1)
        var machine = AIUsagePollingMachine().after([
            fetch(host), .finished(token(1), .success(old), at: date, hostIsEnabled: true),
        ])
        #expect(machine.usage[host]?.snapshot?.fetchedAt == old.oldestUpdatedAt)
        #expect(machine.followUp(for: host) == date.addingTimeInterval(AIUsagePollSchedule.serverFollowUpDelay))
        _ = machine.handle(fetch(host))
        #expect(machine.followUp(for: host) == nil)
        _ = machine.handle(.finished(token(2), .success(old), at: date, hostIsEnabled: true))
        #expect(machine.followUp(for: host) == nil)
        _ = machine.handle(fetch(host, scheduled: true))
        _ = machine.handle(.finished(token(3), .success(old), at: date, hostIsEnabled: true))
        #expect(machine.followUp(for: host) != nil)
        _ = machine.handle(.forget(host))
        #expect(machine.followUp(for: host) == nil)
        #expect(machine.usage[host] == nil)
    }

    @Test func commandFailuresInAReportCountWithoutDiscardingTheReport() {
        let failed = AIUsageReport(providers: [], commandError: "provider failed")
        var machine = AIUsagePollingMachine().after([fetch(host)])
        _ = machine.handle(.finished(token(1), .success(failed), at: date, hostIsEnabled: true))
        #expect(machine.usage[host]?.lastFailure == "provider failed")
        #expect(machine.usage[host]?.consecutiveFailures == 1)
        #expect(machine.usage[host]?.snapshot?.report == failed)
        _ = machine.handle(.schedule(.init(hostID: host, delay: .seconds(1), isFollowUp: false)))
        #expect(machine.handle(.finished(token(1), .success(report), at: date, hostIsEnabled: true)) == [])
    }
}
