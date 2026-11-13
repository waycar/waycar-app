import Testing

@testable import Waycar

@Suite("Pairing camera access machine")
struct PairingCameraAccessMachineTests {
    @Test func aCurrentSnapshotSettlesWithoutRequestingPermission() {
        var machine = PairingCameraAccessMachine()
        #expect(machine.access == .undetermined)
        #expect(machine.handle(.authorization(.denied)).isEmpty)
        #expect(machine.state == .denied)
        #expect(machine.handle(.authorization(.authorized)).isEmpty)
        #expect(machine.state == .authorized)
        #expect(machine.handle(.authorization(.denied)).isEmpty)
        #expect(machine.access == .denied)
    }

    @Test(arguments: [true, false])
    func theCurrentPermissionAnswerEndsTheRequest(granted: Bool) {
        var machine = PairingCameraAccessMachine()
        #expect(machine.handle(.authorization(.undetermined)) == [.requestPermission(1)])
        #expect(machine.state == .requesting(1))
        #expect(machine.access == .undetermined)
        #expect(machine.handle(.authorization(.undetermined)).isEmpty)
        #expect(machine.state == .requesting(1))
        #expect(machine.handle(.permissionReturned(1, granted: granted)).isEmpty)
        #expect(machine.access == (granted ? .authorized : .denied))
    }

    @Test func aSnapshotInvalidatesTheOldRequestWithoutReusingItsToken() {
        var machine = PairingCameraAccessMachine().after([
            .authorization(.undetermined), .authorization(.authorized),
        ])
        #expect(machine.handle(.permissionReturned(1, granted: false)).isEmpty)
        #expect(machine.access == .authorized)
        #expect(machine.handle(.authorization(.undetermined)) == [.requestPermission(2)])
        #expect(machine.handle(.permissionReturned(1, granted: false)).isEmpty)
        #expect(machine.state == .requesting(2))
        #expect(machine.handle(.permissionReturned(2, granted: true)).isEmpty)
        #expect(machine.access == .authorized)
    }

    @Test func anUnownedOrDuplicatePermissionAnswerDoesNothing() {
        var machine = PairingCameraAccessMachine()
        #expect(machine.handle(.permissionReturned(1, granted: true)).isEmpty)
        #expect(machine.state == .undetermined)
        _ = machine.handle(.authorization(.undetermined))
        #expect(machine.handle(.permissionReturned(99, granted: true)).isEmpty)
        #expect(machine.state == .requesting(1))
        _ = machine.handle(.permissionReturned(1, granted: false))
        #expect(machine.handle(.permissionReturned(1, granted: true)).isEmpty)
        #expect(machine.access == .denied)
    }
}
