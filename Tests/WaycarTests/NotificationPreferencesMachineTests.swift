import Foundation
import Testing

@testable import Waycar

struct NotificationPreferencesMachineTests {
    private let host = UUID()
    private let other = UUID()
    private let settings = NotificationPreferencesStore.HostSettings(
        isRegistered: false, notify: NotificationTriggerPreferences())
    private let registered = NotificationPreferencesStore.HostSettings(
        isRegistered: true, notify: NotificationTriggerPreferences())

    private func makeMachine() -> NotificationPreferencesMachine {
        NotificationPreferencesMachine().after([.hostsChanged([host, other])])
    }

    @Test func loadsPublishOnlyForTheirCurrentToken() {
        var machine = makeMachine()
        #expect(machine.displays.isEmpty)
        #expect(machine.handle(.load(host, hasDeviceToken: true)) == [.read(1)])
        #expect(machine.displays[host] == .loading)
        #expect(machine.handle(.load(host, hasDeviceToken: true)) == [.read(2)])
        #expect(machine.handle(.loaded(host, 1, settings, needsRegistration: true)) == [])
        #expect(machine.handle(.loadFailed(host, 1, "old")) == [])
        #expect(machine.displays[host] == .loading)
        #expect(machine.handle(.loaded(host, 2, settings, needsRegistration: false)) == [])
        #expect(machine.displays[host] == .idle(settings))
        _ = machine.handle(.load(host, hasDeviceToken: true))
        #expect(machine.handle(.loaded(host, 3, registered, needsRegistration: true)) == [.reregister(registered)])
        _ = machine.handle(.load(host, hasDeviceToken: true))
        _ = machine.handle(.loadFailed(host, 4, "offline"))
        #expect(machine.displays[host] == .unavailable(message: "offline"))
    }

    @Test func writesKeepTheLastTruthAndExcludeRefresh() {
        var machine = makeMachine()
        #expect(machine.handle(.write(host, settings, hasDeviceToken: true)) == [.write(1)])
        #expect(machine.displays[host] == .updating(settings))
        #expect(machine.handle(.load(host, hasDeviceToken: true)) == [])
        #expect(machine.handle(.write(other, settings, hasDeviceToken: true)) == [.write(2)])
        #expect(machine.handle(.written(other, 2, registered, summaryChoice: true)) == [.writeCompleted(summaryChoice: true)])
        #expect(machine.displays[host] == .updating(settings))
        #expect(machine.handle(.written(host, 1, registered, summaryChoice: false)) == [.writeCompleted(summaryChoice: false)])
        #expect(machine.displays[host] == .idle(registered))
    }

    @Test func failedWritesRereadBeforePublishingAndKeepTheOriginalFailure() {
        for rereadSucceeds in [true, false] {
            var machine = makeMachine()
            _ = machine.handle(.write(host, settings, hasDeviceToken: true))
            #expect(machine.handle(.writeFailed(host, 1, "write failed")) == [.reread(1)])
            #expect(machine.state.hosts[host] == .recoveringAfterPartialWrite(1, settings, "write failed"))
            #expect(machine.displays[host] == .updating(settings))
            #expect(machine.handle(.load(host, hasDeviceToken: true)) == [])
            #expect(machine.handle(.recovered(host, 0, registered)) == [])
            #expect(machine.handle(.recoveryFailed(host, 0)) == [])
            let completion: NotificationPreferencesMachine.Event = rereadSucceeds
                ? .recovered(host, 1, registered) : .recoveryFailed(host, 1)
            #expect(machine.handle(completion) == [.writeCompleted(summaryChoice: nil)])
            #expect(machine.displays[host] == (rereadSucceeds
                ? .failed(message: "write failed", settings: registered)
                : .unavailable(message: "write failed")))
        }
    }

    @Test func missingTokenAndMissingHostDoNotStartReads() {
        var machine = makeMachine()
        #expect(machine.handle(.load(UUID(), hasDeviceToken: true)) == [])
        #expect(machine.handle(.load(host, hasDeviceToken: false)) == [])
        #expect(machine.displays[host] == .unavailable(message: "Waiting for push registration on this device."))
        #expect(machine.handle(.write(other, settings, hasDeviceToken: false)) == [])
        #expect(machine.displays[other] == machine.displays[host])
    }

    @Test func removalAndReplacementInvalidateEveryKindOfCompletion() {
        for stage in 0...2 {
            var machine = makeMachine()
            _ = machine.handle(.load(host, hasDeviceToken: true))
            if stage > 0 { _ = machine.handle(.write(host, settings, hasDeviceToken: true)) }
            if stage > 1 { _ = machine.handle(.writeFailed(host, 2, "failed")) }
            _ = machine.handle([.hostsChanged([other]), .hostsChanged([host, other])])
            let reset = machine.state
            let completions: [NotificationPreferencesMachine.Event] = [
                .loaded(host, 1, registered, needsRegistration: true), .loadFailed(host, 1, "old"),
                .written(host, 2, registered, summaryChoice: true), .writeFailed(host, 2, "old"),
                .recovered(host, 2, registered), .recoveryFailed(host, 2)
            ]
            for event in completions {
                #expect(machine.handle(event) == [])
                #expect(machine.state == reset)
            }
            #expect(machine.handle(.load(host, hasDeviceToken: true)) == [.read(stage == 0 ? 2 : 3)])
        }
    }

    @Test func aNewWriteSupersedesOldReadWriteAndRecoveryTokens() {
        var machine = makeMachine()
        _ = machine.handle([.load(host, hasDeviceToken: true), .write(host, settings, hasDeviceToken: true),
                            .writeFailed(host, 2, "old"), .write(host, registered, hasDeviceToken: true)])
        let current = machine.state
        let completions: [NotificationPreferencesMachine.Event] = [
            .loaded(host, 1, settings, needsRegistration: true), .loadFailed(host, 1, "old"),
            .written(host, 2, settings, summaryChoice: false), .writeFailed(host, 2, "old"),
            .recovered(host, 2, settings), .recoveryFailed(host, 2)
        ]
        for event in completions {
            #expect(machine.handle(event) == [])
            #expect(machine.state == current)
        }
        #expect(machine.handle(.written(host, 3, registered, summaryChoice: nil)) == [.writeCompleted(summaryChoice: nil)])
    }
}
