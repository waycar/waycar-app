import Foundation
import Testing

@testable import Waycar

@Suite("CodexBar detection machine")
struct CodexBarDetectionMachineTests {
    private let id = UUID()
    private let path = "/usr/local/bin/codexbar"
    private var first: CodexBarDetectionMachine.Token { .init(requestID: id, sequence: 1) }
    private var second: CodexBarDetectionMachine.Token { .init(requestID: id, sequence: 2) }
    private var fresh: CodexBarDetectionMachine { .init(retryDelay: .seconds(30)) }

    @Test func unknownProbesOnceOnItsConnectionAndRecordsPresenceOrAbsence() {
        var machine = fresh
        #expect(machine.generation == nil)
        #expect(machine.detection == .unknown)
        #expect(machine.handle(.probe(generation: 1, requestID: id, customPath: nil)) == [.locate(first, customPath: nil)])
        #expect(machine.generation == 1)
        #expect(machine.detection == .probing)
        #expect(machine.handle(.finished(first, .located(path))) == [.didFind(path)])
        #expect(machine.state == .found(path: path, generation: 1))
        #expect(machine.handle(.probe(generation: 2, requestID: id, customPath: nil)) == [.locate(second, customPath: nil)])
        #expect(machine.detection == .found(path: path))
        #expect(machine.handle(.finished(second, .located(nil))) == [.didFind(nil)])
        #expect(machine.state == .missing(generation: 2))
        #expect(machine.detection == .notFound)
    }

    @Test func aFailedProbeRetainsAKnownPathThroughRetryAndReconnection() {
        var machine = fresh.after([
            .probe(generation: 1, requestID: id, customPath: nil), .finished(first, .located(path)),
            .probe(generation: 2, requestID: id, customPath: nil),
        ])
        #expect(machine.handle(.finished(second, .failed("offline"))) == [
            .armRetry(second, after: .seconds(30)), .reschedulePolling,
        ])
        #expect(machine.detection == .found(path: path))
        #expect(machine.generation == 2)
        #expect(machine.handle(.retryElapsed(second)) == [.retireRetry(second), .connectionsChanged])
        #expect(machine.generation == nil)
        #expect(machine.detection == .found(path: path))
    }

    @Test func failuresWithoutAPathAreShownAndBackOffUntilSuccess() {
        var machine = fresh.after([.probe(generation: 1, requestID: id, customPath: nil)])
        _ = machine.handle(.finished(first, .failed("offline")))
        #expect(machine.detection == .failed(message: "offline"))
        _ = machine.handle(.retryElapsed(first))
        _ = machine.handle(.probe(generation: 1, requestID: id, customPath: nil))
        #expect(machine.handle(.finished(second, .failed("again"))) == [
            .armRetry(second, after: .seconds(60)), .reschedulePolling,
        ])
        #expect(machine.handle(.probe(generation: 2, requestID: id, customPath: path)) == [
            .cancelRetry(second), .locate(.init(requestID: id, sequence: 3), customPath: path),
        ])
        _ = machine.handle(.finished(.init(requestID: id, sequence: 3), .located(path)))
        _ = machine.handle(.probe(generation: 3, requestID: id, customPath: nil))
        let fourth = CodexBarDetectionMachine.Token(requestID: id, sequence: 4)
        #expect(machine.handle(.finished(fourth, .failed("later"))) == [
            .armRetry(fourth, after: .seconds(30)), .reschedulePolling,
        ])
    }

    @Test func anInvalidPathDoesNotProbeOrRetryAndResetAllowsAFreshCheck() {
        var machine = fresh
        #expect(machine.handle(.probe(generation: 1, requestID: id, customPath: "relative")) == [])
        #expect(machine.generation == 1)
        #expect(machine.detection == .failed(message: CodexBarError.invalidPath.message))
        #expect(machine.handle([.finished(first, .located(path)), .retryElapsed(first)]) == [])
        #expect(machine.handle(.reset) == [])
        #expect(machine.generation == nil)
        #expect(machine.detection == .unknown)
        #expect(machine.handle(.probe(generation: 1, requestID: id, customPath: path)) == [.locate(second, customPath: path)])
    }

    @Test func supersededCallbacksAndUUIDsFromAForgottenHostCannotLand() {
        var machine = fresh.after([
            .probe(generation: 1, requestID: id, customPath: nil),
            .probe(generation: 2, requestID: id, customPath: nil),
        ])
        let current = machine.state
        #expect(machine.handle([.finished(first, .located(path)), .retryElapsed(first)]) == [])
        #expect(machine.state == current)
        let reusedSequence = CodexBarDetectionMachine.Token(requestID: UUID(), sequence: 2)
        #expect(machine.handle(.finished(reusedSequence, .located(path))) == [])
        #expect(machine.state == current)
        _ = machine.handle(.finished(second, .failed("offline")))
        let waiting = machine.state
        #expect(machine.handle([.finished(second, .located(path)), .retryElapsed(first)]) == [])
        #expect(machine.state == waiting)
        #expect(machine.handle(.reset) == [.cancelRetry(second)])
        #expect(machine.handle([.finished(second, .located(path)), .retryElapsed(second)]) == [])
        #expect(machine.detection == .unknown)
    }

    @Test func missingAndInvalidChecksCanBeReplacedAndAnInFlightCheckCanBeReset() {
        var missing = fresh.after([
            .probe(generation: 1, requestID: id, customPath: nil), .finished(first, .located(nil)),
        ])
        #expect(missing.handle(.probe(generation: 2, requestID: id, customPath: path)) == [.locate(second, customPath: path)])
        #expect(missing.detection == .probing)
        #expect(missing.handle(.reset) == [])
        #expect(missing.handle(.finished(second, .located(path))) == [])
        var invalid = fresh.after([.probe(generation: 1, requestID: id, customPath: "relative")])
        #expect(invalid.handle(.probe(generation: 2, requestID: id, customPath: path)) == [.locate(second, customPath: path)])
        #expect(invalid.generation == 2)
        var unknown = fresh
        #expect(unknown.handle(.reset) == [])
        #expect(unknown.detection == .unknown)
    }

    @Test func completionsInFinishedStatesAndTimersWithoutARetryAreIgnored() {
        for outcome in [CodexBarDetectionMachine.Outcome.located(path), .located(nil)] {
            var machine = fresh.after([
                .probe(generation: 1, requestID: id, customPath: nil), .finished(first, outcome),
            ])
            let state = machine.state
            #expect(machine.handle([.finished(first, .failed("late")), .retryElapsed(first)]) == [])
            #expect(machine.state == state)
            #expect(machine.handle(.reset) == [])
        }
        var unknown = fresh
        #expect(unknown.handle([.finished(first, .located(path)), .retryElapsed(first)]) == [])
    }
}
