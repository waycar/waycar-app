import Foundation
import Testing

@testable import Waycar

@Suite("Composer tray item machine")
struct ComposerTrayItemMachineTests {
    private let source = ComposerTrayItemMachine.Source(
        id: UUID(), value: .file(URL(fileURLWithPath: "/picked.txt")))
    private func queued() -> ComposerTrayItemMachine { ComposerTrayItemMachine(source: source) }
    private func staging() -> ComposerTrayItemMachine { queued().after([.started(1)]) }
    private func failed() -> ComposerTrayItemMachine {
        staging().after([.failed(1, message: "failed", retryable: true)])
    }

    @Test func queuedItemStartsAndCompletesOnce() {
        var machine = queued()
        #expect(machine.state == .queued(source))
        #expect(machine.source != nil)
        #expect(machine.handle(.started(1)) == [])
        #expect(machine.state == .staging(source, operation: 1))
        #expect(machine.handle(.completed(1, path: "/host")) == [.discardSource(source)])
        #expect(machine.state == .ready("/host"))
        #expect(machine.source == nil)
        #expect(machine.retainedOperation == nil)
        #expect(machine.status == .ready(path: "/host"))
        #expect(machine.handle(.completed(1, path: "/late")) == [])
    }

    @Test func failureRetainsSourceAndWorkerForExplicitRetry() {
        var machine = staging()
        #expect(machine.handle(.failed(1, message: "failed", retryable: true)) == [])
        #expect(machine.state == .failed(source, message: "failed", retryable: true, operation: 1))
        #expect(machine.retainedOperation == 1)
        #expect(machine.handle(.retryRetained(2)) == [])
        #expect(machine.handle(.retryRetained(1)) == [])
        #expect(machine.state == .staging(source, operation: 1))
        _ = machine.handle(.failed(1, message: "fatal", retryable: false))
        #expect(machine.handle(.retrySource) == [])
        #expect(machine.state == .queued(source))
    }

    @Test func changingBindingFailsAnUploadAndForgetsEveryRetainedWorkerID() {
        var machine = staging()
        #expect(machine.handle(.bindingChanged(stoppedMessage: "stopped")) == [])
        #expect(machine.state == .failed(source, message: "stopped", retryable: true, operation: nil))
        #expect(machine.handle(.retryRetained(1)) == [])
        #expect(machine.handle(.retrySource) == [])
        #expect(machine.state == .queued(source))
        machine = failed()
        #expect(machine.handle(.bindingChanged(stoppedMessage: "stopped")) == [])
        #expect(machine.state == .failed(source, message: "failed", retryable: true, operation: nil))
    }

    @Test func removalDiscardsTheSourceAndCancelsOrDismissesOnlyItsWorker() {
        var machine = queued()
        #expect(machine.handle(.remove) == [.discardSource(source)])
        #expect(machine.state == .removed)
        machine = staging()
        #expect(machine.handle(.remove) == [.discardSource(source), .cancel(1)])
        machine = failed()
        #expect(machine.handle(.remove) == [.discardSource(source), .dismiss(1)])
        machine = failed().after([.bindingChanged(stoppedMessage: "stopped")])
        #expect(machine.handle(.remove) == [.discardSource(source)])
        machine = ComposerTrayItemMachine(readyPath: "/host")
        #expect(machine.handle(.remove) == [])
        #expect(machine.state == .removed)
        #expect(machine.status == nil)
    }

    @Test func takingTransfersRatherThanDiscardsSourcesAndLeavesHostFilesAlone() {
        var machine = queued()
        #expect(machine.handle(.take) == [])
        #expect(machine.state == .removed)
        machine = staging()
        #expect(machine.handle(.take) == [])
        #expect(machine.state == .removed)
        machine = failed()
        #expect(machine.handle(.take) == [.dismiss(1)])
        #expect(machine.state == .removed)
        machine = failed().after([.bindingChanged(stoppedMessage: "stopped")])
        #expect(machine.handle(.take) == [])
        machine = ComposerTrayItemMachine(readyPath: "/host")
        #expect(machine.handle(.take) == [])
        #expect(machine.state == .removed)
    }

    @Test func staleCompletionsAndIllegalEventsDoNothing() {
        let events: [ComposerTrayItemMachine.Event] = [
            .completed(99, path: "/late"), .failed(99, message: "late", retryable: false),
            .retryRetained(99),
        ]
        var machine = queued()
        #expect(machine.handle(events + [.retrySource, .bindingChanged(stoppedMessage: "stopped")]) == [])
        #expect(machine.state == .queued(source))
        machine = staging()
        #expect(machine.handle(events + [.retrySource, .started(2)]) == [])
        #expect(machine.state == .staging(source, operation: 1))
        machine = failed()
        #expect(machine.handle(events + [.started(2)]) == [])
        #expect(machine.state == failed().state)
        machine = ComposerTrayItemMachine(readyPath: "/host")
        #expect(machine.handle(events + [.started(1), .retrySource, .bindingChanged(stoppedMessage: "stopped")]) == [])
        #expect(machine.state == .ready("/host"))
        machine = queued().after([.remove])
        #expect(machine.handle(events + [.remove, .take, .started(1), .retrySource, .bindingChanged(stoppedMessage: "stopped")]) == [])
        #expect(machine.state == .removed)
    }
}
