import Foundation
import Testing

@testable import Waycar

@Suite("Notification ask machine")
struct NotificationAskMachineTests {
    @Test func onlyOneEligibleScenePresentsAndItsReleaseIsConditional() {
        let first = UUID(), second = UUID()
        var machine = NotificationAskMachine(answer: nil)
        #expect(machine.handle(.present(first, eligible: false)) == [])
        #expect(machine.sceneID == nil)
        #expect(machine.handle(.present(first, eligible: true)) == [])
        #expect(machine.handle([.present(second, eligible: true), .release(second)]) == [])
        #expect(machine.sceneID == first)
        #expect(machine.handle(.release(first)) == [])
        #expect(machine.sceneID == nil)
    }

    @Test func unavailableOnlyEndsAPresentedAskAndDeniedIsDurable() {
        var machine = NotificationAskMachine(answer: nil)
        #expect(machine.handle(.unavailable(denied: true)) == [])
        #expect(machine.answer == nil)
        #expect(machine.handle(.present(UUID(), eligible: true)) == [])
        #expect(machine.handle(.unavailable(denied: false)) == [])
        #expect(machine.sceneID == nil)
        #expect(machine.handle(.present(UUID(), eligible: true)) == [])
        #expect(machine.handle(.unavailable(denied: true)) == [.persist(.declined)])
        #expect(machine.answer == .declined)
    }

    @Test func turnOnWithoutAPromptEnrollsAndBothAnswersAreFinal() {
        var machine = NotificationAskMachine(answer: nil)
        #expect(machine.handle(.turnOn(needsPermission: false)) == [
            .initializeEnrollment, .persist(.accepted), .saveEnrollment, .processEnrollment,
        ])
        #expect(machine.canEnroll)
        #expect(machine.answer == .accepted)
        #expect(machine.handle([.decline, .turnOn(needsPermission: true), .release(UUID())]) == [])
        var declined = NotificationAskMachine(answer: nil)
        #expect(declined.handle(.decline) == [.persist(.declined)])
        #expect(declined.handle([.decline, .turnOn(needsPermission: false)]) == [])
        #expect(!declined.canEnroll)
    }

    @Test func permissionClosesTheSheetBeforeDurableAcceptance() {
        var machine = NotificationAskMachine(answer: nil)
        #expect(machine.handle(.turnOn(needsPermission: true)) == [
            .initializeEnrollment, .requestPermission(1),
        ])
        #expect(machine.answer == .accepted)
        #expect(!machine.canEnroll)
        #expect(machine.sceneID == nil)
        #expect(machine.handle([.decline, .turnOn(needsPermission: true),
                                .permissionFinished(999, .allowed)]) == [])
        #expect(machine.handle(.permissionFinished(1, .allowed)) == [
            .persist(.accepted), .saveEnrollment, .processEnrollment,
        ])
        #expect(machine.canEnroll)
        #expect(machine.handle(.permissionFinished(1, .denied)) == [])
    }

    @Test func deniedPermissionClearsEnrollmentAndFailedPermissionAllowsAnotherAsk() {
        var denied = NotificationAskMachine(answer: nil).after([.turnOn(needsPermission: true)])
        #expect(denied.handle(.permissionFinished(1, .denied)) == [.clearEnrollment, .persist(.declined)])
        #expect(denied.answer == .declined)
        var failed = NotificationAskMachine(answer: nil).after([.turnOn(needsPermission: true)])
        #expect(failed.handle(.permissionFinished(1, .failed)) == [.clearEnrollment])
        #expect(failed.answer == nil)
        #expect(failed.handle(.turnOn(needsPermission: true)) == [.initializeEnrollment, .requestPermission(2)])
        #expect(failed.handle(.permissionFinished(1, .allowed)) == [])
    }

    @Test func persistedAnswersRestoreWithoutEffects() {
        #expect(NotificationAskMachine(answer: .accepted).canEnroll)
        #expect(NotificationAskMachine(answer: .declined).state == .declined)
    }
}
