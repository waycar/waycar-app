import Testing

@testable import Waycar

struct PushRegistrationMachineTests {
    private let token = APNSDeviceToken(hex: "01", environment: .sandbox)

    @Test func authorizationAnswers() {
        for (answer, display, effects) in [
            (PushRegistrationMachine.Authorization.allowed, PushRegistrationMachine.DisplayState.waitingForToken,
             [PushRegistrationMachine.Effect.register]),
            (.denied, .denied, []), (.undetermined, .needsPermission, [])
        ] {
            var machine = PushRegistrationMachine()
            #expect(machine.handle(.refresh) == [.checkAuthorization(1)])
            #expect(machine.display == .unknown)
            #expect(machine.handle(.authorizationFinished(1, answer)) == effects)
            #expect(machine.display == display)
        }
    }

    @Test func permissionAnswers() {
        for (answer, display, effects) in [
            (PushRegistrationMachine.Permission.granted, PushRegistrationMachine.DisplayState.waitingForToken,
             [PushRegistrationMachine.Effect.register]),
            (.denied, .denied, []), (.failed("failure"), .failed("failure"), [])
        ] {
            var machine = PushRegistrationMachine()
            #expect(machine.handle(.enable) == [.requestPermission(1)])
            #expect(machine.handle(.permissionFinished(1, answer)) == effects)
            #expect(machine.display == display)
        }
    }

    @Test func revokedTokenIsRetainedButNeverExposedByALateCallback() {
        var machine = PushRegistrationMachine().after([
            .deviceTokenArrived(token), .refresh, .authorizationFinished(1, .denied)
        ])
        #expect(machine.display == .denied)
        #expect(machine.handle(.deviceTokenArrived(token)) == [])
        #expect(machine.display == .denied)
        #expect(machine.handle(.refresh) == [.checkAuthorization(2)])
        #expect(machine.handle(.authorizationFinished(2, .allowed)) == [])
        #expect(machine.display == .registered(token))
    }

    @Test func olderAnswersAndUnsolicitedCompletionsAreIgnored() {
        var machine = PushRegistrationMachine()
        #expect(machine.handle(.authorizationFinished(1, .allowed)) == [])
        #expect(machine.handle(.permissionFinished(1, .granted)) == [])
        _ = machine.handle([.refresh, .refresh])
        let checking = machine.state
        #expect(machine.handle(.authorizationFinished(1, .allowed)) == [])
        #expect(machine.state == checking)
        _ = machine.handle(.enable)
        let requesting = machine.state
        #expect(machine.handle(.authorizationFinished(2, .denied)) == [])
        #expect(machine.state == requesting)
        _ = machine.handle(.refresh)
        #expect(machine.handle(.permissionFinished(3, .granted)) == [])
        #expect(machine.handle(.authorizationFinished(4, .denied)) == [])
        #expect(machine.display == .denied)
    }

    @Test func callbacksKeepTheCurrentAuthorizationOperation() {
        var machine = PushRegistrationMachine().after([.refresh])
        _ = machine.handle(.deviceTokenArrived(token))
        #expect(machine.handle(.authorizationFinished(1, .allowed)) == [])
        #expect(machine.display == .registered(token))
        _ = machine.handle([.enable, .registrationFailed("registration")])
        #expect(machine.display == .failed("registration"))
        #expect(machine.handle(.permissionFinished(2, .granted)) == [.register])
        #expect(machine.display == .waitingForToken)
        _ = machine.handle(.registrationFailed("again"))
        #expect(machine.display == .failed("again"))
        _ = machine.handle([.refresh, .authorizationFinished(3, .allowed)])
        #expect(machine.display == .registered(token))
    }

    @Test func everyStatusCanStartANewQueryOrPermissionRequest() {
        let setups: [[PushRegistrationMachine.Event]] = [
            [], [.deviceTokenArrived(token)], [.registrationFailed("failure")],
            [.refresh], [.enable], [.refresh, .authorizationFinished(1, .denied)],
            [.refresh, .authorizationFinished(1, .undetermined)],
            [.refresh, .authorizationFinished(1, .allowed)]
        ]
        for setup in setups {
            var machine = PushRegistrationMachine().after(setup)
            let display = machine.display
            guard case .checkAuthorization(let generation) = machine.handle(.refresh).first else {
                Issue.record("refresh must start a query")
                continue
            }
            #expect(machine.display == display)
            #expect(machine.handle(.enable) == [.requestPermission(generation + 1)])
            #expect(machine.display == display)
        }
    }
}
